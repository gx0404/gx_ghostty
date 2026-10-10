//! The colors of the Ghostty GX interface, derived from the terminal
//! colors the same way for the win32 popups and dialogs and for the GTK
//! look (the win32 `ui/style.zig` carries these tokens as they are):
//!
//! - surfaces stepped from the background toward the foreground
//!   (`surface` for bars and panels, `surface_raised` for popups) with
//!   hover, pressed and selected fills, and control fills at rest, hovered
//!   and pressed; pressed is fainter than hovered, as in Fluent;
//! - text levels with WCAG contrast floors on the background, `surface`
//!   and `surface_raised` alike (`text_secondary` and `text_placeholder`
//!   4.5:1, `text_tertiary` 3:1; `text_disabled` has none and is only for
//!   disabled items), and borders with 1.4:1 on all three;
//! - the accent (`ui_color.pickAccent` over the cursor color, palette 4
//!   and palette 12; at least 3:1 on `surface_raised`), the text on it,
//!   accent-colored text (4.5:1) and the text selection;
//! - the keyboard focus ring: WinUI's foreground outer stroke (3:1 on the
//!   surfaces) with an inner stroke in the popup surface, which the win32
//!   controls draw, and a one-color ring in the accent for toolkits whose
//!   rings follow the accent (GTK);
//! - the caution, success and critical colors of Fluent (3:1 on
//!   `surface_raised`).
//!
//! The foreground is limited to a small chroma before it is mixed into
//! surfaces, so a saturated foreground does not tint them. In high
//! contrast the tokens are the system colors (`Tokens.fromSystem`).
//! `Cache` keeps the tokens of the last scheme; the window chrome is in
//! `chrome.zig`.
const std = @import("std");
const Config = @import("../config/Config.zig");
const theme_swatch = @import("theme_swatch.zig");
const ui_color = @import("ui_color.zig");
const Color = ui_color.Color;

/// The contrast floors of the tokens.
pub const floor = struct {
    /// Readable text: `text_secondary`, `text_placeholder`,
    /// `accent_text`.
    pub const text: f32 = 4.5;
    /// Large or supplementary text: `text_tertiary`.
    pub const text_tertiary: f32 = 3;
    /// Shapes that carry meaning: the accent, the focus stroke and the
    /// status colors.
    pub const non_text: f32 = 3;
    /// Borders and dividers.
    pub const border: f32 = 1.4;
};

/// The most OKLCH chroma of the foreground mixed into surfaces.
pub const max_tint_chroma: f32 = 0.04;

/// How far hovered and pressed fills move from the fill below them toward
/// the foreground: pressed less than hovered (Fluent).
pub const hover_share: f32 = 0.08;
pub const pressed_share: f32 = 0.05;

/// The terminal colors the tokens are derived from.
pub const Scheme = struct {
    background: Color,
    foreground: Color,
    /// The accent candidates, in order: the cursor color (only when the
    /// theme sets a color, not `cell-foreground` or `cell-background`),
    /// palette 4 and palette 12.
    cursor: ?Color = null,
    blue: ?Color = null,
    bright_blue: ?Color = null,

    pub fn fromConfig(config: *const Config) Scheme {
        return .{
            .background = fromConfigColor(config.background),
            .foreground = fromConfigColor(config.foreground),
            .cursor = if (config.@"cursor-color") |cursor| switch (cursor) {
                .color => |c| fromConfigColor(c),
                .@"cell-foreground", .@"cell-background" => null,
            } else null,
            .blue = fromConfigColor(config.palette.value[4]),
            .bright_blue = fromConfigColor(config.palette.value[12]),
        };
    }

    /// The scheme of a theme file (`theme_swatch.parseThemeColors`), for
    /// previews; a theme without a background or foreground has the
    /// Ghostty default.
    pub fn fromTheme(colors: theme_swatch.ThemeColors) Scheme {
        const defaults: theme_swatch.Swatch = .{};
        return .{
            .background = fromRgb(colors.background orelse defaults.background),
            .foreground = fromRgb(colors.foreground orelse defaults.foreground),
            .cursor = if (colors.cursor) |c| fromRgb(c) else null,
            .blue = if (colors.palette[4]) |c| fromRgb(c) else null,
            .bright_blue = if (colors.palette[12]) |c| fromRgb(c) else null,
        };
    }
};

