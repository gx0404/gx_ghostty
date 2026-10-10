//! The pure parts of the command palette (`Palette.zig`): which key presses
//! edit the filter (`isEditChord`) and what Enter does with its modifiers
//! (`enterAction`); the order of the matches (`sortMatches`: groups by
//! their best entry, entries by score) and of the recently used entries
//! (`recentTop`) and tabs (`mruOrder`); the filter text with an IME
//! composition in progress (`compositionQuery`); the variants of a filter
//! with two neighboring characters swapped, tried when nothing matches
//! (`Transpositions`); the short form of a launch profile's command
//! (`commandLabel`, `lineLabel`); and when the selected theme is previewed
//! (`PreviewGate`, `previewDelayMs`). Only depends on `std`.
const std = @import("std");

/// Virtual-key codes (winuser.h) the palette looks at; letters are their
/// ASCII capitals.
pub const vk = struct {
    pub const back: u16 = 0x08;
    pub const end: u16 = 0x23;
    pub const home: u16 = 0x24;
    pub const left: u16 = 0x25;
    pub const right: u16 = 0x27;
    pub const insert: u16 = 0x2D;
    pub const delete: u16 = 0x2E;
};

pub const Key = struct {
    vk: u16,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// Whether a key press with a modifier edits the filter text (the editing
/// keys of a Windows text box, `text_edit.handleKey`): Ctrl with the
/// arrows, Backspace, Delete, Insert and the clipboard, select-all, undo and
/// redo letters; Shift+Insert and Shift+Delete; Alt+Backspace (undo).
/// Ctrl+Home and Ctrl+End select the first and last entry instead.
pub fn isEditChord(key: Key) bool {
    if (key.alt) return key.vk == vk.back and !key.ctrl and !key.shift;
    if (key.ctrl) return switch (key.vk) {
        vk.left, vk.right, vk.back, vk.delete, vk.insert, 'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
    if (key.shift) return key.vk == vk.insert or key.vk == vk.delete;
    return false;
}

/// What Enter does with the modifiers held.
pub const EnterAction = enum {
    /// Run the selected entry.
    run,
    /// Ctrl+Enter: open a launch profile in a new window.
    new_window,
    /// Shift+Enter: apply a theme and keep the palette open.
    keep_open,
    /// Other chords (such as Alt+Enter) are no palette keys.
    none,
};

pub fn enterAction(key: Key) EnterAction {
    if (key.alt) return .none;
    if (key.ctrl and key.shift) return .none;
    if (key.ctrl) return .new_window;
    if (key.shift) return .keep_open;
    return .run;
}

/// A matched entry: its index in the entry list, its place in the list's
/// own order (the entry list's, or most recent first for tabs), its group,
/// its score and the length of the title it matched, in code points.
pub const Match = struct {
    index: u32,
    order: u64 = 0,
    group: u8,
    score: i32,
    len: u32,
};

/// The most groups `sortMatches` ranks.
pub const max_groups = 8;

/// Orders `matches` for display: the groups by their best entry (the
/// higher score; for equal scores the shorter title, which more of the
/// filter covers; then the order of the groups), the entries of a group by
/// score and, for equal scores, in their own order (`Match.order`:
/// settings and launch profiles keep the order they are listed in).
pub fn sortMatches(matches: []Match) void {
    var best: [max_groups]?Best = @splat(null);
    for (matches) |m| {
        const slot = &best[m.group];
        if (slot.*) |b| {
            if (m.score > b.score or (m.score == b.score and m.len < b.len)) slot.* = .{ .score = m.score, .len = m.len };
        } else slot.* = .{ .score = m.score, .len = m.len };
    }
    std.mem.sort(Match, matches, &best, before);
}

const Best = struct { score: i32, len: u32 };

fn before(best: *const [max_groups]?Best, a: Match, b: Match) bool {
    if (a.group != b.group) {
        const ga = best[a.group].?;
        const gb = best[b.group].?;
        if (ga.score != gb.score) return ga.score > gb.score;
        if (ga.len != gb.len) return ga.len < gb.len;
        return a.group < b.group;
    }
    if (a.score != b.score) return a.score > b.score;
    if (a.order != b.order) return a.order < b.order;
    return a.index < b.index;
}

/// Fills `out` with the indices of the highest non-zero `ranks`, highest
/// first (equal ranks in index order), and returns them.
pub fn recentTop(ranks: []const u64, out: []usize) []usize {
    var len: usize = 0;
    for (ranks, 0..) |rank, i| {
        if (rank == 0) continue;
        var pos = len;
        while (pos > 0 and ranks[out[pos - 1]] < rank) pos -= 1;
        if (pos >= out.len) continue;
        const end = @min(len, out.len - 1);
        var k = end;
        while (k > pos) : (k -= 1) out[k] = out[k - 1];
        out[pos] = i;
        len = @min(len + 1, out.len);
    }
    return out[0..len];
}

/// Fills `out` (as long as `recency`) with the tab indices in the order of
/// their last use: the most recent first, tabs never selected (recency 0)
/// last, in tab order.
pub fn mruOrder(recency: []const u64, out: []usize) void {
    std.debug.assert(out.len == recency.len);
    for (out, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, out, recency, struct {
        fn lessThan(r: []const u64, a: usize, b: usize) bool {
            if (r[a] != r[b]) return r[a] > r[b];
            return a < b;
        }
    }.lessThan);
}

/// The filter text while an input method composes: the typed text with the
/// composition at the caret, without the apostrophes and spaces a pinyin
/// input method puts between syllables, as UTF-8 in `buf` (cut off at a
/// character when it does not fit). `text` and `composition` are UTF-16.
pub fn compositionQuery(buf: []u8, text: []const u16, caret: usize, composition: []const u16) []const u8 {
    var out: Utf8Out = .{ .buf = buf };
    const split = @min(caret, text.len);
    out.units(text[0..split], false);
    out.units(composition, true);
    out.units(text[split..], false);
    return out.written();
}

const Utf8Out = struct {
    buf: []u8,
    len: usize = 0,
    full: bool = false,

    fn written(self: *const Utf8Out) []const u8 {
        return self.buf[0..self.len];
    }

    fn units(self: *Utf8Out, text: []const u16, drop_separators: bool) void {
        var i: usize = 0;
        while (i < text.len and !self.full) {
            var cp: u21 = text[i];
            i += 1;
            if (std.unicode.utf16IsHighSurrogate(text[i - 1])) {
                if (i < text.len and std.unicode.utf16IsLowSurrogate(text[i])) {
                    cp = std.unicode.utf16DecodeSurrogatePair(&.{ text[i - 1], text[i] }) catch 0xFFFD;
                    i += 1;
                } else cp = 0xFFFD;
            } else if (std.unicode.utf16IsLowSurrogate(text[i - 1])) cp = 0xFFFD;
            if (drop_separators and (cp == '\'' or cp == ' ' or cp == 0x3000)) continue;
            self.codepoint(cp);
        }
    }

    fn codepoint(self: *Utf8Out, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > self.buf.len) {
            self.full = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..n], tmp[0..n]);
        self.len += n;
    }
};

