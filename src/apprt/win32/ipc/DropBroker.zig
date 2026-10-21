//! Dedicated local drop pipe. This does not weaken ordinary IPC authentication.
//! The medium companion must own a real OLE receiver; high-integrity App must
//! explicitly preview each Work and call complete only on final protected paste.
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
const wire = @import("wire.zig");
pub const contract = @import("../../../gx/ipc/drop_broker.zig");
const refs = @import("../../../gx/ui_ref.zig");
const policy = security.policy;
const response_size = 96;
const AbsoluteDescriptor = extern struct { revision: u8 = 1, padding: u8 = 0, control: u16 = 0, owner: ?*anyopaque = null, group: ?*anyopaque = null, sacl: ?*anyopaque = null, dacl: ?*anyopaque = null };
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorDacl(*anyopaque, *i32, *?*anyopaque, *i32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorSacl(*anyopaque, *i32, *?*anyopaque, *i32) callconv(.winapi) i32;
extern "advapi32" fn SetSecurityDescriptorDacl(*anyopaque, i32, ?*anyopaque, i32) callconv(.winapi) i32;
extern "advapi32" fn SetSecurityDescriptorSacl(*anyopaque, i32, ?*anyopaque, i32) callconv(.winapi) i32;
extern "advapi32" fn SetSecurityDescriptorControl(*anyopaque, u16, u16) callconv(.winapi) i32;

const Descriptor = struct {
    user: security.Descriptor,
    label: *anyopaque,
    absolute: AbsoluteDescriptor = .{},
    fn init() !Descriptor {
        const user = try security.Descriptor.initDrop();
        errdefer user.deinit();
        var label: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral("S:(ML;;NW;;;ME)"), 1, &label, null) == 0) return error.LabelFailed;
        return .{ .user = user, .label = label orelse return error.LabelFailed };
    }
    fn attributes(self: *Descriptor) !n.SA {
        var present: i32 = 0;
        var defaulted: i32 = 0;
        var acl: ?*anyopaque = null;
        if (GetSecurityDescriptorDacl(self.user.memory, &present, &acl, &defaulted) == 0 or present == 0 or acl == null) return error.DescriptorFailed;
        if (SetSecurityDescriptorDacl(&self.absolute, 1, acl, 0) == 0) return error.DescriptorFailed;
        if (GetSecurityDescriptorSacl(self.label, &present, &acl, &defaulted) == 0 or present == 0 or acl == null) return error.LabelFailed;
        if (SetSecurityDescriptorSacl(&self.absolute, 1, acl, 0) == 0 or SetSecurityDescriptorControl(&self.absolute, 0x1000, 0x1000) == 0) return error.DescriptorFailed;
        return .{ .nLength = @sizeOf(n.SA), .lpSecurityDescriptor = &self.absolute, .bInheritHandle = .FALSE };
    }
    fn deinit(self: *Descriptor) void {
        self.user.deinit();
        _ = n.LocalFree(self.label);
    }
};

