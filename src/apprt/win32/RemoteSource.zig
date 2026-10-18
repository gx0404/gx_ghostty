//! Source-owned terminal input and resolved binding continuations.
//! All entry points run on the GUI thread; no callback opens hidden-host UI.
const std = @import("std");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const CoreSurface = @import("../../Surface.zig");
const Coordinator = @import("RemoteCoordinator.zig");
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const global = @import("../../global.zig");
const protocol = @import("../../gx/remote_protocol.zig");
const binding = @import("../../gx/remote_binding.zig");
const refs = @import("../../gx/ui_ref.zig");
const win_input = @import("../../gx/win32_input.zig");
const terminal = @import("../../terminal/main.zig");
const w32 = @import("win32.zig");
const perf = @import("../../gx/perf.zig");
const RemoteControls = @import("RemoteControls.zig");

fn trace(comptime format: []const u8, args: anytype) void {
    if (!@import("remote_test.zig").enabled()) return;
    std.log.scoped(.win32_remote_source).info(format, args);
}

const Chain = struct {
    actions: []protocol.ActionText,
    next: usize = 0,
    identity: binding.Identity,
    flags: input.Binding.Flags,
    original: protocol.Input,
    event: input.KeyEvent,
    once: ?CoreSurface.GxOnceTable,
    performed: bool = false,
    ignored: bool = false,
    cancelled: bool = false,
    waiting: bool = false,
};

pub const State = struct {
    surface: *Surface,
    lease: protocol.Lease,
    serial: u64 = 0,
    config_generation: u64 = 1,
    chain: ?Chain = null,
    current_input: ?*const protocol.Input = null,
    applying: ?protocol.ActionRequest = null,
    pending_ui: ?struct { origin: protocol.ActionRequest, identity: binding.Identity } = null,
    callbacks: binding.CallbackQueue = .{},
    inspector_open: bool = false,
    inspector_owned: bool = false,
    quoting_updated_ms: u64 = 0,
    key_sequence: protocol.ActionText = .{},
    queue: [256]?*protocol.Input = @splat(null),
    head: usize = 0,
    len: usize = 0,
    draining: bool = false,
    paste: binding.PasteBuffer = .{},
    confirmation: ?struct { transaction: u64, reason: @FieldType(protocol.ConfirmRequest, "reason") } = null,
    clipboard: ?struct {
        transaction: u64,
        generation: u64,
        request: ?apprt.ClipboardRequest,
        reply: ?*protocol.ClipboardResult = null,
        command: ?*protocol.ClipboardRequest = null,
        origin: ?protocol.ActionRequest = null,
        selection: ?terminal.Selection = null,
    } = null,
    view: protocol.SurfaceState,
    test_applied: RemoteControls.Applied = .{},
    test_snapshot: ?protocol.TestState = null,

    fn transaction(self: *State) !u64 {
        self.serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
        return self.serial;
    }
    fn cancelChain(self: *State) void {
        if (self.chain) |chain| {
            self.surface.core_surface.gxCancelBinding(chain.event);
            self.surface.app.core_app.alloc.free(chain.actions);
        } else if (self.surface.core_surface.keyboard.sequence_set != null) {
            // A disconnected/reloaded prefix has no Chain yet, but its owned
            // encoded keys and one-shot identity must still be cancelled.
            self.surface.core_surface.gxCancelPendingSequence();
        }
        self.chain = null;
    }
    fn cancelClipboard(self: *State, cancelled: bool) void {
        const pending = self.clipboard orelse return;
        self.clipboard = null;
        if (pending.reply) |reply| self.surface.app.core_app.alloc.destroy(reply);
        if (pending.command) |command| self.surface.app.core_app.alloc.destroy(command);
        if (pending.request) |request| self.surface.core_surface.denyClipboardRequest(request);
        if (pending.origin) |origin| actionResult(self, origin, false, cancelled) catch {};
    }
    fn cancelUi(self: *State) void {
        const pending = self.pending_ui orelse return;
        self.pending_ui = null;
        clipboardActionResult(self, pending.origin, false) catch {};
    }
    fn cancelCallbacks(self: *State) void {
        for (&self.callbacks.slots) |*slot| if (slot.*) |pending| {
            slot.* = null;
            if (pending.origin) |origin| clipboardActionResult(self, origin, false) catch {};
            self.surface.app.core_app.alloc.destroy(pending);
        };
    }
    fn discard(self: *State) void {
        self.cancelChain();
        self.cancelUi();
        self.cancelCallbacks();
        const alloc = self.surface.app.core_app.alloc;
        while (self.len != 0) {
            alloc.destroy(self.queue[self.head].?);
            self.queue[self.head] = null;
            self.head = (self.head + 1) % self.queue.len;
            self.len -= 1;
        }
        self.paste.deinit(alloc);
        self.confirmation = null;
        self.cancelClipboard(false);
    }
};

pub fn install(surface: *Surface, lease: protocol.Lease) !void {
    if (surface.remote_source_state) |state| {
        if (std.meta.eql(state.lease, lease)) return;
        release(surface);
    }
    const state = try surface.app.core_app.alloc.create(State);
    state.* = .{ .surface = surface, .lease = lease, .view = .{ .surface = surface.ui_reference, .lease = lease } };
    resetPerfInput(surface);
    surface.remote_source_state = state;
    surface.core_surface.gx_binding_route = .{ .context = state, .callback = routeBinding, .config_changed = configChanged };
    state.view.title = clipped(protocol.Title, surface.getTitle() orelse "");
    state.view.confirm_quit = surface.core_surface.needsConfirmQuit();
    state.view.mouse_visible = !surface.core_surface.mouse.hidden;
    state.view.path_quoting = surface.pathQuoting();
    state.quoting_updated_ms = GetTickCount64();
    if (try surface.core_surface.pwd(surface.app.core_app.alloc)) |pwd| {
        defer surface.app.core_app.alloc.free(pwd);
        state.view.pwd = clipped(protocol.Text, pwd);
    }
    surface.app.remote.postToTarget(surface.ui_reference, .{ .surface_state = state.view }) catch {};
}

pub fn release(surface: *Surface) void {
    const state = surface.remote_source_state orelse return;
    resetPerfInput(surface);
    surface.remote_source_state = null;
    surface.core_surface.gx_binding_route = null;
    state.discard();
    if (state.inspector_owned) surface.core_surface.deactivateInspector();
    surface.app.core_app.alloc.destroy(state);
}

fn configChanged(context: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(context));
    state.cancelChain();
    state.cancelUi();
    state.cancelCallbacks();
    state.cancelClipboard(false);
    state.confirmation = null;
    state.paste.deinit(state.surface.app.core_app.alloc);
    state.config_generation +|= 1;
    state.quoting_updated_ms = 0;
    // Input remains owned and is drained against the replacement config by
    // the outer GUI boundary, never while updateConfig is in progress.
    state.surface.app.wakeup();
}

/// Called at an outer GUI boundary after configuration changes.
pub fn drain(app: *App) void {
    for (app.core_app.surfaces.items) |surface| {
        if (surface.remote_source_state) |state| {
            drainQueue(state) catch {};
            publishState(state) catch {};
            if (@import("remote_test.zig").enabled()) publishTestState(state) catch {};
        }
    }
}

fn publishState(state: *State) !void {
    const core = &state.surface.core_surface;
    const previous = state.view;
    state.view.config_generation = state.config_generation;
    const now = GetTickCount64();
    if (state.quoting_updated_ms == 0 or now -| state.quoting_updated_ms >= 2000) {
        state.view.path_quoting = state.surface.pathQuoting();
        state.quoting_updated_ms = now;
    }
    state.view.grid_columns = core.size.grid().columns;
    state.view.grid_rows = core.size.grid().rows;
    state.view.cell_width = core.size.cell.width;
    state.view.cell_height = core.size.cell.height;
    state.view.exited = core.child_exited;
    state.view.confirm_quit = core.needsConfirmQuit();
    state.view.selection = core.hasSelection();
    const ime = core.imePoint();
    state.view.cursor_x = ime.x;
    state.view.cursor_y = ime.y;
    state.view.cursor_width = ime.width;
    state.view.cursor_height = ime.height;
    if (!sameViewState(&previous, &state.view)) try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .surface_state = state.view });
}

fn publishTestState(state: *State) !void {
    const snapshot = readTestState(true, state) orelse return;
    if (state.test_snapshot) |previous| if (std.meta.eql(previous, snapshot)) return;
    try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .test_state = snapshot });
    state.test_snapshot = snapshot;
}

fn readTestState(enabled: bool, state: *State) ?protocol.TestState {
    if (!enabled) return null;
    if (!state.surface.core_surface_ready) return null;
    const core = &state.surface.core_surface;
    const scrollbar = block: {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        break :block core.io.terminal.screens.active.pages.scrollbar();
    };
    return .{
        .surface = state.surface.ui_reference,
        .lease = state.lease,
        .total = scrollbar.total,
        .viewport = scrollbar.len,
        .offset = scrollbar.offset,
        .applied = state.test_applied.count,
    };
}

