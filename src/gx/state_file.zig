//! Small files Ghostty GX keeps between runs that are not configuration:
//! the remembered window place (`window_state`) and the command palette
//! history (`palette_history`). They live in the Ghostty state directory,
//! `%LOCALAPPDATA%\ghostty\` on Windows and `$XDG_STATE_HOME/ghostty/`
//! (`~/.local/state/ghostty/`) on Linux, like upstream's SSH terminfo cache,
//! and are replaced atomically, never edited in place.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xdg = @import("../os/xdg.zig");

/// The path of the state file `name`. The caller owns the result.
pub fn path(alloc: Allocator, name: []const u8) ![]u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const dir = xdg.state(global.io(), alloc, &environ_map, .{ .subdir = "ghostty" }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.StateDirectoryNotFound,
    };
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, name });
}

/// Reads the file at `file_path`, owned by the caller. Null when it does
/// not exist; `error.StreamTooLong` when it is larger than `max_size`.
pub fn read(alloc: Allocator, io: std.Io, file_path: []const u8, max_size: usize) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(max_size + 1)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Replaces the file at `file_path` (absolute) with `content`, creating its
/// directory if needed: the content goes to a temporary file that then
/// takes the place of the old one.
pub fn write(io: std.Io, file_path: []const u8, content: []const u8) !void {
    const dir_path = std.fs.path.dirname(file_path) orelse return error.InvalidPath;
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    var buf: [1024]u8 = undefined;
    var atomic_file = try dir.createFileAtomic(io, std.fs.path.basename(file_path), .{ .replace = true });
    defer atomic_file.deinit(io);
    var file_writer = atomic_file.file.writer(io, &buf);
    file_writer.interface.writeAll(content) catch return file_writer.err orelse error.WriteFailed;
    file_writer.interface.flush() catch return file_writer.err orelse error.WriteFailed;
    try atomic_file.replace(io);
}

test "write replaces the file and read returns it" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "ghostty", "state" });
    defer testing.allocator.free(file);

    const alloc = testing.allocator;
    try testing.expectEqual(@as(?[]u8, null), try read(alloc, io, file, 64));
    try write(io, file, "one\n");
    const one = (try read(alloc, io, file, 64)).?;
    defer alloc.free(one);
    try testing.expectEqualStrings("one\n", one);
    try write(io, file, "two\n");
    const two = (try read(alloc, io, file, 4)).?;
    defer alloc.free(two);
    try testing.expectEqualStrings("two\n", two);
    try testing.expectError(error.StreamTooLong, read(alloc, io, file, 3));

    var entries = try tmp.dir.openDir(io, "ghostty", .{ .iterate = true });
    defer entries.close(io);
    var it = entries.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}
