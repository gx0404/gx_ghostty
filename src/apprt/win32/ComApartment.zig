const Self = @This();
const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32_com);

owner_thread: ?u32 = null,
com_initialized: bool = false,
ole_initialized: bool = false,
last_hresult: ?w32.HRESULT = null,
phase: Phase = .ready,

const Phase = enum { ready, draining, closing, closed };
pub const Error = error{ WrongThread, Closed, ComInitializationFailed, OleInitializationFailed };

/// Binds a lazy COM/OLE owner to the current GUI thread. Do not copy an
/// initialized owner or use it from another thread.
pub fn init() Self {
    return .{ .owner_thread = w32.GetCurrentThreadId() };
}

/// Holds one STA reference after S_OK or S_FALSE. Repeated calls do not
/// initialize COM again; a failed HRESULT never owns a reference.
pub fn ensureCom(self: *Self) Error!void {
    try self.ensureComWith(NativeApi{});
}

/// Adds one OLE reference while retaining the owner's COM reference.
pub fn ensureOle(self: *Self) Error!void {
    try self.ensureOleWith(NativeApi{});
}

/// Rejects new consumers before teardown while keeping existing references
/// alive until `deinit` runs after the consumers have released their objects.
pub fn beginClose(self: *Self) Error!void {
    try self.beginCloseWith(NativeApi{});
}

/// GUI-thread check for consumers that must stop before their caches are freed.
pub fn isClosing(self: *const Self) bool {
    return self.phase != .ready;
}

/// After all consumers are released, closes OLE before COM on the bound
/// thread. Reentrant or repeated closure is a no-op; initialization stays closed.
pub fn deinit(self: *Self) Error!void {
    try self.deinitWith(NativeApi{});
}

fn checkOwner(self: *const Self, api: anytype) Error!void {
    if (self.owner_thread == null or self.owner_thread.? != api.currentThreadId()) return error.WrongThread;
}

fn ensureComWith(self: *Self, api: anytype) Error!void {
    try self.checkOwner(api);
    if (self.phase != .ready) return error.Closed;
    if (self.com_initialized) return;
    const hr = api.initializeCom();
    self.last_hresult = hr;
    if (hr < 0) return error.ComInitializationFailed;
    self.com_initialized = true;
}

fn ensureOleWith(self: *Self, api: anytype) Error!void {
    try self.ensureComWith(api);
    if (self.ole_initialized) return;
    const hr = api.initializeOle();
    self.last_hresult = hr;
    if (hr < 0) return error.OleInitializationFailed;
    self.ole_initialized = true;
}

fn beginCloseWith(self: *Self, api: anytype) Error!void {
    if (self.owner_thread == null) return;
    try self.checkOwner(api);
    if (self.phase == .ready) self.phase = .draining;
}

fn deinitWith(self: *Self, api: anytype) Error!void {
    if (self.owner_thread == null) return;
    try self.checkOwner(api);
    if (self.phase == .closing or self.phase == .closed) return;
    self.phase = .closing;
    if (self.ole_initialized) {
        self.ole_initialized = false;
        api.uninitializeOle();
    }
    if (self.com_initialized) {
        self.com_initialized = false;
        api.uninitializeCom();
    }
    self.phase = .closed;
}

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) w32.HRESULT;
extern "ole32" fn OleUninitialize() callconv(.winapi) void;

const NativeApi = struct {
    fn currentThreadId(_: NativeApi) u32 {
        return w32.GetCurrentThreadId();
    }

    fn initializeCom(_: NativeApi) w32.HRESULT {
        const hr = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
        log.debug("GUI COM 初始化，thread={} hr={}", .{ w32.GetCurrentThreadId(), hr });
        return hr;
    }

    fn initializeOle(_: NativeApi) w32.HRESULT {
        const hr = OleInitialize(null);
        log.debug("GUI OLE 初始化，thread={} hr={}", .{ w32.GetCurrentThreadId(), hr });
        return hr;
    }

    fn uninitializeOle(_: NativeApi) void {
        OleUninitialize();
        log.debug("GUI OLE 已释放，thread={}", .{w32.GetCurrentThreadId()});
    }

    fn uninitializeCom(_: NativeApi) void {
        w32.CoUninitialize();
        log.debug("GUI COM 已释放，thread={}", .{w32.GetCurrentThreadId()});
    }
};

