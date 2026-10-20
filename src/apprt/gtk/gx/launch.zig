//! Launch profiles (`gx.profiles`) for the GTK apprt: the profiles of the
//! running system plus `gx-launch-profile`, with display names in the
//! current UI language and the arguments that start them through the
//! `app.new-tab` and `app.new-window-command` actions.
//!
//! Without a configured `command`, new terminals start the default launch
//! profile when it is GX Zsh (`defaultCommand`), as on Windows; otherwise
//! they keep the shell `Config.finalize` chose (the upstream login shell).
//!
//! The application keeps the detected shells (`list`), so the menus of
//! every window, which follow each configuration change, do not probe the
//! file system each time; detection runs again when `PATH` or `SHELL`
//! change, or when the shells are older than `cache_lifetime_us`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glib = @import("glib");
const gobject = @import("gobject");

const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const Application = @import("../class/application.zig").Application;

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

    /// The profile new terminals start, an index into `items`: the one
    /// `command` runs (`gx.settings_map.commandProfile`).
    default: ?usize = null,

    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Exact identity lookup for stored or menu-carried profile references.
    /// A renamed or missing id must never fall back to a display name.
    pub fn findId(self: *const List, id: []const u8) ?*const Item {
        for (self.items) |*item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
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

/// How long the application keeps the detected shells, in microseconds.
pub const cache_lifetime_us: i64 = 10 * std.time.us_per_s;

/// The object data key on the application holding its `Cache`.
const cache_key = "gx-launch-profiles";

const Cache = struct {
    alloc: Allocator,
    shells: gx.profiles.Cache = .{},

    /// When `shells` were detected (`glib.getMonotonicTime`).
    detected_us: i64 = 0,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Cache = @ptrCast(@alignCast(data orelse return));
        self.shells.deinit();
        self.alloc.destroy(self);
    }
};

fn appCache(app: *Application) ?*Cache {
    const object = app.as(gobject.Object);
    if (object.getData(cache_key)) |data| return @ptrCast(@alignCast(data));
    const alloc = app.allocator();
    const cache = alloc.create(Cache) catch return null;
    cache.* = .{ .alloc = alloc };
    object.setDataFull(cache_key, cache, &Cache.destroy);
    return cache;
}

/// The profiles of the running system for `config`, with the shells the
/// application detected (see the file header).
pub fn list(app: *Application, config: *const configpkg.Config) Allocator.Error!List {
    const alloc = app.allocator();
    const cache = appCache(app) orelse return try detect(alloc, config);
    const now = glib.getMonotonicTime();

    var result: List = .{ .arena = .init(alloc) };
    errdefer result.deinit();
    const custom = try customProfiles(result.arena.allocator(), config);

    var env = global.environMap() catch |err| {
        log.warn("cannot read the environment to detect launch profiles err={}", .{err});
        return result;
    };
    defer env.deinit();

    const detections = cache.shells.detections;
    var profiles = try cachedProfiles(cache, alloc, &env, custom, now);
    defer profiles.deinit();
    try fill(&result, profiles.profiles, config);
    gx.perf.record("gtk_launch_profiles", @intCast(@max(glib.getMonotonicTime() - now, 0)));
    if (gx.perf.enabled()) log.info("launch profile detections={d} cached={}", .{ cache.shells.detections, cache.shells.detections == detections });
    return result;
}

/// Detects the profiles of the running system and appends the
/// `gx-launch-profile` entries of `config`, without the application's
/// cache.
pub fn detect(alloc: Allocator, config: *const configpkg.Config) Allocator.Error!List {
    var result: List = .{ .arena = .init(alloc) };
    errdefer result.deinit();
    const custom = try customProfiles(result.arena.allocator(), config);

    var env = global.environMap() catch |err| {
        log.warn("cannot read the environment to detect launch profiles err={}", .{err});
        return result;
    };
    defer env.deinit();

    var profiles = try gx.profiles.detectSystem(alloc, global.io(), &env, custom);
    defer profiles.deinit();
    try fill(&result, profiles.profiles, config);
    return result;
}

/// The shells the application detected, then `custom`; detects again when
/// the environment changed or the shells are older than `cache_lifetime_us`.
/// The caller owns the list.
fn cachedProfiles(
    cache: *Cache,
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    custom: []const gx.profiles.Custom,
    now: i64,
) Allocator.Error!gx.profiles.List {
    if (now - cache.detected_us > cache_lifetime_us) cache.shells.invalidate();
    const detections = cache.shells.detections;
    const profiles = try cache.shells.list(alloc, global.io(), env, custom);
    if (cache.shells.detections != detections) cache.detected_us = now;
    return profiles;
}

