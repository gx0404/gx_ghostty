//! The Ghostty GX settings overlay. Opened by `gx:settings`, the main
//! menu's Settings… item and `open_config` when `gx-open-config-ui =
//! settings` (the default); all of them call `show`.
//!
//! A modal panel centered over the terminal window: an activating
//! `ui/Popup` drawn with Direct2D, above a dimmed backdrop
//! (`settings/Scrim.zig`) that closes it when clicked. A section list on
//! the left (Language, Appearance, Font, Interaction, Shell, About) and
//! the rows of the selected section on the right, driven by keyboard and
//! mouse:
//!
//!   - Tab / Shift+Tab (or Ctrl+PgDn / Ctrl+PgUp) switch sections, Up/Down
//!     move between rows and through lists, Left/Right change a choice,
//!     a switch or the font size, Enter and Space activate, Esc closes.
//!   - Lists (themes, font families) have an IME-capable filter box that
//!     takes the typing while the list is focused (fuzzy matching,
//!     `settings/fuzzy.zig`).
//!   - Clicks in the first moments after opening are ignored, so the click
//!     that opened the overlay cannot also press something in it.
//!
//! Every change is recorded in a `gx.settings_map.Changes` and written to
//! the settings overlay `gui-settings.ghostty` (never to the user's
//! configuration file) after a short pause, then the configuration is
//! reloaded from disk like `reload_config`. Moving through the theme list
//! previews themes: the configuration is loaded with an in-memory
//! `--theme` override (and no reload notification) and applied without
//! writing anything; Enter, Apply or a double click keeps the theme, and
//! closing the overlay otherwise reverts the preview. Errors show in the
//! status line. The text follows the UI language, so the overlay redraws
//! in the new language as soon as a `language` change is applied.
//!
//! There is one overlay per process, shown over one window at a time.
//! `Window` calls `onWindowDestroyed` when a window goes away.
const Settings = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const file_load = @import("../../../config/file_load.zig");
const themepkg = @import("../../../config/theme.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");
const Scrim = @import("settings/Scrim.zig");
const draw = @import("settings/draw.zig");
const fuzzy = @import("settings/fuzzy.zig");
const swatch = @import("settings/swatch.zig");
const system = @import("settings/system.zig");

const Config = configpkg.Config;
const i18n = gx.i18n;
const settings_map = gx.settings_map;
const msg = settings_map.msg;
const WindowMaterial = gx.config_types.WindowMaterial;

const log = std.log.scoped(.win32_settings);

// Sizes in DIPs.
const sidebar_width: f32 = 200;
const header_height: f32 = 64;
const footer_height: f32 = 44;
const content_pad: f32 = 24;
const row_gap: f32 = 6;
const card_height: f32 = 44;
const card_height_detail: f32 = 58;
const item_height: f32 = 30;
const field_height: f32 = style.metrics.input_height;
const min_list_height: f32 = 150;
const min_width: f32 = 640;
const max_width: f32 = 920;
const min_height: f32 = 460;
const max_height: f32 = 680;

/// How long changes are collected before they are saved.
const save_delay_ms = 300;
/// The least time between two theme previews while moving through the list.
const preview_interval_ms = 120;
/// Clicks this soon after opening are ignored.
const click_guard_ms = 400;
/// How often a running herdr is checked, and when it is given up.
const herdr_poll_ms = 200;
const herdr_timeout_ms = 30_000;
/// The darkness of the backdrop (0-255).
const scrim_alpha: u8 = 90;

const max_rows = 64;
const max_hits = 160;

/// The overlay, created by the first `show`.
var instance: ?*Settings = null;

alloc: Allocator,
app: *App,
window: *Window,

popup: Popup = .{},
scrim: Scrim = .{},

/// Owns the data loaded when the overlay opens (paths, shells, theme
/// directories); reset when it closes.
arena: ArenaAllocator,
/// Owns the strings of the rows built since the last paint.
scratch: ArenaAllocator,

open: bool = false,
opened_ms: u64 = 0,

section: Section = .language,
/// The focused row of the section (an index into `buildRows`).
focus: usize = 0,
/// Scroll the focused row into view at the next paint.
reveal_focus: bool = false,
body_scroll: f32 = 0,
hover: ?Target = null,

/// The values shown, starting from the configuration when the overlay
/// opens and following every change made here.
values: Values = undefined,
font_family: []const u8 = "",
notifications: Config.AppNotifications = .{},
/// Whether the configuration is loaded with the Ghostty GX layers; theme
/// previews need them (`GHOSTTY_GX_DEFAULTS=0` turns them off).
layered: bool = true,
build: u32 = 0,

themes: ?settings_map.ThemeList = null,
theme_dirs: []const []const u8 = &.{},
theme_list: List = .{},
theme_query: std.ArrayList(u8) = .empty,
/// The theme in the configuration (an index into `themes.names`).
saved_theme: ?u32 = null,
/// The theme to preview and the one currently applied as a preview.
preview_theme: ?u32 = null,
applied_preview: ?u32 = null,
last_preview_ms: u64 = 0,
swatches: swatch.Cache = .{},

fonts: ?system.FontFamilies = null,
font_list: List = .{},
font_query: std.ArrayList(u8) = .empty,

shells: []const Shell = &.{},
shell_selected: usize = 0,
herdr_exe: ?[]const u8 = null,
herdr_run: ?system.HerdrRun = null,

config_path: []const u8 = "",
overlay_path: []const u8 = "",

/// The list whose filter box receives the typing, if any.
text_field: ?Field = null,

changes: settings_map.Changes,
timers: std.EnumSet(Timer) = .initEmpty(),

status_kind: StatusKind = .none,
status_buf: [512]u8 = undefined,
status_len: usize = 0,

/// Hit-test rectangles of the last paint, later ones on top.
hits: [max_hits]Hit = undefined,
hit_count: usize = 0,
/// Where the last paint put the list of the section, for the wheel.
list_area: ?d2d.Rect = null,

// -----------------------------------------------------------------------
// Opening and closing
// -----------------------------------------------------------------------

