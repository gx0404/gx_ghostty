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
//! `appendBusyProcesses` names those busy processes for the confirmation
//! dialogs.
//!
//! Both list the processes when asked, so the answer is current. Closing a
//! tab, a window or the app asks about many terminals at once: a `Scope`
//! makes all of those questions read one process table.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");
const proc = @import("proc.zig");

const log = std.log.scoped(.gx_confirm);

/// One close confirmation: while a scope is active on a thread,
/// `terminalNeedsConfirm` and `appendBusyProcesses` on that thread read
/// one process table, captured when first needed, instead of listing the
/// processes for every terminal. Begin it before asking
/// `needsConfirmQuit` and listing the busy processes of the terminals to
/// close, and end it before showing the confirmation: a modal loop can
/// run other confirmations, which need the processes of their own time.
/// `end` may run again (a `defer` after an explicit `end`).
///
/// A scope that begins inside another one (closing a window while
/// quitting) reads the table of the outermost scope. Its caller cannot end
/// the outer scope before its own dialog, so a confirmation shown inside
/// another scope lists the processes of the outer scope's table, which can
/// be older than that dialog.
///
/// ```
/// var scope: gx.confirm.Scope = undefined;
/// scope.begin(alloc, io);
/// defer scope.end(); // and end it explicitly before the dialog
/// ```
pub const Scope = struct {
    alloc: Allocator,
    io: std.Io,
    table: ?proc.Table = null,

    /// Capturing the table failed; the scope answers like an unreadable
    /// process list without trying again.
    failed: bool = false,

    /// The scope that was active when this one began.
    previous: ?*Scope = null,

    /// `end` ran.
    ended: bool = false,

    threadlocal var current: ?*Scope = null;

    /// Makes `self` the active scope of this thread.
    pub fn begin(self: *Scope, alloc: Allocator, io: std.Io) void {
        self.* = .{ .alloc = alloc, .io = io, .previous = current };
        current = self;
    }

    /// Frees the table and restores the scope that was active before.
    /// Scopes end in the reverse order they began; ending a scope again
    /// does nothing.
    pub fn end(self: *Scope) void {
        if (self.ended) return;
        std.debug.assert(current == self);
        current = self.previous;
        if (self.table) |*table| table.deinit();
        self.table = null;
        self.previous = null;
        self.ended = true;
    }

    /// The active scope of this thread, if any.
    pub fn active() ?*Scope {
        return current;
    }

    /// The table of the outermost scope, captured on first use; null if
    /// the processes cannot be read.
    fn processTable(self: *Scope) ?*proc.Table {
        if (self.previous) |outer| return outer.processTable();
        if (self.table) |*table| return table;
        if (self.failed) return null;
        self.table = proc.Table.capture(self.alloc, self.io) catch |err| {
            if (err != error.Unsupported) log.warn("cannot list the processes err={}", .{err});
            self.failed = true;
            return null;
        };
        return &self.table.?;
    }
};

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
/// Linux and Windows, so callers keep upstream's answer there. Reads the
/// table of the active `Scope`, if any.
pub fn terminalNeedsConfirm(
    alloc: Allocator,
    io: std.Io,
    root: ?u64,
    idle_list: []const [:0]const u8,
) bool {
    const pid = std.math.cast(proc.Pid, root orelse return true) orelse return true;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const names = (processNames(arena.allocator(), io, pid) catch return true) orelse return true;
    const result = needsConfirm(names, idle_list);
    log.debug("pid={d} processes={d} needs_confirm={}", .{ pid, names.len, result });
    return result;
}

/// Appends to `out` the processes of a terminal (`root` and its
/// descendants, see `terminalNeedsConfirm`) that are not idle, so a close
/// confirmation can say what would be terminated. Appends nothing when
/// `root` is null or the processes cannot be read. Reads the table of the
/// active `Scope`, if any. See `appendBusyNames` for the copying,
/// deduplication and naming rules.
pub fn appendBusyProcesses(
    arena: Allocator,
    io: std.Io,
    root: ?u64,
    idle_list: []const [:0]const u8,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const pid = std.math.cast(proc.Pid, root orelse return) orelse return;
    const names = try processNames(arena, io, pid) orelse return;
    try appendBusyNames(arena, names, idle_list, out);
}

/// The names of `pid` and its descendants (root first), from the table
/// of the active `Scope` or from a new one. Null when the processes cannot
/// be read.
fn processNames(arena: Allocator, io: std.Io, pid: proc.Pid) Allocator.Error!?[]const []const u8 {
    if (Scope.active()) |scope| {
        const table = scope.processTable() orelse return null;
        const tree = try table.tree(arena, &.{pid});
        return try tree.names(arena, pid);
    }
    var table = proc.Table.capture(arena, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return null,
        error.SnapshotFailed => {
            log.warn("cannot list the processes of pid={d}", .{pid});
            return null;
        },
    };
    defer table.deinit();
    const tree = try table.tree(arena, &.{pid});
    return try tree.names(arena, pid);
}

