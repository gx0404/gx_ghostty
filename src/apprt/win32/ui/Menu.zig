//! Context and application menus of the win32 apprt, drawn and run by
//! `ui/MenuPopup.zig`.
//!
//! Each `show*` function builds its menu on demand and runs it modally at
//! a screen position. The context menus return what the user picked (null
//! when the menu was dismissed) and the caller performs the choice, the
//! tab bar with `performTabCommand`; the main and launch profile menus
//! perform the picked item themselves. Because menus are built on every
//! invocation they always use the current UI language (labels are English
//! msgids translated with `gx.i18n.tr`); a menu that is open while the
//! language switches closes (`onLanguageChanged`).
//!
//! A menu runs a modal loop that keeps dispatching messages, so call it
//! from a window message (e.g. a click), never from a core callback; key
//! bindings go through `Window.queueMainMenu`. One menu is open at a time.
//! A menu whose owner window or terminal went away while it was open
//! returns null, and the main and profile menus perform the pick only
//! while their window is still open.
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
};

/// What the menus draw with: the app's Direct2D factory and the colors of
/// the current theme. Null when Direct2D is unavailable.
fn menuHost(app: *App) ?MenuPopup.Host {
    const factory = app.uiFactory() orelse return null;
    return .{
        .hinstance = app.hinstance,
        .factory = factory,
        .tokens = style.Tokens.fromConfig(&app.config),
    };
}

const SurfaceItem = enum(usize) {
    copy = 1,
    paste,
    select_all,
    split_right,
    split_down,
    split_left,
    split_up,
    search,
    clear_screen,
    reset,
    open_pwd,
    settings,
};

/// The right-click menu of a terminal surface: clipboard, splits, search,
/// clear and reset, the working directory in File Explorer (when the shell
/// reported it with OSC 7) and the settings. Opens at `screen_pt` and
/// returns the binding action to perform on the surface. Opening the
/// working directory needs no terminal, so the menu does it itself.
pub fn showSurfaceContextMenu(surface: *Surface, screen_pt: w32.POINT) ?input.Binding.Action {
    const owner = surface.hwnd orelse return null;
    if (!surface.core_surface_ready) return null;
    const app = surface.app;
    const host = menuHost(app) orelse return null;
    const alloc = app.core_app.alloc;

    var menu: MenuPopup.Builder = .init(alloc);
    defer menu.deinit();
    // In the menu's arena the directory outlives the terminal.
    const pwd = workingDirectory(surface, menu.arena.allocator());
    buildSurfaceMenu(
        &menu,
        &app.config,
        surface.core_surface.hasSelection(),
        pwd != null,
    ) catch |err| {
        log.err("failed to build the terminal menu err={}", .{err});
        return null;
    };

    const id = MenuPopup.run(host, owner, &menu.root, .{ .anchor = screen_pt }) orelse return null;
    return switch (std.enums.fromInt(SurfaceItem, id) orelse return null) {
        .copy => .{ .copy_to_clipboard = .mixed },
        .paste => .paste_from_clipboard,
        .select_all => .select_all,
        .split_right => .{ .new_split = .right },
        .split_down => .{ .new_split = .down },
        .split_left => .{ .new_split = .left },
        .split_up => .{ .new_split = .up },
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

fn buildSurfaceMenu(
    menu: *MenuPopup.Builder,
    config: *const configpkg.Config,
    has_selection: bool,
    has_pwd: bool,
) Allocator.Error!void {
    const set = &config.keybind.set;
    const root = &menu.root;
    var buf: [64]u8 = undefined;
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.copy),
        .label = i18n.tr("Copy"),
        .icon = icons.copy,
        .shortcut = trigger.formatAction(set, .{ .copy_to_clipboard = .mixed }, &buf),
        .enabled = has_selection,
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.paste),
        .label = i18n.tr("Paste"),
        .icon = icons.paste,
        .shortcut = trigger.formatAction(set, .paste_from_clipboard, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.select_all),
        .label = i18n.tr("Select All"),
        .icon = icons.select_all,
        .shortcut = trigger.formatAction(set, .select_all, &buf),
    });
    try menu.separator(root);
    try addSplitMenu(menu, root, set, @intFromEnum(SurfaceItem.split_right));
    try menu.separator(root);
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.search),
        .label = i18n.tr("Search"),
        .icon = icons.search,
        .shortcut = trigger.formatAction(set, .start_search, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.clear_screen),
        .label = i18n.tr("Clear Screen"),
        .icon = icons.clear,
        .shortcut = trigger.formatAction(set, .clear_screen, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.reset),
        .label = i18n.tr("Reset Terminal"),
        .icon = icons.reset,
        .shortcut = trigger.formatAction(set, .reset, &buf),
    });
    try menu.separator(root);
    if (has_pwd) try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.open_pwd),
        .label = i18n.tr("Open Current Directory in File Explorer"),
        .icon = icons.folder,
    });
    try menu.add(root, .{
        .id = @intFromEnum(SurfaceItem.settings),
        .label = i18n.tr("Settings…"),
        .icon = icons.settings,
        .shortcut = settingsShortcut(config, &buf),
    });
}

