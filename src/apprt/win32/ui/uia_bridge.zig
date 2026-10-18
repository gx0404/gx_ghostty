//! GUI-side UIA snapshots and typed bindings. No terminal state or renderer
//! locks are read here; native providers never retain these GUI objects.
const std = @import("std");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const Pane = @import("../Pane.zig");
const w32 = @import("../win32.zig");
const uia = @import("uia.zig");
const refs = @import("../../../gx/ui_ref.zig");
const i18n = @import("../../../gx/i18n.zig");
const d2d = @import("d2d.zig");
const Palette = @import("Palette.zig");
const Toast = @import("Toast.zig");
const settings_map = @import("../../../gx/settings_map.zig");
const sw_minimize: i32 = 6;

const Binding = union(enum) {
    none,
    window,
    new_tab,
    main_menu,
    profiles,
    minimize,
    maximize,
    close_window,
    select_tab: refs.Reference,
    close_tab: refs.Reference,
};

const Builder = struct {
    specs: [uia.max_nodes]uia.NodeSpec = undefined,
    bindings: [uia.max_nodes]Binding = undefined,
    length: usize = 0,
    fn add(self: *Builder, spec: uia.NodeSpec, binding: Binding) !u16 {
        if (self.length == self.specs.len) return error.TooManyNodes;
        const index = self.length;
        self.specs[index] = spec;
        self.specs[index].id = index + 1;
        self.bindings[index] = binding;
        self.length += 1;
        return @intCast(index);
    }
};

/// Embed in Window. hide before detaching/revoking the Window view, and deinit
/// before freeing it. Rebuild after GUI model or geometry changes, not in MTA.
pub const WindowBridge = struct {
    publisher: uia.Publisher = .{},
    bindings: [uia.max_nodes]Binding = @splat(.none),
    length: usize = 0,
    needs_publish: bool = true,

    pub fn hide(self: *WindowBridge) void {
        self.publisher.hide();
        self.length = 0;
        self.needs_publish = true;
    }
    pub fn dirty(self: *WindowBridge) void {
        self.hide();
    }
    pub fn deinit(self: *WindowBridge) void {
        self.hide();
    }

    pub fn publish(self: *WindowBridge, window: *Window, api: *uia.Api, queue: *uia.Queue) !void {
        errdefer self.hide();
        if (window.closing or !window.ui_attachment.isValid()) return self.hide();
        if (!self.needs_publish and self.publisher.current != null) return;
        const hwnd = window.hwnd orelse return self.hide();
        if (w32.IsWindowVisible_(hwnd) == 0) return self.hide();
        var bounds: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &bounds) == 0) return error.InvalidWindow;
        var origin: w32.POINT = .{ .x = 0, .y = 0 };
        if (w32.ClientToScreen(hwnd, &origin) == 0) return error.InvalidWindow;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var builder: Builder = .{};
        const title = if (window.window_title_override_len) |len|
            try std.unicode.utf16LeToUtf8Alloc(alloc, window.window_title_override[0..len])
        else if (window.tab_count > 0)
            try std.unicode.utf16LeToUtf8Alloc(alloc, window.tab_titles[window.active_tab][0..window.tab_title_lens[window.active_tab]])
        else
            i18n.tr("Terminal");
        const minimized = w32.IsIconic(hwnd) != 0;
        const maximized = w32.IsZoomed(hwnd) != 0;
        const enabled = w32.IsWindowEnabled(hwnd) != 0;
        const layout = window.title_bar.layout();
        _ = try builder.add(.{ .id = 0, .name = title, .role = .window, .bounds = screenRect(bounds), .patterns = .{ .window = true }, .enabled = enabled, .window_interaction_state = if (enabled) 2 else 3, .focusable = true, .focused = w32.GetFocus() == hwnd, .offscreen = minimized, .window_state = if (minimized) 2 else if (maximized) 1 else 0, .can_maximize = !window.is_quick_terminal, .can_minimize = !window.is_quick_terminal, .topmost = isTopmost(hwnd) }, .window);
        builder.specs[0].refuse_nonclient = layout.caption and !window.title_bar.nativeButtons();
        if (layout.height() > 0) {
            if (layout.menu.right > layout.menu.left) {
                _ = try button(&builder, 0, i18n.tr("Main Menu"), clientRect(layout.menu, origin), .main_menu);
            }
            // DWM/native buttons already have their own provider. Never expose
            // duplicates of controls that this application does not draw.
            if (layout.caption and !window.title_bar.nativeButtons()) {
                _ = try button(&builder, 0, i18n.tr("Minimize"), clientRect(layout.minimize, origin), .minimize);
                _ = try button(&builder, 0, if (maximized) i18n.tr("Restore") else i18n.tr("Maximize"), clientRect(layout.maximize, origin), .maximize);
                _ = try button(&builder, 0, i18n.tr("Close Window"), clientRect(layout.close, origin), .close_window);
            }
        }
        if (window.tab_bar.visible and window.tab_count > 0) {
            const geometry = window.tab_bar.geometry(layout);
            const tab_container = try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Tabs"), .role = .tab, .bounds = clientRect(layout.tabs, origin), .patterns = .{ .selection = true }, .selection_required = true }, .none);
            for (0..window.tab_count) |index| {
                var label_buffer: [4096]u8 = undefined;
                const label = window.tab_bar.labelText(index, &label_buffer) orelse i18n.tr("Terminal");
                const tab_rect = window.tab_bar.tabRect(index);
                const tab = try builder.add(.{ .id = 0, .parent = tab_container, .name = try alloc.dupe(u8, label), .role = .tab_item, .bounds = clientRect(tab_rect, origin), .offscreen = tab_rect.right <= tab_rect.left, .patterns = .{ .selection_item = true }, .selected = index == window.active_tab }, .{ .select_tab = window.tab_references[index] });
                const close = window.tab_bar.closeRect(layout, index);
                if (close.right > close.left and tab_rect.right > tab_rect.left) {
                    _ = try button(&builder, tab, i18n.tr("Close Tab"), clientRect(close, origin), .{ .close_tab = window.tab_references[index] });
                }
            }
            if (!geometry.new_tab.isEmpty()) {
                _ = try button(&builder, 0, i18n.tr("New Tab"), clientRect(.{ .left = geometry.new_tab.left, .top = geometry.new_tab.top, .right = geometry.new_tab.right, .bottom = geometry.new_tab.bottom }, origin), .new_tab);
            }
            if (!geometry.profiles.isEmpty()) {
                _ = try button(&builder, 0, i18n.tr("Launch Profiles"), clientRect(.{ .left = geometry.profiles.left, .top = geometry.profiles.top, .right = geometry.profiles.right, .bottom = geometry.profiles.bottom }, origin), .profiles);
            }
        }
        // No node for a terminal pane: its own HWND is its element
        // (`terminalRoot`), which UIA places under this window's element.
        for (builder.specs[1..builder.length]) |*spec| {
            if (!enabled) spec.enabled = false;
            if (minimized) spec.offscreen = true;
        }
        try self.publisher.publish(std.heap.page_allocator, api, queue, window.ui_attachment, hwnd, builder.specs[0..builder.length]);
        @memcpy(self.bindings[0..builder.length], builder.bindings[0..builder.length]);
        self.length = builder.length;
        self.needs_publish = false;
    }

    /// GUI thread only. All native operations use newly resolved records and
    /// no widget pointer is accessed after a potentially reentrant action.
    pub fn dispatch(self: *const WindowBridge, app: *App, action: *const uia.Action) bool {
        if (!self.publisher.accepts(action.*) or action.node_id == 0 or action.node_id > self.length) return false;
        const binding = self.bindings[@intCast(action.node_id - 1)];
        const window = app.resolveWindowView(action.attachment) orelse return false;
        if (window.closing) return false;
        const hwnd = window.hwnd orelse return false;
        if (w32.IsWindowEnabled(hwnd) == 0) return false;
        const reference = window.ui_reference;
        switch (binding) {
            .none => return false,
            .window => switch (action.kind) {
                .focus => window.focusActiveSurface(),
                .close => window.requestClose(),
                .set_window_state => {
                    const mode: i32 = switch (action.window_state) {
                        0 => w32.SW_RESTORE,
                        1 => w32.SW_MAXIMIZE,
                        2 => sw_minimize,
                        else => return false,
                    };
                    _ = w32.ShowWindow(hwnd, mode);
                },
                else => return false,
            },
            .select_tab => |tab| {
                if (action.kind != .select) return false;
                const index = window.resolveTab(tab) orelse return false;
                window.selectTabIndex(index);
            },
            .close_tab => |tab| {
                if (action.kind != .invoke) return false;
                const index = window.resolveTab(tab) orelse return false;
                window.closeTabByIndex(index);
            },
            else => {
                if (action.kind != .invoke) return false;
                switch (binding) {
                    .new_tab => {
                        _ = window.addTab() catch return false;
                        if (app.resolveWindow(reference)) |current| current.focusActiveSurface();
                    },
                    .main_menu => return window.queueMainMenu(null),
                    .profiles => return app.performGx(window, .new_tab_menu),
                    .minimize => {
                        _ = w32.ShowWindow(hwnd, sw_minimize);
                    },
                    .maximize => window.toggleMaximize(),
                    .close_window => window.requestClose(),
                    else => unreachable,
                }
            },
        }
        return true;
    }
};

