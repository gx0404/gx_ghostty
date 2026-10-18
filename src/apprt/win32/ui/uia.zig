//! Free-threaded UI Automation providers over owned immutable snapshots.
//! GUI code alone publishes/revokes snapshots and drains typed actions. Use a
//! thread-safe allocator (page_allocator in production), never a UI arena.
const std = @import("std");
const w32 = @import("../win32.zig");
const refs = @import("../../../gx/ui_ref.zig");
const Allocator = std.mem.Allocator;
const HR = i32;
const S_OK: HR = 0;
const E_NOINTERFACE: HR = @bitCast(@as(u32, 0x80004002));
const E_INVALIDARG: HR = @bitCast(@as(u32, 0x80070057));
const E_OUTOFMEMORY: HR = @bitCast(@as(u32, 0x8007000e));
const UNAVAILABLE: HR = @bitCast(@as(u32, 0x80040201));
const DISABLED: HR = @bitCast(@as(u32, 0x80040200));
const INVALID_OPERATION: HR = @bitCast(@as(u32, 0x80131509));
pub const root_object_id: i32 = -25;
pub const wake_message: u32 = w32.WM_APP + 0x67;
pub const max_nodes = 512;
pub const max_string_bytes = 4096;
pub const max_snapshot_bytes = 1024 * 1024;

pub const Rect = extern struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };
pub const Role = enum(i32) { button = 50000, checkbox = 50002, edit = 50004, list_item = 50007, list = 50008, menu = 50009, menu_item = 50011, tab = 50018, tab_item = 50019, text = 50020, window = 50032, pane = 50033 };
pub const Patterns = struct { invoke: bool = false, selection_item: bool = false, selection: bool = false, value: bool = false, toggle: bool = false, expand_collapse: bool = false, window: bool = false };
pub const NodeSpec = struct {
    id: u64,
    parent: ?u16 = null,
    name: []const u8,
    value: []const u8 = "",
    role: Role = .pane,
    bounds: Rect = .{},
    patterns: Patterns = .{},
    enabled: bool = true,
    focused: bool = false,
    focusable: bool = false,
    offscreen: bool = false,
    selected: bool = false,
    read_only: bool = true,
    multiple_selection: bool = false,
    selection_required: bool = false,
    toggle_state: i32 = 0,
    expand_state: i32 = 0,
    window_state: i32 = 0,
    window_interaction_state: i32 = 2,
    live_setting: i32 = 0,
    can_maximize: bool = false,
    can_minimize: bool = false,
    modal: bool = false,
    topmost: bool = false,
    /// Only a root with an actual custom caption suppresses the HWND host's
    /// synthetic nonclient title bar. Native/DWM captions retain their provider.
    refuse_nonclient: bool = false,
};
/// `focus_changed` is internal: only `Publisher.moveFocus` queues it, so the
/// App message loop raises the focus changed event (`raiseFocusChanged`).
/// No provider method can queue it.
pub const ActionKind = enum { focus, invoke, select, add_selection, remove_selection, set_value, toggle, expand, collapse, close, set_window_state, notification, focus_changed };
/// UIA_AutomationFocusChangedEventId.
const focus_changed_event: i32 = 20005;
pub const Action = struct {
    attachment: refs.Attachment,
    snapshot_id: u64,
    /// Nonzero only for a stable read-only view; only its root focus action
    /// may remain valid across immutable content revisions.
    view_id: u64 = 0,
    node_id: u64,
    kind: ActionKind,
    window_state: i32 = 0,
    value: []u8,
    alloc: Allocator,
    pub fn deinit(self: *Action) void {
        self.alloc.free(self.value);
        self.* = undefined;
    }
};

/// Independently retained by snapshots. close() precedes destruction of hwnd.
pub const Queue = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    refs_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    mutex: std.os.windows.SRWLOCK = .{},
    closed: bool = false,
    next_snapshot_id: u64 = 1,
    items: [64]?Action = .{null} ** 64,
    head: usize = 0,
    length: usize = 0,
    pub fn create(alloc: Allocator, hwnd: w32.HWND) !*Queue {
        const self = try alloc.create(Queue);
        self.* = .{ .alloc = alloc, .hwnd = hwnd };
        return self;
    }
    pub fn retain(self: *Queue) void {
        _ = self.refs_count.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Queue) void {
        if (self.refs_count.fetchSub(1, .acq_rel) == 1) {
            self.close();
            self.alloc.destroy(self);
        }
    }
    pub fn close(self: *Queue) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
        while (self.length > 0) {
            var action = self.items[self.head].?;
            self.items[self.head] = null;
            self.head = (self.head + 1) % self.items.len;
            self.length -= 1;
            action.deinit();
        }
    }
    pub fn pop(self: *Queue) ?Action {
        self.lock();
        defer self.unlock();
        if (self.length == 0) return null;
        const action = self.items[self.head];
        self.items[self.head] = null;
        self.head = (self.head + 1) % self.items.len;
        self.length -= 1;
        return action;
    }
    fn reserveSnapshotId(self: *Queue) !u64 {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.Closed;
        if (self.next_snapshot_id == std.math.maxInt(u64)) return error.Exhausted;
        const id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        return id;
    }
    fn lock(self: *Queue) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.mutex);
    }
    fn unlock(self: *Queue) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.mutex);
    }
    fn post(self: *Queue, snapshot: *Snapshot, node_id: u64, kind: ActionKind, value: []const u8, state: i32) HR {
        return self.postWith(snapshot, node_id, kind, value, state, w32.PostMessageW);
    }
    fn postWith(self: *Queue, snapshot: *Snapshot, node_id: u64, kind: ActionKind, value: []const u8, state: i32, post_message: anytype) HR {
        if (value.len > max_string_bytes) return E_INVALIDARG;
        const copy = self.alloc.dupe(u8, value) catch return E_OUTOFMEMORY;
        var reason: []const u8 = "queued";
        self.lock();
        defer {
            const pending = self.length;
            self.unlock();
            // Logging never holds the queue lock and never includes Value text.
            fixtureTrace(snapshot, node_id, kind, reason, pending);
        }
        if (self.closed or !snapshot.isActive() or self.length == self.items.len) {
            reason = if (self.closed) "queue_closed" else if (!snapshot.isActive()) "snapshot_inactive" else "queue_full";
            self.alloc.free(copy);
            return UNAVAILABLE;
        }
        // PostMessage never calls the destination synchronously; holding this
        // short lock prevents delivery before the owned payload is installed.
        if (post_message(self.hwnd, wake_message, 0, 0) == 0) {
            reason = "PostMessageW_failed";
            self.alloc.free(copy);
            return UNAVAILABLE;
        }
        self.items[(self.head + self.length) % self.items.len] = .{
            .attachment = snapshot.attachment,
            .snapshot_id = snapshot.id,
            .view_id = if (snapshot.view) |view| view.id else 0,
            .node_id = node_id,
            .kind = kind,
            .value = copy,
            .window_state = state,
            .alloc = self.alloc,
        };
        self.length += 1;
        return S_OK;
    }
};

const ReturnProvider = *const fn (w32.HWND, usize, isize, *Face) callconv(.winapi) isize;
const HostProvider = *const fn (w32.HWND, *?*Face) callconv(.winapi) HR;
const Notify = *const fn (*Face, i32, i32, ?[*:0]u16, ?[*:0]u16) callconv(.winapi) HR;
const Event = *const fn (*Face, i32) callconv(.winapi) HR;
pub const Api = struct {
    alloc: Allocator,
    module: *anyopaque,
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    return_provider: ReturnProvider,
    host_provider: HostProvider,
    notification: ?Notify,
    event: ?Event,
    pub fn load(alloc: Allocator) !*Api {
        const module = w32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("UIAutomationCore.dll"), null, 0x800) orelse return error.Unavailable;
        errdefer _ = w32.FreeLibrary(module);
        const ret = w32.GetProcAddress(module, "UiaReturnRawElementProvider") orelse return error.Unavailable;
        const host_proc = w32.GetProcAddress(module, "UiaHostProviderFromHwnd") orelse return error.Unavailable;
        const self = try alloc.create(Api);
        self.* = .{ .alloc = alloc, .module = module, .return_provider = @ptrCast(ret), .host_provider = @ptrCast(host_proc), .notification = @ptrCast(w32.GetProcAddress(module, "UiaRaiseNotificationEvent")), .event = @ptrCast(w32.GetProcAddress(module, "UiaRaiseAutomationEvent")) };
        return self;
    }
    pub fn retain(self: *Api) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Api) void {
        if (self.count.fetchSub(1, .acq_rel) == 1) {
            _ = w32.FreeLibrary(self.module);
            self.alloc.destroy(self);
        }
    }
};

