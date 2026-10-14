//! Persistent authenticated remote control. At most four connections per host:
//! one accept thread plus one reader and one writer per connection (nine total).
//! GUI owns all application effects; transport threads only move owned values.
//! Work retains its connection; shutdown does not invalidate outstanding Work.
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
const wire = @import("wire.zig");
const channel = @import("RemoteChannel.zig");
pub const protocol = @import("../../../gx/remote_protocol.zig");
pub const BoundPeer = channel.BoundPeer;
pub const max_connections = 4;
pub const queue_capacity = 32;
pub fn nativeOffer(mapping: protocol.Mapping) channel.Offer {
    var result: channel.Offer = undefined;
    inline for (std.meta.fields(channel.Offer)) |field| @field(result, field.name) = @field(mapping, field.name);
    return result;
}
pub fn mappingOffer(surface: @import("../../../gx/ui_ref.zig").Reference, offer_id: u64, offer: channel.Offer) protocol.Mapping {
    var result: protocol.Mapping = undefined;
    result.surface = surface;
    result.offer_id = offer_id;
    inline for (std.meta.fields(channel.Offer)) |field| @field(result, field.name) = @field(offer, field.name);
    return result;
}
pub const Endpoint = struct {
    name: [128:0]u16,
    isolation: security.policy.Isolation,
    target: security.policy.Process,
    pub fn init(isolation: security.policy.Isolation, identity: security.policy.Identity, target: security.policy.Process) !Endpoint {
        if (target.pid == 0 or target.birth == 0) return error.InvalidIdentity;
        const domain = try wire.Endpoint.init(isolation, identity);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(std.mem.sliceAsBytes(std.mem.span(@as([*:0]const u16, &domain.name))));
        var process: [12]u8 = undefined;
        std.mem.writeInt(u32, process[0..4], target.pid, .little);
        std.mem.writeInt(u64, process[4..12], target.birth, .little);
        hash.update(&process);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var ascii: [120]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\ghostty-gx-remote-v1-{s}", .{std.fmt.bytesToHex(digest, .lower)});
        var result: Endpoint = .{ .name = @splat(0), .isolation = isolation, .target = target };
        _ = try std.unicode.utf8ToUtf16Le(&result.name, text);
        return result;
    }
};

const Record = struct { id: u64, digest: [32]u8, ticket: protocol.Ticket, outcome: ?protocol.Outcome = null, offer_id: u64 = 0, target_handle: u64 = 0, ack_pending: bool = false };
const Ledger = struct {
    records: [128]?Record = @splat(null),
    high_water: u64 = 0,
    next: usize = 0,
    fn admit(self: *Ledger, packet: *const protocol.Packet, bytes: []const u8) !union(enum) { fresh, pending, complete: Record } {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        for (self.records) |entry| if (entry) |record| if (record.id == packet.request_id) {
            if (!std.mem.eql(u8, &record.digest, &digest)) return error.RequestConflict;
            return if (record.outcome != null) .{ .complete = record } else .pending;
        };
        if (packet.request_id <= self.high_water) return error.ExpiredRequest;
        if (self.records[self.next]) |old| if (old.outcome == null or old.ack_pending) return error.QueueFull;
        self.records[self.next] = .{ .id = packet.request_id, .digest = digest, .ticket = packet.ticket };
        self.next = (self.next + 1) % self.records.len;
        self.high_water = packet.request_id;
        return .fresh;
    }
    fn finish(self: *Ledger, id: u64, outcome: protocol.Outcome, offer_id: u64, target_handle: u64) !Record {
        for (&self.records) |*entry| if (entry.*) |*record| if (record.id == id) {
            if (record.outcome) |previous| {
                if (previous != outcome or record.offer_id != offer_id or record.target_handle != target_handle) return error.RequestConflict;
            }
            record.outcome = outcome;
            record.offer_id = offer_id;
            record.target_handle = target_handle;
            record.ack_pending = true;
            return record.*;
        };
        return error.UnknownRequest;
    }
};

pub const Work = struct {
    connection: *Connection,
    event: union(enum) {
        connected,
        packet: *protocol.Packet,
        disconnected: u16,
        resize_needed: struct { surface: @import("../../../gx/ui_ref.zig").Reference, width: u32, height: u32 },
        frame_failed: @import("../../../gx/ui_ref.zig").Reference,
    },
    /// Peer facts were read from this pipe and bound by the mutual hello.
    /// Only call after connected was delivered. A pre-handshake disconnected
    /// event has no peer. Never retain this pointer past Work.release.
    pub fn peer(self: *const Work) *const BoundPeer {
        return &self.connection.peer.?;
    }
    pub fn release(self: *Work) void {
        if (self.event == .packet) self.connection.allocator.destroy(self.event.packet);
        self.connection.release();
        self.* = undefined;
    }
};

