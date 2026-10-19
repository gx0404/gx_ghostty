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
//! way command-line font families replace configured ones upstream. Ordinary
//! `font-family` input above the defaults also suppresses only the defaults'
//! CJK maps before replay; the original steps remain available for GUI resets.
//! Style-specific font input does not suppress those maps. An explicitly
//! disabled system cursor blink appends a default-layer input, below every
//! user layer; app runtimes sample it with `setSystemCursorBlink`.
//!
//! `Layers` keeps the recorded steps of every layer: it reads the files
//! once and then builds configurations in memory (`Layers.build`), e.g. for
//! every step of a theme preview, and tells which layer a key comes from
//! (`Layers.provenance`). `rebuild` builds a loaded configuration again
//! from the steps it recorded, without reading any file.
//!
//! Problems loading cannot report through a parser are recorded as
//! `.diagnostic` steps, so every later replay reports them again: an
//! overlay file that cannot be read, and a `language` value Ghostty GX
//! does not support. `diagnosticsDigest` tells app runtimes whether the
//! diagnostics changed. The built-in theme is installed into the user's
//! theme directory once per process.
//!
//! A window material (`gx-window-material`) that shows behind the
//! terminals comes with a `background-opacity` in the defaults layer
//! (`materialOpacity`) unless a layer sets `background-opacity`; only the
//! app runtime knows whether the material can show there and says so with
//! `setMaterialOpacity` before loading.
//!
//! The command palette entries of the defaults have `gx:` actions and
//! English msgids as titles and descriptions. The win32 palette translates
//! entries when it shows them; the GTK palette shows them as configured,
//! so on GTK loading translates them into the configured `language`
//! (`translatePalette`). The translated entries are recorded as the
//! defaults' configuration input, so theme and conditional replays keep
//! them, and loading again after `language` changes translates them anew.
//!
//! Setting the environment variable `GHOSTTY_GX_DEFAULTS=0` (or `false`,
//! `off`, `no`) loads the configuration exactly like upstream Ghostty: no
//! defaults, no overlay, upstream order.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const build_config = @import("../build_config.zig");
const Config = @import("../config/Config.zig");
const conditional = @import("../config/conditional.zig");
const file_load = @import("../config/file_load.zig");
const themepkg = @import("../config/theme.zig");
const cli = @import("../cli.zig");
const global = @import("../global.zig");
const inputpkg = @import("../input.zig");
const config_types = @import("config_types.zig");
const gui_settings = @import("gui_settings.zig");
const i18n = @import("i18n.zig");
const perf = @import("perf.zig");
const gx_theme = @import("theme.zig");
const cursor_policy = @import("cursor_policy.zig");

const log = std.log.scoped(.gx_config);

/// Whether a window material shows behind the terminals
/// (`setMaterialOpacity`).
var material_opacity: std.atomic.Value(bool) = .init(false);

const CursorBlink = enum(u8) { unknown, enabled, disabled };
var system_cursor_blink: std.atomic.Value(CursorBlink) = .init(.unknown);

pub fn setSystemCursorBlink(value: ?bool) void {
    system_cursor_blink.store(if (value) |blink| if (blink) .enabled else .disabled else .unknown, .monotonic);
}

pub fn systemCursorBlink() ?bool {
    return switch (system_cursor_blink.load(.monotonic)) {
        .unknown => null,
        .enabled => true,
        .disabled => false,
    };
}

/// Tells loading whether a window material (`gx-window-material`) shows
/// behind the terminals, which the Windows version and the OpenGL driver
/// decide: then the defaults give the material a `background-opacity`
/// (`materialOpacity`). The win32 app runtime sets it once before it loads
/// the configuration; it is off everywhere else.
pub fn setMaterialOpacity(shows: bool) void {
    material_opacity.store(shows, .monotonic);
}

/// The `background-opacity` argument the defaults add for a window
/// material that shows behind the terminals when no layer sets
/// `background-opacity`, as in WezTerm GX: the opaque, wallpaper-tinted
/// Mica and Mica Alt (`tabbed`) at 0.3, the see-through Acrylic at 0.75.
pub fn materialOpacity(material: config_types.WindowMaterial) ?[:0]const u8 {
    return switch (material) {
        .solid => null,
        .mica, .tabbed => "--background-opacity=0.3",
        .acrylic => "--background-opacity=0.75",
    };
}

/// Applies `arg` (`--key=value`) to a loaded configuration above every
/// layer and below `-e`, and finalizes it again. The argument is recorded
/// like any other input, so theme and conditional reloads keep it.
pub fn applyArg(config: *Config, alloc_gpa: Allocator, arg: [:0]const u8) !void {
    const result = try rebuild(config, alloc_gpa, &.{arg});
    config.deinit();
    config.* = result;
}

/// Builds `config` again from the inputs it recorded, with `args`
/// (`--key=value`) above every layer and below `-e`, without reading any
/// file but the theme. `Config.default` runs again, so the GTK app runtime
/// rebuilds to translate the default command palette entries after the
/// messages language changed. The conditional state of `config` is kept.
pub fn rebuild(config: *const Config, alloc_gpa: Allocator, args: []const [:0]const u8) !Config {
    const steps = config._replay_steps.items;
    const command_start = for (steps, 0..) |step, i| {
        if (step == .@"-e") break i;
    } else steps.len;

    // The conditional steps are the theme's, which finalizing loads
    // again; replaying the matching ones would record them unconditional.
    var scratch: ArenaAllocator = .init(alloc_gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var ordered: std.ArrayList(Step) = .empty;
    for (steps[0..command_start]) |step| {
        if (step != .conditional_arg) try ordered.append(arena, step);
    }
    try ordered.appendSlice(arena, try argSteps(arena, args));
    try ordered.appendSlice(arena, steps[command_start..]);

    var result = try config.cloneEmpty(alloc_gpa);
    errdefer result.deinit();
    try result.gxReplay(alloc_gpa, ordered.items);
    result.@"_xdg-terminal-exec" = config.@"_xdg-terminal-exec";
    try result.finalize();
    return result;
}

/// A digest of the diagnostics of `config`: 0 without any, otherwise the
/// same nonzero value for the same diagnostics in the same order. App
/// runtimes compare it to report configuration problems once per change,
/// not again for every reload that keeps them (such as each step of a
/// theme preview).
pub fn diagnosticsDigest(config: *const Config) u64 {
    const items = config._diagnostics.items();
    if (items.len == 0) return 0;
    var hasher: std.hash.Wyhash = .init(0);
    for (items) |diag| {
        hasher.update(@tagName(diag.location));
        switch (diag.location) {
            .none => {},
            .cli => |index| hasher.update(std.mem.asBytes(&index)),
            .file => |file| {
                hasher.update(file.path);
                hasher.update(std.mem.asBytes(&file.line));
            },
        }
        hasher.update(&.{0});
        hasher.update(diag.key);
        hasher.update(&.{0});
        hasher.update(diag.message);
        hasher.update(&.{0});
    }
    return @max(hasher.final(), 1);
}

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

/// Only successfully parsed explicit cursor inputs acquire an override.
/// Defaults retain a distinct replay tag; themes retain their conditional tag.
/// Equal values still count, and arguments after -e belong to the child.
pub fn cursorOverrides(config: *const Config) cursor_policy.Overrides {
    var result: cursor_policy.Overrides = .{};
    // Reuse the parser and reset defaults without loading files or allocating.
    const Values = struct {
        @"cursor-style": @FieldType(Config, "cursor-style") = .block,
        @"cursor-style-blink": @FieldType(Config, "cursor-style-blink") = null,
    };
    var values: Values = .{};
    var buffer: [0]u8 = .{};
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    for (config._replay_steps.items) |step| {
        const source: struct { []const u8, bool } = switch (step) {
            .arg => |arg| .{ @as([]const u8, arg), true },
            .gx_default_cursor_arg => |arg| .{ @as([]const u8, arg), false },
            .conditional_arg => |v| conditional: {
                for (v.conditions) |cond| {
                    if (!config._conditional_state.match(cond)) break :conditional .{ @as([]const u8, ""), false };
                }
                break :conditional .{ v.arg, false };
            },
            .@"-e" => break,
            else => continue,
        };
        const arg, const explicit = source;
        const key = argKey(arg) orelse continue;
        if (!isCursorKey(key)) continue;
        const value = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[eq + 1 ..] else null;
        cli.args.parseIntoField(Values, scratch.allocator(), &values, key, value) catch continue;
        if (std.mem.eql(u8, key, "cursor-style")) {
            result.style = if (explicit) values.@"cursor-style" else null;
        } else result.blink = if (explicit) values.@"cursor-style-blink" else null;
    }
    return result;
}

/// Cursor keys whose source must survive theme/conditional configuration replay.
pub fn isCursorKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "cursor-style") or std.mem.eql(u8, key, "cursor-style-blink");
}

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
    if (!enabled(alloc_gpa)) return error.LayeringDisabled;
    const span: perf.Span = .begin(global.io());
    defer _ = span.end(global.io(), "config_load");
    return try loadWith(alloc_gpa, SystemSources{});
}

/// Loads the configuration like `load`, with `overrides` (`--key=value`
/// arguments) applied above the command line and below `-e`. Settings UIs
/// use it to preview a setting, such as a theme, without writing it; to
/// preview repeatedly, read the files once with `Layers.load` instead.
/// Returns `error.LayeringDisabled` without the Ghostty GX layers.
pub fn loadWithOverrides(alloc_gpa: Allocator, overrides: []const [:0]const u8) !Config {
    if (!enabled(alloc_gpa)) return error.LayeringDisabled;
    return try loadWith(alloc_gpa, SystemSources{ .overrides = overrides });
}

