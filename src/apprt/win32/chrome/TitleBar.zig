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
//! `HTCLOSE`, and the tabs and buttons as `HTCLIENT`. The caption buttons
//! are handled through the non-client mouse messages so DefWindowProc
//! never draws its classic buttons over the row. With a window material
//! the DWM frame extends under the row and DWM draws its own caption
//! buttons there; the title bar then leaves the caption buttons to DWM
//! (`nativeButtons`, `DwmDefWindowProc`) instead of drawing over them.
//!
//! `server` keeps the system caption and puts a tab row below it, `none`
//! drops the caption row (borderless), fullscreen windows show a plain tab
//! row and quick terminals no chrome at all. `toggleDecorations` switches
//! between the configured frame and borderless at runtime.
//!
//! `paint` draws the whole chrome row with Direct2D into a 32bpp DIB with
//! per-pixel alpha and blits it into the window: opaque with the solid
//! material, transparent where the DWM backdrop shows through otherwise
//! (`chrome/Backdrop.zig`). The title bar also owns the chrome tooltip
//! (`ui/Tooltip.zig`), shared with the tab bar, and opens the window menu
//! and the main menu (`ui/Menu.zig`). The owning `Window` embeds this
//! struct as `title_bar`.
//!
//! Popups that keep the window painted as active while they have the focus
//! (`Popup.Options.keep_owner_active`) lock it (`onOwnerActiveLock`); the
//! frame does not follow those locks yet (`ownerActiveLocked`).
//!
//! Sizes, fonts, icons, hit-test rectangles, the canvas DPI and the
//! tooltip follow the window's content scale (`Window.scale`), like the
//! terminals. Only what Windows and DWM draw themselves keeps the real DPI
//! of the window: the resize border (`resizeBandHeight`) and DWM's caption
//! buttons (`nativeButtonBounds`).
const TitleBar = @This();

const std = @import("std");
const configpkg = @import("../../../config.zig");
const i18n = @import("../../../gx/i18n.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const d2d = @import("../ui/d2d.zig");
const style = @import("../ui/style.zig");
const Menu = @import("../ui/Menu.zig");
const tooltips = @import("../ui/Tooltip.zig");
const Backdrop = @import("Backdrop.zig");

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Window style and placement saved when entering fullscreen.
saved_style: u32 = 0,
saved_placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT),

/// The frame configured by `window-decoration`.
decoration: Decoration = .custom,

/// `toggle_window_decorations` hid the decorations (borderless).
decorations_hidden: bool = false,

/// Whether the window is active; the chrome glyphs dim when it is not.
active: bool = true,

/// The title bar button under the mouse and the one being pressed.
hover: Button = .none,
pressed: Button = .none,

/// Whether WM_NCMOUSELEAVE tracking is active.
tracking_nc: bool = false,

/// The Direct2D canvas the chrome row is painted with (created on first
/// paint).
canvas: ?d2d.Canvas = null,

/// The tooltip of the chrome buttons and tabs (its delay timer `TT` runs
/// on the window).
tooltip: Tooltip = .{},

/// How many popups hold the window active (`onOwnerActiveLock`).
owner_active_locks: u16 = 0,

pub const Tooltip = tooltips.Tooltip(TooltipTarget);

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

/// What frames the client area right now.
pub const Frame = enum {
    /// Integrated title bar row with caption buttons.
    custom,
    /// System caption; the chrome row is a plain tab row.
    native,
    /// Native resize borders without a caption.
    borderless,
    fullscreen,
    /// Quick terminal: no chrome.
    popup,
};

/// The buttons of the title bar row (the tab bar has its own).
pub const Button = enum {
    none,
    minimize,
    maximize,
    close,
    menu,

    fn hitCode(self: Button) isize {
        return switch (self) {
            .minimize => HTMINBUTTON,
            .maximize => HTMAXBUTTON,
            .close => HTCLOSE,
            .menu, .none => w32.HTCLIENT,
        };
    }

    fn fromHitCode(code: usize) Button {
        return switch (code) {
            HTMINBUTTON => .minimize,
            HTMAXBUTTON => .maximize,
            HTCLOSE => .close,
            else => .none,
        };
    }
};

