// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs (each tab a split tree).
//!
//! The Window owns the tab model (split trees, active surfaces, titles),
//! split layout and window-level state (DPI scale, size limits) and
//! orchestrates the chrome modules:
//!
//!   - `chrome/TitleBar.zig` (`title_bar`): non-client frame, caption,
//!     fullscreen and decorations; gets the first look at every message.
//!   - `chrome/TabBar.zig` (`tab_bar`): tab bar painting, hit-testing,
//!     drag, context menu and inline rename.
//!   - `chrome/Backdrop.zig`: DWM theme, opacity and blur.
//!   - `ui/ResizeOverlay.zig` (`resize_overlay`): the size overlay.
//!   - `ui/Menu.zig`: the main menu, opened through `queueMainMenu`.
//!
//! Language changes reach the window through `onLanguageChanged`.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");

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

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [MAX_TABS][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [MAX_TABS]u16 = undefined,

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

/// Where the main menu queued by `queueMainMenu` opens (null: below the
/// chrome at the left edge).
main_menu_anchor: ?w32.POINT = null,

/// Posted by `queueMainMenu`; opens the main menu.
const WM_APP_MAIN_MENU: u32 = w32.WM_APP + 20;

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
};

/// Called from App.config_change so the chrome tracks live config
/// reloads (background color in particular).
pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| Backdrop.onConfigChange(hwnd, &self.app.config);
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
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };

    const window_style = TitleBar.windowStyle(&app.config, options.is_quick_terminal);
    const style = window_style.style;
    const ex_style = window_style.ex_style;

    // Cascade non-quick-terminal windows: stack each new window 30px
    // down/right of the most recently created window. Stops once the
    // offset would push the window off the work area, then resets.
    // Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    // Honor an explicit configured window position; it takes precedence over
    // the cascade below. Only when BOTH coordinates are set — passing
    // CW_USEDEFAULT for one axis is not a valid literal coordinate (Win32
    // only special-cases it on x, and would use a huge negative y or treat
    // y as nCmdShow), so a partial config falls back to full default.
    if (!options.is_quick_terminal) {
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                cx = px;
                cy = py;
            }
        }
    }
    if (!options.is_quick_terminal and
        cx == w32.CW_USEDEFAULT and cy == w32.CW_USEDEFAULT and
        app.windows.items.len > 0)
    {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        style,
        cx,
        cy,
        800,
        600,
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

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    Backdrop.apply(hwnd, &app.config, .{ .force_opaque = options.force_opaque });

    // Query DPI scale. The default size above is in 96 DPI pixels.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }
    if (self.scale != 1.0 and !options.is_quick_terminal) {
        _ = w32.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            @intFromFloat(@round(800.0 * self.scale)),
            @intFromFloat(@round(600.0 * self.scale)),
            w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE,
        );
    }

    self.tab_bar.createFont();

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// Handle WM_DPICHANGED, which only top-level windows receive: adopt the
/// suggested window rect, rescale the window chrome, and tell every
/// surface (in every tab) about its new content scale.
fn handleDpiChange(self: *Window, dpi: u32, suggested: *const w32.RECT) void {
    if (dpi == 0) return;
    self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.tab_bar.createFont();
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
    // WM_SIZE arrives to lay the surfaces out again.
    self.layoutSplits();
    self.invalidateTabBar();
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
    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    // Delete the tab bar fonts.
    self.tab_bar.deinit();

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    return self.tab_bar.height();
}

/// Height of the chrome above the terminals: the client-area part of the
/// title bar plus the tab bar.
pub fn chromeHeight(self: *const Window) i32 {
    return self.title_bar.height() + self.tab_bar.height();
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
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                _ = w32.ShowWindow(h, w32.SW_SHOW);
                _ = w32.UpdateWindow(h);
            }
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    return surface;
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}

/// Close the tab at `idx`, deinitializing its split tree.
pub fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.tab_bar.cancelRename();
    var tree = self.tab_trees[idx];
    tree.deinit(); // This unrefs all surfaces → Surface.unref frees when ref_count=0
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.tab_count == 0) {
        self.closing = true;
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
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => self.closeOtherTabs(self.findTabIndex(surface) orelse return),
        .right => self.closeTabsRightOf(self.findTabIndex(surface) orelse return),
    }
}

/// Close every tab except the one at `keep`.
pub fn closeOtherTabs(self: *Window, keep: usize) void {
    var current = keep;
    var i: usize = self.tab_count;
    while (i > 0) {
        i -= 1;
        if (i != current) {
            self.closeTabByIndex(i);
            if (i < current) current -= 1;
        }
    }
}

/// Close every tab after the one at `idx`.
pub fn closeTabsRightOf(self: *Window, idx: usize) void {
    var i: usize = self.tab_count;
    while (i > idx + 1) {
        i -= 1;
        self.closeTabByIndex(i);
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
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.closeTabByIndex(tab);
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
    const surface = self.tab_active_surface[idx];
    self.layoutSplits();
    if (surface.hwnd) |h| _ = w32.SetFocus(h);
    self.updateWindowTitle();
}

/// Layout split panes for the active tab.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                entry.view.setVisible(true);
                if (entry.view.hwnd) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);

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

