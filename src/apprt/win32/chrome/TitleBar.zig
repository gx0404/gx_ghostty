//! Title bar and non-client frame of a top-level terminal window.
//!
//! With `window-decoration = auto` or `client` the window keeps its native
//! frame (resize borders, shadow, Snap, the system menu) but extends the
//! client area over the caption in `WM_NCCALCSIZE`: the top row of the
//! client area is the integrated title bar. It holds the tabs
//! (`chrome/TabBar.zig`), the main menu button and custom-drawn caption
//! buttons. `WM_NCHITTEST` reports the empty parts of the row as
//! `HTCAPTION` (drag, double-click maximize, right-click system menu), the
//! top edge as `HTTOP`, the caption buttons as `HTMINBUTTON`,
//! `HTMAXBUTTON` (Windows 11 shows the Snap Layouts flyout over it) and
//! `HTCLOSE`, and the tabs and buttons as `HTCLIENT`; the geometry is the
//! pure `chrome/caption_layout.zig`. A maximized window takes hits on the
//! tabs and the main menu button up to the screen edge (`Layout.hit_top`).
//! The caption buttons are handled through the non-client mouse messages
//! so DefWindowProc never draws its classic buttons over the row: they
//! show their own tooltips, look pressed only while the pressed button is
//! under the pointer, and fade out of their hover look. With a window
//! material the DWM frame extends under the row and DWM draws its own
//! caption buttons there; the title bar then leaves the caption buttons to
//! DWM (`nativeButtons`, `DwmDefWindowProc`) instead of drawing over them.
//!
//! `server` keeps the system caption and puts a tab row below it, `none`
//! drops the caption row (borderless), fullscreen windows show a plain tab
//! row and quick terminals no chrome at all. `toggleDecorations` switches
//! between the configured frame and borderless at runtime. Without
//! Direct2D nothing of the row can be drawn: windows then keep the system
//! caption and no chrome row.
//!
//! `paint` draws the chrome row with Direct2D into a 32bpp DIB kept between
//! paints (`d2d.DibTarget`), with per-pixel alpha, and blits the part the
//! paint covers (a hover change repaints one button): opaque with the
//! solid material, transparent where the DWM backdrop shows through
//! otherwise (`chrome/Backdrop.zig`, `paintColors`). The title bar also
//! owns the chrome tooltip (`ui/Tooltip.zig`), shared with the tab bar, and
//! opens the window menu and the main menu (`ui/Menu.zig`). The owning
//! `Window` embeds this struct as `title_bar`.
//!
//! Activation: popups that keep the window painted as active while they
//! have the focus (`Popup.Options.keep_owner_active`) lock it
//! (`Popup.WM_GX_OWNER_ACTIVE_LOCK`): while a lock is held,
//! `WM_NCACTIVATE(FALSE)` leaves the glyphs, the tabs and DWM's frame
//! active. When the last lock goes, the window checks once the activation
//! settled (`WM_APP_SYNC_ACTIVATION`) whether it is really active. The
//! window border follows the activation (`Backdrop.setBorder`).
//!
//! Sizes, fonts, icons, hit-test rectangles, the canvas DPI and the
//! tooltip follow the window's content scale (`Window.scale`), like the
//! terminals. Only what Windows and DWM draw themselves keeps the real DPI
//! of the window: the resize border (`resizeBandHeight`) and DWM's caption
//! buttons (`nativeButtonBounds`).
const TitleBar = @This();

const std = @import("std");
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const i18n = @import("../../../gx/i18n.zig");
const perf = @import("../../../gx/perf.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const anim = @import("../ui/anim.zig");
const d2d = @import("../ui/d2d.zig");
const style = @import("../ui/style.zig");
const Menu = @import("../ui/Menu.zig");
const Popup = @import("../ui/Popup.zig");
const tooltips = @import("../ui/Tooltip.zig");
const Backdrop = @import("Backdrop.zig");
const caption_layout = @import("caption_layout.zig");

const log = std.log.scoped(.win32_titlebar);

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Window style and placement saved when entering fullscreen.
saved_style: u32 = 0,
saved_placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT),

/// The frame configured by `window-decoration`.
decoration: Decoration = .custom,

/// `toggle_window_decorations` hid the decorations (borderless).
decorations_hidden: bool = false,

/// Whether the window is painted as active: it is, or a popup holds it
/// active (`ownerActiveLocked`). The chrome glyphs dim when it is not.
active: bool = true,

/// The title bar button under the mouse and the one being pressed.
hover: Button = .none,
pressed: Button = .none,

/// Whether WM_NCMOUSELEAVE tracking is active.
tracking_nc: bool = false,

/// The Direct2D canvas the chrome row is painted with (created on first
/// paint), and the DIB it paints into.
canvas: ?d2d.Canvas = null,
dib: d2d.DibTarget = .{},

/// The layout of the last paint: a resize that keeps it repaints nothing.
painted_layout: Layout = .{},

/// The tooltip of the chrome buttons and tabs (its delay timer `TT` runs
/// on the window).
tooltip: Tooltip = .{},

/// The popups that hold the window active (`onOwnerActiveLock`).
active_locks: ActiveLocks = .{},

/// A `WM_APP_SYNC_ACTIVATION` is posted and not handled yet.
activation_sync_pending: bool = false,

/// Whether high contrast was on when the frame was last set up.
high_contrast: bool = false,

/// Caption buttons fading out of their hover look.
fades: Fades = .{},

/// Where DWM draws its caption buttons (`nativeButtonBounds`), queried
/// again after the window size, DPI or frame changed.
native_bounds: ?w32.RECT = null,
native_bounds_known: bool = false,
native_buttons_enabled: bool = false,
direct2d_failed: bool = false,

pub const Tooltip = tooltips.Tooltip(TooltipTarget);

pub const Frame = caption_layout.Frame;
pub const Button = caption_layout.Button;
pub const Layout = caption_layout.Layout;
pub const Hit = caption_layout.Hit;
pub const empty_rect = caption_layout.empty_rect;
pub const contains = caption_layout.contains;

/// Height of the row buttons (main menu, new tab) in DIPs.
pub const row_button_height = caption_layout.row_button_height;

comptime {
    if (caption_layout.caption_button_width != style.metrics.caption_button_width or
        caption_layout.title_bar_height != style.metrics.title_bar_height)
    {
        @compileError("caption_layout and style.metrics disagree on the title bar sizes");
    }
}

/// Posted after the last activation lock is released.
pub const WM_APP_SYNC_ACTIVATION: u32 = w32.WM_APP + 42;
pub const WM_APP_NATIVE_FALLBACK: u32 = w32.WM_APP + 43;
pub const WM_GHOSTTY_SIMULATE_D2D_FAILURE: u32 = w32.WM_USER + 0x4C;
pub const WM_GHOSTTY_CAPTION_QUERY: u32 = w32.WM_USER + 0x4D;

pub const Decoration = enum {
    /// The integrated title bar (`window-decoration = auto|client`).
    custom,
    /// The system caption with a tab row below it (`server`).
    native,
    /// No caption row (`none`).
    borderless,

    pub fn fromConfig(value: configpkg.Config.WindowDecoration) Decoration {
        return switch (value) {
            .auto, .client => .custom,
            .server => .native,
            .none => .borderless,
        };
    }
};

fn buttonFromHitCode(code: usize) Button {
    return switch (code) {
        HTMINBUTTON => .minimize,
        HTMAXBUTTON => .maximize,
        HTCLOSE => .close,
        else => .none,
    };
}

pub const Style = struct {
    style: u32,
    ex_style: u32,
};

/// The Win32 styles for a new top-level window. Every decoration keeps
/// the overlapped frame (Snap, the system menu, minimize animations);
/// `WM_NCCALCSIZE` removes the caption where the configuration asks for
/// it.
pub fn windowStyle(config: *const configpkg.Config, is_quick_terminal: bool) Style {
    _ = config;
    if (is_quick_terminal) return .{ .style = w32.WS_POPUP, .ex_style = w32.WS_EX_TOOLWINDOW };
    return .{ .style = w32.WS_OVERLAPPEDWINDOW | w32.WS_CLIPCHILDREN, .ex_style = 0 };
}

fn window(self: *TitleBar) *Window {
    return @alignCast(@fieldParentPtr("title_bar", self));
}

fn windowConst(self: *const TitleBar) *const Window {
    return @alignCast(@fieldParentPtr("title_bar", self));
}

/// Release the canvas, the DIB and the tooltip, and stop the fades.
pub fn deinit(self: *TitleBar) void {
    self.fades.stop();
    self.tooltip.destroy();
    if (self.canvas) |*canvas| canvas.deinit();
    self.canvas = null;
    self.dib.deinit();
    Backdrop.releaseFillCache();
}

