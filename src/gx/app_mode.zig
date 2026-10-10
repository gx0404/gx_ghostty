//! herdr app mode for Ghostty GX: while the only tab of a window runs
//! herdr, the window presents herdr like a standalone application (the
//! GTK and win32 apprts hide the tabs and keep the window controls; see
//! `gx-herdr-app-mode`). The apprts ask `terminalRunsHerdr` (or
//! `treeRunsHerdr` with a shared process table) about every terminal of a
//! window's only tab, passing what
//! `Surface.getProcessInfo(.foreground_pid)` reports, and combine the
//! answers with a per-window `State` (or the stateless `decide`).
//!
//! On Linux that pid is the foreground process group leader of the pty,
//! so herdr counts while it runs in the foreground: herdr itself, or a
//! program such as a wrapper script that runs herdr below it. A shell in
//! the foreground means herdr is not running there (at most as a stopped
//! or background job) and needs no process scan, which keeps the periodic
//! check of an idle window down to reading one `comm` file. On Windows the
//! pid is the terminal's child process (normally the shell), so herdr
//! anywhere below it counts and every check lists the processes.
//!
//! The periodic check backs off while nothing changes (`nextDelay`), and
//! entering app mode takes `entry_checks` checks in a row that find herdr,
//! so that a short-lived herdr process does not hide the tabs for a
//! moment.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");
const proc = @import("proc.zig");

const log = std.log.scoped(.gx_app_mode);

/// What `Surface.getProcessInfo(.foreground_pid)` is on a platform.
pub const Root = enum {
    /// The foreground process group leader of the pty (POSIX).
    leader,

    /// The terminal's child process, normally the shell (Windows).
    child,

    pub const native: Root = if (builtin.os.tag == .windows) .child else .leader;
};

/// How many checks in a row must find herdr before a window enters herdr
/// app mode; one check without herdr leaves it.
pub const entry_checks = 2;

/// The herdr app mode of one window, with the entry hysteresis of
/// `entry_checks`. Keep one per window and pass every check to `update`.
pub const State = struct {
    /// Whether the window is in herdr app mode.
    active: bool = false,

    /// Checks in a row that found herdr while not `active`.
    hits: u8 = 0,

    /// Records one check, with the arguments of `decide`, and returns
    /// whether the window is in herdr app mode now. Unknown answers
    /// neither confirm nor end a pending entry.
    pub fn update(self: *State, enabled: bool, tab_count: usize, answers: []const ?bool) bool {
        switch (verdict(enabled, tab_count, answers)) {
            .off => self.* = .{},
            .herdr => if (!self.active) {
                self.hits +|= 1;
                if (self.hits >= entry_checks) self.* = .{ .active = true };
            },
            .unknown => {},
        }
        return self.active;
    }

    /// Whether a check found herdr but the window has not entered app
    /// mode yet: check again soon (see `nextDelay`).
    pub fn pending(self: State) bool {
        return self.hits > 0;
    }
};

/// The shortest and the longest delay between two periodic checks of a
/// window (`nextDelay`).
pub const min_delay_ms: u32 = 500;
pub const max_delay_ms: u32 = 10_000;

/// The delay before the next periodic check of a window: `min_delay_ms`
/// after a `reset` (something that can start or stop herdr happened, such
/// as a title change, a key press or a new tab or split, or the last check
/// changed the state or left an entry `State.pending`), otherwise twice
/// `previous_ms`, between `min_delay_ms` and `max_delay_ms`. An idle
/// window settles at one check every `max_delay_ms`.
pub fn nextDelay(previous_ms: u32, reset: bool) u32 {
    if (reset) return min_delay_ms;
    return std.math.clamp(previous_ms *| 2, min_delay_ms, max_delay_ms);
}

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
/// known to run herdr. `State.update` adds the entry hysteresis.
pub fn decide(enabled: bool, tab_count: usize, answers: []const ?bool, current: bool) bool {
    return switch (verdict(enabled, tab_count, answers)) {
        .off => false,
        .herdr => true,
        .unknown => current,
    };
}

const Verdict = enum { off, herdr, unknown };

/// What one check says: herdr runs in a terminal, app mode is off (the
/// feature is off, the window does not have exactly one tab, or no
/// terminal runs herdr), or unknown (no terminal is known to run herdr,
/// but some answers are unknown).
fn verdict(enabled: bool, tab_count: usize, answers: []const ?bool) Verdict {
    if (!enabled or tab_count != 1) return .off;
    var unknown = false;
    for (answers) |answer| {
        const runs = answer orelse {
            unknown = true;
            continue;
        };
        if (runs) return .herdr;
    }
    return if (unknown) .unknown else .off;
}

