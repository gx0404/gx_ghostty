//! GUI-owned remote leaf in a normal Window. The source retains the terminal,
//! renderer and PTY; this child owns only pixels, native input and UI metadata.
//! Its bell border (`bell-features = border`) follows the local terminal's
//! `gx.bell_border.State`: it rings while the pane is unfocused, clears on
//! focus or input, and paints over the frame in the caution color.
const Self = @This();
const std = @import("std");
const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const d2d = @import("ui/d2d.zig");
const style = @import("ui/style.zig");
const wstr = @import("ui/wstr.zig");
const i18n = @import("../../gx/i18n.zig");
const refs = @import("../../gx/ui_ref.zig");
const protocol = @import("../../gx/remote_protocol.zig");
const Input = @import("RemoteInput.zig");
const RemotePerf = @import("RemotePerf.zig");
const View = @import("RemoteSurfaceView.zig");
const Channel = @import("ipc/RemoteChannel.zig").Channel;
const Snapshot = @import("PaneSnapshot.zig");
const Action = @import("../../input.zig").Binding.Action;
const RemotePaneUi = @import("RemotePaneUi.zig");
const bell_border = @import("../../gx/bell_border.zig");
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyRemotePane");
pub const Callbacks = struct {
    ctx: *anyopaque,
    input: *const fn (*anyopaque, refs.Reference, protocol.Input) bool,
    close_requested: *const fn (*anyopaque, refs.Reference) bool,
};

app: *App,
parent_window: *Window,
ui_reference: refs.Reference,
ui_attachment: refs.Attachment = .{},
source_reference: refs.Reference,
transfer_reference: refs.Reference,
ticket: protocol.Ticket,
callbacks: Callbacks,
ref_count: u32 = 1,
hwnd: ?w32.HWND = null,
canvas: d2d.Canvas,
view: ?View = null,
scale: f32 = 1,
width: u32 = 1,
height: u32 = 1,
visible: bool = false,
focused: bool = false,
unavailable: bool = false,
closed: bool = false,
destroying: bool = false,
close_pending: bool = false,
input_suspended: bool = true,
input_busy: bool = false,
ime_composing: bool = false,
gate: Input.Gate,
decoder: Input.Utf16 = .{},
keys: @import("key_translate.zig").State = .{},
metadata: Snapshot = .{},
ui: RemotePaneUi = .{},
drop_target: ?*@import("ole_drop.zig").Target = null,
drop_target_pending: bool = false,
owned_title: []const u8 = "",
owned_cwd: []const u8 = "",
current_cursor: ?w32.HCURSOR = null,
mouse_visible: bool = true,
bell_border_state: bell_border.State = .{},
/// Survives mapping replacement; a fresh pane/lease starts at zero.
perf_last_input: u64 = 0,

extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "user32" fn GetClassNameW(w32.HWND, [*]u16, i32) callconv(.winapi) i32;
pub fn isWindow(hwnd: w32.HWND) bool {
    var name: [64]u16 = undefined;
    const len = GetClassNameW(hwnd, &name, name.len);
    return len > 0 and std.mem.eql(u16, name[0..@intCast(len)], class_name);
}
pub fn registerClass(instance: w32.HINSTANCE) !void {
    const definition: w32.WNDCLASSEXW = .{ .cbSize = @sizeOf(w32.WNDCLASSEXW), .style = w32.CS_HREDRAW | w32.CS_VREDRAW, .lpfnWndProc = &wndProc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = instance, .hIcon = null, .hCursor = w32.LoadCursorW(null, w32.IDC_IBEAM), .hbrBackground = null, .lpszMenuName = null, .lpszClassName = class_name, .hIconSm = null };
    if (w32.RegisterClassExW(&definition) == 0 and GetLastError() != 1410) return error.WindowClassFailed;
}
pub fn unregisterClass(instance: w32.HINSTANCE) void {
    _ = w32.UnregisterClassW(class_name, instance);
}
pub fn create(app: *App, parent: *Window, source: refs.Reference, transfer: refs.Reference, ticket: protocol.Ticket, callbacks: Callbacks) !*Self {
    if (ticket.target_epoch != app.ui_ids.epoch or source.epoch != ticket.source_epoch) return error.WrongHost;
    const factory = app.uiFactory() orelse return error.Direct2DUnavailable;
    const self = try app.core_app.alloc.create(Self);
    errdefer app.core_app.alloc.destroy(self);
    const serial = try app.ui_ids.create(.tab);
    self.* = .{ .app = app, .parent_window = parent, .source_reference = source, .transfer_reference = transfer, .ui_reference = try app.ui_ids.surface(serial.id), .ticket = ticket, .callbacks = callbacks, .canvas = d2d.Canvas.init(factory), .scale = parent.scale, .gate = .{ .ticket = ticket } };
    errdefer self.canvas.deinit();
    try registerClass(app.hinstance);
    self.hwnd = w32.CreateWindowExW(0, class_name, std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_CHILD | w32.WS_CLIPSIBLINGS, 0, 0, 1, 1, parent.hwnd orelse return error.InvalidOwner, null, app.hinstance, null) orelse return error.WindowCreateFailed;
    _ = w32.SetWindowLongPtrW(self.hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    return self;
}
pub fn ref(self: *Self, _: std.mem.Allocator) std.mem.Allocator.Error!*Self {
    std.debug.assert(self.ref_count < std.math.maxInt(u32));
    self.ref_count += 1;
    return self;
}
pub fn unref(self: *Self, alloc: std.mem.Allocator) void {
    std.debug.assert(self.ref_count > 0);
    self.ref_count -= 1;
    // The coordinator can retain a closed leaf after its visible tree owner
    // disappears. Its transient UI must not outlive that visible ownership.
    if (self.ref_count == 1 and !self.destroying) {
        self.ui.runtime.hide();
        if (self.unavailable) self.closed = true;
    }
    if (self.ref_count == 1 and !self.destroying and !self.closed and !self.unavailable and !self.close_pending) {
        // Dropping one visible owner must never return or close its siblings.
        // The coordinator retains this leaf until the source confirms closure.
        self.close_pending = self.ui.requestCloseFromOwner(self, true);
        self.input_suspended = true;
    }
    if (self.ref_count != 0) return;
    self.destroying = true;
    self.bell_border_state.stop();
    self.revokeDropTarget();
    self.app.shell.revoke(self.ui_reference);
    if (self.owned_title.len != 0) alloc.free(self.owned_title);
    if (self.owned_cwd.len != 0) alloc.free(self.owned_cwd);
    self.gate.disconnect();
    self.ui_attachment = .{};
    self.ui.deinit(alloc);
    if (self.view) |*view| view.deinit() catch unreachable;
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        if (!self.app.deferDropWindowDestroy(hwnd)) _ = w32.DestroyWindow(hwnd);
    }
    self.canvas.deinit();
    alloc.destroy(self);
}
pub fn ready(self: *const Self) bool {
    return !self.destroying and !self.unavailable and !self.closed and self.view != null;
}
pub fn allFrames(self: *const Self) bool {
    return self.ready() and self.view.?.has_frame and self.view.?.state == .live;
}
pub fn acceptMapping(self: *Self, channel: *Channel) !void {
    if (self.destroying or self.unavailable or self.closed or channel.source or channel.closing or channel.local_epoch != self.ticket.target_epoch or channel.peer.epoch != self.ticket.source_epoch) return error.InvalidChannel;
    if (self.view) |*old| if (channel.mapped.generation <= old.channel.mapped.generation) return error.StaleMapping;
    var next = try View.init(self.app.core_app.alloc, &self.app.ui_ids, self.ui_reference.id, self.parent_window.ui_reference, channel);
    errdefer self.app.core_app.alloc.free(next.last_frame);
    if (!self.visible) try next.setVisible(&self.app.ui_ids, self.parent_window.ui_reference, false);
    if (self.view) |*old| try old.deinit();
    self.view = next;
    self.frameReady();
}
pub fn frameReady(self: *Self) void {
    if (self.destroying or self.unavailable or self.closed) return;
    const view = if (self.view) |*value| value else return;
    const acquired = view.channel.acquire() catch {
        self.disconnect();
        return;
    };
    if (acquired) |value| {
        var reading = value;
        defer reading.release();
        if (reading.lease.generation != view.channel.mapped.generation or reading.lease.pixels.len != view.last_frame.len) {
            self.disconnect();
            return;
        }
        view.receivePerf(reading.lease.perf_input, self.visible);
        @memcpy(view.last_frame, reading.lease.pixels);
        view.has_frame = true;
        view.last_sequence = reading.lease.sequence;
        view.state = .live;
    }
    self.invalidate();
}
pub fn enableLease(self: *Self, lease: protocol.Lease) !void {
    if (!self.allFrames() or self.close_pending) return error.NotReady;
    try self.gate.enable(lease);
}
pub fn activateInput(self: *Self) void {
    if (self.gate.lease == null or self.unavailable or self.destroying) return;
    self.input_suspended = false;
    self.queueDropTarget();
    self.emitGeometry();
    self.emit(.{ .focus = self.focused });
}
pub fn cancelClose(self: *Self) void {
    if (!self.unavailable) self.close_pending = false;
}
pub fn disconnect(self: *Self) void {
    if (self.destroying) return;
    self.unavailable = true;
    self.bell_border_state.stop();
    self.ui.runtime.hide();
    self.revokeDropTarget();
    self.app.shell.revoke(self.ui_reference);
    self.input_suspended = true;
    self.gate.disconnect();
    self.ui.disconnect(self.app);
    self.ui.search_bar.bindRemote(self);
    self.ui.search_bar.setOwnerVisible(false);
    self.ui.inspector_popup.hide();
    self.decoder.reset();
    if (self.view) |*view| view.disconnect();
    self.invalidate();
}
pub fn setVisible(self: *Self, visible: bool) void {
    if (!visible and self.visible) {
        self.emit(.{ .focus = false });
        self.emit(.{ .visible = false });
    }
    self.visible = visible and !self.destroying;
    self.hidePerfIfHidden();
    self.ui.search_bar.bindRemote(self);
    self.ui.search_bar.setOwnerVisible(self.visible);
    self.ui_attachment.setVisible(&self.app.ui_ids, self.ui_reference, self.parent_window.ui_reference, self.visible) catch {
        self.ui_attachment = .{};
    };
    if (self.view) |*view| view.setVisible(&self.app.ui_ids, self.parent_window.ui_reference, self.visible) catch {};
    if (self.parent_window.closing) self.bell_border_state.stop();
    if (!visible) {
        if (self.parent_window.is_quick_terminal) self.bell_border_state.clear();
        self.ui.runtime.hide();
        self.ui.accessibility.hide();
        self.decoder.reset();
        self.keys.reset();
        self.ui.inspector_popup.hide();
    }
    self.queueDropTarget();
    if (self.hwnd) |hwnd| _ = w32.ShowWindow(hwnd, if (visible) w32.SW_SHOW else w32.SW_HIDE);
    if (visible) {
        self.emit(.{ .visible = true });
        self.emitGeometry();
    }
}
pub fn handleDpiChange(self: *Self, dpi: u32) void {
    self.scale = @as(f32, @floatFromInt(dpi)) / 96;
    self.canvas.discardTarget();
    self.ui.search_bar.bindRemote(self);
    self.ui.search_bar.onDpiChanged();
    self.emitGeometry();
    self.invalidate();
}
pub fn prepareReparent(self: *Self, window: *Window) !refs.Attachment {
    if (window.app != self.app or window.closing) return error.InvalidOwner;
    return self.app.ui_ids.attach(self.ui_reference, window.ui_reference);
}
pub fn onReparented(self: *Self, window: *Window, attached: refs.Attachment) void {
    self.ui.runtime.onReparented();
    self.revokeDropTarget();
    self.ui.inspector_popup.destroy();
    self.ui.accessibility.hide();
    self.parent_window = window;
    self.ui_attachment = attached;
    self.ui.search_bar.bindRemote(self);
    self.ui.search_bar.onReparented();
    if (self.view) |*view| view.setVisible(&self.app.ui_ids, window.ui_reference, self.visible) catch {};
    self.handleDpiChange(@intFromFloat(@round(window.scale * 96)));
    self.queueDropTarget();
}
pub fn getTitle(self: *const Self) ?[]const u8 {
    return if (self.owned_title.len != 0) self.owned_title else i18n.tr("Remote terminal");
}
pub fn needsConfirmQuit(self: *const Self) bool {
    return self.ready() and self.metadata.needs_confirm;
}
pub fn snapshot(self: *const Self) Snapshot {
    var value = self.metadata;
    value.reference = self.ui_reference;
    value.attachment = self.ui_attachment;
    value.initialized = true;
    value.ready = self.ready();
    value.title = Snapshot.Title.init(self.getTitle() orelse "") catch .{};
    if (value.grid) |*grid| grid.pane = self.ui_reference;
    return value;
}
pub fn workingDirectory(self: *Self, alloc: std.mem.Allocator) !?[]const u8 {
    return if (self.ready() and self.owned_cwd.len != 0) try alloc.dupe(u8, self.owned_cwd) else null;
}

