//! Remote HWND accessibility is an owned snapshot; MTA providers never borrow
//! a RemotePane, terminal, or shared frame mapping.
const std = @import("std");
const App = @import("../App.zig");
const RemotePane = @import("../RemotePane.zig");
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const w32 = @import("../win32.zig");
const refs = @import("../../../gx/ui_ref.zig");
const protocol = @import("../../../gx/remote_protocol.zig");

const ViewKey = struct {
    source: refs.Reference,
    attachment: refs.Attachment,
    lease: protocol.Lease,
    hwnd: w32.HWND,

    fn matches(self: ViewKey, other: ViewKey) bool {
        return self.source.matches(other.source) and self.attachment.matches(other.attachment) and std.meta.eql(self.lease, other.lease) and self.hwnd == other.hwnd;
    }
};

pub const Bridge = struct {
    publisher: uia.Publisher = .{},
    key: ?ViewKey = null,
    content_hash: ?u64 = null,
    pub fn deinit(self: *Bridge) void {
        self.hide();
    }
    pub fn hide(self: *Bridge) void {
        self.publisher.hide();
        self.key = null;
        self.content_hash = null;
    }
    /// Ordinary terminal metadata changes are content refreshes. Revoking the
    /// view here would invalidate MTA readers between their COM calls.
    pub fn dirty(self: *Bridge) void {
        self.content_hash = null;
    }
    pub fn publish(self: *Bridge, app: *App, pane: *RemotePane) !void {
        if (!pane.ready() or !pane.visible or !pane.ui_attachment.isValid()) return self.hide();
        if (!app.ensureUia()) return self.hide();
        const hwnd = pane.hwnd orelse return self.hide();
        const lease = pane.gate.lease orelse return self.hide();
        const key: ViewKey = .{ .source = pane.source_reference, .attachment = pane.ui_attachment, .lease = lease, .hwnd = hwnd };
        if (self.key) |old| if (!old.matches(key)) self.hide();
        var bounds: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &bounds) == 0) return self.hide();
        const rect: uia.Rect = .{ .x = @floatFromInt(bounds.left), .y = @floatFromInt(bounds.top), .width = @floatFromInt(@max(0, bounds.right - bounds.left)), .height = @floatFromInt(@max(0, bounds.bottom - bounds.top)) };
        const text = pane.ui.visible_text;
        var nodes: [18]uia.NodeSpec = undefined;
        // The same terminal element as a local pane's (D-29): the window
        // reports its focus, so a focus change needs no new revision.
        var id_buffer: [48]u8 = undefined;
        nodes[0] = uia_bridge.terminalRoot(pane.getTitle() orelse "", pane.ui_reference, &id_buffer);
        var signature = std.hash.Wyhash.init(0);
        signature.update(std.mem.asBytes(&rect));
        for ([_][]const u8{ nodes[0].name, nodes[0].localized_type, nodes[0].automation_id, text }) |part| {
            signature.update(part);
            signature.update(&.{0});
        }
        const content_hash = signature.final();
        if (self.publisher.current != null and self.content_hash == content_hash) return;
        var offset: usize = 0;
        var count: usize = 1;
        while (offset < text.len and count < nodes.len) {
            var end = @min(text.len, offset + uia.max_string_bytes);
            while (end < text.len and end > offset and text[end] & 0xc0 == 0x80) end -= 1;
            if (end == offset) break;
            nodes[count] = .{ .id = count + 1, .parent = 0, .name = text[offset..end], .role = .text, .bounds = rect };
            count += 1;
            offset = end;
        }
        try self.publisher.publishStable(std.heap.page_allocator, app.uia_api.?, app.uia_queue.?, pane.ui_attachment, hwnd, nodes[0..count]);
        self.key = key;
        self.content_hash = content_hash;
    }
    pub fn dispatch(self: *Bridge, app: *App, pane: *RemotePane, action: *const uia.Action) bool {
        if (!self.publisher.accepts(action.*) or !pane.ready() or !pane.ui_attachment.matches(action.attachment)) return false;
        const key = self.key orelse return false;
        if (!key.matches(.{ .source = pane.source_reference, .attachment = pane.ui_attachment, .lease = pane.gate.lease orelse return false, .hwnd = pane.hwnd orelse return false })) return false;
        // The pane's own focus event (`focusGained`); raising may reenter.
        if (action.kind == .focus_changed) {
            _ = self.publisher.raiseHostFocus(&uia_bridge.systemFocus);
            return true;
        }
        const live = app.resolveRemote(pane.ui_reference) orelse return false;
        if (action.kind != .focus or action.node_id != 1) return false;
        const hwnd = live.hwnd orelse return false;
        _ = w32.SetFocus(hwnd);
        return w32.GetFocus() == hwnd;
    }
};

/// RemotePane's WM_SETFOCUS (D-29, as `TerminalRegistry.focused` for a
/// local pane): with UIA in use and a client listening, make sure the pane
/// has a current element and queue its focus changed event, which
/// `Bridge.dispatch` raises from the App message loop while the pane keeps
/// the system focus. UIA makes none of the window's EVENT_OBJECT_FOCUS for
/// this provider-backed HWND. For RemotePane.zig's WM_SETFOCUS to call.
pub fn focusGained(app: *App, pane: *RemotePane) void {
    const api = app.uia_api orelse return;
    if (!api.clientsListening()) return;
    pane.ui.accessibility.publish(app, pane) catch return;
    _ = pane.ui.accessibility.publisher.queueHostFocus();
}

pub fn onGetObject(app: *App, pane: *RemotePane, wparam: usize, lparam: isize) isize {
    // OBJID_CLIENT remains suppressed: Windows otherwise installs a competing
    // client provider which breaks the custom fragment tree.
    if (w32.objectId(lparam) != uia.root_object_id or !pane.ready()) return 0;
    pane.ui.requestText(pane) catch {};
    pane.ui.accessibility.publish(app, pane) catch return 0;
    return pane.ui.accessibility.publisher.returnProvider(wparam, lparam);
}

test "remote accessibility without a published snapshot is inert" {
    var bridge: Bridge = .{};
    bridge.hide();
    try std.testing.expectEqual(@as(isize, 0), bridge.publisher.returnProvider(0, 0));
    // No element yet: a focus queues no event and raises none.
    try std.testing.expect(!bridge.publisher.queueHostFocus());
    try std.testing.expect(!bridge.publisher.raiseHostFocus(&uia_bridge.systemFocus));
    _ = &focusGained;
    bridge.deinit();
}

test "remote accessibility view key rejects replacement lease owner HWND and epoch" {
    var issuer = try refs.Issuer.init(1);
    const owner = try issuer.create(.window);
    const object = try issuer.surface(2);
    const key: ViewKey = .{ .source = .{ .epoch = 3, .kind = .surface, .id = 4, .generation = 5 }, .attachment = try issuer.attach(object, owner), .lease = .{ .holder_epoch = 1, .transaction = 6, .generation = 7 }, .hwnd = @ptrFromInt(8) };
    try std.testing.expect(key.matches(key));
    var changed = key;
    changed.lease.generation += 1;
    try std.testing.expect(!key.matches(changed));
    changed = key;
    changed.source.epoch += 1;
    try std.testing.expect(!key.matches(changed));
    changed = key;
    changed.attachment.revision += 1;
    try std.testing.expect(!key.matches(changed));
    changed = key;
    changed.hwnd = @ptrFromInt(9);
    try std.testing.expect(!key.matches(changed));
}