/// The UIA element of a terminal pane (D-29): the root of its own HWND's
/// provider, a local Surface's GhosttyTerminal or a RemotePane window. That
/// HWND takes the system focus, so this is the element screen readers
/// announce: named after the terminal, its type localized, its focus and
/// rectangle those of the window itself (`host_state`). A Window fragment
/// never repeats it: UIA places child HWNDs under their window's element.
pub fn terminalRoot(title: []const u8, reference: refs.Reference, automation_id: *[48]u8) uia.NodeSpec {
    return .{
        .id = 1,
        .name = if (title.len > 0) title else i18n.tr("Terminal"),
        .role = .pane,
        .localized_type = i18n.tr("Terminal"),
        // Unique among sibling panes for the whole life of the terminal.
        .automation_id = std.fmt.bufPrint(automation_id, "gx-terminal-{d}", .{reference.generation}) catch unreachable,
        .focusable = true,
        .host_state = true,
    };
}

/// Whether `hwnd` has the system keyboard focus: its thread's focus, with
/// its top-level window in the foreground. A terminal's focus event is only
/// raised then (`Publisher.raiseHostFocus`): an event of a background window
/// would pull a screen reader away from the user's app.
pub fn systemFocus(hwnd: w32.HWND) bool {
    if (w32.GetFocus() != hwnd) return false;
    const top = w32.GetAncestor(hwnd, ga_root) orelse return false;
    return w32.GetForegroundWindow() == top;
}
const ga_root: u32 = 2;

/// One terminal HWND's provider (`terminalRoot`). A new title or language
/// refreshes it without revoking the elements clients hold; a new attachment
/// (the pane moved to another window) or `hide` revokes them.
pub const TerminalBridge = struct {
    publisher: uia.Publisher = .{},
    attachment: ?refs.Attachment = null,
    content_hash: ?u64 = null,

    pub fn hide(self: *TerminalBridge) void {
        self.publisher.hide();
        self.attachment = null;
        self.content_hash = null;
    }
    /// GUI thread, for a WM_GETOBJECT of `hwnd`, the pane's own window.
    pub fn publish(self: *TerminalBridge, api: *uia.Api, queue: *uia.Queue, pane: Pane, hwnd: w32.HWND) !void {
        errdefer self.hide();
        const state = pane.snapshot();
        if (!state.attachment.isValid()) return self.hide();
        if (self.attachment) |old| if (!old.matches(state.attachment)) self.hide();
        var id_buffer: [48]u8 = undefined;
        const root = terminalRoot(state.title.slice(), state.reference, &id_buffer);
        var signature = std.hash.Wyhash.init(0);
        for ([_][]const u8{ root.name, root.localized_type, root.automation_id }) |text| {
            signature.update(text);
            signature.update(&.{0});
        }
        const content_hash = signature.final();
        if (self.publisher.current != null and self.content_hash == content_hash) return;
        try self.publisher.publishStable(std.heap.page_allocator, api, queue, state.attachment, hwnd, &.{root});
        self.attachment = state.attachment;
        self.content_hash = content_hash;
    }
};

/// GUI-thread registry of the local terminal HWNDs UIA asked for (a
/// RemotePane keeps its own, `uia_remote.Bridge`). An entry lives until its
/// HWND is destroyed (`forget`) or the App's teardown (`deinit`).
pub const TerminalRegistry = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Whether a terminal window still has the focus when its queued focus
    /// event is raised (`systemFocus`). Tests, which own no foreground
    /// window, substitute their thread's focus.
    has_focus: *const fn (w32.HWND) bool = &systemFocus,
    const Entry = struct { hwnd: w32.HWND, bridge: TerminalBridge = .{} };

    /// WM_GETOBJECT of the pane's own HWND: its provider, or 0 to let
    /// Windows answer (another object ID, or no provider).
    pub fn getObject(self: *TerminalRegistry, api: *uia.Api, queue: *uia.Queue, pane: Pane, wparam: usize, lparam: isize) isize {
        if (w32.objectId(lparam) != uia.root_object_id) return 0;
        const hwnd = pane.nativeHandle() orelse return 0;
        const item = self.entry(hwnd) catch return 0;
        item.bridge.publish(api, queue, pane, hwnd) catch |err| {
            std.log.scoped(.win32_uia).warn("terminal UIA snapshot unavailable err={}", .{err});
            return 0;
        };
        return item.bridge.publisher.returnProvider(wparam, lparam);
    }
    fn entry(self: *TerminalRegistry, hwnd: w32.HWND) !*Entry {
        for (self.entries.items) |*item| if (item.hwnd == hwnd) return item;
        try self.entries.append(std.heap.page_allocator, .{ .hwnd = hwnd });
        return &self.entries.items[self.entries.items.len - 1];
    }
    /// WM_SETFOCUS of the pane's own HWND while UIA clients listen: make sure
    /// it has a current provider and queue its root's focus changed event.
    /// UIA makes none of the window's EVENT_OBJECT_FOCUS for a provider-backed
    /// HWND, so without it a screen reader stays silent when a pane gets the
    /// focus. `dispatch` raises it from the App message loop.
    pub fn focused(self: *TerminalRegistry, api: *uia.Api, queue: *uia.Queue, pane: Pane) void {
        const hwnd = pane.nativeHandle() orelse return;
        const item = self.entry(hwnd) catch return;
        item.bridge.publish(api, queue, pane, hwnd) catch return;
        _ = item.bridge.publisher.queueHostFocus();
    }
    /// WM_DESTROY of a terminal HWND: what UIA clients hold becomes inert.
    pub fn forget(self: *TerminalRegistry, hwnd: w32.HWND) void {
        for (self.entries.items, 0..) |*item, index| if (item.hwnd == hwnd) {
            item.bridge.hide();
            _ = self.entries.swapRemove(index);
            break;
        };
        if (self.entries.items.len == 0) self.deinit();
    }
    /// The two actions `accepts` leaves a stable view: the root's own focus
    /// event (`focused`), raised while its window keeps the focus, and a
    /// client's SetFocus on a terminal root, applied while it is still that
    /// visible pane. Nothing of the registry is read once either may reenter.
    pub fn dispatch(self: *const TerminalRegistry, app: *App, action: *const uia.Action) bool {
        for (self.entries.items) |*item| {
            if (!item.bridge.publisher.accepts(action.*)) continue;
            if (action.kind == .focus_changed) {
                _ = item.bridge.publisher.raiseHostFocus(self.has_focus);
                return true;
            }
            const hwnd = item.hwnd;
            const pane = app.resolvePaneView(action.attachment) orelse return false;
            const target = pane.nativeHandle() orelse return false;
            if (target != hwnd or w32.IsWindowVisible_(hwnd) == 0 or w32.IsWindowEnabled(hwnd) == 0) return false;
            _ = w32.SetFocus(hwnd);
            return w32.GetFocus() == hwnd;
        }
        return false;
    }
    pub fn deinit(self: *TerminalRegistry) void {
        for (self.entries.items) |*item| item.bridge.hide();
        self.entries.deinit(std.heap.page_allocator);
        self.entries = .empty;
    }
};

fn button(builder: *Builder, parent: u16, name: []const u8, bounds: uia.Rect, binding: Binding) !u16 {
    return builder.add(.{ .id = 0, .parent = parent, .name = name, .role = .button, .bounds = bounds, .patterns = .{ .invoke = true }, .offscreen = bounds.width <= 0 or bounds.height <= 0 }, binding);
}
fn screenRect(rect: w32.RECT) uia.Rect {
    return .{ .x = @floatFromInt(rect.left), .y = @floatFromInt(rect.top), .width = @floatFromInt(@max(0, rect.right - rect.left)), .height = @floatFromInt(@max(0, rect.bottom - rect.top)) };
}
fn clientRect(rect: w32.RECT, origin: w32.POINT) uia.Rect {
    var result = screenRect(rect);
    result.x += @as(f64, @floatFromInt(origin.x));
    result.y += @as(f64, @floatFromInt(origin.y));
    return result;
}

test "UIA bridge translates client pixels and keeps offscreen rectangles empty" {
    const result = clientRect(.{ .left = 10, .top = 20, .right = 30, .bottom = 50 }, .{ .x = -200, .y = 100 });
    try std.testing.expectEqual(uia.Rect{ .x = -190, .y = 120, .width = 20, .height = 30 }, result);
    try std.testing.expectEqual(@as(f64, 0), screenRect(.{ .left = 20, .top = 0, .right = 10, .bottom = 0 }).width);
}

