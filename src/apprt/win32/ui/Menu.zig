//! Context and application menus of the win32 apprt, drawn and run by
//! `ui/MenuPopup.zig` (native menus for screen readers and without
//! Direct2D, `MenuPopup.runNative`).
//!
//! Each `show*` function builds its menu on demand and runs it modally at
//! an anchor: the main menu below the main menu button, lined up with its
//! right edge (also from the keyboard); the launch profile menu below the
//! new-tab button; the window menu, the context menus and the list of all
//! tabs where they are asked for. The context menus return what the user
//! picked (null when the menu was dismissed) and the caller performs the
//! choice, the tab bar with `performTabCommand`; the other menus perform
//! the picked item themselves, the window menu by posting its
//! `WM_SYSCOMMAND`. Because menus are built on every invocation they always
//! use the current UI language (labels are English msgids translated with
//! `gx.i18n.tr`, with access keys from the English labels); a menu that is
//! open while the language switches closes (`onLanguageChanged`).
//!
//! A menu runs a modal loop that keeps dispatching messages, so call it
//! from a window message (e.g. a click), never from a core callback; key
//! bindings go through `Window.queueMainMenu`, `queueNewTabMenu` and
//! `queueContextMenu`. One menu is open at a time. A menu whose owner
//! window or terminal went away while it was open returns null, and the
//! menus perform the pick only while their window is still open.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const profiles = gx.profiles;
const w32 = @import("../win32.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Pane = @import("../Pane.zig");
const ui_ref = @import("../../../gx/ui_ref.zig");
const Window = @import("../Window.zig");
const Dialogs = @import("Dialogs.zig");
const MenuPopup = @import("MenuPopup.zig");
const Popup = @import("Popup.zig");
const drop_companion_launch = @import("../drop_companion_launch.zig");
const Settings = @import("Settings.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const trigger = @import("trigger.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);

/// Icon font glyphs of the menu items (Segoe Fluent Icons / Segoe MDL2
/// Assets names in the comments).
const icons = struct {
    const new_tab = d2d.icons.add;
    const new_window: u21 = 0xE78B; // NewWindow
    const profile: u21 = 0xE756; // CommandPrompt
    const profile_custom: u21 = 0xE943; // Code
    const profile_herdr: u21 = 0xE8A9; // ViewAll
    const split: u21 = 0xE8A0; // OpenPane
    const split_right: u21 = 0xE72A; // Forward
    const split_down: u21 = 0xE74B; // Down
    const split_left: u21 = 0xE72B; // Back
    const split_up: u21 = 0xE74A; // Up
    const command_palette: u21 = 0xE8FD; // BulletedList
    const settings = d2d.icons.settings;
    const keyboard = d2d.icons.keyboard;
    const language: u21 = 0xE774; // Globe
    const reload: u21 = 0xE72C; // Refresh
    const open_file: u21 = 0xE8E5; // OpenFile
    const about: u21 = 0xE946; // Info
    const quit: u21 = 0xE7E8; // PowerButton
    const copy: u21 = 0xE8C8; // Copy
    const paste: u21 = 0xE77F; // Paste
    const select_all: u21 = 0xE8B3; // SelectAll
    const search = d2d.icons.search;
    const clear: u21 = 0xE75C; // EraseTool
    const reset: u21 = 0xE777; // UpdateRestore
    const folder: u21 = 0xE838; // FolderOpen
    const rename: u21 = 0xE8AC; // Rename
    const close = d2d.icons.cancel;
    const move_to_window: u21 = 0xE8A7; // OpenInNewWindow
    const duplicate: u21 = 0xE8C8; // Copy
    const zoom: u21 = 0xE740; // FullScreen
    const minimize = d2d.icons.minimize;
    const maximize = d2d.icons.maximize;
    const restore = d2d.icons.restore;
    const close_window = d2d.icons.close;
};

/// The penguin of WSL launch profiles, as on the tabs that run them.
const wsl_emoji = "\u{1F427}";

/// What the menus draw with: the app's Direct2D factory and the colors of
/// the current theme. Null when Direct2D is unavailable.
fn menuHost(app: *App) ?MenuPopup.Host {
    const factory = app.uiFactory() orelse return null;
    return .{
        .hinstance = app.hinstance,
        .factory = factory,
        .tokens = style.Tokens.fromConfig(&app.config),
        .quit_requested = &app.quit_requested,
        .app = app,
    };
}

/// Run `root` for `owner`: drawn by `MenuPopup.run`, or native for screen
/// readers and without Direct2D (`MenuPopup.runNative`).
fn runMenu(app: *App, owner: w32.HWND, root: *const MenuPopup.List, options: MenuPopup.Options) ?usize {
    if (!MenuPopup.preferNative()) {
        if (menuHost(app)) |host| return MenuPopup.run(host, owner, root, options);
    }
    return MenuPopup.runNative(app.core_app.alloc, owner, root, options);
}

/// The shortcut hints of the menus: the configured keybindings without
/// the keys another program or the input method takes.
fn hintsOf(app: *App) trigger.Hints {
    return .{ .set = &app.config.keybind.set, .blocked = &app.shortcut_conflicts };
}

/// `rect` (client pixels of `hwnd`) in screen pixels.
fn screenRect(hwnd: w32.HWND, rect: w32.RECT) w32.RECT {
    var top_left: w32.POINT = .{ .x = rect.left, .y = rect.top };
    var bottom_right: w32.POINT = .{ .x = rect.right, .y = rect.bottom };
    _ = w32.ClientToScreen(hwnd, &top_left);
    _ = w32.ClientToScreen(hwnd, &bottom_right);
    return .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
}

fn isEmpty(rect: w32.RECT) bool {
    return rect.right <= rect.left or rect.bottom <= rect.top;
}

const SurfaceItem = enum(usize) {
    copy = 1,
    paste,
    select_all,
    split_right,
    split_down,
    split_left,
    split_up,
    zoom_split,
    equalize_splits,
    move_split_to_tab,
    move_split_to_window,
    close_split,
    search,
    clear_screen,
    reset,
    open_pwd,
    settings,
};

/// The right-click menu of a terminal surface: clipboard, splits (zoom,
/// equalize, move to a new tab or window, close), search, clear and reset,
/// the working directory in File Explorer (when the shell reported it with
/// OSC 7) and the settings. Opens at `screen_pt` and returns the binding
/// action to perform on the surface. Opening the working directory needs
/// no terminal, so the menu does it itself.
pub fn showSurfaceContextMenu(surface: *Surface, screen_pt: w32.POINT) ?input.Binding.Action {
    return showPaneContextMenu(Pane.fromLocal(surface), screen_pt);
}
pub fn showPaneContextMenu(pane: Pane, screen_pt: w32.POINT) ?input.Binding.Action {
    return paneMenu(pane, .{ .anchor = MenuPopup.Options.at(screen_pt) });
}
fn paneMenu(pane: Pane, placement: MenuPopup.Options) ?input.Binding.Action {
    const owner = pane.nativeHandle() orelse return null;
    if (!pane.ready()) return null;
    const app = pane.app();
    const window = pane.ownerWindow();
    const window_ref = window.ui_reference;
    const alloc = app.core_app.alloc;

    var menu: MenuPopup.Builder = .init(alloc);
    defer menu.deinit();
    // In the menu's arena the directory outlives the terminal.
    const pwd = workingDirectory(pane, menu.arena.allocator());
    const tab = pane.tabInfo();
    buildSurfaceMenu(&menu, &app.config, hintsOf(app), .{
        .selection = pane.hasSelection(),
        .clipboard_text = w32.IsClipboardFormatAvailable(w32.CF_UNICODETEXT) != 0,
        .split = tab.split,
        .zoomed = tab.zoomed,
        .other_tabs = tab.other_tabs,
        .pwd = pwd != null,
    }) catch |err| {
        log.err("failed to build the terminal menu err={}", .{err});
        return null;
    };

    var options = placement;
    options.owner_scale = window.scale;
    const id = runMenu(app, owner, &menu.root, options) orelse return null;
    return switch (std.enums.fromInt(SurfaceItem, id) orelse return null) {
        .copy => .{ .copy_to_clipboard = .mixed },
        .paste => .paste_from_clipboard,
        .select_all => .select_all,
        .split_right => .{ .new_split = .right },
        .split_down => .{ .new_split = .down },
        .split_left => .{ .new_split = .left },
        .split_up => .{ .new_split = .up },
        .zoom_split => .toggle_split_zoom,
        .equalize_splits => .equalize_splits,
        .move_split_to_tab => .{ .gx = .move_split_to_tab },
        .move_split_to_window => .{ .gx = .move_split_to_window },
        .close_split => .close_surface,
        .search => .start_search,
        .clear_screen => .clear_screen,
        .reset => .reset,
        .open_pwd => {
            if (pwd) |path| if (app.resolveWindow(window_ref)) |live| if (live.hwnd) |hwnd| openFolder(alloc, hwnd, path);
            return null;
        },
        .settings => .{ .gx = .settings },
    };
}

/// What the terminal menu offers depends on.
const SurfaceState = struct {
    selection: bool,
    /// The clipboard holds text to paste.
    clipboard_text: bool,
    /// The terminal's tab has more than one split, and one is zoomed.
    split: bool,
    zoomed: bool,
    /// The window has other tabs.
    other_tabs: bool,
    /// The shell reported its working directory.
    pwd: bool,
};

fn buildSurfaceMenu(
    menu: *MenuPopup.Builder,
    config: *const configpkg.Config,
    hints: trigger.Hints,
    state: SurfaceState,
) Allocator.Error!void {
    const root = &menu.root;
    var buf: [64]u8 = undefined;
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.copy),
        .label = i18n.tr("Copy"),
        .icon = icons.copy,
        .access = 'C',
        .shortcut = hints.text(.{ .copy_to_clipboard = .mixed }, &buf),
        .enabled = state.selection,
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.paste),
        .label = i18n.tr("Paste"),
        .icon = icons.paste,
        .access = 'P',
        .shortcut = hints.text(.paste_from_clipboard, &buf),
        .enabled = state.clipboard_text,
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.select_all),
        .label = i18n.tr("Select All"),
        .icon = icons.select_all,
        .access = 'A',
        .shortcut = hints.text(.select_all, &buf),
    });
    try menu.separator(root);
    const split = try addSplitMenu(menu, root, hints, @intFromEnum(SurfaceItem.split_right));
    try menu.separator(split);
    try menu.add(split, .{
        .id = @intFromEnum(SurfaceItem.zoom_split),
        .label = i18n.tr("Toggle Split Zoom"),
        .icon = icons.zoom,
        .access = 'Z',
        .mark = if (state.zoomed) .check else .none,
        .shortcut = hints.text(.toggle_split_zoom, &buf),
        .enabled = state.split,
    });
    try menu.add(split, .{
        .id = @intFromEnum(SurfaceItem.equalize_splits),
        .label = i18n.tr("Equalize Splits"),
        .access = 'E',
        .shortcut = hints.text(.equalize_splits, &buf),
        .enabled = state.split,
    });
    try menu.separator(split);
    try menu.add(split, .{
        .id = @intFromEnum(SurfaceItem.move_split_to_tab),
        .label = i18n.tr("Move Split to New Tab"),
        .icon = icons.new_tab,
        .access = 'M',
        .shortcut = hints.text(.{ .gx = .move_split_to_tab }, &buf),
        .enabled = state.split,
    });
    try menu.add(split, .{
        .id = @intFromEnum(SurfaceItem.move_split_to_window),
        .label = i18n.tr("Move Split to New Window"),
        .icon = icons.move_to_window,
        .access = 'W',
        .shortcut = hints.text(.{ .gx = .move_split_to_window }, &buf),
        .enabled = state.split or state.other_tabs,
    });
    try menu.separator(split);
    try menu.add(split, .{
        .id = @intFromEnum(SurfaceItem.close_split),
        .label = i18n.tr("Close Split"),
        .icon = icons.close,
        .access = 'C',
        .shortcut = hints.text(.close_surface, &buf),
    });
    try menu.separator(root);
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.search),
        .label = i18n.tr("Search"),
        .icon = icons.search,
        .access = 'E',
        .shortcut = hints.text(.start_search, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.clear_screen),
        .label = i18n.tr("Clear Screen"),
        .icon = icons.clear,
        .access = 'L',
        .shortcut = hints.text(.clear_screen, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.reset),
        .label = i18n.tr("Reset Terminal"),
        .icon = icons.reset,
        .access = 'R',
        .shortcut = hints.text(.reset, &buf),
    });
    try menu.separator(root);
    if (state.pwd) try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.open_pwd),
        .label = i18n.tr("Open Current Directory in File Explorer"),
        .icon = icons.folder,
        .access = 'O',
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.settings),
        .label = i18n.tr("Settings…"),
        .icon = icons.settings,
        .access = 'T',
        .shortcut = settingsShortcut(config, hints, &buf),
    });
}