/// Show the settings for `window`. Returns false if nothing was shown.
pub fn show(window: *Window) bool {
    if (instance) |self| {
        if (self.window == window) {
            if (self.open) {
                if (self.popup.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
                return true;
            }
            return self.openOverlay();
        }
        self.destroy();
    }

    const alloc = window.app.core_app.alloc;
    const self = alloc.create(Settings) catch |err| {
        log.err("cannot create the settings overlay err={}", .{err});
        return false;
    };
    self.* = .{
        .alloc = alloc,
        .app = window.app,
        .window = window,
        .arena = .init(alloc),
        .scratch = .init(alloc),
        .changes = .init(alloc),
    };
    instance = self;
    return self.openOverlay();
}

/// Like `show`, then switch to `section` (the command palette's
/// "Settings: <section>" entries).
pub fn showSection(window: *Window, section: Section) bool {
    if (!show(window)) return false;
    const self = instance orelse return false;
    if (self.section != section) self.enterSection(section);
    return true;
}

/// `window` is going away: save pending changes, end a theme preview and
/// destroy the overlay if it belongs to that window.
pub fn onWindowDestroyed(window: *Window) void {
    const self = instance orelse return;
    if (self.window != window) return;
    self.destroy();
}

fn destroy(self: *Settings) void {
    self.finish(.owner);
    self.stopTimer(.save);
    self.stopTimer(.herdr);
    if (self.herdr_run) |*run| run.deinit();
    self.herdr_run = null;
    if (self.popup.hwnd) |hwnd| {
        // Windows destroys owned windows with their owner.
        if (!Scrim.isOwnWindow(hwnd, &self.popup)) self.popup.hwnd = null;
    }
    self.popup.destroy();
    self.scrim.destroy();
    self.releaseData();
    self.theme_query.deinit(self.alloc);
    self.font_query.deinit(self.alloc);
    self.theme_list.deinit(self.alloc);
    self.font_list.deinit(self.alloc);
    self.changes.deinit();
    self.arena.deinit();
    self.scratch.deinit();
    if (instance == self) instance = null;
    self.alloc.destroy(self);
}

fn openOverlay(self: *Settings) bool {
    const owner = self.window.hwnd orelse return false;
    if (self.window.closing) return false;
    const factory = self.app.uiFactory() orelse return false;
    const t = self.tokens();

    if (self.popup.hwnd == null) {
        self.popup.create(self.app.hinstance, owner, factory, .{
            .activate = true,
            .dismiss_on_escape = true,
            .dismiss_on_outside_click = true,
            .corners = .round,
            .shadow = true,
            .text_input = true,
            .border_color = t.border,
            .dark = t.dark,
        }, .{
            .ctx = self,
            .paint = paint,
            .key = onKey,
            .mouse = onMouse,
            .text_changed = onTextChanged,
            .dismissed = onDismissed,
            .dpi_changed = onDpiChanged,
        }) catch |err| {
            log.err("cannot create the settings popup err={}", .{err});
            return false;
        };
    } else {
        self.popup.setBorderColor(t.border);
    }
    if (self.scrim.hwnd == null) {
        self.scrim.create(self.app.hinstance, owner, scrim_alpha, self, onScrimClick) catch |err| {
            log.warn("cannot create the settings backdrop err={}", .{err});
        };
    }

    self.loadData();
    self.clearStatus();
    self.hover = null;
    self.enterSection(self.section);

    self.scrim.show(Scrim.visibleBounds(owner));
    self.popup.show(self.popupRect(owner));
    self.opened_ms = system.nowMs();
    self.open = true;
    return true;
}

/// How the overlay closes.
const Close = enum {
    /// Escape, the close button or a click on the backdrop: give the
    /// keyboard back to the terminal.
    user,
    /// Another window took the focus; leave it there.
    deactivated,
    /// The window or the overlay goes away.
    owner,
};

/// Saves pending changes and ends a theme preview.
fn finish(self: *Settings, how: Close) void {
    if (!self.open) return;
    self.open = false;
    self.stopTimer(.preview);
    const previewed = self.applied_preview != null;
    self.preview_theme = null;
    self.applied_preview = null;
    if (!self.changes.isEmpty()) {
        // Saving reloads the saved configuration, which ends the preview.
        self.saveNow();
    } else if (previewed) {
        _ = self.reloadFromDisk();
    }
    self.scrim.hide();
    self.popup.hide();
    self.text_field = null;
    self.popup.input.clear();
    self.releaseData();
    if (how == .user) self.window.focusActiveSurface();
}

fn popupRect(self: *Settings, owner: w32.HWND) w32.RECT {
    _ = self;
    const bounds = Scrim.visibleBounds(owner);
    const dpi = w32.GetDpiForWindow(owner);
    const scale: f32 = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0;
    const bounds_w = bounds.right - bounds.left;
    const bounds_h = bounds.bottom - bounds.top;
    const w_dip = std.math.clamp(style.dip(bounds_w, scale) - 80, min_width, max_width);
    const h_dip = std.math.clamp(style.dip(bounds_h, scale) - 80, min_height, max_height);
    const w = style.px(w_dip, scale);
    const h = style.px(h_dip, scale);
    var x = bounds.left + @divTrunc(bounds_w - w, 2);
    var y = bounds.top + @divTrunc(bounds_h - h, 2);

    // Stay on the monitor of the window.
    var info: w32.MONITORINFO = undefined;
    info.cbSize = @sizeOf(w32.MONITORINFO);
    const monitor = w32.MonitorFromWindow(owner, w32.MONITOR_DEFAULTTONEAREST);
    if (w32.GetMonitorInfoW(monitor, &info) != 0) {
        const work = info.rcWork;
        x = std.math.clamp(x, work.left, @max(work.left, work.right - w));
        y = std.math.clamp(y, work.top, @max(work.top, work.bottom - h));
    }
    return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
}

fn tokens(self: *const Settings) style.Tokens {
    return style.Tokens.fromConfig(&self.app.config);
}

fn invalidate(self: *Settings) void {
    self.popup.invalidate();
}

// -----------------------------------------------------------------------
// Data
// -----------------------------------------------------------------------

/// The values the rows show.
const Values = struct {
    language: i18n.Language,
    material: WindowMaterial,
    font_size: f32,
    right_click: Config.RightClickAction,
    scrollbar: bool,
    close_confirmation: Config.ConfirmCloseSurface,
    bell: Config.BellFeatures,

    fn fromConfig(config: *const Config) Values {
        return .{
            .language = i18n.resolve(config.language),
            .material = config.@"gx-window-material",
            .font_size = settings_map.FontSize.normalize(config.@"font-size"),
            .right_click = config.@"right-click-action",
            .scrollbar = config.scrollbar == .system,
            .close_confirmation = config.@"confirm-close-surface",
            .bell = config.@"bell-features",
        };
    }
};

/// A choice of the Shell section.
const Shell = struct {
    /// The `command` value, or null to remove `command` from the overlay.
    command: ?[:0]const u8,
    /// The name: an i18n msgid unless `kind` is `.custom_profile`.
    name: [:0]const u8,
    /// The `{name}` placeholder value of `name` (WSL distributions).
    name_arg: ?[:0]const u8 = null,
    kind: Kind,
    /// The GX Zsh executable, when the choice is GX Zsh.
    gx_zsh: ?[:0]const u8 = null,

    const Kind = enum { system_default, profile, custom_profile, custom_command };
};

fn loadData(self: *Settings) void {
    self.releaseData();
    const config = &self.app.config;
    const arena = self.arena.allocator();

    self.values = .fromConfig(config);
    self.notifications = config.@"app-notifications";
    self.layered = gx.config_layers.enabled(self.alloc);
    self.build = system.windowsBuild();
    const families = config.@"font-family".list.items;
    self.font_family = if (families.len > 0) arena.dupe(u8, families[0]) catch "" else "";

    self.config_path = file_load.preferredDefaultFilePath(arena) catch |err| path: {
        log.warn("cannot locate the configuration file err={}", .{err});
        break :path "";
    };
    self.overlay_path = gx.config_layers.overlayPath(arena) catch |err| path: {
        log.warn("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
        break :path "";
    };

    self.loadThemes(config);
    self.loadShells();
}

fn releaseData(self: *Settings) void {
    if (self.themes) |*list| list.deinit();
    self.themes = null;
    if (self.fonts) |*list| list.deinit();
    self.fonts = null;
    self.swatches.deinit(self.alloc);
    self.theme_list.clear();
    self.font_list.clear();
    self.theme_query.clearRetainingCapacity();
    self.font_query.clearRetainingCapacity();
    self.saved_theme = null;
    self.shells = &.{};
    self.theme_dirs = &.{};
    self.herdr_exe = null;
    self.font_family = "";
    self.config_path = "";
    self.overlay_path = "";
    _ = self.arena.reset(.retain_capacity);
    _ = self.scratch.reset(.retain_capacity);
}

fn loadThemes(self: *Settings, config: *const Config) void {
    const arena = self.arena.allocator();
    var dirs: std.ArrayList([]const u8) = .empty;
    var it: themepkg.LocationIterator = .{ .arena_alloc = arena };
    while (it.next() catch null) |location| {
        dirs.append(arena, location.dir) catch break;
    }
    self.theme_dirs = dirs.items;
    self.themes = settings_map.listThemes(self.alloc, global.io(), dirs.items) catch |err| list: {
        log.warn("cannot list the themes err={}", .{err});
        break :list null;
    };
    if (settings_map.themeName(config.theme)) |name| {
        if (self.themes) |*list| {
            if (list.indexOf(name)) |index| self.saved_theme = @intCast(index);
        }
    }
    self.refilter(.themes);
    if (self.saved_theme) |saved| self.theme_list.select(saved);
}

fn loadShells(self: *Settings) void {
    const arena = self.arena.allocator();
    const overlay_command = self.overlayValue(arena, "command");

    var shells: std.ArrayList(Shell) = .empty;
    shells.append(arena, .{ .command = null, .name = msg.system_default, .kind = .system_default }) catch return;
    var selected: ?usize = if (overlay_command == null) 0 else null;

    if (self.app.launchProfiles()) |list_| {
        var list = list_;
        defer list.deinit();
        for (list.profiles) |profile| {
            const command = settings_map.profileCommand(arena, profile, .native) catch continue;
            const exe: ?[:0]const u8 = switch (profile.command) {
                .argv => |argv| if (argv.len > 0) arena.dupeZ(u8, argv[0]) catch null else null,
                .command_line => null,
            };
            if (profile.kind == .herdr) self.herdr_exe = exe;
            shells.append(arena, .{
                .command = command,
                .name = arena.dupeZ(u8, profile.name) catch continue,
                .name_arg = if (profile.name_arg) |arg| arena.dupeZ(u8, arg) catch null else null,
                .kind = if (profile.kind == .custom) .custom_profile else .profile,
                .gx_zsh = if (profile.kind == .gx_zsh) exe else null,
            }) catch break;
            if (selected == null and std.mem.eql(u8, overlay_command.?, command)) selected = shells.items.len - 1;
        }
    } else |err| {
        log.warn("cannot detect the shells err={}", .{err});
    }

    if (selected == null) {
        // A command the settings did not write.
        const command = arena.dupeZ(u8, overlay_command.?) catch "";
        shells.append(arena, .{ .command = command, .name = command, .kind = .custom_command }) catch {};
        selected = shells.items.len - 1;
    }
    self.shells = shells.items;
    self.shell_selected = selected orelse 0;
}

/// Reads `key` from the overlay file.
fn overlayValue(self: *Settings, alloc: Allocator, key: []const u8) ?[]const u8 {
    if (self.overlay_path.len == 0) return null;
    var overlay = gx.gui_settings.Overlay.load(self.alloc, global.io(), self.overlay_path) catch |err| {
        log.warn("cannot read {s} err={}", .{ self.overlay_path, err });
        return null;
    };
    defer overlay.deinit();
    const value = overlay.get(key) orelse return null;
    return alloc.dupe(u8, value) catch null;
}

fn ensureFonts(self: *Settings) void {
    if (self.fonts != null) return;
    const extra: []const []const u8 = if (self.font_family.len > 0) &.{self.font_family} else &.{};
    self.fonts = system.terminalFontFamilies(self.alloc, extra) catch |err| fonts: {
        log.warn("cannot list the font families err={}", .{err});
        break :fonts null;
    };
    self.refilter(.fonts);
    if (self.fonts) |fonts| {
        for (fonts.names, 0..) |name, i| {
            if (std.mem.eql(u8, name, self.font_family)) self.font_list.select(@intCast(i));
        }
    }
}

// -----------------------------------------------------------------------
// Lists and their filter boxes
// -----------------------------------------------------------------------

const Field = enum { themes, fonts };

/// A filtered list with a cursor.
const List = struct {
    /// Indices into the names, best match first.
    matches: std.ArrayList(u32) = .empty,
    cursor: usize = 0,
    top: usize = 0,
    /// Rows that fit, from the last paint.
    visible: usize = 8,
    /// Scroll the cursor into view at the next paint.
    reveal: bool = true,

    fn deinit(self: *List, alloc: Allocator) void {
        self.matches.deinit(alloc);
        self.* = .{};
    }

    fn clear(self: *List) void {
        self.matches.clearRetainingCapacity();
        self.cursor = 0;
        self.top = 0;
        self.reveal = true;
    }

    /// The name index under the cursor.
    fn current(self: *const List) ?u32 {
        if (self.cursor >= self.matches.items.len) return null;
        return self.matches.items[self.cursor];
    }

    /// Puts the cursor on the name index `index`, if it is listed.
    fn select(self: *List, index: u32) void {
        for (self.matches.items, 0..) |match, i| {
            if (match == index) {
                self.cursor = i;
                self.reveal = true;
                return;
            }
        }
    }

    /// Moves the cursor by `delta`; false if it was already at that end.
    fn move(self: *List, delta: isize) bool {
        const len = self.matches.items.len;
        if (len == 0) return false;
        const current_pos: isize = @intCast(self.cursor);
        const target = std.math.clamp(current_pos + delta, 0, @as(isize, @intCast(len - 1)));
        if (target == current_pos) return false;
        self.cursor = @intCast(target);
        self.reveal = true;
        return true;
    }
};

fn listOf(self: *Settings, field: Field) *List {
    return switch (field) {
        .themes => &self.theme_list,
        .fonts => &self.font_list,
    };
}

fn queryOf(self: *Settings, field: Field) *std.ArrayList(u8) {
    return switch (field) {
        .themes => &self.theme_query,
        .fonts => &self.font_query,
    };
}

fn namesOf(self: *Settings, field: Field) []const [:0]const u8 {
    return switch (field) {
        .themes => if (self.themes) |list| list.names else &.{},
        .fonts => if (self.fonts) |list| list.names else &.{},
    };
}

/// Matches the names of `field` against its filter text.
fn refilter(self: *Settings, field: Field) void {
    const list = self.listOf(field);
    fuzzy.filter(self.alloc, self.namesOf(field), self.queryOf(field).items, &list.matches) catch |err| {
        log.warn("cannot filter the list err={}", .{err});
        list.matches.clearRetainingCapacity();
    };
    list.cursor = 0;
    list.top = 0;
    list.reveal = true;
}

/// Gives the filter box of the focused list, if any, the text input.
fn syncTextField(self: *Settings) void {
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    const want: ?Field = if (self.focus < rows.len) switch (rows[self.focus].action) {
        .themes => .themes,
        .font_family => .fonts,
        else => null,
    } else null;
    if (want == self.text_field) return;
    self.text_field = want;
    if (want) |field| {
        self.popup.input.setText(self.alloc, self.queryOf(field).items) catch {};
    } else {
        self.popup.input.clear();
    }
}

fn onTextChanged(ctx: *anyopaque, popup: *Popup) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    const field = self.text_field orelse {
        // Typing outside a filter box goes nowhere.
        popup.input.clear();
        return;
    };
    const text = popup.input.text(self.alloc) catch return;
    defer self.alloc.free(text);
    const query = self.queryOf(field);
    if (std.mem.eql(u8, query.items, text)) return;
    query.clearRetainingCapacity();
    query.appendSlice(self.alloc, text) catch return;
    self.refilter(field);
    if (field == .themes) self.schedulePreview();
    self.invalidate();
}

// -----------------------------------------------------------------------
// Sections and rows
// -----------------------------------------------------------------------

/// The sections of the overlay, in sidebar order.
pub const Section = enum {
    language,
    appearance,
    font,
    interaction,
    shell,
    about,

    fn title(self: Section) [:0]const u8 {
        return switch (self) {
            .language => i18n.tr(msg.language),
            .appearance => i18n.tr(msg.appearance),
            .font => i18n.tr(msg.font),
            .interaction => i18n.tr(msg.interaction),
            .shell => i18n.tr(msg.shell),
            .about => i18n.tr(msg.about),
        };
    }

    fn icon(self: Section) u21 {
        return switch (self) {
            .language => draw.icons.globe,
            .appearance => draw.icons.color,
            .font => draw.icons.font,
            .interaction => draw.icons.touch,
            .shell => draw.icons.command_prompt,
            .about => draw.icons.info,
        };
    }
};

const RowKind = enum {
    /// A group title with an optional description and buttons.
    group,
    /// A paragraph of secondary text.
    note,
    radio,
    toggle,
    /// A segmented choice (chips).
    choice,
    /// The font size with -/+ and reset.
    stepper,
    /// A filter box with a list below it.
    list,
    /// A title with a value (paths, the version).
    info,
    button,

    fn focusable(self: RowKind) bool {
        return switch (self) {
            .group, .note, .info => false,
            else => true,
        };
    }
};

const Action = union(enum) {
    none,
    language: i18n.Language,
    material,
    themes,
    font_size,
    font_family,
    right_click,
    scrollbar,
    close_confirmation,
    bell: u8,
    shell: u16,
    open_config_file,
    open_config_dir,
};

const GroupButton = enum { apply_theme, apply_font, reset_font };

const Row = struct {
    kind: RowKind,
    action: Action = .none,
    title: []const u8 = "",
    detail: []const u8 = "",
    on: bool = false,
    choices: []const []const u8 = &.{},
    choice: usize = 0,
    /// Bit `i` set: choice `i` is not available.
    disabled: u8 = 0,
    value: []const u8 = "",
    buttons: []const GroupButton = &.{},
    icon: ?u21 = null,
};

/// The rows of the current section. Dynamic strings live in `scratch`
/// until the next paint.
fn buildRows(self: *Settings, buf: *[max_rows]Row) []Row {
    var rows: RowList = .{ .buf = buf };
    const scratch = self.scratch.allocator();
    switch (self.section) {
        .language => {
            rows.add(.{ .kind = .group, .title = i18n.tr(msg.interface_language) });
            for (std.enums.values(i18n.Language)) |lang| {
                rows.add(.{
                    .kind = .radio,
                    .action = .{ .language = lang },
                    .title = lang.nativeName(),
                    .detail = lang.configValue(),
                    .on = self.values.language == lang,
                });
            }
        },
        .appearance => {
            const materials = std.enums.values(WindowMaterial);
            var labels_buf: [materials.len][]const u8 = undefined;
            var disabled: u8 = 0;
            for (materials, 0..) |material, i| {
                labels_buf[i] = materialLabel(material);
                if (!system.materialSupported(material, self.build)) disabled |= @as(u8, 1) << @intCast(i);
            }
            const labels = scratch.dupe([]const u8, &labels_buf) catch &.{};
            rows.add(.{
                .kind = .choice,
                .action = .material,
                .title = i18n.tr(msg.window_material),
                .choices = labels,
                .choice = std.mem.indexOfScalar(WindowMaterial, materials, self.values.material) orelse 0,
                .disabled = disabled,
            });
            rows.add(.{ .kind = .note, .detail = self.materialNote(scratch) });
            rows.add(.{
                .kind = .group,
                .title = i18n.tr(msg.theme),
                .detail = if (self.layered) i18n.tr(msg.theme_hint) else "",
                .buttons = &.{.apply_theme},
            });
            rows.add(.{ .kind = .list, .action = .themes });
        },
        .font => {
            var size_buf: [32]u8 = undefined;
            const size = settings_map.FontSize.format(&size_buf, self.values.font_size) catch "";
            rows.add(.{
                .kind = .stepper,
                .action = .font_size,
                .title = i18n.tr(msg.font_size),
                .value = scratch.dupe(u8, size) catch "",
            });
            rows.add(.{
                .kind = .group,
                .title = i18n.tr(msg.font_family),
                .detail = i18n.tr(msg.font_family_hint),
                .buttons = &.{ .apply_font, .reset_font },
            });
            rows.add(.{ .kind = .list, .action = .font_family });
        },
        .interaction => {
            const menu = self.values.right_click == .@"context-menu";
            rows.add(.{
                .kind = .toggle,
                .action = .right_click,
                .title = i18n.tr("Right-Click Menu"),
                .detail = if (menu) "" else rightClickLabel(self.values.right_click),
                .on = menu,
            });
            rows.add(.{
                .kind = .toggle,
                .action = .scrollbar,
                .title = i18n.tr(msg.show_scrollbar),
                .on = self.values.scrollbar,
            });
            const choices = &settings_map.close_confirmation_choices;
            var labels_buf: [choices.len][]const u8 = undefined;
            for (choices, &labels_buf) |choice, *label| label.* = i18n.trRuntime(choice.label);
            const labels = scratch.dupe([]const u8, &labels_buf) catch &.{};
            rows.add(.{
                .kind = .choice,
                .action = .close_confirmation,
                .title = i18n.tr(msg.close_confirmation),
                .choices = labels,
                .choice = settings_map.choiceIndex(Config.ConfirmCloseSurface, choices, self.values.close_confirmation) orelse 0,
            });
            rows.add(.{ .kind = .group, .title = i18n.tr(msg.bell) });
            inline for (settings_map.bell_features, 0..) |feature, i| {
                rows.add(.{
                    .kind = .toggle,
                    .action = .{ .bell = i },
                    .title = i18n.tr(feature.label),
                    .on = @field(self.values.bell, feature.field),
                });
            }
        },
        .shell => {
            rows.add(.{ .kind = .group, .title = i18n.tr(msg.default_shell), .detail = i18n.tr(msg.default_shell_hint) });
            const current = if (self.shell_selected < self.shells.len)
                self.shellName(scratch, self.shells[self.shell_selected])
            else
                "";
            var note: std.Io.Writer.Allocating = .init(scratch);
            i18n.format(&note.writer, i18n.tr("Current default: {name}"), .{ .name = current }) catch {};
            if (self.app.defaultTerminalCommand()) |command| {
                const line = command.string(scratch) catch "";
                if (line.len > 0) note.writer.print(" \u{2014} {s}", .{line}) catch {};
            }
            rows.add(.{ .kind = .note, .detail = note.written() });
            for (self.shells, 0..) |shell, i| {
                rows.add(.{
                    .kind = .radio,
                    .action = .{ .shell = @intCast(i) },
                    .title = self.shellName(scratch, shell),
                    .detail = shell.command orelse "",
                    .on = i == self.shell_selected,
                });
            }
        },
        .about => {
            rows.add(.{
                .kind = .info,
                .title = i18n.tr(msg.app_name),
                .detail = i18n.fill(scratch, i18n.tr(msg.version), .{ .version = build_config.version_string }) catch "",
            });
            rows.add(.{ .kind = .note, .detail = i18n.tr(msg.notice) });
            rows.add(.{ .kind = .info, .title = i18n.tr(msg.config_file), .detail = self.config_path });
            rows.add(.{ .kind = .info, .title = i18n.tr(msg.settings_file), .detail = self.overlay_path });
            rows.add(.{ .kind = .note, .detail = i18n.tr(msg.settings_file_hint) });
            rows.add(.{
                .kind = .button,
                .action = .open_config_file,
                .title = i18n.tr(msg.open_config_file),
                .icon = draw.icons.open_file,
            });
            rows.add(.{
                .kind = .button,
                .action = .open_config_dir,
                .title = i18n.tr("Open Configuration Directory"),
                .icon = draw.icons.folder,
            });
        },
    }
    return rows.items();
}

const RowList = struct {
    buf: *[max_rows]Row,
    len: usize = 0,

    fn add(self: *RowList, row: Row) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = row;
        self.len += 1;
    }

    fn items(self: *const RowList) []Row {
        return self.buf[0..self.len];
    }
};

