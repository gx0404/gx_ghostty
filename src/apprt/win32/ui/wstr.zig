//! UTF-8 to NUL-terminated UTF-16 conversion for Win32 calls whose text is
//! only known at runtime (translated strings, titles, paths), and back.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Decoded = struct { cp: u21, len: usize };

/// Decode the codepoint at the start of `text` (non-empty); invalid UTF-8
/// decodes to U+FFFD and consumes one byte.
fn decode(text: []const u8) Decoded {
    const seq_len = std.unicode.utf8ByteSequenceLength(text[0]) catch
        return .{ .cp = 0xFFFD, .len = 1 };
    if (seq_len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[0..seq_len]) catch
        return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = seq_len };
}

/// The number of UTF-16 code units `bufZ` produces for `text`, without
/// the terminator.
pub fn utf16Len(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const d = decode(text[i..]);
        len += if (d.cp >= 0x10000) 2 else 1;
        i += d.len;
    }
    return len;
}

/// Convert `text` into `buf` and return the NUL-terminated result. Text
/// that does not fit is truncated at a codepoint boundary; invalid UTF-8
/// becomes U+FFFD. `buf` must have room for at least the terminator.
pub fn bufZ(buf: []u16, text: []const u8) [:0]const u16 {
    std.debug.assert(buf.len > 0);
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const d = decode(text[i..]);
        const cp = d.cp;
        const advance = d.len;
        const units: usize = if (cp >= 0x10000) 2 else 1;
        if (len + units >= buf.len) break;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            buf[len] = @intCast(0xD800 + (v >> 10));
            buf[len + 1] = @intCast(0xDC00 + (v & 0x3FF));
        } else {
            buf[len] = @intCast(cp);
        }
        len += units;
        i += advance;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

/// Convert `text` into a newly allocated NUL-terminated string.
pub fn allocZ(alloc: Allocator, text: []const u8) Allocator.Error![:0]u16 {
    const len = utf16Len(text);
    const buf = try alloc.allocSentinel(u16, len, 0);
    _ = bufZ(buf.ptr[0 .. len + 1], text);
    return buf;
}

/// The first `max_len` code units of `units` at most, without a high
/// surrogate at the end that has lost (or never had) its low surrogate.
pub fn truncate(units: []const u16, max_len: usize) []const u16 {
    var len = @min(units.len, max_len);
    if (len > 0 and std.unicode.utf16IsHighSurrogate(units[len - 1])) len -= 1;
    return units[0..len];
}

/// Decode the codepoint at the start of `units` (non-empty) and the number
/// of code units it takes; an unpaired surrogate decodes to U+FFFD.
fn decode16(units: []const u16) Decoded {
    const unit = units[0];
    if (std.unicode.utf16IsHighSurrogate(unit) and units.len > 1 and
        std.unicode.utf16IsLowSurrogate(units[1]))
    {
        const cp = std.unicode.utf16DecodeSurrogatePair(units[0..2]) catch unreachable;
        return .{ .cp = cp, .len = 2 };
    }
    if (std.unicode.utf16IsHighSurrogate(unit) or std.unicode.utf16IsLowSurrogate(unit)) {
        return .{ .cp = 0xFFFD, .len = 1 };
    }
    return .{ .cp = unit, .len = 1 };
}

/// Convert UTF-16 `units` into newly allocated UTF-8. Unpaired surrogates
/// become U+FFFD, so the result is always valid UTF-8.
pub fn utf8Alloc(alloc: Allocator, units: []const u16) Allocator.Error![]u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        const d = decode16(units[i..]);
        len += std.unicode.utf8CodepointSequenceLength(d.cp) catch unreachable;
        i += d.len;
    }
    const out = try alloc.alloc(u8, len);
    var written: usize = 0;
    i = 0;
    while (i < units.len) {
        const d = decode16(units[i..]);
        written += std.unicode.utf8Encode(d.cp, out[written..]) catch unreachable;
        i += d.len;
    }
    return out;
}

test "bufZ converts and terminates" {
    const testing = std.testing;
    var buf: [16]u16 = undefined;
    const out = bufZ(&buf, "a\u{4E2D}\u{1F47B}");
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(@as(u16, 'a'), out[0]);
    try testing.expectEqual(@as(u16, 0x4E2D), out[1]);
    try testing.expectEqual(@as(u16, 0xD83D), out[2]);
    try testing.expectEqual(@as(u16, 0xDC7B), out[3]);
    try testing.expectEqual(@as(u16, 0), buf[4]);
}

test "bufZ truncates at a codepoint boundary" {
    const testing = std.testing;
    var buf: [3]u16 = undefined;
    const out = bufZ(&buf, "a\u{1F47B}b");
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u16, 'a'), out[0]);
}

test "bufZ replaces invalid UTF-8" {
    const testing = std.testing;
    var buf: [8]u16 = undefined;
    const out = bufZ(&buf, "a\xffb\xe4");
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD }, out);
}

