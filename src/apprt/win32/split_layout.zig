//! Geometry of the split panes of a win32 window that needs no window:
//! where the panes of a split tree go in the terminal area and where its
//! dividers are (`walk`, `paneRect`), the divider a point is on
//! (`hitTest`), the part of the area each divider owns (`Divider.band`,
//! the gap between its two sides, which the window paints) and the line
//! drawn in it (`Divider.line`), and the rectangle a new split takes
//! (`insertRect`). `Window` lays the panes out, paints the gaps and
//! hit-tests the dividers with the same walk, so the three always agree.
//! The trees are `datastruct/split_tree.zig` trees; the arithmetic along
//! one axis comes from `splits.zig`.
const std = @import("std");
const splits = @import("splits.zig");

/// A rectangle in pixels, laid out like the Win32 `RECT`.
pub const Rect = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

/// The sizes of the split chrome at a content scale, in pixels.
pub const Metrics = struct {
    /// Between two panes.
    gap: i32,
    /// The divider line in the middle of the gap.
    line: i32,
    /// The divider line while it is hovered or dragged.
    line_active: i32,

    /// The sizes above in DIPs.
    pub const gap_dip: f32 = 5;
    pub const line_dip: f32 = 1;
    pub const line_active_dip: f32 = 3;

    pub fn forScale(scale: f32) Metrics {
        const gap = px(gap_dip, scale);
        const line = @max(px(line_dip, scale), 1);
        return .{
            .gap = gap,
            .line = line,
            .line_active = std.math.clamp(px(line_active_dip, scale), line + 1, @max(gap, line + 1)),
        };
    }

    fn px(dip: f32, scale: f32) i32 {
        return @intFromFloat(@round(dip * scale));
    }
};

/// A split of a tree laid out over its rectangle.
pub fn Divider(comptime Tree: type) type {
    return struct {
        const Self = @This();

        /// The split node.
        handle: Tree.Node.Handle,
        layout: Tree.Split.Layout,
        /// The rectangle of the split node.
        rect: Rect,
        /// Where its divider line is centered: x for a horizontal split, y
        /// for a vertical one.
        pos: i32,
        /// The part of `rect` between its two sides (the gap).
        band: Rect,

        /// The divider line, `thickness` pixels wide across the split and
        /// as long as the split.
        pub fn line(self: Self, thickness: i32) Rect {
            const start = self.pos - @divTrunc(thickness, 2);
            return switch (self.layout) {
                .horizontal => .{ .left = start, .top = self.rect.top, .right = start + thickness, .bottom = self.rect.bottom },
                .vertical => .{ .left = self.rect.left, .top = start, .right = self.rect.right, .bottom = start + thickness },
            };
        }

        /// Whether (x, y) is on the divider: in its band, or within
        /// `reach` pixels of its line along the split.
        pub fn hit(self: Self, x: i32, y: i32, reach: i32) bool {
            if (self.band.contains(x, y)) return true;
            // Along the split, across it, and the extent across it.
            const v: [4]i32 = switch (self.layout) {
                .horizontal => .{ x, y, self.rect.top, self.rect.bottom },
                .vertical => .{ y, x, self.rect.left, self.rect.right },
            };
            return v[1] >= v[2] and v[1] < v[3] and v[0] >= self.pos - reach and v[0] <= self.pos + reach;
        }
    };
}

/// A split laid out over its rectangle: where its divider is (x of a
/// horizontal split, y of a vertical one), the rectangles of its two sides
/// and the gap between them.
pub const Parts = struct {
    divider: i32,
    first: Rect,
    second: Rect,
    band: Rect,
};

/// The `Parts` of a split over `rect` (side by side when `horizontal`, else
/// one above the other) whose first side takes `ratio` of it, with `gap`
/// pixels between the sides.
pub fn splitRect(rect: Rect, horizontal: bool, ratio: f32, gap: i32) Parts {
    if (horizontal) {
        const divider = splits.dividerPos(rect.left, rect.width(), ratio);
        const spans = splits.childSpans(rect.left, rect.right, divider, gap);
        return .{
            .divider = divider,
            .first = .{ .left = spans[0].start, .top = rect.top, .right = spans[0].end, .bottom = rect.bottom },
            .second = .{ .left = spans[1].start, .top = rect.top, .right = spans[1].end, .bottom = rect.bottom },
            .band = .{ .left = spans[0].end, .top = rect.top, .right = spans[1].start, .bottom = rect.bottom },
        };
    }
    const divider = splits.dividerPos(rect.top, rect.height(), ratio);
    const spans = splits.childSpans(rect.top, rect.bottom, divider, gap);
    return .{
        .divider = divider,
        .first = .{ .left = rect.left, .top = spans[0].start, .right = rect.right, .bottom = spans[0].end },
        .second = .{ .left = rect.left, .top = spans[1].start, .right = rect.right, .bottom = spans[1].end },
        .band = .{ .left = rect.left, .top = spans[0].end, .right = rect.right, .bottom = spans[1].start },
    };
}