fn fromConfigColor(c: anytype) Color {
    return Color.rgb(c.r, c.g, c.b);
}

fn fromRgb(c: theme_swatch.Rgb) Color {
    return Color.rgb(c.r, c.g, c.b);
}

/// The system colors of a high contrast theme: the Windows high contrast
/// colors (`GetSysColor`), the same roles as the CSS system colors. The
/// defaults are a black theme.
pub const SystemColors = struct {
    /// Window background and text (COLOR_WINDOW, COLOR_WINDOWTEXT; CSS
    /// Canvas, CanvasText).
    window: Color = Color.black,
    window_text: Color = Color.white,
    /// Selected and hovered items (COLOR_HIGHLIGHT, COLOR_HIGHLIGHTTEXT;
    /// CSS Highlight, HighlightText).
    highlight: Color = Color.hex(0x1aebff),
    highlight_text: Color = Color.black,
    /// Buttons (COLOR_BTNFACE, COLOR_BTNTEXT; CSS ButtonFace, ButtonText).
    button_face: Color = Color.black,
    button_text: Color = Color.white,
    /// Disabled text (COLOR_GRAYTEXT; CSS GrayText).
    gray_text: Color = Color.hex(0x3ff23f),
    /// Hyperlinks (COLOR_HOTLIGHT; CSS LinkText).
    hotlight: Color = Color.hex(0xffff00),
};

