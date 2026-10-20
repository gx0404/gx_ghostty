//! Value types of the Ghostty GX configuration keys (`gx-*` in
//! `src/config/Config.zig`).
const std = @import("std");
const Config = @import("../config/Config.zig");
const formatterpkg = @import("../config/formatter.zig");

/// Valid values for `gx-window-material`.
pub const WindowMaterial = enum {
    solid,
    mica,
    acrylic,
    tabbed,
};

/// Valid values for `gx-open-config-ui`.
pub const OpenConfigUi = enum {
    settings,
    editor,
};

/// Valid values for `gx-prompt-cursor`.
pub const PromptCursor = enum {
    config,
    bar,
};

/// Valid values for `gx-accent-color`: the Ghostty GX brand purple, a
/// color of the terminal theme, or a color of its own
/// (`ui_tokens.Accent` turns it into the interface accent).
pub const AccentColor = union(enum) {
    brand,
    theme,
    color: Config.Color,

    pub fn parseCLI(input_: ?[]const u8) !AccentColor {
        const input = std.mem.trim(u8, input_ orelse return error.ValueRequired, " \t");
        if (std.mem.eql(u8, input, "brand")) return .brand;
        if (std.mem.eql(u8, input, "theme")) return .theme;
        return .{ .color = try Config.Color.parseCLI(input) };
    }

    /// Used by Formatter
    pub fn formatEntry(self: AccentColor, formatter: formatterpkg.EntryFormatter) !void {
        switch (self) {
            .color => |color| try color.formatEntry(formatter),
            .brand, .theme => try formatter.formatEntry([:0]const u8, @tagName(self)),
        }
    }
};

test "AccentColor parses brand, theme and colors" {
    const testing = std.testing;
    try testing.expectEqual(AccentColor.brand, try AccentColor.parseCLI("brand"));
    try testing.expectEqual(AccentColor.theme, try AccentColor.parseCLI(" theme "));
    try testing.expectEqual(
        AccentColor{ .color = .{ .r = 0xff, .g = 0x88, .b = 0x00 } },
        try AccentColor.parseCLI("#ff8800"),
    );
    try testing.expectEqual(
        AccentColor{ .color = .{ .r = 0, .g = 0, .b = 0 } },
        try AccentColor.parseCLI("black"),
    );
    try testing.expectError(error.ValueRequired, AccentColor.parseCLI(null));
    try testing.expectError(error.InvalidValue, AccentColor.parseCLI("purple-ish"));
}

test "AccentColor formats as it parses" {
    const testing = std.testing;
    for ([_]struct { AccentColor, []const u8 }{
        .{ .brand, "a = brand\n" },
        .{ .theme, "a = theme\n" },
        .{ .{ .color = .{ .r = 0x0a, .g = 0x0b, .b = 0x0c } }, "a = #0a0b0c\n" },
    }) |case| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try case[0].formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try testing.expectEqualStrings(case[1], buf.written());
    }
}
