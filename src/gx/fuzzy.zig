//! Fuzzy matching for the command palette, the keyboard shortcut sheets
//! and the filter boxes of the settings, shared by both apprts.
//!
//! A query is split into terms at whitespace, and a text matches when
//! every term appears in it as a subsequence; the terms may come in any
//! order ("tab new" matches "New Tab"). `score` ranks the best alignment
//! of each term like fzf: every matched character scores, characters at
//! word boundaries (the start, after a space or punctuation, a camelCase
//! hump, the first digit, the first CJK character after Latin text) and
//! runs of consecutive matches score extra, and gaps cost. A query that
//! is the whole name, or begins it, scores extra; the name is the text
//! after the first `: ` or `：` (`Theme: Dracula`), or else all of it,
//! spaces ignored. ASCII letters match case-insensitively, and full-width
//! forms (as typed with a CJK input method) and the ideographic space
//! match their ASCII forms. A term with at least two ASCII letters also
//! matches Chinese characters by the initials of their pinyin readings
//! (`xjbq` matches 新建标签, see `pinyin.zig`), each scoring a little
//! less than a literal match. Full modern pinyin syllables, zh/ch/sh initials,
//! apostrophe boundaries and a final syllable prefix also match; each Hanzi
//! consumes one coherent reading (`zhongwen` or `zhw` finds 中文).
//!
//! `prepare` decodes and classifies a text once for any number of
//! queries; `scorePrepared` scores it, and `positions` also marks the
//! matched characters for highlighting (`Runs` turns them into byte and
//! UTF-16 ranges of the text). `filter` ranks a list of names.
//! `Frecency` ranks remembered picks by how often and how recently they
//! were made.
//!
//! Pure functions over UTF-8 (invalid bytes read as U+FFFD); texts are
//! matched on their first `max_text` code points, queries on their first
//! `max_query` code points and `max_terms` terms. Only depends on `std`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pinyin = @import("pinyin.zig");

/// The longest query, in code points without whitespace.
pub const max_query = 64;

/// The most terms of a query; later ones are ignored.
pub const max_terms = 8;

/// The longest text matched, in code points.
pub const max_text = 192;

const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i8 = score_match / 2;
const bonus_boundary_white: i8 = bonus_boundary + 2;
const bonus_boundary_delimiter: i8 = bonus_boundary + 1;
const bonus_camel: i8 = bonus_boundary + score_gap_extension;
const bonus_consecutive: i8 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i32 = 2;
const penalty_pinyin: i32 = 2;
const bonus_prefix: i32 = 20;
const bonus_exact: i32 = 50;
const min_pinyin_letters = 2;

const no_match: i32 = std.math.minInt(i32) / 4;

/// A parsed query: folded code points, split into terms.
pub const Query = struct {
    cps: [max_query]u21 = undefined,
    len: u8 = 0,
    terms: [max_terms]Term = undefined,
    term_count: u8 = 0,

    const Term = struct {
        start: u8,
        len: u8,
        /// The term may match Chinese characters by pinyin initials.
        pinyin: bool,
    };

    pub fn init(text: []const u8) Query {
        var self: Query = .{};
        var it: Decoder = .{ .bytes = text };
        var in_term = false;
        while (it.next()) |raw| {
            const cp = fold(raw);
            if (isSpace(cp)) {
                in_term = false;
                continue;
            }
            if (self.len == max_query) break;
            if (!in_term) {
                if (self.term_count == max_terms) break;
                self.terms[self.term_count] = .{ .start = self.len, .len = 0, .pinyin = false };
                self.term_count += 1;
                in_term = true;
            }
            self.cps[self.len] = cp;
            self.len += 1;
            self.terms[self.term_count - 1].len += 1;
        }
        for (self.terms[0..self.term_count]) |*term| {
            var letters: usize = 0;
            for (self.cps[term.start..][0..term.len]) |cp| {
                if ((cp >= 'a' and cp <= 'z') or cp == 'ü' or cp == 'Ü') letters += 1;
            }
            term.pinyin = letters >= min_pinyin_letters;
        }
        return self;
    }

    pub fn isEmpty(self: *const Query) bool {
        return self.len == 0;
    }

    /// The folded code points of all terms, without whitespace.
    pub fn slice(self: *const Query) []const u21 {
        return self.cps[0..self.len];
    }

    fn termCps(self: *const Query, i: usize) []const u21 {
        const t = self.terms[i];
        return self.cps[t.start..][0..t.len];
    }
};

/// A text decoded, folded and classified for matching (`prepare`,
/// `Buffer.prepare`).
pub const Prepared = struct {
    /// The folded code points.
    cps: []const u21,
    /// The word-boundary bonus of each code point.
    bonus: []const i8,
    /// The pinyin initials of each code point; empty when the text has no
    /// Chinese characters.
    initials: []const pinyin.Initials,
    /// Where the name starts: after the first `: ` or `：`, else 0.
    name_start: u8,

    /// Frees a text from `prepare`.
    pub fn deinit(self: Prepared, alloc: Allocator) void {
        alloc.free(self.cps);
        alloc.free(self.bonus);
        alloc.free(self.initials);
    }

    fn initialsAt(self: *const Prepared, j: usize) pinyin.Initials {
        return if (self.initials.len == 0) 0 else self.initials[j];
    }
};

