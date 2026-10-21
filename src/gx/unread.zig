//! New output in tabs that are not shown, for Ghostty GX's unread marks
//! (the dot on a win32 tab, `needs-attention` on a GTK tab page).
//!
//! The renderer clears a terminal's dirty flags when it draws and does not
//! draw hidden terminals, so the flags tell whether a hidden terminal
//! changed since its last frame. A terminal can be hidden with changes
//! that were never drawn, though (a prompt redrawn as its tab was switched
//! away from), and the flags alone would then mark an idle tab at once. So
//! a `Tracker` takes a `Baseline` of a terminal when its tab is hidden,
//! and the terminal counts as changed only while it is dirty and its
//! content moved on from that baseline: the scrollback grew or turned
//! over, the active screen switched, or the cursor or the cursor's row
//! changed. A program that rewrites other rows in place and puts the
//! cursor back (a full-screen program redrawing a clock) does not count.
//!
//! The periodic checks run on the UI thread and never wait for the
//! terminal lock: a terminal whose lock is taken is skipped, and one that
//! stays busy for `busy_checks` checks in a row is processing output.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const RendererState = @import("../renderer/State.zig");

/// A summary of a terminal's content that output changes.
pub const Baseline = struct {
    screen: terminal.ScreenSet.Key,
    total_rows: usize,
    page_serial: u64,
    cursor_x: terminal.size.CellCountInt,
    cursor_y: terminal.size.CellCountInt,
    cursor_row_hash: u64,
};

/// How many checks in a row must find a terminal's lock taken before it
/// counts as changed.
pub const busy_checks = 3;

/// The unread state of one terminal. Call `hide` when its tab stops being
/// shown, `check` periodically while it is hidden, and `show` when the
/// tab is shown again.
pub const Tracker = struct {
    /// The content when the tab was hidden, if known.
    baseline: ?Baseline = null,

    /// Checks in a row that found the terminal's lock taken.
    busy: u8 = 0,

    /// The tab of the terminal of `state` was hidden: remember its
    /// content. Waits for the terminal lock like the renderer does.
    pub fn hide(self: *Tracker, state: *RendererState, io: std.Io) void {
        state.lockDemand(io);
        defer state.unlockDemand(io);
        self.* = .{ .baseline = baseline(state.terminal) };
    }

    /// The tab was shown: its terminal is drawn again.
    pub fn show(self: *Tracker) void {
        self.* = .{};
    }

    /// Whether the hidden terminal of `state` has new output (`changed`
    /// since `hide`). Does not wait for the terminal lock.
    pub fn check(self: *Tracker, state: *RendererState, io: std.Io) bool {
        if (!state.mutex.tryLock()) {
            self.busy +|= 1;
            return self.busy >= busy_checks;
        }
        defer state.mutex.unlock(io);
        self.busy = 0;
        return changed(state.terminal, self.baseline);
    }
};

/// The baseline of terminal `t`; the caller holds the terminal lock.
pub fn baseline(t: *const terminal.Terminal) Baseline {
    const screen = t.screens.active;
    return .{
        .screen = t.screens.active_key,
        .total_rows = screen.pages.total_rows,
        .page_serial = screen.pages.page_serial,
        .cursor_x = screen.cursor.x,
        .cursor_y = screen.cursor.y,
        .cursor_row_hash = cursorRowHash(screen),
    };
}

/// Whether terminal `t` changed since its renderer last drew it and, with
/// a baseline, since the baseline was taken (see the module
/// documentation). The caller holds the terminal lock.
pub fn changed(t: *const terminal.Terminal, since: ?Baseline) bool {
    if (!dirty(t)) return false;
    const before = since orelse return true;
    return !std.meta.eql(baseline(t), before);
}

