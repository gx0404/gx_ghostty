//! What kind of program runs in the foreground of a terminal, for status
//! marks on tabs and windows: a remote session, a superuser shell or a
//! container. The GTK apprt can show it on the tab page and as the
//! `.gx-remote` and `.gx-superuser` window classes; the win32 tab bar
//! can apply the same rules.
//!
//! The kind comes from the program's name (`classify`): ssh and similar
//! clients are remote; sudo, su, doas and similar are superuser; toolbox,
//! distrobox and similar are containers, and so are docker, podman,
//! kubectl and similar tools running one of their commands that enter a
//! container (`container_commands`). On Linux a program running as root
//! while Ghostty does not is superuser too (`/proc/<pid>/status`). The
//! program is the foreground process group leader of the pty on Linux; on
//! Windows, which has no foreground process groups, it is the program
//! running below the shell (`proc.Tree.program`), whose arguments are
//! unknown.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");
const proc = @import("proc.zig");

pub const Kind = enum {
    /// A program of the user on this machine.
    local,

    /// A session on another machine.
    remote,

    /// A program running as root.
    superuser,

    /// A shell or program inside a container.
    container,
};

/// Programs that connect to another machine. All of these lists are
/// matched with `policy.nameMatches`.
pub const remote_programs = [_][:0]const u8{
    "ssh",
    "slogin",
    "autossh",
    "sshpass",
    "mosh",
    "mosh-client",
    "et",
    "telnet",
    "rlogin",
    "rsh",
    "plink",
};

/// Programs that run a command as root.
pub const superuser_programs = [_][:0]const u8{
    "sudo",
    "sudo-rs",
    "su",
    "doas",
    "pkexec",
    "run0",
    "gsudo",
};

/// Programs that run a shell inside a container.
pub const container_programs = [_][:0]const u8{
    "toolbox",
    "distrobox*",
    "systemd-nspawn",
    "lxc-attach",
    "lxc-console",
    "nsenter",
};

/// Container tools that enter a container only with one of
/// `container_commands` among their first arguments.
pub const container_tools = [_][:0]const u8{
    "docker",
    "podman",
    "nerdctl",
    "finch",
    "kubectl",
    "oc",
    "lxc",
    "incus",
};

/// Commands of `container_tools` that run something inside a container.
pub const container_commands = [_][]const u8{
    "exec",
    "run",
    "attach",
    "debug",
    "shell",
    "enter",
    "console",
    "rsh",
};

/// How many arguments that are not options a container tool's command
/// can follow (`docker compose exec`, `kubectl -n <namespace> exec`).
const max_command_position = 3;

/// The kind of the program `name` with the arguments `args` (after the
/// program; null when unknown, which never makes a container tool a
/// container). `root` says it runs as root while Ghostty does not.
pub fn classify(name: []const u8, args: ?[]const []const u8, root: bool) Kind {
    if (root or policy.matchesAny(name, &superuser_programs)) return .superuser;
    if (policy.matchesAny(name, &remote_programs)) return .remote;
    if (policy.matchesAny(name, &container_programs)) return .container;
    if (policy.matchesAny(name, &container_tools)) {
        if (entersContainer(args orelse return .local)) return .container;
    }
    return .local;
}

fn entersContainer(args: []const []const u8) bool {
    var position: usize = 0;
    for (args) |arg| {
        if (arg.len == 0 or arg[0] == '-') continue;
        for (container_commands) |command| {
            if (std.mem.eql(u8, arg, command)) return true;
        }
        position += 1;
        if (position == max_command_position) return false;
    }
    return false;
}

