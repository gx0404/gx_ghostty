//! The Ghostty GX keyboard shortcuts cheat sheet: an `Adw.Dialog` that
//! lists the keybindings of the configuration by category (see
//! `shortcuts.zig`) with a search field. Built in code, in the current UI
//! language, each time it is opened.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const glib = @import("glib");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const key = @import("../key.zig");
const shortcuts = @import("shortcuts.zig");

const log = std.log.scoped(.gtk_gx_shortcuts);
const tr = gx.i18n.tr;
const trRuntime = gx.i18n.trRuntime;

/// Shows the cheat sheet for the keybindings of `config` over `parent`.
pub fn present(alloc: Allocator, config: *const configpkg.Config, parent: *gtk.Widget) void {
    const state = alloc.create(State) catch return;
    state.* = .{ .alloc = alloc, .arena = .init(alloc) };
    build(state, config, parent) catch |err| {
        log.warn("cannot build the keyboard shortcuts dialog err={}", .{err});
        state.destroy();
    };
}

/// What the search filter needs; freed with the search entry.
const State = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    groups: std.ArrayList(*gtk.Widget) = .empty,
    rows: std.ArrayList(Row) = .empty,
    page: *gtk.Widget = undefined,
    empty: *gtk.Widget = undefined,

    const Row = struct {
        widget: *gtk.Widget,
        group: usize,

        /// Everything the row matches, lowercased.
        haystack: []const u8,
    };

    fn destroy(self: *State) void {
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    fn destroyData(self: *State) callconv(.c) void {
        self.destroy();
    }
};

fn build(state: *State, config: *const configpkg.Config, parent: *gtk.Widget) Allocator.Error!void {
    const arena = state.arena.allocator();
    const rows = try shortcuts.collect(arena, &config.keybind.set);

    const page = adw.PreferencesPage.new();
    var current: ?shortcuts.Category = null;
    var group: *adw.PreferencesGroup = undefined;
    for (rows) |row| {
        if (current != row.category) {
            current = row.category;
            group = adw.PreferencesGroup.new();
            group.setTitle(trRuntime(row.category.title()));
            page.add(group);
            try state.groups.append(arena, group.as(gtk.Widget));
        }
        const widget = try buildRow(arena, row);
        group.add(widget.widget);
        try state.rows.append(arena, .{
            .widget = widget.widget,
            .group = state.groups.items.len - 1,
            .haystack = widget.haystack,
        });
    }

    const empty = gtk.Label.new(tr("No results"));
    empty.as(gtk.Widget).addCssClass("dim-label");
    empty.as(gtk.Widget).setVexpand(1);
    empty.as(gtk.Widget).setVisible(@intFromBool(rows.len == 0));
    state.page = page.as(gtk.Widget);
    state.empty = empty.as(gtk.Widget);

    const content = gtk.Box.new(.vertical, 0);
    page.as(gtk.Widget).setVexpand(1);
    page.as(gtk.Widget).setVisible(@intFromBool(rows.len > 0));
    content.append(page.as(gtk.Widget));
    content.append(empty.as(gtk.Widget));

    const search = gtk.SearchEntry.new();
    search.setPlaceholderText(tr("Search keyboard shortcuts…"));
    search.as(gtk.Widget).setHexpand(1);
    search.as(gtk.Widget).setMarginStart(12);
    search.as(gtk.Widget).setMarginEnd(12);
    search.as(gtk.Widget).setMarginBottom(6);
    _ = gtk.SearchEntry.signals.search_changed.connect(
        search,
        *State,
        searchChanged,
        state,
        .{ .destroyData = State.destroyData },
    );

    const header = adw.HeaderBar.new();
    header.setTitleWidget(adw.WindowTitle.new(tr("Keyboard Shortcuts"), "").as(gtk.Widget));

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    toolbar.addTopBar(search.as(gtk.Widget));
    toolbar.setContent(content.as(gtk.Widget));

    const dialog = adw.Dialog.new();
    dialog.setTitle(tr("Keyboard Shortcuts"));
    dialog.setContentWidth(640);
    dialog.setContentHeight(560);
    dialog.setChild(toolbar.as(gtk.Widget));
    search.setKeyCaptureWidget(dialog.as(gtk.Widget));
    dialog.present(parent);
    _ = search.as(gtk.Widget).grabFocus();
}

