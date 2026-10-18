//! Ghostty GX additions to `class/window.zig::Window`: menus and header
//! bar tooltips in the current UI language (rebuilt when it changes, with a
//! toast because some libadwaita labels only change in new windows), launch
//! profiles in the new tab dropdown, the terminal context menu, and opening
//! the main menu for the `gx:main_menu` action.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const ext = @import("../ext.zig");
const key = @import("../key.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;
const language = @import("language.zig");
const launch = @import("launch.zig");
const menus = @import("menus.zig");
const open_perf = @import("open_perf.zig");

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

/// The object data key on the box of a terminal's context menu holding
/// the main menu popover next to it (`mainPopover`).
const main_popover_key = "gx-main-menu-popover";

/// Brings the menus and tooltips of `window` up to date with the UI
/// language, the launch profiles and the configuration. Called when the
/// window is created and whenever its configuration changes.
pub fn sync(window: *Window) void {
    const app = Application.default();
    const object = window.as(gobject.Object);
    if (toolbar(window)) |widget| widget.addCssClass("gx-chrome");
    registerActions(window);
    warnMissingHan(window, app);

    const lang = gx.i18n.current();
    const previous: usize = if (object.getData(language_key)) |data| @intFromPtr(data) else 0;
    object.setData(language_key, @ptrFromInt(languageStamp(lang)));

    const config = window.getConfig() orelse return;
    var profiles = launch.list(app, config.get()) catch |err| {
        log.warn("cannot detect launch profiles err={}", .{err});
        return;
    };
    defer profiles.deinit();
    const options = menuOptions(profiles.arena.allocator(), config.get(), profiles) catch return;
    const signature: usize = @truncate(options.signature() | 1);
    if (object.getData(signature_key)) |data| {
        if (@intFromPtr(data) == signature) return;
    }

    var header: Header = .{};
    if (toolbar(window)) |widget| walk(widget, &header);
    const built = menus.windowMenus(app.as(gobject.Object), options);
    for (header.menu_buttons.slice()) |button| {
        if (button.getPopover()) |popover| removeViewControls(gobject.ext.cast(gtk.PopoverMenu, popover) orelse continue);
        button.setMenuModel(built.main_menu.as(gio.MenuModel));
        if (button.getPopover()) |popover| addViewControls(gobject.ext.cast(gtk.PopoverMenu, popover) orelse continue);
    }
    for (header.split_buttons.slice()) |button| button.setMenuModel(built.split_menu.as(gio.MenuModel));
    window.getTabView().setMenuModel(built.tab_context_menu.as(gio.MenuModel));
    object.setData(signature_key, @ptrFromInt(signature));

    if (previous != 0 and previous != languageStamp(lang)) {
        const app_object = app.as(gobject.Object);
        const stamp = app_object.getData("gx-language-toast");
        if (stamp == null or @intFromPtr(stamp.?) != languageStamp(lang)) {
            app_object.setData("gx-language-toast", @ptrFromInt(languageStamp(lang)));
            toast(window, tr("Language changed. Reopen the window to update all labels."));
        }
    }
}

pub fn syncSurfaceMenu(surface: *Surface) void {
    const popover = surfacePopover(surface) orelse return;
    if (popover.as(gobject.Object).getData(restore_key) != null) return;
    if (popover.getMenuModel()) |model| if (menus.isCurrent(model)) return;
    const app = Application.default();
    const menu = menus.contextMenu(app.as(gobject.Object), hasAppAction(app, "gx-settings"));
    popover.setMenuModel(menu.as(gio.MenuModel));
}

/// Opens the main menu of `window`: from its header bar or tab bar button
/// when one is shown, else from the active terminal. Returns false if
/// there is neither. Both keep their menu between openings.
pub fn popupMainMenu(window: *Window) bool {
    var timing = open_perf.begin(.menu);
    var header: Header = .{ .translate = false };
    if (toolbar(window)) |widget| walk(widget, &header);
    for (header.menu_buttons.slice()) |button| {
        const widget = button.as(gtk.Widget);
        if (widget.isVisible() != 0 and widget.getMapped() != 0) {
            // The button keeps its popover and menu: nothing to create.
            open_perf.lap(&timing, .prepare);
            if (button.getPopover()) |popover| open_perf.watch(popover.as(gtk.Widget), timing);
            button.popup();
            if (button.getPopover()) |popover| open_perf.presented(popover.as(gtk.Widget), timing);
            return true;
        }
    }

    const button = if (header.menu_buttons.len > 0) header.menu_buttons.items[0] else return false;
    const model = button.getMenuModel() orelse return false;
    const surface = window.getActiveSurface() orelse return false;
    const context = surfacePopover(surface) orelse return false;
    open_perf.lap(&timing, .prepare);
    const popover = mainPopover(context, model) orelse return false;
    open_perf.lap(&timing, .create);
    pointAtTopRight(popover.as(gtk.Popover));
    open_perf.lap(&timing, .layout);
    open_perf.watch(popover.as(gtk.Widget), timing);
    popover.as(gtk.Popover).popup();
    open_perf.presented(popover.as(gtk.Widget), timing);
    return true;
}

/// The main menu popover of a terminal whose window shows no main menu
/// button, next to its context menu `context` (the main menu used to take
/// the context menu's place, building both menus at every opening). It is
/// built at the first opening and kept, and its menu is built again only
/// when `model` changed. The box of the context menu holds it and removes
/// it with the terminal.
fn mainPopover(context: *gtk.PopoverMenu, model: *gio.MenuModel) ?*gtk.PopoverMenu {
    const parent = context.as(gtk.Widget).getParent() orelse return null;
    const box = gobject.ext.cast(gtk.Box, parent) orelse return null;
    const object = box.as(gobject.Object);
    if (object.getData(main_popover_key)) |data| {
        const popover: *gtk.PopoverMenu = @ptrCast(@alignCast(data));
        if (popover.getMenuModel() != model) {
            removeViewControls(popover);
            popover.setMenuModel(model);
            addViewControls(popover);
        }
        return popover;
    }
    // Like the context menu it stands for.
    const popover = gtk.PopoverMenu.newFromModelFull(model, .{ .nested = true });
    popover.as(gtk.Widget).setHalign(.start);
    popover.as(gtk.Popover).setHasArrow(0);
    box.append(popover.as(gtk.Widget));
    object.setData(main_popover_key, popover);
    popover.as(gobject.Object).weakRef(&forgetMainPopover, object);
    _ = gtk.Popover.signals.closed.connect(popover.as(gtk.Popover), ?*anyopaque, mainPopoverClosed, null, .{});
    addViewControls(popover);
    return popover;
}

fn forgetMainPopover(data: ?*anyopaque, _: *gobject.Object) callconv(.c) void {
    const box: *gobject.Object = @ptrCast(@alignCast(data orelse return));
    box.setData(main_popover_key, null);
}

/// Gives the focus back to the terminal when the main menu closes, like
/// its context menu does (GTK would move it to the tab bar).
fn mainPopoverClosed(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
    const widget = popover.as(gtk.Widget).getAncestor(Surface.getGObjectType()) orelse return;
    if (widget.getRoot() == null) return;
    const surface = gobject.ext.cast(Surface, widget) orelse return;
    surface.grabFocus();
}

pub fn popupNewTabMenu(window: *Window) bool {
    var header: Header = .{ .translate = false };
    if (toolbar(window)) |widget| walk(widget, &header);
    for (header.split_buttons.slice()) |button| {
        const widget = button.as(gtk.Widget);
        if (widget.isVisible() != 0 and widget.getMapped() != 0) {
            button.popup();
            return true;
        }
    }
    const button = if (header.split_buttons.len > 0) header.split_buttons.items[0] else return false;
    const model = button.getMenuModel() orelse return false;
    const surface = window.getActiveSurface() orelse return false;
    const popover = surfacePopover(surface) orelse return false;
    showFromPopover(popover, model);
    return true;
}

pub fn popupContextMenu(surface: *Surface) bool {
    syncSurfaceMenu(surface);
    const popover = surfacePopover(surface) orelse return false;
    const widget = surface.as(gtk.Widget);
    const rect: gdk.Rectangle = .{
        .f_x = @divTrunc(widget.getWidth(), 2),
        .f_y = @divTrunc(widget.getHeight(), 2),
        .f_width = 1,
        .f_height = 1,
    };
    popover.as(gtk.Popover).setPointingTo(&rect);
    popover.as(gtk.Popover).popup();
    return true;
}

pub fn openTabSwitcher(window: *Window) bool {
    window.toggleTabOverview();
    return true;
}

fn menuOptions(alloc: std.mem.Allocator, config: *const configpkg.Config, profiles: launch.List) !menus.Options {
    const Mapping = struct { name: [:0]const u8, action: input.Binding.Action, target: ?[:0]const u8 = null };
    const mappings = [_]Mapping{
        .{ .name = "win.new-tab", .action = .new_tab },
        .{ .name = "win.new-window", .action = .new_window },
        .{ .name = "win.split-up", .action = .{ .new_split = .up } },
        .{ .name = "win.split-down", .action = .{ .new_split = .down } },
        .{ .name = "win.split-left", .action = .{ .new_split = .left } },
        .{ .name = "win.split-right", .action = .{ .new_split = .right } },
        .{ .name = "win.toggle-command-palette", .action = .toggle_command_palette },
        .{ .name = "app.gx-settings", .action = if (config.@"gx-open-config-ui" == .settings) .{ .open_config = .os_open } else .{ .gx = .settings } },
        .{ .name = "app.gx-keybinds", .action = .{ .gx = .keybinds } },
        .{ .name = "app.reload-config", .action = .reload_config },
        .{ .name = "app.gx-open-config-file", .action = if (config.@"gx-open-config-ui" == .editor) .{ .open_config = .os_open } else .{ .gx = .settings } },
        .{ .name = "app.quit", .action = .quit },
        .{ .name = "app.gx-settings-page", .action = .{ .gx = .{ .settings_page = .shell } }, .target = "shell" },
    };
    var accels: std.ArrayList(menus.Accel) = .empty;
    for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.name, "app.gx-open-config-file") and config.@"gx-open-config-ui" != .editor) continue;
        const accel = try actionAccel(alloc, config, mapping.action) orelse continue;
        try accels.append(alloc, .{ .action = mapping.name, .target = mapping.target, .accel = accel });
    }
    const tabs = try alloc.alloc(?[:0]const u8, profiles.items.len);
    const windows = try alloc.alloc(?[:0]const u8, profiles.items.len);
    for (profiles.items, tabs, windows) |profile, *tab_accel, *window_accel| {
        tab_accel.* = try actionAccel(alloc, config, .{ .gx = .{ .new_tab_profile = profile.id } });
        window_accel.* = try actionAccel(alloc, config, .{ .gx = .{ .new_window_profile = profile.id } });
    }
    return .{
        .settings_action = hasAppAction(Application.default(), "gx-settings"),
        .profiles = profiles.items,
        .default_profile = profiles.default,
        .accels = accels.items,
        .tab_profile_accels = tabs,
        .window_profile_accels = windows,
    };
}