pub const Tokens = struct {
    /// Whether the background counts as dark (`ui_color.isDark`).
    dark: bool,
    /// The system high contrast colors are in use (`fromSystem`): draw
    /// borders on cards, inputs and buttons, do not rely on fills alone.
    high_contrast: bool = false,

    /// The terminal background and foreground.
    background: Color,
    foreground: Color,

    /// Fill of bars and panels, a step off the background.
    surface: Color,
    /// Fill of popups and dialogs, a step further.
    surface_raised: Color,
    /// Hover and pressed fills for items on `surface_raised`, and the text
    /// on them (it differs from `text` in high contrast).
    hover: Color,
    pressed: Color,
    hover_text: Color,
    /// Fill of the selected item, tinted with the accent, and the text on
    /// it (4.5:1).
    selected: Color,
    selected_text: Color,
    /// Hairline borders and separators.
    border: Color,

    /// Fill of buttons and similar controls at rest, hovered and pressed,
    /// and their border.
    control_fill: Color,
    control_fill_hover: Color,
    control_fill_pressed: Color,
    control_border: Color,

    accent: Color,
    /// Text on `accent`.
    on_accent: Color,
    /// The accent as text, such as links.
    accent_text: Color,

    /// The keyboard focus ring of WinUI (FocusStrokeColorOuter and
    /// FocusStrokeColorInner): an outer stroke in the foreground, 3:1 on
    /// the surfaces, and an inner one in `surface_raised` that separates
    /// it from the control. The win32 controls draw these two.
    focus_stroke: Color,
    focus_stroke_inner: Color,
    /// A one-color focus ring in the accent, for toolkits whose focus rings
    /// follow the accent (GTK); `focus_stroke` when the accent does not
    /// reach 3:1 on `surface_raised`.
    focus_stroke_accent: Color,

    /// The selection of a text input and the text on it.
    text_selection: Color,
    on_text_selection: Color,

    text: Color,
    text_secondary: Color,
    text_tertiary: Color,
    text_placeholder: Color,
    text_disabled: Color,

    /// Warning markers and text.
    caution: Color,
    /// Success markers.
    success: Color,
    /// Errors and destructive actions.
    critical: Color,

    pub fn derive(scheme: Scheme) Tokens {
        const bg = scheme.background;
        const fg = scheme.foreground;
        const dark = ui_color.isDark(bg);
        const tint = ui_color.limitChroma(fg, max_tint_chroma);
        const surface = ui_color.mix(bg, tint, 0.06);
        const raised = ui_color.mix(bg, tint, 0.10);
        const surfaces = [_]Color{ bg, surface, raised };
        const accent = ui_color.pickAccent(&.{ scheme.cursor, scheme.blue, scheme.bright_blue }, raised);
        const on_accent = ui_color.onAccent(accent);
        const selected = ui_color.mix(raised, accent, 0.28);
        const border = ui_color.ensureContrastAll(ui_color.mix(bg, tint, 0.16), &surfaces, floor.border);
        const focus_stroke = ui_color.ensureContrastAll(fg, &surfaces, floor.non_text);
        return .{
            .dark = dark,
            .background = bg,
            .foreground = fg,
            .surface = surface,
            .surface_raised = raised,
            .hover = ui_color.mix(raised, tint, hover_share),
            .pressed = ui_color.mix(raised, tint, pressed_share),
            .hover_text = fg,
            .selected = selected,
            .selected_text = ui_color.ensureContrast(fg, selected, floor.text),
            .border = border,
            .control_fill = ui_color.mix(raised, tint, 0.06),
            .control_fill_hover = ui_color.mix(raised, tint, 0.09),
            .control_fill_pressed = ui_color.mix(raised, tint, 0.04),
            .control_border = border,
            .accent = accent,
            .on_accent = on_accent,
            .accent_text = ui_color.ensureContrast(accent, raised, floor.text),
            .focus_stroke = focus_stroke,
            .focus_stroke_inner = raised,
            .focus_stroke_accent = if (ui_color.contrast(accent, raised) >= floor.non_text) accent else focus_stroke,
            .text_selection = accent,
            .on_text_selection = on_accent,
            .text = fg,
            .text_secondary = ui_color.ensureContrastAll(ui_color.mix(fg, bg, 0.35), &surfaces, floor.text),
            .text_tertiary = ui_color.ensureContrastAll(ui_color.mix(fg, bg, 0.5), &surfaces, floor.text_tertiary),
            .text_placeholder = ui_color.ensureContrastAll(ui_color.mix(fg, bg, 0.4), &surfaces, floor.text),
            .text_disabled = ui_color.mix(fg, bg, 0.6),
            .caution = ui_color.ensureContrast(if (dark) Color.hex(0xfce100) else Color.hex(0x9d5d00), raised, floor.non_text),
            .success = ui_color.ensureContrast(if (dark) Color.hex(0x6ccb5f) else Color.hex(0x0f7b0f), raised, floor.non_text),
            .critical = ui_color.ensureContrast(if (dark) Color.hex(0xff99a4) else Color.hex(0xc42b1c), raised, floor.non_text),
        };
    }

    /// The tokens in the high contrast colors `c`, with `high_contrast`
    /// set.
    pub fn fromSystem(c: SystemColors) Tokens {
        return .{
            .dark = ui_color.isDark(c.window),
            .high_contrast = true,
            .background = c.window,
            .foreground = c.window_text,
            .surface = c.window,
            .surface_raised = c.window,
            .hover = c.highlight,
            .pressed = c.highlight,
            .hover_text = c.highlight_text,
            .selected = c.highlight,
            .selected_text = c.highlight_text,
            .border = c.window_text,
            .control_fill = c.button_face,
            .control_fill_hover = c.highlight,
            .control_fill_pressed = c.highlight,
            .control_border = c.button_text,
            .accent = c.highlight,
            .on_accent = c.highlight_text,
            .accent_text = c.hotlight,
            .focus_stroke = c.window_text,
            .focus_stroke_inner = c.window,
            .focus_stroke_accent = c.highlight,
            .text_selection = c.highlight,
            .on_text_selection = c.highlight_text,
            .text = c.window_text,
            .text_secondary = c.window_text,
            .text_tertiary = c.window_text,
            .text_placeholder = c.gray_text,
            .text_disabled = c.gray_text,
            .caution = c.window_text,
            .success = c.window_text,
            .critical = c.window_text,
        };
    }
};

