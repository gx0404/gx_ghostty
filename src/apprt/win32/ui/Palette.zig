//! The command palette of a terminal surface: a `Popup` centered near the
//! top of its window, with a filter input (IME-capable) over a scrollable
//! list and a footer that describes the selected entry and the keys that
//! act on it. It has pages (`Page`):
//!
//!   - the root lists the recently used entries, the window's other tabs
//!     ("Switch to Tab: <title>"), the configured `command-palette-entry`
//!     commands with the keycaps of their bindings, the settings sections
//!     (`Settings.showSection`) and the UI language. "New Tab…" and "Change
//!     Theme…" open the next two pages; a filter also finds their entries;
//!   - "New Tab…" lists the launch profiles (like `gx:new_tab_profile`);
//!     Ctrl+Enter opens one in a new window;
//!   - "Change Theme…" lists the themes with their colors. While the
//!     selection rests on a theme the terminals preview it, and leaving the
//!     page or closing the palette without picking one restores the saved
//!     theme. The page opens on the current theme and previews nothing
//!     until the user moves the selection or types. Enter saves the theme
//!     to `gui-settings.ghostty` and closes the palette, Shift+Enter keeps
//!     it open;
//!   - the tab switcher (`toggle(.tabs)`, for `toggle_tab_overview` and
//!     `gx:tab_switcher`) lists the window's tabs, the most recently used
//!     first, with the previous one selected.
//!
//! Backspace in an empty filter goes back to the root. Entries match
//! (`gx.fuzzy`: words in any order, pinyin initials) in the UI language and
//! in English, also while an input method composes; when nothing matches,
//! the filter is tried again with two neighboring characters swapped. The
//! matched characters are highlighted, and an entry found by its English
//! title shows that title on a second line. Matches are grouped, the groups
//! ordered by their best match (`palette_model.sortMatches`).
//!
//! Picks are kept between runs (`gx.palette_history`, in the state file),
//! keyed by the English msgid, action or theme name: the recently used
//! entries come first in the root and rank higher in filtered results,
//! and the entry picked most after typing the same text comes first.
//! Shift+Delete forgets the selected entry, "Clear Recently Used" all.
//!
//! The owning `Window` embeds this struct as `palette` and calls
//! `setActive` (from `toggle_command_palette`), `reposition` (on resize),
//! `onDpiChanged`, `onLanguageChanged` and `deinit`. The app's message
//! loop gives `handleKey` the first look at key presses in the popup
//! (`ownsEdit`); chords bound to other actions then bubble up to the
//! surface, and editing chords stay with the filter (`text_edit`). The
//! palette also hosts the window's keyboard shortcut sheet (`keybinds`,
//! see `Keybinds.zig`), which shares its lifetime.
const Palette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../../input.zig");
const global = @import("../../../global.zig");
const Config = @import("../../../config.zig").Config;
const themepkg = @import("../../../config/theme.zig");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const fuzzy = gx.fuzzy;
const ui_color = gx.ui_color;
const App = @import("../App.zig");
const Pane = @import("../Pane.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Keybinds = @import("Keybinds.zig");
const Popup = @import("Popup.zig");
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const Settings = @import("Settings.zig");
const controls = @import("controls.zig");
const d2d = @import("d2d.zig");
const model = @import("palette_model.zig");
const style = @import("style.zig");
const trigger = @import("trigger.zig");

const log = std.log.scoped(.win32);
const Action = input.Binding.Action;
const History = gx.palette_history.History;
const floor = gx.ui_tokens.floor;

/// Layout in DIPs.
const layout = struct {
    const width_max: f32 = 640;
    const width_min: f32 = 360;
    /// Distance from the window edges and below the chrome.
    const margin: f32 = style.space.m;
    const top_gap: f32 = style.space.s;
    const pad: f32 = style.space.s;
    const input_height: f32 = 36;
    /// The top of the list, below the input and its separator.
    const list_top: f32 = pad + input_height + pad;
    const list_pad: f32 = style.space.xs;
    const list_height_max: f32 = 440;
    const empty_height: f32 = 76;
    const header_height: f32 = style.row.header;
    const item_height: f32 = style.row.list;
    const item_height_two_line: f32 = style.row.two_line;
    const footer_height: f32 = style.control.height;
    const icon_x: f32 = style.space.m;
    const text_x: f32 = icon_x + style.icon.standard + style.space.m;
    const gap: f32 = style.space.m;
    /// The widest share of a row the keycaps and details at its end take.
    const end_share: f32 = 0.45;
    /// The widest share of the footer its key hints take.
    const hints_share: f32 = 0.6;
    const swatch_width: f32 = 72;
    const swatch_height: f32 = 20;
    const wheel_step: f32 = 3 * item_height;
};

/// How many recently used entries an empty filter shows.
const max_recent = 5;

/// The score an entry that opens a page gets on top of its match, so that
/// "theme" finds "Change Theme…" before the themes, which also match it
/// (and start with it: "Theme: Nord").
const page_bonus: i32 = 30;

/// The timer on the popup window that waits for the selection to rest on a
/// theme before previewing it.
const preview_timer_id: usize = 1;

/// The timer on the app's message window (`App.msg_hwnd`) that reloads the
/// saved configuration after a palette went away while previewing a theme
/// (see `deinit`).
const restore_timer_id: usize = 0x5054; // 'PT'

const vk_lbutton: i32 = 0x01;

/// Segoe Fluent Icons / MDL2 Assets glyphs of the entry kinds.
const icons = struct {
    const command: u21 = 0xE945;
    const tab: u21 = 0xE7C4;
    const bell: u21 = 0xE7ED;
    const profile: u21 = 0xE756;
    const new_tab: u21 = d2d.icons.add;
    const settings: u21 = 0xE713;
    const language: u21 = 0xE774;
    const theme: u21 = 0xE790;
    const clear: u21 = 0xE894;
    const back: u21 = 0xE76B;
};

const Group = enum(u8) {
    recent,
    tabs,
    profiles,
    commands,
    settings,
    themes,

    fn title(self: Group) [:0]const u8 {
        return switch (self) {
            .recent => i18n.tr("Recently Used"),
            .tabs => i18n.tr("Tabs"),
            .profiles => i18n.tr("Launch Profiles"),
            .commands => i18n.tr("Commands"),
            .settings => i18n.tr("Settings"),
            .themes => i18n.tr("Themes"),
        };
    }
};

comptime {
    std.debug.assert(@typeInfo(Group).@"enum".fields.len <= model.max_groups);
}

/// What the palette lists.
pub const Page = enum {
    /// Commands, settings, tabs and the recently used entries.
    root,
    /// The launch profiles.
    new_tab,
    /// The themes, previewed while selected.
    themes,
    /// The window's tabs, most recently used first.
    tabs,

    /// The group a page other than the root lists.
    fn group(self: Page) ?Group {
        return switch (self) {
            .root => null,
            .new_tab => .profiles,
            .themes => .themes,
            .tabs => .tabs,
        };
    }

    fn title(self: Page) [:0]const u8 {
        return switch (self) {
            .root => "",
            .new_tab => i18n.tr("New Tab"),
            .themes => i18n.tr("Themes"),
            .tabs => i18n.tr("Tab Switcher"),
        };
    }

    fn placeholder(self: Page) [:0]const u8 {
        return switch (self) {
            .root => i18n.tr("Type a command…"),
            .new_tab => i18n.tr("Search launch profiles…"),
            .themes => i18n.tr("Search themes…"),
            .tabs => i18n.tr("Search tabs…"),
        };
    }
};

/// What an entry does when it runs.
const Target = union(enum) {
    command: Action,
    /// Stable local tab identity, not a pointer to its formerly active pane.
    tab: gx.ui_ref.Reference,
    /// A launch profile id.
    profile: [:0]const u8,
    settings: Settings.Section,
    language: i18n.Language,
    /// A theme name and its index in `theme_names`.
    theme: struct { name: []const u8, index: u32 },
    page: Page,
    clear_history,
};

const Item = struct {
    group: Group,
    icon: u21,
    /// The title in the UI language, and in English for matching.
    title: []const u8,
    title_en: []const u8,
    /// The title on the entry's own page, which leaves out the prefix of
    /// the root ("Theme: "): a name, also in English.
    name: []const u8,
    name_en: []const u8,
    /// What the footer says about the entry when it is selected.
    description: []const u8 = "",
    /// A short note at the end of the row: a launch profile's program, the
    /// current theme or tab.
    detail: []const u8 = "",
    /// The `gx.palette_history` key; empty for entries that are not
    /// remembered.
    key: []const u8 = "",
    shortcut: ?input.Binding.Trigger = null,
    /// The width of the shortcut's keycaps, once measured.
    shortcut_width: ?f32 = null,
    /// The current tab or theme.
    current: bool = false,
    /// A tab with output the user has not seen.
    unread: bool = false,
    /// How recently a tab was selected (`Window.tabRecency`), the current
    /// one highest.
    recency: u64 = 0,
    target: Target,

    /// The place among the recently used entries (`History.rank`) and the
    /// score bonus of the picks.
    rank: u64 = 0,
    bonus: i32 = 0,
    /// The score of the current filter, and whether the entry matched by
    /// its English title rather than the translated one.
    score: i32 = 0,
    english: bool = false,
};

const Row = struct {
    kind: union(enum) {
        header: Group,
        item: usize,
    },
    /// Position in the list content.
    y: f32 = 0,
    h: f32 = 0,
};

/// What the left button went down on.
const Pressed = union(enum) {
    row: usize,
    back,
};

const ItemCache = struct {
    arena: ?std.heap.ArenaAllocator = null,
    entries: []const Item = &.{},
    stamp: ?u64 = null,

    fn deinit(self: *ItemCache) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

popup: Popup = .{},
preparation: Popup.Preparation = .{},
uia_attachment: gx.ui_ref.Attachment = .{},

/// The keyboard shortcut sheet of the window (see `Keybinds.show`).
keybinds: Keybinds.Sheet = .{},

/// Whether the palette is shown, and the page it shows.
active: bool = false,
page: Page = .root,

/// Session rows borrow static entries from `item_cache`; tab and theme
/// entries live in the session arena.
arena: ?std.heap.ArenaAllocator = null,
items: std.ArrayList(Item) = .empty,
item_cache: ItemCache = .{},

/// Where the themes start in `items` (they come last), and whether all of
/// them are there: until a filter or the theme page needs them, only the
/// recently used ones are (`ensureThemes`).
themes_start: usize = 0,
themes_expanded: bool = false,
/// The theme directories of the session, highest priority first.
theme_dirs: []const []const u8 = &.{},
/// The colors of the theme rows by theme index, for the `theme_names`
/// list of generation `swatch_generation`.
swatches: gx.theme_swatch.Cache = .{},
swatch_generation: u64 = 0,

/// The rows on display for the current filter.
rows: std.ArrayList(Row) = .empty,
content_height: f32 = 0,
scroll: f32 = 0,
scrollbar: controls.ScrollIndicator = .{},
/// Row indices (item rows only).
selected: ?usize = null,
hover: ?usize = null,
pressed: ?Pressed = null,
/// The pointer over the popup (DIPs), to find the row under it again after
/// the list scrolled.
mouse: ?d2d.Point = null,
/// The back button of a page, where the last paint put it.
back_rect: ?d2d.Rect = null,
back_hover: bool = false,

/// The query the rows matched: the filter, or one with two characters
/// swapped when the filter matched nothing. The filter as typed is
/// `filter_buf[0..filter_len]`.
query: fuzzy.Query = .{},
filter_buf: [256]u8 = undefined,
filter_len: usize = 0,

/// The theme the terminals show as a preview while the selection rests on
/// it (`preview_buf[0..preview_len]`), or null.
preview_len: ?usize = null,
preview_buf: [256]u8 = undefined,
preview_gate: model.PreviewGate = .{},
/// The in-app notifications when the palette opened; previews keep them
/// without the "reloaded" notification.
notifications: Config.AppNotifications = .{},

pub fn ownerWindow(self: *Palette) *Window {
    return @alignCast(@fieldParentPtr("palette", self));
}
pub fn paneView(self: *Palette) Pane {
    return self.ownerWindow().activePane().?;
}

fn alloc(self: *Palette) Allocator {
    return self.ownerWindow().app.core_app.alloc;
}

/// Destroy the popups and free the entries. A theme preview still showing
/// (the terminal went away under the open palette) ends from the message
/// loop (`restoreSavedTheme`): the window is taking its tab apart now.
pub fn deinit(self: *Palette) void {
    self.keybinds.deinit();
    if (self.preview_len != null) restoreSavedTheme(self.ownerWindow().app);
    self.endPreview(false);
    releasePopup(&self.popup);
    self.rows.deinit(self.alloc());
    self.rows = .empty;
    self.swatches.deinit(self.alloc());
    self.item_cache.deinit();
    if (self.arena) |*arena| arena.deinit();
    self.arena = null;
    self.items = .empty;
    self.theme_dirs = &.{};
    self.active = false;
}

test "palette storage can be released rebuilt and released across reparenting" {
    const fixture_alloc = std.testing.allocator;
    var core: @import("../../../App.zig") = undefined;
    core.alloc = fixture_alloc;
    var app: App = undefined;
    app.core_app = &core;
    var fixture_window: Window = undefined;
    fixture_window.app = &app;
    fixture_window.palette = .{};
    try fixture_window.palette.rows.ensureTotalCapacity(fixture_alloc, 4);
    fixture_window.palette.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture_window.palette.rows.capacity);
    fixture_window.palette.deinit();
    try fixture_window.palette.rows.ensureTotalCapacity(fixture_alloc, 8);
    fixture_window.palette.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture_window.palette.rows.capacity);
}