test "remote fixture snapshot reads real terminal scrollback and disabled gate touches nothing" {
    try std.testing.expectEqual(@as(?protocol.TestState, null), readTestState(false, undefined));
    const alloc = std.testing.allocator;
    const surface = try alloc.create(Surface);
    defer alloc.destroy(surface);
    surface.* = undefined;
    surface.ui_reference = .{ .epoch = 1, .kind = .surface, .id = 5, .generation = 1 };
    surface.core_surface_ready = false;
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 };
    var state: State = .{ .surface = surface, .lease = lease, .view = .{ .surface = surface.ui_reference, .lease = lease } };
    try std.testing.expectEqual(@as(?protocol.TestState, null), readTestState(true, &state));
    surface.core_surface_ready = true;
    const core = &surface.core_surface;
    core.io.terminal = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
    defer core.io.terminal.deinit(alloc);
    var mutex: std.Io.Mutex = .init;
    core.renderer_state = .{ .mutex = &mutex, .terminal = &core.io.terminal };
    for (0..99) |_| try core.io.terminal.linefeed();
    state.test_applied.count = 9;
    const bottom = readTestState(true, &state).?;
    try std.testing.expectEqual(@as(u64, 100), bottom.total);
    try std.testing.expectEqual(@as(u64, 24), bottom.viewport);
    try std.testing.expectEqual(@as(u64, 76), bottom.offset);
    try std.testing.expectEqual(@as(u64, 9), bottom.applied);
    try std.testing.expectEqual(surface.ui_reference, bottom.surface);
    try std.testing.expectEqual(lease, bottom.lease);
    core.io.terminal.scrollViewport(.top);
    const top = readTestState(true, &state).?;
    try std.testing.expectEqual(bottom.total, top.total);
    try std.testing.expectEqual(@as(u64, 0), top.offset);
    try std.testing.expectEqual(bottom.applied, top.applied);
}

fn sameViewState(first: *const protocol.SurfaceState, second: *const protocol.SurfaceState) bool {
    inline for (@typeInfo(protocol.SurfaceState).@"struct".fields) |field| {
        if (comptime field.type == protocol.Title or field.type == protocol.Text) {
            // Bounded strings initialize only their live prefix. Their spare
            // capacity is not part of the state and must never be inspected.
            if (!std.mem.eql(u8, @field(first.*, field.name).slice(), @field(second.*, field.name).slice())) return false;
        } else if (!std.meta.eql(@field(first.*, field.name), @field(second.*, field.name))) return false;
    }
    return true;
}

pub fn messageSurface(body: *const protocol.Body) ?refs.Reference {
    return switch (body.*) {
        inline .ui_action_result,
        .ui_event_result,
        .inspector_request,
        .apply_action,
        .confirm_result,
        .text_snapshot,
        .keybind_snapshot,
        .close_request,
        .clipboard_result,
        => |value| value.surface,
        else => null,
    };
}

pub fn applyInput(app: *App, surface: *Surface, event: *const protocol.Input) !void {
    const state = surface.remote_source_state orelse return error.NotReady;
    if (!std.meta.eql(state.lease, event.lease)) return error.InvalidLease;
    if (event.event == .key) if (event.event.key.native) |native| if (native.virtual_key == w32.VK_RETURN) {
        trace("enter received surface={x} sequence={} action={s} lease={} config={} chain={} queued={} dispatch={}", .{ surface.ui_reference.id, event.sequence, @tagName(event.event.key.action), state.lease.generation, state.config_generation, state.chain != null, state.len, mayDispatchInput(state, event) });
    };
    if (!mayDispatchInput(state, event)) return enqueueInput(state, app.core_app.alloc, event);
    try drainQueue(state);
    // Draining an earlier key can start a new continuation. The newer input
    // must observe that new barrier rather than overtake its queued siblings.
    if (!mayDispatchInput(state, event)) return enqueueInput(state, app.core_app.alloc, event);
    try dispatchInput(state, event);
}

fn enqueueInput(state: *State, alloc: std.mem.Allocator, event: *const protocol.Input) !void {
    if (state.len == state.queue.len) {
        state.discard();
        return error.QueueFull;
    }
    const owned = try alloc.create(protocol.Input);
    owned.* = event.*;
    state.queue[(state.head + state.len) % state.queue.len] = owned;
    state.len += 1;
}

fn mayDispatchInput(state: *const State, event: *const protocol.Input) bool {
    // Late data from a cancelled/reloaded binding is dispatched only to the
    // rejection path below, never held until it could become a normal paste.
    if (stalePasteParent(state, event)) return true;
    if (state.confirmation != null or state.clipboard != null or state.pending_ui != null or state.callbacks.blocksInput()) return false;
    if (state.chain == null) return true;
    return if (waitingPasteIdentity(state)) |identity| binding.pasteBelongsToBinding(event, identity) else false;
}

fn waitingPasteIdentity(state: *const State) ?binding.Identity {
    const chain = if (state.chain) |*value| value else return null;
    if (!chain.waiting or chain.next == 0 or chain.next > chain.actions.len) return null;
    const action = binding.decode(&chain.actions[chain.next - 1]) catch return null;
    if (action != .paste_from_clipboard and action != .paste_from_selection) return null;
    return chain.identity;
}

fn stalePasteParent(state: *const State, event: *const protocol.Input) bool {
    if (event.event != .paste or event.event.paste.parent == null) return false;
    const identity = waitingPasteIdentity(state) orelse return true;
    return !binding.pasteBelongsToBinding(event, identity);
}

fn nextQueuedInput(state: *State) ?*protocol.Input {
    // A binding's own paste may have arrived while clipboard consent was
    // pending. It must remain reachable behind ordinary queued typing.
    for (0..state.len) |offset| {
        const index = (state.head + offset) % state.queue.len;
        const event = state.queue[index].?;
        if (!mayDispatchInput(state, event)) continue;
        for (offset..state.len - 1) |following| {
            state.queue[(state.head + following) % state.queue.len] = state.queue[(state.head + following + 1) % state.queue.len];
        }
        state.queue[(state.head + state.len - 1) % state.queue.len] = null;
        state.len -= 1;
        return event;
    }
    return null;
}

fn drainQueue(state: *State) !void {
    if (state.draining) return;
    state.draining = true;
    defer state.draining = false;
    const alloc = state.surface.app.core_app.alloc;
    while (nextQueuedInput(state)) |event| {
        defer alloc.destroy(event);
        try dispatchInput(state, event);
    }
}

