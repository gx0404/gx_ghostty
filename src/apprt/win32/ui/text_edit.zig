//! The editing model of the single-line text inputs of the custom-drawn
//! UI (`Popup.TextInput`): UTF-16 text with a caret and a selection
//! anchor, movement by character and by word, an undo history and the
//! editing keys of a Windows text box (Ctrl+arrows, Ctrl+Backspace and
//! Ctrl+Delete, Shift+Insert, Ctrl+Insert, Shift+Delete, Ctrl+Z/Y,
//! Alt+Backspace).
//!
//! Pure functions without Win32 calls: `handleKey` reports clipboard keys
//! as a `Clipboard` intent and the caller moves the text (`deleteSelection`
//! after a cut, `paste` with the clipboard text, which keeps the field
//! within `max_len` code units). The functions take any struct with the
//! fields of `Text` (`buf`, `caret`, `anchor`, `history`), such as
//! `Popup.TextInput`.
//!
//! Characters: the caret never lands inside a surrogate pair, and combining
//! marks, variation selectors, emoji modifiers, zero-width joiner sequences
//! and regional indicator pairs move with their base character (an
//! approximation of grapheme clusters, also for UTF-8 text with
//! `nextCharUtf8`; callers that laid the text out pass the DirectWrite
//! cluster stops instead). Words: a run of letters and
//! digits, a run of Han characters (Chinese has no spaces between words,
//! so a run of Hanzi counts as one word), a run of hiragana, katakana or
//! Hangul, or a run of punctuation; whitespace separates them.
//!
//! The undo history follows stb_textedit (public domain): a bounded list of
//! replace records, consecutive typing and deleting merged into one step.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Virtual-key codes of the editing keys (winuser.h); letters are their
/// ASCII capitals.
pub const vk = struct {
    pub const back: u16 = 0x08;
    pub const end: u16 = 0x23;
    pub const home: u16 = 0x24;
    pub const left: u16 = 0x25;
    pub const up: u16 = 0x26;
    pub const right: u16 = 0x27;
    pub const down: u16 = 0x28;
    pub const insert: u16 = 0x2D;
    pub const delete: u16 = 0x2E;
};

