//! Drop-only cross-integrity contract. No commands, environment, clipboard
//! reads or generic action tags exist here. Connection identities are native
//! facts, never claims copied from payloads. All queue calls require one owner
//! lock; GUI preview/paste callbacks must execute after releasing that lock.
const std = @import("std");
const refs = @import("../ui_ref.zig");
const policy = @import("policy.zig");
pub const max_bytes = 1024 * 1024;
pub const max_files = 256;
pub const header_bytes = 40;
pub const max_frame_bytes = max_bytes + max_files * 4 + header_bytes;
pub const max_tickets = 32;
pub const max_pending = 8;
pub const lifetime_ms = 30_000;
pub const Error = error{ InvalidFrame, InvalidData, TooLarge, UnauthorizedPeer, InvalidTarget, InvalidTicket, Expired, Full, Busy, Conflict, NotPreviewing, NotPasting, Closing };
pub const Outcome = enum(u8) { pasted = 1, cancelled = 2, rejected = 3, target_gone = 4, expired = 5, paste_failed = 6 };
pub const Binding = struct { process: policy.Process, epoch: u128 };
pub const Key = struct { source: Binding, request: u64 };
pub const Challenge = struct { nonce: u128, target: refs.Attachment, expires_ms: u64 };
pub const Kind = enum(u16) { text = 1, files = 2 };
pub const Payload = union(Kind) { text: []const u8, files: []const []const u8 };

pub const Decoded = struct {
    nonce: u128,
    request: u64,
    kind: Kind,
    text: []const u8 = "",
    paths: [max_files][]const u8 = undefined,
    count: usize = 0,
    pub fn payload(self: *const Decoded) Payload {
        return switch (self.kind) {
            .text => .{ .text = self.text },
            .files => .{ .files = self.paths[0..self.count] },
        };
    }
};

fn validText(value: []const u8) Error!void {
    if (value.len == 0 or value.len > max_bytes or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidData;
}
fn validPath(value: []const u8) Error!void {
    try validText(value);
    if (value.len > 32767 * 4) return error.TooLarge;
    for (value) |byte| if (byte < 32 or byte == 127 or byte == '"') return error.InvalidData;
    const drive = value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and (value[2] == '/' or value[2] == '\\');
    const unc = value.len > 4 and std.mem.startsWith(u8, value, "\\\\") and !std.mem.startsWith(u8, value, "\\\\?\\") and !std.mem.startsWith(u8, value, "\\\\.\\");
    if (!drive and !unc) return error.InvalidData;
}

pub fn encode(allocator: std.mem.Allocator, request: u64, nonce: u128, payload: Payload) ![]u8 {
    if (request == 0 or nonce == 0) return error.InvalidTicket;
    var size: usize = header_bytes;
    var count: usize = 0;
    switch (payload) {
        .text => |value| {
            try validText(value);
            size += value.len;
        },
        .files => |paths| {
            if (paths.len == 0 or paths.len > max_files) return error.TooLarge;
            count = paths.len;
            var total: usize = 0;
            for (paths) |path| {
                try validPath(path);
                total += path.len;
            }
            if (total > max_bytes) return error.TooLarge;
            size += total + paths.len * 4;
        },
    }
    const bytes = try allocator.alloc(u8, size);
    @memcpy(bytes[0..4], "GXDP");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[6..8], @backingInt(payload), .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(size), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(count), .little);
    std.mem.writeInt(u64, bytes[16..24], request, .little);
    std.mem.writeInt(u128, bytes[24..40], nonce, .little);
    var offset: usize = header_bytes;
    switch (payload) {
        .text => |value| @memcpy(bytes[offset..], value),
        .files => |paths| for (paths) |path| {
            std.mem.writeInt(u32, bytes[offset..][0..4], @intCast(path.len), .little);
            offset += 4;
            @memcpy(bytes[offset..][0..path.len], path);
            offset += path.len;
        },
    }
    return bytes;
}

