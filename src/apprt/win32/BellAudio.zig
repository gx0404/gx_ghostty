const std = @import("std");
const Allocator = std.mem.Allocator;
const wav = @import("bell_wav.zig");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32);

pub const Player = Worker(Native);

pub fn create() !*Player {
    return Player.create(std.heap.page_allocator, .{});
}

const Request = struct {
    path: ?[]u8,
    volume: f64,

    fn deinit(self: Request, alloc: Allocator) void {
        if (self.path) |path| alloc.free(path);
    }
};

const Cache = struct {
    path: []u8,
    source: []u8,
    volume: f64,
    wave: wav.Wave,

    fn deinit(self: Cache, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.source);
        self.wave.deinit(alloc);
    }

    fn matches(self: Cache, path: []const u8, volume: f64, bytes: []const u8) bool {
        return self.volume == volume and std.mem.eql(u8, self.path, path) and std.mem.eql(u8, self.source, bytes);
    }
};

fn State(comptime Backend: type) type {
    return struct {
        const Self = @This();
        backend: Backend,
        cache: ?Cache = null,

        fn prepare(self: *Self, alloc: Allocator, io: std.Io, path: []const u8, volume: f64) !void {
            std.debug.assert(!self.backend.active());
            const source = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(wav.max_file_bytes + 1));
            var keep_source = false;
            defer if (!keep_source) alloc.free(source);
            if (self.cache) |cache| {
                if (cache.matches(path, volume, source)) return;
            }
            const wave = try wav.decode(alloc, source, volume);
            errdefer wave.deinit(alloc);
            const copy = try alloc.dupe(u8, path);
            if (self.cache) |cache| cache.deinit(alloc);
            self.cache = .{ .path = copy, .source = source, .volume = volume, .wave = wave };
            keep_source = true;
        }

        fn clear(self: *Self, alloc: Allocator) void {
            std.debug.assert(!self.backend.isBorrowed());
            if (self.cache) |cache| cache.deinit(alloc);
            self.cache = null;
        }
    };
}

pub const shutdown_wait_ms: u32 = 100;
const retry_wait_ms: u32 = 250;

