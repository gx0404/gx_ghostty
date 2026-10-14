//! GUI-only remote interactions. Requests retain value identities and owned
//! bytes. A queued action is never reported as successfully performed.
const Self = @This();
const std = @import("std");
const App = @import("App.zig");
const RemotePane = @import("RemotePane.zig");
const Pane = @import("Pane.zig");
const Snapshot = @import("PaneSnapshot.zig");
const input = @import("../../input.zig");
const protocol = @import("../../gx/remote_protocol.zig");
const refs = @import("../../gx/ui_ref.zig");
const route = @import("../../gx/remote_binding.zig");
const Dialogs = @import("ui/Dialogs.zig");
const SearchBar = @import("ui/SearchBar.zig");
const clipboard = @import("clipboard.zig");
const w32 = @import("win32.zig");
const Action = input.Binding.Action;
const open_url = @import("open_url.zig");
const i18n = @import("../../gx/i18n.zig");
const url_policy = @import("../../gx/url_policy.zig");
const Popup = @import("ui/Popup.zig");
const d2d = @import("ui/d2d.zig");
const style = @import("ui/style.zig");
const log = std.log.scoped(.win32_remote);

pub const Pending = struct { transaction: u64, generation: u64, origin: ?protocol.ActionRequest = null, aggregate: ?u64 = null, ui_performed: bool = false };
accessibility: @import("ui/uia_remote.zig").Bridge = .{},
search_bar: SearchBar = .{},
search_confirmed: bool = false,
visible_text: []const u8 = "",
keybind_text: []const u8 = "",
keybind_set: @import("../../config/Config.zig").Keybinds = .{},
keybind_arena: ?std.heap.ArenaAllocator = null,
keybind_ready: bool = false,
text_truncated: bool = false,
keybind_truncated: bool = false,
config_generation: u64 = 1,
next_transaction: u64 = 0,
text_transaction: ?u64 = null,
keybind_transaction: ?u64 = null,
consents: [8]?struct { transaction: u64, attachment: refs.Attachment } = @splat(null),
pending: [32]?Pending = @splat(null),
last_action_performed: ?bool = null,
url_requests: [8]?struct { completion: *open_url.Tracked, result: protocol.ActionResult, attachment: refs.Attachment } = @splat(null),
path_quoting: @import("../../gx/path_quote.zig").Style = .windows,
inspector_popup: Popup = .{},
inspector_text: []const u8 = "",
inspector_active: bool = false,
inspector_paused: bool = false,
inspector_truncated: bool = false,
inspector_scroll: f32 = 0,
inspector_pending: [8]?struct { transaction: u64, generation: u64, aggregate: ?u64, command: protocol.InspectorCommand, attachment: refs.Attachment, ui_performed: bool = false } = @splat(null),
inspector_refresh_at: u64 = 0,
runtime: @import("RemoteRuntimeUi.zig") = .{},

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.runtime.deinit();
    for (self.url_requests) |entry| if (entry) |request| request.completion.release();
    self.accessibility.deinit();
    self.search_bar.deinit();
    self.inspector_popup.destroy();
    if (self.inspector_text.len != 0) alloc.free(self.inspector_text);
    if (self.visible_text.len != 0) alloc.free(self.visible_text);
    if (self.keybind_text.len != 0) alloc.free(self.keybind_text);
    if (self.keybind_arena) |*arena| arena.deinit();
    self.* = .{};
}
fn transaction(self: *Self) !u64 {
    self.next_transaction = std.math.add(u64, self.next_transaction, 1) catch return error.Exhausted;
    return self.next_transaction;
}
fn current(pane: *RemotePane, lease: protocol.Lease) bool {
    return pane.ready() and !pane.input_suspended and pane.gate.lease != null and std.meta.eql(pane.gate.lease.?, lease);
}
fn reserve(self: *Self, origin: ?protocol.ActionRequest) !u64 {
    for (&self.pending) |*slot| if (slot.* == null) {
        const id = try self.transaction();
        slot.* = .{ .transaction = id, .generation = self.config_generation, .origin = origin };
        return id;
    };
    return error.QueueFull;
}
fn cancel(self: *Self, id: u64) void {
    for (&self.pending) |*slot| if (slot.*) |value| if (value.transaction == id) {
        slot.* = null;
        return;
    };
}
pub fn sendAction(self: *Self, pane: *RemotePane, action: Action, origin: ?protocol.ActionRequest) !void {
    const lease = pane.gate.lease orelse return error.InputDisabled;
    if (!current(pane, lease)) return error.InputDisabled;
    const id = try self.reserve(origin);
    errdefer self.cancel(id);
    if (action == .end_search) {
        for (&self.pending) |*slot| if (slot.*) |*pending| if (pending.transaction == id) {
            pending.ui_performed = self.search_bar.active;
        };
        self.search_bar.onSearchEnded();
        self.search_confirmed = false;
    }
    var text: [1024]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&text, "{f}", .{action});
    _ = try pane.app.remote.sendToSource(pane.source_reference, .{ .apply_action = .{ .surface = pane.source_reference, .lease = lease, .transaction = id, .config_generation = self.config_generation, .action = try protocol.ActionText.init(encoded) } });
    self.last_action_performed = null;
}
fn attachAggregate(self: *Self, id: u64, aggregate: u64) void {
    for (&self.pending) |*slot| if (slot.*) |*pending| if (pending.transaction == id) {
        pending.aggregate = aggregate;
        if (@import("remote_test.zig").enabled()) log.info("remote action aggregate attached transaction={} aggregate={} generation={}", .{ id, aggregate, pending.generation });
        return;
    };
}
/// Null means a source result is still outstanding; false is an actual refusal.
pub fn performRequest(self: *Self, pane: *RemotePane, action: Action, aggregate: u64, request: protocol.ActionRequest) !?bool {
    if (!pane.ready()) return false;
    switch (action) {
        .inspector => |mode| return try self.inspectorAction(pane, mode, aggregate),
        .search => {
            const app = pane.app;
            const reference = pane.ui_reference;
            const previous = self.next_transaction;
            if (!try self.performBindingAction(pane, action)) return false;
            const live = app.resolveRemote(reference) orelse return false;
            if (live.ui.next_transaction == previous) try live.ui.sendAction(live, action, null);
            live.ui.attachAggregate(live.ui.next_transaction, aggregate);
            return null;
        },
        .paste_from_clipboard, .paste_from_selection => {
            try self.pasteClipboard(pane, null, pasteParent(request, pane.source_reference, pane.gate.lease, self.config_generation));
            self.attachAggregate(self.next_transaction, aggregate);
            return null;
        },
        .copy_to_clipboard, .copy_url_to_clipboard, .search_selection, .set_surface_title, .write_scrollback_file, .write_screen_file, .write_selection_file => {
            try self.sendAction(pane, action, null);
            self.attachAggregate(self.next_transaction, aggregate);
            return null;
        },
        else => {},
    }
    if (route.placement(action) == .source or action == .end_search) {
        try self.sendAction(pane, action, null);
        self.attachAggregate(self.next_transaction, aggregate);
        return null;
    }
    return try self.performBindingAction(pane, action);
}
pub fn disconnect(self: *Self, app: *App) void {
    const pane: *RemotePane = @alignCast(@fieldParentPtr("ui", self));
    app.remote.cancelPasteFanouts(pane.ui_reference);
    self.accessibility.hide();
    self.inspector_popup.hide();
    self.inspector_active = false;
    for (&self.inspector_pending) |*slot| if (slot.*) |pending| {
        if (pending.aggregate) |aggregate| app.remote.completeFanout(aggregate, false);
        slot.* = null;
    };
    for (&self.pending) |*slot| if (slot.*) |pending| {
        if (pending.aggregate) |aggregate| app.remote.completeFanout(aggregate, false);
        slot.* = null;
    };
    self.consents = @splat(null);
    self.text_transaction = null;
    self.keybind_transaction = null;
}
pub fn performBindingAction(self: *Self, pane: *RemotePane, action: Action) !bool {
    if (!pane.ready()) return false;
    switch (action) {
        .inspector => |mode| return (try self.inspectorAction(pane, mode, null)) orelse false,
        .paste_from_clipboard, .paste_from_selection => {
            try self.pasteClipboard(pane, null, null);
            return false;
        },
        .close_surface => {
            _ = self.requestCloseFromOwner(pane, false);
            return false;
        },
        .start_search => {
            const app = pane.app;
            const reference = pane.ui_reference;
            self.search_bar.bindRemote(pane);
            self.search_confirmed = false;
            self.search_bar.setActive(true, "");
            const live = app.resolveRemote(reference) orelse return false;
            if (live.ui.search_bar.active) try live.ui.sendAction(live, .{ .search = "" }, null);
            return live.ui.search_bar.active;
        },
        .search => |needle| {
            const app = pane.app;
            const reference = pane.ui_reference;
            const owned = try app.core_app.alloc.dupeZ(u8, needle);
            defer app.core_app.alloc.free(owned);
            self.search_bar.bindRemote(pane);
            self.search_confirmed = false;
            self.search_bar.setActive(true, owned);
            return if (app.resolveRemote(reference)) |live| live.ui.search_bar.active else false;
        },
        .end_search, .copy_to_clipboard, .copy_url_to_clipboard, .search_selection, .set_surface_title, .write_scrollback_file, .write_screen_file, .write_selection_file => {
            try self.sendAction(pane, action, null);
            return false;
        },
        .copy_title_to_clipboard => {
            const text = pane.getTitle() orelse return false;
            const request = try pane.app.core_app.alloc.create(protocol.ClipboardRequest);
            defer pane.app.core_app.alloc.destroy(request);
            request.* = .{ .surface = pane.source_reference, .lease = pane.gate.lease orelse return false, .transaction = try self.transaction(), .kind = .write, .has_text = true, .text_len = @intCast(text.len), .data = try protocol.SnapshotText.init(text) };
            return try writeClipboard(pane.app, pane.hwnd, request);
        },
        else => {},
    }
    if (route.placement(action) == .target) return pane.parent_window.performUiAction(pane.ui_reference, action, .{});
    try self.sendAction(pane, action, null);
    return false;
}
pub fn dismissSearch(self: *Self, pane: *RemotePane) void {
    if (!self.search_bar.active) return;
    self.search_bar.bindRemote(pane);
    self.search_bar.setActive(false, "");
}

