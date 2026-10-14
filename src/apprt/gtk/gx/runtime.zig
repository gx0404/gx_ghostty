//! GUI-thread identities. Qdata owns records; lookups walk live GTK objects.
//! References do not keep objects alive. Returned pointers are borrowed only
//! for the current non-reentrant GUI operation; resolve again after a modal call.
const std = @import("std");
const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const refs = @import("../../../gx/ui_ref.zig");
const ext = @import("../ext.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const Tab = @import("../class/tab.zig").Tab;
const Surface = @import("../class/surface.zig").Surface;
const state_key = "gx-ui-runtime";
const record_key = "gx-ui-record";
const stopped_key = "gx-ui-runtime-stopped";
const disposed_key = "gx-ui-record-disposed";
const log = std.log.scoped(.gtk_gx_runtime);

const State = struct {
    alloc: std.mem.Allocator,
    issuer: refs.Issuer,
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data orelse return));
        self.alloc.destroy(self);
    }
};
const Record = struct {
    alloc: std.mem.Allocator,
    reference: refs.Reference,
    view: refs.Attachment = .{},
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Record = @ptrCast(@alignCast(data orelse return));
        self.alloc.destroy(self);
    }
};

fn state(app: *Application) !*State {
    const object = app.as(gobject.Object);
    if (object.getData(stopped_key) != null) return error.InvalidEpoch;
    if (object.getData(state_key)) |data| return @ptrCast(@alignCast(data));
    const alloc = app.allocator();
    const value = try alloc.create(State);
    errdefer alloc.destroy(value);
    const rng: std.Random.IoSource = .{ .io = global.io() };
    var epoch: refs.HostEpoch = 0;
    while (epoch == 0) epoch = rng.interface().int(refs.HostEpoch);
    value.* = .{ .alloc = alloc, .issuer = try refs.Issuer.init(epoch) };
    object.setDataFull(state_key, value, &State.destroy);
    return value;
}

fn record(object: *gobject.Object) ?*Record {
    if (object.getData(disposed_key) != null) return null;
    const data = object.getData(record_key) orelse return null;
    return @ptrCast(@alignCast(data));
}

fn create(object: *gobject.Object, kind: refs.Kind, core_id: u64) !void {
    if (record(object) != null) return;
    if (object.getData(disposed_key) != null) return error.InvalidReference;
    const value = try state(Application.default());
    const item = try value.alloc.create(Record);
    errdefer value.alloc.destroy(item);
    item.* = .{
        .alloc = value.alloc,
        .reference = if (kind == .surface) try value.issuer.surface(core_id) else try value.issuer.create(kind),
    };
    object.setDataFull(record_key, item, &Record.destroy);
}

pub fn reference(object: *gobject.Object) refs.Reference {
    return if (record(object)) |value| value.reference else .{};
}

pub fn attachment(object: *gobject.Object) refs.Attachment {
    return if (record(object)) |value| value.view else .{};
}

/// Called before template disposal; strong refs held by dialogs cannot revive it.
pub fn dispose(object: *gobject.Object) void {
    if (record(object)) |value| {
        value.reference = .{};
        value.view = .{};
    }
    object.setData(disposed_key, @ptrFromInt(1));
}

pub fn shutdown(app: *Application) void {
    const object = app.as(gobject.Object);
    if (object.getData(state_key)) |data| {
        const value: *State = @ptrCast(@alignCast(data));
        value.issuer.epoch = 0;
    }
    object.setData(stopped_key, @ptrFromInt(1));
    // Application.deinit may run without GObject finalization.
    object.setDataFull(state_key, null, null);
}

fn syncObject(object: *gobject.Object, owner: *Window, visible: bool) void {
    const item = record(object) orelse return;
    // A late detach from an old owner must not revoke the newly attached view.
    if (!visible and item.view.isValid() and !item.view.owner.matches(reference(owner.as(gobject.Object)))) return;
    const value = state(Application.default()) catch {
        item.view = .{};
        return;
    };
    item.view.setVisible(&value.issuer, item.reference, reference(owner.as(gobject.Object)), visible) catch {
        item.view = .{};
    };
}

