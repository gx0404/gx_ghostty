//! The Ghostty GX settings overlay. Opened by `gx:settings`, the main
//! menu's Settings… item and `open_config` when `gx-open-config-ui =
//! settings` (the default); all of them call `show`, and
//! `gx:settings_page:<page>` and the command palette's "Settings: <section>"
//! entries call `showSection`. Without Direct2D the configuration file opens
//! instead.
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
//!     a switch, the font size or the button of a group, Enter and Space
//!     activate, Delete resets the focused setting, PgUp/PgDn scroll, Esc
//!     clears a filter box and then closes. The focus ring shows once the
//!     keyboard moved the focus.
//!   - Lists (themes, font families) have an IME-capable filter box that
//!     takes the typing while the list is focused (fuzzy matching,
//!     `gx.fuzzy`); typing elsewhere on a page with a list goes to its
//!     filter box. Font families also match by their name in the user's
//!     language. The font size can be typed into its field.
//!   - Buttons, cards and chips act when the left button goes up over the
//!     part it went down on; list items are picked on the press, and the
//!     size buttons repeat while held. The wheel keeps the fraction of
//!     small steps and scrolls the lines `SPI_GETWHEELSCROLLLINES` asks for;
//!     a list at its end passes the wheel on to the page.
//!   - Clicks in the first moments after opening are ignored, so the click
//!     that opened the overlay cannot also press something in it.
//!
//! Every change is recorded in a `gx.settings_map.Changes` and written to
//! the settings overlay `gui-settings.ghostty` (never to the user's
//! configuration file) after a short pause; a failed save keeps the
//! changes, shows the reason and tries again with a growing delay
//! (`settings/model.zig`). The configuration is then rebuilt from a
//! `gx.config_layers.Layers` snapshot (no file is read again; the snapshot
//! follows the changes made here) and the rows show the values it ends up
//! with. The snapshot, the theme directories and the launch profiles are
//! read by the first opening after they became stale (`loadData`) and kept
//! with the hidden overlay of the window between openings; any configuration
//! change, a UI language, DPI or system UI change, and launch profiles
//! detected anew make them stale (`onConfigChange`, `invalidateOwner`,
//! `invalidateData`). Idle preparation never reads them (`prepare`); a
//! change of the files by another program shows after a reload.
//! "Reset to Default" (the ↺ button next to
//! a setting that the settings file sets, or Delete) removes the key from
//! the file, so the configuration file or the default applies again (D13);
//! a value that comes from the configuration file or the command line says
//! so under the setting (`Layers.provenance`).
//!
//! Moving through the theme list previews themes once the cursor rests a
//! moment (a debounce: longer while typing in the filter): the
//! configuration is built from the snapshot with an in-memory `--theme`
//! override (and no reload notification) and applied without writing
//! anything; Enter, Apply or a double click keeps the theme, and closing the
//! overlay otherwise reverts the preview. Errors show in the status line.
//! The text follows the UI language, so the overlay redraws in the new
//! language as soon as a `language` change is applied.
//!
//! The theme list and its swatches and the font families stay between
//! openings. The font families are listed on a thread of their own
//! (`system.FontLoader`, `WM_FONTS_READY` when done) on the first visit to
//! Font and again after `WM_FONTCHANGE`; the last list shows meanwhile.
//! F6 focuses the sidebar search; labels, section names and configuration
//! keys match across all six sections, and Enter reveals a result.
//!
//! Each owner retains at most one hidden overlay, with only one shown at a
//! time. Configuration changes invalidate cached data and the next host.
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
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const TooltipOf = @import("Tooltip.zig").Tooltip;
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");
const Scrim = @import("settings/Scrim.zig");
const draw = @import("settings/draw.zig");
const hit_test = @import("settings/hit_test.zig");
const model = @import("settings/model.zig");
const system = @import("settings/system.zig");

const Config = configpkg.Config;
const Layers = gx.config_layers.Layers;
const i18n = gx.i18n;
const settings_map = gx.settings_map;
const msg = settings_map.msg;
const fuzzy = gx.fuzzy;
const theme_swatch = gx.theme_swatch;
const WindowMaterial = gx.config_types.WindowMaterial;

const log = std.log.scoped(.win32_settings);

// Sizes in DIPs, from the shared steps of `gx.ui_metrics` (`style`) where
// one fits; the others are the panel layout of the Windows settings design.

/// The section list on the left (design: 200), its insets and the height
/// and spacing of its items.
const sidebar_width: f32 = 200;
const sidebar_inset: f32 = style.space.s;
const sidebar_item_height: f32 = style.row.list;
const sidebar_item_gap: f32 = style.space.xs;
/// The page title band (design: 64, two `space.xxl`) and the status line
/// (design: 44, a control with `space.m` around it; no shared step).
const header_height: f32 = 64;
const footer_height: f32 = 44;
const content_pad: f32 = style.space.xl;
const top_pad: f32 = style.space.s;
const bottom_pad: f32 = style.space.l;
const row_gap: f32 = style.space.s;
/// The inner padding of a card and the gap between its parts.
const card_pad: f32 = style.space.l;
const card_inner_gap: f32 = style.space.s;
/// A card with one line: a body line with 12 above and below. No row step
/// of `ui_metrics` is 44 (`row.list` 36 would crowd the radio and switch).
const card_height: f32 = 44;
/// A card with a title and a detail line.
const card_height_detail: f32 = style.row.two_line;
/// A card with chips or buttons: a control with `space.s` around it.
const choice_height: f32 = style.control.height + 2 * style.space.s;
/// The line the chips of a choice take below its title when they do not fit
/// next to it.
const chip_line: f32 = draw.chip_height + style.space.s;
/// A group title line.
const group_height: f32 = style.row.header;
const item_height: f32 = style.row.menu;
const list_pad: f32 = style.space.xs;
const field_height: f32 = style.metrics.input_height;
const field_gap: f32 = style.space.s;
const min_list_items = 4;
/// How much of the rows below a list stays in view when the list is
/// sized, so the page shows that it goes on (about two cards; no shared
/// step).
const list_peek: f32 = 112;
/// The font sample: room for the largest sample size (no shared step).
const sample_height: f32 = 64;
/// The bounds of the panel within the window (design limits).
const min_width: f32 = 640;
const max_width: f32 = 920;
const min_height: f32 = 460;
const max_height: f32 = 680;
/// The page scrolls this much per wheel line: one list row.
const body_line: f32 = style.row.menu;

/// How long changes are collected before they are saved.
const save_delay_ms = 300;
/// Clicks this soon after opening are ignored.
const click_guard_ms = 400;
/// How often a running herdr is checked, and when it is given up.
const herdr_poll_ms = 200;
const herdr_timeout_ms = 30_000;
/// The darkness of the backdrop (0-255).
const scrim_alpha: u8 = 90;

const max_rows = 64;
const max_hits = 192;

/// Posted to the overlay by `system.FontLoader` when the font families are
/// listed.
pub const WM_FONTS_READY: u32 = w32.WM_APP + 2;

/// The currently selected overlay; hidden owners live in `instances`.
var instance: ?*Settings = null;
var instances: ?*Settings = null;

alloc: Allocator,
app: *App,
window: *Window,
next: ?*Settings = null,
data_ready: bool = false,

popup: Popup = .{},
uia_attachment: gx.ui_ref.Attachment = .{},
scrim: Scrim = .{},
tooltip: Tooltip = .{},

/// Cached paths, layers, shells and theme directories, reset on invalidation.
arena: ArenaAllocator,
/// Owns the strings of the rows built since the last paint.
scratch: ArenaAllocator,

open: bool = false,
opened_ms: u64 = 0,

section: Section = .language,
/// The focused row of the section (an index into `buildRows`).
focus: usize = 0,
/// The focused button of a focused group row.
focus_button: usize = 0,
/// The keyboard moved the focus last: the focus ring shows.
focus_visible: bool = false,
/// Scroll the focused row into view at the next paint.
reveal_focus: bool = false,
body_scroll: f32 = 0,
/// The height of the page at the last paint.
body_view: f32 = 0,
hover: ?Target = null,
/// What the left button went down on, until it goes up.
pressed: ?Target = null,
/// The pointer (DIPs) while it is over the overlay.
pointer: ?d2d.Point = null,
wheel_lines: model.Wheel = .{},

/// The values shown: the configuration the app runs with, read again
/// after every change is applied, and the changes made here meanwhile.
values: Values = undefined,
font_family: []const u8 = "",
notifications: Config.AppNotifications = .{},
/// The configuration layers, read when the overlay opens and following
/// the changes made here; null when the layering is off
/// (`GHOSTTY_GX_DEFAULTS=0`) or they could not be read.
layers: ?Layers = null,
/// `inputsDigest` of the configuration the app ran with when the overlay
/// last opened or applied one (`followReload`).
applied_inputs: u64 = 0,
applying: bool = false,
/// Whether the configuration is loaded with the Ghostty GX layers; theme
/// previews need them.
layered: bool = true,
build: u32 = 0,

/// The theme names and their swatches, kept between openings while the
/// theme directories list the same names.
themes: ?settings_map.ThemeList = null,
swatches: theme_swatch.Cache = .{},
theme_dirs: []const []const u8 = &.{},
theme_list: List = .{},
theme_query: std.ArrayList(u8) = .empty,
/// The theme in the configuration (an index into `themes.names`).
saved_theme: ?u32 = null,
/// The theme to preview and the one currently applied as a preview.
preview_theme: ?u32 = null,
applied_preview: ?u32 = null,
/// A paint left swatches unread.
swatches_pending: bool = false,
/// The `theme` of the configuration (names in `arena`): one theme, or a
/// light and dark pair whose `theme_half` the list edits.
saved_pair: ?settings_map.ThemePair = null,
/// The half of a light and dark pair the theme list shows and edits; set to
/// the system's mode when the overlay opens.
theme_half: settings_map.ThemeHalf = .dark,

/// The installed font families, kept between openings.
fonts: ?system.FontFamilies = null,
/// Lists the font families in the background.
font_loader: ?*system.FontLoader = null,
/// The cached font list is current, until WM_FONTCHANGE.
fonts_checked: bool = false,
/// What the font list shows: `fonts` and the configured family.
font_picker: system.Picker = .{ .names = &.{}, .local_names = &.{} },
/// Owns what `font_picker` adds.
font_arena: ArenaAllocator,
font_list: List = .{},
font_query: std.ArrayList(u8) = .empty,
search_query: std.ArrayList(u8) = .empty,

shells: []const Shell = &.{},
shell_selected: usize = 0,
herdr_exe: ?[]const u8 = null,
herdr_run: ?system.HerdrRun = null,

config_path: []const u8 = "",
overlay_path: []const u8 = "",

text_field: ?Field = null,

changes: settings_map.Changes,
/// Failed saves in a row (`model.saveRetryDelayMs`).
save_attempts: u32 = 0,
timers: std.EnumSet(Timer) = .empty,
reset_all: model.Confirm = .{},
measurements: draw.Measurements = .{},

status_kind: StatusKind = .none,
status_buf: [512]u8 = undefined,
status_len: usize = 0,

/// Hit-test rectangles of the last paint, later ones on top.
hits: [max_hits]Hit = undefined,
hit_count: usize = 0,
/// The hits (targets and places) the published accessible model was built
/// from (`uiaBuild`), as `hitsDigest`; null when none is published. Its
/// tokens name hits by position, so a paint that lays them out anew revokes
/// it (`checkUiaHits`).
uia_hits: ?u64 = null,
/// While the body paints: the body, which the hit rectangles of its rows
/// are cut to (`hit_test.clip`).
hit_clip: ?d2d.Rect = null,
/// Where the last paint put the list of the section, for the wheel.
list_area: ?d2d.Rect = null,

const Tooltip = TooltipOf(Tip);

/// What a tooltip describes: the buttons that only show an icon.
const Tip = union(enum) {
    none,
    close,
    reset: u16,
};

// -----------------------------------------------------------------------
// Opening and closing
// -----------------------------------------------------------------------

/// Show the settings for `window`; without Direct2D or GX configuration
/// layering, open the configuration file instead.
pub fn show(window: *Window) bool {
    const timing = Popup.OpenTiming.begin(.settings);
    if (!gx.config_layers.enabled(window.app.core_app.alloc) or window.app.uiFactory() == null) return openConfigInstead(window.app);
    const self = acquire(window) orelse return false;
    if (instance) |old| if (old != self and old.open) old.finish(.deactivated);
    instance = self;
    if (self.open) {
        if (self.popup.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
        return true;
    }
    return self.openOverlay(timing, false);
}

fn find(window: *Window) ?*Settings {
    var it = instances;
    while (it) |self| : (it = self.next) {
        if (self.window == window) return self;
    }
    return null;
}

fn acquire(window: *Window) ?*Settings {
    if (find(window)) |self| return self;

    const alloc = window.app.core_app.alloc;
    const self = alloc.create(Settings) catch |err| {
        log.err("cannot create the settings overlay err={}", .{err});
        return null;
    };
    self.* = .{
        .alloc = alloc,
        .app = window.app,
        .window = window,
        .arena = .init(alloc),
        .scratch = .init(alloc),
        .font_arena = .init(alloc),
        .changes = .init(alloc),
        .next = instances,
    };
    instances = self;
    return self;
}

test "P4 reuse keeps independent settings owners for 100 acquire close cycles" {
    var core: @import("../../../App.zig") = undefined;
    core.alloc = std.testing.allocator;
    var app: App = undefined;
    app.core_app = &core;
    var a: Window = undefined;
    var b: Window = undefined;
    a.app = &app;
    b.app = &app;
    a.hwnd = null;
    b.hwnd = null;
    defer onWindowDestroyed(&a);
    defer onWindowDestroyed(&b);
    const first = acquire(&a).?;
    const second = acquire(&b).?;
    try std.testing.expect(find(&a) != null);
    try std.testing.expect(first != second);
    first.data_ready = true;
    second.data_ready = true;
    first.config_path = try first.arena.allocator().dupe(u8, "fixture-config");
    const storage = first.config_path.ptr;
    for (0..100) |_| {
        try std.testing.expectEqual(first, acquire(&a).?);
        first.open = true;
        first.finish(.deactivated);
        try std.testing.expectEqual(second, acquire(&b).?);
        second.open = true;
        second.finish(.deactivated);
        try std.testing.expectEqual(storage, first.config_path.ptr);
        try std.testing.expect(first.data_ready and second.data_ready);
    }
    invalidateOwner(&a);
    try std.testing.expect(!first.data_ready and first.popup.reuse_invalid);
    try std.testing.expect(second.data_ready and !second.popup.reuse_invalid);
    invalidateData(&b);
    try std.testing.expect(!second.data_ready and !second.popup.reuse_invalid);
}

test "P4 idle preparation leaves settings without read data to the opening" {
    // Reading the configuration layers, the theme directories and the
    // launch profiles is file work: idle preparation never does it, and
    // creates no overlay for a window that has none.
    var core: @import("../../../App.zig") = undefined;
    core.alloc = std.testing.allocator;
    var app: App = undefined;
    app.core_app = &core;
    var window: Window = undefined;
    window.app = &app;
    window.hwnd = null;
    defer onWindowDestroyed(&window);
    try std.testing.expect(!prepare(&window));
    try std.testing.expect(find(&window) == null);
    const self = acquire(&window).?;
    try std.testing.expect(!prepare(&window));
    try std.testing.expect(!self.data_ready and self.layers == null and self.popup.hwnd == null);
}

/// Like `show`, then switch to `section`: the command palette's
/// "Settings: <section>" entries and `gx:settings_page:<page>`.
pub fn showSection(window: *Window, section: Section) bool {
    if (!show(window)) return false;
    const self = instance orelse return true;
    if (!self.open) return true;
    if (self.section != section or self.searching() or self.text_field == .search) self.enterSection(section);
    return true;
}

/// `window` is going away: save pending changes, end a theme preview and
/// destroy the overlay if it belongs to that window.
pub fn onWindowDestroyed(window: *Window) void {
    if (window.hwnd) |owner| @import("MenuPopup.zig").onOwnerDestroyed(owner);
    if (find(window)) |self| self.destroy();
}

pub fn isOpen(window: *Window) bool {
    const self = find(window) orelse return false;
    return self.open;
}

pub fn invalidateOwner(window: *Window) void {
    const self = find(window) orelse return;
    self.data_ready = false;
    self.popup.reuse_invalid = true;
}

/// The launch profiles were detected again with another result
/// (`Menu.onShellsDetected`): read the data again at the next opening. The
/// host stays, and an open overlay keeps what it shows.
pub fn invalidateData(window: *Window) void {
    const self = find(window) orelse return;
    self.data_ready = false;
}

/// Idle preparation (`Menu.prepareIdle`) of the hidden overlay of
/// `window`: lay it out and paint it hidden, only with the data an earlier
/// opening read and nothing made stale since. It reads no file: the
/// configuration layers, the theme directories and the launch profiles are
/// read by the next opening (`loadData`). Returns whether it prepared.
pub fn prepare(window: *Window) bool {
    if (!gx.config_layers.enabled(window.app.core_app.alloc)) return false;
    const self = find(window) orelse return false;
    if (self.open or !self.data_ready) return false;
    return self.openOverlay(null, true);
}

pub fn onConfigChange(app: *App) void {
    var it = instances;
    while (it) |self| : (it = self.next) {
        if (self.app != app) continue;
        self.data_ready = false;
        self.popup.reuse_invalid = true;
        if (!self.open or self.applying) continue;
        self.followConfigChange();
    }
}

fn followConfigChange(self: *Settings) void {
    self.stopTimer(.preview);
    self.preview_theme = null;
    self.applied_preview = null;
    self.followReload();
    self.applied_inputs = inputsDigest(&self.app.config);
    self.swatches.deinit(self.alloc);
    self.loadThemes(&self.app.config);
    self.loadShells();
    self.configApplied(false);
    self.popup.setAccessibleName(i18n.tr(msg.settings));
}

fn openConfigInstead(app: *App) bool {
    log.info("opening the configuration file instead of the unavailable settings overlay", .{});
    return app.openConfigFile(.os_open) catch |err| {
        log.warn("cannot open the configuration file err={}", .{err});
        return false;
    };
}

fn destroy(self: *Settings) void {
    self.finish(.owner);
    inline for (comptime std.enums.values(Timer)) |timer| self.stopTimer(timer);
    if (self.herdr_run) |*run| run.deinit();
    self.herdr_run = null;
    self.tooltip.destroy();
    if (self.popup.hwnd) |hwnd| {
        // Windows destroys owned windows with their owner.
        if (!Scrim.isOwnWindow(hwnd, &self.popup)) self.popup.hwnd = null;
    }
    self.popup.destroy();
    self.scrim.destroy();
    self.releaseData();
    if (self.font_loader) |loader| loader.detach();
    self.font_loader = null;
    if (self.fonts) |*fonts| fonts.deinit();
    self.fonts = null;
    if (self.themes) |*themes| themes.deinit();
    self.themes = null;
    self.swatches.deinit(self.alloc);
    self.theme_query.deinit(self.alloc);
    self.font_query.deinit(self.alloc);
    self.search_query.deinit(self.alloc);
    self.theme_list.deinit(self.alloc);
    self.font_list.deinit(self.alloc);
    self.changes.deinit();
    self.font_arena.deinit();
    self.arena.deinit();
    self.scratch.deinit();
    if (instance == self) instance = null;
    var link = &instances;
    while (link.*) |entry| : (link = &entry.next) {
        if (entry != self) continue;
        link.* = self.next;
        break;
    }
    self.alloc.destroy(self);
}

fn openOverlay(self: *Settings, opened: ?Popup.OpenTiming, preparing: bool) bool {
    var timing = opened;
    const owner = self.window.hwnd orelse return false;
    if (self.window.closing) return false;
    self.uia_attachment = self.window.ui_attachment;
    const factory = self.app.uiFactory() orelse return if (preparing) false else openConfigInstead(self.app);
    const t = self.tokens();
    // Until the first frame is painted (`Popup.show` paints at once).
    const span = if (!preparing) gx.perf.Span.begin(global.io()) else null;
    defer if (span) |value| {
        _ = value.end(global.io(), "settings_open");
    };
    if (timing) |*value| value.lap(.prepare);

    if (self.popup.reuse_invalid) {
        // Detach asynchronous HWND recipients before replacing a hidden host.
        if (self.font_loader) |loader| {
            loader.detach();
            self.fonts_checked = false;
        }
        self.font_loader = null;
        inline for (comptime std.enums.values(Timer)) |timer| self.stopTimer(timer);
        self.tooltip.destroy();
        self.popup.destroy();
        self.scrim.destroy();
    }
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
            .accessible_name = i18n.tr(msg.settings),
            .reuse_host = true,
        }, .{
            .ctx = self,
            .paint = paint,
            .uia_source = .{ .app = self.app, .build = uiaBuild, .is_live = uiaLive, .action = uiaAction },
            .key = onKey,
            .mouse = onMouse,
            .text_changed = onTextChanged,
            .dismissed = onDismissed,
            .dpi_changed = onDpiChanged,
            .timer = onPopupTimer,
            .repeat = onRepeat,
            .message = onMessage,
        }) catch |err| {
            log.err("cannot create the settings popup err={}", .{err});
            return if (preparing) false else openConfigInstead(self.app);
        };
    }
    if (self.scrim.hwnd == null) {
        self.scrim.create(self.app.hinstance, owner, scrim_alpha, .{
            .ctx = self,
            .click = onScrimClick,
            .font_change = onFontChange,
        }) catch |err| {
            log.warn("cannot create the settings backdrop err={}", .{err});
        };
    }

    // A replaced HWND also replaced its timers. Hidden failed saves and the
    // user's existing shell helper keep their bounded retry/poll lifecycle.
    if (!self.changes.isEmpty() and !self.timers.contains(.save)) {
        if (model.saveRetryDelayMs(self.save_attempts)) |delay| self.startTimer(.save, delay);
    }
    if (self.herdr_run != null and !self.timers.contains(.herdr)) self.startTimer(.herdr, herdr_poll_ms);

    if (timing) |*value| value.lap(.create);
    if (!self.data_ready) self.loadData();
    self.theme_query.clearRetainingCapacity();
    self.font_query.clearRetainingCapacity();
    // A pair opens on the theme the system shows now.
    self.theme_half = .ofSystem(!self.app.appsUseLightTheme());
    self.saved_theme = self.savedThemeIndex();
    self.refilter(.themes);
    self.refilter(.fonts);
    // The lists open on the configured theme and font family.
    if (self.saved_theme) |saved| self.theme_list.select(saved);
    if (self.font_picker.indexOf(self.font_family)) |index| self.font_list.select(index);
    self.clearStatus();
    self.pointer = null;
    self.hover = null;
    self.pressed = null;
    self.focus_visible = false;
    self.reset_all.cancel();
    self.wheel_lines.reset();
    if (timing) |*value| value.lap(.prepare);
    self.enterSection(self.section);

    self.popup.setOwnerScale(self.window.scale);
    const rect = self.popupRect(owner);
    if (preparing) {
        self.popup.prepareHidden(rect);
        return true;
    }
    const maximized = w32.IsZoomed(owner) != 0 or self.window.title_bar.is_fullscreen;
    self.scrim.show(Scrim.visibleBounds(owner), !maximized);
    if (timing) |*value| value.lap(.layout);
    self.popup.open_timing = timing;
    self.open = true;
    self.popup.show(rect);
    self.opened_ms = system.nowMs();
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
    self.stopTimer(.prefetch);
    self.endSizeEdit(true);
    const previewed = self.applied_preview != null;
    self.preview_theme = null;
    self.applied_preview = null;
    // Saving applies the saved configuration, which ends the preview.
    const applied = !self.changes.isEmpty() and self.saveNow();
    if (previewed and !applied) _ = self.applyConfig(null, true);
    if (self.popup.hwnd) |hwnd| self.tooltip.setTarget(hwnd, .none);
    self.tooltip.hide();
    self.scrim.hide();
    self.popup.hide();
    self.text_field = null;
    self.popup.input.clear();
    if (how == .user) self.window.focusActiveSurface();
}