/// Whether `hwnd` is the palette popup, whose filter input has the
/// keyboard focus while the palette is shown.
pub fn ownsEdit(self: *const Palette, hwnd: ?w32.HWND) bool {
    const popup = self.popup.hwnd orelse return false;
    return hwnd != null and hwnd.? == popup;
}

/// Show the command palette (on its root page) or hide it.
pub fn setActive(self: *Palette, active: bool) void {
    if (!active) {
        self.close(true);
        return;
    }
    self.open(.root);
}

/// Show the palette on `page`, or hide it when it shows that page already:
/// `toggle(.tabs)` is the tab switcher of `toggle_tab_overview` and
/// `gx:tab_switcher`.
pub fn toggle(self: *Palette, page: Page) void {
    if (self.active and self.page == page) {
        self.close(true);
        return;
    }
    self.open(page);
}

/// Show the palette on `page` (switching to it when the palette is shown).
pub fn open(self: *Palette, page: Page) void {
    var timing = Popup.OpenTiming.begin(.palette);
    if (self.ownerWindow().activePane() == null) return;
    if (self.active) {
        self.setPage(page);
        return;
    }
    const span: gx.perf.Span = .begin(global.io());
    const pane = self.paneView();
    pane.dismissSearch();
    self.uia_attachment = pane.attachment();
    const app = pane.app();
    if (timing) |*value| value.lap(.prepare);
    if (!self.prepareHost()) return;
    if (timing) |*value| value.lap(.create);

    self.active = true;
    self.page = page;
    self.notifications = app.config.@"app-notifications";
    self.popup.input.clear();
    self.mouse = null;
    self.buildItems();
    if (timing) |*value| value.lap(.prepare);
    self.refilter(.navigation);
    const rect = self.bounds() orelse return;
    if (timing) |*value| value.lap(.layout);
    self.popup.open_timing = timing;
    self.popup.show(rect);
    _ = span.end(global.io(), "palette_open");
}

fn prepareHost(self: *Palette) bool {
    const window = self.ownerWindow();
    const app = window.app;
    const owner = window.hwnd orelse return false;
    const t = self.tokens();
    if (!ensurePopup(&self.popup, app, owner, .{
        .activate = true,
        .text_input = true,
        .dismiss_on_escape = true,
        .dismiss_on_outside_click = true,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
        .keep_owner_active = true,
        .accessible_name = i18n.tr("Command Palette"),
        .reuse_host = true,
    }, .{
        .ctx = self,
        .paint = paint,
        .uia_source = .{ .app = app, .build = uiaBuild, .is_live = uiaLive, .action = uiaAction },
        .key = onKey,
        .mouse = onMouse,
        .text_changed = onTextChanged,
        .composition_changed = onCompositionChanged,
        .dismissed = onDismissed,
        .dpi_changed = onPopupDpiChanged,
    })) return false;
    self.popup.setOwnerScale(window.scale);
    return true;
}

/// Event-driven idle preparation of the hidden root. Dynamic tab rows are
/// still rebuilt at open, while the host/target and bounded text cache survive.
pub fn prepare(self: *Palette) void {
    if (self.active or self.ownerWindow().activePane() == null) return;
    if (!self.prepareHost()) return;
    self.page = .root;
    self.popup.input.clear();
    self.mouse = null;
    self.buildItems();
    self.refilter(.navigation);
    self.popup.prepareHidden(self.bounds() orelse return);
}

pub fn invalidateHost(self: *Palette) void {
    self.preparation.request();
    self.popup.reuse_invalid = true;
    self.item_cache.stamp = null;
}

/// Hide the palette, ending a theme preview; `restore_focus` gives the
/// keyboard back to the terminal.
fn close(self: *Palette, restore_focus: bool) void {
    const was_active = self.active;
    self.active = false;
    self.hover = null;
    self.pressed = null;
    self.mouse = null;
    self.scrollbar = .{};
    self.popup.hide();
    self.endPreview(true);
    if (was_active and restore_focus) self.focusSurface();
}

fn focusSurface(self: *Palette) void {
    if (self.ownerWindow().activePane()) |pane| pane.focus();
}

/// Move and size the palette for its window (after a resize).
pub fn reposition(self: *Palette) void {
    if (!self.active or !popupAlive(&self.popup)) return;
    self.popup.setOwnerScale(self.ownerWindow().scale);
    const rect = self.bounds() orelse return;
    self.popup.setBounds(rect);
}

/// The DPI of the surface changed: resize the palette.
pub fn onDpiChanged(self: *Palette) void {
    @import("Menu.zig").invalidateWindow(self.ownerWindow());
    self.reposition();
    self.keybinds.reposition();
}

/// The UI language changed: retranslate the entries.
pub fn onLanguageChanged(self: *Palette) void {
    @import("Menu.zig").invalidateWindow(self.ownerWindow());
    self.keybinds.onLanguageChanged();
    if (!self.active) return;
    self.buildItems();
    self.refilter(.navigation);
    self.reposition();
    self.popup.invalidate();
}

fn tokens(self: *Palette) style.Tokens {
    return style.Tokens.fromConfig(&self.ownerWindow().app.config);
}

/// The palette's place in screen pixels: centered below the window's
/// chrome, as tall as the rows need up to a limit, at the window's scale.
fn bounds(self: *Palette) ?w32.RECT {
    const window = self.ownerWindow();
    const hwnd = window.hwnd orelse return null;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return null;
    const scale = window.scale;
    const client_w = style.dip(client.right - client.left, scale);
    const client_h = style.dip(client.bottom - client.top, scale);
    const top = style.dip(window.chromeHeight(), scale) + layout.top_gap;

    const width = std.math.clamp(client_w - 2 * layout.margin, layout.width_min, layout.width_max);
    const room = client_h - top - layout.margin - layout.list_top - layout.footer_height;
    const list_max = @max(layout.empty_height, @min(layout.list_height_max, room));
    const list_h = std.math.clamp(self.content_height, layout.empty_height, list_max);

    var origin: w32.POINT = .{ .x = 0, .y = 0 };
    _ = w32.ClientToScreen(hwnd, &origin);
    const left = origin.x + style.px(@max(0, (client_w - width) / 2), scale);
    const y = origin.y + style.px(top, scale);
    return .{
        .left = left,
        .top = y,
        .right = left + style.px(width, scale),
        .bottom = y + style.px(layout.list_top + list_h + layout.footer_height, scale),
    };
}

// -----------------------------------------------------------------------
// Entries
// -----------------------------------------------------------------------

/// Collect the entries for a new session.
fn buildItems(self: *Palette) void {
    if (self.arena) |*arena| {
        _ = arena.reset(.retain_capacity);
    } else {
        self.arena = .init(self.alloc());
    }
    const a = self.arena.?.allocator();
    self.items = .empty;
    self.theme_dirs = &.{};
    loadHistory(self.alloc());

    self.refreshItemCache() catch |err| log.warn("palette entries unavailable err={}", .{err});
    self.addTabs(a) catch |err| log.warn("palette tabs unavailable err={}", .{err});
    self.items.appendSlice(a, self.item_cache.entries) catch |err| log.warn("palette entries unavailable err={}", .{err});
    self.themes_start = self.items.items.len;
    self.themes_expanded = false;
    if (!history.isEmpty()) self.addThemes(a, .recent) catch |err| log.warn("palette themes unavailable err={}", .{err});
    self.loadRanks(0);
}

fn itemStamp(self: *Palette) u64 {
    const app = self.ownerWindow().app;
    var hasher: std.hash.Wyhash = .init(configStamp(&app.config, self.hints()));
    std.hash.autoHash(&hasher, app.profiles_cache.detections);
    std.hash.autoHash(&hasher, app.profiles_cache.shells != null);
    std.hash.autoHash(&hasher, history.isEmpty());
    return hasher.final();
}

fn refreshItemCache(self: *Palette) !void {
    const stamp = self.itemStamp();
    if (self.item_cache.stamp == stamp) return;
    const span: gx.perf.Span = .begin(global.io());
    var fresh: ItemCache = .{ .arena = .init(self.alloc()) };
    errdefer fresh.deinit();
    const a = fresh.arena.?.allocator();
    const session_items = self.items;
    defer self.items = session_items;
    self.items = .empty;
    try self.addPages(a);
    try self.addCommands(a);
    try self.addSettings(a);
    try self.addProfiles(a);
    fresh.entries = self.items.items;
    fresh.stamp = self.itemStamp();
    self.item_cache.deinit();
    self.item_cache = fresh;
    _ = span.end(global.io(), "palette_entries_build");
}

fn configStamp(config: *const Config, hints_: trigger.Hints) u64 {
    var hasher: std.hash.Wyhash = .init(@intFromEnum(i18n.current()));
    for (config.@"command-palette-entry".value.items) |command| {
        hashText(&hasher, command.title);
        hashText(&hasher, command.description);
        std.hash.autoHash(&hasher, command.action.hash());
    }
    const profiles = &config.@"gx-launch-profile".map;
    for (profiles.keys(), profiles.values()) |name, command| {
        hashText(&hasher, name);
        hashText(&hasher, command);
    }
    hashText(&hasher, gx.settings_map.themeName(config.theme) orelse "");
    var bindings = hints_.set.bindings.iterator();
    while (bindings.next()) |entry| {
        std.hash.autoHash(&hasher, entry.key_ptr.hash());
        std.hash.autoHash(&hasher, std.meta.activeTag(entry.value_ptr.*));
        switch (entry.value_ptr.*) {
            .leaf => |leaf| {
                std.hash.autoHash(&hasher, leaf.action.hash());
                std.hash.autoHash(&hasher, leaf.flags);
            },
            .leader, .leaf_chained => {},
        }
    }
    var reverse = hints_.set.reverse.iterator();
    while (reverse.next()) |entry| {
        std.hash.autoHash(&hasher, entry.key_ptr.hash());
        std.hash.autoHash(&hasher, entry.value_ptr.hash());
    }
    if (hints_.blocked) |blocked| for (blocked.list.items) |conflict| {
        std.hash.autoHash(&hasher, conflict);
    };
    return hasher.final();
}

fn hashText(hasher: *std.hash.Wyhash, text: []const u8) void {
    std.hash.autoHash(hasher, text.len);
    hasher.update(text);
}

/// All the themes, for a filter or the theme page: the hundreds of them
/// take the place of the recently used ones `buildItems` added.
fn ensureThemes(self: *Palette) void {
    if (self.themes_expanded) return;
    self.themes_expanded = true;
    const a = self.arena.?.allocator();
    self.items.shrinkRetainingCapacity(self.themes_start);
    self.addThemes(a, .all) catch |err| log.warn("palette themes unavailable err={}", .{err});
    self.loadRanks(self.themes_start);
}

/// The places among the recently used entries and the score bonuses of the
/// entries from `start` (`gx.palette_history`).
fn loadRanks(self: *Palette, start: usize) void {
    const now = unixNow();
    for (self.items.items[start..]) |*item| {
        if (item.key.len == 0) continue;
        item.rank = history.rank(item.key);
        item.bonus = history.bonus(item.key, now);
    }
}

pub fn keybindSet(self: *Palette) *const input.Binding.Set {
    if (self.ownerWindow().activePane()) |pane| switch (pane.backend) {
        .remote => |remote| return &remote.ui.keybind_set.set,
        .local => {},
    };
    return &self.ownerWindow().app.config.keybind.set;
}

/// The shortcuts shown next to the items: none that another program or
/// the input method takes, and none without a key name.
fn hints(self: *Palette) trigger.Hints {
    return .{ .set = self.keybindSet(), .blocked = &self.ownerWindow().app.shortcut_conflicts };
}

fn addTabs(self: *Palette, a: Allocator) !void {
    const window = self.ownerWindow();
    for (0..window.tab_count) |i| {
        const title16 = window.tab_titles[i][0..window.tab_title_lens[i]];
        const name = std.unicode.utf16LeToUtf8Alloc(a, title16) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => "",
        };
        const label = if (name.len > 0) name else "Ghostty GX";
        const current = i == window.active_tab;
        const status = window.tabStatus(i);
        try self.items.append(a, .{
            .group = .tabs,
            .icon = if (status.bell) icons.bell else icons.tab,
            .title = try i18n.fill(a, i18n.tr("Switch to Tab: {title}"), .{ .title = label }),
            .title_en = try i18n.fill(a, "Switch to Tab: {title}", .{ .title = label }),
            .name = label,
            .name_en = label,
            .description = label,
            .detail = if (current) i18n.tr("Current Tab") else "",
            .shortcut = self.hints().lookup(.{ .goto_tab = i + 1 }),
            .current = current,
            .unread = status.unread,
            .recency = if (current) std.math.maxInt(u64) else window.tabRecency(i),
            .target = .{ .tab = window.tab_references[i] },
        });
    }
}

