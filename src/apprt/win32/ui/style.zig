//! Design tokens of the win32 UI, derived from the terminal colors so the
//! chrome and popups match the active theme: colors (`Tokens`), sizes in
//! DIPs (`space`, `radius`, `control`, `row`, `type_ramp`, `icon`,
//! `close_button`, `selection_indicator`, `focus_ring`; the older
//! `metrics` and `font_size` stay for existing callers) and the helpers to
//! scale them to pixels and to derive hover/pressed shades. Spacing,
//! radii and control, row and button sizes are multiples of 4 DIPs
//! (checked at compile time); hairlines are one device pixel
//! (`d2d.Canvas.hairline`).
//!
//! Contrast: contrast ratios are WCAG's, on linear-light luminance
//! (`contrast`), and colors are adjusted along OKLab lightness
//! (`ensureContrast`). Secondary text and placeholders get at least 4.5:1
//! on panels and popups, tertiary text, the accent, the focus stroke and
//! the selection indicator 3:1, borders 1.4:1. The accent is the first of
//! the cursor color, palette 4 and palette 12 that is colorful (OKLCH
//! chroma >= 0.05) and contrasts 3:1 with popups, else the first colorful
//! one with its lightness adjusted (`pickAccent`). Surfaces mix the
//! background with the foreground limited to OKLCH chroma 0.04, so a
//! saturated foreground does not tint them. The title bar strip differs
//! from the terminal background by at least 1.12:1, darker when it can.
//!
//! High contrast: while Windows high contrast is on (`system`, GUI thread
//! state that the window refreshes on WM_SETTINGCHANGE, WM_SYSCOLORCHANGE
//! and WM_THEMECHANGED), `fromConfig` returns `fromSystem`, the system
//! colors, with `high_contrast` set so cards and inputs get borders.
//!
//! `fromConfig` caches the tokens of the last colors it saw (the color
//! values, not the config) on the GUI thread; call it when painting.
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const d2d = @import("d2d.zig");

pub const Color = d2d.Color;

