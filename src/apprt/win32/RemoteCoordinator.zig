//! GUI-only cross-host transfer coordinator. Source PTYs and renderer threads
//! survive in a hidden Host; target leaves share the normal Window tab model.
//! App calls drain only at its outer message boundary, never in core callbacks.
const Self = @This();
const std = @import("std");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Host = @import("RemoteHost.zig").Host;
const Output = @import("RemoteHost.zig").Output;
const RemotePane = @import("RemotePane.zig");
const RemoteSource = @import("RemoteSource.zig");
const RemoteInput = @import("RemoteInput.zig");
const transport = @import("ipc/RemoteService.zig");
const channels = @import("ipc/RemoteChannel.zig");
const native = @import("ipc/native.zig");
const policy = @import("ipc/Security.zig").policy;
const protocol = @import("../../gx/remote_protocol.zig");
const authority = @import("../../gx/remote_view.zig");
const refs = @import("../../gx/ui_ref.zig");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32_remote);
pub const wake_message = w32.WM_APP + 0x69;
pub const timer_id: usize = 0x524d; // RM, coordinator retry/query tick.
const max_transfers = transport.max_connections;
pub const transfer_budget: u64 = 512 * 1024 * 1024;
pub const process_budget: u64 = 1024 * 1024 * 1024;
const Export = struct { value: channels.Export, surface: refs.Reference, id: u64, request: ?u64 = null, accepted: bool = false, settled: bool = false, receipt_sent: bool = false, receipt_request: ?u64 = null, receipt_acked: bool = false, receipt_time: u64 = 0 };
const Source = struct {
    connection: ?*transport.Connection,
    source_window: refs.Reference,
    tab: refs.Reference,
    description: protocol.Tree,
    drop_point: ?protocol.DropPoint = null,
    digest: [32]u8,
    host: ?*Host,
    state: authority.SourceAuthority,
    transaction: u64,
    ticket: ?protocol.Ticket = null,
    prepare_request: ?u64 = null,
    prepare_accepted: bool = false,
    outputs_prepared: bool = false,
    commit_request: ?u64 = null,
    revoked_sent: bool = false,
    moved: bool = false,
    retired: bool = false,
    recovering: bool = false,
    close_deferred: bool = false,
    export_serial: u64 = 0,
    mapping_generation: u64 = 1,
    exports: std.ArrayList(Export) = .empty,
    input_sequence: [protocol.max_nodes]protocol.InputSequence = @splat(.{}),
    closed_leaves: [protocol.max_nodes]bool = @splat(false),
    last_query: u64 = 0,
    query_request: ?u64 = null,
    replies: [32]?*protocol.Body = @splat(null),
    reply_head: usize = 0,
    reply_len: usize = 0,
};
const Receipt = struct { request_id: u64, offer_id: u64, target_handle: u64, outcome: protocol.Outcome };
const Target = struct {
    connection: ?*transport.Connection,
    window: *TargetTree,
    ticket: protocol.Ticket,
    ready_sent: bool = false,
    enabled_sent: bool = false,
    source_revoked: bool = false,
    committed: bool = false,
    ever_enabled: bool = false,
    inputs: RemoteInput.Buffer = .{},
    input_sequence: u64 = 0,
    wire_sequence: u64 = 0,
    input_request: ?struct { request: u64, sequence: u64, surface: refs.Reference } = null,
    replies: [32]?*protocol.Body = @splat(null),
    reply_head: usize = 0,
    reply_len: usize = 0,
    last_query: u64 = 0,
    receipts: [256]?Receipt = @splat(null),
    resend_receipts: ?usize = null,
    consumed_receipts: [128]?struct { offer_id: u64, target_handle: u64 } = @splat(null),
    consumed_next: usize = 0,
};
const Local = union(enum) { close_target: refs.Reference, close_source: refs.Reference };
const Fanout = struct {
    id: u64,
    request: protocol.ActionRequest,
    origin: refs.Reference,
    remaining: usize = 0,
    performed: bool = false,
    dispatching: bool = true,
    cancelled: bool = false,
    closing: std.ArrayList(refs.Reference) = .empty,
};

/// Two source chains cannot each wait for the other's ordinary fanout paste.
/// A conflicting request fails before dispatch; it is never queued behind the
/// holder. Identity-checked release ignores completion of an older operation.
const PasteFanoutGate = struct {
    owner: ?u64 = null,

    fn acquire(self: *PasteFanoutGate, id: u64) bool {
        if (self.owner != null) return false;
        self.owner = id;
        return true;
    }

    fn release(self: *PasteFanoutGate, id: u64) void {
        if (self.owner == id) self.owner = null;
    }
};

fn isPasteFanout(action: @import("../../input.zig").Binding.Action, request: protocol.ActionRequest) bool {
    return (request.all or request.global) and (action == .paste_from_clipboard or action == .paste_from_selection);
}

