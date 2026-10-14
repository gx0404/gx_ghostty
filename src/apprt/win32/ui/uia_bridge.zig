//! GUI-side UIA snapshots and typed bindings. No terminal state or renderer
//! locks are read here; native providers never retain these GUI objects.
const std = @import("std");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
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
    focus_surface: refs.Attachment,
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
        if (window.tab_count > 0 and !minimized) {
            const focus = w32.GetFocus();
            var iterator = window.tab_trees[window.active_tab].iterator();
            while (iterator.next()) |entry| {
                const pane = entry.view.pane();
                const state = pane.snapshot();
                if (!state.ready or !state.attachment.isValid()) continue;
                const surface_hwnd = pane.nativeHandle() orelse continue;
                if (w32.IsWindowVisible_(surface_hwnd) == 0) continue;
                var pane_rect: w32.RECT = undefined;
                if (w32.GetWindowRect(surface_hwnd, &pane_rect) == 0) continue;
                _ = try builder.add(.{ .id = 0, .parent = 0, .role = .pane, .name = if (state.title.len > 0) state.title.slice() else i18n.tr("Terminal"), .bounds = screenRect(pane_rect), .focusable = true, .focused = focus == surface_hwnd }, .{ .focus_surface = state.attachment });
            }
        }
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
            .focus_surface => |attachment| {
                if (action.kind != .focus) return false;
                const pane = app.resolvePaneView(attachment) orelse return false;
                const target = pane.nativeHandle() orelse return false;
                _ = w32.SetFocus(target);
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

pub const PopupCallbacks = struct {
    context: *anyopaque,
    /// GUI only; registration is removed before the context is freed.
    is_live: *const fn (*anyopaque) bool,
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

    /// A GUI model edit invalidates all pending index-based actions immediately.
    /// The owning widget schedules publish after its new model/layout is ready.
    pub fn dirty(self: *PopupBridge) void {
        self.publisher.hide();
        self.length = 0;
        self.needs_publish = true;
    }
    pub fn hide(self: *PopupBridge) void {
        self.dirty();
        self.announcement.cancel();
        self.callbacks = null;
        self.hwnd = null;
    }
    pub fn deinit(self: *PopupBridge) void {
        self.hide();
    }
    pub fn publish(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, hwnd: w32.HWND, nodes: []const uia.NodeSpec, tokens: []const u64, callbacks: PopupCallbacks) !void {
        errdefer self.hide();
        if (!callbacks.is_live(callbacks.context) or !attachment.isValid()) return self.hide();
        if (nodes.len != tokens.len or nodes.len > self.tokens.len) return error.InvalidSnapshot;
        if (!self.needs_publish and self.hwnd == hwnd and self.publisher.current != null) return;
        var effective: [uia.max_nodes]uia.NodeSpec = undefined;
        @memcpy(effective[0..nodes.len], nodes);
        if (w32.IsWindowEnabled(hwnd) == 0) for (effective[0..nodes.len]) |*node| {
            node.enabled = false;
            if (node.patterns.window) node.window_interaction_state = 3;
        };
        try self.publisher.publish(std.heap.page_allocator, api, queue, attachment, hwnd, effective[0..nodes.len]);
        @memcpy(self.tokens[0..tokens.len], tokens);
        self.length = tokens.len;
        self.hwnd = hwnd;
        self.callbacks = callbacks;
        self.needs_publish = false;
        self.announcement.retry(&self.publisher);
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
        if (action.kind != .notification and w32.IsWindowEnabled(hwnd) == 0) return false;
        const token = self.tokens[@intCast(action.node_id - 1)];
        if (!callbacks.is_live(callbacks.context)) return false;
        if (action.kind == .notification) {
            if (!self.announcement.consume(action)) return false;
            const delivered = self.publisher.notify(action.value);
            if (!delivered) std.log.scoped(.win32_uia).warn("notification API rejected an announcement", .{});
            return delivered;
        }
        self.dirty();
        // The callback may dismiss its menu and free this bridge. No reads of
        // self/context after the operation; the App registry is removed first.
        return callbacks.action(callbacks.context, token, action);
    }

    /// Called inside MenuPopup with its actual Level. Rows already carry their
    /// pixel layout; no duplicate menu model or guessed item rectangles.
    pub fn publishMenu(self: *PopupBridge, api: *uia.Api, queue: *uia.Queue, attachment: refs.Attachment, level: anytype, callbacks: PopupCallbacks) !void {
        if (!self.needs_publish and self.publisher.current != null) return;
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
        if (!self.needs_publish and self.publisher.current != null) return;
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
        _ = try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Search"), .role = .edit, .value = value, .bounds = dipRect(palette.popup.input.field, bounds, scale), .patterns = .{ .value = true }, .read_only = false, .focusable = true, .focused = w32.GetFocus() == hwnd }, palette_filter);
        const list = try builder.add(.{ .id = 0, .parent = 0, .name = i18n.tr("Results"), .role = .list, .bounds = dipRect(view, bounds, scale), .patterns = .{ .selection = true }, .selection_required = true }, palette_list);
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
        if (!self.needs_publish and self.publisher.current != null) return false;
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
        if (!self.needs_publish and self.publisher.current != null) return;
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
        if (!self.needs_publish and self.publisher.current != null) return;
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
                    if (groups[chip.row] == null) groups[chip.row] = try builder.add(.{ .id = 0, .parent = 0, .name = row.title, .role = .list, .bounds = spec.bounds, .patterns = .{ .selection = true }, .selection_required = true, .focusable = state.container_focusable, .focused = state.container_focused }, settings_hit_base + hit_index);
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
            _ = try builder.add(spec, settings_hit_base + @as(u64, @intCast(hit_index)));
        }
        try self.publish(api, queue, attachment, hwnd, builder.nodes[0..builder.length], builder.tokens[0..builder.length], callbacks);
    }
};

pub const palette_root: u64 = 0;
pub const palette_filter: u64 = 1;
pub const palette_list: u64 = 2;
pub const palette_back: u64 = 3;
pub const palette_row_base: u64 = 1 << 32;
pub const dialog_action_base: u64 = 1 << 32;
pub const settings_hit_base: u64 = 1 << 32;
pub const settings_container: u64 = std.math.maxInt(u64);
pub const ControlState = struct { enabled: bool = true, focused: bool = false, focusable: bool = false, container_focusable: bool = false, container_focused: bool = false };
const PopupBuilder = struct {
    nodes: [uia.max_nodes]uia.NodeSpec = undefined,
    tokens: [uia.max_nodes]u64 = undefined,
    length: usize = 0,
    fn add(self: *PopupBuilder, input: uia.NodeSpec, token: u64) !u16 {
        if (self.length == self.nodes.len) return error.TooManyNodes;
        const index = self.length;
        self.nodes[index] = input;
        self.nodes[index].id = index + 1;
        self.tokens[index] = token;
        self.length += 1;
        return @intCast(index);
    }
};
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
