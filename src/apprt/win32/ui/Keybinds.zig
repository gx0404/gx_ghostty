//! The keyboard shortcut sheet: a large `Popup` centered on a window that
//! lists every keybinding of the configuration (`gx.shortcuts`) by
//! category in a fixed order, one row per action with its title in the UI
//! language, the action and the keycaps of every key sequence that runs it
//! (leader sequences as `A → B`, keys without a name such as media keys
//! last).
//!
//! The search field filters by title (translated or English), action and
//! keys (`gx.shortcuts.Search`): a query written as keys (`ctrl+t`) matches
//! only those keys, and the rows of a category are ordered by score. Alt+K
//! or the Record Keys button records the keys pressed next into the field
//! as such a query (`"Ctrl+Shift+T"`); after a leader key the next key goes
//! on with its sequence; Escape or Alt+K stops recording.
//!
//! Rows can be selected (Up, Down, Page Up, Page Down, Ctrl+Home, Ctrl+End
//! or a click); Enter or a double click closes the sheet and performs the
//! row's actions. Any other chord bound to an action closes the sheet and
//! performs it, the `gx:keybinds` chord just closes it; Home, End and the
//! editing chords stay with the search field.
//!
//! A key sequence whose first chord another program or the input method
//! takes (`App.shortcut_conflicts`) has a warning marker, its row names
//! the taken keys on a second line, and a note at the top of the list
//! explains each reason once.
//!
//! Opened by `gx:keybinds`, the main menu's Keyboard Shortcuts item and the
//! shortcut notice through `show`. The sheet of a window lives in the
//! command palette of the window's active terminal (`Palette.keybinds`), so
//! the terminal owns it. It lays out at the window's content scale
//! (`Window.scale`) and keeps the window painted as active
//! (`Popup.Options.keep_owner_active`). The keycaps are measured once when
//! the sheet opens and their text layouts are kept (`KeycapCache`), so
//! hovering and scrolling reuse their layouts.
//!
//! While a screen reader runs (`SPI_GETSCREENREADER`, or
//! `GHOSTTY_GX_A11Y=screen-reader` for testing), or when Direct2D is not
//! available, a native TaskDialogIndirect lists and copies the shortcuts;
//! Windows keeps it inside its monitor's work area and scrolls a long
//! list. It is posted through `List` so its modal loop never runs in a core
//! callback; its text is copied before the loop. If the API is unavailable,
//! `List` shows a read-only edit control in the system colors instead.
//! Escape closes either native view.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../../global.zig");
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const shortcuts = gx.shortcuts;
const ui_color = gx.ui_color;
const contrast_floor = gx.ui_tokens.floor;
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const Pane = @import("../Pane.zig");
const ui_ref = @import("../../../gx/ui_ref.zig");
const Window = @import("../Window.zig");
const clipboard = @import("../clipboard.zig");
const shortcut_conflicts = @import("../shortcut_conflicts.zig");
const w32 = @import("../win32.zig");
const Palette = @import("Palette.zig");
const Popup = @import("Popup.zig");
const controls = @import("controls.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);
const Binding = input.Binding;
const Action = Binding.Action;
const Trigger = Binding.Trigger;
const Reason = shortcut_conflicts.Reason;

/// Show the keyboard shortcuts for `window`. Returns false if nothing was
/// shown.
pub fn show(window: *Window) bool {
    const pane = window.activePane() orelse return false;
    switch (pane.backend) {
        .remote => |remote| if (!remote.ui.keybind_ready) {
            remote.ui.requestKeybinds(remote) catch return false;
            return false;
        },
        .local => {},
    }
    return window.palette.keybinds.open();
}
/// Local callers share the window-owned sheet with remote panes.
pub fn showLocal(surface: *Surface) bool {
    return show(surface.parent_window);
}

/// Layout in DIPs.
const layout = struct {
    const width_max: f32 = 860;
    const width_min: f32 = 420;
    const height_max: f32 = 760;
    const height_min: f32 = 300;
    /// Room around the sheet inside the window.
    const margin: f32 = 32;
    const pad_x: f32 = style.space.xl;
    const title_y: f32 = style.space.l;
    const title_height: f32 = 32;
    const input_y: f32 = title_y + title_height + style.space.m;
    const input_height: f32 = style.control.height;
    const list_top: f32 = input_y + input_height + style.space.l;
    /// The rows' inset from the sides of the sheet; the scroll indicator
    /// takes the right one.
    const list_x: f32 = controls.ScrollIndicator.hit_width;
    const list_pad: f32 = style.space.s;
    const header_height: f32 = style.row.header;
    const row_height: f32 = style.row.list;
    /// A row with a second line that names the keys another program or
    /// the input method takes.
    const conflict_row_height: f32 = style.row.two_line;
    /// Text and keycaps from the sides of a row.
    const row_pad: f32 = style.space.m;
    const marker_size: f32 = style.icon.standard;
    const sequence_gap: f32 = style.space.m;
    const notice_pad: f32 = style.space.m;
    const notice_gap: f32 = style.space.s;
    const wheel_step: f32 = 3 * row_height;
};

/// Keycap metrics in DIPs, as the shortcut chips of the menus and the
/// command palette.
const keycap = struct {
    const height: f32 = controls.keycap_height;
    const padding: f32 = 6;
    const gap: f32 = 4;
    const step_gap: f32 = 5;
    const arrow = "\u{2192}";
};

/// The note at the top of the list that explains why the keys marked
/// with a warning never reach Ghostty GX.
fn noticeText(reason: Reason) [:0]const u8 {
    return switch (reason) {
        .hotkey => i18n.tr("Global hotkeys of other programs: Windows gives these keys to the program that registered them, so Ghostty GX does not receive them."),
        .ime => i18n.tr("Kept by the input method: Ghostty GX does not receive these keys while the input method is on."),
    };
}

/// The second line of a row whose keys never reach Ghostty GX: the keys
/// and, in short, why.
fn conflictTemplate(reason: Reason) [:0]const u8 {
    return switch (reason) {
        .hotkey => i18n.tr("{keys}: global hotkey of another program"),
        .ime => i18n.tr("{keys}: kept by the input method"),
    };
}

/// One row of bindings: an action, or a chain of actions, with every key
/// sequence that runs it.
const Entry = struct {
    category: shortcuts.Category,
    /// The actions run, in order; more than one for chained bindings.
    actions: []const Action,
    /// The key sequences, leader keys first, in display order: those
    /// whose keys all have a name first, otherwise as `gx.shortcuts` orders
    /// them.
    sequences: []const []const Trigger,
    /// The width of the keycaps of each sequence, measured when the sheet
    /// opens (`Sheet.measure`); empty until then.
    widths: []f32 = &.{},
    /// The title in the UI language and in English.
    title: []const u8 = "",
    title_en: []const u8 = "",
    /// The actions in configuration syntax, e.g. `new_split:right`.
    action_text: []const u8 = "",
    /// Why the first sequence that never reaches Ghostty GX does not, and
    /// the second line that names the keys taken for that reason.
    conflict: ?Reason = null,
    conflict_note: []const u8 = "",
};

/// A row of the list as shown for the current search.
const Row = struct {
    kind: union(enum) {
        /// Why keys never reach Ghostty GX, once at the top of the list
        /// when a row on display has such keys.
        notice: Reason,
        header: shortcuts.Category,
        /// An index into `Sheet.entries`.
        entry: usize,
    },
    y: f32 = 0,
    h: f32 = 0,
};

/// An entry that matches the search, with its score.
const Match = struct {
    entry: u32,
    score: i32,
};

/// Keys pressed while recording, which make the search.
const Recording = struct {
    active: bool = false,
    presses: [max_steps]Press = undefined,
    len: usize = 0,

    /// As many steps as a key query reads.
    const max_steps = 4;

    const Press = struct {
        vk: u16,
        mods: input.Mods,
    };

    /// Whether the presses so far are leader keys in `set`, so that the
    /// next press goes on with their sequence.
    fn continues(self: *const Recording, set: *const Binding.Set) bool {
        if (self.len == 0 or self.len >= max_steps) return false;
        var current = set;
        for (self.presses[0..self.len]) |press| {
            const value = bindingForKey(current, press.vk, press.mods) orelse return false;
            switch (value.*) {
                .leader => |next| current = next,
                .leaf, .leaf_chained => return false,
            }
        }
        return true;
    }

    /// Add a press: the next step of a sequence, or the start of a new
    /// search.
    fn add(self: *Recording, set: *const Binding.Set, press: Press) void {
        if (!self.continues(set)) self.len = 0;
        self.presses[self.len] = press;
        self.len += 1;
    }

    /// The search for the presses, a quoted key query (`"Ctrl+A>N"`).
    fn query(self: *const Recording, buf: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        writer.writeByte('"') catch {};
        for (self.presses[0..self.len], 0..) |press, i| {
            if (i > 0) writer.writeByte('>') catch {};
            var name_buf: [4]u8 = undefined;
            const name = keyName(physicalKey(press.vk), layoutChar(press.vk), &name_buf) orelse "";
            writeChord(&writer, press.mods, name) catch {};
        }
        writer.writeByte('"') catch {};
        return writer.buffered();
    }
};

/// The text layouts of the keycap labels and the sequence arrow, kept
/// while the sheet exists: about 40 labels serve every row.
const KeycapCache = struct {
    caps: std.StringHashMapUnmanaged(Cap) = .empty,
    /// Text layouts created so far, for the performance log.
    created: usize = 0,

    const Cap = struct {
        layout: d2d.TextLayout,
        /// The width of the label, and of its keycap.
        text_w: f32,
        width: f32,
    };

    const text_style: d2d.TextStyle = .{
        .size = style.font_size.caption,
        .align_x = .leading,
        .align_y = .center,
        .ellipsis = false,
    };

    fn deinit(self: *KeycapCache, alloc: Allocator) void {
        var it = self.caps.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.layout.deinit();
        }
        self.caps.deinit(alloc);
        self.* = .{};
    }

    /// The keycap for `label`, laid out on first use; valid until the next
    /// `get`.
    fn get(self: *KeycapCache, alloc: Allocator, factory: *d2d.Factory, label: []const u8) ?*const Cap {
        if (self.caps.getPtr(label)) |cap| return cap;
        var text = d2d.TextLayout.initUtf8(factory, label, text_style, 1000, keycap.height) orelse return null;
        const text_w = text.size().width;
        const owned = alloc.dupe(u8, label) catch {
            text.deinit();
            return null;
        };
        self.caps.put(alloc, owned, .{ .layout = text, .text_w = text_w, .width = capWidth(text_w) }) catch {
            alloc.free(owned);
            text.deinit();
            return null;
        };
        self.created += 1;
        return self.caps.getPtr(owned);
    }
};

/// The width of a keycap for a label `text_w` wide.
fn capWidth(text_w: f32) f32 {
    return @max(keycap.height, @ceil(text_w) + 2 * keycap.padding);
}

const ChipColors = struct {
    fill: d2d.Color,
    border: d2d.Color,
    text: d2d.Color,
    /// The arrow between the steps of a sequence.
    arrow: d2d.Color,

    fn fromTokens(t: style.Tokens) ChipColors {
        const fill = style.mix(t.surface_raised, t.foreground, 0.07);
        return .{
            .fill = fill,
            .border = t.border,
            .text = ui_color.ensureContrast(t.text_secondary, fill, contrast_floor.text),
            .arrow = t.text_tertiary,
        };
    }
};