/// A transfer is a group of remote leaves, never a second top-level window.
/// The coordinator retains each leaf while the normal split tree owns a ref.
const TargetTree = struct {
    app: *App,
    reference: refs.Reference,
    owner: refs.Reference,
    tab: ?refs.Reference = null,
    tree: protocol.Tree,
    panes: [protocol.max_nodes]?*RemotePane = @splat(null),
    unavailable: bool = false,
    fn create(app: *App, tree: *const protocol.Tree, ticket: protocol.Ticket, callbacks: RemotePane.Callbacks) !*TargetTree {
        const owner = try destinationWindow(app, tree);
        const self = try app.core_app.alloc.create(TargetTree);
        errdefer app.core_app.alloc.destroy(self);
        self.* = .{ .app = app, .reference = try app.ui_ids.create(.tab), .owner = owner.ui_reference, .tree = tree.* };
        if (self.tree.drop_index == null) if (tree.drop_point) |point| if (owner.hwnd) |hwnd| {
            var client: w32.POINT = .{ .x = point.x, .y = point.y };
            if (w32.ScreenToClient(hwnd, &client) != 0) if (owner.tab_bar.transferSlotAt(client)) |index| {
                self.tree.drop_index = @intCast(index);
            };
        };
        errdefer for (self.panes) |entry| if (entry) |value| value.unref(app.core_app.alloc);
        for (tree.nodes.slice(), 0..) |node, index| if (node == .leaf) {
            self.panes[index] = try RemotePane.create(app, owner, node.leaf, self.reference, ticket, callbacks);
        };
        return self;
    }
    fn pane(self: *TargetTree, source: refs.Reference) ?*RemotePane {
        for (self.panes) |entry| if (entry) |value| if (value.source_reference.matches(source)) return value;
        return null;
    }
    fn acceptMapping(self: *TargetTree, source: refs.Reference, channel: *channels.Channel) !void {
        return (self.pane(source) orelse return error.InvalidSurface).acceptMapping(channel);
    }
    fn allFrames(self: *const TargetTree) bool {
        if (self.unavailable) return false;
        for (self.panes) |entry| if (entry) |value| if (!value.allFrames()) return false;
        return true;
    }
    fn frameReady(self: *TargetTree, source: refs.Reference) void {
        if (self.pane(source)) |value| value.frameReady();
    }
    fn enableLease(self: *TargetTree, lease: protocol.Lease) !void {
        if (!self.allFrames()) return error.NotReady;
        const owner = self.app.resolveWindow(self.owner) orelse return error.InvalidOwner;
        if (self.tab == null) {
            var list: [protocol.max_leaves]*RemotePane = undefined;
            var count: usize = 0;
            for (self.panes) |entry| if (entry) |value| {
                list[count] = value;
                count += 1;
            };
            const at = self.tree.drop_index orelse @as(u16, @intCast(owner.tab_count));
            self.tab = try owner.adoptRemoteTab(@min(at, owner.tab_count), &self.tree, list[0..count]);
        }
        for (self.panes) |entry| if (entry) |value| try value.enableLease(lease);
        if (owner.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
        if (self.panes[self.tree.zoom orelse self.tree.active]) |active| if (active.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        };
    }
    fn activateInput(self: *TargetTree) void {
        for (self.panes) |entry| if (entry) |value| value.activateInput();
    }
    fn disconnect(self: *TargetTree) void {
        self.unavailable = true;
        for (self.panes) |entry| if (entry) |value| value.disconnect();
    }
    fn deinit(self: *TargetTree) !void {
        self.disconnect();
        // Leaves may have moved into another normal window or a mixed tab.
        // Retire each owned identity wherever it currently lives.
        for (self.panes) |entry| if (entry) |value| {
            if (self.app.resolveLeaf(value.ui_reference)) |leaf| {
                value.parent_window.removeLeaf(leaf);
            }
        };
        for (self.panes) |entry| if (entry) |value| value.unref(self.app.core_app.alloc);
        self.app.core_app.alloc.destroy(self);
    }
};

fn destinationWindow(app: *App, tree: *const protocol.Tree) !*Window {
    if (tree.drop_point) |point| {
        for (app.windows.items) |window| {
            if (window.closing or window.is_remote_host or window.is_quick_terminal or window.tab_count >= Window.MAX_TABS) continue;
            const hwnd = window.hwnd orelse continue;
            var rect: w32.RECT = undefined;
            if (w32.GetWindowRect(hwnd, &rect) == 0 or point.x < rect.left or point.x >= rect.right or point.y < rect.top or point.y >= rect.bottom) continue;
            return window;
        }
    }
    for (app.windows.items) |window| if (!window.closing and !window.is_remote_host and !window.is_quick_terminal and window.tab_count < Window.MAX_TABS) return window;
    return app.newWindow(.{});
}

app: ?*App = null,
service: ?*transport.Service = null,
sources: [max_transfers]?*Source = @splat(null),
targets: [max_transfers]?*Target = @splat(null),
local: [32]Local = undefined,
local_head: usize = 0,
local_len: usize = 0,
serial: u64 = 0,
draining: bool = false,
closing: bool = false,
mapping_consumed: bool = false, // Current non-reentrant GUI Work only.
timer_active: bool = false,
fanouts: [32]?*Fanout = @splat(null),
fanout_serial: u64 = 0,
paste_fanout: PasteFanoutGate = .{},

pub fn performUiRequest(self: *Self, app: *App, origin: *RemotePane, action: @import("../../input.zig").Binding.Action, request: protocol.ActionRequest) !void {
    const exclusive_paste = isPasteFanout(action, request);
    if (exclusive_paste and self.paste_fanout.owner != null) {
        origin.ui.last_action_performed = false;
        try self.postToSource(request.surface, .{ .ui_action_result = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation, .performed = false } });
        return;
    }
    const slot = for (&self.fanouts) |*entry| {
        if (entry.* == null) break entry;
    } else return error.QueueFull;
    const aggregate = try app.core_app.alloc.create(Fanout);
    errdefer app.core_app.alloc.destroy(aggregate);
    self.fanout_serial = try std.math.add(u64, self.fanout_serial, 1);
    aggregate.* = .{ .id = self.fanout_serial, .request = request, .origin = origin.ui_reference };
    var references: std.ArrayList(refs.Reference) = .empty;
    defer references.deinit(app.core_app.alloc);
    var close_targets: std.ArrayList(refs.Reference) = .empty;
    defer close_targets.deinit(app.core_app.alloc);
    if (action == .quit or action == .close_all_windows) {
        for (app.windows.items) |window| if (!window.closing and !window.is_remote_host) try references.append(app.core_app.alloc, window.ui_reference);
        if (app.quick_terminal) |quick| try references.append(app.core_app.alloc, quick.window.ui_reference);
    } else if (request.all or request.global) {
        for (app.windows.items) |window| try window.visiblePaneReferences(&references);
        if (app.quick_terminal) |quick| try quick.window.visiblePaneReferences(&references);
    } else try references.append(app.core_app.alloc, origin.ui_reference);
    try close_targets.ensureTotalCapacity(app.core_app.alloc, references.items.len);
    if (exclusive_paste) std.debug.assert(self.paste_fanout.acquire(aggregate.id));
    slot.* = aggregate;
    defer {
        aggregate.dispatching = false;
        if (aggregate.remaining == 0) self.paste_fanout.release(aggregate.id);
    }
    if (action == .quit or action == .close_all_windows) {
        // Capture value identities before the first confirmation pumps the
        // message loop. Completion waits for actual model removal below.
        for (references.items) |reference| {
            const window = app.resolveWindow(reference) orelse continue;
            const leaf = window.activeLeaf() orelse continue;
            _ = window.requestUiClose(leaf.reference(), .close_window, &aggregate.closing) catch false;
        }
        return;
    }
    if (action.scoped(.app) != null) {
        aggregate.performed = app.performRemoteAppAction(action) catch false;
        return;
    }
    for (references.items, 0..) |reference, index| {
        if (aggregate.cancelled) break;
        const duplicate = for (references.items[0..index]) |previous| {
            if (previous.matches(reference)) break true;
        } else false;
        if (duplicate) continue;
        const pane = @import("Pane.zig").resolve(app, reference) orelse continue;
        if (action == .close_window or action == .close_tab or action == .close_surface) {
            const identity = if (action == .close_surface) reference else if (action == .close_tab and action.close_tab == .this) pane.tabInfo().tab orelse continue else pane.ownerWindow().ui_reference;
            const seen = for (close_targets.items) |previous| {
                if (previous.matches(identity)) break true;
            } else false;
            if (seen) continue;
            close_targets.appendAssumeCapacity(identity);
            _ = pane.ownerWindow().requestUiClose(reference, action, &aggregate.closing) catch false;
            continue;
        }
        if (pane.backend == .remote) {
            aggregate.remaining += 1;
            const completed = pane.backend.remote.ui.performRequest(pane.backend.remote, action, aggregate.id, request) catch false;
            if (completed) |performed| self.completeFanout(aggregate.id, performed);
        } else {
            const performed = pane.performBindingAction(action) catch false;
            if (!aggregate.cancelled) aggregate.performed = performed or aggregate.performed;
        }
    }
}
pub fn completeFanout(self: *Self, id: u64, performed: bool) void {
    for (self.fanouts) |entry| if (entry) |aggregate| if (aggregate.id == id) {
        if (aggregate.cancelled) return;
        if (aggregate.remaining != 0) aggregate.remaining -= 1;
        aggregate.performed = aggregate.performed or performed;
        if (!aggregate.dispatching and aggregate.remaining == 0) self.paste_fanout.release(id);
        return;
    };
}

/// A disconnected or reconfigured initiating source has cancelled its chain.
/// Already-admitted destination effects are not replayed, and their late
/// results cannot release a newer exclusive paste or report stale success.
pub fn cancelPasteFanouts(self: *Self, origin: refs.Reference) void {
    const owner = self.paste_fanout.owner orelse return;
    for (self.fanouts) |entry| if (entry) |aggregate| if (aggregate.id == owner and aggregate.origin.matches(origin)) {
        aggregate.cancelled = true;
        aggregate.performed = false;
        aggregate.remaining = 0;
        self.paste_fanout.release(owner);
        return;
    };
}
pub fn cancelCloseWait(self: *Self, reference: refs.Reference) void {
    for (self.fanouts) |entry| if (entry) |aggregate| {
        var index: usize = 0;
        while (index < aggregate.closing.items.len) {
            if (aggregate.closing.items[index].matches(reference)) _ = aggregate.closing.orderedRemove(index) else index += 1;
        }
    };
}
fn progressFanouts(self: *Self, app: *App) void {
    for (&self.fanouts) |*entry| if (entry.*) |aggregate| {
        if (aggregate.dispatching) continue;
        var index: usize = 0;
        while (index < aggregate.closing.items.len) {
            const reference = aggregate.closing.items[index];
            const exists = switch (reference.kind) {
                .window => app.resolveWindow(reference) != null,
                .tab => app.resolveTab(reference) != null,
                .surface => @import("Pane.zig").resolve(app, reference) != null,
            };
            if (exists) {
                index += 1;
                continue;
            }
            _ = aggregate.closing.orderedRemove(index);
            aggregate.performed = true;
        }
        if (aggregate.remaining != 0 or aggregate.closing.items.len != 0) continue;
        self.paste_fanout.release(aggregate.id);
        if (app.resolveRemote(aggregate.origin)) |pane| pane.ui.last_action_performed = aggregate.performed;
        const request = aggregate.request;
        if (@import("remote_test.zig").enabled()) log.info("remote action aggregate completed aggregate={} source={x} transaction={} generation={} performed={}", .{ aggregate.id, request.surface.id, request.transaction, request.config_generation, aggregate.performed });
        self.postToSource(request.surface, .{ .ui_action_result = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation, .performed = aggregate.performed, .closed = @import("Pane.zig").resolve(app, aggregate.origin) == null } }) catch |err| {
            if (err == error.QueueFull) continue;
        };
        aggregate.closing.deinit(app.core_app.alloc);
        app.core_app.alloc.destroy(aggregate);
        entry.* = null;
    };
}

