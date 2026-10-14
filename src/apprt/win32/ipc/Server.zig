//! One cancellable pipe worker. Only owned queue bytes cross to the GUI.
//! start/take/finish/shutdown/destroy are GUI-owned; destroy must occur after
//! all nested GUI work has called finish, including work in modal loops.
const Self = @This();
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
const wire = @import("wire.zig");
const queue_module = @import("../../../gx/ipc/queue.zig");
const protocol = wire.protocol;
pub const Work = queue_module.Work;
pub const Outcome = protocol.Outcome;

allocator: std.mem.Allocator,
endpoint: wire.Endpoint,
pipe: n.HANDLE,
stop: n.HANDLE,
changed: n.HANDLE,
thread: ?std.Thread = null,
control: std.os.windows.SRWLOCK = .{},
queue: queue_module.Queue,
hwnd: ?std.os.windows.HWND = null,
message: u32 = 0,
peers: [64]?Binding = @splat(null),
last_error: std.atomic.Value(u16) = .init(0),

const Binding = struct { epoch: u128, facts: security.Facts };

/// Takes ownership of pipe only on success.
pub fn create(allocator: std.mem.Allocator, endpoint: wire.Endpoint, epoch: u128, pipe: n.HANDLE) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const stop = try n.event();
    errdefer _ = n.CloseHandle(stop);
    // Auto-reset event: a finish wakes the worker without a polling spin.
    const changed = n.CreateEventW(null, 0, 0, null) orelse return error.EventFailed;
    errdefer _ = n.CloseHandle(changed);
    self.* = .{
        .allocator = allocator,
        .endpoint = endpoint,
        .pipe = pipe,
        .stop = stop,
        .changed = changed,
        .queue = try queue_module.Queue.init(allocator, epoch),
    };
    return self;
}

pub fn start(self: *Self, hwnd: std.os.windows.HWND, message: u32) !void {
    if (self.thread != null) return error.AlreadyStarted;
    self.hwnd = hwnd;
    self.message = message;
    try self.queue.setReady();
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
        self.queue.shutdown();
        return err;
    };
}

pub fn take(self: *Self) ?Work {
    self.lock();
    defer self.unlock();
    return self.queue.take();
}

pub fn finish(self: *Self, key: protocol.Key, outcome: Outcome) !void {
    self.lock();
    defer self.unlock();
    try self.queue.finish(key, outcome);
    _ = n.SetEvent(self.changed);
}

pub fn shutdown(self: *Self) void {
    self.lock();
    self.queue.shutdown();
    self.unlock();
    _ = n.SetEvent(self.stop);
}

pub fn destroy(self: *Self) void {
    self.shutdown();
    if (self.thread) |thread| thread.join();
    self.queue.deinit();
    for (self.peers) |binding| if (binding) |peer| peer.facts.deinit();
    _ = n.CloseHandle(self.pipe);
    _ = n.CloseHandle(self.changed);
    _ = n.CloseHandle(self.stop);
    const allocator = self.allocator;
    allocator.destroy(self);
}

fn lock(self: *Self) void {
    std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.control);
}
fn unlock(self: *Self) void {
    std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.control);
}

fn run(self: *Self) void {
    while (n.WaitForSingleObject(self.stop, 0) == 258) {
        n.connect(self.pipe, self.stop) catch |err| {
            if (err != error.Timeout and err != error.Cancelled) self.last_error.store(@intFromError(err), .release);
            _ = n.DisconnectNamedPipe(self.pipe);
            continue;
        };
        self.serve() catch |err| self.last_error.store(@intFromError(err), .release);
        _ = n.DisconnectNamedPipe(self.pipe);
    }
}

