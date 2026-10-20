//! The built-in Ghostty GX themes: "GX Mocha", the Catppuccin Mocha ANSI
//! palette, text and bright colors on a #1f1f28 background, and its light
//! partner "GX Latte", the Catppuccin Latte palette. The defaults pair
//! them (`theme = light:GX Latte,dark:GX Mocha`), so windows follow the
//! light or dark mode of the system.
//!
//! Ghostty resolves a built-in theme name like any other theme name,
//! first in the user's theme directory (`<config dir>/ghostty/themes`)
//! and then in the resources directory. `install` writes an embedded theme
//! into the user's theme directory so the name resolves even without
//! installed resources; each file starts with the marker of its theme so
//! later versions can replace it without touching a user's own file of
//! the same name.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A built-in theme.
pub const Theme = struct {
    name: []const u8,
    /// The first line of its theme file.
    marker: []const u8,
    /// The theme file, with LF line endings regardless of the checkout.
    content: []const u8,
};

/// The first line of a theme file written by Ghostty GX, before the name.
pub const marker_prefix = "# Ghostty GX built-in theme: ";

pub const mocha = embedded("GX Mocha");
pub const latte = embedded("GX Latte");

/// Every built-in theme.
pub const all = [_]Theme{ mocha, latte };

fn embedded(comptime name: []const u8) Theme {
    return .{
        .name = name,
        .marker = marker_prefix ++ name,
        .content = withoutCr(@embedFile("themes/" ++ name)),
    };
}

fn withoutCr(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(text.len * 4 + 1000);
        var out: [text.len]u8 = undefined;
        var len: usize = 0;
        for (text) |c| {
            if (c == '\r') continue;
            out[len] = c;
            len += 1;
        }
        const result = out[0..len].*;
        return &result;
    }
}

/// Whether a theme name from the configuration (a `theme` value, or its
/// light or dark part) is a built-in theme.
pub fn isBuiltin(theme: []const u8) bool {
    for (all) |builtin| {
        if (std.mem.eql(u8, theme, builtin.name)) return true;
    }
    return false;
}

pub const InstallResult = enum {
    /// The theme file did not exist and was written.
    created,
    /// An older Ghostty GX theme file was replaced.
    updated,
    /// The theme file is already current.
    unchanged,
    /// A file of the same name without `marker` exists; it belongs to the
    /// user and was left alone.
    user_file,
};

/// The largest existing theme file `install` reads.
const max_file_size = 64 * 1024;

