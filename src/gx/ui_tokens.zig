//! The colors of the Ghostty GX interface, derived from the terminal
//! colors the same way for the win32 popups and dialogs and for the GTK
//! look (the win32 `ui/style.zig` carries these tokens as they are):
//!
//! - surfaces a step off the background (`surface` for bars, panels and
//!   cards, `surface_raised` for popups and dialogs, a step further): on
//!   a dark background toward the foreground; on a light one toward
//!   white (`light_lift`), so popups and cards stand out lighter than
//!   the window as in Windows 11 and libadwaita, unless the background
//!   is too close to white for that and they step toward the foreground
//!   as well. Hover, pressed and selected fills, and control fills at
//!   rest, hovered and pressed; pressed is fainter than hovered, as in
//!   Fluent;
//! - text levels with WCAG contrast floors on the background, `surface`
//!   and `surface_raised` alike (`text_secondary` and `text_placeholder`
//!   4.5:1, `text_tertiary` 3:1; `text_disabled` has none and is only for
//!   disabled items), and borders with 1.4:1 on all three;
//! - the accent (`Accent`, from `gx-accent-color`): the Ghostty GX brand
//!   purple (`brand`), a color of the theme (`ui_color.pickAccent` over
//!   the cursor color, palette 4 and palette 12) or a color of its own,
//!   at least 3:1 on `surface_raised`; the text on it, accent-colored
//!   text (4.5:1) and the text selection;
//! - links (`link`): the Ghostty GX blue, or palette 4 when the accent
//!   follows the theme, 4.5:1 on the three surfaces;
//! - the keyboard focus ring: WinUI's foreground outer stroke (3:1 on the
//!   surfaces) with an inner stroke in the popup surface, which the win32
//!   controls draw, and a one-color ring in the accent for toolkits whose
//!   rings follow the accent (GTK);
//! - the caution, success and critical colors: palette 3, 2 and 1 when
//!   they are colorful, else the Fluent ones; 3:1 on `surface_raised` for
//!   markers and fills, and as text (`*_text`) 4.5:1 on the surfaces.
//!
//! The foreground is limited to a small chroma before it is mixed into
//! surfaces, so a saturated foreground does not tint them. In high
//! contrast the tokens are the system colors (`Tokens.fromSystem`).
//! `Cache` keeps the tokens of the last scheme; the window chrome is in
//! `chrome.zig`, the sizes in `ui_metrics.zig`.
const std = @import("std");
const Config = @import("../config/Config.zig");
const config_types = @import("config_types.zig");
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

/// How far the surfaces of a light background move toward white:
/// `surface_raised` this much, `surface` half of it.
pub const light_lift: f32 = 0.6;

/// The least contrast of the lifted `surface_raised` with a light
/// background; backgrounds closer to white step toward the foreground.
pub const light_lift_min_contrast: f32 = 1.04;

/// The Ghostty GX brand colors (the Catppuccin mauve and blue of the
/// Ghostty GX icon): the purple accent and the blue of links, a pale shade
/// for dark backgrounds and a deep one for light backgrounds.
pub const brand = struct {
    pub const purple_dark = Color.hex(0xcba6f7);
    pub const purple_light = Color.hex(0x8839ef);
    pub const blue_dark = Color.hex(0x89b4fa);
    pub const blue_light = Color.hex(0x1e66f5);

    pub fn purple(dark: bool) Color {
        return if (dark) purple_dark else purple_light;
    }

    pub fn blue(dark: bool) Color {
        return if (dark) blue_dark else blue_light;
    }
};

