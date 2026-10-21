//! GUI-owned high-integrity drop adapter. The dedicated broker authenticates
//! its medium companion; only an explicit preview followed by the specific
//! protected-paste completion can acknowledge success. No clipboard is read.
const Self = @This();
const std = @import("std");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Dialogs = @import("ui/Dialogs.zig");
const transport = @import("ipc/DropBroker.zig");
const security = @import("ipc/Security.zig");
const native = @import("ipc/native.zig");
const data = @import("drop_data.zig");
const refs = @import("../../gx/ui_ref.zig");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32_drop_bridge);
const contract = transport.contract;
pub const Outcome = contract.Outcome;
pub const wake_message = w32.WM_APP + 0x6b;

/// Successful pasteBrokerText takes this value and invokes complete exactly
/// once (synchronously or later), including rejection and dialog destruction.
/// An error return MUST NOT retain the receipt or invoke its callback.
/// Each callback context belongs to one operation, never a global clipboard slot.
pub const Receipt = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, Outcome) void,
};

broker: ?*transport.Broker = null,
selected: refs.Attachment = .{},
pending: [contract.max_pending]?*Pending = @splat(null),
draining: bool = false,
closing: bool = false,
fixture_reject: bool = false,

const Pending = struct {
    bridge: *Self,
    allocator: std.mem.Allocator,
    key: contract.Key,
    text: [:0]u8,
    completed: bool = false,

    fn acknowledge(self: *Pending, outcome: Outcome) void {
        if (self.completed) return;
        self.completed = true;
        if (self.bridge.broker) |broker| broker.complete(self.key, outcome) catch |err| {
            log.warn("drop broker completion refused: {}", .{err});
        };
    }
    fn finish(context: *anyopaque, outcome: Outcome) void {
        const self: *Pending = @ptrCast(@alignCast(context));
        self.acknowledge(if (self.bridge.closing) .cancelled else outcome);
        for (&self.bridge.pending) |*slot| if (slot.* == self) {
            slot.* = null;
            break;
        };
        const allocator = self.allocator;
        allocator.free(self.text);
        allocator.destroy(self);
    }
    fn receipt(self: *Pending) Receipt {
        return .{ .context = self, .complete = finish };
    }
};

/// App/COM/window identities must already exist. Medium apps do not open this
/// high-side receiver; the separate companion owns its medium OLE receiver.
pub fn initialize(self: *Self, app: *App) !void {
    if (self.closing or self.broker != null) return error.InvalidState;
    const identity = try security.inspect(native.GetCurrentProcessId());
    defer identity.deinit();
    if (identity.identity.integrity != .high or !identity.identity.elevated) return;
    const hwnd = app.msg_hwnd orelse return error.NotReady;
    const broker = try transport.Broker.create(app.core_app.alloc, try App.instanceIsolation(app.core_app.alloc, app.config.class), app.ui_ids.epoch);
    errdefer broker.destroy();
    try broker.start(hwnd, wake_message);
    self.broker = broker;
    self.updateTarget(app);
}

/// Publish the last explicitly focused local view while a medium drag source
/// has foreground. Never guess another window if that attachment goes stale.
/// Call from the outer GUI loop and after focus/view lifecycle changes.
pub fn updateTarget(self: *Self, app: *App) void {
    const broker = self.broker orelse return;
    if (self.closing) {
        broker.setTarget(.{});
        return;
    }
    if (app.core_app.focusedSurface()) |core| {
        const surface = core.rt_surface;
        if (eligible(app, surface.ui_attachment) != null) self.selected = surface.ui_attachment;
    }
    if (eligible(app, self.selected) == null) self.selected = .{};
    broker.setTarget(self.selected);
}

fn eligible(app: *App, attachment: refs.Attachment) ?*Surface {
    if (app.quit_requested or app.drop_closing) return null;
    const surface = app.resolveSurfaceView(attachment) orelse return null;
    if (surface.parent_window.is_remote_host or !app.remote.allowsLocalInput(surface.ui_reference)) return null;
    if (surface.hwnd == null or surface.parent_window.hwnd == null) return null;
    return surface;
}

/// Only call at the outer GUI boundary; preview and protected paste may pump
/// messages. The wake-message handler itself must only wake that boundary.
pub fn drain(self: *Self, app: *App) void {
    if (self.closing or self.draining) return;
    const broker = self.broker orelse return;
    self.draining = true;
    defer self.draining = false;
    self.updateTarget(app);
    var count: usize = 0;
    while (!self.closing and count < contract.max_pending) : (count += 1) {
        const work = broker.take() orelse break;
        self.preview(app, broker, work) catch |err| {
            // complete accepts rejection in preview and failure while pasting.
            // No payload content is logged and no generic action is dispatched.
            broker.complete(work.key, .paste_failed) catch {};
            log.warn("drop broker preview/paste failed: {}", .{err});
        };
    }
}

