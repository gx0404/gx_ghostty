//! The sizes of the Ghostty GX interface, the same for both app runtimes:
//! DIPs in the win32 popups and chrome (`src/apprt/win32/ui/style.zig`
//! takes its size tokens from here) and CSS pixels in the GTK look, which
//! writes them as literal `px` values (GTK 4.14 parses no CSS variables).
//!
//! - Corner radii: `control` for buttons, inputs, list row fills, cards and
//!   key caps; `overlay` for popups, menus, tab tops and the find, resize
//!   and link overlays; `window` for dialogs and boxed lists.
//! - A spacing scale, control heights and row heights. These and the radii
//!   are multiples of 4 (checked at compile time).
//! - The Fluent type ramp: sizes with their line heights.
//! - The brand signature: the accent bar along the top of the active tab.
//!
//! Colors are in `ui_tokens` and `chrome`, motion in `motion`.
const std = @import("std");

/// Corner radii.
pub const radius = struct {
    pub const control: f32 = 4;
    pub const overlay: f32 = 8;
    pub const window: f32 = 12;
};

/// Spacing steps: items in a row `m`, panels and bars `s`, notices `l`,
/// dialogs and settings pages `xl`, between groups of a page `xxl`.
pub const space = struct {
    pub const xs: f32 = 4;
    pub const s: f32 = 8;
    pub const m: f32 = 12;
    pub const l: f32 = 16;
    pub const xl: f32 = 24;
    pub const xxl: f32 = 32;
};

/// Control heights: buttons and inputs, and icon buttons inside bars.
pub const control = struct {
    pub const height: f32 = 32;
    pub const compact: f32 = 28;
};

/// Row heights: menus, group headers, the command palette and the shortcut
/// lists, and rows with a second line.
pub const row = struct {
    pub const menu: f32 = 32;
    pub const header: f32 = 32;
    pub const list: f32 = 36;
    pub const two_line: f32 = 52;
};

/// A step of the type ramp: the size and the line height, and whether it
/// is semibold.
pub const TypeStep = struct {
    size: f32,
    line: f32,
    semibold: bool = false,
};

/// The Fluent type ramp: caption 12/16, body 14/20, body strong 14/20
/// semibold, body large 18/24, subtitle 20/28 semibold, title 28/36
/// semibold.
pub const type_ramp = struct {
    pub const caption: TypeStep = .{ .size = 12, .line = 16 };
    pub const body: TypeStep = .{ .size = 14, .line = 20 };
    pub const body_strong: TypeStep = .{ .size = 14, .line = 20, .semibold = true };
    pub const body_large: TypeStep = .{ .size = 18, .line = 24 };
    pub const subtitle: TypeStep = .{ .size = 20, .line = 28, .semibold = true };
    pub const title: TypeStep = .{ .size = 28, .line = 36, .semibold = true };
};

/// The brand signature of the window chrome: a bar in the accent along the
/// top edge of the active tab, inside its rounded corners.
pub const signature = struct {
    pub const bar: f32 = 2;
};

/// The sizes the 4 DIP grid applies to.
const grid = [_]f32{
    radius.control, radius.overlay,  radius.window,
    space.xs,       space.s,         space.m,
    space.l,        space.xl,        space.xxl,
    control.height, control.compact, row.menu,
    row.header,     row.list,        row.two_line,
};

comptime {
    for (grid) |v| {
        if (@mod(v, 4) != 0) @compileError("radii, spacing, control and row sizes are multiples of 4");
    }
}

test "sizes are on the 4 grid and increase" {
    const testing = std.testing;
    for (grid) |v| try testing.expectEqual(@as(f32, 0), @mod(v, 4));
    try testing.expect(radius.control < radius.overlay and radius.overlay < radius.window);
    const steps = [_]f32{ space.xs, space.s, space.m, space.l, space.xl, space.xxl };
    for (steps[0 .. steps.len - 1], steps[1..]) |a, b| try testing.expect(a < b);
}

test "the type ramp has the Fluent sizes" {
    const testing = std.testing;
    const ramp = [_]TypeStep{
        type_ramp.caption,    type_ramp.body,     type_ramp.body_strong,
        type_ramp.body_large, type_ramp.subtitle, type_ramp.title,
    };
    const sizes = [_]f32{ 12, 14, 14, 18, 20, 28 };
    for (ramp, sizes) |step, size| {
        try testing.expectEqual(size, step.size);
        try testing.expect(step.line > step.size);
    }
    try testing.expect(type_ramp.body_strong.semibold and !type_ramp.body.semibold);
    try testing.expectEqual(@as(f32, 2), signature.bar);
}