pub const Sheet = struct {
    popup: Popup = .{},
    /// The entries and their strings, rebuilt each time the sheet opens.
    arena: ?std.heap.ArenaAllocator = null,
    entries: std.ArrayList(Entry) = .empty,
    /// Whether the entries have their keycap widths.
    measured: bool = false,
    /// The entries that match the search, and the rows on display.
    matches: std.ArrayList(Match) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// The width the rows were laid out for; 0 to lay them out again.
    layout_width: f32 = 0,
    content_height: f32 = 0,
    scroll: f32 = 0,
    /// Row indices (entry rows only).
    selected: ?usize = null,
    hover: ?usize = null,
    close_hover: bool = false,
    close_pressed: bool = false,
    record_hover: bool = false,
    record_pressed: bool = false,
    /// The width of the Record Keys button as last painted.
    record_width: f32 = 0,
    scrollbar: controls.ScrollIndicator = .{},
    recording: Recording = .{},
    keycaps: KeycapCache = .{},
    /// The native window that stands in for the sheet (see the file
    /// header).
    list: List = .{},

    fn palette(self: *Sheet) *Palette {
        return @alignCast(@fieldParentPtr("keybinds", self));
    }

    fn paneView(self: *Sheet) Pane {
        return self.palette().paneView();
    }

    fn app(self: *Sheet) *App {
        return self.palette().ownerWindow().app;
    }

    fn gpa(self: *Sheet) Allocator {
        return self.app().core_app.alloc;
    }

    fn colors(self: *Sheet) style.Tokens {
        return style.Tokens.fromConfig(&self.app().config);
    }

    pub fn deinit(self: *Sheet) void {
        self.list.destroy();
        Palette.releasePopup(&self.popup);
        const alloc = self.gpa();
        self.rows.deinit(alloc);
        self.rows = .empty;
        self.matches.deinit(alloc);
        self.matches = .empty;
        self.keycaps.deinit(alloc);
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.entries = .empty;
        self.measured = false;
    }

    /// Show the sheet, freshly built from the configuration: the popup, or
    /// the native list for a screen reader, without Direct2D, or while the
    /// list is open.
    fn open(self: *Sheet) bool {
        if (self.list.hwnd != null or screenReaderRunning()) return self.openList(true);
        const pane = self.paneView();
        const window = pane.ownerWindow();
        const owner = window.hwnd orelse return false;
        const t = self.colors();
        if (!Palette.ensurePopup(&self.popup, pane.app(), owner, popupOptions(t), .{
            .ctx = self,
            .paint = paint,
            .key = onKey,
            .mouse = onMouse,
            .text_changed = onTextChanged,
            .dismissed = onDismissed,
            .dpi_changed = onPopupDpiChanged,
        })) return self.openList(true);
        self.popup.setBorderColor(t.border);
        self.popup.setAccessibleName(i18n.tr("Keyboard Shortcuts"));

        self.endInteraction();
        self.popup.input.clear();
        // Sized before the rows are laid out for its width.
        const rect = self.bounds() orelse return false;
        self.popup.setBounds(rect);
        self.build();
        self.refilter();
        self.popup.show(rect);
        return true;
    }

    /// Hide the sheet; `restore_focus` gives the keyboard back to the
    /// terminal.
    fn close(self: *Sheet, restore_focus: bool) void {
        const was_open = self.popup.visible;
        self.endInteraction();
        self.popup.hide();
        if (was_open and restore_focus) {
            self.paneView().focus();
        }
    }

    /// Stop recording, dragging, hovering and pressing.
    fn endInteraction(self: *Sheet) void {
        self.setRecording(false);
        self.endDrag();
        self.hover = null;
        self.close_hover = false;
        self.close_pressed = false;
        self.record_hover = false;
        self.record_pressed = false;
        self.scrollbar.hover = false;
    }

    /// Size the sheet for its window again (DPI change).
    pub fn reposition(self: *Sheet) void {
        if (!self.popup.visible or !Palette.popupAlive(&self.popup)) return;
        const rect = self.bounds() orelse return;
        self.popup.setBounds(rect);
    }

    /// The UI language changed: retranslate the titles.
    pub fn onLanguageChanged(self: *Sheet) void {
        if (self.list.hwnd != null) _ = self.openList(false);
        if (!self.popup.visible) return;
        self.popup.setAccessibleName(i18n.tr("Keyboard Shortcuts"));
        self.build();
        self.refilter();
        self.popup.invalidate();
    }

    /// The sheet's place in screen pixels: centered on the window below its
    /// chrome, at the window's content scale.
    fn bounds(self: *Sheet) ?w32.RECT {
        const window = self.paneView().ownerWindow();
        const hwnd = window.hwnd orelse return null;
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return null;
        self.popup.setOwnerScale(window.scale);
        const rect = placement(client.right - client.left, client.bottom - client.top, window.chromeHeight(), self.popup.ownerScale());
        var origin: w32.POINT = .{ .x = 0, .y = 0 };
        _ = w32.ClientToScreen(hwnd, &origin);
        return .{
            .left = origin.x + rect.left,
            .top = origin.y + rect.top,
            .right = origin.x + rect.right,
            .bottom = origin.y + rect.bottom,
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
        self.measured = false;
        const config = &self.app().config;
        collect(
            a,
            &self.entries,
            self.palette().keybindSet(),
            config.@"command-palette-entry".value.items,
            &self.app().shortcut_conflicts,
        ) catch |err| {
            log.warn("cannot list the keyboard shortcuts err={}", .{err});
        };
    }

    /// Measure the keycaps of every entry once.
    fn measure(self: *Sheet, factory: *d2d.Factory) void {
        if (self.measured) return;
        const arena = if (self.arena) |*arena| arena else return;
        self.measured = true;
        const a = arena.allocator();
        for (self.entries.items) |*entry| {
            const widths = a.alloc(f32, entry.sequences.len) catch return;
            for (entry.sequences, widths) |sequence, *width| width.* = self.sequenceWidth(factory, sequence);
            entry.widths = widths;
        }
    }

    /// The width of the keycaps of a key sequence.
    fn sequenceWidth(self: *Sheet, factory: *d2d.Factory, sequence: []const Trigger) f32 {
        const alloc = self.gpa();
        var width: f32 = 0;
        for (sequence, 0..) |step_trigger, step| {
            if (step > 0) {
                const arrow_w = if (self.keycaps.get(alloc, factory, keycap.arrow)) |cap| @ceil(cap.text_w) else 0;
                width += 2 * keycap.step_gap + arrow_w;
            }
            const caps: shortcuts.Keycaps = .init(step_trigger, .windows);
            for (0..caps.count()) |i| {
                if (i > 0) width += keycap.gap;
                width += if (self.keycaps.get(alloc, factory, caps.get(i))) |cap| cap.width else keycap.height;
            }
        }
        return width;
    }

    // -------------------------------------------------------------------
    // Filtering, selection and scrolling
    // -------------------------------------------------------------------

    fn refilter(self: *Sheet) void {
        const alloc = self.gpa();
        var buf: [1024]u8 = undefined;
        const text = self.popup.input.utf8Range(&buf, 0, self.popup.input.buf.items.len);
        const search: shortcuts.Search = .init(text);
        rank(alloc, &self.matches, self.entries.items, &search) catch |err| {
            log.warn("cannot search the keyboard shortcuts err={}", .{err});
            self.matches.clearRetainingCapacity();
        };
        listRows(alloc, &self.rows, self.entries.items, self.matches.items) catch |err| {
            log.warn("cannot list the keyboard shortcuts err={}", .{err});
            self.rows.clearRetainingCapacity();
        };
        self.layout_width = 0;
        self.scroll = 0;
        self.hover = null;
        // A search selects its best match, so Enter runs it.
        self.selected = if (search.isEmpty()) null else firstEntry(self.rows.items);
        self.ensureLayout();
        self.refreshHover();
    }

    /// Lay the rows out for the sheet's width when it changed.
    fn ensureLayout(self: *Sheet) void {
        const width = self.popup.sizeDip().width;
        if (width <= 0 or width == self.layout_width) return;
        var heights = std.EnumArray(Reason, f32).initFill(layout.row_height + layout.notice_gap);
        if (self.app().uiFactory()) |factory| {
            for (std.enums.values(Reason)) |reason| heights.set(reason, noticeHeight(factory, reason, width));
        }
        self.content_height = placeRows(self.rows.items, self.entries.items, heights);
        self.layout_width = width;
        self.scroll = self.clampedScroll(self.scroll);
    }

    /// The list below the search field (DIPs).
    fn listView(self: *Sheet) d2d.Rect {
        const size = self.popup.sizeDip();
        return .{ .x = 0, .y = layout.list_top, .w = size.width, .h = @max(0, size.height - layout.list_top) };
    }

    fn viewHeight(self: *Sheet) f32 {
        return self.listView().h;
    }

    fn clampedScroll(self: *Sheet, value: f32) f32 {
        const max = @max(0, self.content_height - self.viewHeight());
        return std.math.clamp(value, 0, max);
    }

    fn scrollTo(self: *Sheet, value: f32) void {
        const scroll = self.clampedScroll(value);
        if (scroll == self.scroll) return;
        self.scroll = scroll;
        self.popup.invalidate();
    }

    /// Select entry row `row` and scroll it into view.
    fn select(self: *Sheet, row: usize) void {
        self.ensureLayout();
        if (row >= self.rows.items.len) return;
        self.selected = row;
        self.scroll = self.clampedScroll(revealScroll(self.rows.items, row, self.scroll, self.viewHeight()));
        self.refreshHover();
        self.popup.invalidate();
    }

    /// Move the selection by `steps` entry rows.
    fn moveSelection(self: *Sheet, steps: isize) void {
        self.ensureLayout();
        const row = stepSelection(self.rows.items, self.selected, steps) orelse return;
        self.select(row);
    }

    /// The entry rows a page holds.
    fn pageRows(self: *Sheet) isize {
        const rows = @floor(self.viewHeight() / layout.row_height) - 1;
        return @intFromFloat(@max(1, rows));
    }

    /// The hovered row after the list moved under a still pointer.
    fn refreshHover(self: *Sheet) void {
        const hwnd = self.popup.hwnd orelse return;
        var pt: w32.POINT = undefined;
        if (w32.GetCursorPos_(&pt) == 0) return;
        _ = w32.ScreenToClient(hwnd, &pt);
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        if (pt.x < client.left or pt.y < client.top or pt.x >= client.right or pt.y >= client.bottom) {
            self.hover = null;
            return;
        }
        const s = self.popup.scale();
        self.hover = self.rowAt(.{ .x = @as(f32, @floatFromInt(pt.x)) / s, .y = @as(f32, @floatFromInt(pt.y)) / s });
    }

    /// The entry row under `pos`, if any.
    fn rowAt(self: *Sheet, pos: d2d.Point) ?usize {
        if (pos.y < layout.list_top) return null;
        const width = self.popup.sizeDip().width;
        if (pos.x < layout.list_x or pos.x >= width - layout.list_x) return null;
        const y = pos.y - layout.list_top + self.scroll;
        for (self.rows.items, 0..) |row, i| {
            if (y >= row.y and y < row.y + row.h) return if (row.kind == .entry) i else null;
        }
        return null;
    }

    fn closeButton(width: f32) d2d.Rect {
        return .{
            .x = width - style.space.l - style.close_button.size,
            .y = layout.title_y,
            .w = style.close_button.size,
            .h = style.close_button.size,
        };
    }

    /// The Record Keys button right of the search field.
    fn recordButton(self: *const Sheet, width: f32) d2d.Rect {
        return .{
            .x = width - layout.pad_x - self.record_width,
            .y = layout.input_y,
            .w = self.record_width,
            .h = layout.input_height,
        };
    }

    // -------------------------------------------------------------------
    // Recording keys
    // -------------------------------------------------------------------

    /// Start or stop recording keys. Starting clears the search, which then
    /// shows how recording works; the input method is off while recording,
    /// so keys arrive as they are.
    fn setRecording(self: *Sheet, on: bool) void {
        if (self.recording.active == on) return;
        self.recording.active = on;
        self.recording.len = 0;
        if (self.popup.hwnd) |hwnd| _ = ImmAssociateContextEx(hwnd, null, if (on) 0 else IACE_DEFAULT);
        if (on and self.popup.input.buf.items.len > 0) {
            self.popup.input.clear();
            self.refilter();
        }
        self.popup.invalidate();
    }

    /// Record a key press into the search.
    fn record(self: *Sheet, key: Popup.Key) void {
        var name_buf: [4]u8 = undefined;
        if (keyName(physicalKey(key.vk), layoutChar(key.vk), &name_buf) == null) return;
        const press: Recording.Press = .{ .vk = key.vk, .mods = modsOf(key) };
        self.recording.add(self.palette().keybindSet(), press);
        var buf: [256]u8 = undefined;
        const text = self.recording.query(&buf);
        self.popup.input.setText(self.gpa(), text) catch |err| {
            log.warn("cannot show the recorded keys err={}", .{err});
            return;
        };
        self.refilter();
        self.popup.invalidate();
    }

    // -------------------------------------------------------------------
    // The native list
    // -------------------------------------------------------------------

    /// Show the shortcuts in the native list window (see the file header),
    /// or refresh the text of the open one; `activate` brings it to the
    /// front. Returns false when it cannot be shown.
    fn openList(self: *Sheet, activate: bool) bool {
        const pane = self.paneView();
        const window = pane.ownerWindow();
        const owner = window.hwnd orelse return false;
        if (self.popup.visible) self.close(false);
        self.build();
        const a = if (self.arena) |*arena| arena.allocator() else return false;
        const text = listText(a, self.entries.items, "\r\n") catch return false;
        const units = wstr.allocZ(a, text) catch return false;
        return self.list.show(pane.app().hinstance, owner, window.scale, units, activate);
    }

    // -------------------------------------------------------------------
    // Running
    // -------------------------------------------------------------------

    /// Close the sheet and perform the actions of entry row `row`.
    fn runRow(self: *Sheet, row: usize) void {
        if (row >= self.rows.items.len) return;
        const index = switch (self.rows.items[row].kind) {
            .entry => |i| i,
            .notice, .header => return,
        };
        const pane = self.paneView();
        const app_ = pane.app();
        const reference = pane.reference();
        const actions = self.entries.items[index].actions;
        const skip = isKeybinds(actions);
        var arena = std.heap.ArenaAllocator.init(app_.core_app.alloc);
        defer arena.deinit();
        const copies = cloneActions(arena.allocator(), actions) catch {
            self.close(true);
            return;
        };
        self.close(true);
        if (!skip) perform(app_, reference, copies);
    }

    /// A key bound to an action outside the search: close the sheet and
    /// perform it. Returns false when the key should edit the search
    /// instead.
    fn performChord(self: *Sheet, key: Popup.Key) bool {
        const pane = self.paneView();
        const app_ = pane.app();
        const reference = pane.reference();
        const value = bindingForKey(self.palette().keybindSet(), key.vk, modsOf(key)) orelse {
            // Ctrl+Alt without a binding is AltGr typing a character.
            return !(key.ctrl and key.alt);
        };
        const actions: []const Action = switch (value.*) {
            .leader => return true,
            .leaf => |*leaf| (&leaf.action)[0..1],
            .leaf_chained => |chained| chained.actions.items,
        };
        if (actions.len == 1) switch (actions[0]) {
            // Clipboard chords (e.g. Ctrl+Shift+V) edit the search.
            .copy_to_clipboard, .paste_from_clipboard, .select_all => return false,
            else => {},
        };
        const skip = isKeybinds(actions);
        var arena = std.heap.ArenaAllocator.init(app_.core_app.alloc);
        defer arena.deinit();
        const copies = cloneActions(arena.allocator(), actions) catch {
            self.close(true);
            return true;
        };
        self.close(true);
        if (!skip) perform(app_, reference, copies);
        return true;
    }

    // -------------------------------------------------------------------
    // Input
    // -------------------------------------------------------------------

    fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        _ = Palette.adoptShown(popup);
        const handled = self.keyPress(key);
        // TranslateMessage made characters of the key already: they would
        // go into the search, or beep (Alt+K).
        if (handled) if (popup.hwnd) |hwnd| dropTypedChars(hwnd);
        return handled;
    }

    fn keyPress(self: *Sheet, key: Popup.Key) bool {
        switch (command(key, self.recording.active)) {
            .edit => return false,
            .swallow => return true,
            .close => self.close(true),
            .close_window => {
                const window = self.paneView().ownerWindow();
                self.close(true);
                if (window.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
            },
            .record_start => self.setRecording(true),
            .record_stop => self.setRecording(false),
            .record => self.record(key),
            .run => if (self.selected) |row| self.runRow(row),
            .previous => self.moveSelection(-1),
            .next => self.moveSelection(1),
            .page_previous => self.moveSelection(-self.pageRows()),
            .page_next => self.moveSelection(self.pageRows()),
            .first => if (firstEntry(self.rows.items)) |row| self.select(row),
            .last => if (lastEntry(self.rows.items)) |row| self.select(row),
            .chord => return self.performChord(key),
        }
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
        self.ensureLayout();
        const width = popup.sizeDip().width;
        const view = self.listView();
        const on_close = closeButton(width).contains(event.pos);
        const on_record = self.record_width > 0 and self.recordButton(width).contains(event.pos);
        switch (event.kind) {
            .move => {
                if (self.scrollbar.dragging()) {
                    if (!self.capturing()) {
                        self.endDrag();
                        popup.invalidate();
                    } else if (self.scrollbar.drag(view, self.content_height, view.h, event.pos)) |offset| {
                        self.scrollTo(offset);
                    }
                    return;
                }
                var changed = self.scrollbar.updateHover(view, event.pos);
                const row = self.rowAt(event.pos);
                if (row != self.hover or on_close != self.close_hover or on_record != self.record_hover) {
                    self.hover = row;
                    self.close_hover = on_close;
                    self.record_hover = on_record;
                    changed = true;
                }
                if (changed) popup.invalidate();
            },
            .leave => {
                if (self.scrollbar.dragging()) return;
                self.hover = null;
                self.close_hover = false;
                self.record_hover = false;
                self.scrollbar.hover = false;
                popup.invalidate();
            },
            .down, .double_click => if (event.button == .left) {
                if (self.scrollbar.press(view, self.content_height, view.h, self.scroll, event.pos)) |offset| {
                    if (popup.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
                    self.scrollTo(offset);
                    popup.invalidate();
                    return;
                }
                if (self.rowAt(event.pos)) |row| {
                    if (event.kind == .double_click) {
                        self.runRow(row);
                        return;
                    }
                    self.select(row);
                }
                self.close_pressed = on_close;
                self.record_pressed = on_record;
                popup.invalidate();
            },
            .up => if (event.button == .left) {
                if (self.scrollbar.dragging()) {
                    self.endDrag();
                    popup.invalidate();
                    return;
                }
                const close_clicked = self.close_pressed and on_close;
                const record_clicked = self.record_pressed and on_record;
                self.close_pressed = false;
                self.record_pressed = false;
                if (close_clicked) {
                    self.close(true);
                    return;
                }
                if (record_clicked) self.setRecording(!self.recording.active);
                popup.invalidate();
            },
            .wheel => {
                self.scrollTo(self.scroll - event.wheel * layout.wheel_step);
                self.hover = self.rowAt(event.pos);
                popup.invalidate();
            },
        }
    }

    /// Whether the sheet still has the mouse captured for a drag.
    fn capturing(self: *Sheet) bool {
        const hwnd = self.popup.hwnd orelse return false;
        return w32.GetCapture() == hwnd;
    }

    fn endDrag(self: *Sheet) void {
        if (!self.scrollbar.dragging()) return;
        self.scrollbar.release();
        if (self.capturing()) _ = w32.ReleaseCapture();
    }

    fn onDismissed(ctx: *anyopaque, _: *Popup, reason: Popup.DismissReason) void {
        const self: *Sheet = @ptrCast(@alignCast(ctx));
        self.endInteraction();
        if (reason == .escape or reason == .owner) {
            self.paneView().focus();
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
        if (!gx.perf.enabled()) return self.paintSheet(popup, canvas);

        // How long a paint takes and how much text it lays out: the keycaps
        // this sheet keeps, and the change of the factory's text cache
        // (exact unless the cache turned over a generation meanwhile).
        const io = global.io();
        const span = gx.perf.Span.begin(io);
        const cached = canvas.factory.cachedLayouts();
        const keycaps = self.keycaps.created;
        self.paintSheet(popup, canvas);
        const us = span.end(io, "keybinds.paint");
        log.info("keybinds paint us={d} keycap_layouts={d} text_cache={d}->{d}", .{
            us,
            self.keycaps.created - keycaps,
            cached,
            canvas.factory.cachedLayouts(),
        });
    }

    fn paintSheet(self: *Sheet, popup: *Popup, canvas: *d2d.Canvas) void {
        const t = self.colors();
        const size = popup.sizeDip();
        self.ensureLayout();
        self.measure(canvas.factory);
        canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

        // Title and close button.
        canvas.drawIcon(d2d.icons.keyboard, .{
            .x = layout.pad_x,
            .y = layout.title_y,
            .w = style.icon.large,
            .h = layout.title_height,
        }, style.icon.large, t.accent);
        const title_x = layout.pad_x + style.icon.large + style.space.m;
        const close_rect = closeButton(size.width);
        canvas.drawText(i18n.tr("Keyboard Shortcuts"), .{
            .x = title_x,
            .y = layout.title_y,
            .w = @max(0, close_rect.x - style.space.s - title_x),
            .h = layout.title_height,
        }, .{ .size = style.font_size.subtitle, .weight = .semibold, .color = t.text });
        controls.closeButton(canvas, close_rect, .{
            .hover = self.close_hover,
            .pressed = self.close_pressed and self.close_hover,
        }, t);

        // The search field and the Record Keys button.
        self.paintRecordButton(canvas, size.width, t);
        const record_rect = self.recordButton(size.width);
        popup.drawTextInputEx(canvas, .{
            .x = layout.pad_x,
            .y = layout.input_y,
            .w = @max(0, record_rect.x - style.space.s - layout.pad_x),
            .h = layout.input_height,
        }, t, .{
            .placeholder = if (self.recording.active)
                i18n.tr("Press the keys to look up; Esc stops recording")
            else
                i18n.tr("Search keyboard shortcuts…"),
            // No caret while the keys go to the recording.
            .focused = if (self.recording.active) false else null,
        });
        controls.hairline(canvas, 0, layout.list_top - canvas.hairline(), size.width, t);

        const view = self.listView();
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
        const chips: ChipColors = .fromTokens(t);
        for (self.rows.items, 0..) |row, i| {
            const y = @round((view.y + row.y - self.scroll) * scale) / scale;
            if (y + row.h < view.y) continue;
            if (y > view.y + view.h) break;
            const rect: d2d.Rect = .{ .x = layout.list_x, .y = y, .w = @max(0, view.w - 2 * layout.list_x), .h = row.h };
            switch (row.kind) {
                .notice => |reason| paintNotice(canvas, rect, reason, t),
                .header => |category| canvas.drawText(i18n.trRuntime(category.title()), .{
                    .x = rect.x + layout.row_pad,
                    .y = rect.y,
                    .w = @max(0, rect.w - 2 * layout.row_pad),
                    .h = rect.h - style.space.xs,
                }, .{
                    .size = style.font_size.caption,
                    .weight = .semibold,
                    .color = t.text_secondary,
                    .align_y = .bottom,
                }),
                .entry => |index| self.paintEntry(canvas, rect, i, &self.entries.items[index], t, chips),
            }
        }
        self.scrollbar.draw(canvas, view, self.content_height, view.h, self.scroll, t);
    }

    fn paintRecordButton(self: *Sheet, canvas: *d2d.Canvas, width: f32, t: style.Tokens) void {
        const label = i18n.tr("Record Keys");
        const hint = "Alt+K";
        const label_style: d2d.TextStyle = .{ .size = style.font_size.body, .ellipsis = false };
        const hint_style: d2d.TextStyle = .{ .size = style.font_size.caption, .ellipsis = false };
        const label_w = canvas.measureTextCeil(label, label_style, 1000).width;
        const hint_w = canvas.measureTextCeil(hint, hint_style, 1000).width;
        self.record_width = 2 * style.space.m + style.icon.standard + 2 * style.space.s + label_w + hint_w;

        const rect = canvas.snapRect(self.recordButton(width));
        const state: controls.State = .{
            .hover = self.record_hover,
            .pressed = self.record_pressed and self.record_hover,
        };
        const kind: controls.ButtonKind = if (self.recording.active) .accent else .standard;
        const button = controls.buttonColors(kind, state, t);
        if (button.fill) |fill| canvas.fillRoundedRect(rect, style.radius.control, fill);
        if (button.border) |border| canvas.strokeRoundedRectPx(rect, style.radius.control, border, 1);
        const fill = button.fill orelse t.surface_raised;

        var x = rect.x + style.space.m;
        canvas.drawIcon(d2d.icons.keyboard, .{ .x = x, .y = rect.y, .w = style.icon.standard, .h = rect.h }, style.icon.standard, button.text);
        x += style.icon.standard + style.space.s;
        var text_style = label_style;
        text_style.color = button.text;
        canvas.drawText(label, .{ .x = x, .y = rect.y, .w = label_w, .h = rect.h }, text_style);
        x += label_w + style.space.s;
        var hint_text = hint_style;
        hint_text.color = if (self.recording.active)
            button.text
        else
            ui_color.ensureContrast(t.text_secondary, fill, contrast_floor.text);
        canvas.drawText(hint, .{ .x = x, .y = rect.y, .w = hint_w, .h = rect.h }, hint_text);
    }

    fn paintEntry(
        self: *Sheet,
        canvas: *d2d.Canvas,
        rect: d2d.Rect,
        row: usize,
        entry: *const Entry,
        t: style.Tokens,
        chips: ChipColors,
    ) void {
        const selected = self.selected == row;
        const hovered = self.hover == row;
        const band = rect.inset(0, 1);
        const fill: ?d2d.Color = if (selected) t.selected else if (hovered) t.hover else null;
        if (fill) |f| canvas.fillRoundedRect(canvas.snapRect(band), style.radius.control, f);
        if (selected) controls.selectionIndicator(canvas, band, t);
        const back = fill orelse t.surface_raised;
        const text_color = if (selected) t.selected_text else if (hovered) t.hover_text else t.text;
        // Secondary text and the markers keep their contrast on the row's
        // own fill.
        const secondary = if (fill != null) ui_color.ensureContrast(t.text_secondary, back, contrast_floor.text) else t.text_secondary;
        const caution = if (fill != null) ui_color.ensureContrast(t.caution, back, contrast_floor.non_text) else t.caution;
        const blocked = &self.app().shortcut_conflicts;

        // Keycaps, right-aligned and drawn right to left, so the first
        // sequence ends up rightmost; sequences that do not fit are
        // counted. A sequence that never reaches Ghostty GX has a marker.
        const text_x = rect.x + layout.row_pad;
        const title_w = @min(rect.w * 0.42, 340);
        const min_x = text_x + title_w + style.space.s;
        const center_y = rect.y + rect.h / 2;
        var right = rect.x + rect.w - layout.row_pad;
        var shown: usize = 0;
        for (entry.sequences, 0..) |sequence, i| {
            const marked = blocked.sequenceReason(sequence) != null;
            const marker_w: f32 = if (marked) layout.marker_size + style.space.xs else 0;
            const w = if (i < entry.widths.len) entry.widths[i] else self.sequenceWidth(canvas.factory, sequence);
            const x = right - w - (if (shown > 0) layout.sequence_gap else 0);
            if (x - marker_w < min_x) break;
            right = x - marker_w;
            self.drawSequence(canvas, sequence, x, center_y, chips);
            if (marked) canvas.drawIcon(d2d.icons.warning, .{
                .x = right,
                .y = center_y - layout.marker_size / 2,
                .w = layout.marker_size,
                .h = layout.marker_size,
            }, style.icon.small, caution);
            shown += 1;
        }
        if (shown < entry.sequences.len) {
            var buf: [16]u8 = undefined;
            const more = std.fmt.bufPrint(&buf, "+{d}", .{entry.sequences.len - shown}) catch "";
            const w: f32 = 28;
            canvas.drawText(more, .{ .x = right - w - style.space.xs, .y = center_y - 10, .w = w, .h = 20 }, .{
                .size = style.font_size.caption,
                .color = secondary,
                .align_x = .trailing,
            });
            right -= w + style.space.xs;
        }

        // The title and the action; a row with taken keys names them on a
        // second line.
        const line_h: f32 = if (entry.conflict != null) layout.row_height - 6 else rect.h;
        canvas.drawText(entry.title, .{ .x = text_x, .y = rect.y, .w = title_w, .h = line_h }, .{
            .size = style.font_size.body,
            .color = text_color,
        });
        const action_x = text_x + title_w + style.space.s;
        canvas.drawText(entry.action_text, .{ .x = action_x, .y = rect.y, .w = @max(0, right - action_x - layout.row_pad), .h = line_h }, .{
            .size = style.font_size.caption,
            .color = secondary,
        });
        if (entry.conflict != null) {
            const note_y = rect.y + line_h - 6;
            const note_h = rect.h - line_h;
            canvas.drawIcon(d2d.icons.warning, .{ .x = text_x, .y = note_y, .w = layout.marker_size, .h = note_h }, style.icon.small, caution);
            const note_x = text_x + layout.marker_size + style.space.xs;
            canvas.drawText(entry.conflict_note, .{
                .x = note_x,
                .y = note_y,
                .w = @max(0, right - note_x - layout.row_pad),
                .h = note_h,
            }, .{ .size = style.font_size.caption, .color = secondary });
        }
    }

    /// Draw the keycaps of a key sequence from `x`, vertically centered on
    /// `center_y`, with the kept text layouts.
    fn drawSequence(self: *Sheet, canvas: *d2d.Canvas, sequence: []const Trigger, x: f32, center_y: f32, chips: ChipColors) void {
        const alloc = self.gpa();
        const top = center_y - keycap.height / 2;
        var cx = x;
        for (sequence, 0..) |step_trigger, step| {
            if (step > 0) {
                cx += keycap.step_gap;
                if (self.keycaps.get(alloc, canvas.factory, keycap.arrow)) |cap| {
                    canvas.drawLayout(&cap.layout, .{ .x = cx, .y = top }, chips.arrow, &.{});
                    cx += @ceil(cap.text_w);
                }
                cx += keycap.step_gap;
            }
            const caps: shortcuts.Keycaps = .init(step_trigger, .windows);
            for (0..caps.count()) |i| {
                if (i > 0) cx += keycap.gap;
                const cap = self.keycaps.get(alloc, canvas.factory, caps.get(i)) orelse continue;
                const r = canvas.snapRect(.{ .x = cx, .y = top, .w = cap.width, .h = keycap.height });
                canvas.fillRoundedRect(r, style.radius.control, chips.fill);
                canvas.strokeRoundedRectPx(r, style.radius.control, chips.border, 1);
                canvas.drawLayout(&cap.layout, .{ .x = r.x + (r.w - cap.text_w) / 2, .y = r.y + (r.h - keycap.height) / 2 }, chips.text, &.{});
                cx += cap.width;
            }
        }
    }
};

fn noticeTextStyle(color: d2d.Color) d2d.TextStyle {
    return .{
        .size = style.type_ramp.body.size,
        .line_height = style.type_ramp.body.line,
        .color = color,
        .align_y = .top,
        .wrap = true,
        .ellipsis = false,
    };
}

/// The width of the text of a notice in a sheet `width` wide.
fn noticeTextWidth(width: f32) f32 {
    return @max(1, width - 2 * layout.list_x - 2 * layout.notice_pad - layout.marker_size - style.space.s);
}

/// The height of the row of a notice in a sheet `width` wide, the gap
/// below it included.
fn noticeHeight(factory: *d2d.Factory, reason: Reason, width: f32) f32 {
    const text = factory.measureText(noticeText(reason), noticeTextStyle(.{ .r = 0, .g = 0, .b = 0 }), noticeTextWidth(width));
    return @max(layout.row_height, @ceil(text.height) + 2 * layout.notice_pad) + layout.notice_gap;
}

fn paintNotice(canvas: *d2d.Canvas, rect: d2d.Rect, reason: Reason, t: style.Tokens) void {
    const box = canvas.snapRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(0, rect.h - layout.notice_gap) });
    const fill = if (t.high_contrast) t.surface_raised else style.mix(t.surface_raised, t.caution, 0.12);
    const border = if (t.high_contrast) t.border else style.mix(t.surface_raised, t.caution, 0.4);
    canvas.fillRoundedRect(box, style.radius.control, fill);
    canvas.strokeRoundedRectPx(box, style.radius.control, border, 1);
    canvas.drawIcon(d2d.icons.warning, .{
        .x = box.x + layout.notice_pad,
        .y = box.y + layout.notice_pad,
        .w = layout.marker_size,
        .h = style.type_ramp.body.line,
    }, layout.marker_size, ui_color.ensureContrast(t.caution, fill, contrast_floor.non_text));
    const text_x = box.x + layout.notice_pad + layout.marker_size + style.space.s;
    canvas.drawText(noticeText(reason), .{
        .x = text_x,
        .y = box.y + layout.notice_pad,
        .w = @max(1, box.x + box.w - layout.notice_pad - text_x),
        .h = @max(0, box.h - 2 * layout.notice_pad),
    }, noticeTextStyle(ui_color.ensureContrast(t.text, fill, contrast_floor.text)));
}

/// The popup of the sheet: it takes the keyboard for its search field and
/// keeps its window painted as active meanwhile.
fn popupOptions(t: style.Tokens) Popup.Options {
    return .{
        .activate = true,
        .text_input = true,
        .dismiss_on_escape = true,
        .dismiss_on_outside_click = true,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
        .keep_owner_active = true,
    };
}

/// Where the sheet goes in a window's client area `client_w` × `client_h`
/// pixels with chrome `chrome_h` pixels high, at `scale`: centered below
/// the chrome, `layout.margin` from the edges, between the minimum and the
/// maximum size.
fn placement(client_w: i32, client_h: i32, chrome_h: i32, scale: f32) w32.RECT {
    const w = style.dip(client_w, scale);
    const h = style.dip(client_h, scale);
    const chrome = style.dip(chrome_h, scale);
    const width = std.math.clamp(w - 2 * layout.margin, layout.width_min, layout.width_max);
    const height = std.math.clamp(h - chrome - 2 * layout.margin, layout.height_min, layout.height_max);
    const left = style.px(@max(0, (w - width) / 2), scale);
    const top = style.px(chrome + @max(0, (h - chrome - height) / 2), scale);
    return .{
        .left = left,
        .top = top,
        .right = left + style.px(width, scale),
        .bottom = top + style.px(height, scale),
    };
}

// -----------------------------------------------------------------------
// Searching and the list
// -----------------------------------------------------------------------

/// The entries that match `search` into `out`, in sheet order: by
/// category, then by score, best first, then by their place in the
/// category.
fn rank(alloc: Allocator, out: *std.ArrayList(Match), entries: []const Entry, search: *const shortcuts.Search) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (entries, 0..) |entry, i| {
        const titles = [_][]const u8{ entry.title, entry.title_en, entry.action_text };
        const score = search.score(&titles, entry.sequences) orelse continue;
        try out.append(alloc, .{ .entry = @intCast(i), .score = score });
    }
    if (search.isEmpty()) return;
    const Order = struct {
        entries: []const Entry,

        fn lessThan(ctx: @This(), a: Match, b: Match) bool {
            const ca = ctx.entries[a.entry].category;
            const cb = ctx.entries[b.entry].category;
            if (ca != cb) return @intFromEnum(ca) < @intFromEnum(cb);
            if (a.score != b.score) return a.score > b.score;
            return a.entry < b.entry;
        }
    };
    std.mem.sort(Match, out.items, Order{ .entries = entries }, Order.lessThan);
}