/// GUI-only publisher. Normal publications invalidate prior node identities.
/// Remote read-only views can opt into one lifetime shared by content revisions.
pub const Publisher = struct {
    current: ?*Snapshot = null,
    pub fn publish(self: *Publisher, alloc: Allocator, api: *Api, queue: *Queue, attachment: refs.Attachment, hwnd: w32.HWND, nodes: []const NodeSpec) !void {
        const id = try queue.reserveSnapshotId();
        const snapshot = try Snapshot.create(alloc, api, queue, attachment, hwnd, id, nodes);
        self.hide();
        self.current = snapshot;
    }
    /// Refresh owned content without revoking COM readers of the previous
    /// immutable snapshot. No historical snapshot is retained by the GUI.
    /// hide() or another attachment revokes every revision of the view at once.
    pub fn publishStable(self: *Publisher, alloc: Allocator, api: *Api, queue: *Queue, attachment: refs.Attachment, hwnd: w32.HWND, nodes: []const NodeSpec) !void {
        return self.publishStableWithId(alloc, api, queue, attachment, hwnd, try queue.reserveSnapshotId(), nodes);
    }
    fn publishStableWithId(self: *Publisher, alloc: Allocator, api: *Api, queue: *Queue, attachment: refs.Attachment, hwnd: w32.HWND, id: u64, nodes: []const NodeSpec) !void {
        const snapshot = try Snapshot.create(alloc, api, queue, attachment, hwnd, id, nodes);
        errdefer snapshot.release();
        if (self.current) |old| if (old.view) |view| if (old.isActive() and old.api == api and old.queue == queue and old.hwnd == hwnd and old.attachment.matches(attachment)) {
            view.retain();
            snapshot.view = view;
            self.current = snapshot;
            old.release();
            return;
        };
        snapshot.view = try ViewLifetime.create(alloc, id);
        self.hide();
        self.current = snapshot;
    }
    pub fn hide(self: *Publisher) void {
        const old = self.current orelse return;
        self.current = null;
        if (old.view) |view| view.active.store(false, .release);
        old.active.store(false, .release);
        old.release();
    }
    pub fn deinit(self: *Publisher) void {
        self.hide();
    }
    pub fn accepts(self: *const Publisher, action: Action) bool {
        const snapshot = self.current orelse return false;
        if (!snapshot.isActive() or !snapshot.attachment.matches(action.attachment)) return false;
        if (snapshot.view) |view| return action.kind == .focus and action.node_id == 1 and action.view_id == view.id;
        return action.view_id == 0 and snapshot.id == action.snapshot_id;
    }
    pub fn returnProvider(self: *const Publisher, wparam: usize, lparam: isize) isize {
        if (w32.objectId(lparam) != root_object_id) return 0;
        const snapshot = self.current orelse return 0;
        snapshot.retain();
        defer snapshot.release();
        if (!snapshot.isActive()) return 0;
        return snapshot.api.return_provider(snapshot.hwnd, wparam, lparam, snapshot.nodes[0].face(.simple));
    }
    /// GUI thread: the keyboard focus moved to the node `node_id` of the
    /// current snapshot (0: to none of its nodes) and nothing else changed.
    /// The snapshot keeps its identity, so every element clients hold stays
    /// valid, and `HasKeyboardFocus` and `GetFocus` report the new focus at
    /// once. A move to another node queues its focus changed event for the
    /// App message loop (`raiseFocusChanged`); nothing is raised from here,
    /// and a full queue only loses the event. Returns false without an active
    /// snapshot or such a node, and for a stable view, which reports the
    /// focus of each content revision (`publishStable`).
    pub fn moveFocus(self: *const Publisher, node_id: u64) bool {
        return self.moveFocusWith(node_id, w32.PostMessageW);
    }
    fn moveFocusWith(self: *const Publisher, node_id: u64, post_message: anytype) bool {
        const snapshot = self.current orelse return false;
        if (!snapshot.isActive() or snapshot.view != null) return false;
        if (node_id != 0 and snapshot.findNode(node_id) == null) return false;
        if (snapshot.focus.swap(node_id, .acq_rel) == node_id or node_id == 0) return true;
        _ = snapshot.queue.postWith(snapshot, node_id, .focus_changed, "", 0, post_message);
        return true;
    }
    /// From the App message loop, outside locks (`PopupBridge.dispatch`):
    /// raise UIA_AutomationFocusChangedEventId for `node_id` if it still has
    /// the focus in the current snapshot. A true return is an API result,
    /// not event receipt.
    pub fn raiseFocusChanged(self: *const Publisher, node_id: u64) bool {
        const snapshot = self.current orelse return false;
        snapshot.retain();
        defer snapshot.release();
        if (!snapshot.isActive() or snapshot.focus.load(.acquire) != node_id) return false;
        const node = snapshot.findNode(node_id) orelse return false;
        const raise = snapshot.api.event orelse return false;
        return raise(node.face(.simple), focus_changed_event) >= 0;
    }
    /// GUI thread: whether `specs` describe the current snapshot's elements
    /// unchanged, for the same owner and window, apart from which one has
    /// the focus (`NodeSpec.focused`), the one state `moveFocus` changes.
    pub fn matchesExceptFocus(self: *const Publisher, attachment: refs.Attachment, hwnd: w32.HWND, specs: []const NodeSpec) bool {
        const snapshot = self.current orelse return false;
        if (!snapshot.isActive() or snapshot.view != null or snapshot.hwnd != hwnd or !snapshot.attachment.matches(attachment)) return false;
        if (snapshot.nodes.len != specs.len) return false;
        for (snapshot.nodes, specs) |*node, spec| if (!sameExceptFocus(node.spec, spec)) return false;
        return true;
    }
    /// Call outside locks. A true return is an API result, not event receipt.
    pub fn notify(self: *const Publisher, text: []const u8) bool {
        const snapshot = self.current orelse return false;
        if (!snapshot.nodes[0].spec.patterns.window or text.len > max_string_bytes) return false;
        snapshot.retain();
        defer snapshot.release();
        if (!snapshot.isActive()) return false;
        if (snapshot.api.notification) |notify_fn| {
            const wide = std.unicode.utf8ToUtf16LeAllocZ(snapshot.alloc, text) catch return false;
            defer snapshot.alloc.free(wide);
            const message = SysAllocStringLen(wide.ptr, @intCast(wide.len)) orelse return false;
            defer SysFreeString(message);
            const activity = SysAllocStringLen(std.unicode.utf8ToUtf16LeStringLiteral("GX notification"), 15) orelse return false;
            defer SysFreeString(activity);
            return notify_fn(snapshot.nodes[0].face(.simple), 4, 2, message, activity) >= 0;
        }
        if (snapshot.api.event) |event_fn| return event_fn(snapshot.nodes[0].face(.simple), 20024) >= 0;
        return false;
    }
    /// Queue an internal announcement. It is raised from the App message loop,
    /// never synchronously from a paint/show callback that owns widget memory.
    pub fn announce(self: *const Publisher, text: []const u8) bool {
        return self.announceWith(text, w32.PostMessageW);
    }
    fn announceWith(self: *const Publisher, text: []const u8, post_message: anytype) bool {
        const snapshot = self.current orelse return false;
        if (!snapshot.nodes[0].spec.patterns.window) return false;
        return snapshot.queue.postWith(snapshot, snapshot.nodes[0].spec.id, .notification, text, 0, post_message) == S_OK;
    }
};

