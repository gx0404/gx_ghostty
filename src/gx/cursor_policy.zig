//! Explicit cursor configuration for the GTK and Windows GX apps (GX-0057).
//! Shape and blink override program requests independently. Defaults never
//! acquire an override. The terminal stores the effective state, so rendering
//! and DECRQSS observe the same values. No renderer or lib-vt policy is added.
//!
//! Every State operation requires the owning renderer mutex (except during
//! initialization before publication). It may temporarily restore program
//! state, but calls only terminal primitives: no callbacks, messages or unlocks.
//! Screen identities are keys plus generations, never retained pointers.
const std = @import("std");
const Style = @import("../terminal/cursor.zig").Style;
const Request = @import("../terminal/ansi.zig").CursorStyle;

pub const Overrides = struct {
    style: ?Style = null,
    blink: ?bool = null,

    fn active(self: Overrides) bool {
        return self.style != null or self.blink != null;
    }
};

pub fn enabledFor(comptime runtime: anytype) bool {
    return switch (runtime) {
        .gtk, .win32 => true,
        else => false,
    };
}

pub const State = struct {
    overrides: Overrides = .{},
    styles: [2]?Saved = .{ null, null },
    blink: bool = false,

    const Saved = struct { generation: usize, style: Style };

    pub fn init(t: anytype, overrides: Overrides) State {
        var self: State = .{ .overrides = overrides };
        self.apply(t);
        return self;
    }

    pub fn request(self: *State, t: anytype, value: Request) void {
        self.restore(t);
        t.setCursorStyle(value);
        self.apply(t);
    }

    pub fn changeConfig(self: *State, t: anytype, style: Style, blink: ?bool, overrides: Overrides) void {
        self.restore(t);
        t.setDefaultCursorStyle(style);
        t.setDefaultCursorBlink(blink);
        self.overrides = overrides;
        self.apply(t);
    }

    pub fn reset(self: *State, t: anytype, comptime kind: enum { full, soft }) void {
        self.restore(t);
        switch (kind) {
            .full => t.fullReset(),
            .soft => t.softReset(),
        }
        self.apply(t);
    }

    pub fn screenMode(self: *State, t: anytype, mode: anytype, enabled: bool) !void {
        self.restore(t);
        // Even a failed allocation/cursor copy must leave effective state.
        defer self.apply(t);
        try t.switchScreenMode(mode, enabled);
    }

    pub fn resize(self: *State, t: anytype, alloc: std.mem.Allocator, opts: @TypeOf(t.*).Resize) !void {
        self.restore(t);
        // Resize can replace the active screen, fall back to primary, or fail.
        // Reacquire screen values by key/generation before publishing them.
        defer self.apply(t);
        try t.resize(alloc, opts);
    }

    pub fn deccolm(self: *State, t: anytype, alloc: std.mem.Allocator, mode: @TypeOf(t.*).DeccolmMode) !void {
        self.restore(t);
        // DECCOLM resizes internally and may fail before clearing the screen.
        defer self.apply(t);
        try t.deccolm(alloc, mode);
    }

    pub fn saveMode(self: *State, t: anytype, mode: anytype) void {
        if (mode != .cursor_blinking or self.overrides.blink == null)
            return t.modes.save(mode);
        // XTSAVE must store the hidden program blink, not the effective override.
        // Publish effective state again before returning to the stream handler.
        self.restore(t);
        t.modes.save(mode);
        self.apply(t);
    }

    pub fn restoreMode(self: *State, t: anytype, mode: anytype) bool {
        if (mode != .cursor_blinking or self.overrides.blink == null)
            return t.modes.restore(mode);
        // ModeState.restore writes before StreamHandler.setMode can reject it.
        // Preserve that program state while publishing the explicit blink.
        self.restore(t);
        const value = t.modes.restore(mode);
        self.apply(t);
        return value;
    }

    fn restore(self: *State, t: anytype) void {
        if (self.overrides.style != null) {
            inline for (.{ .primary, .alternate }, 0..) |key, i| {
                if (self.styles[i]) |saved| {
                    if (t.screens.generation(key) == saved.generation) {
                        if (t.screens.get(key)) |screen| screen.cursor.cursor_style = saved.style;
                    }
                }
            }
        }
        if (self.overrides.blink != null) t.modes.set(.cursor_blinking, self.blink);
    }

    fn apply(self: *State, t: anytype) void {
        if (!self.overrides.active()) return;
        inline for (.{ .primary, .alternate }, 0..) |key, i| {
            self.styles[i] = if (t.screens.get(key)) |screen| saved: {
                const saved: Saved = .{ .generation = t.screens.generation(key), .style = screen.cursor.cursor_style };
                if (self.overrides.style) |style| screen.cursor.cursor_style = style;
                break :saved saved;
            } else null;
        }
        self.blink = t.modes.get(.cursor_blinking);
        if (self.overrides.blink) |blink| t.modes.set(.cursor_blinking, blink);
        // is_default remains the program's choice, not the override's choice.
    }
};

