//! Bounded remote input admission and lease gating. Physical keys, text, IME,
//! mouse and protected-paste chunks retain their source ordering. Geometry and
//! focus coalesce per leaf without overtaking accepted ordered input.
const std = @import("std");
const protocol = @import("../../gx/remote_protocol.zig");
const refs = @import("../../gx/ui_ref.zig");
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const Event = @FieldType(protocol.Input, "event");

/// Each pane has one latest geometry/focus slot. Text remains a FIFO. Picking
/// the smallest producer sequence prevents a newer coalesced resize from
/// overtaking earlier text and tripping the source's monotonic input guard.
pub const Buffer = struct {
    const Base = struct { surface: refs.Reference, lease: protocol.Lease, sequence: u64 };
    const Resize = struct { base: Base, value: @FieldType(Event, "resize") };
    const Focus = struct { base: Base, value: bool };
    const Ordered = struct {
        input: protocol.Input,
        paste: ?struct { bytes: []u8, offset: usize = 0, index: u32 = 0 } = null,
    };
    resizes: [protocol.max_nodes]?Resize = @splat(null),
    focuses: [protocol.max_nodes]?Focus = @splat(null),
    ordered: [32]?Ordered = @splat(null),
    head: usize = 0,
    len: usize = 0,
    paste_bytes: usize = 0,

    pub fn push(self: *Buffer, index: usize, input: protocol.Input) bool {
        if (index >= protocol.max_nodes) return false;
        const base: Base = .{ .surface = input.surface, .lease = input.lease, .sequence = input.sequence };
        switch (input.event) {
            .resize => |value| self.resizes[index] = .{ .base = base, .value = value },
            .focus => |value| self.focuses[index] = .{ .base = base, .value = value },
            else => {
                if (self.len == self.ordered.len) return false;
                self.ordered[(self.head + self.len) % self.ordered.len] = .{ .input = input };
                self.len += 1;
            },
        }
        return true;
    }
    /// Ownership transfers only on admission. The whole paste occupies one
    /// FIFO position, so later keystrokes cannot overtake unsent chunks.
    pub fn pushPaste(self: *Buffer, input: protocol.Input, bytes: []u8) bool {
        if (input.event != .paste or bytes.len == 0 or self.len == self.ordered.len or
            bytes.len > protocol.max_paste_bytes - self.paste_bytes) return false;
        self.ordered[(self.head + self.len) % self.ordered.len] = .{ .input = input, .paste = .{ .bytes = bytes } };
        self.len += 1;
        self.paste_bytes += bytes.len;
        return true;
    }
    pub fn peek(self: *const Buffer) ?protocol.Input {
        var result: ?protocol.Input = if (self.len != 0) self.ordered[self.head].?.input else null;
        if (self.len != 0) if (self.ordered[self.head].?.paste) |paste| {
            var end = @min(paste.bytes.len, paste.offset + protocol.Text.capacity);
            while (end < paste.bytes.len and end > paste.offset and paste.bytes[end] & 0xc0 == 0x80) end -= 1;
            result.?.event.paste.index = paste.index;
            result.?.event.paste.last = end == paste.bytes.len;
            result.?.event.paste.text = protocol.Text.init(paste.bytes[paste.offset..end]) catch unreachable;
        };
        for (self.resizes) |item| if (item) |value| {
            if (result == null or value.base.sequence < result.?.sequence) result = .{ .surface = value.base.surface, .lease = value.base.lease, .sequence = value.base.sequence, .event = .{ .resize = value.value } };
        };
        for (self.focuses) |item| if (item) |value| {
            if (result == null or value.base.sequence < result.?.sequence) result = .{ .surface = value.base.surface, .lease = value.base.lease, .sequence = value.base.sequence, .event = .{ .focus = value.value } };
        };
        return result;
    }
    /// Call only after the transport accepted the owned packet. QueueFull does
    /// not remove anything. Producer sequences are unique within a window.
    pub fn pop(self: *Buffer, sequence: u64) ?[]u8 {
        if (self.len != 0 and self.ordered[self.head].?.input.sequence == sequence) {
            var released: ?[]u8 = null;
            if (self.ordered[self.head].?.paste) |*paste| {
                const next = self.peek().?.event.paste;
                paste.offset += next.text.len;
                paste.index += 1;
                if (!next.last) return null;
                released = paste.bytes;
                self.paste_bytes -= paste.bytes.len;
            }
            self.ordered[self.head] = null;
            self.head = (self.head + 1) % self.ordered.len;
            self.len -= 1;
            return released;
        }
        for (&self.resizes) |*entry| if (entry.*) |value| if (value.base.sequence == sequence) {
            entry.* = null;
            return null;
        };
        for (&self.focuses) |*entry| if (entry.*) |value| if (value.base.sequence == sequence) {
            entry.* = null;
            return null;
        };
        return null;
    }
    pub fn clear(self: *Buffer, alloc: std.mem.Allocator) void {
        for (self.ordered) |entry| if (entry) |value| if (value.paste) |paste| alloc.free(paste.bytes);
        self.* = .{};
    }
    pub fn discardSurface(self: *Buffer, alloc: std.mem.Allocator, surface: refs.Reference, paste_only: bool) void {
        var kept: usize = 0;
        const original = self.len;
        for (0..original) |offset| {
            const index = (self.head + offset) % self.ordered.len;
            const item = self.ordered[index].?;
            self.ordered[index] = null;
            if (item.input.surface.matches(surface) and (!paste_only or item.paste != null)) {
                if (item.paste) |paste| {
                    self.paste_bytes -= paste.bytes.len;
                    alloc.free(paste.bytes);
                }
                continue;
            }
            self.ordered[(self.head + kept) % self.ordered.len] = item;
            kept += 1;
        }
        self.len = kept;
        if (!paste_only) {
            for (&self.resizes) |*entry| if (entry.*) |value| if (value.base.surface.matches(surface)) {
                entry.* = null;
            };
            for (&self.focuses) |*entry| if (entry.*) |value| if (value.base.surface.matches(surface)) {
                entry.* = null;
            };
        }
    }
};