pub fn initialize(self: *Self, app: *App) !void {
    self.app = app;
    const service = try transport.Service.create(app.core_app.alloc, try App.instanceIsolation(app.core_app.alloc, app.config.class), app.ui_ids.epoch);
    errdefer service.destroy() catch unreachable;
    try service.start(app.msg_hwnd orelse return error.NotReady, wake_message);
    self.service = service;
}

/// Source coordinator entry, called with an OS-verified target PID/birth.
/// The target epoch is learned asynchronously from the authenticated pipe.
pub fn begin(self: *Self, app: *App, window_ref: refs.Reference, tab_ref: refs.Reference, target: policy.Process) !void {
    var point: w32.POINT = undefined;
    const drop: ?protocol.DropPoint = if (w32.GetCursorPos_(&point) != 0) .{ .x = point.x, .y = point.y } else null;
    return self.beginAt(app, window_ref, tab_ref, target, drop);
}
pub fn beginAt(self: *Self, app: *App, window_ref: refs.Reference, tab_ref: refs.Reference, target: policy.Process, drop: ?protocol.DropPoint) !void {
    if (self.closing or self.service == null or target.pid == native.GetCurrentProcessId()) return error.NotReady;
    const free = for (&self.sources) |*slot| {
        if (slot.* == null) break slot;
    } else return error.Busy;
    const window = app.resolveWindow(window_ref) orelse return error.StaleSource;
    if (window.closing or window.is_quick_terminal or window.is_remote_host or window.tab_transfer_active) return error.InvalidSource;
    const index = window.resolveTab(tab_ref) orelse return error.StaleSource;
    for (self.sources) |slot| if (slot) |source| if (!source.retired and source.tab.matches(tab_ref)) return error.Busy;
    const description = try describe(app.core_app.alloc, window, index);
    const fingerprint = try treeDigest(&description, app.ui_ids.epoch);
    const host = try Host.create(app);
    errdefer host.deinit();
    host.window.is_remote_host = true;
    const source = try app.core_app.alloc.create(Source);
    errdefer app.core_app.alloc.destroy(source);
    const serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
    const connection = try self.service.?.connect(target);
    connection.retain();
    source.* = .{ .connection = connection, .source_window = window_ref, .tab = tab_ref, .description = description, .drop_point = drop, .digest = fingerprint, .host = host, .state = try authority.SourceAuthority.init(app.ui_ids.epoch), .transaction = serial };
    self.serial = serial;
    free.* = source;
    self.syncTimer(app);
}
pub fn resolveHostWindow(self: *const Self, reference: refs.Reference) ?*Window {
    for (self.sources) |slot| if (slot) |source| if (source.host) |host| if (!host.window.closing and host.window.ui_reference.matches(reference)) return host.window;
    return null;
}
pub fn keepsAlive(self: *const Self) bool {
    for (self.sources) |slot| if (slot) |source| if (source.host != null and !source.retired) return true;
    for (self.targets) |slot| if (slot != null) return true;
    return false;
}
pub fn allowsLocalInput(self: *const Self, surface: refs.Reference) bool {
    for (self.sources) |slot| if (slot) |source| if (!source.retired and sourceLeaf(source, surface) != null) {
        const lease = source.state.input orelse return false;
        return lease.holder_epoch == surface.epoch;
    };
    return true;
}
pub fn closeHost(self: *Self, reference: refs.Reference) bool {
    if (self.resolveHostWindow(reference) == null) return false;
    return self.queue(.{ .close_source = reference });
}
/// Stop previews and revoke any preparing lease before the original owner is
/// destroyed. A per-source flag cannot be dropped by a full local input queue.
pub fn deferLocalWindowClose(self: *Self, reference: refs.Reference) bool {
    if (self.closing) return false;
    for (self.sources) |slot| if (slot) |source| {
        if (source.retired or source.moved or !source.source_window.matches(reference)) continue;
        source.close_deferred = true;
        source.recovering = true;
        if (self.app) |app| self.syncTimer(app);
        if (self.app) |app| if (app.msg_hwnd) |hwnd| {
            _ = w32.PostMessageW(hwnd, wake_message, 0, 0);
        };
        return true;
    };
    return false;
}
fn queue(self: *Self, event: Local) bool {
    if (self.closing or self.local_len == self.local.len) return false;
    self.local[(self.local_head + self.local_len) % self.local.len] = event;
    self.local_len += 1;
    if (self.app) |app| if (app.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, wake_message, 0, 0);
    };
    return true;
}
fn onInput(ctx: *anyopaque, window: refs.Reference, input: protocol.Input) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.closing) return false;
    const target = self.targetWindow(window) orelse return false;
    if (!target.source_revoked or !target.ever_enabled or target.window.unavailable) return false;
    const index = for (target.window.tree.nodes.slice(), 0..) |node, index| {
        if (node == .leaf and node.leaf.matches(input.surface)) break index;
    } else return false;
    var ordered = input;
    ordered.sequence = std.math.add(u64, target.input_sequence, 1) catch return false;
    const accepted = target.inputs.push(index, ordered);
    if (accepted) target.input_sequence = ordered.sequence;
    if (accepted) if (self.app) |app| if (app.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, wake_message, 0, 0);
    };
    return accepted;
}
pub fn queuePaste(self: *Self, pane: *RemotePane, transaction: u64, text: []const u8, parent: ?protocol.PasteParent) !void {
    if (self.closing or !std.unicode.utf8ValidateSlice(text)) return error.InvalidPaste;
    const target = self.targetWindow(pane.transfer_reference) orelse return error.InvalidSurface;
    if (!target.source_revoked or !target.ever_enabled or target.window.unavailable) return error.InputDisabled;
    const lease = pane.gate.lease orelse return error.InputDisabled;
    const sequence = try std.math.add(u64, target.input_sequence, 1);
    const owned = try pane.app.core_app.alloc.dupe(u8, text);
    errdefer pane.app.core_app.alloc.free(owned);
    if (!target.inputs.pushPaste(.{ .surface = pane.source_reference, .lease = lease, .sequence = sequence, .event = .{ .paste = .{ .transfer = transaction, .parent = parent, .index = 0, .last = false, .text = .{} } } }, owned)) return error.QueueFull;
    if (@import("remote_test.zig").enabled()) {
        const last = (target.inputs.head + target.inputs.len - 1) % target.inputs.ordered.len;
        log.info("remote paste queued requested={} stored={} producer_sequence={}", .{ transaction, target.inputs.ordered[last].?.input.event.paste.transfer, sequence });
    }
    target.input_sequence = sequence;
    if (pane.app.msg_hwnd) |hwnd| _ = w32.PostMessageW(hwnd, wake_message, 0, 0);
}
pub fn discardInput(self: *Self, source: refs.Reference, paste_only: bool) void {
    for (self.targets) |slot| if (slot) |target| if (target.window.pane(source) != null) {
        target.inputs.discardSurface(target.window.app.core_app.alloc, source, paste_only);
    };
}
fn onClose(ctx: *anyopaque, window: refs.Reference) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.queue(.{ .close_target = window });
}
fn targetWindow(self: *Self, reference: refs.Reference) ?*Target {
    for (self.targets) |slot| if (slot) |target| if (target.window.reference.matches(reference)) return target;
    return null;
}
fn sourceConnection(self: *Self, connection: *transport.Connection) ?*Source {
    for (self.sources) |slot| if (slot) |source| if (source.connection == connection) return source;
    return null;
}
fn targetConnection(self: *Self, connection: *transport.Connection) ?*Target {
    for (self.targets) |slot| if (slot) |target| if (target.connection == connection) return target;
    return null;
}

