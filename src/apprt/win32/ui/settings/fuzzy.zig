//! Fuzzy matching for the filter boxes of the settings overlay (themes and
//! font families). A pattern matches a name when its characters appear in
//! the name in order; ASCII letter case and spaces in the pattern are
//! ignored. Matches at word starts and runs of consecutive characters score
//! higher, so `sd` ranks "Solarized Dark" above "Sandcastle".
//!
//! Only depends on `std`, so the tests run with a plain `zig test` of this
//! file on any host.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Names and patterns are compared up to this many codepoints.
const max_name = 128;
const max_pattern = 32;

const score_match = 16;
const bonus_consecutive = 12;
const bonus_boundary = 12;
const bonus_camel = 10;
const bonus_digit = 6;
const penalty_gap_start = 3;
const penalty_gap_extension = 1;
const max_leading_penalty = 12;
const bonus_prefix = 20;
const bonus_exact = 50;

const invalid: i32 = std.math.minInt(i32) / 4;

/// The score of `pattern` against `name`, or null when it does not match.
/// An empty pattern (or one of spaces only) matches every name with 0.
pub fn score(name: []const u8, pattern: []const u8) ?i32 {
    var name_buf: [max_name]u21 = undefined;
    const name_cps = decode(name, &name_buf, false);
    var pattern_buf: [max_pattern]u21 = undefined;
    const pat = decode(pattern, &pattern_buf, true);
    if (pat.len == 0) return 0;
    if (pat.len > name_cps.len) return null;

    var prev: [max_name]i32 = undefined;
    var cur: [max_name]i32 = undefined;

    for (pat, 0..) |p, i| {
        var gap_best: i32 = invalid;
        for (name_cps, 0..) |c, j| {
            if (i > 0 and j >= 2) {
                gap_best = @max(gap_best - penalty_gap_extension, prev[j - 2] - penalty_gap_start);
            }
            if (fold(c) != p) {
                cur[j] = invalid;
                continue;
            }
            const bonus = boundaryBonus(name_cps, j);
            if (i == 0) {
                const leading: i32 = @intCast(@min(j, max_leading_penalty));
                cur[j] = score_match + 2 * bonus - leading;
                continue;
            }
            var best = gap_best;
            if (j >= 1 and prev[j - 1] > invalid) best = @max(best, prev[j - 1] + bonus_consecutive);
            cur[j] = if (best > invalid) best + score_match + bonus else invalid;
        }
        prev = cur;
    }

    var result: i32 = invalid;
    for (prev[0..name_cps.len]) |s| result = @max(result, s);
    if (result <= invalid) return null;

    switch (prefixOf(name_cps, pat)) {
        .none => {},
        .prefix => result += bonus_prefix,
        .exact => result += bonus_prefix + bonus_exact,
    }
    return result;
}

/// Fills `out` with the indices of the `names` that match `pattern`, best
/// first; equal scores keep shorter names first, then the original order.
/// An empty pattern keeps every name in its original order.
pub fn filter(
    alloc: Allocator,
    names: []const [:0]const u8,
    pattern: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (isBlank(pattern)) {
        try out.ensureTotalCapacity(alloc, names.len);
        for (0..names.len) |i| out.appendAssumeCapacity(@intCast(i));
        return;
    }

    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(alloc);
    for (names, 0..) |name, i| {
        const s = score(name, pattern) orelse continue;
        try ranked.append(alloc, .{ .index = @intCast(i), .score = s, .len = @intCast(@min(name.len, std.math.maxInt(u32))) });
    }
    std.mem.sort(Ranked, ranked.items, {}, Ranked.better);

    try out.ensureTotalCapacity(alloc, ranked.items.len);
    for (ranked.items) |r| out.appendAssumeCapacity(r.index);
}

const Ranked = struct {
    index: u32,
    score: i32,
    len: u32,

    fn better(_: void, a: Ranked, b: Ranked) bool {
        if (a.score != b.score) return a.score > b.score;
        if (a.len != b.len) return a.len < b.len;
        return a.index < b.index;
    }
};

/// Whether `pattern` has nothing to match (empty or spaces only).
pub fn isBlank(pattern: []const u8) bool {
    return std.mem.trim(u8, pattern, " \t").len == 0;
}

/// Decodes up to `buf.len` codepoints of `text`, folding ASCII letters to
/// lower case when `fold_case` and skipping spaces when `skip_space`.
/// Invalid UTF-8 decodes to U+FFFD.
fn decode(text: []const u8, buf: []u21, skip_space: bool) []u21 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len and len < buf.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp: u21 = if (i + seq_len <= text.len)
            std.unicode.utf8Decode(text[i .. i + seq_len]) catch 0xFFFD
        else
            0xFFFD;
        i += if (i + seq_len <= text.len) seq_len else 1;
        if (skip_space and isSpace(cp)) continue;
        buf[len] = if (skip_space) fold(cp) else cp;
        len += 1;
    }
    return buf[0..len];
}

