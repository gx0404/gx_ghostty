//! Ghostty GX menus for the GTK apprt. `ui/1.5/gx/menus.blp` mirrors the
//! upstream window and terminal menus and adds the Ghostty GX entries. Its
//! labels are English msgids that are translated here with `gx.i18n`, so
//! the menus of open windows can be rebuilt whenever the UI language
//! changes. Callers set the new menus on their buttons and popovers rather
//! than editing the menus in place: GTK popover menus keep the pages of
//! removed submenus and then refuse new pages with the same label.
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

/// An attribute on dynamic items whose label must not be translated, such
/// as launch profile names and language names.
const verbatim_attribute = "gx-verbatim";

/// The object data key on a built menu holding the language it was built
/// in (the `Language` tag plus one).
const language_key = "gx-menu-language";

pub const Options = struct {
    /// Whether `app.gx-settings` exists; without it "Settings…" opens the
    /// configuration file instead.
    settings_action: bool,

    /// The launch profiles listed in the new tab dropdown.
    profiles: []const launch.Item = &.{},

    /// A hash of everything the menus are built from, including the UI
    /// language, to skip rebuilding menus that would not change.
    pub fn signature(self: Options) u64 {
        const lang = gx.i18n.current();
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(std.mem.asBytes(&lang));
        hasher.update(std.mem.asBytes(&self.settings_action));
        for (self.profiles) |profile| {
            hasher.update(profile.id);
            hasher.update(&.{0});
            hasher.update(profile.name);
            hasher.update(&.{0});
            for (profile.args) |arg| {
                hasher.update(arg);
                hasher.update(&.{0});
            }
            hasher.update(&.{1});
        }
        return hasher.final();
    }
};

/// The menus of `gx/menus.blp` with the dynamic sections filled in.
pub const Source = struct {
    builder: *gtk.Builder,
    options: Options,

    pub fn init(options: Options) Source {
        const builder = gtk.Builder.newFromResource(comptime gresource.blueprint(.{
            .major = 1,
            .minor = 5,
            .name = "gx/menus",
        }));
        const self: Source = .{ .builder = builder, .options = options };
        self.fillLanguages();
        self.fillProfiles();
        return self;
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
        const tabs = self.menu("gx_profiles_menu");
        const windows = self.menu("gx_window_profiles_menu");
        for (self.options.profiles) |profile| {
            {
                const item = gio.MenuItem.new(profile.name, null);
                defer item.unref();
                item.setActionAndTargetValue(
                    "app.new-tab",
                    glib.ext.Variant.newFrom(.{ @as(u64, 0), profile.args }),
                );
                setVerbatim(item);
                tabs.appendItem(item);
            }
            {
                const item = gio.MenuItem.new(profile.name, null);
                defer item.unref();
                item.setActionAndTargetValue(
                    "app.new-window-command",
                    glib.ext.Variant.newFrom(profile.args),
                );
                setVerbatim(item);
                windows.appendItem(item);
            }
        }
    }
};

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

fn stringAttribute(item: *gio.MenuItem, name: [:0]const u8) ?*glib.Variant {
    const string_type = glib.ext.VariantType.newFor([:0]const u8);
    defer string_type.free();
    return item.getAttributeValue(name, string_type);
}

fn setVerbatim(item: *gio.MenuItem) void {
    item.setAttributeValue(verbatim_attribute, glib.Variant.newBoolean(1));
}
