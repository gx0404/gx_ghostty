//! Ghostty GX configuration layering, used by `Config.load` (fork patch
//! GX-0010). From lowest to highest precedence:
//!
//!   1. the Ghostty GX defaults (`defaults.ghostty`, plus
//!      `defaults-windows.ghostty` on Windows), embedded in the binary;
//!   2. the user configuration files and every `config-file` they or the
//!      command line include;
//!   3. the settings UI overlay `gui-settings.ghostty` (see
//!      `gui_settings.zig`), next to the preferred user configuration file;
//!   4. command-line flags, with `-e` and its command last.
//!
//! The files are read in upstream order; the recorded replay steps are
//! then reordered by layer and the configuration is rebuilt from them, so
//! theme loading and conditional reloads (which replay the same steps)
//! keep the layer order. The defaults are plain configuration lines: a
//! user `theme` replaces `theme = GX Mocha`, and explicit colors still
//! override the theme. When a layer sets a `font-family*` key, its values
//! replace the list from lower layers instead of extending it, the same
//! way command-line font families replace configured ones upstream.
//!
//! Setting the environment variable `GHOSTTY_GX_DEFAULTS=0` (or `false`,
//! `off`, `no`) loads the configuration exactly like upstream Ghostty: no
//! defaults, no overlay, upstream order.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Config = @import("../config/Config.zig");
const file_load = @import("../config/file_load.zig");
const themepkg = @import("../config/theme.zig");
const cli = @import("../cli.zig");
const global = @import("../global.zig");
const gui_settings = @import("gui_settings.zig");
const gx_theme = @import("theme.zig");

const log = std.log.scoped(.gx_config);

/// The Ghostty GX defaults for this platform, in configuration file
/// syntax.
pub const defaults: []const u8 = @embedFile("defaults.ghostty") ++ switch (builtin.os.tag) {
    .windows => @embedFile("defaults-windows.ghostty"),
    else => "",
};

/// The environment variable that turns the Ghostty GX layering off.
pub const disable_env = "GHOSTTY_GX_DEFAULTS";

/// The location reported in diagnostics for lines of `defaults`.
const defaults_location = "<Ghostty GX defaults>";

/// A recorded configuration input (`Config._replay_steps`).
const Step = std.meta.Elem(@FieldType(@FieldType(Config, "_replay_steps"), "items"));

/// The keys whose values replace, rather than extend, the values from
/// lower layers, with the step that resets each of them.
const replaced_keys = [_]struct { []const u8, [:0]const u8 }{
    .{ "font-family", "--font-family=" },
    .{ "font-family-bold", "--font-family-bold=" },
    .{ "font-family-italic", "--font-family-italic=" },
    .{ "font-family-bold-italic", "--font-family-bold-italic=" },
};

/// Whether `Config.load` uses the Ghostty GX layering, i.e. unless
/// `GHOSTTY_GX_DEFAULTS` turns it off.
pub fn enabled(alloc: Allocator) bool {
    const value = global.environ().getAlloc(alloc, disable_env) catch return true;
    defer alloc.free(value);
    return !isOff(value);
}

fn isOff(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    for ([_][]const u8{ "0", "false", "off", "no" }) |off| {
        if (std.ascii.eqlIgnoreCase(trimmed, off)) return true;
    }
    return false;
}

/// Loads the configuration with the Ghostty GX layers and finalizes it.
pub fn load(alloc_gpa: Allocator) !Config {
    return try loadWith(alloc_gpa, SystemSources{});
}

/// Loads the configuration like `load`, with `overrides` (`--key=value`
/// arguments) applied above the command line and below `-e`. Settings UIs
/// use it to preview a setting, such as a theme, without writing it.
pub fn loadWithOverrides(alloc_gpa: Allocator, overrides: []const [:0]const u8) !Config {
    return try loadWith(alloc_gpa, SystemSources{ .overrides = overrides });
}