/// Where the accent comes from (`gx-accent-color`).
pub const Accent = union(enum) {
    /// The brand purple (`brand.purple`).
    brand,
    /// A color of the terminal theme (`ui_color.pickAccent`).
    theme,
    /// A color of its own.
    color: Color,

    pub fn fromConfig(value: config_types.AccentColor) Accent {
        return switch (value) {
            .brand => .brand,
            .theme => .theme,
            .color => |c| .{ .color = fromConfigColor(c) },
        };
    }
};

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
    /// Palette 1, 2 and 3 for the critical, success and caution colors;
    /// null takes the Fluent ones.
    red: ?Color = null,
    green: ?Color = null,
    yellow: ?Color = null,
    /// The accent source. `fromConfig` reads `gx-accent-color` (default
    /// `brand`); schemes built by hand follow the theme.
    accent: Accent = .theme,

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
            .red = fromConfigColor(config.palette.value[1]),
            .green = fromConfigColor(config.palette.value[2]),
            .yellow = fromConfigColor(config.palette.value[3]),
            .accent = .fromConfig(config.@"gx-accent-color"),
        };
    }

    /// The scheme of a theme file (`theme_swatch.parseThemeColors`), for
    /// previews; a theme without a background or foreground has the
    /// Ghostty default. The accent follows the theme; set `accent` to
    /// preview with the configured one.
    pub fn fromTheme(colors: theme_swatch.ThemeColors) Scheme {
        const defaults: theme_swatch.Swatch = .{};
        return .{
            .background = fromRgb(colors.background orelse defaults.background),
            .foreground = fromRgb(colors.foreground orelse defaults.foreground),
            .cursor = if (colors.cursor) |c| fromRgb(c) else null,
            .blue = if (colors.palette[4]) |c| fromRgb(c) else null,
            .bright_blue = if (colors.palette[12]) |c| fromRgb(c) else null,
            .red = if (colors.palette[1]) |c| fromRgb(c) else null,
            .green = if (colors.palette[2]) |c| fromRgb(c) else null,
            .yellow = if (colors.palette[3]) |c| fromRgb(c) else null,
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
    /// The accent as text, such as a selected page name.
    accent_text: Color,
    /// Links (4.5:1 on the surfaces).
    link: Color,

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

    /// Warning markers and fills (3:1 on `surface_raised`) and warning
    /// text (4.5:1 on the surfaces).
    caution: Color,
    caution_text: Color,
    /// Success markers and fills, and success text.
    success: Color,
    success_text: Color,
    /// Errors and destructive actions, and their text.
    critical: Color,
    critical_text: Color,

    pub fn derive(scheme: Scheme) Tokens {
        const bg = scheme.background;
        const fg = scheme.foreground;
        const dark = ui_color.isDark(bg);
        const tint = ui_color.limitChroma(fg, max_tint_chroma);
        const steps = surfaceSteps(bg, tint, dark);
        const surface = steps[0];
        const raised = steps[1];
        const surfaces = [_]Color{ bg, surface, raised };
        const accent = switch (scheme.accent) {
            .brand => ui_color.ensureContrast(brand.purple(dark), raised, floor.non_text),
            .theme => ui_color.pickAccent(&.{ scheme.cursor, scheme.blue, scheme.bright_blue }, raised),
            .color => |c| ui_color.ensureContrast(c.withAlpha(1), raised, floor.non_text),
        };
        const link = switch (scheme.accent) {
            .theme => colorful(scheme.blue) orelse brand.blue(dark),
            .brand, .color => brand.blue(dark),
        };
        const caution = colorful(scheme.yellow) orelse if (dark) Color.hex(0xfce100) else Color.hex(0x9d5d00);
        const success = colorful(scheme.green) orelse if (dark) Color.hex(0x6ccb5f) else Color.hex(0x0f7b0f);
        const critical = colorful(scheme.red) orelse if (dark) Color.hex(0xff99a4) else Color.hex(0xc42b1c);
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
            .link = ui_color.ensureContrastAll(link, &surfaces, floor.text),
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
            .caution = ui_color.ensureContrast(caution, raised, floor.non_text),
            .caution_text = ui_color.ensureContrastAll(caution, &surfaces, floor.text),
            .success = ui_color.ensureContrast(success, raised, floor.non_text),
            .success_text = ui_color.ensureContrastAll(success, &surfaces, floor.text),
            .critical = ui_color.ensureContrast(critical, raised, floor.non_text),
            .critical_text = ui_color.ensureContrastAll(critical, &surfaces, floor.text),
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
            .link = c.hotlight,
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
            .caution_text = c.window_text,
            .success = c.window_text,
            .success_text = c.window_text,
            .critical = c.window_text,
            .critical_text = c.window_text,
        };
    }
};

/// `surface` and `surface_raised` for the background `bg` (see the file
/// header).
fn surfaceSteps(bg: Color, tint: Color, dark: bool) [2]Color {
    if (!dark) {
        const raised = ui_color.mix(bg, Color.white, light_lift);
        if (ui_color.contrast(raised, bg) >= light_lift_min_contrast) {
            return .{ ui_color.mix(bg, Color.white, light_lift / 2), raised };
        }
    }
    return .{ ui_color.mix(bg, tint, 0.06), ui_color.mix(bg, tint, 0.10) };
}

