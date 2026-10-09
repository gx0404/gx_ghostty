//! UTF-8 to NUL-terminated UTF-16 conversion for Win32 calls whose text is
//! only known at runtime (translated strings, titles, paths).
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

test "allocZ" {
    const testing = std.testing;
    const out = try allocZ(testing.allocator, "\u{8BBE}\u{7F6E}");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &.{ 0x8BBE, 0x7F6E }, out);
}
