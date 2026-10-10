//! Motion for the custom-drawn UI: the Fluent durations and easing curves,
//! time-based `Tween`s, whether to animate at all (`enabled`), and a frame
//! clock that calls running animations once per display refresh.
//!
//! The clock: while an `Animator` runs, a background thread waits for the
//! next DWM composition (`DwmFlush`) and posts one `WM_TICK` to a
//! message-only window of this module (class `GhosttyGxAnimClock`); the GUI
//! thread then calls every running animator. The next tick is posted only
//! after the GUI thread handled the previous one, so a busy GUI thread gets
//! fewer ticks rather than a queue of them, and without running animators
//! the thread sleeps on an event. Animations compute their progress from
//! the elapsed time (`Tween`), so a late frame skips ahead instead of
//! slowing the animation down.
//!
//! `enabled` follows the Windows "Animation effects" setting
//! (`SPI_GETCLIENTAREAANIMATION`), is off in remote sessions
//! (`SM_REMOTESESSION`), and the environment variable
//! `GHOSTTY_GX_ANIMATIONS` (`1`/`0`, `on`/`off`, ...) overrides both.
//! Callers ask it when an animation would start and jump to the end state
//! when it says no.
//!
//! Durations and curves are the Fluent motion values: 83/167/250 ms (WinUI
//! ControlFaster/Fast/NormalAnimationDuration), entering elements
//! `cubic-bezier(0,0,0,1)`, leaving ones `cubic-bezier(1,0,1,1)`. The clock
//! thread follows the idea of Zed's Windows vsync thread (Apache-2.0,
//! idea only): DwmFlush in a loop, sleeping a refresh period when it
//! returns at once.
//!
//! Everything except the clock thread runs on the GUI thread.
const std = @import("std");
const w32 = @import("../win32.zig");

const log = std.log.scoped(.win32_anim);

/// Animation durations in milliseconds.
pub const duration_ms = struct {
    /// Hover and press feedback.
    pub const faster: u32 = 83;
    /// Popups fading in, a selection moving.
    pub const fast: u32 = 167;
    /// Larger movements.
    pub const normal: u32 = 250;
};

/// A cubic Bézier easing curve from (0,0) to (1,1), as in CSS
/// `cubic-bezier(x1, y1, x2, y2)`.
pub const Curve = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub const linear: Curve = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 };
    /// Entering elements: fast start, slow end (Fluent decelerate).
    pub const decelerate: Curve = .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 1 };
    /// Leaving elements: slow start, fast end (Fluent accelerate).
    pub const accelerate: Curve = .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 1 };
    /// Moving between two places on screen (Fluent easy ease).
    pub const ease: Curve = .{ .x1 = 0.33, .y1 = 0, .x2 = 0.67, .y2 = 1 };

    /// One coordinate of the curve at parameter `t`.
    fn sample(a1: f32, a2: f32, t: f32) f32 {
        const u = 1 - t;
        return 3 * u * u * t * a1 + 3 * u * t * t * a2 + t * t * t;
    }

    fn slope(a1: f32, a2: f32, t: f32) f32 {
        const u = 1 - t;
        return 3 * u * u * a1 + 6 * u * t * (a2 - a1) + 3 * t * t * (1 - a2);
    }

    /// The parameter where the coordinate with control values a1, a2 is
    /// `v` (it rises monotonically from 0 to 1).
    fn solve(a1: f32, a2: f32, v: f32) f32 {
        var t = v;
        for (0..8) |_| {
            const err = sample(a1, a2, t) - v;
            if (@abs(err) < 1e-6) return t;
            const d = slope(a1, a2, t);
            if (@abs(d) < 1e-6) break;
            t -= err / d;
            if (t < 0 or t > 1) break;
        }
        var lo: f32 = 0;
        var hi: f32 = 1;
        t = v;
        for (0..40) |_| {
            const s = sample(a1, a2, t);
            if (@abs(s - v) < 1e-6) return t;
            if (s < v) lo = t else hi = t;
            t = (lo + hi) / 2;
        }
        return t;
    }

    /// The eased progress for linear progress `x` (0..1).
    pub fn at(self: Curve, x: f32) f32 {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        return sample(self.y1, self.y2, solve(self.x1, self.x2, x));
    }

    /// The linear progress whose eased value is `y`: where an animation
    /// with this curve stands when it should continue from `y`, e.g. one
    /// that reverses halfway.
    pub fn inverse(self: Curve, y: f32) f32 {
        if (y <= 0) return 0;
        if (y >= 1) return 1;
        return sample(self.x1, self.x2, solve(self.y1, self.y2, y));
    }
};

