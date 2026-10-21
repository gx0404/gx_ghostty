//! GTK session lifecycle. The shared model owns the bounded disk contract;
//! this module snapshots only user state and resolves current trusted profiles.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const gobject = @import("gobject");
const glib = @import("glib");
const global = @import("../../../global.zig");
const model = @import("../../../gx/session.zig");
const state_file = @import("../../../gx/state_file.zig");
const Config = @import("../../../config/Config.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const Tab = @import("../class/tab.zig").Tab;
const Surface = @import("../class/surface.zig").Surface;
const Overrides = @import("../class/Overrides.zig");
const origin = @import("origin.zig");
const launch = @import("launch.zig");
const lifecycle = @import("tree_lifecycle.zig");
const geometry = @import("window_state.zig");
const tr = @import("../../../gx/i18n.zig").tr;
const log = std.log.scoped(.gtk_gx_session);
const key = "gx-session-runtime";
const closed_key = "gx-session-closed";
const seed_key = "gx-session-seed";
const geometry_key = "gx-session-geometry";
const failed_key = "gx-session-restore-failed";

const Cli = struct {
    explicit_launch: bool = false,
    font: bool = false,
    title: bool = false,
};
const Approval = struct { id: []const u8, signature: u64, allowed: bool };
const State = struct {
    alloc: std.mem.Allocator,
    app: *Application,
    store: ?model.Store = null,
    attempted: bool = false,
    blocked: bool = false,
    quitting: bool = false,
    restoring: bool = false,
    protect_file: bool = false,
    ready_pending: usize = 0,
    idle: ?c_uint = null,
    notice: ?[:0]const u8 = null,
    cli: Cli = .{},
    parsed: ?model.Parsed = null,
    approvals: std.ArrayList(Approval) = .empty,
    dialog: ?*adw.AlertDialog = null,
    dialog_handler: c_ulong = 0,
    asking: ?Approval = null,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data orelse return));
        self.quitting = true;
        if (self.idle) |idle| _ = glib.Source.remove(idle);
        if (self.dialog) |dialog| {
            if (self.dialog_handler != 0) gobject.signalHandlerDisconnect(dialog.as(gobject.Object), self.dialog_handler);
            dialog.as(adw.Dialog).forceClose();
            dialog.as(gobject.Object).unref();
        }
        if (self.parsed) |parsed| parsed.deinit();
        self.approvals.deinit(self.alloc);
        if (self.store) |*store| store.deinit();
        self.alloc.destroy(self);
    }
};

fn enabled(app: *Application) bool {
    const config = app.getConfig();
    defer config.unref();
    return config.get().@"gx-session-restore";
}
fn current(app: *Application) ?*State {
    const data = app.as(gobject.Object).getData(key) orelse return null;
    return @ptrCast(@alignCast(data));
}
fn obtain(app: *Application) !*State {
    if (current(app)) |value| return value;
    const alloc = app.allocator();
    const value = try alloc.create(State);
    errdefer alloc.destroy(value);
    value.* = .{ .alloc = alloc, .app = app, .cli = try readCli(alloc) };
    // State creation itself may have failed before the fallback window opened.
    // Preserve that failure across a later successful allocation/changed hook.
    inheritRestoreFailure(value, app.as(gobject.Object).getData(failed_key) != null);
    app.as(gobject.Object).setDataFull(key, value, &State.destroy);
    return value;
}
fn readCli(alloc: std.mem.Allocator) !Cli {
    var args = try @import("../../../cli.zig").args.argsIterator(alloc, global.args());
    defer args.deinit();
    var result: Cli = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e")) {
            result.explicit_launch = true;
            break;
        }
        const text = std.mem.trimStart(u8, arg, "-");
        const field = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
        if (std.mem.eql(u8, field, "command") or std.mem.eql(u8, field, "initial-command") or std.mem.eql(u8, field, "working-directory")) result.explicit_launch = true;
        if (std.mem.eql(u8, field, "font-size")) result.font = true;
        if (std.mem.eql(u8, field, "title")) result.title = true;
    }
    return result;
}
fn open(value: *State) !void {
    if (value.store != null) return;
    const path = try state_file.path(value.alloc, model.file_name);
    defer value.alloc.free(path);
    value.store = try model.Store.open(value.alloc, global.io(), path);
}

