//! Overlay-owned launch profile edits replayed against the latest file.
//! Intents borrow their strings for one synchronous commit; failures leave the
//! caller's draft intact. User/include/CLI files are never written.
const std = @import("std");
const Overlay = @import("gui_settings.zig").Overlay;
const Config = @import("../config/Config.zig");
const profile_key = "gx-launch-profile";

pub const Policy = struct {
    enabled: bool = true,
    cli_all: bool = false,
    cli_names: []const []const u8 = &.{},
    reserved_names: []const []const u8 = &.{},
    command_readonly: bool = false,

    pub fn editable(self: Policy, name: []const u8) bool {
        if (!self.enabled or self.cli_all) return false;
        for (self.cli_names) |value| if (std.mem.eql(u8, name, value)) return false;
        return true;
    }
};

pub const Edit = union(enum) {
    /// expected=null creates a new profile; otherwise edit/rename an owned one.
    put: struct { old_name: ?[]const u8 = null, expected: ?[]const u8 = null, name: []const u8, command: []const u8 },
    remove: struct { name: []const u8, expected: []const u8 },
    /// null command restores the lower/default command by removing the key.
    default: struct { expected: ?[]const u8, command: ?[]const u8 },
};

pub const Pair = struct { name: []const u8, command: []const u8 };
pub fn pair(value: []const u8) ?Pair {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return null;
    return .{ .name = std.mem.trim(u8, value[0..eq], &std.ascii.whitespace), .command = std.mem.trim(u8, value[eq + 1 ..], &std.ascii.whitespace) };
}

/// Effective value owned by the overlay, respecting reset and deletion entries.
/// Returns a borrowed view into values, never a command from a lower layer.
pub fn owned(values: []const []const u8, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (values) |value| {
        if (value.len == 0) {
            result = null;
            continue;
        }
        const entry = pair(value) orelse continue;
        if (std.mem.eql(u8, entry.name, name)) result = if (entry.command.len == 0) null else entry.command;
    }
    return result;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 1024 or !std.unicode.utf8ValidateSlice(name) or
        !std.mem.eql(u8, name, std.mem.trim(u8, name, &std.ascii.whitespace)) or std.mem.indexOfAny(u8, name, "=\r\n\x00") != null) return error.InvalidProfile;
}
fn validateCommand(alloc: std.mem.Allocator, command: []const u8) !void {
    if (command.len == 0 or std.mem.indexOfAny(u8, command, "\r\n\x00") != null or !std.unicode.utf8ValidateSlice(command)) return error.InvalidProfile;
    var parsed: Config.Command = undefined;
    try parsed.parseCLI(alloc, command);
}
fn equalOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
    return b == null;
}

/// Replays one reviewed intent into a freshly loaded overlay. All getAll data
/// remains borrowed until setAll formats its replacement lines.
pub fn apply(alloc: std.mem.Allocator, overlay: *Overlay, edit: Edit, policy: Policy) !void {
    if (!policy.enabled) return error.ReadOnly;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    if (edit == .default) {
        if (policy.command_readonly) return error.ReadOnly;
        const change = edit.default;
        if (!equalOptional(overlay.get("command"), change.expected)) return error.Conflict;
        if (change.command) |command| {
            try validateCommand(scratch, command);
            try overlay.set("command", command);
        } else _ = overlay.delete("command");
        return;
    }
    const original = try overlay.getAll(scratch, profile_key);
    var values: std.ArrayList([]const u8) = .empty;
    const old_name = switch (edit) {
        .put => |change| change.old_name,
        .remove => |change| change.name,
        .default => unreachable,
    };
    if (old_name) |name| {
        if (!policy.editable(name)) return error.ReadOnly;
        const expected = switch (edit) {
            .put => |change| change.expected,
            .remove => |change| change.expected,
            .default => unreachable,
        };
        if (expected == null or !equalOptional(owned(original, name), expected)) return error.Conflict;
    }
    if (edit == .put) {
        const change = edit.put;
        try validateName(change.name);
        try validateCommand(scratch, change.command);
        if (!policy.editable(change.name)) return error.ReadOnly;
        const renaming = if (old_name) |old| !std.mem.eql(u8, old, change.name) else true;
        if (renaming) {
            if (owned(original, change.name) != null) return error.DuplicateName;
            for (policy.reserved_names) |name| if (std.mem.eql(u8, name, change.name)) return error.DuplicateName;
        }
    }
    // Remove the old name's complete history. Unrelated duplicates, reset and
    // deletion markers retain their order; removing a shadow reveals its lower
    // source unless an independent reset still masks that source.
    for (original) |raw| {
        if (old_name) |name| if (pair(raw)) |entry| {
            if (std.mem.eql(u8, entry.name, name)) continue;
        };
        try values.append(scratch, raw);
    }
    if (edit == .put) {
        const change = edit.put;
        try values.append(scratch, try std.fmt.allocPrint(scratch, "{s}={s}", .{ change.name, change.command }));
    }
    try overlay.setAll(profile_key, values.items);
}

