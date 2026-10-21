//! The colors of the Ghostty GX look of the GTK app, as CSS derived from
//! the terminal theme with the formulas of the shared interface library,
//! so that one theme gives the GTK and the win32 apprts the same colors:
//! `ui_tokens` for surfaces, text, the accent and the status colors,
//! `chrome` for the tab strip, the tabs and the split dividers.
//!
//! - The main window: rules below the `gx-chrome` class, which
//!   `src/apprt/gtk/gx/window.zig` puts on the window's toolbar view, so
//!   dialogs shown inside the window do not pick them up. The header bar
//!   and tab bar take the tab strip (`chrome.titleBar`, or
//!   `window-titlebar-background` and `-foreground`), the selected tab
//!   the terminal background (`selectedTab`), hovered and pressed tabs
//!   translucent overlays of the strip text and other tabs dimmer text; a
//!   single tab draws no background, as in libadwaita, and a tab being
//!   dragged takes the strip colors. Split dividers, an outline around the
//!   focused terminal when a tab has splits, and the bars of windows with
//!   the `.gx-superuser` or `.gx-remote` class tinted with palette 1 or 5.
//!   Over a translucent background with `background-blur`, the bars,
//!   selected tab and popovers are frosted (`min_bar_opacity`); dialog
//!   surfaces stay opaque so their headers and bodies match.
//! - The brand signature: a bar of `ui_metrics.signature.bar` px in the
//!   accent along the top of the selected tab (an inset box shadow, inside
//!   the rounded corners), also with a single tab and on a dragged tab,
//!   kept at 3:1 on the tab in every state and on tinted strips
//!   (`chrome.signature` and `chrome.tabSignature`, which the win32 tab bar
//!   draws too). `style.css` has a fallback in libadwaita's accent.
//! - The terminal overlays that upstream's `css/style.css` draws in fixed
//!   colors: the find, key table, resize and link overlays on
//!   `surface_raised` with `text` and a `border` outline, the bell border
//!   in the caution color, the child exited banners in the success and
//!   critical colors and a failed progress bar in the critical color. The
//!   shapes are static rules in `style.css`.
//! - Links (`label` link nodes, link buttons) in the main window and in
//!   the Ghostty GX dialogs, which carry the `gx-dialog` class, in
//!   `tokens.link` at 4.5:1 (`linkColor`); the dialogs' banners on the
//!   neutral `control_fill` instead of libadwaita's accent tint, and their
//!   source badges (`.gx-badge`) in the border and text tokens.
//! - Dialogs, popovers and the rest of libadwaita through its named colors
//!   (`@define-color`, which libadwaita 1.5 on GTK 4.14 reads): one raised
//!   surface for dialog bodies, their header bars, popovers and views, so
//!   a dialog's title area has the color of its body; cards and sidebars
//!   one step below it, as in the win32 settings; the accent
//!   (`ui_color.pickAccent` over the cursor color, palette 4 and palette
//!   12) and the status colors. libadwaita 1.6 and newer read CSS
//!   variables instead, which `writeVariables416` writes for GTK 4.16 and
//!   newer.
//!
//! Only `window-theme = auto` and `ghostty` get colors, and `system` when
//! the theme has a light and a dark part (`followsTerminal`): upstream
//! turns `auto` into `system` for such a theme, whose colors follow the
//! system's mode anyway, and the Ghostty GX defaults use one. The style
//! `src/apprt/gtk/gx/style.zig` drops them in high contrast, leaving the
//! system's high contrast colors (like `ui_tokens.Tokens.fromSystem` on
//! Windows). With `ghostty`, upstream's runtime CSS paints every header bar
//! in the title bar background above this stylesheet, so the strip and the
//! dialog surfaces take that color too. `style.zig` appends the output to
//! the static rules in `src/apprt/gtk/gx/style.css`. It is plain text
//! generation without GTK so the core test suite covers it. Every rule
//! after the named colors selects below `toolbarview.gx-chrome` (or a
//! session class above it), below `.gx-dialog`, or the dragged tab
//! (`dnd tab`), never a whole window or every dialog.
const std = @import("std");
const Config = @import("../config/Config.zig");
const chrome = @import("chrome.zig");
const ui_color = @import("ui_color.zig");
const ui_metrics = @import("ui_metrics.zig");
const ui_tokens = @import("ui_tokens.zig");
const Color = ui_color.Color;
const floor = ui_tokens.floor;

/// How much of palette 1 (superuser) or palette 5 (remote) is mixed into
/// the bars of a window whose active terminal runs such a session.
pub const status_tint: f32 = 0.24;

/// The least opacity of the window's bars, selected tab and popovers over a blurred
/// translucent background, so their text stays readable.
pub const min_bar_opacity: f32 = 0.85;

/// The opacity of the bell border and of the child exited banners over the
/// terminal, as upstream's fixed colors have.
pub const overlay_tint_opacity: f32 = 0.5;

/// A color as CSS: `rgb()` when opaque, else `rgba()`, with the components
/// rounded to 8 bits.
pub const Css = struct {
    color: Color,

    pub fn format(self: Css, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const c = self.color.toRgb8();
        if (self.color.a >= 1) {
            try writer.print("rgb({d},{d},{d})", .{ c.r, c.g, c.b });
        } else {
            try writer.print("rgba({d},{d},{d},{d:.2})", .{ c.r, c.g, c.b, @max(self.color.a, 0) });
        }
    }
};

pub fn css(color: Color) Css {
    return .{ .color = color };
}

pub const Colors = struct {
    /// The interface tokens of the terminal colors.
    tokens: ui_tokens.Tokens,

    /// The colors of the main window's header bar, tab bar and splits.
    chrome: chrome.Chrome,

    /// The fill of dialog bodies, their header bars, popovers and views,
    /// and the text on it.
    surface: Color,
    surface_text: Color,

    /// The colors tinting the bars of a window in a superuser or a remote
    /// session: palette 1 (red) and palette 5 (magenta).
    superuser: Color,
    remote: Color,

    /// The opacity of the window's bars, selected tab and popovers: frosted like the
    /// terminal (`background-opacity`, at least `min_bar_opacity`) when
    /// `background-blur` is on, else 1.
    bar_opacity: f32 = 1,
};

