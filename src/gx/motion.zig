//! Motion of the Ghostty GX interface, the same on win32 and GTK: the
//! Fluent durations (83, 167 and 250 ms), the entrance and exit curves as
//! CSS `cubic-bezier` timing functions, and whether to animate at all
//! (the system's animation setting, remote sessions, and the
//! `GHOSTTY_GX_ANIMATIONS` override). Animations are driven by elapsed
//! time (`fraction`), not by frame counts, and jump to their end state
//! when animations are off. Only depends on `std`.
const std = @import("std");

/// Durations in milliseconds.
pub const duration = struct {
    /// Hover and press color fades.
    pub const faster: u32 = 83;
    /// Popups fading in, the selection indicator moving.
    pub const fast: u32 = 167;
    /// Larger movements, such as panels sliding in.
    pub const normal: u32 = 250;
};

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing function: the curve from
/// (0, 0) to (1, 1) with these two control points, mapping the fraction of
/// time passed (x) to the fraction of the change made (y). The x control
/// values must be within 0..1.
pub const CubicBezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    /// The fraction of the change made at time fraction `t` (clamped to
    /// 0..1).
    pub fn at(self: CubicBezier, t: f32) f32 {
        const x = std.math.clamp(t, 0, 1);
        if (x == 0 or x == 1) return x;
        return bezier(self.y1, self.y2, solve(self.x1, self.x2, x));
    }

    /// The time fraction at which the change reaches `p` (clamped to
    /// 0..1): the inverse of `at`, so that an animation reversed midway
    /// continues from where it is. The y control values must be within
    /// 0..1 for the inverse to be unique.
    pub fn timeAt(self: CubicBezier, p: f32) f32 {
        const y = std.math.clamp(p, 0, 1);
        if (y == 0 or y == 1) return y;
        return bezier(self.x1, self.x2, solve(self.y1, self.y2, y));
    }
};

/// One coordinate of the curve at parameter `s`, for control values `c1`
/// and `c2`.
fn bezier(c1: f32, c2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * s * c1 + 3 * u * s * s * c2 + s * s * s;
}

/// The parameter at which the coordinate with control values `c1` and
/// `c2` (within 0..1, so it only grows) reaches `v`.
fn solve(c1: f32, c2: f32, v: f32) f32 {
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..32) |_| {
        const mid = (lo + hi) / 2;
        if (bezier(c1, c2, mid) < v) lo = mid else hi = mid;
    }
    return (lo + hi) / 2;
}

/// Entering and appearing elements: fast out, slow in (decelerate).
pub const enter: CubicBezier = .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 1 };

/// Exiting and disappearing elements: slow out, fast in (accelerate).
pub const exit: CubicBezier = .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 1 };

pub const linear: CubicBezier = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 };

/// The fraction of an animation of `total_ms` done after `elapsed_ms`,
/// 0..1. An animation without duration is done at once.
pub fn fraction(elapsed_ms: u64, total_ms: u32) f32 {
    if (total_ms == 0 or elapsed_ms >= total_ms) return 1;
    return @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(total_ms));
}

/// The environment variable that turns animations on (`1`, `true`, `on`,
/// `yes`) or off (`0`, `false`, `off`, `no`) whatever the system says;
/// other values are ignored.
pub const env_override = "GHOSTTY_GX_ANIMATIONS";

/// What decides whether to animate.
pub const Environment = struct {
    /// The system's animation setting: Windows "Animation effects"
    /// (`SPI_GETCLIENTAREAANIMATION`), GTK `gtk-enable-animations`.
    system: bool,
    /// Running in a remote desktop session (`SM_REMOTESESSION`), where
    /// every frame costs bandwidth.
    remote_session: bool = false,
    /// The value of `env_override`, when set.
    override: ?[]const u8 = null,
};

/// Whether to animate: as the override says, else only when the system
/// allows animations and the session is local.
pub fn enabled(env: Environment) bool {
    if (env.override) |value| {
        if (parseOverride(value)) |on| return on;
    }
    return env.system and !env.remote_session;
}

/// The value of `env_override` as on or off, null when it is neither.
pub fn parseOverride(value: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    for ([_][]const u8{ "1", "true", "on", "yes" }) |word| {
        if (std.ascii.eqlIgnoreCase(trimmed, word)) return true;
    }
    for ([_][]const u8{ "0", "false", "off", "no" }) |word| {
        if (std.ascii.eqlIgnoreCase(trimmed, word)) return false;
    }
    return null;
}

const testing = std.testing;

test "curves start at 0, end at 1 and only grow" {
    for ([_]CubicBezier{ enter, exit, linear }) |curve| {
        try testing.expectEqual(@as(f32, 0), curve.at(0));
        try testing.expectEqual(@as(f32, 1), curve.at(1));
        try testing.expectEqual(@as(f32, 0), curve.at(-1));
        try testing.expectEqual(@as(f32, 1), curve.at(2));
        var previous: f32 = 0;
        for (1..100) |i| {
            const value = curve.at(@as(f32, @floatFromInt(i)) / 100);
            try testing.expect(value >= previous);
            previous = value;
        }
    }
}

test "enter decelerates, exit accelerates" {
    // cubic-bezier(0, 0, 0, 1) at half time: x(s) = s^3, y(s) = 3s^2 - 2s^3.
    try testing.expectApproxEqAbs(@as(f32, 0.8899), enter.at(0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.1101), exit.at(0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.3), linear.at(0.3), 1e-4);
    try testing.expect(enter.at(0.2) > 0.5);
    try testing.expect(exit.at(0.8) < 0.5);
}

test "timeAt inverts at" {
    for ([_]CubicBezier{ enter, exit, linear }) |curve| {
        for ([_]f32{ 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 }) |p| {
            try testing.expectApproxEqAbs(p, curve.at(curve.timeAt(p)), 1e-3);
        }
    }
    try testing.expectEqual(@as(f32, 1), enter.timeAt(1.5));
}

test "fraction" {
    try testing.expectEqual(@as(f32, 0), fraction(0, duration.fast));
    try testing.expectApproxEqAbs(@as(f32, 0.5), fraction(125, duration.normal), 1e-6);
    try testing.expectEqual(@as(f32, 1), fraction(duration.fast, duration.fast));
    try testing.expectEqual(@as(f32, 1), fraction(10_000, duration.fast));
    try testing.expectEqual(@as(f32, 1), fraction(0, 0));
}

test "enabled follows the system, remote sessions and the override" {
    try testing.expect(enabled(.{ .system = true }));
    try testing.expect(!enabled(.{ .system = false }));
    try testing.expect(!enabled(.{ .system = true, .remote_session = true }));
    try testing.expect(!enabled(.{ .system = true, .override = "0" }));
    try testing.expect(enabled(.{ .system = false, .override = "1" }));
    try testing.expect(enabled(.{ .system = true, .remote_session = true, .override = " TRUE " }));
    try testing.expect(!enabled(.{ .system = true, .override = "Off" }));
    try testing.expect(enabled(.{ .system = true, .override = "maybe" }));
    try testing.expect(!enabled(.{ .system = false, .override = "" }));
}
