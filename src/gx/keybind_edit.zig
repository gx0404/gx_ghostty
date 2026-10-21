//! Full keybinding editing model; never reconstructed from shortcut display rows.
//! Uses the native parser for tables, flags, trigger sequences and action chains.
const std = @import("std");
const Config = @import("../config/Config.zig");
const Binding = @import("../input/Binding.zig");
const Overlay = @import("gui_settings.zig").Overlay;
pub const max_values = 1024;
pub const max_draft_bytes = 65536;
const marker = "# gx-keybind-editor ";

pub const Key = struct {
    table: []const u8 = "",
    triggers: []const Binding.Trigger,
    pub fn equal(self: Key, other: Key) bool {
        return std.mem.eql(u8, self.table, other.table) and self.triggers.len == other.triggers.len and self.overlaps(other);
    }
    pub fn overlaps(self: Key, other: Key) bool {
        if (!std.mem.eql(u8, self.table, other.table)) return false;
        for (self.triggers[0..@min(self.triggers.len, other.triggers.len)], other.triggers[0..@min(self.triggers.len, other.triggers.len)]) |a, b| if (!a.equal(b)) return false;
        return true;
    }
};
pub const Source = enum { defaults, user, overlay, cli };
pub const SourceInputs = struct { source: Source, values: []const []const u8 };
pub const Entry = struct { key: Key, flags: Binding.Flags, actions: []const Binding.Action, source: Source = .defaults };
pub const Target = union(enum) { key: Key, table: []const u8, all };
pub const Draft = struct { values: []const []const u8, targets: []const Target };
pub const Group = struct { id: u64, start: usize, end: usize, digest: [32]u8, values: []const []const u8 };
pub const Block = struct { lines: []const usize, digest: [32]u8, values: []const []const u8, target: ?Target };
pub const Scan = struct { groups: []const Group, blocks: []const Block, next_id: u64 };
pub const Selection = union(enum) {
    lower: Entry,
    group: struct { id: u64, digest: [32]u8 },
    block: struct { digest: [32]u8 },
};
pub const Intent = struct { selected: ?Selection = null, values: []const []const u8 = &.{}, reset: bool = false, conflicts_confirmed: bool = false };
pub const Policy = struct { enabled: bool = true, cli: []const Target = &.{} };

pub fn enumerate(alloc: std.mem.Allocator, keybinds: *const Config.Keybinds) ![]Entry {
    var result: std.ArrayList(Entry) = .empty;
    try walk(alloc, &keybinds.set, "", &.{}, &result);
    var tables = keybinds.tables.iterator();
    while (tables.next()) |table| try walk(alloc, table.value_ptr, table.key_ptr.*, &.{}, &result);
    return result.toOwnedSlice(alloc);
}
fn walk(alloc: std.mem.Allocator, set: *const Binding.Set, table: []const u8, prefix: []const Binding.Trigger, output: *std.ArrayList(Entry)) anyerror!void {
    if (prefix.len > 32 or output.items.len > max_values) return error.LimitExceeded;
    var iter = set.bindings.iterator();
    while (iter.next()) |item| {
        const sequence = try alloc.alloc(Binding.Trigger, prefix.len + 1);
        @memcpy(sequence[0..prefix.len], prefix);
        sequence[prefix.len] = item.key_ptr.*;
        const leaf: Binding.Set.GenericLeaf = switch (item.value_ptr.*) {
            .leader => |next| {
                try walk(alloc, next, table, sequence, output);
                continue;
            },
            .leaf => |value| value.generic(),
            .leaf_chained => |value| value.generic(),
        };
        const actions = try alloc.alloc(Binding.Action, leaf.actionsSlice().len);
        for (actions, leaf.actionsSlice()) |*out, action| out.* = try action.clone(alloc);
        try output.append(alloc, .{ .key = .{ .table = try alloc.dupe(u8, table), .triggers = sequence }, .flags = leaf.flags, .actions = actions });
    }
}