/// What frames the client area right now.
pub fn frame(self: *const TitleBar) Frame {
    const win = self.windowConst();
    if (win.is_quick_terminal) return .popup;
    if (self.is_fullscreen) return .fullscreen;
    if (self.decorations_hidden) return .borderless;
    return switch (self.decoration) {
        // The integrated title bar needs Direct2D; the system caption
        // does not.
        .custom => if (self.direct2d_failed) .native else .custom,
        .native => .native,
        .borderless => .borderless,
    };
}

/// Whether `WM_NCCALCSIZE` extends the client area over the caption.
pub fn extendsClient(self: *const TitleBar) bool {
    return self.frame().extendsClient();
}

/// Whether the chrome row has caption buttons.
pub fn hasCaptionRow(self: *const TitleBar) bool {
    return self.frame() == .custom;
}

/// Height in pixels of the chrome row at the top of the client area: the
/// integrated title bar, a tab row, or 0 (also without Direct2D, which
/// draws the row).
pub fn height(self: *const TitleBar) i32 {
    if (self.direct2d_failed) return 0;
    const win = self.windowConst();
    const tabs = win.tab_bar.visible;
    const length: f32 = switch (self.frame()) {
        .custom => style.metrics.title_bar_height,
        // The tab row of a borderless window is its title bar.
        .borderless => if (tabs) style.metrics.title_bar_height else 0,
        .native, .fullscreen => if (tabs) style.metrics.tab_bar_height else 0,
        .popup => 0,
    };
    return style.px(length, win.scale);
}

/// Whether DWM extends its frame under the chrome row, so the window
/// material shows through it (`Window.applyFrameMargins`): with a material
/// (not in high contrast) on a frame with a caption above or in the row.
/// A borderless window keeps its frame to itself, as DWM would draw
/// caption buttons nobody can press in it; its row shows the material
/// where DWM composes the window per pixel (`paintColors`). Fullscreen
/// windows have no frame.
pub fn translucent(self: *const TitleBar) bool {
    return switch (self.frame()) {
        .custom, .native => Backdrop.chromeIsTranslucent(&self.windowConst().app.config),
        .borderless, .fullscreen, .popup => false,
    };
}

/// Whether DWM draws the caption buttons. Wherever the frame is extended
/// under the title bar (a material shows through it) DWM draws its own
/// caption buttons there, and they cannot be hidden without dropping
/// `WS_SYSMENU`, which Snap (Win+Arrow) needs. The title bar then uses
/// those native buttons (`DwmDefWindowProc`) instead of drawing its own
/// over them.
pub fn nativeButtons(self: *const TitleBar) bool {
    return self.hasCaptionRow() and self.native_buttons_enabled;
}

/// The cached DWM button bounds at the real window DPI. GUI thread only.
fn nativeButtonBounds(self: *const TitleBar) ?w32.RECT {
    @constCast(self).refreshNativeBounds();
    return self.native_bounds;
}

fn refreshNativeBounds(self: *TitleBar) void {
    if (self.native_bounds_known or !self.nativeButtons()) return;
    self.native_bounds = self.queryNativeBounds();
    self.native_bounds_known = true;
}

fn forgetNativeBounds(self: *TitleBar) void {
    self.native_bounds_known = false;
    self.native_buttons_enabled = Backdrop.chromeIsTranslucent(&self.windowConst().app.config);
}

fn queryNativeBounds(self: *const TitleBar) ?w32.RECT {
    const hwnd = self.windowConst().hwnd orelse return null;
    var bounds: w32.RECT = undefined;
    if (DwmGetWindowAttribute(hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, &bounds, @sizeOf(w32.RECT)) < 0) return null;
    if (bounds.right <= bounds.left) return null;
    var visible_frame: w32.RECT = undefined;
    if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &visible_frame, @sizeOf(w32.RECT)) < 0 and
        w32.GetWindowRect(hwnd, &visible_frame) == 0) return null;
    var origin = w32.POINT{ .x = 0, .y = 0 };
    if (w32.ClientToScreen(hwnd, &origin) == 0) return null;
    return caption_layout.toClientBounds(bounds, visible_frame, origin.x, origin.y);
}

fn isZoomed(self: *const TitleBar) bool {
    const hwnd = self.windowConst().hwnd orelse return false;
    return w32.IsZoomed(hwnd) != 0;
}

/// The chrome row layout for the current client size
/// (`caption_layout.compute`).
pub fn layout(self: *const TitleBar) Layout {
    const win = self.windowConst();
    const hwnd = win.hwnd orelse return .{};
    const bar_h = self.height();
    if (bar_h <= 0) return .{ .scale = win.scale };
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return .{ .scale = win.scale };
    const f = self.frame();
    return caption_layout.compute(.{
        .width = client.right,
        .bar_height = bar_h,
        .frame = f,
        .zoomed = self.isZoomed(),
        .scale = win.scale,
        .resize_band = if (f.extendsClient()) self.resizeBandHeight() else 0,
        .buttons = if (self.nativeButtons()) .{ .dwm = self.nativeButtonBounds() } else .own,
    });
}

/// The top resize band: the invisible resize border the system uses on
/// the other edges. Windows sizes those borders for the real DPI of the
/// window, so the band does too.
fn resizeBandHeight(self: *const TitleBar) i32 {
    const window_dpi = self.systemDpi();
    return GetSystemMetricsForDpi(SM_CXPADDEDBORDER, window_dpi) + GetSystemMetricsForDpi(SM_CYSIZEFRAME, window_dpi);
}

/// The real DPI of the window (`GetDpiForWindow`), only for what Windows
/// and DWM draw and hit-test themselves. Everything the title bar draws
/// follows `Window.scale` (`canvasDpi`), which differs from it under
/// `Window.WM_GHOSTTY_SIMULATE_DPI`.
fn systemDpi(self: *const TitleBar) u32 {
    const hwnd = self.windowConst().hwnd orelse return 96;
    const value = w32.GetDpiForWindow(hwnd);
    return if (value == 0) 96 else value;
}

/// The DPI the chrome row is drawn at: `Window.scale`, the scale its
/// layout and the terminals use.
fn canvasDpi(self: *const TitleBar) u32 {
    return @intFromFloat(@round(self.windowConst().scale * 96.0));
}

/// What a client point in the chrome row hits.
pub fn hitTest(self: *const TitleBar, lay: Layout, x: i32, y: i32) Hit {
    return caption_layout.hit(lay, x, y, self.tabsAt(lay, x, y));
}

/// Whether the tab bar has a tab or a button at client point (`x`, `y`),
/// moved onto the tabs where the row takes hits above them
/// (`Layout.tabY`).
fn tabsAt(self: *const TitleBar, lay: Layout, x: i32, y: i32) bool {
    if (lay.height() <= 0) return false;
    return self.windowConst().tab_bar.hitsSomething(lay, x, lay.tabY(y));
}

/// Non-client hook, called first by the window procedure for every
/// message. Returns the message result when the title bar handled the
/// message, or null for the default handling.
pub fn handleMessage(
    self: *TitleBar,
    msg: u32,
    wparam: usize,
    lparam: isize,
) ?isize {
    const hwnd = self.window().hwnd orelse return null;

    switch (msg) {
        WM_NCACTIVATE => return self.onNcActivate(hwnd, wparam, lparam),
        Popup.WM_GX_OWNER_ACTIVE_LOCK => {
            self.lockActive(wparam != 0, popupOf(lparam));
            return 0;
        },
        WM_APP_SYNC_ACTIVATION => {
            self.syncActivation();
            return 0;
        },
        WM_APP_NATIVE_FALLBACK => {
            self.applyNativeFallback();
            return 0;
        },
        WM_GHOSTTY_SIMULATE_D2D_FAILURE => {
            self.queueNativeFallback();
            return 1;
        },
        WM_GHOSTTY_CAPTION_QUERY => return @as(isize, @intFromBool(self.active)) |
            (@as(isize, @intFromBool(self.ownerActiveLocked())) << 1) |
            (@as(isize, @intFromBool(self.nativeButtons())) << 2) |
            (@as(isize, @intFromBool(self.direct2d_failed)) << 3),
        w32.WM_SIZE => {
            self.forgetNativeBounds();
            // Restoring repaints the whole window: lay the row out anew
            // then.
            if (wparam == w32.SIZE_MINIMIZED) self.painted_layout = .{};
        },
        else => {},
    }

    // DWM hit-tests, hovers and presses its own caption buttons.
    const native = self.nativeButtons();
    if (native) {
        var result: isize = 0;
        if (DwmDefWindowProc(hwnd, msg, wparam, lparam, &result) != 0) return result;
    }

    switch (msg) {
        WM_NCCALCSIZE => return self.onNcCalcSize(hwnd, wparam, lparam),
        WM_NCHITTEST => return self.onNcHitTest(hwnd, lparam),
        else => {},
    }

    // Our own caption buttons; a native caption or native buttons keep the
    // default handling.
    if (!self.hasCaptionRow() or native) {
        if (msg == WM_NCRBUTTONUP and self.extendsClient() and wparam == HTCAPTION) {
            self.openSystemMenu(lparamPoint(lparam));
            return 0;
        }
        return null;
    }
    switch (msg) {
        WM_NCMOUSEMOVE => {
            const button = buttonFromHitCode(wparam);
            self.setHover(button);
            if (button != .none) {
                self.trackNcLeave(hwnd);
                return 0;
            }
            return null;
        },
        WM_NCMOUSELEAVE => {
            self.tracking_nc = false;
            if (self.hover != .menu) self.setHover(.none);
            self.setPressed(.none);
            return 0;
        },
        WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK => {
            const button = buttonFromHitCode(wparam);
            if (button == .none) return null;
            self.tooltip.hide();
            self.setPressed(button);
            return 0;
        },
        WM_NCLBUTTONUP => {
            const button = buttonFromHitCode(wparam);
            if (button == .none) return null;
            const was_pressed = self.pressed == button;
            self.setPressed(.none);
            if (was_pressed) self.performButton(button);
            return 0;
        },
        WM_NCRBUTTONDOWN, WM_NCRBUTTONDBLCLK => {
            if (buttonFromHitCode(wparam) != .none) return 0;
            return null;
        },
        WM_NCRBUTTONUP => {
            if (buttonFromHitCode(wparam) != .none) return 0;
            if (wparam == HTCAPTION or wparam == HTTOP) {
                self.openSystemMenu(lparamPoint(lparam));
                return 0;
            }
            return null;
        },
        else => return null,
    }
}