test "terminal provider keeps held elements across a title change and revokes them on a move" {
    // The real TerminalBridge over a real local pane adapter. No HWND,
    // desktop or UIAutomationCore is used: providers are called directly.
    const testing = std.testing;
    const Surface = @import("../Surface.zig");
    var api: uia.Api = undefined;
    api.count = .init(1);
    api.event = null;
    api.notification = null;
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const Simple = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
        GetPatternProvider: *const fn (*uia.Face, i32, *?*uia.Face) callconv(.winapi) i32,
        GetPropertyValue: *const fn (*uia.Face, i32, *uia.Variant) callconv(.winapi) i32,
    };
    const Probe = struct {
        extern "oleaut32" fn SysFreeString(?[*:0]u16) callconv(.winapi) void;
        fn table(face: *uia.Face) *const Simple {
            return @ptrCast(@alignCast(face.vtable));
        }
        /// ProviderOptions: S_OK while usable, UIA_E_ELEMENTNOTAVAILABLE once revoked.
        fn options(face: *uia.Face) i32 {
            var flags: u32 = 0;
            return table(face).ProviderOptions(face, &flags);
        }
        fn name(face: *uia.Face, buffer: []u8) ![]const u8 {
            var value: uia.Variant = .{};
            try testing.expectEqual(@as(i32, 0), table(face).GetPropertyValue(face, 30005, &value));
            const text: [*:0]u16 = @ptrCast(@alignCast(value.data.pointer.?));
            defer SysFreeString(text);
            return buffer[0..try std.unicode.utf16LeToUtf8(buffer, std.mem.span(text))];
        }
        fn setTitle(surface: *Surface, title: []const u8) void {
            @memcpy(surface.title[0..title.len], title);
            surface.title[title.len] = 0;
            surface.title_len = title.len;
        }
    };
    var issuer = try refs.Issuer.init(7);
    const first_window = try issuer.create(.window);
    const second_window = try issuer.create(.window);
    var surface: Surface = .{ .app = undefined, .parent_window = undefined, .ui_reference = try issuer.surface(5) };
    surface.ui_attachment = try issuer.attach(surface.ui_reference, first_window);
    Probe.setTitle(&surface, "first");
    const hwnd: w32.HWND = @ptrFromInt(0x40);
    var bridge: TerminalBridge = .{};
    defer bridge.hide();
    var buffer: [64]u8 = undefined;
    try bridge.publish(&api, &queue, Pane.fromLocal(&surface), hwnd);
    const first = bridge.publisher.current.?;
    const held = &first.nodes[0].faces[0];
    _ = Probe.table(held).AddRef(held);
    defer _ = Probe.table(held).Release(held);
    try testing.expectEqualStrings("first", try Probe.name(held, &buffer));
    // Nothing new: the very same snapshot.
    try bridge.publish(&api, &queue, Pane.fromLocal(&surface), hwnd);
    try testing.expect(bridge.publisher.current.? == first);
    // A new title is a new revision; the element held still answers.
    Probe.setTitle(&surface, "second");
    try bridge.publish(&api, &queue, Pane.fromLocal(&surface), hwnd);
    const second = bridge.publisher.current.?;
    try testing.expect(second != first);
    try testing.expectEqualStrings("second", try Probe.name(&second.nodes[0].faces[0], &buffer));
    try testing.expectEqual(@as(i32, 0), Probe.options(held));
    // Moved to another window: the new attachment revokes every revision.
    surface.ui_attachment = try issuer.attach(surface.ui_reference, second_window);
    try bridge.publish(&api, &queue, Pane.fromLocal(&surface), hwnd);
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), Probe.options(held));
    try testing.expectEqual(@as(i32, 0), Probe.options(&bridge.publisher.current.?.nodes[0].faces[0]));
}

pub const PopupCallbacks = struct {
    context: *anyopaque,
    /// GUI only; registration is removed before the context is freed.
    is_live: *const fn (*anyopaque) bool,
    /// GUI only. The bridge pre-revokes the snapshot for every action except
    /// focus. A callback whose action (focus included) changes the model or
    /// layout must call `Popup.invalidate()` itself; a purely visual change
    /// uses `Popup.repaint()` and keeps the retained providers usable.
    action: *const fn (*anyopaque, u64, *const uia.Action) bool,
};

/// GUI registry. A popup owner unregisters before freeing its address-stable
/// bridge/context. Snapshot COM references retain neither of those pointers.
pub const Registry = struct {
    entries: [64]?*PopupBridge = @splat(null),
    pub fn register(self: *Registry, bridge: *PopupBridge) !void {
        for (self.entries) |entry| if (entry == bridge) return;
        for (&self.entries) |*entry| if (entry.* == null) {
            entry.* = bridge;
            return;
        };
        return error.TooManyPopups;
    }
    pub fn unregister(self: *Registry, bridge: *PopupBridge) void {
        for (&self.entries) |*entry| if (entry.* == bridge) {
            entry.* = null;
        };
        bridge.hide();
    }
    pub fn deinit(self: *Registry) void {
        for (&self.entries) |*entry| {
            if (entry.*) |bridge| bridge.hide();
            entry.* = null;
        }
    }
    pub fn dispatch(self: *Registry, app: *App, action: *const uia.Action) bool {
        for (self.entries) |entry| if (entry) |bridge| {
            if (!bridge.publisher.accepts(action.*)) continue;
            return bridge.dispatch(app, action);
        };
        return false;
    }
    pub fn retryAnnouncements(self: *Registry) void {
        for (self.entries) |entry| if (entry) |bridge| {
            bridge.announcement.retry(&bridge.publisher);
        };
    }
};