/// Returns true only when this first ordinary activation is handled by restore.
pub fn activate(app: *Application) bool {
    if (!enabled(app)) return false;
    const value = obtain(app) catch {
        app.as(gobject.Object).setData(failed_key, @ptrFromInt(1));
        return false;
    };
    if (value.attempted) return false;
    value.attempted = true;
    if (value.cli.explicit_launch or app.core().surfaces.items.len != 0) {
        value.protect_file = value.cli.explicit_launch;
        return false;
    }
    open(value) catch |err| {
        value.blocked = true;
        value.notice = loadFailure(err);
        return false;
    };
    value.parsed = value.store.?.load() catch |err| {
        value.blocked = true;
        value.notice = loadFailure(err);
        return false;
    };
    const parsed = value.parsed orelse return false;
    if (parsed.value.skipped_leaves > 0) value.notice = "Temporary and unknown launch commands are not restored.";
    if (parsed.value.windows.len == 0) {
        parsed.deinit();
        value.parsed = null;
        return false;
    }
    value.restoring = true;
    value.protect_file = true;
    continueRestore(value);
    return true;
}

fn loadFailure(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.WorkingDirectoryUnavailable => "A saved working directory is unavailable. The previous session was left unchanged.",
        error.Busy => "The session is already in use by another instance.",
        error.UnsupportedVersion => "The saved session format is not supported.",
        error.InvalidGeneration, error.LimitExceeded, error.InvalidTree, error.InvalidText, error.InvalidCwd, error.InvalidFontSize, error.InvalidGeometry, error.SyntaxError, error.UnexpectedToken, error.UnexpectedEndOfInput, error.MissingField, error.UnknownField, error.DuplicateField, error.InvalidNumber => "The saved session is damaged and was left unchanged.",
        else => "The previous session could not be restored.",
    };
}

fn signature(profile: launch.Item) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (profile.args) |arg| {
        hasher.update(arg);
        hasher.update(&.{0});
    }
    return hasher.final();
}
fn approved(value: *State, profile: launch.Item) ?bool {
    for (value.approvals.items) |approval| {
        if (std.mem.eql(u8, approval.id, profile.id) and approval.signature == signature(profile)) return approval.allowed;
    }
    return null;
}
fn continueRestore(value: *State) void {
    if (value.quitting) return;
    const config = value.app.getConfig();
    defer config.unref();
    var profiles = launch.list(value.app, config.get()) catch return restoreFailed(value);
    defer profiles.deinit();
    const document = value.parsed.?.value;
    for (document.windows) |window| for (window.tabs) |tab| for (tab.nodes) |node| {
        const leaf = node.leaf orelse continue;
        const profile = profiles.findId(leaf.profile_id) orelse continue;
        if (model.restoreDecision(profile.id, true) != .confirm_custom or approved(value, profile.*) != null) continue;
        const dialog = adw.AlertDialog.new(null, null);
        _ = dialog.as(gobject.Object).refSink();
        value.dialog = dialog;
        value.asking = .{ .id = leaf.profile_id, .signature = signature(profile.*), .allowed = false };
        dialog.setHeading(tr("Restore custom launch profile?"));
        const command = if (profile.args.len > 0) profile.args[0] else "";
        const body = value.alloc.printSentinel("{s}\n{s}\n\n{s}", .{ profile.name, command, tr("This profile runs its current configured command. Restore it for this session?") }, 0) catch return restoreFailed(value);
        defer value.alloc.free(body);
        dialog.setBody(body);
        dialog.addResponse("skip", tr("Skip"));
        dialog.addResponse("restore", tr("Restore"));
        dialog.setDefaultResponse("skip");
        dialog.setCloseResponse("skip");
        value.dialog_handler = adw.AlertDialog.signals.response.connect(dialog, *State, response, value, .{});
        dialog.as(adw.Dialog).present(null);
        return;
    };
    buildRestore(value, &profiles) catch return restoreFailed(value);
}
fn response(_: *adw.AlertDialog, response_id: [*:0]const u8, value: *State) callconv(.c) void {
    if (value.quitting) return;
    const dialog = value.dialog orelse return;
    value.dialog = null;
    value.dialog_handler = 0;
    defer dialog.as(gobject.Object).unref();
    var approval = value.asking orelse return;
    value.asking = null;
    approval.allowed = std.mem.eql(u8, std.mem.span(response_id), "restore");
    value.approvals.append(value.alloc, approval) catch return restoreFailed(value);
    continueRestore(value);
}
fn clearParsed(value: *State) void {
    if (value.parsed) |parsed| parsed.deinit();
    value.parsed = null;
    value.approvals.clearRetainingCapacity();
}
fn restoreFailed(value: *State) void {
    markRestoreFailure(value);
    if (value.dialog) |dialog| {
        if (value.dialog_handler != 0) gobject.signalHandlerDisconnect(dialog.as(gobject.Object), value.dialog_handler);
        value.dialog = null;
        value.dialog_handler = 0;
        dialog.as(adw.Dialog).forceClose();
        dialog.as(gobject.Object).unref();
    }
    clearParsed(value);
    value.app.gxNewWindow(null, .none) catch {};
}
fn markRestoreFailure(value: *State) void {
    // Closing the fallback window must never delete a document whose restore
    // failed (OOM, renderer/surface init, or invalid runtime geometry).
    value.blocked = true;
    value.restoring = false;
    value.protect_file = true;
    value.ready_pending = 0;
    value.notice = "The previous session could not be restored.";
}

