//! Bounded, owned drop data. Plain text is never inferred to be a file path.
const std = @import("std");
const Allocator = std.mem.Allocator;
const quote = @import("../../gx/path_quote.zig");

pub const max_bytes = 1024 * 1024;
pub const max_medium_bytes = 4 * max_bytes;
pub const max_files = 256;
pub const max_path_units = 32767;
pub const Error = Allocator.Error || error{ InvalidData, TooLarge, Unsupported, UnsafePath };
pub const Content = union(enum) { text: []u8, files: [][]u8 };

pub const Payload = struct {
    alloc: Allocator,
    content: Content,

    pub fn deinit(self: *Payload) void {
        switch (self.content) {
            .text => |text| self.alloc.free(text),
            .files => |files| {
                for (files) |file| self.alloc.free(file);
                self.alloc.free(files);
            },
        }
        self.* = undefined;
    }

    /// Caller resolves the live terminal and its current shell before calling.
    /// The result goes only through protected paste; this never appends Enter.
    pub fn toPaste(self: *const Payload, alloc: Allocator, style: quote.Style) Error![:0]u8 {
        switch (self.content) {
            .text => |text| return alloc.dupeSentinel(u8, text, 0),
            .files => |files| {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(alloc);
                for (files, 0..) |file, i| {
                    // cmd expands these even inside double quotes. Do not
                    // silently substitute a path or pretend quoting is enough.
                    if (style == .windows and std.mem.indexOfAny(u8, file, "%!") != null)
                        return error.UnsafePath;
                    if (i != 0) try out.append(alloc, ' ');
                    if (!try quote.appendQuoted(alloc, &out, file, style)) return error.UnsafePath;
                    if (out.items.len > max_bytes) return error.TooLarge;
                }
                return alloc.dupeSentinel(u8, out.items, 0);
            },
        }
    }
};

pub fn textUtf8(alloc: Allocator, text: []const u8) Error!Payload {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidData;
    if (text.len > max_bytes) return error.TooLarge;
    return .{ .alloc = alloc, .content = .{ .text = try alloc.dupe(u8, text) } };
}

/// CF_UNICODETEXT / UniformResourceLocatorW must terminate inside GlobalSize.
pub fn unicodeText(alloc: Allocator, bytes: []const u8) Error!Payload {
    const text = try decodeZ(alloc, bytes);
    errdefer alloc.free(text);
    if (text.len == 0) return error.InvalidData;
    if (text.len > max_bytes) return error.TooLarge;
    return .{ .alloc = alloc, .content = .{ .text = text } };
}

fn decodeZ(alloc: Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len > max_medium_bytes) return error.TooLarge;
    if (bytes.len < 2) return error.InvalidData;
    var count: usize = 0;
    while (count < bytes.len / 2 and read16(bytes, count * 2) != 0) : (count += 1) {}
    if (count == bytes.len / 2) return error.InvalidData;
    const wide = try alloc.alloc(u16, count);
    defer alloc.free(wide);
    for (wide, 0..) |*unit, i| unit.* = read16(bytes, i * 2);
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidData,
    };
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

/// A checked CF_HDROP block, not a borrowed clipboard handle. ANSI blocks are
/// explicitly unsupported; Explorer and Unicode OLE sources supply wide lists.
pub fn hdrop(alloc: Allocator, bytes: []const u8) Error!Payload {
    if (bytes.len > max_medium_bytes) return error.TooLarge;
    if (bytes.len < 24) return error.InvalidData;
    const offset = std.mem.readInt(u32, bytes[0..4], .little);
    if (offset < 20 or offset > bytes.len - 4) return error.InvalidData;
    if (std.mem.readInt(u32, bytes[16..20], .little) == 0) return error.Unsupported;
    if (offset % 2 != 0) return error.InvalidData;
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| alloc.free(file);
        files.deinit(alloc);
    }
    var pos: usize = offset;
    var total: usize = 0;
    while (pos + 2 <= bytes.len and read16(bytes, pos) != 0) {
        if (files.items.len == max_files) return error.TooLarge;
        const start = pos;
        while (pos + 2 <= bytes.len and read16(bytes, pos) != 0) : (pos += 2) {}
        if (pos + 2 > bytes.len) return error.InvalidData;
        if ((pos - start) / 2 > max_path_units) return error.TooLarge;
        const file = try decodeZ(alloc, bytes[start .. pos + 2]);
        errdefer alloc.free(file);
        try validatePath(file);
        total += file.len;
        if (total > max_bytes) return error.TooLarge;
        try files.append(alloc, file);
        pos += 2;
    }
    if (files.items.len == 0 or pos + 2 > bytes.len or read16(bytes, pos) != 0) return error.InvalidData;
    return .{ .alloc = alloc, .content = .{ .files = try files.toOwnedSlice(alloc) } };
}

