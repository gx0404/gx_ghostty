//! Design tokens of the win32 UI: the colors (`Tokens`) and sizes in DIPs
//! (`space`, `radius`, `control`, `row`, `type_ramp`, `icon`,
//! `close_button`, `selection_indicator`, `focus_ring`; the older
//! `metrics` and `font_size` stay for existing callers), and the helpers
//! to scale them to pixels and to shade a fill for hover and press.
//! Spacing, radii, control and row heights and the type ramp are the
//! shared sizes of `gx.ui_metrics`, which the GTK look uses as well.
//! Spacing, radii and control, row and button sizes are multiples of 4
//! DIPs (checked at compile time); hairlines are one device pixel
//! (`d2d.Canvas.hairline`).
//!
//! The colors come from the interface library the GTK app shares:
//! `gx.ui_tokens` derives them from the terminal colors with the color
//! math of `gx.ui_color` (contrast floors on every surface, the accent,
//! pressed fainter than hovered, the WinUI focus ring of a foreground
//! outer and a surface inner stroke), and `gx.chrome` the title bar strip,
//! its overlays, the window border and the caption close button. `Tokens`
//! carries both: every field of `gx.ui_tokens.Tokens` under the same name
//! (a comptime check keeps them in step) and the chrome colors the title
//! bar and tab bar draw. `Color` is `gx.ui_color.Color`. A theme is dark
//! when the gamma-encoded luma of its background is under one half
//! (`ui_color.isDark`); contrast ratios use WCAG luminance
//! (`ui_color.luminance`).
//!
//! High contrast: while Windows high contrast is on (`system`),
//! `fromConfig` returns `fromSystem`, the system colors, with
//! `high_contrast` set so cards and inputs get borders. `system` is GUI
//! thread state read on first use; `System.refresh` reads it again, to be
//! called after WM_SETTINGCHANGE, WM_SYSCOLORCHANGE or WM_THEMECHANGED.
//!
//! `fromConfig` caches the tokens of the last colors it saw (the color
//! values, not the config) on the GUI thread; call it when painting.
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const chrome = @import("../../../gx/chrome.zig");
const ui_color = @import("../../../gx/ui_color.zig");
const ui_metrics = @import("../../../gx/ui_metrics.zig");
const ui_tokens = @import("../../../gx/ui_tokens.zig");
const d2d = @import("d2d.zig");

pub const Color = d2d.Color;

/// `a` moved toward `b` by `t` (0 is `a`, 1 is `b`), alpha too
/// (`gx.ui_color.mix`).
pub const mix = ui_color.mix;

/// The WCAG contrast ratio of two colors, 1 to 21 (`gx.ui_color.contrast`).
pub const contrast = ui_color.contrast;

