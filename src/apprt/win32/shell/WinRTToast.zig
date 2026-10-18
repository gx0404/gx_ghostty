//! Owned bounded toast queue with a dedicated MTA. Show success means accepted
//! by WinRT, never proof of banner visibility. Disabled/DND never use a balloon.
const Self = @This();
const std = @import("std");
const Identity = @import("Identity.zig");
const Activation = @import("ToastActivation.zig");
const Interface = Identity.Interface;
const GUID = Identity.GUID;
const HRESULT = Identity.HRESULT;
const HANDLE = std.os.windows.HANDLE;
const HSTRING = ?*anyopaque;
pub const State = enum(u8) { created, starting, ready, unavailable, stopping, stopped };
pub const Result = enum { accepted, suppressed, unavailable, failed, cancelled, evicted };
pub const Outcome = struct { token: Activation.Token, result: Result, hresult: HRESULT = 0 };
pub const Options = struct { activation_only: bool = false };
pub const max_title_bytes = 1024;
pub const max_body_bytes = 8192;
const EventToken = extern struct { value: i64 = 0 };
const Request = struct { token: Activation.Token, xml: []u8, cancelled: bool = false };
const Active = struct { toast: *Interface, handler: *Interface, event: EventToken, token: Activation.Token, serial: u64 };

allocator: std.mem.Allocator,
identity: Identity,
sink: *Activation.Sink,
options: Options,
stop: HANDLE,
changed: HANDLE,
thread: ?std.Thread = null,
state: std.atomic.Value(State) = .init(.created),
lock: std.os.windows.SRWLOCK = .{},
closing: bool = false,
queue: [32]Request = undefined,
head: usize = 0,
len: usize = 0,
retired: [256]Activation.Token = undefined,
retired_len: usize = 0,
results: [32]Outcome = undefined,
result_head: usize = 0,
result_len: usize = 0,
active: [64]?Active = @splat(null), // Worker MTA only.
active_serial: u64 = 0,
missing_backend_result: Result = .unavailable, // Worker MTA only.

pub fn create(allocator: std.mem.Allocator, identity: *const Identity, sink: *Activation.Sink, options: Options) !*Self {
    if (!identity.registration_verified) return error.UnregisteredIdentity;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    var owned = try identity.clone(allocator);
    errdefer owned.deinit();
    const stop = CreateEventW(null, 1, 0, null) orelse return error.EventFailed;
    errdefer _ = CloseHandle(stop);
    const changed = CreateEventW(null, 0, 0, null) orelse return error.EventFailed;
    errdefer _ = CloseHandle(changed);
    sink.retain();
    self.* = .{ .allocator = allocator, .identity = owned, .sink = sink, .options = options, .stop = stop, .changed = changed };
    return self;
}
pub fn start(self: *Self) !void {
    if (self.state.cmpxchgStrong(.created, .starting, .acq_rel, .acquire) != null) return error.AlreadyStarted;
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
        self.state.store(.unavailable, .release);
        return err;
    };
}
fn acquire(self: *Self) void {
    std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.lock);
}
fn unlock(self: *Self) void {
    std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.lock);
}