/// The shortcut of the settings: `gx:settings`, else `open_config` while
/// it opens the settings (`gx-open-config-ui = settings`).
fn settingsShortcut(config: *const configpkg.Config, buf: []u8) ?[]const u8 {
    const set = &config.keybind.set;
    if (trigger.formatAction(set, .{ .gx = .settings }, buf)) |text| return text;
    if (config.@"gx-open-config-ui" != .settings) return null;
    return trigger.formatAction(set, .{ .open_config = .os_open }, buf);
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
/// `first + 1` (down), `first + 2` (left) and `first + 3` (up).
fn addSplitMenu(
    menu: *MenuPopup.Builder,
    list: *MenuPopup.List,
    set: *const input.Binding.Set,
    first: usize,
) Allocator.Error!void {
    const split = try menu.submenu(list, .{ .label = i18n.tr("Split"), .icon = icons.split });
    const directions = [_]input.Binding.Action.SplitDirection{ .right, .down, .left, .up };
    const labels = [_][:0]const u8{
        i18n.tr("Split Right"),
        i18n.tr("Split Down"),
        i18n.tr("Split Left"),
        i18n.tr("Split Up"),
    };
    const glyphs = [_]u21{ icons.split_right, icons.split_down, icons.split_left, icons.split_up };
    var buf: [64]u8 = undefined;
    for (directions, labels, glyphs, 0..) |direction, label, glyph, i| {
        try menu.add(split, .{
            .id = first + i,
            .label = label,
            .icon = glyph,
            .shortcut = trigger.formatAction(set, .{ .new_split = direction }, &buf),
        });
    }
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
    const host = menuHost(app) orelse return null;

    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildTabMenu(&menu, &app.config.keybind.set, tab, window.tab_count) catch |err| {
        log.err("failed to build the tab menu err={}", .{err});
        return null;
    };

    const id = MenuPopup.run(host, owner, &menu.root, .{ .anchor = screen_pt }) orelse return null;
    return std.enums.fromInt(TabCommand, id);
}

fn buildTabMenu(
    menu: *MenuPopup.Builder,
    set: *const input.Binding.Set,
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
            .shortcut = trigger.formatAction(set, .prompt_tab_title, &buf),
        });
        try menu.separator(root);
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.close),
            .label = i18n.tr("Close Tab"),
            .icon = icons.close,
            .shortcut = trigger.formatAction(set, .{ .close_tab = .this }, &buf),
        });
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.close_others),
            .label = i18n.tr("Close Other Tabs"),
            .shortcut = trigger.formatAction(set, .{ .close_tab = .other }, &buf),
            .enabled = tab_count > 1,
        });
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.close_right),
            .label = i18n.tr("Close Tabs to the Right"),
            .shortcut = trigger.formatAction(set, .{ .close_tab = .right }, &buf),
            .enabled = index + 1 < tab_count,
        });
        try menu.separator(root);
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.move_to_new_window),
            .label = i18n.tr("Move Tab to New Window"),
            .icon = icons.move_to_window,
            .shortcut = trigger.formatAction(set, .move_tab_to_new_window, &buf),
            .enabled = tab_count > 1,
        });
        try menu.add(root, .{
            .id = @intFromEnum(TabCommand.duplicate),
            .label = i18n.tr("Duplicate Tab"),
            .icon = icons.duplicate,
        });
        try menu.separator(root);
    }
    try menu.add(root, .{
        .id = @intFromEnum(TabCommand.new_tab),
        .label = i18n.tr("New Tab"),
        .icon = icons.new_tab,
        .shortcut = trigger.formatAction(set, .new_tab, &buf),
    });
}

