//! The keyboard shortcut sheets of both apprts: their model, key names and
//! search.
//!
//! `collect` lists the bindings of a configuration as rows, one per
//! action (or chain of actions) with every key sequence that runs it.
//! Rows are ordered by `Category`, then by a fixed table of actions
//! (`place`), then by the action text with numbers compared by value
//! (`goto_tab:2` before `goto_tab:10`), so the order does not depend on
//! the hash order of the binding set. `title` names an action by its
//! command palette title (msgids for `gx.i18n`).
//!
//! Keys show their modifiers in one order, Win (Super on GTK), Ctrl, Alt,
//! Shift, and the names of `keyLabel`. `Search` finds rows by title
//! (`fuzzy`) and by keys (`KeyQuery`): a query written as keys (`ctrl+t`,
//! `shift+ctrl+t`, `ctrl+a>n`, or quoted) matches only key sequences
//! whose chords have exactly those modifiers, in any order, and that key,
//! where the last key still being typed may be the start of a key name;
//! any other query also matches keys word by word, each word naming a
//! modifier or beginning a word of a key name (`page` finds Page Up), and
//! one-letter words naming the whole key.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const fuzzy = @import("fuzzy.zig");

const Binding = input.Binding;
const Action = Binding.Action;
const Trigger = Binding.Trigger;

pub const Category = enum {
    tabs,
    splits,
    windows,
    clipboard,
    font,
    scrolling,
    search,
    terminal,
    application,
    other,

    /// The msgid of the category title.
    pub fn title(self: Category) [:0]const u8 {
        return switch (self) {
            .tabs => "Tabs",
            .splits => "Splits",
            .windows => "Windows",
            .clipboard => "Clipboard and Selection",
            .font => "Font Size",
            .scrolling => "Scrolling",
            .search => "Search",
            .terminal => "Terminal",
            .application => "Application",
            .other => "Other",
        };
    }
};

/// Where an action goes in the sheet: its category and its place there.
pub const Place = struct {
    category: Category,
    rank: u16,
};

/// The binding actions of each category, in sheet order. Actions that are
/// not listed, such as ones added upstream later, go to `other`.
const table = [_]struct { []const u8, Category }{
    .{ "new_tab", .tabs },
    .{ "close_tab", .tabs },
    .{ "previous_tab", .tabs },
    .{ "next_tab", .tabs },
    .{ "last_tab", .tabs },
    .{ "goto_tab", .tabs },
    .{ "move_tab", .tabs },
    .{ "move_tab_to_new_window", .tabs },
    .{ "toggle_tab_overview", .tabs },
    .{ "prompt_tab_title", .tabs },
    .{ "set_tab_title", .tabs },
    .{ "new_split", .splits },
    .{ "close_surface", .splits },
    .{ "goto_split", .splits },
    .{ "toggle_split_zoom", .splits },
    .{ "resize_split", .splits },
    .{ "equalize_splits", .splits },
    .{ "prompt_surface_title", .splits },
    .{ "set_surface_title", .splits },
    .{ "new_window", .windows },
    .{ "close_window", .windows },
    .{ "close_all_windows", .windows },
    .{ "goto_window", .windows },
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
    .{ "scroll_to_top", .scrolling },
    .{ "scroll_to_bottom", .scrolling },
    .{ "scroll_page_up", .scrolling },
    .{ "scroll_page_down", .scrolling },
    .{ "scroll_page_fractional", .scrolling },
    .{ "scroll_page_lines", .scrolling },
    .{ "scroll_to_selection", .scrolling },
    .{ "scroll_to_row", .scrolling },
    .{ "jump_to_prompt", .scrolling },
    .{ "start_search", .search },
    .{ "search", .search },
    .{ "search_selection", .search },
    .{ "navigate_search", .search },
    .{ "end_search", .search },
    .{ "reset", .terminal },
    .{ "clear_screen", .terminal },
    .{ "text", .terminal },
    .{ "csi", .terminal },
    .{ "esc", .terminal },
    .{ "cursor_key", .terminal },
    .{ "toggle_readonly", .terminal },
    .{ "toggle_mouse_reporting", .terminal },
    .{ "toggle_secure_input", .terminal },
    .{ "show_on_screen_keyboard", .terminal },
    .{ "undo", .terminal },
    .{ "redo", .terminal },
    .{ "toggle_command_palette", .application },
    .{ "gx", .application },
    .{ "open_config", .application },
    .{ "reload_config", .application },
    .{ "inspector", .application },
    .{ "show_gtk_inspector", .application },
    .{ "check_for_updates", .application },
    .{ "quit", .application },
};

const places: std.StaticStringMap(Place) = blk: {
    @setEvalBranchQuota(20_000);
    var entries: [table.len]struct { []const u8, Place } = undefined;
    for (table, &entries, 0..) |entry, *out, i| out.* = .{ entry[0], .{ .category = entry[1], .rank = @intCast(i) } };
    break :blk .initComptime(entries);
};

/// The place of `action` in the sheet.
pub fn place(action: Action) Place {
    return places.get(@tagName(std.meta.activeTag(action))) orelse .{ .category = .other, .rank = table.len };
}

pub fn category(action: Action) Category {
    return place(action).category;
}

/// One row of the sheet.
pub const Row = struct {
    category: Category,
    rank: u16,
    /// The actions run, in order; more than one for chained bindings.
    actions: []const Action,
    /// The key sequences that run them, leader keys first: single keys
    /// before sequences.
    sequences: []const []const Trigger,
    /// The actions in configuration syntax, `, `-separated.
    text: []const u8,
};

/// The rows for the bindings of `set` (see the file header). Leader
/// sequences are followed; `ignore` and `unbind` bindings and catch-all
/// keys are left out. Everything, the actions included, is copied into
/// `arena`, so the rows outlive a configuration reload.
pub fn collect(arena: Allocator, set: *const Binding.Set) Allocator.Error![]Row {
    var builders: std.ArrayList(Builder) = .empty;
    try walk(arena, &builders, set, &.{});
    const rows = try arena.alloc(Row, builders.items.len);
    for (builders.items, rows) |*builder, *row| {
        std.mem.sort([]const Trigger, builder.sequences.items, {}, sequenceLessThan);
        var text: std.Io.Writer.Allocating = .init(arena);
        for (builder.actions, 0..) |action, i| {
            if (i > 0) text.writer.writeAll(", ") catch return error.OutOfMemory;
            text.writer.print("{f}", .{action}) catch return error.OutOfMemory;
        }
        const where = place(builder.actions[0]);
        row.* = .{
            .category = where.category,
            .rank = where.rank,
            .actions = builder.actions,
            .sequences = builder.sequences.items,
            .text = text.written(),
        };
    }
    std.mem.sort(Row, rows, {}, rowLessThan);
    return rows;
}