fn Worker(comptime Backend: type) type {
    return struct {
        const Self = @This();
        alloc: Allocator,
        owned_io: std.Io.Threaded,
        thread: std.Thread = undefined,
        control: std.os.windows.SRWLOCK = .{},
        wake_event: w32.HANDLE,
        finished_event: w32.HANDLE,
        refs: std.atomic.Value(usize) = .init(2),
        stopping: std.atomic.Value(bool) = .init(false),
        faulted: std.atomic.Value(bool) = .init(false),
        issue: std.atomic.Value(u64) = .init(0),
        reported: std.atomic.Value(u64) = .init(0),
        cache_present: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(usize) = .init(0),
        completed: std.atomic.Value(usize) = .init(0),
        pending: ?Request = null,
        serial: u64 = 0,
        active_serial: u64 = 0,
        state: State(Backend),

        fn create(alloc: Allocator, backend: Backend) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            const wake = w32.CreateEventW(null, 0, 0, null) orelse return error.AudioEventFailed;
            errdefer _ = w32.CloseHandle(wake);
            const finished = w32.CreateEventW(null, 1, 0, null) orelse return error.AudioEventFailed;
            errdefer _ = w32.CloseHandle(finished);
            self.* = .{
                .alloc = alloc,
                .owned_io = .init(alloc, .{ .async_limit = .nothing, .concurrent_limit = .nothing, .environ = .empty }),
                .wake_event = wake,
                .finished_event = finished,
                .state = .{ .backend = backend },
            };
            errdefer self.owned_io.deinit();
            if (@hasDecl(Backend, "setCancel")) self.state.backend.setCancel(.{ .ctx = self, .check = obsolete });
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            return self;
        }

        fn obsolete(ctx: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return !self.current(self.active_serial);
        }

        fn lock(self: *Self) void {
            std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.control);
        }

        fn unlock(self: *Self) void {
            std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.control);
        }

        fn signal(self: *Self) void {
            _ = w32.SetEvent(self.wake_event);
        }

        fn wait(self: *Self, milliseconds: u32) void {
            _ = w32.WaitForSingleObject(self.wake_event, milliseconds);
        }

        // Only the caller logs. A quarantined worker has no global I/O, logger,
        // App/Config pointers or callbacks whose lifetime ends with the GUI.
        fn report(self: *Self) void {
            const issue = self.issue.load(.acquire);
            if (issue == 0 or self.reported.swap(issue, .acq_rel) == issue) return;
            const kind = issue >> 32;
            const code: u32 = @truncate(issue);
            if (kind == 7) {
                log.warn("cannot load bell audio (mono/stereo PCM8/16/24/32 or float32/64 WAV, at most 16 MiB/30 s) err={}", .{@as(anyerror, @errorFromInt(@as(u16, @intCast(code))))});
            } else {
                const operation: Operation = @enumFromInt(kind - 1);
                log.warn("bell audio WinMM {s} failed code={}; player disabled", .{ @tagName(operation), code });
            }
        }

        /// GUI-thread requests own their path copy; they never wait for WinMM.
        pub fn request(self: *Self, path: ?[]const u8, volume: f64) !void {
            if (self.stopping.load(.acquire)) return error.PlayerStopped;
            self.report();
            if (self.faulted.load(.acquire)) return error.PlayerFaulted;
            if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidVolume;
            if (path) |p| {
                if (p.len == 0 or p.len > 96 * 1024 or std.mem.indexOfScalar(u8, p, 0) != null)
                    return error.InvalidPath;
            }
            const copy = if (path) |p| try self.alloc.dupe(u8, p) else null;
            self.lock();
            defer self.unlock();
            if (self.stopping.load(.acquire) or self.faulted.load(.acquire)) {
                if (copy) |p| self.alloc.free(p);
                return error.PlayerStopped;
            }
            if (self.pending) |old| old.deinit(self.alloc);
            self.pending = .{ .path = copy, .volume = volume };
            self.serial +%= 1;
            self.signal();
        }

        pub fn invalidate(self: *Self) void {
            self.request(null, 0) catch {};
        }

        pub fn destroy(self: *Self) void {
            self.stopping.store(true, .release);
            self.signal();
            const finished = w32.WaitForSingleObject(self.thread.getHandle(), shutdown_wait_ms) == w32.WAIT_OBJECT_0;
            self.report();
            if (finished) {
                self.thread.join();
            } else {
                // The deadline is permission to stop waiting, never permission
                // to free a borrowed buffer/header or its execution context.
                self.thread.detach();
                log.warn("bell audio shutdown exceeded {} ms; private worker and outstanding native resources retained", .{shutdown_wait_ms});
            }
            self.releaseRef();
        }

        fn retain(self: *Self) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        fn releaseRef(self: *Self) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            _ = w32.CloseHandle(self.finished_event);
            _ = w32.CloseHandle(self.wake_event);
            const alloc = self.alloc;
            alloc.destroy(self);
        }

        fn current(self: *Self, serial: u64) bool {
            self.lock();
            defer self.unlock();
            return !self.stopping.load(.acquire) and !self.faulted.load(.acquire) and self.serial == serial;
        }

        fn discardPending(self: *Self) void {
            self.lock();
            const pending = self.pending;
            self.pending = null;
            self.unlock();
            if (pending) |request_| request_.deinit(self.alloc);
        }

        fn clear(self: *Self) void {
            self.state.clear(self.alloc);
            self.cache_present.store(false, .release);
        }

        fn publishFault(self: *Self) void {
            if (!@hasDecl(Backend, "failure")) return;
            const failure = self.state.backend.failure();
            if (failure.code == 0) return;
            if (self.faulted.load(.acquire)) return;
            self.issue.store((@as(u64, @intFromEnum(failure.operation)) + 1) << 32 | failure.code, .release);
            self.faulted.store(true, .release);
        }

        fn stop(self: *Self) bool {
            while (true) {
                const returned = self.state.backend.stop();
                self.publishFault();
                if (self.faulted.load(.acquire) or self.stopping.load(.acquire)) return false;
                if (returned) {
                    const closed = self.state.backend.close();
                    self.publishFault();
                    return closed and !self.faulted.load(.acquire);
                }
                self.wait(10);
            }
        }

        fn quarantine(self: *Self) void {
            self.discardPending();
            while (true) {
                const returned = self.state.backend.stop();
                self.publishFault();
                if (!self.state.backend.isBorrowed()) self.clear();
                if (returned and self.state.backend.close()) return;
                self.publishFault();
                self.wait(retry_wait_ms);
            }
        }

        fn run(self: *Self) void {
            defer self.releaseRef();
            defer _ = w32.SetEvent(self.finished_event);
            defer self.owned_io.deinit();
            defer self.state.backend.deinit();
            defer self.clear();
            defer self.discardPending();
            self.runRequests();
            self.quarantine();
        }

        fn runRequests(self: *Self) void {
            while (!self.stopping.load(.acquire) and !self.faulted.load(.acquire)) {
                self.lock();
                const pending = self.pending;
                const serial = self.serial;
                self.pending = null;
                self.unlock();
                if (pending == null) {
                    if (!self.state.backend.active()) {
                        self.wait(w32.INFINITE);
                    } else {
                        if (self.state.backend.finish() and self.state.backend.close())
                            _ = self.completed.fetchAdd(1, .release);
                        self.publishFault();
                        if (!self.faulted.load(.acquire)) self.wait(10);
                    }
                    continue;
                }
                const next = pending.?;
                defer next.deinit(self.alloc);
                if (!self.stop()) return;
                if (!self.current(serial)) continue;
                if (next.path == null or next.volume == 0) {
                    self.clear();
                    continue;
                }
                self.state.prepare(self.alloc, self.owned_io.io(), next.path.?, next.volume) catch |err| {
                    self.issue.store(@as(u64, 7) << 32 | @intFromError(err), .release);
                    continue;
                };
                self.cache_present.store(true, .release);
                if (!self.current(serial)) continue;
                self.active_serial = serial;
                self.state.backend.start(self.state.cache.?.wave) catch |err| {
                    if (err == error.PlayerStopped) continue;
                    self.publishFault();
                    if (!self.faulted.load(.acquire)) {
                        self.issue.store(@as(u64, 7) << 32 | @intFromError(err), .release);
                        self.faulted.store(true, .release);
                    }
                    return;
                };
                _ = self.started.fetchAdd(1, .release);
            }
        }

        // A test lease owns the context until controlled fault release. The
        // finished event plus refcount prove cleanup, not a guessed sleep.
        fn flushRetained(self: *Self) !void {
            std.debug.assert(@import("builtin").is_test);
            self.signal();
            try std.testing.expect(w32.WaitForSingleObject(self.finished_event, 5000) == w32.WAIT_OBJECT_0);
            for (0..10000) |_| {
                if (self.refs.load(.acquire) == 1) {
                    self.releaseRef();
                    return;
                }
                std.Thread.yield() catch {};
            }
            return error.WorkerStillReferenced;
        }
    };
}

