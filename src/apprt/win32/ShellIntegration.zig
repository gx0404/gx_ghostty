//! GUI-owned shell integration. Worker callbacks carry capabilities only;
//! every activation resolves its original live target on the GUI thread.
const Self = @This();
const std = @import("std");
const App = @import("App.zig");
const global = @import("../../global.zig");
const Ref = @import("../../gx/ui_ref.zig").Reference;
const i18n = @import("../../gx/i18n.zig");
const Identity = @import("shell/Identity.zig");
const Activation = @import("shell/ToastActivation.zig");
const Toast = @import("shell/WinRTToast.zig");
const JumpList = @import("shell/JumpList.zig");
const w32 = @import("win32.zig");
const wstr = @import("ui/wstr.zig");
const log = std.log.scoped(.win32_shell);
const protocol = @import("../../gx/remote_protocol.zig");
pub const wake_message = w32.WM_APP + 0x68;
pub const server_timer: usize = 0x5348;

identity: ?Identity = null,
registry: ?Activation.Registry = null,
sink: ?*Activation.Sink = null,
worker: ?*Toast = null,
publisher: JumpList.Publisher = .{},
jump_list_dirty: bool = true,
publishing: bool = false,
closing: bool = false,
startup: Identity.Startup = .none,
server_activation_received: bool = false,
pending: [32]?Pending = @splat(null),
pending_retire: [512]?Activation.Token = @splat(null),
const Pending = struct { token: Activation.Token, target: Ref, title: []u8, body: []u8, receipt: ?protocol.ActionResult = null, completed: ?bool = null };
extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]u16, u32) callconv(.winapi) u32;

pub fn readStartup(self: *Self, alloc: std.mem.Allocator) !void {
    var iterator = try std.process.Args.Iterator.initAllocator(global.args(), alloc);
    defer iterator.deinit();
    _ = iterator.next();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    while (iterator.next()) |arg| try args.append(alloc, arg);
    self.startup = try Identity.parseStartup(args.items);
    if (self.startup == .profile) self.startup = .{ .profile = try alloc.dupe(u8, self.startup.profile) };
}

pub fn initialize(self: *Self, app: *App) !void {
    const alloc = app.core_app.alloc;
    var path: [32768]u16 = undefined;
    const len = GetModuleFileNameW(null, &path, path.len);
    if (len == 0 or len >= path.len) return error.InvalidExecutable;
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, path[0..len]);
    defer alloc.free(utf8);
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const size = try std.Io.Dir.cwd().realPathFile(global.io(), utf8, &resolved);
    self.identity = try Identity.detect(alloc, resolved[0..size]);
    try self.identity.?.applyProcess();
    if (self.startup == .drop_companion) return;
    if (!self.identity.?.registration_verified) return;
    self.registry = try Activation.Registry.init(global.io(), app.ui_ids.epoch);
    self.sink = try Activation.Sink.create(alloc, &self.identity.?, app.msg_hwnd, wake_message);
    self.worker = try Toast.create(alloc, &self.identity.?, self.sink.?, .{ .activation_only = self.startup == .toast_server });
    try self.worker.?.start();
}

/// Returns false only when the native backend is unavailable before admission.
/// Queue-full, denied and suppressed requests never become duplicate balloons.
pub fn notify(self: *Self, app: *App, target: Ref, title: []const u8, body: []const u8) bool {
    self.enqueue(app, target, title, body, null) catch |err| return err != error.NativeUnavailable;
    return true;
}

/// Null means native completion is pending, not that a notification appeared.
pub fn notifyRemote(self: *Self, app: *App, target: Ref, title: []const u8, body: []const u8, receipt: protocol.ActionResult) !?bool {
    self.enqueue(app, target, title, body, receipt) catch |err| {
        if (err == error.NativeUnavailable) return app.showLegacyDesktopNotification(target, title, body);
        return false;
    };
    return null;
}

fn enqueue(self: *Self, app: *App, target: Ref, title: []const u8, body: []const u8, receipt: ?protocol.ActionResult) !void {
    if (self.closing) return error.Closed;
    const worker = self.worker orelse return error.NativeUnavailable;
    if (!self.retryRetirements()) return error.QueueFull;
    if (title.len > Toast.max_title_bytes or body.len > Toast.max_body_bytes) return error.LimitExceeded;
    const registry = if (self.registry) |*value| value else return error.NativeUnavailable;
    const slot = for (&self.pending) |*entry| {
        if (entry.* == null) break entry;
    } else return error.QueueFull;
    const issued = try registry.issueWithEviction(target);
    const token = issued.token;
    if (issued.evicted) |old| self.retire(old);
    const alloc = app.core_app.alloc;
    const owned_title = alloc.dupe(u8, title) catch |err| {
        registry.revoke(token);
        return err;
    };
    const owned_body = alloc.dupe(u8, body) catch |err| {
        alloc.free(owned_title);
        registry.revoke(token);
        return err;
    };
    worker.enqueue(token, title, body) catch |err| {
        alloc.free(owned_title);
        alloc.free(owned_body);
        registry.revoke(token);
        return err;
    };
    slot.* = .{ .token = token, .target = target, .title = owned_title, .body = owned_body, .receipt = receipt };
}

fn live(app: *App, target: Ref) bool {
    return switch (target.kind) {
        .surface => app.resolveLeaf(target) != null or app.resolveSurface(target) != null,
        .window => app.resolveWindow(target) != null,
        .tab => false,
    };
}

/// The startup watchdog bounds a server that never receives an activation,
/// not the time a user may spend reading its activation result.
pub fn serverTimeoutShouldQuit(self: *const Self) bool {
    return self.startup == .toast_server and !self.server_activation_received;
}