/// The entries that open the launch profile and theme pages.
fn addPages(self: *Palette, a: Allocator) !void {
    const app = self.ownerWindow().app;
    const new_tab = i18n.tr("New Tab…");
    try self.items.append(a, .{
        .group = .commands,
        .icon = icons.new_tab,
        .title = new_tab,
        .title_en = "New Tab…",
        .name = new_tab,
        .name_en = "New Tab…",
        .key = "page:new_tab",
        .target = .{ .page = .new_tab },
    });
    const theme = i18n.tr("Change Theme…");
    try self.items.append(a, .{
        .group = .commands,
        .icon = icons.theme,
        .title = theme,
        .title_en = "Change Theme…",
        .name = theme,
        .name_en = "Change Theme…",
        .detail = if (gx.settings_map.themeName(app.config.theme)) |current| try a.dupe(u8, current) else "",
        .key = "page:themes",
        .target = .{ .page = .themes },
    });
}

fn addCommands(self: *Palette, a: Allocator) !void {
    const app = self.ownerWindow().app;
    for (app.config.@"command-palette-entry".value.items) |command| {
        if (!supported(command.action)) continue;
        // Copied: a configuration reload frees the originals.
        const action = try command.action.clone(a);
        const title = try a.dupe(u8, i18n.trRuntime(command.title));
        const title_en = try a.dupe(u8, command.title);
        try self.items.append(a, .{
            .group = .commands,
            .icon = icons.command,
            .title = title,
            .title_en = title_en,
            .name = title,
            .name_en = title_en,
            .description = if (command.description.len > 0)
                try a.dupe(u8, i18n.trRuntime(command.description))
            else
                "",
            .key = try std.fmt.allocPrint(a, "{f}", .{action}),
            .shortcut = self.hints().lookup(action),
            .target = .{ .command = action },
        });
    }
}

/// Whether running `action` from the palette does something on Windows.
fn supported(action: Action) bool {
    return switch (action) {
        .toggle_command_palette,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .check_for_updates,
        .toggle_secure_input,
        .inspector,
        .undo,
        .redo,
        => false,
        else => true,
    };
}

/// Whether `action` opens the tab switcher, which the palette shows
/// itself.
fn opensTabSwitcher(action: Action) bool {
    return switch (action) {
        .toggle_tab_overview => true,
        .gx => |gx_action| gx_action == .tab_switcher,
        else => false,
    };
}

fn addSettings(self: *Palette, a: Allocator) !void {
    const sections = [_]struct { [:0]const u8, Settings.Section }{
        .{ "Language", .language },
        .{ "Appearance", .appearance },
        .{ "Font", .font },
        .{ "Interaction", .interaction },
        .{ "Shell", .shell },
        .{ "About", .about },
    };
    inline for (sections) |entry| {
        const section = entry[0];
        const title = try i18n.fill(a, i18n.tr("Settings: {section}"), .{ .section = i18n.tr(section) });
        const title_en = try i18n.fill(a, "Settings: {section}", .{ .section = section });
        try self.items.append(a, .{
            .group = .settings,
            .icon = icons.settings,
            .title = title,
            .title_en = title_en,
            .name = title,
            .name_en = title_en,
            .key = "settings:" ++ section,
            .target = .{ .settings = entry[1] },
        });
    }

    const current = i18n.current();
    const next: i18n.Language = switch (current) {
        .zh_CN => .en,
        .en => .zh_CN,
    };
    const title = try i18n.fill(a, i18n.tr("Switch Language to {language}"), .{ .language = next.nativeName() });
    const title_en = try i18n.fill(a, "Switch Language to {language}", .{ .language = next.nativeName() });
    try self.items.append(a, .{
        .group = .settings,
        .icon = icons.language,
        .title = title,
        .title_en = title_en,
        .name = title,
        .name_en = title_en,
        .description = try i18n.fill(a, i18n.tr("Current language: {language}"), .{ .language = current.nativeName() }),
        .key = "language",
        .target = .{ .language = next },
    });

    if (!history.isEmpty()) {
        const clear = i18n.tr("Clear Recently Used");
        try self.items.append(a, .{
            .group = .settings,
            .icon = icons.clear,
            .title = clear,
            .title_en = "Clear Recently Used",
            .name = clear,
            .name_en = "Clear Recently Used",
            .description = i18n.tr("Forget the entries the command palette remembers."),
            .target = .clear_history,
        });
    }
}

fn addProfiles(self: *Palette, a: Allocator) !void {
    var list = try self.ownerWindow().app.cachedLaunchProfiles();
    defer list.deinit();
    for (list.profiles) |profile| {
        const id = try a.dupeZ(u8, profile.id);
        const name = try gx.profiles.displayName(a, profile);
        const name_en = if (profile.kind == .custom)
            name
        else
            try i18n.fill(a, profile.name, .{ .name = profile.name_arg orelse "" });
        var detail_buf: [256]u8 = undefined;
        const detail = switch (profile.command) {
            .argv => |argv| model.commandLabel(&detail_buf, argv),
            .command_line => |line| model.lineLabel(&detail_buf, line),
        };
        try self.items.append(a, .{
            .group = .profiles,
            .icon = icons.profile,
            .title = try i18n.fill(a, i18n.tr("New Tab: {name}"), .{ .name = name }),
            .title_en = try i18n.fill(a, "New Tab: {name}", .{ .name = name_en }),
            .name = name,
            .name_en = name_en,
            .description = try commandText(a, profile.command),
            .detail = try a.dupe(u8, detail),
            .key = try std.fmt.allocPrint(a, "gx:new_tab_profile:{s}", .{id}),
            .shortcut = self.hints().lookup(.{ .gx = .{ .new_tab_profile = id } }),
            .target = .{ .profile = id },
        });
    }
}

fn commandText(a: Allocator, command: gx.profiles.Command) ![]const u8 {
    return switch (command) {
        .command_line => |line| try a.dupe(u8, line),
        .argv => |argv| argv: {
            var out: std.ArrayList(u8) = .empty;
            for (argv, 0..) |arg, i| {
                if (i > 0) try out.append(a, ' ');
                try out.appendSlice(a, arg);
            }
            break :argv out.items;
        },
    };
}

/// The themes: `all` of them, or only the `recent`ly used ones.
fn addThemes(self: *Palette, a: Allocator, which: enum { recent, all }) !void {
    const app = self.ownerWindow().app;
    if (self.theme_dirs.len == 0) {
        var dirs: std.ArrayList([]const u8) = .empty;
        var it: themepkg.LocationIterator = .{ .arena_alloc = a };
        while (it.next() catch null) |location| try dirs.append(a, location.dir);
        self.theme_dirs = dirs.items;
    }

    const names = theme_names.get(global.io(), self.theme_dirs);
    if (theme_names.generation != self.swatch_generation) {
        self.swatches.deinit(self.alloc());
        self.swatch_generation = theme_names.generation;
    }
    const current = gx.settings_map.themeName(app.config.theme);
    var key_buf: [320]u8 = undefined;
    for (names, 0..) |theme, i| {
        if (which == .recent) {
            const key = std.fmt.bufPrint(&key_buf, "theme:{s}", .{theme}) catch continue;
            if (history.rank(key) == 0) continue;
        }
        const name = try a.dupe(u8, theme);
        const is_current = if (current) |c| std.mem.eql(u8, c, name) else false;
        try self.items.append(a, .{
            .group = .themes,
            .icon = icons.theme,
            .title = try i18n.fill(a, i18n.tr("Theme: {name}"), .{ .name = name }),
            .title_en = try i18n.fill(a, "Theme: {name}", .{ .name = name }),
            .name = name,
            .name_en = name,
            .detail = if (is_current) i18n.tr("Current Theme") else "",
            .key = try std.fmt.allocPrint(a, "theme:{s}", .{name}),
            .current = is_current,
            .target = .{ .theme = .{ .name = name, .index = @intCast(i) } },
        });
    }
}

// -----------------------------------------------------------------------
// Filtering
// -----------------------------------------------------------------------

/// Rebuild the rows for the filter text and select the page's first
/// entry; `cause` sets how long a theme preview waits.
fn refilter(self: *Palette, cause: model.PreviewCause) void {
    const span: gx.perf.Span = .begin(global.io());
    const gpa = self.alloc();
    self.rows.clearRetainingCapacity();
    self.pressed = null;
    for (self.items.items) |*item| item.english = false;

    const text = self.readFilter();
    self.query = .init(text);
    if (self.page == .themes or (self.page == .root and !self.query.isEmpty())) self.ensureThemes();
    const result = if (self.query.isEmpty()) self.listAll(gpa) else self.listMatches(gpa, text);
    result catch |err| log.warn("palette filter failed err={}", .{err});

    var y: f32 = layout.list_pad;
    for (self.rows.items) |*row| {
        row.y = y;
        row.h = switch (row.kind) {
            .header => layout.header_height,
            .item => |i| if (self.items.items[i].english) layout.item_height_two_line else layout.item_height,
        };
        y += row.h;
    }
    self.content_height = if (self.rows.items.len == 0) 0 else y + layout.list_pad;
    self.scroll = 0;
    self.selected = self.initialRow();
    if (self.selected) |row| {
        if (self.page == .themes and self.query.isEmpty()) self.center(row) else self.reveal(row);
    }
    self.updateHover();
    self.preview_gate.filtered(self.query.isEmpty());
    self.schedulePreview(cause);
    _ = span.end(global.io(), "palette_filter");
}

/// The filter text, with an IME composition in progress, kept in
/// `filter_buf`.
fn readFilter(self: *Palette) []const u8 {
    const in = &self.popup.input;
    const text = model.compositionQuery(&self.filter_buf, in.buf.items, in.caret, in.composition.items);
    self.filter_len = text.len;
    return text;
}

fn filterText(self: *const Palette) []const u8 {
    return self.filter_buf[0..self.filter_len];
}

/// The entries of the page without a filter. The root lists the recently
/// used entries, the other tabs, the commands and the settings.
fn listAll(self: *Palette, gpa: Allocator) !void {
    switch (self.page) {
        .root => try self.listRoot(gpa),
        .tabs => {
            var tabs: std.ArrayList(usize) = .empty;
            defer tabs.deinit(gpa);
            var recency: std.ArrayList(u64) = .empty;
            defer recency.deinit(gpa);
            for (self.items.items, 0..) |item, i| {
                if (item.group != .tabs) continue;
                try tabs.append(gpa, i);
                try recency.append(gpa, item.recency);
            }
            const order = try gpa.alloc(usize, tabs.items.len);
            defer gpa.free(order);
            model.mruOrder(recency.items, order);
            for (order) |k| try self.rows.append(gpa, .{ .kind = .{ .item = tabs.items[k] } });
        },
        .new_tab, .themes => {
            const group = self.page.group().?;
            for (self.items.items, 0..) |item, i| {
                if (item.group == group) try self.rows.append(gpa, .{ .kind = .{ .item = i } });
            }
        },
    }
}

fn listRoot(self: *Palette, gpa: Allocator) !void {
    const ranks = try gpa.alloc(u64, self.items.items.len);
    defer gpa.free(ranks);
    for (self.items.items, ranks) |item, *rank| {
        rank.* = if (item.current or item.group == .tabs) 0 else item.rank;
    }
    var top: [max_recent]usize = undefined;
    const recent = model.recentTop(ranks, &top);
    if (recent.len > 0) {
        try self.rows.append(gpa, .{ .kind = .{ .header = .recent } });
        for (recent) |i| try self.rows.append(gpa, .{ .kind = .{ .item = i } });
    }

    for ([_]Group{ .tabs, .commands, .settings }) |group| {
        var header = false;
        for (self.items.items, 0..) |item, i| {
            if (item.group != group) continue;
            if (std.mem.indexOfScalar(usize, recent, i) != null) continue;
            if (group == .tabs and item.current) continue;
            if (!header) {
                try self.rows.append(gpa, .{ .kind = .{ .header = group } });
                header = true;
            }
            try self.rows.append(gpa, .{ .kind = .{ .item = i } });
        }
    }
}

/// The entries matching the filter `text`: grouped in the root, the groups
/// and entries in the order of `model.sortMatches`. When nothing matches,
/// the variant of the filter with two characters swapped that matches best
/// takes its place (`query`).
fn listMatches(self: *Palette, gpa: Allocator, text: []const u8) !void {
    var matches: std.ArrayList(model.Match) = .empty;
    defer matches.deinit(gpa);
    try self.collectMatches(gpa, &self.query, &matches);

    if (matches.items.len == 0) {
        var variants: model.Transpositions = .init(text);
        var best: ?struct { query: fuzzy.Query, top: i32 } = null;
        while (variants.next()) |variant| {
            const q: fuzzy.Query = .init(variant);
            matches.clearRetainingCapacity();
            try self.collectMatches(gpa, &q, &matches);
            const top = topScore(matches.items) orelse continue;
            if (best == null or top > best.?.top) best = .{ .query = q, .top = top };
        }
        matches.clearRetainingCapacity();
        if (best) |b| {
            self.query = b.query;
            try self.collectMatches(gpa, &self.query, &matches);
        }
    }

    self.promoteInputMatch(text, matches.items);
    model.sortMatches(matches.items);

    const headers = self.page == .root;
    var group: ?u8 = null;
    for (matches.items) |m| {
        if (headers and group != m.group) {
            try self.rows.append(gpa, .{ .kind = .{ .header = @enumFromInt(m.group) } });
            group = m.group;
        }
        try self.rows.append(gpa, .{ .kind = .{ .item = m.index } });
    }
}

