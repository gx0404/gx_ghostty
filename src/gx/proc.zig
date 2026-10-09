//! Process inspection for Ghostty GX: process names and the processes
//! running below a terminal's shell, used for herdr app mode and to decide
//! whether closing a terminal needs confirmation.
//!
//! `snapshot` captures the processes reachable from a root pid (normally
//! the terminal's shell) with Toolhelp32 on Windows and `/proc` on Linux;
//! `Tree` answers questions about the root's descendants and guards
//! against pid reuse by comparing creation times.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");

const log = std.log.scoped(.gx_proc);

pub const Pid = u32;

pub const Process = struct {
    pid: Pid,

    /// The parent pid reported by the OS. The parent may have exited and
    /// its pid may have been reused by an unrelated, newer process.
    ppid: Pid,

    /// Creation time in OS-specific units that increase over time
    /// (FILETIME ticks on Windows, clock ticks since boot on Linux), or
    /// null if unknown.
    created: ?u64,

    /// The executable name, e.g. `pwsh.exe` or `zsh`.
    name: []const u8,
};

/// A descendant of a root process: its index in `Tree.processes` and its
/// depth below the root (children have depth 1).
pub const Descendant = struct {
    index: usize,
    depth: usize,
};

/// A set of processes and the parent/child relation between them.
pub const Tree = struct {
    processes: []const Process,

    /// The index of the process with `pid`, if present.
    pub fn find(self: Tree, pid: Pid) ?usize {
        for (self.processes, 0..) |process, i| {
            if (process.pid == pid) return i;
        }
        return null;
    }

    /// Returns true if `child` is a child of `parent`: its parent pid is
    /// `parent.pid` and `parent` is not newer than `child`. A newer parent
    /// means the original parent exited and its pid was reused. Unknown
    /// creation times are trusted.
    pub fn isChild(parent: Process, child: Process) bool {
        if (child.ppid != parent.pid or child.pid == parent.pid) return false;
        const parent_created = parent.created orelse return true;
        const child_created = child.created orelse return true;
        return parent_created <= child_created;
    }

    /// The descendants of `root` in breadth-first order, without the root.
    /// Returns an empty list if `root` is not in the tree. The caller owns
    /// the returned slice.
    pub fn descendants(self: Tree, alloc: Allocator, root: Pid) Allocator.Error![]Descendant {
        var result: std.ArrayList(Descendant) = .empty;
        errdefer result.deinit(alloc);
        const root_index = self.find(root) orelse return try result.toOwnedSlice(alloc);

        const visited = try alloc.alloc(bool, self.processes.len);
        defer alloc.free(visited);
        @memset(visited, false);
        visited[root_index] = true;

        var parent_index = root_index;
        var parent_depth: usize = 0;
        var next: usize = 0;
        while (true) {
            const parent = self.processes[parent_index];
            for (self.processes, 0..) |process, i| {
                if (visited[i] or !isChild(parent, process)) continue;
                visited[i] = true;
                try result.append(alloc, .{ .index = i, .depth = parent_depth + 1 });
            }
            if (next >= result.items.len) break;
            parent_index = result.items[next].index;
            parent_depth = result.items[next].depth;
            next += 1;
        }
        return try result.toOwnedSlice(alloc);
    }

    /// The names of `root` and its descendants, root first. The names
    /// point into the tree; the caller owns the returned slice.
    pub fn names(self: Tree, alloc: Allocator, root: Pid) Allocator.Error![]const []const u8 {
        const root_index = self.find(root) orelse return try alloc.alloc([]const u8, 0);
        const list = try self.descendants(alloc, root);
        defer alloc.free(list);
        const result = try alloc.alloc([]const u8, list.len + 1);
        result[0] = self.processes[root_index].name;
        for (list, result[1..]) |descendant, *name| name.* = self.processes[descendant.index].name;
        return result;
    }

    /// Returns true if `root` or one of its descendants matches `name`
    /// (see `policy.nameMatches`).
    pub fn containsProcess(self: Tree, alloc: Allocator, root: Pid, name: []const u8) Allocator.Error!bool {
        const list = try self.names(alloc, root);
        defer alloc.free(list);
        for (list) |process_name| {
            if (policy.nameMatches(process_name, name)) return true;
        }
        return false;
    }

    /// The deepest descendant of `root`, typically the program the user is
    /// running in the shell. Among equally deep processes the newest one
    /// wins. Returns null if `root` has no descendants.
    pub fn deepestDescendant(self: Tree, alloc: Allocator, root: Pid) Allocator.Error!?Process {
        const list = try self.descendants(alloc, root);
        defer alloc.free(list);
        var best: ?Descendant = null;
        for (list) |candidate| {
            const current = best orelse {
                best = candidate;
                continue;
            };
            if (candidate.depth > current.depth or
                (candidate.depth == current.depth and
                    newer(self.processes[candidate.index], self.processes[current.index])))
            {
                best = candidate;
            }
        }
        return if (best) |found| self.processes[found.index] else null;
    }

    fn newer(a: Process, b: Process) bool {
        const a_created = a.created orelse return false;
        const b_created = b.created orelse return true;
        return a_created > b_created;
    }
};