pub fn decode(bytes: []const u8) Error!Decoded {
    if (bytes.len < header_bytes or bytes.len > max_frame_bytes or !std.mem.eql(u8, bytes[0..4], "GXDP") or
        std.mem.readInt(u16, bytes[4..6], .little) != 1 or std.mem.readInt(u32, bytes[8..12], .little) != bytes.len) return error.InvalidFrame;
    const kind = std.enums.fromInt(Kind, std.mem.readInt(u16, bytes[6..8], .little)) orelse return error.InvalidFrame;
    var result: Decoded = .{ .kind = kind, .request = std.mem.readInt(u64, bytes[16..24], .little), .nonce = std.mem.readInt(u128, bytes[24..40], .little) };
    if (result.request == 0 or result.nonce == 0) return error.InvalidTicket;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    switch (kind) {
        .text => {
            if (count != 0) return error.InvalidFrame;
            result.text = bytes[header_bytes..];
            try validText(result.text);
        },
        .files => {
            if (count == 0 or count > max_files) return error.TooLarge;
            var offset: usize = header_bytes;
            var total: usize = 0;
            for (0..count) |index| {
                if (bytes.len - offset < 4) return error.InvalidFrame;
                const length = std.mem.readInt(u32, bytes[offset..][0..4], .little);
                offset += 4;
                if (length > bytes.len - offset) return error.InvalidFrame;
                const path = bytes[offset..][0..length];
                try validPath(path);
                result.paths[index] = path;
                offset += length;
                total += length;
            }
            if (offset != bytes.len or total > max_bytes) return error.InvalidFrame;
            result.count = count;
        },
    }
    return result;
}

/// Permit medium/high crossing ONLY for a native, mutually linked split pair.
/// Same-level peers retain ordinary logon isolation; no wire claim supplies
/// either linked ID. All remaining identity/domain checks are unchanged.
pub fn authenticate(local: policy.Identity, peer: policy.Identity, expected: policy.Process, local_domain: policy.Isolation, peer_domain: policy.Isolation) !void {
    if ((local.integrity != .medium and local.integrity != .high) or (peer.integrity != .medium and peer.integrity != .high)) return error.UnauthorizedPeer;
    const crossing = local.integrity != peer.integrity or local.elevated != peer.elevated;
    const opposite_levels = (local.integrity == .medium and !local.elevated and peer.integrity == .high and peer.elevated) or
        (local.integrity == .high and local.elevated and peer.integrity == .medium and !peer.elevated);
    const linked_pair = opposite_levels and local.logon_id != 0 and peer.logon_id != 0 and local.logon_id != peer.logon_id and
        local.linked_logon_id != null and peer.linked_logon_id != null and
        local.linked_logon_id.? == peer.logon_id and peer.linked_logon_id.? == local.logon_id;
    var normalized = peer;
    normalized.integrity = local.integrity;
    normalized.elevated = local.elevated;
    if (linked_pair) normalized.logon_id = local.logon_id;
    try policy.authenticate(local, normalized, expected, local_domain, peer_domain, false);
    if (crossing and !linked_pair) return error.UnauthorizedPeer;
}