test "GX0057 runtime scope" {
    const Runtime = enum { gtk, win32, none, embedded, browser };
    try std.testing.expect(enabledFor(Runtime.gtk));
    try std.testing.expect(enabledFor(Runtime.win32));
    try std.testing.expect(!enabledFor(Runtime.none));
    try std.testing.expect(!enabledFor(Runtime.embedded));
    try std.testing.expect(!enabledFor(Runtime.browser));
}

fn expectCursor(t: anytype, style: Style, blink: bool) !void {
    const terminal = @import("../terminal/main.zig");
    const testing = std.testing;
    try testing.expectEqual(style, t.screens.active.cursor.cursor_style);
    try testing.expectEqual(blink, t.modes.get(.cursor_blinking));
    var state: terminal.RenderState = .empty;
    defer state.deinit(testing.allocator);
    try state.update(testing.allocator, t);
    try testing.expectEqual(style, state.cursor.visual_style);
    try testing.expectEqual(blink, state.cursor.blinking);
    const code: u8 = switch (style) {
        .block, .block_hollow => if (blink) 1 else 2,
        .underline => if (blink) 3 else 4,
        .bar => if (blink) 5 else 6,
    };
    var response: [terminal.dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
    var expected: [32]u8 = undefined;
    const query: terminal.dcs.Command.DECRQSS = .decscusr;
    try testing.expectEqualStrings(
        try std.mem.print(&expected, "\x1bP1$r{d} q\x1b\\", .{code}),
        try query.encode(t, &response),
    );
}

test "GX0057 independent overrides and actual cursor queries" {
    const terminal = @import("../terminal/main.zig");
    const testing = std.testing;
    for ([_]?Style{ null, .block, .bar, .underline, .block_hollow }) |shape| {
        for ([_]?bool{ null, false, true }) |blink| {
            var t = try terminal.Terminal.init(testing.io, testing.allocator, .{
                .cols = 10,
                .rows = 5,
                .default_cursor_style = .block,
                .default_cursor_blink = true,
            });
            defer t.deinit(testing.allocator);
            var policy = State.init(&t, .{ .style = shape, .blink = blink });
            inline for (std.meta.tags(Request)) |request| {
                policy.request(&t, request);
                const requested_shape: Style = switch (request) {
                    .default, .blinking_block, .steady_block => .block,
                    .blinking_bar, .steady_bar => .bar,
                    .blinking_underline, .steady_underline => .underline,
                };
                const requested_blink = switch (request) {
                    .default, .blinking_block, .blinking_bar, .blinking_underline => true,
                    else => false,
                };
                try expectCursor(&t, shape orelse requested_shape, blink orelse requested_blink);
                try testing.expectEqual(request == .default, t.cursor.is_default);
            }
        }
    }
}

test "GX0057 reload releases only the removed override and resets discard old requests" {
    const terminal = @import("../terminal/main.zig");
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    var policy = State.init(&t, .{});
    policy.request(&t, .steady_bar);
    policy.changeConfig(&t, .block, true, .{ .style = .block, .blink = true });
    try expectCursor(&t, .block, true);
    policy.request(&t, .steady_underline);
    policy.changeConfig(&t, .block, true, .{ .blink = true });
    try expectCursor(&t, .underline, true);
    policy.changeConfig(&t, .block, true, .{});
    try expectCursor(&t, .underline, false);
    inline for (.{ .full, .soft }) |kind| {
        policy.changeConfig(&t, .bar, false, .{ .style = .bar, .blink = false });
        policy.request(&t, .blinking_underline);
        policy.reset(&t, kind);
        policy.changeConfig(&t, .bar, false, .{});
        try expectCursor(&t, .bar, false);
        try testing.expect(t.cursor.is_default);
    }
}

test "GX0057 screen modes and DECSC DECRC keep program state separate" {
    const terminal = @import("../terminal/main.zig");
    const testing = std.testing;
    inline for (.{ .@"47", .@"1047", .@"1049" }) |mode| {
        var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
        defer t.deinit(testing.allocator);
        var policy = State.init(&t, .{ .style = .block, .blink = true });
        policy.request(&t, .steady_bar);
        t.saveCursor();
        policy.request(&t, .steady_underline);
        t.restoreCursor();
        try expectCursor(&t, .block, true);
        try testing.expect(!t.cursor.is_default);
        try policy.screenMode(&t, mode, true);
        try expectCursor(&t, .block, true);
        policy.request(&t, .blinking_bar);
        try policy.screenMode(&t, mode, false);
        try expectCursor(&t, .block, true);
        policy.changeConfig(&t, .block, null, .{});
        try expectCursor(&t, if (mode == .@"1049") .underline else .bar, true);
        // RIS destroys the alternate screen. A subsequent generation must not
        // resurrect the shadow of the screen that RIS destroyed.
        policy.changeConfig(&t, .block, true, .{ .style = .block });
        policy.reset(&t, .full);
        try policy.screenMode(&t, mode, true);
        policy.changeConfig(&t, .block, true, .{});
        try expectCursor(&t, .block, true);
    }
}

test "GX0057 mode restore cannot bypass explicit blink" {
    const terminal = @import("../terminal/main.zig");
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.cursor_blinking, false);
    t.modes.save(.cursor_blinking);
    var policy = State.init(&t, .{ .blink = true });
    try testing.expect(!policy.restoreMode(&t, .cursor_blinking));
    try expectCursor(&t, .block, true);
    policy.changeConfig(&t, .block, null, .{});
    // Use a program request so default updates do not replace restored mode 12.
    policy.request(&t, .steady_bar);
    policy.changeConfig(&t, .block, true, .{ .blink = true });
    _ = policy.restoreMode(&t, .cursor_blinking);
    policy.changeConfig(&t, .block, null, .{});
    try expectCursor(&t, .bar, false);
}