/// The chrome row of the window in client pixels.
pub const Layout = struct {
    /// The whole row; empty when the window has no chrome row.
    bar: w32.RECT = empty_rect,
    /// Whether the row has caption buttons (integrated title bar).
    caption: bool = false,
    minimize: w32.RECT = empty_rect,
    maximize: w32.RECT = empty_rect,
    close: w32.RECT = empty_rect,
    menu: w32.RECT = empty_rect,
    /// Where the tab bar lays out its tabs and new-tab buttons.
    tabs: w32.RECT = empty_rect,
    /// Top of the tabs (and the row buttons) inside `bar`.
    content_top: i32 = 0,
    /// Height of the top resize band, 0 when the top edge does not resize.
    resize_band: i32 = 0,
    /// Whether the empty parts of the row drag the window.
    draggable: bool = false,
    scale: f32 = 1.0,

    pub fn height(self: Layout) i32 {
        return self.bar.bottom - self.bar.top;
    }
};

pub const empty_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

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

/// Release the canvas and the tooltip.
pub fn deinit(self: *TitleBar) void {
    self.tooltip.destroy();
    if (self.canvas) |*canvas| canvas.deinit();
    self.canvas = null;
}

/// What frames the client area right now.
pub fn frame(self: *const TitleBar) Frame {
    const win = self.windowConst();
    if (win.is_quick_terminal) return .popup;
    if (self.is_fullscreen) return .fullscreen;
    if (self.decorations_hidden) return .borderless;
    return switch (self.decoration) {
        .custom => .custom,
        .native => .native,
        .borderless => .borderless,
    };
}

/// Whether `WM_NCCALCSIZE` extends the client area over the caption.
pub fn extendsClient(self: *const TitleBar) bool {
    return switch (self.frame()) {
        .custom, .borderless => true,
        .native, .fullscreen, .popup => false,
    };
}

/// Whether the chrome row has caption buttons.
pub fn hasCaptionRow(self: *const TitleBar) bool {
    return self.frame() == .custom;
}

/// Height in pixels of the chrome row at the top of the client area: the
/// integrated title bar, a tab row, or 0.
pub fn height(self: *const TitleBar) i32 {
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

/// Whether the chrome row is drawn transparent over the window material:
/// only where DWM extends the frame, which a fullscreen window has none of.
pub fn translucent(self: *const TitleBar) bool {
    return switch (self.frame()) {
        .custom, .native, .borderless => Backdrop.chromeIsTranslucent(&self.windowConst().app.config),
        .fullscreen, .popup => false,
    };
}

/// Whether DWM draws the caption buttons. Wherever the frame is extended
/// under the title bar (a material shows through it) DWM draws its own
/// caption buttons there, and they cannot be hidden without dropping
/// `WS_SYSMENU`, which Snap (Win+Arrow) needs. The title bar then uses
/// those native buttons (`DwmDefWindowProc`) instead of drawing its own
/// over them.
pub fn nativeButtons(self: *const TitleBar) bool {
    return self.hasCaptionRow() and self.translucent();
}

/// The DWM caption buttons in client coordinates, if DWM draws them. DWM
/// sizes them for the real DPI of the window, so they keep that size when
/// `Window.scale` differs from it.
fn nativeButtonBounds(self: *const TitleBar) ?w32.RECT {
    const hwnd = self.windowConst().hwnd orelse return null;
    var bounds: w32.RECT = undefined;
    if (DwmGetWindowAttribute(hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, &bounds, @sizeOf(w32.RECT)) < 0) return null;
    if (bounds.right <= bounds.left) return null;
    // The bounds are relative to the window rectangle.
    var window_rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &window_rect) == 0) return null;
    var origin = w32.POINT{ .x = 0, .y = 0 };
    _ = w32.ClientToScreen(hwnd, &origin);
    const dx = window_rect.left - origin.x;
    const dy = window_rect.top - origin.y;
    return .{
        .left = bounds.left + dx,
        .top = bounds.top + dy,
        .right = bounds.right + dx,
        .bottom = bounds.bottom + dy,
    };
}

fn isZoomed(self: *const TitleBar) bool {
    const hwnd = self.windowConst().hwnd orelse return false;
    return w32.IsZoomed(hwnd) != 0;
}

