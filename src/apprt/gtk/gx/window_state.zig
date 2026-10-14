//! GTK logical geometry, sampled from the real GdkSurface and saved only on
//! accepted close/quit. Never stores screen coordinates or edits configuration.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const global = @import("../../../global.zig");
const Config = @import("../../../config/Config.zig");
const storage = @import("../../../gx/window_state.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const record_key = "gx-window-geometry";
const quitting_key = "gx-window-geometry-quitting";
const log = std.log.scoped(.gtk_gx_window_state);

const Flags = struct { maximized: bool = false, fullscreen: bool = false, tiled: bool = false, minimized: bool = false };

pub const Tracker = struct {
    normal: ?storage.Size = null,
    maximized: bool = false,
    shown: bool = false,

    fn capture(self: *Tracker, size: storage.Size, is_mapped: bool, flags: Flags) void {
        if (!is_mapped) return;
        self.shown = true;
        if (flags.minimized) return;
        if (!flags.fullscreen) self.maximized = flags.maximized;
        if (flags.maximized or flags.fullscreen or flags.tiled or flags.minimized) return;
        if (size.width >= 64 and size.height >= 64) self.normal = size;
    }

    fn snapshot(self: Tracker) ?storage.State {
        if (!self.shown) return null;
        return .{ .size = self.normal orelse return null, .dpi = storage.base_dpi, .maximized = self.maximized };
    }
};

const Record = struct {
    alloc: std.mem.Allocator,
    tracker: Tracker = .{},
    surface: WeakRef(gdk.Surface) = .empty,
    surface_handlers: [3]c_ulong = .{ 0, 0, 0 },
    sample_source: ?c_uint = null,
    restore_decided: bool = false,
    restored: ?storage.State = null,
    closed: bool = false,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Record = @ptrCast(@alignCast(data orelse return));
        if (self.sample_source) |source| _ = glib.Source.remove(source);
        self.surface.deinit();
        self.alloc.destroy(self);
    }
};

fn record(window: *Window) ?*Record {
    const data = window.as(gobject.Object).getData(record_key) orelse return null;
    return @ptrCast(@alignCast(data));
}

pub fn install(window: *Window) void {
    if (record(window) != null) return;
    const alloc = Application.default().allocator();
    const value = alloc.create(Record) catch return;
    value.* = .{ .alloc = alloc };
    window.as(gobject.Object).setDataFull(record_key, value, &Record.destroy);
    _ = gtk.Widget.signals.realize.connect(window.as(gtk.Widget), *Window, realized, window, .{});
    _ = gtk.Widget.signals.map.connect(window.as(gtk.Widget), *Window, mapped, window, .{});
}

fn realized(_: *gtk.Widget, window: *Window) callconv(.c) void {
    const value = record(window) orelse return;
    const surface = window.as(gtk.Native).getSurface() orelse return;
    detachSurface(value, window);
    value.surface.set(surface);
    inline for (.{ "width", "height", "state" }, 0..) |detail, index| {
        value.surface_handlers[index] = gobject.Object.signals.notify.connect(surface, *Window, dimensionsChanged, window, .{ .detail = detail });
    }
}

fn mapped(_: *gtk.Widget, window: *Window) callconv(.c) void {
    if (record(window)) |value| value.tracker.shown = !window.isQuickTerminal();
    schedule(window);
}
fn dimensionsChanged(_: *gdk.Surface, _: *gobject.ParamSpec, window: *Window) callconv(.c) void {
    schedule(window);
}
fn schedule(window: *Window) void {
    const value = record(window) orelse return;
    if (value.closed or window.isQuickTerminal()) return;
    if (value.sample_source == null) value.sample_source = glib.idleAdd(sampleIdle, window);
}
fn sampleIdle(data: ?*anyopaque) callconv(.c) c_int {
    const window: *Window = @ptrCast(@alignCast(data orelse return 0));
    const value = record(window) orelse return 0;
    value.sample_source = null;
    sample(window, value);
    return 0;
}
fn sample(window: *Window, value: *Record) void {
    if (value.closed or window.isQuickTerminal()) return;
    const surface = window.as(gtk.Native).getSurface() orelse return;
    const toplevel = gobject.ext.cast(gdk.Toplevel, surface) orelse return;
    const state = toplevel.getState();
    value.tracker.capture(.{ .width = surface.getWidth(), .height = surface.getHeight() }, window.as(gtk.Widget).getMapped() != 0, .{
        .maximized = state.maximized or window.as(gtk.Window).isMaximized() != 0,
        .fullscreen = state.fullscreen or window.as(gtk.Window).isFullscreen() != 0,
        .tiled = state.tiled,
        .minimized = state.minimized,
    });
}