/// Copies/escapes caller strings before returning. Each token stays independent.
pub fn enqueue(self: *Self, token: Activation.Token, title: []const u8, body: []const u8) !void {
    if (self.options.activation_only) return error.ActivationOnly;
    if (self.state.load(.acquire) == .unavailable) return error.NativeUnavailable;
    const xml = try makeXml(self.allocator, token, title, body);
    errdefer self.allocator.free(xml);
    self.acquire();
    defer self.unlock();
    if (self.closing) return error.Closed;
    if (self.len == self.queue.len) return error.QueueFull;
    self.queue[(self.head + self.len) % self.queue.len] = .{ .token = token, .xml = xml };
    self.len += 1;
    _ = SetEvent(self.changed);
}
/// Independent idempotent retirement set, unaffected by the delivery queue.
/// Retry error.RetireQueueFull at the next GUI drain; never discard that intent.
/// Call for a closed/revoked target, never merely for a banner timeout.
pub fn retire(self: *Self, token: Activation.Token) !void {
    self.acquire();
    defer self.unlock();
    if (self.closing) return error.Closed;
    for (self.retired[0..self.retired_len]) |old| if (std.meta.eql(old, token)) return;
    if (self.retired_len == self.retired.len) return error.RetireQueueFull;
    self.retired[self.retired_len] = token;
    self.retired_len += 1;
    for (0..self.len) |index| {
        const request = &self.queue[(self.head + index) % self.queue.len];
        if (std.meta.eql(request.token, token)) request.cancelled = true;
    }
    _ = SetEvent(self.changed);
}
pub fn takeOutcome(self: *Self) ?Outcome {
    self.acquire();
    defer self.unlock();
    if (self.result_len == 0) return null;
    const value = self.results[self.result_head];
    self.result_head = (self.result_head + 1) % self.results.len;
    self.result_len -= 1;
    _ = SetEvent(self.changed);
    return value;
}
pub fn shutdown(self: *Self) void {
    self.acquire();
    self.closing = true;
    self.unlock();
    self.sink.close();
    self.state.store(.stopping, .release);
    _ = SetEvent(self.stop);
}
pub fn destroy(self: *Self) void {
    self.shutdown();
    if (self.thread) |thread| thread.join();
    for (0..self.len) |index| self.allocator.free(self.queue[(self.head + index) % self.queue.len].xml);
    self.identity.deinit();
    self.sink.release();
    _ = CloseHandle(self.changed);
    _ = CloseHandle(self.stop);
    self.allocator.destroy(self);
}

fn run(self: *Self) void {
    defer self.state.store(.stopped, .release);
    if (!self.options.activation_only) {
        @import("JumpList.zig").migratePinned(self.allocator, @import("../../../global.zig").io(), &self.identity) catch |err| {
            std.log.scoped(.win32_shell).warn("Pinned shortcut migration failed: {}", .{err});
        };
    }
    var api = Api.load() catch {
        self.unavailableLoop();
        return;
    };
    defer api.deinit();
    const initialized = api.initialize(1);
    if (initialized < 0) {
        self.missing_backend_result = bootstrapResult(initialized);
        self.unavailableLoop();
        return;
    }
    defer api.uninitialize();
    var registration = Activation.Registration.start(&self.identity, self.sink) catch {
        self.missing_backend_result = .failed;
        self.unavailableLoop();
        return;
    };
    defer registration.deinit();
    var backend: ?Backend = if (self.options.activation_only) null else Backend.init(self.allocator, &api, &self.identity) catch |err| failed: {
        self.missing_backend_result = switch (err) {
            error.NativeUnavailable => .unavailable,
            error.PolicyDenied => .suppressed,
            else => .failed,
        };
        break :failed null;
    };
    defer if (backend) |*native| native.deinit();
    defer for (&self.active) |*entry| releaseActive(entry);
    self.state.store(if (backend != null or self.options.activation_only or self.missing_backend_result != .unavailable) .ready else .unavailable, .release);
    self.sink.wake();
    const handles = [_]HANDLE{ self.stop, self.changed };
    while (WaitForSingleObject(self.stop, 0) == 258) {
        self.drain(if (backend) |*native| native else null);
        if (WaitForMultipleObjects(handles.len, &handles, 0, 0xffffffff) != 1) break;
    }
}
fn unavailableLoop(self: *Self) void {
    self.state.store(if (self.missing_backend_result == .unavailable) .unavailable else .ready, .release);
    self.sink.wake();
    const handles = [_]HANDLE{ self.stop, self.changed };
    while (WaitForSingleObject(self.stop, 0) == 258) {
        self.drain(null);
        if (WaitForMultipleObjects(handles.len, &handles, 0, 0xffffffff) != 1) break;
    }
}
fn drain(self: *Self, backend: ?*Backend) void {
    while (WaitForSingleObject(self.stop, 0) == 258) {
        self.drainRetired();
        self.acquire();
        // A successful delivery can also evict one old activation delegate.
        if (self.len == 0 or self.result_len + 2 > self.results.len) {
            self.unlock();
            return;
        }
        const request = self.queue[self.head];
        self.head = (self.head + 1) % self.queue.len;
        self.len -= 1;
        self.unlock();
        const outcome: Outcome = deliver: {
            defer self.allocator.free(request.xml);
            if (request.cancelled) break :deliver .{ .token = request.token, .result = .cancelled };
            const native = backend orelse break :deliver .{ .token = request.token, .result = self.missing_backend_result };
            break :deliver self.show(native, request.token, request.xml);
        };
        self.acquire();
        self.results[(self.result_head + self.result_len) % self.results.len] = outcome;
        self.result_len += 1;
        self.unlock();
        self.sink.wake();
    }
}
fn drainRetired(self: *Self) void {
    var tokens: [256]Activation.Token = undefined;
    self.acquire();
    const count = self.retired_len;
    @memcpy(tokens[0..count], self.retired[0..count]);
    self.retired_len = 0;
    self.unlock();
    for (tokens[0..count]) |token| for (&self.active) |*entry| {
        if (entry.*) |active| if (std.meta.eql(active.token, token)) releaseActive(entry);
    };
    if (count != 0) self.sink.wake(); // Let the GUI retry an overflowed retire.
}

