//! GUI-owned remote terminal presentation. This is not a core Surface and never
//! owns a PTY, command, renderer or shell. Only local value references are used
//! by GUI providers; the source host remains authoritative for terminal input.
const Self = @This();
const std = @import("std");
const refs = @import("../../gx/ui_ref.zig");
const Channel = @import("ipc/RemoteChannel.zig").Channel;
const d2d = @import("ui/d2d.zig");
const RemotePerf = @import("RemotePerf.zig");

pub const State = enum { waiting, live, unavailable, closed };
pub const DrawResult = enum { waiting, drawn, unavailable, backend_unavailable };

allocator: std.mem.Allocator,
reference: refs.Reference,
attachment: refs.Attachment,
channel: *Channel,
state: State = .waiting,
last_frame: []u8,
has_frame: bool = false,
last_sequence: u64 = 0,
perf_frame: RemotePerf.Presentation = .{},

/// local_id must be issued from the host's remote-view namespace, not copied
/// from a foreign core Surface ID. The registry must distinguish local core
/// surfaces from remote views even though both use a surface-kind UI reference.
/// Takes ownership of channel only on success; caller keeps this object stable.
pub fn init(allocator: std.mem.Allocator, issuer: *refs.Issuer, local_id: u64, owner: refs.Reference, channel: *Channel) !Self {
    if (channel.source or channel.closing) return error.InvalidChannel;
    const reference = try issuer.surface(local_id);
    const attachment = try issuer.attach(reference, owner);
    const last_frame = try allocator.alloc(u8, channel.mapped.layout.frame_bytes);
    return .{ .allocator = allocator, .reference = reference, .attachment = attachment, .channel = channel, .last_frame = last_frame };
}

/// A hidden or replaced local attachment cannot resurrect its old providers.
pub fn setVisible(self: *Self, issuer: *refs.Issuer, owner: refs.Reference, visible: bool) !void {
    if (self.state == .closed) return error.Closed;
    if (!visible) self.perf_frame = .{};
    try self.attachment.setVisible(issuer, self.reference, owner, visible);
}

/// Both frameReady and draw use this gate. Hidden frames may still update the
/// pixel cache, but cannot start a sample that includes time away from the tab.
pub fn receivePerf(self: *Self, stamp: RemotePerf.InputStamp, visible: bool) void {
    if (visible) self.perf_frame.received(stamp, RemotePerf.now());
}

pub fn matches(self: *const Self, attachment: refs.Attachment) bool {
    return self.state != .closed and self.state != .unavailable and self.attachment.matches(attachment);
}

/// GUI thread only. CreateBitmap copies synchronously while the reading slot
/// is held. A private last-frame copy permits repaint without borrowing shared
/// bytes between frames, and is never displayed after source disconnection.
pub fn draw(self: *Self, canvas: *d2d.Canvas, bounds: d2d.Rect) DrawResult {
    if (self.state == .closed or self.state == .unavailable) return .unavailable;
    if (!self.attachment.isValid()) return .waiting;
    const frame = self.channel.acquire() catch {
        self.disconnect();
        return .unavailable;
    };
    const layout = self.channel.mapped.layout;
    if (frame) |value| {
        var reading = value;
        defer reading.release();
        if (reading.lease.generation != self.channel.mapped.generation) {
            self.disconnect();
            return .unavailable;
        }
        self.receivePerf(reading.lease.perf_input, self.attachment.isValid());
        @memcpy(self.last_frame, reading.lease.pixels);
        self.has_frame = true;
        self.last_sequence = reading.lease.sequence;
        self.state = .live;
        return if (canvas.drawBgra(reading.lease.pixels, layout.width, layout.height, layout.stride, bounds)) .drawn else .backend_unavailable;
    }
    if (!self.has_frame) return .waiting;
    return if (canvas.drawBgra(self.last_frame, layout.width, layout.height, layout.stride, bounds)) .drawn else .backend_unavailable;
}

/// Caller renders its localized unavailable UI. Never recreate a shell or
/// replay a command to disguise a lost source; old input refs become inert.
pub fn disconnect(self: *Self) void {
    if (self.state == .closed) return;
    self.state = .unavailable;
    self.attachment = .{};
    self.has_frame = false;
    self.perf_frame = .{};
    self.channel.close();
}

pub fn deinit(self: *Self) !void {
    if (self.state == .closed) return;
    self.disconnect();
    // Busy preserves the object and its storage until outstanding native leases
    // return. The caller must not free this object when deinit returns an error.
    try self.channel.deinit();
    self.allocator.free(self.last_frame);
    self.reference = .{};
    self.state = .closed;
}

test "remote unavailable view cannot expose providers or display cached pixels" {
    var view: Self = .{ .allocator = std.testing.allocator, .reference = .{}, .attachment = .{}, .channel = undefined, .state = .unavailable, .last_frame = undefined };
    try std.testing.expect(!view.matches(.{}));
    try std.testing.expectEqual(DrawResult.unavailable, view.draw(undefined, undefined));
    // Address-taking ensures production presentation/ownership signatures are
    // compiled by the standard win32 test root, not just isolated frame tests.
    const functions = .{ &init, &setVisible, &draw, &disconnect, &deinit };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}
