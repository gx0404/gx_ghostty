//! Ghostty GX menus for the GTK apprt. `ui/1.5/gx/menus.blp` holds the
//! window and terminal menus: the upstream items plus the Ghostty GX ones,
//! the main menu in the order of the Windows main menu. Its labels are
//! English msgids that are translated here with `gx.i18n`, so the menus of
//! open windows can be rebuilt whenever the UI language changes. Callers
//! set the new menus on their buttons and popovers rather than editing the
//! menus in place: GTK popover menus keep the pages of removed submenus and
//! then refuse new pages with the same label.
//!
//! Built menus are shared: `windowMenus` and `contextMenu` keep them on an
//! owner object (the application), so windows and terminals with the same
//! options do not load the blueprint again.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const gx = @import("../../../gx/main.zig");
const launch = @import("launch.zig");

/// The menus defined in `gx/menus.blp`.
pub const Id = enum {
    main_menu,
    split_menu,
    tab_context_menu,
    context_menu,
};

/// The custom item of the main menu for the zoom, find and fullscreen
/// buttons; the window adds them to each popover (`gtk.PopoverMenu.addChild`).
pub const view_controls = "gx-view-controls";

/// An attribute on dynamic items whose label must not be translated, such
/// as launch profile names and language names.
const verbatim_attribute = "gx-verbatim";

/// The object data key on a built menu holding the language it was built
/// in (the `Language` tag plus one).
const language_key = "gx-menu-language";

/// An accelerator shown next to the items with `action` and, if set, the
/// string `target` (an `accel` attribute, display only). Upstream actions
/// get theirs from the accelerators of the application.
pub const Accel = struct {
    action: [:0]const u8,
    target: ?[:0]const u8 = null,
    accel: [:0]const u8,
};

pub const Options = struct {
    /// Whether `app.gx-settings` exists; without it "Settings…" opens the
    /// configuration file instead.
    settings_action: bool,

    /// The launch profiles listed in the new tab menus.
    profiles: []const launch.Item = &.{},

    /// The profile new terminals start, an index into `profiles`.
    default_profile: ?usize = null,

    /// The accelerators of `gx:new_tab_profile` and `gx:new_window_profile`
    /// for each profile, when not empty.
    tab_profile_accels: []const ?[:0]const u8 = &.{},
    window_profile_accels: []const ?[:0]const u8 = &.{},

    accels: []const Accel = &.{},

    /// A hash of everything the menus are built from, including the UI
    /// language, to skip rebuilding menus that would not change.
    pub fn signature(self: Options) u64 {
        const lang = gx.i18n.current();
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(std.mem.asBytes(&lang));
        hasher.update(std.mem.asBytes(&self.settings_action));
        for (self.profiles) |profile| {
            hashString(&hasher, profile.id);
            hashString(&hasher, profile.name);
            for (profile.args) |arg| hashString(&hasher, arg);
            hasher.update(&.{1});
        }
        const default_profile: usize = self.default_profile orelse std.math.maxInt(usize);
        hasher.update(std.mem.asBytes(&default_profile));
        for ([_][]const ?[:0]const u8{ self.tab_profile_accels, self.window_profile_accels }) |accels| {
            for (accels) |accel| hashString(&hasher, accel orelse "");
            hasher.update(&.{2});
        }
        for (self.accels) |accel| {
            hashString(&hasher, accel.action);
            hashString(&hasher, accel.target orelse "");
            hashString(&hasher, accel.accel);
        }
        return hasher.final();
    }

    fn accelFor(self: Options, action: []const u8, target: ?[]const u8) ?[:0]const u8 {
        for (self.accels) |accel| {
            if (!std.mem.eql(u8, accel.action, action)) continue;
            const wanted = accel.target orelse return accel.accel;
            if (std.mem.eql(u8, wanted, target orelse continue)) return accel.accel;
        }
        return null;
    }
};

fn hashString(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(text);
    hasher.update(&.{0});
}