/// The variants of a filter with two neighboring characters of a word
/// swapped ("nwe tab" gives "new tab" among others), from the start, for a
/// second try when nothing matches it (a typing slip). Characters that are
/// the same or whitespace are not swapped. Filters longer than `max_chars`
/// code points have no variants.
pub const Transpositions = struct {
    cps: [max_chars]u21 = undefined,
    len: usize = 0,
    next_index: usize = 0,
    buf: [max_chars * 4]u8 = undefined,

    pub const max_chars = 64;

    pub fn init(query: []const u8) Transpositions {
        var self: Transpositions = .{};
        const view = std.unicode.Utf8View.init(query) catch return self;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (self.len == max_chars) {
                self.len = 0;
                return self;
            }
            self.cps[self.len] = cp;
            self.len += 1;
        }
        return self;
    }

    /// The next variant, valid until the next call.
    pub fn next(self: *Transpositions) ?[]const u8 {
        while (self.next_index + 1 < self.len) {
            const i = self.next_index;
            self.next_index += 1;
            const a = self.cps[i];
            const b = self.cps[i + 1];
            if (a == b or isBlank(a) or isBlank(b)) continue;
            var n: usize = 0;
            for (self.cps[0..self.len], 0..) |cp, j| {
                const c = if (j == i) b else if (j == i + 1) a else cp;
                n += std.unicode.utf8Encode(c, self.buf[n..]) catch continue;
            }
            return self.buf[0..n];
        }
        return null;
    }

    fn isBlank(cp: u21) bool {
        return cp == ' ' or cp == '\t' or cp == 0x3000;
    }
};

