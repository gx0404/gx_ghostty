//! Ghostty GX additions to `class/window.zig::Window`: menus and header
//! bar tooltips in the current UI language (rebuilt when it changes, with a
//! toast because some libadwaita labels only change in new windows), launch
//! profiles in the new tab dropdown, the terminal context menu, and opening
//! the main menu for the `gx:main_menu` action.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gx = @import("../../../gx/main.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Window = @import("../class/window.zig").Window;
const launch = @import("launch.zig");
const menus = @import("menus.zig");

const log = std.log.scoped(.gtk_gx_window);
const tr = gx.i18n.tr;

/// The object data key on a window holding the UI language its menus were
/// last built in (the `Language` tag plus one).
const language_key = "gx-window-language";

/// The object data key on a window holding `menus.Options.signature` of
/// its menus, plus one.
const signature_key = "gx-window-menus";

/// The object data key on a terminal popover holding the context menu
/// while it shows the main menu.
const restore_key = "gx-context-menu";

/// The object data key on a terminal popover that has the handler putting
/// the context menu back.
const restore_handler_key = "gx-context-menu-handler";

/// Brings the menus and tooltips of `window` up to date with the UI
/// language, the launch profiles and the configuration. Called when the
/// window is created and whenever its configuration changes.
pub fn sync(window: *Window) void {
    const app = Application.default();
    const alloc = app.allocator();
    const object = window.as(gobject.Object);

    const lang = gx.i18n.current();
    const previous: usize = if (object.getData(language_key)) |data| @intFromPtr(data) else 0;
    object.setData(language_key, @ptrFromInt(languageStamp(lang)));

    var profiles: launch.List = profiles: {
        const config = window.getConfig() orelse break :profiles .{ .arena = .init(alloc) };
        break :profiles launch.detect(alloc, config.get()) catch |err| {
            log.warn("cannot detect launch profiles err={}", .{err});
            break :profiles .{ .arena = .init(alloc) };
        };
    };
    defer profiles.deinit();

    const options: menus.Options = .{
        .settings_action = hasAppAction(app, "gx-settings"),
        .profiles = profiles.items,
    };
    // The data is the signature with the lowest bit set, so it is never
    // null; a collision only skips one rebuild.
    const signature: usize = @truncate(options.signature() | 1);
    if (object.getData(signature_key)) |data| {
        if (@intFromPtr(data) == signature) return;
    }
    object.setData(signature_key, @ptrFromInt(signature));

    var header: Header = .{};
    if (toolbar(window)) |widget| walk(widget, &header);

    var source: menus.Source = .init(options);
    defer source.deinit();
    {
        const menu = source.translated(.main_menu);
        defer menu.unref();
        for (header.menu_buttons.slice()) |button| button.setMenuModel(menu.as(gio.MenuModel));
    }
    {
        const menu = source.translated(.split_menu);
        defer menu.unref();
        for (header.split_buttons.slice()) |button| button.setMenuModel(menu.as(gio.MenuModel));
    }
    {
        const menu = source.translated(.tab_context_menu);
        defer menu.unref();
        window.getTabView().setMenuModel(menu.as(gio.MenuModel));
    }

    if (previous != 0 and previous != languageStamp(lang)) {
        toast(window, tr("Language changed. Reopen the window to update all labels."));
    }
}

/// Rebuilds the context menu of `surface` if the UI language changed
/// since it was built. Called right before the menu opens.
pub fn syncSurfaceMenu(surface: *Surface) void {
    const popover = surfacePopover(surface) orelse return;
    if (popover.as(gobject.Object).getData(restore_key) != null) return;
    if (popover.getMenuModel()) |model| if (menus.isCurrent(model)) return;

    var source: menus.Source = .init(.{
        .settings_action = hasAppAction(Application.default(), "gx-settings"),
    });
    defer source.deinit();
    const menu = source.translated(.context_menu);
    defer menu.unref();
    popover.setMenuModel(menu.as(gio.MenuModel));
}

/// Opens the main menu of `window`: from its header bar or tab bar button
/// when one is shown, else from the active terminal. Returns false if
/// there is neither.
pub fn popupMainMenu(window: *Window) bool {
    var header: Header = .{};
    if (toolbar(window)) |widget| walk(widget, &header);
    for (header.menu_buttons.slice()) |button| {
        const widget = button.as(gtk.Widget);
        if (widget.isVisible() != 0 and widget.getMapped() != 0) {
            button.popup();
            return true;
        }
    }

    const button = if (header.menu_buttons.len > 0) header.menu_buttons.items[0] else return false;
    const model = button.getMenuModel() orelse return false;
    const surface = window.getActiveSurface() orelse return false;
    const popover = surfacePopover(surface) orelse return false;
    showFromPopover(popover, model);
    return true;
}

/// Up to four widgets of one kind.
fn Widgets(comptime T: type) type {
    return struct {
        items: [4]*T = undefined,
        len: usize = 0,

        fn add(self: *@This(), item: *T) void {
            if (self.len == self.items.len) return;
            self.items[self.len] = item;
            self.len += 1;
        }

        fn slice(self: *const @This()) []const *T {
            return self.items[0..self.len];
        }
    };
}

