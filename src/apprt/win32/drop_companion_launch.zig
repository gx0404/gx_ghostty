//! GUI-thread launcher for the medium-integrity drop receiver (DropCompanion).
//! The elevated terminal cannot receive drops from normal-privilege windows
//! (UIPI), so it opens a separate normal-privilege receiver. This is a standard
//! same-user de-elevation: it duplicates the elevated token's own linked
//! (limited) token and starts the receiver with it via CreateProcessWithTokenW.
//! It never bypasses UAC, never relaxes a UIPI message filter, and never falls
//! back to a privileged launch (runas / high CreateProcess). On any failure it
//! returns a distinct Outcome so the caller can explain why nothing opened.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("App.zig");
const n = @import("ipc/native.zig");
const Identity = @import("shell/Identity.zig");
const windows_argv = @import("../../gx/windows_argv.zig");
const HANDLE = n.HANDLE;

const log = std.log.scoped(.win32_drop_launch);

/// What a launch attempt produced. The caller shows an explanation for every
/// value other than `.launched`; the receiver opens its own window on success.
pub const Outcome = enum {
    /// A de-elevated receiver process was started.
    launched,
    /// This window is not a full elevated token, so it has no linked medium
    /// token to de-elevate to (for example, User Account Control is off).
    not_elevated,
    /// The elevated token reports no usable linked token.
    no_linked_token,
    /// The duplicated child token was not a de-elevated medium token; the
    /// launch is refused rather than risk starting another elevated process.
    not_medium,
    /// The token query, duplication or process creation failed.
    launch_failed,
};

// TOKEN_INFORMATION_CLASS values (winnt.h).
const token_elevation_type: c_int = 18;
const token_linked_token: c_int = 19;
const token_elevation: c_int = 20;
const token_integrity_level: c_int = 25;

// TOKEN_ELEVATION_TYPE values (winnt.h): only a full token has a linked medium
// token to de-elevate to.
const token_elevation_type_full: u32 = 2;

// Mandatory integrity RIDs (winnt.h). Only the medium band can use the broker.
const integrity_medium: u32 = 0x2000;
const integrity_high: u32 = 0x3000;

const token_query: u32 = 0x0008;
const maximum_allowed: u32 = 0x02000000;
const security_impersonation: c_int = 2;
const token_primary: c_int = 1;
const create_unicode_environment: u32 = 0x0000_0400;

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?[*]u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW([*]u16) callconv(.winapi) i32;
extern "advapi32" fn OpenProcessToken(HANDLE, u32, *HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(HANDLE, c_int, ?*anyopaque, u32, *u32) callconv(.winapi) i32;
extern "advapi32" fn DuplicateTokenEx(HANDLE, u32, ?*anyopaque, c_int, c_int, *HANDLE) callconv(.winapi) i32;
extern "advapi32" fn CreateProcessWithTokenW(HANDLE, u32, ?[*:0]const u16, ?[*:0]u16, u32, ?*anyopaque, ?[*:0]const u16, *STARTUPINFOW, *PROCESS_INFORMATION) callconv(.winapi) i32;
extern "advapi32" fn IsValidSid(*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn GetSidSubAuthorityCount(*anyopaque) callconv(.winapi) *u8;
extern "advapi32" fn GetSidSubAuthority(*anyopaque, u32) callconv(.winapi) *u32;

/// Only a full elevated token owns a linked limited token to de-elevate to.
pub fn canDeElevate(elevation_type: u32) bool {
    return elevation_type == token_elevation_type_full;
}

/// Match DropCompanion's medium-only contract before creating a process.
pub fn acceptableChildToken(elevated: u32, integrity_rid: u32) bool {
    return elevated == 0 and integrity_rid >= integrity_medium and integrity_rid < integrity_high;
}

/// The command line that starts a drop receiver bound to one elevated process.
/// Keeps the exact PID/birth decode contract of `Identity.parseStartup`.
pub fn buildCommandLine(alloc: std.mem.Allocator, exe: []const u8, pid: u32, birth: u64) ![:0]u16 {
    var pid_buf: [64]u8 = undefined;
    var birth_buf: [64]u8 = undefined;
    const pid_arg = try std.fmt.bufPrint(&pid_buf, "--gx-drop-target-pid={d}", .{pid});
    const birth_arg = try std.fmt.bufPrint(&birth_buf, "--gx-drop-target-birth={d}", .{birth});
    return windows_argv.encode(alloc, &.{
        exe,
        Identity.action_switch ++ "drop-companion",
        pid_arg,
        birth_arg,
    });
}

fn integrityRid(token: HANDLE) ?u32 {
    var buffer: [256]u8 align(8) = undefined;
    var size: u32 = 0;
    if (GetTokenInformation(token, token_integrity_level, @ptrCast(&buffer), buffer.len, &size) == 0 or size < @sizeOf(usize)) return null;
    const sid = @as(*const ?*anyopaque, @ptrCast(@alignCast(&buffer))).* orelse return null;
    if (IsValidSid(sid) == 0) return null;
    const count = GetSidSubAuthorityCount(sid).*;
    if (count == 0) return null;
    return GetSidSubAuthority(sid, count - 1).*;
}

/// Start a normal-privilege drop receiver for this elevated terminal. GUI
/// thread only. Never pumps messages or enters a modal loop.
pub fn launch(app: *App) Outcome {
    var self_token: HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), token_query, &self_token) == 0) {
        log.warn("OpenProcessToken failed err={}", .{n.GetLastError()});
        return .launch_failed;
    }
    defer _ = n.CloseHandle(self_token);

    var elevation_type: u32 = 0;
    var returned: u32 = 0;
    if (GetTokenInformation(self_token, token_elevation_type, @ptrCast(&elevation_type), @sizeOf(u32), &returned) == 0) {
        log.warn("TokenElevationType query failed err={}", .{n.GetLastError()});
        return .launch_failed;
    }
    if (!canDeElevate(elevation_type)) return .not_elevated;

    var linked: HANDLE = undefined;
    if (GetTokenInformation(self_token, token_linked_token, @ptrCast(&linked), @sizeOf(HANDLE), &returned) == 0) {
        log.warn("TokenLinkedToken query failed err={}", .{n.GetLastError()});
        return .no_linked_token;
    }
    defer _ = n.CloseHandle(linked);

    var primary: HANDLE = undefined;
    if (DuplicateTokenEx(linked, maximum_allowed, null, security_impersonation, token_primary, &primary) == 0) {
        log.warn("DuplicateTokenEx failed err={}", .{n.GetLastError()});
        return .launch_failed;
    }
    defer _ = n.CloseHandle(primary);

    var child_elevated: u32 = 0;
    if (GetTokenInformation(primary, token_elevation, @ptrCast(&child_elevated), @sizeOf(u32), &returned) == 0) {
        log.warn("child TokenElevation query failed err={}", .{n.GetLastError()});
        return .launch_failed;
    }
    const rid = integrityRid(primary) orelse return .launch_failed;
    if (!acceptableChildToken(child_elevated, rid)) return .not_medium;

    var image: [32768]u16 = undefined;
    var image_size: u32 = image.len;
    if (n.QueryFullProcessImageNameW(GetCurrentProcess(), 0, &image, &image_size) == 0 or image_size == 0 or image_size >= image.len) {
        log.warn("QueryFullProcessImageNameW failed err={}", .{n.GetLastError()});
        return .launch_failed;
    }
    image[image_size] = 0;

    const alloc = app.core_app.alloc;
    const exe_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, image[0..image_size]) catch return .launch_failed;
    defer alloc.free(exe_utf8);
    var birth: u64 = 0;
    var unused: u64 = 0;
    if (n.GetProcessTimes(GetCurrentProcess(), &birth, &unused, &unused, &unused) == 0) return .launch_failed;
    const command = buildCommandLine(alloc, exe_utf8, n.GetCurrentProcessId(), birth) catch |err| {
        log.warn("drop receiver command line could not be built: {}", .{err});
        return .launch_failed;
    };
    defer alloc.free(command);

    // Inherit this process's exact environment so the receiver resolves the
    // same isolation directory (LOCALAPPDATA/XDG_CONFIG_HOME), never the real
    // per-user config by accident.
    const environment = GetEnvironmentStringsW() orelse return .launch_failed;
    defer _ = FreeEnvironmentStringsW(environment);

    var startup: STARTUPINFOW = .{ .cb = @sizeOf(STARTUPINFOW) };
    var info: PROCESS_INFORMATION = .{};
    if (CreateProcessWithTokenW(
        primary,
        0,
        @ptrCast(&image),
        command.ptr,
        create_unicode_environment,
        @ptrCast(environment),
        null,
        &startup,
        &info,
    ) == 0) {
        log.warn("CreateProcessWithTokenW failed err={}", .{n.GetLastError()});
        return .launch_failed;
    }
    if (info.hThread) |thread| _ = n.CloseHandle(thread);
    if (info.hProcess) |process| _ = n.CloseHandle(process);
    log.info("started a normal-privilege drop receiver for elevated pid={}", .{n.GetCurrentProcessId()});
    return .launched;
}