fn actionAccel(alloc: std.mem.Allocator, config: *const configpkg.Config, action: input.Binding.Action) !?[:0]const u8 {
    const trigger = menuTrigger(&config.keybind.set, action) orelse return null;
    var buf: [128]u8 = undefined;
    const accel = try key.accelFromTrigger(&buf, trigger) orelse return null;
    return try alloc.dupeZ(u8, accel);
}

fn menuTrigger(set: *const input.Binding.Set, action: input.Binding.Action) ?input.Binding.Trigger {
    if (set.getTrigger(action)) |trigger| return trigger;
    var best: ?input.Binding.Trigger = null;
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leaf => |leaf| leaf,
            else => continue,
        };
        if (!leaf.action.equal(action)) continue;
        const trigger = entry.key_ptr.*;
        if (best == null or trigger.hash() < best.?.hash()) best = trigger;
    }
    return best;
}

const context_page_key = "gx-context-tab-page";
const actions_key = "gx-window-actions";
const controls_key = "gx-view-controls-widget";

fn registerActions(window: *Window) void {
    const object = window.as(gobject.Object);
    if (object.getData(actions_key) != null) return;
    ext.actions.add(Window, window, &.{
        .init("gx-tab-close", actionTabClose, null),
        .init("gx-tab-close-others", actionTabCloseOthers, null),
        .init("gx-tab-close-right", actionTabCloseRight, null),
        .init("gx-tab-duplicate", actionTabDuplicate, null),
        .init("gx-tab-move-window", actionTabMoveWindow, null),
        .initStateful("gx-tab-pin", actionTabPin, null, glib.Variant.newBoolean(0)),
        .init("gx-zoom-out", actionView, null),
        .init("gx-zoom-reset", actionView, null),
        .init("gx-zoom-in", actionView, null),
        .init("gx-fullscreen", actionView, null),
        .init("gx-find", actionView, null),
    });
    _ = adw.TabView.signals.setup_menu.connect(window.getTabView(), *Window, setupTabMenu, window, .{});
    object.setData(actions_key, @ptrFromInt(1));
    setupTabMenu(window.getTabView(), null, window);
}

