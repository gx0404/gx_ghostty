const std = @import("std");

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn ctrlOnly(self: Modifiers) bool {
        return self.ctrl and !self.shift and !self.alt and !self.super;
    }
};

pub const Unit = enum { wheel, surface };

pub const WheelAccumulator = struct {
    pending: f64 = 0,
    unit: ?Unit = null,

    pub fn reset(self: *WheelAccumulator) void {
        self.* = .{};
    }

    pub fn update(
        self: *WheelAccumulator,
        enabled: bool,
        mods: Modifiers,
        delta: f64,
        unit: Unit,
        surface_step: f64,
    ) ?i32 {
        if (!enabled or !mods.ctrlOnly() or !std.math.isFinite(delta) or delta == 0) {
            self.reset();
            return null;
        }
        if (unit == .surface and (!std.math.isFinite(surface_step) or surface_step <= 0)) {
            self.reset();
            return null;
        }
        const amount = if (unit == .surface) delta / surface_step else delta;
        if (self.unit != unit or (self.pending != 0 and (self.pending < 0) != (amount < 0))) self.reset();
        self.unit = unit;
        self.pending += std.math.clamp(amount, -254, 254);
        const tolerance: f64 = 1e-9;
        const steps = @trunc(self.pending + if (self.pending < 0) -tolerance else tolerance);
        self.pending -= steps;
        if (@abs(self.pending) < tolerance) self.pending = 0;
        return -@as(i32, @intFromFloat(steps));
    }
};

pub const PinchState = struct {
    start: ?f32 = null,
    last: f32 = 0,

    pub fn reset(self: *PinchState) void {
        self.* = .{};
    }

    pub fn begin(self: *PinchState, enabled: bool, points: f32) bool {
        self.reset();
        if (!enabled or !std.math.isFinite(points) or points <= 0) return false;
        self.start = std.math.clamp(points, 1, 255);
        self.last = self.start.?;
        return true;
    }

    pub fn update(self: *PinchState, enabled: bool, scale: f64) ?f32 {
        if (!enabled) {
            self.reset();
            return null;
        }
        const start = self.start orelse return null;
        if (!std.math.isFinite(scale) or scale <= 0) return null;
        const target: f32 = if (scale == 1) start else @floatCast(std.math.clamp(@round(@as(f64, start) * scale * 2) / 2, 1, 255));
        if (target == self.last) return null;
        self.last = target;
        return target;
    }
};

const testing = std.testing;
const ctrl: Modifiers = .{ .ctrl = true };

test "wheel accumulates raw fractional notches in both directions" {
    var wheel: WheelAccumulator = .{};
    try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, -0.25, .wheel, 0));
    try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, -0.5, .wheel, 0));
    try testing.expectEqual(@as(?i32, 1), wheel.update(true, ctrl, -0.25, .wheel, 0));
    try testing.expectEqual(@as(?i32, -2), wheel.update(true, ctrl, 2.25, .wheel, 0));
}

test "wheel reversal discards the old direction remainder" {
    var wheel: WheelAccumulator = .{};
    _ = wheel.update(true, ctrl, -0.75, .wheel, 0);
    try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, 0.5, .wheel, 0));
    try testing.expectEqual(@as(?i32, -1), wheel.update(true, ctrl, 0.5, .wheel, 0));
}

test "wheel requires Ctrl alone and disabled events are not claimed" {
    var wheel: WheelAccumulator = .{};
    for ([_]Modifiers{ .{}, .{ .ctrl = true, .shift = true }, .{ .ctrl = true, .alt = true }, .{ .ctrl = true, .super = true } }) |mods| {
        _ = wheel.update(true, ctrl, -0.75, .wheel, 0);
        try testing.expectEqual(@as(?i32, null), wheel.update(true, mods, -1, .wheel, 0));
        try testing.expectEqual(@as(f64, 0), wheel.pending);
    }
    try testing.expectEqual(@as(?i32, null), wheel.update(false, ctrl, -1, .wheel, 0));
}

