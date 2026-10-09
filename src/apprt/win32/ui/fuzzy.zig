//! Fuzzy matching for the command palette and the keyboard shortcut sheet.
//!
//! A query matches a text when its characters appear in the text in order
//! (a subsequence); whitespace in the query is ignored. `score` ranks the
//! best alignment like fzf: every matched character scores, characters at
//! word boundaries (the start, after a space or punctuation, a camelCase
//! hump, the first digit, the first CJK character after Latin text) and
//! runs of consecutive matches score extra, and gaps between matches cost.
//! ASCII letters match case-insensitively and full-width ASCII (as typed
//! with a CJK input method) matches its ASCII form. `Frecency` ranks
//! remembered picks by how often and how recently they were made.
//!
//! Pure functions over UTF-8; texts longer than `max_text` code points
//! are matched on their first `max_text` code points.
const std = @import("std");

/// The longest query, in code points; longer queries are cut off.
pub const max_query = 64;

/// The longest text matched, in code points.
pub const max_text = 192;

const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i16 = score_match / 2;
const bonus_boundary_white: i16 = bonus_boundary + 2;
const bonus_boundary_delimiter: i16 = bonus_boundary + 1;
const bonus_camel: i16 = bonus_boundary + score_gap_extension;
const bonus_consecutive: i16 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i16 = 2;

const no_match: i32 = std.math.minInt(i32) / 4;

/// A normalized query: folded code points without whitespace.
pub const Query = struct {
    cps: [max_query]u21 = undefined,
    len: usize = 0,

    pub fn init(text: []const u8) Query {
        var self: Query = .{};
        var it = Decoder{ .bytes = text };
        while (it.next()) |cp| {
            if (isSpace(cp)) continue;
            if (self.len == max_query) break;
            self.cps[self.len] = fold(cp);
            self.len += 1;
        }
        return self;
    }

    pub fn isEmpty(self: *const Query) bool {
        return self.len == 0;
    }

    pub fn slice(self: *const Query) []const u21 {
        return self.cps[0..self.len];
    }
};

/// The score of the best alignment of `query` in `text`, or null when
/// `text` does not contain the query as a subsequence. An empty query
/// matches everything with score 0. Higher is better.
pub fn score(query: *const Query, text: []const u8) ?i32 {
    if (query.isEmpty()) return 0;

    var cps: [max_text]u21 = undefined;
    var bonus: [max_text]i16 = undefined;
    const n = prepare(text, &cps, &bonus);
    const q = query.slice();
    if (n < q.len) return null;
    if (!isSubsequence(q, cps[0..n])) return null;

    // Row-by-row dynamic program over the text: `prev[j]` is the best
    // score of the query prefix ending with its last character matched at
    // text position j, `prev_chunk[j]` the bonus of the first character
    // of the consecutive run that ends there (a run keeps the bonus of
    // its start, so "Tab" in "New Tab" outranks t-a-b spread out).
    var row_a: [max_text]i32 = undefined;
    var row_b: [max_text]i32 = undefined;
    var chunk_a: [max_text]i16 = undefined;
    var chunk_b: [max_text]i16 = undefined;
    var prev: []i32 = row_a[0..n];
    var cur: []i32 = row_b[0..n];
    var prev_chunk: []i16 = chunk_a[0..n];
    var cur_chunk: []i16 = chunk_b[0..n];

    for (0..n) |j| {
        if (cps[j] == q[0]) {
            cur[j] = score_match + @as(i32, bonus[j]) * bonus_first_char_multiplier;
            cur_chunk[j] = bonus[j];
        } else {
            cur[j] = no_match;
            cur_chunk[j] = 0;
        }
    }

    for (1..q.len) |i| {
        std.mem.swap([]i32, &prev, &cur);
        std.mem.swap([]i16, &prev_chunk, &cur_chunk);

        // Best `prev[k]` with the gap penalty to position j, k <= j - 2.
        var gap_best: i32 = no_match;
        for (0..n) |j| {
            if (j >= 2) {
                gap_best = @max(gap_best + score_gap_extension, prev[j - 2] + score_gap_start);
            }
            cur[j] = no_match;
            cur_chunk[j] = 0;
            if (j == 0 or cps[j] != q[i]) continue;

            var best: i32 = no_match;
            var best_chunk: i16 = 0;
            if (prev[j - 1] > no_match / 2) {
                const chunk = prev_chunk[j - 1];
                const b = @max(@max(chunk, bonus_consecutive), bonus[j]);
                best = prev[j - 1] + score_match + b;
                best_chunk = @max(chunk, bonus[j]);
            }
            if (gap_best > no_match / 2) {
                const candidate = gap_best + score_match + bonus[j];
                if (candidate > best) {
                    best = candidate;
                    best_chunk = bonus[j];
                }
            }
            cur[j] = best;
            cur_chunk[j] = best_chunk;
        }
    }

    var result: i32 = no_match;
    for (cur) |s| result = @max(result, s);
    if (result <= no_match / 2) return null;
    return result;
}