/// Poll worker completions at the outer GUI boundary. Enqueuing the shell
/// request cannot complete a binding continuation.
pub fn drain(self: *Self, pane: *RemotePane) void {
    for (&self.url_requests) |*entry| if (entry.*) |request| {
        const performed = request.completion.result() orelse continue;
        var result = request.result;
        result.performed = performed and current(pane, result.lease) and pane.ui_attachment.matches(request.attachment) and self.config_generation == result.config_generation;
        pane.app.remote.postToSource(result.surface, .{ .ui_event_result = result }) catch |err| {
            if (err == error.QueueFull) continue;
        };
        request.completion.release();
        entry.* = null;
    };
    const pending = for (self.inspector_pending) |entry| {
        if (entry != null) break true;
    } else false;
    if (self.inspector_active and pane.visible and !self.inspector_popup.visible and !pending) {
        _ = self.showInspector(pane, false) catch false;
    }
    if (self.inspector_active and pane.visible and self.inspector_popup.visible and self.inspector_refresh_at <= GetTickCount64()) {
        if (!pending) self.inspectorCommand(pane, .refresh, null, false) catch {};
        self.inspector_refresh_at = GetTickCount64() + 500;
    }
}

pub fn quoting(self: *const Self) @import("../../gx/path_quote.zig").Style {
    return self.path_quoting;
}

