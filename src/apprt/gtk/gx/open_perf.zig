//! Opt-in action-to-map measurements for GX popovers and dialogs.
//!
//! An opening is timed from its action (or its call) to the map of what
//! it shows, in phases like the Windows popups (`<ui>.open.<phase>`):
//! `prepare` until what opens is found, `create` for building it,
//! `layout` for filling it in and choosing what it shows, and `show` from
//! presenting until the map. The phases add up to `<ui>.open.total`, and
//! an opening that never maps records none of them.
const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const perf = @import("../../../gx/perf.zig");

const data_key = "gx-open-perf";
var action_start: ?perf.Instant = null;

/// The GTK action dispatcher runs on the GUI thread. Preserve nested actions.
pub const ActionScope = struct {
    previous: ?perf.Instant,

    pub fn begin(measured: bool) ActionScope {
        const previous = action_start;
        if (measured and perf.enabled()) action_start = perf.now(global.io());
        return .{ .previous = previous };
    }

    pub fn end(self: ActionScope) void {
        action_start = self.previous;
    }
};

/// What opens, the `<ui>` of its metric names.
pub const Kind = enum { menu, settings };

/// The measured phases before presenting; `show` is the rest of `total`.
pub const Phase = enum { prepare, create, layout };

const metric_count = 5;

fn metricNames(kind: Kind) *const [metric_count][]const u8 {
    return switch (kind) {
        inline else => |tag| comptime &.{
            @tagName(tag) ++ ".open.prepare",
            @tagName(tag) ++ ".open.create",
            @tagName(tag) ++ ".open.layout",
            @tagName(tag) ++ ".open.show",
            @tagName(tag) ++ ".open.total",
        },
    };
}

/// One opening; null (`begin`) while measurements are off.
pub const Timing = struct {
    kind: Kind,
    start: perf.Instant,
    last: perf.Instant,
    phases: [3]u64 = @splat(0),

    /// Ends `phase`, which ran since the previous lap (or the start).
    fn lapAt(self: *Timing, phase: Phase, at: perf.Instant) void {
        self.phases[@backingInt(phase)] += perf.elapsedUs(self.last, at);
        self.last = at;
    }

    /// The samples of an opening that mapped at `at`, in the order of
    /// `metricNames`: the measured phases, `show` as the rest of the
    /// total, and the total.
    fn samples(self: Timing, at: perf.Instant) [metric_count]u64 {
        const total = perf.elapsedUs(self.start, at);
        var work: u64 = 0;
        for (self.phases) |us| work += us;
        return .{ self.phases[0], self.phases[1], self.phases[2], total -| work, total };
    }
};

pub fn begin(kind: Kind) ?Timing {
    if (!perf.enabled()) return null;
    const at = action_start orelse perf.now(global.io());
    return .{ .kind = kind, .start = at, .last = at };
}

/// Ends `phase` of the opening `timing`, if measured.
pub fn lap(timing: *?Timing, phase: Phase) void {
    if (timing.*) |*value| value.lapAt(phase, perf.now(global.io()));
}

/// Diagnostic steps within a phase, each recorded as `<metric> <us>us`
/// while measurements are on.
pub const Steps = struct {
    last: ?perf.Instant,

    pub fn begin() Steps {
        return .{ .last = if (perf.enabled()) perf.now(global.io()) else null };
    }

    /// Records the time since the previous step (or `begin`) as `metric`.
    pub fn step(self: *Steps, metric: []const u8) void {
        const last = self.last orelse return;
        const at = perf.now(global.io());
        perf.record(metric, perf.elapsedUs(last, at));
        self.last = at;
    }
};

const Record = struct {
    timing: ?Timing = null,
    presenting: bool = true,
    mapped_since_arm: bool = false,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Record = @ptrCast(@alignCast(data orelse return));
        std.heap.c_allocator.destroy(self);
    }

    fn finish(self: *Record) void {
        if (!self.mapped_since_arm) return;
        const timing = self.timing orelse return;
        self.timing = null;
        const values = timing.samples(perf.now(global.io()));
        for (metricNames(timing.kind), values) |metric, us| perf.record(metric, us);
    }
};

/// Arm before present/popup, after the measured phases. The map handler
/// runs after GTK's default handler. Object data owns the record; a
/// destroyed, never-mapped widget emits no sample.
pub fn watch(widget: *gtk.Widget, timing: ?Timing) void {
    const value = timing orelse return;
    const object = widget.as(gobject.Object);
    if (widget.getMapped() != 0) {
        if (object.getData(data_key)) |data| {
            const previous: *Record = @ptrCast(@alignCast(data));
            cancelled(widget, previous);
        }
        return;
    }
    const record: *Record = if (object.getData(data_key)) |data|
        @ptrCast(@alignCast(data))
    else record: {
        const created = std.heap.c_allocator.create(Record) catch return;
        created.* = .{};
        object.setDataFull(data_key, created, &Record.destroy);
        _ = gtk.Widget.signals.map.connect(widget, *Record, mapped, created, .{ .after = true });
        _ = gtk.Widget.signals.unmap.connect(widget, *Record, cancelled, created, .{ .after = true });
        _ = gtk.Widget.signals.hide.connect(widget, *Record, cancelled, created, .{ .after = true });
        break :record created;
    };
    record.* = .{ .timing = value };
}