/// Called after each upstream initial sizing pass (estimate and surface init).
/// The decision/file are cached; a late initial sizing pass cannot erase restore.
pub fn restore(window: *Window) void {
    const value = record(window) orelse return;
    if (value.closed or window.isQuickTerminal()) return;
    const config = window.getConfig() orelse return;
    const cfg = config.get();
    var width: c_int = 0;
    var height: c_int = 0;
    window.as(gtk.Window).getDefaultSize(&width, &height);
    if (value.tracker.normal == null and width >= 64 and height >= 64) value.tracker.normal = .{ .width = width, .height = height };
    if (!value.restore_decided) {
        value.restore_decided = true;
        if (cfg.@"window-save-state" == .never or hasOtherOrdinary(window)) return;
        const path = storage.defaultPath(value.alloc) catch return;
        defer value.alloc.free(path);
        value.restored = storage.load(value.alloc, global.io(), path) catch |err| {
            log.warn("cannot read window geometry: {}", .{err});
            return;
        };
    }
    const saved = value.restored orelse return;
    const size = restoredSize(cfg, .{ .width = width, .height = height }, saved.size);
    window.as(gtk.Window).setDefaultSize(size.width, size.height);
    // Keep a normal size available when the first frame opens maximized.
    if (size.width >= 64 and size.height >= 64) value.tracker.normal = size;
    if (restoreMaximized(cfg) and saved.maximized) {
        value.tracker.maximized = true;
        window.as(gtk.Window).maximize();
    }
}

fn restoredSize(config: *const Config, initial: storage.Size, saved: storage.Size) storage.Size {
    if (config.@"window-save-state" == .never) return initial;
    return .{
        .width = if (config.@"window-width" == 0) saved.width else initial.width,
        .height = if (config.@"window-height" == 0) saved.height else initial.height,
    };
}

pub fn restoreMaximized(config: *const Config) bool {
    if (config.@"window-save-state" == .never or config.maximize or config.fullscreen != .false) return false;
    // Explicit false is also an instruction. Only scan configuration arguments;
    // tokens after -e belong to the child and must not influence this decision.
    for (config._replay_steps.items) |step| switch (step) {
        .@"-e" => break,
        .arg => |arg| {
            const text = std.mem.trimStart(u8, arg, "-");
            const key = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
            if (std.mem.eql(u8, key, "maximize") or std.mem.eql(u8, key, "fullscreen")) return false;
        },
        else => {},
    };
    return true;
}

fn hasOtherOrdinary(window: *Window) bool {
    var cursor: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (cursor) |node| : (cursor = node.f_next) {
        const object: *gobject.Object = @ptrCast(@alignCast(node.f_data orelse continue));
        const other = gobject.ext.cast(Window, object) orelse continue;
        if (other == window or other.isQuickTerminal()) continue;
        if (record(other)) |value| {
            if (value.closed) continue;
        }
        // Hidden staged transfer windows have not participated in the desktop.
        if (other.as(gtk.Widget).getVisible() != 0) return true;
    }
    return false;
}

fn save(window: *Window, value: *Record) void {
    if (window.isQuickTerminal()) return;
    const config = window.getConfig() orelse return;
    if (config.get().@"window-save-state" == .never) return;
    const saved_state = value.tracker.snapshot() orelse return;
    const path = storage.defaultPath(value.alloc) catch return;
    defer value.alloc.free(path);
    storage.save(global.io(), path, saved_state) catch |err| log.warn("cannot save window geometry: {}", .{err});
}

/// Must be called only after close confirmation succeeds, before gtk.destroy.
pub fn closing(window: *Window) void {
    const value = record(window) orelse return;
    if (value.closed) return;
    sample(window, value);
    if (Application.default().as(gobject.Object).getData(quitting_key) == null and !hasOtherOrdinary(window)) save(window, value);
    value.closed = true;
}

