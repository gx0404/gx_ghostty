//! The colors of the window chrome, the same for the win32 title bar and
//! tab bar and for the GTK header bar and tab bar:
//!
//! - the tab strip (`titleBar`) a step darker than the terminal
//!   background: 8% toward black for light backgrounds, 32% for dark
//!   ones, more when that contrasts less than `strip_min_contrast` with
//!   the background; backgrounds too dark for that get a strip a step
//!   toward the foreground instead;
//! - the active tab in the terminal background, so that it joins the
//!   terminal, and inactive tab text with a 4.5:1 floor on the strip;
//! - translucent hover and pressed overlays in the strip text color,
//!   pressed lighter than hover (Fluent), and the tab separators;
//! - the split divider (`split-divider-color`, else 15% of the foreground
//!   mixed into the background with a 1.4:1 floor) and the accent for a
//!   divider being hovered or dragged;
//! - the 1px Windows 11 window border and the red of a hovered caption
//!   close button;
//! - the brand signature, the accent bar along the top of the selected tab
//!   (`ui_metrics.signature.bar` thick): the accent moved to 3:1 against
//!   every fill the bar is drawn on (`signature`, `tabSignature`).
//!
//! `window-titlebar-background` and `-foreground` replace the strip
//! colors where the GTK app honors them (`Options.fromConfig`). In high
//! contrast the chrome takes the system colors (`Chrome.fromSystem`).
const chrome = @This();

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config/Config.zig");
const ui_color = @import("ui_color.zig");
const ui_tokens = @import("ui_tokens.zig");
const Color = ui_color.Color;

/// The least contrast of the tab strip with the terminal background, so
/// the active tab stands out of it.
pub const strip_min_contrast: f32 = 1.12;

/// The Windows 11 caption close button: hovered, its glyph, pressed.
pub const close_hover = Color.hex(0xc42b1c);
pub const close_hover_text = Color.white;
pub const close_pressed: Color = .{ .r = close_hover.r, .g = close_hover.g, .b = close_hover.b, .a = 0.9 };

/// Colors the configuration sets for the chrome.
pub const Options = struct {
    /// `split-divider-color`.
    divider: ?Color = null,
    /// `window-titlebar-background` and `window-titlebar-foreground`.
    title_bar: ?Color = null,
    title_bar_text: ?Color = null,

    /// The chrome colors of `config`. The title bar colors are GTK only
    /// and, like the rest of the GTK look, apply with `window-theme`
    /// `auto` or `ghostty`.
    pub fn fromConfig(config: *const Config) Options {
        const titlebar = builtin.target.os.tag != .windows and switch (config.@"window-theme") {
            .auto, .ghostty => true,
            .system, .light, .dark => false,
        };
        return .{
            .divider = if (config.@"split-divider-color") |c| fromConfigColor(c) else null,
            .title_bar = if (!titlebar) null else if (config.@"window-titlebar-background") |c| fromConfigColor(c) else null,
            .title_bar_text = if (!titlebar) null else if (config.@"window-titlebar-foreground") |c| fromConfigColor(c) else null,
        };
    }
};

fn fromConfigColor(c: Config.Color) Color {
    return Color.rgb(c.r, c.g, c.b);
}

pub const Chrome = struct {
    /// Whether the strip counts as dark (`ui_color.isDark`).
    dark: bool,
    /// The fill of the title bar and the tab strip.
    title_bar: Color,
    /// Text on the strip: the active tab's title.
    text: Color,
    /// Titles of inactive tabs.
    text_inactive: Color,
    /// The fill of the active tab.
    active_tab: Color,
    /// Translucent overlays for hovered and pressed tabs and buttons on
    /// the strip; they also work over a backdrop material.
    hover: Color,
    pressed: Color,
    /// The translucent line between inactive tabs.
    tab_separator: Color,
    /// The split divider, and the divider being hovered or dragged.
    divider: Color,
    divider_active: Color,
    /// The 1px window border.
    window_border: Color,
    /// The hovered caption close button, its glyph, and the pressed one.
    close_hover: Color = chrome.close_hover,
    close_hover_text: Color = chrome.close_hover_text,
    close_pressed: Color = chrome.close_pressed,

    pub fn derive(tokens: *const ui_tokens.Tokens, options: Options) Chrome {
        const bg = tokens.background;
        const fg = tokens.foreground;
        const strip = options.title_bar orelse titleBar(bg, fg);
        const text = options.title_bar_text orelse fg;
        const dark = ui_color.isDark(strip);
        return .{
            .dark = dark,
            .title_bar = strip,
            .text = text,
            .text_inactive = ui_color.ensureContrast(ui_color.mix(text, strip, 0.35), strip, ui_tokens.floor.text),
            .active_tab = bg,
            .hover = text.withAlpha(if (dark) 0.08 else 0.06),
            .pressed = text.withAlpha(if (dark) 0.05 else 0.04),
            .tab_separator = text.withAlpha(0.16),
            .divider = options.divider orelse divider(bg, fg),
            .divider_active = tokens.accent,
            .window_border = ui_color.mix(bg, fg, if (tokens.dark) 0.18 else 0.22),
        };
    }

    /// The chrome in the high contrast colors `c`: the window colors, with
    /// the highlight for hovered, pressed and active parts.
    pub fn fromSystem(c: ui_tokens.SystemColors) Chrome {
        return .{
            .dark = ui_color.isDark(c.window),
            .title_bar = c.window,
            .text = c.window_text,
            .text_inactive = c.window_text,
            .active_tab = c.window,
            .hover = c.highlight,
            .pressed = c.highlight,
            .tab_separator = c.window_text,
            .divider = c.window_text,
            .divider_active = c.highlight,
            .window_border = c.window_text,
            .close_hover = c.highlight,
            .close_hover_text = c.highlight_text,
            .close_pressed = c.highlight,
        };
    }
};

