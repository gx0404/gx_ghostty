//! Process policies shared by the Ghostty GX apprts: herdr app mode and
//! whether the processes running in a terminal count as idle (so closing
//! it needs no confirmation).
const std = @import("std");

/// Processes that count as idle when nothing else runs in a terminal:
/// shells, shell launchers and console helpers. Used when
/// `gx-idle-processes` is empty; matched with `nameMatches`.
pub const builtin_idle_processes = [_][:0]const u8{
    "cmd.exe",
    "pwsh.exe",
    "powershell.exe",
    "zsh",
    "bash",
    "sh",
    "fish",
    "nu",
    "gx-zsh",
    "wsl.exe",
    "wslhost.exe",
    "conhost.exe",
    "OpenConsole.exe",
    "gitstatusd*",
    "env.exe",
};

/// Returns true if the process `name` matches `pattern`. Both are compared
/// by basename, ASCII case-insensitively and without a trailing `.exe`,
/// and a leading `-` (login shells such as `-zsh`) is ignored. A trailing
/// `*` in `pattern` matches any suffix.
pub fn nameMatches(name: []const u8, pattern: []const u8) bool {
    const n = normalize(name);
    const p = normalize(pattern);
    if (p.len > 0 and p[p.len - 1] == '*') {
        const prefix = p[0 .. p.len - 1];
        return n.len >= prefix.len and std.ascii.eqlIgnoreCase(n[0..prefix.len], prefix);
    }
    return std.ascii.eqlIgnoreCase(n, p);
}

fn normalize(name: []const u8) []const u8 {
    var base = name;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    if (base.len > 0 and base[0] == '-') base = base[1..];
    const ext = ".exe";
    if (base.len > ext.len and std.ascii.eqlIgnoreCase(base[base.len - ext.len ..], ext)) {
        base = base[0 .. base.len - ext.len];
    }
    return base;
}

/// Returns true if `name` matches any pattern in `patterns`.
pub fn matchesAny(name: []const u8, patterns: []const [:0]const u8) bool {
    for (patterns) |pattern| {
        if (nameMatches(name, pattern)) return true;
    }
    return false;
}

/// Returns true if every process in `names` (the processes running in a
/// terminal, usually from `proc.Tree.names`) is idle according to
/// `idle_list`, or the built-in list when `idle_list` is empty. No
/// processes at all is idle.
pub fn isIdle(names: []const []const u8, idle_list: []const [:0]const u8) bool {
    const list = if (idle_list.len == 0) &builtin_idle_processes else idle_list;
    for (names) |name| {
        if (!matchesAny(name, list)) return false;
    }
    return true;
}

/// Returns true if a window should be in herdr app mode: the feature is
/// enabled (`gx-herdr-app-mode`), the window has exactly one tab, and
/// herdr runs in that tab (`names` are the processes of its terminal).
pub fn herdrAppMode(enabled: bool, tab_count: usize, names: []const []const u8) bool {
    if (!enabled or tab_count != 1) return false;
    for (names) |name| {
        if (nameMatches(name, "herdr")) return true;
    }
    return false;
}

test "nameMatches ignores case, paths, .exe and login dashes" {
    const testing = std.testing;
    try testing.expect(nameMatches("pwsh.exe", "pwsh.exe"));
    try testing.expect(nameMatches("PWSH.EXE", "pwsh.exe"));
    try testing.expect(nameMatches("pwsh", "pwsh.exe"));
    try testing.expect(nameMatches("pwsh.exe", "pwsh"));
    try testing.expect(nameMatches("C:\\Program Files\\PowerShell\\7\\pwsh.exe", "pwsh.exe"));
    try testing.expect(nameMatches("/usr/bin/zsh", "zsh"));
    try testing.expect(nameMatches("-zsh", "zsh"));
    try testing.expect(nameMatches("OpenConsole.exe", "openconsole.exe"));
    try testing.expect(!nameMatches("zshx", "zsh"));
    try testing.expect(!nameMatches("bash", "sh"));
    try testing.expect(!nameMatches(".exe", "exe"));
    try testing.expect(!nameMatches("vim", "nvim"));
}

test "nameMatches supports trailing wildcards" {
    const testing = std.testing;
    try testing.expect(nameMatches("gitstatusd", "gitstatusd*"));
    try testing.expect(nameMatches("gitstatusd-linux-x86_64", "gitstatusd*"));
    try testing.expect(nameMatches("gitstatusd-windows-x86_64.exe", "gitstatusd*"));
    try testing.expect(nameMatches("GitStatusD-linu", "gitstatusd*"));
    try testing.expect(!nameMatches("gitstatus", "gitstatusd*"));
    try testing.expect(nameMatches("anything", "*"));
}

test "isIdle with the built-in list" {
    const testing = std.testing;
    try testing.expect(isIdle(&.{}, &.{}));
    try testing.expect(isIdle(&.{ "pwsh.exe", "conhost.exe" }, &.{}));
    try testing.expect(isIdle(&.{ "gx-zsh.exe", "zsh.exe", "gitstatusd-windows-x86_64.exe" }, &.{}));
    try testing.expect(isIdle(&.{ "zsh", "gitstatusd-linu" }, &.{}));
    try testing.expect(isIdle(&.{ "wsl.exe", "wslhost.exe", "env.exe", "nu.exe" }, &.{}));
    try testing.expect(isIdle(&.{ "-bash", "sh", "fish" }, &.{}));
    try testing.expect(!isIdle(&.{ "pwsh.exe", "vim.exe" }, &.{}));
    try testing.expect(!isIdle(&.{ "zsh", "herdr" }, &.{}));
    try testing.expect(!isIdle(&.{"python3"}, &.{}));
}

test "isIdle with a configured list replaces the built-in list" {
    const testing = std.testing;
    const configured = [_][:0]const u8{ "zsh", "tmux*" };
    try testing.expect(isIdle(&.{ "zsh", "tmux: server" }, &configured));
    try testing.expect(!isIdle(&.{ "zsh", "bash" }, &configured));
}

test "herdrAppMode needs a single tab running herdr" {
    const testing = std.testing;
    try testing.expect(herdrAppMode(true, 1, &.{ "gx-zsh.exe", "zsh.exe", "herdr.exe" }));
    try testing.expect(herdrAppMode(true, 1, &.{"herdr"}));
    try testing.expect(herdrAppMode(true, 1, &.{ "zsh", "/usr/lib/ohmyzsh-gx/lib/herdr/herdr" }));
    try testing.expect(!herdrAppMode(false, 1, &.{"herdr"}));
    try testing.expect(!herdrAppMode(true, 2, &.{"herdr"}));
    try testing.expect(!herdrAppMode(true, 0, &.{"herdr"}));
    try testing.expect(!herdrAppMode(true, 1, &.{ "zsh", "herdr-helper" }));
    try testing.expect(!herdrAppMode(true, 1, &.{}));
}