/// A configuration with only the Ghostty GX defaults applied, not
/// finalized; e.g. the values the settings UI resets to.
pub fn defaultConfig(alloc_gpa: Allocator) !Config {
    var cfg = try Config.default(alloc_gpa);
    errdefer cfg.deinit();
    var reader: std.Io.Reader = .fixed(defaults);
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = defaults_location };
    try cfg.loadIter(alloc_gpa, &iter);
    return cfg;
}

/// The path of the settings overlay `gui-settings.ghostty`: next to the
/// preferred user configuration file (`%LOCALAPPDATA%\ghostty` on
/// Windows, `$XDG_CONFIG_HOME/ghostty` or `~/.config/ghostty` on Linux).
/// The caller owns the returned path.
pub fn overlayPath(alloc: Allocator) ![]u8 {
    const config_path = try file_load.preferredDefaultFilePath(alloc);
    defer alloc.free(config_path);
    const dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    return try std.fs.path.join(alloc, &.{ dir, gui_settings.file_name });
}

/// Where the layers come from when loading for real.
const SystemSources = struct {
    overrides: []const [:0]const u8 = &.{},

    fn defaultsText(_: SystemSources) []const u8 {
        return defaults;
    }

    fn loadUserFiles(_: SystemSources, cfg: *Config, alloc: Allocator) !void {
        try cfg.loadDefaultFiles(alloc);
    }

    fn loadCli(_: SystemSources, cfg: *Config, alloc: Allocator) !void {
        try cfg.loadCliArgs(alloc);
    }

    fn overlay(_: SystemSources, alloc: Allocator) ?[]u8 {
        return overlayPath(alloc) catch |err| {
            log.warn("cannot locate {s}, not loading it err={}", .{ gui_settings.file_name, err });
            return null;
        };
    }

    fn installTheme(_: SystemSources, alloc: Allocator) void {
        var arena: ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const dir = themepkg.Location.user.dir(arena.allocator()) catch null orelse {
            log.warn("no user theme directory for the {s} theme", .{gx_theme.name});
            return;
        };
        const result = gx_theme.install(alloc, global.io(), dir) catch |err| {
            log.warn("cannot install the {s} theme into {s} err={}", .{ gx_theme.name, dir, err });
            return;
        };
        switch (result) {
            .created, .updated => log.info("installed the {s} theme into {s}", .{ gx_theme.name, dir }),
            .unchanged => {},
            .user_file => log.info("keeping the user's {s} theme in {s}", .{ gx_theme.name, dir }),
        }
    }
};

