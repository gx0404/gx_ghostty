//! Binding placement and bounded asynchronous continuation identities.
//! Canonical Binding.Action text is the only action language on the wire.
const std = @import("std");
const input = @import("../input.zig");
const protocol = @import("remote_protocol.zig");
const refs = @import("ui_ref.zig");
const Keybinds = @import("../config/Config.zig").Keybinds;

pub const Placement = enum { source, target };

/// Exhaustive by design: adding an upstream action requires a placement choice.
pub fn placement(action: input.Binding.Action) Placement {
    return switch (action) {
        .ignore,
        .unbind,
        .csi,
        .esc,
        .text,
        .cursor_key,
        .reset,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        .search,
        .search_selection,
        .navigate_search,
        .clear_screen,
        .select_all,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .toggle_readonly,
        .toggle_mouse_reporting,
        .end_key_sequence,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .crash,
        => .source,
        .copy_to_clipboard,
        .paste_from_clipboard,
        .paste_from_selection,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        .start_search,
        .end_search,
        .write_scrollback_file,
        .write_screen_file,
        .write_selection_file,
        .new_window,
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .prompt_surface_title,
        .prompt_tab_title,
        .prompt_window_title,
        .set_surface_title,
        .set_tab_title,
        .set_window_title,
        .new_split,
        .goto_split,
        .goto_window,
        .toggle_split_zoom,
        .resize_split,
        .equalize_splits,
        .reset_window_size,
        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .open_config,
        .reload_config,
        .close_surface,
        .close_tab,
        .close_window,
        .close_all_windows,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        .check_for_updates,
        .undo,
        .redo,
        .quit,
        .gx,
        => .target,
    };
}

pub fn encode(action: input.Binding.Action) !protocol.ActionText {
    var result: protocol.ActionText = .{};
    var writer: std.Io.Writer = .fixed(&result.items);
    try action.format(&writer);
    result.len = @intCast(writer.end);
    return result;
}

pub fn decode(value: *const protocol.ActionText) !input.Binding.Action {
    if (value.len == 0 or value.len > value.items.len) return error.InvalidAction;
    return input.Binding.Action.parse(value.slice());
}

/// Complete Config.Keybinds syntax, including named tables, flags, sequences,
/// and chain entries. The table prefix must precede binding flags.
pub fn writeKeybindSnapshot(bindings: *const Keybinds, writer: *std.Io.Writer) !void {
    try writeSet(&bindings.set, writer, "", "", 0);
    var tables = bindings.tables.iterator();
    while (tables.next()) |table| {
        if (table.value_ptr.bindings.count() == 0) {
            try writer.print("keybind = {s}/\n", .{table.key_ptr.*});
        } else try writeSet(table.value_ptr, writer, table.key_ptr.*, "", 0);
    }
}

fn writeSet(set: *const input.Binding.Set, writer: *std.Io.Writer, table: []const u8, prefix: []const u8, depth: usize) anyerror!void {
    if (depth > 32) return error.LimitExceeded;
    var iter = set.bindings.iterator();
    while (iter.next()) |entry| {
        var path_buffer: [4096]u8 = undefined;
        var path: std.Io.Writer = .fixed(&path_buffer);
        try path.print("{s}{f}", .{ prefix, entry.key_ptr.* });
        switch (entry.value_ptr.*) {
            .leader => |child| {
                try path.writeAll(">");
                try writeSet(child, writer, table, path.buffered(), depth + 1);
            },
            inline .leaf, .leaf_chained => |leaf| {
                var line_buffer: [8192]u8 = undefined;
                var line: std.Io.Writer = .fixed(&line_buffer);
                if (table.len != 0) try line.print("{s}/", .{table});
                if (!leaf.flags.consumed) try line.writeAll("unconsumed:");
                if (leaf.flags.all) try line.writeAll("all:");
                if (leaf.flags.global) try line.writeAll("global:");
                if (leaf.flags.performable) try line.writeAll("performable:");
                try line.writeAll(path.buffered());
                try entry.value_ptr.formatEntries(&line, @import("../config/formatter.zig").entryFormatter("keybind", writer));
            },
        }
    }
}