fn inheritRestoreFailure(value: *State, failed: bool) void {
    if (!failed) return;
    markRestoreFailure(value);
    value.attempted = true;
}

const Seed = struct {
    alloc: std.mem.Allocator,
    font_size: ?f32,
    ready: bool = false,
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Seed = @ptrCast(@alignCast(data orelse return));
        self.alloc.destroy(self);
    }
};
fn setSeed(value: *State, surface: *Surface, font_size: ?f32) !void {
    const seed = try value.alloc.create(Seed);
    seed.* = .{ .alloc = value.alloc, .font_size = font_size };
    surface.as(gobject.Object).setDataFull(seed_key, seed, &Seed.destroy);
    value.ready_pending += 1;
}
/// Applied to the per-surface clone only, never to the global/user configuration.
pub fn applySeed(surface: *Surface, config: *Config) void {
    const data = surface.as(gobject.Object).getData(seed_key) orelse return;
    const seed: *Seed = @ptrCast(@alignCast(data));
    applyConfigSeed(config, seed.font_size);
}
fn applyConfigSeed(config: *Config, font_size: ?f32) void {
    config.@"initial-command" = null;
    if (font_size) |size| config.@"font-size" = size;
}
pub fn surfaceReady(surface: *Surface) void {
    defer changed(Application.default());
    const data = surface.as(gobject.Object).getData(seed_key) orelse return;
    const seed: *Seed = @ptrCast(@alignCast(data));
    if (seed.ready) return;
    seed.ready = true;
    const value = current(Application.default()) orelse return;
    value.ready_pending -|= 1;
    if (value.ready_pending == 0 and !value.restoring and !value.blocked) value.protect_file = false;
}