pub const Phase = enum { challenged, queued, preview, pasting, complete };
pub const Work = struct { key: Key, target: refs.Attachment, decoded: Decoded };
pub const Status = union(enum) { pending: Phase, complete: Outcome };
pub const Transactions = struct {
    allocator: std.mem.Allocator,
    host_epoch: u128,
    entries: [max_tickets]?Entry = @splat(null),
    closing: bool = false,
    const Entry = struct { key: Key, challenge: Challenge, phase: Phase = .challenged, bytes: ?[]u8 = null, hash: [32]u8 = @splat(0), outcome: ?Outcome = null };

    pub fn init(allocator: std.mem.Allocator, host_epoch: u128) Error!Transactions {
        if (host_epoch == 0) return error.InvalidTarget;
        return .{ .allocator = allocator, .host_epoch = host_epoch };
    }
    pub fn deinit(self: *Transactions) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            std.debug.assert(entry.phase != .preview and entry.phase != .pasting);
            if (entry.bytes) |bytes| self.allocator.free(bytes);
            slot.* = null;
        };
    }
    pub fn prepare(self: *Transactions, key: Key, target: refs.Attachment, nonce: u128, now: u64) Error!Challenge {
        if (self.closing) return error.Closing;
        if (key.source.epoch == 0 or key.source.process.pid == 0 or key.source.process.birth == 0 or key.request == 0 or nonce == 0) return error.InvalidTicket;
        if (self.find(key)) |entry| return entry.challenge;
        if (!target.isValid() or target.object.kind != .surface or target.object.epoch != self.host_epoch) return error.InvalidTarget;
        for (self.entries) |slot| if (slot) |entry| if (entry.challenge.nonce == nonce) return error.Conflict;
        for (&self.entries) |*slot| if (slot.* == null) {
            const challenge: Challenge = .{ .nonce = nonce, .target = target, .expires_ms = std.math.add(u64, now, lifetime_ms) catch return error.Expired };
            slot.* = .{ .key = key, .challenge = challenge };
            return challenge;
        };
        return error.Full;
    }
    pub fn submit(self: *Transactions, key: Key, bytes: []const u8, now: u64) !Status {
        const entry = self.find(key) orelse return error.InvalidTicket;
        const decoded = try decode(bytes);
        if (decoded.nonce != entry.challenge.nonce or decoded.request != key.request) return error.InvalidTicket;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        if (entry.phase != .challenged) {
            if (!std.mem.eql(u8, &hash, &entry.hash)) return error.Conflict;
            return self.status(key).?;
        }
        if (self.closing) return error.Closing;
        if (now >= entry.challenge.expires_ms) return error.Expired;
        var pending: usize = 0;
        for (self.entries) |slot| if (slot) |item| {
            if (item.bytes != null) pending += 1;
        };
        if (pending >= max_pending) return error.Full;
        const owned = try self.allocator.dupe(u8, bytes);
        entry.bytes = owned;
        entry.hash = hash;
        entry.phase = .queued;
        return .{ .pending = .queued };
    }
    pub fn take(self: *Transactions, now: u64) ?Work {
        if (self.closing) return null;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.phase != .queued) continue;
            if (now >= entry.challenge.expires_ms) {
                self.finish(entry, .expired);
                continue;
            }
            entry.phase = .preview;
            return .{ .key = entry.key, .target = entry.challenge.target, .decoded = decode(entry.bytes.?) catch unreachable };
        };
        return null;
    }
    /// GUI calls this ONLY after explicit preview response and a fresh target
    /// attachment lookup. No positive completion ACK is emitted at this stage.
    pub fn approve(self: *Transactions, key: Key, accepted: bool, live: refs.Attachment, now: u64) Error!bool {
        const entry = self.find(key) orelse return error.InvalidTicket;
        if (entry.phase != .preview) return error.NotPreviewing;
        if (self.closing or !accepted) {
            self.finish(entry, .cancelled);
            return false;
        }
        if (now >= entry.challenge.expires_ms) {
            self.finish(entry, .expired);
            return false;
        }
        if (!entry.challenge.target.matches(live)) {
            self.finish(entry, .target_gone);
            return false;
        }
        entry.phase = .pasting;
        return true;
    }
    /// Success only after the protected paste operation's observable final
    /// callback. A queued paste, dialog acceptance or `.started` is insufficient.
    pub fn complete(self: *Transactions, key: Key, outcome: Outcome) Error!void {
        const entry = self.find(key) orelse return error.InvalidTicket;
        if (entry.phase == .complete and entry.outcome == outcome) return;
        if (entry.phase != .pasting and !(entry.phase == .preview and outcome != .pasted)) return error.NotPasting;
        self.finish(entry, outcome);
    }
    pub fn status(self: *Transactions, key: Key) ?Status {
        const entry = self.find(key) orelse return null;
        return if (entry.outcome) |outcome| .{ .complete = outcome } else .{ .pending = entry.phase };
    }
    pub fn shutdown(self: *Transactions) void {
        self.closing = true;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.phase == .queued or entry.phase == .challenged) self.finish(entry, .cancelled);
        };
    }
    /// Only after native verification of the exact PID/birth's exit. Pending
    /// GUI borrows cannot be evicted; socket loss or elapsed time is insufficient.
    pub fn forgetExitedPeer(self: *Transactions, source: Binding) Error!void {
        for (self.entries) |slot| if (slot) |entry| {
            if (std.meta.eql(entry.key.source, source) and (entry.phase == .preview or entry.phase == .pasting)) return error.Busy;
        };
        for (&self.entries) |*slot| if (slot.*) |entry| {
            if (!std.meta.eql(entry.key.source, source)) continue;
            if (entry.bytes) |bytes| self.allocator.free(bytes);
            slot.* = null;
        };
    }
    fn find(self: *Transactions, key: Key) ?*Entry {
        for (&self.entries) |*slot| if (slot.*) |*entry| if (std.meta.eql(entry.key, key)) return entry;
        return null;
    }
    fn finish(self: *Transactions, entry: *Entry, outcome: Outcome) void {
        if (entry.bytes) |bytes| self.allocator.free(bytes);
        entry.bytes = null;
        entry.phase = .complete;
        entry.outcome = outcome;
    }
};

const test_key: Key = .{ .source = .{ .process = .{ .pid = 1, .birth = 2 }, .epoch = 3 }, .request = 4 };
fn testTarget() refs.Attachment {
    return .{ .object = .{ .epoch = 5, .kind = .surface, .id = 6, .generation = 7 }, .owner = .{ .epoch = 5, .kind = .window, .id = 8, .generation = 9 }, .revision = 10 };
}