fn dispatchInput(state: *State, event: *const protocol.Input) !void {
    const surface = state.surface;
    const core = &surface.core_surface;
    state.current_input = event;
    defer state.current_input = null;
    switch (event.event) {
        .key => |*key| {
            const native = if (key.native) |*value| value else null;
            if (native) |value| if (value.virtual_key == w32.VK_RETURN) {
                trace("enter dispatched surface={x} sequence={} action={s} lease={} config={} queued={}", .{ surface.ui_reference.id, event.sequence, @tagName(key.action), state.lease.generation, state.config_generation, state.len });
            };
            var native_text: [2]u16 = undefined;
            const raw_text: []const u16 = if (native) |value| if (value.text.len != 0) value.text.slice() else try nativeCodepoint(value.codepoint, &native_text) else &.{};
            const message: ?win_input.KeyMessage = if (native) |value| .{
                .vk = value.virtual_key,
                .lparam = @intCast(@as(u32, value.repeat_count) | (@as(u32, value.scan_code) << 16) | (@as(u32, @intFromBool(value.extended)) << 24)),
                .down = key.action != .release,
                .state = @bitCast(value.control_state),
                .text = raw_text,
                .dead = value.dead,
            } else null;
            _ = try core.gxWin32KeyCallback(.{
                .action = @enumFromInt(@intFromEnum(key.action)),
                .key = try protocol.physicalKey(input.Key, key.physical),
                .mods = @bitCast(key.modifiers),
                .consumed_mods = @bitCast(key.consumed_modifiers),
                .composing = key.composing,
                .utf8 = key.text.slice(),
                .unshifted_codepoint = @intCast(key.unshifted_codepoint),
            }, message);
        },
        .text => |*text| _ = try core.gxWin32KeyCallback(.{ .utf8 = text.slice() }, null),
        .composition => |*composition| try core.preeditCallback(if (composition.phase == .end) null else composition.text.slice()),
        .visible => |visible| try core.occlusionCallback(visible),
        .focus => |focused| {
            if (!focused) try core.preeditCallback(null);
            try core.focusCallback(focused);
        },
        .resize => |size| {
            surface.handleDpiChange(size.dpi);
            if (surface.hwnd) |hwnd| _ = w32.SetWindowPos(hwnd, null, 0, 0, @intCast(size.width), @intCast(size.height), w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
            surface.handleResize(size.width, size.height);
        },
        .mouse => |mouse| {
            const size = try surface.getSize();
            const mods: input.Mods = @bitCast(mouse.modifiers);
            surface.cursor_pos = .{ .x = mouse.x * @as(f32, @floatFromInt(size.width)), .y = mouse.y * @as(f32, @floatFromInt(size.height)) };
            try core.cursorPosCallback(surface.cursor_pos, mods);
            switch (mouse.action) {
                .motion => {},
                .scroll => try core.scrollCallback(mouse.scroll_x, mouse.scroll_y, .{}),
                .press, .release => _ = try core.mouseButtonCallback(if (mouse.action == .press) .press else .release, switch (mouse.button) {
                    .none => .unknown,
                    inline else => |button| @field(input.MouseButton, @tagName(button)),
                }, mods),
            }
        },
        .paste => |*chunk| {
            if (chunk.index == 0 or chunk.last) {
                trace("paste chunk surface={x} transfer={} parent={} parent_config={} index={} last={} lease={} config={} stale={} queued={}", .{ surface.ui_reference.id, chunk.transfer, if (chunk.parent) |parent| parent.transaction else 0, if (chunk.parent) |parent| parent.config_generation else 0, chunk.index, chunk.last, state.lease.generation, state.config_generation, stalePasteParent(state, event), state.len });
            }
            if (stalePasteParent(state, event)) {
                if (chunk.last) pasteResult(state, chunk.transfer, false) catch {};
                return;
            }
            const completed = state.paste.append(surface.app.core_app.alloc, chunk) catch |err| {
                try pasteResult(state, chunk.transfer, false);
                return err;
            };
            if (completed) {
                completePaste(state, false) catch |err| switch (err) {
                    error.UnsafePaste, error.UnauthorizedPaste => {
                        const transaction = try state.transaction();
                        state.confirmation = .{ .transaction = transaction, .reason = .paste };
                        try surface.app.remote.postToTarget(surface.ui_reference, .{ .confirm_request = .{ .surface = surface.ui_reference, .lease = state.lease, .transaction = transaction, .reason = .paste, .text = clipped(protocol.Text, state.paste.bytes.items) } });
                    },
                    else => {
                        state.paste.deinit(surface.app.core_app.alloc);
                        return err;
                    },
                };
            }
        },
    }
    // An asynchronous binding has only been queued, not applied. Its original
    // input is marked by advance after the continuation actually completes.
    markCompletedPerfInput(state, event);
}

fn markCompletedPerfInput(state: *State, event: *const protocol.Input) void {
    if (@import("remote_test.zig").enabled()) state.test_applied.note(true, state.chain == null, event);
    if (state.chain == null) markPerfInput(state.surface, event);
}

fn resetPerfInput(surface: *Surface) void {
    if (!perf.enabled()) return;
    if (surface.remote_output) |output| output.perf_input.store(.{});
}

/// GUI owns Output lifetime and is the sole stamp writer. Do not wait on the
/// readback lock: the render thread takes a coherent atomic snapshot at begin.
fn markPerfInput(surface: *Surface, event: *const protocol.Input) void {
    if (!perf.enabled() or event.perf.sequence == 0) return;
    if (surface.remote_output) |output| {
        if (event.perf.sequence > output.perf_input.load().sequence) output.perf_input.store(event.perf);
    }
}

test "remote applied performance stamp is monotonic independent of transport sequence and resets with lease" {
    const previous = perf.enabled();
    defer perf.setEnabled(previous);
    var event: protocol.Input = .{
        .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 },
        .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 },
        .sequence = 100,
        .event = .{ .text = try protocol.Text.init("x") },
        .perf = .{ .sequence = 7, .qpc = 12345 },
    };
    // Off must not even dereference the surface or touch its export lock.
    perf.setEnabled(false);
    markPerfInput(undefined, &event);
    resetPerfInput(undefined);
    const alloc = std.testing.allocator;
    const surface = try alloc.create(Surface);
    defer alloc.destroy(surface);
    var output: @import("RemoteHost.zig").Output = undefined;
    output.perf_input = .{};
    surface.* = undefined;
    surface.remote_mutex = .{};
    surface.remote_output = &output;
    perf.setEnabled(true);
    // Even while a renderer owns the readback lock, GUI stamp updates must
    // finish without taking it. This thread holds it to model that condition.
    std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&surface.remote_mutex);
    defer std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&surface.remote_mutex);
    markPerfInput(surface, &event);
    try std.testing.expectEqual(event.perf, output.perf_input.load());
    event.sequence = 200;
    event.perf = .{ .sequence = 6, .qpc = 12000 };
    markPerfInput(surface, &event);
    try std.testing.expectEqual(@as(u64, 7), output.perf_input.load().sequence);
    resetPerfInput(surface);
    try std.testing.expectEqual(@import("RemotePerf.zig").InputStamp{}, output.perf_input.load());
    surface.remote_output = null;
    markPerfInput(surface, &event);
}

fn completePaste(state: *State, confirmed: bool) !void {
    const transfer = state.paste.transfer;
    if (state.surface.core_surface.readonly or state.paste.bytes.items.len == 0) {
        state.paste.deinit(state.surface.app.core_app.alloc);
        try pasteResult(state, transfer, false);
        return;
    }
    try state.surface.core_surface.completeClipboardRequest(.{ .paste = .standard }, .{ .contents = &.{.{ .mime = "text/plain", .data = state.paste.bytes.items }}, .confirmed = confirmed });
    trace("paste applied surface={x} transfer={} parent={} lease={} config={} confirmed={}", .{ state.surface.ui_reference.id, transfer, if (state.paste.parent) |parent| parent.transaction else 0, state.lease.generation, state.config_generation, confirmed });
    state.paste.deinit(state.surface.app.core_app.alloc);
    try pasteResult(state, transfer, true);
}

fn pasteResult(state: *State, transaction: u64, performed: bool) !void {
    return pasteCompletion(state, transaction, performed, false);
}

fn pasteCompletion(state: *State, transaction: u64, performed: bool, cancelled: bool) !void {
    if (transaction == 0) return;
    state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .apply_action_result = .{ .surface = state.surface.ui_reference, .lease = state.lease, .transaction = transaction, .config_generation = state.config_generation, .performed = performed, .cancelled = cancelled } }) catch |err| {
        trace("paste result dispatch failed surface={x} transfer={} lease={} config={} performed={} err={}", .{ state.surface.ui_reference.id, transaction, state.lease.generation, state.config_generation, performed, err });
        return err;
    };
    trace("paste result dispatched surface={x} transfer={} lease={} config={} performed={} cancelled={}", .{ state.surface.ui_reference.id, transaction, state.lease.generation, state.config_generation, performed, cancelled });
}

fn routeBinding(context: *anyopaque, core: *CoreSurface, event: input.KeyEvent, leaf: input.Binding.Set.GenericLeaf, once: ?CoreSurface.GxOnceTable) !?CoreSurface.InputEffect {
    const state: *State = @ptrCast(@alignCast(context));
    const actions = leaf.actionsSlice();
    const remote = once != null or leaf.flags.all or leaf.flags.global or for (actions) |action| {
        if (binding.placement(action) == .target or action == .search_selection) break true;
    } else false;
    if (!remote) return null;
    if (state.chain != null) return .consumed;
    const original = state.current_input orelse return .consumed;
    if (actions.len > 256) return .consumed;
    const owned = try state.surface.app.core_app.alloc.alloc(protocol.ActionText, actions.len);
    var transferred = false;
    errdefer if (!transferred) state.surface.app.core_app.alloc.free(owned);
    for (actions, owned) |action, *value| value.* = try binding.encode(action);
    state.chain = .{
        .actions = owned,
        .identity = .{ .surface = state.surface.ui_reference, .lease = state.lease, .transaction = 1, .config_generation = state.config_generation },
        .flags = leaf.flags,
        .original = original.*,
        .event = event,
        .once = once,
    };
    transferred = true;
    core.gxBeginBinding();
    try advance(state);
    return .consumed;
}

fn selectionSearchAction(state: *State) !?protocol.ActionText {
    const alloc = state.surface.app.core_app.alloc;
    const selection = try state.surface.core_surface.selectionString(alloc) orelse return null;
    defer alloc.free(selection);
    if (selection.len == 0) return null;
    return binding.encode(.{ .search = selection }) catch null;
}

/// A target-wide search-selection fanout must read each source's own selection.
/// Its apply result is deferred until that pane's visible search UI opens.
fn requestSelectionSearch(state: *State, origin: protocol.ActionRequest) !bool {
    if (state.pending_ui != null) return false;
    const action = try selectionSearchAction(state) orelse return false;
    const transaction = try state.transaction();
    const identity: binding.Identity = .{ .surface = state.surface.ui_reference, .lease = state.lease, .transaction = transaction, .config_generation = state.config_generation };
    try state.surface.app.remote.postToTarget(identity.surface, .{ .ui_action = .{ .surface = identity.surface, .lease = identity.lease, .transaction = transaction, .config_generation = identity.config_generation, .action = action } });
    state.pending_ui = .{ .origin = origin, .identity = identity };
    return true;
}

fn advance(state: *State) !void {
    const chain = if (state.chain) |*value| value else return;
    while (chain.next < chain.actions.len) {
        const action = try binding.decode(&chain.actions[chain.next]);
        chain.next += 1;
        const selection_action: ?protocol.ActionText = if (action == .search_selection and !chain.flags.all and !chain.flags.global)
            (try selectionSearchAction(state)) orelse continue
        else
            null;
        if (selection_action != null or binding.placement(action) == .target or chain.flags.all or chain.flags.global) {
            chain.identity.transaction = try state.transaction();
            chain.waiting = true;
            trace("binding request surface={x} source_transaction={} lease={} config={} action={s} queued={}", .{ state.surface.ui_reference.id, chain.identity.transaction, state.lease.generation, chain.identity.config_generation, @tagName(action), state.len });
            state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .ui_action = .{
                .surface = state.surface.ui_reference,
                .lease = state.lease,
                .transaction = chain.identity.transaction,
                .config_generation = chain.identity.config_generation,
                .action = selection_action orelse chain.actions[chain.next - 1],
                .all = chain.flags.all,
                .global = chain.flags.global,
            } }) catch |err| {
                state.discard();
                return err;
            };
            return;
        }
        const performed = state.surface.core_surface.performBindingAction(action) catch false;
        chain.performed = chain.performed or performed;
        chain.ignored = chain.ignored or (performed and action == .ignore);
    }
    var finished = state.chain.?;
    state.chain = null;
    trace("binding complete surface={x} source_transaction={} lease={} config={} performed={} cancelled={} queued={}", .{ state.surface.ui_reference.id, finished.identity.transaction, state.lease.generation, finished.identity.config_generation, finished.performed, finished.cancelled, state.len });
    defer state.surface.app.core_app.alloc.free(finished.actions);
    finished.event.utf8 = switch (finished.original.event) {
        .key => |*key| key.text.slice(),
        .text => |*text| text.slice(),
        else => "",
    };
    const core = &state.surface.core_surface;
    if (try core.gxCompleteBinding(finished.event, finished.flags, finished.performed, finished.ignored, finished.cancelled, finished.once)) {
        core.gx_binding_bypass = true;
        defer core.gx_binding_bypass = false;
        try dispatchInput(state, &finished.original);
    }
    markCompletedPerfInput(state, &finished.original);
}

