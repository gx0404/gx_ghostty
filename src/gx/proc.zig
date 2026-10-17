//! Process inspection for Ghostty GX: process names and the processes
//! running below a terminal's shell, used for herdr app mode, the tab
//! labels and to decide whether closing a terminal needs confirmation.
//!
//! `Table` reads every process of the system in one pass (Toolhelp32 on
//! Windows, `/proc` on Linux): pids and parent pids up front, names and
//! Windows creation times only for the processes that a `Table.tree`
//! keeps, so one table answers for the terminals of every tab. `Tree`
//! answers questions about the descendants of a root (normally a
//! terminal's shell) and guards against pid reuse by comparing creation
//! times. `Shared` keeps one table for the periodic checks of the GUI
//! thread; `snapshot` captures a table for a single root.
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

/// What a terminal shows as the program it runs (see `Tree.program`).
pub const Program = struct {
    /// The program's name for display (`policy.displayName`, so without a
    /// directory or `.exe`).
    name: []const u8,

    /// Whether the terminal runs WSL: `wsl.exe` is its shell or its
    /// program.
    wsl: bool,
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

    /// The program running in the terminal whose shell is `root`, for its
    /// tab label: the deepest descendant that is not a console helper
    /// (`policy.helper_processes`), the newest among equally deep ones,
    /// else `root` itself. Null if `root` is not in the tree. The name
    /// points into the tree.
    pub fn program(self: Tree, alloc: Allocator, root: Pid) Allocator.Error!?Program {
        const index = try self.programIndex(alloc, root) orelse return null;
        const root_name = self.processes[self.find(root).?].name;
        const name = self.processes[index].name;
        return .{
            .name = policy.displayName(name),
            .wsl = policy.nameMatches(root_name, "wsl.exe") or policy.nameMatches(name, "wsl.exe"),
        };
    }

    /// The index in `processes` of the process that `program` names, or
    /// null if `root` is not in the tree.
    pub fn programIndex(self: Tree, alloc: Allocator, root: Pid) Allocator.Error!?usize {
        const root_index = self.find(root) orelse return null;
        const list = try self.descendants(alloc, root);
        defer alloc.free(list);
        var best: ?Descendant = null;
        for (list) |candidate| {
            const process = self.processes[candidate.index];
            if (policy.matchesAny(process.name, &policy.helper_processes)) continue;
            if (best) |current| {
                if (candidate.depth < current.depth) continue;
                if (candidate.depth == current.depth and
                    !newer(process, self.processes[current.index])) continue;
            }
            best = candidate;
        }
        return if (best) |found| found.index else root_index;
    }

    fn newer(a: Process, b: Process) bool {
        const a_created = a.created orelse return false;
        const b_created = b.created orelse return true;
        return a_created > b_created;
    }
};

pub const SnapshotError = Allocator.Error || error{ Unsupported, SnapshotFailed };