test "surface scroll converts logical pixels before accumulation" {
    var wheel: WheelAccumulator = .{};
    try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, -10, .surface, 40));
    try testing.expectEqual(@as(?i32, 1), wheel.update(true, ctrl, -30, .surface, 40));
    _ = wheel.update(true, ctrl, -30, .surface, 40);
    try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, -0.25, .wheel, 40));
    try testing.expectEqual(@as(?i32, 1), wheel.update(true, ctrl, -0.75, .wheel, 40));
}

test "wheel stop reset and invalid events clear remainders" {
    var wheel: WheelAccumulator = .{};
    for ([_]f64{ 0, std.math.nan(f64), std.math.inf(f64) }) |delta| {
        _ = wheel.update(true, ctrl, -0.75, .wheel, 0);
        try testing.expectEqual(@as(?i32, null), wheel.update(true, ctrl, delta, .wheel, 0));
        try testing.expectEqual(@as(f64, 0), wheel.pending);
    }
    try testing.expectEqual(@as(?i32, null), wheel.update(true, ctrl, -1, .surface, 0));
    _ = wheel.update(true, ctrl, -0.75, .wheel, 0);
    wheel.reset();
    try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, -0.25, .wheel, 0));
    try testing.expectEqual(@as(?i32, 254), wheel.update(true, ctrl, -1e20, .wheel, 0));
}

test "pinch uses cumulative scale against gesture begin size" {
    var pinch: PinchState = .{};
    try testing.expect(pinch.begin(true, 12));
    try testing.expectEqual(@as(?f32, 18), pinch.update(true, 1.5));
    try testing.expectEqual(@as(?f32, 24), pinch.update(true, 2));
    try testing.expectEqual(@as(?f32, 6), pinch.update(true, 0.5));
    try testing.expectEqual(@as(?f32, 12), pinch.update(true, 1));
}

test "pinch deduplicates quantized targets and clamps to core limits" {
    var pinch: PinchState = .{};
    try testing.expect(pinch.begin(true, 12.3));
    try testing.expectEqual(@as(?f32, null), pinch.update(true, 1));
    try testing.expectEqual(@as(?f32, 12.5), pinch.update(true, 1.02));
    try testing.expectEqual(@as(?f32, null), pinch.update(true, 1.03));
    try testing.expectEqual(@as(?f32, 255), pinch.update(true, 1e20));
    try testing.expectEqual(@as(?f32, null), pinch.update(true, 1e20));
    try testing.expectEqual(@as(?f32, 1), pinch.update(true, 0.001));
}

test "pinch end cancel and disable require a new begin" {
    var pinch: PinchState = .{};
    try testing.expect(!pinch.begin(false, 12));
    try testing.expectEqual(@as(?f32, null), pinch.update(true, 2));
    try testing.expect(pinch.begin(true, 12));
    pinch.reset();
    try testing.expectEqual(@as(?f32, null), pinch.update(true, 2));
    try testing.expect(pinch.begin(true, 12));
    try testing.expectEqual(@as(?f32, null), pinch.update(false, 2));
    try testing.expectEqual(@as(?f32, null), pinch.update(true, 2));
    try testing.expect(pinch.begin(true, 16));
    try testing.expectEqual(@as(?f32, 32), pinch.update(true, 2));
}

test "pinch rejects invalid scales without changing its baseline" {
    var pinch: PinchState = .{};
    try testing.expect(!pinch.begin(true, std.math.nan(f32)));
    try testing.expect(pinch.begin(true, 12));
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |scale| try testing.expectEqual(@as(?f32, null), pinch.update(true, scale));
    try testing.expectEqual(@as(?f32, 24), pinch.update(true, 2));
}

test "fractional tenths complete a notch without an extra event" {
    for ([_]f64{ 0.1, -0.1 }) |fraction| {
        var wheel: WheelAccumulator = .{};
        for (0..9) |_| try testing.expectEqual(@as(?i32, 0), wheel.update(true, ctrl, fraction, .wheel, 0));
        try testing.expectEqual(@as(?i32, if (fraction > 0) -1 else 1), wheel.update(true, ctrl, fraction, .wheel, 0));
        try testing.expectEqual(@as(f64, 0), wheel.pending);
    }
}
