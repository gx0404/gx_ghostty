//! Opening the Windows clipboard for the terminals, dialogs and popup text
//! inputs. Another application can hold the clipboard open for a moment
//! (clipboard managers, remote desktop tools such as RustDesk or ToDesk
//! syncing it), and `OpenClipboard` fails meanwhile, so `open` tries a few
//! times with a short pause in between, as Windows Terminal does. The
//! pauses block the calling (GUI) thread: `attempts` and `retry_delay_ms`
//! keep that short, and callers that can wait longer retry from a timer
//! (`Surface`).
const std = @import("std");
const w32 = @import("win32.zig");

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

/// Replace the clipboard contents with `data`, a moveable CF_UNICODETEXT
/// memory block, which the clipboard owns afterwards (it is freed when the
/// clipboard does not take it). Fails without touching `data` when the
/// clipboard stays busy.
pub fn setUnicodeText(owner: ?w32.HWND, data: *anyopaque) error{ClipboardBusy}!void {
    if (!open(owner)) return error.ClipboardBusy;
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, data) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(data);
    }
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
