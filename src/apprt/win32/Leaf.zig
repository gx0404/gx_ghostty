//! GUI-thread owned split-tree identity. Each local Surface has one weak Leaf
//! backlink; every retained tree owns a strong backend and Leaf reference.
const Self = @This();
const std = @import("std");
const Surface = @import("Surface.zig");
const RemotePane = @import("RemotePane.zig");
const Pane = @import("Pane.zig");
const Window = @import("Window.zig");
const refs = @import("../../gx/ui_ref.zig");
const Allocator = std.mem.Allocator;

ref_count: u32 = 0,
backend: union(enum) { local: *Surface, remote: *RemotePane },

pub fn fromLocal(alloc: Allocator, surface: *Surface) !*Self {
    if (surface.leaf) |leaf| return leaf;
    const leaf = try alloc.create(Self);
    leaf.* = .{ .backend = .{ .local = surface } };
    surface.leaf = leaf;
    return leaf;
}
pub fn fromRemote(alloc: Allocator, remote_pane: *RemotePane) !*Self {
    const leaf = try alloc.create(Self);
    leaf.* = .{ .backend = .{ .remote = remote_pane } };
    return leaf;
}
/// Only for a just-created identity whose first tree allocation failed.
pub fn discardUnretained(self: *Self, alloc: Allocator) void {
    std.debug.assert(self.ref_count == 0);
    switch (self.backend) {
        .local => |s| s.leaf = null,
        .remote => {},
    }
    alloc.destroy(self);
}
pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
    std.debug.assert(self.ref_count < std.math.maxInt(u32));
    switch (self.backend) {
        .local => |s| _ = try s.ref(alloc),
        .remote => |r| _ = try r.ref(alloc),
    }
    self.ref_count += 1;
    return self;
}
pub fn unref(self: *Self, alloc: Allocator) void {
    std.debug.assert(self.ref_count > 0);
    self.ref_count -= 1;
    const final = self.ref_count == 0;
    switch (self.backend) {
        .local => |s| {
            if (final) s.leaf = null;
            s.unref(alloc);
        },
        .remote => |r| r.unref(alloc),
    }
    if (final) alloc.destroy(self);
}
pub fn eql(self: *const Self, other: *const Self) bool {
    return self == other;
}
/// Core/WGL-only access. Window layout and GUI operations dispatch via Pane.
pub fn local(self: *const Self) ?*Surface {
    return switch (self.backend) {
        .local => |s| s,
        .remote => null,
    };
}
pub fn remote(self: *const Self) ?*RemotePane {
    return switch (self.backend) {
        .remote => |r| r,
        .local => null,
    };
}
pub fn pane(self: *const Self) Pane {
    return switch (self.backend) {
        .local => |s| Pane.fromLocal(s),
        .remote => |r| Pane.fromRemote(r),
    };
}
pub fn nativeHandle(self: *const Self) ?@import("win32.zig").HWND {
    return self.pane().nativeHandle();
}
pub fn reference(self: *const Self) refs.Reference {
    return self.pane().reference();
}
pub fn attachment(self: *const Self) refs.Attachment {
    return self.pane().attachment();
}
pub fn ownerWindow(self: *const Self) *Window {
    return self.pane().ownerWindow();
}
pub fn getTitle(self: *const Self) ?[]const u8 {
    return switch (self.backend) {
        .local => |s| s.getTitle(),
        .remote => |r| r.getTitle(),
    };
}
pub fn scale(self: *const Self) f32 {
    return switch (self.backend) {
        .local => |s| s.scale,
        .remote => |r| r.scale,
    };
}
pub fn setVisible(self: *Self, visible: bool) void {
    switch (self.backend) {
        inline else => |p| p.setVisible(visible),
    }
}
pub fn handleDpiChange(self: *Self, dpi: u32) void {
    switch (self.backend) {
        inline else => |p| p.handleDpiChange(dpi),
    }
}
pub fn prepareReparent(self: *Self, window: *Window) !refs.Attachment {
    return switch (self.backend) {
        inline else => |p| try p.prepareReparent(window),
    };
}
pub fn onReparented(self: *Self, window: *Window, attached: refs.Attachment) void {
    switch (self.backend) {
        inline else => |p| p.onReparented(window, attached),
    }
}
pub fn onLanguageChanged(self: *Self) void {
    switch (self.backend) {
        inline else => |p| p.onLanguageChanged(),
    }
}
pub fn setUnfocusedDim(self: *Self, dim: Surface.DimColor) void {
    switch (self.backend) {
        inline else => |p| p.setUnfocusedDim(dim),
    }
}
pub fn refreshRenderer(self: *Self) void {
    switch (self.backend) {
        inline else => |p| p.refreshRenderer(),
    }
}
pub fn repositionPopups(self: *Self) void {
    switch (self.backend) {
        .local => |s| s.repositionPopups(),
        .remote => {},
    }
}
pub fn setLiveResize(self: *Self, live: bool) void {
    switch (self.backend) {
        .local => |s| s.in_live_resize = live,
        .remote => {},
    }
}
pub fn refreshScrollbarMode(self: *Self) void {
    switch (self.backend) {
        .local => |s| s.refreshScrollbarMode(),
        .remote => {},
    }
}
pub fn needsConfirmQuit(self: *Self) bool {
    return switch (self.backend) {
        .local => |s| s.core_surface_ready and s.core_surface.needsConfirmQuit(),
        .remote => |r| r.needsConfirmQuit(),
    };
}
pub fn appendBusyProcesses(self: *Self, alloc: Allocator, names: *std.ArrayList([]const u8)) void {
    switch (self.backend) {
        .local => |s| s.appendBusyProcesses(alloc, names),
        .remote => |r| {
            const copied = r.snapshot();
            if (copied.busy.len != 0) {
                const name = alloc.dupe(u8, copied.busy.slice()) catch return;
                names.append(alloc, name) catch alloc.free(name);
            }
        },
    }
}
pub fn progress(self: *const Self) @import("tab_status.zig").Progress {
    return switch (self.backend) {
        .local => |s| s.progress,
        .remote => |r| r.snapshot().progress,
    };
}