fn serve(self: *Self) !void {
    const deadline = n.Deadline.init(10000);
    const local = try security.inspect(n.GetCurrentProcessId());
    defer local.deinit();
    const peer = try security.pipePeer(self.pipe, true);
    var retained = false;
    defer if (!retained) peer.deinit();
    // Authenticate OS facts before sending any handshake data.
    try security.policy.authenticate(local.identity, peer.identity, peer.identity.process, self.endpoint.isolation, self.endpoint.isolation, false);
    try security.verifyImage(local, peer);
    var hello: [wire.hello_size]u8 = undefined;
    wire.hello(&hello, self.queue.host_epoch, local.identity, self.endpoint.isolation);
    try n.write(self.pipe, &hello, self.stop, deadline);
    if ((try n.readMessage(self.pipe, &hello, self.stop, deadline)).len != hello.len) return error.InvalidHandshake;
    const sender_epoch = try wire.verifyHello(&hello, local, peer, self.endpoint.isolation);
    retained = try self.bindPeer(sender_epoch, peer);
    var buffer: [protocol.max_frame_size]u8 = undefined;
    const frame = try wire.readFrame(self.pipe, &buffer, self.stop, deadline);
    if (n.WaitForSingleObject(peer.process, 0) != 258) return error.ProcessExited;
    self.lock();
    const admission = self.queue.submit(sender_epoch, frame) catch |err| {
        self.unlock();
        return switch (err) {
            error.Full, error.NotReady, error.OutOfMemory => self.sendOutcome(frame.key, .unavailable, deadline),
            error.ShuttingDown => self.sendOutcome(frame.key, .cancelled, deadline),
            error.RequestConflict => self.sendOutcome(frame.key, .rejected, deadline),
            else => err,
        };
    };
    self.unlock();
    if (admission == .accepted) {
        if (n.PostMessageW(self.hwnd.?, self.message, 0, 0) == 0) {
            // No GUI target means this server cannot truthfully execute work.
            self.shutdown();
            return error.PostFailed;
        }
    }
    while (true) {
        self.lock();
        const outcome = self.queue.acknowledgement(frame.key);
        self.unlock();
        if (outcome) |result| {
            return self.sendOutcome(frame.key, result, deadline);
        }
        const events = [_]n.HANDLE{ self.changed, self.stop };
        switch (n.WaitForMultipleObjects(2, &events, 0, deadline.remaining())) {
            0 => {},
            1 => return error.Cancelled,
            else => return error.Timeout,
        }
    }
}

fn sendOutcome(self: *Self, key: protocol.Key, outcome: Outcome, deadline: n.Deadline) !void {
    var buffer: [protocol.max_frame_size]u8 = undefined;
    const bytes = try protocol.encode(&buffer, .{ .key = key, .message = .{ .acknowledgement = outcome } });
    try n.write(self.pipe, bytes, self.stop, deadline);
    // DisconnectNamedPipe discards unread outbound bytes. The receipt proves
    // the client consumed the ACK without an unbounded FlushFileBuffers call.
    var receipt: [1]u8 = undefined;
    if ((try n.readMessage(self.pipe, &receipt, self.stop, deadline)).len != 1 or receipt[0] != 1)
        return error.InvalidReceipt;
}

/// Worker-owned binding table; retained process handles distinguish PID reuse.
/// The queue lock only covers model changes, never process queries or pipe I/O.
fn bindPeer(self: *Self, epoch: u128, facts: security.Facts) !bool {
    for (&self.peers) |*slot| if (slot.*) |binding| {
        if (n.WaitForSingleObject(binding.facts.process, 0) == 0) {
            self.lock();
            const reclaimed = if (self.queue.forgetExitedPeer(binding.epoch)) |_| true else |_| false;
            self.unlock();
            if (reclaimed) {
                binding.facts.deinit();
                slot.* = null;
                continue;
            }
        }
        if (std.meta.eql(binding.facts.identity.process, facts.identity.process)) {
            if (binding.epoch != epoch) return error.EpochMismatch;
            return false;
        }
        if (binding.epoch == epoch) return error.EpochMismatch;
    };
    for (&self.peers) |*slot| {
        if (slot.* != null) continue;
        slot.* = .{ .epoch = epoch, .facts = facts };
        return true;
    }
    return error.PeerCapacity;
}