/// The rows for `matches` into `rows`: a notice for each reason why keys
/// of a row on display never reach Ghostty GX, then each category with
/// its rows.
fn listRows(alloc: Allocator, rows: *std.ArrayList(Row), entries: []const Entry, matches: []const Match) Allocator.Error!void {
    rows.clearRetainingCapacity();
    var reasons: std.EnumSet(Reason) = .initEmpty();
    for (matches) |match| {
        if (entries[match.entry].conflict) |reason| reasons.insert(reason);
    }
    var it = reasons.iterator();
    while (it.next()) |reason| try rows.append(alloc, .{ .kind = .{ .notice = reason } });

    var current: ?shortcuts.Category = null;
    for (matches) |match| {
        const category = entries[match.entry].category;
        if (current != category) {
            try rows.append(alloc, .{ .kind = .{ .header = category } });
            current = category;
        }
        try rows.append(alloc, .{ .kind = .{ .entry = match.entry } });
    }
}

/// Lay out `rows` from the top of the list, with the notices
/// `notice_height` high. Returns the height of the content.
fn placeRows(rows: []Row, entries: []const Entry, notice_height: std.EnumArray(Reason, f32)) f32 {
    var y: f32 = layout.list_pad;
    for (rows) |*row| {
        row.y = y;
        row.h = switch (row.kind) {
            .notice => |reason| notice_height.get(reason),
            .header => layout.header_height,
            .entry => |i| if (entries[i].conflict != null) layout.conflict_row_height else layout.row_height,
        };
        y += row.h;
    }
    return if (rows.len == 0) 0 else y + layout.list_pad;
}

