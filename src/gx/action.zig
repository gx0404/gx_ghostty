//! Ghostty GX binding actions, written `gx:<name>[:<argument>]` wherever
//! Ghostty accepts a binding action (`keybind`, `command-palette-entry`).
//!
//! The upstream binding action `gx` (`input.Binding.Action.gx`, fork patch
//! GX-0014) carries an `Action`. The core surface hands it to the app
//! runtime's `gxAction(target, action) !bool`; app runtimes without that
//! function log it and report the action as not performed. An app runtime
//! also reports the actions it does not implement as not performed, so a
//! `performable:` binding passes its key on to the terminal.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The binding action name that introduces a GX action.
pub const prefix = "gx";

/// A subset of `input.Binding.Error`, so binding parsing can return these
/// errors unchanged.
pub const Error = error{
    /// The name is known, but its argument is missing, empty or not allowed.
    InvalidFormat,

    /// The name is not a GX action.
    InvalidAction,
};

pub const Action = union(enum) {
    /// Open the Ghostty GX settings.
    settings,

    /// Open the main menu.
    main_menu,

    /// Show all keyboard shortcuts.
    keybinds,

    /// Open a new tab with the launch profile that has this id
    /// (`profiles.Profile.id`), e.g. `pwsh`, `wsl:Ubuntu` or `custom:Python`.
    new_tab_profile: []const u8,

    /// Open a new window with the launch profile that has this id.
    new_window_profile: []const u8,

    /// Open the Ghostty GX settings at a page, e.g. `settings_page:font`.
    settings_page: SettingsPage,

    /// Open the new tab menu: the launch profiles and splits.
    new_tab_menu,

    /// Open the context menu of the focused terminal at the cursor, so it
    /// can be used from the keyboard.
    context_menu,

    /// Move the focused split into a new tab of its window.
    move_split_to_tab,

    /// Move the focused split into a new window.
    move_split_to_window,

    /// Search the tabs of the window by title and switch to one, the most
    /// recently used first.
    tab_switcher,

    /// Parses `<name>[:<argument>]`, the text after `gx:`. The argument is
    /// everything after the first colon, so it may contain colons. The
    /// result borrows from `input`; use `clone` to keep it.
    pub fn parse(input: []const u8) Error!Action {
        const colon = std.mem.indexOfScalar(u8, input, ':');
        const name = input[0 .. colon orelse input.len];
        const argument: ?[]const u8 = if (colon) |i| input[i + 1 ..] else null;

        inline for (@typeInfo(Action).@"union".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) switch (field.type) {
                void => {
                    if (argument != null) return error.InvalidFormat;
                    return @unionInit(Action, field.name, {});
                },

                []const u8 => {
                    const value = argument orelse return error.InvalidFormat;
                    if (value.len == 0) return error.InvalidFormat;
                    return @unionInit(Action, field.name, value);
                },

                else => switch (@typeInfo(field.type)) {
                    .@"enum" => {
                        const value = argument orelse return error.InvalidFormat;
                        const parsed = std.meta.stringToEnum(field.type, value) orelse return error.InvalidFormat;
                        return @unionInit(Action, field.name, parsed);
                    },
                    else => @compileError("unsupported GX action argument: " ++ @typeName(field.type)),
                },
            };
        }

        return error.InvalidAction;
    }

    /// Parses `gx:<name>[:<argument>]`.
    pub fn parseQualified(input: []const u8) Error!Action {
        if (input.len <= prefix.len or
            !std.mem.startsWith(u8, input, prefix) or
            input[prefix.len] != ':') return error.InvalidAction;
        return parse(input[prefix.len + 1 ..]);
    }

    /// Writes `<name>[:<argument>]`, the input of `parse`.
    pub fn format(self: Action, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
        switch (self) {
            inline else => |value| switch (@TypeOf(value)) {
                void => {},
                []const u8 => {
                    try writer.writeByte(':');
                    try writer.writeAll(value);
                },
                else => {
                    try writer.writeByte(':');
                    try writer.writeAll(@tagName(value));
                },
            },
        }
    }

    /// Copies the argument into `alloc`.
    pub fn clone(self: Action, alloc: Allocator) Allocator.Error!Action {
        return switch (self) {
            inline else => |value, tag| @unionInit(Action, @tagName(tag), switch (@TypeOf(value)) {
                []const u8 => try alloc.dupe(u8, value),
                else => value,
            }),
        };
    }

    pub fn equal(self: Action, other: Action) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            inline else => |value, tag| switch (@TypeOf(value)) {
                void => true,
                []const u8 => std.mem.eql(u8, value, @field(other, @tagName(tag))),
                else => value == @field(other, @tagName(tag)),
            },
        };
    }

    /// The msgid of the title of the action, as menus and the keyboard
    /// shortcut sheets show it, translated in `i18n/gx.zh_CN.po`.
    pub fn title(self: Action) [:0]const u8 {
        return switch (self) {
            .settings => "Settings…",
            .main_menu => "Main Menu",
            .keybinds => "Keyboard Shortcuts",
            .new_tab_profile => "New Tab with Profile",
            .new_window_profile => "New Window with Profile",
            .settings_page => "Settings Page",
            .new_tab_menu => "New Tab Menu",
            .context_menu => "Context Menu",
            .move_split_to_tab => "Move Split to New Tab",
            .move_split_to_window => "Move Split to New Window",
            .tab_switcher => "Tab Switcher",
        };
    }
};