/// `terminalRunsHerdr` with the processes listed already: `tree` holds
/// the processes of `root` (`proc.Table.tree` with `root` among its
/// roots, for example from a `proc.Shared` table for every terminal of a
/// check), and `kind` says what `root` is (`Root.native` on the running
/// system). A missing pid, or one that is not in the tree, answers false.
pub fn treeRunsHerdr(alloc: Allocator, tree: proc.Tree, root: ?u64, kind: Root) Allocator.Error!bool {
    const pid = std.math.cast(proc.Pid, root orelse return false) orelse return false;
    const index = tree.find(pid) orelse return false;
    if (kind == .leader) switch (classify(tree.processes[index].name)) {
        .herdr => return true,
        .idle => return false,
        .other => {},
    };
    return try tree.containsProcess(alloc, pid, "herdr");
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

test "State enters after two checks find herdr and leaves at once" {
    const testing = std.testing;
    var state: State = .{};
    try testing.expect(!state.update(true, 1, &.{true}));
    try testing.expect(state.pending());
    // An unknown answer neither confirms nor cancels the pending entry.
    try testing.expect(!state.update(true, 1, &.{null}));
    try testing.expect(state.pending());
    try testing.expect(state.update(true, 1, &.{ false, true }));
    try testing.expect(!state.pending());
    try testing.expect(state.update(true, 1, &.{null}));
    try testing.expect(state.update(true, 1, &.{true}));

    try testing.expect(!state.update(true, 1, &.{false}));
    try testing.expect(!state.pending());

    // A short-lived herdr process between two checks without it.
    try testing.expect(!state.update(true, 1, &.{true}));
    try testing.expect(!state.update(true, 1, &.{false}));
    try testing.expect(!state.pending());
    try testing.expect(!state.update(true, 1, &.{true}));

    // A second tab, or the feature turned off, leaves at once.
    try testing.expect(state.update(true, 1, &.{true}));
    try testing.expect(!state.update(true, 2, &.{true}));
    try testing.expect(!state.update(true, 1, &.{true}));
    try testing.expect(state.update(true, 1, &.{true}));
    try testing.expect(!state.update(false, 1, &.{true}));
    try testing.expect(!state.update(true, 1, &.{}));
}

test "nextDelay backs off while nothing changes" {
    const testing = std.testing;
    var delay: u32 = nextDelay(0, true);
    try testing.expectEqual(min_delay_ms, delay);
    const expected = [_]u32{ 1000, 2000, 4000, 8000, max_delay_ms, max_delay_ms };
    for (expected) |ms| {
        delay = nextDelay(delay, false);
        try testing.expectEqual(ms, delay);
    }
    try testing.expectEqual(min_delay_ms, nextDelay(delay, true));
    try testing.expectEqual(min_delay_ms, nextDelay(0, false));
    try testing.expectEqual(max_delay_ms, nextDelay(std.math.maxInt(u32), false));
}

test "treeRunsHerdr reads a shared tree" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tree: proc.Tree = .{ .processes = &.{
        .{ .pid = 100, .ppid = 1, .created = 500, .name = "bash" },
        .{ .pid = 101, .ppid = 100, .created = 600, .name = "herdr" },
        .{ .pid = 200, .ppid = 1, .created = 510, .name = "vim" },
        .{ .pid = 300, .ppid = 1, .created = 700, .name = "gx-herdr" },
        .{ .pid = 301, .ppid = 300, .created = 800, .name = "herdr" },
        .{ .pid = 400, .ppid = 1, .created = 900, .name = "pwsh.exe" },
        .{ .pid = 401, .ppid = 400, .created = 910, .name = "herdr.exe" },
    } };

    // A foreground shell with herdr as a stopped job does not count when
    // the root is the foreground process group leader, but does when it
    // is the terminal's shell.
    try testing.expect(!try treeRunsHerdr(alloc, tree, 100, .leader));
    try testing.expect(try treeRunsHerdr(alloc, tree, 100, .child));
    try testing.expect(try treeRunsHerdr(alloc, tree, 101, .leader));
    try testing.expect(try treeRunsHerdr(alloc, tree, 300, .leader));
    try testing.expect(!try treeRunsHerdr(alloc, tree, 200, .leader));
    try testing.expect(try treeRunsHerdr(alloc, tree, 400, .child));
    try testing.expect(!try treeRunsHerdr(alloc, tree, 999, .child));
    try testing.expect(!try treeRunsHerdr(alloc, tree, null, .child));
    try testing.expect(!try treeRunsHerdr(alloc, tree, std.math.maxInt(u64), .child));
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
