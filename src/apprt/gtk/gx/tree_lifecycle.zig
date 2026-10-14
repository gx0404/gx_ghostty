//! Preparation and membership checks for transferring already-running GTK leaves.
const std = @import("std");
const glib = @import("glib");
const Surface = @import("../class/surface.zig").Surface;

/// Clone the complete tree before changing either owner. The returned box is
/// compatible with Surface.Tree's GObject destructor; adoptOwnedTree consumes
/// it, while abandon frees it. GLib container allocation and Zig node allocation
/// both report failure before a source tree is changed.
pub fn prepare(alloc: std.mem.Allocator, tree: *const Surface.Tree) std.mem.Allocator.Error!?*Surface.Tree {
    if (tree.isEmpty()) return null;
    const data = glib.tryMalloc(@sizeOf(Surface.Tree)) orelse return error.OutOfMemory;
    const result: *Surface.Tree = @ptrCast(@alignCast(data));
    errdefer glib.free(result);
    result.* = try tree.clone(alloc);
    return result;
}

pub fn abandon(tree: ?*Surface.Tree) void {
    if (tree) |value| {
        value.deinit();
        glib.free(value);
    }
}

pub fn contains(tree: ?*const Surface.Tree, surface: ?*Surface) bool {
    const value = tree orelse return false;
    const view = surface orelse return false;
    var it = value.iterator();
    while (it.next()) |entry| if (entry.view == view) return true;
    return false;
}

test "empty transfer preparation never allocates" {
    try std.testing.expectEqual(@as(?*Surface.Tree, null), try prepare(std.testing.failing_allocator, &.empty));
    try std.testing.expect(!contains(null, null));
}