/// The UI colors for one terminal theme.
pub const Tokens = struct {
    /// Whether the theme is dark (from the background's gamma luminance).
    dark: bool,
    /// The Windows high contrast colors are in use: draw borders on cards
    /// and inputs, do not rely on fills alone.
    high_contrast: bool = false,

    /// The terminal background and foreground.
    background: Color,
    foreground: Color,

    /// Accent (`pickAccent`): selection indicators, focus underlines,
    /// primary buttons; at least 3:1 on `surface_raised`.
    accent: Color,
    /// Text and glyphs on `accent` (black or white, whichever contrasts
    /// more; always at least 4.5:1).
    on_accent: Color,
    /// The accent where it is text (links, the current item's note): at
    /// least 4.5:1 on `surface_raised`.
    accent_text: Color,

    /// Fill of chrome bars (tab bar) and panels, slightly off the
    /// terminal background.
    surface: Color,
    /// Fill of popups and flyouts, a step further from the background.
    surface_raised: Color,
    /// Hover and pressed fills for items on `surface`/`surface_raised`.
    hover: Color,
    pressed: Color,
    /// Text on `hover` and `pressed` (differs from `text` in high
    /// contrast).
    hover_text: Color,
    /// Selected item fill (accent tinted, subtle: the selection indicator
    /// carries the contrast).
    selected: Color,
    /// Text on `selected`.
    selected_text: Color,
    /// Hairline borders and separators: at least 1.4:1 on the background
    /// and on `surface_raised`.
    border: Color,

    /// Fill of buttons and similar controls at rest, hovered and pressed
    /// (pressed is fainter than hovered, as in Fluent), and their border.
    control_fill: Color,
    control_fill_hover: Color,
    control_fill_pressed: Color,
    control_border: Color,

    /// The keyboard focus ring: the outer stroke (at least 3:1) and the
    /// inner one that separates it from the control.
    focus_stroke: Color,
    focus_stroke_inner: Color,
    /// The selection of a text input and the text on it.
    text_selection: Color,
    on_text_selection: Color,

    /// Fill of the title bar row with the solid window material: darker
    /// than the terminal background (lighter for near-black backgrounds)
    /// by at least 1.12:1, so the active tab, which has the terminal
    /// background, stands out of the strip.
    title_bar: Color,
    /// The 1px Windows 11 window border.
    window_border: Color,
    /// Translucent overlays for hovered and pressed chrome buttons and
    /// tabs; they work on the solid strip and over a backdrop material.
    overlay_hover: Color,
    overlay_pressed: Color,

    text: Color,
    /// Secondary text: at least 4.5:1 on `surface` and `surface_raised`.
    text_secondary: Color,
    /// Hints and less important labels: at least 3:1.
    text_tertiary: Color,
    /// Placeholders of empty inputs: at least 4.5:1.
    text_placeholder: Color,
    /// Disabled items only (not for text that has to be read).
    text_disabled: Color,

    /// Warning markers and text (the Fluent caution color), success and
    /// error markers; at least 3:1 on `surface_raised`.
    caution: Color,
    success: Color,
    critical: Color,

    /// The red of a hovered close button (Windows 11 caption close).
    close_hover: Color = Color.hex(0xc42b1c),
    close_hover_text: Color = Color.hex(0xffffff),
    /// The pressed caption close button.
    close_pressed: Color = Color.hex(0xc42b1c).withAlpha(0.9),

    /// The tokens for the current config: the system colors in high
    /// contrast, else derived from the terminal colors (cached by them).
    pub fn fromConfig(config: *const Config) Tokens {
        if (system.highContrast()) return fromSystem(system.colors);
        return cached(Inputs.fromConfig(config));
    }

    /// Tokens for a background, foreground and accent candidate.
    pub fn fromColors(bg: Color, fg: Color, accent: Color) Tokens {
        return fromInputs(.{ .background = bg, .foreground = fg, .accents = .{ accent, accent, accent } });
    }

    /// Tokens for a theme: background, foreground and the accent
    /// candidates in order (cursor color when set, palette 4, palette 12).
    pub fn fromTheme(bg: Color, fg: Color, cursor: ?Color, blue: Color, bright_blue: Color) Tokens {
        return fromInputs(.{ .background = bg, .foreground = fg, .accents = .{ cursor orelse blue, blue, bright_blue } });
    }

    fn fromInputs(in: Inputs) Tokens {
        const bg = in.background;
        const fg = in.foreground;
        const dark = luminance(bg) < 0.5;
        const neutral = limitChroma(fg, 0.04);

        const surface = mix(bg, neutral, 0.06);
        const surface_raised = mix(bg, neutral, 0.10);
        const fills = [_]Color{ surface, surface_raised };

        const accent = pickAccent(&in.accents, surface_raised);
        const on_accent = onColor(accent);
        const selected = mix(surface_raised, accent, 0.28);
        const border = ensureContrastAll(mix(bg, neutral, 0.16), &.{ bg, surface_raised }, 1.4);
        const caution = if (dark) Color.hex(0xfce100) else Color.hex(0x9d5d00);
        const success = if (dark) Color.hex(0x6ccb5f) else Color.hex(0x0f7b0f);
        const critical = if (dark) Color.hex(0xff99a4) else Color.hex(0xc42b1c);

        return .{
            .dark = dark,
            .background = bg,
            .foreground = fg,
            .accent = accent,
            .on_accent = on_accent,
            .accent_text = ensureContrast(accent, surface_raised, 4.5),
            .surface = surface,
            .surface_raised = surface_raised,
            .hover = mix(surface_raised, neutral, 0.08),
            .pressed = mix(surface_raised, neutral, 0.14),
            .hover_text = fg,
            .selected = selected,
            .selected_text = ensureContrast(fg, selected, 4.5),
            .border = border,
            .control_fill = mix(surface_raised, neutral, 0.06),
            .control_fill_hover = mix(surface_raised, neutral, 0.09),
            .control_fill_pressed = mix(surface_raised, neutral, 0.04),
            .control_border = border,
            .focus_stroke = ensureContrastAll(fg, &fills, 3),
            .focus_stroke_inner = surface_raised,
            .text_selection = accent,
            .on_text_selection = on_accent,
            .title_bar = titleBar(bg, neutral, dark),
            .window_border = mix(bg, neutral, if (dark) 0.18 else 0.22),
            .overlay_hover = fg.withAlpha(if (dark) 0.08 else 0.06),
            .overlay_pressed = fg.withAlpha(if (dark) 0.05 else 0.04),
            .text = fg,
            .text_secondary = ensureContrastAll(mix(fg, bg, 0.35), &fills, 4.5),
            .text_tertiary = ensureContrastAll(mix(fg, bg, 0.5), &fills, 3),
            .text_placeholder = ensureContrastAll(mix(fg, bg, 0.4), &fills, 4.5),
            .text_disabled = mix(fg, bg, 0.6),
            .caution = ensureContrast(caution, surface_raised, 3),
            .success = ensureContrast(success, surface_raised, 3),
            .critical = ensureContrast(critical, surface_raised, 3),
        };
    }

    /// The tokens for the Windows high contrast colors.
    pub fn fromSystem(c: SystemColors) Tokens {
        return .{
            .dark = luminance(c.window) < 0.5,
            .high_contrast = true,
            .background = c.window,
            .foreground = c.window_text,
            .accent = c.highlight,
            .on_accent = c.highlight_text,
            .accent_text = c.hotlight,
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
            .focus_stroke = c.window_text,
            .focus_stroke_inner = c.window,
            .text_selection = c.highlight,
            .on_text_selection = c.highlight_text,
            .title_bar = c.window,
            .window_border = c.window_text,
            .overlay_hover = c.highlight,
            .overlay_pressed = c.highlight,
            .text = c.window_text,
            .text_secondary = c.window_text,
            .text_tertiary = c.window_text,
            .text_placeholder = c.gray_text,
            .text_disabled = c.gray_text,
            .caution = c.window_text,
            .success = c.window_text,
            .critical = c.window_text,
            .close_hover = c.highlight,
            .close_hover_text = c.highlight_text,
            .close_pressed = c.highlight,
        };
    }
};