/// The menus of `gx/menus.blp` with the dynamic sections filled in.
pub const Source = struct {
    builder: *gtk.Builder,
    options: Options,

    pub fn init(options: Options) Source {
        const start = glib.getMonotonicTime();
        const builder = gtk.Builder.newFromResource(comptime gresource.blueprint(.{
            .major = 1,
            .minor = 5,
            .name = "gx/menus",
        }));
        gx.perf.record("gtk_menu_builder_load", @intCast(@max(glib.getMonotonicTime() - start, 0)));
        var self: Source = .{ .builder = builder, .options = options };
        self.prepare(options);
        return self;
    }

    fn prepare(self: *Source, options: Options) void {
        self.options = options;
        inline for (.{ "gx_view_section", "gx_language_menu", "gx_profiles_menu", "gx_main_profiles_menu", "gx_window_profiles_menu" }) |name| self.menu(name).removeAll();
        self.fillViewControls();
        self.fillLanguages();
        self.fillProfiles();
    }

    pub fn deinit(self: *Source) void {
        self.builder.unref();
        self.* = undefined;
    }

    /// A new menu with the items of menu `id` translated into the current
    /// UI language. Empty sections and submenus are dropped. The caller
    /// owns the returned reference.
    pub fn translated(self: *const Source, comptime id: Id) *gio.Menu {
        const result = gio.Menu.new();
        append(result, self.menu(@tagName(id)).as(gio.MenuModel), self.options);
        result.as(gobject.Object).setData(
            language_key,
            @ptrFromInt(@as(usize, @intFromEnum(gx.i18n.current())) + 1),
        );
        return result;
    }

    fn menu(self: *const Source, comptime name: [:0]const u8) *gio.Menu {
        const object = self.builder.getObject(name) orelse
            @panic("gx/menus.blp is missing " ++ name);
        return gobject.ext.cast(gio.Menu, object) orelse
            @panic("gx/menus.blp: " ++ name ++ " is not a menu");
    }

    fn fillViewControls(self: *const Source) void {
        const item = gio.MenuItem.new(null, null);
        defer item.unref();
        item.setAttributeValue("custom", glib.Variant.newString(view_controls));
        self.menu("gx_view_section").appendItem(item);
    }

    fn fillLanguages(self: *const Source) void {
        const target = self.menu("gx_language_menu");
        for (std.enums.values(gx.i18n.Language)) |lang| {
            const item = gio.MenuItem.new(lang.nativeName(), null);
            defer item.unref();
            item.setActionAndTargetValue("app.gx-language", glib.Variant.newString(lang.configValue()));
            setVerbatim(item);
            target.appendItem(item);
        }
    }

    fn fillProfiles(self: *const Source) void {
        const tab_menus = [_]*gio.Menu{ self.menu("gx_profiles_menu"), self.menu("gx_main_profiles_menu") };
        const windows = self.menu("gx_window_profiles_menu");
        for (self.options.profiles, 0..) |profile, i| {
            var label_buf: [256]u8 = undefined;
            const label = if (self.options.default_profile == i)
                defaultLabel(&label_buf, profile.name)
            else
                profile.name;
            for (tab_menus) |tabs| {
                const item = gio.MenuItem.new(label, null);
                defer item.unref();
                item.setActionAndTargetValue(
                    "app.gx-new-tab-profile",
                    glib.Variant.newString(profile.id),
                );
                setVerbatim(item);
                setAccel(item, nth(self.options.tab_profile_accels, i));
                tabs.appendItem(item);
            }
            {
                const item = gio.MenuItem.new(label, null);
                defer item.unref();
                item.setActionAndTargetValue(
                    "app.gx-new-window-profile",
                    glib.Variant.newString(profile.id),
                );
                setVerbatim(item);
                setAccel(item, nth(self.options.window_profile_accels, i));
                windows.appendItem(item);
            }
        }
    }
};

/// The label of the default launch profile: its name marked as the
/// default in the UI language.
fn defaultLabel(buf: []u8, name: [:0]const u8) [:0]const u8 {
    var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    gx.i18n.format(&writer, gx.i18n.tr("{name} (Default)"), .{ .name = name }) catch return name;
    const len = writer.buffered().len;
    buf[len] = 0;
    return buf[0..len :0];
}

fn nth(accels: []const ?[:0]const u8, i: usize) ?[:0]const u8 {
    return if (i < accels.len) accels[i] else null;
}

/// The menus a window shows, built for one `Options` signature.
pub const WindowMenus = struct {
    signature: u64,
    main_menu: *gio.Menu,
    split_menu: *gio.Menu,
    tab_context_menu: *gio.Menu,

    fn deinit(self: *WindowMenus) void {
        self.main_menu.unref();
        self.split_menu.unref();
        self.tab_context_menu.unref();
    }
};