/// Exercise the actual app stream and mailbox, not a renderer-side substitute.
pub fn testStream(comptime Handler: type) !void {
    const terminal = @import("../terminal/main.zig");
    const termio = @import("../termio.zig");
    const renderer = @import("../renderer.zig");
    const testing = std.testing;
    const cases = [_]struct { overrides: Overrides, bytes: []const u8, reply: []const u8 }{
        .{ .overrides = .{}, .bytes = "\x1b[6 q", .reply = "\x1bP1$r6 q\x1b\\" },
        .{ .overrides = .{ .style = .underline }, .bytes = "\x1b[2 q", .reply = "\x1bP1$r4 q\x1b\\" },
        .{ .overrides = .{ .blink = true }, .bytes = "\x1b[6 q", .reply = "\x1bP1$r5 q\x1b\\" },
        .{ .overrides = .{ .style = .underline, .blink = true }, .bytes = "\x1b[2 q", .reply = "\x1bP1$r3 q\x1b\\" },
        .{ .overrides = .{ .style = .bar, .blink = false }, .bytes = "\x1b[1 q\x1b7\x1b[3 q\x1b8", .reply = "\x1bP1$r6 q\x1b\\" },
        .{ .overrides = .{ .style = .bar, .blink = false }, .bytes = "\x1b[?1049h\x1b[3 q\x1b[?1049l", .reply = "\x1bP1$r6 q\x1b\\" },
        .{ .overrides = .{ .style = .bar, .blink = false }, .bytes = "\x1b[3 q\x1b[!p", .reply = "\x1bP1$r6 q\x1b\\" },
        .{ .overrides = .{ .blink = true }, .bytes = "\x1b[?12r", .reply = "\x1bP1$r1 q\x1b\\" },
        // The legacy non-null default still ignores ordinary mode 12 requests.
        .{ .overrides = .{}, .bytes = "\x1b[?12l", .reply = "\x1bP1$r1 q\x1b\\" },
    };
    for (cases) |case| {
        var t = try terminal.Terminal.init(testing.io, testing.allocator, .{
            .cols = 10,
            .rows = 5,
            .default_cursor_blink = true,
        });
        defer t.deinit(testing.allocator);
        var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
        defer mailbox.deinit(testing.allocator);
        var mutex: std.Io.Mutex = .init;
        mutex.lockUncancelable(testing.io);
        defer mutex.unlock(testing.io);
        var render_state: renderer.State = .{ .mutex = &mutex, .terminal = &t };
        var stream: Handler.Stream = .init(.{ .allocator = testing.allocator, .handler = .{
            .alloc = testing.allocator,
            .size = undefined,
            .terminal = &t,
            .gx_cursor_policy = State.init(&t, case.overrides),
            .termio_mailbox = &mailbox,
            .surface_mailbox = undefined,
            .renderer_state = &render_state,
            .renderer_mailbox = undefined,
            .renderer_wakeup = undefined,
            .enquiry_response = "",
            .osc_color_report_format = .@"16-bit",
            .clipboard_write = .deny,
            .clipboard_write_limit = 0,
            .xt_checksum_report = false,
        } });
        defer stream.deinit();
        const bytes = try std.mem.concat(testing.allocator, u8, &.{ case.bytes, "\x1bP$q q\x1b\\" });
        defer testing.allocator.free(bytes);
        stream.nextSlice(bytes);
        const message = mailbox.spsc.queue.pop(testing.io) orelse return error.MissingCursorReply;
        defer message.deinit();
        switch (message) {
            .write_small => |v| try testing.expectEqualStrings(case.reply, v.data[0..v.len]),
            .write_alloc => |v| try testing.expectEqualStrings(case.reply, v.data),
            else => return error.UnexpectedCursorReply,
        }
        try testing.expect(mailbox.spsc.queue.pop(testing.io) == null);
    }
}