fn inspectorAction(self: *Self, pane: *RemotePane, mode: Action.InspectorMode, aggregate: ?u64) !?bool {
    const opening = switch (mode) {
        .show => true,
        .hide => false,
        .toggle => !self.inspector_active,
    };
    if (opening == self.inspector_active) return false;
    try self.inspectorCommand(pane, if (opening) .open else .close, aggregate, self.inspector_popup.visible);
    return null;
}

fn inspectorCommand(self: *Self, pane: *RemotePane, command: protocol.InspectorCommand, aggregate: ?u64, ui_performed: bool) !void {
    const lease = pane.gate.lease orelse return error.InputDisabled;
    if (!current(pane, lease)) return error.InputDisabled;
    const slot = for (&self.inspector_pending) |*entry| {
        if (entry.* == null) break entry;
    } else return error.QueueFull;
    const id = try self.transaction();
    try pane.app.remote.postToSource(pane.source_reference, .{ .inspector_request = .{ .surface = pane.source_reference, .lease = lease, .transaction = id, .config_generation = self.config_generation, .command = command } });
    slot.* = .{ .transaction = id, .generation = self.config_generation, .aggregate = aggregate, .command = command, .attachment = pane.ui_attachment, .ui_performed = ui_performed };
}

fn showInspector(self: *Self, pane: *RemotePane, activate: bool) !bool {
    const factory = pane.app.uiFactory() orelse return false;
    const owner = pane.parent_window.hwnd orelse return false;
    if (self.inspector_popup.owner != owner) self.inspector_popup.destroy();
    try self.inspector_popup.create(pane.app.hinstance, owner, factory, .{ .activate = true, .dismiss_on_outside_click = false, .close_owner_on_close = false, .accessible_name = i18n.tr("Terminal Inspector") }, .{ .ctx = pane, .paint = inspectorPaint, .key = inspectorKey, .mouse = inspectorMouse, .dismissed = inspectorDismissed });
    self.inspector_popup.setOwnerScale(pane.scale);
    self.inspector_popup.applyTheme(style.Tokens.fromConfig(&pane.app.config));
    var area: w32.RECT = undefined;
    if (w32.GetWindowRect(owner, &area) == 0) return false;
    const width: i32 = @intFromFloat(760 * pane.scale);
    const height: i32 = @intFromFloat(540 * pane.scale);
    const left = area.left + @divTrunc(area.right - area.left - width, 2);
    const top = area.top + @divTrunc(area.bottom - area.top - height, 2);
    self.inspector_popup.options.activate = activate;
    self.inspector_popup.show(.{ .left = left, .top = top, .right = left + width, .bottom = top + height });
    self.inspector_popup.options.activate = true;
    return self.inspector_popup.visible;
}

fn inspectorPaint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const pane: *RemotePane = @ptrCast(@alignCast(ctx));
    const self = &pane.ui;
    const tokens = style.Tokens.fromConfig(&pane.app.config);
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(popup.hwnd orelse return, &rect) == 0) return;
    const width = @as(f32, @floatFromInt(rect.right)) / popup.scale();
    const height = @as(f32, @floatFromInt(rect.bottom)) / popup.scale();
    canvas.fillRect(.{ .x = 0, .y = 0, .w = width, .h = height }, tokens.background);
    canvas.drawText(i18n.tr("Terminal Inspector"), .{ .x = 16, .y = 12, .w = width - 32, .h = 28 }, style.type_ramp.subtitle.text(tokens.text));
    const labels = [_][]const u8{ i18n.tr("Refresh"), i18n.tr("Clear"), if (self.inspector_paused) i18n.tr("Resume IO") else i18n.tr("Pause IO"), i18n.tr("Export") };
    for (labels, 0..) |label, index| canvas.drawText(label, .{ .x = 16 + @as(f32, @floatFromInt(index)) * 112, .y = 48, .w = 104, .h = 28 }, style.type_ramp.body.text(tokens.text));
    if (self.inspector_truncated) canvas.drawText(i18n.tr("Snapshot truncated"), .{ .x = 16, .y = 80, .w = width - 32, .h = 24 }, style.type_ramp.body.text(tokens.text));
    var lines = std.mem.splitScalar(u8, self.inspector_text, '\n');
    var line: usize = 0;
    var y: f32 = 108;
    const skip: usize = @intFromFloat(@max(0, self.inspector_scroll));
    while (lines.next()) |text| : (line += 1) {
        if (line < skip) continue;
        if (y + 20 > height) break;
        canvas.drawText(text, .{ .x = 16, .y = y, .w = width - 32, .h = 20 }, style.type_ramp.body.text(tokens.text));
        y += 20;
    }
}

fn inspectorKey(ctx: *anyopaque, _: *Popup, key: Popup.Key) bool {
    const pane: *RemotePane = @ptrCast(@alignCast(ctx));
    if (key.vk == w32.VK_F5) {
        pane.ui.inspectorCommand(pane, .refresh, null, false) catch {};
        return true;
    }
    return false;
}

