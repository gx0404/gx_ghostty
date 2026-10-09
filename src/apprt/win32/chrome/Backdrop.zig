//! DWM chrome theming and window backdrop of a top-level terminal window:
//! the dark/light frame (`window-theme`, `background`), the border color,
//! the dark theme of common controls, the system backdrop material
//! (`gx-window-material`), translucency (`background-opacity`) and the
//! accent blur behind translucent windows (`background-blur`).
//!
//! Materials: `mica`, `acrylic` and `tabbed` set `DWMWA_SYSTEMBACKDROP_TYPE`
//! (Windows 11 22H2, build 22621, and later; older systems fall back to
//! `solid` and log it). `extendFrame` extends the frame over the title bar
//! row, which `TitleBar` draws with per-pixel alpha (transparent strip and
//! inactive tabs, opaque active tab). DWM then draws its own caption
//! buttons in that row, so the title bar uses them instead of its
//! custom-drawn ones (`TitleBar.nativeButtons`).
//!
//! Per-pixel translucency (`perPixel`): when the terminals present frames
//! with an alpha channel DWM can use (`alphaFramesSupported`: build 22621
//! or later and the system OpenGL driver with an alpha pixel format) and
//! the window has a material or a `background-opacity` below one, the
//! window enables DWM blur-behind with an empty region
//! (`DwmEnableBlurBehindWindow`), which blurs nothing but makes DWM compose
//! the whole client area, the WGL child windows included, with the alpha
//! of its pixels. The renderers write premultiplied alpha: the terminal
//! background has `background-opacity`, glyphs, cursor, selection and
//! images stay opaque, and the material or the desktop shows through the
//! background only. GDI writes no alpha, so everything the window paints
//! itself goes through premultiplied 32bpp DIBs (`fillBackground`,
//! `fillOpaque`, the title bar). Without a material the desktop shows
//! through, blurred with `background-blur`.
//!
//! Fallback (Windows 10 and builds before 22621, the Mesa software
//! renderer, a pixel format without alpha): the material shows in the
//! chrome only and `background-opacity` below one makes the whole window,
//! chrome and text included, uniformly translucent with `WS_EX_LAYERED`.
//!
//! Stateless: everything lives on the HWND. `Window` calls `apply` once
//! after creating its HWND, `onConfigChange` after every app-level
//! configuration change and `extendFrame` whenever the height of its chrome
//! changes; `App` uses `toggleOpacity` for `toggle_background_opacity` in
//! the fallback.
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const gx_config = @import("../../../gx/config_types.zig");
const renderer = @import("../../../renderer.zig");
const w32 = @import("../win32.zig");
const style = @import("../ui/style.zig");

const log = std.log.scoped(.win32_backdrop);

pub const Material = gx_config.WindowMaterial;

/// First Windows build with `DWMWA_SYSTEMBACKDROP_TYPE` (Windows 11 22H2).
pub const material_min_build: u32 = 22621;

/// Side length in pixels of the DIB tile `fillPixels` blits.
const fill_tile: i32 = 256;

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
    /// inheriting a parent that was toggled opaque). Fallback only.
    force_opaque: bool = false,
    /// Whether the terminals' frames carry alpha DWM can compose
    /// (`alphaFramesSupported`).
    alpha_frames: bool = false,
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

    if (perPixel(config, options.alpha_frames)) {
        setPerPixel(hwnd, true);
    } else if (config.@"background-opacity" < 1.0 and !options.force_opaque) {
        // Skip when force_opaque (parent window was toggled to opaque via
        // toggle_background_opacity — inherit that state for the new window).
        setLayeredOpacity(hwnd, config.@"background-opacity");
    }
    if (blurEnabled(config)) applyBackgroundBlur(hwnd, true);
}

/// Follow a live configuration reload: theme, border, material, per-pixel
/// translucency and blur.
pub fn onConfigChange(hwnd: w32.HWND, config: *const Config, alpha_frames: bool) void {
    applyTheme(hwnd, config);
    applyBorderColor(hwnd, config);
    applyMaterial(hwnd, config);
    if (alpha_frames) setPerPixel(hwnd, perPixel(config, true));
    applyBackgroundBlur(hwnd, blurEnabled(config));
}

/// Whether the terminals of this process present frames whose alpha DWM
/// can compose: Windows 11 22H2 or later (the same builds as the
/// materials) and an OpenGL device with alpha frames. Logs why not.
pub fn alphaFramesSupported(device: *const renderer.Device) bool {
    if (!supportsMaterials()) {
        log.info("per-pixel translucency needs Windows build {d} or later; this is build {d}, " ++
            "background-opacity makes whole windows translucent", .{ material_min_build, windowsBuild() });
        return false;
    }
    switch (device.alphaFrames()) {
        .supported => return true,
        .software => log.info("software OpenGL: the window material shows in the title bar only and " ++
            "background-opacity makes whole windows translucent", .{}),
        .no_alpha_channel => log.info("the OpenGL pixel format has no alpha channel: the window material " ++
            "shows in the title bar only and background-opacity makes whole windows translucent", .{}),
    }
    return false;
}

/// Whether DWM composes the window per pixel: the terminals' frames
/// carry alpha (`alpha_frames`) and the window shows something through
/// them, a material or a `background-opacity` below one.
pub fn perPixel(config: *const Config, alpha_frames: bool) bool {
    if (!alpha_frames) return false;
    return material(config) != .solid or config.@"background-opacity" < 1.0;
}

