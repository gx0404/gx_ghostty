//! Quoting of Windows file paths that are dropped or pasted into a
//! terminal, for the shell that runs in it. Windows shells get the path as
//! is, in double quotes (cmd.exe) or single quotes (PowerShell, which
//! expands `$` and backticks in double quotes); shells from MSYS2, Cygwin
//! and Git for Windows (GX Zsh, Git Bash) get a single-quoted POSIX path
//! (`/c/Users/...`); WSL gets its `/mnt/c/...` view of the path.
const std = @import("std");
const Allocator = std.mem.Allocator;
const policy = @import("policy.zig");

pub const Style = enum {
    /// `"C:\dir\file"`: cmd.exe and unknown shells.
    windows,
    /// `'C:\dir\file'`, a quote doubled: PowerShell.
    powershell,
    /// `'/c/dir/file'`, a quote as `'\''`: MSYS2, Cygwin and Git Bash.
    msys,
    /// `'/mnt/c/dir/file'`, a quote as `'\''`: WSL.
    wsl,
};

/// The quoting style for a terminal running the processes `names` (its
/// shell and that shell's descendants, root first, see
/// `proc.Tree.names`). The last shell in the list, normally the innermost
/// one, decides; without a known shell it is `.windows`.
pub fn styleFor(names: []const []const u8) Style {
    var style: Style = .windows;
    for (names) |name| {
        if (matches(name, &.{ "pwsh", "powershell" })) {
            style = .powershell;
        } else if (matches(name, &.{"cmd"})) {
            style = .windows;
        } else if (matches(name, &.{ "wsl", "wslhost" })) {
            style = .wsl;
        } else if (matches(name, &.{ "zsh", "bash", "sh", "dash", "ksh", "fish", "gx-zsh" })) {
            style = .msys;
        }
    }
    return style;
}

fn matches(name: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (policy.nameMatches(name, pattern)) return true;
    }
    return false;
}

/// Appends `path` quoted in `style` to `out`. Returns false, appending
/// nothing, for a path the style cannot quote safely: control characters
/// (they could end the line or start an escape sequence) anywhere, or a
/// double quote with `.windows`, whose double quotes cannot escape it.
pub fn appendQuoted(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    style: Style,
) Allocator.Error!bool {
    for (path) |c| {
        if (c < 0x20 or c == 0x7F) return false;
    }
    switch (style) {
        .windows => {
            if (std.mem.indexOfScalar(u8, path, '"') != null) return false;
            try out.ensureUnusedCapacity(alloc, path.len + 2);
            out.appendAssumeCapacity('"');
            out.appendSliceAssumeCapacity(path);
            out.appendAssumeCapacity('"');
        },
        .powershell => {
            try out.append(alloc, '\'');
            for (path) |c| {
                if (c == '\'') try out.append(alloc, '\'');
                try out.append(alloc, c);
            }
            try out.append(alloc, '\'');
        },
        .msys, .wsl => {
            try out.append(alloc, '\'');
            try appendPosixPath(alloc, out, path, style);
            try out.append(alloc, '\'');
        },
    }
    return true;
}

/// The POSIX form of a Windows path, single-quote escaped: `C:\x` becomes
/// `/c/x` (MSYS) or `/mnt/c/x` (WSL); a WSL network path
/// (`\\wsl$\<distro>\x`, `\\wsl.localhost\<distro>\x`) becomes `/x` in
/// WSL; other paths only have their backslashes turned into slashes.
fn appendPosixPath(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    style: Style,
) Allocator.Error!void {
    var rest = path;
    if (rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') {
        try out.appendSlice(alloc, if (style == .wsl) "/mnt/" else "/");
        try out.append(alloc, std.ascii.toLower(rest[0]));
        rest = rest[2..];
        // A bare drive ("C:") is the root of the drive.
        if (rest.len == 0) try out.append(alloc, '/');
    } else if (style == .wsl) {
        if (wslDistroPath(rest)) |inside| rest = inside;
    }
    for (rest) |c| switch (c) {
        '\\' => try out.append(alloc, '/'),
        '\'' => try out.appendSlice(alloc, "'\\''"),
        else => try out.append(alloc, c),
    };
}

/// The part of `\\wsl$\<distro>\x` or `\\wsl.localhost\<distro>\x` after
/// the distribution, starting with its backslash.
fn wslDistroPath(path: []const u8) ?[]const u8 {
    for ([_][]const u8{ "\\\\wsl$\\", "\\\\wsl.localhost\\" }) |prefix| {
        if (path.len <= prefix.len or !std.ascii.startsWithIgnoreCase(path, prefix)) continue;
        const after = path[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, after, '\\') orelse return "\\";
        return after[slash..];
    }
    return null;
}

fn expectQuoted(path: []const u8, style: Style, expected: ?[]const u8) !void {
    const testing = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const ok = try appendQuoted(testing.allocator, &out, path, style);
    if (expected) |e| {
        try testing.expect(ok);
        try testing.expectEqualStrings(e, out.items);
    } else {
        try testing.expect(!ok);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "styleFor picks the innermost shell" {
    const testing = std.testing;
    try testing.expectEqual(Style.windows, styleFor(&.{}));
    try testing.expectEqual(Style.windows, styleFor(&.{ "cmd.exe", "conhost.exe" }));
    try testing.expectEqual(Style.powershell, styleFor(&.{ "pwsh.exe", "conhost.exe" }));
    try testing.expectEqual(Style.powershell, styleFor(&.{"powershell.exe"}));
    try testing.expectEqual(Style.msys, styleFor(&.{ "gx-zsh.exe", "zsh.exe", "gitstatusd-windows-x86_64.exe" }));
    try testing.expectEqual(Style.msys, styleFor(&.{ "pwsh.exe", "bash.exe" }));
    try testing.expectEqual(Style.wsl, styleFor(&.{ "wsl.exe", "wslhost.exe" }));
    try testing.expectEqual(Style.powershell, styleFor(&.{ "zsh.exe", "pwsh.exe", "ping.exe" }));
}

test "appendQuoted for Windows shells" {
    try expectQuoted("C:\\Users\\me\\a b.txt", .windows, "\"C:\\Users\\me\\a b.txt\"");
    try expectQuoted("C:\\x\\it's.txt", .powershell, "'C:\\x\\it''s.txt'");
    try expectQuoted("C:\\x\\$HOME`.txt", .powershell, "'C:\\x\\$HOME`.txt'");
    try expectQuoted("\\\\server\\share\\a\"b", .windows, null);
    try expectQuoted("C:\\a\nb", .powershell, null);
}

test "appendQuoted for POSIX shells" {
    try expectQuoted("C:\\Users\\me\\a b.txt", .msys, "'/c/Users/me/a b.txt'");
    try expectQuoted("D:\\it's", .msys, "'/d/it'\\''s'");
    try expectQuoted("C:", .msys, "'/c/'");
    try expectQuoted("\\\\server\\share\\x", .msys, "'//server/share/x'");
    try expectQuoted("C:\\Users\\me\\a b.txt", .wsl, "'/mnt/c/Users/me/a b.txt'");
    try expectQuoted("\\\\wsl$\\Ubuntu\\home\\me\\x", .wsl, "'/home/me/x'");
    try expectQuoted("\\\\wsl.localhost\\Ubuntu\\home", .wsl, "'/home'");
    try expectQuoted("\\\\wsl.localhost\\Ubuntu", .wsl, "'/'");
    try expectQuoted("C:\\a\x1b[201~", .msys, null);
}