fn inspectorMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const pane: *RemotePane = @ptrCast(@alignCast(ctx));
    if (event.kind == .wheel) {
        const maximum = @as(f32, @floatFromInt(std.mem.count(u8, pane.ui.inspector_text, "\n")));
        pane.ui.inspector_scroll = std.math.clamp(pane.ui.inspector_scroll - event.wheel * 3, 0, maximum);
        popup.invalidate();
        return;
    }
    if (event.kind != .up or event.button != .left or event.pos.y < 48 or event.pos.y >= 80 or event.pos.x < 16 or event.pos.x >= 464) return;
    const index: usize = @intFromFloat((event.pos.x - 16) / 112);
    const command: protocol.InspectorCommand = switch (index) {
        0 => .refresh,
        1 => .clear,
        2 => if (pane.ui.inspector_paused) .@"resume" else .pause,
        3 => .export_io,
        else => return,
    };
    pane.ui.inspectorCommand(pane, command, null, false) catch {};
}

fn inspectorDismissed(ctx: *anyopaque, _: *Popup, _: Popup.DismissReason) void {
    const pane: *RemotePane = @ptrCast(@alignCast(ctx));
    if (pane.ui.inspector_active) pane.ui.inspectorCommand(pane, .close, null, true) catch {};
}
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn saveInspectorIo(app: *App, pane: *RemotePane, contents: []const u8) !bool {
    const reference = pane.ui_reference;
    const attachment = pane.ui_attachment;
    const lease = pane.gate.lease orelse return false;
    const generation = pane.ui.config_generation;
    const owned = try app.core_app.alloc.dupe(u8, contents);
    defer app.core_app.alloc.free(owned);
    const path = try Dialogs.saveFilePath(app.core_app.alloc, pane.parent_window.hwnd, .{
        .title = i18n.tr("Export Terminal IO Events"),
        .default_name = "ghostty-terminal-io.txt",
        .default_ext = "txt",
        .filters = &.{ .{ .label = i18n.tr("Text files (*.txt)"), .pattern = "*.txt" }, .{ .label = i18n.tr("All files (*.*)"), .pattern = "*.*" } },
    }) orelse return false;
    defer app.core_app.alloc.free(path);
    const live = app.resolveRemote(reference) orelse return false;
    if (!current(live, lease) or !live.ui_attachment.matches(attachment) or live.ui.config_generation != generation) return false;
    const io = @import("../../global.zig").io();
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(owned);
    try writer.interface.flush();
    return true;
}

fn uiEvent(app: *App, pane: *RemotePane, request: *const protocol.UiEvent) !void {
    const reference = pane.ui_reference;
    const attachment = pane.ui_attachment;
    const owner = pane.parent_window.hwnd;
    var result: protocol.ActionResult = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation, .performed = false };
    switch (request.event) {
        .runtime => |*event| result.performed = try pane.ui.runtime.handle(app, pane, event.*),
        .present_terminal => result.performed = app.presentReference(reference),
        .resize_window => |size| result.performed = pane.parent_window.resizeForSurface(pane, .{ .width = size.width, .height = size.height }),
        .open_url => |*value| {
            const alloc = app.core_app.alloc;
            var host: [192]u8 = undefined;
            const options: url_policy.Context = .{ .host_name = hostName(&host) };
            const url = try alloc.dupe(u8, value.url.slice());
            defer alloc.free(url);
            var path: ?[]u8 = null;
            defer if (path) |owned| alloc.free(owned);
            if (value.kind == .osc8) switch (url_policy.decide(url, options)) {
                .allow => {},
                .deny => |reason| {
                    pane.parent_window.showNotice(.{ .severity = .warning, .title = i18n.tr(url_policy.msg.denied_title), .body = i18n.trRuntime(reason.msgid()) }, null);
                    try app.remote.postToSource(result.surface, .{ .ui_event_result = result });
                    return;
                },
                .confirm => |reason| {
                    var body: std.Io.Writer.Allocating = .init(alloc);
                    defer body.deinit();
                    try i18n.format(&body.writer, i18n.trRuntime(reason.msgid()), .{ .scheme = url_policy.scheme(url) orelse "" });
                    try body.writer.writeAll("\n\n");
                    try url_policy.writeDisplay(&body.writer, url);
                    if (Dialogs.confirm(owner, body.written(), i18n.tr(url_policy.msg.confirm_title)) != .accept) {
                        try app.remote.postToSource(result.surface, .{ .ui_event_result = result });
                        return;
                    }
                    path = try url_policy.filePath(alloc, url, options);
                },
            };
            const live = app.resolveRemote(reference) orelse {
                try app.remote.postToSource(result.surface, .{ .ui_event_result = result });
                return;
            };
            if (current(live, result.lease) and live.ui_attachment.matches(attachment) and live.ui.config_generation == result.config_generation) {
                for (&live.ui.url_requests) |*slot| if (slot.* == null) {
                    slot.* = .{ .completion = try open_url.openTracked(path orelse url), .result = result, .attachment = attachment };
                    return;
                };
            }
        },
        .desktop_notification => |*value| {
            if (try app.shell.notifyRemote(app, reference, value.title.slice(), value.body.slice(), result)) |performed| result.performed = performed else return;
        },
        .export_terminal_io => |*value| {
            const contents = try app.core_app.alloc.dupe(u8, value.slice());
            defer app.core_app.alloc.free(contents);
            const path = try Dialogs.saveFilePath(app.core_app.alloc, owner, .{
                .title = i18n.tr("Export Terminal IO Events"),
                .default_name = "ghostty-terminal-io.txt",
                .default_ext = "txt",
                .filters = &.{ .{ .label = i18n.tr("Text files (*.txt)"), .pattern = "*.txt" }, .{ .label = i18n.tr("All files (*.*)"), .pattern = "*.*" } },
            });
            if (path) |chosen| {
                defer app.core_app.alloc.free(chosen);
                if (app.resolveRemote(reference)) |live| if (current(live, result.lease) and live.ui_attachment.matches(attachment) and live.ui.config_generation == result.config_generation) {
                    const io = @import("../../global.zig").io();
                    var file = try std.Io.Dir.createFileAbsolute(io, chosen, .{ .truncate = true });
                    defer file.close(io);
                    var buffer: [4096]u8 = undefined;
                    var writer = file.writer(io, &buffer);
                    try writer.interface.writeAll(contents);
                    try writer.interface.flush();
                    result.performed = true;
                };
            }
        },
        .start_search => |*value| result.performed = try pane.ui.performBindingAction(pane, .{ .search = value.slice() }),
    }
    try app.remote.postToSource(result.surface, .{ .ui_event_result = result });
}