/// Every process of the system, read in one pass. Parent pids are known
/// up front; names and Windows creation times are read when a `tree`
/// first keeps a process and are then cached in the table, so build
/// trees for several terminals from one table (`tree` takes several
/// roots). Not thread-safe; free it with `deinit`.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,

    /// The processes, sorted by pid.
    entries: []Entry,

    /// Indexes into `entries` sorted by parent pid, built by the first
    /// `tree`.
    by_parent: ?[]const u32 = null,

    /// Where the names come from.
    names: Names,

    const Entry = struct {
        pid: Pid,
        ppid: Pid,

        /// The raw name: this range of the table's name buffer.
        name_start: u32,
        name_len: u32,

        /// The creation time, valid once `created_read`.
        created: ?u64 = null,
        created_read: bool = false,

        /// The UTF-8 name, once read.
        name: ?[]const u8 = null,
    };

    const Names = union(enum) {
        /// Complete UTF-8 names (`fromProcesses`).
        utf8: []const u8,

        /// Windows `szExeFile` names (UTF-16), converted when read.
        utf16: []const u16,

        /// Linux `comm` names from `<pid>/stat`, completed from
        /// `<pid>/cmdline` when the kernel truncated them.
        procfs: Procfs,
    };

    const Procfs = struct {
        comm: []const u8,
        io: std.Io,
        dir: std.Io.Dir,

        /// Whether the table opened `dir` and closes it in `deinit`.
        owned: bool,
    };

    /// Reads every process of the running system: Toolhelp32 on Windows,
    /// `/proc` (kept open until `deinit`) on Linux.
    /// `proc.snapshot` counts each system snapshot attempt, including failure.
    pub fn capture(alloc: Allocator, io: std.Io) SnapshotError!Table {
        switch (builtin.os.tag) {
            .windows => return try windows.capture(alloc),
            .linux => {
                @import("perf.zig").count("proc.snapshot", 1);
                var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |err| {
                    log.warn("cannot open /proc err={}", .{err});
                    return error.SnapshotFailed;
                };
                errdefer dir.close(io);
                var table = try readProc(alloc, io, dir);
                table.names.procfs.owned = true;
                return table;
            },
            else => return error.Unsupported,
        }
    }

    /// Reads a Linux procfs layout from `proc_dir`: an iterable directory
    /// with `<pid>/stat` and `<pid>/cmdline` entries, which must stay open
    /// while the table is in use.
    /// Injected procfs directories do not count as system snapshot attempts;
    /// production callers must use `capture` to participate in `proc.snapshot`.
    pub fn readProc(alloc: Allocator, io: std.Io, proc_dir: std.Io.Dir) Allocator.Error!Table {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        var comm: std.ArrayList(u8) = .empty;
        var it = proc_dir.iterate();
        while (it.next(io) catch null) |dir_entry| {
            const pid = std.fmt.parseInt(Pid, dir_entry.name, 10) catch continue;
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{d}/stat", .{pid}) catch continue;
            var stat_buf: [1024]u8 = undefined;
            const data = proc_dir.readFile(io, path, &stat_buf) catch continue;
            const stat = parseStat(data) orelse continue;
            try entries.append(a, .{
                .pid = pid,
                .ppid = stat.ppid,
                .name_start = @intCast(comm.items.len),
                .name_len = @intCast(stat.comm.len),
                .created = stat.starttime,
                .created_read = true,
            });
            try comm.appendSlice(a, stat.comm);
        }
        sortByPid(entries.items);
        return .{
            .arena = arena,
            .entries = entries.items,
            .names = .{ .procfs = .{ .comm = comm.items, .io = io, .dir = proc_dir, .owned = false } },
        };
    }

    /// A table of `processes`, for callers that list processes
    /// themselves and for tests.
    pub fn fromProcesses(alloc: Allocator, processes: []const Process) Allocator.Error!Table {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const entries = try a.alloc(Entry, processes.len);
        var names: std.ArrayList(u8) = .empty;
        for (processes, entries) |process, *entry| {
            entry.* = .{
                .pid = process.pid,
                .ppid = process.ppid,
                .name_start = @intCast(names.items.len),
                .name_len = @intCast(process.name.len),
                .created = process.created,
                .created_read = true,
            };
            try names.appendSlice(a, process.name);
        }
        sortByPid(entries);
        return .{ .arena = arena, .entries = entries, .names = .{ .utf8 = names.items } };
    }

    pub fn deinit(self: *Table) void {
        switch (self.names) {
            .procfs => |procfs| if (procfs.owned) procfs.dir.close(procfs.io),
            .utf8, .utf16 => {},
        }
        self.arena.deinit();
        self.* = undefined;
    }

    /// The number of processes in the table.
    pub fn count(self: *const Table) usize {
        return self.entries.len;
    }

    /// The processes reachable from any of `roots` through parent pids
    /// (the roots in the table and all of their descendants), with names
    /// and creation times, in pid order. Like the OS, this follows parent
    /// pids regardless of creation times; the `Tree` applies them.
    /// Everything, names included, is allocated with `arena` (a tree has
    /// no `deinit`), so the tree stays valid after the table is freed.
    pub fn tree(self: *Table, arena: Allocator, roots: []const Pid) Allocator.Error!Tree {
        const keep = try arena.alloc(bool, self.entries.len);
        @memset(keep, false);
        var kept: usize = 0;
        var pending: std.ArrayList(u32) = .empty;
        for (roots) |root| {
            const i = self.indexOf(root) orelse continue;
            if (keep[i]) continue;
            keep[i] = true;
            kept += 1;
            try pending.append(arena, @intCast(i));
        }
        if (kept > 0) {
            const by_parent = try self.parentIndex();
            while (pending.pop()) |i| {
                const parent = self.entries[i].pid;
                for (childrenOf(self.entries, by_parent, parent)) |child| {
                    if (keep[child] or self.entries[child].pid == parent) continue;
                    keep[child] = true;
                    kept += 1;
                    try pending.append(arena, child);
                }
            }
        }

        const processes = try arena.alloc(Process, kept);
        var n: usize = 0;
        for (keep, 0..) |k, i| {
            if (!k) continue;
            processes[n] = .{
                .pid = self.entries[i].pid,
                .ppid = self.entries[i].ppid,
                .created = self.createdAt(i),
                .name = try arena.dupe(u8, try self.nameAt(i)),
            };
            n += 1;
        }
        return .{ .processes = processes };
    }

    fn sortByPid(entries: []Entry) void {
        std.mem.sortUnstable(Entry, entries, {}, lessByPid);
    }

    fn lessByPid(_: void, a: Entry, b: Entry) bool {
        return a.pid < b.pid;
    }

    fn indexOf(self: *const Table, pid: Pid) ?usize {
        const i = std.sort.lowerBound(Entry, self.entries, pid, orderPid);
        if (i < self.entries.len and self.entries[i].pid == pid) return i;
        return null;
    }

    fn orderPid(pid: Pid, entry: Entry) std.math.Order {
        return std.math.order(pid, entry.pid);
    }

    fn parentIndex(self: *Table) Allocator.Error![]const u32 {
        if (self.by_parent) |index| return index;
        const index = try self.arena.allocator().alloc(u32, self.entries.len);
        for (index, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sortUnstable(u32, index, self.entries, lessByParent);
        self.by_parent = index;
        return index;
    }

    fn lessByParent(entries: []const Entry, a: u32, b: u32) bool {
        if (entries[a].ppid != entries[b].ppid) return entries[a].ppid < entries[b].ppid;
        return a < b;
    }

    const ParentKey = struct {
        entries: []const Entry,
        ppid: Pid,
    };

    /// The indexes of the entries whose parent pid is `ppid`.
    fn childrenOf(entries: []const Entry, by_parent: []const u32, ppid: Pid) []const u32 {
        const range = std.sort.equalRange(u32, by_parent, ParentKey{ .entries = entries, .ppid = ppid }, orderParent);
        return by_parent[range[0]..range[1]];
    }

    fn orderParent(key: ParentKey, index: u32) std.math.Order {
        return std.math.order(key.ppid, key.entries[index].ppid);
    }

    fn createdAt(self: *Table, i: usize) ?u64 {
        const entry = &self.entries[i];
        if (!entry.created_read) {
            entry.created = if (builtin.os.tag == .windows) windows.creationTime(entry.pid) else null;
            entry.created_read = true;
        }
        return entry.created;
    }

    fn nameAt(self: *Table, i: usize) Allocator.Error![]const u8 {
        const entry = &self.entries[i];
        if (entry.name) |name| return name;
        const start = entry.name_start;
        const end = start + entry.name_len;
        const name: []const u8 = switch (self.names) {
            .utf8 => |names| names[start..end],
            .utf16 => |names| try std.unicode.wtf16LeToWtf8Alloc(self.arena.allocator(), names[start..end]),
            .procfs => |procfs| try fullName(self.arena.allocator(), procfs.io, procfs.dir, entry.pid, procfs.comm[start..end]),
        };
        entry.name = name;
        return name;
    }
};