pub fn sendToSource(self: *Self, source: refs.Reference, body: protocol.Body) !u64 {
    if (self.closing) return error.NotReady;
    for (self.targets) |slot| if (slot) |target| {
        if (target.window.pane(source) == null) continue;
        if (target.window.unavailable or target.connection == null) continue;
        if (!target.source_revoked or !target.ever_enabled) return error.NotReady;
        return (target.connection orelse return error.NotConnected).sendBody(target.ticket, body);
    };
    return error.InvalidSurface;
}
/// Completion replies survive transient transport backpressure. They are
/// values owned by the GUI and are discarded, never replayed, on disconnect.
pub fn postToSource(self: *Self, source: refs.Reference, body: protocol.Body) !void {
    if (self.closing) return error.NotReady;
    for (self.targets) |slot| if (slot) |target| {
        if (target.window.pane(source) == null) continue;
        if (target.window.unavailable or target.connection == null) continue;
        send: {
            if (target.reply_len != 0) break :send;
            _ = target.connection.?.sendBody(target.ticket, body) catch |err| {
                if (err != error.QueueFull) return err;
                break :send;
            };
            return;
        }
        if (target.reply_len == target.replies.len) {
            target.connection.?.shutdown();
            return error.NotConnected;
        }
        const owned = try target.window.app.core_app.alloc.create(protocol.Body);
        owned.* = body;
        target.replies[(target.reply_head + target.reply_len) % target.replies.len] = owned;
        target.reply_len += 1;
        return;
    };
    return error.InvalidSurface;
}
pub fn sendToTarget(self: *Self, source: refs.Reference, body: protocol.Body) !u64 {
    if (self.closing) return error.NotReady;
    for (self.sources) |slot| if (slot) |entry| {
        if (entry.retired) continue;
        const contains = for (entry.description.nodes.slice()) |node| {
            if (node == .leaf and node.leaf.matches(source)) break true;
        } else false;
        if (!contains) continue;
        return (entry.connection orelse return error.NotConnected).sendBody(entry.ticket orelse return error.NotReady, body);
    };
    return error.InvalidSurface;
}
pub fn postToTarget(self: *Self, reference: refs.Reference, body: protocol.Body) !void {
    if (self.closing) return error.NotReady;
    for (self.sources) |slot| if (slot) |source| {
        if (source.retired or sourceLeaf(source, reference) == null) continue;
        const connection = source.connection orelse return error.NotConnected;
        send: {
            if (source.reply_len != 0) break :send;
            _ = connection.sendBody(source.ticket orelse return error.NotReady, body) catch |err| {
                if (err != error.QueueFull) return err;
                break :send;
            };
            return;
        }
        if (source.reply_len == source.replies.len) {
            connection.shutdown();
            return error.NotConnected;
        }
        const owned = try self.app.?.core_app.alloc.create(protocol.Body);
        owned.* = body;
        source.replies[(source.reply_head + source.reply_len) % source.replies.len] = owned;
        source.reply_len += 1;
        return;
    };
    return error.InvalidSurface;
}
pub fn resolveRemote(self: *Self, source: refs.Reference) ?*RemotePane {
    for (self.targets) |slot| if (slot) |target| if (target.window.pane(source)) |pane| return pane;
    return null;
}
pub fn acceptsSourceAction(self: *Self, reference: refs.Reference, lease: protocol.Lease) bool {
    for (self.sources) |slot| if (slot) |source| {
        if (!source.retired and source.moved and sourceLeaf(source, reference) != null and source.state.acceptsInput(lease)) return true;
    };
    return false;
}
/// Stop worker borrows before a source leaf is destroyed. Host output storage
/// remains owned until the outer drain retires the complete source group.
pub fn sourceLeafClosed(self: *Self, reference: refs.Reference) void {
    for (self.sources) |slot| if (slot) |source| {
        const index = sourceLeaf(source, reference) orelse continue;
        source.closed_leaves[index] = true;
        if (source.connection) |connection| connection.unwatchFrame(reference);
        if (self.app) |app| if (app.msg_hwnd) |hwnd| {
            _ = w32.PostMessageW(hwnd, wake_message, 0, 0);
        };
    };
}
/// A remote-only tab may return to its authenticated source host. A mixed tab
/// cannot be transferred as one authority domain, so leave its tree untouched.
pub fn returnRemoteTab(self: *Self, app: *App, tab: refs.Reference, process: policy.Process) !bool {
    const location = app.resolveTab(tab) orelse return error.StaleSource;
    const index = location.window.resolveTab(tab) orelse return error.StaleSource;
    var transfer: ?refs.Reference = null;
    var local_count: usize = 0;
    for (location.window.tab_trees[index].nodes) |node| if (node == .leaf) {
        if (node.leaf.local() != null) {
            local_count += 1;
            continue;
        }
        const pane = node.leaf.pane();
        const remote = app.resolveRemote(pane.reference()) orelse return error.StaleSource;
        if (transfer) |existing| {
            if (!existing.matches(remote.transfer_reference)) return error.MixedRemoteTransfer;
        } else transfer = remote.transfer_reference;
    };
    const reference = transfer orelse return false;
    if (local_count != 0) return error.MixedRemoteTransfer;
    const target = self.targetWindow(reference) orelse return error.StaleSource;
    const connection = target.connection orelse return error.NotConnected;
    if (!std.meta.eql(connection.peer.?.facts.identity.process, process)) return error.WrongSourceHost;
    if (!self.queue(.{ .close_target = reference })) return error.QueueFull;
    return true;
}

pub fn drain(self: *Self, app: *App) void {
    if (self.closing or self.draining) return;
    const service = self.service orelse return;
    self.draining = true;
    defer self.draining = false;
    var count: usize = 0;
    while (count < 128) : (count += 1) {
        var work = service.take() orelse break;
        defer work.release();
        switch (work.event) {
            .connected => if (self.sourceConnection(work.connection)) |source| {
                source.ticket = source.state.prepare(work.peer().epoch, source.transaction) catch {
                    self.reclaim(app, source) catch {};
                    continue;
                };
                source.mapping_generation = source.ticket.?.generation;
            },
            .disconnected => |reason| {
                if (reason != 0) log.warn("remote connection ended error={}", .{@as(anyerror, @errorFromInt(reason))});
                if (self.sourceConnection(work.connection)) |source| self.reclaim(app, source) catch |err| log.err("remote source reclaim failed: {}", .{err});
                if (self.targetConnection(work.connection)) |target| {
                    if (!target.ever_enabled) {
                        self.removeTarget(app, target) catch {};
                    } else {
                        target.window.disconnect();
                        target.inputs.clear(app.core_app.alloc);
                        target.connection.?.release();
                        target.connection = null;
                    }
                }
            },
            .resize_needed => |resize| if (self.sourceConnection(work.connection)) |source| {
                self.resizeMapping(app, source, resize.surface, resize.width, resize.height) catch |err| {
                    log.warn("remote resize mapping failed: {}", .{err});
                    self.reclaim(app, source) catch {};
                };
            },
            .frame_failed => if (self.sourceConnection(work.connection)) |source| self.reclaim(app, source) catch {},
            .packet => |packet| {
                if (packet.body == .acknowledgement) {
                    self.acknowledge(app, work.connection, packet);
                    continue;
                }
                self.mapping_consumed = false;
                self.handle(app, &work) catch |err| {
                    log.warn("remote control rejected kind={s} request={} error={}", .{ @tagName(std.meta.activeTag(packet.body)), packet.request_id, err });
                    // Even a stale/missing target transaction must retire a
                    // validated first-offer section received by this process.
                    if (packet.body == .mapping_offer and !self.mapping_consumed) {
                        if (channels.discardOffer(transport.nativeOffer(packet.body.mapping_offer), app.ui_ids.epoch, work.peer())) |_| {
                            self.mapping_consumed = true;
                        } else |discard_error| log.warn("rejected remote mapping discard refused: {}", .{discard_error});
                    }
                    const consumed = packet.body != .mapping_offer or self.mapping_consumed;
                    work.connection.finishMapping(&work, .rejected, consumed) catch {};
                    if (packet.body == .target_enabled) if (self.sourceConnection(work.connection)) |source| self.reclaim(app, source) catch {};
                    continue;
                };
                work.connection.finish(&work, .completed) catch |err| {
                    // finish records the completed result before enqueueing ACK.
                    // QueueFull is recovered by query/state; never execute twice.
                    if (err != error.QueueFull and err != error.NotConnected) log.warn("remote ACK failed: {}", .{err});
                };
            },
        }
    }
    while (self.local_len != 0) {
        const event = self.local[self.local_head];
        switch (event) {
            .close_target => |reference| if (self.targetWindow(reference)) |target| {
                if (target.connection) |connection| {
                    _ = connection.sendBody(target.ticket, .abort) catch 0;
                    connection.shutdown();
                }
                self.removeTarget(app, target) catch |err| log.warn("remote target close failed: {}", .{err});
            },
            .close_source => |reference| for (self.sources) |slot| if (slot) |source| if (source.host) |host| {
                if (!host.window.ui_reference.matches(reference)) continue;
                source.state.shutdown();
                if (source.ticket) |ticket| if (source.connection) |connection| {
                    if (source.state.query(ticket)) |status| {
                        _ = connection.sendBody(ticket, .{ .status = status }) catch 0;
                    } else |_| {}
                };
                self.retireHost(app, source);
            },
        }
        self.local_head = (self.local_head + 1) % self.local.len;
        self.local_len -= 1;
    }
    for (&self.sources) |*slot| if (slot.*) |source| {
        self.reapClosedOutputs(app, source);
        if (!source.retired and allSourceLeavesClosed(source) and source.reply_len == 0 and
            (source.connection == null or source.connection.?.outputDrained())) self.retireHost(app, source);
        if (!source.retired) self.progressSource(app, source) catch |err| {
            if (err != error.QueueFull) {
                log.warn("remote source progress failed: {}", .{err});
                self.reclaim(app, source) catch {};
            }
        };
        self.reapExports(source);
        if (source.retired and source.host == null and source.exports.items.len == 0) {
            if (source.connection) |connection| connection.release();
            source.exports.deinit(app.core_app.alloc);
            app.core_app.alloc.destroy(source);
            slot.* = null;
        }
    };
    for (self.targets) |slot| if (slot) |target| {
        var all_closed = true;
        for (target.window.panes) |entry| if (entry) |pane| if (!pane.closed) {
            all_closed = false;
            pane.ui.drain(pane);
        };
        if (all_closed) {
            self.removeTarget(app, target) catch {};
            continue;
        }
        self.progressTarget(target) catch |err| {
            if (err != error.QueueFull and err != error.NotConnected) target.window.disconnect();
        };
    };
    RemoteSource.drain(app);
    self.progressFanouts(app);
    service.reap();
    self.syncTimer(app);
}
fn syncTimer(self: *Self, app: *App) void {
    var needed = false;
    for (self.sources) |slot| if (slot) |source| {
        if ((!source.retired and (!source.moved or source.recovering or source.close_deferred or !source.revoked_sent)) or
            (source.retired and source.exports.items.len != 0)) needed = true;
        if (!source.retired) for (source.exports.items) |item| {
            if (!item.settled or !item.receipt_acked) needed = true;
        };
    };
    for (self.targets) |slot| if (slot) |target| {
        if (target.connection != null and !target.window.unavailable and (!target.source_revoked or target.resend_receipts != null)) needed = true;
    };
    if (self.closing) needed = false;
    if (needed == self.timer_active) return;
    const hwnd = app.msg_hwnd orelse return;
    if (needed) {
        self.timer_active = w32.SetTimer(hwnd, timer_id, 250, null) != 0;
    } else {
        _ = w32.KillTimer(hwnd, timer_id);
        self.timer_active = false;
    }
}

