//! The keyboard shortcut sheet: a large `Popup` centered on a window that
//! lists every keybinding of the configuration by category (tabs, splits,
//! clipboard, font, windows, navigation, Ghostty GX, terminal, other), one
//! row per action with its title in the UI language, the action and the
//! keycaps of every key sequence that runs it (leader sequences as
//! `A → B`). The search input filters by title (translated or English),
//! action and keys.
//!
//! Opened by `gx:keybinds` and the main menu's Keyboard Shortcuts item
//! through `show`. The sheet of a window lives in the command palette of
//! the window's active terminal (`Palette.keybinds`), so the terminal owns
//! it. While the sheet is open a chord bound to an action closes it and
//! performs the action; the `gx:keybinds` chord just closes it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Palette = @import("Palette.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const fuzzy = @import("fuzzy.zig");
const style = @import("style.zig");
const trigger = @import("trigger.zig");

const log = std.log.scoped(.win32);
const Action = input.Binding.Action;
const Trigger = input.Binding.Trigger;

/// Show the keyboard shortcuts for `window`. Returns false if nothing was
/// shown.
pub fn show(window: *Window) bool {
    const surface = window.getActiveSurface() orelse return false;
    return surface.palette.keybinds.open();
}

/// Layout in DIPs.
const layout = struct {
    const width_max: f32 = 860;
    const width_min: f32 = 420;
    const height_max: f32 = 760;
    const height_min: f32 = 300;
    const margin: f32 = 32;
    const pad_x: f32 = 20;
    const title_y: f32 = 12;
    const title_height: f32 = 32;
    const close_size: f32 = 32;
    const input_y: f32 = 52;
    const input_height: f32 = 36;
    const list_top: f32 = input_y + input_height + 12;
    const list_pad: f32 = 6;
    const header_height: f32 = 34;
    const row_height: f32 = 34;
    const row_radius: f32 = 6;
    const sequence_gap: f32 = 12;
    const wheel_step: f32 = 3 * row_height;
};

const Category = enum {
    tabs,
    splits,
    clipboard,
    font,
    windows,
    navigation,
    gx,
    terminal,
    other,

    fn title(self: Category) [:0]const u8 {
        return switch (self) {
            .tabs => i18n.tr("Tabs"),
            .splits => i18n.tr("Splits"),
            .clipboard => i18n.tr("Clipboard and Selection"),
            .font => i18n.tr("Font Size"),
            .windows => i18n.tr("Windows"),
            .navigation => i18n.tr("Navigation"),
            .gx => i18n.tr("Ghostty GX"),
            .terminal => i18n.tr("Terminal"),
            .other => i18n.tr("Other"),
        };
    }
};

/// One action and the key sequences that run it.
const Entry = struct {
    category: Category,
    /// The actions run, in order; more than one for chained bindings.
    actions: []const Action,
    /// The key sequences, leader keys first.
    sequences: std.ArrayList([]const Trigger) = .empty,
    /// The title in the UI language and in English.
    title: []const u8 = "",
    title_en: []const u8 = "",
    /// The actions in configuration syntax, e.g. `new_split:right`.
    action_text: []const u8 = "",
    /// The formatted key sequences, for the search.
    keys_text: []const u8 = "",
};

const Row = struct {
    kind: union(enum) {
        header: Category,
        entry: usize,
    },
    y: f32 = 0,
    h: f32 = 0,
};