/// The short form of a command given as its arguments, for a launch
/// profile's row: the program's file name and the arguments
/// (`C:\Windows\System32\wsl.exe -d Ubuntu` becomes `wsl.exe -d Ubuntu`),
/// in `buf` (cut off when it does not fit).
pub fn commandLabel(buf: []u8, argv: []const [:0]const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch break;
        w.writeAll(if (i == 0) basename(arg) else arg) catch break;
    }
    return w.buffered();
}

/// `commandLabel` for a command line in the syntax of the `command` option
/// (a `gx-launch-profile`): without its `direct:` or `shell:` prefix, the
/// file name of its first word, which may be quoted, and the rest as is.
pub fn lineLabel(buf: []u8, line: []const u8) []const u8 {
    var rest = std.mem.trim(u8, line, " \t");
    for ([_][]const u8{ "direct:", "shell:" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) rest = std.mem.trimStart(u8, rest[prefix.len..], " \t");
    }
    var program = rest;
    var args: []const u8 = "";
    if (rest.len > 0 and rest[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, rest, 1, '"')) |close| {
            program = rest[1..close];
            args = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        }
    } else if (std.mem.indexOfAny(u8, rest, " \t")) |space| {
        program = rest[0..space];
        args = std.mem.trimStart(u8, rest[space..], " \t");
    }
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(basename(program)) catch return w.buffered();
    if (args.len > 0) {
        w.writeByte(' ') catch return w.buffered();
        w.writeAll(args) catch return w.buffered();
    }
    return w.buffered();
}

/// The file name of a Windows or POSIX path.
fn basename(path: []const u8) []const u8 {
    const sep = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return path;
    return path[sep + 1 ..];
}

/// Whether the selected theme is previewed. The theme page opens on the
/// current theme, and opening it must not change the theme: the selection
/// previews only once the user moved it with the keyboard or typed a
/// filter.
pub const PreviewGate = struct {
    armed: bool = false,

    /// The filter changed and selected its first entry.
    pub fn filtered(self: *PreviewGate, query_empty: bool) void {
        self.armed = !query_empty;
    }

    /// The user moved the selection.
    pub fn navigated(self: *PreviewGate) void {
        self.armed = true;
    }

    /// The theme the terminals should show while the theme `selected` (if
    /// any) is selected: it once armed, else the saved one (null).
    pub fn target(self: PreviewGate, selected: ?[]const u8) ?[]const u8 {
        return if (self.armed) selected else null;
    }
};

/// What moved the selection onto a theme.
pub const PreviewCause = enum { typing, navigation };

/// How long the selection rests on a theme before the terminals preview
/// it: longer while typing, when every key press selects another theme.
pub fn previewDelayMs(cause: PreviewCause) u32 {
    return switch (cause) {
        .typing => 400,
        .navigation => 150,
    };
}

const testing = std.testing;