pub const PopupBridge = struct {
    publisher: uia.Publisher = .{},
    callbacks: ?PopupCallbacks = null,
    tokens: [uia.max_nodes]u64 = @splat(0),
    length: usize = 0,
    hwnd: ?w32.HWND = null,
    needs_publish: bool = true,
    announcement: uia.PendingAnnouncement = .{},
    /// Set while the owning popup rebuilds its specs only to report where
    /// the keyboard focus is now (`Popup.focusMoved`): `publish` moves the
    /// focus within the current snapshot instead of replacing it.
    focus_only: bool = false,
    /// Stable identity of each node of the current snapshot, parallel to
    /// `tokens`: the token itself unless the widget's tokens are positions
    /// (`publishKeyed`; Settings keys its hits by target).
    keys: [uia.max_nodes]u64 = @splat(0),
    /// Identity of the element the current snapshot gives the focus (null:
    /// none, or no snapshot).
    focus_key: ?u64 = null,
    /// Identity whose focus changed event was last raised while it had the
    /// focus. Null since the popup was shown, and whenever the focus left
    /// every element: the next element to get the focus is reported.
    focus_reported: ?u64 = null,
    /// What the last publication selected in each selection container
    /// (`trackSelection`). Null since the popup was shown: its first
    /// publication only records what it shows.
    selection: ?Selection = null,

    /// A GUI model edit invalidates all pending index-based actions immediately.
    /// The owning widget schedules publish after its new model/layout is ready.
    /// What the focus was last reported on survives, so a republication that
    /// keeps the focus where it was raises no second event.
    pub fn dirty(self: *PopupBridge) void {
        self.publisher.hide();
        self.length = 0;
        self.needs_publish = true;
        self.focus_key = null;
    }
    pub fn hide(self: *PopupBridge) void {
        self.dirty();
        self.announcement.cancel();
        self.callbacks = null;
        self.hwnd = null;
        self.focus_reported = null;
        self.selection = null;
    }
    pub fn deinit(self: *PopupBridge) void {
        self.hide();
    }
    /// Nothing to publish: no model change since the last publication, and
    /// not a focus-only rebuild (`focus_only`).
    fn upToDate(self: *const PopupBridge) bool {
        return !self.focus_only and !self.needs_publish and self.publisher.current != null;
    }
    pub fn publish(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, hwnd: w32.HWND, nodes: []const uia.NodeSpec, tokens: []const u64, callbacks: PopupCallbacks) !void {
        return self.publishKeyed(api, queue, attachment, hwnd, nodes, tokens, tokens, callbacks);
    }
    /// `publish` with each node's stable identity in `keys` (parallel to
    /// `tokens`) for widgets whose tokens are positions. A new snapshot that
    /// gives the focus to an element other than the one last reported, or
    /// to any element right after the popup was shown, queues its focus
    /// changed event for the App message loop once published.
    pub fn publishKeyed(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, hwnd: w32.HWND, nodes: []const uia.NodeSpec, tokens: []const u64, keys: []const u64, callbacks: PopupCallbacks) !void {
        errdefer self.hide();
        if (!callbacks.is_live(callbacks.context) or !attachment.isValid()) return self.hide();
        if (nodes.len != tokens.len or keys.len != tokens.len or nodes.len > self.tokens.len) return error.InvalidSnapshot;
        if (!self.focus_only and !self.needs_publish and self.hwnd == hwnd and self.publisher.current != null) return;
        var effective: [uia.max_nodes]uia.NodeSpec = undefined;
        @memcpy(effective[0..nodes.len], nodes);
        if (w32.IsWindowEnabled(hwnd) == 0) for (effective[0..nodes.len]) |*node| {
            node.enabled = false;
            if (node.patterns.window) node.window_interaction_state = 3;
        };
        if (self.focus_only) return self.moveFocusTo(attachment, hwnd, effective[0..nodes.len], tokens, keys, callbacks);
        try self.publisher.publish(std.heap.page_allocator, api, queue, attachment, hwnd, effective[0..nodes.len]);
        @memcpy(self.tokens[0..tokens.len], tokens);
        @memcpy(self.keys[0..keys.len], keys);
        self.length = tokens.len;
        self.hwnd = hwnd;
        self.callbacks = callbacks;
        self.needs_publish = false;
        self.announcement.retry(&self.publisher);
        self.trackFocus(focusedKey(nodes, keys), true);
        self.trackSelection(nodes, keys);
    }
    /// A publication that moves the selection of a container the previous
    /// one already showed (the keyboard in a palette's results, a radio
    /// choice, a settings section) queues ElementSelected for the newly
    /// selected element, at most `max_selection_events` per publication.
    /// A container that just appeared only records its selection: its
    /// appearance is no selection change.
    fn trackSelection(self: *PopupBridge, nodes: []const uia.NodeSpec, keys: []const u64) void {
        var current: Selection = .{};
        var queued: usize = 0;
        for (nodes, keys) |node, key| {
            if (!node.patterns.selection_item or !node.selected or current.count == Selection.slots) continue;
            const container = selectionContainer(nodes, node) orelse continue;
            const pair: Selection.Pair = .{ .container = identity(keys[container], nodes[container]), .item = identity(key, node) };
            current.pairs[current.count] = pair;
            current.count += 1;
            if (self.selection) |previous| {
                if (previous.moved(pair) and queued < max_selection_events and self.publisher.queueSelected(node.id)) queued += 1;
            }
        }
        self.selection = current;
    }
    /// The identity of the node the snapshot gives the focus: the first one
    /// marked focused, as `uia.Snapshot` takes it.
    fn focusedKey(nodes: []const uia.NodeSpec, keys: []const u64) ?u64 {
        for (nodes, keys) |node, key| if (node.focused) return key;
        return null;
    }
    /// The focus is now on the element `key` (null: on none). A focus that
    /// arrives with a new snapshot on an element other than the one last
    /// reported is queued for the message loop here; an in-place move queued
    /// its own event in `Publisher.moveFocus`.
    fn trackFocus(self: *PopupBridge, key: ?u64, new_snapshot: bool) void {
        self.focus_key = key;
        const focused = key orelse {
            self.focus_reported = null;
            return;
        };
        if (self.focus_reported) |reported| if (reported == focused) return;
        if (new_snapshot) _ = self.publisher.queueFocusChanged();
    }
    /// A focus-only rebuild (`focus_only`). When its specs describe the
    /// current snapshot's elements unchanged apart from the focus (the same
    /// window, owner, callbacks, tokens and keys in the same order and node
    /// specs), the focus moves in place to the node they mark focused, and
    /// the elements clients hold stay valid. Anything else is a model change
    /// no invalidation announced: revoke the snapshot, and publish anew at
    /// the next request. A focus-only rebuild never publishes.
    fn moveFocusTo(self: *PopupBridge, attachment: refs.Attachment, hwnd: w32.HWND, nodes: []const uia.NodeSpec, tokens: []const u64, keys: []const u64, callbacks: PopupCallbacks) void {
        const current = self.callbacks orelse return self.dirty();
        if (self.hwnd == hwnd and std.meta.eql(current, callbacks) and std.mem.eql(u64, tokens, self.tokens[0..self.length]) and
            std.mem.eql(u64, keys, self.keys[0..self.length]) and self.publisher.matchesExceptFocus(attachment, hwnd, nodes))
        {
            const focused: u64 = for (nodes) |node| {
                if (node.focused) break node.id;
            } else 0;
            if (self.publisher.moveFocus(focused)) return self.trackFocus(focusedKey(nodes, keys), false);
        }
        self.dirty();
    }
    pub fn announce(self: *PopupBridge, text: []const u8) void {
        self.announcement.stage(text);
        self.announcement.retry(&self.publisher);
    }
    pub fn dispatch(self: *PopupBridge, app: *App, action: *const uia.Action) bool {
        if (!self.publisher.accepts(action.*) or action.node_id == 0 or action.node_id > self.length) return false;
        const owner_live = switch (action.attachment.object.kind) {
            .window => app.resolveWindowView(action.attachment) != null,
            .surface => app.resolveSurfaceView(action.attachment) != null,
            .tab => app.resolveTabView(action.attachment) != null,
        };
        if (!owner_live) return false;
        const callbacks = self.callbacks orelse return false;
        const hwnd = self.hwnd orelse return false;
        if (action.kind != .notification and action.kind != .focus_changed and action.kind != .element_selected and w32.IsWindowEnabled(hwnd) == 0) return false;
        const token = self.tokens[@intCast(action.node_id - 1)];
        if (!callbacks.is_live(callbacks.context)) return false;
        if (action.kind == .notification) {
            if (!self.announcement.consume(action)) return false;
            const delivered = self.publisher.notify(action.value);
            if (!delivered) std.log.scoped(.win32_uia).warn("notification API rejected an announcement", .{});
            return delivered;
        }
        if (action.kind == .focus_changed) return self.dispatchFocusChanged(action);
        if (action.kind == .element_selected) return self.dispatchSelected(action);
        return self.dispatchPrepared(callbacks, token, action);
    }
    /// An ElementSelected event of the current snapshot (`trackSelection`),
    /// raised here from the message loop, outside locks, like a focus
    /// change: no widget callback, nothing revoked.
    fn dispatchSelected(self: *PopupBridge, action: *const uia.Action) bool {
        const raised = self.publisher.raiseSelected(action.node_id);
        if (@import("../remote_test.zig").enabled()) std.log.scoped(.win32_uia).info("fixture_uia_selected snapshot={d} node={d} raised={}", .{ action.snapshot_id, action.node_id, raised });
        return raised;
    }
    /// A focus changed event of the current snapshot (queued by
    /// `Publisher.moveFocus` or `trackFocus`), raised here from the message
    /// loop, outside locks: no widget callback, nothing revoked. Raised while
    /// its node still has the focus, that element counts as reported.
    fn dispatchFocusChanged(self: *PopupBridge, action: *const uia.Action) bool {
        const raised = self.publisher.raiseFocusChanged(action.node_id);
        if (raised) self.focus_reported = self.focus_key;
        if (@import("../remote_test.zig").enabled()) std.log.scoped(.win32_uia).info("fixture_uia_focus snapshot={d} node={d} raised={}", .{ action.snapshot_id, action.node_id, raised });
        return raised;
    }
    fn dispatchPrepared(self: *PopupBridge, callbacks: PopupCallbacks, token: u64, action: *const uia.Action) bool {
        // UIAutomation may focus a Value target before calling SetValue on the
        // same retained provider. Focus alone does not change the token/model
        // mapping. Actual edits, selection and layout mutations still revoke it.
        if (@import("../remote_test.zig").enabled()) std.log.scoped(.win32_uia).info("fixture_uia_dispatch snapshot={d} node={d} kind={s} invalidates={}", .{ action.snapshot_id, action.node_id, @tagName(action.kind), action.kind != .focus });
        if (action.kind != .focus) self.dirty();
        // The callback may dismiss its menu and free this bridge. No reads of
        // self/context after the operation; the App registry is removed first.
        return callbacks.action(callbacks.context, token, action);
    }

    /// Called inside MenuPopup with its actual Level. Rows already carry their
    /// pixel layout; no duplicate menu model or guessed item rectangles.
    pub fn publishMenu(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, level: anytype, callbacks: PopupCallbacks) !void {
        if (self.upToDate()) return;
        const hwnd = level.popup.hwnd orelse return self.hide();
        if (!level.popup.visible) return self.hide();
        var builder: PopupBuilder = .{};
        _ = try builder.add(.{ .id = 0, .name = i18n.tr("Menu"), .role = .menu, .bounds = screenRect(level.bounds) }, 0);
        for (level.list.items.items, 0..) |item, index| {
            if (item.kind == .separator) continue;
            const row = level.rows[index];
            const top = level.bounds.top + level.arrow_px + row.top - level.scroll_px;
            const visible_top = @max(top, level.bounds.top + level.arrow_px);
            const visible_bottom = @min(top + row.height, level.bounds.bottom - level.arrow_px);
            if (visible_bottom <= visible_top) continue;
            const actionable = item.kind == .action or item.kind == .submenu;
            const expanded = item.kind == .submenu and level.state.depth > level.index + 1 and level.state.levels[level.index + 1].parent_item == index;
            _ = try builder.add(.{ .id = 0, .parent = 0, .name = item.label, .role = if (actionable) .menu_item else .text, .bounds = screenRect(.{ .left = level.bounds.left, .top = visible_top, .right = level.bounds.right, .bottom = visible_bottom }), .enabled = actionable and item.enabled, .focusable = actionable and item.enabled, .focused = actionable and level.hot == index and level.hot_keyboard, .patterns = .{ .invoke = item.kind == .action, .expand_collapse = item.kind == .submenu }, .expand_state = if (expanded) 1 else 0 }, @as(u64, @intCast(index)) + 1);
        }
        try self.publish(api, queue, attachment, hwnd, builder.nodes[0..builder.length], builder.tokens[0..builder.length], callbacks);
    }

    /// Palette supplies its private listView() rectangle in DIPs. Filter value,
    /// rows and selection come directly from its current GUI model.
    pub fn publishPalette(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, palette: *Palette, view: d2d.Rect, callbacks: PopupCallbacks) !void {
        if (self.upToDate()) return;
        const hwnd = palette.popup.hwnd orelse return self.hide();
        if (!palette.active or !palette.popup.visible) return self.hide();
        var bounds: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &bounds) == 0) return error.InvalidWindow;
        const scale = palette.popup.ownerScale();
        const alloc = std.heap.page_allocator;
        const value = try palette.popup.input.text(alloc);
        defer alloc.free(value);
        var builder: PopupBuilder = .{};
        _ = try builder.add(.{ .id = 0, .name = i18n.tr("Command Palette"), .role = .window, .bounds = screenRect(bounds), .patterns = .{ .window = true } }, palette_root);
        const search = try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Search"), .role = .edit, .value = value, .bounds = dipRect(palette.popup.input.field, bounds, scale), .patterns = .{ .value = true }, .read_only = false, .focusable = true, .focused = w32.GetFocus() == hwnd }, palette_filter);
        const list = try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Results"), .role = .list, .bounds = dipRect(view, bounds, scale), .patterns = .{ .selection = true }, .selection_required = true }, palette_list);
        // The keyboard stays in the edit: screen readers follow the
        // selection of the list it controls (ElementSelected).
        builder.nodes[search].controller_for = list;
        for (palette.rows.items, 0..) |row, index| {
            const item_index = switch (row.kind) {
                .item => |item| item,
                .header => continue,
            };
            const top = view.y + row.y - palette.scroll;
            const visible_top = @max(top, view.y);
            const visible_bottom = @min(top + row.h, view.y + view.h);
            if (visible_bottom <= visible_top) continue;
            const item = palette.items.items[item_index];
            _ = try builder.add(.{ .id = 0, .parent = list, .name = if (palette.page == .root) item.title else item.name, .role = .list_item, .bounds = dipRect(.{ .x = view.x, .y = visible_top, .w = view.w, .h = visible_bottom - visible_top }, bounds, scale), .patterns = .{ .invoke = true, .selection_item = true }, .selected = palette.selected == index }, palette_row_base + @as(u64, @intCast(index)));
        }
        if (palette.back_rect) |back| {
            _ = try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Back"), .role = .button, .bounds = dipRect(back, bounds, scale), .patterns = .{ .invoke = true } }, palette_back);
        }
        try self.publish(api, queue, attachment, hwnd, builder.nodes[0..builder.length], builder.tokens[0..builder.length], callbacks);
    }

    /// Notification roots retain Window pattern, including on older Win10 where
    /// the Notification export is absent and a polite live region is used.
    /// Publication does not itself imply a new semantic announcement.
    pub fn publishToast(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, toast: *Toast, callbacks: PopupCallbacks) !bool {
        if (self.upToDate()) return false;
        const hwnd = toast.popup.hwnd orelse {
            self.hide();
            return false;
        };
        if (!toast.popup.visible) {
            self.hide();
            return false;
        }
        var bounds: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &bounds) == 0) return error.InvalidWindow;
        const specs = [_]uia.NodeSpec{.{ .id = 1, .name = toast.text[0..toast.text_len], .role = .window, .bounds = screenRect(bounds), .patterns = .{ .window = true }, .live_setting = 1, .topmost = isTopmost(hwnd) }};
        try self.publish(api, queue, attachment, hwnd, &specs, &.{0}, callbacks);
        return true;
    }

    /// Called from Dialogs with its live Dialog, including its actual layout and
    /// focus order. Action tokens map to Dialog.activate/target, not mouse input.
    pub fn publishDialog(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, dialog: anytype, callbacks: PopupCallbacks) !void {
        if (self.upToDate()) return;
        const hwnd = dialog.popup.hwnd orelse return self.hide();
        if (!dialog.popup.visible or dialog.result != null) return self.hide();
        var bounds: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &bounds) == 0) return error.InvalidWindow;
        const scale = dialog.popup.ownerScale();
        var builder: PopupBuilder = .{};
        _ = try builder.add(.{ .id = 0, .name = dialog.spec.window_title orelse dialog.spec.title, .role = .window, .bounds = screenRect(bounds), .patterns = .{ .window = true }, .modal = true }, 0);
        if (dialog.spec.body.len > 0) {
            _ = try builder.add(.{ .id = 0, .parent = 0, .name = dialog.spec.body, .role = .text, .bounds = dipRect(dialog.layout.body, bounds, scale) }, 1);
        }
        const link_count = @min(dialog.spec.links.len, dialog.layout.links.len);
        const button_count = @min(dialog.spec.buttons.len, dialog.layout.buttons.len);
        for (dialog.spec.links[0..link_count], 0..) |link, index| {
            _ = try builder.add(.{ .id = 0, .parent = 0, .name = link.label, .role = .button, .bounds = dipRect(dialog.layout.links[index], bounds, scale), .patterns = .{ .invoke = true }, .focusable = true, .focused = dialog.focus == index }, dialog_action_base + @as(u64, @intCast(index)));
        }
        if (dialog.spec.check) |label| {
            _ = try builder.add(.{ .id = 0, .parent = 0, .name = label, .role = .checkbox, .bounds = dipRect(dialog.layout.check, bounds, scale), .patterns = .{ .toggle = true }, .toggle_state = @intFromBool(dialog.checked), .focusable = true, .focused = dialog.focus == link_count }, dialog_action_base + @as(u64, @intCast(link_count)));
        }
        const buttons_start = link_count + @as(usize, @intFromBool(dialog.spec.check != null));
        for (dialog.spec.buttons[0..button_count], 0..) |button_spec, index| {
            _ = try builder.add(.{ .id = 0, .parent = 0, .name = button_spec.label, .role = .button, .bounds = dipRect(dialog.layout.buttons[index], bounds, scale), .patterns = .{ .invoke = true }, .focusable = true, .focused = dialog.focus == buttons_start + index }, dialog_action_base + @as(u64, @intCast(buttons_start + index)));
        }
        try self.publish(api, queue, attachment, hwnd, builder.nodes[0..builder.length], builder.tokens[0..builder.length], callbacks);
    }

    /// Settings supplies buildRows() and the exact enabled/focused states used
    /// by its hit targets. All rectangles and action tokens use that same hit
    /// list, so clipping/search/reordering cannot select a guessed control.
    pub fn publishSettings(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, settings: anytype, rows: anytype, states: []const ControlState, callbacks: PopupCallbacks) !void {
        if (self.upToDate()) return;
        const hwnd = settings.popup.hwnd orelse return self.hide();
        if (!settings.open or !settings.popup.visible) return self.hide();
        if (states.len != settings.hit_count or rows.len > 64) return error.InvalidSnapshot;
        var bounds: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &bounds) == 0) return error.InvalidWindow;
        const scale = settings.popup.ownerScale();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var builder: PopupBuilder = .{};
        _ = try builder.add(.{ .id = 0, .name = i18n.tr("Settings"), .role = .window, .bounds = screenRect(bounds), .patterns = .{ .window = true } }, 0);
        var section_bounds: ?uia.Rect = null;
        var radio_bounds: ?uia.Rect = null;
        for (settings.hits[0..settings.hit_count]) |hit| switch (hit.target) {
            .section => section_bounds = unionRect(section_bounds, dipRect(hit.rect, bounds, scale)),
            .row => |index| if (index < rows.len and rows[index].kind == .radio) {
                radio_bounds = unionRect(radio_bounds, dipRect(hit.rect, bounds, scale));
            },
            else => {},
        };
        const sections = if (section_bounds) |rect| try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Settings"), .role = .tab, .bounds = rect, .patterns = .{ .selection = true }, .selection_required = true }, settings_container) else null;
        const radios = if (radio_bounds) |rect| try builder.add(.{ .id = 0, .parent = 0, .name = i18n.trRuntime(settings_map.pageLabel(settings.section)), .role = .list, .bounds = rect, .patterns = .{ .selection = true }, .selection_required = true }, settings_container) else null;
        var groups: [64]?u16 = @splat(null);
        for (settings.hits[0..settings.hit_count], states, 0..) |hit, state, hit_index| {
            var spec: uia.NodeSpec = .{ .id = 0, .parent = 0, .name = "", .role = .button, .bounds = dipRect(hit.rect, bounds, scale), .enabled = state.enabled, .focused = state.focused, .focusable = state.focusable };
            switch (hit.target) {
                .section => |section| {
                    spec.parent = sections orelse 0;
                    spec.name = i18n.trRuntime(settings_map.pageLabel(section));
                    spec.role = .tab_item;
                    spec.patterns.selection_item = true;
                    spec.selected = settings.section == section;
                },
                .close => {
                    spec.name = i18n.tr("Close");
                    spec.patterns.invoke = true;
                },
                .search => {
                    spec.name = i18n.tr("Search");
                    spec.role = .edit;
                    spec.value = settings.search_query.items;
                    spec.patterns.value = true;
                    spec.read_only = !state.enabled;
                },
                .row => |index| {
                    if (index >= rows.len) continue;
                    const row = rows[index];
                    spec.name = row.title;
                    switch (row.kind) {
                        .toggle => {
                            spec.role = .checkbox;
                            spec.patterns.toggle = true;
                            spec.toggle_state = @intFromBool(row.on);
                        },
                        .radio => {
                            spec.role = .list_item;
                            spec.parent = radios orelse 0;
                            spec.patterns.selection_item = true;
                            spec.selected = row.on;
                        },
                        .button, .result => spec.patterns.invoke = true,
                        else => continue,
                    }
                },
                .chip => |chip| {
                    if (chip.row >= rows.len or chip.index >= rows[chip.row].choices.len) continue;
                    const row = rows[chip.row];
                    if (groups[chip.row] == null) groups[chip.row] = try builder.addKeyed(.{ .id = 0, .parent = 0, .name = row.title, .role = .list, .bounds = spec.bounds, .patterns = .{ .selection = true }, .selection_required = true, .focusable = state.container_focusable, .focused = state.container_focused }, settings_hit_base + hit_index, settingsGroupKey(chip.row));
                    const parent = groups[chip.row].?;
                    builder.nodes[parent].bounds = unionRect(builder.nodes[parent].bounds, spec.bounds);
                    spec.parent = parent;
                    spec.role = .list_item;
                    spec.name = row.choices[chip.index];
                    spec.patterns.selection_item = true;
                    spec.selected = row.choice == chip.index;
                },
                .value => |index| {
                    if (index >= rows.len) continue;
                    spec.name = rows[index].title;
                    spec.value = rows[index].value;
                    spec.role = .edit;
                    spec.patterns.value = true;
                    spec.read_only = !state.enabled;
                },
                .field => |index| {
                    if (index >= rows.len) continue;
                    spec.name = rows[index].title;
                    spec.role = .edit;
                    spec.patterns.value = true;
                    spec.read_only = !state.enabled;
                    spec.value = switch (rows[index].action) {
                        .themes => settings.theme_query.items,
                        .font_family => settings.font_query.items,
                        else => continue,
                    };
                },
                .step => |step| {
                    if (step.row >= rows.len) continue;
                    spec.name = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ rows[step.row].title, if (step.step == .plus) i18n.tr("Increase") else i18n.tr("Decrease") });
                    spec.patterns.invoke = true;
                },
                .reset => |index| {
                    if (index >= rows.len) continue;
                    spec.name = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ rows[index].title, i18n.tr("Reset") });
                    spec.patterns.invoke = true;
                },
                .group_button => |button_spec| {
                    if (button_spec.row >= rows.len) continue;
                    const label = switch (button_spec.button) {
                        .reset => i18n.tr("Reset"),
                        .apply_theme => i18n.tr("Apply Theme"),
                        .apply_font => i18n.tr("Apply Font"),
                    };
                    spec.name = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ rows[button_spec.row].title, label });
                    spec.patterns.invoke = true;
                },
                .item => |item| {
                    if (item.row >= rows.len) continue;
                    const row = rows[item.row];
                    const themes = row.action == .themes;
                    if (!themes and row.action != .font_family) continue;
                    const list = if (themes) &settings.theme_list else &settings.font_list;
                    const names = if (themes) (if (settings.themes) |values| values.names else &.{}) else settings.font_picker.names;
                    if (item.index >= list.matches.items.len) continue;
                    const name_index = list.matches.items[item.index];
                    if (name_index >= names.len) continue;
                    if (groups[item.row] == null) groups[item.row] = try builder.add(.{ .id = 0, .parent = 0, .name = row.title, .role = .list, .bounds = spec.bounds, .patterns = .{ .selection = true }, .selection_required = true }, settings_container);
                    const parent = groups[item.row].?;
                    builder.nodes[parent].bounds = unionRect(builder.nodes[parent].bounds, spec.bounds);
                    spec.parent = parent;
                    spec.name = names[name_index];
                    spec.role = .list_item;
                    spec.patterns = .{ .selection_item = true, .invoke = true };
                    spec.selected = list.cursor == item.index;
                },
            }
            _ = try builder.addKeyed(spec, settings_hit_base + @as(u64, @intCast(hit_index)), settingsKey(hit.target));
        }
        try self.publishKeyed(api, queue, attachment, hwnd, builder.nodes[0..builder.length], builder.tokens[0..builder.length], builder.keys[0..builder.length], callbacks);
    }
};