pub const Connection = struct {
    pub const FrameSource = struct {
        surface: @import("../../../gx/ui_ref.zig").Reference,
        ticket: protocol.Ticket,
        generation: u64,
        sequence: *const std.atomic.Value(u64),
        requested_size: *const std.atomic.Value(u64),
        failed: *const std.atomic.Value(bool),
    };
    const Watch = struct {
        source: FrameSource,
        sequence: u64 = 0,
        requested_size: u64 = 0,
        failed: bool = false,
        resize_pending: bool = false,
        failure_pending: bool = false,
    };
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
    local_epoch: u128,
    peer: ?BoundPeer = null,
    local_process: security.policy.Process = .{ .pid = 0, .birth = 0 },
    pipe: ?n.HANDLE,
    server_side: bool,
    stop: n.HANDLE,
    changed: n.HANDLE,
    incoming_changed: n.HANDLE,
    hwnd: std.os.windows.HWND,
    message: u32,
    thread: ?std.Thread = null,
    references: std.atomic.Value(usize) = .init(1),
    control: std.os.windows.SRWLOCK = .{},
    connected: bool = false,
    reported_connected: bool = false,
    ended: bool = false,
    reported_ended: bool = false,
    failure: u16 = 0,
    closing: bool = false,
    outgoing: [queue_capacity]?[]u8 = @splat(null),
    out_head: usize = 0,
    out_len: usize = 0,
    writing: bool = false,
    incoming: [queue_capacity]?*protocol.Packet = @splat(null),
    in_head: usize = 0,
    in_len: usize = 0,
    stopped_input: ?*protocol.Packet = null,
    ledger: Ledger = .{},
    sent_high_water: u64 = 0,
    highest_offer_id: u64 = 0,
    watches: [protocol.max_leaves]?Watch = @splat(null),
    frame_cursor: usize = 0,

    fn create(alloc: std.mem.Allocator, endpoint: Endpoint, epoch: u128, pipe: ?n.HANDLE, server_side: bool, hwnd: std.os.windows.HWND, message: u32) !*Connection {
        const self = try alloc.create(Connection);
        errdefer alloc.destroy(self);
        const stop = try n.event();
        errdefer _ = n.CloseHandle(stop);
        const changed = n.CreateEventW(null, 0, 0, null) orelse return error.EventFailed;
        errdefer _ = n.CloseHandle(changed);
        const incoming_changed = n.CreateEventW(null, 0, 0, null) orelse return error.EventFailed;
        errdefer _ = n.CloseHandle(incoming_changed);
        self.* = .{ .allocator = alloc, .endpoint = endpoint, .local_epoch = epoch, .pipe = pipe, .server_side = server_side, .stop = stop, .changed = changed, .incoming_changed = incoming_changed, .hwnd = hwnd, .message = message };
        return self;
    }
    fn lock(self: *Connection) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.control);
    }
    fn unlock(self: *Connection) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.control);
    }
    fn wake(self: *Connection) void {
        if (n.PostMessageW(self.hwnd, self.message, 0, 0) == 0) self.shutdown();
    }
    pub fn outputDrained(self: *Connection) bool {
        self.lock();
        defer self.unlock();
        if (self.out_len != 0 or self.writing) return false;
        for (self.ledger.records) |entry| if (entry) |record| if (record.ack_pending) return false;
        return true;
    }
    /// Remote GUI views that keep a connection beyond a Work must retain it.
    /// Releasing is non-destructive; only Service.reap/destroy joins and frees.
    pub fn retain(self: *Connection) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Connection) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 1);
    }
    /// Duplicate this handle into Output before it is published to a renderer.
    /// Output signals it alongside its own event; no per-frame thread is added.
    pub fn frameWakeHandle(self: *Connection) n.HANDLE {
        return self.changed;
    }
    /// Atomics remain borrowed until unwatchFrame returns. This lock is never
    /// held by the renderer; writer reads only these independent atomic fields.
    pub fn watchFrame(self: *Connection, source: FrameSource) !void {
        self.lock();
        defer self.unlock();
        if (self.closing or !self.connected) return error.NotConnected;
        if (!source.surface.isValid() or source.surface.kind != .surface or source.surface.epoch != self.local_epoch or source.ticket.source_epoch != self.local_epoch or source.ticket.target_epoch != self.peer.?.epoch or source.generation == 0) return error.InvalidFrameSource;
        for (&self.watches) |*slot| if (slot.*) |watch| {
            if (watch.source.surface.matches(source.surface)) {
                slot.* = .{ .source = source };
                _ = n.SetEvent(self.changed);
                return;
            }
        };
        for (&self.watches) |*slot| if (slot.* == null) {
            slot.* = .{ .source = source };
            _ = n.SetEvent(self.changed);
            return;
        };
        return error.QueueFull;
    }
    pub fn unwatchFrame(self: *Connection, surface: @import("../../../gx/ui_ref.zig").Reference) void {
        self.lock();
        defer self.unlock();
        for (&self.watches) |*slot| if (slot.*) |watch| if (watch.source.surface.matches(surface)) {
            slot.* = null;
        };
    }
    /// The shared allocator of request IDs for GUI and frame writer. Prefer
    /// this over send(Packet): assignment and enqueue are one locked operation.
    pub fn sendBody(self: *Connection, ticket: protocol.Ticket, body: protocol.Body) !u64 {
        if (body == .acknowledgement) return error.InvalidAcknowledgement;
        self.lock();
        defer self.unlock();
        if (self.closing or !self.connected) return error.NotConnected;
        if (self.out_len == self.outgoing.len) return error.QueueFull;
        const id = std.math.add(u64, self.sent_high_water, 1) catch return error.Exhausted;
        const packet = try self.allocator.create(protocol.Packet);
        defer self.allocator.destroy(packet);
        packet.* = .{ .sender_epoch = self.local_epoch, .recipient_epoch = self.peer.?.epoch, .request_id = id, .ticket = ticket, .body = body };
        const buffer = try self.allocator.alloc(u8, protocol.max_frame_size);
        defer self.allocator.free(buffer);
        const bytes = try self.allocator.dupe(u8, try protocol.encode(buffer, packet));
        self.outgoing[(self.out_head + self.out_len) % self.outgoing.len] = bytes;
        self.out_len += 1;
        self.sent_high_water = id;
        _ = n.SetEvent(self.changed);
        return id;
    }
    /// Copies and validates before returning. The GUI never waits for pipe I/O.
    /// Retry QueueFull with the same packet, but never replay input after reconnect.
    pub fn send(self: *Connection, packet: *const protocol.Packet) !void {
        const buffer = try self.allocator.alloc(u8, protocol.max_frame_size);
        defer self.allocator.free(buffer);
        const encoded = try protocol.encode(buffer, packet);
        const owned = try self.allocator.dupe(u8, encoded);
        errdefer self.allocator.free(owned);
        self.lock();
        defer self.unlock();
        if (self.closing or !self.connected) return error.NotConnected;
        const peer = &self.peer.?;
        if (packet.sender_epoch != self.local_epoch or packet.recipient_epoch != peer.epoch) return error.WrongPeer;
        if (self.out_len == self.outgoing.len) return error.QueueFull;
        if (packet.body != .acknowledgement) {
            if (packet.request_id <= self.sent_high_water) return error.RepeatedRequest;
            self.sent_high_water = packet.request_id;
        }
        self.outgoing[(self.out_head + self.out_len) % self.outgoing.len] = owned;
        self.out_len += 1;
        _ = n.SetEvent(self.changed);
    }
    /// The writer drains recorded ACKs even when ordinary sends are full.
    /// Completion never depends on replaying an input or application action.
    pub fn finish(self: *Connection, work: *const Work, outcome: protocol.Outcome) !void {
        return self.finishMapping(work, outcome, true);
    }
    /// For rejected mapping offers, a zero handle in the ACK explicitly means
    /// ownership was NOT consumed. The source must keep that Export debt.
    pub fn finishMapping(self: *Connection, work: *const Work, outcome: protocol.Outcome, mapping_consumed: bool) !void {
        if (work.connection != self or work.event != .packet) return error.InvalidWork;
        const packet = work.event.packet;
        if (packet.body == .acknowledgement) return error.InvalidWork;
        var offer_id: u64 = 0;
        var target_handle: u64 = 0;
        if (packet.body == .mapping_offer) {
            offer_id = packet.body.mapping_offer.offer_id;
            target_handle = if (mapping_consumed) packet.body.mapping_offer.target_handle else 0;
        }
        self.lock();
        _ = self.ledger.finish(packet.request_id, outcome, offer_id, target_handle) catch |err| {
            self.unlock();
            return err;
        };
        self.unlock();
        _ = n.SetEvent(self.changed);
    }
    fn ack(self: *Connection, record: Record) !void {
        self.lock();
        defer self.unlock();
        _ = try self.ledger.finish(record.id, record.outcome.?, record.offer_id, record.target_handle);
        _ = n.SetEvent(self.changed);
    }
    /// Called under control by the sole writer. Pending outcomes are bounded
    /// by the ledger and cannot be overwritten before they enter the queue.
    fn collectAcks(self: *Connection) !void {
        for (&self.ledger.records) |*entry| if (entry.*) |*record| {
            if (!record.ack_pending) continue;
            if (self.out_len == self.outgoing.len) return;
            const packet = try self.allocator.create(protocol.Packet);
            defer self.allocator.destroy(packet);
            packet.* = .{ .sender_epoch = self.local_epoch, .recipient_epoch = self.peer.?.epoch, .request_id = record.id, .ticket = record.ticket, .body = .{ .acknowledgement = .{ .outcome = record.outcome.?, .offer_id = record.offer_id, .target_handle = record.target_handle } } };
            var buffer: [256]u8 = undefined;
            const bytes = try self.allocator.dupe(u8, try protocol.encode(&buffer, packet));
            self.outgoing[(self.out_head + self.out_len) % self.outgoing.len] = bytes;
            self.out_len += 1;
            record.ack_pending = false;
        };
    }
    fn take(self: *Connection) ?Work {
        self.lock();
        defer self.unlock();
        const event: @FieldType(Work, "event") = if (self.connected and !self.reported_connected) block: {
            self.reported_connected = true;
            break :block .connected;
        } else if (self.in_len != 0) block: {
            const packet = self.incoming[self.in_head].?;
            self.incoming[self.in_head] = null;
            self.in_head = (self.in_head + 1) % self.incoming.len;
            self.in_len -= 1;
            _ = n.SetEvent(self.incoming_changed);
            break :block .{ .packet = packet };
        } else if (self.stopped_input) |packet| block: {
            self.stopped_input = null;
            break :block .{ .packet = packet };
        } else if (self.takeFrameEvent()) |frame_event| frame_event else if (self.ended and !self.reported_ended) block: {
            self.reported_ended = true;
            break :block .{ .disconnected = self.failure };
        } else return null;
        self.retain();
        return .{ .connection = self, .event = event };
    }
    fn takeFrameEvent(self: *Connection) ?@FieldType(Work, "event") {
        for (&self.watches) |*slot| if (slot.*) |*watch| {
            if (watch.failure_pending) {
                watch.failure_pending = false;
                return .{ .frame_failed = watch.source.surface };
            }
            if (watch.resize_pending) {
                watch.resize_pending = false;
                return .{ .resize_needed = .{ .surface = watch.source.surface, .width = @truncate(watch.requested_size), .height = @truncate(watch.requested_size >> 32) } };
            }
        };
        return null;
    }
    // Called by the sole writer while holding control. Frame packets join the
    // same queue and ID sequence as GUI packets, so wire order stays monotonic.
    fn collectFrames(self: *Connection) !bool {
        var wake_gui = false;
        for (0..self.watches.len) |offset| {
            const index = (self.frame_cursor + offset) % self.watches.len;
            const watch = if (self.watches[index]) |*value| value else continue;
            const requested = watch.source.requested_size.load(.acquire);
            if (requested != 0 and requested != watch.requested_size) {
                watch.requested_size = requested;
                watch.resize_pending = true;
                wake_gui = true;
            }
            if (!watch.failed and watch.source.failed.load(.acquire)) {
                watch.failed = true;
                watch.failure_pending = true;
                wake_gui = true;
            }
            const sequence = watch.source.sequence.load(.acquire);
            // Reserve four slots for GUI control/mapping traffic so busy frame
            // producers cannot starve remaining leaves' prepare/commit work.
            if (watch.failed or sequence == 0 or sequence == watch.sequence or self.out_len >= self.outgoing.len - 4) continue;
            const id = std.math.add(u64, self.sent_high_water, 1) catch return error.Exhausted;
            const packet = try self.allocator.create(protocol.Packet);
            defer self.allocator.destroy(packet);
            packet.* = .{ .sender_epoch = self.local_epoch, .recipient_epoch = self.peer.?.epoch, .request_id = id, .ticket = watch.source.ticket, .body = .{ .frame_ready = .{ .surface = watch.source.surface, .generation = watch.source.generation, .sequence = sequence } } };
            var buffer: [256]u8 = undefined;
            const bytes = try self.allocator.dupe(u8, try protocol.encode(&buffer, packet));
            self.outgoing[(self.out_head + self.out_len) % self.outgoing.len] = bytes;
            self.out_len += 1;
            self.sent_high_water = id;
            watch.sequence = sequence;
        }
        self.frame_cursor = (self.frame_cursor + 1) % self.watches.len;
        return wake_gui;
    }
    pub fn shutdown(self: *Connection) void {
        self.lock();
        self.closing = true;
        self.unlock();
        _ = n.SetEvent(self.stop);
    }
    fn launch(self: *Connection) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn run(self: *Connection) void {
        self.readLoop() catch |err| {
            self.lock();
            self.failure = @intFromError(err);
            self.unlock();
        };
        self.shutdown();
        self.lock();
        self.ended = true;
        self.unlock();
        self.wake();
    }
    fn handshake(self: *Connection) !void {
        const pipe = self.pipe.?;
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const facts = try security.pipePeer(pipe, self.server_side);
        defer facts.deinit();
        if (!self.server_side and !std.meta.eql(facts.identity.process, self.endpoint.target)) return error.WrongPeer;
        try security.policy.authenticate(local.identity, facts.identity, facts.identity.process, self.endpoint.isolation, self.endpoint.isolation, false);
        try security.verifyImage(local, facts);
        const deadline = n.Deadline.init(10000);
        var hello: [wire.hello_size]u8 = undefined;
        if (self.server_side) {
            wire.hello(&hello, self.local_epoch, local.identity, self.endpoint.isolation);
            try n.write(pipe, &hello, self.stop, deadline);
        }
        if ((try n.readMessage(pipe, &hello, self.stop, deadline)).len != hello.len) return error.InvalidHandshake;
        const epoch = try wire.verifyHello(&hello, local, facts, self.endpoint.isolation);
        if (epoch == self.local_epoch) return error.InvalidEpoch;
        const peer = try BoundPeer.fromPipe(pipe, self.server_side, facts.identity.process, self.endpoint.isolation, self.endpoint.isolation, epoch);
        if (!self.server_side) {
            // An explicit drag/transfer may hand foreground to this verified
            // target host, never to an unauthenticated endpoint claimant.
            _ = n.AllowSetForegroundWindow(facts.identity.process.pid);
            wire.hello(&hello, self.local_epoch, local.identity, self.endpoint.isolation);
            n.write(pipe, &hello, self.stop, deadline) catch |err| {
                var value = peer;
                value.deinit();
                return err;
            };
        }
        self.lock();
        self.peer = peer;
        self.local_process = local.identity.process;
        self.connected = true;
        self.unlock();
        self.wake();
    }
    fn readLoop(self: *Connection) !void {
        if (self.pipe == null) self.pipe = try open(&self.endpoint, self.stop);
        try self.handshake();
        const writer = try std.Thread.spawn(.{}, writeLoop, .{self});
        defer {
            self.shutdown();
            writer.join();
        }
        const buffer = try self.allocator.alloc(u8, protocol.max_frame_size);
        defer self.allocator.free(buffer);
        while (n.WaitForSingleObject(self.stop, 0) == 258) {
            if (!self.peer.?.alive()) return error.PeerExited;
            // Reserve storage BEFORE consuming a record, so allocation failure
            // cannot silently discard an authenticated duplicated-handle offer.
            const owned = try self.allocator.create(protocol.Packet);
            var submitted = false;
            defer if (!submitted) self.allocator.destroy(owned);
            const bytes = n.readMessage(self.pipe.?, buffer, self.stop, n.Deadline.init(1000)) catch |err| {
                if (err == error.Timeout) continue;
                return err;
            };
            try protocol.decodeInto(bytes, owned);
            const packet = owned;
            if (packet.sender_epoch != self.peer.?.epoch or packet.recipient_epoch != self.local_epoch) return error.WrongPeer;
            if (packet.body == .mapping_offer) {
                const offer = packet.body.mapping_offer;
                if (!std.meta.eql(offer.source, self.peer.?.facts.identity.process) or !std.meta.eql(offer.target, self.local_process)) return error.WrongPeer;
            }
            if (packet.body != .acknowledgement) {
                self.lock();
                const admission = self.ledger.admit(packet, bytes) catch |err| {
                    self.unlock();
                    return err;
                };
                self.unlock();
                switch (admission) {
                    .fresh => {},
                    .pending => continue,
                    .complete => |record| {
                        try self.ack(record);
                        continue;
                    },
                }
            }
            if (packet.body == .mapping_offer) {
                // A new request id must not cause a second consumption of an
                // already accepted numeric handle. Offer IDs never reset within
                // this authenticated pipe session.
                if (packet.body.mapping_offer.offer_id <= self.highest_offer_id) return error.RepeatedOffer;
                self.highest_offer_id = packet.body.mapping_offer.offer_id;
            }
            while (n.WaitForSingleObject(self.stop, 0) == 258) {
                self.lock();
                if (self.in_len < self.incoming.len) {
                    self.incoming[(self.in_head + self.in_len) % self.incoming.len] = owned;
                    self.in_len += 1;
                    submitted = true;
                    self.unlock();
                    self.wake();
                    break;
                }
                self.unlock();
                const events = [_]n.HANDLE{ self.stop, self.incoming_changed };
                _ = n.WaitForMultipleObjects(events.len, &events, 0, 1000);
            }
            if (!submitted) {
                // Preserve the single in-flight packet during shutdown, notably
                // duplicated mapping handles that the GUI must accept/reject.
                self.lock();
                self.stopped_input = owned;
                self.unlock();
                submitted = true;
            }
        }
    }
    fn writeLoop(self: *Connection) void {
        while (n.WaitForSingleObject(self.stop, 0) == 258) {
            self.lock();
            self.collectAcks() catch |err| {
                self.failure = @intFromError(err);
                self.unlock();
                self.shutdown();
                return;
            };
            const notify_gui = self.collectFrames() catch |err| {
                self.failure = @intFromError(err);
                self.unlock();
                self.shutdown();
                return;
            };
            const bytes = if (self.out_len != 0) block: {
                const value = self.outgoing[self.out_head].?;
                self.outgoing[self.out_head] = null;
                self.out_head = (self.out_head + 1) % self.outgoing.len;
                self.out_len -= 1;
                self.writing = true;
                break :block value;
            } else null;
            self.unlock();
            if (notify_gui) self.wake();
            if (bytes) |value| {
                defer self.allocator.free(value);
                n.write(self.pipe.?, value, self.stop, n.Deadline.init(10000)) catch |err| {
                    self.lock();
                    self.failure = @intFromError(err);
                    self.unlock();
                    self.shutdown();
                    return;
                };
                self.lock();
                self.writing = false;
                self.unlock();
                self.wake(); // GUI may retry a full outgoing queue.
            } else {
                const events = [_]n.HANDLE{ self.stop, self.changed };
                _ = n.WaitForMultipleObjects(events.len, &events, 0, 1000);
            }
        }
    }
    fn destroy(self: *Connection) !void {
        self.shutdown();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.references.load(.acquire) != 1 or self.in_len != 0 or self.stopped_input != null) return error.Busy;
        if (self.peer) |*peer| peer.deinit();
        for (self.outgoing) |entry| if (entry) |bytes| self.allocator.free(bytes);
        if (self.pipe) |pipe| {
            if (self.server_side) _ = n.DisconnectNamedPipe(pipe);
            _ = n.CloseHandle(pipe);
        }
        _ = n.CloseHandle(self.incoming_changed);
        _ = n.CloseHandle(self.changed);
        _ = n.CloseHandle(self.stop);
        self.allocator.destroy(self);
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
    epoch: u128,
    stop: n.HANDLE,
    listener: n.HANDLE,
    hwnd: ?std.os.windows.HWND = null,
    message: u32 = 0,
    control: std.os.windows.SRWLOCK = .{},
    connections: [max_connections]?*Connection = @splat(null),
    thread: ?std.Thread = null,
    failure: std.atomic.Value(u16) = .init(0),
    pub fn create(alloc: std.mem.Allocator, isolation: security.policy.Isolation, epoch: u128) !*Service {
        if (epoch == 0) return error.InvalidEpoch;
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const endpoint = try Endpoint.init(isolation, local.identity, local.identity.process);
        const listener = try makePipe(&endpoint, true);
        errdefer _ = n.CloseHandle(listener);
        const stop = try n.event();
        errdefer _ = n.CloseHandle(stop);
        const self = try alloc.create(Service);
        self.* = .{ .allocator = alloc, .endpoint = endpoint, .epoch = epoch, .stop = stop, .listener = listener };
        return self;
    }
    pub fn start(self: *Service, hwnd: std.os.windows.HWND, message: u32) !void {
        if (self.thread != null) return error.AlreadyStarted;
        self.hwnd = hwnd;
        self.message = message;
        self.thread = try std.Thread.spawn(.{}, listen, .{self});
    }
    fn lock(self: *Service) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.control);
    }
    fn unlock(self: *Service) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.control);
    }
    fn add(self: *Service, connection: *Connection) !void {
        self.lock();
        defer self.unlock();
        if (n.WaitForSingleObject(self.stop, 0) != 258) return error.Closed;
        for (&self.connections) |*slot| if (slot.* == null) {
            slot.* = connection;
            return;
        };
        return error.QueueFull;
    }
    /// Caller provides a PID AND creation time from target discovery, not a title.
    /// Returns before connecting; only the connected Work permits mapping export.
    pub fn connect(self: *Service, target: security.policy.Process) !*Connection {
        const hwnd = self.hwnd orelse return error.NotReady;
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const endpoint = try Endpoint.init(self.endpoint.isolation, local.identity, target);
        const connection = try Connection.create(self.allocator, endpoint, self.epoch, null, false, hwnd, self.message);
        errdefer connection.destroy() catch unreachable;
        try self.add(connection);
        connection.launch() catch |err| {
            self.remove(connection);
            return err;
        };
        return connection;
    }
    fn remove(self: *Service, connection: *Connection) void {
        self.lock();
        defer self.unlock();
        for (&self.connections) |*slot| if (slot.* == connection) {
            slot.* = null;
            return;
        };
    }
    pub fn take(self: *Service) ?Work {
        self.lock();
        defer self.unlock();
        for (self.connections) |slot| if (slot) |connection| if (connection.take()) |work| return work;
        return null;
    }
    /// Reap only after disconnected was consumed and every Work released.
    pub fn reap(self: *Service) void {
        self.lock();
        defer self.unlock();
        for (&self.connections) |*slot| if (slot.*) |connection| {
            connection.lock();
            const ready = connection.ended and connection.reported_ended and connection.in_len == 0 and connection.stopped_input == null and connection.references.load(.acquire) == 1;
            connection.unlock();
            if (ready) {
                connection.destroy() catch continue;
                slot.* = null;
            }
        };
    }
    pub fn shutdown(self: *Service) void {
        _ = n.SetEvent(self.stop);
        self.lock();
        defer self.unlock();
        for (self.connections) |slot| if (slot) |connection| connection.shutdown();
    }
    /// Drain/release queued Work first. Busy leaves the service alive for retry;
    /// in particular mapping offers must not be silently discarded at shutdown.
    pub fn destroy(self: *Service) !void {
        self.shutdown();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        for (&self.connections) |*slot| if (slot.*) |connection| {
            try connection.destroy();
            slot.* = null;
        };
        _ = n.CloseHandle(self.listener);
        _ = n.CloseHandle(self.stop);
        self.allocator.destroy(self);
    }
    fn listen(self: *Service) void {
        while (n.WaitForSingleObject(self.stop, 0) == 258) {
            n.connect(self.listener, self.stop) catch |err| {
                if (err != error.Timeout and err != error.Cancelled) self.failure.store(@intFromError(err), .release);
                _ = n.DisconnectNamedPipe(self.listener);
                continue;
            };
            const replacement = makePipe(&self.endpoint, false) catch |err| {
                self.failure.store(@intFromError(err), .release);
                _ = n.DisconnectNamedPipe(self.listener);
                continue;
            };
            const accepted = self.listener;
            self.listener = replacement;
            const connection = Connection.create(self.allocator, self.endpoint, self.epoch, accepted, true, self.hwnd.?, self.message) catch |err| {
                self.failure.store(@intFromError(err), .release);
                _ = n.CloseHandle(accepted);
                continue;
            };
            self.add(connection) catch {
                connection.destroy() catch unreachable;
                continue;
            };
            connection.launch() catch |err| {
                self.failure.store(@intFromError(err), .release);
                self.remove(connection);
                connection.destroy() catch unreachable;
            };
        }
    }
};
fn makePipe(endpoint: *const Endpoint, first: bool) !n.HANDLE {
    const descriptor = try security.Descriptor.init();
    defer descriptor.deinit();
    var attributes = descriptor.attributes();
    const pipe = n.CreateNamedPipeW(&endpoint.name, 0x40000003 | @as(u32, if (first) 0x80000 else 0), 14, max_connections + 1, protocol.max_frame_size, protocol.max_frame_size, 1000, &attributes);
    if (pipe == n.INVALID) return error.CreatePipeFailed;
    return pipe;
}
fn open(endpoint: *const Endpoint, stop: n.HANDLE) !n.HANDLE {
    const deadline = n.Deadline.init(10000);
    while (deadline.remaining() != 0 and n.WaitForSingleObject(stop, 0) == 258) {
        const pipe = n.CreateFileW(&endpoint.name, 0xc0000000, 0, null, 3, 0x40110000, null);
        if (pipe != n.INVALID) {
            const mode: u32 = 2;
            if (n.SetNamedPipeHandleState(pipe, &mode, null, null) == 0) {
                _ = n.CloseHandle(pipe);
                return error.PipeModeFailed;
            }
            return pipe;
        }
        switch (n.GetLastError()) {
            2, 231 => {
                _ = n.WaitNamedPipeW(&endpoint.name, @min(deadline.remaining(), 100));
                _ = n.WaitForSingleObject(stop, 10);
            },
            else => return error.OpenPipeFailed,
        }
    }
    return error.Timeout;
}

