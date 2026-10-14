//! Normalized monochrome SVG paths, independent of the native drawing API.
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };
pub const Cubic = struct { c1: Point, c2: Point, end: Point };
pub const FillRule = enum { nonzero, evenodd };
pub const Command = union(enum) {
    move: Point,
    line: Point,
    cubic: Cubic,
    close,
};
pub const Path = struct { fill_rule: FillRule, commands: []const Command };
pub const Icon = struct { width: f32, height: f32, paths: []const Path };
pub const Placement = struct { scale: f32, x: f32, y: f32 };

/// Fit without distortion, retaining centering in a non-square destination.
pub fn fit(icon: Icon, x: f32, y: f32, width: f32, height: f32) ?Placement {
    const values = [_]f32{ icon.width, icon.height, x, y, width, height };
    for (values) |value| if (!std.math.isFinite(value)) return null;
    if (icon.width <= 0 or icon.height <= 0 or width <= 0 or height <= 0) return null;
    const scale = @min(width / icon.width, height / icon.height);
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    const px = x + (width - icon.width * scale) / 2;
    const py = y + (height - icon.height * scale) / 2;
    if (!std.math.isFinite(px) or !std.math.isFinite(py)) return null;
    return .{ .scale = scale, .x = px, .y = py };
}

test "fluent fit keeps centering and scale at all requested DPIs" {
    const icon: Icon = .{ .width = 20, .height = 20, .paths = &.{} };
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |dpi| {
        const result = fit(icon, 4 * dpi, 8 * dpi, 40 * dpi, 20 * dpi).?;
        try std.testing.expectEqual(dpi, result.scale);
        try std.testing.expectEqual(14 * dpi, result.x);
        try std.testing.expectEqual(8 * dpi, result.y);
    }
    try std.testing.expect(fit(icon, 0, 0, 0, 20) == null);
    try std.testing.expect(fit(icon, std.math.nan(f32), 0, 20, 20) == null);
}