/// Worker reserves two outcome slots before this call. Action Center tokens
/// remain valid through banner dismissal, up to a bounded oldest-first eviction.
fn reserveActive(self: *Self) *?Active {
    var oldest: usize = 0;
    for (&self.active, 0..) |*entry, index| {
        const value = entry.* orelse return entry;
        if (value.serial < self.active[oldest].?.serial) oldest = index;
    }
    const token = self.active[oldest].?.token;
    releaseActive(&self.active[oldest]);
    self.acquire();
    defer self.unlock();
    std.debug.assert(self.result_len < self.results.len);
    self.results[(self.result_head + self.result_len) % self.results.len] = .{ .token = token, .result = .evicted };
    self.result_len += 1;
    return &self.active[oldest];
}
fn releaseActive(entry: *?Active) void {
    const active = entry.* orelse return;
    entry.* = null;
    _ = Identity.method(*const fn (*Interface, EventToken) callconv(.winapi) HRESULT, active.toast, 12)(active.toast, active.event);
    Identity.release(active.handler);
    Identity.release(active.toast);
}
fn show(self: *Self, backend: *Backend, token: Activation.Token, xml: []const u8) Outcome {
    var setting: i32 = 0;
    const settings_hr = Identity.method(*const fn (*Interface, *i32) callconv(.winapi) HRESULT, backend.notifier, 8)(backend.notifier, &setting);
    if (settings_hr < 0) return .{ .token = token, .result = .failed, .hresult = settings_hr };
    if (setting != 0) return .{ .token = token, .result = .suppressed };
    if (self.active_serial == std.math.maxInt(u64)) return .{ .token = token, .result = .failed };
    const slot = self.reserveActive();
    const toast = backend.createToast(xml) catch return .{ .token = token, .result = .failed, .hresult = backend.last_hresult };
    var retained = false;
    defer if (!retained) Identity.release(toast);
    const handler = Activation.WarmHandler.create(self.sink, token) catch return .{ .token = token, .result = .failed };
    defer if (!retained) Identity.release(&handler.interface);
    var event: EventToken = .{};
    const subscribed = Identity.method(*const fn (*Interface, *Interface, *EventToken) callconv(.winapi) HRESULT, toast, 11)(toast, &handler.interface, &event);
    if (subscribed < 0) return .{ .token = token, .result = .failed, .hresult = subscribed };
    const shown = Identity.method(*const fn (*Interface, *Interface) callconv(.winapi) HRESULT, backend.notifier, 6)(backend.notifier, toast);
    if (shown < 0) {
        _ = Identity.method(*const fn (*Interface, EventToken) callconv(.winapi) HRESULT, toast, 12)(toast, event);
        return .{ .token = token, .result = .failed, .hresult = shown };
    }
    self.active_serial += 1;
    slot.* = .{ .toast = toast, .handler = &handler.interface, .event = event, .token = token, .serial = self.active_serial };
    retained = true;
    // Focus Assist/DND may suppress a successful Show. Do not infer visibility,
    // synthesize another backend, or revoke its Action Center activation token.
    return .{ .token = token, .result = .accepted, .hresult = shown };
}