const WaveFormat = extern struct {
    tag: u16 align(1) = 1,
    channels: u16 align(1),
    rate: u32 align(1),
    byte_rate: u32 align(1),
    block: u16 align(1),
    bits: u16 align(1) = 16,
    extra: u16 align(1) = 0,
};

const WaveHeader = extern struct {
    data: [*]u8 align(1),
    length: u32 align(1),
    recorded: u32 align(1) = 0,
    user: usize align(1) = 0,
    flags: u32 align(1) = 0,
    loops: u32 align(1) = 0,
    next: ?*WaveHeader align(1) = null,
    reserved: usize align(1) = 0,
};

const Api = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (?*anyopaque, *?*anyopaque, u32, *const WaveFormat, usize, usize, u32) u32 = systemOpen,
    prepare: *const fn (?*anyopaque, *anyopaque, *WaveHeader, u32) u32 = systemPrepare,
    write: *const fn (?*anyopaque, *anyopaque, *WaveHeader, u32) u32 = systemWrite,
    reset: *const fn (?*anyopaque, *anyopaque) u32 = systemReset,
    unprepare: *const fn (?*anyopaque, *anyopaque, *WaveHeader, u32) u32 = systemUnprepare,
    close: *const fn (?*anyopaque, *anyopaque) u32 = systemClose,

    fn systemOpen(_: ?*anyopaque, handle: *?*anyopaque, device: u32, fmt: *const WaveFormat, callback: usize, instance: usize, flags: u32) u32 {
        return waveOutOpen(handle, device, fmt, callback, instance, flags);
    }
    fn systemPrepare(_: ?*anyopaque, handle: *anyopaque, header: *WaveHeader, size: u32) u32 {
        return waveOutPrepareHeader(handle, header, size);
    }
    fn systemWrite(_: ?*anyopaque, handle: *anyopaque, header: *WaveHeader, size: u32) u32 {
        return waveOutWrite(handle, header, size);
    }
    fn systemReset(_: ?*anyopaque, handle: *anyopaque) u32 {
        return waveOutReset(handle);
    }
    fn systemUnprepare(_: ?*anyopaque, handle: *anyopaque, header: *WaveHeader, size: u32) u32 {
        return waveOutUnprepareHeader(handle, header, size);
    }
    fn systemClose(_: ?*anyopaque, handle: *anyopaque) u32 {
        return waveOutClose(handle);
    }
};

const Failure = struct {
    operation: Operation = .open,
    code: u32 = 0,
};

const Cancel = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque) bool,
};