fn layoutNode(self: *Window, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            view.setVisible(true);
            if (view.hwnd) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
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
    std.mem.swap(SplitTree(Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap([256]u16, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    std.mem.swap(u16, &self.tab_title_lens[self.active_tab], &self.tab_title_lens[new_index]);
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

    const moved_active = self.tab_active_surface[tab_idx];
    const moved_title = self.tab_titles[tab_idx];
    const moved_title_len = self.tab_title_lens[tab_idx];

    var i = tab_idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    } else if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    }

    destination.tab_trees[0] = moved_tree;
    destination.tab_active_surface[0] = moved_active;
    destination.tab_titles[0] = moved_title;
    destination.tab_title_lens[0] = moved_title_len;
    destination.tab_count = 1;
    destination.active_tab = 0;

    it = destination.tab_trees[0].iterator();
    while (it.next()) |entry| entry.view.parent_window = destination;

    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    self.invalidateTabBar();

    destination.updateTabBarVisibility();
    destination.updateWindowTitle();
    _ = w32.ShowWindow(destination_hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(destination_hwnd);
    destination.layoutSplits();
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);

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

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    if (self.tab_bar.updateVisibility()) self.handleResize();
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
}

/// Move a tab from one index to another, shifting intermediate tabs.
pub fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.tab_bar.cancelRename();

    // Save the source tab state
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];
    const saved_title_len = self.tab_title_lens[from];

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
            self.tab_title_lens[i] = self.tab_title_lens[i + 1];
        }
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
            self.tab_title_lens[i] = self.tab_title_lens[i - 1];
        }
    }

    // Place the saved tab at the destination
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;
    self.tab_title_lens[to] = saved_title_len;

    self.active_tab = to;
    self.invalidateTabBar();
}

/// Return true if it is safe to close this whole window. If any tab still
/// has a running process, show a single aggregate confirmation dialog
/// (mirroring macOS/GTK, which confirm once per window) and return whether
/// the user approved. Whole-window close paths (title-bar X, Alt+F4,
/// close_window) previously skipped this check entirely; the per-surface
/// close path (Ctrl+Shift+W) still confirms separately in Surface.close.
/// When the last tab has already been closed (tab_count == 0) there is
/// nothing to confirm, so this returns true silently.
pub fn confirmCloseIfNeeded(self: *Window) bool {
    var needs = false;
    outer: for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (surface.core_surface_ready and
                surface.core_surface.needsConfirmQuit())
            {
                needs = true;
                break :outer;
            }
        }
    }
    if (!needs) return true;

    return Dialogs.confirmCloseWindow(self.hwnd) == .accept;
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

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        self.tab_bar.deinit();
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
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Handle WM_PAINT: the client area outside the terminals is the chrome
/// (title bar and tab bar).
fn paint(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    self.title_bar.paint(hdc);
    self.tab_bar.paint(hdc);
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
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_APP_MAIN_MENU => {
            if (!window.closing) Menu.showMainMenu(window, window.main_menu_anchor);
            return 0;
        },

        w32.WM_CTLCOLORSTATIC => {
            // Dark theming for the STATIC popups owned by this window
            // (resize overlay). Static controls send this to their owner,
            // i.e. here — not to surfaceWndProc.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (window.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
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
                window.setActiveTabVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(true);
            }
            window.handleResize();
            return 0;
        },
        w32.WM_POWERBROADCAST => {
            // After system sleep/resume nothing else kicks a re-present:
            // the renderer has no vsync/power awareness, so without this
            // the last pre-sleep frame can stay on screen stale (the same
            // bug as microsoft/terminal#14483). Invalidate every surface
            // in the active tab; the surface WM_PAINT handler validates
            // and wakes the renderer thread, driving a full re-present
            // through the existing pipeline. Both resume events may
            // arrive for a single resume; the redundant invalidation is
            // harmless. Return TRUE per the message contract.
            if (wparam == w32.PBT_APMRESUMEAUTOMATIC or
                wparam == w32.PBT_APMRESUMESUSPEND)
            {
                if (window.active_tab < window.tab_count) {
                    var it = window.tab_trees[window.active_tab].iterator();
                    while (it.next()) |entry| {
                        if (entry.view.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
                    }
                }
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOVE => {
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all tabs
            // so hidden tabs don't surface a stale position when activated.
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    if (entry.view.scrollbar) |sb| _ = sb.repositionAndResize();
                }
            }
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
            // Title-bar X / Alt+F4 / close_all_windows land here. Confirm
            // once for the whole window if any tab has a running process.
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
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (window.tab_bar.contains(y)) {
                window.tab_bar.onLeftButtonDown(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            _ = window.tab_bar.onLeftButtonUp();
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // Double-click on tab bar starts inline rename
            if (window.tab_bar.contains(y)) {
                window.tab_bar.onDoubleClick(x);
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (window.tab_bar.contains(y)) {
                window.tab_bar.onRightButtonUp(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            // Tab drag reorder and tab bar hover.
            _ = window.tab_bar.onMouseMove(x, y);
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
            window.tab_bar.onMouseLeave();
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