pub const Endpoint = struct {
    name: [160:0]u16,
    isolation: policy.Isolation,
    host_epoch: u128,
    host: policy.Process,
    /// GUI/launcher hands this endpoint only to its owned companion. Discovery
    /// must retain this PID/birth+epoch, not select an arbitrary same-name pipe.
    pub fn init(isolation: policy.Isolation, local: policy.Identity, host_epoch: u128) !Endpoint {
        if (host_epoch == 0) return error.InvalidEpoch;
        return named(isolation, local, local.process, host_epoch);
    }
    /// Locate one exact process incarnation without trusting discovery payloads.
    /// Epoch zero means learn it once from the authenticated host hello.
    pub fn forTarget(isolation: policy.Isolation, target: policy.Process) !Endpoint {
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const peer = try security.inspect(target.pid);
        defer peer.deinit();
        try contract.authenticate(local.identity, peer.identity, target, isolation, isolation);
        try security.verifyImage(local, peer);
        // The server's actual token owns this namespace. A linked medium
        // companion has a different AuthenticationId from its elevated host.
        return named(isolation, peer.identity, target, 0);
    }
    fn named(isolation: policy.Isolation, local: policy.Identity, host: policy.Process, host_epoch: u128) !Endpoint {
        if (host.pid == 0 or host.birth == 0) return error.InvalidIdentity;
        var identity = local;
        identity.integrity = .medium;
        identity.elevated = false;
        const ordinary = try wire.Endpoint.init(isolation, identity);
        const base = std.mem.span(@as([*:0]const u16, &ordinary.name));
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(std.mem.sliceAsBytes(base));
        var process: [12]u8 = undefined;
        std.mem.writeInt(u32, process[0..4], host.pid, .little);
        std.mem.writeInt(u64, process[4..12], host.birth, .little);
        hash.update(&process);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var buffer: [128]u8 = undefined;
        const text = try std.mem.print(&buffer, "\\\\.\\pipe\\ghostty-gx-drop-v1-{s}", .{std.fmt.bytesToHex(digest, .lower)});
        var name: [160:0]u16 = @splat(0);
        _ = try std.unicode.utf8ToUtf16Le(&name, text);
        return .{ .name = name, .isolation = isolation, .host_epoch = host_epoch, .host = host };
    }
};

fn verifyHello(bytes: *const [wire.hello_size]u8, local: security.Facts, peer: security.Facts, domain: policy.Isolation) !u128 {
    if (!std.mem.eql(u8, bytes[0..4], "GXIH") or std.mem.readInt(u16, bytes[4..6], .little) != 1 or bytes[6] != 0 or bytes[7] != 0) return error.InvalidHandshake;
    const epoch = std.mem.readInt(u128, bytes[8..24], .little);
    if (epoch == 0) return error.InvalidEpoch;
    const claimed: policy.Process = .{ .pid = std.mem.readInt(u32, bytes[24..28], .little), .birth = std.mem.readInt(u64, bytes[28..36], .little) };
    var peer_domain: policy.Isolation = undefined;
    inline for (@typeInfo(policy.Isolation).@"struct".field_names, 0..) |field, index| @memcpy(&@field(peer_domain, field), bytes[36 + index * 32 ..][0..32]);
    try contract.authenticate(local.identity, peer.identity, claimed, domain, peer_domain);
    try security.verifyImage(local, peer);
    return epoch;
}

fn response(buffer: *[response_size]u8, challenge: contract.Challenge, status: contract.Status) void {
    @memset(buffer, 0);
    buffer[0] = 1;
    switch (status) {
        .complete => |outcome| buffer[1] = @backingInt(outcome),
        .pending => |phase| buffer[2] = @backingInt(phase),
    }
    std.mem.writeInt(u128, buffer[8..24], challenge.nonce, .little);
    std.mem.writeInt(u64, buffer[24..32], challenge.expires_ms, .little);
    std.mem.writeInt(u128, buffer[32..48], challenge.target.object.epoch, .little);
    std.mem.writeInt(u64, buffer[48..56], challenge.target.object.id, .little);
    std.mem.writeInt(u64, buffer[56..64], challenge.target.object.generation, .little);
    std.mem.writeInt(u64, buffer[64..72], challenge.target.owner.id, .little);
    std.mem.writeInt(u64, buffer[72..80], challenge.target.owner.generation, .little);
    std.mem.writeInt(u64, buffer[80..88], challenge.target.revision, .little);
}

