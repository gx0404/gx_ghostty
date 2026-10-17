//! Bounded remote pixels and source-authoritative input leases. Transport must
//! authenticate peer epochs before using these values; none are credentials.
const std = @import("std");
pub const header_bytes: usize = 256;
pub const max_dimension: u32 = 16384;
pub const max_frame_bytes: u32 = 128 * 1024 * 1024;
pub const slot_count = 2;

/// Target-local input identity, independent of transport renumbering. QPC is
/// comparable across processes on the same Windows host. Both zero means off.
pub const InputStamp = struct {
    sequence: u64 = 0,
    qpc: u64 = 0,

    pub fn valid(self: InputStamp) bool {
        return (self.sequence == 0) == (self.qpc == 0) and self.qpc <= std.math.maxInt(i64);
    }
};

/// BGRA8 pixels, top row first. One immutable layout per mapping generation;
/// resize creates another mapping instead of mutating a reader's dimensions.
pub const Layout = struct {
    width: u32,
    height: u32,
    stride: u32,
    frame_bytes: u32,
    slot_bytes: u32,
    total_bytes: usize,

    pub fn checked(width: u32, height: u32, stride: u32) !Layout {
        if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidDimensions;
        const row = @as(u64, width) * 4;
        if (stride % 4 != 0 or stride < row or stride > row + 4096) return error.InvalidStride;
        const size = @as(u64, stride) * height;
        if (size > max_frame_bytes) return error.CapacityExceeded;
        const padded = std.mem.alignForward(u64, size, 64);
        return .{ .width = width, .height = height, .stride = stride, .frame_bytes = @intCast(size), .slot_bytes = @intCast(padded), .total_bytes = @intCast(header_bytes + padded * slot_count) };
    }
    pub fn offset(self: Layout, index: u1) usize {
        return header_bytes + @as(usize, index) * self.slot_bytes;
    }
};

pub const Ticket = struct { source_epoch: u128, target_epoch: u128, transaction: u64, generation: u64 };
pub const InputLease = struct { holder_epoch: u128, generation: u64, transaction: u64 };
pub const Phase = enum { preparing, ready, committed, target_enabled, remote, aborted, reclaimed, source_lost };
pub const Status = struct { ticket: Ticket, phase: Phase, source_ready: bool = false, target_ready: bool = false };
pub const Error = error{ InvalidEpoch, InvalidTransaction, StaleTransaction, Busy, UnknownTransaction, UnauthorizedPeer, NotReady, NotCommitted, NotEnabled, AlreadyCommitted, Exhausted, SourceLost };