/// Room to prepare one text without allocating.
pub const Buffer = struct {
    cps: [max_text]u21 = undefined,
    bonus: [max_text]i8 = undefined,
    initials: [max_text]pinyin.Initials = undefined,

    /// `text` prepared in this buffer, valid until the buffer is reused.
    pub fn prepare(self: *Buffer, text: []const u8) Prepared {
        var it: Decoder = .{ .bytes = text };
        var n: usize = 0;
        var prev_class: Class = .white;
        var any_initials = false;
        var name_start: ?usize = null;
        while (it.next()) |raw| {
            if (n == max_text) break;
            const class = classify(raw);
            const cp = fold(raw);
            if (name_start == null) {
                if (raw == 0xFF1A) {
                    name_start = n + 1;
                } else if (n > 0 and isSpace(cp) and self.cps[n - 1] == ':') {
                    name_start = n;
                }
            }
            self.cps[n] = cp;
            self.bonus[n] = bonusFor(prev_class, class);
            self.initials[n] = pinyin.initials(raw);
            if (self.initials[n] != 0) any_initials = true;
            prev_class = class;
            n += 1;
        }
        const start = @min(name_start orelse 0, n);
        return .{
            .cps = self.cps[0..n],
            .bonus = self.bonus[0..n],
            .initials = if (any_initials) self.initials[0..n] else &.{},
            .name_start = @intCast(if (start >= n) 0 else start),
        };
    }
};

/// `text` prepared for matching, in memory from `alloc` (free it with
/// `Prepared.deinit`).
pub fn prepare(alloc: Allocator, text: []const u8) Allocator.Error!Prepared {
    var buf: Buffer = undefined;
    const p = buf.prepare(text);
    const cps = try alloc.dupe(u21, p.cps);
    errdefer alloc.free(cps);
    const bonus = try alloc.dupe(i8, p.bonus);
    errdefer alloc.free(bonus);
    const initials = try alloc.dupe(pinyin.Initials, p.initials);
    return .{ .cps = cps, .bonus = bonus, .initials = initials, .name_start = p.name_start };
}

/// The score of the best alignment of `query` in `text`, or null when
/// some term does not match. An empty query matches everything with
/// score 0. Higher is better.
pub fn score(query: *const Query, text: []const u8) ?i32 {
    if (query.isEmpty()) return 0;
    var buf: Buffer = undefined;
    const p = buf.prepare(text);
    return scorePrepared(query, &p);
}

/// Whether `query` matches `text` (see `score`).
pub fn matches(query: *const Query, text: []const u8) bool {
    return score(query, text) != null;
}

/// `score` for a prepared text.
pub fn scorePrepared(query: *const Query, p: *const Prepared) ?i32 {
    if (query.isEmpty()) return 0;
    var total: i32 = 0;
    for (0..query.term_count) |i| {
        const m = matchTerm(query.termCps(i), query.terms[i].pinyin, p, null) orelse return null;
        total += m.score;
    }
    return total + nameBonus(query.slice(), p);
}

/// The matched characters of a text, by code point index.
pub const Positions = std.StaticBitSet(max_text);

/// `scorePrepared`, also marking in `out` the characters that the best
/// alignment of each term matched (all of them, for terms that overlap).
/// `out` is empty when there is no match or the query is empty.
pub fn positions(query: *const Query, p: *const Prepared, out: *Positions) ?i32 {
    out.* = .empty;
    if (query.isEmpty()) return 0;
    var trace: Trace = undefined;
    var total: i32 = 0;
    for (0..query.term_count) |i| {
        const t = query.termCps(i);
        const m = matchTerm(t, query.terms[i].pinyin, p, &trace) orelse {
            out.* = .empty;
            return null;
        };
        total += m.score;
        var j = m.end;
        var row = t.len;
        while (row > 0) {
            out.set(j);
            const previous = trace[row - 1][j];
            j = previous.text;
            row = previous.query;
        }
    }
    return total + nameBonus(query.slice(), p);
}

/// For each query character after the first and each text position it
/// matched at, the position the previous character matched at.
const TraceStep = struct { text: u8, query: u8 };
const Trace = [max_query][max_text]TraceStep;

const Match = struct { score: i32, end: usize };

const Accept = enum { none, literal, pinyin };

fn accept(p: *const Prepared, j: usize, c: u21, use_pinyin: bool) Accept {
    if (p.cps[j] == c) return .literal;
    if (use_pinyin and pinyin.has(p.initialsAt(j), c)) return .pinyin;
    return .none;
}

fn penalty(how: Accept) i32 {
    return if (how == .pinyin) penalty_pinyin else 0;
}

