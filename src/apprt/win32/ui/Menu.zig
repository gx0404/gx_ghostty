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
const Window = @import("../Window.zig");
const Dialogs = @import("Dialogs.zig");
const MenuPopup = @import("MenuPopup.zig");
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
    return surfaceMenu(surface, .{ .anchor = MenuPopup.Options.at(screen_pt) });
}

fn surfaceMenu(surface: *Surface, placement: MenuPopup.Options) ?input.Binding.Action {
    const owner = surface.hwnd orelse return null;
    if (!surface.core_surface_ready) return null;
    const app = surface.app;
    const window = surface.parent_window;
    const alloc = app.core_app.alloc;

    var menu: MenuPopup.Builder = .init(alloc);
    defer menu.deinit();
    // In the menu's arena the directory outlives the terminal.
    const pwd = workingDirectory(surface, menu.arena.allocator());
    const tab = window.findTabIndex(surface);
    const split = if (tab) |i| window.tab_trees[i].isSplit() else false;
    buildSurfaceMenu(&menu, &app.config, hintsOf(app), .{
        .selection = surface.core_surface.hasSelection(),
        .clipboard_text = w32.IsClipboardFormatAvailable(w32.CF_UNICODETEXT) != 0,
        .split = split,
        .zoomed = if (tab) |i| window.tab_trees[i].zoomed != null else false,
        .other_tabs = window.tab_count > 1,
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
            if (pwd) |path| openFolder(alloc, owner, path);
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
fn workingDirectory(surface: *Surface, alloc: Allocator) ?[]const u8 {
    const path = (surface.core_surface.pwd(alloc) catch return null) orelse return null;
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
    const hwnd = surface.hwnd orelse return;
    if (!surface.core_surface_ready) return;
    const app = surface.app;
    const id = surface.core_surface.id;
    const cell = cursorCell(
        surface.core_surface.imePoint(),
        surface.scale,
        surface.core_surface.size.cell.width,
        surface.core_surface.size.cell.height,
        surface.width,
        surface.height,
    );
    const binding = surfaceMenu(surface, .{
        .anchor = screenRect(hwnd, cell),
        .keyboard = true,
    }) orelse return;
    const live = findSurface(app, id) orelse return;
    if (!live.core_surface_ready) return;
    _ = live.core_surface.performBindingAction(binding) catch |err| {
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

/// Perform a pick of the tab context menu for the tab holding the terminals
/// with core surface ids `tab` (null: the empty part of the tab bar). The
/// menu ran a modal loop, so the tab is found again by any of those ids
/// (its focused split can close meanwhile); nothing happens when all of
/// them closed.
pub fn performTabCommand(window: *Window, tab: ?[]const u64, command: TabCommand) void {
    if (command == .new_tab) {
        _ = window.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }
    const index = for (tab orelse return) |id| {
        if (window.findTabBySurfaceId(id)) |i| break i;
    } else return;
    switch (command) {
        .rename => window.tab_bar.startRename(index),
        .close => window.closeTabByIndex(index),
        .close_others => window.closeOtherTabs(index),
        .close_right => window.closeTabsRightOf(index),
        .move_to_new_window => _ = window.moveTabToNewWindow(window.tab_active_surface[index]) catch |err| failed: {
            log.err("failed to move the tab to a new window err={}", .{err});
            break :failed false;
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
    var ids: [Window.MAX_TABS]u64 = undefined;
    const count = window.tab_count;
    for (0..count) |i| {
        ids[i] = window.tab_active_surface[i].core_surface.id;
        var title_buf: [768]u8 = undefined;
        var label_buf: [64]u8 = undefined;
        const title = wstr.utf8Buf(&title_buf, window.tab_titles[i][0..window.tab_title_lens[i]]);
        const label = if (std.mem.trim(u8, title, " ").len > 0)
            title
        else
            std.fmt.bufPrint(&label_buf, "{s} {d}", .{ i18n.tr("Tab"), i + 1 }) catch i18n.tr("Tab");
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
    if (!windowOpen(app, window) or id == 0 or id > count) return;
    if (window.findTabBySurfaceId(ids[id - 1])) |index| window.selectTabIndex(index);
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
    openMainMenu(window, .{ .anchor = rect, .alignment = alignment });
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
    if (anchor) |pt| return openMainMenu(window, .{ .anchor = MenuPopup.Options.at(pt) });
    openMainMenu(window, .{ .anchor = menuButtonAnchor(window), .alignment = .right, .keyboard = true });
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

fn openMainMenu(window: *Window, placement: MenuPopup.Options) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing) return;
    const app = window.app;
    const prepare = if (gx.perf.enabled()) gx.perf.Span.begin(global.io()) else null;

    var launch: ProfileItems = .init(app);
    defer launch.deinit();
    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildMainMenu(&menu, app, &launch) catch |err| {
        log.err("failed to build the main menu err={}", .{err});
        return;
    };
    if (prepare) |span| _ = span.end(global.io(), "menu.prepare");

    var options = placement;
    options.owner_scale = window.scale;
    const id = runMenu(app, hwnd, &menu.root, options) orelse return;
    if (!windowOpen(app, window)) return;

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

/// Whether `window` is still one of the app's open windows.
fn windowOpen(app: *App, window: *Window) bool {
    for (app.windows.items) |open| {
        if (open == window) return !window.closing;
    }
    if (app.quick_terminal) |qt| {
        if (qt.window == window) return !window.closing;
    }
    return false;
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
    if (!windowOpen(app, window)) return;
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
            const access = MenuPopup.pickAccessKey(profile.name, used);
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
    new_tab: *Window,
    /// The core surface id of the terminal.
    context: u64,
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
    return queue(window.app, .{ .new_tab = window });
}

/// Open the context menu of `surface` at its cursor
/// (`showSurfaceContextMenuAtCursor`) once the current message has been
/// handled, for `gx:context_menu`. Safe in a core callback. Returns false
/// when it could not be queued.
pub fn queueContextMenu(surface: *Surface) bool {
    if (!surface.core_surface_ready or surface.hwnd == null) return false;
    return queue(surface.app, .{ .context = surface.core_surface.id });
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
        .new_tab => |window| {
            if (!windowOpen(app, window) or !enabledWindow(window.hwnd)) return;
            showNewTabMenu(window);
        },
        .context => |surface_id| {
            const surface = findSurface(app, surface_id) orelse return;
            if (!enabledWindow(surface.parent_window.hwnd)) return;
            showSurfaceContextMenuAtCursor(surface);
        },
    }
}

/// Whether `hwnd` takes input (no modal dialog disabled it).
fn enabledWindow(hwnd: ?w32.HWND) bool {
    const h = hwnd orelse return false;
    return w32.IsWindowEnabled(h) != 0;
}

/// The terminal with core surface id `id` in one of the app's windows.
fn findSurface(app: *App, id: u64) ?*Surface {
    for (app.windows.items) |window| {
        if (findSurfaceIn(window, id)) |surface| return surface;
    }
    if (app.quick_terminal) |qt| return findSurfaceIn(qt.window, id);
    return null;
}

fn findSurfaceIn(window: *Window, id: u64) ?*Surface {
    if (window.closing) return null;
    const tab = window.findTabBySurfaceId(id) orelse return null;
    var it = window.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        if (entry.view.core_surface.id == id) return entry.view;
    }
    return null;
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
    const zoomed = w32.IsZoomed(hwnd) != 0;
    const fullscreen = window.title_bar.is_fullscreen;
    const state: WindowState = .{ .zoomed = zoomed, .fullscreen = fullscreen };
    // Alt+Space opens it while both keys are down.
    const keyboard = w32.GetKeyState(@as(i32, w32.VK_SPACE)) < 0 and w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0;

    if (MenuPopup.preferNative() or menuHost(app) == null) return nativeWindowMenu(hwnd, screen_pt, state);

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
    if (!windowOpen(app, window)) return;
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
fn nativeWindowMenu(hwnd: w32.HWND, screen_pt: w32.POINT, state: WindowState) void {
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
        try testing.expectEqualStrings(i18n.tr("Command Prompt"), menu.root.items.items[0].label);
    }
}

test {
    std.testing.refAllDecls(@This());
}