pub fn commit(alloc: std.mem.Allocator, io: std.Io, path: []const u8, edit: Edit, policy: Policy) !void {
    var latest = try Overlay.load(alloc, io, path);
    defer latest.deinit();
    try apply(alloc, &latest, edit, policy);
    try latest.save(io, path);
}

/// Where a listed launch profile comes from, which decides whether the
/// settings UI can edit it.
pub const Source = enum {
    /// A `gx-launch-profile` entry the settings overlay owns: editable.
    overlay,
    /// A shell detected on this system (not a `custom:` profile).
    detected,
    /// A `gx-launch-profile` entry of the user's configuration files.
    config_file,
    /// A `gx-launch-profile` entry of the command line, which wins.
    command_line,
    /// Editing is off (no Ghostty GX layers, or they cannot be read).
    disabled,
};

/// The source of the listed profile `id` (`custom:<name>` for
/// `gx-launch-profile` entries) for `policy` and the overlay's raw
/// `gx-launch-profile` values.
pub fn source(policy: Policy, values: []const []const u8, id: []const u8) Source {
    if (!policy.enabled) return .disabled;
    const name = std.mem.cutPrefix(u8, id, "custom:") orelse return .detected;
    if (!policy.editable(name)) return .command_line;
    return if (owned(values, name) != null) .overlay else .config_file;
}

/// Whether a draft differs from what it was opened with: a new profile
/// (`old_name` null) once anything is typed, an existing one once its name
/// or its overlay-owned command (`expected`) changed.
pub fn draftChanged(old_name: ?[]const u8, expected: ?[]const u8, name: []const u8, command: []const u8) bool {
    const old = old_name orelse return name.len > 0 or command.len > 0;
    return !std.mem.eql(u8, old, name) or !equalOptional(expected, command);
}

test "profile edits preserve unrelated latest values reset markers and comments" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator, "# note\ngx-launch-profile = Old=old-command\ngx-launch-profile =\ngx-launch-profile = Old=current-command\ngx-launch-profile = External=external-command\nunknown = keep\n");
    defer overlay.deinit();
    try apply(testing.allocator, &overlay, .{ .put = .{ .old_name = "Old", .expected = "current-command", .name = "New", .command = "new-command" } }, .{});
    const values = try overlay.getAll(testing.allocator, profile_key);
    defer testing.allocator.free(values);
    try testing.expectEqualStrings("", values[0]);
    try testing.expectEqualStrings("external-command", owned(values, "External").?);
    try testing.expectEqualStrings("new-command", owned(values, "New").?);
    try testing.expect(owned(values, "Old") == null);
    try testing.expectEqualStrings("keep", overlay.get("unknown").?);
    try testing.expectEqualStrings("# note", overlay.lines.items[0]);
}

test "profile stale draft conflict leaves externally edited value unchanged" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator, "gx-launch-profile = A=external\n");
    defer overlay.deinit();
    try testing.expectError(error.Conflict, apply(testing.allocator, &overlay, .{ .remove = .{ .name = "A", .expected = "draft-base" } }, .{}));
    try testing.expectEqualStrings("A=external", overlay.get(profile_key).?);
    try testing.expectError(error.ReadOnly, apply(testing.allocator, &overlay, .{ .remove = .{ .name = "A", .expected = "external" } }, .{ .cli_names = &.{"A"} }));
}

test "profile delete reveals lower values by removing all owned name entries" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator, "gx-launch-profile = A=old\ngx-launch-profile = A=current\ngx-launch-profile = B=keep\ncommand = unchanged\n");
    defer overlay.deinit();
    try apply(testing.allocator, &overlay, .{ .remove = .{ .name = "A", .expected = "current" } }, .{});
    const values = try overlay.getAll(testing.allocator, profile_key);
    defer testing.allocator.free(values);
    try testing.expectEqual(@as(usize, 1), values.len);
    try testing.expectEqualStrings("B=keep", values[0]);
    try testing.expectEqualStrings("unchanged", overlay.get("command").?);
}