pub const Sheet = struct {
    popup: Popup = .{},
    /// The entries and their strings, rebuilt each time the sheet opens.
    arena: ?std.heap.ArenaAllocator = null,
    entries: std.ArrayList(Entry) = .empty,
    /// The rows on display for the current filter.
    rows: std.ArrayList(Row) = .empty,
    content_height: f32 = 0,
    scroll: f32 = 0,
    hover: ?usize = null,
    close_hover: bool = false,
    close_pressed: bool = false,

    fn palette(self: *Sheet) *Palette {
        return @alignCast(@fieldParentPtr("keybinds", self));
    }

    fn gpa(self: *Sheet) Allocator {
        return self.palette().surface().app.core_app.alloc;
    }

    fn colors(self: *Sheet) style.Tokens {
        return style.Tokens.fromConfig(&self.palette().surface().app.config);
    }

    pub fn deinit(self: *Sheet) void {
        Palette.releasePopup(&self.popup);
        self.rows.deinit(self.gpa());
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.entries = .empty;
    }

    /// Show the sheet, freshly built from the configuration.
    fn open(self: *Sheet) bool {
        const s = self.palette().surface();
        const owner = s.parent_window.hwnd orelse return false;
        const t = self.colors();
        if (!Palette.ensurePopup(&self.popup, s.app, owner, .{
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
        })) return false;
        self.popup.setBorderColor(t.border);

        self.popup.input.clear();
        self.build();
        self.refilter();
        const rect = self.bounds() orelse return false;
        self.popup.show(rect);
        return true;
    }

    /// Hide the sheet; `restore_focus` gives the keyboard back to the
    /// terminal.
    fn close(self: *Sheet, restore_focus: bool) void {
        const was_open = self.popup.visible;
        self.hover = null;
        self.close_hover = false;
        self.close_pressed = false;
        self.popup.hide();
        if (was_open and restore_focus) {
            if (self.palette().surface().hwnd) |hwnd| _ = w32.SetFocus(hwnd);
        }
    }

    /// Size the sheet for its window again (DPI change).
    pub fn reposition(self: *Sheet) void {
        if (!self.popup.visible or !Palette.popupAlive(&self.popup)) return;
        const rect = self.bounds() orelse return;
        self.popup.setBounds(rect);
    }

    /// The UI language changed: retranslate the titles.
    pub fn onLanguageChanged(self: *Sheet) void {
        if (!self.popup.visible) return;
        self.build();
        self.refilter();
        self.popup.invalidate();
    }

    /// The sheet's place in screen pixels: centered on the window below
    /// its chrome.
    fn bounds(self: *Sheet) ?w32.RECT {
        const window = self.palette().surface().parent_window;
        const hwnd = window.hwnd orelse return null;
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return null;
        const dpi = w32.GetDpiForWindow(hwnd);
        const scale = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0;
        const client_w = style.dip(client.right - client.left, scale);
        const client_h = style.dip(client.bottom - client.top, scale);
        const chrome = style.dip(window.chromeHeight(), scale);

        const width = std.math.clamp(client_w - 2 * layout.margin, layout.width_min, layout.width_max);
        const height = std.math.clamp(client_h - chrome - 2 * layout.margin, layout.height_min, layout.height_max);
        var origin: w32.POINT = .{ .x = 0, .y = 0 };
        _ = w32.ClientToScreen(hwnd, &origin);
        const left = origin.x + style.px(@max(0, (client_w - width) / 2), scale);
        const top = origin.y + style.px(chrome + @max(0, (client_h - chrome - height) / 2), scale);
        return .{
            .left = left,
            .top = top,
            .right = left + style.px(width, scale),
            .bottom = top + style.px(height, scale),
        };
    }

    // -------------------------------------------------------------------
    // Model
    // -------------------------------------------------------------------

    fn build(self: *Sheet) void {
        if (self.arena) |*arena| {
            _ = arena.reset(.retain_capacity);
        } else {
            self.arena = .init(self.gpa());
        }
        const a = self.arena.?.allocator();
        self.entries = .empty;
        const config = &self.palette().surface().app.config;
        collect(a, &self.entries, &config.keybind.set, config.@"command-palette-entry".value.items) catch |err| {
            log.warn("cannot list the keyboard shortcuts err={}", .{err});
        };
    }

    // -------------------------------------------------------------------
    // Filtering and scrolling
    // -------------------------------------------------------------------

    fn refilter(self: *Sheet) void {
        const allocator = self.gpa();
        self.rows.clearRetainingCapacity();
        self.hover = null;

        var buf: [1024]u8 = undefined;
        const text = self.popup.input.utf8Range(&buf, 0, self.popup.input.buf.items.len);
        const query: fuzzy.Query = .init(text);

        var current: ?Category = null;
        for (self.entries.items, 0..) |entry, i| {
            if (!query.isEmpty() and !entryMatches(&query, entry)) continue;
            if (current != entry.category) {
                self.rows.append(allocator, .{ .kind = .{ .header = entry.category } }) catch break;
                current = entry.category;
            }
            self.rows.append(allocator, .{ .kind = .{ .entry = i } }) catch break;
        }

        var y: f32 = layout.list_pad;
        for (self.rows.items) |*row| {
            row.y = y;
            row.h = switch (row.kind) {
                .header => layout.header_height,
                .entry => layout.row_height,
            };
            y += row.h;
        }
        self.content_height = if (self.rows.items.len == 0) 0 else y + layout.list_pad;
        self.scroll = 0;
    }

    fn viewHeight(self: *Sheet) f32 {
        return @max(0, self.popup.sizeDip().height - layout.list_top);
    }

    fn scrollTo(self: *Sheet, value: f32) void {
        const max = @max(0, self.content_height - self.viewHeight());
        self.scroll = std.math.clamp(value, 0, max);
        self.popup.invalidate();
    }

    fn rowAt(self: *Sheet, pos: d2d.Point) ?usize {
        if (pos.y < layout.list_top) return null;
        const y = pos.y - layout.list_top + self.scroll;
        for (self.rows.items, 0..) |row, i| {
            if (y >= row.y and y < row.y + row.h) return if (row.kind == .entry) i else null;
        }
        return null;
    }

    fn closeButton(self: *Sheet) d2d.Rect {
        const size = self.popup.sizeDip();
        return .{
            .x = size.width - 12 - layout.close_size,
            .y = layout.title_y,
            .w = layout.close_size,
            .h = layout.close_size,
        };
    }

    // -------------------------------------------------------------------
    // Input
    // -------------------------------------------------------------------

    fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        _ = Palette.adoptShown(popup);
        return self.keyPress(key);
    }

    fn keyPress(self: *Sheet, key: Popup.Key) bool {
        if (key.vk == w32.VK_PROCESSKEY) return false;
        const plain = !key.ctrl and !key.alt;
        const view = self.viewHeight();
        switch (key.vk) {
            w32.VK_ESCAPE => {
                self.close(true);
                return true;
            },
            w32.VK_UP, w32.VK_DOWN => if (!key.alt) {
                const dir: f32 = if (key.vk == w32.VK_UP) -1 else 1;
                self.scrollTo(self.scroll + dir * layout.row_height);
                return true;
            },
            w32.VK_PRIOR, w32.VK_NEXT => if (!key.alt) {
                const dir: f32 = if (key.vk == w32.VK_PRIOR) -1 else 1;
                self.scrollTo(self.scroll + dir * @max(layout.row_height, view - layout.row_height));
                return true;
            },
            w32.VK_HOME, w32.VK_END => if (!key.shift and !key.alt) {
                self.scrollTo(if (key.vk == w32.VK_HOME) 0 else self.content_height);
                return true;
            },
            w32.VK_F4 => if (key.alt and !key.ctrl) {
                const window = self.palette().surface().parent_window;
                self.close(true);
                if (window.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
                return true;
            },
            else => {},
        }
        if (plain) return false;
        if (key.ctrl and !key.shift and !key.alt) switch (key.vk) {
            'A', 'C', 'V', 'X', 'Y', 'Z' => return false,
            else => {},
        };

        const s = self.palette().surface();
        const mods: input.Mods = .{ .ctrl = key.ctrl, .shift = key.shift, .alt = key.alt };
        const action = trigger.actionForKey(&s.app.config.keybind.set, key.vk, mods) orelse return true;
        switch (action) {
            .gx => |g| if (g == .keybinds) {
                self.close(true);
                return true;
            },
            // Clipboard chords (e.g. Ctrl+Shift+V) edit the search.
            .copy_to_clipboard, .paste_from_clipboard, .select_all => return false,
            else => {},
        }
        self.close(true);
        if (s.core_surface_ready) _ = s.core_surface.performBindingAction(action) catch |err| {
            log.err("shortcut sheet chord failed action={t} err={}", .{ action, err });
        };
        return true;
    }

    fn onTextChanged(ctx: *anyopaque, popup: *Popup) void {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        self.refilter();
        popup.invalidate();
    }

    fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        _ = Palette.adoptShown(popup);
        const on_close = self.closeButton().contains(event.pos);
        switch (event.kind) {
            .move => {
                const row = self.rowAt(event.pos);
                if (row != self.hover or on_close != self.close_hover) {
                    self.hover = row;
                    self.close_hover = on_close;
                    popup.invalidate();
                }
            },
            .leave => {
                self.hover = null;
                self.close_hover = false;
                popup.invalidate();
            },
            .down => if (event.button == .left) {
                self.close_pressed = on_close;
                popup.invalidate();
            },
            .up => if (event.button == .left) {
                const pressed = self.close_pressed;
                self.close_pressed = false;
                if (pressed and on_close) {
                    self.close(true);
                    return;
                }
                popup.invalidate();
            },
            .double_click => {},
            .wheel => {
                self.scrollTo(self.scroll - event.wheel * layout.wheel_step);
                self.hover = self.rowAt(event.pos);
            },
        }
    }

    fn onDismissed(ctx: *anyopaque, _: *Popup, reason: Popup.DismissReason) void {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        self.hover = null;
        self.close_hover = false;
        self.close_pressed = false;
        if (reason == .escape or reason == .owner) {
            if (self.palette().surface().hwnd) |hwnd| _ = w32.SetFocus(hwnd);
        }
    }

    fn onPopupDpiChanged(ctx: *anyopaque, _: *Popup) void {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        self.reposition();
    }

    // -------------------------------------------------------------------
    // Painting
    // -------------------------------------------------------------------

    fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        const t = self.colors();
        const size = popup.sizeDip();
        canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

        // Title and close button.
        canvas.drawIcon(d2d.icons.keyboard, .{ .x = layout.pad_x, .y = layout.title_y, .w = 20, .h = layout.title_height }, 18, t.accent);
        canvas.drawText(i18n.tr("Keyboard Shortcuts"), .{
            .x = layout.pad_x + 30,
            .y = layout.title_y,
            .w = size.width - 2 * layout.pad_x - 30 - layout.close_size,
            .h = layout.title_height,
        }, .{ .size = style.font_size.subtitle, .weight = .semibold, .color = t.text });
        const close_rect = self.closeButton();
        if (self.close_pressed and self.close_hover) {
            canvas.fillRoundedRect(close_rect, layout.row_radius, t.pressed);
        } else if (self.close_hover) {
            canvas.fillRoundedRect(close_rect, layout.row_radius, t.hover);
        }
        canvas.drawIcon(d2d.icons.cancel, close_rect, 12, t.text_secondary);

        popup.drawTextInput(canvas, .{
            .x = layout.pad_x,
            .y = layout.input_y,
            .w = size.width - 2 * layout.pad_x,
            .h = layout.input_height,
        }, t, i18n.tr("Search keyboard shortcuts…"));
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
            const y = @round((view.y + row.y - self.scroll) * scale) / scale;
            if (y + row.h < view.y) continue;
            if (y > view.y + view.h) break;
            const rect: d2d.Rect = .{ .x = 12, .y = y, .w = view.w - 24, .h = row.h };
            switch (row.kind) {
                .header => |group| canvas.drawText(group.title(), .{
                    .x = rect.x + 8,
                    .y = rect.y + 10,
                    .w = rect.w - 16,
                    .h = rect.h - 10,
                }, .{ .size = style.font_size.caption, .weight = .semibold, .color = t.text_secondary }),
                .entry => |index| self.paintEntry(canvas, rect, i, &self.entries.items[index], t, chips),
            }
        }

        // Scroll position.
        if (self.content_height > view.h and view.h > 0) {
            const thumb_h = @max(24, view.h * view.h / self.content_height);
            const max_scroll = self.content_height - view.h;
            const thumb_y = view.y + (view.h - thumb_h) * (self.scroll / max_scroll);
            canvas.fillRoundedRect(.{ .x = view.w - 6, .y = thumb_y + 2, .w = 3, .h = thumb_h - 4 }, 1.5, t.text_disabled.withAlpha(0.6));
        }
    }

    fn paintEntry(
        self: *Sheet,
        canvas: *d2d.Canvas,
        rect: d2d.Rect,
        row: usize,
        entry: *const Entry,
        t: style.Tokens,
        chips: trigger.ChipColors,
    ) void {
        if (self.hover == row) canvas.fillRoundedRect(rect.inset(0, 1), layout.row_radius, t.hover);

        // Keycaps, right-aligned; sequences that do not fit are counted.
        const title_w = @min(rect.w * 0.42, 340);
        const min_x = rect.x + 8 + title_w + 8;
        var right = rect.x + rect.w - 8;
        var shown: usize = 0;
        for (entry.sequences.items) |sequence| {
            const w = trigger.measureSequence(canvas, sequence);
            const x = right - w - (if (shown > 0) layout.sequence_gap else 0);
            if (x < min_x) break;
            right = x;
            _ = trigger.drawSequence(canvas, sequence, x, rect.y + rect.h / 2, chips);
            shown += 1;
        }
        // Drawn right to left: the first sequence ends up rightmost.
        if (shown < entry.sequences.items.len) {
            var buf: [16]u8 = undefined;
            const more = std.fmt.bufPrint(&buf, "+{d}", .{entry.sequences.items.len - shown}) catch "";
            const w: f32 = 28;
            canvas.drawText(more, .{ .x = right - w - 4, .y = rect.y, .w = w, .h = rect.h }, .{
                .size = style.font_size.caption,
                .color = t.text_disabled,
                .align_x = .trailing,
            });
            right -= w + 4;
        }

        canvas.drawText(entry.title, .{ .x = rect.x + 8, .y = rect.y, .w = title_w, .h = rect.h }, .{
            .size = style.font_size.body,
            .color = t.text,
        });
        const action_x = rect.x + 8 + title_w + 8;
        canvas.drawText(entry.action_text, .{ .x = action_x, .y = rect.y, .w = @max(0, right - action_x - 12), .h = rect.h }, .{
            .size = style.font_size.caption,
            .color = t.text_disabled,
        });
    }
};