fn restoreNode(value: *State, profiles: *const launch.List, tab: model.Tab, index: u16, surfaces: []?*Surface, skipped: *u32) anyerror!?Surface.Tree {
    const node = tab.nodes[index];
    if (node.leaf) |leaf| {
        const profile = profiles.findId(leaf.profile_id) orelse {
            skipped.* += 1;
            return null;
        };
        if (model.restoreDecision(profile.id, true) == .confirm_custom and approved(value, profile.*) != true) {
            skipped.* += 1;
            return null;
        }
        var arena = std.heap.ArenaAllocator.init(value.alloc);
        defer arena.deinit();
        const args = glib.ext.Variant.newFrom(profile.args);
        _ = args.refSink();
        defer args.unref();
        var it: glib.VariantIter = undefined;
        _ = it.init(args);
        var overrides = try Overrides.parse(arena.allocator(), &it);
        overrides.launch_origin = .{ .profile = profile.id };
        overrides.title = if (!value.cli.title) if (leaf.title_override) |title| try arena.allocator().dupeSentinel(u8, title, 0) else null else null;
        if (leaf.cwd) |cwd| if (cwd.kind == .posix) {
            // Parse already validated the lexical local-domain constraint.
            if (std.Io.Dir.openDirAbsolute(global.io(), cwd.path, .{})) |dir_| {
                var dir = dir_;
                dir.close(global.io());
                overrides.working_directory = try arena.allocator().dupeSentinel(u8, cwd.path, 0);
            } else |_| return error.WorkingDirectoryUnavailable;
        };
        const surface = Surface.new(overrides);
        _ = surface.refSink();
        defer surface.unref();
        try setSeed(value, surface, if (value.cli.font) null else leaf.font_size);
        const tree = try Surface.Tree.init(value.alloc, surface);
        surfaces[index] = surface;
        return tree;
    }
    const split = node.split.?;
    var first = try restoreNode(value, profiles, tab, split.first, surfaces, skipped);
    var second = restoreNode(value, profiles, tab, split.second, surfaces, skipped) catch |err| {
        if (first) |*tree| tree.deinit();
        return err;
    };
    if (first == null) return second;
    if (second == null) return first;
    defer first.?.deinit();
    defer second.?.deinit();
    const ratio: f16 = @floatCast(split.ratio);
    if (ratio <= 0 or ratio >= 1) return error.InvalidTree;
    return try first.?.split(value.alloc, .root, if (split.axis == .horizontal) .right else .down, ratio, &second.?);
}

fn buildRestore(value: *State, profiles: *const launch.List) !void {
    const document = value.parsed.?.value;
    var windows: std.ArrayList(*Window) = .empty;
    defer windows.deinit(value.alloc);
    var committed = false;
    defer if (!committed) for (windows.items) |window| window.as(gtk.Window).destroy();
    var skipped = document.skipped_leaves;
    const config = value.app.getConfig();
    defer config.unref();
    for (document.windows) |saved_window| {
        const window = value.app.gxNewEmptyWindow();
        windows.append(value.alloc, window) catch |err| {
            window.as(gtk.Window).destroy();
            return err;
        };
        if (!value.cli.title) if (saved_window.title_override) |title| window.setTitleOverride(title);
        var active_page: ?*@import("adw").TabPage = null;
        for (saved_window.tabs, 0..) |saved_tab, tab_index| {
            const surfaces = try value.alloc.alloc(?*Surface, saved_tab.nodes.len);
            defer value.alloc.free(surfaces);
            @memset(surfaces, null);
            var tree = (try restoreNode(value, profiles, saved_tab, saved_tab.root, surfaces, &skipped)) orelse continue;
            defer tree.deinit();
            if (saved_tab.zoom) |zoom| if (surfaces[zoom]) |surface| {
                tree.zoomed = tree.locate(surface);
            };
            var leaves = tree.iterator();
            const focused = surfaces[saved_tab.active] orelse leaves.next().?.view;
            var owned = try lifecycle.prepare(value.alloc, &tree);
            defer lifecycle.abandon(owned);
            const tab = Tab.newEmpty(config);
            _ = tab.as(gobject.Object).refSink();
            defer tab.unref();
            if (!value.cli.title) if (saved_tab.title_override) |title| {
                const title_z = try value.alloc.dupeSentinel(u8, title, 0);
                defer value.alloc.free(title_z);
                tab.setTitleOverride(title_z);
            };
            tab.getSplitTree().adoptOwnedTree(owned, focused);
            owned = null;
            tab.getSplitTree().rebuildNow();
            // Publish only the complete tab: unattached, its rebuild cannot grab
            // focus. Grabs inside the not-yet-shown window let each later page
            // switch queue a GTK move-focus ref that nothing cleared before
            // present, and GTK 4.14-4.18 overwrites such a pending ref instead
            // of releasing it, leaking a restored tab (see split_transfer.zig).
            const page = window.adoptTab(tab);
            if (tab_index == saved_window.active) active_page = page;
        }
        if (window.getTabView().getNPages() == 0) {
            _ = windows.pop();
            window.as(gtk.Window).destroy();
            continue;
        }
        if (active_page) |page| window.getTabView().setSelectedPage(page);
        if (saved_window.geometry) |size| {
            const seed = try value.alloc.create(WindowGeometry);
            seed.* = .{ .alloc = value.alloc, .value = size };
            window.as(gobject.Object).setDataFull(geometry_key, seed, &WindowGeometry.destroy);
            applyGeometry(window);
        }
    }
    if (windows.items.len == 0) {
        value.ready_pending = 0;
        value.restoring = false;
        value.notice = "Some terminals were not restored because their launch profile was unavailable or not approved.";
        clearParsed(value);
        try value.app.gxNewWindow(null, .none);
        committed = true;
        return;
    }
    if (skipped > 0) value.notice = "Some terminals were not restored because their launch profile was unavailable or not approved.";
    value.restoring = false;
    for (windows.items) |window| window.as(gtk.Window).present();
    committed = true;
    if (value.ready_pending == 0) value.protect_file = false;
    clearParsed(value);
}

