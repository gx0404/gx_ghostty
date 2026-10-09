//! The colors of the Ghostty GX look for the GTK app, as CSS derived from
//! the terminal theme: the header bar and tab bar take the titlebar colors
//! (the terminal background and foreground unless `window-titlebar-*` is
//! set), tabs get hover and selected shades mixed from them, the selected
//! tab an outline in the theme's blue (palette color 4), and split
//! dividers a line between the terminal background and foreground.
//! `src/apprt/gtk/gx/style.zig` appends the output of `write` to the
//! static rules in `src/apprt/gtk/gx/style.css`. It is plain text
//! generation without GTK so the core test suite covers it.
const std = @import("std");
const Config = @import("../config/Config.zig");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn format(self: Rgb, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("rgb({d},{d},{d})", .{ self.r, self.g, self.b });
    }
};

/// An `Rgb` with an opacity, formatted as CSS `rgba()`.
pub const Rgba = struct {
    rgb: Rgb,
    alpha: f32,

    pub fn format(self: Rgba, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("rgba({d},{d},{d},{d:.2})", .{ self.rgb.r, self.rgb.g, self.rgb.b, self.alpha });
    }
};

pub const Colors = struct {
    /// The header bar and tab bar background and text.
    bar_background: Rgb,
    bar_foreground: Rgb,

    /// The terminal background and foreground.
    background: Rgb,
    foreground: Rgb,

    /// The accent of the selected tab.
    accent: Rgb,
};

/// The colors of the GX look for `config`, or null unless the window
/// follows the terminal colors (`window-theme = auto` or `ghostty`); with
/// `system`, `light` and `dark` the header bar keeps the libadwaita colors.
pub fn fromConfig(config: *const Config) ?Colors {
    switch (config.@"window-theme") {
        .auto, .ghostty => {},
        .system, .light, .dark => return null,
    }
    return .{
        .bar_background = rgb(config.@"window-titlebar-background" orelse config.background),
        .bar_foreground = rgb(config.@"window-titlebar-foreground" orelse config.foreground),
        .background = rgb(config.background),
        .foreground = rgb(config.foreground),
        .accent = rgb(config.palette.value[4]),
    };
}

fn rgb(color: anytype) Rgb {
    return .{ .r = color.r, .g = color.g, .b = color.b };
}

/// `a` moved towards `b` by `t` (0 is `a`, 1 is `b`), per channel and
/// rounded to the nearest value.
pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    return .{
        .r = mixChannel(a.r, b.r, t),
        .g = mixChannel(a.g, b.g, t),
        .b = mixChannel(a.b, b.b, t),
    };
}

fn mixChannel(a: u8, b: u8, t: f32) u8 {
    const from: f32 = @floatFromInt(a);
    const to: f32 = @floatFromInt(b);
    const value = from + (to - from) * std.math.clamp(t, 0, 1);
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

/// Writes the color rules for `colors`.
pub fn write(writer: *std.Io.Writer, colors: Colors) std.Io.Writer.Error!void {
    const bar_bg = colors.bar_background;
    const bar_fg = colors.bar_foreground;
    try writer.print(
        \\/* Ghostty GX colors derived from the terminal theme */
        \\.window toolbarview > .top-bar,
        \\.window toolbarview > .bottom-bar,
        \\.window headerbar,
        \\.window tabbar .box {{
        \\  background-color: {[bar_bg]f};
        \\  color: {[bar_fg]f};
        \\}}
        \\.window tabbar tab:hover {{
        \\  background-color: {[hover]f};
        \\}}
        \\.window tabbar tab:active {{
        \\  background-color: {[pressed]f};
        \\}}
        \\.window tabbar tab:selected {{
        \\  background-color: {[selected]f};
        \\  box-shadow: inset 0 0 0 1px {[outline]f};
        \\}}
        \\.window tabbar tab:selected:hover {{
        \\  background-color: {[selected_hover]f};
        \\}}
        \\.window tabbar tab:selected:active {{
        \\  background-color: {[pressed]f};
        \\}}
        \\.window .split paned > separator {{
        \\  background-image: image({[divider]f});
        \\  box-shadow: none;
        \\}}
        \\
    , .{
        .bar_bg = bar_bg,
        .bar_fg = bar_fg,
        .hover = mix(bar_bg, bar_fg, 0.07),
        .pressed = mix(bar_bg, bar_fg, 0.20),
        .selected = mix(bar_bg, bar_fg, 0.12),
        .selected_hover = mix(bar_bg, bar_fg, 0.16),
        .outline = Rgba{ .rgb = colors.accent, .alpha = 0.45 },
        .divider = mix(colors.background, colors.foreground, 0.15),
    });
}

test "fromConfig follows window-theme" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.background = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };
    config.foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    config.palette.value[4] = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };

    config.@"window-theme" = .auto;
    const auto = fromConfig(&config).?;
    try testing.expectEqual(Rgb{ .r = 0x1f, .g = 0x1f, .b = 0x28 }, auto.bar_background);
    try testing.expectEqual(Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, auto.bar_foreground);
    try testing.expectEqual(Rgb{ .r = 0x89, .g = 0xb4, .b = 0xfa }, auto.accent);

    config.@"window-theme" = .ghostty;
    config.@"window-titlebar-background" = .{ .r = 1, .g = 2, .b = 3 };
    const ghostty = fromConfig(&config).?;
    try testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, ghostty.bar_background);
    try testing.expectEqual(Rgb{ .r = 0x1f, .g = 0x1f, .b = 0x28 }, ghostty.background);

    for ([_]Config.WindowTheme{ .system, .light, .dark }) |theme| {
        config.@"window-theme" = theme;
        try testing.expectEqual(@as(?Colors, null), fromConfig(&config));
    }
}

test "mix" {
    const testing = std.testing;
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    try testing.expectEqual(black, mix(black, white, 0));
    try testing.expectEqual(white, mix(black, white, 1));
    try testing.expectEqual(Rgb{ .r = 128, .g = 128, .b = 128 }, mix(black, white, 0.5));
    try testing.expectEqual(white, mix(black, white, 2));
    try testing.expectEqual(black, mix(black, white, -1));
    const bg: Rgb = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };
    try testing.expectEqual(Rgb{ .r = 62, .g = 62, .b = 70 }, mix(bg, white, 0.14));
    try testing.expectEqual(Rgb{ .r = 0x1f, .g = 0x1f, .b = 0x28 }, mix(bg, bg, 0.5));
}

test "write the GX Mocha colors" {
    const testing = std.testing;
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const bg: Rgb = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };
    const fg: Rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    try write(&writer, .{
        .bar_background = bg,
        .bar_foreground = fg,
        .background = bg,
        .foreground = fg,
        .accent = .{ .r = 0x89, .g = 0xb4, .b = 0xfa },
    });
    const css = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, css, "background-color: rgb(31,31,40);\n  color: rgb(255,255,255);") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".window tabbar tab:hover {\n  background-color: rgb(47,47,55);") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".window tabbar tab:selected {\n  background-color: rgb(58,58,66);") != null);
    try testing.expect(std.mem.indexOf(u8, css, "box-shadow: inset 0 0 0 1px rgba(137,180,250,0.45);") != null);
    try testing.expect(std.mem.indexOf(u8, css, "background-image: image(rgb(65,65,72));\n  box-shadow: none;") != null);
    try testing.expectEqual(std.mem.count(u8, css, "{"), std.mem.count(u8, css, "}"));
}
