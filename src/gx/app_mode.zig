//! herdr app mode for Ghostty GX: while the only tab of a window runs
//! herdr, the window presents herdr like a standalone application (the
//! GTK apprt hides the tab bar; see `gx-herdr-app-mode`). The apprts ask
//! `terminalRunsHerdr` about every terminal of a window's only tab,
//! passing what `Surface.getProcessInfo(.foreground_pid)` reports, and
//! combine the answers with `decide`.
//!
//! On Linux that pid is the foreground process group leader of the pty,
//! so herdr counts while it runs in the foreground: herdr itself, or a
//! program such as a wrapper script that runs herdr below it. A shell in
//! the foreground means herdr is not running there (at most as a stopped
//! or background job) and needs no process scan, which keeps the periodic
//! check of an idle window down to reading one `comm` file. On Windows the
//! pid is the terminal's child process (normally the shell), so herdr
//! anywhere below it counts and every check lists the processes.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");
const proc = @import("proc.zig");

const log = std.log.scoped(.gx_app_mode);

/// What the name of a terminal's foreground process says about herdr.
pub const Foreground = enum {
    /// herdr runs in the foreground.
    herdr,
    /// A shell or another built-in idle process is in the foreground.
    idle,
    /// Another program is in the foreground; herdr may run below it.
    other,
};

/// Classifies the name of a terminal's foreground process.
pub fn classify(name: []const u8) Foreground {
    if (policy.nameMatches(name, "herdr")) return .herdr;
    if (policy.matchesAny(name, &policy.builtin_idle_processes)) return .idle;
    return .other;
}

/// Whether a window is in herdr app mode, given `enabled`
/// (`gx-herdr-app-mode`), its number of tabs and the `terminalRunsHerdr`
/// answers for the terminals of its tab. Any terminal running herdr turns
/// app mode on; unknown answers (null) keep `current` when no terminal is
/// known to run herdr.
pub fn decide(enabled: bool, tab_count: usize, answers: []const ?bool, current: bool) bool {
    if (!enabled or tab_count != 1) return false;
    var unknown = false;
    for (answers) |answer| {
        const runs = answer orelse {
            unknown = true;
            continue;
        };
        if (runs) return true;
    }
    return unknown and current;
}

/// Whether the terminal whose `Surface.getProcessInfo(.foreground_pid)` is
/// `root` runs herdr (see the module documentation). With `scan` false,
/// answers that need a list of processes (Linux: the foreground process
/// is neither herdr nor a shell; Windows: always) are null. A missing pid,
/// errors and systems other than Linux and Windows answer false.
pub fn terminalRunsHerdr(alloc: Allocator, io: std.Io, root: ?u64, scan: bool) ?bool {
    const pid = std.math.cast(proc.Pid, root orelse return false) orelse return false;
    switch (builtin.os.tag) {
        .linux => {
            var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |err| {
                log.warn("cannot open /proc err={}", .{err});
                return false;
            };
            defer dir.close(io);
            return procRunsHerdr(alloc, io, dir, pid, scan) catch false;
        },
        .windows => {
            if (!scan) return null;
            var snapshot = proc.snapshot(alloc, io, pid) catch return false;
            defer snapshot.deinit();
            return snapshot.tree.containsProcess(alloc, pid, "herdr") catch false;
        },
        else => return false,
    }
}

/// `terminalRunsHerdr` for Linux, reading a procfs layout from `proc_dir`
/// (normally `/proc`).
pub fn procRunsHerdr(
    alloc: Allocator,
    io: std.Io,
    proc_dir: std.Io.Dir,
    root: proc.Pid,
    scan: bool,
) Allocator.Error!?bool {
    const name = try proc.processName(alloc, io, proc_dir, root) orelse return false;
    defer alloc.free(name);
    switch (classify(name)) {
        .herdr => return true,
        .idle => return false,
        .other => if (!scan) return null,
    }
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const tree: proc.Tree = .{ .processes = try proc.procSnapshot(arena.allocator(), io, proc_dir, root) };
    return try tree.containsProcess(alloc, root, "herdr");
}