fn mapped(_: *gtk.Widget, record: *Record) callconv(.c) void {
    if (record.timing == null) return;
    record.mapped_since_arm = true;
    // A synchronous map may precede the caller's final menu setup.
    if (!record.presenting) record.finish();
}

fn cancelled(_: *gtk.Widget, record: *Record) callconv(.c) void {
    record.timing = null;
    record.mapped_since_arm = false;
}

/// Re-presenting an already mapped dialog has no new map signal.
pub fn presented(widget: *gtk.Widget, timing: ?Timing) void {
    if (timing == null) return;
    const data = widget.as(gobject.Object).getData(data_key) orelse return;
    const record: *Record = @ptrCast(@alignCast(data));
    record.presenting = false;
    if (widget.getVisible() == 0) {
        cancelled(widget, record);
        return;
    }
    if (widget.getMapped() != 0) record.finish();
}

test "disabled opening does not require a clock" {
    const before = perf.enabled();
    defer perf.setEnabled(before);
    perf.setEnabled(false);
    try std.testing.expect(begin(.menu) == null);
    var timing = begin(.settings);
    lap(&timing, .prepare);
    try std.testing.expect(timing == null);
    var steps: Steps = .begin();
    steps.step("test.step");
    try std.testing.expect(steps.last == null);
    const scope = ActionScope.begin(true);
    defer scope.end();
    try std.testing.expect(action_start == null);
}

test "the phases of an opening add up to its total" {
    const start: perf.Instant = .{ .nanoseconds = 1_000_000 };
    var timing: Timing = .{ .kind = .settings, .start = start, .last = start };
    timing.lapAt(.prepare, .{ .nanoseconds = 1_200_000 });
    timing.lapAt(.create, .{ .nanoseconds = 4_200_000 });
    timing.lapAt(.layout, .{ .nanoseconds = 5_000_000 });
    // A phase lapped twice adds up; the reused path has no create phase.
    timing.lapAt(.layout, .{ .nanoseconds = 5_100_000 });
    const values = timing.samples(.{ .nanoseconds = 6_000_000 });
    try std.testing.expectEqual([_]u64{ 200, 3000, 900, 900, 5000 }, values);
    try std.testing.expectEqualStrings("settings.open.show", metricNames(.settings)[3]);
    try std.testing.expectEqualStrings("menu.open.total", metricNames(.menu)[4]);
    // A clock that went back records no negative show.
    try std.testing.expectEqual(@as(u64, 0), timing.samples(.{ .nanoseconds = 5_050_000 })[3]);
    // `lap` advances the opening it is given, not a copy.
    var measured: ?Timing = .{ .kind = .menu, .start = start, .last = start };
    lap(&measured, .prepare);
    try std.testing.expect(measured.?.last.nanoseconds != start.nanoseconds);
}

test "mapped opening completes once and disabled widgets have no measurement data" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const before = perf.enabled();
    defer perf.setEnabled(before);
    const window = gtk.Window.new();
    defer window.destroy();
    const widget = window.as(gtk.Widget);
    perf.setEnabled(false);
    watch(widget, begin(.menu));
    try std.testing.expect(widget.as(gobject.Object).getData(data_key) == null);
    perf.setEnabled(true);
    const started = begin(.menu);
    watch(widget, started);
    const record: *Record = @ptrCast(@alignCast(widget.as(gobject.Object).getData(data_key).?));
    try std.testing.expect(record.timing != null);
    window.present();
    presented(widget, started);
    try std.testing.expect(widget.getMapped() != 0);
    try std.testing.expect(record.timing == null);
    presented(widget, started);
    try std.testing.expect(record.timing == null);
    // Reopening a visible dialog is not a new map measurement.
    watch(widget, begin(.menu));
    try std.testing.expect(record.timing == null);
    window.present();
    presented(widget, started);
    try std.testing.expect(record.timing == null);
}

test "failed and cancelled openings cannot measure a later unrelated map" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const before = perf.enabled();
    defer perf.setEnabled(before);
    perf.setEnabled(true);
    const window = gtk.Window.new();
    defer window.destroy();
    const widget = window.as(gtk.Widget);
    const started = begin(.settings);
    watch(widget, started);
    const record: *Record = @ptrCast(@alignCast(widget.as(gobject.Object).getData(data_key).?));
    // Simulate present/popup returning without ever making the widget visible.
    presented(widget, started);
    try std.testing.expect(record.timing == null);
    window.present();
    try std.testing.expect(record.timing == null);
    widget.setVisible(0);
    watch(widget, started);
    widget.setVisible(1);
    widget.setVisible(0);
    try std.testing.expect(record.timing == null);
}
