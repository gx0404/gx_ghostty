//! The Ghostty GX settings UI model, independent of any UI toolkit: the
//! choices a settings UI offers, the configuration keys and values they
//! write to `gui-settings.ghostty`, the msgids of their labels, and the
//! pending changes a UI saves in one go. The GTK settings dialog
//! (`src/apprt/gtk/gx/settings_dialog.zig`) and the Windows settings
//! overlay (`src/apprt/win32/ui/Settings.zig`) only render it; the Windows
//! command palette uses its theme list and changes as well.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Config = @import("../config/Config.zig");
const gui_settings = @import("gui_settings.zig");
const profiles = @import("profiles.zig");

/// The msgids of the settings UI strings, translated in
/// `i18n/gx.zh_CN.po`. Placeholders are filled with `i18n.fill`.
pub const msg = struct {
    pub const settings = "Settings";
    pub const changes_saved = "Changes are saved automatically.";
    pub const language = "Language";
    pub const interface_language = "Interface Language";
    pub const appearance = "Appearance";
    pub const theme = "Theme";
    pub const theme_hint = "Move through the list to preview a theme. Press Enter or Apply to keep it.";
    pub const search_themes = "Search themes…";
    pub const no_themes = "No matching themes";
    pub const apply = "Apply";
    pub const window_material = "Window Material";
    pub const material_hint = "Blur needs compositor support.";
    pub const font = "Font";
    pub const font_size = "Font Size";
    pub const reset_to_default = "Reset to Default";
    pub const font_family = "Font Family";
    pub const font_family_hint = "Leave empty to use the default font.";
    pub const interaction = "Interaction";
    pub const right_click = "Right-Click Action";
    pub const show_scrollbar = "Show Scrollbar";
    pub const close_confirmation = "Close Confirmation";
    pub const bell = "Bell";
    pub const shell = "Shell";
    pub const default_shell = "Default Shell";
    pub const default_shell_hint = "Used by new tabs and windows.";
    pub const system_default = "System Default";
    pub const custom_command = "Custom: {command}";
    pub const herdr_updated = "herdr now starts GX Zsh by default.";
    pub const herdr_user_config = "herdr uses your own configuration, so its default shell was left unchanged.";
    pub const herdr_failed = "Could not set the default shell of herdr: {reason}";
    pub const herdr_exit = "herdr exited with code {code} while setting its default shell.";
    pub const about = "About";
    pub const app_name = "Ghostty GX";
    pub const version = "Version {version}";
    pub const config_file = "Configuration File";
    pub const settings_file = "Settings File";
    pub const settings_file_hint = "Settings made here are saved to this file and override the configuration file.";
    pub const open_config_file = "Open Configuration File";
    pub const open_failed = "Could not open the configuration file: {reason}";
    pub const save_failed = "Could not save the settings: {reason}";
    pub const reload_failed = "Could not reload the configuration: {reason}";
    pub const preview_failed = "Could not preview the theme: {reason}";
};

/// A choice of a settings UI: a configuration value and the msgid of its
/// label.
pub fn Choice(comptime T: type) type {
    return struct {
        value: T,
        label: [:0]const u8,
    };
}

/// The position of `value` in `choices`, or null if it is not offered.
pub fn choiceIndex(comptime T: type, choices: []const Choice(T), value: T) ?usize {
    for (choices, 0..) |choice, i| {
        if (choice.value == value) return i;
    }
    return null;
}

/// The `right-click-action` choices, in display order.
pub const right_click_choices = [_]Choice(Config.RightClickAction){
    .{ .value = .@"context-menu", .label = "Show Context Menu" },
    .{ .value = .@"copy-or-paste", .label = "Copy or Paste" },
    .{ .value = .paste, .label = "Paste" },
    .{ .value = .copy, .label = "Copy" },
    .{ .value = .ignore, .label = "Do Nothing" },
};

/// The `confirm-close-surface` choices, in display order.
pub const close_confirmation_choices = [_]Choice(Config.ConfirmCloseSurface){
    .{ .value = .true, .label = "If a Process Runs" },
    .{ .value = .always, .label = "Always" },
    .{ .value = .false, .label = "Never" },
};

