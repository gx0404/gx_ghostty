//! DWM chrome theming and window backdrop of a top-level terminal window:
//! the dark/light frame (`window-theme`, `background`), the border color,
//! the dark theme of common controls, the system backdrop material
//! (`gx-window-material`), translucency (`background-opacity` through
//! `WS_EX_LAYERED`) and the accent blur behind translucent windows
//! (`background-blur`).
//!
//! Materials: `mica`, `acrylic` and `tabbed` set `DWMWA_SYSTEMBACKDROP_TYPE`
//! (Windows 11 22H2, build 22621, and later; older systems fall back to
//! `solid` and log it). DWM only shows a backdrop through client pixels
//! whose alpha is below one inside the frame extended into the client
//! area, so `extendFrame` extends the frame over the title bar row, which
//! `TitleBar` draws with per-pixel alpha (transparent strip and inactive
//! tabs, opaque active tab). DWM then draws its own caption buttons in that
//! row, so the title bar uses them instead of its custom-drawn ones
//! (`TitleBar.nativeButtons`).
//!
//! The material shows in the chrome only. The terminals are WGL child
//! windows and DWM composes their pixels opaque even inside an extended
//! frame (with the whole client area extended and `background-opacity =
//! 0.3`, the terminal still covered the backdrop on Windows 11 build
//! 26300), so the terminal area keeps its solid background.
//! `background-opacity` below one makes the whole window, chrome included,
//! uniformly translucent with `WS_EX_LAYERED`; DWM keeps drawing the
//! material under it. `background-blur` (the accent blur behind a
//! translucent window) only applies to the solid material.
//!
//! Stateless: everything lives on the HWND. `Window` calls `apply` once
//! after creating its HWND, `onConfigChange` after every app-level
//! configuration change and `extendFrame` whenever the height of its chrome
//! changes; `App` uses `toggleOpacity` for `toggle_background_opacity`.
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const gx_config = @import("../../../gx/config_types.zig");
const w32 = @import("../win32.zig");
const style = @import("../ui/style.zig");

const log = std.log.scoped(.win32_backdrop);

pub const Material = gx_config.WindowMaterial;

/// First Windows build with `DWMWA_SYSTEMBACKDROP_TYPE` (Windows 11 22H2).
pub const material_min_build: u32 = 22621;

const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;
/// `DWMWA_BORDER_COLOR` value that removes the border (Windows 11).
const DWMWA_COLOR_NONE: u32 = 0xFFFFFFFE;

/// DWM_SYSTEMBACKDROP_TYPE values.
const DWMSBT_NONE: u32 = 1;
const DWMSBT_MAINWINDOW: u32 = 2;
const DWMSBT_TRANSIENTWINDOW: u32 = 3;
const DWMSBT_TABBEDWINDOW: u32 = 4;

pub const ApplyOptions = struct {
    /// Start fully opaque regardless of `background-opacity` (a new window
    /// inheriting a parent that was toggled opaque).
    force_opaque: bool = false,
};

/// Apply the complete chrome state of a freshly created window.
pub fn apply(hwnd: w32.HWND, config: *const Config, options: ApplyOptions) void {
    applyTheme(hwnd, config);
    applyBorderColor(hwnd, config);
    applyMaterial(hwnd, config);

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
    if (blurEnabled(config)) applyBackgroundBlur(hwnd, true);
}

/// Follow a live configuration reload: theme, border, material and blur.
pub fn onConfigChange(hwnd: w32.HWND, config: *const Config) void {
    applyTheme(hwnd, config);
    applyBorderColor(hwnd, config);
    applyMaterial(hwnd, config);
    applyBackgroundBlur(hwnd, blurEnabled(config));
}

/// The accent blur only applies to the solid material: the system
/// backdrops are blurred (or tinted) already and would fight with it.
fn blurEnabled(config: *const Config) bool {
    return config.@"background-blur".enabled() and material(config) == .solid;
}

/// The material the window actually uses: `gx-window-material`, or
/// `solid` when the system has no backdrop support.
pub fn material(config: *const Config) Material {
    const wanted = config.@"gx-window-material";
    if (wanted == .solid or !supportsMaterials()) return .solid;
    return wanted;
}