fn materialLabel(material: WindowMaterial) [:0]const u8 {
    return switch (material) {
        .solid => i18n.tr("Solid"),
        .mica => i18n.tr("Mica"),
        .acrylic => i18n.tr("Acrylic"),
        .tabbed => i18n.tr("Tabbed"),
    };
}

fn materialNote(self: *Settings, alloc: Allocator) []const u8 {
    if (self.build < system.build_windows_11) return i18n.tr("Window material requires Windows 11.");
    const all = for (std.enums.values(WindowMaterial)) |material| {
        if (!system.materialSupported(material, self.build)) break false;
    } else true;
    const template = if (all)
        i18n.tr("All window materials are supported on this system (build {build}).")
    else
        i18n.tr("Dimmed materials are not supported on this system (build {build}).");
    return i18n.fill(alloc, template, .{ .build = self.build }) catch "";
}

fn rightClickLabel(action: Config.RightClickAction) []const u8 {
    const choices = &settings_map.right_click_choices;
    const index = settings_map.choiceIndex(Config.RightClickAction, choices, action) orelse return "";
    return i18n.trRuntime(choices[index].label);
}

fn shellName(self: *Settings, alloc: Allocator, shell: Shell) []const u8 {
    _ = self;
    return switch (shell.kind) {
        .system_default => i18n.tr(msg.system_default),
        .custom_profile => shell.name,
        .custom_command => i18n.fill(alloc, i18n.tr(msg.custom_command), .{ .command = shell.name }) catch shell.name,
        .profile => i18n.fill(alloc, i18n.trRuntime(shell.name), .{ .name = shell.name_arg orelse "" }) catch shell.name,
    };
}