/// Score the entries of the page against `query` (the title and the
/// English one; on a page of its own, the name), keeping the score and
/// whether English matched better in each entry.
fn collectMatches(self: *Palette, gpa: Allocator, query: *const fuzzy.Query, out: *std.ArrayList(model.Match)) !void {
    const only = self.page.group();
    var buf: fuzzy.Buffer = undefined;
    for (self.items.items, 0..) |*item, i| {
        if (only) |g| if (item.group != g) continue;
        const text = if (only != null) item.name else item.title;
        const text_en = if (only != null) item.name_en else item.title_en;
        const p = buf.prepare(text);
        const len: u32 = @intCast(p.cps.len);
        const translated = fuzzy.scorePrepared(query, &p);
        var english: ?i32 = null;
        var len_en: u32 = len;
        if (!std.mem.eql(u8, text, text_en)) {
            const pe = buf.prepare(text_en);
            len_en = @intCast(pe.cps.len);
            english = fuzzy.scorePrepared(query, &pe);
        }
        const by_english = english != null and (translated == null or english.? > translated.?);
        const score = (if (by_english) english else translated) orelse continue;
        item.english = by_english;
        item.score = score + item.bonus + if (item.target == .page) page_bonus else 0;
        try out.append(gpa, .{
            .index = @intCast(i),
            .order = if (self.page == .tabs) std.math.maxInt(u64) - item.recency else i,
            .group = @intFromEnum(item.group),
            .score = item.score,
            .len = if (by_english) len_en else len,
        });
    }
}

fn topScore(matches: []const model.Match) ?i32 {
    var top: ?i32 = null;
    for (matches) |m| top = if (top) |t| @max(t, m.score) else m.score;
    return top;
}

/// The entry picked most often after typing `text` (`History.inputMatch`)
/// comes first.
fn promoteInputMatch(self: *Palette, text: []const u8, matches: []model.Match) void {
    const hash = history.inputMatch(text) orelse return;
    const top = topScore(matches) orelse return;
    for (matches) |*m| {
        const item = &self.items.items[m.index];
        if (item.key.len == 0 or gx.palette_history.keyHash(item.key) != hash) continue;
        m.score = top + 1;
        item.score = m.score;
        return;
    }
}

// -----------------------------------------------------------------------
// Selection and scrolling
// -----------------------------------------------------------------------

fn isItemRow(self: *const Palette, row: usize) bool {
    return row < self.rows.items.len and self.rows.items[row].kind == .item;
}

/// The first item row from `start` in direction `dir` (+1/-1), if any.
fn nextItemRow(self: *const Palette, start: usize, dir: i32) ?usize {
    var i: isize = @intCast(start);
    const len: isize = @intCast(self.rows.items.len);
    while (i >= 0 and i < len) : (i += dir) {
        if (self.isItemRow(@intCast(i))) return @intCast(i);
    }
    return null;
}

fn lastItemRow(self: *const Palette) ?usize {
    if (self.rows.items.len == 0) return null;
    return self.nextItemRow(self.rows.items.len - 1, -1);
}

/// The row a new filter selects: the first entry; without a filter the
/// current theme on the theme page, and the previous tab in the tab
/// switcher.
fn initialRow(self: *const Palette) ?usize {
    const first = self.nextItemRow(0, 1) orelse return null;
    if (!self.query.isEmpty()) return first;
    switch (self.page) {
        .themes => for (self.rows.items, 0..) |row, i| switch (row.kind) {
            .item => |index| if (self.items.items[index].current) return i,
            .header => {},
        },
        .tabs => return self.nextItemRow(first + 1, 1) orelse first,
        .root, .new_tab => {},
    }
    return first;
}

fn selectedItem(self: *const Palette) ?*Item {
    const row = self.selected orelse return null;
    if (!self.isItemRow(row)) return null;
    return &self.items.items[self.rows.items[row].kind.item];
}

/// The list below the filter and above the footer, in DIPs.
fn listView(self: *const Palette) d2d.Rect {
    const size = self.popup.sizeDip();
    return .{
        .x = 0,
        .y = layout.list_top,
        .w = size.width,
        .h = @max(0, size.height - layout.list_top - layout.footer_height),
    };
}

/// The height of the list once the popup has the size of its rows
/// (`bounds`), which it gets after a new filter.
fn viewHeight(self: *Palette) f32 {
    const rect = self.bounds() orelse return self.listView().h;
    const height = style.dip(rect.bottom - rect.top, self.ownerWindow().scale);
    return @max(0, height - layout.list_top - layout.footer_height);
}

fn maxScroll(self: *Palette) f32 {
    return @max(0, self.content_height - self.viewHeight());
}

fn scrollTo(self: *Palette, value: f32) void {
    self.scroll = std.math.clamp(value, 0, self.maxScroll());
}

/// Scroll so `row` (and the header right above it) is visible.
fn reveal(self: *Palette, row: usize) void {
    const r = self.rows.items[row];
    var top = r.y;
    if (row > 0 and self.rows.items[row - 1].kind == .header) top = self.rows.items[row - 1].y;
    if (row == self.nextItemRow(0, 1)) top = 0;
    const view = self.viewHeight();
    if (top < self.scroll) {
        self.scrollTo(top);
    } else if (r.y + r.h + layout.list_pad > self.scroll + view) {
        self.scrollTo(r.y + r.h + layout.list_pad - view);
    }
}

/// Scroll `row` to the middle of the list.
fn center(self: *Palette, row: usize) void {
    const r = self.rows.items[row];
    self.scrollTo(r.y + r.h / 2 - self.viewHeight() / 2);
}

/// The row under the pointer, after the pointer or the list moved.
fn updateHover(self: *Palette) void {
    self.hover = if (self.mouse) |pos| self.rowAt(pos) else null;
}

fn select(self: *Palette, row: ?usize) void {
    const r = row orelse return;
    self.selected = r;
    self.reveal(r);
    self.updateHover();
    self.popup.invalidate();
    self.preview_gate.navigated();
    self.schedulePreview(.navigation);
}

/// Move the selection by `delta` entries, wrapping around at the ends.
fn move(self: *Palette, delta: i32) void {
    const current = self.selected orelse return self.select(self.nextItemRow(0, 1));
    const next = if (delta > 0)
        (if (current + 1 < self.rows.items.len) self.nextItemRow(current + 1, 1) else null) orelse self.nextItemRow(0, 1)
    else
        (if (current > 0) self.nextItemRow(current - 1, -1) else null) orelse self.lastItemRow();
    self.select(next);
}

/// Move the selection by about one view height.
fn pageBy(self: *Palette, dir: i32) void {
    const current = self.selected orelse return;
    const target_y = self.rows.items[current].y + @as(f32, @floatFromInt(dir)) * (self.viewHeight() - layout.item_height);
    var best = current;
    for (self.rows.items, 0..) |row, i| {
        if (row.kind != .item) continue;
        if (dir > 0 and row.y <= target_y) best = i;
        if (dir < 0 and row.y >= target_y and i < best) {
            best = i;
            break;
        }
    }
    if (dir < 0 and best == current) best = self.nextItemRow(0, 1) orelse current;
    self.select(best);
}

/// The item row at `pos` (DIPs in the popup), if any; not over the scroll
/// indicator of a list that scrolls.
fn rowAt(self: *const Palette, pos: d2d.Point) ?usize {
    const view = self.listView();
    if (!view.contains(pos)) return null;
    if (self.content_height > view.h and controls.ScrollIndicator.track(view).contains(pos)) return null;
    const y = pos.y - view.y + self.scroll;
    for (self.rows.items, 0..) |row, i| {
        if (y >= row.y and y < row.y + row.h) return if (row.kind == .item) i else null;
    }
    return null;
}

/// Show `next` instead of the current page, with an empty filter. Leaving
/// the theme page ends its preview.
fn setPage(self: *Palette, next: Page) void {
    if (self.page == .themes and next != .themes) self.endPreview(true);
    self.page = next;
    self.popup.input.clear();
    self.scrollbar.release();
    self.refilter(.navigation);
    self.reposition();
    self.updateHover();
    self.popup.invalidate();
}

// -----------------------------------------------------------------------
// Running entries
// -----------------------------------------------------------------------

fn runSelected(self: *Palette, how: model.EnterAction) void {
    const row = self.selected orelse return;
    if (!self.isItemRow(row)) return;
    self.run(self.rows.items[row].kind.item, how);
}

/// Run entry `index`: open its page, or close the palette and perform it.
/// `how` is `.new_window` to open a launch profile in a new window and
/// `.keep_open` to apply a theme with the palette open.
fn run(self: *Palette, index: usize, how: model.EnterAction) void {
    const item = self.items.items[index];
    switch (item.target) {
        .page => |next| {
            self.remember(item);
            self.setPage(next);
            return;
        },
        .command => |action| if (opensTabSwitcher(action)) {
            self.remember(item);
            self.setPage(.tabs);
            return;
        },
        .theme => |theme| if (how == .keep_open) {
            self.remember(item);
            self.applyKeepOpen(theme.name);
            return;
        },
        .clear_history => {
            const pane = self.paneView();
            const app = pane.app();
            const owner = pane.ownerWindow().ui_reference;
            self.close(true);
            history.clear();
            commitHistory(app.core_app.alloc);
            if (app.resolveWindow(owner)) |window| window.showToast(.{ .text = i18n.tr("Cleared the recently used entries."), .icon = d2d.icons.completed });
            return;
        },
        else => {},
    }

    self.remember(item);
    const pane = self.paneView();
    const reference = pane.reference();
    const owner = pane.ownerWindow().ui_reference;
    const app = pane.app();
    var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena.deinit();
    const target = cloneTarget(item.target, arena.allocator()) catch return;
    // Saving a theme reloads the configuration anyway.
    if (item.target == .theme) self.endPreview(false);
    self.close(true);

    switch (target) {
        .command => |action| {
            const live = Pane.resolve(app, reference) orelse return;
            _ = live.performBindingAction(action) catch |err| {
                log.err("palette action failed action={t} err={}", .{ action, err });
            };
        },
        .tab => |tab| {
            const window = app.resolveWindow(owner) orelse return;
            if (window.resolveTab(tab)) |i| {
                window.selectTabIndex(i);
                window.invalidateTabBar();
            }
        },
        .profile => |id| if (app.resolveWindow(owner)) |window| {
            _ = app.openProfile(window, id, if (how == .new_window) .window else .tab);
        },
        .settings => |section| if (app.resolveWindow(owner)) |window| {
            _ = Settings.showSection(window, section);
        },
        .language => |language| if (app.resolveWindow(owner)) |window| {
            _ = saveSetting(window, "language", language.configValue());
        },
        .theme => |theme| if (app.resolveWindow(owner)) |window| {
            _ = saveSetting(window, "theme", theme.name);
        },
        .page, .clear_history => {},
    }
}
fn cloneTarget(target: Target, allocator: Allocator) !Target {
    return switch (target) {
        .command => |action| .{ .command = try action.clone(allocator) },
        .profile => |id| .{ .profile = try allocator.dupeZ(u8, id) },
        .theme => |theme| .{ .theme = .{ .name = try allocator.dupe(u8, theme.name), .index = theme.index } },
        else => target,
    };
}

/// Save theme `name` as the theme and keep the palette open on it. Saving
/// reloads the configuration; the session's entries then show its theme
/// as a palette opened afresh does (`followTheme`).
fn applyKeepOpen(self: *Palette, name: []const u8) void {
    const window = self.ownerWindow();
    self.endPreview(false);
    if (!saveSetting(window, "theme", name)) return;
    const current = gx.settings_map.themeName(window.app.config.theme);
    if (self.arena) |*arena| followTheme(self.items.items, current, arena.allocator()) catch |err| {
        log.warn("palette theme entries not refreshed err={}", .{err});
    };
    if (!self.active) return;
    self.popup.applyTheme(self.tokens());
    self.popup.invalidate();
}

/// Show `current` (the configuration's theme, null for none or a light and
/// dark pair) as the current theme in the session's `items`, as `addPages`
/// and `addThemes` do for a new session: its row is marked, and "Change
/// Theme…" names it on the root. `a` owns the new detail.
fn followTheme(items: []Item, current: ?[]const u8, a: Allocator) !void {
    const detail: []const u8 = if (current) |name| try a.dupe(u8, name) else "";
    for (items) |*item| switch (item.target) {
        .theme => |theme| {
            item.current = if (current) |name| std.mem.eql(u8, name, theme.name) else false;
            item.detail = if (item.current) i18n.tr("Current Theme") else "";
        },
        .page => |page| if (page == .themes) {
            item.detail = detail;
        },
        else => {},
    };
}

