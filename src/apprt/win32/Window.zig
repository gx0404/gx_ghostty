// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs (each tab a split tree).
//!
//! The Window owns the tab model (split trees, active surfaces, titles,
//! unread flags), split layout and window-level state (DPI scale, size
//! limits, placement) and orchestrates the chrome modules:
//!
//!   - `chrome/TitleBar.zig` (`title_bar`): non-client frame, the
//!     integrated title bar row (caption buttons, main menu button,
//!     tooltip), fullscreen and decorations; gets the first look at every
//!     message and paints the chrome row.
//!   - `chrome/TabBar.zig` (`tab_bar`): the tabs in that row: painting,
//!     hit-testing, drag, context menu, inline rename, unread badges.
//!   - `chrome/Backdrop.zig`: DWM theme, border, material, opacity, blur.
//!   - `ui/ResizeOverlay.zig` (`resize_overlay`): the size overlay.
//!   - `ui/ShortcutNotice.zig` (`shortcut_notice`): the notice about
//!     shortcuts other programs take.
//!   - `ui/Menu.zig`: the main menu, opened through `queueMainMenu`.
//!
//! Closing tabs (`closeTabByIndex`, `closeOtherTabs`, `closeTabsRightOf`,
//! the `close_tab` action) and the window (WM_CLOSE) asks first only when
//! a terminal runs a program (core `needsConfirmQuit`). herdr app mode
//! (`updateAppMode`) hides the tab bar while the only tab runs herdr.
//!
//! The chrome is a single row at the top of the client area
//! (`chromeHeight`); the terminals fill the rest. A new window is placed
//! at about 80% of the work area of the monitor under the cursor
//! (cascading from other windows) unless `window-position-*` or
//! `window-width`/`window-height` say otherwise, and stays cloaked until
//! its first terminal frame is presented (at most `first_frame_timeout_ms`)
//! so it never flashes an unpainted frame.
//!
//! Language changes reach the window through `onLanguageChanged`, DPI
//! changes through `WM_DPICHANGED` and configuration changes through
//! `onConfigChange`.
//!
//! DPI (per-monitor v2, `dist/windows/ghostty.manifest`): only top-level
//! windows get WM_DPICHANGED. `handleDpiChange` rescales the chrome, gives
//! every surface of every tab the new content scale (terminal fonts, find
//! bar, scrollbar, IME position; `Surface.handleDpiChange`), adopts the
//! rect Windows suggests and lays the panes out again. The popups are
//! top-level windows themselves: they get their own WM_DPICHANGED when
//! they land on another monitor (`ui/Popup.zig`), and size themselves
//! with their owner's DPI when shown; those of the chrome (the title bar
//! tooltip, the resize overlay, the menus opened from the title bar)
//! follow `scale` instead (`Popup.setOwnerScale`). `WM_GHOSTTY_SIMULATE_DPI`
//! runs the same path without a monitor of another DPI.
//!
//! Rendering stays live in the modal move/size loop: the surfaces render
//! on their own threads, and a live resize waits once per layout for the
//! panes' first frames at the new size (`layoutSplits`). After a resume
//! (WM_POWERBROADCAST) or a display change (WM_DISPLAYCHANGE) the
//! terminals draw a complete new frame (`refreshRenderers`).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const gx = @import("../../gx/main.zig");

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");
const Backdrop = @import("chrome/Backdrop.zig");
const TabBar = @import("chrome/TabBar.zig");
const TitleBar = @import("chrome/TitleBar.zig");
const Dialogs = @import("ui/Dialogs.zig");
const Menu = @import("ui/Menu.zig");
const ResizeOverlay = @import("ui/ResizeOverlay.zig");
const ShortcutNotice = @import("ui/ShortcutNotice.zig");
const style = @import("ui/style.zig");
const Settings = @import("ui/Settings.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
pub const MAX_TABS: usize = 64;

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab split trees owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_trees: [MAX_TABS]SplitTree(Surface) = undefined,

/// The currently focused surface within each tab.
tab_active_surface: [MAX_TABS]*Surface = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Content scale (DPI / 96.0) of the chrome and the terminals, from the
/// last WM_DPICHANGED (or `WM_GHOSTTY_SIMULATE_DPI`). Lay out and draw
/// with it, not with `GetDpiForWindow`.
scale: f32 = 1.0,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [MAX_TABS][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [MAX_TABS]u16 = undefined,

/// Whether each tab received output (or rang the bell) since it was last
/// the active tab (the tab bar shows a badge).
tab_unread: [MAX_TABS]bool = [_]bool{false} ** MAX_TABS,

/// Explicit top-level window title override. Null follows the active tab.
window_title_override_len: ?u16 = null,
window_title_override: [256]u16 = undefined,

/// Title bar / non-client frame (see chrome/TitleBar.zig).
title_bar: TitleBar = .{},

/// Tab bar (see chrome/TabBar.zig).
tab_bar: TabBar = .{},

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Surface).Node.Handle = .root,
drag_split_layout: SplitTree(Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

/// Transient "columns × rows" overlay shown while resizing.
resize_overlay: ResizeOverlay = .{},

/// The notice about default shortcuts other programs take.
shortcut_notice: ShortcutNotice = .{},

/// Where the main menu queued by `queueMainMenu` opens (null: below the
/// chrome at the left edge).
main_menu_anchor: ?w32.POINT = null,

/// Hides the tab bar regardless of `window-show-tab-bar` (see
/// `setTabBarSuppressed`).
tab_bar_suppressed: bool = false,

/// Whether the window is in herdr app mode (see `updateAppMode`).
app_mode: bool = false,

/// Whether the herdr app mode timer (`app_mode_timer_id`) runs.
app_mode_timer: bool = false,

/// The window is shown but cloaked until its first frame (see
/// `showWhenReady`); the surface whose frame it waits for and since when.
first_frame_surface: ?*Surface = null,
first_frame_since_ms: u64 = 0,

/// Whether `window-position-x/-y` placed the window (no re-centering).
position_configured: bool = false,

/// The terminal size from `window-width`/`window-height` (`initial_size`,
/// DIPs), restored by `reset_window_size`.
initial_content_size: ?[2]u32 = null,

/// Whether the window has been shown (`showWhenReady`).
shown: bool = false,

/// True while `layoutSplits` moves the panes: a pane resized during a
/// live resize then leaves waiting for its new frame to the window.
laying_out: bool = false,

/// Posted by `queueMainMenu`; opens the main menu.
const WM_APP_MAIN_MENU: u32 = w32.WM_APP + 20;

/// Posted by `closeTabMode`: wparam is the `apprt.action.CloseTabMode`,
/// lparam the core id of the surface whose tab it refers to.
const WM_APP_CLOSE_TAB: u32 = w32.WM_APP + 0x61;

/// The timer that re-checks herdr app mode while the window has one tab.
const app_mode_timer_id: usize = 0x4844; // 'HD'
const app_mode_interval_ms: u32 = 1500;

/// The most terminals of a tab whose processes the app mode check reads.
const app_mode_max_terminals = 32;

/// Polls for the first frame of a new window (`showWhenReady`).
const FIRST_FRAME_TIMER_ID: usize = 0x4646; // 'FF'
const first_frame_poll_ms: u32 = 10;
/// Show the window even without a frame after this long.
pub const first_frame_timeout_ms: u64 = 300;

/// Drives the tab bar's unread badges and program labels.
const CHROME_TIMER_ID: usize = 0x4348; // 'CH'
const chrome_timer_ms: u32 = 1000;

/// Share of the monitor work area a new window covers.
const default_size_ratio: f32 = 0.8;
/// Offset between cascaded windows in DIPs.
const cascade_step: f32 = 30;

/// Test-only message: SendMessage(window, WM_GHOSTTY_SIMULATE_DPI, dpi, 0)
/// runs the WM_DPICHANGED handling for `dpi` with the window rect scaled
/// around its center, as Windows suggests it, so the DPI change path can
/// be exercised without a monitor of another DPI. The windows themselves
/// keep their real DPI (`GetDpiForWindow`). Returns 1 when handled.
pub const WM_GHOSTTY_SIMULATE_DPI: u32 = w32.WM_USER + 0x47;

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
};

/// Called from App.config_change so the chrome tracks live config
/// reloads: theme colors, border, material, decorations and tab bar.
pub fn onConfigChange(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const config = &self.app.config;
    Backdrop.onConfigChange(hwnd, config);
    if (!self.is_quick_terminal) {
        const decoration = TitleBar.Decoration.fromConfig(config.@"window-decoration");
        if (decoration != self.title_bar.decoration) self.title_bar.applyDecoration(config);
    }
    self.title_bar.onConfigChange();
    self.onFrameChanged();
    self.updateAppMode();
}

/// The UI language changed: rebuild menus and repaint the chrome and the
/// popups of every surface.
pub fn onLanguageChanged(self: *Window) void {
    Menu.onLanguageChanged();
    self.title_bar.onLanguageChanged();
    self.tab_bar.onLanguageChanged();
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| entry.view.onLanguageChanged();
    }
    self.shortcut_notice.reposition();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };

    const window_style = TitleBar.windowStyle(&app.config, options.is_quick_terminal);

    // Quick terminals are positioned by QuickTerminal.calculateRects.
    // Others start centered at 80% of the work area (`initialRect`).
    // Honor an explicit configured window position only when BOTH
    // coordinates are set; a partial config falls back to the default.
    var rect = w32.RECT{ .left = w32.CW_USEDEFAULT, .top = w32.CW_USEDEFAULT, .right = 800, .bottom = 600 };
    if (!options.is_quick_terminal) {
        var position: ?w32.POINT = null;
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| position = .{ .x = px, .y = py };
        }
        self.position_configured = position != null;
        rect = initialRect(position);
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        window_style.ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        window_style.style,
        rect.left,
        rect.top,
        if (options.is_quick_terminal) rect.right else rect.right - rect.left,
        if (options.is_quick_terminal) rect.bottom else rect.bottom - rect.top,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Keep the window invisible to the user until its first frame is
    // presented (`showWhenReady`), so it never shows an unpainted frame.
    if (!options.is_quick_terminal) setCloaked(hwnd, true);

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    Backdrop.apply(hwnd, &app.config, .{ .force_opaque = options.force_opaque });

    // Query DPI scale (the window was created on its monitor already).
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    if (!options.is_quick_terminal) {
        // WM_NCCALCSIZE reaches the title bar from now on.
        self.title_bar.applyDecoration(&app.config);
        _ = self.tab_bar.updateVisibility();
        self.applyFrameMargins();
        if (!self.position_configured) self.cascade();
        _ = w32.SetTimer(hwnd, CHROME_TIMER_ID, chrome_timer_ms, null);
    }

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// The rectangle (screen pixels) of a new window: 80% of the work area of
/// the monitor under the cursor (or under `position`), centered there or
/// at `position`.
fn initialRect(position: ?w32.POINT) w32.RECT {
    var anchor: w32.POINT = .{ .x = 0, .y = 0 };
    if (position) |p| {
        anchor = p;
    } else if (w32.GetCursorPos_(&anchor) == 0) {
        anchor = .{ .x = 0, .y = 0 };
    }
    const work = workAreaAt(anchor);
    const work_w = work.right - work.left;
    const work_h = work.bottom - work.top;
    const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(work_w)) * default_size_ratio));
    const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(work_h)) * default_size_ratio));
    if (position) |p| return .{ .left = p.x, .top = p.y, .right = p.x + w, .bottom = p.y + h };
    const x = work.left + @divTrunc(work_w - w, 2);
    const y = work.top + @divTrunc(work_h - h, 2);
    return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
}