/// Loads the layers from `sources` (see `SystemSources` for the
/// interface), rebuilds the configuration in layer order and finalizes
/// it.
fn loadWith(alloc_gpa: Allocator, sources: anytype) !Config {
    var live = try Config.default(alloc_gpa);
    defer live.deinit();

    try sources.loadUserFiles(&live, alloc_gpa);
    // `config-default-files` only has an effect on the command line.
    live.@"config-default-files" = true;
    const cli_start = live._replay_steps.items.len;
    try sources.loadCli(&live, alloc_gpa);

    // `--config-default-files=false` makes the command-line loader rebuild
    // the configuration from the command-line steps alone.
    const default_files = live.@"config-default-files";
    const cli_begin = if (default_files) cli_start else 0;
    const cli_end = live._replay_steps.items.len;
    const command_start = for (live._replay_steps.items[cli_begin..cli_end], cli_begin..) |step, i| {
        if (step == .@"-e") break i;
    } else cli_end;
    const command_len = cli_end - command_start;

    // Includes are recorded before the `-e` command.
    try live.loadRecursiveFiles(alloc_gpa);
    const includes_end = live._replay_steps.items.len - command_len;

    const overlay_start = live._replay_steps.items.len;
    if (default_files) {
        if (sources.overlay(alloc_gpa)) |path| {
            defer alloc_gpa.free(path);
            _ = live.loadOptionalFile(alloc_gpa, path);
        }
    }
    const overlay_end = live._replay_steps.items.len;

    var scratch: ArenaAllocator = .init(alloc_gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const steps = live._replay_steps.items;

    var ordered: std.ArrayList(Step) = .empty;
    try appendLayer(arena, &ordered, try defaultSteps(arena, sources.defaultsText()));
    var user: std.ArrayList(Step) = .empty;
    if (default_files) try user.appendSlice(arena, steps[0..cli_start]);
    try user.appendSlice(arena, steps[command_start..includes_end]);
    try appendLayer(arena, &ordered, user.items);
    try appendLayer(arena, &ordered, steps[overlay_start..overlay_end]);
    try appendLayer(arena, &ordered, steps[cli_begin..command_start]);
    try appendLayer(arena, &ordered, try argSteps(arena, sources.overrides));
    try ordered.appendSlice(arena, steps[includes_end .. includes_end + command_len]);

    var result = try live.cloneEmpty(alloc_gpa);
    errdefer result.deinit();
    try result.gxReplay(alloc_gpa, ordered.items);
    result.@"_xdg-terminal-exec" = live.@"_xdg-terminal-exec";

    if (result.theme) |theme| {
        if (gx_theme.isBuiltin(theme.light) or gx_theme.isBuiltin(theme.dark)) {
            sources.installTheme(alloc_gpa);
        }
    }

    try result.finalize();
    return result;
}

/// The steps of command-line style arguments. The arguments are not
/// copied; replaying copies them into the new configuration.
fn argSteps(arena: Allocator, args: []const [:0]const u8) Allocator.Error![]const Step {
    const result = try arena.alloc(Step, args.len);
    for (args, result) |arg, *step| step.* = .{ .arg = arg };
    return result;
}

/// The steps `defaults` records, without parsing them.
fn defaultSteps(arena: Allocator, text: []const u8) Allocator.Error![]const Step {
    var reader: std.Io.Reader = .fixed(text);
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = defaults_location };
    var result: std.ArrayList(Step) = .empty;
    while (iter.next()) |arg| try result.append(arena, .{ .arg = try arena.dupeZ(u8, arg) });
    return result.items;
}

/// Appends one layer, resetting each `replaced_keys` key before the
/// layer's first value for it.
fn appendLayer(arena: Allocator, list: *std.ArrayList(Step), layer: []const Step) Allocator.Error!void {
    var reset = [_]bool{false} ** replaced_keys.len;
    for (layer) |step| {
        switch (step) {
            .arg => |arg| if (replacedKey(arg)) |index| {
                if (!reset[index]) {
                    reset[index] = true;
                    try list.append(arena, .{ .arg = replaced_keys[index][1] });
                }
            },
            else => {},
        }
        try list.append(arena, step);
    }
}

/// The `replaced_keys` index of a `--key=value` argument with a
/// non-empty value (an empty value is itself a reset).
fn replacedKey(arg: []const u8) ?usize {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    if (eq + 1 == arg.len) return null;
    for (replaced_keys, 0..) |entry, i| {
        if (std.mem.eql(u8, arg[2..eq], entry[0])) return i;
    }
    return null;
}

/// Layer sources for tests: explicit defaults text, at most one user file
/// (absolute path), command-line arguments, an overlay file and
/// overrides.
const TestSources = struct {
    defaults_text: []const u8,
    user_path: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    overlay_path: ?[]const u8 = null,
    overrides: []const [:0]const u8 = &.{},

    fn defaultsText(self: TestSources) []const u8 {
        return self.defaults_text;
    }

    fn loadUserFiles(self: TestSources, cfg: *Config, alloc: Allocator) !void {
        if (self.user_path) |path| try cfg.loadFile(alloc, path);
    }

    /// Mirrors `Config.loadCliArgs` for `args`, including the rebuild for
    /// `--config-default-files=false`.
    fn loadCli(self: TestSources, cfg: *Config, alloc: Allocator) !void {
        cfg.@"config-default-files" = true;
        const start = cfg._replay_steps.items.len;
        inline for (replaced_keys) |entry| @field(cfg, entry[0]).overwrite_next = true;
        var it = cli.args.sliceIterator(self.args);
        try cfg.loadIter(alloc, &it);
        inline for (replaced_keys) |entry| @field(cfg, entry[0]).overwrite_next = false;
        if (!cfg.@"config-default-files") {
            var fresh = try cfg.cloneEmpty(alloc);
            errdefer fresh.deinit();
            try fresh.gxReplay(alloc, cfg._replay_steps.items[start..]);
            cfg.deinit();
            cfg.* = fresh;
        }
    }

    fn overlay(self: TestSources, alloc: Allocator) ?[]u8 {
        const path = self.overlay_path orelse return null;
        return alloc.dupe(u8, path) catch null;
    }

    fn installTheme(_: TestSources, _: Allocator) void {}
};