/// The caller must supply an arena: Config.Keybinds owns parser strings for
/// actions and table names in the same way as a normal derived configuration.
pub fn readKeybindSnapshot(alloc: std.mem.Allocator, bytes: []const u8) !Keybinds {
    var result: Keybinds = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "keybind = ")) return error.InvalidSnapshot;
        const value = line["keybind = ".len..];
        if (value.len == 0 or std.mem.eql(u8, value, "clear")) return error.InvalidSnapshot;
        try result.parseCLI(alloc, value);
    }
    return result;
}

pub const Identity = struct {
    surface: refs.Reference,
    lease: protocol.Lease,
    transaction: u64,
    config_generation: u64,

    pub fn accepts(self: Identity, result: protocol.ActionResult) bool {
        return self.surface.matches(result.surface) and
            std.meta.eql(self.lease, result.lease) and
            self.transaction == result.transaction and
            self.config_generation == result.config_generation;
    }
};

/// Only data explicitly produced for this suspended binding may bypass its
/// queued physical input. Direct menu/OLE paste carries no parent identity.
pub fn pasteBelongsToBinding(event: *const protocol.Input, identity: Identity) bool {
    if (event.event != .paste) return false;
    const parent = event.event.paste.parent orelse return false;
    return identity.accepts(.{ .surface = event.surface, .lease = event.lease, .transaction = parent.transaction, .config_generation = parent.config_generation, .performed = false });
}

/// Callback payloads live in transport packets. This queue retains only the
/// identity and optional apply-action receipt; its fixed slots stay small.
pub const CallbackQueue = struct {
    pub const Pending = struct {
        identity: Identity,
        origin: ?protocol.ActionRequest,
        kind: std.meta.Tag(@FieldType(protocol.UiEvent, "event")),
    };
    slots: [16]?*Pending = @splat(null),

    pub fn reserve(self: *CallbackQueue, alloc: std.mem.Allocator, value: Pending) !void {
        for (&self.slots) |*slot| if (slot.* == null) {
            const owned = try alloc.create(Pending);
            owned.* = value;
            slot.* = owned;
            return;
        };
        return error.QueueFull;
    }

    /// Exact-match removal makes stale, duplicate and foreign receipts inert.
    pub fn take(self: *CallbackQueue, result: protocol.ActionResult) ?*Pending {
        for (&self.slots) |*slot| if (slot.*) |pending| if (pending.identity.accepts(result)) {
            slot.* = null;
            return pending;
        };
        return null;
    }

    pub fn blocksInput(self: *const CallbackQueue) bool {
        for (self.slots) |slot| if (slot) |pending| if (pending.origin != null) return true;
        return false;
    }

    pub fn containsOrigin(self: *const CallbackQueue, request: protocol.ActionRequest) bool {
        const identity: Identity = .{ .surface = request.surface, .lease = request.lease, .transaction = request.transaction, .config_generation = request.config_generation };
        for (self.slots) |slot| if (slot) |pending| if (pending.origin) |origin| {
            if (identity.accepts(.{ .surface = origin.surface, .lease = origin.lease, .transaction = origin.transaction, .config_generation = origin.config_generation, .performed = false })) return true;
        };
        return false;
    }
};

