// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs (each tab a split tree).
//!
//! The Window owns the tab model (split trees, active surfaces, titles,
//! unread and bell flags, the progress its terminals report, when each tab
//! was last selected), split layout and window-level state (DPI scale, size
//! limits, placement) and orchestrates the chrome modules. A tab shows its
//! title override (`set_tab_title`, renaming) or else the title of its
//! focused split (`refreshTabTitle`); the focused split is the one that
//! last got the keyboard focus (`setActiveSurface`). The tab bar reads
//! the rest of a tab's state from `tabStatus`. The chrome modules:
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
//!   - `ui/Notice.zig` (`notice`) and `ui/Toast.zig` (`toast`): the
//!     window's notice and toast at the bottom of the terminals
//!     (`showNotice`, `showToast`).
//!   - `ui/Menu.zig`: the main menu, opened through `queueMainMenu`.
//!
//! The system broadcasts top-level windows get (settings, system colors,
//! visual style, accent color) go to `onSystemSettingChange`, which passes
//! them on to the design tokens, the app, the backdrop and the title bar.
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
//! the active tab's surfaces the new content scale (`Surface.handleDpiChange`),
//! leaving hidden tabs to follow when selected (`applyScale`). It adopts
//! the rect Windows suggests and lays the panes out once. The popups are
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
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const gx = @import("../../gx/main.zig");

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Leaf = @import("Leaf.zig");
const RemotePane = @import("RemotePane.zig");
const protocol = @import("../../gx/remote_protocol.zig");
const refs = @import("../../gx/ui_ref.zig");
const Pane = @import("Pane.zig");
const Palette = @import("ui/Palette.zig");
const PaneSnapshot = @import("PaneSnapshot.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const split_layout = @import("split_layout.zig");
const splits = @import("splits.zig");
const tab_status = @import("tab_status.zig");
const tabs = @import("tabs.zig");
const w32 = @import("win32.zig");
const Backdrop = @import("chrome/Backdrop.zig");
const TabBar = @import("chrome/TabBar.zig");
const TitleBar = @import("chrome/TitleBar.zig");
const caption_layout = @import("chrome/caption_layout.zig");
const Dialogs = @import("ui/Dialogs.zig");
const Menu = @import("ui/Menu.zig");
const Notice = @import("ui/Notice.zig");
const Popup = @import("ui/Popup.zig");
const ResizeOverlay = @import("ui/ResizeOverlay.zig");
const ShortcutNotice = @import("ui/ShortcutNotice.zig");
const Toast = @import("ui/Toast.zig");
const style = @import("ui/style.zig");
const Settings = @import("ui/Settings.zig");
const wstr = @import("ui/wstr.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
pub const MAX_TABS: usize = 64;
const WM_APP_TAB_DETACH: u32 = w32.WM_APP + 0x68;
const DetachRequest = struct { tab: gx.ui_ref.Reference, point: w32.POINT };

/// The parent App.
app: *App,
ui_reference: gx.ui_ref.Reference = .{},
ui_attachment: gx.ui_ref.Attachment = .{},
pending_native_destroy: bool = false,
tab_references: [MAX_TABS]gx.ui_ref.Reference = @splat(.{}),
pending_tab_detach: ?DetachRequest = null,
tab_transfer_active: bool = false,
tab_transfer_close: bool = false,
uia_bridge: @import("ui/uia_bridge.zig").WindowBridge = .{},
uia_dirty: bool = true,
tab_attachments: [MAX_TABS]gx.ui_ref.Attachment = @splat(.{}),

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab split trees owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_trees: [MAX_TABS]SplitTree(Leaf) = undefined,

/// The currently focused surface within each tab.
tab_active_surface: [MAX_TABS]*Leaf = undefined,
palette: Palette = .{},

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Content scale (DPI / 96.0) of the chrome and the terminals, from the
/// last WM_DPICHANGED (or `WM_GHOSTTY_SIMULATE_DPI`). Lay out and draw
/// with it, not with `GetDpiForWindow`.
scale: f32 = 1.0,

/// The title each tab shows (UTF-16, for painting the tab bar), from its
/// override and its focused terminal (`refreshTabTitle`).
tab_titles: [MAX_TABS][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [MAX_TABS]u16 = undefined,

/// The title each tab shows instead of its focused terminal's
/// (`set_tab_title`, renaming the tab), or null.
tab_title_overrides: [MAX_TABS]?tabs.Title = [_]?tabs.Title{null} ** MAX_TABS,

/// Whether each tab received output (or rang the bell) since it was last
/// the active tab (the tab bar shows a badge).
tab_unread: [MAX_TABS]bool = [_]bool{false} ** MAX_TABS,

/// Whether a terminal of each tab rang the bell since the tab was last
/// selected (`ringTab`, `tabStatus`).
tab_bell: [MAX_TABS]bool = [_]bool{false} ** MAX_TABS,

/// When each tab was last selected, as the `activation_count` of that
/// selection (`tabRecency`); 0 for never.
tab_activated: [MAX_TABS]u64 = [_]u64{0} ** MAX_TABS,

/// Tab selections so far, for `tab_activated`.
activation_count: u64 = 0,

/// Explicit top-level window title override. Null follows the active tab.
window_title_override_len: ?u16 = null,
window_title_override: [256]u16 = undefined,

/// Title bar / non-client frame (see chrome/TitleBar.zig).
title_bar: TitleBar = .{},

/// Tab bar (see chrome/TabBar.zig).
tab_bar: TabBar = .{},

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,
/// Source-owned background container, registered separately by RemoteCoordinator.
is_remote_host: bool = false,

/// Split divider drag state: the tab, the split node and how far from the
/// divider line the pointer grabbed it. Replacing the tab's split tree ends
/// the drag (`replaceTree`).
dragging_split: bool = false,
drag_split_tab: usize = 0,
drag_split_handle: SplitTree(Leaf).Node.Handle = .root,
drag_split_layout: SplitTree(Leaf).Split.Layout = .horizontal,
drag_grab_offset: i32 = 0,

/// The split of the active tab whose divider is under the pointer, drawn
/// highlighted (`updateDividerHover`), and whether WM_MOUSELEAVE is
/// requested for it.
divider_hover: ?SplitTree(Leaf).Node.Handle = null,
divider_tracking: bool = false,

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

/// The window's notice and toast at the bottom of the terminal area
/// (`showNotice`, `showToast`).
notice: Notice = .{},
toast: Toast = .{},

/// Where the main menu queued by `queueMainMenu` opens (null: below the
/// chrome at the left edge).
main_menu_anchor: ?w32.POINT = null,

/// Hides the tab bar regardless of `window-show-tab-bar` (see
/// `setTabBarSuppressed`).
tab_bar_suppressed: bool = false,

/// Whether the window is in herdr app mode (see `updateAppMode`).
app_mode: bool = false,

/// The herdr app mode checks (`checkAppMode`): the entry hysteresis, the
/// delay before the next periodic check and when it is due
/// (`GetTickCount64`), and whether `app_mode_soon_timer_id` runs.
app_mode_state: gx.app_mode.State = .{},
app_mode_samples: AppModeSamples = .{},
app_mode_delay_ms: u32 = 0,
app_mode_due_ms: u64 = 0,
app_mode_soon: bool = false,

/// The surface whose first frame the cloaked window waits for, and since when.
first_frame_surface: ?*Surface = null,
first_frame_since_ms: u64 = 0,

/// When the window became visible to the user (`uncloak`,
/// `GetTickCount64`); 0 before. The size overlay waits for it
/// (`showResizeOverlay`).
uncloaked_ms: u64 = 0,

/// The terminal and grid the size overlay showed or would have shown
/// last, so it shows only for a grid that changed (`showResizeOverlay`).
overlay_grid: ?OverlayGrid = null,

/// Why the terminals of the active tab are not seen although they are laid
/// out (`setOcclusion`).
occlusion: Occlusion = .{},
visibility: VisibilitySubscriptions = .{},

/// Whether `window-position-x/-y` placed the window (no re-centering).
position_configured: bool = false,

/// Whether the window took its place from the remembered window state
/// (`restoredRect`; no re-centering), and whether it opens maximized
/// because the remembered window was.
position_restored: bool = false,
start_maximized: bool = false,

/// Where the window is while it is neither maximized, minimized nor
/// fullscreen (screen pixels), and whether it is maximized, for the window
/// state (`trackPlacement`, `saveWindowState`).
normal_rect: ?w32.RECT = null,
maximized: bool = false,

/// The terminal size from `window-width`/`window-height` (`initial_size`,
/// DIPs), restored by `reset_window_size`.
initial_content_size: ?[2]u32 = null,

/// Whether the window has been shown (`showWhenReady`).
shown: bool = false,

/// True while `layoutSplits` moves the panes: a pane resized during a
/// live resize then leaves waiting for its new frame to the window.
laying_out: bool = false,

/// What the last `layoutSplits` laid out, so `relayout` can tell whether
/// the panes still are where they belong.
layout_key: ?LayoutKey = null,
layout_passes: usize = 0,

/// The terminal (core surface id) and grid of a size overlay.
const OverlayGrid = PaneSnapshot.Grid;

/// What a layout of the panes depends on, besides split ratios changed in
/// place (whose callers lay out themselves): the terminal area, the scale,
/// the tab and its tree.
const LayoutKey = struct {
    area: w32.RECT,
    scale: f32,
    tab: usize,
    nodes: usize,
    zoomed: ?SplitTree(Leaf).Node.Handle,
};

/// Reasons nobody sees the window's terminals: the renderers stop drawing
/// while any is set (`setOcclusion`).
const Occlusion = packed struct(u8) {
    /// Hidden (`toggle_visibility`, the quick terminal).
    hidden: bool = false,
    minimized: bool = false,
    locked: bool = false,
    display_off: bool = false,
    desktop: bool = false,
    _padding: u3 = 0,

    fn any(self: Occlusion) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

/// How long after the window became visible resizes show no size overlay:
/// those are the window settling (maximizing, its tab bar), not the user.
const overlay_delay_ms: u64 = 250;

/// Posted by `queueMainMenu`; opens the main menu.
const WM_APP_MAIN_MENU: u32 = w32.WM_APP + 20;

/// Posted by `closeTabMode`: wparam is the `apprt.action.CloseTabMode`,
/// lparam the core id of the surface whose tab it refers to.
const WM_APP_CLOSE_TAB: u32 = w32.WM_APP + 0x61;

/// For the render thread of a terminal of this window to post when the
/// terminal presented its first frame after `showWhenReady` asked for one
/// (`Surface.requestFirstFrameMessage`), so the window uncloaks at once:
/// wparam 0, lparam the terminal's core surface id (`CoreSurface.id`). The
/// `FIRST_FRAME_TIMER_ID` fallback uncloaks the window as well, so it shows
/// when the message does not come.
pub const WM_APP_FIRST_FRAME: u32 = w32.WM_APP + 31;

/// A one-shot timer for an herdr app mode check sooner than the next tick
/// of `CHROME_TIMER_ID` (`checkAppModeIn`): after a terminal title changed,
/// or while an entry waits for its second check.
const app_mode_soon_timer_id: usize = 0x4851; // 'HQ'

/// How long after a title change the app mode check runs (herdr sets the
/// title as it starts).
const app_mode_title_delay_ms: u32 = 300;

/// The most terminals of a tab whose processes the app mode check reads.
const app_mode_max_terminals = 32;

/// One-shot fallback when no first-frame message arrives.
const FIRST_FRAME_TIMER_ID: usize = 0x4646; // 'FF'
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

/// Test-only message: SendMessage(window, WM_GHOSTTY_SIMULATE_SYSTEM_THEME,
/// theme, 0) makes the app act as if Windows switched its apps color scheme
/// or high contrast (`App.SimulatedSystemTheme` in wparam,
/// `App.simulateSystemTheme`). Returns 1 when simulated.
pub const WM_GHOSTTY_SIMULATE_SYSTEM_THEME: u32 = w32.WM_USER + 0x49;

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
    Backdrop.onConfigChange(hwnd, config, self.app.alpha_frames);
    if (!self.is_quick_terminal) {
        const decoration = TitleBar.Decoration.fromConfig(config.@"window-decoration");
        if (decoration != self.title_bar.decoration) self.title_bar.applyDecoration(config);
    }
    self.title_bar.onConfigChange();
    self.updateDims();
    self.onFrameChanged();
    self.updateAppMode();
}

/// The UI language changed: rebuild menus and repaint the chrome and the
/// popups of every surface.
pub fn onLanguageChanged(self: *Window) void {
    self.palette.onLanguageChanged();
    Menu.onLanguageChanged();
    self.title_bar.onLanguageChanged();
    self.tab_bar.onLanguageChanged();
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| entry.view.onLanguageChanged();
    }
    self.shortcut_notice.reposition();
    self.repositionOverlays();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };
    self.ui_reference = try app.ui_ids.create(.window);
    self.ui_attachment = try app.ui_ids.attach(self.ui_reference, self.ui_reference);

    const window_style = TitleBar.windowStyle(&app.config, options.is_quick_terminal);

    // Quick terminals are positioned by QuickTerminal.calculateRects.
    // Others start centered at 80% of the work area (`initialRect`), or
    // where the window that closed last was, when no other window is open
    // (`restoredRect`). Honor an explicit configured window position only
    // when BOTH coordinates are set; a partial config falls back to the
    // default.
    var rect = w32.RECT{ .left = w32.CW_USEDEFAULT, .top = w32.CW_USEDEFAULT, .right = 800, .bottom = 600 };
    if (!options.is_quick_terminal) {
        var position: ?w32.POINT = null;
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| position = .{ .x = px, .y = py };
        }
        self.position_configured = position != null;
        rect = initialRect(position);
        if (app.windows.items.len == 0) {
            if (self.restoredRect(rect)) |restored| rect = restored;
        }
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

    Backdrop.apply(hwnd, &app.config, .{ .force_opaque = options.force_opaque, .alpha_frames = app.alpha_frames });

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
        if (!self.position_configured and !self.position_restored) self.cascade();
        var placed: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &placed) != 0) self.normal_rect = placed;
        _ = w32.SetTimer(hwnd, CHROME_TIMER_ID, chrome_timer_ms, null);
    }
    self.visibility.init(hwnd);
    VisibilitySubscriptions.refreshShell(self);

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// The least size, in DIPs, a remembered window opens with.
const restore_min_dip: [2]i32 = .{ 320, 200 };

/// Where the window opens from the remembered window state
/// (`gx.window_state`, the window that closed last), instead of `default`:
/// the parts `window_state.use` leaves to it under the configuration. The
/// remembered place counts only while it is on a monitor
/// (`MonitorFromRect`); there the window keeps its size in DIPs, moves into
/// the work area and gets at least `restore_min_dip` (`window_state.restore`).
/// Otherwise, a remembered size opens at the default place. Sets
/// `start_maximized` and `position_restored`. Null when nothing applies.
fn restoredRect(self: *Window, default: w32.RECT) ?w32.RECT {
    const ws = gx.window_state;
    const use = ws.use(&self.app.config);
    if (!use.any()) return null;
    const alloc = self.app.core_app.alloc;
    const path = ws.defaultPath(alloc) catch return null;
    defer alloc.free(path);
    const state = (ws.load(alloc, global.io(), path) catch |err| {
        log.warn("cannot read the window state err={}", .{err});
        return null;
    }) orelse return null;
    if (use.maximized) self.start_maximized = state.maximized;

    // The monitor of the remembered place if it is on one, else the
    // monitor of the default place.
    const saved: ?w32.RECT = if (state.rect()) |r| .{ .left = r.x, .top = r.y, .right = r.right(), .bottom = r.bottom() } else null;
    const remembered: ?w32.HMONITOR = if (use.position) if (saved) |r| MonitorFromRect(&r, MONITOR_DEFAULTTONULL) else null else null;
    const monitor = remembered orelse MonitorFromRect(&default, MONITOR_DEFAULTTONEAREST) orelse return null;
    var mi: w32.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(monitor, &mi) == 0) return null;
    const work: ws.Rect = .{
        .x = mi.rcWork.left,
        .y = mi.rcWork.top,
        .width = mi.rcWork.right - mi.rcWork.left,
        .height = mi.rcWork.bottom - mi.rcWork.top,
    };
    const dpi = monitorDpi(monitor);
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    const chrome = caption_layout.minTrackSize(scale, self.tab_bar.showsAdminBadge());
    const min: ws.Size = .{
        .width = @max(ws.scale(restore_min_dip[0], dpi), chrome.width),
        .height = @max(ws.scale(restore_min_dip[1], dpi), chrome.height),
    };

    const default_rect: ws.Rect = .{
        .x = default.left,
        .y = default.top,
        .width = default.right - default.left,
        .height = default.bottom - default.top,
    };
    const placed: ws.Rect = placed: {
        if (remembered != null) {
            if (ws.restore(state, work, dpi, min, &.{})) |at| {
                self.position_restored = true;
                if (use.size) break :placed at;
                break :placed ws.fit(.{ .x = at.x, .y = at.y, .width = default_rect.width, .height = default_rect.height }, work);
            }
        }
        if (!use.size) return null;
        // The remembered size at the default place, in DIPs.
        const sized = ws.rescale(.{ .x = 0, .y = 0, .width = state.size.width, .height = state.size.height }, state.dpi, dpi);
        const width = @max(sized.width, min.width);
        const height = @max(sized.height, min.height);
        const x = if (self.position_configured) default_rect.x else work.x + @divTrunc(work.width - width, 2);
        const y = if (self.position_configured) default_rect.y else work.y + @divTrunc(work.height - height, 2);
        break :placed ws.fit(.{ .x = x, .y = y, .width = width, .height = height }, work);
    };
    return .{ .left = placed.x, .top = placed.y, .right = placed.right(), .bottom = placed.bottom() };
}

/// The effective DPI of `monitor` (96 when unknown).
fn monitorDpi(monitor: w32.HMONITOR) u32 {
    var x: u32 = 0;
    var y: u32 = 0;
    if (GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y) < 0 or x == 0) return 96;
    return x;
}

const MONITOR_DEFAULTTONULL: u32 = 0;
const MONITOR_DEFAULTTONEAREST: u32 = 2;
const MDT_EFFECTIVE_DPI: u32 = 0;
extern "user32" fn MonitorFromRect(lprc: *const w32.RECT, dwFlags: u32) callconv(.winapi) ?w32.HMONITOR;
extern "shcore" fn GetDpiForMonitor(hmonitor: w32.HMONITOR, dpiType: u32, dpiX: *u32, dpiY: *u32) callconv(.winapi) i32;

/// Remember where the window is (`gx.window_state`), for the next window
/// that opens when none is open (`restoredRect`): when the last window
/// closes, or the app quits. `window-save-state = never` remembers nothing.
fn saveWindowState(self: *Window) void {
    if (self.is_quick_terminal or !self.shown) return;
    if (self.app.config.@"window-save-state" == .never) return;
    const hwnd = self.hwnd orelse return;
    const rect = self.normal_rect orelse return;
    const dpi = w32.GetDpiForWindow(hwnd);
    const state: gx.window_state.State = .{
        .position = .{ .x = rect.left, .y = rect.top },
        .size = .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top },
        .dpi = if (dpi != 0) dpi else 96,
        .maximized = self.maximized,
    };
    const alloc = self.app.core_app.alloc;
    const path = gx.window_state.defaultPath(alloc) catch |err| {
        log.warn("cannot find the window state file err={}", .{err});
        return;
    };
    defer alloc.free(path);
    gx.window_state.save(global.io(), path, state) catch |err| {
        log.warn("cannot save the window state err={}", .{err});
    };
}

/// The window moved or changed its size or state (WM_WINDOWPOSCHANGED):
/// keep its place for the window state, while it is neither minimized nor
/// fullscreen: whether it is maximized, and its rectangle when it is not.
fn trackPlacement(self: *Window) void {
    self.uia_dirty = true;
    self.uia_bridge.dirty();
    const hwnd = self.hwnd orelse return;
    if (self.is_quick_terminal or self.title_bar.is_fullscreen or self.closing) return;
    if (w32.IsIconic(hwnd) != 0) return;
    const maximized = w32.IsZoomed(hwnd) != 0;
    if (self.maximized != maximized) self.app.scheduleSessionSave();
    self.maximized = maximized;
    if (self.maximized) return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const changed = if (self.normal_rect) |old| !std.meta.eql(old, rect) else true;
        self.normal_rect = rect;
        if (changed) self.app.scheduleSessionSave();
    }
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
    if (!self.shown) self.applyContentSize(width, height, !self.position_configured and !self.position_restored);
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
/// frame, or after `first_frame_timeout_ms`. With `fullscreen` set, the
/// window goes fullscreen while it is still cloaked (after it is shown, so
/// leaving fullscreen restores it as shown), and its terminals show at
/// their final size.
fn showWhenReady(self: *Window, view: anytype) void {
    const leaf = leafIdentity(view) orelse return;
    const surface = leaf.local() orelse {
        const native = self.hwnd orelse return;
        self.shown = true;
        _ = w32.ShowWindow(native, if (self.app.config.maximize or self.start_maximized) SW_SHOWMAXIMIZED else w32.SW_SHOW);
        self.uncloak(true);
        return;
    };
    const hwnd = self.hwnd orelse return;
    self.first_frame_surface = surface;
    self.first_frame_since_ms = GetTickCount64();
    if (surface.frame_event) |event| _ = w32.ResetEvent(event);
    surface.requestFirstFrameMessage(hwnd);
    self.shown = true;
    const maximized = self.app.config.maximize or self.start_maximized;
    _ = w32.ShowWindow(hwnd, if (maximized) SW_SHOWMAXIMIZED else w32.SW_SHOW);
    if (self.app.config.fullscreen != .false and !self.title_bar.is_fullscreen) {
        self.title_bar.toggleFullscreen();
    }
    _ = w32.UpdateWindow(hwnd);
    if (self.first_frame_surface != null and w32.SetTimer(hwnd, FIRST_FRAME_TIMER_ID, @intCast(first_frame_timeout_ms), null) == 0) {
        self.uncloak(false);
    }
}

