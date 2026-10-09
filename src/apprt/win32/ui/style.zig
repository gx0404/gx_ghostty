//! Design tokens of the win32 UI, derived from the terminal colors so the
//! chrome and popups match the active theme: colors (`Tokens`), metrics in
//! DIPs (`metrics`, `font_size`) and the helpers to scale them to pixels
//! and to derive hover/pressed shades.
//!
//! Tokens are cheap to compute; build them from the current config when
//! painting (or cache them per config change).
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const d2d = @import("d2d.zig");

pub const Color = d2d.Color;

/// The UI colors for one terminal theme.
pub const Tokens = struct {
    /// Whether the theme is dark (from the background luminance).
    dark: bool,

    /// The terminal background and foreground.
    background: Color,
    foreground: Color,

    /// Accent: the cursor color when configured, else the palette blue.
    accent: Color,
    /// Text drawn on top of `accent`.
    on_accent: Color,

    /// Fill of chrome bars (tab bar) and panels, slightly off the
    /// terminal background.
    surface: Color,
    /// Fill of popups and flyouts, a step further from the background.
    surface_raised: Color,
    /// Hover and pressed fills for items on `surface`/`surface_raised`.
    hover: Color,
    pressed: Color,
    /// Selected item fill (accent tinted).
    selected: Color,
    /// Hairline borders and separators.
    border: Color,

    /// Fill of the title bar row with the solid window material: a shade
    /// darker than the terminal background (lighter for near-black
    /// backgrounds), so the active tab, which has the terminal
    /// background, stands out of the strip.
    title_bar: Color,
    /// The 1px Windows 11 window border.
    window_border: Color,
    /// Translucent overlays for hovered and pressed chrome buttons and
    /// tabs; they work on the solid strip and over a backdrop material.
    overlay_hover: Color,
    overlay_pressed: Color,

    text: Color,
    text_secondary: Color,
    text_disabled: Color,

    /// The red of a hovered close button (Windows 11 caption close).
    close_hover: Color = Color.hex(0xc42b1c),
    close_hover_text: Color = Color.hex(0xffffff),
    /// The pressed caption close button.
    close_pressed: Color = Color.hex(0xc42b1c).withAlpha(0.9),

    pub fn fromConfig(config: *const Config) Tokens {
        const bg = fromConfigColor(config.background);
        const fg = fromConfigColor(config.foreground);
        const accent = accent: {
            if (config.@"cursor-color") |cursor| switch (cursor) {
                .color => |c| break :accent fromConfigColor(c),
                .@"cell-foreground", .@"cell-background" => {},
            };
            const blue = config.palette.value[4];
            break :accent Color.rgb(blue.r, blue.g, blue.b);
        };
        return fromColors(bg, fg, accent);
    }

    pub fn fromColors(bg: Color, fg: Color, accent: Color) Tokens {
        const surface = mix(bg, fg, 0.06);
        const surface_raised = mix(bg, fg, 0.10);
        const dark = luminance(bg) < 0.5;
        const black = Color.hex(0x000000);
        return .{
            .dark = dark,
            .background = bg,
            .foreground = fg,
            .accent = accent,
            .on_accent = if (luminance(accent) < 0.5) Color.hex(0xffffff) else Color.hex(0x000000),
            .surface = surface,
            .surface_raised = surface_raised,
            .hover = mix(surface_raised, fg, 0.08),
            .pressed = mix(surface_raised, fg, 0.14),
            .selected = mix(surface_raised, accent, 0.28),
            .border = mix(bg, fg, 0.16),
            .title_bar = if (!dark)
                mix(bg, black, 0.08)
            else if (luminance(bg) < 0.03)
                mix(bg, fg, 0.08)
            else
                mix(bg, black, 0.32),
            .window_border = mix(bg, fg, if (dark) 0.18 else 0.22),
            .overlay_hover = fg.withAlpha(if (dark) 0.08 else 0.06),
            .overlay_pressed = fg.withAlpha(if (dark) 0.05 else 0.04),
            .text = fg,
            .text_secondary = mix(fg, bg, 0.35),
            .text_disabled = mix(fg, bg, 0.6),
        };
    }
};

fn fromConfigColor(c: Config.Color) Color {
    return Color.rgb(c.r, c.g, c.b);
}

/// Linear mix of two colors: `t` = 0 gives `a`, 1 gives `b`.
pub fn mix(a: Color, b: Color, t: f32) Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

/// The hover shade of `base` (moved toward the foreground).
pub fn hoverOf(base: Color, tokens: Tokens) Color {
    return mix(base, tokens.foreground, 0.08);
}