const Builder = struct {
    actions: []const Action,
    sequences: std.ArrayList([]const Trigger) = .empty,
};

fn walk(
    arena: Allocator,
    builders: *std.ArrayList(Builder),
    set: *const Binding.Set,
    prefix: []const Trigger,
) Allocator.Error!void {
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const trigger = entry.key_ptr.*;
        if (trigger.key == .catch_all) continue;
        const sequence = try std.mem.concat(arena, Trigger, &.{ prefix, &.{trigger} });
        switch (entry.value_ptr.*) {
            .leader => |next| try walk(arena, builders, next, sequence),
            .leaf => |*leaf| try add(arena, builders, (&leaf.action)[0..1], sequence),
            .leaf_chained => |chained| try add(arena, builders, chained.actions.items, sequence),
        }
    }
}

fn add(
    arena: Allocator,
    builders: *std.ArrayList(Builder),
    actions: []const Action,
    sequence: []const Trigger,
) Allocator.Error!void {
    if (actions.len == 0) return;
    switch (actions[0]) {
        .ignore, .unbind => return,
        else => {},
    }
    for (builders.items) |*builder| {
        if (sameActions(builder.actions, actions)) {
            try builder.sequences.append(arena, sequence);
            return;
        }
    }
    const copies = try arena.alloc(Action, actions.len);
    for (actions, copies) |action, *copy| copy.* = try action.clone(arena);
    var builder: Builder = .{ .actions = copies };
    try builder.sequences.append(arena, sequence);
    try builders.append(arena, builder);
}

fn sameActions(a: []const Action, b: []const Action) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.equal(y)) return false;
    return true;
}

fn rowLessThan(_: void, a: Row, b: Row) bool {
    if (a.category != b.category) return @backingInt(a.category) < @backingInt(b.category);
    if (a.rank != b.rank) return a.rank < b.rank;
    return naturalOrder(a.text, b.text) == .lt;
}

fn sequenceLessThan(_: void, a: []const Trigger, b: []const Trigger) bool {
    if (a.len != b.len) return a.len < b.len;
    for (a, b) |x, y| {
        const order = triggerOrder(x, y);
        if (order != .eq) return order == .lt;
    }
    return false;
}

/// Triggers with fewer modifiers first, then by key.
fn triggerOrder(a: Trigger, b: Trigger) std.math.Order {
    const ma = modifiersOf(a.mods);
    const mb = modifiersOf(b.mods);
    if (@popCount(ma) != @popCount(mb)) return std.math.order(@popCount(ma), @popCount(mb));
    if (ma != mb) return std.math.order(ma, mb);
    const ka = keyOrder(a.key);
    const kb = keyOrder(b.key);
    return std.math.order(ka, kb);
}

fn keyOrder(key: Trigger.Key) u64 {
    return switch (key) {
        .unicode => |cp| cp,
        .physical => |k| (1 << 32) + @as(u64, @intCast(@backingInt(k))),
        .catch_all => 1 << 40,
    };
}

/// Orders `a` and `b` byte by byte, but runs of digits by their value
/// (`goto_tab:2` before `goto_tab:10`).
pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const a_end = digitsEnd(a, i);
            const b_end = digitsEnd(b, j);
            const a_num = std.mem.trimStart(u8, a[i..a_end], "0");
            const b_num = std.mem.trimStart(u8, b[j..b_end], "0");
            if (a_num.len != b_num.len) return std.math.order(a_num.len, b_num.len);
            const by_value = std.mem.order(u8, a_num, b_num);
            if (by_value != .eq) return by_value;
            i = a_end;
            j = b_end;
            continue;
        }
        if (a[i] != b[j]) return std.math.order(a[i], b[j]);
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

fn digitsEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return end;
}

pub const Title = struct {
    /// The msgid of the title, or the title of a configured command
    /// palette entry as written.
    msgid: [:0]const u8,
    /// The title names this exact action, argument included; otherwise
    /// callers append the argument (`argument`).
    exact: bool,
};

/// The title of `action`: that of an equal configured (`commands`) command
/// palette entry, else an equal default entry. Text, CSI and ESC actions
/// then use their generic titles; other actions use the only default entry
/// with the same action name, else a Ghostty GX title for the action name.
/// Null when there is none; callers show the action itself.
pub fn title(action: Action, commands: []const input.Command) ?Title {
    for (commands) |command| {
        if (command.action.equal(action)) return .{ .msgid = command.title, .exact = true };
    }
    for (input.command.defaults) |command| {
        if (command.action.equal(action)) return .{ .msgid = command.title, .exact = true };
    }

    const tag = std.meta.activeTag(action);
    switch (tag) {
        .text, .csi, .esc => return .{ .msgid = fallback_titles.get(@tagName(tag)).?, .exact = false },
        else => {},
    }
    var same_name: ?[:0]const u8 = null;
    var count: usize = 0;
    for (input.command.defaults) |command| {
        if (std.meta.activeTag(command.action) != tag) continue;
        same_name = command.title;
        count += 1;
    }
    if (count == 1) return .{ .msgid = same_name.?, .exact = false };

    const msgid = if (action == .gx)
        gx_titles.get(@tagName(std.meta.activeTag(action.gx)))
    else
        fallback_titles.get(@tagName(tag));
    return .{ .msgid = msgid orelse return null, .exact = false };
}

/// The argument of an action from its configuration syntax: the text
/// after the first colon, or for `gx:` actions after the GX action name.
pub fn argument(formatted: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, formatted, "gx:")) formatted["gx:".len..] else formatted;
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const arg = rest[colon + 1 ..];
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

const gx_titles: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "settings", "Settings…" },
    .{ "main_menu", "Main Menu" },
    .{ "keybinds", "Keyboard Shortcuts" },
    .{ "new_tab_profile", "New Tab with Profile" },
    .{ "new_window_profile", "New Window with Profile" },
});

/// How keys are named.
pub const Style = enum {
    /// Win, PgUp, PgDn, PrtSc.
    windows,
    /// Super, Page Up, Page Down, Print.
    gtk,

    /// The style of the apprt this is built for.
    pub const native: Style = if (builtin.target.os.tag == .windows) .windows else .gtk;
};