fn progressSource(self: *Self, app: *App, source: *Source) !void {
    if (source.connection) |connection| while (source.reply_len != 0) {
        const body = source.replies[source.reply_head].?;
        _ = try connection.sendBody(source.ticket orelse return error.NotReady, body.*);
        app.core_app.alloc.destroy(body);
        source.replies[source.reply_head] = null;
        source.reply_head = (source.reply_head + 1) % source.replies.len;
        source.reply_len -= 1;
    };
    if (allSourceLeavesClosed(source)) return;
    if (source.recovering) return self.reclaim(app, source);
    const ticket = source.ticket orelse return;
    const connection = source.connection orelse return;
    if (source.prepare_request == null) {
        var description = source.description;
        description.drop_point = source.drop_point;
        source.prepare_request = try connection.sendBody(ticket, .{ .prepare = description });
        source.last_query = native.Deadline.init(0).end;
        return;
    }
    const now = native.Deadline.init(0).end;
    if (now -| source.last_query >= 2000 and !source.moved) {
        source.query_request = try connection.sendBody(ticket, .query);
        source.last_query = now;
    }
    if (!source.prepare_accepted) return;
    const host = source.host orelse return error.InvalidHost;
    if (!source.outputs_prepared) {
        try unchanged(app, source);
        try source.exports.ensureUnusedCapacity(app.core_app.alloc, protocol.max_leaves);
        for (source.description.nodes.slice()) |node| if (node == .leaf) {
            const surface = app.resolveSurface(node.leaf) orelse return error.StaleSource;
            const width = @max(1, surface.width);
            const height = @max(1, surface.height);
            const layout = try channels.Layout.checked(width, height, width * 4);
            try self.checkBudget(sourceBytes(source), layout.total_bytes);
            const channel = try channels.Channel.createSource(app.core_app.alloc, layout, source.mapping_generation, ticket.source_epoch, &connection.peer.?);
            var owned = false;
            defer if (!owned) channel.deinit() catch {};
            const output = try host.prepareOutput(surface, channel, connection.frameWakeHandle());
            owned = true;
            const exported = try channel.exportToPeer();
            source.export_serial += 1;
            source.exports.appendAssumeCapacity(.{ .value = exported, .surface = node.leaf, .id = source.export_serial });
            // Wire mapping offer is queued before frame notifications are enabled.
            _ = output;
            try surface.core_surface.refreshCallback();
        };
        source.outputs_prepared = true;
    }
    for (source.exports.items) |*item| if (item.settled and !item.receipt_acked and (!item.receipt_sent or now -| item.receipt_time >= 2000)) {
        item.receipt_request = try connection.sendBody(ticket, .{ .mapping_receipt = .{ .offer_id = item.id, .target_handle = item.value.offer.target_handle } });
        item.receipt_sent = true;
        item.receipt_time = now;
    };
    for (source.exports.items) |*item| if (item.request == null) {
        item.request = try connection.sendBody(ticket, .{ .mapping_offer = transport.mappingOffer(item.surface, item.id, item.value.offer) });
        const output = host.findOutput(item.surface) orelse return error.InvalidHost;
        try watch(connection, item.surface, ticket, output);
    };
    if (source.state.active) |status| {
        if (status.phase == .preparing) {
            const all = for (source.exports.items) |item| {
                if (!item.accepted) break false;
            } else true;
            if (all) try source.state.ready(ticket, ticket.source_epoch);
        }
    }
    if (source.state.active) |status| if (status.phase == .ready or status.phase == .committed) {
        if (source.commit_request == null) {
            try unchanged(app, source);
            const lease = try source.state.commit(ticket);
            source.commit_request = try connection.sendBody(ticket, .{ .commit = lease });
        }
    };
    if (source.moved and !source.revoked_sent) {
        _ = try connection.sendBody(ticket, .source_revoked);
        source.revoked_sent = true;
    }
}
fn progressTarget(self: *Self, target: *Target) !void {
    _ = self;
    const connection = target.connection orelse return;
    while (target.reply_len != 0) {
        const body = target.replies[target.reply_head].?;
        _ = try connection.sendBody(target.ticket, body.*);
        target.window.app.core_app.alloc.destroy(body);
        target.replies[target.reply_head] = null;
        target.reply_head = (target.reply_head + 1) % target.replies.len;
        target.reply_len -= 1;
    }
    if (target.resend_receipts) |start| {
        var index = start;
        while (index < target.receipts.len) : (index += 1) {
            target.resend_receipts = index;
            if (target.receipts[index]) |receipt| {
                const packet: protocol.Packet = .{ .sender_epoch = target.ticket.target_epoch, .recipient_epoch = target.ticket.source_epoch, .request_id = receipt.request_id, .ticket = target.ticket, .body = .{ .acknowledgement = .{ .outcome = receipt.outcome, .offer_id = receipt.offer_id, .target_handle = receipt.target_handle } } };
                try connection.send(&packet);
            }
        }
        target.resend_receipts = null;
    }
    if (target.window.unavailable) return;
    if (!target.ready_sent and target.window.allFrames()) {
        _ = try connection.sendBody(target.ticket, .ready);
        target.ready_sent = true;
        target.last_query = native.Deadline.init(0).end;
    }
    if (target.ever_enabled and !target.enabled_sent) {
        _ = try connection.sendBody(target.ticket, .target_enabled);
        target.enabled_sent = true;
    }
    // An unknown/missing commit notification is resolved from source authority;
    // query never replays a command or a terminal input operation.
    const now = native.Deadline.init(0).end;
    if (target.ready_sent and !target.source_revoked and now -| target.last_query >= 2000) {
        _ = try connection.sendBody(target.ticket, .query);
        target.last_query = now;
    }
    if (target.source_revoked and target.ever_enabled and target.input_request == null) if (target.inputs.peek()) |input| {
        var ordered = input;
        ordered.sequence = try std.math.add(u64, target.wire_sequence, 1);
        if (@import("remote_test.zig").enabled() and ordered.event == .paste) log.info("remote paste sending queued_transfer={} wire_transfer={} chunk={} wire_sequence={}", .{ input.event.paste.transfer, ordered.event.paste.transfer, ordered.event.paste.index, ordered.sequence });
        const request = try connection.sendBody(target.ticket, .{ .input = ordered });
        target.wire_sequence = ordered.sequence;
        target.input_request = .{ .request = request, .sequence = input.sequence, .surface = input.surface };
    };
}

