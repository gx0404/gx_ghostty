const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`).
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // fork(gx): GX-0008 begin: an empty host (file:///path) is the local machine
    if (hostname.len == 0) return true;
    // fork(gx): GX-0008 end

    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    switch (builtin.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE) return false;
            const ourHostname = buf[0..nSize];
            // fork(gx): GX-0008 Windows host names are case-insensitive; also accept the DNS host name
            return std.ascii.eqlIgnoreCase(hostname, ourHostname) or isLocalDnsHostname(hostname);
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return std.mem.eql(u8, hostname, ourHostname);
        },
    }
}

// fork(gx): GX-0008 begin: the DNS host name, which MSYS2 `hostname` prints
/// GetComputerNameA returns the NetBIOS name, which is upper-cased and cut
/// to 15 characters; the DNS host name keeps the configured spelling.
fn isLocalDnsHostname(hostname: []const u8) bool {
    const windows = @import("windows.zig");
    var buf: [256:0]u8 = undefined;
    var size: windows.DWORD = buf.len;
    if (GetComputerNameExA(ComputerNameDnsHostname, &buf, &size) == windows.FALSE) return false;
    return std.ascii.eqlIgnoreCase(hostname, buf[0..size]);
}

const ComputerNameDnsHostname: c_int = 1;
extern "kernel32" fn GetComputerNameExA(
    NameType: c_int,
    lpBuffer: [*]u8,
    nSize: *u32,
) callconv(.winapi) std.os.windows.BOOL;
// fork(gx): GX-0008 end

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}

test "isLocal returns true when hostname is local" {
    switch (builtin.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
                return error.GetComputerNameFailed;
            const localHostname = buf[0..nSize];
            try std.testing.expect(try isLocal(localHostname));
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const localHostname = try posix.gethostname(&buf);
            try std.testing.expect(try isLocal(localHostname));
        },
    }
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}

// fork(gx): GX-0008 begin: empty hosts and Windows host name case
test "isLocal returns true for an empty hostname" {
    try std.testing.expect(try isLocal(""));
}

test "isLocal ignores case on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const windows = @import("windows.zig");
    var buf: [256:0]u8 = undefined;
    var nSize: windows.DWORD = buf.len;
    if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
        return error.GetComputerNameFailed;
    const lower = buf[0..nSize];
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    try std.testing.expect(try isLocal(lower));

    var dns_buf: [256:0]u8 = undefined;
    var dns_size: u32 = dns_buf.len;
    if (GetComputerNameExA(ComputerNameDnsHostname, &dns_buf, &dns_size) == windows.FALSE)
        return error.GetComputerNameFailed;
    try std.testing.expect(try isLocal(dns_buf[0..dns_size]));
}
// fork(gx): GX-0008 end