const Native = struct {
    api: Api = .{},
    cancel: ?Cancel = null,
    handle: ?*anyopaque = null,
    event: ?w32.HANDLE = null,
    header: WaveHeader = undefined,
    prepared: bool = false,
    first_failure: Failure = .{},

    fn setCancel(self: *Native, cancel: Cancel) void {
        self.cancel = cancel;
    }

    fn obsolete(self: *const Native) bool {
        return if (self.cancel) |cancel| cancel.check(cancel.ctx) else false;
    }

    fn active(self: *const Native) bool {
        return self.handle != null;
    }

    fn isBorrowed(self: *const Native) bool {
        return self.prepared;
    }

    fn failure(self: *const Native) Failure {
        return self.first_failure;
    }

    fn result(self: *Native, operation: Operation, code: u32) bool {
        if (code == 0) return true;
        if (self.first_failure.code == 0) self.first_failure = .{ .operation = operation, .code = code };
        return false;
    }

    fn start(self: *Native, wave: wav.Wave) !void {
        std.debug.assert(!self.active());
        if (self.obsolete()) return error.PlayerStopped;
        const event = self.event orelse blk: {
            const event = w32.CreateEventW(null, 0, 0, null) orelse return error.AudioEventFailed;
            self.event = event;
            break :blk event;
        };
        _ = w32.ResetEvent(event);
        const fmt: WaveFormat = .{
            .channels = wave.channels,
            .rate = wave.rate,
            .byte_rate = wave.rate * @as(u32, wave.channels) * 2,
            .block = wave.channels * 2,
        };
        if (!self.result(.open, self.api.open(self.api.ctx, &self.handle, std.math.maxInt(u32), &fmt, @intFromPtr(event), 0, 0x00050000)))
            return error.AudioOpenFailed;
        if (self.obsolete()) return error.PlayerStopped;
        self.header = .{ .data = wave.samples().ptr, .length = @intCast(wave.samples().len) };
        if (!self.result(.prepare, self.api.prepare(self.api.ctx, self.handle.?, &self.header, @sizeOf(WaveHeader))))
            return error.AudioPrepareFailed;
        self.prepared = true;
        if (self.obsolete()) return error.PlayerStopped;
        if (!self.result(.write, self.api.write(self.api.ctx, self.handle.?, &self.header, @sizeOf(WaveHeader))))
            return error.AudioWriteFailed;
    }

    fn returnBuffer(self: *Native) bool {
        if (!self.prepared) return true;
        const handle = self.handle orelse return false;
        const code = self.api.unprepare(self.api.ctx, handle, &self.header, @sizeOf(WaveHeader));
        if (code == 33) return false; // WAVERR_STILLPLAYING
        if (!self.result(.unprepare, code)) return false;
        // Only successful unprepare ends the header/PCM loan. Closing the
        // device is a separate operation and cannot extend this loan again.
        self.prepared = false;
        return true;
    }

    fn close(self: *Native) bool {
        std.debug.assert(!self.prepared);
        const handle = self.handle orelse return true;
        if (!self.result(.close, self.api.close(self.api.ctx, handle))) return false;
        self.handle = null;
        return true;
    }

    fn finish(self: *Native) bool {
        if (!self.prepared) return true;
        // An early event is not completion. Unprepare, not dwFlags or a
        // timeout, is the fence that permits freeing the PCM/header.
        if (w32.WaitForSingleObject(self.event.?, 0) != w32.WAIT_OBJECT_0) return false;
        return self.returnBuffer();
    }

    fn stop(self: *Native) bool {
        const handle = self.handle orelse return true;
        if (self.prepared) _ = self.result(.reset, self.api.reset(self.api.ctx, handle));
        return self.returnBuffer();
    }

    fn deinit(self: *Native) void {
        std.debug.assert(!self.active() and !self.prepared);
        if (self.event) |event| _ = w32.CloseHandle(event);
        self.event = null;
    }
};