test "D13: a theme saved with the palette open shows on the root like a new session" {
    const testing = std.testing;
    const T = struct {
        fn theme(name: []const u8, index: u32, rank: u64, current: bool) Item {
            return .{
                .group = .themes,
                .icon = 0,
                .title = name,
                .title_en = name,
                .name = name,
                .name_en = name,
                .detail = if (current) i18n.tr("Current Theme") else "",
                .current = current,
                .rank = rank,
                .target = .{ .theme = .{ .name = name, .index = index } },
            };
        }
        fn page(detail: []const u8) Item {
            return .{ .group = .commands, .icon = 0, .title = "Change Theme…", .title_en = "Change Theme…", .name = "Change Theme…", .name_en = "Change Theme…", .detail = detail, .key = "page:themes", .rank = 2, .target = .{ .page = .themes } };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The session opened on Nord; Shift+Enter saved Nord Light, which the
    // picks now rank first (`remember`).
    var session = [_]Item{ T.page("Nord"), T.theme("Nord", 0, 0, true), T.theme("Nord Light", 1, 3, false), T.theme("Dracula", 2, 1, false) };
    try followTheme(&session, "Nord Light", arena.allocator());
    try testing.expectEqualStrings("Nord Light", session[0].detail);
    try testing.expect(!session[1].current and session[2].current and !session[3].current);
    try testing.expectEqualStrings("", session[1].detail);
    try testing.expectEqualStrings(i18n.tr("Current Theme"), session[2].detail);

    // Back on the root it lists what a palette opened on Nord Light lists:
    // "Change Theme…" naming it and the other recent picks, the current
    // theme left out like the current tab.
    var fresh = [_]Item{ T.page("Nord Light"), T.theme("Nord", 0, 0, false), T.theme("Nord Light", 1, 3, true), T.theme("Dracula", 2, 1, false) };
    var after: Palette = .{ .items = .{ .items = &session, .capacity = session.len } };
    defer after.rows.deinit(testing.allocator);
    try after.listRoot(testing.allocator);
    var reopened: Palette = .{ .items = .{ .items = &fresh, .capacity = fresh.len } };
    defer reopened.rows.deinit(testing.allocator);
    try reopened.listRoot(testing.allocator);
    try testing.expectEqual(reopened.rows.items.len, after.rows.items.len);
    for (after.rows.items, reopened.rows.items) |row, expected| switch (expected.kind) {
        .header => |group| try testing.expectEqual(group, row.kind.header),
        .item => |i| {
            const item = after.items.items[row.kind.item];
            try testing.expectEqualStrings(fresh[i].title, item.title);
            try testing.expectEqualStrings(fresh[i].detail, item.detail);
        },
    };
    try testing.expectEqual(Group.recent, after.rows.items[0].kind.header);
    try testing.expectEqual(@as(usize, 0), after.rows.items[1].kind.item);
    try testing.expectEqual(@as(usize, 3), after.rows.items[2].kind.item);
}

test "D13: a reused palette host rebuilds its entries for a changed theme" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    const hints_: trigger.Hints = .{ .set = &config.keybind.set };
    config.theme = .{ .light = "Nord", .dark = "Nord" };
    const nord = configStamp(&config, hints_);
    // The cached static entries ("Change Theme…" and the theme it names)
    // belong to one theme: the next opening of a hidden host rebuilds them.
    config.theme = .{ .light = "Nord Light", .dark = "Nord Light" };
    try testing.expect(configStamp(&config, hints_) != nord);
    // A configuration change also retires the hidden host and its cache.
    var palette: Palette = .{};
    palette.item_cache.stamp = nord;
    palette.preparation.pending = false;
    palette.invalidateHost();
    try testing.expect(palette.item_cache.stamp == null);
    try testing.expect(palette.popup.reuse_invalid and palette.preparation.pending);
}

/// Remember a pick of `item` and what was typed before it.
fn remember(self: *Palette, item: Item) void {
    if (item.key.len == 0) return;
    history.record(item.key, unixNow());
    const typed = self.filterText();
    if (typed.len > 0) history.recordInput(typed, item.key);
    commitHistory(self.alloc());
    self.loadRanks(0);
}

/// Shift+Delete: forget the selected entry when it is remembered. Returns
/// whether it was.
fn forgetSelected(self: *Palette) bool {
    const row = self.selected orelse return false;
    const item = self.selectedItem() orelse return false;
    if (item.key.len == 0 or item.rank == 0) return false;
    history.remove(item.key);
    commitHistory(self.alloc());
    item.rank = 0;
    item.bonus = 0;
    const scroll = self.scroll;
    self.refilter(.navigation);
    // Keep the selection where it was, on the entry now there.
    self.selected = self.nextItemRow(@min(row, self.rows.items.len -| 1), 1) orelse self.lastItemRow();
    self.scrollTo(scroll);
    if (self.selected) |r| self.reveal(r);
    self.updateHover();
    self.reposition();
    self.popup.invalidate();
    return true;
}

/// Write `key = value` to `gui-settings.ghostty` and reload the
/// configuration, like the settings UI does. Returns whether it was saved;
/// a toast tells why not.
fn saveSetting(window: *Window, key: []const u8, value: []const u8) bool {
    const alloc_ = window.app.core_app.alloc;
    const path = gx.config_layers.overlayPath(alloc_) catch |err| {
        log.err("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
        showSaveError(window, err);
        return false;
    };
    defer alloc_.free(path);
    var changes: gx.settings_map.Changes = .init(alloc_);
    defer changes.deinit();
    changes.set(key, value) catch |err| {
        showSaveError(window, err);
        return false;
    };
    changes.commit(alloc_, global.io(), path) catch |err| {
        log.err("cannot save {s} err={}", .{ path, err });
        showSaveError(window, err);
        return false;
    };
    if (gx.perf.enabled() and std.mem.eql(u8, key, "theme")) gx.perf.count("theme.reload", 1);
    window.performBindingAction(.reload_config);
    return true;
}

fn showSaveError(window: *Window, err: anyerror) void {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    i18n.format(&writer, i18n.tr("Could not save the settings: {reason}"), .{
        .reason = i18n.trRuntime(gx.settings_map.errorReason(err)),
    }) catch {};
    window.showToast(.{ .text = writer.buffered(), .icon = d2d.icons.warning });
}

// -----------------------------------------------------------------------
// Theme preview
// -----------------------------------------------------------------------

/// The selected theme, including a root-page search result. PreviewGate keeps
/// merely opening an empty palette from previewing a recently used theme.
fn selectedTheme(self: *Palette) ?[]const u8 {
    const item = self.selectedItem() orelse return null;
    return switch (item.target) {
        .theme => |theme| if (item.current) null else theme.name,
        else => null,
    };
}

test "root theme search previews the selection but empty opening does not" {
    var items = [_]Item{.{ .group = .themes, .icon = 0, .title = "Nord", .title_en = "Nord", .name = "Nord", .name_en = "Nord", .target = .{ .theme = .{ .name = "Nord", .index = 0 } } }};
    var rows = [_]Row{.{ .kind = .{ .item = 0 }, .y = 0, .h = 20 }};
    var palette: Palette = .{ .page = .root, .selected = 0, .items = .{ .items = &items, .capacity = 1 }, .rows = .{ .items = &rows, .capacity = 1 } };
    palette.preview_gate.filtered(true);
    try std.testing.expect(palette.wantedTheme() == null);
    palette.preview_gate.filtered(false);
    try std.testing.expectEqualStrings("Nord", palette.wantedTheme().?);
    items[0].current = true;
    try std.testing.expect(palette.wantedTheme() == null);
}

fn previewTheme(self: *const Palette) ?[]const u8 {
    const len = self.preview_len orelse return null;
    return self.preview_buf[0..len];
}

/// The theme the terminals should show now (null: the saved one).
fn wantedTheme(self: *Palette) ?[]const u8 {
    return self.preview_gate.target(self.selectedTheme());
}

fn sameTheme(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Preview the selected theme in the terminals once the selection rests
/// on it, or show the saved theme again when it moved off the themes.
fn schedulePreview(self: *Palette, cause: model.PreviewCause) void {
    const hwnd = self.popup.hwnd orelse return;
    if (!self.active or sameTheme(self.wantedTheme(), self.previewTheme())) {
        _ = w32.KillTimer(hwnd, preview_timer_id);
        return;
    }
    _ = w32.SetTimer(hwnd, preview_timer_id, model.previewDelayMs(cause), @ptrCast(&previewTimer));
}

fn previewTimer(hwnd: w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w32.KillTimer(hwnd, id);
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return;
    const popup: *Popup = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const self: *Palette = @alignCast(@fieldParentPtr("popup", popup));
    if (!self.active) return;
    const theme = self.wantedTheme();
    if (sameTheme(theme, self.previewTheme())) return;
    self.applyTheme(theme);
}

/// Load the configuration with `theme` (null: as saved) and apply it to
/// the running app without saving anything, like the settings UI's theme
/// preview.
fn applyTheme(self: *Palette, theme: ?[]const u8) void {
    const app = self.ownerWindow().app;
    const alloc_ = app.core_app.alloc;
    var quiet_buf: [128]u8 = undefined;
    const quiet = gx.settings_map.quietReloadArg(&quiet_buf, self.notifications) catch return;
    var args: [2][:0]const u8 = .{ quiet, undefined };
    var len: usize = 1;
    var theme_arg: ?[:0]u8 = null;
    defer if (theme_arg) |arg| alloc_.free(arg);
    if (theme) |name| {
        if (name.len > self.preview_buf.len) return;
        theme_arg = gx.settings_map.themeArg(alloc_, name) catch return;
        args[1] = theme_arg.?;
        len = 2;
    }

    var config = gx.config_layers.loadWithOverrides(alloc_, args[0..len]) catch |err| {
        log.warn("cannot load the configuration for a theme preview err={}", .{err});
        return;
    };
    defer config.deinit();
    gx.perf.count("theme.reload", 1);
    app.applyConfig(&config) catch |err| {
        log.warn("cannot apply a theme preview err={}", .{err});
        return;
    };

    if (theme) |name| {
        @memcpy(self.preview_buf[0..name.len], name);
        self.preview_len = name.len;
    } else {
        self.preview_len = null;
    }
    if (self.active) {
        self.popup.applyTheme(self.tokens());
        self.popup.invalidate();
    }
}

/// Stop previewing; with `restore` the terminals show the saved theme
/// again.
fn endPreview(self: *Palette, restore: bool) void {
    if (popupAlive(&self.popup)) _ = w32.KillTimer(self.popup.hwnd.?, preview_timer_id);
    if (self.preview_len == null) return;
    if (restore) self.applyTheme(null);
    self.preview_len = null;
}

/// Show the saved theme again from the message loop: `restoreTimer` reloads
/// the configuration like `reload_config`. For a palette that goes away
/// while previewing, during the teardown of its terminal, when reloading
/// right away would lay out a tab whose terminals are being freed.
fn restoreSavedTheme(app: *App) void {
    if (app.quit_requested) return;
    const hwnd = app.msg_hwnd orelse return;
    _ = w32.SetTimer(hwnd, restore_timer_id, 0, @ptrCast(&restoreTimer));
}

fn restoreTimer(hwnd: w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w32.KillTimer(hwnd, id);
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return;
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));
    if (app.quit_requested) return;
    gx.perf.count("theme.reload", 1);
    app.core_app.performAction(app, .reload_config) catch |err| {
        log.warn("cannot restore the saved theme err={}", .{err});
    };
}

// -----------------------------------------------------------------------
// Input
// -----------------------------------------------------------------------

/// A key press in the palette, routed by the app's message loop before
/// the popup sees it. Returns true when the palette handled it; chords
/// bound to other actions return false so the loop hands them to the
/// surface.
pub fn handleKey(self: *Palette, vk: u16) bool {
    return self.keyPress(.{
        .vk = vk,
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
    }, true);
}

fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    if (adoptShown(popup)) self.active = true;
    return self.keyPress(key, false);
}

fn modelKey(key: Popup.Key) model.Key {
    return .{ .vk = key.vk, .ctrl = key.ctrl, .shift = key.shift, .alt = key.alt };
}

