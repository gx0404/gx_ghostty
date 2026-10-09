//! Context and application menus of the win32 apprt.
//!
//! Each `show*` function builds its menu on demand, runs it modally at a
//! screen position and returns what the user picked (null when the menu
//! was dismissed); the caller performs the choice. Because menus are
//! built on every invocation they always use the current UI language.
//!
//! The implementation is TrackPopupMenuEx today; a custom popup menu can
//! replace it behind the same functions.
const std = @import("std");
const input = @import("../../../input.zig");
const w32 = @import("../win32.zig");
const wstr = @import("wstr.zig");

/// The right-click menu of a terminal surface. Returns the binding action
/// to perform on that surface.
pub fn showSurfaceContextMenu(
    owner: w32.HWND,
    screen_pt: w32.POINT,
    has_selection: bool,
) ?input.Binding.Action {
    const Item = enum(usize) {
        copy = 1,
        paste,
        select_all,
        split_right,
        split_down,
        reset,
    };

    var menu = Builder.init() orelse return null;
    defer menu.deinit();
    menu.item(@intFromEnum(Item.copy), "Copy", has_selection);
    menu.item(@intFromEnum(Item.paste), "Paste", true);
    menu.separator();
    menu.item(@intFromEnum(Item.select_all), "Select All", true);
    menu.separator();
    menu.item(@intFromEnum(Item.split_right), "Split Right", true);
    menu.item(@intFromEnum(Item.split_down), "Split Down", true);
    menu.separator();
    menu.item(@intFromEnum(Item.reset), "Reset Terminal", true);

    const id = menu.track(owner, screen_pt) orelse return null;
    const item = std.enums.fromInt(Item, id) orelse return null;
    return switch (item) {
        .copy => .{ .copy_to_clipboard = .mixed },
        .paste => .paste_from_clipboard,
        .select_all => .select_all,
        .split_right => .{ .new_split = .right },
        .split_down => .{ .new_split = .down },
        .reset => .reset,
    };
}

/// What the tab context menu asks the window to do.
pub const TabCommand = enum(usize) {
    close = 9001,
    close_others,
    close_right,
    new_tab,
};

pub const TabMenuContext = struct {
    /// The right-clicked tab, or null for the empty part of the tab bar
    /// (which only offers New Tab).
    tab: ?usize,
    tab_count: usize,
};

/// The right-click menu of the tab bar.
pub fn showTabContextMenu(
    owner: w32.HWND,
    screen_pt: w32.POINT,
    context: TabMenuContext,
) ?TabCommand {
    var menu = Builder.init() orelse return null;
    defer menu.deinit();
    if (context.tab) |tab| {
        menu.item(@intFromEnum(TabCommand.close), "Close Tab", true);
        menu.item(@intFromEnum(TabCommand.close_others), "Close Other Tabs", context.tab_count > 1);
        menu.item(@intFromEnum(TabCommand.close_right), "Close Tabs to the Right", tab + 1 < context.tab_count);
        menu.separator();
    }
    menu.item(@intFromEnum(TabCommand.new_tab), "New Tab", true);

    const id = menu.track(owner, screen_pt) orelse return null;
    return std.enums.fromInt(TabCommand, id);
}

/// Hook for a language change. Menus are built on demand, so there is
/// nothing cached to rebuild.
pub fn onLanguageChanged() void {}

/// A Win32 popup menu under construction.
const Builder = struct {
    menu: w32.HMENU,

    fn init() ?Builder {
        return .{ .menu = w32.CreatePopupMenu() orelse return null };
    }

    fn deinit(self: *Builder) void {
        _ = w32.DestroyMenu(self.menu);
    }

    fn item(self: *Builder, id: usize, label: []const u8, enabled: bool) void {
        var buf: [256]u16 = undefined;
        _ = w32.AppendMenuW(
            self.menu,
            if (enabled) w32.MF_STRING else w32.MF_GRAYED,
            id,
            wstr.bufZ(&buf, label),
        );
    }

    fn separator(self: *Builder) void {
        _ = w32.AppendMenuW(self.menu, w32.MF_SEPARATOR, 0, null);
    }

    /// Run the menu modally; returns the picked command id.
    fn track(self: *Builder, owner: w32.HWND, screen_pt: w32.POINT) ?usize {
        const cmd = w32.TrackPopupMenuEx(
            self.menu,
            w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
            screen_pt.x,
            screen_pt.y,
            owner,
            null,
        );
        if (cmd <= 0) return null;
        return @intCast(cmd);
    }
};