/// GUI-owned semantic announcement retained until dispatch, even if the bounded
/// queue fills or a layout publication invalidates its previously queued copy.
pub const PendingAnnouncement = struct {
    bytes: [max_string_bytes]u8 = undefined,
    length: usize = 0,
    pending: bool = false,
    queued_snapshot_id: ?u64 = null,

    pub fn cancel(self: *PendingAnnouncement) void {
        self.pending = false;
        self.queued_snapshot_id = null;
    }
    pub fn stage(self: *PendingAnnouncement, text: []const u8) void {
        self.cancel();
        if (text.len > self.bytes.len or !std.unicode.utf8ValidateSlice(text)) return;
        @memcpy(self.bytes[0..text.len], text);
        self.length = text.len;
        self.pending = true;
    }
    pub fn retry(self: *PendingAnnouncement, publisher: *const Publisher) void {
        self.retryWith(publisher, w32.PostMessageW);
    }
    fn retryWith(self: *PendingAnnouncement, publisher: *const Publisher, post_message: anytype) void {
        const snapshot = publisher.current orelse return;
        if (!self.pending or self.queued_snapshot_id == snapshot.id) return;
        if (publisher.announceWith(self.bytes[0..self.length], post_message)) self.queued_snapshot_id = snapshot.id;
    }
    /// Clear before calling UIAutomationCore: its callback may destroy the owner.
    pub fn consume(self: *PendingAnnouncement, action: *const Action) bool {
        if (!self.pending or action.kind != .notification or self.queued_snapshot_id != action.snapshot_id or
            !std.mem.eql(u8, self.bytes[0..self.length], action.value)) return false;
        self.cancel();
        return true;
    }
};

const FaceKind = enum { simple, fragment, root, invoke, selection_item, selection, value, toggle, expand_collapse, window };
const face_count = @typeInfo(FaceKind).@"enum".fields.len;
pub const Face = extern struct { vtable: *const anyopaque, node: *Node };
const Node = struct {
    snapshot: *Snapshot,
    index: usize,
    spec: NodeSpec,
    faces: [face_count]Face,
    fn face(self: *Node, kind: FaceKind) *Face {
        return &self.faces[@intFromEnum(kind)];
    }
    fn supported(self: *const Node, kind: FaceKind) bool {
        return switch (kind) {
            .simple, .fragment => true,
            .root => self.index == 0,
            .invoke => self.spec.patterns.invoke,
            .selection_item => self.spec.patterns.selection_item,
            .selection => self.spec.patterns.selection,
            .value => self.spec.patterns.value,
            .toggle => self.spec.patterns.toggle,
            .expand_collapse => self.spec.patterns.expand_collapse,
            .window => self.spec.patterns.window,
        };
    }
};
const ViewLifetime = struct {
    alloc: Allocator,
    id: u64,
    active: std.atomic.Value(bool) = .init(true),
    count: std.atomic.Value(usize) = .init(1),

    fn create(alloc: Allocator, id: u64) !*ViewLifetime {
        const self = try alloc.create(ViewLifetime);
        self.* = .{ .alloc = alloc, .id = id };
        return self;
    }
    fn retain(self: *ViewLifetime) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
    fn release(self: *ViewLifetime) void {
        if (self.count.fetchSub(1, .acq_rel) == 1) self.alloc.destroy(self);
    }
};

const Snapshot = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    api: *Api,
    queue: *Queue,
    attachment: refs.Attachment,
    hwnd: w32.HWND,
    id: u64,
    nodes: []Node,
    view: ?*ViewLifetime = null,
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    /// The id of the node with the keyboard focus (0: none), first from the
    /// specs' `focused`. The one state of a published snapshot that changes
    /// in place (`Publisher.moveFocus`, GUI thread); providers read it
    /// atomically, so a focus move needs no publication and revokes nothing.
    focus: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fn create(alloc: Allocator, api: *Api, queue: *Queue, attachment: refs.Attachment, hwnd: w32.HWND, id: u64, specs: []const NodeSpec) !*Snapshot {
        try validate(specs);
        if (!attachment.isValid()) return error.InvalidSnapshot;
        const self = try alloc.create(Snapshot);
        errdefer alloc.destroy(self);
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const storage = arena.allocator();
        const nodes = try storage.alloc(Node, specs.len);
        for (specs, 0..) |spec, index| {
            var owned = spec;
            owned.name = try storage.dupe(u8, spec.name);
            owned.value = try storage.dupe(u8, spec.value);
            nodes[index] = .{ .snapshot = self, .index = index, .spec = owned, .faces = undefined };
            inline for (0..face_count) |i| nodes[index].faces[i] = .{ .vtable = vtables[i], .node = &nodes[index] };
        }
        api.retain();
        queue.retain();
        self.* = .{ .alloc = alloc, .arena = arena, .api = api, .queue = queue, .attachment = attachment, .hwnd = hwnd, .id = id, .nodes = nodes, .focus = .init(initialFocus(specs)) };
        return self;
    }
    fn initialFocus(specs: []const NodeSpec) u64 {
        for (specs) |spec| if (spec.focused) return spec.id;
        return 0;
    }
    fn findNode(self: *Snapshot, id: u64) ?*Node {
        if (id == 0) return null;
        for (self.nodes) |*node| if (node.spec.id == id) return node;
        return null;
    }
    fn retain(self: *Snapshot) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
    fn isActive(self: *const Snapshot) bool {
        return self.active.load(.acquire) and (if (self.view) |view| view.active.load(.acquire) else true);
    }
    fn release(self: *Snapshot) void {
        if (self.count.fetchSub(1, .acq_rel) == 1) {
            if (self.view) |view| view.release();
            self.queue.release();
            self.api.release();
            self.arena.deinit();
            self.alloc.destroy(self);
        }
    }
};

/// Field by field, strings by content. `focused` is the one field a focus
/// move changes (`Publisher.matchesExceptFocus`).
fn sameExceptFocus(a: NodeSpec, b: NodeSpec) bool {
    inline for (@typeInfo(NodeSpec).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "focused")) continue;
        const equal = if (field.type == []const u8)
            std.mem.eql(u8, @field(a, field.name), @field(b, field.name))
        else
            std.meta.eql(@field(a, field.name), @field(b, field.name));
        if (!equal) return false;
    }
    return true;
}