/// Whether `query` matches `text` (see `score`).
pub fn matches(query: *const Query, text: []const u8) bool {
    return score(query, text) != null;
}

fn isSubsequence(q: []const u21, text: []const u21) bool {
    var i: usize = 0;
    for (text) |cp| {
        if (cp == q[i]) {
            i += 1;
            if (i == q.len) return true;
        }
    }
    return false;
}

/// Decode, fold and classify `text` into `cps` and `bonus`; returns the
/// number of code points.
fn prepare(text: []const u8, cps: *[max_text]u21, bonus: *[max_text]i16) usize {
    var it = Decoder{ .bytes = text };
    var n: usize = 0;
    var prev_class: Class = .white;
    while (it.next()) |raw| {
        if (n == max_text) break;
        const class = classify(raw);
        cps[n] = fold(raw);
        bonus[n] = bonusFor(prev_class, class);
        prev_class = class;
        n += 1;
    }
    return n;
}

const Class = enum { white, delimiter, non_word, lower, upper, digit, cjk, letter };

fn classify(cp: u21) Class {
    const c = foldWidth(cp);
    if (isSpace(c)) return .white;
    if (c < 0x80) {
        const b: u8 = @intCast(c);
        if (std.ascii.isLower(b)) return .lower;
        if (std.ascii.isUpper(b)) return .upper;
        if (std.ascii.isDigit(b)) return .digit;
        return switch (b) {
            '/', ',', ':', ';', '|', '-', '_', '.', '+', '>', '(', ')', '[', ']' => .delimiter,
            else => .non_word,
        };
    }
    if (isCjkPunctuation(c)) return .delimiter;
    if (isCjk(c)) return .cjk;
    return .letter;
}

fn bonusFor(prev: Class, cur: Class) i16 {
    if (cur == .white or cur == .delimiter or cur == .non_word) return 0;
    return switch (prev) {
        .white => bonus_boundary_white,
        .delimiter => bonus_boundary_delimiter,
        .non_word => bonus_boundary,
        .lower => if (cur == .upper or cur == .digit) bonus_camel else if (cur == .cjk) bonus_boundary else 0,
        .upper, .letter => if (cur == .digit) bonus_camel else if (cur == .cjk) bonus_boundary else 0,
        .digit => if (cur != .digit) bonus_camel else 0,
        .cjk => if (cur != .cjk) bonus_boundary else 0,
    };
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0, 0x3000 => true,
        else => false,
    };
}

/// Full-width ASCII (U+FF01..U+FF5E) to ASCII.
fn foldWidth(cp: u21) u21 {
    if (cp >= 0xFF01 and cp <= 0xFF5E) return cp - 0xFEE0;
    if (cp == 0x3000) return ' ';
    return cp;
}

/// The form two code points are compared in.
fn fold(cp: u21) u21 {
    const c = foldWidth(cp);
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

fn isCjk(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x9FFF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0x20000 and cp <= 0x2FFFF);
}

fn isCjkPunctuation(cp: u21) bool {
    return (cp >= 0x3000 and cp <= 0x303F) or (cp >= 0xFE30 and cp <= 0xFE4F) or cp == 0x2026 or cp == 0x00B7;
}