fn hostName(buffer: *[192]u8) []const u8 {
    var wide: [64]u16 = undefined;
    var len: u32 = wide.len;
    if (GetComputerNameExW(1, &wide, &len) == 0) return "";
    const count = std.unicode.utf16LeToUtf8(buffer, wide[0..@min(len, wide.len)]) catch return "";
    return buffer[0..count];
}
extern "kernel32" fn GetComputerNameExW(c_int, [*]u16, *u32) callconv(.winapi) i32;
pub fn queryResult(self: *const Self) isize {
    return if (self.last_action_performed) |performed| (if (performed) @as(isize, 1) else 2) else 0;
}
pub fn requestCloseFromOwner(_: *Self, pane: *RemotePane, confirmed: bool) bool {
    const lease = pane.gate.lease orelse return false;
    if (!current(pane, lease)) return false;
    pane.app.remote.postToSource(pane.source_reference, .{ .close_request = .{ .surface = pane.source_reference, .lease = lease, .confirmed = confirmed } }) catch return false;
    return true;
}
pub fn requestText(self: *Self, pane: *RemotePane) !void {
    if (self.text_transaction != null) return;
    const lease = pane.gate.lease orelse return error.InputDisabled;
    if (!current(pane, lease)) return error.InputDisabled;
    const id = try self.transaction();
    _ = try pane.app.remote.sendToSource(pane.source_reference, .{ .text_snapshot = .{ .surface = pane.source_reference, .lease = lease, .transaction = id, .kind = .screen } });
    self.text_transaction = id;
}
pub fn requestKeybinds(self: *Self, pane: *RemotePane) !void {
    if (self.keybind_transaction != null) return;
    const lease = pane.gate.lease orelse return error.InputDisabled;
    if (!current(pane, lease)) return error.InputDisabled;
    const id = try self.transaction();
    _ = try pane.app.remote.sendToSource(pane.source_reference, .{ .keybind_snapshot = .{ .surface = pane.source_reference, .lease = lease, .transaction = id } });
    self.keybind_transaction = id;
}
fn pasteParent(request: protocol.ActionRequest, source: refs.Reference, lease: ?protocol.Lease, generation: u64) ?protocol.PasteParent {
    const current_lease = lease orelse return null;
    if (!request.surface.matches(source) or !std.meta.eql(request.lease, current_lease) or request.config_generation != generation) return null;
    return .{ .transaction = request.transaction, .config_generation = request.config_generation };
}