pub const Modifier = enum(u2) {
    super,
    ctrl,
    alt,
    shift,

    /// The order modifiers are shown in.
    pub const order = [_]Modifier{ .super, .ctrl, .alt, .shift };

    pub fn label(self: Modifier, style: Style) []const u8 {
        return switch (self) {
            .super => if (style == .windows) "Win" else "Super",
            .ctrl => "Ctrl",
            .alt => "Alt",
            .shift => "Shift",
        };
    }

    fn bit(self: Modifier) u4 {
        return @as(u4, 1) << @backingInt(self);
    }
};

/// The modifiers of `mods` as a set (`Modifier.bit`).
fn modifiersOf(mods: input.Mods) u4 {
    var set: u4 = 0;
    if (mods.super) set |= Modifier.super.bit();
    if (mods.ctrl) set |= Modifier.ctrl.bit();
    if (mods.alt) set |= Modifier.alt.bit();
    if (mods.shift) set |= Modifier.shift.bit();
    return set;
}

/// Names a modifier is searched by.
const modifier_names = [_]struct { []const u8, Modifier }{
    .{ "super", .super },
    .{ "win", .super },
    .{ "windows", .super },
    .{ "cmd", .super },
    .{ "command", .super },
    .{ "meta", .super },
    .{ "logo", .super },
    .{ "ctrl", .ctrl },
    .{ "control", .ctrl },
    .{ "ctl", .ctrl },
    .{ "alt", .alt },
    .{ "opt", .alt },
    .{ "option", .alt },
    .{ "shift", .shift },
};

fn modifierNamed(word: []const u8) ?Modifier {
    for (modifier_names) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    }
    return null;
}

/// The modifiers with a name that `word` begins.
fn modifiersBegun(word: []const u8) u4 {
    var set: u4 = 0;
    for (modifier_names) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry[0], word)) set |= entry[1].bit();
    }
    return set;
}

const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const digits = "0123456789";

const function_keys = blk: {
    var names: [25][]const u8 = undefined;
    for (&names, 1..) |*name, i| name.* = std.fmt.comptimePrint("F{d}", .{i});
    break :blk names;
};

const numpad_digits = blk: {
    var names: [10][]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("Num {d}", .{i});
    break :blk names;
};

fn offset(key: input.Key, first: input.Key, last: input.Key) ?usize {
    const k = @backingInt(key);
    if (k < @backingInt(first) or k > @backingInt(last)) return null;
    return @intCast(k - @backingInt(first));
}

/// The display name of a physical key, or null when it has none (media
/// and browser keys and the like).
pub fn physicalLabel(key: input.Key, style: Style) ?[]const u8 {
    if (offset(key, .key_a, .key_z)) |i| return letters[i..][0..1];
    if (offset(key, .digit_0, .digit_9)) |i| return digits[i..][0..1];
    if (offset(key, .f1, .f25)) |i| return function_keys[i];
    if (offset(key, .numpad_0, .numpad_9)) |i| return numpad_digits[i];
    return switch (key) {
        .space => "Space",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Escape",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => if (style == .windows) "PgUp" else "Page Up",
        .page_down => if (style == .windows) "PgDn" else "Page Down",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Delete",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .semicolon => ";",
        .quote => "'",
        .bracket_left => "[",
        .bracket_right => "]",
        .backslash, .intl_backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        .numpad_add => "Num +",
        .numpad_subtract => "Num -",
        .numpad_multiply => "Num *",
        .numpad_divide => "Num /",
        .numpad_decimal => "Num .",
        .numpad_enter => "Num Enter",
        .numpad_equal => "Num =",
        .caps_lock => "Caps Lock",
        .num_lock => "Num Lock",
        .scroll_lock => "Scroll Lock",
        .print_screen => if (style == .windows) "PrtSc" else "Print",
        .pause => "Pause",
        .context_menu => "Menu",
        else => null,
    };
}

/// Room for any key label (`keyLabel`): the longest is a key's tag name.
pub const max_key_label = blk: {
    @setEvalBranchQuota(10_000);
    var len = 4;
    for (std.meta.fieldNames(input.Key)) |name| len = @max(len, name.len);
    break :blk len;
};

/// The name of the key of a trigger, written into `buf` when it is not a
/// constant: `physicalLabel`, else the tag name; a character key
/// upper-cased if it is an ASCII letter, `Space` for a space, nothing for
/// control characters; nothing for the catch-all key.
pub fn keyLabel(key: Trigger.Key, style: Style, buf: *[max_key_label]u8) []const u8 {
    return switch (key) {
        .physical => |k| physicalLabel(k, style) orelse @tagName(k),
        .unicode => |cp| codepointLabel(cp, buf),
        .catch_all => "",
    };
}

fn codepointLabel(cp: u21, buf: *[max_key_label]u8) []const u8 {
    if (cp >= 'a' and cp <= 'z') return letters[cp - 'a' ..][0..1];
    if (cp == ' ') return "Space";
    if (cp < 0x20 or cp == 0x7F) return "";
    const len = std.unicode.utf8Encode(cp, buf) catch return "";
    return buf[0..len];
}

/// Whether the key of `trigger` has a display name rather than a tag name
/// or nothing (`keyLabel`).
pub fn hasLabel(trigger: Trigger) bool {
    return switch (trigger.key) {
        .unicode => |cp| cp >= 0x20 and cp != 0x7F,
        .physical => |k| physicalLabel(k, .windows) != null,
        .catch_all => false,
    };
}

/// The keycaps of a trigger: its modifiers in `Modifier.order`, then its
/// key.
pub const Keycaps = struct {
    mods: [4][]const u8 = undefined,
    mods_len: usize = 0,
    key_buf: [max_key_label]u8 = undefined,
    key_len: usize = 0,

    pub fn init(trigger: Trigger, style: Style) Keycaps {
        var self: Keycaps = .{};
        const set = modifiersOf(trigger.mods);
        for (Modifier.order) |mod| {
            if (set & mod.bit() == 0) continue;
            self.mods[self.mods_len] = mod.label(style);
            self.mods_len += 1;
        }
        var buf: [max_key_label]u8 = undefined;
        const label = keyLabel(trigger.key, style, &buf);
        @memcpy(self.key_buf[0..label.len], label);
        self.key_len = label.len;
        return self;
    }

    pub fn count(self: *const Keycaps) usize {
        return self.mods_len + @intFromBool(self.key_len > 0);
    }

    /// The label of keycap `i` (< `count`).
    pub fn get(self: *const Keycaps, i: usize) []const u8 {
        if (i < self.mods_len) return self.mods[i];
        return self.key_buf[0..self.key_len];
    }
};