/// Processes captured by `snapshot`. Call `deinit` to free it.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    tree: Tree,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SnapshotError = Allocator.Error || error{ Unsupported, SnapshotFailed };

/// Captures `root` and every process reachable from it through parent
/// pids, with names and creation times. `io` is used on Linux to read
/// `/proc`.
pub fn snapshot(alloc: Allocator, io: std.Io, root: Pid) SnapshotError!Snapshot {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const processes = switch (builtin.os.tag) {
        .windows => try windows.snapshot(arena.allocator(), root),
        .linux => linux: {
            var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |err| {
                log.warn("cannot open /proc err={}", .{err});
                return error.SnapshotFailed;
            };
            defer dir.close(io);
            break :linux try procSnapshot(arena.allocator(), io, dir, root);
        },
        else => return error.Unsupported,
    };
    return .{ .arena = arena, .tree = .{ .processes = processes } };
}

/// Like `snapshot`, but reads a Linux procfs layout from `proc_dir` (an
/// iterable directory with `<pid>/stat` and `<pid>/cmdline` entries).
pub fn procSnapshot(arena: Allocator, io: std.Io, proc_dir: std.Io.Dir, root: Pid) Allocator.Error![]Process {
    var all: std.ArrayList(Process) = .empty;
    var it = proc_dir.iterate();
    while (it.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(Pid, entry.name, 10) catch continue;
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{d}/stat", .{pid}) catch continue;
        var stat_buf: [1024]u8 = undefined;
        const data = proc_dir.readFile(io, path, &stat_buf) catch continue;
        const stat = parseStat(data) orelse continue;
        try all.append(arena, .{
            .pid = pid,
            .ppid = stat.ppid,
            .created = stat.starttime,
            .name = try fullName(arena, io, proc_dir, pid, stat.comm),
        });
    }
    return try reachable(arena, all.items, root);
}

/// The kernel truncates `comm` to 15 bytes.
const max_comm_len = 15;

const Stat = struct {
    comm: []const u8,
    ppid: Pid,
    starttime: u64,
};

/// Parses the fields Ghostty GX needs from `/proc/<pid>/stat`.
fn parseStat(data: []const u8) ?Stat {
    const open = std.mem.indexOfScalar(u8, data, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse return null;
    if (close < open) return null;
    var fields = std.mem.tokenizeScalar(u8, data[close + 1 ..], ' ');
    // Fields 3 (state) through 22 (starttime), see proc(5).
    var values: [20][]const u8 = undefined;
    for (&values) |*value| value.* = fields.next() orelse return null;
    return .{
        .comm = data[open + 1 .. close],
        .ppid = std.fmt.parseInt(Pid, values[1], 10) catch return null,
        .starttime = std.fmt.parseInt(u64, std.mem.trimEnd(u8, values[19], "\n"), 10) catch return null,
    };
}

/// The basename of argv[0] from `<pid>/cmdline`, without a login shell's
/// leading `-`, or null if it is unavailable.
fn argv0Name(arena: Allocator, io: std.Io, proc_dir: std.Io.Dir, pid: Pid) Allocator.Error!?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{d}/cmdline", .{pid}) catch return null;
    var buf: [4096]u8 = undefined;
    const data = proc_dir.readFile(io, path, &buf) catch return null;
    const argv0 = std.mem.sliceTo(data, 0);
    var base = std.fs.path.basenamePosix(argv0);
    if (base.len > 0 and base[0] == '-') base = base[1..];
    if (base.len == 0) return null;
    return try arena.dupe(u8, base);
}

/// `comm`, or the basename of argv[0] when the kernel truncated `comm`
/// and argv[0] extends it. Allocated in `arena`.
fn fullName(
    arena: Allocator,
    io: std.Io,
    proc_dir: std.Io.Dir,
    pid: Pid,
    comm: []const u8,
) Allocator.Error![]const u8 {
    if (comm.len >= max_comm_len) {
        if (try argv0Name(arena, io, proc_dir, pid)) |argv0| {
            if (std.mem.startsWith(u8, argv0, comm)) return argv0;
        }
    }
    return try arena.dupe(u8, comm);
}

