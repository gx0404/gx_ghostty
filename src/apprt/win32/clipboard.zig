//! The Windows clipboard for the terminals, dialogs and popup text inputs.
//!
//! Another application can hold the clipboard open for a moment (clipboard
//! managers, remote desktop tools such as RustDesk or ToDesk syncing it),
//! and `OpenClipboard` fails meanwhile, so `open` tries a few times with a
//! short pause in between, as Windows Terminal does. The pauses block the
//! calling (GUI) thread: `attempts` and `retry_delay_ms` keep that short,
//! and callers that can wait longer retry from a timer (`Surface`).
//!
//! Text goes on the clipboard as CF_UNICODETEXT and, for rich text, as
//! "HTML Format" (`htmlDocument`); text read back is bounded by the size of
//! its memory block and decoded leniently (`unicodeText`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const wstr = @import("ui/wstr.zig");

const log = std.log.scoped(.win32);

/// How many times `open` tries, and the pause between two tries (at least
/// one system timer tick in practice).
pub const attempts = 10;
pub const retry_delay_ms = 5;

/// Open the clipboard for `owner`, waiting while another application holds
/// it. When this returns true the caller closes it with
/// `w32.CloseClipboard`.
pub fn open(owner: ?w32.HWND) bool {
    return retry(owner, tryOpen, pause);
}

/// One representation of a clipboard write: a moveable memory block
/// (`GlobalAlloc(GMEM_MOVEABLE)`) holding the data in `format`.
pub const Item = struct {
    format: u32,
    data: *anyopaque,
};

/// Replace the clipboard contents with `items`, which the clipboard owns
/// afterwards (a block it does not take is freed). Fails without touching
/// them when the clipboard stays busy.
pub fn setData(owner: ?w32.HWND, items: []const Item) error{ClipboardBusy}!void {
    _ = try setDataChecked(owner, items);
}

/// As setData, but true only when the clipboard accepted a representation.
pub fn setDataChecked(owner: ?w32.HWND, items: []const Item) error{ClipboardBusy}!bool {
    if (!open(owner)) return error.ClipboardBusy;
    defer _ = w32.CloseClipboard();
    if (w32.EmptyClipboard() == 0) {
        for (items) |item| _ = w32.GlobalFree(item.data);
        return false;
    }
    return transferItems({}, items, transferItem, freeItem);
}

fn transferItems(context: anytype, items: []const Item, comptime transfer: fn (@TypeOf(context), Item) bool, comptime release: fn (@TypeOf(context), Item) void) bool {
    var accepted = false;
    for (items) |item| {
        if (transfer(context, item)) {
            accepted = true;
        } else {
            release(context, item);
        }
    }
    return accepted;
}

fn transferItem(_: void, item: Item) bool {
    if (w32.SetClipboardData(item.format, item.data) != null) return true;
    log.warn("SetClipboardData failed format={d}", .{item.format});
    return false;
}

fn freeItem(_: void, item: Item) void {
    _ = w32.GlobalFree(item.data);
}

test "clipboard copy feedback requires a successful format transfer" {
    const Fake = struct {
        accepted_format: u32,
        released: usize = 0,

        fn transfer(self: *@This(), item: Item) bool {
            return item.format == self.accepted_format;
        }

        fn release(self: *@This(), _: Item) void {
            self.released += 1;
        }
    };
    const items = [_]Item{ .{ .format = 1, .data = @ptrFromInt(1) }, .{ .format = 2, .data = @ptrFromInt(2) } };
    var failed: Fake = .{ .accepted_format = 3 };
    try std.testing.expect(!transferItems(&failed, &items, Fake.transfer, Fake.release));
    try std.testing.expectEqual(@as(usize, 2), failed.released);
    var partial: Fake = .{ .accepted_format = 1 };
    try std.testing.expect(transferItems(&partial, &items, Fake.transfer, Fake.release));
    try std.testing.expectEqual(@as(usize, 1), partial.released);
}

/// Replace the clipboard contents with `data`, a moveable CF_UNICODETEXT
/// memory block, which the clipboard owns afterwards (it is freed when the
/// clipboard does not take it). Fails without touching `data` when the
/// clipboard stays busy.
pub fn setUnicodeText(owner: ?w32.HWND, data: *anyopaque) error{ClipboardBusy}!void {
    return setData(owner, &.{.{ .format = w32.CF_UNICODETEXT, .data = data }});
}