pub const Broker = struct {
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
    pipe: n.HANDLE,
    stop: n.HANDLE,
    changed: n.HANDLE,
    hwnd: ?std.os.windows.HWND = null,
    message: u32 = 0,
    thread: ?std.Thread = null,
    mutex: std.os.windows.SRWLOCK = .{},
    transactions: contract.Transactions,
    target: refs.Attachment = .{},
    peers: [contract.max_tickets]?Peer = @splat(null),
    last_error: std.atomic.Value(u16) = .init(0),
    const Peer = struct { binding: contract.Binding, facts: security.Facts };

    pub fn create(allocator: std.mem.Allocator, domain: policy.Isolation, host_epoch: u128) !*Broker {
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        if (local.identity.integrity != .medium and local.identity.integrity != .high) return error.UnauthorizedPeer;
        const endpoint = try Endpoint.init(domain, local.identity, host_epoch);
        var descriptor = try Descriptor.init();
        defer descriptor.deinit();
        var attributes = try descriptor.attributes();
        const pipe = n.CreateNamedPipeW(&endpoint.name, 0x40080003, 14, 1, 65536, 65536, 1000, &attributes);
        if (pipe == n.INVALID) return error.CreatePipeFailed;
        errdefer _ = n.CloseHandle(pipe);
        const stop = try n.event();
        errdefer _ = n.CloseHandle(stop);
        const changed = n.CreateEventW(null, 0, 0, null) orelse return error.EventFailed;
        errdefer _ = n.CloseHandle(changed);
        const self = try allocator.create(Broker);
        self.* = .{ .allocator = allocator, .endpoint = endpoint, .pipe = pipe, .stop = stop, .changed = changed, .transactions = try contract.Transactions.init(allocator, host_epoch) };
        return self;
    }
    pub fn start(self: *Broker, hwnd: std.os.windows.HWND, message: u32) !void {
        if (self.thread != null) return error.AlreadyStarted;
        self.hwnd = hwnd;
        self.message = message;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    /// GUI publishes only a currently confirmed drop destination. Challenge
    /// issuance snapshots it; approve still rechecks the actual live attachment.
    pub fn setTarget(self: *Broker, target: refs.Attachment) void {
        self.lock();
        defer self.unlock();
        self.target = target;
    }
    pub fn take(self: *Broker) ?contract.Work {
        self.lock();
        defer self.unlock();
        return self.transactions.take(n.GetTickCount64());
    }
    pub fn approve(self: *Broker, key: contract.Key, accepted: bool, live: refs.Attachment) !bool {
        self.lock();
        defer self.unlock();
        const peer_alive = for (self.peers) |slot| {
            if (slot) |peer| if (std.meta.eql(peer.binding, key.source)) break n.WaitForSingleObject(peer.facts.process, 0) == 258;
        } else false;
        const result = try self.transactions.approve(key, accepted and peer_alive, live, n.GetTickCount64());
        _ = n.SetEvent(self.changed);
        return result;
    }
    pub fn complete(self: *Broker, key: contract.Key, outcome: contract.Outcome) !void {
        self.lock();
        defer self.unlock();
        try self.transactions.complete(key, outcome);
        _ = n.SetEvent(self.changed);
    }
    pub fn shutdown(self: *Broker) void {
        self.lock();
        self.transactions.shutdown();
        self.target = .{};
        self.unlock();
        _ = n.SetEvent(self.stop);
    }
    /// GUI preview/paste callbacks must have completed/cancelled before destroy.
    pub fn destroy(self: *Broker) void {
        self.shutdown();
        if (self.thread) |thread| thread.join();
        self.transactions.deinit();
        for (self.peers) |peer| if (peer) |value| value.facts.deinit();
        _ = n.CloseHandle(self.pipe);
        _ = n.CloseHandle(self.stop);
        _ = n.CloseHandle(self.changed);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    fn lock(self: *Broker) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.mutex);
    }
    fn unlock(self: *Broker) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.mutex);
    }
    fn run(self: *Broker) void {
        const buffer = self.allocator.alloc(u8, contract.max_frame_bytes) catch {
            self.last_error.store(@intFromError(error.OutOfMemory), .release);
            return;
        };
        defer self.allocator.free(buffer);
        while (n.WaitForSingleObject(self.stop, 0) == 258) {
            n.connect(self.pipe, self.stop) catch {
                _ = n.DisconnectNamedPipe(self.pipe);
                continue;
            };
            self.serve(buffer) catch |err| self.last_error.store(@intFromError(err), .release);
            _ = n.DisconnectNamedPipe(self.pipe);
        }
    }
    fn bindPeer(self: *Broker, binding: contract.Binding, facts: security.Facts) !bool {
        self.lock();
        defer self.unlock();
        for (&self.peers) |*slot| if (slot.*) |peer| {
            if (n.WaitForSingleObject(peer.facts.process, 0) == 0) {
                const reclaim = if (self.transactions.forgetExitedPeer(peer.binding)) |_| true else |_| false;
                if (reclaim) {
                    peer.facts.deinit();
                    slot.* = null;
                    continue;
                }
            }
            if (std.meta.eql(peer.binding.process, binding.process)) {
                if (peer.binding.epoch != binding.epoch) return error.PeerChanged;
                return false;
            }
            if (peer.binding.epoch == binding.epoch) return error.PeerChanged;
        };
        for (&self.peers) |*slot| if (slot.* == null) {
            slot.* = .{ .binding = binding, .facts = facts };
            return true;
        };
        return error.Full;
    }
    fn serve(self: *Broker, buffer: []u8) !void {
        const deadline = n.Deadline.init(35_000);
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const peer = try security.pipePeer(self.pipe, true);
        var retained = false;
        defer if (!retained) peer.deinit();
        try contract.authenticate(local.identity, peer.identity, peer.identity.process, self.endpoint.isolation, self.endpoint.isolation);
        try security.verifyImage(local, peer);
        var hello: [wire.hello_size]u8 = undefined;
        wire.hello(&hello, self.endpoint.host_epoch, local.identity, self.endpoint.isolation);
        try n.write(self.pipe, &hello, self.stop, deadline);
        if ((try n.readMessage(self.pipe, &hello, self.stop, deadline)).len != hello.len) return error.InvalidHandshake;
        const source_epoch = try verifyHello(&hello, local, peer, self.endpoint.isolation);
        const binding: contract.Binding = .{ .epoch = source_epoch, .process = peer.identity.process };
        retained = try self.bindPeer(binding, peer);
        var request_bytes: [8]u8 = undefined;
        if ((try n.readMessage(self.pipe, &request_bytes, self.stop, deadline)).len != 8) return error.InvalidFrame;
        const key: contract.Key = .{ .source = binding, .request = std.mem.readInt(u64, &request_bytes, .little) };
        const nonce = try n.epoch();
        self.lock();
        const challenge = self.transactions.prepare(key, self.target, nonce, n.GetTickCount64()) catch |err| {
            self.unlock();
            return err;
        };
        const initial = self.transactions.status(key).?;
        self.unlock();
        var answer: [response_size]u8 = undefined;
        response(&answer, challenge, initial);
        try n.write(self.pipe, &answer, self.stop, deadline);
        if (initial != .complete) {
            const bytes = try n.readMessage(self.pipe, buffer, self.stop, deadline);
            if (n.WaitForSingleObject(peer.process, 0) != 258) return error.PeerExited;
            self.lock();
            _ = self.transactions.submit(key, bytes, n.GetTickCount64()) catch |err| {
                self.unlock();
                return err;
            };
            self.unlock();
            if (n.PostMessageW(self.hwnd.?, self.message, 0, 0) == 0) return error.PostFailed;
            while (true) {
                self.lock();
                const status = self.transactions.status(key).?;
                self.unlock();
                if (status == .complete) {
                    response(&answer, challenge, status);
                    try n.write(self.pipe, &answer, self.stop, deadline);
                    break;
                }
                const events = [_]n.HANDLE{ self.changed, self.stop };
                switch (n.WaitForMultipleObjects(2, &events, 0, deadline.remaining())) {
                    0 => {},
                    1 => return error.Cancelled,
                    else => return error.Timeout,
                }
            }
        }
        var receipt: [1]u8 = undefined;
        if ((try n.readMessage(self.pipe, &receipt, self.stop, deadline)).len != 1 or receipt[0] != 1) return error.InvalidReceipt;
    }
};