fn firstEntry(rows: []const Row) ?usize {
    for (rows, 0..) |row, i| {
        if (row.kind == .entry) return i;
    }
    return null;
}

fn lastEntry(rows: []const Row) ?usize {
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        if (rows[i].kind == .entry) return i;
    }
    return null;
}

/// The entry row `steps` entry rows after `from` (before it for negative
/// steps), stopping at the first and the last; the first entry row when
/// nothing is selected. Null when there is no entry row.
fn stepSelection(rows: []const Row, from: ?usize, steps: isize) ?usize {
    const start = from orelse return firstEntry(rows);
    if (start >= rows.len) return firstEntry(rows);
    var current = start;
    var left = @abs(steps);
    var i = start;
    while (left > 0) {
        if (steps > 0) {
            if (i + 1 >= rows.len) break;
            i += 1;
        } else {
            if (i == 0) break;
            i -= 1;
        }
        if (rows[i].kind == .entry) {
            current = i;
            left -= 1;
        }
    }
    return current;
}

/// The scroll offset that shows row `index` whole in a view `view` high,
/// moving as little as possible from `scroll`. The first entry also
/// shows what is above it, and an entry right below its category's
/// header shows the header.
fn revealScroll(rows: []const Row, index: usize, scroll: f32, view: f32) f32 {
    const row = rows[index];
    var top = row.y;
    var bottom = row.y + row.h;
    if (firstEntry(rows) == index) {
        top = 0;
    } else if (index > 0 and rows[index - 1].kind == .header) {
        top = rows[index - 1].y;
    }
    if (lastEntry(rows) == index) bottom += layout.list_pad;
    if (top < scroll) return top;
    if (bottom > scroll + view) return @min(top, bottom - view);
    return scroll;
}