fn checkFirstFrame(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.KillTimer(hwnd, FIRST_FRAME_TIMER_ID);
    const surface = self.firstFrameSurface() orelse return self.uncloak(false);
    const drawn = if (surface.frame_event) |event| w32.WaitForSingleObject(event, 0) == w32.WAIT_OBJECT_0 else false;
    self.uncloak(drawn);
}

/// `WM_APP_FIRST_FRAME`: the terminal with core id `id` presented a frame.
fn onFirstFrame(self: *Window, id: u64) void {
    const surface = self.firstFrameSurface() orelse return;
    if (!surface.core_surface_initialized or surface.core_surface.id != id) return;
    self.uncloak(true);
}

/// The terminal whose first frame the cloaked window waits for, if it is
/// still one of the window's (it can close before its first frame).
fn firstFrameSurface(self: *Window) ?*Surface {
    const surface = self.first_frame_surface orelse return null;
    if (self.findTabIndex(surface) == null) return null;
    return surface;
}

/// Show the window to the user: the first frame of its terminal (`drawn`)
/// or the timeout is there. Resizes show the size overlay from shortly
/// after (`showResizeOverlay`); with `resize-overlay = always` it shows
/// now.
fn uncloak(self: *Window, drawn: bool) void {
    const hwnd = self.hwnd orelse return;
    if (self.first_frame_surface == null) return;
    _ = w32.KillTimer(hwnd, FIRST_FRAME_TIMER_ID);
    self.first_frame_surface = null;
    setCloaked(hwnd, false);
    self.uncloaked_ms = GetTickCount64();
    // The layouts before were the window opening: they are the first one
    // `resize-overlay = after-first` leaves out.
    if (self.app.config.@"resize-overlay" != .always) {
        if (self.activePane()) |pane_| self.resize_overlay.rememberPane(pane_);
    }
    self.overlay_grid = self.activeGrid();
    if (self.app.config.@"resize-overlay" == .always and !self.is_quick_terminal) self.showActiveResizeOverlay();
    log.debug("window shown after {d}ms first_frame={}", .{ self.uncloaked_ms -| self.first_frame_since_ms, drawn });
}

/// The terminal and grid of the active tab's focused terminal.
fn activeGrid(self: *Window) ?OverlayGrid {
    const pane_ = self.activePane() orelse return null;
    return pane_.grid();
}

/// A resize: show the size overlay (`ResizeOverlay.show`, which follows
/// `resize-overlay`) when the grid of the focused terminal changed, but not
/// before the window is visible and has settled (`overlay_delay_ms`).
fn showResizeOverlay(self: *Window) void {
    if (self.uncloaked_ms == 0 and !self.is_quick_terminal) return;
    const grid = self.activeGrid() orelse return;
    if (self.overlay_grid) |last| if (std.meta.eql(last, grid)) return;
    self.overlay_grid = grid;
    if (GetTickCount64() -| self.uncloaked_ms < overlay_delay_ms) return;
    self.showActiveResizeOverlay();
}

fn showActiveResizeOverlay(self: *Window) void {
    const surface = self.activeLeaf() orelse return;
    const tree = &self.tab_trees[self.active_tab];
    const handle = tree.locate(surface) orelse return;
    const area = split_layout.paneRect(Tree, tree, self.splitArea(), self.splitMetrics().gap, handle) orelse return;
    self.resize_overlay.showPaneIn(surface.pane(), .{ .left = area.left, .top = area.top, .right = area.right, .bottom = area.bottom });
}

/// Hide the size overlay once the pane it shows is no longer on screen
/// (`paneOnScreen`): another tab is selected, the pane closed or moved to
/// another tab or window, or a zoom hides it. A resize of the pane that is
/// still shown keeps it (`showResizeOverlay`).
fn dropStaleResizeOverlay(self: *Window) void {
    const owner = self.resize_overlay.owner() orelse return;
    if (!self.paneOnScreen(owner.tab, owner.pane)) self.resize_overlay.hide();
}