const Event = enum { com_init, ole_init, ole_uninit, com_uninit };
const MockApi = struct {
    thread_id: u32 = 1,
    com_result: w32.HRESULT = 0,
    ole_result: w32.HRESULT = 0,
    calls: [16]Event = undefined,
    count: usize = 0,
    reenter: ?*Self = null,
    reentry_count: usize = 0,
    reentry_error: ?Error = null,
    reentry_cleanup_failed: bool = false,

    fn currentThreadId(self: *const MockApi) u32 {
        return self.thread_id;
    }

    fn record(self: *MockApi, event: Event) void {
        self.calls[self.count] = event;
        self.count += 1;
    }

    fn initializeCom(self: *MockApi) w32.HRESULT {
        self.record(.com_init);
        return self.com_result;
    }

    fn initializeOle(self: *MockApi) w32.HRESULT {
        self.record(.ole_init);
        return self.ole_result;
    }

    fn uninitializeOle(self: *MockApi) void {
        self.record(.ole_uninit);
        self.tryReentry();
    }

    fn uninitializeCom(self: *MockApi) void {
        self.record(.com_uninit);
        self.tryReentry();
    }

    fn tryReentry(self: *MockApi) void {
        if (self.reenter) |apartment| {
            self.reentry_count += 1;
            apartment.ensureOleWith(self) catch |err| {
                self.reentry_error = err;
            };
            apartment.deinitWith(self) catch {
                self.reentry_cleanup_failed = true;
            };
        }
    }

    fn expectCalls(self: *const MockApi, expected: []const Event) !void {
        try std.testing.expectEqualSlices(Event, expected, self.calls[0..self.count]);
    }
};

test "successful COM initialization balances S_OK and S_FALSE exactly once" {
    for ([_]w32.HRESULT{ 0, 1 }) |result| {
        var api: MockApi = .{ .com_result = result };
        var apartment: Self = .{ .owner_thread = api.thread_id };
        try apartment.ensureComWith(&api);
        try apartment.ensureComWith(&api);
        try std.testing.expect(apartment.com_initialized);
        try std.testing.expectEqual(@as(?w32.HRESULT, result), apartment.last_hresult);
        try apartment.deinitWith(&api);
        try apartment.deinitWith(&api);
        try std.testing.expect(!apartment.com_initialized);
        try std.testing.expectError(error.Closed, apartment.ensureComWith(&api));
        try api.expectCalls(&.{ .com_init, .com_uninit });
    }
}

test "failed COM initialization is retained and never uninitialized" {
    var api: MockApi = .{ .com_result = -1 };
    var apartment: Self = .{ .owner_thread = api.thread_id };
    try std.testing.expectError(error.ComInitializationFailed, apartment.ensureOleWith(&api));
    try std.testing.expect(!apartment.com_initialized);
    try std.testing.expect(!apartment.ole_initialized);
    try std.testing.expectEqual(@as(?w32.HRESULT, -1), apartment.last_hresult);
    try apartment.deinitWith(&api);
    try api.expectCalls(&.{.com_init});
}

test "OLE failure preserves COM ownership and a successful retry owns one OLE reference" {
    var api: MockApi = .{ .ole_result = -1 };
    var apartment: Self = .{ .owner_thread = api.thread_id };
    try std.testing.expectError(error.OleInitializationFailed, apartment.ensureOleWith(&api));
    try std.testing.expect(apartment.com_initialized);
    try std.testing.expect(!apartment.ole_initialized);
    try std.testing.expectEqual(@as(?w32.HRESULT, -1), apartment.last_hresult);
    api.ole_result = 1;
    try apartment.ensureOleWith(&api);
    try apartment.ensureOleWith(&api);
    try apartment.deinitWith(&api);
    try api.expectCalls(&.{ .com_init, .ole_init, .ole_init, .ole_uninit, .com_uninit });
}

test "OLE failure alone is not balanced with OleUninitialize" {
    var api: MockApi = .{ .ole_result = -1 };
    var apartment: Self = .{ .owner_thread = api.thread_id };
    try std.testing.expectError(error.OleInitializationFailed, apartment.ensureOleWith(&api));
    try apartment.deinitWith(&api);
    try api.expectCalls(&.{ .com_init, .ole_init, .com_uninit });
}

test "wrong thread and unbound owners cannot initialize or release apartments" {
    var api: MockApi = .{};
    var unbound: Self = .{};
    try std.testing.expectError(error.WrongThread, unbound.ensureComWith(&api));
    try unbound.deinitWith(&api);
    try api.expectCalls(&.{});
    var apartment: Self = .{ .owner_thread = api.thread_id };
    try apartment.ensureComWith(&api);
    api.thread_id = 2;
    try std.testing.expectError(error.WrongThread, apartment.ensureComWith(&api));
    try std.testing.expectError(error.WrongThread, apartment.ensureOleWith(&api));
    try std.testing.expectError(error.WrongThread, apartment.deinitWith(&api));
    try std.testing.expect(apartment.com_initialized);
    try api.expectCalls(&.{.com_init});
    api.thread_id = 1;
    try apartment.deinitWith(&api);
    try api.expectCalls(&.{ .com_init, .com_uninit });
}