// -----------------------------------------------------------------------
// Keys
// -----------------------------------------------------------------------

/// What a key press in the sheet does.
const Command = enum {
    /// The search field takes it.
    edit,
    /// Nothing happens.
    swallow,
    close,
    /// Alt+F4: close the sheet and its window.
    close_window,
    record_start,
    record_stop,
    /// Record the key into the search.
    record,
    /// Perform the selected row.
    run,
    previous,
    next,
    page_previous,
    page_next,
    first,
    last,
    /// Perform the key's binding, if it has one.
    chord,
};

/// What `key` does in the sheet, `recording` keys or not.
fn command(key: Popup.Key, recording: bool) Command {
    if (key.vk == w32.VK_PROCESSKEY) return .edit;
    const plain = !key.ctrl and !key.alt and !key.shift;
    const alt_only = key.alt and !key.ctrl and !key.shift;
    if (recording) {
        if (key.vk == 'K' and alt_only) return .record_stop;
        if (key.vk == w32.VK_ESCAPE and plain) return .record_stop;
        if (isModifier(key.vk)) return .swallow;
        return .record;
    }
    switch (key.vk) {
        w32.VK_ESCAPE => return .close,
        'K' => if (alt_only) return .record_start,
        w32.VK_UP => if (!key.ctrl and !key.alt) return .previous,
        w32.VK_DOWN => if (!key.ctrl and !key.alt) return .next,
        w32.VK_PRIOR => if (!key.ctrl and !key.alt) return .page_previous,
        w32.VK_NEXT => if (!key.ctrl and !key.alt) return .page_next,
        // Home and End move the caret; with Ctrl they go through the list.
        w32.VK_HOME => if (key.ctrl and !key.shift and !key.alt) return .first,
        w32.VK_END => if (key.ctrl and !key.shift and !key.alt) return .last,
        w32.VK_RETURN => if (!key.ctrl and !key.alt) return .run,
        w32.VK_F4 => if (alt_only) return .close_window,
        else => {},
    }
    if (!key.ctrl and !key.alt) return .edit;
    // Editing chords stay with the search field even when bound
    // (Ctrl+Shift+Left selects a word), like the other popup inputs
    // (`App.editKeyRoute`).
    if (key.ctrl and !key.alt) switch (key.vk) {
        w32.VK_LEFT, w32.VK_RIGHT, w32.VK_HOME, w32.VK_END, w32.VK_BACK, w32.VK_DELETE, w32.VK_INSERT => return .edit,
        'A', 'C', 'V', 'X', 'Y', 'Z' => return .edit,
        else => {},
    };
    return .chord;
}

fn isModifier(vk: u16) bool {
    return switch (vk) {
        w32.VK_SHIFT, w32.VK_CONTROL, w32.VK_MENU, w32.VK_LWIN, w32.VK_RWIN => true,
        // VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU.
        0xA0...0xA5 => true,
        else => false,
    };
}

/// The modifiers of a key press, the Windows key included.
fn modsOf(key: Popup.Key) input.Mods {
    const win = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0;
    return .{ .ctrl = key.ctrl, .shift = key.shift, .alt = key.alt, .super = win };
}

/// Drop the characters TranslateMessage made of a key the sheet took, so
/// that they neither go into the search field nor beep (Alt+K).
fn dropTypedChars(hwnd: w32.HWND) void {
    var msg: w32.MSG = undefined;
    while (w32.PeekMessageW(&msg, hwnd, w32.WM_CHAR, w32.WM_DEADCHAR, w32.PM_REMOVE) != 0) {}
    while (w32.PeekMessageW(&msg, hwnd, w32.WM_SYSCHAR, w32.WM_SYSDEADCHAR, w32.PM_REMOVE) != 0) {}
}

const MAPVK_VK_TO_CHAR: u32 = 2;
const MAPVK_VK_TO_VSC_EX: u32 = 4;
const IACE_DEFAULT: u32 = 0x0010;
extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
extern "imm32" fn ImmAssociateContextEx(hwnd: w32.HWND, himc: ?w32.HIMC, flags: u32) callconv(.winapi) i32;

/// The physical key of virtual key `vk` on the current layout.
fn physicalKey(vk: u16) ?input.Key {
    const scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
    if (scan == 0) return null;
    for (input.keycodes.entries) |entry| {
        if (entry.native == scan and entry.key != .unidentified) return entry.key;
    }
    return null;
}

/// The character virtual key `vk` types without modifiers on the current
/// layout, or 0.
fn layoutChar(vk: u16) u32 {
    return MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0x7FFF;
}

/// The binding of `set` for virtual key `vk` with `mods`, matched like the
/// core matches key events (`Binding.Set.getEvent`): by the physical key,
/// then by the unshifted character of the key.
fn bindingForKey(set: *const Binding.Set, vk: u16, mods: input.Mods) ?*const Binding.Set.Value {
    var t: Trigger = .{ .mods = mods.binding() };
    if (physicalKey(vk)) |key| {
        t.key = .{ .physical = key };
        if (set.get(t)) |entry| return entry.value_ptr;
    }
    const char = layoutChar(vk);
    if (char >= 0x20) {
        const cp: u21 = @intCast(if (char >= 'A' and char <= 'Z') char + 32 else char);
        t.key = .{ .unicode = cp };
        if (set.get(t)) |entry| return entry.value_ptr;
    }
    return null;
}

/// Whether `key` types a character: letters, digits and punctuation, whose
/// character depends on the layout.
fn typesCharacter(key: input.Key) bool {
    const k = @intFromEnum(key);
    if (k >= @intFromEnum(input.Key.key_a) and k <= @intFromEnum(input.Key.key_z)) return true;
    if (k >= @intFromEnum(input.Key.digit_0) and k <= @intFromEnum(input.Key.digit_9)) return true;
    return switch (key) {
        .backquote,
        .minus,
        .equal,
        .bracket_left,
        .bracket_right,
        .backslash,
        .intl_backslash,
        .semicolon,
        .quote,
        .comma,
        .period,
        .slash,
        => true,
        else => false,
    };
}

/// A typed character as the name of its key, upper-cased if it is an ASCII
/// letter; null for control characters and for the characters a key query
/// reads as syntax (`+`, `>` and `"`).
fn charName(char: u32, buf: *[4]u8) ?[]const u8 {
    if (char <= 0x20 or char == 0x7F) return null;
    if (char < 0x80 and std.mem.indexOfScalar(u8, "+>\"", @intCast(char)) != null) return null;
    const upper = if (char >= 'a' and char <= 'z') char - ('a' - 'A') else char;
    const cp = std.math.cast(u21, upper) orelse return null;
    const len = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..len];
}

/// The name of a pressed key in a key query: the character a key of the
/// typing area types on the layout (`char`), else the label of the
/// physical key, or its tag name when the label has a space or a `+`,
/// which a key query reads as separators. Null when the key has no name.
fn keyName(physical: ?input.Key, char: u32, buf: *[4]u8) ?[]const u8 {
    const key = physical orelse return charName(char, buf);
    if (typesCharacter(key)) {
        if (charName(char, buf)) |name| return name;
    }
    const label = shortcuts.physicalLabel(key, .windows) orelse return @tagName(key);
    if (std.mem.indexOfAny(u8, label, " +") != null) return @tagName(key);
    return label;
}

/// Write a chord as a key query reads it: its modifiers in sheet order,
/// then the key.
fn writeChord(writer: *std.Io.Writer, mods: input.Mods, key: []const u8) std.Io.Writer.Error!void {
    for (shortcuts.Modifier.order) |mod| {
        const on = switch (mod) {
            .super => mods.super,
            .ctrl => mods.ctrl,
            .alt => mods.alt,
            .shift => mods.shift,
        };
        if (!on) continue;
        try writer.writeAll(mod.label(.windows));
        try writer.writeByte('+');
    }
    try writer.writeAll(key);
}

// -----------------------------------------------------------------------
// Performing
// -----------------------------------------------------------------------

/// Whether `actions` only opens the sheet, which is open already.
fn isKeybinds(actions: []const Action) bool {
    if (actions.len != 1) return false;
    return switch (actions[0]) {
        .gx => |g| g == .keybinds,
        else => false,
    };
}

/// Copy into a caller-owned arena before closing/reloading the sheet.
fn cloneActions(allocator: Allocator, actions: []const Action) ![]const Action {
    const copies = try allocator.alloc(Action, actions.len);
    for (actions, copies) |action, *copy| copy.* = try action.clone(allocator);
    return copies;
}
fn perform(app: *App, reference: ui_ref.Reference, actions: []const Action) void {
    for (actions) |action| {
        const pane = Pane.resolve(app, reference) orelse return;
        _ = pane.performBindingAction(action) catch |err| {
            log.err("shortcut sheet action failed action={t} err={}", .{ action, err });
            return;
        };
    }
}

// -----------------------------------------------------------------------
// The native list
// -----------------------------------------------------------------------

/// The environment variable that makes the sheet act as if a screen reader
/// ran (`screen-reader`), for testing.
const a11y_env = "GHOSTTY_GX_A11Y";

const TaskDialogCallback = *const fn (w32.HWND, u32, usize, isize, isize) callconv(.winapi) i32;
const TaskDialogButton = extern struct {
    id: i32 align(1),
    text: [*:0]const u16 align(1),
};
const TaskDialogConfig = extern struct {
    cbSize: u32 align(1) = @sizeOf(TaskDialogConfig),
    hwndParent: ?w32.HWND align(1) = null,
    hInstance: ?w32.HINSTANCE align(1) = null,
    dwFlags: u32 align(1) = 0,
    dwCommonButtons: u32 align(1) = 0,
    pszWindowTitle: ?[*:0]const u16 align(1) = null,
    mainIcon: ?*anyopaque align(1) = null,
    pszMainInstruction: ?[*:0]const u16 align(1) = null,
    pszContent: ?[*:0]const u16 align(1) = null,
    cButtons: u32 align(1) = 0,
    pButtons: ?[*]const TaskDialogButton align(1) = null,
    nDefaultButton: i32 align(1) = 0,
    cRadioButtons: u32 align(1) = 0,
    pRadioButtons: ?[*]const TaskDialogButton align(1) = null,
    nDefaultRadioButton: i32 align(1) = 0,
    pszVerificationText: ?[*:0]const u16 align(1) = null,
    pszExpandedInformation: ?[*:0]const u16 align(1) = null,
    pszExpandedControlText: ?[*:0]const u16 align(1) = null,
    pszCollapsedControlText: ?[*:0]const u16 align(1) = null,
    footerIcon: ?*anyopaque align(1) = null,
    pszFooter: ?[*:0]const u16 align(1) = null,
    pfCallback: ?TaskDialogCallback align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: u32 align(1) = 0,
};
const TaskDialogIndirect = *const fn (*const TaskDialogConfig, ?*i32, ?*i32, ?*i32) callconv(.winapi) i32;
const TaskDialogData = struct {
    source: w32.HWND,
    text: [:0]const u16,
};
const task_copy_id = 1001;
const TDF_ALLOW_DIALOG_CANCELLATION: u32 = 0x0008;
const TDF_CALLBACK_TIMER: u32 = 0x0800;
const TDF_POSITION_RELATIVE_TO_WINDOW: u32 = 0x1000;
const TDN_BUTTON_CLICKED: u32 = 2;
const TDN_TIMER: u32 = 4;
const TDM_CLICK_BUTTON: u32 = w32.WM_USER + 102;

