//! Tab bookkeeping of a win32 window that needs no window: which tab
//! `goto_tab` selects, where `move_tab` puts a tab, which tab becomes
//! active when one closes, which window `goto_window` goes to, and the
//! title a tab shows (`displayTitle`). `Window` keeps the tabs.
const std = @import("std");
const wstr = @import("ui/wstr.zig");

/// The most UTF-16 code units of a tab or window title; longer titles are
/// cut at a codepoint boundary.
pub const max_title_len = 255;

/// The title of a tab whose terminal has not set one.
pub const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

/// A title of at most `max_title_len` UTF-16 code units.
pub const Title = struct {
    len: u16 = 0,
    buf: [max_title_len + 1]u16 = undefined,

    /// `text` as a title; invalid UTF-8 becomes U+FFFD.
    pub fn fromUtf8(text: []const u8) Title {
        var title: Title = .{};
        title.len = @intCast(wstr.bufZ(&title.buf, text).len);
        return title;
    }

    pub fn fromUtf16(units: []const u16) Title {
        const kept = wstr.truncate(units, max_title_len);
        var title: Title = .{ .len = @intCast(kept.len) };
        @memcpy(title.buf[0..kept.len], kept);
        return title;
    }

    pub fn slice(self: *const Title) []const u16 {
        return self.buf[0..self.len];
    }
};

/// The title a tab shows: its override (`set_tab_title`, renaming the
/// tab), else the title of its focused terminal, else `default_title`.
pub fn displayTitle(override: ?[]const u16, terminal: []const u16) []const u16 {
    if (override) |title| return title;
    if (terminal.len > 0) return terminal;
    return default_title;
}

/// A `goto_tab` target.
pub const Goto = union(enum) {
    previous,
    next,
    last,
    /// The tab number, starting from 1; past the last tab is the last tab.
    number: usize,
};

/// The index of the tab `goto` selects among `count` tabs while the tab at
/// `active` is active, or null when there is no other tab to go to (a
/// single tab, tab number 0) so that the key reaches the terminal.
pub fn gotoIndex(active: usize, count: usize, goto: Goto) ?usize {
    if (count <= 1) return null;
    return switch (goto) {
        .previous => if (active > 0) active - 1 else count - 1,
        .next => if (active + 1 < count) active + 1 else 0,
        .last => count - 1,
        .number => |n| if (n == 0) null else @min(n - 1, count - 1),
    };
}

/// Where `move_tab` moves the tab at `index` among `count` tabs: `amount`
/// places on, wrapping around. Null when it stays where it is.
pub fn moveIndex(index: usize, count: usize, amount: isize) ?usize {
    if (count <= 1 or index >= count) return null;
    const shift: usize = @intCast(@mod(amount, @as(isize, @intCast(count))));
    const to = (index + shift) % count;
    return if (to == index) null else to;
}

/// The index of the tab at `index` after the tab at `from` moved to `to`
/// and the tabs between them shifted over.
pub fn movedIndex(index: usize, from: usize, to: usize) usize {
    if (index == from) return to;
    if (from < to and index > from and index <= to) return index - 1;
    if (to < from and index >= to and index < from) return index + 1;
    return index;
}

/// The tab to activate before the active tab at `closed` closes, among
/// `count` tabs: the one after it, or the one before it when it is the
/// last. Null when it is the only tab.
pub fn closeNeighbor(closed: usize, count: usize) ?usize {
    if (count <= 1) return null;
    return if (closed + 1 < count) closed + 1 else closed - 1;
}

/// The index of the tab at `index` after the tab at `removed`, another
/// one, was removed.
pub fn indexAfterRemove(index: usize, removed: usize) usize {
    return if (index > removed) index - 1 else index;
}

/// The index of the active tab once the tab at `closed` is gone, among
/// `count` tabs of which the one at `active` was active: the same tab
/// unless it is the one closing, then `closeNeighbor`. Null when no tab is
/// left.
pub fn activeAfterClose(active: usize, closed: usize, count: usize) ?usize {
    if (count <= 1) return null;
    const next = if (closed == active) closeNeighbor(closed, count).? else active;
    return indexAfterRemove(next, closed);
}

/// The index after `index` among `count` (> 0) items, or before it when
/// `forward` is false, wrapping around.
pub fn cycleIndex(index: usize, count: usize, forward: bool) usize {
    if (forward) return if (index + 1 < count) index + 1 else 0;
    return if (index > 0) index - 1 else count - 1;
}

test "displayTitle prefers the override, then the terminal title" {
    const testing = std.testing;
    const vim = std.unicode.utf8ToUtf16LeStringLiteral("vim");
    const notes = std.unicode.utf8ToUtf16LeStringLiteral("notes");
    try testing.expectEqualSlices(u16, notes, displayTitle(notes, vim));
    try testing.expectEqualSlices(u16, vim, displayTitle(null, vim));
    try testing.expectEqualSlices(u16, default_title, displayTitle(null, &.{}));
}