/// The fill of the tab strip for the terminal colors `bg` and `fg` (see
/// the file header).
pub fn titleBar(bg: Color, fg: Color) Color {
    const step: f32 = if (ui_color.isDark(bg)) 0.32 else 0.08;
    if (ui_color.mixToContrast(bg, Color.black, step, bg, strip_min_contrast)) |darker| return darker;
    const tint = ui_color.limitChroma(fg, ui_tokens.max_tint_chroma);
    return ui_color.mixToContrast(bg, tint, 0.08, bg, strip_min_contrast) orelse
        ui_color.mixToContrast(bg, Color.white, 0.08, bg, strip_min_contrast) orelse
        Color.white;
}

/// The split divider for the terminal colors `bg` and `fg` when
/// `split-divider-color` is not set.
pub fn divider(bg: Color, fg: Color) Color {
    const tint = ui_color.limitChroma(fg, ui_tokens.max_tint_chroma);
    return ui_color.ensureContrast(ui_color.mix(bg, tint, 0.15), bg, ui_tokens.floor.border);
}

/// The accent bar of the brand signature: the accent, moved to 3:1 against
/// every fill it is drawn on (`fills`, taken as opaque: a translucent fill
/// shows the terminal or the strip through, which are among the fills).
/// At most eight fills count.
pub fn signature(accent: Color, fills: []const Color) Color {
    var opaque_fills: [8]Color = undefined;
    const n = @min(fills.len, opaque_fills.len);
    for (fills[0..n], opaque_fills[0..n]) |fill, *out| out.* = fill.withAlpha(1);
    return ui_color.ensureContrastAll(accent.withAlpha(1), opaque_fills[0..n], ui_tokens.floor.non_text);
}

/// The signature on the selected tab of the strip `bars`, whose fill is
/// `selected`: at 3:1 on it plain, hovered and pressed, and on the terminal
/// background `background`, which a translucent tab shows through. The
/// win32 and the GTK tab bars draw this color.
pub fn tabSignature(accent: Color, bars: Chrome, selected: Color, background: Color) Color {
    return signature(accent, &.{
        selected,
        ui_color.over(bars.hover, selected),
        ui_color.over(bars.pressed, selected),
        background,
    });
}

const testing = std.testing;
const contrast = ui_color.contrast;
const luminance = ui_color.luminance;

fn chromeFor(bg: u24, fg: u24) Chrome {
    const tokens = ui_tokens.Tokens.derive(.{ .background = Color.hex(bg), .foreground = Color.hex(fg) });
    return .derive(&tokens, .{});
}

test "the strip is a step darker than a dark background" {
    // GX Mocha: 32% toward black is just under 1.12:1, so a little more.
    const c = chromeFor(0x1f1f28, 0xffffff);
    try testing.expect(luminance(c.title_bar) < luminance(c.active_tab));
    try testing.expect(contrast(c.title_bar, c.active_tab) >= strip_min_contrast);
    try testing.expect(contrast(c.title_bar, c.active_tab) < 1.15);
    try testing.expectEqual(@as(u24, 0x1f1f28), c.active_tab.toHex());
    try testing.expect(c.dark);
}

test "the strip of a light background darkens by 8%" {
    const bg = Color.hex(0xeff1f5);
    const c = chromeFor(0xeff1f5, 0x4c4f69);
    try testing.expectEqual(ui_color.mix(bg, Color.black, 0.08), c.title_bar);
    try testing.expect(contrast(c.title_bar, bg) >= strip_min_contrast);
    try testing.expect(!c.dark);
}

