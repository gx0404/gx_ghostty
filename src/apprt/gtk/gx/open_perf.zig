//! Opt-in action-to-map measurements for GX popovers and dialogs.
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

pub fn begin() ?perf.Instant {
    if (!perf.enabled()) return null;
    return action_start orelse perf.now(global.io());
}

const Record = struct {
    start: ?perf.Instant = null,
    metric: []const u8 = "",
    presenting: bool = true,
    mapped_since_arm: bool = false,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Record = @ptrCast(@alignCast(data orelse return));
        std.heap.c_allocator.destroy(self);
    }

    fn finish(self: *Record) void {
        if (!self.mapped_since_arm) return;
        const start = self.start orelse return;
        self.start = null;
        perf.record(self.metric, perf.sinceUs(global.io(), start));
    }
};

/// Arm before present/popup. The map handler runs after GTK's default handler.
/// Object data owns the record; a destroyed, never-mapped widget emits no sample.
pub fn watch(widget: *gtk.Widget, metric: []const u8, start: ?perf.Instant) void {
    const instant = start orelse return;
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
        const value = std.heap.c_allocator.create(Record) catch return;
        value.* = .{};
        object.setDataFull(data_key, value, &Record.destroy);
        _ = gtk.Widget.signals.map.connect(widget, *Record, mapped, value, .{ .after = true });
        _ = gtk.Widget.signals.unmap.connect(widget, *Record, cancelled, value, .{ .after = true });
        _ = gtk.Widget.signals.hide.connect(widget, *Record, cancelled, value, .{ .after = true });
        break :record value;
    };
    record.* = .{ .start = instant, .metric = metric };
}

fn mapped(_: *gtk.Widget, record: *Record) callconv(.c) void {
    if (record.start == null) return;
    record.mapped_since_arm = true;
    // A synchronous map may precede the caller's final menu setup.
    if (!record.presenting) record.finish();
}

fn cancelled(_: *gtk.Widget, record: *Record) callconv(.c) void {
    record.start = null;
    record.mapped_since_arm = false;
}

/// Re-presenting an already mapped dialog has no new map signal.
pub fn presented(widget: *gtk.Widget, start: ?perf.Instant) void {
    if (start == null) return;
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
    try std.testing.expect(begin() == null);
    const scope = ActionScope.begin(true);
    defer scope.end();
    try std.testing.expect(action_start == null);
}

test "mapped opening completes once and disabled widgets have no measurement data" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const before = perf.enabled();
    defer perf.setEnabled(before);
    const window = gtk.Window.new();
    defer window.destroy();
    const widget = window.as(gtk.Widget);
    perf.setEnabled(false);
    watch(widget, "test.open.total", begin());
    try std.testing.expect(widget.as(gobject.Object).getData(data_key) == null);
    perf.setEnabled(true);
    const started = begin();
    watch(widget, "test.open.total", started);
    const record: *Record = @ptrCast(@alignCast(widget.as(gobject.Object).getData(data_key).?));
    try std.testing.expect(record.start != null);
    window.present();
    presented(widget, started);
    try std.testing.expect(widget.getMapped() != 0);
    try std.testing.expect(record.start == null);
    presented(widget, started);
    try std.testing.expect(record.start == null);
    // Reopening a visible dialog is not a new map measurement.
    watch(widget, "test.open.total", begin());
    try std.testing.expect(record.start == null);
    window.present();
    presented(widget, started);
    try std.testing.expect(record.start == null);
}

test "failed and cancelled openings cannot measure a later unrelated map" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const before = perf.enabled();
    defer perf.setEnabled(before);
    perf.setEnabled(true);
    const window = gtk.Window.new();
    defer window.destroy();
    const widget = window.as(gtk.Widget);
    const started = begin();
    watch(widget, "test.open.total", started);
    const record: *Record = @ptrCast(@alignCast(widget.as(gobject.Object).getData(data_key).?));
    // Simulate present/popup returning without ever making the widget visible.
    presented(widget, started);
    try std.testing.expect(record.start == null);
    window.present();
    try std.testing.expect(record.start == null);
    widget.setVisible(0);
    watch(widget, "test.open.total", started);
    widget.setVisible(1);
    widget.setVisible(0);
    try std.testing.expect(record.start == null);
}