pub const Attempt = struct {
    endpoint: Endpoint,
    source_epoch: u128,
    request: u64,
    payload_hash: ?[32]u8 = null,
    pub fn send(self: *Attempt, allocator: std.mem.Allocator, payload: contract.Payload) !contract.Outcome {
        return self.sendCancelable(allocator, payload, null);
    }
    /// Cancellation only stops local waiting. Once submitted, an unknown reply
    /// never implies that the high-end operation was rolled back or may replay.
    pub fn sendCancelable(self: *Attempt, allocator: std.mem.Allocator, payload: contract.Payload, stop: ?n.HANDLE) !contract.Outcome {
        const check = try contract.encode(allocator, self.request, 1, payload);
        defer allocator.free(check);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(check, &hash, .{});
        if (self.payload_hash) |previous| {
            if (!std.mem.eql(u8, &previous, &hash)) return error.Conflict;
        } else self.payload_hash = hash;
        const deadline = n.Deadline.init(36_000);
        const pipe = n.CreateFileW(&self.endpoint.name, 0xc0000000, 0, null, 3, 0x40110000, null);
        if (pipe == n.INVALID) return error.OpenPipeFailed;
        defer _ = n.CloseHandle(pipe);
        const mode: u32 = 2;
        if (n.SetNamedPipeHandleState(pipe, &mode, null, null) == 0) return error.PipeModeFailed;
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const peer = try security.pipePeer(pipe, false);
        defer peer.deinit();
        if (!std.meta.eql(peer.identity.process, self.endpoint.host)) return error.PeerChanged;
        var hello: [wire.hello_size]u8 = undefined;
        if ((try n.readMessage(pipe, &hello, stop, deadline)).len != hello.len) return error.InvalidHandshake;
        const verified_epoch = try verifyHello(&hello, local, peer, self.endpoint.isolation);
        if (self.endpoint.host_epoch == 0) self.endpoint.host_epoch = verified_epoch else if (verified_epoch != self.endpoint.host_epoch) return error.PeerChanged;
        wire.hello(&hello, self.source_epoch, local.identity, self.endpoint.isolation);
        try n.write(pipe, &hello, stop, deadline);
        var request_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &request_bytes, self.request, .little);
        try n.write(pipe, &request_bytes, stop, deadline);
        var answer: [response_size]u8 = undefined;
        if ((try n.readMessage(pipe, &answer, stop, deadline)).len != answer.len or answer[0] != 1) return error.InvalidReply;
        if (answer[1] == 0) {
            if (std.mem.readInt(u128, answer[32..48], .little) != self.endpoint.host_epoch) return error.InvalidTarget;
            const bytes = try contract.encode(allocator, self.request, std.mem.readInt(u128, answer[8..24], .little), payload);
            defer allocator.free(bytes);
            n.write(pipe, bytes, stop, deadline) catch return error.ResultUnknown;
            const reply = n.readMessage(pipe, &answer, stop, deadline) catch return error.ResultUnknown;
            if (reply.len != answer.len or answer[0] != 1) return error.InvalidReply;
        }
        const outcome = std.enums.fromInt(contract.Outcome, answer[1]) orelse return error.InvalidReply;
        n.write(pipe, &.{1}, stop, deadline) catch {};
        return outcome;
    }
};

