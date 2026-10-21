//! Warm WinRT delegates and cold COM activation share one bounded token sink.
//! Callbacks never own a Surface/Window pointer, execute text, or create shells.
const std = @import("std");
const Identity = @import("Identity.zig");
const Ref = @import("../../../gx/ui_ref.zig").Reference;
const GUID = Identity.GUID;
const HRESULT = Identity.HRESULT;
const Interface = Identity.Interface;
const prefix = "gx-toast-v1:";
pub const token_length = prefix.len + 65;
pub const Token = struct { host_epoch: u128, nonce: u128 };

pub fn encode(token: Token, buffer: *[token_length]u8) ![]const u8 {
    if (token.host_epoch == 0 or token.nonce == 0) return error.InvalidToken;
    return try std.mem.print(buffer, "{s}{x:0>32}:{x:0>32}", .{ prefix, token.host_epoch, token.nonce });
}
pub fn parse(value: []const u8) !Token {
    if (value.len != token_length or !std.mem.startsWith(u8, value, prefix) or value[prefix.len + 32] != ':') return error.InvalidToken;
    for (value[prefix.len..], 0..) |byte, index| {
        if (index != 32 and !std.ascii.isHex(byte)) return error.InvalidToken;
    }
    const epoch = std.fmt.parseInt(u128, value[prefix.len .. prefix.len + 32], 16) catch return error.InvalidToken;
    const nonce = std.fmt.parseInt(u128, value[prefix.len + 33 ..], 16) catch return error.InvalidToken;
    if (epoch == 0 or nonce == 0) return error.InvalidToken;
    return .{ .host_epoch = epoch, .nonce = nonce };
}

/// GUI-owned capabilities. Closing a target invalidates its entries; a banner
/// timeout does not, since the notification may still live in Action Center.
pub const Registry = struct {
    epoch: u128,
    secret: [32]u8,
    serial: u64 = 0,
    entries: [256]?Entry = @splat(null),
    const Entry = struct { token: Token, target: Ref, serial: u64 };
    pub const Issued = struct { token: Token, evicted: ?Token = null };
    pub fn init(io: std.Io, epoch: u128) !Registry {
        if (epoch == 0) return error.InvalidEpoch;
        var self: Registry = .{ .epoch = epoch, .secret = undefined };
        const random: std.Random.IoSource = .{ .io = io };
        random.interface().bytes(&self.secret);
        return self;
    }
    pub fn issue(self: *Registry, target: Ref) !Token {
        if (!target.isValid() or target.epoch != self.epoch or self.epoch == 0) return error.InvalidTarget;
        const slot = for (&self.entries) |*entry| {
            if (entry.* == null) break entry;
        } else return error.QueueFull;
        self.serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
        var serial: [8]u8 = undefined;
        std.mem.writeInt(u64, &serial, self.serial, .little);
        var digest: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, &serial, &self.secret);
        const token: Token = .{ .host_epoch = self.epoch, .nonce = std.mem.readInt(u128, digest[0..16], .big) };
        if (token.nonce == 0) return error.Exhausted;
        slot.* = .{ .token = token, .target = target, .serial = self.serial };
        return token;
    }
    /// Keep at most 256 Action Center capabilities, evicting the oldest issued
    /// token. The GUI must retire the returned evicted token on the MTA.
    pub fn issueWithEviction(self: *Registry, target: Ref) !Issued {
        if (!target.isValid() or target.epoch != self.epoch or self.epoch == 0) return error.InvalidTarget;
        var oldest: usize = 0;
        for (self.entries, 0..) |entry, index| {
            const value = entry orelse return .{ .token = try self.issue(target) };
            if (value.serial < self.entries[oldest].?.serial) oldest = index;
        }
        const previous = self.entries[oldest].?;
        self.entries[oldest] = null;
        errdefer self.entries[oldest] = previous;
        return .{ .token = try self.issue(target), .evicted = previous.token };
    }
    pub fn resolve(self: *const Registry, token: Token) ?Ref {
        if (token.host_epoch != self.epoch or self.epoch == 0) return null;
        for (self.entries) |entry_| if (entry_) |entry| {
            if (std.meta.eql(entry.token, token)) return entry.target;
        };
        return null;
    }
    pub fn revoke(self: *Registry, token: Token) void {
        for (&self.entries) |*entry| if (entry.*) |value| {
            if (std.meta.eql(token, value.token)) entry.* = null;
        };
    }
    /// Return the revoked tokens so the MTA can retire their event handlers.
    pub fn revokeTarget(self: *Registry, target: Ref, output: *[256]Token) []const Token {
        var count: usize = 0;
        for (&self.entries) |*entry| if (entry.*) |value| {
            if (target.matches(value.target)) {
                output[count] = value.token;
                count += 1;
                entry.* = null;
            }
        };
        return output[0..count];
    }
    pub fn invalidate(self: *Registry, target: Ref) void {
        var tokens: [256]Token = undefined;
        _ = self.revokeTarget(target, &tokens);
    }
    pub fn shutdown(self: *Registry) void {
        self.epoch = 0;
        self.entries = @splat(null);
        @memset(&self.secret, 0);
    }
};