/// The `bell-features` flags, in display order, with the msgids of their
/// labels.
pub const bell_features = [_]struct {
    field: [:0]const u8,
    label: [:0]const u8,
}{
    .{ .field = "system", .label = "System Sound" },
    .{ .field = "audio", .label = "Audio File" },
    .{ .field = "attention", .label = "Request Attention" },
    .{ .field = "title", .label = "Bell Icon in Title" },
    .{ .field = "border", .label = "Border Highlight" },
};

/// A configuration line a choice writes.
pub const Setting = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

/// The window material presets. Each one sets only keys the GTK apprt
/// honours: `background-opacity` and `background-blur`
/// (`gx-window-material` is Windows only).
pub const Material = enum {
    solid,
    translucent,
    blur,

    /// The msgid of the label.
    pub fn label(self: Material) [:0]const u8 {
        return switch (self) {
            .solid => "Solid",
            .translucent => "Translucent",
            .blur => "Blur",
        };
    }

    /// The configuration lines the preset writes. Both keys are always
    /// written so a blur set elsewhere cannot leak into another preset.
    pub fn settings(self: Material) [2]Setting {
        return switch (self) {
            .solid => .{
                .{ .key = "background-opacity", .value = "1" },
                .{ .key = "background-blur", .value = "false" },
            },
            .translucent => .{
                .{ .key = "background-opacity", .value = "0.9" },
                .{ .key = "background-blur", .value = "false" },
            },
            .blur => .{
                .{ .key = "background-opacity", .value = "0.85" },
                .{ .key = "background-blur", .value = "true" },
            },
        };
    }

    /// The preset that describes a configuration: opaque windows are
    /// solid, translucent ones blur or not.
    pub fn fromConfig(opacity: f64, blur: bool) Material {
        if (opacity >= 1) return .solid;
        return if (blur) .blur else .translucent;
    }
};

/// The font size range and step of the settings UI.
pub const FontSize = struct {
    pub const min: f32 = 6;
    pub const max: f32 = 100;
    pub const step: f32 = 0.5;

    /// The Ghostty GX default (`defaults.ghostty`) that "reset" restores.
    pub const default: f32 = 12;

    /// Clamps `value` to the range and rounds it to one decimal.
    pub fn normalize(value: f64) f32 {
        if (std.math.isNan(value)) return default;
        const clamped = std.math.clamp(value, min, max);
        return @floatCast(@round(clamped * 10) / 10);
    }

    /// Formats a normalized size as a configuration value, without
    /// trailing zeros (`12`, `12.5`).
    pub fn format(buf: []u8, value: f32) error{NoSpaceLeft}![]const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{value});
    }
};

/// The `scrollbar` value for a "show scrollbar" switch.
pub fn scrollbar(show: bool) Config.Scrollbar {
    return if (show) .system else .never;
}

/// Formats a packed struct of flags (such as `bell-features`) as a
/// configuration value that sets every flag explicitly, e.g.
/// `system,no-audio,attention`, so it does not depend on the defaults.
pub fn formatFlags(comptime T: type, value: T, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (i > 0) writer.writeByte(',') catch return error.NoSpaceLeft;
        if (!@field(value, field.name)) writer.writeAll("no-") catch return error.NoSpaceLeft;
        writer.writeAll(field.name) catch return error.NoSpaceLeft;
    }
    return writer.buffered();
}

/// The command-line override that keeps a configuration reload quiet:
/// the in-app notifications of `current` without the "Reloaded the
/// configuration" toast. Settings UIs apply it while previewing, so
/// browsing themes does not raise a toast for every step.
pub fn quietReloadArg(buf: []u8, current: Config.AppNotifications) error{NoSpaceLeft}![:0]const u8 {
    var quiet = current;
    quiet.@"config-reload" = false;
    var flags_buf: [128]u8 = undefined;
    const flags = try formatFlags(Config.AppNotifications, quiet, &flags_buf);
    return std.fmt.bufPrintZ(buf, "--app-notifications={s}", .{flags});
}

/// The command-line override that previews the theme `name`.
pub fn themeArg(alloc: Allocator, name: []const u8) Allocator.Error![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "--theme={s}", .{name}, 0);
}

