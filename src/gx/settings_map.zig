//! The Ghostty GX settings UI model, independent of any UI toolkit: the
//! choices a settings UI offers, the configuration keys and values they
//! write to `gui-settings.ghostty`, the msgids of their labels, and the
//! pending changes a UI saves in one go. The GTK settings dialog
//! (`src/apprt/gtk/gx/settings_dialog.zig`) and the Windows settings
//! overlay (`src/apprt/win32/ui/Settings.zig`) only render it; the Windows
//! command palette uses its theme list and changes as well.
//!
//! "Reset to Default" removes the key from the settings file
//! (`Changes.reset`), so the user configuration applies again where it sets
//! the key, else the Ghostty GX default; a UI shows the value the reloaded
//! configuration has. `config_layers.Layers.provenance` tells where a value
//! comes from (`provenanceLabel`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const build_config = @import("../build_config.zig");
const Config = @import("../config/Config.zig");
const action = @import("action.zig");
const branding = @import("branding.zig");
const config_layers = @import("config_layers.zig");
const config_types = @import("config_types.zig");
const gui_settings = @import("gui_settings.zig");
const profiles = @import("profiles.zig");

const log = std.log.scoped(.gx_settings);

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
    pub const notice = branding.notice;
    pub const version = "Version {version}";
    pub const config_file = "Configuration File";
    pub const settings_file = "Settings File";
    pub const settings_file_hint = "Settings made here are saved to this file and override the configuration file.";
    pub const open_config_file = "Open Configuration File";
    pub const open_failed = "Could not open the configuration file: {reason}";
    pub const save_failed = "Could not save the settings: {reason}";
    pub const reload_failed = "Could not reload the configuration: {reason}";
    pub const preview_failed = "Could not preview the theme: {reason}";
    pub const light_theme = "Light Theme";
    pub const dark_theme = "Dark Theme";
    pub const theme_pair_hint = "Windows follow the light or dark mode of the system.";
    pub const accent_color = "Accent Color";
    pub const accent_color_hint = "Marks the active tab, switches, selected items and the keyboard focus.";
    pub const opacity = "Background Opacity";
    pub const opacity_hint = "Automatic keeps the opacity that goes with the window material.";
    pub const cursor = "Cursor";
    pub const cursor_style = "Cursor Style";
    pub const cursor_blink = "Blinking Cursor";
    pub const padding = "Window Padding";
    pub const padding_hint = "Applies to new terminals.";
    pub const focus_follows_mouse = "Focus Follows Mouse";
    pub const focus_follows_mouse_hint = "Moving the mouse over a split focuses it.";
    pub const ctrl_scroll_zoom = "Zoom with Ctrl+Wheel";
    pub const ctrl_scroll_zoom_hint = "Hold Ctrl and turn the mouse wheel, or pinch on a touchpad, to change the font size.";
    pub const from_defaults = "Ghostty GX default";
    pub const from_user = "From the configuration file";
    pub const from_overlay = "From the settings file";
    pub const from_cli = "From the command line, which overrides the settings here";
    pub const from_nothing = "Ghostty default";
};

/// The settings pages, in display order; `gx:settings_page:<page>` opens
/// one.
pub const Page = action.SettingsPage;

/// The msgid of the title of `page`.
pub fn pageLabel(page: Page) [:0]const u8 {
    return switch (page) {
        .language => msg.language,
        .appearance => msg.appearance,
        .font => msg.font,
        .interaction => msg.interaction,
        .shell => msg.shell,
        .about => msg.about,
    };
}

/// The msgid that tells where the value of a setting comes from, for the
/// layer `config_layers.Layers.provenance` returns.
pub fn provenanceLabel(layer: ?config_layers.Layer) [:0]const u8 {
    return switch (layer orelse return msg.from_nothing) {
        .defaults => msg.from_defaults,
        .user => msg.from_user,
        .overlay => msg.from_overlay,
        .cli => msg.from_cli,
    };
}