/// The shortcut of the settings: `gx:settings`, else `open_config` while
/// it opens the settings (`gx-open-config-ui = settings`).
fn settingsShortcut(config: *const configpkg.Config, hints: trigger.Hints, buf: []u8) ?[]const u8 {
    if (hints.text(.{ .gx = .settings }, buf)) |text| return text;
    if (config.@"gx-open-config-ui" != .settings) return null;
    return hints.text(.{ .open_config = .os_open }, buf);
}

/// The terminal's working directory as reported by its shell (OSC 7),
/// when it is an absolute local path; allocated with `alloc`.
fn workingDirectory(pane: Pane, alloc: Allocator) ?[]const u8 {
    const path = (pane.workingDirectory(alloc) catch return null) orelse return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    return path;
}

/// Open the directory `path` in File Explorer.
fn openFolder(alloc: Allocator, owner: w32.HWND, path: []const u8) void {
    const path_w = wstr.allocZ(alloc, path) catch |err| {
        log.err("failed to open the working directory err={}", .{err});
        return;
    };
    defer alloc.free(path_w);
    const result = w32.ShellExecuteW(
        owner,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        path_w,
        null,
        null,
        w32.SW_SHOW,
    );
    // ShellExecute reports success with a value above 32.
    if (result <= 32) log.err("failed to open the working directory path={s} result={}", .{ path, result });
}

/// A Split submenu with one item per direction: ids `first` (right),
/// `first + 1` (down), `first + 2` (left) and `first + 3` (up). Returns
/// the submenu for more items.
fn addSplitMenu(
    menu: *MenuPopup.Builder,
    list: *MenuPopup.List,
    hints: trigger.Hints,
    first: usize,
) Allocator.Error!*MenuPopup.List {
    const split = try menu.submenu(list, .{ .label = i18n.tr("Split"), .icon = icons.split, .access = 'S' });
    const directions = [_]input.Binding.Action.SplitDirection{ .right, .down, .left, .up };
    const labels = [_][:0]const u8{
        i18n.tr("Split Right"),
        i18n.tr("Split Down"),
        i18n.tr("Split Left"),
        i18n.tr("Split Up"),
    };
    const keys = [_]u8{ 'R', 'D', 'L', 'U' };
    const glyphs = [_]u21{ icons.split_right, icons.split_down, icons.split_left, icons.split_up };
    var buf: [64]u8 = undefined;
    for (directions, labels, keys, glyphs, 0..) |direction, label, key, glyph, i| {
        try menu.add(split, .{
            .id = first + i,
            .label = label,
            .icon = glyph,
            .access = key,
            .shortcut = hints.text(.{ .new_split = direction }, &buf),
        });
    }
    return split;
}

/// The context menu of `surface` for the keyboard (`gx:context_menu`):
/// below the terminal cursor, with the first item highlighted. Performs
/// the picked action on the surface.
pub fn showSurfaceContextMenuAtCursor(surface: *Surface) void {
    showPaneContextMenuAtCursor(Pane.fromLocal(surface));
}
pub fn showPaneContextMenuAtCursor(pane: Pane) void {
    const hwnd = pane.nativeHandle() orelse return;
    const anchor = pane.cursorAnchor() orelse return;
    const app = pane.app();
    const reference = pane.reference();
    const cell = cursorCell(
        .{ .x = anchor.x, .y = anchor.y, .width = anchor.width, .height = anchor.height },
        anchor.scale,
        anchor.cell_width,
        anchor.cell_height,
        anchor.pane_width,
        anchor.pane_height,
    );
    const binding = paneMenu(pane, .{
        .anchor = screenRect(hwnd, cell),
        .keyboard = true,
    }) orelse return;
    const live = Pane.resolve(app, reference) orelse return;
    _ = live.performBindingAction(binding) catch |err| {
        log.err("context menu action failed err={}", .{err});
    };
}

/// The cursor cell in client pixels from the core's `imePoint` (the
/// middle of the cell and its bottom, in unscaled points), kept inside the
/// surface.
fn cursorCell(
    point: @import("../../../apprt.zig").IMEPos,
    scale: f32,
    cell_width: u32,
    cell_height: u32,
    surface_width: u32,
    surface_height: u32,
) w32.RECT {
    const cw: i32 = @intCast(@max(cell_width, 1));
    const ch: i32 = @intCast(@max(cell_height, 1));
    const max_x: i32 = @max(@as(i32, @intCast(surface_width)) - cw, 0);
    const max_bottom: i32 = @max(@as(i32, @intCast(surface_height)), ch);
    const center_x: i32 = @intFromFloat(@round(point.x * scale));
    const bottom_y: i32 = @intFromFloat(@round(point.y * scale));
    const left = std.math.clamp(center_x - @divTrunc(cw, 2), 0, max_x);
    const bottom = std.math.clamp(bottom_y, ch, max_bottom);
    return .{ .left = left, .top = bottom - ch, .right = left + cw, .bottom = bottom };
}

/// What the tab context menu asks the window to do (`performTabCommand`).
pub const TabCommand = enum(usize) {
    rename = 1,
    close,
    close_others,
    close_right,
    move_to_new_window,
    duplicate,
    new_tab,
};

/// The right-click menu of the tab bar for the tab at index `tab` of
/// `window`, or for the empty part of the tab bar (null), which only
/// offers New Tab. Opens at `screen_pt`; perform the pick with
/// `performTabCommand`.
pub fn showTabContextMenu(window: *Window, screen_pt: w32.POINT, tab: ?usize) ?TabCommand {
    const owner = window.hwnd orelse return null;
    if (window.closing) return null;
    const app = window.app;

    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildTabMenu(&menu, hintsOf(app), tab, window.tab_count) catch |err| {
        log.err("failed to build the tab menu err={}", .{err});
        return null;
    };

    const id = runMenu(app, owner, &menu.root, .{
        .anchor = MenuPopup.Options.at(screen_pt),
        .owner_scale = window.scale,
    }) orelse return null;
    return std.enums.fromInt(TabCommand, id);
}