const BuiltRow = struct {
    widget: *gtk.Widget,
    haystack: []const u8,
};

fn buildRow(arena: Allocator, row: shortcuts.Row) Allocator.Error!BuiltRow {
    var haystack: std.Io.Writer.Allocating = .init(arena);
    const hay = &haystack.writer;

    var formatted: std.Io.Writer.Allocating = .init(arena);
    for (row.actions, 0..) |action, i| {
        if (i > 0) formatted.writer.writeAll(", ") catch return error.OutOfMemory;
        formatted.writer.print("{f}", .{action}) catch return error.OutOfMemory;
    }
    const actions_text = try formatted.toOwnedSliceSentinel(0);

    const widget = adw.ActionRow.new();
    widget.as(adw.PreferencesRow).setUseMarkup(0);
    const msgid = shortcuts.title(row.actions[0], actions_text);
    if (msgid) |id| {
        const title = trRuntime(id);
        widget.as(adw.PreferencesRow).setTitle(title);
        widget.setSubtitle(actions_text);
        hay.print("{s}\n", .{title}) catch return error.OutOfMemory;
    } else {
        widget.as(adw.PreferencesRow).setTitle(actions_text);
    }
    hay.print("{s}\n{s}\n", .{ actions_text, trRuntime(row.category.title()) }) catch
        return error.OutOfMemory;

    const keys = gtk.Box.new(.vertical, 4);
    keys.as(gtk.Widget).setValign(.center);
    for (row.sequences.items) |sequence| {
        keys.append(try buildSequence(arena, sequence, hay));
    }
    widget.addSuffix(keys.as(gtk.Widget));

    const text = haystack.written();
    for (text) |*ch| ch.* = std.ascii.toLower(ch.*);
    return .{ .widget = widget.as(gtk.Widget), .haystack = text };
}

/// One key sequence: the keys as keycaps, leader keys first.
fn buildSequence(
    arena: Allocator,
    sequence: []const input.Binding.Trigger,
    hay: *std.Io.Writer,
) Allocator.Error!*gtk.Widget {
    const box = gtk.Box.new(.horizontal, 6);
    box.as(gtk.Widget).setHalign(.end);
    for (sequence, 0..) |trigger, i| {
        if (i > 0) {
            const next = gtk.Label.new("›");
            next.as(gtk.Widget).addCssClass("dim-label");
            box.append(next.as(gtk.Widget));
        }

        var label_buf: [128]u8 = undefined;
        var label_writer: std.Io.Writer = .fixed(&label_buf);
        const has_label = key.labelFromTrigger(&label_writer, trigger) catch false;
        const label = if (has_label) label_writer.buffered() else "?";
        hay.print("{s} ", .{label}) catch return error.OutOfMemory;

        var accel_buf: [128]u8 = undefined;
        const accel = key.accelFromTrigger(&accel_buf, trigger) catch null;
        if (accel) |value| {
            box.append(gtk.ShortcutLabel.new(value).as(gtk.Widget));
        } else {
            const text = try arena.dupeZ(u8, label);
            const fallback = gtk.Label.new(text);
            fallback.as(gtk.Widget).addCssClass("monospace");
            box.append(fallback.as(gtk.Widget));
        }
    }
    hay.writeByte('\n') catch return error.OutOfMemory;
    return box.as(gtk.Widget);
}

fn searchChanged(entry: *gtk.SearchEntry, state: *State) callconv(.c) void {
    var needle_buf: [256]u8 = undefined;
    const text = std.mem.span(entry.as(gtk.Editable).getText());
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    const needle = std.ascii.lowerString(&needle_buf, trimmed[0..@min(trimmed.len, needle_buf.len)]);

    var visible_rows: usize = 0;
    var group_visible = [_]bool{false} ** @typeInfo(shortcuts.Category).@"enum".fields.len;
    for (state.rows.items) |row| {
        const visible = needle.len == 0 or std.mem.indexOf(u8, row.haystack, needle) != null;
        row.widget.setVisible(@intFromBool(visible));
        if (visible) {
            visible_rows += 1;
            group_visible[row.group] = true;
        }
    }
    for (state.groups.items, 0..) |group, i| group.setVisible(@intFromBool(group_visible[i]));
    state.page.setVisible(@intFromBool(visible_rows > 0));
    state.empty.setVisible(@intFromBool(visible_rows == 0));
}
