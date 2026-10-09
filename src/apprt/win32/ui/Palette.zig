//! The command palette of a terminal surface: a `Popup` centered near the
//! top of its window, with a filter input (IME-capable) over a grouped,
//! scrollable list of what can be run from the keyboard:
//!
//!   - the configured `command-palette-entry` commands, with the keycaps
//!     of their bindings;
//!   - the window's tabs ("Switch to Tab: <title>");
//!   - the launch profiles ("New Tab: <profile>", like
//!     `gx:new_tab_profile`);
//!   - the settings sections (`Settings.show`) and the UI language;
//!   - the themes ("Theme: <name>"), saved to `gui-settings.ghostty`;
//!     while the selection rests on a theme the terminals preview it, and
//!     closing the palette without picking it restores the saved one.
//!
//! Titles are shown in the UI language and matched (`fuzzy.zig`) against
//! both the translation and the English msgid. Picks are remembered for
//! the process (`history`, a `fuzzy.Frecency`), keyed by the English msgid
//! or action string: with an empty filter the recently used entries come
//! first, and they rank higher in filtered results.
//!
//! The owning `Surface` embeds this struct as `palette` and calls
//! `setActive` (from `toggle_command_palette`), `reposition` (on resize),
//! `onDpiChanged`, `onLanguageChanged` and `deinit`. The app's message
//! loop gives `handleKey` the first look at key presses in the popup
//! (`ownsEdit`); chords bound to other actions then bubble up to the
//! surface. The palette also hosts the window's keyboard shortcut sheet
//! (`keybinds`, see `Keybinds.zig`), which shares its lifetime.
const Palette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../../input.zig");
const global = @import("../../../global.zig");
const Config = @import("../../../config.zig").Config;
const themepkg = @import("../../../config/theme.zig");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Keybinds = @import("Keybinds.zig");
const Popup = @import("Popup.zig");
const Settings = @import("Settings.zig");
const d2d = @import("d2d.zig");
const fuzzy = @import("fuzzy.zig");
const style = @import("style.zig");
const trigger = @import("trigger.zig");

const log = std.log.scoped(.win32);
const Action = input.Binding.Action;

/// Layout in DIPs.
const layout = struct {
    const width_max: f32 = 640;
    const width_min: f32 = 360;
    /// Distance from the window edges and below the chrome.
    const margin: f32 = 12;
    const top_gap: f32 = 8;
    const pad: f32 = 8;
    const input_height: f32 = 36;
    /// The top of the list, below the input and its separator.
    const list_top: f32 = pad + input_height + pad + 1;
    const list_pad: f32 = 4;
    const list_height_max: f32 = 470;
    const empty_height: f32 = 56;
    const header_height: f32 = 28;
    const item_height: f32 = 36;
    const item_height_described: f32 = 50;
    const row_radius: f32 = 6;
    const icon_size: f32 = 16;
    const text_x: f32 = 12 + icon_size + 10;
    const wheel_step: f32 = 3 * item_height;
};

/// How many recently used entries an empty filter shows.
const max_recent = 5;

/// How long the selection rests on a theme before the terminals preview
/// it, and the timer that waits for it (on the popup window).
const preview_delay_ms = 150;
const preview_timer_id: usize = 1;

/// Segoe Fluent Icons / MDL2 Assets glyphs of the entry kinds.
const icons = struct {
    const command: u21 = 0xE945;
    const tab: u21 = 0xE7C4;
    const profile: u21 = 0xE756;
    const settings: u21 = 0xE713;
    const language: u21 = 0xE774;
    const theme: u21 = 0xE790;
};

