const std = @import("std");
const Allocator = std.mem.Allocator;
const wav = @import("bell_wav.zig");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32);

pub const Player = Worker(Native);

pub fn create(io: std.Io) !*Player {
    return Player.create(std.heap.page_allocator, io, .{});
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
            std.debug.assert(!self.backend.active());
            if (self.cache) |cache| cache.deinit(alloc);
            self.cache = null;
        }
    };
}

fn Worker(comptime Backend: type) type {
    return struct {
        const Self = @This();
        alloc: Allocator,
        io: std.Io,
        thread: std.Thread = undefined,
        mutex: std.Io.Mutex = .init,
        ready: std.Io.Condition = .init,
        pending: ?Request = null,
        serial: u64 = 0,
        stopping: bool = false,
        state: State(Backend),

        fn create(alloc: Allocator, io: std.Io, backend: Backend) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            self.* = .{ .alloc = alloc, .io = io, .state = .{ .backend = backend } };
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            return self;
        }

        /// The GUI only copies a request. File I/O, decoding and all WinMM
        /// calls belong to the joined worker; no Config/App pointers escape.
        pub fn request(self: *Self, path: ?[]const u8, volume: f64) !void {
            if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidVolume;
            if (path) |p| {
                if (p.len == 0 or p.len > 96 * 1024 or std.mem.indexOfScalar(u8, p, 0) != null)
                    return error.InvalidPath;
            }
            const copy = if (path) |p| try self.alloc.dupe(u8, p) else null;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping) {
                if (copy) |p| self.alloc.free(p);
                return error.PlayerStopped;
            }
            if (self.pending) |old| old.deinit(self.alloc);
            self.pending = .{ .path = copy, .volume = volume };
            self.serial +%= 1;
            self.ready.signal(self.io);
        }

        pub fn invalidate(self: *Self) void {
            self.request(null, 0) catch {};
        }

        pub fn destroy(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.ready.signal(self.io);
            self.mutex.unlock(self.io);
            self.thread.join();
            if (self.pending) |request_| request_.deinit(self.alloc);
            const alloc = self.alloc;
            alloc.destroy(self);
        }

        fn current(self: *Self, serial: u64) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return !self.stopping and self.serial == serial;
        }

        fn pause(self: *Self) void {
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }

        fn stop(self: *Self) void {
            // A failed reset/unprepare never transfers ownership back. Keep
            // both the stable WAVEHDR and PCM buffer until WinMM releases them.
            while (!self.state.backend.stop()) self.pause();
        }

        fn run(self: *Self) void {
            defer self.state.backend.deinit();
            defer self.state.clear(self.alloc);
            defer self.stop();
            while (true) {
                self.mutex.lockUncancelable(self.io);
                if (self.stopping) {
                    self.mutex.unlock(self.io);
                    return;
                }
                const pending = self.pending;
                const serial = self.serial;
                self.pending = null;
                if (pending == null) {
                    if (!self.state.backend.active()) {
                        self.ready.waitUncancelable(self.io, &self.mutex);
                        self.mutex.unlock(self.io);
                    } else {
                        self.mutex.unlock(self.io);
                        _ = self.state.backend.finish();
                        self.pause();
                    }
                    continue;
                }
                self.mutex.unlock(self.io);
                const next = pending.?;
                defer next.deinit(self.alloc);
                self.stop();
                if (!self.current(serial)) continue;
                if (next.path == null or next.volume == 0) {
                    self.state.clear(self.alloc);
                    continue;
                }
                self.state.prepare(self.alloc, self.io, next.path.?, next.volume) catch |err| {
                    log.warn("cannot load bell audio (mono/stereo PCM8/16/24/32 or float32/64 WAV, at most 16 MiB/30 s) err={}", .{err});
                    continue;
                };
                if (!self.current(serial)) continue;
                self.state.backend.start(self.state.cache.?.wave) catch |err| {
                    log.warn("cannot play bell audio err={}", .{err});
                    self.stop();
                };
            }
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

const Native = struct {
    handle: ?*anyopaque = null,
    event: ?w32.HANDLE = null,
    header: WaveHeader = undefined,
    prepared: bool = false,
    failed: bool = false,

    fn active(self: *const Native) bool {
        return self.handle != null;
    }

    fn result(self: *Native, code: u32) bool {
        if (code == 0) return true;
        if (!self.failed) log.warn("bell audio WinMM error code={}", .{code});
        self.failed = true;
        return false;
    }

    fn start(self: *Native, wave: wav.Wave) !void {
        std.debug.assert(!self.active());
        self.failed = false;
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
        if (!self.result(waveOutOpen(&self.handle, std.math.maxInt(u32), &fmt, @intFromPtr(event), 0, 0x00050000)))
            return error.AudioOpenFailed;
        self.header = .{ .data = wave.samples().ptr, .length = @intCast(wave.samples().len) };
        if (!self.result(waveOutPrepareHeader(self.handle.?, &self.header, @sizeOf(WaveHeader))))
            return error.AudioPrepareFailed;
        self.prepared = true;
        if (!self.result(waveOutWrite(self.handle.?, &self.header, @sizeOf(WaveHeader))))
            return error.AudioWriteFailed;
    }

    fn release(self: *Native) bool {
        const handle = self.handle orelse return true;
        if (self.prepared) {
            const code = waveOutUnprepareHeader(handle, &self.header, @sizeOf(WaveHeader));
            if (code == 33) return false; // WAVERR_STILLPLAYING
            if (!self.result(code)) return false;
            self.prepared = false;
        }
        if (!self.result(waveOutClose(handle))) return false;
        self.handle = null;
        return true;
    }

    fn finish(self: *Native) bool {
        if (self.handle == null) return true;
        if (!self.prepared or self.failed) return self.release();
        // The event synchronizes native buffer completion. Unprepare is the
        // ownership fence, not an unsynchronized read of dwFlags.
        if (w32.WaitForSingleObject(self.event.?, 0) != w32.WAIT_OBJECT_0) return false;
        return self.release();
    }

    fn stop(self: *Native) bool {
        const handle = self.handle orelse return true;
        if (self.prepared and !self.result(waveOutReset(handle))) return self.finish();
        return self.release();
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
    const player = try Worker(Mock).create(t.allocator, t.io, .{ .observer = &observer });
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
    const player = try Worker(Mock).create(t.allocator, t.io, .{ .observer = &observer });
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
    try testFile(tmp.dir, "bell.wav", 20000);
    const input = try tmp.dir.readFileAlloc(t.io, "bell.wav", t.allocator, .limited(1024));
    defer t.allocator.free(input);
    const wave = try wav.decode(t.allocator, input, 0);
    defer wave.deinit(t.allocator);
    try t.expectEqualSlices(u8, &.{ 0, 0 }, wave.samples());
    var native: Native = .{};
    defer native.deinit();
    defer {
        while (!native.stop()) std.Io.sleep(t.io, .fromMilliseconds(10), .awake) catch {};
    }
    try native.start(wave);
    try t.expect(native.header.data == wave.samples().ptr);
    var finished = false;
    for (0..200) |_| {
        if (native.finish()) {
            finished = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(finished);
    try native.start(wave);
    try t.expect(native.stop());
    try t.expect(native.handle == null and !native.prepared);
}