/// Whether pane `pane` is on screen as part of tab `tab`: that tab is the
/// active one, still holds the pane and shows it (no zoom on another pane).
fn paneOnScreen(self: *const Window, tab: refs.Reference, pane: refs.Reference) bool {
    if (self.closing or self.active_tab >= self.tab_count) return false;
    if (!self.tab_references[self.active_tab].matches(tab)) return false;
    const tree = &self.tab_trees[self.active_tab];
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (!entry.view.reference().matches(pane)) continue;
        return if (tree.zoomed) |zoomed| entry.handle == zoomed else true;
    }
    return false;
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
/// tab visibility, the DWM frame and the layout, and repaint. The WM_SIZE of
/// a frame change lays the panes out with the new tab bar already
/// (`handleResize`), so this lays them out only when no WM_SIZE did
/// (`relayout`).
pub fn onFrameChanged(self: *Window) void {
    _ = self.tab_bar.updateVisibility();
    self.applyFrameMargins();
    self.relayout();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Handle WM_DPICHANGED, which only top-level windows receive: adopt the
/// suggested window rect, rescale the window chrome, and tell the
/// terminals of the active tab about their new content scale; the other
/// tabs follow when they are selected (`applyScale`).
fn handleDpiChange(self: *Window, dpi: u32, suggested: *const w32.RECT) void {
    self.palette.popup.setOwnerScale(@as(f32, @floatFromInt(dpi)) / 96);
    self.palette.onDpiChanged();
    if (dpi == 0) return;
    const quick = self.quickTerminal();
    if (quick) |qt| if (qt.ignoresDpiChange()) return;
    self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.title_bar.onDpiChanged();
    if (self.tab_count > 0) self.applyScale(self.active_tab);

    if (self.is_quick_terminal) {
        if (quick) |qt| qt.relayout();
    } else if (self.hwnd) |hwnd| {
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
    self.relayout();
    self.repositionOverlays();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

fn quickTerminal(self: *const Window) ?*@import("QuickTerminal.zig") {
    if (!self.is_quick_terminal) return null;
    const qt = self.app.quick_terminal orelse return null;
    return if (qt.window == self) qt else null;
}

/// Give the terminals of tab `tab` the window's content scale
/// (`Surface.handleDpiChange`) if they missed a DPI change: the window
/// rescales only the terminals of the active tab, the others when they are
/// selected, and a tab moved from another window comes with its scale.
fn applyScale(self: *Window, tab: usize) void {
    if (tab >= self.tab_count) return;
    const dpi: u32 = @intFromFloat(@round(self.scale * 96));
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        if (entry.view.scale() != self.scale) entry.view.handleDpiChange(dpi);
    }
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
    surface: anytype,
    size: apprt.action.ResizeWindow,
) bool {
    const hwnd = self.hwnd orelse return false;
    const surface_hwnd = surface.hwnd orelse return false;
    if (self.title_bar.is_fullscreen or self.is_quick_terminal) return false;
    if (w32.IsZoomed(hwnd) != 0) return false;
    const leaf = self.leafForPane(surface.ui_reference) orelse return false;
    const tab = self.findTabIndex(leaf) orelse return false;
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
/// When the app quits it deinitializes every window in `app.windows`; the
/// last of them remembers its place for the next run.
pub fn deinit(self: *Window) void {
    self.app.shell.revoke(self.ui_reference);
    self.uia_bridge.deinit();
    self.ui_reference = .{};
    self.ui_attachment = .{};
    self.visibility.deinit(self.hwnd);
    Settings.onWindowDestroyed(self);
    const windows = self.app.windows.items;
    if (windows.len > 0 and windows[windows.len - 1] == self) self.saveWindowState();

    // Close all tab surfaces, off the screen.
    self.hide();
    self.cleanupAllSurfaces();

    // Delete the tab bar fonts and the title bar canvas and tooltip.
    self.tab_bar.deinit();
    self.title_bar.deinit();
    self.resize_overlay.deinit();
    self.shortcut_notice.deinit();
    self.notice.deinit();
    self.toast.deinit();

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        if (self.hasForeignTerminalWindows()) {
            // Irrecoverable SetParent rollback: the app is shutting down and
            // another model still owns these renderers. Keep this inert native
            // parent until process teardown rather than destroy a live GL HWND.
            log.err("retaining native transfer parent after failed rollback", .{});
        } else if (!self.app.deferDropParentDestroy(hwnd)) _ = w32.DestroyWindow(hwnd);
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
    return self.tab_active_surface[self.active_tab].local();
}

/// Borrowed GUI adapters, valid only until a model mutation or modal call.
/// Core runtime callbacks retain getActiveSurface; UI consumers migrate here.
pub fn activePane(self: *const Window) ?Pane {
    return self.paneAtTab(self.active_tab);
}
pub fn paneAtTab(self: *const Window, index: usize) ?Pane {
    if (self.closing or index >= self.tab_count) return null;
    return self.tab_active_surface[index].pane();
}
pub const PaneIterator = struct {
    inner: ?SplitTree(Leaf).Iterator = null,
    pub fn next(self: *PaneIterator) ?Pane {
        const iterator = if (self.inner) |*value| value else return null;
        const entry = iterator.next() orelse return null;
        return entry.view.pane();
    }
};
pub fn paneIterator(self: *const Window, tab: usize) PaneIterator {
    if (self.closing or tab >= self.tab_count) return .{};
    return .{ .inner = self.tab_trees[tab].iterator() };
}
pub fn lookupPane(self: *const Window, reference: gx.ui_ref.Reference) ?Pane {
    if (!reference.isValid() or reference.kind != .surface or reference.epoch != self.ui_reference.epoch) return null;
    for (0..self.tab_count) |tab| {
        var iterator = self.paneIterator(tab);
        while (iterator.next()) |candidate| if (reference.matches(candidate.reference())) return candidate;
    }
    return null;
}

test "local pane facade rejects stale references without changing tree ownership" {
    const alloc = std.testing.allocator;
    var issuer = try gx.ui_ref.Issuer.init(7);
    var window: Window = .{ .app = undefined, .ui_reference = try issuer.create(.window), .tab_count = 1 };
    // A fixture-owned strong ref keeps tree release from invoking native cleanup.
    var surface: Surface = .{ .app = undefined, .parent_window = &window, .ui_reference = try issuer.surface(42), .ref_count = 1 };
    const leaf = try Leaf.fromLocal(alloc, &surface);
    window.tab_trees[0] = try SplitTree(Leaf).init(alloc, leaf);
    defer window.tab_trees[0].deinit();
    window.tab_active_surface[0] = surface.leaf.?;
    try std.testing.expect(window.activePane().?.reference().matches(surface.ui_reference));
    try std.testing.expect(window.lookupPane(surface.ui_reference) != null);
    var iterator = window.paneIterator(0);
    try std.testing.expect(iterator.next().?.reference().matches(surface.ui_reference));
    try std.testing.expect(iterator.next() == null);
    try std.testing.expectEqual(@as(u32, 2), surface.ref_count);
    var stale = surface.ui_reference;
    stale.generation += 1;
    try std.testing.expect(window.lookupPane(stale) == null);
    window.closing = true;
    try std.testing.expect(window.activePane() == null);
    try std.testing.expect(window.lookupPane(surface.ui_reference) == null);
}

/// Give keyboard focus to the active surface of the active tab.
pub fn focusActiveSurface(self: *Window) void {
    if (self.activeLeaf()) |s| {
        if (s.nativeHandle()) |h| _ = w32.SetFocus(h);
    }
}

/// Whether this window is the active window or the keyboard focus is in
/// it or in a popup it owns. Moving the focus into a window that has
/// neither would activate it, taking it from the window the user is in.
fn hasFocus(self: *const Window) bool {
    const hwnd = self.hwnd orelse return false;
    if (w32.GetActiveWindow() == hwnd) return true;
    const focus = w32.GetFocus() orelse return false;
    return GetAncestor(focus, GA_ROOTOWNER) == hwnd;
}

/// Perform a binding action on behalf of the window's chrome (menus,
/// buttons): on the active surface, or app-scoped when there is none.
pub fn performBindingAction(self: *Window, action: @import("../../input.zig").Binding.Action) void {
    if (self.activePane()) |pane| {
        _ = pane.performBindingAction(action) catch |err| {
            log.err("binding action failed action={t} err={}", .{ action, err });
        };
        return;
    }
    if (action.scoped(.app)) |app_action| self.app.core_app.performAction(self.app, app_action) catch |err| {
        log.err("binding action failed action={t} err={}", .{ action, err });
    };
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

/// Feedback is deferred while a live Quick terminal is hidden or moving,
/// and discarded once its owner starts closing.
pub fn feedbackDisposition(self: *const Window) Notice.Disposition {
    if (self.closing) return .discard;
    if (!self.is_quick_terminal) return .ready;
    const qt = self.quickTerminal() orelse return .deferred;
    return if (qt.visible and !qt.animating) .ready else .deferred;
}

pub fn suspendFeedback(self: *Window) void {
    if (self.closing) {
        self.notice.hide();
        self.toast.hide();
        self.shortcut_notice.hide();
    } else {
        self.notice.deferUntilShown();
        self.toast.deferUntilShown();
        self.shortcut_notice.notice.deferUntilShown();
    }
}

pub fn resumeFeedback(self: *Window) void {
    const placement = self.overlayPlacement() orelse return;
    self.notice.onOwnerShown(placement);
    self.toast.onOwnerShown(placement);
    self.shortcut_notice.reposition();
    if (self.shortcut_notice.notice.placement) |where| self.shortcut_notice.notice.onOwnerShown(where);
}

/// Where the notice and the toast show: centered at the bottom of the
/// terminal area, at the window's content scale.
fn overlayPlacement(self: *const Window) ?Notice.Placement {
    const hwnd = self.hwnd orelse return null;
    return .{ .owner = hwnd, .area = self.surfaceRect(), .scale = self.scale };
}

/// Show `content` in the window's notice, replacing the one on display.
/// `callbacks` report the button picked and why it closed. GUI thread,
/// from the message loop; from a core callback use `postNotice`.
pub fn showNotice(self: *Window, content: Notice.Content, callbacks: ?Notice.Callbacks) void {
    const placement = self.overlayPlacement() orelse return;
    self.notice.show(self.app, placement, content, callbacks);
}

/// `showNotice` from a core callback (on the GUI thread): the notice shows
/// from the message loop (`Notice.post`).
pub fn postNotice(self: *Window, content: Notice.Content, callbacks: ?Notice.Callbacks) void {
    const placement = self.overlayPlacement() orelse return;
    self.notice.post(self.app, placement, content, callbacks);
}

/// Close the window's notice (reported as `Notice.CloseReason.owner`).
pub fn hideNotice(self: *Window) void {
    self.notice.hide();
}

/// Show `content` in the window's toast for a few seconds. GUI thread, from
/// the message loop; from a core callback use `postToast`.
pub fn showToast(self: *Window, content: Toast.Content) void {
    const placement = self.overlayPlacement() orelse return;
    self.toast.show(self.app, placement, content);
}

/// `showToast` from a core callback (on the GUI thread): the toast shows
/// from the message loop (`Toast.post`).
pub fn postToast(self: *Window, content: Toast.Content) void {
    const placement = self.overlayPlacement() orelse return;
    self.toast.post(self.app, placement, content);
}

/// Keep the notice and the toast on the terminal area after a move, a
/// resize, a DPI or language change or another tab.
fn repositionOverlays(self: *Window) void {
    const placement = self.overlayPlacement() orelse return;
    self.notice.reposition(placement);
    self.toast.reposition(placement);
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
const GA_ROOTOWNER: u32 = 3;
extern "user32" fn GetAncestor(hwnd: w32.HWND, gaFlags: u32) callconv(.winapi) ?w32.HWND;

const WM_WINDOWPOSCHANGED: u32 = 0x0047;
const SWP_HIDEWINDOW: u32 = 0x0080;
const WINDOWPOS = extern struct {
    hwnd: ?w32.HWND,
    hwndInsertAfter: ?w32.HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: u32,
};

/// The index of the tab whose split tree holds `surface`.
pub fn findTabIndex(self: *Window, view: anytype) ?usize {
    const surface = leafIdentity(view) orelse return null;
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// `surface` got the keyboard focus (WM_SETFOCUS): make it the focused
/// terminal of the tab whose split tree holds it, which may not be the
/// active tab, and show its title on the tab. A zoomed tab moves its zoom
/// to it or unzooms (`split-preserve-zoom`), so a focused pane is never
/// hidden. Returns false when no tab of this window holds `surface`.
pub fn setActiveSurface(self: *Window, view: anytype) bool {
    const surface = leafIdentity(view) orelse return false;
    const tab = self.findTabIndex(surface) orelse return false;
    const tree = &self.tab_trees[tab];
    const was_zoomed = tree.zoomed != null;
    if (tree.zoomed) |zoomed| {
        const handle = tree.locate(surface) orelse return false;
        if (handle != zoomed) {
            tree.zoom(splits.zoomAfterFocus(
                SplitTree(Leaf).Node.Handle,
                zoomed,
                handle,
                self.app.config.@"split-preserve-zoom".navigation,
            ));
            if (tab == self.active_tab) self.layoutSplits();
        }
    }
    if (self.tab_active_surface[tab] != surface) {
        self.tab_active_surface[tab] = surface;
        self.refreshTabTitle(tab);
        self.updateTabDim(tab);
    }
    if (was_zoomed != (tree.zoomed != null)) self.onTabZoomChanged(tab);
    return true;
}

/// Tell the renderers of the terminals of tab `tab` which of them to dim
/// (`Surface.setUnfocusedDim`, drawn by the renderer): the panes of a split
/// other than the tab's focused one (`split_layout.dimsPane`), covered by
/// `1 - unfocused-split-opacity` of `unfocused-split-fill` (else the
/// background). A tab that shows one pane, alone or zoomed, dims none, and
/// neither does the window losing the focus.
fn updateTabDim(self: *Window, tab: usize) void {
    if (tab >= self.tab_count) return;
    const config = &self.app.config;
    const fill = config.@"unfocused-split-fill" orelse config.background;
    const dim: Surface.DimColor = .init(fill.r, fill.g, fill.b, @floatCast(1 - config.@"unfocused-split-opacity"));
    const tree = &self.tab_trees[tab];
    var it = tree.iterator();
    while (it.next()) |entry| {
        const dims = split_layout.dimsPane(tree.isSplit(), tree.zoomed != null, entry.view == self.tab_active_surface[tab]);
        entry.view.setUnfocusedDim(if (dims) dim else .none);
    }
}

/// `updateTabDim` for every tab (the configuration changed).
fn updateDims(self: *Window) void {
    for (0..self.tab_count) |i| self.updateTabDim(i);
}

/// Tab `tab` zoomed one of its splits or stopped: its panes dim
/// differently and the tab bar shows the zoom (`tabStatus`).
fn onTabZoomChanged(self: *Window, tab: usize) void {
    if (self.hwnd != null and !self.is_quick_terminal) self.app.scheduleSessionSave();
    self.updateTabDim(tab);
    self.invalidateTabBar();
}

/// Find the Node.Handle for a surface in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, view: anytype) ?SplitTree(Leaf).Node.Handle {
    const surface = leafIdentity(view) orelse return null;
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}

/// Everything the window keeps per tab, for moving tabs between slots.
const TabSlot = struct {
    reference: gx.ui_ref.Reference,
    attachment: gx.ui_ref.Attachment,
    tree: SplitTree(Leaf),
    active_surface: *Leaf,
    title: [256]u16,
    title_len: u16,
    title_override: ?tabs.Title,
    unread: bool,
    bell: bool,
    activated: u64,
};

pub fn resolveTab(self: *const Window, reference: gx.ui_ref.Reference) ?usize {
    if (self.closing or !self.ui_reference.isValid() or reference.epoch != self.ui_reference.epoch or reference.kind != .tab) return null;
    for (self.tab_references[0..self.tab_count], 0..) |live, index| {
        if (reference.matches(live)) return index;
    }
    return null;
}

fn getSlot(self: *const Window, i: usize) TabSlot {
    return .{
        .reference = self.tab_references[i],
        .attachment = self.tab_attachments[i],
        .tree = self.tab_trees[i],
        .active_surface = self.tab_active_surface[i],
        .title = self.tab_titles[i],
        .title_len = self.tab_title_lens[i],
        .title_override = self.tab_title_overrides[i],
        .unread = self.tab_unread[i],
        .bell = self.tab_bell[i],
        .activated = self.tab_activated[i],
    };
}

fn setSlot(self: *Window, i: usize, slot: TabSlot) void {
    self.tab_references[i] = slot.reference;
    self.tab_attachments[i] = slot.attachment;
    self.tab_trees[i] = slot.tree;
    self.tab_active_surface[i] = slot.active_surface;
    self.tab_titles[i] = slot.title;
    self.tab_title_lens[i] = slot.title_len;
    self.tab_title_overrides[i] = slot.title_override;
    self.tab_unread[i] = slot.unread;
    self.tab_bell[i] = slot.bell;
    self.tab_activated[i] = slot.activated;
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
    if (self.is_quick_terminal and self.tab_count != 0) return error.QuickTerminalTabUnsupported;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    const reference = try self.app.ui_ids.create(.tab);
    const attachment = try self.app.ui_ids.attach(reference, self.ui_reference);
    self.tab_bar.cancelRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    surface.initWithOptions(self.app, self, options) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    // After surface.init succeeds, create the SplitTree which takes ownership
    // via ref(). If this fails, we manually clean up.
    const leaf = Leaf.fromLocal(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    var tree = SplitTree(Leaf).init(alloc, leaf) catch |err| {
        leaf.discardUnretained(alloc);
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

    self.cancelDividerDrag();
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) self.copySlot(i, i - 1);
    self.tab_references[pos] = reference;
    self.tab_attachments[pos] = attachment;
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = leaf;
    self.tab_unread[pos] = false;
    self.tab_bell[pos] = false;
    self.tab_activated[pos] = 0;
    self.tab_title_overrides[pos] = null;
    self.tab_title_lens[pos] = 0;
    if (self.tab_count > 0 and self.active_tab >= pos) self.active_tab += 1;
    self.tab_count += 1;

    // The terminal may have its title already (the `title` option).
    self.refreshTabTitle(pos);

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is
        // ready, uncloaking it with the first frame. Quick terminal
        // windows are shown by QuickTerminal.animateIn() instead.
        self.active_tab = pos;
        self.noteTabActivated(pos);
        self.tab_bar.onTabShown(pos);
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
    if (!self.is_quick_terminal) self.app.scheduleSessionSave();
    return surface;
}

/// Open a new tab that runs the command of the focused terminal of tab
/// `index` (its launch profile, if it was opened with one), with the same
/// title override. Selecting the tab first makes the new tab inherit that
/// terminal's working directory (`tab-inherit-working-directory`) and,
/// with the default `window-new-tab-position = current`, open next to it.
pub fn duplicateTab(self: *Window, index: usize) void {
    if (index >= self.tab_count) return;
    const surface = self.tab_active_surface[index].local();
    const title_override = self.tab_title_overrides[index];
    self.selectTabIndex(index);
    const duplicate = self.addTabWithOptions(.{
        .context = .tab,
        .command = if (surface) |local| if (local.launch_command) |*command| command else null else null,
        .profile_id = if (surface) |local| if (local.launch_command != null) local.launch_origin.profileId() else null else null,
    }) catch |err| {
        log.err("failed to duplicate the tab err={}", .{err});
        return;
    };
    const title = title_override orelse return;
    if (self.findTabIndex(duplicate)) |tab| self.setTabTitleOverride(tab, title);
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, view: anytype) void {
    const surface = leafIdentity(view) orelse return;
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
/// The tabs leave the tab model together and the window lays out once
/// before their terminals stop (`freeTrees`).
fn closeTabs(self: *Window, selection: TabSelection) void {
    _ = self.closeTabsRequested(selection);
}

fn closeTabsRequested(self: *Window, selection: TabSelection) bool {
    const hwnd = self.hwnd orelse return false;
    var ids: [MAX_TABS]refs.Reference = undefined;
    var count: usize = 0;
    var check: CloseCheck = .init(self.app.core_app.alloc);
    defer check.deinit();
    var scope: @import("../../gx/confirm.zig").Scope = undefined;
    scope.begin(self.app.core_app.alloc, @import("../../global.zig").io());
    defer scope.end();
    for (0..self.tab_count) |i| {
        if (!selection.contains(i)) continue;
        ids[count] = self.tab_references[i];
        count += 1;
        check.tab(self, i) catch |err| {
            log.err("cannot prepare the tab close confirmation err={}", .{err});
            return false;
        };
    }
    scope.end();
    check.done();
    if (count == 0) return false;
    // The tab that stays when the active one closes with others.
    const keep: usize = switch (selection) {
        .one => self.tab_count,
        .all_but, .right_of => |i| i,
    };
    const keep_id: ?refs.Reference = if (keep < self.tab_count) self.tab_references[keep] else null;

    if (check.needed) {
        const choice = if (count == 1)
            Dialogs.confirmCloseTabWithTitle(hwnd, check.groups.items[0])
        else
            Dialogs.confirmCloseTabsByTab(hwnd, check.groups.items);
        if (choice != .accept or !isAlive(hwnd, self)) return false;
    }

    if (self.tab_count == 0) return false;
    if (self.requestRemoteSelectionClose(ids[0..count])) return true;
    if (self.closeQuickSelection(ids[0..count])) return true;
    const focused = self.hasFocus();
    const active_id = self.tab_references[self.active_tab];
    const active_closed = referenceIndex(ids[0..count], active_id) != null;
    if (active_closed) {
        const preferred = if (keep_id) |id| self.resolveTab(id) else null;
        if (preferred) |index| {
            self.active_tab = index;
        } else {
            const start = tabs.closeNeighbor(self.active_tab, self.tab_count) orelse self.active_tab;
            for (0..self.tab_count) |offset| {
                const index = (start + offset) % self.tab_count;
                const id = self.tab_references[index];
                if (referenceIndex(ids[0..count], id) == null) {
                    self.active_tab = index;
                    break;
                }
            }
        }
    }
    self.tab_bar.cancelRename();
    self.tab_bar.cancelDrag();
    self.cancelDividerDrag();
    var trees: [MAX_TABS]Tree = undefined;
    var detached: usize = 0;
    for (ids[0..count]) |id| {
        const index = self.resolveTab(id) orelse continue;
        trees[detached] = self.detachTab(index);
        detached += 1;
    }
    if (detached == 0) return false;
    if (self.tab_count == 0) {
        self.hide();
        freeTrees(self.app, trees[0..detached]);
        _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return true;
    }
    for (trees[0..detached]) |*tree| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(false);
            if (entry.view.nativeHandle()) |child| _ = w32.ShowWindow(child, w32.SW_HIDE);
        }
    }
    const visibility_changed = self.tab_bar.updateVisibility();
    if (visibility_changed) self.applyFrameMargins();
    if (active_closed) {
        self.tab_unread[self.active_tab] = false;
        self.tab_bell[self.active_tab] = false;
        self.noteTabActivated(self.active_tab);
        self.applyScale(self.active_tab);
        self.layoutSplits();
        self.repositionTabPopups(self.active_tab);
        self.tab_bar.onTabShown(self.active_tab);
        if (focused) self.focusActiveSurface();
        self.updateWindowTitle();
    } else if (visibility_changed) {
        self.relayout();
    } else if (self.layout_key) |*key| {
        key.tab = self.active_tab;
    }
    self.repositionOverlays();
    self.invalidateTabBar();
    self.updateAppMode();
    freeTrees(self.app, trees[0..detached]);
    return true;
}

fn closeQuickSelection(self: *Window, ids: []const refs.Reference) bool {
    if (!self.is_quick_terminal or self.tab_count != 1) return false;
    if (referenceIndex(ids, self.tab_references[0]) == null) return false;
    self.removeTab(0);
    return true;
}

/// The index of the tab with the terminal whose core surface id is `id`,
/// e.g. to find a tab again after a modal loop.
pub fn findTabBySurfaceId(self: *Window, id: u64) ?usize {
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view.local()) |surface| if (surface.core_surface_initialized and surface.core_surface.id == id) return i;
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
/// The active tab hands over to its neighbor (`tabs.closeNeighbor`)
/// before it goes; closing another tab leaves the active one as it is.
fn removeTab(self: *Window, idx: usize) void {
    if (self.hwnd != null) {
        self.app.session.markRemoved();
        self.app.scheduleSessionSave();
    }
    if (idx >= self.tab_count or self.closing) return;
    if (self.is_quick_terminal and self.tab_count == 1) {
        if (self.app.quick_terminal) |qt| {
            if (qt.window == self) {
                self.closing = true;
                self.stopAppModeSoon();
                if (qt.onLastTabClosed()) return;
            }
        }
    }
    // Cancel any in-progress rename (the edit control may belong to this
    // tab) and tab drag (the dragged index shifts).
    self.tab_bar.cancelRename();
    self.tab_bar.cancelDrag();
    self.cancelDividerDrag();
    if (idx == self.active_tab) {
        if (tabs.closeNeighbor(idx, self.tab_count)) |neighbor| self.selectTabIndex(neighbor);
    }
    // Take the tab out of the model before its terminals go away: their
    // windows hide and pass the focus on meanwhile.
    var tree = [1]Tree{self.detachTab(idx)};
    if (self.tab_count == 0) {
        // The window closes: off the screen before its terminals stop.
        self.hide();
        self.stopAppModeSoon();
        freeTrees(self.app, &tree);
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    self.updateTabBarVisibility();
    // The tab bar stays visible with `window-show-tab-bar = always`, so
    // nothing else repaints it without the removed tab.
    self.invalidateTabBar();
    self.updateAppMode();
    freeTrees(self.app, &tree);
}

/// Take the tab at `idx` out of the tab model, keeping the active tab, and
/// return its split tree for the caller to free (`freeTrees`) or move.
fn detachTab(self: *Window, idx: usize) Tree {
    const tree = self.tab_trees[idx];
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) self.copySlot(i, i + 1);
    self.tab_count -= 1;
    if (self.tab_count > 0) self.active_tab = tabs.indexAfterRemove(self.active_tab, idx);
    return tree;
}

/// Free the split trees `trees`, out of the tab model, and their
/// terminals: all of them stop their renderer and IO threads at once
/// first, so the terminals go in parallel rather than one after the other,
/// then each terminal is freed and its window destroyed
/// (`destroyFreedWindow`).
fn freeTrees(app: *App, trees: []Tree) void {
    for (trees) |*tree| stopTerminalThreads(tree);
    for (trees) |*tree| {
        var windows: [PaneLayout.capacity]w32.HWND = undefined;
        var count: usize = 0;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (count == windows.len) break;
            windows[count] = entry.view.nativeHandle() orelse continue;
            count += 1;
        }
        tree.deinit(); // Unrefs all surfaces: Surface.unref frees them.
        for (windows[0..count]) |hwnd| destroyFreedWindow(app, hwnd);
    }
}

/// Ask the renderer and IO threads of the terminals that freeing `tree`
/// frees (no other tree holds them) to stop, without waiting for them;
/// `Surface.deinit` joins them.
fn stopTerminalThreads(tree: *const Tree) void {
    var it = tree.iterator();
    while (it.next()) |entry| {
        const surface = entry.view.local() orelse continue;
        if (!surface.core_surface_ready or surface.ref_count != 1) continue;
        surface.core_surface.renderer_thread.stop.notify() catch {};
        surface.core_surface.io_thread.stop.notify() catch {};
    }
}

/// Collects whether closing some terminals needs a confirmation and the
/// processes that make it so. All the terminals of one check read one
/// process table (`gx.confirm.Scope`), from the first terminal to `done`,
/// which has to come before the confirmation: its modal loop can run
/// other confirmations, which need the processes of their own time.
const CloseCheck = struct {
    arena: std.heap.ArenaAllocator,
    groups: std.ArrayList(Dialogs.ProcessGroup) = .empty,
    needed: bool = false,
    scope: gx.confirm.Scope = undefined,
    scoped: bool = false,

    fn init(alloc: Allocator) CloseCheck {
        return .{ .arena = .init(alloc) };
    }

    fn deinit(self: *CloseCheck) void {
        self.done();
        self.arena.deinit();
    }

    fn tab(self: *CloseCheck, window: *Window, index: usize) Allocator.Error!void {
        const group = try window.closeGroup(index, self.arena.allocator()) orelse return;
        try self.groups.append(self.arena.allocator(), group);
        self.needed = true;
    }

    /// The terminals are checked: free the process table.
    fn done(self: *CloseCheck) void {
        if (!self.scoped) return;
        self.scope.end();
        self.scoped = false;
    }

    fn surface(self: *CloseCheck, s: *Surface) void {
        if (!s.core_surface_ready) return;
        if (!self.scoped) {
            self.scope.begin(self.arena.child_allocator, global.io());
            self.scoped = true;
        }
        if (!s.core_surface.needsConfirmQuit()) return;
        self.needed = true;
    }
};

/// The confirmation data of one tab, owned by `alloc`, or null when none
/// of its terminals needs confirmation. Collect under a gx.confirm.Scope
/// and end that scope before the modal dialog.
pub fn closeGroup(self: *Window, index: usize, alloc: Allocator) Allocator.Error!?Dialogs.ProcessGroup {
    if (index >= self.tab_count) return null;
    var processes: std.ArrayList([]const u8) = .empty;
    var needed = false;
    var it = self.tab_trees[index].iterator();
    while (it.next()) |entry| {
        const surface = entry.view;
        if (!surface.needsConfirmQuit()) continue;
        needed = true;
        surface.appendBusyProcesses(alloc, &processes);
    }
    if (!needed) return null;
    return try ownedCloseGroup(alloc, self.tab_titles[index][0..self.tab_title_lens[index]], processes.items);
}

fn ownedCloseGroup(alloc: Allocator, title: []const u16, processes: []const []const u8) Allocator.Error!Dialogs.ProcessGroup {
    const copied_title = try std.unicode.wtf16LeToWtf8Alloc(alloc, title);
    errdefer alloc.free(copied_title);
    const copied_processes = try alloc.alloc([]const u8, processes.len);
    errdefer alloc.free(copied_processes);
    var copied: usize = 0;
    errdefer for (copied_processes[0..copied]) |name| alloc.free(name);
    for (processes, copied_processes) |name, *destination| {
        destination.* = try alloc.dupe(u8, name);
        copied += 1;
    }
    return .{ .title = copied_title, .processes = copied_processes };
}

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
/// in the tab, close the entire tab instead. The focus stays where it is
/// unless the closing surface is the tab's focused one; then the pane
/// before it in the tree's order, or after it when it was the first,
/// takes over (`splits.focusAfterClose`, as in the GTK and macOS apps),
/// and gets the keyboard focus if the tab is shown and the window has it.
pub fn closeSplitSurface(self: *Window, view: anytype) void {
    const surface = leafIdentity(view) orelse return;
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

    const handle = tree.locate(surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });

    const was_active = self.tab_active_surface[tab] == surface;
    const next: *Leaf = if (!was_active) self.tab_active_surface[tab] else next: {
        const next_handle = splits.focusAfterClose(SplitTree(Leaf), alloc, tree, handle) orelse {
            self.removeTab(tab);
            return;
        };
        break :next tree.nodes[next_handle.idx()].leaf;
    };
    const focused = was_active and self.hasFocus();
    const was_zoomed = tree.zoomed != null;

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };

    // Before the closing terminal hides: its focus goes to this window,
    // which passes it to the active surface.
    const closed_hwnd = surface.nativeHandle();
    self.tab_active_surface[tab] = next;
    self.replaceTree(tab, new_tree);
    destroyFreedWindow(self.app, closed_hwnd);
    self.refreshTabTitle(tab);
    self.updateTabDim(tab);
    if (was_zoomed != (self.tab_trees[tab].zoomed != null)) self.invalidateTabBar();
    if (tab == self.active_tab) {
        self.layoutSplits();
        if (focused) {
            if (next.nativeHandle()) |h| _ = w32.SetFocus(h);
        }
    }
    self.updateAppMode();
}

/// Destroy the window `hwnd` of a terminal its split tree freed: the
/// terminal let go of it (`Surface.deinit` clears its window's
/// GWLP_USERDATA), its renderer and GL context are gone, and otherwise the
/// hidden window and its private DC would stay until the top-level window
/// closes. A terminal still alive (another tree holds it) keeps its window.
fn destroyFreedWindow(app: *App, hwnd: ?w32.HWND) void {
    const h = hwnd orelse return;
    if (w32.IsWindow(h) == 0 or w32.GetWindowLongPtrW(h, w32.GWLP_USERDATA) != 0) return;
    if (app.deferDropWindowDestroy(h)) return;
    _ = w32.DestroyWindow(h);
}

/// Set the visibility (occlusion) of the surfaces of the active tab that
/// are shown (only the zoomed one of a zoomed tab), so the renderers stop
/// rebuilding frames nobody sees. The window does so itself for the
/// reasons in `occlusion` (`setOcclusion`). GUI thread.
pub fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    const tree = &self.tab_trees[self.active_tab];
    var it = tree.iterator();
    while (it.next()) |entry| {
        const shown = if (tree.zoomed) |zoomed| entry.handle == zoomed else true;
        entry.view.setVisible(visible and shown);
    }
}

/// Whether the terminals of the active tab can be seen (`occlusion`).
fn terminalsSeen(self: *const Window) bool {
    return !self.closing and !self.occlusion.any();
}

fn pollingVisible(self: *const Window) bool {
    const hwnd = self.hwnd orelse return false;
    return self.terminalsSeen() and w32.IsWindowVisible_(hwnd) != 0 and w32.IsIconic(hwnd) == 0;
}

/// Set one reason in `occlusion` and tell the renderers of the active tab
/// whether their terminals are seen now.
fn setOcclusion(self: *Window, comptime reason: []const u8, occluded: bool) void {
    if (@field(self.occlusion, reason) == occluded) return;
    @field(self.occlusion, reason) = occluded;
    const seen = self.terminalsSeen();
    self.setViewVisible(seen);
    self.setActiveTabVisible(seen);
    if (self.hwnd) |hwnd| {
        if (seen and !self.is_quick_terminal) {
            _ = w32.SetTimer(hwnd, CHROME_TIMER_ID, chrome_timer_ms, null);
            self.app_mode_due_ms = 0;
        } else {
            _ = w32.KillTimer(hwnd, CHROME_TIMER_ID);
            self.stopAppModeSoon();
        }
    }
}

/// Revoke root/tab view providers while occluded without losing object IDs.
/// Showing the window again publishes new revisions for the same live objects.
fn setViewVisible(self: *Window, visible: bool) void {
    self.uia_dirty = true;
    if (!visible) self.uia_bridge.hide();
    self.ui_attachment.setVisible(&self.app.ui_ids, self.ui_reference, self.ui_reference, visible) catch |err| {
        log.warn("cannot publish window view err={}", .{err});
    };
    for (self.tab_references[0..self.tab_count], self.tab_attachments[0..self.tab_count]) |reference, *attachment| {
        attachment.setVisible(&self.app.ui_ids, reference, self.ui_reference, visible) catch |err| {
            log.warn("cannot publish tab view err={}", .{err});
        };
    }
}

/// Hide the panes of tab `tab`, which is no longer shown.
fn hideTabPanes(self: *Window, tab: usize) void {
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        entry.view.setVisible(false);
        if (entry.view.nativeHandle()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }
    self.tab_bar.onTabHidden(tab);
}

/// Make every visible terminal draw a complete new frame (see
/// `Surface.refreshRenderer`), e.g. after the system resumed.
pub fn refreshRenderers(self: *Window) void {
    if (self.active_tab >= self.tab_count) return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| entry.view.refreshRenderer();
}

/// Move the screen-positioned popups of the terminals of the active tab
/// (scrollbars, find bars) and of the window after the window moved. The
/// popups of the other tabs are hidden; they move when their tab is
/// selected (`selectTabIndex`).
fn repositionPopups(self: *Window) void {
    if (self.palette.active) self.palette.reposition();
    if (self.quickTerminal()) |qt| if (qt.animating or !qt.visible) return;
    if (self.tab_count > 0) self.repositionTabPopups(self.active_tab);
    self.shortcut_notice.reposition();
    self.repositionOverlays();
}

fn repositionTabPopups(self: *Window, tab: usize) void {
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| entry.view.repositionPopups();
}

/// Switch to the tab at `idx`: show its panes, move the keyboard focus to
/// its focused terminal when this window has the focus, then hide the
/// panes of the previous tab, so the focus never passes through a hidden
/// pane. Selecting the active tab again only gives its terminal the focus.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (self.hwnd != null and !self.is_quick_terminal) self.app.scheduleSessionSave();
    if (idx >= self.tab_count) return;
    self.tab_bar.cancelRename();
    // Clear any in-progress tab drag
    self.tab_bar.cancelDrag();
    const previous = self.active_tab;
    if (idx == previous) {
        self.focusActiveSurface();
        return;
    }
    const focused = self.hasFocus();
    self.cancelDividerDrag();
    self.divider_hover = null;
    self.active_tab = idx;
    self.tab_unread[idx] = false;
    self.tab_bell[idx] = false;
    self.noteTabActivated(idx);
    self.applyScale(idx);
    self.layoutSplits();
    // Its popups stayed where they were while the window moved.
    self.repositionTabPopups(idx);
    if (focused) self.focusActiveSurface();
    if (previous < self.tab_count) self.hideTabPanes(previous);
    self.tab_bar.onTabShown(idx);
    self.updateWindowTitle();
    self.invalidateTabBar();
    self.repositionOverlays();
}

/// Tab `tab` was selected: it is the most recent one now (`tabRecency`).
fn noteTabActivated(self: *Window, tab: usize) void {
    self.activation_count += 1;
    self.tab_activated[tab] = self.activation_count;
}