/// The theme a theme list shows as selected for a `theme` value: the
/// theme when light and dark use the same one, otherwise null.
pub fn themeName(theme: ?Config.Theme) ?[]const u8 {
    const value = theme orelse return null;
    if (!std.mem.eql(u8, value.light, value.dark)) return null;
    return value.light;
}

/// Whether the theme file `name` can be written as a `theme` value: not
/// hidden, and free of the separators of a light/dark pair (`,`, `=` and
/// `:`), surrounding blanks and control characters.
pub fn isThemeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    if (std.mem.indexOfAny(u8, name, ",=:") != null) return false;
    if (std.mem.trim(u8, name, " \t").len != name.len) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// The themes a settings UI offers. All memory is owned by `arena`.
pub const ThemeList = struct {
    arena: ArenaAllocator,

    /// Unique theme names, sorted case-insensitively.
    names: []const [:0]const u8,

    pub fn deinit(self: *ThemeList) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The position of `name`, if it is listed.
    pub fn indexOf(self: *const ThemeList, name: []const u8) ?usize {
        for (self.names, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return i;
        }
        return null;
    }
};

/// Lists the theme files in `dirs`, highest priority first (the order of
/// `src/config/theme.zig::LocationIterator`). A name found in several
/// directories is listed once; missing directories are skipped, and
/// files that `isThemeName` rejects are left out.
pub fn listThemes(alloc: Allocator, io: std.Io, dirs: []const []const u8) !ThemeList {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var names: std.ArrayList([:0]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (dirs) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {},
                else => continue,
            }
            if (!isThemeName(entry.name)) continue;
            const result = try seen.getOrPut(arena_alloc, entry.name);
            if (result.found_existing) continue;
            const name = try arena_alloc.dupeZ(u8, entry.name);
            result.key_ptr.* = name;
            try names.append(arena_alloc, name);
        }
    }

    std.mem.sort([:0]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: [:0]const u8, b: [:0]const u8) bool {
            return switch (std.ascii.orderIgnoreCase(a, b)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a, b) == .lt,
            };
        }
    }.lessThan);

    return .{ .arena = arena, .names = names.items };
}

/// The `command` value that starts `profile`: `direct:` and the
/// arguments when none of them needs quoting, otherwise the arguments
/// quoted for the shell that runs the `command` (POSIX single quotes on
/// Linux, the C runtime rules on Windows). Custom profiles already use
/// the `command` syntax and are returned as they are.
pub fn profileCommand(
    alloc: Allocator,
    profile: profiles.Profile,
    platform: profiles.Platform,
) Allocator.Error![:0]u8 {
    const args = switch (profile.command) {
        .command_line => |line| return try alloc.dupeZ(u8, line),
        .argv => |argv| argv,
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const direct = for (args) |arg| {
        if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t") != null) break false;
    } else true;
    if (direct) try out.appendSlice(alloc, "direct:");

    for (args, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, ' ');
        if (direct) {
            try out.appendSlice(alloc, arg);
            continue;
        }
        switch (platform) {
            .linux => try appendPosixQuoted(alloc, &out, arg),
            .windows => try appendWindowsQuoted(alloc, &out, arg),
        }
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

/// Appends `arg` for `/bin/sh`, single-quoted unless it only contains
/// characters the shell takes literally.
fn appendPosixQuoted(alloc: Allocator, out: *std.ArrayList(u8), arg: []const u8) Allocator.Error!void {
    const plain = arg.len > 0 and for (arg) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._-+=:,@%", c) == null) break false;
    } else true;
    if (plain) return try out.appendSlice(alloc, arg);

    try out.append(alloc, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
}

/// Appends `arg` so the C runtime command-line rules read it back as one
/// argument: double quotes around it, with backslashes doubled before a
/// quote and quotes escaped.
fn appendWindowsQuoted(alloc: Allocator, out: *std.ArrayList(u8), arg: []const u8) Allocator.Error!void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) return try out.appendSlice(alloc, arg);

    try out.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                try out.appendNTimes(alloc, '\\', backslashes * 2 + 1);
                try out.append(alloc, '"');
                backslashes = 0;
            },
            else => {
                try out.appendNTimes(alloc, '\\', backslashes);
                try out.append(alloc, c);
                backslashes = 0;
            },
        }
    }
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
}