pub fn formatKey(alloc: std.mem.Allocator, key: Key) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    if (key.table.len > 0) try output.writer.print("{s}/", .{key.table});
    for (key.triggers, 0..) |trigger, index| {
        if (index != 0) try output.writer.writeByte('>');
        try output.writer.print("{f}", .{trigger});
    }
    return output.toOwnedSlice();
}
pub fn formatEntry(alloc: std.mem.Allocator, entry: Entry) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    var output: std.Io.Writer.Allocating = .init(alloc);
    if (entry.key.table.len > 0) try output.writer.print("{s}/", .{entry.key.table});
    if (entry.flags.global) try output.writer.writeAll("global:");
    if (entry.flags.all) try output.writer.writeAll("all:");
    if (!entry.flags.consumed) try output.writer.writeAll("unconsumed:");
    if (entry.flags.performable) try output.writer.writeAll("performable:");
    for (entry.key.triggers, 0..) |trigger, index| {
        if (index != 0) try output.writer.writeByte('>');
        try output.writer.print("{f}", .{trigger});
    }
    if (entry.actions.len == 0) return error.InvalidFormat;
    try output.writer.print("={f}", .{entry.actions[0]});
    try values.append(alloc, try output.toOwnedSlice());
    for (entry.actions[1..]) |action| try values.append(alloc, try alloc.print("chain={f}", .{action}));
    return values.toOwnedSlice(alloc);
}

const Scoped = struct { table: []const u8, binding: []const u8 };
fn scope(raw: []const u8) Scoped {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse raw.len;
    if (std.mem.indexOfScalar(u8, raw[0..eq], '/')) |slash| {
        if (slash > 0 and std.mem.indexOfAny(u8, raw[0..slash], "+>") == null) return .{ .table = raw[0..slash], .binding = raw[slash + 1 ..] };
    }
    return .{ .table = "", .binding = raw };
}
pub fn target(alloc: std.mem.Allocator, raw: []const u8) !?Target {
    if (raw.len == 0 or std.mem.eql(u8, raw, "clear")) return .all;
    const scoped = scope(raw);
    if (scoped.binding.len == 0) return .{ .table = try alloc.dupe(u8, scoped.table) };
    var parser = try Binding.Parser.init(scoped.binding);
    var triggers: std.ArrayList(Binding.Trigger) = .empty;
    while (try parser.next()) |part| switch (part) {
        .leader => |trigger| try triggers.append(alloc, trigger),
        .binding => |binding| try triggers.append(alloc, binding.trigger),
        .chain => return null,
    };
    return .{ .key = .{ .table = try alloc.dupe(u8, scoped.table), .triggers = try triggers.toOwnedSlice(alloc) } };
}

/// Each value is a whole native keybind entry. Validation uses one Keybinds
/// instance so chain targeting follows native table/reset parse order exactly.
pub fn parseValues(alloc: std.mem.Allocator, values: []const []const u8) !Draft {
    if (values.len == 0 or values.len > max_values) return error.InvalidFormat;
    var parsed: Config.Keybinds = .{};
    var targets: std.ArrayList(Target) = .empty;
    var bytes: usize = 0;
    for (values) |value| {
        bytes += value.len;
        if (bytes > max_draft_bytes or std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidFormat;
        try parsed.parseCLI(alloc, value);
        if (try target(alloc, value)) |value_target| try targets.append(alloc, value_target);
    }
    return .{ .values = values, .targets = try targets.toOwnedSlice(alloc) };
}
pub fn parseText(alloc: std.mem.Allocator, text: []const u8) !Draft {
    if (text.len > max_draft_bytes) return error.LimitExceeded;
    var values: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const raw = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.trim(u8, raw, " \t").len == 0) continue;
        try values.append(alloc, try alloc.dupe(u8, valueFromLine(raw) orelse raw));
    }
    return try parseValues(alloc, values.items);
}
pub fn valuesText(alloc: std.mem.Allocator, values: []const []const u8) ![:0]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte('\n');
        try output.writer.writeAll(if (value.len == 0) "keybind =" else value);
    }
    return try alloc.dupeSentinel(u8, output.written(), 0);
}

fn overlaps(a: Target, b: Target) bool {
    if (a == .all or b == .all) return true;
    const a_table = switch (a) {
        .key => |key| key.table,
        .table => |name| name,
        .all => unreachable,
    };
    const b_table = switch (b) {
        .key => |key| key.table,
        .table => |name| name,
        .all => unreachable,
    };
    if (!std.mem.eql(u8, a_table, b_table)) return false;
    if (a == .table or b == .table) return true;
    return a.key.overlaps(b.key);
}
pub fn readonly(policy: Policy, desired: Target) bool {
    if (!policy.enabled) return true;
    for (policy.cli) |locked| if (overlaps(locked, desired)) return true;
    return false;
}
pub fn hasConflict(draft: Draft, current: []const Entry, ignored: ?Key) bool {
    for (draft.targets) |desired| for (current) |entry| {
        if (ignored) |key| if (key.equal(entry.key)) continue;
        if (overlaps(desired, .{ .key = entry.key })) return true;
    };
    return false;
}