test "popup focus dispatch preserves the retained Value provider and pending action" {
    const testing = std.testing;
    var api: uia.Api = undefined;
    api.count = .init(1);
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: refs.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    var bridge: PopupBridge = .{};
    defer bridge.deinit();
    try bridge.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &.{
        .{ .id = 1, .name = "Palette", .role = .window, .patterns = .{ .window = true } },
        .{ .id = 2, .parent = 0, .name = "Search", .role = .edit, .patterns = .{ .value = true }, .focusable = true, .read_only = false },
    });
    const snapshot = bridge.publisher.current.?;
    const Lifetime = extern struct {
        query: *const anyopaque,
        add: *const fn (*uia.Face) callconv(.winapi) u32,
        release: *const fn (*uia.Face) callconv(.winapi) u32,
        options: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    const face = &snapshot.nodes[1].faces[0];
    const table: *const Lifetime = @ptrCast(@alignCast(face.vtable));
    _ = table.add(face);
    defer _ = table.release(face);
    var value: uia.Action = .{ .attachment = attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .set_value, .value = &.{}, .alloc = testing.allocator };
    var focus = value;
    focus.kind = .focus;
    const Context = struct {
        calls: usize = 0,
        fn live(_: *anyopaque) bool {
            return true;
        }
        fn action(context: *anyopaque, _: u64, _: *const uia.Action) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return true;
        }
    };
    var context: Context = .{};
    const callbacks: PopupCallbacks = .{ .context = &context, .is_live = Context.live, .action = Context.action };
    try testing.expect(bridge.dispatchPrepared(callbacks, palette_filter, &focus));
    try testing.expectEqual(@as(usize, 1), context.calls);
    var options: u32 = 0;
    try testing.expectEqual(@as(i32, 0), table.options(face, &options));
    try testing.expect(bridge.publisher.accepts(value));
    // A real edit still revokes index-based providers before model mutation.
    try testing.expect(bridge.dispatchPrepared(callbacks, palette_filter, &value));
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), table.options(face, &options));
    try testing.expect(!bridge.publisher.accepts(value));
}