/// The pages of the Ghostty GX settings, in display order: the argument of
/// `settings_page`. The names are part of `gx:settings_page:<page>`
/// bindings, so renaming one breaks configurations.
pub const SettingsPage = enum {
    language,
    appearance,
    font,
    interaction,
    shell,
    about,
};

fn expectFormat(expected: []const u8, value: anytype) !void {
    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{value});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "parse GX actions" {
    const testing = std.testing;

    try testing.expect((try Action.parse("settings")).equal(.settings));
    try testing.expect((try Action.parse("main_menu")).equal(.main_menu));
    try testing.expect((try Action.parse("keybinds")).equal(.keybinds));
    try testing.expectEqualStrings("pwsh", (try Action.parse("new_tab_profile:pwsh")).new_tab_profile);
    try testing.expectEqualStrings("wsl:Ubuntu", (try Action.parse("new_tab_profile:wsl:Ubuntu")).new_tab_profile);
    try testing.expectEqualStrings("custom:My Shell", (try Action.parse("new_window_profile:custom:My Shell")).new_window_profile);

    try testing.expect((try Action.parseQualified("gx:main_menu")).equal(.main_menu));
    try testing.expectEqualStrings("wsl:Debian", (try Action.parseQualified("gx:new_window_profile:wsl:Debian")).new_window_profile);

    try testing.expectEqual(SettingsPage.font, (try Action.parse("settings_page:font")).settings_page);
    for (std.enums.values(SettingsPage)) |page| {
        var buf: [64]u8 = undefined;
        const input = try std.fmt.bufPrint(&buf, "settings_page:{t}", .{page});
        try testing.expect((try Action.parse(input)).equal(.{ .settings_page = page }));
    }
    try testing.expect((try Action.parse("new_tab_menu")).equal(.new_tab_menu));
    try testing.expect((try Action.parse("context_menu")).equal(.context_menu));
    try testing.expect((try Action.parse("move_split_to_tab")).equal(.move_split_to_tab));
    try testing.expect((try Action.parse("move_split_to_window")).equal(.move_split_to_window));
    try testing.expect((try Action.parse("tab_switcher")).equal(.tab_switcher));
}