/// What `owner` keeps: the menus of the last window options and the
/// terminal context menu of the last UI language.
const Cache = struct {
    window: ?WindowMenus = null,
    context: ?*gio.Menu = null,
    context_signature: u64 = 0,
    sources: [std.enums.values(gx.i18n.Language).len]?Source = @splat(null),

    fn source(self: *Cache, options: Options) *Source {
        const slot = &self.sources[@intFromEnum(gx.i18n.current())];
        if (slot.*) |*existing| {
            existing.prepare(options);
            return existing;
        }
        slot.* = .init(options);
        return &slot.*.?;
    }

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Cache = @ptrCast(@alignCast(data orelse return));
        if (self.window) |*menus| menus.deinit();
        if (self.context) |context| context.unref();
        for (&self.sources) |*source_| if (source_.*) |*s| s.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

/// The object data key on the owner holding its `Cache`.
const cache_key = "gx-menus";

fn ownerCache(owner: *gobject.Object) ?*Cache {
    if (owner.getData(cache_key)) |data| return @ptrCast(@alignCast(data));
    const cache = std.heap.c_allocator.create(Cache) catch return null;
    cache.* = .{};
    owner.setDataFull(cache_key, cache, &Cache.destroy);
    return cache;
}

/// The window menus for `options`, built when its signature differs from
/// the menus `owner` keeps. The menus belong to `owner`; callers that
/// keep one take a reference (setting it on a widget does).
pub fn windowMenus(owner: *gobject.Object, options: Options) WindowMenus {
    const signature = options.signature();
    const cache = ownerCache(owner);
    if (cache) |c| if (c.window) |menus| {
        if (menus.signature == signature) return menus;
    };

    var temporary: ?Source = null;
    defer if (temporary) |*s| s.deinit();
    const source = if (cache) |c| c.source(options) else source: {
        temporary = .init(options);
        break :source &temporary.?;
    };
    var menus: WindowMenus = .{
        .signature = signature,
        .main_menu = source.translated(.main_menu),
        .split_menu = source.translated(.split_menu),
        .tab_context_menu = source.translated(.tab_context_menu),
    };
    const c = cache orelse {
        // Without a cache the menus live as long as the widgets that
        // show them: drop the reference once they are set.
        scheduleUnref(&menus);
        return menus;
    };
    if (c.window) |*old| old.deinit();
    c.window = menus;
    return menus;
}

/// The terminal context menu in the current UI language, built once per
/// language and `settings_action`. It belongs to `owner`.
pub fn contextMenu(owner: *gobject.Object, settings_action: bool) *gio.Menu {
    const signature = (Options{ .settings_action = settings_action }).signature();
    const cache = ownerCache(owner);
    if (cache) |c| if (c.context) |menu| {
        if (c.context_signature == signature) return menu;
    };

    const options: Options = .{ .settings_action = settings_action };
    var temporary: ?Source = null;
    defer if (temporary) |*s| s.deinit();
    const source = if (cache) |c| c.source(options) else source: {
        temporary = .init(options);
        break :source &temporary.?;
    };
    const menu = source.translated(.context_menu);
    const c = cache orelse {
        _ = glib.idleAdd(unrefMenu, menu);
        return menu;
    };
    if (c.context) |old| old.unref();
    c.context = menu;
    c.context_signature = signature;
    return menu;
}

fn scheduleUnref(menus: *const WindowMenus) void {
    _ = glib.idleAdd(unrefMenu, menus.main_menu);
    _ = glib.idleAdd(unrefMenu, menus.split_menu);
    _ = glib.idleAdd(unrefMenu, menus.tab_context_menu);
}

fn unrefMenu(data: ?*anyopaque) callconv(.c) c_int {
    const menu: *gio.Menu = @ptrCast(@alignCast(data orelse return 0));
    menu.unref();
    return 0;
}

/// Whether `model` is a menu built by `Source.translated` in the current UI
/// language.
pub fn isCurrent(model: *gio.MenuModel) bool {
    const stamp = model.as(gobject.Object).getData(language_key) orelse return false;
    return @intFromPtr(stamp) == @as(usize, @intFromEnum(gx.i18n.current())) + 1;
}

fn append(target: *gio.Menu, source: *gio.MenuModel, options: Options) void {
    const n = source.getNItems();
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const item = gio.MenuItem.newFromModel(source, i);
        defer item.unref();

        translateLabel(item);
        if (!options.settings_action) replaceSettingsAction(item);
        setOptionAccel(item, options);

        const keep = keep: {
            inline for (.{ "section", "submenu" }) |link| {
                if (item.getLink(link)) |child| {
                    defer child.unref();
                    const copy = gio.Menu.new();
                    defer copy.unref();
                    append(copy, child, options);
                    if (copy.as(gio.MenuModel).getNItems() == 0) break :keep false;
                    item.setLink(link, copy.as(gio.MenuModel));
                }
            }
            break :keep true;
        };
        if (keep) target.appendItem(item);
    }
}

