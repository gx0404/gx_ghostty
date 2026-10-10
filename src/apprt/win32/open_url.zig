//! Opening URLs and files with their default handler (`ShellExecuteW`).
//! The shell can pump messages while it hands a URL over (DDE, COM calls
//! to shell extensions), and the core asks to open a clicked link while it
//! holds the terminal lock (`Surface.processLinks`): a window procedure run
//! from that pump which takes the lock again would hang the GUI thread for
//! good. So the URL is copied and opened on a thread of its own, which owns
//! no windows. `internal_os.open` is not used: it starts `rundll32` as a
//! child process.
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

/// Open the file `path` (UTF-8) with the program its type is associated
/// with, without waiting for it. A type without one (`.ghostty`, for
/// example) gets the system's "Open with" dialog, and when that cannot be
/// shown, Notepad (`fallbackFor`). Returns false when the thread that opens
/// it could not start.
pub fn openFile(path: []const u8) bool {
    const path_w = wstr.allocZ(alloc, path) catch |err| {
        log.warn("cannot open a file err={}", .{err});
        return false;
    };
    const thread = std.Thread.spawn(.{}, openFileThread, .{path_w}) catch |err| {
        log.warn("cannot open a file err={}", .{err});
        alloc.free(path_w);
        return false;
    };
    thread.detach();
    return true;
}

/// What to try after opening a file with its association failed with the
/// Win32 error `err`.
pub const Fallback = enum {
    /// The type has no association: let the user pick a program.
    open_with,
    /// Open it in Notepad, which reads any text file.
    notepad,
};

pub fn fallbackFor(err: u32) Fallback {
    return switch (err) {
        ERROR_NO_ASSOCIATION => .open_with,
        else => .notepad,
    };
}

fn openFileThread(path_w: [:0]u16) void {
    defer alloc.free(path_w);

    const hr = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED | w32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) w32.CoUninitialize();

    // Without UI: a missing association is told by the error, and the
    // "Open with" dialog below is the only one the user sees.
    var info: SHELLEXECUTEINFOW = .{
        .fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC,
        .lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("open"),
        .lpFile = path_w,
        .nShow = w32.SW_SHOW,
    };
    if (ShellExecuteExW(&info) != 0) return;
    const err = GetLastError();

    if (fallbackFor(err) == .open_with) {
        const open_as: OPENASINFO = .{
            .pcszFile = path_w,
            .oaifInFlags = OAIF_ALLOW_REGISTRATION | OAIF_EXEC,
        };
        const result = SHOpenWithDialog(null, &open_as);
        // Picked a program, or decided not to open the file.
        if (result >= 0 or result == HRESULT_CANCELLED) return;
        log.warn("cannot show the open with dialog hr=0x{x}", .{@as(u32, @bitCast(result))});
    }

    // Windows file names cannot contain a double quote.
    const quoted = std.mem.concatWithSentinel(alloc, u16, &.{
        std.unicode.utf8ToUtf16LeStringLiteral("\""),
        path_w,
        std.unicode.utf8ToUtf16LeStringLiteral("\""),
    }, 0) catch return;
    defer alloc.free(quoted);
    const result = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe"),
        quoted,
        null,
        w32.SW_SHOW,
    );
    if (result <= 32) log.warn("cannot open a file err={} notepad={}", .{ err, result });
}

const ERROR_NO_ASSOCIATION: u32 = 1155;
const HRESULT_CANCELLED: w32.HRESULT = @bitCast(@as(u32, 0x800704C7));

const SEE_MASK_NOASYNC: u32 = 0x00000100;
const SEE_MASK_FLAG_NO_UI: u32 = 0x00000400;

const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
    fMask: u32 = 0,
    hwnd: ?w32.HWND = null,
    lpVerb: ?[*:0]const u16 = null,
    lpFile: ?[*:0]const u16 = null,
    lpParameters: ?[*:0]const u16 = null,
    lpDirectory: ?[*:0]const u16 = null,
    nShow: i32 = 0,
    hInstApp: ?*anyopaque = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?[*:0]const u16 = null,
    hkeyClass: ?*anyopaque = null,
    dwHotKey: u32 = 0,
    hIconOrMonitor: ?*anyopaque = null,
    hProcess: ?*anyopaque = null,
};

const OAIF_ALLOW_REGISTRATION: u32 = 0x00000001;
const OAIF_EXEC: u32 = 0x00000004;

const OPENASINFO = extern struct {
    pcszFile: [*:0]const u16,
    pcszClass: ?[*:0]const u16 = null,
    oaifInFlags: u32,
};

extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) i32;
extern "shell32" fn SHOpenWithDialog(parent: ?w32.HWND, info: *const OPENASINFO) callconv(.winapi) w32.HRESULT;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

test "a file type without an association gets the open with dialog" {
    const testing = std.testing;
    try testing.expectEqual(Fallback.open_with, fallbackFor(ERROR_NO_ASSOCIATION));
    // File not found, access denied: Notepad says what is wrong.
    try testing.expectEqual(Fallback.notepad, fallbackFor(2));
    try testing.expectEqual(Fallback.notepad, fallbackFor(5));
}

test "SHELLEXECUTEINFOW has the size of the Windows SDK structure" {
    const expected: usize = if (@sizeOf(usize) == 8) 112 else 60;
    try std.testing.expectEqual(expected, @sizeOf(SHELLEXECUTEINFOW));
}