/// `color` when it is colorful enough to carry a meaning, else null.
fn colorful(color: ?Color) ?Color {
    const c = color orelse return null;
    return if (ui_color.chroma(c) >= ui_color.accent_min_chroma) c else null;
}

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
    const accents = [_]Accent{ .theme, .brand, .{ .color = Color.hex(0x777777) }, .{ .color = Color.hex(0xffee00) } };
    for (samples) |sample| for (accents) |accent| {
        var scheme = sample;
        scheme.accent = accent;
        scheme.red = Color.hex(0xcc3333);
        scheme.green = Color.hex(0x66cc66);
        scheme.yellow = Color.hex(0xffe066);
        const t = Tokens.derive(scheme);
        // Text, borders and the focus ring hold on every surface.
        for ([_]Color{ t.background, t.surface, t.surface_raised }) |on| {
            try testing.expect(contrast(t.text_secondary, on) >= floor.text);
            try testing.expect(contrast(t.text_placeholder, on) >= floor.text);
            try testing.expect(contrast(t.text_tertiary, on) >= floor.text_tertiary);
            try testing.expect(contrast(t.border, on) >= floor.border);
            try testing.expect(contrast(t.focus_stroke, on) >= floor.non_text);
            try testing.expect(contrast(t.link, on) >= floor.text);
            try testing.expect(contrast(t.caution_text, on) >= floor.text);
            try testing.expect(contrast(t.success_text, on) >= floor.text);
            try testing.expect(contrast(t.critical_text, on) >= floor.text);
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
    };
}

test "surfaces step toward the foreground when dark and toward white when light" {
    const dark = Tokens.derive(gx_mocha);
    try testing.expect(luminance(dark.surface) > luminance(dark.background));
    try testing.expect(luminance(dark.surface_raised) > luminance(dark.surface));
    try testing.expect(luminance(dark.hover) > luminance(dark.surface_raised));

    // Catppuccin Latte: popups and cards are lighter than the window.
    const latte = samples[3];
    const light = Tokens.derive(latte);
    try testing.expect(!light.dark);
    try testing.expectEqual(ui_color.mix(latte.background, Color.white, light_lift), light.surface_raised);
    try testing.expectEqual(ui_color.mix(latte.background, Color.white, light_lift / 2), light.surface);
    try testing.expect(luminance(light.surface) > luminance(light.background));
    try testing.expect(luminance(light.surface_raised) > luminance(light.surface));
    // Hovered and pressed items still darken a lifted surface.
    try testing.expect(luminance(light.hover) < luminance(light.surface_raised));

    // A white background cannot lift: the surfaces step toward the text.
    const white = Tokens.derive(samples[8]);
    try testing.expect(luminance(white.surface) < luminance(white.background));
    try testing.expect(luminance(white.surface_raised) < luminance(white.surface));
}

test "the brand accent is the GX purple of the background's shade" {
    var mocha = gx_mocha;
    mocha.accent = .brand;
    const dark = Tokens.derive(mocha);
    try testing.expectEqual(brand.purple_dark, dark.accent);
    try testing.expectEqual(brand.blue_dark, dark.link);
    try testing.expectEqual(Color.black, dark.on_accent);
    try testing.expectEqual(dark.accent, dark.focus_stroke_accent);

    var latte = samples[3];
    latte.accent = .brand;
    const light = Tokens.derive(latte);
    try testing.expectEqual(brand.purple_light, light.accent);
    try testing.expectEqual(Color.white, light.on_accent);
    // The deep blue is darkened a little to read on the window.
    try testing.expect(contrast(light.link, latte.background) >= floor.text);
    try testing.expect(luminance(light.link) <= luminance(brand.blue_light));
    try testing.expect(ui_color.toOklch(light.link).c > 0.15);
}

test "the theme accent is the one pickAccent chooses" {
    for (samples) |scheme| {
        const t = Tokens.derive(scheme);
        const expected = ui_color.pickAccent(&.{ scheme.cursor, scheme.blue, scheme.bright_blue }, t.surface_raised);
        try testing.expectEqual(expected, t.accent);
        // Links follow palette 4 while it is colorful.
        if (scheme.blue) |blue| {
            if (ui_color.chroma(blue) >= ui_color.accent_min_chroma) {
                try testing.expectEqual(ui_color.ensureContrastAll(blue, &.{ t.background, t.surface, t.surface_raised }, floor.text), t.link);
            }
        }
    }
}

