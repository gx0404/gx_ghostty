//! The model of the Ghostty GX keyboard shortcuts cheat sheet on GTK, on
//! top of `gx.shortcuts`: its rows grouped into sections, one per category
//! of the root key set and one per key table, and the title of each row.
//! Titles are English msgids for `gx.i18n`; `shortcuts_dialog.zig`
//! translates them and shows the keys as keycaps.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const gx = @import("../../../gx/main.zig");

const sheet = gx.shortcuts;
const Binding = input.Binding;

/// How many key sequences a row shows; the others fold into "+N".
pub const shown_sequences = 2;

pub const Section = struct {
    kind: union(enum) {
        category: sheet.Category,
        /// A key table (`<table>/<binding>` keybinds), by name.
        table: []const u8,
    },
    rows: []const sheet.Row,
};

/// The sections of `keybinds`: the categories of the root key set in
/// `gx.shortcuts` order, then one section per key table, by name. Sections
/// without rows are left out. Everything is allocated in `arena`.
pub fn sections(arena: Allocator, keybinds: *const configpkg.Config.Keybinds) Allocator.Error![]const Section {
    var result: std.ArrayList(Section) = .empty;

    const rows = try sheet.collect(arena, &keybinds.set);
    var start: usize = 0;
    while (start < rows.len) {
        var end = start + 1;
        while (end < rows.len and rows[end].category == rows[start].category) end += 1;
        try result.append(arena, .{ .kind = .{ .category = rows[start].category }, .rows = rows[start..end] });
        start = end;
    }

    const names = try arena.dupe([]const u8, keybinds.tables.keys());
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return sheet.naturalOrder(a, b) == .lt;
        }
    }.lessThan);
    for (names) |name| {
        const table = keybinds.tables.getPtr(name) orelse continue;
        const table_rows = try sheet.collect(arena, table);
        if (table_rows.len == 0) continue;
        try result.append(arena, .{ .kind = .{ .table = name }, .rows = table_rows });
    }
    return result.items;
}

pub const Title = struct {
    /// The msgid, or the title of a configured command palette entry as
    /// written.
    msgid: [:0]const u8,

    /// The argument of the action, when the title does not name it, such
    /// as the tab of `goto_tab:3`.
    argument: ?[]const u8 = null,
};

/// The title of `row`, named by its first action: `gx.shortcuts.title`
/// (configured command palette entries in `commands`, then the default
/// ones), with the Ghostty GX actions it does not name titled by
/// `gx.action.Action.title`. Null when there is none; the sheet then shows
/// the action itself.
pub fn title(arena: Allocator, row: sheet.Row, commands: []const input.Command) Allocator.Error!?Title {
    const action = row.actions[0];
    const found: sheet.Title = sheet.title(action, commands) orelse switch (action) {
        .gx => |gx_action| .{ .msgid = gx_action.title(), .exact = false },
        else => return null,
    };
    if (found.exact) return .{ .msgid = found.msgid };
    const formatted = try std.fmt.allocPrint(arena, "{f}", .{action});
    return .{ .msgid = found.msgid, .argument = sheet.argument(formatted) };
}

/// The title of a section as a msgid; key table sections fill `{name}`
/// with the table name.
pub fn sectionTitle(section: Section) [:0]const u8 {
    return switch (section.kind) {
        .category => |category| category.title(),
        .table => "Key Table: {name}",
    };
}

const testing = std.testing;

fn testKeybinds(alloc: Allocator, lines: []const []const u8) !configpkg.Config.Keybinds {
    var keybinds: configpkg.Config.Keybinds = .{};
    for (lines) |line| try keybinds.parseCLI(alloc, line);
    return keybinds;
}