fn revokeDropTarget(self: *Self) void {
    if (self.drop_target) |target| {
        self.drop_target = null;
        self.app.retireDropTarget(target);
    }
}

pub fn queueDropTarget(self: *Self) void {
    if (!self.ready() or !self.ui_attachment.isValid() or self.input_suspended) return;
    if (self.drop_target) |target| {
        if (!target.attachment.matches(self.ui_attachment)) _ = target.updateAttachment(self.ui_attachment);
        return;
    }
    if (self.drop_target_pending or self.hwnd == null) return;
    self.drop_target_pending = true;
    self.app.queueDropTargets();
}

pub fn installDropTarget(self: *Self) void {
    self.drop_target_pending = false;
    if (!self.ready() or self.input_suspended or !self.ui_attachment.isValid() or self.drop_target != null) return;
    const app = self.app;
    const reference = self.ui_reference;
    const attachment = self.ui_attachment;
    const hwnd = self.hwnd orelse return;
    app.beginDropRegistration(hwnd);
    defer app.endDropRegistration();
    const target = @import("ole_drop.zig").Target.create(app.core_app.alloc, &app.com_apartment, hwnd, attachment, app.dropCallbacks()) catch return;
    const live = app.resolveRemote(reference) orelse {
        _ = target.destroy();
        return;
    };
    if (!live.ready() or !live.ui_attachment.matches(attachment) or live.drop_target != null) {
        _ = target.destroy();
        return;
    }
    live.drop_target = target;
}
pub fn cursorAnchor(self: *Self) ?Snapshot.CursorAnchor {
    return self.metadata.cursor;
}

/// The terminal's bell as `bell-features` asks, on this target: the
/// source's BEL (`SurfaceState.bell`) and a finished command both ring it
/// here (`RemoteRuntimeUi.ringBell`). True when anything happened.
pub fn ringBell(self: *Self) bool {
    return @import("RemoteRuntimeUi.zig").ringBell(self);
}

/// Ring the bell border, like `Surface.ringBellBorder`: only an unfocused,
/// ready pane with `bell-features = border` rings, and a closing window
/// stops it. It stays until focus or input (`clearBellBorder`).
pub fn ringBellBorder(self: *Self) void {
    if (!self.ready() or !self.bell_border_state.accepting) return;
    if (self.parent_window.closing) {
        self.bell_border_state.stop();
        self.invalidate();
        return;
    }
    if (self.parent_window.is_quick_terminal and self.parent_window.feedbackDisposition() != .ready) return;
    self.bell_border_state.configure(self.app.config.@"bell-features".border);
    self.bell_border_state.ring(self.focused);
    self.invalidate();
}

/// Input reached the pane: its bell border clears.
pub fn clearBellBorder(self: *Self) void {
    if (!self.bell_border_state.ringing) return;
    self.bell_border_state.clear();
    self.invalidate();
}

/// Input from the target user that counts against the bell border, the same
/// input the source would accept (`emit`).
fn acceptsInput(self: *const Self) bool {
    return self.visible and !self.input_suspended and !self.unavailable and !self.closed and !self.destroying;
}