test "classify foreground processes" {
    const testing = std.testing;
    try testing.expectEqual(Foreground.herdr, classify("herdr"));
    try testing.expectEqual(Foreground.herdr, classify("herdr.exe"));
    try testing.expectEqual(Foreground.idle, classify("-zsh"));
    try testing.expectEqual(Foreground.idle, classify("bash"));
    try testing.expectEqual(Foreground.idle, classify("pwsh.exe"));
    try testing.expectEqual(Foreground.other, classify("vim"));
    try testing.expectEqual(Foreground.other, classify("gx-herdr"));
    try testing.expectEqual(Foreground.other, classify("herdr-helper"));
}

test "decide needs the feature, a single tab and herdr" {
    const testing = std.testing;
    try testing.expect(decide(true, 1, &.{true}, false));
    try testing.expect(decide(true, 1, &.{ false, true }, false));
    try testing.expect(decide(true, 1, &.{ null, true }, false));
    try testing.expect(!decide(false, 1, &.{true}, true));
    try testing.expect(!decide(true, 2, &.{true}, true));
    try testing.expect(!decide(true, 0, &.{}, true));
    try testing.expect(!decide(true, 1, &.{false}, true));
    try testing.expect(!decide(true, 1, &.{}, true));
}

test "decide keeps the current mode while answers are unknown" {
    const testing = std.testing;
    try testing.expect(decide(true, 1, &.{null}, true));
    try testing.expect(!decide(true, 1, &.{null}, false));
    try testing.expect(decide(true, 1, &.{ false, null }, true));
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn writeTestProcess(dir: std.Io.Dir, pid: proc.Pid, ppid: proc.Pid, started: u64, comm: []const u8) !void {
    var path_buf: [32]u8 = undefined;
    var data_buf: [256]u8 = undefined;
    try writeTestFile(
        dir,
        try std.fmt.bufPrint(&path_buf, "{d}/stat", .{pid}),
        try std.fmt.bufPrint(&data_buf, "{d} ({s}) S {d} 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 {d} 0 0\n", .{ pid, comm, ppid, started }),
    );
    try writeTestFile(
        dir,
        try std.fmt.bufPrint(&path_buf, "{d}/comm", .{pid}),
        try std.fmt.bufPrint(&data_buf, "{s}\n", .{comm}),
    );
}

test "procRunsHerdr reads a procfs layout" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A shell with herdr as a stopped job, vim, a wrapper script running
    // herdr, and herdr itself.
    try writeTestProcess(tmp.dir, 100, 1, 500, "bash");
    try writeTestProcess(tmp.dir, 101, 100, 600, "herdr");
    try writeTestProcess(tmp.dir, 200, 1, 510, "vim");
    try writeTestProcess(tmp.dir, 300, 1, 700, "gx-herdr");
    try writeTestProcess(tmp.dir, 301, 300, 800, "herdr");
    try writeTestProcess(tmp.dir, 302, 301, 900, "zsh");
    try writeTestProcess(tmp.dir, 400, 1, 1000, "herdr");

    try testing.expectEqual(@as(?bool, true), try procRunsHerdr(alloc, io, tmp.dir, 400, false));
    try testing.expectEqual(@as(?bool, false), try procRunsHerdr(alloc, io, tmp.dir, 100, true));
    try testing.expectEqual(@as(?bool, null), try procRunsHerdr(alloc, io, tmp.dir, 300, false));
    try testing.expectEqual(@as(?bool, true), try procRunsHerdr(alloc, io, tmp.dir, 300, true));
    try testing.expectEqual(@as(?bool, null), try procRunsHerdr(alloc, io, tmp.dir, 200, false));
    try testing.expectEqual(@as(?bool, false), try procRunsHerdr(alloc, io, tmp.dir, 200, true));
    try testing.expectEqual(@as(?bool, false), try procRunsHerdr(alloc, io, tmp.dir, 999, true));
}

test "terminalRunsHerdr without a process" {
    const testing = std.testing;
    try testing.expectEqual(@as(?bool, false), terminalRunsHerdr(testing.allocator, testing.io, null, true));
    try testing.expectEqual(@as(?bool, false), terminalRunsHerdr(testing.allocator, testing.io, std.math.maxInt(u64), true));
}