fn preview(self: *Self, app: *App, broker: *transport.Broker, work: contract.Work) !void {
    // The normal authenticated protocol still prepared/decoded this request.
    // Only the explicitly gated fixture can exhaust GUI admission on demand.
    if (self.takeFixtureRejection(@import("remote_test.zig").enabled())) {
        try broker.complete(work.key, .rejected);
        return;
    }
    const surface = eligible(app, work.target) orelse {
        try broker.complete(work.key, .target_gone);
        return;
    };
    const free = for (&self.pending) |*slot| {
        if (slot.* == null) break slot;
    } else {
        try broker.complete(work.key, .rejected);
        return;
    };
    const allocator = app.core_app.alloc;
    // Work borrows broker storage. Copy before the modal preview so cancellation
    // may release transaction storage without invalidating any GUI-owned bytes.
    var payload = try clonePayload(allocator, work.decoded.payload());
    defer payload.deinit();
    const text = try payload.toPaste(allocator, surface.pathQuoting());
    var transferred = false;
    defer if (!transferred) allocator.free(text);
    const owner = surface.parent_window.hwnd;
    const count = if (payload.content == .files) payload.content.files.len else 0;
    const accepted = Dialogs.confirmBrokerDrop(owner, text, work.key.source.process.pid, count) == .accept;
    if (self.closing) {
        try broker.complete(work.key, .cancelled);
        return;
    }
    const live = eligible(app, work.target) orelse {
        try broker.complete(work.key, .target_gone);
        return;
    };
    // Changing foreground shells while the dialog is open must never change
    // the actual pasted quoting relative to the user's approved preview.
    const current = try payload.toPaste(allocator, live.pathQuoting());
    defer allocator.free(current);
    if (!std.mem.eql(u8, text, current)) {
        try broker.complete(work.key, .rejected);
        return;
    }
    // Native approve rechecks the retained peer process plus deadline and exact
    // current attachment. Preview acceptance alone is not a success receipt.
    if (!try broker.approve(work.key, accepted, live.ui_attachment)) return;
    const target = eligible(app, work.target) orelse {
        try broker.complete(work.key, .target_gone);
        return;
    };
    const pending = try allocator.create(Pending);
    pending.* = .{ .bridge = self, .allocator = allocator, .key = work.key, .text = text };
    free.* = pending;
    transferred = true;
    // May synchronously invoke finish and destroy pending. Do not read it again
    // on success. On error the callee contract leaves this receipt unconsumed.
    target.pasteBrokerText(text, pending.receipt()) catch |err| {
        Pending.finish(pending, .paste_failed);
        log.warn("drop broker protected paste could not start: {}", .{err});
    };
}

fn takeFixtureRejection(self: *Self, enabled: bool) bool {
    if (!enabled or !self.fixture_reject) return false;
    self.fixture_reject = false;
    return true;
}

test "broker fixture rejection is one shot and inert with gate off" {
    var bridge: Self = .{ .fixture_reject = true };
    try std.testing.expect(!bridge.takeFixtureRejection(false));
    try std.testing.expect(bridge.fixture_reject);
    try std.testing.expect(bridge.takeFixtureRejection(true));
    try std.testing.expect(!bridge.takeFixtureRejection(true));
}

fn clonePayload(allocator: std.mem.Allocator, payload: contract.Payload) !data.Payload {
    return switch (payload) {
        .text => |value| data.textUtf8(allocator, value),
        .files => |paths| data.filePaths(allocator, paths),
    };
}

/// Whether this elevated process runs a live broker, so a normal-privilege
/// drop receiver can pair with it. Never true in a medium-integrity process:
/// `initialize` only starts a broker for a high, elevated token.
pub fn available(self: *const Self) bool {
    return self.broker != null and !self.closing;
}

/// Stop new work before Surface/dialog teardown. Existing callbacks retain
/// their own text/context until cancellation/destruction calls their receipt.
pub fn beginClose(self: *Self) void {
    if (self.closing) return;
    self.closing = true;
    self.selected = .{};
    if (self.broker) |broker| {
        broker.setTarget(.{});
        for (self.pending) |slot| if (slot) |pending| pending.acknowledge(.cancelled);
        broker.shutdown();
    }
}

/// App calls after every concrete ClipboardConfirm has returned its receipt.
/// Busy is a lifecycle error to resolve, never permission to free live contexts.
pub fn destroy(self: *Self) !void {
    self.beginClose();
    if (self.draining) return error.Busy;
    for (self.pending) |slot| if (slot != null) return error.Busy;
    if (self.broker) |broker| broker.destroy();
    self.broker = null;
}

test "drop bridge production entrypoints compile" {
    inline for (.{ &initialize, &updateTarget, &drain, &beginClose, &destroy }) |function|
        try std.testing.expect(@intFromPtr(function) != 0);
}

test "drop bridge payload clone preserves source bytes and file quoting" {
    const allocator = std.testing.allocator;
    var payload = try clonePayload(allocator, .{ .files = &.{"C:\\owned\\with space.txt"} });
    defer payload.deinit();
    const text = try payload.toPaste(allocator, .powershell);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("'C:\\owned\\with space.txt'", text);
    try std.testing.expectError(error.UnsafePath, blk: {
        var unsafe = try clonePayload(allocator, .{ .files = &.{"C:\\owned\\%USER%.txt"} });
        defer unsafe.deinit();
        break :blk unsafe.toPaste(allocator, .windows);
    });
}

test "drop bridge close retains operation context until its own receipt" {
    var bridge: Self = .{};
    const allocator = std.testing.allocator;
    const pending = try allocator.create(Pending);
    pending.* = .{ .bridge = &bridge, .allocator = allocator, .key = undefined, .text = try allocator.dupeSentinel(u8, "owned", 0) };
    bridge.pending[0] = pending;
    const receipt = pending.receipt();
    bridge.beginClose();
    try std.testing.expectError(error.Busy, bridge.destroy());
    receipt.complete(receipt.context, .pasted);
    try std.testing.expect(bridge.pending[0] == null);
    try bridge.destroy();
}