/// A temporary directory with helpers to write files and get their
/// absolute paths.
const TestDir = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,

    fn init() !TestDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *TestDir) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Writes `data` to `name` and returns its absolute path, owned by the
    /// caller's arena.
    fn write(self: *TestDir, arena: Allocator, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
        return try std.fs.path.join(arena, &.{ self.root, name });
    }
};

fn expectFamilies(expected: []const []const u8, actual: Config.RepeatableString) !void {
    const testing = std.testing;
    try testing.expectEqual(expected.len, actual.list.items.len);
    for (expected, actual.list.items) |e, a| try testing.expectEqualStrings(e, a);
}

fn expectNoDiagnostics(cfg: *const Config) !void {
    if (cfg._diagnostics.empty()) return;
    for (cfg._diagnostics.items()) |diag| {
        std.debug.print("unexpected diagnostic: {s}: {s}\n", .{ diag.key, diag.message });
    }
    return error.TestUnexpectedResult;
}

test "the embedded defaults parse cleanly" {
    const testing = std.testing;
    const inputpkg = @import("../input.zig");

    var upstream = try Config.default(testing.allocator);
    defer upstream.deinit();
    var cfg = try defaultConfig(testing.allocator);
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);

    try testing.expectEqualStrings("GX Mocha", cfg.theme.?.light);
    try testing.expectEqualStrings("GX Mocha", cfg.theme.?.dark);
    try testing.expectEqualStrings("zh-CN", cfg.language.?);
    try expectFamilies(&.{"JetBrainsMono Nerd Font"}, cfg.@"font-family");
    try testing.expectEqual(@as(f32, 12), cfg.@"font-size");
    try testing.expectEqual(@as(u32, 10), cfg.@"window-padding-x".top_left);
    try testing.expectEqual(@as(u32, 10), cfg.@"window-padding-x".bottom_right);
    try testing.expectEqual(@as(u32, 8), cfg.@"window-padding-y".top_left);
    try testing.expectEqual(@as(u32, 8), cfg.@"window-padding-y".bottom_right);
    try testing.expectEqual(Config.WindowPaddingBalance.true, cfg.@"window-padding-balance");
    try testing.expect(cfg.@"cursor-style" == .block);
    try testing.expectEqual(@as(?bool, true), cfg.@"cursor-style-blink");
    try testing.expectEqual(Config.RightClickAction.@"context-menu", cfg.@"right-click-action");
    try testing.expectEqual(Config.ConfirmCloseSurface.true, cfg.@"confirm-close-surface");
    try testing.expect(cfg.@"gx-herdr-app-mode");
    if (builtin.os.tag == .windows) try testing.expect(cfg.@"quit-after-last-window-closed");

    // Alt+1..Alt+8 belong to the shell; other default bindings remain.
    if (!builtin.os.tag.isDarwin()) {
        for ([_][]const u8{ "alt+1", "alt+digit_1", "alt+8", "alt+digit_8" }) |trigger| {
            const parsed = try inputpkg.Binding.Trigger.parse(trigger);
            try testing.expect(upstream.keybind.set.get(parsed) != null);
            try testing.expect(cfg.keybind.set.get(parsed) == null);
        }
        const last_tab = try inputpkg.Binding.Trigger.parse("alt+9");
        try testing.expect(cfg.keybind.set.get(last_tab) != null);
    }

    // GX actions get performable bindings on keys upstream leaves free.
    for ([_]struct { []const u8, inputpkg.Binding.Action }{
        .{ "ctrl+shift+m", .{ .gx = .main_menu } },
        .{ "ctrl+shift+slash", .{ .gx = .keybinds } },
    }) |binding| {
        const trigger = try inputpkg.Binding.Trigger.parse(binding[0]);
        try testing.expect(upstream.keybind.set.get(trigger) == null);
        const entry = cfg.keybind.set.get(trigger) orelse return error.TestUnexpectedResult;
        try testing.expect(entry.value_ptr.* == .leaf);
        try testing.expect(entry.value_ptr.leaf.action.equal(binding[1]));
        try testing.expect(entry.value_ptr.leaf.flags.performable);
    }

    // The GX command palette entries follow the upstream ones.
    const upstream_entries = upstream.@"command-palette-entry".value.items;
    const entries = cfg.@"command-palette-entry".value.items;
    try testing.expectEqual(upstream_entries.len + 3, entries.len);
    for (upstream_entries, entries[0..upstream_entries.len]) |expected, actual| {
        try testing.expect(expected.equal(actual));
    }
    const gx_entries = entries[upstream_entries.len..];
    try testing.expectEqualStrings("Settings", gx_entries[0].title);
    try testing.expect(gx_entries[0].action.equal(.{ .gx = .settings }));
    try testing.expectEqualStrings("Keyboard Shortcuts", gx_entries[1].title);
    try testing.expect(gx_entries[1].action.equal(.{ .gx = .keybinds }));
    try testing.expectEqualStrings("Main Menu", gx_entries[2].title);
    try testing.expect(gx_entries[2].action.equal(.{ .gx = .main_menu }));
}