/// Settings changed in a settings UI and not saved yet, in the order they
/// were first changed. A UI collects changes for a moment and then
/// `commit`s them, so rapid edits write the overlay file once.
pub const Changes = struct {
    arena: ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        key: []const u8,

        /// The new values of the key; empty removes it from the overlay.
        values: []const []const u8,
    };

    pub fn init(alloc: Allocator) Changes {
        return .{ .arena = .init(alloc) };
    }

    pub fn deinit(self: *Changes) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Changes) bool {
        return self.entries.items.len == 0;
    }

    /// Sets `key` to `value`.
    pub fn set(self: *Changes, key: []const u8, value: []const u8) Allocator.Error!void {
        try self.setAll(key, &.{value});
    }

    /// Sets a repeatable key to `values`; an empty `values` removes it.
    pub fn setAll(self: *Changes, key: []const u8, values: []const []const u8) Allocator.Error!void {
        const alloc = self.arena.allocator();
        const copies = try alloc.alloc([]const u8, values.len);
        for (values, copies) |value, *copy| copy.* = try alloc.dupe(u8, value);

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.values = copies;
                return;
            }
        }
        try self.entries.append(alloc, .{ .key = try alloc.dupe(u8, key), .values = copies });
    }

    /// Removes `key` from the overlay, so lower layers apply again.
    pub fn delete(self: *Changes, key: []const u8) Allocator.Error!void {
        try self.setAll(key, &.{});
    }

    /// Applies the changes to `overlay`.
    pub fn apply(self: *const Changes, overlay: *gui_settings.Overlay) (Allocator.Error || gui_settings.Error)!void {
        for (self.entries.items) |entry| try overlay.setAll(entry.key, entry.values);
    }

    /// Writes the changes to the overlay file at `path` (load, apply,
    /// atomic save) and clears them. On error the file and the changes
    /// are left as they were.
    pub fn commit(self: *Changes, alloc: Allocator, io: std.Io, path: []const u8) !void {
        if (self.isEmpty()) return;
        var overlay = try gui_settings.Overlay.load(alloc, io, path);
        defer overlay.deinit();
        try self.apply(&overlay);
        try overlay.save(io, path);
        self.clear();
    }

    pub fn clear(self: *Changes) void {
        self.entries = .empty;
        _ = self.arena.reset(.retain_capacity);
    }
};

const testing = std.testing;
const cli = @import("../cli.zig");
const i18n = @import("i18n.zig");

/// Parses `args` (`--key=value`) into a default configuration.
fn testConfig(args: []const []const u8) !Config {
    var cfg = try Config.default(testing.allocator);
    errdefer cfg.deinit();
    var it = cli.args.sliceIterator(args);
    try cfg.loadIter(testing.allocator, &it);
    try testing.expect(cfg._diagnostics.empty());
    return cfg;
}

fn settingArg(buf: []u8, setting: Setting) ![]const u8 {
    return std.fmt.bufPrint(buf, "--{s}={s}", .{ setting.key, setting.value });
}

test "material presets set opacity and blur" {
    const expected = [_]struct { Material, f64, bool }{
        .{ .solid, 1, false },
        .{ .translucent, 0.9, false },
        .{ .blur, 0.85, true },
    };
    for (expected) |case| {
        var bufs: [2][64]u8 = undefined;
        const lines = case[0].settings();
        // A blur from another layer must not survive a preset.
        var cfg = try testConfig(&.{
            "--background-blur=true",
            try settingArg(&bufs[0], lines[0]),
            try settingArg(&bufs[1], lines[1]),
        });
        defer cfg.deinit();
        try testing.expectEqual(case[1], cfg.@"background-opacity");
        try testing.expectEqual(case[2], cfg.@"background-blur".enabled());
        try testing.expectEqual(case[0], Material.fromConfig(cfg.@"background-opacity", cfg.@"background-blur".enabled()));
    }
}

test "material of other configurations" {
    try testing.expectEqual(Material.solid, Material.fromConfig(1, true));
    try testing.expectEqual(Material.solid, Material.fromConfig(1.5, false));
    try testing.expectEqual(Material.translucent, Material.fromConfig(0.5, false));
    try testing.expectEqual(Material.blur, Material.fromConfig(0.3, true));
}

