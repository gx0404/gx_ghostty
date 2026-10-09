//! OSC 7 working directories on Windows.
//!
//! Shells report their working directory as a `file://<host>/<path>` URI
//! (or kitty's `kitty-shell-cwd://`). On Windows the path is a drive path
//! with a leading slash, `/C:/Users/me` (percent-encoded in `file:` URIs),
//! or the MSYS2 and Cygwin spellings `/c/Users/me` and
//! `/cygdrive/c/Users/me` (older GX Zsh releases). The termio stream handler
//! validates the scheme and host and decodes the URI path as on every
//! other platform; `nativePath` then turns the path into the native form,
//! `C:\Users\me`, which is what the terminal stores as its pwd and what new
//! tabs, splits and windows inherit as their working directory
//! (`apprt.surface.newConfig` copies the focused surface's pwd into
//! `working-directory`, and CreateProcessW gets it as the current
//! directory). Anything that is not an absolute drive path is ignored:
//! relative paths, UNC and device paths, POSIX paths such as `/home/me`,
//! drive-relative paths (`/C:Users`), and characters Windows paths cannot
//! contain.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.gx_osc7);

pub const Error = error{InvalidPath} || Allocator.Error;

/// The decoded path of an OSC 7 URI as this platform's working directory.
/// Returns the path itself except on Windows, where it is converted with
/// `windowsPath` and null means it is not a usable working directory.
pub fn nativePath(alloc: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    if (comptime builtin.os.tag != .windows) return path;
    return windowsPath(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => {
            log.warn("OSC 7 path is not an absolute Windows drive path: {s}", .{path});
            return null;
        },
    };
}