/// The best alignment of one term: a dynamic program over the text where
/// `prev[j]` is the best score of the term so far with its last character
/// matched at position j, and `prev_chunk[j]` the bonus of the first
/// character of the consecutive run that ends there (a run keeps the
/// bonus of its start, so "Tab" in "New Tab" outranks t-a-b spread out).
fn matchTerm(t: []const u21, use_pinyin: bool, p: *const Prepared, trace: ?*Trace) ?Match {
    if (use_pinyin and p.initials.len != 0) return matchSyllables(t, p, trace);
    return matchSingle(t, use_pinyin, p, trace);
}

fn matchSingle(t: []const u21, use_pinyin: bool, p: *const Prepared, trace: ?*Trace) ?Match {
    const n = p.cps.len;
    const m = t.len;
    if (m == 0 or n < m) return null;
    if (!isSubsequence(t, use_pinyin, p)) return null;

    var row_a: [max_text]i32 = undefined;
    var row_b: [max_text]i32 = undefined;
    var chunk_a: [max_text]i8 = undefined;
    var chunk_b: [max_text]i8 = undefined;
    var prev: []i32 = row_a[0..n];
    var cur: []i32 = row_b[0..n];
    var prev_chunk: []i8 = chunk_a[0..n];
    var cur_chunk: []i8 = chunk_b[0..n];

    for (0..n) |j| {
        const how = accept(p, j, t[0], use_pinyin);
        if (how == .none) {
            cur[j] = no_match;
            cur_chunk[j] = 0;
        } else {
            cur[j] = score_match + @as(i32, p.bonus[j]) * bonus_first_char_multiplier - penalty(how);
            cur_chunk[j] = p.bonus[j];
            if (trace) |tr| tr[0][j] = .{ .text = 0, .query = 0 };
        }
    }

    for (1..m) |i| {
        std.mem.swap([]i32, &prev, &cur);
        std.mem.swap([]i8, &prev_chunk, &cur_chunk);

        // The best `prev[k]` with the gap penalty to position j, k <= j - 2.
        var gap_best: i32 = no_match;
        var gap_from: usize = 0;
        for (0..n) |j| {
            if (j >= 2) {
                const opened = prev[j - 2] + score_gap_start;
                const extended = gap_best + score_gap_extension;
                if (opened >= extended) {
                    gap_best = opened;
                    gap_from = j - 2;
                } else {
                    gap_best = extended;
                }
            }
            cur[j] = no_match;
            cur_chunk[j] = 0;
            if (j == 0) continue;
            const how = accept(p, j, t[i], use_pinyin);
            if (how == .none) continue;

            var best: i32 = no_match;
            var best_chunk: i8 = 0;
            var best_from: usize = 0;
            if (prev[j - 1] > no_match / 2) {
                const chunk = prev_chunk[j - 1];
                best = prev[j - 1] + score_match + @max(chunk, bonus_consecutive, p.bonus[j]);
                best_chunk = @max(chunk, p.bonus[j]);
                best_from = j - 1;
            }
            if (gap_best > no_match / 2) {
                const candidate = gap_best + score_match + p.bonus[j];
                if (candidate > best) {
                    best = candidate;
                    best_chunk = p.bonus[j];
                    best_from = gap_from;
                }
            }
            if (best <= no_match / 2) continue;
            cur[j] = best - penalty(how);
            cur_chunk[j] = best_chunk;
            if (trace) |tr| tr[i][j] = .{ .text = @intCast(best_from), .query = @intCast(i) };
        }
    }

    var result: i32 = no_match;
    var end: usize = 0;
    for (cur, 0..) |s, j| {
        if (s > result) {
            result = s;
            end = j;
        }
    }
    if (result <= no_match / 2) return null;
    return .{ .score = result, .end = end };
}

const SyllableCell = struct { score: i32 = no_match, chunk: i8 = 0, from: u8 = 0 };