/// A configuration with only the Ghostty GX defaults applied, not
/// finalized; upstream defaults when layering is disabled.
pub fn defaultConfig(alloc_gpa: Allocator) !Config {
    var cfg = try Config.default(alloc_gpa);
    errdefer cfg.deinit();
    if (!enabled(alloc_gpa)) return cfg;
    const arena = cfg._arena.?.allocator();
    try cfg.gxReplay(alloc_gpa, try effectiveDefaults(arena, try defaultSteps(arena, defaults), false, systemCursorBlink()));
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

/// A layer of the configuration, lowest first.
pub const Layer = enum {
    /// The Ghostty GX defaults.
    defaults,

    /// The user configuration files and every file they or the command
    /// line include.
    user,

    /// The settings overlay `gui-settings.ghostty`.
    overlay,

    /// The command line, without `-e` and its command.
    cli,
};

/// The configuration inputs of every layer, read from disk once and then
/// built into configurations in memory as often as needed: a settings UI
/// keeps one while it is open and builds every theme preview from it
/// instead of loading everything again. Building gives the same
/// configuration as loading (`build` with the same overrides as
/// `loadWithOverrides`), as long as the files did not change.
pub const Layers = struct {
    /// Owns the steps and the paths.
    arena: ArenaAllocator,

    /// The recorded inputs of each layer, in the order they were read.
    steps: std.EnumArray(Layer, std.ArrayList(Step)) = .initFill(.empty),

    /// `-e` and the command after it, last in every build.
    command: []const Step = &.{},

    /// The directory of the overlay file, against which `setOverlay`
    /// expands relative paths; null when there is no overlay.
    overlay_dir: ?[]const u8 = null,

    /// Whether builds translate the palette entries of the defaults
    /// (`translatePalette`), add the `background-opacity` of a window
    /// material (`materialOpacityStep`) and install the built-in theme.
    translate_palette: bool = false,
    material_opacity: bool = false,
    install_theme: bool = false,

    xdg_terminal_exec: bool = false,
    system_cursor_blink: ?bool = null,

    pub fn setSystemCursorBlink(self: *Layers, value: ?bool) bool {
        const changed = (self.system_cursor_blink == false) != (value == false);
        self.system_cursor_blink = value;
        return changed;
    }

    /// Reads every layer from disk. Fails with `error.LayeringDisabled`
    /// when `GHOSTTY_GX_DEFAULTS` turns the layering off (`enabled`).
    pub fn load(alloc_gpa: Allocator) !Layers {
        if (!enabled(alloc_gpa)) return error.LayeringDisabled;
        return try read(alloc_gpa, SystemSources{});
    }

    pub fn deinit(self: *Layers) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A finalized configuration of all layers, with `overrides`
    /// (`--key=value`) above the command line and below `-e`. Reads no
    /// file but the theme.
    pub fn build(self: *const Layers, alloc_gpa: Allocator, overrides: []const [:0]const u8) !Config {
        const span: perf.Span = .begin(global.io());
        defer _ = span.end(global.io(), "config_build");

        var scratch: ArenaAllocator = .init(alloc_gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const preview_steps = try argSteps(arena, overrides);
        var ordered: std.ArrayList(Step) = .empty;
        try appendLayer(arena, &ordered, try effectiveDefaults(
            arena,
            self.steps.get(.defaults).items,
            self.userFont(preview_steps),
            self.system_cursor_blink,
        ));
        const defaults_end = ordered.items.len;
        try appendLayer(arena, &ordered, self.steps.get(.user).items);
        try appendLayer(arena, &ordered, self.steps.get(.overlay).items);
        try appendLayer(arena, &ordered, self.steps.get(.cli).items);
        try appendLayer(arena, &ordered, preview_steps);
        if (try languageDiagnostic(arena, ordered.items)) |step| try ordered.append(arena, step);
        try ordered.appendSlice(arena, self.command);

        if (self.translate_palette) {
            try translatePalette(arena, ordered.items[0..defaults_end], configuredLanguage(ordered.items));
        }
        if (self.material_opacity) {
            if (materialOpacityStep(ordered.items)) |step| try ordered.insert(arena, defaults_end, step);
        }

        var result = try Config.default(alloc_gpa);
        errdefer result.deinit();
        try result.gxReplay(alloc_gpa, ordered.items);
        result.@"_xdg-terminal-exec" = self.xdg_terminal_exec;

        if (self.install_theme) {
            if (result.theme) |theme| {
                if (gx_theme.isBuiltin(theme.light) or gx_theme.isBuiltin(theme.dark)) installThemeOnce(alloc_gpa);
            }
        }

        try result.finalize();
        return result;
    }

    /// The highest layer that sets `key` (a configuration key without
    /// `--`), which is where its value comes from; null when no layer sets
    /// it, so it is Ghostty's default or comes from the theme. A
    /// `background-opacity` the defaults add for a window material counts
    /// as set by the defaults.
    pub fn provenance(self: *const Layers, key: []const u8) ?Layer {
        var result: ?Layer = null;
        for (std.enums.values(Layer)) |layer| {
            if (self.sets(layer, key)) result = layer;
        }
        if (result == null and self.material_opacity and std.mem.eql(u8, key, "background-opacity")) {
            var material: config_types.WindowMaterial = .solid;
            for (std.enums.values(Layer)) |layer| material = lastMaterial(material, self.steps.get(layer).items);
            if (materialOpacity(material) != null) return .defaults;
        }
        return result;
    }

    /// Whether `layer` sets `key` (a configuration key without `--`).
    pub fn sets(self: *const Layers, layer: Layer, key: []const u8) bool {
        if (layer == .defaults) {
            if (std.mem.eql(u8, key, "font-codepoint-map") and self.userFont(&.{})) return false;
            if (std.mem.eql(u8, key, "cursor-style-blink") and self.system_cursor_blink == false) return true;
        }
        return stepsSet(self.steps.get(layer).items, key);
    }

    fn userFont(self: *const Layers, overrides: []const Step) bool {
        for ([_]Layer{ .user, .overlay, .cli }) |layer| {
            if (stepsSet(self.steps.get(layer).items, "font-family")) return true;
        }
        return stepsSet(overrides, "font-family");
    }

    /// Sets `key` to `values` in the overlay layer, one value per line like
    /// `gui_settings.Overlay.setAll` writes the file (an empty `values`
    /// removes the key), so later builds follow what a settings UI saved
    /// without reading the file again.
    pub fn setOverlay(self: *Layers, key: []const u8, values: []const []const u8) Allocator.Error!void {
        const arena = self.arena.allocator();
        const list = self.steps.getPtr(.overlay);

        var position: ?usize = null;
        var i: usize = 0;
        while (i < list.items.len) {
            const matches = switch (list.items[i]) {
                .arg => |arg| if (argKey(arg)) |name| std.mem.eql(u8, name, key) else false,
                else => false,
            };
            if (!matches) {
                i += 1;
                continue;
            }
            if (position == null) position = i;
            _ = list.orderedRemove(i);
        }

        // New lines go where the key was, else before the expansion of
        // relative paths that ends the steps of the file.
        const expand: ?usize = for (list.items, 0..) |step, index| {
            if (step == .expand) break index;
        } else null;
        const at = position orelse expand orelse list.items.len;
        for (values, 0..) |value, n| {
            const arg = try std.fmt.allocPrintSentinel(arena, "--{s}={s}", .{ key, value }, 0);
            try list.insert(arena, at + n, .{ .arg = arg });
        }
        if (values.len > 0 and expand == null) {
            if (self.overlay_dir) |dir| try list.append(arena, .{ .expand = dir });
        }
    }

    /// Reads the layers from `sources` (see `SystemSources` for the
    /// interface).
    fn read(alloc_gpa: Allocator, sources: anytype) !Layers {
        var live = try Config.default(alloc_gpa);
        defer live.deinit();

        try sources.loadUserFiles(&live, alloc_gpa);
        // `config-default-files` only has an effect on the command line.
        live.@"config-default-files" = true;
        const cli_start = live._replay_steps.items.len;
        try sources.loadCli(&live, alloc_gpa);

        // `--config-default-files=false` makes the command-line loader
        // rebuild the configuration from the command-line steps alone.
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

        var self: Layers = .{
            .arena = .init(alloc_gpa),
            .translate_palette = sources.translatesPalette(),
            .material_opacity = sources.materialOpacity(),
            .system_cursor_blink = sources.cursorBlink(),
            .install_theme = sources.installsTheme(),
            .xdg_terminal_exec = live.@"_xdg-terminal-exec",
        };
        errdefer self.deinit();
        const arena = self.arena.allocator();

        const overlay_start = live._replay_steps.items.len;
        var overlay_error: ?cli.Diagnostic = null;
        if (default_files) {
            if (sources.overlay(alloc_gpa)) |path| {
                defer alloc_gpa.free(path);
                if (std.fs.path.dirname(path)) |dir| self.overlay_dir = try arena.dupe(u8, dir);
                overlay_error = try loadOverlay(&live, alloc_gpa, arena, path);
            }
        }
        const overlay_end = live._replay_steps.items.len;
        const steps = live._replay_steps.items;

        try self.steps.getPtr(.defaults).appendSlice(arena, try defaultSteps(arena, sources.defaultsText()));
        if (default_files) try self.appendCopies(.user, steps[0..cli_start]);
        try self.appendCopies(.user, steps[command_start..includes_end]);
        try self.appendCopies(.overlay, steps[overlay_start..overlay_end]);
        if (overlay_error) |diag| try self.steps.getPtr(.overlay).append(arena, .{ .diagnostic = diag });
        try self.appendCopies(.cli, steps[cli_begin..command_start]);

        var command: std.ArrayList(Step) = .empty;
        for (steps[includes_end .. includes_end + command_len]) |step| {
            try command.append(arena, try cloneStep(arena, step));
        }
        self.command = command.items;
        return self;
    }

    fn appendCopies(self: *Layers, layer: Layer, steps: []const Step) Allocator.Error!void {
        const arena = self.arena.allocator();
        const list = self.steps.getPtr(layer);
        for (steps) |step| try list.append(arena, try cloneStep(arena, step));
    }
};

/// Loads the overlay file at `path` into `live`. A missing or empty file
/// is no overlay; a file that cannot be read gives a diagnostic (allocated
/// with `arena`), so settings that silently do not apply show up.
fn loadOverlay(live: *Config, alloc_gpa: Allocator, arena: Allocator, path: []const u8) Allocator.Error!?cli.Diagnostic {
    const failure: anyerror = failure: {
        if (!std.fs.path.isAbsolute(path)) break :failure error.InvalidPath;
        // `Config.loadFile` only logs a path that is not a file.
        const file = file_load.open(global.io(), path) catch |err| switch (err) {
            error.FileNotFound, error.FileIsEmpty => return null,
            else => break :failure err,
        };
        file.close(global.io());
        live.loadFile(alloc_gpa, path) catch |err| switch (err) {
            error.FileNotFound, error.FileIsEmpty => return null,
            error.OutOfMemory => return error.OutOfMemory,
            else => break :failure err,
        };
        return null;
    };
    log.warn("cannot read {s} err={}", .{ path, failure });
    return .{ .message = try std.fmt.allocPrintSentinel(arena, "error reading {s}: {}", .{ path, failure }, 0) };
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

    /// Whether loading translates the palette entries of the defaults:
    /// only the GTK command palette shows entry texts as configured.
    fn translatesPalette(_: SystemSources) bool {
        return comptime build_config.app_runtime == .gtk;
    }

    fn materialOpacity(_: SystemSources) bool {
        return material_opacity.load(.monotonic);
    }

    fn cursorBlink(_: SystemSources) ?bool {
        return systemCursorBlink();
    }

    fn installsTheme(_: SystemSources) bool {
        return true;
    }
};

/// Whether the built-in theme was installed (or tried to be) in this
/// process.
var theme_installed: std.atomic.Value(bool) = .init(false);

/// Installs the built-in theme into the user's theme directory, once per
/// process: later loads find it there.
fn installThemeOnce(alloc: Allocator) void {
    if (theme_installed.swap(true, .acq_rel)) return;
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

/// Loads the layers from `sources` (see `SystemSources` for the
/// interface), rebuilds the configuration in layer order and finalizes
/// it.
fn loadWith(alloc_gpa: Allocator, sources: anytype) !Config {
    var layers = try Layers.read(alloc_gpa, sources);
    defer layers.deinit();
    return try layers.build(alloc_gpa, sources.overrides);
}

/// A copy of `step` allocated with `arena`.
fn cloneStep(arena: Allocator, step: Step) Allocator.Error!Step {
    return switch (step) {
        .arg => |arg| .{ .arg = try arena.dupeZ(u8, arg) },
        .gx_default_cursor_arg => |arg| .{ .gx_default_cursor_arg = try arena.dupeZ(u8, arg) },
        .expand => |base| .{ .expand = try arena.dupe(u8, base) },
        .conditional_arg => |value| .{ .conditional_arg = .{
            .conditions = conditions: {
                const copies = try arena.alloc(conditional.Conditional, value.conditions.len);
                for (value.conditions, copies) |cond, *copy| copy.* = try cond.clone(arena);
                break :conditions copies;
            },
            .arg = try arena.dupe(u8, value.arg),
        } },
        .diagnostic => |diag| .{ .diagnostic = try diag.clone(arena) },
        .@"-e" => .@"-e",
    };
}

/// The key of a `--key=value` (or `--key`) argument.
fn argKey(arg: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const rest = arg[2..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '=') orelse rest.len];
}

/// A diagnostic step for a `language` that Ghostty GX does not support,
/// which then shows in `zh-CN` (`i18n.resolve`); null when the last
/// `language` before `-e` is supported or not set.
fn languageDiagnostic(arena: Allocator, steps: []const Step) Allocator.Error!?Step {
    const prefix = "--language=";
    var value: ?[]const u8 = null;
    for (steps) |step| switch (step) {
        .arg => |arg| if (std.mem.startsWith(u8, arg, prefix)) {
            value = if (arg.len > prefix.len) arg[prefix.len..] else null;
        },
        .@"-e" => break,
        else => {},
    };
    const language = value orelse return null;
    if (i18n.parseLanguage(language) != null) return null;
    return .{ .diagnostic = .{
        .key = "language",
        .message = try std.fmt.allocPrintSentinel(
            arena,
            "unsupported value \"{s}\", using {s}",
            .{ language, i18n.Language.default.configValue() },
            0,
        ),
    } };
}

// The steps of command-line style arguments. The arguments are not
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

fn stepsSet(steps: []const Step, key: []const u8) bool {
    for (steps) |step| switch (step) {
        .arg => |arg| if (argKey(arg)) |name| {
            if (std.mem.eql(u8, name, key)) return true;
        },
        .@"-e" => break,
        else => {},
    };
    return false;
}

fn effectiveDefaults(arena: Allocator, raw: []const Step, user_font: bool, blink: ?bool) Allocator.Error![]const Step {
    var result: std.ArrayList(Step) = .empty;
    for (raw) |step| {
        if (user_font and step == .arg and stepsSet(&.{step}, "font-codepoint-map")) continue;
        const tagged: Step = if (step == .arg and isCursorKey(argKey(step.arg) orelse ""))
            .{ .gx_default_cursor_arg = step.arg }
        else
            step;
        try result.append(arena, tagged);
    }
    if (blink == false) try result.append(arena, .{ .gx_default_cursor_arg = "--cursor-style-blink=false" });
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

/// The defaults' `background-opacity` step for the window material that
/// layered `steps` configure (`materialOpacity`), or null without a
/// material or when a layer sets `background-opacity` itself.
fn materialOpacityStep(steps: []const Step) ?Step {
    for (steps) |step| switch (step) {
        .arg => |arg| if (std.mem.startsWith(u8, arg, "--background-opacity=")) return null,
        .@"-e" => break,
        else => {},
    };
    return .{ .arg = materialOpacity(lastMaterial(.solid, steps)) orelse return null };
}

/// The window material after `steps`, starting from `material`: the last
/// `gx-window-material` value before `-e`; an empty value resets it to
/// `solid` and an invalid one leaves it unchanged.
fn lastMaterial(material: config_types.WindowMaterial, steps: []const Step) config_types.WindowMaterial {
    const prefix = "--gx-window-material=";
    var result = material;
    for (steps) |step| switch (step) {
        .arg => |arg| if (std.mem.startsWith(u8, arg, prefix)) {
            const value = arg[prefix.len..];
            result = if (value.len == 0)
                .solid
            else
                std.meta.stringToEnum(config_types.WindowMaterial, value) orelse result;
        },
        .@"-e" => break,
        else => {},
    };
    return result;
}

/// The UI language that layered `steps` configure: the last `language`
/// value before `-e`, resolved like the app runtimes resolve it.
fn configuredLanguage(steps: []const Step) i18n.Language {
    const prefix = "--language=";
    var value: ?[]const u8 = null;
    for (steps) |step| switch (step) {
        .arg => |arg| if (std.mem.startsWith(u8, arg, prefix)) {
            value = if (arg.len > prefix.len) arg[prefix.len..] else null;
        },
        .@"-e" => break,
        else => {},
    };
    return i18n.resolve(value);
}

/// Translates the `command-palette-entry` steps of the defaults layer into
/// `lang` (see `translatePaletteEntry`). The steps stay configuration
/// input, so every later replay of them keeps the translation.
fn translatePalette(arena: Allocator, defaults_layer: []Step, lang: i18n.Language) Allocator.Error!void {
    for (defaults_layer) |*step| switch (step.*) {
        .arg => |arg| if (try translatePaletteEntry(arena, arg, lang)) |translated| {
            step.* = .{ .arg = translated };
        },
        else => {},
    };
}

/// `arg` with its title and description replaced by their `lang`
/// translations, if `arg` is a `command-palette-entry` with a `gx:` action
/// and `lang` translates at least one of its texts; null otherwise. The
/// result uses the syntax `+show-config` writes.
fn translatePaletteEntry(arena: Allocator, arg: []const u8, lang: i18n.Language) Allocator.Error!?[:0]const u8 {
    const prefix = "--command-palette-entry=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    const command = cli.args.parseAutoStruct(inputpkg.Command, arena, arg[prefix.len..], null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (command.action != .gx) return null;
    const title = i18n.lookup(lang, command.title);
    const description = i18n.lookup(lang, command.description);
    if (title == null and description == null) return null;

    const action = try std.fmt.allocPrint(arena, "{f}", .{command.action});
    return try std.fmt.allocPrintSentinel(arena, "{s}title:\"{f}\",description:\"{f}\",action:\"{f}\"", .{
        prefix,
        std.zig.fmtString(title orelse command.title),
        std.zig.fmtString(description orelse command.description),
        std.zig.fmtString(action),
    }, 0);
}

/// Layer sources for tests: explicit defaults text, at most one user file
/// (absolute path), command-line arguments, an overlay file, overrides,
/// whether the palette entries of the defaults are translated (as on
/// GTK) and whether a window material shows behind the terminals.
const TestSources = struct {
    defaults_text: []const u8,
    user_path: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    overlay_path: ?[]const u8 = null,
    overrides: []const [:0]const u8 = &.{},
    translate_palette: bool = false,
    material_opacity: bool = false,
    system_cursor_blink: ?bool = null,

    fn defaultsText(self: TestSources) []const u8 {
        return self.defaults_text;
    }

    fn translatesPalette(self: TestSources) bool {
        return self.translate_palette;
    }

    fn materialOpacity(self: TestSources) bool {
        return self.material_opacity;
    }

    fn cursorBlink(self: TestSources) ?bool {
        return self.system_cursor_blink;
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

    fn installsTheme(_: TestSources) bool {
        return false;
    }
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

    var upstream = try Config.default(testing.allocator);
    defer upstream.deinit();
    var cfg = try defaultConfig(testing.allocator);
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);

    try testing.expectEqualStrings("GX Mocha", cfg.theme.?.light);
    try testing.expectEqualStrings("GX Mocha", cfg.theme.?.dark);
    try testing.expectEqualStrings("zh-CN", cfg.language.?);
    try expectFamilies(if (builtin.os.tag == .windows) &.{"JetBrainsMono Nerd Font"} else &.{}, cfg.@"font-family");
    for ([_]u21{ 0x3200, 0x33ff, 0xfe10, 0xfe1f }) |codepoint| {
        try testing.expect(cfg.@"font-codepoint-map".map.get(codepoint) != null);
    }
    try testing.expectEqual(@as(f32, 12), cfg.@"font-size");
    try testing.expectEqual(@as(u32, 10), cfg.@"window-padding-x".top_left);
    try testing.expectEqual(@as(u32, 10), cfg.@"window-padding-x".bottom_right);
    try testing.expectEqual(@as(u32, 8), cfg.@"window-padding-y".top_left);
    try testing.expectEqual(@as(u32, 8), cfg.@"window-padding-y".bottom_right);
    try testing.expectEqual(Config.WindowPaddingBalance.true, cfg.@"window-padding-balance");
    try testing.expect(cfg.@"cursor-style" == .block);
    try testing.expectEqual(@as(?bool, true), cfg.@"cursor-style-blink");
    try testing.expect(cfg.@"mouse-hide-while-typing");
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

    // Windows has no selection clipboard: Shift+Insert pastes the clipboard.
    if (builtin.os.tag == .windows) {
        const shift_insert = try inputpkg.Binding.Trigger.parse("shift+insert");
        const entry = cfg.keybind.set.get(shift_insert) orelse return error.TestUnexpectedResult;
        try testing.expect(entry.value_ptr.* == .leaf);
        try testing.expect(entry.value_ptr.leaf.action.equal(.paste_from_clipboard));
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

test "GX0057 cursor origins survive layers equal values and copies" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const raw = "cursor-style = block\ncursor-style-blink = true\n";
    const user = try dir.write(arena, "cursor.ghostty", raw);
    const include = try dir.write(arena, "include.ghostty", "config-file = cursor.ghostty\n");
    const include_arg = try std.fmt.allocPrintSentinel(arena, "--config-file={s}", .{user}, 0);
    const cases = [_]struct { sources: TestSources, explicit: bool }{
        .{ .sources = .{ .defaults_text = raw }, .explicit = false },
        .{ .sources = .{ .defaults_text = raw, .system_cursor_blink = false }, .explicit = false },
        .{ .sources = .{ .defaults_text = raw, .user_path = user }, .explicit = true },
        .{ .sources = .{ .defaults_text = raw, .user_path = include }, .explicit = true },
        .{ .sources = .{ .defaults_text = raw, .args = &.{include_arg} }, .explicit = true },
        .{ .sources = .{ .defaults_text = raw, .overlay_path = user }, .explicit = true },
        .{ .sources = .{ .defaults_text = raw, .args = &.{ "--cursor-style=block", "--cursor-style-blink=true" } }, .explicit = true },
        .{ .sources = .{ .defaults_text = raw, .overrides = &.{ "--cursor-style=block", "--cursor-style-blink=true" } }, .explicit = true },
        .{ .sources = .{ .defaults_text = raw, .args = &.{ "-e", "vim", "--cursor-style=block", "--cursor-style-blink=true" } }, .explicit = false },
        .{ .sources = .{ .defaults_text = raw, .user_path = user, .args = &.{"--config-default-files=false"} }, .explicit = false },
        .{ .sources = .{ .defaults_text = raw, .args = &.{"--gx-launch-profile=Test=direct:vim --cursor-style=bar"} }, .explicit = false },
    };
    for (cases) |case| {
        var cfg = try loadWith(alloc, case.sources);
        defer cfg.deinit();
        try expectNoDiagnostics(&cfg);
        const expected: cursor_policy.Overrides = if (case.explicit) .{ .style = .block, .blink = true } else .{};
        try testing.expectEqualDeep(expected, cursorOverrides(&cfg));
        var clone = try cfg.clone(alloc);
        defer clone.deinit();
        try testing.expectEqualDeep(expected, cursorOverrides(&clone));
        var rebuilt = try rebuild(&clone, alloc, &.{});
        defer rebuilt.deinit();
        try testing.expectEqualDeep(expected, cursorOverrides(&rebuilt));
    }
}

test "GX0057 cursor priority invalid input empty input and overlay removal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const user = try dir.write(arena, "cursor.ghostty", "cursor-style = bar\ncursor-style-blink = false\n");
    const overlay = try dir.write(arena, "gui-settings.ghostty", "cursor-style = underline\ncursor-style-blink = true\n");
    var layers = try Layers.read(alloc, TestSources{ .defaults_text = "cursor-style=block\ncursor-style-blink=true\n", .user_path = user, .overlay_path = overlay });
    defer layers.deinit();
    var cfg = try layers.build(alloc, &.{ "--cursor-style=block_hollow", "--cursor-style-blink=false" });
    defer cfg.deinit();
    try testing.expectEqualDeep(cursor_policy.Overrides{ .style = .block_hollow, .blink = false }, cursorOverrides(&cfg));
    var invalid = try layers.build(alloc, &.{ "--cursor-style=invalid", "--cursor-style-blink=invalid" });
    defer invalid.deinit();
    try testing.expect(!invalid._diagnostics.empty());
    try testing.expectEqualDeep(cursor_policy.Overrides{ .style = .underline, .blink = true }, cursorOverrides(&invalid));
    var empty = try rebuild(&cfg, alloc, &.{ "--cursor-style=", "--cursor-style-blink=" });
    defer empty.deinit();
    try testing.expectEqualDeep(cursor_policy.Overrides{ .style = .block }, cursorOverrides(&empty));
    try layers.setOverlay("cursor-style", &.{});
    try layers.setOverlay("cursor-style-blink", &.{});
    var removed = try layers.build(alloc, &.{});
    defer removed.deinit();
    try testing.expectEqualDeep(cursor_policy.Overrides{ .style = .bar, .blink = false }, cursorOverrides(&removed));
    // A disk reload with the last explicit input removed releases ownership.
    // TestSources uses loadFile directly, unlike production loadDefaultFiles
    // through loadOptionalFile. Keep the input nonempty to test removed keys,
    // rather than the optional-file handling of a zero-byte file.
    _ = try dir.write(arena, "cursor.ghostty", "# Cursor overrides removed.\n");
    _ = try dir.write(arena, "gui-settings.ghostty", "# Cursor overrides removed.\n");
    var reloaded = try loadWith(alloc, TestSources{ .defaults_text = "cursor-style=block\ncursor-style-blink=true\n", .user_path = user, .overlay_path = overlay });
    defer reloaded.deinit();
    try expectNoDiagnostics(&reloaded);
    try testing.expectEqualDeep(cursor_policy.Overrides{}, cursorOverrides(&reloaded));
    var invalid_only = try loadWith(alloc, TestSources{ .defaults_text = "cursor-style=block\n", .args = &.{"--cursor-style=invalid"} });
    defer invalid_only.deinit();
    try testing.expectEqualDeep(cursor_policy.Overrides{}, cursorOverrides(&invalid_only));
}

test "GX0057 theme cursors stay defaults across conditional replay" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const light = try dir.write(arena, "Light", "cursor-style=bar\ncursor-style-blink=false\n");
    const dark = try dir.write(arena, "Dark", "cursor-style=underline\ncursor-style-blink=true\n");
    const theme_arg = try std.fmt.allocPrintSentinel(arena, "--theme=light:{s},dark:{s}", .{ light, dark }, 0);
    var cfg = try loadWith(alloc, TestSources{ .defaults_text = "", .args = &.{theme_arg} });
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);
    try testing.expectEqualDeep(cursor_policy.Overrides{}, cursorOverrides(&cfg));
    var state = cfg._conditional_state;
    state.theme = if (state.theme == .light) .dark else .light;
    var changed = (try cfg.changeConditionalState(state)).?;
    defer changed.deinit();
    if (comptime cursor_policy.enabledFor(build_config.app_runtime)) {
        try testing.expectEqualDeep(cursor_policy.Overrides{}, cursorOverrides(&changed));
    }
    var explicit = try rebuild(&changed, alloc, &.{ "--cursor-style=block", "--cursor-style-blink=true" });
    defer explicit.deinit();
    try testing.expectEqualDeep(cursor_policy.Overrides{ .style = .block, .blink = true }, cursorOverrides(&explicit));
    // Loading without GX layers has no artificial default cursor arguments.
    var upstream = try Config.default(alloc);
    defer upstream.deinit();
    var it = cli.args.sliceIterator(&.{ "--cursor-style=block", "--cursor-style-blink" });
    try upstream.loadIter(alloc, &it);
    try testing.expectEqualDeep(cursor_policy.Overrides{ .style = .block, .blink = true }, cursorOverrides(&upstream));
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

/// The `language` and `command-palette-entry` lines of the embedded
/// defaults.
fn paletteDefaults(arena: Allocator) Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, defaults, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "language") and
            !std.mem.startsWith(u8, line, "command-palette-entry")) continue;
        try result.appendSlice(arena, line);
        try result.append(arena, '\n');
    }
    return result.items;
}