/// Scope provenance comes from the full source inputs, never a display row.
pub fn sourceOf(alloc: std.mem.Allocator, key: Key, inputs: []const SourceInputs) Source {
    var result: Source = .defaults;
    for (inputs) |layer| for (layer.values) |value| {
        const affected = (target(alloc, value) catch null) orelse continue;
        if (overlaps(affected, .{ .key = key })) result = layer.source;
    };
    return result;
}

fn valueFromLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
        return if (std.mem.eql(u8, trimmed, "keybind")) "" else null;
    };
    if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq], " \t"), "keybind")) return null;
    const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
}
fn checksum(lines: []const []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (lines) |line| {
        hash.update(line);
        hash.update("\n");
    }
    return hash.finalResult();
}
fn markerId(line: []const u8, kind: []const u8) !u64 {
    if (!std.mem.startsWith(u8, line, marker)) return error.Conflict;
    const rest = line[marker.len..];
    if (!std.mem.startsWith(u8, rest, kind)) return error.Conflict;
    const id = std.fmt.parseInt(u64, rest[kind.len..], 10) catch return error.Conflict;
    if (id == 0) return error.Conflict;
    return id;
}

pub fn scan(alloc: std.mem.Allocator, overlay: *const Overlay) !Scan {
    var groups: std.ArrayList(Group) = .empty;
    var blocks: std.ArrayList(Block) = .empty;
    var group_start: ?usize = null;
    var group_id: u64 = 0;
    var maximum: u64 = 0;
    var group_values: std.ArrayList([]const u8) = .empty;
    var last_block: ?usize = null;
    for (overlay.lines.items, 0..) |raw, index| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, marker)) {
            if (std.mem.startsWith(u8, line[marker.len..], "begin ")) {
                if (group_start != null or groups.items.len >= 128) return error.Conflict;
                group_id = try markerId(line, "begin ");
                for (groups.items) |group| if (group.id == group_id) return error.Conflict;
                group_start = index;
                group_values = .empty;
                last_block = null;
                maximum = @max(maximum, group_id);
            } else {
                const start = group_start orelse return error.Conflict;
                if (try markerId(line, "end ") != group_id) return error.Conflict;
                _ = parseValues(alloc, group_values.items) catch return error.Conflict;
                try groups.append(alloc, .{ .id = group_id, .start = start, .end = index + 1, .digest = checksum(overlay.lines.items[start .. index + 1]), .values = group_values.items });
                group_start = null;
                last_block = null;
            }
            continue;
        }
        if (group_start != null) {
            const value = valueFromLine(raw) orelse return error.Conflict;
            try group_values.append(alloc, value);
            continue;
        }
        const value = valueFromLine(raw) orelse continue;
        // A chain inserted after a managed end marker still belongs to that
        // group's native binding. It must not silently retarget during edits.
        if (std.mem.startsWith(u8, value, "chain=") and last_block == null and groups.items.len > 0) return error.Conflict;
        if (std.mem.startsWith(u8, value, "chain=")) if (last_block) |block_index| {
            var block = &blocks.items[block_index];
            const indices = try alloc.alloc(usize, block.lines.len + 1);
            @memcpy(indices[0..block.lines.len], block.lines);
            indices[block.lines.len] = index;
            const values = try alloc.alloc([]const u8, block.values.len + 1);
            @memcpy(values[0..block.values.len], block.values);
            values[block.values.len] = value;
            block.lines = indices;
            block.values = values;
            const raw_lines = try alloc.alloc([]const u8, indices.len);
            for (indices, raw_lines) |line_index, *out| out.* = overlay.lines.items[line_index];
            block.digest = checksum(raw_lines);
            continue;
        };
        const indices = try alloc.alloc(usize, 1);
        indices[0] = index;
        const values = try alloc.alloc([]const u8, 1);
        values[0] = value;
        try blocks.append(alloc, .{ .lines = indices, .values = values, .digest = checksum(&.{raw}), .target = target(alloc, value) catch null });
        last_block = blocks.items.len - 1;
    }
    if (group_start != null) return error.Conflict;
    return .{ .groups = groups.items, .blocks = blocks.items, .next_id = std.math.add(u64, maximum, 1) catch return error.LimitExceeded };
}

