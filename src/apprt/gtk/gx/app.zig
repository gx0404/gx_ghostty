//! Ghostty GX additions to `class/application.zig::Application`: the
//! `app.gx-language`, `app.gx-keybinds`, `app.gx-about`,
//! `app.gx-settings-page` and `app.gx-open-config-file` actions, following
//! `language` changes at runtime, and the GTK side of the Ghostty GX
//! binding actions (`gx:<name>[:<arg>]`, dispatched by the core through
//! `App.gxAction`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const ext = @import("../ext.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const GxSettingsDialog = @import("settings_dialog.zig").GxSettingsDialog;
const about = @import("about.zig");
const language = @import("language.zig");
const launch = @import("launch.zig");
const shortcuts_dialog = @import("shortcuts_dialog.zig");
const gx_window = @import("window.zig");

const log = std.log.scoped(.gtk_gx_app);

/// The object data key on the application while a configuration reload
/// for a language switch is queued.
const reload_key = "gx-language-reload";

/// Registers the Ghostty GX app actions: `app.gx-language` (stateful, the
/// `language` configuration value, written to `gui-settings.ghostty`),
/// `app.gx-keybinds` (the keyboard shortcuts cheat sheet), `app.gx-about`
/// (the Ghostty GX About dialog), `app.gx-settings-page` (the settings at
/// a page, a `gx.action.SettingsPage` name) and `app.gx-open-config-file`
/// (the configuration file in the system editor, whatever
/// `gx-open-config-ui` says). Called from `Application.startup`.
pub fn startup(app: *Application) void {
    const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
    defer s_variant_type.free();

    const actions = [_]ext.actions.Action(Application){
        .initStateful(
            "gx-language",
            actionLanguage,
            s_variant_type,
            glib.Variant.newString(gx.i18n.current().configValue()),
        ),
        .init("gx-keybinds", actionKeybinds, null),
        .init("gx-about", actionAbout, null),
        .init("gx-settings-page", actionSettingsPage, s_variant_type),
        .init("gx-open-config-file", actionOpenConfigFile, null),
    };
    ext.actions.add(Application, app, &actions);
}

/// Follows the `language` of the application configuration. Called from
/// `Application.propConfig`, which runs before the windows see the new
/// configuration and rebuild their menus.
pub fn configChanged(app: *Application) void {
    const config = app.getConfig();
    defer config.unref();
    const lang = gx.i18n.resolve(config.get().language);
    if (lang != gx.i18n.current() and language.switchTo(lang)) reloadLater(app);
    setLanguageState(app, lang);
}

/// Handles a Ghostty GX binding action for `target`. `action` is a
/// `gx.action.Action`; see `request`. Returns false when the action is
/// not handled, so that `performable:` bindings pass their key on.
pub fn performGxAction(app: *Application, target: apprt.Target, action: anytype) bool {
    return switch (request(action)) {
        .settings => openSettings(app),
        .settings_page => |page| openSettingsPage(app, page),
        .main_menu => if (targetWindow(app, target)) |window| gx_window.popupMainMenu(window) else false,
        .keybinds => if (targetWindow(app, target)) |window| showShortcuts(app, window) else false,
        .new_tab_profile => |name| launchProfile(app, target, name, .tab),
        .new_window_profile => |name| launchProfile(app, target, name, .window),
        .new_tab_menu => if (targetWindow(app, target)) |window| gx_window.popupNewTabMenu(window) else false,
        .context_menu => switch (target) {
            .app => false,
            .surface => |core| gx_window.popupContextMenu(core.rt_surface.surface),
        },
        .tab_switcher => if (targetWindow(app, target)) |window| gx_window.openTabSwitcher(window) else false,
        .unknown => false,
    };
}

pub const Request = union(enum) {
    settings,
    /// The page name, a `gx.action.SettingsPage` tag.
    settings_page: []const u8,
    main_menu,
    keybinds,
    new_tab_profile: []const u8,
    new_window_profile: []const u8,
    new_tab_menu,
    context_menu,
    tab_switcher,
    unknown,
};

/// Maps a `gx.action.Action` to a request by tag name, so this compiles
/// with any tagged union; tags this app runtime does not handle, such as
/// `move_split_to_tab`, are unknown. Enum payloads (the settings page) map
/// to their tag names.
pub fn request(action: anytype) Request {
    switch (action) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            const simple = [_][]const u8{ "settings", "main_menu", "keybinds", "new_tab_menu", "context_menu", "tab_switcher" };
            inline for (simple) |simple_name| {
                if (comptime std.mem.eql(u8, name, simple_name)) return @unionInit(Request, simple_name, {});
            }
            if (comptime std.mem.eql(u8, name, "settings_page")) {
                return .{ .settings_page = if (@typeInfo(@TypeOf(payload)) == .@"enum") @tagName(payload) else payload };
            }
            if (comptime std.mem.eql(u8, name, "new_tab_profile")) return .{ .new_tab_profile = payload };
            if (comptime std.mem.eql(u8, name, "new_window_profile")) return .{ .new_window_profile = payload };
            return .unknown;
        },
    }
}