pub fn handle(app: *App, coordinator: *Coordinator, packet: *const protocol.Packet) !bool {
    const reference = messageSurface(&packet.body) orelse return false;
    const surface = app.resolveSurface(reference) orelse return error.StaleSource;
    const state = surface.remote_source_state orelse return error.NotReady;
    if (!coordinator.acceptsSourceAction(reference, state.lease)) return error.InvalidLease;
    switch (packet.body) {
        .ui_action_result => |result| {
            trace("binding receipt surface={x} source_transaction={} expected={} lease={} config={} performed={} cancelled={} closed={} matches={}", .{ reference.id, result.transaction, if (state.chain) |chain| chain.identity.transaction else 0, result.lease.generation, result.config_generation, result.performed, result.cancelled, result.closed, if (state.chain) |chain| chain.waiting and chain.identity.accepts(result) else false });
            if (state.pending_ui) |pending| if (pending.identity.accepts(result)) {
                state.pending_ui = null;
                if (result.performed) state.view.search_active = true;
                try actionResult(state, pending.origin, result.performed, result.cancelled);
                try drainQueue(state);
                return true;
            };
            const chain = if (state.chain) |*value| value else return true;
            // Native callbacks and a cancelled older chain can leave receipts
            // in flight. Neither may complete the current continuation.
            if (!chain.waiting or !chain.identity.accepts(result)) return true;
            chain.waiting = false;
            chain.performed = chain.performed or result.performed;
            chain.cancelled = chain.cancelled or result.cancelled;
            if (result.performed) {
                const action = try binding.decode(&chain.actions[chain.next - 1]);
                if (action == .ignore) chain.ignored = true;
                if (action == .start_search or action == .search_selection or action == .search) state.view.search_active = true;
            }
            if (result.closed) {
                state.discard();
                return true;
            }
            try advance(state);
            try drainQueue(state);
            trace("binding receipt drained surface={x} chain={} queued={}", .{ reference.id, state.chain != null, state.len });
        },
        .ui_event_result => |result| {
            const pending = state.callbacks.take(result) orelse return true;
            defer app.core_app.alloc.destroy(pending);
            const performed = result.performed and result.config_generation == state.config_generation;
            if (pending.kind == .start_search and performed) state.view.search_active = true;
            if (pending.origin) |origin| try actionResult(state, origin, performed, result.cancelled and result.config_generation == state.config_generation);
            try drainQueue(state);
        },
        .inspector_request => |request| try handleInspector(state, request),
        .clipboard_result => |*result| {
            const pending = state.clipboard orelse return true;
            if (!std.meta.eql(result.lease, state.lease) or result.transaction != pending.transaction or pending.generation != state.config_generation) return true;
            if (pending.reply != null) return true;
            try finishClipboard(state, result, false);
            try drainQueue(state);
        },
        .apply_action => |request| {
            if (!std.meta.eql(request.lease, state.lease)) return error.InvalidLease;
            const action = try binding.decode(&request.action);
            if (action == .search_selection) {
                if (request.config_generation == state.config_generation and try requestSelectionSearch(state, request)) return true;
                try clipboardActionResult(state, request, false);
                return true;
            }
            const copy = action == .copy_to_clipboard or action == .copy_url_to_clipboard;
            const write = switch (action) {
                .write_screen_file, .write_scrollback_file, .write_selection_file => true,
                else => false,
            };
            state.applying = request;
            defer state.applying = null;
            const allowed = binding.placement(action) == .source or copy or write or action == .end_search or action == .set_surface_title;
            const performed = if (request.config_generation == state.config_generation and allowed and (!write or hasWriteContent(&surface.core_surface, action))) surface.core_surface.performBindingAction(action) catch false else false;
            if (request.config_generation == state.config_generation and action == .search) state.view.search_active = true;
            if (state.callbacks.containsOrigin(request)) return true;
            if (copy or write) {
                if (state.clipboard) |pending| if (pending.origin) |origin| if (origin.transaction == request.transaction) return true;
                // Core copy helpers may swallow the platform write failure.
                if (copy) {
                    try clipboardActionResult(state, request, false);
                    return true;
                }
            }
            try coordinator.postToTarget(reference, .{ .apply_action_result = .{ .surface = reference, .lease = state.lease, .transaction = request.transaction, .config_generation = request.config_generation, .performed = performed } });
        },
        .close_request => |request| {
            if (!std.meta.eql(request.lease, state.lease)) return error.InvalidLease;
            if (!request.confirmed and surface.core_surface.needsConfirmQuit()) {
                const transaction = try state.transaction();
                state.confirmation = .{ .transaction = transaction, .reason = .close };
                try coordinator.postToTarget(reference, .{ .confirm_request = .{ .surface = reference, .lease = state.lease, .transaction = transaction, .reason = .close } });
            } else try close(state);
        },
        .confirm_result => |result| {
            const confirmation = state.confirmation orelse return true;
            if (!std.meta.eql(result.lease, state.lease) or result.transaction != confirmation.transaction) return error.InvalidResult;
            trace("confirmation receipt surface={x} transaction={} reason={s} confirmed={} lease={} config={}", .{ reference.id, result.transaction, @tagName(confirmation.reason), result.confirmed, state.lease.generation, state.config_generation });
            state.confirmation = null;
            switch (confirmation.reason) {
                .close => if (result.confirmed) {
                    try close(state);
                    return true;
                },
                .paste => {
                    if (state.clipboard) |pending| {
                        if (pending.reply) |reply| {
                            if (result.confirmed) try finishClipboard(state, reply, true) else state.cancelClipboard(true);
                        }
                    } else if (result.confirmed) try completePaste(state, true) else {
                        const transaction = state.paste.transfer;
                        state.paste.deinit(app.core_app.alloc);
                        try pasteCompletion(state, transaction, false, true);
                    }
                },
                .clipboard_read, .clipboard_write => {
                    const pending = state.clipboard orelse return true;
                    if (!result.confirmed or pending.generation != state.config_generation) {
                        state.cancelClipboard(!result.confirmed and pending.generation == state.config_generation);
                    } else if (pending.command) |command| {
                        command.prompt = false;
                        command.confirmed = true;
                        state.surface.app.remote.postToTarget(reference, .{ .clipboard_request = command.* }) catch |err| {
                            state.cancelClipboard(false);
                            return err;
                        };
                        state.clipboard.?.command = null;
                        app.core_app.alloc.destroy(command);
                    }
                },
            }
            try drainQueue(state);
        },
        .text_snapshot, .keybind_snapshot => |request| {
            if (!std.meta.eql(request.lease, state.lease)) return error.InvalidLease;
            var result: protocol.SnapshotResult = .{ .surface = reference, .lease = state.lease, .transaction = request.transaction };
            var writer: std.Io.Writer = .fixed(&result.text.items);
            if (packet.body == .text_snapshot) {
                const core = &surface.core_surface;
                core.renderer_state.mutex.lockUncancelable(global.io());
                defer core.renderer_state.mutex.unlock(global.io());
                const screen = core.io.terminal.screens.active;
                if (request.kind == .selection) {
                    if (screen.selection) |selection| {
                        var formatter: @import("../../terminal/formatter.zig").ScreenFormatter = .init(screen, .{ .emit = .plain, .unwrap = true, .trim = false });
                        formatter.content = .{ .selection = selection };
                        formatter.format(&writer) catch {
                            result.truncated = true;
                        };
                    }
                } else screen.dumpString(&writer, .{ .tl = screen.pages.getTopLeft(if (request.kind == .scrollback) .screen else .viewport) }) catch {
                    result.truncated = true;
                };
            } else {
                binding.writeKeybindSnapshot(&surface.core_surface.config.keybind, &writer) catch {
                    result.truncated = true;
                };
            }
            result.text.len = @intCast(utf8Prefix(writer.buffered()));
            if (result.truncated and packet.body == .keybind_snapshot) result.text.len = if (std.mem.lastIndexOfScalar(u8, result.text.slice(), '\n')) |last| @intCast(last + 1) else 0;
            try coordinator.postToTarget(reference, if (packet.body == .text_snapshot) .{ .text_snapshot_result = result } else .{ .keybind_snapshot_result = result });
        },
        else => return false,
    }
    return true;
}