test "popup focus-only rebuild moves HasKeyboardFocus and GetFocus in place" {
    // The popup rebuilds its specs only to report a focus move (the real
    // PopupBridge.publish): the elements a client holds stay usable and
    // report the new focus. No HWND, desktop or UIAutomationCore is used.
    const testing = std.testing;
    var api: uia.Api = undefined;
    api.count = .init(1);
    api.event = null;
    api.notification = null;
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: refs.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const Widget = struct {
        fn live(_: *anyopaque) bool {
            return true;
        }
        fn action(_: *anyopaque, _: u64, _: *const uia.Action) bool {
            return true;
        }
        /// A dialog, its check box (node 2) and OK (node 3); `focus` is a node id.
        fn specs(focus: u64, checked: bool) [3]uia.NodeSpec {
            return .{
                .{ .id = 1, .name = "Dialog", .role = .window, .patterns = .{ .window = true } },
                .{ .id = 2, .parent = 0, .name = "Remember", .role = .checkbox, .patterns = .{ .toggle = true }, .toggle_state = @intFromBool(checked), .focusable = true, .focused = focus == 2 },
                .{ .id = 3, .parent = 0, .name = "OK", .role = .button, .patterns = .{ .invoke = true }, .focusable = true, .focused = focus == 3 },
            };
        }
    };
    const Simple = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
        GetPatternProvider: *const fn (*uia.Face, i32, *?*uia.Face) callconv(.winapi) i32,
        GetPropertyValue: *const fn (*uia.Face, i32, *uia.Variant) callconv(.winapi) i32,
    };
    const Root = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ElementProviderFromPoint: *const fn (*uia.Face, f64, f64, *?*uia.Face) callconv(.winapi) i32,
        GetFocus: *const fn (*uia.Face, *?*uia.Face) callconv(.winapi) i32,
    };
    const Probe = struct {
        fn table(face: *uia.Face) *const Simple {
            return @ptrCast(@alignCast(face.vtable));
        }
        /// ProviderOptions: S_OK while usable, UIA_E_ELEMENTNOTAVAILABLE once revoked.
        fn options(face: *uia.Face) i32 {
            var flags: u32 = 0;
            return table(face).ProviderOptions(face, &flags);
        }
        /// UIA_HasKeyboardFocusPropertyId (30008), a VT_BOOL.
        fn hasFocus(face: *uia.Face) !bool {
            var value: uia.Variant = .{};
            try testing.expectEqual(@as(i32, 0), table(face).GetPropertyValue(face, 30008, &value));
            try testing.expectEqual(@as(u16, 11), value.tag);
            return value.data.integer != 0;
        }
        /// The node IRawElementProviderFragmentRoot::GetFocus reports.
        fn rootFocus(root: *uia.Face) !?*anyopaque {
            const vtable: *const Root = @ptrCast(@alignCast(root.vtable));
            var focused: ?*uia.Face = null;
            try testing.expectEqual(@as(i32, 0), vtable.GetFocus(root, &focused));
            const face = focused orelse return null;
            _ = vtable.Release(face);
            return face.node;
        }
    };
    var context: u8 = 0;
    const callbacks: PopupCallbacks = .{ .context = &context, .is_live = Widget.live, .action = Widget.action };
    const tokens = [_]u64{ 0, 10, 20 };
    var bridge: PopupBridge = .{};
    defer bridge.deinit();
    const first = Widget.specs(2, false);
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &first, &tokens, callbacks);
    const snapshot = bridge.publisher.current.?;
    const check = &snapshot.nodes[1].faces[0];
    const ok = &snapshot.nodes[2].faces[0];
    const root = &snapshot.nodes[0].faces[2];
    for ([_]*uia.Face{ check, ok, root }) |face| _ = Probe.table(face).AddRef(face);
    defer for ([_]*uia.Face{ check, ok, root }) |face| {
        _ = Probe.table(face).Release(face);
    };
    try testing.expect(try Probe.hasFocus(check));
    try testing.expect(!try Probe.hasFocus(ok));
    try testing.expectEqual(@as(?*anyopaque, check.node), try Probe.rootFocus(root));

    // Tab: the focus moves from the check box to OK and nothing else changed.
    const moved = Widget.specs(3, false);
    bridge.focus_only = true;
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &moved, &tokens, callbacks);
    bridge.focus_only = false;
    try testing.expectEqual(snapshot, bridge.publisher.current.?);
    try testing.expectEqual(@as(i32, 0), Probe.options(check));
    try testing.expectEqual(@as(i32, 0), Probe.options(ok));
    try testing.expect(!try Probe.hasFocus(check));
    try testing.expect(try Probe.hasFocus(ok));
    try testing.expectEqual(@as(?*anyopaque, ok.node), try Probe.rootFocus(root));

    // The popup lost the focus: still the same elements, none focused.
    const away = Widget.specs(0, false);
    bridge.focus_only = true;
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &away, &tokens, callbacks);
    bridge.focus_only = false;
    try testing.expectEqual(snapshot, bridge.publisher.current.?);
    try testing.expect(!try Probe.hasFocus(check));
    try testing.expect(!try Probe.hasFocus(ok));
    try testing.expectEqual(@as(?*anyopaque, null), try Probe.rootFocus(root));

    // A focus-only rebuild that finds anything else changed (the check box
    // toggled with no invalidation) revokes the snapshot and publishes
    // nothing; the next ordinary publication replaces it.
    const toggled = Widget.specs(2, true);
    bridge.focus_only = true;
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &toggled, &tokens, callbacks);
    try testing.expect(bridge.publisher.current == null and bridge.needs_publish);
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), Probe.options(check));
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &toggled, &tokens, callbacks);
    try testing.expect(bridge.publisher.current == null);
    bridge.focus_only = false;
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &toggled, &tokens, callbacks);
    try testing.expect(bridge.publisher.current.? != snapshot);
    // So does one with other elements (tokens).
    bridge.focus_only = true;
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &toggled, &[_]u64{ 0, 10, 30 }, callbacks);
    bridge.focus_only = false;
    try testing.expect(bridge.publisher.current == null and bridge.needs_publish);
}