pub fn windowInitialized(window: *Window) void {
    create(window.as(gobject.Object), .window, 0) catch |err| {
        log.err("cannot issue window identity: {}", .{err});
        return;
    };
    _ = gtk.Widget.signals.map.connect(window.as(gtk.Widget), *Window, windowMapped, window, .{});
    _ = gtk.Widget.signals.unmap.connect(window.as(gtk.Widget), *Window, windowUnmapped, window, .{});
}

fn windowMapped(_: *gtk.Widget, window: *Window) callconv(.c) void {
    syncWindow(window, true);
}
fn windowUnmapped(_: *gtk.Widget, window: *Window) callconv(.c) void {
    syncWindow(window, false);
}
fn syncWindow(window: *Window, visible: bool) void {
    syncObject(window.as(gobject.Object), window, visible);
    const tabs = window.getTabView();
    var i: c_int = 0;
    while (i < tabs.getNPages()) : (i += 1) {
        const tab = gobject.ext.cast(Tab, tabs.getNthPage(i).getChild()) orelse continue;
        syncTab(window, tab, visible);
    }
}
fn syncTab(window: *Window, tab: *Tab, visible: bool) void {
    syncObject(tab.as(gobject.Object), window, visible and tab.as(gtk.Widget).getMapped() != 0);
    const tree = tab.getSurfaceTree() orelse return;
    var it = tree.iterator();
    while (it.next()) |entry| syncObject(entry.view.as(gobject.Object), window, visible and entry.view.getMapped());
}

/// Reserve tab identity before a transfer changes either tree.
pub fn prepareTab(tab: *Tab) !void {
    const exists = record(tab.as(gobject.Object)) != null;
    try create(tab.as(gobject.Object), .tab, 0);
    if (!exists) {
        _ = gtk.Widget.signals.map.connect(tab.as(gtk.Widget), *Tab, tabMapped, tab, .{});
        _ = gtk.Widget.signals.unmap.connect(tab.as(gtk.Widget), *Tab, tabUnmapped, tab, .{});
    }
}
fn tabMapped(_: *gtk.Widget, tab: *Tab) callconv(.c) void {
    const window = ext.getAncestor(Window, tab.as(gtk.Widget)) orelse return;
    syncTab(window, tab, window.as(gtk.Widget).getMapped() != 0);
}
fn tabUnmapped(_: *gtk.Widget, tab: *Tab) callconv(.c) void {
    if (ext.getAncestor(Window, tab.as(gtk.Widget))) |window| {
        syncTab(window, tab, false);
    } else if (record(tab.as(gobject.Object))) |value| value.view = .{};
}

pub fn tabAttached(window: *Window, tab: *Tab) void {
    prepareTab(tab) catch |err| {
        log.err("cannot issue tab identity: {}", .{err});
        return;
    };
    syncTab(window, tab, window.as(gtk.Widget).getMapped() != 0);
}

pub fn tabDetached(window: *Window, tab: *Tab) void {
    syncTab(window, tab, false);
}

/// Fails before the newly initialized core surface is published.
pub fn prepareSurface(surface: *Surface, core_id: u64) !void {
    const exists = record(surface.as(gobject.Object)) != null;
    try create(surface.as(gobject.Object), .surface, core_id);
    if (!exists) _ = gobject.Object.signals.notify.connect(surface, *Surface, surfaceMapped, surface, .{ .detail = "mapped" });
}
fn surfaceMapped(_: *Surface, _: *gobject.ParamSpec, surface: *Surface) callconv(.c) void {
    const window = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse {
        if (record(surface.as(gobject.Object))) |value| value.view = .{};
        return;
    };
    surfaceAttached(window, surface);
}

pub fn surfaceAttached(window: *Window, surface: *Surface) void {
    syncObject(surface.as(gobject.Object), window, window.as(gtk.Widget).getMapped() != 0 and surface.getMapped());
}

pub fn surfaceDetached(window: *Window, surface: *Surface) void {
    syncObject(surface.as(gobject.Object), window, false);
}