/// The chrome row layout for the current client size.
pub fn layout(self: *const TitleBar) Layout {
    const win = self.windowConst();
    const hwnd = win.hwnd orelse return .{};
    const bar_h = self.height();
    if (bar_h <= 0) return .{ .scale = win.scale };
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return .{ .scale = win.scale };

    const s = win.scale;
    const f = self.frame();
    const caption = f == .custom;
    const zoomed = self.isZoomed();
    var lay: Layout = .{
        .bar = .{ .left = 0, .top = 0, .right = client.right, .bottom = bar_h },
        .caption = caption,
        .scale = s,
        .draggable = f != .fullscreen and f != .popup,
        .resize_band = if (self.extendsClient() and !zoomed) self.resizeBandHeight() else 0,
    };

    // Tabs hang from the top margin (below the top resize band of an
    // extended client area) and touch the bottom of the row.
    const top_margin: f32 = if (self.extendsClient()) 8 else 4;
    lay.content_top = style.px(top_margin, s);

    var right = client.right;
    // Next to the caption buttons, the main menu button is centered on
    // them like their glyphs.
    var caption_top: i32 = 0;
    var caption_bottom: i32 = bar_h;
    if (caption) native: {
        if (self.nativeButtons()) {
            const bounds = self.nativeButtonBounds() orelse break :native;
            right = @min(right, bounds.left);
            caption_top = @max(bounds.top, 0);
            caption_bottom = @min(bounds.bottom, bar_h);
            break :native;
        }
        const bw = style.px(style.metrics.caption_button_width, s);
        lay.close = .{ .left = right - bw, .top = 0, .right = right, .bottom = bar_h };
        right -= bw;
        lay.maximize = .{ .left = right - bw, .top = 0, .right = right, .bottom = bar_h };
        right -= bw;
        lay.minimize = .{ .left = right - bw, .top = 0, .right = right, .bottom = bar_h };
        right -= bw;
    }

    // The main menu button, square-ish like the new-tab button.
    const btn_h = style.px(row_button_height, s);
    const btn_w = style.px(menu_button_width, s);
    const btn_top = if (caption)
        caption_top + @divTrunc(caption_bottom - caption_top - btn_h, 2)
    else
        lay.content_top + @divTrunc(bar_h - lay.content_top - btn_h, 2);
    right -= style.px(if (caption) 4 else 6, s);
    lay.menu = .{ .left = right - btn_w, .top = btn_top, .right = right, .bottom = btn_top + btn_h };
    right = lay.menu.left;

    // Keep a strip of empty title bar to drag the window by.
    const drag_reserve: f32 = if (lay.draggable) (if (caption) 40 else 24) else 4;
    const left: f32 = if (caption and !zoomed) 8 else 6;
    lay.tabs = .{
        .left = style.px(left, s),
        .top = lay.content_top,
        .right = @max(style.px(left, s), right - style.px(drag_reserve, s)),
        .bottom = bar_h,
    };
    return lay;
}

/// Height of the row buttons (main menu, new tab) in DIPs.
pub const row_button_height: f32 = 28;
const menu_button_width: f32 = 36;

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
pub const Hit = union(enum) {
    /// Not in the chrome row.
    none,
    /// Empty title bar (drag).
    caption,
    button: Button,
    /// The tab bar (tabs, their close buttons, new tab, profiles).
    tabs,
};

pub fn hitTest(self: *const TitleBar, lay: Layout, x: i32, y: i32) Hit {
    if (lay.height() <= 0 or y < lay.bar.top or y >= lay.bar.bottom or x < 0 or x >= lay.bar.right) return .none;
    if (lay.caption) {
        if (contains(lay.close, x, y)) return .{ .button = .close };
        if (contains(lay.maximize, x, y)) return .{ .button = .maximize };
        if (contains(lay.minimize, x, y)) return .{ .button = .minimize };
    }
    if (contains(lay.menu, x, y)) return .{ .button = .menu };
    if (self.windowConst().tab_bar.hitsSomething(lay, x, y)) return .tabs;
    return .caption;
}