/// The titles and descriptions of the palette entries of the embedded
/// defaults, translated into `lang` where the table has a translation.
fn defaultPaletteTexts(arena: Allocator, lang: i18n.Language) ![]const [2][]const u8 {
    const prefix = "--command-palette-entry=";
    var result: std.ArrayList([2][]const u8) = .empty;
    for (try defaultSteps(arena, defaults)) |step| {
        if (!std.mem.startsWith(u8, step.arg, prefix)) continue;
        const command = try cli.args.parseAutoStruct(inputpkg.Command, arena, step.arg[prefix.len..], null);
        try result.append(arena, .{
            i18n.lookup(lang, command.title) orelse command.title,
            i18n.lookup(lang, command.description) orelse command.description,
        });
    }
    return result.items;
}

/// Checks the titles and descriptions of the `gx:` command palette
/// entries of `cfg`, in order, and that the C mirror matches every entry.
fn expectGxEntries(cfg: *const Config, expected: []const [2][]const u8) !void {
    const testing = std.testing;
    const entries = cfg.@"command-palette-entry";
    try testing.expectEqual(entries.value.items.len, entries.value_c.items.len);
    var count: usize = 0;
    for (entries.value.items, entries.value_c.items) |command, c| {
        try testing.expectEqualStrings(command.title, std.mem.span(c.title));
        try testing.expectEqualStrings(command.description, std.mem.span(c.description));
        if (command.action != .gx) continue;
        try testing.expect(count < expected.len);
        try testing.expectEqualStrings(expected[count][0], command.title);
        try testing.expectEqualStrings(expected[count][1], command.description);
        count += 1;
    }
    try testing.expectEqual(expected.len, count);
}