/// Handle a key press: navigation, running and closing, the pages, and the
/// chords bound to actions; editing keys go to the filter. `routed` is
/// true when the app's message loop asks first (`handleKey`) and false
/// when the popup's window procedure asks.
fn keyPress(self: *Palette, key: Popup.Key, routed: bool) bool {
    if (!self.active or key.vk == w32.VK_PROCESSKEY) return false;
    const plain = !key.ctrl and !key.alt;
    switch (key.vk) {
        w32.VK_ESCAPE => {
            self.close(true);
            return true;
        },
        w32.VK_RETURN => {
            const how = model.enterAction(modelKey(key));
            if (how != .none) {
                self.runSelected(how);
                return true;
            }
        },
        w32.VK_UP, w32.VK_DOWN => if (!key.alt) {
            self.move(if (key.vk == w32.VK_UP) -1 else 1);
            return true;
        },
        w32.VK_TAB => if (!key.ctrl and !key.alt) {
            self.move(if (key.shift) -1 else 1);
            return true;
        },
        w32.VK_PRIOR, w32.VK_NEXT => if (!key.alt) {
            self.pageBy(if (key.vk == w32.VK_PRIOR) -1 else 1);
            return true;
        },
        w32.VK_HOME => if (!key.shift and !key.alt) {
            self.select(self.nextItemRow(0, 1));
            return true;
        },
        w32.VK_END => if (!key.shift and !key.alt) {
            self.select(self.lastItemRow());
            self.scrollTo(self.maxScroll());
            self.updateHover();
            return true;
        },
        'P', 'N' => if (key.ctrl and !key.shift and !key.alt) {
            self.move(if (key.vk == 'P') -1 else 1);
            return true;
        },
        w32.VK_BACK => if (plain and self.page != .root and self.filterEmpty()) {
            self.setPage(.root);
            return true;
        },
        w32.VK_DELETE => if (key.shift and plain) {
            if (self.forgetSelected()) return true;
        },
        w32.VK_F4 => if (key.alt and !key.ctrl) {
            // Alt+F4 closes the window, not just the palette.
            const window = self.ownerWindow();
            self.close(true);
            if (window.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
            return true;
        },
        else => {},
    }
    if (plain) return false;

    // Ctrl+Backspace, Ctrl+arrows, the clipboard and undo edit the filter;
    // the app never bubbles them.
    if (model.isEditChord(modelKey(key))) return false;

    const mods: input.Mods = .{ .ctrl = key.ctrl, .shift = key.shift, .alt = key.alt };
    const action = trigger.actionForKey(self.keybindSet(), key.vk, mods) orelse {
        // Unbound chords do nothing here instead of reaching the terminal.
        return true;
    };
    if (opensTabSwitcher(action)) {
        if (self.page == .tabs) self.close(true) else self.setPage(.tabs);
        return true;
    }
    switch (action) {
        .toggle_command_palette => {
            self.close(true);
            return true;
        },
        // Clipboard chords (e.g. Ctrl+Shift+V) edit the filter.
        .copy_to_clipboard, .paste_from_clipboard, .select_all => {
            if (!routed) return false;
            if (self.popup.hwnd) |hwnd| _ = w32.SendMessageW(hwnd, w32.WM_KEYDOWN, key.vk, 0);
            return true;
        },
        else => {
            // The message loop closes the palette and gives the key to the
            // surface; keys it does not route are performed here.
            if (routed) return false;
            const pane = self.paneView();
            const app = pane.app();
            const reference = pane.reference();
            var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
            defer arena.deinit();
            const owned = action.clone(arena.allocator()) catch return true;
            self.close(true);
            const live = Pane.resolve(app, reference) orelse return true;
            _ = live.performBindingAction(owned) catch |err| {
                log.err("palette chord failed action={t} err={}", .{ action, err });
            };
            return true;
        },
    }
}

/// Whether the filter is empty, with no composition in progress.
fn filterEmpty(self: *const Palette) bool {
    const in = &self.popup.input;
    return in.buf.items.len == 0 and in.composition.items.len == 0;
}

fn onTextChanged(ctx: *anyopaque, popup: *Popup) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    if (adoptShown(popup)) self.active = true;
    self.textChanged();
}

/// An input method composes: filter with the composition as well.
fn onCompositionChanged(ctx: *anyopaque, popup: *Popup) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    if (adoptShown(popup)) self.active = true;
    self.textChanged();
}

fn textChanged(self: *Palette) void {
    if (!self.active) return;
    const in = &self.popup.input;
    var buf: [256]u8 = undefined;
    if (!model.queryChanged(self.filterText(), &buf, in.buf.items, in.caret, in.composition.items)) return;
    self.refilter(.typing);
    self.reposition();
    self.updateHover();
    self.popup.invalidate();
}

fn uiaLive(context: *anyopaque) bool {
    const self: *Palette = @ptrCast(@alignCast(context));
    return self.active and self.popup.visible and uia_bridge.attachmentAlive(self.ownerWindow().app, self.uia_attachment);
}
fn uiaBuild(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
    const self: *Palette = @ptrCast(@alignCast(context));
    try bridge.publishPalette(api, queue, self.uia_attachment, self, self.listView(), .{ .context = self, .is_live = uiaLive, .action = uiaAction });
}
fn uiaAction(context: *anyopaque, token: u64, action: *const uia.Action) bool {
    const self: *Palette = @ptrCast(@alignCast(context));
    if (!uiaLive(context)) return false;
    if (token == uia_bridge.palette_root and action.kind == .close) {
        self.close(true);
        return true;
    }
    if (token == uia_bridge.palette_filter) {
        if (action.kind == .focus) {
            const hwnd = self.popup.hwnd orelse return false;
            _ = w32.SetFocus(hwnd);
            return true;
        }
        if (action.kind != .set_value) return false;
        if (std.mem.indexOfAny(u8, action.value, "\r\n") != null) return false;
        self.popup.input.setText(self.ownerWindow().app.core_app.alloc, action.value) catch return false;
        self.textChanged();
        return true;
    }
    if (token == uia_bridge.palette_back and action.kind == .invoke) {
        self.setPage(.root);
        return true;
    }
    if (token < uia_bridge.palette_row_base) return false;
    const row = std.math.cast(usize, token - uia_bridge.palette_row_base) orelse return false;
    if (row >= self.rows.items.len or self.rows.items[row].kind != .item) return false;
    switch (action.kind) {
        .select => self.select(row),
        .invoke => self.run(self.rows.items[row].kind.item, .run),
        else => return false,
    }
    return true;
}

/// How a click runs an entry: with Ctrl in a new window, with Shift
/// keeping the palette open, like Enter.
fn clickAction() model.EnterAction {
    const how = model.enterAction(.{
        .vk = w32.VK_RETURN,
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
    });
    return if (how == .none) .run else how;
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    if (adoptShown(popup)) self.active = true;
    const view = self.listView();
    switch (event.kind) {
        .move => {
            self.mouse = event.pos;
            if (self.scrollbar.dragging()) {
                if (w32.GetKeyState(vk_lbutton) < 0) {
                    if (self.scrollbar.drag(view, self.content_height, view.h, event.pos)) |offset| {
                        self.scrollTo(offset);
                        popup.invalidate();
                    }
                    return;
                }
                // The button went up elsewhere (the capture was taken).
                self.scrollbar.release();
            }
            var changed = self.content_height > view.h and self.scrollbar.updateHover(view, event.pos);
            const row = self.rowAt(event.pos);
            if (row != self.hover) {
                self.hover = row;
                changed = true;
            }
            const back = if (self.back_rect) |r| r.contains(event.pos) else false;
            if (back != self.back_hover) {
                self.back_hover = back;
                changed = true;
            }
            if (changed) popup.repaint();
        },
        .leave => {
            self.mouse = null;
            if (self.scrollbar.dragging()) return;
            self.hover = null;
            self.back_hover = false;
            self.scrollbar.hover = false;
            popup.repaint();
        },
        .down => if (event.button == .left) {
            if (self.scrollbar.press(view, self.content_height, view.h, self.scroll, event.pos)) |offset| {
                self.scrollTo(offset);
                self.updateHover();
                if (popup.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
                popup.invalidate();
                return;
            }
            if (self.back_rect) |r| if (r.contains(event.pos)) {
                self.pressed = .back;
                popup.repaint();
                return;
            };
            if (self.rowAt(event.pos)) |row| {
                self.pressed = .{ .row = row };
                popup.repaint();
            }
        },
        .up => if (event.button == .left) {
            if (self.scrollbar.dragging()) {
                self.scrollbar.release();
                if (popup.hwnd) |hwnd| if (w32.GetCapture() == hwnd) {
                    _ = w32.ReleaseCapture();
                };
                popup.repaint();
                return;
            }
            const pressed = self.pressed orelse return;
            self.pressed = null;
            popup.invalidate();
            switch (pressed) {
                .back => if (self.back_rect) |r| if (r.contains(event.pos)) self.setPage(.root),
                .row => |row| if (self.rowAt(event.pos)) |at| if (at == row) {
                    self.selected = row;
                    self.run(self.rows.items[row].kind.item, clickAction());
                },
            }
        },
        .double_click => {},
        .wheel => {
            self.scrollTo(self.scroll - event.wheel * layout.wheel_step);
            self.mouse = event.pos;
            self.updateHover();
            popup.invalidate();
        },
    }
}

fn onDismissed(ctx: *anyopaque, _: *Popup, reason: Popup.DismissReason) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    self.active = false;
    self.hover = null;
    self.pressed = null;
    self.mouse = null;
    self.scrollbar = .{};
    self.endPreview(true);
    // Clicking elsewhere moved the focus already.
    if (reason != .deactivated and reason != .outside_click) self.focusSurface();
}

fn onPopupDpiChanged(ctx: *anyopaque, _: *Popup) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    self.reposition();
}

// -----------------------------------------------------------------------
// Painting
// -----------------------------------------------------------------------

/// How a row is drawn.
const RowState = enum { normal, hover, pressed, selected, selected_pressed };

/// The colors of a row in one state: its fill and what is drawn on it.
/// Text on the fill contrasts at least 4.5:1 with it, the icon, the
/// selection indicator and marks 3:1; in high contrast the system colors
/// stay as they are.
const RowColors = struct {
    fill: ?d2d.Color,
    text: d2d.Color,
    secondary: d2d.Color,
    /// Matched characters and the current tab or theme.
    accent: d2d.Color,
    icon: d2d.Color,
    /// The selection indicator and the dot of a tab with new output.
    mark: d2d.Color,
    indicator: bool,

    fn of(t: style.Tokens, state: RowState) RowColors {
        const selected = state == .selected or state == .selected_pressed;
        if (t.high_contrast) {
            if (state == .normal) return .{
                .fill = null,
                .text = t.text,
                .secondary = t.text_secondary,
                .accent = t.accent_text,
                .icon = t.text_secondary,
                .mark = t.accent,
                .indicator = false,
            };
            return .{
                .fill = t.selected,
                .text = t.selected_text,
                .secondary = t.selected_text,
                .accent = t.selected_text,
                .icon = t.selected_text,
                .mark = t.selected_text,
                .indicator = selected,
            };
        }
        const fill: ?d2d.Color = switch (state) {
            .normal => null,
            .hover => t.hover,
            .pressed => t.pressed,
            .selected => t.selected,
            .selected_pressed => style.mix(t.selected, t.surface_raised, 0.3),
        };
        const bg = fill orelse t.surface_raised;
        const text = switch (state) {
            .normal => t.text,
            .hover, .pressed => t.hover_text,
            .selected, .selected_pressed => t.selected_text,
        };
        return .{
            .fill = fill,
            .text = ui_color.ensureContrast(text, bg, floor.text),
            .secondary = ui_color.ensureContrast(t.text_secondary, bg, floor.text),
            .accent = ui_color.ensureContrast(t.accent_text, bg, floor.text),
            .icon = ui_color.ensureContrast(if (selected) t.accent else t.text_secondary, bg, floor.non_text),
            .mark = ui_color.ensureContrast(t.accent, bg, floor.non_text),
            .indicator = selected,
        };
    }

    /// The fill under the row's text.
    fn background(self: RowColors, t: style.Tokens) d2d.Color {
        return self.fill orelse t.surface_raised;
    }
};

const Palettes = std.EnumArray(RowState, RowColors);

fn rowColors(t: style.Tokens) Palettes {
    var out: Palettes = undefined;
    for (std.enums.values(RowState)) |state| out.set(state, .of(t, state));
    return out;
}

fn rowState(self: *const Palette, row: usize) RowState {
    const pressed = if (self.pressed) |p| switch (p) {
        .row => |r| r == row and self.hover == row,
        .back => false,
    } else false;
    if (self.selected == row) return if (pressed) .selected_pressed else .selected;
    if (pressed) return .pressed;
    if (self.hover == row) return .hover;
    return .normal;
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

    // A page's back button, then the filter.
    var input_x = layout.pad;
    self.back_rect = null;
    if (self.page != .root) {
        const back = self.backRect(canvas);
        self.paintBack(canvas, back, t);
        self.back_rect = back;
        input_x = back.x + back.w + style.space.xs;
    }
    popup.drawTextInput(canvas, .{
        .x = input_x,
        .y = layout.pad,
        .w = @max(0, size.width - input_x - layout.pad),
        .h = layout.input_height,
    }, t, self.page.placeholder());
    controls.hairline(canvas, 0, layout.list_top - canvas.hairline(), size.width, t);

    const view = self.listView();
    const chips = trigger.ChipColors.fromTokens(t);
    canvas.pushClip(view);
    if (self.rows.items.len == 0) {
        self.paintEmpty(canvas, view, t);
    } else {
        const scale = popup.scale();
        const colors = rowColors(t);
        for (self.rows.items, 0..) |row, i| {
            const y = style.snap(view.y + row.y - self.scroll, scale);
            if (y + row.h < view.y) continue;
            if (y > view.y + view.h) break;
            const rect: d2d.Rect = .{ .x = layout.pad, .y = y, .w = view.w - 2 * layout.pad, .h = row.h };
            switch (row.kind) {
                .header => |group| paintHeader(canvas, rect, group, t),
                .item => |index| self.paintItem(canvas, rect, &self.items.items[index], colors.get(self.rowState(i)), chips, t),
            }
        }
        self.scrollbar.draw(canvas, view, self.content_height, view.h, self.scroll, t);
    }
    canvas.popClip();

    self.paintFooter(canvas, .{
        .x = 0,
        .y = size.height - layout.footer_height,
        .w = size.width,
        .h = layout.footer_height,
    }, chips, t);
}

