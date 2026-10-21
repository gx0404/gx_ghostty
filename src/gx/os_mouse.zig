//! The double-click time of the Windows mouse settings, the default of
//! `click-repeat-interval` on Windows (`src/os/mouse.zig::clickInterval`,
//! GX-0048 in docs/FORK_PATCHES.md).
const std = @import("std");
const builtin = @import("builtin");

/// The longest interval in milliseconds whose nanoseconds still fit the
/// `u32` the core derives from `click-repeat-interval`
/// (`src/Surface.zig`: milliseconds times 1_000_000). Windows accepts
/// double-click times up to 5000 ms.
pub const max_ms: u32 = std.math.maxInt(u32) / std.time.ns_per_ms;

/// The user's double-click time in milliseconds, at most `max_ms`, or null
/// when it is unknown: on other platforms, or when Windows reports 0.
pub fn doubleClickTime() ?u32 {
    if (comptime builtin.target.os.tag != .windows) return null;
    return clamp(user32.GetDoubleClickTime());
}

fn clamp(ms: u32) ?u32 {
    if (ms == 0) return null;
    return @min(ms, max_ms);
}

const user32 = struct {
    extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
};

test "doubleClickTime keeps the nanoseconds in range and skips zero" {
    try std.testing.expectEqual(@as(?u32, null), clamp(0));
    try std.testing.expectEqual(@as(?u32, 500), clamp(500));
    try std.testing.expectEqual(@as(?u32, max_ms), clamp(max_ms));
    try std.testing.expectEqual(@as(?u32, max_ms), clamp(5000));
    try std.testing.expect(@as(u64, max_ms) * std.time.ns_per_ms <= std.math.maxInt(u32));
    try std.testing.expect(@as(u64, max_ms + 1) * std.time.ns_per_ms > std.math.maxInt(u32));
}

test "doubleClickTime follows the Windows mouse settings" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const system = user32.GetDoubleClickTime();
    try std.testing.expect(system != 0);
    try std.testing.expectEqual(clamp(system), doubleClickTime());
    try std.testing.expectEqual(doubleClickTime(), @import("../os/mouse.zig").clickInterval());
}