test "remote control ledger records GUI completion and rejects reused conflicting request ids" {
    var ledger: Ledger = .{};
    const packet: protocol.Packet = .{ .sender_epoch = 1, .recipient_epoch = 2, .request_id = 1, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 3, .generation = 4 }, .body = .query };
    try std.testing.expect((try ledger.admit(&packet, "request")) == .fresh);
    try std.testing.expect((try ledger.admit(&packet, "request")) == .pending);
    try std.testing.expectError(error.RequestConflict, ledger.admit(&packet, "changed"));
    _ = try ledger.finish(1, .completed, 0, 0);
    try std.testing.expect((try ledger.admit(&packet, "request")) == .complete);
    try std.testing.expectError(error.RequestConflict, ledger.finish(1, .rejected, 0, 0));
}

test "remote completed acknowledgements remain owned until writer admission" {
    var ledger: Ledger = .{};
    var packet: protocol.Packet = .{ .sender_epoch = 1, .recipient_epoch = 2, .request_id = 1, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 3, .generation = 4 }, .body = .query };
    for (1..ledger.records.len + 1) |id| {
        packet.request_id = id;
        _ = try ledger.admit(&packet, "request");
        _ = try ledger.finish(id, .completed, 0, 0);
    }
    packet.request_id += 1;
    try std.testing.expectError(error.QueueFull, ledger.admit(&packet, "request"));
    ledger.records[0].?.ack_pending = false;
    try std.testing.expect((try ledger.admit(&packet, "request")) == .fresh);
}