/// Writes a trigger as keycaps joined by `+` (`Ctrl+Shift+T`).
pub fn writeTrigger(writer: *std.Io.Writer, trigger: Trigger, style: Style) std.Io.Writer.Error!void {
    const caps: Keycaps = .init(trigger, style);
    for (0..caps.count()) |i| {
        if (i > 0) try writer.writeByte('+');
        try writer.writeAll(caps.get(i));
    }
}

/// Writes a key sequence, leader keys first, with `separator` between the
/// steps (` → ` on win32).
pub fn writeSequence(
    writer: *std.Io.Writer,
    sequence: []const Trigger,
    style: Style,
    separator: []const u8,
) std.Io.Writer.Error!void {
    for (sequence, 0..) |trigger, i| {
        if (i > 0) try writer.writeAll(separator);
        try writeTrigger(writer, trigger, style);
    }
}

/// How well a word names a key, weakest first.
const Fit = enum(u2) { none, word, prefix, exact };

/// How a word may name a key: only as a whole name, also as the start of
/// one, or also as the start of a word of one.
const Mode = enum { exact, prefix, word };

/// How well `word` names `key` in `mode`: the whole of one of its names
/// (`exact`), the start of one (`prefix`), or the start of a word of one,
/// words being separated by spaces and underscores (`word`). The names of
/// a key are its labels in both styles, its tag name with and without
/// underscores, a few short forms, and for a character key the names of
/// the physical key that types it.
fn fitKey(key: Trigger.Key, word: []const u8, mode: Mode) Fit {
    var best: Fit = .none;
    var buf: [max_key_label]u8 = undefined;
    switch (key) {
        .catch_all => return .none,
        .physical => |k| best = fitPhysical(k, word, mode),
        .unicode => |cp| {
            best = fitName(codepointLabel(cp, &buf), word, mode);
            if (cp < 0x80) {
                if (input.Key.fromASCII(@intCast(cp))) |k| best = better(best, fitPhysical(k, word, mode));
            }
        },
    }
    return best;
}

fn fitPhysical(key: input.Key, word: []const u8, mode: Mode) Fit {
    var best: Fit = .none;
    for ([_]Style{ .windows, .gtk }) |style| {
        if (physicalLabel(key, style)) |label| best = better(best, fitName(label, word, mode));
    }
    const tag = @tagName(key);
    best = better(best, fitName(tag, word, mode));
    var buf: [max_key_label]u8 = undefined;
    var len: usize = 0;
    for (tag) |c| {
        if (c == '_') continue;
        buf[len] = c;
        len += 1;
    }
    best = better(best, fitName(buf[0..len], word, mode));
    const short: ?[]const u8 = switch (key) {
        .escape => "esc",
        .enter => "return",
        .delete => "del",
        .insert => "ins",
        .backspace => "bksp",
        else => null,
    };
    if (short) |name| best = better(best, fitName(name, word, mode));
    return best;
}

fn fitName(name: []const u8, word: []const u8, mode: Mode) Fit {
    if (name.len == 0 or word.len == 0) return .none;
    if (std.ascii.eqlIgnoreCase(name, word)) return .exact;
    if (mode != .exact and std.ascii.startsWithIgnoreCase(name, word)) return .prefix;
    if (mode == .word) {
        var words = std.mem.tokenizeAny(u8, name, " _");
        while (words.next()) |part| {
            if (std.ascii.startsWithIgnoreCase(part, word)) return .word;
        }
    }
    return .none;
}

fn better(a: Fit, b: Fit) Fit {
    return if (@backingInt(b) > @backingInt(a)) b else a;
}

