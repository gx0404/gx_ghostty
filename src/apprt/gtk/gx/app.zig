//! Ghostty GX additions to `class/application.zig::Application`: the
//! `app.gx-language`, `app.gx-keybinds` and `app.gx-about` actions,
//! following `language` changes at runtime, and the GTK side of the
//! Ghostty GX binding actions (`gx:<name>[:<arg>]`, dispatched by the core
//! through `App.gxAction`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const ext = @import("../ext.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
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
/// `app.gx-keybinds` (the keyboard shortcuts cheat sheet) and
/// `app.gx-about` (the Ghostty GX About dialog). Called from
/// `Application.startup`.
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
/// not handled.
pub fn performGxAction(app: *Application, target: apprt.Target, action: anytype) bool {
    return switch (request(action)) {
        .settings => openSettings(app),
        .main_menu => if (targetWindow(app, target)) |window| gx_window.popupMainMenu(window) else false,
        .keybinds => if (targetWindow(app, target)) |window| showShortcuts(app, window) else false,
        .new_tab_profile => |name| launchProfile(app, target, name, .tab),
        .new_window_profile => |name| launchProfile(app, target, name, .window),
        .unknown => false,
    };
}

pub const Request = union(enum) {
    settings,
    main_menu,
    keybinds,
    new_tab_profile: []const u8,
    new_window_profile: []const u8,
    unknown,
};

/// Maps a `gx.action.Action` to a request by tag name, so this compiles
/// with any tagged union (`settings`, `main_menu`, `keybinds`, and the
/// profile actions with a profile id or name); other tags are unknown.
pub fn request(action: anytype) Request {
    switch (action) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "settings")) return .settings;
            if (comptime std.mem.eql(u8, name, "main_menu")) return .main_menu;
            if (comptime std.mem.eql(u8, name, "keybinds")) return .keybinds;
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
    saveLanguage(app.allocator(), lang) catch |err| {
        log.warn("cannot save language to {s} err={}", .{ gx.gui_settings.file_name, err });
        return;
    };
    action.setState(glib.Variant.newString(lang.configValue()));

    // Switch first so the reload translates the command palette entries
    // in the new language.
    if (lang != gx.i18n.current()) _ = language.switchTo(lang);
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

/// Loads the configuration again once the current configuration change is
/// handled, so that `Config.default` translates the default command
/// palette entries in the new language.
fn reloadLater(app: *Application) void {
    const object = app.as(gobject.Object);
    if (object.getData(reload_key) != null) return;
    object.setData(reload_key, @ptrFromInt(1));
    _ = glib.idleAdd(reload, app);
}

fn reload(data: ?*anyopaque) callconv(.c) c_int {
    const app: *Application = @ptrCast(@alignCast(data orelse return 0));
    app.as(gobject.Object).setData(reload_key, null);
    app.core().performAction(app.rt(), .reload_config) catch |err| {
        log.warn("error reloading config for the UI language err={}", .{err});
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
    var profiles = launch.detect(app.allocator(), config.get()) catch return false;
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

/// The shape of `gx.action.Action` the core passes to `App.gxAction`.
const TestAction = union(enum) {
    settings,
    main_menu,
    keybinds,
    new_tab_profile: []const u8,
    new_window_profile: []const u8,
};

fn performTestAction(app: *Application, target: apprt.Target, action: TestAction) bool {
    return performGxAction(app, target, action);
}

test "performGxAction compiles for gx.action.Action" {
    // Taking the address analyzes the handler for that action type.
    _ = &performTestAction;
}

test "request maps the gx.action.Action tags by name" {
    const testing = std.testing;
    const Action = TestAction;

    try testing.expect(request(@as(Action, .settings)) == .settings);
    try testing.expect(request(@as(Action, .main_menu)) == .main_menu);
    try testing.expect(request(@as(Action, .keybinds)) == .keybinds);
    try testing.expectEqualStrings("gx-zsh", request(Action{ .new_tab_profile = "gx-zsh" }).new_tab_profile);
    try testing.expectEqualStrings("bash", request(Action{ .new_window_profile = "bash" }).new_window_profile);

    const Later = union(enum) { settings, something_new: u32 };
    try testing.expect(request(@as(Later, .settings)) == .settings);
    try testing.expect(request(Later{ .something_new = 1 }) == .unknown);
}
