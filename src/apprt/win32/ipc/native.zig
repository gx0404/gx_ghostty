//! Small native IPC ABI and cancellable overlapped byte transport.
const std = @import("std");
pub const HANDLE = std.os.windows.HANDLE;
pub const INVALID = std.os.windows.INVALID_HANDLE_VALUE;
pub const SA = std.os.windows.SECURITY_ATTRIBUTES;
pub const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u64 = 0,
    event: ?HANDLE = null,
};
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) i32;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
pub extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetProcessTimes(HANDLE, *u64, *u64, *u64, *u64) callconv(.winapi) i32;
pub extern "kernel32" fn QueryFullProcessImageNameW(HANDLE, u32, [*]u16, *u32) callconv(.winapi) i32;
pub extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, i32) callconv(.winapi) i32;
pub extern "kernel32" fn CreateNamedPipeW([*:0]const u16, u32, u32, u32, u32, u32, u32, ?*SA) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ConnectNamedPipe(HANDLE, *Overlapped) callconv(.winapi) i32;
pub extern "kernel32" fn DisconnectNamedPipe(HANDLE) callconv(.winapi) i32;
pub extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*SA, u32, u32, ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WaitNamedPipeW([*:0]const u16, u32) callconv(.winapi) i32;
pub extern "kernel32" fn SetNamedPipeHandleState(HANDLE, ?*const u32, ?*const u32, ?*const u32) callconv(.winapi) i32;
pub extern "kernel32" fn GetNamedPipeClientProcessId(HANDLE, *u32) callconv(.winapi) i32;
pub extern "kernel32" fn GetNamedPipeServerProcessId(HANDLE, *u32) callconv(.winapi) i32;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, u32, ?*u32, *Overlapped) callconv(.winapi) i32;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, ?*u32, *Overlapped) callconv(.winapi) i32;
pub extern "kernel32" fn GetOverlappedResult(HANDLE, *Overlapped, *u32, i32) callconv(.winapi) i32;
pub extern "kernel32" fn CancelIoEx(HANDLE, ?*Overlapped) callconv(.winapi) i32;
pub extern "kernel32" fn CreateEventW(?*SA, i32, i32, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) i32;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
pub extern "kernel32" fn WaitForMultipleObjects(u32, [*]const HANDLE, i32, u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn PostMessageW(std.os.windows.HWND, u32, usize, isize) callconv(.winapi) i32;
pub extern "user32" fn AllowSetForegroundWindow(u32) callconv(.winapi) i32;
pub extern "advapi32" fn SystemFunction036([*]u8, u32) callconv(.winapi) u8;

pub fn epoch() !u128 {
    var value: u128 = 0;
    if (SystemFunction036(std.mem.asBytes(&value), 16) == 0 or value == 0) return error.RandomFailed;
    return value;
}

pub fn event() !HANDLE {
    return CreateEventW(null, 1, 0, null) orelse error.EventFailed;
}

pub const Deadline = struct {
    end: u64,
    pub fn init(ms: u32) Deadline {
        return .{ .end = GetTickCount64() +| ms };
    }
    pub fn remaining(self: Deadline) u32 {
        return @intCast(@min(self.end -| GetTickCount64(), std.math.maxInt(u32) - 1));
    }
};

fn complete(pipe: HANDLE, op: *Overlapped, stop: ?HANDLE, deadline: Deadline) !u32 {
    const handles = [_]HANDLE{ op.event.?, stop orelse op.event.? };
    const result = WaitForMultipleObjects(if (stop != null) 2 else 1, &handles, 0, deadline.remaining());
    if (result != 0) {
        _ = CancelIoEx(pipe, op);
        // The kernel must retire the OVERLAPPED before its stack storage dies.
        // Named-pipe cancellation completes independently of the GUI or peer.
        var ignored: u32 = 0;
        _ = GetOverlappedResult(pipe, op, &ignored, 1);
        return if (result == 1) error.Cancelled else error.Timeout;
    }
    var count: u32 = 0;
    if (GetOverlappedResult(pipe, op, &count, 0) == 0) return error.PipeIoFailed;
    return count;
}

pub fn connect(pipe: HANDLE, stop: HANDLE) !void {
    const wake = try event();
    defer _ = CloseHandle(wake);
    var op: Overlapped = .{ .event = wake };
    if (ConnectNamedPipe(pipe, &op) != 0) return;
    switch (GetLastError()) {
        535 => return, // Client connected before ConnectNamedPipe.
        997 => _ = try complete(pipe, &op, stop, Deadline.init(1000)),
        else => return error.PipeConnectFailed,
    }
}

/// One message-mode record, preserving its boundary so decode can reject
/// trailing bytes. Oversized records fail instead of being accepted as prefixes.
pub fn readMessage(pipe: HANDLE, bytes: []u8, stop: ?HANDLE, deadline: Deadline) ![]u8 {
    const wake = try event();
    defer _ = CloseHandle(wake);
    var op: Overlapped = .{ .event = wake };
    if (ReadFile(pipe, bytes.ptr, @intCast(bytes.len), null, &op) == 0 and GetLastError() != 997)
        return error.PipeIoFailed;
    const count = try complete(pipe, &op, stop, deadline);
    if (count == 0) return error.PipeClosed;
    return bytes[0..count];
}

pub fn write(pipe: HANDLE, bytes: []const u8, stop: ?HANDLE, deadline: Deadline) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const wake = try event();
        defer _ = CloseHandle(wake);
        var op: Overlapped = .{ .event = wake };
        if (WriteFile(pipe, bytes[offset..].ptr, @intCast(bytes.len - offset), null, &op) == 0 and GetLastError() != 997)
            return error.PipeIoFailed;
        const count = try complete(pipe, &op, stop, deadline);
        if (count == 0) return error.PipeClosed;
        offset += count;
    }
}