fn taskDialog(source: w32.HWND, owner: ?w32.HWND, edit: w32.HWND) bool {
    const library = w32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("comctl32.dll"), null, w32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return false;
    defer _ = w32.FreeLibrary(library);
    const run: TaskDialogIndirect = @ptrCast(w32.GetProcAddress(library, "TaskDialogIndirect") orelse return false);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const len: usize = @intCast(@max(0, w32.GetWindowTextLengthW(edit)));
    const text = a.allocSentinel(u16, len, 0) catch return false;
    _ = w32.GetWindowTextW(edit, text.ptr, @intCast(len + 1));
    const title = wstr.allocZ(a, i18n.tr("Keyboard Shortcuts")) catch return false;
    const copy = wstr.allocZ(a, i18n.tr("Copy")) catch return false;
    const close = wstr.allocZ(a, i18n.tr("Close")) catch return false;
    var data: TaskDialogData = .{ .source = source, .text = text };
    const buttons = [_]TaskDialogButton{
        .{ .id = task_copy_id, .text = copy.ptr },
        .{ .id = w32.IDCANCEL, .text = close.ptr },
    };
    const config: TaskDialogConfig = .{
        .hwndParent = owner,
        .dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_CALLBACK_TIMER | TDF_POSITION_RELATIVE_TO_WINDOW,
        .pszWindowTitle = title.ptr,
        .pszMainInstruction = title.ptr,
        .pszContent = text.ptr,
        .cButtons = buttons.len,
        .pButtons = &buttons,
        .nDefaultButton = w32.IDCANCEL,
        .pfCallback = taskDialogCallback,
        .lpCallbackData = @bitCast(@intFromPtr(&data)),
        .cxWidth = 420,
    };
    const hr = run(&config, null, null, null);
    if (hr < 0) log.warn("native shortcut TaskDialogIndirect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    return hr >= 0;
}

fn taskDialogCallback(hwnd: w32.HWND, msg: u32, wparam: usize, _: isize, ref_data: isize) callconv(.winapi) i32 {
    const data: *const TaskDialogData = @ptrFromInt(@as(usize, @bitCast(ref_data)));
    // The list window went away with its terminal.
    if (msg == TDN_TIMER and w32.IsWindow(data.source) == 0) {
        _ = w32.SendMessageW(hwnd, TDM_CLICK_BUTTON, w32.IDCANCEL, 0);
    }
    if (msg != TDN_BUTTON_CLICKED or wparam != task_copy_id) return 0;
    const units = data.text.len + 1;
    const handle = w32.GlobalAlloc(w32.GMEM_MOVEABLE, units * @sizeOf(u16)) orelse return 1;
    const ptr = w32.GlobalLock(handle) orelse {
        _ = w32.GlobalFree(handle);
        return 1;
    };
    const dst: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dst[0..units], data.text[0..units]);
    _ = w32.GlobalUnlock(handle);
    clipboard.setUnicodeText(hwnd, handle) catch |err| {
        log.warn("copy from shortcut dialog failed err={}", .{err});
        _ = w32.GlobalFree(handle);
    };
    return 1;
}

/// Whether a screen reader runs (`SPI_GETSCREENREADER`), or `a11y_env`
/// asks to act as if one did.
fn screenReaderRunning() bool {
    if (a11yOverride()) return true;
    var on: i32 = 0;
    return SystemParametersInfoW(SPI_GETSCREENREADER, 0, @ptrCast(&on), 0) != 0 and on != 0;
}

fn a11yOverride() bool {
    const wide = global.environ().getWindows(std.unicode.utf8ToUtf16LeStringLiteral(a11y_env)) orelse return false;
    var buf: [32]u8 = undefined;
    if (wide.len > buf.len) return false;
    for (wide, buf[0..wide.len]) |c, *out| {
        out.* = std.math.cast(u8, c) orelse return false;
    }
    return isScreenReaderValue(buf[0..wide.len]);
}

/// Whether a value of `a11y_env` asks for the screen reader behavior.
fn isScreenReaderValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, &std.ascii.whitespace), "screen-reader");
}

/// The text of the native list: why keys are taken, once per reason, then
/// each category with its rows, one per line (`New Tab — Ctrl+Shift+T`),
/// the keys that never reach Ghostty GX named after them. Lines end with
/// `newline`.
fn listText(a: Allocator, entries: []const Entry, newline: []const u8) std.Io.Writer.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var reasons: std.EnumSet(Reason) = .initEmpty();
    for (entries) |entry| {
        if (entry.conflict) |reason| reasons.insert(reason);
    }
    var notices = reasons.iterator();
    while (notices.next()) |reason| {
        try w.writeAll(noticeText(reason));
        try w.writeAll(newline);
    }
    var current: ?shortcuts.Category = null;
    for (entries) |entry| {
        if (current != entry.category) {
            if (current != null or reasons.count() > 0) try w.writeAll(newline);
            try w.writeAll(i18n.trRuntime(entry.category.title()));
            try w.writeAll(newline);
            current = entry.category;
        }
        try w.writeAll("    ");
        try w.writeAll(entry.title);
        try w.writeAll(" \u{2014} ");
        for (entry.sequences, 0..) |sequence, i| {
            if (i > 0) try w.writeAll(", ");
            try shortcuts.writeSequence(w, sequence, .windows, " " ++ keycap.arrow ++ " ");
        }
        if (entry.conflict != null) try w.print(" ({s})", .{entry.conflict_note});
        try w.writeAll(newline);
    }
    return out.written();
}

/// The keyboard shortcuts as plain text in a native window owned by the
/// terminal's window (see the file header): a read-only multi-line edit
/// control in the system colors, so it follows high contrast. Escape or
/// closing the window gives the keyboard back to the terminal.
const List = struct {
    hwnd: ?w32.HWND = null,
    owner: ?w32.HWND = null,
    edit: ?w32.HWND = null,
    font: ?*anyopaque = null,
    task_open: bool = false,
    native_fallback: bool = false,
    /// The scale the text and padding are sized for: the window's content
    /// scale, then the DPI of the monitor the list moved to.
    scale: f32 = 1,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxShortcutList");
    const WM_SHOW_TASK_DIALOG = w32.WM_USER + 1;
    var class_registered = false;

    /// The size of the window and the room around the text, in DIPs.
    const width: f32 = 640;
    const height: f32 = 600;
    const padding: f32 = style.space.m;

    fn sheet(self: *List) *Sheet {
        return @alignCast(@fieldParentPtr("list", self));
    }

    fn show(self: *List, hinstance: w32.HINSTANCE, owner: w32.HWND, scale: f32, text: [:0]const u16, bring_to_front: bool) bool {
        const created = self.hwnd == null;
        if (created and !self.create(hinstance, owner, scale)) return false;
        const hwnd = self.hwnd orelse return false;
        self.owner = owner;
        var title: [128]u16 = undefined;
        _ = w32.SetWindowTextW(hwnd, wstr.bufZ(&title, i18n.tr("Keyboard Shortcuts")));
        if (self.edit) |edit| {
            _ = w32.SetWindowTextW(edit, text.ptr);
            _ = w32.SendMessageW(edit, EM_SETSEL, 0, 0);
        }
        if (created or bring_to_front) {
            if (self.native_fallback) {
                self.activate();
            } else if (!self.task_open) {
                return w32.PostMessageW(hwnd, WM_SHOW_TASK_DIALOG, 0, 0) != 0;
            }
        }
        return true;
    }

    fn activate(self: *List) void {
        const hwnd = self.hwnd orelse return;
        _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
        _ = w32.SetForegroundWindow(hwnd);
        if (self.edit) |edit| _ = w32.SetFocus(edit);
    }

    fn runTaskDialog(self: *List) void {
        if (self.task_open) return;
        const hwnd = self.hwnd orelse return;
        const edit = self.edit orelse return;
        self.task_open = true;
        const shown = taskDialog(hwnd, self.owner, edit);
        if (w32.IsWindow(hwnd) == 0) return;
        const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (userdata == 0) return;
        const current: *List = @ptrFromInt(@as(usize, @bitCast(userdata)));
        current.task_open = false;
        if (shown) {
            current.close();
        } else {
            current.native_fallback = true;
            current.activate();
        }
    }

    fn create(self: *List, hinstance: w32.HINSTANCE, owner: w32.HWND, scale: f32) bool {
        if (!registerClass(hinstance)) return false;
        var frame: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = w32.GetWindowRect(owner, &frame);
        const w = style.px(width, scale);
        const h = style.px(height, scale);
        const hwnd = w32.CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_OVERLAPPEDWINDOW,
            @divTrunc(frame.left + frame.right - w, 2),
            @divTrunc(frame.top + frame.bottom - h, 2),
            w,
            h,
            owner,
            null,
            hinstance,
            null,
        ) orelse return false;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        const edit = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
            0,
            0,
            0,
            0,
            hwnd,
            null,
            hinstance,
            null,
        ) orelse {
            _ = w32.DestroyWindow(hwnd);
            return false;
        };
        self.edit = edit;
        // Subclassed for Escape; the edit control's own procedure is kept
        // in its user data.
        const original = w32.SetWindowLongPtrW(edit, w32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
        _ = w32.SetWindowLongPtrW(edit, w32.GWLP_USERDATA, original);
        self.setScale(scale);
        return true;
    }

    /// Close the window and give the keyboard back to the terminal.
    fn close(self: *List) void {
        const hwnd = self.hwnd orelse return;
        const terminal = self.sheet().paneView().nativeHandle();
        _ = w32.DestroyWindow(hwnd);
        if (terminal) |h| _ = w32.SetFocus(h);
    }

    /// Destroy the window with the sheet; `WM_NCDESTROY` frees the rest.
    fn destroy(self: *List) void {
        const hwnd = self.hwnd orelse return;
        _ = w32.DestroyWindow(hwnd);
    }

    /// The text size and padding for `scale`.
    fn setScale(self: *List, scale: f32) void {
        self.scale = scale;
        const edit = self.edit orelse return;
        if (w32.CreateFontW(
            -style.px(style.font_size.body, scale),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            0,
            0,
            CLEARTYPE_QUALITY,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        )) |font| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(font), 1);
            if (self.font) |old| _ = w32.DeleteObject(old);
            self.font = font;
        }
        self.layout();
    }

    /// Fill the window with the edit control, the text `padding` from its
    /// edges.
    fn layout(self: *List) void {
        const hwnd = self.hwnd orelse return;
        const edit = self.edit orelse return;
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        _ = w32.MoveWindow(edit, 0, 0, client.right, client.bottom, 1);
        var text: w32.RECT = undefined;
        if (w32.GetClientRect(edit, &text) == 0) return;
        const pad = style.px(padding, self.scale);
        text = .{
            .left = text.left + pad,
            .top = text.top + pad,
            .right = @max(text.left + pad, text.right - pad),
            .bottom = @max(text.top + pad, text.bottom - pad),
        };
        _ = w32.SendMessageW(edit, EM_SETRECT, 0, @bitCast(@intFromPtr(&text)));
    }

    fn registerClass(hinstance: w32.HINSTANCE) bool {
        if (class_registered) return true;
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (w32.RegisterClassExW(&wc) == 0) return false;
        class_registered = true;
        return true;
    }

    fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        const self: *List = @ptrFromInt(@as(usize, @bitCast(userdata)));
        switch (msg) {
            WM_SHOW_TASK_DIALOG => {
                self.runTaskDialog();
                return 0;
            },
            w32.WM_SIZE => {
                self.layout();
                return 0;
            },
            w32.WM_SETFOCUS => {
                if (self.edit) |edit| _ = w32.SetFocus(edit);
                return 0;
            },
            // A read-only edit control asks for its colors like a static
            // control: the window colors, not the dialog face.
            w32.WM_CTLCOLORSTATIC => {
                const hdc: w32.HDC = @ptrFromInt(wparam);
                _ = w32.SetTextColor(hdc, GetSysColor(COLOR_WINDOWTEXT));
                _ = w32.SetBkColor(hdc, GetSysColor(COLOR_WINDOW));
                return @bitCast(@intFromPtr(GetSysColorBrush(COLOR_WINDOW)));
            },
            w32.WM_DPICHANGED => {
                const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = w32.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
                );
                self.setScale(@as(f32, @floatFromInt((wparam >> 16) & 0xFFFF)) / 96.0);
                return 0;
            },
            w32.WM_CLOSE => {
                self.close();
                return 0;
            },
            WM_NCDESTROY => {
                _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
                if (self.font) |font| _ = w32.DeleteObject(font);
                self.* = .{};
                return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    /// The edit control's procedure: Escape closes the window, Ctrl+A
    /// selects everything; the rest goes to the edit control.
    fn editProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        const original = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (original == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        switch (msg) {
            w32.WM_KEYDOWN => switch (wparam & 0xFFFF) {
                w32.VK_ESCAPE => {
                    if (w32.GetParent(hwnd)) |parent| _ = w32.PostMessageW(parent, w32.WM_CLOSE, 0, 0);
                    return 0;
                },
                'A' => if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
                    _ = w32.SendMessageW(hwnd, EM_SETSEL, 0, -1);
                    return 0;
                },
                else => {},
            },
            // The characters of those keys, which a read-only edit control
            // would beep at.
            w32.WM_CHAR => if (wparam == 0x1B or wparam == 0x01) return 0,
            else => {},
        }
        return CallWindowProcW(@ptrFromInt(@as(usize, @bitCast(original))), hwnd, msg, wparam, lparam);
    }
};