/// What the bell border shows now: current configuration (disabling it
/// drops a ring for good), the caution color and one device pixel per
/// scale step, only over a live frame of a visible pane.
fn bellBorder(self: *Self, caution: d2d.Color) bell_border.Snapshot {
    self.bell_border_state.configure(self.app.config.@"bell-features".border);
    if (self.parent_window.closing) self.bell_border_state.stop();
    return self.bell_border_state.snapshot(self.visible and self.ready(), caution.toRgb8(), self.scale);
}

/// A rectangle in device pixels.
pub const PixelRect = struct { x: u32, y: u32, w: u32, h: u32 };

/// The top, bottom, left and right strips that `gx.bell_border.covers`
/// paints on a `width` x `height` pane at `requested` pixels.
pub fn bellBorderEdges(width: u32, height: u32, requested: u7) [4]PixelRect {
    const t = bell_border.thickness(width, height, requested);
    if (t == 0) return @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    const side = height -| 2 * t;
    return .{
        .{ .x = 0, .y = 0, .w = width, .h = t },
        .{ .x = 0, .y = height - t, .w = width, .h = t },
        .{ .x = 0, .y = t, .w = t, .h = side },
        .{ .x = width - t, .y = t, .w = t, .h = side },
    };
}

fn drawBellBorder(self: *Self, caution: d2d.Color) void {
    const border = self.bellBorder(caution);
    if (!border.active) return;
    const color = d2d.Color.rgb(border.r, border.g, border.b);
    for (bellBorderEdges(self.width, self.height, border.width)) |edge| {
        if (edge.w == 0 or edge.h == 0) continue;
        self.canvas.fillRect(.{
            .x = @as(f32, @floatFromInt(edge.x)) / self.scale,
            .y = @as(f32, @floatFromInt(edge.y)) / self.scale,
            .w = @as(f32, @floatFromInt(edge.w)) / self.scale,
            .h = @as(f32, @floatFromInt(edge.h)) / self.scale,
        }, color);
    }
}

pub fn setMouseState(self: *Self, cursor: u16, visible: bool) void {
    const shape = std.enums.fromInt(@import("../../terminal/main.zig").MouseShape, cursor) orelse .text;
    self.current_cursor = w32.LoadCursorW(null, @import("Surface.zig").cursorIdFor(shape));
    self.mouse_visible = visible;
    var point: w32.POINT = undefined;
    if (self.hwnd) |hwnd| if (w32.GetCapture() == hwnd or (w32.GetCursorPos_(&point) != 0 and w32.WindowFromPoint(point) == hwnd)) {
        _ = w32.SetCursor(if (visible) self.current_cursor else null);
    };
}
pub fn performBindingAction(self: *Self, action: Action) !bool {
    return self.ui.performBindingAction(self, action);
}
pub fn dismissSearch(self: *Self) void {
    self.ui.dismissSearch(self);
}
pub fn onLanguageChanged(self: *Self) void {
    self.ui.search_bar.bindRemote(self);
    self.ui.search_bar.onLanguageChanged();
    self.invalidate();
}
pub fn refreshRenderer(self: *Self) void {
    self.invalidate();
}
pub fn setUnfocusedDim(self: *Self, _: @import("Surface.zig").DimColor) void {
    self.invalidate();
}
pub fn invalidate(self: *Self) void {
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}
pub fn emit(self: *Self, event: Input.Event) void {
    self.emitTimed(event, if (protocol.Input.measurable(event)) RemotePerf.now() else 0);
}

/// GUI-only, pure state transition shared by hide and its regression tests.
fn hidePerfIfHidden(self: *Self) void {
    if (self.visible) return;
    self.perf_last_input = @max(self.perf_last_input, self.gate.sequence);
    if (self.view) |*view| view.perf_frame = .{};
}