extern "winmm" fn waveOutOpen(handle: *?*anyopaque, device: u32, format_: *const WaveFormat, callback: usize, instance: usize, flags: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutPrepareHeader(handle: *anyopaque, header: *WaveHeader, size: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutWrite(handle: *anyopaque, header: *WaveHeader, size: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutReset(handle: *anyopaque) callconv(.winapi) u32;
extern "winmm" fn waveOutUnprepareHeader(handle: *anyopaque, header: *WaveHeader, size: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutClose(handle: *anyopaque) callconv(.winapi) u32;

const Observer = struct {
    starts: std.atomic.Value(usize) = .init(0),
    stops: std.atomic.Value(usize) = .init(0),
    sample: std.atomic.Value(i16) = .init(0),
    allow_stop: std.atomic.Value(bool) = .init(true),
    done: std.atomic.Value(bool) = .init(false),

    fn awaitCount(counter: *std.atomic.Value(usize), value: usize) !void {
        for (0..300) |_| {
            if (counter.load(.acquire) >= value) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
        return error.WorkerTimeout;
    }
};

const Mock = struct {
    borrowed: ?[]u8 = null,
    first_sample: i16 = 0,
    starts: usize = 0,
    stops: usize = 0,
    retries: usize = 0,
    done: bool = false,
    fail_start: bool = false,
    observer: ?*Observer = null,

    fn active(self: *const Mock) bool {
        return self.borrowed != null;
    }

    fn isBorrowed(self: *const Mock) bool {
        return self.borrowed != null;
    }

    fn close(self: *Mock) bool {
        return !self.active();
    }

    fn start(self: *Mock, wave: wav.Wave) !void {
        std.debug.assert(!self.active());
        self.borrowed = wave.samples();
        self.first_sample = std.mem.readInt(i16, wave.samples()[0..2], .little);
        self.starts += 1;
        if (self.observer) |observer| {
            observer.sample.store(self.first_sample, .monotonic);
            _ = observer.starts.fetchAdd(1, .release);
        }
        if (self.fail_start) return error.MockWriteFailed;
    }

    fn stop(self: *Mock) bool {
        if (self.borrowed) |bytes| {
            std.debug.assert(self.first_sample == std.mem.readInt(i16, bytes[0..2], .little));
            if (self.observer) |observer| if (!observer.allow_stop.load(.acquire)) return false;
            if (self.retries > 0) {
                self.retries -= 1;
                return false;
            }
            self.borrowed = null;
            self.stops += 1;
            if (self.observer) |observer| _ = observer.stops.fetchAdd(1, .release);
        }
        return true;
    }

    fn finish(self: *Mock) bool {
        const done = if (self.observer) |observer| observer.done.load(.acquire) else self.done;
        return if (done) self.stop() else false;
    }

    fn deinit(self: *Mock) void {
        std.debug.assert(!self.active());
    }
};

fn testFile(dir: std.Io.Dir, name: []const u8, value: i16) !void {
    var bytes = [_]u8{ 'R', 'I', 'F', 'F', 38, 0, 0, 0, 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ', 16, 0, 0, 0, 1, 0, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0, 'd', 'a', 't', 'a', 2, 0, 0, 0, 0, 0 };
    std.mem.writeInt(i16, bytes[44..46], value, .little);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &bytes });
}

test "bell audio cache scales submitted data and refreshes same-size file content path and gain" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    try testFile(tmp.dir, "other.wav", -20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    const other = try tmp.dir.realPathFileAlloc(t.io, "other.wav", t.allocator);
    defer t.allocator.free(other);
    var state: State(Mock) = .{ .backend = .{} };
    defer state.clear(t.allocator);
    try state.prepare(t.allocator, t.io, path, 0.5);
    const original = state.cache.?.wave.bytes.ptr;
    try state.backend.start(state.cache.?.wave);
    try t.expectEqual(@as(i16, 10000), state.backend.first_sample);
    try t.expect(state.backend.stop());
    try state.prepare(t.allocator, t.io, path, 0.5);
    try t.expectEqual(original, state.cache.?.wave.bytes.ptr);
    try testFile(tmp.dir, "bell.wav", 16000);
    try state.prepare(t.allocator, t.io, path, 0.5);
    try state.backend.start(state.cache.?.wave);
    try t.expectEqual(@as(i16, 8000), state.backend.first_sample);
    try t.expect(state.backend.stop());
    try state.prepare(t.allocator, t.io, path, 0.75);
    try state.backend.start(state.cache.?.wave);
    try t.expectEqual(@as(i16, 12000), state.backend.first_sample);
    try t.expect(state.backend.stop());
    try state.prepare(t.allocator, t.io, other, 0.5);
    try state.backend.start(state.cache.?.wave);
    try t.expectEqual(@as(i16, -10000), state.backend.first_sample);
    try t.expect(state.backend.stop());
}

test "bell audio ownership waits for asynchronous completion and failed stop before free" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var state: State(Mock) = .{ .backend = .{ .retries = 1 } };
    defer state.clear(t.allocator);
    try state.prepare(t.allocator, t.io, path, 0.5);
    try state.backend.start(state.cache.?.wave);
    try t.expect(!state.backend.finish());
    try t.expect(!state.backend.stop());
    try t.expect(state.backend.borrowed.?.ptr == state.cache.?.wave.samples().ptr);
    try t.expectEqual(@as(i16, 10000), std.mem.readInt(i16, state.backend.borrowed.?[0..2], .little));
    state.backend.done = true;
    try t.expect(state.backend.finish());
    state.clear(t.allocator);
    try t.expectEqual(@as(?Cache, null), state.cache);
    try t.expectEqual(@as(usize, 1), state.backend.stops);
}

test "bell audio failed write and invalid file do not play cached audio at unity" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var state: State(Mock) = .{ .backend = .{ .fail_start = true } };
    defer state.clear(t.allocator);
    try state.prepare(t.allocator, t.io, path, 0.5);
    try t.expectError(error.MockWriteFailed, state.backend.start(state.cache.?.wave));
    try t.expect(state.backend.stop());
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bell.wav", .data = "invalid" });
    try t.expectError(error.InvalidWave, state.prepare(t.allocator, t.io, path, 0.5));
    try t.expect(!state.backend.active());
    try t.expectEqual(@as(usize, 1), state.backend.starts);
}

test "bell audio worker coalesces owns requests invalidates and joins without a device" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var observer: Observer = .{};
    const player = try Worker(Mock).create(t.allocator, .{ .observer = &observer });
    defer player.destroy();
    defer observer.allow_stop.store(true, .release);
    try player.request(path, 0.5);
    try Observer.awaitCount(&observer.starts, 1);
    try t.expectEqual(@as(i16, 10000), observer.sample.load(.acquire));
    observer.allow_stop.store(false, .release);
    try player.request("not-a-file.wav", 0.75);
    try player.request(path, 0.3);
    @memset(path, 'x');
    observer.allow_stop.store(true, .release);
    try Observer.awaitCount(&observer.starts, 2);
    try t.expectEqual(@as(i16, 6000), observer.sample.load(.acquire));
    try t.expect(!player.current(0));
    // Zero volume does not even open a nonexistent file or native device.
    try player.request("not-a-file.wav", 0);
    try Observer.awaitCount(&observer.stops, 2);
    try t.expectEqual(@as(usize, 2), observer.starts.load(.acquire));
    player.invalidate();
    try t.expectError(error.InvalidPath, player.request("bad\x00path", 0.5));
    try t.expectError(error.InvalidVolume, player.request("b.wav", std.math.nan(f64)));
}

test "bell audio worker completion then shutdown joins and releases active ownership" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", -20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var observer: Observer = .{};
    const player = try Worker(Mock).create(t.allocator, .{ .observer = &observer });
    var destroyed = false;
    defer if (!destroyed) player.destroy();
    try player.request(path, 0.75);
    try Observer.awaitCount(&observer.starts, 1);
    observer.done.store(true, .release);
    try Observer.awaitCount(&observer.stops, 1);
    observer.done.store(false, .release);
    try player.request(path, 1);
    try Observer.awaitCount(&observer.starts, 2);
    try t.expectEqual(@as(i16, -20000), observer.sample.load(.acquire));
    player.destroy();
    destroyed = true;
    try t.expectEqual(@as(usize, 2), observer.stops.load(.acquire));
}