/// The UI colors for one terminal theme.
pub const Tokens = struct {
    // The fields of `gx.ui_tokens.Tokens`, which documents them; `combine`
    // copies them by name.
    dark: bool,
    high_contrast: bool = false,
    background: Color,
    foreground: Color,
    surface: Color,
    surface_raised: Color,
    hover: Color,
    pressed: Color,
    hover_text: Color,
    selected: Color,
    selected_text: Color,
    border: Color,
    control_fill: Color,
    control_fill_hover: Color,
    control_fill_pressed: Color,
    control_border: Color,
    accent: Color,
    on_accent: Color,
    accent_text: Color,
    link: Color,
    focus_stroke: Color,
    focus_stroke_inner: Color,
    focus_stroke_accent: Color,
    text_selection: Color,
    on_text_selection: Color,
    text: Color,
    text_secondary: Color,
    text_tertiary: Color,
    text_placeholder: Color,
    text_disabled: Color,
    caution: Color,
    caution_text: Color,
    success: Color,
    success_text: Color,
    critical: Color,
    critical_text: Color,

    /// Fill of the title bar row with the solid window material
    /// (`gx.chrome.titleBar`): at least 1.12:1 from the terminal
    /// background, darker when it can, so the active tab, which has the
    /// terminal background, stands out of the strip.
    title_bar: Color,
    /// The 1px Windows 11 window border.
    window_border: Color,
    /// Translucent overlays for hovered and pressed chrome buttons and
    /// tabs, pressed fainter; they work on the solid strip and over a
    /// backdrop material.
    overlay_hover: Color,
    overlay_pressed: Color,
    /// The red of a hovered caption close button (Windows 11), its glyph,
    /// and the pressed button.
    close_hover: Color,
    close_hover_text: Color,
    close_pressed: Color,

    /// The fields `combine` sets from `gx.chrome.Chrome`.
    const chrome_fields = 7;

    comptime {
        const shared = @typeInfo(ui_tokens.Tokens).@"struct".field_names;
        if (@typeInfo(Tokens).@"struct".field_names.len != shared.len + chrome_fields) {
            @compileError("style.Tokens must have the fields of gx.ui_tokens.Tokens and the chrome colors");
        }
    }

    /// The tokens for the current config: the system colors in high
    /// contrast, else derived from the terminal colors (cached by them).
    pub fn fromConfig(config: *const Config) Tokens {
        if (system.highContrast()) return fromSystem(system.colors);
        return cached(ui_tokens.Scheme.fromConfig(config));
    }

    /// Tokens for a background, foreground and accent candidate.
    pub fn fromColors(bg: Color, fg: Color, accent: Color) Tokens {
        return derive(.{ .background = bg, .foreground = fg, .cursor = accent, .blue = accent, .bright_blue = accent });
    }

    /// Tokens for a theme: background, foreground and the accent
    /// candidates in order (cursor color when set, palette 4, palette 12).
    pub fn fromTheme(bg: Color, fg: Color, cursor: ?Color, blue: Color, bright_blue: Color) Tokens {
        return derive(.{ .background = bg, .foreground = fg, .cursor = cursor, .blue = blue, .bright_blue = bright_blue });
    }

    /// The tokens for the Windows high contrast colors.
    pub fn fromSystem(c: SystemColors) Tokens {
        return combine(ui_tokens.Tokens.fromSystem(c), chrome.Chrome.fromSystem(c));
    }

    fn derive(scheme: ui_tokens.Scheme) Tokens {
        const shared: ui_tokens.Tokens = .derive(scheme);
        return combine(shared, .derive(&shared, .{}));
    }

    fn combine(shared: ui_tokens.Tokens, colors: chrome.Chrome) Tokens {
        var out: Tokens = undefined;
        inline for (@typeInfo(ui_tokens.Tokens).@"struct".field_names) |field| {
            @field(out, field) = @field(shared, field);
        }
        out.title_bar = colors.title_bar;
        out.window_border = colors.window_border;
        out.overlay_hover = colors.hover;
        out.overlay_pressed = colors.pressed;
        out.close_hover = colors.close_hover;
        out.close_hover_text = colors.close_hover_text;
        out.close_pressed = colors.close_pressed;
        return out;
    }
};

const CacheEntry = struct { scheme: ui_tokens.Scheme, tokens: Tokens };

/// The last tokens `fromConfig` derived (GUI thread).
var last: ?CacheEntry = null;

fn cached(scheme: ui_tokens.Scheme) Tokens {
    if (last) |entry| if (std.meta.eql(entry.scheme, scheme)) return entry.tokens;
    const tokens = Tokens.derive(scheme);
    last = .{ .scheme = scheme, .tokens = tokens };
    return tokens;
}

/// The hover shade of `base`: moved toward the foreground by
/// `gx.ui_tokens.hover_share`.
pub fn hoverOf(base: Color, tokens: Tokens) Color {
    return mix(base, tokens.foreground, ui_tokens.hover_share);
}

/// The pressed shade of `base`, fainter than the hover shade (Fluent).
pub fn pressedOf(base: Color, tokens: Tokens) Color {
    return mix(base, tokens.foreground, ui_tokens.pressed_share);
}

// -----------------------------------------------------------------------
// System state (high contrast)
// -----------------------------------------------------------------------

/// The Windows system colors high contrast uses.
pub const SystemColors = ui_tokens.SystemColors;