fn handle(self: *Self, app: *App, work: *transport.Work) !void {
    const packet = work.event.packet;
    if (packet.body == .prepare) {
        if (self.targetConnection(work.connection) != null or self.sourceConnection(work.connection) != null) return error.Busy;
        const slot = for (&self.targets) |*entry| {
            if (entry.* == null) break entry;
        } else return error.Busy;
        const target = try app.core_app.alloc.create(Target);
        errdefer app.core_app.alloc.destroy(target);
        const window = try TargetTree.create(app, &packet.body.prepare, packet.ticket, .{ .ctx = self, .input = onInput, .close_requested = onClose });
        work.connection.retain();
        target.* = .{ .connection = work.connection, .window = window, .ticket = packet.ticket };
        slot.* = target;
        app.stopQuitTimer();
        return;
    }
    if (self.sourceConnection(work.connection)) |source| {
        const ticket = source.ticket orelse return error.NotReady;
        if (!std.meta.eql(ticket, packet.ticket) or source.retired) return error.StaleTransaction;
        if (RemoteSource.messageSurface(&packet.body)) |reference| {
            if (sourceLeaf(source, reference) == null) return error.InvalidSurface;
            if (try RemoteSource.handle(app, self, packet)) return;
        }
        switch (packet.body) {
            .ready => try source.state.ready(ticket, work.peer().epoch),
            .target_enabled => {
                try source.state.targetEnabled(ticket, work.peer().epoch);
                if (!source.moved) {
                    try unchanged(app, source);
                    const from = app.resolveWindow(source.source_window) orelse return error.StaleSource;
                    const host = source.host orelse return error.InvalidHost;
                    if (!try from.moveTabToWindow(source.tab, host.window.ui_reference, 0)) return error.MoveFailed;
                    source.moved = true;
                    host.detachPreviews();
                }
                try source.state.sourceRevoked(ticket);
                for (source.description.nodes.slice()) |node| if (node == .leaf) {
                    const surface = app.resolveSurface(node.leaf) orelse return error.StaleSource;
                    try RemoteSource.install(surface, source.state.input.?);
                };
            },
            .input => |*input| try applyInput(app, source, input),
            .query => {
                _ = try work.connection.sendBody(ticket, .{ .status = try source.state.query(ticket) });
            },
            .abort => try self.reclaim(app, source),
            else => return error.UnsupportedMessage,
        }
        return;
    }
    const target = self.targetConnection(work.connection) orelse return error.UnknownTransaction;
    if (!std.meta.eql(target.ticket, packet.ticket)) return error.StaleTransaction;
    const remote_reference: ?refs.Reference = switch (packet.body) {
        inline .ui_action, .ui_event, .inspector_result, .apply_action_result, .surface_state, .confirm_request, .text_snapshot_result, .keybind_snapshot_result, .leaf_closed, .clipboard_request => |value| value.surface,
        else => null,
    };
    if (remote_reference) |reference| {
        const pane = target.window.pane(reference) orelse return error.InvalidSurface;
        if (try @import("RemotePaneUi.zig").handlePacket(app, pane, packet)) return;
    }
    switch (packet.body) {
        .mapping_offer => |mapping| {
            const receipt_slot = for (&target.receipts) |*entry| {
                if (entry.* == null) break entry;
            } else {
                try channels.discardOffer(transport.nativeOffer(mapping), app.ui_ids.epoch, work.peer());
                self.mapping_consumed = true;
                return error.ReceiptQueueFull;
            };
            // Admission is bounded before mapping/copying the offered pixels.
            self.checkBudget(targetBytes(target), mapping.bytes + @as(u64, mapping.stride) * mapping.height) catch |err| {
                try channels.discardOffer(transport.nativeOffer(mapping), app.ui_ids.epoch, work.peer());
                self.mapping_consumed = true;
                receipt_slot.* = .{ .request_id = packet.request_id, .offer_id = mapping.offer_id, .target_handle = mapping.target_handle, .outcome = .rejected };
                return err;
            };
            const channel = channels.Channel.acceptTracked(app.core_app.alloc, transport.nativeOffer(mapping), app.ui_ids.epoch, work.peer(), &self.mapping_consumed) catch |err| {
                if (self.mapping_consumed) receipt_slot.* = .{ .request_id = packet.request_id, .offer_id = mapping.offer_id, .target_handle = mapping.target_handle, .outcome = .rejected };
                return err;
            };
            var consumed = false;
            defer if (!consumed) channel.deinit() catch {};
            target.window.acceptMapping(mapping.surface, channel) catch |err| {
                receipt_slot.* = .{ .request_id = packet.request_id, .offer_id = mapping.offer_id, .target_handle = mapping.target_handle, .outcome = .rejected };
                return err;
            };
            consumed = true;
            receipt_slot.* = .{ .request_id = packet.request_id, .offer_id = mapping.offer_id, .target_handle = mapping.target_handle, .outcome = .completed };
        },
        .mapping_receipt => |receipt| {
            for (&target.receipts) |*entry| if (entry.*) |cached| if (cached.offer_id == receipt.offer_id) {
                if (cached.target_handle != receipt.target_handle) return error.InvalidReceipt;
                target.consumed_receipts[target.consumed_next] = .{ .offer_id = receipt.offer_id, .target_handle = receipt.target_handle };
                target.consumed_next = (target.consumed_next + 1) % target.consumed_receipts.len;
                entry.* = null;
                return;
            };
            for (target.consumed_receipts) |entry| if (entry) |cached| if (cached.offer_id == receipt.offer_id and cached.target_handle == receipt.target_handle) return;
            return error.InvalidReceipt;
        },
        .frame_ready => |frame| {
            const index = for (target.window.tree.nodes.slice(), 0..) |node, index| {
                if (node == .leaf and node.leaf.matches(frame.surface)) break index;
            } else return error.InvalidSurface;
            const pane = target.window.panes[index] orelse return error.NotReady;
            const view = if (pane.view) |*value| value else return error.NotReady;
            if (view.channel.mapped.generation != frame.generation) return error.StaleMapping;
            target.window.frameReady(frame.surface);
        },
        .commit => |lease| {
            target.committed = true;
            try target.window.enableLease(lease);
            target.ever_enabled = true;
        },
        .source_revoked => {
            if (!target.ever_enabled) return error.NotCommitted;
            target.source_revoked = true;
            target.window.activateInput();
        },
        .status => |status| switch (status.phase) {
            .committed, .target_enabled, .remote => {
                target.committed = true;
                if (!target.ever_enabled) {
                    try target.window.enableLease(.{ .holder_epoch = target.ticket.target_epoch, .generation = target.ticket.generation, .transaction = target.ticket.transaction });
                    target.ever_enabled = true;
                }
                if (status.phase == .remote) {
                    target.source_revoked = true;
                    target.window.activateInput();
                }
                target.enabled_sent = false;
            },
            .aborted, .reclaimed, .source_lost => {
                if (!target.ever_enabled) try self.removeTarget(app, target) else {
                    target.window.disconnect();
                    target.inputs.clear(app.core_app.alloc);
                }
            },
            else => {},
        },
        .query => {
            target.ready_sent = false;
            target.enabled_sent = false;
            target.resend_receipts = 0;
        },
        .abort => {
            if (!target.ever_enabled) try self.removeTarget(app, target) else {
                target.window.disconnect();
                target.inputs.clear(app.core_app.alloc);
            }
        },
        else => return error.UnsupportedMessage,
    }
}
fn acknowledge(self: *Self, app: *App, connection: *transport.Connection, packet: *const protocol.Packet) void {
    if (self.targetConnection(connection)) |target| {
        if (!std.meta.eql(target.ticket, packet.ticket)) return;
        if (target.input_request) |pending| if (pending.request == packet.request_id) {
            target.input_request = null;
            if (packet.body.acknowledgement.outcome != .completed) {
                if (target.window.pane(pending.surface)) |pane| if (pane.closed) return;
                target.window.disconnect();
                target.inputs.clear(app.core_app.alloc);
                connection.shutdown();
                return;
            }
            if (target.inputs.pop(pending.sequence)) |bytes| app.core_app.alloc.free(bytes);
        };
        return;
    }
    const source = self.sourceConnection(connection) orelse return;
    if (source.ticket == null or !std.meta.eql(source.ticket.?, packet.ticket)) return;
    const result = packet.body.acknowledgement;
    if (source.prepare_request == packet.request_id) {
        if (result.outcome == .completed) source.prepare_accepted = true else self.reclaim(app, source) catch {};
        return;
    }
    if (source.query_request == packet.request_id) {
        if (result.outcome == .completed) source.prepare_accepted = true;
        return;
    }
    for (source.exports.items) |*item| if (item.request == packet.request_id) {
        if (result.offer_id == item.id and result.target_handle == 0 and result.outcome != .completed) {
            self.reclaim(app, source) catch {};
            return;
        }
        if (result.offer_id != item.id or result.target_handle != item.value.offer.target_handle) return;
        item.value.acknowledge(&connection.peer.?, item.value.offer.generation, result.target_handle) catch return;
        item.settled = true;
        item.accepted = result.outcome == .completed;
        if (!item.accepted) self.reclaim(app, source) catch {};
        return;
    };
    for (source.exports.items) |*item| if (item.receipt_request == packet.request_id) {
        if (result.outcome == .completed) item.receipt_acked = true;
        return;
    };
    if (source.commit_request == packet.request_id and result.outcome != .completed) self.reclaim(app, source) catch {};
}