/// Save mode 12 while an explicit override is already hiding program blink,
/// restore it, then remove the override through the real handler reload path.
/// Both queries use the real VT stream and PTY reply mailbox under one mutex.
pub fn testStreamModeSaveRestore(comptime Handler: type) !void {
    const terminal = @import("../terminal/main.zig");
    const termio = @import("../termio.zig");
    const renderer = @import("../renderer.zig");
    const Config = @import("../config/Config.zig");
    const testing = std.testing;
    for ([_]bool{ true, false }) |override_blink| {
        // Model the reloaded GX default without an explicit replay input.
        var config = try Config.default(testing.allocator);
        defer config.deinit();
        config.@"cursor-style-blink" = true;
        var reloaded = try termio.Termio.DerivedConfig.init(testing.allocator, &config);
        defer reloaded.deinit();
        try testing.expectEqualDeep(Overrides{}, reloaded.gx_cursor_overrides);

        var t = try terminal.Terminal.init(testing.io, testing.allocator, .{
            .cols = 10,
            .rows = 5,
            .default_cursor_blink = override_blink,
        });
        defer t.deinit(testing.allocator);
        var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
        defer mailbox.deinit(testing.allocator);
        var mutex: std.Io.Mutex = .init;
        mutex.lockUncancelable(testing.io);
        defer mutex.unlock(testing.io);
        var render_state: renderer.State = .{ .mutex = &mutex, .terminal = &t };
        var stream: Handler.Stream = .init(.{ .allocator = testing.allocator, .handler = .{
            .alloc = testing.allocator,
            .size = undefined,
            .terminal = &t,
            .gx_cursor_policy = State.init(&t, .{ .blink = override_blink }),
            .termio_mailbox = &mailbox,
            .surface_mailbox = undefined,
            .renderer_state = &render_state,
            .renderer_mailbox = undefined,
            .renderer_wakeup = undefined,
            .enquiry_response = "",
            .osc_color_report_format = .@"16-bit",
            .clipboard_write = .deny,
            .clipboard_write_limit = 0,
            .xt_checksum_report = false,
        } });
        defer stream.deinit();

        stream.nextSlice(if (override_blink) "\x1b[6 q" else "\x1b[5 q");
        try expectCursor(&t, .bar, override_blink);
        try testing.expect(!t.cursor.is_default);
        // Save happens with the override active, not before policy init.
        // Restore and the first query share an input block.
        stream.nextSlice("\x1b[?12s\x1b[?12r\x1bP$q q\x1b\\");
        try expectStreamReply(&mailbox, if (override_blink) "\x1bP1$r5 q\x1b\\" else "\x1bP1$r6 q\x1b\\");

        stream.handler.changeConfig(&reloaded);
        const reload_message = mailbox.spsc.queue.pop(testing.io) orelse return error.MissingReloadMessage;
        defer reload_message.deinit();
        try testing.expect(reload_message == .color_scheme_report);
        // No new cursor request: the original program blink must reappear.
        stream.nextSlice("\x1bP$q q\x1b\\");
        try expectStreamReply(&mailbox, if (override_blink) "\x1bP1$r6 q\x1b\\" else "\x1bP1$r5 q\x1b\\");
        try expectCursor(&t, .bar, !override_blink);
        try testing.expect(!t.cursor.is_default);
    }
}

