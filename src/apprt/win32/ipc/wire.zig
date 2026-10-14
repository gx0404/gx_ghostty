//! Fixed handshake and authenticated endpoint namespace for the native pipe.
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
const policy = security.policy;
pub const protocol = @import("../../../gx/ipc/protocol.zig");
pub const hello_size = 164;

pub const Endpoint = struct {
    name: [128:0]u16,
    isolation: policy.Isolation,

    pub fn init(isolation: policy.Isolation, identity: policy.Identity) !Endpoint {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&identity.sid);
        var numbers: [14]u8 = undefined;
        std.mem.writeInt(u64, numbers[0..8], identity.logon_id, .little);
        std.mem.writeInt(u32, numbers[8..12], identity.session_id, .little);
        numbers[12] = @intFromEnum(identity.integrity);
        numbers[13] = @intFromBool(identity.elevated);
        hash.update(&numbers);
        inline for (std.meta.fields(policy.Isolation)) |field| hash.update(&@field(isolation, field.name));
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var ascii: [120]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "\\\\.\\pipe\\ghostty-gx-v1-{s}", .{std.fmt.bytesToHex(digest, .lower)});
        var result: Endpoint = .{ .name = @splat(0), .isolation = isolation };
        _ = try std.unicode.utf8ToUtf16Le(&result.name, text);
        return result;
    }
};

pub fn hello(buffer: *[hello_size]u8, epoch: u128, identity: policy.Identity, isolation: policy.Isolation) void {
    @memset(buffer, 0);
    @memcpy(buffer[0..4], "GXIH");
    std.mem.writeInt(u16, buffer[4..6], protocol.version, .little);
    std.mem.writeInt(u128, buffer[8..24], epoch, .little);
    std.mem.writeInt(u32, buffer[24..28], identity.process.pid, .little);
    std.mem.writeInt(u64, buffer[28..36], identity.process.birth, .little);
    inline for (std.meta.fields(policy.Isolation), 0..) |field, i|
        @memcpy(buffer[36 + i * 32 ..][0..32], &@field(isolation, field.name));
}

pub fn verifyHello(buffer: *const [hello_size]u8, local: security.Facts, peer: security.Facts, isolation: policy.Isolation) !u128 {
    if (!std.mem.eql(u8, buffer[0..4], "GXIH") or buffer[6] != 0 or buffer[7] != 0) return error.InvalidHandshake;
    if (std.mem.readInt(u16, buffer[4..6], .little) != protocol.version) return error.UnsupportedVersion;
    const epoch = std.mem.readInt(u128, buffer[8..24], .little);
    if (epoch == 0) return error.InvalidEpoch;
    const claimed: policy.Process = .{
        .pid = std.mem.readInt(u32, buffer[24..28], .little),
        .birth = std.mem.readInt(u64, buffer[28..36], .little),
    };
    var peer_isolation: policy.Isolation = undefined;
    inline for (std.meta.fields(policy.Isolation), 0..) |field, i|
        @memcpy(&@field(peer_isolation, field.name), buffer[36 + i * 32 ..][0..32]);
    try policy.authenticate(local.identity, peer.identity, claimed, isolation, peer_isolation, false);
    try security.verifyImage(local, peer);
    return epoch;
}

pub fn readFrame(pipe: n.HANDLE, buffer: *[protocol.max_frame_size]u8, stop: ?n.HANDLE, deadline: n.Deadline) !protocol.Frame {
    return protocol.decode(try n.readMessage(pipe, buffer, stop, deadline));
}

test "apprt.win32.ipc.wire namespace excludes process but includes isolation" {
    const isolation: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    const identity: policy.Identity = .{ .process = .{ .pid = 1, .birth = 2 }, .sid = @splat(5), .logon_id = 6, .session_id = 7, .integrity = .medium, .elevated = false };
    const first = try Endpoint.init(isolation, identity);
    var other = identity;
    other.process.pid = 2;
    try std.testing.expectEqualDeep(first, try Endpoint.init(isolation, other));
    other.elevated = true;
    try std.testing.expect(!std.mem.eql(u16, &first.name, &(try Endpoint.init(isolation, other)).name));
    inline for (std.meta.fields(policy.Isolation)) |field| {
        var changed = isolation;
        @field(changed, field.name)[0] += 1;
        try std.testing.expect(!std.mem.eql(u16, &first.name, &(try Endpoint.init(changed, identity)).name));
    }
}

test "apprt.win32.ipc.wire handshake claims must match actual process birth" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const local = try security.inspect(n.GetCurrentProcessId());
    defer local.deinit();
    const isolation: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    var buffer: [hello_size]u8 = undefined;
    hello(&buffer, 123, local.identity, isolation);
    try std.testing.expectEqual(@as(u128, 123), try verifyHello(&buffer, local, local, isolation));
    buffer[28] ^= 1;
    try std.testing.expectError(error.ProcessChanged, verifyHello(&buffer, local, local, isolation));
    buffer[28] ^= 1;
    buffer[36] ^= 1;
    try std.testing.expectError(error.DifferentIsolation, verifyHello(&buffer, local, local, isolation));
    buffer[36] ^= 1;
    buffer[6] = 1;
    try std.testing.expectError(error.InvalidHandshake, verifyHello(&buffer, local, local, isolation));
}