/// Whether the window follows the terminal colors: `window-theme = auto`
/// or `ghostty`, or `system` with a theme that has a light and a dark
/// part (see the file header); with `system` otherwise, `light` and
/// `dark` everything keeps the libadwaita colors.
pub fn followsTerminal(config: *const Config) bool {
    return switch (config.@"window-theme") {
        .auto, .ghostty => true,
        .system => config._conditional_set.contains(.theme),
        .light, .dark => false,
    };
}

/// The colors of the GX look for `config`, or null unless the window
/// follows the terminal colors (`followsTerminal`).
pub fn fromConfig(config: *const Config) ?Colors {
    if (!followsTerminal(config)) return null;
    const opacity: f32 = @floatCast(std.math.clamp(config.@"background-opacity", 0, 1));
    const ghostty = config.@"window-theme" == .ghostty;
    const tokens: ui_tokens.Tokens = .derive(.fromConfig(config));
    // `chrome.Options.fromConfig` drops the title bar colors on Windows,
    // which has no GTK look; reading them here keeps the CSS the same on
    // every host.
    var options: chrome.Options = .fromConfig(config);
    options.title_bar = if (config.@"window-titlebar-background") |c|
        fromConfigColor(c)
    else if (ghostty) tokens.background else null;
    options.title_bar_text = if (config.@"window-titlebar-foreground") |c|
        fromConfigColor(c)
    else if (ghostty) tokens.foreground else null;
    const bars: chrome.Chrome = .derive(&tokens, options);
    return .{
        .tokens = tokens,
        .chrome = bars,
        .surface = if (ghostty) bars.title_bar else tokens.surface_raised,
        .surface_text = if (ghostty) bars.text else tokens.text,
        .superuser = fromConfigColor(config.palette.value[1]),
        .remote = fromConfigColor(config.palette.value[5]),
        .bar_opacity = if (config.@"background-blur".enabled() and opacity < 1)
            @max(opacity, min_bar_opacity)
        else
            1,
    };
}

fn fromConfigColor(c: anytype) Color {
    return Color.rgb(c.r, c.g, c.b);
}

/// The libadwaita named colors of the GX look. `@define-color` takes the
/// field names; libadwaita 1.6 and newer read CSS variables named like
/// them with dashes (`--window-bg-color`). libadwaita 1.5 has no
/// `overview_*` colors; defining them is harmless.
pub const Named = struct {
    accent_bg_color: Color,
    accent_fg_color: Color,
    accent_color: Color,
    destructive_bg_color: Color,
    destructive_fg_color: Color,
    destructive_color: Color,
    success_bg_color: Color,
    success_fg_color: Color,
    success_color: Color,
    warning_bg_color: Color,
    warning_fg_color: Color,
    warning_color: Color,
    error_bg_color: Color,
    error_fg_color: Color,
    error_color: Color,
    window_bg_color: Color,
    window_fg_color: Color,
    view_bg_color: Color,
    view_fg_color: Color,
    headerbar_bg_color: Color,
    headerbar_fg_color: Color,
    headerbar_backdrop_color: Color,
    sidebar_bg_color: Color,
    sidebar_fg_color: Color,
    sidebar_backdrop_color: Color,
    secondary_sidebar_bg_color: Color,
    secondary_sidebar_fg_color: Color,
    secondary_sidebar_backdrop_color: Color,
    card_bg_color: Color,
    card_fg_color: Color,
    dialog_bg_color: Color,
    dialog_fg_color: Color,
    popover_bg_color: Color,
    popover_fg_color: Color,
    thumbnail_bg_color: Color,
    thumbnail_fg_color: Color,
    overview_bg_color: Color,
    overview_fg_color: Color,

    pub fn fromColors(colors: Colors) Named {
        const t = &colors.tokens;
        const surface = colors.surface;
        const text = colors.surface_text;
        const accent = ui_color.ensureContrast(t.accent, surface, floor.non_text);
        const critical = status(t.critical, surface);
        const success = status(t.success, surface);
        const caution = status(t.caution, surface);
        return .{
            .accent_bg_color = accent,
            .accent_fg_color = ui_color.onAccent(accent),
            .accent_color = ui_color.ensureContrast(t.accent_text, surface, floor.text),
            .destructive_bg_color = critical.bg,
            .destructive_fg_color = critical.fg,
            .destructive_color = critical.text,
            .success_bg_color = success.bg,
            .success_fg_color = success.fg,
            .success_color = success.text,
            .warning_bg_color = caution.bg,
            .warning_fg_color = caution.fg,
            .warning_color = caution.text,
            .error_bg_color = critical.bg,
            .error_fg_color = critical.fg,
            .error_color = critical.text,
            .window_bg_color = surface,
            .window_fg_color = text,
            .view_bg_color = surface,
            .view_fg_color = text,
            .headerbar_bg_color = surface,
            .headerbar_fg_color = text,
            .headerbar_backdrop_color = surface,
            .sidebar_bg_color = t.surface,
            .sidebar_fg_color = t.text,
            .sidebar_backdrop_color = t.surface,
            .secondary_sidebar_bg_color = t.surface,
            .secondary_sidebar_fg_color = t.text,
            .secondary_sidebar_backdrop_color = t.surface,
            .card_bg_color = t.surface,
            .card_fg_color = t.text,
            .dialog_bg_color = surface,
            .dialog_fg_color = text,
            .popover_bg_color = surface.withAlpha(colors.bar_opacity),
            .popover_fg_color = text,
            .thumbnail_bg_color = surface,
            .thumbnail_fg_color = text,
            .overview_bg_color = surface,
            .overview_fg_color = text,
        };
    }
};

const Status = struct { bg: Color, fg: Color, text: Color };

/// A status color as a fill (3:1 on `surface`), the text on that fill and
/// the color as text on `surface` (4.5:1).
fn status(color: Color, surface: Color) Status {
    const bg = ui_color.ensureContrast(color, surface, floor.non_text);
    return .{
        .bg = bg,
        .fg = ui_color.onAccent(bg),
        .text = ui_color.ensureContrast(color, surface, floor.text),
    };
}

