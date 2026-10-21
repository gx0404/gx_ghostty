//! Pure decisions over identity facts obtained from the native pipe/token APIs.
//! Never populate verified facts or isolation values from an unauthenticated
//! wire claim. Hashes partition endpoints; they do not replace OS authentication.
const std = @import("std");

pub const Digest = [32]u8;
pub const Process = struct { pid: u32, birth: u64 };
pub const Integrity = enum { low, medium, high, system };
pub const Identity = struct {
    process: Process,
    sid: Digest,
    logon_id: u64,
    /// Native TOKEN_LINKED_TOKEN fact only. Ordinary IPC never uses this to
    /// relax its same-logon check, and handshakes do not carry this field.
    linked_logon_id: ?u64 = null,
    session_id: u32,
    integrity: Integrity,
    elevated: bool,
};
pub const Isolation = struct {
    config_root: Digest,
    build: Digest,
    class: Digest,
    install: Digest,
};

pub const Error = error{
    RemotePeer,
    UnverifiedPeer,
    ProcessChanged,
    DifferentUser,
    DifferentLogon,
    DifferentSession,
    DifferentElevation,
    DifferentIsolation,
    InvalidEpoch,
    EpochMismatch,
};

/// Run on BOTH ends after native verification of the actual connected process.
/// expected_process is the PID/birth obtained from the secured endpoint/handshake;
/// actual_peer is independently re-read from the pipe and process token.
pub fn authenticate(
    local: Identity,
    actual_peer: Identity,
    expected_process: Process,
    local_isolation: Isolation,
    peer_isolation: Isolation,
    is_remote: bool,
) Error!void {
    if (is_remote) return error.RemotePeer;
    if (local.process.pid == 0 or local.process.birth == 0 or
        actual_peer.process.pid == 0 or actual_peer.process.birth == 0)
        return error.UnverifiedPeer;
    if (!std.meta.eql(actual_peer.process, expected_process)) return error.ProcessChanged;
    if (!std.mem.eql(u8, &local.sid, &actual_peer.sid)) return error.DifferentUser;
    if (local.logon_id != actual_peer.logon_id) return error.DifferentLogon;
    if (local.session_id != actual_peer.session_id) return error.DifferentSession;
    if (local.integrity != actual_peer.integrity or local.elevated != actual_peer.elevated) return error.DifferentElevation;
    if (!std.meta.eql(local_isolation, peer_isolation)) return error.DifferentIsolation;
}

/// Epochs must be bound to the already authenticated connection, not accepted
/// anew on every frame. The native layer must reject a changed epoch on retry.
pub fn checkEpochs(bound_sender: u128, bound_host: u128, sender: u128, host: u128) Error!void {
    if (bound_sender == 0 or bound_host == 0 or sender == 0 or host == 0) return error.InvalidEpoch;
    if (sender != bound_sender or host != bound_host) return error.EpochMismatch;
}

pub const Launch = struct {
    explicit_standalone: bool = false,
    execute_command: bool = false,
    /// Until a typed transfer exists, preserve CLI semantics by launching locally.
    has_unforwarded_overrides: bool = false,
};
pub const LaunchMode = enum { forward_or_elect, independent };

pub fn launchMode(launch: Launch) LaunchMode {
    return if (launch.explicit_standalone or launch.execute_command or launch.has_unforwarded_overrides)
        .independent
    else
        .forward_or_elect;
}

test "gx.ipc.policy authenticate process birth and all isolation dimensions" {
    const identity: Identity = .{
        .process = .{ .pid = 7, .birth = 8 },
        .sid = @as([32]u8, @splat(1)),
        .logon_id = 9,
        .session_id = 10,
        .integrity = .medium,
        .elevated = false,
    };
    const isolation: Isolation = .{
        .config_root = @as([32]u8, @splat(2)),
        .build = @as([32]u8, @splat(3)),
        .class = @as([32]u8, @splat(4)),
        .install = @as([32]u8, @splat(5)),
    };
    try authenticate(identity, identity, identity.process, isolation, isolation, false);
    try std.testing.expectError(error.RemotePeer, authenticate(identity, identity, identity.process, isolation, isolation, true));
    var peer = identity;
    peer.process.birth += 1;
    try std.testing.expectError(error.ProcessChanged, authenticate(identity, peer, identity.process, isolation, isolation, false));
    peer = identity;
    peer.sid[0] += 1;
    try std.testing.expectError(error.DifferentUser, authenticate(identity, peer, identity.process, isolation, isolation, false));
    peer = identity;
    peer.logon_id += 1;
    try std.testing.expectError(error.DifferentLogon, authenticate(identity, peer, identity.process, isolation, isolation, false));
    peer = identity;
    peer.session_id += 1;
    try std.testing.expectError(error.DifferentSession, authenticate(identity, peer, identity.process, isolation, isolation, false));
    peer = identity;
    peer.integrity = .high;
    try std.testing.expectError(error.DifferentElevation, authenticate(identity, peer, identity.process, isolation, isolation, false));
    inline for (@typeInfo(Isolation).@"struct".field_names) |field| {
        var other = isolation;
        @field(other, field)[0] += 1;
        try std.testing.expectError(error.DifferentIsolation, authenticate(identity, identity, identity.process, isolation, other, false));
    }
    try std.testing.expectError(error.EpochMismatch, checkEpochs(1, 2, 1, 3));
    try std.testing.expectError(error.InvalidEpoch, checkEpochs(0, 2, 0, 2));
    try checkEpochs(1, 2, 1, 2);
}

test "gx.ipc.policy command overrides and standalone cannot be silently forwarded" {
    try std.testing.expectEqual(LaunchMode.forward_or_elect, launchMode(.{}));
    try std.testing.expectEqual(LaunchMode.independent, launchMode(.{ .execute_command = true }));
    try std.testing.expectEqual(LaunchMode.independent, launchMode(.{ .explicit_standalone = true }));
    try std.testing.expectEqual(LaunchMode.independent, launchMode(.{ .has_unforwarded_overrides = true }));
}

test "gx.ipc.policy linked token facts never relax ordinary logon authentication" {
    const local: Identity = .{ .process = .{ .pid = 1, .birth = 2 }, .sid = @splat(3), .logon_id = 4, .linked_logon_id = 5, .session_id = 6, .integrity = .medium, .elevated = false };
    var peer = local;
    peer.process = .{ .pid = 7, .birth = 8 };
    peer.logon_id = 5;
    peer.linked_logon_id = 4;
    const isolation: Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    try std.testing.expectError(error.DifferentLogon, authenticate(local, peer, peer.process, isolation, isolation, false));
    peer.integrity = .high;
    peer.elevated = true;
    try std.testing.expectError(error.DifferentLogon, authenticate(local, peer, peer.process, isolation, isolation, false));
    try std.testing.expectError(error.DifferentLogon, authenticate(peer, local, local.process, isolation, isolation, false));
}
