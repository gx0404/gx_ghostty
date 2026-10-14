//! Toolkit-free drag thresholds and a rollback transaction for native parents.
const std = @import("std");

pub const Gesture = enum { pending, reorder, detach };
pub fn gesture(dx: i32, dy: i32, scale: f32) Gesture {
    if (!std.math.isFinite(scale) or scale <= 0) return .pending;
    if (@as(f64, @floatFromInt(@abs(@as(i64, dy)))) / scale > 15) return .detach;
    if (@as(f64, @floatFromInt(@abs(@as(i64, dx)))) / scale > 10) return .reorder;
    return .pending;
}

/// Backend owns identity/liveness checks. Roll back only successful moves, in
/// reverse order; report rollback failure rather than silently destroying a
/// staging parent that may still contain running terminals.
pub fn reparent(comptime Backend: type, backend: *Backend, count: usize) !void {
    var moved: usize = 0;
    while (moved < count) : (moved += 1) {
        backend.move(moved) catch |err| {
            var rollback_failed = false;
            while (moved > 0) {
                moved -= 1;
                backend.restore(moved) catch {
                    rollback_failed = true;
                };
            }
            return if (rollback_failed) error.RollbackFailed else err;
        };
    }
    if (@hasDecl(Backend, "validate")) backend.validate() catch |err| {
        var failed = false;
        while (moved > 0) {
            moved -= 1;
            backend.restore(moved) catch {
                failed = true;
            };
        }
        return if (failed) error.RollbackFailed else err;
    };
}

test "tab transfer strict DIP thresholds across supported scales" {
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        const vertical: i32 = @intFromFloat(@floor(15 * scale));
        try std.testing.expectEqual(Gesture.pending, gesture(0, vertical, scale));
        try std.testing.expectEqual(Gesture.detach, gesture(0, vertical + 1, scale));
        const horizontal: i32 = @intFromFloat(@floor(10 * scale));
        try std.testing.expectEqual(Gesture.pending, gesture(horizontal, 0, scale));
        try std.testing.expectEqual(Gesture.reorder, gesture(horizontal + 1, 0, scale));
    }
    try std.testing.expectEqual(Gesture.detach, gesture(100, -16, 1));
}

test "tab transfer restores every successful SetParent and reports rollback failure" {
    const Backend = struct {
        fail: usize,
        fail_restore: bool = false,
        fail_validation: bool = false,
        parents: [4]bool = @splat(false),
        fn move(self: *@This(), i: usize) !void {
            if (i == self.fail) return error.SetParentFailed;
            self.parents[i] = true;
        }
        fn restore(self: *@This(), i: usize) !void {
            if (self.fail_restore) return error.RestoreFailed;
            self.parents[i] = false;
        }
        fn validate(self: *@This()) !void {
            if (self.fail_validation) return error.OwnerChanged;
        }
    };
    for (0..4) |failure| {
        var backend: Backend = .{ .fail = failure };
        try std.testing.expectError(error.SetParentFailed, reparent(Backend, &backend, 4));
        try std.testing.expectEqual([4]bool{ false, false, false, false }, backend.parents);
    }
    var rollback: Backend = .{ .fail = 2, .fail_restore = true };
    try std.testing.expectError(error.RollbackFailed, reparent(Backend, &rollback, 4));
    var changed: Backend = .{ .fail = 4, .fail_validation = true };
    try std.testing.expectError(error.OwnerChanged, reparent(Backend, &changed, 4));
    try std.testing.expectEqual([4]bool{ false, false, false, false }, changed.parents);
}