test "a background too dark to step down gets a lighter strip" {
    // Before, #0c0c0c got a strip at 1.02:1 that hid the active tab.
    for ([_]u24{ 0x0c0c0c, 0x000000, 0x050508 }) |bg| {
        const c = chromeFor(bg, 0xcccccc);
        try testing.expect(luminance(c.title_bar) > luminance(Color.hex(bg)));
        try testing.expect(contrast(c.title_bar, Color.hex(bg)) >= strip_min_contrast);
    }
    // Even with a foreground as dark as the background.
    try testing.expect(contrast(titleBar(Color.black, Color.black), Color.black) >= strip_min_contrast);
}

test "inactive tab text is readable on the strip" {
    for ([_][2]u24{
        .{ 0xfdf6e3, 0x657b83 },
        .{ 0x1f1f28, 0xffffff },
        .{ 0x3a3a3a, 0x7a7a7a },
        .{ 0x0c0c0c, 0xcccccc },
    }) |colors| {
        const c = chromeFor(colors[0], colors[1]);
        try testing.expect(contrast(c.text_inactive, c.title_bar) >= ui_tokens.floor.text);
    }
}

test "overlays are translucent strip text, pressed lighter than hover" {
    const c = chromeFor(0x1f1f28, 0xffffff);
    try testing.expectEqual(@as(u24, 0xffffff), c.hover.toHex());
    try testing.expect(c.hover.a > 0 and c.hover.a < 0.5);
    try testing.expect(c.pressed.a < c.hover.a);
    try testing.expect(c.tab_separator.a > c.hover.a);
    const light = chromeFor(0xffffff, 0x000000);
    try testing.expect(light.pressed.a < light.hover.a);
}

test "the divider mixes the foreground in, or takes split-divider-color" {
    // GX Mocha, as the GTK look had it.
    const c = chromeFor(0x1f1f28, 0xffffff);
    try testing.expectEqual(@as(u24, 0x414148), c.divider.toHex());
    try testing.expect(contrast(c.divider, Color.hex(0x1f1f28)) >= ui_tokens.floor.border);
    // A dim foreground still gives a visible line.
    const dim = chromeFor(0x202020, 0x262626);
    try testing.expect(contrast(dim.divider, Color.hex(0x202020)) >= ui_tokens.floor.border);

    const tokens = ui_tokens.Tokens.derive(.{ .background = Color.hex(0x1f1f28), .foreground = Color.white, .blue = Color.hex(0x89b4fa) });
    const custom: Chrome = .derive(&tokens, .{ .divider = Color.hex(0x808080) });
    try testing.expectEqual(@as(u24, 0x808080), custom.divider.toHex());
    try testing.expectEqual(tokens.accent, custom.divider_active);
}

test "title bar options replace the strip colors" {
    const tokens = ui_tokens.Tokens.derive(.{ .background = Color.hex(0x1f1f28), .foreground = Color.white });
    const c: Chrome = .derive(&tokens, .{ .title_bar = Color.hex(0xf0f0f0), .title_bar_text = Color.hex(0x202020) });
    try testing.expectEqual(@as(u24, 0xf0f0f0), c.title_bar.toHex());
    try testing.expectEqual(@as(u24, 0x202020), c.text.toHex());
    try testing.expect(!c.dark);
    try testing.expect(contrast(c.text_inactive, c.title_bar) >= ui_tokens.floor.text);
    try testing.expectEqual(@as(u24, 0x202020), c.hover.toHex());
    // The active tab still joins the terminal.
    try testing.expectEqual(@as(u24, 0x1f1f28), c.active_tab.toHex());
}

test "the caption close button is red, or the highlight in high contrast" {
    const c = chromeFor(0x1f1f28, 0xffffff);
    try testing.expectEqual(close_hover, c.close_hover);
    try testing.expectEqual(close_hover_text, c.close_hover_text);
    try testing.expectEqual(close_pressed, c.close_pressed);
    const system: ui_tokens.SystemColors = .{};
    const hc: Chrome = .fromSystem(system);
    try testing.expectEqual(system.window, hc.title_bar);
    try testing.expectEqual(system.window_text, hc.window_border);
    try testing.expectEqual(system.highlight, hc.hover);
    try testing.expectEqual(system.highlight, hc.close_hover);
    try testing.expectEqual(system.highlight_text, hc.close_hover_text);
    try testing.expect(hc.dark);
}

const gx_mocha: ui_tokens.Scheme = .{
    .background = Color.hex(0x1f1f28),
    .foreground = Color.hex(0xcdd6f4),
    .cursor = Color.hex(0xf5e0dc),
    .blue = Color.hex(0x89b4fa),
    .bright_blue = Color.hex(0x74a8fc),
    .red = Color.hex(0xf38ba8),
};
const gx_latte: ui_tokens.Scheme = .{
    .background = Color.hex(0xeff1f5),
    .foreground = Color.hex(0x4c4f69),
    .cursor = Color.hex(0xdc8a78),
    .blue = Color.hex(0x1e66f5),
    .bright_blue = Color.hex(0x456eff),
    .red = Color.hex(0xd20f39),
};