test "Title cuts long titles at a codepoint boundary" {
    const testing = std.testing;
    const long: Title = .fromUtf8("\u{6C49}" ** 300);
    try testing.expectEqual(@as(usize, max_title_len), long.slice().len);
    const cjk: Title = .fromUtf8("\u{6C49}" ** 200);
    try testing.expectEqual(@as(usize, 200), cjk.slice().len);
    const pair_at_end: Title = .fromUtf8("x" ** 254 ++ "\u{1F47B}");
    try testing.expectEqual(@as(usize, 254), pair_at_end.slice().len);

    var units: [300]u16 = undefined;
    @memset(&units, 'x');
    units[254] = 0xD83D;
    units[255] = 0xDC7B;
    const cut: Title = .fromUtf16(&units);
    try testing.expectEqual(@as(usize, 254), cut.slice().len);
    const empty: Title = .fromUtf16(&.{});
    try testing.expectEqual(@as(usize, 0), empty.slice().len);
}

test "gotoIndex" {
    const testing = std.testing;
    // A single tab: nothing to go to, the key goes to the terminal.
    try testing.expectEqual(@as(?usize, null), gotoIndex(0, 1, .next));
    try testing.expectEqual(@as(?usize, null), gotoIndex(0, 1, .previous));
    try testing.expectEqual(@as(?usize, null), gotoIndex(0, 1, .{ .number = 1 }));
    try testing.expectEqual(@as(?usize, null), gotoIndex(0, 0, .last));

    try testing.expectEqual(@as(?usize, 1), gotoIndex(0, 3, .next));
    try testing.expectEqual(@as(?usize, 0), gotoIndex(2, 3, .next));
    try testing.expectEqual(@as(?usize, 2), gotoIndex(0, 3, .previous));
    try testing.expectEqual(@as(?usize, 0), gotoIndex(1, 3, .previous));
    try testing.expectEqual(@as(?usize, 2), gotoIndex(0, 3, .last));
    // Tab numbers start from 1 and clamp to the last tab.
    try testing.expectEqual(@as(?usize, 0), gotoIndex(2, 3, .{ .number = 1 }));
    try testing.expectEqual(@as(?usize, 1), gotoIndex(2, 3, .{ .number = 2 }));
    try testing.expectEqual(@as(?usize, 2), gotoIndex(0, 3, .{ .number = 9 }));
    try testing.expectEqual(@as(?usize, null), gotoIndex(0, 3, .{ .number = 0 }));
}

test "moveIndex wraps around" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), moveIndex(0, 1, 1));
    try testing.expectEqual(@as(?usize, 1), moveIndex(0, 3, 1));
    try testing.expectEqual(@as(?usize, 0), moveIndex(2, 3, 1));
    try testing.expectEqual(@as(?usize, 2), moveIndex(0, 3, -1));
    try testing.expectEqual(@as(?usize, 1), moveIndex(0, 3, 4));
    try testing.expectEqual(@as(?usize, null), moveIndex(1, 3, 3));
    try testing.expectEqual(@as(?usize, null), moveIndex(1, 3, 0));
    // minInt(isize) is 1 modulo 3.
    try testing.expectEqual(@as(?usize, 2), moveIndex(1, 3, std.math.minInt(isize)));
}

test "movedIndex follows a moved tab" {
    const testing = std.testing;
    // [A B C D]: B (1) moves to 3 -> [A C D B].
    try testing.expectEqual(@as(usize, 3), movedIndex(1, 1, 3));
    try testing.expectEqual(@as(usize, 0), movedIndex(0, 1, 3));
    try testing.expectEqual(@as(usize, 1), movedIndex(2, 1, 3));
    try testing.expectEqual(@as(usize, 2), movedIndex(3, 1, 3));
    // [A B C D]: D (3) moves to 0 -> [D A B C].
    try testing.expectEqual(@as(usize, 0), movedIndex(3, 3, 0));
    try testing.expectEqual(@as(usize, 1), movedIndex(0, 3, 0));
    try testing.expectEqual(@as(usize, 3), movedIndex(2, 3, 0));
}

test "the tab after a close" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), closeNeighbor(0, 1));
    try testing.expectEqual(@as(?usize, 2), closeNeighbor(1, 3));
    try testing.expectEqual(@as(?usize, 1), closeNeighbor(2, 3));
    try testing.expectEqual(@as(?usize, 1), closeNeighbor(0, 2));

    // Closing a background tab keeps the active tab, which shifts left
    // when the closed tab was before it.
    try testing.expectEqual(@as(?usize, 1), activeAfterClose(1, 2, 3));
    try testing.expectEqual(@as(?usize, 0), activeAfterClose(1, 0, 3));
    // Closing the active tab activates the next one, or the previous one
    // for the last tab.
    try testing.expectEqual(@as(?usize, 1), activeAfterClose(1, 1, 3));
    try testing.expectEqual(@as(?usize, 1), activeAfterClose(2, 2, 3));
    try testing.expectEqual(@as(?usize, 0), activeAfterClose(0, 0, 2));
    try testing.expectEqual(@as(?usize, null), activeAfterClose(0, 0, 1));

    // Selecting the neighbor first ends on the same tab.
    for (2..6) |count| {
        for (0..count) |closed| {
            const neighbor = closeNeighbor(closed, count).?;
            try testing.expectEqual(activeAfterClose(closed, closed, count).?, indexAfterRemove(neighbor, closed));
        }
    }
}

test "cycleIndex" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 1), cycleIndex(0, 3, true));
    try testing.expectEqual(@as(usize, 0), cycleIndex(2, 3, true));
    try testing.expectEqual(@as(usize, 2), cycleIndex(0, 3, false));
    try testing.expectEqual(@as(usize, 1), cycleIndex(2, 3, false));
}