/// Appends the names in `names` that are not idle according to
/// `idle_list` (the built-in list when empty), in order, as the interface
/// shows them (`policy.displayName`: `PING.EXE` becomes `PING`), copied
/// with `arena`. Names already in `out` (compared like
/// `policy.nameMatches`, so `PING.EXE` and `ping.exe` are the same) are
/// skipped, which lets callers collect the processes of several terminals
/// into one list.
pub fn appendBusyNames(
    arena: Allocator,
    names: []const []const u8,
    idle_list: []const [:0]const u8,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const list = if (idle_list.len == 0) &policy.builtin_idle_processes else idle_list;
    outer: for (names) |name| {
        if (policy.matchesAny(name, list)) continue;
        for (out.items) |seen| {
            if (policy.nameMatches(name, seen)) continue :outer;
        }
        try out.append(arena, try arena.dupe(u8, policy.displayName(name)));
    }
}

/// Windows helpers for the termio backend, which only knows the child
/// process by its handle.
pub const windows = if (builtin.target.os.tag == .windows) struct {
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

test "appendBusyNames lists each busy process once, without .exe" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try appendBusyNames(arena.allocator(), &.{ "pwsh.exe", "PING.EXE", "conhost.exe" }, &.{}, &out);
    try appendBusyNames(arena.allocator(), &.{ "gx-zsh.exe", "zsh.exe", "ping.exe", "vim.exe" }, &.{}, &out);
    try appendBusyNames(arena.allocator(), &.{ "bash", "/usr/bin/python3", "vim" }, &.{}, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("PING", out.items[0]);
    try testing.expectEqualStrings("vim", out.items[1]);
    try testing.expectEqualStrings("python3", out.items[2]);
}

test "appendBusyNames with configured idle processes" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    const configured = [_][:0]const u8{ "zsh", "tmux*" };
    try appendBusyNames(arena.allocator(), &.{ "zsh", "tmux: client", "pwsh.exe" }, &configured, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("pwsh", out.items[0]);
}

test "appendBusyProcesses without a process" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try appendBusyProcesses(arena.allocator(), testing.io, null, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "terminalNeedsConfirm without a process" {
    const testing = std.testing;
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, null, &.{}));
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, std.math.maxInt(u64), &.{}));
}

test "terminalNeedsConfirm for the test process" {
    const testing = std.testing;
    if (builtin.target.os.tag != .windows and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const self_pid: u64 = switch (builtin.target.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.os.linux.getpid()),
    };
    // The test binary is not an idle process, and `*` makes every process
    // idle.
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{}));
    try testing.expect(!terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{"*"}));
}

test "a scope reads one process table for every question" {
    const testing = std.testing;
    if (builtin.target.os.tag != .windows and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const self_pid: u64 = switch (builtin.target.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.os.linux.getpid()),
    };
    try testing.expectEqual(@as(?*Scope, null), Scope.active());

    var scope: Scope = undefined;
    scope.begin(testing.allocator, testing.io);
    try testing.expectEqual(@as(?*Scope, &scope), Scope.active());
    try testing.expect(scope.table == null);

    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{}));
    const table = &scope.table.?;
    const entries = table.entries.ptr;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try appendBusyProcesses(arena.allocator(), testing.io, self_pid, &.{}, &out);
    try testing.expect(out.items.len > 0);
    try testing.expect(!terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{"*"}));
    try testing.expectEqual(entries, scope.table.?.entries.ptr);

    {
        // A nested scope reads the outer scope's table and restores the
        // outer scope when it ends.
        var inner: Scope = undefined;
        inner.begin(testing.allocator, testing.io);
        defer inner.end();
        try testing.expectEqual(@as(?*Scope, &inner), Scope.active());
        try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{}));
        try testing.expect(inner.table == null);
        try testing.expectEqual(entries, scope.table.?.entries.ptr);
    }
    try testing.expectEqual(@as(?*Scope, &scope), Scope.active());

    scope.end();
    try testing.expectEqual(@as(?*Scope, null), Scope.active());

    // Without a scope every question lists the processes again.
    try testing.expect(terminalNeedsConfirm(testing.allocator, testing.io, self_pid, &.{}));
}

test "ending a scope again does nothing" {
    const testing = std.testing;
    var outer: Scope = undefined;
    outer.begin(testing.allocator, testing.io);
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .linux) {
        // A captured table is freed once.
        _ = terminalNeedsConfirm(testing.allocator, testing.io, 1, &.{});
        try testing.expect(outer.table != null or outer.failed);
    }
    {
        var inner: Scope = undefined;
        inner.begin(testing.allocator, testing.io);
        defer inner.end();
        inner.end();
        try testing.expectEqual(@as(?*Scope, &outer), Scope.active());
    }
    // The deferred second end of the inner scope left the outer one active.
    try testing.expectEqual(@as(?*Scope, &outer), Scope.active());
    outer.end();
    outer.end();
    try testing.expectEqual(@as(?*Scope, null), Scope.active());
    try testing.expect(outer.table == null);
}
