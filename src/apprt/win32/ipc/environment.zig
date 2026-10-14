//! Resolve canonical on-disk paths before forming an instance namespace.
const std = @import("std");
const n = @import("native.zig");
const policy = @import("Security.zig").policy;
const FileInfo = extern struct {
    attributes: u32,
    creation: [2]u32,
    access: [2]u32,
    write: [2]u32,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};
extern "kernel32" fn GetModuleFileNameW(?n.HANDLE, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFinalPathNameByHandleW(n.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandle(n.HANDLE, *FileInfo) callconv(.winapi) i32;
extern "kernel32" fn LCMapStringEx([*:0]const u16, u32, [*]const u16, i32, [*]u16, i32, ?*anyopaque, ?*anyopaque, isize) callconv(.winapi) i32;

fn canonical(path: [*:0]const u16, output: []u16, stamp: ?*FileInfo) ![]u16 {
    const handle = n.CreateFileW(path, 0, 7, null, 3, 0x02000000, null);
    if (handle == n.INVALID) return error.IsolationPathUnavailable;
    defer _ = n.CloseHandle(handle);
    const count = GetFinalPathNameByHandleW(handle, output.ptr, @intCast(output.len), 0);
    if (count == 0 or count >= output.len) return error.IsolationPathUnavailable;
    if (stamp) |value| if (GetFileInformationByHandle(handle, value) == 0) return error.ImageInformationFailed;
    return output[0..count];
}

fn pathDigest(path: []const u16) !policy.Digest {
    var normalized: [32768]u16 = undefined;
    const size = LCMapStringEx(std.unicode.utf8ToUtf16LeStringLiteral(""), 0x200, path.ptr, @intCast(path.len), &normalized, normalized.len, null, null, 0);
    if (size <= 0) return error.PathNormalizationFailed;
    return hash(std.mem.sliceAsBytes(normalized[0..@intCast(size)]));
}

fn hash(bytes: []const u8) policy.Digest {
    var result: policy.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn isolation(allocator: std.mem.Allocator, config_directory: []const u8, class: ?[]const u8, build: []const u8) !policy.Isolation {
    const config_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, config_directory);
    defer allocator.free(config_w);
    var scratch: [32768]u16 = undefined;
    const config_digest = try pathDigest(try canonical(config_w, &scratch, null));
    var exe: [32768:0]u16 = @splat(0);
    const length = GetModuleFileNameW(null, &exe, exe.len);
    if (length == 0 or length >= exe.len) return error.ImagePathFailed;
    var info: FileInfo = undefined;
    const exe_digest = try pathDigest(try canonical(&exe, &scratch, &info));
    var build_hash = std.crypto.hash.sha2.Sha256.init(.{});
    build_hash.update(build);
    build_hash.update(&exe_digest);
    // Exclude access time and link count: they can change while a host runs.
    build_hash.update(std.mem.asBytes(&info.write));
    build_hash.update(std.mem.asBytes(&info.volume));
    build_hash.update(std.mem.asBytes(&info.size_high));
    build_hash.update(std.mem.asBytes(&info.size_low));
    build_hash.update(std.mem.asBytes(&info.index_high));
    build_hash.update(std.mem.asBytes(&info.index_low));
    var build_digest: policy.Digest = undefined;
    build_hash.final(&build_digest);
    return .{ .config_root = config_digest, .class = hash(class orelse ""), .install = exe_digest, .build = build_digest };
}

/// CLI overrides not represented in the typed protocol must execute locally.
pub fn canForwardArgument(argument: []const u8) bool {
    return std.mem.startsWith(u8, argument, "--class=") or
        std.mem.eql(u8, argument, "--gx-single-instance") or
        std.mem.eql(u8, argument, "--gx-single-instance=true");
}

test "apprt.win32.ipc.environment unknown overrides and execute are local" {
    try std.testing.expect(canForwardArgument("--class=example"));
    try std.testing.expect(canForwardArgument("--gx-single-instance=true"));
    for ([_][]const u8{ "-e", "--working-directory=C:/", "--font-size=20", "--initial-window=false", "--config-file=test", "--gx-single-instance=false" }) |arg|
        try std.testing.expect(!canForwardArgument(arg));
}

test "apprt.win32.ipc.environment canonical directories and executable identity" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const alias = try std.fs.path.join(testing.allocator, &.{ root, "." });
    defer testing.allocator.free(alias);
    const first = try isolation(testing.allocator, root, null, "test-build");
    try testing.expectEqualDeep(first, try isolation(testing.allocator, alias, null, "test-build"));
    const different_class = try isolation(testing.allocator, root, "another-class", "test-build");
    try testing.expect(!std.mem.eql(u8, &first.class, &different_class.class));
    const different_build = try isolation(testing.allocator, root, null, "other-build");
    try testing.expect(!std.mem.eql(u8, &first.build, &different_build.build));
}
