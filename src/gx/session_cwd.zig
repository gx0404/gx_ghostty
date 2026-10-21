//! Strict guest-domain OSC 7 capture for session restore. This parser never
//! opens a path, probes WSL, or changes the host terminal's native cwd. The
//! caller supplies an immutable launch profile and a verified local-host fact.
const std = @import("std");
pub const max_path_bytes = 4096;
pub const max_uri_bytes = max_path_bytes * 3 + 512;
pub const Error = error{ TooLong, InvalidUri, NonLocalHost, InvalidPath, InvalidUtf8 };

pub const GuestCwd = struct {
    /// Borrowed from the immutable, explicitly selected WSL launch origin.
    profile_id: []const u8,
    /// Borrowed from the supplied output buffer; copy before returning to IO.
    path: []const u8,
};

/// null means this is not a WSL launch, or OSC 7 explicitly cleared the cwd.
/// Errors must invalidate any previous captured cwd; retaining a stale path
/// after an unknown-domain update would silently restore the wrong directory.
pub fn parse(profile_id: ?[]const u8, raw_uri: []const u8, host_is_local: bool, output: *[max_path_bytes]u8) Error!?GuestCwd {
    const id = profile_id orelse return null;
    if (!std.mem.startsWith(u8, id, "wsl:") or id.len == 4) return null;
    if (raw_uri.len == 0) return null;
    if (!host_is_local) return error.NonLocalHost;
    if (raw_uri.len > max_uri_bytes) return error.TooLong;
    const raw_path = std.mem.startsWith(u8, raw_uri, "kitty-shell-cwd://");
    const authority_start: usize = if (raw_path) "kitty-shell-cwd://".len else if (std.mem.startsWith(u8, raw_uri, "file://")) "file://".len else return error.InvalidUri;
    const path_start = std.mem.indexOfScalarPos(u8, raw_uri, authority_start, '/') orelse return error.InvalidUri;
    const authority = raw_uri[authority_start..path_start];
    if (authority.len > 253) return error.InvalidUri;
    for (authority) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "@:%\\?#[]", byte) != null) return error.InvalidUri;
    }
    var count: usize = 0;
    var i = path_start;
    while (i < raw_uri.len) : (i += 1) {
        var byte = raw_uri[i];
        if (!raw_path) {
            if (byte == '?' or byte == '#') return error.InvalidUri;
            if (byte == '%') {
                if (i + 2 >= raw_uri.len) return error.InvalidUri;
                const high = std.fmt.charToDigit(raw_uri[i + 1], 16) catch return error.InvalidUri;
                const low = std.fmt.charToDigit(raw_uri[i + 2], 16) catch return error.InvalidUri;
                byte = high * 16 + low;
                i += 2;
            }
        }
        if (count == output.len) return error.TooLong;
        output[count] = byte;
        count += 1;
    }
    const path = output[0..count];
    try validatePath(path);
    return .{ .profile_id = id, .path = path };
}

fn validatePath(path: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    if (path.len == 0 or path[0] != '/' or std.mem.startsWith(u8, path, "//")) return error.InvalidPath;
    // A drive URI belongs to the host parser even when emitted in a WSL tab.
    if (path.len >= 3 and std.ascii.isAlphabetic(path[1]) and path[2] == ':') return error.InvalidPath;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\') return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

test "guest cwd requires explicit WSL provenance and verified local domain" {
    var output: [max_path_bytes]u8 = undefined;
    for ([_]?[]const u8{ null, "pwsh", "custom:wsl", "wsl:" }) |profile|
        try std.testing.expect((try parse(profile, "file:///home/me", true, &output)) == null);
    try std.testing.expectError(error.NonLocalHost, parse("wsl:Ubuntu", "file://unknown-guest/home/me", false, &output));
    const local = (try parse("wsl:Ubuntu", "file://verified-host/home/me", true, &output)).?;
    try std.testing.expectEqualStrings("wsl:Ubuntu", local.profile_id);
    try std.testing.expectEqualStrings("/home/me", local.path);
    try std.testing.expect((try parse("wsl:Ubuntu", "", true, &output)) == null);
}

test "guest cwd decodes file URI once but preserves kitty raw path" {
    var output: [max_path_bytes]u8 = undefined;
    const escaped = (try parse("wsl:Ubuntu", "file://localhost/home/%E4%B8%AD%E6%96%87%20%252e", true, &output)).?;
    try std.testing.expectEqualStrings("/home/中文 %2e", escaped.path);
    const raw = (try parse("wsl:Ubuntu", "kitty-shell-cwd:///home/a%20b?#file", true, &output)).?;
    try std.testing.expectEqualStrings("/home/a%20b?#file", raw.path);
    try std.testing.expectEqualStrings("/", (try parse("wsl:Ubuntu", "file:///", true, &output)).?.path);
}

test "guest cwd rejects traversal device paths credentials ports and malformed Unicode" {
    var output: [max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "file:///home/../secret", "file:///home/%2e%2e/secret", "file:///home/./x", "file:////server/share", "file:///C:/work", "file:///home/%5cdevice", "file:///home/%00bad", "file:///home/%0Abad" }) |uri|
        try std.testing.expectError(error.InvalidPath, parse("wsl:Ubuntu", uri, true, &output));
    for ([_][]const u8{ "http://localhost/path", "file://user@localhost/path", "file://localhost:80/path", "file://local%68ost/path", "file:///path?query", "file:///path#fragment", "file:///path%2", "file:///path%XZ" }) |uri|
        try std.testing.expectError(error.InvalidUri, parse("wsl:Ubuntu", uri, true, &output));
    try std.testing.expectError(error.InvalidUtf8, parse("wsl:Ubuntu", "file:///home/%ff", true, &output));
}

test "guest cwd bounds decoded bytes without allocation on every platform" {
    var output: [max_path_bytes]u8 = undefined;
    const exact = "file:///" ++ std.mem.asBytes(&@as([(max_path_bytes - 1)]["a".len]u8, @splat("a".*)));
    try std.testing.expectEqual(@as(usize, max_path_bytes), (try parse("wsl:Ubuntu", exact, true, &output)).?.path.len);
    try std.testing.expectError(error.TooLong, parse("wsl:Ubuntu", exact ++ "a", true, &output));
    const oversized = "file:///" ++ std.mem.asBytes(&@as([max_uri_bytes]["a".len]u8, @splat("a".*)));
    try std.testing.expectError(error.TooLong, parse("wsl:Ubuntu", oversized, true, &output));
}
