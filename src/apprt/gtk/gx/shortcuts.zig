//! The model of the Ghostty GX keyboard shortcuts cheat sheet: the
//! keybindings of a configuration grouped by category, one row per action
//! with every key sequence that runs it. Titles are English msgids for
//! `gx.i18n`; the dialog in `shortcuts_dialog.zig` translates them.
const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../../input.zig");
const Binding = input.Binding;

pub const Category = enum {
    tabs,
    splits,
    windows,
    clipboard,
    font,
    scrolling,
    search,
    terminal,
    application,
    other,

    /// The msgid of the category title.
    pub fn title(self: Category) [:0]const u8 {
        return switch (self) {
            .tabs => "Tabs",
            .splits => "Splits",
            .windows => "Windows",
            .clipboard => "Clipboard and Selection",
            .font => "Font Size",
            .scrolling => "Scrolling",
            .search => "Search",
            .terminal => "Terminal",
            .application => "Application",
            .other => "Other",
        };
    }
};

pub const Row = struct {
    category: Category,

    /// The actions run, in order; more than one for chained bindings.
    actions: []const Binding.Action,

    /// The key sequences that run the actions, leader keys first.
    sequences: std.ArrayList([]const Binding.Trigger) = .empty,
};

/// The rows for the bindings of `set`, ordered by category and then by
/// the first binding of each action. `ignore` bindings and catch-all keys
/// are left out. The rows borrow actions from `set` and allocate in
/// `arena`.
pub fn collect(arena: Allocator, set: *const Binding.Set) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    try walk(arena, &rows, set, &.{});
    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return @intFromEnum(a.category) < @intFromEnum(b.category);
        }
    }.lessThan);
    return rows.items;
}

fn walk(
    arena: Allocator,
    rows: *std.ArrayList(Row),
    set: *const Binding.Set,
    prefix: []const Binding.Trigger,
) Allocator.Error!void {
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const trigger = entry.key_ptr.*;
        if (trigger.key == .catch_all) continue;
        const sequence = try std.mem.concat(arena, Binding.Trigger, &.{ prefix, &.{trigger} });
        switch (entry.value_ptr.*) {
            .leader => |next| try walk(arena, rows, next, sequence),
            .leaf => |*leaf| try add(arena, rows, (&leaf.action)[0..1], sequence),
            .leaf_chained => |chained| try add(arena, rows, chained.actions.items, sequence),
        }
    }
}

fn add(
    arena: Allocator,
    rows: *std.ArrayList(Row),
    actions: []const Binding.Action,
    sequence: []const Binding.Trigger,
) Allocator.Error!void {
    if (actions.len == 0) return;
    switch (actions[0]) {
        .ignore, .unbind => return,
        else => {},
    }
    for (rows.items) |*row| {
        if (sameActions(row.actions, actions)) {
            try row.sequences.append(arena, sequence);
            return;
        }
    }
    var row: Row = .{
        .category = category(actions[0]),
        .actions = try arena.dupe(Binding.Action, actions),
    };
    try row.sequences.append(arena, sequence);
    try rows.append(arena, row);
}

fn sameActions(a: []const Binding.Action, b: []const Binding.Action) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.equal(y)) return false;
    return true;
}

/// The category of an action, by its tag name so that actions added later
/// fall into `other` instead of breaking the build.
pub fn category(action: Binding.Action) Category {
    return categories.get(@tagName(std.meta.activeTag(action))) orelse .other;
}

