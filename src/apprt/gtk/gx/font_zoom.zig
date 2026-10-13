const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");
const glib = @import("glib");
const font_zoom = @import("../../../gx/font_zoom.zig");
const Surface = @import("../class/surface.zig").Surface;
const Application = @import("../class/application.zig").Application;

const log = std.log.scoped(.gtk_gx_font_zoom);
const key = "gx-font-zoom";

const State = struct {
    alloc: std.mem.Allocator,
    owner: *Surface,
    widget: *gtk.Widget,
    enabled: bool = false,
    wheel: font_zoom.WheelAccumulator = .{},
    pinch: font_zoom.PinchState = .{},
    last_scroll: i64 = 0,
    gesture: ?*gtk.GestureZoom = null,
    gesture_handlers: [4]c_ulong = @splat(0),
    keys: ?*gtk.EventControllerKey = null,
    key_handler: c_ulong = 0,
    focus: ?*gtk.EventControllerFocus = null,
    focus_handler: c_ulong = 0,
    scroll: ?*gtk.EventControllerScroll = null,
    scroll_handlers: [2]c_ulong = @splat(0),

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data orelse return));
        self.alloc.destroy(self);
    }

    fn reset(self: *State) void {
        self.wheel.reset();
        self.pinch.reset();
        self.last_scroll = 0;
    }

    fn detach(self: *State) void {
        self.enabled = false;
        self.reset();
        if (self.scroll) |ec| {
            self.scroll = null;
            for (self.scroll_handlers) |id| gobject.signalHandlerDisconnect(ec.as(gobject.Object), id);
            ec.unref();
        }
        if (self.gesture) |gesture| {
            self.gesture = null;
            for (self.gesture_handlers) |id| gobject.signalHandlerDisconnect(gesture.as(gobject.Object), id);
            gesture.as(gtk.EventController).reset();
            self.widget.removeController(gesture.as(gtk.EventController));
        }
        if (self.keys) |ec| {
            self.keys = null;
            gobject.signalHandlerDisconnect(ec.as(gobject.Object), self.key_handler);
            self.widget.removeController(ec.as(gtk.EventController));
        }
        if (self.focus) |ec| {
            self.focus = null;
            gobject.signalHandlerDisconnect(ec.as(gobject.Object), self.focus_handler);
            self.widget.removeController(ec.as(gtk.EventController));
        }
    }
};

fn state(owner: *Surface) ?*State {
    return @ptrCast(@alignCast(owner.as(gobject.Object).getData(key) orelse return null));
}

pub fn sync(owner: *Surface, widget: *gtk.Widget, enabled: bool) void {
    const st = state(owner) orelse create: {
        const alloc = Application.default().allocator();
        const value = alloc.create(State) catch return;
        value.* = .{ .alloc = alloc, .owner = owner, .widget = widget };
        owner.as(gobject.Object).setDataFull(key, value, &State.destroy);
        break :create value;
    };
    st.reset();
    if (!enabled) {
        st.detach();
        return;
    }
    if (st.gesture) |gesture| {
        gesture.as(gtk.EventController).reset();
        st.enabled = true;
        return;
    }
    st.enabled = true;

    const gesture: *gtk.GestureZoom = @ptrCast(gtk.GestureZoom.new());
    gesture.as(gtk.EventController).setPropagationPhase(.capture);
    st.gesture_handlers = .{
        gtk.Gesture.signals.begin.connect(gesture.as(gtk.Gesture), *State, pinchBegin, st, .{}),
        gtk.Gesture.signals.end.connect(gesture.as(gtk.Gesture), *State, pinchEnd, st, .{}),
        gtk.Gesture.signals.cancel.connect(gesture.as(gtk.Gesture), *State, pinchEnd, st, .{}),
        gtk.GestureZoom.signals.scale_changed.connect(gesture, *State, pinchScale, st, .{}),
    };
    st.gesture = gesture;
    widget.addController(gesture.as(gtk.EventController));

    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    st.key_handler = gtk.EventControllerKey.signals.key_released.connect(keys, *State, keyReleased, st, .{});
    st.keys = keys;
    widget.addController(keys.as(gtk.EventController));

    const focus = gtk.EventControllerFocus.new();
    st.focus_handler = gtk.EventControllerFocus.signals.leave.connect(focus, *State, focusLeave, st, .{});
    st.focus = focus;
    widget.addController(focus.as(gtk.EventController));
}

pub fn dispose(owner: *Surface) void {
    const data = owner.as(gobject.Object).stealData(key) orelse return;
    const st: *State = @ptrCast(@alignCast(data));
    st.detach();
    State.destroy(data);
}