/// One process table for the periodic checks of a thread (the GUI
/// thread): the tab labels and herdr app mode of every window read the
/// table that the first of them captured, until it is `ttl` old. Close
/// confirmations need the current processes and use `confirm.Scope`
/// instead. Keep one per app; not thread-safe.
pub const Shared = struct {
    /// How long a captured table answers.
    ttl: std.Io.Duration = .fromMilliseconds(default_ttl_ms),

    table: ?Table = null,

    /// When `table` was captured, on the `awake` clock.
    captured_at: std.Io.Timestamp = .zero,

    /// The number of tables captured, for diagnostics.
    captures: u64 = 0,

    pub const default_ttl_ms = 1000;

    /// The shared table, captured now if there is none or it is `ttl`
    /// old. It stays valid until the next `get`, `invalidate` or `deinit`;
    /// trees built from it (`Table.tree`) stay valid after that.
    pub fn get(self: *Shared, alloc: Allocator, io: std.Io) SnapshotError!*Table {
        return self.getAt(alloc, io, std.Io.Timestamp.now(io, .awake));
    }

    /// `get` at the time `now` (the `awake` clock).
    pub fn getAt(self: *Shared, alloc: Allocator, io: std.Io, now: std.Io.Timestamp) SnapshotError!*Table {
        if (self.table) |*table| {
            const age = self.captured_at.durationTo(now).nanoseconds;
            if (age >= 0 and age < self.ttl.nanoseconds) return table;
        }
        const table = try Table.capture(alloc, io);
        self.invalidate();
        self.table = table;
        self.captured_at = now;
        self.captures += 1;
        return &self.table.?;
    }

    /// Drops the table, so that the next `get` reads the processes again.
    pub fn invalidate(self: *Shared) void {
        if (self.table) |*table| table.deinit();
        self.table = null;
    }

    pub fn deinit(self: *Shared) void {
        self.invalidate();
        self.* = undefined;
    }
};

