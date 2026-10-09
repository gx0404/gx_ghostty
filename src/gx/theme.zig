//! The built-in Ghostty GX theme "GX Mocha": the Catppuccin Mocha ANSI
//! palette on a #1f1f28 background with white text.
//!
//! Ghostty resolves `theme = GX Mocha` like any other theme name, first in
//! the user's theme directory (`<config dir>/ghostty/themes`) and then in
//! the resources directory. `install` writes the embedded theme into the
//! user's theme directory so the name resolves even without installed
//! resources; the file carries `marker` so later versions can replace it
//! without touching a user's own file of the same name.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const name = "GX Mocha";

/// The first line of a theme file written by Ghostty GX.
pub const marker = "# Ghostty GX built-in theme: " ++ name;

/// The theme file, with LF line endings regardless of the checkout.
pub const content: []const u8 = withoutCr(@embedFile("themes/GX Mocha"));

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
/// light or dark part) is the built-in theme.
pub fn isBuiltin(theme: []const u8) bool {
    return std.mem.eql(u8, theme, name);
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

/// Makes `<dir_path>/GX Mocha` hold the built-in theme, creating
/// `dir_path` if needed. The file is replaced atomically.
pub fn install(alloc: Allocator, io: std.Io, dir_path: []const u8) !InstallResult {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    const existing: ?[]u8 = dir.readFileAlloc(io, name, alloc, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |old| alloc.free(old);
    if (existing) |old| {
        if (equalIgnoringCr(old, content)) return .unchanged;
        if (!std.mem.startsWith(u8, old, marker)) return .user_file;
    }

    var buf: [1024]u8 = undefined;
    var atomic_file = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer atomic_file.deinit(io);
    var file_writer = atomic_file.file.writer(io, &buf);
    file_writer.interface.writeAll(content) catch return file_writer.err orelse error.WriteFailed;
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

test "content starts with the marker and sets no fonts" {
    const testing = std.testing;
    try testing.expect(std.mem.startsWith(u8, content, marker ++ "\n"));
    try testing.expect(std.mem.indexOfScalar(u8, content, '\r') == null);
    try testing.expect(std.mem.indexOf(u8, content, "background = #1f1f28\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "foreground = #ffffff\n") != null);
    try testing.expect(std.mem.indexOf(u8, content, "font-") == null);
    try testing.expect(isBuiltin("GX Mocha"));
    try testing.expect(!isBuiltin("gx mocha"));
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

    try testing.expectEqual(InstallResult.created, try install(alloc, io, themes));
    try testing.expectEqual(InstallResult.unchanged, try install(alloc, io, themes));

    const path = "ghostty/themes/" ++ name;
    var buf: [max_file_size]u8 = undefined;
    try testing.expectEqualStrings(content, try tmp.dir.readFile(io, path, &buf));

    const crlf = try std.mem.replaceOwned(u8, alloc, content, "\n", "\r\n");
    defer alloc.free(crlf);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = crlf });
    try testing.expectEqual(InstallResult.unchanged, try install(alloc, io, themes));

    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = marker ++ "\n# gx-theme-version: 0\nbackground = #000000\n" });
    try testing.expectEqual(InstallResult.updated, try install(alloc, io, themes));
    try testing.expectEqualStrings(content, try tmp.dir.readFile(io, path, &buf));

    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "background = #123456\n" });
    try testing.expectEqual(InstallResult.user_file, try install(alloc, io, themes));
    try testing.expectEqualStrings("background = #123456\n", try tmp.dir.readFile(io, path, &buf));
}
