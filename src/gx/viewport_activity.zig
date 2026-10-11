const std = @import("std");

pub const Pending = struct {
    accepting: bool = false,
    pending: bool = false,

    pub fn setAccepting(self: *Pending, accepting: bool) void {
        self.accepting = accepting;
        if (!accepting) self.pending = false;
    }

    pub fn record(self: *Pending, before: anytype, after: @TypeOf(before)) bool {
        if (!self.accepting or before.total != after.total or before.len != after.len or
            before.offset == after.offset or after.total <= after.len) return false;
        self.pending = true;
        return true;
    }

    pub fn take(self: *Pending) bool {
        const pending = self.pending;
        self.pending = false;
        return pending;
    }
};

test "D11: same values need mutation provenance, not a scrollbar report" {
    const State = struct { total: usize, offset: usize, len: usize };
    const before: State = .{ .total = 100, .offset = 50, .len = 24 };
    const after: State = .{ .total = 100, .offset = 49, .len = 24 };
    var activity: Pending = .{ .accepting = true };
    try std.testing.expect(!activity.take());
    try std.testing.expect(activity.record(before, after));
    try std.testing.expect(activity.take());
    try std.testing.expect(!activity.take());
}

test "D11: no movement, geometry changes, hidden and never do not wake" {
    const State = struct { total: usize, offset: usize, len: usize };
    const before: State = .{ .total = 100, .offset = 50, .len = 24 };
    var activity: Pending = .{ .accepting = true };
    for ([_]State{
        before,
        .{ .total = 101, .offset = 50, .len = 24 },
        .{ .total = 101, .offset = 51, .len = 24 },
        .{ .total = 100, .offset = 49, .len = 25 },
        .{ .total = 24, .offset = 0, .len = 24 },
    }) |after| try std.testing.expect(!activity.record(before, after));
    const after: State = .{ .total = 100, .offset = 49, .len = 24 };
    try std.testing.expect(activity.record(before, after));
    activity.setAccepting(false);
    try std.testing.expect(!activity.take());
    try std.testing.expect(!activity.record(before, after));
    activity.setAccepting(true);
    try std.testing.expect(!activity.take());
}

test "D11: round trips coalesce but movement after taking wakes again" {
    const State = struct { total: usize, offset: usize, len: usize };
    const before: State = .{ .total = 100, .offset = 50, .len = 24 };
    const after: State = .{ .total = 100, .offset = 49, .len = 24 };
    var activity: Pending = .{ .accepting = true };
    try std.testing.expect(activity.record(before, after));
    try std.testing.expect(activity.record(after, before));
    activity.setAccepting(true);
    try std.testing.expect(activity.take());
    try std.testing.expect(!activity.take());
    try std.testing.expect(activity.record(before, after));
    try std.testing.expect(activity.take());
}