pub const Gate = struct {
    ticket: protocol.Ticket,
    lease: ?protocol.Lease = null,
    sequence: u64 = 0,
    disconnected: bool = false,
    pub fn enable(self: *Gate, lease: protocol.Lease) !void {
        if (self.disconnected or lease.holder_epoch != self.ticket.target_epoch or lease.transaction != self.ticket.transaction or lease.generation != self.ticket.generation) return error.InvalidLease;
        if (self.lease) |old| if (!std.meta.eql(old, lease)) return error.InvalidLease;
        self.lease = lease;
    }
    pub fn next(self: *Gate, surface: refs.Reference, event: Event) !protocol.Input {
        if (self.disconnected or self.lease == null) return error.InputDisabled;
        if (!surface.isValid() or surface.kind != .surface or surface.epoch != self.ticket.source_epoch) return error.InvalidSurface;
        const next_sequence = std.math.add(u64, self.sequence, 1) catch return error.Exhausted;
        const input: protocol.Input = .{ .surface = surface, .lease = self.lease.?, .sequence = next_sequence, .event = event };
        const packet: protocol.Packet = .{ .sender_epoch = self.ticket.target_epoch, .recipient_epoch = self.ticket.source_epoch, .request_id = 1, .ticket = self.ticket, .body = .{ .input = input } };
        try protocol.validate(&packet);
        self.sequence = next_sequence;
        return input;
    }
    pub fn disconnect(self: *Gate) void {
        self.disconnected = true;
        self.lease = null;
    }
};

pub const Utf16 = struct {
    high: ?u16 = null,
    pub fn reset(self: *Utf16) void {
        self.high = null;
    }
    pub fn feed(self: *Utf16, unit: u16) !?protocol.Text {
        if (unit >= 0xd800 and unit <= 0xdbff) {
            self.high = unit;
            return null;
        }
        const first = self.high;
        self.high = null;
        if (unit >= 0xdc00 and unit <= 0xdfff) {
            const upper = first orelse return error.InvalidUtf16;
            return scalar(0x10000 + (@as(u32, upper) - 0xd800) * 1024 + unit - 0xdc00);
        }
        if (first != null) return error.InvalidUtf16;
        return scalar(unit);
    }
    pub fn scalar(value: u32) !?protocol.Text {
        if (value == 0) return null;
        if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.InvalidUtf16;
        var bytes: [4]u8 = undefined;
        const count = try std.unicode.utf8Encode(@intCast(value), &bytes);
        return try protocol.Text.init(bytes[0..count]);
    }
};