test "choices offer every value once and parse back" {
    inline for (.{
        .{ Config.RightClickAction, &right_click_choices, "right-click-action" },
        .{ Config.ConfirmCloseSurface, &close_confirmation_choices, "confirm-close-surface" },
    }) |case| {
        const T = case[0];
        const choices: []const Choice(T) = case[1];
        try testing.expectEqual(std.enums.values(T).len, choices.len);
        for (std.enums.values(T)) |value| {
            const index = choiceIndex(T, choices, value).?;
            var buf: [64]u8 = undefined;
            var cfg = try testConfig(&.{try std.fmt.bufPrint(&buf, "--" ++ case[2] ++ "={s}", .{@tagName(value)})});
            defer cfg.deinit();
            try testing.expectEqual(choices[index].value, @field(cfg, case[2]));
        }
    }
    try testing.expectEqual(Config.RightClickAction.@"context-menu", right_click_choices[0].value);
    try testing.expectEqual(Config.ConfirmCloseSurface.true, close_confirmation_choices[0].value);
}

test "bell feature labels cover every flag" {
    const fields = @typeInfo(Config.BellFeatures).@"struct".fields;
    try testing.expectEqual(fields.len, bell_features.len);
    inline for (fields) |field| {
        const found = for (bell_features) |feature| {
            if (std.mem.eql(u8, feature.field, field.name)) break true;
        } else false;
        try testing.expect(found);
    }
}

test "formatFlags round-trips through the parser" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "no-system,no-audio,attention,title,no-border",
        try formatFlags(Config.BellFeatures, .{}, &buf),
    );

    const bells = [_]Config.BellFeatures{
        .{},
        .{ .system = true, .audio = true, .attention = false, .title = false, .border = true },
        .{ .system = false, .audio = false, .attention = false, .title = false, .border = false },
    };
    for (bells) |bell| {
        var arg_buf: [160]u8 = undefined;
        const arg = try std.fmt.bufPrint(&arg_buf, "--bell-features={s}", .{try formatFlags(Config.BellFeatures, bell, &buf)});
        var cfg = try testConfig(&.{ "--bell-features=system,audio", arg });
        defer cfg.deinit();
        try testing.expectEqual(bell, cfg.@"bell-features");
    }

    try testing.expectError(error.NoSpaceLeft, formatFlags(Config.BellFeatures, .{}, buf[0..8]));
}

test "quietReloadArg turns off the reload toast only" {
    for ([_]bool{ true, false }) |clipboard| {
        var buf: [128]u8 = undefined;
        const arg = try quietReloadArg(&buf, .{ .@"clipboard-copy" = clipboard, .@"config-reload" = true });
        var cfg = try testConfig(&.{arg});
        defer cfg.deinit();
        try testing.expect(!cfg.@"app-notifications".@"config-reload");
        try testing.expectEqual(clipboard, cfg.@"app-notifications".@"clipboard-copy");
    }
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "--app-notifications=clipboard-copy,no-config-reload",
        try quietReloadArg(&buf, .{}),
    );
}

test "themeArg previews a theme by name" {
    const arg = try themeArg(testing.allocator, "Builtin Solarized Dark");
    defer testing.allocator.free(arg);
    try testing.expectEqualStrings("--theme=Builtin Solarized Dark", arg);
}

test "font sizes are clamped, rounded and formatted" {
    try testing.expectEqual(@as(f32, 6), FontSize.normalize(1));
    try testing.expectEqual(@as(f32, 100), FontSize.normalize(250));
    try testing.expectEqual(@as(f32, 12.5), FontSize.normalize(12.5));
    try testing.expectEqual(@as(f32, 12.3), FontSize.normalize(12.34));
    try testing.expectEqual(FontSize.default, FontSize.normalize(std.math.nan(f64)));

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("12", try FontSize.format(&buf, 12));
    try testing.expectEqualStrings("12.5", try FontSize.format(&buf, 12.5));
    try testing.expectEqualStrings("6", try FontSize.format(&buf, FontSize.normalize(-3)));

    for ([_]f32{ 6, 12.5, 13.3, 100 }) |size| {
        var arg_buf: [64]u8 = undefined;
        var cfg = try testConfig(&.{try std.fmt.bufPrint(&arg_buf, "--font-size={s}", .{try FontSize.format(&buf, size)})});
        defer cfg.deinit();
        try testing.expectEqual(size, cfg.@"font-size");
    }
}