/// The work area of the monitor nearest to `pt`.
fn workAreaAt(pt: w32.POINT) w32.RECT {
    var mi: w32.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST)) |monitor| {
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) return mi.rcWork;
    }
    return .{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
}

/// The work area of the monitor the window is on.
fn workArea(hwnd: w32.HWND) w32.RECT {
    var mi: w32.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(w32.MONITORINFO);
    const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
    if (w32.GetMonitorInfoW(monitor, &mi) != 0) return mi.rcWork;
    return .{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
}

/// Center the window on its work area at its current size and step it
/// down-right past other windows already sitting there.
fn cascade(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) == 0) return;
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    const work = workArea(hwnd);
    const center_x = work.left + @divTrunc(work.right - work.left - w, 2);
    const center_y = work.top + @divTrunc(work.bottom - work.top - h, 2);
    var x = center_x;
    var y = center_y;
    const step = style.px(cascade_step, self.scale);
    var tries: usize = 0;
    while (tries < 64 and self.positionTaken(x, y, @divTrunc(step, 2))) : (tries += 1) {
        x += step;
        y += step;
        if (x + w > work.right or y + h > work.bottom) {
            x = center_x;
            y = center_y;
            break;
        }
    }
    if (x != rect.left or y != rect.top) {
        _ = w32.SetWindowPos(hwnd, null, x, y, 0, 0, w32.SWP_NOZORDER | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE);
    }
}

/// Whether another visible window has its top-left corner near (x, y).
fn positionTaken(self: *const Window, x: i32, y: i32, tolerance: i32) bool {
    for (self.app.windows.items) |other| {
        if (other == self) continue;
        const h = other.hwnd orelse continue;
        if (w32.IsWindowVisible_(h) == 0) continue;
        var r: w32.RECT = undefined;
        if (w32.GetWindowRect(h, &r) == 0) continue;
        if (@abs(r.left - x) <= tolerance and @abs(r.top - y) <= tolerance) return true;
    }
    return false;
}