pub fn selectionFor(alloc: std.mem.Allocator, scanned: Scan, entry: Entry) !Selection {
    var chosen: ?Selection = null;
    var last_position: usize = 0;
    for (scanned.groups) |group| for (group.values) |value| {
        const affected = (target(alloc, value) catch null) orelse continue;
        if (affected == .key and affected.key.equal(entry.key) and (chosen == null or group.start >= last_position)) {
            chosen = .{ .group = .{ .id = group.id, .digest = group.digest } };
            last_position = group.start;
        }
    };
    for (scanned.blocks) |block| {
        const affected = block.target orelse continue;
        if (affected == .key and affected.key.equal(entry.key) and (chosen == null or block.lines[0] >= last_position)) {
            chosen = .{ .block = .{ .digest = block.digest } };
            last_position = block.lines[0];
        }
    }
    return chosen orelse .{ .lower = entry };
}

/// Mutates only after the complete replacement is parsed and allocated. Current
/// file contents and selected raw-group digests are checked before any write.
pub fn apply(alloc: std.mem.Allocator, overlay: *Overlay, current: []const Entry, policy: Policy, intent: Intent) !void {
    if (!policy.enabled) return error.ReadOnly;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const scanned = try scan(scratch, overlay);
    const skip = try scratch.alloc(bool, overlay.lines.items.len);
    @memset(skip, false);
    var id = scanned.next_id;
    var ignored: ?Key = null;
    var old_lower: ?Entry = null;
    if (intent.selected) |selected| switch (selected) {
        .lower => |entry| {
            if (readonly(policy, .{ .key = entry.key })) return error.ReadOnly;
            var found = false;
            for (current) |live| if (live.key.equal(entry.key)) {
                const expected = try formatEntry(scratch, entry);
                const actual = try formatEntry(scratch, live);
                if (!std.mem.eql(u8, &checksum(expected), &checksum(actual))) return error.Conflict;
                found = true;
                break;
            };
            if (!found) return error.Conflict;
            if (intent.reset) return;
            ignored = entry.key;
            old_lower = entry;
        },
        .group => |expected| {
            const group = for (scanned.groups) |group| {
                if (group.id == expected.id) break group;
            } else return error.Conflict;
            if (!std.mem.eql(u8, &group.digest, &expected.digest)) return error.Conflict;
            const draft = try parseValues(scratch, group.values);
            for (draft.targets) |affected| if (readonly(policy, affected)) return error.ReadOnly;
            @memset(skip[group.start..group.end], true);
            id = group.id;
            for (draft.targets) |affected| if (affected == .key) {
                ignored = affected.key;
            };
        },
        .block => |expected| {
            var matches: usize = 0;
            for (scanned.blocks) |block| if (std.mem.eql(u8, &block.digest, &expected.digest)) {
                matches += 1;
                if (block.target) |affected| {
                    if (readonly(policy, affected)) return error.ReadOnly;
                    if (affected == .key) ignored = affected.key;
                }
                for (block.lines) |index| skip[index] = true;
            };
            if (matches != 1) return error.Conflict;
        },
    };
    var values: std.ArrayList([]const u8) = .empty;
    if (!intent.reset) {
        const draft = try parseValues(scratch, intent.values);
        for (draft.targets) |affected| if (readonly(policy, affected)) return error.ReadOnly;
        if (!intent.conflicts_confirmed and hasConflict(draft, current, ignored)) return error.ConfirmationRequired;
        if (old_lower) |entry| {
            var same = false;
            for (draft.targets) |affected| if (affected == .key and affected.key.equal(entry.key)) {
                same = true;
                break;
            };
            if (!same) try values.append(scratch, try scratch.print("{s}=unbind", .{try formatKey(scratch, entry.key)}));
        }
        try values.appendSlice(scratch, intent.values);
        _ = try parseValues(scratch, values.items);
    }
    var output: std.Io.Writer.Allocating = .init(scratch);
    for (overlay.lines.items, skip) |line, omitted| if (!omitted) try output.writer.print("{s}\n", .{line});
    if (!intent.reset) {
        var formatted = try Overlay.parse(scratch, "");
        defer formatted.deinit();
        try formatted.setAll("keybind", values.items);
        try output.writer.print("{s}begin {d}\n", .{ marker, id });
        try formatted.write(&output.writer);
        try output.writer.print("{s}end {d}\n", .{ marker, id });
    }
    var replacement = try Overlay.parse(overlay.alloc, output.written());
    replacement.existed = overlay.existed;
    overlay.deinit();
    overlay.* = replacement;
}

