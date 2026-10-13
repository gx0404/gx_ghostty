//! DWM chrome theming and window backdrop of a top-level terminal window:
//! the dark/light frame (`window-theme`, `background`), the border color,
//! the dark theme of common controls, the system backdrop material
//! (`gx-window-material`), translucency (`background-opacity`) and the
//! accent blur behind translucent windows (`background-blur`).
//!
//! Materials: `mica`, `acrylic` and `tabbed` set `DWMWA_SYSTEMBACKDROP_TYPE`
//! (Windows 11 22H2, build 22621, and later; older systems fall back to
//! `solid` and log it). `extendFrame` extends the frame over the title bar
//! row, which `TitleBar` draws with per-pixel alpha (the strip and inactive
//! tabs show the material; active tabs follow terminal opacity). DWM draws its caption
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
//! The 1px Windows 11 border (`setBorder`) follows the frame and the
//! activation, which `TitleBar` knows: the theme's hairline while the
//! window is active, the system's own inactive border while it is not,
//! none for borderless windows; with "Show accent color on title bars and
//! window borders" on, the system draws it in both states.
//!
//! The state lives on the HWND; the DWM attributes this module set are
//! remembered per window (`applied`), so a configuration change that keeps
//! them (a theme preview step) makes no DWM call. `Window` calls `apply`
//! once after creating its HWND (it forgets what was remembered for that
//! HWND), `onConfigChange` after every app-level configuration change,
//! `onSystemSettingChange` for the system broadcasts and `extendFrame`
//! whenever the height of its chrome changes; `App` uses `toggleOpacity`
//! for `toggle_background_opacity` in the fallback.
const std = @import("std");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const gx_config = @import("../../../gx/config_types.zig");
const renderer = @import("../../../renderer.zig");
const w32 = @import("../win32.zig");
const d2d = @import("../ui/d2d.zig");
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

/// Apply the complete chrome state of a freshly created window (the
/// active border; `TitleBar` sets the border of its frame afterwards).
pub fn apply(hwnd: w32.HWND, config: *const Config, options: ApplyOptions) void {
    // A new window: whatever was remembered for this HWND value belonged
    // to a destroyed one.
    forget(hwnd);

    // Apply dark theme to common controls (scrollbar, etc.). It sends
    // WM_THEMECHANGED, which forgets the remembered state: first.
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    applyTheme(hwnd, config);
    setBorder(hwnd, config, .active);
    applyMaterial(hwnd, config);

    if (perPixel(config, options.alpha_frames)) {
        setPerPixel(hwnd, true);
    } else if (config.@"background-opacity" < 1.0 and !options.force_opaque) {
        // Skip when force_opaque (parent window was toggled to opaque via
        // toggle_background_opacity — inherit that state for the new window).
        setLayeredOpacity(hwnd, config.@"background-opacity");
    }
    if (blurEnabled(config)) applyBackgroundBlur(hwnd, true);
}

/// Follow a live configuration reload: theme, material, per-pixel
/// translucency and blur. The border follows the frame, which `TitleBar`
/// sets after this (`TitleBar.onConfigChange`). Attributes that keep their
/// value are not set again.
pub fn onConfigChange(hwnd: w32.HWND, config: *const Config, alpha_frames: bool) void {
    applyTheme(hwnd, config);
    applyMaterial(hwnd, config);
    if (alpha_frames) setPerPixel(hwnd, perPixel(config, true));
    applyBackgroundBlur(hwnd, blurEnabled(config));
}

/// A system broadcast reached the top-level window `hwnd`
/// (`Window.onSystemSettingChange`), before `TitleBar` hears it. GUI
/// thread. The apps light or dark theme ("ImmersiveColorSet") changes the
/// dark or light frame of `window-theme = system` (`isDark`); it and the
/// colorization change whether borders show the accent (`setBorder`,
/// which `TitleBar.onSystemSettingChange` applies). A visual style change
/// forgets the remembered DWM state, so the next change sets everything.
/// Every top-level window hears each broadcast; the system settings are
/// read again each time, which is cheap.
pub fn onSystemSettingChange(hwnd: w32.HWND, config: *const Config, alpha_frames: bool, change: w32.SystemChange) void {
    switch (change) {
        .setting => if (change.isArea("ImmersiveColorSet")) {
            refreshSystemTheme();
            applyTheme(hwnd, config);
        },
        .colorization => refreshSystemTheme(),
        .theme => {
            const frame_top = appliedFor(hwnd).frame_top;
            forget(hwnd);
            refreshSystemTheme();
            onConfigChange(hwnd, config, alpha_frames);
            if (frame_top) |top| extendFrame(hwnd, config, top);
        },
        .sys_colors => {},
    }
}