test "drop broker native pipe requires preview and final paste callback" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const domain: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    const epoch = try n.epoch();
    const broker = try Broker.create(std.testing.allocator, domain, epoch);
    defer broker.destroy();
    const w32 = @import("../win32.zig");
    const hwnd = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("owned drop broker contract"), 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.TestWindowFailed;
    defer _ = w32.DestroyWindow(hwnd);
    var issuer = try refs.Issuer.init(epoch);
    const owner = try issuer.create(.window);
    const target = try issuer.attach(try issuer.surface(1), owner);
    broker.setTarget(target);
    try broker.start(hwnd, 0x806f);
    const Probe = struct {
        attempt: Attempt,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            const outcome = self.attempt.send(std.heap.page_allocator, .{ .text = "owned harmless text" }) catch |err| {
                self.failure = err;
                return;
            };
            if (outcome != .pasted) self.failure = error.UnexpectedOutcome;
        }
    };
    const located = try Endpoint.forTarget(domain, broker.endpoint.host);
    try std.testing.expectEqualSlices(u16, &broker.endpoint.name, &located.name);
    try std.testing.expectEqual(@as(u128, 0), located.host_epoch);
    var probe: Probe = .{ .attempt = .{ .endpoint = located, .source_epoch = try n.epoch(), .request = 1 } };
    const worker = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    defer worker.join();
    const deadline = n.Deadline.init(10_000);
    var handled = false;
    while (!probe.done.load(.acquire) and deadline.remaining() != 0) {
        if (broker.take()) |work| {
            try std.testing.expectError(error.NotPasting, broker.complete(work.key, .pasted));
            try std.testing.expectEqualStrings("owned harmless text", work.decoded.payload().text);
            try std.testing.expect(try broker.approve(work.key, true, target));
            try std.testing.expect(!probe.done.load(.acquire));
            // Native contract driver represents the final callback, not a real
            // PTY paste. VM high-end GUI/medium companion remain separate gates.
            try broker.complete(work.key, .pasted);
            handled = true;
        }
        _ = n.WaitForSingleObject(broker.stop, 1);
    }
    if (!probe.done.load(.acquire)) {
        broker.shutdown();
        return error.TestTimeout;
    }
    if (probe.failure) |err| return err;
    try std.testing.expect(handled);
    try std.testing.expectEqual(epoch, probe.attempt.endpoint.host_epoch);
}