fn buildTabMenu(
    menu: *MenuPopup.Builder,
    hints: trigger.Hints,
    tab: ?usize,
    tab_count: usize,
) Allocator.Error!void {
    const root = &menu.root;
    var buf: [64]u8 = undefined;
    if (tab) |index| {
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.rename),
            .label = i18n.tr("Rename Tab"),
            .icon = icons.rename,
            .access = 'R',
            .shortcut = hints.text(.prompt_tab_title, &buf),
        });
        try menu.separator(root);
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.close),
            .label = i18n.tr("Close Tab"),
            .icon = icons.close,
            .access = 'C',
            .shortcut = hints.text(.{ .close_tab = .this }, &buf),
        });
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.close_others),
            .label = i18n.tr("Close Other Tabs"),
            .access = 'O',
            .shortcut = hints.text(.{ .close_tab = .other }, &buf),
            .enabled = tab_count > 1,
        });
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.close_right),
            .label = i18n.tr("Close Tabs to the Right"),
            .access = 'G',
            .shortcut = hints.text(.{ .close_tab = .right }, &buf),
            .enabled = index + 1 < tab_count,
        });
        try menu.separator(root);
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.move_to_new_window),
            .label = i18n.tr("Move Tab to New Window"),
            .icon = icons.move_to_window,
            .access = 'M',
            .shortcut = hints.text(.move_tab_to_new_window, &buf),
            .enabled = tab_count > 1,
        });
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.duplicate),
            .label = i18n.tr("Duplicate Tab"),
            .icon = icons.duplicate,
            .access = 'D',
        });
        try menu.separator(root);
    }
    try menu.add(root, .{
        .id = @intFromEnum(TabCommand.new_tab),
        .label = i18n.tr("New Tab"),
        .icon = icons.new_tab,
        .access = 'N',
        .shortcut = hints.text(.new_tab, &buf),
    });
}

/// The caller resolves the window after its modal menu; the tab is resolved
/// again from its complete stable identity, including epoch and generation.
pub fn performTabCommand(window: *Window, tab: ?gx.ui_ref.Reference, command: TabCommand) void {
    if (command == .new_tab) {
        _ = window.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }
    const index = window.resolveTab(tab orelse return) orelse return;
    switch (command) {
        .rename => window.tab_bar.startRename(index),
        .close => window.closeTabByIndex(index),
        .close_others => window.closeOtherTabs(index),
        .close_right => window.closeTabsRightOf(index),
        .move_to_new_window => {
            const pane = window.paneAtTab(index) orelse return;
            _ = pane.moveTabToNewWindow() catch |err| failed: {
                log.err("failed to move the tab to a new window err={}", .{err});
                break :failed false;
            };
        },
        .duplicate => window.duplicateTab(index),
        .new_tab => unreachable,
    }
}

/// The menu of all tabs of `window`, for a tab strip that cannot show them
/// all: one item per tab with its title and its `goto_tab` shortcut, the
/// active tab marked; a long list scrolls. Picking one selects that tab.
/// Opens below `anchor` (screen pixels, e.g. the overflow button), lined up
/// with its left edge, or its right edge near the right of the screen.
/// Same calling rules as `showMainMenu`.
pub fn showTabList(window: *Window, anchor: w32.RECT) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing or window.tab_count == 0) return;
    const app = window.app;
    const hints = hintsOf(app);

    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    // Tabs can close or move while the menu runs: the pick selects the tab
    // found again by the terminal that was focused in it.
    var identities: [Window.MAX_TABS]ui_ref.Reference = undefined;
    const window_ref = window.ui_reference;
    const count = window.tab_count;
    for (0..count) |i| {
        identities[i] = window.tab_references[i];
        var title_buf: [768]u8 = undefined;
        const label = window.tab_bar.labelText(i, &title_buf) orelse continue;
        var shortcut_buf: [64]u8 = undefined;
        menu.add(&menu.root, .{
            .id = i + 1,
            .label = label,
            .mark = if (i == window.active_tab) .radio else .none,
            .shortcut = hints.text(.{ .goto_tab = i + 1 }, &shortcut_buf),
        }) catch |err| {
            log.err("failed to build the tab list err={}", .{err});
            return;
        };
    }

    const id = runMenu(app, hwnd, &menu.root, .{
        .anchor = anchor,
        .owner_scale = window.scale,
    }) orelse return;
    const live = app.resolveWindow(window_ref) orelse return;
    if (id == 0 or id > count) return;
    if (live.resolveTab(identities[id - 1])) |index| live.selectTabIndex(index);
}

const MainItem = enum(usize) {
    new_tab = 1,
    new_window,
    split_right,
    split_down,
    split_left,
    split_up,
    command_palette,
    settings,
    keybinds,
    reload_config,
    open_config_file,
    about,
    quit,
    drop_receiver,
};

/// Ids of the Language submenu items: this plus the `i18n.Language` value.
const language_ids: usize = 0x3000;

/// The edge of its anchor rectangle a menu lines up with.
pub const Align = MenuPopup.Align;

/// The application menu opened from a button: below `anchor` (screen
/// pixels: the button, down to the bottom of the chrome row), lined up
/// with its `alignment` edge and flipped when it does not fit; null opens
/// it from the keyboard like `showMainMenu(window, null)`. Same calling
/// rules as `showMainMenu`.
pub fn showMain(window: *Window, anchor: ?w32.RECT, alignment: Align) void {
    const rect = anchor orelse return showMainMenu(window, null);
    const timing = Popup.OpenTiming.begin(.menu);
    openMainMenu(window, .{ .anchor = rect, .alignment = alignment, .open_timing = timing });
}

/// The application menu (`gx:main_menu`): new tabs and windows, a launch
/// profile submenu, splits, the command palette, settings, keyboard
/// shortcuts, the UI language, the configuration, About and Quit. Opens at
/// `anchor` (screen coordinates), or from the keyboard (null) below the
/// main menu button lined up with its right edge, with the first item
/// highlighted and the access keys shown; performs the picked item for
/// `window`. Runs a modal loop, so call it from a window message (e.g. a
/// button click), never from a core callback; key bindings go through
/// `Window.queueMainMenu`.
pub fn showMainMenu(window: *Window, anchor: ?w32.POINT) void {
    const timing = Popup.OpenTiming.begin(.menu);
    if (anchor) |pt| return openMainMenu(window, .{ .anchor = MenuPopup.Options.at(pt), .open_timing = timing });
    openMainMenu(window, .{ .anchor = menuButtonAnchor(window), .alignment = .right, .keyboard = true, .open_timing = timing });
}

/// The main menu button and its column down to the bottom of the chrome
/// row in screen pixels, where the main menu opens; without a chrome row,
/// the top right corner of the client area.
fn menuButtonAnchor(window: *Window) w32.RECT {
    const hwnd = window.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const lay = window.title_bar.layout();
    if (!isEmpty(lay.menu)) {
        return screenRect(hwnd, .{ .left = lay.menu.left, .top = lay.menu.top, .right = lay.menu.right, .bottom = lay.bar.bottom });
    }
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const top = window.chromeHeight();
    return screenRect(hwnd, .{ .left = client.right, .top = top, .right = client.right, .bottom = top });
}

/// Invalidate generations, not live callback storage. Active overlays finish
/// their transaction (an open menu, palette or settings stays open, only
/// marked stale); the next idle preparation/open rebuilds their hosts. Only
/// the owner's destruction ends an open menu (`Settings.onWindowDestroyed`).
pub fn invalidateWindow(window: *Window) void {
    window.palette.invalidateHost();
    Settings.invalidateOwner(window);
    if (window.hwnd) |hwnd| MenuPopup.invalidateOwner(hwnd);
}

/// What hidden popup hosts draw with from the system (`style.system`):
/// whether high contrast applies and, if it does, its system colors.
const SystemUi = struct {
    high_contrast: bool,
    colors: ?style.SystemColors,

    fn current() SystemUi {
        const high_contrast = style.system.highContrast();
        return .{ .high_contrast = high_contrast, .colors = if (high_contrast) style.system.colors else null };
    }
};

/// The system UI state the hidden hosts were last retired for; null until
/// the first broadcast of the process. GUI thread.
var drawn_system: ?SystemUi = null;

/// A system broadcast reached a window (`App.onSystemSettingChange`), after
/// `style.system` was read again: retire every owner's hidden hosts only
/// when what they draw with changed (`invalidateApp`). Every window hears
/// each broadcast, and a new window hears its own WM_THEMECHANGED
/// (`Backdrop.apply`); the first one that sees a change retires them all,
/// the others see none. The app light or dark mode reaches the hosts as a
/// configuration change when the configuration follows it.
pub fn onSystemChange(app: *App) void {
    const now = SystemUi.current();
    if (drawn_system) |drawn| if (std.meta.eql(drawn, now)) return;
    drawn_system = now;
    invalidateApp(app);
}