fn popupRect(self: *Settings, owner: w32.HWND) w32.RECT {
    const bounds = Scrim.visibleBounds(owner);
    const scale = self.window.scale;
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

fn uiaLive(context: *anyopaque) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    return self.open and self.popup.visible and uia_bridge.attachmentAlive(self.app, self.uia_attachment);
}
fn uiaControlState(self: *Settings, target: Target, rows: []const Row) uia_bridge.ControlState {
    var state: uia_bridge.ControlState = .{};
    switch (target) {
        .search => {
            state.focusable = true;
            state.focused = self.popup.focused and self.text_field == .search;
        },
        .row => |index| {
            state.enabled = index < rows.len;
            state.focusable = state.enabled and rows[index].focusable();
            state.focused = self.popup.focused and self.text_field == null and self.focus == index;
        },
        .chip => |chip| {
            state.enabled = chip.row < rows.len and chip.index < rows[chip.row].choices.len and chip.index < 8 and
                rows[chip.row].disabled & (@as(u8, 1) << @intCast(chip.index)) == 0;
            state.container_focusable = chip.row < rows.len and rows[chip.row].focusable();
            state.container_focused = state.container_focusable and self.popup.focused and self.text_field == null and self.focus == chip.row;
        },
        .step => |step| {
            state.enabled = if (step.step == .minus) self.values.font_size > settings_map.FontSize.min else self.values.font_size < settings_map.FontSize.max;
        },
        .value => |index| {
            state.enabled = index < rows.len;
            state.focusable = true;
            state.focused = self.popup.focused and self.text_field == .font_size;
        },
        .field => |index| {
            state.enabled = index < rows.len;
            state.focusable = true;
            state.focused = self.popup.focused and state.enabled and self.text_field == listField(rows[index].action) and self.focus == index;
        },
        .group_button => |item| {
            state.enabled = item.row < rows.len and self.groupButtonEnabled(item.button);
            state.focusable = true;
            if (item.row < rows.len) {
                if (std.mem.indexOfScalar(GroupButton, rows[item.row].buttons, item.button)) |index|
                    state.focused = self.popup.focused and self.text_field == null and self.focus == item.row and self.focus_button == index;
            }
        },
        .section, .close, .item, .reset => {},
    }
    return state;
}
fn uiaBuild(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
    const self: *Settings = @ptrCast(@alignCast(context));
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    var states: [max_hits]uia_bridge.ControlState = undefined;
    for (self.hits[0..self.hit_count], 0..) |hit, index| states[index] = self.uiaControlState(hit.target, rows);
    const published = bridge.publisher.current;
    try bridge.publishSettings(api, queue, self.uia_attachment, self, rows, states[0..self.hit_count], .{ .context = self, .is_live = uiaLive, .action = uiaAction });
    if (bridge.publisher.current != published) self.notePublishedHits();
}

/// The hits of the last paint are what the accessible model now published
/// was built from.
fn notePublishedHits(self: *Settings) void {
    self.uia_hits = self.hitsDigest();
}

/// The targets and places of the hits of the last paint.
fn hitsDigest(self: *const Settings) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, self.hit_count);
    for (self.hits[0..self.hit_count]) |hit| {
        std.hash.autoHash(&hasher, hit.target);
        hasher.update(std.mem.asBytes(&hit.rect));
    }
    return hasher.final();
}

/// After a paint laid the hits out: when they differ from those of the
/// published accessible model (a scroll that revealed the focus, another
/// section), its elements would act on other controls now. Revoke them; the
/// paint publishes the new layout (`Popup.uiaLayoutChanged`).
fn checkUiaHits(self: *Settings) void {
    const published = self.uia_hits orelse return;
    if (published == self.hitsDigest()) return;
    self.uia_hits = null;
    self.popup.uiaLayoutChanged();
}

fn uiaAction(context: *anyopaque, token: u64, action: *const uia.Action) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    if (!uiaLive(context)) return false;
    if (token == 0 and action.kind == .close) {
        self.popup.dismiss(.owner);
        return true;
    }
    if (token < uia_bridge.settings_hit_base or token == uia_bridge.settings_container) return false;
    const hit_index = std.math.cast(usize, token - uia_bridge.settings_hit_base) orelse return false;
    if (hit_index >= self.hit_count) return false;
    const target = self.hits[hit_index].target;
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    const control_state = self.uiaControlState(target, rows);
    if (!control_state.enabled and !(action.kind == .focus and control_state.container_focusable)) return false;
    const hwnd = self.popup.hwnd orelse return false;
    const cookie = self.popup.uia_cookie;
    if (action.kind == .set_value) {
        if (std.mem.indexOfAny(u8, action.value, "\r\n") != null) return false;
        switch (target) {
            .search => self.focusSearch(false),
            .field => |index| self.focusRow(index),
            .value => {
                if (model.parseFontSize(action.value) == null) return false;
                self.beginSizeEdit(action.value, false);
                self.endSizeEdit(true);
                return true;
            },
            else => return false,
        }
        if (!Popup.uiaAlive(hwnd, cookie)) return false;
        self.popup.input.setText(self.alloc, action.value) catch return false;
        onTextChanged(self, &self.popup);
        return true;
    }
    if (action.kind == .focus) {
        switch (target) {
            .search => self.focusSearch(false),
            .row, .field => |index| self.focusRow(index),
            .chip => |chip| self.focusRow(chip.row),
            .value => |index| {
                const alloc = self.alloc;
                const value = alloc.dupe(u8, rows[index].value) catch return false;
                defer alloc.free(value);
                self.focusRow(index);
                if (!Popup.uiaAlive(hwnd, cookie)) return false;
                self.beginSizeEdit(value, true);
            },
            .group_button => |item| {
                const button_index = std.mem.indexOfScalar(GroupButton, rows[item.row].buttons, item.button);
                self.focusRow(item.row);
                if (!Popup.uiaAlive(hwnd, cookie)) return false;
                if (button_index) |index| self.focus_button = index;
            },
            else => return false,
        }
        if (!Popup.uiaAlive(hwnd, cookie)) return false;
        self.showUiaFocus();
        _ = w32.SetFocus(hwnd);
        return true;
    }
    if (action.kind != .invoke and action.kind != .toggle and action.kind != .select) return false;
    switch (target) {
        .step => |step| self.stepFontSize(step.step),
        .item => self.press(&self.popup, target, action.kind == .invoke),
        else => self.click(target),
    }
    return true;
}

fn showUiaFocus(self: *Settings) void {
    self.focus_visible = true;
    // Focus rings do not change the hit-token mapping. Earlier helpers may
    // have committed an edit and invalidated it; reporting the focus must
    // not undo that.
    self.popup.focusMoved();
}

test "UIA settings focus preserves the retained Toggle provider until a model edit" {
    const testing = std.testing;
    var api: uia.Api = undefined;
    api.count = .init(1);
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: gx.ui_ref.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const nodes = [_]uia.NodeSpec{
        .{ .id = 1, .name = "Settings", .role = .window },
        .{ .id = 2, .parent = 0, .name = "Scrollbar", .role = .checkbox, .patterns = .{ .toggle = true } },
    };
    var self: Settings = .{
        .alloc = testing.allocator,
        .app = undefined,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
    };
    defer self.arena.deinit();
    defer self.scratch.deinit();
    defer self.font_arena.deinit();
    defer self.changes.deinit();
    defer self.popup.destroy();
    // Popup.create normally supplies the input allocator; this fixture never
    // creates an HWND, so initialize the same ownership explicitly.
    self.popup.input.alloc = testing.allocator;
    try self.popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    const snapshot = self.popup.uia_view.publisher.current.?;
    const provider = &snapshot.nodes[1].faces[0];
    const Abi = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    const abi: *const Abi = @ptrCast(@alignCast(provider.vtable));
    _ = abi.AddRef(provider);
    defer _ = abi.Release(provider);
    const action: uia.Action = .{ .attachment = attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .toggle, .value = &.{}, .alloc = testing.allocator };
    var options: u32 = 0;
    self.showUiaFocus();
    try testing.expect(self.focus_visible);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    try testing.expect(self.popup.uia_view.publisher.accepts(action));
    // Entering an editor is focus-only; applying/leaving an edited value is
    // not, and continues to use the original model invalidation paths.
    self.focusSearch(false);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    self.beginSizeEdit("14", true);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    try testing.expect(self.popup.uia_view.publisher.accepts(action));
    self.invalidate();
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), abi.ProviderOptions(provider, &options));
    try testing.expect(!self.popup.uia_view.publisher.accepts(action));
}

// Exercise the real Settings key handler and accessible model with a hidden
// popup. Only painting is replaced: the two button hits stand for its layout.
const GroupFocusProbe = struct {
    const Simple = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
        GetPatternProvider: *const fn (*uia.Face, i32, *?*uia.Face) callconv(.winapi) i32,
        GetPropertyValue: *const fn (*uia.Face, i32, *uia.Variant) callconv(.winapi) i32,
    };
    const Root = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ElementProviderFromPoint: *const fn (*uia.Face, f64, f64, *?*uia.Face) callconv(.winapi) i32,
        GetFocus: *const fn (*uia.Face, *?*uia.Face) callconv(.winapi) i32,
    };
    fn simple(face: *uia.Face) *const Simple {
        return @ptrCast(@alignCast(face.vtable));
    }
    fn paint(ctx: *anyopaque, _: *Popup, _: *d2d.Canvas) void {
        const self: *Settings = @ptrCast(@alignCast(ctx));
        self.checkUiaHits();
    }
    fn check(root: *uia.Face, buttons: [2]*uia.Face, focused: usize) !void {
        for (buttons, 0..) |face, index| {
            var options: u32 = 0;
            try std.testing.expectEqual(@as(i32, 0), simple(face).ProviderOptions(face, &options));
            var value: uia.Variant = .{};
            try std.testing.expectEqual(@as(i32, 0), simple(face).GetPropertyValue(face, 30008, &value));
            try std.testing.expectEqual(@as(u16, 11), value.tag);
            try std.testing.expectEqual(index == focused, value.data.integer != 0);
        }
        const table: *const Root = @ptrCast(@alignCast(root.vtable));
        var focus: ?*uia.Face = null;
        try std.testing.expectEqual(@as(i32, 0), table.GetFocus(root, &focus));
        const face = focus orelse return error.TestUnexpectedResult;
        defer _ = simple(face).Release(face);
        try std.testing.expectEqual(buttons[focused].node, face.node);
    }
    fn run(section: Section) !void {
        const testing = std.testing;
        // UiaTestClient compares ASCII event names. Keep this fixture's
        // language explicit and restore the process setting on every exit.
        const language = i18n.current();
        i18n.setCurrent(.en);
        defer i18n.setCurrent(language);
        const attachment: gx.ui_ref.Attachment = .{
            .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
            .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
            .revision = 1,
        };
        var fixture: Popup.UiaTestClient.AppFixture = undefined;
        try fixture.init(attachment);
        defer fixture.deinit();
        var config = try Config.default(testing.allocator);
        defer config.deinit();
        const factory = try d2d.Factory.create(testing.allocator);
        defer factory.destroy();
        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        const owner = w32.CreateWindowExW(0, class, class, 0, -32000, -32000, 32, 32, null, null, null, null) orelse return error.TestWindowFailed;
        defer _ = w32.DestroyWindow(owner);
        var self: Settings = .{
            .alloc = testing.allocator,
            .app = &fixture.app,
            .window = &fixture.window,
            .arena = .init(testing.allocator),
            .scratch = .init(testing.allocator),
            .font_arena = .init(testing.allocator),
            .changes = .init(testing.allocator),
            .layers = .{ .arena = .init(testing.allocator) },
            .values = .fromConfig(&config, null),
            .section = section,
            .open = true,
            .uia_attachment = attachment,
        };
        defer self.arena.deinit();
        defer self.scratch.deinit();
        defer self.font_arena.deinit();
        defer self.changes.deinit();
        defer self.layers.?.deinit();
        defer self.theme_list.deinit(testing.allocator);
        defer self.font_query.deinit(testing.allocator);
        defer self.popup.destroy();
        try self.layers.?.setOverlay(if (section == .appearance) "theme" else "font-family", &.{"Test"});
        try self.theme_list.matches.append(testing.allocator, 0);
        try self.font_query.appendSlice(testing.allocator, "Test");
        var rows_buf: [max_rows]Row = undefined;
        const rows = self.buildRows(&rows_buf);
        self.focus = for (rows, 0..) |row, index| {
            if (row.kind == .group and row.buttons.len == 2) break index;
        } else return error.TestUnexpectedResult;
        const row = rows[self.focus];
        try testing.expectEqual(GroupButton.reset, row.buttons[0]);
        for (row.buttons, 0..) |button, index| self.hits[index] = .{
            .rect = .{ .x = @as(f32, @floatFromInt(index)) * 120, .y = 0, .w = 100, .h = 24 },
            .target = .{ .group_button = .{ .row = @intCast(self.focus), .button = button } },
        };
        self.hit_count = 2;
        try self.popup.create(fixture.app.hinstance, owner, factory, .{}, .{
            .ctx = &self,
            .paint = GroupFocusProbe.paint,
            .uia_source = .{ .app = &fixture.app, .build = uiaBuild, .is_live = uiaLive, .action = uiaAction },
        });
        // Never show or activate this window on the desktop.
        self.popup.visible = true;
        self.popup.focused = true;
        const client = try Popup.UiaTestClient.create(self.popup.hwnd.?);
        defer client.destroy(&fixture.app);
        try client.ready(&fixture.app);
        client.settle(&fixture.app, 200);
        const snapshot = self.popup.uia_view.publisher.current.?;
        const snapshot_id = snapshot.id;
        const buttons: [2]*uia.Face = .{ &snapshot.nodes[1].faces[0], &snapshot.nodes[2].faces[0] };
        const root = &snapshot.nodes[0].faces[2];
        for (buttons) |face| _ = simple(face).AddRef(face);
        _ = simple(root).AddRef(root);
        defer for (buttons) |face| {
            _ = simple(face).Release(face);
        };
        defer _ = simple(root).Release(root);
        try check(root, buttons, 0);
        for ([_]u16{ w32.VK_RIGHT, w32.VK_RIGHT, w32.VK_LEFT, w32.VK_LEFT }, [_]usize{ 1, 1, 0, 0 }, 0..) |vk, index, step| {
            client.clear();
            try testing.expect(onKey(&self, &self.popup, .{ .vk = vk, .ctrl = false, .shift = false, .alt = false }));
            try testing.expectEqual(index, self.focus_button);
            try check(root, buttons, index);
            try testing.expectEqual(snapshot, self.popup.uia_view.publisher.current.?);
            try testing.expectEqual(snapshot_id, self.popup.uia_view.publisher.current.?.id);
            try testing.expect(self.focus_visible);
            const label = if (index == 0) i18n.tr("Reset") else if (section == .appearance) i18n.tr("Apply Theme") else i18n.tr("Apply Font");
            const name = try testing.allocator.print("{s}: {s}", .{ row.title, label });
            defer testing.allocator.free(name);
            if (step % 2 == 0) try client.expect(&fixture.app, .focus, name);
            client.settle(&fixture.app, 100);
            try testing.expectEqual(@as(usize, if (step % 2 == 0) 1 else 0), client.times(.focus, name));
        }
        // A changed hit layout must still revoke every retained provider.
        self.hits[0].rect.y += 24;
        self.checkUiaHits();
        var options: u32 = 0;
        for (buttons) |face| try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), simple(face).ProviderOptions(face, &options));
        self.popup.visible = false;
    }
};

test "UIA settings theme group arrows preserve providers and report focus to a real client" {
    try GroupFocusProbe.run(.appearance);
}

test "UIA settings font group arrows preserve providers and report focus to a real client" {
    try GroupFocusProbe.run(.font);
}

test "UIA settings hover and press feedback keep the retained provider" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    var api: uia.Api = undefined;
    api.count = .init(1);
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: gx.ui_ref.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const nodes = [_]uia.NodeSpec{
        .{ .id = 1, .name = "Settings", .role = .window },
        .{ .id = 2, .parent = 0, .name = "Scrollbar", .role = .checkbox, .patterns = .{ .toggle = true } },
    };
    var self: Settings = .{
        .alloc = testing.allocator,
        .app = undefined,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
        .values = .fromConfig(&config, null),
    };
    defer self.arena.deinit();
    defer self.scratch.deinit();
    defer self.font_arena.deinit();
    defer self.changes.deinit();
    defer self.popup.destroy();
    // Popup.create normally supplies the input allocator; this fixture never
    // creates an HWND, so initialize the same ownership explicitly.
    self.popup.input.alloc = testing.allocator;
    try self.popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    const snapshot = self.popup.uia_view.publisher.current.?;
    const provider = &snapshot.nodes[1].faces[0];
    const Abi = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    const abi: *const Abi = @ptrCast(@alignCast(provider.vtable));
    _ = abi.AddRef(provider);
    defer _ = abi.Release(provider);
    const action: uia.Action = .{ .attachment = attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .toggle, .value = &.{}, .alloc = testing.allocator };
    var options: u32 = 0;
    // The pointer moving over the overlay and leaving it only changes colors.
    self.setHover(.close);
    self.setHover(.{ .row = 1 });
    self.setHover(null);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    try testing.expect(self.popup.uia_view.publisher.accepts(action));
    // Pressing a button or a row shows it pressed; it acts on release. A
    // press on a field only moves the focus.
    self.press(&self.popup, .close, false);
    try testing.expect(std.meta.eql(self.pressed, @as(?Target, .close)));
    self.press(&self.popup, .{ .row = 1 }, false);
    self.press(&self.popup, .{ .field = 0 }, false);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    // Released elsewhere, and a press on empty space: only the look changes.
    onMouse(&self, &self.popup, .{ .kind = .up, .button = .left, .pos = .{ .x = -100, .y = -100 } });
    try testing.expect(self.pressed == null);
    onMouse(&self, &self.popup, .{ .kind = .down, .button = .left, .pos = .{ .x = -100, .y = -100 } });
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    try testing.expect(self.popup.uia_view.publisher.accepts(action));
    // A model edit still revokes it.
    self.invalidate();
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), abi.ProviderOptions(provider, &options));
}