test "consumer shutdown rejects new initialization while retaining live references" {
    var api: MockApi = .{};
    var apartment: Self = .{ .owner_thread = api.thread_id };
    try apartment.ensureOleWith(&api);
    api.thread_id = 2;
    try std.testing.expectError(error.WrongThread, apartment.beginCloseWith(&api));
    api.thread_id = 1;
    try apartment.ensureComWith(&api);
    try apartment.beginCloseWith(&api);
    try apartment.beginCloseWith(&api);
    try std.testing.expect(apartment.com_initialized and apartment.ole_initialized);
    try std.testing.expectError(error.Closed, apartment.ensureComWith(&api));
    try std.testing.expectError(error.Closed, apartment.ensureOleWith(&api));
    try api.expectCalls(&.{ .com_init, .ole_init });
    try apartment.deinitWith(&api);
    try api.expectCalls(&.{ .com_init, .ole_init, .ole_uninit, .com_uninit });
}

test "shutdown rejects initialization and is idempotent during COM reentry" {
    var api: MockApi = .{};
    var apartment: Self = .{ .owner_thread = api.thread_id };
    try apartment.ensureOleWith(&api);
    api.reenter = &apartment;
    try apartment.deinitWith(&api);
    try apartment.deinitWith(&api);
    try std.testing.expectEqual(@as(usize, 2), api.reentry_count);
    try std.testing.expectEqual(@as(?Error, error.Closed), api.reentry_error);
    try std.testing.expect(!api.reentry_cleanup_failed);
    try std.testing.expect(!apartment.ole_initialized);
    try std.testing.expect(!apartment.com_initialized);
    try api.expectCalls(&.{ .com_init, .ole_init, .ole_uninit, .com_uninit });
}

extern "ole32" fn CoGetApartmentType(kind: *i32, qualifier: *i32) callconv(.winapi) w32.HRESULT;

// SDK APTTYPE/APTTYPEQUALIFIER values. Only MTA + IMPLICIT_MTA means
// this thread inherited an apartment without acquiring a COM reference:
// https://learn.microsoft.com/windows/win32/api/objidl/ne-objidl-apttypequalifier
const NativeApartmentState = struct {
    hr: w32.HRESULT,
    kind: i32 = -1,
    qualifier: i32 = -1,

    const NoReference = enum { not_initialized, implicit_mta };
    const not_initialized: w32.HRESULT = @bitCast(@as(u32, 0x800401f0));

    fn query() NativeApartmentState {
        var state: NativeApartmentState = .{ .hr = undefined };
        state.hr = CoGetApartmentType(&state.kind, &state.qualifier);
        return state;
    }

    fn noReference(self: NativeApartmentState) ?NoReference {
        // Failed queries do not define the output kind/qualifier.
        if (self.hr == not_initialized) return .not_initialized;
        if (self.hr == 0 and self.kind == 1 and self.qualifier == 1) return .implicit_mta;
        return null;
    }

    fn expectExplicit(self: NativeApartmentState, mta: bool) !void {
        try std.testing.expectEqual(@as(w32.HRESULT, 0), self.hr);
        try std.testing.expectEqual(@as(i32, 0), self.qualifier);
        if (mta) {
            try std.testing.expectEqual(@as(i32, 1), self.kind);
        } else {
            try std.testing.expect(self.kind == 0 or self.kind == 3);
        }
        try std.testing.expectEqual(@as(?NoReference, null), self.noReference());
    }
};