pub const Key = struct {
    vk: u16,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// A clipboard operation the caller performs for a key.
pub const Clipboard = enum {
    none,
    /// Put the selection on the clipboard.
    copy,
    /// Put the selection on the clipboard, then `deleteSelection`.
    cut,
    /// Insert the clipboard text with `paste`.
    paste,
};

pub const Result = struct {
    /// The key is an editing key of the field (even when it changed
    /// nothing, like Backspace at the start).
    handled: bool = false,
    /// The text changed.
    changed: bool = false,
    /// The caret or the selection moved.
    moved: bool = false,
    clipboard: Clipboard = .none,
};

/// A range of UTF-16 code units, `start` <= `end`.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// A text field: the state the functions of this file edit.
/// `Popup.TextInput` has the same fields.
pub const Text = struct {
    buf: std.ArrayList(u16) = .empty,
    caret: usize = 0,
    anchor: usize = 0,
    history: History = .{},

    pub fn deinit(self: *Text, alloc: Allocator) void {
        self.buf.deinit(alloc);
        self.history.deinit(alloc);
        self.* = .{};
    }
};

// -----------------------------------------------------------------------
// Characters
// -----------------------------------------------------------------------

const CodePoint = struct { cp: u21, len: usize };

/// The code point at `pos` (< text.len); an unpaired surrogate is one
/// code point of its own.
fn codePointAt(text: []const u16, pos: usize) CodePoint {
    const unit = text[pos];
    if (std.unicode.utf16IsHighSurrogate(unit) and pos + 1 < text.len and
        std.unicode.utf16IsLowSurrogate(text[pos + 1]))
    {
        const high: u21 = unit - 0xD800;
        const low: u21 = text[pos + 1] - 0xDC00;
        return .{ .cp = 0x10000 + (high << 10) + low, .len = 2 };
    }
    return .{ .cp = unit, .len = 1 };
}

/// The code point at byte `pos` of UTF-8 text (< text.len); a byte that
/// does not start a valid sequence is U+FFFD of its own.
fn codePointAtUtf8(text: []const u8, pos: usize) CodePoint {
    const invalid: CodePoint = .{ .cp = 0xFFFD, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return invalid;
    if (pos + len > text.len) return invalid;
    const cp = std.unicode.utf8Decode(text[pos..][0..len]) catch return invalid;
    return .{ .cp = cp, .len = len };
}

fn codePointIn(comptime Unit: type, text: []const Unit, pos: usize) CodePoint {
    return switch (Unit) {
        u16 => codePointAt(text, pos),
        u8 => codePointAtUtf8(text, pos),
        else => @compileError("text is UTF-16 or UTF-8"),
    };
}

/// Code points that belong to the character before them.
fn isExtend(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, // combining diacritical marks
        0x0483...0x0489,
        0x0591...0x05BD,
        0x05BF,
        0x05C1...0x05C2,
        0x05C4...0x05C5,
        0x05C7,
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06DC,
        0x06DF...0x06E4,
        0x06E7...0x06E8,
        0x06EA...0x06ED,
        0x0900...0x0903, // Devanagari signs
        0x093A...0x094F,
        0x0951...0x0957,
        0x0962...0x0963,
        0x0E31,
        0x0E34...0x0E3A, // Thai vowels and tone marks
        0x0E47...0x0E4E,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x200C, // zero-width non-joiner
        0x20D0...0x20FF,
        0x3099...0x309A, // kana voiced sound marks
        0xFE00...0xFE0F, // variation selectors
        0xFE20...0xFE2F,
        0x1F3FB...0x1F3FF, // emoji skin tone modifiers
        0xE0020...0xE007F, // emoji tag sequences
        0xE0100...0xE01EF,
        => true,
        else => false,
    };
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

const zwj: u21 = 0x200D;

/// The end of the character that starts at `pos`.
pub fn nextChar(text: []const u16, pos: usize) usize {
    return nextCharIn(u16, text, pos);
}

/// `nextChar` for UTF-8 text, in bytes.
pub fn nextCharUtf8(text: []const u8, pos: usize) usize {
    return nextCharIn(u8, text, pos);
}

fn nextCharIn(comptime Unit: type, text: []const Unit, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var p = pos;
    const first = codePointIn(Unit, text, p);
    p += first.len;
    if (isRegionalIndicator(first.cp) and p < text.len) {
        const second = codePointIn(Unit, text, p);
        if (isRegionalIndicator(second.cp)) p += second.len;
    }
    while (p < text.len) {
        const next = codePointIn(Unit, text, p);
        if (next.cp == zwj) {
            // A zero-width joiner joins the following character.
            p += next.len;
            if (p < text.len) p += codePointIn(Unit, text, p).len;
            continue;
        }
        if (!isExtend(next.cp)) break;
        p += next.len;
    }
    return p;
}

/// The start of the character that contains `pos`; `text.len` for the end.
pub fn charStart(text: []const u16, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var p: usize = 0;
    while (true) {
        const next = nextChar(text, p);
        if (next > pos) return p;
        p = next;
    }
}

/// The start of the character before `pos`.
pub fn prevChar(text: []const u16, pos: usize) usize {
    const end = @min(pos, text.len);
    var p: usize = 0;
    var last: usize = 0;
    while (p < end) {
        last = p;
        p = nextChar(text, p);
    }
    return last;
}

/// Character stops: the DirectWrite cluster stops of the text when they
/// match it (sorted, from 0 to `text.len`), else the approximation above.
const Chars = struct {
    text: []const u16,
    stops: ?[]const u32 = null,

    fn init(text: []const u16, stops: ?[]const u32) Chars {
        const valid = if (stops) |s|
            s.len > 0 and s[0] == 0 and s[s.len - 1] == text.len
        else
            false;
        return .{ .text = text, .stops = if (valid) stops else null };
    }

    fn next(self: Chars, pos: usize) usize {
        const stops = self.stops orelse return nextChar(self.text, pos);
        for (stops) |stop| if (stop > pos) return stop;
        return self.text.len;
    }

    fn prev(self: Chars, pos: usize) usize {
        const stops = self.stops orelse return prevChar(self.text, pos);
        var last: usize = 0;
        for (stops) |stop| {
            if (stop >= pos) break;
            last = stop;
        }
        return last;
    }
};

// -----------------------------------------------------------------------
// Words
// -----------------------------------------------------------------------

/// What a character counts as for word movement.
pub const Class = enum { space, punct, word, han, hiragana, katakana, hangul };

pub fn classOf(cp: u21) Class {
    if (isSpace(cp)) return .space;
    if (isHan(cp)) return .han;
    if (cp == 0x30A0 or cp == 0x30FB) return .punct;
    if (cp >= 0x3040 and cp <= 0x309F) return .hiragana;
    if ((cp >= 0x30A0 and cp <= 0x30FF) or (cp >= 0x31F0 and cp <= 0x31FF) or
        (cp >= 0xFF66 and cp <= 0xFF9F)) return .katakana;
    if (isHangul(cp)) return .hangul;
    if (isPunct(cp)) return .punct;
    return .word;
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isHan(cp: u21) bool {
    return switch (cp) {
        0x2E80...0x2FDF, // radicals
        0x3005, // 々
        0x3007, // 〇
        0x3021...0x3029,
        0x3038...0x303B,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xF900...0xFAFF,
        0x20000...0x2FA1F,
        0x30000...0x323AF,
        => true,
        else => false,
    };
}

fn isHangul(cp: u21) bool {
    return switch (cp) {
        0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xFFA0...0xFFDC => true,
        else => false,
    };
}

fn isPunct(cp: u21) bool {
    return switch (cp) {
        0x21...0x2F,
        0x3A...0x40,
        0x5B...0x5E,
        0x60,
        0x7B...0x7E,
        0xA1...0xA9,
        0xAB...0xB1,
        0xB4,
        0xB6...0xB8,
        0xBB,
        0xBF,
        0xD7,
        0xF7,
        0x2010...0x2027,
        0x2030...0x205E,
        0x2070...0x2BFF, // super/subscripts, currency, symbols, arrows, math, boxes
        0x3001...0x3004,
        0x3008...0x3020,
        0x3030,
        0x303D,
        0xFE10...0xFE19,
        0xFE30...0xFE6B,
        0xFF01...0xFF0F,
        0xFF1A...0xFF20,
        0xFF3B...0xFF3E,
        0xFF40,
        0xFF5B...0xFF65,
        0x1F000...0x1FAFF, // emoji and pictographs
        => true,
        else => false,
    };
}

fn classAt(text: []const u16, pos: usize) Class {
    return classOf(codePointAt(text, pos).cp);
}

/// Where Ctrl+Left goes from `pos`: the start of the word before it,
/// skipping whitespace.
pub fn wordLeft(text: []const u16, pos: usize) usize {
    const end = charStart(text, @min(pos, text.len));
    var p: usize = 0;
    var run_start: usize = 0;
    var run_class: ?Class = null;
    var word_start: usize = 0;
    while (p < end) {
        const class = classAt(text, p);
        if (run_class == null or class != run_class.?) {
            run_start = p;
            run_class = class;
        }
        if (class != .space) word_start = run_start;
        p = nextChar(text, p);
    }
    return word_start;
}

/// Where Ctrl+Right goes from `pos`: past the rest of the word and the
/// whitespace after it, to the start of the next word (Windows).
pub fn wordRight(text: []const u16, pos: usize) usize {
    var p = charStart(text, @min(pos, text.len));
    if (p >= text.len) return text.len;
    const first = classAt(text, p);
    if (first != .space) {
        while (p < text.len and classAt(text, p) == first) p = nextChar(text, p);
    }
    while (p < text.len and classAt(text, p) == .space) p = nextChar(text, p);
    return p;
}

/// The word (or run of whitespace or punctuation) at `pos`, which a
/// double click selects; at the end of the text, the last one.
pub fn wordAt(text: []const u16, pos: usize) Range {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    var target = charStart(text, @min(pos, text.len));
    if (target >= text.len) target = prevChar(text, text.len);
    var p: usize = 0;
    var run_start: usize = 0;
    var run_class: ?Class = null;
    var found = false;
    while (p < text.len) {
        const class = classAt(text, p);
        if (run_class == null or class != run_class.?) {
            if (found) return .{ .start = run_start, .end = p };
            run_start = p;
            run_class = class;
        }
        if (p == target) found = true;
        p = nextChar(text, p);
    }
    return .{ .start = run_start, .end = text.len };
}

// -----------------------------------------------------------------------
// Undo history
// -----------------------------------------------------------------------

/// How an edit merges with the one before it into one undo step.
pub const EditKind = enum {
    /// Typed characters: consecutive ones merge up to a word boundary.
    typing,
    /// Backspace: consecutive ones merge.
    delete_back,
    /// Delete: consecutive ones merge.
    delete_forward,
    /// Its own step (paste, cut, input method result, word deletion).
    other,
};

const Record = struct {
    pos: usize,
    removed: []u16,
    inserted: []u16,
    /// The caret and anchor before the edit.
    caret: usize,
    anchor: usize,
    kind: EditKind,
};

/// The undo and redo steps of a field.
pub const History = struct {
    records: std.ArrayList(Record) = .empty,
    /// The records before this index are done (undo takes the last of
    /// them); the ones from it on were undone (redo takes the first).
    done: usize = 0,
    /// The code units the records store.
    units: usize = 0,

    pub const max_records = 64;
    pub const max_units = 8192;

    pub fn deinit(self: *History, alloc: Allocator) void {
        self.clear(alloc);
        self.records.deinit(alloc);
        self.* = .{};
    }

    /// Forget all steps.
    pub fn clear(self: *History, alloc: Allocator) void {
        for (self.records.items) |r| freeRecord(alloc, r);
        self.records.clearRetainingCapacity();
        self.done = 0;
        self.units = 0;
    }

    pub fn canUndo(self: *const History) bool {
        return self.done > 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.done < self.records.items.len;
    }

    fn freeRecord(alloc: Allocator, r: Record) void {
        alloc.free(r.removed);
        alloc.free(r.inserted);
    }

    fn dropRedo(self: *History, alloc: Allocator) void {
        for (self.records.items[self.done..]) |r| {
            self.units -= r.removed.len + r.inserted.len;
            freeRecord(alloc, r);
        }
        self.records.shrinkRetainingCapacity(self.done);
    }

    /// Drop the oldest steps over the limits.
    fn trim(self: *History, alloc: Allocator) void {
        while (self.records.items.len > 0 and
            (self.records.items.len > max_records or self.units > max_units))
        {
            const r = self.records.orderedRemove(0);
            self.units -= r.removed.len + r.inserted.len;
            freeRecord(alloc, r);
            self.done -|= 1;
        }
    }

    /// Merge an edit into the last step; whether it did.
    fn merge(
        self: *History,
        alloc: Allocator,
        text: []const u16,
        start: usize,
        end: usize,
        units: []const u16,
        kind: EditKind,
    ) Allocator.Error!bool {
        if (self.records.items.len == 0 or self.done != self.records.items.len) return false;
        const last = &self.records.items[self.records.items.len - 1];
        if (last.kind != kind) return false;
        switch (kind) {
            .typing => {
                if (start != end or start != last.pos + last.inserted.len) return false;
                // A new word is a new step.
                if (last.inserted.len > 0 and units.len > 0 and
                    isSpaceUnit(last.inserted[last.inserted.len - 1]) and !isSpaceUnit(units[0])) return false;
                const merged = try alloc.alloc(u16, last.inserted.len + units.len);
                @memcpy(merged[0..last.inserted.len], last.inserted);
                @memcpy(merged[last.inserted.len..], units);
                alloc.free(last.inserted);
                last.inserted = merged;
                self.units += units.len;
                return true;
            },
            .delete_back => {
                if (units.len != 0 or last.inserted.len != 0 or end != last.pos) return false;
                const merged = try alloc.alloc(u16, end - start + last.removed.len);
                @memcpy(merged[0 .. end - start], text[start..end]);
                @memcpy(merged[end - start ..], last.removed);
                alloc.free(last.removed);
                last.removed = merged;
                last.pos = start;
                self.units += end - start;
                return true;
            },
            .delete_forward => {
                if (units.len != 0 or last.inserted.len != 0 or start != last.pos) return false;
                const merged = try alloc.alloc(u16, last.removed.len + end - start);
                @memcpy(merged[0..last.removed.len], last.removed);
                @memcpy(merged[last.removed.len..], text[start..end]);
                alloc.free(last.removed);
                last.removed = merged;
                self.units += end - start;
                return true;
            },
            .other => return false,
        }
    }
};

fn isSpaceUnit(unit: u16) bool {
    return isSpace(unit);
}

// -----------------------------------------------------------------------
// Editing
// -----------------------------------------------------------------------

/// The selection of `t` (empty at the caret).
pub fn selection(t: anytype) Range {
    return .{ .start = @min(t.anchor, t.caret), .end = @max(t.anchor, t.caret) };
}

pub fn hasSelection(t: anytype) bool {
    return t.anchor != t.caret;
}

/// Move the caret to `pos` (kept on a character boundary); `extend`
/// keeps the anchor, selecting what is in between.
pub fn setCaret(t: anytype, pos: usize, extend: bool) void {
    t.caret = charStart(t.buf.items, @min(pos, t.buf.items.len));
    if (!extend) t.anchor = t.caret;
}

pub fn selectAll(t: anytype) void {
    t.anchor = 0;
    t.caret = t.buf.items.len;
}

/// Select the word at `pos` (a double click).
pub fn selectWord(t: anytype, pos: usize) void {
    const word = wordAt(t.buf.items, pos);
    t.anchor = word.start;
    t.caret = word.end;
}

/// Replace `t.buf[start..end]` with `units`, put the caret after them and
/// record the step.
pub fn replace(alloc: Allocator, t: anytype, start: usize, end: usize, units: []const u16, kind: EditKind) Allocator.Error!void {
    std.debug.assert(start <= end and end <= t.buf.items.len);
    if (start == end and units.len == 0) return;
    try t.buf.ensureUnusedCapacity(alloc, units.len -| (end - start));
    const h = &t.history;
    h.dropRedo(alloc);
    if (!try h.merge(alloc, t.buf.items, start, end, units, kind)) {
        const removed = try alloc.dupe(u16, t.buf.items[start..end]);
        errdefer alloc.free(removed);
        const inserted = try alloc.dupe(u16, units);
        errdefer alloc.free(inserted);
        try h.records.append(alloc, .{
            .pos = start,
            .removed = removed,
            .inserted = inserted,
            .caret = t.caret,
            .anchor = t.anchor,
            .kind = kind,
        });
        h.done = h.records.items.len;
        h.units += removed.len + inserted.len;
        h.trim(alloc);
    }
    t.buf.replaceRangeAssumeCapacity(start, end - start, units);
    t.caret = start + units.len;
    t.anchor = t.caret;
}

/// Insert typed text at the caret, replacing the selection. Typing on
/// after it merges into the same undo step, up to a word boundary.
pub fn typeText(alloc: Allocator, t: anytype, units: []const u16) Allocator.Error!void {
    const sel = selection(t);
    try replace(alloc, t, sel.start, sel.end, units, .typing);
}

/// Insert text as one step (an input method result), replacing the
/// selection.
pub fn insertText(alloc: Allocator, t: anytype, units: []const u16) Allocator.Error!void {
    const sel = selection(t);
    try replace(alloc, t, sel.start, sel.end, units, .other);
}

/// The most UTF-16 code units `paste` leaves in a field. Layout, hit
/// testing and painting go over the whole text, so a megabyte on the
/// clipboard would stall the UI.
pub const max_len: usize = 4096;

/// Insert clipboard text as one step: the first line, cut at a character
/// boundary so the text stays within `max_len` code units. Nothing changes
/// when none of it fits.
pub fn paste(alloc: Allocator, t: anytype, units: []const u16) Allocator.Error!void {
    var end: usize = 0;
    while (end < units.len and units[end] != '\r' and units[end] != '\n') end += 1;
    const line = units[0..end];
    const room = max_len -| (t.buf.items.len - selection(t).len());
    const fit = if (line.len <= room) line.len else charStart(line, room);
    if (fit == 0 and line.len > 0) return;
    try insertText(alloc, t, line[0..fit]);
}

/// Delete the selection; whether there was one.
pub fn deleteSelection(alloc: Allocator, t: anytype) Allocator.Error!bool {
    const sel = selection(t);
    if (sel.len() == 0) return false;
    try replace(alloc, t, sel.start, sel.end, &.{}, .other);
    return true;
}

/// Replace the whole text without an undo step and forget the history
/// (a new filter session).
pub fn reset(alloc: Allocator, t: anytype, units: []const u16) Allocator.Error!void {
    t.history.clear(alloc);
    t.buf.clearRetainingCapacity();
    try t.buf.appendSlice(alloc, units);
    t.caret = t.buf.items.len;
    t.anchor = t.caret;
}

/// Undo the last step; false when there is none, or when the text no
/// longer holds what it inserted (an owner edited `buf` directly, which
/// also clears the history).
pub fn undo(alloc: Allocator, t: anytype) Allocator.Error!bool {
    const h = &t.history;
    if (h.done == 0) return false;
    const r = h.records.items[h.done - 1];
    if (!holds(t.buf.items, r.pos, r.inserted)) {
        h.clear(alloc);
        return false;
    }
    try t.buf.replaceRange(alloc, r.pos, r.inserted.len, r.removed);
    h.done -= 1;
    t.caret = @min(r.caret, t.buf.items.len);
    t.anchor = @min(r.anchor, t.buf.items.len);
    return true;
}

/// Redo the last undone step (see `undo`).
pub fn redo(alloc: Allocator, t: anytype) Allocator.Error!bool {
    const h = &t.history;
    if (h.done >= h.records.items.len) return false;
    const r = h.records.items[h.done];
    if (!holds(t.buf.items, r.pos, r.removed)) {
        h.clear(alloc);
        return false;
    }
    try t.buf.replaceRange(alloc, r.pos, r.removed.len, r.inserted);
    h.done += 1;
    t.caret = r.pos + r.inserted.len;
    t.anchor = t.caret;
    return true;
}

fn holds(text: []const u16, pos: usize, units: []const u16) bool {
    if (pos + units.len > text.len) return false;
    return std.mem.eql(u16, text[pos..][0..units.len], units);
}

fn moved(t: anytype, caret: usize, anchor: usize) Result {
    return .{ .handled = true, .moved = t.caret != caret or t.anchor != anchor };
}

fn edited(changed: bool) Result {
    return .{ .handled = true, .changed = changed, .moved = changed };
}

/// Handle an editing key. `stops` are the cluster stops of the laid-out
/// text, if the caller has them. Clipboard keys only report the
/// operation (`Result.clipboard`).
pub fn handleKey(alloc: Allocator, t: anytype, key: Key, stops: ?[]const u32) Allocator.Error!Result {
    const text = t.buf.items;
    const chars = Chars.init(text, stops);
    const sel = selection(t);
    const caret = t.caret;
    const anchor = t.anchor;

    if (key.alt) {
        // Alt+Backspace is the old undo key of Windows text boxes.
        if (key.vk == vk.back and !key.ctrl and !key.shift) return edited(try undo(alloc, t));
        return .{};
    }

    switch (key.vk) {
        vk.left, vk.right => {
            const left = key.vk == vk.left;
            const target = if (key.ctrl)
                (if (left) wordLeft(text, caret) else wordRight(text, caret))
            else if (!key.shift and sel.len() > 0)
                (if (left) sel.start else sel.end)
            else if (left)
                chars.prev(caret)
            else
                chars.next(caret);
            t.caret = target;
            if (!key.shift) t.anchor = target;
            return moved(t, caret, anchor);
        },
        vk.home, vk.end => {
            t.caret = if (key.vk == vk.home) 0 else text.len;
            if (!key.shift) t.anchor = t.caret;
            return moved(t, caret, anchor);
        },
        vk.back => {
            if (sel.len() > 0) return edited(try deleteSelection(alloc, t));
            if (caret == 0) return .{ .handled = true };
            if (key.ctrl) {
                try replace(alloc, t, wordLeft(text, caret), caret, &.{}, .other);
            } else {
                try replace(alloc, t, chars.prev(caret), caret, &.{}, .delete_back);
            }
            return edited(true);
        },
        vk.delete => {
            if (key.shift and !key.ctrl and sel.len() > 0) return .{ .handled = true, .clipboard = .cut };
            if (sel.len() > 0) return edited(try deleteSelection(alloc, t));
            if (caret >= text.len) return .{ .handled = true };
            if (key.ctrl) {
                try replace(alloc, t, caret, wordRight(text, caret), &.{}, .other);
            } else {
                try replace(alloc, t, caret, chars.next(caret), &.{}, .delete_forward);
            }
            return edited(true);
        },
        vk.insert => {
            if (key.ctrl and !key.shift) return .{ .handled = true, .clipboard = if (sel.len() > 0) .copy else .none };
            if (key.shift and !key.ctrl) return .{ .handled = true, .clipboard = .paste };
        },
        'A' => if (key.ctrl and !key.shift) {
            selectAll(t);
            return moved(t, caret, anchor);
        },
        'C' => if (key.ctrl) return .{ .handled = true, .clipboard = if (sel.len() > 0) .copy else .none },
        'X' => if (key.ctrl) return .{ .handled = true, .clipboard = if (sel.len() > 0) .cut else .none },
        'V' => if (key.ctrl) return .{ .handled = true, .clipboard = .paste },
        'Z' => if (key.ctrl) return edited(if (key.shift) try redo(alloc, t) else try undo(alloc, t)),
        'Y' => if (key.ctrl and !key.shift) return edited(try redo(alloc, t)),
        else => {},
    }
    return .{};
}

/// Click count of a pointer press: 1 places the caret, 2 selects the
/// word, 3 selects everything.
pub fn pointerDown(t: anytype, pos: usize, clicks: u8, shift: bool) void {
    switch (clicks) {
        0, 1 => setCaret(t, pos, shift),
        2 => selectWord(t, pos),
        else => selectAll(t),
    }
}

/// The pointer moved with the button down: extend the selection to `pos`.
pub fn pointerDrag(t: anytype, pos: usize) void {
    setCaret(t, pos, true);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

fn textOf(alloc: Allocator, utf8: []const u8) !Text {
    var t: Text = .{};
    errdefer t.deinit(alloc);
    const units = try std.unicode.utf8ToUtf16LeAlloc(alloc, utf8);
    defer alloc.free(units);
    try reset(alloc, &t, units);
    return t;
}

fn expectText(t: *const Text, utf8: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(testing.allocator, utf8);
    defer testing.allocator.free(units);
    try testing.expectEqualSlices(u16, units, t.buf.items);
}

test "characters never split a surrogate pair or a combining sequence" {
    // a, ghost (surrogate pair), e + combining acute, b.
    const text = L("a\u{1F47B}e\u{301}b");
    try testing.expectEqual(@as(usize, 1), nextChar(text, 0));
    try testing.expectEqual(@as(usize, 3), nextChar(text, 1));
    try testing.expectEqual(@as(usize, 5), nextChar(text, 3));
    try testing.expectEqual(@as(usize, 6), nextChar(text, 5));
    try testing.expectEqual(@as(usize, 6), nextChar(text, 6));
    try testing.expectEqual(@as(usize, 3), prevChar(text, 5));
    try testing.expectEqual(@as(usize, 1), prevChar(text, 3));
    // Inside the pair and inside the accented letter: snap to the start.
    try testing.expectEqual(@as(usize, 1), charStart(text, 2));
    try testing.expectEqual(@as(usize, 3), charStart(text, 4));
    try testing.expectEqual(@as(usize, 6), charStart(text, 6));
}

test "emoji sequences move as one character" {
    // Family: man ZWJ woman ZWJ girl; then a flag (two regional
    // indicators) and a thumbs up with a skin tone.
    const family = L("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    try testing.expectEqual(family.len, nextChar(family, 0));
    const flags = L("\u{1F1E8}\u{1F1F3}\u{1F1EF}\u{1F1F5}");
    try testing.expectEqual(@as(usize, 4), nextChar(flags, 0));
    try testing.expectEqual(@as(usize, 8), nextChar(flags, 4));
    try testing.expectEqual(@as(usize, 4), prevChar(flags, 8));
    const thumbs = L("\u{1F44D}\u{1F3FD}x");
    try testing.expectEqual(@as(usize, 4), nextChar(thumbs, 0));
    // A variation selector stays with its base.
    const heart = L("\u{2764}\u{FE0F}!");
    try testing.expectEqual(@as(usize, 2), nextChar(heart, 0));
}

test "an unpaired surrogate is a character of its own" {
    const text = [_]u16{ 'a', 0xD83D, 'b', 0xDC7B };
    try testing.expectEqual(@as(usize, 2), nextChar(&text, 1));
    try testing.expectEqual(@as(usize, 4), nextChar(&text, 3));
    try testing.expectEqual(@as(usize, 3), prevChar(&text, 4));
}

test "words: letters, punctuation and whitespace" {
    const text = L("foo.bar baz");
    // Ctrl+Right stops at the start of each word and punctuation run.
    try testing.expectEqual(@as(usize, 3), wordRight(text, 0));
    try testing.expectEqual(@as(usize, 4), wordRight(text, 3));
    try testing.expectEqual(@as(usize, 8), wordRight(text, 4));
    try testing.expectEqual(@as(usize, 11), wordRight(text, 8));
    try testing.expectEqual(@as(usize, 11), wordRight(text, 11));
    // Ctrl+Left goes back the same way.
    try testing.expectEqual(@as(usize, 8), wordLeft(text, 11));
    try testing.expectEqual(@as(usize, 4), wordLeft(text, 8));
    try testing.expectEqual(@as(usize, 3), wordLeft(text, 4));
    try testing.expectEqual(@as(usize, 0), wordLeft(text, 3));
    try testing.expectEqual(@as(usize, 0), wordLeft(text, 0));
    // From inside a word, to its start; trailing spaces are skipped.
    try testing.expectEqual(@as(usize, 4), wordLeft(text, 6));
    const spaced = L("  hello   ");
    try testing.expectEqual(@as(usize, 2), wordLeft(spaced, spaced.len));
    try testing.expectEqual(@as(usize, 2), wordRight(spaced, 0));
    try testing.expectEqual(spaced.len, wordRight(spaced, 2));
    // Underscores and digits belong to words.
    try testing.expectEqual(@as(usize, 8), wordRight(L("snake_2 x"), 0));
}

test "a run of Han characters is one word" {
    const text = L("中文输入法abc，测试");
    try testing.expectEqual(@as(usize, 5), wordRight(text, 0));
    try testing.expectEqual(@as(usize, 8), wordRight(text, 5));
    try testing.expectEqual(@as(usize, 9), wordRight(text, 8));
    try testing.expectEqual(@as(usize, 11), wordRight(text, 9));
    try testing.expectEqual(@as(usize, 9), wordLeft(text, 11));
    try testing.expectEqual(@as(usize, 8), wordLeft(text, 9));
    try testing.expectEqual(@as(usize, 5), wordLeft(text, 8));
    try testing.expectEqual(@as(usize, 0), wordLeft(text, 5));
    // Ideographic space separates words too.
    const ideographic = L("配置\u{3000}文件");
    try testing.expectEqual(@as(usize, 3), wordRight(ideographic, 0));
    try testing.expectEqual(@as(usize, 3), wordLeft(ideographic, ideographic.len));
    // Kana runs are words of their own, apart from the kanji.
    const japanese = L("日本語のテキスト");
    try testing.expectEqual(@as(usize, 3), wordRight(japanese, 0));
    try testing.expectEqual(@as(usize, 4), wordRight(japanese, 3));
    try testing.expectEqual(japanese.len, wordRight(japanese, 4));
}

test "words in supplementary planes keep their surrogate pairs" {
    // Two CJK Extension B characters, a space and an emoji.
    const text = L("\u{20000}\u{20001} \u{1F47B}");
    try testing.expectEqual(@as(usize, 5), wordRight(text, 0));
    try testing.expectEqual(@as(usize, 0), wordLeft(text, 4));
    try testing.expectEqual(@as(usize, 5), wordLeft(text, text.len));
    const word = wordAt(text, 1);
    try testing.expectEqual(@as(usize, 0), word.start);
    try testing.expectEqual(@as(usize, 4), word.end);
}

test "wordAt selects the run under the pointer" {
    const text = L("open config.ghostty now");
    const config = wordAt(text, 7);
    try testing.expectEqual(@as(usize, 5), config.start);
    try testing.expectEqual(@as(usize, 11), config.end);
    const dot = wordAt(text, 11);
    try testing.expectEqual(@as(usize, 11), dot.start);
    try testing.expectEqual(@as(usize, 12), dot.end);
    const space = wordAt(text, 4);
    try testing.expectEqual(@as(usize, 4), space.start);
    try testing.expectEqual(@as(usize, 5), space.end);
    // At the end: the last word.
    const last = wordAt(text, text.len);
    try testing.expectEqual(@as(usize, 20), last.start);
    try testing.expectEqual(text.len, last.end);
    const empty = wordAt(L(""), 0);
    try testing.expectEqual(@as(usize, 0), empty.len());
}

test "arrow keys move by character, by word and collapse a selection" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "ab cd");
    defer t.deinit(alloc);
    try testing.expectEqual(@as(usize, 5), t.caret);
    var r = try handleKey(alloc, &t, .{ .vk = vk.left }, null);
    try testing.expect(r.handled and r.moved and !r.changed);
    try testing.expectEqual(@as(usize, 4), t.caret);
    r = try handleKey(alloc, &t, .{ .vk = vk.left, .ctrl = true }, null);
    try testing.expectEqual(@as(usize, 3), t.caret);
    r = try handleKey(alloc, &t, .{ .vk = vk.left, .ctrl = true, .shift = true }, null);
    try testing.expectEqual(@as(usize, 0), t.caret);
    try testing.expectEqual(@as(usize, 3), t.anchor);
    // Right without Shift collapses the selection to its end.
    r = try handleKey(alloc, &t, .{ .vk = vk.right }, null);
    try testing.expectEqual(@as(usize, 3), t.caret);
    try testing.expectEqual(@as(usize, 3), t.anchor);
    r = try handleKey(alloc, &t, .{ .vk = vk.home, .shift = true }, null);
    try testing.expectEqual(@as(usize, 0), t.caret);
    try testing.expectEqual(@as(usize, 3), t.anchor);
    r = try handleKey(alloc, &t, .{ .vk = vk.end }, null);
    try testing.expectEqual(@as(usize, 5), t.caret);
    try testing.expect(!hasSelection(&t));
    // Up and Down are the owner's.
    r = try handleKey(alloc, &t, .{ .vk = vk.up }, null);
    try testing.expect(!r.handled);
}

test "cluster stops from the layout drive character movement" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "abcd");
    defer t.deinit(alloc);
    // A layout that made "bc" one cluster.
    const stops = [_]u32{ 0, 1, 3, 4 };
    t.caret = 1;
    t.anchor = 1;
    _ = try handleKey(alloc, &t, .{ .vk = vk.right }, &stops);
    try testing.expectEqual(@as(usize, 3), t.caret);
    _ = try handleKey(alloc, &t, .{ .vk = vk.left }, &stops);
    try testing.expectEqual(@as(usize, 1), t.caret);
    // Stops of another text are ignored.
    const stale = [_]u32{ 0, 2 };
    _ = try handleKey(alloc, &t, .{ .vk = vk.right }, &stale);
    try testing.expectEqual(@as(usize, 2), t.caret);
}

test "Backspace and Delete by character and by word" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "git commit -m 中文消息");
    defer t.deinit(alloc);
    var r = try handleKey(alloc, &t, .{ .vk = vk.back, .ctrl = true }, null);
    try testing.expect(r.changed);
    try expectText(&t, "git commit -m ");
    // "-m" is punctuation and a word, like Ctrl+Left sees it.
    r = try handleKey(alloc, &t, .{ .vk = vk.back, .ctrl = true }, null);
    try expectText(&t, "git commit -");
    r = try handleKey(alloc, &t, .{ .vk = vk.back, .ctrl = true }, null);
    try expectText(&t, "git commit ");
    r = try handleKey(alloc, &t, .{ .vk = vk.back }, null);
    try expectText(&t, "git commit");
    t.caret = 0;
    t.anchor = 0;
    r = try handleKey(alloc, &t, .{ .vk = vk.delete, .ctrl = true }, null);
    try expectText(&t, "commit");
    r = try handleKey(alloc, &t, .{ .vk = vk.delete }, null);
    try expectText(&t, "ommit");
    // Nothing to delete: handled, unchanged.
    r = try handleKey(alloc, &t, .{ .vk = vk.back }, null);
    try testing.expect(r.handled and !r.changed);
    // A selection goes first.
    t.anchor = 1;
    t.caret = 3;
    r = try handleKey(alloc, &t, .{ .vk = vk.back, .ctrl = true }, null);
    try expectText(&t, "oit");
    try testing.expectEqual(@as(usize, 1), t.caret);
}