test "drop broker codec has only owned bounded text or file paths" {
    const alloc = std.testing.allocator;
    const text = try encode(alloc, 1, 2, .{ .text = "owned\r\ntext" });
    defer alloc.free(text);
    const decoded = try decode(text);
    try std.testing.expectEqualStrings("owned\r\ntext", decoded.text);
    const files = try encode(alloc, 1, 2, .{ .files = &.{"C:\\owned\\中文.txt"} });
    defer alloc.free(files);
    const paths = try decode(files);
    try std.testing.expectEqualStrings("C:\\owned\\中文.txt", paths.payload().files[0]);
    try std.testing.expectError(error.InvalidFrame, decode(files[0 .. files.len - 1]));
    try std.testing.expectError(error.InvalidData, encode(alloc, 1, 2, .{ .files = &.{"\\\\?\\C:\\device"} }));
    try std.testing.expectError(error.InvalidData, encode(alloc, 1, 2, .{ .text = "bad\x00text" }));
}

test "drop broker requires explicit preview and final paste before success ACK" {
    var queue = try Transactions.init(std.testing.allocator, 5);
    defer queue.deinit();
    _ = try queue.prepare(test_key, testTarget(), 11, 100);
    const bytes = try encode(std.testing.allocator, 4, 11, .{ .text = "owned" });
    defer std.testing.allocator.free(bytes);
    _ = try queue.submit(test_key, bytes, 101);
    try std.testing.expectError(error.NotPasting, queue.complete(test_key, .pasted));
    const work = queue.take(102).?;
    try std.testing.expectEqualStrings("owned", work.decoded.payload().text);
    try std.testing.expectError(error.NotPasting, queue.complete(test_key, .pasted));
    try std.testing.expect(try queue.approve(test_key, true, testTarget(), 103));
    try std.testing.expectEqualDeep(Status{ .pending = .pasting }, queue.status(test_key).?);
    try queue.complete(test_key, .pasted);
    try std.testing.expectEqualDeep(Status{ .complete = .pasted }, try queue.submit(test_key, bytes, 104));
}

test "drop broker stale target expiry cancel and shutdown do not paste" {
    for (0..4) |scenario| {
        var queue = try Transactions.init(std.testing.allocator, 5);
        defer queue.deinit();
        _ = try queue.prepare(test_key, testTarget(), 11, 100);
        const bytes = try encode(std.testing.allocator, 4, 11, .{ .text = "owned" });
        defer std.testing.allocator.free(bytes);
        _ = try queue.submit(test_key, bytes, 101);
        _ = queue.take(102).?;
        var target = testTarget();
        if (scenario == 0) target.revision += 1;
        if (scenario == 3) queue.shutdown();
        try std.testing.expect(!try queue.approve(test_key, scenario != 2, target, if (scenario == 1) 30100 else 103));
        try std.testing.expect(queue.status(test_key).?.complete != .pasted);
    }
}

test "drop broker permits only medium high crossing and preserves every other identity boundary" {
    const local: policy.Identity = .{ .process = .{ .pid = 1, .birth = 2 }, .sid = @splat(3), .logon_id = 4, .linked_logon_id = 9, .session_id = 5, .integrity = .high, .elevated = true };
    var peer = local;
    peer.process = .{ .pid = 6, .birth = 7 };
    peer.logon_id = 9;
    peer.linked_logon_id = 4;
    peer.integrity = .medium;
    peer.elevated = false;
    const domain: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    try authenticate(local, peer, peer.process, domain, domain);
    try authenticate(peer, local, local.process, domain, domain);
    try std.testing.expectError(error.DifferentLogon, policy.authenticate(local, peer, peer.process, domain, domain, false));
    try std.testing.expectError(error.DifferentLogon, policy.authenticate(peer, local, local.process, domain, domain, false));
    var other = peer;
    other.sid[0] ^= 1;
    try std.testing.expectError(error.DifferentUser, authenticate(local, other, other.process, domain, domain));
    other = peer;
    other.logon_id += 1;
    try std.testing.expectError(error.DifferentLogon, authenticate(local, other, other.process, domain, domain));
    other = peer;
    other.session_id += 1;
    try std.testing.expectError(error.DifferentSession, authenticate(local, other, other.process, domain, domain));
    other = peer;
    other.integrity = .low;
    try std.testing.expectError(error.UnauthorizedPeer, authenticate(local, other, other.process, domain, domain));
    other.integrity = .system;
    try std.testing.expectError(error.UnauthorizedPeer, authenticate(local, other, other.process, domain, domain));
    other = peer;
    other.process.birth += 1;
    try std.testing.expectError(error.ProcessChanged, authenticate(local, other, peer.process, domain, domain));
    inline for (@typeInfo(policy.Isolation).@"struct".field_names) |field| {
        var changed = domain;
        @field(changed, field)[0] ^= 1;
        try std.testing.expectError(error.DifferentIsolation, authenticate(local, peer, peer.process, domain, changed));
    }
}