/// Perform a pick of the tab context menu for the tab at index `tab`.
pub fn performTabCommand(window: *Window, tab: ?usize, command: TabCommand) void {
    if (command == .new_tab) {
        _ = window.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }
    // Tabs can close while the menu is open.
    const index = tab orelse return;
    if (index >= window.tab_count) return;
    switch (command) {
        .rename => window.tab_bar.startRename(index),
        .close => window.closeTabByIndex(index),
        .close_others => window.closeOtherTabs(index),
        .close_right => window.closeTabsRightOf(index),
        .move_to_new_window => _ = window.moveTabToNewWindow(window.tab_active_surface[index]) catch |err| failed: {
            log.err("failed to move the tab to a new window err={}", .{err});
            break :failed false;
        },
        .duplicate => duplicateTab(window, index),
        .new_tab => unreachable,
    }
}

/// Open a new tab that runs the command of the focused terminal of tab
/// `index` (its launch profile, if it was opened with one). Selecting the
/// tab first makes the new tab inherit that terminal's working directory
/// (`tab-inherit-working-directory`) and, with the default
/// `window-new-tab-position = current`, open next to it.
fn duplicateTab(window: *Window, index: usize) void {
    const surface = window.tab_active_surface[index];
    window.selectTabIndex(index);
    _ = window.addTabWithOptions(.{
        .context = .tab,
        .command = if (surface.launch_command) |*command| command else null,
    }) catch |err| {
        log.err("failed to duplicate the tab err={}", .{err});
        return;
    };
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

/// The application menu (`gx:main_menu`): new tabs and windows, a launch
/// profile submenu, splits, the command palette, settings, keyboard
/// shortcuts, the UI language, the configuration, About and Quit. Opens at
/// `anchor` (screen coordinates; null: below the chrome at the window's
/// left edge, with the first item highlighted for the keyboard) and
/// performs the picked item for `window`. Runs a modal loop, so call it
/// from a window message (e.g. a button click), never from a core
/// callback; key bindings go through `Window.queueMainMenu`.
pub fn showMainMenu(window: *Window, anchor: ?w32.POINT) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing) return;
    const app = window.app;
    const host = menuHost(app) orelse return;

    var launch: ProfileItems = .init(app);
    defer launch.deinit();
    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildMainMenu(&menu, app, &launch) catch |err| {
        log.err("failed to build the main menu err={}", .{err});
        return;
    };

    const screen_pt = anchor orelse below_chrome: {
        var origin: w32.POINT = .{ .x = 0, .y = window.chromeHeight() };
        _ = w32.ClientToScreen(hwnd, &origin);
        break :below_chrome origin;
    };
    const id = MenuPopup.run(host, hwnd, &menu.root, .{
        .anchor = screen_pt,
        .select_first = anchor == null,
    }) orelse return;
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
    const set = &app.config.keybind.set;
    const root = &menu.root;
    var buf: [64]u8 = undefined;

    try menu.add(root, .{
        .id = @intFromEnum(MainItem.new_tab),
        .label = i18n.tr("New Tab"),
        .icon = icons.new_tab,
        .shortcut = trigger.formatAction(set, .new_tab, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.new_window),
        .label = i18n.tr("New Window"),
        .icon = icons.new_window,
        .shortcut = trigger.formatAction(set, .new_window, &buf),
    });
    const profile_menu = try menu.submenu(root, .{ .label = i18n.tr("New Tab with Profile"), .icon = icons.profile });
    try launch.append(menu, profile_menu, set, .tab);
    try addSplitMenu(menu, root, set, @intFromEnum(MainItem.split_right));
    try menu.separator(root);

    try menu.add(root, .{
        .id = @intFromEnum(MainItem.command_palette),
        .label = i18n.tr("Command Palette"),
        .icon = icons.command_palette,
        .shortcut = trigger.formatAction(set, .toggle_command_palette, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.settings),
        .label = i18n.tr("Settings…"),
        .icon = icons.settings,
        .shortcut = settingsShortcut(&app.config, &buf),
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.keybinds),
        .label = i18n.tr("Keyboard Shortcuts"),
        .icon = icons.keyboard,
        .shortcut = trigger.formatAction(set, .{ .gx = .keybinds }, &buf),
    });
    const languages = try menu.submenu(root, .{ .label = i18n.tr("Language"), .icon = icons.language });
    for (std.enums.values(i18n.Language)) |lang| {
        try menu.add(languages, .{
            .id = language_ids + @intFromEnum(lang),
            .label = lang.nativeName(),
            .mark = if (lang == i18n.current()) .radio else .none,
        });
    }
    try menu.separator(root);

    try menu.add(root, .{
        .id = @intFromEnum(MainItem.reload_config),
        .label = i18n.tr("Reload Configuration"),
        .icon = icons.reload,
        .shortcut = trigger.formatAction(set, .reload_config, &buf),
    });
    // `open_config` opens the settings with `gx-open-config-ui = settings`.
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.open_config_file),
        .label = i18n.tr("Open Configuration File"),
        .icon = icons.open_file,
        .shortcut = if (app.config.@"gx-open-config-ui" == .settings)
            null
        else
            trigger.formatAction(set, .{ .open_config = .os_open }, &buf),
    });
    try menu.separator(root);
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.about),
        .label = i18n.tr("About Ghostty GX"),
        .icon = icons.about,
    });
    try menu.add(root, .{
        .id = @intFromEnum(MainItem.quit),
        .label = i18n.tr("Quit"),
        .icon = icons.quit,
        .shortcut = trigger.formatAction(set, .quit, &buf),
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

/// Id of the profile menu's Set Default Shell… item.
const default_shell_id: usize = 1;

/// The launch profile menu of the new-tab button: the launch profiles,
/// the default one tagged, each opening in a new tab of `window`; a
/// submenu opening them in a new window; and Set Default Shell…, which
/// opens the settings. Opens at `anchor` (screen coordinates). Same
/// calling rules as `showMainMenu`.
pub fn showProfileMenu(window: *Window, anchor: w32.POINT) void {
    const hwnd = window.hwnd orelse return;
    if (window.closing) return;
    const app = window.app;
    const host = menuHost(app) orelse return;

    var launch: ProfileItems = .init(app);
    defer launch.deinit();
    var menu: MenuPopup.Builder = .init(app.core_app.alloc);
    defer menu.deinit();
    buildProfileMenu(&menu, &app.config.keybind.set, &launch) catch |err| {
        log.err("failed to build the profile menu err={}", .{err});
        return;
    };

    const id = MenuPopup.run(host, hwnd, &menu.root, .{ .anchor = anchor }) orelse return;
    if (!windowOpen(app, window)) return;
    if (launch.pick(id)) |pick| {
        _ = app.openProfile(window, pick.id, pick.where);
    } else if (id == default_shell_id) {
        _ = Settings.show(window);
    }
}

fn buildProfileMenu(
    menu: *MenuPopup.Builder,
    set: *const input.Binding.Set,
    launch: *ProfileItems,
) Allocator.Error!void {
    const root = &menu.root;
    try menu.header(root, i18n.tr("New Tab"));
    try launch.append(menu, root, set, .tab);
    try menu.separator(root);
    const window_menu = try menu.submenu(root, .{ .label = i18n.tr("New Window with Profile"), .icon = icons.new_window });
    try launch.append(menu, window_menu, set, .window);
    try menu.separator(root);
    try menu.add(root, .{
        .id = default_shell_id,
        .label = i18n.tr("Set Default Shell…"),
        .icon = icons.settings,
    });
}

/// The launch profiles (`App.launchProfiles`) as menu items. Items with
/// ids from `tab_ids` open a profile in a new tab, from `window_ids` in a
/// new window.
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
            .list = app.launchProfiles() catch |err| null: {
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
        set: *const input.Binding.Set,
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
        for (self.all(), 0..) |profile, i| {
            const action: input.Binding.Action = .{ .gx = switch (where) {
                .tab => .{ .new_tab_profile = profile.id },
                .window => .{ .new_window_profile = profile.id },
            } };
            var buf: [64]u8 = undefined;
            const shortcut = trigger.formatAction(set, action, &buf);
            try menu.add(list, .{
                .id = first + i,
                .label = profiles.displayName(alloc, profile) catch profile.name,
                .icon = icons.profile,
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

/// The right-hand text of the default profile: "Default", before its
/// shortcut if it has one.
fn defaultTag(alloc: Allocator, shortcut: ?[]const u8) Allocator.Error![]const u8 {
    const tag = i18n.tr("Default");
    const keys = shortcut orelse return tag;
    return try std.fmt.allocPrint(alloc, "{s} · {s}", .{ tag, keys });
}

/// Hook for a language change. Menus are built on demand, so the next one
/// uses the new language; a menu that is open closes.
pub fn onLanguageChanged() void {
    MenuPopup.cancel();
}