pub const Sink = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    lock: std.os.windows.SRWLOCK = .{},
    closed: bool = false,
    destination: ?std.os.windows.HWND,
    message: u32,
    aumid: [:0]u16,
    queue: [64]Token = undefined,
    head: usize = 0,
    len: usize = 0,
    pub fn create(allocator: std.mem.Allocator, identity: *const Identity, hwnd: ?std.os.windows.HWND, message: u32) !*Sink {
        const self = try allocator.create(Sink);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .destination = hwnd, .message = message, .aumid = try allocator.dupeSentinel(u16, identity.aumid, 0) };
        return self;
    }
    pub fn retain(self: *Sink) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Sink) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.allocator.free(self.aumid);
        self.allocator.destroy(self);
    }
    fn acquire(self: *Sink) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.lock);
    }
    fn unlock(self: *Sink) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.lock);
    }
    pub fn close(self: *Sink) void {
        self.acquire();
        defer self.unlock();
        self.closed = true;
        self.destination = null;
        self.len = 0;
    }
    pub fn post(self: *Sink, token: Token) !void {
        if (token.host_epoch == 0 or token.nonce == 0) return error.InvalidToken;
        self.acquire();
        defer self.unlock();
        if (self.closed) return error.Closed;
        if (self.len == self.queue.len) return error.QueueFull;
        self.queue[(self.head + self.len) % self.queue.len] = token;
        self.len += 1;
        // Post under the close lock; the GUI closes the sink before destroying
        // this HWND. The message carries no address and is only a wake hint.
        if (self.destination) |hwnd| _ = PostMessageW(hwnd, self.message, 0, 0);
    }
    pub fn wake(self: *Sink) void {
        self.acquire();
        defer self.unlock();
        if (!self.closed) if (self.destination) |hwnd| {
            _ = PostMessageW(hwnd, self.message, 0, 0);
        };
    }
    pub fn take(self: *Sink) ?Token {
        self.acquire();
        defer self.unlock();
        if (self.closed or self.len == 0) return null;
        const result = self.queue[self.head];
        self.head = (self.head + 1) % self.queue.len;
        self.len -= 1;
        return result;
    }
};
extern "user32" fn PostMessageW(std.os.windows.HWND, u32, usize, isize) callconv(.winapi) i32;

const iid_callback = Identity.guid("53e31837-6600-4a81-9395-75cffe746f94");
const iid_factory = Identity.guid("00000001-0000-0000-c000-000000000046");
const iid_warm = Identity.guid("ab54de2d-97d9-5528-b6ad-105afe156530");
const no_interface: HRESULT = @bitCast(@as(u32, 0x80004002));
const invalid_argument: HRESULT = @bitCast(@as(u32, 0x80070057));
const unavailable: HRESULT = @bitCast(@as(u32, 0x80004005));
const out_of_memory: HRESULT = @bitCast(@as(u32, 0x8007000e));
const no_aggregation: HRESULT = @bitCast(@as(u32, 0x80040110));

fn bounded(ptr: [*:0]const u16, maximum: usize) ![]const u16 {
    for (0..maximum + 1) |index| if (ptr[index] == 0) return ptr[0..index];
    return error.TooLong;
}
fn parseWide(ptr: [*:0]const u16) !Token {
    const wide = try bounded(ptr, token_length);
    if (wide.len != token_length) return error.InvalidToken;
    var buffer: [token_length]u8 = undefined;
    for (wide, &buffer) |unit, *byte| {
        if (unit > 127) return error.InvalidToken;
        byte.* = @intCast(unit);
    }
    return parse(&buffer);
}

