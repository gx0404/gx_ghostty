//! File log sink for the win32 apprt. A GUI subsystem executable has no
//! console to print to, so log messages also go to
//! `%LOCALAPPDATA%\ghostty\logs\ghostty.log`. The file is created on the
//! first message of a run; the previous run's log is kept as
//! `ghostty.log.1`.
//!
//! Like stderr, the sink is process-wide: the log function has no
//! context to carry it, so the open file lives in this file's globals,
//! guarded by a lock that needs no initialization.
const std = @import("std");
const windows = std.os.windows;

const max_line = 8192;

var lock: SRWLOCK = .{};
var state: enum { closed, open, failed } = .closed;
var handle: windows.HANDLE = undefined;

pub fn write(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [max_line]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var time: SYSTEMTIME = undefined;
    GetLocalTime(&time);
    writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} [{d}] ", .{
        time.wHour,
        time.wMinute,
        time.wSecond,
        time.wMilliseconds,
        GetCurrentThreadId(),
    }) catch {};

    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    writer.print(level_txt ++ prefix ++ format ++ "\n", args) catch {
        // Too long for one line: keep what fits.
        buf[buf.len - 1] = '\n';
    };
    const line = writer.buffered();

    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    if (state == .closed) open();
    if (state != .open) return;

    var written: u32 = 0;
    _ = WriteFile(handle, line.ptr, @intCast(line.len), &written, null);
}

fn open() void {
    state = .failed;

    var path_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const base_len = GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"),
        &path_buf,
        path_buf.len,
    );
    if (base_len == 0 or base_len >= path_buf.len) return;

    var len: usize = base_len;
    const dirs = [_][]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("\\ghostty"),
        std.unicode.utf8ToUtf16LeStringLiteral("\\logs"),
    };
    for (dirs) |dir| {
        len = append(&path_buf, len, dir) orelse return;
        path_buf[len] = 0;
        // Fails harmlessly when the directory already exists.
        _ = CreateDirectoryW(path_buf[0..len :0], null);
    }

    len = append(&path_buf, len, std.unicode.utf8ToUtf16LeStringLiteral("\\ghostty.log")) orelse return;
    path_buf[len] = 0;
    const path = path_buf[0..len :0];

    var old_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    @memcpy(old_buf[0..len], path);
    const old_len = append(&old_buf, len, std.unicode.utf8ToUtf16LeStringLiteral(".1")) orelse return;
    old_buf[old_len] = 0;
    _ = MoveFileExW(path, old_buf[0..old_len :0], MOVEFILE_REPLACE_EXISTING);

    const file = CreateFileW(
        path,
        GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (file == windows.INVALID_HANDLE_VALUE) return;

    handle = file;
    state = .open;
}

fn append(buf: []u16, len: usize, value: []const u16) ?usize {
    // Keep room for the sentinel.
    if (len + value.len >= buf.len) return null;
    @memcpy(buf[len..][0..value.len], value);
    return len + value.len;
}

const SRWLOCK = extern struct { ptr: ?*anyopaque = null };

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

const GENERIC_WRITE = 0x40000000;
const FILE_SHARE_READ = 0x00000001;
const FILE_SHARE_WRITE = 0x00000002;
const FILE_SHARE_DELETE = 0x00000004;
const CREATE_ALWAYS = 2;
const FILE_ATTRIBUTE_NORMAL = 0x80;
const MOVEFILE_REPLACE_EXISTING = 0x1;

extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