/// The msgid of a short reason for `err`, for the `{reason}` of messages
/// such as `msg.save_failed`; errors without one give their name.
pub fn errorReason(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "Permission denied.",
        error.FileNotFound => "The file or folder does not exist.",
        error.NoSpaceLeft, error.DiskQuota => "The disk is full.",
        error.ReadOnlyFileSystem => "The disk is read-only.",
        error.PathAlreadyExists => "Another program changed the file at the same time. Try again.",
        error.FileBusy,
        error.SharingViolation,
        error.LockViolation,
        error.AntivirusInterference,
        => "The file is in use by another program.",
        error.InvalidSetting => "The value cannot be written to the settings file.",
        error.OutOfMemory => "Out of memory.",
        error.NameTooLong,
        error.BadPathName,
        error.InvalidPath,
        error.InvalidUtf8,
        error.InvalidWtf8,
        error.NotDir,
        error.IsDir,
        => "The path is not valid.",
        error.FileTooBig, error.StreamTooLong => "The file is too large.",
        error.InputOutput, error.ReadFailed, error.WriteFailed => "Reading or writing the disk failed.",
        error.NetworkNotFound => "The network location is not available.",
        error.NoHomeDir, error.HomeDirectoryNotFound => "The configuration folder could not be found.",
        else => @errorName(err),
    };
}

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

/// The app runtimes with a settings UI.
pub const Runtime = enum {
    win32,
    gtk,

    /// The app runtime of this build; null for those without a settings
    /// UI.
    pub const native: ?Runtime = switch (build_config.app_runtime) {
        .win32 => .win32,
        .gtk => .gtk,
        else => null,
    };
};

/// A `bell-features` flag of the settings UIs.
pub const BellFeature = struct {
    field: [:0]const u8,

    /// The msgid of the label.
    label: [:0]const u8,

    /// The app runtimes that implement the flag; a settings UI lists only
    /// the flags its runtime implements.
    runtimes: std.EnumSet(Runtime),

    pub fn supports(self: BellFeature, runtime: Runtime) bool {
        return self.runtimes.contains(runtime);
    }
};

/// The `bell-features` flags, in display order. Both settings runtimes
/// implement every flag, including the per-terminal border highlight.
pub const bell_features = [_]BellFeature{
    .{ .field = "system", .label = "System Sound", .runtimes = .initFull() },
    .{ .field = "audio", .label = "Audio File", .runtimes = .initFull() },
    .{ .field = "attention", .label = "Request Attention", .runtimes = .initFull() },
    .{ .field = "title", .label = "Bell Icon in Title", .runtimes = .initFull() },
    .{ .field = "border", .label = "Border Highlight", .runtimes = .initFull() },
};

/// The value type of `cursor-style`.
pub const CursorStyle = @FieldType(Config, "cursor-style");

/// The `cursor-style` choices, in display order.
pub const cursor_style_choices = [_]Choice(CursorStyle){
    .{ .value = .block, .label = "Block" },
    .{ .value = .bar, .label = "Bar" },
    .{ .value = .underline, .label = "Underline" },
    .{ .value = .block_hollow, .label = "Hollow Block" },
};

/// A switch of a settings UI: a boolean configuration key.
pub const Switch = struct {
    key: [:0]const u8,

    /// The msgids of the label and of the line under it ("" for none).
    label: [:0]const u8,
    hint: [:0]const u8 = "",

    /// The value a switch in the state `on` writes.
    pub fn value(on: bool) [:0]const u8 {
        return if (on) "true" else "false";
    }
};

/// Whether the cursor blinks (`cursor-style-blink`).
pub const cursor_blink: Switch = .{ .key = "cursor-style-blink", .label = msg.cursor_blink };

/// Whether moving the mouse over a split focuses it.
pub const focus_follows_mouse: Switch = .{
    .key = "focus-follows-mouse",
    .label = msg.focus_follows_mouse,
    .hint = msg.focus_follows_mouse_hint,
};

/// Whether Ctrl and the mouse wheel change the font size.
pub const ctrl_scroll_zoom: Switch = .{
    .key = "gx-ctrl-scroll-zoom",
    .label = msg.ctrl_scroll_zoom,
    .hint = msg.ctrl_scroll_zoom_hint,
};

/// The `gx-accent-color` choices, in display order. A color of its own is
/// not a choice: a UI shows it as `custom_label`, read-only, until "Reset
/// to Default".
pub const Accent = enum {
    brand,
    theme,

    pub const key = "gx-accent-color";

    /// The label of a color set in a configuration file.
    pub const custom_label = "Custom Color";

    /// The msgid of the label.
    pub fn label(self: Accent) [:0]const u8 {
        return switch (self) {
            .brand => "Ghostty GX Purple",
            .theme => "From the Theme",
        };
    }

    /// The value written.
    pub fn value(self: Accent) [:0]const u8 {
        return @tagName(self);
    }

    /// The choice that shows `accent`, or null for a color of its own.
    pub fn fromConfig(accent: config_types.AccentColor) ?Accent {
        return switch (accent) {
            .brand => .brand,
            .theme => .theme,
            .color => null,
        };
    }
};

