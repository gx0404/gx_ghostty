//! DWM chrome theming and window backdrop of a top-level terminal window:
//! the dark/light title bar and caption color (`window-theme`,
//! `background`), the dark theme of common controls, translucency
//! (`background-opacity` through `WS_EX_LAYERED`) and the accent blur
//! behind translucent windows (`background-blur`).
//!
//! Stateless: everything lives on the HWND. `Window` calls `apply` once
//! after creating its HWND and `onConfigChange` after every app-level
//! configuration change; `App` uses `toggleOpacity` for
//! `toggle_background_opacity`. The window material (`gx-window-material`:
//! Mica, acrylic, tabbed) belongs here as well.
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const w32 = @import("../win32.zig");

pub const ApplyOptions = struct {
    /// Start fully opaque regardless of `background-opacity` (a new window
    /// inheriting a parent that was toggled opaque).
    force_opaque: bool = false,
};

/// Apply the complete chrome state of a freshly created window.
pub fn apply(hwnd: w32.HWND, config: *const Config, options: ApplyOptions) void {
    applyChromeTheme(hwnd, config.@"window-theme", config.background);

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window transparent.
    // Skip when force_opaque (parent window was toggled to opaque via
    // toggle_background_opacity — inherit that state for the new window).
    if (config.@"background-opacity" < 1.0 and !options.force_opaque) {
        setLayeredOpacity(hwnd, config.@"background-opacity");
    }
    if (config.@"background-blur".enabled()) {
        applyBackgroundBlur(hwnd, true);
    }
}

/// Follow a live configuration reload (background color in particular).
pub fn onConfigChange(hwnd: w32.HWND, config: *const Config) void {
    applyChromeTheme(hwnd, config.@"window-theme", config.background);
    applyBackgroundBlur(hwnd, config.@"background-blur".enabled());
}

/// Whether the window is currently translucent (`WS_EX_LAYERED`).
pub fn isTranslucent(hwnd: w32.HWND) bool {
    const ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
    return (ex & w32.WS_EX_LAYERED) != 0;
}

/// Toggle between fully opaque and the configured `background-opacity`.
pub fn toggleOpacity(hwnd: w32.HWND, opacity: f64) void {
    const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
    if (current_ex & w32.WS_EX_LAYERED != 0) {
        // Remove layered style (restore full opacity). Clearing
        // WS_EX_LAYERED is not repainted automatically — without an
        // explicit redraw the window stays translucent until the next
        // repaint (e.g. a later focus change).
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex & ~w32.WS_EX_LAYERED);
        _ = w32.RedrawWindow(
            hwnd,
            null,
            null,
            w32.RDW_ERASE | w32.RDW_INVALIDATE | w32.RDW_FRAME | w32.RDW_ALLCHILDREN,
        );
    } else {
        setLayeredOpacity(hwnd, opacity);
    }
}

fn setLayeredOpacity(hwnd: w32.HWND, opacity: f64) void {
    const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
    _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
    const alpha: u8 = @intFromFloat(@round(opacity * 255.0));
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
}

/// Read HKCU\...\Themes\Personalize\AppsUseLightTheme. Returns true when the
/// system apps theme is light. A missing/erroring value is treated as light,
/// which is how the Personalize key reads before it is ever written.
pub fn systemUsesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return true;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return true;
    if (kind != w32.REG_DWORD) return true;
    return val != 0; // 0 = dark, nonzero = light
}

/// Whether the chrome of a window is dark for `theme`: dark/light force
/// the mode, `system` reads the OS apps theme, and `auto`/`ghostty` fall
/// back to the terminal background luminance.
pub fn isDark(theme: Config.WindowTheme, bg: Config.Color) bool {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    return switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemUsesLightTheme(),
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => luminance < 0.5,
    };
}

/// Apply the DWM dark/light title bar, honoring `window-theme` (see
/// `isDark`). The caption is tinted to the terminal background only for
/// the luminance-derived themes; for the explicit dark/light/system themes
/// the caption is reset to the system default so the standard themed title
/// bar (and legible glyphs) is drawn.
pub fn applyChromeTheme(
    hwnd: w32.HWND,
    theme: Config.WindowTheme,
    bg: Config.Color,
) void {
    const dark_mode: u32 = if (isDark(theme, bg)) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const tint_caption = switch (theme) {
        .auto, .ghostty => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Enable/disable the DWM accent blur behind the window (background-blur).
/// Visible where the window is translucent (background-opacity < 1): the
/// desktop behind shows blurred instead of sharp, the acrylic-ish look.
pub fn applyBackgroundBlur(hwnd: w32.HWND, enabled: bool) void {
    var policy: w32.ACCENT_POLICY = .{
        .AccentState = if (enabled) w32.ACCENT_ENABLE_BLURBEHIND else w32.ACCENT_DISABLED,
        .AccentFlags = 0,
        .GradientColor = 0,
        .AnimationId = 0,
    };
    var data: w32.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = w32.WCA_ACCENT_POLICY,
        .pvData = @ptrCast(&policy),
        .cbData = @sizeOf(w32.ACCENT_POLICY),
    };
    _ = w32.SetWindowCompositionAttribute(hwnd, &data);
}