test "the GX palette entries of the defaults have zh-CN translations" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const english = try defaultPaletteTexts(arena, .en);
    const chinese = try defaultPaletteTexts(arena, .zh_CN);
    try testing.expectEqual(@as(usize, 3), english.len);
    for (english, chinese) |en, zh| {
        for (en, zh) |en_text, zh_text| {
            if (std.mem.eql(u8, en_text, zh_text)) {
                std.debug.print("missing zh-CN translation for {s}\n", .{en_text});
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expectEqualStrings("设置", chinese[0][0]);
}

test "translatePaletteEntry translates the texts of gx: entries" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = "--command-palette-entry=";

    var list: Config.RepeatableCommand = .{};
    const settings = prefix ++ "title:\"Settings\",description:\"Open the Ghostty GX settings.\",action:gx:settings";
    try list.parseCLI(arena, (try translatePaletteEntry(arena, settings, .zh_CN)).?[prefix.len..]);
    // Without a description, and with an argument that has colons.
    const profile = prefix ++ "title:\"Main Menu\",action:gx:new_tab_profile:wsl:Ubuntu";
    try list.parseCLI(arena, (try translatePaletteEntry(arena, profile, .zh_CN)).?[prefix.len..]);

    try testing.expectEqualStrings("设置", list.value.items[0].title);
    try testing.expectEqualStrings(i18n.lookup(.zh_CN, "Open the Ghostty GX settings.").?, list.value.items[0].description);
    try testing.expect(list.value.items[0].action.equal(.{ .gx = .settings }));
    try testing.expectEqualStrings(i18n.lookup(.zh_CN, "Main Menu").?, list.value.items[1].title);
    try testing.expectEqualStrings("", list.value.items[1].description);
    try testing.expect(list.value.items[1].action.equal(.{ .gx = .{ .new_tab_profile = "wsl:Ubuntu" } }));

    for ([_][]const u8{
        prefix ++ "title:\"New Tab\",action:new_tab",
        prefix ++ "title:\"My Settings\",description:\"Mine\",action:gx:settings",
        prefix ++ "title:\"Settings\"",
        "--font-size=12",
    }) |arg| {
        try testing.expectEqual(@as(?[:0]const u8, null), try translatePaletteEntry(arena, arg, .zh_CN));
    }
    try testing.expectEqual(@as(?[:0]const u8, null), try translatePaletteEntry(arena, settings, .en));
}

test "loading on GTK translates the GX palette entries into the configured language" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const english = try defaultPaletteTexts(arena, .en);
    const chinese = try defaultPaletteTexts(arena, .zh_CN);
    const defaults_text = try paletteDefaults(arena);
    const user_en = try dir.write(arena, "config.ghostty", "language = en\n");
    const overlay_zh = try dir.write(arena, gui_settings.file_name, "language = zh-CN\n");

    const cases = [_]struct { TestSources, []const [2][]const u8 }{
        .{ .{ .defaults_text = defaults_text, .translate_palette = true }, chinese },
        .{ .{ .defaults_text = defaults_text, .translate_palette = true, .user_path = user_en }, english },
        .{ .{ .defaults_text = defaults_text, .translate_palette = true, .user_path = user_en, .overlay_path = overlay_zh }, chinese },
        .{ .{ .defaults_text = defaults_text, .translate_palette = true, .overlay_path = overlay_zh, .args = &.{"--language=en"} }, english },
        .{ .{ .defaults_text = defaults_text, .translate_palette = true, .args = &.{ "--language=en", "-e", "--language=zh-CN" } }, english },
        // Other app runtimes translate entries when they show them.
        .{ .{ .defaults_text = defaults_text }, english },
    };
    for (cases) |case| {
        var cfg = try loadWith(testing.allocator, case[0]);
        defer cfg.deinit();
        try expectNoDiagnostics(&cfg);
        try expectGxEntries(&cfg, case[1]);
    }

    // Entries the user writes are shown as written.
    const user_entry = try dir.write(arena, "entry.ghostty", "command-palette-entry = title:\"Settings\",action:gx:settings\n");
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = defaults_text,
        .user_path = user_entry,
        .translate_palette = true,
    });
    defer cfg.deinit();
    const expected = try std.mem.concat(arena, [2][]const u8, &.{ chinese, &.{.{ "Settings", "" }} });
    try expectGxEntries(&cfg, expected);
}