/// The kind of the foreground program of the terminal whose
/// `Surface.getProcessInfo(.foreground_pid)` is `root` (see the module
/// documentation). On Windows, pass the tree of a shared process table
/// (`proc.Table.tree` with `root` among its roots) when there is one;
/// otherwise the processes are listed for this call. A missing pid,
/// unreadable processes and systems other than Linux and Windows are
/// `.local`.
pub fn terminalKind(alloc: Allocator, io: std.Io, root: ?u64, tree: ?proc.Tree) Kind {
    const pid = std.math.cast(proc.Pid, root orelse return .local) orelse return .local;
    switch (builtin.target.os.tag) {
        .linux => {
            var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{}) catch return .local;
            defer dir.close(io);
            return procKind(alloc, io, dir, pid, std.os.linux.geteuid()) catch .local;
        },
        .windows => {
            if (tree) |t| return treeKind(alloc, t, pid) catch .local;
            var snapshot = proc.snapshot(alloc, io, pid) catch return .local;
            defer snapshot.deinit();
            return treeKind(alloc, snapshot.tree, pid) catch .local;
        },
        else => return .local,
    }
}

/// `terminalKind` from a process tree: by name, the strongest kind among
/// the program running below the shell `root` (`proc.Tree.program`) and
/// the processes between them, so that `sudo` or `ssh` running another
/// program still counts. Superuser is the strongest, then remote, then
/// container.
pub fn treeKind(alloc: Allocator, tree: proc.Tree, root: proc.Pid) Allocator.Error!Kind {
    var index: ?usize = try tree.programIndex(alloc, root) orelse return .local;
    var kind: Kind = .local;
    var steps: usize = 0;
    while (index) |i| : (steps += 1) {
        if (steps > tree.processes.len) break;
        const process = tree.processes[i];
        kind = stronger(kind, classify(process.name, null, false));
        if (process.pid == root) break;
        index = tree.find(process.ppid);
    }
    return kind;
}

fn stronger(a: Kind, b: Kind) Kind {
    return if (rank(b) > rank(a)) b else a;
}

fn rank(kind: Kind) u2 {
    return switch (kind) {
        .local => 0,
        .container => 1,
        .remote => 2,
        .superuser => 3,
    };
}

/// `terminalKind` on Linux, reading a procfs layout from `proc_dir`
/// (normally `/proc`): the name, the arguments (for container tools) and
/// the effective user of the foreground process group leader `pid`.
/// `own_euid` is Ghostty's effective user id.
pub fn procKind(
    alloc: Allocator,
    io: std.Io,
    proc_dir: std.Io.Dir,
    pid: proc.Pid,
    own_euid: u32,
) Allocator.Error!Kind {
    const name = try proc.processName(alloc, io, proc_dir, pid) orelse return .local;
    defer alloc.free(name);
    const root = own_euid != 0 and (effectiveUid(io, proc_dir, pid) orelse own_euid) == 0;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const args = if (policy.matchesAny(name, &container_tools))
        try readArgs(arena.allocator(), io, proc_dir, pid)
    else
        null;
    return classify(name, args, root);
}

/// The effective user id of process `pid`, from the `Uid:` line of
/// `<pid>/status` in `proc_dir`, or null if it is unknown.
pub fn effectiveUid(io: std.Io, proc_dir: std.Io.Dir, pid: proc.Pid) ?u32 {
    var path_buf: [32]u8 = undefined;
    const path = std.mem.print(&path_buf, "{d}/status", .{pid}) catch return null;
    var buf: [4096]u8 = undefined;
    const data = proc_dir.readFile(io, path, &buf) catch return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const prefix = "Uid:";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        // Real, effective, saved and file system user ids.
        var ids = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
        _ = ids.next() orelse return null;
        return std.fmt.parseInt(u32, ids.next() orelse return null, 10) catch null;
    }
    return null;
}