/// Roll over text columns, retaining query-prefix states. A transition consumes
/// one text character and one coherent reading, never a polyphone combination.
/// Scores and highlights use this same DP; only visible rows request a trace.
fn matchSyllables(t: []const u21, p: *const Prepared, trace: ?*Trace) ?Match {
    if (t.len == 0 or p.cps.len == 0) return null;
    var previous: [max_query + 1]SyllableCell = @splat(.{});
    var gaps: [max_query + 1]SyllableCell = @splat(.{});
    var result: ?Match = null;
    for (p.cps, 0..) |cp, j| {
        var current: [max_query + 1]SyllableCell = @splat(.{});
        for (0..t.len) |i| {
            var source: SyllableCell = .{};
            if (i == 0) {
                source = .{ .score = @as(i32, p.bonus[j]) * bonus_first_char_multiplier, .chunk = p.bonus[j] };
            } else {
                if (previous[i].score > no_match / 2) {
                    source = previous[i];
                    source.score += @max(source.chunk, bonus_consecutive, p.bonus[j]);
                    source.chunk = @max(source.chunk, p.bonus[j]);
                }
                if (gaps[i].score > no_match / 2 and gaps[i].score + p.bonus[j] > source.score) {
                    source = gaps[i];
                    source.score += p.bonus[j];
                    source.chunk = p.bonus[j];
                }
            }
            if (source.score <= no_match / 2) continue;
            if (cp == t[i]) offerSyllable(&current, trace, source, i, j, 1, 1, false);
            if (pinyinLetter(t[i]) < 'a' or pinyinLetter(t[i]) > 'z' or p.initialsAt(j) == 0) continue;
            var readings = pinyin.readings(cp);
            while (readings.next()) |reading| {
                var matched: usize = 0;
                while (matched < reading.len and i + matched < t.len and pinyinLetter(t[i + matched]) == reading[matched]) : (matched += 1) {}
                if (matched == 0) continue;
                // The old one-letter initials are always valid. zh/ch/sh can
                // also be used as an initial, as in zhw for 中文.
                offerReading(&current, trace, source, t, i, j, 1);
                if (matched >= 2 and reading.len >= 2 and reading[1] == 'h' and
                    (reading[0] == 'z' or reading[0] == 'c' or reading[0] == 's'))
                    offerReading(&current, trace, source, t, i, j, 2);
                if (matched == reading.len) offerReading(&current, trace, source, t, i, j, matched);
                // Only the final syllable may be a partial prefix. No middle
                // substring or truncated interior syllable can consume a Hanzi.
                if (i + matched == t.len) offerReading(&current, trace, source, t, i, j, matched);
            }
        }
        if (current[t.len].score > no_match / 2 and (result == null or current[t.len].score > result.?.score))
            result = .{ .score = current[t.len].score, .end = j };
        for (0..t.len + 1) |i| {
            const opened = previous[i].score + score_gap_start;
            gaps[i].score += score_gap_extension;
            if (previous[i].score > no_match / 2 and opened >= gaps[i].score) {
                gaps[i] = previous[i];
                gaps[i].score = opened;
            }
        }
        previous = current;
    }
    return result;
}

fn offerReading(current: *[max_query + 1]SyllableCell, trace: ?*Trace, source: SyllableCell, t: []const u21, i: usize, j: usize, letters: usize) void {
    var consumed = letters;
    if (i + consumed < t.len and t[i + consumed] == '\'') {
        if (i + consumed + 1 == t.len or t[i + consumed + 1] == '\'') return;
        consumed += 1;
    }
    offerSyllable(current, trace, source, i, j, consumed, letters, true);
}

fn pinyinLetter(cp: u21) u21 {
    return if (cp == 'ü' or cp == 'Ü') 'v' else cp;
}

fn offerSyllable(current: *[max_query + 1]SyllableCell, trace: ?*Trace, source: SyllableCell, i: usize, j: usize, consumed: usize, letters: usize, phonetic: bool) void {
    const contribution = @as(i32, @intCast(letters)) * (score_match - @as(i32, if (phonetic) penalty_pinyin else 0)) +
        @as(i32, @intCast(letters - 1)) * bonus_consecutive;
    const value = source.score + contribution;
    if (value <= current[i + consumed].score) return;
    current[i + consumed] = .{ .score = value, .chunk = source.chunk, .from = @intCast(j) };
    if (trace) |tr| tr[i + consumed - 1][j] = .{ .text = source.from, .query = @intCast(i) };
}

fn isSubsequence(t: []const u21, use_pinyin: bool, p: *const Prepared) bool {
    var i: usize = 0;
    for (0..p.cps.len) |j| {
        if (accept(p, j, t[i], use_pinyin) != .none) {
            i += 1;
            if (i == t.len) return true;
        }
    }
    return false;
}

const Prefix = enum(u2) { none, prefix, exact };

/// The bonus for a query that is the name of the text or begins it, the
/// name being all of the text or the part after its first `: ` or `：`.
fn nameBonus(q: []const u21, p: *const Prepared) i32 {
    const whole = prefixAt(q, p.cps, 0);
    const name = if (p.name_start == 0) .none else prefixAt(q, p.cps, p.name_start);
    const best: Prefix = @fromBackingInt(@max(@backingInt(whole), @backingInt(name)));
    return switch (best) {
        .none => 0,
        .prefix => bonus_prefix,
        .exact => bonus_prefix + bonus_exact,
    };
}

/// Whether the text from `start` begins with `q`, and whether that is all
/// of it; spaces in the text are skipped.
fn prefixAt(q: []const u21, cps: []const u21, start: usize) Prefix {
    var j = start;
    for (q) |c| {
        while (j < cps.len and isSpace(cps[j])) j += 1;
        if (j >= cps.len or cps[j] != c) return .none;
        j += 1;
    }
    while (j < cps.len and isSpace(cps[j])) j += 1;
    return if (j == cps.len) .exact else .prefix;
}

/// A range of matched characters (`Runs`).
pub const Run = struct {
    /// Code point indices, end exclusive.
    start: usize,
    end: usize,
    /// The same range in bytes of the UTF-8 text.
    byte_start: usize,
    byte_end: usize,
    /// The same range in UTF-16 code units, for valid UTF-8.
    utf16_start: usize,
    utf16_end: usize,
};