// -----------------------------------------------------------------------
// Remembered DWM state
// -----------------------------------------------------------------------

/// The DWM attributes this module set on one window, null where unknown.
const Applied = struct {
    hwnd: ?w32.HWND = null,
    dark: ?u32 = null,
    caption: ?u32 = null,
    border: ?u32 = null,
    backdrop: ?u32 = null,
    per_pixel: ?bool = null,
    blur: ?bool = null,
    frame_top: ?i32 = null,
};

/// Windows whose state is remembered; more windows than this evict the
/// oldest, which then sets everything again next time. GUI thread.
var applied: [16]Applied = @splat(.{});
var applied_next: usize = 0;

/// The remembered state of `hwnd`, a fresh record when there is none.
fn appliedFor(hwnd: w32.HWND) *Applied {
    for (&applied) |*entry| {
        if (entry.hwnd == hwnd) return entry;
    }
    const slot = slot: {
        for (&applied) |*entry| {
            const other = entry.hwnd orelse break :slot entry;
            if (w32.IsWindow(other) == 0) break :slot entry;
        }
        const entry = &applied[applied_next];
        applied_next = (applied_next + 1) % applied.len;
        break :slot entry;
    };
    slot.* = .{ .hwnd = hwnd };
    return slot;
}

/// Forget what was set on `hwnd`: everything is set again next time.
fn forget(hwnd: w32.HWND) void {
    for (&applied) |*entry| {
        if (entry.hwnd == hwnd) entry.* = .{};
    }
}

/// Set the DWORD attribute `attr` of `hwnd` to `value` unless `field`
/// remembers it has that value already. Returns the failed HRESULT, null
/// when set or already set (an attribute the system lacks, such as the
/// border color on Windows 10, fails every time).
fn setDword(hwnd: w32.HWND, field: *?u32, attr: u32, value: u32) ?i32 {
    if (field.* == value) return null;
    const hr = w32.DwmSetWindowAttribute(hwnd, attr, @ptrCast(&value), @sizeOf(u32));
    field.* = if (hr < 0) null else value;
    return if (hr < 0) hr else null;
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
    const state = appliedFor(hwnd);
    if (state.per_pixel == enabled) return;
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
    state.per_pixel = if (hr < 0) null else enabled;
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

/// Stored BGRA of the terminal background, including linear-light channels
/// above alpha. Draw it with `Canvas.beginDib`'s coverage replacement.
pub fn backgroundPixel(config: *const Config) u32 {
    return premultiplied(config.background, config.@"background-opacity", config.@"alpha-blending".isLinear());
}

/// GDI writes no alpha (a `FillRect` in a window DWM composes per pixel
/// is fully transparent), so this blits a 32bpp DIB tile of the
/// premultiplied BGRA `pixel` over `rect`; the DC's clipping applies as
/// usual.
fn fillPixels(hdc: w32.HDC, rect: w32.RECT, pixel: u32) void {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width <= 0 or height <= 0) return;
    const mem_dc = FillCache.target.ensure(hdc, fill_tile, fill_tile) orelse return;
    if (FillCache.pixel != pixel) {
        _ = GdiFlush();
        const pixels: [*]u32 = @ptrCast(@alignCast(FillCache.target.bits orelse return));
        @memset(pixels[0..@intCast(fill_tile * fill_tile)], pixel);
        FillCache.pixel = pixel;
    }
    var y = rect.top;
    while (y < rect.bottom) : (y += fill_tile) {
        var x = rect.left;
        while (x < rect.right) : (x += fill_tile) {
            _ = w32.BitBlt(hdc, x, y, @min(fill_tile, rect.right - x), @min(fill_tile, rect.bottom - y), mem_dc, 0, 0, w32.SRCCOPY);
        }
    }
}

const FillCache = struct {
    var target: d2d.DibTarget = .{};
    var pixel: ?u32 = null;
};

pub fn releaseFillCache() void {
    FillCache.target.deinit();
    FillCache.pixel = null;
}