/// The arguments of process `pid` after the program, from `<pid>/cmdline`
/// in `proc_dir`, or null if they are unknown.
fn readArgs(arena: Allocator, io: std.Io, proc_dir: std.Io.Dir, pid: proc.Pid) Allocator.Error!?[]const []const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.mem.print(&path_buf, "{d}/cmdline", .{pid}) catch return null;
    var buf: [4096]u8 = undefined;
    const data = proc_dir.readFile(io, path, &buf) catch return null;
    var args: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\x00"), 0);
    _ = it.next();
    while (it.next()) |arg| try args.append(arena, try arena.dupe(u8, arg));
    return args.items;
}

test "classify by program name" {
    const testing = std.testing;
    try testing.expectEqual(Kind.local, classify("zsh", null, false));
    try testing.expectEqual(Kind.local, classify("vim", &.{"file"}, false));
    try testing.expectEqual(Kind.remote, classify("ssh", null, false));
    try testing.expectEqual(Kind.remote, classify("ssh.exe", null, false));
    try testing.expectEqual(Kind.remote, classify("mosh-client", null, false));
    try testing.expectEqual(Kind.remote, classify("PLINK.EXE", null, false));
    try testing.expectEqual(Kind.superuser, classify("sudo", null, false));
    try testing.expectEqual(Kind.superuser, classify("-su", null, false));
    try testing.expectEqual(Kind.superuser, classify("gsudo.exe", null, false));
    try testing.expectEqual(Kind.container, classify("toolbox", null, false));
    try testing.expectEqual(Kind.container, classify("distrobox-enter", null, false));
    // Running as root wins over the name.
    try testing.expectEqual(Kind.superuser, classify("bash", null, true));
    try testing.expectEqual(Kind.superuser, classify("ssh", null, true));
    try testing.expectEqual(Kind.local, classify("sshd-helper", null, false));
}

test "classify container tools by their command" {
    const testing = std.testing;
    try testing.expectEqual(Kind.container, classify("docker", &.{ "exec", "-it", "web", "sh" }, false));
    try testing.expectEqual(Kind.container, classify("docker", &.{ "--context", "prod", "exec", "-it", "web", "sh" }, false));
    try testing.expectEqual(Kind.container, classify("docker", &.{ "compose", "exec", "web", "bash" }, false));
    try testing.expectEqual(Kind.container, classify("podman", &.{ "run", "--rm", "-it", "fedora" }, false));
    try testing.expectEqual(Kind.container, classify("kubectl", &.{ "-n", "dev", "exec", "-it", "pod", "--", "bash" }, false));
    try testing.expectEqual(Kind.container, classify("oc", &.{ "rsh", "pod" }, false));
    try testing.expectEqual(Kind.container, classify("lxc", &.{ "shell", "c1" }, false));
    try testing.expectEqual(Kind.local, classify("docker", &.{ "build", "-t", "app", "." }, false));
    try testing.expectEqual(Kind.local, classify("kubectl", &.{ "logs", "-f", "pod" }, false));
    try testing.expectEqual(Kind.local, classify("podman", &.{}, false));
    // The command comes within the first few words.
    try testing.expectEqual(Kind.local, classify("docker", &.{ "image", "inspect", "x", "run" }, false));
    // Unknown arguments, as on Windows.
    try testing.expectEqual(Kind.local, classify("docker.exe", null, false));
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "procKind reads a procfs layout" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const status = "Name:\t{s}\nUmask:\t0022\nState:\tS (sleeping)\nUid:\t{d}\t{d}\t{d}\t{d}\nGid:\t1000\t1000\t1000\t1000\n";
    try writeTestFile(tmp.dir, "100/comm", "bash\n");
    try writeTestFile(tmp.dir, "100/status", std.fmt.comptimePrint(status, .{ "bash", 1000, 1000, 1000, 1000 }));
    try writeTestFile(tmp.dir, "200/comm", "bash\n");
    try writeTestFile(tmp.dir, "200/status", std.fmt.comptimePrint(status, .{ "bash", 0, 0, 0, 0 }));
    try writeTestFile(tmp.dir, "300/comm", "sudo\n");
    try writeTestFile(tmp.dir, "300/status", std.fmt.comptimePrint(status, .{ "sudo", 1000, 0, 0, 0 }));
    try writeTestFile(tmp.dir, "400/comm", "ssh\n");
    try writeTestFile(tmp.dir, "400/status", std.fmt.comptimePrint(status, .{ "ssh", 1000, 1000, 1000, 1000 }));
    try writeTestFile(tmp.dir, "500/comm", "podman\n");
    try writeTestFile(tmp.dir, "500/cmdline", "podman\x00exec\x00-it\x00toolbx\x00bash\x00");
    try writeTestFile(tmp.dir, "600/comm", "podman\n");
    try writeTestFile(tmp.dir, "600/cmdline", "podman\x00ps\x00");

    try testing.expectEqual(@as(?u32, 1000), effectiveUid(io, tmp.dir, 100));
    try testing.expectEqual(@as(?u32, 0), effectiveUid(io, tmp.dir, 300));
    try testing.expectEqual(@as(?u32, null), effectiveUid(io, tmp.dir, 500));

    try testing.expectEqual(Kind.local, try procKind(alloc, io, tmp.dir, 100, 1000));
    try testing.expectEqual(Kind.superuser, try procKind(alloc, io, tmp.dir, 200, 1000));
    // Ghostty running as root does not mark every root shell.
    try testing.expectEqual(Kind.local, try procKind(alloc, io, tmp.dir, 200, 0));
    try testing.expectEqual(Kind.superuser, try procKind(alloc, io, tmp.dir, 300, 1000));
    try testing.expectEqual(Kind.remote, try procKind(alloc, io, tmp.dir, 400, 1000));
    try testing.expectEqual(Kind.container, try procKind(alloc, io, tmp.dir, 500, 1000));
    try testing.expectEqual(Kind.local, try procKind(alloc, io, tmp.dir, 600, 1000));
    try testing.expectEqual(Kind.local, try procKind(alloc, io, tmp.dir, 999, 1000));
}