/// Progress of an animation over time: started at `start_ns` (see
/// `now`), lasting `duration_ns`, eased by `curve`.
pub const Tween = struct {
    start_ns: u64,
    duration_ns: u64,
    curve: Curve = Curve.decelerate,

    pub fn begin(now_ns: u64, ms: u32, curve: Curve) Tween {
        return .{ .start_ns = now_ns, .duration_ns = @as(u64, ms) * std.time.ns_per_ms, .curve = curve };
    }

    /// The share of the duration elapsed at `now_ns`, 0..1.
    pub fn linear(self: Tween, now_ns: u64) f32 {
        if (self.duration_ns == 0 or now_ns >= self.start_ns + self.duration_ns) return 1;
        if (now_ns <= self.start_ns) return 0;
        const elapsed: f64 = @floatFromInt(now_ns - self.start_ns);
        const total: f64 = @floatFromInt(self.duration_ns);
        return @floatCast(elapsed / total);
    }

    /// The eased progress at `now_ns`, 0..1.
    pub fn progress(self: Tween, now_ns: u64) f32 {
        return self.curve.at(self.linear(now_ns));
    }

    pub fn done(self: Tween, now_ns: u64) bool {
        return self.linear(now_ns) >= 1;
    }

    /// The value between `from` and `to` at `now_ns`.
    pub fn lerp(self: Tween, now_ns: u64, from: f32, to: f32) f32 {
        return from + (to - from) * self.progress(now_ns);
    }
};

// -----------------------------------------------------------------------
// Whether to animate
// -----------------------------------------------------------------------

/// Whether animations should run now (see the file header). Ask when an
/// animation would start.
pub fn enabled() bool {
    return decide(envOverride(), clientAreaAnimation(), remoteSession());
}

/// Animations run when `GHOSTTY_GX_ANIMATIONS` says so (`env`), else when
/// the system setting is on and the session is local.
pub fn decide(env: ?bool, client_area_animation: bool, remote_session: bool) bool {
    if (env) |forced| return forced;
    return client_area_animation and !remote_session;
}

/// The value of `GHOSTTY_GX_ANIMATIONS`: null when unset or unrecognized.
pub fn parseOverride(value: []const u8) ?bool {
    const on = [_][]const u8{ "1", "true", "on", "yes" };
    const off = [_][]const u8{ "0", "false", "off", "no" };
    const trimmed = std.mem.trim(u8, value, " \t");
    for (on) |word| if (std.ascii.eqlIgnoreCase(trimmed, word)) return true;
    for (off) |word| if (std.ascii.eqlIgnoreCase(trimmed, word)) return false;
    return null;
}

const EnvState = enum { unread, unset, on, off };
var env_state: EnvState = .unread;

fn envOverride() ?bool {
    if (env_state == .unread) {
        env_state = .unset;
        var buf: [16]u16 = undefined;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_ANIMATIONS");
        const n = GetEnvironmentVariableW(name, &buf, buf.len);
        if (n > 0 and n < buf.len) {
            var ascii: [16]u8 = undefined;
            for (buf[0..n], 0..) |unit, i| ascii[i] = if (unit < 0x80) @intCast(unit) else '?';
            if (parseOverride(ascii[0..n])) |value| env_state = if (value) .on else .off;
        }
    }
    return switch (env_state) {
        .on => true,
        .off => false,
        .unread, .unset => null,
    };
}

