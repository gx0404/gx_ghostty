const std = @import("std");

pub const Input = struct {
    viewport: bool,
    preedit: bool,
    password: bool,
    visible: bool,
    focused: bool,
    blinking: bool,
};

pub fn blinkAffects(input: Input) bool {
    return input.viewport and !input.preedit and !input.password and
        input.visible and input.focused and input.blinking;
}

pub fn notify(thread: anytype, io: std.Io) void {
    if (!thread.flags.visible or !thread.flags.focused) return;
    const renderer = thread.renderer;
    renderer.draw_mutex.lockUncancelable(io);
    const wake = renderer.display_realized and renderer.gx_cursor_blink_affects;
    renderer.draw_mutex.unlock(io);
    if (wake) thread.wakeup.notify() catch {};
}

test "gx.cursor_blink: all visibility priorities" {
    for (0..64) |bits| {
        const input: Input = .{
            .viewport = bits & 1 != 0,
            .preedit = bits & 2 != 0,
            .password = bits & 4 != 0,
            .visible = bits & 8 != 0,
            .focused = bits & 16 != 0,
            .blinking = bits & 32 != 0,
        };
        try std.testing.expectEqual(bits == 57, blinkAffects(input));
    }
}

pub fn invalidate(renderer: anytype, io: std.Io) void {
    renderer.draw_mutex.lockUncancelable(io);
    defer renderer.draw_mutex.unlock(io);
    renderer.gx_cursor_blink_affects = true;
}

pub fn testStyle(comptime RenderState: type, comptime style: anytype, comptime affects: anytype) !void {
    var state: RenderState = .empty;
    for (std.meta.tags(@TypeOf(state.cursor.visual_style))) |visual| {
        for (0..64) |bits| {
            state.cursor.viewport = if (bits & 1 != 0) .{ .x = 0, .y = 0, .wide_tail = false } else null;
            state.cursor.password_input = bits & 4 != 0;
            state.cursor.visible = bits & 8 != 0;
            state.cursor.blinking = bits & 32 != 0;
            state.cursor.visual_style = visual;
            const preedit = bits & 2 != 0;
            const focused = bits & 16 != 0;
            try std.testing.expectEqual(
                style(&state, .{ .preedit = preedit, .focused = focused, .blink_visible = true }) !=
                    style(&state, .{ .preedit = preedit, .focused = focused, .blink_visible = false }),
                affects(&state, .{ .preedit = preedit, .focused = focused }),
            );
        }
    }
}

pub fn testThread(comptime Thread: type, comptime Renderer: type, comptime xev: type, comptime callback: anytype) !void {
    const Counter = struct {
        wakes: usize = 0,
        fn wake(self_: ?*@This(), _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
            result catch unreachable;
            self_.?.wakes += 1;
            return .rearm;
        }
    };
    for (0..5) |gate| {
        var renderer: Renderer = undefined;
        renderer.draw_mutex = .init;
        renderer.display_realized = gate != 2;
        renderer.gx_cursor_blink_affects = gate != 1;
        var config = try std.meta.Child(@typeInfo(@TypeOf(Thread.init)).@"fn".params[1].type.?).default(std.testing.allocator);
        defer config.deinit();
        var thread = try Thread.init(std.testing.allocator, &config, undefined, &renderer, undefined);
        defer thread.deinit();
        thread.flags.visible = gate != 3;
        thread.flags.focused = gate != 4;
        var counter: Counter = .{};
        thread.wakeup.wait(&thread.loop, &thread.wakeup_c, Counter, &counter, Counter.wake);
        try thread.loop.run(.no_wait);
        try std.testing.expectEqual(xev.CallbackAction.disarm, callback(&thread, &thread.loop, &thread.cursor_c, {}));
        for (0..4) |_| try thread.loop.run(.no_wait);
        try std.testing.expect(thread.flags.cursor_blink_visible);
        try std.testing.expect(thread.cursor_c.state() == .active);
        try std.testing.expectEqual(@as(usize, if (gate == 0) 1 else 0), counter.wakes);
        try thread.wakeup.notify();
        for (0..4) |_| try thread.loop.run(.no_wait);
        try std.testing.expectEqual(@as(usize, if (gate == 0) 2 else 1), counter.wakes);
        try std.testing.expectEqual(xev.CallbackAction.disarm, callback(&thread, &thread.loop, &thread.cursor_c, error.Canceled));
        try std.testing.expect(thread.flags.cursor_blink_visible);
        invalidate(&renderer, std.testing.io);
        try std.testing.expect(renderer.gx_cursor_blink_affects);
    }
}

pub fn testFocus(comptime Thread: type, comptime Renderer: type, comptime drain: anytype, comptime callback: anytype) !void {
    if (@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    var renderer: Renderer = undefined;
    renderer.draw_mutex = .init;
    renderer.display_realized = true;
    renderer.gx_cursor_blink_affects = false;
    renderer.focused = true;
    renderer.has_custom_shaders = false;
    renderer.kitty_animation_next_ms = null;
    renderer.display_link = null;
    var config = try std.meta.Child(@typeInfo(@TypeOf(Thread.init)).@"fn".params[1].type.?).default(std.testing.allocator);
    defer config.deinit();
    var thread = try Thread.init(std.testing.allocator, &config, undefined, &renderer, undefined);
    defer thread.deinit();
    _ = callback(&thread, &thread.loop, &thread.cursor_c, {});
    try thread.loop.run(.no_wait);
    try std.testing.expect(thread.cursor_c.state() == .active);
    _ = thread.mailbox.push(std.testing.io, .{ .focus = false }, .instant);
    try drain(&thread);
    for (0..4) |_| try thread.loop.run(.no_wait);
    try std.testing.expect(!thread.flags.focused);
    try std.testing.expect(!renderer.focused);
    try std.testing.expect(thread.cursor_c.state() == .dead);
    _ = thread.mailbox.push(std.testing.io, .{ .focus = true }, .instant);
    try drain(&thread);
    try thread.loop.run(.no_wait);
    try std.testing.expect(thread.flags.focused);
    try std.testing.expect(renderer.focused);
    try std.testing.expect(thread.flags.cursor_blink_visible);
    try std.testing.expect(thread.cursor_c.state() == .active);
    _ = thread.mailbox.push(std.testing.io, .reset_cursor_blink, .instant);
    try drain(&thread);
    for (0..4) |_| try thread.loop.run(.no_wait);
    try std.testing.expect(thread.flags.cursor_blink_visible);
    renderer.has_custom_shaders = true;
    renderer.config.custom_shader_animation = .always;
    try std.testing.expectEqual(Renderer.AnimationWake.Kind.draw, renderer.animationWake().?.kind);
    renderer.has_custom_shaders = false;
    renderer.kitty_animation_clock = .now(std.testing.io, .awake);
    renderer.kitty_animation_next_ms = 0;
    try std.testing.expectEqual(Renderer.AnimationWake.Kind.update, renderer.animationWake().?.kind);
}