test "drop broker requires reciprocal native split links and never infers one from user SID" {
    const high: policy.Identity = .{ .process = .{ .pid = 1, .birth = 2 }, .sid = @splat(3), .logon_id = 4, .linked_logon_id = 9, .session_id = 5, .integrity = .high, .elevated = true };
    const medium: policy.Identity = .{ .process = .{ .pid = 6, .birth = 7 }, .sid = high.sid, .logon_id = 9, .linked_logon_id = 4, .session_id = 5, .integrity = .medium, .elevated = false };
    const domain: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    var missing = medium;
    missing.linked_logon_id = null;
    try std.testing.expectError(error.DifferentLogon, authenticate(high, missing, missing.process, domain, domain));
    try std.testing.expectError(error.DifferentLogon, authenticate(missing, high, high.process, domain, domain));
    var wrong = medium;
    wrong.linked_logon_id = 100;
    try std.testing.expectError(error.DifferentLogon, authenticate(high, wrong, wrong.process, domain, domain));
    try std.testing.expectError(error.DifferentLogon, authenticate(wrong, high, high.process, domain, domain));
    var wrong_high = high;
    wrong_high.linked_logon_id = 101;
    try std.testing.expectError(error.DifferentLogon, authenticate(wrong_high, medium, medium.process, domain, domain));
    wrong = medium;
    wrong.elevated = true;
    try std.testing.expectError(error.DifferentLogon, authenticate(high, wrong, wrong.process, domain, domain));
    // Same-logon crossing is not proof of a split pair, even for the same SID.
    wrong = medium;
    wrong.logon_id = high.logon_id;
    wrong.linked_logon_id = null;
    try std.testing.expectError(error.UnauthorizedPeer, authenticate(high, wrong, wrong.process, domain, domain));
    // Normal same-level clients still work without any linked token fact.
    var normal = medium;
    normal.linked_logon_id = null;
    try authenticate(normal, normal, normal.process, domain, domain);
    wrong = normal;
    wrong.logon_id = 100;
    wrong.linked_logon_id = normal.logon_id;
    normal.linked_logon_id = wrong.logon_id;
    try std.testing.expectError(error.DifferentLogon, authenticate(normal, wrong, wrong.process, domain, domain));
}

test "drop broker bounded pending payloads reject overflow and preserve in-flight GUI borrows on shutdown" {
    var queue = try Transactions.init(std.testing.allocator, 5);
    defer queue.deinit();
    for (0..max_pending + 1) |index| {
        var key = test_key;
        key.request = index + 1;
        const nonce = index + 1;
        _ = try queue.prepare(key, testTarget(), nonce, 0);
        const bytes = try encode(std.testing.allocator, key.request, nonce, .{ .text = "owned" });
        defer std.testing.allocator.free(bytes);
        if (index < max_pending) _ = try queue.submit(key, bytes, 1) else try std.testing.expectError(error.Full, queue.submit(key, bytes, 1));
    }
    const work = queue.take(2).?;
    queue.shutdown();
    try std.testing.expectEqualStrings("owned", work.decoded.payload().text);
    try std.testing.expectError(error.Busy, queue.forgetExitedPeer(test_key.source));
    try std.testing.expect(!try queue.approve(work.key, true, testTarget(), 3));
    try queue.forgetExitedPeer(test_key.source);
}

test "drop broker completed request queries survive target loss without reexecuting" {
    var queue = try Transactions.init(std.testing.allocator, 5);
    defer queue.deinit();
    const challenge = try queue.prepare(test_key, testTarget(), 11, 100);
    const bytes = try encode(std.testing.allocator, 4, 11, .{ .text = "owned" });
    defer std.testing.allocator.free(bytes);
    _ = try queue.submit(test_key, bytes, 101);
    _ = queue.take(102).?;
    try std.testing.expect(!try queue.approve(test_key, false, testTarget(), 103));
    try std.testing.expectEqualDeep(challenge, try queue.prepare(test_key, .{}, 12, 104));
    try std.testing.expectEqualDeep(Status{ .complete = .cancelled }, queue.status(test_key).?);
    const altered = try encode(std.testing.allocator, 4, 11, .{ .text = "different" });
    defer std.testing.allocator.free(altered);
    try std.testing.expectError(error.Conflict, queue.submit(test_key, altered, 104));
}
