//! Close confirmation for Ghostty GX. With `confirm-close-surface = true`,
//! upstream Ghostty asks before closing a terminal whose cursor is not at a
//! shell prompt, which is every terminal whose shell lacks shell
//! integration (for example `cmd.exe` and PowerShell on Windows). Ghostty
//! GX also skips the question when every process running in the terminal
//! is idle: a shell, a shell launcher or a console helper (see
//! `policy.isIdle` and `gx-idle-processes`).
//!
//! `src/Surface.zig::needsConfirmQuit` (fork patch GX-0012) passes the pid
//! that `Surface.getProcessInfo(.foreground_pid)` reports: the foreground
//! process group leader of the pty on POSIX, and the terminal's child
//! process (normally the shell) on Windows, which has no foreground
//! process groups. `terminalNeedsConfirm` checks that process and all of
//! its descendants, so `gx-zsh.exe` running `zsh.exe` is idle, while a
//! shell running `vim`, `herdr`, a script or a background job is busy.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");
const proc = @import("proc.zig");

const log = std.log.scoped(.gx_confirm);

/// Returns true if closing a terminal running the processes `names` needs
/// confirmation: false only when every process is idle according to
/// `idle_list` (the `gx-idle-processes` values; empty selects the built-in
/// list). An empty `names` means the processes are unknown, which needs
/// confirmation.
pub fn needsConfirm(names: []const []const u8, idle_list: []const [:0]const u8) bool {
    if (names.len == 0) return true;
    return !policy.isIdle(names, idle_list);
}

/// `needsConfirm` for the processes of a terminal: `root` (see the module
/// documentation) and all of its descendants. Returns true when `root` is
/// null or the processes cannot be read, including on systems other than
/// Linux and Windows, so callers keep upstream's answer there.
pub fn terminalNeedsConfirm(
    alloc: Allocator,
    io: std.Io,
    root: ?u64,
    idle_list: []const [:0]const u8,
) bool {
    const pid = std.math.cast(proc.Pid, root orelse return true) orelse return true;
    var snapshot = proc.snapshot(alloc, io, pid) catch |err| {
        if (err != error.Unsupported) log.warn("cannot list the processes of pid={d} err={}", .{ pid, err });
        return true;
    };
    defer snapshot.deinit();
    const names = snapshot.tree.names(alloc, pid) catch return true;
    defer alloc.free(names);
    const result = needsConfirm(names, idle_list);
    log.debug("pid={d} processes={d} needs_confirm={}", .{ pid, names.len, result });
    return result;
}

/// Windows helpers for the termio backend, which only knows the child
/// process by its handle.
pub const windows = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;

    extern "kernel32" fn GetProcessId(Process: win.HANDLE) callconv(.winapi) win.DWORD;

    /// The process id of the process `handle`, or null if it is unknown.
    pub fn processId(handle: win.HANDLE) ?u64 {
        const id = GetProcessId(handle);
        return if (id == 0) null else id;
    }
} else struct {};

test "needsConfirm with the built-in idle list" {
    const testing = std.testing;
    try testing.expect(needsConfirm(&.{}, &.{}));
    try testing.expect(!needsConfirm(&.{"zsh"}, &.{}));
    try testing.expect(!needsConfirm(&.{ "-bash", "gitstatusd-linu" }, &.{}));
    try testing.expect(!needsConfirm(&.{ "pwsh.exe", "conhost.exe" }, &.{}));
    try testing.expect(!needsConfirm(&.{ "gx-zsh.exe", "zsh.exe", "gitstatusd-windows-x86_64.exe" }, &.{}));
    try testing.expect(needsConfirm(&.{ "bash", "sleep" }, &.{}));
    try testing.expect(needsConfirm(&.{"sleep"}, &.{}));
    try testing.expect(needsConfirm(&.{ "pwsh.exe", "vim.exe" }, &.{}));
    try testing.expect(needsConfirm(&.{ "gx-zsh.exe", "zsh.exe", "herdr.exe", "zsh.exe" }, &.{}));
    try testing.expect(needsConfirm(&.{"herdr"}, &.{}));
}

test "needsConfirm with configured idle processes" {
    const testing = std.testing;
    const configured = [_][:0]const u8{ "zsh", "tmux*" };
    try testing.expect(!needsConfirm(&.{ "zsh", "tmux: client" }, &configured));
    try testing.expect(needsConfirm(&.{ "zsh", "bash" }, &configured));
    try testing.expect(needsConfirm(&.{}, &configured));
}

test "terminalNeedsConfirm without a process" {
    const testing = std.testing;
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, null, &.{}));
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, std.math.maxInt(u64), &.{}));
}

test "terminalNeedsConfirm for the test process" {
    const testing = std.testing;
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    const self_pid: u64 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.os.linux.getpid()),
    };
    // The test binary is not an idle process, and `*` makes every process
    // idle.
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{}));
    try testing.expect(!terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{"*"}));
}