test "leaf identity is retained through tree clones and never aliases a backend copy" {
    const alloc = std.testing.allocator;
    var surface: Surface = .{ .app = undefined, .ref_count = 1 };
    const leaf = try Self.fromLocal(alloc, &surface);
    try std.testing.expect(leaf == try Self.fromLocal(alloc, &surface));
    const Tree = @import("../../datastruct/split_tree.zig").SplitTree(Self);
    var tree = try Tree.init(alloc, leaf);
    var clone = try tree.clone(alloc);
    try std.testing.expectEqual(@as(u32, 2), leaf.ref_count);
    tree.deinit();
    try std.testing.expectEqual(@as(u32, 1), leaf.ref_count);
    try std.testing.expect(clone.nodes[0].leaf.eql(leaf));
    clone.deinit();
    try std.testing.expect(surface.leaf == null);
    try std.testing.expectEqual(@as(u32, 1), surface.ref_count);
}

test "mixed leaf trees retain backend identity through split clone and removal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var local_surface: Surface = .{ .app = undefined, .ref_count = 1 };
    var remote_pane: RemotePane = undefined;
    remote_pane.ref_count = 1;
    remote_pane.destroying = true;
    const local_leaf = try fromLocal(alloc, &local_surface);
    const remote_leaf = try fromRemote(alloc, &remote_pane);
    const Tree = @import("../../datastruct/split_tree.zig").SplitTree(Self);
    var local_tree = try Tree.init(alloc, local_leaf);
    defer local_tree.deinit();
    var remote_tree = try Tree.init(alloc, remote_leaf);
    defer remote_tree.deinit();
    var mixed = try local_tree.split(alloc, .root, .right, 0.35, &remote_tree);
    defer mixed.deinit();
    var retained = try mixed.clone(alloc);
    defer retained.deinit();
    try testing.expect(local_leaf.local() == &local_surface);
    try testing.expect(remote_leaf.local() == null);
    try testing.expect(remote_leaf.remote() == &remote_pane);
    const remote_handle = retained.locate(remote_leaf).?;
    retained.zoom(remote_handle);
    try testing.expect(retained.zoomed == remote_handle);
    var remaining = try retained.remove(alloc, remote_handle);
    defer remaining.deinit();
    try testing.expect(!remaining.isSplit());
    try testing.expect(remaining.nodes[0].leaf == local_leaf);
    try testing.expect(mixed.locate(remote_leaf) != null);
    try testing.expectEqual(@as(u32, 4), remote_pane.ref_count);
}