/// GUI/source-owner serialized state. A committed lease immediately rejects
/// source input, even while its old view remains visible waiting for the target
/// enable ACK. Thus lost ACKs never permit two input owners. The target queries
/// status after reconnect; it never replays an operation under a new ticket.
pub const SourceAuthority = struct {
    source_epoch: u128,
    issued_generation: u64 = 1,
    last_transaction: u64 = 0,
    input: ?InputLease,
    active: ?Status = null,
    completed: ?Status = null,
    stopped: bool = false,

    pub fn init(source_epoch: u128) Error!SourceAuthority {
        if (source_epoch == 0) return error.InvalidEpoch;
        return .{ .source_epoch = source_epoch, .input = .{ .holder_epoch = source_epoch, .generation = 1, .transaction = 0 } };
    }

    pub fn prepare(self: *SourceAuthority, target_epoch: u128, transaction: u64) Error!Ticket {
        if (self.stopped) return error.SourceLost;
        if (target_epoch == 0 or target_epoch == self.source_epoch) return error.InvalidEpoch;
        if (transaction == 0) return error.InvalidTransaction;
        if (self.active) |status| {
            if (status.ticket.transaction == transaction and status.ticket.target_epoch == target_epoch) return status.ticket;
            return error.Busy;
        }
        if (transaction <= self.last_transaction) return error.StaleTransaction;
        const generation = try self.nextGeneration();
        const ticket: Ticket = .{ .source_epoch = self.source_epoch, .target_epoch = target_epoch, .transaction = transaction, .generation = generation };
        self.active = .{ .ticket = ticket, .phase = .preparing };
        self.last_transaction = transaction;
        return ticket;
    }

    /// peer_epoch must be the independently authenticated connection identity.
    pub fn ready(self: *SourceAuthority, ticket: Ticket, peer_epoch: u128) Error!void {
        const status = try self.current(ticket);
        if (peer_epoch == self.source_epoch) status.source_ready = true else if (peer_epoch == ticket.target_epoch) status.target_ready = true else return error.UnauthorizedPeer;
        if (status.phase == .preparing and status.source_ready and status.target_ready) status.phase = .ready;
    }

    /// The return value is the single target input capability for this transfer.
    /// Source input stops here; source UI teardown happens only after enabled.
    pub fn commit(self: *SourceAuthority, ticket: Ticket) Error!InputLease {
        const status = try self.current(ticket);
        switch (status.phase) {
            .committed, .target_enabled, .remote => return self.input.?,
            .ready => {},
            else => return error.NotReady,
        }
        status.phase = .committed;
        self.input = .{ .holder_epoch = ticket.target_epoch, .generation = ticket.generation, .transaction = ticket.transaction };
        return self.input.?;
    }

    pub fn targetEnabled(self: *SourceAuthority, ticket: Ticket, peer_epoch: u128) Error!void {
        const status = try self.current(ticket);
        if (peer_epoch != ticket.target_epoch) return error.UnauthorizedPeer;
        switch (status.phase) {
            .committed => status.phase = .target_enabled,
            .target_enabled, .remote => {},
            else => return error.NotCommitted,
        }
    }

    /// Source GUI calls this only after actually revoking its visible view.
    pub fn sourceRevoked(self: *SourceAuthority, ticket: Ticket) Error!void {
        const status = try self.current(ticket);
        switch (status.phase) {
            .target_enabled => status.phase = .remote,
            .remote => {},
            else => return error.NotEnabled,
        }
    }

    pub fn query(self: *const SourceAuthority, ticket: Ticket) Error!Status {
        if (self.active) |status| if (std.meta.eql(status.ticket, ticket)) return status;
        if (self.completed) |status| if (std.meta.eql(status.ticket, ticket)) return status;
        return error.UnknownTransaction;
    }

    pub fn acceptsInput(self: *const SourceAuthority, lease: InputLease) bool {
        if (self.stopped) return false;
        const current_lease = self.input orelse return false;
        return lease.holder_epoch != 0 and std.meta.eql(current_lease, lease);
    }

    /// A prepare can be cancelled without changing the source's live lease.
    pub fn abort(self: *SourceAuthority, ticket: Ticket) Error!void {
        if (self.completed) |status| if (std.meta.eql(status.ticket, ticket) and status.phase == .aborted) return;
        const status = try self.current(ticket);
        if (status.phase != .preparing and status.phase != .ready) return error.AlreadyCommitted;
        self.complete(.aborted);
    }

    /// Source decides disconnection. A fresh generation invalidates both the
    /// old target lease and delayed source input from before the transfer.
    /// This never starts a replacement shell or reconstructs terminal output.
    pub fn disconnect(self: *SourceAuthority, ticket: Ticket) Error!void {
        if (self.completed) |status| if (std.meta.eql(status.ticket, ticket) and (status.phase == .aborted or status.phase == .reclaimed)) return;
        const status = try self.current(ticket);
        if (status.phase == .preparing or status.phase == .ready) return self.abort(ticket);
        self.input = null;
        const generation = self.nextGeneration() catch |err| {
            self.complete(.reclaimed);
            return err;
        };
        self.input = .{ .holder_epoch = self.source_epoch, .generation = generation, .transaction = 0 };
        self.complete(.reclaimed);
    }

    pub fn shutdown(self: *SourceAuthority) void {
        self.input = null;
        self.stopped = true;
        if (self.active != null) self.complete(.source_lost);
    }

    fn current(self: *SourceAuthority, ticket: Ticket) Error!*Status {
        if (self.stopped) return error.SourceLost;
        const status = if (self.active) |*value| value else return error.UnknownTransaction;
        if (!std.meta.eql(status.ticket, ticket)) return error.UnknownTransaction;
        return status;
    }
    fn nextGeneration(self: *SourceAuthority) Error!u64 {
        const next = std.math.add(u64, self.issued_generation, 1) catch return error.Exhausted;
        self.issued_generation = next;
        return next;
    }
    fn complete(self: *SourceAuthority, phase: Phase) void {
        self.completed = self.active;
        self.completed.?.phase = phase;
        self.active = null;
    }
};