const categories: std.StaticStringMap(Category) = .initComptime(.{
    .{ "new_tab", .tabs },
    .{ "previous_tab", .tabs },
    .{ "next_tab", .tabs },
    .{ "last_tab", .tabs },
    .{ "goto_tab", .tabs },
    .{ "move_tab", .tabs },
    .{ "move_tab_to_new_window", .tabs },
    .{ "toggle_tab_overview", .tabs },
    .{ "close_tab", .tabs },
    .{ "prompt_tab_title", .tabs },
    .{ "set_tab_title", .tabs },
    .{ "new_split", .splits },
    .{ "goto_split", .splits },
    .{ "toggle_split_zoom", .splits },
    .{ "resize_split", .splits },
    .{ "equalize_splits", .splits },
    .{ "close_surface", .splits },
    .{ "prompt_surface_title", .splits },
    .{ "set_surface_title", .splits },
    .{ "new_window", .windows },
    .{ "goto_window", .windows },
    .{ "close_window", .windows },
    .{ "close_all_windows", .windows },
    .{ "toggle_maximize", .windows },
    .{ "toggle_fullscreen", .windows },
    .{ "toggle_window_decorations", .windows },
    .{ "toggle_window_float_on_top", .windows },
    .{ "toggle_background_opacity", .windows },
    .{ "toggle_visibility", .windows },
    .{ "toggle_quick_terminal", .windows },
    .{ "reset_window_size", .windows },
    .{ "prompt_window_title", .windows },
    .{ "set_window_title", .windows },
    .{ "copy_to_clipboard", .clipboard },
    .{ "paste_from_clipboard", .clipboard },
    .{ "paste_from_selection", .clipboard },
    .{ "copy_url_to_clipboard", .clipboard },
    .{ "copy_title_to_clipboard", .clipboard },
    .{ "select_all", .clipboard },
    .{ "adjust_selection", .clipboard },
    .{ "write_screen_file", .clipboard },
    .{ "write_selection_file", .clipboard },
    .{ "write_scrollback_file", .clipboard },
    .{ "increase_font_size", .font },
    .{ "decrease_font_size", .font },
    .{ "reset_font_size", .font },
    .{ "set_font_size", .font },
    .{ "scroll_to_top", .scrolling },
    .{ "scroll_to_bottom", .scrolling },
    .{ "scroll_to_selection", .scrolling },
    .{ "scroll_to_row", .scrolling },
    .{ "scroll_page_up", .scrolling },
    .{ "scroll_page_down", .scrolling },
    .{ "scroll_page_fractional", .scrolling },
    .{ "scroll_page_lines", .scrolling },
    .{ "jump_to_prompt", .scrolling },
    .{ "search", .search },
    .{ "search_selection", .search },
    .{ "navigate_search", .search },
    .{ "start_search", .search },
    .{ "end_search", .search },
    .{ "reset", .terminal },
    .{ "clear_screen", .terminal },
    .{ "text", .terminal },
    .{ "csi", .terminal },
    .{ "esc", .terminal },
    .{ "cursor_key", .terminal },
    .{ "toggle_readonly", .terminal },
    .{ "toggle_mouse_reporting", .terminal },
    .{ "toggle_secure_input", .terminal },
    .{ "show_on_screen_keyboard", .terminal },
    .{ "undo", .terminal },
    .{ "redo", .terminal },
    .{ "open_config", .application },
    .{ "reload_config", .application },
    .{ "quit", .application },
    .{ "toggle_command_palette", .application },
    .{ "inspector", .application },
    .{ "show_gtk_inspector", .application },
    .{ "check_for_updates", .application },
    .{ "gx", .application },
});

/// The msgid of the title of an action: the title of its default command
/// palette entry, else of the only palette entry with the same action
/// name, else a Ghostty GX title. Null when there is none; callers then
/// show the action itself. `formatted` is the action in configuration
/// syntax (`Action.format`), used for the Ghostty GX `gx:` actions.
pub fn title(action: Binding.Action, formatted: []const u8) ?[:0]const u8 {
    for (input.command.defaults) |cmd| {
        if (cmd.action.equal(action)) return cmd.title;
    }

    const tag = std.meta.activeTag(action);
    var same_name: ?[:0]const u8 = null;
    var count: usize = 0;
    for (input.command.defaults) |cmd| {
        if (std.meta.activeTag(cmd.action) != tag) continue;
        same_name = cmd.title;
        count += 1;
    }
    if (count == 1) return same_name;

    if (std.mem.eql(u8, @tagName(tag), "gx")) return gxTitle(formatted);
    return fallback_titles.get(@tagName(tag));
}

const fallback_titles: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "previous_tab", "Previous Tab" },
    .{ "next_tab", "Next Tab" },
    .{ "last_tab", "Last Tab" },
    .{ "goto_tab", "Go to Tab" },
    .{ "new_split", "New Split" },
    .{ "resize_split", "Resize Split" },
    .{ "adjust_selection", "Adjust Selection" },
    .{ "jump_to_prompt", "Jump to Prompt" },
    .{ "scroll_page_lines", "Scroll Lines" },
    .{ "toggle_command_palette", "Command Palette" },
    .{ "toggle_quick_terminal", "Quick Terminal" },
    .{ "write_screen_file", "Write Screen to File" },
    .{ "write_selection_file", "Write Selection to File" },
    .{ "write_scrollback_file", "Write Scrollback to File" },
    .{ "text", "Send Text" },
    .{ "csi", "Send Control Sequence" },
    .{ "esc", "Send Escape Sequence" },
});