test "translated GX palette entries survive conditional reloads and clones" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const chinese = try defaultPaletteTexts(arena, .zh_CN);
    const light = try dir.write(arena, "light", "background = #eeeeee\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    const defaults_text = try std.fmt.allocPrint(
        arena,
        "theme = light:{s},dark:{s}\n{s}",
        .{ light, dark, try paletteDefaults(arena) },
    );

    var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text, .translate_palette = true });
    defer cfg.deinit();
    try expectGxEntries(&cfg, chinese);

    var dark_cfg = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer dark_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark_cfg.background);
    try expectGxEntries(&dark_cfg, chinese);

    var cloned = try dark_cfg.clone(testing.allocator);
    defer cloned.deinit();
    try expectGxEntries(&cloned, chinese);
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

test "a window material that shows behind the terminals gets a default background opacity" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const light = try dir.write(arena, "light", "background = #eeeeee\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    const defaults_text = try std.fmt.allocPrint(arena, "theme = light:{s},dark:{s}\n", .{ light, dark });
    const mica = try dir.write(arena, "mica.ghostty", "gx-window-material = mica\n");
    const acrylic = try dir.write(arena, "acrylic.ghostty", "gx-window-material = acrylic\n");
    const own = try dir.write(arena, "own.ghostty", "background-opacity = 0.9\ngx-window-material = tabbed\n");
    const opaque_overlay = try dir.write(arena, "opaque.ghostty", "background-opacity = 1\n");

    const cases = [_]struct { TestSources, f64 }{
        .{ .{ .defaults_text = defaults_text, .user_path = mica, .material_opacity = true }, 0.3 },
        .{ .{ .defaults_text = defaults_text, .user_path = acrylic, .material_opacity = true }, 0.75 },
        .{ .{ .defaults_text = defaults_text, .args = &.{"--gx-window-material=tabbed"}, .material_opacity = true }, 0.3 },
        // A layer that sets the opacity wins, whatever its rank.
        .{ .{ .defaults_text = defaults_text, .user_path = own, .material_opacity = true }, 0.9 },
        .{ .{ .defaults_text = defaults_text, .user_path = mica, .overlay_path = opaque_overlay, .material_opacity = true }, 1 },
        // No material, a material reset, or a material the app runtime
        // cannot show behind the terminals.
        .{ .{ .defaults_text = defaults_text, .material_opacity = true }, 1 },
        .{ .{ .defaults_text = defaults_text, .user_path = mica, .args = &.{"--gx-window-material="}, .material_opacity = true }, 1 },
        .{ .{ .defaults_text = defaults_text, .user_path = mica }, 1 },
    };
    for (cases) |case| {
        var cfg = try loadWith(testing.allocator, case[0]);
        defer cfg.deinit();
        try expectNoDiagnostics(&cfg);
        try testing.expectEqual(case[1], cfg.@"background-opacity");
    }

    // The default is configuration input: conditional reloads keep it.
    var cfg = try loadWith(testing.allocator, TestSources{ .defaults_text = defaults_text, .user_path = mica, .material_opacity = true });
    defer cfg.deinit();
    var dark_cfg = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer dark_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark_cfg.background);
    try testing.expectEqual(@as(f64, 0.3), dark_cfg.@"background-opacity");
}