test "Backspace removes a whole surrogate pair" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "a\u{1F47B}");
    defer t.deinit(alloc);
    _ = try handleKey(alloc, &t, .{ .vk = vk.back }, null);
    try expectText(&t, "a");
    try testing.expectEqual(@as(usize, 1), t.caret);
}

test "clipboard keys report their intent" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "hello");
    defer t.deinit(alloc);
    // Without a selection, copy and cut do nothing.
    try testing.expectEqual(Clipboard.none, (try handleKey(alloc, &t, .{ .vk = 'C', .ctrl = true }, null)).clipboard);
    try testing.expectEqual(Clipboard.none, (try handleKey(alloc, &t, .{ .vk = vk.insert, .ctrl = true }, null)).clipboard);
    try testing.expectEqual(Clipboard.paste, (try handleKey(alloc, &t, .{ .vk = vk.insert, .shift = true }, null)).clipboard);
    try testing.expectEqual(Clipboard.paste, (try handleKey(alloc, &t, .{ .vk = 'V', .ctrl = true }, null)).clipboard);
    // Shift+Delete without a selection deletes like Delete.
    t.caret = 0;
    t.anchor = 0;
    var r = try handleKey(alloc, &t, .{ .vk = vk.delete, .shift = true }, null);
    try testing.expectEqual(Clipboard.none, r.clipboard);
    try expectText(&t, "ello");

    _ = try handleKey(alloc, &t, .{ .vk = 'A', .ctrl = true }, null);
    try testing.expectEqual(@as(usize, 4), selection(&t).len());
    try testing.expectEqual(Clipboard.copy, (try handleKey(alloc, &t, .{ .vk = vk.insert, .ctrl = true }, null)).clipboard);
    try testing.expectEqual(Clipboard.copy, (try handleKey(alloc, &t, .{ .vk = 'C', .ctrl = true, .shift = true }, null)).clipboard);
    r = try handleKey(alloc, &t, .{ .vk = vk.delete, .shift = true }, null);
    try testing.expectEqual(Clipboard.cut, r.clipboard);
    // The caller copies, then deletes.
    try expectText(&t, "ello");
    try testing.expect(try deleteSelection(alloc, &t));
    try expectText(&t, "");
    try reset(alloc, &t, L("xy"));
    selectAll(&t);
    try testing.expectEqual(Clipboard.cut, (try handleKey(alloc, &t, .{ .vk = 'X', .ctrl = true }, null)).clipboard);
    // Plain Insert is not an editing key here (no overwrite mode).
    try testing.expect(!(try handleKey(alloc, &t, .{ .vk = vk.insert }, null)).handled);
}