/// System UI settings the tokens follow, read on the GUI thread.
pub const System = struct {
    high_contrast: bool = false,
    colors: SystemColors = .{},
    loaded: bool = false,
    /// A test hook forces high contrast on or off; null follows Windows.
    forced_high_contrast: ?bool = null,

    /// Read the settings again (after WM_SETTINGCHANGE, WM_SYSCOLORCHANGE,
    /// WM_THEMECHANGED).
    pub fn refresh(self: *System) void {
        self.loaded = true;
        var hc: HIGHCONTRASTW = .{};
        self.high_contrast = SystemParametersInfoW(SPI_GETHIGHCONTRAST, @sizeOf(HIGHCONTRASTW), @ptrCast(&hc), 0) != 0 and
            hc.dwFlags & HCF_HIGHCONTRASTON != 0;
        self.colors = .{
            .window = sysColor(COLOR_WINDOW),
            .window_text = sysColor(COLOR_WINDOWTEXT),
            .highlight = sysColor(COLOR_HIGHLIGHT),
            .highlight_text = sysColor(COLOR_HIGHLIGHTTEXT),
            .button_face = sysColor(COLOR_BTNFACE),
            .button_text = sysColor(COLOR_BTNTEXT),
            .gray_text = sysColor(COLOR_GRAYTEXT),
            .hotlight = sysColor(COLOR_HOTLIGHT),
        };
    }

    /// Whether the high contrast colors apply.
    pub fn highContrast(self: *System) bool {
        if (!self.loaded) self.refresh();
        return self.forced_high_contrast orelse self.high_contrast;
    }
};

/// The system UI state of the GUI thread.
pub var system: System = .{};

fn sysColor(index: i32) Color {
    const ref = GetSysColor(index);
    return Color.rgb(@truncate(ref), @truncate(ref >> 8), @truncate(ref >> 16));
}

const HIGHCONTRASTW = extern struct {
    cbSize: u32 = @sizeOf(HIGHCONTRASTW),
    dwFlags: u32 = 0,
    lpszDefaultScheme: ?[*:0]u16 = null,
};
const SPI_GETHIGHCONTRAST: u32 = 0x0042;
const HCF_HIGHCONTRASTON: u32 = 0x1;
const COLOR_WINDOW: i32 = 5;
const COLOR_WINDOWTEXT: i32 = 8;
const COLOR_HIGHLIGHT: i32 = 13;
const COLOR_HIGHLIGHTTEXT: i32 = 14;
const COLOR_BTNFACE: i32 = 15;
const COLOR_GRAYTEXT: i32 = 17;
const COLOR_BTNTEXT: i32 = 18;
const COLOR_HOTLIGHT: i32 = 26;

extern "user32" fn GetSysColor(nIndex: i32) callconv(.winapi) u32;
extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;

// -----------------------------------------------------------------------
// Sizes
// -----------------------------------------------------------------------

/// Spacing steps in DIPs (`gx.ui_metrics.space`): dialogs, settings and
/// the shortcut sheet use `xl`, notices `l`, panels and the find bar `s`,
/// items in a row `m`, groups of a page `xxl`.
pub const space = struct {
    pub const xs: f32 = ui_metrics.space.xs;
    pub const s: f32 = ui_metrics.space.s;
    pub const m: f32 = ui_metrics.space.m;
    pub const l: f32 = ui_metrics.space.l;
    pub const xl: f32 = ui_metrics.space.xl;
    pub const xxl: f32 = ui_metrics.space.xxl;
};

/// Corner radii (`gx.ui_metrics.radius`): `control` for buttons, inputs,
/// list row fills, cards, key caps and caption buttons; `overlay` for
/// popups, dialogs and tab tops (tooltips and link previews use
/// `control`); `window` for large panels.
pub const radius = struct {
    pub const control: f32 = ui_metrics.radius.control;
    pub const overlay: f32 = ui_metrics.radius.overlay;
    pub const window: f32 = ui_metrics.radius.window;
};

/// Control heights (`gx.ui_metrics.control`): buttons and inputs, and icon
/// buttons inside bars.
pub const control = struct {
    pub const height: f32 = ui_metrics.control.height;
    pub const compact: f32 = ui_metrics.control.compact;
};