/// How recently tab `i` was selected: higher is more recent, 0 for never.
/// Sort by it, highest first, for the tabs in the order of their last use.
/// GUI thread.
pub fn tabRecency(self: *const Window, i: usize) u64 {
    if (i >= self.tab_count) return 0;
    return self.tab_activated[i];
}

/// What the tab bar shows on tab `i` besides its title: unread output, the
/// bell, zoom and the progress its terminals report (`tab_status.merge`).
/// GUI thread.
pub fn tabStatus(self: *const Window, i: usize) tab_status.TabStatus {
    if (i >= self.tab_count) return .{};
    const now = GetTickCount64();
    var progress: tab_status.Progress = .none;
    var it = self.tab_trees[i].iterator();
    while (it.next()) |entry| progress = tab_status.merge(progress, entry.view.progress(), now);
    return .{
        .unread = self.tab_unread[i],
        .bell = self.tab_bell[i],
        .zoomed = self.tab_trees[i].zoomed != null,
        .progress = progress,
    };
}

/// The terminal `surface` reported progress (OSC 9;4, the `progress_report`
/// action): keep it as the terminal's latest report (`Surface.progress`)
/// for its tab (`tabStatus`), and repaint the tab bar when it changed.
/// GUI thread.
pub fn setSurfaceProgress(self: *Window, surface: *Surface, report: apprt.Action.Value(.progress_report)) void {
    const progress: tab_status.Progress = .{
        .state = switch (report.state) {
            .remove => .none,
            .set => .normal,
            .@"error" => .@"error",
            .indeterminate => .indeterminate,
            .pause => .paused,
        },
        .percent = if (report.progress) |percent| @min(percent, 100) else null,
        .updated_ms = GetTickCount64(),
    };
    const changed = progress.state != surface.progress.state or
        !std.meta.eql(progress.percent, surface.progress.percent);
    surface.progress = progress;
    if (changed and self.findTabIndex(surface) != null) self.invalidateTabBar();
}

/// The terminal `surface` rang the bell: mark its tab (`tabStatus`) until
/// the tab is selected, unless it is the active tab, and repaint the tab
/// bar. GUI thread.
pub fn ringTab(self: *Window, view: anytype) void {
    const surface = leafIdentity(view) orelse return;
    const tab = self.findTabIndex(surface) orelse return;
    if (tab == self.active_tab or self.tab_bell[tab]) return;
    self.tab_bell[tab] = true;
    self.invalidateTabBar();
}

/// Layout split panes for the active tab (`split_layout.walk`): a zoomed
/// tab shows only its zoomed pane. The panes move in one DeferWindowPos
/// batch, so they resize together instead of one after the other; during a
/// live resize the window then waits once for all of them to present a
/// frame at the new size. A size overlay whose pane left the screen goes
/// first (`dropStaleResizeOverlay`).
pub fn layoutSplits(self: *Window) void {
    self.dropStaleResizeOverlay();
    if (self.tab_count == 0) return;
    self.layout_passes +|= 1;
    const tree = &self.tab_trees[self.active_tab];
    self.layout_key = self.layoutKey();
    var panes: PaneLayout = .{ .visible = self.terminalsSeen() };
    split_layout.walk(Tree, tree, self.splitArea(), self.splitMetrics().gap, &panes);
    if (tree.zoomed != null) {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (panes.holds(entry.view)) continue;
            entry.view.setVisible(false);
            if (entry.view.nativeHandle()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    self.laying_out = true;
    panes.apply();
    self.laying_out = false;
    panes.awaitResizeFrames();

    // The panes of a single pane or a zoomed tab cover the whole area.
    // Between split panes, repaint the gaps and the divider lines directly
    // using GetDC (not BeginPaint, which clips to the invalid region and
    // misses the gaps), so no line of a previous layout or background of a
    // previous opacity stays behind.
    if (!tree.isSplit() or tree.zoomed != null) return;
    self.repaintSplitGaps();
}

/// The split tree of a tab.
const Tree = SplitTree(Leaf);

fn layoutKey(self: *const Window) LayoutKey {
    const tree = &self.tab_trees[self.active_tab];
    return .{
        .area = self.surfaceRect(),
        .scale = self.scale,
        .tab = self.active_tab,
        .nodes = @intFromPtr(tree.nodes.ptr),
        .zoomed = tree.zoomed,
    };
}

/// Lay the panes out again (`layoutSplits`) unless the last layout still
/// holds (a WM_SIZE on the way here did it); repaint the split gaps either
/// way, for a new background or divider color.
fn relayout(self: *Window) void {
    self.uia_dirty = true;
    self.uia_bridge.dirty();
    self.dropStaleResizeOverlay();
    if (self.tab_count == 0) return;
    if (self.layout_key) |key| if (std.meta.eql(key, self.layoutKey())) return self.repaintSplitGaps();
    self.layoutSplits();
}

/// A divider of the active tab laid out over the terminal area.
const Divider = split_layout.Divider(Tree);

/// The terminal area the panes of the active tab share.
fn splitArea(self: *const Window) split_layout.Rect {
    return @bitCast(self.surfaceRect());
}

/// The gap between split panes and the divider lines, in pixels.
fn splitMetrics(self: *const Window) split_layout.Metrics {
    return .forScale(self.scale);
}

/// How far from its line a divider takes the mouse, in pixels: at least
/// the whole gap.
fn dividerReach(self: *const Window) i32 {
    return @max(style.px(3, self.scale), @divTrunc(self.splitMetrics().gap + 1, 2));
}

/// The visible panes of one layout pass and where they go.
const PaneLayout = struct {
    const capacity = protocol.max_leaves;

    surfaces: [capacity]*Leaf = undefined,
    rects: [capacity]w32.RECT = undefined,
    len: usize = 0,
    /// What the panes tell their renderers (`Surface.setVisible`): false
    /// while the window is occluded.
    visible: bool = true,

    /// `split_layout.walk` visitor.
    pub fn pane(self: *PaneLayout, _: Tree.Node.Handle, surface: *Leaf, rect: split_layout.Rect) void {
        self.add(surface, @bitCast(rect));
    }

    /// Whether the pass shows `surface`, for a zoomed tab (one pane).
    fn holds(self: *const PaneLayout, surface: *Leaf) bool {
        return std.mem.indexOfScalar(*Leaf, self.surfaces[0..self.len], surface) != null;
    }

    fn add(self: *PaneLayout, surface: *Leaf, rect: w32.RECT) void {
        if (self.len == capacity) {
            surface.setVisible(self.visible);
            place(surface, rect);
            return;
        }
        self.surfaces[self.len] = surface;
        self.rects[self.len] = rect;
        self.len += 1;
    }

    const flags = w32.SWP_NOZORDER | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW;

    /// Mark the panes visible (unless the window is occluded), then move
    /// and show them in one batch, or one by one when the batch fails.
    fn apply(self: *const PaneLayout) void {
        const surfaces = self.surfaces[0..self.len];
        const rects = self.rects[0..self.len];
        for (surfaces) |surface| surface.setVisible(self.visible);
        defer {
            if (!self.visible) for (surfaces) |surface| surface.setVisible(false);
        }

        batch: {
            var hdwp = w32.BeginDeferWindowPos(@intCast(self.len)) orelse break :batch;
            for (surfaces, rects) |surface, rect| {
                const hwnd = surface.nativeHandle() orelse continue;
                // A failed DeferWindowPos abandons the whole batch.
                hdwp = w32.DeferWindowPos(hdwp, hwnd, null, rect.left, rect.top, width(rect), height(rect), flags) orelse
                    break :batch;
            }
            if (w32.EndDeferWindowPos(hdwp) != 0) return;
        }
        for (surfaces, rects) |surface, rect| place(surface, rect);
    }

    fn place(surface: *Leaf, rect: w32.RECT) void {
        const hwnd = surface.nativeHandle() orelse return;
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
        var locals: [capacity]*Surface = undefined;
        var count: usize = 0;
        for (self.surfaces[0..self.len]) |leaf| if (leaf.local()) |surface| {
            locals[count] = surface;
            count += 1;
        };
        _ = Surface.awaitResizeFrames(locals[0..count]);
    }
};

/// Paint the part of the client area below the chrome that no pane covers
/// with the terminal background, then the split dividers (WM_ERASEBKGND;
/// the panes are clipped out). When DWM composes the window per pixel the
/// background gets the terminals' `background-opacity`, so the material
/// shows through the gaps alike.
fn eraseSurfaceArea(self: *Window, hdc: w32.HDC) void {
    self.fillTerminalBackground(hdc, self.surfaceRect());
    self.paintDividers(hdc, false);
}

/// Repaint the gaps between the split panes of the active tab and their
/// divider lines, outside WM_PAINT.
fn repaintSplitGaps(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = &self.tab_trees[self.active_tab];
    if (!tree.isSplit() or tree.zoomed != null) return;
    const hwnd = self.hwnd orelse return;
    const dc = w32.GetDC(hwnd) orelse return;
    defer _ = w32.ReleaseDC(hwnd, dc);
    self.paintDividers(dc, true);
}

/// Paint the divider lines of the active tab, the hovered or dragged one
/// thicker in the accent color, after filling the gaps they lie in with
/// the terminal background when `fill_gaps`.
fn paintDividers(self: *Window, hdc: w32.HDC, fill_gaps: bool) void {
    if (self.tab_count == 0) return;
    const tree = &self.tab_trees[self.active_tab];
    if (!tree.isSplit() or tree.zoomed != null) return;
    const Painter = struct {
        window: *Window,
        hdc: w32.HDC,
        fill_gaps: bool,
        metrics: split_layout.Metrics,
        colors: DividerColors,

        pub fn divider(painter: *@This(), d: Divider) void {
            if (painter.fill_gaps) painter.window.fillTerminalBackground(painter.hdc, @bitCast(d.band));
            const active = painter.window.dividerActive(d.handle);
            const line = d.line(if (active) painter.metrics.line_active else painter.metrics.line);
            painter.window.fillColor(painter.hdc, @bitCast(line), if (active) painter.colors.active else painter.colors.normal);
        }
    };
    const metrics = self.splitMetrics();
    var painter: Painter = .{
        .window = self,
        .hdc = hdc,
        .fill_gaps = fill_gaps,
        .metrics = metrics,
        .colors = self.dividerColors(),
    };
    split_layout.walk(Tree, tree, self.splitArea(), metrics.gap, &painter);
}

/// Fill `rect` of the window DC `hdc` with the terminal background.
fn fillTerminalBackground(self: *Window, hdc: w32.HDC, rect: w32.RECT) void {
    const config = &self.app.config;
    if (Backdrop.perPixel(config, self.app.alpha_frames)) {
        Backdrop.fillBackground(hdc, rect, config);
    } else if (self.app.bg_brush) |brush| {
        _ = w32.FillRect(hdc, &rect, brush);
    }
}

/// Fill `rect` of the window DC `hdc` with the opaque `color`, also when
/// DWM composes the window per pixel (where GDI leaves its pixels
/// transparent).
fn fillColor(self: *Window, hdc: w32.HDC, rect: w32.RECT, color: configpkg.Config.Color) void {
    if (Backdrop.perPixel(&self.app.config, self.app.alpha_frames)) {
        Backdrop.fillOpaque(hdc, rect, color);
        return;
    }
    const brush = w32.GetStockObject(DC_BRUSH) orelse return;
    _ = SetDCBrushColor(hdc, w32.RGB(color.r, color.g, color.b));
    _ = w32.FillRect(hdc, &rect, @ptrCast(brush));
}

/// The colors of the split dividers: `split-divider-color`, else the
/// foreground mixed into the background (`gx.chrome.divider`), and the
/// accent for the one hovered or dragged; the system colors in high
/// contrast.
const DividerColors = struct {
    normal: configpkg.Config.Color,
    active: configpkg.Config.Color,
};

fn dividerColors(self: *const Window) DividerColors {
    const config = &self.app.config;
    if (style.system.highContrast()) {
        const colors: gx.chrome.Chrome = .fromSystem(style.system.colors);
        return .{ .normal = rgb8(colors.divider), .active = rgb8(colors.divider_active) };
    }
    const tokens = style.Tokens.fromConfig(config);
    const options = gx.chrome.Options.fromConfig(config);
    return .{
        .normal = rgb8(options.divider orelse gx.chrome.divider(tokens.background, tokens.foreground)),
        .active = rgb8(tokens.accent),
    };
}

fn rgb8(color: style.Color) configpkg.Config.Color {
    const c = color.toRgb8();
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

const DC_BRUSH: i32 = 18;
extern "gdi32" fn SetDCBrushColor(hdc: w32.HDC, color: u32) callconv(.winapi) u32;

/// Whether the divider of the split `handle` of the active tab is hovered
/// or dragged.
fn dividerActive(self: *const Window, handle: Tree.Node.Handle) bool {
    if (self.dragging_split) return self.drag_split_tab == self.active_tab and self.drag_split_handle == handle;
    return self.divider_hover == handle;
}

/// The divider of the active tab at client (x, y), if any.
fn hitTestDivider(self: *Window, x: i32, y: i32) ?Divider {
    if (self.tab_count == 0) return null;
    const tree = &self.tab_trees[self.active_tab];
    if (!tree.isSplit() or tree.zoomed != null) return null;
    return split_layout.hitTest(Tree, tree, self.splitArea(), self.splitMetrics().gap, self.dividerReach(), x, y);
}

/// The pointer moved over the client area at (x, y) without dragging a
/// divider: highlight the divider under it, if any.
fn updateDividerHover(self: *Window, x: i32, y: i32) void {
    const hit = self.hitTestDivider(x, y);
    self.setDividerHover(if (hit) |d| d.handle else null);
    if (hit == null or self.divider_tracking) return;
    const hwnd = self.hwnd orelse return;
    var tme = w32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
        .dwFlags = w32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (w32.TrackMouseEvent(&tme) != 0) self.divider_tracking = true;
}

/// Highlight the divider of the split `handle` of the active tab (none for
/// null) and repaint the dividers when that changed.
fn setDividerHover(self: *Window, handle: ?Tree.Node.Handle) void {
    if (self.divider_hover == handle) return;
    self.divider_hover = handle;
    if (!self.dragging_split) self.repaintSplitGaps();
}

/// The least a pane keeps of its split while a divider is dragged, in DIPs.
const min_pane_size: f32 = 40;

/// Start dragging the divider `hit`, grabbed at the pointer offset `grab`
/// from its line: the panes of the tab resize like in a live resize of the
/// window, each layout waiting for their frames at the new size.
fn startDividerDrag(self: *Window, hit: Divider, grab: i32) void {
    self.dragging_split = true;
    self.drag_split_tab = self.active_tab;
    self.drag_split_handle = hit.handle;
    self.drag_split_layout = hit.layout;
    self.drag_grab_offset = grab;
    self.setPanesLiveResize(self.active_tab, true);
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
    self.repaintSplitGaps();
}

/// Mark the panes of tab `tab` as in a live resize (`Surface.handleResize`
/// then waits for a frame at each new size), or not.
fn setPanesLiveResize(self: *Window, tab: usize, live: bool) void {
    if (tab >= self.tab_count) return;
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| entry.view.setLiveResize(live);
}

/// Move the dragged divider to follow the pointer at (x, y): the ratio of
/// its split comes from the split's own rectangle, keeping the offset at
/// which the divider was grabbed. The drag ends instead when its split is
/// gone.
fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const tab = self.drag_split_tab;
    if (tab != self.active_tab or tab >= self.tab_count) return self.cancelDividerDrag();
    const tree = &self.tab_trees[tab];
    const handle = self.drag_split_handle;
    if (handle.idx() >= tree.nodes.len) return self.cancelDividerDrag();
    const current = switch (tree.nodes[handle.idx()]) {
        .leaf => return self.cancelDividerDrag(),
        .split => |s| if (s.layout != self.drag_split_layout) return self.cancelDividerDrag() else s.ratio,
    };
    const metrics = self.splitMetrics();
    const divider = split_layout.findDivider(Tree, tree, self.splitArea(), metrics.gap, handle) orelse
        return self.cancelDividerDrag();

    const rect = divider.rect;
    const min_size = style.px(min_pane_size, self.scale) + metrics.gap;
    const ratio: f16 = @floatCast(switch (self.drag_split_layout) {
        .horizontal => splits.ratioAt(rect.left, rect.width(), x - self.drag_grab_offset, min_size),
        .vertical => splits.ratioAt(rect.top, rect.height(), y - self.drag_grab_offset, min_size),
    });
    if (ratio == current) return;
    tree.resizeInPlace(handle, ratio);
    self.layoutSplits();
    self.showResizeOverlay();
}

/// End a divider drag: the button went up, the capture went elsewhere or
/// the split tree changed under it.
fn cancelDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    self.setPanesLiveResize(self.drag_split_tab, false);
    self.divider_hover = null;
    if (self.hwnd) |hwnd| {
        if (w32.GetCapture() == hwnd) _ = w32.ReleaseCapture();
    }
    if (self.drag_split_tab == self.active_tab) self.repaintSplitGaps();
}

/// Replace the split tree of tab `tab` and free the old one. A divider
/// drag in that tab ends and its divider is no longer hovered: their nodes
/// belong to the old tree.
fn replaceTree(self: *Window, tab: usize, tree: SplitTree(Leaf)) void {
    if (!self.is_quick_terminal) self.app.scheduleSessionSave();
    if (self.drag_split_tab == tab) self.cancelDividerDrag();
    if (tab == self.active_tab) self.divider_hover = null;
    var old = self.tab_trees[tab];
    self.tab_trees[tab] = tree;
    old.deinit();
}

/// Create a new split in the active tab. The new terminal starts in the
/// half of the focused pane it takes (`split_layout.insertRect`), so its pty
/// starts at its final size rather than the size of the whole tab.
pub fn newSplit(self: *Window, direction: SplitTree(Leaf).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;
    const was_zoomed = self.tab_trees[tab].zoomed != null;

    // Splitting unzooms the tab.
    const metrics = self.splitMetrics();
    var geometry = self.tab_trees[tab];
    geometry.zoomed = null;
    const area = self.splitArea();
    const pane = split_layout.paneRect(Tree, &geometry, area, metrics.gap, handle) orelse area;
    const rect: w32.RECT = @bitCast(split_layout.insertRect(Tree.Split.Direction, pane, direction, metrics.gap));

    // Create new surface. Once the single-node tree holds it, freeing the
    // tree frees the surface.
    const new_surface = try alloc.create(Surface);
    new_surface.initWithOptions(self.app, self, .{ .context = .split, .rect = rect }) catch |err| {
        const new_hwnd = new_surface.hwnd;
        new_surface.deinit();
        alloc.destroy(new_surface);
        destroyFreedWindow(self.app, new_hwnd);
        return err;
    };
    const new_hwnd = new_surface.hwnd;
    const new_leaf = Leaf.fromLocal(alloc, new_surface) catch |err| {
        new_surface.deinit();
        alloc.destroy(new_surface);
        destroyFreedWindow(self.app, new_hwnd);
        return err;
    };
    var insert_tree = SplitTree(Leaf).init(alloc, new_leaf) catch |err| {
        new_leaf.discardUnretained(alloc);
        new_surface.deinit();
        alloc.destroy(new_surface);
        destroyFreedWindow(self.app, new_hwnd);
        return err;
    };
    // On an error the terminal is freed with `insert_tree`, then its window.
    errdefer destroyFreedWindow(self.app, new_hwnd);
    defer insert_tree.deinit();

    // Split the current tree at the active surface.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Focus the new surface.
    self.tab_active_surface[tab] = new_leaf;
    self.replaceTree(tab, new_tree);
    self.refreshTabTitle(tab);
    self.updateTabDim(tab);
    if (was_zoomed) self.invalidateTabBar();

    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
    self.updateAppMode();
}

/// Focus the split in direction `goto_target` from the focused split of
/// the tab of `surface` (`goto_split`); previous and next wrap around.
/// Returns false when there is none, so that the key reaches the
/// terminal. A zoomed tab moves its zoom to the newly focused split with
/// `split-preserve-zoom = navigation` and unzooms otherwise, so the focus
/// never lands on a hidden split.
pub fn gotoSplit(self: *Window, view: anytype, goto_target: apprt.action.GotoSplit) bool {
    const surface = leafIdentity(view) orelse return false;
    const tab = self.findTabIndex(surface) orelse return false;
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return false;
    const from = tree.locate(self.tab_active_surface[tab]) orelse return false;

    const target: SplitTree(Leaf).Goto = switch (goto_target) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };
    const dest = (tree.goto(self.app.core_app.alloc, from, target) catch return false) orelse return false;
    if (dest == from) return false;
    const next = switch (tree.nodes[dest.idx()]) {
        .leaf => |candidate| candidate,
        .split => return false,
    };

    const zoomed = tree.zoomed != null;
    if (zoomed) tree.zoom(splits.zoomAfterFocus(
        SplitTree(Leaf).Node.Handle,
        tree.zoomed,
        dest,
        self.app.config.@"split-preserve-zoom".navigation,
    ));
    self.tab_active_surface[tab] = next;
    self.refreshTabTitle(tab);
    self.updateTabDim(tab);
    if (zoomed and tree.zoomed == null) self.invalidateTabBar();
    if (tab == self.active_tab) {
        if (zoomed) self.layoutSplits();
        if (next.nativeHandle()) |h| _ = w32.SetFocus(h);
    }
    return true;
}