test "paste inserts the first line over the selection" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "find me");
    defer t.deinit(alloc);
    t.anchor = 5;
    t.caret = 7;
    try paste(alloc, &t, L("you\r\nand more"));
    try expectText(&t, "find you");
    try testing.expectEqual(@as(usize, 8), t.caret);
}

test "paste keeps the field within max_len" {
    const alloc = testing.allocator;
    var t: Text = .{};
    defer t.deinit(alloc);
    const huge = try alloc.alloc(u16, max_len * 3);
    defer alloc.free(huge);
    @memset(huge, 'x');
    try paste(alloc, &t, huge);
    try testing.expectEqual(max_len, t.buf.items.len);
    try testing.expectEqual(max_len, t.caret);
    // Full: nothing more goes in, and a failed paste is not an undo step.
    const steps = t.history.records.items.len;
    try paste(alloc, &t, L("y"));
    try testing.expectEqual(max_len, t.buf.items.len);
    try testing.expectEqual(steps, t.history.records.items.len);
    // The selection makes room for what replaces it.
    t.anchor = 0;
    t.caret = 10;
    try paste(alloc, &t, huge);
    try testing.expectEqual(max_len, t.buf.items.len);
    try testing.expectEqual(@as(usize, 10), t.caret);

    // The cut never splits a character: a surrogate pair or an accented
    // letter across the limit is left out whole.
    try reset(alloc, &t, huge[0 .. max_len - 1]);
    try paste(alloc, &t, L("\u{1F47B}"));
    try testing.expectEqual(max_len - 1, t.buf.items.len);
    try paste(alloc, &t, L("e\u{301}"));
    try testing.expectEqual(max_len - 1, t.buf.items.len);
    try paste(alloc, &t, L("ae\u{301}"));
    try testing.expectEqual(max_len, t.buf.items.len);
    try testing.expectEqual(@as(u16, 'a'), t.buf.items[max_len - 1]);
}