fn validate(nodes: []const NodeSpec) !void {
    if (nodes.len == 0 or nodes.len > max_nodes) return error.InvalidSnapshot;
    var bytes: usize = 0;
    for (nodes, 0..) |node, i| {
        if (node.id == 0 or (if (i == 0) node.parent != null else node.parent == null or node.parent.? >= i)) return error.InvalidSnapshot;
        for (nodes[0..i]) |other| if (other.id == node.id) return error.InvalidSnapshot;
        for ([_][]const u8{ node.name, node.value }) |value| {
            if (value.len > max_string_bytes or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSnapshot;
            bytes += value.len;
        }
        if (bytes > max_snapshot_bytes) return error.InvalidSnapshot;
        for ([_]f64{ node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height }) |value| {
            if (!std.math.isFinite(value) or @abs(value) > 16_777_216) return error.InvalidSnapshot;
        }
        if (node.bounds.width < 0 or node.bounds.height < 0 or node.toggle_state < 0 or node.toggle_state > 2 or node.expand_state < 0 or node.expand_state > 3 or node.window_state < 0 or node.window_state > 2 or node.window_interaction_state < 0 or node.window_interaction_state > 4 or node.live_setting < 0 or node.live_setting > 2) return error.InvalidSnapshot;
    }
}

fn guid(comptime text: []const u8) w32.GUID {
    @setEvalBranchQuota(10000);
    var result: w32.GUID = undefined;
    result.Data1 = std.fmt.parseInt(u32, text[0..8], 16) catch unreachable;
    result.Data2 = std.fmt.parseInt(u16, text[9..13], 16) catch unreachable;
    result.Data3 = std.fmt.parseInt(u16, text[14..18], 16) catch unreachable;
    const offsets = [_]usize{ 19, 21, 24, 26, 28, 30, 32, 34 };
    for (offsets, 0..) |offset, i| result.Data4[i] = std.fmt.parseInt(u8, text[offset .. offset + 2], 16) catch unreachable;
    return result;
}
const iid_unknown = guid("00000000-0000-0000-c000-000000000046");
const iids = [_]w32.GUID{
    guid("d6dd68d1-86fd-4332-8666-9abedea2d24c"),
    guid("f7063da8-8359-439c-9297-bbc5299a7d87"),
    guid("620ce2a5-ab8f-40a9-86cb-de3c75599b58"),
    guid("54fcb24b-e18e-47a2-b4d3-eccbe77599a2"),
    guid("2acad808-b2d4-452d-a407-91ff1ad167b2"),
    guid("fb8b03af-3bdf-48d4-bd36-1a65793be168"),
    guid("c7935180-6fb3-4201-b174-7df73adbf64a"),
    guid("56d00bd0-c4f4-433c-a836-1a52a57e0892"),
    guid("d847d3a5-cab0-4a98-8c32-ecb45c59ad24"),
    guid("987df77b-db06-4d77-8f8a-86a9c3bb90b9"),
};
fn equalGuid(a: *const w32.GUID, b: *const w32.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}
fn live(face: *Face) bool {
    return face.node.snapshot.isActive();
}
fn retainFace(face: *Face) callconv(.winapi) u32 {
    return @intCast(face.node.snapshot.count.fetchAdd(1, .monotonic) + 1);
}
fn releaseFace(face: *Face) callconv(.winapi) u32 {
    const snapshot = face.node.snapshot;
    // COM callers do not rely on the exact count. Do not read freed storage.
    snapshot.release();
    return 0;
}
fn queryFace(face: *Face, iid: *const w32.GUID, out: *?*anyopaque) callconv(.winapi) HR {
    out.* = null;
    if (equalGuid(iid, &iid_unknown)) {
        out.* = face.node.face(.simple);
        _ = retainFace(face);
        return S_OK;
    }
    for (iids, 0..) |candidate, index| {
        if (equalGuid(iid, &candidate) and face.node.supported(@enumFromInt(index))) {
            out.* = &face.node.faces[index];
            _ = retainFace(face);
            return S_OK;
        }
    }
    return E_NOINTERFACE;
}
const UnknownTable = extern struct {
    QueryInterface: *const fn (*Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) HR = queryFace,
    AddRef: *const fn (*Face) callconv(.winapi) u32 = retainFace,
    Release: *const fn (*Face) callconv(.winapi) u32 = releaseFace,
};
pub const Variant = extern struct {
    tag: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    data: extern union { integer: i64, real: f64, pointer: ?*anyopaque, record: [2]usize } = .{ .record = .{ 0, 0 } },
};
fn boolean(value: bool) Variant {
    return .{ .tag = 11, .data = .{ .integer = if (value) -1 else 0 } };
}
fn integer(value: i32) Variant {
    return .{ .tag = 3, .data = .{ .integer = value } };
}
fn bstr(face: *Face, text: []const u8, out: *?[*:0]u16) HR {
    out.* = null;
    const alloc = face.node.snapshot.alloc;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return E_OUTOFMEMORY;
    defer alloc.free(wide);
    out.* = SysAllocStringLen(wide.ptr, @intCast(wide.len)) orelse return E_OUTOFMEMORY;
    return S_OK;
}
fn stringProperty(face: *Face, text: []const u8, out: *Variant) HR {
    var value: ?[*:0]u16 = null;
    const result = bstr(face, text, &value);
    if (result < 0) return result;
    out.* = .{ .tag = 8, .data = .{ .pointer = value } };
    return S_OK;
}
fn options(face: *Face, out: *u32) callconv(.winapi) HR {
    out.* = 0;
    if (!live(face)) return UNAVAILABLE;
    // ServerSide + ProviderOwnsSetFocus. Do not request COM apartment threading:
    // methods are thread safe and focus is always posted, never called inline.
    out.* = 0x2 | 0x10;
    if (face.node.index == 0 and face.node.spec.refuse_nonclient) out.* |= 0x40;
    return S_OK;
}
fn patternKind(id: i32) ?FaceKind {
    return switch (id) {
        10000 => .invoke,
        10001 => .selection,
        10002 => .value,
        10005 => .expand_collapse,
        10009 => .window,
        10010 => .selection_item,
        10015 => .toggle,
        else => null,
    };
}
fn pattern(face: *Face, id: i32, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    const kind = patternKind(id) orelse return S_OK;
    if (!face.node.supported(kind)) return S_OK;
    out.* = face.node.face(kind);
    _ = retainFace(face);
    return S_OK;
}
fn property(face: *Face, id: i32, out: *Variant) callconv(.winapi) HR {
    out.* = .{};
    if (!live(face)) return UNAVAILABLE;
    const node = face.node.spec;
    switch (id) {
        30001 => {
            const array = SafeArrayCreateVector(5, 0, 4) orelse return E_OUTOFMEMORY;
            const values = [_]f64{ node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height };
            for (values, 0..) |value, i| {
                var index: i32 = @intCast(i);
                var element = value;
                if (SafeArrayPutElement(array, &index, &element) < 0) {
                    _ = SafeArrayDestroy(array);
                    return E_OUTOFMEMORY;
                }
            }
            out.* = .{ .tag = 0x2005, .data = .{ .pointer = array } };
        },
        30002 => out.* = integer(@bitCast(GetCurrentProcessId())),
        30003 => out.* = integer(@intFromEnum(node.role)),
        30005 => return stringProperty(face, node.name, out),
        30008 => out.* = boolean(face.node.snapshot.focus.load(.acquire) == node.id),
        30009 => out.* = boolean(node.focusable),
        30010 => out.* = boolean(node.enabled),
        30011 => {
            var buffer: [32]u8 = undefined;
            const id_text = std.fmt.bufPrint(&buffer, "gx-{d}", .{node.id}) catch return E_INVALIDARG;
            return stringProperty(face, id_text, out);
        },
        30016, 30017 => out.* = boolean(true),
        30019 => out.* = boolean(false),
        30020 => out.* = integer(if (face.node.index == 0) @bitCast(@as(u32, @truncate(@intFromPtr(face.node.snapshot.hwnd)))) else 0),
        30022 => out.* = boolean(node.offscreen),
        30024 => return stringProperty(face, "GhosttyGX", out),
        30031 => out.* = boolean(node.patterns.invoke),
        30028 => out.* = boolean(node.patterns.expand_collapse),
        30036 => out.* = boolean(node.patterns.selection_item),
        30037 => out.* = boolean(node.patterns.selection),
        30041 => out.* = boolean(node.patterns.toggle),
        30043 => out.* = boolean(node.patterns.value),
        30044 => out.* = boolean(node.patterns.window),
        30045 => if (node.patterns.value) return stringProperty(face, node.value, out),
        30046 => if (node.patterns.value) {
            out.* = boolean(node.read_only);
        },
        30070 => if (node.patterns.expand_collapse) {
            out.* = integer(node.expand_state);
        },
        30079 => if (node.patterns.selection_item) {
            out.* = boolean(node.selected);
        },
        30086 => if (node.patterns.toggle) {
            out.* = integer(node.toggle_state);
        },
        30135 => out.* = integer(node.live_setting),
        else => {},
    }
    return S_OK;
}
fn host(face: *Face, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    if (face.node.index != 0) return S_OK;
    return face.node.snapshot.api.host_provider(face.node.snapshot.hwnd, out);
}
const SimpleTable = extern struct {
    unknown: UnknownTable = .{},
    ProviderOptions: *const fn (*Face, *u32) callconv(.winapi) HR = options,
    GetPatternProvider: *const fn (*Face, i32, *?*Face) callconv(.winapi) HR = pattern,
    GetPropertyValue: *const fn (*Face, i32, *Variant) callconv(.winapi) HR = property,
    HostRawElementProvider: *const fn (*Face, *?*Face) callconv(.winapi) HR = host,
};
fn returnFace(node: *Node, kind: FaceKind, out: *?*Face) HR {
    out.* = node.face(kind);
    _ = retainFace(out.*.?);
    return S_OK;
}
fn navigate(face: *Face, direction: i32, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    const node = face.node;
    const nodes = node.snapshot.nodes;
    var found: ?usize = null;
    switch (direction) {
        0 => found = if (node.spec.parent) |parent| @as(usize, parent) else null,
        1, 2 => if (node.spec.parent != null) {
            for (nodes, 0..) |other, index| {
                if (other.spec.parent != node.spec.parent) continue;
                if (direction == 1 and index > node.index) {
                    found = index;
                    break;
                }
                if (direction == 2 and index < node.index) found = index;
            }
        },
        3, 4 => for (nodes, 0..) |other, index| {
            if (other.spec.parent != null and @as(usize, other.spec.parent.?) == node.index) {
                found = index;
                if (direction == 3) break;
            }
        },
        else => return E_INVALIDARG,
    }
    if (found) |index| return returnFace(&nodes[index], .fragment, out);
    return S_OK;
}
fn runtimeId(face: *Face, out: *?*anyopaque) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    const snapshot = face.node.snapshot;
    const identity = if (snapshot.view) |view| view.id else snapshot.id;
    const values = [_]u32{ 3, @truncate(snapshot.attachment.object.epoch), @truncate(snapshot.attachment.object.epoch >> 32), @truncate(snapshot.attachment.object.epoch >> 64), @truncate(snapshot.attachment.object.epoch >> 96), @truncate(snapshot.attachment.object.id), @truncate(snapshot.attachment.object.id >> 32), @truncate(snapshot.attachment.object.generation), @truncate(snapshot.attachment.object.generation >> 32), @truncate(snapshot.attachment.revision), @truncate(snapshot.attachment.revision >> 32), @truncate(@intFromPtr(snapshot.hwnd)), @truncate(@as(u64, @intFromPtr(snapshot.hwnd)) >> 32), @truncate(identity), @truncate(identity >> 32), @truncate(face.node.spec.id), @truncate(face.node.spec.id >> 32) };
    const array = SafeArrayCreateVector(3, 0, values.len) orelse return E_OUTOFMEMORY;
    for (values, 0..) |value, i| {
        var index: i32 = @intCast(i);
        var element: i32 = @bitCast(value);
        if (SafeArrayPutElement(array, &index, &element) < 0) {
            _ = SafeArrayDestroy(array);
            return E_OUTOFMEMORY;
        }
    }
    out.* = array;
    return S_OK;
}
fn bounds(face: *Face, out: *Rect) callconv(.winapi) HR {
    out.* = .{};
    if (!live(face)) return UNAVAILABLE;
    out.* = face.node.spec.bounds;
    return S_OK;
}
fn embedded(face: *Face, out: *?*anyopaque) callconv(.winapi) HR {
    out.* = null;
    return if (live(face)) S_OK else UNAVAILABLE;
}
fn fragmentRoot(face: *Face, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    return returnFace(&face.node.snapshot.nodes[0], .root, out);
}
fn enqueue(face: *Face, kind: ActionKind, value: []const u8, state: i32) HR {
    if (!live(face)) {
        fixtureTrace(face.node.snapshot, face.node.spec.id, kind, "enqueue_inactive", 0);
        return UNAVAILABLE;
    }
    if (!face.node.spec.enabled) return DISABLED;
    return face.node.snapshot.queue.post(face.node.snapshot, face.node.spec.id, kind, value, state);
}
fn focus(face: *Face) callconv(.winapi) HR {
    if (!live(face)) return UNAVAILABLE;
    if (!face.node.spec.focusable) return INVALID_OPERATION;
    return enqueue(face, .focus, "", 0);
}
const FragmentTable = extern struct {
    unknown: UnknownTable = .{},
    Navigate: *const fn (*Face, i32, *?*Face) callconv(.winapi) HR = navigate,
    GetRuntimeId: *const fn (*Face, *?*anyopaque) callconv(.winapi) HR = runtimeId,
    BoundingRectangle: *const fn (*Face, *Rect) callconv(.winapi) HR = bounds,
    GetEmbeddedFragmentRoots: *const fn (*Face, *?*anyopaque) callconv(.winapi) HR = embedded,
    SetFocus: *const fn (*Face) callconv(.winapi) HR = focus,
    FragmentRoot: *const fn (*Face, *?*Face) callconv(.winapi) HR = fragmentRoot,
};
fn atPoint(face: *Face, x: f64, y: f64, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return E_INVALIDARG;
    const nodes = face.node.snapshot.nodes;
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        const rect = nodes[index].spec.bounds;
        if (!nodes[index].spec.offscreen and x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height)
            return returnFace(&nodes[index], .fragment, out);
    }
    return S_OK;
}
fn getFocus(face: *Face, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    const snapshot = face.node.snapshot;
    const node = snapshot.findNode(snapshot.focus.load(.acquire)) orelse return S_OK;
    return returnFace(node, .fragment, out);
}
const RootTable = extern struct {
    unknown: UnknownTable = .{},
    ElementProviderFromPoint: *const fn (*Face, f64, f64, *?*Face) callconv(.winapi) HR = atPoint,
    GetFocus: *const fn (*Face, *?*Face) callconv(.winapi) HR = getFocus,
};
const ActionFn = *const fn (*Face) callconv(.winapi) HR;
const BoolFn = *const fn (*Face, *i32) callconv(.winapi) HR;
fn actionFn(comptime kind: ActionKind) ActionFn {
    return struct {
        fn call(face: *Face) callconv(.winapi) HR {
            return enqueue(face, kind, "", 0);
        }
    }.call;
}
fn fieldFn(comptime field: []const u8) BoolFn {
    return struct {
        fn call(face: *Face, out: *i32) callconv(.winapi) HR {
            out.* = 0;
            if (!live(face)) return UNAVAILABLE;
            const value = @field(face.node.spec, field);
            out.* = if (@TypeOf(value) == bool) @intFromBool(value) else value;
            return S_OK;
        }
    }.call;
}
const InvokeTable = extern struct { unknown: UnknownTable = .{}, Invoke: ActionFn = actionFn(.invoke) };
fn containerNode(node: *Node) ?*Node {
    var parent = node.spec.parent;
    while (parent) |index| {
        const candidate = &node.snapshot.nodes[index];
        if (candidate.spec.patterns.selection) return candidate;
        parent = candidate.spec.parent;
    }
    return null;
}
fn selectionContainer(face: *Face, out: *?*Face) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    if (containerNode(face.node)) |node| return returnFace(node, .simple, out);
    return S_OK;
}
fn changeSelection(face: *Face, kind: ActionKind) HR {
    if (!live(face)) return UNAVAILABLE;
    const container = containerNode(face.node) orelse return INVALID_OPERATION;
    if (kind == .add_selection and !container.spec.multiple_selection)
        return enqueue(face, .select, "", 0);
    if (kind == .remove_selection) {
        if (!face.node.spec.selected) return S_OK;
        if (container.spec.selection_required) {
            var selected_count: usize = 0;
            for (face.node.snapshot.nodes) |*node| {
                if (node.spec.selected and containerNode(node) == container) selected_count += 1;
            }
            if (selected_count <= 1) return INVALID_OPERATION;
        }
    }
    return enqueue(face, kind, "", 0);
}
fn addSelection(face: *Face) callconv(.winapi) HR {
    return changeSelection(face, .add_selection);
}
fn removeSelection(face: *Face) callconv(.winapi) HR {
    return changeSelection(face, .remove_selection);
}
const SelectionItemTable = extern struct {
    unknown: UnknownTable = .{},
    Select: ActionFn = actionFn(.select),
    AddToSelection: ActionFn = addSelection,
    RemoveFromSelection: ActionFn = removeSelection,
    IsSelected: BoolFn = fieldFn("selected"),
    SelectionContainer: *const fn (*Face, *?*Face) callconv(.winapi) HR = selectionContainer,
};
fn selection(face: *Face, out: *?*anyopaque) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    var selected: [max_nodes]*Node = undefined;
    var count: usize = 0;
    for (face.node.snapshot.nodes) |*node| {
        if (node.spec.patterns.selection_item and node.spec.selected and containerNode(node) == face.node) {
            selected[count] = node;
            count += 1;
        }
    }
    const array = SafeArrayCreateVector(13, 0, @intCast(count)) orelse return E_OUTOFMEMORY;
    for (selected[0..count], 0..) |node, i| {
        var index: i32 = @intCast(i);
        if (SafeArrayPutElement(array, &index, node.face(.simple)) < 0) {
            _ = SafeArrayDestroy(array);
            return E_OUTOFMEMORY;
        }
    }
    out.* = array;
    return S_OK;
}
const SelectionTable = extern struct {
    unknown: UnknownTable = .{},
    GetSelection: *const fn (*Face, *?*anyopaque) callconv(.winapi) HR = selection,
    CanSelectMultiple: BoolFn = fieldFn("multiple_selection"),
    IsSelectionRequired: BoolFn = fieldFn("selection_required"),
};
fn setValue(face: *Face, text: [*:0]const u16) callconv(.winapi) HR {
    if (!live(face)) {
        fixtureTrace(face.node.snapshot, face.node.spec.id, .set_value, "setValue_inactive", 0);
        return UNAVAILABLE;
    }
    if (face.node.spec.read_only) return INVALID_OPERATION;
    var length: usize = 0;
    while (length <= max_string_bytes and text[length] != 0) : (length += 1) {}
    if (length > max_string_bytes) return E_INVALIDARG;
    const alloc = face.node.snapshot.alloc;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, text[0..length]) catch |err| return switch (err) {
        error.OutOfMemory => E_OUTOFMEMORY,
        else => E_INVALIDARG,
    };
    defer alloc.free(utf8);
    // GX Value targets are single-line filter and settings editors.
    if (std.mem.indexOfAny(u8, utf8, "\r\n") != null) return E_INVALIDARG;
    return enqueue(face, .set_value, utf8, 0);
}
fn getValue(face: *Face, out: *?[*:0]u16) callconv(.winapi) HR {
    out.* = null;
    if (!live(face)) return UNAVAILABLE;
    return bstr(face, face.node.spec.value, out);
}
const ValueTable = extern struct {
    unknown: UnknownTable = .{},
    SetValue: *const fn (*Face, [*:0]const u16) callconv(.winapi) HR = setValue,
    Value: *const fn (*Face, *?[*:0]u16) callconv(.winapi) HR = getValue,
    IsReadOnly: BoolFn = fieldFn("read_only"),
};

