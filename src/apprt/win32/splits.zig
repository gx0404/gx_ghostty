//! Split rules of the win32 apprt that need no window. Geometry along one
//! axis of a split: where its divider goes (`dividerPos`), the ratio that
//! puts the divider under the pointer (`ratioAt`, its inverse) and the
//! spans of its children (`childSpans`). Focus: which pane takes the focus
//! when one closes (`focusAfterClose`) and where the zoom of a zoomed tree
//! goes when the focus moves (`zoomAfterFocus`). `Window` lays the panes
//! out with them; the trees are `datastruct/split_tree.zig` trees.
const std = @import("std");

/// One axis of a rectangle in pixels: [start, end).
pub const Span = struct { start: i32, end: i32 };

/// The divider position of a split over `extent` pixels from `start` whose
/// first child takes `ratio` of it.
pub fn dividerPos(start: i32, extent: i32, ratio: f32) i32 {
    const total: f32 = @floatFromInt(@max(extent, 0));
    return start + @as(i32, @intFromFloat(std.math.clamp(ratio, 0, 1) * total));
}

/// The ratio of a split over `extent` pixels from `start` that puts its
/// divider at `pos` (`dividerPos` gives `pos` back), keeping it at least
/// `min_size` pixels from both ends (from the middle, when the extent is
/// less than twice that).
pub fn ratioAt(start: i32, extent: i32, pos: i32, min_size: i32) f32 {
    if (extent <= 0) return 0.5;
    const margin = std.math.clamp(min_size, 0, @divTrunc(extent - 1, 2));
    const offset = std.math.clamp(pos -| start, margin, extent - 1 - margin);
    // The middle of the pixel, so that storing the ratio as an f16 in the
    // split tree still lands the divider on it.
    return (@as(f32, @floatFromInt(offset)) + 0.5) / @as(f32, @floatFromInt(extent));
}

/// The spans of the two children of a split over [start, end) with its
/// divider at `divider` and `gap` pixels between them.
pub fn childSpans(start: i32, end: i32, divider: i32, gap: i32) [2]Span {
    return .{
        .{ .start = start, .end = divider - @divTrunc(gap, 2) },
        .{ .start = divider + @divTrunc(gap + 1, 2), .end = end },
    };
}

/// The leaf of `tree` that takes the focus when the leaf `closed` closes:
/// the leaf before it in the tree's order (in-order traversal), or the one
/// after it when it is the first, as in the GTK and macOS apps. Null when
/// `closed` is the whole tree.
pub fn focusAfterClose(
    comptime Tree: type,
    alloc: std.mem.Allocator,
    tree: *const Tree,
    closed: Tree.Node.Handle,
) ?Tree.Node.Handle {
    // Only spatial navigation allocates.
    const next = (tree.goto(alloc, closed, .previous) catch null) orelse
        (tree.goto(alloc, closed, .next) catch null) orelse
        return null;
    return if (next == closed) null else next;
}

/// The zoomed node of a tree zoomed on `zoomed` (if any) once the pane
/// `focus` has the focus: the zoom follows the focus with
/// `split-preserve-zoom = navigation` (`preserve`), else the tree unzooms,
/// so a focused pane is never hidden.
pub fn zoomAfterFocus(comptime Handle: type, zoomed: ?Handle, focus: Handle, preserve: bool) ?Handle {
    const current = zoomed orelse return null;
    if (current == focus or preserve) return focus;
    return null;
}

test "ratioAt is the inverse of dividerPos" {
    const testing = std.testing;
    for ([_]i32{ 1, 2, 3, 7, 100, 497, 1000, 1024, 2047 }) |extent| {
        const start: i32 = 503;
        var pos = start;
        while (pos < start + extent) : (pos += 1) {
            const ratio = ratioAt(start, extent, pos, 0);
            try testing.expect(ratio > 0 and ratio < 1);
            try testing.expectEqual(pos, dividerPos(start, extent, ratio));
            // The split tree keeps the ratio as an f16.
            const stored: f16 = @floatCast(ratio);
            try testing.expectEqual(pos, dividerPos(start, extent, stored));
        }
    }
}

test "ratioAt keeps the minimum size on both sides" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 40), dividerPos(0, 1000, ratioAt(0, 1000, 5, 40)));
    try testing.expectEqual(@as(i32, 959), dividerPos(0, 1000, ratioAt(0, 1000, 2000, 40)));
    try testing.expectEqual(@as(i32, 100), dividerPos(100, 1000, ratioAt(100, 1000, -50, 0)));
    // Too small for the minimum on both sides: the middle.
    try testing.expectEqual(@as(i32, 24), dividerPos(0, 50, ratioAt(0, 50, 0, 40)));
    try testing.expectEqual(@as(i32, 25), dividerPos(0, 50, ratioAt(0, 50, 49, 40)));
    try testing.expectEqual(@as(f32, 0.5), ratioAt(0, 0, 10, 40));
}