fn entryMatches(query: *const fuzzy.Query, entry: Entry) bool {
    return fuzzy.matches(query, entry.title) or
        fuzzy.matches(query, entry.title_en) or
        fuzzy.matches(query, entry.action_text) or
        fuzzy.matches(query, entry.keys_text);
}

// -----------------------------------------------------------------------
// Collecting the bindings
// -----------------------------------------------------------------------

/// Collect one entry per action bound in `set` (leader sequences
/// included; `ignore`, `unbind` and catch-all bindings left out), ordered
/// by category and then by binding order. `commands` (the configured
/// palette entries) name actions the built-in tables do not know. All
/// memory comes from `a`.
fn collect(
    a: Allocator,
    entries: *std.ArrayList(Entry),
    set: *const input.Binding.Set,
    commands: []const input.Command,
) !void {
    try walk(a, entries, set, &.{});
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
            return @intFromEnum(lhs.category) < @intFromEnum(rhs.category);
        }
    }.lessThan);

    for (entries.items) |*entry| {
        // Single keys before sequences.
        std.mem.sort([]const Trigger, entry.sequences.items, {}, struct {
            fn lessThan(_: void, lhs: []const Trigger, rhs: []const Trigger) bool {
                return lhs.len < rhs.len;
            }
        }.lessThan);
        try describe(a, entry, commands);
    }
}