/// `text` (UTF-8; invalid sequences become U+FFFD) as a moveable,
/// NUL-terminated CF_UNICODETEXT memory block, or null when Windows could
/// not allocate it.
pub fn unicodeTextBlock(alloc: Allocator, text: []const u8) Allocator.Error!?*anyopaque {
    const utf16 = try wstr.allocZ(alloc, text);
    defer alloc.free(utf16);
    return block(std.mem.sliceAsBytes(utf16[0..utf16.len]), @sizeOf(u16));
}

/// `bytes` followed by a NUL as a moveable memory block (the "HTML Format"
/// payload is NUL-terminated UTF-8), or null when Windows could not
/// allocate it.
pub fn bytesBlock(bytes: []const u8) ?*anyopaque {
    return block(bytes, 1);
}

/// A moveable memory block holding a copy of `bytes` and `nul_len` zero
/// bytes after them.
fn block(bytes: []const u8, nul_len: usize) ?*anyopaque {
    const handle = w32.GlobalAlloc(w32.GMEM_MOVEABLE, bytes.len + nul_len) orelse {
        log.warn("GlobalAlloc failed for a clipboard write", .{});
        return null;
    };
    const dst = w32.GlobalLock(handle) orelse {
        log.warn("GlobalLock failed for a clipboard write", .{});
        _ = w32.GlobalFree(handle);
        return null;
    };
    @memcpy(dst[0..bytes.len], bytes);
    @memset(dst[bytes.len..][0..nul_len], 0);
    _ = w32.GlobalUnlock(handle);
    return handle;
}

/// The text of the CF_UNICODETEXT memory block `handle` as newly allocated
/// UTF-8: up to its terminating NUL, within the block (a careless producer
/// can leave the NUL out), with unpaired surrogates as U+FFFD. Null when
/// the block cannot be locked. The clipboard must be open.
pub fn unicodeText(alloc: Allocator, handle: *anyopaque) Allocator.Error!?[]u8 {
    const bytes = w32.GlobalLock(handle) orelse return null;
    defer _ = w32.GlobalUnlock(handle);
    const units: [*]const u16 = @ptrCast(@alignCast(bytes));
    return try wstr.utf8Alloc(alloc, terminated(units[0 .. w32.GlobalSize(handle) / 2]));
}

/// `units` up to the first NUL, or all of them when there is none.
fn terminated(units: []const u16) []const u16 {
    return units[0 .. std.mem.indexOfScalar(u16, units, 0) orelse units.len];
}

/// The registered clipboard format of rich text, "HTML Format"; 0 when it
/// cannot be registered.
pub fn htmlFormat() u32 {
    return w32.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format"));
}

const html_prefix = "<html>\r\n<body>\r\n<!--StartFragment-->";
const html_suffix = "<!--EndFragment-->\r\n</body>\r\n</html>";
const html_header_len = ("Version:0.9\r\n" ++
    "StartHTML:0000000000\r\n" ++
    "EndHTML:0000000000\r\n" ++
    "StartFragment:0000000000\r\n" ++
    "EndFragment:0000000000\r\n").len;

/// The "HTML Format" payload for the HTML `fragment` (UTF-8): the header
/// with the byte offsets of the document and of the fragment, then the
/// document, with the fragment between the comments that mark it for the
/// pasting application.
pub fn htmlDocument(alloc: Allocator, fragment: []const u8) Allocator.Error![]u8 {
    const start_html = html_header_len;
    const start_fragment = start_html + html_prefix.len;
    const end_fragment = start_fragment + fragment.len;
    const end_html = end_fragment + html_suffix.len;
    return std.fmt.allocPrint(
        alloc,
        "Version:0.9\r\n" ++
            "StartHTML:{d:0>10}\r\n" ++
            "EndHTML:{d:0>10}\r\n" ++
            "StartFragment:{d:0>10}\r\n" ++
            "EndFragment:{d:0>10}\r\n" ++
            html_prefix ++ "{s}" ++ html_suffix,
        .{ start_html, end_html, start_fragment, end_fragment, fragment },
    );
}