/// The terminal size `window-width`/`window-height` ask for (the
/// `initial_size` action, in DIPs). Like a GTK default size it only sizes
/// the window before it is shown (clamped to the work area and centered
/// again unless the position is configured); later updates (font size
/// changes) only change what `reset_window_size` restores.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    self.initial_content_size = .{ width, height };
    if (!self.shown) self.applyContentSize(width, height, !self.position_configured);
}

/// Restore the size the window started with (`reset_window_size`).
pub fn resetWindowSize(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.initial_content_size) |size| {
        self.applyContentSize(size[0], size[1], false);
        return;
    }
    if (self.is_quick_terminal or self.title_bar.is_fullscreen) return;
    if (w32.IsZoomed(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) == 0) return;
    const default = initialRect(.{ .x = rect.left, .y = rect.top });
    _ = w32.SetWindowPos(hwnd, null, 0, 0, default.right - default.left, default.bottom - default.top, w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE);
}

fn applyContentSize(self: *Window, width: u32, height: u32, recenter: bool) void {
    const hwnd = self.hwnd orelse return;
    if (self.is_quick_terminal or self.title_bar.is_fullscreen) return;
    if (w32.IsZoomed(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
    var window_rect: w32.RECT = undefined;
    var client: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &window_rect) == 0) return;
    if (w32.GetClientRect(hwnd, &client) == 0) return;
    const nc_w = (window_rect.right - window_rect.left) - (client.right - client.left);
    const nc_h = (window_rect.bottom - window_rect.top) - (client.bottom - client.top);
    const work = workArea(hwnd);
    const content_w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * self.scale));
    const content_h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * self.scale));
    const w = @min(content_w + nc_w, work.right - work.left);
    const h = @min(content_h + self.chromeHeight() + nc_h, work.bottom - work.top);
    _ = w32.SetWindowPos(hwnd, null, 0, 0, w, h, w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE);
    if (recenter) self.cascade();
}

/// Cloak or uncloak the window (DWMWA_CLOAK): a cloaked window is shown
/// and painted as usual but DWM keeps it off the screen.
fn setCloaked(hwnd: w32.HWND, cloaked: bool) void {
    const value: u32 = @intFromBool(cloaked);
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, @ptrCast(&value), @sizeOf(u32));
}

const DWMWA_CLOAK: u32 = 13;

/// Show the (cloaked) window and uncloak it once `surface` presented a
/// frame, or after `first_frame_timeout_ms`.
fn showWhenReady(self: *Window, surface: *Surface) void {
    const hwnd = self.hwnd orelse return;
    // Wait for a frame presented after the window is shown, not one
    // drawn into the hidden window.
    if (surface.frame_event) |event| _ = w32.ResetEvent(event);
    self.shown = true;
    _ = w32.ShowWindow(hwnd, if (self.app.config.maximize) SW_SHOWMAXIMIZED else w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);
    self.first_frame_surface = surface;
    self.first_frame_since_ms = GetTickCount64();
    _ = w32.SetTimer(hwnd, FIRST_FRAME_TIMER_ID, first_frame_poll_ms, null);
}

/// WM_TIMER for `showWhenReady`.
fn checkFirstFrame(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const surface = self.first_frame_surface orelse {
        _ = w32.KillTimer(hwnd, FIRST_FRAME_TIMER_ID);
        return;
    };
    const elapsed = GetTickCount64() -| self.first_frame_since_ms;
    const drawn = if (surface.frame_event) |event|
        w32.WaitForSingleObject(event, 0) == w32.WAIT_OBJECT_0
    else
        true;
    if (!drawn and elapsed < first_frame_timeout_ms) return;
    _ = w32.KillTimer(hwnd, FIRST_FRAME_TIMER_ID);
    self.first_frame_surface = null;
    setCloaked(hwnd, false);
    log.debug("window shown after {d}ms first_frame={}", .{ elapsed, drawn });
}

const SW_SHOWMAXIMIZED: i32 = 3;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// Extend the DWM frame under the chrome row when the window material
/// shows through it (`Backdrop.extendFrame`).
pub fn applyFrameMargins(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    Backdrop.extendFrame(hwnd, &self.app.config, if (self.title_bar.translucent()) self.chromeHeight() else 0);
}

/// The frame changed (fullscreen, decorations, configuration): update the
/// tab visibility, the DWM frame and the layout, and repaint.
pub fn onFrameChanged(self: *Window) void {
    _ = self.tab_bar.updateVisibility();
    self.applyFrameMargins();
    self.layoutSplits();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Handle WM_DPICHANGED, which only top-level windows receive: adopt the
/// suggested window rect, rescale the window chrome, and tell every
/// surface (in every tab) about its new content scale.
fn handleDpiChange(self: *Window, dpi: u32, suggested: *const w32.RECT) void {
    if (dpi == 0) return;
    self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.title_bar.onDpiChanged();

    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| entry.view.handleDpiChange(dpi);
    }

    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowPos(
            hwnd,
            null,
            suggested.left,
            suggested.top,
            suggested.right - suggested.left,
            suggested.bottom - suggested.top,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
        );
    }

    // The new rect can have the same size in pixels, in which case no
    // WM_SIZE arrives to lay the surfaces out again. The chrome row and
    // the DWM frame under it scale with the DPI.
    self.applyFrameMargins();
    self.layoutSplits();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// The rect Windows would suggest for a move to `dpi`: the window rect
/// scaled from the current DPI around its center (`WM_GHOSTTY_SIMULATE_DPI`).
fn simulatedDpiRect(self: *Window, dpi: u32) ?w32.RECT {
    const hwnd = self.hwnd orelse return null;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) == 0) return null;
    const ratio = @as(f32, @floatFromInt(dpi)) / (self.scale * 96.0);
    const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.right - rect.left)) * ratio));
    const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.bottom - rect.top)) * ratio));
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    return .{
        .left = cx - @divTrunc(w, 2),
        .top = cy - @divTrunc(h, 2),
        .right = cx - @divTrunc(w, 2) + w,
        .bottom = cy - @divTrunc(h, 2) + h,
    };
}

/// Resize the window so that `surface` gets the requested size in points
/// (CSI 8 t). A zero dimension keeps the current one. Ignored for split,
/// maximized, fullscreen and quick terminal windows.
pub fn resizeForSurface(
    self: *Window,
    surface: *Surface,
    size: apprt.action.ResizeWindow,
) bool {
    const hwnd = self.hwnd orelse return false;
    const surface_hwnd = surface.hwnd orelse return false;
    if (self.title_bar.is_fullscreen or self.is_quick_terminal) return false;
    if (w32.IsZoomed(hwnd) != 0) return false;
    const tab = self.findTabIndex(surface) orelse return false;
    if (self.tab_trees[tab].isSplit()) return false;

    var surface_rect: w32.RECT = undefined;
    var window_rect: w32.RECT = undefined;
    if (w32.GetClientRect(surface_hwnd, &surface_rect) == 0) return false;
    if (w32.GetWindowRect(hwnd, &window_rect) == 0) return false;

    const current_w = surface_rect.right - surface_rect.left;
    const current_h = surface_rect.bottom - surface_rect.top;
    const want_w: i32 = if (size.width == 0) current_w else @intFromFloat(
        @round(@as(f32, @floatFromInt(size.width)) * surface.scale),
    );
    const want_h: i32 = if (size.height == 0) current_h else @intFromFloat(
        @round(@as(f32, @floatFromInt(size.height)) * surface.scale),
    );

    _ = w32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        window_rect.right - window_rect.left + want_w - current_w,
        window_rect.bottom - window_rect.top + want_h - current_h,
        w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE,
    );
    return true;
}