fn fixtureTrace(snapshot: *const Snapshot, node: u64, kind: ActionKind, reason: []const u8, pending: usize) void {
    if (!@import("../remote_test.zig").enabled()) return;
    std.log.scoped(.win32_uia).info("fixture_uia snapshot={d} hwnd={d} node={d} kind={s} reason={s} pending={d}", .{ snapshot.id, @intFromPtr(snapshot.hwnd), node, @tagName(kind), reason, pending });
}
const ToggleTable = extern struct { unknown: UnknownTable = .{}, Toggle: ActionFn = actionFn(.toggle), ToggleState: BoolFn = fieldFn("toggle_state") };
const ExpandTable = extern struct { unknown: UnknownTable = .{}, Expand: ActionFn = actionFn(.expand), Collapse: ActionFn = actionFn(.collapse), ExpandCollapseState: BoolFn = fieldFn("expand_state") };
fn setVisual(face: *Face, state: i32) callconv(.winapi) HR {
    if (!live(face)) return UNAVAILABLE;
    if (state < 0 or state > 2) return E_INVALIDARG;
    if (state == face.node.spec.window_state) return S_OK;
    if ((state == 1 and !face.node.spec.can_maximize) or (state == 2 and !face.node.spec.can_minimize)) return INVALID_OPERATION;
    return enqueue(face, .set_window_state, "", state);
}
fn waitIdle(face: *Face, _: i32, out: *i32) callconv(.winapi) HR {
    out.* = 0;
    return if (live(face)) S_OK else UNAVAILABLE;
}
const WindowTable = extern struct {
    unknown: UnknownTable = .{},
    SetVisualState: *const fn (*Face, i32) callconv(.winapi) HR = setVisual,
    Close: ActionFn = actionFn(.close),
    WaitForInputIdle: *const fn (*Face, i32, *i32) callconv(.winapi) HR = waitIdle,
    CanMaximize: BoolFn = fieldFn("can_maximize"),
    CanMinimize: BoolFn = fieldFn("can_minimize"),
    IsModal: BoolFn = fieldFn("modal"),
    WindowVisualState: BoolFn = fieldFn("window_state"),
    WindowInteractionState: BoolFn = fieldFn("window_interaction_state"),
    IsTopmost: BoolFn = fieldFn("topmost"),
};
const simple_table: SimpleTable = .{};
const fragment_table: FragmentTable = .{};
const root_table: RootTable = .{};
const invoke_table: InvokeTable = .{};
const selection_item_table: SelectionItemTable = .{};
const selection_table: SelectionTable = .{};
const value_table: ValueTable = .{};
const toggle_table: ToggleTable = .{};
const expand_table: ExpandTable = .{};
const window_table: WindowTable = .{};
const vtables = [_]*const anyopaque{ &simple_table, &fragment_table, &root_table, &invoke_table, &selection_item_table, &selection_table, &value_table, &toggle_table, &expand_table, &window_table };