/// Visit the panes and dividers of `tree` laid out over `area` with `gap`
/// pixels between panes: `visitor.pane(handle, view, rect)` for every pane
/// shown and `visitor.divider(divider)` for every split shown, before the
/// panes and splits inside it. Either method may be left out. A zoomed tree
/// shows only its zoomed node, over the whole area.
pub fn walk(comptime Tree: type, tree: *const Tree, area: Rect, gap: i32, visitor: anytype) void {
    if (tree.nodes.len == 0) return;
    walkNode(Tree, tree, tree.zoomed orelse .root, area, gap, visitor);
}

fn walkNode(comptime Tree: type, tree: *const Tree, handle: Tree.Node.Handle, rect: Rect, gap: i32, visitor: anytype) void {
    const Visitor = @TypeOf(visitor.*);
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| if (comptime @hasDecl(Visitor, "pane")) visitor.pane(handle, view, rect),
        .split => |s| {
            const parts = splitRect(rect, s.layout == .horizontal, @floatCast(s.ratio), gap);
            if (comptime @hasDecl(Visitor, "divider")) visitor.divider(Divider(Tree){
                .handle = handle,
                .layout = s.layout,
                .rect = rect,
                .pos = parts.divider,
                .band = parts.band,
            });
            walkNode(Tree, tree, s.left, parts.first, gap, visitor);
            walkNode(Tree, tree, s.right, parts.second, gap, visitor);
        },
    }
}

/// Where the pane `handle` of `tree` is, laid out over `area` (`walk`);
/// null when it is not shown (another split is zoomed).
pub fn paneRect(comptime Tree: type, tree: *const Tree, area: Rect, gap: i32, handle: Tree.Node.Handle) ?Rect {
    const Finder = struct {
        want: Tree.Node.Handle,
        found: ?Rect = null,

        pub fn pane(self: *@This(), h: Tree.Node.Handle, _: *Tree.View, rect: Rect) void {
            if (h == self.want) self.found = rect;
        }
    };
    var finder: Finder = .{ .want = handle };
    walk(Tree, tree, area, gap, &finder);
    return finder.found;
}

/// The divider of `tree` (laid out over `area`) that (x, y) is on, the
/// outermost one first (`Divider.hit`); null when there is none.
pub fn hitTest(comptime Tree: type, tree: *const Tree, area: Rect, gap: i32, reach: i32, x: i32, y: i32) ?Divider(Tree) {
    const Hit = struct {
        x: i32,
        y: i32,
        reach: i32,
        found: ?Divider(Tree) = null,

        pub fn divider(self: *@This(), d: Divider(Tree)) void {
            if (self.found == null and d.hit(self.x, self.y, self.reach)) self.found = d;
        }
    };
    var finder: Hit = .{ .x = x, .y = y, .reach = reach };
    walk(Tree, tree, area, gap, &finder);
    return finder.found;
}

/// The divider of the split `handle` of `tree` laid out over `area`, if
/// it is shown.
pub fn findDivider(comptime Tree: type, tree: *const Tree, area: Rect, gap: i32, handle: Tree.Node.Handle) ?Divider(Tree) {
    const Finder = struct {
        want: Tree.Node.Handle,
        found: ?Divider(Tree) = null,

        pub fn divider(self: *@This(), d: Divider(Tree)) void {
            if (d.handle == self.want) self.found = d;
        }
    };
    var finder: Finder = .{ .want = handle };
    walk(Tree, tree, area, gap, &finder);
    return finder.found;
}