test "the embedded defaults set no colors" {
    const testing = std.testing;
    var reader: std.Io.Reader = .fixed(defaults);
    var iter: cli.args.LineIterator = .{ .r = &reader };
    var count: usize = 0;
    while (iter.next()) |arg| {
        count += 1;
        const key = arg[2 .. std.mem.indexOfScalar(u8, arg, '=') orelse arg.len];
        for ([_][]const u8{
            "background",
            "foreground",
            "palette",
            "selection-background",
            "selection-foreground",
            "cursor-text",
            "bold-color",
            "faint-opacity",
            "minimum-contrast",
            "split-divider-color",
            "unfocused-split-fill",
            "window-titlebar-background",
            "window-titlebar-foreground",
        }) |color_key| {
            try testing.expect(!std.mem.eql(u8, key, color_key));
        }
        try testing.expect(!std.mem.endsWith(u8, key, "-color"));
    }
    try testing.expect(count > 0);
}

test "the GX Mocha theme parses cleanly" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var reader: std.Io.Reader = .fixed(gx_theme.content);
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = gx_theme.name };
    try cfg.loadIter(testing.allocator, &iter);
    try expectNoDiagnostics(&cfg);
    try testing.expectEqual(Config.Color{ .r = 0x1f, .g = 0x1f, .b = 0x28 }, cfg.background);
    try testing.expectEqual(Config.Color{ .r = 0xff, .g = 0xff, .b = 0xff }, cfg.foreground);
    try testing.expectEqual(@as(u8, 0x45), cfg.palette.value[0].r);
    try testing.expectEqual(@as(u8, 0xf3), cfg.palette.value[1].r);
}