/// The caller first validates Tree through remote_protocol. Empty rectangles
/// are assigned to hidden leaves, including all non-zoomed panes during zoom.
pub fn layout(tree: *const protocol.Tree, area: Rect, output: *[protocol.max_nodes]Rect) void {
    @memset(output, .{});
    layoutNode(tree, tree.zoom orelse tree.root, area, output);
}
fn layoutNode(tree: *const protocol.Tree, index: u16, area: Rect, output: *[protocol.max_nodes]Rect) void {
    switch (tree.nodes.items[index]) {
        .leaf => output[index] = area,
        .split => |split| {
            var first = area;
            var second = area;
            const gap: f32 = @min(2, if (split.axis == .horizontal) area.w else area.h);
            if (split.axis == .horizontal) {
                first.w = @max(0, area.w - gap) * split.ratio;
                second.x += first.w + gap;
                second.w = @max(0, area.w - first.w - gap);
            } else {
                first.h = @max(0, area.h - gap) * split.ratio;
                second.y += first.h + gap;
                second.h = @max(0, area.h - first.h - gap);
            }
            layoutNode(tree, split.first, first, output);
            layoutNode(tree, split.second, second, output);
        },
    }
}

test "remote input gate drops precommit and disconnected input and never reuses sequence" {
    var gate: Gate = .{ .ticket = .{ .source_epoch = 1, .target_epoch = 2, .transaction = 3, .generation = 4 } };
    const surface: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 5, .generation = 6 };
    try std.testing.expectError(error.InputDisabled, gate.next(surface, .{ .focus = true }));
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 };
    try gate.enable(lease);
    try std.testing.expectEqual(@as(u64, 1), (try gate.next(surface, .{ .focus = true })).sequence);
    try gate.enable(lease);
    try std.testing.expectEqual(@as(u64, 2), (try gate.next(surface, .{ .focus = false })).sequence);
    gate.disconnect();
    try std.testing.expectError(error.InputDisabled, gate.next(surface, .{ .focus = true }));
    try std.testing.expectError(error.InvalidLease, gate.enable(lease));
}

test "remote text assembles surrogate pairs and clears unfinished input on focus loss" {
    var decoder: Utf16 = .{};
    try std.testing.expect((try decoder.feed(0xd83d)) == null);
    const emoji = (try decoder.feed(0xde00)).?;
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", emoji.slice());
    try std.testing.expect((try decoder.feed(0xd83d)) == null);
    decoder.reset();
    try std.testing.expectError(error.InvalidUtf16, decoder.feed(0xde00));
    try std.testing.expectEqualStrings("\r", (try decoder.feed(13)).?.slice());
    try std.testing.expect((try decoder.feed(0)) == null);
}

test "remote split layout preserves complete tree ratios and zoom hides other leaves" {
    const a: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const b: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 2, .generation = 2 };
    var tree: protocol.Tree = .{ .nodes = try protocol.Bounded(protocol.Node, protocol.max_nodes).init(&.{ .{ .split = .{ .axis = .horizontal, .ratio = 0.25, .first = 1, .second = 2 } }, .{ .leaf = a }, .{ .leaf = b } }), .root = 0, .active = 2 };
    var bounds: [protocol.max_nodes]Rect = undefined;
    layout(&tree, .{ .w = 402, .h = 200 }, &bounds);
    try std.testing.expectEqual(@as(f32, 100), bounds[1].w);
    try std.testing.expectEqual(@as(f32, 102), bounds[2].x);
    try std.testing.expectEqual(@as(f32, 300), bounds[2].w);
    tree.zoom = 2;
    layout(&tree, .{ .w = 402, .h = 200 }, &bounds);
    try std.testing.expectEqual(@as(f32, 0), bounds[1].w);
    try std.testing.expectEqual(@as(f32, 402), bounds[2].w);
}

test "remote initial input retains all 128 pane sizes and coalescing preserves text order" {
    var queue: Buffer = .{};
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 };
    for (0..protocol.max_leaves) |index| {
        try std.testing.expect(queue.push(index, .{ .surface = .{ .epoch = 1, .kind = .surface, .id = index + 1, .generation = 1 }, .lease = lease, .sequence = index + 1, .event = .{ .resize = .{ .width = 100, .height = 100, .dpi = 96 } } }));
    }
    var count: usize = 0;
    while (queue.peek()) |input| {
        _ = queue.pop(input.sequence);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 128), count);
    const surface: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    try std.testing.expect(queue.push(0, .{ .surface = surface, .lease = lease, .sequence = 129, .event = .{ .resize = .{ .width = 200, .height = 100, .dpi = 96 } } }));
    try std.testing.expect(queue.push(0, .{ .surface = surface, .lease = lease, .sequence = 130, .event = .{ .text = try protocol.Text.init("typed") } }));
    try std.testing.expect(queue.push(0, .{ .surface = surface, .lease = lease, .sequence = 131, .event = .{ .resize = .{ .width = 300, .height = 100, .dpi = 96 } } }));
    try std.testing.expectEqual(@as(u64, 130), queue.peek().?.sequence);
    try std.testing.expectEqual(@as(u64, 130), queue.peek().?.sequence); // Failed send leaves it untouched.
    _ = queue.pop(130);
    try std.testing.expectEqual(@as(u64, 131), queue.peek().?.sequence);
    _ = queue.pop(131);
    try std.testing.expect(queue.peek() == null);
}