test "parse rejects malformed GX actions" {
    const testing = std.testing;

    try testing.expectError(error.InvalidAction, Action.parse(""));
    try testing.expectError(error.InvalidAction, Action.parse("bogus"));
    try testing.expectError(error.InvalidAction, Action.parse(":settings"));
    try testing.expectError(error.InvalidAction, Action.parse("Settings"));
    try testing.expectError(error.InvalidFormat, Action.parse("settings:"));
    try testing.expectError(error.InvalidFormat, Action.parse("main_menu:now"));
    try testing.expectError(error.InvalidFormat, Action.parse("new_tab_profile"));
    try testing.expectError(error.InvalidFormat, Action.parse("new_tab_profile:"));
    try testing.expectError(error.InvalidFormat, Action.parse("settings_page"));
    try testing.expectError(error.InvalidFormat, Action.parse("settings_page:"));
    try testing.expectError(error.InvalidFormat, Action.parse("settings_page:Font"));
    try testing.expectError(error.InvalidFormat, Action.parse("settings_page:bogus"));
    try testing.expectError(error.InvalidFormat, Action.parse("new_tab_menu:x"));
    try testing.expectError(error.InvalidFormat, Action.parse("tab_switcher:"));
    try testing.expectError(error.InvalidAction, Action.parse("move_split"));

    try testing.expectError(error.InvalidAction, Action.parseQualified("gx"));
    try testing.expectError(error.InvalidAction, Action.parseQualified("gx:"));
    try testing.expectError(error.InvalidAction, Action.parseQualified("gxsettings"));
    try testing.expectError(error.InvalidAction, Action.parseQualified("settings"));
}

test "format is the inverse of parse" {
    const inputs = [_][]const u8{
        "settings",
        "main_menu",
        "keybinds",
        "new_tab_profile:pwsh",
        "new_tab_profile:wsl:Ubuntu-24.04",
        "new_window_profile:custom:Python",
        "settings_page:appearance",
        "settings_page:about",
        "new_tab_menu",
        "context_menu",
        "move_split_to_tab",
        "move_split_to_window",
        "tab_switcher",
    };
    for (inputs) |input| {
        const action = try Action.parse(input);
        try expectFormat(input, action);
    }
}

test "clone copies the argument and equal compares it" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf = "new_tab_profile:pwsh".*;
    const parsed = try Action.parse(&buf);
    const copy = try parsed.clone(alloc);
    try testing.expect(copy.equal(parsed));
    buf[buf.len - 1] = 'x';
    try testing.expectEqualStrings("pwsh", copy.new_tab_profile);
    try testing.expect(!copy.equal(parsed));

    try testing.expect(Action.equal(.settings, .settings));
    try testing.expect(!Action.equal(.settings, .keybinds));
    try testing.expect(!Action.equal(.{ .new_tab_profile = "pwsh" }, .{ .new_window_profile = "pwsh" }));
    try testing.expect((try Action.clone(.main_menu, alloc)).equal(.main_menu));

    const page: Action = .{ .settings_page = .shell };
    try testing.expect((try page.clone(alloc)).equal(page));
    try testing.expect(!page.equal(.{ .settings_page = .font }));
    try testing.expect(!page.equal(.settings));
    try testing.expect(!Action.equal(.move_split_to_tab, .move_split_to_window));
}

test "every GX action has a translated title" {
    const i18n = @import("i18n.zig");
    inline for (@typeInfo(Action).@"union".fields) |field| {
        const action = @unionInit(Action, field.name, switch (field.type) {
            void => {},
            []const u8 => "x",
            else => std.enums.values(field.type)[0],
        });
        const msgid = action.title();
        if (i18n.lookup(.zh_CN, msgid) == null) {
            std.debug.print("missing zh-CN translation for {s}\n", .{msgid});
            return error.TestUnexpectedResult;
        }
    }
}