test "gx.remote_binding callback queue owns receipts and rejects stale reload lease and duplicate results" {
    const alloc = std.testing.allocator;
    var queue: CallbackQueue = .{};
    defer for (queue.slots) |slot| if (slot) |pending| alloc.destroy(pending);
    const identity: Identity = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 4, .generation = 5 }, .lease = .{ .holder_epoch = 2, .transaction = 6, .generation = 7 }, .transaction = 8, .config_generation = 9 };
    var origin: protocol.ActionRequest = .{ .surface = identity.surface, .lease = identity.lease, .transaction = 20, .config_generation = identity.config_generation, .action = try protocol.ActionText.init("write_screen_file:open") };
    try queue.reserve(alloc, .{ .identity = identity, .origin = origin, .kind = .open_url });
    origin.action.items[0] = 'X';
    try std.testing.expectEqualStrings("write_screen_file:open", queue.slots[0].?.origin.?.action.slice());
    try std.testing.expect(queue.blocksInput());
    try std.testing.expect(queue.containsOrigin(origin));
    var result: protocol.ActionResult = .{ .surface = identity.surface, .lease = identity.lease, .transaction = identity.transaction, .config_generation = identity.config_generation, .performed = true };
    result.config_generation += 1;
    try std.testing.expect(queue.take(result) == null);
    result.config_generation -= 1;
    result.lease.generation += 1;
    try std.testing.expect(queue.take(result) == null);
    result.lease.generation -= 1;
    result.surface.generation += 1;
    try std.testing.expect(queue.take(result) == null);
    result.surface.generation -= 1;
    const pending = queue.take(result).?;
    defer alloc.destroy(pending);
    try std.testing.expect(pending.origin != null);
    try std.testing.expect(queue.take(result) == null);
    try std.testing.expect(!queue.blocksInput());
    // Native callbacks do not stall typing, and a full queue refuses ownership.
    for (0..queue.slots.len) |index| {
        var next = identity;
        next.transaction += index + 1;
        try queue.reserve(alloc, .{ .identity = next, .origin = null, .kind = .desktop_notification });
    }
    try std.testing.expect(!queue.blocksInput());
    try std.testing.expectError(error.QueueFull, queue.reserve(alloc, .{ .identity = identity, .origin = origin, .kind = .open_url }));
    try std.testing.expect(@sizeOf(CallbackQueue) <= 256);
}

/// A paste is all-or-nothing. No bytes reach the PTY before its final chunk.
/// Any sequence mismatch discards the entire buffered transfer.
pub const PasteBuffer = struct {
    transfer: u64 = 0,
    parent: ?protocol.PasteParent = null,
    next: u32 = 0,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *PasteBuffer, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
        self.* = .{};
    }

    pub fn append(self: *PasteBuffer, alloc: std.mem.Allocator, chunk: *const protocol.Paste) !bool {
        errdefer self.deinit(alloc);
        if (chunk.transfer == 0 or chunk.text.len > protocol.Text.capacity) return error.InvalidPaste;
        if (self.transfer == 0) {
            if (chunk.index != 0) return error.InvalidPaste;
            self.transfer = chunk.transfer;
            self.parent = chunk.parent;
        }
        if (self.transfer != chunk.transfer or !std.meta.eql(self.parent, chunk.parent) or self.next != chunk.index or
            self.bytes.items.len + chunk.text.len > protocol.max_paste_bytes or
            (!chunk.last and chunk.text.len == 0)) return error.InvalidPaste;
        try self.bytes.appendSlice(alloc, chunk.text.slice());
        self.next += 1;
        return chunk.last;
    }
};

test "gx.remote_binding canonical action round trips and target placement" {
    const encoded = try encode(.{ .new_split = .right });
    try std.testing.expectEqualStrings("new_split:right", encoded.slice());
    try std.testing.expectEqual(Placement.target, placement(try decode(&encoded)));
    try std.testing.expectEqual(Placement.source, placement(.{ .text = "hello" }));
    try std.testing.expectEqual(Placement.source, placement(.ignore));
}

test "gx.remote_binding paste rejects gaps reordering and mixed transfers atomically" {
    var buffer: PasteBuffer = .{};
    defer buffer.deinit(std.testing.allocator);
    var chunk: protocol.Paste = .{ .transfer = 1, .index = 0, .last = false, .text = try protocol.Text.init("hello") };
    try std.testing.expect(!try buffer.append(std.testing.allocator, &chunk));
    chunk.index = 2;
    try std.testing.expectError(error.InvalidPaste, buffer.append(std.testing.allocator, &chunk));
    try std.testing.expectEqual(@as(usize, 0), buffer.bytes.items.len);
    chunk.index = 0;
    chunk.last = true;
    try std.testing.expect(try buffer.append(std.testing.allocator, &chunk));
    try std.testing.expectEqualStrings("hello", buffer.bytes.items);
}