fn setupTabMenu(view: *adw.TabView, page: ?*adw.TabPage, window: *Window) callconv(.c) void {
    window.as(gobject.Object).setDataFull(context_page_key, if (page) |p| p.as(gobject.Object).ref() else null, &unrefObject);
    const present = page != null;
    const pinned = if (page) |p| p.getPinned() != 0 else false;
    const position = if (page) |p| view.getPagePosition(p) else -1;
    setEnabled(window, "gx-tab-close", present);
    setEnabled(window, "gx-tab-close-others", present and view.getNPages() - view.getNPinnedPages() > @as(c_int, if (pinned) 0 else 1));
    setEnabled(window, "gx-tab-close-right", present and @max(position + 1, view.getNPinnedPages()) < view.getNPages());
    setEnabled(window, "gx-tab-duplicate", present);
    setEnabled(window, "gx-tab-move-window", present and view.getNPages() > 1);
    setEnabled(window, "gx-tab-pin", present);
    const action = simpleAction(window, "gx-tab-pin") orelse return;
    action.setState(glib.Variant.newBoolean(@intFromBool(pinned)));
}

fn simpleAction(window: *Window, name: [:0]const u8) ?*gio.SimpleAction {
    return gobject.ext.cast(gio.SimpleAction, window.as(gio.ActionMap).lookupAction(name) orelse return null);
}