fn lparamPoint(lparam: isize) w32.POINT {
    return .{
        .x = @as(i16, @truncate(lparam & 0xFFFF)),
        .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
    };
}

fn onNcCalcSize(self: *TitleBar, hwnd: w32.HWND, wparam: usize, lparam: isize) ?isize {
    if (!self.extendsClient() or wparam == 0) return null;
    const params: *NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const original = params.rgrc[0];
    const ret = w32.DefWindowProcW(hwnd, WM_NCCALCSIZE, wparam, lparam);
    if (ret != 0) return ret;

    // Keep the default left, right and bottom borders; give the caption
    // to the client area. A maximized window hangs over the monitor edges
    // by its frame, so its client area starts that far down instead.
    var rect = params.rgrc[0];
    const frame_y = original.bottom - rect.bottom;
    rect.top = original.top;
    if (w32.IsZoomed(hwnd) != 0) rect.top += frame_y;
    params.rgrc[0] = rect;
    return 0;
}

fn onNcHitTest(self: *TitleBar, hwnd: w32.HWND, lparam: isize) ?isize {
    const f = self.frame();
    if (f == .popup) return null;
    const lay = self.layout();
    if (lay.height() <= 0 and !f.extendsClient()) return null;

    // The default handles the left, right and bottom borders.
    const default = w32.DefWindowProcW(hwnd, WM_NCHITTEST, 0, lparam);
    if (default != w32.HTCLIENT) return default;

    var pt = lparamPoint(lparam);
    _ = w32.ScreenToClient(hwnd, &pt);
    return switch (caption_layout.ncHit(lay, pt.x, pt.y, self.tabsAt(lay, pt.x, pt.y))) {
        .client => w32.HTCLIENT,
        .caption => HTCAPTION,
        .top => HTTOP,
        .top_left => HTTOPLEFT,
        .top_right => HTTOPRIGHT,
        .minimize => HTMINBUTTON,
        .maximize => HTMAXBUTTON,
        .close => HTCLOSE,
    };
}

fn trackNcLeave(self: *TitleBar, hwnd: w32.HWND) void {
    if (self.tracking_nc) return;
    var tme = w32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
        .dwFlags = w32.TME_LEAVE | TME_NONCLIENT,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (w32.TrackMouseEvent(&tme) != 0) self.tracking_nc = true;
}

/// The button under the pointer changed; the one it left fades out.
fn setHover(self: *TitleBar, button: Button) void {
    self.setHoverWith(button, true);
}

fn setHoverWith(self: *TitleBar, button: Button, fade: bool) void {
    if (self.hover == button) return;
    const left = self.hover;
    self.hover = button;
    self.fades.cancel(button);
    if (fade) self.fades.begin(left) else self.fades.cancel(left);
    self.invalidateButton(left);
    self.invalidateButton(button);
    self.setTooltipTarget(switch (button) {
        .none => .none,
        .minimize => .minimize,
        .maximize => .maximize,
        .close => .close,
        .menu => .menu,
    });
}

/// The button being pressed changed.
fn setPressed(self: *TitleBar, button: Button) void {
    if (self.pressed == button) return;
    self.invalidateButton(self.pressed);
    self.pressed = button;
    self.invalidateButton(button);
}

/// The layout moved under a pointer that stayed (a resize, maximizing):
/// hover the caption button now under it, without a fade. The main menu
/// button keeps its hover only while still under the pointer; the next
/// mouse move over it hovers it again.
fn syncHover(self: *TitleBar, lay: Layout) void {
    const hwnd = self.window().hwnd orelse return;
    var under: Button = .none;
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) != 0 and WindowFromPoint(pt) == hwnd) {
        _ = w32.ScreenToClient(hwnd, &pt);
        switch (self.hitTest(lay, pt.x, pt.y)) {
            .button => |b| under = b,
            else => {},
        }
    }
    const button: Button = if (under == .menu and self.hover != .menu) .none else under;
    if (button == self.hover) return;
    self.setHoverWith(button, false);
    if (button != .none and button != .menu) self.trackNcLeave(hwnd);
}

fn performButton(self: *TitleBar, button: Button) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    self.tooltip.hide();
    switch (button) {
        .none => {},
        .minimize => _ = w32.PostMessageW(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0),
        .maximize => _ = w32.PostMessageW(hwnd, WM_SYSCOMMAND, if (w32.IsZoomed(hwnd) != 0) SC_RESTORE else SC_MAXIMIZE, 0),
        .close => _ = w32.PostMessageW(hwnd, WM_SYSCOMMAND, SC_CLOSE, 0),
        .menu => {
            // The button's column down to the bottom of the row.
            const lay = self.layout();
            var top_left = w32.POINT{ .x = lay.menu.left, .y = lay.menu.top };
            var bottom_right = w32.POINT{ .x = lay.menu.right, .y = lay.bar.bottom };
            _ = w32.ClientToScreen(hwnd, &top_left);
            _ = w32.ClientToScreen(hwnd, &bottom_right);
            Menu.showMain(win, .{
                .left = top_left.x,
                .top = top_left.y,
                .right = bottom_right.x,
                .bottom = bottom_right.y,
            }, .right);
        },
    }
}

// -----------------------------------------------------------------------
// Client mouse input in the chrome row (the main menu button; the rest is
// forwarded to the tab bar)
// -----------------------------------------------------------------------

/// Mouse movement in the client area. Returns true when it was over the
/// chrome row.
pub fn onMouseMove(self: *TitleBar, x: i32, y: i32) bool {
    const lay = self.layout();
    const hit = self.hitTest(lay, x, y);
    self.setHover(switch (hit) {
        .button => |button| if (button == .menu) .menu else .none,
        else => .none,
    });
    _ = self.window().tab_bar.onMouseMove(lay, x, lay.tabY(y));
    return hit != .none;
}

/// A left-button press in the client area; returns true when the chrome
/// row handled it.
pub fn onLeftButtonDown(self: *TitleBar, x: i32, y: i32) bool {
    const lay = self.layout();
    switch (self.hitTest(lay, x, y)) {
        .none => return false,
        .button => |button| {
            self.tooltip.hide();
            self.setPressed(button);
            return true;
        },
        .tabs => {
            self.tooltip.hide();
            self.window().tab_bar.onLeftButtonDown(lay, x, lay.tabY(y));
            return true;
        },
        .caption => return true,
    }
}

/// A left-button release in the client area.
pub fn onLeftButtonUp(self: *TitleBar, x: i32, y: i32) bool {
    const lay = self.layout();
    const pressed = self.pressed;
    if (pressed != .none) {
        self.setPressed(.none);
        const released_on_menu = switch (self.hitTest(lay, x, y)) {
            .button => |button| button == .menu,
            else => false,
        };
        if (pressed == .menu and released_on_menu) self.performButton(.menu);
        return true;
    }
    return self.window().tab_bar.onLeftButtonUp(lay, x, lay.tabY(y));
}

/// The mouse left the client area.
pub fn onMouseLeave(self: *TitleBar) void {
    if (self.hover == .menu) self.setHover(.none);
    if (self.pressed == .menu) self.setPressed(.none);
    self.window().tab_bar.onMouseLeave();
}