test "Binding.Action parses, formats and hashes gx actions" {
    const testing = std.testing;
    const Binding = @import("../input/Binding.zig");

    const menu = try Binding.Action.parse("gx:main_menu");
    try testing.expect(menu == .gx);
    try testing.expect(menu.gx.equal(.main_menu));
    try testing.expectEqual(Binding.Action.Scope.surface, menu.scope());
    try expectFormat("gx:main_menu", menu);

    const wsl = try Binding.Action.parse("gx:new_tab_profile:wsl:Ubuntu");
    try testing.expectEqualStrings("wsl:Ubuntu", wsl.gx.new_tab_profile);
    try expectFormat("gx:new_tab_profile:wsl:Ubuntu", wsl);

    try testing.expectError(error.InvalidFormat, Binding.Action.parse("gx"));
    try testing.expectError(error.InvalidAction, Binding.Action.parse("gx:"));
    try testing.expectError(error.InvalidAction, Binding.Action.parse("gx:bogus"));
    try testing.expectError(error.InvalidFormat, Binding.Action.parse("gx:settings:x"));
    try testing.expectError(error.InvalidFormat, Binding.Action.parse("gx:new_window_profile"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try wsl.clone(arena.allocator());
    try testing.expect(copy.equal(wsl));
    try testing.expect(copy.gx.new_tab_profile.ptr != wsl.gx.new_tab_profile.ptr);
    try testing.expectEqual(wsl.hash(), copy.hash());

    const pwsh = try Binding.Action.parse("gx:new_tab_profile:pwsh");
    try testing.expect(!pwsh.equal(wsl));
    try testing.expect(pwsh.hash() != wsl.hash());
    try testing.expect(!menu.equal(try Binding.Action.parse("gx:settings")));

    const font = try Binding.Action.parse("gx:settings_page:font");
    try testing.expectEqual(SettingsPage.font, font.gx.settings_page);
    try expectFormat("gx:settings_page:font", font);
    const shell = try Binding.Action.parse("gx:settings_page:shell");
    try testing.expect(!font.equal(shell));
    try testing.expect(font.hash() != shell.hash());
    try testing.expect(font.equal(try font.clone(arena.allocator())));
    try testing.expectError(error.InvalidFormat, Binding.Action.parse("gx:settings_page:nope"));
    try testing.expectEqual(Binding.Action.Scope.surface, (try Binding.Action.parse("gx:tab_switcher")).scope());
}

test "Binding.Set binds gx actions from keybind syntax" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Binding = @import("../input/Binding.zig");

    var set: Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "ctrl+shift+m=gx:main_menu");
    try set.parseAndPut(alloc, "ctrl+alt+p=gx:new_tab_profile:pwsh");

    const trigger = try Binding.Trigger.parse("ctrl+shift+m");
    const entry = set.get(trigger) orelse return error.TestUnexpectedResult;
    try testing.expect(entry.value_ptr.* == .leaf);
    try testing.expect(entry.value_ptr.leaf.action.equal(.{ .gx = .main_menu }));
    const reverse = set.getTrigger(.{ .gx = .main_menu }) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(trigger.hash(), reverse.hash());

    const profile = set.getTrigger(.{ .gx = .{ .new_tab_profile = "pwsh" } }) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual((try Binding.Trigger.parse("ctrl+alt+p")).hash(), profile.hash());
}

test "Binding.Action gx entries in command-palette-entry" {
    const testing = std.testing;
    const Config = @import("../config/Config.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: Config.RepeatableCommand = .{};
    try list.parseCLI(alloc, "title:Settings,description:Open the Ghostty GX settings.,action:gx:settings");
    try list.parseCLI(alloc, "title:Ubuntu,action:gx:new_tab_profile:wsl:Ubuntu");

    const settings = list.value.items[0];
    try testing.expectEqualStrings("Settings", settings.title);
    try testing.expect(settings.action.equal(.{ .gx = .settings }));
    try testing.expectEqualStrings("gx", std.mem.span(list.value_c.items[0].action_key));
    try testing.expectEqualStrings("gx:settings", std.mem.span(list.value_c.items[0].action));

    const ubuntu = list.value.items[1];
    try testing.expectEqualStrings("wsl:Ubuntu", ubuntu.action.gx.new_tab_profile);
    try testing.expectEqualStrings("gx:new_tab_profile:wsl:Ubuntu", std.mem.span(list.value_c.items[1].action));

    try list.parseCLI(alloc, "title:Fonts,action:gx:settings_page:font");
    try testing.expect(list.value.items[2].action.equal(.{ .gx = .{ .settings_page = .font } }));
    try testing.expectEqualStrings("gx:settings_page:font", std.mem.span(list.value_c.items[2].action));

    try testing.expectError(error.InvalidValue, list.parseCLI(alloc, "title:Bad,action:gx:bogus"));
    try testing.expectError(error.InvalidValue, list.parseCLI(alloc, "title:Bad,action:gx:keybinds:x"));
}