/// The name of the Linux process `pid` read from `proc_dir` (normally
/// `/proc`): its `comm`, or the basename of argv[0] when the kernel
/// truncated `comm` and argv[0] extends it. Returns null if the process
/// does not exist. The caller owns the returned name.
pub fn processName(alloc: Allocator, io: std.Io, proc_dir: std.Io.Dir, pid: Pid) Allocator.Error!?[]u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{d}/comm", .{pid}) catch return null;
    var buf: [256]u8 = undefined;
    const data = proc_dir.readFile(io, path, &buf) catch return null;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const name = try fullName(arena.allocator(), io, proc_dir, pid, std.mem.trimEnd(u8, data, "\n"));
    return try alloc.dupe(u8, name);
}

/// `root` and the processes reachable from it through parent pids,
/// ignoring creation times (the `Tree` applies them). Keeps the order of
/// `all`; returns an empty list if `root` is not in `all`.
fn reachable(arena: Allocator, all: []const Process, root: Pid) Allocator.Error![]Process {
    const keep = try arena.alloc(bool, all.len);
    @memset(keep, false);
    var pending: std.ArrayList(Pid) = .empty;
    for (all, 0..) |process, i| {
        if (process.pid == root) {
            keep[i] = true;
            try pending.append(arena, root);
        }
    }
    while (pending.pop()) |parent| {
        for (all, 0..) |process, i| {
            if (keep[i] or process.ppid != parent or process.pid == parent) continue;
            keep[i] = true;
            try pending.append(arena, process.pid);
        }
    }
    var result: std.ArrayList(Process) = .empty;
    for (all, keep) |process, kept| {
        if (kept) try result.append(arena, process);
    }
    return try result.toOwnedSlice(arena);
}