fn defaultFocus(self: *Settings, rows: []const Row) usize {
    for (rows, 0..) |row, i| {
        switch (self.section) {
            .language, .shell => if (row.kind == .radio and row.on) return i,
            .appearance => if (row.kind == .list) return i,
            .about => if (row.kind == .button) return i,
            else => {},
        }
    }
    return firstFocusable(rows) orelse 0;
}

fn firstFocusable(rows: []const Row) ?usize {
    for (rows, 0..) |row, i| if (row.kind.focusable()) return i;
    return null;
}

fn enterSection(self: *Settings, section: Section) void {
    self.section = section;
    self.body_scroll = 0;
    if (section == .font) self.ensureFonts();
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    self.focus = self.defaultFocus(rows);
    self.reveal_focus = true;
    self.theme_list.reveal = true;
    self.font_list.reveal = true;
    self.syncTextField();
    self.invalidate();
}

fn cycleSection(self: *Settings, delta: isize) void {
    const sections = std.enums.values(Section);
    const count: isize = @intCast(sections.len);
    const current: isize = @intCast(@intFromEnum(self.section));
    self.enterSection(sections[@intCast(@mod(current + delta, count))]);
}

/// Moves the focus to the next focusable row in direction `delta`.
fn moveFocus(self: *Settings, rows: []const Row, delta: isize) void {
    var i: isize = @intCast(self.focus);
    while (true) {
        i += delta;
        if (i < 0 or i >= rows.len) return;
        if (rows[@intCast(i)].kind.focusable()) break;
    }
    self.focus = @intCast(i);
    self.reveal_focus = true;
    if (i == 0 or firstFocusableBefore(rows, @intCast(i)) == null) self.body_scroll = 0;
    self.syncTextField();
    self.invalidate();
}

fn firstFocusableBefore(rows: []const Row, end: usize) ?usize {
    for (rows[0..end], 0..) |row, i| if (row.kind.focusable()) return i;
    return null;
}

// -----------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------

/// Enter, Space or a click on `row`.
fn activate(self: *Settings, row: Row) void {
    switch (row.action) {
        .none, .font_size => {},
        .language => |lang| self.setLanguage(lang),
        .material => self.stepChoice(row, 1),
        .themes => self.applyTheme(),
        .font_family => self.applyFontFamily(),
        .right_click => self.setRightClickMenu(!row.on),
        .scrollbar => self.setScrollbar(!row.on),
        .close_confirmation => self.stepChoice(row, 1),
        .bell => |i| self.setBell(i, !row.on),
        .shell => |i| self.chooseShell(i),
        .open_config_file => self.openConfigFile(),
        .open_config_dir => self.openConfigDir(),
    }
    self.invalidate();
}

/// Left/Right on a choice: the previous or next available choice, wrapping
/// around for Enter.
fn stepChoice(self: *Settings, row: Row, delta: isize) void {
    const count = row.choices.len;
    if (count == 0) return;
    var index: isize = @intCast(row.choice);
    for (0..count) |_| {
        index = @mod(index + delta, @as(isize, @intCast(count)));
        const i: usize = @intCast(index);
        if (row.disabled & (@as(u8, 1) << @intCast(i)) == 0) {
            self.setChoice(row, i);
            return;
        }
    }
}

/// Picks choice `index` of a choice row.
fn setChoice(self: *Settings, row: Row, index: usize) void {
    if (index >= row.choices.len) return;
    if (row.disabled & (@as(u8, 1) << @intCast(index)) != 0) return;
    switch (row.action) {
        .material => {
            const material = std.enums.values(WindowMaterial)[index];
            if (material == self.values.material) return;
            self.values.material = material;
            self.queueSet("gx-window-material", @tagName(material));
        },
        .close_confirmation => {
            const value = settings_map.close_confirmation_choices[index].value;
            if (value == self.values.close_confirmation) return;
            self.values.close_confirmation = value;
            self.queueSet("confirm-close-surface", @tagName(value));
        },
        else => {},
    }
    self.invalidate();
}

fn setLanguage(self: *Settings, lang: i18n.Language) void {
    if (lang == self.values.language) return;
    self.values.language = lang;
    self.queueSet("language", lang.configValue());
}

fn setRightClickMenu(self: *Settings, on: bool) void {
    // Without the menu, a right click copies the selection or pastes.
    const action: Config.RightClickAction = if (on) .@"context-menu" else .@"copy-or-paste";
    if (action == self.values.right_click) return;
    self.values.right_click = action;
    self.queueSet("right-click-action", @tagName(action));
}

fn setScrollbar(self: *Settings, on: bool) void {
    if (on == self.values.scrollbar) return;
    self.values.scrollbar = on;
    self.queueSet("scrollbar", @tagName(settings_map.scrollbar(on)));
}

fn setBell(self: *Settings, index: u8, on: bool) void {
    inline for (settings_map.bell_features, 0..) |feature, i| {
        if (i == index) @field(self.values.bell, feature.field) = on;
    }
    var buf: [128]u8 = undefined;
    const value = settings_map.formatFlags(Config.BellFeatures, self.values.bell, &buf) catch return;
    self.queueSet("bell-features", value);
}

const Step = enum { minus, plus, reset };

fn stepFontSize(self: *Settings, step: Step) void {
    const FontSize = settings_map.FontSize;
    const size: f32 = switch (step) {
        .minus => FontSize.normalize(self.values.font_size - FontSize.step),
        .plus => FontSize.normalize(self.values.font_size + FontSize.step),
        .reset => FontSize.default,
    };
    if (size == self.values.font_size) return;
    self.values.font_size = size;
    var buf: [32]u8 = undefined;
    const value = FontSize.format(&buf, size) catch return;
    self.queueSet("font-size", value);
    self.invalidate();
}

fn applyFontFamily(self: *Settings) void {
    const names = self.namesOf(.fonts);
    const typed = std.mem.trim(u8, self.font_query.items, &std.ascii.whitespace);
    // The highlighted family, or what was typed when nothing matches.
    const family: []const u8 = if (self.font_list.current()) |index| names[index] else typed;
    if (family.len == 0) return self.resetFontFamily();
    self.font_family = self.arena.allocator().dupe(u8, family) catch return;
    self.queueSet("font-family", family);
    self.invalidate();
}

fn resetFontFamily(self: *Settings) void {
    self.font_family = "";
    self.queueSetAll("font-family", &.{});
    self.invalidate();
}

fn chooseShell(self: *Settings, index: u16) void {
    if (index >= self.shells.len) return;
    const shell = self.shells[index];
    self.shell_selected = index;
    if (shell.command) |command| {
        self.queueSet("command", command);
    } else {
        self.queueSetAll("command", &.{});
    }
    if (shell.gx_zsh) |exe| self.runHerdr(exe);
    self.invalidate();
}

fn openConfigFile(self: *Settings) void {
    // The editor path of `gx-open-config-ui = editor`.
    const opened = self.app.openConfigFile(.os_open) catch |err| {
        self.setStatus(.err, msg.open_failed, .{ .reason = @errorName(err) });
        return;
    };
    if (!opened) self.setStatus(.err, msg.open_failed, .{ .reason = "ShellExecute" });
}

fn openConfigDir(self: *Settings) void {
    const dir = std.fs.path.dirname(self.overlay_path) orelse return;
    std.Io.Dir.cwd().createDirPath(global.io(), dir) catch |err| {
        log.warn("cannot create {s} err={}", .{ dir, err });
    };
    const dir_w = wstr.allocZ(self.alloc, dir) catch return;
    defer self.alloc.free(dir_w);
    const result = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        dir_w,
        null,
        null,
        w32.SW_SHOW,
    );
    if (result <= 32) self.setStatus(.err, msg.open_failed, .{ .reason = "ShellExecute" });
}

// -----------------------------------------------------------------------
// Themes
// -----------------------------------------------------------------------

fn themeName(self: *Settings, index: u32) ?[:0]const u8 {
    const names = self.namesOf(.themes);
    return if (index < names.len) names[index] else null;
}

/// Previews the theme under the cursor, at most every
/// `preview_interval_ms` while the cursor moves.
fn schedulePreview(self: *Settings) void {
    if (!self.layered) return;
    const index = self.theme_list.current() orelse return;
    if (self.preview_theme == null and self.applied_preview == null and index == self.saved_theme) return;
    self.preview_theme = index;
    if (self.timers.contains(.preview)) return;
    const elapsed = system.nowMs() -| self.last_preview_ms;
    const delay: u32 = if (elapsed >= preview_interval_ms) 10 else @intCast(preview_interval_ms - elapsed);
    self.startTimer(.preview, delay);
}