extern "oleaut32" fn SysAllocStringLen([*]const u16, u32) callconv(.winapi) ?[*:0]u16;
extern "oleaut32" fn SysFreeString(?[*:0]u16) callconv(.winapi) void;
extern "oleaut32" fn SafeArrayCreateVector(u16, i32, u32) callconv(.winapi) ?*anyopaque;
extern "oleaut32" fn SafeArrayPutElement(*anyopaque, *i32, *const anyopaque) callconv(.winapi) HR;
extern "oleaut32" fn SafeArrayDestroy(*anyopaque) callconv(.winapi) HR;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

test "UIA snapshot rejects aliases cycles invalid strings and rectangles" {
    try validate(&.{.{ .id = 1, .name = "Window" }});
    try std.testing.expectError(error.InvalidSnapshot, validate(&.{ .{ .id = 1, .name = "Window" }, .{ .id = 1, .parent = 0, .name = "Duplicate" } }));
    try std.testing.expectError(error.InvalidSnapshot, validate(&.{ .{ .id = 1, .name = "Window" }, .{ .id = 2, .parent = 1, .name = "Cycle" } }));
    try std.testing.expectError(error.InvalidSnapshot, validate(&.{.{ .id = 1, .name = "a\x00b" }}));
    try std.testing.expectError(error.InvalidSnapshot, validate(&.{.{ .id = 1, .name = "Window", .bounds = .{ .width = -1 } }}));
}
test "UIA COM layouts match SDK pointer slots and VARIANT" {
    const pointer = @sizeOf(usize);
    try std.testing.expectEqual(7 * pointer, @sizeOf(SimpleTable));
    try std.testing.expectEqual(9 * pointer, @sizeOf(FragmentTable));
    try std.testing.expectEqual(5 * pointer, @sizeOf(RootTable));
    try std.testing.expectEqual(12 * pointer, @sizeOf(WindowTable));
    try std.testing.expectEqual(@as(usize, if (pointer == 8) 24 else 16), @sizeOf(Variant));
}