/// A search of key sequences (see the file header).
pub const KeyQuery = struct {
    text: [max_text]u8 = undefined,
    tokens: [max_tokens]Token = undefined,
    token_count: u8 = 0,
    steps: [max_steps]Step = undefined,
    step_count: u8 = 0,
    /// Written as keys.
    chord: bool = false,
    /// Quoted: every key name is whole, even the last.
    exact: bool = false,
    /// A chord with two keys in one step, which nothing matches.
    invalid: bool = false,

    const max_text = 128;
    const max_tokens = 16;
    const max_steps = 4;

    const Token = struct { start: u8, len: u8 };

    const Step = struct {
        mods: u4 = 0,
        /// The token naming the key, if any.
        key: ?u8 = null,
        /// The key token is still being typed and may be the start of a
        /// key name, or of the name of a modifier in `begun`.
        open: bool = false,
        begun: u4 = 0,
    };

    pub fn init(query: []const u8) KeyQuery {
        var self: KeyQuery = .{};
        var len: usize = 0;
        var i: usize = 0;
        while (i < query.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(query[i]) catch 1;
            const whole = i + seq_len <= query.len;
            var cp: u21 = if (whole) std.unicode.utf8Decode(query[i..][0..seq_len]) catch 0xFFFD else 0xFFFD;
            i += if (whole) seq_len else 1;
            if (cp >= 0xFF01 and cp <= 0xFF5E) cp -= 0xFEE0;
            if (cp == 0x3000) cp = ' ';
            if (cp >= 'A' and cp <= 'Z') cp += 'a' - 'A';
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &encoded) catch continue;
            if (len + n > max_text) break;
            @memcpy(self.text[len..][0..n], encoded[0..n]);
            len += n;
        }
        // The last key is still being typed unless a separator follows it.
        const typing = len > 0 and std.mem.indexOfScalar(u8, "+> \t\n\r\x0b\x0c", self.text[len - 1]) == null;
        var text: []const u8 = std.mem.trim(u8, self.text[0..len], &std.ascii.whitespace);
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            self.exact = true;
            text = std.mem.trim(u8, text[1 .. text.len - 1], &std.ascii.whitespace);
        }
        if (text.len == 0) return self;
        self.chord = self.exact or std.mem.indexOfAny(u8, text, "+>") != null;
        if (!self.chord) {
            var words = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
            while (words.next()) |word| self.addToken(word) orelse break;
            return self;
        }

        var steps = std.mem.splitScalar(u8, text, '>');
        while (steps.next()) |step_text| {
            if (self.step_count == max_steps) break;
            var step: Step = .{};
            var rest = std.mem.trim(u8, step_text, &std.ascii.whitespace);
            // `ctrl++` is Ctrl with the `+` key.
            var plus: ?[]const u8 = null;
            if (std.mem.endsWith(u8, rest, "++")) {
                plus = rest[rest.len - 1 ..];
                rest = rest[0 .. rest.len - 1];
            }
            var parts = std.mem.tokenizeAny(u8, rest, "+ \t\n\r\x0b\x0c");
            while (parts.next()) |part| {
                if (modifierNamed(part)) |mod| {
                    step.mods |= mod.bit();
                    continue;
                }
                if (step.key != null) self.invalid = true;
                step.key = self.token_count;
                self.addToken(part) orelse break;
            }
            if (plus) |key| {
                if (step.key != null) self.invalid = true;
                step.key = self.token_count;
                self.addToken(key) orelse {};
            }
            self.steps[self.step_count] = step;
            self.step_count += 1;
        }
        const open = typing and !self.exact;
        if (open and self.step_count > 0) {
            const last = &self.steps[self.step_count - 1];
            if (last.key) |key| {
                if (key + 1 == self.token_count) {
                    last.open = true;
                    last.begun = modifiersBegun(self.token(key)) & ~last.mods;
                }
            }
        }
        return self;
    }

    /// Adds `word`, a slice of `text`, as the next token; null when there
    /// is no room.
    fn addToken(self: *KeyQuery, word: []const u8) ?void {
        if (self.token_count == max_tokens) return null;
        const start = @intFromPtr(word.ptr) - @intFromPtr(&self.text);
        self.tokens[self.token_count] = .{ .start = @intCast(start), .len = @intCast(word.len) };
        self.token_count += 1;
    }

    fn token(self: *const KeyQuery, i: usize) []const u8 {
        const t = self.tokens[i];
        return self.text[t.start..][0..t.len];
    }

    pub fn isEmpty(self: *const KeyQuery) bool {
        return self.token_count == 0 and self.step_count == 0;
    }

    /// Whether the query is written as keys, so that only key sequences
    /// should match it, not titles.
    pub fn isChord(self: *const KeyQuery) bool {
        return self.chord;
    }

    /// The score of a key sequence (leader keys first) for the query, null
    /// when it does not match. Higher is better.
    pub fn score(self: *const KeyQuery, sequence: []const Trigger) ?i32 {
        if (sequence.len == 0 or self.isEmpty() or self.invalid) return null;
        return if (self.chord) self.chordScore(sequence) else self.wordScore(sequence);
    }

    /// The best `score` of `sequences`.
    pub fn scoreAny(self: *const KeyQuery, sequences: []const []const Trigger) ?i32 {
        var best: ?i32 = null;
        for (sequences) |sequence| {
            const s = self.score(sequence) orelse continue;
            best = if (best) |b| @max(b, s) else s;
        }
        return best;
    }

    /// The steps of the query match consecutive steps of the sequence;
    /// matching from its first step and covering all of it score more.
    fn chordScore(self: *const KeyQuery, sequence: []const Trigger) ?i32 {
        const n = self.step_count;
        if (n == 0 or n > sequence.len) return null;
        var best: ?i32 = null;
        for (0..sequence.len - n + 1) |start| {
            var total: i32 = 0;
            for (self.steps[0..n], sequence[start..][0..n]) |step, trigger| {
                total += self.stepScore(step, trigger) orelse break;
            } else {
                total -= 5 * @as(i32, @intCast(sequence.len - n));
                if (start == 0) total += 10;
                best = if (best) |b| @max(b, total) else total;
            }
        }
        return best;
    }

    fn stepScore(self: *const KeyQuery, step: Step, trigger: Trigger) ?i32 {
        const mods = modifiersOf(trigger.mods);
        const key = step.key orelse return if (step.mods != 0 and mods == step.mods) 60 else null;
        const word = self.token(key);
        const mode: Mode = if (step.open and word.len > 1) .prefix else .exact;
        const fit = fitKey(trigger.key, word, mode);
        if (fit != .none and mods == step.mods) return if (fit == .exact) 100 else 80;
        // The word being typed may begin a modifier name instead.
        if (step.open and mods & step.mods == step.mods) {
            const extra = mods & ~step.mods;
            if (extra != 0 and extra & step.begun == extra and @popCount(extra) == 1) return 50;
        }
        return null;
    }

    /// Every word must name a modifier of some step of the sequence or fit
    /// the key of some step.
    fn wordScore(self: *const KeyQuery, sequence: []const Trigger) ?i32 {
        var total: i32 = 0;
        for (0..self.token_count) |i| {
            const word = self.token(i);
            const mode: Mode = if (word.len > 1) .word else .exact;
            const named = modifierNamed(word);
            var best: ?i32 = null;
            for (sequence) |trigger| {
                if (named) |mod| {
                    if (modifiersOf(trigger.mods) & mod.bit() != 0) best = @max(best orelse 0, 10);
                }
                const fit: i32 = switch (fitKey(trigger.key, word, mode)) {
                    .none => continue,
                    .word => 15,
                    .prefix => 20,
                    .exact => 30,
                };
                best = @max(best orelse 0, fit);
            }
            total += best orelse return null;
        }
        return total;
    }
};

/// A search of a sheet: the same text as a fuzzy query for titles and as
/// a key query.
pub const Search = struct {
    text: fuzzy.Query,
    keys: KeyQuery,

    pub fn init(query: []const u8) Search {
        return .{ .text = .init(query), .keys = .init(query) };
    }

    pub fn isEmpty(self: *const Search) bool {
        return self.text.isEmpty();
    }

    /// The score of a row with these titles (translated and English) and
    /// key sequences: the best of the titles and the keys, or only the
    /// keys when the query is written as keys. 0 for an empty search,
    /// null when nothing matches.
    pub fn score(self: *const Search, titles: []const []const u8, sequences: []const []const Trigger) ?i32 {
        if (self.isEmpty()) return 0;
        var best = self.keys.scoreAny(sequences);
        if (self.keys.isChord()) return best;
        for (titles) |text| {
            const s = fuzzy.score(&self.text, text) orelse continue;
            best = if (best) |b| @max(b, s) else s;
        }
        return best;
    }
};

/// The place of the binding action named `name` (`new_tab`,
/// `gx:settings`), as `place` puts that action.
pub fn placeByName(name: []const u8) Place {
    const tag = if (std.mem.startsWith(u8, name, "gx:")) "gx" else name;
    return places.get(tag) orelse .{ .category = .other, .rank = table.len };
}