fn watch(connection: *transport.Connection, surface: refs.Reference, ticket: protocol.Ticket, output: *Output) !void {
    try connection.watchFrame(.{ .surface = surface, .ticket = ticket, .generation = output.channel.mapped.generation, .sequence = &output.latest_sequence, .requested_size = &output.requested_size, .failed = &output.failed });
}
fn resizeMapping(self: *Self, app: *App, source: *Source, reference: refs.Reference, width: u32, height: u32) !void {
    if (!source.moved or source.retired or sourceLeaf(source, reference) == null) return error.NotReady;
    const host = source.host orelse return error.InvalidHost;
    const connection = source.connection orelse return error.NotReady;
    const ticket = source.ticket.?;
    const surface = app.resolveSurface(reference) orelse return error.StaleSource;
    const previous = host.findOutput(reference) orelse return error.InvalidHost;
    if (previous.channel.mapped.layout.width == width and previous.channel.mapped.layout.height == height) return;
    if (source.exports.items.len >= 256) return error.Busy;
    try source.exports.ensureUnusedCapacity(app.core_app.alloc, 1);
    const generation = std.math.add(u64, source.mapping_generation, 1) catch return error.Exhausted;
    const layout = try channels.Layout.checked(width, height, width * 4);
    try self.checkBudget(sourceBytes(source), layout.total_bytes);
    const channel = try channels.Channel.createSource(app.core_app.alloc, layout, generation, ticket.source_epoch, &connection.peer.?);
    var consumed = false;
    defer if (!consumed) channel.deinit() catch {};
    connection.unwatchFrame(reference);
    const old = host.replaceOutputWithWake(surface, channel, connection.frameWakeHandle()) catch |err| {
        try watch(connection, reference, ticket, previous);
        return err;
    };
    consumed = true;
    old.deinit();
    const exported = try channel.exportToPeer();
    source.mapping_generation = generation;
    source.export_serial += 1;
    source.exports.appendAssumeCapacity(.{ .value = exported, .surface = reference, .id = source.export_serial });
    try surface.core_surface.refreshCallback();
}
fn applyInput(app: *App, source: *Source, input: *const protocol.Input) !void {
    if (!source.moved or source.retired) return error.NotReady;
    const index = sourceLeaf(source, input.surface) orelse return error.InvalidSurface;
    try source.input_sequence[index].accept(&source.state, input);
    const surface = app.resolveSurface(input.surface) orelse return error.StaleSource;
    if (surface.parent_window != source.host.?.window or !surface.core_surface_ready) return error.InvalidOwner;
    try RemoteSource.applyInput(app, surface, input);
}
fn sourceLeaf(source: *const Source, reference: refs.Reference) ?usize {
    for (source.description.nodes.slice(), 0..) |node, index| if (!source.closed_leaves[index] and node == .leaf and node.leaf.matches(reference)) return index;
    return null;
}
fn allSourceLeavesClosed(source: *const Source) bool {
    for (source.description.nodes.slice(), 0..) |node, index| if (node == .leaf and !source.closed_leaves[index]) return false;
    return true;
}
fn unchanged(app: *App, source: *Source) !void {
    const window = app.resolveWindow(source.source_window) orelse return error.StaleSource;
    const index = window.resolveTab(source.tab) orelse return error.StaleSource;
    const current = try describe(app.core_app.alloc, window, index);
    const fingerprint = try treeDigest(&current, app.ui_ids.epoch);
    if (!std.mem.eql(u8, &fingerprint, &source.digest)) return error.SourceChanged;
}
fn describe(alloc: std.mem.Allocator, window: *Window, tab: usize) !protocol.Tree {
    const tree = &window.tab_trees[tab];
    if (tree.nodes.len == 0 or tree.nodes.len > protocol.max_nodes) return error.LimitExceeded;
    var result: protocol.Tree = .{ .nodes = .{ .len = @intCast(tree.nodes.len) }, .root = 0, .active = @intCast((tree.locate(window.tab_active_surface[tab]) orelse return error.InvalidTree).idx()), .zoom = if (tree.zoomed) |zoom| @intCast(zoom.idx()) else null };
    for (tree.nodes, result.nodes.items[0..tree.nodes.len]) |node, *out| out.* = switch (node) {
        .leaf => |leaf| .{ .leaf = (leaf.local() orelse return error.MixedRemoteTransfer).ui_reference },
        .split => |split| .{ .split = .{ .axis = if (split.layout == .horizontal) .horizontal else .vertical, .ratio = @floatCast(split.ratio), .first = @intCast(split.left.idx()), .second = @intCast(split.right.idx()) } },
    };
    if (window.tab_title_overrides[tab]) |title| {
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, title.buf[0..title.len]);
        defer alloc.free(utf8);
        result.tab_override = try protocol.Title.init(utf8);
    }
    if (window.window_title_override_len) |len| {
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, window.window_title_override[0..len]);
        defer alloc.free(utf8);
        result.window_override = try protocol.Title.init(utf8);
    }
    return result;
}
fn treeDigest(tree: *const protocol.Tree, epoch: u128) ![32]u8 {
    const other = if (epoch == 1) @as(u128, 2) else 1;
    const packet: protocol.Packet = .{ .sender_epoch = epoch, .recipient_epoch = other, .request_id = 1, .ticket = .{ .source_epoch = epoch, .target_epoch = other, .transaction = 1, .generation = 1 }, .body = .{ .prepare = tree.* } };
    var bytes: [protocol.max_frame_size]u8 = undefined;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try protocol.encode(&bytes, &packet), &hash, .{});
    return hash;
}