test "layer precedence: defaults < user < overlay < command line" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const sources: TestSources = .{
        .defaults_text = "font-size = 12\nwindow-padding-x = 10\nlanguage = zh-CN\n" ++
            "cursor-style-blink = true\nfont-family = A\nfont-family = B\n",
        .user_path = try dir.write(arena, "config.ghostty", "font-size = 13\nwindow-padding-x = 11\n" ++
            "language = en\nfont-family = U1\nfont-family = U2\n"),
        .overlay_path = try dir.write(arena, gui_settings.file_name, "font-size = 14\nlanguage = zh-CN\n"),
        .args = &.{"--font-size=15"},
    };

    var cfg = try loadWith(testing.allocator, sources);
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);
    try testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try testing.expectEqualStrings("zh-CN", cfg.language.?);
    try testing.expectEqual(@as(u32, 11), cfg.@"window-padding-x".top_left);
    try testing.expectEqual(@as(?bool, true), cfg.@"cursor-style-blink");
    try expectFamilies(&.{ "U1", "U2" }, cfg.@"font-family");
    try expectFamilies(&.{ "U1", "U2" }, cfg.@"font-family-bold");

    // Without the overlay and the command line the user file wins.
    var user_only = try loadWith(testing.allocator, TestSources{
        .defaults_text = sources.defaults_text,
        .user_path = sources.user_path,
    });
    defer user_only.deinit();
    try testing.expectEqual(@as(f32, 13), user_only.@"font-size");
    try testing.expectEqualStrings("en", user_only.language.?);

    // Without a user file the defaults apply.
    var defaults_only = try loadWith(testing.allocator, TestSources{ .defaults_text = sources.defaults_text });
    defer defaults_only.deinit();
    try testing.expectEqual(@as(f32, 12), defaults_only.@"font-size");
    try expectFamilies(&.{ "A", "B" }, defaults_only.@"font-family");
}

test "font families of a higher layer replace the lower layers" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const defaults_text = "font-family = A\nfont-family = B\nfont-family-bold = BoldA\n";
    const user = try dir.write(arena, "config.ghostty", "font-family = U\nfont-size = 13\n");
    const overlay = try dir.write(arena, "overlay.ghostty", "font-family = O1\nfont-family = O2\n");

    {
        var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text, .user_path = user });
        defer cfg.deinit();
        try expectFamilies(&.{"U"}, cfg.@"font-family");
        try expectFamilies(&.{"BoldA"}, cfg.@"font-family-bold");
    }
    {
        var cfg = try loadWith(testing.allocator, TestSources{
            .defaults_text = defaults_text,
            .user_path = user,
            .overlay_path = overlay,
        });
        defer cfg.deinit();
        try expectFamilies(&.{ "O1", "O2" }, cfg.@"font-family");
    }
    {
        var cfg = try loadWith(testing.allocator, TestSources{
            .defaults_text = defaults_text,
            .user_path = user,
            .overlay_path = overlay,
            .args = &.{ "--font-family=C", "--font-family-bold=" },
        });
        defer cfg.deinit();
        try expectFamilies(&.{"C"}, cfg.@"font-family");
        try expectFamilies(&.{"C"}, cfg.@"font-family-bold");
    }
}

test "includes rank below the overlay and the command line" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    _ = try dir.write(arena, "include.ghostty", "font-size = 16\nlanguage = en\nwindow-padding-x = 30\n");
    const user = try dir.write(arena, "config.ghostty", "config-file = include.ghostty\nfont-size = 13\n");
    const overlay = try dir.write(arena, "overlay.ghostty", "language = zh-CN\n");

    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\n",
        .user_path = user,
        .overlay_path = overlay,
        .args = &.{"--window-padding-x=40"},
    });
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);
    // An include still overrides the file that includes it.
    try testing.expectEqual(@as(f32, 16), cfg.@"font-size");
    try testing.expectEqualStrings("zh-CN", cfg.language.?);
    try testing.expectEqual(@as(u32, 40), cfg.@"window-padding-x".top_left);
}