fn emitTimed(self: *Self, event: Input.Event, qpc: u64) void {
    if (self.destroying or self.unavailable or self.closed or self.close_pending or !self.visible or self.input_suspended) return;
    var value = self.gate.next(self.source_reference, event) catch return;
    if (qpc != 0 and protocol.Input.measurable(event)) value.perf = .{ .sequence = value.sequence, .qpc = qpc };
    const accepted = self.callbacks.input(self.callbacks.ctx, self.transfer_reference, value);
    if (self.input_busy == accepted) {
        self.input_busy = !accepted;
        self.invalidate();
    }
}
fn emitGeometry(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return;
    self.width = @intCast(@max(1, rect.right));
    self.height = @intCast(@max(1, rect.bottom));
    self.emit(.{ .resize = .{ .width = self.width, .height = self.height, .dpi = @intFromFloat(@round(self.scale * 96)) } });
}
fn modifiers() u16 {
    const Mods = @import("../../input.zig").Mods;
    const value: Mods = .{ .shift = w32.GetKeyState(w32.VK_SHIFT) < 0, .ctrl = w32.GetKeyState(w32.VK_CONTROL) < 0, .alt = w32.GetKeyState(w32.VK_MENU) < 0, .super = w32.GetKeyState(w32.VK_LWIN) < 0 or w32.GetKeyState(w32.VK_RWIN) < 0 };
    return @bitCast(value);
}
fn mouse(self: *Self, message: u32, wparam: usize, lparam: isize) void {
    const bits: usize = @bitCast(lparam);
    var point: w32.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
    const scroll = message == w32.WM_MOUSEWHEEL or message == w32.WM_MOUSEHWHEEL;
    if (scroll) if (self.hwnd) |hwnd| {
        _ = w32.ScreenToClient(hwnd, &point);
    };
    const Mouse = @FieldType(Input.Event, "mouse");
    var value: Mouse = .{ .action = .motion, .button = .none, .x = std.math.clamp(@as(f32, @floatFromInt(point.x)) / @as(f32, @floatFromInt(@max(1, self.width))), 0, 1), .y = std.math.clamp(@as(f32, @floatFromInt(point.y)) / @as(f32, @floatFromInt(@max(1, self.height))), 0, 1), .scroll_x = 0, .scroll_y = 0, .modifiers = modifiers() };
    if (scroll) {
        value.action = .scroll;
        const delta = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(wparam >> 16)))))) / 120;
        if (message == w32.WM_MOUSEHWHEEL) value.scroll_x = delta else value.scroll_y = delta;
    } else switch (message) {
        w32.WM_LBUTTONDOWN, w32.WM_LBUTTONUP => {
            value.button = .left;
            value.action = if (message == w32.WM_LBUTTONDOWN) .press else .release;
        },
        w32.WM_RBUTTONDOWN, w32.WM_RBUTTONUP => {
            value.button = .right;
            value.action = if (message == w32.WM_RBUTTONDOWN) .press else .release;
        },
        w32.WM_MBUTTONDOWN, w32.WM_MBUTTONUP => {
            value.button = .middle;
            value.action = if (message == w32.WM_MBUTTONDOWN) .press else .release;
        },
        w32.WM_XBUTTONDOWN, w32.WM_XBUTTONUP => {
            value.button = if (wparam >> 16 & 0xffff == 1) .four else .five;
            value.action = if (message == w32.WM_XBUTTONDOWN) .press else .release;
        },
        else => {},
    }
    if (value.action == .press) if (self.hwnd) |hwnd| {
        _ = w32.SetFocus(hwnd);
        _ = w32.SetCapture(hwnd);
    };
    if (value.action == .press and self.acceptsInput()) self.clearBellBorder();
    if (value.action == .release) _ = w32.ReleaseCapture();
    self.emit(.{ .mouse = value });
}
fn imeText(self: *Self, himc: w32.HIMC, kind: u32) !protocol.Text {
    const bytes = w32.ImmGetCompositionStringW(himc, kind, null, 0);
    if (bytes < 0 or bytes & 1 != 0 or bytes > 8192) return error.InvalidComposition;
    const alloc = self.app.core_app.alloc;
    const units = try alloc.alloc(u16, @intCast(@divTrunc(bytes, 2)));
    defer alloc.free(units);
    const got = w32.ImmGetCompositionStringW(himc, kind, units.ptr, @intCast(bytes));
    if (got != bytes) return error.InvalidComposition;
    const text = try wstr.utf8Alloc(alloc, units);
    defer alloc.free(text);
    return protocol.Text.init(text);
}
fn positionIme(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    const anchor = self.cursorAnchor() orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    const x: i32 = @intFromFloat(@max(0, anchor.x * self.scale));
    const y: i32 = @intFromFloat(@max(0, anchor.y * self.scale));
    const height: i32 = @intFromFloat(@max(1, anchor.height * self.scale));
    _ = w32.ImmSetCompositionWindow(himc, &.{ .dwStyle = w32.CFS_POINT, .ptCurrentPos = .{ .x = x, .y = y }, .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 } });
    _ = w32.ImmSetCandidateWindow(himc, &.{ .dwIndex = 0, .dwStyle = w32.CFS_EXCLUDE, .ptCurrentPos = .{ .x = x, .y = y + height }, .rcArea = .{ .left = x, .top = y, .right = x + @as(i32, @intCast(@max(1, anchor.cell_width))), .bottom = y + height } });
}
fn key(self: *Self, wparam: usize, lparam: isize, pressed: bool) void {
    if (self.input_suspended or !self.visible or self.unavailable) return;
    const qpc = if (pressed) RemotePerf.now() else 0;
    if (pressed) self.clearBellBorder();
    const decoded = self.keys.decode(wparam, lparam, if (pressed) .press else .release) orelse return;
    if (decoded.preedit_changed) self.emit(.{ .composition = .{ .phase = .update, .text = protocol.Text.init(decoded.preedit orelse "") catch .{} } });
    if (decoded.ime_release) return;
    var unicode: u32 = 0;
    if (decoded.message.text.len != 0) {
        var iterator = std.unicode.Utf16LeIterator.init(decoded.message.text);
        unicode = iterator.nextCodepoint() catch 0 orelse 0;
    }
    self.emitTimed(.{ .key = .{
        .action = switch (decoded.event.action) {
            .press => .press,
            .repeat => .repeat,
            .release => .release,
        },
        .physical = @intCast(@intFromEnum(decoded.event.key)),
        .unicode = unicode,
        .modifiers = @intCast(decoded.event.mods.int()),
        .consumed_modifiers = @intCast(decoded.event.consumed_mods.int()),
        .composing = self.ime_composing or decoded.event.composing,
        .unshifted_codepoint = decoded.event.unshifted_codepoint,
        .text = protocol.Text.init(decoded.event.utf8) catch .{},
        .native = .{ .virtual_key = decoded.message.vk, .scan_code = @as(u8, @truncate(@as(usize, @bitCast(lparam)) >> 16)), .extended = lparam & (1 << 24) != 0, .control_state = decoded.message.state.int(), .codepoint = unicode, .text = protocol.Bounded(u16, 4).init(decoded.message.text) catch .{}, .repeat_count = @max(1, @as(u16, @truncate(@as(usize, @bitCast(lparam))))), .dead = decoded.message.dead },
    } }, qpc);
}
fn paint(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    var painting: w32.PAINTSTRUCT = undefined;
    _ = w32.BeginPaint(hwnd, &painting) orelse return;
    defer _ = w32.EndPaint(hwnd, &painting);
    if (!self.canvas.beginHwnd(hwnd, @intFromFloat(@round(self.scale * 96)))) return;
    const colors = style.Tokens.fromConfig(&self.app.config);
    self.canvas.clear(colors.background);
    const rect: d2d.Rect = .{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(self.width)) / self.scale, .h = @as(f32, @floatFromInt(self.height)) / self.scale };
    const result: View.DrawResult = if (self.view) |*view| view.draw(&self.canvas, rect) else .waiting;
    if (result == .drawn and !self.closed) self.drawBellBorder(colors.caution);
    if (result != .drawn or self.closed) {
        const message = if (self.closed) i18n.tr("The remote terminal was closed.") else if (self.unavailable or result == .unavailable) i18n.tr("The remote terminal is unavailable.") else if (result == .backend_unavailable) i18n.tr("Remote terminal rendering is unavailable.") else i18n.tr("Waiting for remote terminal...");
        self.canvas.drawText(message, rect.inset(24, 24), .{ .color = colors.foreground, .align_x = .center, .wrap = true });
        if (self.unavailable or self.closed) self.canvas.drawText(i18n.tr("Close"), .{ .x = @max(0, rect.w / 2 - 60), .y = @max(0, rect.h / 2 + 24), .w = 120, .h = 32 }, .{ .color = colors.accent, .align_x = .center });
    }
    if (self.input_busy) self.canvas.drawText(i18n.tr("Remote input is temporarily busy."), .{ .x = 8, .y = @max(0, rect.h - 32), .w = @max(0, rect.w - 16), .h = 32 }, .{ .color = colors.foreground });
    const completed = self.canvas.finish();
    if (completed == .recreate) self.invalidate();
    self.recordPaint(completed == .ok, result);
}