/// Resize the split nearest to the focused split of the tab of `surface`
/// in the given direction by the given pixel amount (`resize_split`).
/// Returns false, letting the key reach the terminal, when the tab has no
/// splits.
pub fn resizeSplit(self: *Window, view: anytype, rs: apprt.action.ResizeSplit) bool {
    const surface = leafIdentity(view) orelse return false;
    const tab = self.findTabIndex(surface) orelse return false;
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit() or rs.amount == 0) return false;
    const handle = tree.locate(self.tab_active_surface[tab]) orelse return false;

    const layout: SplitTree(Leaf).Split.Layout = switch (rs.direction) {
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
    const delta: f16 = @floatCast(std.math.clamp(sign * @as(f32, @floatFromInt(rs.amount)) / dimension, -1, 1));

    const was_zoomed = tree.zoomed != null;
    const new_tree = tree.resize(self.app.core_app.alloc, handle, layout, delta) catch return false;
    self.replaceTree(tab, new_tree);
    if (was_zoomed != (self.tab_trees[tab].zoomed != null)) self.onTabZoomChanged(tab);
    if (tab == self.active_tab) self.layoutSplits();
    return true;
}

/// Equalize all splits in the tab of `surface` (`equalize_splits`).
/// Returns false when the tab has no splits.
pub fn equalizeSplits(self: *Window, view: anytype) bool {
    const surface = leafIdentity(view) orelse return false;
    const tab = self.findTabIndex(surface) orelse return false;
    if (!self.tab_trees[tab].isSplit()) return false;
    const new_tree = self.tab_trees[tab].equalize(self.app.core_app.alloc) catch return false;
    self.replaceTree(tab, new_tree);
    if (tab == self.active_tab) self.layoutSplits();
    return true;
}

/// Toggle the zoom of the focused split in the tab of `surface`
/// (`toggle_split_zoom`). Returns false when the tab has no splits.
pub fn toggleSplitZoom(self: *Window, view: anytype) bool {
    const surface = leafIdentity(view) orelse return false;
    const tab = self.findTabIndex(surface) orelse return false;
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return false;
    const handle = tree.locate(self.tab_active_surface[tab]) orelse return false;
    tree.zoom(if (tree.zoomed == handle) null else handle);
    self.onTabZoomChanged(tab);
    if (tab == self.active_tab) self.layoutSplits();
    return true;
}

/// Navigate to a tab by GotoTab target (previous, next, last, or a tab
/// number starting from 1). Returns false when the window has a single
/// tab or the target is the active tab (which only gets the focus), like
/// GTK, so that the key reaches the terminal.
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    const goto: tabs.Goto = switch (target) {
        .previous => .previous,
        .next => .next,
        .last => .last,
        _ => .{ .number = std.math.cast(usize, @intFromEnum(target)) orelse return false },
    };
    const idx = tabs.gotoIndex(self.active_tab, self.tab_count, goto) orelse return false;
    if (idx == self.active_tab) {
        self.focusActiveSurface();
        return false;
    }
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the tab of `surface` by a relative offset, wrapping cyclically
/// (`move_tab`). Returns false when it stays where it is (a single tab),
/// so that the key reaches the terminal.
pub fn moveTab(self: *Window, view: anytype, amount: isize) bool {
    const surface = leafIdentity(view) orelse return false;
    const from = self.findTabIndex(surface) orelse return false;
    const to = tabs.moveIndex(from, self.tab_count, amount) orelse return false;
    self.moveTabTo(from, to);
    return true;
}

pub fn moveSplitToTab(self: *Window, view: anytype) !bool {
    const surface = leafIdentity(view) orelse return false;
    if (self.closing or self.is_quick_terminal or self.tab_count >= MAX_TABS) return false;
    const tab = self.findTabIndex(surface) orelse return false;
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return false;
    const handle = tree.locate(surface) orelse return false;
    const next = self.focusAfterMove(tab, handle);
    const reference = try self.app.ui_ids.create(.tab);
    const attachment = try self.app.ui_ids.attach(reference, self.ui_reference);
    const surface_attachment = try surface.prepareReparent(self);
    const detached = try splits.detachPane(Tree, self.app.core_app.alloc, tree, handle);
    surface.onReparented(self, surface_attachment);
    self.finishSplitMove(tab, next, detached.remaining);
    const pos = switch (self.app.config.@"window-new-tab-position") {
        .current => tab + 1,
        .end => self.tab_count,
    };
    self.insertMovedSlot(pos, .{
        .reference = reference,
        .attachment = attachment,
        .tree = detached.moved,
        .active_surface = surface,
        .title = [_]u16{0} ** 256,
        .title_len = 0,
        .title_override = null,
        .unread = false,
        .bell = false,
        .activated = 0,
    });
    self.refreshTabTitle(pos);
    self.updateTabDim(pos);
    self.selectTabIndex(pos);
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    self.updateAppMode();
    return true;
}

pub fn moveSplitToNewWindow(self: *Window, view: anytype) !bool {
    const surface = leafIdentity(view) orelse return false;
    if (self.closing or self.is_quick_terminal) return false;
    const tab = self.findTabIndex(surface) orelse return false;
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return false;
    const handle = tree.locate(surface) orelse return false;
    const next = self.focusAfterMove(tab, handle);
    const reference = try self.app.ui_ids.create(.tab);
    var detached = try splits.detachPane(Tree, self.app.core_app.alloc, tree, handle);
    errdefer detached.remaining.deinit();
    errdefer detached.moved.deinit();
    const destination = try self.createMoveWindow();
    errdefer self.discardMoveWindow(destination);
    const attachment = try self.app.ui_ids.attach(reference, destination.ui_reference);
    const surface_attachment = try surface.prepareReparent(destination);
    const child = surface.nativeHandle() orelse return error.Win32Error;
    const parent = destination.hwnd orelse return error.Win32Error;
    self.cancelDividerDrag();
    if (w32.SetParent(child, parent) == null) return error.Win32Error;
    self.finishSplitMove(tab, next, detached.remaining);
    destination.insertMovedSlot(0, .{
        .reference = reference,
        .attachment = attachment,
        .tree = detached.moved,
        .active_surface = surface,
        .title = [_]u16{0} ** 256,
        .title_len = 0,
        .title_override = null,
        .unread = false,
        .bell = false,
        .activated = 0,
    });
    surface.onReparented(destination, surface_attachment);
    destination.applyScale(0);
    destination.updateTabDim(0);
    destination.refreshTabTitle(0);
    destination.noteTabActivated(0);
    destination.tab_bar.onTabShown(0);
    self.relayout();
    self.repositionPopups();
    self.invalidateTabBar();
    self.updateAppMode();
    destination.updateTabBarVisibility();
    destination.layoutSplits();
    destination.showWhenReady(surface);
    destination.focusActiveSurface();
    destination.updateAppMode();
    return true;
}

fn focusAfterMove(self: *Window, tab: usize, handle: Tree.Node.Handle) *Leaf {
    const tree = &self.tab_trees[tab];
    const surface = tree.nodes[handle.idx()].leaf;
    if (self.tab_active_surface[tab] != surface) return self.tab_active_surface[tab];
    const next = splits.focusAfterClose(Tree, self.app.core_app.alloc, tree, handle).?;
    return tree.nodes[next.idx()].leaf;
}

fn finishSplitMove(self: *Window, tab: usize, next: *Leaf, tree: Tree) void {
    self.tab_bar.cancelRename();
    self.tab_bar.cancelDrag();
    self.cancelDividerDrag();
    self.tab_active_surface[tab] = next;
    self.replaceTree(tab, tree);
    self.refreshTabTitle(tab);
    self.updateTabDim(tab);
}

fn insertMovedSlot(self: *Window, pos: usize, slot: TabSlot) void {
    self.cancelDividerDrag();
    var index = self.tab_count;
    while (index > pos) : (index -= 1) self.copySlot(index, index - 1);
    self.setSlot(pos, slot);
    if (self.tab_count > 0 and self.active_tab >= pos) self.active_tab += 1;
    self.tab_count += 1;
}

/// Consume a prepared restore tree only after identity reservation succeeds.
/// Staged windows stay hidden until the complete session has been constructed.
pub fn adoptSessionTab(self: *Window, tree: *Tree, focused: *Leaf, title: ?tabs.Title) !usize {
    if (self.closing or self.is_quick_terminal or self.tab_count >= MAX_TABS) return error.InvalidOwner;
    if (tree.locate(focused) == null) return error.InvalidSurface;
    const reference = try self.app.ui_ids.create(.tab);
    const attachment = try self.app.ui_ids.attach(reference, self.ui_reference);
    const index = self.tab_count;
    self.insertMovedSlot(index, .{
        .reference = reference,
        .attachment = attachment,
        .tree = tree.*,
        .active_surface = focused,
        .title = @splat(0),
        .title_len = 0,
        .title_override = title,
        .unread = false,
        .bell = false,
        .activated = 0,
    });
    tree.* = .empty;
    self.refreshTabTitle(index);
    self.updateTabDim(index);
    return index;
}

fn fitSessionRect(rect: gx.window_state.Rect, work: gx.window_state.Rect, dpi: u32, show_admin_badge: bool) gx.window_state.Rect {
    const minimum = caption_layout.minTrackSize(@as(f32, @floatFromInt(dpi)) / 96, show_admin_badge);
    var expanded = rect;
    expanded.width = @max(expanded.width, minimum.width);
    expanded.height = @max(expanded.height, minimum.height);
    return gx.window_state.fit(expanded, work);
}

test "session geometry expands before fitting the target work area" {
    const ws = gx.window_state;
    for ([_]u32{ 96, 120, 144, 168, 192, 216 }) |dpi| {
        for ([_]bool{ false, true }) |badge| {
            const work: ws.Rect = .{ .x = -1920, .y = 40, .width = 1920, .height = 1040 };
            const minimum = caption_layout.minTrackSize(@as(f32, @floatFromInt(dpi)) / 96, badge);
            const fitted = fitSessionRect(.{ .x = -100, .y = 1070, .width = 80, .height = 20 }, work, dpi, badge);
            try std.testing.expectEqual(minimum.width, fitted.width);
            try std.testing.expectEqual(minimum.height, fitted.height);
            try std.testing.expectEqual(work.right(), fitted.right());
            try std.testing.expectEqual(work.bottom(), fitted.bottom());
            const large: ws.Rect = .{ .x = -1800, .y = 100, .width = 1500, .height = 800 };
            try std.testing.expectEqual(large, fitSessionRect(large, work, dpi, badge));
        }
    }
}

pub fn revealSession(self: *Window, active: usize, geometry: ?gx.session.Geometry) !void {
    if (self.closing or self.tab_count == 0) return error.InvalidOwner;
    const hwnd = self.hwnd orelse return error.InvalidOwner;
    if (geometry) |saved| if (self.app.config.@"window-save-state" != .never) {
        var current: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &current) == 0) return error.Win32Error;
        const hint: w32.RECT = .{ .left = saved.x orelse current.left, .top = saved.y orelse current.top, .right = (saved.x orelse current.left) +| @as(i32, @intCast(saved.width)), .bottom = (saved.y orelse current.top) +| @as(i32, @intCast(saved.height)) };
        const monitor = MonitorFromRect(&hint, MONITOR_DEFAULTTONEAREST) orelse return error.Win32Error;
        var info: w32.MONITORINFO = .{ .cbSize = @sizeOf(w32.MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (w32.GetMonitorInfoW(monitor, &info) == 0) return error.Win32Error;
        const ws = gx.window_state;
        const target_dpi = monitorDpi(monitor);
        const scaled = ws.rescale(.{ .x = hint.left, .y = hint.top, .width = @intCast(saved.width), .height = @intCast(saved.height) }, saved.dpi, target_dpi);
        const cfg = &self.app.config;
        const placed = fitSessionRect(.{
            .x = if (cfg.@"window-position-x" == null) scaled.x else current.left,
            .y = if (cfg.@"window-position-y" == null) scaled.y else current.top,
            .width = if (cfg.@"window-width" == 0) scaled.width else current.right - current.left,
            .height = if (cfg.@"window-height" == 0) scaled.height else current.bottom - current.top,
        }, .{ .x = info.rcWork.left, .y = info.rcWork.top, .width = info.rcWork.right - info.rcWork.left, .height = info.rcWork.bottom - info.rcWork.top }, target_dpi, self.tab_bar.showsAdminBadge());
        _ = w32.SetWindowPos(hwnd, null, placed.x, placed.y, placed.width, placed.height, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        self.start_maximized = saved.maximized and ws.use(cfg).maximized;
        for (cfg._replay_steps.items) |step| switch (step) {
            .@"-e" => break,
            .arg => |arg| {
                const name = std.mem.trimStart(u8, arg, "-");
                if (std.mem.startsWith(u8, name, "maximize=") or std.mem.startsWith(u8, name, "fullscreen=")) self.start_maximized = false;
            },
            else => {},
        };
    };
    self.active_tab = @min(active, self.tab_count - 1);
    for (0..self.tab_count) |index| if (index != self.active_tab) {
        self.hideTabPanes(index);
    };
    self.noteTabActivated(self.active_tab);
    self.applyScale(self.active_tab);
    self.tab_bar.onTabShown(self.active_tab);
    self.updateTabBarVisibility();
    self.updateWindowTitle();
    self.relayout();
    self.showWhenReady(self.tab_active_surface[self.active_tab]);
    self.focusActiveSurface();
}

fn createMoveWindow(self: *Window) !*Window {
    const alloc = self.app.core_app.alloc;
    const destination = try alloc.create(Window);
    errdefer alloc.destroy(destination);
    try destination.init(self.app, .{});
    errdefer destination.deinit();
    try self.app.windows.append(alloc, destination);
    return destination;
}

fn discardMoveWindow(self: *Window, destination: *Window) void {
    for (self.app.windows.items, 0..) |window, index| {
        if (window == destination) {
            _ = self.app.windows.orderedRemove(index);
            break;
        }
    }
    destination.deinit();
    self.app.core_app.alloc.destroy(destination);
}

/// Move the tab containing `surface`, including all of its splits, into a new
/// native window without restarting any child processes.
pub fn queueTabDetach(self: *Window, tab: gx.ui_ref.Reference, point: w32.POINT) bool {
    if (self.closing or self.is_quick_terminal or self.tab_transfer_active or self.pending_tab_detach != null) return false;
    _ = self.resolveTab(tab) orelse return false;
    const hwnd = self.hwnd orelse return false;
    self.pending_tab_detach = .{ .tab = tab, .point = point };
    if (w32.PostMessageW(hwnd, WM_APP_TAB_DETACH, 0, 0) == 0) {
        self.pending_tab_detach = null;
        return false;
    }
    return true;
}

pub fn moveTabToNewWindow(self: *Window, view: anytype) !bool {
    const surface = leafIdentity(view) orelse return false;
    if (self.closing or self.is_quick_terminal or self.tab_count <= 1) return false;
    const index = self.findTabIndex(surface) orelse return false;
    _ = try self.detachTabForDrag(self.tab_references[index]);
    return true;
}

/// Creates a genuinely empty container, then transfers the existing complete tab.
pub fn detachTabForDrag(self: *Window, reference: gx.ui_ref.Reference) !gx.ui_ref.Reference {
    if (self.closing or self.is_quick_terminal or self.tab_transfer_active) return error.InvalidOwner;
    _ = self.resolveTab(reference) orelse return error.InvalidTab;
    const app = self.app;
    const source_reference = self.ui_reference;
    const destination = try self.createMoveWindow();
    const destination_reference = destination.ui_reference;
    var discard = true;
    errdefer if (discard) {
        if (app.resolveWindow(destination_reference)) |live| live.requestClose();
    };
    const source = app.resolveWindow(source_reference) orelse return error.InvalidOwner;
    if (!(source.moveTabToWindow(reference, destination_reference, 0) catch |err| {
        // Never destroy a parent that still holds a running HWND after a
        // failed OS rollback. Keep both owners for diagnosis/recovery.
        if (err == error.RollbackFailed) discard = false;
        return err;
    })) return error.InvalidOwner;
    return destination_reference;
}

/// Move a complete owned slot, preserving its tree, zoom, active pane and
/// manual title. All allocations/identity reservations precede native changes.
pub fn moveTabToWindow(self: *Window, reference: gx.ui_ref.Reference, destination_reference: gx.ui_ref.Reference, position: usize) !bool {
    const app = self.app;
    const destination = app.resolveWindow(destination_reference) orelse return false;
    if (self == destination or self.closing or self.is_quick_terminal or destination.is_quick_terminal or
        self.tab_transfer_active or destination.tab_transfer_active or destination.tab_count >= MAX_TABS) return false;
    const index = self.resolveTab(reference) orelse return false;
    const source_reference = self.ui_reference;
    const source_hwnd = self.hwnd orelse return false;
    const destination_hwnd = destination.hwnd orelse return false;
    const source_count = self.tab_count;
    const destination_count = destination.tab_count;
    const source_nodes = self.tab_trees[index].nodes.ptr;
    const slot_attachment = try app.ui_ids.attach(reference, destination_reference);
    const View = struct { reference: gx.ui_ref.Reference, child: w32.HWND, attachment: gx.ui_ref.Attachment };
    var views: std.ArrayList(View) = .empty;
    defer views.deinit(app.core_app.alloc);
    // A nested model removal cannot free a terminal while SetParent is active.
    var retained = try self.tab_trees[index].clone(app.core_app.alloc);
    defer retained.deinit();
    var it = retained.iterator();
    while (it.next()) |entry| try views.append(app.core_app.alloc, .{
        .reference = entry.view.reference(),
        .child = entry.view.nativeHandle() orelse return error.InvalidSurface,
        .attachment = try entry.view.prepareReparent(destination),
    });
    self.tab_transfer_active = true;
    destination.tab_transfer_active = true;
    defer endTabTransfer(app, source_reference);
    defer endTabTransfer(app, destination_reference);
    self.tab_bar.cancelRename();
    self.tab_bar.cancelDrag();
    self.cancelDividerDrag();
    destination.tab_bar.cancelRename();
    destination.tab_bar.cancelDrag();
    destination.cancelDividerDrag();
    self.uia_bridge.hide();
    destination.uia_bridge.hide();
    const Backend = struct {
        app: *App,
        source: gx.ui_ref.Reference,
        destination: gx.ui_ref.Reference,
        tab: gx.ui_ref.Reference,
        source_hwnd: w32.HWND,
        destination_hwnd: w32.HWND,
        source_count: usize,
        destination_count: usize,
        source_nodes: [*]const Tree.Node,
        views: []const View,
        pub fn validate(b: *@This()) !void {
            const from = b.app.resolveWindow(b.source) orelse return error.StaleSource;
            const to = b.app.resolveWindow(b.destination) orelse return error.StaleDestination;
            const slot = from.resolveTab(b.tab) orelse return error.StaleSource;
            if (from.tab_transfer_close or to.tab_transfer_close or from.tab_count != b.source_count or
                to.tab_count != b.destination_count or from.tab_trees[slot].nodes.ptr != b.source_nodes)
                return error.StaleSource;
        }
        pub fn move(b: *@This(), i: usize) !void {
            try b.validate();
            const owner = b.app.resolveWindow(b.source) orelse return error.StaleSource;
            const surface = owner.leafForPane(b.views[i].reference) orelse return error.StaleSource;
            if (surface.nativeHandle() != b.views[i].child or w32.GetParent(b.views[i].child) != b.source_hwnd) return error.StaleSource;
            if (w32.SetParent(b.views[i].child, b.destination_hwnd) == null) return error.SetParentFailed;
        }
        pub fn restore(b: *@This(), i: usize) !void {
            if (w32.IsWindow(b.source_hwnd) == 0 or w32.IsWindow(b.views[i].child) == 0) return error.RollbackFailed;
            if (w32.GetParent(b.views[i].child) == b.source_hwnd) return;
            for (0..3) |_| {
                if (w32.SetParent(b.views[i].child, b.source_hwnd) != null or w32.GetParent(b.views[i].child) == b.source_hwnd) return;
            }
            return error.RollbackFailed;
        }
    };
    var backend: Backend = .{ .app = app, .source = source_reference, .destination = destination_reference, .tab = reference, .source_hwnd = source_hwnd, .destination_hwnd = destination_hwnd, .source_count = source_count, .destination_count = destination_count, .source_nodes = source_nodes, .views = views.items };
    try @import("tab_transfer.zig").reparent(Backend, &backend, views.items.len);
    // No message-pumping call between this final validation and slot publication.
    const from = app.resolveWindow(source_reference) orelse return error.StaleSource;
    const to = app.resolveWindow(destination_reference) orelse return error.StaleDestination;
    const current = from.resolveTab(reference) orelse return error.StaleSource;
    var moved = from.getSlot(current);
    moved.attachment = slot_attachment;
    const next = if (from.tab_count > 1) tabs.activeAfterClose(from.active_tab, current, from.tab_count).? else 0;
    var i = current;
    while (i + 1 < from.tab_count) : (i += 1) from.copySlot(i, i + 1);
    from.tab_count -= 1;
    from.active_tab = next;
    const inserted = @min(position, to.tab_count);
    to.insertMovedSlot(inserted, moved);
    to.active_tab = inserted;
    // From here both native and model ownership agree. Reparent callbacks only
    // retire OLE resources; native COM work stays in the outer app loop.
    for (views.items) |view| {
        const live = to.leafForPane(view.reference) orelse continue;
        live.onReparented(to, view.attachment);
    }
    if (app.resolveWindow(source_reference)) |live| {
        if (live.tab_count == 0) {
            live.tab_transfer_close = true;
        } else {
            live.noteTabActivated(live.active_tab);
            live.applyScale(live.active_tab);
            live.tab_bar.onTabShown(live.active_tab);
            live.updateTabBarVisibility();
            live.updateWindowTitle();
            live.relayout();
            live.repositionPopups();
            live.invalidateTabBar();
            live.updateAppMode();
        }
    }
    if (app.resolveWindow(destination_reference)) |live| {
        if (live.is_remote_host) {
            live.relayout();
            var iterator = live.tab_trees[live.active_tab].iterator();
            while (iterator.next()) |entry| {
                entry.view.setVisible(false);
                if (entry.view.nativeHandle()) |child| _ = w32.ShowWindow(child, w32.SW_HIDE);
            }
            app.scheduleSessionSave();
            return true;
        }
        for (0..live.tab_count) |tab| if (tab != live.active_tab) {
            live.hideTabPanes(tab);
        };
        live.noteTabActivated(live.active_tab);
        live.applyScale(live.active_tab);
        live.updateTabDim(live.active_tab);
        live.tab_bar.onTabShown(live.active_tab);
        live.updateTabBarVisibility();
        live.updateWindowTitle();
        live.relayout();
        live.showWhenReady(moved.active_surface);
        live.focusActiveSurface();
        live.updateAppMode();
    }
    app.scheduleSessionSave();
    return true;
}

fn endTabTransfer(app: *App, reference: gx.ui_ref.Reference) void {
    // A nested last-tab close may already mark the window closing. Locate its
    // still-owned record without reviving it for normal UI operations.
    const window = for (app.windows.items) |candidate| {
        if (reference.matches(candidate.ui_reference)) break candidate;
    } else app.remote.resolveHostWindow(reference) orelse return;
    window.tab_transfer_active = false;
    if (window.tab_transfer_close or window.closing) {
        window.tab_transfer_close = false;
        window.requestClose();
    }
}

/// Update the top-level window title to match the active tab's title (or
/// the window title override). Nothing happens when it is the same.
pub fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const title: []const u16 = if (self.window_title_override_len) |len|
        self.window_title_override[0..len]
    else
        self.tab_titles[self.active_tab][0..self.tab_title_lens[self.active_tab]];
    var current: [tabs.max_title_len + 2]u16 = undefined;
    const current_len: usize = @intCast(@max(0, w32.GetWindowTextW(hwnd, &current, current.len)));
    if (std.mem.eql(u16, current[0..current_len], title)) return;
    var buf: [tabs.max_title_len + 1]u16 = undefined;
    @memcpy(buf[0..title.len], title);
    buf[title.len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
    // Without the tabs the title bar shows the window title.
    if (!self.tab_bar.visible) self.title_bar.invalidate();
}

/// Set or clear the explicit top-level window title override.
pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        self.window_title_override_len = @intCast(wstr.bufZ(&self.window_title_override, title).len);
    }
    self.updateWindowTitle();
}