const SPI_GETSCREENREADER: u32 = 0x0046;
const ES_MULTILINE: u32 = 0x0004;
const ES_AUTOVSCROLL: u32 = 0x0040;
const ES_READONLY: u32 = 0x0800;
const EM_SETSEL: u32 = 0x00B1;
const EM_SETRECT: u32 = 0x00B3;
const WM_NCDESTROY: u32 = 0x0082;
const COLOR_WINDOW: i32 = 5;
const COLOR_WINDOWTEXT: i32 = 8;
const DEFAULT_CHARSET: u32 = 1;
const CLEARTYPE_QUALITY: u32 = 5;
extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;
extern "user32" fn GetSysColor(nIndex: i32) callconv(.winapi) u32;
extern "user32" fn GetSysColorBrush(nIndex: i32) callconv(.winapi) ?w32.HBRUSH;
extern "user32" fn CallWindowProcW(
    lpPrevWndFunc: *const anyopaque,
    hWnd: w32.HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.winapi) isize;

// -----------------------------------------------------------------------
// Collecting the bindings
// -----------------------------------------------------------------------

/// Collect one entry per action (or chain of actions) bound in `set`, in
/// the order of `gx.shortcuts.collect`, with their titles and texts.
/// `commands` (the configured palette entries) name actions the built-in
/// tables do not know; `blocked` marks the key sequences that never reach
/// Ghostty GX. All memory comes from `a`.
fn collect(
    a: Allocator,
    entries: *std.ArrayList(Entry),
    set: *const Binding.Set,
    commands: []const input.Command,
    blocked: *const shortcut_conflicts.Conflicts,
) !void {
    const rows = try shortcuts.collect(a, set);
    try entries.ensureTotalCapacity(a, rows.len);
    for (rows) |row| {
        var entry: Entry = .{
            .category = row.category,
            .actions = row.actions,
            .sequences = try displayOrder(a, row.sequences),
            .action_text = row.text,
        };
        try describe(a, &entry, commands);
        try markConflicts(a, &entry, blocked);
        entries.appendAssumeCapacity(entry);
    }
}

/// `sequences` with those whose keys all have a name first (media keys
/// such as `copy` last), otherwise in the same order.
fn displayOrder(a: Allocator, sequences: []const []const Trigger) Allocator.Error![]const []const Trigger {
    const out = try a.alloc([]const Trigger, sequences.len);
    var n: usize = 0;
    for ([_]bool{ true, false }) |named| {
        for (sequences) |sequence| {
            if (allNamed(sequence) != named) continue;
            out[n] = sequence;
            n += 1;
        }
    }
    return out;
}

fn allNamed(sequence: []const Trigger) bool {
    for (sequence) |t| {
        if (!shortcuts.hasLabel(t)) return false;
    }
    return true;
}

/// Fill in the titles of `entry`.
fn describe(a: Allocator, entry: *Entry, commands: []const input.Command) !void {
    var titles: std.ArrayList(u8) = .empty;
    var titles_en: std.ArrayList(u8) = .empty;
    for (entry.actions, 0..) |action, i| {
        if (i > 0) {
            try titles.appendSlice(a, ", ");
            try titles_en.appendSlice(a, ", ");
        }
        const formatted = try std.fmt.allocPrint(a, "{f}", .{action});
        const named = shortcuts.title(action, commands) orelse {
            try titles.appendSlice(a, formatted);
            try titles_en.appendSlice(a, formatted);
            continue;
        };
        try titles.appendSlice(a, i18n.trRuntime(named.msgid));
        try titles_en.appendSlice(a, named.msgid);
        if (!named.exact) if (shortcuts.argument(formatted)) |arg| {
            try titles.print(a, " ({s})", .{arg});
            try titles_en.print(a, " ({s})", .{arg});
        };
    }
    entry.title = titles.items;
    entry.title_en = titles_en.items;
}

/// Mark `entry` when a key sequence of it never reaches Ghostty GX: the
/// reason of the first such sequence, and the note that names the first
/// keys of the sequences taken for that reason.
fn markConflicts(a: Allocator, entry: *Entry, blocked: *const shortcut_conflicts.Conflicts) !void {
    var keys: std.Io.Writer.Allocating = .init(a);
    var named: std.ArrayList(Trigger) = .empty;
    for (entry.sequences) |sequence| {
        const reason = blocked.sequenceReason(sequence) orelse continue;
        if (entry.conflict == null) entry.conflict = reason;
        if (reason != entry.conflict.?) continue;
        const first = sequence[0];
        const seen = for (named.items) |t| {
            if (std.meta.eql(t, first)) break true;
        } else false;
        if (seen) continue;
        try named.append(a, first);
        if (named.items.len > 1) keys.writer.writeAll(", ") catch return error.OutOfMemory;
        shortcuts.writeTrigger(&keys.writer, first, .windows) catch return error.OutOfMemory;
    }
    const reason = entry.conflict orelse return;
    var note: std.Io.Writer.Allocating = .init(a);
    i18n.format(&note.writer, conflictTemplate(reason), .{ .keys = keys.written() }) catch return error.OutOfMemory;
    entry.conflict_note = note.written();
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

fn testEntries(a: Allocator, lines: []const []const u8, taken: []const struct { []const u8, Reason }) ![]Entry {
    var set: Binding.Set = .{};
    for (lines) |line| try set.parseAndPut(a, line);
    var blocked: shortcut_conflicts.Conflicts = .{};
    for (taken) |t| {
        const chord = shortcut_conflicts.chordOf(try Trigger.parse(t[0])).?;
        try blocked.list.append(a, .{ .chord = chord, .reason = t[1] });
    }
    var entries: std.ArrayList(Entry) = .empty;
    try collect(a, &entries, &set, &.{}, &blocked);
    return entries.items;
}

fn entryNamed(entries: []const Entry, action_text: []const u8) ?*const Entry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.action_text, action_text)) return entry;
    }
    return null;
}

test "collect orders the rows, names the actions and the taken keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try testEntries(a, &.{
        "ctrl+shift+c=copy_to_clipboard",
        "copy=copy_to_clipboard",
        "ctrl+insert=copy_to_clipboard",
        "ctrl+shift+o=new_split:right",
        "ctrl+shift+f>n=start_search",
        "ctrl+shift+w=close_tab",
        "ctrl+shift+t=new_tab",
        "alt+2=goto_tab:2",
    }, &.{
        .{ "ctrl+shift+c", .hotkey },
        .{ "ctrl+shift+o", .hotkey },
        .{ "ctrl+shift+f", .ime },
    });

    // The order of `gx.shortcuts`, not of the binding set.
    try testing.expectEqual(@as(usize, 6), entries.len);
    try testing.expectEqualStrings("new_tab", entries[0].action_text);
    try testing.expectEqualStrings("close_tab:this", entries[1].action_text);
    try testing.expectEqualStrings("goto_tab:2", entries[2].action_text);

    const goto = entryNamed(entries, "goto_tab:2").?;
    try testing.expectEqualStrings("Go to Tab (2)", goto.title_en);
    try testing.expectEqual(@as(?Reason, null), goto.conflict);

    // The media key goes last; the note names the taken key once.
    const copy = entryNamed(entries, "copy_to_clipboard:mixed").?;
    try testing.expectEqual(@as(usize, 3), copy.sequences.len);
    try testing.expect(copy.sequences[2][0].key == .physical);
    try testing.expectEqual(@as(?Reason, .hotkey), copy.conflict);
    try testing.expect(std.mem.indexOf(u8, copy.conflict_note, "Ctrl+Shift+C") != null);
    try testing.expect(std.mem.indexOf(u8, copy.conflict_note, "Insert") == null);

    const split = entryNamed(entries, "new_split:right").?;
    try testing.expectEqualStrings("Split Right", split.title_en);
    try testing.expectEqual(@as(?Reason, .hotkey), split.conflict);
    // A sequence is taken by its first chord.
    const search = entryNamed(entries, "start_search").?;
    try testing.expectEqual(@as(?Reason, .ime), search.conflict);
    try testing.expect(std.mem.indexOf(u8, search.conflict_note, "Ctrl+Shift+F") != null);
}

fn testRows(a: Allocator, entries: []const Entry, query: []const u8) ![]const Row {
    var matches: std.ArrayList(Match) = .empty;
    const search: shortcuts.Search = .init(query);
    try rank(a, &matches, entries, &search);
    var rows: std.ArrayList(Row) = .empty;
    try listRows(a, &rows, entries, matches.items);
    return rows.items;
}

fn rowText(entries: []const Entry, row: Row) []const u8 {
    return switch (row.kind) {
        .entry => |i| entries[i].action_text,
        .header => |category| category.title(),
        .notice => |reason| @tagName(reason),
    };
}

test "a key query matches exactly those keys and rows rank by score in their category" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try testEntries(a, &.{
        "ctrl+shift+t=new_tab",
        "ctrl+shift+w=close_tab",
        "ctrl+shift+o=new_split:right",
        "ctrl+shift+e=new_split:down",
        "ctrl+alt+up=goto_split:up",
        "ctrl+shift+enter=toggle_split_zoom",
    }, &.{});

    // No binding is exactly Ctrl+T.
    try testing.expectEqual(@as(usize, 0), (try testRows(a, entries, "ctrl+t")).len);
    const new_tab = try testRows(a, entries, "ctrl+shift+t");
    try testing.expectEqual(@as(usize, 2), new_tab.len);
    try testing.expectEqualStrings("new_tab", rowText(entries, new_tab[1]));

    // Every split row, under one header; the closest title first.
    const split = try testRows(a, entries, "split");
    try testing.expectEqualStrings("Splits", rowText(entries, split[0]));
    try testing.expect(std.mem.startsWith(u8, rowText(entries, split[1]), "new_split"));
    for (split[1..]) |row| try testing.expect(row.kind == .entry);

    // No search: all rows in sheet order.
    const all = try testRows(a, entries, "");
    try testing.expectEqualStrings("Tabs", rowText(entries, all[0]));
    try testing.expectEqualStrings("new_tab", rowText(entries, all[1]));
    try testing.expectEqualStrings("close_tab:this", rowText(entries, all[2]));
}

test "a notice heads the list for each reason a row on display has" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try testEntries(a, &.{
        "ctrl+shift+t=new_tab",
        "ctrl+shift+o=new_split:right",
        "ctrl+shift+f=start_search",
    }, &.{
        .{ "ctrl+shift+o", .hotkey },
        .{ "ctrl+shift+f", .ime },
    });
    const all = try testRows(a, entries, "");
    try testing.expectEqualStrings("hotkey", rowText(entries, all[0]));
    try testing.expectEqualStrings("ime", rowText(entries, all[1]));
    try testing.expectEqualStrings("Tabs", rowText(entries, all[2]));

    // Only the reasons of the rows a search shows.
    const tabs = try testRows(a, entries, "new tab");
    try testing.expectEqualStrings("Tabs", rowText(entries, tabs[0]));
    const split = try testRows(a, entries, "split right");
    try testing.expectEqualStrings("hotkey", rowText(entries, split[0]));
    try testing.expectEqualStrings("Splits", rowText(entries, split[1]));

    // Rows with taken keys are taller.
    const rows = try a.dupe(Row, all);
    const heights: std.EnumArray(Reason, f32) = .initFill(60);
    const content = placeRows(rows, entries, heights);
    try testing.expectEqual(layout.list_pad, rows[0].y);
    try testing.expectEqual(@as(f32, 60), rows[1].h);
    try testing.expectEqual(layout.header_height, rows[2].h);
    try testing.expectEqual(layout.row_height, rows[3].h);
    try testing.expectEqual(layout.conflict_row_height, rows[5].h);
    const last = rows[rows.len - 1];
    try testing.expectEqual(last.y + last.h + layout.list_pad, content);
}

test "the selection steps over entry rows and scrolls into view" {
    // notice, header, entry, entry, header, entry
    var rows = [_]Row{
        .{ .kind = .{ .notice = .hotkey } },
        .{ .kind = .{ .header = .tabs } },
        .{ .kind = .{ .entry = 0 } },
        .{ .kind = .{ .entry = 1 } },
        .{ .kind = .{ .header = .splits } },
        .{ .kind = .{ .entry = 2 } },
    };
    var y: f32 = layout.list_pad;
    for (&rows) |*row| {
        row.y = y;
        row.h = 40;
        y += 40;
    }
    try testing.expectEqual(@as(?usize, 2), firstEntry(&rows));
    try testing.expectEqual(@as(?usize, 5), lastEntry(&rows));
    try testing.expectEqual(@as(?usize, 2), stepSelection(&rows, null, 1));
    try testing.expectEqual(@as(?usize, 2), stepSelection(&rows, null, -1));
    try testing.expectEqual(@as(?usize, 3), stepSelection(&rows, 2, 1));
    try testing.expectEqual(@as(?usize, 5), stepSelection(&rows, 3, 1));
    try testing.expectEqual(@as(?usize, 5), stepSelection(&rows, 2, 10));
    try testing.expectEqual(@as(?usize, 2), stepSelection(&rows, 5, -10));
    try testing.expectEqual(@as(?usize, 3), stepSelection(&rows, 5, -1));
    try testing.expectEqual(@as(?usize, null), stepSelection(rows[0..2], null, 1));

    // Already in view: no scroll. The last entry scrolls to the bottom with
    // its header in view when the view is tall enough.
    try testing.expectEqual(@as(f32, 0), revealScroll(&rows, 3, 0, 200));
    try testing.expectApproxEqAbs(rows[5].y + rows[5].h + layout.list_pad - 100, revealScroll(&rows, 5, 0, 100), 1e-4);
    // Scrolled past: the first entry goes back to the top of the list, a
    // later one shows its header.
    try testing.expectEqual(@as(f32, 0), revealScroll(&rows, 2, 150, 100));
    try testing.expectEqual(rows[4].y, revealScroll(&rows, 5, 230, 100));
}