/// Deinitialize the Window: close all tabs, delete fonts, destroy HWND.
pub fn deinit(self: *Window) void {
    Settings.onWindowDestroyed(self);

    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    // Delete the tab bar fonts and the title bar canvas and tooltip.
    self.tab_bar.deinit();
    self.title_bar.deinit();
    self.resize_overlay.deinit();
    self.shortcut_notice.deinit();

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Height of the chrome above the terminals: the single chrome row (the
/// integrated title bar with the tabs, or a plain tab row).
pub fn chromeHeight(self: *const Window) i32 {
    return self.title_bar.height();
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the chrome height from the top.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.chromeHeight();
    return rect;
}

/// Returns the currently active Surface, or null if there are no tabs.
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}

/// Give keyboard focus to the active surface of the active tab.
pub fn focusActiveSurface(self: *Window) void {
    if (self.getActiveSurface()) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}

/// Perform a binding action on behalf of the window's chrome (menus,
/// buttons): on the active surface, or app-scoped when there is none.
pub fn performBindingAction(self: *Window, action: @import("../../input.zig").Binding.Action) void {
    if (self.getActiveSurface()) |surface| {
        if (surface.core_surface_ready) {
            _ = surface.core_surface.performBindingAction(action) catch |err| {
                log.err("binding action failed action={t} err={}", .{ action, err });
            };
            return;
        }
    }
    if (action.scoped(.app)) |app_action| {
        self.app.core_app.performAction(self.app, app_action) catch |err| {
            log.err("binding action failed action={t} err={}", .{ action, err });
        };
    }
}

/// Open the main menu (`Menu.showMainMenu`) once the current message has
/// been handled, at `anchor` in screen coordinates or below the chrome.
/// The menu runs a modal loop, which must not run inside a core callback
/// such as a key binding. Returns false if the request could not be queued.
pub fn queueMainMenu(self: *Window, anchor: ?w32.POINT) bool {
    const hwnd = self.hwnd orelse return false;
    if (self.closing) return false;
    self.main_menu_anchor = anchor;
    return w32.PostMessageW(hwnd, WM_APP_MAIN_MENU, 0, 0) != 0;
}

/// Alt+Space (without Ctrl, Shift or Win) opens the window menu of the
/// window that owns `msg.hwnd`, like in every Windows app, unless a
/// keybind uses alt+space. The message loop calls this before
/// dispatching keys; returns true when the key was used.
pub fn handleSystemMenuKey(app: *App, msg: *const w32.MSG) bool {
    if (msg.message != w32.WM_SYSKEYDOWN or (msg.wParam & 0xFFFF) != w32.VK_SPACE) return false;
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) return false;
    const target = msg.hwnd orelse return false;
    const root = GetAncestor(target, GA_ROOT) orelse return false;
    const set = &app.config.keybind.set;
    const mods: input.Mods = .{ .alt = true };
    if (set.get(.{ .key = .{ .physical = .space }, .mods = mods }) != null or
        set.get(.{ .key = .{ .unicode = ' ' }, .mods = mods }) != null) return false;
    for (app.windows.items) |window| {
        if (window.hwnd != root or window.closing) continue;
        window.title_bar.openSystemMenuFromKeyboard();
        return true;
    }
    return false;
}

const input = @import("../../input.zig");
const GA_ROOT: u32 = 2;
extern "user32" fn GetAncestor(hwnd: w32.HWND, gaFlags: u32) callconv(.winapi) ?w32.HWND;

/// Find the tab index containing a given surface.
/// Checks tab_active_surface first, then scans all trees.
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a surface in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}

/// Everything the window keeps per tab, for moving tabs between slots.
const TabSlot = struct {
    tree: SplitTree(Surface),
    active_surface: *Surface,
    title: [256]u16,
    title_len: u16,
    unread: bool,
};

fn getSlot(self: *const Window, i: usize) TabSlot {
    return .{
        .tree = self.tab_trees[i],
        .active_surface = self.tab_active_surface[i],
        .title = self.tab_titles[i],
        .title_len = self.tab_title_lens[i],
        .unread = self.tab_unread[i],
    };
}

fn setSlot(self: *Window, i: usize, slot: TabSlot) void {
    self.tab_trees[i] = slot.tree;
    self.tab_active_surface[i] = slot.active_surface;
    self.tab_titles[i] = slot.title;
    self.tab_title_lens[i] = slot.title_len;
    self.tab_unread[i] = slot.unread;
}

/// Copy tab slot `src` over slot `dst`.
fn copySlot(self: *Window, dst: usize, src: usize) void {
    self.setSlot(dst, self.getSlot(src));
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithOptions(.{ .context = .tab });
}

pub const AddTabOptions = Surface.InitOptions;

/// Add a tab with per-surface configuration overrides.
pub fn addTabWithOptions(self: *Window, options: AddTabOptions) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.tab_bar.cancelRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.initWithOptions(self.app, self, options);
    // After surface.init succeeds, create the SplitTree which takes ownership
    // via ref(). If this fails, we manually clean up.
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees surface

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) self.copySlot(i, i - 1);
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_unread[pos] = false;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is
        // ready, uncloaking it with the first frame. Quick terminal
        // windows are shown by QuickTerminal.animateIn() instead.
        self.active_tab = pos;
        self.updateTabBarVisibility();
        if (!self.is_quick_terminal) self.showWhenReady(surface);
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.updateAppMode();
    return surface;
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.removeTab(idx);
}

/// Close the tab at `idx` on behalf of the user (tab bar, menus, the
/// `close_tab` action): asks first when one of its terminals runs a
/// program (core `needsConfirmQuit`).
pub fn closeTabByIndex(self: *Window, idx: usize) void {
    self.closeTabs(.{ .one = idx });
}

/// Close every tab except the one at `keep`, asking first like
/// `closeTabByIndex`.
pub fn closeOtherTabs(self: *Window, keep: usize) void {
    self.closeTabs(.{ .all_but = keep });
}

/// Close every tab after the one at `idx`, asking first like
/// `closeTabByIndex`.
pub fn closeTabsRightOf(self: *Window, idx: usize) void {
    self.closeTabs(.{ .right_of = idx });
}