test "UIA settings revokes its elements when a paint lays their hits out anew" {
    // Settings tokens name hits by position (`uia_bridge.settings_hit_base`
    // + index). A paint that scrolls (a revealed focus) or lays the hits out
    // otherwise would leave a retained element acting on another control:
    // it is revoked, and that paint publishes the new layout. A paint with
    // the same layout (a focus ring, a hover) keeps it.
    const testing = std.testing;
    var api: uia.Api = undefined;
    api.count = .init(1);
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: gx.ui_ref.Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const nodes = [_]uia.NodeSpec{
        .{ .id = 1, .name = "Settings", .role = .window },
        .{ .id = 2, .parent = 0, .name = "Scrollbar", .role = .checkbox, .patterns = .{ .toggle = true } },
        .{ .id = 3, .parent = 0, .name = "Bell", .role = .checkbox, .patterns = .{ .toggle = true } },
    };
    var self: Settings = .{
        .alloc = testing.allocator,
        .app = undefined,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
    };
    defer self.arena.deinit();
    defer self.scratch.deinit();
    defer self.font_arena.deinit();
    defer self.changes.deinit();
    defer self.popup.destroy();
    self.popup.input.alloc = testing.allocator;
    self.hits[0] = .{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 }, .target = .{ .row = 0 } };
    self.hits[1] = .{ .rect = .{ .x = 0, .y = 20, .w = 100, .h = 20 }, .target = .{ .row = 1 } };
    self.hit_count = 2;
    try self.popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    self.popup.uia_view.needs_publish = false;
    self.notePublishedHits();
    const snapshot = self.popup.uia_view.publisher.current.?;
    const provider = &snapshot.nodes[1].faces[0];
    const Abi = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    const abi: *const Abi = @ptrCast(@alignCast(provider.vtable));
    _ = abi.AddRef(provider);
    defer _ = abi.Release(provider);
    const action: uia.Action = .{ .attachment = attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .toggle, .value = &.{}, .alloc = testing.allocator };
    var options: u32 = 0;
    // The next paint lays the same hits out again.
    self.checkUiaHits();
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
    try testing.expect(self.popup.uia_view.publisher.accepts(action));
    // A paint that scrolled by a row: the same tokens name other rows now.
    self.hits[0] = .{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 }, .target = .{ .row = 1 } };
    self.hits[1] = .{ .rect = .{ .x = 0, .y = 20, .w = 100, .h = 20 }, .target = .{ .row = 2 } };
    self.checkUiaHits();
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), abi.ProviderOptions(provider, &options));
    try testing.expect(!self.popup.uia_view.publisher.accepts(action));
    try testing.expect(self.popup.uia_view.needs_publish and self.uia_hits == null);
}

// -----------------------------------------------------------------------
// Data
// -----------------------------------------------------------------------