fn previewNow(self: *Settings) void {
    self.last_preview_ms = system.nowMs();
    const index = self.preview_theme orelse return;
    if (self.applied_preview == index) return;
    const name = self.themeName(index) orelse return;
    // Pending changes go to disk first so the preview keeps them.
    self.commitChanges() catch {};
    if (self.reloadWith(name)) {
        self.applied_preview = index;
        self.setStatus(.info, "Previewing {name}", .{ .name = name });
    }
}

fn applyTheme(self: *Settings) void {
    const index = self.theme_list.current() orelse return;
    const name = self.themeName(index) orelse return;
    self.stopTimer(.preview);
    self.preview_theme = null;
    self.applied_preview = null;
    self.saved_theme = index;
    self.queueSet("theme", name);
    self.saveNow();
    self.invalidate();
}

// -----------------------------------------------------------------------
// Saving and reloading
// -----------------------------------------------------------------------

fn queueSet(self: *Settings, key: []const u8, value: []const u8) void {
    self.queueSetAll(key, &.{value});
}

/// Records a change (an empty `values` removes `key` from the overlay)
/// and saves it with the other changes of the next moment.
fn queueSetAll(self: *Settings, key: []const u8, values: []const []const u8) void {
    self.changes.setAll(key, values) catch |err| {
        log.warn("cannot record the change of {s} err={}", .{ key, err });
        return;
    };
    self.stopTimer(.save);
    self.startTimer(.save, save_delay_ms);
}

/// Writes the recorded changes to the overlay file.
fn commitChanges(self: *Settings) !void {
    if (self.changes.isEmpty()) return;
    const path = gx.config_layers.overlayPath(self.alloc) catch |err| {
        log.warn("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
        self.changes.clear();
        self.setStatus(.err, msg.save_failed, .{ .reason = @errorName(err) });
        return err;
    };
    defer self.alloc.free(path);
    self.changes.commit(self.alloc, global.io(), path) catch |err| {
        log.warn("cannot save {s} err={}", .{ path, err });
        self.changes.clear();
        self.setStatus(.err, msg.save_failed, .{ .reason = @errorName(err) });
        return err;
    };
    log.info("saved the settings to {s}", .{path});
}

/// Saves the recorded changes and applies them.
fn saveNow(self: *Settings) void {
    self.stopTimer(.save);
    if (self.changes.isEmpty()) return;
    self.commitChanges() catch return;
    const ok = if (self.applied_preview != null or self.preview_theme != null) ok: {
        const index = self.preview_theme orelse self.applied_preview.?;
        break :ok self.reloadWith(self.themeName(index));
    } else self.reloadFromDisk();
    if (ok) self.setStatus(.success, "Settings saved.", .{});
}

/// Reloads the configuration from disk and applies it, like
/// `reload_config`.
fn reloadFromDisk(self: *Settings) bool {
    var config = Config.load(self.alloc) catch |err| {
        log.warn("cannot reload the configuration err={}", .{err});
        self.setStatus(.err, msg.reload_failed, .{ .reason = @errorName(err) });
        return false;
    };
    defer config.deinit();
    self.app.core_app.updateConfig(self.app, &config) catch |err| {
        log.warn("cannot apply the configuration err={}", .{err});
        self.setStatus(.err, msg.reload_failed, .{ .reason = @errorName(err) });
        return false;
    };
    self.applied_preview = null;
    self.configApplied();
    return true;
}

/// Loads the configuration with in-memory overrides, `theme` (if any) and
/// no reload notification, and applies it without saving anything.
fn reloadWith(self: *Settings, theme: ?[]const u8) bool {
    var quiet_buf: [128]u8 = undefined;
    const quiet = settings_map.quietReloadArg(&quiet_buf, self.notifications) catch |err| {
        self.setStatus(.err, msg.preview_failed, .{ .reason = @errorName(err) });
        return false;
    };
    var args: [2][:0]const u8 = .{ quiet, undefined };
    var len: usize = 1;
    var theme_arg: ?[:0]u8 = null;
    defer if (theme_arg) |arg| self.alloc.free(arg);
    if (theme) |name| {
        theme_arg = settings_map.themeArg(self.alloc, name) catch |err| {
            self.setStatus(.err, msg.preview_failed, .{ .reason = @errorName(err) });
            return false;
        };
        args[1] = theme_arg.?;
        len = 2;
    }
    var config = gx.config_layers.loadWithOverrides(self.alloc, args[0..len]) catch |err| {
        log.warn("cannot load the configuration err={}", .{err});
        self.setStatus(.err, msg.preview_failed, .{ .reason = @errorName(err) });
        return false;
    };
    defer config.deinit();
    self.app.core_app.updateConfig(self.app, &config) catch |err| {
        log.warn("cannot apply the configuration err={}", .{err});
        self.setStatus(.err, msg.preview_failed, .{ .reason = @errorName(err) });
        return false;
    };
    self.configApplied();
    return true;
}

/// The application now runs with a new configuration: follow its colors
/// and language.
fn configApplied(self: *Settings) void {
    const t = self.tokens();
    self.popup.setBorderColor(t.border);
    self.invalidate();
}

// -----------------------------------------------------------------------
// herdr
// -----------------------------------------------------------------------

/// Makes herdr start GX Zsh by default, if herdr is installed:
/// `herdr --gx-set-default-shell <gx-zsh>` runs in the background and its
/// result shows in the status line. Exit code 3 means the user manages the
/// herdr configuration, which is not an error.
fn runHerdr(self: *Settings, gx_zsh: []const u8) void {
    if (self.herdr_run != null) return;
    const herdr = system.herdrNextTo(self.alloc, global.io(), gx_zsh) orelse
        (if (self.herdr_exe) |exe| self.alloc.dupe(u8, exe) catch return else return);
    defer self.alloc.free(herdr);
    self.herdr_run = system.HerdrRun.start(self.alloc, herdr, gx_zsh) catch |err| {
        self.setStatus(.err, msg.herdr_failed, .{ .reason = @errorName(err) });
        return;
    };
    log.info("running {s} --gx-set-default-shell {s}", .{ herdr, gx_zsh });
    self.startTimer(.herdr, herdr_poll_ms);
}

fn pollHerdr(self: *Settings) void {
    var run = self.herdr_run orelse {
        self.stopTimer(.herdr);
        return;
    };
    // Report after the shell choice is saved, so its status does not hide
    // the result.
    if (self.timers.contains(.save)) return;
    switch (run.poll()) {
        .running => {
            if (system.nowMs() -| run.started_ms < herdr_timeout_ms) return;
            log.warn("herdr --gx-set-default-shell did not finish", .{});
            self.setStatus(.err, msg.herdr_failed, .{ .reason = "timeout" });
        },
        .exited => |code| switch (code) {
            0 => self.setStatus(.success, msg.herdr_updated, .{}),
            system.herdr_user_config_exit => self.setStatus(.info, msg.herdr_user_config, .{}),
            else => {
                log.warn("herdr --gx-set-default-shell exited with {d}", .{code});
                self.setStatus(.err, msg.herdr_exit, .{ .code = code });
            },
        },
        .failed => self.setStatus(.err, msg.herdr_failed, .{ .reason = "wait" }),
    }
    run.deinit();
    self.herdr_run = null;
    self.stopTimer(.herdr);
}

// -----------------------------------------------------------------------
// Timers
// -----------------------------------------------------------------------

const Timer = enum(usize) {
    save = 1,
    preview = 2,
    herdr = 3,
};

fn startTimer(self: *Settings, timer: Timer, ms: u32) void {
    const hwnd = self.popup.hwnd orelse return;
    if (w32.SetTimer(hwnd, @intFromEnum(timer), ms, @ptrCast(&timerProc)) != 0) self.timers.insert(timer);
}

fn stopTimer(self: *Settings, timer: Timer) void {
    if (!self.timers.contains(timer)) return;
    self.timers.remove(timer);
    if (self.popup.hwnd) |hwnd| _ = w32.KillTimer(hwnd, @intFromEnum(timer));
}

fn timerProc(hwnd: ?w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    const self = instance orelse {
        _ = w32.KillTimer(hwnd, id);
        return;
    };
    const timer = std.enums.fromInt(Timer, id) orelse return;
    switch (timer) {
        .save => {
            self.stopTimer(.save);
            self.saveNow();
        },
        .preview => {
            self.stopTimer(.preview);
            self.previewNow();
        },
        .herdr => self.pollHerdr(),
    }
    self.invalidate();
}

// -----------------------------------------------------------------------
// Status line
// -----------------------------------------------------------------------

const StatusKind = enum { none, info, success, err };

fn setStatus(self: *Settings, kind: StatusKind, comptime msgid: [:0]const u8, args: anytype) void {
    var writer: std.Io.Writer = .fixed(&self.status_buf);
    i18n.format(&writer, i18n.tr(msgid), args) catch {};
    self.status_len = writer.buffered().len;
    self.status_kind = kind;
    self.invalidate();
}

fn clearStatus(self: *Settings) void {
    self.status_kind = .none;
    self.status_len = 0;
}

// -----------------------------------------------------------------------
// Input
// -----------------------------------------------------------------------

const Target = union(enum) {
    section: Section,
    close,
    row: u16,
    chip: struct { row: u16, index: u8 },
    step: struct { row: u16, step: Step },
    item: struct { row: u16, index: u32 },
    field: u16,
    group_button: GroupButton,
};

const Hit = struct {
    rect: d2d.Rect,
    target: Target,
};

fn addHit(self: *Settings, rect: d2d.Rect, target: Target) void {
    if (self.hit_count >= self.hits.len) return;
    self.hits[self.hit_count] = .{ .rect = rect, .target = target };
    self.hit_count += 1;
}

fn hitAt(self: *const Settings, pos: d2d.Point) ?Target {
    var i = self.hit_count;
    while (i > 0) {
        i -= 1;
        if (self.hits[i].rect.contains(pos)) return self.hits[i].target;
    }
    return null;
}

fn isHover(self: *const Settings, target: Target) bool {
    const hover = self.hover orelse return false;
    return std.meta.eql(hover, target);
}

fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    if (key.alt and key.vk == w32.VK_F4) {
        popup.dismiss(.owner);
        return true;
    }
    if (key.alt) return false;
    if (key.vk == w32.VK_TAB) {
        self.cycleSection(if (key.shift) -1 else 1);
        return true;
    }
    if (key.ctrl and (key.vk == w32.VK_NEXT or key.vk == w32.VK_PRIOR)) {
        self.cycleSection(if (key.vk == w32.VK_NEXT) 1 else -1);
        return true;
    }

    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    if (rows.len == 0) return false;
    if (self.focus >= rows.len or !rows[self.focus].kind.focusable()) self.focus = self.defaultFocus(rows);
    const row = rows[self.focus];
    const list: ?*List = switch (row.action) {
        .themes => &self.theme_list,
        .font_family => &self.font_list,
        else => null,
    };

    switch (key.vk) {
        w32.VK_UP, w32.VK_DOWN => {
            const delta: isize = if (key.vk == w32.VK_UP) -1 else 1;
            if (list) |l| {
                if (l.move(delta)) {
                    if (row.action == .themes) self.schedulePreview();
                    self.invalidate();
                    return true;
                }
            }
            self.moveFocus(rows, delta);
            return true;
        },
        w32.VK_PRIOR, w32.VK_NEXT => {
            const l = list orelse return true;
            const page: isize = @intCast(@max(l.visible, 2) - 1);
            if (l.move(if (key.vk == w32.VK_PRIOR) -page else page) and row.action == .themes) self.schedulePreview();
            self.invalidate();
            return true;
        },
        w32.VK_HOME, w32.VK_END => {
            const l = list orelse return false;
            if (!key.ctrl) return false;
            const far: isize = @intCast(l.matches.items.len);
            if (l.move(if (key.vk == w32.VK_HOME) -far else far) and row.action == .themes) self.schedulePreview();
            self.invalidate();
            return true;
        },
        w32.VK_LEFT, w32.VK_RIGHT => {
            const right = key.vk == w32.VK_RIGHT;
            switch (row.kind) {
                .choice => self.stepChoice(row, if (right) 1 else -1),
                .toggle => if (row.on != right) self.activate(row),
                .stepper => self.stepFontSize(if (right) .plus else .minus),
                else => return false,
            }
            self.invalidate();
            return true;
        },
        w32.VK_RETURN => {
            self.activate(row);
            return true;
        },
        w32.VK_SPACE => {
            if (row.kind == .list) return false;
            self.activate(row);
            return true;
        },
        w32.VK_OEM_PLUS, w32.VK_ADD, w32.VK_OEM_MINUS, w32.VK_SUBTRACT => {
            if (row.kind != .stepper) return false;
            const plus = key.vk == w32.VK_OEM_PLUS or key.vk == w32.VK_ADD;
            self.stepFontSize(if (plus) .plus else .minus);
            return true;
        },
        w32.VK_BACK, w32.VK_DELETE => {
            if (row.kind != .stepper) return false;
            self.stepFontSize(.reset);
            return true;
        },
        else => return false,
    }
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    _ = popup;
    switch (event.kind) {
        .move => {
            const target = self.hitAt(event.pos);
            const changed = if (target) |t| !self.isHover(t) else self.hover != null;
            if (changed) {
                self.hover = target;
                self.invalidate();
            }
        },
        .leave => if (self.hover != null) {
            self.hover = null;
            self.invalidate();
        },
        .down, .double_click => {
            if (event.button != .left) return;
            if (system.nowMs() -| self.opened_ms < click_guard_ms) return;
            const target = self.hitAt(event.pos) orelse return;
            if (event.kind == .double_click) {
                if (target == .item) {
                    self.click(target);
                    var buf: [max_rows]Row = undefined;
                    const rows = self.buildRows(&buf);
                    if (target.item.row < rows.len) self.activate(rows[target.item.row]);
                    return;
                }
            }
            self.click(target);
        },
        .up => {},
        .wheel => self.wheel(event.pos, event.wheel),
    }
}