/// Show on tab `tab` the title it should have now (`tabs.displayTitle`:
/// its override, else its focused terminal's title), repainting the tab
/// bar and the window title only when it changed.
fn refreshTabTitle(self: *Window, tab: usize) void {
    if (tab >= self.tab_count) return;
    const terminal: tabs.Title = .fromUtf8(self.tab_active_surface[tab].getTitle() orelse "");
    const override: ?[]const u16 = if (self.tab_title_overrides[tab]) |*title| title.slice() else null;
    const title = tabs.displayTitle(override, terminal.slice());
    if (std.mem.eql(u16, self.tab_titles[tab][0..self.tab_title_lens[tab]], title)) return;
    @memcpy(self.tab_titles[tab][0..title.len], title);
    self.tab_title_lens[tab] = @intCast(title.len);
    if (tab == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}

/// The terminal `surface` has a new title (`set_title`): its tab shows it
/// while `surface` is the focused terminal of the tab and the tab has no
/// title override. A program may have started or exited in it, which herdr
/// app mode looks at (`onAppModeTitle`).
pub fn onSurfaceTitleChanged(self: *Window, view: anytype) void {
    const surface = leafIdentity(view) orelse return;
    const tab = self.findTabIndex(surface) orelse return;
    self.onAppModeTitle();
    if (self.tab_active_surface[tab] != surface) return;
    self.refreshTabTitle(tab);
}

/// Set the title override of tab `tab` (`set_tab_title`, renaming the
/// tab); an empty title clears it, so the tab shows its terminal's title
/// again.
pub fn setTabTitleOverride(self: *Window, tab: usize, title: tabs.Title) void {
    if (self.hwnd != null and !self.is_quick_terminal) self.app.scheduleSessionSave();
    if (tab >= self.tab_count) return;
    self.tab_title_overrides[tab] = if (title.len == 0) null else title;
    self.refreshTabTitle(tab);
}

/// Update tab bar visibility based on config and tab count. The chrome row
/// can change height with it; the terminals follow without a size overlay
/// (the user did not resize the window).
fn updateTabBarVisibility(self: *Window) void {
    if (!self.tab_bar.updateVisibility()) return;
    self.applyFrameMargins();
    self.layoutSplits();
    self.overlay_grid = self.activeGrid();
    self.shortcut_notice.reposition();
    self.repositionOverlays();
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
/// own; a second tab or herdr exiting restores the tab bar at once, while
/// entering takes two checks in a row that find herdr (`gx.app_mode.State`).
/// This checks now (tabs, splits or the configuration changed). Besides,
/// a window with a single tab that is seen checks again shortly after a
/// terminal title changes and on the tab bar's tick, less often while
/// nothing changes (`gx.app_mode.nextDelay`). The checks read the process
/// table the app shares (`App.processTable`).
pub fn updateAppMode(self: *Window) void {
    self.checkAppMode(true);
}

/// Whether the window checks for herdr app mode: the feature is on and the
/// window has a single tab.
fn appModeWatched(self: *const Window) bool {
    return self.app.config.@"gx-herdr-app-mode" and !self.is_quick_terminal and
        !self.closing and self.tab_count == 1;
}

/// Check for herdr app mode and plan the next periodic check, sooner when
/// something that can start or stop herdr happened (`reset`).
fn checkAppMode(self: *Window, reset: bool) void {
    const enabled = self.app.config.@"gx-herdr-app-mode" and !self.is_quick_terminal;
    const watched = self.appModeWatched();
    if (watched and !self.pollingVisible()) {
        self.app_mode_due_ms = 0;
        return self.stopAppModeSoon();
    }
    var answers: [app_mode_max_terminals]?bool = undefined;
    const count = if (watched) self.appModeAnswers(&answers) else 0;

    const was = self.app_mode;
    const app_mode = self.app_mode_samples.update(&self.app_mode_state, enabled, self.tab_count, answers[0..count], self.app.proc_shared.captures);
    if (app_mode != was) log.info("herdr app mode {s}", .{if (app_mode) "on" else "off"});
    self.app_mode = app_mode;
    self.setTabBarSuppressed(app_mode);

    if (!watched) return self.stopAppModeSoon();
    self.app_mode_delay_ms = gx.app_mode.nextDelay(
        self.app_mode_delay_ms,
        reset or app_mode != was or self.app_mode_state.pending(),
    );
    self.app_mode_due_ms = GetTickCount64() + self.app_mode_delay_ms;
    // The tab bar ticks once a second; sooner checks need their own timer.
    if (self.app_mode_delay_ms < chrome_timer_ms) self.checkAppModeIn(self.app_mode_delay_ms);
}

/// Whether each terminal of the only tab runs herdr, in `answers`, from the
/// app's shared process table (`gx.app_mode.treeRunsHerdr`): null where it
/// is unknown (a terminal that is not ready, no process table). Returns how
/// many answers there are; they stop at the first terminal running herdr,
/// as one is enough.
fn appModeAnswers(self: *Window, answers: *[app_mode_max_terminals]?bool) usize {
    var pids: [app_mode_max_terminals]?u64 = undefined;
    var roots: [app_mode_max_terminals]gx.proc.Pid = undefined;
    var count: usize = 0;
    var root_count: usize = 0;
    var it = self.tab_trees[0].iterator();
    while (it.next()) |entry| {
        if (count == answers.len) break;
        const surface = entry.view;
        pids[count] = if (surface.pane().foregroundPid()) |pid| @as(u64, pid) else null;
        if (pids[count]) |pid| if (std.math.cast(gx.proc.Pid, pid)) |root| {
            roots[root_count] = root;
            root_count += 1;
        };
        answers[count] = null;
        count += 1;
    }

    if (root_count == 0) return count;
    const table = self.app.processTable() catch |err| {
        log.warn("cannot list the processes for herdr app mode err={}", .{err});
        return count;
    };
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const tree = table.tree(arena.allocator(), roots[0..root_count]) catch return count;
    for (pids[0..count], 0..) |pid, i| {
        if (pid == null) continue;
        answers[i] = gx.app_mode.treeRunsHerdr(arena.allocator(), tree, pid, .native) catch null;
        if (answers[i] orelse false) return i + 1;
    }
    return count;
}

/// The periodic app mode check shares the chrome tick.
fn onAppModeTick(self: *Window) void {
    if (!self.appModeWatched() or !self.pollingVisible() or self.app_mode_soon) return;
    if (GetTickCount64() < self.app_mode_due_ms) return;
    self.checkAppMode(false);
}

fn checkAppModeIn(self: *Window, delay_ms: u32) void {
    if (!self.appModeWatched() or !self.pollingVisible() or self.app_mode_soon) return;
    const hwnd = self.hwnd orelse return;
    if (w32.SetTimer(hwnd, app_mode_soon_timer_id, delay_ms, null) != 0) self.app_mode_soon = true;
}

fn onAppModeSoon(self: *Window) void {
    self.stopAppModeSoon();
    if (self.pollingVisible()) self.checkAppMode(false);
}

fn onAppModeTitle(self: *Window) void {
    if (!self.appModeWatched()) return;
    self.app_mode_delay_ms = 0;
    self.checkAppModeIn(app_mode_title_delay_ms);
}

fn stopAppModeSoon(self: *Window) void {
    if (!self.app_mode_soon) return;
    self.app_mode_soon = false;
    if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, app_mode_soon_timer_id);
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    self.uia_dirty = true;
    self.uia_bridge.dirty();
    self.tab_bar.invalidate();
}

/// Set (or clear, when empty) the explicit window title override (UTF-16,
/// cut to `tabs.max_title_len` code units at a codepoint boundary).
pub fn setWindowTitleOverride(self: *Window, title: []const u16) void {
    if (self.hwnd != null and !self.is_quick_terminal) self.app.scheduleSessionSave();
    const units = wstr.truncate(title, tabs.max_title_len);
    if (units.len == 0) {
        self.window_title_override_len = null;
    } else {
        @memcpy(self.window_title_override[0..units.len], units);
        self.window_title_override_len = @intCast(units.len);
    }
    self.updateWindowTitle();
}

pub fn toggleMaximize(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.title_bar.is_fullscreen) {
        self.toggleFullscreen();
        _ = w32.ShowWindow(hwnd, SW_SHOWMAXIMIZED);
    } else {
        _ = w32.ShowWindow(hwnd, if (w32.IsZoomed(hwnd) != 0) w32.SW_RESTORE else SW_SHOWMAXIMIZED);
    }
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
/// chrome and show the resize overlay (`showResizeOverlay`). Entering or
/// leaving fullscreen can show or hide the tab bar: that is settled first,
/// so the panes are laid out once.
fn handleResize(self: *Window) void {
    if (self.tab_bar.updateVisibility()) self.applyFrameMargins();
    self.layoutSplits();
    self.invalidateTabBar();
    if (!self.is_quick_terminal) self.showResizeOverlay();
    self.shortcut_notice.reposition();
    self.repositionOverlays();
}

/// Move a tab from one index to another, shifting intermediate tabs.
pub fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.tab_bar.cancelRename();
    self.cancelDividerDrag();

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

    self.active_tab = tabs.movedIndex(self.active_tab, from, to);
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
    if (self.closing) return true;
    const hwnd = self.hwnd orelse return true;
    var check: CloseCheck = .init(self.app.core_app.alloc);
    defer check.deinit();
    var scope: @import("../../gx/confirm.zig").Scope = undefined;
    scope.begin(self.app.core_app.alloc, @import("../../global.zig").io());
    defer scope.end();
    for (0..self.tab_count) |i| check.tab(self, i) catch |err| {
        log.err("cannot prepare the window close confirmation err={}", .{err});
        return false;
    };
    scope.end();
    check.done();
    if (!check.needed) return true;

    return Dialogs.confirmCloseWindowByTab(hwnd, check.groups.items) == .accept and isAlive(hwnd, self);
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
    if (self.tab_transfer_active) {
        self.tab_transfer_close = true;
        return;
    }
    if (self.is_remote_host) {
        _ = self.app.remote.closeHost(self.ui_reference);
        return;
    }
    if (!self.app.quit_requested and self.requestRemoteSelectionClose(self.tab_references[0..self.tab_count])) return;
    if (self.app.remote.deferLocalWindowClose(self.ui_reference)) return;
    if (self.hasForeignTerminalWindows()) {
        log.err("cannot close a transfer parent while another window owns its terminals", .{});
        return;
    }
    if (self.pending_native_destroy) return;
    if (self.app.running) self.app.session.onWindowClose(self.app, self);
    // The last window remembers its place for the next one.
    const windows = self.app.windows.items;
    if (windows.len == 1 and windows[0] == self) self.saveWindowState();
    // Off the screen at once: the terminals take a moment to stop.
    self.hide();
    // First, cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        if (self.app.deferDropParentDestroy(hwnd)) {
            self.pending_native_destroy = true;
            return;
        }
        _ = w32.DestroyWindow(hwnd);
    }
}

/// A failed native rollback must never let an empty staging container destroy
/// another model owner's live terminal HWNDs. Query only current GUI records.
fn hasForeignTerminalWindows(self: *const Window) bool {
    const hwnd = self.hwnd orelse return false;
    for (self.app.core_app.surfaces.items) |surface| {
        if (surface.parent_window == self) continue;
        const child = surface.hwnd orelse continue;
        if (w32.GetParent(child) == hwnd) return true;
    }
    return false;
}