const windows = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;

    const TH32CS_SNAPPROCESS: win.DWORD = 0x00000002;
    const PROCESS_QUERY_LIMITED_INFORMATION: win.DWORD = 0x1000;

    const PROCESSENTRY32W = extern struct {
        dwSize: win.DWORD,
        cntUsage: win.DWORD,
        th32ProcessID: win.DWORD,
        th32DefaultHeapID: win.ULONG_PTR,
        th32ModuleID: win.DWORD,
        cntThreads: win.DWORD,
        th32ParentProcessID: win.DWORD,
        pcPriClassBase: win.LONG,
        dwFlags: win.DWORD,
        szExeFile: [win.MAX_PATH]win.WCHAR,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(
        dwFlags: win.DWORD,
        th32ProcessID: win.DWORD,
    ) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn Process32FirstW(
        hSnapshot: win.HANDLE,
        lppe: *PROCESSENTRY32W,
    ) callconv(.winapi) win.BOOL;
    extern "kernel32" fn Process32NextW(
        hSnapshot: win.HANDLE,
        lppe: *PROCESSENTRY32W,
    ) callconv(.winapi) win.BOOL;
    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: win.DWORD,
        bInheritHandle: win.BOOL,
        dwProcessId: win.DWORD,
    ) callconv(.winapi) ?win.HANDLE;
    extern "kernel32" fn GetProcessTimes(
        hProcess: win.HANDLE,
        lpCreationTime: *win.FILETIME,
        lpExitTime: *win.FILETIME,
        lpKernelTime: *win.FILETIME,
        lpUserTime: *win.FILETIME,
    ) callconv(.winapi) win.BOOL;
    extern "kernel32" fn CloseHandle(hObject: win.HANDLE) callconv(.winapi) win.BOOL;

    fn snapshot(arena: Allocator, root: Pid) SnapshotError![]Process {
        const handle = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (handle == win.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
        defer _ = CloseHandle(handle);

        var all: std.ArrayList(Process) = .empty;
        var entry: PROCESSENTRY32W = undefined;
        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        var more = Process32FirstW(handle, &entry).toBool();
        while (more) : (more = Process32NextW(handle, &entry).toBool()) {
            const name = std.mem.sliceTo(&entry.szExeFile, 0);
            try all.append(arena, .{
                .pid = entry.th32ProcessID,
                .ppid = entry.th32ParentProcessID,
                .created = null,
                .name = try std.unicode.wtf16LeToWtf8Alloc(arena, name),
            });
        }

        const processes = try reachable(arena, all.items, root);
        for (processes) |*process| process.created = creationTime(process.pid);
        return processes;
    }

    fn creationTime(pid: Pid) ?u64 {
        if (pid == 0) return null;
        const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return null;
        defer _ = CloseHandle(process);
        var created: win.FILETIME = undefined;
        var exited: win.FILETIME = undefined;
        var kernel: win.FILETIME = undefined;
        var user: win.FILETIME = undefined;
        if (!GetProcessTimes(process, &created, &exited, &kernel, &user).toBool()) return null;
        return (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
    }
} else struct {};

fn testProcess(pid: Pid, ppid: Pid, created: ?u64, name: []const u8) Process {
    return .{ .pid = pid, .ppid = ppid, .created = created, .name = name };
}

test "descendants walks the tree breadth-first" {
    const testing = std.testing;
    const tree: Tree = .{ .processes = &.{
        testProcess(1, 0, 1, "init"),
        testProcess(10, 1, 10, "pwsh.exe"),
        testProcess(11, 10, 11, "git.exe"),
        testProcess(12, 10, 12, "herdr.exe"),
        testProcess(13, 12, 13, "zsh.exe"),
        testProcess(20, 1, 20, "explorer.exe"),
    } };

    const list = try tree.descendants(testing.allocator, 10);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("git.exe", tree.processes[list[0].index].name);
    try testing.expectEqual(@as(usize, 1), list[0].depth);
    try testing.expectEqualStrings("herdr.exe", tree.processes[list[1].index].name);
    try testing.expectEqualStrings("zsh.exe", tree.processes[list[2].index].name);
    try testing.expectEqual(@as(usize, 2), list[2].depth);

    const missing = try tree.descendants(testing.allocator, 99);
    defer testing.allocator.free(missing);
    try testing.expectEqual(@as(usize, 0), missing.len);
}

test "descendants ignores reused parent pids" {
    const testing = std.testing;
    // Process 30 was started by an earlier process 10 that exited; the
    // current process 10 is newer than 30, so 30 is not its child.
    const tree: Tree = .{ .processes = &.{
        testProcess(10, 1, 500, "pwsh.exe"),
        testProcess(30, 10, 100, "stale-child.exe"),
        testProcess(31, 10, 600, "vim.exe"),
        testProcess(32, 10, null, "unknown-time.exe"),
    } };

    const list = try tree.descendants(testing.allocator, 10);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("vim.exe", tree.processes[list[0].index].name);
    try testing.expectEqualStrings("unknown-time.exe", tree.processes[list[1].index].name);
}

test "descendants survives cycles and self parents" {
    const testing = std.testing;
    const tree: Tree = .{ .processes = &.{
        testProcess(0, 0, null, "System Idle Process"),
        testProcess(5, 6, null, "a"),
        testProcess(6, 5, null, "b"),
    } };

    const idle = try tree.descendants(testing.allocator, 0);
    defer testing.allocator.free(idle);
    try testing.expectEqual(@as(usize, 0), idle.len);

    const cycle = try tree.descendants(testing.allocator, 5);
    defer testing.allocator.free(cycle);
    try testing.expectEqual(@as(usize, 1), cycle.len);
    try testing.expectEqualStrings("b", tree.processes[cycle[0].index].name);
}

test "names, containsProcess and deepestDescendant" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const tree: Tree = .{ .processes = &.{
        testProcess(10, 1, 10, "gx-zsh.exe"),
        testProcess(11, 10, 11, "zsh.exe"),
        testProcess(12, 11, 12, "herdr.exe"),
        testProcess(13, 11, 13, "gitstatusd-windows-x86_64.exe"),
        testProcess(14, 12, 14, "nvim.exe"),
        testProcess(15, 12, 15, "node.exe"),
    } };

    const all = try tree.names(alloc, 10);
    defer alloc.free(all);
    try testing.expectEqual(@as(usize, 6), all.len);
    try testing.expectEqualStrings("gx-zsh.exe", all[0]);
    try testing.expect(!policy.isIdle(all, &.{}));
    try testing.expect(policy.herdrAppMode(true, 1, all));

    try testing.expect(try tree.containsProcess(alloc, 10, "herdr"));
    try testing.expect(try tree.containsProcess(alloc, 12, "HERDR.EXE"));
    try testing.expect(!try tree.containsProcess(alloc, 14, "herdr"));
    try testing.expect(!try tree.containsProcess(alloc, 99, "herdr"));

    const deepest = (try tree.deepestDescendant(alloc, 10)).?;
    try testing.expectEqualStrings("node.exe", deepest.name);
    try testing.expectEqual(@as(?Process, null), try tree.deepestDescendant(alloc, 14));

    const missing = try tree.names(alloc, 99);
    defer alloc.free(missing);
    try testing.expectEqual(@as(usize, 0), missing.len);
}