/// The runs of consecutive matched characters of `text` (`positions`), in
/// order.
pub const Runs = struct {
    decoder: Decoder,
    positions: *const Positions,
    index: usize = 0,
    utf16: usize = 0,

    pub fn init(text: []const u8, matched: *const Positions) Runs {
        return .{ .decoder = .{ .bytes = text }, .positions = matched };
    }

    pub fn next(self: *Runs) ?Run {
        var run: ?Run = null;
        while (self.index < max_text) {
            const byte = self.decoder.i;
            const cp = self.decoder.next() orelse break;
            const units: usize = if (cp >= 0x10000) 2 else 1;
            const matched = self.positions.isSet(self.index);
            if (run) |*r| {
                if (!matched) {
                    self.decoder.i = byte;
                    return r.*;
                }
                r.end += 1;
                r.byte_end = self.decoder.i;
                r.utf16_end += units;
            } else if (matched) {
                run = .{
                    .start = self.index,
                    .end = self.index + 1,
                    .byte_start = byte,
                    .byte_end = self.decoder.i,
                    .utf16_start = self.utf16,
                    .utf16_end = self.utf16 + units,
                };
            }
            self.index += 1;
            self.utf16 += units;
        }
        return run;
    }
};

/// Fills `out` with the indices of the `names` that match `pattern`, best
/// first; equal scores keep shorter names (in code points) first, then
/// the original order. An empty pattern keeps every name in its original
/// order.
pub fn filter(
    alloc: Allocator,
    names: []const [:0]const u8,
    pattern: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    const query: Query = .init(pattern);
    if (query.isEmpty()) {
        try out.ensureTotalCapacity(alloc, names.len);
        for (0..names.len) |i| out.appendAssumeCapacity(@intCast(i));
        return;
    }

    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(alloc);
    var buf: Buffer = undefined;
    for (names, 0..) |name, i| {
        const p = buf.prepare(name);
        const s = scorePrepared(&query, &p) orelse continue;
        try ranked.append(alloc, .{ .index = @intCast(i), .score = s, .len = @intCast(p.cps.len) });
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

/// Whether `pattern` has nothing to match (empty or whitespace only).
pub fn isBlank(pattern: []const u8) bool {
    const query: Query = .init(pattern);
    return query.isEmpty();
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

fn bonusFor(prev: Class, cur: Class) i8 {
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

/// Full-width ASCII (U+FF01..U+FF5E) to ASCII, the ideographic space to a
/// space.
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
        const entry = self.find(key) orelse return 0;
        return self.weight(entry);
    }

    /// The place of `key` in a list of recent picks, higher first: by
    /// frecency, the latest pick first among equal ones (picks one after
    /// another weigh the same). 0 when it was never picked.
    pub fn rank(self: *const Frecency, key: []const u8) u64 {
        const entry = self.find(key) orelse return 0;
        const age = self.clock -% entry.last;
        return (@as(u64, self.weight(entry)) << 32) | (std.math.maxInt(u32) - age);
    }

    fn find(self: *const Frecency, key: []const u8) ?Entry {
        if (key.len == 0) return null;
        const hash = hashOf(key);
        for (self.entries[0..self.len]) |entry| {
            if (entry.hash == hash) return entry;
        }
        return null;
    }

    fn weight(self: *const Frecency, entry: Entry) u32 {
        const age = self.clock -% entry.last;
        const recency: u32 = if (age < 2) 100 else if (age < 5) 70 else if (age < 12) 50 else if (age < 30) 30 else 10;
        return @min(entry.count, 20) * recency;
    }
};

/// A lenient UTF-8 decoder: invalid bytes decode to U+FFFD, one per byte.
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

const testing = std.testing;

fn testScore(query: []const u8, text: []const u8) ?i32 {
    const q: Query = .init(query);
    return score(&q, text);
}

fn expectOrder(names: []const [:0]const u8, pattern: []const u8, expected: []const []const u8) !void {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try filter(testing.allocator, names, pattern, &out);
    try testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |e, index| try testing.expectEqualStrings(e, names[index]);
}

fn expectPositions(query: []const u8, text: []const u8, expected: []const usize) !void {
    const q: Query = .init(query);
    var buf: Buffer = undefined;
    const p = buf.prepare(text);
    var out: Positions = undefined;
    const s = positions(&q, &p, &out);
    try testing.expectEqual(scorePrepared(&q, &p), s);
    try testing.expectEqual(expected.len, out.count());
    for (expected) |i| try testing.expect(out.isSet(i));
}

test "subsequences match, others do not" {
    try testing.expect(testScore("ntab", "New Tab") != null);
    try testing.expect(testScore("NEW TAB", "new tab") != null);
    try testing.expect(testScore("tabn", "New Tab") == null);
    try testing.expect(testScore("x", "New Tab") == null);
    try testing.expectEqual(@as(?i32, 0), testScore("", "anything"));
    try testing.expectEqual(@as(?i32, 0), testScore("   ", "anything"));
    try testing.expect(testScore("a", "") == null);
    try testing.expect(testScore("drc", "Dracula") != null);
    try testing.expect(testScore("lcd", "Dracula") == null);
    try testing.expect(testScore("abc", "ab") == null);
}

test "every term must match, in any order" {
    try testing.expect(testScore("tab new", "New Tab") != null);
    try testing.expect(testScore("solar dark", "Solarized Dark") != null);
    try testing.expect(testScore("tab xyz", "New Tab") == null);
    // Terms may use the same characters.
    try testing.expect(testScore("tab ta", "New Tab") != null);
    // Without whitespace the query is one term.
    try testing.expect(testScore("gxmocha", "GX Mocha") != null);
    // Terms beyond `max_terms` are ignored.
    try testing.expect(testScore("a a a a a a a a zzz", "a") != null);
}

test "word boundaries and runs rank higher" {
    try testing.expect(testScore("tab", "New Tab").? > testScore("tab", "Toggle Background Blur").?);
    try testing.expect(testScore("sp", "Split Right").? > testScore("sp", "Inspector").?);
    try testing.expect(testScore("ct", "copyTitle").? > testScore("ct", "action").?);
    // The best alignment is found, not the leftmost one.
    try testing.expectEqual(testScore("tab", "New Tab").?, testScore("tab", "Toggle Tab Bar").?);
    try testing.expect(testScore("sd", "Solarized Dark").? > testScore("sd", "Sandcastle").?);
    try testing.expect(testScore("mon", "Monokai").? > testScore("mon", "Mellow Night").?);
}

test "the name or its start scores extra" {
    try testing.expect(testScore("new tab", "New Tab").? > testScore("new tab", "New Tab: GX Zsh").?);
    try testing.expect(testScore("dracula", "Theme: Dracula").? > testScore("dracula", "Theme: Dracula+").?);
    try testing.expect(testScore("dracula", "Theme: Dracula+").? > testScore("dracula", "Theme: Builtin Dracula").?);
    try testing.expect(testScore("gx", "当前默认：GX Zsh").? > testScore("gx", "当前默认 GX Zsh").?);
    try testing.expectEqual(testScore("tab", "New Tab").? + bonus_prefix + bonus_exact, testScore("tab", "Tab").?);
}

test "CJK text and full-width input" {
    try testing.expect(testScore("标签", "切换到标签: 主页") != null);
    try testing.expect(testScore("主题", "主题: Dracula") != null);
    try testing.expect(testScore("主题：d", "主题: Dracula") != null);
    try testing.expect(testScore("ＧＸ", "新建标签页: GX Zsh") != null);
    try testing.expect(testScore("ｎｅｗ　ｔａｂ", "New Tab") != null);
    try testing.expect(testScore("新建标签", "新建标签页: GX Zsh").? > testScore("新建标签", "新建窗口并切换到标签").?);
    try testing.expect(testScore("题主", "主题: Dracula") == null);
    try testing.expect(testScore("中文", "简体中文") != null);
    try testing.expect(testScore("frappé", "Catppuccin Frappé") != null);
    try testing.expect(testScore("文中", "中文") == null);
    try testing.expect(testScore("\u{4E8C}", "\u{4E2D}") == null);
}

test "pinyin initials match Chinese characters" {
    try testing.expect(testScore("xjbq", "新建标签页") != null);
    try testing.expect(testScore("XJBQ", "新建标签页") != null);
    try testing.expect(testScore("zt", "主题: Dracula") != null);
    // Polyphones match by any of their readings: 音乐 is yīn yuè.
    try testing.expect(testScore("yy", "音乐") != null);
    try testing.expect(testScore("yl", "音乐") != null);
    // Runs of initials rank like runs of letters.
    try testing.expect(testScore("xjbq", "新建标签页: GX Zsh").? > testScore("xjbq", "新建窗口并切换到标签").?);
    // A literal match beats one by initials, and pinyin needs two letters.
    try testing.expect(testScore("zt", "zt: x").? > testScore("zt", "主题: x").?);
    try testing.expect(testScore("z", "主题") == null);
    try testing.expect(testScore("z主", "主题") == null);
    // Initials and characters mix, within a term and across terms.
    try testing.expect(testScore("xj标签", "新建标签页") != null);
    try testing.expect(testScore("xj 标签", "新建标签页") != null);
}

test "full pinyin modern polyphones digraph initials and final prefixes" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "zhongwen", "中文" },
        .{ "zhw", "中文" },
        .{ "zhongwe", "中文" },
        .{ "zhong'wen", "中文" },
        .{ "chongqing", "重庆" },
        .{ "chong'qing", "重庆" },
        .{ "yinyue", "音乐" },
        .{ "yinle", "音乐" },
        .{ "lvse", "绿色" },
        .{ "lüse", "绿色" },
        .{ "ＺＨＯＮＧＷＥＮ", "中文" },
        .{ "wen zhong", "中文" },
    };
    for (cases) |case| {
        const query = Query.init(case[0]);
        var buffer: Buffer = undefined;
        const prepared = buffer.prepare(case[1]);
        var marked: Positions = undefined;
        const value = scorePrepared(&query, &prepared);
        try std.testing.expect(value != null);
        try std.testing.expectEqual(value, positions(&query, &prepared, &marked));
        try std.testing.expectEqual(@as(usize, 2), marked.count());
    }
    for ([_][]const u8{ "hon", "zhonwen", "tongqing", "zhong''wen", "'zhongwen", "zhongwen'" }) |text| {
        const query = Query.init(text);
        try std.testing.expect(score(&query, "中文重庆") == null);
    }
    const mixed = Query.init("zhch");
    try std.testing.expect(score(&mixed, "重") == null);
    // 绿 legitimately also has lu (绿林); 女 has no plain-u modern reading.
    const plain_u = Query.init("nuxing");
    try std.testing.expect(score(&plain_u, "女性") == null);
    const umlaut = Query.init("nvxing");
    try std.testing.expect(score(&umlaut, "女性") != null);
    const literal_umlaut = Query.init("lü");
    try std.testing.expect(score(&literal_umlaut, "lü") != null);
    try std.testing.expect(score(&literal_umlaut, "lv") == null);
    const query = Query.init("zhongwen");
    try std.testing.expect(score(&query, "zhongwen").? > score(&query, "中文").?);
}