const SPI_GETCLIENTAREAANIMATION: u32 = 0x1042;
const SM_REMOTESESSION: i32 = 0x1000;

fn clientAreaAnimation() bool {
    var on: i32 = 1;
    if (SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, @ptrCast(&on), 0) == 0) return true;
    return on != 0;
}

fn remoteSession() bool {
    return w32.GetSystemMetrics(SM_REMOTESESSION) != 0;
}

// -----------------------------------------------------------------------
// Time
// -----------------------------------------------------------------------

var qpc_frequency: u64 = 0;

fn frequency() u64 {
    if (qpc_frequency == 0) {
        var f: i64 = 0;
        _ = w32.QueryPerformanceFrequency(&f);
        qpc_frequency = @intCast(@max(f, 1));
    }
    return qpc_frequency;
}

/// The current time in nanoseconds of the performance counter: the
/// clock of `Tween` and of `Animator.tick`.
pub fn now() u64 {
    var counter: i64 = 0;
    _ = w32.QueryPerformanceCounter(&counter);
    const ticks: u128 = @intCast(@max(counter, 0));
    return @intCast(ticks * std.time.ns_per_s / frequency());
}

// -----------------------------------------------------------------------
// Clock
// -----------------------------------------------------------------------

/// A running animation, embedded in its owner (find the owner with
/// `@fieldParentPtr`). Stop it before the owner goes away.
pub const Animator = struct {
    /// Called on the GUI thread once per frame with the frame time while
    /// running; return false when the animation is over (it stops).
    tick: *const fn (animator: *Animator, now_ns: u64) bool,
    running: bool = false,
};

/// The message the clock thread posts to the clock window; its class is
/// private to this module.
pub const WM_TICK: u32 = w32.WM_APP + 37;

const max_animators = 128;
/// The sleep instead of a composition wait when DWM does not wait.
const fallback_frame_ms = 15;

const Clock = struct {
    hwnd: ?w32.HWND = null,
    wake: ?w32.HANDLE = null,
    unavailable: bool = false,
    animators: [max_animators]*Animator = undefined,
    count: usize = 0,
    /// The animator being called while `dispatching` (stop moves it).
    cursor: usize = 0,
    dispatching: bool = false,
    /// Shared with the clock thread.
    active: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
};

var clock: Clock = .{};

/// Call `animator.tick` once per frame from now on. Returns false (and
/// the caller jumps to the end state) when there is no clock.
pub fn start(animator: *Animator) bool {
    if (animator.running) return true;
    if (!ensureClock()) return false;
    if (clock.count == max_animators) {
        log.warn("too many animations running", .{});
        return false;
    }
    clock.animators[clock.count] = animator;
    clock.count += 1;
    animator.running = true;
    if (!clock.active.swap(true, .acq_rel)) _ = w32.SetEvent(clock.wake.?);
    return true;
}

/// Stop calling `animator.tick`.
pub fn stop(animator: *Animator) void {
    if (!animator.running) return;
    animator.running = false;
    for (clock.animators[0..clock.count], 0..) |a, i| {
        if (a != animator) continue;
        std.mem.copyForwards(*Animator, clock.animators[i .. clock.count - 1], clock.animators[i + 1 .. clock.count]);
        clock.count -= 1;
        if (clock.dispatching and i <= clock.cursor) clock.cursor -%= 1;
        break;
    }
    if (clock.count == 0) clock.active.store(false, .release);
}

/// Whether any animation is running.
pub fn busy() bool {
    return clock.count > 0;
}

fn onTick() void {
    const t = now();
    clock.dispatching = true;
    clock.cursor = 0;
    while (clock.cursor < clock.count) {
        const animator = clock.animators[clock.cursor];
        if (!animator.tick(animator, t)) stop(animator);
        clock.cursor +%= 1;
    }
    clock.dispatching = false;
    clock.pending.store(false, .release);
}

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxAnimClock");