/// Whether `entry` is one key combination with one action in the root
/// table, which a structured editor can show and write back without loss.
pub fn isSimple(entry: Entry) bool {
    return entry.key.table.len == 0 and entry.key.triggers.len == 1 and
        entry.key.triggers[0].key != .catch_all and entry.actions.len == 1;
}

/// The first entry of `current` that saving `draft` would replace or
/// overlap, as `hasConflict` checks; null when there is none.
pub fn firstConflict(draft: Draft, current: []const Entry, ignored: ?Key) ?usize {
    for (draft.targets) |desired| for (current, 0..) |entry, index| {
        if (ignored) |key| if (key.equal(entry.key)) continue;
        if (overlaps(desired, .{ .key = entry.key })) return index;
    };
    return null;
}

/// `values` with the binding of `key` (its keybind value and the `chain=`
/// values right after it) replaced by `replacement`, and later bindings of
/// the same key dropped; `replacement` is appended when no value binds
/// `key`. Other values keep their order.
pub fn replaceBinding(alloc: std.mem.Allocator, values: []const []const u8, key: Key, replacement: []const []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var replaced = false;
    var skipping = false;
    for (values) |value| {
        if (skipping and std.mem.startsWith(u8, value, "chain=")) continue;
        skipping = false;
        const affected = target(alloc, value) catch null;
        if (affected) |found| if (found == .key and found.key.equal(key)) {
            if (!replaced) try result.appendSlice(alloc, replacement);
            replaced = true;
            skipping = true;
            continue;
        };
        try result.append(alloc, value);
    }
    if (!replaced) try result.appendSlice(alloc, replacement);
    return result.toOwnedSlice(alloc);
}
test "native tables flags chains catch_all and ignore roundtrip without display loss" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const values: []const []const u8 = &.{ "copy/unconsumed:performable:ctrl+a>ctrl+b=text:hello", "chain=text:world", "copy/catch_all=ignore", "global:ctrl+f12=new_window" };
    _ = try parseValues(alloc, values);
    var native: Config.Keybinds = .{};
    for (values) |value| try native.parseCLI(alloc, value);
    const entries = try enumerate(alloc, &native);
    try testing.expectEqual(@as(usize, 3), entries.len);
    var roundtrip: Config.Keybinds = .{};
    for (entries) |entry| for (try formatEntry(alloc, entry)) |value| try roundtrip.parseCLI(alloc, value);
    try testing.expect(native.equal(roundtrip));
}

test "lower rebind emits unbind and reset removes only its managed group" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var native: Config.Keybinds = .{};
    try native.parseCLI(alloc, "ctrl+a=new_tab");
    const entries = try enumerate(alloc, &native);
    var overlay = try Overlay.parse(testing.allocator, "# keep\nunknown = yes\nkeybind = table/\n");
    defer overlay.deinit();
    try apply(testing.allocator, &overlay, entries, .{}, .{ .selected = .{ .lower = entries[0] }, .values = &.{"ctrl+b=new_tab"} });
    const scanned = try scan(alloc, &overlay);
    try testing.expectEqualStrings("ctrl+a=unbind", scanned.groups[0].values[0]);
    try apply(testing.allocator, &overlay, entries, .{}, .{ .selected = .{ .group = .{ .id = scanned.groups[0].id, .digest = scanned.groups[0].digest } }, .reset = true });
    try testing.expectEqualStrings("yes", overlay.get("unknown").?);
    try testing.expectEqualStrings("table/", overlay.get("keybind").?);
}

test "leader conflict and CLI prefix locks use real trigger identity" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var native: Config.Keybinds = .{};
    try native.parseCLI(alloc, "ctrl+a>ctrl+b=new_tab");
    const entries = try enumerate(alloc, &native);
    const draft = try parseValues(alloc, &.{"ctrl+a=new_window"});
    try testing.expect(hasConflict(draft, entries, null));
    try testing.expect(readonly(.{ .cli = &.{.{ .key = entries[0].key }} }, draft.targets[0]));
    try testing.expectError(error.InvalidFormat, parseValues(alloc, &.{"chain=new_tab"}));
}