/// The tokens of the last scheme asked for, derived again only when the
/// scheme changes. For one thread.
pub const Cache = struct {
    scheme: ?Scheme = null,
    tokens: Tokens = undefined,

    pub fn get(self: *Cache, scheme: Scheme) *const Tokens {
        if (self.scheme) |cached| {
            if (std.meta.eql(cached, scheme)) return &self.tokens;
        }
        self.tokens = .derive(scheme);
        self.scheme = scheme;
        return &self.tokens;
    }
};

const testing = std.testing;
const contrast = ui_color.contrast;
const luminance = ui_color.luminance;

const gx_mocha: Scheme = .{
    .background = Color.hex(0x1f1f28),
    .foreground = Color.hex(0xffffff),
    .cursor = Color.hex(0xf5e0dc),
    .blue = Color.hex(0x89b4fa),
    .bright_blue = Color.hex(0x89b4fa),
};

/// Schemes that stress the floors: Solarized Light, Gruvbox Light,
/// Catppuccin Latte, Dracula, Blue Matrix (a saturated foreground), the
/// Windows Terminal Campbell colors (a near-black background), a dim
/// gray scheme, plain black on white, Gruvbox Dark, the xterm colors on
/// black and on white, and a saturated matrix theme.
const samples = [_]Scheme{
    gx_mocha,
    .{ .background = Color.hex(0xfdf6e3), .foreground = Color.hex(0x657b83), .cursor = Color.hex(0x657b83), .blue = Color.hex(0x268bd2), .bright_blue = Color.hex(0x839496) },
    .{ .background = Color.hex(0xfbf1c7), .foreground = Color.hex(0x3c3836), .cursor = Color.hex(0x3c3836), .blue = Color.hex(0x458588), .bright_blue = Color.hex(0x076678) },
    .{ .background = Color.hex(0xeff1f5), .foreground = Color.hex(0x4c4f69), .cursor = Color.hex(0xdc8a78), .blue = Color.hex(0x1e66f5), .bright_blue = Color.hex(0x3878f6) },
    .{ .background = Color.hex(0x282a36), .foreground = Color.hex(0xf8f8f2), .cursor = Color.hex(0xf8f8f2), .blue = Color.hex(0xbd93f9), .bright_blue = Color.hex(0xd6acff) },
    .{ .background = Color.hex(0x101116), .foreground = Color.hex(0x00a2ff), .cursor = Color.hex(0x76ff9f), .blue = Color.hex(0x00b0ff), .bright_blue = Color.hex(0x6871ff) },
    .{ .background = Color.hex(0x0c0c0c), .foreground = Color.hex(0xcccccc), .blue = Color.hex(0x0037da), .bright_blue = Color.hex(0x3b78ff) },
    .{ .background = Color.hex(0x3a3a3a), .foreground = Color.hex(0x7a7a7a), .blue = Color.hex(0x4a4a4a), .bright_blue = Color.hex(0x5a5a5a) },
    .{ .background = Color.hex(0xffffff), .foreground = Color.hex(0x000000) },
    .{ .background = Color.hex(0x282828), .foreground = Color.hex(0xebdbb2), .cursor = Color.hex(0xebdbb2), .blue = Color.hex(0x458588), .bright_blue = Color.hex(0x83a598) },
    .{ .background = Color.hex(0x000000), .foreground = Color.hex(0xffffff), .blue = Color.hex(0x0000ee), .bright_blue = Color.hex(0x5c5cff) },
    .{ .background = Color.hex(0xffffff), .foreground = Color.hex(0x000000), .blue = Color.hex(0x0000ee), .bright_blue = Color.hex(0x5c5cff) },
    .{ .background = Color.hex(0x0f191c), .foreground = Color.hex(0x00ff9c), .cursor = Color.hex(0x00ff9c), .blue = Color.hex(0x00ff9c), .bright_blue = Color.hex(0x00ff9c) },
};