test "popup publications report a focus that arrives with a new snapshot" {
    // A popup just shown with a focused element, and a republication that
    // gives the focus to another element (a menu that scrolls as the keyboard
    // moves, a submenu or page opened from the keyboard), each queue one
    // focus changed event for the new snapshot; a republication that keeps
    // the focus where it was reported raises none. The queue posts to a real
    // message-only window, and the event names the real provider face.
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const sink = w32.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.TestWindowFailed;
    defer {
        var drained: w32.MSG = undefined;
        while (w32.PeekMessageW(&drained, sink, 0, 0, w32.PM_REMOVE) != 0) {}
        _ = w32.DestroyWindow(sink);
    }
    const Recorder = struct {
        var raised: usize = 0;
        var sender: ?*uia.Face = null;
        fn raise(face: *uia.Face, event: i32) callconv(.winapi) i32 {
            if (event != 20005) return -1;
            raised += 1;
            sender = face;
            return 0;
        }
    };
    Recorder.raised = 0;
    var api: uia.Api = undefined;
    api.count = .init(1);
    api.event = Recorder.raise;
    api.notification = null;
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = sink };
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    defer queue.close();
    const attachment: refs.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const Widget = struct {
        fn live(_: *anyopaque) bool {
            return true;
        }
        fn action(_: *anyopaque, _: u64, _: *const uia.Action) bool {
            return true;
        }
        /// A menu: New Tab (node 2) and the Split submenu (node 3);
        /// `focus` is a node id, 0 for none.
        fn specs(focus: u64, expanded: bool) [3]uia.NodeSpec {
            return .{
                .{ .id = 1, .name = "Menu", .role = .menu },
                .{ .id = 2, .parent = 0, .name = "New Tab", .role = .menu_item, .patterns = .{ .invoke = true }, .focusable = true, .focused = focus == 2 },
                .{ .id = 3, .parent = 0, .name = "Split", .role = .menu_item, .patterns = .{ .expand_collapse = true }, .expand_state = @intFromBool(expanded), .focusable = true, .focused = focus == 3 },
            };
        }
    };
    const Simple = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
        GetPatternProvider: *const fn (*uia.Face, i32, *?*uia.Face) callconv(.winapi) i32,
        GetPropertyValue: *const fn (*uia.Face, i32, *uia.Variant) callconv(.winapi) i32,
    };
    const Probe = struct {
        /// UIA_HasKeyboardFocusPropertyId (30008) through the provider's vtable.
        fn hasFocus(face: *uia.Face) !bool {
            const table: *const Simple = @ptrCast(@alignCast(face.vtable));
            var value: uia.Variant = .{};
            try testing.expectEqual(@as(i32, 0), table.GetPropertyValue(face, 30008, &value));
            return value.data.integer != 0;
        }
        /// The next queued action, which must be a focus changed event.
        fn event(q: *uia.Queue) !uia.Action {
            const action = q.pop() orelse return error.NoFocusEvent;
            try testing.expectEqual(uia.ActionKind.focus_changed, action.kind);
            return action;
        }
    };
    var context: u8 = 0;
    const callbacks: PopupCallbacks = .{ .context = &context, .is_live = Widget.live, .action = Widget.action };
    const tokens = [_]u64{ 0, 1, 2 };
    var bridge: PopupBridge = .{};
    defer bridge.deinit();

    // Shown with the keyboard on New Tab: reported once, naming its face.
    const opened = Widget.specs(2, false);
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &opened, &tokens, callbacks);
    const first = bridge.publisher.current.?;
    var shown = try Probe.event(&queue);
    defer shown.deinit();
    try testing.expectEqual(first.id, shown.snapshot_id);
    try testing.expectEqual(@as(u64, 2), shown.node_id);
    try testing.expect(bridge.publisher.accepts(shown));
    try testing.expect(bridge.dispatchFocusChanged(&shown));
    try testing.expectEqual(@as(usize, 1), Recorder.raised);
    try testing.expectEqual(@as(?*uia.Face, &first.nodes[1].faces[0]), Recorder.sender);
    try testing.expect(queue.pop() == null);

    // A model change that keeps the focus on New Tab: nothing to report.
    bridge.dirty();
    const expanded = Widget.specs(2, true);
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &expanded, &tokens, callbacks);
    try testing.expect(queue.pop() == null);

    // The keyboard moves to Split and the menu scrolls: the in-place event
    // queued for the old snapshot goes stale; the new snapshot reports Split.
    const down = Widget.specs(3, true);
    bridge.focus_only = true;
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &down, &tokens, callbacks);
    bridge.focus_only = false;
    const before_scroll = bridge.publisher.current.?.id;
    bridge.dirty();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &down, &tokens, callbacks);
    const scrolled = bridge.publisher.current.?;
    var stale = try Probe.event(&queue);
    defer stale.deinit();
    try testing.expectEqual(before_scroll, stale.snapshot_id);
    try testing.expect(!bridge.publisher.accepts(stale));
    var moved = try Probe.event(&queue);
    defer moved.deinit();
    try testing.expectEqual(scrolled.id, moved.snapshot_id);
    try testing.expectEqual(@as(u64, 3), moved.node_id);
    try testing.expect(bridge.publisher.accepts(moved));
    try testing.expect(bridge.dispatchFocusChanged(&moved));
    try testing.expectEqual(@as(usize, 2), Recorder.raised);
    try testing.expectEqual(@as(?*uia.Face, &scrolled.nodes[2].faces[0]), Recorder.sender);
    try testing.expect(try Probe.hasFocus(&scrolled.nodes[2].faces[0]));
    try testing.expect(!try Probe.hasFocus(&scrolled.nodes[1].faces[0]));
    try testing.expect(queue.pop() == null);

    // Settings-like positional tokens shift while the keys stay: the focus
    // did not move, nothing is reported.
    bridge.dirty();
    try bridge.publishKeyed(&api, &queue, attachment, @ptrFromInt(1), &down, &[_]u64{ 0, 11, 12 }, &tokens, callbacks);
    try testing.expect(queue.pop() == null);

    // The focus leaves every element, then comes back to Split: reported.
    bridge.dirty();
    const away = Widget.specs(0, true);
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &away, &tokens, callbacks);
    try testing.expect(queue.pop() == null);
    bridge.dirty();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &down, &tokens, callbacks);
    var back = try Probe.event(&queue);
    defer back.deinit();
    try testing.expectEqual(@as(u64, 3), back.node_id);
    try testing.expect(bridge.dispatchFocusChanged(&back));
    try testing.expectEqual(@as(usize, 3), Recorder.raised);

    // Hidden and shown again on the same element: reported again. An event
    // the loop has not dispatched before the next publication is replaced
    // by that publication's own, never raised twice.
    bridge.hide();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &down, &tokens, callbacks);
    var reshown = try Probe.event(&queue);
    defer reshown.deinit();
    try testing.expect(bridge.publisher.accepts(reshown));
    bridge.dirty();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &down, &tokens, callbacks);
    try testing.expect(!bridge.publisher.accepts(reshown));
    var latest = try Probe.event(&queue);
    defer latest.deinit();
    try testing.expect(bridge.publisher.accepts(latest));
    try testing.expect(bridge.dispatchFocusChanged(&latest));
    try testing.expectEqual(@as(usize, 4), Recorder.raised);
    try testing.expect(queue.pop() == null);
}

test "popup publications raise ElementSelected only when a shown list moves its selection" {
    // A palette's results (Down moves the selection, typing refilters) and a
    // list that appears: only a selection that moved within a list the
    // previous publication showed queues ElementSelected, naming the new
    // selected element's face. The queue posts to a real message-only window.
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const sink = w32.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.TestWindowFailed;
    defer {
        var drained: w32.MSG = undefined;
        while (w32.PeekMessageW(&drained, sink, 0, 0, w32.PM_REMOVE) != 0) {}
        _ = w32.DestroyWindow(sink);
    }
    const Recorder = struct {
        var raised: usize = 0;
        var sender: ?*uia.Face = null;
        fn raise(face: *uia.Face, event: i32) callconv(.winapi) i32 {
            if (event != 20012) return -1;
            raised += 1;
            sender = face;
            return 0;
        }
    };
    Recorder.raised = 0;
    var api: uia.Api = undefined;
    api.count = .init(1);
    api.event = Recorder.raise;
    api.notification = null;
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = sink };
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    defer queue.close();
    const attachment: refs.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const Widget = struct {
        fn live(_: *anyopaque) bool {
            return true;
        }
        fn action(_: *anyopaque, _: u64, _: *const uia.Action) bool {
            return true;
        }
        /// A palette: its results list holds two rows, row `choice`
        /// selected; `rows` names them. With `extra`, a second list appears.
        fn specs(rows: [2][]const u8, choice: usize, extra: bool) [7]uia.NodeSpec {
            return .{
                .{ .id = 1, .name = "Command Palette", .role = .window, .patterns = .{ .window = true } },
                .{ .id = 2, .parent = 0, .name = "Results", .role = .list, .patterns = .{ .selection = true } },
                .{ .id = 3, .parent = 1, .name = rows[0], .role = .list_item, .patterns = .{ .selection_item = true }, .selected = choice == 0 },
                .{ .id = 4, .parent = 1, .name = rows[1], .role = .list_item, .patterns = .{ .selection_item = true }, .selected = choice == 1 },
                .{ .id = 5, .parent = 0, .name = if (extra) "Themes" else "Hidden", .role = .list, .patterns = .{ .selection = extra } },
                .{ .id = 6, .parent = 4, .name = "Dark", .role = .list_item, .patterns = .{ .selection_item = true }, .selected = true },
                .{ .id = 7, .parent = 4, .name = "Light", .role = .list_item, .patterns = .{ .selection_item = true } },
            };
        }
        /// The next queued action, which must be an ElementSelected event.
        fn selected(q: *uia.Queue) !?uia.Action {
            const value = q.pop() orelse return null;
            try testing.expectEqual(uia.ActionKind.element_selected, value.kind);
            return value;
        }
    };
    var context: u8 = 0;
    const callbacks: PopupCallbacks = .{ .context = &context, .is_live = Widget.live, .action = Widget.action };
    const tokens = [_]u64{ 0, 1, 10, 11, 2, 20, 21 };
    var bridge: PopupBridge = .{};
    defer bridge.deinit();
    const commands = [2][]const u8{ "Split Right", "Split Left" };

    // Shown: what it selects is no change.
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &Widget.specs(commands, 0, false), &tokens, callbacks);
    try testing.expect(try Widget.selected(&queue) == null);

    // Down: the second row is selected; one event, naming its face.
    bridge.dirty();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &Widget.specs(commands, 1, false), &tokens, callbacks);
    const down = bridge.publisher.current.?;
    var moved = (try Widget.selected(&queue)).?;
    defer moved.deinit();
    try testing.expectEqual(@as(u64, 4), moved.node_id);
    try testing.expect(bridge.dispatchSelected(&moved));
    try testing.expectEqual(@as(usize, 1), Recorder.raised);
    try testing.expectEqual(@as(?*uia.Face, &down.nodes[3].faces[0]), Recorder.sender);
    try testing.expect(queue.pop() == null);

    // Republished unchanged: nothing.
    bridge.dirty();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &Widget.specs(commands, 1, false), &tokens, callbacks);
    try testing.expect(queue.pop() == null);

    // Typing refilters: the selected position now shows another command.
    bridge.dirty();
    const filtered = [2][]const u8{ "Split Up", "Split Down" };
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &Widget.specs(filtered, 1, false), &tokens, callbacks);
    var refiltered = (try Widget.selected(&queue)).?;
    defer refiltered.deinit();
    try testing.expectEqual(@as(u64, 4), refiltered.node_id);
    try testing.expect(queue.pop() == null);

    // A list that appears with its own selection: no event for it.
    bridge.dirty();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &Widget.specs(filtered, 1, true), &tokens, callbacks);
    try testing.expect(queue.pop() == null);

    // Hidden, then shown on another row: again only recorded.
    bridge.hide();
    try bridge.publish(&api, &queue, attachment, @ptrFromInt(1), &Widget.specs(commands, 0, false), &tokens, callbacks);
    try testing.expect(queue.pop() == null);
    try testing.expectEqual(@as(usize, 1), Recorder.raised);
}