fn reclaim(self: *Self, app: *App, source: *Source) !void {
    if (source.retired) return;
    if (allSourceLeavesClosed(source)) {
        self.retireHost(app, source);
        return;
    }
    source.recovering = true;
    if (source.ticket) |ticket| {
        try source.state.disconnect(ticket);
        if (source.connection) |connection| {
            _ = connection.sendBody(ticket, .{ .status = try source.state.query(ticket) }) catch 0;
        }
    }
    if (source.moved) {
        const host = source.host orelse return error.InvalidHost;
        // A close receipt can arrive before its posted native WM_CLOSE. Such
        // leaves are already terminally closed and must not reappear locally.
        for (source.description.nodes.slice(), 0..) |node, index| if (node == .leaf and source.closed_leaves[index]) {
            if (app.resolveSurface(node.leaf)) |surface| if (surface.leaf) |leaf| {
                surface.parent_window.removeLeaf(leaf);
            };
        };
        const previous = app.resolveWindow(source.source_window);
        const destination = previous orelse try app.newWindow(.{});
        if (previous == null) {
            source.source_window = destination.ui_reference;
            if (source.description.window_override.len != 0) {
                const title = try app.core_app.alloc.dupeZ(u8, source.description.window_override.slice());
                defer app.core_app.alloc.free(title);
                destination.setWindowTitle(title);
            }
        }
        if (!try host.window.moveTabToWindow(source.tab, destination.ui_reference, 0)) return error.RestoreFailed;
        source.moved = false;
    }
    self.retireHost(app, source);
}
fn retireHost(self: *Self, app: *App, source: *Source) void {
    _ = self;
    source.retired = true;
    for (&source.replies) |*entry| if (entry.*) |body| {
        app.core_app.alloc.destroy(body);
        entry.* = null;
    };
    source.reply_len = 0;
    for (source.description.nodes.slice()) |node| if (node == .leaf) if (app.resolveSurface(node.leaf)) |surface| RemoteSource.release(surface);
    if (source.connection) |connection| {
        for (source.description.nodes.slice()) |node| if (node == .leaf) connection.unwatchFrame(node.leaf);
    }
    if (source.host) |host| {
        host.deinit();
        source.host = null;
    }
    if (source.connection) |connection| {
        connection.shutdown();
        connection.release();
        source.connection = null;
    }
    if (source.close_deferred) {
        source.close_deferred = false;
        if (app.resolveWindow(source.source_window)) |window| if (window.hwnd) |hwnd| {
            _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        };
    }
}
fn reapExports(self: *Self, source: *Source) void {
    _ = self;
    var index: usize = 0;
    while (index < source.exports.items.len) {
        const item = &source.exports.items[index];
        // During prepare keep settled entries to establish all-mappings-ready.
        if (!source.retired) {
            if (!source.moved or !item.receipt_acked) {
                index += 1;
                continue;
            }
            const closed = for (source.description.nodes.slice(), 0..) |node, leaf_index| {
                if (node == .leaf and node.leaf.matches(item.surface)) break source.closed_leaves[leaf_index];
            } else false;
            const current = if (source.host) |host| host.findOutput(item.surface) else null;
            if (current) |output| if (output.channel.mapped.generation == item.value.offer.generation) {
                index += 1;
                continue;
            };
            const replaced = for (source.exports.items) |later| {
                if (later.surface.matches(item.surface) and later.value.offer.generation > item.value.offer.generation and later.accepted) break true;
            } else false;
            if (!closed and !replaced) {
                index += 1;
                continue;
            }
        }
        item.value.deinit() catch {
            index += 1;
            continue;
        };
        _ = source.exports.orderedRemove(index);
    }
}
fn reapClosedOutputs(_: *Self, app: *App, source: *Source) void {
    const host = source.host orelse return;
    var index: usize = 0;
    while (index < host.outputs.items.len) {
        const binding = host.outputs.items[index];
        // The native Surface destructor has cleared the render borrow before
        // its identity disappears. A close-request alone is not sufficient.
        if (app.resolveSurface(binding.surface) != null) {
            index += 1;
            continue;
        }
        if (source.connection) |connection| connection.unwatchFrame(binding.surface);
        const removed = host.outputs.orderedRemove(index);
        removed.output.deinit();
    }
}
fn sourceBytes(source: *const Source) u64 {
    var bytes: u64 = 0;
    for (source.exports.items) |item| bytes +|= item.value.offer.bytes;
    return bytes;
}
fn targetBytes(target: *const Target) u64 {
    var bytes: u64 = 0;
    for (target.window.panes) |entry| if (entry) |pane| if (pane.view) |value| {
        bytes +|= value.channel.mapped.layout.total_bytes;
        bytes +|= value.last_frame.len;
    };
    return bytes;
}
fn checkBudget(self: *const Self, transfer_used: u64, additional: u64) !void {
    if (transfer_used +| additional > transfer_budget) return error.RemoteMemoryBudget;
    var used: u64 = 0;
    for (self.sources) |slot| if (slot) |source| {
        used +|= sourceBytes(source);
    };
    for (self.targets) |slot| if (slot) |target| {
        used +|= targetBytes(target);
    };
    if (used +| additional > process_budget) return error.RemoteMemoryBudget;
}
fn removeTarget(self: *Self, app: *App, target: *Target) !void {
    target.inputs.clear(app.core_app.alloc);
    for (&target.replies) |*slot| if (slot.*) |body| {
        app.core_app.alloc.destroy(body);
        slot.* = null;
    };
    try target.window.deinit();
    if (target.connection) |connection| connection.release();
    for (&self.targets) |*slot| if (slot.* == target) {
        slot.* = null;
        break;
    };
    app.core_app.alloc.destroy(target);
}
pub fn shutdown(self: *Self, app: *App) void {
    if (self.closing) return;
    self.closing = true;
    self.paste_fanout = .{};
    if (app.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, timer_id);
    self.timer_active = false;
    for (&self.fanouts) |*entry| if (entry.*) |aggregate| {
        aggregate.closing.deinit(app.core_app.alloc);
        app.core_app.alloc.destroy(aggregate);
        entry.* = null;
    };
    const service = self.service orelse return;
    service.shutdown();
    while (service.take()) |value| {
        var work = value;
        discardWork(app, &work);
        work.release();
    }
    for (self.targets) |slot| if (slot) |target| self.removeTarget(app, target) catch {};
    for (&self.sources) |*slot| if (slot.*) |source| {
        self.retireHost(app, source);
        self.reapExports(source);
        // Unacknowledged foreign handles are never force-closed or reused.
        // Their bounded tracking remains until process exit if the peer lives.
        for (source.exports.items) |*item| item.value.abandonLocalTrackingOnShutdown();
        source.exports.deinit(app.core_app.alloc);
        app.core_app.alloc.destroy(source);
        slot.* = null;
    };
    // A reader stopping concurrently may publish its final owned packet.
    service.destroy() catch {
        while (service.take()) |value| {
            var work = value;
            discardWork(app, &work);
            work.release();
        }
        service.destroy() catch |err| {
            log.err("remote service shutdown pending: {}", .{err});
            return;
        };
    };
    self.service = null;
}
fn discardWork(app: *App, work: *transport.Work) void {
    if (work.event == .packet and work.event.packet.body == .mapping_offer) {
        channels.discardOffer(transport.nativeOffer(work.event.packet.body.mapping_offer), app.ui_ids.epoch, work.peer()) catch |err| log.warn("shutdown mapping discard refused: {}", .{err});
    }
}

test "remote coordinator production control entrypoints compile" {
    inline for (.{ &initialize, &begin, &drain, &shutdown, &resolveHostWindow, &keepsAlive, &allowsLocalInput, &closeHost, &deferLocalWindowClose }) |function| try std.testing.expect(@intFromPtr(function) != 0);
}

test "remote concurrent paste fanouts reject the second source and release exact operation" {
    const first: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 10, .generation = 1 };
    const second: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 11, .generation = 1 };
    var request: protocol.ActionRequest = .{ .surface = first, .lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 }, .transaction = 5, .config_generation = 1, .action = try protocol.ActionText.init("paste_from_clipboard"), .all = true };
    try std.testing.expect(isPasteFanout(.paste_from_clipboard, request));
    request.all = false;
    try std.testing.expect(!isPasteFanout(.paste_from_clipboard, request));
    request.global = true;
    try std.testing.expect(isPasteFanout(.paste_from_selection, request));
    try std.testing.expect(!isPasteFanout(.{ .copy_to_clipboard = .mixed }, request));

    var coordinator: Self = .{};
    var a: Fanout = .{ .id = 1, .origin = first, .request = request, .remaining = 2, .dispatching = false };
    var b: Fanout = .{ .id = 2, .origin = second, .request = request, .remaining = 1, .dispatching = false };
    coordinator.fanouts[0] = &a;
    coordinator.fanouts[1] = &b;
    try std.testing.expect(coordinator.paste_fanout.acquire(a.id));
    // B is refused before it can send an ordinary paste back to A. Its source
    // chain can end, allowing A's already-admitted paste at B to complete.
    try std.testing.expect(!coordinator.paste_fanout.acquire(b.id));
    coordinator.completeFanout(a.id, false);
    try std.testing.expectEqual(@as(?u64, a.id), coordinator.paste_fanout.owner);
    coordinator.completeFanout(a.id, true);
    try std.testing.expect(coordinator.paste_fanout.owner == null);
    try std.testing.expect(a.performed);

    try std.testing.expect(coordinator.paste_fanout.acquire(b.id));
    coordinator.cancelPasteFanouts(first);
    try std.testing.expectEqual(@as(?u64, b.id), coordinator.paste_fanout.owner);
    coordinator.cancelPasteFanouts(second);
    try std.testing.expect(coordinator.paste_fanout.owner == null);
    try std.testing.expect(b.cancelled);
    try std.testing.expect(!b.performed);
    try std.testing.expect(coordinator.paste_fanout.acquire(3));
    coordinator.completeFanout(b.id, true);
    coordinator.paste_fanout.release(a.id);
    try std.testing.expectEqual(@as(?u64, 3), coordinator.paste_fanout.owner);
    try std.testing.expect(!b.performed);
}

test "remote coordinator refuses transfer and aggregate mapping budget before allocation" {
    var coordinator: Self = .{};
    try coordinator.checkBudget(transfer_budget - 1, 1);
    try std.testing.expectError(error.RemoteMemoryBudget, coordinator.checkBudget(transfer_budget, 1));
    var exports: [1]Export = undefined;
    exports[0].value.offer.bytes = transfer_budget;
    var first: Source = undefined;
    first.exports = .{ .items = &exports, .capacity = exports.len };
    var second: Source = undefined;
    second.exports = .{ .items = &exports, .capacity = exports.len };
    coordinator.sources[0] = &first;
    coordinator.sources[1] = &second;
    try std.testing.expectError(error.RemoteMemoryBudget, coordinator.checkBudget(0, 1));
}