pub const Callback = struct {
    interface: Interface = .{ .vtable = &vtable },
    refs: std.atomic.Value(u32) = .init(1),
    sink: *Sink,
    pub fn create(sink: *Sink) !*Callback {
        const self = try sink.allocator.create(Callback);
        sink.retain();
        self.* = .{ .sink = sink };
        return self;
    }
    const vtable = [_]*const anyopaque{ @ptrCast(&query), @ptrCast(&addRef), @ptrCast(&release), @ptrCast(&activate) };
    fn from(face: *Interface) *Callback {
        return @alignCast(@fieldParentPtr("interface", face));
    }
    fn query(face: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!Identity.sameGuid(iid, &Identity.iid_unknown) and !Identity.sameGuid(iid, &iid_callback) and !Identity.sameGuid(iid, &Identity.iid_agile)) return no_interface;
        out.* = face;
        _ = addRef(face);
        return 0;
    }
    fn addRef(face: *Interface) callconv(.winapi) u32 {
        return from(face).refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(face: *Interface) callconv(.winapi) u32 {
        const self = from(face);
        const previous = self.refs.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const sink = self.sink;
            sink.allocator.destroy(self);
            sink.release();
        }
        return previous - 1;
    }
    /// SDK notificationactivationcallback.h: IUnknown + Activate; inputs are
    /// unsupported by our XML, so foreign input data is never inspected.
    fn activate(face: *Interface, aumid: [*:0]const u16, args: ?[*:0]const u16, _: ?*const anyopaque, count: u32) callconv(.winapi) HRESULT {
        const self = from(face);
        if (count != 0) return invalid_argument;
        const appid = bounded(aumid, 128) catch return invalid_argument;
        if (!std.mem.eql(u16, appid, self.sink.aumid)) return invalid_argument;
        const token = parseWide(args orelse return invalid_argument) catch return invalid_argument;
        self.sink.post(token) catch return unavailable;
        return 0;
    }
};

pub const WarmHandler = struct {
    interface: Interface = .{ .vtable = &vtable },
    refs: std.atomic.Value(u32) = .init(1),
    sink: *Sink,
    token: Token,
    pub fn create(sink: *Sink, token: Token) !*WarmHandler {
        const self = try sink.allocator.create(WarmHandler);
        sink.retain();
        self.* = .{ .sink = sink, .token = token };
        return self;
    }
    const vtable = [_]*const anyopaque{ @ptrCast(&query), @ptrCast(&addRef), @ptrCast(&release), @ptrCast(&invoke) };
    fn from(face: *Interface) *WarmHandler {
        return @alignCast(@fieldParentPtr("interface", face));
    }
    fn query(face: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!Identity.sameGuid(iid, &Identity.iid_unknown) and !Identity.sameGuid(iid, &iid_warm) and !Identity.sameGuid(iid, &Identity.iid_agile)) return no_interface;
        out.* = face;
        _ = addRef(face);
        return 0;
    }
    fn addRef(face: *Interface) callconv(.winapi) u32 {
        return from(face).refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(face: *Interface) callconv(.winapi) u32 {
        const self = from(face);
        const previous = self.refs.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const sink = self.sink;
            sink.allocator.destroy(self);
            sink.release();
        }
        return previous - 1;
    }
    fn invoke(face: *Interface, _: ?*Interface, _: ?*Interface) callconv(.winapi) HRESULT {
        const self = from(face);
        self.sink.post(self.token) catch return unavailable;
        return 0;
    }
};

const Factory = struct {
    interface: Interface = .{ .vtable = &vtable },
    refs: std.atomic.Value(u32) = .init(1),
    locks: std.atomic.Value(u32) = .init(0),
    sink: *Sink,
    const vtable = [_]*const anyopaque{ @ptrCast(&query), @ptrCast(&addRef), @ptrCast(&release), @ptrCast(&createInstance), @ptrCast(&lockServer) };
    fn from(face: *Interface) *Factory {
        return @alignCast(@fieldParentPtr("interface", face));
    }
    fn query(face: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!Identity.sameGuid(iid, &Identity.iid_unknown) and !Identity.sameGuid(iid, &iid_factory)) return no_interface;
        out.* = face;
        _ = addRef(face);
        return 0;
    }
    fn addRef(face: *Interface) callconv(.winapi) u32 {
        return from(face).refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(face: *Interface) callconv(.winapi) u32 {
        const self = from(face);
        const previous = self.refs.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const sink = self.sink;
            sink.allocator.destroy(self);
            sink.release();
        }
        return previous - 1;
    }
    fn createInstance(face: *Interface, outer: ?*Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (outer != null) return no_aggregation;
        const callback = Callback.create(from(face).sink) catch return out_of_memory;
        defer Identity.release(&callback.interface);
        return Callback.query(&callback.interface, iid, out);
    }
    fn lockServer(face: *Interface, locked: i32) callconv(.winapi) HRESULT {
        const self = from(face);
        if (locked != 0) {
            _ = self.locks.fetchAdd(1, .monotonic);
            _ = addRef(face);
        } else {
            var count = self.locks.load(.acquire);
            while (true) {
                if (count == 0) return invalid_argument;
                if (self.locks.cmpxchgWeak(count, count - 1, .acq_rel, .acquire)) |current| {
                    count = current;
                } else break;
            }
            _ = release(face);
        }
        return 0;
    }
};