const back_label_style: d2d.TextStyle = .{ .size = style.font_size.body, .ellipsis = false };

/// The back button of a page: a chevron and the page's title, left of the
/// filter.
fn backRect(self: *const Palette, canvas: *d2d.Canvas) d2d.Rect {
    const label_w = canvas.measureTextCeil(self.page.title(), back_label_style, 400).width;
    return .{
        .x = layout.pad,
        .y = layout.pad,
        .w = style.space.s + style.icon.small + style.space.s + label_w + style.space.m,
        .h = layout.input_height,
    };
}

fn paintBack(self: *const Palette, canvas: *d2d.Canvas, rect: d2d.Rect, t: style.Tokens) void {
    const pressed = if (self.pressed) |p| p == .back and self.back_hover else false;
    const state: controls.State = .{ .hover = self.back_hover, .pressed = pressed };
    const colors = controls.buttonColors(.subtle, state, t);
    const r = canvas.snapRect(rect);
    if (colors.fill) |fill| canvas.fillRoundedRect(r, style.radius.control, fill);
    if (colors.border) |border| canvas.strokeRoundedRectPx(r, style.radius.control, border, 1);
    const glyph_x = r.x + style.space.s;
    canvas.drawIcon(icons.back, .{ .x = glyph_x, .y = r.y, .w = style.icon.small, .h = r.h }, style.icon.small, colors.text);
    var label = back_label_style;
    label.color = colors.text;
    const text_x = glyph_x + style.icon.small + style.space.s;
    canvas.drawText(self.page.title(), .{ .x = text_x, .y = r.y, .w = @max(0, r.x + r.w - text_x), .h = r.h }, label);
}

fn paintHeader(canvas: *d2d.Canvas, rect: d2d.Rect, group: Group, t: style.Tokens) void {
    const text_y = rect.y + style.space.s;
    canvas.drawText(group.title(), .{ .x = rect.x + layout.icon_x, .y = text_y, .w = rect.w - 2 * layout.icon_x, .h = rect.y + rect.h - text_y }, .{
        .size = style.font_size.caption,
        .weight = .semibold,
        .color = t.text_secondary,
    });
}

/// The no-results message, naming the filter; in Chinese, a hint to try
/// English or pinyin initials.
fn paintEmpty(self: *const Palette, canvas: *d2d.Canvas, view: d2d.Rect, t: style.Tokens) void {
    var buf: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const filter = self.filterText();
    if (filter.len == 0) {
        writer.writeAll(i18n.tr("No results")) catch {};
    } else {
        var cut: [96]u8 = undefined;
        i18n.format(&writer, i18n.tr("No results for “{query}”"), .{ .query = cutText(&cut, filter) }) catch {};
    }
    const line_h = style.type_ramp.body.line;
    var y = view.y + style.space.l;
    canvas.drawText(writer.buffered(), .{ .x = view.x + style.space.m, .y = y, .w = view.w - 2 * style.space.m, .h = line_h }, .{
        .size = style.font_size.body,
        .color = t.text_secondary,
        .align_x = .center,
    });
    if (filter.len == 0 or i18n.current() == .en) return;
    y += line_h + style.space.xs;
    canvas.drawText(i18n.tr("Try the English name or the pinyin initials."), .{
        .x = view.x + style.space.m,
        .y = y,
        .w = view.w - 2 * style.space.m,
        .h = style.type_ramp.caption.line,
    }, .{ .size = style.font_size.caption, .color = t.text_secondary, .align_x = .center });
}

/// The start of `text` that fits `buf`, cut at a character.
fn cutText(buf: []u8, text: []const u8) []const u8 {
    if (text.len <= buf.len) return text;
    var end = buf.len;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(buf[0..end], text[0..end]);
    return buf[0..end];
}

fn paintItem(
    self: *Palette,
    canvas: *d2d.Canvas,
    rect: d2d.Rect,
    item: *Item,
    c: RowColors,
    chips: trigger.ChipColors,
    t: style.Tokens,
) void {
    const fill_rect = canvas.snapRect(rect.inset(0, 1));
    if (c.fill) |fill| canvas.fillRoundedRect(fill_rect, style.radius.control, fill);
    if (c.indicator) {
        const bar = canvas.snapRect(controls.indicatorRect(fill_rect));
        canvas.fillRoundedRect(bar, bar.w / 2, c.mark);
    }

    const two_line = item.english;
    const title_h = layout.item_height;
    const title_y = if (two_line) rect.y + style.space.xs else rect.y;
    const icon_rect: d2d.Rect = .{ .x = rect.x + layout.icon_x, .y = title_y, .w = style.icon.standard, .h = title_h - (if (two_line) style.space.xs else 0) };
    canvas.drawIcon(item.icon, icon_rect, style.icon.standard, c.icon);
    if (item.unread and !item.current) {
        const dot: f32 = 6;
        canvas.fillRoundedRect(canvas.snapRect(.{
            .x = icon_rect.x + icon_rect.w - dot / 2,
            .y = icon_rect.y + icon_rect.h / 2 - style.icon.standard / 2 - dot / 4,
            .w = dot,
            .h = dot,
        }), dot / 2, c.mark);
    }

    // The end of the row: a theme's colors, the keycaps, a detail.
    var right = rect.x + rect.w - style.space.m;
    const center_y = title_y + (title_h - (if (two_line) style.space.xs else 0)) / 2;
    if (item.target == .theme) {
        const swatch_rect: d2d.Rect = .{ .x = right - layout.swatch_width, .y = center_y - layout.swatch_height / 2, .w = layout.swatch_width, .h = layout.swatch_height };
        self.paintSwatch(canvas, swatch_rect, item.target.theme.index, item.target.theme.name, t);
        right = swatch_rect.x - layout.gap;
    }
    const budget = rect.w * layout.end_share;
    if (item.shortcut) |shortcut| {
        const sequence = [_]input.Binding.Trigger{shortcut};
        const w = item.shortcut_width orelse measured: {
            const measured = trigger.measureSequence(canvas, &sequence);
            item.shortcut_width = measured;
            break :measured measured;
        };
        if (w <= budget) {
            _ = trigger.drawSequence(canvas, &sequence, right - w, center_y, chips);
            right -= w + layout.gap;
        }
    }
    if (item.detail.len > 0) {
        const detail_style: d2d.TextStyle = .{
            .size = style.font_size.caption,
            .color = if (item.current) c.accent else c.secondary,
            .align_x = .trailing,
        };
        const room = @max(0, @min(budget, right - (rect.x + layout.text_x) - 2 * layout.gap));
        const w = @min(room, canvas.measureTextCeil(item.detail, detail_style, 10_000).width);
        if (w > 0) {
            canvas.drawText(item.detail, .{ .x = right - w, .y = title_y, .w = w, .h = title_h - (if (two_line) style.space.xs else 0) }, detail_style);
            right -= w + layout.gap;
        }
    }

    const own = self.page != .root;
    const title = if (own) item.name else item.title;
    const x = rect.x + layout.text_x;
    const w = @max(0, right - x);
    const title_rect: d2d.Rect = .{ .x = x, .y = title_y, .w = w, .h = title_h - (if (two_line) style.space.xs else 0) };
    self.drawMatched(canvas, title, title_rect, .{ .size = style.font_size.body, .color = c.text }, c.accent);
    if (two_line) {
        const english = if (own) item.name_en else item.title_en;
        const line_y = title_rect.y + title_rect.h - style.space.xs;
        self.drawMatched(canvas, english, .{ .x = x, .y = line_y, .w = w, .h = style.type_ramp.caption.line + style.space.xs }, .{ .size = style.font_size.caption, .color = c.secondary }, c.accent);
    }
}

/// Draw `text` with the characters the query matched in `accent`,
/// semibold.
fn drawMatched(self: *const Palette, canvas: *d2d.Canvas, text: []const u8, rect: d2d.Rect, text_style: d2d.TextStyle, accent: d2d.Color) void {
    if (self.query.isEmpty()) return canvas.drawText(text, rect, text_style);
    var runs: [16]d2d.TextRun = undefined;
    canvas.drawTextRuns(text, rect, text_style, matchRuns(&self.query, text, accent, &runs));
}

/// The runs of `text` the query matched (`fuzzy.positions`), in `color`
/// and semibold, in `out`.
fn matchRuns(query: *const fuzzy.Query, text: []const u8, color: d2d.Color, out: []d2d.TextRun) []d2d.TextRun {
    var buf: fuzzy.Buffer = undefined;
    const prepared = buf.prepare(text);
    var matched: fuzzy.Positions = undefined;
    _ = fuzzy.positions(query, &prepared, &matched) orelse return out[0..0];
    var it: fuzzy.Runs = .init(text, &matched);
    var n: usize = 0;
    while (it.next()) |range| {
        if (n == out.len) break;
        out[n] = .{ .start = range.byte_start, .len = range.byte_end - range.byte_start, .color = color, .weight = .semibold };
        n += 1;
    }
    return out[0..n];
}

/// A theme's colors: its background with "Aa" in its foreground and six of
/// its palette colors.
fn paintSwatch(self: *Palette, canvas: *d2d.Canvas, rect: d2d.Rect, index: u32, name: []const u8, t: style.Tokens) void {
    const swatch = self.swatches.get(self.alloc(), global.io(), self.theme_dirs, index, name);
    const r = canvas.snapRect(rect);
    canvas.fillRoundedRect(r, style.radius.control, rgb(swatch.background));
    canvas.strokeRoundedRectPx(r, style.radius.control, t.border, 1);
    canvas.drawText("Aa", .{ .x = r.x + 2, .y = r.y, .w = 22, .h = r.h }, .{
        .size = 11,
        .weight = .semibold,
        .color = rgb(swatch.foreground),
        .align_x = .center,
        .ellipsis = false,
    });
    const dot: f32 = 6;
    var x = r.x + 26;
    const y = r.y + (r.h - dot) / 2;
    for (1..7) |i| {
        canvas.fillRoundedRect(canvas.snapRect(.{ .x = x, .y = y, .w = dot, .h = dot }), 1.5, rgb(swatch.color(i)));
        x += dot + 1.5;
    }
}

fn rgb(c: gx.theme_swatch.Rgb) d2d.Color {
    return d2d.Color.rgb(c.r, c.g, c.b);
}

/// A key and what it does to the selected entry, in the footer.
const Hint = struct {
    trigger: input.Binding.Trigger,
    label: []const u8,
};

/// The keys that act on the selected entry, most useful first.
fn footerHints(self: *const Palette, item: ?*const Item, out: *[4]Hint) []Hint {
    var n: usize = 0;
    if (item) |it| {
        const enter: input.Binding.Trigger = .{ .key = .{ .physical = .enter } };
        out[n] = .{ .trigger = enter, .label = switch (it.target) {
            .theme => i18n.tr("Apply"),
            .tab => i18n.tr("Switch"),
            .profile, .page => i18n.tr("Open"),
            else => i18n.tr("Run"),
        } };
        n += 1;
        switch (it.target) {
            .profile => {
                out[n] = .{ .trigger = .{ .key = .{ .physical = .enter }, .mods = .{ .ctrl = true } }, .label = i18n.tr("New Window") };
                n += 1;
            },
            .theme => {
                out[n] = .{ .trigger = .{ .key = .{ .physical = .enter }, .mods = .{ .shift = true } }, .label = i18n.tr("Apply Without Closing") };
                n += 1;
            },
            else => {},
        }
        if (it.rank > 0) {
            out[n] = .{ .trigger = .{ .key = .{ .physical = .delete }, .mods = .{ .shift = true } }, .label = i18n.tr("Remove") };
            n += 1;
        }
    }
    if (self.page != .root and self.filterEmpty() and n < out.len) {
        out[n] = .{ .trigger = .{ .key = .{ .physical = .backspace } }, .label = i18n.tr("Back") };
        n += 1;
    }
    return out[0..n];
}

/// The footer: what the selected entry is (a command's description, a
/// launch profile's command line) and the keys that act on it.
fn paintFooter(self: *Palette, canvas: *d2d.Canvas, rect: d2d.Rect, chips: trigger.ChipColors, t: style.Tokens) void {
    controls.hairline(canvas, rect.x, rect.y, rect.w, t);
    const item = self.selectedItem();
    const label_style: d2d.TextStyle = .{ .size = style.font_size.caption, .color = t.text_secondary, .ellipsis = false };
    const center_y = rect.y + rect.h / 2;

    var hint_buf: [4]Hint = undefined;
    const all = self.footerHints(item, &hint_buf);
    // As many hints as fit, from the most useful one.
    var widths: [4]f32 = undefined;
    var count: usize = 0;
    var total: f32 = 0;
    for (all, 0..) |hint, i| {
        const keys = trigger.measureSequence(canvas, &.{hint.trigger});
        const label = canvas.measureTextCeil(hint.label, label_style, 400).width;
        const w = keys + style.space.xs + label;
        const next = total + w + (if (i > 0) style.space.m else 0);
        if (next > rect.w * layout.hints_share) break;
        widths[i] = w;
        total = next;
        count += 1;
    }
    var x = rect.x + rect.w - style.space.m - total;
    const hints_x = x;
    for (all[0..count], widths[0..count]) |hint, w| {
        const keys_right = trigger.drawSequence(canvas, &.{hint.trigger}, x, center_y, chips);
        const label_x = keys_right + style.space.xs;
        canvas.drawText(hint.label, .{ .x = label_x, .y = rect.y, .w = x + w - label_x, .h = rect.h }, label_style);
        x += w + style.space.m;
    }

    const it = item orelse return;
    if (it.description.len == 0) return;
    const desc_x = rect.x + style.space.m;
    const desc_w = hints_x - desc_x - style.space.m;
    if (desc_w < 48) return;
    const desc_rect: d2d.Rect = .{ .x = desc_x, .y = rect.y, .w = desc_w, .h = rect.h };
    const desc_style: d2d.TextStyle = .{ .size = style.font_size.caption, .color = t.text_secondary };
    if (it.target == .profile) {
        canvas.drawTextMiddle(it.description, desc_rect, desc_style);
    } else {
        canvas.drawText(it.description, desc_rect, desc_style);
    }
}