// -----------------------------------------------------------------------
// System menu
// -----------------------------------------------------------------------

/// Open the window menu at `screen_pt` (right-click on the title bar); it
/// performs the picked command (`Menu.showWindowMenu`).
pub fn openSystemMenu(self: *TitleBar, screen_pt: w32.POINT) void {
    Menu.showWindowMenu(self.window(), screen_pt);
}

/// Open the window menu below the left end of the title bar (Alt+Space).
pub fn openSystemMenuFromKeyboard(self: *TitleBar) void {
    const hwnd = self.window().hwnd orelse return;
    var pt = w32.POINT{ .x = 0, .y = @max(self.layout().bar.bottom, 0) };
    _ = w32.ClientToScreen(hwnd, &pt);
    self.openSystemMenu(pt);
}

// -----------------------------------------------------------------------
// Activation
// -----------------------------------------------------------------------

/// The popups holding the window painted as active.
const ActiveLocks = struct {
    /// The locking popups; null slots are free.
    popups: [8]?w32.HWND = @splat(null),
    /// Locks of popups that did not say which they are or did not fit.
    others: u16 = 0,

    fn add(self: *ActiveLocks, popup: ?w32.HWND) void {
        if (popup) |p| {
            for (self.popups) |slot| if (slot != null and slot.? == p) return;
            for (&self.popups) |*slot| if (slot.* == null) {
                slot.* = p;
                return;
            };
        }
        self.others +|= 1;
    }

    fn remove(self: *ActiveLocks, popup: ?w32.HWND) void {
        if (popup) |p| for (&self.popups) |*slot| if (slot.* != null and slot.*.? == p) {
            slot.* = null;
            return;
        };
        self.others -|= 1;
    }

    /// Whether a lock is held; a popup that went away without letting go
    /// holds none.
    fn held(self: *const ActiveLocks) bool {
        return self.heldWith(windowExists);
    }

    fn heldWith(self: *const ActiveLocks, exists: *const fn (w32.HWND) bool) bool {
        if (self.others > 0) return true;
        for (self.popups) |slot| {
            const p = slot orelse continue;
            if (exists(p)) return true;
        }
        return false;
    }

    /// Forget popups that went away without letting go.
    fn prune(self: *ActiveLocks) void {
        self.pruneWith(windowExists);
    }

    fn pruneWith(self: *ActiveLocks, exists: *const fn (w32.HWND) bool) void {
        for (&self.popups) |*slot| {
            const p = slot.* orelse continue;
            if (!exists(p)) slot.* = null;
        }
    }

    fn windowExists(hwnd: w32.HWND) bool {
        return w32.IsWindow(hwnd) != 0;
    }
};

