//! The frame clock of the custom-drawn UI: time-based `Tween`s, whether
//! to animate at all (`enabled`), and a clock that calls running
//! animations once per display refresh. The durations and easing curves
//! are the shared ones of `gx.motion` (re-exported as `motion`): Fluent's
//! 83/167/250 ms, entering elements `motion.enter`, leaving ones
//! `motion.exit`, movements `motion.ease`.
//!
//! The clock: while an `Animator` runs, a background thread waits for the
//! next DWM composition (`DwmFlush`) and posts one `WM_TICK` to a
//! message-only window of this module (class `GhosttyGxAnimClock`); the GUI
//! thread then calls every running animator. The next tick is posted only
//! after the GUI thread handled the previous one, so a busy GUI thread gets
//! fewer ticks rather than a queue of them, and without running animators
//! the thread sleeps on an event. The thread starts with the first
//! animation and is detached: it lives until the process exits. Animations
//! compute their progress from the elapsed time (`Tween`), so a late frame
//! skips ahead instead of slowing the animation down. The clock thread
//! follows the idea of Zed's Windows vsync thread (Apache-2.0, idea only):
//! DwmFlush in a loop, sleeping a refresh period when it returns at once.
//!
//! `enabled` is `motion.enabled` for this system: the Windows "Animation
//! effects" setting (`SPI_GETCLIENTAREAANIMATION`), off in remote sessions
//! (`SM_REMOTESESSION`), and `GHOSTTY_GX_ANIMATIONS` (read once) overrides
//! both. Callers ask it when an animation would start and jump to the end
//! state when it says no.
//!
//! Everything except the clock thread runs on the GUI thread.
const std = @import("std");
const w32 = @import("../win32.zig");

/// The shared durations and curves (`gx.motion`).
pub const motion = @import("../../../gx/motion.zig");

const log = std.log.scoped(.win32_anim);

/// Progress of an animation over time: started at `start_ns` (see
/// `now`), lasting `duration_ns`, eased by `curve`.
pub const Tween = struct {
    start_ns: u64,
    duration_ns: u64,
    curve: motion.CubicBezier = motion.enter,

    pub fn begin(now_ns: u64, ms: u32, curve: motion.CubicBezier) Tween {
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
    return motion.enabled(.{
        .system = clientAreaAnimation(),
        .remote_session = remoteSession(),
        .override = envOverride(),
    });
}

var env_read = false;
var env_buf: [16]u8 = undefined;
var env_len: usize = 0;

/// The value of `motion.env_override`, read once; null when unset or too
/// long to be a valid value.
fn envOverride() ?[]const u8 {
    if (!env_read) {
        env_read = true;
        var buf: [env_buf.len]u16 = undefined;
        const name = std.unicode.utf8ToUtf16LeStringLiteral(motion.env_override);
        const n = GetEnvironmentVariableW(name, &buf, buf.len);
        if (n > 0 and n < buf.len) {
            for (buf[0..n], 0..) |unit, i| env_buf[i] = if (unit < 0x80) @intCast(unit) else '?';
            env_len = n;
        }
    }
    return if (env_len > 0) env_buf[0..env_len] else null;
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
/// `@fieldParentPtr`). The owner stops it before it goes away, also from
/// inside its own tick: a tick may `stop` its animator and then free the
/// owner, and the clock does not touch a stopped animator again. A tick
/// that returns false without stopping is stopped by the clock after it
/// returns, so its owner must still be alive then.
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
        if (!animator.tick(animator, t)) {
            // Unless the tick stopped it itself: then `stop` moved the
            // cursor and the animator, whose owner may be gone, is left
            // alone.
            if (clock.cursor < clock.count and clock.animators[clock.cursor] == animator) stop(animator);
        }
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
    // Never joined: the thread waits on `wake` while nothing animates and
    // ends with the process.
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
/// It never returns; the process exit ends it.
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

test "tweens follow the clock, not the frames" {
    const testing = std.testing;
    const ms = std.time.ns_per_ms;
    const tween = Tween.begin(1000 * ms, motion.duration.fast, motion.linear);
    try testing.expectEqual(@as(f32, 0), tween.progress(1000 * ms));
    try testing.expectEqual(@as(f32, 0), tween.progress(900 * ms));
    try testing.expectApproxEqAbs(@as(f32, 0.5), tween.linear(1000 * ms + 83 * ms + ms / 2), 1e-3);
    try testing.expect(!tween.done(1100 * ms));
    // A frame that comes late lands where the time says.
    try testing.expect(tween.done(1167 * ms));
    try testing.expectEqual(@as(f32, 1), tween.progress(5000 * ms));
    try testing.expectApproxEqAbs(@as(f32, 128), tween.lerp(1000 * ms + 83 * ms + ms / 2, 0, 255), 0.5);
    // Zero duration is done at once.
    const instant = Tween.begin(0, 0, motion.enter);
    try testing.expect(instant.done(0));
    try testing.expectEqual(@as(f32, 1), instant.progress(0));
    // The default curve decelerates, like the popup fade-in.
    const fade = Tween.begin(0, motion.duration.fast, motion.enter);
    try testing.expectEqual(motion.enter.at(0.5), fade.progress(83 * ms + ms / 2));
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

test "a tick that stops its own animator is not touched again" {
    const testing = std.testing;
    const Owner = struct {
        animator: Animator = .{ .tick = tick },
        ticks: u32 = 0,

        fn tick(animator: *Animator, _: u64) bool {
            const self: *@This() = @fieldParentPtr("animator", animator);
            self.ticks += 1;
            stop(animator);
            // What a freed owner could hold: the clock must not stop it
            // again or read it.
            animator.running = true;
            return false;
        }
    };
    const saved = clock;
    defer clock = saved;
    clock = .{};

    var first: Owner = .{};
    var second: Owner = .{};
    for ([_]*Owner{ &first, &second }) |owner| {
        clock.animators[clock.count] = &owner.animator;
        clock.count += 1;
        owner.animator.running = true;
    }
    onTick();
    // Both ran once and left the clock; the clock left their (garbage)
    // state alone.
    try testing.expectEqual(@as(u32, 1), first.ticks);
    try testing.expectEqual(@as(u32, 1), second.ticks);
    try testing.expectEqual(@as(usize, 0), clock.count);
    try testing.expect(first.animator.running and second.animator.running);
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