/// Set the state before KillTimer: a timer message may already be queued, and
/// presenting a target or a native dialog may enter a nested message loop.
pub fn activationReceived(self: *Self, hwnd: ?w32.HWND) void {
    if (self.startup != .toast_server) return;
    self.server_activation_received = true;
    if (hwnd) |window| _ = w32.KillTimer(window, server_timer);
}

/// Called from the outer loop, where native shell calls may reenter safely.
pub fn drain(self: *Self, app: *App) void {
    if (self.closing) return;
    _ = self.retryRetirements();
    if (self.worker) |worker| while (worker.takeOutcome()) |outcome| {
        if (outcome.result == .evicted) if (self.registry) |*registry| registry.revoke(outcome.token);
        for (&self.pending) |*entry| if (entry.*) |*request| {
            if (!std.meta.eql(request.token, outcome.token)) continue;
            request.completed = outcome.result == .accepted;
            if (outcome.result != .accepted) {
                if (self.registry) |*registry| registry.revoke(outcome.token);
                if (outcome.result == .unavailable and live(app, request.target)) {
                    request.completed = app.showLegacyDesktopNotification(request.target, request.title, request.body);
                }
            }
            break;
        };
    };
    for (&self.pending) |*entry| if (entry.*) |request| if (request.completed) |performed| {
        if (request.receipt) |saved| {
            var result = saved;
            const pane = app.resolveRemote(request.target);
            result.performed = if (pane) |value| performed and value.ready() and value.gate.lease != null and std.meta.eql(value.gate.lease.?, saved.lease) and value.ui.config_generation == saved.config_generation else false;
            app.remote.postToSource(result.surface, .{ .ui_event_result = result }) catch |err| {
                if (err == error.QueueFull) continue;
            };
        }
        app.core_app.alloc.free(request.title);
        app.core_app.alloc.free(request.body);
        entry.* = null;
    };
    if (self.sink) |sink| for (0..64) |_| {
        const token = sink.take() orelse break;
        self.activationReceived(app.msg_hwnd);
        const target = if (self.registry) |*registry| registry.resolve(token) else null;
        // The same presentation as the tray balloon and `present_terminal`.
        if (target) |reference| if (app.presentReference(reference)) continue;
        var text: [256]u16 = undefined;
        var caption: [64]u16 = undefined;
        // A cold server has no application window to own or expose this dialog.
        // Request foreground focus and keep this one result visible even when
        // Windows denies foreground activation; do not make app windows topmost.
        const flags = w32.MB_ICONINFORMATION | @as(u32, if (self.startup == .toast_server)
            0x00010000 | 0x00040000 // MB_SETFOREGROUND | MB_TOPMOST
        else
            0);
        _ = w32.MessageBoxW(null, wstr.bufZ(&text, i18n.tr("The notification target is no longer available.")), wstr.bufZ(&caption, "Ghostty GX"), flags);
        if (self.startup == .toast_server) {
            app.quit_requested = true;
            w32.PostQuitMessage(0);
            return;
        }
    };
    if (self.jump_list_dirty and !self.publishing and self.startup != .toast_server and self.startup != .drop_companion) self.publish(app);
}

fn publish(self: *Self, app: *App) void {
    self.jump_list_dirty = false;
    const identity = if (self.identity) |*value| value else return;
    if (!identity.registration_verified) return;
    self.publishing = true;
    defer self.publishing = false;
    var profiles = app.cachedLaunchProfiles() catch return;
    defer profiles.deinit();
    var items: [JumpList.max_profiles]JumpList.Profile = undefined;
    const count = @min(items.len, profiles.profiles.len);
    for (profiles.profiles[0..count], items[0..count]) |profile, *item| item.* = .{ .id = profile.id, .title = i18n.trRuntime(profile.name) };
    var snapshot = JumpList.Snapshot.init(app.core_app.alloc, identity, items[0..count]) catch return;
    defer snapshot.deinit();
    app.com_apartment.ensureCom() catch return;
    if (self.closing or app.quit_requested) return;
    _ = self.publisher.publish(identity, &snapshot) catch |err| {
        log.warn("JumpList update failed: {}", .{err});
        return;
    };
}

pub fn revoke(self: *Self, target: Ref) void {
    if (self.registry) |*registry| {
        var tokens: [256]Activation.Token = undefined;
        for (registry.revokeTarget(target, &tokens)) |token| self.retire(token);
    }
}

fn retire(self: *Self, token: Activation.Token) void {
    const worker = self.worker orelse return;
    worker.retire(token) catch {
        for (self.pending_retire) |pending| if (pending) |value| {
            if (std.meta.eql(value, token)) return;
        };
        for (&self.pending_retire) |*slot| if (slot.* == null) {
            slot.* = token;
            return;
        };
        // New admissions stop while backlogged: at most one evicted token plus
        // the registry's 256 current capabilities can need retirement.
        unreachable;
    };
}

fn retryRetirements(self: *Self) bool {
    const worker = self.worker orelse return true;
    for (&self.pending_retire) |*slot| if (slot.*) |token| {
        worker.retire(token) catch return false;
        slot.* = null;
    };
    return true;
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    if (self.closing) return;
    self.closing = true;
    if (self.registry) |*registry| registry.shutdown();
    if (self.sink) |sink| sink.close();
    if (self.worker) |worker| worker.destroy();
    if (self.sink) |sink| sink.release();
    if (self.identity) |*identity| identity.deinit();
    if (self.startup == .profile) alloc.free(self.startup.profile);
    for (&self.pending) |*entry| if (entry.*) |request| {
        alloc.free(request.title);
        alloc.free(request.body);
        entry.* = null;
    };
    self.worker = null;
    self.sink = null;
    self.identity = null;
}
