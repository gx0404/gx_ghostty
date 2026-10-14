//! Move a live GTK Surface into an empty tab/window without a new process.
const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;
const Tab = @import("../class/tab.zig").Tab;
const Surface = @import("../class/surface.zig").Surface;
const SplitTree = @import("../class/split_tree.zig").SplitTree;
const lifecycle = @import("tree_lifecycle.zig");
const runtime = @import("runtime.zig");
const log = std.log.scoped(.gtk_gx_split_transfer);
const busy_key = "gx-split-transfer-active";

pub const Destination = enum { tab, window };

pub fn perform(app: *Application, target: apprt.Target, destination: Destination) bool {
    const core = switch (target) {
        .surface => |core| core,
        .app => app.core().focusedSurface() orelse return false,
    };
    return transfer(app, core.rt_surface.surface, destination) catch |err| {
        log.warn("cannot transfer split: {}", .{err});
        return false;
    };
}

fn transfer(app: *Application, surface: *Surface, destination: Destination) !bool {
    const source_window = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse return false;
    if (source_window.isQuickTerminal()) return false;
    const source_tree = ext.getAncestor(SplitTree, surface.as(gtk.Widget)) orelse return false;
    const tree = source_tree.getTree() orelse return false;
    // Match the Windows actions: moving a whole tab is a separate operation.
    if (!tree.isSplit()) return false;
    const handle = tree.locate(surface) orelse return false;
    const source_reference = runtime.reference(surface.as(gobject.Object));
    if (runtime.resolveSurface(app, source_reference) != surface) return false;
    const window_reference = runtime.reference(source_window.as(gobject.Object));
    if (runtime.resolveWindow(app, window_reference) != source_window) return false;

    const source_object = source_window.as(gobject.Object);
    if (source_object.getData(busy_key) != null) return false;
    source_object.setData(busy_key, @ptrFromInt(1));
    defer source_object.setData(busy_key, null);
    _ = source_window.ref();
    defer source_window.unref();
    _ = source_tree.ref();
    defer source_tree.unref();
    _ = surface.ref();
    defer surface.unref();

    // Every recoverable allocation completes while the original model and
    // widgets remain untouched. Both trees retain strong refs to their leaves.
    var prepared = try prepareModels(Surface.Tree, app.allocator(), tree, handle);
    defer prepared.deinit();
    var remaining = try lifecycle.prepare(app.allocator(), &prepared.remaining);
    defer lifecycle.abandon(remaining);
    var moved = try lifecycle.prepare(app.allocator(), &prepared.moved);
    defer lifecycle.abandon(moved);
    const old_focus = source_tree.getLastFocusedSurface();
    const next_focus = chooseFocus(Surface.Tree, &prepared.remaining, old_focus, surface);

    const config = source_window.getConfig();
    const tab = Tab.newEmpty(config);
    _ = tab.as(gobject.Object).refSink();
    defer tab.unref();
    try runtime.prepareTab(tab);
    const target_tree = tab.getSplitTree();

    const target_window = switch (destination) {
        .tab => source_window,
        .window => app.gxNewEmptyWindow(),
    };
    var committed = false;
    defer if (!committed and destination == .window) target_window.as(gtk.Window).destroy();
    if (!runtime.reference(target_window.as(gobject.Object)).isValid()) return error.InvalidReference;

    // Creating GTK containers emits signals. Recheck the actual source after
    // those calls; a held strong reference alone does not prove live ownership.
    if (runtime.resolveWindow(app, window_reference) != source_window or
        runtime.resolveSurface(app, source_reference) != surface or
        source_tree.getTree() != tree or
        ext.getAncestor(SplitTree, surface.as(gtk.Widget)) != source_tree) return error.StaleSource;

    // No recoverable work remains. Synchronously move the existing
    // scrolled-window widget into the unattached target before removing the
    // source model. This preserves the Surface, renderer, PTY and scrollback.
    target_tree.adoptOwnedTree(moved, surface);
    moved = null;
    target_tree.rebuildNow();
    // Rebuild the source while its page is still shown, then publish the
    // target. GTK 4.14-4.18 _gtk_window_unset_focus_and_default overwrites a
    // pending strong move_focus_widget ref instead of releasing it. Selecting
    // the target first queued a ref to the source page bin while focus was in
    // the moved pane, and unparenting that pane replaced it, so the source tab,
    // its model and remaining leaves never finalized. Here the visible remaining
    // leaf takes focus before the page switch, so each pending ref is cleared
    // by a visible grab before another can be queued.
    source_tree.adoptOwnedTree(remaining, next_focus);
    remaining = null;
    source_tree.rebuildNow();
    _ = target_window.adoptTab(tab);
    // Source disconnect only revokes its own old lease, never the target lease.
    // The same Window is userdata on both old/new leaf signal handlers, so
    // reconnect every leaf after both models and the target page commit.
    source_window.gxRebindSurfaceHandlers();
    if (target_window != source_window) target_window.gxRebindSurfaceHandlers();
    committed = true;

    if (destination == .window) {
        // Keep the existing terminal grid approximately stable on first show.
        const width = source_window.as(gtk.Widget).getWidth();
        const height = source_window.as(gtk.Widget).getHeight();
        if (width > 0 and height > 0) target_window.as(gtk.Window).setDefaultSize(width, height);
        target_window.as(gtk.Window).present();
    }
    surface.grabFocus();
    surface.redraw();
    return true;
}