fn testAttachment() refs.Attachment {
    return .{ .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 }, .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 }, .revision = 1 };
}
fn testPost(_: w32.HWND, _: u32, _: usize, _: isize) i32 {
    return 1;
}
test "UIA snapshot owns strings old provider is inert and queue is bounded" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const api = try Api.load(alloc);
    defer api.release();
    const queue = try Queue.create(alloc, @ptrFromInt(1));
    defer queue.release();
    var publisher: Publisher = .{};
    defer publisher.deinit();
    var name = [_]u8{ 'O', 'K' };
    try publisher.publish(alloc, api, queue, testAttachment(), @ptrFromInt(1), &.{
        .{ .id = 1, .name = "Window", .patterns = .{ .window = true } },
        .{ .id = 2, .parent = 0, .name = &name, .role = .button, .patterns = .{ .invoke = true } },
    });
    name[0] = 'X';
    const snapshot = publisher.current.?;
    const face = snapshot.nodes[1].face(.simple);
    _ = retainFace(face);
    defer _ = releaseFace(face);
    try std.testing.expectEqualStrings("OK", face.node.spec.name);
    var pattern_out: ?*Face = null;
    try std.testing.expectEqual(S_OK, pattern(face, 10009, &pattern_out));
    try std.testing.expect(pattern_out == null);
    for (0..queue.items.len) |_| try std.testing.expectEqual(S_OK, queue.postWith(snapshot, 2, .invoke, "copied", 0, testPost));
    try std.testing.expectEqual(UNAVAILABLE, queue.postWith(snapshot, 2, .invoke, "overflow", 0, testPost));
    var action = queue.pop().?;
    defer action.deinit();
    try std.testing.expect(publisher.accepts(action));
    try std.testing.expectEqualStrings("copied", action.value);
    publisher.hide();
    try std.testing.expect(!publisher.accepts(action));
    var result: Variant = .{};
    try std.testing.expectEqual(UNAVAILABLE, property(face, 30005, &result));
    try std.testing.expectEqual(UNAVAILABLE, queue.postWith(snapshot, 2, .invoke, "late", 0, testPost));
    queue.close();
    try std.testing.expect(queue.pop() == null);
}

fn snapshotAllocationExercise(alloc: Allocator, api: *Api, queue: *Queue) !void {
    const snapshot = try Snapshot.create(alloc, api, queue, testAttachment(), @ptrFromInt(1), 1, &.{ .{ .id = 1, .name = "Window" }, .{ .id = 2, .parent = 0, .name = "Edit", .value = "owned text" } });
    snapshot.release();
}
test "UIA snapshot allocation failure releases partial immutable arena" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const api = try Api.load(alloc);
    defer api.release();
    const queue = try Queue.create(alloc, @ptrFromInt(1));
    defer queue.release();
    try std.testing.checkAllAllocationFailures(alloc, snapshotAllocationExercise, .{ api, queue });
    try std.testing.expectEqual(@as(usize, 1), api.count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), queue.refs_count.load(.monotonic));
}

/// No native UI calls: IDs are injected, API/queue owners remain retained on
/// the stack, and ProviderOptions only reads the immutable snapshot lifetime.
fn stableViewExercise(alloc: Allocator) !void {
    var api: Api = undefined;
    api.count = .init(1);
    var queue: Queue = .{ .alloc = alloc, .hwnd = @ptrFromInt(1) };
    defer std.debug.assert(api.count.load(.acquire) == 1);
    defer std.debug.assert(queue.refs_count.load(.acquire) == 1);
    var publisher: Publisher = .{};
    defer publisher.deinit();
    const attachment = testAttachment();
    var first_name = "first".*;
    try publisher.publishStableWithId(alloc, &api, &queue, attachment, @ptrFromInt(1), 10, &.{.{ .id = 1, .name = &first_name, .focusable = true }});
    const first = publisher.current.?;
    first.retain();
    defer first.release();
    @memset(&first_name, 'x');
    const action: Action = .{ .attachment = attachment, .snapshot_id = first.id, .view_id = first.view.?.id, .node_id = 1, .kind = .focus, .value = &.{}, .alloc = alloc };
    try publisher.publishStableWithId(alloc, &api, &queue, attachment, @ptrFromInt(1), 11, &.{.{ .id = 1, .name = "second", .focusable = true }});
    const second = publisher.current.?;
    second.retain();
    defer second.release();
    try std.testing.expect(first != second);
    try std.testing.expect(first.view == second.view);
    try std.testing.expectEqualStrings("first", first.nodes[0].spec.name);
    try std.testing.expectEqualStrings("second", second.nodes[0].spec.name);
    var flags: u32 = 0;
    try std.testing.expectEqual(S_OK, options(first.nodes[0].face(.simple), &flags));
    try std.testing.expectEqual(S_OK, options(second.nodes[0].face(.simple), &flags));
    try std.testing.expect(publisher.accepts(action));
    var wrong = action;
    wrong.kind = .invoke;
    try std.testing.expect(!publisher.accepts(wrong));
    wrong = action;
    wrong.node_id = 2;
    try std.testing.expect(!publisher.accepts(wrong));

    publisher.hide();
    try std.testing.expectEqual(UNAVAILABLE, options(first.nodes[0].face(.simple), &flags));
    try std.testing.expectEqual(UNAVAILABLE, options(second.nodes[0].face(.simple), &flags));
    try std.testing.expect(!publisher.accepts(action));
    // Showing the same HWND and attachment again starts a fresh lifetime; it
    // must never revive an old provider or accept an already-queued old action.
    try publisher.publishStableWithId(alloc, &api, &queue, attachment, @ptrFromInt(1), 12, &.{.{ .id = 1, .name = "reopened", .focusable = true }});
    const reopened = publisher.current.?;
    reopened.retain();
    defer reopened.release();
    try std.testing.expect(reopened.view.?.id != action.view_id);
    try std.testing.expect(!publisher.accepts(action));
    try std.testing.expectEqual(UNAVAILABLE, options(first.nodes[0].face(.simple), &flags));
    var moved = attachment;
    moved.revision += 1;
    try publisher.publishStableWithId(alloc, &api, &queue, moved, @ptrFromInt(1), 13, &.{.{ .id = 1, .name = "moved", .focusable = true }});
    try std.testing.expectEqual(UNAVAILABLE, options(reopened.nodes[0].face(.simple), &flags));
    try std.testing.expectEqual(S_OK, options(publisher.current.?.nodes[0].face(.simple), &flags));
}

test "UIA stable view keeps immutable content readable then revokes every old provider" {
    try stableViewExercise(std.testing.allocator);
}

test "UIA stable view allocation failures release snapshots and lifetime tokens" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stableViewExercise, .{});
}

test "UIA custom caption root alone refuses synthetic nonclient support" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const api = try Api.load(alloc);
    defer api.release();
    const queue = try Queue.create(alloc, @ptrFromInt(1));
    defer queue.release();
    var publisher: Publisher = .{};
    defer publisher.deinit();
    for ([_]bool{ false, true }) |custom_caption| {
        try publisher.publish(alloc, api, queue, testAttachment(), @ptrFromInt(1), &.{
            .{ .id = 1, .name = "Window", .refuse_nonclient = custom_caption, .patterns = .{ .window = true } },
            .{ .id = 2, .parent = 0, .name = "Close", .refuse_nonclient = true, .patterns = .{ .invoke = true } },
        });
        const nodes = publisher.current.?.nodes;
        var root_flags: u32 = 0;
        var child_flags: u32 = 0;
        try std.testing.expectEqual(S_OK, simple_table.ProviderOptions(nodes[0].face(.simple), &root_flags));
        try std.testing.expectEqual(S_OK, simple_table.ProviderOptions(nodes[1].face(.simple), &child_flags));
        try std.testing.expectEqual(@as(u32, if (custom_caption) 0x52 else 0x12), root_flags);
        try std.testing.expectEqual(@as(u32, 0x12), child_flags);
    }
}