fn close(state: *State) !void {
    const surface = state.surface;
    state.discard();
    try surface.app.remote.postToTarget(surface.ui_reference, .{ .leaf_closed = .{ .surface = surface.ui_reference } });
    surface.app.remote.sourceLeafClosed(surface.ui_reference);
    if (surface.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
}

pub fn requestClose(surface: *Surface, process_active: bool) !void {
    const state = surface.remote_source_state orelse return;
    if (process_active and surface.core_surface.needsConfirmQuit()) {
        const transaction = try state.transaction();
        state.confirmation = .{ .transaction = transaction, .reason = .close };
        try surface.app.remote.postToTarget(surface.ui_reference, .{ .confirm_request = .{ .surface = surface.ui_reference, .lease = state.lease, .transaction = transaction, .reason = .close } });
    } else try close(state);
}

/// Native adapter entry point. The original request transfers only after the
/// bounded packet was accepted by the transport; Kitty arenas stay source-owned.
pub fn clipboardRequest(surface: *Surface, location: apprt.Clipboard, request: apprt.ClipboardRequest) !apprt.ClipboardReadResult {
    const state = surface.remote_source_state orelse return .unsupported;
    if (location != .standard) return .unsupported;
    if (state.clipboard != null or state.confirmation != null) return .unavailable;
    var message: protocol.ClipboardRequest = .{
        .surface = surface.ui_reference,
        .lease = state.lease,
        .transaction = try state.transaction(),
        .kind = .read,
    };
    const config = &surface.core_surface.config;
    switch (request) {
        .paste => {},
        .list => message.kind = .list,
        .osc_52_read => message.prompt = config.clipboard_read == .ask,
        .kitty_read => |kitty| message.prompt = config.clipboard_read == .ask and !kitty.granted and kitty.mimes.len != 0,
        .kitty_write => |kitty| {
            message.kind = .write;
            message.prompt = config.clipboard_write == .ask and !kitty.granted;
            clipboardContents(&message, if (kitty.contents.len == 0) &.{.{ .mime = "text/plain", .data = "" }} else kitty.contents) catch return .unsupported;
        },
        .osc_52_write => return .unsupported,
    }
    try beginClipboard(state, &message, request);
    return .started;
}

/// OSC 52 and source-owned copy-on-select writes carry no upstream receipt,
/// but still wait for an actual target result before releasing their slot.
pub fn setClipboard(surface: *Surface, location: apprt.Clipboard, contents: []const apprt.ClipboardContent, confirm: bool) !void {
    const state = surface.remote_source_state orelse return error.NotReady;
    if (location != .standard) return error.UnsupportedClipboard;
    if (state.clipboard != null or state.confirmation != null) return error.ClipboardBusy;
    var message: protocol.ClipboardRequest = .{ .surface = surface.ui_reference, .lease = state.lease, .transaction = try state.transaction(), .kind = .write, .prompt = confirm };
    try clipboardContents(&message, contents);
    try beginClipboard(state, &message, null);
}

fn beginClipboard(state: *State, message: *const protocol.ClipboardRequest, request: ?apprt.ClipboardRequest) !void {
    const alloc = state.surface.app.core_app.alloc;
    const command: ?*protocol.ClipboardRequest = if (message.prompt) try alloc.create(protocol.ClipboardRequest) else null;
    errdefer if (command) |owned| alloc.destroy(owned);
    if (command) |owned| {
        owned.* = message.*;
        // Confirmation only grants permission. Recheck the source generation
        // before sending the effect, since target modal loops defer pipe work.
        const reason: @FieldType(protocol.ConfirmRequest, "reason") = if (message.kind == .write) .clipboard_write else .clipboard_read;
        try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .confirm_request = .{ .surface = message.surface, .lease = message.lease, .transaction = message.transaction, .reason = reason, .text = clipped(protocol.Text, if (message.has_text) message.plain() else message.html()) } });
        state.confirmation = .{ .transaction = message.transaction, .reason = reason };
    } else try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .clipboard_request = message.* });
    state.clipboard = .{ .transaction = message.transaction, .generation = state.config_generation, .request = request, .command = command, .origin = state.applying };
    if (state.applying) |origin| {
        if ((binding.decode(&origin.action) catch unreachable) == .copy_to_clipboard) {
            // Called by the core copy callback while its renderer lock is held.
            state.clipboard.?.selection = state.surface.core_surface.io.terminal.screens.active.selection;
        }
    }
}

fn clipboardActionResult(state: *State, origin: protocol.ActionRequest, performed: bool) !void {
    return actionResult(state, origin, performed, false);
}

fn actionResult(state: *State, origin: protocol.ActionRequest, performed: bool, cancelled: bool) !void {
    try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .apply_action_result = .{ .surface = origin.surface, .lease = origin.lease, .transaction = origin.transaction, .config_generation = origin.config_generation, .performed = performed, .cancelled = cancelled } });
}

fn clipboardContents(message: *protocol.ClipboardRequest, contents: []const apprt.ClipboardContent) !void {
    const clipboard = @import("../../terminal/clipboard.zig");
    var plain: ?[]const u8 = null;
    var html: ?[]const u8 = null;
    for (contents) |content| {
        if (plain == null and clipboard.isTextMime(content.mime)) plain = content.data;
        if (html == null and std.mem.eql(u8, content.mime, "text/html")) html = content.data;
    }
    if (plain == null and html == null) return error.UnsupportedContents;
    const plain_bytes = plain orelse "";
    const html_bytes = html orelse "";
    if (plain_bytes.len + html_bytes.len > protocol.SnapshotText.capacity) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(plain_bytes) or !std.unicode.utf8ValidateSlice(html_bytes) or std.mem.indexOfScalar(u8, plain_bytes, 0) != null or std.mem.indexOfScalar(u8, html_bytes, 0) != null) return error.InvalidText;
    message.has_text = plain != null;
    message.has_html = html != null;
    message.text_len = @intCast(plain_bytes.len);
    message.data.len = @intCast(plain_bytes.len + html_bytes.len);
    @memcpy(message.data.items[0..plain_bytes.len], plain_bytes);
    @memcpy(message.data.items[plain_bytes.len..message.data.len], html_bytes);
}

fn finishClipboard(state: *State, result: *const protocol.ClipboardResult, confirmed: bool) !void {
    const pending = state.clipboard orelse return;
    if (!result.performed) {
        state.cancelClipboard(false);
        return;
    }
    const request = pending.request orelse {
        state.clipboard = null;
        if (pending.origin) |origin| {
            if (pending.selection) |selection| state.surface.core_surface.gxCompleteClipboardCopy(selection) catch {};
            try clipboardActionResult(state, origin, true);
        }
        return;
    };
    const core = &state.surface.core_surface;
    if (request == .kitty_write) {
        state.clipboard = null;
        try core.gxCompleteClipboardWrite(request.kitty_write, true);
        return;
    }
    var contents: [2]@import("../../terminal/clipboard.zig").Content = undefined;
    var available: [2][]const u8 = undefined;
    var count: usize = 0;
    if (result.has_text) {
        contents[count] = .{ .mime = "text/plain", .data = result.plain() };
        available[count] = "text/plain";
        count += 1;
    }
    if (result.has_html) {
        contents[count] = .{ .mime = "text/html", .data = result.html() };
        available[count] = "text/html";
        count += 1;
    }
    // Only a paste requires the source's protected-paste check. Read access
    // has already been authorized by the target according to `prompt`.
    core.completeClipboardRequest(request, .{ .contents = contents[0..count], .available = available[0..count], .confirmed = confirmed or request != .paste }) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const reply = try state.surface.app.core_app.alloc.create(protocol.ClipboardResult);
            errdefer state.surface.app.core_app.alloc.destroy(reply);
            reply.* = result.*;
            const transaction = try state.transaction();
            try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .confirm_request = .{ .surface = state.surface.ui_reference, .lease = state.lease, .transaction = transaction, .reason = .paste, .text = clipped(protocol.Text, result.plain()) } });
            state.clipboard.?.reply = reply;
            state.confirmation = .{ .transaction = transaction, .reason = .paste };
            return;
        },
        else => {
            // Beyond authorization the core consumes Kitty request arenas,
            // including its error paths; never deny the freed request again.
            state.clipboard = null;
            if (pending.reply) |reply| state.surface.app.core_app.alloc.destroy(reply);
            return err;
        },
    };
    state.clipboard = null;
    if (pending.reply) |reply| state.surface.app.core_app.alloc.destroy(reply);
}

fn utf8Prefix(bytes: []const u8) usize {
    var len = bytes.len;
    while (len != 0 and !std.unicode.utf8ValidateSlice(bytes[0..len])) : (len -= 1) {}
    return len;
}

fn nativeCodepoint(value: u32, buffer: *[2]u16) ![]const u16 {
    if (value == 0) return &.{};
    if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.InvalidCodepoint;
    if (value <= 0xffff) {
        buffer[0] = @intCast(value);
        return buffer[0..1];
    }
    const scalar = value - 0x10000;
    buffer[0] = @intCast(0xd800 + (scalar >> 10));
    buffer[1] = @intCast(0xdc00 + (scalar & 0x3ff));
    return buffer;
}
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
fn clipped(comptime T: type, bytes: []const u8) T {
    return T.init(bytes[0..utf8Prefix(bytes[0..@min(bytes.len, T.capacity)])]) catch unreachable;
}

fn requestUiEvent(state: *State, event: @FieldType(protocol.UiEvent, "event")) !void {
    // Config reload can call back again before the outer GUI drain publishes
    // its snapshot. Keep the target generation ahead of the new UI effect.
    if (state.view.config_generation != state.config_generation) {
        state.view.config_generation = state.config_generation;
        try state.surface.app.remote.postToTarget(state.surface.ui_reference, .{ .surface_state = state.view });
    }
    const identity: binding.Identity = .{ .surface = state.surface.ui_reference, .lease = state.lease, .transaction = try state.transaction(), .config_generation = state.config_generation };
    const alloc = state.surface.app.core_app.alloc;
    // Informational runtime notifications follow an already-performed source
    // action. A failed toast must not undo that action's true performed value.
    const origin = switch (event) {
        .runtime, .present_terminal, .resize_window, .desktop_notification => null,
        else => state.applying,
    };
    try state.callbacks.reserve(alloc, .{ .identity = identity, .origin = origin, .kind = std.meta.activeTag(event) });
    errdefer if (state.callbacks.take(.{ .surface = identity.surface, .lease = identity.lease, .transaction = identity.transaction, .config_generation = identity.config_generation, .performed = false })) |pending| alloc.destroy(pending);
    try state.surface.app.remote.postToTarget(identity.surface, .{ .ui_event = .{ .surface = identity.surface, .lease = identity.lease, .transaction = identity.transaction, .config_generation = identity.config_generation, .event = event } });
}