test "drop broker endpoint binds host PID birth and isolation without prior epoch discovery" {
    const local = try security.inspect(n.GetCurrentProcessId());
    defer local.deinit();
    const domain: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    const first = try Endpoint.init(domain, local.identity, 123);
    const restarted = try Endpoint.init(domain, local.identity, 456);
    try std.testing.expectEqualSlices(u16, &first.name, &restarted.name);
    var other = local.identity;
    other.process.birth += 1;
    const different_birth = try Endpoint.init(domain, other, 123);
    try std.testing.expect(!std.mem.eql(u16, &first.name, &different_birth.name));
    other = local.identity;
    other.process.pid += 1;
    const different_pid = try Endpoint.init(domain, other, 123);
    try std.testing.expect(!std.mem.eql(u16, &first.name, &different_pid.name));
    var isolated = domain;
    isolated.config_root[0] ^= 1;
    const different_domain = try Endpoint.init(isolated, local.identity, 123);
    try std.testing.expect(!std.mem.eql(u16, &first.name, &different_domain.name));
}

test "drop broker split token endpoint is named by the authenticated host logon" {
    const host: policy.Identity = .{ .process = .{ .pid = 1, .birth = 2 }, .sid = @splat(3), .logon_id = 4, .linked_logon_id = 9, .session_id = 5, .integrity = .high, .elevated = true };
    var companion = host;
    companion.process = .{ .pid = 6, .birth = 7 };
    companion.integrity = .medium;
    companion.elevated = false;
    companion.logon_id = 9;
    companion.linked_logon_id = 4;
    const domain: policy.Isolation = .{ .config_root = @splat(1), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    try contract.authenticate(companion, host, host.process, domain, domain);
    const server = try Endpoint.init(domain, host, 123);
    const verified_target = try Endpoint.named(domain, host, host.process, 0);
    try std.testing.expectEqualSlices(u16, &server.name, &verified_target.name);
    const caller_logon = try Endpoint.named(domain, companion, host.process, 0);
    try std.testing.expect(!std.mem.eql(u16, &server.name, &caller_logon.name));
}