fn popupOf(lparam: isize) ?w32.HWND {
    if (lparam == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

/// `Popup.WM_GX_OWNER_ACTIVE_LOCK` from `popup`: it is about to take the
/// activation (`locked`), or it hid or lost it. Popups send it from `show`
/// and `WM_MOUSEACTIVATE` (SendMessage), so this pumps no messages: once
/// the last lock went, a posted message checks the activation after the
/// change completed.
fn lockActive(self: *TitleBar, locked: bool, popup: ?w32.HWND) void {
    if (locked) {
        self.active_locks.prune();
        self.active_locks.add(popup);
        return;
    }
    self.active_locks.remove(popup);
    if (self.active_locks.held() or self.activation_sync_pending) return;
    const hwnd = self.window().hwnd orelse return;
    if (w32.PostMessageW(hwnd, WM_APP_SYNC_ACTIVATION, 0, 0) != 0) {
        self.activation_sync_pending = true;
    } else {
        self.syncActivation();
    }
}

/// `Popup.WM_GX_OWNER_ACTIVE_LOCK` from a popup that did not say which it
/// is: count the lock. GUI thread; pumps no messages.
pub fn onOwnerActiveLock(self: *TitleBar, locked: bool) void {
    self.lockActive(locked, null);
}

/// Whether a popup holds the window active, so `WM_NCACTIVATE(FALSE)`
/// leaves the frame active.
pub fn ownerActiveLocked(self: *const TitleBar) bool {
    return self.active_locks.held();
}

/// The last lock went and the activation change settled: paint the frame
/// as it really is, active only while the window is the foreground window
/// (not when another program, or one of its own dialogs, is).
fn syncActivation(self: *TitleBar) void {
    self.activation_sync_pending = false;
    self.active_locks.prune();
    if (self.active_locks.held()) return;
    const hwnd = self.window().hwnd orelse return;
    const active = w32.GetForegroundWindow() == hwnd;
    if (active == self.active) return;
    self.setActive(active);
    // DWM's parts of the frame (the border, its caption buttons, an
    // inactive material) follow the default handling of WM_NCACTIVATE,
    // which the lock kept active.
    _ = self.defNcActivate(hwnd, active, 0);
}

fn onNcActivate(self: *TitleBar, hwnd: w32.HWND, wparam: usize, lparam: isize) isize {
    // The low word is the BOOL; Windows sets more for minimized windows.
    const active = wparam & 0xFFFF != 0 or self.active_locks.held();
    self.setActive(active);
    // Returns TRUE: a deactivation proceeds even while painted active.
    return self.defNcActivate(hwnd, active, lparam);
}

/// The default handling of WM_NCACTIVATE for the frame painted `active`.
fn defNcActivate(self: *TitleBar, hwnd: w32.HWND, active: bool, lparam: isize) isize {
    const wparam: usize = @intFromBool(active);
    if (self.nativeButtons()) {
        var result: isize = 0;
        if (DwmDefWindowProc(hwnd, WM_NCACTIVATE, wparam, lparam, &result) != 0) return result;
    }
    return w32.DefWindowProcW(hwnd, WM_NCACTIVATE, wparam, lparam);
}

fn setActive(self: *TitleBar, active: bool) void {
    if (active == self.active) return;
    self.active = active;
    self.invalidate();
    self.applyBorder();
}

/// Show the border of the frame and the activation (`Backdrop.setBorder`).
fn applyBorder(self: *TitleBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    const border: Backdrop.Border = if (self.frame() == .borderless)
        .hidden
    else if (self.active)
        .active
    else
        .inactive;
    Backdrop.setBorder(hwnd, &win.app.config, border);
}

// -----------------------------------------------------------------------
// System changes and size
// -----------------------------------------------------------------------

/// A system broadcast reached the window (`Window.onSystemSettingChange`),
/// after the design tokens read the system colors again (`style.system`)
/// and `Backdrop` followed it: high contrast switches the row between
/// opaque and over the material, and the row repaints when the system
/// colors, the visual style or the apps theme changed; the border follows
/// the accent color settings.
pub fn onSystemSettingChange(self: *TitleBar, change: w32.SystemChange) void {
    switch (change) {
        .sys_colors, .theme => self.onAppearanceChanged(),
        .setting => |setting| if (change.isArea("ImmersiveColorSet") or setting.action == SPI_SETHIGHCONTRAST) {
            self.onAppearanceChanged();
        },
        .colorization => self.applyBorder(),
    }
}

fn onAppearanceChanged(self: *TitleBar) void {
    self.forgetNativeBounds();
    const high_contrast = style.system.highContrast();
    if (high_contrast != self.high_contrast) {
        self.high_contrast = high_contrast;
        self.tooltip.hide();
        self.window().applyFrameMargins();
    }
    self.applyBorder();
    self.invalidate();
}

/// The window was resized (WM_SIZE, not minimized): drop the tooltip,
/// repaint the row when its layout changed (not for a change of height
/// only) and hover what is under the pointer now (maximizing moves the
/// buttons).
pub fn onSize(self: *TitleBar) void {
    self.tooltip.hide();
    self.forgetNativeBounds();
    self.refreshNativeBounds();
    const lay = self.layout();
    if (!std.meta.eql(lay, self.painted_layout)) self.invalidate();
    self.syncHover(lay);
}

// -----------------------------------------------------------------------
// Painting
// -----------------------------------------------------------------------

/// Repaint the chrome row.
pub fn invalidate(self: *TitleBar) void {
    const hwnd = self.window().hwnd orelse return;
    const h = self.height();
    if (h <= 0) return;
    var rect = w32.RECT{ .left = 0, .top = 0, .right = 1 << 16, .bottom = h };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Repaint `rect` (client pixels) of the chrome row only, such as a tab.
pub fn invalidateRect(self: *TitleBar, rect: w32.RECT) void {
    const hwnd = self.window().hwnd orelse return;
    if (rect.right <= rect.left or rect.bottom <= rect.top) return;
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

fn invalidateButton(self: *TitleBar, button: Button) void {
    if (button == .none) return;
    self.invalidateRect(self.layout().buttonRect(button));
}

/// Paint the part of the chrome row the paint DC `hdc` covers (its clip
/// box, the update region): the strip, the tabs, the main menu button and
/// the caption buttons, drawn with Direct2D into the kept 32bpp DIB
/// (premultiplied alpha, so the backdrop material shows through
/// transparent pixels) and blitted in one go.
pub fn paint(self: *TitleBar, hdc: w32.HDC) void {
    const win = self.window();
    const lay = self.layout();
    const w = lay.bar.right - lay.bar.left;
    const h = lay.height();
    if (w <= 0 or h <= 0) return;
    const dirty = paintArea(hdc, lay.bar) orelse return;

    const factory = win.app.uiFactory() orelse return;
    const span: ?perf.Span = if (perf.enabled()) perf.Span.begin(global.io()) else null;
    defer if (span) |s| {
        _ = s.end(global.io(), "titlebar.paint");
    };
    if (self.canvas == null) self.canvas = d2d.Canvas.init(factory);
    const canvas = &self.canvas.?;
    const mem_dc = self.dib.ensure(hdc, w, h) orelse return;

    const rect = w32.RECT{ .left = 0, .top = 0, .right = w, .bottom = h };
    if (!canvas.beginDcAlpha(mem_dc, rect, self.canvasDpi())) {
        self.queueNativeFallback();
        return;
    }
    const tokens = style.Tokens.fromConfig(&win.app.config);
    const colors = self.paintColors(tokens);
    const ctx: PaintContext = .{
        .canvas = canvas,
        .tokens = tokens,
        .layout = lay,
        .active = self.active,
        .translucent = colors.strip_fill.a < 1,
        .strip_fill = colors.strip_fill,
        .strip_text = colors.strip_text,
        .strip_text_inactive = colors.strip_text_inactive,
        .tab_fill = colors.tab_fill,
    };
    // Direct2D draws only inside the clip; the rest of the DIB keeps the
    // last paint, which is on the screen already. Parts outside it are
    // not drawn at all (a hovered caption button repaints only itself).
    canvas.pushClip(ctx.dipRect(dirty));
    canvas.clear(colors.strip_fill);
    const native = self.nativeButtons();
    if (native and colors.strip_fill.a > 0) {
        var caption_area = lay.bar;
        caption_area.left = std.math.clamp(
            if (self.nativeButtonBounds()) |bounds| bounds.left else lay.bar.right - style.px(3 * style.metrics.caption_button_width, lay.scale),
            lay.bar.left,
            lay.bar.right,
        );
        if (overlaps(dirty, caption_area)) {
            canvas.pushClip(ctx.dipRect(caption_area));
            canvas.clear(d2d.Color.black.withAlpha(0));
            canvas.popClip();
        }
    }
    const tab_area: w32.RECT = .{ .left = 0, .top = 0, .right = lay.menu.left, .bottom = lay.bar.bottom };
    if (overlaps(dirty, tab_area) or lay.menu.right <= lay.menu.left) win.tab_bar.paint(ctx);
    const now = anim.now();
    if (overlaps(dirty, lay.menu)) self.paintMenuButton(ctx, now);
    if (lay.caption and !native) self.paintCaptionButtons(ctx, dirty, now);
    canvas.popClip();
    switch (canvas.finish()) {
        .ok => {},
        .recreate => {
            self.invalidate();
            return;
        },
        .failed => {
            self.queueNativeFallback();
            return;
        },
    }
    self.painted_layout = lay;

    _ = w32.BitBlt(hdc, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top, mem_dc, dirty.left, dirty.top, w32.SRCCOPY);
}

/// The part of `bar` the paint DC `hdc` covers, null when none.
fn paintArea(hdc: w32.HDC, bar: w32.RECT) ?w32.RECT {
    var clip: w32.RECT = undefined;
    switch (GetClipBox(hdc, &clip)) {
        NULLREGION => return null,
        REGION_ERROR => return bar,
        else => {},
    }
    const area: w32.RECT = .{
        .left = @max(bar.left, clip.left),
        .top = @max(bar.top, clip.top),
        .right = @min(bar.right, clip.right),
        .bottom = @min(bar.bottom, clip.bottom),
    };
    if (area.right <= area.left or area.bottom <= area.top) return null;
    return area;
}

/// Whether two pixel rectangles share a pixel.
fn overlaps(a: w32.RECT, b: w32.RECT) bool {
    return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
}

/// The colors of the strip (see `PaintContext`).
const StripColors = struct {
    strip_fill: d2d.Color,
    strip_text: d2d.Color,
    strip_text_inactive: d2d.Color,
    tab_fill: d2d.Color,
};

/// The strip colors (`stripColors`) for this window.
fn paintColors(self: *const TitleBar, tokens: style.Tokens) StripColors {
    const win = self.windowConst();
    const config = &win.app.config;
    const per_pixel = Backdrop.perPixel(config, win.app.alpha_frames);
    return stripColors(tokens, .{
        .material = Backdrop.material(config),
        .under_frame = self.translucent(),
        .per_pixel = per_pixel,
        .opacity = @floatCast(std.math.clamp(config.@"background-opacity", 0, 1)),
        .material_dark = Backdrop.materialIsDark(config),
        .terminal = if (per_pixel) Backdrop.straightColor(config) else null,
    });
}

/// What the strip shows through, for `stripColors`.
const StripBackdrop = struct {
    material: Backdrop.Material = .solid,
    /// DWM extends its frame under the row, so the material shows there
    /// (`translucent`).
    under_frame: bool = false,
    /// DWM composes the window per pixel (`Backdrop.perPixel`).
    per_pixel: bool = false,
    /// `background-opacity`.
    opacity: f32 = 1,
    /// Whether the material is dark (`Backdrop.materialIsDark`).
    material_dark: bool = true,
    /// The terminal background as the terminals draw it
    /// (`Backdrop.straightColor`), where DWM composes the window per pixel.
    terminal: ?d2d.Color = null,
};

/// Bare materials use black or white glyphs according to `window-theme`.
/// Acrylic and per-pixel strips have a title-bar underlay at the terminals'
/// opacity. High contrast stays opaque; active tabs join the terminals.
fn stripColors(tokens: style.Tokens, through: StripBackdrop) StripColors {
    var colors: StripColors = .{
        .strip_fill = tokens.title_bar,
        .strip_text = tokens.text,
        .strip_text_inactive = tokens.text_disabled,
        .tab_fill = tokens.background,
    };
    if (tokens.high_contrast) return colors;
    if (through.terminal) |terminal| colors.tab_fill = terminal;
    const material = through.under_frame and through.material != .solid;
    const bare = material and (through.material != .acrylic or !through.per_pixel);
    if (bare) {
        colors.strip_fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const text = materialText(through.material_dark);
        colors.strip_text = text.text;
        colors.strip_text_inactive = text.inactive;
    } else if (material or through.per_pixel) {
        colors.strip_fill = tokens.title_bar.withAlpha(through.opacity);
    }
    return colors;
}

/// Text on a bare material: the token text colors of a black (dark) or a
/// white theme, derived once each.
fn materialText(dark: bool) struct { text: d2d.Color, inactive: d2d.Color } {
    const Cache = struct {
        var dark_text: ?style.Tokens = null;
        var light_text: ?style.Tokens = null;
    };
    const slot = if (dark) &Cache.dark_text else &Cache.light_text;
    if (slot.* == null) {
        const black = d2d.Color.black;
        const white = d2d.Color.white;
        slot.* = style.Tokens.fromColors(if (dark) black else white, if (dark) white else black, if (dark) white else black);
    }
    return .{ .text = slot.*.?.text, .inactive = slot.*.?.text_disabled };
}

/// What the chrome row painters share.
pub const PaintContext = struct {
    canvas: *d2d.Canvas,
    tokens: style.Tokens,
    layout: Layout,
    /// Whether the window is painted as active (inactive glyphs dim).
    active: bool,
    /// Whether the strip is (partly) transparent over a backdrop material
    /// or the desktop.
    translucent: bool,
    /// The fill of the strip (painted already; see `paintColors`).
    strip_fill: d2d.Color,
    /// Text and glyphs on the strip, and dimmed for an inactive window.
    strip_text: d2d.Color,
    strip_text_inactive: d2d.Color,
    /// The fill of the active tab, which joins the terminal below: the
    /// terminal background as the terminals draw it
    /// (`Backdrop.straightColor` where DWM composes the window per pixel).
    tab_fill: d2d.Color,

    /// A pixel rectangle in DIPs.
    pub fn dipRect(self: PaintContext, rect: w32.RECT) d2d.Rect {
        const s = self.layout.scale;
        return .{
            .x = style.dip(rect.left, s),
            .y = style.dip(rect.top, s),
            .w = style.dip(rect.right - rect.left, s),
            .h = style.dip(rect.bottom - rect.top, s),
        };
    }

    /// Glyph color of chrome buttons.
    pub fn glyphColor(self: PaintContext) d2d.Color {
        return if (self.active) self.strip_text else self.strip_text_inactive;
    }

    /// Glyph color of a hovered or pressed chrome button: on the highlight
    /// fill of high contrast, the highlight text.
    pub fn hoverGlyphColor(self: PaintContext) d2d.Color {
        return if (self.tokens.high_contrast) self.tokens.hover_text else self.strip_text;
    }
};

/// How a button looks: its fill (none when plain) and glyph color.
const Look = struct {
    fill: ?d2d.Color,
    glyph: d2d.Color,
};

/// The look of `button` at `now` (`lookOf`).
fn buttonLook(self: *const TitleBar, ctx: PaintContext, button: Button, now: u64) Look {
    return lookOf(ctx, button, .{
        .hovered = self.hover == button,
        .pressed = self.pressed == button,
        .fade = self.fades.progress(button, now),
    });
}

/// Where a button is in its states.
const ButtonState = struct {
    hovered: bool = false,
    pressed: bool = false,
    fade: ?Fades.Progress = null,
};

/// The look of `button` in `state`: pressed only while the pressed button
/// is also under the pointer, hovered, fading out of the hover look, or
/// plain. The close button turns red (#c42b1c); pressed fills are fainter
/// than hover fills. In high contrast the fills are the highlight color
/// with the highlight text on them.
fn lookOf(ctx: PaintContext, button: Button, state: ButtonState) Look {
    const close = button == .close;
    const hover_fill = if (close) ctx.tokens.close_hover else ctx.tokens.overlay_hover;
    const hover_glyph = if (close) ctx.tokens.close_hover_text else ctx.hoverGlyphColor();
    if (state.hovered and state.pressed) return .{
        .fill = if (close) ctx.tokens.close_pressed else ctx.tokens.overlay_pressed,
        .glyph = hover_glyph,
    };
    if (state.hovered) return .{ .fill = hover_fill, .glyph = hover_glyph };
    if (state.fade) |p| return .{
        .fill = hover_fill.withAlpha(hover_fill.a * (1 - p.fill)),
        .glyph = style.mix(hover_glyph, ctx.glyphColor(), p.glyph),
    };
    return .{ .fill = null, .glyph = ctx.glyphColor() };
}

fn paintMenuButton(self: *TitleBar, ctx: PaintContext, now: u64) void {
    const r = ctx.dipRect(ctx.layout.menu);
    if (r.w <= 0) return;
    const look = self.buttonLook(ctx, .menu, now);
    if (look.fill) |fill| ctx.canvas.fillRoundedRect(r, style.radius.control, fill);
    ctx.canvas.drawIcon(d2d.icons.global_nav, r, 14, look.glyph);
}

/// Paint the caption buttons `dirty` (client pixels) touches.
fn paintCaptionButtons(self: *TitleBar, ctx: PaintContext, dirty: w32.RECT, now: u64) void {
    const zoomed = self.isZoomed();
    const buttons = [_]struct { Button, w32.RECT, u21 }{
        .{ .minimize, ctx.layout.minimize, d2d.icons.minimize },
        .{ .maximize, ctx.layout.maximize, if (zoomed) d2d.icons.restore else d2d.icons.maximize },
        .{ .close, ctx.layout.close, d2d.icons.close },
    };
    for (buttons) |entry| {
        const button, const rect, const glyph = entry;
        if (!overlaps(dirty, rect)) continue;
        const r = ctx.dipRect(rect);
        const look = self.buttonLook(ctx, button, now);
        if (look.fill) |fill| ctx.canvas.fillRect(r, fill);
        ctx.canvas.drawIcon(glyph, r, style.metrics.caption_glyph_size, look.glyph);
    }
}

/// Caption buttons fading out of their hover look after the pointer left
/// them. WinUI's caption buttons fade the fill in 150 ms and the glyph in
/// 100 ms; these take the nearest shared Fluent durations (`gx.motion`).
/// Painting reads the progress from the clock; the ticks repaint the
/// fading buttons only.
const Fades = struct {
    animator: anim.Animator = .{ .tick = tick },
    /// When each of `buttons` started fading (`anim.now`), 0 when it does
    /// not.
    started: [buttons.len]u64 = @splat(0),

    const buttons = [_]Button{ .minimize, .maximize, .close, .menu };

    const Progress = struct { fill: f32, glyph: f32 };

    fn index(button: Button) ?usize {
        return std.mem.indexOfScalar(Button, &buttons, button);
    }

    fn fillTween(start: u64) anim.Tween {
        return .begin(start, anim.motion.duration.fast, anim.motion.linear);
    }

    /// Fade `button` out from now on, when animations are on.
    fn begin(self: *Fades, button: Button) void {
        const i = index(button) orelse return;
        if (!anim.enabled()) return;
        self.started[i] = @max(anim.now(), 1);
        if (!anim.start(&self.animator)) self.started[i] = 0;
    }

    fn cancel(self: *Fades, button: Button) void {
        const i = index(button) orelse return;
        self.started[i] = 0;
    }

    fn stop(self: *Fades) void {
        anim.stop(&self.animator);
        self.started = @splat(0);
    }

    /// How far `button` faded at `now`; null when it does not fade.
    fn progress(self: *const Fades, button: Button, now: u64) ?Progress {
        const i = index(button) orelse return null;
        const start = self.started[i];
        if (start == 0) return null;
        const fill = fillTween(start);
        if (fill.done(now)) return null;
        const glyph: anim.Tween = .begin(start, anim.motion.duration.faster, anim.motion.linear);
        return .{ .fill = fill.progress(now), .glyph = glyph.progress(now) };
    }

    fn tick(animator: *anim.Animator, now: u64) bool {
        const self: *Fades = @alignCast(@fieldParentPtr("animator", animator));
        const title_bar: *TitleBar = @alignCast(@fieldParentPtr("fades", self));
        const lay = title_bar.layout();
        var running = false;
        for (&self.started, buttons) |*start, button| {
            if (start.* == 0) continue;
            title_bar.invalidateRect(lay.buttonRect(button));
            if (fillTween(start.*).done(now)) start.* = 0 else running = true;
        }
        return running;
    }
};

// -----------------------------------------------------------------------
// Tooltip
// -----------------------------------------------------------------------

/// What the tooltip describes.
pub const TooltipTarget = union(enum) {
    none,
    menu,
    minimize,
    maximize,
    close,
    new_tab,
    profiles,
    tab_close: usize,
    tab: usize,
};

/// The tab bar part under the mouse changed: point the tooltip at it, or
/// clear a tooltip of the tab bar (but not one of the title bar buttons).
pub fn setTabTooltipTarget(self: *TitleBar, target: TooltipTarget) void {
    if (target == .none) switch (self.tooltip.target) {
        .new_tab, .profiles, .tab_close, .tab => {},
        else => return,
    };
    self.setTooltipTarget(target);
}

/// Point the tooltip at `target`: it shows after the hover delay and
/// hides when the target changes.
pub fn setTooltipTarget(self: *TitleBar, target: TooltipTarget) void {
    const hwnd = self.window().hwnd orelse return;
    self.tooltip.setTarget(hwnd, target);
}

/// WM_TIMER for the tooltip; returns true when it was the tooltip delay.
pub fn onTimer(self: *TitleBar, id: usize) bool {
    const hwnd = self.window().hwnd orelse return false;
    if (!self.tooltip.delayElapsed(hwnd, id)) return false;
    self.showTooltip();
    return true;
}

fn showTooltip(self: *TitleBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    // Only while the mouse still is over this window.
    var cursor: w32.POINT = undefined;
    if (w32.GetCursorPos_(&cursor) == 0) return;
    if (WindowFromPoint(cursor) != hwnd) return;

    var buf: [512]u8 = undefined;
    const lay = self.layout();
    const text: []const u8, const anchor: w32.RECT = switch (self.tooltip.target) {
        .none => return,
        .menu => .{ i18n.tr("Main menu"), lay.menu },
        .minimize => .{ i18n.tr("Minimize"), lay.minimize },
        .maximize => .{ if (self.isZoomed()) i18n.tr("Restore Down") else i18n.tr("Maximize"), lay.maximize },
        .close => .{ i18n.tr("Close"), lay.close },
        .new_tab, .profiles, .tab_close, .tab => tip: {
            const tip = win.tab_bar.tooltip(self.tooltip.target, lay, &buf) orelse return;
            break :tip .{ tip.text, tip.anchor };
        },
    };
    if (text.len == 0 or anchor.right <= anchor.left) return;
    var top_left = w32.POINT{ .x = anchor.left, .y = anchor.top };
    var bottom_right = w32.POINT{ .x = anchor.right, .y = anchor.bottom };
    _ = w32.ClientToScreen(hwnd, &top_left);
    _ = w32.ClientToScreen(hwnd, &bottom_right);
    self.tooltip.show(win.app, hwnd, win.scale, text, .{
        .left = top_left.x,
        .top = top_left.y,
        .right = bottom_right.x,
        .bottom = bottom_right.y,
    });
}

/// The DPI of the window changed (metrics, fonts and caption buttons).
pub fn onDpiChanged(self: *TitleBar) void {
    self.tooltip.hide();
    self.forgetNativeBounds();
    self.invalidate();
}

/// The UI language changed: refresh a visible tooltip and repaint.
pub fn onLanguageChanged(self: *TitleBar) void {
    if (self.tooltip.visible()) self.showTooltip();
    self.invalidate();
}

/// The configuration changed (colors, material), after
/// `Backdrop.onConfigChange`: set the border of the frame and repaint.
pub fn onConfigChange(self: *TitleBar) void {
    self.tooltip.hide();
    self.forgetNativeBounds();
    self.applyBorder();
    self.invalidate();
}

// -----------------------------------------------------------------------
// Fullscreen and decorations
// -----------------------------------------------------------------------

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *TitleBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    self.tooltip.hide();
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        self.saved_placement.length = @sizeOf(WINDOWPLACEMENT);
        _ = GetWindowPlacement(hwnd, &self.saved_placement);
        self.is_fullscreen = true;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE | w32.WS_CLIPCHILDREN);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        self.is_fullscreen = false;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = SetWindowPlacement(hwnd, &self.saved_placement);
        _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_FRAMECHANGED);
    }
    self.forgetNativeBounds();
    win.onFrameChanged();
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleDecorations(self: *TitleBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    self.decorations_hidden = !self.decorations_hidden;
    self.tooltip.hide();
    self.forgetNativeBounds();
    self.applyBorder();
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    win.onFrameChanged();
}

/// Apply the configured decoration once the window exists. Without
/// Direct2D, which draws the chrome row, every window keeps the system
/// caption and no chrome row (`frame`, `height`).
pub fn applyDecoration(self: *TitleBar, config: *const configpkg.Config) void {
    self.decoration = Decoration.fromConfig(config.@"window-decoration");
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    if (!self.direct2d_failed and win.app.uiFactory() == null) self.markNativeFallback();
    self.high_contrast = style.system.highContrast();
    self.forgetNativeBounds();
    self.applyBorder();
    // Recompute the frame now that WM_NCCALCSIZE reaches this title bar.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE);
}

fn markNativeFallback(self: *TitleBar) void {
    if (self.direct2d_failed) return;
    self.direct2d_failed = true;
    self.tooltip.hide();
    self.fades.stop();
    log.warn("Direct2D is unavailable: the window uses the system title bar without tabs", .{});
}

fn queueNativeFallback(self: *TitleBar) void {
    self.markNativeFallback();
    const hwnd = self.window().hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_NATIVE_FALLBACK, 0, 0);
}

