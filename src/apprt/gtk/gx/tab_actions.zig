//! Key bindings and the command palette close tabs like the GX tab menu:
//! `close_tab:other` and `close_tab:right` leave the pinned tabs (D-22).
//! They reach the tab through `Application.Action.closeTab`, which
//! activates `tab.close` on the focused surface, and upstream's
//! `Tab.actionClose` closes `other` with `AdwTabView.closeOtherPages` and
//! `right` with `closePagesAfter`, pinned tabs included, because the window
//! confirms every close request. A "tab" action group whose only action is
//! `close`, on the split tree of each tab, answers first: GTK looks a
//! prefixed action up from the widget towards the root and goes on to the
//! next group with that prefix when one lacks the action, so the tab's
//! other actions still come from the tab. Closing this tab is forwarded to
//! the upstream action on the Tab itself, above our group.
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const SplitTree = @import("../class/split_tree.zig").SplitTree;
const Tab = @import("../class/tab.zig").Tab;
const window = @import("window.zig");

const log = std.log.scoped(.gtk_gx_tab_actions);

/// The object data key on a split tree that has the group.
const attached_key = "gx-tab-close-group";

/// Adds the "tab" group with `close` to the split tree of `tab`, once; a
/// tab moved to another window keeps it.
pub fn attach(tab: *Tab) void {
    const tree = tab.getSplitTree();
    const object = tree.as(gobject.Object);
    if (object.getData(attached_key) != null) return;
    insertCloseGroup(SplitTree, tree.as(gtk.Widget), tree, actionClose);
    object.setData(attached_key, @ptrFromInt(1));
}

/// Inserts a "tab" group on `widget` whose only action is `close`, with
/// the close mode as its string parameter like upstream's `tab.close`.
fn insertCloseGroup(
    comptime T: type,
    widget: *gtk.Widget,
    data: *T,
    callback: ext.actions.Action(T).Callback,
) void {
    const group = gio.SimpleActionGroup.new();
    defer group.unref();
    const s_type = glib.ext.VariantType.newFor([:0]const u8);
    defer s_type.free();
    ext.actions.addToMap(T, data, group.as(gio.ActionMap), &.{
        .init("close", callback, s_type),
    });
    widget.insertActionGroup("tab", group.as(gio.ActionGroup));
}

fn actionClose(_: *gio.SimpleAction, param_: ?*glib.Variant, tree: *SplitTree) callconv(.c) void {
    const param = param_ orelse return;
    var str: ?[*:0]const u8 = null;
    param.get("&s", &str);
    const name = std.mem.span(str orelse return);
    const mode = std.meta.stringToEnum(apprt.action.CloseTabMode, name) orelse {
        log.warn("invalid mode provided to tab.close: {s}", .{name});
        return;
    };
    const tab = ext.getAncestor(Tab, tree.as(gtk.Widget)) orelse return;
    const view = ext.getAncestor(adw.TabView, tab.as(gtk.Widget)) orelse return;
    if (mode == .this) return closeThis(tab.as(gtk.Widget));
    close(view, view.getPage(tab.as(gtk.Widget)), mode);
}

fn closeThis(tab: *gtk.Widget) void {
    _ = tab.activateAction("tab.close", "s", @as([*:0]const u8, "this"));
}

/// Asks to close what `mode` names from `page`: the page itself, or the
/// unpinned tabs other than it or after it, like the tab menu.
fn close(view: *adw.TabView, page: *adw.TabPage, mode: apprt.action.CloseTabMode) void {
    switch (mode) {
        .this => unreachable, // Forwarded to the upstream Tab before entering here.
        .other => window.closeOtherTabs(view, page),
        .right => window.closeTabsRight(view, page),
    }
}

const TestCounts = struct {
    tab: ?*gtk.Widget = null,
    tab_close: u32 = 0,
    gx_close: u32 = 0,
    next_page: u32 = 0,
};

fn testTabClose(_: *gio.SimpleAction, _: ?*glib.Variant, counts: *TestCounts) callconv(.c) void {
    counts.tab_close += 1;
}

fn testGxClose(_: *gio.SimpleAction, param: ?*glib.Variant, counts: *TestCounts) callconv(.c) void {
    var str: ?[*:0]const u8 = null;
    param.?.get("&s", &str);
    if (std.mem.eql(u8, std.mem.span(str.?), "this")) return closeThis(counts.tab.?);
    if (std.mem.eql(u8, std.mem.span(str.?), "right")) counts.gx_close += 1;
}

fn testNextPage(_: *gio.SimpleAction, _: ?*glib.Variant, counts: *TestCounts) callconv(.c) void {
    counts.next_page += 1;
}