pub fn contains(rect: w32.RECT, x: i32, y: i32) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
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

    // Track activation before DWM gets the message: the glyphs dim while
    // the window is inactive.
    if (msg == WM_NCACTIVATE) {
        const active = wparam != 0 or self.ownerActiveLocked();
        if (active != self.active) {
            self.active = active;
            self.invalidate();
        }
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
        WM_NCACTIVATE => return null,
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
            const button = Button.fromHitCode(wparam);
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
            self.pressed = .none;
            self.invalidate();
            return 0;
        },
        WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK => {
            const button = Button.fromHitCode(wparam);
            if (button == .none) return null;
            self.pressed = button;
            self.tooltip.hide();
            self.invalidate();
            return 0;
        },
        WM_NCLBUTTONUP => {
            const button = Button.fromHitCode(wparam);
            if (button == .none) return null;
            const was_pressed = self.pressed == button;
            self.pressed = .none;
            self.invalidate();
            if (was_pressed) self.performButton(button);
            return 0;
        },
        WM_NCRBUTTONDOWN, WM_NCRBUTTONDBLCLK => {
            if (Button.fromHitCode(wparam) != .none) return 0;
            return null;
        },
        WM_NCRBUTTONUP => {
            if (Button.fromHitCode(wparam) != .none) return 0;
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
    const extends = self.extendsClient();
    if (lay.height() <= 0 and !extends) return null;

    // The default handles the left, right and bottom borders.
    const default = w32.DefWindowProcW(hwnd, WM_NCHITTEST, 0, lparam);
    if (default != w32.HTCLIENT) return default;

    var pt = lparamPoint(lparam);
    _ = w32.ScreenToClient(hwnd, &pt);

    // Caption buttons reach the top edge (like Windows Terminal); the rest
    // of the top edge resizes the window.
    const hit = self.hitTest(lay, pt.x, pt.y);
    switch (hit) {
        .button => |button| if (button != .menu) return button.hitCode(),
        else => {},
    }
    if (lay.resize_band > 0 and pt.y >= 0 and pt.y < lay.resize_band) {
        const corner = lay.resize_band * 2;
        if (pt.x < corner) return HTTOPLEFT;
        if (pt.x >= lay.bar.right - corner) return HTTOPRIGHT;
        return HTTOP;
    }
    return switch (hit) {
        .none, .tabs => w32.HTCLIENT,
        .button => |button| button.hitCode(),
        .caption => if (lay.draggable) HTCAPTION else w32.HTCLIENT,
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

fn setHover(self: *TitleBar, button: Button) void {
    if (self.hover == button) return;
    self.hover = button;
    self.invalidate();
    // Windows shows its own tooltips over HTMINBUTTON, HTMAXBUTTON and
    // HTCLOSE, so the caption buttons get no second one.
    self.setTooltipTarget(switch (button) {
        .none, .minimize, .maximize, .close => .none,
        .menu => .menu,
    });
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
    _ = self.window().tab_bar.onMouseMove(lay, x, y);
    self.setHover(switch (hit) {
        .button => |button| if (button == .menu) .menu else .none,
        else => .none,
    });
    return hit != .none;
}

/// A left-button press in the client area; returns true when the chrome
/// row handled it.
pub fn onLeftButtonDown(self: *TitleBar, x: i32, y: i32) bool {
    const lay = self.layout();
    switch (self.hitTest(lay, x, y)) {
        .none => return false,
        .button => |button| {
            self.pressed = button;
            self.tooltip.hide();
            self.invalidate();
            return true;
        },
        .tabs => {
            self.tooltip.hide();
            self.window().tab_bar.onLeftButtonDown(lay, x, y);
            return true;
        },
        .caption => return true,
    }
}

/// A left-button release in the client area.
pub fn onLeftButtonUp(self: *TitleBar, x: i32, y: i32) bool {
    const pressed = self.pressed;
    if (pressed != .none) {
        self.pressed = .none;
        self.invalidate();
        const released_on_menu = switch (self.hitTest(self.layout(), x, y)) {
            .button => |button| button == .menu,
            else => false,
        };
        if (pressed == .menu and released_on_menu) self.performButton(.menu);
        return true;
    }
    return self.window().tab_bar.onLeftButtonUp(self.layout(), x, y);
}

/// The mouse left the client area.
pub fn onMouseLeave(self: *TitleBar) void {
    if (self.hover == .menu) self.setHover(.none);
    if (self.pressed == .menu) {
        self.pressed = .none;
        self.invalidate();
    }
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
// Activation lock and system changes
// -----------------------------------------------------------------------

/// `Popup.WM_GX_OWNER_ACTIVE_LOCK` reached the window: a popup with
/// `keep_owner_active` is about to take the activation (`locked`), or it
/// hid or lost it. Popups send it from `show` and `WM_MOUSEACTIVATE`
/// (SendMessage), so this must not pump messages. GUI thread. Only counts
/// the locks for now.
pub fn onOwnerActiveLock(self: *TitleBar, locked: bool) void {
    if (locked) {
        self.owner_active_locks +|= 1;
    } else {
        self.owner_active_locks -|= 1;
    }
}

/// Whether a popup holds the window active, so `WM_NCACTIVATE(FALSE)`
/// leaves the frame active. Always false for now.
pub fn ownerActiveLocked(self: *const TitleBar) bool {
    _ = self;
    return false;
}

/// A system broadcast reached the window (`Window.onSystemSettingChange`),
/// after the design tokens read the system colors again (`style.system`):
/// repaint the row when the system colors or the visual style changed
/// (high contrast on or off).
pub fn onSystemSettingChange(self: *TitleBar, change: w32.SystemChange) void {
    switch (change) {
        .sys_colors, .theme => self.invalidate(),
        .setting, .colorization => {},
    }
}

/// The window was resized (WM_SIZE, not minimized): drop the tooltip and
/// repaint the row (maximizing moves the tabs and swaps the maximize
/// glyph).
pub fn onSize(self: *TitleBar) void {
    self.tooltip.hide();
    self.invalidate();
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

/// Paint the chrome row into the window's paint DC: the strip, the tabs,
/// the main menu button and the caption buttons, drawn with Direct2D into
/// a 32bpp DIB (premultiplied alpha, so the backdrop material shows
/// through transparent pixels) and blitted in one go.
pub fn paint(self: *TitleBar, hdc: w32.HDC) void {
    const win = self.window();
    const lay = self.layout();
    const w = lay.bar.right - lay.bar.left;
    const h = lay.height();
    if (w <= 0 or h <= 0) return;

    const factory = win.app.uiFactory() orelse return;
    if (self.canvas == null) self.canvas = d2d.Canvas.init(factory);
    const canvas = &self.canvas.?;

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    var bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
    var bits: ?*anyopaque = null;
    const dib = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = w32.DeleteObject(dib);
    const old_bmp = w32.SelectObject(mem_dc, dib);
    defer _ = w32.SelectObject(mem_dc, old_bmp);

    const rect = w32.RECT{ .left = 0, .top = 0, .right = w, .bottom = h };
    if (!canvas.beginDcAlpha(mem_dc, rect, self.canvasDpi())) return;
    const tokens = style.Tokens.fromConfig(&win.app.config);
    const see_through = self.translucent();
    canvas.clear(if (see_through) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else tokens.title_bar);

    const ctx: PaintContext = .{
        .canvas = canvas,
        .tokens = tokens,
        .layout = lay,
        .active = self.active,
        .translucent = see_through,
    };
    win.tab_bar.paint(ctx);
    self.paintMenuButton(ctx);
    if (lay.caption and !self.nativeButtons()) self.paintCaptionButtons(ctx);
    canvas.end();

    _ = w32.BitBlt(hdc, lay.bar.left, lay.bar.top, w, h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// What the chrome row painters share.
pub const PaintContext = struct {
    canvas: *d2d.Canvas,
    tokens: style.Tokens,
    layout: Layout,
    /// Whether the window is active (inactive glyphs dim).
    active: bool,
    /// Whether the strip is transparent over a backdrop material.
    translucent: bool,

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
        return if (self.active) self.tokens.text else self.tokens.text_disabled;
    }
};

fn paintMenuButton(self: *TitleBar, ctx: PaintContext) void {
    const r = ctx.dipRect(ctx.layout.menu);
    if (r.w <= 0) return;
    const radius = style.metrics.corner_radius / 2;
    if (self.pressed == .menu) {
        ctx.canvas.fillRoundedRect(r, radius, ctx.tokens.overlay_pressed);
    } else if (self.hover == .menu) {
        ctx.canvas.fillRoundedRect(r, radius, ctx.tokens.overlay_hover);
    }
    ctx.canvas.drawIcon(d2d.icons.global_nav, r, 14, ctx.glyphColor());
}

fn paintCaptionButtons(self: *TitleBar, ctx: PaintContext) void {
    const win = self.window();
    const zoomed = if (win.hwnd) |hwnd| w32.IsZoomed(hwnd) != 0 else false;
    const buttons = [_]struct { Button, w32.RECT, u21 }{
        .{ .minimize, ctx.layout.minimize, d2d.icons.minimize },
        .{ .maximize, ctx.layout.maximize, if (zoomed) d2d.icons.restore else d2d.icons.maximize },
        .{ .close, ctx.layout.close, d2d.icons.close },
    };
    for (buttons) |entry| {
        const button, const rect, const glyph = entry;
        const r = ctx.dipRect(rect);
        const hovered = self.hover == button;
        const pressed = self.pressed == button;
        var glyph_color = ctx.glyphColor();
        if (button == .close and (hovered or pressed)) {
            ctx.canvas.fillRect(r, if (pressed) ctx.tokens.close_pressed else ctx.tokens.close_hover);
            glyph_color = ctx.tokens.close_hover_text;
        } else if (pressed) {
            ctx.canvas.fillRect(r, ctx.tokens.overlay_pressed);
        } else if (hovered) {
            ctx.canvas.fillRect(r, ctx.tokens.overlay_hover);
        }
        ctx.canvas.drawIcon(glyph, r, style.metrics.caption_glyph_size, glyph_color);
    }
}

// -----------------------------------------------------------------------
// Tooltip
// -----------------------------------------------------------------------

/// What the tooltip describes.
pub const TooltipTarget = union(enum) {
    none,
    menu,
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
        .new_tab => .{ i18n.tr("New tab"), win.tab_bar.new_tab_rect },
        .profiles => .{ i18n.tr("New Tab with Profile"), win.tab_bar.profile_rect },
        .tab_close => |i| .{ i18n.tr("Close tab"), win.tab_bar.closeRect(lay, i) },
        .tab => |i| .{ win.tab_bar.tooltipText(i, &buf) orelse return, win.tab_bar.tabRect(i) },
    };
    if (text.len == 0) return;
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
    self.invalidate();
}

/// The UI language changed: refresh a visible tooltip and repaint.
pub fn onLanguageChanged(self: *TitleBar) void {
    if (self.tooltip.visible()) self.showTooltip();
    self.invalidate();
}

/// The configuration changed (colors, material): repaint.
pub fn onConfigChange(self: *TitleBar) void {
    self.tooltip.hide();
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
    win.onFrameChanged();
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleDecorations(self: *TitleBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    self.decorations_hidden = !self.decorations_hidden;
    self.tooltip.hide();
    Backdrop.setBorderVisible(hwnd, &win.app.config, self.frame() != .borderless);
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    win.onFrameChanged();
}

/// Apply the configured decoration once the window exists.
pub fn applyDecoration(self: *TitleBar, config: *const configpkg.Config) void {
    self.decoration = Decoration.fromConfig(config.@"window-decoration");
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    if (self.frame() == .borderless) Backdrop.setBorderVisible(hwnd, config, false);
    // Recompute the frame now that WM_NCCALCSIZE reaches this title bar.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE);
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

extern "dwmapi" fn DwmDefWindowProc(hWnd: w32.HWND, msg: u32, wParam: usize, lParam: isize, plResult: *isize) callconv(.winapi) i32;
extern "dwmapi" fn DwmGetWindowAttribute(hwnd: w32.HWND, dwAttribute: u32, pvAttribute: *anyopaque, cbAttribute: u32) callconv(.winapi) i32;
extern "user32" fn GetSystemMetricsForDpi(nIndex: i32, dpi: u32) callconv(.winapi) i32;
extern "user32" fn WindowFromPoint(point: w32.POINT) callconv(.winapi) ?w32.HWND;
pub extern "user32" fn GetWindowPlacement(hWnd: w32.HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) i32;
extern "user32" fn SetWindowPlacement(hWnd: w32.HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(.winapi) i32;