/// Row heights (`gx.ui_metrics.row`): menus, settings lists and group
/// headers; the command palette, the shortcut sheet and navigation; rows
/// with two lines.
pub const row = struct {
    pub const menu: f32 = ui_metrics.row.menu;
    pub const header: f32 = ui_metrics.row.header;
    pub const list: f32 = ui_metrics.row.list;
    pub const two_line: f32 = ui_metrics.row.two_line;
};

/// A step of the type ramp: size and line height in DIPs, and weight.
pub const TypeStyle = struct {
    size: f32,
    line: f32,
    weight: d2d.FontWeight = .normal,

    /// A text style of this step in `color`, lines `line` DIPs apart.
    pub fn text(self: TypeStyle, color: Color) d2d.TextStyle {
        return .{ .size = self.size, .weight = self.weight, .color = color, .line_height = self.line };
    }

    fn of(step: ui_metrics.TypeStep) TypeStyle {
        return .{ .size = step.size, .line = step.line, .weight = if (step.semibold) .semibold else .normal };
    }
};

/// The Fluent type ramp (Windows typography): caption 12/16, body 14/20,
/// body strong 14/20 semibold, body large 18/24, subtitle 20/28
/// semibold, title 28/36 semibold. Menu shortcuts use caption with
/// `text_secondary`.
pub const type_ramp = struct {
    pub const caption: TypeStyle = .of(ui_metrics.type_ramp.caption);
    pub const body: TypeStyle = .of(ui_metrics.type_ramp.body);
    pub const body_strong: TypeStyle = .of(ui_metrics.type_ramp.body_strong);
    pub const body_large: TypeStyle = .of(ui_metrics.type_ramp.body_large);
    pub const subtitle: TypeStyle = .of(ui_metrics.type_ramp.subtitle);
    pub const title: TypeStyle = .of(ui_metrics.type_ramp.title);
};

/// Icon glyph sizes: standard; chevrons, check marks and close glyphs;
/// caption buttons; title icons.
pub const icon = struct {
    pub const standard: f32 = 16;
    pub const small: f32 = 12;
    pub const caption: f32 = 10;
    pub const large: f32 = 20;
};

/// Close buttons: 32 DIPs square (28 inside bars) with the cancel glyph
/// at 12 and a `radius.control` hover fill.
pub const close_button = struct {
    pub const size: f32 = 32;
    pub const compact: f32 = 28;
    pub const glyph: f32 = 12;
};

/// The selection indicator of a selected list row: an accent pill
/// 3 × 16 DIPs at the row's leading edge.
pub const selection_indicator = struct {
    pub const width: f32 = 3;
    pub const height: f32 = 16;
};

/// The keyboard focus ring, outside the control: a 1 DIP inner stroke
/// (`focus_stroke_inner`) and a 2 DIP outer one (`focus_stroke`), drawn
/// only for keyboard focus.
pub const focus_ring = struct {
    pub const inner: f32 = 1;
    pub const outer: f32 = 2;
};

/// Metrics in DIPs (pixels at 96 DPI); scale with `px`. Newer code uses
/// the token groups above.
pub const metrics = struct {
    /// Height of the title bar row that holds the tabs and the caption
    /// buttons (Windows 11 tabbed apps).
    pub const title_bar_height: f32 = 40;
    /// Width of a caption button (minimize, maximize/restore, close).
    pub const caption_button_width: f32 = 46;
    /// Size of the caption button glyphs.
    pub const caption_glyph_size: f32 = icon.caption;
    /// Height of the tab bar without caption buttons (native title bar,
    /// borderless and fullscreen windows).
    pub const tab_bar_height: f32 = 36;
    /// Twice `radius.control`: existing callers halve it. Newer code uses
    /// `radius.control` and `radius.overlay`.
    pub const corner_radius: f32 = 8;
    /// Corner radius of popups (matches the DWM round corner).
    pub const popup_radius: f32 = radius.overlay;
    /// Hairline border width in DIPs (`d2d.Canvas.hairline` is one device
    /// pixel).
    pub const border_width: f32 = 1;
    /// Horizontal and vertical content padding.
    pub const padding_x: f32 = space.m;
    pub const padding_y: f32 = space.s;
    /// Gap between related elements.
    pub const gap: f32 = space.s;
    /// Height of list and menu items.
    pub const item_height: f32 = row.menu;
    /// Height of text inputs.
    pub const input_height: f32 = control.height;
    /// Icon glyph size.
    pub const icon_size: f32 = icon.standard;
};