/// Hide the window for good, before its terminals stop: input no longer
/// reaches it (`closing`) and its renderers are not told about the hide.
fn hide(self: *Window) void {
    self.uia_bridge.hide();
    self.resize_overlay.hide();
    const hwnd = self.hwnd orelse return;
    self.closing = true;
    self.visibility.deinit(hwnd);
    self.stopAppModeSoon();
    _ = w32.KillTimer(hwnd, CHROME_TIMER_ID);
    _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    self.palette.deinit();
    self.cancelDividerDrag();
    // Empty the tab model before any terminal goes away: freeing one can
    // dispatch messages that walk the tabs, which then find none instead
    // of trees being freed (SplitTree.deinit leaves its tree undefined).
    const count = self.tab_count;
    self.tab_count = 0;
    var trees: [MAX_TABS]Tree = undefined;
    for (self.tab_trees[0..count], trees[0..count]) |*slot, *tree| {
        tree.* = slot.*;
        slot.* = .empty;
    }
    freeTrees(self.app, trees[0..count]);
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    self.uia_bridge.deinit();
    const app = self.app;
    self.visibility.deinit(self.hwnd);
    Settings.onWindowDestroyed(self);

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        self.tab_bar.deinit();
        self.title_bar.deinit();
        self.resize_overlay.deinit();
        self.shortcut_notice.deinit();
        self.notice.deinit();
        self.toast.deinit();
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
    self.notice.deinit();
    self.toast.deinit();
    self.hwnd = null;

    // Background hosts belong to RemoteCoordinator, never the ordinary list.
    // Unexpected native destruction invalidates the record; its owner still
    // joins terminal threads and releases the Host allocation at a safe point.
    if (self.is_remote_host) {
        self.closing = true;
        return;
    }

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
pub fn onBell(self: *Window, view: anytype) void {
    const surface = leafIdentity(view) orelse return;
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
    const app = self.app;
    const owner = self.ui_reference;
    const command = Menu.showTabContextMenu(self, screen, null) orelse return;
    const live = app.resolveWindow(owner) orelse return;
    Menu.performTabCommand(live, null, command);
}

/// A system broadcast reached this window (only top-level windows hear
/// them; every window hears each one): read the system colors and high
/// contrast state of the design tokens again (`style.system`), then tell
/// the app, the backdrop and the title bar, and repaint the split dividers
/// after a change of the system colors (high contrast). The terminal
/// windows draw nothing of the system colors; the popups are top-level
/// windows and hear the broadcasts themselves. GUI thread. `.theme` also
/// comes from `SetWindowTheme` on this window: `Backdrop.apply` sends one
/// from `init`, before the window has tabs.
fn onSystemSettingChange(self: *Window, change: w32.SystemChange) void {
    const hwnd = self.hwnd orelse return;
    switch (change) {
        .setting, .sys_colors, .theme => style.system.refresh(),
        .colorization => {},
    }
    self.app.onSystemSettingChange(self, change);
    Backdrop.onSystemSettingChange(hwnd, &self.app.config, self.app.alpha_frames, change);
    self.title_bar.onSystemSettingChange(change);
    self.repaintSplitGaps();
    const message: u32, const wp: usize, const lp: isize = switch (change) {
        .setting => |setting| .{ w32.WM_SETTINGCHANGE, setting.action, if (setting.area) |area| @bitCast(@intFromPtr(area)) else 0 },
        .sys_colors => .{ w32.WM_SYSCOLORCHANGE, 0, 0 },
        .theme => .{ w32.WM_THEMECHANGED, 0, 0 },
        .colorization => |color| .{ w32.WM_DWMCOLORIZATIONCOLORCHANGED, color.color, @intFromBool(color.opaque_blend) },
    };
    for (0..self.tab_count) |tab| {
        var it = self.tab_trees[tab].iterator();
        while (it.next()) |entry| {
            entry.view.refreshScrollbarMode();
            if (entry.view.nativeHandle()) |child| _ = w32.SendMessageW(child, message, wp, lp);
        }
    }
}

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

    if (window.app.drop_closing) return 0;

    if (window.app.isTaskbarButtonCreated(msg)) {
        window.app.onTaskbarButtonCreated(window);
        return 0;
    }

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

    // System broadcasts go on to the default handling afterwards.
    if (w32.SystemChange.fromMessage(msg, wparam, lparam)) |change| window.onSystemSettingChange(change);

    if (msg == TitleBar.WM_SYSCOMMAND and wparam & 0xFFF0 == 0xF030 and window.title_bar.is_fullscreen) {
        window.toggleFullscreen();
    }
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
            if (w32.objectId(lparam) == w32.OBJID_CLIENT) return 0;
            if (w32.objectId(lparam) == -25) return window.app.uiaForWindow(window, wparam, lparam);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (window.resize_overlay.onTimer(wparam)) return 0;
            if (window.shortcut_notice.onTimer(wparam)) return 0;
            if (window.title_bar.onTimer(wparam)) return 0;
            switch (wparam) {
                FIRST_FRAME_TIMER_ID => window.checkFirstFrame(),
                CHROME_TIMER_ID => {
                    if (!window.pollingVisible()) return 0;
                    window.tab_bar.onTimer();
                    window.onAppModeTick();
                },
                app_mode_soon_timer_id => window.onAppModeSoon(),
                else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
            }
            return 0;
        },

        WM_APP_MAIN_MENU => {
            if (window.closing) return 0;
            if (window.main_menu_anchor) |anchor| {
                Menu.showMainMenu(window, anchor);
            } else {
                Menu.showMainMenu(window, null);
            }
            return 0;
        },

        WM_APP_CLOSE_TAB => {
            if (!window.closing) window.onCloseTabRequest(wparam, lparam);
            return 0;
        },

        WM_APP_FIRST_FRAME => {
            window.onFirstFrame(@bitCast(lparam));
            return 0;
        },

        Popup.WM_GX_OWNER_ACTIVE_LOCK => {
            window.title_bar.onOwnerActiveLock(wparam != 0);
            return 0;
        },

        @import("remote_test.zig").begin_message => {
            if (!@import("remote_test.zig").enabled() or window.tab_count == 0 or wparam > std.math.maxInt(u32)) return 0;
            const target: @import("ipc/Security.zig").policy.Process = .{ .pid = @intCast(wparam), .birth = @as(usize, @bitCast(lparam)) };
            if (window.app.remote.returnRemoteTab(window.app, window.tab_references[window.active_tab], target) catch return 0) return 1;
            window.app.remote.begin(window.app, window.ui_reference, window.tab_references[window.active_tab], target) catch return 0;
            return 1;
        },
        @import("remote_test.zig").query_message => {
            const fixture = @import("remote_test.zig");
            if (!fixture.enabled()) return 0;
            if (wparam >= 12 and wparam <= 16) {
                if (wparam == 12) return @intCast(window.tab_count);
                const leaf = window.activeLeaf() orelse return 0;
                if (wparam == 16) return if (leaf.remote()) |remote| if (remote.hwnd) |native| @bitCast(@intFromPtr(native)) else 0 else 0;
                var count: usize = 0;
                var iterator = window.tab_trees[window.active_tab].iterator();
                while (iterator.next()) |entry| {
                    if (wparam == 13 or (wparam == 14 and entry.view.local() != null) or (wparam == 15 and entry.view.remote() != null)) count += 1;
                }
                return @intCast(count);
            }
            if (window.activeLeaf()) |leaf| if (leaf.remote()) |remote| return if (wparam == 3) 0 else remote.query(wparam);
            const surface = window.getActiveSurface();
            return switch (wparam) {
                0 => fixture.magic,
                1 => if (window.shown and !window.closing) @intCast(fixture.Flags.visible) else 0,
                2 => if (surface) |value| @bitCast(@as(usize, @intCast(value.ui_reference.id))) else 0,
                3 => if (surface) |value| if (value.core_surface_ready) @intCast(value.core_surface.getProcessInfo(.foreground_pid) orelse 0) else 0 else 0,
                7 => if (surface) |value| if (value.hwnd) |child| @bitCast(@intFromPtr(child)) else 0 else 0,
                else => 0,
            };
        },
        WM_GHOSTTY_SIMULATE_SYSTEM_THEME => return @intFromBool(window.app.simulateSystemTheme(wparam)),
        WM_GHOSTTY_WINDOW_STATE => {
            return switch (wparam) {
                0 => @as(isize, @as(u8, @bitCast(window.occlusion))) |
                    (@as(isize, @intFromBool(window.visibility.unregister_session != null)) << 8) |
                    (@as(isize, @intFromBool(window.visibility.power != null)) << 9) |
                    (@as(isize, @intFromBool(window.visibility.cloak_hook != null)) << 10) |
                    (@as(isize, @intFromBool(window.title_bar.is_fullscreen)) << 16),
                1 => @intCast(window.tab_count),
                2 => @intFromFloat(window.scale * 96),
                3 => if (window.activeLeaf()) |leaf| @intFromFloat(leaf.scale() * 96) else 0,
                4 => if (window.getActiveSurface()) |surface| @intFromBool(surface.last_reported_visible orelse false) else 0,
                5 => @intFromBool(window.app_mode_soon),
                6 => if (window.activeLeaf()) |leaf| @intFromBool(window.moveSplitToTab(leaf) catch false) else 0,
                7 => if (window.activeLeaf()) |leaf| @intFromBool(window.moveSplitToNewWindow(leaf) catch false) else 0,
                8 => @intCast(@min(window.layout_passes, std.math.maxInt(isize))),
                9 => blk: {
                    window.toggleMaximize();
                    break :blk 1;
                },
                10 => @intCast(window.active_tab),
                11 => @intFromBool(window.app_mode),
                12 => window.app_mode_state.hits,
                else => 0,
            };
        },
        WM_GHOSTTY_SIMULATE_OCCLUSION => {
            window.setOcclusion("locked", wparam & 1 != 0);
            window.setOcclusion("display_off", wparam & 2 != 0);
            window.setOcclusion("desktop", wparam & 4 != 0);
            return 1;
        },
        VisibilitySubscriptions.WM_WTSSESSION_CHANGE => {
            switch (wparam) {
                VisibilitySubscriptions.WTS_SESSION_LOCK => window.setOcclusion("locked", true),
                VisibilitySubscriptions.WTS_SESSION_UNLOCK => window.setOcclusion("locked", false),
                else => {},
            }
            return 0;
        },

        w32.WM_MOUSEWHEEL, w32.WM_MOUSEHWHEEL => {
            // The pointer is in screen coordinates.
            var pt = mousePoint(lparam);
            _ = w32.ScreenToClient(hwnd, &pt);
            if (window.inChrome(pt.y)) {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                const horizontal = msg == w32.WM_MOUSEHWHEEL;
                if (window.tab_bar.onMouseWheel(window.title_bar.layout(), pt.x, pt.y, delta, horizontal)) return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SIZE => {
            // Minimizing does not hide child surface HWNDs, so tell the core
            // to stop rendering the active tab while minimized. Return early:
            // the client rect is 0x0 while minimized, so re-laying-out would
            // both re-mark the surfaces visible (undoing the occlusion) and
            // collapse the grid, and the resize overlay would flash offscreen.
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setOcclusion("minimized", true);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setOcclusion("minimized", false);
            }
            window.title_bar.onSize();
            window.handleResize();
            return 0;
        },
        w32.WM_SHOWWINDOW => {
            if (!window.closing) window.setOcclusion("hidden", wparam == 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_WINDOWPOSCHANGED => {
            // Hidden (`toggle_visibility`, the quick terminal), the
            // terminals draw nothing. ShowWindow and SetWindowPos both
            // say so here; a minimized window stays shown.
            const pos: *const WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (!window.closing) {
                if (pos.flags & SWP_HIDEWINDOW != 0) {
                    window.setOcclusion("hidden", true);
                } else if (pos.flags & w32.SWP_SHOWWINDOW != 0) {
                    window.setOcclusion("hidden", false);
                }
            }
            // DefWindowProc sends WM_SIZE and WM_MOVE.
            const result = w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            window.trackPlacement();
            return result;
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
                VisibilitySubscriptions.refreshShell(window);
                window.refreshRenderers();
                return 1;
            }
            if (wparam == VisibilitySubscriptions.PBT_POWERSETTINGCHANGE and lparam != 0) {
                const setting: *const VisibilitySubscriptions.PowerSetting = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (VisibilitySubscriptions.displayOff(setting)) |off| window.setOcclusion("display_off", off);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_DISPLAYCHANGE => {
            log.info("display changed, redrawing the terminals", .{});
            if (window.quickTerminal()) |qt| qt.relayout();
            window.fitFullscreen();
            VisibilitySubscriptions.refreshShell(window);
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
            // Apply the size limits (the chrome's own minimum and the
            // user-configured ones) if any. lparam points to a MINMAXINFO
            // the OS will consult for resize clamping.
            const chrome = caption_layout.minTrackSize(window.scale, window.tab_bar.showsAdminBadge());
            const min_w = @max(window.min_track_w, chrome.width);
            const min_h = @max(window.min_track_h, chrome.height);
            if (min_w > 0 or min_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (min_w > 0) mmi.ptMinTrackSize.x = min_w;
                if (min_h > 0) mmi.ptMinTrackSize.y = min_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            window.setPanesLiveResize(window.active_tab, true);
            return 0;
        },
        WM_APP_TAB_DETACH => {
            const request = window.pending_tab_detach orelse return 0;
            window.pending_tab_detach = null;
            const app = window.app;
            const reference = window.ui_reference;
            @import("TabTransfer.zig").run(app, reference, request.tab, request.point) catch |err| {
                log.warn("tab drag transfer failed err={}", .{err});
            };
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            window.setPanesLiveResize(window.active_tab, false);
            return 0;
        },
        w32.WM_CLOSE => {
            if (window.tab_transfer_active) {
                window.tab_transfer_close = true;
                return 0;
            }
            // Title-bar X / Alt+F4 / close_window land here. Confirm once
            // for the whole window if any tab has a running process. While
            // a dialog's modal loop runs, the close waits for the dialog.
            if (Dialogs.deferClose(hwnd)) return 0;
            if (!window.confirmCloseIfNeeded()) return 0;
            if (window.quickTerminal()) |qt| {
                if (window.closing and qt.animating) return 0;
                if (!window.closing) {
                    window.closing = true;
                    window.stopAppModeSoon();
                    if (qt.onLastTabClosed()) return 0;
                }
            }
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
            window.focusActiveSurface();
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
                const along = if (hit.layout == .horizontal) pt.x else pt.y;
                window.startDividerDrag(hit, along - hit.pos);
                return 0;
            }
            _ = window.title_bar.onLeftButtonDown(pt.x, pt.y);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.cancelDividerDrag();
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
            // Double-click on a divider: the panes on both sides get the
            // same share.
            if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                const tree = &window.tab_trees[window.active_tab];
                tree.resizeInPlace(hit.handle, split_layout.balancedRatio(Tree, tree, hit.handle));
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
        w32.WM_MBUTTONDOWN => {
            const pt = mousePoint(lparam);
            if (window.inChrome(pt.y)) {
                _ = window.tab_bar.onMiddleButtonDown(window.title_bar.layout(), pt.x, pt.y);
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
                // The button went up where the window did not see it.
                if (wparam & w32.MK_LBUTTON == 0) {
                    window.cancelDividerDrag();
                } else {
                    window.updateDividerDrag(pt.x, pt.y);
                    return 0;
                }
            }
            window.updateDividerHover(pt.x, pt.y);
            // Tab drag reorder and chrome hover.
            _ = window.title_bar.onMouseMove(pt.x, pt.y);
            return 0;
        },
        w32.WM_CAPTURECHANGED => {
            window.tab_bar.onCaptureLost();
            window.cancelDividerDrag();
            return 0;
        },

        0x001F => { // WM_CANCELMODE
            @import("TabTransfer.zig").cancelNativeMove();
            window.tab_bar.cancelDrag();
            window.cancelDividerDrag();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
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
            window.divider_tracking = false;
            if (!window.dragging_split) window.setDividerHover(null);
            window.title_bar.onMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    // lparam is the window being activated instead, if any.
                    qt.onFocusLost(@ptrFromInt(@as(usize, @bitCast(lparam))));
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ACTIVATEAPP => {
            if (wparam == 0 and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| qt.onAppDeactivated();
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "runtime references follow tab slots across reorder and window ownership" {
    const testing = std.testing;
    var issuer = try gx.ui_ref.Issuer.init(123);
    var source: Window = .{ .app = undefined, .ui_reference = try issuer.create(.window), .tab_count = 2 };
    var destination: Window = .{ .app = undefined, .ui_reference = try issuer.create(.window) };
    var first: Surface = .{ .app = undefined };
    var second: Surface = .{ .app = undefined };
    var first_leaf: Leaf = .{ .backend = .{ .local = &first } };
    var second_leaf: Leaf = .{ .backend = .{ .local = &second } };
    first.leaf = &first_leaf;
    second.leaf = &second_leaf;
    source.tab_references[0] = try issuer.create(.tab);
    source.tab_references[1] = try issuer.create(.tab);
    source.tab_trees[0] = .empty;
    source.tab_trees[1] = .empty;
    source.tab_active_surface[0] = first.leaf.?;
    source.tab_active_surface[1] = second.leaf.?;
    source.tab_titles[0] = [_]u16{0} ** 256;
    source.tab_titles[1] = [_]u16{0} ** 256;
    source.tab_title_lens[0] = 0;
    source.tab_title_lens[1] = 0;
    const first_ref = source.tab_references[0];
    const second_ref = source.tab_references[1];
    const saved = source.getSlot(0);
    source.copySlot(0, 1);
    source.setSlot(1, saved);
    try testing.expectEqual(@as(?usize, 1), source.resolveTab(first_ref));
    try testing.expectEqual(@as(?usize, 0), source.resolveTab(second_ref));
    destination.setSlot(0, source.getSlot(1));
    destination.tab_count = 1;
    source.tab_count = 1;
    try testing.expect(source.resolveTab(first_ref) == null);
    try testing.expectEqual(@as(?usize, 0), destination.resolveTab(first_ref));
    try testing.expect(destination.tab_active_surface[0] == first.leaf.?);
    destination.closing = true;
    try testing.expect(destination.resolveTab(first_ref) == null);
    destination.closing = false;
    destination.tab_references[0] = try issuer.create(.tab);
    try testing.expect(destination.resolveTab(first_ref) == null);
    try testing.expect(destination.resolveTab(destination.ui_reference) == null);
}

test "runtime reference exhaustion precedes native window and tab creation" {
    const testing = std.testing;
    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = undefined, .default_command_arena = undefined, .ui_ids = try gx.ui_ref.Issuer.init(123) };
    app.ui_ids.serial = std.math.maxInt(u64);
    var window: Window = undefined;
    try testing.expectError(error.Exhausted, window.init(&app, .{}));
    try testing.expect(window.hwnd == null);
    try testing.expect(!window.ui_reference.isValid());
    try testing.expectError(error.Exhausted, window.addTabWithOptions(.{ .context = .tab }));
    try testing.expectEqual(@as(usize, 0), window.tab_count);
}

test "quick terminal rejects an additional tab before creating a surface" {
    var window: Window = .{ .app = undefined, .is_quick_terminal = true, .tab_count = 1 };
    try std.testing.expectError(error.QuickTerminalTabUnsupported, window.addTabWithOptions(.{ .context = .tab }));
    window.closing = true;
    try std.testing.expectError(error.WindowClosing, window.addTabWithOptions(.{ .context = .tab }));
}

test "quick last tab remains in the model until deferred window close" {
    const testing = std.testing;
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    config.@"quick-terminal-animation-duration" = 0;
    var core_app: @import("../../App.zig") = undefined;
    core_app.alloc = testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    app.config = config;
    var window: Window = .{ .app = &app, .is_quick_terminal = true, .tab_count = 1 };
    window.tab_trees[0] = .empty;
    var surface: Surface = .{ .app = &app, .parent_window = &window, .core_surface_initialized = true };
    surface.core_surface.id = 1;
    var leaf: Leaf = .{ .backend = .{ .local = &surface } };
    surface.leaf = &leaf;
    window.tab_references[0] = .{ .epoch = 1, .kind = .tab, .id = 1, .generation = 1 };
    window.tab_active_surface[0] = &leaf;
    var quick: @import("QuickTerminal.zig") = .{ .app = &app, .window = &window, .phase = .shown, .visible = true };
    app.quick_terminal = &quick;
    try testing.expect(!window.closeQuickSelection(&.{.{ .epoch = 1, .kind = .tab, .id = 2, .generation = 1 }}));
    try testing.expect(!window.closing);
    try testing.expect(window.closeQuickSelection(&.{window.tab_references[0]}));
    try testing.expectEqual(@as(usize, 1), window.tab_count);
    try testing.expect(window.closing);
    try testing.expect(quick.close_when_hidden);
    window.removeTab(0);
    try testing.expectEqual(@as(usize, 1), window.tab_count);
    try testing.expect(window.confirmCloseIfNeeded());
}

test "close confirmation groups own titles and process names" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var title = [_]u16{ 'B', 'u', 's', 'y' };
    var process = [_]u8{ 'p', 'i', 'n', 'g' };
    var names = [_][]const u8{&process};
    const group = try ownedCloseGroup(arena.allocator(), &title, &names);
    title[0] = 'X';
    process[0] = 'X';
    names[0] = "replaced";
    try testing.expectEqualStrings("Busy", group.title);
    try testing.expectEqualStrings("ping", group.processes[0]);
}

test "feedback waits for a settled Quick owner and discards a closing owner" {
    const testing = std.testing;
    var app: App = undefined;
    app.quick_terminal = null;
    var window: Window = .{ .app = &app };
    try testing.expectEqual(Notice.Disposition.ready, window.feedbackDisposition());
    window.is_quick_terminal = true;
    try testing.expectEqual(Notice.Disposition.deferred, window.feedbackDisposition());
    var quick: @import("QuickTerminal.zig") = .{ .app = &app, .window = &window };
    app.quick_terminal = &quick;
    for ([_]bool{ false, true }) |visible| {
        for ([_]bool{ false, true }) |animating| {
            quick.visible = visible;
            quick.animating = animating;
            const expected: Notice.Disposition = if (visible and !animating) .ready else .deferred;
            try testing.expectEqual(expected, window.feedbackDisposition());
            window.closing = true;
            try testing.expectEqual(Notice.Disposition.discard, window.feedbackDisposition());
            window.closing = false;
        }
    }
}

const VisibilitySubscriptions = struct {
    wts_module: ?w32.HINSTANCE = null,
    unregister_session: ?*const fn (w32.HWND) callconv(.winapi) i32 = null,
    power: ?*anyopaque = null,
    unregister_power: ?*const fn (*anyopaque) callconv(.winapi) i32 = null,
    cloak_hook: ?*anyopaque = null,
    unhook: ?*const fn (*anyopaque) callconv(.winapi) i32 = null,

    const WM_WTSSESSION_CHANGE: u32 = 0x02B1;
    const WTS_SESSION_LOCK: usize = 7;
    const WTS_SESSION_UNLOCK: usize = 8;
    const PBT_POWERSETTINGCHANGE: usize = 0x8013;
    const EVENT_OBJECT_CLOAKED: u32 = 0x8017;
    const EVENT_OBJECT_UNCLOAKED: u32 = 0x8018;
    const DWMWA_CLOAKED: u32 = 14;
    const DWM_CLOAKED_SHELL: u32 = 2;
    const display_state: w32.GUID = .{
        .Data1 = 0x6FE69556,
        .Data2 = 0x704A,
        .Data3 = 0x47A0,
        .Data4 = .{ 0x8F, 0x24, 0xC2, 0x8D, 0x93, 0x6F, 0xDA, 0x47 },
    };
    const PowerSetting = extern struct { guid: w32.GUID, length: u32, state: u32 };
    const WinEventProc = *const fn (?*anyopaque, u32, ?w32.HWND, i32, i32, u32, u32) callconv(.winapi) void;

    fn init(self: *VisibilitySubscriptions, hwnd: w32.HWND) void {
        const RegisterSession = *const fn (w32.HWND, u32) callconv(.winapi) i32;
        if (LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("wtsapi32.dll"), null, 0x800)) |module| {
            self.wts_module = module;
            const register = proc(RegisterSession, module, "WTSRegisterSessionNotification");
            const unregister = proc(@TypeOf(self.unregister_session.?), module, "WTSUnRegisterSessionNotification");
            if (register != null and unregister != null and register.?(hwnd, 0) != 0) {
                self.unregister_session = unregister;
            }
        }
        const user = w32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return;
        const RegisterPower = *const fn (w32.HWND, *const w32.GUID, u32) callconv(.winapi) ?*anyopaque;
        if (proc(RegisterPower, user, "RegisterPowerSettingNotification")) |register| {
            if (proc(@TypeOf(self.unregister_power.?), user, "UnregisterPowerSettingNotification")) |unregister| {
                self.unregister_power = unregister;
                self.power = register(hwnd, &display_state, 0);
            }
        }
        const SetHook = *const fn (u32, u32, ?w32.HINSTANCE, WinEventProc, u32, u32, u32) callconv(.winapi) ?*anyopaque;
        if (proc(SetHook, user, "SetWinEventHook")) |set_hook| {
            if (proc(@TypeOf(self.unhook.?), user, "UnhookWinEvent")) |unhook| {
                self.unhook = unhook;
                self.cloak_hook = set_hook(EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED, null, onCloakEvent, GetCurrentProcessId(), 0, 0);
            }
        }
        log.debug("visibility subscriptions session={} power={} cloak={}", .{
            self.unregister_session != null, self.power != null, self.cloak_hook != null,
        });
    }

    fn deinit(self: *VisibilitySubscriptions, hwnd: ?w32.HWND) void {
        if (self.cloak_hook) |hook| {
            if (self.unhook) |unhook| _ = unhook(hook);
        }
        if (self.power) |power| {
            if (self.unregister_power) |unregister| _ = unregister(power);
        }
        if (hwnd) |h| {
            if (self.unregister_session) |unregister| _ = unregister(h);
        }
        if (self.wts_module) |module| _ = FreeLibrary(module);
        self.* = .{};
    }

    fn shellCloaked(flags: u32) bool {
        return flags & DWM_CLOAKED_SHELL != 0;
    }

    fn refreshShell(window: *Window) void {
        const hwnd = window.hwnd orelse return;
        var flags: u32 = 0;
        if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &flags, @sizeOf(u32)) >= 0) {
            window.setOcclusion("desktop", shellCloaked(flags));
        }
    }

    fn onCloakEvent(hook: ?*anyopaque, _: u32, target: ?w32.HWND, object: i32, child: i32, _: u32, _: u32) callconv(.winapi) void {
        if (object != 0 or child != 0) return;
        const hwnd = target orelse return;
        var name: [64]u16 = undefined;
        const len = GetClassNameW(hwnd, &name, name.len);
        if (len <= 0 or !std.mem.eql(u16, name[0..@intCast(len)], App.WINDOW_CLASS_NAME[0..])) return;
        const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (userdata == 0) return;
        const window: *Window = @ptrFromInt(@as(usize, @bitCast(userdata)));
        if (window.visibility.cloak_hook != hook) return;
        refreshShell(window);
    }

    fn displayOff(setting: *const PowerSetting) ?bool {
        if (setting.length != @sizeOf(u32) or !std.meta.eql(setting.guid, display_state)) return null;
        return switch (setting.state) {
            0, 2 => true,
            1 => false,
            else => null,
        };
    }

    fn proc(comptime T: type, module: w32.HINSTANCE, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(module, name.ptr));
    }

    extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) ?w32.HINSTANCE;
    extern "kernel32" fn FreeLibrary(w32.HINSTANCE) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(w32.HINSTANCE, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "user32" fn GetClassNameW(w32.HWND, [*]u16, i32) callconv(.winapi) i32;
    extern "dwmapi" fn DwmGetWindowAttribute(w32.HWND, u32, *anyopaque, u32) callconv(.winapi) i32;
};

pub const WM_GHOSTTY_WINDOW_STATE: u32 = w32.WM_USER + 0x4A;
pub const WM_GHOSTTY_SIMULATE_OCCLUSION: u32 = w32.WM_USER + 0x4B;

fn fitFullscreen(self: *Window) void {
    if (!self.title_bar.is_fullscreen) return;
    const hwnd = self.hwnd orelse return;
    const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
    var info: w32.MONITORINFO = .{ .cbSize = @sizeOf(w32.MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
    if (w32.GetMonitorInfoW(monitor, &info) == 0) return;
    const rect = info.rcMonitor;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
}

test "only shell cloak pauses the renderers" {
    try std.testing.expect(!VisibilitySubscriptions.shellCloaked(0));
    try std.testing.expect(!VisibilitySubscriptions.shellCloaked(1));
    try std.testing.expect(!VisibilitySubscriptions.shellCloaked(4));
    try std.testing.expect(VisibilitySubscriptions.shellCloaked(2));
    try std.testing.expect(VisibilitySubscriptions.shellCloaked(3));
}

test "display notifications reject other settings and damaged payloads" {
    const V = VisibilitySubscriptions;
    var setting: V.PowerSetting = .{ .guid = V.display_state, .length = 4, .state = 0 };
    try std.testing.expectEqual(@as(?bool, true), V.displayOff(&setting));
    setting.state = 1;
    try std.testing.expectEqual(@as(?bool, false), V.displayOff(&setting));
    setting.state = 2;
    try std.testing.expectEqual(@as(?bool, true), V.displayOff(&setting));
    setting.state = 3;
    try std.testing.expectEqual(@as(?bool, null), V.displayOff(&setting));
    setting.length = 1;
    try std.testing.expectEqual(@as(?bool, null), V.displayOff(&setting));
    setting.length = 4;
    setting.guid.Data1 = 0;
    try std.testing.expectEqual(@as(?bool, null), V.displayOff(&setting));
}

const AppModeSamples = struct {
    positive_capture: ?u64 = null,

    fn update(self: *AppModeSamples, state: *gx.app_mode.State, enabled: bool, count: usize, answers: []const ?bool, capture: u64) bool {
        if (!enabled or count != 1) {
            self.positive_capture = null;
            return state.update(enabled, count, answers);
        }
        const positive = for (answers) |answer| {
            if (answer orelse false) break true;
        } else false;
        if (positive and state.pending() and self.positive_capture == capture) return state.active;
        const active = state.update(enabled, count, answers);
        if (positive) {
            self.positive_capture = capture;
        } else if (!state.pending()) {
            self.positive_capture = null;
        }
        return active;
    }
};

test "app mode hysteresis needs two independently captured process tables" {
    var state: gx.app_mode.State = .{};
    var samples: AppModeSamples = .{};
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 1));
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 1));
    try std.testing.expectEqual(@as(u8, 1), state.hits);
    try std.testing.expect(!samples.update(&state, true, 1, &.{null}, 2));
    try std.testing.expect(samples.update(&state, true, 1, &.{true}, 2));
    try std.testing.expect(!samples.update(&state, true, 1, &.{false}, 2));
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 2));
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 2));
    try std.testing.expect(samples.update(&state, true, 1, &.{true}, 3));
}

