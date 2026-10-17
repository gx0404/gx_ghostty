//! Performance measurements of Ghostty GX, off unless the environment
//! variable `GHOSTTY_GX_PERF` is `1` (or `true`, `on`, `yes`). Every sample
//! is one line of the scoped log `gx_perf`, `<metric> <value>us`, for
//! example `info(gx_perf): first_frame 183456us`; `scripts/gx_perf.py`
//! collects them. Metric names use lower-case letters, digits, `_` and `.`;
//! the summary of a series (`Stats.report`) adds `_p50`, `_p90` and `_max`
//! to its name.
//!
//! Times come from the awake clock (`std.Io.Clock.awake`): monotonic, and
//! without the time the system was suspended. `processAgeUs` measures from
//! the start of the process instead, for startup metrics.
//!
//! Recording only logs, so any thread may record. `Stats` belongs to one
//! thread.
const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");

const log = std.log.scoped(.gx_perf);

/// The environment variable that turns measurements on.
pub const env_var = "GHOSTTY_GX_PERF";

const Switch = enum(u8) { unknown, off, on };

var switch_state: std.atomic.Value(Switch) = .init(.unknown);

/// Whether measurements are on. The first call reads `GHOSTTY_GX_PERF`;
/// loading the configuration makes it on the main thread at startup.
pub fn enabled() bool {
    return switch (switch_state.load(.acquire)) {
        .on => true,
        .off => false,
        .unknown => {
            const on = envSwitch(global.environ());
            setEnabled(on);
            return on;
        },
    };
}

/// Whether `GHOSTTY_GX_PERF` in `environ` turns measurements on, read
/// without allocating.
fn envSwitch(environ: std.process.Environ) bool {
    if (builtin.os.tag == .windows) {
        const wide = environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(env_var)) orelse return false;
        var buf: [16]u8 = undefined;
        if (wide.len > buf.len) return false;
        for (wide, buf[0..wide.len]) |c, *out| {
            out.* = std.math.cast(u8, c) orelse return false;
        }
        return isOn(buf[0..wide.len]);
    }
    return isOn(environ.getPosix(env_var) orelse return false);
}

/// Turns measurements on or off, overriding `GHOSTTY_GX_PERF`.
pub fn setEnabled(on: bool) void {
    switch_state.store(if (on) .on else .off, .release);
}

/// Whether a `GHOSTTY_GX_PERF` value turns measurements on.
pub fn isOn(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    for ([_][]const u8{ "1", "true", "on", "yes" }) |on| {
        if (std.ascii.eqlIgnoreCase(trimmed, on)) return true;
    }
    return false;
}

/// A point in time on the awake clock.
pub const Instant = std.Io.Timestamp;

pub fn now(io: std.Io) Instant {
    return std.Io.Clock.awake.now(io);
}

/// The microseconds from `from` to `to`, 0 if `to` is not later.
pub fn elapsedUs(from: Instant, to: Instant) u64 {
    const ns = from.durationTo(to).nanoseconds;
    if (ns <= 0) return 0;
    return @intCast(@min(@divTrunc(ns, std.time.ns_per_us), std.math.maxInt(u64)));
}

/// The microseconds since `from`.
pub fn sinceUs(io: std.Io, from: Instant) u64 {
    return elapsedUs(from, now(io));
}

/// Logs the sample `<metric> <us>us` when measurements are on.
pub fn record(metric: []const u8, us: u64) void {
    if (!enabled()) return;
    log.info("{s} {d}us", .{ metric, us });
}

/// Logs a unitless count or gauge when measurements are on.
pub fn count(metric: []const u8, n: u64) void {
    if (!enabled()) return;
    log.info("metric {s} {d}", .{ metric, n });
}

/// A measurement from `begin` to `end`.
pub const Span = struct {
    start: Instant,

    pub fn begin(io: std.Io) Span {
        return .{ .start = now(io) };
    }

    /// Records the time since `begin` as `metric` and returns it.
    pub fn end(self: Span, io: std.Io, metric: []const u8) u64 {
        const us = sinceUs(io, self.start);
        record(metric, us);
        return us;
    }
};