/// A confirmed app quit snapshots the active ordinary window once; destruction
/// order of the remaining windows cannot overwrite that choice.
pub fn quit(app: *Application) void {
    const object = app.as(gobject.Object);
    if (object.getData(quitting_key) != null) return;
    object.setData(quitting_key, @ptrFromInt(1));
    var chosen: ?*Window = null;
    if (app.as(gtk.Application).getActiveWindow()) |active| {
        if (gobject.ext.cast(Window, active)) |window| if (!window.isQuickTerminal()) {
            chosen = window;
        };
    }
    if (chosen == null) {
        var cursor: ?*glib.List = app.as(gtk.Application).getWindows();
        while (cursor) |node| : (cursor = node.f_next) {
            const candidate: *gobject.Object = @ptrCast(@alignCast(node.f_data orelse continue));
            const window = gobject.ext.cast(Window, candidate) orelse continue;
            if (window.isQuickTerminal()) continue;
            const value = record(window) orelse continue;
            if (value.closed or !value.tracker.shown) continue;
            chosen = window;
            break;
        }
    }
    const window = chosen orelse return;
    const value = record(window) orelse return;
    sample(window, value);
    save(window, value);
}

fn detachSurface(value: *Record, window: *Window) void {
    _ = window;
    if (value.surface.get()) |surface| {
        defer surface.unref();
        for (value.surface_handlers) |handler| if (handler != 0) {
            gobject.signalHandlerDisconnect(surface.as(gobject.Object), handler);
        };
    }
    value.surface.set(null);
    value.surface_handlers = .{ 0, 0, 0 };
}

pub fn dispose(window: *Window) void {
    const value = record(window) orelse return;
    closing(window);
    if (value.sample_source) |source| {
        _ = glib.Source.remove(source);
        value.sample_source = null;
    }
    detachSurface(value, window);
}

test "normal geometry survives maximize fullscreen tile minimize and unmap" {
    const testing = std.testing;
    var tracker: Tracker = .{};
    try testing.expect(tracker.snapshot() == null);
    tracker.capture(.{ .width = 900, .height = 600 }, true, .{});
    tracker.capture(.{ .width = 1920, .height = 1080 }, true, .{ .maximized = true });
    try testing.expect(tracker.snapshot().?.maximized);
    try testing.expectEqual(@as(i32, 900), tracker.snapshot().?.size.width);
    tracker.capture(.{ .width = 1920, .height = 1080 }, true, .{ .fullscreen = true });
    try testing.expect(tracker.snapshot().?.maximized);
    tracker.capture(.{ .width = 960, .height = 1080 }, true, .{ .tiled = true });
    tracker.capture(.{ .width = 0, .height = 0 }, true, .{ .minimized = true });
    tracker.capture(.{ .width = 1, .height = 1 }, false, .{});
    try testing.expectEqual(storage.Size{ .width = 900, .height = 600 }, tracker.snapshot().?.size);
    try testing.expect(tracker.snapshot().?.position == null);
    try testing.expectEqual(storage.base_dpi, tracker.snapshot().?.dpi);
}

test "geometry restore respects each configured axis and never" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    const initial: storage.Size = .{ .width = 800, .height = 500 };
    const saved: storage.Size = .{ .width = 1100, .height = 700 };
    config.@"window-width" = 100;
    try testing.expectEqual(storage.Size{ .width = 800, .height = 700 }, restoredSize(&config, initial, saved));
    config.@"window-width" = 0;
    config.@"window-height" = 30;
    try testing.expectEqual(storage.Size{ .width = 1100, .height = 500 }, restoredSize(&config, initial, saved));
    config.@"window-save-state" = .never;
    try testing.expectEqual(initial, restoredSize(&config, initial, saved));
    try testing.expect(!restoreMaximized(&config));
}

test "geometry entrypoints compile" {
    const functions = .{ &install, &restore, &closing, &quit, &dispose };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}

test "explicit maximize false takes precedence over remembered maximization" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    try std.testing.expect(restoreMaximized(&config));
    var args = @import("../../../cli.zig").args.sliceIterator(&.{"--maximize=false"});
    try config.loadIter(std.testing.allocator, &args);
    try std.testing.expect(!restoreMaximized(&config));
}

/// Owned value for a session snapshot; coordinates remain absent on GTK.
pub fn snapshot(window: *Window) ?storage.State {
    const config = window.getConfig() orelse return null;
    if (config.get().@"window-save-state" == .never) return null;
    const value = record(window) orelse return null;
    sample(window, value);
    return value.tracker.snapshot();
}