/// UI font sizes in DIPs (`type_ramp` adds line heights).
pub const font_size = struct {
    pub const caption: f32 = type_ramp.caption.size;
    pub const body: f32 = type_ramp.body.size;
    pub const body_strong: f32 = type_ramp.body_strong.size;
    pub const subtitle: f32 = type_ramp.subtitle.size;
    pub const title: f32 = type_ramp.title.size;
};

comptime {
    const sizes = [_]f32{
        space.xs,              space.s,                    space.m,                  space.l,
        space.xl,              space.xxl,                  radius.control,           radius.overlay,
        radius.window,         control.height,             control.compact,          row.menu,
        row.header,            row.list,                   row.two_line,             close_button.size,
        close_button.compact,  selection_indicator.height, metrics.title_bar_height, metrics.tab_bar_height,
        metrics.corner_radius, metrics.item_height,        metrics.input_height,     metrics.icon_size,
        metrics.padding_x,     metrics.padding_y,
    };
    for (sizes) |v| {
        if (@mod(v, 4) != 0) @compileError("UI spacing, radii and control sizes are multiples of 4 DIPs");
    }
}

/// A DIP length in pixels at `scale` (DPI / 96).
pub fn px(length: f32, scale: f32) i32 {
    return @intFromFloat(@round(length * scale));
}

/// A DIP length in whole pixels at `scale`, rounded up (boxes sized from
/// text never cut its last pixel).
pub fn pxCeil(length: f32, scale: f32) i32 {
    return @intFromFloat(@ceil(length * scale - 0.001));
}

/// A pixel length in DIPs at `scale`.
pub fn dip(pixels: i32, scale: f32) f32 {
    return @as(f32, @floatFromInt(pixels)) / scale;
}

/// `v` (DIPs) on the nearest device pixel at `scale`.
pub const snap = d2d.snapValue;

const testing = std.testing;
const luminance = ui_color.luminance;

test "mix" {
    const black = Color.hex(0x000000);
    const white = Color.hex(0xffffff);
    const mid = mix(black, white, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid.r, 0.001);
    try testing.expectEqual(@as(u32, 0x808080), d2d.colorRef(mix(black, white, 0.5)));
}

test "the tokens are the shared tokens and the chrome colors" {
    const bg = Color.hex(0x1f1f28);
    const fg = Color.hex(0xffffff);
    const t = Tokens.fromTheme(bg, fg, Color.hex(0xf5e0dc), Color.hex(0x89b4fa), Color.hex(0x89b4fa));
    const shared: ui_tokens.Tokens = .derive(.{
        .background = bg,
        .foreground = fg,
        .cursor = Color.hex(0xf5e0dc),
        .blue = Color.hex(0x89b4fa),
        .bright_blue = Color.hex(0x89b4fa),
    });
    inline for (@typeInfo(ui_tokens.Tokens).@"struct".field_names) |field| {
        try testing.expectEqual(@field(shared, field), @field(t, field));
    }
    const colors: chrome.Chrome = .derive(&shared, .{});
    try testing.expectEqual(colors.title_bar, t.title_bar);
    try testing.expectEqual(colors.window_border, t.window_border);
    try testing.expectEqual(colors.hover, t.overlay_hover);
    try testing.expectEqual(colors.pressed, t.overlay_pressed);
    try testing.expectEqual(chrome.close_hover, t.close_hover);
}