fn recordPaint(self: *Self, completed: bool, result: View.DrawResult) void {
    if (completed and result == .drawn and !self.closed and self.visible) {
        if (self.view) |*view| view.perf_frame.presented(&self.perf_last_input);
    }
}
pub fn wndProc(hwnd: w32.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const address = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self: *Self = if (address != 0) @ptrFromInt(@as(usize, @bitCast(address))) else return w32.DefWindowProcW(hwnd, message, wparam, lparam);
    const fixture = @import("remote_test.zig");
    if (message == fixture.query_message and fixture.enabled()) return self.query(wparam);
    switch (message) {
        w32.WM_SETCURSOR => {
            if (@as(u16, @truncate(@as(usize, @bitCast(lparam)))) != w32.HTCLIENT) return w32.DefWindowProcW(hwnd, message, wparam, lparam);
            _ = w32.SetCursor(if (self.mouse_visible) self.current_cursor orelse w32.LoadCursorW(null, w32.IDC_IBEAM) else null);
            return 1;
        },
        w32.WM_PAINT => {
            self.paint();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SIZE => {
            self.emitGeometry();
            self.invalidate();
            return 0;
        },
        w32.WM_SETFOCUS => {
            if (self.parent_window.leafForPane(self.ui_reference)) |leaf| _ = self.parent_window.setActiveSurface(leaf);
            self.bell_border_state.setFocused(true);
            self.focused = true;
            self.emit(.{ .focus = true });
            self.invalidate();
            return 0;
        },
        w32.WM_KILLFOCUS => {
            if (self.ime_composing) {
                if (w32.ImmGetContext(hwnd)) |himc| {
                    _ = w32.ImmNotifyIME(himc, w32.NI_COMPOSITIONSTR, w32.CPS_CANCEL, 0);
                    _ = w32.ImmReleaseContext(hwnd, himc);
                }
                self.emit(.{ .composition = .{ .phase = .end } });
            }
            self.ime_composing = false;
            self.emit(.{ .focus = false });
            self.bell_border_state.setFocused(false);
            self.focused = false;
            self.decoder.reset();
            self.keys.reset();
            self.invalidate();
            return 0;
        },
        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            self.key(wparam, lparam, true);
            return 0;
        },
        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            self.key(wparam, lparam, false);
            return 0;
        },
        w32.WM_IME_STARTCOMPOSITION => {
            if (self.acceptsInput()) self.clearBellBorder();
            self.ime_composing = true;
            self.decoder.reset();
            self.emit(.{ .composition = .{ .phase = .start } });
            self.positionIme();
            return 0;
        },
        w32.WM_IME_ENDCOMPOSITION => {
            self.ime_composing = false;
            self.emit(.{ .composition = .{ .phase = .end } });
            return 0;
        },
        w32.WM_IME_COMPOSITION => {
            const himc = w32.ImmGetContext(hwnd) orelse return 0;
            defer _ = w32.ImmReleaseContext(hwnd, himc);
            const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
            if (flags & (w32.GCS_RESULTSTR | w32.GCS_COMPSTR) != 0 and self.acceptsInput()) self.clearBellBorder();
            if (flags & w32.GCS_RESULTSTR != 0) {
                self.emit(.{ .composition = .{ .phase = .end } });
                if (self.imeText(himc, w32.GCS_RESULTSTR)) |text| self.emit(.{ .text = text }) else |_| {}
            }
            if (flags & w32.GCS_COMPSTR != 0) {
                if (self.imeText(himc, w32.GCS_COMPSTR)) |text| self.emit(.{ .composition = .{ .phase = .update, .text = text } }) else |_| {}
            }
            self.positionIme();
            return 0;
        },
        w32.WM_IME_SETCONTEXT => return w32.DefWindowProcW(hwnd, message, wparam, lparam & ~@as(isize, w32.ISC_SHOWUICOMPOSITIONWINDOW)),
        w32.WM_GETOBJECT => return @import("ui/uia_remote.zig").onGetObject(self.app, self, wparam, lparam),
        w32.WM_CHAR => {
            if ((wparam >= 0x20 or wparam == '\t' or wparam == '\r' or wparam == '\n') and self.acceptsInput()) self.clearBellBorder();
            if (self.keys.key_event_produced_text or self.ime_composing) return 0;
            if (wparam <= 0xffff) if (self.decoder.feed(@intCast(wparam)) catch null) |text| self.emit(.{ .text = text });
            return 0;
        },
        0x0109 => {
            if (wparam == 0xffff) return 1;
            if (self.acceptsInput()) self.clearBellBorder();
            self.decoder.reset();
            if (wparam <= 0x10ffff) if (Input.Utf16.scalar(@intCast(wparam)) catch null) |text| self.emit(.{ .text = text });
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            if (self.unavailable or self.closed) {
                _ = self.callbacks.close_requested(self.callbacks.ctx, self.transfer_reference);
            } else self.mouse(message, wparam, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP, w32.WM_RBUTTONDOWN, w32.WM_RBUTTONUP, w32.WM_MBUTTONDOWN, w32.WM_MBUTTONUP, w32.WM_XBUTTONDOWN, w32.WM_XBUTTONUP, w32.WM_MOUSEMOVE, w32.WM_MOUSEWHEEL, w32.WM_MOUSEHWHEEL => {
            self.mouse(message, wparam, lparam);
            return 0;
        },
        w32.WM_CLOSE => {
            if (!self.close_pending and !self.destroying) self.close_pending = self.callbacks.close_requested(self.callbacks.ctx, self.transfer_reference);
            return 0;
        },
        0x0082 => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            self.hwnd = null;
            return w32.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}
pub fn query(self: *const Self, field: usize) isize {
    const fixture = @import("remote_test.zig");
    return switch (field) {
        0 => fixture.magic,
        1 => @intCast(fixture.Flags.remote | (if (self.ready()) fixture.Flags.ready else @as(usize, 0)) | (if (self.allFrames()) fixture.Flags.frames else @as(usize, 0)) | (if (self.gate.lease != null and !self.input_suspended) fixture.Flags.lease else @as(usize, 0)) | (if (self.visible) fixture.Flags.visible else @as(usize, 0)) | (if (self.unavailable) fixture.Flags.unavailable else @as(usize, 0))),
        2 => @bitCast(@as(usize, @intCast(self.source_reference.id))),
        4 => if (self.view) |view| @bitCast(@as(usize, @intCast(view.last_sequence))) else 0,
        5 => if (self.view) |view| @bitCast(@as(usize, @intCast(view.channel.mapped.generation))) else 0,
        6 => @bitCast(@as(usize, @intCast(self.ticket.transaction))),
        7 => @bitCast(@as(usize, @intCast(self.ticket.generation))),
        8 => @bitCast(@as(usize, @intCast(self.ui_reference.id))),
        9 => @intFromEnum(if (self.closed) View.State.closed else if (self.unavailable) View.State.unavailable else if (self.allFrames()) View.State.live else View.State.waiting),
        10 => self.ui.queryResult(),
        else => 0,
    };
}

test "remote bell border edges cover exactly the shared border pixels" {
    for ([_]u7{ 1, 2, 3, 127 }) |requested| {
        for ([_][2]u32{ .{ 0, 0 }, .{ 1, 1 }, .{ 1, 9 }, .{ 9, 1 }, .{ 2, 3 }, .{ 5, 7 }, .{ 80, 24 } }) |size| {
            const edges = bellBorderEdges(size[0], size[1], requested);
            for (0..size[1]) |y| {
                for (0..size[0]) |x| {
                    var hits: u32 = 0;
                    for (edges) |edge| {
                        if (x >= edge.x and x < edge.x + edge.w and y >= edge.y and y < edge.y + edge.h) hits += 1;
                    }
                    const expected = bell_border.covers(size[0], size[1], requested, @intCast(x), @intCast(y));
                    // Strips may overlap only when the pane is thinner than both edges.
                    try std.testing.expectEqual(expected, hits > 0);
                    if (size[0] > 2 and size[1] > 2) try std.testing.expect(hits <= 1);
                }
            }
        }
    }
}

fn perfTestPane() Self {
    return .{
        .app = undefined,
        .parent_window = undefined,
        .canvas = undefined,
        .ui_reference = .{},
        .transfer_reference = .{},
        .source_reference = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 1 },
        .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 9 },
        .gate = .{ .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 7, .generation = 9 } },
        .callbacks = undefined,
    };
}