/// The values the rows show.
const Values = struct {
    language: i18n.Language,
    material: WindowMaterial,
    /// Null for a value no choice offers.
    opacity: ?settings_map.Opacity,
    padding: ?settings_map.Padding,
    cursor_style: settings_map.CursorStyle,
    cursor_blink: bool,
    font_size: f32,
    right_click: Config.RightClickAction,
    scrollbar: bool,
    close_confirmation: Config.ConfirmCloseSurface,
    focus_follows_mouse: bool,
    ctrl_scroll_zoom: bool,
    bell: Config.BellFeatures,
    /// Null for a color of its own (`accent_color`), which is shown, not
    /// chosen (`settings_map.Accent`).
    accent: ?settings_map.Accent,
    accent_color: Config.Color,
    /// The accent each choice gives with the current theme, in the order of
    /// `accents`.
    accent_dots: [accents.len]d2d.Color,

    fn fromConfig(config: *const Config, layers: ?*const Layers) Values {
        const padding_keys = settings_map.Padding.keys;
        const accent_config = config.@"gx-accent-color";
        return .{
            .language = i18n.resolve(config.language),
            .material = config.@"gx-window-material",
            .opacity = settings_map.Opacity.fromConfig(config.@"background-opacity", configured(layers, "background-opacity")),
            .padding = settings_map.Padding.fromConfig(
                config.@"window-padding-x",
                config.@"window-padding-y",
                configured(layers, padding_keys[0]) or configured(layers, padding_keys[1]),
            ),
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink" orelse true,
            .font_size = settings_map.FontSize.normalize(config.@"font-size"),
            .right_click = config.@"right-click-action",
            .scrollbar = config.scrollbar == .system,
            .close_confirmation = config.@"confirm-close-surface",
            .focus_follows_mouse = config.@"focus-follows-mouse",
            .ctrl_scroll_zoom = config.@"gx-ctrl-scroll-zoom",
            .bell = config.@"bell-features",
            .accent = settings_map.Accent.fromConfig(accent_config),
            .accent_color = switch (accent_config) {
                .color => |color| color,
                .brand, .theme => .{ .r = 0, .g = 0, .b = 0 },
            },
            .accent_dots = accentDots(config),
        };
    }

    /// The accent of each choice of `accents` with the colors of `config`.
    fn accentDots(config: *const Config) [accents.len]d2d.Color {
        var scheme = gx.ui_tokens.Scheme.fromConfig(config);
        var dots: [accents.len]d2d.Color = undefined;
        for (accents, &dots) |choice, *dot| {
            scheme.accent = switch (choice) {
                .brand => .brand,
                .theme => .theme,
            };
            dot.* = gx.ui_tokens.Tokens.derive(scheme).accent;
        }
        return dots;
    }

    /// Whether a layer above the defaults sets `key`; without the layers,
    /// the configuration sets everything it has.
    fn configured(layers: ?*const Layers, key: []const u8) bool {
        const l = layers orelse return true;
        const layer = l.provenance(key) orelse return false;
        return layer != .defaults;
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

fn layersPtr(self: *Settings) ?*Layers {
    return if (self.layers) |*layers| layers else null;
}

fn loadData(self: *Settings) void {
    self.releaseData();
    const config = &self.app.config;
    const arena = self.arena.allocator();

    self.layered = gx.config_layers.enabled(self.alloc);
    if (self.layered) {
        self.layers = App.loadLayers(self.alloc) catch |err| layers: {
            log.warn("cannot read the configuration layers, previews read the files err={}", .{err});
            break :layers null;
        };
        // Changes a failed save keeps (it is tried again).
        if (self.layersPtr()) |layers| self.changes.applyToLayers(layers) catch |err| {
            log.warn("cannot keep the unsaved settings err={}", .{err});
        };
    }
    self.applied_inputs = inputsDigest(config);
    self.values = .fromConfig(config, self.layersPtr());
    self.notifications = config.@"app-notifications";
    self.build = system.windowsBuild();
    self.font_family = self.configuredFamily(arena);

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
    self.updateFontPicker();
    self.data_ready = true;
}

/// The first configured font family, in `alloc`.
fn configuredFamily(self: *Settings, alloc: Allocator) []const u8 {
    const families = self.app.config.@"font-family".list.items;
    if (families.len == 0) return "";
    return alloc.dupe(u8, families[0]) catch "";
}

/// Frees what was loaded for one opening; the theme and font lists stay.
fn releaseData(self: *Settings) void {
    self.data_ready = false;
    if (self.layers) |*layers| layers.deinit();
    self.layers = null;
    self.theme_list.clear();
    self.font_list.clear();
    self.theme_query.clearRetainingCapacity();
    self.font_query.clearRetainingCapacity();
    self.search_query.clearRetainingCapacity();
    self.shells = &.{};
    self.theme_dirs = &.{};
    self.herdr_exe = null;
    self.font_family = "";
    self.config_path = "";
    self.overlay_path = "";
    self.font_picker = .{ .names = &.{}, .local_names = &.{} };
    _ = self.font_arena.reset(.retain_capacity);
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

    var listed = settings_map.listThemes(self.alloc, global.io(), dirs.items) catch |err| list: {
        log.warn("cannot list the themes err={}", .{err});
        break :list null;
    };
    if (listed) |*new| {
        const same = if (self.themes) |*old| sameNames(old.names, new.names) else false;
        if (same) {
            new.deinit();
        } else {
            if (self.themes) |*old| old.deinit();
            self.themes = new.*;
            // Swatches are kept by index.
            self.swatches.deinit(self.alloc);
        }
    }
    self.rememberTheme(config);
    self.refilter(.themes);
    if (self.saved_theme) |saved| self.theme_list.select(saved);
}

fn sameNames(a: []const [:0]const u8, b: []const [:0]const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Keeps the `theme` of `config` (`saved_pair`) and marks the theme the
/// list edits (`saved_theme`).
fn rememberTheme(self: *Settings, config: *const Config) void {
    self.saved_pair = null;
    if (settings_map.ThemePair.fromConfig(config.theme)) |pair| {
        const arena = self.arena.allocator();
        const light = arena.dupe(u8, pair.light) catch return;
        const dark = if (pair.isPair()) (arena.dupe(u8, pair.dark) catch return) else light;
        self.saved_pair = .{ .light = light, .dark = dark };
    }
    self.saved_theme = self.savedThemeIndex();
}

/// The light and dark pair of the configuration, null for one theme.
fn themePair(self: *const Settings) ?settings_map.ThemePair {
    const pair = self.saved_pair orelse return null;
    return if (pair.isPair()) pair else null;
}

/// The theme the list edits: the configured one, or its `theme_half` of a
/// pair (an index into `themes.names`).
fn savedThemeIndex(self: *const Settings) ?u32 {
    const pair = self.saved_pair orelse return null;
    const name = if (pair.isPair()) self.theme_half.name(pair) else pair.light;
    const list = if (self.themes) |*themes| themes else return null;
    const index = list.indexOf(name) orelse return null;
    return @intCast(index);
}

fn loadShells(self: *Settings) void {
    const arena = self.arena.allocator();
    const overlay_command = self.overlayValue(arena, "command");

    var shells: std.ArrayList(Shell) = .empty;
    shells.append(arena, .{ .command = null, .name = msg.system_default, .kind = .system_default }) catch return;
    var selected: ?usize = if (overlay_command == null) 0 else null;

    if (self.app.cachedLaunchProfiles()) |list_| {
        var list = list_;
        defer list.deinit();
        for (list.profiles) |profile| {
            const command = settings_map.profileCommand(arena, profile, .native) catch continue;
            const exe: ?[:0]const u8 = switch (profile.command) {
                .argv => |argv| if (argv.len > 0) arena.dupeSentinel(u8, argv[0], 0) catch null else null,
                .command_line => null,
            };
            if (profile.kind == .herdr) self.herdr_exe = exe;
            shells.append(arena, .{
                .command = command,
                .name = arena.dupeSentinel(u8, profile.name, 0) catch continue,
                .name_arg = if (profile.name_arg) |arg| arena.dupeSentinel(u8, arg, 0) catch null else null,
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
        const command = arena.dupeSentinel(u8, overlay_command.?, 0) catch "";
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

// -----------------------------------------------------------------------
// Font families
// -----------------------------------------------------------------------

fn ensureFonts(self: *Settings) void {
    if (self.fonts_checked or self.font_loader != null) return;
    const hwnd = self.popup.hwnd orelse return;
    self.font_loader = system.FontLoader.start(self.alloc, hwnd, WM_FONTS_READY, true) catch |err| {
        log.warn("cannot list the font families in the background err={}", .{err});
        return;
    };
    self.fonts_checked = true;
}

/// `WM_FONTS_READY`: take the new list, keeping the cursor on its family.
fn onFontsReady(self: *Settings) void {
    const loader = self.font_loader orelse return;
    var failed = false;
    switch (loader.take()) {
        .running => return,
        .ready => |families| {
            var keep_buf: [256]u8 = undefined;
            const keep = self.cursorFamily(&keep_buf);
            if (self.fonts) |*old| old.deinit();
            self.fonts = families;
            self.rebuildFontPicker(keep);
        },
        .failed, .taken => failed = true,
    }
    loader.detach();
    self.font_loader = null;
    if (!failed and !self.fonts_checked and self.open and self.section == .font) self.ensureFonts();
    if (failed) self.fonts_checked = false;
    self.invalidate();
}

/// `WM_FONTCHANGE`: fonts were installed or removed.
fn onFontChange(ctx: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    self.fonts_checked = false;
    self.measurements.clear();
    if (self.open and self.section == .font) self.ensureFonts();
}

/// Builds what the font list shows from `fonts` and the configured family,
/// keeping the cursor on the family it was on.
fn updateFontPicker(self: *Settings) void {
    var keep_buf: [256]u8 = undefined;
    self.rebuildFontPicker(self.cursorFamily(&keep_buf));
}

/// The family under the cursor of the font list, copied into `buf`.
fn cursorFamily(self: *Settings, buf: []u8) ?[]const u8 {
    const index = self.font_list.current() orelse return null;
    if (index >= self.font_picker.names.len) return null;
    const name = self.font_picker.names[index];
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

/// The font list from `fonts` and the configured family, with the cursor
/// on `keep` when it is listed, else on the configured family.
fn rebuildFontPicker(self: *Settings, keep: ?[]const u8) void {
    _ = self.font_arena.reset(.retain_capacity);
    const installed = if (self.fonts) |*fonts| fonts else null;
    self.font_picker = system.Picker.init(self.font_arena.allocator(), installed, self.font_family) catch
        .{ .names = &.{}, .local_names = &.{} };
    self.refilter(.fonts);
    if (keep) |name| {
        if (self.font_picker.indexOf(name)) |index| return self.font_list.select(index);
    }
    if (self.font_picker.indexOf(self.font_family)) |index| self.font_list.select(index);
}

// -----------------------------------------------------------------------
// Lists and their filter boxes
// -----------------------------------------------------------------------

const Field = enum { themes, fonts, font_size, search };

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

    /// Scrolls by `lines`; false if it was already at that end.
    fn scroll(self: *List, lines: i32) bool {
        const max_top = self.matches.items.len -| self.visible;
        const top: isize = @as(isize, @intCast(self.top)) + lines;
        const clamped: usize = @intCast(std.math.clamp(top, 0, @as(isize, @intCast(max_top))));
        if (clamped == self.top) return false;
        self.top = clamped;
        self.reveal = false;
        return true;
    }
};

fn listOf(self: *Settings, field: Field) *List {
    return switch (field) {
        .themes => &self.theme_list,
        .fonts, .font_size => &self.font_list,
        .search => unreachable,
    };
}

fn queryOf(self: *Settings, field: Field) *std.ArrayList(u8) {
    return switch (field) {
        .themes => &self.theme_query,
        .fonts, .font_size => &self.font_query,
        .search => &self.search_query,
    };
}

fn namesOf(self: *Settings, field: Field) []const [:0]const u8 {
    return switch (field) {
        .themes => if (self.themes) |list| list.names else &.{},
        .fonts, .font_size => self.font_picker.names,
        .search => unreachable,
    };
}

/// The list field of a row, if it has one.
fn listField(action: Action) ?Field {
    return switch (action) {
        .themes => .themes,
        .font_family => .fonts,
        else => null,
    };
}

/// Matches the names of `field` against its filter text; font families
/// also by their name in the user's language.
fn refilter(self: *Settings, field: Field) void {
    if (field == .search) {
        var buf: [max_rows]Row = undefined;
        const rows = self.buildRows(&buf);
        self.focus = firstFocusable(rows) orelse 0;
        self.body_scroll = 0;
        self.reveal_focus = true;
        return;
    }
    const list = self.listOf(field);
    const query = self.queryOf(field).items;
    const result = switch (field) {
        .themes => fuzzy.filter(self.alloc, self.namesOf(field), query, &list.matches),
        .fonts, .font_size => filterNames(self.alloc, self.font_picker.names, self.font_picker.local_names, query, &list.matches),
        .search => unreachable,
    };
    result catch |err| {
        log.warn("cannot filter the list err={}", .{err});
        list.matches.clearRetainingCapacity();
    };
    list.cursor = 0;
    list.top = 0;
    list.reveal = true;
}

/// `gx.fuzzy.filter` over two names per entry (`alt` may be null), each
/// entry ranked by the better of them.
fn filterNames(
    alloc: Allocator,
    names: []const [:0]const u8,
    alt: []const ?[:0]const u8,
    pattern: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    const query: fuzzy.Query = .init(pattern);
    if (query.isEmpty()) {
        try out.ensureTotalCapacity(alloc, names.len);
        for (0..names.len) |i| out.appendAssumeCapacity(@intCast(i));
        return;
    }

    const Ranked = struct {
        index: u32,
        score: i32,
        len: u32,

        fn better(_: void, a: @This(), b: @This()) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.len != b.len) return a.len < b.len;
            return a.index < b.index;
        }
    };
    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(alloc);
    var buf: fuzzy.Buffer = undefined;
    for (names, 0..) |name, i| {
        var best: ?Ranked = null;
        var candidates = [2]?[]const u8{ name, null };
        if (i < alt.len) {
            if (alt[i]) |local| candidates[1] = local;
        }
        for (candidates) |candidate| {
            const text = candidate orelse continue;
            const p = buf.prepare(text);
            const s = fuzzy.scorePrepared(&query, &p) orelse continue;
            const entry: Ranked = .{ .index = @intCast(i), .score = s, .len = @intCast(p.cps.len) };
            if (best == null or Ranked.better({}, entry, best.?)) best = entry;
        }
        if (best) |entry| try ranked.append(alloc, entry);
    }
    std.mem.sort(Ranked, ranked.items, {}, Ranked.better);
    try out.ensureTotalCapacity(alloc, ranked.items.len);
    for (ranked.items) |r| out.appendAssumeCapacity(r.index);
}

/// Gives the filter box of the focused list, if any, the text input; a
/// size being typed is applied when the focus moves on.
fn syncTextField(self: *Settings) void {
    if (self.searching()) return;
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    const want: ?Field = if (self.focus < rows.len) listField(rows[self.focus].action) else null;
    if (self.text_field == .font_size) {
        if (self.focus < rows.len and rows[self.focus].action == .font_size) return;
        self.endSizeEdit(true);
    }
    if (want == self.text_field) return;
    self.text_field = want;
    if (want) |field| {
        self.popup.input.setText(self.alloc, self.queryOf(field).items) catch {};
    } else {
        self.popup.input.clear();
    }
}

fn focusSearch(self: *Settings, select: bool) void {
    self.endSizeEdit(true);
    if (self.text_field != .search) self.popup.input.setText(self.alloc, self.search_query.items) catch {};
    self.text_field = .search;
    if (select) self.popup.input.anchor = 0;
    self.stopTimer(.preview);
    self.popup.focusMoved();
}

fn onTextChanged(ctx: *anyopaque, popup: *Popup) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    const field = self.text_field orelse return self.typedElsewhere(popup);
    if (field == .font_size) return self.invalidate();
    const text = popup.input.text(self.alloc) catch return;
    defer self.alloc.free(text);
    const query = self.queryOf(field);
    if (std.mem.eql(u8, query.items, text)) return;
    query.clearRetainingCapacity();
    query.appendSlice(self.alloc, text) catch return;
    self.refilter(field);
    if (field == .themes) self.schedulePreview(.type);
    self.invalidate();
}

fn typedElsewhere(self: *Settings, popup: *Popup) void {
    const typed = popup.input.text(self.alloc) catch return popup.input.clear();
    defer self.alloc.free(typed);
    if (fuzzy.isBlank(typed)) return popup.input.clear();
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    if (typed.len > 0 and self.focus < rows.len and rows[self.focus].action == .font_size and model.startsFontSize(typed[0])) {
        return self.beginSizeEdit(typed, false);
    }
    const list_index: ?usize = for (rows, 0..) |row, i| {
        if (listField(row.action) != null) break i;
    } else null;
    const field: Field = if (list_index) |index| listField(rows[index].action).? else .search;
    const query = self.queryOf(field);
    query.appendSlice(self.alloc, typed) catch {};
    if (list_index) |index| self.focus = index;
    self.focus_visible = true;
    self.reveal_focus = true;
    self.text_field = field;
    popup.input.setText(self.alloc, query.items) catch {};
    self.refilter(field);
    if (field == .themes) self.schedulePreview(.type);
    self.invalidate();
}

/// Starts typing the font size, with `text` in the field (all of it
/// selected when `select`).
fn beginSizeEdit(self: *Settings, text: []const u8, select: bool) void {
    self.text_field = .font_size;
    self.popup.input.setText(self.alloc, text) catch {};
    if (select) self.popup.input.anchor = 0;
    self.popup.focusMoved();
}

/// Stops typing the font size, applying a valid size when `apply`.
fn endSizeEdit(self: *Settings, apply: bool) void {
    if (self.text_field != .font_size) return;
    const text = self.popup.input.text(self.alloc) catch null;
    defer if (text) |t| self.alloc.free(t);
    self.text_field = null;
    self.popup.input.clear();
    if (apply) {
        if (text) |t| if (model.parseFontSize(t)) |size| self.setFontSize(settings_map.FontSize.normalize(size));
    }
    self.invalidate();
}

// -----------------------------------------------------------------------
// Sections and rows
// -----------------------------------------------------------------------

/// The sections of the overlay, in sidebar order: the pages of
/// `gx:settings_page:<page>`.
pub const Section = settings_map.Page;

fn sectionTitle(section: Section) [:0]const u8 {
    return i18n.trRuntime(settings_map.pageLabel(section));
}

fn sectionIcon(section: Section) u21 {
    return switch (section) {
        .language => draw.icons.globe,
        .appearance => draw.icons.color,
        .font => draw.icons.font,
        .interaction => draw.icons.touch,
        .shell => draw.icons.command_prompt,
        .about => draw.icons.info,
    };
}

const RowKind = enum {
    /// A group title with an optional description and buttons.
    group,
    /// A paragraph of secondary text.
    note,
    radio,
    toggle,
    /// A segmented choice (chips).
    choice,
    /// The font size with -/+ and a field to type it into.
    stepper,
    /// A filter box with a list below it.
    list,
    /// A title with a value (paths, the version).
    info,
    button,
    /// A line of text in the font being picked.
    sample,
    /// A setting the search found, with the section it is in.
    result,
};

/// A row of a section, as a search result points at it.
const Goto = struct {
    section: Section,
    row: u16,
};

const Action = union(enum) {
    none,
    goto: Goto,
    language: i18n.Language,
    /// Which half of a light and dark theme pair the theme list edits.
    theme_half,
    accent,
    material,
    opacity,
    padding,
    cursor_style,
    cursor_blink,
    themes,
    font_size,
    font_family,
    right_click: u8,
    scrollbar,
    close_confirmation,
    focus_follows_mouse,
    ctrl_scroll_zoom,
    bell: u8,
    shell: u16,
    open_config_file,
    open_config_dir,
    reset_all,
};

const GroupButton = enum { reset, apply_theme, apply_font };

const Row = struct {
    kind: RowKind,
    action: Action = .none,
    title: []const u8 = "",
    detail: []const u8 = "",
    /// The detail warns (the command line overrides the setting).
    detail_warning: bool = false,
    on: bool = false,
    choices: []const []const u8 = &.{},
    /// Null when the value is none of the choices.
    choice: ?usize = 0,
    /// Bit `i` set: choice `i` is not available.
    disabled: u8 = 0,
    value: []const u8 = "",
    buttons: []const GroupButton = &.{},
    icon: ?u21 = null,
    /// The configuration keys the row sets, which Delete resets.
    keys: []const []const u8 = &.{},
    /// Draw a reset button: the settings file sets `keys`.
    resettable: bool = false,
    /// A choice whose group row above names it: the chips start on the left
    /// and `title` only names them for search and accessibility.
    chips_only: bool = false,
    /// A color dot before the label of each choice, or none.
    dots: []const d2d.Color = &.{},

    fn focusable(self: Row) bool {
        return switch (self.kind) {
            .group => self.buttons.len > 0,
            .note, .info, .sample => false,
            else => true,
        };
    }
};

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

/// What a setting row says under its title: where the value comes from
/// when that is not the settings file or a default, else `hint`.
const Detail = struct {
    text: []const u8 = "",
    warning: bool = false,
};

fn detailFor(self: *Settings, keys: []const []const u8, hint: []const u8) Detail {
    const layers = self.layersPtr() orelse return .{ .text = hint };
    var source: ?gx.config_layers.Layer = null;
    for (keys) |key| {
        const layer = layers.provenance(key) orelse continue;
        if (source == null or @backingInt(layer) > @backingInt(source.?)) source = layer;
    }
    return switch (source orelse return .{ .text = hint }) {
        .cli => .{ .text = i18n.trRuntime(settings_map.provenanceLabel(.cli)), .warning = true },
        .user => .{ .text = i18n.trRuntime(settings_map.provenanceLabel(.user)) },
        .defaults, .overlay => .{ .text = hint },
    };
}

/// Whether the settings file sets one of `keys` (with the changes made
/// here), so "Reset to Default" does something.
fn overlaySets(self: *Settings, keys: []const []const u8) bool {
    const layers = self.layersPtr() orelse return false;
    for (keys) |key| if (layers.sets(.overlay, key)) return true;
    return false;
}

/// A setting row with its keys, detail and reset button.
fn setting(self: *Settings, row: Row, hint: []const u8) Row {
    var out = row;
    const detail = self.detailFor(row.keys, hint);
    out.detail = detail.text;
    out.detail_warning = detail.warning;
    out.resettable = self.overlaySets(row.keys);
    return out;
}

/// A group title over the radio rows of one setting.
fn settingGroup(self: *Settings, scratch: Allocator, title: []const u8, keys: []const []const u8, hint: []const u8, buttons: []const GroupButton) Row {
    const resettable = self.overlaySets(keys);
    const detail = self.detailFor(keys, hint);
    var all: []const GroupButton = buttons;
    if (resettable) {
        if (scratch.alloc(GroupButton, buttons.len + 1)) |list| {
            list[0] = .reset;
            @memcpy(list[1..], buttons);
            all = list;
        } else |_| {}
    }
    return .{
        .kind = .group,
        .title = title,
        .detail = detail.text,
        .detail_warning = detail.warning,
        .buttons = all,
        .keys = keys,
        .resettable = resettable,
    };
}

const keys_language: []const []const u8 = &.{"language"};
const keys_material: []const []const u8 = &.{"gx-window-material"};
const keys_opacity: []const []const u8 = &.{"background-opacity"};
const keys_padding: []const []const u8 = &.{ settings_map.Padding.keys[0], settings_map.Padding.keys[1] };
const keys_cursor_style: []const []const u8 = &.{"cursor-style"};
const keys_cursor_blink: []const []const u8 = &.{settings_map.cursor_blink.key};
const keys_theme: []const []const u8 = &.{"theme"};
const keys_accent: []const []const u8 = &.{settings_map.Accent.key};
/// The accent choices, in display order.
const accents = std.enums.values(settings_map.Accent);
const theme_halves = std.enums.values(settings_map.ThemeHalf);
const keys_font_size: []const []const u8 = &.{"font-size"};
const keys_font_family: []const []const u8 = &.{"font-family"};
const keys_right_click: []const []const u8 = &.{"right-click-action"};
const keys_scrollbar: []const []const u8 = &.{"scrollbar"};
const keys_close: []const []const u8 = &.{"confirm-close-surface"};
const keys_focus_follows_mouse: []const []const u8 = &.{settings_map.focus_follows_mouse.key};
const keys_ctrl_scroll_zoom: []const []const u8 = &.{settings_map.ctrl_scroll_zoom.key};
const keys_bell: []const []const u8 = &.{"bell-features"};
const keys_command: []const []const u8 = &.{"command"};

/// The rows of the body: the settings the search finds while it has text,
/// else the rows of the current section. Dynamic strings live in `scratch`
/// until the next paint.
fn buildRows(self: *Settings, buf: *[max_rows]Row) []Row {
    if (self.searching()) return self.buildSearchRows(buf);
    return self.buildSectionRows(self.section, buf);
}

/// Whether the search has text, so the body shows what it finds.
fn searching(self: *const Settings) bool {
    return !fuzzy.isBlank(self.search_query.items);
}

/// The settings of every section whose title, or the title of the group
/// it is in, matches the search: a group row per section, a result row
/// per setting pointing at its row (`Goto`).
fn buildSearchRows(self: *Settings, buf: *[max_rows]Row) []Row {
    var rows: RowList = .{ .buf = buf };
    const query: fuzzy.Query = .init(self.search_query.items);
    var section_buf: [max_rows]Row = undefined;
    for (std.enums.values(Section)) |section| {
        const section_rows = self.buildSectionRows(section, &section_buf);
        appendSearchRows(&rows, section, sectionTitle(section), section_rows, &query, self.scratch.allocator());
    }
    if (rows.len == 0) rows.add(.{ .kind = .note, .detail = i18n.tr("No matching settings") });
    return rows.items();
}

fn appendSearchRows(out: *RowList, section: Section, section_title: []const u8, rows: []const Row, query: *const fuzzy.Query, alloc: Allocator) void {
    var group: []const u8 = "";
    var found = false;
    for (rows, 0..) |row, i| {
        switch (row.kind) {
            .group => {
                group = row.title;
                continue;
            },
            .radio, .toggle, .choice, .stepper, .list, .button => {},
            .note, .info, .sample, .result => continue,
        }
        const title = if (row.kind == .list or row.title.len == 0) group else row.title;
        if (title.len == 0) continue;
        var text: std.Io.Writer.Allocating = .init(alloc);
        defer text.deinit();
        text.writer.print("{s} {s} {s}", .{ section_title, group, title }) catch continue;
        for (row.keys) |key| text.writer.print(" {s}", .{key}) catch {};
        if (fuzzy.score(query, text.written()) == null) continue;
        if (!found) {
            found = true;
            out.add(.{ .kind = .group, .title = section_title });
        }
        const where = if (group.len > 0 and !std.mem.eql(u8, group, title))
            alloc.print("{s} \u{203A} {s}", .{ section_title, group }) catch section_title
        else
            section_title;
        out.add(.{
            .kind = .result,
            .action = .{ .goto = .{ .section = section, .row = @intCast(i) } },
            .title = title,
            .detail = where,
        });
    }
}

/// The rows of `section`.
fn buildSectionRows(self: *Settings, section: Section, buf: *[max_rows]Row) []Row {
    var rows: RowList = .{ .buf = buf };
    const scratch = self.scratch.allocator();
    switch (section) {
        .language => {
            rows.add(self.settingGroup(scratch, i18n.tr(msg.interface_language), keys_language, "", &.{}));
            for (std.enums.values(i18n.Language)) |lang| {
                rows.add(.{
                    .kind = .radio,
                    .action = .{ .language = lang },
                    .title = lang.nativeName(),
                    .detail = lang.configValue(),
                    .on = self.values.language == lang,
                    .keys = keys_language,
                });
            }
        },
        .appearance => {
            const pair = self.themePair();
            var theme_group = self.settingGroup(scratch, i18n.tr(msg.theme), keys_theme, if (self.layered) i18n.tr(msg.theme_hint) else "", &.{.apply_theme});
            if (pair) |p| theme_group.detail = self.pairDetail(scratch, p, theme_group.detail);
            rows.add(theme_group);
            if (pair != null) {
                var half_labels: [theme_halves.len][]const u8 = undefined;
                for (theme_halves, &half_labels) |half, *label| label.* = i18n.trRuntime(half.label());
                rows.add(.{
                    .kind = .choice,
                    .action = .theme_half,
                    .title = i18n.tr(settings_map.theme_half_title),
                    .choices = scratch.dupe([]const u8, &half_labels) catch &.{},
                    .choice = std.mem.indexOfScalar(settings_map.ThemeHalf, theme_halves, self.theme_half),
                    .chips_only = true,
                });
            }
            rows.add(.{ .kind = .list, .action = .themes, .keys = keys_theme });

            self.addAccentRows(&rows, scratch);

            rows.add(.{ .kind = .group, .title = i18n.tr("Window") });
            const materials = std.enums.values(WindowMaterial);
            var material_labels: [materials.len][]const u8 = undefined;
            var disabled: u8 = 0;
            for (materials, 0..) |material, i| {
                material_labels[i] = materialLabel(material);
                if (!system.materialSupported(material, self.build)) disabled |= @as(u8, 1) << @intCast(i);
            }
            rows.add(self.setting(.{
                .kind = .choice,
                .action = .material,
                .title = i18n.tr(msg.window_material),
                .choices = scratch.dupe([]const u8, &material_labels) catch &.{},
                .choice = std.mem.indexOfScalar(WindowMaterial, materials, self.values.material),
                .disabled = disabled,
                .keys = keys_material,
            }, ""));
            rows.add(.{ .kind = .note, .detail = self.materialNote(scratch) });

            const opacities = std.enums.values(settings_map.Opacity);
            var opacity_labels: [opacities.len][]const u8 = undefined;
            for (opacities, &opacity_labels) |choice, *label| label.* = i18n.trRuntime(choice.label());
            const opacity_hint = if (self.app.alpha_frames)
                i18n.tr(msg.opacity_hint)
            else
                i18n.tr("On this system the whole window becomes translucent.");
            rows.add(self.setting(.{
                .kind = .choice,
                .action = .opacity,
                .title = i18n.tr(msg.opacity),
                .choices = scratch.dupe([]const u8, &opacity_labels) catch &.{},
                .choice = if (self.values.opacity) |o| std.mem.indexOfScalar(settings_map.Opacity, opacities, o) else null,
                .keys = keys_opacity,
            }, opacity_hint));

            const paddings = std.enums.values(settings_map.Padding);
            var padding_labels: [paddings.len][]const u8 = undefined;
            for (paddings, &padding_labels) |preset, *label| label.* = i18n.trRuntime(preset.label());
            rows.add(self.setting(.{
                .kind = .choice,
                .action = .padding,
                .title = i18n.tr(msg.padding),
                .choices = scratch.dupe([]const u8, &padding_labels) catch &.{},
                .choice = if (self.values.padding) |p| std.mem.indexOfScalar(settings_map.Padding, paddings, p) else null,
                .keys = keys_padding,
            }, i18n.tr(msg.padding_hint)));

            rows.add(.{ .kind = .group, .title = i18n.tr(msg.cursor) });
            const cursor_choices = &settings_map.cursor_style_choices;
            var cursor_labels: [cursor_choices.len][]const u8 = undefined;
            for (cursor_choices, &cursor_labels) |choice, *label| label.* = i18n.trRuntime(choice.label);
            rows.add(self.setting(.{
                .kind = .choice,
                .action = .cursor_style,
                .title = i18n.tr(msg.cursor_style),
                .choices = scratch.dupe([]const u8, &cursor_labels) catch &.{},
                .choice = settings_map.choiceIndex(settings_map.CursorStyle, cursor_choices, self.values.cursor_style),
                .keys = keys_cursor_style,
            }, ""));
            rows.add(self.setting(.{
                .kind = .toggle,
                .action = .cursor_blink,
                .title = i18n.tr(msg.cursor_blink),
                .on = self.values.cursor_blink,
                .keys = keys_cursor_blink,
            }, ""));
        },
        .font => {
            var size_buf: [32]u8 = undefined;
            const size = settings_map.FontSize.format(&size_buf, self.values.font_size) catch "";
            rows.add(self.setting(.{
                .kind = .stepper,
                .action = .font_size,
                .title = i18n.tr(msg.font_size),
                .value = scratch.dupe(u8, size) catch "",
                .keys = keys_font_size,
            }, ""));
            rows.add(.{ .kind = .sample });
            rows.add(self.settingGroup(scratch, i18n.tr(msg.font_family), keys_font_family, i18n.tr(msg.font_family_hint), &.{.apply_font}));
            rows.add(.{ .kind = .list, .action = .font_family, .keys = keys_font_family });
        },
        .interaction => {
            rows.add(self.settingGroup(scratch, i18n.tr(msg.right_click), keys_right_click, "", &.{}));
            for (settings_map.right_click_choices, 0..) |choice, i| {
                rows.add(.{
                    .kind = .radio,
                    .action = .{ .right_click = @intCast(i) },
                    .title = i18n.trRuntime(choice.label),
                    .on = self.values.right_click == choice.value,
                    .keys = keys_right_click,
                });
            }
            rows.add(self.setting(.{
                .kind = .toggle,
                .action = .scrollbar,
                .title = i18n.tr(msg.show_scrollbar),
                .on = self.values.scrollbar,
                .keys = keys_scrollbar,
            }, ""));
            const choices = &settings_map.close_confirmation_choices;
            var labels_buf: [choices.len][]const u8 = undefined;
            for (choices, &labels_buf) |choice, *label| label.* = i18n.trRuntime(choice.label);
            rows.add(self.setting(.{
                .kind = .choice,
                .action = .close_confirmation,
                .title = i18n.tr(msg.close_confirmation),
                .choices = scratch.dupe([]const u8, &labels_buf) catch &.{},
                .choice = settings_map.choiceIndex(Config.ConfirmCloseSurface, choices, self.values.close_confirmation),
                .keys = keys_close,
            }, ""));
            rows.add(self.setting(.{
                .kind = .toggle,
                .action = .focus_follows_mouse,
                .title = i18n.tr(settings_map.focus_follows_mouse.label),
                .on = self.values.focus_follows_mouse,
                .keys = keys_focus_follows_mouse,
            }, i18n.tr(settings_map.focus_follows_mouse.hint)));
            rows.add(self.setting(.{
                .kind = .toggle,
                .action = .ctrl_scroll_zoom,
                .title = i18n.tr(settings_map.ctrl_scroll_zoom.label),
                .on = self.values.ctrl_scroll_zoom,
                .keys = keys_ctrl_scroll_zoom,
            }, i18n.tr(settings_map.ctrl_scroll_zoom.hint)));
            rows.add(self.settingGroup(scratch, i18n.tr(msg.bell), keys_bell, "", &.{}));
            const runtime = settings_map.Runtime.native orelse .win32;
            inline for (settings_map.bell_features, 0..) |feature, i| {
                if (feature.supports(runtime)) rows.add(.{
                    .kind = .toggle,
                    .action = .{ .bell = i },
                    .title = i18n.tr(feature.label),
                    .on = @field(self.values.bell, feature.field),
                    .keys = keys_bell,
                });
            }
        },
        .shell => {
            rows.add(self.settingGroup(scratch, i18n.tr(msg.default_shell), keys_command, i18n.tr(msg.default_shell_hint), &.{}));
            const current = if (self.shell_selected < self.shells.len)
                self.shellName(scratch, self.shells[self.shell_selected])
            else
                "";
            var note: std.Io.Writer.Allocating = .init(scratch);
            i18n.format(&note.writer, i18n.tr("Current default: {name}"), .{ .name = current }) catch {};
            if (self.app.defaultTerminalCommand()) |command| {
                const line = command.string(scratch) catch "";
                if (line.len > 0) note.writer.print(" \u{2014} {s}", .{model.displayCommand(line)}) catch {};
            }
            rows.add(.{ .kind = .note, .detail = note.written() });
            for (self.shells, 0..) |shell, i| {
                rows.add(.{
                    .kind = .radio,
                    .action = .{ .shell = @intCast(i) },
                    .title = self.shellName(scratch, shell),
                    .detail = model.displayCommand(shell.command orelse ""),
                    .on = i == self.shell_selected,
                    .keys = keys_command,
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
            rows.add(.{ .kind = .info, .title = i18n.tr("Graphics"), .detail = self.graphicsDetail(scratch) });
            rows.add(.{ .kind = .info, .title = i18n.tr(msg.config_file), .detail = windowsPath(scratch, self.config_path) });
            rows.add(.{ .kind = .info, .title = i18n.tr(msg.settings_file), .detail = windowsPath(scratch, self.overlay_path) });
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
            rows.add(.{
                .kind = .button,
                .action = .reset_all,
                .title = i18n.tr("Reset Interface Settings"),
                .icon = draw.icons.reset,
            });
            rows.add(.{
                .kind = .note,
                .detail = if (self.reset_all.armed(system.nowMs()))
                    i18n.tr("Press Reset Interface Settings again to confirm.")
                else
                    i18n.tr("Removes every setting made here, so the configuration file and the defaults apply again."),
                .detail_warning = self.reset_all.armed(system.nowMs()),
            });
        },
    }
    return rows.items();
}

/// The detail of the theme group of a light and dark pair: both themes,
/// then `hint`.
fn pairDetail(self: *Settings, alloc: Allocator, pair: settings_map.ThemePair, hint: []const u8) []const u8 {
    _ = self;
    const summary = i18n.fill(alloc, i18n.tr(settings_map.theme_pair_summary), .{ .light = pair.light, .dark = pair.dark }) catch return hint;
    const pair_hint = i18n.tr(msg.theme_pair_hint);
    // Sentences ending in a full-width stop (Chinese) need no space.
    const space: []const u8 = if (pair_hint.len > 0 and pair_hint[pair_hint.len - 1] < 0x80) " " else "";
    const explained = if (hint.len > 0)
        alloc.print("{s}{s}{s}", .{ pair_hint, space, hint }) catch hint
    else
        pair_hint;
    return alloc.print("{s}\n{s}", .{ summary, explained }) catch summary;
}

/// The accent color: a group with the chips of `accents`, or a color of its
/// own from a configuration file, shown and not chosen.
fn addAccentRows(self: *Settings, rows: *RowList, scratch: Allocator) void {
    var group = self.settingGroup(scratch, i18n.tr(msg.accent_color), keys_accent, i18n.tr(msg.accent_color_hint), &.{});
    var row: Row = .{
        .kind = .choice,
        .action = .accent,
        .title = i18n.tr(msg.accent_color),
        .keys = keys_accent,
        .chips_only = true,
    };
    if (self.values.accent) |accent| {
        var labels: [accents.len][]const u8 = undefined;
        for (accents, &labels) |choice, *label| label.* = i18n.trRuntime(choice.label());
        row.choices = scratch.dupe([]const u8, &labels) catch &.{};
        row.choice = std.mem.indexOfScalar(settings_map.Accent, accents, accent);
        row.dots = &self.values.accent_dots;
    } else {
        // Read-only: one chip that cannot be picked, the color and where
        // it comes from.
        const color = self.values.accent_color;
        const layer: ?gx.config_layers.Layer = if (self.layersPtr()) |layers| layers.provenance(settings_map.Accent.key) else null;
        group.detail = scratch.print("#{x:0>2}{x:0>2}{x:0>2} \u{00B7} {s}", .{
            color.r,
            color.g,
            color.b,
            i18n.trRuntime(settings_map.provenanceLabel(layer)),
        }) catch group.detail;
        group.detail_warning = layer == .cli;
        row.choices = scratch.dupe([]const u8, &.{i18n.tr(settings_map.Accent.custom_label)}) catch &.{};
        row.choice = null;
        row.disabled = 1;
        row.dots = scratch.dupe(d2d.Color, &.{d2d.Color.rgb(color.r, color.g, color.b)}) catch &.{};
    }
    rows.add(group);
    rows.add(row);
}

fn windowsPath(alloc: Allocator, path: []const u8) []const u8 {
    const buf = alloc.alloc(u8, path.len) catch return path;
    return model.windowsPath(buf, path);
}

fn materialLabel(material: WindowMaterial) [:0]const u8 {
    return switch (material) {
        .solid => i18n.tr("Solid"),
        .mica => i18n.tr("Mica"),
        .acrylic => i18n.tr("Acrylic"),
        .tabbed => i18n.tr("Tabbed"),
    };
}

/// Which materials work here, and why one does not show behind the
/// terminals.
fn materialNote(self: *Settings, alloc: Allocator) []const u8 {
    if (self.build < system.build_windows_11) return i18n.tr("Window material requires Windows 11.");
    const all = for (std.enums.values(WindowMaterial)) |material| {
        if (!system.materialSupported(material, self.build)) break false;
    } else true;
    if (!all) return i18n.fill(alloc, i18n.tr("Dimmed materials are not supported on this system (build {build})."), .{ .build = self.build }) catch "";
    if (!self.app.alpha_frames and self.values.material != .solid) {
        return switch (self.app.core_app.device.?.alphaFrames()) {
            .software => i18n.tr("The material shows in the title bar only: the terminals are drawn by software rendering."),
            .supported, .no_alpha_channel => i18n.tr("The material shows in the title bar only: the graphics driver draws the terminals without transparency."),
        };
    }
    return i18n.fill(alloc, i18n.tr("All window materials are supported on this system (build {build})."), .{ .build = self.build }) catch "";
}

/// The OpenGL implementation that draws the terminals (`wgl.Device`).
fn graphicsDetail(self: *Settings, alloc: Allocator) []const u8 {
    const device = self.app.core_app.device orelse return "OpenGL";
    device.wait() catch return "OpenGL";
    const backend = device.backend();
    var out: std.Io.Writer.Allocating = .init(alloc);
    const name = if (backend.renderer.len > 0) backend.renderer else backend.vendor;
    out.writer.print("{s} \u{00B7} OpenGL {d}.{d}", .{ name, backend.version.major, backend.version.minor }) catch {};
    if (backend.software) out.writer.print(" \u{00B7} {s}", .{i18n.tr("Software rendering")}) catch {};
    return out.written();
}

fn shellName(self: *Settings, alloc: Allocator, shell: Shell) []const u8 {
    _ = self;
    return switch (shell.kind) {
        .system_default => i18n.tr(msg.system_default),
        .custom_profile => shell.name,
        .custom_command => i18n.fill(alloc, i18n.tr(msg.custom_command), .{ .command = model.displayCommand(shell.name) }) catch shell.name,
        .profile => i18n.fill(alloc, i18n.trRuntime(shell.name), .{ .name = shell.name_arg orelse "" }) catch shell.name,
    };
}

fn defaultFocus(self: *Settings, rows: []const Row) usize {
    for (rows, 0..) |row, i| {
        switch (self.section) {
            .language, .shell, .interaction => if (row.kind == .radio and row.on) return i,
            .appearance, .font => if (row.kind == .list) return i,
            .about => if (row.kind == .button) return i,
        }
    }
    return firstFocusable(rows) orelse 0;
}

fn firstFocusable(rows: []const Row) ?usize {
    for (rows, 0..) |row, i| if (row.focusable()) return i;
    return null;
}

fn gotoSetting(self: *Settings, target: Goto) void {
    self.enterSection(target.section);
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    if (target.row >= rows.len or !rows[target.row].focusable()) return;
    self.focus = target.row;
    self.focus_button = 0;
    self.focus_visible = true;
    self.reveal_focus = true;
    self.syncTextField();
    self.invalidate();
}

fn enterSection(self: *Settings, section: Section) void {
    self.endSizeEdit(true);
    self.search_query.clearRetainingCapacity();
    self.text_field = null;
    self.popup.input.clear();
    self.section = section;
    self.body_scroll = 0;
    self.hover = null;
    self.pressed = null;
    self.reset_all.cancel();
    self.tooltip.hide();
    if (section == .font) self.ensureFonts();
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    self.focus = self.defaultFocus(rows);
    self.focus_button = 0;
    self.reveal_focus = true;
    self.theme_list.reveal = true;
    self.font_list.reveal = true;
    self.syncTextField();
    self.invalidate();
}

fn cycleSection(self: *Settings, delta: isize) void {
    const sections = std.enums.values(Section);
    const count: isize = @intCast(sections.len);
    const current: isize = @intCast(@backingInt(self.section));
    self.enterSection(sections[@intCast(@mod(current + delta, count))]);
}

/// Moves the focus to the next focusable row in direction `delta`.
fn moveFocus(self: *Settings, rows: []const Row, delta: isize) void {
    var i: isize = @intCast(self.focus);
    while (true) {
        i += delta;
        if (i < 0 or i >= rows.len) return;
        if (rows[@intCast(i)].focusable()) break;
    }
    self.focus = @intCast(i);
    self.focus_button = if (delta < 0) rows[self.focus].buttons.len -| 1 else 0;
    self.reveal_focus = true;
    if (i == 0 or firstFocusableBefore(rows, @intCast(i)) == null) self.body_scroll = 0;
    self.syncTextField();
    // The paint reveals the row: the focus is reported in place after it
    // when that kept the layout, else the paint publishes it anew
    // (`checkUiaHits`).
    self.popup.focusMovedAtPaint();
}

fn firstFocusableBefore(rows: []const Row, end: usize) ?usize {
    for (rows[0..end], 0..) |row, i| if (row.focusable()) return i;
    return null;
}

// -----------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------

/// Enter, Space or a click on `row`.
fn activate(self: *Settings, row: Row) void {
    switch (row.action) {
        .none, .font_size => {},
        .goto => |target| self.gotoSetting(target),
        .language => |lang| self.setLanguage(lang),
        .theme_half, .accent, .material, .opacity, .padding, .cursor_style, .close_confirmation => self.stepChoice(row, 1),
        .themes => self.applyTheme(),
        .font_family => self.applyFontFamily(),
        .right_click => |i| self.setRightClick(i),
        .scrollbar => self.setScrollbar(!row.on),
        .cursor_blink, .focus_follows_mouse, .ctrl_scroll_zoom => self.setSwitch(row.action, !row.on),
        .bell => |i| self.setBell(i, !row.on),
        .shell => |i| self.chooseShell(i),
        .open_config_file => self.openConfigFile(),
        .open_config_dir => self.openConfigDir(),
        .reset_all => self.resetAll(),
    }
    self.invalidate();
}

fn activateGroupButton(self: *Settings, row: Row, button: GroupButton) void {
    switch (button) {
        .reset => self.resetRow(row),
        .apply_theme => self.applyTheme(),
        .apply_font => self.applyFontFamily(),
    }
    self.invalidate();
}

/// Left/Right on a choice: the previous or next available choice, wrapping
/// around for Enter.
fn stepChoice(self: *Settings, row: Row, delta: isize) void {
    const count = row.choices.len;
    if (count == 0) return;
    var index: isize = if (row.choice) |c| @intCast(c) else if (delta > 0) -1 else @intCast(count);
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
    if (row.choice == index) return;
    switch (row.action) {
        .theme_half => self.setThemeHalf(theme_halves[index]),
        .accent => {
            const accent = accents[index];
            self.values.accent = accent;
            self.queueSet(settings_map.Accent.key, accent.value());
        },
        .material => {
            const material = std.enums.values(WindowMaterial)[index];
            self.values.material = material;
            self.queueSet("gx-window-material", @tagName(material));
        },
        .opacity => {
            const choice = std.enums.values(settings_map.Opacity)[index];
            self.values.opacity = choice;
            if (choice.value()) |value| self.queueSet("background-opacity", value) else self.queueReset(keys_opacity);
        },
        .padding => {
            const preset = std.enums.values(settings_map.Padding)[index];
            self.values.padding = preset;
            if (preset.values()) |values| {
                for (settings_map.Padding.keys, values) |key, value| self.queueSet(key, value);
            } else self.queueReset(keys_padding);
        },
        .cursor_style => {
            const value = settings_map.cursor_style_choices[index].value;
            self.values.cursor_style = value;
            self.queueSet("cursor-style", @tagName(value));
        },
        .close_confirmation => {
            const value = settings_map.close_confirmation_choices[index].value;
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

fn setRightClick(self: *Settings, index: u8) void {
    if (index >= settings_map.right_click_choices.len) return;
    const action = settings_map.right_click_choices[index].value;
    if (action == self.values.right_click) return;
    self.values.right_click = action;
    self.queueSet("right-click-action", @tagName(action));
}

fn setScrollbar(self: *Settings, on: bool) void {
    if (on == self.values.scrollbar) return;
    self.values.scrollbar = on;
    self.queueSet("scrollbar", @tagName(settings_map.scrollbar(on)));
}

fn setSwitch(self: *Settings, action: Action, on: bool) void {
    const item: settings_map.Switch = switch (action) {
        .cursor_blink => settings_map.cursor_blink,
        .focus_follows_mouse => settings_map.focus_follows_mouse,
        .ctrl_scroll_zoom => settings_map.ctrl_scroll_zoom,
        else => return,
    };
    const value: *bool = switch (action) {
        .cursor_blink => &self.values.cursor_blink,
        .focus_follows_mouse => &self.values.focus_follows_mouse,
        .ctrl_scroll_zoom => &self.values.ctrl_scroll_zoom,
        else => unreachable,
    };
    if (value.* == on) return;
    value.* = on;
    self.queueSet(item.key, settings_map.Switch.value(on));
}

fn setBell(self: *Settings, index: u8, on: bool) void {
    inline for (settings_map.bell_features, 0..) |feature, i| {
        if (i == index) @field(self.values.bell, feature.field) = on;
    }
    var buf: [128]u8 = undefined;
    const value = settings_map.formatFlags(Config.BellFeatures, self.values.bell, &buf) catch return;
    self.queueSet("bell-features", value);
}

const Step = enum(u32) { minus, plus };

fn stepFontSize(self: *Settings, step: Step) void {
    const FontSize = settings_map.FontSize;
    self.setFontSize(switch (step) {
        .minus => FontSize.normalize(self.values.font_size - FontSize.step),
        .plus => FontSize.normalize(self.values.font_size + FontSize.step),
    });
}

fn setFontSize(self: *Settings, size: f32) void {
    if (size == self.values.font_size) return;
    self.values.font_size = size;
    var buf: [32]u8 = undefined;
    const value = settings_map.FontSize.format(&buf, size) catch return;
    self.queueSet("font-size", value);
    self.invalidate();
}

fn applyFontFamily(self: *Settings) void {
    const names = self.font_picker.names;
    const typed = std.mem.trim(u8, self.font_query.items, &std.ascii.whitespace);
    // The highlighted family, or what was typed when nothing matches.
    const family: []const u8 = if (self.font_list.current()) |index| names[index] else typed;
    if (family.len == 0) return self.resetRow(.{ .kind = .group, .keys = keys_font_family });
    if (std.mem.eql(u8, family, self.font_family)) return;
    // The settings file replaces the whole list: keep the fallbacks.
    const families = settings_map.fontFamilies(self.alloc, family, self.app.config.@"font-family".list.items) catch return;
    defer self.alloc.free(families);
    self.font_family = self.arena.allocator().dupe(u8, family) catch return;
    self.queueSetAll("font-family", families);
    self.invalidate();
}

/// "Reset to Default": removes the keys of `row` from the settings file
/// at once, so the row shows the value that applies then.
fn resetRow(self: *Settings, row: Row) void {
    if (row.keys.len == 0 or !self.overlaySets(row.keys)) return;
    self.queueReset(row.keys);
    if (std.mem.eql(u8, row.keys[0], "theme")) {
        self.stopTimer(.preview);
        self.preview_theme = null;
        self.applied_preview = null;
    }
    _ = self.saveNow();
}

fn resetAll(self: *Settings) void {
    if (!self.reset_all.press(system.nowMs())) return self.invalidate();
    if (self.overlay_path.len == 0) return;
    for ([_][]const []const u8{
        keys_language,     keys_material, keys_opacity,             keys_padding,          keys_cursor_style,
        keys_cursor_blink, keys_theme,    keys_font_size,           keys_font_family,      keys_right_click,
        keys_scrollbar,    keys_close,    keys_focus_follows_mouse, keys_ctrl_scroll_zoom, keys_bell,
        keys_command,      keys_accent,
    }) |keys| self.queueReset(keys);
    self.stopTimer(.preview);
    self.preview_theme = null;
    self.applied_preview = null;
    if (self.changes.isEmpty() or self.saveNow()) {
        self.setStatus(.success, "Every setting made here was removed.", .{});
    }
}

fn chooseShell(self: *Settings, index: u16) void {
    if (index >= self.shells.len) return;
    const shell = self.shells[index];
    self.shell_selected = index;
    if (shell.command) |command| {
        self.queueSet("command", command);
    } else {
        self.queueReset(keys_command);
    }
    if (shell.gx_zsh) |exe| self.runHerdr(exe);
    self.invalidate();
}

fn openConfigFile(self: *Settings) void {
    // The editor path of `gx-open-config-ui = editor`.
    const opened = self.app.openConfigFile(.os_open) catch |err| {
        return self.setStatusReason(.err, msg.open_failed, err);
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

/// The `theme` value that keeps theme `index`: the theme alone, or the
/// configured pair with its `theme_half` replaced, so the system's light
/// or dark mode is still followed. Owned by `alloc`.
fn themeValue(self: *Settings, alloc: Allocator, index: u32) ?[:0]u8 {
    const name = self.themeName(index) orelse return null;
    const pair = self.themePair() orelse return alloc.dupeSentinel(u8, name, 0) catch null;
    return self.theme_half.replace(pair, name).value(alloc) catch null;
}

/// Shows and edits the `half` of a light and dark pair; a preview of the
/// other half ends.
fn setThemeHalf(self: *Settings, half: settings_map.ThemeHalf) void {
    if (half == self.theme_half) return;
    self.endPreview();
    self.theme_half = half;
    self.saved_theme = self.savedThemeIndex();
    if (self.saved_theme) |saved| self.theme_list.select(saved);
}

/// Stops a theme preview and applies the saved configuration again.
fn endPreview(self: *Settings) void {
    self.stopTimer(.preview);
    const previewed = self.applied_preview != null;
    self.preview_theme = null;
    self.applied_preview = null;
    if (previewed) _ = self.applyConfig(null, true);
}

/// Previews the theme under the cursor once it rests for the time
/// `trigger` asks for (`model.previewDelayMs`): every move starts the wait
/// again, so moving through the list previews where it stops.
fn schedulePreview(self: *Settings, trigger: model.PreviewTrigger) void {
    if (!self.layered) return;
    const index = self.theme_list.current() orelse return;
    if (self.preview_theme == null and self.applied_preview == null and index == self.saved_theme) return;
    self.preview_theme = index;
    self.stopTimer(.preview);
    self.startTimer(.preview, model.previewDelayMs(trigger));
}

fn previewNow(self: *Settings) void {
    const index = self.preview_theme orelse return;
    if (self.applied_preview == index) return;
    const name = self.themeName(index) orelse return;
    const value = self.themeValue(self.alloc, index) orelse return;
    defer self.alloc.free(value);
    const span: gx.perf.Span = .begin(global.io());
    defer _ = span.end(global.io(), "settings_preview");
    const saved = self.commitChanges();
    if (self.applyConfig(value, true)) {
        self.applied_preview = index;
        if (saved) self.setStatus(.info, "Previewing {name}", .{ .name = name });
    }
}

fn applyTheme(self: *Settings) void {
    const index = self.theme_list.current() orelse return;
    const value = self.themeValue(self.alloc, index) orelse return;
    defer self.alloc.free(value);
    self.stopTimer(.preview);
    self.preview_theme = null;
    self.applied_preview = null;
    self.saved_theme = index;
    self.queueSet("theme", value);
    _ = self.saveNow();
    self.invalidate();
}

// -----------------------------------------------------------------------
// Saving and reloading
// -----------------------------------------------------------------------

fn queueSet(self: *Settings, key: []const u8, value: []const u8) void {
    self.queueSetAll(key, &.{value});
}

/// "Reset to Default" of `keys` (`Changes.reset`): removes them from the
/// settings file with the next save.
fn queueReset(self: *Settings, keys: []const []const u8) void {
    for (keys) |key| {
        self.changes.reset(key) catch |err| {
            log.warn("cannot record the reset of {s} err={}", .{ key, err });
            continue;
        };
        self.followChange(key, &.{});
    }
    self.scheduleSave();
}

/// Records a change (an empty `values` removes `key` from the overlay)
/// and saves it with the other changes of the next moment.
fn queueSetAll(self: *Settings, key: []const u8, values: []const []const u8) void {
    self.changes.setAll(key, values) catch |err| {
        log.warn("cannot record the change of {s} err={}", .{ key, err });
        return;
    };
    self.followChange(key, values);
    self.scheduleSave();
}

/// The layers follow a change at once, so the rows show where values come
/// from and previews keep it.
fn followChange(self: *Settings, key: []const u8, values: []const []const u8) void {
    const layers = self.layersPtr() orelse return;
    layers.setOverlay(key, values) catch |err| {
        log.warn("cannot follow the change of {s} err={}", .{ key, err });
    };
}

fn scheduleSave(self: *Settings) void {
    self.save_attempts = 0;
    self.stopTimer(.save);
    self.startTimer(.save, save_delay_ms);
}

/// Writes the recorded changes to the overlay file. On failure the
/// changes stay, the reason shows and the save is tried again later.
fn commitChanges(self: *Settings) bool {
    if (self.changes.isEmpty()) return true;
    const path = gx.config_layers.overlayPath(self.alloc) catch |err| return self.saveFailed(err);
    defer self.alloc.free(path);
    self.changes.commit(self.alloc, global.io(), path) catch |err| return self.saveFailed(err);
    self.save_attempts = 0;
    log.info("saved the settings to {s}", .{path});
    return true;
}

fn saveFailed(self: *Settings, err: anyerror) bool {
    log.warn("cannot save the settings err={}", .{err});
    self.save_attempts += 1;
    self.setStatusReason(.err, msg.save_failed, err);
    self.stopTimer(.save);
    if (model.saveRetryDelayMs(self.save_attempts)) |delay| {
        self.startTimer(.save, delay);
    } else {
        log.warn("gave up saving the settings after {d} attempts", .{self.save_attempts});
    }
    return false;
}

/// Saves the recorded changes and applies them. Returns whether the
/// configuration with them applies now.
fn saveNow(self: *Settings) bool {
    self.stopTimer(.save);
    if (self.changes.isEmpty()) return true;
    var theme_action = false;
    if (gx.perf.enabled()) {
        for (self.changes.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, "theme")) theme_action = true;
        }
    }
    if (!self.commitChanges()) return false;
    const preview = self.preview_theme orelse self.applied_preview;
    const preview_value: ?[:0]u8 = if (preview) |index| self.themeValue(self.alloc, index) else null;
    defer if (preview_value) |value| self.alloc.free(value);
    const ok = self.applyConfig(preview_value, theme_action);
    if (ok) self.setStatus(.success, "Settings saved.", .{});
    return ok;
}

/// Builds the configuration (from the layers, else from the files) with
/// `theme` as a preview override, applies it and shows its values. A
/// preview has no reload notification and saves nothing.
fn applyConfig(self: *Settings, theme: ?[]const u8, theme_action: bool) bool {
    const preview = theme != null;
    var quiet_buf: [128]u8 = undefined;
    var args: [2][:0]const u8 = undefined;
    var len: usize = 0;
    var theme_arg: ?[:0]u8 = null;
    defer if (theme_arg) |arg| self.alloc.free(arg);
    if (theme) |name| {
        args[0] = settings_map.quietReloadArg(&quiet_buf, self.notifications) catch |err| return self.applyFailed(preview, err);
        theme_arg = settings_map.themeArg(self.alloc, name) catch |err| return self.applyFailed(preview, err);
        args[1] = theme_arg.?;
        len = 2;
    }
    self.followReload();
    var config = self.buildConfig(args[0..len]) catch |err| return self.applyFailed(preview, err);
    defer config.deinit();
    self.applying = true;
    defer self.applying = false;
    if (gx.perf.enabled()) {
        if (theme_action or preview or self.app.config.changed(&config, .theme)) gx.perf.count("theme.reload", 1);
    }
    const applied = if (preview) @import("Menu.zig").applyThemePreview(self.app, &config) else self.app.applyConfig(&config);
    applied catch |err| return self.applyFailed(preview, err);
    self.applied_inputs = inputsDigest(&self.app.config);
    if (!preview) self.applied_preview = null;
    self.configApplied(preview);
    return true;
}

/// Reads the layers again when something else applied a configuration
/// (`reload_config`) since the overlay did, so a save or a preview does not
/// undo it. The changes not saved yet are kept.
fn followReload(self: *Settings) void {
    const layers = self.layersPtr() orelse return;
    if (inputsDigest(&self.app.config) == self.applied_inputs) return;
    log.info("the configuration was replaced, reading its layers again", .{});
    var fresh = App.loadLayers(self.alloc) catch |err| {
        log.warn("cannot read the configuration layers again err={}", .{err});
        return;
    };
    self.changes.applyToLayers(&fresh) catch |err| {
        log.warn("cannot keep the unsaved settings err={}", .{err});
    };
    layers.deinit();
    self.layers = fresh;
}

/// A digest of the recorded inputs of `config`: the same for a
/// configuration built from the same inputs.
fn inputsDigest(config: *const Config) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (config._replay_steps.items) |step| {
        hasher.update(@tagName(step));
        switch (step) {
            .arg => |arg| hasher.update(arg),
            .conditional_arg => |conditional| hasher.update(conditional.arg),
            else => {},
        }
        hasher.update(&.{0});
    }
    return hasher.final();
}

/// The configuration with `overrides`: built from the layers, else read
/// from the files.
fn buildConfig(self: *Settings, overrides: []const [:0]const u8) !Config {
    const blink = App.sampleSystemCursorBlink();
    if (self.layersPtr()) |layers| {
        _ = layers.setSystemCursorBlink(blink);
        return try layers.build(self.alloc, overrides);
    }
    if (overrides.len > 0) return try gx.config_layers.loadWithOverrides(self.alloc, overrides);
    return try Config.load(self.alloc);
}

fn applyFailed(self: *Settings, preview: bool, err: anyerror) bool {
    log.warn("cannot apply the configuration err={}", .{err});
    if (preview) {
        self.setStatusReason(.err, msg.preview_failed, err);
    } else {
        self.setStatusReason(.err, msg.reload_failed, err);
    }
    return false;
}

fn configApplied(self: *Settings, preview: bool) void {
    const config = &self.app.config;
    self.popup.applyTheme(self.tokens());
    self.popup.setAccessibleName(i18n.tr(msg.settings));
    self.values = .fromConfig(config, self.layersPtr());
    self.font_family = self.configuredFamily(self.arena.allocator());
    self.updateFontPicker();
    if (!preview) {
        self.notifications = config.@"app-notifications";
        self.rememberTheme(config);
        if (self.saved_theme) |saved| {
            if (self.theme_list.current() == null) self.theme_list.select(saved);
        }
    }
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
        self.setStatusReason(.err, msg.herdr_failed, err);
        return;
    };
    log.info("running {s} --gx-set-default-shell {s}", .{ herdr, gx_zsh });
    self.startTimer(.herdr, herdr_poll_ms);
}

/// Checks a running herdr; true when it finished (and the status line
/// changed).
fn pollHerdr(self: *Settings) bool {
    var run = self.herdr_run orelse {
        self.stopTimer(.herdr);
        return false;
    };
    // Report after the shell choice is saved, so its status does not hide
    // the result.
    if (self.timers.contains(.save)) return false;
    switch (run.poll()) {
        .running => {
            if (system.nowMs() -| run.started_ms < herdr_timeout_ms) return false;
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
    return true;
}

// -----------------------------------------------------------------------
// Timers
// -----------------------------------------------------------------------

const Timer = enum(usize) {
    save = 1,
    preview = 2,
    herdr = 3,
    /// Reads the swatches a paint left out and of the next page.
    prefetch = 4,
};

fn startTimer(self: *Settings, timer: Timer, ms: u32) void {
    const hwnd = self.popup.hwnd orelse return;
    if (w32.SetTimer(hwnd, @backingInt(timer), ms, @ptrCast(&timerProc)) != 0) self.timers.insert(timer);
}

fn stopTimer(self: *Settings, timer: Timer) void {
    if (!self.timers.contains(timer)) return;
    self.timers.remove(timer);
    if (self.popup.hwnd) |hwnd| _ = w32.KillTimer(hwnd, @backingInt(timer));
}

fn timerProc(hwnd: ?w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    const self = byPopup(hwnd) orelse {
        _ = w32.KillTimer(hwnd, id);
        return;
    };
    const timer = std.enums.fromInt(Timer, id) orelse return;
    switch (timer) {
        .save => {
            self.stopTimer(.save);
            _ = self.saveNow();
        },
        .preview => {
            self.stopTimer(.preview);
            self.previewNow();
        },
        .herdr => if (self.pollHerdr()) self.invalidate(),
        .prefetch => {
            self.stopTimer(.prefetch);
            if (self.prefetchSwatches()) self.invalidate();
        },
    }
}

fn byPopup(hwnd: ?w32.HWND) ?*Settings {
    if (hwnd == null) return null;
    var it = instances;
    while (it) |self| : (it = self.next) {
        if (self.popup.hwnd == hwnd) return self;
    }
    return null;
}

/// Reads the swatches of the themes on display and of the pages above and
/// below; true when it read any.
fn prefetchSwatches(self: *Settings) bool {
    if (!self.open or self.section != .appearance) return false;
    const names = self.namesOf(.themes);
    const matches = self.theme_list.matches.items;
    const visible = @max(self.theme_list.visible, 1);
    const start = self.theme_list.top -| visible;
    const end = @min(matches.len, self.theme_list.top + 2 * visible);
    var read = false;
    for (matches[start..end]) |index| {
        if (index >= names.len or self.swatches.map.contains(index)) continue;
        _ = self.swatches.get(self.alloc, global.io(), self.theme_dirs, index, names[index]);
        read = true;
    }
    self.swatches_pending = false;
    return read;
}

/// Timers the popup gets as WM_TIMER: the tooltip delay.
fn onPopupTimer(ctx: *anyopaque, popup: *Popup, id: usize) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    const hwnd = popup.hwnd orelse return;
    if (!self.tooltip.delayElapsed(hwnd, id)) return;
    const text: []const u8 = switch (self.tooltip.target) {
        .none => return,
        .close => i18n.tr("Close"),
        .reset => i18n.tr(msg.reset_to_default),
    };
    const hover = self.hover orelse return;
    const rect = self.hitRect(hover) orelse return;
    var window_rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &window_rect) == 0) return;
    const s = popup.scale();
    const anchor: w32.RECT = .{
        .left = window_rect.left + style.px(rect.x, s),
        .top = window_rect.top + style.px(rect.y, s),
        .right = window_rect.left + style.px(rect.x + rect.w, s),
        .bottom = window_rect.top + style.px(rect.y + rect.h, s),
    };
    self.tooltip.show(self.app, hwnd, self.window.scale, text, anchor);
}

fn onRepeat(ctx: *anyopaque, popup: *Popup, tag: u32) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    _ = popup;
    const step = std.enums.fromInt(Step, tag) orelse return;
    self.stepFontSize(step);
}

fn onMessage(ctx: *anyopaque, popup: *Popup, message: u32, wparam: usize, lparam: isize) bool {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    _ = popup;
    _ = wparam;
    _ = lparam;
    if (message != WM_FONTS_READY) return false;
    self.onFontsReady();
    return true;
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

/// `setStatus` with the translated reason of `err` as `{reason}`.
fn setStatusReason(self: *Settings, kind: StatusKind, comptime msgid: [:0]const u8, err: anyerror) void {
    self.setStatus(kind, msgid, .{ .reason = i18n.trRuntime(errorMessage(err)) });
}

fn errorMessage(err: anyerror) [:0]const u8 {
    const reason = settings_map.errorReason(err);
    return if (std.mem.eql(u8, reason, @errorName(err))) "An unexpected error occurred." else reason;
}

test "settings errors keep known reasons and localize unknown errors" {
    try std.testing.expectEqualStrings("Permission denied.", errorMessage(error.PermissionDenied));
    try std.testing.expectEqualStrings("The file is in use by another program.", errorMessage(error.SharingViolation));
    try std.testing.expectEqualStrings("An unexpected error occurred.", errorMessage(error.Unexpected));
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
    search,
    close,
    row: u16,
    chip: struct { row: u16, index: u8 },
    step: struct { row: u16, step: Step },
    /// The font size field.
    value: u16,
    item: struct { row: u16, index: u32 },
    field: u16,
    group_button: struct { row: u16, button: GroupButton },
    /// The reset button of a setting row.
    reset: u16,
};

const Hit = struct {
    rect: d2d.Rect,
    target: Target,
};

fn addHit(self: *Settings, rect: d2d.Rect, target: Target) void {
    const visible = hit_test.clip(rect, self.hit_clip) orelse return;
    if (self.hit_count >= self.hits.len) return;
    self.hits[self.hit_count] = .{ .rect = visible, .target = target };
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

fn hitRect(self: *const Settings, target: Target) ?d2d.Rect {
    var i = self.hit_count;
    while (i > 0) {
        i -= 1;
        if (std.meta.eql(self.hits[i].target, target)) return self.hits[i].rect;
    }
    return null;
}

fn isHover(self: *const Settings, target: Target) bool {
    const hover = self.hover orelse return false;
    return std.meta.eql(hover, target);
}

/// The state `target` draws in: pressed while the button that went down
/// on it is still down over it.
fn stateOf(self: *const Settings, target: Target, enabled: bool) draw.State {
    if (!enabled) return .{ .disabled = true };
    const hover = self.isHover(target);
    const pressed = if (self.pressed) |p| std.meta.eql(p, target) else false;
    return .{ .hover = hover, .pressed = hover and pressed };
}

fn setHover(self: *Settings, target: ?Target) void {
    const same = if (target) |t| self.isHover(t) else self.hover == null;
    if (same) return;
    self.hover = target;
    self.updateTooltip();
    // Drawn only: the accessible model does not include the hover, so
    // providers a client holds stay valid.
    self.popup.repaint();
}

fn updateTooltip(self: *Settings) void {
    const hwnd = self.popup.hwnd orelse return;
    const tip: Tip = if (self.hover) |hover| switch (hover) {
        .close => .close,
        .reset => |row| .{ .reset = row },
        .group_button => |button| if (button.button == .reset) .{ .reset = button.row } else .none,
        else => .none,
    } else .none;
    self.tooltip.setTarget(hwnd, tip);
}

fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    if (key.alt and key.vk == w32.VK_F4) {
        popup.dismiss(.owner);
        return true;
    }
    if (key.alt) return false;
    self.tooltip.hide();
    if (key.vk == w32.VK_F6 or (key.ctrl and key.vk == 'F')) {
        self.focusSearch(true);
        return true;
    }
    if (self.text_field == .search) {
        switch (key.vk) {
            w32.VK_LEFT, w32.VK_RIGHT, w32.VK_HOME, w32.VK_END, w32.VK_BACK, w32.VK_DELETE, w32.VK_SPACE => return false,
            w32.VK_RETURN => {
                var buf: [max_rows]Row = undefined;
                const rows = self.buildRows(&buf);
                if (self.searching() and self.focus < rows.len) self.activate(rows[self.focus]);
                return true;
            },
            w32.VK_UP, w32.VK_DOWN => if (!self.searching()) {
                self.text_field = null;
                self.popup.input.clear();
                self.syncTextField();
                self.focus_visible = true;
                self.invalidate();
                return true;
            },
            else => {},
        }
    }

    if (self.text_field == .font_size) {
        switch (key.vk) {
            w32.VK_RETURN => {
                self.endSizeEdit(true);
                self.focus_visible = true;
                return true;
            },
            w32.VK_ESCAPE => {
                self.endSizeEdit(false);
                return true;
            },
            w32.VK_UP, w32.VK_DOWN, w32.VK_TAB, w32.VK_PRIOR, w32.VK_NEXT => self.endSizeEdit(true),
            else => return false,
        }
    }
    if (key.vk == w32.VK_ESCAPE) {
        // A filter box with text: clear it first.
        if (self.text_field) |field| {
            if (self.queryOf(field).items.len > 0) {
                self.clearQuery(field);
                return true;
            }
        }
        if (self.reset_all.armed(system.nowMs())) {
            self.reset_all.cancel();
            self.invalidate();
            return true;
        }
        return false;
    }
    if (key.vk == w32.VK_TAB) {
        self.focus_visible = true;
        self.cycleSection(if (key.shift) -1 else 1);
        return true;
    }
    if (key.ctrl and (key.vk == w32.VK_NEXT or key.vk == w32.VK_PRIOR)) {
        self.focus_visible = true;
        self.cycleSection(if (key.vk == w32.VK_NEXT) 1 else -1);
        return true;
    }

    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    if (rows.len == 0) return false;
    if (self.focus >= rows.len or !rows[self.focus].focusable()) self.focus = self.defaultFocus(rows);
    const row = rows[self.focus];
    const field = listField(row.action);
    const list: ?*List = if (field) |f| self.listOf(f) else null;

    switch (key.vk) {
        w32.VK_UP, w32.VK_DOWN => {
            self.focus_visible = true;
            const delta: isize = if (key.vk == w32.VK_UP) -1 else 1;
            if (list) |l| {
                if (l.move(delta)) {
                    if (field == .themes) self.schedulePreview(.navigate);
                    self.invalidate();
                    return true;
                }
            }
            self.moveFocus(rows, delta);
            return true;
        },
        w32.VK_PRIOR, w32.VK_NEXT => {
            self.focus_visible = true;
            const up = key.vk == w32.VK_PRIOR;
            if (list) |l| {
                const page: isize = @intCast(@max(l.visible, 2) - 1);
                if (l.move(if (up) -page else page) and field == .themes) self.schedulePreview(.navigate);
                self.invalidate();
                return true;
            }
            const page = @max(body_line, self.body_view - body_line);
            self.scrollBody(if (up) -page else page);
            return true;
        },
        w32.VK_HOME, w32.VK_END => {
            const home = key.vk == w32.VK_HOME;
            if (list) |l| {
                if (!key.ctrl) return false;
                const far: isize = @intCast(l.matches.items.len);
                if (l.move(if (home) -far else far) and field == .themes) self.schedulePreview(.navigate);
                self.invalidate();
                return true;
            }
            self.focus_visible = true;
            self.scrollBody(if (home) -std.math.floatMax(f32) else std.math.floatMax(f32) / 2);
            return true;
        },
        w32.VK_LEFT, w32.VK_RIGHT => {
            const right = key.vk == w32.VK_RIGHT;
            switch (row.kind) {
                .choice => self.stepChoice(row, if (right) 1 else -1),
                .toggle => if (row.on != right) self.activate(row),
                .stepper => self.stepFontSize(if (right) .plus else .minus),
                .group => {
                    if (right and self.focus_button + 1 < row.buttons.len) self.focus_button += 1;
                    if (!right and self.focus_button > 0) self.focus_button -= 1;
                    self.showUiaFocus();
                    return true;
                },
                else => return false,
            }
            self.focus_visible = true;
            self.invalidate();
            return true;
        },
        w32.VK_RETURN, w32.VK_SPACE => {
            if (key.vk == w32.VK_SPACE and row.kind == .list) return false;
            self.focus_visible = true;
            switch (row.kind) {
                .group => {
                    if (row.buttons.len == 0) return false;
                    self.activateGroupButton(row, row.buttons[@min(self.focus_button, row.buttons.len - 1)]);
                },
                // Enter types the font size.
                .stepper => if (key.vk == w32.VK_RETURN) self.beginSizeEdit(row.value, true),
                else => self.activate(row),
            }
            return true;
        },
        w32.VK_OEM_PLUS, w32.VK_ADD, w32.VK_OEM_MINUS, w32.VK_SUBTRACT => {
            if (row.kind != .stepper) return false;
            const plus = key.vk == w32.VK_OEM_PLUS or key.vk == w32.VK_ADD;
            self.stepFontSize(if (plus) .plus else .minus);
            return true;
        },
        w32.VK_F2 => {
            if (row.kind != .stepper) return false;
            self.beginSizeEdit(row.value, true);
            return true;
        },
        w32.VK_BACK, w32.VK_DELETE => {
            if (row.kind == .list or (key.vk == w32.VK_BACK and row.kind != .stepper)) return false;
            self.resetRow(row);
            return true;
        },
        else => return false,
    }
}

fn clearQuery(self: *Settings, field: Field) void {
    self.queryOf(field).clearRetainingCapacity();
    self.popup.input.clear();
    self.refilter(field);
    switch (field) {
        .themes => if (self.preview_theme orelse self.saved_theme) |index| self.theme_list.select(index),
        .fonts, .font_size => if (self.font_picker.indexOf(self.font_family)) |index| self.font_list.select(index),
        .search => {
            var buf: [max_rows]Row = undefined;
            self.focus = self.defaultFocus(self.buildRows(&buf));
        },
    }
    self.invalidate();
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self: *Settings = @ptrCast(@alignCast(ctx));
    switch (event.kind) {
        .move => {
            self.pointer = event.pos;
            self.setHover(self.hitAt(event.pos));
            // A held size button repeats only while the pointer is on it.
            if (self.pressed) |pressed| if (pressed == .step and !self.isHover(pressed)) popup.stopRepeat();
        },
        .leave => {
            self.pointer = null;
            self.setHover(null);
            popup.stopRepeat();
        },
        .down, .double_click => {
            if (event.button != .left) return;
            if (system.nowMs() -| self.opened_ms < click_guard_ms) return;
            self.focus_visible = false;
            self.tooltip.hide();
            const target = self.hitAt(event.pos) orelse {
                self.endSizeEdit(true);
                // Only the focus ring goes; a committed size invalidated.
                return self.popup.repaint();
            };
            self.press(popup, target, event.kind == .double_click);
        },
        .up => {
            if (event.button != .left) return;
            popup.stopRepeat();
            const pressed = self.pressed orelse return;
            self.pressed = null;
            if (popup.hwnd) |hwnd| if (w32.GetCapture() == hwnd) {
                _ = w32.ReleaseCapture();
            };
            if (self.hitAt(event.pos)) |target| {
                if (std.meta.eql(target, pressed)) {
                    self.click(pressed);
                    return self.invalidate();
                }
            }
            // Released elsewhere: only the pressed look goes.
            self.popup.repaint();
        },
        .wheel => self.wheel(event.pos, event.wheel),
    }
}

/// The left button went down on `target`: list items, filter boxes and
/// the size buttons act now, everything else when it goes up over it.
fn press(self: *Settings, popup: *Popup, target: Target, double: bool) void {
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    switch (target) {
        .search => self.focusSearch(false),
        .item => |item| {
            if (item.row >= rows.len) return;
            self.focusRow(item.row);
            const field = listField(rows[item.row].action) orelse return;
            const list = self.listOf(field);
            if (item.index >= list.matches.items.len) return;
            list.cursor = item.index;
            if (double) return self.activate(rows[item.row]);
            if (field == .themes) self.schedulePreview(.click);
            // The list cursor is the selection the accessible model shows.
            return self.invalidate();
        },
        .field => |i| self.focusRow(i),
        .value => |i| {
            if (self.text_field == .font_size or i >= rows.len) return;
            self.focusRow(i);
            self.beginSizeEdit(rows[i].value, true);
        },
        .step => |step| {
            if (step.row >= rows.len) return;
            self.focusRow(step.row);
            self.stepFontSize(step.step);
            self.pressed = target;
            popup.startRepeat(@backingInt(step.step));
        },
        else => {
            self.pressed = target;
            if (popup.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
        },
    }
    // A focus move or the pressed look only changes what is drawn; model
    // edits (a stepped size, a committed edit) invalidated themselves.
    self.popup.focusMoved();
}

/// The left button went up over `target`, where it went down.
fn click(self: *Settings, target: Target) void {
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    switch (target) {
        .section => |section| return self.enterSection(section),
        .close => return self.popup.dismiss(.owner),
        .group_button => |button| {
            if (button.row >= rows.len) return;
            self.focusRow(button.row);
            const row = rows[button.row];
            if (std.mem.indexOfScalar(GroupButton, row.buttons, button.button)) |index| self.focus_button = index;
            self.activateGroupButton(row, button.button);
        },
        .reset => |i| if (i < rows.len) self.resetRow(rows[i]),
        .row => |i| {
            if (i >= rows.len) return;
            self.focusRow(i);
            switch (rows[i].kind) {
                .radio, .toggle, .button, .result => self.activate(rows[i]),
                else => {},
            }
        },
        .chip => |chip| {
            if (chip.row >= rows.len) return;
            self.focusRow(chip.row);
            self.setChoice(rows[chip.row], chip.index);
        },
        .step, .value, .item, .field, .search => {},
    }
    self.invalidate();
}

fn focusRow(self: *Settings, index: usize) void {
    if (self.focus != index) self.focus_button = 0;
    self.focus = index;
    self.syncTextField();
}

/// The list of the section, if it has one.
fn sectionList(self: *Settings) ?*List {
    return switch (self.section) {
        .appearance => &self.theme_list,
        .font => &self.font_list,
        else => null,
    };
}

fn wheel(self: *Settings, pos: d2d.Point, notches: f32) void {
    self.tooltip.hide();
    const wheel_setting = system.wheelScrollLines();
    if (self.list_area) |area| {
        if (area.contains(pos)) {
            if (self.sectionList()) |list| {
                const page: f32 = @floatFromInt(@max(list.visible, 2) - 1);
                const lines = self.wheel_lines.lines(notches, model.wheelLines(wheel_setting, page));
                if (lines == 0) return;
                if (list.scroll(lines)) return self.invalidate();
                // At the end of the list the page scrolls on.
            }
        }
    }
    const page_lines = @max(1, self.body_view / body_line - 1);
    self.scrollBody(-notches * model.wheelLines(wheel_setting, page_lines) * body_line);
}

fn scrollBody(self: *Settings, delta: f32) void {
    self.body_scroll = @max(0, self.body_scroll + delta);
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
    self.hit_clip = null;
    self.list_area = null;
    self.popup.input.field = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
    self.checkUiaHits();

    // What is under the pointer may have moved (scrolling, a new section).
    if (self.pointer) |pos| {
        const target = self.hitAt(pos);
        const same = if (target) |hit| self.isHover(hit) else self.hover == null;
        if (!same) {
            self.hover = target;
            self.updateTooltip();
            self.invalidate();
        }
    }
    if (self.open and self.swatches_pending and !self.timers.contains(.prefetch)) self.startTimer(.prefetch, 15);
}

fn paintSidebar(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, h: f32) void {
    canvas.fillRect(.{ .x = 0, .y = 0, .w = sidebar_width, .h = h }, t.surface);
    canvas.fillRect(.{ .x = sidebar_width - 1, .y = 0, .w = 1, .h = h }, t.border);

    // The title: the settings icon and the panel name in body large.
    const title_y = (header_height - style.type_ramp.body_large.line - style.space.s) / 2;
    canvas.drawIcon(draw.icons.settings, .{ .x = sidebar_inset + style.space.s, .y = title_y, .w = 22, .h = 28 }, style.type_ramp.body_large.size, t.accent);
    var title_style = style.type_ramp.body_large.text(t.text);
    title_style.weight = .semibold;
    canvas.drawText(i18n.tr(msg.settings), .{ .x = 48, .y = title_y, .w = sidebar_width - 48 - style.space.m, .h = 28 }, title_style);

    const search: d2d.Rect = .{ .x = sidebar_inset, .y = header_height - style.space.s, .w = sidebar_width - 2 * sidebar_inset, .h = field_height };
    if (self.text_field == .search) {
        self.popup.drawTextInputEx(canvas, search, t, .{ .placeholder = i18n.tr("Search settings…"), .focused = true });
    } else {
        canvas.fillRoundedRect(search, draw.radius, t.surface_raised);
        canvas.strokeRoundedRect(search, draw.radius, t.border, 1);
        canvas.drawText(i18n.tr("Search settings…"), search.inset(style.metrics.padding_x, 0), .{
            .size = style.font_size.body,
            .color = t.text_placeholder,
        });
    }
    self.addHit(search, .search);

    var y: f32 = search.y + search.h + style.space.m;
    for (std.enums.values(Section)) |section| {
        const item: d2d.Rect = .{ .x = sidebar_inset, .y = y, .w = sidebar_width - 2 * sidebar_inset, .h = sidebar_item_height };
        const selected = section == self.section and !self.searching();
        const state = self.stateOf(.{ .section = section }, true);
        if (selected) {
            canvas.fillRoundedRect(item, draw.radius, t.selected);
            draw.selectionIndicator(canvas, item, t);
        } else if (state.pressed) {
            canvas.fillRoundedRect(item, draw.radius, t.pressed);
        } else if (state.hover) {
            canvas.fillRoundedRect(item, draw.radius, t.hover);
        }
        const icon_rect: d2d.Rect = .{ .x = item.x + 12, .y = item.y + (item.h - 18) / 2, .w = 18, .h = 18 };
        const fluent_id: @import("fluent_icons.zig").Id = switch (section) {
            .language => .language,
            .appearance => .appearance,
            .font => .font,
            .interaction => .interaction,
            .shell => .shell,
            .about => .about,
        };
        if (!selected or !self.app.fluent_icons.draw(canvas, fluent_id, icon_rect, t.accent)) {
            canvas.drawIcon(sectionIcon(section), .{ .x = item.x + 12, .y = item.y, .w = 18, .h = item.h }, 15, if (selected) t.accent else t.text_secondary);
        }
        canvas.drawText(sectionTitle(section), .{ .x = item.x + 40, .y = item.y, .w = item.w - 48, .h = item.h }, .{
            .size = style.font_size.body,
            .weight = if (selected) .semibold else .normal,
            .color = if (selected) t.selected_text else t.text,
        });
        self.addHit(item, .{ .section = section });
        y += sidebar_item_height + sidebar_item_gap;
    }
}

fn paintHeader(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, w: f32) void {
    const close_y = (header_height - style.close_button.size) / 2;
    canvas.drawText(if (self.searching()) i18n.tr("Search Settings") else sectionTitle(self.section), .{
        .x = sidebar_width + content_pad,
        .y = close_y,
        .w = @max(0, w - sidebar_width - content_pad - 2 * style.close_button.size),
        .h = style.close_button.size,
    }, .{ .size = style.font_size.subtitle, .weight = .semibold, .color = t.text });
    const close: d2d.Rect = .{ .x = w - style.space.l - style.close_button.size, .y = close_y, .w = style.close_button.size, .h = style.close_button.size };
    draw.iconButton(canvas, close, d2d.icons.cancel, self.stateOf(.close, true), t);
    self.addHit(close, .close);
}

fn paintFooter(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, rect: d2d.Rect) void {
    canvas.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, t.border);
    var text_style: d2d.TextStyle = .{ .size = style.font_size.caption, .color = t.text_secondary };
    const text: []const u8 = switch (self.status_kind) {
        .none => if (self.font_loader != null and self.section == .font) i18n.tr("Loading font families…") else i18n.tr(msg.changes_saved),
        else => self.status_buf[0..self.status_len],
    };
    switch (self.status_kind) {
        .none, .info => {},
        .success => text_style.color = draw.successColor(t),
        .err => text_style.color = draw.errorColor(t),
    }

    const esc = if (self.text_field) |field|
        if (field != .font_size and self.queryOf(field).items.len > 0) i18n.tr("Clear Search") else i18n.tr("Close")
    else
        i18n.tr("Close");
    const hints = [_]struct { []const u8, []const u8 }{
        .{ if (self.searching()) "Enter" else "Tab", if (self.searching()) i18n.tr("Open") else i18n.tr("Switch Section") },
        .{ "Esc", esc },
    };
    var hints_w: f32 = 0;
    var widths: [hints.len]f32 = undefined;
    for (hints, &widths, 0..) |hint, *width, i| {
        width.* = draw.keyHintWidth(canvas, &self.measurements, hint[0], hint[1]);
        hints_w += width.* + if (i > 0) style.space.l else 0;
    }

    const full_w = @max(0, rect.w - 2 * content_pad);
    const fits = self.measurements.measure(canvas, text, text_style, 10_000).width <= full_w - hints_w - style.space.l;
    if (!fits) text_style.wrap = true;
    canvas.drawText(text, .{
        .x = rect.x + content_pad,
        .y = rect.y + 1,
        .w = if (fits) full_w - hints_w - style.space.l else full_w,
        .h = rect.h - 1,
    }, text_style);
    if (!fits) return;
    var x = rect.x + rect.w - content_pad - hints_w;
    for (hints, widths) |hint, width| {
        _ = draw.keyHint(canvas, &self.measurements, x, rect.y, rect.h, hint[0], hint[1], t);
        x += width + style.space.l;
    }
}

/// The height of a row, and whether the chips of a choice go on a line of
/// their own.
const Geometry = struct {
    height: f32,
    wrap: bool = false,
};

fn paintBody(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, body: d2d.Rect) void {
    var buf: [max_rows]Row = undefined;
    const rows = self.buildRows(&buf);
    if (rows.len == 0) return;
    if (self.focus >= rows.len or !rows[self.focus].focusable()) self.focus = self.defaultFocus(rows);
    self.body_view = body.h;

    const x = body.x + content_pad;
    const width = @max(0, body.w - 2 * content_pad);

    // Heights: a list takes what the rows above it and a part of those
    // below it leave, in whole items.
    var geometry: [max_rows]Geometry = undefined;
    var before: f32 = 0;
    var after: f32 = 0;
    var list_index: ?usize = null;
    for (rows, 0..) |row, i| {
        geometry[i] = self.rowGeometry(canvas, row, width);
        if (row.kind == .list) {
            list_index = i;
            continue;
        }
        if (list_index == null) before += geometry[i].height + row_gap else after += geometry[i].height + row_gap;
    }
    if (list_index) |li| {
        const peek = @min(after, list_peek);
        const available = body.h - top_pad - before - bottom_pad - peek - field_height - field_gap;
        const min_box = @as(f32, @floatFromInt(min_list_items)) * item_height + 2 * list_pad;
        const fit = model.fitList(@max(min_box, available), item_height, list_pad);
        geometry[li].height = field_height + field_gap + fit.box;
    }
    var content: f32 = top_pad + bottom_pad;
    for (geometry[0..rows.len], 0..) |g, i| content += g.height + if (i > 0) row_gap else 0;

    // Scrolling.
    const max_scroll = @max(0, content - body.h);
    if (self.reveal_focus) {
        self.reveal_focus = false;
        var row_top: f32 = top_pad;
        for (geometry[0..self.focus]) |g| row_top += g.height + row_gap;
        const row_bottom = row_top + geometry[self.focus].height;
        self.body_scroll = model.reveal(self.body_scroll, row_top, row_bottom, body.h, top_pad, max_scroll);
    }
    self.body_scroll = std.math.clamp(self.body_scroll, 0, max_scroll);

    canvas.pushClip(body);
    defer canvas.popClip();
    self.hit_clip = body;
    defer self.hit_clip = null;
    var y = body.y + top_pad - self.body_scroll;
    for (rows, 0..) |row, i| {
        const g = geometry[i];
        const rect: d2d.Rect = .{ .x = x, .y = y, .w = width, .h = g.height };
        if (rect.y + rect.h >= body.y and rect.y <= body.y + body.h) {
            self.paintRow(canvas, t, row, @intCast(i), rect, body, g);
        }
        y += g.height + row_gap;
    }

    if (max_scroll > 0) {
        const track_h = body.h - 8;
        const thumb_h = @max(24, track_h * body.h / content);
        const thumb_y = body.y + 4 + (track_h - thumb_h) * (self.body_scroll / max_scroll);
        canvas.fillRoundedRect(.{ .x = body.x + body.w - 6, .y = thumb_y, .w = 3, .h = thumb_h }, 1.5, t.text_tertiary);
    }
}

fn rowGeometry(self: *Settings, canvas: *d2d.Canvas, row: Row, width: f32) Geometry {
    return switch (row.kind) {
        .group => {
            var h: f32 = group_height;
            if (row.detail.len > 0) h += measureWrapped(canvas, row.detail, width);
            return .{ .height = h };
        },
        .note => .{ .height = measureWrapped(canvas, row.detail, width) + 4 },
        .radio, .toggle, .result => .{ .height = if (row.detail.len > 0) card_height_detail else card_height },
        .stepper => .{ .height = if (row.detail.len > 0) card_height_detail else choice_height },
        .choice => {
            if (row.chips_only) return .{ .height = choice_height };
            const base: f32 = if (row.detail.len > 0) card_height_detail else choice_height;
            const body_style: d2d.TextStyle = .{ .size = style.font_size.body, .ellipsis = false };
            const caption_style: d2d.TextStyle = .{ .size = style.font_size.caption, .ellipsis = false };
            var title_w = self.measurements.measure(canvas, row.title, body_style, 10_000).width;
            if (row.detail.len > 0) title_w = @max(title_w, self.measurements.measure(canvas, row.detail, caption_style, 10_000).width);
            const reset_w: f32 = if (row.resettable) draw.icon_button_size + card_inner_gap else 0;
            const chips_w = draw.chipsWidth(canvas, &self.measurements, row.choices, row.dots.len > 0);
            const wrap = model.chipsWrap(title_w, chips_w + reset_w, card_pad, width - 2 * card_pad);
            return .{ .height = if (wrap) base + chip_line else base, .wrap = wrap };
        },
        .info => .{ .height = card_height_detail },
        .button => .{ .height = draw.button_height + style.space.s },
        .sample => .{ .height = sample_height },
        .list => .{ .height = 0 },
    };
}

fn captionStyle(t: style.Tokens, warning: bool) d2d.TextStyle {
    return .{
        .size = style.font_size.caption,
        .color = if (warning) draw.cautionColor(t) else t.text_secondary,
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

fn paintRow(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, row: Row, index: u16, rect: d2d.Rect, body: d2d.Rect, geometry: Geometry) void {
    const ring = index == self.focus and row.focusable() and self.focus_visible;
    const title_style: d2d.TextStyle = .{ .size = style.font_size.body, .color = t.text };
    const row_state = self.stateOf(.{ .row = index }, true);
    switch (row.kind) {
        .group => {
            var bx = rect.x + rect.w;
            var i = row.buttons.len;
            while (i > 0) {
                i -= 1;
                const button = row.buttons[i];
                const target: Target = .{ .group_button = .{ .row = index, .button = button } };
                const enabled = self.groupButtonEnabled(button);
                var state = self.stateOf(target, enabled);
                state.focused = ring and @min(self.focus_button, row.buttons.len - 1) == i;
                if (button == .reset) {
                    bx -= draw.icon_button_size;
                    const brect: d2d.Rect = .{ .x = bx, .y = rect.y + (group_height - draw.icon_button_size) / 2, .w = draw.icon_button_size, .h = draw.icon_button_size };
                    draw.iconButton(canvas, brect, draw.icons.reset, state, t);
                    self.addHit(brect, target);
                } else {
                    const label = i18n.tr(msg.apply);
                    const bw = draw.buttonWidth(canvas, &self.measurements, label, null);
                    bx -= bw;
                    const brect: d2d.Rect = .{ .x = bx, .y = rect.y + (group_height - draw.button_height) / 2, .w = bw, .h = draw.button_height };
                    draw.button(canvas, brect, label, null, .primary, state, t);
                    if (enabled) self.addHit(brect, target);
                }
                bx -= card_inner_gap;
            }
            var group_style = title_style;
            group_style.weight = .semibold;
            canvas.drawText(row.title, .{ .x = rect.x, .y = rect.y, .w = @max(0, bx - rect.x), .h = group_height }, group_style);
            if (row.detail.len > 0) {
                canvas.drawText(row.detail, .{ .x = rect.x, .y = rect.y + group_height, .w = rect.w, .h = rect.h - group_height }, captionStyle(t, row.detail_warning));
            }
            return;
        },
        .note => return canvas.drawText(row.detail, .{ .x = rect.x, .y = rect.y + 2, .w = rect.w, .h = rect.h }, captionStyle(t, row.detail_warning)),
        .result => {
            draw.card(canvas, rect, t, row_state);
            self.paintTitle(canvas, t, row, .{ .x = rect.x + card_pad, .y = rect.y, .w = rect.w - 60, .h = rect.h });
            canvas.drawIcon(0xE76C, .{ .x = rect.x + rect.w - 32, .y = rect.y, .w = 20, .h = rect.h }, style.icon.small, t.text_secondary);
            self.addHit(rect, .{ .row = index });
        },
        .radio => {
            draw.card(canvas, rect, t, row_state);
            draw.radio(canvas, .{ .x = rect.x + style.space.m, .y = rect.y, .w = 24, .h = rect.h }, row.on, row_state, t);
            self.paintTitle(canvas, t, row, .{ .x = rect.x + 48, .y = rect.y, .w = rect.w - 48 - card_pad, .h = rect.h });
            self.addHit(rect, .{ .row = index });
        },
        .toggle => {
            draw.card(canvas, rect, t, row_state);
            self.addHit(rect, .{ .row = index });
            const sw: d2d.Rect = .{
                .x = rect.x + rect.w - card_pad - draw.switch_width,
                .y = rect.y + (rect.h - draw.switch_height) / 2,
                .w = draw.switch_width,
                .h = draw.switch_height,
            };
            draw.switchControl(canvas, sw, row.on, row_state, t);
            var right = sw.x - card_inner_gap;
            if (row.resettable) right = self.paintReset(canvas, t, index, right, rect.y + (rect.h - draw.icon_button_size) / 2) - card_inner_gap;
            self.paintTitle(canvas, t, row, .{ .x = rect.x + card_pad, .y = rect.y, .w = @max(0, right - rect.x - card_pad), .h = rect.h });
        },
        .choice => {
            draw.card(canvas, rect, t, .{});
            self.addHit(rect, .{ .row = index });
            const head_h = if (geometry.wrap) rect.h - chip_line else rect.h;
            const dotted = row.dots.len > 0;
            const chips_w = draw.chipsWidth(canvas, &self.measurements, row.choices, dotted);
            const chips_left = rect.x + rect.w - style.space.m - chips_w;
            var cx = if (geometry.wrap or row.chips_only) rect.x + card_pad else chips_left;
            const cy = if (geometry.wrap) rect.y + head_h - 2 else rect.y + (rect.h - draw.chip_height) / 2;
            for (row.choices, 0..) |label, i| {
                if (i >= 8) break;
                const chip_w = draw.chipWidth(canvas, &self.measurements, label, dotted);
                const chip_rect: d2d.Rect = .{ .x = cx, .y = cy, .w = chip_w, .h = draw.chip_height };
                const enabled = row.disabled & (@as(u8, 1) << @intCast(i)) == 0;
                const target: Target = .{ .chip = .{ .row = index, .index = @intCast(i) } };
                const dot: ?d2d.Color = if (i < row.dots.len) row.dots[i] else null;
                draw.chip(canvas, chip_rect, label, row.choice == i, dot, self.stateOf(target, enabled), t);
                if (enabled) self.addHit(chip_rect, target);
                cx += chip_w + draw.chip_gap;
            }
            if (row.chips_only) {
                // The group row above names the chips and has the reset button.
                if (ring) draw.focusRing(canvas, rect, draw.radius, t);
                return;
            }
            var right = if (geometry.wrap) rect.x + rect.w - style.space.m else chips_left - card_inner_gap;
            if (row.resettable) right = self.paintReset(canvas, t, index, right, rect.y + (head_h - draw.icon_button_size) / 2) - card_inner_gap;
            self.paintTitle(canvas, t, row, .{ .x = rect.x + card_pad, .y = rect.y, .w = @max(0, right - rect.x - card_pad), .h = head_h });
        },
        .stepper => {
            draw.card(canvas, rect, t, .{});
            self.addHit(rect, .{ .row = index });
            const FontSize = settings_map.FontSize;
            const by = rect.y + (rect.h - draw.button_height) / 2;
            const plus: d2d.Rect = .{ .x = rect.x + rect.w - style.space.m - draw.button_height, .y = by, .w = draw.button_height, .h = draw.button_height };
            const value: d2d.Rect = .{ .x = plus.x - style.space.xs - 64, .y = by, .w = 64, .h = draw.button_height };
            const minus: d2d.Rect = .{ .x = value.x - style.space.xs - draw.button_height, .y = by, .w = draw.button_height, .h = draw.button_height };
            const steps = [_]struct { d2d.Rect, Step, u21, bool }{
                .{ minus, .minus, draw.icons.remove, self.values.font_size > FontSize.min },
                .{ plus, .plus, draw.icons.add, self.values.font_size < FontSize.max },
            };
            for (steps) |step| {
                const target: Target = .{ .step = .{ .row = index, .step = step[1] } };
                draw.button(canvas, step[0], "", step[2], .normal, self.stateOf(target, step[3]), t);
                if (step[3]) self.addHit(step[0], target);
            }
            if (self.text_field == .font_size) {
                self.popup.drawTextInputEx(canvas, value, t, .{ .focused = true });
            } else {
                const value_state = self.stateOf(.{ .value = index }, true);
                canvas.fillRoundedRect(value, draw.radius, if (value_state.hover) style.hoverOf(t.surface_raised, t) else t.surface_raised);
                canvas.strokeRoundedRect(value, draw.radius, t.border, 1);
                canvas.drawText(row.value, value, .{ .size = style.font_size.body, .weight = .semibold, .color = t.text, .align_x = .center });
            }
            self.addHit(value, .{ .value = index });
            var right = minus.x - card_inner_gap;
            if (row.resettable) right = self.paintReset(canvas, t, index, right, rect.y + (rect.h - draw.icon_button_size) / 2) - card_inner_gap;
            self.paintTitle(canvas, t, row, .{ .x = rect.x + card_pad, .y = rect.y, .w = @max(0, right - rect.x - card_pad), .h = rect.h });
        },
        .list => return self.paintList(canvas, t, row, index, rect, body),
        .info => {
            draw.card(canvas, rect, t, .{});
            const two_line = twoLineTop(rect);
            canvas.drawText(row.title, .{ .x = rect.x + card_pad, .y = two_line, .w = rect.w - 2 * card_pad, .h = style.type_ramp.body.line }, title_style);
            canvas.drawTextMiddle(row.detail, .{ .x = rect.x + card_pad, .y = two_line + style.type_ramp.body.line, .w = rect.w - 2 * card_pad, .h = style.type_ramp.caption.line }, .{
                .size = style.font_size.caption,
                .color = t.text_secondary,
            });
            return;
        },
        .button => {
            const bw = draw.buttonWidth(canvas, &self.measurements, row.title, row.icon);
            const brect: d2d.Rect = .{ .x = rect.x, .y = rect.y + style.space.xs, .w = bw, .h = draw.button_height };
            var state = row_state;
            state.focused = ring;
            draw.button(canvas, brect, row.title, row.icon, .normal, state, t);
            self.addHit(brect, .{ .row = index });
            return;
        },
        .sample => {
            const size_dip = std.math.clamp(self.values.font_size * 4.0 / 3.0, 8, sample_height - 12);
            return draw.fontSample(canvas, rect, self.sampleFamily(), size_dip, t);
        },
    }
    if (ring) draw.focusRing(canvas, rect, draw.radius, t);
}

/// A reset button whose right edge is at `right`, top at `y`; returns its
/// left edge.
fn paintReset(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, index: u16, right: f32, y: f32) f32 {
    const rect: d2d.Rect = .{ .x = right - draw.icon_button_size, .y = y, .w = draw.icon_button_size, .h = draw.icon_button_size };
    const target: Target = .{ .reset = index };
    draw.iconButton(canvas, rect, draw.icons.reset, self.stateOf(target, true), t);
    self.addHit(rect, target);
    return rect.x;
}

/// The title of a card row with its optional detail line.
fn paintTitle(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, row: Row, rect: d2d.Rect) void {
    _ = self;
    const title_style: d2d.TextStyle = .{ .size = style.font_size.body, .color = t.text };
    if (row.detail.len == 0) {
        canvas.drawText(row.title, rect, title_style);
        return;
    }
    const top = twoLineTop(rect);
    canvas.drawText(row.title, .{ .x = rect.x, .y = top, .w = rect.w, .h = style.type_ramp.body.line }, title_style);
    canvas.drawText(row.detail, .{ .x = rect.x, .y = top + style.type_ramp.body.line, .w = rect.w, .h = style.type_ramp.caption.line }, .{
        .size = style.font_size.caption,
        .color = if (row.detail_warning) draw.cautionColor(t) else t.text_secondary,
    });
}

/// The top of a title over a detail line (body over caption) centered in
/// `rect`.
fn twoLineTop(rect: d2d.Rect) f32 {
    return rect.y + (rect.h - style.type_ramp.body.line - style.type_ramp.caption.line) / 2;
}

fn groupButtonEnabled(self: *Settings, button: GroupButton) bool {
    return switch (button) {
        .reset => true,
        .apply_theme => if (self.theme_list.current()) |index| index != self.saved_theme else false,
        .apply_font => if (self.font_list.current()) |index|
            !std.mem.eql(u8, self.font_picker.names[index], self.font_family)
        else
            std.mem.trim(u8, self.font_query.items, &std.ascii.whitespace).len > 0,
    };
}

/// The family the font sample shows: the one under the cursor while the
/// list has the focus, else the configured one.
fn sampleFamily(self: *Settings) []const u8 {
    if (self.text_field == .fonts) {
        if (self.font_list.current()) |index| {
            if (index < self.font_picker.names.len) return self.font_picker.names[index];
        }
    }
    return self.font_family;
}

fn paintList(self: *Settings, canvas: *d2d.Canvas, t: style.Tokens, row: Row, index: u16, rect: d2d.Rect, body: d2d.Rect) void {
    const field: Field = listField(row.action) orelse return;
    const list = self.listOf(field);
    const names = self.namesOf(field);
    const focused = index == self.focus;
    const placeholder = switch (field) {
        .themes => i18n.tr(msg.search_themes),
        .fonts, .font_size => i18n.tr("Search font families…"),
        .search => unreachable,
    };

    // The filter box.
    const field_rect: d2d.Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = field_height };
    if (focused and self.text_field == field) {
        self.popup.drawTextInput(canvas, field_rect, t, placeholder);
    } else {
        canvas.fillRoundedRect(field_rect, draw.radius, t.surface);
        canvas.strokeRoundedRect(field_rect, draw.radius, t.border, 1);
        const query = self.queryOf(field).items;
        canvas.drawText(if (query.len > 0) query else placeholder, field_rect.inset(style.metrics.padding_x, 0), .{
            .size = style.font_size.body,
            .color = if (query.len > 0) t.text else t.text_placeholder,
        });
    }
    self.addHit(field_rect, .{ .field = index });

    // The list, sized to whole items by `paintBody`.
    const box: d2d.Rect = .{ .x = rect.x, .y = rect.y + field_height + field_gap, .w = rect.w, .h = @max(0, rect.h - field_height - field_gap) };
    canvas.fillRoundedRect(box, draw.radius, t.surface);
    canvas.strokeRoundedRect(box, draw.radius, if (focused) style.mix(t.border, t.accent, 0.5) else t.border, 1);
    self.list_area = hit_test.intersect(box, body);

    const matches = list.matches.items;
    const visible: usize = @max(1, @as(usize, @intFromFloat(@floor((box.h - 2 * list_pad) / item_height + 0.001))));
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
            .fonts, .font_size => if (self.fonts == null and self.font_loader != null)
                i18n.tr("Loading font families…")
            else
                i18n.tr("No matching fonts"),
            .search => unreachable,
        };
        canvas.drawText(empty, box, .{ .size = style.font_size.body, .color = t.text_secondary, .align_x = .center });
        return;
    }

    const scrollbar_w: f32 = if (matches.len > visible) 8 else 0;
    canvas.pushClip(box.inset(1, 1));
    defer canvas.popClip();
    const saved: ?u32 = switch (field) {
        .themes => self.saved_theme,
        .fonts, .font_size => self.font_picker.indexOf(self.font_family),
        .search => unreachable,
    };
    var i = list.top;
    while (i < matches.len and i < list.top + visible) : (i += 1) {
        const name_index = matches[i];
        if (name_index >= names.len) continue;
        const item_rect: d2d.Rect = .{
            .x = box.x + list_pad,
            .y = box.y + list_pad + @as(f32, @floatFromInt(i - list.top)) * item_height,
            .w = box.w - 2 * list_pad - scrollbar_w,
            .h = item_height,
        };
        const target: Target = .{ .item = .{ .row = index, .index = @intCast(i) } };
        if (i == list.cursor) {
            canvas.fillRoundedRect(item_rect, draw.radius, if (focused) t.selected else style.mix(t.surface, t.selected, 0.6));
            if (focused) draw.selectionIndicator(canvas, item_rect, t);
        } else if (self.isHover(target)) {
            canvas.fillRoundedRect(item_rect, draw.radius, t.hover);
        }
        const text_color = if (i == list.cursor and focused) t.selected_text else t.text;
        var right = item_rect.x + item_rect.w - style.space.s;
        if (field == .themes) {
            const swatch_rect: d2d.Rect = .{
                .x = right - draw.swatch_width,
                .y = item_rect.y + style.space.xs,
                .w = draw.swatch_width,
                .h = item_rect.h - 2 * style.space.xs,
            };
            if (self.swatches.map.get(name_index)) |colors| {
                draw.themeSwatch(canvas, swatch_rect, colors, t);
            } else {
                draw.swatchPlaceholder(canvas, swatch_rect, t);
                self.swatches_pending = true;
            }
            right = swatch_rect.x - style.space.s;
        }
        if (saved == name_index) {
            canvas.drawIcon(draw.icons.check, .{ .x = right - 20, .y = item_rect.y, .w = 20, .h = item_rect.h }, style.icon.small, t.accent);
            right -= 20 + style.space.s;
        }
        const name_style: d2d.TextStyle = .{
            .size = style.font_size.body,
            .color = text_color,
            .weight = if (saved == name_index) .semibold else .normal,
        };
        const name_rect: d2d.Rect = .{ .x = item_rect.x + style.space.m, .y = item_rect.y, .w = @max(0, right - item_rect.x - style.space.m), .h = item_rect.h };
        const local: ?[:0]const u8 = if (field != .themes and name_index < self.font_picker.local_names.len) self.font_picker.local_names[name_index] else null;
        if (local) |local_name| {
            const name_w = @min(name_rect.w * 0.6, @ceil(canvas.measureText(names[name_index], name_style, 10_000).width));
            canvas.drawText(names[name_index], .{ .x = name_rect.x, .y = name_rect.y, .w = name_w, .h = name_rect.h }, name_style);
            canvas.drawText(local_name, .{ .x = name_rect.x + name_w + style.space.m, .y = name_rect.y, .w = @max(0, name_rect.w - name_w - style.space.m), .h = name_rect.h }, .{
                .size = style.font_size.caption,
                .color = if (i == list.cursor and focused) t.selected_text else t.text_secondary,
                .align_x = .trailing,
            });
        } else {
            canvas.drawText(names[name_index], name_rect, name_style);
        }
        self.addHit(item_rect, target);
    }
    if (field == .themes and !self.swatches_pending) {
        // Read the pages around the view after this paint.
        const start = list.top -| visible;
        const end = @min(matches.len, list.top + 2 * visible);
        for (matches[start..end]) |name_index| {
            if (!self.swatches.map.contains(name_index)) {
                self.swatches_pending = true;
                break;
            }
        }
    }

    if (scrollbar_w > 0) {
        const track_h = box.h - 8;
        const len_f: f32 = @floatFromInt(matches.len);
        const thumb_h = @max(20, track_h * @as(f32, @floatFromInt(visible)) / len_f);
        const max_top: f32 = @floatFromInt(matches.len - visible);
        const thumb_y = box.y + 4 + (track_h - thumb_h) * (@as(f32, @floatFromInt(list.top)) / @max(max_top, 1));
        canvas.fillRoundedRect(.{ .x = box.x + box.w - 7, .y = thumb_y, .w = 3, .h = thumb_h }, 1.5, t.text_tertiary);
    }
}

test "UIA segmented choice exposes row focus even when first option is disabled" {
    var settings: Settings = undefined;
    settings.popup = .{};
    settings.popup.focused = true;
    settings.text_field = null;
    settings.focus = 0;
    const rows = &.{Row{ .kind = .choice, .choices = &.{ "A", "B" }, .disabled = 1 }};
    const disabled = settings.uiaControlState(.{ .chip = .{ .row = 0, .index = 0 } }, rows);
    try std.testing.expect(!disabled.enabled);
    try std.testing.expect(disabled.container_focusable and disabled.container_focused);
    try std.testing.expect(!disabled.focusable and !disabled.focused);
    settings.text_field = .search;
    try std.testing.expect(!settings.uiaControlState(.{ .chip = .{ .row = 0, .index = 1 } }, rows).container_focused);
    settings.text_field = null;
    settings.popup.focused = false;
    try std.testing.expect(!settings.uiaControlState(.{ .chip = .{ .row = 0, .index = 1 } }, rows).container_focused);
}

test "font families match by their English or local name" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const names = [_][:0]const u8{ "Cascadia Mono", "Microsoft YaHei Mono", "Sarasa Mono SC" };
    const local = [_]?[:0]const u8{ null, "微软雅黑 Mono", "更纱黑体 SC" };
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(alloc);

    try filterNames(alloc, &names, &local, "", &out);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, out.items);
    try filterNames(alloc, &names, &local, "yahei", &out);
    try testing.expectEqualSlices(u32, &.{1}, out.items);
    // The local name, and its pinyin initials.
    try filterNames(alloc, &names, &local, "雅黑", &out);
    try testing.expectEqualSlices(u32, &.{1}, out.items);
    try filterNames(alloc, &names, &local, "gs", &out);
    try testing.expectEqualSlices(u32, &.{2}, out.items);
    // Missing local names are fine.
    try filterNames(alloc, &names, &.{}, "cascadia", &out);
    try testing.expectEqualSlices(u32, &.{0}, out.items);
    try filterNames(alloc, &names, &local, "zzz", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the inputs digest follows the recorded inputs" {
    const testing = std.testing;
    var a = try Config.default(testing.allocator);
    defer a.deinit();
    var b = try Config.default(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(inputsDigest(&a), inputsDigest(&b));
    try gx.config_layers.applyArg(&b, testing.allocator, "--font-size=15");
    try testing.expect(inputsDigest(&a) != inputsDigest(&b));
}

test "settings search matches labels, sections, keys and pinyin" {
    const testing = std.testing;
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = [_]Row{
        .{ .kind = .group, .title = "字体" },
        .{ .kind = .stepper, .action = .font_size, .title = "字号", .keys = keys_font_size },
        .{ .kind = .list, .action = .font_family, .keys = keys_font_family },
        .{ .kind = .note, .detail = "font-size" },
    };
    for ([_][]const u8{ "font-size", "字号", "zihao", "zh", "字体 字号", "ＦＯＮＴ－ＳＩＺＥ" }) |pattern| {
        var buf: [max_rows]Row = undefined;
        var out: RowList = .{ .buf = &buf };
        const query: fuzzy.Query = .init(pattern);
        appendSearchRows(&out, .font, "Font", &source, &query, alloc);
        try testing.expect(out.len >= 2);
        try testing.expectEqual(RowKind.group, out.items()[0].kind);
        try testing.expectEqual(RowKind.result, out.items()[1].kind);
        try testing.expectEqual(Section.font, out.items()[1].action.goto.section);
        try testing.expectEqual(@as(u16, 1), out.items()[1].action.goto.row);
    }
    var buf: [max_rows]Row = undefined;
    var out: RowList = .{ .buf = &buf };
    const query: fuzzy.Query = .init("font-family");
    appendSearchRows(&out, .font, "Font", &source, &query, alloc);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u16, 2), out.items()[1].action.goto.row);
    try testing.expectEqualStrings("字体", out.items()[1].title);
}

test "a search result clears the query and reveals its setting without changing it" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    var self: Settings = .{
        .alloc = testing.allocator,
        .app = undefined,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
        .values = .fromConfig(&config, null),
        .text_field = .search,
    };
    defer self.arena.deinit();
    defer self.scratch.deinit();
    defer self.font_arena.deinit();
    defer self.changes.deinit();
    defer self.search_query.deinit(testing.allocator);
    try self.search_query.appendSlice(testing.allocator, "font-size");
    const original = self.values.font_size;
    self.gotoSetting(.{ .section = .font, .row = 0 });
    try testing.expectEqual(Section.font, self.section);
    try testing.expectEqual(@as(usize, 0), self.focus);
    try testing.expect(self.focus_visible and self.reveal_focus);
    try testing.expectEqual(@as(usize, 0), self.search_query.items.len);
    try testing.expect(self.text_field == null);
    try testing.expectEqual(original, self.values.font_size);
    try testing.expect(self.changes.isEmpty());
}

test "theme previews read back other settings without committing the preview" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.@"font-size" = 17;
    config.@"app-notifications".@"config-reload" = false;
    var app: App = undefined;
    app.config = config;
    var self: Settings = .{
        .alloc = testing.allocator,
        .app = &app,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
        .values = .fromConfig(&config, null),
        .saved_theme = 7,
    };
    defer self.arena.deinit();
    defer self.scratch.deinit();
    defer self.font_arena.deinit();
    defer self.changes.deinit();
    defer self.font_list.deinit(testing.allocator);
    const notifications = self.notifications;
    self.values.font_size = 13;
    self.configApplied(true);
    try testing.expectEqual(@as(f32, 17), self.values.font_size);
    try testing.expectEqual(@as(?u32, 7), self.saved_theme);
    try testing.expect(std.meta.eql(notifications, self.notifications));
    try testing.expect(self.changes.isEmpty());
}

test "activation spaces outside a field do not change focus or start a preview" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    var self: Settings = .{
        .alloc = testing.allocator,
        .app = undefined,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
        .values = .fromConfig(&config, null),
        .focus = 2,
    };
    defer self.arena.deinit();
    defer self.scratch.deinit();
    defer self.font_arena.deinit();
    defer self.changes.deinit();
    defer self.popup.input.deinit(testing.allocator);
    defer self.search_query.deinit(testing.allocator);
    defer self.theme_query.deinit(testing.allocator);
    for ([_][]const u8{ " ", "\t", "\u{3000}" }) |text| {
        try self.popup.input.setText(testing.allocator, text);
        self.typedElsewhere(&self.popup);
        try testing.expectEqual(@as(usize, 2), self.focus);
        try testing.expect(self.text_field == null);
        try testing.expect(self.preview_theme == null);
        try testing.expectEqual(@as(usize, 0), self.popup.input.buf.items.len);
        try testing.expectEqual(@as(usize, 0), self.search_query.items.len);
        try testing.expectEqual(@as(usize, 0), self.theme_query.items.len);
    }
}

test "settings sizes follow the shared metrics" {
    const testing = std.testing;
    const ui_metrics = gx.ui_metrics;
    try testing.expectEqual(ui_metrics.space.xl, content_pad);
    try testing.expectEqual(ui_metrics.space.s, top_pad);
    try testing.expectEqual(ui_metrics.space.l, bottom_pad);
    try testing.expectEqual(ui_metrics.space.s, row_gap);
    try testing.expectEqual(ui_metrics.space.l, card_pad);
    try testing.expectEqual(ui_metrics.row.two_line, card_height_detail);
    try testing.expectEqual(ui_metrics.control.height + 2 * ui_metrics.space.s, choice_height);
    try testing.expectEqual(ui_metrics.row.header, group_height);
    try testing.expectEqual(ui_metrics.row.menu, item_height);
    try testing.expectEqual(ui_metrics.row.list, sidebar_item_height);
    try testing.expectEqual(ui_metrics.control.height, field_height);
    try testing.expectEqual(ui_metrics.radius.control, draw.radius);
    try testing.expectEqual(ui_metrics.control.height, draw.button_height);
    try testing.expectEqual(ui_metrics.control.compact, draw.chip_height);
    // A title and a detail line fit a two-line card.
    try testing.expect(style.type_ramp.body.line + style.type_ramp.caption.line <= card_height_detail - 2 * style.space.s);
    // The sizes the panel keeps stay on the 4 DIP grid.
    for ([_]f32{ sidebar_width, header_height, footer_height, card_height, list_peek, sample_height, body_line }) |size| {
        try testing.expectEqual(@as(f32, 0), @mod(size, 4));
    }
}

/// An overlay without a window for the tests of its model; `app` only
/// answers what the rows of the Appearance section ask.
fn testSettings(config: *const Config, app: *App) Settings {
    const testing = std.testing;
    app.alpha_frames = true;
    return .{
        .alloc = testing.allocator,
        .app = app,
        .window = undefined,
        .arena = .init(testing.allocator),
        .scratch = .init(testing.allocator),
        .font_arena = .init(testing.allocator),
        .changes = .init(testing.allocator),
        .values = .fromConfig(config, null),
    };
}

fn testSettingsDeinit(self: *Settings) void {
    self.arena.deinit();
    self.scratch.deinit();
    self.font_arena.deinit();
    self.changes.deinit();
    self.theme_list.deinit(std.testing.allocator);
    if (self.themes) |*themes| themes.deinit();
}

fn testThemes(self: *Settings, names: []const [:0]const u8) !void {
    self.themes = .{ .arena = .init(std.testing.allocator), .names = names };
    try self.theme_list.matches.ensureTotalCapacity(std.testing.allocator, names.len);
    for (0..names.len) |i| self.theme_list.matches.appendAssumeCapacity(@intCast(i));
}

test "a light and dark pair edits one half and keeps the other" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.theme = .{ .light = "GX Latte", .dark = "GX Mocha" };
    var app: App = undefined;
    var self = testSettings(&config, &app);
    defer testSettingsDeinit(&self);
    try testThemes(&self, &.{ "Dracula", "GX Latte", "GX Mocha", "Nord" });

    self.theme_half = .dark;
    self.rememberTheme(&config);
    try testing.expect(self.themePair() != null);
    try testing.expectEqual(@as(?u32, 2), self.saved_theme);
    {
        const value = self.themeValue(testing.allocator, 0).?;
        defer testing.allocator.free(value);
        try testing.expectEqualStrings("light:GX Latte,dark:Dracula", value);
    }

    // The light half: the list marks GX Latte and keeps the dark theme.
    self.setThemeHalf(.light);
    try testing.expectEqual(settings_map.ThemeHalf.light, self.theme_half);
    try testing.expectEqual(@as(?u32, 1), self.saved_theme);
    try testing.expectEqual(@as(?u32, 1), self.theme_list.current());
    {
        const value = self.themeValue(testing.allocator, 3).?;
        defer testing.allocator.free(value);
        try testing.expectEqualStrings("light:Nord,dark:GX Mocha", value);
    }

    // The pair shows the chips of its halves above the list.
    var buf: [max_rows]Row = undefined;
    const rows = self.buildSectionRows(.appearance, &buf);
    var half_row: ?Row = null;
    for (rows) |row| if (row.action == .theme_half) {
        half_row = row;
    };
    try testing.expectEqual(@as(?usize, 0), half_row.?.choice);
    try testing.expect(std.mem.indexOf(u8, rows[0].detail, "GX Latte") != null);
    try testing.expect(std.mem.indexOf(u8, rows[0].detail, "GX Mocha") != null);
}

test "one theme edits the theme alone" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.theme = .{ .light = "Nord", .dark = "Nord" };
    var app: App = undefined;
    var self = testSettings(&config, &app);
    defer testSettingsDeinit(&self);
    try testThemes(&self, &.{ "Dracula", "Nord" });
    self.rememberTheme(&config);
    try testing.expect(self.themePair() == null);
    try testing.expectEqual(@as(?u32, 1), self.saved_theme);
    const value = self.themeValue(testing.allocator, 0).?;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("Dracula", value);

    var buf: [max_rows]Row = undefined;
    for (self.buildSectionRows(.appearance, &buf)) |row| try testing.expect(row.action != .theme_half);
}

