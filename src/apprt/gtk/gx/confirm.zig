//! The running processes in the close confirmation (fork patch GX-0027).
//!
//! Upstream's `CloseConfirmationDialog` only says that closing terminates
//! the terminal sessions. `listProcesses`, called from its `present`, adds
//! what would be terminated: the processes that are not idle
//! (`gx.confirm.appendBusyProcesses`, so `zsh` or `bash` at a prompt are
//! left out) in the terminals of the target that need the confirmation,
//! like the Windows dialogs. The terminals come from the dialog's target and
//! the parent its caller presents it on: every terminal when quitting, the
//! splits of every tab of the window, the splits of the tab, or the active
//! split of the split tree. One `gx.confirm.Scope` lists the processes once
//! for all of them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const adw = @import("adw");
const gtk = @import("gtk");

const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const CoreSurface = @import("../../../Surface.zig");
const Application = @import("../class/application.zig").Application;
const close_confirmation_dialog = @import("../class/close_confirmation_dialog.zig");
const CloseConfirmationDialog = close_confirmation_dialog.CloseConfirmationDialog;
const Target = close_confirmation_dialog.Target;
const SplitTree = @import("../class/split_tree.zig").SplitTree;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;

const log = std.log.scoped(.gtk_gx_confirm);
const tr = gx.i18n.tr;

/// The most rows the process list has; a longer list ends with a row that
/// counts the processes not shown.
pub const max_rows = 6;

/// Sets the extra child of `dialog`, about to be presented on `parent`
/// for `target`, to the list of processes that closing would terminate.
/// Leaves the dialog as it is when there are none or they are unknown.
pub fn listProcesses(dialog: *CloseConfirmationDialog, target: Target, parent: ?*gtk.Widget) void {
    const alloc = Application.default().allocator();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    var processes: Processes = .{ .arena = arena.allocator() };
    {
        var scope: gx.confirm.Scope = undefined;
        scope.begin(alloc, global.io());
        defer scope.end();
        processes.collect(target, parent);
    }
    if (processes.names.items.len == 0) return;

    const list = processList(arena.allocator(), processes.names.items) catch |err| {
        log.warn("cannot show the running processes err={}", .{err});
        return;
    };
    dialog.as(adw.AlertDialog).setExtraChild(list);
}

/// The busy processes of the terminals to close, each name once.
const Processes = struct {
    arena: Allocator,
    names: std.ArrayList([]const u8) = .empty,

    fn collect(self: *Processes, target: Target, parent: ?*gtk.Widget) void {
        switch (target) {
            .app => for (Application.default().core().surfaces.items) |surface| {
                self.addCore(surface.gobj().core());
            },
            .window => if (cast(Window, parent)) |window| self.addWindow(window),
            .tab => if (cast(Tab, parent)) |tab| self.addTree(tab.getSplitTree()),
            .surface => if (cast(SplitTree, parent)) |tree| {
                if (tree.getActiveSurface()) |surface| self.addCore(surface.core());
            },
        }
    }

    fn addWindow(self: *Processes, window: *Window) void {
        const tab_view = window.getTabView();
        const pages: usize = @intCast(@max(0, tab_view.getNPages()));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            self.addTree(tab.getSplitTree());
        }
    }

    fn addTree(self: *Processes, split_tree: *SplitTree) void {
        const tree = split_tree.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| self.addCore(entry.view.core());
    }

    /// Adds the busy processes of a terminal that needs the confirmation,
    /// as `CoreSurface.needsConfirmQuit` decides for the close.
    fn addCore(self: *Processes, core_: ?*CoreSurface) void {
        const core = core_ orelse return;
        if (!core.needsConfirmQuit()) return;
        gx.confirm.appendBusyProcesses(
            self.arena,
            global.io(),
            core.getProcessInfo(.foreground_pid),
            core.config.gx_idle_processes.list.items,
            &self.names,
        ) catch |err| log.warn("cannot list the busy processes err={}", .{err});
    }
};

fn cast(comptime T: type, widget: ?*gtk.Widget) ?*T {
    return gobject.ext.cast(T, widget orelse return null);
}

/// How many of `count` processes get a row, and how many the last row
/// counts instead: never one, which would take a row as well.
pub fn rows(count: usize) struct { shown: usize, more: usize } {
    if (count <= max_rows) return .{ .shown = count, .more = 0 };
    return .{ .shown = max_rows - 1, .more = count - (max_rows - 1) };
}

/// A heading and a boxed list of `names`, copied with `arena`.
fn processList(arena: Allocator, names: []const []const u8) Allocator.Error!*gtk.Widget {
    const box = gtk.Box.new(.vertical, 6);

    const heading = gtk.Label.new(tr("Running processes:"));
    heading.setXalign(0);
    heading.as(gtk.Widget).addCssClass("heading");
    box.append(heading.as(gtk.Widget));

    const list = gtk.ListBox.new();
    list.setSelectionMode(.none);
    list.as(gtk.Widget).addCssClass("boxed-list");
    const counts = rows(names.len);
    for (names[0..counts.shown]) |name| {
        list.append(try row(arena, name, false));
    }
    if (counts.more > 0) {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        gx.i18n.format(&writer, tr("…and {count} more"), .{ .count = counts.more }) catch {};
        list.append(try row(arena, writer.buffered(), true));
    }
    box.append(list.as(gtk.Widget));

    return box.as(gtk.Widget);
}

fn row(arena: Allocator, text: []const u8, dim: bool) Allocator.Error!*gtk.Widget {
    const label = gtk.Label.new((try arena.dupeSentinel(u8, text, 0)).ptr);
    label.setXalign(0);
    label.setEllipsize(.end);
    const widget = label.as(gtk.Widget);
    widget.setMarginStart(12);
    widget.setMarginEnd(12);
    widget.setMarginTop(8);
    widget.setMarginBottom(8);
    if (dim) widget.addCssClass("dim-label");

    const list_row = gtk.ListBoxRow.new();
    list_row.setActivatable(@intFromBool(false));
    list_row.setChild(widget);
    return list_row.as(gtk.Widget);
}

test "rows never count a single process in the last row" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), rows(0).shown);
    try testing.expectEqual(@as(usize, 1), rows(1).shown);
    try testing.expectEqual(@as(usize, max_rows), rows(max_rows).shown);
    try testing.expectEqual(@as(usize, 0), rows(max_rows).more);
    try testing.expectEqual(@as(usize, max_rows - 1), rows(max_rows + 1).shown);
    try testing.expectEqual(@as(usize, 2), rows(max_rows + 1).more);
    try testing.expectEqual(@as(usize, 20 - (max_rows - 1)), rows(20).more);
    for (0..30) |count| {
        const r = rows(count);
        try testing.expectEqual(count, r.shown + r.more);
        try testing.expect(r.shown + @intFromBool(r.more > 0) <= max_rows);
        try testing.expect(r.more != 1);
    }
}