test "full pinyin trace follows variable length syllables and UTF16 emoji offsets" {
    const text = "😀重庆 中文音乐";
    var buffer: Buffer = undefined;
    const prepared = buffer.prepare(text);
    for ([_][]const u8{ "chongqing", "zhongwen", "yinyue", "yinle", "zhw", "zw", "zhong'wen" }) |term| {
        const query = Query.init(term);
        var marked: Positions = undefined;
        const result = positions(&query, &prepared, &marked);
        try std.testing.expectEqual(scorePrepared(&query, &prepared), result);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(usize, 2), marked.count());
    }
    const query = Query.init("chongqing");
    var marked: Positions = undefined;
    _ = positions(&query, &prepared, &marked);
    var runs = Runs.init(text, &marked);
    const run = runs.next().?;
    try std.testing.expectEqual(@as(usize, 2), run.utf16_start);
    try std.testing.expectEqual(@as(usize, 4), run.utf16_end);
    try std.testing.expectEqualStrings("重庆", text[run.byte_start..run.byte_end]);
}

test "full pinyin bounded query text and term limits without allocation" {
    const query = Query.init(std.mem.asBytes(&@as([max_query]["a".len]u8, @splat("a".*))));
    var buffer: Buffer = undefined;
    const prepared = buffer.prepare(std.mem.asBytes(&@as([(max_text + 1)]["阿".len]u8, @splat("阿".*))));
    try std.testing.expectEqual(@as(usize, max_text), prepared.cps.len);
    var marked: Positions = undefined;
    const result = positions(&query, &prepared, &marked);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(scorePrepared(&query, &prepared), result);
    try std.testing.expectEqual(@as(usize, max_query), marked.count());
    const terms = Query.init("zhong zhong zhong zhong zhong zhong zhong zhong absent");
    try std.testing.expectEqual(@as(u8, max_terms), terms.term_count);
    try std.testing.expect(score(&terms, "中") != null);
}