test "tokens follow the background" {
    const dark = Tokens.fromColors(Color.hex(0x1e1e2e), Color.hex(0xcdd6f4), Color.hex(0x89b4fa));
    try testing.expect(dark.dark);
    try testing.expect(luminance(dark.surface) > luminance(dark.background));
    try testing.expect(luminance(dark.hover) > luminance(dark.surface_raised));
    // Pressed is fainter than hovered (Fluent).
    try testing.expect(contrast(dark.pressed, dark.surface_raised) < contrast(dark.hover, dark.surface_raised));
    try testing.expect(contrast(pressedOf(dark.surface, dark), dark.surface) < contrast(hoverOf(dark.surface, dark), dark.surface));

    const light = Tokens.fromColors(Color.hex(0xffffff), Color.hex(0x000000), Color.hex(0x0067c0));
    try testing.expect(!light.dark);
    try testing.expect(luminance(light.surface) < luminance(light.background));
    try testing.expectEqual(@as(u32, 0xffffff), d2d.colorRef(light.on_accent));
}

test "the title bar strip contrasts with the active tab" {
    // The active tab has the terminal background; the strip is darker.
    const dark = Tokens.fromColors(Color.hex(0x1f1f28), Color.hex(0xffffff), Color.hex(0xf5e0dc));
    try testing.expect(luminance(dark.title_bar) < luminance(dark.background));
    const light = Tokens.fromColors(Color.hex(0xeff1f5), Color.hex(0x4c4f69), Color.hex(0x1e66f5));
    try testing.expect(luminance(light.title_bar) < luminance(light.background));
    // A black background cannot get darker: the strip is lighter.
    const black = Tokens.fromColors(Color.hex(0x000000), Color.hex(0xcccccc), Color.hex(0x3d8ef8));
    try testing.expect(luminance(black.title_bar) > luminance(black.background));
    // Overlays are translucent foreground, pressed fainter.
    try testing.expect(dark.overlay_hover.a > 0 and dark.overlay_hover.a < 0.5);
    try testing.expect(dark.overlay_pressed.a < dark.overlay_hover.a);
}

test "the title bar strip has no jump near black" {
    // The old formula switched from lightening to a 32 % darkening at a
    // luminance of 0.03, leaving #0c0c0c-like backgrounds at 1.02:1.
    var level: u8 = 0;
    while (level < 0x40) : (level += 1) {
        const bg = Color.rgb(level, level, level);
        const t = Tokens.fromColors(bg, Color.hex(0xcccccc), Color.hex(0x3d8ef8));
        try testing.expect(contrast(t.title_bar, bg) >= chrome.strip_min_contrast);
    }
}

test "the GX Mocha accent is the palette blue" {
    const t = Tokens.fromTheme(
        Color.hex(0x1e1e2e),
        Color.hex(0xcdd6f4),
        Color.hex(0xf5e0dc),
        Color.hex(0x89b4fa),
        Color.hex(0x89b4fa),
    );
    try testing.expectEqual(@as(u24, 0x89b4fa), t.accent.toHex());
    try testing.expectEqual(@as(u24, 0x000000), t.on_accent.toHex());
    // A colorful cursor color still wins.
    const cursor = Tokens.fromTheme(Color.hex(0x282828), Color.hex(0xebdbb2), Color.hex(0xfe8019), Color.hex(0x458588), Color.hex(0x83a598));
    try testing.expectEqual(@as(u24, 0xfe8019), cursor.accent.toHex());
    // No cursor color: palette 4 when it contrasts, else palette 12.
    const dim_blue = Tokens.fromTheme(Color.hex(0x000000), Color.hex(0xffffff), null, Color.hex(0x00008b), Color.hex(0x5c5cff));
    try testing.expectEqual(@as(u24, 0x5c5cff), dim_blue.accent.toHex());
}