fn setEnabled(window: *Window, name: [:0]const u8, enabled: bool) void {
    const action = simpleAction(window, name) orelse return;
    action.setEnabled(@intFromBool(enabled));
}

fn contextPage(window: *Window) ?*adw.TabPage {
    const data = window.as(gobject.Object).getData(context_page_key) orelse return null;
    const page: *adw.TabPage = @ptrCast(@alignCast(data));
    const view = window.getTabView();
    var i: c_int = 0;
    while (i < view.getNPages()) : (i += 1) {
        if (view.getNthPage(i) == page) return page;
    }
    return null;
}

fn actionTabClose(_: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    window.getTabView().closePage(contextPage(window) orelse return);
}

fn actionTabCloseOthers(_: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    closeOtherTabs(window.getTabView(), contextPage(window) orelse return);
}

/// "Close Other Tabs": asks to close every unpinned tab other than `keep`.
/// Pinned tabs are not other tabs (R3-Window.01), like the menu item that
/// counts only unpinned tabs. `closeOtherPages` would close them, because
/// the window confirms every close request. Going from the last tab keeps
/// the positions still to visit valid while tabs close.
pub fn closeOtherTabs(view: *adw.TabView, keep: *adw.TabPage) void {
    var i = view.getNPages();
    while (i > 0) {
        i -= 1;
        const page = view.getNthPage(i);
        if (page != keep and page.getPinned() == 0) view.closePage(page);
    }
}

