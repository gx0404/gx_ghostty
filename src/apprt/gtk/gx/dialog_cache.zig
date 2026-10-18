//! At most one reusable dialog per toplevel window (P4). Closing a kept
//! dialog only takes it out of its window, and the next opening there
//! presents the same dialog again instead of building a new one. The
//! window holds the reference: dropping the dialog (when what it shows is
//! out of date) or finalizing the window object releases it.
const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

/// The dialogs of type `T` kept on windows under the object data `key`.
pub fn Cache(comptime T: type, comptime key: [:0]const u8) type {
    return struct {
        /// The dialog `window` keeps, if any. The window holds the reference.
        pub fn get(window: *gtk.Window) ?*T {
            const data = window.as(gobject.Object).getData(key) orelse return null;
            return @ptrCast(@alignCast(data));
        }

        /// Keeps `dialog` for `window`, releasing the dialog kept before.
        /// Takes a reference, sinking a floating one.
        pub fn keep(window: *gtk.Window, dialog: *T) void {
            _ = dialog.as(gobject.Object).refSink();
            window.as(gobject.Object).setDataFull(key, dialog, &release);
        }

        /// Releases the dialog `window` keeps; it is destroyed once nothing
        /// else holds it.
        pub fn drop(window: *gtk.Window) void {
            window.as(gobject.Object).setDataFull(key, null, null);
        }

        fn release(data: ?*anyopaque) callconv(.c) void {
            const object: *gobject.Object = @ptrCast(@alignCast(data orelse return));
            object.unref();
        }
    };
}

/// Whether `window` shows an `adw.Dialog` inside itself, so that it can
/// keep one (`adw_dialog_present` makes a separate window otherwise).
pub fn hostsDialogs(window: *gtk.Window) bool {
    const object = window.as(gobject.Object);
    const adwaita = gobject.ext.isA(object, adw.ApplicationWindow) or gobject.ext.isA(object, adw.Window);
    return adwaita and window.getResizable() != 0;
}

const testing = std.testing;
const TestCache = Cache(adw.Dialog, "gx-test-dialog-cache");

/// Runs the main loop until `done` returns true, for at most `ms`
/// milliseconds; returns whether it did.
fn runUntil(context: anytype, comptime done: fn (@TypeOf(context)) bool, ms: u32) bool {
    // Wakes the loop up so that the deadline is checked.
    const tick = glib.timeoutAdd(5, &keepTicking, null);
    defer _ = glib.Source.remove(tick);
    const deadline = glib.getMonotonicTime() + @as(i64, ms) * 1000;
    while (!done(context)) {
        if (glib.getMonotonicTime() >= deadline) return false;
        _ = glib.MainContext.iteration(null, 1);
    }
    return true;
}

fn keepTicking(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

fn shown(dialog: *adw.Dialog) bool {
    const widget = dialog.as(gtk.Widget);
    return widget.getMapped() != 0 and frames(dialog) >= 3;
}

fn removed(dialog: *adw.Dialog) bool {
    return dialog.as(gtk.Widget).getParent() == null;
}

const frames_key = "gx-test-frames";

fn frames(dialog: *adw.Dialog) usize {
    return @intFromPtr(dialog.as(gobject.Object).getData(frames_key));
}

fn countFrame(widget: *gtk.Widget, _: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
    const object = widget.as(gobject.Object);
    object.setData(frames_key, @ptrFromInt(@intFromPtr(object.getData(frames_key)) + 1));
    return 1;
}

const gdk = @import("gdk");

/// The widgets below `widget`, itself included.
fn widgetCount(widget: *gtk.Widget) usize {
    var count: usize = 1;
    var child = widget.getFirstChild();
    while (child) |current| : (child = current.getNextSibling()) count += widgetCount(current);
    return count;
}

fn setAnimations(on: bool) void {
    const settings = gtk.Settings.getDefault() orelse return;
    var value = gobject.ext.Value.newFrom(on);
    defer value.unset();
    gobject.Object.setProperty(settings.as(gobject.Object), "gtk-enable-animations", &value);
}

test "a kept dialog opens and closes 100 times without growing its window" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    adw.init();
    setAnimations(false);
    defer setAnimations(true);

    const window = adw.Window.new();
    const gtk_window = window.as(gtk.Window);
    gtk_window.setDefaultSize(800, 600);
    gtk_window.present();
    defer gtk_window.destroy();
    try testing.expect(hostsDialogs(gtk_window));
    const toplevels = gtk.Window.getToplevels().getNItems();

    var finalized: Finalization = .{};
    defer finalized.deinit();
    const first = adw.Dialog.new();
    finalized.watch(first.as(gobject.Object));
    first.setChild(gtk.Label.new("kept").as(gtk.Widget));
    _ = first.as(gtk.Widget).addTickCallback(&countFrame, null, null);
    TestCache.keep(gtk_window, first);

    // The window's widgets, with the dialog shown and after it closed, stay
    // as they were at the first opening.
    var shown_count: ?usize = null;
    var closed_count: ?usize = null;
    for (0..100) |_| {
        const dialog = TestCache.get(gtk_window) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(first, dialog);
        dialog.as(gobject.Object).setData(frames_key, null);
        dialog.present(window.as(gtk.Widget));
        try testing.expect(runUntil(dialog, shown, 2000));
        const count = widgetCount(window.as(gtk.Widget));
        if (shown_count) |expected| try testing.expectEqual(expected, count) else shown_count = count;
        try testing.expect(dialog.close() != 0);
        try testing.expect(runUntil(dialog, removed, 2000));
        const after = widgetCount(window.as(gtk.Widget));
        if (closed_count) |expected| try testing.expectEqual(expected, after) else closed_count = after;
        try testing.expect(after < shown_count.?);
        try testing.expectEqual(toplevels, gtk.Window.getToplevels().getNItems());
    }
    try testing.expect(!finalized.done());

    // Dropped (out of date), the hidden dialog goes, and the next opening
    // builds a new one.
    TestCache.drop(gtk_window);
    try testing.expect(TestCache.get(gtk_window) == null);
    // GTK can keep an unparented widget until the frame clock's after-paint
    // phase completes. Dropping our reference must still really finalize
    // it; unparenting or clearing the cache alone does not prove that.
    try testing.expect(runUntil(&finalized, Finalization.done, 2000));
}