test "app mode samples reset when the feature is disabled or another tab opens" {
    var state: gx.app_mode.State = .{};
    var samples: AppModeSamples = .{};
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 1));
    try std.testing.expect(!samples.update(&state, true, 2, &.{true}, 1));
    try std.testing.expectEqual(@as(?u64, null), samples.positive_capture);
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 1));
    try std.testing.expect(!samples.update(&state, false, 1, &.{true}, 1));
    try std.testing.expect(!samples.update(&state, true, 1, &.{true}, 1));
    try std.testing.expect(samples.update(&state, true, 1, &.{true}, 2));
}

test "window and caption private message contracts do not collide" {
    const messages = [_]u32{
        WM_GHOSTTY_SIMULATE_DPI,
        WM_GHOSTTY_SIMULATE_SYSTEM_THEME,
        WM_GHOSTTY_WINDOW_STATE,
        WM_GHOSTTY_SIMULATE_OCCLUSION,
        TitleBar.WM_GHOSTTY_SIMULATE_D2D_FAILURE,
        TitleBar.WM_GHOSTTY_CAPTION_QUERY,
    };
    for (messages, 0..) |message, i| {
        try std.testing.expect(message >= w32.WM_USER);
        for (messages[i + 1 ..]) |other| try std.testing.expect(message != other);
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn leafIdentity(view: anytype) ?*Leaf {
    if (@TypeOf(view) == *Leaf) return view;
    if (@TypeOf(view) == *Surface) return view.leaf;
    @compileError("expected a Leaf or local Surface identity");
}
fn referenceIndex(values: []const refs.Reference, needle: refs.Reference) ?usize {
    for (values, 0..) |value, index| if (value.matches(needle)) return index;
    return null;
}
pub fn activeLeaf(self: *const Window) ?*Leaf {
    if (self.closing or self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}
pub fn leafForPane(self: *const Window, reference: refs.Reference) ?*Leaf {
    if (self.closing or !reference.isValid()) return null;
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        var iterator = tree.iterator();
        while (iterator.next()) |entry| if (entry.view.reference().matches(reference)) return entry.view;
    }
    return null;
}
pub fn removeLeaf(self: *Window, leaf: *Leaf) void {
    // A confirmed close or revoked lease removes an identity without opening
    // another dialog. User requests must run their confirmation before this.
    const index = self.findTabIndex(leaf) orelse return;
    if (self.tab_trees[index].isSplit()) self.closeSplitSurface(leaf) else self.removeTab(index);
}
pub fn onLeafStateChanged(self: *Window, leaf: *Leaf) void {
    const tab = self.findTabIndex(leaf) orelse return;
    const state = leaf.pane().snapshot();
    if (tab != self.active_tab) {
        self.tab_unread[tab] = self.tab_unread[tab] or state.unread;
        self.tab_bell[tab] = self.tab_bell[tab] or state.bell;
    }
    self.refreshTabTitle(tab);
    self.invalidateTabBar();
    self.uia_bridge.dirty();
}
pub fn closeRemoteTransfer(self: *Window, tab: refs.Reference) void {
    while (self.resolveTab(tab)) |index| {
        var iterator = self.tab_trees[index].iterator();
        const remote_leaf = while (iterator.next()) |entry| {
            if (entry.view.remote() != null) break entry.view;
        } else return;
        remote_leaf.remote().?.disconnect();
        self.removeLeaf(remote_leaf);
    }
}

/// Source terminal shutdown is asynchronous. Keep remote identities visible
/// until leaf_closed confirms completion; ordinary local siblings close now.
fn requestRemoteSelectionClose(self: *Window, selected: []const refs.Reference) bool {
    var found = false;
    var references: std.ArrayList(refs.Reference) = .empty;
    defer references.deinit(self.app.core_app.alloc);
    for (selected) |tab| {
        const index = self.resolveTab(tab) orelse continue;
        var iterator = self.tab_trees[index].iterator();
        while (iterator.next()) |entry| {
            found = found or entry.view.remote() != null;
            references.append(self.app.core_app.alloc, entry.view.reference()) catch return true;
        }
    }
    if (!found) return false;
    const app = self.app;
    const owner = self.ui_reference;
    for (references.items) |reference| {
        const window = app.resolveWindow(owner) orelse return true;
        const leaf = window.leafForPane(reference) orelse continue;
        if (leaf.remote()) |remote| {
            if (remote.closed or remote.unavailable) window.removeLeaf(leaf) else _ = remote.ui.requestCloseFromOwner(remote, true);
        } else window.removeLeaf(leaf);
    }
    return true;
}

/// Install a source description using target-owned panes. Existing tree slots
/// and native parents remain untouched until every identity/allocation succeeds.
pub fn adoptRemoteTab(self: *Window, at: usize, description: *const protocol.Tree, panes: []const *RemotePane) !refs.Reference {
    if (self.closing or self.is_quick_terminal or self.is_remote_host or self.tab_count >= MAX_TABS) return error.InvalidOwner;
    if (panes.len == 0 or panes.len > protocol.max_leaves or description.nodes.len == 0 or description.nodes.len > protocol.max_nodes) return error.InvalidTree;
    for (panes, 0..) |pane, index| {
        if (pane.parent_window != self or pane.app != self.app or self.app.resolveRemote(pane.ui_reference) != null) return error.InvalidOwner;
        for (panes[0..index]) |prior| if (prior == pane or prior.source_reference.matches(pane.source_reference)) return error.InvalidTree;
    }
    const reference = try self.app.ui_ids.create(.tab);
    const attachment = try self.app.ui_ids.attach(reference, self.ui_reference);
    var identities = [_]?*Leaf{null} ** protocol.max_nodes;
    var visited = [_]bool{false} ** protocol.max_nodes;
    var tree = try self.buildRemoteTree(description, description.root, panes, &identities, &visited, 0);
    errdefer tree.deinit();
    for (visited[0..description.nodes.len]) |seen| if (!seen) return error.InvalidTree;
    if (description.active >= description.nodes.len) return error.InvalidTree;
    const focused = identities[description.active] orelse return error.InvalidTree;
    if (description.zoom) |zoom| {
        if (zoom >= description.nodes.len) return error.InvalidTree;
        tree.zoomed = tree.locate(identities[zoom] orelse return error.InvalidTree) orelse return error.InvalidTree;
    }
    var attachments: [protocol.max_leaves]refs.Attachment = undefined;
    for (panes, 0..) |pane, index| attachments[index] = try pane.prepareReparent(self);
    const position = @min(at, self.tab_count);
    self.tab_bar.cancelRename();
    self.tab_bar.cancelDrag();
    self.insertMovedSlot(position, .{ .reference = reference, .attachment = attachment, .tree = tree, .active_surface = focused, .title = @splat(0), .title_len = 0, .title_override = if (description.tab_override.len != 0) .fromUtf8(description.tab_override.slice()) else null, .unread = false, .bell = false, .activated = 0 });
    for (panes, 0..) |pane, index| pane.onReparented(self, attachments[index]);
    self.refreshTabTitle(position);
    self.selectTabIndex(position);
    self.updateTabBarVisibility();
    self.layoutSplits();
    self.updateWindowTitle();
    self.updateAppMode();
    if (!self.shown) self.showWhenReady(focused);
    self.focusActiveSurface();
    self.app.scheduleSessionSave();
    return reference;
}
fn buildRemoteTree(self: *Window, description: *const protocol.Tree, index: u16, panes: []const *RemotePane, identities: *[protocol.max_nodes]?*Leaf, visited: *[protocol.max_nodes]bool, depth: usize) anyerror!Tree {
    if (depth > 32 or index >= description.nodes.len or visited[index]) return error.InvalidTree;
    visited[index] = true;
    const alloc = self.app.core_app.alloc;
    switch (description.nodes.items[index]) {
        .leaf => |source| {
            const pane = for (panes) |candidate| {
                if (candidate.source_reference.matches(source)) break candidate;
            } else return error.InvalidTree;
            for (identities) |existing| if (existing) |leaf| if (leaf.remote() == pane) return error.InvalidTree;
            const leaf = try Leaf.fromRemote(alloc, pane);
            errdefer leaf.discardUnretained(alloc);
            const tree = try Tree.init(alloc, leaf);
            identities[index] = leaf;
            return tree;
        },
        .split => |branch| {
            const ratio: f16 = @floatCast(branch.ratio);
            if (!std.math.isFinite(ratio) or ratio <= 0 or ratio >= 1) return error.InvalidTree;
            var first = try self.buildRemoteTree(description, branch.first, panes, identities, visited, depth + 1);
            defer first.deinit();
            var second = try self.buildRemoteTree(description, branch.second, panes, identities, visited, depth + 1);
            defer second.deinit();
            return try first.split(alloc, .root, if (branch.axis == .horizontal) .right else .down, ratio, &second);
        },
    }
}
pub fn describeTab(self: *Window, tab_reference: refs.Reference) !protocol.Tree {
    const index = self.resolveTab(tab_reference) orelse return error.InvalidTab;
    const tree = &self.tab_trees[index];
    if (tree.nodes.len == 0 or tree.nodes.len > protocol.max_nodes) return error.InvalidTree;
    var nodes: protocol.Bounded(protocol.Node, protocol.max_nodes) = .{ .len = @intCast(tree.nodes.len) };
    for (tree.nodes, nodes.items[0..tree.nodes.len]) |node, *destination| destination.* = switch (node) {
        .leaf => |leaf| .{ .leaf = leaf.reference() },
        .split => |branch| .{ .split = .{ .axis = if (branch.layout == .horizontal) .horizontal else .vertical, .ratio = @floatCast(branch.ratio), .first = @intFromEnum(branch.left), .second = @intFromEnum(branch.right) } },
    };
    return .{ .nodes = nodes, .root = 0, .active = @intFromEnum(tree.locate(self.tab_active_surface[index]) orelse return error.InvalidTree), .zoom = if (tree.zoomed) |zoom| @intFromEnum(zoom) else null, .tab_override = if (self.tab_title_overrides[index]) |title| try protocolTitle(title.slice()) else .{}, .window_override = if (self.window_title_override_len) |len| try protocolTitle(self.window_title_override[0..len]) else .{} };
}
/// UI actions run against the visible target identity. The source evaluates
/// key bindings, while window/tree operations always belong to this owner.
pub fn performUiAction(self: *Window, origin: refs.Reference, action: @import("../../input.zig").Binding.Action, flags: @import("../../input.zig").Binding.Flags) !bool {
    _ = flags;
    const leaf = self.leafForPane(origin) orelse return false;
    const tab = self.findTabIndex(leaf) orelse return false;
    switch (action) {
        .new_split => |direction| {
            self.selectTabIndex(tab);
            _ = self.setActiveSurface(leaf);
            const area = self.surfaceRect();
            try self.newSplit(switch (direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
                .auto => if (area.right - area.left > area.bottom - area.top) .right else .down,
            });
            return true;
        },
        .goto_split => |target| return self.gotoSplit(leaf, switch (target) {
            .previous => .previous,
            .next => .next,
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
        }),
        .resize_split => |value| return self.resizeSplit(leaf, .{ .direction = switch (value[0]) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }, .amount = value[1] }),
        .equalize_splits => return self.equalizeSplits(leaf),
        .toggle_split_zoom => return self.toggleSplitZoom(leaf),
        .new_tab => {
            _ = try self.addTab();
            return true;
        },
        .previous_tab => return self.selectTab(.previous),
        .next_tab => return self.selectTab(.next),
        .last_tab => return self.selectTab(.last),
        .goto_tab => |index| return self.selectTab(@enumFromInt(index)),
        .move_tab => |amount| return self.moveTab(leaf, amount),
        .move_tab_to_new_window => return try self.moveTabToNewWindow(leaf),
        .goto_window => |direction| {
            const windows = self.app.windows.items;
            var index = std.mem.indexOfScalar(*Window, windows, self) orelse return false;
            for (1..windows.len) |_| {
                index = tabs.cycleIndex(index, windows.len, direction == .next);
                const window = windows[index];
                if (window.closing or window.is_remote_host) continue;
                const hwnd = window.hwnd orelse continue;
                if (w32.IsWindowVisible_(hwnd) == 0) continue;
                if (w32.IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                if (w32.SetForegroundWindow(hwnd) == 0) return false;
                window.focusActiveSurface();
                return true;
            }
            return false;
        },
        .set_tab_title => |title| {
            self.setTabTitleOverride(tab, .fromUtf8(title));
            return true;
        },
        .set_window_title => |title| {
            const owned = try self.app.core_app.alloc.dupeZ(u8, title);
            defer self.app.core_app.alloc.free(owned);
            self.setWindowTitle(owned);
            return true;
        },
        .prompt_surface_title, .prompt_tab_title => {
            self.selectTabIndex(tab);
            _ = self.setActiveSurface(leaf);
            self.tab_bar.startRename(tab);
            return self.tab_bar.rename_target != .none;
        },
        .prompt_window_title => {
            self.tab_bar.startWindowRename();
            return self.tab_bar.rename_target != .none;
        },
        .close_tab, .close_window => {
            const app = self.app;
            var closing: std.ArrayList(refs.Reference) = .empty;
            defer closing.deinit(app.core_app.alloc);
            if (!try self.requestUiClose(origin, action, &closing)) return false;
            for (closing.items) |reference| {
                if (reference.kind == .window) {
                    if (app.resolveWindow(reference) != null) return false;
                } else if (app.resolveTab(reference) != null) return false;
            }
            return closing.items.len > 0;
        },
        .toggle_command_palette => {
            self.palette.setActive(!self.palette.active);
            return true;
        },
        .toggle_tab_overview => {
            self.palette.toggle(.tabs);
            return true;
        },
        .toggle_fullscreen => {
            self.toggleFullscreen();
            return true;
        },
        .toggle_maximize => {
            self.toggleMaximize();
            return true;
        },
        .toggle_window_decorations => {
            self.toggleWindowDecorations();
            return true;
        },
        .toggle_window_float_on_top => {
            const hwnd = self.hwnd orelse return false;
            const topmost = w32.GetWindowLongPtrW(hwnd, w32.GWL_EXSTYLE) & w32.WS_EX_TOPMOST != 0;
            return w32.SetWindowPos(hwnd, if (topmost) w32.HWND_NOTOPMOST else w32.HWND_TOPMOST, 0, 0, 0, 0, w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE) != 0;
        },
        .reset_window_size => {
            self.resetWindowSize();
            return true;
        },
        .gx => |value| {
            self.selectTabIndex(tab);
            _ = self.setActiveSurface(leaf);
            return self.app.performGx(self, value);
        },
        else => {
            if (action.scoped(.app) != null) return try self.app.performRemoteAppAction(action);
            return false;
        },
    }
}
fn protocolTitle(value: []const u16) !protocol.Title {
    var bytes: [1024]u8 = undefined;
    const count = try std.unicode.utf16LeToUtf8(&bytes, value);
    return try protocol.Title.init(bytes[0..count]);
}

test "remote tabs are rejected by quick terminal before inspecting backend state" {
    var window: Window = .{ .app = undefined, .is_quick_terminal = true };
    try std.testing.expectError(error.InvalidOwner, window.adoptRemoteTab(0, undefined, &.{}));
}

/// Append only currently displayed panes; callers capture this list before
/// invoking callbacks and deduplicate complete stable references.
pub fn visiblePaneReferences(self: *const Window, out: *std.ArrayList(refs.Reference)) !void {
    if (self.closing or self.is_remote_host or self.tab_count == 0) return;
    const hwnd = self.hwnd orelse return;
    if (w32.IsIconic(hwnd) != 0 or w32.IsWindowVisible_(hwnd) == 0) return;
    var iterator = self.tab_trees[self.active_tab].iterator();
    while (iterator.next()) |entry| {
        const leaf = entry.view;
        if (!leaf.attachment().isValid()) continue;
        const child = leaf.nativeHandle() orelse continue;
        if (w32.IsWindowVisible_(child) == 0) continue;
        try out.append(self.app.core_app.alloc, leaf.reference());
    }
}

/// Captures identities before confirmation, then starts a close. Accepted does
/// not mean completed: the coordinator waits for these identities to disappear.
pub fn requestUiClose(self: *Window, origin: refs.Reference, action: @import("../../input.zig").Binding.Action, closed: *std.ArrayList(refs.Reference)) !bool {
    const app = self.app;
    const owner = self.ui_reference;
    const origin_leaf = self.leafForPane(origin) orelse return false;
    const tab = self.findTabIndex(origin_leaf) orelse return false;
    const base = closed.items.len;
    errdefer closed.items.len = base;
    switch (action) {
        .close_surface => {
            try closed.append(app.core_app.alloc, origin);
            if (origin_leaf.needsConfirmQuit()) {
                var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
                defer arena.deinit();
                var names: std.ArrayList([]const u8) = .empty;
                origin_leaf.appendBusyProcesses(arena.allocator(), &names);
                if (Dialogs.confirmCloseSurface(self.hwnd, names.items) != .accept) {
                    closed.items.len = base;
                    return false;
                }
            }
            const live = app.resolveLeaf(origin) orelse return true;
            if (live.remote()) |remote| {
                if (!remote.closed and !remote.unavailable) {
                    if (!remote.ui.requestCloseFromOwner(remote, true)) {
                        closed.items.len = base;
                        return false;
                    }
                    return true;
                }
            }
            live.ownerWindow().removeLeaf(live);
            return true;
        },
        .close_window => {
            try closed.append(app.core_app.alloc, owner);
            if (!self.confirmCloseIfNeeded()) {
                closed.items.len = base;
                return false;
            }
            const live = app.resolveWindow(owner) orelse return true;
            live.close();
            return true;
        },
        .close_tab => |mode| {
            const selection: TabSelection = switch (mode) {
                .this => .{ .one = tab },
                .other => .{ .all_but = tab },
                .right => .{ .right_of = tab },
            };
            for (0..self.tab_count) |index| if (selection.contains(index)) try closed.append(app.core_app.alloc, self.tab_references[index]);
            if (!self.closeTabsRequested(selection)) {
                closed.items.len = base;
                return false;
            }
            return true;
        },
        else => return false,
    }
}