pub fn makeXml(alloc: std.mem.Allocator, token: Activation.Token, title: []const u8, body: []const u8) ![]u8 {
    if (title.len > max_title_bytes or body.len > max_body_bytes or !std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(body)) return error.InvalidText;
    var token_buffer: [Activation.token_length]u8 = undefined;
    const launch = try Activation.encode(token, &token_buffer);
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try output.writer.print("<toast activationType=\"foreground\" launch=\"{s}\"><visual><binding template=\"ToastGeneric\"><text>", .{launch});
    try escape(&output.writer, title);
    try output.writer.writeAll("</text><text>");
    try escape(&output.writer, body);
    try output.writer.writeAll("</text></binding></visual></toast>");
    return try output.toOwnedSlice();
}
fn escape(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        39 => try writer.writeAll("&apos;"),
        0...8, 11, 12, 14...31 => try writer.writeAll("&#xfffd;"),
        else => try writer.writeByte(byte),
    };
}

const Api = struct {
    library: *anyopaque,
    initialize: *const fn (u32) callconv(.winapi) HRESULT,
    uninitialize: *const fn () callconv(.winapi) void,
    factory: *const fn (HSTRING, *const GUID, *?*Interface) callconv(.winapi) HRESULT,
    activate: *const fn (HSTRING, *?*Interface) callconv(.winapi) HRESULT,
    create_string: *const fn ([*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT,
    delete_string: *const fn (HSTRING) callconv(.winapi) HRESULT,
    fn load() !Api {
        const library = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse return error.NativeUnavailable;
        errdefer _ = FreeLibrary(library);
        var self: Api = undefined;
        self.library = library;
        inline for (.{ .{ "initialize", "RoInitialize" }, .{ "uninitialize", "RoUninitialize" }, .{ "factory", "RoGetActivationFactory" }, .{ "activate", "RoActivateInstance" }, .{ "create_string", "WindowsCreateString" }, .{ "delete_string", "WindowsDeleteString" } }) |entry| {
            @field(self, entry[0]) = @ptrCast(GetProcAddress(library, entry[1]) orelse return error.NativeUnavailable);
        }
        return self;
    }
    fn deinit(self: *Api) void {
        _ = FreeLibrary(self.library);
    }
    fn string(self: *Api, alloc: std.mem.Allocator, value: []const u8) !HSTRING {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
        defer alloc.free(wide);
        var result: HSTRING = null;
        try checkBootstrap(self.create_string(wide.ptr, @intCast(wide.len), &result));
        return result;
    }
};
const Backend = struct {
    allocator: std.mem.Allocator,
    api: *Api,
    notifier: *Interface,
    factory: *Interface,
    last_hresult: HRESULT = 0,
    fn check(self: *Backend, hr: HRESULT) !void {
        self.last_hresult = hr;
        if (hr < 0) return error.NativeFailed;
    }
    fn init(alloc: std.mem.Allocator, api: *Api, identity: *const Identity) !Backend {
        const manager_name = try api.string(alloc, "Windows.UI.Notifications.ToastNotificationManager");
        defer _ = api.delete_string(manager_name);
        var manager: ?*Interface = null;
        try checkBootstrap(api.factory(manager_name, &iid_manager, &manager));
        if (manager == null) return error.NativeFailed;
        defer Identity.release(manager.?);
        const aumid = try api.string(alloc, identity.aumid_utf8);
        defer _ = api.delete_string(aumid);
        var notifier: ?*Interface = null;
        try checkBootstrap(Identity.method(*const fn (*Interface, HSTRING, *?*Interface) callconv(.winapi) HRESULT, manager.?, 7)(manager.?, aumid, &notifier));
        if (notifier == null) return error.NativeFailed;
        errdefer Identity.release(notifier.?);
        const toast_name = try api.string(alloc, "Windows.UI.Notifications.ToastNotification");
        defer _ = api.delete_string(toast_name);
        var factory: ?*Interface = null;
        try checkBootstrap(api.factory(toast_name, &iid_toast_factory, &factory));
        if (factory == null) return error.NativeFailed;
        return .{ .allocator = alloc, .api = api, .notifier = notifier.?, .factory = factory.? };
    }
    fn deinit(self: *Backend) void {
        Identity.release(self.factory);
        Identity.release(self.notifier);
    }
    fn createToast(self: *Backend, xml: []const u8) !*Interface {
        const class = try self.api.string(self.allocator, "Windows.Data.Xml.Dom.XmlDocument");
        defer _ = self.api.delete_string(class);
        var document: ?*Interface = null;
        try self.check(self.api.activate(class, &document));
        const doc = document orelse return error.NativeFailed;
        defer Identity.release(doc);
        const io = try Identity.query(doc, &iid_xml_io);
        defer Identity.release(io);
        const text = try self.api.string(self.allocator, xml);
        defer _ = self.api.delete_string(text);
        try self.check(Identity.method(*const fn (*Interface, HSTRING) callconv(.winapi) HRESULT, io, 6)(io, text));
        const xml_document = try Identity.query(doc, &iid_xml_document);
        defer Identity.release(xml_document);
        var toast: ?*Interface = null;
        try self.check(Identity.method(*const fn (*Interface, *Interface, *?*Interface) callconv(.winapi) HRESULT, self.factory, 6)(self.factory, xml_document, &toast));
        return toast orelse return error.NativeFailed;
    }
};
const iid_manager = Identity.guid("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
fn bootstrapResult(hr: HRESULT) Result {
    return switch (@as(u32, @bitCast(hr))) {
        0x80040154, 0x80004002 => .unavailable, // Missing class/interface.
        0x80070005 => .suppressed, // Policy/access denial is never a balloon fallback.
        else => .failed,
    };
}
fn checkBootstrap(hr: HRESULT) !void {
    if (hr >= 0) return;
    return switch (bootstrapResult(hr)) {
        .unavailable => error.NativeUnavailable,
        .suppressed => error.PolicyDenied,
        else => error.NativeFailed,
    };
}
const iid_toast_factory = Identity.guid("04124b20-82c6-4229-b109-fd9ed4662b53");
const iid_xml_io = Identity.guid("6cd0e74e-ee65-4489-9ebf-ca43e87ba637");
const iid_xml_document = Identity.guid("f7f3a506-1e87-42d6-bcfb-b8c809fa5494");
extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(?*const anyopaque, i32, i32, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) i32;
extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const HANDLE, i32, u32) callconv(.winapi) u32;

test "toast XML escapes terminal text without interpreting it as actions" {
    const testing = std.testing;
    const xml = try makeXml(testing.allocator, .{ .host_epoch = 1, .nonce = 2 }, "A<&\"", "</text><actions>bad</actions>\x00");
    defer testing.allocator.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "A&lt;&amp;&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "&lt;actions&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<actions>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "&#xfffd;") != null);
}