test "bufZ fills a buffer exactly and cuts one unit more" {
    const testing = std.testing;
    var buf: [256]u16 = undefined;
    const fits = "x" ** 255;
    try testing.expectEqual(@as(usize, 255), bufZ(&buf, fits).len);
    try testing.expectEqual(@as(u16, 0), buf[255]);
    const over = "x" ** 256;
    const out = bufZ(&buf, over);
    try testing.expectEqual(@as(usize, 255), out.len);
    try testing.expectEqual(@as(u16, 0), buf[255]);
    // A surrogate pair that would end one unit past the room is left out.
    const pair_at_end = "x" ** 254 ++ "\u{1F47B}";
    try testing.expectEqual(@as(usize, 254), bufZ(&buf, pair_at_end).len);
    const pair_fits = "x" ** 253 ++ "\u{1F47B}";
    const pair_out = bufZ(&buf, pair_fits);
    try testing.expectEqual(@as(usize, 255), pair_out.len);
    try testing.expectEqual(@as(u16, 0xDC7B), pair_out[254]);
}

test "bufZ keeps 200 CJK characters and cuts 300" {
    const testing = std.testing;
    var buf: [256]u16 = undefined;
    const two_hundred = "\u{6C49}" ** 200;
    const out = bufZ(&buf, two_hundred);
    try testing.expectEqual(@as(usize, 200), out.len);
    for (out) |unit| try testing.expectEqual(@as(u16, 0x6C49), unit);
    try testing.expectEqual(@as(usize, 255), bufZ(&buf, "\u{6C49}" ** 300).len);
}

test "bufZ into a small fixed buffer" {
    const testing = std.testing;
    // The title of a tray balloon (NOTIFYICONDATAW.szInfoTitle).
    var title: [64]u16 = undefined;
    try testing.expectEqual(@as(usize, 63), bufZ(&title, "\u{6C49}" ** 100).len);
    try testing.expectEqual(@as(u16, 0), title[63]);
    try testing.expectEqual(@as(usize, 2), bufZ(&title, "a\xc3").len);
}

test "allocZ" {
    const testing = std.testing;
    const out = try allocZ(testing.allocator, "\u{8BBE}\u{7F6E}");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &.{ 0x8BBE, 0x7F6E }, out);
}

test "allocZ converts a 5000 character URL" {
    const testing = std.testing;
    const url = "https://example.com/?q=" ++ "a" ** (5000 - 23);
    try testing.expectEqual(@as(usize, 5000), url.len);
    const out = try allocZ(testing.allocator, url);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 5000), out.len);
    try testing.expectEqual(@as(u16, 0), out.ptr[5000]);
    try testing.expectEqual(@as(u16, 'h'), out[0]);
    try testing.expectEqual(@as(u16, 'a'), out[4999]);
}

test "truncate never splits a surrogate pair" {
    const testing = std.testing;
    const units = [_]u16{ 'a', 0xD83D, 0xDC7B, 'b' };
    try testing.expectEqualSlices(u16, &units, truncate(&units, 8));
    try testing.expectEqualSlices(u16, units[0..3], truncate(&units, 3));
    try testing.expectEqualSlices(u16, units[0..1], truncate(&units, 2));
    try testing.expectEqualSlices(u16, units[0..1], truncate(&units, 1));
    try testing.expectEqual(@as(usize, 0), truncate(&units, 0).len);
    // A dangling high surrogate at the end goes too.
    const dangling = [_]u16{ 'a', 0xD83D };
    try testing.expectEqualSlices(u16, dangling[0..1], truncate(&dangling, 255));
}

test "utf8Alloc converts long CJK text and surrogate pairs" {
    const testing = std.testing;
    const units = [_]u16{0x6C49} ** 200;
    const out = try utf8Alloc(testing.allocator, &units);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 600), out.len);
    try testing.expectEqualStrings("\u{6C49}" ** 200, out);

    const ghost = try utf8Alloc(testing.allocator, &.{ 'a', 0xD83D, 0xDC7B });
    defer testing.allocator.free(ghost);
    try testing.expectEqualStrings("a\u{1F47B}", ghost);
}

test "utf8Alloc replaces unpaired surrogates" {
    const testing = std.testing;
    const out = try utf8Alloc(testing.allocator, &.{ 0xD83D, 'x', 0xDC7B, 0xD83D });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\u{FFFD}x\u{FFFD}\u{FFFD}", out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "utf8Alloc through a stack fallback allocator" {
    const testing = std.testing;
    // `Surface.sendImeText` converts with 256 bytes on the stack; longer
    // IME results go to the heap.
    var fallback = std.heap.stackFallback(256, testing.allocator);
    const alloc = fallback.get();
    const short = try utf8Alloc(alloc, &([_]u16{0x6C49} ** 10));
    defer alloc.free(short);
    try testing.expectEqual(@as(usize, 30), short.len);
    const long = try utf8Alloc(alloc, &([_]u16{0x6C49} ** 200));
    defer alloc.free(long);
    try testing.expectEqual(@as(usize, 600), long.len);
}