test "only a full elevated token can de-elevate to a linked medium token" {
    try std.testing.expect(canDeElevate(token_elevation_type_full));
    try std.testing.expect(!canDeElevate(1)); // TokenElevationTypeDefault
    try std.testing.expect(!canDeElevate(3)); // TokenElevationTypeLimited
    try std.testing.expect(!canDeElevate(0));
}

test "a drop receiver child token must be de-elevated and in the medium integrity band" {
    try std.testing.expect(acceptableChildToken(0, 0x2000)); // medium, not elevated
    try std.testing.expect(acceptableChildToken(0, 0x2100)); // medium plus, not elevated
    try std.testing.expect(!acceptableChildToken(0, 0x1000)); // low is not a broker receiver
    try std.testing.expect(!acceptableChildToken(1, 0x2000)); // elevated flag set
    try std.testing.expect(!acceptableChildToken(0, 0x3000)); // high integrity
    try std.testing.expect(!acceptableChildToken(0, 0x4000)); // system integrity
}

test "companion command line round-trips the launching identity through parseStartup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const exe = "C:\\Program Files\\Ghostty GX\\ghostty.exe";
    const command = try buildCommandLine(testing.allocator, exe, 4242, 133_000_000_000_000_001);
    defer testing.allocator.free(command);
    var count: c_int = 0;
    const argv = CommandLineToArgvW(command, &count) orelse return error.DecodeFailed;
    defer _ = LocalFree(@ptrCast(argv));
    try testing.expectEqual(@as(c_int, 4), count);
    const total: usize = @intCast(count);
    var owned: [4][]const u8 = undefined;
    var filled: usize = 0;
    defer for (owned[0..filled]) |value| testing.allocator.free(value);
    for (0..total) |index| {
        owned[index] = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.span(argv[index]));
        filled += 1;
    }
    try testing.expectEqualStrings(exe, owned[0]);
    const parsed = try Identity.parseStartup(owned[1..4]);
    try testing.expectEqual(@as(u32, 4242), parsed.drop_companion.pid);
    try testing.expectEqual(@as(u64, 133_000_000_000_000_001), parsed.drop_companion.birth);
}

extern "shell32" fn CommandLineToArgvW([*:0]const u16, *c_int) callconv(.winapi) ?[*][*:0]u16;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