fn fold(cp: u21) u21 {
    return if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
}

fn isSeparator(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '-', '_', '.', '/', '\\', '(', ')', '[', ']', '+', ':', ',', '&' => true,
        else => false,
    };
}

fn isLower(cp: u21) bool {
    return cp < 0x80 and std.ascii.isLower(@intCast(cp));
}

fn isUpper(cp: u21) bool {
    return cp < 0x80 and std.ascii.isUpper(@intCast(cp));
}

fn isDigit(cp: u21) bool {
    return cp < 0x80 and std.ascii.isDigit(@intCast(cp));
}

fn isAlpha(cp: u21) bool {
    return cp < 0x80 and std.ascii.isAlphabetic(@intCast(cp));
}

/// The word-start bonus of the codepoint at `j`.
fn boundaryBonus(name: []const u21, j: usize) i32 {
    if (j == 0) return bonus_boundary;
    const prev = name[j - 1];
    const c = name[j];
    if (isSeparator(c)) return 0;
    if (isSeparator(prev)) return bonus_boundary;
    if (isLower(prev) and isUpper(c)) return bonus_camel;
    if ((isAlpha(prev) and isDigit(c)) or (isDigit(prev) and isAlpha(c))) return bonus_digit;
    return 0;
}

const Prefix = enum { none, prefix, exact };

/// Whether `name` starts with `pattern` (folded, without spaces, like the
/// pattern), and whether that is all of it.
fn prefixOf(name: []const u21, pattern: []const u21) Prefix {
    var j: usize = 0;
    for (pattern) |p| {
        while (j < name.len and isSpace(name[j])) j += 1;
        if (j >= name.len or fold(name[j]) != p) return .none;
        j += 1;
    }
    while (j < name.len and isSpace(name[j])) j += 1;
    return if (j == name.len) .exact else .prefix;
}

fn isSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t';
}

const testing = std.testing;

fn expectOrder(names: []const [:0]const u8, pattern: []const u8, expected: []const []const u8) !void {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try filter(testing.allocator, names, pattern, &out);
    try testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |e, index| try testing.expectEqualStrings(e, names[index]);
}

test "an empty pattern keeps every name in order" {
    const names = [_][:0]const u8{ "b", "a", "C" };
    try expectOrder(&names, "", &.{ "b", "a", "C" });
    try expectOrder(&names, "   ", &.{ "b", "a", "C" });
    try testing.expectEqual(@as(?i32, 0), score("anything", ""));
}

test "characters must appear in order" {
    try testing.expect(score("Dracula", "drc") != null);
    try testing.expect(score("Dracula", "xyz") == null);
    try testing.expect(score("Dracula", "lcd") == null);
    try testing.expect(score("ab", "abc") == null);
}

test "case and pattern spaces are ignored" {
    try testing.expect(score("dracula", "DRAC") != null);
    try testing.expect(score("Solarized Dark", "solar dark") != null);
    try testing.expect(score("GX Mocha", "gxmocha") != null);
}

test "word starts beat scattered matches" {
    const names = [_][:0]const u8{ "Sandcastle", "Solarized Dark" };
    try expectOrder(&names, "sd", &.{ "Solarized Dark", "Sandcastle" });
}

test "consecutive runs beat gaps" {
    const names = [_][:0]const u8{ "Mellow Night", "Monokai" };
    try expectOrder(&names, "mon", &.{ "Monokai", "Mellow Night" });
}

test "exact and prefix matches come first, shorter names on ties" {
    const names = [_][:0]const u8{ "Dracula+", "Builtin Dracula", "Dracula" };
    try expectOrder(&names, "dracula", &.{ "Dracula", "Dracula+", "Builtin Dracula" });
}

test "non-ASCII names match by codepoint" {
    try testing.expect(score("简体中文", "中文") != null);
    try testing.expect(score("Catppuccin Frappé", "frappé") != null);
    try testing.expect(score("中文", "文中") == null);
    // A multi-byte pattern character never matches part of another one.
    try testing.expect(score("\u{4E2D}", "\u{4E8C}") == null);
}

test "invalid UTF-8 does not crash" {
    _ = score("a\xffb", "ab");
    _ = score("ab", "\xff");
    _ = score("\xe4", "a");
}

test "long names and patterns are cut off" {
    const long = "a" ** 300;
    try testing.expect(score(long, "aaa") != null);
    try testing.expect(score("abc", "a" ** 100) == null);
}