const Group = enum {
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

const group_count = @typeInfo(Group).@"enum".fields.len;

/// What an entry does when it runs.
const Target = union(enum) {
    command: Action,
    /// The tab whose active surface this is.
    tab: *Surface,
    /// A launch profile id.
    profile: [:0]const u8,
    settings,
    language: i18n.Language,
    theme: []const u8,
};

const Item = struct {
    group: Group,
    icon: u21,
    /// The title in the UI language, and in English for matching.
    title: []const u8,
    title_en: []const u8,
    description: []const u8 = "",
    /// The `History` key; empty for entries that are not remembered.
    key: []const u8 = "",
    shortcut: ?input.Binding.Trigger = null,
    /// The current tab or theme.
    current: bool = false,
    target: Target,
    frecency: u32 = 0,
    score: i32 = 0,
};

const Row = struct {
    kind: union(enum) {
        header: Group,
        item: usize,
        /// "Type to search N themes…".
        theme_hint,
    },
    /// Position in the list content.
    y: f32 = 0,
    h: f32 = 0,
};

popup: Popup = .{},

/// The keyboard shortcut sheet of the window (see `Keybinds.show`).
keybinds: Keybinds.Sheet = .{},

/// Whether the palette is shown.
active: bool = false,

/// The entries of the current session; they and their strings live in
/// `arena`, which is reset each time the palette opens.
arena: ?std.heap.ArenaAllocator = null,
items: std.ArrayList(Item) = .empty,
theme_count: usize = 0,

/// The rows on display for the current filter.
rows: std.ArrayList(Row) = .empty,
content_height: f32 = 0,
scroll: f32 = 0,
/// Row indices (item rows only).
selected: ?usize = null,
hover: ?usize = null,
pressed: ?usize = null,

/// The theme the terminals show as a preview while the selection rests on
/// it (`preview_buf[0..preview_len]`), or null.
preview_len: ?usize = null,
preview_buf: [256]u8 = undefined,
/// The in-app notifications when the palette opened; previews keep them
/// without the "reloaded" notification.
notifications: Config.AppNotifications = .{},

pub fn surface(self: *Palette) *Surface {
    return @alignCast(@fieldParentPtr("palette", self));
}

fn alloc(self: *Palette) Allocator {
    return self.surface().app.core_app.alloc;
}

/// Destroy the popups and free the entries.
pub fn deinit(self: *Palette) void {
    self.keybinds.deinit();
    self.endPreview(false);
    releasePopup(&self.popup);
    self.rows.deinit(self.alloc());
    if (self.arena) |*arena| arena.deinit();
    self.arena = null;
    self.items = .empty;
    self.active = false;
}

/// Whether `hwnd` is the palette popup, whose filter input has the
/// keyboard focus while the palette is shown.
pub fn ownsEdit(self: *const Palette, hwnd: ?w32.HWND) bool {
    const popup = self.popup.hwnd orelse return false;
    return hwnd != null and hwnd.? == popup;
}

/// Show or hide the command palette.
pub fn setActive(self: *Palette, active: bool) void {
    if (!active) {
        self.close(true);
        return;
    }
    const s = self.surface();
    if (s.search_bar.active) s.search_bar.setActive(false, &[_:0]u8{});
    const owner = s.parent_window.hwnd orelse return;
    const t = self.tokens();
    if (!ensurePopup(&self.popup, s.app, owner, .{
        .activate = true,
        .text_input = true,
        .dismiss_on_escape = true,
        .dismiss_on_outside_click = true,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
    }, .{
        .ctx = self,
        .paint = paint,
        .key = onKey,
        .mouse = onMouse,
        .text_changed = onTextChanged,
        .dismissed = onDismissed,
        .dpi_changed = onPopupDpiChanged,
    })) return;
    self.popup.setBorderColor(t.border);

    self.active = true;
    self.notifications = s.app.config.@"app-notifications";
    self.popup.input.clear();
    self.buildItems();
    self.refilter();
    const rect = self.bounds() orelse return;
    self.popup.show(rect);
}

/// Hide the palette, ending a theme preview; `restore_focus` gives the
/// keyboard back to the terminal.
fn close(self: *Palette, restore_focus: bool) void {
    const was_active = self.active;
    self.active = false;
    self.hover = null;
    self.pressed = null;
    self.popup.hide();
    self.endPreview(true);
    if (was_active and restore_focus) self.focusSurface();
}

fn focusSurface(self: *Palette) void {
    if (self.surface().hwnd) |hwnd| _ = w32.SetFocus(hwnd);
}

/// Move and size the palette for its window (after a resize).
pub fn reposition(self: *Palette) void {
    if (!self.active or !popupAlive(&self.popup)) return;
    const rect = self.bounds() orelse return;
    self.popup.setBounds(rect);
}

/// The DPI of the surface changed: resize the palette.
pub fn onDpiChanged(self: *Palette) void {
    self.reposition();
    self.keybinds.reposition();
}

/// The UI language changed: retranslate the entries.
pub fn onLanguageChanged(self: *Palette) void {
    self.keybinds.onLanguageChanged();
    if (!self.active) return;
    self.buildItems();
    self.refilter();
    self.reposition();
    self.popup.invalidate();
}

fn tokens(self: *Palette) style.Tokens {
    return style.Tokens.fromConfig(&self.surface().app.config);
}

/// The palette's place in screen pixels: centered below the window's
/// chrome, as tall as the rows need up to a limit.
fn bounds(self: *Palette) ?w32.RECT {
    const window = self.surface().parent_window;
    const hwnd = window.hwnd orelse return null;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return null;
    const scale = windowScale(hwnd);
    const client_w = style.dip(client.right - client.left, scale);
    const client_h = style.dip(client.bottom - client.top, scale);
    const top = style.dip(window.chromeHeight(), scale) + layout.top_gap;

    const width = std.math.clamp(client_w - 2 * layout.margin, layout.width_min, layout.width_max);
    const list_max = @max(layout.empty_height, @min(layout.list_height_max, client_h - top - layout.margin - layout.list_top));
    const list_h = std.math.clamp(self.content_height, layout.empty_height, list_max);

    var origin: w32.POINT = .{ .x = 0, .y = 0 };
    _ = w32.ClientToScreen(hwnd, &origin);
    const left = origin.x + style.px(@max(0, (client_w - width) / 2), scale);
    const y = origin.y + style.px(top, scale);
    return .{
        .left = left,
        .top = y,
        .right = left + style.px(width, scale),
        .bottom = y + style.px(layout.list_top + list_h, scale),
    };
}

fn windowScale(hwnd: w32.HWND) f32 {
    const dpi = w32.GetDpiForWindow(hwnd);
    return @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0;
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
    self.theme_count = 0;

    self.addTabs(a) catch |err| log.warn("palette tabs unavailable err={}", .{err});
    self.addProfiles(a) catch |err| log.warn("palette launch profiles unavailable err={}", .{err});
    self.addCommands(a) catch |err| log.warn("palette commands unavailable err={}", .{err});
    self.addSettings(a) catch |err| log.warn("palette settings unavailable err={}", .{err});
    self.addThemes(a) catch |err| log.warn("palette themes unavailable err={}", .{err});

    for (self.items.items) |*item| item.frecency = history.get(item.key);
}

fn keybindSet(self: *Palette) *const input.Binding.Set {
    return &self.surface().app.config.keybind.set;
}

fn addTabs(self: *Palette, a: Allocator) !void {
    const window = self.surface().parent_window;
    for (0..window.tab_count) |i| {
        const title16 = window.tab_titles[i][0..window.tab_title_lens[i]];
        const name = std.unicode.utf16LeToUtf8Alloc(a, title16) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => "",
        };
        const label = if (name.len > 0) name else "Ghostty GX";
        try self.items.append(a, .{
            .group = .tabs,
            .icon = icons.tab,
            .title = try i18n.fill(a, i18n.tr("Switch to Tab: {title}"), .{ .title = label }),
            .title_en = try i18n.fill(a, "Switch to Tab: {title}", .{ .title = label }),
            .description = if (i == window.active_tab) i18n.tr("Current Tab") else "",
            .shortcut = trigger.find(self.keybindSet(), .{ .goto_tab = i + 1 }),
            .current = i == window.active_tab,
            .target = .{ .tab = window.tab_active_surface[i] },
        });
    }
}