fn actionLanguage(
    action: *gio.SimpleAction,
    parameter: ?*glib.Variant,
    app: *Application,
) callconv(.c) void {
    const value = parameter orelse return;
    const lang = gx.i18n.parseLanguage(std.mem.span(value.getString(null))) orelse return;
    // Picking the language in use writes nothing and reloads nothing.
    if (lang == gx.i18n.current()) {
        action.setState(glib.Variant.newString(lang.configValue()));
        return;
    }
    saveLanguage(app.allocator(), lang) catch |err| {
        log.warn("cannot save language to {s} err={}", .{ gx.gui_settings.file_name, err });
        return;
    };
    action.setState(glib.Variant.newString(lang.configValue()));

    // Switch first so the reload translates the command palette entries
    // in the new language.
    _ = language.switchTo(lang);
    reloadQuietly(app);
}

/// Loads the configuration again, as `reload_config` does, without the
/// "Reloaded the configuration" toast: the windows tell about the new
/// language themselves (`window.sync`).
fn reloadQuietly(app: *Application) void {
    const alloc = app.allocator();
    const notifications = notifications: {
        const config = app.getConfig();
        defer config.unref();
        break :notifications config.get().@"app-notifications";
    };
    var quiet_buf: [128]u8 = undefined;
    const quiet = gx.settings_map.quietReloadArg(&quiet_buf, notifications) catch |err| {
        log.warn("cannot keep the configuration reload quiet err={}", .{err});
        return reloadConfig(app);
    };
    _ = @import("defaults.zig").sampleSystemCursorBlink();
    var config = gx.config_layers.loadWithOverrides(alloc, &.{quiet}) catch |err| {
        // Without the Ghostty GX layers (GHOSTTY_GX_DEFAULTS=0) the
        // upstream reload applies.
        log.info("reloading the configuration the upstream way err={}", .{err});
        return reloadConfig(app);
    };
    defer config.deinit();
    app.core().updateConfig(app.rt(), &config) catch |err| {
        log.warn("error applying the configuration err={}", .{err});
    };
}

fn reloadConfig(app: *Application) void {
    app.core().performAction(app.rt(), .reload_config) catch |err| {
        log.warn("error reloading config err={}", .{err});
    };
}

fn actionKeybinds(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    app: *Application,
) callconv(.c) void {
    const window = activeWindow(app) orelse return;
    _ = showShortcuts(app, window);
}

fn actionAbout(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    app: *Application,
) callconv(.c) void {
    const window = activeWindow(app) orelse return;
    about.present(window);
}

fn actionSettingsPage(
    _: *gio.SimpleAction,
    parameter: ?*glib.Variant,
    app: *Application,
) callconv(.c) void {
    const value = parameter orelse return;
    _ = openSettingsPage(app, std.mem.span(value.getString(null)));
}

fn actionOpenConfigFile(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    app: *Application,
) callconv(.c) void {
    openConfigFile(app);
}

fn saveLanguage(alloc: Allocator, lang: gx.i18n.Language) !void {
    const path = try gx.config_layers.overlayPath(alloc);
    defer alloc.free(path);
    var overlay = try gx.gui_settings.Overlay.load(alloc, global.io(), path);
    defer overlay.deinit();
    try overlay.set("language", lang.configValue());
    try overlay.save(global.io(), path);
}

fn setLanguageState(app: *Application, lang: gx.i18n.Language) void {
    const action = app.as(gio.ActionMap).lookupAction("gx-language") orelse return;
    const simple = gobject.ext.cast(gio.SimpleAction, action) orelse return;
    simple.setState(glib.Variant.newString(lang.configValue()));
}

/// Rebuilds the configuration in memory once the current configuration
/// change is handled, so that `Config.default` translates the default
/// command palette entries in the new language. Nothing is read from disk
/// again (`gx.config_layers.rebuild`).
fn reloadLater(app: *Application) void {
    const object = app.as(gobject.Object);
    if (object.getData(reload_key) != null) return;
    object.setData(reload_key, @ptrFromInt(1));
    _ = glib.idleAdd(reload, app);
}

fn reload(data: ?*anyopaque) callconv(.c) c_int {
    const app: *Application = @ptrCast(@alignCast(data orelse return 0));
    app.as(gobject.Object).setData(reload_key, null);
    const config = app.getConfig();
    defer config.unref();
    var rebuilt = gx.config_layers.rebuild(config.get(), app.allocator(), &.{}) catch |err| {
        log.warn("error rebuilding config for the UI language err={}", .{err});
        return 0;
    };
    defer rebuilt.deinit();
    app.core().updateConfig(app.rt(), &rebuilt) catch |err| {
        log.warn("error applying config for the UI language err={}", .{err});
    };
    return 0;
}