/// Tabs to close together (`closeTabs`).
const TabSelection = union(enum) {
    one: usize,
    all_but: usize,
    right_of: usize,

    fn contains(self: TabSelection, idx: usize) bool {
        return switch (self) {
            .one => |i| idx == i,
            .all_but => |i| idx != i,
            .right_of => |i| idx > i,
        };
    }
};

/// Close the `selection` tabs, after one confirmation listing the busy
/// processes when a terminal in any of them runs a program (core
/// `needsConfirmQuit`, which with the GX idle-process check lets idle
/// shells close without asking; see `CloseCheck`). The dialog's modal
/// loop keeps dispatching messages, which can close tabs or this whole
/// window, so the tabs are found again by a terminal's core id afterwards.
fn closeTabs(self: *Window, selection: TabSelection) void {
    const hwnd = self.hwnd orelse return;
    var ids: [MAX_TABS]u64 = undefined;
    var count: usize = 0;
    var check: CloseCheck = .init(self.app.core_app.alloc);
    defer check.deinit();
    for (0..self.tab_count) |i| {
        if (!selection.contains(i)) continue;
        ids[count] = self.tab_active_surface[i].core_surface.id;
        count += 1;
        check.tab(self, i);
    }
    if (count == 0) return;

    if (check.needed) {
        const choice = if (count == 1)
            Dialogs.confirmCloseTab(hwnd, check.processes.items)
        else
            Dialogs.confirmCloseTabs(hwnd, check.processes.items);
        if (choice != .accept or !isAlive(hwnd, self)) return;
    }

    for (ids[0..count]) |id| {
        if (self.findTabBySurfaceId(id)) |idx| self.removeTab(idx);
    }
}

/// The index of the tab with the terminal whose core surface id is `id`.
fn findTabBySurfaceId(self: *Window, id: u64) ?usize {
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view.core_surface_initialized and entry.view.core_surface.id == id) return i;
        }
    }
    return null;
}

/// Whether `hwnd` is still the live window of `window`, e.g. after a modal
/// dialog. `window` is not dereferenced: it may have been freed.
fn isAlive(hwnd: w32.HWND, window: *const Window) bool {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    return userdata != 0 and @as(usize, @bitCast(userdata)) == @intFromPtr(window);
}

/// Remove the tab at `idx` without asking, deinitializing its split tree.
fn removeTab(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.tab_bar.cancelRename();
    var tree = self.tab_trees[idx];
    tree.deinit(); // This unrefs all surfaces → Surface.unref frees when ref_count=0
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) self.copySlot(i, i + 1);
    self.tab_count -= 1;
    if (self.tab_count == 0) {
        self.closing = true;
        self.setAppModeTimer(false);
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    // The tab bar stays visible with `window-show-tab-bar = always`, so
    // nothing else repaints it without the removed tab.
    self.invalidateTabBar();
    self.updateAppMode();
}

/// Collects whether closing some terminals needs a confirmation and the
/// processes that make it so.
const CloseCheck = struct {
    arena: std.heap.ArenaAllocator,
    processes: std.ArrayList([]const u8) = .empty,
    needed: bool = false,

    fn init(alloc: Allocator) CloseCheck {
        return .{ .arena = .init(alloc) };
    }

    fn deinit(self: *CloseCheck) void {
        self.arena.deinit();
    }

    fn surface(self: *CloseCheck, s: *Surface) void {
        if (!s.core_surface_ready or !s.core_surface.needsConfirmQuit()) return;
        self.needed = true;
        s.appendBusyProcesses(self.arena.allocator(), &self.processes);
    }

    fn tab(self: *CloseCheck, window: *Window, index: usize) void {
        var it = window.tab_trees[index].iterator();
        while (it.next()) |entry| self.surface(entry.view);
    }
};

/// The `close_tab` action: close the tab of `surface` (`this`, all of its
/// splits), the other tabs or the tabs to its right. The core performs it
/// inside a key binding, so the confirmation and the close run from the
/// message loop (`WM_APP_CLOSE_TAB`).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    const hwnd = self.hwnd orelse return;
    if (!surface.core_surface_initialized) return;
    _ = w32.PostMessageW(
        hwnd,
        WM_APP_CLOSE_TAB,
        @intCast(@intFromEnum(mode)),
        @bitCast(surface.core_surface.id),
    );
}

/// Handle `WM_APP_CLOSE_TAB` (see `closeTabMode`).
fn onCloseTabRequest(self: *Window, wparam: usize, lparam: isize) void {
    const mode = std.enums.fromInt(apprt.action.CloseTabMode, wparam) orelse return;
    const idx = self.findTabBySurfaceId(@bitCast(lparam)) orelse return;
    switch (mode) {
        .this => self.closeTabByIndex(idx),
        .other => self.closeOtherTabs(idx),
        .right => self.closeTabsRightOf(idx),
    }
}

/// Close a single surface within a split tree. If it's the last surface
/// in the tab, close the entire tab instead.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse {
        log.debug("closeSplitSurface: surface not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitSurface: not split, closing whole tab", .{});
        self.closeTab(surface);
        return;
    }

    const handle = self.findHandle(tab, surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the surface pointer from the next handle before we modify the tree.
    const next_surface: ?*Surface = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitSurface: has_next={}", .{next_surface != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    log.debug("closeSplitSurface: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    if (next_surface) |ns| {
        log.debug("closeSplitSurface: focusing next surface", .{});
        self.tab_active_surface[tab] = ns;
        self.layoutSplits();
        if (ns.hwnd) |h| _ = w32.SetFocus(h);
        self.updateAppMode();
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.removeTab(tab);
    }
}

/// Switch to the tab at the given index.
/// Set the visibility (occlusion) of every surface in the active tab. Used on
/// window minimize/restore so the renderer stops rebuilding frames while the
/// window is minimized.
fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| entry.view.setVisible(visible);
}

/// Make every visible terminal draw a complete new frame (see
/// `Surface.refreshRenderer`), e.g. after the system resumed.
pub fn refreshRenderers(self: *Window) void {
    if (self.active_tab >= self.tab_count) return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| entry.view.refreshRenderer();
}

/// Move the screen-positioned popups of every terminal (scrollbars, find
/// bars) after the window moved, in all tabs so a hidden tab doesn't show
/// a stale position when activated.
fn repositionPopups(self: *Window) void {
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| entry.view.repositionPopups();
    }
    self.shortcut_notice.reposition();
}

pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.tab_bar.cancelRename();
    // Clear any in-progress tab drag
    self.tab_bar.cancelDrag();
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(false);
            if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    self.active_tab = idx;
    self.tab_unread[idx] = false;
    const surface = self.tab_active_surface[idx];
    self.layoutSplits();
    if (surface.hwnd) |h| _ = w32.SetFocus(h);
    self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Layout split panes for the active tab. The panes move in one