test "UTF-8 characters keep combining marks, sequences and flags" {
    const text = "a\u{1F468}\u{200D}\u{1F469}e\u{301}\u{1F1E8}\u{1F1F3}\xffb";
    var stops: [8]usize = undefined;
    var n: usize = 0;
    var p: usize = 0;
    while (p < text.len) : (n += 1) {
        stops[n] = p;
        p = nextCharUtf8(text, p);
    }
    // a, the joined pair, e with its accent, the flag, the invalid byte, b.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 12, 15, 23, 24 }, stops[0..n]);
    try testing.expectEqual(text.len, nextCharUtf8(text, text.len));
    // A sequence cut off at the end is one invalid byte at a time.
    try testing.expectEqual(@as(usize, 1), nextCharUtf8("\xe4\xb8", 0));
}

test "undo merges typing per word and redo replays it" {
    const alloc = testing.allocator;
    var t: Text = .{};
    defer t.deinit(alloc);
    for (L("new tab")) |unit| try typeText(alloc, &t, &.{unit});
    try expectText(&t, "new tab");
    // "new " and "tab" are two steps.
    try testing.expectEqual(@as(usize, 2), t.history.records.items.len);
    var r = try handleKey(alloc, &t, .{ .vk = 'Z', .ctrl = true }, null);
    try testing.expect(r.changed);
    try expectText(&t, "new ");
    r = try handleKey(alloc, &t, .{ .vk = 'Z', .ctrl = true }, null);
    try expectText(&t, "");
    r = try handleKey(alloc, &t, .{ .vk = 'Z', .ctrl = true }, null);
    try testing.expect(r.handled and !r.changed);
    r = try handleKey(alloc, &t, .{ .vk = 'Y', .ctrl = true }, null);
    try expectText(&t, "new ");
    r = try handleKey(alloc, &t, .{ .vk = 'Z', .ctrl = true, .shift = true }, null);
    try expectText(&t, "new tab");
    try testing.expectEqual(@as(usize, 7), t.caret);
    // Alt+Backspace undoes too.
    r = try handleKey(alloc, &t, .{ .vk = vk.back, .alt = true }, null);
    try expectText(&t, "new ");
}