/// The launch profile new terminals start when no `command` is configured.
pub const Default = struct {
    /// The stable profile id (`gx-zsh`), for the launch origin.
    id: [:0]const u8,

    /// The command that starts it.
    command: configpkg.Command,
};

/// The default launch profile for the detected `profiles`: null when
/// `command` is `configured` in any configuration layer
/// (`gx.profiles.commandConfigured`), or when the platform's default
/// profile (`gx.profiles.defaultProfile`) is not GX Zsh, so that new
/// terminals keep the shell `Config.finalize` chose. The id and command
/// are copied into `alloc` (the arena of the surface configuration).
pub fn resolveDefault(
    alloc: Allocator,
    configured: bool,
    profiles: []const gx.profiles.Profile,
    platform: gx.profiles.Platform,
) Allocator.Error!?Default {
    if (configured) return null;
    const profile = gx.profiles.defaultProfile(profiles, platform) orelse return null;
    if (profile.kind != .gx_zsh) return null;
    const argv = switch (profile.command) {
        .argv => |argv| argv,
        .command_line => return null,
    };
    if (argv.len == 0) return null;
    const copy = try alloc.alloc([:0]const u8, argv.len);
    for (argv, copy) |arg, *out| out.* = try alloc.dupeZ(u8, arg);
    return .{
        .id = try alloc.dupeZ(u8, profile.id),
        .command = .{ .direct = copy },
    };
}

/// The default launch profile of new terminals on the running system for
/// `config` (`resolveDefault`), with the shells the application detected.
/// Allocates the result with `alloc`. When the environment cannot be read
/// it logs and returns null: new terminals keep the upstream shell.
pub fn defaultCommand(
    app: *Application,
    config: *const configpkg.Config,
    alloc: Allocator,
) Allocator.Error!?Default {
    if (gx.profiles.commandConfigured(config._replay_steps.items)) return null;
    var env = global.environMap() catch |err| {
        log.warn("cannot read the environment to detect the default shell err={}", .{err});
        return null;
    };
    defer env.deinit();
    const gpa = app.allocator();
    var profiles = if (appCache(app)) |cache|
        try cachedProfiles(cache, gpa, &env, &.{}, glib.getMonotonicTime())
    else
        try gx.profiles.detectSystem(gpa, global.io(), &env, &.{});
    defer profiles.deinit();
    return try resolveDefault(alloc, false, profiles.profiles, .native);
}

fn customProfiles(arena: Allocator, config: *const configpkg.Config) Allocator.Error![]const gx.profiles.Custom {
    var custom: std.ArrayList(gx.profiles.Custom) = .empty;
    var it = config.@"gx-launch-profile".iterator();
    while (it.next()) |entry| {
        try custom.append(arena, .{ .name = entry.key_ptr.*, .command = entry.value_ptr.* });
    }
    return custom.items;
}

/// Fills `result` with the items of `profiles`, copied into its arena,
/// and the default profile of `config`: the profile of a configured
/// `command`, else the platform's default profile (GX Zsh, then the login
/// shell), which new terminals start (`defaultCommand`). The `command`
/// that `Config.finalize` fills in is not a configured one.
fn fill(result: *List, profiles: []const gx.profiles.Profile, config: *const configpkg.Config) Allocator.Error!void {
    const arena = result.arena.allocator();
    const items = try arena.alloc(Item, profiles.len);
    for (profiles, items) |profile, *item| {
        const name = try gx.profiles.displayName(arena, profile);
        item.* = .{
            .id = try arena.dupeZ(u8, profile.id),
            .name = try arena.dupeZ(u8, name),
            .args = try args(arena, profile.command),
        };
    }
    result.items = items;
    const configured = gx.profiles.commandConfigured(config._replay_steps.items);
    result.default = try gx.settings_map.commandProfile(
        arena,
        profiles,
        if (configured) config.command else null,
        gx.profiles.Platform.native,
    );
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
    var list_: List = .{ .arena = .init(testing.allocator) };
    defer list_.deinit();
    list_.items = &.{
        .{ .id = "bash", .name = "Bash", .args = &.{} },
        .{ .id = "custom:bash", .name = "My Bash", .args = &.{} },
    };

    try testing.expectEqualStrings("bash", list_.find("bash").?.id);
    try testing.expectEqualStrings("custom:bash", list_.find("custom:bash").?.id);
    try testing.expectEqualStrings("custom:bash", list_.find("my bash").?.id);
    try testing.expectEqual(@as(?*const Item, null), list_.find("fish"));
}