test "bootstrap access denial and general failures never permit legacy notification fallback" {
    try std.testing.expectError(error.PolicyDenied, checkBootstrap(@bitCast(@as(u32, 0x80070005))));
    try std.testing.expectError(error.NativeFailed, checkBootstrap(@bitCast(@as(u32, 0x80004005))));
    try std.testing.expectError(error.NativeUnavailable, checkBootstrap(@bitCast(@as(u32, 0x80040154))));
    try std.testing.expect(!mayUseLegacy(bootstrapResult(@bitCast(@as(u32, 0x80070005)))));
}
test "WinRT callable entrypoints compile without loading or publishing a notification" {
    const functions = .{ &create, &start, &enqueue, &takeOutcome, &retire, &shutdown, &destroy };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}

/// Only a genuinely unavailable native backend permits the legacy backend.
/// Accepted is not visible: DND/Focus Assist may legitimately hide the banner.
pub fn mayUseLegacy(result: Result) bool {
    return result == .unavailable;
}

test "native notifier disabled policy suppresses without constructing or showing a toast" {
    const testing = std.testing;
    const Fake = struct {
        interface: Interface,
        fn setting(_: *Interface, value: *i32) callconv(.winapi) HRESULT {
            value.* = 1;
            return 0;
        }
        fn forbidden(_: *Interface) callconv(.winapi) HRESULT {
            @panic("disabled notifier must not call Show");
        }
    };
    var vtable: [9]*const anyopaque = @splat(@ptrCast(&Fake.forbidden));
    vtable[8] = @ptrCast(&Fake.setting);
    var notifier: Fake = .{ .interface = .{ .vtable = &vtable } };
    var backend: Backend = .{ .allocator = testing.allocator, .api = undefined, .notifier = &notifier.interface, .factory = undefined };
    var worker: Self = undefined;
    const outcome = worker.show(&backend, .{ .host_epoch = 1, .nonce = 2 }, "not parsed");
    try testing.expectEqual(Result.suppressed, outcome.result);
    try testing.expect(!mayUseLegacy(outcome.result));
    try testing.expect(!mayUseLegacy(.accepted));
    try testing.expect(!mayUseLegacy(.failed));
}