/// Where a view inserted next to a pane at `rect` in `direction` goes
/// (`SplitTree.split` with a ratio of one half): the right or lower half
/// for `.right` and `.down`, the other half for `.left` and `.up`.
pub fn insertRect(comptime Direction: type, rect: Rect, direction: Direction, gap: i32) Rect {
    const horizontal = switch (direction) {
        .left, .right => true,
        .up, .down => false,
    };
    const parts = splitRect(rect, horizontal, 0.5, gap);
    return switch (direction) {
        .left, .up => parts.first,
        .right, .down => parts.second,
    };
}

/// Whether a pane is dimmed as an unfocused split: its tab shows several
/// panes (it is split and not zoomed) and the pane is not the tab's
/// focused one.
pub fn dimsPane(split: bool, zoomed: bool, focused: bool) bool {
    return split and !zoomed and !focused;
}

/// The ratio that gives each pane on both sides of the split `handle` of
/// `tree` the same share of it: the number of panes side by side on each
/// side along the split, as `SplitTree.equalize` weighs them.
pub fn balancedRatio(comptime Tree: type, tree: *const Tree, handle: Tree.Node.Handle) f16 {
    if (handle.idx() >= tree.nodes.len) return 0.5;
    const s = switch (tree.nodes[handle.idx()]) {
        .leaf => return 0.5,
        .split => |s| s,
    };
    const left: f32 = @floatFromInt(weight(Tree, tree, s.left, s.layout));
    const right: f32 = @floatFromInt(weight(Tree, tree, s.right, s.layout));
    return @floatCast(left / (left + right));
}

fn weight(comptime Tree: type, tree: *const Tree, handle: Tree.Node.Handle, layout: Tree.Split.Layout) u32 {
    if (handle.idx() >= tree.nodes.len) return 1;
    return switch (tree.nodes[handle.idx()]) {
        .leaf => 1,
        .split => |s| if (s.layout == layout)
            weight(Tree, tree, s.left, layout) + weight(Tree, tree, s.right, layout)
        else
            1,
    };
}

const testing = std.testing;

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

const TestTree = @import("../../datastruct/split_tree.zig").SplitTree(TestView);

/// Records what `walk` visits.
const Recorder = struct {
    panes: [8]struct { label: u8, rect: Rect } = undefined,
    pane_count: usize = 0,
    dividers: [8]Divider(TestTree) = undefined,
    divider_count: usize = 0,

    pub fn pane(self: *Recorder, _: TestTree.Node.Handle, view: *TestView, rect: Rect) void {
        self.panes[self.pane_count] = .{ .label = view.label, .rect = rect };
        self.pane_count += 1;
    }

    pub fn divider(self: *Recorder, d: Divider(TestTree)) void {
        self.dividers[self.divider_count] = d;
        self.divider_count += 1;
    }

    fn rectOf(self: *const Recorder, label: u8) ?Rect {
        for (self.panes[0..self.pane_count]) |p| if (p.label == label) return p.rect;
        return null;
    }
};

test "walk lays out nested splits with gaps between the panes" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = 'A' };
    var b: TestView = .{ .label = 'B' };
    var c: TestView = .{ .label = 'C' };
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &b);
    defer tb.deinit();
    var tc: TestTree = try .init(alloc, &c);
    defer tc.deinit();

    // A | (B / C) over 1000 x 600 below a 40 px chrome row.
    var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer ab.deinit();
    var tree = try ab.split(alloc, ab.locate(&b).?, .down, 0.5, &tc);
    defer tree.deinit();

    const area: Rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 640 };
    var rec: Recorder = .{};
    walk(TestTree, &tree, area, 5, &rec);
    try testing.expectEqual(@as(usize, 3), rec.pane_count);
    try testing.expectEqual(@as(usize, 2), rec.divider_count);
    try testing.expectEqual(Rect{ .left = 0, .top = 40, .right = 498, .bottom = 640 }, rec.rectOf('A').?);
    try testing.expectEqual(Rect{ .left = 503, .top = 40, .right = 1000, .bottom = 338 }, rec.rectOf('B').?);
    try testing.expectEqual(Rect{ .left = 503, .top = 343, .right = 1000, .bottom = 640 }, rec.rectOf('C').?);

    // The outer divider comes first; each band is the gap between its sides.
    const outer = rec.dividers[0];
    try testing.expectEqual(TestTree.Node.Handle.root, outer.handle);
    try testing.expectEqual(@as(i32, 500), outer.pos);
    try testing.expectEqual(Rect{ .left = 498, .top = 40, .right = 503, .bottom = 640 }, outer.band);
    const inner = rec.dividers[1];
    try testing.expectEqual(Rect{ .left = 503, .top = 338, .right = 1000, .bottom = 343 }, inner.band);
    try testing.expectEqual(Rect{ .left = 503, .top = 40, .right = 1000, .bottom = 640 }, inner.rect);

    // The panes and the bands tile the area.
    var covered: i64 = 0;
    for (rec.panes[0..rec.pane_count]) |p| covered += @as(i64, p.rect.width()) * p.rect.height();
    for (rec.dividers[0..rec.divider_count]) |d| covered += @as(i64, d.band.width()) * d.band.height();
    try testing.expectEqual(@as(i64, area.width()) * area.height(), covered);
}

