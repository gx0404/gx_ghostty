//! Launch profiles (`gx.profiles`) for the GTK apprt: the profiles of the
//! running system plus `gx-launch-profile`, with display names in the
//! current UI language and the arguments that start them through the
//! `app.new-tab` and `app.new-window-command` actions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");

const log = std.log.scoped(.gtk_gx_launch);

pub const Item = struct {
    /// The stable profile id, e.g. `gx-zsh` or `custom:Python`.
    id: [:0]const u8,

    /// The name in the current UI language.
    name: [:0]const u8,

    /// The arguments for `app.new-tab` and `app.new-window-command`, in
    /// the syntax of `class/Overrides.zig::parse`.
    args: []const [:0]const u8,
};

/// Launch profiles. All memory is owned by `arena`.
pub const List = struct {
    arena: ArenaAllocator,
    items: []const Item = &.{},

    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The profile whose id or name is `query`; names match ignoring ASCII
    /// case.
    pub fn find(self: *const List, query: []const u8) ?*const Item {
        for (self.items) |*item| {
            if (std.mem.eql(u8, item.id, query)) return item;
        }
        for (self.items) |*item| {
            if (std.ascii.eqlIgnoreCase(item.name, query)) return item;
        }
        return null;
    }
};

/// Detects the profiles of the running system and appends the
/// `gx-launch-profile` entries of `config`. Detection only probes a few
/// paths, so it runs whenever a menu is rebuilt.
pub fn detect(alloc: Allocator, config: *const configpkg.Config) Allocator.Error!List {
    var list: List = .{ .arena = .init(alloc) };
    errdefer list.deinit();
    const arena = list.arena.allocator();

    var custom: std.ArrayList(gx.profiles.Custom) = .empty;
    var it = config.@"gx-launch-profile".iterator();
    while (it.next()) |entry| {
        try custom.append(arena, .{ .name = entry.key_ptr.*, .command = entry.value_ptr.* });
    }

    var env = global.environMap() catch |err| {
        log.warn("cannot read the environment to detect launch profiles err={}", .{err});
        return list;
    };
    defer env.deinit();

    var profiles = try gx.profiles.detectSystem(alloc, global.io(), &env, custom.items);
    defer profiles.deinit();

    const items = try arena.alloc(Item, profiles.profiles.len);
    for (profiles.profiles, items) |profile, *item| {
        const name = try gx.profiles.displayName(arena, profile);
        item.* = .{
            .id = try arena.dupeZ(u8, profile.id),
            .name = try arena.dupeZ(u8, name),
            .args = try args(arena, profile.command),
        };
    }
    list.items = items;
    return list;
}

/// The `Overrides.parse` arguments that start `command`. Detected shells
/// run through `-e`, which takes the following arguments verbatim (paths
/// may contain spaces); custom profiles are command lines in the syntax
/// of the `command` option and go through `--command=`.
pub fn args(alloc: Allocator, command: gx.profiles.Command) Allocator.Error![]const [:0]const u8 {
    switch (command) {
        .argv => |argv| {
            const result = try alloc.alloc([:0]const u8, argv.len + 1);
            result[0] = "-e";
            for (argv, result[1..]) |arg, *out| out.* = try alloc.dupeZ(u8, arg);
            return result;
        },
        .command_line => |line| {
            const result = try alloc.alloc([:0]const u8, 1);
            result[0] = try std.fmt.allocPrintSentinel(alloc, "--command={s}", .{line}, 0);
            return result;
        },
    }
}

test "args runs detected shells verbatim with -e" {
    const testing = std.testing;
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try args(arena.allocator(), .{ .argv = &.{ "/opt/My Shell/bin/zsh", "-l" } });
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("-e", result[0]);
    try testing.expectEqualStrings("/opt/My Shell/bin/zsh", result[1]);
    try testing.expectEqualStrings("-l", result[2]);
}

test "args passes custom command lines to --command" {
    const testing = std.testing;
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try args(arena.allocator(), .{ .command_line = "direct:python3 -i" });
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("--command=direct:python3 -i", result[0]);
}

test "List.find matches ids, then names ignoring case" {
    const testing = std.testing;
    var list: List = .{ .arena = .init(testing.allocator) };
    defer list.deinit();
    list.items = &.{
        .{ .id = "bash", .name = "Bash", .args = &.{} },
        .{ .id = "custom:bash", .name = "My Bash", .args = &.{} },
    };

    try testing.expectEqualStrings("bash", list.find("bash").?.id);
    try testing.expectEqualStrings("custom:bash", list.find("custom:bash").?.id);
    try testing.expectEqualStrings("custom:bash", list.find("my bash").?.id);
    try testing.expectEqual(@as(?*const Item, null), list.find("fish"));
}

test "detect lists custom profiles after the detected ones" {
    const testing = std.testing;
    var config: configpkg.Config = try .default(testing.allocator);
    defer config.deinit();
    try config.@"gx-launch-profile".parseCLI(config._arena.?.allocator(), "Logs=direct:tail -f /tmp/x.log");

    var list = try detect(testing.allocator, &config);
    defer list.deinit();

    const last = list.items[list.items.len - 1];
    try testing.expectEqualStrings("custom:Logs", last.id);
    try testing.expectEqualStrings("Logs", last.name);
    try testing.expectEqual(@as(usize, 1), last.args.len);
    try testing.expectEqualStrings("--command=direct:tail -f /tmp/x.log", last.args[0]);
    for (list.items) |item| try testing.expect(item.args.len > 0);
}