const WindowGeometry = struct {
    alloc: std.mem.Allocator,
    value: model.Geometry,
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *WindowGeometry = @ptrCast(@alignCast(data orelse return));
        self.alloc.destroy(self);
    }
};

/// Runs after ordinary geometry restoration and after late core size hints.
pub fn applyGeometry(window: *Window) void {
    const data = window.as(gobject.Object).getData(geometry_key) orelse return;
    const seed: *WindowGeometry = @ptrCast(@alignCast(data));
    const config = window.getConfig() orelse return;
    const cfg = config.get();
    if (cfg.@"window-save-state" == .never) return;
    var width: c_int = 800;
    var height: c_int = 600;
    if (window.getActiveSurface()) |surface| {
        surface.estimateInitialSize();
        if (surface.getDefaultSize()) |hint| {
            width = @intCast(hint.width);
            height = @intCast(hint.height);
        }
    }
    window.as(gtk.Window).setDefaultSize(if (cfg.@"window-width" == 0) @intCast(seed.value.width) else width, if (cfg.@"window-height" == 0) @intCast(seed.value.height) else height);
    if (seed.value.maximized and geometry.restoreMaximized(cfg)) window.as(gtk.Window).maximize();
}

/// A user removal, unlike an initial tree installation, ends restore protection.
pub fn removed(app: *Application) void {
    const value = current(app) orelse return;
    if (!releaseProtectionForRemoval(value)) return;
    changed(app);
}

fn releaseProtectionForRemoval(value: *State) bool {
    if (value.blocked or value.restoring or value.quitting) return false;
    value.protect_file = false;
    return true;
}

test "failed restore blocks fallback removal and close from overwriting saved session" {
    var value: State = .{ .alloc = std.testing.allocator, .app = undefined, .restoring = true };
    markRestoreFailure(&value);
    try std.testing.expect(!releaseProtectionForRemoval(&value));
    try std.testing.expect(!releaseProtectionForRemoval(&value));
    persist(&value, null); // blocked must return before dereferencing app/store
    value.quitting = true;
    persist(&value, null);
    try std.testing.expect(value.blocked and value.protect_file);
    var skipped: State = .{ .alloc = std.testing.allocator, .app = undefined, .protect_file = true };
    try std.testing.expect(releaseProtectionForRemoval(&skipped));
    try std.testing.expect(!skipped.protect_file);
}

test "state allocation failure remains blocked when fallback later obtains state" {
    var value: State = .{ .alloc = std.testing.allocator, .app = undefined };
    inheritRestoreFailure(&value, true);
    try std.testing.expect(value.attempted and value.blocked and value.protect_file);
    try std.testing.expect(!releaseProtectionForRemoval(&value));
    persist(&value, null);
    var ordinary: State = .{ .alloc = std.testing.allocator, .app = undefined };
    inheritRestoreFailure(&ordinary, false);
    try std.testing.expect(!ordinary.attempted and !ordinary.blocked);
}

pub fn observeWindow(window: *Window) void {
    _ = gtk.Widget.signals.map.connect(window.as(gtk.Widget), *Window, mapped, window, .{});
}
fn mapped(_: *gtk.Widget, window: *Window) callconv(.c) void {
    windowShown(window);
}

pub fn windowShown(window: *Window) void {
    if (window.isQuickTerminal()) return;
    const value = current(Application.default()) orelse return;
    const notice = value.notice orelse return;
    value.notice = null;
    @import("window.zig").toast(window, @import("../../../gx/i18n.zig").trRuntime(notice));
}