test "applyArg ranks above every layer and keeps the -e command" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const light = try dir.write(arena, "light", "background = #eeeeee\nbackground-opacity = 0.5\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    const user = try dir.write(arena, "config.ghostty", "background-opacity = 0.8\n");
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = try std.fmt.allocPrint(arena, "theme = light:{s},dark:{s}\n", .{ light, dark }),
        .user_path = user,
        .args = &.{ "--font-size=15", "-e", "htop" },
    });
    defer cfg.deinit();
    try testing.expectEqual(@as(f64, 0.8), cfg.@"background-opacity");

    try applyArg(&cfg, testing.allocator, "--background-opacity=1");
    try expectNoDiagnostics(&cfg);
    try testing.expectEqual(@as(f64, 1), cfg.@"background-opacity");
    try testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try testing.expectEqual(Config.Color{ .r = 0xee, .g = 0xee, .b = 0xee }, cfg.background);
    const command = cfg.@"initial-command".?.direct;
    try testing.expectEqual(@as(usize, 1), command.len);
    try testing.expectEqualStrings("htop", command[0]);

    var dark_cfg = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer dark_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark_cfg.background);
    try testing.expectEqual(@as(f64, 1), dark_cfg.@"background-opacity");
    try testing.expectEqual(@as(usize, 1), dark_cfg.@"initial-command".?.direct.len);

    try applyArg(&cfg, testing.allocator, "--background-opacity=0.8");
    try testing.expectEqual(@as(f64, 0.8), cfg.@"background-opacity");
}

/// Fails, naming the keys, when two configurations differ in any key or in
/// their number of diagnostics.
fn expectSameConfig(expected: *const Config, actual: *const Config) !void {
    var changes = expected.changeIterator(actual);
    var same = true;
    while (changes.next()) |key| {
        // `Path.equal` compares the pointers of the paths, so separately
        // loaded configurations always differ there; compare the text.
        if (key == .@"config-file") {
            const a = expected.@"config-file".value.items;
            const b = actual.@"config-file".value.items;
            if (a.len == b.len) {
                for (a, b) |x, y| {
                    if (std.meta.activeTag(x) != std.meta.activeTag(y)) break;
                    const x_path, const y_path = switch (x) {
                        inline else => |path, tag| .{ path, @field(y, @tagName(tag)) },
                    };
                    if (!std.mem.eql(u8, x_path, y_path)) break;
                } else continue;
            }
        }
        if (key == .@"font-codepoint-map") {
            const a = expected.@"font-codepoint-map".map.list.slice();
            const b = actual.@"font-codepoint-map".map.list.slice();
            try std.testing.expectEqual(a.len, b.len);
            for (0..a.len) |i| try std.testing.expectEqualDeep(a.get(i), b.get(i));
            continue;
        }
        std.debug.print("configurations differ in {t}\n", .{key});
        same = false;
    }
    try std.testing.expect(same);
    try std.testing.expectEqual(expected._diagnostics.items().len, actual._diagnostics.items().len);
}

test "Layers.build gives what loading gives, without reading the files again" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const light = try dir.write(arena, "light", "background = #eeeeee\nforeground = #010101\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    _ = try dir.write(arena, "include.ghostty", "window-padding-y = 7\nfont-family = I\n");
    const sources: TestSources = .{
        .defaults_text = try std.fmt.allocPrint(
            arena,
            "theme = light:{s},dark:{s}\nfont-size = 12\nfont-family = A\nlanguage = zh-CN\n",
            .{ light, dark },
        ),
        .user_path = try dir.write(arena, "config.ghostty", "font-size = 13\nconfig-file = include.ghostty\n"),
        .overlay_path = try dir.write(arena, gui_settings.file_name, "language = en\nfont-family = O\n"),
        .args = &.{ "--window-padding-x=20", "-e", "htop", "--font-size=99" },
        .overrides = &.{"--font-size=17"},
        .translate_palette = true,
        .material_opacity = true,
    };

    var loaded = try loadWith(testing.allocator, sources);
    defer loaded.deinit();
    var layers = try Layers.read(testing.allocator, sources);
    defer layers.deinit();

    // Builds keep what was read.
    _ = try dir.write(arena, "config.ghostty", "font-size = 30\n");
    _ = try dir.write(arena, "include.ghostty", "window-padding-y = 1\n");
    _ = try dir.write(arena, gui_settings.file_name, "language = zh-CN\n");

    var built = try layers.build(testing.allocator, sources.overrides);
    defer built.deinit();
    try expectSameConfig(&loaded, &built);
    try expectNoDiagnostics(&built);
    try testing.expectEqual(@as(f32, 17), built.@"font-size");
    try testing.expectEqualStrings("en", built.language.?);
    try expectFamilies(&.{"O"}, built.@"font-family");
    try testing.expectEqual(@as(u32, 7), built.@"window-padding-y".top_left);
    try testing.expectEqual(@as(u32, 20), built.@"window-padding-x".top_left);
    try testing.expectEqualStrings("htop", built.@"initial-command".?.direct[0]);

    // Other overrides, such as a theme preview, need no files either.
    var preview = try layers.build(testing.allocator, &.{try std.fmt.allocPrintSentinel(arena, "--theme={s}", .{dark}, 0)});
    defer preview.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, preview.background);
    try testing.expectEqual(@as(f32, 13), preview.@"font-size");

    var dark_cfg = (try built.changeConditionalState(.{ .theme = .dark })).?;
    defer dark_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, dark_cfg.background);
    try testing.expectEqual(@as(f32, 17), dark_cfg.@"font-size");
}

test "provenance names the highest layer that sets a key" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    var layers = try Layers.read(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\ncursor-style = block\nfont-family = A\nlanguage = zh-CN\n",
        .user_path = try dir.write(arena, "config.ghostty", "font-size = 13\nlanguage = en\nfont-family-bold = B\n"),
        .overlay_path = try dir.write(arena, gui_settings.file_name, "language = zh-CN\ntheme =\n"),
        .args = &.{ "--window-padding-x=4", "-e", "vim", "--cursor-style=bar" },
    });
    defer layers.deinit();

    try testing.expectEqual(@as(?Layer, .defaults), layers.provenance("cursor-style"));
    try testing.expectEqual(@as(?Layer, .defaults), layers.provenance("font-family"));
    try testing.expectEqual(@as(?Layer, .user), layers.provenance("font-size"));
    try testing.expectEqual(@as(?Layer, .user), layers.provenance("font-family-bold"));
    try testing.expectEqual(@as(?Layer, .overlay), layers.provenance("language"));
    try testing.expectEqual(@as(?Layer, .overlay), layers.provenance("theme"));
    try testing.expectEqual(@as(?Layer, .cli), layers.provenance("window-padding-x"));
    try testing.expectEqual(@as(?Layer, null), layers.provenance("background"));
    try testing.expectEqual(@as(?Layer, null), layers.provenance("font"));
    try testing.expectEqual(@as(?Layer, null), layers.provenance("background-opacity"));

    try testing.expect(layers.sets(.user, "language"));
    try testing.expect(layers.sets(.overlay, "language"));
    try testing.expect(!layers.sets(.cli, "language"));
    try testing.expect(!layers.sets(.user, "font-family"));
}

test "provenance of the background opacity of a window material" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const mica = try dir.write(arena, "config.ghostty", "gx-window-material = mica\n");
    var material = try Layers.read(testing.allocator, TestSources{
        .defaults_text = "font-size = 12\n",
        .user_path = mica,
        .material_opacity = true,
    });
    defer material.deinit();
    try testing.expectEqual(@as(?Layer, .defaults), material.provenance("background-opacity"));

    var hidden = try Layers.read(testing.allocator, TestSources{ .defaults_text = "font-size = 12\n", .user_path = mica });
    defer hidden.deinit();
    try testing.expectEqual(@as(?Layer, null), hidden.provenance("background-opacity"));

    try material.setOverlay("background-opacity", &.{"0.9"});
    try testing.expectEqual(@as(?Layer, .overlay), material.provenance("background-opacity"));
}