/// A title (msgid) for the binding action named `name` (`new_tab`,
/// `copy_to_clipboard`, `gx:settings_page`), whatever its argument, for
/// lists of actions to choose from: the only default command palette entry
/// with that action, else the one for the action with its default
/// argument, else a generic title (`title`); for `gx:` names the Ghostty
/// GX title. Null when there is none.
pub fn titleForName(name: []const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, name, "gx:")) {
        const GxAction = @import("action.zig").Action;
        const gx_name = name["gx:".len..];
        inline for (@typeInfo(GxAction).@"union".field_names) |field| {
            if (std.mem.eql(u8, field, gx_name)) {
                const value = @unionInit(GxAction, field, switch (@typeInfo(@FieldType(GxAction, field))) {
                    .void => {},
                    .@"enum" => std.enums.values(@FieldType(GxAction, field))[0],
                    else => if (@FieldType(GxAction, field) == []const u8) "" else return null,
                });
                return value.title();
            }
        }
        return null;
    }
    // As in `title`, text sequences have generic titles.
    for ([_][]const u8{ "text", "csi", "esc" }) |generic| {
        if (std.mem.eql(u8, name, generic)) return fallback_titles.get(name);
    }
    var found: ?[:0]const u8 = null;
    var count: usize = 0;
    for (input.command.defaults) |command| {
        if (!std.mem.eql(u8, @tagName(std.meta.activeTag(command.action)), name)) continue;
        found = command.title;
        count += 1;
    }
    if (count == 1) return found.?;
    if (count > 1) {
        if (Action.parse(name)) |action| {
            for (input.command.defaults) |command| {
                if (command.action.equal(action)) return command.title;
            }
        } else |_| {}
    }
    return fallback_titles.get(name);
}

const testing = std.testing;

fn testSet(alloc: Allocator, lines: []const []const u8) !Binding.Set {
    var set: Binding.Set = .{};
    errdefer set.deinit(alloc);
    for (lines) |line| try set.parseAndPut(alloc, line);
    return set;
}

fn parseSequence(alloc: Allocator, text: []const u8) ![]const Trigger {
    var steps: std.ArrayList(Trigger) = .empty;
    var it = std.mem.splitScalar(u8, text, '>');
    while (it.next()) |step| try steps.append(alloc, try Trigger.parse(step));
    return steps.items;
}

fn expectKeys(query: []const u8, keys: []const u8, matches: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const q: KeyQuery = .init(query);
    const sequence = try parseSequence(arena.allocator(), keys);
    if ((q.score(sequence) != null) != matches) {
        std.debug.print("query {s} keys {s}: expected match={}\n", .{ query, keys, matches });
        return error.TestUnexpectedResult;
    }
}

fn keyScore(query: []const u8, keys: []const u8) !?i32 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const q: KeyQuery = .init(query);
    return q.score(try parseSequence(arena.allocator(), keys));
}

fn expectTrigger(expected: []const u8, keys: []const u8, style: Style) !void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeTrigger(&writer, try Trigger.parse(keys), style);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "every action of the table is a binding action, once" {
    inline for (table, 0..) |entry, i| {
        try testing.expect(@hasField(Action, entry[0]));
        for (table[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier[0], entry[0]));
    }
    try testing.expectEqual(Category.tabs, category(.new_tab));
    try testing.expectEqual(Category.splits, category(.{ .new_split = .right }));
    try testing.expectEqual(Category.application, category(.reload_config));
    try testing.expectEqual(Category.application, category(.{ .gx = .settings }));
    try testing.expectEqual(Category.other, category(.end_key_sequence));
    try testing.expect(place(.new_tab).rank < place(.next_tab).rank);
}

test "collect groups the keys of each action and orders the rows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const set = try testSet(alloc, &.{
        "ctrl+shift+c=copy_to_clipboard",
        "ctrl+page_down=next_tab",
        "ctrl+tab=next_tab",
        "alt+0=goto_tab:10",
        "alt+2=goto_tab:2",
        "ctrl+a>n=new_tab",
        "ctrl+shift+t=new_tab",
        "ctrl+shift+x=ignore",
        "ctrl+shift+o=new_split:right",
        "ctrl+shift+e=reset",
        "chain=clear_screen",
    });

    const rows = try collect(alloc, &set);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(alloc, row.text);
    const expected = [_][]const u8{
        "new_tab",
        "next_tab",
        "goto_tab:2",
        "goto_tab:10",
        "new_split:right",
        "copy_to_clipboard:mixed",
    };
    try testing.expectEqual(expected.len + 1, rows.len);
    for (expected, texts.items[0..expected.len]) |e, actual| try testing.expectEqualStrings(e, actual);

    // Single keys come before sequences.
    try testing.expectEqual(@as(usize, 1), rows[0].sequences[0].len);
    try testing.expectEqual(@as(usize, 2), rows[0].sequences[1].len);
    try testing.expectEqual(@as(usize, 2), rows[1].sequences.len);
    try testing.expectEqual(Category.terminal, rows[rows.len - 1].category);
    try testing.expectEqual(@as(usize, 2), rows[rows.len - 1].actions.len);
}

test "collect does not depend on the binding order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const lines = [_][]const u8{ "ctrl+1=goto_tab:1", "ctrl+t=new_tab", "ctrl+w=close_tab", "ctrl+tab=next_tab", "ctrl+n=new_window" };
    var reversed: [lines.len][]const u8 = undefined;
    for (lines, 0..) |line, i| reversed[lines.len - 1 - i] = line;
    const a = try collect(alloc, &try testSet(alloc, &lines));
    const b = try collect(alloc, &try testSet(alloc, &reversed));
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqualStrings(x.text, y.text);
    try testing.expectEqualStrings("new_tab", a[0].text);
    try testing.expectEqualStrings("close_tab:this", a[1].text);
}