/// Turn per-pixel composition of the window on or off. An empty blur
/// region blurs nothing (Windows 8 and later no longer blur behind
/// windows anyway) but makes DWM use the alpha channel of the window.
fn setPerPixel(hwnd: w32.HWND, enabled: bool) void {
    const region = if (enabled) w32.CreateRectRgn(0, 0, -1, -1) else null;
    defer if (region) |r| {
        _ = w32.DeleteObject(r);
    };
    const blur: w32.DWM_BLURBEHIND = .{
        .dwFlags = w32.DWM_BB_ENABLE | (if (region != null) w32.DWM_BB_BLURREGION else 0),
        .fEnable = @intFromBool(enabled),
        .hRgnBlur = region,
    };
    const hr = w32.DwmEnableBlurBehindWindow(hwnd, &blur);
    if (hr < 0) log.warn("DwmEnableBlurBehindWindow enable={} failed hr=0x{x}", .{ enabled, @as(u32, @bitCast(hr)) });
}

/// Fill `rect` of the window DC `hdc` of a window DWM composes per pixel
/// with the terminal background as the renderers draw it: `background` at
/// `background-opacity`, premultiplied in linear light unless
/// `alpha-blending` is `native`, so it matches the panes.
pub fn fillBackground(hdc: w32.HDC, rect: w32.RECT, config: *const Config) void {
    fillPixels(hdc, rect, premultiplied(
        config.background,
        config.@"background-opacity",
        config.@"alpha-blending".isLinear(),
    ));
}

/// Fill `rect` of the window DC `hdc` of a window DWM composes per pixel
/// with the opaque `color`.
pub fn fillOpaque(hdc: w32.HDC, rect: w32.RECT, color: Config.Color) void {
    fillPixels(hdc, rect, premultiplied(color, 1, false));
}

/// GDI writes no alpha (a `FillRect` in a window DWM composes per pixel
/// is fully transparent), so this blits a 32bpp DIB tile of the
/// premultiplied BGRA `pixel` over `rect`; the DC's clipping applies as
/// usual.
fn fillPixels(hdc: w32.HDC, rect: w32.RECT, pixel: u32) void {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width <= 0 or height <= 0) return;
    const tile_w = @min(width, fill_tile);
    const tile_h = @min(height, fill_tile);

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    var bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = tile_w, .biHeight = -tile_h } };
    var bits: ?*anyopaque = null;
    const dib = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = w32.DeleteObject(dib);
    const old_bmp = w32.SelectObject(mem_dc, dib);
    defer _ = w32.SelectObject(mem_dc, old_bmp);

    const pixels: [*]u32 = @ptrCast(@alignCast(bits orelse return));
    @memset(pixels[0..@intCast(tile_w * tile_h)], pixel);
    var y = rect.top;
    while (y < rect.bottom) : (y += tile_h) {
        var x = rect.left;
        while (x < rect.right) : (x += tile_w) {
            _ = w32.BitBlt(hdc, x, y, @min(tile_w, rect.right - x), @min(tile_h, rect.bottom - y), mem_dc, 0, 0, w32.SRCCOPY);
        }
    }
}

/// The sRGB `color` at `alpha` as a premultiplied BGRA pixel, the way the
/// OpenGL renderer writes it: the alpha quantized to 8 bits first, and
/// with `linear` the color multiplied in linear light, then encoded as
/// sRGB again.
fn premultiplied(color: Config.Color, alpha: f64, linear: bool) u32 {
    const a8: u32 = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
    const a = @as(f64, @floatFromInt(a8)) / 255;
    const Channel = struct {
        a: f64,
        linear: bool,

        fn f(self: @This(), value: u8) u32 {
            const c = @as(f64, @floatFromInt(value)) / 255;
            const p = if (self.linear) linearToSrgb(srgbToLinear(c) * self.a) else c * self.a;
            return @intFromFloat(@round(p * 255));
        }
    };
    const ch: Channel = .{ .a = a, .linear = linear };
    return (a8 << 24) | (ch.f(color.r) << 16) | (ch.f(color.g) << 8) | ch.f(color.b);
}

fn srgbToLinear(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f64) f64 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
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

/// Whether the window is currently translucent (`WS_EX_LAYERED`, the
/// fallback).
pub fn isTranslucent(hwnd: w32.HWND) bool {
    const ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
    return (ex & w32.WS_EX_LAYERED) != 0;
}

/// Toggle between fully opaque and the configured `background-opacity`
/// with `WS_EX_LAYERED` (the fallback; see `App.toggleBackgroundOpaque`
/// for per-pixel translucency).
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

test premultiplied {
    const testing = std.testing;
    const color: Config.Color = .{ .r = 0x20, .g = 0x40, .b = 0xff };
    try testing.expectEqual(@as(u32, 0xff2040ff), premultiplied(color, 1, false));
    try testing.expectEqual(@as(u32, 0xff2040ff), premultiplied(color, 1, true));
    try testing.expectEqual(@as(u32, 0x80102080), premultiplied(color, 0.5, false));
    try testing.expectEqual(@as(u32, 0x80152dbc), premultiplied(color, 0.5, true));
    try testing.expectEqual(@as(u32, 0), premultiplied(color, 0, true));
    try testing.expectEqual(@as(u32, 0xff2040ff), premultiplied(color, 3, false));
    // GX Mocha at 0.8 in linear light, as the renderer writes it.
    try testing.expectEqual(@as(u32, 0xcc1b1b23), premultiplied(.{ .r = 0x1f, .g = 0x1f, .b = 0x28 }, 0.8, true));
}