test "settings focus keys follow the hit target, not its position" {
    const Section = enum { general, appearance };
    const Step = enum { minus, plus };
    const GroupButton = enum { reset, apply_theme, apply_font };
    const Target = union(enum) {
        section: Section,
        search,
        close,
        row: u16,
        chip: struct { row: u16, index: u8 },
        step: struct { row: u16, step: Step },
        value: u16,
        item: struct { row: u16, index: u32 },
        field: u16,
        group_button: struct { row: u16, button: GroupButton },
        reset: u16,
    };
    const targets = [_]Target{
        .{ .section = .general },                                  .{ .section = .appearance },
        .search,                                                   .close,
        .{ .row = 3 },                                             .{ .row = 4 },
        .{ .chip = .{ .row = 3, .index = 1 } },                    .{ .chip = .{ .row = 4, .index = 1 } },
        .{ .step = .{ .row = 3, .step = .plus } },                 .{ .value = 3 },
        .{ .item = .{ .row = 3, .index = 70000 } },                .{ .field = 3 },
        .{ .group_button = .{ .row = 3, .button = .apply_font } }, .{ .reset = 3 },
    };
    for (targets, 0..) |target, i| {
        // Equal targets give equal keys wherever their hits are.
        try std.testing.expectEqual(settingsKey(target), settingsKey(targets[i]));
        for (targets[i + 1 ..]) |other| try std.testing.expect(settingsKey(target) != settingsKey(other));
        try std.testing.expect(settingsKey(target) != settingsGroupKey(3));
    }
    try std.testing.expect(settingsGroupKey(3) != settingsGroupKey(4));
}

pub const palette_root: u64 = 0;
pub const palette_filter: u64 = 1;
pub const palette_list: u64 = 2;
pub const palette_back: u64 = 3;
pub const palette_row_base: u64 = 1 << 32;
pub const dialog_action_base: u64 = 1 << 32;
pub const settings_hit_base: u64 = 1 << 32;
pub const settings_container: u64 = std.math.maxInt(u64);
pub const ControlState = struct { enabled: bool = true, focused: bool = false, focusable: bool = false, container_focusable: bool = false, container_focused: bool = false };
/// A publication's (container, selected item) identities, up to `slots`.
const Selection = struct {
    const slots = 16;
    const Pair = struct { container: u64, item: u64 };
    pairs: [slots]Pair = undefined,
    count: usize = 0,
    /// Whether `pair` moves the selection of a container this publication
    /// also showed.
    fn moved(self: *const Selection, pair: Pair) bool {
        for (self.pairs[0..self.count]) |previous| if (previous.container == pair.container) return previous.item != pair.item;
        return false;
    }
};
const max_selection_events = 4;
/// The nearest ancestor with the Selection pattern, as UIA's SelectionContainer.
fn selectionContainer(nodes: []const uia.NodeSpec, node: uia.NodeSpec) ?usize {
    var parent = node.parent;
    while (parent) |index| {
        if (nodes[index].patterns.selection) return index;
        parent = nodes[index].parent;
    }
    return null;
}
/// A node's identity across publications: its key with its role and name,
/// so a row whose position now shows another entry is another element.
fn identity(key: u64, node: uia.NodeSpec) u64 {
    var hasher = std.hash.Wyhash.init(key);
    hasher.update(std.mem.asBytes(&node.role));
    hasher.update(node.name);
    return hasher.final();
}

const PopupBuilder = struct {
    nodes: [uia.max_nodes]uia.NodeSpec = undefined,
    tokens: [uia.max_nodes]u64 = undefined,
    keys: [uia.max_nodes]u64 = undefined,
    length: usize = 0,
    fn add(self: *PopupBuilder, input: uia.NodeSpec, token: u64) !u16 {
        return self.addKeyed(input, token, token);
    }
    /// `key`: the node's stable identity where its token is a position.
    fn addKeyed(self: *PopupBuilder, input: uia.NodeSpec, token: u64, key: u64) !u16 {
        if (self.length == self.nodes.len) return error.TooManyNodes;
        const index = self.length;
        self.nodes[index] = input;
        self.nodes[index].id = index + 1;
        self.tokens[index] = token;
        self.keys[index] = key;
        self.length += 1;
        return @intCast(index);
    }
};
/// Settings tokens are hit positions, which scrolling shifts; the focus
/// follows the hit's target, which stays with its control.
fn settingsKey(target: anytype) u64 {
    const payload: u64 = switch (target) {
        .section => |section| @intFromEnum(section),
        .search, .close => 0,
        .row, .value, .field, .reset => |index| index,
        .chip => |chip| @as(u64, chip.row) << 8 | chip.index,
        .step => |step| @as(u64, step.row) << 8 | @intFromEnum(step.step),
        .item => |item| @as(u64, item.row) << 32 | item.index,
        .group_button => |group| @as(u64, group.row) << 8 | @intFromEnum(group.button),
    };
    return (@as(u64, @intFromEnum(std.meta.activeTag(target))) + 1) << 56 | payload;
}
/// The chip list of a row; no hit target is a row's chip list.
fn settingsGroupKey(row: u16) u64 {
    return @as(u64, 0xff) << 56 | row;
}
fn dipRect(rect: d2d.Rect, popup: w32.RECT, scale: f32) uia.Rect {
    return .{ .x = @as(f64, @floatFromInt(popup.left)) + @as(f64, rect.x * scale), .y = @as(f64, @floatFromInt(popup.top)) + @as(f64, rect.y * scale), .width = @max(0, rect.w * scale), .height = @max(0, rect.h * scale) };
}
fn isTopmost(hwnd: w32.HWND) bool {
    return @as(usize, @bitCast(w32.GetWindowLongPtrW(hwnd, w32.GWL_EXSTYLE))) & w32.WS_EX_TOPMOST != 0;
}
fn unionRect(previous: ?uia.Rect, next: uia.Rect) uia.Rect {
    const old = previous orelse return next;
    const x = @min(old.x, next.x);
    const y = @min(old.y, next.y);
    return .{ .x = x, .y = y, .width = @max(old.x + old.width, next.x + next.width) - x, .height = @max(old.y + old.height, next.y + next.height) - y };
}

/// Resolve a native popup owner to a currently attached GUI object, never a
/// cached HWND-as-pointer. No terminal contents or renderer mutex are touched.
pub fn ownerAttachment(app: *App, hwnd: w32.HWND) ?refs.Attachment {
    for (app.windows.items) |window| if (attachmentInWindow(window, hwnd)) |attachment| return attachment;
    if (app.quick_terminal) |quick| if (attachmentInWindow(quick.window, hwnd)) |attachment| return attachment;
    return null;
}
pub fn attachmentAlive(app: *App, attachment: refs.Attachment) bool {
    return switch (attachment.object.kind) {
        .window => app.resolveWindowView(attachment) != null,
        .surface => app.resolvePaneView(attachment) != null,
        .tab => app.resolveTabView(attachment) != null,
    };
}
fn attachmentInWindow(window: *Window, hwnd: w32.HWND) ?refs.Attachment {
    if (window.closing) return null;
    if (window.hwnd == hwnd and window.ui_attachment.isValid()) return window.ui_attachment;
    for (window.tab_trees[0..window.tab_count]) |*tree| {
        var iterator = tree.iterator();
        while (iterator.next()) |entry| {
            if (entry.view.nativeHandle() == hwnd and entry.view.attachment().isValid()) return entry.view.attachment();
        }
    }
    return null;
}