test "positions marks the best alignment of every term" {
    try expectPositions("ntab", "New Tab", &.{ 0, 4, 5, 6 });
    try expectPositions("tab", "Toggle Tab Bar", &.{ 7, 8, 9 });
    try expectPositions("tab new", "New Tab", &.{ 0, 1, 2, 4, 5, 6 });
    try expectPositions("xjbq", "新建标签页", &.{ 0, 1, 2, 3 });
    try expectPositions("", "New Tab", &.{});
    try expectPositions("xyz", "New Tab", &.{});
}

test "Runs gives the byte and UTF-16 ranges of the matches" {
    const text = "新建 \u{1F600}GX Zsh";
    const q: Query = .init("新 gx");
    var buf: Buffer = undefined;
    const p = buf.prepare(text);
    var matched: Positions = undefined;
    _ = positions(&q, &p, &matched).?;
    var runs: Runs = .init(text, &matched);
    const first = runs.next().?;
    try testing.expectEqual(Run{ .start = 0, .end = 1, .byte_start = 0, .byte_end = 3, .utf16_start = 0, .utf16_end = 1 }, first);
    const second = runs.next().?;
    // After 新建, a space and an emoji (two UTF-16 units).
    try testing.expectEqual(Run{ .start = 4, .end = 6, .byte_start = 11, .byte_end = 13, .utf16_start = 5, .utf16_end = 7 }, second);
    try testing.expectEqualStrings("GX", text[second.byte_start..second.byte_end]);
    try testing.expectEqual(@as(?Run, null), runs.next());
}

