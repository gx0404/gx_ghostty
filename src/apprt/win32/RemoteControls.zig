//! Opt-in, GUI-owned remote fixture controls. Negative results are explicit
//! failures; zero is a real counter value, never an unavailable snapshot.
const std = @import("std");
const protocol = @import("../../gx/remote_protocol.zig");
pub const query_message: u32 = 0x400 + 0x53;
pub const control_message: u32 = 0x400 + 0x54;
pub const magic: isize = 0x47585233; // GXR3, interface schema version 1.
pub const unavailable: isize = -2;
pub const invalid: isize = -1;
pub const Selector = enum(usize) {
    capability = 0,
    scrollback_total = 1,
    scrollback_viewport = 2,
    scrollback_offset = 3,
    input_applied = 4,
    input_query_count = 5,
    ack_dropped = 6,
};

pub const State = struct {
    snapshot: ?protocol.TestState = null,
    armed: bool = false,
    recovering: bool = false,
    dropped: u64 = 0,
    queries: u64 = 0,
    last_query_ms: u64 = 0,

    /// Disabled dispatch does not inspect state or consume any message.
    pub fn dispatch(self: *State, enabled: bool, live: bool, message: u32, wparam: usize, lparam: isize) ?isize {
        if (!enabled or (message != query_message and message != control_message)) return null;
        if (message == control_message) {
            if (wparam != 1 or lparam != magic) return invalid;
            if (!live or self.snapshot == null) return unavailable;
            if (self.armed or self.recovering) return invalid;
            self.armed = true;
            return 1;
        }
        if (lparam != 0) return invalid;
        const selector = std.enums.fromInt(Selector, wparam) orelse return invalid;
        if (!live) return unavailable;
        const snapshot = self.snapshot orelse return unavailable;
        return switch (selector) {
            .capability => magic,
            .scrollback_total => scalar(snapshot.total),
            .scrollback_viewport => scalar(snapshot.viewport),
            .scrollback_offset => scalar(snapshot.offset),
            .input_applied => scalar(snapshot.applied),
            .input_query_count => scalar(self.queries),
            .ack_dropped => scalar(self.dropped),
        };
    }

    /// Invoked only for the actual ACK of the currently in-flight input.
    pub fn dropAck(self: *State, enabled: bool, measurable: bool, outcome: protocol.Outcome) bool {
        if (!enabled or !measurable or outcome != .completed) return false;
        if (!self.armed) return false;
        self.armed = false;
        self.recovering = true;
        self.last_query_ms = 0;
        self.dropped +|= 1;
        return true;
    }

    pub fn queryDue(self: *const State, enabled: bool, now_ms: u64) bool {
        if (!enabled) return false;
        return self.recovering and (self.last_query_ms == 0 or now_ms -| self.last_query_ms >= 250);
    }

    pub fn queried(self: *State, now_ms: u64) void {
        self.queries +|= 1;
        self.last_query_ms = now_ms;
    }

    pub fn acceptSnapshot(self: *State, snapshot: protocol.TestState) void {
        if (self.snapshot) |old| if (snapshot.applied < old.applied) return;
        self.snapshot = snapshot;
    }
};

pub const Applied = struct {
    count: u64 = 0,
    last_sequence: u64 = 0,

    /// Text-bearing input is counted once after its callback/continuation ends.
    pub fn note(self: *Applied, enabled: bool, complete: bool, event: *const protocol.Input) void {
        if (!enabled or !complete) return;
        if (!protocol.Input.measurable(event.event) or event.sequence <= self.last_sequence) return;
        self.last_sequence = event.sequence;
        self.count +|= 1;
    }
};

fn scalar(value: u64) isize {
    return @intCast(@min(value, std.math.maxInt(isize)));
}

test "remote fixture disabled gate never reads state or handles messages" {
    const state: *State = undefined;
    try std.testing.expectEqual(@as(?isize, null), state.dispatch(false, true, query_message, 0, 0));
    try std.testing.expectEqual(@as(?isize, null), state.dispatch(false, true, control_message, 1, magic));
    try std.testing.expect(!state.dropAck(false, true, .completed));
    try std.testing.expect(!state.queryDue(false, 100));
    const applied: *Applied = undefined;
    applied.note(false, true, undefined);
}

test "remote fixture controls require source snapshot and drop exactly one real completed text ACK" {
    var state: State = .{};
    try std.testing.expectEqual(@as(?isize, unavailable), state.dispatch(true, true, query_message, 1, 0));
    try std.testing.expectEqual(@as(?isize, unavailable), state.dispatch(true, true, control_message, 1, magic));
    state.snapshot = .{ .surface = .{}, .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 }, .total = 100, .viewport = 24, .offset = 76, .applied = 3 };
    try std.testing.expectEqual(@as(?isize, magic), state.dispatch(true, true, query_message, 0, 0));
    try std.testing.expectEqual(@as(?isize, invalid), state.dispatch(true, true, control_message, 1, 0));
    try std.testing.expectEqual(@as(?isize, 1), state.dispatch(true, true, control_message, 1, magic));
    try std.testing.expect(!state.dropAck(true, false, .completed));
    try std.testing.expect(!state.dropAck(true, true, .rejected));
    try std.testing.expect(state.dropAck(true, true, .completed));
    try std.testing.expect(!state.dropAck(true, true, .completed));
    try std.testing.expectEqual(@as(?isize, 1), state.dispatch(true, true, query_message, 6, 0));
    try std.testing.expect(state.queryDue(true, 100));
    state.queried(100);
    try std.testing.expect(!state.queryDue(true, 349));
    try std.testing.expect(state.queryDue(true, 350));
    try std.testing.expectEqual(@as(?isize, 1), state.dispatch(true, true, query_message, 5, 0));
    state.recovering = false;
    try std.testing.expect(!state.queryDue(true, 1000));
    try std.testing.expectEqual(@as(?isize, unavailable), state.dispatch(true, false, query_message, 4, 0));
    try std.testing.expectEqual(@as(?isize, invalid), state.dispatch(true, true, query_message, 99, 0));
    try std.testing.expectEqual(@as(?isize, invalid), state.dispatch(true, true, query_message, 1, 1));
    try std.testing.expectEqual(@as(?isize, 100), state.dispatch(true, true, query_message, 1, 0));
    try std.testing.expectEqual(@as(?isize, 24), state.dispatch(true, true, query_message, 2, 0));
    try std.testing.expectEqual(@as(?isize, 76), state.dispatch(true, true, query_message, 3, 0));
    var stale = state.snapshot.?;
    stale.applied = 2;
    state.acceptSnapshot(stale);
    try std.testing.expectEqual(@as(?isize, 3), state.dispatch(true, true, query_message, 4, 0));
}

test "remote fixture applied count is monotonic and excludes unfinished duplicate and nontext input" {
    var applied: Applied = .{};
    var event: protocol.Input = .{ .surface = .{}, .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 }, .sequence = 5, .event = .{ .text = try protocol.Text.init("x") } };
    applied.note(true, false, &event);
    try std.testing.expectEqual(@as(u64, 0), applied.count);
    applied.note(true, true, &event);
    applied.note(true, true, &event);
    try std.testing.expectEqual(@as(u64, 1), applied.count);
    event.sequence = 6;
    event.event = .{ .focus = true };
    applied.note(true, true, &event);
    try std.testing.expectEqual(@as(u64, 1), applied.count);
}