/// A series of samples, such as frame intervals during a resize, summed up
/// by quantiles. Keeps the latest `capacity` samples.
pub const Stats = struct {
    pub const capacity = 512;

    samples: [capacity]u64 = undefined,
    len: usize = 0,
    /// Where the next sample goes once the buffer is full.
    next: usize = 0,
    /// All samples added since the last reset, also those no longer kept.
    count: u64 = 0,

    pub fn add(self: *Stats, us: u64) void {
        self.count += 1;
        if (self.len < capacity) {
            self.samples[self.len] = us;
            self.len += 1;
            return;
        }
        self.samples[self.next] = us;
        self.next = (self.next + 1) % capacity;
    }

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    /// The nearest-rank quantile `q` (0 to 1) of the kept samples, null
    /// without samples: `quantile(0.5)` is the median, `quantile(1)` the
    /// largest sample.
    pub fn quantile(self: *const Stats, q: f64) ?u64 {
        if (self.len == 0) return null;
        var sorted: [capacity]u64 = undefined;
        @memcpy(sorted[0..self.len], self.samples[0..self.len]);
        std.mem.sort(u64, sorted[0..self.len], {}, std.sort.asc(u64));
        const clamped = std.math.clamp(q, 0, 1);
        const rank: usize = @intFromFloat(@ceil(clamped * @as(f64, @floatFromInt(self.len))));
        return sorted[@max(rank, 1) - 1];
    }

    /// Records the median, the 90th percentile and the largest sample as
    /// `<metric>_p50`, `<metric>_p90` and `<metric>_max`, then starts a new
    /// series. Nothing is recorded without samples.
    pub fn report(self: *Stats, metric: []const u8) void {
        defer self.reset();
        if (self.len == 0 or !enabled()) return;
        const parts = [_]struct { []const u8, f64 }{ .{ "_p50", 0.5 }, .{ "_p90", 0.9 }, .{ "_max", 1 } };
        for (parts) |part| {
            var buf: [128]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "{s}{s}", .{ metric, part[0] }) catch continue;
            record(name, self.quantile(part[1]).?);
        }
    }
};

/// The microseconds since this process started, or null where that is not
/// known. Linux counts in the kernel's clock ticks (10 ms).
pub fn processAgeUs(io: std.Io) ?u64 {
    switch (builtin.os.tag) {
        .windows => {
            const win = std.os.windows;
            var creation: win.FILETIME = undefined;
            var exit: win.FILETIME = undefined;
            var kernel: win.FILETIME = undefined;
            var user: win.FILETIME = undefined;
            if (!windows.GetProcessTimes(win.GetCurrentProcess(), &creation, &exit, &kernel, &user).toBool()) return null;
            const ticks = (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
            // FILETIME counts 100 ns since 1601-01-01.
            const unix_ticks = std.math.sub(u64, ticks, 116_444_736_000_000_000) catch return null;
            const start_ns: i96 = @as(i96, unix_ticks) * 100;
            const now_ns = std.Io.Clock.real.now(io).nanoseconds;
            if (now_ns <= start_ns) return 0;
            return @intCast(@divTrunc(now_ns - start_ns, std.time.ns_per_us));
        },
        .linux => {
            var buf: [1024]u8 = undefined;
            const stat = std.Io.Dir.cwd().readFile(io, "/proc/self/stat", &buf) catch return null;
            const start_ticks = procStartTicks(stat) orelse return null;
            const start_ns: i96 = @as(i96, start_ticks) * (std.time.ns_per_s / linux_ticks_per_s);
            const now_ns = std.Io.Clock.boot.now(io).nanoseconds;
            if (now_ns <= start_ns) return 0;
            return @intCast(@divTrunc(now_ns - start_ns, std.time.ns_per_us));
        },
        else => return null,
    }
}

/// `USER_HZ`, the unit of the start time in `/proc/<pid>/stat`: 100 on
/// every architecture Ghostty builds for.
const linux_ticks_per_s = 100;

/// The start time (field 22) of a `/proc/<pid>/stat` line, in clock ticks
/// since boot. The command name (field 2) may contain spaces and
/// parentheses, so fields are counted after its last `)`.
fn procStartTicks(stat: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var field: usize = 3;
    while (fields.next()) |value| : (field += 1) {
        if (field == 22) return std.fmt.parseInt(u64, std.mem.trimEnd(u8, value, "\n"), 10) catch null;
    }
    return null;
}

const windows = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;
    extern "kernel32" fn GetProcessTimes(
        hProcess: win.HANDLE,
        lpCreationTime: *win.FILETIME,
        lpExitTime: *win.FILETIME,
        lpKernelTime: *win.FILETIME,
        lpUserTime: *win.FILETIME,
    ) callconv(.winapi) win.BOOL;
} else struct {};