test "UIA announcement survives full queue and republication without duplicate delivery" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const api = try Api.load(alloc);
    defer api.release();
    const queue = try Queue.create(alloc, @ptrFromInt(1));
    defer queue.release();
    var publisher: Publisher = .{};
    defer publisher.deinit();
    const nodes = &.{NodeSpec{ .id = 1, .name = "Toast", .patterns = .{ .window = true } }};
    try publisher.publish(alloc, api, queue, testAttachment(), @ptrFromInt(1), nodes);
    for (0..queue.items.len) |_| try std.testing.expectEqual(S_OK, queue.postWith(publisher.current.?, 1, .focus, "", 0, testPost));
    var announcement: PendingAnnouncement = .{};
    var text = [_]u8{ 'O', 'K' };
    announcement.stage(&text);
    text[0] = 'X';
    announcement.retryWith(&publisher, testPost);
    try std.testing.expect(announcement.pending and announcement.queued_snapshot_id == null);
    while (queue.pop()) |item| {
        var action = item;
        action.deinit();
    }
    announcement.retryWith(&publisher, testPost);
    announcement.retryWith(&publisher, testPost);
    try std.testing.expectEqual(@as(usize, 1), queue.length);
    var stale = queue.pop().?;
    defer stale.deinit();
    try std.testing.expectEqualStrings("OK", stale.value);
    try publisher.publish(alloc, api, queue, testAttachment(), @ptrFromInt(1), nodes);
    announcement.retryWith(&publisher, testPost);
    try std.testing.expect(!announcement.consume(&stale));
    var current = queue.pop().?;
    defer current.deinit();
    try std.testing.expect(publisher.accepts(current));
    try std.testing.expect(announcement.consume(&current));
    try std.testing.expect(!announcement.consume(&current));
    announcement.retryWith(&publisher, testPost);
    try std.testing.expect(queue.pop() == null);
    announcement.stage("Replacement");
    announcement.retryWith(&publisher, testPost);
    announcement.cancel();
    var cancelled = queue.pop().?;
    defer cancelled.deinit();
    try std.testing.expect(!announcement.consume(&cancelled));
}

test "UIA a focus move updates HasKeyboardFocus and GetFocus in place and queues one event" {
    const alloc = std.testing.allocator;
    const Recorder = struct {
        var raised: usize = 0;
        var face: ?*Face = null;
        var event: i32 = 0;
        fn raise(target: *Face, id: i32) callconv(.winapi) HR {
            raised += 1;
            face = target;
            event = id;
            return S_OK;
        }
        fn hasFocus(target: *Face) !bool {
            var value: Variant = .{};
            try std.testing.expectEqual(S_OK, property(target, 30008, &value));
            try std.testing.expectEqual(@as(u16, 11), value.tag);
            return value.data.integer != 0;
        }
        fn focusOf(root: *Face) !?*Node {
            var out: ?*Face = null;
            try std.testing.expectEqual(S_OK, getFocus(root, &out));
            const focused = out orelse return null;
            defer _ = releaseFace(focused);
            return focused.node;
        }
    };
    Recorder.raised = 0;
    var api: Api = undefined;
    api.count = .init(1);
    api.notification = null;
    api.event = Recorder.raise;
    const queue = try Queue.create(alloc, @ptrFromInt(1));
    defer queue.release();
    var publisher: Publisher = .{};
    defer publisher.deinit();
    try publisher.publish(alloc, &api, queue, testAttachment(), @ptrFromInt(1), &.{
        .{ .id = 1, .name = "Dialog", .patterns = .{ .window = true } },
        .{ .id = 2, .parent = 0, .name = "A", .focusable = true, .focused = true },
        .{ .id = 3, .parent = 0, .name = "B", .focusable = true },
    });
    const snapshot = publisher.current.?;
    const root = snapshot.nodes[0].face(.root);
    const a = snapshot.nodes[1].face(.simple);
    const b = snapshot.nodes[2].face(.simple);
    try std.testing.expect(try Recorder.hasFocus(a));
    try std.testing.expect(!try Recorder.hasFocus(b));
    try std.testing.expectEqual(@as(?*Node, &snapshot.nodes[1]), try Recorder.focusOf(root));

    try std.testing.expect(publisher.moveFocusWith(3, testPost));
    try std.testing.expect(!try Recorder.hasFocus(a));
    try std.testing.expect(try Recorder.hasFocus(b));
    try std.testing.expectEqual(@as(?*Node, &snapshot.nodes[2]), try Recorder.focusOf(root));
    // Same identity: every element stays valid and actions on it are accepted.
    try std.testing.expectEqual(snapshot, publisher.current.?);
    var flags: u32 = 0;
    try std.testing.expectEqual(S_OK, options(a, &flags));
    try std.testing.expectEqual(S_OK, options(b, &flags));
    try std.testing.expectEqual(@as(usize, 1), queue.length);
    var queued = queue.pop().?;
    defer queued.deinit();
    try std.testing.expectEqual(ActionKind.focus_changed, queued.kind);
    try std.testing.expectEqual(@as(u64, 3), queued.node_id);
    try std.testing.expect(publisher.accepts(queued));
    // No second event for the same node; no move to a node it does not have.
    try std.testing.expect(publisher.moveFocusWith(3, testPost));
    try std.testing.expect(!publisher.moveFocusWith(9, testPost));
    try std.testing.expectEqual(@as(usize, 0), queue.length);
    try std.testing.expect(try Recorder.hasFocus(b));
    // The loop raises it while the node still has the focus.
    try std.testing.expect(publisher.raiseFocusChanged(3));
    try std.testing.expectEqual(@as(usize, 1), Recorder.raised);
    try std.testing.expectEqual(@as(?*Face, b), Recorder.face);
    try std.testing.expectEqual(focus_changed_event, Recorder.event);
    // An event the focus has already moved on from raises nothing.
    try std.testing.expect(publisher.moveFocusWith(2, testPost));
    var back = queue.pop().?;
    defer back.deinit();
    try std.testing.expectEqual(@as(u64, 2), back.node_id);
    try std.testing.expect(!publisher.raiseFocusChanged(3));
    try std.testing.expectEqual(@as(usize, 1), Recorder.raised);
    // Away from every node: nothing queued, nothing reports the focus.
    try std.testing.expect(publisher.moveFocusWith(0, testPost));
    try std.testing.expectEqual(@as(usize, 0), queue.length);
    try std.testing.expect(!publisher.raiseFocusChanged(2));
    try std.testing.expect(!try Recorder.hasFocus(a));
    try std.testing.expect(!try Recorder.hasFocus(b));
    try std.testing.expectEqual(@as(?*Node, null), try Recorder.focusOf(root));
    // A hidden snapshot moves nothing.
    publisher.hide();
    try std.testing.expect(!publisher.moveFocusWith(2, testPost));
}

test "UIA only a focus difference matches a published snapshot" {
    const alloc = std.testing.allocator;
    var api: Api = undefined;
    api.count = .init(1);
    const queue = try Queue.create(alloc, @ptrFromInt(1));
    defer queue.release();
    var publisher: Publisher = .{};
    defer publisher.deinit();
    const attachment = testAttachment();
    const hwnd: w32.HWND = @ptrFromInt(1);
    var name = [_]u8{ 'O', 'K' };
    const specs = [_]NodeSpec{
        .{ .id = 1, .name = "Dialog", .patterns = .{ .window = true } },
        .{ .id = 2, .parent = 0, .name = &name, .role = .button, .patterns = .{ .invoke = true }, .focusable = true, .focused = true },
    };
    try publisher.publish(alloc, &api, queue, attachment, hwnd, &specs);
    // Another focus, and equal strings in other memory, still match.
    var moved = specs;
    moved[0].focused = true;
    moved[1].focused = false;
    var copy = [_]u8{ 'O', 'K' };
    moved[1].name = &copy;
    try std.testing.expect(publisher.matchesExceptFocus(attachment, hwnd, &moved));
    // Anything else is a model change.
    var renamed = moved;
    renamed[1].name = "Cancel";
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, hwnd, &renamed));
    var disabled = moved;
    disabled[1].enabled = false;
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, hwnd, &disabled));
    var resized = moved;
    resized[1].bounds.width = 1;
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, hwnd, &resized));
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, hwnd, moved[0..1]));
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, @ptrFromInt(2), &moved));
    var reopened = attachment;
    reopened.revision += 1;
    try std.testing.expect(!publisher.matchesExceptFocus(reopened, hwnd, &moved));
    // A stable view reports the focus of each content revision instead.
    try publisher.publishStableWithId(alloc, &api, queue, attachment, hwnd, 99, &specs);
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, hwnd, &moved));
    try std.testing.expect(!publisher.moveFocusWith(1, testPost));
    publisher.hide();
    try std.testing.expect(!publisher.matchesExceptFocus(attachment, hwnd, &specs));
}