test "the font size default is the Ghostty GX default" {
    const config_layers = @import("config_layers.zig");
    var cfg = try config_layers.defaultConfig(testing.allocator);
    defer cfg.deinit();
    try testing.expectEqual(FontSize.default, cfg.@"font-size");
    try testing.expect(FontSize.min <= FontSize.default and FontSize.default <= FontSize.max);
}

test "scrollbar switch values" {
    inline for (.{ true, false }) |show| {
        var cfg = try testConfig(&.{"--scrollbar=" ++ @tagName(comptime scrollbar(show))});
        defer cfg.deinit();
        try testing.expectEqual(scrollbar(show), cfg.scrollbar);
    }
}

test "themeName selects single themes only" {
    try testing.expectEqual(@as(?[]const u8, null), themeName(null));
    try testing.expectEqualStrings("GX Mocha", themeName(.{ .light = "GX Mocha", .dark = "GX Mocha" }).?);
    try testing.expectEqual(@as(?[]const u8, null), themeName(.{ .light = "a", .dark = "b" }));

    var cfg = try testConfig(&.{"--theme=Builtin Dark"});
    defer cfg.deinit();
    try testing.expectEqualStrings("Builtin Dark", themeName(cfg.theme).?);
}

test "isThemeName" {
    for ([_][]const u8{ "GX Mocha", "Builtin Solarized Dark", "3024 Night", "Catppuccin Frappé", "a+b (c)" }) |name| {
        try testing.expect(isThemeName(name));
    }
    for ([_][]const u8{ "", ".hidden", ".DS_Store", "a,b", "light:x", "a=b", " padded", "tab\t", "new\nline" }) |name| {
        try testing.expect(!isThemeName(name));
    }
}

test "listThemes merges directories by priority" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "user/subdir");
    try tmp.dir.createDirPath(io, "resources");
    for ([_][]const u8{ "user/b", "user/A", "user/.hidden", "user/x,y", "resources/a2", "resources/b", "resources/C" }) |path| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "background = #000000\n" });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const user = try std.fs.path.join(testing.allocator, &.{ root, "user" });
    defer testing.allocator.free(user);
    const resources = try std.fs.path.join(testing.allocator, &.{ root, "resources" });
    defer testing.allocator.free(resources);
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "missing" });
    defer testing.allocator.free(missing);

    var list = try listThemes(testing.allocator, io, &.{ user, missing, resources });
    defer list.deinit();
    const expected = [_][]const u8{ "A", "a2", "b", "C" };
    try testing.expectEqual(expected.len, list.names.len);
    for (expected, list.names) |e, a| try testing.expectEqualStrings(e, a);
    try testing.expectEqual(@as(?usize, 2), list.indexOf("b"));
    try testing.expectEqual(@as(?usize, null), list.indexOf("B"));
}

test "profileCommand writes direct commands when it can" {
    const alloc = testing.allocator;
    const cases = [_]struct { profiles.Platform, []const [:0]const u8, []const u8 }{
        .{ .linux, &.{"/usr/lib/ohmyzsh-gx/bin/gx-zsh"}, "direct:/usr/lib/ohmyzsh-gx/bin/gx-zsh" },
        .{ .linux, &.{ "/usr/bin/fish", "-l" }, "direct:/usr/bin/fish -l" },
        .{ .linux, &.{ "/opt/my shell/zsh", "-l" }, "'/opt/my shell/zsh' -l" },
        .{ .linux, &.{"/a b/it's"}, "'/a b/it'\\''s'" },
        .{ .windows, &.{"C:\\Windows\\system32\\cmd.exe"}, "direct:C:\\Windows\\system32\\cmd.exe" },
        .{ .windows, &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}, "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"" },
        .{ .windows, &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "-i", "-l" }, "\"C:\\Program Files\\Git\\bin\\bash.exe\" -i -l" },
        .{ .windows, &.{ "C:\\a dir\\", "say \"hi\"" }, "\"C:\\a dir\\\\\" \"say \\\"hi\\\"\"" },
    };
    for (cases) |case| {
        const command = try profileCommand(alloc, .{
            .id = "test",
            .name = "Test",
            .command = .{ .argv = case[1] },
            .kind = .zsh,
        }, case[0]);
        defer alloc.free(command);
        try testing.expectEqualStrings(case[2], command);
    }

    const custom = try profileCommand(alloc, .{
        .id = "custom:Python",
        .name = "Python",
        .command = .{ .command_line = "direct:python -i" },
        .kind = .custom,
    }, .linux);
    defer alloc.free(custom);
    try testing.expectEqualStrings("direct:python -i", custom);
}