fn Models(comptime Tree: type) type {
    return struct {
        remaining: Tree,
        moved: Tree,
        fn deinit(self: *@This()) void {
            self.remaining.deinit();
            self.moved.deinit();
        }
    };
}

fn prepareModels(comptime Tree: type, alloc: std.mem.Allocator, tree: *Tree, handle: Tree.Node.Handle) !Models(Tree) {
    if (!tree.isSplit()) return error.OnlyPane;
    if (handle.idx() >= tree.nodes.len) return error.InvalidPane;
    const surface = switch (tree.nodes[handle.idx()]) {
        .leaf => |value| value,
        .split => return error.InvalidPane,
    };
    var moved = try Tree.init(alloc, surface);
    errdefer moved.deinit();
    return .{ .remaining = try tree.remove(alloc, handle), .moved = moved };
}

fn chooseFocus(comptime Tree: type, tree: *const Tree, previous: anytype, moved: @TypeOf(previous)) @TypeOf(previous) {
    if (previous) |view| if (view != moved) {
        if (tree.locate(view) != null) return view;
    };
    var it = tree.iterator();
    return if (it.next()) |entry| entry.view else null;
}

const TestView = struct {
    refs: usize = 0,
    pub fn ref(self: *@This()) *@This() {
        self.refs += 1;
        return self;
    }
    pub fn unref(self: *@This()) void {
        self.refs -= 1;
    }
    pub fn splitTreeLabel(_: *const @This()) []const u8 {
        return "pane";
    }
};
const TestTree = @import("../../../datastruct/split_tree.zig").SplitTree(TestView);

test "transfer preparation preserves identities zoom and source on every allocation failure" {
    const testing = std.testing;
    var left: TestView = .{};
    var right: TestView = .{};
    var left_tree = try TestTree.init(testing.allocator, &left);
    defer left_tree.deinit();
    var right_tree = try TestTree.init(testing.allocator, &right);
    defer right_tree.deinit();
    var tree = try left_tree.split(testing.allocator, .root, .right, 0.3, &right_tree);
    defer tree.deinit();
    tree.zoomed = tree.locate(&left).?;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn check(alloc: std.mem.Allocator, source: *TestTree, retained: *TestView, moved_view: *TestView) !void {
            const before_nodes = source.nodes;
            const before_zoom = source.zoomed;
            const retained_refs = retained.refs;
            const moved_refs = moved_view.refs;
            defer {
                testing.expect(source.nodes.ptr == before_nodes.ptr) catch @panic("source changed");
                testing.expectEqual(before_zoom, source.zoomed) catch @panic("zoom changed");
                testing.expectEqual(retained_refs, retained.refs) catch @panic("retained reference leak");
                testing.expectEqual(moved_refs, moved_view.refs) catch @panic("moved reference leak");
            }
            var prepared = try prepareModels(TestTree, alloc, source, source.locate(moved_view).?);
            defer prepared.deinit();
            try testing.expect(prepared.moved.nodes[0].leaf == moved_view);
            try testing.expect(prepared.remaining.nodes[0].leaf == retained);
            try testing.expectEqual(TestTree.Node.Handle.root, prepared.remaining.zoomed.?);
            try testing.expectEqual(@as(?TestTree.Node.Handle, null), prepared.moved.zoomed);
        }
    }.check, .{ &tree, &left, &right });
}

test "transfer rejects whole tab and branch without changing source" {
    const testing = std.testing;
    var one: TestView = .{};
    var tree = try TestTree.init(testing.allocator, &one);
    defer tree.deinit();
    try testing.expectError(error.OnlyPane, prepareModels(TestTree, testing.allocator, &tree, .root));
    var two: TestView = .{};
    var other = try TestTree.init(testing.allocator, &two);
    defer other.deinit();
    var split = try tree.split(testing.allocator, .root, .right, 0.5, &other);
    defer split.deinit();
    try testing.expectError(error.InvalidPane, prepareModels(TestTree, testing.allocator, &split, .root));
    try testing.expectEqual(@as(?*TestView, &one), chooseFocus(TestTree, &split, @as(?*TestView, &one), @as(?*TestView, &two)));
}
