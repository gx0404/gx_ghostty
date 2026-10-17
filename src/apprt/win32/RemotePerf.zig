//! Optional remote-frame telemetry. QPC is shared by processes on this host;
//! timestamps never drive admission, retries, rendering or input ordering.
const std = @import("std");
const perf = @import("../../gx/perf.zig");
pub const InputStamp = @import("../../gx/remote_view.zig").InputStamp;

extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;

/// Zero is the disabled/unavailable sentinel. Off means no clock API calls.
pub fn now() u64 {
    if (!perf.enabled()) return 0;
    var value: i64 = 0;
    if (QueryPerformanceCounter(&value) == 0 or value <= 0) return 0;
    return @intCast(value);
}

pub fn frequency() u64 {
    if (!perf.enabled()) return 0;
    var value: i64 = 0;
    if (QueryPerformanceFrequency(&value) == 0 or value <= 0) return 0;
    return @intCast(value);
}

pub fn elapsedUs(start: u64, end: u64, hz: u64) ?u64 {
    if (start == 0 or end < start or hz == 0) return null;
    return ticksUs(end - start, hz);
}

fn ticksUs(ticks: u64, hz: u64) u64 {
    return @intCast(@min(@as(u128, ticks) * std.time.us_per_s / hz, std.math.maxInt(u64)));
}

pub fn record(metric: []const u8, start: u64, end: u64) void {
    if (elapsedUs(start, end, frequency())) |us| perf.record(metric, us);
}

pub fn recordTicks(metric: []const u8, ticks: u64) void {
    const hz = frequency();
    if (hz != 0) perf.record(metric, ticksUs(ticks, hz));
}

/// One GUI-owned pending frame. A newer received frame supersedes an unpainted
/// one. The pane (not the mapping) owns last_input across mapping replacements.
pub const Presentation = struct {
    received_qpc: u64 = 0,
    input: InputStamp = .{},

    pub const Samples = struct { present: ?u64 = null, input_to_present: ?u64 = null };

    pub fn received(self: *Presentation, stamp: InputStamp, qpc: u64) void {
        self.* = .{ .received_qpc = qpc, .input = stamp };
    }

    /// Call only after a visible frame's successful EndDraw. A failed draw
    /// leaves the pending sample available for the next successful repaint.
    pub fn complete(self: *Presentation, last_input: *u64, end: u64, hz: u64) Samples {
        const duration = elapsedUs(self.received_qpc, end, hz) orelse return .{};
        defer self.* = .{};
        var samples: Samples = .{ .present = duration };
        if (self.input.valid() and self.input.sequence > last_input.*) {
            if (elapsedUs(self.input.qpc, end, hz)) |us| {
                samples.input_to_present = us;
                last_input.* = self.input.sequence;
            }
        }
        return samples;
    }

    pub fn presented(self: *Presentation, last_input: *u64) void {
        if (!perf.enabled()) return;
        const end = now();
        const samples = self.complete(last_input, end, frequency());
        if (samples.present) |us| perf.record("remote.present", us);
        if (samples.input_to_present) |us| perf.record("remote.input_to_present", us);
    }
};

test "remote QPC conversion rejects missing reversed clocks and saturates overflow" {
    try std.testing.expectEqual(@as(?u64, 250), elapsedUs(10_000, 12_500, 10_000_000));
    try std.testing.expectEqual(@as(?u64, 0), elapsedUs(1, 1, 10));
    try std.testing.expectEqual(@as(?u64, null), elapsedUs(0, 10, 10));
    try std.testing.expectEqual(@as(?u64, null), elapsedUs(11, 10, 10));
    try std.testing.expectEqual(@as(?u64, null), elapsedUs(1, 10, 0));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), elapsedUs(1, std.math.maxInt(u64), 1));
}

test "remote presentation samples latest input once across coalescing repaint and resize" {
    var pending: Presentation = .{};
    var last_input: u64 = 0;
    pending.received(.{ .sequence = 1, .qpc = 100 }, 150);
    // The older unpainted frame/input is superseded, not logged retroactively.
    pending.received(.{ .sequence = 3, .qpc = 200 }, 250);
    const sample = pending.complete(&last_input, 300, 1_000_000);
    try std.testing.expectEqual(@as(?u64, 50), sample.present);
    try std.testing.expectEqual(@as(?u64, 100), sample.input_to_present);
    try std.testing.expectEqual(@as(u64, 3), last_input);
    try std.testing.expectEqual(Presentation.Samples{}, pending.complete(&last_input, 310, 1_000_000));
    // A replacement mapping keeps the pane's input high-water mark.
    var resized: Presentation = .{};
    resized.received(.{ .sequence = 3, .qpc = 200 }, 320);
    try std.testing.expectEqual(@as(?u64, null), resized.complete(&last_input, 350, 1_000_000).input_to_present);
    resized.received(.{ .sequence = 2, .qpc = 180 }, 360);
    try std.testing.expectEqual(@as(?u64, null), resized.complete(&last_input, 370, 1_000_000).input_to_present);
}

test "remote presentation retains unsuccessful sample and rejects invalid input stamps" {
    var pending: Presentation = .{};
    var last_input: u64 = 0;
    pending.received(.{ .sequence = 1, .qpc = 100 }, 150);
    try std.testing.expectEqual(Presentation.Samples{}, pending.complete(&last_input, 200, 0));
    try std.testing.expectEqual(@as(?u64, 150), pending.complete(&last_input, 250, 1_000_000).input_to_present);
    for ([_]InputStamp{ .{}, .{ .sequence = 2 }, .{ .sequence = 2, .qpc = 500 } }) |stamp| {
        pending.received(stamp, 300);
        try std.testing.expectEqual(@as(?u64, null), pending.complete(&last_input, 400, 1_000_000).input_to_present);
    }
    try std.testing.expectEqual(@as(u64, 1), last_input);
}

test "remote telemetry is inert when the performance switch is off" {
    const previous = perf.enabled();
    defer perf.setEnabled(previous);
    perf.setEnabled(false);
    try std.testing.expectEqual(@as(u64, 0), now());
    try std.testing.expectEqual(@as(u64, 0), frequency());
    var pending: Presentation = .{};
    var last_input: u64 = 0;
    pending.received(.{ .sequence = 1, .qpc = 100 }, 150);
    pending.presented(&last_input);
    try std.testing.expectEqual(@as(u64, 0), last_input);
    try std.testing.expectEqual(@as(u64, 150), pending.received_qpc);
}