/// Makes `<dir_path>/<theme name>` hold the built-in `theme`, creating
/// `dir_path` if needed. The file is replaced atomically.
pub fn install(alloc: Allocator, io: std.Io, dir_path: []const u8, theme: Theme) !InstallResult {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    const existing: ?[]u8 = dir.readFileAlloc(io, theme.name, alloc, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |old| alloc.free(old);
    if (existing) |old| {
        if (equalIgnoringCr(old, theme.content)) return .unchanged;
        if (!std.mem.startsWith(u8, old, theme.marker)) return .user_file;
    }

    var buf: [1024]u8 = undefined;
    var atomic_file = try dir.createFileAtomic(io, theme.name, .{ .replace = true });
    defer atomic_file.deinit(io);
    var file_writer = atomic_file.file.writer(io, &buf);
    file_writer.interface.writeAll(theme.content) catch return file_writer.err orelse error.WriteFailed;
    file_writer.interface.flush() catch return file_writer.err orelse error.WriteFailed;
    try atomic_file.replace(io);
    return if (existing == null) .created else .updated;
}

fn equalIgnoringCr(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and a[i] == '\r') i += 1;
        while (j < b.len and b[j] == '\r') j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

test "every theme starts with its marker and sets no fonts" {
    const testing = std.testing;
    inline for (all) |theme| {
        try testing.expect(std.mem.startsWith(u8, theme.content, theme.marker ++ "\n"));
        try testing.expect(std.mem.indexOfScalar(u8, theme.content, '\r') == null);
        try testing.expect(std.mem.indexOf(u8, theme.content, "font-") == null);
        try testing.expect(std.mem.indexOf(u8, theme.content, "# gx-theme-version: ") != null);
        try testing.expect(isBuiltin(theme.name));
    }
    try testing.expect(!isBuiltin("gx mocha"));
    try testing.expect(!isBuiltin("Catppuccin Latte"));
}

test "GX Mocha has soft text and the Catppuccin bright colors" {
    const testing = std.testing;
    const content = mocha.content;
    try testing.expect(std.mem.indexOf(u8, content, "# gx-theme-version: 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "background = #1f1f28\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "foreground = #cdd6f4\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "palette = 7=#a6adc8\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "palette = 9=#f37799\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "palette = 14=#6bd7ca\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "palette = 15=#bac2de\n") != null);
}

test "GX Latte is the Catppuccin Latte palette" {
    const testing = std.testing;
    const content = latte.content;
    try testing.expect(std.mem.indexOf(u8, content, "background = #eff1f5\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "foreground = #4c4f69\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "palette = 4=#1e66f5\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "palette = 12=#456eff\n") != null);
}

test "equalIgnoringCr" {
    const testing = std.testing;
    try testing.expect(equalIgnoringCr("a\r\nb\r\n", "a\nb\n"));
    try testing.expect(equalIgnoringCr("", "\r"));
    try testing.expect(!equalIgnoringCr("a\nb", "a\nc"));
    try testing.expect(!equalIgnoringCr("a", "ab"));
}

test "install creates, keeps and updates the theme file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const themes = try std.fs.path.join(alloc, &.{ root, "ghostty", "themes" });
    defer alloc.free(themes);

    for (all) |theme| {
        try testing.expectEqual(InstallResult.created, try install(alloc, io, themes, theme));
        try testing.expectEqual(InstallResult.unchanged, try install(alloc, io, themes, theme));
    }

    const content = mocha.content;
    const path = "ghostty/themes/" ++ mocha.name;
    var buf: [max_file_size]u8 = undefined;
    try testing.expectEqualStrings(content, try tmp.dir.readFile(io, path, &buf));
    try testing.expectEqualStrings(latte.content, try tmp.dir.readFile(io, "ghostty/themes/" ++ latte.name, &buf));

    const crlf = try std.mem.replaceOwned(u8, alloc, content, "\n", "\r\n");
    defer alloc.free(crlf);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = crlf });
    try testing.expectEqual(InstallResult.unchanged, try install(alloc, io, themes, mocha));

    // Version 2 of GX Mocha, with white text and the bright colors equal
    // to the normal ones, is replaced.
    const old_version = try std.mem.replaceOwned(u8, alloc, content, "# gx-theme-version: 3", "# gx-theme-version: 2");
    defer alloc.free(old_version);
    const old_text = try std.mem.replaceOwned(u8, alloc, old_version, "foreground = #cdd6f4", "foreground = #ffffff");
    defer alloc.free(old_text);
    const old_theme = try std.mem.replaceOwned(u8, alloc, old_text, "palette = 9=#f37799", "palette = 9=#f38ba8");
    defer alloc.free(old_theme);
    const old_crlf = try std.mem.replaceOwned(u8, alloc, old_theme, "\n", "\r\n");
    defer alloc.free(old_crlf);
    for ([_][]const u8{ old_theme, old_crlf }) |old| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = old });
        try testing.expectEqual(InstallResult.updated, try install(alloc, io, themes, mocha));
        try testing.expectEqualStrings(content, try tmp.dir.readFile(io, path, &buf));
        try testing.expectEqual(InstallResult.unchanged, try install(alloc, io, themes, mocha));
    }

    // A file with another theme's marker is not this theme's file.
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = latte.content });
    try testing.expectEqual(InstallResult.user_file, try install(alloc, io, themes, mocha));

    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "background = #123456\n" });
    try testing.expectEqual(InstallResult.user_file, try install(alloc, io, themes, mocha));
    try testing.expectEqualStrings("background = #123456\n", try tmp.dir.readFile(io, path, &buf));
}