// -----------------------------------------------------------------------
// Popup lifetime (shared with Keybinds.zig)
// -----------------------------------------------------------------------

/// Whether the window of `popup` still exists: Windows destroys owned
/// popups with their owner, e.g. when the tab moved to another window.
pub fn popupAlive(popup: *const Popup) bool {
    const hwnd = popup.hwnd orelse return false;
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    return userdata == @as(isize, @bitCast(@intFromPtr(popup)));
}

/// Whether the window of a hidden `popup` was shown again from outside
/// (automation and accessibility tools activate windows by handle); the
/// popup then counts as shown again so it can still be closed. Returns
/// true when it adopted such a window.
pub fn adoptShown(popup: *Popup) bool {
    if (popup.visible) return false;
    const hwnd = popup.hwnd orelse return false;
    if (w32.IsWindowVisible_(hwnd) == 0) return false;
    popup.visible = true;
    return true;
}

/// Destroy `popup` and free its resources. A window Windows destroyed with
/// its owner left `popup.hwnd` null (`WM_NCDESTROY`), so a handle that is
/// set is the popup's own.
pub fn releasePopup(popup: *Popup) void {
    popup.destroy();
}

/// Make `popup` a live popup owned by `owner`: create it, or recreate it
/// when its window is gone, belongs to another window or uses the other
/// dark/light frame. Returns false when it cannot be created.
pub fn ensurePopup(
    popup: *Popup,
    app: *App,
    owner: w32.HWND,
    options: Popup.Options,
    callbacks: Popup.Callbacks,
) bool {
    if (popup.hwnd != null) {
        if (!popup.reuse_invalid and popupAlive(popup) and popup.owner == owner and popup.options.dark == options.dark) return true;
        releasePopup(popup);
    }
    const factory = app.uiFactory() orelse return false;
    popup.create(app.hinstance, owner, factory, options, callbacks) catch |err| {
        log.warn("failed to create a popup err={}", .{err});
        return false;
    };
    return true;
}

// -----------------------------------------------------------------------
// State shared by the palettes of the process (GUI thread)
// -----------------------------------------------------------------------

/// The palette history (`gx.palette_history`): loaded from its state file
/// when a palette first opens, written back after every pick or removal.
var history: History = .{};
var history_loaded = false;

fn loadHistory(alloc_: Allocator) void {
    if (history_loaded) return;
    history_loaded = true;
    const path = History.defaultPath(alloc_) catch |err| {
        log.warn("cannot locate the palette history err={}", .{err});
        return;
    };
    defer alloc_.free(path);
    history = History.load(alloc_, global.io(), path) catch |err| {
        log.warn("cannot read the palette history err={}", .{err});
        return;
    };
}

fn commitHistory(alloc_: Allocator) void {
    const path = History.defaultPath(alloc_) catch |err| {
        log.warn("cannot locate the palette history err={}", .{err});
        return;
    };
    defer alloc_.free(path);
    history.commit(alloc_, global.io(), path) catch |err| {
        log.warn("cannot save the palette history err={}", .{err});
    };
}

/// The wall clock in seconds since the Unix epoch, for the history.
fn unixNow() i64 {
    const ns = std.Io.Clock.real.now(global.io()).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

/// The theme names of the theme directories, listed again only when a
/// directory changed (its modification time), so opening a palette does
/// not list hundreds of files every time. The list's memory is its own.
const ThemeNames = struct {
    list: ?gx.settings_map.ThemeList = null,
    /// The directories and their modification times the list is of.
    stamp: u64 = 0,
    /// Counts the lists, so theme indices of an older one are not used.
    generation: u64 = 0,

    fn get(self: *ThemeNames, io: std.Io, dirs: []const []const u8) []const [:0]const u8 {
        const stamp = dirStamp(io, dirs);
        if (self.list == null or stamp != self.stamp) {
            if (gx.settings_map.listThemes(std.heap.page_allocator, io, dirs)) |fresh| {
                if (self.list) |*old| old.deinit();
                self.list = fresh;
                self.stamp = stamp;
                self.generation +%= 1;
            } else |err| log.warn("cannot list the themes err={}", .{err});
        }
        return if (self.list) |list| list.names else &.{};
    }

    fn dirStamp(io: std.Io, dirs: []const []const u8) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        for (dirs) |path| {
            hasher.update(path);
            var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
                hasher.update("\x00missing");
                continue;
            };
            defer dir.close(io);
            const stat = dir.stat(io) catch {
                hasher.update("\x00unknown");
                continue;
            };
            const mtime: i128 = stat.mtime.nanoseconds;
            hasher.update(std.mem.asBytes(&mtime));
        }
        return hasher.final();
    }
};

var theme_names: ThemeNames = .{};

test "row colors keep text readable on every row fill" {
    const testing = std.testing;
    // bg, fg, cursor (0 = none), palette 4, palette 12.
    const themes = [_][5]u24{
        .{ 0x2e3440, 0xd8dee9, 0xd8dee9, 0x81a1c1, 0x81a1c1 }, // Nord
        .{ 0x1e1e2e, 0xcdd6f4, 0xf5e0dc, 0x89b4fa, 0x89b4fa }, // GX Mocha
        .{ 0xeff1f5, 0x4c4f69, 0xdc8a78, 0x1e66f5, 0x1e66f5 }, // Catppuccin Latte
        .{ 0xfdf6e3, 0x657b83, 0x657b83, 0x268bd2, 0x839496 }, // Solarized Light
        .{ 0x000000, 0xffffff, 0, 0x0000ee, 0x5c5cff }, // xterm
    };
    for (themes) |th| {
        const cursor: ?d2d.Color = if (th[2] == 0) null else d2d.Color.hex(th[2]);
        const t = style.Tokens.fromTheme(d2d.Color.hex(th[0]), d2d.Color.hex(th[1]), cursor, d2d.Color.hex(th[3]), d2d.Color.hex(th[4]));
        const all = rowColors(t);
        for (std.enums.values(RowState)) |state| {
            const c = all.get(state);
            const bg = c.background(t);
            try testing.expect(style.contrast(c.text, bg) >= floor.text);
            try testing.expect(style.contrast(c.secondary, bg) >= floor.text);
            try testing.expect(style.contrast(c.accent, bg) >= floor.text);
            try testing.expect(style.contrast(c.icon, bg) >= floor.non_text);
            try testing.expect(style.contrast(c.mark, bg) >= floor.non_text);
        }
        // The selected row has the selection fill and indicator; hover and
        // pressed only shade.
        try testing.expect(all.get(.selected).indicator);
        try testing.expect(!all.get(.hover).indicator);
        try testing.expectEqual(t.selected, all.get(.selected).fill.?);
        try testing.expectEqual(t.hover, all.get(.hover).fill.?);
        try testing.expectEqual(@as(?d2d.Color, null), all.get(.normal).fill);
    }
}

test "row colors use the system colors in high contrast" {
    const testing = std.testing;
    const t = style.Tokens.fromSystem(.{});
    const selected = RowColors.of(t, .selected);
    try testing.expectEqual(t.selected, selected.fill.?);
    try testing.expectEqual(t.selected_text, selected.text);
    try testing.expectEqual(t.selected_text, selected.accent);
    try testing.expect(selected.indicator);
    const normal = RowColors.of(t, .normal);
    try testing.expectEqual(t.text, normal.text);
    try testing.expectEqual(@as(?d2d.Color, null), normal.fill);
}

test "matchRuns marks what the query matched" {
    const testing = std.testing;
    const query: fuzzy.Query = .init("ntab");
    var runs: [16]d2d.TextRun = undefined;
    const color = d2d.Color.hex(0x89b4fa);
    const out = matchRuns(&query, "New Tab", color, &runs);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(usize, 0), out[0].start);
    try testing.expectEqual(@as(usize, 1), out[0].len);
    try testing.expectEqual(@as(usize, 4), out[1].start);
    try testing.expectEqual(@as(usize, 3), out[1].len);
    try testing.expectEqual(d2d.FontWeight.semibold, out[1].weight.?);
    // Pinyin initials mark the characters, in bytes.
    const pinyin: fuzzy.Query = .init("xjbq");
    const cjk = matchRuns(&pinyin, "新建标签页", color, &runs);
    try testing.expectEqual(@as(usize, 1), cjk.len);
    try testing.expectEqual(@as(usize, 12), cjk[0].len);
    const none: fuzzy.Query = .init("xyz");
    try testing.expectEqual(@as(usize, 0), matchRuns(&none, "New Tab", color, &runs).len);
}

test "cutText cuts at a character" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("ab", cutText(&buf, "ab"));
    try testing.expectEqualStrings("a新", cutText(&buf, "a新建"));
}

test "entry cache stamp tracks commands profiles bindings and language" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    var copy = try config.clone(testing.allocator);
    defer copy.deinit();
    const hints_: trigger.Hints = .{ .set = &config.keybind.set };
    const original = configStamp(&config, hints_);
    try testing.expectEqual(original, configStamp(&copy, .{ .set = &copy.keybind.set }));
    config.@"font-size" = 18;
    try testing.expectEqual(original, configStamp(&config, hints_));
    config.@"command-palette-entry".value.items[0].title = "Changed title";
    const commands = configStamp(&config, hints_);
    try testing.expect(commands != original);
    const a = config._arena.?.allocator();
    try config.@"gx-launch-profile".map.put(a, "Test Shell", "cmd.exe /d");
    const profiles = configStamp(&config, hints_);
    try testing.expect(profiles != commands);
    try config.keybind.set.parseAndPut(a, "ctrl+f9=new_tab");
    const bindings = configStamp(&config, hints_);
    try testing.expect(bindings != profiles);
    var blocked: @import("../shortcut_conflicts.zig").Conflicts = .{};
    defer blocked.deinit(testing.allocator);
    try blocked.list.append(testing.allocator, .{ .chord = .{ .mods = w32.MOD_CONTROL, .vk = w32.VK_F9 }, .reason = .hotkey });
    try testing.expect(bindings != configStamp(&config, .{ .set = hints_.set, .blocked = &blocked }));
    const language = i18n.current();
    defer i18n.setCurrent(language);
    i18n.setCurrent(if (language == .en) .zh_CN else .en);
    try testing.expect(bindings != configStamp(&config, hints_));
}

test "theme names reuse an unchanged directory and refresh missing directories" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fs.path.join(testing.allocator, &.{ root, "themes" });
    defer testing.allocator.free(path);
    var names: ThemeNames = .{};
    defer if (names.list) |*list| list.deinit();
    try testing.expectEqual(@as(usize, 0), names.get(io, &.{path}).len);
    const missing = names.generation;
    try tmp.dir.createDirPath(io, "themes");
    try tmp.dir.writeFile(io, .{ .sub_path = "themes/Nord", .data = "background = #2e3440\n" });
    try testing.expectEqualStrings("Nord", names.get(io, &.{path})[0]);
    try testing.expect(names.generation != missing);
    const generation = names.generation;
    try testing.expectEqualStrings("Nord", names.get(io, &.{path})[0]);
    try testing.expectEqual(generation, names.generation);
}

test "pressed rows require the pointer and keep selection distinct" {
    const testing = std.testing;
    var palette: Palette = .{ .selected = 1, .hover = 2, .pressed = .{ .row = 2 } };
    try testing.expectEqual(RowState.selected, palette.rowState(1));
    try testing.expectEqual(RowState.pressed, palette.rowState(2));
    palette.hover = 3;
    try testing.expectEqual(RowState.normal, palette.rowState(2));
    try testing.expectEqual(RowState.hover, palette.rowState(3));
    palette.hover = 1;
    palette.pressed = .{ .row = 1 };
    try testing.expectEqual(RowState.selected_pressed, palette.rowState(1));
    const t = style.Tokens.fromColors(d2d.Color.hex(0x2e3440), d2d.Color.hex(0xd8dee9), d2d.Color.hex(0x81a1c1));
    const hover = RowColors.of(t, .hover);
    const pressed = RowColors.of(t, .pressed);
    try testing.expect(style.contrast(pressed.fill.?, t.surface_raised) < style.contrast(hover.fill.?, t.surface_raised));
}