fn actionTabCloseRight(_: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    closeTabsRight(window.getTabView(), contextPage(window) orelse return);
}

/// "Close Tabs to the Right": asks to close the unpinned tabs after
/// `page`. Pinned tabs stay, like with "Close Other Tabs" (D-21), and like
/// the menu item that counts only the unpinned tabs to the right; pinned
/// tabs come first, so from a pinned tab the later pinned ones stay.
/// `closePagesAfter` would close them, because the window confirms every
/// close request.
pub fn closeTabsRight(view: *adw.TabView, page: *adw.TabPage) void {
    const first = view.getPagePosition(page) + 1;
    var i = view.getNPages();
    while (i > first) {
        i -= 1;
        const other = view.getNthPage(i);
        if (other.getPinned() == 0) view.closePage(other);
    }
}

fn actionTabDuplicate(_: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    const page = contextPage(window) orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    const surface = tab.getActiveSurface() orelse return;
    window.newTab(surface.core(), .none);
}

fn actionTabMoveWindow(_: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    const page = contextPage(window) orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    _ = window.moveTabToNewWindow(tab.getActiveSurface() orelse return);
}

fn actionTabPin(action: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    const page = contextPage(window) orelse return;
    const pinned = page.getPinned() == 0;
    window.getTabView().setPagePinned(page, @intFromBool(pinned));
    action.setState(glib.Variant.newBoolean(@intFromBool(pinned)));
}

fn actionView(action: *gio.SimpleAction, _: ?*glib.Variant, window: *Window) callconv(.c) void {
    const name = std.mem.span(action.as(gio.Action).getName());
    const binding: input.Binding.Action = if (std.mem.eql(u8, name, "gx-zoom-out"))
        .{ .decrease_font_size = 1 }
    else if (std.mem.eql(u8, name, "gx-zoom-in"))
        .{ .increase_font_size = 1 }
    else if (std.mem.eql(u8, name, "gx-zoom-reset"))
        .reset_font_size
    else if (std.mem.eql(u8, name, "gx-fullscreen"))
        .toggle_fullscreen
    else
        .start_search;
    const surface = window.getActiveSurface() orelse return;
    const core = surface.core() orelse return;
    _ = core.performBindingAction(binding) catch |err| log.warn("cannot perform view action err={}", .{err});
}

fn addViewControls(popover: *gtk.PopoverMenu) void {
    if (popover.as(gobject.Object).getData(controls_key) != null) return;
    const box = gtk.Box.new(.horizontal, 6);
    _ = box.as(gobject.Object).refSink();
    box.as(gtk.Widget).setMarginStart(6);
    box.as(gtk.Widget).setMarginEnd(6);
    const controls = [_]struct { action: [:0]const u8, label: ?[:0]const u8 = null, icon: ?[:0]const u8 = null, title: [:0]const u8 }{
        .{ .action = "win.gx-zoom-out", .label = "−", .title = tr("Zoom Out") },
        .{ .action = "win.gx-zoom-reset", .label = tr("Reset Zoom"), .title = tr("Reset Zoom") },
        .{ .action = "win.gx-zoom-in", .label = "+", .title = tr("Zoom In") },
        .{ .action = "win.gx-find", .icon = "edit-find-symbolic", .title = tr("Find…") },
        .{ .action = "win.gx-fullscreen", .icon = "view-fullscreen-symbolic", .title = tr("Full Screen") },
    };
    for (controls) |control| {
        const button = if (control.label) |label| gtk.Button.newWithLabel(label) else gtk.Button.newFromIconName(control.icon.?);
        button.as(gtk.Widget).setTooltipText(control.title);
        button.as(gtk.Widget).setHexpand(1);
        button.as(gtk.Actionable).setActionName(control.action);
        box.append(button.as(gtk.Widget));
    }
    if (popover.addChild(box.as(gtk.Widget), menus.view_controls) != 0) {
        popover.as(gobject.Object).setDataFull(controls_key, box, &unrefObject);
    } else {
        box.unref();
    }
}