test "the accent chips write gx-accent-color and a color of its own is read-only" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    var app: App = undefined;
    var self = testSettings(&config, &app);
    defer testSettingsDeinit(&self);

    var buf: [max_rows]Row = undefined;
    var accent_row: ?Row = null;
    for (self.buildSectionRows(.appearance, &buf)) |row| if (row.action == .accent) {
        accent_row = row;
    };
    const row = accent_row.?;
    try testing.expectEqual(accents.len, row.choices.len);
    try testing.expectEqual(accents.len, row.dots.len);
    try testing.expectEqual(@as(?usize, 0), row.choice);
    self.setChoice(row, 1);
    try testing.expectEqual(@as(?settings_map.Accent, .theme), self.values.accent);
    const entry = self.changes.entries.items[0];
    try testing.expectEqualStrings(settings_map.Accent.key, entry.key);
    try testing.expectEqualStrings("theme", entry.values[0]);

    config.@"gx-accent-color" = .{ .color = .{ .r = 0xe5, .g = 0xa5, .b = 0x0a } };
    self.values = .fromConfig(&config, null);
    _ = self.scratch.reset(.retain_capacity);
    const rows = self.buildSectionRows(.appearance, &buf);
    for (rows, 0..) |custom, i| if (custom.action == .accent) {
        try testing.expectEqual(@as(usize, 1), custom.choices.len);
        try testing.expectEqual(@as(?usize, null), custom.choice);
        try testing.expectEqual(@as(u8, 1), custom.disabled);
        try testing.expect(std.mem.startsWith(u8, rows[i - 1].detail, "#e5a50a"));
    };
}

test {
    std.testing.refAllDecls(@This());
}