/// Convert a URI path to an absolute Windows path: `/C:/Users/me`,
/// `/c/Users/me` and `/cygdrive/c/Users/me` all become `C:\Users\me`, and
/// `/C:`, `/c` and `/cygdrive/c` become `C:\`. Separators may be `/` or
/// `\`; repeated and trailing separators are dropped and the drive letter
/// is upper-cased. The result is allocated.
pub fn windowsPath(alloc: Allocator, path_: []const u8) Error![]u8 {
    // Cygwin's default prefix for drive mounts.
    const cygdrive = "/cygdrive";
    const path = if (std.mem.startsWith(u8, path_, cygdrive ++ "/"))
        path_[cygdrive.len..]
    else
        path_;

    if (path.len < 2 or path[0] != '/') return error.InvalidPath;
    const drive = path[1];
    if (!std.ascii.isAlphabetic(drive)) return error.InvalidPath;

    // The rest after the drive: "/C:" + rest or (MSYS) "/c" + rest. Both
    // must continue with a separator or end.
    var rest = path[2..];
    if (rest.len > 0 and rest[0] == ':') rest = rest[1..];
    if (rest.len > 0 and !isSeparator(rest[0])) return error.InvalidPath;

    var result: std.ArrayList(u8) = try .initCapacity(alloc, rest.len + 3);
    errdefer result.deinit(alloc);
    result.appendSliceAssumeCapacity(&.{ std.ascii.toUpper(drive), ':', '\\' });

    var it = std.mem.tokenizeAny(u8, rest, "/\\");
    var first = true;
    while (it.next()) |segment| {
        for (segment) |c| if (!validPathByte(c)) return error.InvalidPath;
        if (!first) try result.append(alloc, '\\');
        try result.appendSlice(alloc, segment);
        first = false;
    }

    return result.toOwnedSlice(alloc);
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Bytes a Windows path component cannot contain: control characters
/// (NUL included) and `<>:"|?*`. Non-ASCII UTF-8 bytes are allowed.
fn validPathByte(c: u8) bool {
    return switch (c) {
        0...0x1F, '<', '>', ':', '"', '|', '?', '*' => false,
        else => true,
    };
}

const testing = std.testing;

fn expectWindowsPath(expected: []const u8, path: []const u8) !void {
    const result = try windowsPath(testing.allocator, path);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "windowsPath converts drive paths" {
    try expectWindowsPath("C:\\Windows", "/C:/Windows");
    try expectWindowsPath("C:\\Users\\me\\My Documents", "/C:/Users/me/My Documents");
    try expectWindowsPath("D:\\work", "/d:/work/");
    try expectWindowsPath("C:\\", "/C:");
    try expectWindowsPath("C:\\", "/C:/");
    try expectWindowsPath("C:\\a\\b", "/C:\\a\\\\b//");
    try expectWindowsPath("C:\\Users\\\u{4F60}\u{597D}", "/C:/Users/\u{4F60}\u{597D}");
}

test "windowsPath converts MSYS and Cygwin drive paths" {
    try expectWindowsPath("C:\\Users\\me", "/c/Users/me");
    try expectWindowsPath("C:\\", "/c");
    try expectWindowsPath("C:\\", "/c/");
    try expectWindowsPath("E:\\src\\gx", "/E/src/gx");
    try expectWindowsPath("C:\\Users\\me", "/cygdrive/c/Users/me");
    try expectWindowsPath("D:\\", "/cygdrive/d");
}

test "windowsPath rejects what is not an absolute drive path" {
    const invalid = [_][]const u8{
        "",
        "/",
        "C:/Windows", // no leading slash: not a URI path
        "relative/path",
        "//server/share", // UNC
        "//?/C:/Windows", // device path
        "/\\\\server\\share",
        "/home/me", // POSIX
        "/tmp",
        "/mnt/c/Users",
        "/cygdrive",
        "/cygdrive/",
        "/cygdrive/cygdrive/c",
        "/C:Users", // drive-relative
        "/1:/x",
        "/C:/a:b",
        "/C:/a|b",
        "/C:/what?",
        "/C:/a\x00b",
        "/C:/a\nb",
    };
    for (invalid) |path| {
        try testing.expectError(error.InvalidPath, windowsPath(testing.allocator, path));
    }
}

test "nativePath leaves other platforms' paths alone" {
    const path = try nativePath(testing.allocator, "/C:/Windows");
    if (comptime builtin.os.tag == .windows) {
        defer testing.allocator.free(path.?);
        try testing.expectEqualStrings("C:\\Windows", path.?);
        try testing.expectEqual(null, try nativePath(testing.allocator, "/home/me"));
    } else {
        try testing.expectEqualStrings("/C:/Windows", path.?);
    }
}

/// The steps src/termio/stream_handler.zig::reportPwd takes from an OSC 7
/// URL to the stored pwd, for testing them together. Returns null where
/// reportPwd ignores the URL.
fn reportedPwd(arena: Allocator, url: []const u8) !?[]const u8 {
    const internal_os = @import("../os/main.zig");
    const uri = internal_os.uri.parse(url, .{
        .mac_address = comptime builtin.os.tag != .macos,
        .raw_path = std.mem.startsWith(u8, url, "kitty-shell-cwd://"),
    }) catch return null;
    if (!std.mem.eql(u8, "file", uri.scheme) and
        !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme)) return null;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch |err| switch (err) {
        error.UriMissingHost => std.Io.net.HostName{ .bytes = "" },
    };
    if (!try internal_os.hostname.isLocal(host.bytes)) return null;

    // The same allocators as reportPwd: a stack fallback, used once, for
    // the decoded path and the arena for the native one.
    var stack_alloc = std.heap.stackFallback(1024, arena);
    const raw_path = try uri.path.toRawMaybeAlloc(stack_alloc.get());
    const path = try nativePath(arena, raw_path) orelse return null;
    return try arena.dupe(u8, path);
}

test "OSC 7 URLs from Windows shells become native working directories" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // GX Zsh: localhost and a percent-encoded drive path.
    try testing.expectEqualStrings(
        "C:\\Users\\me\\My Files\\\u{4F60}\u{597D}",
        (try reportedPwd(alloc, "file://localhost/C:/Users/me/My%20Files/%E4%BD%A0%E5%A5%BD")).?,
    );
    try testing.expectEqualStrings("C:\\Windows", (try reportedPwd(alloc, "file://localhost/C:/Windows")).?);

    // An empty host is the local machine; older GX Zsh releases send that
    // with Cygwin paths.
    try testing.expectEqualStrings("C:\\Windows", (try reportedPwd(alloc, "file:///C:/Windows")).?);
    try testing.expectEqualStrings("C:\\Users\\me", (try reportedPwd(alloc, "file:///cygdrive/c/Users/me")).?);

    // herdr: the upper-case computer name; any case matches.
    var name_buf: [256:0]u8 = undefined;
    var name_len: u32 = name_buf.len;
    const windows = @import("../os/main.zig").windows;
    if (windows.exp.kernel32.GetComputerNameA(&name_buf, &name_len) == windows.FALSE)
        return error.GetComputerNameFailed;
    for ([_]bool{ false, true }) |lower| {
        const name = try alloc.dupe(u8, name_buf[0..name_len]);
        if (lower) {
            for (name) |*c| c.* = std.ascii.toLower(c.*);
        }
        const url = try std.fmt.allocPrint(alloc, "file://{s}/C:/Windows/System32", .{name});
        try testing.expectEqualStrings("C:\\Windows\\System32", (try reportedPwd(alloc, url)).?);
    }

    // MSYS shells and kitty's unencoded form.
    try testing.expectEqualStrings("C:\\Users\\me", (try reportedPwd(alloc, "file://localhost/c/Users/me")).?);
    try testing.expectEqualStrings("C:\\a b", (try reportedPwd(alloc, "kitty-shell-cwd://localhost/C:/a b")).?);

    // Ignored: other hosts, other schemes, UNC and POSIX paths.
    try testing.expectEqual(null, try reportedPwd(alloc, "file://not-the-local-hostname/C:/Windows"));
    try testing.expectEqual(null, try reportedPwd(alloc, "http://localhost/C:/Windows"));
    try testing.expectEqual(null, try reportedPwd(alloc, "file://localhost//server/share"));
    try testing.expectEqual(null, try reportedPwd(alloc, "file://localhost/home/me"));
}

test {
    // src/os/main.zig does not reference these; OSC 7 relies on them.
    _ = @import("../os/hostname.zig");
}