test "gx.remote_binding paste parent requires exact surface lease action and config" {
    const identity: Identity = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 3, .generation = 2 }, .lease = .{ .holder_epoch = 2, .generation = 4, .transaction = 5 }, .transaction = 8, .config_generation = 9 };
    var event: protocol.Input = .{ .surface = identity.surface, .lease = identity.lease, .sequence = 1, .event = .{ .paste = .{ .transfer = 20, .index = 0, .last = false, .text = try protocol.Text.init("first"), .parent = .{ .transaction = 8, .config_generation = 9 } } } };
    try std.testing.expect(pasteBelongsToBinding(&event, identity));
    event.event.paste.parent.?.transaction += 1;
    try std.testing.expect(!pasteBelongsToBinding(&event, identity));
    event.event.paste.parent.?.transaction -= 1;
    event.event.paste.parent.?.config_generation += 1;
    try std.testing.expect(!pasteBelongsToBinding(&event, identity));
    event.event.paste.parent.?.config_generation -= 1;
    event.surface.generation += 1;
    try std.testing.expect(!pasteBelongsToBinding(&event, identity));
    event.surface.generation -= 1;
    event.lease.generation += 1;
    try std.testing.expect(!pasteBelongsToBinding(&event, identity));
    event.lease.generation -= 1;
    var buffer: PasteBuffer = .{};
    defer buffer.deinit(std.testing.allocator);
    try std.testing.expect(!try buffer.append(std.testing.allocator, &event.event.paste));
    event.event.paste.index = 1;
    event.event.paste.last = true;
    event.event.paste.parent = null;
    try std.testing.expect(!pasteBelongsToBinding(&event, identity));
    try std.testing.expectError(error.InvalidPaste, buffer.append(std.testing.allocator, &event.event.paste));
    try std.testing.expectEqual(@as(usize, 0), buffer.bytes.items.len);
}

test "gx.remote_binding result requires exact leaf lease transaction and config" {
    const identity: Identity = .{ .surface = .{ .epoch = 1, .kind = .surface, .id = 3, .generation = 2 }, .lease = .{ .holder_epoch = 2, .generation = 4, .transaction = 5 }, .transaction = 8, .config_generation = 1 };
    var result: protocol.ActionResult = .{ .surface = identity.surface, .lease = identity.lease, .transaction = identity.transaction, .config_generation = identity.config_generation, .performed = false };
    try std.testing.expect(identity.accepts(result));
    result.config_generation += 1;
    try std.testing.expect(!identity.accepts(result));
    result.config_generation = identity.config_generation;
    result.lease.generation += 1;
    try std.testing.expect(!identity.accepts(result));
}

test "gx.remote_binding snapshot round trips named tables flags sequences and chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var original: Keybinds = .{};
    for ([_][]const u8{
        "performable:ctrl+a=copy_to_clipboard",
        "chain=text:after-copy",
        "f4=text:with trailing spaces  ",
        "mode/unconsumed:ctrl+x>c=new_tab",
        "chain=text:after-tab",
        "mode/global:f2=toggle_visibility",
        "other/all:f3=select_all",
        "empty/",
    }) |line| try original.parseCLI(arena.allocator(), line);
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writeKeybindSnapshot(&original, &writer.writer);
    const decoded = try readKeybindSnapshot(arena.allocator(), writer.written());
    try std.testing.expect(original.equal(decoded));
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "mode/unconsumed:") != null);
    try std.testing.expectError(error.InvalidSnapshot, readKeybindSnapshot(arena.allocator(), "keybind = clear\n"));
}