fn pasteClipboard(self: *Self, pane: *RemotePane, origin: ?protocol.ActionRequest, parent: ?protocol.PasteParent) !void {
    if (!clipboard.open(pane.hwnd)) return error.ClipboardBusy;
    const text = blk: {
        defer _ = w32.CloseClipboard();
        const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return error.EmptyClipboard;
        if (w32.GlobalSize(handle) > protocol.max_paste_bytes * 2 + 2) return error.InvalidPaste;
        break :blk try clipboard.unicodeText(pane.app.core_app.alloc, handle) orelse return error.EmptyClipboard;
    };
    defer pane.app.core_app.alloc.free(text);
    try self.pasteWithParent(pane, text, origin, parent);
}
pub fn paste(self: *Self, pane: *RemotePane, text: []const u8, origin: ?protocol.ActionRequest) !void {
    const parent = if (origin) |request| pasteParent(request, pane.source_reference, pane.gate.lease, self.config_generation) else null;
    return self.pasteWithParent(pane, text, origin, parent);
}
fn pasteWithParent(self: *Self, pane: *RemotePane, text: []const u8, origin: ?protocol.ActionRequest, parent: ?protocol.PasteParent) !void {
    if (text.len == 0 or text.len > protocol.max_paste_bytes) return error.InvalidPaste;
    const lease = pane.gate.lease orelse return error.InputDisabled;
    if (!current(pane, lease)) return error.InputDisabled;
    const id = try self.reserve(origin);
    errdefer self.cancel(id);
    try pane.app.remote.queuePaste(pane, id, text, parent);
    if (@import("remote_test.zig").enabled()) log.info("remote paste admitted surface={x} transfer={} parent={any} generation={}", .{ pane.source_reference.id, id, if (parent) |value| @as(?u64, value.transaction) else null, self.config_generation });
    pane.clearBellBorder();
    self.last_action_performed = null;
}
fn reply(app: *App, source: refs.Reference, request: protocol.ActionRequest, performed: bool) !void {
    try app.remote.postToSource(source, .{ .ui_action_result = .{ .surface = source, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation, .performed = performed } });
}
fn clipboardRequest(app: *App, pane: *RemotePane, request: *const protocol.ClipboardRequest) !void {
    const reference = pane.ui_reference;
    const attachment = pane.ui_attachment;
    const owner = pane.parent_window.hwnd;
    const result = try app.core_app.alloc.create(protocol.ClipboardResult);
    defer app.core_app.alloc.destroy(result);
    result.* = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .performed = false };
    if (request.confirmed) {
        var consent = false;
        for (&pane.ui.consents) |*slot| if (slot.*) |value| if (value.transaction == request.transaction) {
            slot.* = null;
            consent = value.attachment.matches(attachment);
            break;
        };
        if (!consent) {
            try app.remote.postToSource(request.surface, .{ .clipboard_result = result.* });
            return;
        }
    }
    if (request.kind != .write) readClipboard(app, pane.hwnd, request.kind == .list, result) catch {};
    const preview = if (request.kind == .write) (if (request.has_text) request.plain() else request.html()) else result.plain();
    const accepted = !request.prompt or Dialogs.confirmClipboardAccess(owner, if (request.kind == .write) .write else .read, preview) == .accept;
    const live = app.resolveRemote(reference);
    const authorized = if (live) |value| accepted and value.ui_attachment.matches(attachment) and current(value, request.lease) else false;
    if (!authorized) {
        result.performed = false;
    } else if (request.kind == .write) {
        result.performed = writeClipboard(app, live.?.hwnd, request) catch false;
    }
    try app.remote.postToSource(request.surface, .{ .clipboard_result = result.* });
}
fn readClipboard(app: *App, owner: ?w32.HWND, list: bool, result: *protocol.ClipboardResult) !void {
    if (!clipboard.open(owner)) return error.ClipboardBusy;
    defer _ = w32.CloseClipboard();
    const html_format = clipboard.htmlFormat();
    result.has_text = w32.IsClipboardFormatAvailable(w32.CF_UNICODETEXT) != 0;
    result.has_html = html_format != 0 and w32.IsClipboardFormatAvailable(html_format) != 0;
    if (list) {
        result.performed = true;
        return;
    }
    if (result.has_text) {
        const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return error.Unavailable;
        if (w32.GlobalSize(handle) > protocol.SnapshotText.capacity * 2 + 2) return error.LimitExceeded;
        const text = try clipboard.unicodeText(app.core_app.alloc, handle) orelse return error.Unavailable;
        defer app.core_app.alloc.free(text);
        result.data = try protocol.SnapshotText.init(text);
        result.text_len = @intCast(text.len);
    }
    if (result.has_html) {
        const handle = w32.GetClipboardData(html_format) orelse return error.Unavailable;
        const raw = w32.GlobalLock(handle) orelse return error.Unavailable;
        defer _ = w32.GlobalUnlock(handle);
        const size = w32.GlobalSize(handle);
        if (size > protocol.SnapshotText.capacity + 1024) return error.LimitExceeded;
        const bytes = raw[0 .. std.mem.indexOfScalar(u8, raw[0..size], 0) orelse size];
        const fragment = htmlFragment(bytes) orelse return error.InvalidHtml;
        if (!std.unicode.utf8ValidateSlice(fragment) or result.data.len + fragment.len > protocol.SnapshotText.capacity) return error.LimitExceeded;
        @memcpy(result.data.items[result.data.len..][0..fragment.len], fragment);
        result.data.len += @intCast(fragment.len);
    }
    result.performed = result.has_text or result.has_html;
}
fn htmlFragment(bytes: []const u8) ?[]const u8 {
    const begin = htmlOffset(bytes, "StartFragment:") orelse return null;
    const end = htmlOffset(bytes, "EndFragment:") orelse return null;
    if (begin > end or end > bytes.len) return null;
    return bytes[begin..end];
}
fn htmlOffset(bytes: []const u8, name: []const u8) ?usize {
    const at = (std.mem.indexOf(u8, bytes, name) orelse return null) + name.len;
    const suffix = bytes[at..];
    const end = std.mem.indexOfAny(u8, suffix, "\r\n") orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, suffix[0..end], " "), 10) catch null;
}
fn writeClipboard(app: *App, owner: ?w32.HWND, request: *const protocol.ClipboardRequest) !bool {
    var items: [2]clipboard.Item = undefined;
    var count: usize = 0;
    var consumed = false;
    defer if (!consumed) for (items[0..count]) |item| {
        _ = w32.GlobalFree(item.data);
    };
    if (request.has_text or request.has_html) {
        const text = if (request.has_text) request.plain() else request.html();
        const block = try clipboard.unicodeTextBlock(app.core_app.alloc, text) orelse return false;
        items[count] = .{ .format = w32.CF_UNICODETEXT, .data = block };
        count += 1;
    }
    if (request.has_html) {
        const format = clipboard.htmlFormat();
        if (format == 0) return false;
        const html = try clipboard.htmlDocument(app.core_app.alloc, request.html());
        defer app.core_app.alloc.free(html);
        const block = clipboard.bytesBlock(html) orelse return false;
        items[count] = .{ .format = format, .data = block };
        count += 1;
    }
    if (count == 0) return false;
    const performed = try clipboard.setDataChecked(owner, items[0..count]);
    consumed = true;
    return performed;
}
pub fn handlePacket(app: *App, pane: *RemotePane, packet: *const protocol.Packet) !bool {
    if (!std.meta.eql(pane.ticket, packet.ticket) or packet.sender_epoch != pane.source_reference.epoch) return error.InvalidIdentity;
    const self = &pane.ui;
    switch (packet.body) {
        .ui_event => |*request| {
            if (!request.surface.matches(pane.source_reference) or !current(pane, request.lease) or request.config_generation != self.config_generation) return error.InvalidIdentity;
            uiEvent(app, pane, request) catch {
                try app.remote.postToSource(request.surface, .{ .ui_event_result = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation, .performed = false } });
            };
        },
        .inspector_result => |*result| {
            if (!result.surface.matches(pane.source_reference) or !current(pane, result.lease)) return error.InvalidIdentity;
            const pending = for (&self.inspector_pending) |*slot| {
                if (slot.*) |value| if (value.transaction == result.transaction) {
                    slot.* = null;
                    break value;
                };
            } else return error.UnknownTransaction;
            var performed = pending.generation == result.config_generation and result.config_generation == self.config_generation and pending.command == result.command and pending.attachment.matches(pane.ui_attachment) and result.performed;
            defer if (pending.aggregate) |aggregate| app.remote.completeFanout(aggregate, performed);
            errdefer performed = false;
            const reference = pane.ui_reference;
            if (performed) switch (result.command) {
                .export_io => {
                    // A truncated log is useful for inspection, but is never
                    // silently exported as if it were the complete recording.
                    if (result.truncated) {
                        pane.parent_window.showNotice(.{ .severity = .warning, .title = i18n.tr("Snapshot truncated"), .body = i18n.tr("Clear the recording and export a smaller capture.") }, null);
                        performed = false;
                    } else performed = saveInspectorIo(app, pane, result.text.slice()) catch false;
                },
                .close => {
                    performed = pending.ui_performed or self.inspector_popup.visible;
                    self.inspector_active = false;
                    self.inspector_popup.hide();
                },
                else => {
                    const bytes = try app.core_app.alloc.dupe(u8, result.text.slice());
                    if (self.inspector_text.len != 0) app.core_app.alloc.free(self.inspector_text);
                    self.inspector_text = bytes;
                    self.inspector_active = result.active;
                    self.inspector_paused = result.paused;
                    self.inspector_truncated = result.truncated;
                    if (result.command == .open) {
                        performed = try self.showInspector(pane, true);
                        if (!performed) {
                            self.inspector_active = false;
                            self.inspectorCommand(pane, .close, null, false) catch {};
                        }
                    } else self.inspector_popup.invalidate();
                },
            };
            if (app.resolveRemote(reference)) |live| live.ui.last_action_performed = performed;
        },
        .surface_state => |state| {
            if (!state.surface.matches(pane.source_reference)) return error.InvalidIdentity;
            if (pane.closed) return true;
            if (pane.gate.lease == null or !std.meta.eql(pane.gate.lease.?, state.lease) or state.config_generation < self.config_generation) return error.InvalidIdentity;
            const title = try app.core_app.alloc.dupe(u8, state.title.slice());
            const cwd = app.core_app.alloc.dupe(u8, state.pwd.slice()) catch |err| {
                app.core_app.alloc.free(title);
                return err;
            };
            if (pane.owned_title.len != 0) app.core_app.alloc.free(pane.owned_title);
            if (pane.owned_cwd.len != 0) app.core_app.alloc.free(pane.owned_cwd);
            pane.owned_title = title;
            pane.owned_cwd = cwd;
            pane.metadata.title = try Snapshot.Title.init(state.title.slice());
            pane.metadata.cwd = try Snapshot.Title.init(state.pwd.slice());
            pane.metadata.needs_confirm = state.confirm_quit;
            pane.metadata.bell = state.bell;
            if (state.bell) _ = pane.ringBell();
            if (self.config_generation != state.config_generation) {
                self.disconnect(app);
                app.remote.discardInput(pane.source_reference, true);
                self.keybind_ready = false;
            }
            self.config_generation = state.config_generation;
            self.path_quoting = state.path_quoting;
            pane.setMouseState(state.cursor, state.mouse_visible);
            pane.metadata.selection = state.selection;
            if (state.grid_columns > 0 and state.grid_rows > 0) pane.metadata.grid = .{ .pane = pane.ui_reference, .columns = state.grid_columns, .rows = state.grid_rows };
            pane.metadata.cursor = .{ .x = state.cursor_x, .y = state.cursor_y, .width = state.cursor_width, .height = state.cursor_height, .scale = pane.scale, .cell_width = state.cell_width, .cell_height = state.cell_height, .pane_width = pane.width, .pane_height = pane.height };
            self.search_bar.bindRemote(pane);
            self.search_bar.setTotal(if (state.search_total) |value| std.math.cast(usize, value) else null);
            self.search_bar.setSelected(if (state.search_selected) |value| std.math.cast(usize, value) else null);
            if (state.search_active) self.search_confirmed = true else if (self.search_confirmed and self.search_bar.active) {
                self.search_bar.onSearchEnded();
                self.search_confirmed = false;
            }
            if (app.resolveLeaf(pane.ui_reference)) |leaf| pane.parent_window.onLeafStateChanged(leaf);
            self.accessibility.dirty();
            pane.invalidate();
        },
        .ui_action => |request| {
            if (!request.surface.matches(pane.source_reference) or !current(pane, request.lease)) return error.InvalidIdentity;
            self.config_generation = request.config_generation;
            self.last_action_performed = null;
            const action = Action.parse(request.action.slice()) catch {
                try reply(app, pane.source_reference, request, false);
                return true;
            };
            const source = pane.source_reference;
            app.remote.performUiRequest(app, pane, action, request) catch {
                try reply(app, source, request, false);
            };
        },
        .apply_action_result => |result| {
            if (!result.surface.matches(pane.source_reference) or !current(pane, result.lease)) return error.InvalidIdentity;
            for (&self.pending) |*slot| if (slot.*) |pending| if (pending.transaction == result.transaction) {
                slot.* = null;
                const performed = pending.generation == result.config_generation and (result.performed or pending.ui_performed);
                if (@import("remote_test.zig").enabled()) log.info("remote action result surface={x} transaction={} generation={} aggregate={any} performed={}", .{ result.surface.id, result.transaction, result.config_generation, pending.aggregate, performed });
                self.last_action_performed = performed;
                if (pending.aggregate) |aggregate| app.remote.completeFanout(aggregate, performed);
                if (pending.origin) |origin| try reply(app, pane.source_reference, origin, performed);
                return true;
            };
            var pending_ids: [32]u64 = @splat(0);
            for (self.pending, 0..) |entry, index| if (entry) |pending| {
                pending_ids[index] = pending.transaction;
            };
            log.warn("remote unknown action result surface={x} transaction={} generation={} issued={} pending={any}", .{ result.surface.id, result.transaction, result.config_generation, self.next_transaction, pending_ids });
            return error.UnknownTransaction;
        },
        .confirm_request => |request| {
            if (!request.surface.matches(pane.source_reference) or !current(pane, request.lease)) return error.InvalidIdentity;
            const reference = pane.ui_reference;
            const attachment = pane.ui_attachment;
            const source = pane.source_reference;
            const owner = pane.parent_window.hwnd;
            const accepted = switch (request.reason) {
                .close => Dialogs.confirmCloseSurface(owner, &.{}) == .accept,
                .paste => Dialogs.confirmUnsafePaste(owner, request.text.slice()) == .accept,
                .clipboard_read => Dialogs.confirmClipboardAccess(owner, .read, request.text.slice()) == .accept,
                .clipboard_write => Dialogs.confirmClipboardAccess(owner, .write, request.text.slice()) == .accept,
            };
            const live = app.resolveRemote(reference);
            var confirmed = if (live) |value| accepted and value.ui_attachment.matches(attachment) and current(value, request.lease) else false;
            if (confirmed and (request.reason == .clipboard_read or request.reason == .clipboard_write)) {
                const slot = for (&live.?.ui.consents) |*entry| {
                    if (entry.* == null) break entry;
                } else null;
                if (slot) |entry| entry.* = .{ .transaction = request.transaction, .attachment = attachment } else confirmed = false;
            }
            if (!confirmed and request.reason == .close) app.remote.cancelCloseWait(reference);
            try app.remote.postToSource(source, .{ .confirm_result = .{ .surface = source, .lease = request.lease, .transaction = request.transaction, .confirmed = confirmed } });
        },
        .clipboard_request => |*request| {
            if (!request.surface.matches(pane.source_reference) or !current(pane, request.lease)) return error.InvalidIdentity;
            try clipboardRequest(app, pane, request);
        },
        .text_snapshot_result => |result| {
            if (!result.surface.matches(pane.source_reference) or !current(pane, result.lease) or self.text_transaction != result.transaction) return error.InvalidIdentity;
            const bytes = try app.core_app.alloc.dupe(u8, result.text.slice());
            if (self.visible_text.len != 0) app.core_app.alloc.free(self.visible_text);
            self.visible_text = bytes;
            self.text_transaction = null;
            self.text_truncated = result.truncated;
            try self.accessibility.publish(app, pane);
        },
        .keybind_snapshot_result => |result| {
            if (!result.surface.matches(pane.source_reference) or !current(pane, result.lease) or self.keybind_transaction != result.transaction) return error.InvalidIdentity;
            var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
            errdefer arena.deinit();
            const text = try arena.allocator().dupe(u8, result.text.slice());
            const bindings = try route.readKeybindSnapshot(arena.allocator(), text);
            if (self.keybind_arena) |*old| old.deinit();
            self.keybind_arena = arena;
            self.keybind_set = bindings;
            self.keybind_ready = true;
            self.keybind_transaction = null;
            self.keybind_truncated = result.truncated;
            _ = @import("ui/Keybinds.zig").show(pane.parent_window);
        },
        .leaf_closed => |value| {
            if (!value.surface.matches(pane.source_reference)) return error.InvalidIdentity;
            pane.closed = true;
            self.disconnect(app);
            app.remote.discardInput(pane.source_reference, false);
            pane.input_suspended = true;
            pane.gate.disconnect();
            self.accessibility.hide();
            if (pane.view) |*view| {
                if (view.deinit()) |_| {
                    pane.view = null;
                } else |_| {
                    view.disconnect();
                }
            }
            pane.canvas.discardTarget();
            if (app.resolveLeaf(pane.ui_reference)) |leaf| pane.parent_window.removeLeaf(leaf);
        },
        else => return false,
    }
    return true;
}