test "undo merges consecutive Backspace and restores the selection" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "abcdef");
    defer t.deinit(alloc);
    for (0..3) |_| _ = try handleKey(alloc, &t, .{ .vk = vk.back }, null);
    try expectText(&t, "abc");
    try testing.expectEqual(@as(usize, 1), t.history.records.items.len);
    _ = try undo(alloc, &t);
    try expectText(&t, "abcdef");
    try testing.expectEqual(@as(usize, 6), t.caret);

    // Typing over a selection undoes back to the selection.
    t.anchor = 1;
    t.caret = 4;
    try typeText(alloc, &t, L("X"));
    try typeText(alloc, &t, L("Y"));
    try expectText(&t, "aXYef");
    _ = try undo(alloc, &t);
    try expectText(&t, "abcdef");
    try testing.expectEqual(@as(usize, 4), t.caret);
    try testing.expectEqual(@as(usize, 1), t.anchor);
    // A new edit drops the redo steps.
    try typeText(alloc, &t, L("Z"));
    try testing.expect(!t.history.canRedo());
}

test "undo gives up when the owner changed the text behind its back" {
    const alloc = testing.allocator;
    var t: Text = .{};
    defer t.deinit(alloc);
    try typeText(alloc, &t, L("abc"));
    // Like Palette.deleteWordBack, which edits buf directly.
    t.buf.items.len = 1;
    t.caret = 1;
    t.anchor = 1;
    try testing.expect(!try undo(alloc, &t));
    try testing.expect(!t.history.canUndo());
    try expectText(&t, "a");
}