test "setOverlay changes the overlay layer like saving the settings file" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const overlay_path = try dir.write(arena, gui_settings.file_name, "# mine\nfont-size = 14\ntheme =\n");
    const sources: TestSources = .{
        .defaults_text = "font-size = 12\nfont-family = A\n",
        .user_path = try dir.write(arena, "config.ghostty", "font-size = 13\nfont-family = U\n"),
        .overlay_path = overlay_path,
    };
    var layers = try Layers.read(testing.allocator, sources);
    defer layers.deinit();

    const edits = [_]struct { []const u8, []const []const u8 }{
        .{ "font-size", &.{"16"} },
        .{ "font-family", &.{ "X", "Y" } },
        .{ "language", &.{"en"} },
        .{ "font-size", &.{} },
        .{ "theme", &.{} },
    };
    for (edits) |edit| {
        try layers.setOverlay(edit[0], edit[1]);

        var overlay = try gui_settings.Overlay.load(testing.allocator, io, overlay_path);
        defer overlay.deinit();
        try overlay.setAll(edit[0], edit[1]);
        try overlay.save(io, overlay_path);

        var built = try layers.build(testing.allocator, &.{});
        defer built.deinit();
        var loaded = try loadWith(testing.allocator, sources);
        defer loaded.deinit();
        try expectSameConfig(&loaded, &built);
    }

    var built = try layers.build(testing.allocator, &.{});
    defer built.deinit();
    // Without the overlay's line, the user configuration applies again.
    try testing.expectEqual(@as(f32, 13), built.@"font-size");
    try testing.expectEqual(@as(?Layer, .user), layers.provenance("font-size"));
    try expectFamilies(&.{ "X", "Y" }, built.@"font-family");
    try testing.expectEqualStrings("en", built.language.?);
}

test "setOverlay without an overlay file" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const missing = try std.fs.path.join(arena, &.{ dir.root, gui_settings.file_name });
    var layers = try Layers.read(testing.allocator, TestSources{ .defaults_text = "font-size = 12\n", .overlay_path = missing });
    defer layers.deinit();
    try layers.setOverlay("font-size", &.{"15"});
    try layers.setOverlay("font-size", &.{"16"});
    var built = try layers.build(testing.allocator, &.{});
    defer built.deinit();
    try testing.expectEqual(@as(f32, 16), built.@"font-size");
    try testing.expectEqual(@as(?Layer, .overlay), layers.provenance("font-size"));
}

test "an unreadable overlay and an unsupported language are reported" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    // A directory where the overlay file belongs.
    try dir.tmp.dir.createDirPath(io, gui_settings.file_name);
    const overlay = try std.fs.path.join(arena, &.{ dir.root, gui_settings.file_name });
    const theme = try dir.write(arena, "theme", "background = #111111\n");
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = try std.fmt.allocPrint(arena, "theme = {s}\nlanguage = zh-CN\n", .{theme}),
        .user_path = try dir.write(arena, "config.ghostty", "language = fr\n"),
        .overlay_path = overlay,
    });
    defer cfg.deinit();

    const diags = cfg._diagnostics.items();
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, gui_settings.file_name) != null);
    try testing.expectEqualStrings("language", diags[1].key);
    try testing.expect(std.mem.indexOf(u8, diags[1].message, "\"fr\"") != null);
    // The language still falls back to zh-CN.
    try testing.expectEqual(i18n.Language.zh_CN, i18n.resolve(cfg.language));

    // Replays report them again, once.
    var cloned = try cfg.clone(testing.allocator);
    defer cloned.deinit();
    try cloned.finalize();
    try testing.expectEqual(@as(usize, 2), cloned._diagnostics.items().len);
    var rebuilt = try rebuild(&cfg, testing.allocator, &.{});
    defer rebuilt.deinit();
    try testing.expectEqual(@as(usize, 2), rebuilt._diagnostics.items().len);
    try testing.expectEqual(diagnosticsDigest(&cfg), diagnosticsDigest(&rebuilt));
}

test "supported, unset and reset languages are not reported" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    for ([_][]const u8{ "language = en\n", "language = zh_CN.UTF-8\n", "language = EN-us\n", "language =\n", "font-size = 13\n" }) |text| {
        var cfg = try loadWith(testing.allocator, TestSources{
            .defaults_text = "language = zh-CN\n",
            .user_path = try dir.write(arena, "config.ghostty", text),
        });
        defer cfg.deinit();
        try expectNoDiagnostics(&cfg);
    }
    // The last value counts, -e and its command aside.
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = "language = de\n",
        .args = &.{ "--language=en", "-e", "--language=xx" },
    });
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);
}

test "diagnosticsDigest changes with the diagnostics only" {
    const testing = std.testing;
    var a = try Config.default(testing.allocator);
    defer a.deinit();
    var b = try Config.default(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(u64, 0), diagnosticsDigest(&a));

    try a.addDiagnosticFmt("one {d}", .{1});
    try b.addDiagnosticFmt("one {d}", .{1});
    try testing.expect(diagnosticsDigest(&a) != 0);
    try testing.expectEqual(diagnosticsDigest(&a), diagnosticsDigest(&b));

    try b.addDiagnosticFmt("two", .{});
    try testing.expect(diagnosticsDigest(&a) != diagnosticsDigest(&b));
    try a.addDiagnosticFmt("two", .{});
    try testing.expectEqual(diagnosticsDigest(&a), diagnosticsDigest(&b));
}

test "rebuild keeps the inputs, the conditional state and the command" {
    const testing = std.testing;
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();

    const light = try dir.write(arena, "light", "background = #eeeeee\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    const user = try dir.write(arena, "config.ghostty", "font-size = 13\nfont-family = U\n");
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = try std.fmt.allocPrint(arena, "theme = light:{s},dark:{s}\nfont-family = A\n", .{ light, dark }),
        .user_path = user,
        .args = &.{ "--font-size=15", "-e", "htop" },
    });
    defer cfg.deinit();
    var dark_cfg = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer dark_cfg.deinit();

    try dir.tmp.dir.deleteFile(testing.io, "config.ghostty");
    var rebuilt = try rebuild(&dark_cfg, testing.allocator, &.{});
    defer rebuilt.deinit();
    try expectSameConfig(&dark_cfg, &rebuilt);
    try testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x11, .b = 0x11 }, rebuilt.background);

    var light_cfg = (try rebuilt.changeConditionalState(.{ .theme = .light })).?;
    defer light_cfg.deinit();
    try testing.expectEqual(Config.Color{ .r = 0xee, .g = 0xee, .b = 0xee }, light_cfg.background);
    try testing.expectEqual(@as(f32, 15), light_cfg.@"font-size");
    try expectFamilies(&.{"U"}, light_cfg.@"font-family");
    try testing.expectEqualStrings("htop", light_cfg.@"initial-command".?.direct[0]);

    var quiet = try rebuild(&cfg, testing.allocator, &.{"--app-notifications=no-config-reload"});
    defer quiet.deinit();
    try testing.expect(!quiet.@"app-notifications".@"config-reload");
    try testing.expectEqual(@as(f32, 15), quiet.@"font-size");
}

test "R4 user font suppresses only defaults maps" {
    const testing = std.testing;
    var cfg = try loadWith(testing.allocator, TestSources{
        .defaults_text = "font-family = Default\nfont-codepoint-map = U+4E00-U+9FFF=Default CJK\n",
        .args = &.{ "--font-family=User", "--font-codepoint-map=U+E000=Symbols" },
    });
    defer cfg.deinit();
    try expectNoDiagnostics(&cfg);
    try testing.expect(cfg.@"font-codepoint-map".map.get(0x4e00) == null);
    try testing.expect(cfg.@"font-codepoint-map".map.get(0xe000) != null);
}

test "R4 ordinary font input matrix preserves layer maps and raw defaults" {
    const alloc = std.testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const map = "font-codepoint-map = U+4E00-U+9FFF=Default CJK\n";
    const raw = "font-family = Default\n" ++ map;
    const user = try dir.write(arena, "font.ghostty", "font-family = User\n");
    const empty = try dir.write(arena, "empty.ghostty", "font-family =\n");
    _ = try dir.write(arena, "nested.ghostty", "font-family = Included\n");
    const include = try dir.write(arena, "include.ghostty", "config-file = nested.ghostty\n");
    const include_arg = try std.fmt.allocPrint(arena, "--config-file={s}", .{include});
    const custom = try dir.write(arena, "maps.ghostty", "font-family = User\nfont-codepoint-map = U+E000=User Symbols\n");
    const overlay = try dir.write(arena, "overlay.ghostty", "font-codepoint-map = U+E001=GUI Symbols\n");
    const identical = try dir.write(arena, "identical.ghostty", "font-family = User\n" ++ map);
    const cases = [_]struct { sources: TestSources, maps: usize, provenance: ?Layer }{
        .{ .sources = .{ .defaults_text = raw }, .maps = 1, .provenance = .defaults },
        .{ .sources = .{ .defaults_text = raw, .user_path = user }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .user_path = empty }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .user_path = include }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .args = &.{include_arg} }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .overlay_path = user }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .args = &.{"--font-family=CLI"} }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .overrides = &.{"--font-family=Preview"} }, .maps = 0, .provenance = .defaults },
        .{ .sources = .{ .defaults_text = raw, .overrides = &.{"--font-family="} }, .maps = 0, .provenance = .defaults },
        .{ .sources = .{ .defaults_text = raw, .args = &.{ "--font-family-bold=Bold", "--font-family-italic=Italic", "--font-family-bold-italic=Both" } }, .maps = 1, .provenance = .defaults },
        .{ .sources = .{ .defaults_text = raw, .args = &.{ "-e", "sh", "--font-family=Not Config" } }, .maps = 1, .provenance = .defaults },
        .{ .sources = .{ .defaults_text = raw, .user_path = user, .overlay_path = user, .args = &.{"--config-default-files=false"} }, .maps = 1, .provenance = .defaults },
        .{ .sources = .{ .defaults_text = raw, .user_path = user, .args = &.{ "--config-default-files=false", include_arg } }, .maps = 0, .provenance = null },
        .{ .sources = .{ .defaults_text = raw, .user_path = custom, .overlay_path = overlay, .args = &.{"--font-codepoint-map=U+E002=CLI Symbols"} }, .maps = 3, .provenance = .cli },
        .{ .sources = .{ .defaults_text = raw, .user_path = identical }, .maps = 1, .provenance = .user },
    };
    for (cases) |case| {
        var loaded = try loadWith(alloc, case.sources);
        defer loaded.deinit();
        try expectNoDiagnostics(&loaded);
        try std.testing.expectEqual(case.maps, loaded.@"font-codepoint-map".map.list.len);
        var layers = try Layers.read(alloc, case.sources);
        defer layers.deinit();
        try std.testing.expect(stepsSet(layers.steps.get(.defaults).items, "font-codepoint-map"));
        try std.testing.expectEqual(case.provenance, layers.provenance("font-codepoint-map"));
        var built = try layers.build(alloc, case.sources.overrides);
        defer built.deinit();
        try expectSameConfig(&loaded, &built);
    }
}