/// A digest of the launch profiles detected in `cache`; null when none are
/// cached (not detected yet, or invalidated).
pub fn shellsDigest(cache: *const gx.profiles.Cache) ?u64 {
    const shells = cache.shells orelse return null;
    var hasher: std.hash.Wyhash = .init(0);
    for (shells.profiles) |profile| {
        hashBytes(&hasher, profile.id);
        hashBytes(&hasher, profile.name);
        hashBytes(&hasher, profile.name_arg orelse "");
        std.hash.autoHash(&hasher, profile.kind);
        std.hash.autoHash(&hasher, std.meta.activeTag(profile.command));
        switch (profile.command) {
            .argv => |argv| {
                std.hash.autoHash(&hasher, argv.len);
                for (argv) |arg| hashBytes(&hasher, arg);
            },
            .command_line => |line| hashBytes(&hasher, line),
        }
    }
    return hasher.final();
}

fn hashBytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    std.hash.autoHash(hasher, bytes.len);
    hasher.update(bytes);
}

/// The launch profiles were detected again (an "Environment" broadcast,
/// `App.onSystemSettingChange`); `before` is their `shellsDigest` from
/// before. When they changed, or are not known, what lists them is read
/// again at the next opening (the shells of the settings; the palette
/// entries follow `profiles_cache` themselves) and every window prepares
/// its hidden UI again. The hosts stay: nothing they draw with changed.
pub fn onShellsDetected(app: *App, before: ?u64) void {
    if (before) |old| if (shellsDigest(&app.profiles_cache)) |new| if (old == new) return;
    for (app.windows.items) |window| shellsChanged(window);
    if (app.quick_terminal) |qt| shellsChanged(qt.window);
}

fn shellsChanged(window: *Window) void {
    Settings.invalidateData(window);
    window.palette.preparation.request();
}

/// Test windows without an HWND for the invalidation tests.
const InvalidationFixture = struct {
    app: App,
    primary: Window,
    window: Window,
    windows: [2]*Window,

    fn init(self: *InvalidationFixture) void {
        self.app = undefined;
        self.app.quick_terminal = null;
        self.primary = undefined;
        self.primary.hwnd = null;
        self.primary.palette = .{};
        self.window = undefined;
        self.window.hwnd = null;
        self.window.palette = .{};
        self.windows = .{ &self.primary, &self.window };
        self.app.windows = .{ .items = &self.windows, .capacity = self.windows.len };
    }

    fn settle(self: *InvalidationFixture) void {
        for (self.windows) |owner| {
            owner.palette.preparation.pending = .initEmpty();
            owner.palette.popup.reuse_invalid = false;
            owner.palette.item_cache.stamp = 123;
        }
    }

    fn retired(self: *InvalidationFixture) !bool {
        const first = self.windows[0].palette.popup.reuse_invalid;
        for (self.windows) |owner| {
            try std.testing.expectEqual(first, owner.palette.popup.reuse_invalid);
            try std.testing.expectEqual(first, owner.palette.preparation.isPending());
            try std.testing.expectEqual(first, owner.palette.item_cache.stamp == null);
        }
        return first;
    }
};

test "P4 a change of what popups draw with retires every owner's hidden hosts once" {
    // No HWND, desktop or native theme API: high contrast is forced, as
    // `App.simulateSystemTheme` does before it broadcasts.
    const forced = style.system.forced_high_contrast;
    defer style.system.forced_high_contrast = forced;
    const drawn = drawn_system;
    defer drawn_system = drawn;
    var fixture: InvalidationFixture = undefined;
    fixture.init();
    style.system.forced_high_contrast = false;
    fixture.app.onSystemSettingChange(&fixture.window, .sys_colors);
    fixture.settle();
    style.system.forced_high_contrast = true;
    // A non-primary window hears it first and retires every owner's hosts,
    // although only the primary window applies process-wide changes.
    fixture.app.onSystemSettingChange(&fixture.window, .sys_colors);
    try std.testing.expect(try fixture.retired());
    fixture.settle();
    // The other windows hear the same broadcasts: nothing is retired twice.
    fixture.app.onSystemSettingChange(&fixture.primary, .sys_colors);
    fixture.app.onSystemSettingChange(&fixture.primary, .theme);
    try std.testing.expect(!try fixture.retired());
    style.system.forced_high_contrast = false;
    fixture.app.onSystemSettingChange(&fixture.primary, .theme);
    try std.testing.expect(try fixture.retired());
}

test "P4 broadcasts that change nothing popups draw with keep every hidden host" {
    // Every window hears each broadcast, and a new window hears its own
    // WM_THEMECHANGED (Backdrop.apply sets its window theme in init). None of
    // them may retire the hosts unless what the popups draw with changed.
    var app: App = undefined;
    app.quick_terminal = null;
    var primary: Window = undefined;
    primary.hwnd = null;
    primary.palette = .{};
    var window: Window = undefined;
    window.hwnd = null;
    window.palette = .{};
    var windows = [_]*Window{ &primary, &window };
    app.windows = .{ .items = &windows, .capacity = windows.len };
    // Whatever the first broadcast of this process does, the next ones see
    // the same system state.
    app.onSystemSettingChange(&window, .theme);
    for (windows) |owner| {
        owner.palette.preparation.pending = .initEmpty();
        owner.palette.popup.reuse_invalid = false;
        owner.palette.item_cache.stamp = 123;
    }
    app.onSystemSettingChange(&window, .theme);
    app.onSystemSettingChange(&primary, .theme);
    app.onSystemSettingChange(&window, .sys_colors);
    app.onSystemSettingChange(&primary, .{ .colorization = .{ .color = 0xC40078D4, .opaque_blend = true } });
    for (windows) |owner| {
        try std.testing.expect(!owner.palette.preparation.isPending());
        try std.testing.expect(!owner.palette.popup.reuse_invalid);
        try std.testing.expect(owner.palette.item_cache.stamp == 123);
    }
}

test "P4 re-detected launch profiles refresh what lists them only when they changed" {
    var fixture: InvalidationFixture = undefined;
    fixture.init();
    fixture.settle();
    fixture.app.profiles_cache = .{};
    try std.testing.expect(shellsDigest(&fixture.app.profiles_cache) == null);
    const first = [_]gx.profiles.Profile{.{ .id = "pwsh", .name = "PowerShell", .command = .{ .command_line = "pwsh.exe" }, .kind = .pwsh }};
    fixture.app.profiles_cache.shells = .{ .arena = .init(std.testing.allocator), .profiles = &first };
    defer fixture.app.profiles_cache.invalidate();
    const before = shellsDigest(&fixture.app.profiles_cache);
    try std.testing.expect(before != null);
    // Detected again with the same result: nothing to do.
    onShellsDetected(&fixture.app, before);
    try std.testing.expect(!try fixture.retired());
    // Another result, or none known before: the data and the preparation
    // follow, the hosts stay.
    const second = [_]gx.profiles.Profile{.{ .id = "pwsh", .name = "PowerShell", .command = .{ .command_line = "pwsh.exe -NoLogo" }, .kind = .pwsh }};
    fixture.app.profiles_cache.shells.?.profiles = &second;
    try std.testing.expect(shellsDigest(&fixture.app.profiles_cache).? != before.?);
    for ([_]?u64{ before, null }) |known| {
        fixture.settle();
        onShellsDetected(&fixture.app, known);
        for (fixture.windows) |owner| {
            try std.testing.expect(owner.palette.preparation.isPending());
            try std.testing.expect(!owner.palette.popup.reuse_invalid);
            try std.testing.expect(owner.palette.item_cache.stamp == 123);
        }
    }
}

/// Retire the hidden hosts of every owner (`invalidateWindow`): a system UI
/// change (`onSystemChange`) applies to all of them, whichever window heard
/// the broadcast first.
pub fn invalidateApp(app: *App) void {
    for (app.windows.items) |window| invalidateWindow(window);
    if (app.quick_terminal) |qt| invalidateWindow(qt.window);
}

/// Only the outer GUI loop calls this, after dispatch and before GetMessage.
/// Pending units are requested by owner creation (enabled by its first
/// frame) and by configuration, language, DPI and launch profile
/// notifications. One unit runs at a time, the hidden palette, main menu or
/// settings of one owner, and the input queue is looked at again before the
/// next: input waits for one unit at most, and the rest goes on at the next
/// idle boundary. Owners take turns, from the one after the owner served
/// last. No unit reads a file: what needs one (detecting the launch
/// profiles, the palette history, the theme directories, the configuration
/// layers) is left to the real opening (`Palette.prepare`, `prepareMain`,
/// `Settings.prepare`).
pub fn prepareIdle(app: *App) void {
    prepareIdleWith(app, IdleOps);
}

/// What idle preparation asks of the system and does with a unit; the
/// scheduling tests replace it.
const IdleOps = struct {
    /// Whether input waits. PeekMessage may dispatch sent messages, even
    /// the destruction of an owner.
    fn inputPending() bool {
        var message: w32.MSG = undefined;
        return w32.PeekMessageW(&message, null, 0, 0, 0) != 0;
    }

    fn eligible(window: *Window) bool {
        return window.shown and window.first_frame_surface == null and
            !window.closing and !window.palette.active and !Settings.isOpen(window);
    }

    /// One unit; with `GHOSTTY_GX_PERF` the time of one that prepared its
    /// hidden host is `<ui>.prepare.idle`.
    fn run(window: *Window, unit: Popup.Preparation.Unit) void {
        const span = if (gx.perf.enabled()) gx.perf.Span.begin(global.io()) else null;
        const prepared = switch (unit) {
            .palette => window.palette.prepare(),
            .main_menu => prepareMain(window),
            .settings => Settings.prepare(window),
        };
        if (span) |value| if (prepared) {
            _ = value.end(global.io(), switch (unit) {
                .palette => "palette.prepare.idle",
                .main_menu => "menu.prepare.idle",
                .settings => "settings.prepare.idle",
            });
        };
    }
};