test "profile validation rejects injection readonly collisions and accidental default rewrites" {
    const testing = std.testing;
    var overlay = try Overlay.init(testing.allocator);
    defer overlay.deinit();
    try testing.expectError(error.InvalidProfile, apply(testing.allocator, &overlay, .{ .put = .{ .name = "A\nB", .command = "sh" } }, .{}));
    try testing.expectError(error.InvalidProfile, apply(testing.allocator, &overlay, .{ .put = .{ .name = "A", .command = "sh\ncommand=bad" } }, .{}));
    try testing.expectError(error.DuplicateName, apply(testing.allocator, &overlay, .{ .put = .{ .name = "ReadOnly", .command = "sh" } }, .{ .reserved_names = &.{"ReadOnly"} }));
    try apply(testing.allocator, &overlay, .{ .default = .{ .expected = null, .command = "direct:bash" } }, .{});
    try testing.expectEqualStrings("direct:bash", overlay.get("command").?);
    try apply(testing.allocator, &overlay, .{ .default = .{ .expected = "direct:bash", .command = null } }, .{});
    try testing.expect(overlay.get("command") == null);
}

test "profile commit rereads externally added entries and preserves the file after conflict" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fs.path.join(testing.allocator, &.{ root, "gui-settings.ghostty" });
    defer testing.allocator.free(path);
    // The draft was opened before External was written by another editor.
    try tmp.dir.writeFile(io, .{ .sub_path = "gui-settings.ghostty", .data = "gx-launch-profile = A=before\ngx-launch-profile = External=keep\nother = unchanged\n" });
    try commit(testing.allocator, io, path, .{ .put = .{ .old_name = "A", .expected = "before", .name = "A", .command = "after" } }, .{});
    var latest = try Overlay.load(testing.allocator, io, path);
    defer latest.deinit();
    const values = try latest.getAll(testing.allocator, profile_key);
    defer testing.allocator.free(values);
    try testing.expectEqualStrings("keep", owned(values, "External").?);
    try testing.expectEqualStrings("after", owned(values, "A").?);
    const before = try tmp.dir.readFileAlloc(io, "gui-settings.ghostty", testing.allocator, .limited(8192));
    defer testing.allocator.free(before);
    try testing.expectError(error.Conflict, commit(testing.allocator, io, path, .{ .remove = .{ .name = "A", .expected = "stale" } }, .{}));
    const after = try tmp.dir.readFileAlloc(io, "gui-settings.ghostty", testing.allocator, .limited(8192));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "profile source tells overlay config command-line detected and disabled entries apart" {
    const testing = std.testing;
    const values: []const []const u8 = &.{ "Gone=sh", "", "Mine=sh", "Again=sh" };
    try testing.expectEqual(Source.overlay, source(.{}, values, "custom:Mine"));
    try testing.expectEqual(Source.overlay, source(.{}, values, "custom:Again"));
    // A reset marker hides earlier overlay entries, so a lower source shows.
    try testing.expectEqual(Source.config_file, source(.{}, values, "custom:Gone"));
    try testing.expectEqual(Source.config_file, source(.{}, values, "custom:Lower"));
    try testing.expectEqual(Source.detected, source(.{}, values, "gx-zsh"));
    try testing.expectEqual(Source.command_line, source(.{ .cli_names = &.{"Mine"} }, values, "custom:Mine"));
    try testing.expectEqual(Source.command_line, source(.{ .cli_all = true }, values, "custom:Lower"));
    try testing.expectEqual(Source.disabled, source(.{ .enabled = false }, values, "custom:Mine"));
    try testing.expectEqual(Source.disabled, source(.{ .enabled = false }, values, "bash"));
}

test "profile draft changes compare against the opened name and owned command" {
    const testing = std.testing;
    try testing.expect(!draftChanged(null, null, "", ""));
    try testing.expect(draftChanged(null, null, "A", ""));
    try testing.expect(draftChanged(null, null, "", "sh"));
    try testing.expect(!draftChanged("A", "sh", "A", "sh"));
    try testing.expect(draftChanged("A", "sh", "B", "sh"));
    try testing.expect(draftChanged("A", "sh", "A", "bash"));
    try testing.expect(draftChanged("A", null, "A", "sh"));
}