/// The `background-opacity` choices, in display order.
pub const Opacity = enum {
    /// Removes `background-opacity` from the settings file: the user
    /// configuration applies, else the opacity that goes with the window
    /// material (`config_layers.materialOpacity`), else opaque.
    automatic,
    @"100",
    @"90",
    @"80",
    @"70",

    /// The msgid of the label; the percentages need no translation.
    pub fn label(self: Opacity) [:0]const u8 {
        return switch (self) {
            .automatic => "Automatic",
            inline else => |tag| @tagName(tag) ++ "%",
        };
    }

    /// The value written, or null to remove the key.
    pub fn value(self: Opacity) ?[:0]const u8 {
        return switch (self) {
            .automatic => null,
            .@"100" => "1",
            .@"90" => "0.9",
            .@"80" => "0.8",
            .@"70" => "0.7",
        };
    }

    /// The choice that shows `opacity`: `automatic` unless a layer above
    /// the defaults sets it (`configured`, see
    /// `config_layers.Layers.provenance`), else the choice with that value,
    /// or null for a value no choice offers.
    pub fn fromConfig(opacity: f64, configured: bool) ?Opacity {
        if (!configured) return .automatic;
        for (std.enums.values(Opacity)) |choice| {
            const text = choice.value() orelse continue;
            const number = std.fmt.parseFloat(f64, text) catch continue;
            if (@abs(number - opacity) < 0.005) return choice;
        }
        return null;
    }
};

