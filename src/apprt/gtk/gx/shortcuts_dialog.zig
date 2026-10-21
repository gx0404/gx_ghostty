//! The Ghostty GX keyboard shortcuts cheat sheet: an `Adw.Dialog` that
//! lists the keybindings of the configuration by category and key table
//! (`shortcuts.zig`). Each action shows up to two key sequences as keycaps,
//! modifiers in the `gx.shortcuts` order, and folds the others into "+N".
//! The search field filters by title, with pinyin initials, and by keys
//! (`gx.shortcuts.Search`); Escape clears it, or closes the sheet when it
//! is empty. Built in code, in the current UI language, each time it opens.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");
const keycaps = @import("keycaps.zig");
const shortcuts = @import("shortcuts.zig");

const sheet = gx.shortcuts;
const Trigger = input.Binding.Trigger;

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

/// What the search needs; freed with the search entry.
const State = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    dialog: *adw.Dialog = undefined,
    page: *adw.PreferencesPage = undefined,
    stack: *gtk.Stack = undefined,
    groups: std.ArrayList(*gtk.Widget) = .empty,
    group_visible: []bool = &.{},
    rows: std.ArrayList(Row) = .empty,

    const Row = struct {
        widget: *gtk.Widget,
        group: usize,

        /// The title in the UI language and in English, and the actions
        /// in configuration syntax.
        titles: [3][]const u8,
        sequences: []const []const Trigger,
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
    const commands = config.@"command-palette-entry".value.items;
    const all = try shortcuts.sections(arena, &config.keybind);

    const page = adw.PreferencesPage.new();
    for (all) |section| {
        const group = adw.PreferencesGroup.new();
        group.setTitle(try sectionTitle(arena, section));
        page.add(group);
        try state.groups.append(arena, group.as(gtk.Widget));
        for (section.rows) |row| {
            const built = try buildRow(arena, row, commands);
            group.add(built.widget);
            try state.rows.append(arena, .{
                .widget = built.widget,
                .group = state.groups.items.len - 1,
                .titles = built.titles,
                .sequences = row.sequences,
            });
        }
    }
    state.group_visible = try arena.alloc(bool, state.groups.items.len);
    state.page = page;

    const empty = adw.StatusPage.new();
    empty.setIconName("edit-find-symbolic");
    empty.setTitle(tr("No results"));

    const stack = gtk.Stack.new();
    _ = stack.addNamed(page.as(gtk.Widget), "list");
    _ = stack.addNamed(empty.as(gtk.Widget), "empty");
    stack.setVisibleChildName(if (state.rows.items.len > 0) "list" else "empty");
    state.stack = stack;

    // The clamp lines the search field up with the groups, which the
    // preferences page clamps the same way.
    const search = gtk.SearchEntry.new();
    search.setPlaceholderText(tr("Search keyboard shortcuts…"));
    search.as(gtk.Widget).setHexpand(1);
    search.as(gtk.Widget).setMarginStart(12);
    search.as(gtk.Widget).setMarginEnd(12);
    search.as(gtk.Widget).setMarginBottom(6);
    const search_clamp = adw.Clamp.new();
    search_clamp.setChild(search.as(gtk.Widget));

    const header = adw.HeaderBar.new();
    header.setTitleWidget(adw.WindowTitle.new(tr("Keyboard Shortcuts"), "").as(gtk.Widget));
    const edit_button = gtk.Button.newWithLabel(tr("Edit Keyboard Shortcuts"));
    edit_button.as(gtk.Actionable).setActionName("app.gx-shortcut-editor");
    header.packEnd(edit_button.as(gtk.Widget));

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    toolbar.addTopBar(search_clamp.as(gtk.Widget));
    toolbar.setContent(stack.as(gtk.Widget));

    const dialog = adw.Dialog.new();
    dialog.setTitle(tr("Keyboard Shortcuts"));
    dialog.setContentWidth(680);
    dialog.setContentHeight(560);
    dialog.setChild(toolbar.as(gtk.Widget));
    dialog.as(gtk.Widget).addCssClass("gx-dialog");
    state.dialog = dialog;

    _ = gtk.SearchEntry.signals.search_changed.connect(
        search,
        *State,
        searchChanged,
        state,
        .{ .destroyData = State.destroyData },
    );
    _ = gtk.SearchEntry.signals.stop_search.connect(search, *State, stopSearch, state, .{});
    search.setKeyCaptureWidget(dialog.as(gtk.Widget));

    dialog.present(parent);
    _ = search.as(gtk.Widget).grabFocus();
}

fn sectionTitle(arena: Allocator, section: shortcuts.Section) Allocator.Error![:0]const u8 {
    const msgid = shortcuts.sectionTitle(section);
    return switch (section.kind) {
        .category => trRuntime(msgid),
        .table => |name| try fillZ(arena, trRuntime(msgid), .{ .name = name }),
    };
}

const BuiltRow = struct {
    widget: *gtk.Widget,
    titles: [3][]const u8,
};

fn buildRow(arena: Allocator, row: sheet.Row, commands: []const input.Command) Allocator.Error!BuiltRow {
    const text = try arena.dupeZ(u8, row.text);
    var titles: [3][]const u8 = .{ "", "", text };

    const widget = adw.ActionRow.new();
    widget.as(adw.PreferencesRow).setUseMarkup(0);
    if (try shortcuts.title(arena, row, commands)) |found| {
        const translated = try titleText(arena, trRuntime(found.msgid), tr("{title}: {argument}"), found.argument);
        titles[0] = translated;
        titles[1] = try titleText(arena, found.msgid, "{title}: {argument}", found.argument);
        widget.as(adw.PreferencesRow).setTitle(translated);
        widget.setSubtitle(text);
    } else {
        widget.as(adw.PreferencesRow).setTitle(text);
    }
    widget.addSuffix(try keycaps.keys(arena, row.sequences));
    return .{ .widget = widget.as(gtk.Widget), .titles = titles };
}

fn titleText(
    arena: Allocator,
    title: [:0]const u8,
    template: []const u8,
    argument: ?[]const u8,
) Allocator.Error![:0]const u8 {
    const arg = argument orelse return title;
    return try fillZ(arena, template, .{ .title = title, .argument = arg });
}

/// `gx.i18n.format` into a new string for GTK.
fn fillZ(arena: Allocator, template: []const u8, args: anytype) Allocator.Error![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    gx.i18n.format(&out.writer, template, args) catch return error.OutOfMemory;
    return try out.toOwnedSliceSentinel(0);
}

fn searchChanged(entry: *gtk.SearchEntry, state: *State) callconv(.c) void {
    const search: sheet.Search = .init(std.mem.span(entry.as(gtk.Editable).getText()));
    @memset(state.group_visible, false);
    var visible_rows: usize = 0;
    for (state.rows.items) |row| {
        const visible = search.score(&row.titles, row.sequences) != null;
        row.widget.setVisible(@intFromBool(visible));
        if (visible) {
            visible_rows += 1;
            state.group_visible[row.group] = true;
        }
    }
    for (state.groups.items, state.group_visible) |group, visible| group.setVisible(@intFromBool(visible));
    state.stack.setVisibleChildName(if (visible_rows > 0) "list" else "empty");
    state.page.scrollToTop();
}

/// Escape clears the search, or closes the sheet when there is nothing to
/// clear.
fn stopSearch(entry: *gtk.SearchEntry, state: *State) callconv(.c) void {
    const editable = entry.as(gtk.Editable);
    if (std.mem.span(editable.getText()).len > 0) {
        editable.setText("");
        return;
    }
    _ = state.dialog.close();
}