fn walk(
    a: Allocator,
    entries: *std.ArrayList(Entry),
    set: *const input.Binding.Set,
    prefix: []const Trigger,
) Allocator.Error!void {
    var it = set.bindings.iterator();
    while (it.next()) |binding| {
        const key = binding.key_ptr.*;
        if (key.key == .catch_all) continue;
        const sequence = try std.mem.concat(a, Trigger, &.{ prefix, &.{key} });
        switch (binding.value_ptr.*) {
            .leader => |next| try walk(a, entries, next, sequence),
            .leaf => |leaf| try add(a, entries, &.{leaf.action}, sequence),
            .leaf_chained => |chained| try add(a, entries, chained.actions.items, sequence),
        }
    }
}

fn add(
    a: Allocator,
    entries: *std.ArrayList(Entry),
    actions: []const Action,
    sequence: []const Trigger,
) Allocator.Error!void {
    if (actions.len == 0) return;
    switch (actions[0]) {
        .ignore, .unbind => return,
        else => {},
    }
    for (entries.items) |*entry| {
        if (sameActions(entry.actions, actions)) {
            try entry.sequences.append(a, sequence);
            return;
        }
    }
    // Copied: a configuration reload frees the originals.
    const copies = try a.alloc(Action, actions.len);
    for (actions, copies) |action, *copy| copy.* = try action.clone(a);
    var entry: Entry = .{ .category = category(actions[0]), .actions = copies };
    try entry.sequences.append(a, sequence);
    try entries.append(a, entry);
}