/// Whether the renderer has anything to redraw in terminal `t`: its dirty
/// flags, or a dirty page or row in the viewport.
fn dirty(t: *const terminal.Terminal) bool {
    if (anyFlag(t.flags.dirty)) return true;
    const screen = t.screens.active;
    if (anyFlag(screen.dirty)) return true;
    var it = screen.pages.pageIterator(.right_down, .{ .viewport = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.pageIfResident() orelse continue;
        if (page.dirty) return true;
        for (page.rows.ptr(page.memory)[chunk.start..chunk.end]) |row| {
            if (row.dirty) return true;
        }
    }
    return false;
}

fn anyFlag(flags: anytype) bool {
    const Int = @Int(.unsigned, @bitSizeOf(@TypeOf(flags)));
    return @as(Int, @bitCast(flags)) != 0;
}

fn cursorRowHash(screen: *const terminal.Screen) u64 {
    const pin = screen.cursor.page_pin;
    const page = pin.node.pageIfResident() orelse return 0;
    const cells = page.getCells(page.getRow(pin.y));
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(cells));
}

/// Marks terminal `t` as drawn, like the renderer does.
fn testDraw(t: *terminal.Terminal) void {
    t.flags.dirty = .{};
    t.screens.active.dirty = .{};
    t.screens.active.pages.clearDirty();
}

test "changed needs something to redraw" {
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("$ ");
    try testing.expect(changed(&t, null));
    testDraw(&t);
    try testing.expect(!changed(&t, null));
    try t.printString("ls");
    try testing.expect(changed(&t, null));
}

test "a baseline ignores changes drawn or not before it" {
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);

    // The prompt was redrawn as the tab was hidden, before a frame.
    try t.printString("$ ");
    const before = baseline(&t);
    try testing.expect(changed(&t, null));
    try testing.expect(!changed(&t, before));

    // New output on the cursor's row.
    try t.printString("make");
    try testing.expect(changed(&t, before));
}

test "a baseline sees scrolling, rewritten lines and screen switches" {
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 3 });
    defer t.deinit(testing.allocator);

    try t.printString("a\nb\nc");
    testDraw(&t);
    var before = baseline(&t);
    try t.printString("\nd");
    try testing.expect(changed(&t, before));

    // A progress line rewritten in place, the cursor back where it was.
    try t.printString("\n10%");
    testDraw(&t);
    before = baseline(&t);
    t.carriageReturn();
    try t.printString("20%");
    try testing.expect(changed(&t, before));

    // A full-screen program redraws a row elsewhere and puts the cursor
    // back: not new output.
    testDraw(&t);
    before = baseline(&t);
    const x = t.screens.active.cursor.x;
    const y = t.screens.active.cursor.y;
    t.setCursorPos(1, 1);
    try t.printString("Q");
    t.setCursorPos(y + 1, x + 1);
    try testing.expect(!changed(&t, before));

    // A full-screen program starts.
    testDraw(&t);
    before = baseline(&t);
    _ = try t.switchScreen(.alternate);
    try testing.expect(changed(&t, before));
}

test "Tracker counts a terminal busy for several checks as changed" {
    const testing = std.testing;
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    var mutex: std.Io.Mutex = .init;
    var state: RendererState = .{ .mutex = &mutex, .terminal = &t };

    try t.printString("$ ");
    var tracker: Tracker = .{};
    tracker.hide(&state, testing.io);
    try testing.expect(tracker.baseline != null);
    try testing.expect(!tracker.check(&state, testing.io));

    try testing.expect(mutex.tryLock());
    for (1..busy_checks) |_| try testing.expect(!tracker.check(&state, testing.io));
    try testing.expect(tracker.check(&state, testing.io));
    mutex.unlock(testing.io);
    try testing.expect(!tracker.check(&state, testing.io));

    try t.printString("echo hi\n");
    try testing.expect(tracker.check(&state, testing.io));

    tracker.show();
    try testing.expect(tracker.baseline == null);
    try testing.expectEqual(@as(u8, 0), tracker.busy);
}
