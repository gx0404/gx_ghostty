const std = @import("std");

pub fn appendFlags(alloc: std.mem.Allocator, current: []const u8, flags: []const []const u8) std.mem.Allocator.Error![:0]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try result.appendSlice(alloc, current);
    for (flags) |flag| {
        if (flag.len == 0 or contains(result.items, flag)) continue;
        if (result.items.len > 0 and !separator(result.items[result.items.len - 1])) try result.append(alloc, ',');
        try result.appendSlice(alloc, flag);
    }
    return result.toOwnedSliceSentinel(alloc, 0);
}

fn separator(byte: u8) bool {
    return std.mem.indexOfScalar(u8, ":;, \t\r\n", byte) != null;
}

fn contains(value: []const u8, flag: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, value, ":;, \t\r\n");
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(token, flag)) return true;
    return false;
}

const testing = std.testing;

test "append flags preserves user and unknown tokens and NUL terminates" {
    const result = try appendFlags(testing.allocator, "unknown:gl-debug; no-vulkan ", &.{ "vulkan", "opengl" });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("unknown:gl-debug; no-vulkan vulkan,opengl", result);
    try testing.expectEqual(@as(u8, 0), result[result.len]);
}

test "append flags is idempotent with duplicate and case insensitive tokens" {
    const first = try appendFlags(testing.allocator, "OPENGL,unknown", &.{ "opengl", "vulkan", "vulkan" });
    defer testing.allocator.free(first);
    const second = try appendFlags(testing.allocator, first, &.{ "opengl", "vulkan" });
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("OPENGL,unknown,vulkan", first);
    try testing.expectEqualStrings(first, second);
}

test "append flags grows beyond the former fixed buffer" {
    const long = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(long);
    @memset(long, 'x');
    const result = try appendFlags(testing.allocator, long, &.{"vulkan"});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(long, result[0..long.len]);
    try testing.expectEqualStrings(",vulkan", result[long.len..]);
    try testing.expectEqual(@as(u8, 0), result[result.len]);
}

test "append flags handles absent empty and already satisfied values" {
    for ([_][]const u8{ "", "vulkan", "vulkan," }) |current| {
        const result = try appendFlags(testing.allocator, current, &.{ "", "vulkan" });
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(if (current.len == 0) "vulkan" else current, result);
    }
    const result = try appendFlags(testing.allocator, "user-only", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("user-only", result);
}

fn allocationCheck(alloc: std.mem.Allocator) !void {
    const result = try appendFlags(alloc, "unknown", &.{ "vulkan", "opengl" });
    defer alloc.free(result);
    try testing.expectEqualStrings("unknown,vulkan,opengl", result);
}

test "append flags frees partial allocations on failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationCheck, .{});
}