/// The sRGB `color` at `alpha` as a premultiplied BGRA pixel, the way the
/// OpenGL renderer writes it: the alpha quantized to 8 bits first, and
/// with `linear` the color multiplied in linear light, then encoded as
/// sRGB again.
fn premultiplied(color: Config.Color, opacity: f64, linear: bool) u32 {
    return @import("alpha.zig").backgroundPixel(.{ color.r, color.g, color.b }, opacity, linear);
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

/// Whether the title bar row is drawn transparent over a backdrop: a
/// material, except in high contrast, where DWM draws none.
pub fn chromeIsTranslucent(config: *const Config) bool {
    return material(config) != .solid and !style.system.highContrast();
}

/// Whether DWM supports system backdrop materials on this system.
pub fn supportsMaterials() bool {
    return windowsBuild() >= material_min_build;
}

/// The Windows build, read once (`queryBuild`).
var build_number: u32 = 0;

/// The Windows build number (RtlGetVersion, which unlike GetVersionEx is
/// not subject to manifest-based version lies), read once. Zero when
/// unknown.
pub fn windowsBuild() u32 {
    if (build_number == 0) build_number = queryBuild();
    return build_number;
}

fn queryBuild() u32 {
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
    if (setDword(hwnd, &appliedFor(hwnd).backdrop, DWMWA_SYSTEMBACKDROP_TYPE, value)) |hr| {
        log.warn("DWMWA_SYSTEMBACKDROP_TYPE={d} failed hr=0x{x}", .{ value, @as(u32, @bitCast(hr)) });
    }
}

/// Extend the DWM frame over the top `chrome_height` pixels of the client
/// area when the material shows through the chrome, and retract it
/// otherwise. Call it whenever the chrome height or the material changes.
pub fn extendFrame(hwnd: w32.HWND, config: *const Config, chrome_height: i32) void {
    const top: i32 = if (chromeIsTranslucent(config)) @max(chrome_height, 0) else 0;
    const state = appliedFor(hwnd);
    if (state.frame_top == top) return;
    const margins: w32.MARGINS = .{ .left = 0, .right = 0, .top = top, .bottom = 0 };
    state.frame_top = if (w32.DwmExtendFrameIntoClientArea(hwnd, &margins) < 0) null else top;
}

/// What the 1px Windows 11 window border shows (see the file header).
pub const Border = enum {
    /// Borderless windows.
    hidden,
    /// The theme's hairline between the background and the foreground,
    /// like the chrome separators.
    active,
    /// The system's inactive border, like every other inactive window.
    inactive,
};

/// Show `border` on the window (the frame and activation `TitleBar` knows).
pub fn setBorder(hwnd: w32.HWND, config: *const Config, border: Border) void {
    const value: u32 = switch (border) {
        .hidden => DWMWA_COLOR_NONE,
        .inactive => w32.DWMWA_COLOR_DEFAULT,
        .active => if (accentBorders())
            w32.DWMWA_COLOR_DEFAULT
        else
            d2d.colorRef(style.Tokens.fromConfig(config).window_border),
    };
    _ = setDword(hwnd, &appliedFor(hwnd).border, w32.DWMWA_BORDER_COLOR, value);
}

/// Remove the Windows 11 border (borderless windows) or restore the theme
/// border of an active window.
pub fn setBorderVisible(hwnd: w32.HWND, config: *const Config, visible: bool) void {
    setBorder(hwnd, config, if (visible) .active else .hidden);
}

// -----------------------------------------------------------------------
// System theme
// -----------------------------------------------------------------------

/// The system settings the frame follows, read on first use and again by
/// `refreshSystemTheme` (GUI thread).
const SystemTheme = struct {
    /// "Choose your app mode": light.
    apps_light: bool,
    /// "Show accent color on title bars and window borders".
    accent_borders: bool,
};

var system_theme: ?SystemTheme = null;

fn systemTheme() SystemTheme {
    if (system_theme) |theme| return theme;
    const theme: SystemTheme = .{
        .apps_light = systemUsesLightTheme(),
        .accent_borders = (readDword(
            std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\DWM"),
            std.unicode.utf8ToUtf16LeStringLiteral("ColorPrevalence"),
        ) orelse 0) != 0,
    };
    system_theme = theme;
    return theme;
}

/// Read the system settings of `SystemTheme` again on their next use.
fn refreshSystemTheme() void {
    system_theme = null;
}

/// Whether the system draws window borders in the accent color.
fn accentBorders() bool {
    return systemTheme().accent_borders;
}

/// A DWORD value of HKEY_CURRENT_USER, null when missing or not a DWORD.
fn readDword(subkey: [*:0]const u16, name: [*:0]const u16) ?u32 {
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var value: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, name, null, &kind, @ptrCast(&value), &size) != w32.ERROR_SUCCESS) return null;
    if (kind != w32.REG_DWORD) return null;
    return value;
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
    const value = readDword(
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme"),
    ) orelse return true;
    return value != 0; // 0 = dark, nonzero = light
}

/// Whether the chrome of a window is dark for `theme`: dark/light force
/// the mode, `system` follows the OS apps theme (read once, and again
/// after it changed), and `auto`/`ghostty` fall back to the terminal
/// background luminance. The window material follows it too.
pub fn isDark(theme: Config.WindowTheme, bg: Config.Color) bool {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    return switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemTheme().apps_light,
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => luminance < 0.5,
    };
}