fn expectStreamReply(mailbox: anytype, expected: []const u8) !void {
    const testing = std.testing;
    const message = mailbox.spsc.queue.pop(testing.io) orelse return error.MissingCursorReply;
    defer message.deinit();
    switch (message) {
        .write_small => |v| try testing.expectEqualStrings(expected, v.data[0..v.len]),
        .write_alloc => |v| try testing.expectEqualStrings(expected, v.data),
        else => return error.UnexpectedCursorReply,
    }
    try testing.expect(mailbox.spsc.queue.pop(testing.io) == null);
}

/// Real app resize entry points with allocation failures inside existing
/// PageList node pools. No tripwire export or runtime test seam is needed.
pub fn testResize(comptime Io: type, comptime entry: enum { termio, mode_3, deccolm }) !void {
    const terminal = @import("../terminal/main.zig");
    const termio = @import("../termio.zig");
    const renderer = @import("../renderer.zig");
    const xev = @import("../global.zig").xev;
    const testing = std.testing;
    const Failure = enum { none, replacement, fallback, primary };
    // Mode 40 logs an error when primary resize fails. Its recovered alternate
    // paths are tested here; primary OOM is exercised through Termio and mode 3.
    const failures: []const Failure = if (entry == .mode_3)
        &.{ .none, .replacement, .fallback }
    else
        &.{ .none, .replacement, .fallback, .primary };
    for ([_]Style{ .underline, .bar }) |style| {
        for (failures) |failure| {
            var primary_nodes = testing.FailingAllocator.init(testing.allocator, .{});
            var alternate_nodes = testing.FailingAllocator.init(testing.allocator, .{});
            var replacement = testing.FailingAllocator.init(testing.allocator, .{});
            var app_io: Io = undefined;
            app_io.alloc = replacement.allocator();
            app_io.terminal = try terminal.Terminal.init(testing.io, testing.allocator, .{
                .cols = 10,
                .rows = 3,
                .default_cursor_style = style,
                .default_cursor_blink = true,
            });
            defer app_io.terminal.deinit(testing.allocator);
            const t = &app_io.terminal;
            _ = try t.switchScreen(.alternate);
            t.setCursorStyle(.steady_block);
            // Both screens use the allocation-atomic no-reflow resize path.
            // This makes primary node OOM a pre-commit error as well.
            t.modes.set(.wraparound, false);
            const generation = t.screens.generation(.alternate);
            // All wrappers delegate to the same leak-checking allocator. Only
            // future node allocations can fail; existing owned nodes still free
            // through that allocator, even after Terminal replaces their screen.
            const primary = t.screens.get(.primary).?;
            const alternate = t.screens.get(.alternate).?;
            try testing.expectEqual(@as(usize, 0), primary.pages.pool.nodes.free.items.len);
            try testing.expectEqual(@as(usize, 0), alternate.pages.pool.nodes.free.items.len);
            primary.pages.pool.nodes.allocator = primary_nodes.allocator();
            alternate.pages.pool.nodes.allocator = alternate_nodes.allocator();

            var mutex: std.Io.Mutex = .init;
            var render_state: renderer.State = .{ .mutex = &mutex, .terminal = t };
            var renderer_mailbox: renderer.Thread.Mailbox = .{};
            defer while (renderer_mailbox.pop(testing.io)) |msg| msg.deinit();
            var wakeup = try xev.Async.init();
            defer wakeup.deinit();
            app_io.renderer_state = &render_state;
            app_io.renderer_mailbox = &renderer_mailbox;
            app_io.renderer_wakeup = &wakeup;
            app_io.size = .{
                .screen = .{ .width = 132, .height = 3 },
                .cell = .{ .width = 1, .height = 1 },
                .padding = .{},
            };
            // Exec.resize explicitly supports the pre-start state (no PTY).
            // It only updates grid/screen sizes and reads this optional field.
            app_io.backend = .{ .exec = undefined };
            app_io.backend.exec.subprocess.pty = null;
            app_io.mailbox = try termio.Mailbox.initSPSC(testing.allocator);
            defer app_io.mailbox.deinit(testing.allocator);
            const Handler = @import("../termio/stream_handler.zig").StreamHandler;
            app_io.terminal_stream = Handler.Stream.init(.{ .allocator = testing.allocator, .handler = .{
                .alloc = app_io.alloc,
                .size = &app_io.size,
                .terminal = t,
                .gx_cursor_policy = State.init(t, .{ .style = style, .blink = true }),
                .termio_mailbox = &app_io.mailbox,
                .surface_mailbox = undefined,
                .renderer_state = &render_state,
                .renderer_mailbox = &renderer_mailbox,
                .renderer_wakeup = &wakeup,
                .enquiry_response = "",
                .osc_color_report_format = .@"16-bit",
                .clipboard_write = .deny,
                .clipboard_write_limit = 0,
                .xt_checksum_report = false,
            } });
            defer app_io.terminal_stream.deinit();
            // DECCOLM needs mode 40 enabled, without triggering a preparatory
            // resize that would consume the fault before the tested request.
            if (entry == .deccolm) t.modes.set(.enable_mode_3, true);
            switch (failure) {
                .none => {},
                .replacement => alternate_nodes.fail_index = 0,
                .fallback => {
                    alternate_nodes.fail_index = 0;
                    replacement.fail_index = 0;
                },
                .primary => primary_nodes.fail_index = 0,
            }

            if (entry == .termio) {
                // The real Termio entry takes the shared mutex itself.
                var td: Io.ThreadData = undefined;
                if (failure == .primary) {
                    try testing.expectError(error.OutOfMemory, app_io.resize(&td, app_io.size));
                } else try app_io.resize(&td, app_io.size);
            }
            mutex.lockUncancelable(testing.io);
            defer mutex.unlock(testing.io);
            switch (entry) {
                .termio => app_io.terminal_stream.nextSlice("\x1bP$q q\x1b\\"),
                // Each handler request and its DECRQSS are in one input block.
                .mode_3 => app_io.terminal_stream.nextSlice("\x1b[?40l\x1bP$q q\x1b\\"),
                .deccolm => app_io.terminal_stream.nextSlice("\x1b[?3h\x1bP$q q\x1b\\"),
            }
            // Prove the real failure/replacement branch was reached before
            // checking appearance. No fabricated screen/generation substitutes.
            try testing.expectEqual(failure == .primary, primary_nodes.has_induced_failure);
            try testing.expectEqual(failure == .replacement or failure == .fallback, alternate_nodes.has_induced_failure);
            try testing.expectEqual(failure == .fallback, replacement.has_induced_failure);
            try testing.expectEqual(@as(terminal.size.CellCountInt, if (failure == .primary) 10 else 132), t.cols);
            try testing.expectEqual(generation +% @as(usize, if (failure == .replacement or failure == .fallback) 1 else 0), t.screens.generation(.alternate));
            try testing.expectEqual(if (failure == .fallback) terminal.ScreenSet.Key.primary else terminal.ScreenSet.Key.alternate, t.screens.active_key);
            if (failure == .fallback) try testing.expect(t.screens.get(.alternate) == null);
            if (failure == .replacement) {
                const fresh = t.screens.get(.alternate).?;
                try testing.expectEqual(@as(terminal.size.CellCountInt, 132), fresh.pages.cols);
                try testing.expect(fresh.pages.getCell(.{ .active = .{} }).?.cell.isEmpty());
            }
            try expectStreamReply(&app_io.mailbox, if (style == .underline) "\x1bP1$r3 q\x1b\\" else "\x1bP1$r5 q\x1b\\");
            try expectCursor(t, style, true);
            try testing.expect(!t.cursor.is_default);
            // Releasing the override must not revive a dead generation's
            // shadow or leave its effective shape saved as program state.
            app_io.terminal_stream.handler.gx_cursor_policy.changeConfig(t, .block, true, .{});
            try expectCursor(t, if (failure == .fallback) style else .block, false);
        }
    }
}