fn applyNativeFallback(self: *TitleBar) void {
    const win = self.window();
    self.applyDecoration(&win.app.config);
    win.onFrameChanged();
}

// -----------------------------------------------------------------------
// Win32 declarations used only by the title bar
// -----------------------------------------------------------------------

const WM_NCCALCSIZE: u32 = 0x0083;
const WM_NCHITTEST: u32 = 0x0084;
const WM_NCACTIVATE: u32 = 0x0086;
const WM_NCMOUSEMOVE: u32 = 0x00A0;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_NCLBUTTONUP: u32 = 0x00A2;
const WM_NCLBUTTONDBLCLK: u32 = 0x00A3;
const WM_NCRBUTTONDOWN: u32 = 0x00A4;
const WM_NCRBUTTONUP: u32 = 0x00A5;
const WM_NCRBUTTONDBLCLK: u32 = 0x00A6;
const WM_NCMOUSELEAVE: u32 = 0x02A2;
pub const WM_SYSCOMMAND: u32 = 0x0112;

const HTCAPTION: isize = 2;
const HTMINBUTTON: isize = 8;
const HTMAXBUTTON: isize = 9;
const HTTOP: isize = 12;
const HTTOPLEFT: isize = 13;
const HTTOPRIGHT: isize = 14;
const HTCLOSE: isize = 20;