test "keys go to the search field, the list, the recording or the bindings" {
    const k = struct {
        fn key(vk: u16, ctrl: bool, shift: bool, alt: bool) Popup.Key {
            return .{ .vk = vk, .ctrl = ctrl, .shift = shift, .alt = alt };
        }
    }.key;
    // Typing and moving the caret.
    try testing.expectEqual(Command.edit, command(k('Q', false, false, false), false));
    try testing.expectEqual(Command.edit, command(k('Q', false, true, false), false));
    try testing.expectEqual(Command.edit, command(k(w32.VK_HOME, false, false, false), false));
    try testing.expectEqual(Command.edit, command(k(w32.VK_END, false, true, false), false));
    try testing.expectEqual(Command.edit, command(k(w32.VK_END, true, true, false), false));
    try testing.expectEqual(Command.edit, command(k(w32.VK_BACK, true, false, false), false));
    try testing.expectEqual(Command.edit, command(k(w32.VK_LEFT, true, true, false), false));
    try testing.expectEqual(Command.edit, command(k('V', true, true, false), false));
    try testing.expectEqual(Command.edit, command(k(w32.VK_PROCESSKEY, false, false, false), true));
    // The list.
    try testing.expectEqual(Command.first, command(k(w32.VK_HOME, true, false, false), false));
    try testing.expectEqual(Command.last, command(k(w32.VK_END, true, false, false), false));
    try testing.expectEqual(Command.next, command(k(w32.VK_DOWN, false, false, false), false));
    try testing.expectEqual(Command.previous, command(k(w32.VK_UP, false, true, false), false));
    try testing.expectEqual(Command.page_next, command(k(w32.VK_NEXT, false, false, false), false));
    try testing.expectEqual(Command.run, command(k(w32.VK_RETURN, false, false, false), false));
    try testing.expectEqual(Command.close, command(k(w32.VK_ESCAPE, false, false, false), false));
    try testing.expectEqual(Command.close_window, command(k(w32.VK_F4, false, false, true), false));
    // Bindings: Ctrl+Page Down switches tabs, Ctrl+Up is a chord.
    try testing.expectEqual(Command.chord, command(k(w32.VK_NEXT, true, false, false), false));
    try testing.expectEqual(Command.chord, command(k(w32.VK_UP, true, false, false), false));
    try testing.expectEqual(Command.chord, command(k('T', true, true, false), false));
    try testing.expectEqual(Command.chord, command(k('9', false, false, true), false));
    // Recording: Alt+K toggles it, Escape stops it, modifiers wait for the
    // key, every other key is recorded.
    try testing.expectEqual(Command.record_start, command(k('K', false, false, true), false));
    try testing.expectEqual(Command.record_stop, command(k('K', false, false, true), true));
    try testing.expectEqual(Command.record_stop, command(k(w32.VK_ESCAPE, false, false, false), true));
    try testing.expectEqual(Command.swallow, command(k(w32.VK_CONTROL, true, false, false), true));
    try testing.expectEqual(Command.swallow, command(k(0xA2, true, false, false), true));
    try testing.expectEqual(Command.record, command(k('T', true, true, false), true));
    try testing.expectEqual(Command.record, command(k(w32.VK_ESCAPE, true, false, false), true));
    try testing.expectEqual(Command.record, command(k(w32.VK_RETURN, false, false, false), true));
}

test "recorded keys read back as a key query of the same keys" {
    var buf: [4]u8 = undefined;
    // Keys of the typing area are named by the character they type.
    try testing.expectEqualStrings("T", keyName(.key_t, 'T', &buf).?);
    try testing.expectEqualStrings("Z", keyName(.key_y, 'Z', &buf).?);
    try testing.expectEqualStrings(",", keyName(.comma, ',', &buf).?);
    try testing.expectEqualStrings("\u{00E4}", keyName(.quote, 0xE4, &buf).?);
    // Characters a key query reads as syntax fall back to the key.
    try testing.expectEqualStrings("]", keyName(.bracket_right, '+', &buf).?);
    // Other keys by their label, or their tag name when the label has a
    // separator in it.
    try testing.expectEqualStrings("PgUp", keyName(.page_up, 0, &buf).?);
    try testing.expectEqualStrings("F5", keyName(.f5, 0, &buf).?);
    try testing.expectEqualStrings("numpad_add", keyName(.numpad_add, '+', &buf).?);
    try testing.expectEqualStrings("numpad_1", keyName(.numpad_1, '1', &buf).?);
    try testing.expectEqualStrings("Space", keyName(.space, ' ', &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), keyName(null, 0, &buf));

    const cases = [_]struct { input.Key, u32, input.Mods }{
        .{ .key_t, 'T', .{ .ctrl = true, .shift = true } },
        .{ .page_up, 0, .{ .ctrl = true } },
        .{ .numpad_add, '+', .{ .super = true } },
        .{ .f5, 0, .{} },
        .{ .comma, ',', .{ .ctrl = true } },
        .{ .enter, '\r', .{ .ctrl = true, .shift = true } },
        .{ .bracket_left, '[', .{ .super = true, .ctrl = true } },
        .{ .arrow_up, 0, .{ .super = true, .ctrl = true, .shift = true } },
    };
    for (cases) |case| {
        var text_buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&text_buf);
        try writer.writeByte('"');
        try writeChord(&writer, case[2], keyName(case[0], case[1], &buf).?);
        try writer.writeByte('"');
        const query: shortcuts.KeyQuery = .init(writer.buffered());
        const physical: Trigger = .{ .key = .{ .physical = case[0] }, .mods = case[2] };
        try testing.expect(query.score(&.{physical}) != null);
        // Not the same key with another modifier.
        var other = physical;
        other.mods.alt = !other.mods.alt;
        try testing.expect(query.score(&.{other}) == null);
    }

    // A character binding matches the key that types it.
    var text_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text_buf);
    try writeChord(&writer, .{ .ctrl = true, .shift = true }, keyName(.key_t, 'T', &buf).?);
    const query: shortcuts.KeyQuery = .init(writer.buffered());
    try testing.expect(query.score(&.{try Trigger.parse("ctrl+shift+t")}) != null);
    try testing.expectEqualStrings("Ctrl+Shift+T", writer.buffered());
}

test "recording goes on with a sequence after a leader key" {
    // Function keys map to the same physical key with every layout.
    const alloc = testing.allocator;
    var set: Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "ctrl+f7>f8=new_tab");
    try set.parseAndPut(alloc, "ctrl+f5=new_window");

    var recording: Recording = .{ .active = true };
    const ctrl: input.Mods = .{ .ctrl = true };
    recording.add(&set, .{ .vk = w32.VK_F7, .mods = ctrl });
    recording.add(&set, .{ .vk = w32.VK_F8, .mods = .{} });
    try testing.expectEqual(@as(usize, 2), recording.len);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\"Ctrl+F7>F8\"", recording.query(&buf));
    const query: shortcuts.KeyQuery = .init(recording.query(&buf));
    try testing.expect(query.score(&.{ try Trigger.parse("ctrl+f7"), try Trigger.parse("f8") }) != null);

    // The sequence ended: the next key starts a new search, and so does a
    // key after one that is no leader.
    recording.add(&set, .{ .vk = w32.VK_F5, .mods = ctrl });
    try testing.expectEqual(@as(usize, 1), recording.len);
    recording.add(&set, .{ .vk = w32.VK_F7, .mods = ctrl });
    try testing.expectEqual(@as(usize, 1), recording.len);
    try testing.expectEqualStrings("\"Ctrl+F7\"", recording.query(&buf));
}

test "the native list has one line per row under its category, notices first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try testEntries(a, &.{
        "ctrl+shift+t=new_tab",
        "ctrl+a>n=new_window",
        "ctrl+shift+o=new_split:right",
        "ctrl+shift+c=copy_to_clipboard",
        "ctrl+insert=copy_to_clipboard",
    }, &.{.{ "ctrl+shift+o", .hotkey }});
    try testing.expectEqual(@as(usize, 4), entries.len);
    const new_tab = entryNamed(entries, "new_tab").?;
    const split = entryNamed(entries, "new_split:right").?;
    const new_window = entryNamed(entries, "new_window").?;
    const copy = entryNamed(entries, "copy_to_clipboard:mixed").?;

    const expected = [_][]const u8{
        noticeText(.hotkey),
        "",
        i18n.trRuntime(shortcuts.Category.tabs.title()),
        try std.fmt.allocPrint(a, "    {s} \u{2014} Ctrl+Shift+T", .{new_tab.title}),
        "",
        i18n.trRuntime(shortcuts.Category.splits.title()),
        try std.fmt.allocPrint(a, "    {s} \u{2014} Ctrl+Shift+O ({s})", .{ split.title, split.conflict_note }),
        "",
        i18n.trRuntime(shortcuts.Category.windows.title()),
        try std.fmt.allocPrint(a, "    {s} \u{2014} Ctrl+A \u{2192} N", .{new_window.title}),
        "",
        i18n.trRuntime(shortcuts.Category.clipboard.title()),
        try std.fmt.allocPrint(a, "    {s} \u{2014} Ctrl+Insert, Ctrl+Shift+C", .{copy.title}),
        "",
    };
    const text = try listText(a, entries, "\r\n");
    var lines = std.mem.splitSequence(u8, text, "\r\n");
    for (expected) |line| try testing.expectEqualStrings(line, lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());

    // Without taken keys the list starts with its first category.
    const plain = try listText(a, entries[0..1], "\n");
    try testing.expect(std.mem.startsWith(u8, plain, i18n.trRuntime(shortcuts.Category.tabs.title())));
}

test "TaskDialog structures use the packed Windows ABI" {
    try testing.expectEqual(@as(usize, 1), @alignOf(TaskDialogConfig));
    try testing.expectEqual(@as(usize, 4), @offsetOf(TaskDialogConfig, "hwndParent"));
    try testing.expectEqual(@as(usize, 4 + @sizeOf(usize)), @sizeOf(TaskDialogButton));
    try testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 160 else 96), @sizeOf(TaskDialogConfig));
}

test "GHOSTTY_GX_A11Y=screen-reader turns the native list on" {
    try testing.expect(isScreenReaderValue("screen-reader"));
    try testing.expect(isScreenReaderValue(" Screen-Reader\n"));
    try testing.expect(!isScreenReaderValue("1"));
    try testing.expect(!isScreenReaderValue(""));
    try testing.expect(!isScreenReaderValue("screen"));
}

test "the sheet takes the keyboard and keeps its window painted as active" {
    const t = style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    const options = popupOptions(t);
    try testing.expect(options.activate);
    try testing.expect(options.keep_owner_active);
    try testing.expect(options.text_input);
    try testing.expect(options.dark);
    try testing.expectEqual(t.border, options.border_color.?);
}

test "the sheet sits centered below the chrome at the window's scale" {
    // 1500 × 1000 DIPs at 150 %: the largest sheet, centered under 40 DIPs
    // of chrome.
    const big = placement(2250, 1500, 60, 1.5);
    try testing.expectEqual(@as(i32, style.px(layout.width_max, 1.5)), big.right - big.left);
    try testing.expectEqual(@as(i32, style.px(layout.height_max, 1.5)), big.bottom - big.top);
    try testing.expectEqual(@divTrunc(2250 - (big.right - big.left), 2), big.left);
    try testing.expect(big.top >= 60);
    // A small window keeps the minimum size; a simulated 192 dpi doubles
    // it in pixels.
    const small = placement(400, 300, 40, 1.0);
    try testing.expectEqual(@as(i32, @intFromFloat(layout.width_min)), small.right - small.left);
    try testing.expectEqual(@as(i32, 40), small.top);
    const doubled = placement(800, 600, 80, 2.0);
    try testing.expectEqual(2 * (small.right - small.left), doubled.right - doubled.left);
    try testing.expectEqual(2 * (small.bottom - small.top), doubled.bottom - doubled.top);
}