/// Call `tryOnce` up to `attempts` times, calling `wait` between two
/// tries, until a try succeeds; whether one did.
fn retry(
    context: anytype,
    comptime tryOnce: fn (@TypeOf(context)) bool,
    comptime wait: fn (@TypeOf(context)) void,
) bool {
    for (0..attempts) |i| {
        if (i > 0) wait(context);
        if (tryOnce(context)) return true;
    }
    return false;
}

fn tryOpen(owner: ?w32.HWND) bool {
    return w32.OpenClipboard(owner) != 0;
}

fn pause(_: ?w32.HWND) void {
    w32.Sleep(retry_delay_ms);
}

test "retry waits between a bounded number of tries" {
    const testing = std.testing;
    const Clipboard = struct {
        /// The try that finds the clipboard free (0: never).
        free_at: usize,
        tries: usize = 0,
        waits: usize = 0,

        fn tryOnce(self: *@This()) bool {
            self.tries += 1;
            return self.tries == self.free_at;
        }

        fn wait(self: *@This()) void {
            self.waits += 1;
        }
    };

    // Free right away: no pause.
    var free: Clipboard = .{ .free_at = 1 };
    try testing.expect(retry(&free, Clipboard.tryOnce, Clipboard.wait));
    try testing.expectEqual(@as(usize, 1), free.tries);
    try testing.expectEqual(@as(usize, 0), free.waits);

    // Released after a moment.
    var brief: Clipboard = .{ .free_at = 3 };
    try testing.expect(retry(&brief, Clipboard.tryOnce, Clipboard.wait));
    try testing.expectEqual(@as(usize, 3), brief.tries);
    try testing.expectEqual(@as(usize, 2), brief.waits);

    // The last try still counts.
    var late: Clipboard = .{ .free_at = attempts };
    try testing.expect(retry(&late, Clipboard.tryOnce, Clipboard.wait));
    try testing.expectEqual(@as(usize, attempts - 1), late.waits);

    // Held throughout: give up after the last try, without a pause after it.
    var held: Clipboard = .{ .free_at = 0 };
    try testing.expect(!retry(&held, Clipboard.tryOnce, Clipboard.wait));
    try testing.expectEqual(@as(usize, attempts), held.tries);
    try testing.expectEqual(@as(usize, attempts - 1), held.waits);
}

/// The value of the header field `name` (e.g. "StartHTML:") of an "HTML
/// Format" payload.
fn htmlOffset(doc: []const u8, name: []const u8) !usize {
    const start = (std.mem.indexOf(u8, doc, name) orelse return error.TestUnexpectedResult) + name.len;
    const end = std.mem.indexOfScalarPos(u8, doc, start, '\r') orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(usize, doc[start..end], 10);
}

test "htmlDocument points at the document and the fragment" {
    const testing = std.testing;
    const fragment = "<div style=\"font-family: monospace;\">a &lt; b \xe4\xb8\xad</div>";
    const doc = try htmlDocument(testing.allocator, fragment);
    defer testing.allocator.free(doc);

    const start_html = try htmlOffset(doc, "StartHTML:");
    const end_html = try htmlOffset(doc, "EndHTML:");
    const start_fragment = try htmlOffset(doc, "StartFragment:");
    const end_fragment = try htmlOffset(doc, "EndFragment:");

    try testing.expectEqualStrings(fragment, doc[start_fragment..end_fragment]);
    try testing.expect(std.mem.startsWith(u8, doc[start_html..], "<html>"));
    try testing.expectEqual(doc.len, end_html);
    try testing.expect(std.mem.endsWith(u8, doc, "</html>"));
    try testing.expect(std.mem.endsWith(u8, doc[0..start_fragment], "<!--StartFragment-->"));
    try testing.expect(std.mem.startsWith(u8, doc[end_fragment..], "<!--EndFragment-->"));
    // The header is ASCII and always the same length.
    try testing.expectEqual(html_header_len, start_html);

    const empty = try htmlDocument(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqual(try htmlOffset(empty, "StartFragment:"), try htmlOffset(empty, "EndFragment:"));
}

test "terminated stops at the first NUL or the end of the block" {
    const testing = std.testing;
    const text = [_]u16{ 'a', 'b', 0, 'c' };
    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, terminated(&text));
    const unterminated = [_]u16{ 'a', 'b', 'c' };
    try testing.expectEqualSlices(u16, &unterminated, terminated(&unterminated));
    try testing.expectEqual(@as(usize, 0), terminated(&.{}).len);
}