const SC_MINIMIZE: u32 = 0xF020;
const SC_MAXIMIZE: u32 = 0xF030;
const SC_CLOSE: u32 = 0xF060;
const SC_RESTORE: u32 = 0xF120;

const TME_NONCLIENT: u32 = 0x00000010;

const SM_CYSIZEFRAME: i32 = 33;
const SM_CXPADDEDBORDER: i32 = 92;

const SPI_SETHIGHCONTRAST: u32 = 0x0043;

/// GetClipBox results.
const REGION_ERROR: i32 = 0;
const NULLREGION: i32 = 1;

const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]w32.RECT,
    lppos: ?*anyopaque,
};

pub const WINDOWPLACEMENT = extern struct {
    length: u32,
    flags: u32,
    showCmd: u32,
    ptMinPosition: w32.POINT,
    ptMaxPosition: w32.POINT,
    rcNormalPosition: w32.RECT,
};

const DWMWA_CAPTION_BUTTON_BOUNDS: u32 = 5;
const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;

extern "dwmapi" fn DwmDefWindowProc(hWnd: w32.HWND, msg: u32, wParam: usize, lParam: isize, plResult: *isize) callconv(.winapi) i32;
extern "dwmapi" fn DwmGetWindowAttribute(hwnd: w32.HWND, dwAttribute: u32, pvAttribute: *anyopaque, cbAttribute: u32) callconv(.winapi) i32;
extern "gdi32" fn GetClipBox(hdc: w32.HDC, lprect: *w32.RECT) callconv(.winapi) i32;
extern "user32" fn GetSystemMetricsForDpi(nIndex: i32, dpi: u32) callconv(.winapi) i32;
extern "user32" fn WindowFromPoint(point: w32.POINT) callconv(.winapi) ?w32.HWND;
pub extern "user32" fn GetWindowPlacement(hWnd: w32.HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) i32;
extern "user32" fn SetWindowPlacement(hWnd: w32.HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(.winapi) i32;

test "the button fades end where the hover look ends" {
    const testing = std.testing;
    const ms = std.time.ns_per_ms;
    var fades: Fades = .{};
    try testing.expectEqual(@as(?Fades.Progress, null), fades.progress(.close, 1000 * ms));
    fades.started[Fades.index(.close).?] = 1000 * ms;
    const start = fades.progress(.close, 1000 * ms).?;
    try testing.expectEqual(@as(f32, 0), start.fill);
    // The glyph is back first; the fill a little later.
    const mid = fades.progress(.close, 1000 * ms + anim.motion.duration.faster * ms).?;
    try testing.expectEqual(@as(f32, 1), mid.glyph);
    try testing.expect(mid.fill > 0.4 and mid.fill < 0.6);
    try testing.expectEqual(@as(?Fades.Progress, null), fades.progress(.close, 1000 * ms + anim.motion.duration.fast * ms));
    // Other buttons are not fading.
    try testing.expectEqual(@as(?Fades.Progress, null), fades.progress(.minimize, 1000 * ms));
    fades.cancel(.close);
    try testing.expectEqual(@as(?Fades.Progress, null), fades.progress(.close, 1000 * ms));
    try testing.expectEqual(@as(?usize, null), Fades.index(.none));
}

const TestWindows = struct {
    const alive: w32.HWND = @ptrFromInt(0x1000);
    const gone: w32.HWND = @ptrFromInt(0x2000);

    fn exists(hwnd: w32.HWND) bool {
        return hwnd == alive;
    }

    fn count(locks: *const ActiveLocks, hwnd: w32.HWND) usize {
        return std.mem.count(?w32.HWND, &locks.popups, &[_]?w32.HWND{hwnd});
    }
};

test "activation locks count popups once and forget the ones that went away" {
    const testing = std.testing;
    const exists = TestWindows.exists;
    var locks: ActiveLocks = .{};
    try testing.expect(!locks.heldWith(exists));
    // An anonymous lock counts.
    locks.add(null);
    try testing.expect(locks.heldWith(exists));
    locks.remove(null);
    try testing.expect(!locks.heldWith(exists));
    // Unbalanced unlocks saturate.
    locks.remove(null);
    try testing.expectEqual(@as(u16, 0), locks.others);

    // The same popup locking twice is one lock; its unlock ends it.
    locks.add(TestWindows.alive);
    locks.add(TestWindows.alive);
    try testing.expectEqual(@as(usize, 1), TestWindows.count(&locks, TestWindows.alive));
    try testing.expect(locks.heldWith(exists));
    locks.remove(TestWindows.alive);
    try testing.expect(!locks.heldWith(exists));

    // A popup that went away without unlocking holds nothing and is
    // forgotten.
    locks.add(TestWindows.gone);
    locks.add(TestWindows.alive);
    try testing.expect(locks.heldWith(exists));
    locks.remove(TestWindows.alive);
    try testing.expect(!locks.heldWith(exists));
    locks.pruneWith(exists);
    try testing.expectEqual(@as(usize, 0), TestWindows.count(&locks, TestWindows.gone));

    // More popups than slots still count.
    for (0..locks.popups.len) |i| locks.add(@ptrFromInt(0x3000 + 0x10 * i));
    locks.add(TestWindows.alive);
    try testing.expectEqual(@as(u16, 1), locks.others);
    try testing.expect(locks.heldWith(exists));
    locks.remove(TestWindows.alive);
    try testing.expect(!locks.heldWith(exists));
}

fn testContext(canvas: *d2d.Canvas, tokens: style.Tokens) PaintContext {
    const colors = stripColors(tokens, .{});
    return .{
        .canvas = canvas,
        .tokens = tokens,
        .layout = .{},
        .active = true,
        .translucent = false,
        .strip_fill = colors.strip_fill,
        .strip_text = colors.strip_text,
        .strip_text_inactive = colors.strip_text_inactive,
        .tab_fill = colors.tab_fill,
    };
}

fn gxMocha() style.Tokens {
    return style.Tokens.fromTheme(
        d2d.Color.hex(0x1e1e2e),
        d2d.Color.hex(0xcdd6f4),
        d2d.Color.hex(0xf5e0dc),
        d2d.Color.hex(0x89b4fa),
        d2d.Color.hex(0x89b4fa),
    );
}

test "caption buttons look pressed only while the pointer stays on them" {
    const testing = std.testing;
    var canvas: d2d.Canvas = undefined;
    const tokens = gxMocha();
    const ctx = testContext(&canvas, tokens);

    const plain = lookOf(ctx, .minimize, .{});
    try testing.expectEqual(@as(?d2d.Color, null), plain.fill);
    try testing.expectEqual(tokens.text, plain.glyph);
    // Pressed, then dragged off: plain again.
    try testing.expectEqual(@as(?d2d.Color, null), lookOf(ctx, .minimize, .{ .pressed = true }).fill);
    const hovered = lookOf(ctx, .minimize, .{ .hovered = true });
    const pressed = lookOf(ctx, .minimize, .{ .hovered = true, .pressed = true });
    try testing.expectEqual(tokens.overlay_hover, hovered.fill.?);
    try testing.expectEqual(tokens.overlay_pressed, pressed.fill.?);
    // Pressed is fainter than hovered (Fluent).
    try testing.expect(pressed.fill.?.a < hovered.fill.?.a);

    // The close button is #c42b1c with a white glyph, pressed at 90%.
    const close = lookOf(ctx, .close, .{ .hovered = true });
    try testing.expectEqual(@as(u24, 0xc42b1c), close.fill.?.toHex());
    try testing.expectEqual(@as(u24, 0xffffff), close.glyph.toHex());
    try testing.expect(lookOf(ctx, .close, .{ .hovered = true, .pressed = true }).fill.?.a < 1);

    // Fading out: half the fill, the glyph on its way back.
    const fading = lookOf(ctx, .close, .{ .fade = .{ .fill = 0.5, .glyph = 1 } });
    try testing.expectApproxEqAbs(close.fill.?.a * 0.5, fading.fill.?.a, 1e-6);
    try testing.expectEqual(tokens.text, fading.glyph);
}

test "high contrast caption buttons draw the highlight text on the highlight" {
    const testing = std.testing;
    var canvas: d2d.Canvas = undefined;
    // High Contrast Black.
    const system: style.SystemColors = .{
        .window = d2d.Color.hex(0x000000),
        .window_text = d2d.Color.hex(0xffffff),
        .highlight = d2d.Color.hex(0x1aebff),
        .highlight_text = d2d.Color.hex(0x000000),
        .button_face = d2d.Color.hex(0x000000),
        .button_text = d2d.Color.hex(0xffffff),
        .gray_text = d2d.Color.hex(0x3ff23f),
        .hotlight = d2d.Color.hex(0xffff00),
    };
    const tokens = style.Tokens.fromSystem(system);
    const ctx = testContext(&canvas, tokens);
    // An opaque strip in the window colors, whatever shows behind it.
    const strip = stripColors(tokens, .{ .material = .mica, .under_frame = true, .per_pixel = true, .opacity = 0.3 });
    try testing.expectEqual(system.window, strip.strip_fill);
    try testing.expectEqual(system.window_text, strip.strip_text);

    for ([_]Button{ .minimize, .maximize, .menu, .close }) |button| {
        const look = lookOf(ctx, button, .{ .hovered = true });
        try testing.expectEqual(system.highlight, look.fill.?);
        try testing.expectEqual(system.highlight_text, look.glyph);
        try testing.expect(style.contrast(look.glyph, look.fill.?) >= 4.5);
        const pressed = lookOf(ctx, button, .{ .hovered = true, .pressed = true });
        try testing.expectEqual(system.highlight_text, pressed.glyph);
    }
    try testing.expectEqual(system.window_text, lookOf(ctx, .minimize, .{}).glyph);
}

test "the strip shows the material, the terminals' opacity or nothing" {
    const testing = std.testing;
    const tokens = gxMocha();
    // Solid and opaque.
    const solid = stripColors(tokens, .{});
    try testing.expectEqual(tokens.title_bar, solid.strip_fill);
    try testing.expectEqual(tokens.background, solid.tab_fill);

    const mica = stripColors(tokens, .{ .material = .mica, .under_frame = true, .per_pixel = true, .opacity = 0.3 });
    try testing.expectEqual(@as(f32, 0), mica.strip_fill.a);
    try testing.expectEqual(d2d.Color.white, mica.strip_text);
    // A light Mica (`window-theme = light`) under a dark theme: dark text.
    const light = stripColors(tokens, .{ .material = .tabbed, .under_frame = true, .material_dark = false });
    try testing.expectEqual(@as(f32, 0), light.strip_fill.a);
    try testing.expect(style.contrast(light.strip_text, d2d.Color.white) >= 4.5);
    try testing.expect(style.contrast(light.strip_text, d2d.Color.white) > style.contrast(tokens.text, d2d.Color.white));

    // Acrylic where the terminals are translucent: the title bar at their
    // opacity beneath; without per-pixel composition the bare material.
    const acrylic = stripColors(tokens, .{ .material = .acrylic, .under_frame = true, .per_pixel = true, .opacity = 0.75 });
    try testing.expectEqual(tokens.title_bar.withAlpha(0.75), acrylic.strip_fill);
    const fallback = stripColors(tokens, .{ .material = .acrylic, .under_frame = true, .opacity = 1 });
    try testing.expectEqual(@as(f32, 0), fallback.strip_fill.a);

    // No material under the row (solid, a borderless window), translucent
    // terminals: the strip as translucent, the active tab as they draw it.
    const terminal: d2d.Color = .{ .r = 0.1, .g = 0.1, .b = 0.15, .a = 0.8 };
    const see_through = stripColors(tokens, .{ .material = .mica, .per_pixel = true, .opacity = 0.8, .terminal = terminal });
    try testing.expectEqual(tokens.title_bar.withAlpha(0.8), see_through.strip_fill);
    try testing.expectEqual(terminal, see_through.tab_fill);
}

test "overlaps" {
    const testing = std.testing;
    const a: w32.RECT = .{ .left = 0, .top = 0, .right = 10, .bottom = 10 };
    try testing.expect(overlaps(a, .{ .left = 9, .top = 9, .right = 20, .bottom = 20 }));
    try testing.expect(!overlaps(a, .{ .left = 10, .top = 0, .right = 20, .bottom = 10 }));
    try testing.expect(!overlaps(a, empty_rect));
}

test "Direct2D failure keeps native controls visible without affecting other windows" {
    var failed: Window = undefined;
    failed.is_quick_terminal = false;
    failed.title_bar = .{ .direct2d_failed = true };
    try std.testing.expectEqual(Frame.native, failed.title_bar.frame());
    try std.testing.expectEqual(@as(i32, 0), failed.title_bar.height());
    try std.testing.expect(!failed.title_bar.nativeButtons());
    var healthy: Window = undefined;
    healthy.is_quick_terminal = false;
    healthy.title_bar = .{};
    try std.testing.expectEqual(Frame.custom, healthy.title_bar.frame());
    failed.title_bar.is_fullscreen = true;
    try std.testing.expectEqual(Frame.fullscreen, failed.title_bar.frame());
}