/// The owner served last by `prepareIdle`; the next unit comes from the
/// owner after it. GUI thread.
var idle_turn: ui_ref.Reference = .{};

fn prepareIdleWith(app: *App, comptime Ops: type) void {
    while (!app.quit_requested) {
        // Looking at the queue may dispatch sent messages, even the
        // destruction of an owner: no Window is borrowed across it, and the
        // next unit is found again among the owners left.
        if (Ops.inputPending()) return;
        const next = nextIdleUnit(app, Ops) orelse return;
        idle_turn = next.owner.ui_reference;
        Ops.run(next.owner, next.unit);
    }
}

const IdleUnit = struct { owner: *Window, unit: Popup.Preparation.Unit };

/// The next waiting unit of an eligible owner, taken from it, looking at
/// the owners from the one after `idle_turn`.
fn nextIdleUnit(app: *App, comptime Ops: type) ?IdleUnit {
    const count = app.windows.items.len + @intFromBool(app.quick_terminal != null);
    var start: usize = 0;
    for (0..count) |i| {
        if (idle_turn.matches(idleOwner(app, i).ui_reference)) {
            start = i + 1;
            break;
        }
    }
    for (0..count) |step| {
        const owner = idleOwner(app, (start + step) % count);
        if (owner.palette.preparation.takeNext(Ops.eligible(owner))) |unit| return .{ .owner = owner, .unit = unit };
    }
    return null;
}

/// The owners of hidden UI: the windows, then the quick terminal.
fn idleOwner(app: *App, index: usize) *Window {
    return if (index < app.windows.items.len) app.windows.items[index] else app.quick_terminal.?.window;
}

/// Whether the launch profiles are detected for the current environment,
/// so listing them (`App.cachedLaunchProfiles`) probes no file. Idle
/// preparation leaves a detection to the real opening.
pub fn launchProfilesCached(app: *App) bool {
    var env = global.environMap() catch return false;
    defer env.deinit();
    return app.profiles_cache.isCurrent(&env);
}

/// Owners without an HWND and a record of the idle units that ran, for the
/// scheduling tests: no desktop or message queue.
const IdleFixture = struct {
    /// Units that may run in this idle before input arrives.
    var allowed: usize = 0;
    var served: usize = 0;
    /// Each unit as 10 × its owner's id + the unit.
    var runs: [32]u64 = undefined;
    var count: usize = 0;
    /// The first unit destroys the owner at this index (a message dispatched
    /// while the queue is looked at would).
    var destroy: ?struct { app: *App, index: usize } = null;

    fn inputPending() bool {
        return served >= allowed;
    }

    fn eligible(window: *Window) bool {
        return window.shown;
    }

    fn run(window: *Window, unit: Popup.Preparation.Unit) void {
        served += 1;
        runs[count] = 10 * window.ui_reference.id + @intFromEnum(unit);
        count += 1;
        if (destroy) |gone| {
            destroy = null;
            _ = gone.app.windows.orderedRemove(gone.index);
        }
    }

    fn ran() []const u64 {
        return runs[0..count];
    }

    /// One idle boundary at which input arrives after `units` units.
    fn idle(app: *App, units: usize) void {
        allowed = units;
        served = 0;
        prepareIdleWith(app, IdleFixture);
    }

    fn init(app: *App, windows: []Window, list: []*Window) void {
        count = 0;
        destroy = null;
        idle_turn = .{};
        app.* = undefined;
        app.quit_requested = false;
        app.quick_terminal = null;
        for (windows, list, 1..) |*window, *slot, id| {
            window.* = undefined;
            window.palette = .{};
            window.shown = true;
            window.ui_reference = .{ .epoch = 1, .kind = .window, .id = id, .generation = 1 };
            slot.* = window;
        }
        app.windows = .{ .items = list, .capacity = list.len };
    }
};

test "P4 idle preparation looks at the input again after every unit" {
    // The palette, the main menu and the settings of an owner are three
    // units: input that arrives during one waits for that one only, and the
    // others continue at the next idle.
    const turn = idle_turn;
    defer idle_turn = turn;
    var app: App = undefined;
    var windows: [1]Window = undefined;
    var list: [1]*Window = undefined;
    IdleFixture.init(&app, &windows, &list);
    IdleFixture.idle(&app, 1);
    try testing.expectEqualSlices(u64, &.{10}, IdleFixture.ran());
    try testing.expectEqual(@as(usize, 2), windows[0].palette.preparation.pending.count());
    IdleFixture.idle(&app, 0);
    try testing.expectEqualSlices(u64, &.{10}, IdleFixture.ran());
    IdleFixture.idle(&app, std.math.maxInt(usize));
    try testing.expectEqualSlices(u64, &.{ 10, 11, 12 }, IdleFixture.ran());
    try testing.expect(!windows[0].palette.preparation.isPending());
    // Nothing waits: an idle boundary does nothing, polls nothing.
    IdleFixture.idle(&app, std.math.maxInt(usize));
    try testing.expectEqual(@as(usize, 3), IdleFixture.count);
    // A requested quit ends the preparation before its next unit.
    windows[0].palette.preparation.request();
    app.quit_requested = true;
    IdleFixture.idle(&app, std.math.maxInt(usize));
    try testing.expectEqual(@as(usize, 3), IdleFixture.count);
}

test "P4 idle preparation advances every owner in turn" {
    // Owners take turns, starting after the one served last, also across
    // idle boundaries; an owner not shown yet keeps its units.
    const turn = idle_turn;
    defer idle_turn = turn;
    var app: App = undefined;
    var windows: [3]Window = undefined;
    var list: [3]*Window = undefined;
    IdleFixture.init(&app, &windows, &list);
    windows[2].shown = false;
    for (0..4) |_| IdleFixture.idle(&app, 1);
    try testing.expectEqualSlices(u64, &.{ 10, 20, 11, 21 }, IdleFixture.ran());
    IdleFixture.idle(&app, std.math.maxInt(usize));
    try testing.expectEqualSlices(u64, &.{ 10, 20, 11, 21, 12, 22 }, IdleFixture.ran());
    try testing.expectEqual(@as(usize, 3), windows[2].palette.preparation.pending.count());
    windows[2].shown = true;
    windows[0].palette.preparation.request();
    IdleFixture.idle(&app, std.math.maxInt(usize));
    try testing.expectEqualSlices(u64, &.{ 10, 20, 11, 21, 12, 22, 30, 10, 31, 11, 32, 12 }, IdleFixture.ran());
}

test "P4 idle preparation finds its owners again after every unit" {
    // A message dispatched while the queue is looked at may destroy an owner:
    // the next unit is found among the owners left, never through a pointer
    // kept from before.
    const turn = idle_turn;
    defer idle_turn = turn;
    var app: App = undefined;
    var windows: [3]Window = undefined;
    var list: [3]*Window = undefined;
    IdleFixture.init(&app, &windows, &list);
    IdleFixture.destroy = .{ .app = &app, .index = 1 };
    IdleFixture.idle(&app, std.math.maxInt(usize));
    try testing.expectEqualSlices(u64, &.{ 10, 30, 11, 31, 12, 32 }, IdleFixture.ran());
    try testing.expectEqual(@as(usize, 3), windows[1].palette.preparation.pending.count());
}

/// The idle unit of the main menu: build it and prepare its hidden root
/// host (`MenuPopup.prepare`), unless that needs a launch profile detection.
fn prepareMain(window: *Window) bool {
    if (MenuPopup.preferNative()) return false;
    const owner = window.hwnd orelse return false;
    const app = window.app;
    if (!launchProfilesCached(app)) return false;
    const host = menuHost(app) orelse return false;
    var launch: ProfileItems = .init(app);
    defer launch.deinit();
    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildMainMenu(&menu, app, &launch) catch return false;
    MenuPopup.prepare(host, owner, &menu.root, .{
        .anchor = menuButtonAnchor(window),
        .alignment = .right,
        .keyboard = true,
        .owner_scale = window.scale,
        .reuse_root = true,
    });
    return true;
}