/// The new tab and main menu buttons of the header bar and the tab bar.
/// Visiting a button also translates its tooltip.
const Header = struct {
    menu_buttons: Widgets(gtk.MenuButton) = .{},
    split_buttons: Widgets(adw.SplitButton) = .{},

    /// Returns whether to visit the children of `widget`.
    fn visit(self: *Header, widget: *gtk.Widget) bool {
        if (gobject.ext.cast(adw.SplitButton, widget)) |button| {
            widget.setTooltipText(tr("New Tab"));
            button.setDropdownTooltip(tr("Launch Profiles and Splits"));
            self.split_buttons.add(button);
            return false;
        }
        if (gobject.ext.cast(gtk.MenuButton, widget)) |button| {
            if (iconIs(button.getIconName(), "open-menu-symbolic")) {
                widget.setTooltipText(tr("Main Menu"));
                self.menu_buttons.add(button);
            }
            return false;
        }
        if (gobject.ext.cast(gtk.ToggleButton, widget)) |button| {
            if (iconIs(button.as(gtk.Button).getIconName(), "view-grid-symbolic")) {
                widget.setTooltipText(tr("View Open Tabs"));
            }
            return false;
        }
        return true;
    }
};

/// Visits the widgets below `widget` depth first, skipping tab contents.
fn walk(widget: *gtk.Widget, header: *Header) void {
    var child = widget.getFirstChild();
    while (child) |current| : (child = current.getNextSibling()) {
        if (gobject.ext.isA(current, adw.TabView)) continue;
        if (header.visit(current)) walk(current, header);
    }
}

fn toolbar(window: *Window) ?*gtk.Widget {
    const object = gtk_widget_get_template_child(
        window.as(gtk.Widget),
        Window.getGObjectType(),
        "toolbar",
    ) orelse return null;
    return gobject.ext.cast(gtk.Widget, object);
}

fn surfacePopover(surface: *Surface) ?*gtk.PopoverMenu {
    const object = gtk_widget_get_template_child(
        surface.as(gtk.Widget),
        Surface.getGObjectType(),
        "context_menu",
    ) orelse return null;
    return gobject.ext.cast(gtk.PopoverMenu, object);
}

fn toast(window: *Window, title: [:0]const u8) void {
    const object = gtk_widget_get_template_child(
        window.as(gtk.Widget),
        Window.getGObjectType(),
        "toast_overlay",
    ) orelse return;
    const overlay = gobject.ext.cast(adw.ToastOverlay, object) orelse return;
    const item = adw.Toast.new(title);
    item.setTimeout(6);
    overlay.addToast(item);
}

/// Shows `model` from the context menu popover of a terminal at its top
/// right corner, then puts the context menu back when the popover closes.
fn showFromPopover(popover: *gtk.PopoverMenu, model: *gio.MenuModel) void {
    const object = popover.as(gobject.Object);
    if (object.getData(restore_handler_key) == null) {
        _ = gtk.Popover.signals.closed.connect(
            popover.as(gtk.Popover),
            ?*anyopaque,
            restoreContextMenu,
            null,
            .{},
        );
        object.setData(restore_handler_key, @ptrFromInt(1));
    }
    if (object.getData(restore_key) == null) {
        const context = popover.getMenuModel() orelse return;
        object.setDataFull(restore_key, context.as(gobject.Object).ref(), &unrefObject);
    }
    popover.setMenuModel(model);

    const anchor = popover.as(gtk.Widget).getParent() orelse popover.as(gtk.Widget);
    const rect: gdk.Rectangle = .{
        .f_x = @max(anchor.getWidth() - 1, 0),
        .f_y = 0,
        .f_width = 1,
        .f_height = 1,
    };
    popover.as(gtk.Popover).setPointingTo(&rect);
    popover.as(gtk.Popover).popup();
}

fn restoreContextMenu(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
    const data = popover.as(gobject.Object).stealData(restore_key) orelse return;
    const context: *gio.MenuModel = @ptrCast(@alignCast(data));
    defer context.unref();
    const menu = gobject.ext.cast(gtk.PopoverMenu, popover) orelse return;
    menu.setMenuModel(context);
}

fn unrefObject(data: ?*anyopaque) callconv(.c) void {
    const object: *gobject.Object = @ptrCast(@alignCast(data orelse return));
    object.unref();
}

fn iconIs(icon: ?[*:0]const u8, name: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(icon orelse return false), name);
}

fn hasAppAction(app: *Application, name: [:0]const u8) bool {
    return app.as(gio.ActionGroup).hasAction(name) != 0;
}

fn languageStamp(lang: gx.i18n.Language) usize {
    return @as(usize, @intFromEnum(lang)) + 1;
}

// The generated binding declares the result as non-null, but GTK returns
// null for names that are not template children.
extern fn gtk_widget_get_template_child(
    widget: *gtk.Widget,
    widget_type: usize,
    name: [*:0]const u8,
) ?*gobject.Object;