fn perfTestView() View {
    return .{ .allocator = std.testing.allocator, .reference = .{}, .attachment = .{}, .channel = undefined, .last_frame = undefined };
}

test "remote hidden pane discards pending timing and retires input through its gate sequence" {
    const perf = @import("../../gx/perf.zig");
    const previous = perf.enabled();
    defer perf.setEnabled(previous);
    perf.setEnabled(true);
    const pane = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(pane);
    pane.* = perfTestPane();
    pane.view = perfTestView();
    pane.gate.sequence = 8;
    pane.perf_last_input = 3;
    pane.view.?.perf_frame.received(.{ .sequence = 7, .qpc = 100 }, 150);
    pane.hidePerfIfHidden();
    try std.testing.expectEqual(RemotePerf.Presentation{}, pane.view.?.perf_frame);
    try std.testing.expectEqual(@as(u64, 8), pane.perf_last_input);
    pane.view.?.receivePerf(.{ .sequence = 7, .qpc = 100 }, false);
    try std.testing.expectEqual(RemotePerf.Presentation{}, pane.view.?.perf_frame);
    // draw must return before clocks, channel access or painting when hidden.
    try std.testing.expectEqual(View.DrawResult.waiting, pane.view.?.draw(undefined, undefined));
    pane.visible = true;
    // Fixed clocks keep the hide/show attribution regression purely logical.
    pane.view.?.perf_frame.received(.{ .sequence = 7, .qpc = 100 }, 200);
    pane.hidePerfIfHidden();
    const samples = pane.view.?.perf_frame.complete(&pane.perf_last_input, 210, 1_000_000);
    try std.testing.expectEqual(@as(?u64, 10), samples.present);
    try std.testing.expectEqual(@as(?u64, null), samples.input_to_present);
    pane.visible = false;
    pane.perf_last_input = 10;
    pane.hidePerfIfHidden();
    try std.testing.expectEqual(@as(u64, 10), pane.perf_last_input);
    pane.view = null;
    pane.gate.sequence = 11;
    pane.hidePerfIfHidden();
    try std.testing.expectEqual(@as(u64, 11), pane.perf_last_input);
}