fn expectSignatureOn(sig: Color, fills: []const Color) !void {
    try testing.expectEqual(@as(f32, 1), sig.a);
    for (fills) |fill| try testing.expect(contrast(sig, fill.withAlpha(1)) >= ui_tokens.floor.non_text);
}

test "the signature marks the selected tab at 3:1 on every fill" {
    for ([_]ui_tokens.Scheme{ gx_mocha, gx_latte }) |base| {
        for ([_]ui_tokens.Accent{ .brand, .theme, .{ .color = Color.hex(0x777777) } }) |accent| {
            var scheme = base;
            scheme.accent = accent;
            const tokens: ui_tokens.Tokens = .derive(scheme);
            const bg = tokens.background;
            // The derived strip (win32, GTK with `window-theme = auto`), a
            // strip in the terminal background (GTK `window-theme =
            // ghostty`, which selects a step from it) and a translucent tab.
            const strips = [_]Options{ .{}, .{ .title_bar = bg } };
            for (strips) |options| {
                const bars: Chrome = .derive(&tokens, options);
                for ([_]Color{ bars.active_tab, ui_color.mix(bars.title_bar, bars.text, 0.12), bg.withAlpha(0.6) }) |selected| {
                    const sig = tabSignature(tokens.accent, bars, selected, bg);
                    try expectSignatureOn(sig, &.{
                        selected,
                        ui_color.over(bars.hover, selected),
                        ui_color.over(bars.pressed, selected),
                        bg,
                    });
                }
            }
            // A single tab on a strip tinted for a superuser or remote
            // session (palette 1 mixed in, as GTK tints it).
            const bars: Chrome = .derive(&tokens, .{});
            const tinted = ui_color.mix(bars.title_bar, base.red.?, 0.24);
            try expectSignatureOn(signature(tokens.accent, &.{ tinted, bars.title_bar }), &.{ tinted, bars.title_bar });
        }
    }
}

test "the brand signature keeps the brand purple where it reads" {
    var mocha = gx_mocha;
    mocha.accent = .brand;
    const dark: ui_tokens.Tokens = .derive(mocha);
    const bars: Chrome = .derive(&dark, .{});
    try testing.expectEqual(@as(u24, 0xcba6f7), tabSignature(dark.accent, bars, bars.active_tab, dark.background).toHex());

    var latte = gx_latte;
    latte.accent = .brand;
    const light: ui_tokens.Tokens = .derive(latte);
    const light_bars: Chrome = .derive(&light, .{});
    const sig = tabSignature(light.accent, light_bars, light_bars.active_tab, light.background);
    try testing.expect(contrast(sig, light.background) >= ui_tokens.floor.non_text);
    try testing.expect(ui_color.toOklch(sig).c > 0.1);
}

test "the signature ignores fills past eight and their alpha" {
    const accent = Color.hex(0x404040).withAlpha(0.5);
    const sig = signature(accent, &.{Color.black.withAlpha(0.1)});
    try testing.expectEqual(@as(f32, 1), sig.a);
    try testing.expect(contrast(sig, Color.black) >= ui_tokens.floor.non_text);
    var many: [10]Color = @splat(Color.white);
    many[9] = Color.black;
    try testing.expect(contrast(signature(Color.hex(0x7a7a7a), &many), Color.white) >= ui_tokens.floor.non_text);
}

test "Options.fromConfig" {
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    try testing.expectEqual(Options{}, Options.fromConfig(&config));

    config.@"split-divider-color" = .{ .r = 1, .g = 2, .b = 3 };
    config.@"window-titlebar-background" = .{ .r = 4, .g = 5, .b = 6 };
    config.@"window-titlebar-foreground" = .{ .r = 7, .g = 8, .b = 9 };
    config.@"window-theme" = .ghostty;
    const options = Options.fromConfig(&config);
    try testing.expectEqual(@as(u24, 0x010203), options.divider.?.toHex());
    if (builtin.target.os.tag == .windows) {
        try testing.expectEqual(@as(?Color, null), options.title_bar);
        try testing.expectEqual(@as(?Color, null), options.title_bar_text);
    } else {
        try testing.expectEqual(@as(u24, 0x040506), options.title_bar.?.toHex());
        try testing.expectEqual(@as(u24, 0x070809), options.title_bar_text.?.toHex());
    }

    config.@"window-theme" = .dark;
    const dark = Options.fromConfig(&config);
    try testing.expectEqual(@as(?Color, null), dark.title_bar);
    try testing.expectEqual(@as(u24, 0x010203), dark.divider.?.toHex());
}