test "profileCommand direct commands parse back to the arguments" {
    const argv: []const [:0]const u8 = &.{ "/usr/bin/zsh", "-l", "--no-rcs" };
    const command = try profileCommand(testing.allocator, .{
        .id = "zsh",
        .name = "Zsh",
        .command = .{ .argv = argv },
        .kind = .zsh,
    }, .linux);
    defer testing.allocator.free(command);
    var buf: [128]u8 = undefined;
    var cfg = try testConfig(&.{try std.fmt.bufPrint(&buf, "--command={s}", .{command})});
    defer cfg.deinit();
    const parsed = cfg.command.?.direct;
    try testing.expectEqual(argv.len, parsed.len);
    for (argv, parsed) |e, a| try testing.expectEqualStrings(e, a);
}

test "Changes keep the first position and the last value" {
    var changes: Changes = .init(testing.allocator);
    defer changes.deinit();
    try testing.expect(changes.isEmpty());

    try changes.set("font-size", "13");
    try changes.set("theme", "Dracula");
    try changes.set("font-size", "14");
    try changes.setAll("font-family", &.{ "A", "B" });
    try changes.delete("command");

    var overlay = try gui_settings.Overlay.parse(testing.allocator,
        \\# keep me
        \\command = direct:/bin/zsh
        \\font-size = 12
        \\
    );
    defer overlay.deinit();
    try changes.apply(&overlay);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try overlay.write(&out.writer);
    try testing.expectEqualStrings(
        \\# keep me
        \\font-size = 14
        \\theme = Dracula
        \\font-family = A
        \\font-family = B
        \\
    , out.written());

    changes.clear();
    try testing.expect(changes.isEmpty());
    try changes.set("language", "en");
    try testing.expectEqual(@as(usize, 1), changes.entries.items.len);
}

test "Changes commit to the overlay file" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "ghostty", gui_settings.file_name });
    defer alloc.free(path);

    var changes: Changes = .init(alloc);
    defer changes.deinit();
    try changes.commit(alloc, io, path);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "ghostty", .{}));

    try changes.set("theme", "GX Mocha");
    try changes.set("background-opacity", "0.9");
    try changes.commit(alloc, io, path);
    try testing.expect(changes.isEmpty());

    try changes.delete("background-opacity");
    try changes.set("font-size", "13.5");
    try changes.commit(alloc, io, path);

    var overlay = try gui_settings.Overlay.load(alloc, io, path);
    defer overlay.deinit();
    try testing.expectEqualStrings("GX Mocha", overlay.get("theme").?);
    try testing.expectEqualStrings("13.5", overlay.get("font-size").?);
    try testing.expectEqual(@as(?[]const u8, null), overlay.get("background-opacity"));
}

test "settings strings are translated" {
    var missing: usize = 0;
    const check = struct {
        fn check(id: []const u8, count: *usize) void {
            if (i18n.lookup(.zh_CN, id) != null) return;
            std.debug.print("missing zh-CN translation for {s}\n", .{id});
            count.* += 1;
        }
    }.check;
    inline for (@typeInfo(msg).@"struct".decls) |decl| check(@field(msg, decl.name), &missing);
    for (right_click_choices) |choice| check(choice.label, &missing);
    for (close_confirmation_choices) |choice| check(choice.label, &missing);
    for (bell_features) |feature| check(feature.label, &missing);
    for (std.enums.values(Material)) |material| check(material.label(), &missing);
    try testing.expectEqual(@as(usize, 0), missing);
}