/// Register/revoke on the worker MTA, after RoInitialize and before RoUninitialize.
/// This publishes a live class object only; installer registry writes are separate.
pub const Registration = struct {
    factory: *Factory,
    cookie: u32,
    pub fn start(identity: *const Identity, sink: *Sink) !Registration {
        if (!identity.registration_verified) return error.UnregisteredIdentity;
        const factory = try sink.allocator.create(Factory);
        sink.retain();
        factory.* = .{ .sink = sink };
        errdefer Identity.release(&factory.interface);
        var cookie: u32 = 0;
        if (CoRegisterClassObject(&identity.activator, &factory.interface, 4, 1, &cookie) < 0) return error.ActivatorUnavailable;
        return .{ .factory = factory, .cookie = cookie };
    }
    pub fn deinit(self: *Registration) void {
        _ = CoRevokeClassObject(self.cookie);
        Identity.release(&self.factory.interface);
        self.* = undefined;
    }
};
extern "ole32" fn CoRegisterClassObject(*const GUID, *Interface, u32, u32, *u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(u32) callconv(.winapi) HRESULT;

test "opaque token grammar is bounded and cannot carry command or body text" {
    const testing = std.testing;
    var buffer: [token_length]u8 = undefined;
    const token: Token = .{ .host_epoch = 10, .nonce = 23 };
    try testing.expectEqual(token, try parse(try encode(token, &buffer)));
    try testing.expectError(error.InvalidToken, parse("cmd.exe /c anything"));
    try testing.expectError(error.InvalidToken, parse(buffer[0 .. buffer.len - 1]));
}
test "registry keeps targets independent and expires only the closed target" {
    const testing = std.testing;
    var registry: Registry = .{ .epoch = 7, .secret = @splat(3) };
    const a: Ref = .{ .epoch = 7, .kind = .surface, .id = 11, .generation = 1 };
    const b: Ref = .{ .epoch = 7, .kind = .surface, .id = 12, .generation = 2 };
    const first = try registry.issue(a);
    const second = try registry.issue(b);
    try testing.expect(!std.meta.eql(first, second));
    registry.invalidate(a);
    try testing.expect(registry.resolve(first) == null);
    try testing.expect(registry.resolve(second).?.matches(b));
    registry.shutdown();
    try testing.expect(registry.resolve(second) == null);
}

test "registry evicts oldest capability and remains usable after thousands of notifications" {
    var registry: Registry = .{ .epoch = 7, .secret = @splat(3) };
    const target: Ref = .{ .epoch = 7, .kind = .surface, .id = 11, .generation = 1 };
    var evicted: usize = 0;
    for (0..1024) |_| {
        const issued = try registry.issueWithEviction(target);
        try std.testing.expect(registry.resolve(issued.token) != null);
        if (issued.evicted) |old| {
            evicted += 1;
            try std.testing.expect(registry.resolve(old) == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 768), evicted);
}
test "memory COM warm and cold callbacks copy independent tokens and close inertly" {
    const testing = std.testing;
    var identity = try Identity.init(testing.allocator, .installed, "C:/App/ghostty.exe", true);
    defer identity.deinit();
    const sink = try Sink.create(testing.allocator, &identity, null, 0);
    defer sink.release();
    const warm = try WarmHandler.create(sink, .{ .host_epoch = 1, .nonce = 2 });
    defer Identity.release(&warm.interface);
    const cold = try Callback.create(sink);
    defer Identity.release(&cold.interface);
    try testing.expectEqual(@as(HRESULT, 0), WarmHandler.invoke(&warm.interface, null, null));
    var buffer: [token_length]u8 = undefined;
    const encoded = try encode(.{ .host_epoch = 1, .nonce = 3 }, &buffer);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, encoded);
    defer testing.allocator.free(wide);
    try testing.expectEqual(@as(HRESULT, 0), Callback.activate(&cold.interface, identity.aumid, wide, null, 0));
    try testing.expectEqual(@as(u128, 2), sink.take().?.nonce);
    try testing.expectEqual(@as(u128, 3), sink.take().?.nonce);
    sink.close();
    try testing.expect(WarmHandler.invoke(&warm.interface, null, null) < 0);
}
