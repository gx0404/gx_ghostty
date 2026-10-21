//! Tab status of a win32 window that needs no window: the progress a
//! terminal reported last (OSC 9;4, `Progress`), what a tab or a window
//! shows for the reports of its terminals (`merge`, `aggregate`) and the
//! status the tab bar draws on a tab besides its title (`TabStatus`).
//! `Window` keeps the reports (`Surface.progress`, written through
//! `Window.setSurfaceProgress`) and the per-tab flags, and hands the tab bar
//! a `TabStatus` (`Window.tabStatus`).
const std = @import("std");

/// How long a progress report counts without a newer one from its
/// terminal, so a program that died without removing its progress leaves
/// none behind (the GTK app hides its progress bar after the same time).
pub const stale_after_ms: u64 = 15_000;

/// What a progress report says, by priority: when several terminals report
/// progress, the state of the highest priority shows (`merge`).
pub const ProgressState = enum(u3) {
    /// No progress: never reported, or removed.
    none = 0,
    indeterminate = 1,
    normal = 2,
    paused = 3,
    @"error" = 4,

    fn priority(self: ProgressState) u3 {
        return @backingInt(self);
    }
};

/// The latest progress report of a terminal.
pub const Progress = struct {
    state: ProgressState = .none,
    /// 0 to 100, when the report carries a value.
    percent: ?u8 = null,
    /// When it arrived, in milliseconds of `GetTickCount64`.
    updated_ms: u64 = 0,

    pub const none: Progress = .{};

    /// Whether it counts at `now_ms`: it reports something and is at most
    /// `stale_after_ms` old.
    pub fn active(self: Progress, now_ms: u64) bool {
        return self.state != .none and now_ms -| self.updated_ms <= stale_after_ms;
    }
};

/// `acc` with the report `next` of another terminal added: the state of the
/// highest priority wins (error, paused, normal, indeterminate); reports in
/// the same state keep the lowest percent (the one furthest from done) and
/// the latest time. Reports that do not count at `now_ms` are left out.
pub fn merge(acc: Progress, next: Progress, now_ms: u64) Progress {
    if (!next.active(now_ms)) return acc;
    if (!acc.active(now_ms)) return next;
    if (next.state.priority() > acc.state.priority()) return next;
    if (next.state.priority() < acc.state.priority()) return acc;
    return .{
        .state = acc.state,
        .percent = minPercent(acc.percent, next.percent),
        .updated_ms = @max(acc.updated_ms, next.updated_ms),
    };
}

/// The progress the reports of several terminals show together (`merge`).
pub fn aggregate(reports: []const Progress, now_ms: u64) Progress {
    var acc: Progress = .none;
    for (reports) |report| acc = merge(acc, report, now_ms);
    return acc;
}

fn minPercent(a: ?u8, b: ?u8) ?u8 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

/// What the tab bar shows on a tab besides its title.
pub const TabStatus = struct {
    /// A terminal of the tab printed something since the tab was last
    /// active.
    unread: bool = false,
    /// A terminal of the tab rang the bell since the tab was last selected.
    bell: bool = false,
    /// The tab shows one of its splits zoomed.
    zoomed: bool = false,
    /// The progress its terminals report (`merge`).
    progress: Progress = .none,
};

test "merge prefers error, then paused, normal and indeterminate" {
    const testing = std.testing;
    const now: u64 = 100_000;
    const states = [_]ProgressState{ .indeterminate, .normal, .paused, .@"error" };
    for (states, 0..) |low, i| {
        for (states[i + 1 ..]) |high| {
            const a: Progress = .{ .state = low, .percent = 10, .updated_ms = now };
            const b: Progress = .{ .state = high, .percent = 90, .updated_ms = now };
            try testing.expectEqual(high, merge(a, b, now).state);
            try testing.expectEqual(high, merge(b, a, now).state);
            try testing.expectEqual(@as(?u8, 90), merge(a, b, now).percent);
        }
    }
}

test "merge keeps the lowest percent and the latest time of one state" {
    const testing = std.testing;
    const now: u64 = 100_000;
    const a: Progress = .{ .state = .normal, .percent = 80, .updated_ms = now - 500 };
    const b: Progress = .{ .state = .normal, .percent = 30, .updated_ms = now - 100 };
    const c: Progress = .{ .state = .normal, .updated_ms = now - 200 };
    const ab = merge(a, b, now);
    try testing.expectEqual(@as(?u8, 30), ab.percent);
    try testing.expectEqual(now - 100, ab.updated_ms);
    try testing.expectEqual(@as(?u8, 30), merge(ab, c, now).percent);
    try testing.expectEqual(@as(?u8, 80), merge(c, a, now).percent);
    try testing.expectEqual(@as(?u8, null), merge(c, c, now).percent);
}

test "aggregate leaves out removed and stale reports" {
    const testing = std.testing;
    const now: u64 = 100_000;
    try testing.expectEqual(Progress.none, aggregate(&.{}, now));
    const removed: Progress = .{ .state = .none, .updated_ms = now };
    const stale: Progress = .{ .state = .@"error", .percent = 5, .updated_ms = now - stale_after_ms - 1 };
    const fresh: Progress = .{ .state = .paused, .percent = 40, .updated_ms = now - stale_after_ms };
    try testing.expectEqual(Progress.none, aggregate(&.{ removed, stale }, now));
    try testing.expectEqual(fresh, aggregate(&.{ removed, stale, fresh }, now));
    try testing.expect(!stale.active(now));
    try testing.expect(fresh.active(now));
    // A report from the future (a clock that went back) still counts.
    try testing.expect((Progress{ .state = .normal, .updated_ms = now + 10 }).active(now));
}