/// The window padding presets, in display order. Each sets both keys of
/// `keys`, in points; padding applies to new terminals.
pub const Padding = enum {
    /// Keeps the horizontal padding the overlay scrollbar needs.
    compact,

    /// Removes both keys: the user configuration applies, else the Ghostty
    /// GX default (10 × 8 points).
    default,

    spacious,

    pub const keys = [2][:0]const u8{ "window-padding-x", "window-padding-y" };

    /// The msgid of the label.
    pub fn label(self: Padding) [:0]const u8 {
        return switch (self) {
            .compact => "Compact",
            .default => "Default",
            .spacious => "Spacious",
        };
    }

    /// The values of `keys`, or null to remove them.
    pub fn values(self: Padding) ?[2][:0]const u8 {
        return switch (self) {
            .compact => .{ "9", "4" },
            .default => null,
            .spacious => .{ "16", "12" },
        };
    }

    /// The preset that shows the padding `x` and `y`: `default` unless a
    /// layer above the defaults sets either key (`configured`), else the
    /// preset with these values, or null for values no preset has.
    pub fn fromConfig(x: Config.WindowPadding, y: Config.WindowPadding, configured: bool) ?Padding {
        if (!configured) return .default;
        for (std.enums.values(Padding)) |preset| {
            const texts = preset.values() orelse continue;
            const px = std.fmt.parseInt(u32, texts[0], 10) catch continue;
            const py = std.fmt.parseInt(u32, texts[1], 10) catch continue;
            if (x.top_left == px and x.bottom_right == px and y.top_left == py and y.bottom_right == py) return preset;
        }
        return null;
    }
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

    /// The Ghostty GX default (`defaults.ghostty`). "Reset to Default"
    /// does not write it but removes `font-size` (`Changes.reset`), so a
    /// size in the user configuration applies again.
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

/// The `font-family` values that make `new` the first font family and
/// keep the fallback families of `current` (the configured list) after it,
/// without repeating `new`. A UI that picks one family must keep the
/// others, because the settings file replaces the whole list of the lower
/// layers. An empty `new` gives no values, which removes the key so the
/// lower layers apply again. Only the returned slice is allocated.
pub fn fontFamilies(alloc: Allocator, new: []const u8, current: []const []const u8) Allocator.Error![]const []const u8 {
    const name = std.mem.trim(u8, new, &std.ascii.whitespace);
    if (name.len == 0) return &.{};
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(alloc);
    try result.append(alloc, name);
    for (current[@min(current.len, 1)..]) |family| {
        if (family.len == 0 or std.ascii.eqlIgnoreCase(family, name)) continue;
        try result.append(alloc, family);
    }
    return try result.toOwnedSlice(alloc);
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
/// theme when light and dark use the same one, otherwise null (see
/// `ThemePair`).
pub fn themeName(theme: ?Config.Theme) ?[]const u8 {
    const value = theme orelse return null;
    if (!std.mem.eql(u8, value.light, value.dark)) return null;
    return value.light;
}

/// The light and the dark theme of a `theme` value; both are the same
/// theme unless the configuration follows the system's light or dark
/// mode with two.
pub const ThemePair = struct {
    light: []const u8,
    dark: []const u8,

    pub fn fromConfig(theme: ?Config.Theme) ?ThemePair {
        const configured = theme orelse return null;
        return .{ .light = configured.light, .dark = configured.dark };
    }

    pub fn isPair(self: ThemePair) bool {
        return !std.mem.eql(u8, self.light, self.dark);
    }

    /// The `theme` value: the name of one theme, `light:<light>,dark:<dark>`
    /// for two. Names must pass `isThemeName`.
    pub fn value(self: ThemePair, alloc: Allocator) Allocator.Error![:0]u8 {
        if (!self.isPair()) return try alloc.dupeZ(u8, self.light);
        return try std.fmt.allocPrintSentinel(alloc, "light:{s},dark:{s}", .{ self.light, self.dark }, 0);
    }

    /// The command-line override that previews the pair.
    pub fn arg(self: ThemePair, alloc: Allocator) Allocator.Error![:0]u8 {
        const theme = try self.value(alloc);
        defer alloc.free(theme);
        return try themeArg(alloc, theme);
    }
};

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
/// directories is listed once; files that `isThemeName` rejects are left
/// out. A directory that is missing or cannot be read is skipped, with the
/// themes of the others still listed.
pub fn listThemes(alloc: Allocator, io: std.Io, dirs: []const []const u8) Allocator.Error!ThemeList {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var names: std.ArrayList([:0]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (dirs) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                log.warn("cannot list the themes in {s} err={}", .{ path, err });
                continue;
            },
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch |err| {
            log.warn("cannot list the themes in {s} err={}", .{ path, err });
            break;
        }) |entry| {
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

/// The launch profile that the `command` configuration starts, as an index
/// into `list`: the profile whose `profileCommand` is `command` (what the
/// settings UI writes), else the first profile that runs the same program
/// without arguments (`cmd.exe` is `C:\Windows\system32\cmd.exe`). Without
/// a `command`, the platform's default profile. Allocates temporary text
/// with `alloc` (an arena).
pub fn commandProfile(
    alloc: Allocator,
    list: []const profiles.Profile,
    command: ?Config.Command,
    platform: profiles.Platform,
) Allocator.Error!?usize {
    const configured = command orelse {
        const fallback = profiles.defaultProfile(list, platform) orelse return null;
        for (list, 0..) |*profile, i| {
            if (profile == fallback) return i;
        }
        return null;
    };

    const text = try commandText(alloc, configured);
    for (list, 0..) |profile, i| {
        if (std.mem.eql(u8, try profileCommand(alloc, profile, platform), text)) return i;
    }

    const program = programName(configured, platform);
    if (program.len == 0) return null;
    for (list, 0..) |profile, i| switch (profile.command) {
        .argv => |argv| if (argv.len == 1 and samePath(programName(.{ .direct = argv }, platform), program, platform)) return i,
        .command_line => {},
    };
    return null;
}

/// `command` in configuration syntax, the way `profileCommand` writes it.
fn commandText(alloc: Allocator, command: Config.Command) Allocator.Error![]const u8 {
    switch (command) {
        .shell => |line| return line,
        .direct => |args| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(alloc, "direct:");
            for (args, 0..) |arg, i| {
                if (i > 0) try out.append(alloc, ' ');
                try out.appendSlice(alloc, arg);
            }
            return out.items;
        },
    }
}

/// The file name of the program `command` runs (on Windows without
/// `.exe`).
fn programName(command: Config.Command, platform: profiles.Platform) []const u8 {
    const program = switch (command) {
        .direct => |args| if (args.len > 0) args[0] else "",
        .shell => |line| first: {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
                const end = std.mem.indexOfScalarPos(u8, trimmed, 1, trimmed[0]) orelse trimmed.len;
                break :first trimmed[1..end];
            }
            break :first trimmed[0 .. std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len];
        },
    };
    return switch (platform) {
        .linux => std.fs.path.basenamePosix(program),
        .windows => windows: {
            const name = std.fs.path.basenameWindows(program);
            break :windows if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - ".exe".len] else name;
        },
    };
}