test "bell audio cache allocation failures keep ownership and do not leak" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    const Case = struct {
        fn run(alloc: Allocator, file: []const u8) !void {
            var state: State(Mock) = .{ .backend = .{} };
            defer state.clear(alloc);
            try state.prepare(alloc, std.testing.io, file, 0.5);
            try state.prepare(alloc, std.testing.io, file, 0.75);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Case.run, .{path});
}

test "bell audio WinMM structures match Windows SDK ABI offsets" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 18), @sizeOf(WaveFormat));
    try t.expectEqual(@as(usize, 1), @alignOf(WaveFormat));
    try t.expectEqual(@as(usize, 16), @offsetOf(WaveFormat, "extra"));
    try t.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 48 else 32), @sizeOf(WaveHeader));
    try t.expectEqual(@as(usize, 1), @alignOf(WaveHeader));
    try t.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 16), @offsetOf(WaveHeader, "flags"));
}

test "bell audio native WinMM silent buffer completion reset and release" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 0);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    const player = try Player.create(t.allocator, .{});
    player.retain();
    var destroyed = false;
    defer {
        if (!destroyed) player.destroy();
        player.flushRetained() catch @panic("native silent test did not release ownership");
    }
    try player.request(path, 1);
    try Observer.awaitCount(&player.completed, 1);
    const native = &player.state.backend;
    try t.expectEqualSlices(u8, &.{ 0, 0 }, player.state.cache.?.wave.samples());
    try t.expect(native.header.data == player.state.cache.?.wave.samples().ptr);
    try t.expect(native.handle == null and !native.prepared);
    try player.request(path, 1);
    try Observer.awaitCount(&player.started, 2);
    player.destroy();
    destroyed = true;
    try t.expect(w32.WaitForSingleObject(player.finished_event, 0) == w32.WAIT_OBJECT_0);
    try t.expect(!player.cache_present.load(.acquire));
    try t.expect(player.state.backend.event == null);
}

const Operation = enum(u8) { open, prepare, write, reset, unprepare, close };

const Script = struct {
    errors: [6]std.atomic.Value(u32) = @splat(.init(0)),
    calls: [6]std.atomic.Value(usize) = @splat(.init(0)),
    callback: std.atomic.Value(usize) = .init(0),
    header_address: std.atomic.Value(usize) = .init(0),
    pcm_address: std.atomic.Value(usize) = .init(0),
    sample: std.atomic.Value(i16) = .init(0),
    loan: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(true),
    early: bool = false,
    blocked: std.atomic.Value(u32) = .init(0),
    entered: std.atomic.Value(u32) = .init(0),
    gate: ?w32.HANDLE = null,

    fn api(self: *Script) Api {
        return .{ .ctx = self, .open = open, .prepare = prepare, .write = write, .reset = reset, .unprepare = unprepare, .close = close };
    }

    fn selfFrom(ctx: ?*anyopaque) *Script {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn enter(self: *Script, operation: Operation) u32 {
        const i = @intFromEnum(operation);
        _ = self.calls[i].fetchAdd(1, .release);
        if (self.blocked.load(.acquire) == i + 1) {
            self.entered.store(i + 1, .release);
            std.debug.assert(w32.WaitForSingleObject(self.gate.?, w32.INFINITE) == w32.WAIT_OBJECT_0);
        }
        return self.errors[i].load(.acquire);
    }

    fn complete(self: *Script) void {
        self.done.store(true, .release);
        const callback = self.callback.load(.acquire);
        if (callback != 0) _ = w32.SetEvent(@ptrFromInt(callback));
    }

    fn open(ctx: ?*anyopaque, handle: *?*anyopaque, _: u32, _: *const WaveFormat, callback: usize, _: usize, _: u32) u32 {
        const self = selfFrom(ctx);
        self.callback.store(callback, .release);
        const code = self.enter(.open);
        if (code != 0) return code;
        handle.* = @ptrFromInt(1);
        if (self.early) _ = w32.SetEvent(@ptrFromInt(callback));
        return 0;
    }

    fn prepare(ctx: ?*anyopaque, _: *anyopaque, header: *WaveHeader, _: u32) u32 {
        const self = selfFrom(ctx);
        self.header_address.store(@intFromPtr(header), .monotonic);
        self.pcm_address.store(@intFromPtr(header.data), .monotonic);
        const code = self.enter(.prepare);
        if (code != 0) return code;
        self.loan.store(true, .release);
        return 0;
    }

    fn write(ctx: ?*anyopaque, _: *anyopaque, header: *WaveHeader, _: u32) u32 {
        const self = selfFrom(ctx);
        self.sample.store(std.mem.readInt(i16, header.data[0..2], .little), .monotonic);
        const code = self.enter(.write);
        if (code != 0) return code;
        if (self.done.load(.acquire)) self.complete();
        return 0;
    }

    fn reset(ctx: ?*anyopaque, _: *anyopaque) u32 {
        const self = selfFrom(ctx);
        const code = self.enter(.reset);
        if (code == 0) self.complete();
        return code;
    }

    fn unprepare(ctx: ?*anyopaque, _: *anyopaque, _: *WaveHeader, _: u32) u32 {
        const self = selfFrom(ctx);
        const code = self.enter(.unprepare);
        if (code != 0) return code;
        if (!self.done.load(.acquire)) return 33;
        self.loan.store(false, .release);
        return 0;
    }

    fn close(ctx: ?*anyopaque, _: *anyopaque) u32 {
        const self = selfFrom(ctx);
        std.debug.assert(!self.loan.load(.acquire));
        return self.enter(.close);
    }

    fn awaitCalls(self: *Script, operation: Operation, count: usize) !void {
        try Observer.awaitCount(&self.calls[@intFromEnum(operation)], count);
    }
};

test "bell audio permanent close after unprepare must not block Worker destroy" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var script: Script = .{};
    script.errors[@intFromEnum(Operation.close)].store(6, .release);
    const player = try Player.create(t.allocator, .{ .api = script.api() });
    player.retain();
    try player.request(path, 0.5);
    try script.awaitCalls(.close, 1);
    try t.expect(!script.loan.load(.acquire));
    const Probe = struct {
        fn run(p: *Player) void {
            p.destroy();
        }
    };
    const destroyer = try std.Thread.spawn(.{}, Probe.run, .{player});
    const bounded = w32.WaitForSingleObject(destroyer.getHandle(), 300) == w32.WAIT_OBJECT_0;
    try t.expect(w32.WaitForSingleObject(destroyer.getHandle(), 5000) == w32.WAIT_OBJECT_0);
    destroyer.join();
    try t.expect(!player.cache_present.load(.acquire));
    script.errors[@intFromEnum(Operation.close)].store(0, .release);
    try player.flushRetained();
    try t.expect(bounded);
}