/// The upstream file action returns void when its requested range is absent.
/// Inspect that precondition so an empty selection cannot consume `performable`.
fn hasWriteContent(core: *CoreSurface, action: input.Binding.Action) bool {
    const mode = switch (action) {
        inline .write_screen_file, .write_scrollback_file, .write_selection_file => |value| value,
        else => return false,
    };
    if (mode.action == .paste and core.readonly) return false;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    const screen = core.io.terminal.screens.active;
    return switch (action) {
        .write_screen_file => screen.pages.getBottomRight(.screen) != null,
        .write_scrollback_file => core.io.terminal.screens.active_key != .alternate and screen.pages.getBottomRight(.history) != null,
        .write_selection_file => screen.selection != null,
        else => false,
    };
}

fn handleInspector(state: *State, request: protocol.InspectorRequest) !void {
    if (!std.meta.eql(request.lease, state.lease)) return error.InvalidLease;
    const core = &state.surface.core_surface;
    const alloc = state.surface.app.core_app.alloc;
    const result = try alloc.create(protocol.InspectorResult);
    defer alloc.destroy(result);
    result.* = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation, .command = request.command, .performed = false };
    if (request.config_generation == state.config_generation) command: {
        switch (request.command) {
            .open => {
                if (core.inspector == null) {
                    core.activateInspector() catch break :command;
                    state.inspector_owned = true;
                }
                state.inspector_open = true;
            },
            .close => {
                if (state.inspector_owned) core.deactivateInspector();
                state.inspector_owned = false;
                state.inspector_open = false;
                result.performed = true;
                break :command;
            },
            else => if (!state.inspector_open or core.inspector == null) break :command,
        }
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const inspector = core.inspector orelse break :command;
        const stream = &inspector.gui.vt_stream;
        switch (request.command) {
            .clear => {
                var events = stream.events.iterator(.forward);
                while (events.next()) |event| event.deinit(alloc);
                stream.events.clear();
                stream.parser_stream.handler.current_seq = 1;
                stream.selected_event_seq = null;
                var keys = inspector.gui.key_stream.events.iterator(.forward);
                while (keys.next()) |key| key.deinit(alloc);
                inspector.gui.key_stream.events.clear();
            },
            .pause => stream.parser_stream.handler.paused = true,
            .@"resume" => stream.parser_stream.handler.paused = false,
            else => {},
        }
        result.performed = true;
        result.active = state.inspector_open;
        result.paused = stream.parser_stream.handler.paused;
        var writer: std.Io.Writer = .fixed(&result.text.items);
        writeInspector(core, request.command == .export_io, &writer) catch {
            result.truncated = true;
        };
        result.text.len = @intCast(utf8Prefix(writer.buffered()));
    }
    try state.surface.app.remote.postToTarget(request.surface, .{ .inspector_result = result.* });
}

/// Called under the renderer mutex. The target receives only formatted data;
/// neither ImGui objects nor terminal pointers escape their source process.
fn writeInspector(core: *CoreSurface, io_only: bool, writer: *std.Io.Writer) !void {
    const inspector = core.inspector orelse return;
    const t = &core.io.terminal;
    if (!io_only) {
        const screen = t.screens.active;
        try writer.print("grid: {d} x {d}\nscreen: {s}\ncursor: {d}, {d}\nreadonly: {}\nchild_exited: {}\nmouse_reporting: {}\nbracketed_paste: {}\n\nKeyboard\n", .{ core.size.grid().columns, core.size.grid().rows, @tagName(t.screens.active_key), screen.cursor.x, screen.cursor.y, core.readonly, core.child_exited, t.flags.mouse_event != .none, t.modes.get(.bracketed_paste) });
        var keys = inspector.gui.key_stream.events.iterator(.reverse);
        while (keys.next()) |key| {
            try writer.print("{s}\t{s}\t", .{ @tagName(key.event.action), @tagName(key.event.key) });
            try writeInspectorText(writer, key.event.utf8);
            try writer.writeAll("\tPTY=");
            for (key.pty) |byte| try writer.print("{x:0>2}", .{byte});
            try writer.writeByte('\n');
        }
        try writer.writeAll("\nTerminal IO\n");
    }
    try writer.writeAll("Seq\tKind\tDescription\n");
    var events = inspector.gui.vt_stream.events.iterator(.forward);
    while (events.next()) |event| {
        try writer.print("{d}\t{s}\t", .{ event.seq, @tagName(event.kind) });
        try writeInspectorText(writer, event.raw_description);
        try writer.writeByte('\n');
    }
}

fn writeInspectorText(writer: *std.Io.Writer, bytes: []const u8) !void {
    const valid = std.unicode.utf8ValidateSlice(bytes);
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f or (!valid and byte >= 0x80)) {
            try writer.print("\\x{x:0>2}", .{byte});
        } else try writer.writeByte(byte);
    }
}

fn currentKeyTable(core: *CoreSurface) protocol.Title {
    const stack = core.keyboard.table_stack.items;
    if (stack.len == 0) return .{};
    const active = stack[stack.len - 1].set;
    var tables = core.config.keybind.tables.iterator();
    while (tables.next()) |table| if (table.value_ptr == active) return clipped(protocol.Title, table.key_ptr.*);
    return .{};
}

fn keySequence(state: *State, value: apprt.action.KeySequence) ?protocol.ActionText {
    switch (value) {
        .end => {
            state.key_sequence = .{};
            return null;
        },
        .trigger => |trigger| {
            var buffer: [128]u8 = undefined;
            const formatted = @import("ui/trigger.zig").format(trigger, &buffer);
            var writer: std.Io.Writer = .fixed(state.key_sequence.items[state.key_sequence.len..]);
            if (state.key_sequence.len != 0) writer.writeAll(" \u{2192} ") catch {};
            writer.writeAll(formatted) catch {};
            state.key_sequence.len += @intCast(writer.buffered().len);
            state.key_sequence.len = @intCast(utf8Prefix(state.key_sequence.slice()));
            return state.key_sequence;
        },
    }
}