test "remote view layout bounds BGRA stride dimensions and mapping capacity" {
    const layout = try Layout.checked(7680, 4320, 7680 * 4);
    try std.testing.expect(layout.frame_bytes <= max_frame_bytes);
    try std.testing.expectEqual(@as(usize, header_bytes), layout.offset(0));
    try std.testing.expectEqual(layout.total_bytes, layout.offset(1) + layout.slot_bytes);
    try std.testing.expectError(error.InvalidDimensions, Layout.checked(0, 1, 4));
    try std.testing.expectError(error.InvalidStride, Layout.checked(10, 1, 39));
    try std.testing.expectError(error.InvalidStride, Layout.checked(10, 1, 44_000));
    try std.testing.expectError(error.CapacityExceeded, Layout.checked(16384, 16384, 65536));
}

test "remote input transfer is idempotent and never has two input owners" {
    var authority = try SourceAuthority.init(11);
    const original = authority.input.?;
    const ticket = try authority.prepare(22, 1);
    try std.testing.expectEqualDeep(ticket, try authority.prepare(22, 1));
    try std.testing.expect(authority.acceptsInput(original));
    try std.testing.expectError(error.NotReady, authority.commit(ticket));
    try std.testing.expectError(error.UnauthorizedPeer, authority.ready(ticket, 33));
    try authority.ready(ticket, 11);
    try authority.ready(ticket, 22);
    const remote = try authority.commit(ticket);
    try std.testing.expect(!authority.acceptsInput(original));
    try std.testing.expect(authority.acceptsInput(remote));
    try std.testing.expectEqualDeep(remote, try authority.commit(ticket));
    try std.testing.expectEqual(Phase.committed, (try authority.query(ticket)).phase);
    try std.testing.expectError(error.NotEnabled, authority.sourceRevoked(ticket));
    try authority.targetEnabled(ticket, 22);
    try authority.sourceRevoked(ticket);
    try authority.sourceRevoked(ticket);
    try authority.disconnect(ticket);
    try authority.disconnect(ticket);
    try std.testing.expect(!authority.acceptsInput(remote));
    try std.testing.expect(!authority.acceptsInput(original));
    try std.testing.expect(authority.acceptsInput(authority.input.?));
    try std.testing.expectEqual(Phase.reclaimed, (try authority.query(ticket)).phase);
}

test "remote input abort does not reuse issued generations or resurrect tickets" {
    var authority = try SourceAuthority.init(1);
    const local = authority.input.?;
    const first = try authority.prepare(2, 1);
    try authority.abort(first);
    try authority.abort(first);
    try std.testing.expect(authority.acceptsInput(local));
    try std.testing.expectError(error.StaleTransaction, authority.prepare(2, 1));
    const second = try authority.prepare(2, 2);
    try std.testing.expect(second.generation > first.generation);
    try std.testing.expectError(error.UnknownTransaction, authority.commit(first));
    authority.shutdown();
    try std.testing.expect(!authority.acceptsInput(local));
    try std.testing.expectEqual(Phase.source_lost, (try authority.query(second)).phase);
    try std.testing.expectError(error.SourceLost, authority.prepare(2, 3));
}

test "remote input generation exhaustion fails closed on disconnect" {
    var authority = try SourceAuthority.init(1);
    const ticket = try authority.prepare(2, 1);
    try authority.ready(ticket, 1);
    try authority.ready(ticket, 2);
    const remote = try authority.commit(ticket);
    authority.issued_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.Exhausted, authority.disconnect(ticket));
    try std.testing.expect(!authority.acceptsInput(remote));
    try std.testing.expect(authority.input == null);
}