fn ensureClock() bool {
    if (clock.hwnd != null) return true;
    if (clock.unavailable) return false;
    // Set again on success below; a failure is not retried.
    clock.unavailable = true;

    const hinstance = w32.GetModuleHandleW(null) orelse return false;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &clockWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("cannot register the animation clock window class", .{});
        return false;
    }
    const hwnd = w32.CreateWindowExW(0, CLASS_NAME, CLASS_NAME, 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, hinstance, null) orelse {
        log.warn("cannot create the animation clock window", .{});
        return false;
    };
    const wake = w32.CreateEventW(null, 0, 0, null) orelse {
        _ = w32.DestroyWindow(hwnd);
        return false;
    };
    _ = frequency();
    const thread = std.Thread.spawn(.{}, clockThread, .{ hwnd, wake }) catch |err| {
        log.warn("cannot start the animation clock err={}", .{err});
        _ = w32.CloseHandle(wake);
        _ = w32.DestroyWindow(hwnd);
        return false;
    };
    thread.detach();
    clock.hwnd = hwnd;
    clock.wake = wake;
    clock.unavailable = false;
    return true;
}

fn clockWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (msg == WM_TICK) {
        onTick();
        return 0;
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The clock thread: one tick per composed frame while animations run.
fn clockThread(hwnd: w32.HWND, wake: w32.HANDLE) void {
    while (true) {
        if (!clock.active.load(.acquire)) {
            _ = w32.WaitForSingleObject(wake, w32.INFINITE);
            continue;
        }
        const before = now();
        const hr = DwmFlush();
        // DwmFlush returns at once when nothing is composed: wait a frame.
        if (hr < 0 or now() -| before < std.time.ns_per_ms) w32.Sleep(fallback_frame_ms);
        if (!clock.active.load(.acquire)) continue;
        // The GUI thread has not handled the last tick yet: skip a frame.
        if (clock.pending.swap(true, .acq_rel)) continue;
        if (w32.PostMessageW(hwnd, WM_TICK, 0, 0) == 0) clock.pending.store(false, .release);
    }
}

extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;

test "curves start at 0, end at 1 and ease the right way" {
    const testing = std.testing;
    inline for (.{ Curve.linear, Curve.decelerate, Curve.accelerate, Curve.ease }) |curve| {
        try testing.expectEqual(@as(f32, 0), curve.at(0));
        try testing.expectEqual(@as(f32, 1), curve.at(1));
        try testing.expectEqual(@as(f32, 0), curve.at(-1));
        try testing.expectEqual(@as(f32, 1), curve.at(2));
        // Monotonic.
        var last: f32 = 0;
        for (1..100) |i| {
            const v = curve.at(@as(f32, @floatFromInt(i)) / 100);
            try testing.expect(v >= last - 1e-5);
            last = v;
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 0.5), Curve.linear.at(0.5), 1e-4);
    // cubic-bezier(0,0,0,1) at x = 0.5: t = cbrt(0.5), y = 3t^2 - 2t^3.
    const t = std.math.cbrt(@as(f32, 0.5));
    try testing.expectApproxEqAbs(3 * t * t - 2 * t * t * t, Curve.decelerate.at(0.5), 1e-4);
    // Decelerate is ahead of linear, accelerate behind it.
    try testing.expect(Curve.decelerate.at(0.25) > 0.6);
    try testing.expect(Curve.accelerate.at(0.25) < 0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Curve.ease.at(0.5), 1e-3);
}

test "inverse finds where a curve reaches a value" {
    const testing = std.testing;
    inline for (.{ Curve.linear, Curve.decelerate, Curve.accelerate, Curve.ease }) |curve| {
        for ([_]f32{ 0.1, 0.25, 0.5, 0.8, 0.95 }) |x| {
            try testing.expectApproxEqAbs(x, curve.inverse(curve.at(x)), 2e-3);
        }
    }
    // A slide-in reversed at 70 % continues from the same position with
    // the accelerating curve.
    const shown = Curve.decelerate.at(0.4);
    const out_start = Curve.accelerate.inverse(1 - shown);
    try testing.expectApproxEqAbs(1 - shown, Curve.accelerate.at(out_start), 1e-3);
}

test "tweens follow the clock, not the frames" {
    const testing = std.testing;
    const ms = std.time.ns_per_ms;
    const tween = Tween.begin(1000 * ms, duration_ms.fast, Curve.linear);
    try testing.expectEqual(@as(f32, 0), tween.progress(1000 * ms));
    try testing.expectEqual(@as(f32, 0), tween.progress(900 * ms));
    try testing.expectApproxEqAbs(@as(f32, 0.5), tween.linear(1000 * ms + 83 * ms + ms / 2), 1e-3);
    try testing.expect(!tween.done(1100 * ms));
    // A frame that comes late lands where the time says.
    try testing.expect(tween.done(1167 * ms));
    try testing.expectEqual(@as(f32, 1), tween.progress(5000 * ms));
    try testing.expectApproxEqAbs(@as(f32, 128), tween.lerp(1000 * ms + 83 * ms + ms / 2, 0, 255), 0.5);
    // Zero duration is done at once.
    const instant = Tween.begin(0, 0, Curve.decelerate);
    try testing.expect(instant.done(0));
    try testing.expectEqual(@as(f32, 1), instant.progress(0));
}

test "animations follow the system setting, remote sessions and the override" {
    const testing = std.testing;
    try testing.expect(decide(null, true, false));
    try testing.expect(!decide(null, false, false));
    try testing.expect(!decide(null, true, true));
    try testing.expect(decide(true, false, true));
    try testing.expect(!decide(false, true, false));

    try testing.expectEqual(@as(?bool, true), parseOverride("1"));
    try testing.expectEqual(@as(?bool, true), parseOverride(" On "));
    try testing.expectEqual(@as(?bool, false), parseOverride("0"));
    try testing.expectEqual(@as(?bool, false), parseOverride("FALSE"));
    try testing.expectEqual(@as(?bool, null), parseOverride(""));
    try testing.expectEqual(@as(?bool, null), parseOverride("maybe"));
}

test "stopping animators while the clock calls them" {
    const testing = std.testing;
    const Counter = struct {
        animator: Animator = .{ .tick = tick },
        ticks: u32 = 0,
        limit: u32,
        /// Another animator this one stops on its first tick.
        victim: ?*Animator = null,

        fn tick(animator: *Animator, _: u64) bool {
            const self: *@This() = @fieldParentPtr("animator", animator);
            self.ticks += 1;
            if (self.victim) |v| stop(v);
            return self.ticks < self.limit;
        }
    };
    // Run the dispatch without the window or the thread.
    const saved = clock;
    defer clock = saved;
    clock = .{};

    var a: Counter = .{ .limit = 1 };
    var c: Counter = .{ .limit = 3 };
    var b: Counter = .{ .limit = 3, .victim = &c.animator };
    for ([_]*Counter{ &a, &b, &c }) |counter| {
        clock.animators[clock.count] = &counter.animator;
        clock.count += 1;
        counter.animator.running = true;
    }
    onTick();
    // a finished, b stopped c before c's turn.
    try testing.expectEqual(@as(u32, 1), a.ticks);
    try testing.expectEqual(@as(u32, 1), b.ticks);
    try testing.expectEqual(@as(u32, 0), c.ticks);
    try testing.expect(!a.animator.running and b.animator.running and !c.animator.running);
    try testing.expectEqual(@as(usize, 1), clock.count);
    onTick();
    onTick();
    try testing.expectEqual(@as(u32, 3), b.ticks);
    try testing.expectEqual(@as(usize, 0), clock.count);
    try testing.expect(!busy());
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