test "sections group the root keys by category and list key tables after them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keybinds = try testKeybinds(alloc, &.{
        "clear",
        "ctrl+shift+c=copy_to_clipboard",
        "ctrl+tab=next_tab",
        "ctrl+shift+t=new_tab",
        "vim/j=scroll_page_lines:1",
        "vim/escape=deactivate_key_table",
        "a10/x=new_window",
        "a9/x=new_window",
        "empty/q=ignore",
    });
    const result = try sections(alloc, &keybinds);
    try testing.expectEqual(@as(usize, 5), result.len);

    try testing.expectEqual(sheet.Category.tabs, result[0].kind.category);
    try testing.expectEqual(@as(usize, 2), result[0].rows.len);
    try testing.expectEqualStrings("new_tab", result[0].rows[0].text);
    try testing.expectEqual(sheet.Category.clipboard, result[1].kind.category);

    try testing.expectEqualStrings("a9", result[2].kind.table);
    try testing.expectEqualStrings("a10", result[3].kind.table);
    try testing.expectEqualStrings("vim", result[4].kind.table);
    try testing.expectEqual(@as(usize, 2), result[4].rows.len);
    try testing.expectEqualStrings("Key Table: {name}", sectionTitle(result[4]));
    try testing.expectEqualStrings("Tabs", sectionTitle(result[0]));
}

test "title names Ghostty GX actions and keeps arguments the title does not name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keybinds = try testKeybinds(alloc, &.{
        "clear",
        "ctrl+shift+m=gx:main_menu",
        "ctrl+alt+f=gx:settings_page:font",
        "ctrl+alt+t=gx:tab_switcher",
        "alt+3=goto_tab:3",
        "ctrl+shift+o=new_split:right",
        "ctrl+shift+e=end_key_sequence",
    });
    const rows = try sheet.collect(alloc, &keybinds.set);

    var by_text: std.StringHashMapUnmanaged(?Title) = .empty;
    for (rows) |row| try by_text.put(alloc, row.text, try title(alloc, row, &.{}));

    const menu = by_text.get("gx:main_menu").?.?;
    try testing.expectEqualStrings("Main Menu", menu.msgid);
    try testing.expectEqual(@as(?[]const u8, null), menu.argument);

    const font = by_text.get("gx:settings_page:font").?.?;
    try testing.expectEqualStrings("Settings Page", font.msgid);
    try testing.expectEqualStrings("font", font.argument.?);

    try testing.expectEqualStrings("Tab Switcher", by_text.get("gx:tab_switcher").?.?.msgid);

    const goto = by_text.get("goto_tab:3").?.?;
    try testing.expectEqualStrings("Go to Tab", goto.msgid);
    try testing.expectEqualStrings("3", goto.argument.?);

    const split = by_text.get("new_split:right").?.?;
    try testing.expectEqualStrings("Split Right", split.msgid);
    try testing.expectEqual(@as(?[]const u8, null), split.argument);

    try testing.expectEqual(@as(?Title, null), by_text.get("end_key_sequence").?);

    const configured = [_]input.Command{.{ .title = "Fonts", .action = .{ .gx = .{ .settings_page = .font } } }};
    const row = for (rows) |candidate| {
        if (std.mem.eql(u8, candidate.text, "gx:settings_page:font")) break candidate;
    } else return error.TestUnexpectedResult;
    const named = (try title(alloc, row, &configured)).?;
    try testing.expectEqualStrings("Fonts", named.msgid);
    try testing.expectEqual(@as(?[]const u8, null), named.argument);
}

test "every Ghostty GX title and section title is translated" {
    inline for (@typeInfo(gx.action.Action).@"union".fields) |field| {
        const action = @unionInit(gx.action.Action, field.name, switch (field.type) {
            void => {},
            []const u8 => "x",
            else => std.enums.values(field.type)[0],
        });
        try testing.expect(gx.i18n.lookup(.zh_CN, action.title()) != null);
    }
    for (std.enums.values(sheet.Category)) |category| {
        try testing.expect(gx.i18n.lookup(.zh_CN, category.title()) != null);
    }
    try testing.expect(gx.i18n.lookup(.zh_CN, sectionTitle(.{ .kind = .{ .table = "x" }, .rows = &.{} })) != null);
}