fn openMainMenu(window: *Window, placement: MenuPopup.Options) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing) return;
    const app = window.app;
    const attachment = window.ui_attachment;
    const prepare = if (gx.perf.enabled()) gx.perf.Span.begin(global.io()) else null;
    const detections = app.profiles_cache.detections;

    var launch: ProfileItems = .init(app);
    if (prepare != null) log.info("menu profile detections={}", .{app.profiles_cache.detections - detections});
    defer launch.deinit();
    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildMainMenu(&menu, app, &launch) catch |err| {
        log.err("failed to build the main menu err={}", .{err});
        return;
    };
    if (prepare) |span| _ = span.end(global.io(), "menu.prepare");

    var options = placement;
    if (options.open_timing) |*timing| timing.lap(.prepare);
    options.owner_scale = window.scale;
    options.reuse_root = true;
    const id = runMenu(app, hwnd, &menu.root, options) orelse return;
    if (!windowOpen(app, window, attachment)) return;

    if (launch.pick(id)) |pick| {
        _ = app.openProfile(window, pick.id, pick.where);
        return;
    }
    if (id >= language_ids) {
        if (std.enums.fromInt(i18n.Language, id - language_ids)) |lang| setLanguage(window, lang);
        return;
    }
    switch (std.enums.fromInt(MainItem, id) orelse return) {
        .new_tab => window.performBindingAction(.new_tab),
        .new_window => window.performBindingAction(.new_window),
        .split_right => window.performBindingAction(.{ .new_split = .right }),
        .split_down => window.performBindingAction(.{ .new_split = .down }),
        .split_left => window.performBindingAction(.{ .new_split = .left }),
        .split_up => window.performBindingAction(.{ .new_split = .up }),
        .command_palette => window.performBindingAction(.toggle_command_palette),
        .settings => _ = app.performGx(window, .settings),
        .keybinds => _ = app.performGx(window, .keybinds),
        .reload_config => window.performBindingAction(.reload_config),
        .open_config_file => _ = app.openConfigFile(.os_open) catch |err| failed: {
            log.err("failed to open the configuration file err={}", .{err});
            break :failed false;
        },
        .about => Dialogs.showAbout(hwnd, build_config.version_string),
        .quit => window.performBindingAction(.quit),
        // `windowOpen` re-resolved this window after the modal menu returned;
        // the launch never pumps messages, so it stays valid for the notice.
        .drop_receiver => switch (drop_companion_launch.launch(app)) {
            .launched => {},
            .not_elevated => window.showNotice(.{
                .severity = .@"error",
                .title = i18n.tr("Drop Receiver"),
                .body = i18n.tr("A normal-privilege drop receiver needs an elevated window with User Account Control enabled."),
            }, null),
            .no_linked_token, .not_medium, .launch_failed => window.showNotice(.{
                .severity = .@"error",
                .title = i18n.tr("Drop Receiver"),
                .body = i18n.tr("The drop receiver could not be started."),
            }, null),
        },
    }
}

fn buildMainMenu(menu: *MenuPopup.Builder, app: *App, launch: *ProfileItems) Allocator.Error!void {
    const hints = hintsOf(app);
    const root = &menu.root;
    var buf: [64]u8 = undefined;

    try menu.add(root, .{
        .id = @intFromEnum(MainItem.new_tab),
        .label = i18n.tr("New Tab"),
        .icon = icons.new_tab,
        .access = 'T',
        .shortcut = hints.text(.new_tab, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.new_window),
        .label = i18n.tr("New Window"),
        .icon = icons.new_window,
        .access = 'N',
        .shortcut = hints.text(.new_window, &buf),
    });
    const profile_menu = try menu.submenu(root, .{
        .label = i18n.tr("New Tab with Profile"),
        .icon = icons.profile,
        .access = 'P',
    });
    try launch.append(menu, profile_menu, hints, .tab);
    _ = try addSplitMenu(menu, root, hints, @intFromEnum(MainItem.split_right));
    try menu.separator(root);

    try menu.add(root, .{
        .id = @intFromEnum(MainItem.command_palette),
        .label = i18n.tr("Command Palette"),
        .icon = icons.command_palette,
        .access = 'C',
        .shortcut = hints.text(.toggle_command_palette, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.settings),
        .label = i18n.tr("Settings…"),
        .icon = icons.settings,
        .access = 'E',
        .shortcut = settingsShortcut(&app.config, hints, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.keybinds),
        .label = i18n.tr("Keyboard Shortcuts"),
        .icon = icons.keyboard,
        .access = 'K',
        .shortcut = hints.text(.{ .gx = .keybinds }, &buf),
    });
    const languages = try menu.submenu(root, .{ .label = i18n.tr("Language"), .icon = icons.language, .access = 'L' });
    for (std.enums.values(i18n.Language)) |lang| {
        try menu.add(languages, .{
            .id = language_ids + @intFromEnum(lang),
            .label = lang.nativeName(),
            .access = switch (lang) {
                .en => 'E',
                .zh_CN => 'C',
            },
            .mark = if (lang == i18n.current()) .radio else .none,
        });
    }
    try menu.separator(root);

    try menu.add(root, .{
        .id = @intFromEnum(MainItem.reload_config),
        .label = i18n.tr("Reload Configuration"),
        .icon = icons.reload,
        .access = 'R',
        .shortcut = hints.text(.reload_config, &buf),
    });
    // `open_config` opens the settings with `gx-open-config-ui = settings`.
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.open_config_file),
        .label = i18n.tr("Open Configuration File"),
        .icon = icons.open_file,
        .access = 'O',
        .shortcut = if (app.config.@"gx-open-config-ui" == .settings)
            null
        else
            hints.text(.{ .open_config = .os_open }, &buf),
    });
    // Only an elevated window with a running broker can pair with a
    // normal-privilege drop receiver; medium windows never show this item.
    if (app.drop_bridge.available()) {
        try menu.separator(root);
        try menu.add(root, .{
            .id = @intFromEnum(MainItem.drop_receiver),
            .label = i18n.tr("Drop into Elevated Terminal…"),
            .icon = d2d.icons.shield,
            .access = 'D',
        });
    }
    try menu.separator(root);
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.about),
        .label = i18n.tr("About Ghostty GX"),
        .icon = icons.about,
        .access = 'A',
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.quit),
        .label = i18n.tr("Quit"),
        .icon = icons.quit,
        .access = 'Q',
        .shortcut = hints.text(.quit, &buf),
    });
}

/// Switch the UI language: save `language` to the settings overlay
/// `gui-settings.ghostty` and reload the configuration, which switches
/// the language and refreshes every window (`App.updateConfig`).
fn setLanguage(window: *Window, lang: i18n.Language) void {
    if (lang == i18n.current()) return;
    saveLanguage(window.app.core_app.alloc, lang) catch |err| {
        log.err("failed to save the language to {s} err={}", .{ gx.gui_settings.file_name, err });
        return;
    };
    window.performBindingAction(.reload_config);
}

fn saveLanguage(alloc: Allocator, lang: i18n.Language) !void {
    const path = try gx.config_layers.overlayPath(alloc);
    defer alloc.free(path);
    var overlay = try gx.gui_settings.Overlay.load(alloc, global.io(), path);
    defer overlay.deinit();
    try overlay.set("language", lang.configValue());
    try overlay.save(global.io(), path);
}

/// Reject object-address reuse and hide/reopen while the modal menu ran.
fn windowOpen(app: *App, window: *Window, attachment: ui_ref.Attachment) bool {
    return app.resolveWindowView(attachment) == window;
}

/// Items of the launch profile menu besides the profiles.
const ProfileMenuItem = enum(usize) {
    set_default_shell = 1,
    split_right,
    split_down,
    split_left,
    split_up,
};

/// The launch profile menu of the new-tab button: the launch profiles,
/// the default one tagged, each opening in a new tab of `window`; a
/// submenu opening them in a new window; the splits; and Set Default
/// Shell…, which opens the settings. Opens at `anchor` (screen
/// coordinates). Same calling rules as `showMainMenu`.
pub fn showProfileMenu(window: *Window, anchor: w32.POINT) void {
    openProfileMenu(window, .{ .anchor = MenuPopup.Options.at(anchor) });
}

/// The launch profile menu for the keyboard (`gx:new_tab_menu`): below the
/// new-tab button (below the chrome at the left edge without one), with
/// the first item highlighted.
pub fn showNewTabMenu(window: *Window) void {
    const hwnd = window.hwnd orelse return;
    const button = window.tab_bar.new_tab_rect;
    const anchor = if (window.tab_bar.visible and !isEmpty(button))
        screenRect(hwnd, button)
    else below_chrome: {
        const top = window.chromeHeight();
        break :below_chrome screenRect(hwnd, .{ .left = 0, .top = top, .right = 0, .bottom = top });
    };
    openProfileMenu(window, .{ .anchor = anchor, .keyboard = true });
}

fn openProfileMenu(window: *Window, placement: MenuPopup.Options) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing) return;
    const app = window.app;
    const attachment = window.ui_attachment;

    var launch: ProfileItems = .init(app);
    defer launch.deinit();
    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildProfileMenu(&menu, hintsOf(app), &launch) catch |err| {
        log.err("failed to build the profile menu err={}", .{err});
        return;
    };

    var options = placement;
    options.owner_scale = window.scale;
    const id = runMenu(app, hwnd, &menu.root, options) orelse return;
    if (!windowOpen(app, window, attachment)) return;
    if (launch.pick(id)) |pick| {
        _ = app.openProfile(window, pick.id, pick.where);
        return;
    }
    switch (std.enums.fromInt(ProfileMenuItem, id) orelse return) {
        .set_default_shell => _ = Settings.show(window),
        .split_right => window.performBindingAction(.{ .new_split = .right }),
        .split_down => window.performBindingAction(.{ .new_split = .down }),
        .split_left => window.performBindingAction(.{ .new_split = .left }),
        .split_up => window.performBindingAction(.{ .new_split = .up }),
    }
}