test "GX Mocha takes the palette blue as accent" {
    const t = Tokens.derive(gx_mocha);
    try testing.expect(t.dark);
    try testing.expectEqual(@as(u24, 0x89b4fa), t.accent.toHex());
    try testing.expectEqual(Color.black, t.on_accent);
    try testing.expectEqual(t.accent, t.focus_stroke_accent);
    try testing.expectEqual(t.accent, t.text_selection);
    // The WinUI focus ring: the foreground outside, the popup fill inside.
    try testing.expectEqual(Color.hex(0xffffff), t.focus_stroke);
    try testing.expectEqual(t.surface_raised, t.focus_stroke_inner);
    try testing.expectEqual(Color.hex(0xffffff), t.text);
    // White already contrasts 4.5:1 at 35% toward the background.
    try testing.expectEqual(ui_color.mix(t.foreground, t.background, 0.35), t.text_secondary);
}

test "every theme gets the contrast floors" {
    for (samples) |scheme| {
        const t = Tokens.derive(scheme);
        // Text, borders and the focus ring hold on every surface.
        for ([_]Color{ t.background, t.surface, t.surface_raised }) |on| {
            try testing.expect(contrast(t.text_secondary, on) >= floor.text);
            try testing.expect(contrast(t.text_placeholder, on) >= floor.text);
            try testing.expect(contrast(t.text_tertiary, on) >= floor.text_tertiary);
            try testing.expect(contrast(t.border, on) >= floor.border);
            try testing.expect(contrast(t.focus_stroke, on) >= floor.non_text);
        }
        const on = t.surface_raised;
        try testing.expect(contrast(t.accent_text, on) >= floor.text);
        try testing.expect(contrast(t.accent, on) >= floor.non_text);
        try testing.expect(contrast(t.focus_stroke_accent, on) >= floor.non_text);
        try testing.expect(contrast(t.caution, on) >= floor.non_text);
        try testing.expect(contrast(t.success, on) >= floor.non_text);
        try testing.expect(contrast(t.critical, on) >= floor.non_text);
        try testing.expect(contrast(t.selected_text, t.selected) >= floor.text);
        try testing.expect(contrast(t.on_text_selection, t.text_selection) >= floor.text);
        const other = if (std.meta.eql(t.on_accent, Color.black)) Color.white else Color.black;
        try testing.expect(contrast(t.on_accent, t.accent) >= contrast(other, t.accent));
    }
}

test "surfaces step from the background toward the foreground" {
    const dark = Tokens.derive(gx_mocha);
    try testing.expect(luminance(dark.surface) > luminance(dark.background));
    try testing.expect(luminance(dark.surface_raised) > luminance(dark.surface));
    try testing.expect(luminance(dark.hover) > luminance(dark.surface_raised));
    const light = Tokens.derive(samples[3]);
    try testing.expect(!light.dark);
    try testing.expect(luminance(light.surface) < luminance(light.background));
    try testing.expect(luminance(light.surface_raised) < luminance(light.surface));
}

test "pressed is lighter than hover" {
    for (samples) |scheme| {
        const t = Tokens.derive(scheme);
        const base = t.surface_raised;
        try testing.expect(contrast(t.pressed, base) < contrast(t.hover, base));
        // Controls: pressed fainter than at rest, hovered stronger.
        try testing.expect(contrast(t.control_fill_pressed, base) < contrast(t.control_fill, base));
        try testing.expect(contrast(t.control_fill, base) < contrast(t.control_fill_hover, base));
    }
}