test "prepare copies what Buffer.prepare decodes" {
    const text = "Theme: 主题";
    const prepared = try prepare(testing.allocator, text);
    defer prepared.deinit(testing.allocator);
    var buf: Buffer = undefined;
    const local = buf.prepare(text);
    try testing.expectEqualSlices(u21, local.cps, prepared.cps);
    try testing.expectEqualSlices(i8, local.bonus, prepared.bonus);
    try testing.expectEqualSlices(pinyin.Initials, local.initials, prepared.initials);
    try testing.expectEqual(@as(u8, 6), prepared.name_start);
    // A text without Chinese characters has no initials.
    const ascii = try prepare(testing.allocator, "New Tab");
    defer ascii.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ascii.initials.len);
    try testing.expectEqual(@as(u8, 0), ascii.name_start);
}

test "an empty pattern keeps every name in order" {
    const names = [_][:0]const u8{ "b", "a", "C" };
    try expectOrder(&names, "", &.{ "b", "a", "C" });
    try expectOrder(&names, "   ", &.{ "b", "a", "C" });
    try expectOrder(&names, "\u{3000}", &.{ "b", "a", "C" });
    try testing.expect(isBlank(" \t\u{3000}"));
    try testing.expect(!isBlank(" x "));
}

test "filter ranks names" {
    try expectOrder(&.{ "Sandcastle", "Solarized Dark" }, "sd", &.{ "Solarized Dark", "Sandcastle" });
    try expectOrder(&.{ "Mellow Night", "Monokai" }, "mon", &.{ "Monokai", "Mellow Night" });
    try expectOrder(&.{ "Dracula+", "Builtin Dracula", "Dracula" }, "dracula", &.{ "Dracula", "Dracula+", "Builtin Dracula" });
    try expectOrder(&.{ "Dracula", "xyz" }, "DRAC", &.{"Dracula"});
    // Equal scores: shorter names, by code points, then the original order.
    try expectOrder(&.{ "ab x", "ab", "ab y" }, "ab", &.{ "ab", "ab x", "ab y" });
    try expectOrder(&.{ "Mono ab", "字体 ab" }, "ab", &.{ "字体 ab", "Mono ab" });
}

test "Frecency ranks frequent and recent picks" {
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

test "Frecency.rank puts the latest of equal picks first" {
    var f: Frecency = .{};
    try testing.expectEqual(@as(u64, 0), f.rank("theme:A"));
    f.record("theme:A");
    f.record("theme:B");
    // Picked one after the other, both weigh the same.
    try testing.expectEqual(f.get("theme:A"), f.get("theme:B"));
    try testing.expect(f.rank("theme:B") > f.rank("theme:A"));
    f.record("theme:A");
    try testing.expect(f.rank("theme:A") > f.rank("theme:B"));
    // Frecency comes before recency.
    for (0..3) |_| f.record("new_tab");
    f.record("theme:B");
    try testing.expect(f.get("new_tab") > f.get("theme:B"));
    try testing.expect(f.rank("new_tab") > f.rank("theme:B"));
    try testing.expectEqual(@as(u64, 0), f.rank(""));
}

test "Frecency.rank survives the pick counter wrapping around" {
    var f: Frecency = .{ .clock = std.math.maxInt(u32) - 1 };
    f.record("theme:A");
    f.record("theme:B");
    try testing.expectEqual(@as(u32, 0), f.clock);
    try testing.expect(f.rank("theme:B") > f.rank("theme:A"));
}

test "Frecency replaces the weakest key when full" {
    var f: Frecency = .{};
    var buf: [16]u8 = undefined;
    for (0..Frecency.capacity) |i| {
        const key = try std.mem.print(&buf, "key{d}", .{i});
        f.record(key);
        if (i == 0) f.record(key);
    }
    try testing.expectEqual(@as(usize, Frecency.capacity), f.len);
    f.record("newcomer");
    try testing.expectEqual(@as(usize, Frecency.capacity), f.len);
    try testing.expect(f.get("newcomer") > 0);
    try testing.expect(f.get("key0") > 0);
}

test "long texts and patterns, and invalid UTF-8" {
    const long = std.mem.asBytes(&@as([400]["x".len]u8, @splat("x".*))) ++ "abc";
    try testing.expect(testScore("abc", long) == null);
    try testing.expect(testScore("aaa", std.mem.asBytes(&@as([300]["a".len]u8, @splat("a".*)))) != null);
    try testing.expect(testScore(std.mem.asBytes(&@as([100]["a".len]u8, @splat("a".*))), "abc") == null);
    try testing.expect(testScore("abc", "a\xffb\xfec") != null);
    try testing.expect(testScore("a", "\xff\xff") == null);
    _ = testScore("ab", "\xe4");
    _ = testScore("\xe4", "a");
    var buf: Buffer = undefined;
    try testing.expectEqual(@as(usize, max_text), buf.prepare(std.mem.asBytes(&@as([400]["x".len]u8, @splat("x".*)))).cps.len);
}