test "a custom accent keeps its hue and reaches 3:1" {
    var scheme = gx_mocha;
    scheme.accent = .{ .color = Color.hex(0xe5a50a) };
    try testing.expectEqual(@as(u24, 0xe5a50a), Tokens.derive(scheme).accent.toHex());
    // Too dark for the dark surfaces: lightened, hue kept.
    scheme.accent = .{ .color = Color.hex(0x2a1a6e) };
    const dim = Tokens.derive(scheme);
    try testing.expect(contrast(dim.accent, dim.surface_raised) >= floor.non_text);
    const before = ui_color.toOklch(Color.hex(0x2a1a6e)).h;
    try testing.expect(@abs(ui_color.toOklch(dim.accent).h - before) < 5);
    // Links stay the brand blue.
    try testing.expectEqual(brand.blue_dark, dim.link);
}

test "status colors come from palette 1, 2 and 3 when colorful" {
    var mocha = gx_mocha;
    mocha.red = Color.hex(0xf38ba8);
    mocha.green = Color.hex(0xa6e3a1);
    mocha.yellow = Color.hex(0xf9e2af);
    const t = Tokens.derive(mocha);
    try testing.expectEqual(@as(u24, 0xf38ba8), t.critical.toHex());
    try testing.expectEqual(@as(u24, 0xa6e3a1), t.success.toHex());
    try testing.expectEqual(@as(u24, 0xf9e2af), t.caution.toHex());
    try testing.expectEqual(t.critical, t.critical_text);

    // Gray palette entries carry no meaning: the Fluent colors apply.
    mocha.red = Color.hex(0x808080);
    mocha.green = null;
    const plain = Tokens.derive(mocha);
    try testing.expectEqual(@as(u24, 0xff99a4), plain.critical.toHex());
    try testing.expectEqual(@as(u24, 0x6ccb5f), plain.success.toHex());

    // Catppuccin Latte: the markers keep 3:1, the text darkens to 4.5:1.
    var latte = samples[3];
    latte.green = Color.hex(0x40a02b);
    latte.yellow = Color.hex(0xdf8e1d);
    const light = Tokens.derive(latte);
    try testing.expect(contrast(light.success, light.surface_raised) >= floor.non_text);
    try testing.expect(luminance(light.success_text) < luminance(light.success));
    try testing.expect(luminance(light.caution_text) < luminance(light.caution));
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

test "Scheme.fromConfig reads the status palette and gx-accent-color" {
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.palette.value[1] = .{ .r = 0xd2, .g = 0x0f, .b = 0x39 };
    config.palette.value[2] = .{ .r = 0x40, .g = 0xa0, .b = 0x2b };
    config.palette.value[3] = .{ .r = 0xdf, .g = 0x8e, .b = 0x1d };
    const scheme = Scheme.fromConfig(&config);
    try testing.expectEqual(@as(u24, 0xd20f39), scheme.red.?.toHex());
    try testing.expectEqual(@as(u24, 0x40a02b), scheme.green.?.toHex());
    try testing.expectEqual(@as(u24, 0xdf8e1d), scheme.yellow.?.toHex());
    // The default is the brand accent.
    try testing.expectEqual(Accent.brand, scheme.accent);
    config.@"gx-accent-color" = .theme;
    try testing.expectEqual(Accent.theme, Scheme.fromConfig(&config).accent);
    config.@"gx-accent-color" = .{ .color = .{ .r = 0xe5, .g = 0xa5, .b = 0x0a } };
    try testing.expectEqual(Accent{ .color = Color.hex(0xe5a50a) }, Scheme.fromConfig(&config).accent);
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
    try testing.expectEqual(@as(?Color, null), scheme.red);
    try testing.expectEqual(Accent.theme, scheme.accent);
}

test "Cache derives again only for a new scheme" {
    var cache: Cache = .{};
    const first = cache.get(gx_mocha);
    try testing.expectEqual(Tokens.derive(gx_mocha), first.*);
    try testing.expectEqual(first, cache.get(gx_mocha));
    const other = cache.get(samples[3]);
    try testing.expectEqual(Tokens.derive(samples[3]), other.*);
    var branded = samples[3];
    branded.accent = .brand;
    try testing.expectEqual(brand.purple_light, cache.get(branded).accent);
}
