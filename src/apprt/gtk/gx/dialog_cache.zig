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
fn runUntil(comptime done: fn (*adw.Dialog) bool, dialog: *adw.Dialog, ms: u32) bool {
    // Wakes the loop up so that the deadline is checked.
    const tick = glib.timeoutAdd(5, &keepTicking, null);
    defer _ = glib.Source.remove(tick);
    var waited: u32 = 0;
    while (!done(dialog)) {
        if (waited >= ms) return false;
        _ = glib.MainContext.iteration(null, 1);
        waited += 5;
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

    var dialog_gone = false;
    const first = adw.Dialog.new();
    first.as(gobject.Object).weakRef(&markGone, &dialog_gone);
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
        try testing.expect(runUntil(shown, dialog, 2000));
        const count = widgetCount(window.as(gtk.Widget));
        if (shown_count) |expected| try testing.expectEqual(expected, count) else shown_count = count;
        try testing.expect(dialog.close() != 0);
        try testing.expect(runUntil(removed, dialog, 2000));
        const after = widgetCount(window.as(gtk.Widget));
        if (closed_count) |expected| try testing.expectEqual(expected, after) else closed_count = after;
        try testing.expect(after < shown_count.?);
        try testing.expectEqual(toplevels, gtk.Window.getToplevels().getNItems());
    }
    try testing.expect(!dialog_gone);

    // Dropped (out of date), the hidden dialog goes, and the next opening
    // builds a new one.
    TestCache.drop(gtk_window);
    try testing.expect(dialog_gone);
    try testing.expect(TestCache.get(gtk_window) == null);
}

test "destroying its window releases the kept dialog" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    adw.init();
    const window = adw.Window.new();
    const gtk_window = window.as(gtk.Window);
    var dialog_gone = false;
    const dialog = adw.Dialog.new();
    dialog.as(gobject.Object).weakRef(&markGone, &dialog_gone);
    TestCache.keep(gtk_window, dialog);
    // Keeping another one releases the first.
    var second_gone = false;
    const second = adw.Dialog.new();
    second.as(gobject.Object).weakRef(&markGone, &second_gone);
    TestCache.keep(gtk_window, second);
    try testing.expect(dialog_gone);
    try testing.expect(!second_gone);
    gtk_window.destroy();
    try testing.expect(second_gone);
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

fn markGone(data: ?*anyopaque, _: *gobject.Object) callconv(.c) void {
    const gone: *bool = @ptrCast(@alignCast(data orelse return));
    gone.* = true;
}