/// Processes captured by `snapshot`. Call `deinit` to free it.
pub const Snapshot = struct {
    table: Table,
    tree: Tree,

    pub fn deinit(self: *Snapshot) void {
        self.table.deinit();
        self.* = undefined;
    }
};

/// Captures `root` and every process reachable from it through parent
/// pids, with names and creation times. `io` is used on Linux to read
/// `/proc`. To ask about several terminals, build one `Table.tree` with
/// all of their roots instead.
pub fn snapshot(alloc: Allocator, io: std.Io, root: Pid) SnapshotError!Snapshot {
    var table = try Table.capture(alloc, io);
    errdefer table.deinit();
    const tree = try table.tree(table.arena.allocator(), &.{root});
    return .{ .table = table, .tree = tree };
}

/// Like `snapshot`, but reads a Linux procfs layout from `proc_dir` (see
/// `Table.readProc`) and allocates with `arena`.
pub fn procSnapshot(arena: Allocator, io: std.Io, proc_dir: std.Io.Dir, root: Pid) Allocator.Error![]const Process {
    var table = try Table.readProc(arena, io, proc_dir);
    defer table.deinit();
    const tree = try table.tree(arena, &.{root});
    return tree.processes;
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

/// `comm` itself, or the basename of argv[0] (allocated in `arena`) when
/// the kernel truncated `comm` and argv[0] extends it.
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
    return comm;
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

    /// A typical system has a few hundred processes with short names;
    /// reserving room for them up front keeps the arena from collecting
    /// the outgrown buffers.
    const expected_processes = 1024;
    const expected_name_len = 24;

    fn capture(alloc: Allocator) SnapshotError!Table {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        @import("perf.zig").count("proc.snapshot", 1);
        const handle = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (handle == win.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
        defer _ = CloseHandle(handle);

        var entries: std.ArrayList(Table.Entry) = try .initCapacity(a, expected_processes);
        var names: std.ArrayList(u16) = try .initCapacity(a, expected_processes * expected_name_len);
        var entry: PROCESSENTRY32W = undefined;
        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        var more = Process32FirstW(handle, &entry).toBool();
        while (more) : (more = Process32NextW(handle, &entry).toBool()) {
            const name = std.mem.sliceTo(&entry.szExeFile, 0);
            try entries.append(a, .{
                .pid = entry.th32ProcessID,
                .ppid = entry.th32ParentProcessID,
                .name_start = @intCast(names.items.len),
                .name_len = @intCast(name.len),
            });
            try names.appendSlice(a, name);
        }
        Table.sortByPid(entries.items);
        return .{ .arena = arena, .entries = entries.items, .names = .{ .utf16 = names.items } };
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

test "names and containsProcess" {
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

    try testing.expect(try tree.containsProcess(alloc, 10, "herdr"));
    try testing.expect(try tree.containsProcess(alloc, 12, "HERDR.EXE"));
    try testing.expect(!try tree.containsProcess(alloc, 14, "herdr"));
    try testing.expect(!try tree.containsProcess(alloc, 99, "herdr"));

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
    try testing.expect(!try tree.containsProcess(alloc, 10, "herdr"));
}

test "program is the deepest process that is not a helper" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const tree: Tree = .{ .processes = &.{
        testProcess(10, 1, 10, "gx-zsh.exe"),
        testProcess(11, 10, 11, "zsh.exe"),
        testProcess(12, 11, 12, "herdr.exe"),
        testProcess(13, 11, 13, "gitstatusd-windows-x86_64.exe"),
        testProcess(14, 12, 14, "nvim.exe"),
        testProcess(15, 12, 15, "node.exe"),
        testProcess(16, 15, 16, "conhost.exe"),
        testProcess(20, 1, 20, "pwsh.exe"),
        testProcess(21, 20, 21, "OpenConsole.exe"),
        testProcess(30, 1, 30, "wsl.exe"),
        testProcess(31, 30, 31, "wslhost.exe"),
        testProcess(32, 30, 32, "wslrelay.exe"),
        testProcess(40, 1, 40, "cmd.exe"),
        testProcess(41, 40, null, "PING.EXE"),
        testProcess(42, 40, 42, "timeout.exe"),
    } };

    // The newest of the deepest non-helper processes.
    const herdr = (try tree.program(alloc, 10)).?;
    try testing.expectEqualStrings("node", herdr.name);
    try testing.expect(!herdr.wsl);

    // Only helpers below the shell: the shell itself.
    const pwsh = (try tree.program(alloc, 20)).?;
    try testing.expectEqualStrings("pwsh", pwsh.name);
    const wsl = (try tree.program(alloc, 30)).?;
    try testing.expectEqualStrings("wsl", wsl.name);
    try testing.expect(wsl.wsl);

    // A known creation time wins over an unknown one at the same depth.
    const cmd = (try tree.program(alloc, 40)).?;
    try testing.expectEqualStrings("timeout", cmd.name);

    try testing.expectEqual(@as(?Program, null), try tree.program(alloc, 99));
}

test "Table.tree follows several roots in one pass" {
    const testing = std.testing;
    var table: Table = try .fromProcesses(testing.allocator, &.{
        testProcess(20, 1, 20, "other"),
        testProcess(12, 11, 12, "zsh"),
        testProcess(1, 0, 1, "init"),
        testProcess(10, 1, 10, "zsh"),
        testProcess(11, 10, 11, "herdr"),
        testProcess(30, 1, 30, "pwsh.exe"),
        testProcess(31, 30, 31, "vim.exe"),
        testProcess(40, 40, 40, "self-parent"),
    });
    defer table.deinit();
    try testing.expectEqual(@as(usize, 8), table.count());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tree = try table.tree(arena.allocator(), &.{ 30, 10, 99, 10, 40 });
    const pids = [_]Pid{ 10, 11, 12, 30, 31, 40 };
    try testing.expectEqual(pids.len, tree.processes.len);
    for (pids, tree.processes) |pid, process| try testing.expectEqual(pid, process.pid);
    try testing.expect(try tree.containsProcess(arena.allocator(), 10, "herdr"));
    try testing.expect(!try tree.containsProcess(arena.allocator(), 30, "herdr"));
    try testing.expectEqualStrings("vim", (try tree.program(arena.allocator(), 30)).?.name);

    const none = try table.tree(arena.allocator(), &.{});
    try testing.expectEqual(@as(usize, 0), none.processes.len);
    const missing = try table.tree(arena.allocator(), &.{99});
    try testing.expectEqual(@as(usize, 0), missing.processes.len);
}

test "Table.tree outlives the table" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var table: Table = try .fromProcesses(testing.allocator, &.{
        testProcess(10, 1, 10, "bash"),
        testProcess(11, 10, 11, "sleep"),
    });
    const tree = try table.tree(arena.allocator(), &.{10});
    table.deinit();
    const names = try tree.names(arena.allocator(), 10);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("bash", names[0]);
    try testing.expectEqualStrings("sleep", names[1]);
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

test "Table.readProc reads the names of kept processes only" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const stat = " S {d} 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 {d} 0 0\n";
    try writeTestFile(tmp.dir, "300/stat", "300 (bash)" ++ comptime std.fmt.comptimePrint(stat, .{ 1, 500 }));
    try writeTestFile(tmp.dir, "301/stat", "301 (a-very-long-pro)" ++ comptime std.fmt.comptimePrint(stat, .{ 300, 600 }));
    try writeTestFile(tmp.dir, "301/cmdline", "/opt/a-very-long-program-name\x00");
    try writeTestFile(tmp.dir, "400/stat", "400 (another-long-na)" ++ comptime std.fmt.comptimePrint(stat, .{ 1, 700 }));
    try writeTestFile(tmp.dir, "400/cmdline", "/opt/another-long-name\x00");

    var table: Table = try .readProc(testing.allocator, testing.io, tmp.dir);
    defer table.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tree = try table.tree(arena.allocator(), &.{300});
    try testing.expectEqual(@as(usize, 2), tree.processes.len);
    try testing.expectEqualStrings("a-very-long-program-name", tree.processes[1].name);
    try testing.expectEqual(@as(?u64, 600), tree.processes[1].created);

    // The process outside the tree kept its truncated name unread.
    const outside = table.indexOf(400).?;
    try testing.expectEqual(@as(?[]const u8, null), table.entries[outside].name);
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
    try testing.expect(snap.table.count() > 1);
}

test "Shared reuses a table until it is ttl old" {
    const testing = std.testing;
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;

    var shared: Shared = .{};
    defer shared.deinit();
    const start: std.Io.Timestamp = .fromNanoseconds(10 * std.time.ns_per_s);
    const first = try shared.getAt(testing.allocator, testing.io, start);
    try testing.expect(first.count() > 0);
    try testing.expectEqual(@as(u64, 1), shared.captures);

    const later = start.addDuration(.fromMilliseconds(Shared.default_ttl_ms - 1));
    _ = try shared.getAt(testing.allocator, testing.io, later);
    try testing.expectEqual(@as(u64, 1), shared.captures);

    // A clock that went backwards does not keep the table forever.
    _ = try shared.getAt(testing.allocator, testing.io, .fromNanoseconds(0));
    try testing.expectEqual(@as(u64, 2), shared.captures);

    const expired: std.Io.Timestamp = .fromNanoseconds(std.time.ns_per_ms * Shared.default_ttl_ms);
    _ = try shared.getAt(testing.allocator, testing.io, expired);
    try testing.expectEqual(@as(u64, 3), shared.captures);

    shared.invalidate();
    _ = try shared.getAt(testing.allocator, testing.io, expired);
    try testing.expectEqual(@as(u64, 4), shared.captures);
}