pub fn surfaceInitialized(surface: *Surface) void {
    const window = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse return;
    surfaceAttached(window, surface);
}

fn accepts(app: *Application, value: refs.Reference, kind: refs.Kind) bool {
    if (!value.isValid() or value.kind != kind) return false;
    const object = app.as(gobject.Object);
    if (object.getData(stopped_key) != null) return false;
    const data = object.getData(state_key) orelse return false;
    const live: *State = @ptrCast(@alignCast(data));
    return value.epoch == live.issuer.epoch;
}

pub fn resolveWindow(app: *Application, value: refs.Reference) ?*Window {
    if (!accepts(app, value, .window)) return null;
    var cursor: ?*glib.List = app.as(gtk.Application).getWindows();
    while (cursor) |node| : (cursor = node.f_next) {
        const object: *gobject.Object = @ptrCast(@alignCast(node.f_data orelse continue));
        const window = gobject.ext.cast(Window, object) orelse continue;
        if (value.matches(reference(object))) return window;
    }
    return null;
}

pub fn resolveTab(app: *Application, value: refs.Reference) ?*Tab {
    if (!accepts(app, value, .tab)) return null;
    var cursor: ?*glib.List = app.as(gtk.Application).getWindows();
    while (cursor) |node| : (cursor = node.f_next) {
        const object: *gobject.Object = @ptrCast(@alignCast(node.f_data orelse continue));
        const window = gobject.ext.cast(Window, object) orelse continue;
        if (!reference(object).isValid()) continue;
        const tabs = window.getTabView();
        var i: c_int = 0;
        while (i < tabs.getNPages()) : (i += 1) {
            const tab = gobject.ext.cast(Tab, tabs.getNthPage(i).getChild()) orelse continue;
            if (value.matches(reference(tab.as(gobject.Object)))) return tab;
        }
    }
    return null;
}

pub fn resolveSurface(app: *Application, value: refs.Reference) ?*Surface {
    if (!accepts(app, value, .surface)) return null;
    const core = app.core().findSurfaceByID(value.id) orelse return null;
    const surface = core.rt_surface.surface;
    return if (value.matches(reference(surface.as(gobject.Object)))) surface else null;
}

pub fn resolveSurfaceView(app: *Application, value: refs.Attachment) ?*Surface {
    if (!value.isValid()) return null;
    const owner = resolveWindow(app, value.owner) orelse return null;
    if (owner.as(gtk.Widget).getMapped() == 0) return null;
    const surface = resolveSurface(app, value.object) orelse return null;
    if (!surface.getMapped()) return null;
    if (surface.as(gtk.Widget).getMapped() == 0) return null;
    if (!value.matches(attachment(surface.as(gobject.Object)))) return null;
    if (ext.getAncestor(Window, surface.as(gtk.Widget)) != owner) return null;
    return surface;
}

/// Resolves any view while checking both its current owner and its lease.
pub fn resolveView(app: *Application, value: refs.Attachment) ?*gobject.Object {
    if (!value.isValid()) return null;
    const owner = resolveWindow(app, value.owner) orelse return null;
    if (owner.as(gtk.Widget).getMapped() == 0) return null;
    const object = switch (value.object.kind) {
        .window => (resolveWindow(app, value.object) orelse return null).as(gobject.Object),
        .tab => tab: {
            const tab = resolveTab(app, value.object) orelse return null;
            if (tab.as(gtk.Widget).getMapped() == 0 or ext.getAncestor(Window, tab.as(gtk.Widget)) != owner) return null;
            break :tab tab.as(gobject.Object);
        },
        .surface => (resolveSurfaceView(app, value) orelse return null).as(gobject.Object),
    };
    if (!value.matches(attachment(object))) return null;
    return object;
}

test "runtime lookup and lifecycle entrypoints compile" {
    const functions = .{ &resolveWindow, &resolveTab, &resolveSurface, &resolveSurfaceView, &resolveView, &windowInitialized, &prepareSurface, &tabAttached, &tabDetached, &dispose, &shutdown };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}