fn click(self: *Settings, target: Target) void {
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    switch (target) {
        .section => |section| return self.enterSection(section),
        .close => return self.popup.dismiss(.owner),
        .group_button => |button| {
            switch (button) {
                .apply_theme => self.applyTheme(),
                .apply_font => self.applyFontFamily(),
                .reset_font => self.resetFontFamily(),
            }
            self.invalidate();
            return;
        },
        .row => |i| {
            if (i >= rows.len) return;
            self.focusRow(i);
            switch (rows[i].kind) {
                .radio, .toggle, .button => self.activate(rows[i]),
                else => {},
            }
        },
        .chip => |chip| {
            if (chip.row >= rows.len) return;
            self.focusRow(chip.row);
            self.setChoice(rows[chip.row], chip.index);
        },
        .step => |step| {
            if (step.row >= rows.len) return;
            self.focusRow(step.row);
            self.stepFontSize(step.step);
        },
        .item => |item| {
            if (item.row >= rows.len) return;
            self.focusRow(item.row);
            const list: *List = switch (rows[item.row].action) {
                .themes => &self.theme_list,
                .font_family => &self.font_list,
                else => return,
            };
            if (item.index >= list.matches.items.len) return;
            list.cursor = item.index;
            if (rows[item.row].action == .themes) self.schedulePreview();
        },
        .field => |i| self.focusRow(i),
    }
    self.invalidate();
}

fn focusRow(self: *Settings, index: usize) void {
    self.focus = index;
    self.syncTextField();
}

fn wheel(self: *Settings, pos: d2d.Point, notches: f32) void {
    if (self.list_area) |area| {
        if (area.contains(pos)) {
            const field: Field = if (self.section == .font) .fonts else .themes;
            const list = self.listOf(field);
            const len = list.matches.items.len;
            const max_top = len -| list.visible;
            const delta: isize = @intFromFloat(@round(-notches * 3));
            const top: isize = @as(isize, @intCast(list.top)) + delta;
            list.top = @intCast(std.math.clamp(top, 0, @as(isize, @intCast(max_top))));
            list.reveal = false;
            self.invalidate();
            return;
        }
    }
    self.body_scroll = @max(0, self.body_scroll - notches * 96);
    self.reveal_focus = false;
    self.invalidate();
}

fn onDismissed(ctx: *anyopaque, popup: *Popup, reason: Popup.DismissReason) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    _ = popup;
    self.finish(switch (reason) {
        .escape, .outside_click => .user,
        .deactivated => .deactivated,
        .owner => .user,
    });
}

fn onScrimClick(ctx: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    if (system.nowMs() -| self.opened_ms < click_guard_ms) return;
    self.popup.dismiss(.outside_click);
}

fn onDpiChanged(ctx: *anyopaque, popup: *Popup) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    _ = popup;
    self.reveal_focus = true;
    self.invalidate();
}

// -----------------------------------------------------------------------
// Painting
// -----------------------------------------------------------------------

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    _ = self.scratch.reset(.retain_capacity);
    self.hit_count = 0;
    self.list_area = null;
    const t = self.tokens();
    const size = popup.sizeDip();
    const w = size.width;
    const h = size.height;

    canvas.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, t.surface_raised);
    self.paintSidebar(canvas, t, h);
    self.paintHeader(canvas, t, w);
    self.paintBody(canvas, t, .{
        .x = sidebar_width,
        .y = header_height,
        .w = @max(0, w - sidebar_width),
        .h = @max(0, h - header_height - footer_height),
    });
    self.paintFooter(canvas, t, .{
        .x = sidebar_width,
        .y = h - footer_height,
        .w = @max(0, w - sidebar_width),
        .h = footer_height,
    });
}

fn paintSidebar(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, h: f32) void {
    canvas.fillRect(.{ .x = 0, .y = 0, .w = sidebar_width, .h = h }, t.surface);
    canvas.fillRect(.{ .x = sidebar_width - 1, .y = 0, .w = 1, .h = h }, t.border);

    canvas.drawIcon(draw.icons.settings, .{ .x = 18, .y = 18, .w = 22, .h = 28 }, 18, t.accent);
    canvas.drawText(i18n.tr(msg.settings), .{ .x = 48, .y = 18, .w = sidebar_width - 60, .h = 28 }, .{
        .size = 18,
        .weight = .semibold,
        .color = t.text,
    });

    var y: f32 = 64;
    for (std.enums.values(Section)) |section| {
        const item: d2d.Rect = .{ .x = 10, .y = y, .w = sidebar_width - 20, .h = 36 };
        const selected = section == self.section;
        if (selected) {
            canvas.fillRoundedRect(item, 4, t.selected);
            canvas.fillRoundedRect(.{ .x = item.x, .y = item.y + 10, .w = 3, .h = 16 }, 1.5, t.accent);
        } else if (self.isHover(.{ .section = section })) {
            canvas.fillRoundedRect(item, 4, t.hover);
        }
        canvas.drawIcon(section.icon(), .{ .x = item.x + 12, .y = item.y, .w = 18, .h = item.h }, 15, if (selected) t.accent else t.text_secondary);
        canvas.drawText(section.title(), .{ .x = item.x + 40, .y = item.y, .w = item.w - 48, .h = item.h }, .{
            .size = style.font_size.body,
            .weight = if (selected) .semibold else .normal,
            .color = t.text,
        });
        self.addHit(item, .{ .section = section });
        y += 40;
    }
}

fn paintHeader(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, w: f32) void {
    canvas.drawText(self.section.title(), .{
        .x = sidebar_width + content_pad,
        .y = 16,
        .w = @max(0, w - sidebar_width - content_pad - 64),
        .h = 34,
    }, .{ .size = style.font_size.subtitle, .weight = .semibold, .color = t.text });
    const close: d2d.Rect = .{ .x = w - 16 - 34, .y = 16, .w = 34, .h = 34 };
    draw.button(canvas, close, "", draw.icons.close, .subtle, true, self.isHover(.close), t);
    self.addHit(close, .close);
}