test "editing chords stay with the filter" {
    try testing.expect(isEditChord(.{ .vk = vk.back, .ctrl = true }));
    try testing.expect(isEditChord(.{ .vk = vk.delete, .ctrl = true }));
    try testing.expect(isEditChord(.{ .vk = vk.left, .ctrl = true, .shift = true }));
    try testing.expect(isEditChord(.{ .vk = vk.right, .ctrl = true }));
    try testing.expect(isEditChord(.{ .vk = 'Z', .ctrl = true, .shift = true }));
    try testing.expect(isEditChord(.{ .vk = 'V', .ctrl = true, .shift = true }));
    try testing.expect(isEditChord(.{ .vk = vk.insert, .shift = true }));
    try testing.expect(isEditChord(.{ .vk = vk.insert, .ctrl = true }));
    try testing.expect(isEditChord(.{ .vk = vk.delete, .shift = true }));
    try testing.expect(isEditChord(.{ .vk = vk.back, .alt = true }));
    // List keys and bindings are not edits.
    try testing.expect(!isEditChord(.{ .vk = vk.home, .ctrl = true }));
    try testing.expect(!isEditChord(.{ .vk = vk.end, .ctrl = true }));
    try testing.expect(!isEditChord(.{ .vk = 'P', .ctrl = true, .shift = true }));
    try testing.expect(!isEditChord(.{ .vk = 'T', .ctrl = true }));
    try testing.expect(!isEditChord(.{ .vk = vk.left, .alt = true }));
    try testing.expect(!isEditChord(.{ .vk = vk.back, .alt = true, .ctrl = true }));
    try testing.expect(!isEditChord(.{ .vk = vk.back }));
}

test "Enter with modifiers" {
    try testing.expectEqual(EnterAction.run, enterAction(.{ .vk = 0x0D }));
    try testing.expectEqual(EnterAction.new_window, enterAction(.{ .vk = 0x0D, .ctrl = true }));
    try testing.expectEqual(EnterAction.keep_open, enterAction(.{ .vk = 0x0D, .shift = true }));
    try testing.expectEqual(EnterAction.none, enterAction(.{ .vk = 0x0D, .alt = true }));
    try testing.expectEqual(EnterAction.none, enterAction(.{ .vk = 0x0D, .ctrl = true, .shift = true }));
}

fn expectOrder(matches: []Match, expected: []const u32) !void {
    sortMatches(matches);
    try testing.expectEqual(expected.len, matches.len);
    for (expected, matches) |index, m| try testing.expectEqual(index, m.index);
}

test "sortMatches ranks groups by their best entry" {
    // Groups by their best score; entries by score.
    var a = [_]Match{
        .{ .index = 0, .group = 1, .score = 40, .len = 10 },
        .{ .index = 1, .group = 1, .score = 60, .len = 10 },
        .{ .index = 2, .group = 3, .score = 50, .len = 10 },
        .{ .index = 3, .group = 3, .score = 55, .len = 10 },
    };
    try expectOrder(&a, &.{ 1, 0, 3, 2 });

    // "new tab": the command "New Tab" (shorter) comes before the launch
    // profiles "New Tab: X" that score the same.
    var b = [_]Match{
        .{ .index = 0, .group = 1, .score = 90, .len = 18 },
        .{ .index = 1, .group = 1, .score = 90, .len = 20 },
        .{ .index = 2, .group = 2, .score = 90, .len = 7 },
    };
    try expectOrder(&b, &.{ 2, 0, 1 });

    // Equal best entries: the order of the groups.
    var c = [_]Match{
        .{ .index = 0, .group = 4, .score = 30, .len = 5 },
        .{ .index = 1, .group = 2, .score = 30, .len = 5 },
    };
    try expectOrder(&c, &.{ 1, 0 });

    // Equal scores in a group keep the original order, not the shorter
    // title ("Settings: Shell" stays after "Settings: Language").
    var d = [_]Match{
        .{ .index = 7, .group = 3, .score = 20, .len = 15 },
        .{ .index = 5, .group = 3, .score = 20, .len = 18 },
        .{ .index = 6, .group = 3, .score = 20, .len = 12 },
    };
    try expectOrder(&d, &.{ 5, 6, 7 });

    // A list's own order (tabs, most recent first) decides before the index.
    var e = [_]Match{
        .{ .index = 0, .order = 2, .group = 1, .score = 20, .len = 5 },
        .{ .index = 1, .order = 0, .group = 1, .score = 20, .len = 5 },
        .{ .index = 2, .order = 1, .group = 1, .score = 20, .len = 5 },
    };
    try expectOrder(&e, &.{ 1, 2, 0 });
}

test "recentTop keeps the highest ranks" {
    var out: [3]usize = undefined;
    try testing.expectEqual(@as(usize, 0), recentTop(&.{ 0, 0 }, &out).len);
    try testing.expectEqualSlices(usize, &.{ 3, 1, 4 }, recentTop(&.{ 0, 5, 0, 9, 2, 1 }, &out));
    // Equal ranks: index order.
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, recentTop(&.{ 4, 0, 4 }, &out));
}