const NativeScenario = struct {
    mode: enum { fresh, existing_sta, existing_mta },
    failure: ?anyerror = null,
    require_implicit_mta: bool = false,

    fn run(self: *NativeScenario) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }

    fn check(self: *NativeScenario) !void {
        const testing = std.testing;
        const changed_mode: w32.HRESULT = @as(i32, @bitCast(@as(u32, 0x80010106)));
        const initial = NativeApartmentState.query().noReference() orelse
            return error.UnexpectedExplicitApartment;
        if (self.require_implicit_mta) {
            try testing.expectEqual(NativeApartmentState.NoReference.implicit_mta, initial);
        }
        var external_initialized = false;
        defer if (external_initialized) w32.CoUninitialize();
        var external_state: ?NativeApartmentState = null;
        if (self.mode != .fresh) {
            const flags: u32 = if (self.mode == .existing_sta) w32.COINIT_APARTMENTTHREADED else 0;
            const hr = w32.CoInitializeEx(null, flags);
            external_initialized = hr >= 0;
            try testing.expectEqual(@as(w32.HRESULT, 0), hr);
            external_state = NativeApartmentState.query();
            try external_state.?.expectExplicit(self.mode == .existing_mta);
        }
        var apartment = Self.init();
        defer apartment.deinit() catch {};
        if (self.mode == .existing_mta) {
            try testing.expectError(error.ComInitializationFailed, apartment.ensureCom());
            try testing.expectEqual(@as(?w32.HRESULT, changed_mode), apartment.last_hresult);
        } else {
            try apartment.ensureCom();
            try testing.expectEqual(@as(?w32.HRESULT, if (external_initialized) 1 else 0), apartment.last_hresult);
            try apartment.ensureOle();
            try NativeApartmentState.query().expectExplicit(false);
        }
        try apartment.beginClose();
        try apartment.deinit();
        if (external_state) |expected| {
            // Releasing owned references must preserve the external reference,
            // including explicit MTA (NONE), never merely an implicit MTA.
            const remaining = NativeApartmentState.query();
            try remaining.expectExplicit(self.mode == .existing_mta);
            try testing.expectEqualDeep(expected, remaining);
            w32.CoUninitialize();
            external_initialized = false;
        }
        // After every reference owned by this scenario is released, the same
        // no-reference state must be restored; an arbitrary S_OK is not enough.
        try testing.expectEqual(@as(?NativeApartmentState.NoReference, initial), NativeApartmentState.query().noReference());
    }
};

// Keeps a process MTA alive without initializing COM on the scenario thread.
// The ready/release handshake makes this independent of UIA and test ordering.
const NativeMtaHolder = struct {
    ready: w32.HANDLE,
    release: w32.HANDLE,
    result: w32.HRESULT = -1,

    fn run(self: *NativeMtaHolder) void {
        self.result = w32.CoInitializeEx(null, 0);
        defer if (self.result >= 0) w32.CoUninitialize();
        _ = w32.SetEvent(self.ready);
        _ = w32.WaitForSingleObject(self.release, w32.INFINITE);
    }
};

fn runNativeThread(mode: @FieldType(NativeScenario, "mode"), require_implicit_mta: bool) !void {
    var scenario: NativeScenario = .{ .mode = mode, .require_implicit_mta = require_implicit_mta };
    const thread = try std.Thread.spawn(.{}, NativeScenario.run, .{&scenario});
    thread.join();
    if (scenario.failure) |err| return err;
}

fn runNativeScenario(mode: @FieldType(NativeScenario, "mode")) !void {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    // Reject explicit STA/MTA, neutral apartments, and non-S_OK queries even
    // when their output fields happen to resemble an implicit MTA.
    for ([_]NativeApartmentState{
        .{ .hr = 0, .kind = 0, .qualifier = 0 }, // STA
        .{ .hr = 0, .kind = 3, .qualifier = 0 }, // MAINSTA
        .{ .hr = 0, .kind = 1, .qualifier = 0 }, // Explicit MTA
        .{ .hr = 0, .kind = 2, .qualifier = 4 }, // NA on implicit MTA
        .{ .hr = 0, .kind = 0, .qualifier = 1 }, // Wrong kind
        .{ .hr = 0, .kind = 1, .qualifier = 2 }, // Wrong qualifier
        .{ .hr = 1, .kind = 1, .qualifier = 1 }, // S_FALSE is not S_OK
        .{ .hr = @bitCast(@as(u32, 0x80004005)), .kind = 1, .qualifier = 1 }, // E_FAIL
    }) |state| {
        try std.testing.expectEqual(@as(?NativeApartmentState.NoReference, null), state.noReference());
    }
    const uninitialized: NativeApartmentState = .{ .hr = NativeApartmentState.not_initialized };
    try std.testing.expectEqual(NativeApartmentState.NoReference.not_initialized, uninitialized.noReference().?);
    try runNativeThread(mode, false);

    const ready = w32.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = w32.CloseHandle(ready);
    const release = w32.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = w32.CloseHandle(release);
    var holder: NativeMtaHolder = .{ .ready = ready, .release = release };
    const thread = try std.Thread.spawn(.{}, NativeMtaHolder.run, .{&holder});
    defer {
        _ = w32.SetEvent(release);
        thread.join();
    }
    try std.testing.expectEqual(w32.WAIT_OBJECT_0, w32.WaitForSingleObject(ready, 5000));
    try std.testing.expectEqual(@as(w32.HRESULT, 0), holder.result);
    try runNativeThread(mode, true);
}

test "native fresh STA and OLE are both released on their owner thread" {
    try runNativeScenario(.fresh);
}

test "native preexisting STA remains initialized after releasing owned references" {
    try runNativeScenario(.existing_sta);
}

test "native incompatible MTA is neither changed nor released" {
    try runNativeScenario(.existing_mta);
}