test "high contrast tokens are the system colors" {
    const colors: SystemColors = .{
        .window = Color.hex(0xffffff),
        .window_text = Color.hex(0x000000),
        .highlight = Color.hex(0x37006e),
        .highlight_text = Color.hex(0xffffff),
        .button_face = Color.hex(0xffffff),
        .button_text = Color.hex(0x000000),
        .gray_text = Color.hex(0x600000),
        .hotlight = Color.hex(0x00009f),
    };
    const t = Tokens.fromSystem(colors);
    try testing.expect(t.high_contrast);
    try testing.expect(!t.dark);
    try testing.expectEqual(colors.highlight, t.selected);
    try testing.expectEqual(colors.highlight_text, t.selected_text);
    try testing.expectEqual(colors.highlight_text, t.hover_text);
    try testing.expectEqual(colors.window_text, t.text_secondary);
    try testing.expectEqual(colors.window_text, t.border);
    try testing.expectEqual(colors.window_text, t.focus_stroke);
    try testing.expectEqual(colors.hotlight, t.accent_text);
    try testing.expectEqual(colors.gray_text, t.text_disabled);
    try testing.expect(!Tokens.derive(gx_mocha).high_contrast);
}

test "a saturated foreground does not tint the surfaces" {
    const blue_matrix = samples[5];
    const t = Tokens.derive(blue_matrix);
    try testing.expect(ui_color.chroma(t.surface_raised) < 0.02);
    const tinted = ui_color.mix(blue_matrix.background, blue_matrix.foreground, 0.10);
    try testing.expect(ui_color.chroma(tinted) > ui_color.chroma(t.surface_raised));
}

test "Scheme.fromConfig reads the cursor color only when it is a color" {
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.background = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };
    config.foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    config.palette.value[4] = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };
    config.palette.value[12] = .{ .r = 0x74, .g = 0xc7, .b = 0xec };

    config.@"cursor-color" = null;
    const plain = Scheme.fromConfig(&config);
    try testing.expectEqual(@as(?Color, null), plain.cursor);
    try testing.expectEqual(@as(u24, 0x1f1f28), plain.background.toHex());
    try testing.expectEqual(@as(u24, 0x89b4fa), plain.blue.?.toHex());
    try testing.expectEqual(@as(u24, 0x74c7ec), plain.bright_blue.?.toHex());

    config.@"cursor-color" = .@"cell-foreground";
    try testing.expectEqual(@as(?Color, null), Scheme.fromConfig(&config).cursor);
    config.@"cursor-color" = .{ .color = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 } };
    try testing.expectEqual(@as(u24, 0xf38ba8), Scheme.fromConfig(&config).cursor.?.toHex());
}

test "Scheme.fromTheme reads a theme file" {
    const scheme = Scheme.fromTheme(theme_swatch.parseThemeColors(
        \\palette = 4=#89b4fa
        \\cursor-color = #f5e0dc
        \\foreground = #ffffff
        \\
    ));
    const defaults: theme_swatch.Swatch = .{};
    try testing.expectEqual(fromRgb(defaults.background), scheme.background);
    try testing.expectEqual(@as(u24, 0xffffff), scheme.foreground.toHex());
    try testing.expectEqual(@as(u24, 0xf5e0dc), scheme.cursor.?.toHex());
    try testing.expectEqual(@as(u24, 0x89b4fa), scheme.blue.?.toHex());
    try testing.expectEqual(@as(?Color, null), scheme.bright_blue);
}

test "Cache derives again only for a new scheme" {
    var cache: Cache = .{};
    const first = cache.get(gx_mocha);
    try testing.expectEqual(Tokens.derive(gx_mocha), first.*);
    try testing.expectEqual(first, cache.get(gx_mocha));
    const other = cache.get(samples[3]);
    try testing.expectEqual(Tokens.derive(samples[3]), other.*);
}