fn removeViewControls(popover: *gtk.PopoverMenu) void {
    const data = popover.as(gobject.Object).getData(controls_key) orelse return;
    _ = popover.removeChild(@ptrCast(@alignCast(data)));
    popover.as(gobject.Object).setDataFull(controls_key, null, null);
}

fn warnMissingHan(window: *Window, app: *Application) void {
    if (gx.i18n.current() != .zh_CN) return;
    const object = app.as(gobject.Object);
    if (object.getData("gx-han-font-checked") != null) return;
    object.setData("gx-han-font-checked", @ptrFromInt(1));
    if (language.hanGlyphAvailable(window.as(gtk.Widget))) return;
    log.warn("Chinese glyphs are missing; install fonts-noto-cjk", .{});
    toast(window, tr("Chinese glyphs are missing. Install fonts-noto-cjk to display the Chinese interface."));
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
const Header = struct {
    /// Whether visiting a button translates its tooltip, which `sync` does
    /// when the language changes; opening a menu only looks it up.
    translate: bool = true,
    menu_buttons: Widgets(gtk.MenuButton) = .{},
    split_buttons: Widgets(adw.SplitButton) = .{},

    /// Returns whether to visit the children of `widget`.
    fn visit(self: *Header, widget: *gtk.Widget) bool {
        if (gobject.ext.cast(adw.SplitButton, widget)) |button| {
            if (self.translate) {
                widget.setTooltipText(tr("New Tab"));
                button.setDropdownTooltip(tr("Launch Profiles and Splits"));
            }
            self.split_buttons.add(button);
            return false;
        }
        if (gobject.ext.cast(gtk.MenuButton, widget)) |button| {
            if (iconIs(button.getIconName(), "open-menu-symbolic")) {
                if (self.translate) widget.setTooltipText(tr("Main Menu"));
                self.menu_buttons.add(button);
            }
            return false;
        }
        if (gobject.ext.cast(gtk.ToggleButton, widget)) |button| {
            if (self.translate and iconIs(button.as(gtk.Button).getIconName(), "view-grid-symbolic")) {
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

pub fn toast(window: *Window, title: [:0]const u8) void {
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
    pointAtTopRight(popover.as(gtk.Popover));
    popover.as(gtk.Popover).popup();
}

/// Points `popover` at the top right corner of the terminal it belongs to.
fn pointAtTopRight(popover: *gtk.Popover) void {
    const anchor = popover.as(gtk.Widget).getParent() orelse popover.as(gtk.Widget);
    const rect: gdk.Rectangle = .{
        .f_x = @max(anchor.getWidth() - 1, 0),
        .f_y = 0,
        .f_width = 1,
        .f_height = 1,
    };
    popover.setPointingTo(&rect);
}

fn restoreContextMenu(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
    const data = popover.as(gobject.Object).stealData(restore_key) orelse return;
    const context: *gio.MenuModel = @ptrCast(@alignCast(data));
    defer context.unref();
    const menu = gobject.ext.cast(gtk.PopoverMenu, popover) orelse return;
    removeViewControls(menu);
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

test "menuTrigger shows performable GX shortcuts without adding them to the reverse map" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var keybinds: configpkg.Config.Keybinds = .{};
    const action: input.Binding.Action = .{ .gx = .keybinds };
    try keybinds.parseCLI(arena.allocator(), "performable:ctrl+shift+slash=gx:keybinds");
    try testing.expectEqual(@as(?input.Binding.Trigger, null), keybinds.set.getTrigger(action));
    var expected: configpkg.Config.Keybinds = .{};
    try expected.parseCLI(arena.allocator(), "ctrl+shift+slash=gx:keybinds");
    try testing.expect(menuTrigger(&keybinds.set, action).?.equal(expected.set.getTrigger(action).?));
    try testing.expectEqual(@as(?input.Binding.Trigger, null), keybinds.set.getTrigger(action));
    try keybinds.parseCLI(arena.allocator(), "ctrl+alt+k=gx:keybinds");
    try testing.expect(menuTrigger(&keybinds.set, action).?.equal(keybinds.set.getTrigger(action).?));
}

test "close other tabs keeps the pinned tabs and the context tab" {
    const testing = std.testing;
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const view = adw.TabView.new();
    _ = view.as(gobject.Object).refSink();
    defer view.as(gobject.Object).unref();
    // The window confirms every close request, pinned or not
    // (`Window.tabViewClosePage` without a running program).
    _ = adw.TabView.signals.close_page.connect(view, ?*anyopaque, testConfirmClose, null, .{});

    var pages: [6]*adw.TabPage = undefined;
    for (&pages) |*page| {
        page.* = view.append(gtk.Label.new(null).as(gtk.Widget));
        _ = page.*.as(gobject.Object).ref();
    }
    defer for (pages) |page| page.as(gobject.Object).unref();
    view.setPagePinned(pages[2], 1);
    view.setPagePinned(pages[4], 1);

    // From an unpinned tab: the pinned tabs stay.
    closeOtherTabs(view, pages[3]);
    try testing.expectEqual(@as(c_int, 3), view.getNPages());
    for ([_]*adw.TabPage{ pages[2], pages[4], pages[3] }) |page| try testing.expect(view.getPagePosition(page) >= 0);

    // From a pinned tab: only the unpinned tabs close.
    _ = view.append(gtk.Label.new(null).as(gtk.Widget));
    closeOtherTabs(view, pages[4]);
    try testing.expectEqual(@as(c_int, 2), view.getNPages());
    for ([_]*adw.TabPage{ pages[2], pages[4] }) |page| try testing.expect(view.getPagePosition(page) >= 0);
}

test "close tabs to the right keeps the pinned tabs" {
    const testing = std.testing;
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const view = adw.TabView.new();
    _ = view.as(gobject.Object).refSink();
    defer view.as(gobject.Object).unref();
    _ = adw.TabView.signals.close_page.connect(view, ?*anyopaque, testConfirmClose, null, .{});

    var pages: [6]*adw.TabPage = undefined;
    for (&pages) |*page| {
        page.* = view.append(gtk.Label.new(null).as(gtk.Widget));
        _ = page.*.as(gobject.Object).ref();
    }
    defer for (pages) |page| page.as(gobject.Object).unref();
    // Three pinned tabs first: 0, 1 and 2, then the unpinned 3, 4 and 5.
    for (pages[0..3]) |page| view.setPagePinned(page, 1);

    // From the first pinned tab: the later pinned tabs stay, only the
    // unpinned ones close.
    _ = view.append(gtk.Label.new(null).as(gtk.Widget));
    closeTabsRight(view, pages[0]);
    try testing.expectEqual(@as(c_int, 3), view.getNPages());
    for (pages[0..3], 0..) |page, i| try testing.expectEqual(@as(c_int, @intCast(i)), view.getPagePosition(page));

    // From an unpinned tab: only the tabs after it close.
    const kept = view.append(gtk.Label.new(null).as(gtk.Widget));
    _ = view.append(gtk.Label.new(null).as(gtk.Widget));
    _ = view.append(gtk.Label.new(null).as(gtk.Widget));
    closeTabsRight(view, kept);
    try testing.expectEqual(@as(c_int, 4), view.getNPages());
    try testing.expectEqual(@as(c_int, 3), view.getPagePosition(kept));
}

fn testConfirmClose(view: *adw.TabView, page: *adw.TabPage, _: ?*anyopaque) callconv(.c) c_int {
    view.closePageFinish(page, 1);
    return 1;
}

test "menuTrigger never advertises a key sequence as a single menu accelerator" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var keybinds: configpkg.Config.Keybinds = .{};
    try keybinds.parseCLI(arena.allocator(), "ctrl+x>ctrl+k=gx:keybinds");
    try testing.expectEqual(@as(?input.Binding.Trigger, null), menuTrigger(&keybinds.set, .{ .gx = .keybinds }));
}