/// Remembers picks (keyed by string) and ranks them by frecency: how
/// often and how recently each was picked. Ages are counted in picks, so
/// the ranking does not depend on the clock. Holds `capacity` keys (as
/// hashes); a new key replaces the weakest one when full.
pub const Frecency = struct {
    pub const capacity = 64;

    entries: [capacity]Entry = undefined,
    len: usize = 0,
    clock: u32 = 0,

    const Entry = struct { hash: u64, count: u32, last: u32 };

    fn hashOf(key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    /// Record a pick of `key`; empty keys are not remembered.
    pub fn record(self: *Frecency, key: []const u8) void {
        if (key.len == 0) return;
        self.clock +%= 1;
        const hash = hashOf(key);
        for (self.entries[0..self.len]) |*entry| {
            if (entry.hash != hash) continue;
            entry.count +|= 1;
            entry.last = self.clock;
            return;
        }
        const slot = if (self.len < capacity) slot: {
            self.len += 1;
            break :slot self.len - 1;
        } else weakest: {
            var weakest: usize = 0;
            for (self.entries[0..self.len], 0..) |entry, i| {
                if (self.weight(entry) < self.weight(self.entries[weakest])) weakest = i;
            }
            break :weakest weakest;
        };
        self.entries[slot] = .{ .hash = hash, .count = 1, .last = self.clock };
    }

    /// The frecency of `key`: higher for frequent and recent picks, 0 when
    /// it was never picked.
    pub fn get(self: *const Frecency, key: []const u8) u32 {
        if (key.len == 0) return 0;
        const hash = hashOf(key);
        for (self.entries[0..self.len]) |entry| {
            if (entry.hash == hash) return self.weight(entry);
        }
        return 0;
    }

    fn weight(self: *const Frecency, entry: Entry) u32 {
        const age = self.clock -% entry.last;
        const recency: u32 = if (age < 2) 100 else if (age < 5) 70 else if (age < 12) 50 else if (age < 30) 30 else 10;
        return @min(entry.count, 20) * recency;
    }
};

/// A lenient UTF-8 decoder: invalid bytes decode to U+FFFD.
const Decoder = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(self: *Decoder) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const rest = self.bytes[self.i..];
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (len > rest.len) {
            self.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(rest[0..len]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        self.i += len;
        return cp;
    }
};

fn testScore(query: []const u8, text: []const u8) ?i32 {
    const q = Query.init(query);
    return score(&q, text);
}

test "subsequences match, others do not" {
    const testing = std.testing;
    try testing.expect(testScore("ntab", "New Tab") != null);
    try testing.expect(testScore("NEW TAB", "new tab") != null);
    try testing.expect(testScore("tabn", "New Tab") == null);
    try testing.expect(testScore("x", "New Tab") == null);
    try testing.expectEqual(@as(?i32, 0), testScore("", "anything"));
    try testing.expectEqual(@as(?i32, 0), testScore("   ", "anything"));
    try testing.expect(testScore("a", "") == null);
}

test "word boundaries and runs rank higher" {
    const testing = std.testing;
    // A run at a word start beats scattered letters.
    try testing.expect(testScore("tab", "New Tab").? > testScore("tab", "Toggle Background Blur").?);
    // A boundary match beats the same letters inside a word.
    try testing.expect(testScore("sp", "Split Right").? > testScore("sp", "Inspector").?);
    // camelCase humps count as boundaries.
    try testing.expect(testScore("ct", "copyTitle").? > testScore("ct", "action").?);
    // The best alignment is found, not the leftmost one.
    try testing.expectEqual(testScore("tab", "Tab").?, testScore("tab", "Toggle Tab Bar").?);
}

test "CJK text and full-width input" {
    const testing = std.testing;
    try testing.expect(testScore("标签", "切换到标签: 主页") != null);
    try testing.expect(testScore("主题", "主题: Dracula") != null);
    try testing.expect(testScore("主题：d", "主题: Dracula") != null);
    try testing.expect(testScore("ＧＸ", "新建标签页: GX Zsh") != null);
    try testing.expect(testScore("新建标签", "新建标签页: GX Zsh").? > testScore("新建标签", "新建窗口并切换到标签").?);
    try testing.expect(testScore("题主", "主题: Dracula") == null);
}

test "Frecency ranks frequent and recent picks" {
    const testing = std.testing;
    var f: Frecency = .{};
    try testing.expectEqual(@as(u32, 0), f.get("new_tab"));
    f.record("new_tab");
    f.record("new_tab");
    f.record("theme:Dracula");
    try testing.expect(f.get("new_tab") > f.get("theme:Dracula"));
    for (0..40) |_| f.record("copy_to_clipboard:mixed");
    try testing.expect(f.get("copy_to_clipboard:mixed") > f.get("new_tab"));
    f.record("");
    try testing.expectEqual(@as(u32, 0), f.get(""));
}

test "Frecency replaces the weakest key when full" {
    const testing = std.testing;
    var f: Frecency = .{};
    var buf: [16]u8 = undefined;
    for (0..Frecency.capacity) |i| {
        const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
        f.record(key);
        if (i == 0) f.record(key);
    }
    try testing.expectEqual(@as(usize, Frecency.capacity), f.len);
    f.record("newcomer");
    try testing.expectEqual(@as(usize, Frecency.capacity), f.len);
    try testing.expect(f.get("newcomer") > 0);
    try testing.expect(f.get("key0") > 0);
}

test "long texts and invalid UTF-8 do not break matching" {
    const testing = std.testing;
    const long = "x" ** 400 ++ "abc";
    try testing.expect(testScore("abc", long) == null);
    try testing.expect(testScore("abc", "a\xffb\xfec") != null);
    try testing.expect(testScore("a", "\xff\xff") == null);
}