test "retirement survives a full delivery queue and cancels queued notification idempotently" {
    var identity = try Identity.init(std.testing.allocator, .installed, "C:/App/ghostty.exe", true);
    defer identity.deinit();
    const sink = try Activation.Sink.create(std.testing.allocator, &identity, null, 0);
    defer sink.release();
    const worker = try create(std.testing.allocator, &identity, sink, .{});
    defer worker.destroy();
    for (1..33) |index| try worker.enqueue(.{ .host_epoch = 1, .nonce = index }, "title", "body");
    try std.testing.expectError(error.QueueFull, worker.enqueue(.{ .host_epoch = 1, .nonce = 33 }, "title", "body"));
    const token: Activation.Token = .{ .host_epoch = 1, .nonce = 1 };
    try worker.retire(token);
    try worker.retire(token);
    try std.testing.expectEqual(@as(usize, 1), worker.retired_len);
    try std.testing.expect(worker.queue[worker.head].cancelled);
    // Cancellation stays on the request after the independent set is drained.
    worker.drainRetired();
    try std.testing.expect(worker.queue[worker.head].cancelled);
    try std.testing.expectEqual(@as(usize, 0), worker.retired_len);
    for (1..257) |index| try worker.retire(.{ .host_epoch = 1, .nonce = index });
    try std.testing.expectError(error.RetireQueueFull, worker.retire(.{ .host_epoch = 1, .nonce = 257 }));
    worker.drainRetired();
    try worker.retire(.{ .host_epoch = 1, .nonce = 257 });
}

test "active delegate eviction remains usable beyond 64 notifications and reports every eviction" {
    const Fake = struct {
        fn release(_: *Interface) callconv(.winapi) u32 {
            return 1;
        }
        fn remove(_: *Interface, _: EventToken) callconv(.winapi) HRESULT {
            return 0;
        }
    };
    var table: [13]*const anyopaque = @splat(@ptrCast(&Fake.release));
    table[12] = @ptrCast(&Fake.remove);
    var object: Interface = .{ .vtable = &table };
    var identity = try Identity.init(std.testing.allocator, .installed, "C:/App/ghostty.exe", true);
    defer identity.deinit();
    const sink = try Activation.Sink.create(std.testing.allocator, &identity, null, 0);
    defer sink.release();
    const worker = try create(std.testing.allocator, &identity, sink, .{});
    defer worker.destroy();
    defer for (&worker.active) |*entry| releaseActive(entry);
    for (1..1025) |index| {
        const slot = worker.reserveActive();
        slot.* = .{ .toast = &object, .handler = &object, .event = .{}, .token = .{ .host_epoch = 1, .nonce = index }, .serial = index };
        if (index > 64) {
            const outcome = worker.takeOutcome().?;
            try std.testing.expectEqual(Result.evicted, outcome.result);
            try std.testing.expectEqual(@as(u128, index - 64), outcome.token.nonce);
        } else try std.testing.expect(worker.takeOutcome() == null);
    }
}