/// The fill of the selected tab: the terminal background, so the tab joins
/// the terminal below it, unless the strip has (almost) that color too, as
/// with `window-theme = ghostty`; then a step from the strip toward its
/// text, the way libadwaita marks the selected tab.
pub fn selectedTab(bars: chrome.Chrome) Color {
    const strip = bars.title_bar;
    const ratio = chrome.strip_min_contrast;
    if (ui_color.contrast(bars.active_tab, strip) >= ratio) return bars.active_tab;
    const away = if (ui_color.isDark(strip)) Color.white else Color.black;
    return ui_color.mixToContrast(strip, bars.text, 0.12, strip, ratio) orelse
        ui_color.mixToContrast(strip, away, 0.12, strip, ratio) orelse
        ui_color.mix(strip, away, 0.12);
}

/// The bars of a window in a superuser or remote session.
pub const Tint = struct {
    bar: Color,
    text: Color,
    text_inactive: Color,

    pub fn derive(bars: chrome.Chrome, color: Color) Tint {
        const bar = ui_color.mix(bars.title_bar, color.withAlpha(bars.title_bar.a), status_tint);
        return .{
            .bar = bar,
            .text = ui_color.ensureContrast(bars.text, bar, floor.text),
            .text_inactive = ui_color.ensureContrast(bars.text_inactive, bar, floor.text),
        };
    }
};

/// The accent bar of the brand signature (`chrome.signature`, shared with
/// the win32 tab bar).
pub const signature = chrome.signature;

/// The color of links in the main window and the Ghostty GX dialogs:
/// `tokens.link` at 4.5:1 on the dialog surface, cards, the tab strip and
/// the terminal background.
pub fn linkColor(colors: Colors) Color {
    const t = &colors.tokens;
    return ui_color.ensureContrastAll(t.link, &.{
        colors.surface,
        t.surface,
        t.surface_raised,
        colors.chrome.title_bar.withAlpha(1),
        t.background,
    }, floor.text);
}