const testing = std.testing;

test "GHOSTTY_GX_PERF values that turn measurements on" {
    for ([_][]const u8{ "1", "true", "ON", " yes " }) |value| try testing.expect(isOn(value));
    for ([_][]const u8{ "", "0", "false", "off", "2" }) |value| try testing.expect(!isOn(value));
}

test "envSwitch reads GHOSTTY_GX_PERF" {
    try testing.expect(!envSwitch(.empty));
    if (builtin.os.tag != .windows) {
        const on = [_:null]?[*:0]const u8{ "PATH=/bin", "GHOSTTY_GX_PERF=yes" };
        try testing.expect(envSwitch(.{ .block = .{ .slice = &on } }));
        const off = [_:null]?[*:0]const u8{"GHOSTTY_GX_PERF=0"};
        try testing.expect(!envSwitch(.{ .block = .{ .slice = &off } }));
    }
}

test "setEnabled overrides the environment" {
    const before = enabled();
    defer setEnabled(before);
    setEnabled(true);
    try testing.expect(enabled());
    record("gx_perf_test", 12);
    setEnabled(false);
    try testing.expect(!enabled());
}

test "elapsedUs and Span measure on the awake clock" {
    const io = testing.io;
    const start: Instant = .{ .nanoseconds = 1_000_000 };
    try testing.expectEqual(@as(u64, 250), elapsedUs(start, .{ .nanoseconds = 1_250_999 }));
    try testing.expectEqual(@as(u64, 0), elapsedUs(start, .{ .nanoseconds = 999 }));

    const span: Span = .begin(io);
    const a = now(io);
    try testing.expect(elapsedUs(span.start, a) < 60 * std.time.us_per_s);
    _ = span.end(io, "gx_perf_test");
}

test "Stats quantiles" {
    var stats: Stats = .{};
    try testing.expectEqual(@as(?u64, null), stats.quantile(0.5));
    for (1..11) |i| stats.add(@intCast(i * 10));
    try testing.expectEqual(@as(?u64, 50), stats.quantile(0.5));
    try testing.expectEqual(@as(?u64, 90), stats.quantile(0.9));
    try testing.expectEqual(@as(?u64, 100), stats.quantile(1));
    try testing.expectEqual(@as(?u64, 10), stats.quantile(0));
    try testing.expectEqual(@as(u64, 10), stats.count);

    // Only the latest samples are kept.
    for (0..Stats.capacity) |_| stats.add(7);
    try testing.expectEqual(@as(?u64, 7), stats.quantile(1));
    try testing.expectEqual(@as(u64, 10 + Stats.capacity), stats.count);

    stats.report("gx_perf_test");
    try testing.expectEqual(@as(usize, 0), stats.len);
}

test "procStartTicks reads field 22 after the command name" {
    const line = "4242 (my (odd) cmd) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1234 56\n";
    try testing.expectEqual(@as(?u64, 987654), procStartTicks(line));
    try testing.expectEqual(@as(?u64, null), procStartTicks("4242 (x) S 1 2"));
    try testing.expectEqual(@as(?u64, null), procStartTicks("garbage"));
}

test "processAgeUs is known on Windows and Linux" {
    const age = processAgeUs(testing.io);
    switch (builtin.os.tag) {
        .windows, .linux => try testing.expect(age.? < 24 * std.time.us_per_hour),
        else => try testing.expectEqual(@as(?u64, null), age),
    }
}