fn testLoad(config: *configpkg.Config, text: []const u8) !void {
    const cli = @import("../../../cli.zig");
    var reader: std.Io.Reader = .fixed(text);
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = "test" };
    try config.loadIter(std.testing.allocator, &iter);
}

/// GX Zsh, a login shell and bash with distinct program names.
const test_profiles = [_]gx.profiles.Profile{
    .{ .id = "gx-zsh", .name = "GX Zsh", .command = .{ .argv = &.{"/usr/lib/ohmyzsh-gx/bin/gx-zsh"} }, .kind = .gx_zsh },
    .{ .id = "login-shell", .name = "Login Shell", .command = .{ .argv = &.{"/usr/bin/zsh"} }, .kind = .login_shell },
    .{ .id = "bash", .name = "Bash", .command = .{ .argv = &.{"/usr/bin/bash"} }, .kind = .bash },
};

test "resolveDefault starts GX Zsh only when it is the default and command is not configured" {
    const testing = std.testing;
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const default = (try resolveDefault(alloc, false, &test_profiles, .linux)).?;
    try testing.expectEqualStrings("gx-zsh", default.id);
    try testing.expectEqual(@as(usize, 1), default.command.direct.len);
    try testing.expectEqualStrings("/usr/lib/ohmyzsh-gx/bin/gx-zsh", default.command.direct[0]);
    // Copied into the surface configuration's arena, not borrowed from the detected list.
    try testing.expect(default.command.direct[0].ptr != test_profiles[0].command.argv[0].ptr);

    try testing.expect(try resolveDefault(alloc, true, &test_profiles, .linux) == null);
    // Only the login shell and bash: new terminals keep the upstream shell.
    try testing.expect(try resolveDefault(alloc, false, test_profiles[1..], .linux) == null);
    try testing.expect(try resolveDefault(alloc, false, &.{}, .linux) == null);
}

test "fill marks GX Zsh as the default unless command is configured" {
    const testing = std.testing;
    var config: configpkg.Config = try .default(testing.allocator);
    defer config.deinit();
    // The shell Config.finalize fills in is not a configured command.
    config.command = .{ .shell = "/usr/bin/bash" };

    var detected: List = .{ .arena = .init(testing.allocator) };
    defer detected.deinit();
    try fill(&detected, &test_profiles, &config);
    try testing.expectEqual(@as(?usize, 0), detected.default);

    var without_gx: List = .{ .arena = .init(testing.allocator) };
    defer without_gx.deinit();
    try fill(&without_gx, test_profiles[1..], &config);
    try testing.expectEqualStrings("login-shell", without_gx.items[without_gx.default.?].id);

    try testLoad(&config, "command = /usr/bin/bash\n");
    var configured: List = .{ .arena = .init(testing.allocator) };
    defer configured.deinit();
    try fill(&configured, &test_profiles, &config);
    try testing.expectEqualStrings("bash", configured.items[configured.default.?].id);
}

test "detect lists custom profiles after the detected ones and marks the default" {
    const testing = std.testing;
    var config: configpkg.Config = try .default(testing.allocator);
    defer config.deinit();
    // Through a configuration file, so that the replay steps record `command`.
    try testLoad(&config,
        \\gx-launch-profile = Logs=direct:tail -f /tmp/x.log
        \\command = direct:tail -f /tmp/x.log
        \\
    );

    var result = try detect(testing.allocator, &config);
    defer result.deinit();

    const last = result.items[result.items.len - 1];
    try testing.expectEqualStrings("custom:Logs", last.id);
    try testing.expectEqualStrings("Logs", last.name);
    try testing.expectEqual(@as(usize, 1), last.args.len);
    try testing.expectEqualStrings("--command=direct:tail -f /tmp/x.log", last.args[0]);
    try testing.expectEqual(@as(?usize, result.items.len - 1), result.default);
    for (result.items) |item| try testing.expect(item.args.len > 0);
}

test "List.findId does not retarget a stale profile id to a display name" {
    var profiles: List = .{ .arena = .init(std.testing.allocator) };
    defer profiles.deinit();
    profiles.items = &.{.{ .id = "custom:New", .name = "custom:Old", .args = &.{} }};
    try std.testing.expect(profiles.findId("custom:Old") == null);
    try std.testing.expect(profiles.findId("CUSTOM:NEW") == null);
    try std.testing.expectEqualStrings("custom:New", profiles.findId("custom:New").?.id);
    try std.testing.expect(profiles.find("custom:Old") != null);
}