test "remote emitTimed gates inactive input and stamps only measurable event kinds" {
    const perf = @import("../../gx/perf.zig");
    const previous = perf.enabled();
    defer perf.setEnabled(previous);
    const Sink = struct {
        calls: u64 = 0,
        stamp: RemotePerf.InputStamp = .{},
        accept: bool = true,
        fn input(ctx: *anyopaque, _: refs.Reference, value: protocol.Input) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.stamp = value.perf;
            return self.accept;
        }
    };
    var sink: Sink = .{};
    const pane = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(pane);
    pane.* = perfTestPane();
    pane.callbacks = .{ .ctx = &sink, .input = Sink.input, .close_requested = undefined };
    pane.visible = true;
    pane.input_suspended = false;
    const event: Input.Event = .{ .text = try protocol.Text.init("x") };
    perf.setEnabled(true);
    pane.emitTimed(event, 100);
    try std.testing.expectEqual(@as(u64, 0), sink.calls); // no input lease
    try pane.gate.enable(.{ .holder_epoch = 2, .transaction = 7, .generation = 9 });
    inline for (.{ "destroying", "unavailable", "closed", "close_pending", "input_suspended" }) |field| {
        @field(pane, field) = true;
        pane.emitTimed(event, 100);
        @field(pane, field) = false;
    }
    pane.visible = false;
    pane.emitTimed(event, 100);
    try std.testing.expectEqual(@as(u64, 0), sink.calls);
    try std.testing.expectEqual(@as(u64, 0), pane.gate.sequence);
    pane.visible = true;
    pane.emitTimed(event, 100);
    try std.testing.expectEqual(RemotePerf.InputStamp{ .sequence = 1, .qpc = 100 }, sink.stamp);
    pane.emitTimed(.{ .key = .{ .action = .press, .physical = 0, .unicode = 0, .modifiers = 0 } }, 200);
    try std.testing.expectEqual(RemotePerf.InputStamp{}, sink.stamp);
    sink.accept = false;
    pane.emitTimed(event, 300);
    try std.testing.expect(pane.input_busy);
    try std.testing.expectEqual(@as(u64, 3), pane.gate.sequence);
    sink.accept = true;
    perf.setEnabled(false);
    pane.emit(event);
    try std.testing.expectEqual(RemotePerf.InputStamp{}, sink.stamp);
    try std.testing.expect(!pane.input_busy);
    try std.testing.expectEqual(@as(u64, 4), sink.calls);
}

test "remote paint timing requires perf visible open drawn and successful EndDraw" {
    const perf = @import("../../gx/perf.zig");
    const previous = perf.enabled();
    defer perf.setEnabled(previous);
    const pane = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(pane);
    pane.* = perfTestPane();
    pane.view = perfTestView();
    for ([_]bool{ false, true }) |enabled| {
        perf.setEnabled(enabled);
        for ([_]bool{ false, true }) |visible| {
            pane.visible = visible;
            for ([_]bool{ false, true }) |closed| {
                pane.closed = closed;
                for ([_]bool{ false, true }) |completed| {
                    for (std.enums.values(View.DrawResult)) |result| {
                        pane.perf_last_input = 0;
                        pane.view.?.perf_frame.received(.{ .sequence = 7, .qpc = 1 }, 1);
                        pane.recordPaint(completed, result);
                        const expected = enabled and visible and !closed and completed and result == .drawn;
                        try std.testing.expectEqual(@as(u64, if (expected) 7 else 0), pane.perf_last_input);
                        try std.testing.expectEqual(@as(u64, if (expected) 0 else 1), pane.view.?.perf_frame.received_qpc);
                        if (expected) {
                            pane.recordPaint(completed, result);
                            try std.testing.expectEqual(RemotePerf.Presentation{}, pane.view.?.perf_frame);
                        }
                    }
                }
            }
        }
    }
}