fn buildProfileMenu(
    menu: *MenuPopup.Builder,
    hints: trigger.Hints,
    launch: *ProfileItems,
) Allocator.Error!void {
    const root = &menu.root;
    try menu.header(root, i18n.tr("New Tab"));
    try launch.append(menu, root, hints, .tab);
    try menu.separator(root);
    const window_menu = try menu.submenu(root, .{
        .label = i18n.tr("New Window with Profile"),
        .icon = icons.new_window,
        .access = 'W',
    });
    try launch.append(menu, window_menu, hints, .window);
    _ = try addSplitMenu(menu, root, hints, @intFromEnum(ProfileMenuItem.split_right));
    try menu.separator(root);
    try menu.add(root, .{
        .id = @intFromEnum(ProfileMenuItem.set_default_shell),
        .label = i18n.tr("Set Default Shell…"),
        .icon = icons.settings,
        .access = 'D',
    });
}

/// The launch profiles as menu items, from the app's cache of detected
/// shells (`App.cachedLaunchProfiles`). Items with ids from `tab_ids` open
/// a profile in a new tab, from `window_ids` in a new window.
const ProfileItems = struct {
    const tab_ids: usize = 0x1000;
    const window_ids: usize = 0x2000;

    arena: std.heap.ArenaAllocator,
    list: ?profiles.List,
    /// The profile new terminals start by default.
    default: ?usize = null,

    fn init(app: *App) ProfileItems {
        var self: ProfileItems = .{
            .arena = .init(app.core_app.alloc),
            .list = app.cachedLaunchProfiles() catch |err| null: {
                log.warn("launch profile detection failed err={}", .{err});
                break :null null;
            },
        };
        self.default = gx.settings_map.commandProfile(
            self.arena.allocator(),
            self.all(),
            app.defaultTerminalCommand(),
            profiles.Platform.native,
        ) catch null;
        return self;
    }

    fn deinit(self: *ProfileItems) void {
        if (self.list) |*list| list.deinit();
        self.arena.deinit();
    }

    fn all(self: *const ProfileItems) []const profiles.Profile {
        return if (self.list) |list| list.profiles else &.{};
    }

    /// Append one item per profile to `list`, or a disabled placeholder.
    /// Profile shortcuts are the `gx:new_tab_profile` and
    /// `gx:new_window_profile` key bindings.
    fn append(
        self: *ProfileItems,
        menu: *MenuPopup.Builder,
        list: *MenuPopup.List,
        hints: trigger.Hints,
        where: App.ProfileTarget,
    ) Allocator.Error!void {
        if (self.all().len == 0) {
            try menu.add(list, .{ .label = i18n.tr("No Launch Profiles"), .enabled = false });
            return;
        }
        const alloc = self.arena.allocator();
        const first: usize = switch (where) {
            .tab => tab_ids,
            .window => window_ids,
        };
        var used: MenuPopup.AccessSet = .initEmpty();
        for (self.all(), 0..) |profile, i| {
            const action: input.Binding.Action = .{ .gx = switch (where) {
                .tab => .{ .new_tab_profile = profile.id },
                .window => .{ .new_window_profile = profile.id },
            } };
            var buf: [64]u8 = undefined;
            const shortcut = hints.text(action, &buf);
            const icon = profileIcon(profile.kind);
            const access = MenuPopup.pickAccessKey(profile.name_arg orelse profile.name, used) orelse
                (if (profile.kind == .wsl) MenuPopup.pickAccessKey("WSL", used) else null);
            if (access) |key| used.set(if (key >= 'A') 10 + @as(usize, key - 'A') else key - '0');
            try menu.add(list, .{
                .id = first + i,
                .label = profiles.displayName(alloc, profile) catch profile.name,
                .icon = icon.glyph,
                .icon_text = icon.text,
                .access = access,
                .shortcut = if (self.default == i) try defaultTag(alloc, shortcut) else shortcut,
            });
        }
    }

    const Pick = struct {
        id: []const u8,
        where: App.ProfileTarget,
    };

    /// The profile and destination behind menu item `id`, if it is a
    /// profile item.
    fn pick(self: *const ProfileItems, id: usize) ?Pick {
        const all_profiles = self.all();
        if (id >= tab_ids and id - tab_ids < all_profiles.len) {
            return .{ .id = all_profiles[id - tab_ids].id, .where = .tab };
        }
        if (id >= window_ids and id - window_ids < all_profiles.len) {
            return .{ .id = all_profiles[id - window_ids].id, .where = .window };
        }
        return null;
    }
};

const ProfileIcon = struct {
    glyph: ?u21 = null,
    text: ?[]const u8 = null,
};

/// The icon of a launch profile by what it runs: WSL distributions the
/// penguin of their tabs, custom commands and herdr their own glyphs,
/// shells the command prompt.
fn profileIcon(kind: profiles.Kind) ProfileIcon {
    return switch (kind) {
        .wsl => .{ .text = wsl_emoji },
        .custom => .{ .glyph = icons.profile_custom },
        .herdr => .{ .glyph = icons.profile_herdr },
        .gx_zsh, .pwsh, .powershell, .cmd, .git_bash, .msys2, .nushell, .login_shell, .zsh, .bash, .fish => .{ .glyph = icons.profile },
    };
}

/// The right-hand text of the default profile: "Default", before its
/// shortcut if it has one.
fn defaultTag(alloc: Allocator, shortcut: ?[]const u8) Allocator.Error![]const u8 {
    const tag = i18n.tr("Default");
    const keys = shortcut orelse return tag;
    return try std.fmt.allocPrint(alloc, "{s} · {s}", .{ tag, keys });
}

// -----------------------------------------------------------------------
// Menus asked for by key bindings
// -----------------------------------------------------------------------

/// A menu a key binding asked for, opened from the message loop: a binding
/// runs inside a core callback, where a menu must not run its modal loop.
const Queued = union(enum) {
    new_tab: ui_ref.Reference,
    context: ui_ref.Reference,
};

var queued: ?Queued = null;
var queued_app: ?*App = null;
/// The thread timer that opens the queued menu (0 when none).
var queued_timer: usize = 0;

/// Open the launch profile menu of `window` for the keyboard
/// (`showNewTabMenu`) once the current message has been handled, for
/// `gx:new_tab_menu`. Safe in a core callback. Returns false when it could
/// not be queued.
pub fn queueNewTabMenu(window: *Window) bool {
    if (window.closing or window.hwnd == null) return false;
    return queue(window.app, .{ .new_tab = window.ui_reference });
}

/// Open the context menu of `surface` at its cursor
/// (`showSurfaceContextMenuAtCursor`) once the current message has been
/// handled, for `gx:context_menu`. Safe in a core callback. Returns false
/// when it could not be queued.
pub fn queueContextMenu(surface: *Surface) bool {
    return queuePaneContextMenu(Pane.fromLocal(surface));
}
pub fn queuePaneContextMenu(pane: Pane) bool {
    if (!pane.ready() or pane.nativeHandle() == null) return false;
    return queue(pane.app(), .{ .context = pane.reference() });
}

fn queue(app: *App, request: Queued) bool {
    queued = request;
    queued_app = app;
    if (queued_timer == 0) queued_timer = w32.SetTimer(null, 0, 0, @ptrCast(&openQueued));
    if (queued_timer == 0) {
        queued = null;
        return false;
    }
    return true;
}

fn openQueued(hwnd: ?w32.HWND, msg: u32, id: usize, time: u32) callconv(.winapi) void {
    _ = hwnd;
    _ = msg;
    _ = time;
    _ = w32.KillTimer(null, id);
    queued_timer = 0;
    const request = queued orelse return;
    queued = null;
    const app = queued_app orelse return;
    switch (request) {
        .new_tab => |reference| {
            const window = app.resolveWindow(reference) orelse return;
            if (!enabledWindow(window.hwnd)) return;
            showNewTabMenu(window);
        },
        .context => |reference| {
            const pane = Pane.resolve(app, reference) orelse return;
            if (!enabledWindow(pane.ownerWindow().hwnd)) return;
            showPaneContextMenuAtCursor(pane);
        },
    }
}

/// Whether `hwnd` takes input (no modal dialog disabled it).
fn enabledWindow(hwnd: ?w32.HWND) bool {
    const h = hwnd orelse return false;
    return w32.IsWindowEnabled(h) != 0;
}

// -----------------------------------------------------------------------
// Window menu
// -----------------------------------------------------------------------

/// The window menu of `window` at `screen_pt` (screen pixels), as a right
/// click on the title bar and Alt+Space open it (from the keyboard with
/// the first item highlighted): Restore, Move, Size, Minimize, Maximize
/// and Close, enabled for the window's state. The pick is posted to the
/// window (WM_SYSCOMMAND). Runs a modal loop: call it from a window
/// message. For screen readers and without Direct2D it is the native
/// system menu (`GetSystemMenu`).
pub fn showWindowMenu(window: *Window, screen_pt: w32.POINT) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing) return;
    const app = window.app;
    const attachment = window.ui_attachment;
    const zoomed = w32.IsZoomed(hwnd) != 0;
    const fullscreen = window.title_bar.is_fullscreen;
    const state: WindowState = .{ .zoomed = zoomed, .fullscreen = fullscreen };
    // Alt+Space opens it while both keys are down.
    const keyboard = w32.GetKeyState(@as(i32, w32.VK_SPACE)) < 0 and w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0;

    if (MenuPopup.preferNative() or menuHost(app) == null) return nativeWindowMenu(app, attachment, hwnd, screen_pt, state);

    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildWindowMenu(&menu, state) catch |err| {
        log.err("failed to build the window menu err={}", .{err});
        return;
    };
    const id = runMenu(app, hwnd, &menu.root, .{
        .anchor = MenuPopup.Options.at(screen_pt),
        .keyboard = keyboard,
        .owner_scale = window.scale,
    }) orelse return;
    if (!windowOpen(app, window, attachment)) return;
    _ = w32.PostMessageW(hwnd, WM_SYSCOMMAND, id, 0);
}