test "naturalOrder compares numbers by value" {
    try testing.expectEqual(std.math.Order.lt, naturalOrder("goto_tab:2", "goto_tab:10"));
    try testing.expectEqual(std.math.Order.gt, naturalOrder("goto_tab:10", "goto_tab:9"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("a01", "a1"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("new_split:down", "new_split:right"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("abc", "abcd"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("", ""));
}

test "title prefers the command palette titles" {
    try testing.expectEqualStrings("Split Right", title(.{ .new_split = .right }, &.{}).?.msgid);
    try testing.expect(title(.{ .new_split = .right }, &.{}).?.exact);
    try testing.expectEqualStrings("Increase Font Size", title(.{ .increase_font_size = 3 }, &.{}).?.msgid);
    try testing.expectEqualStrings("Next Tab", title(.next_tab, &.{}).?.msgid);
    const goto = title(.{ .goto_tab = 3 }, &.{}).?;
    try testing.expectEqualStrings("Go to Tab", goto.msgid);
    try testing.expect(!goto.exact);
    try testing.expectEqualStrings("New Split", title(.{ .new_split = .auto }, &.{}).?.msgid);
    try testing.expectEqualStrings("Settings…", title(.{ .gx = .settings }, &.{}).?.msgid);
    try testing.expectEqualStrings("New Tab with Profile", title(.{ .gx = .{ .new_tab_profile = "pwsh" } }, &.{}).?.msgid);
    try testing.expectEqual(@as(?Title, null), title(.end_key_sequence, &.{}));

    const configured = [_]input.Command{.{ .title = "My Split", .action = .{ .new_split = .right } }};
    try testing.expectEqualStrings("My Split", title(.{ .new_split = .right }, &configured).?.msgid);
}

test "title uses generic names for free-form arguments" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "text:hello", "Send Text" },
        .{ "text:world:👻", "Send Text" },
        .{ "text:", "Send Text" },
        .{ "csi:0m", "Send Control Sequence" },
        .{ "csi:2J", "Send Control Sequence" },
        .{ "csi:", "Send Control Sequence" },
        .{ "esc:c", "Send Escape Sequence" },
        .{ "esc:7", "Send Escape Sequence" },
        .{ "esc:", "Send Escape Sequence" },
    };
    for (cases) |case| {
        const action = try Action.parse(case[0]);
        const named = title(action, &.{}).?;
        try testing.expectEqualStrings(case[1], named.msgid);
        try testing.expect(!named.exact);
    }
    const ghost = title(try Action.parse("text:👻"), &.{}).?;
    try testing.expectEqualStrings("Ghostty", ghost.msgid);
    try testing.expect(ghost.exact);
}

test "title matches configured free-form arguments exactly" {
    const commands = [_]input.Command{
        .{ .title = "Greeting", .action = try Action.parse("text:hello") },
        .{ .title = "Farewell", .action = try Action.parse("text:bye") },
        .{ .title = "Reset Style", .action = try Action.parse("csi:0m") },
        .{ .title = "Clear Display", .action = try Action.parse("csi:2J") },
        .{ .title = "Reset Terminal", .action = try Action.parse("esc:c") },
        .{ .title = "Save Cursor", .action = try Action.parse("esc:7") },
        .{ .title = "My Ghost", .action = try Action.parse("text:👻") },
        .{ .title = "Another Greeting", .action = try Action.parse("text:hello") },
    };
    for (commands[0 .. commands.len - 1]) |command| {
        const text = try testing.allocator.print("{f}", .{command.action});
        defer testing.allocator.free(text);
        const action = try Action.parse(text);
        try testing.expect(action.equal(command.action));
        const named = title(action, &commands).?;
        try testing.expectEqualStrings(command.title, named.msgid);
        try testing.expect(named.exact);
    }
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "text:other", "Send Text" },
        .{ "csi:1m", "Send Control Sequence" },
        .{ "esc:8", "Send Escape Sequence" },
    };
    for (cases) |case| {
        const named = title(try Action.parse(case[0]), &commands).?;
        try testing.expectEqualStrings(case[1], named.msgid);
        try testing.expect(!named.exact);
    }
    const ghost = title(try Action.parse("text:👻"), commands[0..6]).?;
    try testing.expectEqualStrings("Ghostty", ghost.msgid);
    try testing.expect(ghost.exact);
}

test "title preserves fixed action and enum fallback priorities" {
    const commands = [_]input.Command{
        .{ .title = "My Reload", .action = try Action.parse("reload_config") },
        .{ .title = "My Inspector", .action = try Action.parse("inspector:toggle") },
        .{ .title = "My Split", .action = try Action.parse("new_split:right") },
    };
    for (commands) |command| {
        const named = title(command.action, &commands).?;
        try testing.expectEqualStrings(command.title, named.msgid);
        try testing.expect(named.exact);
    }
    const exact_cases = [_]struct { []const u8, []const u8 }{
        .{ "reload_config", "Reload Config" },
        .{ "inspector:toggle", "Toggle Inspector" },
        .{ "new_split:right", "Split Right" },
    };
    for (exact_cases) |case| {
        const named = title(try Action.parse(case[0]), &.{}).?;
        try testing.expectEqualStrings(case[1], named.msgid);
        try testing.expect(named.exact);
    }
    const fallback_cases = [_]struct { []const u8, []const u8 }{
        .{ "inspector:show", "Toggle Inspector" },
        .{ "inspector:hide", "Toggle Inspector" },
        .{ "increase_font_size:3", "Increase Font Size" },
        .{ "new_split:auto", "New Split" },
    };
    for (fallback_cases) |case| {
        const action = try Action.parse(case[0]);
        for ([_][]const input.Command{ &.{}, &commands }) |configured| {
            const named = title(action, configured).?;
            try testing.expectEqualStrings(case[1], named.msgid);
            try testing.expect(!named.exact);
        }
    }
    try testing.expectEqual(@as(?Title, null), title(try Action.parse("gx:tab_switcher"), &commands));
    try testing.expectError(error.InvalidAction, Action.parse("gx:unknown"));
}

test "argument" {
    try testing.expectEqualStrings("right", argument("new_split:right").?);
    try testing.expectEqualStrings("wsl:Ubuntu", argument("gx:new_tab_profile:wsl:Ubuntu").?);
    try testing.expectEqual(@as(?[]const u8, null), argument("gx:settings"));
    try testing.expectEqual(@as(?[]const u8, null), argument("new_tab"));
    try testing.expectEqual(@as(?[]const u8, null), argument("text:"));
}

test "keys show their modifiers in one order" {
    try expectTrigger("Ctrl+Shift+T", "shift+ctrl+t", .windows);
    try expectTrigger("Win+Ctrl+Alt+Shift+F5", "shift+alt+super+ctrl+f5", .windows);
    try expectTrigger("Super+Ctrl+Alt+Shift+F5", "shift+alt+super+ctrl+f5", .gtk);
    try expectTrigger("Ctrl+PgUp", "ctrl+page_up", .windows);
    try expectTrigger("Ctrl+Page Up", "ctrl+page_up", .gtk);
    try expectTrigger("Ctrl+,", "ctrl+,", .windows);
    try expectTrigger("Ctrl+,", "ctrl+comma", .windows);
    try expectTrigger("Win+Num +", "super+numpad_add", .windows);
    try expectTrigger("Ctrl+\u{00E4}", "ctrl+\u{00E4}", .gtk);
    try expectTrigger("Alt+Space", "alt+space", .gtk);
    try expectTrigger("paste", "paste", .windows);
    try testing.expect(!hasLabel(try Trigger.parse("paste")));
    try testing.expect(hasLabel(try Trigger.parse("ctrl+t")));
    try testing.expect(hasLabel(try Trigger.parse("f12")));

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeSequence(&writer, &.{ try Trigger.parse("ctrl+a"), try Trigger.parse("n") }, .windows, " \u{2192} ");
    try testing.expectEqualStrings("Ctrl+A \u{2192} N", writer.buffered());

    const caps: Keycaps = .init(try Trigger.parse("ctrl+shift+slash"), .windows);
    try testing.expectEqual(@as(usize, 3), caps.count());
    try testing.expectEqualStrings("Ctrl", caps.get(0));
    try testing.expectEqualStrings("Shift", caps.get(1));
    try testing.expectEqualStrings("/", caps.get(2));
    const long: Keycaps = .init(try Trigger.parse("numpad_memory_subtract"), .windows);
    try testing.expectEqualStrings("numpad_memory_subtract", long.get(0));
}

