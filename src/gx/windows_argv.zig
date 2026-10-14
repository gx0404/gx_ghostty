//! Windows process argument encoding, not shell or PowerShell quoting.
//! Every argument is quoted; backslashes preceding quotes and the closing
//! delimiter follow the documented CommandLineToArgvW/CRT rules.
const std = @import("std");
pub const max_units = 32766;

pub fn encode(alloc: std.mem.Allocator, args: []const []const u8) ![:0]u16 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    for (args, 0..) |arg, index| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null or !std.unicode.utf8ValidateSlice(arg)) return error.InvalidArgument;
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.writeByte('"');
        var slashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            try output.writer.splatByteAll('\\', if (byte == '"') slashes * 2 + 1 else slashes);
            slashes = 0;
            try output.writer.writeByte(byte);
        }
        try output.writer.splatByteAll('\\', slashes * 2);
        try output.writer.writeByte('"');
        if (output.written().len > max_units * 4) return error.CommandLineTooLong;
    }
    const encoded = try std.unicode.utf8ToUtf16LeAllocZ(alloc, output.written());
    errdefer alloc.free(encoded);
    if (encoded.len > max_units) return error.CommandLineTooLong;
    return encoded;
}

/// Get the same encoded string as UTF-8 for a package manifest or log-free test.
pub fn encodeUtf8(alloc: std.mem.Allocator, args: []const []const u8) ![]u8 {
    const wide = try encode(alloc, args);
    defer alloc.free(wide);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, wide);
}

test "quotes spaces empty values quotes and trailing backslashes" {
    const testing = std.testing;
    const encoded = try encodeUtf8(testing.allocator, &.{ "ghostty.exe", "", "a b", "a\"b", "C:\\dir with space\\" });
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("\"ghostty.exe\" \"\" \"a b\" \"a\\\"b\" \"C:\\dir with space\\\\\"", encoded);
    try testing.expectError(error.InvalidArgument, encode(testing.allocator, &.{"embedded\x00nul"}));
}

test "native Windows argv decoder roundtrips UTF-8 and trailing slashes" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const args = [_][]const u8{ "C:\\Program Files\\Ghostty GX\\ghostty.exe", "--gx-shell-action=profile", "--gx-shell-profile=custom:\u{4e2d}\u{6587} \"quoted\"\\", "" };
    const command = try encode(testing.allocator, &args);
    defer testing.allocator.free(command);
    var count: c_int = 0;
    const parsed = Native.CommandLineToArgvW(command, &count) orelse return error.DecodeFailed;
    defer _ = Native.LocalFree(@ptrCast(parsed));
    try testing.expectEqual(@as(c_int, args.len), count);
    for (args, 0..) |arg, index| {
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.span(parsed[index]));
        defer testing.allocator.free(utf8);
        try testing.expectEqualStrings(arg, utf8);
    }
}
const Native = struct {
    extern "shell32" fn CommandLineToArgvW([*:0]const u16, *c_int) callconv(.winapi) ?[*][*:0]u16;
    extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
};
