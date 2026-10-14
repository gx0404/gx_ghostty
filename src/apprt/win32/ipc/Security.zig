//! Native process/token facts and protected pipe DACLs. Ordinary IPC keeps its
//! user ACL; the drop-only endpoint admits actual local/linked logon SIDs.
const std = @import("std");
const n = @import("native.zig");
pub const policy = @import("../../../gx/ipc/policy.zig");
const Digest = policy.Digest;

extern "advapi32" fn OpenProcessToken(n.HANDLE, u32, *n.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(n.HANDLE, u32, *anyopaque, u32, *u32) callconv(.winapi) i32;
extern "advapi32" fn IsValidSid(*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn GetLengthSid(*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn GetSidSubAuthorityCount(*anyopaque) callconv(.winapi) *u8;
extern "advapi32" fn GetSidSubAuthority(*anyopaque, u32) callconv(.winapi) *u32;
extern "advapi32" fn ConvertSidToStringSidW(*anyopaque, *?[*:0]u16) callconv(.winapi) i32;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) i32;

pub const Facts = struct {
    identity: policy.Identity,
    process: n.HANDLE,

    pub fn deinit(self: Facts) void {
        _ = n.CloseHandle(self.process);
    }
};

fn info(token: n.HANDLE, class: u32, buffer: []align(8) u8) ![]align(8) u8 {
    var size: u32 = 0;
    if (GetTokenInformation(token, class, buffer.ptr, @intCast(buffer.len), &size) == 0 or size > buffer.len)
        return error.TokenInformationFailed;
    return buffer[0..size];
}

fn tokenSid(buffer: []align(8) u8) !*anyopaque {
    if (buffer.len < @sizeOf(usize)) return error.InvalidToken;
    const sid = @as(*const ?*anyopaque, @ptrCast(buffer.ptr)).* orelse return error.InvalidToken;
    if (IsValidSid(sid) == 0) return error.InvalidToken;
    return sid;
}

/// Reads one token without following its linked token. This is used for both
/// the process token and the OS-provided linked handle, never handshake data.
fn tokenIdentity(token: n.HANDLE, process: policy.Process) !policy.Identity {
    var buffer: [4096]u8 align(8) = undefined;
    const sid = try tokenSid(try info(token, 1, &buffer));
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(@as([*]const u8, @ptrCast(sid))[0..GetLengthSid(sid)], &digest, .{});
    const stats = try info(token, 10, &buffer);
    if (stats.len < 16) return error.InvalidToken;
    const logon = std.mem.readInt(u64, stats[8..16], .little);
    const session = try info(token, 12, buffer[0..4]);
    if (session.len < 4) return error.InvalidToken;
    const session_id = std.mem.readInt(u32, session[0..4], .little);
    const elevation = try info(token, 20, buffer[0..4]);
    if (elevation.len < 4) return error.InvalidToken;
    const elevated = std.mem.readInt(u32, elevation[0..4], .little) != 0;
    const label = try tokenSid(try info(token, 25, &buffer));
    const count = GetSidSubAuthorityCount(label).*;
    if (count == 0) return error.InvalidToken;
    const level = GetSidSubAuthority(label, count - 1).*;
    return .{
        .process = process,
        .sid = digest,
        .logon_id = logon,
        .session_id = session_id,
        .integrity = if (level < 0x2000) .low else if (level < 0x3000) .medium else if (level < 0x4000) .high else .system,
        .elevated = elevated,
    };
}

fn elevationType(token: n.HANDLE) !u32 {
    var buffer: [8]u8 align(8) = undefined;
    const result = try info(token, 18, buffer[0..4]);
    if (result.len < 4) return error.InvalidToken;
    return std.mem.readInt(u32, result[0..4], .little);
}

const LinkedToken = struct { handle: n.HANDLE, identity: policy.Identity };

fn linkedToken(token: n.HANDLE, owner: policy.Identity) !?LinkedToken {
    const kind = try elevationType(token);
    if (kind == 1) return null; // TokenElevationTypeDefault has no split pair.
    if (kind != 2 and kind != 3) return error.InvalidToken;
    var buffer: [8]u8 align(8) = undefined;
    const result = info(token, 19, &buffer) catch return null;
    if (result.len < @sizeOf(n.HANDLE)) return error.InvalidToken;
    const handle = @as(*const ?n.HANDLE, @ptrCast(result.ptr)).* orelse return error.InvalidToken;
    var retained = false;
    defer if (!retained) {
        _ = n.CloseHandle(handle);
    };
    const linked = tokenIdentity(handle, owner.process) catch return null;
    const linked_kind = elevationType(handle) catch return null;
    const opposite = (kind == 2 and linked_kind == 3 and owner.integrity == .high and owner.elevated and linked.integrity == .medium and !linked.elevated) or
        (kind == 3 and linked_kind == 2 and owner.integrity == .medium and !owner.elevated and linked.integrity == .high and linked.elevated);
    if (!opposite or owner.logon_id == 0 or linked.logon_id == 0 or owner.logon_id == linked.logon_id or
        owner.session_id != linked.session_id or !std.mem.eql(u8, &owner.sid, &linked.sid)) return null;
    retained = true;
    return .{ .handle = handle, .identity = linked };
}

pub fn inspect(pid: u32) !Facts {
    const process = n.OpenProcess(0x00101000, 0, pid) orelse return error.OpenProcessFailed;
    errdefer _ = n.CloseHandle(process);
    if (n.WaitForSingleObject(process, 0) != 258) return error.ProcessExited;
    var birth: u64 = 0;
    var unused: u64 = 0;
    if (n.GetProcessTimes(process, &birth, &unused, &unused, &unused) == 0) return error.ProcessTimesFailed;
    var token: n.HANDLE = undefined;
    if (OpenProcessToken(process, 8, &token) == 0) return error.OpenTokenFailed;
    defer _ = n.CloseHandle(token);
    var identity = try tokenIdentity(token, .{ .pid = pid, .birth = birth });
    if (try linkedToken(token, identity)) |linked| {
        defer _ = n.CloseHandle(linked.handle);
        identity.linked_logon_id = linked.identity.logon_id;
    }
    return .{ .process = process, .identity = identity };
}

/// The expected executable is our own image. An endpoint at the right name is
/// insufficient; both sides independently inspect the process behind the pipe.
pub fn verifyImage(local: Facts, peer: Facts) !void {
    var local_path: [32768]u16 = undefined;
    var peer_path: [32768]u16 = undefined;
    var local_size: u32 = local_path.len;
    var peer_size: u32 = peer_path.len;
    if (n.QueryFullProcessImageNameW(local.process, 0, &local_path, &local_size) == 0 or
        n.QueryFullProcessImageNameW(peer.process, 0, &peer_path, &peer_size) == 0)
        return error.ImageQueryFailed;
    if (n.CompareStringOrdinal(&local_path, @intCast(local_size), &peer_path, @intCast(peer_size), 1) != 2)
        return error.DifferentImage;
}

pub fn pipePeer(pipe: n.HANDLE, server_side: bool) !Facts {
    var pid: u32 = 0;
    const ok = if (server_side) n.GetNamedPipeClientProcessId(pipe, &pid) else n.GetNamedPipeServerProcessId(pipe, &pid);
    if (ok == 0 or pid == 0) return error.PeerPidFailed;
    return inspect(pid);
}

fn logonSid(token: n.HANDLE, buffer: []align(8) u8) !*anyopaque {
    const SidAndAttributes = extern struct { sid: ?*anyopaque, attributes: u32 };
    const Groups = extern struct { count: u32, groups: [1]SidAndAttributes };
    const result = try info(token, 28, buffer); // TokenLogonSid, not an inferred LUID SID.
    if (result.len < @sizeOf(Groups)) return error.InvalidToken;
    const groups: *const Groups = @ptrCast(result.ptr);
    if (groups.count != 1 or groups.groups[0].attributes & 0xc0000000 != 0xc0000000) return error.InvalidToken;
    const sid = groups.groups[0].sid orelse return error.InvalidToken;
    if (IsValidSid(sid) == 0) return error.InvalidToken;
    return sid;
}

fn dropSddl(buffer: *[512:0]u16, local: []const u16, linked: ?[]const u16) ![:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P");
    const ace = std.unicode.utf8ToUtf16LeStringLiteral("(A;;GA;;;");
    @memcpy(buffer[0..prefix.len], prefix);
    var len: usize = prefix.len;
    const sids = [_]?[]const u16{ local, linked };
    for (sids, 0..) |sid_, index| if (sid_) |sid| {
        if (index != 0 and std.mem.eql(u16, local, sid)) continue;
        if (sid.len == 0 or len + ace.len + sid.len + 1 >= buffer.len) return error.SidTooLong;
        @memcpy(buffer[len..][0..ace.len], ace);
        len += ace.len;
        @memcpy(buffer[len..][0..sid.len], sid);
        len += sid.len;
        buffer[len] = ')';
        len += 1;
    };
    buffer[len] = 0;
    return buffer[0..len :0];
}

pub const Descriptor = struct {
    memory: *anyopaque,
    /// Only the dedicated drop broker uses this ACL. Its two principals come
    /// from TokenLogonSid on actual token handles; no user/world/admin wildcard
    /// is added. A missing linked token grants only the current logon.
    pub fn initDrop() !Descriptor {
        const local = try inspect(n.GetCurrentProcessId());
        defer local.deinit();
        var token: n.HANDLE = undefined;
        if (OpenProcessToken(local.process, 8, &token) == 0) return error.OpenTokenFailed;
        defer _ = n.CloseHandle(token);
        const owner = try tokenIdentity(token, local.identity.process);
        const linked = try linkedToken(token, owner);
        defer if (linked) |value| {
            _ = n.CloseHandle(value.handle);
        };
        var buffer: [4096]u8 align(8) = undefined;
        var local_text: ?[*:0]u16 = null;
        if (ConvertSidToStringSidW(try logonSid(token, &buffer), &local_text) == 0) return error.SidConversionFailed;
        defer _ = n.LocalFree(@ptrCast(local_text.?));
        var linked_text: ?[*:0]u16 = null;
        defer if (linked_text) |value| {
            _ = n.LocalFree(@ptrCast(value));
        };
        if (linked) |value| {
            if (ConvertSidToStringSidW(try logonSid(value.handle, &buffer), &linked_text) == 0) return error.SidConversionFailed;
        }
        var sddl_buffer: [512:0]u16 = undefined;
        const sddl = try dropSddl(&sddl_buffer, std.mem.span(local_text.?), if (linked_text) |value| std.mem.span(value) else null);
        var memory: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.ptr, 1, &memory, null) == 0) return error.DescriptorFailed;
        return .{ .memory = memory orelse return error.DescriptorFailed };
    }

    pub fn init() !Descriptor {
        const local = try inspect(n.GetCurrentProcessId());
        defer local.deinit();
        var token: n.HANDLE = undefined;
        if (OpenProcessToken(local.process, 8, &token) == 0) return error.OpenTokenFailed;
        defer _ = n.CloseHandle(token);
        var buffer: [4096]u8 align(8) = undefined;
        const sid = try tokenSid(try info(token, 1, &buffer));
        var sid_text: ?[*:0]u16 = null;
        if (ConvertSidToStringSidW(sid, &sid_text) == 0) return error.SidConversionFailed;
        defer _ = n.LocalFree(@ptrCast(sid_text.?));
        const text = std.mem.span(sid_text.?);
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
        var sddl: [256:0]u16 = @splat(0);
        if (prefix.len + text.len + 1 >= sddl.len) return error.SidTooLong;
        @memcpy(sddl[0..prefix.len], prefix);
        @memcpy(sddl[prefix.len..][0..text.len], text);
        sddl[prefix.len + text.len] = ')';
        var memory: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(&sddl, 1, &memory, null) == 0)
            return error.DescriptorFailed;
        return .{ .memory = memory orelse return error.DescriptorFailed };
    }
    pub fn attributes(self: Descriptor) n.SA {
        return .{ .nLength = @sizeOf(n.SA), .lpSecurityDescriptor = self.memory, .bInheritHandle = .FALSE };
    }
    pub fn deinit(self: Descriptor) void {
        _ = n.LocalFree(self.memory);
    }
};

test "apprt.win32.ipc.Security reads real own token and process birth" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const facts = try inspect(n.GetCurrentProcessId());
    defer facts.deinit();
    try std.testing.expect(facts.identity.process.birth != 0);
    try verifyImage(facts, facts);
    const descriptor = try Descriptor.init();
    defer descriptor.deinit();
    const drop_descriptor = try Descriptor.initDrop();
    defer drop_descriptor.deinit();
}

test "apprt.win32.ipc.Security drop ACL contains only exact native logon principals" {
    const local = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-5-10-20");
    const linked = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-5-10-30");
    var buffer: [512:0]u16 = undefined;
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;S-1-5-5-10-20)(A;;GA;;;S-1-5-5-10-30)"), try dropSddl(&buffer, local, linked));
    const single = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;S-1-5-5-10-20)");
    try std.testing.expectEqualSlices(u16, single, try dropSddl(&buffer, local, null));
    try std.testing.expectEqualSlices(u16, single, try dropSddl(&buffer, local, local));
}