test "derived colors meet their contrast floors across themes" {
    // bg, fg, cursor (0 = none), palette 4, palette 12.
    const themes = [_][5]u24{
        .{ 0x1e1e2e, 0xcdd6f4, 0xf5e0dc, 0x89b4fa, 0x89b4fa }, // GX Mocha
        .{ 0xeff1f5, 0x4c4f69, 0xdc8a78, 0x1e66f5, 0x1e66f5 }, // Catppuccin Latte
        .{ 0xfdf6e3, 0x657b83, 0x657b83, 0x268bd2, 0x839496 }, // Solarized Light
        .{ 0x282828, 0xebdbb2, 0xebdbb2, 0x458588, 0x83a598 }, // Gruvbox Dark
        .{ 0x000000, 0xffffff, 0, 0x0000ee, 0x5c5cff }, // xterm
        .{ 0xffffff, 0x000000, 0, 0x0000ee, 0x5c5cff }, // xterm light
        .{ 0x0f191c, 0x00ff9c, 0x00ff9c, 0x00ff9c, 0x00ff9c }, // a saturated matrix theme
        .{ 0x0c0c0c, 0xcccccc, 0xffffff, 0x0037da, 0x3b78ff }, // Campbell
    };
    const floor = ui_tokens.floor;
    for (themes) |th| {
        const cursor: ?Color = if (th[2] == 0) null else Color.hex(th[2]);
        const t = Tokens.fromTheme(Color.hex(th[0]), Color.hex(th[1]), cursor, Color.hex(th[3]), Color.hex(th[4]));
        for ([_]Color{ t.background, t.surface, t.surface_raised }) |fill| {
            try testing.expect(contrast(t.text_secondary, fill) >= floor.text);
            try testing.expect(contrast(t.text_placeholder, fill) >= floor.text);
            try testing.expect(contrast(t.text_tertiary, fill) >= floor.text_tertiary);
            try testing.expect(contrast(t.focus_stroke, fill) >= floor.non_text);
            try testing.expect(contrast(t.border, fill) >= floor.border);
        }
        try testing.expect(contrast(t.accent, t.surface_raised) >= floor.non_text);
        try testing.expect(contrast(t.accent_text, t.surface_raised) >= floor.text);
        try testing.expect(contrast(t.on_accent, t.accent) >= floor.text);
        try testing.expect(contrast(t.on_text_selection, t.text_selection) >= floor.text);
        try testing.expect(contrast(t.selected_text, t.selected) >= floor.text);
        try testing.expect(contrast(t.title_bar, t.background) >= chrome.strip_min_contrast);
        for ([_]Color{ t.caution, t.success, t.critical }) |marker| {
            try testing.expect(contrast(marker, t.surface_raised) >= floor.non_text);
        }
        // Surfaces stay neutral under a saturated foreground.
        try testing.expect(ui_color.chroma(t.surface_raised) <= ui_color.chroma(t.background) + 0.02);
    }
}

test "high contrast uses the system colors" {
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
    try testing.expectEqual(colors.hotlight, t.accent_text);
    try testing.expectEqual(colors.gray_text, t.text_disabled);
    try testing.expectEqual(colors.window, t.title_bar);
    try testing.expectEqual(colors.highlight, t.close_hover);
    try testing.expectEqual(colors.highlight_text, t.close_hover_text);
}

test "fromConfig caches by color values" {
    const saved = last;
    defer last = saved;
    last = null;
    const scheme: ui_tokens.Scheme = .{
        .background = Color.hex(0x1e1e2e),
        .foreground = Color.hex(0xcdd6f4),
        .cursor = Color.hex(0xf5e0dc),
        .blue = Color.hex(0x89b4fa),
        .bright_blue = Color.hex(0x89b4fa),
    };
    const first = cached(scheme);
    try testing.expect(last != null);
    try testing.expectEqual(first.accent, cached(scheme).accent);
    var other = scheme;
    other.background = Color.hex(0xeff1f5);
    const second = cached(other);
    try testing.expect(!second.dark);
    try testing.expect(std.meta.eql(last.?.scheme, other));
}

test "px rounds" {
    try testing.expectEqual(@as(i32, 36), px(metrics.tab_bar_height, 1.0));
    try testing.expectEqual(@as(i32, 54), px(metrics.tab_bar_height, 1.5));
    try testing.expectEqual(@as(i32, 12), px(8, 1.5));
    try testing.expectEqual(@as(i32, 21), pxCeil(13.5, 1.5));
    try testing.expectEqual(@as(i32, 20), pxCeil(13.3333333, 1.5));
    try testing.expectEqual(@as(i32, 14), pxCeil(13.1, 1.0));
}