fn sameActions(lhs: []const Action, rhs: []const Action) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |x, y| if (!x.equal(y)) return false;
    return true;
}

/// Fill in the titles and search texts of `entry`.
fn describe(a: Allocator, entry: *Entry, commands: []const input.Command) !void {
    var titles: std.ArrayList(u8) = .empty;
    var titles_en: std.ArrayList(u8) = .empty;
    var actions: std.ArrayList(u8) = .empty;
    for (entry.actions, 0..) |action, i| {
        if (i > 0) {
            try titles.appendSlice(a, ", ");
            try titles_en.appendSlice(a, ", ");
            try actions.appendSlice(a, ", ");
        }
        const formatted = try std.fmt.allocPrint(a, "{f}", .{action});
        try actions.appendSlice(a, formatted);

        const named = title(action, commands);
        const msgid: []const u8 = if (named) |n| n.msgid else formatted;
        try titles.appendSlice(a, if (named) |n| i18n.trRuntime(n.msgid) else formatted);
        try titles_en.appendSlice(a, msgid);
        if (named) |n| if (!n.exact) {
            if (argument(action, formatted)) |arg| {
                try titles.print(a, " ({s})", .{arg});
                try titles_en.print(a, " ({s})", .{arg});
            }
        };
    }
    entry.title = titles.items;
    entry.title_en = titles_en.items;
    entry.action_text = actions.items;

    var keys: std.ArrayList(u8) = .empty;
    for (entry.sequences.items) |sequence| {
        var buf: [128]u8 = undefined;
        try keys.appendSlice(a, trigger.formatSequence(sequence, &buf));
        try keys.appendSlice(a, "  ");
    }
    entry.keys_text = keys.items;
}