/// Titles for the Ghostty GX binding actions (`gx:<name>[:<arg>]`).
fn gxTitle(formatted: []const u8) ?[:0]const u8 {
    const titles = [_]struct { []const u8, [:0]const u8 }{
        .{ "gx:settings", "Settings…" },
        .{ "gx:main_menu", "Main Menu" },
        .{ "gx:keybinds", "Keyboard Shortcuts" },
        .{ "gx:new_tab_profile", "New Tab with Profile" },
        .{ "gx:new_window_profile", "New Window with Profile" },
    };
    for (titles) |entry| {
        if (!std.mem.startsWith(u8, formatted, entry[0])) continue;
        const rest = formatted[entry[0].len..];
        if (rest.len == 0 or rest[0] == ':') return entry[1];
    }
    return null;
}

fn testSet(alloc: Allocator, lines: []const []const u8) !Binding.Set {
    var set: Binding.Set = .{};
    errdefer set.deinit(alloc);
    for (lines) |line| try set.parseAndPut(alloc, line);
    return set;
}

test "collect groups triggers per action and orders rows by category" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const set = try testSet(alloc, &.{
        "ctrl+shift+c=copy_to_clipboard",
        "ctrl+tab=next_tab",
        "ctrl+page_down=next_tab",
        "ctrl+a>n=new_tab",
        "ctrl+shift+x=ignore",
        "ctrl+shift+o=new_split:right",
    });

    const rows = try collect(alloc, &set);
    try testing.expectEqual(@as(usize, 4), rows.len);

    try testing.expectEqual(Category.tabs, rows[0].category);
    try testing.expect(rows[0].actions[0] == .next_tab);
    try testing.expectEqual(@as(usize, 2), rows[0].sequences.items.len);

    try testing.expectEqual(Category.tabs, rows[1].category);
    try testing.expect(rows[1].actions[0] == .new_tab);
    const sequence = rows[1].sequences.items[0];
    try testing.expectEqual(@as(usize, 2), sequence.len);
    try testing.expect(sequence[0].mods.ctrl);
    try testing.expect(!sequence[1].mods.ctrl);

    try testing.expectEqual(Category.splits, rows[2].category);
    try testing.expectEqual(Category.clipboard, rows[3].category);
}

test "category falls back to other" {
    const testing = std.testing;
    try testing.expectEqual(Category.tabs, category(.new_tab));
    try testing.expectEqual(Category.splits, category(.{ .new_split = .right }));
    try testing.expectEqual(Category.application, category(.reload_config));
    try testing.expectEqual(Category.other, category(.end_key_sequence));
}

test "title prefers the command palette titles" {
    const testing = std.testing;
    try testing.expectEqualStrings("Split Right", title(.{ .new_split = .right }, "new_split:right").?);
    try testing.expectEqualStrings("Increase Font Size", title(.{ .increase_font_size = 3 }, "increase_font_size:3").?);
    try testing.expectEqualStrings("Next Tab", title(.next_tab, "next_tab").?);
    try testing.expectEqualStrings("Go to Tab", title(.{ .goto_tab = 3 }, "goto_tab:3").?);
    try testing.expectEqualStrings("New Split", title(.{ .new_split = .auto }, "new_split:auto").?);
    try testing.expectEqual(@as(?[:0]const u8, null), title(.end_key_sequence, "end_key_sequence"));
}

test "gxTitle names the Ghostty GX actions" {
    const testing = std.testing;
    try testing.expectEqualStrings("Settings…", gxTitle("gx:settings").?);
    try testing.expectEqualStrings("New Tab with Profile", gxTitle("gx:new_tab_profile:gx-zsh").?);
    try testing.expectEqual(@as(?[:0]const u8, null), gxTitle("gx:settingsx"));
    try testing.expectEqual(@as(?[:0]const u8, null), gxTitle("gx:unknown"));
}