fn awaitFlag(flag: *std.atomic.Value(bool), value: bool) !void {
    for (0..300) |_| {
        if (flag.load(.acquire) == value) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    return error.WorkerTimeout;
}

fn destroyWithinBudget(player: *Player) !void {
    const before = std.Io.Timestamp.now(std.testing.io, .awake);
    player.destroy();
    const elapsed = before.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).toMilliseconds();
    std.debug.print("bell audio injected destroy: {d} ms (thread wait limit {d} ms)\n", .{ elapsed, shutdown_wait_ms });
    try std.testing.expect(elapsed < 500);
}

fn releaseScript(script: *Script) void {
    for (&script.errors) |*code| code.store(0, .release);
    script.done.store(true, .release);
    if (script.gate) |gate| _ = w32.SetEvent(gate);
}

test "bell audio native failure matrix isolates every stage without repeated players or leaks" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    for (std.enums.values(Operation)) |operation| {
        for ([_]u32{ 5, 6, 7 }) |code| {
            var script: Script = .{};
            script.errors[@intFromEnum(operation)].store(code, .release);
            if (operation == .reset) script.done.store(false, .release);
            const player = try Player.create(t.allocator, .{ .api = script.api() });
            player.retain();
            var destroyed = false;
            defer {
                releaseScript(&script);
                if (!destroyed) player.destroy();
                player.flushRetained() catch @panic("injected fault did not release ownership");
            }
            try player.request(path, 0.5);
            if (operation == .reset) {
                try Observer.awaitCount(&player.started, 1);
                player.invalidate();
            }
            try script.awaitCalls(operation, 1);
            try awaitFlag(&player.faulted, true);
            for (0..100) |_| try t.expectError(error.PlayerFaulted, player.request(path, 0.75));
            try t.expectEqual(@as(usize, 1), script.calls[@intFromEnum(Operation.open)].load(.acquire));
            try t.expectEqual(player.issue.load(.acquire), player.reported.load(.acquire));
            try destroyWithinBudget(player);
            destroyed = true;
            if (operation == .reset or operation == .unprepare) {
                try t.expect(script.loan.load(.acquire));
                try t.expect(player.cache_present.load(.acquire));
                const header: *WaveHeader = @ptrFromInt(script.header_address.load(.acquire));
                try t.expect(header == &player.state.backend.header);
                try t.expectEqual(@as(i16, 10000), std.mem.readInt(i16, header.data[0..2], .little));
            } else {
                try t.expect(!script.loan.load(.acquire));
                try t.expect(!player.cache_present.load(.acquire));
            }
        }
    }
}