test "a query written as keys needs exactly those modifiers" {
    try expectKeys("ctrl+t", "ctrl+t", true);
    try expectKeys("CTRL+T", "ctrl+key_t", true);
    try expectKeys("ctrl+t", "ctrl+shift+t", false);
    try expectKeys("shift+ctrl+t", "ctrl+shift+t", true);
    try expectKeys("control+shift+t", "ctrl+shift+t", true);
    try expectKeys("ctrl+t", "alt+t", false);
    try expectKeys("ctrl+ｔ", "ctrl+t", true);
    // Only modifiers: any key with exactly those.
    try expectKeys("ctrl+shift", "ctrl+shift+c", true);
    try expectKeys("ctrl+shift", "ctrl+c", false);
    try expectKeys("ctrl+", "ctrl+c", true);
    try expectKeys("ctrl+", "ctrl+shift+c", false);
    // Two keys in one chord match nothing.
    try expectKeys("ctrl+a+b", "ctrl+a", false);
}

test "the key being typed may be the start of its name" {
    try expectKeys("ctrl+ta", "ctrl+tab", true);
    try expectKeys("ctrl+pag", "ctrl+page_down", true);
    try expectKeys("ctrl+pgu", "ctrl+page_up", true);
    // One letter is the whole key name.
    try expectKeys("ctrl+t", "ctrl+tab", false);
    // A finished or quoted key is whole.
    try expectKeys("ctrl+ta ", "ctrl+tab", false);
    try expectKeys("\"ctrl+ta\"", "ctrl+tab", false);
    try expectKeys("\"ctrl+tab\"", "ctrl+tab", true);
    // Or the start of a modifier name.
    try expectKeys("ctrl+sh", "ctrl+shift+c", true);
    try expectKeys("ctrl+sh", "ctrl+c", false);
    // An exact key outranks a prefix and a modifier being typed.
    try testing.expect((try keyScore("ctrl+s", "ctrl+s")).? > (try keyScore("ctrl+s", "ctrl+shift+s")).?);
    try testing.expect((try keyScore("ctrl+tab", "ctrl+tab")).? > (try keyScore("ctrl+ta", "ctrl+tab")).?);
}

test "a query written as keys matches the steps of sequences" {
    try expectKeys("ctrl+a>n", "ctrl+a>n", true);
    try expectKeys("ctrl+a > n", "ctrl+a>n", true);
    try expectKeys("ctrl+a>n", "ctrl+a>m", false);
    try expectKeys("ctrl+a", "ctrl+a>n", true);
    try expectKeys("ctrl+n", "ctrl+a>ctrl+n", true);
    try testing.expect((try keyScore("ctrl+a", "ctrl+a")).? > (try keyScore("ctrl+a", "ctrl+a>n")).?);
    try expectKeys("ctrl++", "ctrl++", true);
    try expectKeys("ctrl++", "ctrl+equal", false);
}

test "words name modifiers or begin words of key names" {
    try expectKeys("shift", "ctrl+shift+c", true);
    // Not every row with Shift for `sh`.
    try expectKeys("sh", "ctrl+shift+c", false);
    try expectKeys("page", "ctrl+page_up", true);
    try expectKeys("up", "ctrl+page_up", true);
    try expectKeys("pgdn", "ctrl+page_down", true);
    try expectKeys("tab", "ctrl+tab", true);
    try expectKeys("t", "ctrl+tab", false);
    try expectKeys("t", "ctrl+t", true);
    try expectKeys("comma", "ctrl+,", true);
    try expectKeys("esc", "escape", true);
    try expectKeys("ctrl tab", "ctrl+tab", true);
    try expectKeys("ctrl tab", "alt+tab", false);
    try expectKeys("f1", "f12", true);
    try testing.expect((try keyScore("f1", "f1")).? > (try keyScore("f1", "f12")).?);
    try expectKeys("new", "ctrl+t", false);
}

test "Search matches titles, or only keys for a query written as keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const new_tab = [_][]const Trigger{try parseSequence(alloc, "ctrl+shift+t")};
    const titles = [_][]const u8{ "新建标签页", "New Tab" };

    try testing.expectEqual(@as(?i32, 0), Search.init("").score(&titles, &new_tab));
    try testing.expect(Search.init("new tab").score(&titles, &new_tab) != null);
    try testing.expect(Search.init("xjbq").score(&titles, &new_tab) != null);
    try testing.expect(Search.init("shift").score(&titles, &new_tab) != null);
    try testing.expect(Search.init("ctrl+shift+t").score(&titles, &new_tab) != null);
    try testing.expect(Search.init("ctrl+t").score(&titles, &new_tab) == null);
    // A chord does not match titles as letters.
    try testing.expect(Search.init("n+t").score(&titles, &new_tab) == null);
    try testing.expect(Search.init("close").score(&titles, &new_tab) == null);
}

test "titleForName names actions without their argument" {
    try testing.expectEqualStrings("New Tab", titleForName("new_tab").?);
    try testing.expectEqualStrings("Copy to Clipboard", titleForName("copy_to_clipboard").?);
    try testing.expectEqualStrings("Go to Tab", titleForName("goto_tab").?);
    try testing.expectEqualStrings("Send Text", titleForName("text").?);
    try testing.expectEqualStrings("Settings…", titleForName("gx:settings").?);
    try testing.expectEqualStrings("Settings Page", titleForName("gx:settings_page").?);
    try testing.expectEqualStrings("New Tab with Profile", titleForName("gx:new_tab_profile").?);
    try testing.expectEqual(@as(?[:0]const u8, null), titleForName("gx:no_such_action"));
    try testing.expectEqual(@as(?[:0]const u8, null), titleForName("no_such_action"));
}

test "placeByName follows place" {
    try testing.expectEqual(place(.new_tab), placeByName("new_tab"));
    try testing.expectEqual(Category.application, placeByName("gx:settings").category);
    try testing.expectEqual(Category.other, placeByName("no_such_action").category);
}
