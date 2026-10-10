//! Opening URLs with their default handler (`ShellExecuteW`). The shell can
//! pump messages while it hands a URL over (DDE, COM calls to shell
//! extensions), and the core asks to open a clicked link while it holds the
//! terminal lock (`Surface.processLinks`): a window procedure run from that
//! pump which takes the lock again would hang the GUI thread for good. So
//! the URL is copied and opened on a thread of its own, which owns no
//! windows. `internal_os.open` is not used: it starts `rundll32` as a child
//! process.
const std = @import("std");
const w32 = @import("win32.zig");
const wstr = @import("ui/wstr.zig");

const log = std.log.scoped(.win32);

/// The thread that opens a URL frees its copy, so the copy comes from an
/// allocator any thread can use.
const alloc = std.heap.page_allocator;

/// Open `url` without waiting for the shell. Failures are logged with the
/// length of the URL only, since a URL can carry private data.
pub fn open(url: []const u8) void {
    const url_w = wstr.allocZ(alloc, url) catch |err| {
        log.warn("cannot open a URL err={} len={}", .{ err, url.len });
        return;
    };
    const thread = std.Thread.spawn(.{}, openThread, .{ url_w, url.len }) catch |err| {
        log.warn("cannot open a URL err={} len={}", .{ err, url.len });
        alloc.free(url_w);
        return;
    };
    thread.detach();
}

fn openThread(url_w: [:0]u16, len: usize) void {
    defer alloc.free(url_w);

    // The shell may hand the URL to extensions that need COM.
    const hr = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED | w32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) w32.CoUninitialize();

    const result = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        url_w,
        null,
        null,
        w32.SW_SHOW,
    );
    // Values up to 32 are errors (SE_ERR_*).
    if (result <= 32) log.warn("cannot open a URL code={} len={}", .{ result, len });
}