test "idle shell tree" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const tree: Tree = .{ .processes = &.{
        testProcess(10, 1, 10, "pwsh.exe"),
        testProcess(11, 10, 11, "conhost.exe"),
    } };
    const all = try tree.names(alloc, 10);
    defer alloc.free(all);
    try testing.expect(policy.isIdle(all, &.{}));
    try testing.expect(!policy.herdrAppMode(true, 1, all));
}

test "reachable keeps the root and its pid-linked processes" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const all = [_]Process{
        testProcess(1, 0, 1, "init"),
        testProcess(10, 1, 10, "zsh"),
        testProcess(11, 10, 11, "herdr"),
        testProcess(12, 11, 12, "zsh"),
        testProcess(20, 1, 20, "other"),
    };
    const kept = try reachable(arena.allocator(), &all, 10);
    try testing.expectEqual(@as(usize, 3), kept.len);
    try testing.expectEqual(@as(Pid, 10), kept[0].pid);
    try testing.expectEqual(@as(Pid, 12), kept[2].pid);
    try testing.expectEqual(@as(usize, 0), (try reachable(arena.allocator(), &all, 99)).len);
}

test "parseStat handles spaces and parentheses in comm" {
    const testing = std.testing;
    const stat = parseStat("1234 (tmux: server (1)) S 1 1234 1234 0 -1 4194560 " ++
        "100 0 0 0 1 2 0 0 20 0 1 0 98765 1000 100 18446744073709551615\n").?;
    try testing.expectEqualStrings("tmux: server (1)", stat.comm);
    try testing.expectEqual(@as(Pid, 1), stat.ppid);
    try testing.expectEqual(@as(u64, 98765), stat.starttime);

    try testing.expectEqual(@as(?Stat, null), parseStat("garbage"));
    try testing.expectEqual(@as(?Stat, null), parseStat("1 (x) S 1 2 3"));
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "procSnapshot and processName read a procfs layout" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const stat = " S {d} 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 {d} 0 0\n";
    try writeTestFile(tmp.dir, "100/stat", "100 (zsh)" ++ comptime std.fmt.comptimePrint(stat, .{ 1, 500 }));
    try writeTestFile(tmp.dir, "100/comm", "zsh\n");
    try writeTestFile(tmp.dir, "100/cmdline", "-zsh\x00");
    try writeTestFile(tmp.dir, "101/stat", "101 (herdr)" ++ comptime std.fmt.comptimePrint(stat, .{ 100, 600 }));
    try writeTestFile(tmp.dir, "101/comm", "herdr\n");
    try writeTestFile(tmp.dir, "102/stat", "102 (gitstatusd-linu)" ++ comptime std.fmt.comptimePrint(stat, .{ 100, 700 }));
    try writeTestFile(tmp.dir, "102/comm", "gitstatusd-linu\n");
    try writeTestFile(tmp.dir, "102/cmdline", "/home/u/.cache/gitstatus/gitstatusd-linux-x86_64\x00-s\x00");
    try writeTestFile(tmp.dir, "103/stat", "103 (stale)" ++ comptime std.fmt.comptimePrint(stat, .{ 100, 10 }));
    try writeTestFile(tmp.dir, "200/stat", "200 (other)" ++ comptime std.fmt.comptimePrint(stat, .{ 1, 800 }));
    try writeTestFile(tmp.dir, "self/stat", "garbage");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const processes = try procSnapshot(arena.allocator(), testing.io, tmp.dir, 100);
    const tree: Tree = .{ .processes = processes };
    const all = try tree.names(testing.allocator, 100);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("zsh", all[0]);
    try testing.expect(try tree.containsProcess(testing.allocator, 100, "herdr"));
    try testing.expect(try tree.containsProcess(testing.allocator, 100, "gitstatusd-linux-x86_64"));
    try testing.expect(!try tree.containsProcess(testing.allocator, 100, "stale"));

    const name = (try processName(testing.allocator, testing.io, tmp.dir, 102)).?;
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("gitstatusd-linux-x86_64", name);

    const short = (try processName(testing.allocator, testing.io, tmp.dir, 101)).?;
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("herdr", short);

    try testing.expectEqual(@as(?[]u8, null), try processName(testing.allocator, testing.io, tmp.dir, 999));
}

test "snapshot of the current process" {
    const testing = std.testing;
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;

    const self_pid: Pid = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.os.linux.getpid()),
    };
    var snap = try snapshot(testing.allocator, testing.io, self_pid);
    defer snap.deinit();
    const index = snap.tree.find(self_pid) orelse return error.TestUnexpectedResult;
    try testing.expect(snap.tree.processes[index].name.len > 0);
    try testing.expect(snap.tree.processes[index].created != null);
}