test "a user theme replaces the default theme and user colors beat themes" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const theme_a = try dir.write(arena, "theme-a", "background = #111111\nforeground = #aaaaaa\n");
    const theme_b = try dir.write(arena, "theme-b", "background = #222222\n");
    const defaults_text = try std.fmt.allocPrint(arena, "theme = {s}\nfont-size = 12\n", .{theme_a});

    {
        var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text });
        defer cfg.deinit();
        try expectNoDiagnostics(&cfg);
        try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, cfg.background);
        try testing.expectEqual(Config.Color{ .r = 0xaa, .g = 0xaa, .b = 0xaa }, cfg.foreground);
        try testing.expectEqual(@as(f32, 12), cfg.@"font-size");
    }
    {
        const user = try dir.write(arena, "colors.ghostty", "background = #333333\n");
        var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text, .user_path = user });
        defer cfg.deinit();
        try testing.expectEqual(Config.Color{ .r = 0x33, .g = 0x33, .b = 0x33 }, cfg.background);
        try testing.expectEqual(Config.Color{ .r = 0xaa, .g = 0xaa, .b = 0xaa }, cfg.foreground);
    }
    {
        const user = try dir.write(arena, "theme.ghostty", try std.fmt.allocPrint(arena, "theme = {s}\n", .{theme_b}));
        var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text, .user_path = user });
        defer cfg.deinit();
        try testing.expectEqualStrings(theme_b, cfg.theme.?.light);
        try testing.expectEqual(Config.Color{ .r = 0x22, .g = 0x22, .b = 0x22 }, cfg.background);
        try testing.expectEqual(Config.Color{ .r = 0xff, .g = 0xff, .b = 0xff }, cfg.foreground);
    }
    {
        const user = try dir.write(arena, "no-theme.ghostty", "theme =\n");
        var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text, .user_path = user });
        defer cfg.deinit();
        try testing.expectEqual(@as(?Config.Theme, null), cfg.theme);
        try testing.expectEqual(Config.Color{ .r = 0x28, .g = 0x2c, .b = 0x34 }, cfg.background);
    }
}

test "conditional theme reloads keep the layer order" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const light = try dir.write(arena, "light", "background = #eeeeee\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    const defaults_text = try std.fmt.allocPrint(
        arena,
        "theme = light:{s},dark:{s}\nfont-family = A\nfont-size = 12\n",
        .{ light, dark },
    );
    const user = try dir.write(arena, "config.ghostty", "font-family = U\nfont-size = 13\n");

    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = defaults_text,
        .user_path = user,
        .args = &.{"--font-size=15"},
    });
    defer cfg.deinit();
    try testing.expect(cfg._conditional_set.contains(.theme));
    try testing.expectEqual(Config.Color{ .r = 0xee, .g = 0xee, .b = 0xee }, cfg.background);

    var dark_cfg = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer dark_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark_cfg.background);
    try testing.expectEqual(@as(f32, 15), dark_cfg.@"font-size");
    try expectFamilies(&.{"U"}, dark_cfg.@"font-family");

    var cloned = try dark_cfg.clone(testing.allocator);
    defer cloned.deinit();
    var light_cfg = (try cloned.changeConditionalState(.{ .theme = .light })).?;
    defer light_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0xee, .g = 0xee, .b = 0xee }, light_cfg.background);
    try testing.expectEqual(@as(f32, 15), light_cfg.@"font-size");
    try expectFamilies(&.{"U"}, light_cfg.@"font-family");
}

test "the -e command stays last" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    _ = try dir.write(arena, "include.ghostty", "window-padding-x = 30\n");
    const user = try dir.write(arena, "config.ghostty", "config-file = include.ghostty\n");
    const overlay = try dir.write(arena, "overlay.ghostty", "language = en\n");

    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\n",
        .user_path = user,
        .overlay_path = overlay,
        .args = &.{ "--font-size=15", "-e", "htop", "--font-size=99" },
    });
    defer cfg.deinit();
    try testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try testing.expectEqualStrings("en", cfg.language.?);
    try testing.expectEqual(@as(u32, 30), cfg.@"window-padding-x".top_left);
    const command = cfg.@"initial-command".?.direct;
    try testing.expectEqual(@as(usize, 2), command.len);
    try testing.expectEqualStrings("htop", command[0]);
    try testing.expectEqualStrings("--font-size=99", command[1]);
    try testing.expect(cfg.@"quit-after-last-window-closed");
}