/// The colors tokens are derived from.
const Inputs = struct {
    background: Color,
    foreground: Color,
    /// Accent candidates in order of preference.
    accents: [3]Color,

    fn fromConfig(config: *const Config) Inputs {
        const cursor: ?Color = cursor: {
            if (config.@"cursor-color") |cursor| switch (cursor) {
                .color => |c| break :cursor fromConfigColor(c),
                .@"cell-foreground", .@"cell-background" => {},
            };
            break :cursor null;
        };
        const blue = config.palette.value[4];
        const bright_blue = config.palette.value[12];
        const p4 = Color.rgb(blue.r, blue.g, blue.b);
        return .{
            .background = fromConfigColor(config.background),
            .foreground = fromConfigColor(config.foreground),
            .accents = .{ cursor orelse p4, p4, Color.rgb(bright_blue.r, bright_blue.g, bright_blue.b) },
        };
    }

    fn eql(a: Inputs, b: Inputs) bool {
        return std.meta.eql(a, b);
    }
};

const CacheEntry = struct { inputs: Inputs, tokens: Tokens };

/// The last tokens `fromConfig` derived (GUI thread).
var last: ?CacheEntry = null;

fn cached(inputs: Inputs) Tokens {
    if (last) |entry| if (entry.inputs.eql(inputs)) return entry.tokens;
    const tokens = Tokens.fromInputs(inputs);
    last = .{ .inputs = inputs, .tokens = tokens };
    return tokens;
}

fn fromConfigColor(c: Config.Color) Color {
    return Color.rgb(c.r, c.g, c.b);
}

/// The title bar strip: the background darkened (a 32 % mix toward black
/// on dark themes, 8 % on light ones) or, when that is not 1.12:1 away,
/// darkened further or lightened toward the foreground until it is.
fn titleBar(bg: Color, neutral: Color, dark: bool) Color {
    const min = 1.12;
    const black = Color.hex(0x000000);
    const preferred = mix(bg, black, if (dark) 0.32 else 0.08);
    if (contrast(preferred, bg) >= min) return preferred;
    if (contrast(black, bg) >= min) return bisectMix(bg, black, bg, min);
    if (contrast(neutral, bg) >= min) return bisectMix(bg, neutral, bg, min);
    return mix(bg, neutral, 0.08);
}

