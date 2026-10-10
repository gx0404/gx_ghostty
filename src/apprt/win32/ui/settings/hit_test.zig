//! Hit-test rectangles of the settings overlay. While the body paints, the
//! rectangles of its rows are cut to the body like their painting: a row
//! scrolled partly under the header or the footer is clickable only where
//! it shows, and one scrolled out of sight not at all, so a click on the
//! footer's key hints cannot press the row hidden under them.
//!
//! The functions take any rectangle struct with `x`, `y`, `w` and `h`
//! (`d2d.Rect`). Only depends on `std`, so the tests run with a plain
//! `zig test` of this file on any host.
const std = @import("std");

/// The overlap of the rectangles `a` and `b`, empty (zero width or height)
/// when they do not overlap.
pub fn intersect(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

/// The part of `rect` that can be hit within `bounds` (none: all of it),
/// or null when nothing of it is left.
pub fn clip(rect: anytype, bounds: ?@TypeOf(rect)) ?@TypeOf(rect) {
    const b = bounds orelse return rect;
    const visible = intersect(rect, b);
    if (visible.w <= 0 or visible.h <= 0) return null;
    return visible;
}

const testing = std.testing;

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// The body of a 920×680 DIP overlay: right of the sidebar, between the
/// header and the footer.
const body: Rect = .{ .x = 200, .y = 64, .w = 720, .h = 572 };

test "a row half under the footer keeps its visible half" {
    const row = clip(Rect{ .x = 224, .y = 610, .w = 672, .h = 58 }, body).?;
    try testing.expectEqual(Rect{ .x = 224, .y = 610, .w = 672, .h = 26 }, row);
}

test "rows scrolled out of the body cannot be hit" {
    // Under the footer: its key hints sit there.
    try testing.expectEqual(@as(?Rect, null), clip(Rect{ .x = 224, .y = 650, .w = 672, .h = 44 }, body));
    // Under the header and its close button.
    try testing.expectEqual(@as(?Rect, null), clip(Rect{ .x = 224, .y = 10, .w = 672, .h = 44 }, body));
    // Touching the edge is not overlapping.
    try testing.expectEqual(@as(?Rect, null), clip(Rect{ .x = 224, .y = 636, .w = 672, .h = 44 }, body));
    try testing.expectEqual(@as(?Rect, null), clip(Rect{ .x = 224, .y = 20, .w = 672, .h = 44 }, body));
}

test "rows inside the body and hits outside it are kept" {
    const row: Rect = .{ .x = 224, .y = 100, .w = 672, .h = 44 };
    try testing.expectEqual(row, clip(row, body).?);
    // The sidebar and the header paint without a clip.
    const close: Rect = .{ .x = 870, .y = 16, .w = 34, .h = 34 };
    try testing.expectEqual(close, clip(close, null).?);
}

test "intersect" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expectEqual(Rect{ .x = 5, .y = 2, .w = 5, .h = 8 }, intersect(a, Rect{ .x = 5, .y = 2, .w = 20, .h = 20 }));
    const apart = intersect(a, Rect{ .x = 20, .y = 0, .w = 5, .h = 5 });
    try testing.expectEqual(@as(f32, 0), apart.w);
}