pub fn changed(app: *Application) void {
    if (!enabled(app)) return;
    const value = obtain(app) catch return;
    if (value.quitting or value.restoring or value.protect_file or value.blocked or value.cli.explicit_launch) return;
    if (value.idle == null) value.idle = glib.idleAdd(saveIdle, value);
}
fn saveIdle(data: ?*anyopaque) callconv(.c) c_int {
    const value: *State = @ptrCast(@alignCast(data orelse return 0));
    value.idle = null;
    persist(value, null);
    return 0;
}
fn persist(value: *State, exclude: ?*Window) void {
    if (value.blocked or value.restoring or value.cli.explicit_launch or !enabled(value.app)) return;
    open(value) catch |err| {
        value.blocked = true;
        value.notice = loadFailure(err);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(value.alloc);
    defer arena.deinit();
    const next_generation = std.math.add(u64, value.store.?.generation, 1) catch {
        value.notice = "The session could not be saved.";
        return;
    };
    const document = snapshot(value.app, arena.allocator(), next_generation, exclude) catch |err| {
        if (err == error.NotReady) return;
        value.notice = "The session could not be saved.";
        return;
    };
    value.store.?.save(document) catch |err| {
        log.warn("session save failed; previous document is unchanged: {}", .{err});
        value.notice = "The session could not be saved.";
        if (value.app.as(gtk.Application).getActiveWindow()) |active| {
            if (gobject.ext.cast(Window, active)) |window| windowShown(window);
        }
    };
}
pub fn closing(window: *Window) void {
    if (window.isQuickTerminal()) return;
    if (window.as(gobject.Object).getData(closed_key) != null) return;
    window.as(gobject.Object).setData(closed_key, @ptrFromInt(1));
    const value = current(Application.default()) orelse return;
    if (!releaseProtectionForRemoval(value)) return;
    persist(value, window);
}
pub fn quit(app: *Application) void {
    if (!enabled(app)) return;
    const value = obtain(app) catch return;
    if (value.quitting) return;
    if (!value.protect_file) persist(value, null);
    value.quitting = true;
}
pub fn shutdown(app: *Application) void {
    app.as(gobject.Object).setDataFull(key, null, null);
}

fn manualTitle(alloc: std.mem.Allocator, object: *gobject.Object) !?[]const u8 {
    var title = gobject.ext.Value.new(?[*:0]const u8);
    defer title.unset();
    object.getProperty("title-override", &title);
    return if (title.getString()) |text| try alloc.dupe(u8, std.mem.span(text)) else null;
}

fn snapshotNode(alloc: std.mem.Allocator, tree: *Surface.Tree, index: Surface.Tree.Node.Handle, nodes: *std.ArrayList(model.Node), map: []?u16, skipped: *u32) anyerror!?u16 {
    const node = tree.nodes[index.idx()];
    const result: u16 = switch (node) {
        .leaf => |surface| leaf: {
            const id = origin.get(surface).profileId() orelse {
                skipped.* += 1;
                return null;
            };
            const core = surface.core() orelse return error.NotReady;
            var cwd: ?model.Cwd = null;
            if (try core.pwd(alloc)) |path| {
                const candidate: model.Cwd = .{ .kind = .posix, .path = path };
                if (model.validateCwd(candidate)) |_| {
                    cwd = candidate;
                } else |_| {}
            }
            const result: u16 = @intCast(nodes.items.len);
            try nodes.append(alloc, .{ .leaf = .{
                .profile_id = try alloc.dupe(u8, id),
                .cwd = cwd,
                .font_size = core.font_size.points,
                .title_override = try manualTitle(alloc, surface.as(gobject.Object)),
            } });
            break :leaf result;
        },
        .split => |split| split: {
            const first = try snapshotNode(alloc, tree, split.left, nodes, map, skipped);
            const second = try snapshotNode(alloc, tree, split.right, nodes, map, skipped);
            if (first == null) return second;
            if (second == null) return first;
            const result: u16 = @intCast(nodes.items.len);
            try nodes.append(alloc, .{ .split = .{ .axis = if (split.layout == .horizontal) .horizontal else .vertical, .ratio = @floatCast(split.ratio), .first = first.?, .second = second.? } });
            break :split result;
        },
    };
    map[index.idx()] = result;
    return result;
}

fn snapshot(app: *Application, alloc: std.mem.Allocator, generation: u64, exclude: ?*Window) !model.Document {
    var windows: std.ArrayList(model.Window) = .empty;
    var skipped: u32 = 0;
    var cursor: ?*glib.List = app.as(gtk.Application).getWindows();
    while (cursor) |entry| : (cursor = entry.f_next) {
        const object: *gobject.Object = @ptrCast(@alignCast(entry.f_data orelse continue));
        const window = gobject.ext.cast(Window, object) orelse continue;
        if (window == exclude or window.isQuickTerminal() or object.getData(closed_key) != null) continue;
        var tabs: std.ArrayList(model.Tab) = .empty;
        var active: u16 = 0;
        const view = window.getTabView();
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const tree = tab.getSurfaceTree() orelse continue;
            if (tree.nodes.len == 0) continue;
            if (tree.nodes.len > model.max_nodes or tabs.items.len >= model.max_tabs) return error.LimitExceeded;
            var nodes: std.ArrayList(model.Node) = .empty;
            const map = try alloc.alloc(?u16, tree.nodes.len);
            @memset(map, null);
            const root = (try snapshotNode(alloc, tree, .root, &nodes, map, &skipped)) orelse continue;
            var active_leaf: u16 = for (nodes.items, 0..) |node, index| {
                if (node.leaf != null) break @intCast(index);
            } else return error.InvalidTree;
            if (tab.getActiveSurface()) |surface| if (tree.locate(surface)) |handle| {
                active_leaf = map[handle.idx()] orelse active_leaf;
            };
            if (page == view.getSelectedPage()) active = @intCast(tabs.items.len);
            try tabs.append(alloc, .{
                .nodes = nodes.items,
                .root = root,
                .active = active_leaf,
                .zoom = if (tree.zoomed) |zoom| map[zoom.idx()] else null,
                .title_override = try manualTitle(alloc, tab.as(gobject.Object)),
            });
        }
        if (tabs.items.len == 0) continue;
        if (windows.items.len >= model.max_windows) return error.LimitExceeded;
        const normal = geometry.snapshot(window);
        try windows.append(alloc, .{ .tabs = tabs.items, .active = active, .title_override = try manualTitle(alloc, window.as(gobject.Object)), .geometry = if (normal) |size| .{
            .width = @intCast(size.size.width),
            .height = @intCast(size.size.height),
            .dpi = 96,
            .maximized = size.maximized,
        } else null });
    }
    const result: model.Document = .{ .version = model.version, .generation = generation, .windows = windows.items, .skipped_leaves = skipped };
    try model.validate(result);
    return result;
}