/// The smallest mix of `from` toward `to` that contrasts `min` with
/// `against` (contrast(to, against) >= min).
fn bisectMix(from: Color, to: Color, against: Color, min: f32) Color {
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..24) |_| {
        const mid = (lo + hi) / 2;
        if (contrast(mix(from, to, mid), against) >= min) hi = mid else lo = mid;
    }
    return mix(from, to, hi);
}

// -----------------------------------------------------------------------
// Color math
// -----------------------------------------------------------------------

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

/// Luminance (Rec. 709 weights on the gamma-encoded components), 0..1:
/// what decides whether a theme is dark. Contrast uses
/// `relativeLuminance`.
pub fn luminance(c: Color) f32 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

fn toLinear(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn fromLinear(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// WCAG relative luminance (linear light), 0..1.
pub fn relativeLuminance(c: Color) f32 {
    return 0.2126 * toLinear(c.r) + 0.7152 * toLinear(c.g) + 0.0722 * toLinear(c.b);
}

/// The WCAG contrast ratio of two colors, 1..21.
pub fn contrast(a: Color, b: Color) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// A color in OKLab (Björn Ottosson): lightness 0..1 and two opponent
/// axes.
pub const Oklab = struct { l: f32, a: f32, b: f32 };

pub fn toOklab(c: Color) Oklab {
    const r = toLinear(c.r);
    const g = toLinear(c.g);
    const b = toLinear(c.b);
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

/// The sRGB color of `lab` (out-of-gamut components clipped).
pub fn fromOklab(lab: Oklab, alpha: f32) Color {
    const l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
    const m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
    const s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{
        .r = fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        .g = fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        .b = fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
        .a = alpha,
    };
}

/// The OKLCH chroma of a color: 0 for grays.
pub fn chroma(c: Color) f32 {
    const lab = toOklab(c);
    return @sqrt(lab.a * lab.a + lab.b * lab.b);
}

/// `c` with its OKLCH chroma limited to `max`, lightness and hue kept.
pub fn limitChroma(c: Color, max: f32) Color {
    const lab = toOklab(c);
    const ch = @sqrt(lab.a * lab.a + lab.b * lab.b);
    if (ch <= max) return c;
    const k = max / ch;
    return fromOklab(.{ .l = lab.l, .a = lab.a * k, .b = lab.b * k }, c.a);
}

/// `c` moved along OKLab lightness (its chroma fading toward white or
/// black) just far enough to contrast `min` with `against`: away from
/// `against` when that can reach it, else the other way; white or black
/// when neither can.
pub fn ensureContrast(c: Color, against: Color, min: f32) Color {
    if (contrast(c, against) >= min) return c;
    const lab = toOklab(c);
    const lighter_first = relativeLuminance(c) >= relativeLuminance(against);
    const targets = if (lighter_first) [2]f32{ 1, 0 } else [2]f32{ 0, 1 };
    for (targets) |target| {
        if (contrast(toward(lab, target, 1, c.a), against) < min) continue;
        var lo: f32 = 0;
        var hi: f32 = 1;
        for (0..24) |_| {
            const mid = (lo + hi) / 2;
            if (contrast(toward(lab, target, mid, c.a), against) >= min) hi = mid else lo = mid;
        }
        return toward(lab, target, hi, c.a);
    }
    const white = Color.hex(0xffffff);
    const black = Color.hex(0x000000);
    return if (contrast(white, against) >= contrast(black, against)) white else black;
}

/// `ensureContrast` against every color of `against`.
pub fn ensureContrastAll(c: Color, against: []const Color, min: f32) Color {
    var out = c;
    for (0..3) |_| {
        var ok = true;
        for (against) |bg| {
            if (contrast(out, bg) >= min) continue;
            ok = false;
            out = ensureContrast(out, bg, min);
        }
        if (ok) break;
    }
    return out;
}

/// `lab` with lightness `t` of the way to `target` (1 white, 0 black) and
/// its chroma faded by the same share.
fn toward(lab: Oklab, target: f32, t: f32, alpha: f32) Color {
    return fromOklab(.{
        .l = lab.l + (target - lab.l) * t,
        .a = lab.a * (1 - t),
        .b = lab.b * (1 - t),
    }, alpha);
}

/// Black or white, whichever contrasts more with `c`.
pub fn onColor(c: Color) Color {
    const white = Color.hex(0xffffff);
    const black = Color.hex(0x000000);
    return if (contrast(white, c) >= contrast(black, c)) white else black;
}

/// The accent among `candidates` (in order of preference) for UI on
/// `against`: the first colorful one (OKLCH chroma >= 0.05) that
/// contrasts 3:1, else the first colorful one adjusted to 3:1, else the
/// first one adjusted (gray themes keep a gray accent).
pub fn pickAccent(candidates: []const Color, against: Color) Color {
    const min_chroma = 0.05;
    for (candidates) |c| {
        if (chroma(c) >= min_chroma and contrast(c, against) >= 3) return c;
    }
    for (candidates) |c| {
        if (chroma(c) >= min_chroma) return ensureContrast(c, against, 3);
    }
    return ensureContrast(candidates[0], against, 3);
}

// -----------------------------------------------------------------------
// System state (high contrast)
// -----------------------------------------------------------------------

/// The Windows system colors high contrast uses.
pub const SystemColors = struct {
    window: Color = Color.hex(0x000000),
    window_text: Color = Color.hex(0xffffff),
    highlight: Color = Color.hex(0x1aebff),
    highlight_text: Color = Color.hex(0x000000),
    button_face: Color = Color.hex(0x000000),
    button_text: Color = Color.hex(0xffffff),
    gray_text: Color = Color.hex(0x3ff23f),
    hotlight: Color = Color.hex(0xffff00),
};

/// System UI settings the tokens follow, read on the GUI thread.
pub const System = struct {
    high_contrast: bool = false,
    colors: SystemColors = .{},
    loaded: bool = false,
    /// A test hook forces high contrast on or off; null follows Windows.
    forced_high_contrast: ?bool = null,

    /// Read the settings again (on WM_SETTINGCHANGE, WM_SYSCOLORCHANGE,
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

/// Spacing steps in DIPs: dialogs, settings and the shortcut sheet use
/// `xl`, notices `l`, panels and the find bar `s`, items in a row `m`.
pub const space = struct {
    pub const xs: f32 = 4;
    pub const s: f32 = 8;
    pub const m: f32 = 12;
    pub const l: f32 = 16;
    pub const xl: f32 = 24;
};

/// Corner radii: `control` for buttons, inputs, list row fills, cards,
/// key caps and caption buttons; `overlay` for popups, dialogs and tab
/// tops (tooltips and link previews use `control`).
pub const radius = struct {
    pub const control: f32 = 4;
    pub const overlay: f32 = 8;
};

/// Control heights: buttons and inputs, and icon buttons inside bars.
pub const control = struct {
    pub const height: f32 = 32;
    pub const compact: f32 = 28;
};

/// Row heights: menus, settings lists and group headers; the command
/// palette, the shortcut sheet and navigation; rows with two lines.
pub const row = struct {
    pub const menu: f32 = 32;
    pub const header: f32 = 32;
    pub const list: f32 = 36;
    pub const two_line: f32 = 52;
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
};

/// The Fluent type ramp (Windows typography): caption 12/16, body 14/20,
/// body strong 14/20 semibold, body large 18/24, subtitle 20/28
/// semibold, title 28/36 semibold. Menu shortcuts use caption with
/// `text_secondary`.
pub const type_ramp = struct {
    pub const caption: TypeStyle = .{ .size = 12, .line = 16 };
    pub const body: TypeStyle = .{ .size = 14, .line = 20 };
    pub const body_strong: TypeStyle = .{ .size = 14, .line = 20, .weight = .semibold };
    pub const body_large: TypeStyle = .{ .size = 18, .line = 24 };
    pub const subtitle: TypeStyle = .{ .size = 20, .line = 28, .weight = .semibold };
    pub const title: TypeStyle = .{ .size = 28, .line = 36, .weight = .semibold };
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
        space.xs,                 space.s,                space.m,               space.l,
        space.xl,                 radius.control,         radius.overlay,        control.height,
        control.compact,          row.menu,               row.header,            row.list,
        row.two_line,             close_button.size,      close_button.compact,  selection_indicator.height,
        metrics.title_bar_height, metrics.tab_bar_height, metrics.corner_radius, metrics.item_height,
        metrics.input_height,     metrics.icon_size,      metrics.padding_x,     metrics.padding_y,
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

test "the title bar strip has no jump near black" {
    const testing = std.testing;
    // The old formula switched from lightening to a 32 % darkening at a
    // luminance of 0.03, leaving #0c0c0c-like backgrounds at 1.02:1.
    var level: u8 = 0;
    while (level < 0x40) : (level += 1) {
        const bg = Color.rgb(level, level, level);
        const t = Tokens.fromColors(bg, Color.hex(0xcccccc), Color.hex(0x3d8ef8));
        try testing.expect(contrast(t.title_bar, bg) >= 1.119);
    }
}

test "contrast follows WCAG" {
    const testing = std.testing;
    const white = Color.hex(0xffffff);
    const black = Color.hex(0x000000);
    try testing.expectApproxEqAbs(@as(f32, 21), contrast(white, black), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), contrast(Color.hex(0x336699), Color.hex(0x336699)), 0.001);
    // #767676 is the lightest gray with 4.5:1 on white.
    try testing.expect(contrast(Color.hex(0x767676), white) >= 4.5);
    try testing.expect(contrast(Color.hex(0x777777), white) < 4.5);
    try testing.expectApproxEqAbs(@as(f32, 0.2126), relativeLuminance(Color.hex(0xff0000)), 0.001);
}

test "OKLab round trip and chroma" {
    const testing = std.testing;
    for ([_]u24{ 0x89b4fa, 0xf5e0dc, 0x1e1e2e, 0xffffff, 0x000000, 0x00ff00 }) |hex| {
        const c = Color.hex(hex);
        const back = fromOklab(toOklab(c), 1);
        try testing.expectApproxEqAbs(c.r, back.r, 0.002);
        try testing.expectApproxEqAbs(c.g, back.g, 0.002);
        try testing.expectApproxEqAbs(c.b, back.b, 0.002);
    }
    try testing.expectApproxEqAbs(@as(f32, 1), toOklab(Color.hex(0xffffff)).l, 0.001);
    try testing.expect(chroma(Color.hex(0x808080)) < 0.001);
    // GX Mocha: the rosewater cursor is nearly gray, the blue is not.
    try testing.expect(chroma(Color.hex(0xf5e0dc)) < 0.05);
    try testing.expect(chroma(Color.hex(0x89b4fa)) > 0.05);
    const limited = limitChroma(Color.hex(0x00ff00), 0.04);
    try testing.expectApproxEqAbs(@as(f32, 0.04), chroma(limited), 0.002);
    try testing.expectApproxEqAbs(toOklab(Color.hex(0x00ff00)).l, toOklab(limited).l, 0.002);
}

test "ensureContrast reaches the floor along lightness" {
    const testing = std.testing;
    const pairs = [_][2]u24{
        .{ 0x585b70, 0x1e1e2e }, // dim text on a dark theme
        .{ 0xacb0be, 0xeff1f5 }, // dim text on a light theme
        .{ 0x0000ee, 0x000000 }, // xterm blue on black
        .{ 0x808080, 0x808080 }, // the same color
    };
    for (pairs) |pair| {
        const c = Color.hex(pair[0]);
        const against = Color.hex(pair[1]);
        for ([_]f32{ 3, 4.5 }) |min| {
            const out = ensureContrast(c, against, min);
            try testing.expect(contrast(out, against) >= min - 0.01);
        }
    }
    // Already enough: unchanged.
    const fine = Color.hex(0xcdd6f4);
    try testing.expectEqual(fine, ensureContrast(fine, Color.hex(0x1e1e2e), 4.5));
    // Mid gray cannot reach 21:1: the stronger extreme.
    const extreme = ensureContrast(Color.hex(0x808080), Color.hex(0x7f7f7f), 21);
    try testing.expect(extreme.r == 0 or extreme.r == 1);
}

test "the GX Mocha accent is the palette blue" {
    const testing = std.testing;
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

test "pickAccent adjusts a colorful accent that lacks contrast" {
    const testing = std.testing;
    const against = Color.hex(0x2a2b3c);
    const dark_blue = Color.hex(0x00006b);
    const accent = pickAccent(&.{ Color.hex(0xcccccc), dark_blue, dark_blue }, against);
    try testing.expect(contrast(accent, against) >= 2.99);
    // Still blue: more blue than red.
    try testing.expect(accent.b > accent.r);
    // A gray theme keeps a gray accent, with contrast.
    const gray = pickAccent(&.{ Color.hex(0x444444), Color.hex(0x555555), Color.hex(0x666666) }, against);
    try testing.expect(chroma(gray) < 0.02);
    try testing.expect(contrast(gray, against) >= 2.99);
}

test "derived colors meet their contrast floors across themes" {
    const testing = std.testing;
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
    for (themes) |th| {
        const cursor: ?Color = if (th[2] == 0) null else Color.hex(th[2]);
        const t = Tokens.fromTheme(Color.hex(th[0]), Color.hex(th[1]), cursor, Color.hex(th[3]), Color.hex(th[4]));
        for ([_]Color{ t.surface, t.surface_raised }) |fill| {
            try testing.expect(contrast(t.text_secondary, fill) >= 4.49);
            try testing.expect(contrast(t.text_placeholder, fill) >= 4.49);
            try testing.expect(contrast(t.text_tertiary, fill) >= 2.99);
            try testing.expect(contrast(t.focus_stroke, fill) >= 2.99);
        }
        try testing.expect(contrast(t.accent, t.surface_raised) >= 2.99);
        try testing.expect(contrast(t.accent_text, t.surface_raised) >= 4.49);
        try testing.expect(contrast(t.on_accent, t.accent) >= 4.5);
        try testing.expect(contrast(t.on_text_selection, t.text_selection) >= 4.5);
        try testing.expect(contrast(t.border, t.background) >= 1.39);
        try testing.expect(contrast(t.border, t.surface_raised) >= 1.39);
        try testing.expect(contrast(t.selected_text, t.selected) >= 4.49);
        try testing.expect(contrast(t.title_bar, t.background) >= 1.119);
        for ([_]Color{ t.caution, t.success, t.critical }) |marker| {
            try testing.expect(contrast(marker, t.surface_raised) >= 2.99);
        }
        // Surfaces stay neutral under a saturated foreground.
        try testing.expect(chroma(t.surface_raised) <= chroma(t.background) + 0.02);
    }
}

test "high contrast uses the system colors" {
    const testing = std.testing;
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
}

test "fromConfig caches by color values" {
    const testing = std.testing;
    const saved = last;
    defer last = saved;
    last = null;
    const in: Inputs = .{
        .background = Color.hex(0x1e1e2e),
        .foreground = Color.hex(0xcdd6f4),
        .accents = .{ Color.hex(0xf5e0dc), Color.hex(0x89b4fa), Color.hex(0x89b4fa) },
    };
    const first = cached(in);
    try testing.expect(last != null);
    try testing.expectEqual(first.accent, cached(in).accent);
    var other = in;
    other.background = Color.hex(0xeff1f5);
    const second = cached(other);
    try testing.expect(!second.dark);
    try testing.expect(last.?.inputs.eql(other));
}

test "px rounds" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 36), px(metrics.tab_bar_height, 1.0));
    try testing.expectEqual(@as(i32, 54), px(metrics.tab_bar_height, 1.5));
    try testing.expectEqual(@as(i32, 12), px(8, 1.5));
    try testing.expectEqual(@as(i32, 21), pxCeil(13.5, 1.5));
    try testing.expectEqual(@as(i32, 20), pxCeil(13.3333333, 1.5));
    try testing.expectEqual(@as(i32, 14), pxCeil(13.1, 1.0));
}