test "remote endpoint binds target birth and rejects pid reuse in its namespace" {
    const isolation: security.policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    const identity: security.policy.Identity = .{ .process = .{ .pid = 1, .birth = 2 }, .sid = @splat(5), .logon_id = 6, .session_id = 7, .integrity = .medium, .elevated = false };
    const one = try Endpoint.init(isolation, identity, .{ .pid = 100, .birth = 200 });
    const reused = try Endpoint.init(isolation, identity, .{ .pid = 100, .birth = 201 });
    try std.testing.expect(!std.mem.eql(u16, &one.name, &reused.name));
    try std.testing.expectError(error.InvalidIdentity, Endpoint.init(isolation, identity, .{ .pid = 0, .birth = 201 }));
}
test "remote service production entrypoints compile without starting pipes" {
    inline for (.{ &Service.create, &Service.start, &Service.connect, &Service.take, &Service.reap, &Service.destroy, &Connection.send, &Connection.finish, &Work.release }) |function| try std.testing.expect(@intFromPtr(function) != 0);
}

test "persistent native remote pipe authenticates twice and ACK waits for GUI completion" {
    const NativeTest = struct {
        extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?std.os.windows.HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?std.os.windows.HWND;
        extern "user32" fn DestroyWindow(std.os.windows.HWND) callconv(.winapi) i32;
        fn discard(connection: *Connection) void {
            while (connection.take()) |value| {
                var work = value;
                work.release();
            }
        }
        fn waitPacket(connection: *Connection, service: ?*Service) !Work {
            const deadline = n.Deadline.init(5000);
            while (deadline.remaining() != 0) {
                const found = if (service) |host| host.take() else connection.take();
                if (found) |value| {
                    var work = value;
                    if (work.event == .packet) return work;
                    const failed = work.event == .disconnected;
                    work.release();
                    if (failed) return error.UnexpectedDisconnect;
                }
                _ = n.WaitForSingleObject(connection.stop, 1);
            }
            return error.TestTimeout;
        }
    };
    const hwnd = NativeTest.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("GX remote native contract"), 0, 0, 0, 0, 0, @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))), null, null, null) orelse return error.TestWindowFailed;
    defer _ = NativeTest.DestroyWindow(hwnd);
    const epoch = try n.epoch();
    var isolation: security.policy.Isolation = .{ .config_root = @splat(0), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    std.mem.writeInt(u128, isolation.config_root[0..16], epoch, .little);
    const service = try Service.create(std.testing.allocator, isolation, epoch);
    defer {
        service.shutdown();
        if (service.thread) |thread| {
            thread.join();
            service.thread = null;
        }
        for (service.connections) |slot| if (slot) |connection| {
            if (connection.thread) |thread| {
                thread.join();
                connection.thread = null;
            }
            NativeTest.discard(connection);
        };
        service.destroy() catch unreachable;
    }
    try service.start(hwnd, 0x8070);
    const client_epoch = try n.epoch();
    const client = try Connection.create(std.testing.allocator, service.endpoint, client_epoch, null, false, hwnd, 0x8070);
    defer {
        client.shutdown();
        if (client.thread) |thread| {
            thread.join();
            client.thread = null;
        }
        NativeTest.discard(client);
        client.destroy() catch unreachable;
    }
    try client.launch();
    const deadline = n.Deadline.init(5000);
    var connected = false;
    while (deadline.remaining() != 0) {
        if (client.take()) |value| {
            var work = value;
            defer work.release();
            if (work.event == .disconnected) return error.UnexpectedDisconnect;
            if (work.event == .connected) {
                try std.testing.expectEqual(epoch, work.peer().epoch);
                connected = true;
                break;
            }
        }
        _ = n.WaitForSingleObject(client.stop, 1);
    }
    try std.testing.expect(connected);
    var packet: protocol.Packet = .{ .sender_epoch = client_epoch, .recipient_epoch = epoch, .request_id = 1, .ticket = .{ .source_epoch = client_epoch, .target_epoch = epoch, .transaction = 1, .generation = 2 }, .body = .query };
    for (1..4) |request_id| {
        packet.request_id = request_id;
        try client.send(&packet);
        var work = try NativeTest.waitPacket(client, service);
        defer work.release();
        try std.testing.expectEqual(client_epoch, work.peer().epoch);
        try std.testing.expectEqual(@as(u64, request_id), work.event.packet.request_id);
        try std.testing.expect(client.take() == null); // No pre-execution ACK.
        try work.connection.finish(&work, .completed);
        var reply = try NativeTest.waitPacket(client, null);
        defer reply.release();
        try std.testing.expectEqual(protocol.Outcome.completed, reply.event.packet.body.acknowledgement.outcome);
        try std.testing.expectEqual(@as(u64, request_id), reply.event.packet.request_id);
    }
    // The numeric mapping offer and its receipt traverse this very connection,
    // and accept gets the OS facts returned by its authenticated handshake.
    const source = try channel.Channel.createSource(std.testing.allocator, try channel.Layout.checked(4, 3, 16), 2, client_epoch, &client.peer.?);
    defer source.deinit() catch unreachable;
    var exported = try source.exportToPeer();
    defer exported.deinit() catch unreachable;
    packet.request_id = 4;
    packet.body = .{ .mapping_offer = mappingOffer(.{ .epoch = client_epoch, .kind = .surface, .id = 10, .generation = 1 }, 1, exported.offer) };
    try client.send(&packet);
    var mapping_work = try NativeTest.waitPacket(client, service);
    defer mapping_work.release();
    const target = try channel.Channel.accept(std.testing.allocator, nativeOffer(mapping_work.event.packet.body.mapping_offer), epoch, mapping_work.peer());
    defer target.deinit() catch unreachable;
    try mapping_work.connection.finish(&mapping_work, .completed);
    var mapping_reply = try NativeTest.waitPacket(client, null);
    defer mapping_reply.release();
    const receipt = mapping_reply.event.packet.body.acknowledgement;
    try std.testing.expectEqual(@as(u64, 1), receipt.offer_id);
    try exported.acknowledge(&client.peer.?, 2, receipt.target_handle);
    var sequence: std.atomic.Value(u64) = .init(0);
    var requested: std.atomic.Value(u64) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    const surface = packet.body.mapping_offer.surface;
    try client.watchFrame(.{ .surface = surface, .ticket = packet.ticket, .generation = 2, .sequence = &sequence, .requested_size = &requested, .failed = &failed });
    defer client.unwatchFrame(surface);
    sequence.store(1, .release);
    _ = n.SetEvent(client.frameWakeHandle());
    const gui_id = try client.sendBody(packet.ticket, .query);
    var previous_id: u64 = 4;
    var frames: usize = 0;
    var queries: usize = 0;
    for (0..2) |_| {
        var next = try NativeTest.waitPacket(client, service);
        defer next.release();
        try std.testing.expect(next.event.packet.request_id > previous_id);
        previous_id = next.event.packet.request_id;
        switch (next.event.packet.body) {
            .frame_ready => |frame| {
                frames += 1;
                try std.testing.expectEqual(@as(u64, 1), frame.sequence);
            },
            .query => {
                queries += 1;
                try std.testing.expectEqual(gui_id, next.event.packet.request_id);
            },
            else => return error.UnexpectedPacket,
        }
        try next.connection.finish(&next, .completed);
        var response = try NativeTest.waitPacket(client, null);
        response.release();
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
    try std.testing.expectEqual(@as(usize, 1), queries);
    requested.store(@as(u64, 480) << 32 | 640, .release);
    _ = n.SetEvent(client.frameWakeHandle());
    const resize_deadline = n.Deadline.init(5000);
    var resized = false;
    while (resize_deadline.remaining() != 0) {
        if (client.take()) |value| {
            var next = value;
            defer next.release();
            try std.testing.expect(next.event == .resize_needed);
            try std.testing.expectEqual(@as(u32, 640), next.event.resize_needed.width);
            try std.testing.expectEqual(@as(u32, 480), next.event.resize_needed.height);
            resized = true;
            break;
        }
        _ = n.WaitForSingleObject(client.stop, 1);
    }
    try std.testing.expect(resized);
    client.unwatchFrame(surface);
    // A consumer-held Work survives connection shutdown and prevents teardown.
    mapping_work.connection.shutdown();
    try std.testing.expectError(error.Busy, mapping_work.connection.destroy());
    try std.testing.expectEqual(client_epoch, mapping_work.peer().epoch);
}

test "frame collection OOM does not consume sequence or allocate request id" {
    var sequence: std.atomic.Value(u64) = .init(1);
    var requested: std.atomic.Value(u64) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    var connection: Connection = .{
        .allocator = std.testing.failing_allocator,
        .endpoint = undefined,
        .local_epoch = 1,
        .pipe = null,
        .server_side = false,
        .stop = undefined,
        .changed = undefined,
        .incoming_changed = undefined,
        .hwnd = undefined,
        .message = 0,
        .peer = .{ .facts = undefined, .epoch = 2, .isolation = undefined },
        .connected = true,
    };
    connection.watches[0] = .{ .source = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 }, .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 1, .generation = 2 }, .generation = 2, .sequence = &sequence, .requested_size = &requested, .failed = &failed } };
    try std.testing.expectError(error.OutOfMemory, connection.collectFrames());
    try std.testing.expectEqual(@as(u64, 0), connection.sent_high_water);
    try std.testing.expectEqual(@as(u64, 0), connection.watches[0].?.sequence);
    try std.testing.expectEqual(@as(usize, 0), connection.out_len);
    connection.unwatchFrame(connection.watches[0].?.source.surface);
    try std.testing.expect(connection.watches[0] == null);
}