test "dragging a nested divider follows the pointer" {
    const testing = std.testing;
    // A | (B | C) over 1000 px with a 5 px gap: the nested split covers
    // the right child of the root.
    const gap = 5;
    const root_divider = dividerPos(0, 1000, 0.5);
    const right = childSpans(0, 1000, root_divider, gap)[1];
    try testing.expectEqual(Span{ .start = 503, .end = 1000 }, right);
    // The pointer at 750 (75% of the window) puts the nested divider at
    // 750, not at 75% of the nested split (875).
    const ratio: f16 = @floatCast(ratioAt(right.start, right.end - right.start, 750, 0));
    try testing.expectEqual(@as(i32, 750), dividerPos(right.start, right.end - right.start, ratio));
}

test "childSpans leave the gap between the children" {
    const testing = std.testing;
    const odd = childSpans(0, 1000, 500, 5);
    try testing.expectEqual(Span{ .start = 0, .end = 498 }, odd[0]);
    try testing.expectEqual(Span{ .start = 503, .end = 1000 }, odd[1]);
    const even = childSpans(10, 110, 60, 4);
    try testing.expectEqual(Span{ .start = 10, .end = 58 }, even[0]);
    try testing.expectEqual(Span{ .start = 62, .end = 110 }, even[1]);
    const none = childSpans(0, 100, 30, 0);
    try testing.expectEqual(none[0].end, none[1].start);
}

const TestView = struct {
    label: u8,

    pub fn ref(self: *TestView, _: std.mem.Allocator) std.mem.Allocator.Error!*TestView {
        return self;
    }

    pub fn unref(_: *TestView, _: std.mem.Allocator) void {}

    pub fn eql(a: *const TestView, b: *const TestView) bool {
        return a == b;
    }
};

test "focusAfterClose picks the previous leaf, else the next" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Tree = @import("../../datastruct/split_tree.zig").SplitTree(TestView);

    var a: TestView = .{ .label = 'A' };
    var b: TestView = .{ .label = 'B' };
    var c: TestView = .{ .label = 'C' };
    var ta: Tree = try .init(alloc, &a);
    defer ta.deinit();
    var tb: Tree = try .init(alloc, &b);
    defer tb.deinit();
    var tc: Tree = try .init(alloc, &c);
    defer tc.deinit();

    // A | (B | C)
    var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer ab.deinit();
    var a_bc = try ab.split(alloc, ab.locate(&b).?, .right, 0.5, &tc);
    defer a_bc.deinit();
    const Expect = struct {
        fn focus(tree: *const Tree, closed: *TestView, want: *TestView) !void {
            const handle = focusAfterClose(Tree, testing.allocator, tree, tree.locate(closed).?).?;
            try testing.expectEqual(want, tree.nodes[handle.idx()].leaf);
        }
    };
    try Expect.focus(&a_bc, &b, &a);
    try Expect.focus(&a_bc, &a, &b);
    try Expect.focus(&a_bc, &c, &b);

    // (A | B) / C: C below, A and B above it.
    var ab_c = try ab.split(alloc, .root, .down, 0.5, &tc);
    defer ab_c.deinit();
    try Expect.focus(&ab_c, &c, &b);
    try Expect.focus(&ab_c, &a, &b);
    try Expect.focus(&ab_c, &b, &a);

    // The leaf stays in the tree without the closed one.
    var removed = try a_bc.remove(alloc, a_bc.locate(&b).?);
    defer removed.deinit();
    try testing.expect(removed.locate(&a) != null);

    try testing.expectEqual(@as(?Tree.Node.Handle, null), focusAfterClose(Tree, alloc, &ta, .root));
}

test "zoomAfterFocus" {
    const testing = std.testing;
    const H = enum(u16) { root = 0, _ };
    const a: H = @enumFromInt(1);
    const b: H = @enumFromInt(2);
    try testing.expectEqual(@as(?H, null), zoomAfterFocus(H, null, a, true));
    try testing.expectEqual(@as(?H, a), zoomAfterFocus(H, a, a, false));
    try testing.expectEqual(@as(?H, null), zoomAfterFocus(H, a, b, false));
    try testing.expectEqual(@as(?H, b), zoomAfterFocus(H, a, b, true));
}