test "malformed duplicate and hand-edited managed groups cannot be overwritten" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var malformed = try Overlay.parse(testing.allocator, "# gx-keybind-editor begin 1\nunknown = keep\n# gx-keybind-editor end 1\n");
    defer malformed.deinit();
    try testing.expectError(error.Conflict, scan(arena.allocator(), &malformed));
    var duplicate = try Overlay.parse(testing.allocator, "# gx-keybind-editor begin 1\nkeybind = a=ignore\n# gx-keybind-editor end 1\n# gx-keybind-editor begin 1\nkeybind = b=ignore\n# gx-keybind-editor end 1\n");
    defer duplicate.deinit();
    try testing.expectError(error.Conflict, scan(arena.allocator(), &duplicate));
    var overlay = try Overlay.parse(testing.allocator, "# gx-keybind-editor begin 2\nkeybind = a=ignore\n# gx-keybind-editor end 2\n");
    defer overlay.deinit();
    const before = try scan(arena.allocator(), &overlay);
    try overlay.setAll("keybind", &.{"a=new_tab"});
    try testing.expectError(error.Conflict, apply(testing.allocator, &overlay, &.{}, .{}, .{ .selected = .{ .group = .{ .id = 2, .digest = before.groups[0].digest } }, .reset = true }));
}

test "draft preserves explicit empty reset and trailing text action spaces" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const draft = try parseText(arena.allocator(), "keybind =\na=text:hello \ncopy/ctrl+/=ignore");
    try testing.expectEqualStrings("", draft.values[0]);
    try testing.expectEqualStrings("a=text:hello ", draft.values[1]);
    try testing.expectEqualStrings("copy", draft.targets[2].key.table);
}

test "allocation failure leaves the original overlay intact" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var overlay = try Overlay.parse(testing.allocator, "# original\nunknown = keep\n");
            defer overlay.deinit();
            apply(alloc, &overlay, &.{}, .{}, .{ .values = &.{"ctrl+a=new_tab"} }) catch |err| {
                try testing.expectEqualStrings("keep", overlay.get("unknown").?);
                try testing.expect(overlay.get("keybind") == null);
                try testing.expectEqualStrings("# original", overlay.lines.items[0]);
                return err;
            };
        }
    }.check, .{});
}

test "isSimple accepts only one root key with one action" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var native: Config.Keybinds = .{};
    for ([_][]const u8{ "ctrl+a=new_tab", "ctrl+b>c=new_tab", "copy/ctrl+d=new_tab", "ctrl+e=text:a", "chain=text:b", "catch_all=ignore" }) |value| try native.parseCLI(alloc, value);
    var simple: usize = 0;
    for (try enumerate(alloc, &native)) |entry| {
        if (!isSimple(entry)) continue;
        simple += 1;
        try testing.expectEqualStrings("ctrl+a", try formatKey(alloc, entry.key));
    }
    try testing.expectEqual(@as(usize, 1), simple);
}

test "replaceBinding swaps one binding with its chain and keeps the rest" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = (try target(alloc, "ctrl+b=new_tab")).?.key;
    const values: []const []const u8 = &.{ "ctrl+a=unbind", "ctrl+b=text:x", "chain=text:y", "ctrl+c=new_tab", "ctrl+b=new_window" };
    const replaced = try replaceBinding(alloc, values, key, &.{"ctrl+alt+b=new_tab"});
    try testing.expectEqual(@as(usize, 3), replaced.len);
    try testing.expectEqualStrings("ctrl+a=unbind", replaced[0]);
    try testing.expectEqualStrings("ctrl+alt+b=new_tab", replaced[1]);
    try testing.expectEqualStrings("ctrl+c=new_tab", replaced[2]);
    const appended = try replaceBinding(alloc, &.{"ctrl+a=unbind"}, key, &.{"ctrl+b=new_tab"});
    try testing.expectEqual(@as(usize, 2), appended.len);
    try testing.expectEqualStrings("ctrl+b=new_tab", appended[1]);
}

test "firstConflict names the overlapped entry and skips the edited one" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var native: Config.Keybinds = .{};
    try native.parseCLI(alloc, "ctrl+a>ctrl+b=new_tab");
    try native.parseCLI(alloc, "ctrl+x=new_window");
    const entries = try enumerate(alloc, &native);
    const draft = try parseValues(alloc, &.{"ctrl+x=close_surface"});
    const index = firstConflict(draft, entries, null).?;
    try testing.expectEqualStrings("ctrl+x", try formatKey(alloc, entries[index].key));
    try testing.expectEqual(@as(?usize, null), firstConflict(draft, entries, entries[index].key));
    try testing.expect(firstConflict(try parseValues(alloc, &.{"ctrl+a=ignore"}), entries, null) != null);
}