test "remote text backpressure rejects only new admissions without losing accepted input" {
    var queue: Buffer = .{};
    const surface: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    for (1..33) |sequence| try std.testing.expect(queue.push(0, .{ .surface = surface, .lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 }, .sequence = sequence, .event = .{ .text = try protocol.Text.init("x") } }));
    try std.testing.expect(!queue.push(0, .{ .surface = surface, .lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 }, .sequence = 33, .event = .{ .text = try protocol.Text.init("x") } }));
    for (1..33) |sequence| {
        try std.testing.expectEqual(@as(u64, sequence), queue.peek().?.sequence);
        _ = queue.pop(sequence);
    }
    try std.testing.expect(queue.peek() == null);
}

test "remote paste spool keeps later input behind every UTF8 chunk and releases owned bytes" {
    const alloc = std.testing.allocator;
    var queue: Buffer = .{};
    defer queue.clear(alloc);
    const surface: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 };
    const parent: protocol.PasteParent = .{ .transaction = 11, .config_generation = 12 };
    const bytes = try alloc.alloc(u8, protocol.Text.capacity + 7);
    @memset(bytes, 'a');
    @memcpy(bytes[protocol.Text.capacity - 1 ..][0..3], "\xe4\xb8\xad");
    try std.testing.expect(queue.pushPaste(.{ .surface = surface, .lease = lease, .sequence = 1, .event = .{ .paste = .{ .transfer = 1, .parent = parent, .index = 0, .last = false, .text = .{} } } }, bytes));
    try std.testing.expect(queue.push(0, .{ .surface = surface, .lease = lease, .sequence = 2, .event = .{ .text = try protocol.Text.init("later") } }));
    const first = queue.peek().?;
    try std.testing.expectEqual(parent, first.event.paste.parent.?);
    try std.testing.expectEqual(@as(usize, protocol.Text.capacity - 1), first.event.paste.text.len);
    try std.testing.expect(!first.event.paste.last);
    try std.testing.expect(queue.pop(1) == null);
    const second = queue.peek().?;
    try std.testing.expectEqual(parent, second.event.paste.parent.?);
    try std.testing.expectEqual(@as(u64, 1), second.sequence);
    try std.testing.expectEqual(@as(u32, 1), second.event.paste.index);
    try std.testing.expect(second.event.paste.last);
    try std.testing.expect(std.unicode.utf8ValidateSlice(second.event.paste.text.slice()));
    alloc.free(queue.pop(1).?);
    try std.testing.expectEqual(@as(u64, 2), queue.peek().?.sequence);
    try std.testing.expectEqual(@as(usize, 0), queue.paste_bytes);
}

test "remote cancellation discards only the closed surface and releases unsent paste" {
    const alloc = std.testing.allocator;
    var queue: Buffer = .{};
    defer queue.clear(alloc);
    const first: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 };
    const second: refs.Reference = .{ .epoch = 1, .kind = .surface, .id = 2, .generation = 2 };
    const lease: protocol.Lease = .{ .holder_epoch = 2, .transaction = 3, .generation = 4 };
    try std.testing.expect(queue.pushPaste(.{ .surface = first, .lease = lease, .sequence = 1, .event = .{ .paste = .{ .transfer = 1, .index = 0, .last = true, .text = .{} } } }, try alloc.dupe(u8, "cancel")));
    try std.testing.expect(queue.push(1, .{ .surface = second, .lease = lease, .sequence = 2, .event = .{ .text = try protocol.Text.init("keep") } }));
    queue.discardSurface(alloc, first, false);
    try std.testing.expectEqual(@as(usize, 0), queue.paste_bytes);
    try std.testing.expectEqual(@as(u64, 2), queue.peek().?.sequence);
}