test "a close group on the split tree answers tab.close and leaves the other tab actions to the tab" {
    const testing = std.testing;
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    // The tab with its own "tab" group (close and next-page, like
    // `Tab.initActionMap`), its split tree with the GX group, and a surface
    // and a menu item inside the tree.
    const tab = gtk.Box.new(.vertical, 0);
    _ = tab.as(gobject.Object).refSink();
    defer tab.as(gobject.Object).unref();
    const tree = gtk.Box.new(.vertical, 0);
    tab.append(tree.as(gtk.Widget));
    const surface = gtk.Box.new(.vertical, 0);
    tree.append(surface.as(gtk.Widget));
    const item = gtk.Button.new();
    tree.append(item.as(gtk.Widget));

    var counts: TestCounts = .{ .tab = tab.as(gtk.Widget) };
    const tab_group = gio.SimpleActionGroup.new();
    defer tab_group.unref();
    const s_type = glib.ext.VariantType.newFor([:0]const u8);
    defer s_type.free();
    ext.actions.addToMap(TestCounts, &counts, tab_group.as(gio.ActionMap), &.{
        .init("close", testTabClose, s_type),
        .init("next-page", testNextPage, null),
    });
    tab.as(gtk.Widget).insertActionGroup("tab", tab_group.as(gio.ActionGroup));
    insertCloseGroup(TestCounts, tree.as(gtk.Widget), &counts, testGxClose);

    // From the surface, tab.close reaches the GX group only.
    try testing.expect(surface.as(gtk.Widget).activateAction("tab.close", "s", @as([*:0]const u8, "right")) != 0);
    try testing.expectEqual(@as(u32, 1), counts.gx_close);
    try testing.expectEqual(@as(u32, 0), counts.tab_close);

    // The tab's other actions are still found, and their state still
    // reaches the widgets that show them.
    try testing.expect(surface.as(gtk.Widget).activateAction("tab.next-page", null) != 0);
    try testing.expectEqual(@as(u32, 1), counts.next_page);
    item.as(gtk.Actionable).setActionName("tab.next-page");
    try testing.expect(item.as(gtk.Widget).getSensitive() != 0);
    const next = gobject.ext.cast(gio.SimpleAction, tab_group.as(gio.ActionMap).lookupAction("next-page").?).?;
    next.setEnabled(0);
    try testing.expect(item.as(gtk.Widget).getSensitive() == 0);
    next.setEnabled(1);
    try testing.expect(item.as(gtk.Widget).getSensitive() != 0);

    // From the surface, this forwards to upstream exactly once, without
    // recursing through our group or implementing upstream close semantics.
    try testing.expect(surface.as(gtk.Widget).activateAction("tab.close", "s", @as([*:0]const u8, "this")) != 0);
    try testing.expectEqual(@as(u32, 1), counts.tab_close);
    try testing.expectEqual(@as(u32, 1), counts.gx_close);
    counts.tab_close = 0;

    // Above the split tree the tab's own close still answers.
    try testing.expect(tab.as(gtk.Widget).activateAction("tab.close", "s", @as([*:0]const u8, "this")) != 0);
    try testing.expectEqual(@as(u32, 1), counts.tab_close);
}

test "closing from a key binding keeps the pinned tabs" {
    const testing = std.testing;
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    const view = adw.TabView.new();
    _ = view.as(gobject.Object).refSink();
    defer view.as(gobject.Object).unref();
    _ = adw.TabView.signals.close_page.connect(view, ?*anyopaque, testConfirmClose, null, .{});

    var pages: [6]*adw.TabPage = undefined;
    for (&pages) |*page| {
        page.* = view.append(gtk.Label.new(null).as(gtk.Widget));
        _ = page.*.as(gobject.Object).ref();
    }
    defer for (pages) |page| page.as(gobject.Object).unref();
    view.setPagePinned(pages[0], 1);
    view.setPagePinned(pages[1], 1);

    // close_tab:other from an unpinned tab: the pinned tabs stay.
    close(view, pages[3], .other);
    try testing.expectEqual(@as(c_int, 3), view.getNPages());
    for ([_]*adw.TabPage{ pages[0], pages[1], pages[3] }) |page| try testing.expect(view.getPagePosition(page) >= 0);

    // close_tab:right from the first pinned tab: the other pinned tab stays.
    close(view, pages[0], .right);
    try testing.expectEqual(@as(c_int, 2), view.getNPages());
    for ([_]*adw.TabPage{ pages[0], pages[1] }) |page| try testing.expect(view.getPagePosition(page) >= 0);
}

fn testConfirmClose(view: *adw.TabView, page: *adw.TabPage, _: ?*anyopaque) callconv(.c) c_int {
    view.closePageFinish(page, 1);
    return 1;
}