/// Whether the title bar row is drawn transparent over a backdrop.
pub fn chromeIsTranslucent(config: *const Config) bool {
    return material(config) != .solid;
}

/// Whether DWM supports system backdrop materials on this system.
pub fn supportsMaterials() bool {
    return windowsBuild() >= material_min_build;
}

/// The Windows build number (RtlGetVersion, which unlike GetVersionEx is
/// not subject to manifest-based version lies). Zero when unknown.
pub fn windowsBuild() u32 {
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    if (std.os.windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return 0;
    return info.dwBuildNumber;
}

fn applyMaterial(hwnd: w32.HWND, config: *const Config) void {
    // Without system backdrop support the attribute does not exist; there
    // is nothing to reset either.
    if (!supportsMaterials()) {
        const wanted = config.@"gx-window-material";
        if (wanted != .solid) log.info(
            "gx-window-material={t} needs Windows 11 22H2 (build {d}) or later; this is build {d}, using solid",
            .{ wanted, material_min_build, windowsBuild() },
        );
        return;
    }
    const value: u32 = switch (material(config)) {
        .solid => DWMSBT_NONE,
        .mica => DWMSBT_MAINWINDOW,
        .acrylic => DWMSBT_TRANSIENTWINDOW,
        .tabbed => DWMSBT_TABBEDWINDOW,
    };
    const hr = w32.DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, @ptrCast(&value), @sizeOf(u32));
    if (hr < 0) log.warn("DWMWA_SYSTEMBACKDROP_TYPE={d} failed hr=0x{x}", .{ value, @as(u32, @bitCast(hr)) });
}

/// Extend the DWM frame over the top `chrome_height` pixels of the client
/// area when the material shows through the chrome, and retract it
/// otherwise. Call it whenever the chrome height or the material changes.
pub fn extendFrame(hwnd: w32.HWND, config: *const Config, chrome_height: i32) void {
    const top: i32 = if (chromeIsTranslucent(config)) @max(chrome_height, 0) else 0;
    const margins: w32.MARGINS = .{ .left = 0, .right = 0, .top = top, .bottom = 0 };
    _ = w32.DwmExtendFrameIntoClientArea(hwnd, &margins);
}

/// The 1px Windows 11 window border follows the theme: a hairline between
/// the background and the foreground, like the chrome separators.
fn applyBorderColor(hwnd: w32.HWND, config: *const Config) void {
    const tokens = style.Tokens.fromConfig(config);
    const ref: u32 = tokens.window_border.colorRef();
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_BORDER_COLOR, @ptrCast(&ref), @sizeOf(u32));
}

/// Remove the Windows 11 border (borderless windows) or restore the theme
/// border.
pub fn setBorderVisible(hwnd: w32.HWND, config: *const Config, visible: bool) void {
    if (visible) return applyBorderColor(hwnd, config);
    const none: u32 = DWMWA_COLOR_NONE;
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_BORDER_COLOR, @ptrCast(&none), @sizeOf(u32));
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

/// The DWM theme of the window (see `applyChromeTheme`). A material fills
/// the caption itself, so the caption is never tinted then.
fn applyTheme(hwnd: w32.HWND, config: *const Config) void {
    applyChromeTheme(hwnd, config.@"window-theme", config.background, material(config) == .solid);
}

/// Apply the DWM dark/light frame, honoring `window-theme` (see `isDark`):
/// it picks the dark or light variant of the shadow, the border and the
/// system backdrop, and of the system caption of native title bars. With
/// `tint` that caption is tinted to the terminal background, but only for
/// the luminance-derived themes; for the explicit dark/light/system themes
/// it is reset to the system default so the standard themed title bar (and
/// legible glyphs) is drawn.
pub fn applyChromeTheme(
    hwnd: w32.HWND,
    theme: Config.WindowTheme,
    bg: Config.Color,
    tint: bool,
) void {
    const dark_mode: u32 = if (isDark(theme, bg)) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const tint_caption = tint and switch (theme) {
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