/// Opens the Ghostty GX settings (`app.gx-settings`), or the configuration
/// file if the application has no such action.
fn openSettings(app: *Application) bool {
    const group = app.as(gio.ActionGroup);
    if (group.hasAction("gx-settings") != 0 and group.getActionParameterType("gx-settings") == null) {
        group.activateAction("gx-settings", null);
    } else {
        group.activateAction("open-config", glib.Variant.newString("os-open"));
    }
    return true;
}

/// Opens the Ghostty GX settings at `page`, a `gx.action.SettingsPage`
/// name, which is also the name of the page in the settings dialog.
/// Returns false for an unknown page.
fn openSettingsPage(app: *Application, page: []const u8) bool {
    const settings_page = std.meta.stringToEnum(gx.action.SettingsPage, page) orelse {
        log.warn("unknown settings page {s}", .{page});
        return false;
    };
    GxSettingsDialog.showPage(app, settings_page);
    return true;
}

/// Opens the configuration file in the system editor, as upstream's
/// `open_config` does when `gx-open-config-ui = editor`.
fn openConfigFile(app: *Application) void {
    const alloc = app.allocator();
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("error getting config file path err={}", .{err});
        return;
    };
    defer alloc.free(path);
    app.openUrlFallback(.text, path);
}

fn showShortcuts(app: *Application, window: *Window) bool {
    const config = window.getConfig() orelse return false;
    shortcuts_dialog.present(app.allocator(), config.get(), window.as(gtk.Widget));
    return true;
}

/// Starts the launch profile `name` (an id such as `gx-zsh`, or a display
/// name) in a new tab next to the target terminal, or in a new window.
fn launchProfile(
    app: *Application,
    target: apprt.Target,
    name: []const u8,
    where: enum { tab, window },
) bool {
    const config = app.getConfig();
    defer config.unref();
    var profiles = launch.list(app, config.get()) catch return false;
    defer profiles.deinit();
    const profile = profiles.find(name) orelse {
        log.warn("unknown launch profile {s}", .{name});
        return false;
    };

    const group = app.as(gio.ActionGroup);
    switch (where) {
        .tab => {
            const surface_id: u64 = switch (target) {
                .app => 0,
                .surface => |core| core.id,
            };
            group.activateAction("new-tab", glib.ext.Variant.newFrom(.{ surface_id, profile.args }));
        },
        .window => group.activateAction("new-window-command", glib.ext.Variant.newFrom(profile.args)),
    }
    return true;
}

fn targetWindow(app: *Application, target: apprt.Target) ?*Window {
    switch (target) {
        .app => {},
        .surface => |core| {
            const surface = core.rt_surface.surface;
            if (ext.getAncestor(Window, surface.as(gtk.Widget))) |window| return window;
        },
    }
    return activeWindow(app);
}

fn activeWindow(app: *Application) ?*Window {
    const window = app.as(gtk.Application).getActiveWindow() orelse return null;
    return gobject.ext.cast(Window, window);
}

fn performTestAction(app: *Application, target: apprt.Target, action: gx.action.Action) bool {
    return performGxAction(app, target, action);
}

test "performGxAction compiles for gx.action.Action" {
    // Taking the address analyzes the handler for that action type.
    _ = &performTestAction;
}

test "request maps the gx.action.Action tags by name" {
    const testing = std.testing;
    const Action = gx.action.Action;

    try testing.expect(request(@as(Action, .settings)) == .settings);
    try testing.expect(request(@as(Action, .main_menu)) == .main_menu);
    try testing.expect(request(@as(Action, .keybinds)) == .keybinds);
    try testing.expect(request(@as(Action, .new_tab_menu)) == .new_tab_menu);
    try testing.expect(request(@as(Action, .context_menu)) == .context_menu);
    try testing.expect(request(@as(Action, .tab_switcher)) == .tab_switcher);
    try testing.expectEqualStrings("gx-zsh", request(Action{ .new_tab_profile = "gx-zsh" }).new_tab_profile);
    try testing.expectEqualStrings("bash", request(Action{ .new_window_profile = "bash" }).new_window_profile);
    try testing.expectEqualStrings("shell", request(Action{ .settings_page = .shell }).settings_page);
    try testing.expect(request(@as(Action, .move_split_to_tab)) == .unknown);
    try testing.expect(request(@as(Action, .move_split_to_window)) == .unknown);

    const Later = union(enum) { settings, something_new: u32 };
    try testing.expect(request(@as(Later, .settings)) == .settings);
    try testing.expect(request(Later{ .something_new = 1 }) == .unknown);

    // Every settings page is a page name the settings action accepts.
    for (std.enums.values(gx.action.SettingsPage)) |page| {
        const name = request(Action{ .settings_page = page }).settings_page;
        try testing.expectEqual(page, std.meta.stringToEnum(gx.action.SettingsPage, name).?);
    }
}