/// DeferWindowPos batch, so they resize together instead of one after the
/// other; during a live resize the window then waits once for all of them
/// to present a frame at the new size.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    var panes: PaneLayout = .{};
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                panes.add(entry.view, rect);
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
    } else {
        self.layoutNode(&panes, tree, .root, rect);
    }

    self.laying_out = true;
    panes.apply();
    self.laying_out = false;
    panes.awaitResizeFrames();
    if (tree.zoomed != null) return;

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
}

fn layoutNode(self: *Window, panes: *PaneLayout, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| panes.add(view, rect),
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(panes, tree, s.left, left_rect);
                self.layoutNode(panes, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(panes, tree, s.left, top_rect);
                self.layoutNode(panes, tree, s.right, bottom_rect);
            }
        },
    }
}

/// The visible panes of one layout pass and where they go.
const PaneLayout = struct {
    const capacity = 64;

    surfaces: [capacity]*Surface = undefined,
    rects: [capacity]w32.RECT = undefined,
    len: usize = 0,

    fn add(self: *PaneLayout, surface: *Surface, rect: w32.RECT) void {
        if (self.len == capacity) {
            surface.setVisible(true);
            place(surface, rect);
            return;
        }
        self.surfaces[self.len] = surface;
        self.rects[self.len] = rect;
        self.len += 1;
    }

    const flags = w32.SWP_NOZORDER | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW;

    /// Mark the panes visible, then move and show them in one batch, or
    /// one by one when the batch fails.
    fn apply(self: *const PaneLayout) void {
        const surfaces = self.surfaces[0..self.len];
        const rects = self.rects[0..self.len];
        for (surfaces) |surface| surface.setVisible(true);

        batch: {
            var hdwp = w32.BeginDeferWindowPos(@intCast(self.len)) orelse break :batch;
            for (surfaces, rects) |surface, rect| {
                const hwnd = surface.hwnd orelse continue;
                // A failed DeferWindowPos abandons the whole batch.
                hdwp = w32.DeferWindowPos(hdwp, hwnd, null, rect.left, rect.top, width(rect), height(rect), flags) orelse
                    break :batch;
            }
            if (w32.EndDeferWindowPos(hdwp) != 0) return;
        }
        for (surfaces, rects) |surface, rect| place(surface, rect);
    }

    fn place(surface: *Surface, rect: w32.RECT) void {
        const hwnd = surface.hwnd orelse return;
        _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, width(rect), height(rect), flags);
    }

    fn width(rect: w32.RECT) i32 {
        return @max(rect.right - rect.left, 1);
    }

    fn height(rect: w32.RECT) i32 {
        return @max(rect.bottom - rect.top, 1);
    }

    /// During a live resize, wait (briefly) until every resized pane has
    /// presented a frame at its new size, so DWM does not stretch stale
    /// frames. The renderers draw in parallel.
    fn awaitResizeFrames(self: *const PaneLayout) void {
        var events: [capacity]w32.HANDLE = undefined;
        var count: u32 = 0;
        for (self.surfaces[0..self.len]) |surface| {
            if (!surface.resize_frame_pending) continue;
            surface.resize_frame_pending = false;
            const event = surface.frame_event orelse continue;
            events[count] = event;
            count += 1;
        }
        if (count > 0) _ = w32.WaitForMultipleObjects(count, &events, 1, Surface.resize_frame_timeout_ms);
    }
};

/// Paint the part of the client area below the chrome that no pane covers
/// with the terminal background, then the split dividers.
fn eraseSurfaceArea(self: *Window, hdc: w32.HDC) void {
    const brush = self.app.bg_brush orelse return;
    const rect = self.surfaceRect();
    _ = w32.FillRect(hdc, &rect, brush);
    self.paintDividers(hdc);
}

/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}

fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);

            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Surface).Node.Handle,
    layout: SplitTree(Surface).Split.Layout,
};

fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Surface),
    handle: SplitTree(Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}

fn startDividerDrag(self: *Window, handle: SplitTree(Surface).Node.Handle, layout: SplitTree(Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// Create a new split in the active tab.
pub fn newSplit(self: *Window, direction: SplitTree(Surface).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split);

    // Create a single-node tree for the new surface.
    var insert_tree = try SplitTree(Surface).init(alloc, new_surface);
    defer insert_tree.deinit();

    // Split the current tree at the active surface.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Focus the new surface.
    self.tab_active_surface[tab] = new_surface;

    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
    self.updateAppMode();
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.tab_active_surface[tab] = surface;
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        },
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const layout: SplitTree(Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            // GotoTab carries a c_int; clamp non-negative before casting
            // so a negative sentinel doesn't panic the @intCast.
            const raw = @intFromEnum(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < self.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    const moved = self.getSlot(self.active_tab);
    self.copySlot(self.active_tab, new_index);
    self.setSlot(new_index, moved);
    self.active_tab = new_index;
    self.invalidateTabBar();
}

/// Move the tab containing `surface`, including all of its splits, into a new
/// native window without restarting any child processes.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    if (self.is_quick_terminal or self.tab_count <= 1) return false;
    const tab_idx = self.findTabIndex(surface) orelse return false;

    const alloc = self.app.core_app.alloc;
    const destination = try alloc.create(Window);
    destination.init(self.app, .{}) catch |err| {
        alloc.destroy(destination);
        return err;
    };
    errdefer {
        destination.deinit();
        alloc.destroy(destination);
    }

    try self.app.windows.append(alloc, destination);
    var tracked = true;
    errdefer if (tracked) {
        for (self.app.windows.items, 0..) |window, i| {
            if (window == destination) {
                _ = self.app.windows.orderedRemove(i);
                break;
            }
        }
    };

    const destination_hwnd = destination.hwnd orelse return error.Win32Error;
    var moved_tree = self.tab_trees[tab_idx];

    // Reparent every child HWND first so a failure can be rolled back before
    // either window's tab arrays are mutated.
    var it = moved_tree.iterator();
    while (it.next()) |entry| {
        const child = entry.view.hwnd orelse continue;
        if (w32.SetParent(child, destination_hwnd) == null) {
            if (self.hwnd) |source_hwnd| {
                var rollback = moved_tree.iterator();
                while (rollback.next()) |rollback_entry| {
                    if (rollback_entry.view.hwnd) |h| _ = w32.SetParent(h, source_hwnd);
                }
            }
            return error.Win32Error;
        }
    }

    var moved = self.getSlot(tab_idx);
    moved.unread = false;
    const moved_active = moved.active_surface;

    var i = tab_idx;
    while (i + 1 < self.tab_count) : (i += 1) self.copySlot(i, i + 1);
    self.tab_count -= 1;
    if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    } else if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    }

    destination.setSlot(0, moved);
    destination.tab_count = 1;
    destination.active_tab = 0;

    it = destination.tab_trees[0].iterator();
    while (it.next()) |entry| entry.view.parent_window = destination;

    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    self.updateAppMode();

    destination.updateTabBarVisibility();
    destination.updateWindowTitle();
    destination.layoutSplits();
    destination.showWhenReady(moved_active);
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);
    destination.updateAppMode();

    tracked = false;
    return true;
}