const WindowState = struct {
    zoomed: bool,
    fullscreen: bool,

    fn movable(self: WindowState) bool {
        return !self.zoomed and !self.fullscreen;
    }
};

fn buildWindowMenu(menu: *MenuPopup.Builder, state: WindowState) Allocator.Error!void {
    const root = &menu.root;
    try menu.add(root, .{
        .id = SC_RESTORE,
        .label = i18n.tr("Restore"),
        .icon = icons.restore,
        .access = 'R',
        .enabled = state.zoomed or state.fullscreen,
    });
    try menu.add(root, .{ .id = SC_MOVE, .label = i18n.tr("Move"), .access = 'M', .enabled = state.movable() });
    try menu.add(root, .{ .id = SC_SIZE, .label = i18n.tr("Size"), .access = 'S', .enabled = state.movable() });
    try menu.add(root, .{ .id = SC_MINIMIZE, .label = i18n.tr("Minimize"), .icon = icons.minimize, .access = 'N' });
    try menu.add(root, .{
        .id = SC_MAXIMIZE,
        .label = i18n.tr("Maximize"),
        .icon = icons.maximize,
        .access = 'X',
        .enabled = !state.zoomed,
    });
    try menu.separator(root);
    try menu.add(root, .{
        .id = SC_CLOSE,
        .label = i18n.tr("Close"),
        .icon = icons.close_window,
        .access = 'C',
        .shortcut = "Alt+F4",
    });
}

/// The system menu of `hwnd` (native), set up for its state.
fn nativeWindowMenu(app: *App, attachment: ui_ref.Attachment, hwnd: w32.HWND, screen_pt: w32.POINT, state: WindowState) void {
    const menu = GetSystemMenu(hwnd, 0) orelse return;
    setMenuItemEnabled(menu, SC_RESTORE, state.zoomed or state.fullscreen);
    setMenuItemEnabled(menu, SC_MOVE, state.movable());
    setMenuItemEnabled(menu, SC_SIZE, state.movable());
    setMenuItemEnabled(menu, SC_MINIMIZE, true);
    setMenuItemEnabled(menu, SC_MAXIMIZE, !state.zoomed);
    setMenuItemEnabled(menu, SC_CLOSE, true);
    _ = SetMenuDefaultItem(menu, std.math.maxInt(u32), 0);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_RETURNCMD | TPM_RIGHTBUTTON,
        screen_pt.x,
        screen_pt.y,
        hwnd,
        null,
    );
    const live = app.resolveWindowView(attachment) orelse return;
    if (live.hwnd != hwnd) return;
    if (cmd > 0) _ = w32.PostMessageW(hwnd, WM_SYSCOMMAND, @intCast(cmd), 0);
}

fn setMenuItemEnabled(menu: w32.HMENU, item: u32, enabled: bool) void {
    _ = EnableMenuItem(menu, item, MF_BYCOMMAND | if (enabled) MF_ENABLED else w32.MF_GRAYED);
}

/// Hook for a language change. Menus are built on demand, so the next one
/// uses the new language; a menu that is open closes.
pub fn onLanguageChanged() void {
    MenuPopup.cancel();
}

const WM_SYSCOMMAND: u32 = 0x0112;
const SC_SIZE: u32 = 0xF000;
const SC_MOVE: u32 = 0xF010;
const SC_MINIMIZE: u32 = 0xF020;
const SC_MAXIMIZE: u32 = 0xF030;
const SC_CLOSE: u32 = 0xF060;
const SC_RESTORE: u32 = 0xF120;
const TPM_RIGHTBUTTON: u32 = 0x0002;
const MF_BYCOMMAND: u32 = 0x00000000;
const MF_ENABLED: u32 = 0x00000000;

extern "user32" fn GetSystemMenu(hWnd: w32.HWND, bRevert: i32) callconv(.winapi) ?w32.HMENU;
extern "user32" fn EnableMenuItem(hMenu: w32.HMENU, uIDEnableItem: u32, uEnable: u32) callconv(.winapi) i32;
extern "user32" fn SetMenuDefaultItem(hMenu: w32.HMENU, uItem: u32, fByPos: u32) callconv(.winapi) i32;

const testing = std.testing;

test "the window menu follows the window state" {
    var menu: MenuPopup.Builder = .init(testing.allocator);
    defer menu.deinit();
    try buildWindowMenu(&menu, .{ .zoomed = true, .fullscreen = false });
    const items = menu.root.items.items;
    try testing.expectEqual(@as(usize, SC_RESTORE), items[0].id);
    try testing.expect(items[0].enabled);
    // Maximized: no move, size or maximize.
    try testing.expect(!items[1].enabled);
    try testing.expect(!items[2].enabled);
    try testing.expect(!items[4].enabled);
    try testing.expectEqual(@as(usize, SC_CLOSE), items[6].id);
    try testing.expectEqualStrings("Alt+F4", items[6].shortcut.?);

    var normal: MenuPopup.Builder = .init(testing.allocator);
    defer normal.deinit();
    try buildWindowMenu(&normal, .{ .zoomed = false, .fullscreen = false });
    try testing.expect(!normal.root.items.items[0].enabled);
    try testing.expect(normal.root.items.items[1].enabled);
    try testing.expect(normal.root.items.items[4].enabled);
}

test "the access keys of a menu are distinct and in its English labels" {
    const saved = i18n.current();
    defer i18n.setCurrent(saved);
    i18n.setCurrent(.en);

    var tab_menu: MenuPopup.Builder = .init(testing.allocator);
    defer tab_menu.deinit();
    const set: input.Binding.Set = .{};
    try buildTabMenu(&tab_menu, .{ .set = &set }, 0, 3);
    var window_menu: MenuPopup.Builder = .init(testing.allocator);
    defer window_menu.deinit();
    try buildWindowMenu(&window_menu, .{ .zoomed = false, .fullscreen = false });

    for ([_]*const MenuPopup.List{ &tab_menu.root, &window_menu.root }) |list| {
        var seen: MenuPopup.AccessSet = .initEmpty();
        for (list.items.items) |item| {
            const key = item.access orelse continue;
            const bit: usize = if (key >= 'A') 10 + key - 'A' else key - '0';
            try testing.expect(!seen.isSet(bit));
            seen.set(bit);
            try testing.expect(MenuPopup.accessIndex(item.label, key) != null);
        }
    }
}

test "cursorCell scales points to pixels and stays in the surface" {
    const rect = cursorCell(.{ .x = 25, .y = 40, .width = 0, .height = 0 }, 1.5, 10, 20, 800, 600);
    try testing.expectEqual(w32.RECT{ .left = 33, .top = 40, .right = 43, .bottom = 60 }, rect);
    const outside = cursorCell(.{ .x = 2000, .y = 2000, .width = 0, .height = 0 }, 1, 10, 20, 800, 600);
    try testing.expectEqual(w32.RECT{ .left = 790, .top = 580, .right = 800, .bottom = 600 }, outside);
}

test "profile icons tell WSL, custom commands and herdr apart" {
    try testing.expectEqualStrings(wsl_emoji, profileIcon(.wsl).text.?);
    try testing.expectEqual(@as(?u21, icons.profile_custom), profileIcon(.custom).glyph);
    try testing.expectEqual(@as(?u21, icons.profile), profileIcon(.pwsh).glyph);
}

test "profile access keys use English names in either UI language" {
    const saved = i18n.current();
    defer i18n.setCurrent(saved);
    var launch: ProfileItems = .{
        .arena = .init(testing.allocator),
        .list = .{
            .arena = .init(testing.allocator),
            .profiles = &.{
                .{ .id = "cmd", .name = "Command Prompt", .command = .{ .command_line = "cmd.exe" }, .kind = .cmd },
                .{ .id = "custom:Copy", .name = "Copy", .command = .{ .command_line = "cmd.exe" }, .kind = .custom },
                .{ .id = "wsl:Fedora", .name = "WSL: {name}", .name_arg = "Fedora", .command = .{ .command_line = "wsl.exe" }, .kind = .wsl },
            },
        },
    };
    defer launch.deinit();
    const set: input.Binding.Set = .{};
    for ([_]i18n.Language{ .en, .zh_CN }) |lang| {
        i18n.setCurrent(lang);
        var menu: MenuPopup.Builder = .init(testing.allocator);
        defer menu.deinit();
        try launch.append(&menu, &menu.root, .{ .set = &set }, .tab);
        try testing.expectEqual(@as(?u8, 'C'), menu.root.items.items[0].access);
        try testing.expectEqual(@as(?u8, 'O'), menu.root.items.items[1].access);
        try testing.expectEqual(@as(?u8, 'F'), menu.root.items.items[2].access);
        try testing.expect(MenuPopup.accessIndex(menu.root.items.items[2].label, 'F') != null);
        try testing.expectEqualStrings(i18n.tr("Command Prompt"), menu.root.items.items[0].label);
    }
}

test {
    std.testing.refAllDecls(@This());
}