test "bell audio blocked native API matrix retains stable execution context after bounded destroy" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    for (std.enums.values(Operation)) |operation| {
        var script: Script = .{};
        const gate = w32.CreateEventW(null, 1, 0, null) orelse return error.AudioEventFailed;
        defer _ = w32.CloseHandle(gate);
        script.gate = gate;
        script.blocked.store(@as(u32, @intFromEnum(operation)) + 1, .release);
        if (operation == .reset) script.done.store(false, .release);
        const player = try Player.create(t.allocator, .{ .api = script.api() });
        player.retain();
        var destroyed = false;
        defer {
            releaseScript(&script);
            if (!destroyed) player.destroy();
            player.flushRetained() catch @panic("blocked API context did not release");
        }
        try player.request(path, 0.5);
        if (operation == .reset) {
            try Observer.awaitCount(&player.started, 1);
            player.invalidate();
        }
        for (0..300) |_| {
            if (script.entered.load(.acquire) != 0) break;
            try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
        }
        try t.expectEqual(@as(u32, @intFromEnum(operation)) + 1, script.entered.load(.acquire));
        const original_pcm = player.state.cache.?.wave.samples().ptr;
        const original_header = &player.state.backend.header;
        try destroyWithinBudget(player);
        destroyed = true;
        try t.expect(w32.WaitForSingleObject(player.finished_event, 0) == w32.WAIT_TIMEOUT);
        try t.expect(player.cache_present.load(.acquire));
        try t.expectEqual(original_pcm, player.state.cache.?.wave.samples().ptr);
        try t.expectEqual(@as(i16, 10000), std.mem.readInt(i16, original_pcm[0..2], .little));
        if (operation != .open) {
            try t.expect(original_header == &player.state.backend.header);
            try t.expectEqual(@intFromPtr(original_header), script.header_address.load(.acquire));
        }
        try t.expectError(error.PlayerStopped, player.request(path, 1));
        // Unblocking the actual call is the release source, not the deadline.
    }
}

test "bell audio early and absent completion retain loan until unprepare succeeds" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var script: Script = .{ .early = true };
    script.done.store(false, .release);
    const player = try Player.create(t.allocator, .{ .api = script.api() });
    player.retain();
    defer {
        releaseScript(&script);
        player.destroy();
        player.flushRetained() catch @panic("completion test did not release");
    }
    try player.request(path, 0.5);
    try script.awaitCalls(.unprepare, 1);
    try t.expectEqual(@as(usize, 0), player.completed.load(.acquire));
    try t.expect(!player.faulted.load(.acquire));
    try t.expect(script.loan.load(.acquire));
    const header: *WaveHeader = @ptrFromInt(script.header_address.load(.acquire));
    try t.expectEqual(@as(i16, 10000), std.mem.readInt(i16, header.data[0..2], .little));
    script.complete();
    try Observer.awaitCount(&player.completed, 1);
    try t.expect(!script.loan.load(.acquire));
    try t.expect(script.calls[@intFromEnum(Operation.unprepare)].load(.acquire) >= 2);
    try player.request("not-a-file.wav", 0);
    try awaitFlag(&player.cache_present, false);
    try t.expectEqual(@as(usize, 1), script.calls[@intFromEnum(Operation.open)].load(.acquire));
}

test "bell audio new serial while prepare blocks does not submit the obsolete gain" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var script: Script = .{};
    const gate = w32.CreateEventW(null, 1, 0, null) orelse return error.AudioEventFailed;
    defer _ = w32.CloseHandle(gate);
    script.gate = gate;
    script.blocked.store(@as(u32, @intFromEnum(Operation.prepare)) + 1, .release);
    const player = try Player.create(t.allocator, .{ .api = script.api() });
    player.retain();
    defer {
        releaseScript(&script);
        player.destroy();
        player.flushRetained() catch @panic("serial test did not release");
    }
    try player.request(path, 0.5);
    try script.awaitCalls(.prepare, 1);
    try player.request(path, 0.3);
    var unrelated_io: std.Io.Threaded = .init(t.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    unrelated_io.deinit();
    _ = w32.SetEvent(gate);
    try Observer.awaitCount(&player.completed, 1);
    try t.expectEqual(@as(usize, 2), script.calls[@intFromEnum(Operation.open)].load(.acquire));
    try t.expectEqual(@as(usize, 1), script.calls[@intFromEnum(Operation.write)].load(.acquire));
    try t.expectEqual(@as(i16, 6000), script.sample.load(.acquire));
}

test "bell audio requests racing destroy cannot reopen a quarantined player" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "bell.wav", 20000);
    const path = try tmp.dir.realPathFileAlloc(t.io, "bell.wav", t.allocator);
    defer t.allocator.free(path);
    var script: Script = .{};
    const gate = w32.CreateEventW(null, 1, 0, null) orelse return error.AudioEventFailed;
    defer _ = w32.CloseHandle(gate);
    script.gate = gate;
    script.blocked.store(@as(u32, @intFromEnum(Operation.write)) + 1, .release);
    const player = try Player.create(t.allocator, .{ .api = script.api() });
    player.retain();
    var destroyed = false;
    defer {
        releaseScript(&script);
        if (!destroyed) player.destroy();
        player.flushRetained() catch @panic("racing producer did not release");
    }
    try player.request(path, 0.5);
    try script.awaitCalls(.write, 1);
    const Producer = struct {
        fn run(p: *Player, file: []const u8) void {
            defer p.releaseRef();
            for (0..500) |_| p.request(file, 0.3) catch |err| {
                std.debug.assert(err == error.PlayerStopped);
            };
        }
    };
    player.retain();
    const producer = try std.Thread.spawn(.{}, Producer.run, .{ player, path });
    try destroyWithinBudget(player);
    destroyed = true;
    producer.join();
    try t.expectError(error.PlayerStopped, player.request(path, 1));
    try t.expectEqual(@as(usize, 1), script.calls[@intFromEnum(Operation.open)].load(.acquire));
    try t.expectEqual(@as(usize, 1), script.calls[@intFromEnum(Operation.write)].load(.acquire));
    try t.expect(script.loan.load(.acquire));
}