const Title = struct {
    msgid: [:0]const u8,
    /// The title names this exact action, including its argument.
    exact: bool,
};

/// The msgid of the title of `action`: the title of an equal configured
/// or default command palette entry, else of the only default entry with
/// the same action name, else a title for the action name. Null when
/// there is none; the action itself is shown then.
fn title(action: Action, commands: []const input.Command) ?Title {
    for (commands) |command| {
        if (command.action.equal(action)) return .{ .msgid = command.title, .exact = true };
    }
    for (input.command.defaults) |command| {
        if (command.action.equal(action)) return .{ .msgid = command.title, .exact = true };
    }

    const tag = std.meta.activeTag(action);
    var same_name: ?[:0]const u8 = null;
    var count: usize = 0;
    for (input.command.defaults) |command| {
        if (std.meta.activeTag(command.action) != tag) continue;
        same_name = command.title;
        count += 1;
    }
    if (count == 1) return .{ .msgid = same_name.?, .exact = false };

    if (action == .gx) return .{ .msgid = switch (action.gx) {
        .settings => "Settings…",
        .main_menu => "Main Menu",
        .keybinds => "Keyboard Shortcuts",
        .new_tab_profile => "New Tab with Profile",
        .new_window_profile => "New Window with Profile",
    }, .exact = false };
    const msgid = fallback_titles.get(@tagName(tag)) orelse return null;
    return .{ .msgid = msgid, .exact = false };
}

/// The argument of an action in configuration syntax (after the first
/// colon; for `gx:` actions after the GX action name), if any.
fn argument(action: Action, formatted: []const u8) ?[]const u8 {
    if (action == .gx) return switch (action.gx) {
        .new_tab_profile, .new_window_profile => |id| id,
        else => null,
    };
    const colon = std.mem.indexOfScalar(u8, formatted, ':') orelse return null;
    const arg = formatted[colon + 1 ..];
    return if (arg.len == 0) null else arg;
}