/// The pressed shade of `base`.
pub fn pressedOf(base: Color, tokens: Tokens) Color {
    return mix(base, tokens.foreground, 0.14);
}

/// Relative luminance (Rec. 709) of a color, 0..1.
pub fn luminance(c: Color) f32 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// Metrics in DIPs (pixels at 96 DPI); scale with `px`.
pub const metrics = struct {
    /// Height of the title bar row that holds the tabs and the caption
    /// buttons (Windows 11 tabbed apps).
    pub const title_bar_height: f32 = 40;
    /// Width of a caption button (minimize, maximize/restore, close).
    pub const caption_button_width: f32 = 46;
    /// Size of the caption button glyphs.
    pub const caption_glyph_size: f32 = 10;
    /// Height of the tab bar without caption buttons (native title bar,
    /// borderless and fullscreen windows).
    pub const tab_bar_height: f32 = 36;
    /// Corner radius of tabs, buttons and list items.
    pub const corner_radius: f32 = 8;
    /// Corner radius of popups (matches the DWM round corner).
    pub const popup_radius: f32 = 8;
    /// Hairline border width.
    pub const border_width: f32 = 1;
    /// Horizontal and vertical content padding.
    pub const padding_x: f32 = 12;
    pub const padding_y: f32 = 8;
    /// Gap between related elements.
    pub const gap: f32 = 8;
    /// Height of list and menu items.
    pub const item_height: f32 = 32;
    /// Height of text inputs.
    pub const input_height: f32 = 32;
    /// Icon glyph size.
    pub const icon_size: f32 = 16;
};

/// UI font sizes in DIPs (Windows 11 type ramp).
pub const font_size = struct {
    pub const caption: f32 = 12;
    pub const body: f32 = 14;
    pub const body_strong: f32 = 14;
    pub const subtitle: f32 = 20;
    pub const title: f32 = 28;
};

/// A DIP length in pixels at `scale` (DPI / 96).
pub fn px(length: f32, scale: f32) i32 {
    return @intFromFloat(@round(length * scale));
}

/// A pixel length in DIPs at `scale`.
pub fn dip(pixels: i32, scale: f32) f32 {
    return @as(f32, @floatFromInt(pixels)) / scale;
}

test "mix" {
    const testing = std.testing;
    const black = Color.hex(0x000000);
    const white = Color.hex(0xffffff);
    const mid = mix(black, white, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid.r, 0.001);
    try testing.expectEqual(@as(u32, 0x808080), mix(black, white, 0.5).colorRef());
}

test "tokens follow the background" {
    const testing = std.testing;
    const dark = Tokens.fromColors(Color.hex(0x1e1e2e), Color.hex(0xcdd6f4), Color.hex(0x89b4fa));
    try testing.expect(dark.dark);
    try testing.expect(luminance(dark.surface) > luminance(dark.background));
    try testing.expect(luminance(dark.hover) > luminance(dark.surface_raised));

    const light = Tokens.fromColors(Color.hex(0xffffff), Color.hex(0x000000), Color.hex(0x0067c0));
    try testing.expect(!light.dark);
    try testing.expect(luminance(light.surface) < luminance(light.background));
    try testing.expectEqual(@as(u32, 0xffffff), light.on_accent.colorRef());
}

test "the title bar strip contrasts with the active tab" {
    const testing = std.testing;
    // The active tab has the terminal background; the strip is darker.
    const dark = Tokens.fromColors(Color.hex(0x1f1f28), Color.hex(0xffffff), Color.hex(0xf5e0dc));
    try testing.expect(luminance(dark.title_bar) < luminance(dark.background));
    const light = Tokens.fromColors(Color.hex(0xeff1f5), Color.hex(0x4c4f69), Color.hex(0x1e66f5));
    try testing.expect(luminance(light.title_bar) < luminance(light.background));
    // A black background cannot get darker: the strip is lighter.
    const black = Tokens.fromColors(Color.hex(0x000000), Color.hex(0xcccccc), Color.hex(0x3d8ef8));
    try testing.expect(luminance(black.title_bar) > luminance(black.background));
    // Overlays are translucent foreground.
    try testing.expect(dark.overlay_hover.a > 0 and dark.overlay_hover.a < 0.5);
}

test "px rounds" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 36), px(metrics.tab_bar_height, 1.0));
    try testing.expectEqual(@as(i32, 54), px(metrics.tab_bar_height, 1.5));
    try testing.expectEqual(@as(i32, 12), px(8, 1.5));
}