fn paintFooter(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, rect: d2d.Rect) void {
    canvas.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, t.border);
    var text_style: d2d.TextStyle = .{ .size = style.font_size.caption, .color = t.text_secondary };
    const text: []const u8 = switch (self.status_kind) {
        .none => i18n.tr(msg.changes_saved),
        else => self.status_buf[0..self.status_len],
    };
    switch (self.status_kind) {
        .none, .info => {},
        .success => text_style.color = draw.successColor(t),
        .err => text_style.color = draw.errorColor(t),
    }

    // A message that does not fit next to the key hints takes the whole
    // line, wrapped.
    const full_w = @max(0, rect.w - 2 * content_pad);
    const hints_w = self.paintKeyHints(canvas, t, rect, false) + 16;
    const fits = canvas.measureText(text, text_style, 10_000).width <= full_w - hints_w;
    if (!fits) text_style.wrap = true;
    canvas.drawText(text, .{
        .x = rect.x + content_pad,
        .y = rect.y + 1,
        .w = if (fits) full_w - hints_w else full_w,
        .h = rect.h - 1,
    }, text_style);
    if (fits) _ = self.paintKeyHints(canvas, t, rect, true);
}

/// The key hints at the right of the footer; returns their width and
/// draws them when `visible`.
fn paintKeyHints(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, rect: d2d.Rect, visible: bool) f32 {
    _ = self;
    const hints = [_]struct { []const u8, []const u8 }{
        .{ "Tab", i18n.tr("Switch Section") },
        .{ "Esc", i18n.tr("Close") },
    };
    var widths: [hints.len]f32 = undefined;
    var total: f32 = 0;
    const small: d2d.TextStyle = .{ .size = style.font_size.caption, .ellipsis = false };
    for (hints, 0..) |hint, i| {
        widths[i] = @ceil(canvas.measureText(hint[0], small, 200).width) + 12 + 6 +
            @ceil(canvas.measureText(hint[1], small, 400).width);
        total += widths[i];
    }
    total += 16 * @as(f32, @floatFromInt(hints.len - 1));
    if (visible) {
        var x = rect.x + rect.w - content_pad - total;
        for (hints, widths) |hint, width| {
            _ = draw.keyHint(canvas, x, rect.y, rect.h, hint[0], hint[1], t);
            x += width + 16;
        }
    }
    return total;
}

/// Row geometry of a paint pass.
const Layout = struct {
    heights: [max_rows]f32 = undefined,
    content_height: f32 = 0,
};

fn paintBody(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, body: d2d.Rect) void {
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    if (rows.len == 0) return;
    if (self.focus >= rows.len or !rows[self.focus].kind.focusable()) self.focus = self.defaultFocus(rows);

    const x = body.x + content_pad;
    const width = @max(0, body.w - 2 * content_pad);
    const top_pad: f32 = 8;
    const bottom_pad: f32 = 16;

    // Heights: lists take what the other rows leave.
    var layout: Layout = .{};
    var fixed: f32 = 0;
    var list_count: f32 = 0;
    for (rows, 0..) |row, i| {
        const height = if (row.kind == .list) 0 else self.rowHeight(canvas, row, width);
        layout.heights[i] = height;
        fixed += height;
        if (row.kind == .list) list_count += 1;
    }
    fixed += row_gap * @as(f32, @floatFromInt(rows.len - 1));
    if (list_count > 0) {
        const share = @max(min_list_height, (body.h - top_pad - bottom_pad - fixed) / list_count);
        for (rows, 0..) |row, i| {
            if (row.kind == .list) layout.heights[i] = share;
        }
        fixed += share * list_count;
    }
    layout.content_height = top_pad + fixed + bottom_pad;

    // Scrolling.
    const max_scroll = @max(0, layout.content_height - body.h);
    if (self.reveal_focus) {
        self.reveal_focus = false;
        var row_top: f32 = top_pad;
        for (rows[0..self.focus], 0..) |_, i| row_top += layout.heights[i] + row_gap;
        const row_bottom = row_top + layout.heights[self.focus];
        if (row_top < self.body_scroll) self.body_scroll = row_top - top_pad;
        if (row_bottom > self.body_scroll + body.h) self.body_scroll = row_bottom - body.h + bottom_pad;
    }
    self.body_scroll = std.math.clamp(self.body_scroll, 0, max_scroll);

    canvas.pushClip(body);
    defer canvas.popClip();
    var y = body.y + top_pad - self.body_scroll;
    for (rows, 0..) |row, i| {
        const height = layout.heights[i];
        const rect: d2d.Rect = .{ .x = x, .y = y, .w = width, .h = height };
        if (rect.y + rect.h >= body.y and rect.y <= body.y + body.h) {
            self.paintRow(canvas, t, row, @intCast(i), rect, body);
        }
        y += height + row_gap;
    }

    if (max_scroll > 0) {
        const track_h = body.h - 8;
        const thumb_h = @max(24, track_h * body.h / layout.content_height);
        const thumb_y = body.y + 4 + (track_h - thumb_h) * (self.body_scroll / max_scroll);
        canvas.fillRoundedRect(.{ .x = body.x + body.w - 6, .y = thumb_y, .w = 3, .h = thumb_h }, 1.5, t.text_disabled);
    }
}

fn rowHeight(self: *Settings, canvas: *d2d.Canvas, row: Row, width: f32) f32 {
    _ = self;
    return switch (row.kind) {
        .group => {
            var h: f32 = 34;
            if (row.detail.len > 0) h += 2 + measureWrapped(canvas, row.detail, width);
            return h;
        },
        .note => measureWrapped(canvas, row.detail, width) + 4,
        .radio, .toggle => if (row.detail.len > 0) card_height_detail else card_height,
        .choice, .stepper => card_height + 4,
        .info => 22 + 8 + measureWrapped(canvas, row.detail, width - 32) + 14,
        .button => draw.button_height + 8,
        .list => min_list_height,
    };
}

fn captionStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.caption,
        .color = t.text_secondary,
        .align_y = .top,
        .wrap = true,
        .ellipsis = false,
    };
}

fn measureWrapped(canvas: *d2d.Canvas, text: []const u8, width: f32) f32 {
    if (text.len == 0) return 0;
    const s: d2d.TextStyle = .{ .size = style.font_size.caption, .align_y = .top, .wrap = true, .ellipsis = false };
    return @ceil(canvas.measureText(text, s, @max(width, 1)).height);
}

fn paintRow(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, row: Row, index: u16, rect: d2d.Rect, body: d2d.Rect) void {
    const focused = index == self.focus and row.kind.focusable();
    const title_style: d2d.TextStyle = .{ .size = style.font_size.body, .color = t.text };
    const hover_row = self.isHover(.{ .row = index });
    switch (row.kind) {
        .group => {
            var buttons_w: f32 = 0;
            var bx = rect.x + rect.w;
            for (row.buttons) |button| {
                const label = groupButtonLabel(button);
                const bw = draw.buttonWidth(canvas, label, null);
                bx -= bw;
                const brect: d2d.Rect = .{ .x = bx, .y = rect.y + 2, .w = bw, .h = draw.button_height };
                const enabled = self.groupButtonEnabled(button);
                draw.button(canvas, brect, label, null, if (button == .reset_font) .normal else .primary, enabled, self.isHover(.{ .group_button = button }), t);
                if (enabled) self.addHit(brect, .{ .group_button = button });
                bx -= 8;
                buttons_w += bw + 8;
            }
            var group_style = title_style;
            group_style.weight = .semibold;
            canvas.drawText(row.title, .{ .x = rect.x, .y = rect.y + 4, .w = @max(0, rect.w - buttons_w), .h = 26 }, group_style);
            if (row.detail.len > 0) {
                canvas.drawText(row.detail, .{ .x = rect.x, .y = rect.y + 34, .w = rect.w, .h = rect.h - 34 }, captionStyle(t));
            }
        },
        .note => canvas.drawText(row.detail, .{ .x = rect.x, .y = rect.y + 2, .w = rect.w, .h = rect.h }, captionStyle(t)),
        .radio => {
            draw.card(canvas, rect, t, hover_row);
            draw.radio(canvas, .{ .x = rect.x + 12, .y = rect.y, .w = 24, .h = rect.h }, row.on, hover_row, t);
            self.paintTitle(canvas, t, row, .{ .x = rect.x + 48, .y = rect.y, .w = rect.w - 64, .h = rect.h });
            self.addHit(rect, .{ .row = index });
        },
        .toggle => {
            draw.card(canvas, rect, t, hover_row);
            const sw: d2d.Rect = .{
                .x = rect.x + rect.w - 16 - draw.switch_width,
                .y = rect.y + (rect.h - draw.switch_height) / 2,
                .w = draw.switch_width,
                .h = draw.switch_height,
            };
            draw.switchControl(canvas, sw, row.on, hover_row, t);
            self.paintTitle(canvas, t, row, .{ .x = rect.x + 16, .y = rect.y, .w = rect.w - 48 - draw.switch_width, .h = rect.h });
            self.addHit(rect, .{ .row = index });
        },
        .choice => {
            draw.card(canvas, rect, t, false);
            self.addHit(rect, .{ .row = index });
            var widths: [8]f32 = undefined;
            var total: f32 = 0;
            for (row.choices, 0..) |label, i| {
                if (i >= widths.len) break;
                widths[i] = draw.chipWidth(canvas, label);
                total += widths[i] + (if (i > 0) @as(f32, 6) else 0);
            }
            var cx = rect.x + rect.w - 12 - total;
            for (row.choices, 0..) |label, i| {
                if (i >= widths.len) break;
                const chip_rect: d2d.Rect = .{ .x = cx, .y = rect.y + (rect.h - draw.chip_height) / 2, .w = widths[i], .h = draw.chip_height };
                const enabled = row.disabled & (@as(u8, 1) << @intCast(i)) == 0;
                const target: Target = .{ .chip = .{ .row = index, .index = @intCast(i) } };
                draw.chip(canvas, chip_rect, label, i == row.choice, enabled, self.isHover(target), t);
                if (enabled) self.addHit(chip_rect, target);
                cx += widths[i] + 6;
            }
            canvas.drawText(row.title, .{ .x = rect.x + 16, .y = rect.y, .w = @max(0, rect.w - total - 40), .h = rect.h }, title_style);
        },
        .stepper => {
            draw.card(canvas, rect, t, false);
            self.addHit(rect, .{ .row = index });
            const reset_label = i18n.tr(msg.reset_to_default);
            const reset_w = draw.buttonWidth(canvas, reset_label, draw.icons.reset);
            const by = rect.y + (rect.h - draw.button_height) / 2;
            const reset: d2d.Rect = .{ .x = rect.x + rect.w - 12 - reset_w, .y = by, .w = reset_w, .h = draw.button_height };
            const plus: d2d.Rect = .{ .x = reset.x - 16 - draw.button_height, .y = by, .w = draw.button_height, .h = draw.button_height };
            const value: d2d.Rect = .{ .x = plus.x - 4 - 64, .y = by, .w = 64, .h = draw.button_height };
            const minus: d2d.Rect = .{ .x = value.x - 4 - draw.button_height, .y = by, .w = draw.button_height, .h = draw.button_height };
            const FontSize = settings_map.FontSize;
            const steps = [_]struct { d2d.Rect, Step, []const u8, ?u21, bool }{
                .{ minus, .minus, "", draw.icons.remove, self.values.font_size > FontSize.min },
                .{ plus, .plus, "", draw.icons.add, self.values.font_size < FontSize.max },
                .{ reset, .reset, reset_label, draw.icons.reset, self.values.font_size != FontSize.default },
            };
            for (steps) |step| {
                const target: Target = .{ .step = .{ .row = index, .step = step[1] } };
                draw.button(canvas, step[0], step[2], step[3], .normal, step[4], self.isHover(target), t);
                if (step[4]) self.addHit(step[0], target);
            }
            canvas.fillRoundedRect(value, 4, t.surface_raised);
            canvas.strokeRoundedRect(value, 4, t.border, 1);
            canvas.drawText(row.value, value, .{ .size = style.font_size.body, .weight = .semibold, .color = t.text, .align_x = .center });
            canvas.drawText(row.title, .{ .x = rect.x + 16, .y = rect.y, .w = @max(0, minus.x - rect.x - 24), .h = rect.h }, title_style);
        },
        .list => self.paintList(canvas, t, row, index, rect, body),
        .info => {
            draw.card(canvas, rect, t, false);
            canvas.drawText(row.title, .{ .x = rect.x + 16, .y = rect.y + 8, .w = rect.w - 32, .h = 22 }, title_style);
            canvas.drawText(row.detail, .{ .x = rect.x + 16, .y = rect.y + 30, .w = rect.w - 32, .h = rect.h - 34 }, captionStyle(t));
        },
        .button => {
            const bw = draw.buttonWidth(canvas, row.title, row.icon);
            const brect: d2d.Rect = .{ .x = rect.x, .y = rect.y + 4, .w = bw, .h = draw.button_height };
            draw.button(canvas, brect, row.title, row.icon, .normal, true, hover_row, t);
            self.addHit(brect, .{ .row = index });
            if (focused) draw.focusRing(canvas, brect, t);
            return;
        },
    }
    if (focused and row.kind != .list) draw.focusRing(canvas, rect, t);
}