/// Writes the color rules for `colors`, all of which GTK 4.14 parses.
pub fn write(writer: *std.Io.Writer, colors: Colors) std.Io.Writer.Error!void {
    const named: Named = .fromColors(colors);
    try writer.writeAll("/* Ghostty GX colors derived from the terminal theme */\n");
    inline for (@typeInfo(Named).@"struct".field_names) |field| {
        try writer.print("@define-color " ++ field ++ " {f};\n", .{css(@field(named, field))});
    }

    const bars = colors.chrome;
    const t = colors.tokens;
    const active = selectedTab(bars).withAlpha(colors.bar_opacity);
    try writer.print(
        \\toolbarview.gx-chrome > .top-bar,
        \\toolbarview.gx-chrome > .bottom-bar {{
        \\  background-color: {[bar]f};
        \\  color: {[text]f};
        \\}}
        \\dnd tab {{
        \\  background-color: {[strip]f};
        \\  color: {[text]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tab:not(:selected) {{
        \\  color: {[inactive]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:hover {{
        \\  background-color: {[hover]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:active {{
        \\  background-color: {[pressed]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:selected {{
        \\  background-color: {[active]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:selected:hover {{
        \\  background-color: {[active_hover]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:selected:active {{
        \\  background-color: {[active_pressed]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox > tabboxchild:focus-within:focus-visible {{
        \\  outline-color: {[tab_focus]f};
        \\}}
        \\toolbarview.gx-chrome .split paned > separator {{
        \\  background-image: image({[divider]f});
        \\  box-shadow: none;
        \\}}
        \\toolbarview.gx-chrome .split .surface:focus-within {{
        \\  outline: 1px solid {[split_focus]f};
        \\  outline-offset: -1px;
        \\}}
        \\
    , .{
        .bar = css(bars.title_bar.withAlpha(colors.bar_opacity)),
        .strip = css(bars.title_bar),
        .text = css(bars.text),
        .inactive = css(bars.text_inactive),
        .hover = css(bars.hover),
        .pressed = css(bars.pressed),
        .active = css(active),
        .active_hover = css(ui_color.over(bars.hover, active)),
        .active_pressed = css(ui_color.over(bars.pressed, active)),
        .tab_focus = css(ui_color.ensureContrast(t.focus_stroke_accent, bars.title_bar, floor.non_text)),
        .divider = css(bars.divider),
        .split_focus = css(ui_color.ensureContrast(t.focus_stroke_accent, t.background, floor.non_text)),
    });

    // The brand signature, over the selected tab in every state; a single
    // tab and a dragged one sit on the strip, frosted over the terminal.
    try writer.print(
        \\toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:selected {{
        \\  box-shadow: inset 0 {[bar]d}px 0 0 {[tabs]f};
        \\}}
        \\toolbarview.gx-chrome tabbar tabbox.single-tab tab:selected {{
        \\  box-shadow: inset 0 {[bar]d}px 0 0 {[single]f};
        \\}}
        \\dnd tab {{
        \\  box-shadow: inset 0 {[bar]d}px 0 0 {[dragged]f};
        \\}}
        \\
    , .{
        .bar = ui_metrics.signature.bar,
        .tabs = css(chrome.tabSignature(t.accent, bars, active, t.background)),
        .single = css(signature(t.accent, &.{ bars.title_bar, t.background })),
        .dragged = css(signature(t.accent, &.{bars.title_bar})),
    });

    // Upstream's terminal overlays (`src/apprt/gtk/css/style.css`).
    try writer.print(
        \\toolbarview.gx-chrome label.url-overlay,
        \\toolbarview.gx-chrome .search-overlay,
        \\toolbarview.gx-chrome .key-state-overlay,
        \\toolbarview.gx-chrome label.resize-overlay {{
        \\  background-color: {[raised]f};
        \\  color: {[text]f};
        \\  outline-color: {[border]f};
        \\}}
        \\toolbarview.gx-chrome .surface .bell-overlay {{
        \\  border-color: {[bell]f};
        \\}}
        \\toolbarview.gx-chrome .child-exited.normal revealer widget {{
        \\  background-color: {[exited]f};
        \\}}
        \\toolbarview.gx-chrome .child-exited.abnormal revealer widget {{
        \\  background-color: {[failed]f};
        \\}}
        \\toolbarview.gx-chrome .surface progressbar.error trough progress {{
        \\  background-color: {[progress]f};
        \\}}
        \\
    , .{
        .raised = css(t.surface_raised),
        .text = css(t.text),
        .border = css(t.border),
        .bell = css(t.caution.withAlpha(overlay_tint_opacity)),
        .exited = css(t.success.withAlpha(overlay_tint_opacity)),
        .failed = css(t.critical.withAlpha(overlay_tint_opacity)),
        .progress = css(t.critical),
    });

    // Links, and the banners and badges of the Ghostty GX dialogs.
    try writer.print(
        \\toolbarview.gx-chrome *:link,
        \\toolbarview.gx-chrome *:visited,
        \\toolbarview.gx-chrome button.link,
        \\toolbarview.gx-chrome button.link > label,
        \\.gx-dialog *:link,
        \\.gx-dialog *:visited,
        \\.gx-dialog button.link,
        \\.gx-dialog button.link > label {{
        \\  color: {[link]f};
        \\}}
        \\.gx-dialog banner > revealer > widget {{
        \\  background-color: {[banner]f};
        \\  color: {[text]f};
        \\}}
        \\.gx-dialog .gx-badge.gx-source-defaults {{
        \\  color: {[tertiary]f};
        \\  box-shadow: inset 0 0 0 1px {[border]f};
        \\}}
        \\.gx-dialog .gx-badge.gx-source-settings,
        \\.gx-dialog .gx-badge.gx-advanced {{
        \\  color: {[secondary]f};
        \\  box-shadow: inset 0 0 0 1px {[border]f};
        \\}}
        \\.gx-dialog .gx-badge.gx-source-user {{
        \\  color: {[text]f};
        \\  background-color: {[fill]f};
        \\}}
        \\.gx-dialog .gx-badge.gx-source-cli {{
        \\  color: {[text]f};
        \\  background-color: {[fill_strong]f};
        \\  box-shadow: inset 0 0 0 1px {[border]f};
        \\}}
        \\.gx-dialog .gx-badge.gx-mark:not(.gx-accent) {{
        \\  color: {[secondary]f};
        \\  background-color: {[fill]f};
        \\}}
        \\
    , .{
        .link = css(linkColor(colors)),
        .banner = css(t.control_fill),
        .text = css(t.text),
        .tertiary = css(t.text_tertiary),
        .secondary = css(t.text_secondary),
        .border = css(t.border),
        .fill = css(t.control_fill),
        .fill_strong = css(t.control_fill_hover),
    });

    try writeTint(writer, "gx-superuser", bars, colors.superuser, t.accent, colors.bar_opacity);
    try writeTint(writer, "gx-remote", bars, colors.remote, t.accent, colors.bar_opacity);
}

fn writeTint(
    writer: *std.Io.Writer,
    class: []const u8,
    bars: chrome.Chrome,
    color: Color,
    accent: Color,
    opacity: f32,
) std.Io.Writer.Error!void {
    const tint: Tint = .derive(bars, color);
    try writer.print(
        \\.{[class]s} toolbarview.gx-chrome > .top-bar,
        \\.{[class]s} toolbarview.gx-chrome > .bottom-bar {{
        \\  background-color: {[bar]f};
        \\  color: {[text]f};
        \\}}
        \\.{[class]s} toolbarview.gx-chrome tabbar tab:not(:selected) {{
        \\  color: {[inactive]f};
        \\}}
        \\.{[class]s} toolbarview.gx-chrome tabbar tabbox.single-tab tab:selected {{
        \\  box-shadow: inset 0 {[size]d}px 0 0 {[signature]f};
        \\}}
        \\
    , .{
        .class = class,
        .bar = css(tint.bar.withAlpha(opacity)),
        .text = css(tint.text),
        .inactive = css(tint.text_inactive),
        .size = ui_metrics.signature.bar,
        .signature = css(signature(accent, &.{ tint.bar, bars.title_bar })),
    });
}

/// Writes the named colors of `colors` as the CSS variables of libadwaita
/// 1.6 and newer, which declares them on `:root`; `window` (the root node
/// of every window) also gets them in case a libadwaita release declares
/// them there. Variables inherit, so popovers and dialogs inside a window
/// follow. Only for GTK 4.16 and newer, which parse variables: the caller
/// checks the runtime version.
pub fn writeVariables416(writer: *std.Io.Writer, colors: Colors) std.Io.Writer.Error!void {
    const named: Named = .fromColors(colors);
    try writer.writeAll(":root,\nwindow {\n");
    inline for (@typeInfo(Named).@"struct".field_names) |field| {
        try writer.print("  --" ++ comptime dashed(field) ++ ": {f};\n", .{css(@field(named, field))});
    }
    try writer.writeAll("}\n");
}

fn dashed(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = name[0..name.len].*;
        for (&out) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const result = out;
        return &result;
    }
}

const testing = std.testing;
const contrast = ui_color.contrast;

fn gxMochaConfig() !Config {
    var config = try Config.default(testing.allocator);
    errdefer config.deinit();
    config.background = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };
    config.foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    config.@"cursor-color" = .{ .color = .{ .r = 0xf5, .g = 0xe0, .b = 0xdc } };
    config.palette.value[1] = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 };
    config.palette.value[4] = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };
    config.palette.value[5] = .{ .r = 0xf5, .g = 0xc2, .b = 0xe7 };
    config.palette.value[12] = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };
    // These tests follow the theme's accent; `brand` has its own test.
    config.@"gx-accent-color" = .theme;
    return config;
}

fn written(colors: Colors, comptime variables: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    if (variables) try writeVariables416(&out.writer, colors) else try write(&out.writer, colors);
    return out.toOwnedSlice();
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "fromConfig follows window-theme" {
    var config = try gxMochaConfig();
    defer config.deinit();

    config.@"window-theme" = .auto;
    const auto = fromConfig(&config).?;
    // The rosewater cursor is almost gray: the accent is palette 4 (D3).
    try testing.expectEqual(@as(u24, 0x89b4fa), auto.tokens.accent.toHex());
    // The strip is a step darker than the terminal, the selected tab joins it.
    try testing.expectEqual(chrome.titleBar(auto.tokens.background, auto.tokens.foreground), auto.chrome.title_bar);
    try testing.expectEqual(@as(u24, 0x1f1f28), auto.chrome.active_tab.toHex());
    try testing.expectEqual(auto.tokens.surface_raised, auto.surface);
    try testing.expectEqual(@as(u24, 0xf38ba8), auto.superuser.toHex());
    try testing.expectEqual(@as(u24, 0xf5c2e7), auto.remote.toHex());

    // `ghostty`: the strip and the surfaces take the title bar colors, as
    // upstream paints the header bars with them.
    config.@"window-theme" = .ghostty;
    const plain = fromConfig(&config).?;
    try testing.expectEqual(@as(u24, 0x1f1f28), plain.chrome.title_bar.toHex());
    try testing.expectEqual(@as(u24, 0x1f1f28), plain.surface.toHex());
    try testing.expectEqual(@as(u24, 0xffffff), plain.surface_text.toHex());
    config.@"window-titlebar-background" = .{ .r = 1, .g = 2, .b = 3 };
    const titled = fromConfig(&config).?;
    try testing.expectEqual(@as(u24, 0x010203), titled.chrome.title_bar.toHex());
    try testing.expectEqual(@as(u24, 0x010203), titled.surface.toHex());
    try testing.expectEqual(@as(u24, 0x1f1f28), titled.chrome.active_tab.toHex());

    for ([_]Config.WindowTheme{ .system, .light, .dark }) |theme| {
        config.@"window-theme" = theme;
        try testing.expectEqual(@as(?Colors, null), fromConfig(&config));
    }
}

test "a light and dark theme pair keeps the GX colors" {
    // Upstream turns `auto` into `system` for `theme = light:…,dark:…`,
    // as with the Ghostty GX defaults.
    var config = try gxMochaConfig();
    defer config.deinit();
    config.@"window-theme" = .system;
    config._conditional_set.insert(.theme);
    try testing.expect(followsTerminal(&config));
    const colors = fromConfig(&config).?;
    try testing.expectEqual(colors.tokens.surface_raised, colors.surface);
    for ([_]Config.WindowTheme{ .light, .dark }) |theme| {
        config.@"window-theme" = theme;
        try testing.expect(!followsTerminal(&config));
    }
}

test "the default brand accent is the GX purple, links the GX blue" {
    var config = try gxMochaConfig();
    defer config.deinit();
    config.@"gx-accent-color" = .brand;
    const colors = fromConfig(&config).?;
    try testing.expectEqual(ui_tokens.brand.purple_dark, colors.tokens.accent);
    try testing.expectEqual(ui_tokens.brand.blue_dark, colors.tokens.link);
    const named: Named = .fromColors(colors);
    try testing.expectEqual(@as(u24, 0xcba6f7), named.accent_bg_color.toHex());
    try testing.expectEqual(Color.black, named.accent_fg_color);
}

test "the selected tab stands out of the strip" {
    var config = try gxMochaConfig();
    defer config.deinit();

    // auto: the strip is darker, the selected tab is the terminal.
    const auto = fromConfig(&config).?;
    try testing.expectEqual(auto.chrome.active_tab, selectedTab(auto.chrome));

    // ghostty: the strip is the terminal background, so the selected tab
    // steps toward the text instead of vanishing into the strip.
    config.@"window-theme" = .ghostty;
    const plain = fromConfig(&config).?;
    const selected = selectedTab(plain.chrome);
    try testing.expect(contrast(selected, plain.chrome.title_bar) >= chrome.strip_min_contrast);
    try testing.expectEqual(ui_color.mix(plain.chrome.title_bar, plain.chrome.text, 0.12), selected);
    const out = try written(plain, false);
    defer testing.allocator.free(out);
    var buf: [128]u8 = undefined;
    try testing.expect(has(out, try std.mem.print(&buf, "tabbox:not(.single-tab) tab:selected {{\n  background-color: {f};", .{css(selected)})));

    // A foreground as dark as the background still gets a visible tab.
    config.foreground = config.background;
    const dim = fromConfig(&config).?;
    try testing.expect(contrast(selectedTab(dim.chrome), dim.chrome.title_bar) >= chrome.strip_min_contrast);
}

test "named colors put dialogs, popovers and their header bars on one surface" {
    var config = try gxMochaConfig();
    defer config.deinit();
    const colors = fromConfig(&config).?;
    const named: Named = .fromColors(colors);
    const t = colors.tokens;
    try testing.expectEqual(@as(u24, 0x89b4fa), named.accent_bg_color.toHex());
    try testing.expectEqual(Color.black, named.accent_fg_color);
    for ([_]Color{
        named.window_bg_color,
        named.dialog_bg_color,
        named.popover_bg_color,
        named.headerbar_bg_color,
        named.headerbar_backdrop_color,
        named.view_bg_color,
    }) |c| try testing.expectEqual(t.surface_raised, c);
    try testing.expectEqual(t.surface, named.card_bg_color);
    try testing.expectEqual(t.surface, named.sidebar_bg_color);
    try testing.expectEqual(t.text, named.dialog_fg_color);
}

test "named colors keep their contrast floors" {
    const schemes = [_][3]u24{
        .{ 0x1f1f28, 0xffffff, 0x89b4fa }, // GX Mocha
        .{ 0xeff1f5, 0x4c4f69, 0x1e66f5 }, // Catppuccin Latte
        .{ 0xfdf6e3, 0x657b83, 0x268bd2 }, // Solarized Light
        .{ 0x000000, 0xffffff, 0x0000ee }, // xterm
        .{ 0x3a3a3a, 0x7a7a7a, 0x4a4a4a }, // dim grays
    };
    for (schemes) |scheme| {
        var config = try Config.default(testing.allocator);
        defer config.deinit();
        config.background = .{ .r = @truncate(scheme[0] >> 16), .g = @truncate(scheme[0] >> 8), .b = @truncate(scheme[0]) };
        config.foreground = .{ .r = @truncate(scheme[1] >> 16), .g = @truncate(scheme[1] >> 8), .b = @truncate(scheme[1]) };
        config.palette.value[4] = .{ .r = @truncate(scheme[2] >> 16), .g = @truncate(scheme[2] >> 8), .b = @truncate(scheme[2]) };
        config.@"cursor-color" = null;
        for ([_]Config.WindowTheme{ .auto, .ghostty }) |theme| {
            config.@"window-theme" = theme;
            const colors = fromConfig(&config).?;
            const n: Named = .fromColors(colors);
            const on = n.dialog_bg_color;
            try testing.expect(contrast(n.accent_bg_color, on) >= floor.non_text);
            try testing.expect(contrast(n.accent_color, on) >= floor.text);
            try testing.expect(contrast(n.destructive_color, on) >= floor.text);
            try testing.expect(contrast(n.warning_color, on) >= floor.text);
            try testing.expect(contrast(n.success_color, on) >= floor.text);
            try testing.expect(contrast(n.error_bg_color, on) >= floor.non_text);
            try testing.expect(contrast(n.accent_fg_color, n.accent_bg_color) >= contrast(if (std.meta.eql(n.accent_fg_color, Color.black)) Color.white else Color.black, n.accent_bg_color));
            for ([_]Color{ colors.superuser, colors.remote }) |status_color| {
                const tint: Tint = .derive(colors.chrome, status_color);
                try testing.expect(contrast(tint.text, tint.bar) >= floor.text);
                try testing.expect(contrast(tint.text_inactive, tint.bar) >= floor.text);
            }
        }
    }
}

test "the bars are frosted only over a blurred translucent background" {
    var config = try gxMochaConfig();
    defer config.deinit();
    try testing.expectEqual(@as(f32, 1), fromConfig(&config).?.bar_opacity);
    config.@"background-opacity" = 0.5;
    try testing.expectEqual(@as(f32, 1), fromConfig(&config).?.bar_opacity);
    config.@"background-blur" = .true;
    try testing.expectEqual(min_bar_opacity, fromConfig(&config).?.bar_opacity);
    config.@"background-opacity" = 0.9;
    const colors = fromConfig(&config).?;
    try testing.expectApproxEqAbs(@as(f32, 0.9), colors.bar_opacity, 1e-6);
    config.@"background-opacity" = 1;
    try testing.expectEqual(@as(f32, 1), fromConfig(&config).?.bar_opacity);

    const out = try written(colors, false);
    defer testing.allocator.free(out);
    const strip = colors.chrome.title_bar.toRgb8();
    var buf: [128]u8 = undefined;
    // The bars and the selected tab let the blur through; the tab being
    // dragged, a window of its own, stays opaque.
    try testing.expect(has(out, try std.mem.print(&buf, ".bottom-bar {{\n  background-color: rgba({d},{d},{d},0.90);", .{ strip.r, strip.g, strip.b })));
    try testing.expect(has(out, "tab:selected {\n  background-color: rgba(31,31,40,0.90);"));
    try testing.expect(has(out, try std.mem.print(&buf, "dnd tab {{\n  background-color: rgb({d},{d},{d});", .{ strip.r, strip.g, strip.b })));
}

test "frosted popovers retain an opacity floor and leave dialog headers opaque" {
    var config = try gxMochaConfig();
    defer config.deinit();
    config.@"background-opacity" = 0.5;
    try testing.expectEqual(@as(f32, 1), Named.fromColors(fromConfig(&config).?).popover_bg_color.a);
    config.@"background-blur" = .true;

    for ([_]Config.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        const colors = fromConfig(&config).?;
        const named: Named = .fromColors(colors);
        try testing.expectEqual(min_bar_opacity, named.popover_bg_color.a);
        try testing.expectEqual(colors.surface.toHex(), named.popover_bg_color.toHex());
        try testing.expectEqual(colors.surface, named.dialog_bg_color);
        try testing.expectEqual(named.dialog_bg_color, named.headerbar_bg_color);
        try testing.expectEqual(named.dialog_bg_color, named.window_bg_color);
        try testing.expectEqual(colors.surface_text, named.popover_fg_color);

        const out = try written(colors, false);
        defer testing.allocator.free(out);
        const variables = try written(colors, true);
        defer testing.allocator.free(variables);
        var buf: [128]u8 = undefined;
        try testing.expect(has(out, try std.mem.print(&buf, "@define-color popover_bg_color {f};\n", .{css(named.popover_bg_color)})));
        try testing.expect(has(variables, try std.mem.print(&buf, "  --popover-bg-color: {f};\n", .{css(named.popover_bg_color)})));
    }
}

test "status tints mix palette 1 and 5 into the strip" {
    var config = try gxMochaConfig();
    defer config.deinit();
    const colors = fromConfig(&config).?;
    const superuser: Tint = .derive(colors.chrome, colors.superuser);
    try testing.expectEqual(ui_color.mix(colors.chrome.title_bar, colors.superuser, status_tint), superuser.bar);
    try testing.expect(superuser.bar.r > superuser.bar.b);
    // White text needs no change on the dark tinted strip.
    try testing.expectEqual(colors.chrome.text, superuser.text);
}

test "write scopes the window chrome to gx-chrome and parses on GTK 4.14" {
    var config = try gxMochaConfig();
    defer config.deinit();
    const colors = fromConfig(&config).?;
    const out = try written(colors, false);
    defer testing.allocator.free(out);

    var buf: [128]u8 = undefined;
    try testing.expect(has(out, "@define-color accent_bg_color rgb(137,180,250);\n"));
    try testing.expect(has(out, "@define-color accent_fg_color rgb(0,0,0);\n"));
    for ([_][]const u8{ "window_bg_color", "popover_bg_color", "headerbar_bg_color", "dialog_bg_color" }) |name| {
        try testing.expect(has(out, try std.mem.print(&buf, "@define-color {s} {f};\n", .{ name, css(colors.tokens.surface_raised) })));
    }
    try testing.expect(has(out, try std.mem.print(&buf, "@define-color card_bg_color {f};\n", .{css(colors.tokens.surface)})));

    const bar = try std.mem.print(&buf, "toolbarview.gx-chrome > .bottom-bar {{\n  background-color: {f};\n  color: rgb(255,255,255);\n}}", .{css(colors.chrome.title_bar)});
    try testing.expect(has(out, bar));
    const dragged = try std.mem.print(&buf, "dnd tab {{\n  background-color: {f};\n  color: rgb(255,255,255);\n}}", .{css(colors.chrome.title_bar)});
    try testing.expect(has(out, dragged));
    // The selected tab joins the terminal; hover and press are overlays,
    // pressed fainter than hovered; a single tab draws nothing.
    try testing.expect(has(out, "tabbox:not(.single-tab) tab:selected {\n  background-color: rgb(31,31,40);"));
    try testing.expect(has(out, "tabbox:not(.single-tab) tab:hover {\n  background-color: rgba(255,255,255,0.08);"));
    try testing.expect(has(out, "tabbox:not(.single-tab) tab:active {\n  background-color: rgba(255,255,255,0.05);"));
    // Inset shadows only draw the signature and the badge outlines.
    var shadows = std.mem.splitSequence(u8, out, "box-shadow: inset ");
    _ = shadows.next();
    while (shadows.next()) |rest| {
        try testing.expect(std.mem.startsWith(u8, rest, "0 2px 0 0 ") or std.mem.startsWith(u8, rest, "0 0 0 1px "));
    }
    try testing.expect(has(out, "background-image: image(rgb(65,65,72));\n  box-shadow: none;"));
    try testing.expect(has(out, ".split .surface:focus-within {\n  outline: 1px solid rgb(137,180,250);"));
    try testing.expect(has(out, ".gx-superuser toolbarview.gx-chrome > .top-bar,"));
    try testing.expect(has(out, ".gx-remote toolbarview.gx-chrome tabbar tab:not(:selected) {"));

    // Every rule but the dragged tab selects below the main toolbar view,
    // the session classes or the Ghostty GX dialogs, never a whole window.
    const first_rule = std.mem.indexOf(u8, out, "toolbarview.gx-chrome > .top-bar") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.lastIndexOf(u8, out, "@define-color").? < first_rule);
    var rules = std.mem.splitSequence(u8, out[first_rule..], "}\n");
    while (rules.next()) |rule| {
        const open = std.mem.indexOfScalar(u8, rule, '{') orelse continue;
        var selectors = std.mem.splitScalar(u8, rule[0..open], ',');
        while (selectors.next()) |raw| {
            const selector = std.mem.trim(u8, raw, " \n");
            if (selector.len == 0 or std.mem.startsWith(u8, selector, "/*")) continue;
            try testing.expect(std.mem.eql(u8, selector, "dnd tab") or
                has(selector, "toolbarview.gx-chrome ") or
                std.mem.startsWith(u8, selector, ".gx-dialog "));
        }
    }
    try testing.expectEqual(std.mem.count(u8, out, "{"), std.mem.count(u8, out, "}"));
    for ([_][]const u8{ "var(", ":root", "--", "color-mix(", ".window " }) |newer| {
        try testing.expect(!has(out, newer));
    }
}

test "writeVariables416 writes the same colors as libadwaita variables" {
    var config = try gxMochaConfig();
    defer config.deinit();
    const colors = fromConfig(&config).?;
    const out = try written(colors, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, ":root,\nwindow {\n"));
    try testing.expect(has(out, "  --accent-bg-color: rgb(137,180,250);\n"));
    try testing.expect(has(out, "  --window-bg-color: rgb(53,53,62);\n"));
    try testing.expect(has(out, "  --secondary-sidebar-backdrop-color: "));
    try testing.expect(!has(out, "_color"));
    try testing.expectEqual(@typeInfo(Named).@"struct".field_names.len, std.mem.count(u8, out, "\n  --"));
    try testing.expectEqualStrings("window-bg-color", comptime dashed("window_bg_color"));
}

test "Css formats opaque and translucent colors" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("rgb(137,180,250)", try std.mem.print(&buf, "{f}", .{css(Color.hex(0x89b4fa))}));
    try testing.expectEqualStrings("rgba(255,255,255,0.08)", try std.mem.print(&buf, "{f}", .{css(Color.white.withAlpha(0.08))}));
}

fn gxLatteConfig() !Config {
    var config = try Config.default(testing.allocator);
    errdefer config.deinit();
    config.background = .{ .r = 0xef, .g = 0xf1, .b = 0xf5 };
    config.foreground = .{ .r = 0x4c, .g = 0x4f, .b = 0x69 };
    config.@"cursor-color" = .{ .color = .{ .r = 0xdc, .g = 0x8a, .b = 0x78 } };
    config.palette.value[1] = .{ .r = 0xd2, .g = 0x0f, .b = 0x39 };
    config.palette.value[2] = .{ .r = 0x40, .g = 0xa0, .b = 0x2b };
    config.palette.value[3] = .{ .r = 0xdf, .g = 0x8e, .b = 0x1d };
    config.palette.value[4] = .{ .r = 0x1e, .g = 0x66, .b = 0xf5 };
    config.palette.value[5] = .{ .r = 0xea, .g = 0x76, .b = 0xcb };
    config.palette.value[12] = .{ .r = 0x1e, .g = 0x66, .b = 0xf5 };
    config.@"gx-accent-color" = .brand;
    return config;
}

/// The declarations of the first rule in `out` whose selector list is
/// exactly `selectors`.
fn ruleBody(out: []const u8, selectors: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, out, start, selectors)) |at| {
        start = at + selectors.len;
        const line_start = at == 0 or out[at - 1] == '\n' or out[at - 1] == '}';
        if (!line_start or !std.mem.startsWith(u8, out[start..], " {\n")) continue;
        const body = start + " {\n".len;
        const end = std.mem.indexOfPos(u8, out, body, "}") orelse return null;
        return out[body..end];
    }
    return null;
}

/// The color of `property` in `body` (as `Css` writes it).
fn declared(body: []const u8, property: []const u8, buf: []u8) ![]const u8 {
    const at = std.mem.indexOf(u8, body, property) orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfScalarPos(u8, body, at, ';') orelse return error.TestUnexpectedResult;
    return std.mem.print(buf, "{s}", .{body[at + property.len .. end]});
}

test "the signature bar marks the selected tab at 3:1 in every state" {
    var mocha = try gxMochaConfig();
    defer mocha.deinit();
    mocha.@"gx-accent-color" = .brand;
    var latte = try gxLatteConfig();
    defer latte.deinit();
    for ([_]*Config{ &mocha, &latte }) |config| {
        for ([_]Config.WindowTheme{ .auto, .ghostty }) |theme| {
            for ([_]bool{ false, true }) |frosted| {
                config.@"window-theme" = theme;
                config.@"background-opacity" = if (frosted) 0.6 else 1;
                config.@"background-blur" = if (frosted) .true else .false;
                const colors = fromConfig(config).?;
                const bars = colors.chrome;
                const active = selectedTab(bars).withAlpha(1);
                const tabs = signature(colors.tokens.accent, &.{
                    active,
                    ui_color.over(bars.hover, active),
                    ui_color.over(bars.pressed, active),
                });
                for ([_]Color{ active, ui_color.over(bars.hover, active), ui_color.over(bars.pressed, active) }) |fill| {
                    try testing.expect(contrast(tabs, fill) >= floor.non_text);
                }
                try testing.expect(contrast(signature(colors.tokens.accent, &.{bars.title_bar}), bars.title_bar) >= floor.non_text);

                const out = try written(colors, false);
                defer testing.allocator.free(out);
                for ([_][]const u8{
                    "toolbarview.gx-chrome tabbar tabbox:not(.single-tab) tab:selected",
                    "toolbarview.gx-chrome tabbar tabbox.single-tab tab:selected",
                    "dnd tab",
                    ".gx-superuser toolbarview.gx-chrome tabbar tabbox.single-tab tab:selected",
                    ".gx-remote toolbarview.gx-chrome tabbar tabbox.single-tab tab:selected",
                }) |selectors| {
                    var found = false;
                    var start: usize = 0;
                    while (std.mem.indexOfPos(u8, out, start, selectors)) |at| {
                        start = at + selectors.len;
                        const rest = out[start..];
                        if (!std.mem.startsWith(u8, rest, " {\n  box-shadow: inset 0 2px 0 0 ")) continue;
                        found = true;
                        break;
                    }
                    try testing.expect(found);
                }
            }
        }
    }
    // The brand purple on the GX Mocha terminal background needs no change.
    mocha.@"window-theme" = .auto;
    mocha.@"background-opacity" = 1;
    mocha.@"background-blur" = .false;
    const colors = fromConfig(&mocha).?;
    const out = try written(colors, false);
    defer testing.allocator.free(out);
    try testing.expect(has(out, "tabbox:not(.single-tab) tab:selected {\n  box-shadow: inset 0 2px 0 0 rgb(203,166,247);"));
    try testing.expectEqual(@as(f32, 2), ui_metrics.signature.bar);
}

test "the terminal overlays take the interface tokens" {
    var latte = try gxLatteConfig();
    defer latte.deinit();
    const colors = fromConfig(&latte).?;
    const t = colors.tokens;
    const out = try written(colors, false);
    defer testing.allocator.free(out);
    var buf: [256]u8 = undefined;
    const overlays = ruleBody(out,
        \\toolbarview.gx-chrome label.url-overlay,
        \\toolbarview.gx-chrome .search-overlay,
        \\toolbarview.gx-chrome .key-state-overlay,
        \\toolbarview.gx-chrome label.resize-overlay
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(try std.mem.print(&buf, "  background-color: {f};\n  color: {f};\n  outline-color: {f};\n", .{
        css(t.surface_raised), css(t.text), css(t.border),
    }), overlays);
    // Light themes lift the overlay surface toward white.
    try testing.expect(t.surface_raised.r > t.background.r);

    var color: [64]u8 = undefined;
    const bell = ruleBody(out, "toolbarview.gx-chrome .surface .bell-overlay") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(try std.mem.print(&buf, "{f}", .{css(t.caution.withAlpha(overlay_tint_opacity))}), try declared(bell, "border-color: ", &color));
    try testing.expect(!has(bell, "border-width"));
    const exited = ruleBody(out, "toolbarview.gx-chrome .child-exited.normal revealer widget") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(try std.mem.print(&buf, "{f}", .{css(t.success.withAlpha(0.5))}), try declared(exited, "background-color: ", &color));
    const failed = ruleBody(out, "toolbarview.gx-chrome .child-exited.abnormal revealer widget") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(try std.mem.print(&buf, "{f}", .{css(t.critical.withAlpha(0.5))}), try declared(failed, "background-color: ", &color));
    const progress = ruleBody(out, "toolbarview.gx-chrome .surface progressbar.error trough progress") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(try std.mem.print(&buf, "{f}", .{css(t.critical)}), try declared(progress, "background-color: ", &color));
    // Upstream's fixed gray outline and colors are gone from the GX output.
    try testing.expect(!has(out, "#555555"));
    try testing.expect(!has(out, "rgba(192,28,40"));
}

test "links keep 4.5:1, banners and badges stay neutral" {
    var mocha = try gxMochaConfig();
    defer mocha.deinit();
    mocha.@"gx-accent-color" = .brand;
    var latte = try gxLatteConfig();
    defer latte.deinit();
    for ([_]*Config{ &mocha, &latte }) |config| {
        for ([_]Config.WindowTheme{ .auto, .ghostty }) |theme| {
            config.@"window-theme" = theme;
            const colors = fromConfig(config).?;
            const t = colors.tokens;
            const link = linkColor(colors);
            for ([_]Color{ colors.surface, t.surface, t.surface_raised, colors.chrome.title_bar, t.background }) |on| {
                try testing.expect(contrast(link, on) >= floor.text);
            }
            const out = try written(colors, false);
            defer testing.allocator.free(out);
            var buf: [128]u8 = undefined;
            try testing.expect(has(out, try std.mem.print(&buf, ".gx-dialog button.link > label {{\n  color: {f};", .{css(link)})));
            try testing.expect(has(out, "toolbarview.gx-chrome *:link,\ntoolbarview.gx-chrome *:visited,"));
            const banner = ruleBody(out, ".gx-dialog banner > revealer > widget") orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(try std.mem.print(&buf, "  background-color: {f};\n  color: {f};\n", .{ css(t.control_fill), css(t.text) }), banner);
            // The badges use no accent or status color.
            const first = std.mem.indexOf(u8, out, ".gx-dialog .gx-badge") orelse return error.TestUnexpectedResult;
            const tints = std.mem.indexOfPos(u8, out, first, ".gx-superuser") orelse return error.TestUnexpectedResult;
            const badges = out[first..tints];
            for ([_]Color{ t.accent, t.accent_text, t.caution, t.success, t.critical }) |colorful| {
                try testing.expect(!has(badges, try std.mem.print(&buf, "{f};", .{css(colorful)})));
            }
            try testing.expect(has(badges, ".gx-dialog .gx-badge.gx-mark:not(.gx-accent) {"));
        }
    }
}