fn translateLabel(item: *gio.MenuItem) void {
    if (item.getAttributeValue(verbatim_attribute, null)) |value| {
        value.unref();
        return;
    }
    const value = stringAttribute(item, "label") orelse return;
    defer value.unref();
    item.setLabel(gx.i18n.trRuntime(std.mem.span(value.getString(null))));
}

fn replaceSettingsAction(item: *gio.MenuItem) void {
    const value = stringAttribute(item, "action") orelse return;
    defer value.unref();
    if (!std.mem.eql(u8, std.mem.span(value.getString(null)), "app.gx-settings")) return;
    item.setActionAndTargetValue("app.open-config", glib.Variant.newString("os-open"));
}

fn setOptionAccel(item: *gio.MenuItem, options: Options) void {
    if (options.accels.len == 0) return;
    const action = stringAttribute(item, "action") orelse return;
    defer action.unref();
    const target = stringAttribute(item, "target");
    defer if (target) |value| value.unref();
    setAccel(item, options.accelFor(
        std.mem.span(action.getString(null)),
        if (target) |value| std.mem.span(value.getString(null)) else null,
    ));
}

fn setAccel(item: *gio.MenuItem, accel: ?[:0]const u8) void {
    item.setAttributeValue("accel", glib.Variant.newString(accel orelse return));
}

fn stringAttribute(item: *gio.MenuItem, name: [:0]const u8) ?*glib.Variant {
    const string_type = glib.ext.VariantType.newFor([:0]const u8);
    defer string_type.free();
    return item.getAttributeValue(name, string_type);
}

fn setVerbatim(item: *gio.MenuItem) void {
    item.setAttributeValue(verbatim_attribute, glib.Variant.newBoolean(1));
}

test "Options.accelFor matches the action and the target" {
    const testing = std.testing;
    const options: Options = .{
        .settings_action = true,
        .accels = &.{
            .{ .action = "app.gx-keybinds", .accel = "<Shift><Ctrl>question" },
            .{ .action = "app.gx-settings-page", .target = "shell", .accel = "<Ctrl><Alt>s" },
        },
    };
    try testing.expectEqualStrings("<Shift><Ctrl>question", options.accelFor("app.gx-keybinds", null).?);
    try testing.expectEqualStrings("<Shift><Ctrl>question", options.accelFor("app.gx-keybinds", "x").?);
    try testing.expectEqualStrings("<Ctrl><Alt>s", options.accelFor("app.gx-settings-page", "shell").?);
    try testing.expectEqual(@as(?[:0]const u8, null), options.accelFor("app.gx-settings-page", "font"));
    try testing.expectEqual(@as(?[:0]const u8, null), options.accelFor("app.gx-settings-page", null));
    try testing.expectEqual(@as(?[:0]const u8, null), options.accelFor("app.gx-about", null));
}

test "Options.signature follows the default profile and the accelerators" {
    const testing = std.testing;
    const items = [_]launch.Item{
        .{ .id = "bash", .name = "Bash", .args = &.{ "-e", "/bin/bash" } },
        .{ .id = "zsh", .name = "Zsh", .args = &.{ "-e", "/bin/zsh" } },
    };
    const base: Options = .{ .settings_action = true, .profiles = &items };
    var other = base;
    other.default_profile = 1;
    try testing.expect(base.signature() != other.signature());

    var accel = base;
    accel.accels = &.{.{ .action = "app.gx-keybinds", .accel = "<Ctrl>k" }};
    try testing.expect(base.signature() != accel.signature());

    var tab_accel = base;
    tab_accel.tab_profile_accels = &.{ null, "<Ctrl><Alt>z" };
    try testing.expect(base.signature() != tab_accel.signature());
    try testing.expectEqual(base.signature(), (Options{ .settings_action = true, .profiles = &items }).signature());
}

test "defaultLabel marks the name and falls back to it when it does not fit" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const previous = gx.i18n.current();
    defer gx.i18n.setCurrent(previous);
    gx.i18n.setCurrent(.en);
    try testing.expectEqualStrings("Bash (Default)", defaultLabel(&buf, "Bash"));
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("Bash", defaultLabel(&small, "Bash"));
}