test "the history keeps the last steps within its limits" {
    const alloc = testing.allocator;
    var t: Text = .{};
    defer t.deinit(alloc);
    for (0..History.max_records + 10) |_| try insertText(alloc, &t, L("x"));
    try testing.expectEqual(@as(usize, History.max_records), t.history.records.items.len);
    try testing.expectEqual(History.max_records, t.history.done);
    // A paste bigger than the unit budget is not undoable but works.
    const big = try alloc.alloc(u16, History.max_units + 1);
    defer alloc.free(big);
    @memset(big, 'y');
    try insertText(alloc, &t, big);
    try testing.expect(t.history.units <= History.max_units);
    try testing.expectEqual(History.max_records + 10 + big.len, t.buf.items.len);
}

test "pointer clicks place the caret, select a word or everything" {
    const alloc = testing.allocator;
    var t = try textOf(alloc, "ssh user@host");
    defer t.deinit(alloc);
    pointerDown(&t, 2, 1, false);
    try testing.expectEqual(@as(usize, 2), t.caret);
    try testing.expect(!hasSelection(&t));
    pointerDrag(&t, 8);
    try testing.expectEqual(@as(usize, 2), selection(&t).start);
    try testing.expectEqual(@as(usize, 8), selection(&t).end);
    pointerDown(&t, 6, 2, false);
    try testing.expectEqual(@as(usize, 4), selection(&t).start);
    try testing.expectEqual(@as(usize, 8), selection(&t).end);
    // Shift+click extends from the anchor, the start of the word.
    pointerDown(&t, 0, 1, true);
    try testing.expectEqual(@as(usize, 0), t.caret);
    try testing.expectEqual(@as(usize, 4), t.anchor);
    pointerDown(&t, 3, 3, false);
    try testing.expectEqual(t.buf.items.len, selection(&t).len());
    // A click inside a surrogate pair lands before it.
    try reset(alloc, &t, L("a\u{1F47B}b"));
    pointerDown(&t, 2, 1, false);
    try testing.expectEqual(@as(usize, 1), t.caret);
}