/// Intercept core callbacks for exported surfaces. Pure renderer bookkeeping
/// may remain local; visible UI is forwarded or explicitly unavailable.
pub fn routeAction(app: *App, target: apprt.Target, comptime action: apprt.Action.Key, value: apprt.Action.Value(action)) !?bool {
    const core = switch (target) {
        .app => return null,
        .surface => |surface| surface,
    };
    const surface = core.rt_surface;
    const state = surface.remote_source_state orelse return null;
    switch (action) {
        .render, .cell_size, .size_limit, .initial_size, .color_change, .config_change, .scrollbar => return null,
        .renderer_health => {
            if (value == .unhealthy) try requestUiEvent(state, .{ .desktop_notification = .{
                .title = clipped(protocol.Title, @import("../../gx/i18n.zig").tr("Renderer Unhealthy")),
                .body = clipped(protocol.Text, @import("../../gx/i18n.zig").tr("The GPU renderer is in an unhealthy state; terminal output may stop updating.")),
            } });
            return true;
        },
        .set_title => {
            state.view.title = clipped(protocol.Title, value.title);
            surface.setTitle(value.title);
        },
        .pwd => state.view.pwd = clipped(protocol.Text, value.pwd),
        .ring_bell => state.view.bell = true,
        .mouse_shape => state.view.cursor = @intCast(@intFromEnum(value)),
        .mouse_visibility => state.view.mouse_visible = value == .visible,
        .show_child_exited => {
            state.view.exited = true;
            try app.remote.postToTarget(surface.ui_reference, .{ .surface_state = state.view });
            // The core writes its exit/error explanation into the terminal
            // when no native notice was shown. Preserve that visible fallback.
            return false;
        },
        .start_search => {
            try requestUiEvent(state, .{ .start_search = try protocol.Text.init(value.needle) });
            return true;
        },
        .open_url => {
            try requestUiEvent(state, .{ .open_url = .{ .kind = @enumFromInt(@intFromEnum(value.kind)), .url = try protocol.SnapshotText.init(value.url) } });
            return true;
        },
        .desktop_notification => {
            try requestUiEvent(state, .{ .desktop_notification = .{ .title = clipped(protocol.Title, value.title), .body = clipped(protocol.Text, value.body) } });
            return true;
        },
        .export_terminal_io => {
            try requestUiEvent(state, .{ .export_terminal_io = try protocol.SnapshotText.init(value.contents) });
            return true;
        },
        .present_terminal => {
            try requestUiEvent(state, .present_terminal);
            return true;
        },
        .resize_window => {
            try requestUiEvent(state, .{ .resize_window = .{ .width = value.width, .height = value.height } });
            return true;
        },
        .readonly => {
            try requestUiEvent(state, .{ .runtime = .{ .readonly = value == .on } });
            return true;
        },
        .key_sequence => {
            try requestUiEvent(state, .{ .runtime = .{ .key_sequence = keySequence(state, value) } });
            return true;
        },
        .key_table => {
            try requestUiEvent(state, .{ .runtime = .{ .key_table = currentKeyTable(core) } });
            return true;
        },
        .progress_report => {
            try requestUiEvent(state, .{ .runtime = .{ .progress = .{ .state = @intCast(@intFromEnum(value.state)), .progress = if (value.progress) |percent| @min(percent, 100) else null } } });
            return true;
        },
        .command_finished => {
            try requestUiEvent(state, .{ .runtime = .{ .command_finished = .{ .exit_code = value.exit_code, .duration_ns = value.duration.duration } } });
            return true;
        },
        .mouse_over_link => {
            try requestUiEvent(state, .{ .runtime = .{ .mouse_over_link = clipped(protocol.Text, value.url) } });
            return true;
        },
        .render_inspector => return true,
        .end_search => state.view.search_active = false,
        .search_total => state.view.search_total = if (value.total) |total| @intCast(total) else null,
        .search_selected => state.view.search_selected = if (value.selected) |selected| @intCast(selected) else null,
        .selection_changed, .quit_timer => return true,
        else => {
            const mapped: input.Binding.Action = switch (action) {
                .quit => .quit,
                .new_window => .new_window,
                .new_tab => .new_tab,
                .close_window => .close_window,
                .close_all_windows => .close_all_windows,
                .toggle_maximize => .toggle_maximize,
                .toggle_fullscreen => .toggle_fullscreen,
                .toggle_tab_overview => .toggle_tab_overview,
                .toggle_window_decorations => .toggle_window_decorations,
                .toggle_quick_terminal => .toggle_quick_terminal,
                .toggle_visibility => .toggle_visibility,
                .toggle_background_opacity => .toggle_background_opacity,
                .toggle_command_palette => .toggle_command_palette,
                .toggle_split_zoom => .toggle_split_zoom,
                .equalize_splits => .equalize_splits,
                .reset_window_size => .reset_window_size,
                .move_tab_to_new_window => .move_tab_to_new_window,
                .copy_title_to_clipboard => .copy_title_to_clipboard,
                .prompt_title => switch (value) {
                    .surface => .prompt_surface_title,
                    .tab => .prompt_tab_title,
                    .window => .prompt_window_title,
                },
                .inspector => .{ .inspector = @enumFromInt(@intFromEnum(value)) },
                .set_tab_title => .{ .set_tab_title = value.title },
                .set_window_title => .{ .set_window_title = value.title },
                .new_split => .{ .new_split = @enumFromInt(@intFromEnum(value)) },
                .close_tab => .{ .close_tab = @enumFromInt(@intFromEnum(value)) },
                .goto_split => .{ .goto_split = @enumFromInt(@intFromEnum(value)) },
                .goto_window => .{ .goto_window = @enumFromInt(@intFromEnum(value)) },
                .move_tab => .{ .move_tab = value.amount },
                .open_config => .{ .open_config = @enumFromInt(@intFromEnum(value)) },
                .reload_config => .reload_config,
                else => return false,
            };
            try app.remote.postToTarget(surface.ui_reference, .{ .ui_action = .{ .surface = surface.ui_reference, .lease = state.lease, .transaction = try state.transaction(), .config_generation = state.config_generation, .action = try binding.encode(mapped) } });
            // This is a dispatch acknowledgement only. Binding continuations
            // use their separate ui_action_result and never count this value.
            return true;
        },
    }
    try app.remote.postToTarget(surface.ui_reference, .{ .surface_state = state.view });
    state.view.bell = false;
    return true;
}

test "apprt.win32 remote source owns bounded input queue instead of packet slabs" {
    try std.testing.expect(@sizeOf(State) < 20 * 1024);
    try std.testing.expectEqual(@as(usize, 4), utf8Prefix("hello"[0..4]));
    try std.testing.expectEqual(@as(usize, 0), utf8Prefix("\xe4\xb8"));
}

test "remote continuation must finish before marking its input performance stamp" {
    const previous = perf.enabled();
    defer perf.setEnabled(previous);
    perf.setEnabled(true);
    const alloc = std.testing.allocator;
    const surface = try alloc.create(Surface);
    defer alloc.destroy(surface);
    surface.* = undefined;
    var output: @import("RemoteHost.zig").Output = undefined;
    output.perf_input = .{};
    surface.remote_output = &output;
    const event: protocol.Input = .{
        .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 },
        .lease = .{ .holder_epoch = 2, .transaction = 7, .generation = 9 },
        .sequence = 100,
        .event = .{ .text = try protocol.Text.init("x") },
        .perf = .{ .sequence = 7, .qpc = 12345 },
    };
    var state: State = undefined;
    state.surface = surface;
    state.chain = .{ .actions = &.{}, .identity = undefined, .flags = .{}, .original = event, .event = .{}, .once = null, .waiting = true };
    markCompletedPerfInput(&state, &event);
    try std.testing.expectEqual(@import("RemotePerf.zig").InputStamp{}, output.perf_input.load());
    state.chain.?.waiting = false; // runnable is not yet completed
    markCompletedPerfInput(&state, &event);
    try std.testing.expectEqual(@import("RemotePerf.zig").InputStamp{}, output.perf_input.load());
    state.chain = null;
    markCompletedPerfInput(&state, &event);
    try std.testing.expectEqual(event.perf, output.perf_input.load());
}

test "apprt.win32 remote source native codepoints encode UTF16 scalar boundaries" {
    var buffer: [2]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{0x4e2d}, try nativeCodepoint(0x4e2d, &buffer));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde42 }, try nativeCodepoint(0x1f642, &buffer));
    try std.testing.expectEqualSlices(u16, &.{ 0xdbff, 0xdfff }, try nativeCodepoint(0x10ffff, &buffer));
    try std.testing.expectError(error.InvalidCodepoint, nativeCodepoint(0xd800, &buffer));
    try std.testing.expectError(error.InvalidCodepoint, nativeCodepoint(0x110000, &buffer));
}

test "apprt.win32 remote source state equality ignores unused bounded string storage" {
    var first: protocol.SurfaceState = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 }, .lease = .{ .holder_epoch = 2, .transaction = 1, .generation = 1 } };
    @memset(&first.title.items, 0x11);
    @memset(&first.pwd.items, 0x22);
    first.title.len = 4;
    first.pwd.len = 3;
    @memcpy(first.title.items[0..4], "term");
    @memcpy(first.pwd.items[0..3], "cwd");
    var second = first;
    @memset(second.title.items[second.title.len..], 0x33);
    @memset(second.pwd.items[second.pwd.len..], 0x44);
    try std.testing.expect(sameViewState(&first, &second));
    second.title.items[0] = 'T';
    try std.testing.expect(!sameViewState(&first, &second));
    second.title.items[0] = 't';
    second.grid_rows += 1;
    try std.testing.expect(!sameViewState(&first, &second));
    second.grid_rows = first.grid_rows;
    second.pwd.len -= 1;
    try std.testing.expect(!sameViewState(&first, &second));
}

test "apprt.win32 remote inspector snapshot escapes arbitrary terminal bytes" {
    var bytes: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeInspectorText(&writer, "hello\t\xe4\xb8\xad\x00");
    try std.testing.expectEqualStrings("hello\\x09\xe4\xb8\xad\\x00", writer.buffered());
    writer.end = 0;
    try writeInspectorText(&writer, "\xff\x1b[A");
    try std.testing.expectEqualStrings("\\xff\\x1b[A", writer.buffered());
}

test "apprt.win32 remote source reload cancels owned callbacks and close discards queued input" {
    const alloc = std.testing.allocator;
    var core_app: @import("../../App.zig") = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    app.core_app = &core_app;
    app.remote = .{ .closing = true };
    app.msg_hwnd = null;
    app.wakeup_pending = .init(false);
    var surface: Surface = undefined;
    surface.app = &app;
    surface.core_surface.keyboard = .{};
    surface.ui_reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 2, .generation = 3 };
    var state: State = .{ .surface = &surface, .lease = lease, .view = .{ .surface = surface.ui_reference, .lease = lease } };
    defer state.discard();
    const identity: binding.Identity = .{ .surface = surface.ui_reference, .lease = lease, .transaction = 4, .config_generation = 1 };
    try state.callbacks.reserve(alloc, .{ .identity = identity, .kind = .open_url, .origin = .{ .surface = surface.ui_reference, .lease = lease, .transaction = 5, .config_generation = 1, .action = try protocol.ActionText.init("write_screen_file:open") } });
    const queued = try alloc.create(protocol.Input);
    queued.* = .{ .surface = surface.ui_reference, .lease = lease, .sequence = 6, .event = .{ .text = try protocol.Text.init("kept") } };
    state.queue[0] = queued;
    state.len = 1;
    _ = try state.paste.append(alloc, &.{ .transfer = 7, .index = 0, .last = false, .text = try protocol.Text.init("never written") });
    state.confirmation = .{ .transaction = 8, .reason = .paste };
    configChanged(&state);
    try std.testing.expectEqual(@as(u64, 2), state.config_generation);
    try std.testing.expect(!state.callbacks.blocksInput());
    try std.testing.expect(state.callbacks.take(.{ .surface = identity.surface, .lease = identity.lease, .transaction = identity.transaction, .config_generation = identity.config_generation, .performed = true }) == null);
    try std.testing.expect(state.confirmation == null);
    try std.testing.expectEqual(@as(usize, 0), state.paste.bytes.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.len);
    try std.testing.expectEqualStrings("kept", state.queue[0].?.event.text.slice());
    state.discard();
    try std.testing.expectEqual(@as(usize, 0), state.len);
    try std.testing.expect(state.queue[0] == null);
}