/// The title of a radio or toggle row with its optional detail line.
fn paintTitle(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, row: Row, rect: d2d.Rect) void {
    _ = self;
    const title_style: d2d.TextStyle = .{ .size = style.font_size.body, .color = t.text };
    if (row.detail.len == 0) {
        canvas.drawText(row.title, rect, title_style);
        return;
    }
    canvas.drawText(row.title, .{ .x = rect.x, .y = rect.y + 9, .w = rect.w, .h = 22 }, title_style);
    canvas.drawText(row.detail, .{ .x = rect.x, .y = rect.y + 31, .w = rect.w, .h = 18 }, .{
        .size = style.font_size.caption,
        .color = t.text_secondary,
    });
}

fn groupButtonLabel(button: GroupButton) []const u8 {
    return switch (button) {
        .apply_theme, .apply_font => i18n.tr(msg.apply),
        .reset_font => i18n.tr(msg.reset_to_default),
    };
}

fn groupButtonEnabled(self: *Settings, button: GroupButton) bool {
    return switch (button) {
        .apply_theme => if (self.theme_list.current()) |index| index != self.saved_theme else false,
        .apply_font => self.font_list.current() != null or
            std.mem.trim(u8, self.font_query.items, &std.ascii.whitespace).len > 0,
        .reset_font => self.font_family.len > 0,
    };
}

fn paintList(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, row: Row, index: u16, rect: d2d.Rect, body: d2d.Rect) void {
    const field: Field = if (row.action == .themes) .themes else .fonts;
    const list = self.listOf(field);
    const names = self.namesOf(field);
    const focused = index == self.focus;
    const placeholder = switch (field) {
        .themes => i18n.tr(msg.search_themes),
        .fonts => i18n.tr("Search font families…"),
    };

    // The filter box.
    const field_rect: d2d.Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = field_height };
    if (focused and self.text_field == field) {
        self.popup.drawTextInput(canvas, field_rect, t, placeholder);
    } else {
        canvas.fillRoundedRect(field_rect, 4, t.surface);
        canvas.strokeRoundedRect(field_rect, 4, t.border, 1);
        const query = self.queryOf(field).items;
        canvas.drawText(if (query.len > 0) query else placeholder, field_rect.inset(style.metrics.padding_x, 0), .{
            .size = style.font_size.body,
            .color = if (query.len > 0) t.text else t.text_disabled,
        });
    }
    self.addHit(field_rect, .{ .field = index });

    // The list.
    const box: d2d.Rect = .{ .x = rect.x, .y = rect.y + field_height + 8, .w = rect.w, .h = @max(0, rect.h - field_height - 8) };
    canvas.fillRoundedRect(box, draw.radius, t.surface);
    canvas.strokeRoundedRect(box, draw.radius, if (focused) style.mix(t.border, t.accent, 0.5) else t.border, 1);
    const visible_box = intersect(box, body);
    self.list_area = visible_box;

    const matches = list.matches.items;
    const inner_h = @max(0, box.h - 8);
    const visible: usize = @max(1, @as(usize, @intFromFloat(@floor(inner_h / item_height))));
    list.visible = visible;
    if (list.reveal) {
        list.reveal = false;
        if (list.cursor < list.top) list.top = list.cursor;
        if (list.cursor >= list.top + visible) list.top = list.cursor + 1 - visible;
    }
    list.top = @min(list.top, matches.len -| visible);

    if (matches.len == 0) {
        const empty = switch (field) {
            .themes => i18n.tr(msg.no_themes),
            .fonts => i18n.tr("No matching fonts"),
        };
        canvas.drawText(empty, box, .{ .size = style.font_size.body, .color = t.text_secondary, .align_x = .center });
        return;
    }

    const scrollbar_w: f32 = if (matches.len > visible) 8 else 0;
    canvas.pushClip(box.inset(1, 1));
    defer canvas.popClip();
    const saved: ?u32 = switch (field) {
        .themes => self.saved_theme,
        .fonts => self.fontIndex(self.font_family),
    };
    var i = list.top;
    while (i < matches.len and i < list.top + visible) : (i += 1) {
        const name_index = matches[i];
        if (name_index >= names.len) continue;
        const item_rect: d2d.Rect = .{
            .x = box.x + 4,
            .y = box.y + 4 + @as(f32, @floatFromInt(i - list.top)) * item_height,
            .w = box.w - 8 - scrollbar_w,
            .h = item_height,
        };
        const target: Target = .{ .item = .{ .row = index, .index = @intCast(i) } };
        if (i == list.cursor) {
            canvas.fillRoundedRect(item_rect, 4, if (focused) t.selected else style.mix(t.surface, t.selected, 0.6));
            if (focused) canvas.fillRoundedRect(.{ .x = item_rect.x, .y = item_rect.y + 8, .w = 3, .h = item_rect.h - 16 }, 1.5, t.accent);
        } else if (self.isHover(target)) {
            canvas.fillRoundedRect(item_rect, 4, t.hover);
        }
        var name_w = item_rect.w - 24 - 24;
        if (field == .themes) {
            const swatch_rect: d2d.Rect = .{
                .x = item_rect.x + item_rect.w - 8 - draw.swatch_width,
                .y = item_rect.y + 5,
                .w = draw.swatch_width,
                .h = item_rect.h - 10,
            };
            const colors = self.swatches.get(self.alloc, global.io(), self.theme_dirs, name_index, names[name_index]);
            draw.themeSwatch(canvas, swatch_rect, colors, t);
            name_w -= draw.swatch_width + 8;
        }
        if (saved == name_index) {
            canvas.drawIcon(draw.icons.check, .{ .x = item_rect.x + item_rect.w - 28 - (if (field == .themes) draw.swatch_width + 8 else 0), .y = item_rect.y, .w = 20, .h = item_rect.h }, 12, t.accent);
        }
        canvas.drawText(names[name_index], .{ .x = item_rect.x + 12, .y = item_rect.y, .w = @max(0, name_w), .h = item_rect.h }, .{
            .size = style.font_size.body,
            .color = t.text,
            .weight = if (saved == name_index) .semibold else .normal,
        });
        self.addHit(intersect(item_rect, body), target);
    }

    if (scrollbar_w > 0) {
        const track_h = box.h - 8;
        const len_f: f32 = @floatFromInt(matches.len);
        const thumb_h = @max(20, track_h * @as(f32, @floatFromInt(visible)) / len_f);
        const max_top: f32 = @floatFromInt(matches.len - visible);
        const thumb_y = box.y + 4 + (track_h - thumb_h) * (@as(f32, @floatFromInt(list.top)) / @max(max_top, 1));
        canvas.fillRoundedRect(.{ .x = box.x + box.w - 7, .y = thumb_y, .w = 3, .h = thumb_h }, 1.5, t.text_disabled);
    }
}

fn fontIndex(self: *Settings, family: []const u8) ?u32 {
    for (self.namesOf(.fonts), 0..) |name, i| {
        if (std.mem.eql(u8, name, family)) return @intCast(i);
    }
    return null;
}

fn intersect(a: d2d.Rect, b: d2d.Rect) d2d.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}