fn modifiers(value: gdk.ModifierType) font_zoom.Modifiers {
    // X11 pointer events may retain Mod3/Mod4/Mod5 without virtual masks.
    const extra_modifiers = @as(c_uint, @bitCast(value)) & 0xe0 != 0;
    return .{
        .ctrl = value.control_mask,
        .shift = value.shift_mask,
        .alt = value.alt_mask,
        .super = value.super_mask or value.meta_mask or value.hyper_mask or extra_modifiers,
    };
}

fn surfaceStep(height: c_int) f64 {
    return std.math.pow(f64, @floatFromInt(@max(height, 1)), 2.0 / 3.0);
}

pub fn scroll(owner: *Surface, ec: *gtk.EventControllerScroll, delta: f64) bool {
    const st = state(owner) orelse return false;
    if (!st.enabled) {
        st.reset();
        return false;
    }
    const core = owner.core() orelse {
        st.reset();
        return false;
    };
    if (st.scroll != ec) {
        if (st.scroll) |previous| {
            for (st.scroll_handlers) |id| gobject.signalHandlerDisconnect(previous.as(gobject.Object), id);
            previous.unref();
        }
        ec.ref();
        st.scroll = ec;
        st.scroll_handlers = .{
            gtk.EventControllerScroll.signals.scroll_begin.connect(ec, *State, scrollReset, st, .{}),
            gtk.EventControllerScroll.signals.scroll_end.connect(ec, *State, scrollReset, st, .{}),
        };
        st.wheel.reset();
    }
    const now = glib.getMonotonicTime();
    if (now - st.last_scroll > 500 * std.time.us_per_ms) st.wheel.reset();
    st.last_scroll = now;
    const steps = st.wheel.update(
        st.enabled,
        modifiers(ec.as(gtk.EventController).getCurrentEventState()),
        delta,
        if (ec.getUnit() == .surface) .surface else .wheel,
        surfaceStep(st.widget.getHeight()),
    ) orelse return false;
    if (steps != 0) setSize(owner, std.math.clamp(core.font_size.points + @as(f32, @floatFromInt(steps)), 1, 255));
    return true;
}

fn setSize(owner: *Surface, points: f32) void {
    const core = owner.core() orelse return;
    if (points == core.font_size.points) return;
    _ = core.performBindingAction(.{ .set_font_size = points }) catch |err| {
        log.warn("cannot change the font size err={}", .{err});
        return;
    };
}

fn pinchBegin(gesture: *gtk.Gesture, _: ?*gdk.EventSequence, st: *State) callconv(.c) void {
    const core = st.owner.core() orelse return;
    if (!st.pinch.begin(st.enabled, core.font_size.points)) return;
    st.wheel.reset();
    _ = gesture.setState(.claimed);
}

fn pinchEnd(_: *gtk.Gesture, _: ?*gdk.EventSequence, st: *State) callconv(.c) void {
    st.pinch.reset();
}

fn pinchScale(_: *gtk.GestureZoom, scale: f64, st: *State) callconv(.c) void {
    const points = st.pinch.update(st.enabled, scale) orelse return;
    setSize(st.owner, points);
}

fn scrollReset(_: *gtk.EventControllerScroll, st: *State) callconv(.c) void {
    st.wheel.reset();
}

fn keyReleased(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, st: *State) callconv(.c) void {
    if (keyval == gdk.KEY_Control_L or keyval == gdk.KEY_Control_R) st.wheel.reset();
}

fn focusLeave(_: *gtk.EventControllerFocus, st: *State) callconv(.c) void {
    st.reset();
}

test "font zoom modifiers allow lock states but reject Ctrl combinations" {
    const testing = std.testing;
    try testing.expect(modifiers(.{ .control_mask = true, .lock_mask = true }).ctrlOnly());
    try testing.expect(!modifiers(.{ .control_mask = true, .shift_mask = true }).ctrlOnly());
    try testing.expect(!modifiers(.{ .control_mask = true, .alt_mask = true }).ctrlOnly());
    try testing.expect(!modifiers(.{ .control_mask = true, .super_mask = true }).ctrlOnly());
    try testing.expect(!modifiers(.{ .control_mask = true, .meta_mask = true }).ctrlOnly());
    try testing.expect(modifiers(@bitCast(@as(c_uint, 0x16))).ctrlOnly());
    for ([_]c_uint{ 0x24, 0x44, 0x84 }) |raw| try testing.expect(!modifiers(@bitCast(raw)).ctrlOnly());
}

test "surface units use GTK page step rather than wheel or Windows units" {
    try std.testing.expectApproxEqAbs(@as(f64, 64), surfaceStep(512), 0.000001);
    var wheel: font_zoom.WheelAccumulator = .{};
    try std.testing.expectEqual(@as(?i32, 1), wheel.update(true, .{ .ctrl = true }, -64, .surface, surfaceStep(512)));
    try std.testing.expectEqual(@as(?i32, 1), wheel.update(true, .{ .ctrl = true }, -1, .wheel, surfaceStep(512)));
}