const fallback_titles: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "previous_tab", "Previous Tab" },
    .{ "next_tab", "Next Tab" },
    .{ "last_tab", "Last Tab" },
    .{ "goto_tab", "Go to Tab" },
    .{ "new_split", "New Split" },
    .{ "resize_split", "Resize Split" },
    .{ "adjust_selection", "Adjust Selection" },
    .{ "jump_to_prompt", "Jump to Prompt" },
    .{ "scroll_page_lines", "Scroll Lines" },
    .{ "toggle_command_palette", "Command Palette" },
    .{ "toggle_quick_terminal", "Quick Terminal" },
    .{ "write_screen_file", "Write Screen to File" },
    .{ "write_selection_file", "Write Selection to File" },
    .{ "write_scrollback_file", "Write Scrollback to File" },
    .{ "text", "Send Text" },
    .{ "csi", "Send Control Sequence" },
    .{ "esc", "Send Escape Sequence" },
});

/// The category of an action, by its tag name so that actions added later
/// fall into `other` instead of breaking the build.
fn category(action: Action) Category {
    return categories.get(@tagName(std.meta.activeTag(action))) orelse .other;
}

const categories: std.StaticStringMap(Category) = .initComptime(.{
    .{ "new_tab", .tabs },
    .{ "previous_tab", .tabs },
    .{ "next_tab", .tabs },
    .{ "last_tab", .tabs },
    .{ "goto_tab", .tabs },
    .{ "move_tab", .tabs },
    .{ "move_tab_to_new_window", .tabs },
    .{ "toggle_tab_overview", .tabs },
    .{ "close_tab", .tabs },
    .{ "prompt_tab_title", .tabs },
    .{ "set_tab_title", .tabs },
    .{ "new_split", .splits },
    .{ "goto_split", .splits },
    .{ "toggle_split_zoom", .splits },
    .{ "resize_split", .splits },
    .{ "equalize_splits", .splits },
    .{ "close_surface", .splits },
    .{ "prompt_surface_title", .splits },
    .{ "set_surface_title", .splits },
    .{ "copy_to_clipboard", .clipboard },
    .{ "paste_from_clipboard", .clipboard },
    .{ "paste_from_selection", .clipboard },
    .{ "copy_url_to_clipboard", .clipboard },
    .{ "copy_title_to_clipboard", .clipboard },
    .{ "select_all", .clipboard },
    .{ "adjust_selection", .clipboard },
    .{ "write_screen_file", .clipboard },
    .{ "write_selection_file", .clipboard },
    .{ "write_scrollback_file", .clipboard },
    .{ "increase_font_size", .font },
    .{ "decrease_font_size", .font },
    .{ "reset_font_size", .font },
    .{ "set_font_size", .font },
    .{ "new_window", .windows },
    .{ "goto_window", .windows },
    .{ "close_window", .windows },
    .{ "close_all_windows", .windows },
    .{ "toggle_maximize", .windows },
    .{ "toggle_fullscreen", .windows },
    .{ "toggle_window_decorations", .windows },
    .{ "toggle_window_float_on_top", .windows },
    .{ "toggle_background_opacity", .windows },
    .{ "toggle_visibility", .windows },
    .{ "toggle_quick_terminal", .windows },
    .{ "reset_window_size", .windows },
    .{ "prompt_window_title", .windows },
    .{ "set_window_title", .windows },
    .{ "quit", .windows },
    .{ "scroll_to_top", .navigation },
    .{ "scroll_to_bottom", .navigation },
    .{ "scroll_to_selection", .navigation },
    .{ "scroll_to_row", .navigation },
    .{ "scroll_page_up", .navigation },
    .{ "scroll_page_down", .navigation },
    .{ "scroll_page_fractional", .navigation },
    .{ "scroll_page_lines", .navigation },
    .{ "jump_to_prompt", .navigation },
    .{ "search", .navigation },
    .{ "search_selection", .navigation },
    .{ "navigate_search", .navigation },
    .{ "start_search", .navigation },
    .{ "end_search", .navigation },
    .{ "gx", .gx },
    .{ "toggle_command_palette", .gx },
    .{ "open_config", .gx },
    .{ "reload_config", .gx },
    .{ "inspector", .gx },
    .{ "check_for_updates", .gx },
    .{ "reset", .terminal },
    .{ "clear_screen", .terminal },
    .{ "text", .terminal },
    .{ "csi", .terminal },
    .{ "esc", .terminal },
    .{ "cursor_key", .terminal },
    .{ "toggle_readonly", .terminal },
    .{ "toggle_mouse_reporting", .terminal },
    .{ "toggle_secure_input", .terminal },
    .{ "undo", .terminal },
    .{ "redo", .terminal },
});
