//! Context and application menus of the win32 apprt.
//!
//! Each `show*` function builds its menu on demand and runs it modally at
//! a screen position. The context menus return what the user picked (null
//! when the menu was dismissed) and the caller performs the choice; the
//! main menu performs its items itself. Because menus are built on every
//! invocation they always use the current UI language (labels are English
//! msgids translated with `gx.i18n.tr`).
//!
//! The implementation is TrackPopupMenuEx today; a custom popup menu can
//! replace it behind the same functions.
const std = @import("std");
const build_config = @import("../../../build_config.zig");
const input = @import("../../../input.zig");
const i18n = @import("../../../gx/i18n.zig");
const profiles = @import("../../../gx/profiles.zig");
const w32 = @import("../win32.zig");
const Window = @import("../Window.zig");
const Dialogs = @import("Dialogs.zig");
const trigger = @import("trigger.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);

/// The right-click menu of a terminal surface. Returns the binding action
/// to perform on that surface.
pub fn showSurfaceContextMenu(
    owner: w32.HWND,
    screen_pt: w32.POINT,
    has_selection: bool,
) ?input.Binding.Action {
    const Item = enum(usize) {
        copy = 1,
        paste,
        select_all,
        split_right,
        split_down,
        reset,
    };

    var menu = Builder.init() orelse return null;
    defer menu.deinit();
    menu.item(@intFromEnum(Item.copy), i18n.tr("Copy"), has_selection);
    menu.item(@intFromEnum(Item.paste), i18n.tr("Paste"), true);
    menu.separator();
    menu.item(@intFromEnum(Item.select_all), i18n.tr("Select All"), true);
    menu.separator();
    menu.item(@intFromEnum(Item.split_right), i18n.tr("Split Right"), true);
    menu.item(@intFromEnum(Item.split_down), i18n.tr("Split Down"), true);
    menu.separator();
    menu.item(@intFromEnum(Item.reset), i18n.tr("Reset Terminal"), true);

    const id = menu.track(owner, screen_pt) orelse return null;
    const item = std.enums.fromInt(Item, id) orelse return null;
    return switch (item) {
        .copy => .{ .copy_to_clipboard = .mixed },
        .paste => .paste_from_clipboard,
        .select_all => .select_all,
        .split_right => .{ .new_split = .right },
        .split_down => .{ .new_split = .down },
        .reset => .reset,
    };
}

/// What the tab context menu asks the window to do.
pub const TabCommand = enum(usize) {
    close = 9001,
    close_others,
    close_right,
    new_tab,
};

pub const TabMenuContext = struct {
    /// The right-clicked tab, or null for the empty part of the tab bar
    /// (which only offers New Tab).
    tab: ?usize,
    tab_count: usize,
};

/// The right-click menu of the tab bar.
pub fn showTabContextMenu(
    owner: w32.HWND,
    screen_pt: w32.POINT,
    context: TabMenuContext,
) ?TabCommand {
    var menu = Builder.init() orelse return null;
    defer menu.deinit();
    if (context.tab) |tab| {
        menu.item(@intFromEnum(TabCommand.close), i18n.tr("Close Tab"), true);
        menu.item(@intFromEnum(TabCommand.close_others), i18n.tr("Close Other Tabs"), context.tab_count > 1);
        menu.item(@intFromEnum(TabCommand.close_right), i18n.tr("Close Tabs to the Right"), tab + 1 < context.tab_count);
        menu.separator();
    }
    menu.item(@intFromEnum(TabCommand.new_tab), i18n.tr("New Tab"), true);

    const id = menu.track(owner, screen_pt) orelse return null;
    return std.enums.fromInt(TabCommand, id);
}

/// The application menu (`gx:main_menu`): new tabs and windows, a launch
/// profile submenu, settings, keyboard shortcuts, the command palette, the
/// configuration, About and Quit. Opens at `anchor` (screen coordinates;
/// null: below the chrome at the window's left edge) and performs the
/// picked item for `window`. Runs a modal loop, so call it from a window
/// message (e.g. a button click), never from a core callback; key
/// bindings go through `Window.queueMainMenu`.
pub fn showMainMenu(window: *Window, anchor: ?w32.POINT) void {
    const hwnd = window.hwnd orelse return;
    const app = window.app;
    const set = &app.config.keybind.set;

    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    var launch: ?profiles.List = app.launchProfiles() catch |err| null: {
        log.warn("launch profile detection failed err={}", .{err});
        break :null null;
    };
    defer if (launch) |*list| list.deinit();
    const profile_list: []const profiles.Profile = if (launch) |list| list.profiles else &.{};

    var menu = Builder.init() orelse return;
    defer menu.deinit();

    var hint_buf: [64]u8 = undefined;
    menu.itemHint(@intFromEnum(MainItem.new_tab), i18n.tr("New Tab"), trigger.formatAction(set, .new_tab, &hint_buf));
    menu.itemHint(@intFromEnum(MainItem.new_window), i18n.tr("New Window"), trigger.formatAction(set, .new_window, &hint_buf));
    if (Builder.init()) |submenu_| {
        var submenu = submenu_;
        if (profile_list.len == 0) submenu.item(0, i18n.tr("No Launch Profiles"), false);
        for (profile_list, 0..) |profile, i| {
            const name = profiles.displayName(arena.allocator(), profile) catch profile.name;
            submenu.item(main_menu_profile_first + i, name, true);
        }
        menu.submenu(submenu, i18n.tr("New Tab with Profile"));
    }
    menu.separator();

    // With `gx-open-config-ui = settings`, `open_config` opens the settings.
    const settings_ui = app.config.@"gx-open-config-ui" == .settings;
    const open_config: input.Binding.Action = .{ .open_config = .os_open };
    menu.itemHint(@intFromEnum(MainItem.settings), i18n.tr("Settings…"), trigger.formatAction(set, .{ .gx = .settings }, &hint_buf) orelse
        if (settings_ui) trigger.formatAction(set, open_config, &hint_buf) else null);
    menu.itemHint(@intFromEnum(MainItem.keybinds), i18n.tr("Keyboard Shortcuts"), trigger.formatAction(set, .{ .gx = .keybinds }, &hint_buf));
    menu.itemHint(@intFromEnum(MainItem.command_palette), i18n.tr("Command Palette"), trigger.formatAction(set, .toggle_command_palette, &hint_buf));
    menu.separator();
    menu.itemHint(@intFromEnum(MainItem.reload_config), i18n.tr("Reload Configuration"), trigger.formatAction(set, .reload_config, &hint_buf));
    menu.itemHint(@intFromEnum(MainItem.open_config_file), i18n.tr("Open Configuration File"), if (settings_ui) null else trigger.formatAction(set, open_config, &hint_buf));
    menu.separator();
    menu.item(@intFromEnum(MainItem.about), i18n.tr("About Ghostty GX"), true);
    menu.itemHint(@intFromEnum(MainItem.quit), i18n.tr("Quit"), trigger.formatAction(set, .quit, &hint_buf));

    const screen_pt = anchor orelse below_chrome: {
        var origin: w32.POINT = .{ .x = 0, .y = window.chromeHeight() };
        _ = w32.ClientToScreen(hwnd, &origin);
        break :below_chrome origin;
    };
    const id = menu.track(hwnd, screen_pt) orelse return;

    if (id >= main_menu_profile_first and id - main_menu_profile_first < profile_list.len) {
        _ = app.openProfile(window, profile_list[id - main_menu_profile_first].id, .tab);
        return;
    }
    switch (std.enums.fromInt(MainItem, id) orelse return) {
        .new_tab => window.performBindingAction(.new_tab),
        .new_window => window.performBindingAction(.new_window),
        .settings => _ = app.performGx(window, .settings),
        .keybinds => _ = app.performGx(window, .keybinds),
        .command_palette => window.performBindingAction(.toggle_command_palette),
        .reload_config => window.performBindingAction(.reload_config),
        .open_config_file => _ = app.openConfigFile(.os_open) catch |err| failed: {
            log.err("failed to open the configuration file err={}", .{err});
            break :failed false;
        },
        .about => Dialogs.showAbout(hwnd, build_config.version_string),
        .quit => window.performBindingAction(.quit),
    }
}

const MainItem = enum(usize) {
    new_tab = 1,
    new_window,
    settings,
    keybinds,
    command_palette,
    reload_config,
    open_config_file,
    about,
    quit,
};

/// Command id of the first launch profile in the main menu.
const main_menu_profile_first: usize = 0x1000;

/// Hook for a language change. Menus are built on demand, so there is
/// nothing cached to rebuild.
pub fn onLanguageChanged() void {}

/// A Win32 popup menu under construction.
const Builder = struct {
    menu: w32.HMENU,

    fn init() ?Builder {
        return .{ .menu = w32.CreatePopupMenu() orelse return null };
    }

    fn deinit(self: *Builder) void {
        _ = w32.DestroyMenu(self.menu);
    }

    fn item(self: *Builder, id: usize, label: []const u8, enabled: bool) void {
        var buf: [256]u16 = undefined;
        _ = w32.AppendMenuW(
            self.menu,
            if (enabled) w32.MF_STRING else w32.MF_GRAYED,
            id,
            wstr.bufZ(&buf, label),
        );
    }

    /// An item with a right-aligned shortcut hint (`label\thint`).
    fn itemHint(self: *Builder, id: usize, label: []const u8, hint: ?[]const u8) void {
        var buf: [256]u8 = undefined;
        const text = if (hint) |h|
            std.fmt.bufPrint(&buf, "{s}\t{s}", .{ label, h }) catch label
        else
            label;
        self.item(id, text, true);
    }

    /// Append `child` as a submenu; this menu owns it from then on.
    fn submenu(self: *Builder, child: Builder, label: []const u8) void {
        var buf: [256]u16 = undefined;
        if (w32.AppendMenuW(
            self.menu,
            w32.MF_STRING | w32.MF_POPUP,
            @intFromPtr(child.menu),
            wstr.bufZ(&buf, label),
        ) == 0) {
            var orphan = child;
            orphan.deinit();
        }
    }

    fn separator(self: *Builder) void {
        _ = w32.AppendMenuW(self.menu, w32.MF_SEPARATOR, 0, null);
    }

    /// Run the menu modally; returns the picked command id.
    fn track(self: *Builder, owner: w32.HWND, screen_pt: w32.POINT) ?usize {
        const cmd = w32.TrackPopupMenuEx(
            self.menu,
            w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
            screen_pt.x,
            screen_pt.y,
            owner,
            null,
        );
        if (cmd <= 0) return null;
        return @intCast(cmd);
    }
};