/// Whether the window material of `config` is dark (`isDark`).
pub fn materialIsDark(config: *const Config) bool {
    return isDark(config.@"window-theme", config.background);
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
    const state = appliedFor(hwnd);
    const dark_mode: u32 = if (isDark(theme, bg)) 1 else 0;
    _ = setDword(hwnd, &state.dark, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, dark_mode);

    const tint_caption = tint and switch (theme) {
        .auto, .ghostty => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = setDword(hwnd, &state.caption, w32.DWMWA_CAPTION_COLOR, caption_color);
}

/// Enable/disable the DWM accent blur behind the window (background-blur).
/// Visible where the window is translucent (background-opacity < 1): the
/// desktop behind shows blurred instead of sharp, the acrylic-ish look.
pub fn applyBackgroundBlur(hwnd: w32.HWND, enabled: bool) void {
    const state = appliedFor(hwnd);
    if (state.blur == enabled) return;
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
    state.blur = if (w32.SetWindowCompositionAttribute(hwnd, &data) != 0) enabled else null;
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

test "ChromeAlpha light linear fill retains channels above alpha" {
    const pixel = premultiplied(.{ .r = 255, .g = 255, .b = 255 }, 0.3, true);
    try std.testing.expectEqual(@as(u32, 0x4d959595), pixel);
    try std.testing.expect((pixel & 255) > pixel >> 24);
}

test "ChromeAlpha native DIB replacement matches background tile bytes" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = d2d.Canvas.init(factory);
    defer canvas.deinit();
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    var tile: d2d.DibTarget = .{};
    defer tile.deinit();
    defer releaseFillCache();
    _ = target.ensure(null, 16, 16) orelse return error.CreateDibFailed;
    const tile_dc = tile.ensure(null, 16, 16) orelse return error.CreateDibFailed;
    const rect: w32.RECT = .{ .left = 0, .top = 0, .right = 16, .bottom = 16 };
    const backgrounds = [_]Config.Color{
        .{ .r = 31, .g = 31, .b = 40 },
        .{ .r = 240, .g = 248, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
    };
    for (backgrounds) |bg| {
        for ([_]f64{ 0, 0.01, 0.1, 0.3, 0.75, 1 }) |opacity| {
            for ([_]bool{ true, false }) |linear| {
                const pixel = premultiplied(bg, opacity, linear);
                fillPixels(tile_dc, rect, pixel);
                try testing.expect(canvas.beginDib(&target, .{ .width = 16, .height = 16 }, 96));
                canvas.clear(d2d.Color.white.withAlpha(0.3));
                try testing.expect(canvas.beginReplacement(pixel));
                canvas.fillRect(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, .white);
                canvas.endReplacement();
                try testing.expectEqual(d2d.EndResult.ok, canvas.finish());
                try testing.expect(GdiFlush() != 0);
                const painted: [*]const u32 = @ptrCast(@alignCast(target.bits.?));
                const tiled: [*]const u32 = @ptrCast(@alignCast(tile.bits.?));
                try testing.expectEqualSlices(u32, tiled[0..256], painted[0..256]);
            }
        }
    }
}

test "background tiles reuse their DC and bitmap across rectangles and colors" {
    const testing = std.testing;
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    defer releaseFillCache();
    const dc = target.ensure(null, 32, 32) orelse return error.CreateDibFailed;
    const rect: w32.RECT = .{ .left = 0, .top = 0, .right = 32, .bottom = 32 };
    fillPixels(dc, rect, 0xff112233);
    const cached_dc = FillCache.target.dc;
    const cached_bitmap = FillCache.target.bitmap;
    const output: [*]u32 = @ptrCast(@alignCast(target.bits.?));
    _ = GdiFlush();
    try testing.expectEqual(@as(u32, 0xff112233), output[31 * 32 + 31]);
    fillPixels(dc, .{ .left = 0, .top = 0, .right = 8, .bottom = 8 }, 0xff112233);
    try testing.expectEqual(cached_dc, FillCache.target.dc);
    try testing.expectEqual(cached_bitmap, FillCache.target.bitmap);
    fillPixels(dc, rect, 0xff445566);
    try testing.expectEqual(cached_bitmap, FillCache.target.bitmap);
    _ = GdiFlush();
    try testing.expectEqual(@as(u32, 0xff445566), output[0]);
    releaseFillCache();
    fillPixels(dc, rect, 0xff445566);
    _ = GdiFlush();
    try testing.expectEqual(@as(u32, 0xff445566), output[0]);
}

extern "gdi32" fn GdiFlush() callconv(.winapi) i32;