test "destroying its window releases the kept dialog" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    adw.init();
    const window = adw.Window.new();
    const gtk_window = window.as(gtk.Window);
    var finalized: Finalization = .{};
    defer finalized.deinit();
    const dialog = adw.Dialog.new();
    finalized.watch(dialog.as(gobject.Object));
    TestCache.keep(gtk_window, dialog);
    // Keeping another one releases the first.
    var second_finalized: Finalization = .{};
    defer second_finalized.deinit();
    const second = adw.Dialog.new();
    second_finalized.watch(second.as(gobject.Object));
    TestCache.keep(gtk_window, second);
    try testing.expect(finalized.done());
    try testing.expect(!second_finalized.done());
    gtk_window.destroy();
    try testing.expect(second_finalized.done());
}

test "dropping a cached dialog releases only the cache reference" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    adw.init();
    const window = adw.Window.new().as(gtk.Window);
    defer window.destroy();
    var finalized: Finalization = .{};
    defer finalized.deinit();
    const dialog = adw.Dialog.new();
    finalized.watch(dialog.as(gobject.Object));
    {
        const owned = dialog.as(gobject.Object).refSink();
        defer owned.unref();
        const child = gtk.Label.new("still owned").as(gtk.Widget);
        dialog.setChild(child);
        TestCache.keep(window, dialog);
        TestCache.drop(window);
        try testing.expect(TestCache.get(window) == null);
        try testing.expect(!finalized.done());
        try testing.expectEqual(child, dialog.getChild());
    }
    try testing.expect(finalized.done());
}

test "destroying a window finalizes its presented or hidden cached dialog" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    adw.init();
    for ([_]bool{ false, true }) |close_first| {
        const window = adw.Window.new().as(gtk.Window);
        var destroyed = false;
        defer if (!destroyed) window.destroy();
        window.setDefaultSize(800, 600);
        window.present();
        var finalized: Finalization = .{};
        defer finalized.deinit();
        const dialog = adw.Dialog.new();
        finalized.watch(dialog.as(gobject.Object));
        dialog.setChild(gtk.Label.new("owned by window").as(gtk.Widget));
        _ = dialog.as(gtk.Widget).addTickCallback(&countFrame, null, null);
        TestCache.keep(window, dialog);
        dialog.present(window.as(gtk.Widget));
        try testing.expect(runUntil(dialog, shown, 2000));
        if (close_first) {
            try testing.expect(dialog.close() != 0);
            try testing.expect(runUntil(dialog, removed, 2000));
            try testing.expectEqual(dialog, TestCache.get(window));
            try testing.expect(!finalized.done());
        }
        window.destroy();
        destroyed = true;
        try testing.expect(runUntil(&finalized, Finalization.done, 2000));
    }
}

test "only windows that show dialogs inside them keep one" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    adw.init();
    const plain = gtk.Window.new();
    defer plain.destroy();
    try testing.expect(!hostsDialogs(plain));
    const fixed = adw.Window.new();
    defer fixed.as(gtk.Window).destroy();
    fixed.as(gtk.Window).setResizable(0);
    try testing.expect(!hostsDialogs(fixed.as(gtk.Window)));
}

// Object data is destroyed at finalization, whereas a weak notification can
// already run during dispose. Never retain the object being observed. Remove
// the stack-backed observer on early test failure before its scope ends.
const Finalization = struct {
    const key = "gx-test-finalization";
    object: ?*gobject.Object = null,

    fn watch(self: *Finalization, object: *gobject.Object) void {
        self.object = object;
        object.setDataFull(key, self, &notify);
    }

    fn deinit(self: *Finalization) void {
        if (self.object) |object| _ = object.stealData(key);
    }

    fn done(self: *Finalization) bool {
        return self.object == null;
    }

    fn notify(data: ?*anyopaque) callconv(.c) void {
        const self: *Finalization = @ptrCast(@alignCast(data orelse return));
        self.object = null;
    }
};