fn samePath(a: []const u8, b: []const u8, platform: profiles.Platform) bool {
    return switch (platform) {
        .linux => std.mem.eql(u8, a, b),
        .windows => std.ascii.eqlIgnoreCase(a, b),
    };
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

    /// "Reset to Default": removes `key` from the overlay, so the user
    /// configuration applies again where it sets `key`, else the Ghostty GX
    /// default.
    pub fn reset(self: *Changes, key: []const u8) Allocator.Error!void {
        try self.delete(key);
    }

    /// Applies the changes to `overlay`.
    pub fn apply(self: *const Changes, overlay: *gui_settings.Overlay) (Allocator.Error || gui_settings.Error)!void {
        for (self.entries.items) |entry| try overlay.setAll(entry.key, entry.values);
    }

    /// Applies the changes to the overlay layer of `layers` the way
    /// `commit` writes them to the file, so a UI that previews from
    /// `layers` keeps them. Call it before `commit`, which clears the
    /// changes.
    pub fn applyToLayers(self: *const Changes, layers: *config_layers.Layers) Allocator.Error!void {
        for (self.entries.items) |entry| try layers.setOverlay(entry.key, entry.values);
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
        .{ CursorStyle, &cursor_style_choices, "cursor-style" },
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

test "bell features name the app runtimes that implement them" {
    for (bell_features) |feature| try testing.expect(feature.supports(.gtk));
    var windows: std.ArrayList([]const u8) = .empty;
    defer windows.deinit(testing.allocator);
    for (bell_features) |feature| {
        if (feature.supports(.win32)) try windows.append(testing.allocator, feature.field);
    }
    try testing.expectEqual(@as(usize, 5), windows.items.len);
    try testing.expectEqualStrings("system", windows.items[0]);
    try testing.expectEqualStrings("audio", windows.items[1]);
    try testing.expectEqualStrings("attention", windows.items[2]);
    try testing.expectEqualStrings("title", windows.items[3]);
    try testing.expectEqualStrings("border", windows.items[4]);

    const expected: ?Runtime = switch (build_config.app_runtime) {
        .win32 => .win32,
        .gtk => .gtk,
        else => null,
    };
    try testing.expectEqual(expected, Runtime.native);
}

test "switches write booleans their keys parse" {
    for ([_]Switch{ cursor_blink, focus_follows_mouse, ctrl_scroll_zoom }) |item| {
        for ([_]bool{ true, false }) |on| {
            var buf: [64]u8 = undefined;
            var cfg = try testConfig(&.{try std.fmt.bufPrint(&buf, "--{s}={s}", .{ item.key, Switch.value(on) })});
            defer cfg.deinit();
        }
    }
    var cfg = try testConfig(&.{ "--cursor-style-blink=false", "--focus-follows-mouse=true", "--gx-ctrl-scroll-zoom=false" });
    defer cfg.deinit();
    try testing.expectEqual(@as(?bool, false), cfg.@"cursor-style-blink");
    try testing.expect(cfg.@"focus-follows-mouse");
    try testing.expect(!cfg.@"gx-ctrl-scroll-zoom");

    var defaults = try testConfig(&.{});
    defer defaults.deinit();
    try testing.expect(defaults.@"gx-ctrl-scroll-zoom");
}

test "accent choices write values that parse back" {
    for (std.enums.values(Accent)) |choice| {
        var buf: [64]u8 = undefined;
        var cfg = try testConfig(&.{try std.fmt.bufPrint(&buf, "--{s}={s}", .{ Accent.key, choice.value() })});
        defer cfg.deinit();
        try testing.expectEqual(choice, Accent.fromConfig(cfg.@"gx-accent-color").?);
    }
    var cfg = try testConfig(&.{"--gx-accent-color=#e5a50a"});
    defer cfg.deinit();
    try testing.expectEqual(@as(?Accent, null), Accent.fromConfig(cfg.@"gx-accent-color"));
    // The default is the brand, the first choice.
    var plain = try testConfig(&.{});
    defer plain.deinit();
    try testing.expectEqual(Accent.brand, Accent.fromConfig(plain.@"gx-accent-color").?);
    try testing.expectEqual(Accent.brand, std.enums.values(Accent)[0]);
}

test "opacity choices write values that parse back" {
    for (std.enums.values(Opacity)) |choice| {
        const text = choice.value() orelse {
            try testing.expectEqual(Opacity.automatic, choice);
            continue;
        };
        var buf: [64]u8 = undefined;
        var cfg = try testConfig(&.{try std.fmt.bufPrint(&buf, "--background-opacity={s}", .{text})});
        defer cfg.deinit();
        try testing.expectEqual(@as(?Opacity, choice), Opacity.fromConfig(cfg.@"background-opacity", true));
    }
    try testing.expectEqualStrings("90%", Opacity.@"90".label());
    try testing.expectEqual(@as(?Opacity, .automatic), Opacity.fromConfig(0.3, false));
    try testing.expectEqual(@as(?Opacity, null), Opacity.fromConfig(0.85, true));
}

test "padding presets write values that parse back" {
    for (std.enums.values(Padding)) |preset| {
        const texts = preset.values() orelse {
            try testing.expectEqual(Padding.default, preset);
            continue;
        };
        var bufs: [2][64]u8 = undefined;
        var cfg = try testConfig(&.{
            try std.fmt.bufPrint(&bufs[0], "--{s}={s}", .{ Padding.keys[0], texts[0] }),
            try std.fmt.bufPrint(&bufs[1], "--{s}={s}", .{ Padding.keys[1], texts[1] }),
        });
        defer cfg.deinit();
        try testing.expectEqual(@as(?Padding, preset), Padding.fromConfig(cfg.@"window-padding-x", cfg.@"window-padding-y", true));
    }
    try testing.expectEqual(@as(?Padding, .default), Padding.fromConfig(.{}, .{}, false));
    try testing.expectEqual(@as(?Padding, null), Padding.fromConfig(.{ .top_left = 9, .bottom_right = 2 }, .{ .top_left = 4, .bottom_right = 4 }, true));
}

test "fontFamilies keeps the fallback families" {
    const alloc = testing.allocator;
    const cases = [_]struct { []const u8, []const []const u8, []const []const u8 }{
        .{ "Cascadia Mono", &.{"JetBrainsMono Nerd Font"}, &.{"Cascadia Mono"} },
        .{ "Cascadia Code", &.{ "Iosevka", "Sarasa Mono SC", "Symbols" }, &.{ "Cascadia Code", "Sarasa Mono SC", "Symbols" } },
        .{ " sarasa mono sc ", &.{ "Iosevka", "Sarasa Mono SC" }, &.{"sarasa mono sc"} },
        .{ "Iosevka", &.{}, &.{"Iosevka"} },
        .{ "", &.{ "Iosevka", "Sarasa Mono SC" }, &.{} },
        .{ "  ", &.{"Iosevka"}, &.{} },
    };
    for (cases) |case| {
        const families = try fontFamilies(alloc, case[0], case[1]);
        defer alloc.free(families);
        try testing.expectEqual(case[2].len, families.len);
        for (case[2], families) |expected, actual| try testing.expectEqualStrings(expected, actual);
    }
}

test "errorReason explains common errors and names the others" {
    try testing.expectEqualStrings("Permission denied.", errorReason(error.AccessDenied));
    try testing.expectEqualStrings("The disk is full.", errorReason(error.NoSpaceLeft));
    try testing.expectEqualStrings("SomethingRare", errorReason(error.SomethingRare));
}

test "ThemePair writes one theme or a light and dark pair" {
    const alloc = testing.allocator;
    try testing.expectEqual(@as(?ThemePair, null), ThemePair.fromConfig(null));
    for ([_]ThemePair{
        .{ .light = "GX Mocha", .dark = "GX Mocha" },
        .{ .light = "Builtin Solarized Light", .dark = "Builtin Solarized Dark" },
    }) |pair| {
        const arg = try pair.arg(alloc);
        defer alloc.free(arg);
        var cfg = try testConfig(&.{arg});
        defer cfg.deinit();
        const parsed = ThemePair.fromConfig(cfg.theme).?;
        try testing.expectEqualStrings(pair.light, parsed.light);
        try testing.expectEqualStrings(pair.dark, parsed.dark);
        try testing.expectEqual(pair.isPair(), parsed.isPair());
        try testing.expectEqual(pair.isPair(), themeName(cfg.theme) == null);
    }
}

test "pages and provenance have labels" {
    try testing.expectEqualStrings(msg.font, pageLabel(.font));
    try testing.expectEqual(@as(usize, 6), std.enums.values(Page).len);
    try testing.expectEqualStrings(msg.from_nothing, provenanceLabel(null));
    try testing.expectEqualStrings(msg.from_cli, provenanceLabel(.cli));
}

test "Changes reach a layers snapshot like the settings file" {
    var layers: config_layers.Layers = .{ .arena = .init(testing.allocator) };
    defer layers.deinit();
    var changes: Changes = .init(testing.allocator);
    defer changes.deinit();

    try changes.set("font-size", "15");
    try changes.setAll("font-family", &.{ "A", "B" });
    try changes.applyToLayers(&layers);
    try testing.expect(layers.sets(.overlay, "font-size"));
    var cfg = try layers.build(testing.allocator, &.{});
    defer cfg.deinit();
    try testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try testing.expectEqual(@as(usize, 2), cfg.@"font-family".list.items.len);

    changes.clear();
    try changes.reset("font-size");
    try changes.applyToLayers(&layers);
    try testing.expect(!layers.sets(.overlay, "font-size"));
    try testing.expectEqual(@as(?config_layers.Layer, null), layers.provenance("font-size"));
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

test "listThemes skips directories it cannot read" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "resources");
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/b", .data = "background = #000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const resources = try std.fs.path.join(testing.allocator, &.{ root, "resources" });
    defer testing.allocator.free(resources);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "file" });
    defer testing.allocator.free(file);
    const long = try std.fs.path.join(testing.allocator, &.{ root, "x" ** 300 });
    defer testing.allocator.free(long);

    var list = try listThemes(testing.allocator, io, &.{ long, file, resources });
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.names.len);
    try testing.expectEqualStrings("b", list.names[0]);
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