test "session entrypoints compile against the real GTK objects" {
    const functions = .{ &activate, &changed, &closing, &quit, &shutdown, &applySeed, &surfaceReady, &windowShown };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}

test "restored surface seed clears initial command and preserves the current profile command" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    config.command = .{ .shell = "current-trusted-profile" };
    config.@"initial-command" = .{ .shell = "temporary-cli-command" };
    config.@"font-size" = 13;
    applyConfigSeed(&config, null);
    try std.testing.expect(config.@"initial-command" == null);
    try std.testing.expectEqualStrings("current-trusted-profile", config.command.?.shell);
    try std.testing.expectEqual(@as(f32, 13), config.@"font-size");
    applyConfigSeed(&config, 19);
    try std.testing.expectEqual(@as(f32, 19), config.@"font-size");
}

test "custom restore approval cannot authorize a changed current command" {
    var value: State = .{ .alloc = std.testing.allocator, .app = undefined };
    defer value.approvals.deinit(value.alloc);
    const profile: launch.Item = .{ .id = "custom:Python", .name = "Python", .args = &.{"--command=python3"} };
    try value.approvals.append(value.alloc, .{ .id = profile.id, .signature = signature(profile), .allowed = true });
    try std.testing.expectEqual(@as(?bool, true), approved(&value, profile));
    var changed_profile = profile;
    changed_profile.args = &.{"--command=other-program"};
    try std.testing.expect(approved(&value, changed_profile) == null);
    changed_profile = profile;
    changed_profile.id = "custom:Other";
    try std.testing.expect(approved(&value, changed_profile) == null);
}