fn validatePath(path: []const u8) Error!void {
    if (path.len < 3 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidData;
    for (path) |c| if (c < 0x20 or c == 0x7f or c == '"') return error.UnsafePath;
    const drive = std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    const unc = std.mem.startsWith(u8, path, "\\\\") and path.len > 4;
    if (!drive and !unc) return error.InvalidData;
}

/// Copy file names obtained from a checked native HDROP adapter.
pub fn filePaths(alloc: Allocator, paths: []const []const u8) Error!Payload {
    if (paths.len == 0) return error.InvalidData;
    if (paths.len > max_files) return error.TooLarge;
    const files = try alloc.alloc([]u8, paths.len);
    var count: usize = 0;
    errdefer {
        for (files[0..count]) |file| alloc.free(file);
        alloc.free(files);
    }
    var total: usize = 0;
    for (paths) |path| {
        try validatePath(path);
        total += path.len;
        if (total > max_bytes) return error.TooLarge;
        files[count] = try alloc.dupe(u8, path);
        count += 1;
    }
    return .{ .alloc = alloc, .content = .{ .files = files } };
}

/// Only explicitly typed URI data reaches this function. Decode percent escapes
/// once; a second encoded percent remains a literal part of the resulting path.
pub fn fileUri(alloc: Allocator, uri: []const u8) Error!Payload {
    if (uri.len > max_bytes) return error.TooLarge;
    if (uri.len < 8 or !std.ascii.startsWithIgnoreCase(uri, "file://")) return error.Unsupported;
    if (std.mem.indexOfAny(u8, uri, "?#\r\n\x00\\") != null) return error.InvalidData;
    const rest = uri[7..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidData;
    const authority = rest[0..slash];
    if (std.mem.indexOfAny(u8, authority, "@:%") != null) return error.InvalidData;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(alloc);
    const local = authority.len == 0 or std.ascii.eqlIgnoreCase(authority, "localhost");
    if (!local) {
        try path.appendSlice(alloc, "\\\\");
        try path.appendSlice(alloc, authority);
    }
    var i: usize = slash + @as(usize, if (local) 1 else 0);
    while (i < rest.len) : (i += 1) {
        var c = rest[i];
        if (c == '%') {
            if (i + 2 >= rest.len) return error.InvalidData;
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch return error.InvalidData;
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch return error.InvalidData;
            c = hi * 16 + lo;
            i += 2;
        }
        try path.append(alloc, if (c == '/') '\\' else c);
    }
    try validatePath(path.items);
    const files = try alloc.alloc([]u8, 1);
    errdefer alloc.free(files);
    files[0] = try path.toOwnedSlice(alloc);
    return .{ .alloc = alloc, .content = .{ .files = files } };
}

test "drop data preserves text and never guesses paths" {
    const alloc = std.testing.allocator;
    var payload = try textUtf8(alloc, "file:///C:/a%20b\r\nnext");
    defer payload.deinit();
    const paste = try payload.toPaste(alloc, .windows);
    defer alloc.free(paste);
    try std.testing.expectEqualStrings("file:///C:/a%20b\r\nnext", paste);
    try std.testing.expectError(error.InvalidData, textUtf8(alloc, "a\x00b"));
}

test "drop URI decodes once and refuses shell expansion for cmd" {
    const alloc = std.testing.allocator;
    var payload = try fileUri(alloc, "file:///C:/space%20%E4%B8%AD%F0%9F%98%80%2520.txt");
    defer payload.deinit();
    const paste = try payload.toPaste(alloc, .powershell);
    defer alloc.free(paste);
    try std.testing.expectEqualStrings("'C:\\space 中😀%20.txt'", paste);
    try std.testing.expectError(error.UnsafePath, payload.toPaste(alloc, .windows));
    try std.testing.expectError(error.UnsafePath, fileUri(alloc, "file:///C:/a%0Ab"));
    try std.testing.expectError(error.Unsupported, fileUri(alloc, "https://example.com/a"));
    try std.testing.expectError(error.InvalidData, fileUri(alloc, "file://user@host/share/a"));
}

test "drop Unicode medium must contain a valid bounded terminator" {
    const alloc = std.testing.allocator;
    var payload = try unicodeText(alloc, &.{ 65, 0, 0, 0 });
    defer payload.deinit();
    try std.testing.expectEqualStrings("A", payload.content.text);
    try std.testing.expectError(error.InvalidData, unicodeText(alloc, &.{ 65, 0 }));
    try std.testing.expectError(error.InvalidData, unicodeText(alloc, &.{ 0, 0xd8, 0, 0 }));
}

test "drop files are owned and joined without Enter" {
    const alloc = std.testing.allocator;
    var payload = try filePaths(alloc, &.{ "C:\\a b.txt", "D:\\中😀.txt" });
    defer payload.deinit();
    const paste = try payload.toPaste(alloc, .powershell);
    defer alloc.free(paste);
    try std.testing.expectEqualStrings("'C:\\a b.txt' 'D:\\中😀.txt'", paste);
    try std.testing.expectError(error.InvalidData, filePaths(alloc, &.{"relative.txt"}));
    try std.testing.expectError(error.UnsafePath, filePaths(alloc, &.{"C:\\bad\nfile"}));
}

fn allocationExercise(alloc: Allocator) !void {
    var files = try filePaths(alloc, &.{ "C:\\a b", "D:\\it's" });
    defer files.deinit();
    const paste = try files.toPaste(alloc, .powershell);
    defer alloc.free(paste);
    var uri = try fileUri(alloc, "file:///C:/some%20file");
    defer uri.deinit();
    var text = try unicodeText(alloc, &.{ 65, 0, 0, 0 });
    defer text.deinit();
}

test "drop allocation failures free partial payloads" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}