test "R4 deleting GUI font restores defaults only without lower user font" {
    const alloc = std.testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const user = try dir.write(arena, "font.ghostty", "font-family = User\n");
    for ([_]?[]const u8{ null, user }) |path| {
        var layers = try Layers.read(alloc, TestSources{
            .defaults_text = "font-codepoint-map = U+4E00-U+9FFF=Default CJK\n",
            .user_path = path,
        });
        defer layers.deinit();
        try layers.setOverlay("font-codepoint-map", &.{"U+E000=Symbols"});
        try layers.setOverlay("font-family", &.{"GUI"});
        var chosen = try layers.build(alloc, &.{});
        defer chosen.deinit();
        try std.testing.expect(chosen.@"font-codepoint-map".map.get(0x4e00) == null);
        try std.testing.expect(chosen.@"font-codepoint-map".map.get(0xe000) != null);
        try layers.setOverlay("font-family", &.{});
        var restored = try layers.build(alloc, &.{});
        defer restored.deinit();
        try std.testing.expectEqual(path == null, restored.@"font-codepoint-map".map.get(0x4e00) != null);
        try std.testing.expect(restored.@"font-codepoint-map".map.get(0xe000) != null);
        try layers.setOverlay("font-codepoint-map", &.{});
        try std.testing.expectEqual(@as(?Layer, if (path == null) .defaults else null), layers.provenance("font-codepoint-map"));
    }
}

test "R4 effective defaults survive conditional replay clone finalize and rebuild" {
    const alloc = std.testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const light = try dir.write(arena, "light", "background = #eeeeee\n");
    const dark = try dir.write(arena, "dark", "background = #111111\n");
    var config = try loadWith(alloc, TestSources{
        .defaults_text = try std.fmt.allocPrint(arena, "theme = light:{s},dark:{s}\ncursor-style-blink = true\nfont-codepoint-map = U+4E00-U+9FFF=Default CJK\n", .{ light, dark }),
        .args = &.{ "--font-family=User", "--font-codepoint-map=U+E000=Symbols", "-e", "sh", "--font-family=Command" },
        .system_cursor_blink = false,
    });
    defer config.deinit();
    var switched = (try config.changeConditionalState(.{ .theme = .dark })).?;
    defer switched.deinit();
    var clone = try switched.clone(alloc);
    defer clone.deinit();
    try clone.finalize();
    try clone.finalize();
    var rebuilt = try rebuild(&clone, alloc, &.{"--language=en"});
    defer rebuilt.deinit();
    for ([_]*const Config{ &config, &switched, &clone, &rebuilt }) |cfg| {
        try expectNoDiagnostics(cfg);
        try std.testing.expect(cfg.@"font-codepoint-map".map.get(0x4e00) == null);
        try std.testing.expect(cfg.@"font-codepoint-map".map.get(0xe000) != null);
        try std.testing.expectEqual(@as(?bool, false), cfg.@"cursor-style-blink");
        try std.testing.expectEqualStrings("--font-family=Command", cfg.@"initial-command".?.direct[1]);
    }
}

test "R4 system blink is a default below every user layer and preview" {
    const alloc = std.testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const raw = "cursor-style-blink = true\n";
    const Place = enum { user, include, overlay, cli, preview };
    const values = [_]struct { text: []const u8, expected: ?bool }{
        .{ .text = "true", .expected = true },
        .{ .text = "false", .expected = false },
        .{ .text = "", .expected = null },
    };
    for ([_]?bool{ null, true, false }) |system| {
        var defaults_only = try loadWith(alloc, TestSources{ .defaults_text = raw, .system_cursor_blink = system });
        defer defaults_only.deinit();
        try std.testing.expectEqual(@as(?bool, system != false), defaults_only.@"cursor-style-blink");
        for (std.enums.values(Place)) |place| {
            for (values) |value| {
                const text = try std.fmt.allocPrint(arena, "cursor-style-blink = {s}\n", .{value.text});
                const path = try dir.write(arena, "blink.ghostty", text);
                const arg = try std.fmt.allocPrintSentinel(arena, "--cursor-style-blink={s}", .{value.text}, 0);
                var sources: TestSources = .{ .defaults_text = raw, .system_cursor_blink = system };
                switch (place) {
                    .user => sources.user_path = path,
                    .include => sources.user_path = try dir.write(arena, "include.ghostty", "config-file = blink.ghostty\n"),
                    .overlay => sources.overlay_path = path,
                    .cli => sources.args = &.{arg},
                    .preview => sources.overrides = &.{arg},
                }
                var config = try loadWith(alloc, sources);
                defer config.deinit();
                try expectNoDiagnostics(&config);
                try std.testing.expectEqual(value.expected, config.@"cursor-style-blink");
                var layers = try Layers.read(alloc, sources);
                defer layers.deinit();
                var built = try layers.build(alloc, sources.overrides);
                defer built.deinit();
                try expectSameConfig(&config, &built);
                const origin: Layer = switch (place) {
                    .user, .include => .user,
                    .overlay => .overlay,
                    .cli => .cli,
                    .preview => .defaults,
                };
                try std.testing.expectEqual(@as(?Layer, origin), layers.provenance("cursor-style-blink"));
            }
        }
    }
}

test "R4 blink snapshot updates without rereading and GUI reset follows system" {
    const alloc = std.testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    _ = try dir.write(arena, "included.ghostty", "font-size = 17\n");
    const user = try dir.write(arena, "config.ghostty", "config-file = included.ghostty\n");
    const overlay = try dir.write(arena, "gui-settings.ghostty", "cursor-style-blink = true\n");
    var layers = try Layers.read(alloc, TestSources{ .defaults_text = "font-size = 12\n", .user_path = user, .overlay_path = overlay });
    defer layers.deinit();
    try dir.tmp.dir.deleteFile(std.testing.io, "config.ghostty");
    try dir.tmp.dir.deleteFile(std.testing.io, "included.ghostty");
    try dir.tmp.dir.deleteFile(std.testing.io, "gui-settings.ghostty");
    try std.testing.expect(layers.setSystemCursorBlink(false));
    var config = try layers.build(alloc, &.{});
    defer config.deinit();
    try std.testing.expectEqual(@as(?bool, true), config.@"cursor-style-blink");
    try std.testing.expectEqual(@as(f32, 17), config.@"font-size");
    try layers.setOverlay("cursor-style-blink", &.{});
    var restored = try layers.build(alloc, &.{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(?bool, false), restored.@"cursor-style-blink");
    try std.testing.expectEqual(@as(?Layer, .defaults), layers.provenance("cursor-style-blink"));
    try std.testing.expect(!layers.setSystemCursorBlink(false));
    try std.testing.expect(layers.setSystemCursorBlink(null));
    try std.testing.expectEqual(@as(?Layer, null), layers.provenance("cursor-style-blink"));
}

test "R4 defaultConfig uses the same system blink defaults" {
    defer setSystemCursorBlink(null);
    for ([_]?bool{ null, true, false }) |system| {
        setSystemCursorBlink(system);
        var config = try defaultConfig(std.testing.allocator);
        defer config.deinit();
        try std.testing.expectEqual(@as(?bool, system != false), config.@"cursor-style-blink");
    }
}

test "R4 migrated theme is loaded with corrected ANSI whites" {
    const alloc = std.testing.allocator;
    var scratch: ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var dir = try TestDir.init();
    defer dir.deinit();
    const path = try dir.write(arena, gx_theme.name, gx_theme.marker ++ "\n# gx-theme-version: 1\npalette = 7=#bac2de\npalette = 15=#a6adc8\n");
    try std.testing.expectEqual(gx_theme.InstallResult.updated, try gx_theme.install(alloc, std.testing.io, dir.root));
    var config = try loadWith(alloc, TestSources{ .defaults_text = try std.fmt.allocPrint(arena, "theme = {s}\n", .{path}) });
    defer config.deinit();
    try expectNoDiagnostics(&config);
    const RGB = @TypeOf(config.palette.value[7]);
    try std.testing.expectEqual(RGB{ .r = 0xa6, .g = 0xad, .b = 0xc8 }, config.palette.value[7]);
    try std.testing.expectEqual(RGB{ .r = 0xba, .g = 0xc2, .b = 0xde }, config.palette.value[15]);
    try std.testing.expect(config.palette.value[15].luminance() >= config.palette.value[7].luminance());
}