/// Update the top-level window title to match the active tab's title.
pub fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.window_title_override_len orelse
        self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    if (self.window_title_override_len != null) {
        @memcpy(buf[0..len], self.window_title_override[0..len]);
    } else {
        @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    }
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Set or clear the explicit top-level window title override.
pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        const len = std.unicode.utf8ToUtf16Le(&self.window_title_override, title) catch 0;
        self.window_title_override_len = @intCast(@min(len, self.window_title_override.len));
    }
    self.updateWindowTitle();
}

/// Called when a tab's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(surface) orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Update tab bar visibility based on config and tab count. The chrome row
/// can change height with it.
fn updateTabBarVisibility(self: *Window) void {
    if (!self.tab_bar.updateVisibility()) return;
    self.applyFrameMargins();
    self.handleResize();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Hide the tab bar regardless of `window-show-tab-bar`, or stop hiding
/// it; for example while herdr runs as the only tab (`gx-herdr-app-mode`).
pub fn setTabBarSuppressed(self: *Window, suppressed: bool) void {
    if (self.tab_bar_suppressed == suppressed) return;
    self.tab_bar_suppressed = suppressed;
    self.updateTabBarVisibility();
}

/// herdr app mode (`gx-herdr-app-mode`, see src/gx/app_mode.zig): while
/// the only tab of the window runs herdr in one of its terminals, the tab
/// bar is hidden so the window presents herdr like an application of its
/// own. Checked when tabs or splits change and, while the window has a
/// single tab, on a timer (`app_mode_interval_ms`); a second tab or herdr
/// exiting restores the tab bar.
pub fn updateAppMode(self: *Window) void {
    const enabled = self.app.config.@"gx-herdr-app-mode" and !self.is_quick_terminal;
    const watch = enabled and !self.closing and self.tab_count == 1;
    self.setAppModeTimer(watch);

    // Each answer lists the processes, so stop at the first terminal that
    // runs herdr: one is enough.
    var answers: [app_mode_max_terminals]?bool = undefined;
    var count: usize = 0;
    if (watch) {
        var it = self.tab_trees[0].iterator();
        while (it.next()) |entry| {
            if (count == answers.len) break;
            const surface = entry.view;
            const answer = if (surface.core_surface_ready) gx.app_mode.terminalRunsHerdr(
                self.app.core_app.alloc,
                global.io(),
                surface.core_surface.getProcessInfo(.foreground_pid),
                true,
            ) else null;
            answers[count] = answer;
            count += 1;
            if (answer orelse false) break;
        }
    }

    const app_mode = gx.app_mode.decide(enabled, self.tab_count, answers[0..count], self.app_mode);
    if (app_mode != self.app_mode) log.info("herdr app mode {s}", .{if (app_mode) "on" else "off"});
    self.app_mode = app_mode;
    self.setTabBarSuppressed(app_mode);
}

fn setAppModeTimer(self: *Window, run: bool) void {
    if (self.app_mode_timer == run) return;
    const hwnd = self.hwnd orelse return;
    if (run) {
        if (w32.SetTimer(hwnd, app_mode_timer_id, app_mode_interval_ms, null) == 0) return;
    } else {
        _ = w32.KillTimer(hwnd, app_mode_timer_id);
    }
    self.app_mode_timer = run;
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    self.tab_bar.invalidate();
}

/// Replace the title of the tab at `tab_idx` (UTF-16, truncated to 255
/// code units).
pub fn setTabTitle(self: *Window, tab_idx: usize, title: []const u16) void {
    if (tab_idx >= self.tab_count) return;
    const len: u16 = @intCast(@min(title.len, 255));
    @memcpy(self.tab_titles[tab_idx][0..len], title[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
}

/// Set (or clear, when empty) the explicit window title override (UTF-16,
/// truncated to 255 code units).
pub fn setWindowTitleOverride(self: *Window, title: []const u16) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        const len: u16 = @intCast(@min(title.len, 255));
        @memcpy(self.window_title_override[0..len], title[0..len]);
        self.window_title_override_len = len;
    }
    self.updateWindowTitle();
}

/// Toggle fullscreen mode on the top-level window.
pub fn toggleFullscreen(self: *Window) void {
    self.title_bar.toggleFullscreen();
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    self.title_bar.toggleDecorations();
}

/// Handle WM_SIZE: re-layout the active tab's split panes, repaint the
/// chrome and show the resize overlay.
fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.resize_overlay.show();
    self.shortcut_notice.reposition();
}

/// Move a tab from one index to another, shifting intermediate tabs.
pub fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.tab_bar.cancelRename();

    // Save the source tab state
    const saved = self.getSlot(from);

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) self.copySlot(i, i + 1);
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) self.copySlot(i, i - 1);
    }

    // Place the saved tab at the destination
    self.setSlot(to, saved);

    self.active_tab = to;
    self.invalidateTabBar();
}

/// Return true if it is safe to close this whole window. If a terminal in
/// any tab runs a program (core `needsConfirmQuit`, which lets idle shells
/// pass), show a single aggregate confirmation dialog (mirroring
/// macOS/GTK, which confirm once per window) and return whether the user
/// approved. Every whole-window close (caption close button, Alt+F4,
/// `close_window`) arrives as WM_CLOSE and asks here. When the last tab
/// has already been closed (tab_count == 0) there is nothing to confirm,
/// so this returns true silently. Returns false when the window was
/// destroyed while the dialog was open; `self` is invalid then.
pub fn confirmCloseIfNeeded(self: *Window) bool {
    const hwnd = self.hwnd orelse return true;
    var check: CloseCheck = .init(self.app.core_app.alloc);
    defer check.deinit();
    for (0..self.tab_count) |i| check.tab(self, i);
    if (!check.needed) return true;

    return Dialogs.confirmCloseWindow(hwnd, check.processes.items) == .accept and isAlive(hwnd, self);
}