test "a zoomed tree shows only the zoomed pane" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = 'A' };
    var b: TestView = .{ .label = 'B' };
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &b);
    defer tb.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer tree.deinit();
    tree.zoom(tree.locate(&b));

    const area: Rect = .{ .right = 800, .bottom = 600 };
    var rec: Recorder = .{};
    walk(TestTree, &tree, area, 5, &rec);
    try testing.expectEqual(@as(usize, 1), rec.pane_count);
    try testing.expectEqual(@as(usize, 0), rec.divider_count);
    try testing.expectEqual(area, rec.rectOf('B').?);
    try testing.expectEqual(@as(?Rect, null), paneRect(TestTree, &tree, area, 5, tree.locate(&a).?));
    try testing.expectEqual(@as(?Divider(TestTree), null), hitTest(TestTree, &tree, area, 5, 3, 400, 300));
}

test "a single pane fills the area and has no divider" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = 'A' };
    var tree: TestTree = try .init(alloc, &a);
    defer tree.deinit();
    const area: Rect = .{ .top = 40, .right = 800, .bottom = 600 };
    try testing.expectEqual(area, paneRect(TestTree, &tree, area, 5, .root).?);
    var rec: Recorder = .{};
    walk(TestTree, &tree, area, 5, &rec);
    try testing.expectEqual(@as(usize, 0), rec.divider_count);
    walk(TestTree, &TestTree.empty, area, 5, &rec);
    try testing.expectEqual(@as(usize, 1), rec.pane_count);
}

test "hitTest finds the divider under the pointer" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = 'A' };
    var b: TestView = .{ .label = 'B' };
    var c: TestView = .{ .label = 'C' };
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &b);
    defer tb.deinit();
    var tc: TestTree = try .init(alloc, &c);
    defer tc.deinit();
    var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer ab.deinit();
    var tree = try ab.split(alloc, ab.locate(&b).?, .down, 0.5, &tc);
    defer tree.deinit();
    const area: Rect = .{ .right = 1000, .bottom = 600 };

    // Anywhere in the gap, and within reach of the line.
    for ([_]i32{ 497, 498, 500, 502, 503 }) |x| {
        const hit = hitTest(TestTree, &tree, area, 5, 3, x, 100).?;
        try testing.expectEqual(TestTree.Node.Handle.root, hit.handle);
        try testing.expectEqual(TestTree.Split.Layout.horizontal, hit.layout);
    }
    try testing.expectEqual(@as(?Divider(TestTree), null), hitTest(TestTree, &tree, area, 5, 3, 496, 100));
    try testing.expectEqual(@as(?Divider(TestTree), null), hitTest(TestTree, &tree, area, 5, 3, 504, 100));

    // The nested divider spans only its own split.
    const nested = hitTest(TestTree, &tree, area, 5, 3, 700, 300).?;
    try testing.expectEqual(TestTree.Split.Layout.vertical, nested.layout);
    try testing.expectEqual(@as(i32, 503), nested.rect.left);
    try testing.expectEqual(@as(i32, 300), nested.pos);
    try testing.expectEqual(@as(?Divider(TestTree), null), hitTest(TestTree, &tree, area, 5, 3, 200, 300));
    try testing.expectEqual(@as(?Divider(TestTree), null), hitTest(TestTree, &tree, area, 5, 3, 700, 200));
    // Where both meet, the outer divider wins.
    try testing.expectEqual(TestTree.Node.Handle.root, hitTest(TestTree, &tree, area, 5, 3, 503, 300).?.handle);

    const found = findDivider(TestTree, &tree, area, 5, nested.handle).?;
    try testing.expectEqual(nested.band, found.band);
}