fn addProfiles(self: *Palette, a: Allocator) !void {
    var list = try self.surface().app.launchProfiles();
    defer list.deinit();
    for (list.profiles) |profile| {
        const id = try a.dupeZ(u8, profile.id);
        const name = try gx.profiles.displayName(a, profile);
        const name_en = if (profile.kind == .custom)
            name
        else
            try i18n.fill(a, profile.name, .{ .name = profile.name_arg orelse "" });
        try self.items.append(a, .{
            .group = .profiles,
            .icon = icons.profile,
            .title = try i18n.fill(a, i18n.tr("New Tab: {name}"), .{ .name = name }),
            .title_en = try i18n.fill(a, "New Tab: {name}", .{ .name = name_en }),
            .description = try commandText(a, profile.command),
            .key = try std.fmt.allocPrint(a, "gx:new_tab_profile:{s}", .{id}),
            .shortcut = trigger.find(self.keybindSet(), .{ .gx = .{ .new_tab_profile = id } }),
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

fn addCommands(self: *Palette, a: Allocator) !void {
    const app = self.surface().app;
    for (app.config.@"command-palette-entry".value.items) |command| {
        if (!supported(command.action)) continue;
        // Copied: a configuration reload frees the originals.
        const action = try command.action.clone(a);
        try self.items.append(a, .{
            .group = .commands,
            .icon = icons.command,
            .title = try a.dupe(u8, i18n.trRuntime(command.title)),
            .title_en = try a.dupe(u8, command.title),
            .description = if (command.description.len > 0)
                try a.dupe(u8, i18n.trRuntime(command.description))
            else
                "",
            .key = try std.fmt.allocPrint(a, "{f}", .{action}),
            .shortcut = trigger.find(self.keybindSet(), action),
            .target = .{ .command = action },
        });
    }
}

/// Whether running `action` from the palette does something on Windows.
fn supported(action: Action) bool {
    return switch (action) {
        .toggle_command_palette,
        .toggle_tab_overview,
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

fn addSettings(self: *Palette, a: Allocator) !void {
    const sections = [_][:0]const u8{ "Language", "Appearance", "Font", "Interaction", "Shell", "About" };
    inline for (sections) |section| {
        try self.items.append(a, .{
            .group = .settings,
            .icon = icons.settings,
            .title = try i18n.fill(a, i18n.tr("Settings: {section}"), .{ .section = i18n.tr(section) }),
            .title_en = try i18n.fill(a, "Settings: {section}", .{ .section = section }),
            .key = "settings:" ++ section,
            .target = .settings,
        });
    }

    const current = i18n.current();
    const next: i18n.Language = switch (current) {
        .zh_CN => .en,
        .en => .zh_CN,
    };
    try self.items.append(a, .{
        .group = .settings,
        .icon = icons.language,
        .title = try i18n.fill(a, i18n.tr("Switch Language to {language}"), .{ .language = next.nativeName() }),
        .title_en = try i18n.fill(a, "Switch Language to {language}", .{ .language = next.nativeName() }),
        .description = try i18n.fill(a, i18n.tr("Current language: {language}"), .{ .language = current.nativeName() }),
        .key = "language",
        .target = .{ .language = next },
    });
}

fn addThemes(self: *Palette, a: Allocator) !void {
    const app = self.surface().app;
    var dirs: std.ArrayList([]const u8) = .empty;
    var it: themepkg.LocationIterator = .{ .arena_alloc = a };
    while (it.next() catch null) |location| try dirs.append(a, location.dir);

    var list = try gx.settings_map.listThemes(self.alloc(), global.io(), dirs.items);
    defer list.deinit();
    const current = gx.settings_map.themeName(app.config.theme);
    for (list.names) |theme| {
        const name = try a.dupe(u8, theme);
        const is_current = if (current) |c| std.mem.eql(u8, c, name) else false;
        try self.items.append(a, .{
            .group = .themes,
            .icon = icons.theme,
            .title = try i18n.fill(a, i18n.tr("Theme: {name}"), .{ .name = name }),
            .title_en = try i18n.fill(a, "Theme: {name}", .{ .name = name }),
            .description = if (is_current) i18n.tr("Current Theme") else "",
            .key = try std.fmt.allocPrint(a, "theme:{s}", .{name}),
            .current = is_current,
            .target = .{ .theme = name },
        });
        self.theme_count += 1;
    }
}

// -----------------------------------------------------------------------
// Filtering
// -----------------------------------------------------------------------

/// Rebuild the rows for the filter text and select the first entry.
fn refilter(self: *Palette) void {
    const gpa = self.alloc();
    self.rows.clearRetainingCapacity();
    self.hover = null;
    self.pressed = null;

    var buf: [1024]u8 = undefined;
    const text = self.popup.input.utf8Range(&buf, 0, self.popup.input.buf.items.len);
    const query: fuzzy.Query = .init(text);
    const result = if (query.isEmpty()) self.listAll(gpa) else self.listMatches(gpa, &query);
    result catch |err| log.warn("palette filter failed err={}", .{err});

    var y: f32 = layout.list_pad;
    for (self.rows.items) |*row| {
        row.y = y;
        row.h = switch (row.kind) {
            .header => layout.header_height,
            .theme_hint => layout.header_height,
            .item => |i| if (self.items.items[i].description.len > 0)
                layout.item_height_described
            else
                layout.item_height,
        };
        y += row.h;
    }
    self.content_height = if (self.rows.items.len == 0) 0 else y + layout.list_pad;
    self.scroll = 0;
    self.selected = self.nextItemRow(0, 1);
    self.schedulePreview();
}

/// Every entry by group, the recently used ones first. Themes are
/// hundreds, so only the current one is listed until the user types.
fn listAll(self: *Palette, gpa: Allocator) !void {
    var recent: [max_recent]usize = undefined;
    var recent_len: usize = 0;
    for (self.items.items, 0..) |item, i| {
        if (item.frecency == 0) continue;
        // Insert into the top list, most frecent first.
        var pos = recent_len;
        while (pos > 0 and self.items.items[recent[pos - 1]].frecency < item.frecency) pos -= 1;
        if (pos >= max_recent) continue;
        const end = @min(recent_len, max_recent - 1);
        var k = end;
        while (k > pos) : (k -= 1) recent[k] = recent[k - 1];
        recent[pos] = i;
        recent_len = @min(recent_len + 1, max_recent);
    }
    if (recent_len > 0) {
        try self.rows.append(gpa, .{ .kind = .{ .header = .recent } });
        for (recent[0..recent_len]) |i| try self.rows.append(gpa, .{ .kind = .{ .item = i } });
    }

    for ([_]Group{ .tabs, .profiles, .commands, .settings, .themes }) |group| {
        var header = false;
        for (self.items.items, 0..) |item, i| {
            if (item.group != group) continue;
            if (std.mem.indexOfScalar(usize, recent[0..recent_len], i) != null) continue;
            if (group == .themes and !item.current) continue;
            if (!header) {
                try self.rows.append(gpa, .{ .kind = .{ .header = group } });
                header = true;
            }
            try self.rows.append(gpa, .{ .kind = .{ .item = i } });
        }
        if (group == .themes and self.theme_count > 0) {
            if (!header) try self.rows.append(gpa, .{ .kind = .{ .header = group } });
            try self.rows.append(gpa, .{ .kind = .theme_hint });
        }
    }
}

/// The entries matching `query`: groups ordered by their best match,
/// entries by score.
fn listMatches(self: *Palette, gpa: Allocator, query: *const fuzzy.Query) !void {
    var best: [group_count]?i32 = @splat(null);
    var matched: std.ArrayList(usize) = .empty;
    defer matched.deinit(gpa);

    for (self.items.items, 0..) |*item, i| {
        const translated = fuzzy.score(query, item.title);
        const english = if (std.mem.eql(u8, item.title, item.title_en)) null else fuzzy.score(query, item.title_en);
        const score = maxScore(translated, english) orelse continue;
        item.score = score + @as(i32, @intCast(@min(item.frecency / 8, 24)));
        const g = @intFromEnum(item.group);
        best[g] = if (best[g]) |b| @max(b, item.score) else item.score;
        try matched.append(gpa, i);
    }

    const Context = struct {
        items: []const Item,
        best: *const [group_count]?i32,

        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ia = ctx.items[a];
            const ib = ctx.items[b];
            if (ia.group != ib.group) {
                const ba = ctx.best[@intFromEnum(ia.group)].?;
                const bb = ctx.best[@intFromEnum(ib.group)].?;
                if (ba != bb) return ba > bb;
                return @intFromEnum(ia.group) < @intFromEnum(ib.group);
            }
            if (ia.score != ib.score) return ia.score > ib.score;
            // Equal matches: the shorter title first (it matches more of
            // it), except for themes, which stay in name order.
            if (ia.group != .themes and ia.title.len != ib.title.len) return ia.title.len < ib.title.len;
            return a < b;
        }
    };
    std.mem.sort(usize, matched.items, Context{ .items = self.items.items, .best = &best }, Context.lessThan);

    var group: ?Group = null;
    for (matched.items) |i| {
        const item_group = self.items.items[i].group;
        if (group != item_group) {
            try self.rows.append(gpa, .{ .kind = .{ .header = item_group } });
            group = item_group;
        }
        try self.rows.append(gpa, .{ .kind = .{ .item = i } });
    }
}

fn maxScore(a: ?i32, b: ?i32) ?i32 {
    if (a) |x| return if (b) |y| @max(x, y) else x;
    return b;
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

fn viewHeight(self: *Palette) f32 {
    return @max(0, self.popup.sizeDip().height - layout.list_top);
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

fn select(self: *Palette, row: ?usize) void {
    const r = row orelse return;
    self.selected = r;
    self.reveal(r);
    self.popup.invalidate();
    self.schedulePreview();
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

fn lastItemRow(self: *const Palette) ?usize {
    if (self.rows.items.len == 0) return null;
    return self.nextItemRow(self.rows.items.len - 1, -1);
}

/// Move the selection by about one view height.
fn page(self: *Palette, dir: i32) void {
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

/// The item row at `pos` (DIPs in the popup), if any.
fn rowAt(self: *Palette, pos: d2d.Point) ?usize {
    if (pos.y < layout.list_top or pos.x < 0 or pos.x >= self.popup.sizeDip().width) return null;
    const y = pos.y - layout.list_top + self.scroll;
    for (self.rows.items, 0..) |row, i| {
        if (y >= row.y and y < row.y + row.h) return if (row.kind == .item) i else null;
    }
    return null;
}

// -----------------------------------------------------------------------
// Running entries
// -----------------------------------------------------------------------

fn runSelected(self: *Palette) void {
    const row = self.selected orelse return;
    if (!self.isItemRow(row)) return;
    self.run(self.rows.items[row].kind.item);
}

/// Close the palette and run entry `index`.
fn run(self: *Palette, index: usize) void {
    const item = self.items.items[index];
    history.record(item.key);
    const s = self.surface();
    const window = s.parent_window;
    const app = s.app;
    // Saving a theme reloads the configuration anyway.
    if (item.target == .theme) self.endPreview(false);
    self.close(true);

    switch (item.target) {
        .command => |action| {
            if (!s.core_surface_ready) return;
            _ = s.core_surface.performBindingAction(action) catch |err| {
                log.err("palette action failed action={t} err={}", .{ action, err });
            };
        },
        .tab => |tab| if (window.findTabIndex(tab)) |i| {
            window.selectTabIndex(i);
            window.invalidateTabBar();
        },
        .profile => |id| _ = app.openProfile(window, id, .tab),
        .settings => _ = Settings.show(window),
        .language => |language| saveSetting(window, "language", language.configValue()),
        .theme => |name| saveSetting(window, "theme", name),
    }
}

/// Write `key = value` to `gui-settings.ghostty` and reload the
/// configuration, like the settings UI does.
fn saveSetting(window: *Window, key: []const u8, value: []const u8) void {
    const alloc_ = window.app.core_app.alloc;
    const path = gx.config_layers.overlayPath(alloc_) catch |err| {
        log.err("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
        return;
    };
    defer alloc_.free(path);
    var changes: gx.settings_map.Changes = .init(alloc_);
    defer changes.deinit();
    changes.set(key, value) catch return;
    changes.commit(alloc_, global.io(), path) catch |err| {
        log.err("cannot save {s} err={}", .{ path, err });
        return;
    };
    window.performBindingAction(.reload_config);
}

// -----------------------------------------------------------------------
// Theme preview
// -----------------------------------------------------------------------

/// The theme of the selected entry, if it is one other than the saved
/// theme.
fn selectedTheme(self: *Palette) ?[]const u8 {
    const row = self.selected orelse return null;
    if (!self.isItemRow(row)) return null;
    const item = &self.items.items[self.rows.items[row].kind.item];
    return switch (item.target) {
        .theme => |name| if (item.current) null else name,
        else => null,
    };
}

fn previewTheme(self: *const Palette) ?[]const u8 {
    const len = self.preview_len orelse return null;
    return self.preview_buf[0..len];
}

fn sameTheme(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Preview the selected theme in the terminals once the selection rests
/// on it, or show the saved theme again when it moved off the themes.
fn schedulePreview(self: *Palette) void {
    const hwnd = self.popup.hwnd orelse return;
    if (!self.active or sameTheme(self.selectedTheme(), self.previewTheme())) {
        _ = w32.KillTimer(hwnd, preview_timer_id);
        return;
    }
    _ = w32.SetTimer(hwnd, preview_timer_id, preview_delay_ms, @ptrCast(&previewTimer));
}

fn previewTimer(hwnd: w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w32.KillTimer(hwnd, id);
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return;
    const popup: *Popup = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const self: *Palette = @alignCast(@fieldParentPtr("popup", popup));
    if (!self.active) return;
    const theme = self.selectedTheme();
    if (sameTheme(theme, self.previewTheme())) return;
    self.applyTheme(theme);
}

/// Load the configuration with `theme` (null: as saved) and apply it to
/// the running app without saving anything, like the settings UI's theme
/// preview.
fn applyTheme(self: *Palette, theme: ?[]const u8) void {
    const app = self.surface().app;
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
    app.core_app.updateConfig(app, &config) catch |err| {
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
        self.popup.setBorderColor(self.tokens().border);
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

/// Handle a key press: navigation, running and closing, editing chords
/// for the filter and the chords bound to actions. `routed` is true when
/// the app's message loop asks first (`handleKey`) and false when the
/// popup's window procedure asks.
fn keyPress(self: *Palette, key: Popup.Key, routed: bool) bool {
    if (!self.active or key.vk == w32.VK_PROCESSKEY) return false;
    const plain = !key.ctrl and !key.alt;
    switch (key.vk) {
        w32.VK_ESCAPE => {
            self.close(true);
            return true;
        },
        w32.VK_RETURN => {
            self.runSelected();
            return true;
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
            self.page(if (key.vk == w32.VK_PRIOR) -1 else 1);
            return true;
        },
        w32.VK_HOME => if (!key.shift and !key.alt) {
            self.select(self.nextItemRow(0, 1));
            return true;
        },
        w32.VK_END => if (!key.shift and !key.alt) {
            self.select(self.lastItemRow());
            self.scrollTo(self.maxScroll());
            return true;
        },
        'P', 'N' => if (key.ctrl and !key.shift and !key.alt) {
            self.move(if (key.vk == 'P') -1 else 1);
            return true;
        },
        w32.VK_BACK => if (key.ctrl and !key.alt) {
            self.deleteWordBack();
            return true;
        },
        w32.VK_F4 => if (key.alt and !key.ctrl) {
            // Alt+F4 closes the window, not just the palette.
            const window = self.surface().parent_window;
            self.close(true);
            if (window.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
            return true;
        },
        else => {},
    }
    if (plain) return false;

    // Ctrl+A/C/V/X/Y/Z edit the filter; the app never bubbles them.
    if (key.ctrl and !key.shift and !key.alt and isEditVk(key.vk)) return false;

    const mods: input.Mods = .{ .ctrl = key.ctrl, .shift = key.shift, .alt = key.alt };
    const action = trigger.actionForKey(self.keybindSet(), key.vk, mods) orelse {
        // Unbound chords do nothing here instead of reaching the terminal.
        return true;
    };
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
            const s = self.surface();
            self.close(true);
            if (s.core_surface_ready) _ = s.core_surface.performBindingAction(action) catch |err| {
                log.err("palette chord failed action={t} err={}", .{ action, err });
            };
            return true;
        },
    }
}

fn isEditVk(vk: u16) bool {
    return switch (vk) {
        'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
}

/// Ctrl+Backspace: delete the selection, else the word before the caret.
fn deleteWordBack(self: *Palette) void {
    const in = &self.popup.input;
    var start = @min(in.anchor, in.caret);
    const end = @max(in.anchor, in.caret);
    if (start == end) {
        while (start > 0 and in.buf.items[start - 1] == ' ') start -= 1;
        while (start > 0 and in.buf.items[start - 1] != ' ') start -= 1;
    }
    if (start == end) return;
    in.buf.replaceRangeAssumeCapacity(start, end - start, &.{});
    in.caret = start;
    in.anchor = start;
    self.textChanged();
}

fn onTextChanged(ctx: *anyopaque, popup: *Popup) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    if (adoptShown(popup)) self.active = true;
    self.textChanged();
}

fn textChanged(self: *Palette) void {
    if (!self.active) return;
    self.refilter();
    self.reposition();
    self.popup.invalidate();
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    if (adoptShown(popup)) self.active = true;
    switch (event.kind) {
        .move => {
            const row = self.rowAt(event.pos);
            if (row != self.hover) {
                self.hover = row;
                popup.invalidate();
            }
        },
        .leave => if (self.hover != null) {
            self.hover = null;
            popup.invalidate();
        },
        .down => if (event.button == .left) {
            self.pressed = self.rowAt(event.pos);
        },
        .up => if (event.button == .left) {
            const row = self.rowAt(event.pos);
            const pressed = self.pressed;
            self.pressed = null;
            if (row != null and row == pressed) {
                self.selected = row;
                self.run(self.rows.items[row.?].kind.item);
            }
        },
        .double_click => {},
        .wheel => {
            self.scrollTo(self.scroll - event.wheel * layout.wheel_step);
            self.hover = self.rowAt(event.pos);
            popup.invalidate();
        },
    }
}

fn onDismissed(ctx: *anyopaque, _: *Popup, reason: Popup.DismissReason) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    self.active = false;
    self.hover = null;
    self.pressed = null;
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

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *Palette = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

    popup.drawTextInput(canvas, .{
        .x = layout.pad,
        .y = layout.pad,
        .w = size.width - 2 * layout.pad,
        .h = layout.input_height,
    }, t, i18n.tr("Type a command…"));
    canvas.fillRect(.{ .x = 0, .y = layout.list_top - 1, .w = size.width, .h = 1 }, t.border);

    const view: d2d.Rect = .{ .x = 0, .y = layout.list_top, .w = size.width, .h = @max(0, size.height - layout.list_top) };
    canvas.pushClip(view);
    defer canvas.popClip();

    if (self.rows.items.len == 0) {
        canvas.drawText(i18n.tr("No results"), view, .{
            .size = style.font_size.body,
            .color = t.text_secondary,
            .align_x = .center,
        });
        return;
    }

    const scale = popup.scale();
    const chips = trigger.ChipColors.fromTokens(t);
    for (self.rows.items, 0..) |row, i| {
        const y = snap(view.y + row.y - self.scroll, scale);
        if (y + row.h < view.y) continue;
        if (y > view.y + view.h) break;
        const rect: d2d.Rect = .{ .x = layout.pad, .y = y, .w = view.w - 2 * layout.pad, .h = row.h };
        switch (row.kind) {
            .header => |group| paintHeader(canvas, rect, group, t),
            .theme_hint => self.paintThemeHint(canvas, rect, t),
            .item => |index| self.paintItem(canvas, rect, i, &self.items.items[index], t, chips),
        }
    }
    self.paintScrollbar(canvas, view, t);
}

fn snap(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

fn paintHeader(canvas: *d2d.Canvas, rect: d2d.Rect, group: Group, t: style.Tokens) void {
    canvas.drawText(group.title(), .{ .x = rect.x + 12, .y = rect.y + 6, .w = rect.w - 24, .h = rect.h - 6 }, .{
        .size = style.font_size.caption,
        .weight = .semibold,
        .color = t.text_secondary,
    });
}

fn paintThemeHint(self: *Palette, canvas: *d2d.Canvas, rect: d2d.Rect, t: style.Tokens) void {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    i18n.format(&writer, i18n.tr("Type to search {count} themes…"), .{ .count = self.theme_count }) catch {};
    canvas.drawText(writer.buffered(), .{ .x = rect.x + layout.text_x, .y = rect.y, .w = rect.w - layout.text_x - 12, .h = rect.h }, .{
        .size = style.font_size.caption,
        .color = t.text_disabled,
    });
}

fn paintItem(
    self: *Palette,
    canvas: *d2d.Canvas,
    rect: d2d.Rect,
    row: usize,
    item: *const Item,
    t: style.Tokens,
    chips: trigger.ChipColors,
) void {
    const selected = self.selected == row;
    const fill = rect.inset(0, 1);
    if (selected) {
        canvas.fillRoundedRect(fill, layout.row_radius, style.mix(t.surface_raised, t.accent, 0.16));
        canvas.fillRoundedRect(.{ .x = fill.x, .y = fill.y + 8, .w = 2, .h = @max(0, fill.h - 16) }, 1, t.accent);
    } else if (self.hover == row) {
        canvas.fillRoundedRect(fill, layout.row_radius, t.hover);
    }

    canvas.drawIcon(item.icon, .{ .x = rect.x + 12, .y = rect.y, .w = layout.icon_size, .h = rect.h }, 14, if (selected) t.accent else t.text_secondary);

    var right = rect.x + rect.w - 10;
    if (item.shortcut) |shortcut| {
        const sequence = [_]input.Binding.Trigger{shortcut};
        const w = trigger.measureSequence(canvas, &sequence);
        if (w < rect.w / 2) {
            _ = trigger.drawSequence(canvas, &sequence, right - w, rect.y + rect.h / 2, chips);
            right -= w + 12;
        }
    }

    const x = rect.x + layout.text_x;
    const w = @max(0, right - x);
    const title_style: d2d.TextStyle = .{ .size = style.font_size.body, .color = t.text };
    if (item.description.len == 0) {
        canvas.drawText(item.title, .{ .x = x, .y = rect.y, .w = w, .h = rect.h }, title_style);
        return;
    }
    canvas.drawText(item.title, .{ .x = x, .y = rect.y + 6, .w = w, .h = 22 }, title_style);
    canvas.drawText(item.description, .{ .x = x, .y = rect.y + 27, .w = w, .h = 17 }, .{
        .size = style.font_size.caption,
        .color = if (item.current) t.accent else t.text_secondary,
    });
}

fn paintScrollbar(self: *Palette, canvas: *d2d.Canvas, view: d2d.Rect, t: style.Tokens) void {
    if (self.content_height <= view.h or view.h <= 0) return;
    const thumb_h = @max(24, view.h * view.h / self.content_height);
    const range = view.h - thumb_h;
    const y = view.y + range * (self.scroll / self.maxScroll());
    canvas.fillRoundedRect(.{ .x = view.x + view.w - 5, .y = y + 2, .w = 3, .h = thumb_h - 4 }, 1.5, t.text_disabled.withAlpha(0.6));
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

/// Destroy `popup`, or only free its resources when Windows destroyed
/// its window already (the handle may belong to another window by now).
pub fn releasePopup(popup: *Popup) void {
    if (popup.hwnd == null or popupAlive(popup)) {
        popup.destroy();
        return;
    }
    if (popup.canvas) |*canvas| canvas.deinit();
    popup.input.deinit(popup.alloc);
    popup.* = .{};
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
        if (popupAlive(popup) and popup.owner == owner and popup.options.dark == options.dark) return true;
        releasePopup(popup);
    }
    const factory = app.uiFactory() orelse return false;
    popup.create(app.hinstance, owner, factory, options, callbacks) catch |err| {
        log.warn("failed to create a popup err={}", .{err});
        return false;
    };
    return true;
}

/// The palette picks of the process, keyed by the English msgid or action
/// string of the entry. Only the GUI thread uses it.
var history: fuzzy.Frecency = .{};