test "treeKind looks below the shell" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tree: proc.Tree = .{ .processes = &.{
        .{ .pid = 10, .ppid = 1, .created = 10, .name = "pwsh.exe" },
        .{ .pid = 11, .ppid = 10, .created = 11, .name = "ssh.exe" },
        .{ .pid = 12, .ppid = 10, .created = 9, .name = "conhost.exe" },
        .{ .pid = 20, .ppid = 1, .created = 20, .name = "cmd.exe" },
        .{ .pid = 21, .ppid = 20, .created = 21, .name = "ping.exe" },
        .{ .pid = 30, .ppid = 1, .created = 30, .name = "pwsh.exe" },
        .{ .pid = 31, .ppid = 30, .created = 31, .name = "gsudo.exe" },
        .{ .pid = 32, .ppid = 31, .created = 32, .name = "ssh.exe" },
        .{ .pid = 33, .ppid = 32, .created = 33, .name = "conhost.exe" },
        .{ .pid = 40, .ppid = 1, .created = 40, .name = "ssh.exe" },
    } };
    const alloc = arena.allocator();
    try testing.expectEqual(Kind.remote, try treeKind(alloc, tree, 10));
    try testing.expectEqual(Kind.local, try treeKind(alloc, tree, 20));
    // sudo running ssh: the program is ssh, superuser is stronger.
    try testing.expectEqual(Kind.superuser, try treeKind(alloc, tree, 30));
    // A profile that runs ssh directly.
    try testing.expectEqual(Kind.remote, try treeKind(alloc, tree, 40));
    try testing.expectEqual(Kind.local, try treeKind(alloc, tree, 99));
}

test "terminalKind without a process" {
    const testing = std.testing;
    try testing.expectEqual(Kind.local, terminalKind(testing.allocator, testing.io, null, null));
    try testing.expectEqual(Kind.local, terminalKind(testing.allocator, testing.io, std.math.maxInt(u64), null));
}