test "the divider line is centered on the divider" {
    const D = Divider(TestTree);
    const d: D = .{
        .handle = .root,
        .layout = .horizontal,
        .rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 640 },
        .pos = 500,
        .band = .{ .left = 498, .top = 40, .right = 503, .bottom = 640 },
    };
    try testing.expectEqual(Rect{ .left = 500, .top = 40, .right = 501, .bottom = 640 }, d.line(1));
    try testing.expectEqual(Rect{ .left = 499, .top = 40, .right = 502, .bottom = 640 }, d.line(3));
    var v = d;
    v.layout = .vertical;
    v.pos = 300;
    try testing.expectEqual(Rect{ .left = 0, .top = 299, .right = 1000, .bottom = 301 }, v.line(2));
}

test "Metrics grow with the scale and keep the active line inside the gap" {
    const m100 = Metrics.forScale(1);
    try testing.expectEqual(Metrics{ .gap = 5, .line = 1, .line_active = 3 }, m100);
    const m150 = Metrics.forScale(1.5);
    try testing.expectEqual(@as(i32, 8), m150.gap);
    try testing.expectEqual(@as(i32, 2), m150.line);
    try testing.expect(m150.line_active > m150.line and m150.line_active <= m150.gap);
    for ([_]f32{ 0.5, 1, 1.25, 1.5, 1.75, 2, 3 }) |scale| {
        const m = Metrics.forScale(scale);
        try testing.expect(m.line >= 1);
        try testing.expect(m.line_active > m.line);
        try testing.expect(m.line_active <= @max(m.gap, m.line + 1));
    }
}

test "insertRect takes the half on the side of the new split" {
    const Direction = enum { left, right, up, down };
    const rect: Rect = .{ .left = 100, .top = 40, .right = 1100, .bottom = 640 };
    try testing.expectEqual(Rect{ .left = 603, .top = 40, .right = 1100, .bottom = 640 }, insertRect(Direction, rect, .right, 5));
    try testing.expectEqual(Rect{ .left = 100, .top = 40, .right = 598, .bottom = 640 }, insertRect(Direction, rect, .left, 5));
    try testing.expectEqual(Rect{ .left = 100, .top = 343, .right = 1100, .bottom = 640 }, insertRect(Direction, rect, .down, 5));
    try testing.expectEqual(Rect{ .left = 100, .top = 40, .right = 1100, .bottom = 338 }, insertRect(Direction, rect, .up, 5));
}

test "insertRect matches the layout of the split it makes" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = 'A' };
    var b: TestView = .{ .label = 'B' };
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &b);
    defer tb.deinit();
    const area: Rect = .{ .top = 40, .right = 1237, .bottom = 811 };
    for ([_]TestTree.Split.Direction{ .left, .right, .up, .down }) |direction| {
        var tree = try ta.split(alloc, .root, direction, 0.5, &tb);
        defer tree.deinit();
        const want = paneRect(TestTree, &tree, area, 7, tree.locate(&b).?).?;
        try testing.expectEqual(want, insertRect(TestTree.Split.Direction, area, direction, 7));
    }
}

test "dimsPane dims the unfocused panes of a split that shows them" {
    try testing.expect(dimsPane(true, false, false));
    try testing.expect(!dimsPane(true, false, true));
    try testing.expect(!dimsPane(true, true, false));
    try testing.expect(!dimsPane(false, false, false));
    try testing.expect(!dimsPane(false, false, true));
}

test "balancedRatio weighs the panes side by side" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = 'A' };
    var b: TestView = .{ .label = 'B' };
    var c: TestView = .{ .label = 'C' };
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, &b);
    defer tb.deinit();
    var tc: TestTree = try .init(alloc, &c);
    defer tc.deinit();

    // A | (B | C): A takes a third.
    var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer ab.deinit();
    var abc = try ab.split(alloc, ab.locate(&b).?, .right, 0.5, &tc);
    defer abc.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), @as(f32, balancedRatio(TestTree, &abc, .root)), 0.001);
    // A | (B / C): a stack counts once across the split.
    var a_bc = try ab.split(alloc, ab.locate(&b).?, .down, 0.5, &tc);
    defer a_bc.deinit();
    try testing.expectEqual(@as(f16, 0.5), balancedRatio(TestTree, &a_bc, .root));
    // A leaf has nothing to balance.
    try testing.expectEqual(@as(f16, 0.5), balancedRatio(TestTree, &ta, .root));
}