test "commandProfile finds the profile a command starts" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const windows = [_]profiles.Profile{
        .{ .id = "gx-zsh", .name = "GX Zsh", .command = .{ .argv = &.{"C:\\GX\\bin\\gx-zsh.exe"} }, .kind = .gx_zsh },
        .{ .id = "pwsh", .name = "PowerShell 7", .command = .{ .argv = &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"} }, .kind = .pwsh },
        .{ .id = "cmd", .name = "Command Prompt", .command = .{ .argv = &.{"C:\\Windows\\system32\\cmd.exe"} }, .kind = .cmd },
        .{ .id = "git-bash", .name = "Git Bash", .command = .{ .argv = &.{ "C:\\Git\\bin\\bash.exe", "-i", "-l" } }, .kind = .git_bash },
        .{ .id = "custom:Py", .name = "Py", .command = .{ .command_line = "python -i" }, .kind = .custom },
    };
    const cases = [_]struct { ?Config.Command, ?usize }{
        // What the settings UI writes.
        .{ .{ .direct = &.{"C:\\GX\\bin\\gx-zsh.exe"} }, 0 },
        .{ .{ .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"" }, 1 },
        .{ .{ .direct = &.{ "C:\\Git\\bin\\bash.exe", "-i", "-l" } }, 3 },
        .{ .{ .shell = "python -i" }, 4 },
        // The same program spelled differently.
        .{ .{ .shell = "cmd.exe" }, 2 },
        .{ .{ .shell = "PWSH -NoLogo" }, 1 },
        .{ .{ .shell = "bash" }, null },
        .{ .{ .shell = "nvim" }, null },
        // Without a command, the default profile.
        .{ null, 0 },
    };
    for (cases) |case| {
        try testing.expectEqual(case[1], try commandProfile(alloc, &windows, case[0], .windows));
    }

    const linux = [_]profiles.Profile{
        .{ .id = "login-shell", .name = "Login Shell", .command = .{ .argv = &.{"/bin/bash"} }, .kind = .login_shell },
        .{ .id = "zsh", .name = "Zsh", .command = .{ .argv = &.{"/usr/bin/zsh"} }, .kind = .zsh },
    };
    try testing.expectEqual(@as(?usize, 0), try commandProfile(alloc, &linux, .{ .shell = "/bin/bash" }, .linux));
    try testing.expectEqual(@as(?usize, 1), try commandProfile(alloc, &linux, .{ .direct = &.{"/usr/bin/zsh"} }, .linux));
    try testing.expectEqual(@as(?usize, null), try commandProfile(alloc, &linux, .{ .shell = "ZSH" }, .linux));
    try testing.expectEqual(@as(?usize, 0), try commandProfile(alloc, &linux, null, .linux));
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
    for (cursor_style_choices) |choice| check(choice.label, &missing);
    for (bell_features) |feature| check(feature.label, &missing);
    for (std.enums.values(Material)) |material| check(material.label(), &missing);
    for (std.enums.values(Padding)) |preset| check(preset.label(), &missing);
    for (std.enums.values(Accent)) |accent| check(accent.label(), &missing);
    check(Accent.custom_label, &missing);
    check(Opacity.automatic.label(), &missing);
    for ([_]anyerror{
        error.AccessDenied,
        error.FileNotFound,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.PathAlreadyExists,
        error.SharingViolation,
        error.InvalidSetting,
        error.OutOfMemory,
        error.InvalidPath,
        error.FileTooBig,
        error.InputOutput,
        error.NetworkNotFound,
        error.NoHomeDir,
    }) |err| check(errorReason(err), &missing);
    try testing.expectEqual(@as(usize, 0), missing);
}

/// The msgid of the line under the accent color row, which says what
/// `accent` does.
pub fn accentHint(accent: Accent) [:0]const u8 {
    return switch (accent) {
        .brand => "Stays Ghostty GX purple whatever the theme.",
        .theme => "Takes the accent color of the current theme.",
    };
}

test "accent hints are translated" {
    for (std.enums.values(Accent)) |accent| {
        try testing.expect(i18n.lookup(.zh_CN, accentHint(accent)) != null);
    }
}

/// The half of a light and dark theme pair (`ThemePair`) a settings UI
/// edits: a theme list chooses the theme of that half and keeps the other.
pub const ThemeHalf = enum {
    light,
    dark,

    /// The msgid of the label.
    pub fn label(self: ThemeHalf) [:0]const u8 {
        return switch (self) {
            .light => msg.light_theme,
            .dark => msg.dark_theme,
        };
    }

    /// The half the system's light or dark mode shows now.
    pub fn ofSystem(dark: bool) ThemeHalf {
        return if (dark) .dark else .light;
    }

    /// The theme `pair` uses for this half.
    pub fn name(self: ThemeHalf, pair: ThemePair) []const u8 {
        return switch (self) {
            .light => pair.light,
            .dark => pair.dark,
        };
    }

    /// `pair` with this half set to `theme`; the other half stays. When
    /// both halves end up the same, the pair is one theme again.
    pub fn replace(self: ThemeHalf, pair: ThemePair, theme: []const u8) ThemePair {
        return switch (self) {
            .light => .{ .light = theme, .dark = pair.dark },
            .dark => .{ .light = pair.light, .dark = theme },
        };
    }
};

/// The msgid of the summary of a light and dark pair, with the
/// `{light}` and `{dark}` placeholders.
pub const theme_pair_summary = "Light: {light} · Dark: {dark}";

/// The msgid of the title of the choice between the halves of a pair.
pub const theme_half_title = "Theme to Edit";

test "ThemeHalf replaces one half of a pair and keeps the other" {
    const alloc = testing.allocator;
    const pair: ThemePair = .{ .light = "GX Latte", .dark = "GX Mocha" };
    try testing.expectEqualStrings("GX Latte", ThemeHalf.light.name(pair));
    try testing.expectEqualStrings("GX Mocha", ThemeHalf.dark.name(pair));
    try testing.expectEqual(ThemeHalf.dark, ThemeHalf.ofSystem(true));
    try testing.expectEqual(ThemeHalf.light, ThemeHalf.ofSystem(false));

    const cases = [_]struct { ThemeHalf, []const u8, []const u8 }{
        .{ .light, "Builtin Solarized Light", "light:Builtin Solarized Light,dark:GX Mocha" },
        .{ .dark, "Dracula", "light:GX Latte,dark:Dracula" },
        // Choosing the other half's theme leaves one theme.
        .{ .light, "GX Mocha", "GX Mocha" },
        .{ .dark, "GX Latte", "GX Latte" },
    };
    for (cases) |case| {
        const replaced = case[0].replace(pair, case[1]);
        const value = try replaced.value(alloc);
        defer alloc.free(value);
        try testing.expectEqualStrings(case[2], value);

        // The value parses back to the pair, so a preview or a save keeps
        // the half that was not edited.
        const arg = try replaced.arg(alloc);
        defer alloc.free(arg);
        var cfg = try testConfig(&.{arg});
        defer cfg.deinit();
        const parsed = ThemePair.fromConfig(cfg.theme).?;
        try testing.expectEqualStrings(replaced.light, parsed.light);
        try testing.expectEqualStrings(replaced.dark, parsed.dark);
        try testing.expectEqualStrings(case[1], case[0].name(parsed));
    }
}

test "the default theme is a light and dark pair" {
    const line = "theme = light:GX Latte,dark:GX Mocha";
    try testing.expect(std.mem.indexOf(u8, config_layers.defaults, line) != null);
    var cfg = try testConfig(&.{"--theme=light:GX Latte,dark:GX Mocha"});
    defer cfg.deinit();
    const pair = ThemePair.fromConfig(cfg.theme) orelse return error.TestUnexpectedResult;
    try testing.expect(pair.isPair());
    try testing.expectEqualStrings("GX Latte", ThemeHalf.light.name(pair));
    try testing.expectEqualStrings("GX Mocha", ThemeHalf.dark.name(pair));
}

test "theme half strings are translated" {
    for (std.enums.values(ThemeHalf)) |half| try testing.expect(i18n.lookup(.zh_CN, half.label()) != null);
    try testing.expect(i18n.lookup(.zh_CN, theme_pair_summary) != null);
    try testing.expect(i18n.lookup(.zh_CN, theme_half_title) != null);
}