test "remote UI pending results require their transaction and queue is bounded" {
    var state: Self = .{};
    for (0..state.pending.len) |_| _ = try state.reserve(null);
    try std.testing.expectError(error.QueueFull, state.reserve(null));
    state.cancel(999);
    try std.testing.expectError(error.QueueFull, state.reserve(null));
    state.cancel(1);
    try std.testing.expectEqual(@as(u64, 33), try state.reserve(null));
    try std.testing.expect(state.last_action_performed == null);
}

test "remote UI paste parent belongs only to its exact source lease and configuration" {
    const source: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 3, .generation = 1 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 4, .generation = 5 };
    const request: protocol.ActionRequest = .{ .surface = source, .lease = lease, .transaction = 8, .config_generation = 9, .action = try protocol.ActionText.init("paste_from_clipboard"), .all = true };
    const parent = pasteParent(request, source, lease, 9).?;
    try std.testing.expectEqual(@as(u64, 8), parent.transaction);
    try std.testing.expectEqual(@as(u64, 9), parent.config_generation);
    var foreign = source;
    foreign.id += 1;
    try std.testing.expect(pasteParent(request, foreign, lease, 9) == null);
    var replaced = lease;
    replaced.generation += 1;
    try std.testing.expect(pasteParent(request, source, replaced, 9) == null);
    try std.testing.expect(pasteParent(request, source, null, 9) == null);
    try std.testing.expect(pasteParent(request, source, lease, 10) == null);
}
