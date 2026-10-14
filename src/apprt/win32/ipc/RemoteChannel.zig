//! Native shared-frame ownership. Offers are accepted ONLY on the same already
//! authenticated pipe session. A numeric handle is not an identity or ticket.
//! Peer process objects remain open to distinguish PID reuse during transfers.
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
const frames = @import("remote_frame.zig");
const policy = security.policy;
pub const Layout = frames.Layout;
const section_access: u32 = 0x0001 | 0x0002 | 0x0004; // QUERY, MAP_WRITE, MAP_READ
const SectionInfo = extern struct { base: ?*anyopaque, attributes: u32, maximum_size: i64 };
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) n.HANDLE;
extern "kernel32" fn CreateFileMappingW(n.HANDLE, ?*n.SA, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) ?n.HANDLE;
extern "kernel32" fn MapViewOfFile(n.HANDLE, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn DuplicateHandle(n.HANDLE, n.HANDLE, n.HANDLE, *n.HANDLE, u32, i32, u32) callconv(.winapi) i32;
extern "ntdll" fn NtQuerySection(n.HANDLE, u32, *SectionInfo, u32, ?*u32) callconv(.winapi) i32;
extern "ntdll" fn NtQueryObject(n.HANDLE, u32, *anyopaque, u32, ?*u32) callconv(.winapi) i32;

pub const BoundPeer = struct {
    facts: security.Facts,
    epoch: u128,
    isolation: policy.Isolation,

    /// expected and peer_isolation must be from the authenticated handshake,
    /// not from the mapping Offer. Re-read actual pipe PID/token on both ends.
    pub fn fromPipe(pipe: n.HANDLE, server_side: bool, expected: policy.Process, local_isolation: policy.Isolation, peer_isolation: policy.Isolation, epoch: u128) !BoundPeer {
        if (epoch == 0) return error.InvalidEpoch;
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const peer = try security.pipePeer(pipe, server_side);
        errdefer peer.deinit();
        try policy.authenticate(local.identity, peer.identity, expected, local_isolation, peer_isolation, false);
        try security.verifyImage(local, peer);
        return .{ .facts = peer, .epoch = epoch, .isolation = local_isolation };
    }
    pub fn deinit(self: *BoundPeer) void {
        self.facts.deinit();
        self.* = undefined;
    }
    pub fn alive(self: *const BoundPeer) bool {
        return n.WaitForSingleObject(self.facts.process, 0) == 258;
    }
    fn clone(self: *const BoundPeer) !BoundPeer {
        if (!self.alive()) return error.PeerExited;
        const fresh = try security.inspect(self.facts.identity.process.pid);
        errdefer fresh.deinit();
        if (!std.meta.eql(fresh.identity, self.facts.identity)) return error.PeerChanged;
        return .{ .facts = fresh, .epoch = self.epoch, .isolation = self.isolation };
    }
};

/// This is a value contract, not a wire struct (encode fields explicitly).
pub const Offer = struct {
    source: policy.Process,
    target: policy.Process,
    source_epoch: u128,
    target_epoch: u128,
    generation: u64,
    width: u32,
    height: u32,
    stride: u32,
    bytes: u64,
    target_handle: u64,
};

fn offerHandle(offer: Offer, local_epoch: u128, source_peer: *const BoundPeer) !n.HANDLE {
    if (source_peer.epoch != offer.source_epoch or !std.meta.eql(source_peer.facts.identity.process, offer.source)) return error.PeerChanged;
    const local = try security.inspect(n.GetCurrentProcessId());
    defer local.deinit();
    if (local_epoch == 0 or local_epoch != offer.target_epoch or !std.meta.eql(local.identity.process, offer.target)) return error.WrongRecipient;
    if (offer.target_handle == 0 or offer.target_handle > std.math.maxInt(usize) - 16) return error.InvalidHandle;
    const mapping: n.HANDLE = @ptrFromInt(@as(usize, @intCast(offer.target_handle)));
    var info: SectionInfo = undefined;
    if (NtQuerySection(mapping, 0, &info, @sizeOf(SectionInfo), null) < 0 or info.maximum_size < 0) return error.InvalidMapping;
    return mapping;
}

/// Reject a once-admitted offer on its authenticated pipe without mapping it.
/// Caller must enforce the same duplicate-offer ledger as Channel.accept.
/// Only this process's received section handle is closed, never a peer handle.
pub fn discardOffer(offer: Offer, local_epoch: u128, source_peer: *const BoundPeer) !void {
    const mapping = try offerHandle(offer, local_epoch, source_peer);
    if (n.CloseHandle(mapping) == 0) return error.CloseMappingFailed;
}

/// Tracks one bounded outbound duplication until explicit target acceptance or
/// verified process exit. Never DuplicateHandle(CLOSE_SOURCE) on a timeout: the
/// target may already have closed and reused that numeric handle.
pub const Export = struct {
    offer: Offer,
    peer: BoundPeer,
    acknowledged: bool = false,

    pub fn acknowledge(self: *Export, bound_target: *const BoundPeer, generation: u64, target_handle: u64) !void {
        if (!self.peer.alive() or !bound_target.alive()) return error.PeerExited;
        if (!std.meta.eql(bound_target.facts.identity.process, self.offer.target) or !std.meta.eql(bound_target.isolation, self.peer.isolation) or bound_target.epoch != self.offer.target_epoch or
            generation != self.offer.generation or target_handle != self.offer.target_handle) return error.InvalidAcknowledgement;
        self.acknowledged = true;
    }
    pub fn deinit(self: *Export) !void {
        if (!self.acknowledged and self.peer.alive()) return error.AwaitingAcknowledgement;
        self.peer.deinit();
        self.* = undefined;
    }

    /// Only the process-shutdown coordinator may abandon acknowledgement
    /// tracking. The recipient owns its duplicated handle; never close that
    /// numeric value from here, since it may already have been reused there.
    pub fn abandonLocalTrackingOnShutdown(self: *Export) void {
        self.peer.deinit();
        self.* = undefined;
    }
};

/// Address-stable and externally synchronized per local process. This wrapper
/// counts leases so shutdown cannot unmap bytes borrowed by render/present.
pub const Channel = struct {
    allocator: std.mem.Allocator,
    mapping: n.HANDLE,
    mapped: frames.Mapped,
    peer: BoundPeer,
    local_epoch: u128,
    source: bool,
    leases: usize = 0,
    closing: bool = false,
    exported: bool = false,

    pub fn createSource(allocator: std.mem.Allocator, layout: Layout, generation: u64, local_epoch: u128, target: *const BoundPeer) !*Channel {
        if (local_epoch == 0 or generation == 0) return error.InvalidEpoch;
        const checked = try Layout.checked(layout.width, layout.height, layout.stride);
        if (!std.meta.eql(checked, layout)) return error.InvalidLayout;
        var peer = try target.clone();
        errdefer peer.deinit();
        const descriptor = try security.Descriptor.init();
        defer descriptor.deinit();
        var attributes = descriptor.attributes();
        const mapping = CreateFileMappingW(n.INVALID, &attributes, 4, 0, @intCast(layout.total_bytes), null) orelse return error.MappingFailed;
        errdefer _ = n.CloseHandle(mapping);
        const pointer = MapViewOfFile(mapping, 0x0002 | 0x0004, 0, 0, layout.total_bytes) orelse return error.MapViewFailed;
        errdefer _ = UnmapViewOfFile(pointer);
        const bytes = @as([*]align(8) u8, @ptrCast(@alignCast(pointer)))[0..layout.total_bytes];
        const self = try allocator.create(Channel);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .mapping = mapping, .mapped = try frames.Mapped.initialize(bytes, layout, generation), .peer = peer, .local_epoch = local_epoch, .source = true };
        return self;
    }

    pub fn exportToPeer(self: *Channel) !Export {
        if (!self.source or self.closing or self.exported) return error.InvalidState;
        var peer = try self.peer.clone();
        errdefer peer.deinit();
        const duplicate_process = n.OpenProcess(0x00101040, 0, peer.facts.identity.process.pid) orelse return error.OpenProcessFailed;
        defer _ = n.CloseHandle(duplicate_process);
        var birth: u64 = 0;
        var unused: u64 = 0;
        if (n.GetProcessTimes(duplicate_process, &birth, &unused, &unused, &unused) == 0 or
            birth != peer.facts.identity.process.birth or n.WaitForSingleObject(duplicate_process, 0) != 258) return error.PeerChanged;
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        var target_handle: n.HANDLE = undefined;
        if (DuplicateHandle(GetCurrentProcess(), self.mapping, duplicate_process, &target_handle, section_access, 0, 0) == 0) return error.DuplicateFailed;
        self.exported = true;
        return .{ .peer = peer, .offer = .{
            .source = local.identity.process,
            .target = peer.facts.identity.process,
            .source_epoch = self.local_epoch,
            .target_epoch = peer.epoch,
            .generation = self.mapped.generation,
            .width = self.mapped.layout.width,
            .height = self.mapped.layout.height,
            .stride = self.mapped.layout.stride,
            .bytes = self.mapped.layout.total_bytes,
            .target_handle = @intFromPtr(target_handle),
        } };
    }

    /// Consumes the offered local handle once peer/recipient identity checks
    /// succeed, even on later validation failure. The authenticated transport
    /// sends an acceptance/rejection receipt and must reject duplicate offers.
    pub fn accept(allocator: std.mem.Allocator, offer: Offer, local_epoch: u128, source_peer: *const BoundPeer) !*Channel {
        var consumed = false;
        return acceptTracked(allocator, offer, local_epoch, source_peer, &consumed);
    }

    /// The receipt distinguishes rejection before ownership transfer from a
    /// mapping that was consumed and closed during later validation failure.
    pub fn acceptTracked(allocator: std.mem.Allocator, offer: Offer, local_epoch: u128, source_peer: *const BoundPeer, consumed: *bool) !*Channel {
        consumed.* = false;
        if (!source_peer.alive()) return error.PeerChanged;
        const mapping = try offerHandle(offer, local_epoch, source_peer);
        consumed.* = true;
        errdefer _ = n.CloseHandle(mapping);
        const layout = try Layout.checked(offer.width, offer.height, offer.stride);
        if (offer.bytes != layout.total_bytes) return error.MappingLength;
        var info: SectionInfo = undefined;
        if (NtQuerySection(mapping, 0, &info, @sizeOf(SectionInfo), null) < 0 or info.maximum_size < 0) return error.InvalidMapping;
        const capacity: u64 = @intCast(info.maximum_size);
        if (capacity < offer.bytes or capacity > std.mem.alignForward(u64, offer.bytes, 4096)) return error.MappingLength;
        const pointer = MapViewOfFile(mapping, 0x0002 | 0x0004, 0, 0, layout.total_bytes) orelse return error.MapViewFailed;
        errdefer _ = UnmapViewOfFile(pointer);
        const bytes = @as([*]align(8) u8, @ptrCast(@alignCast(pointer)))[0..layout.total_bytes];
        const mapped = try frames.Mapped.attach(bytes, offer.generation);
        if (!std.meta.eql(mapped.layout, layout)) return error.InvalidLayout;
        var peer = try source_peer.clone();
        errdefer peer.deinit();
        const self = try allocator.create(Channel);
        self.* = .{ .allocator = allocator, .mapping = mapping, .mapped = mapped, .peer = peer, .local_epoch = local_epoch, .source = false };
        return self;
    }

    pub fn beginWrite(self: *Channel) !Write {
        if (!self.source or self.closing or !self.peer.alive()) return error.ChannelUnavailable;
        const lease = try self.mapped.beginWrite();
        self.leases += 1;
        return .{ .channel = self, .lease = lease };
    }
    pub fn acquire(self: *Channel) !?Read {
        if (self.source or self.closing or !self.peer.alive()) return error.ChannelUnavailable;
        const lease = (try self.mapped.acquire()) orelse return null;
        self.leases += 1;
        return .{ .channel = self, .lease = lease };
    }
    pub fn close(self: *Channel) void {
        self.closing = true;
        if (self.source) self.mapped.close();
    }
    pub fn deinit(self: *Channel) !void {
        self.close();
        if (self.leases != 0) return error.Busy;
        _ = UnmapViewOfFile(self.mapped.bytes.ptr);
        _ = n.CloseHandle(self.mapping);
        self.peer.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const Write = struct {
    channel: *Channel,
    lease: frames.WriteLease,
    active: bool = true,
    pub fn publish(self: *Write, pixels: []const u8) !void {
        if (!self.active) return error.StaleLease;
        defer self.cancel();
        try self.lease.publishCopy(pixels);
    }
    pub fn cancel(self: *Write) void {
        if (!self.active) return;
        self.active = false;
        _ = self.lease.cancel();
        self.channel.leases -= 1;
    }
};
pub const Read = struct {
    channel: *Channel,
    lease: frames.ReadLease,
    active: bool = true,
    pub fn release(self: *Read) void {
        if (!self.active) return;
        self.active = false;
        _ = self.lease.release();
        self.channel.leases -= 1;
    }
};

test "remote channel native mapping duplicates restricted handles and pins borrowed frames" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(@intFromPtr(&BoundPeer.fromPipe) != 0);
    // Production constructs BoundPeer only via fromPipe. This native mapping
    // test binds both endpoints to the independently inspected test process.
    const isolation: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    var target_peer: BoundPeer = .{ .facts = try security.inspect(n.GetCurrentProcessId()), .epoch = 2, .isolation = isolation };
    defer target_peer.deinit();
    var source_peer: BoundPeer = .{ .facts = try security.inspect(n.GetCurrentProcessId()), .epoch = 1, .isolation = isolation };
    defer source_peer.deinit();
    const source = try Channel.createSource(std.testing.allocator, try Layout.checked(4, 2, 16), 7, 1, &target_peer);
    defer source.deinit() catch @panic("source lease leak");
    var exported = try source.exportToPeer();
    const target = try Channel.accept(std.testing.allocator, exported.offer, 2, &source_peer);
    var target_live = true;
    defer if (target_live) target.deinit() catch @panic("target lease leak");
    try exported.acknowledge(&target_peer, exported.offer.generation, exported.offer.target_handle);
    try exported.deinit();
    var basic: [56]u8 align(8) = @splat(0);
    try std.testing.expect(NtQueryObject(target.mapping, 0, &basic, basic.len, null) >= 0);
    // Verify actual GrantedAccess; requesting FILE_MAP_EXECUTE alone can be
    // ignored by MapViewOfFile and does not prove execute permission.
    try std.testing.expectEqual(section_access, std.mem.readInt(u32, basic[4..8], .little));
    var writing = try source.beginWrite();
    try writing.publish(&(@as([32]u8, @splat(0x77))));
    var reading = (try target.acquire()).?;
    try std.testing.expectEqual(@as(u8, 0x77), reading.lease.pixels[0]);
    try std.testing.expectError(error.Busy, target.deinit());
    try std.testing.expectEqual(@as(u8, 0x77), reading.lease.pixels[31]);
    reading.release();
    try target.deinit();
    target_live = false;
}

test "remote channel refuses wrong recipient before consuming handle and rejects false capacity" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const isolation: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    var target_peer: BoundPeer = .{ .facts = try security.inspect(n.GetCurrentProcessId()), .epoch = 2, .isolation = isolation };
    defer target_peer.deinit();
    var source_peer: BoundPeer = .{ .facts = try security.inspect(n.GetCurrentProcessId()), .epoch = 1, .isolation = isolation };
    defer source_peer.deinit();
    const source = try Channel.createSource(std.testing.allocator, try Layout.checked(4, 2, 16), 7, 1, &target_peer);
    defer source.deinit() catch @panic("source lease leak");
    var exported = try source.exportToPeer();
    const event = try n.event();
    defer _ = n.CloseHandle(event);
    var wrong_type = exported.offer;
    wrong_type.target_handle = @intFromPtr(event);
    try std.testing.expectError(error.InvalidMapping, discardOffer(wrong_type, 2, &source_peer));
    try std.testing.expectEqual(@as(u32, 258), n.WaitForSingleObject(event, 0));
    try std.testing.expectError(error.AwaitingAcknowledgement, exported.deinit());
    try std.testing.expectError(error.WrongRecipient, Channel.accept(std.testing.allocator, exported.offer, 3, &source_peer));
    var forged = exported.offer;
    forged.source.birth += 1;
    try std.testing.expectError(error.PeerChanged, Channel.accept(std.testing.allocator, forged, 2, &source_peer));
    forged = exported.offer;
    forged.bytes += 4096;
    try std.testing.expectError(error.MappingLength, Channel.accept(std.testing.allocator, forged, 2, &source_peer));
    // Validation failure after identity binding consumed/closed this handle.
    var info: SectionInfo = undefined;
    try std.testing.expect(NtQuerySection(@ptrFromInt(@as(usize, @intCast(exported.offer.target_handle))), 0, &info, @sizeOf(SectionInfo), null) < 0);
    try exported.acknowledge(&target_peer, exported.offer.generation, exported.offer.target_handle);
    try exported.deinit();
}