test "mruOrder puts the most recent tabs first" {
    var out: [5]usize = undefined;
    mruOrder(&.{ 3, 9, 0, 5, 0 }, &out);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 0, 2, 4 }, &out);
}

test "compositionQuery puts the composition at the caret without separators" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ab", compositionQuery(&buf, L("ab"), 2, &.{}));
    try testing.expectEqualStrings("新xj标签", compositionQuery(&buf, L("新标签"), 1, L("x'j ")));
    try testing.expectEqualStrings("a新建", compositionQuery(&buf, L("a"), 9, L("新建")));
    // A surrogate pair stays whole; an unpaired surrogate reads as U+FFFD.
    try testing.expectEqualStrings("\u{1F600}\u{FFFD}", compositionQuery(&buf, &.{ 0xD83D, 0xDE00, 0xD83D }, 3, &.{}));
    // Cut off at a character.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("a新", compositionQuery(&small, L("a新建"), 3, &.{}));
}

test "Transpositions swaps neighbors within words" {
    var t: Transpositions = .init("nwe tab");
    var seen: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen.items) |s| testing.allocator.free(s);
        seen.deinit(testing.allocator);
    }
    while (t.next()) |variant| try seen.append(testing.allocator, try testing.allocator.dupe(u8, variant));
    try testing.expectEqual(@as(usize, 4), seen.items.len);
    try testing.expectEqualStrings("wne tab", seen.items[0]);
    try testing.expectEqualStrings("new tab", seen.items[1]);
    try testing.expectEqualStrings("nwe atb", seen.items[2]);
    try testing.expectEqualStrings("nwe tba", seen.items[3]);

    var cjk: Transpositions = .init("题主");
    try testing.expectEqualStrings("主题", cjk.next().?);
    try testing.expectEqual(@as(?[]const u8, null), cjk.next());

    var same: Transpositions = .init("aa");
    try testing.expectEqual(@as(?[]const u8, null), same.next());
    var long: Transpositions = .init("x" ** 70);
    try testing.expectEqual(@as(?[]const u8, null), long.next());
}

test "commandLabel and lineLabel keep the program name and arguments" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("wsl.exe -d Ubuntu-24.04", commandLabel(&buf, &.{ "C:\\WINDOWS\\System32\\wsl.exe", "-d", "Ubuntu-24.04" }));
    try testing.expectEqualStrings("pwsh.exe", commandLabel(&buf, &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}));
    try testing.expectEqualStrings("zsh -l", commandLabel(&buf, &.{ "/usr/bin/zsh", "-l" }));
    try testing.expectEqualStrings("python.exe -i", lineLabel(&buf, "direct:\"C:\\Program Files\\Python\\python.exe\" -i"));
    try testing.expectEqualStrings("nu.exe", lineLabel(&buf, "shell: C:\\tools\\nu.exe"));
    try testing.expectEqualStrings("bash -l", lineLabel(&buf, "bash -l"));
    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("wsl.ex", commandLabel(&small, &.{ "C:\\wsl.exe", "-d" }));
}

test "PreviewGate previews only a selection the user chose" {
    var gate: PreviewGate = .{};
    // Opening the theme page: the current theme is selected.
    gate.filtered(true);
    try testing.expectEqual(@as(?[]const u8, null), gate.target("Dracula"));
    // Moving the selection onto a theme previews it.
    gate.navigated();
    try testing.expectEqualStrings("Dracula", gate.target("Dracula").?);
    // So does the first entry of a typed filter.
    gate.filtered(false);
    try testing.expectEqualStrings("Nord", gate.target("Nord").?);
    // Clearing the filter shows the saved theme again.
    gate.filtered(true);
    try testing.expectEqual(@as(?[]const u8, null), gate.target("Dracula"));
    // Off the themes the saved one shows, too.
    gate.navigated();
    try testing.expectEqual(@as(?[]const u8, null), gate.target(null));
    try testing.expect(previewDelayMs(.typing) > previewDelayMs(.navigation));
}
