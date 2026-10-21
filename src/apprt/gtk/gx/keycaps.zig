//! Keycaps for the Ghostty GX keyboard shortcut dialogs: the cheat sheet
//! (`shortcuts_dialog.zig`) and the shortcut editor (`shortcut_editor.zig`).
//! A key combination is a `Keycaps` box of `.keycap` labels joined by dim
//! `+` signs, modifiers in the `gx.shortcuts` order; a key sequence joins
//! its steps with `›`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const Common = @import("../class.zig").Common;

const sheet = gx.shortcuts;
const Trigger = input.Binding.Trigger;

/// How many key sequences `keys` shows; the others fold into "+N".
pub const shown_sequences = @import("shortcuts.zig").shown_sequences;

/// The first key sequences of a row side by side, then "+N" for the
/// others, which its tooltip lists.
pub fn keys(arena: Allocator, sequences: []const []const Trigger) Allocator.Error!*gtk.Widget {
    const box = gtk.Box.new(.horizontal, 12);
    box.as(gtk.Widget).setValign(.center);
    const shown = @min(sequences.len, shown_sequences);
    for (sequences[0..shown], 0..) |steps, i| {
        if (i > 0) box.append(dimLabel("/"));
        box.append(try sequence(arena, steps));
    }
    if (sequences.len > shown) {
        const more = dimLabel(try arena.printSentinel("+{d}", .{sequences.len - shown}, 0));
        more.setTooltipText(try sequencesText(arena, sequences[shown..]));
        box.append(more);
    }
    return box.as(gtk.Widget);
}

/// A key sequence: the keycaps of each step, leader keys first.
pub fn sequence(arena: Allocator, steps: []const Trigger) Allocator.Error!*gtk.Widget {
    if (steps.len == 1) return try chord(arena, steps[0]);
    const box = gtk.Box.new(.horizontal, 6);
    box.as(gtk.Widget).setValign(.center);
    for (steps, 0..) |trigger, i| {
        if (i > 0) box.append(dimLabel("›"));
        box.append(try chord(arena, trigger));
    }
    return box.as(gtk.Widget);
}

/// The keycaps of one key combination.
pub fn chord(arena: Allocator, trigger: Trigger) Allocator.Error!*gtk.Widget {
    const caps: sheet.Keycaps = .init(trigger, .gtk);
    var labels: [5][]const u8 = undefined;
    for (0..caps.count()) |i| labels[i] = caps.get(i);
    return try fromLabels(arena, labels[0..caps.count()], false);
}

/// Keycaps with the given labels; `pending` adds a dim "…" keycap for a key
/// still to come, as while a shortcut is being recorded.
pub fn fromLabels(arena: Allocator, labels: []const []const u8, pending: bool) Allocator.Error!*gtk.Widget {
    const keycaps = gobject.ext.newInstance(Keycaps, .{});
    const box = keycaps.as(gtk.Box);
    box.setSpacing(6);
    box.as(gtk.Widget).setValign(.center);
    for (labels, 0..) |text, i| {
        if (i > 0) box.append(dimLabel("+"));
        const label = gtk.Label.new(try arena.dupeSentinel(u8, text, 0));
        label.as(gtk.Widget).addCssClass("keycap");
        box.append(label.as(gtk.Widget));
    }
    if (pending) {
        if (labels.len > 0) box.append(dimLabel("+"));
        const label = gtk.Label.new("…");
        label.as(gtk.Widget).addCssClass("keycap");
        label.as(gtk.Widget).addCssClass("dim-label");
        box.append(label.as(gtk.Widget));
    }
    return keycaps.as(gtk.Widget);
}

/// The key sequences one per line, steps joined by ` › `.
pub fn sequencesText(arena: Allocator, sequences: []const []const Trigger) Allocator.Error![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (sequences, 0..) |steps, i| {
        if (i > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
        sheet.writeSequence(&out.writer, steps, .gtk, " › ") catch return error.OutOfMemory;
    }
    return try out.toOwnedSliceSentinel(0);
}

pub fn dimLabel(text: [:0]const u8) *gtk.Widget {
    const label = gtk.Label.new(text);
    label.as(gtk.Widget).addCssClass("dim-label");
    return label.as(gtk.Widget);
}

/// The keycaps of one key combination. Its CSS name is `shortcut`, so
/// libadwaita styles the `.keycap` labels as in a `Gtk.ShortcutLabel`,
/// whose modifier order would differ from `gx.shortcuts`.
pub const Keycaps = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyGxKeycaps",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    const C = Common(Self, null);
    pub const as = C.as;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "shortcut");
        }

        pub const as = C.Class.as;
    };
};

test "keycap builders compile against GTK" {
    try std.testing.expect(@intFromPtr(&keys) != 0);
    try std.testing.expect(@intFromPtr(&fromLabels) != 0);
}