test "overrides rank above the command line and below -e" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const theme_a = try dir.write(arena, "theme-a", "background = #111111\n");
    const theme_b = try dir.write(arena, "theme-b", "background = #222222\n");
    const overlay = try dir.write(
        arena,
        "overlay.ghostty",
        try std.fmt.allocPrint(arena, "theme = {s}\nfont-size = 14\n", .{theme_a}),
    );

    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\n",
        .overlay_path = overlay,
        .args = &.{ "--font-size=15", "-e", "htop" },
        .overrides = &.{
            try std.fmt.allocPrintSentinel(arena, "--theme={s}", .{theme_b}, 0),
            "--font-size=16",
        },
    });
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);
    try testing.expectEqualStrings(theme_b, cfg.theme.?.light);
    try testing.expectEqual(Config.Color{ .r = 0x22, .g = 0x22, .b = 0x22 }, cfg.background);
    try testing.expectEqual(@as(f32, 16), cfg.@"font-size");
    const command = cfg.@"initial-command".?.direct;
    try testing.expectEqual(@as(usize, 1), command.len);
    try testing.expectEqualStrings("htop", command[0]);

    var plain = try loadWith(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\n",
        .overlay_path = overlay,
    });
    defer plain.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, plain.background);
    try testing.expectEqual(@as(f32, 14), plain.@"font-size");
}

test "config-default-files=false skips user files and the overlay, not the defaults" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const user = try dir.write(arena, "config.ghostty", "font-size = 13\nconfig-default-files = true\n");
    const overlay = try dir.write(arena, "overlay.ghostty", "language = en\n");
    const include = try dir.write(arena, "include.ghostty", "window-padding-x = 30\n");

    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\nlanguage = zh-CN\n",
        .user_path = user,
        .overlay_path = overlay,
        .args = &.{ "--config-default-files=false", try std.fmt.allocPrint(arena, "--config-file={s}", .{include}) },
    });
    defer cfg.deinit();
    try testing.expect(!cfg.@"config-default-files");
    try testing.expectEqual(@as(f32, 12), cfg.@"font-size");
    try testing.expectEqualStrings("zh-CN", cfg.language.?);
    try testing.expectEqual(@as(u32, 30), cfg.@"window-padding-x".top_left);
}

test "config-file errors survive the rebuild and later replays" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const theme = try dir.write(arena, "theme", "background = #111111\n");
    const user = try dir.write(arena, "config.ghostty", "config-file = missing.ghostty\n");
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = try std.fmt.allocPrint(arena, "theme = {s}\n", .{theme}),
        .user_path = user,
    });
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
    try testing.expect(std.mem.indexOf(u8, cfg._diagnostics.items()[0].message, "missing.ghostty") != null);

    // A second finalize reloads the theme by replaying the steps again,
    // like `ghostty +validate-config` does.
    var reloaded = try cfg.clone(testing.allocator);
    defer reloaded.deinit();
    try reloaded.finalize();
    try testing.expectEqual(@as(usize, 1), reloaded._diagnostics.items().len);
    try reloaded.finalize();
    try testing.expectEqual(@as(usize, 1), reloaded._diagnostics.items().len);
}

test "upstream loading also keeps config-file errors across theme reloads" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const theme = try dir.write(arena, "theme", "background = #111111\n");
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var it = cli.args.sliceIterator(&.{
        try std.fmt.allocPrint(arena, "--theme={s}", .{theme}),
        try std.fmt.allocPrint(arena, "--config-file={s}", .{try std.fs.path.join(arena, &.{ dir.root, "missing" })}),
    });
    try cfg.loadIter(testing.allocator, &it);
    try cfg.loadRecursiveFiles(testing.allocator);
    try cfg.finalize();
    try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
    try cfg.finalize();
    try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
}

test "GHOSTTY_GX_DEFAULTS values that turn the layering off" {
    const testing = std.testing;
    for ([_][]const u8{ "0", "false", "OFF", " no " }) |value| try testing.expect(isOff(value));
    for ([_][]const u8{ "", "1", "true", "yes" }) |value| try testing.expect(!isOff(value));
}

test "overlayPath is next to the preferred configuration file" {
    const testing = std.testing;
    const path = try overlayPath(testing.allocator);
    defer testing.allocator.free(path);
    const config_path = try file_load.preferredDefaultFilePath(testing.allocator);
    defer testing.allocator.free(config_path);
    try testing.expectEqualStrings(gui_settings.file_name, std.fs.path.basename(path));
    try testing.expectEqualStrings(std.fs.path.dirname(config_path).?, std.fs.path.dirname(path).?);
}