/// Close this window from a core action (`close_window`): through
/// WM_CLOSE, so the confirmation and the close run from the message loop
/// rather than inside the key binding that asked for it.
pub fn requestClose(self: *Window) void {
    if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    // First, cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;
    Settings.onWindowDestroyed(self);

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        self.tab_bar.deinit();
        self.title_bar.deinit();
        self.resize_overlay.deinit();
        self.shortcut_notice.deinit();
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // Clean up Window-level resources.
    self.tab_bar.deinit();
    self.title_bar.deinit();
    self.resize_overlay.deinit();
    self.shortcut_notice.deinit();
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Handle WM_PAINT: the client area outside the terminals is the chrome
/// row (title bar with the tabs).
fn paint(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    self.title_bar.paint(hdc);
}

/// Client coordinates of a mouse message.
fn mousePoint(lparam: isize) w32.POINT {
    return .{
        .x = @as(i16, @truncate(lparam & 0xFFFF)),
        .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
    };
}

/// Whether client `y` lies in the chrome row.
fn inChrome(self: *const Window, y: i32) bool {
    return y >= 0 and y < self.chromeHeight();
}

/// The tab of `surface` rang the bell: badge it unless it is the active
/// tab.
pub fn onBell(self: *Window, surface: *Surface) void {
    self.tab_bar.markUnread(surface);
}

/// A right click in the client part of the chrome row: the tab menus, or
/// just "New Tab" on an empty part (a fullscreen tab row; the empty title
/// bar is a caption with the window menu).
fn onChromeRightClick(self: *Window, pt: w32.POINT) void {
    if (self.tab_bar.onRightButtonUp(self.title_bar.layout(), pt.x, pt.y)) return;
    const hwnd = self.hwnd orelse return;
    var screen = pt;
    _ = w32.ClientToScreen(hwnd, &screen);
    const command = Menu.showTabContextMenu(self, screen, null) orelse return;
    Menu.performTabCommand(self, null, command);
}

const WM_CAPTURECHANGED: u32 = 0x0215;

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MBUTTONUP,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    // The title bar owns the non-client frame and sees every message first.
    if (window.title_bar.handleMessage(msg, wparam, lparam)) |result| return result;

    switch (msg) {
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (window.resize_overlay.onTimer(wparam)) return 0;
            if (window.shortcut_notice.onTimer(wparam)) return 0;
            if (window.title_bar.onTimer(wparam)) return 0;
            switch (wparam) {
                FIRST_FRAME_TIMER_ID => window.checkFirstFrame(),
                CHROME_TIMER_ID => window.tab_bar.onTimer(),
                app_mode_timer_id => window.updateAppMode(),
                else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
            }
            return 0;
        },

        WM_APP_MAIN_MENU => {
            if (!window.closing) Menu.showMainMenu(window, window.main_menu_anchor);
            return 0;
        },

        WM_APP_CLOSE_TAB => {
            if (!window.closing) window.onCloseTabRequest(wparam, lparam);
            return 0;
        },

        w32.WM_SIZE => {
            // Minimizing does not hide child surface HWNDs, so tell the core
            // to stop rendering the active tab while minimized. Return early:
            // the client rect is 0x0 while minimized, so re-laying-out would
            // both re-mark the surfaces visible (undoing the occlusion) and
            // collapse the grid, and the resize overlay would flash offscreen.
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setActiveTabVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(true);
            }
            // Maximizing moves the tabs (no left margin) and swaps the
            // maximize glyph: repaint the whole chrome row.
            window.title_bar.tooltip.hide();
            window.title_bar.invalidate();
            window.handleResize();
            return 0;
        },
        w32.WM_POWERBROADCAST => {
            // After system sleep/resume nothing else kicks a re-present:
            // the renderer has no vsync/power awareness and never redraws
            // an unchanged terminal, so the last pre-sleep frame (or a
            // lost, black one) could stay on screen (the same bug as
            // microsoft/terminal#14483). Make every visible surface draw a
            // complete new frame. Both resume events may arrive for a
            // single resume; the redundant refresh is harmless. Return
            // TRUE per the message contract.
            if (wparam == w32.PBT_APMRESUMEAUTOMATIC or
                wparam == w32.PBT_APMRESUMESUSPEND)
            {
                log.info("system resumed, redrawing the terminals", .{});
                window.refreshRenderers();
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_DISPLAYCHANGE => {
            // A resolution or monitor layout change can lose the window
            // contents, and screen-positioned popups may now be off.
            log.info("display changed, redrawing the terminals", .{});
            window.refreshRenderers();
            window.repositionPopups();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOVE => {
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar and the find bar are screen-positioned popups that
            // must follow their owner.
            window.repositionPopups();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_DPICHANGED => {
            // HIWORD(wparam) is the new Y DPI (equal to X for windows);
            // lparam points to the suggested window rect.
            const dpi: u32 = @intCast((wparam >> 16) & 0xFFFF);
            const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            window.handleDpiChange(dpi, suggested);
            return 0;
        },
        WM_GHOSTTY_SIMULATE_DPI => {
            const dpi: u32 = @intCast(wparam & 0xFFFF);
            if (dpi < 48 or dpi > 960) return 0;
            const suggested = window.simulatedDpiRect(dpi) orelse return 0;
            log.info("simulating a DPI change dpi={}", .{dpi});
            window.handleDpiChange(dpi, &suggested);
            return 1;
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = true;
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = false;
            }
            return 0;
        },
        w32.WM_CLOSE => {
            // Title-bar X / Alt+F4 / close_window land here. Confirm once
            // for the whole window if any tab has a running process. While
            // a dialog's modal loop runs, the close waits for the dialog.
            if (Dialogs.deferClose(hwnd)) return 0;
            if (!window.confirmCloseIfNeeded()) return 0;
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paint();
            return 0;
        },
        w32.WM_COMMAND => {
            if (window.tab_bar.onCommand(wparam)) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child surface.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the terminal.
            if (window.getActiveSurface()) |s| {
                if (s.hwnd) |h| _ = w32.SetFocus(h);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => {
            // Fill what the terminals don't cover (split gaps, an area a
            // resize exposed before the panes follow) with the terminal
            // background instead of leaving stale pixels, and redraw the
            // dividers the fill covered. The panes are clipped out
            // (WS_CLIPCHILDREN); the chrome paints itself in WM_PAINT.
            window.eraseSurfaceArea(@ptrFromInt(wparam));
            return 1;
        },
        w32.WM_LBUTTONDOWN => {
            const pt = mousePoint(lparam);
            if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            _ = window.title_bar.onLeftButtonDown(pt.x, pt.y);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            const pt = mousePoint(lparam);
            _ = window.title_bar.onLeftButtonUp(pt.x, pt.y);
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const pt = mousePoint(lparam);
            // Double-click on a tab starts inline rename.
            if (window.inChrome(pt.y)) {
                _ = window.tab_bar.onDoubleClick(window.title_bar.layout(), pt.x, pt.y);
                return 0;
            }
            if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const pt = mousePoint(lparam);
            if (window.inChrome(pt.y)) {
                window.onChromeRightClick(pt);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MBUTTONUP => {
            const pt = mousePoint(lparam);
            if (window.inChrome(pt.y)) {
                _ = window.tab_bar.onMiddleButtonUp(window.title_bar.layout(), pt.x, pt.y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const pt = mousePoint(lparam);
            if (window.dragging_split) {
                window.updateDividerDrag(pt.x, pt.y);
                return 0;
            }
            // Tab drag reorder and chrome hover.
            _ = window.title_bar.onMouseMove(pt.x, pt.y);
            return 0;
        },
        WM_CAPTURECHANGED => {
            window.tab_bar.onCaptureLost();
            return 0;
        },
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.title_bar.onMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