test "apprt.win32 remote once prefix survives failed performable completion and cancellation" {
    const alloc = std.testing.allocator;
    var core_app: @import("../../App.zig") = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    app.core_app = &core_app;
    app.remote = .{ .closing = true };
    app.msg_hwnd = null;
    app.wakeup_pending = .init(false);
    var surface: Surface = undefined;
    surface.app = &app;
    surface.ui_reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 2, .generation = 3 };
    var state: State = .{ .surface = &surface, .lease = lease, .view = .{ .surface = surface.ui_reference, .lease = lease } };
    surface.remote_source_state = &state;
    const core = &surface.core_surface;
    core.alloc = alloc;
    core.rt_app = &app;
    core.rt_surface = &surface;
    core.keyboard = .{};
    core.config.keybind = .{};
    core.readonly = true; // Flushed prefix bytes are freed without needing a PTY.
    core.gx_binding_route = .{ .context = &state, .callback = routeBinding, .config_changed = configChanged };
    core.gx_sequence_once = null;
    defer core.keyboard.table_stack.deinit(alloc);
    defer core.keyboard.sequence_queued.deinit(alloc);
    defer state.discard();
    var table: input.Binding.Set = .{};
    var prefix: input.Binding.Set = .{};
    try core.keyboard.table_stack.append(alloc, .{ .set = &table, .once = true, .gx_generation = 10 });
    const once: CoreSurface.GxOnceTable = .{ .set = &table, .generation = 10 };
    const key: input.KeyEvent = .{ .unshifted_codepoint = 'c' };
    // This is the identity handoff used by a leader and its resolved leaf.
    core.keyboard.sequence_set = &prefix;
    core.gxRememberSequenceOnce(once);
    try std.testing.expectEqual(@as(usize, 1), core.keyboard.table_stack.items.len);
    const carried = core.gxSequenceOnce();
    try std.testing.expect(carried.?.set == &table);
    try core.keyboard.sequence_queued.append(alloc, .{ .alloc = .{ .alloc = alloc, .data = try alloc.dupe(u8, "prefix") } });
    core.gxBeginBinding();
    try std.testing.expect(core.gxSequenceOnce() == null);
    // A false result requests the original key exactly once; it does not pop.
    try std.testing.expect(try core.gxCompleteBinding(key, .{ .performable = true }, false, false, false, carried));
    try std.testing.expectEqual(@as(usize, 1), core.keyboard.table_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), core.keyboard.sequence_queued.items.len);
    try std.testing.expect(core.keyboard.last_trigger == null);
    // Reload and disconnect can cancel before a leaf creates its Chain.
    core.keyboard.sequence_set = &prefix;
    core.gxRememberSequenceOnce(once);
    configChanged(&state);
    try std.testing.expect(core.gxSequenceOnce() == null);
    try std.testing.expect(core.keyboard.sequence_set == null);
    try std.testing.expectEqual(@as(usize, 1), core.keyboard.table_stack.items.len);
    core.keyboard.sequence_set = &prefix;
    core.gxRememberSequenceOnce(once);
    state.discard();
    try std.testing.expect(core.gxSequenceOnce() == null);
    try std.testing.expectEqual(@as(usize, 1), core.keyboard.table_stack.items.len);
    // A subsequent actual success removes exactly that activation.
    try std.testing.expect(!try core.gxCompleteBinding(key, .{}, true, false, false, once));
    try std.testing.expectEqual(@as(usize, 0), core.keyboard.table_stack.items.len);
    try std.testing.expectEqual(@as(?u64, key.bindingHash()), core.keyboard.last_trigger);
    // With no remote route the added sequence bookkeeping is inert.
    core.gx_binding_route = null;
    core.gxRememberSequenceOnce(once);
    try std.testing.expect(core.gxSequenceOnce() == null);
}

test "apprt.win32 remote cancellation consumes performable paste without claiming success or popping once" {
    const alloc = std.testing.allocator;
    var core_app: @import("../../App.zig") = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    app.core_app = &core_app;
    app.remote = .{ .closing = true };
    app.msg_hwnd = null;
    app.wakeup_pending = .init(false);
    var surface: Surface = undefined;
    surface.app = &app;
    surface.ui_reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 2, .generation = 3 };
    var state: State = .{ .surface = &surface, .lease = lease, .view = .{ .surface = surface.ui_reference, .lease = lease } };
    surface.remote_source_state = &state;
    const core = &surface.core_surface;
    core.alloc = alloc;
    core.rt_app = &app;
    core.rt_surface = &surface;
    core.keyboard = .{};
    core.config.keybind = .{};
    core.readonly = true;
    core.gx_binding_route = .{ .context = &state, .callback = routeBinding, .config_changed = configChanged };
    core.gx_sequence_once = null;
    defer core.keyboard.table_stack.deinit(alloc);
    defer core.keyboard.sequence_queued.deinit(alloc);
    defer state.discard();
    var table: input.Binding.Set = .{};
    try core.keyboard.table_stack.append(alloc, .{ .set = &table, .once = true, .gx_generation = 10 });
    const once: CoreSurface.GxOnceTable = .{ .set = &table, .generation = 10 };
    const key: input.KeyEvent = .{ .unshifted_codepoint = 'v', .mods = .{ .ctrl = true, .shift = true } };
    // A genuine miss still asks the caller to replay its original native key.
    try std.testing.expect(try core.gxCompleteBinding(key, .{ .performable = true }, false, false, false, once));
    try std.testing.expect(core.keyboard.last_trigger == null);
    for ([_]input.Binding.Flags{
        .{ .performable = true },
        .{ .consumed = false, .performable = true },
        .{ .all = true, .performable = true },
        .{ .global = true, .performable = true },
    }) |flags| {
        try core.keyboard.sequence_queued.append(alloc, .{ .alloc = .{ .alloc = alloc, .data = try alloc.dupe(u8, "owned-prefix") } });
        core.keyboard.sequence_set = &table;
        core.gxRememberSequenceOnce(once);
        // User cancellation keeps performed=false. It must suppress replay
        // nevertheless, drop prefix bytes, and suppress the matching release.
        try std.testing.expect(!try core.gxCompleteBinding(key, flags, false, false, true, once));
        try std.testing.expectEqual(@as(usize, 1), core.keyboard.table_stack.items.len);
        try std.testing.expectEqual(@as(usize, 0), core.keyboard.sequence_queued.items.len);
        try std.testing.expect(core.gxSequenceOnce() == null);
        try std.testing.expectEqual(@as(?u64, key.bindingHash()), core.keyboard.last_trigger);
    }
}

test "apprt.win32 remote paste only bypasses queued typing for its exact suspended parent" {
    const alloc = std.testing.allocator;
    const reference: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 2, .generation = 3 };
    var state: State = .{ .surface = undefined, .lease = lease, .view = .{ .surface = reference, .lease = lease } };
    defer for (state.queue) |slot| if (slot) |value| alloc.destroy(value);
    var actions = [_]protocol.ActionText{try binding.encode(.paste_from_clipboard)};
    const text: protocol.Input = .{ .surface = reference, .lease = lease, .sequence = 1, .event = .{ .text = try protocol.Text.init("X") } };
    var direct: protocol.Input = .{ .surface = reference, .lease = lease, .sequence = 2, .event = .{ .paste = .{ .transfer = 12, .index = 0, .last = true, .text = try protocol.Text.init("Y") } } };
    var owned = direct;
    owned.sequence = 3;
    owned.event.paste.transfer = 13;
    owned.event.paste.parent = .{ .transaction = 4, .config_generation = 1 };
    state.chain = .{ .actions = &actions, .next = 1, .identity = .{ .surface = reference, .lease = lease, .transaction = 4, .config_generation = 1 }, .flags = .{}, .original = text, .event = .{}, .once = null, .waiting = true };
    try enqueueInput(&state, alloc, &text);
    try enqueueInput(&state, alloc, &direct);
    try std.testing.expect(!mayDispatchInput(&state, &direct));
    // A consent barrier can queue the binding's own data behind ordinary keys.
    state.confirmation = .{ .transaction = 5, .reason = .clipboard_read };
    try enqueueInput(&state, alloc, &owned);
    try std.testing.expect(nextQueuedInput(&state) == null);
    state.confirmation = null;
    const required = nextQueuedInput(&state).?;
    defer alloc.destroy(required);
    try std.testing.expectEqual(@as(u64, 13), required.event.paste.transfer);
    try std.testing.expect(nextQueuedInput(&state) == null);
    // Completing the chain resumes the original FIFO: X before menu-pasted Y.
    state.chain = null;
    const first = nextQueuedInput(&state).?;
    defer alloc.destroy(first);
    try std.testing.expectEqualStrings("X", first.event.text.slice());
    const second = nextQueuedInput(&state).?;
    defer alloc.destroy(second);
    try std.testing.expectEqualStrings("Y", second.event.paste.text.slice());
    try std.testing.expect(nextQueuedInput(&state) == null);
    // Cancelled/old-parent chunks take the rejection path even when now idle.
    try std.testing.expect(stalePasteParent(&state, &owned));
    direct.event.paste.parent = owned.event.paste.parent;
    state.chain = .{ .actions = &actions, .next = 1, .identity = .{ .surface = reference, .lease = lease, .transaction = 4, .config_generation = 2 }, .flags = .{}, .original = text, .event = .{}, .once = null, .waiting = true };
    try std.testing.expect(stalePasteParent(&state, &direct));
}
