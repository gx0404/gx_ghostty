//! The colors of a theme file, for the swatch next to each theme in the
//! theme list: background, foreground and the 16 palette colors, read
//! straight from the `key = value` lines without loading a configuration.
//! Only hex colors (`#rrggbb`, `rrggbb`, `#rgb`) are understood; anything
//! else keeps the Ghostty default.
//!
//! `Cache` reads the files of the rows on display on demand, so opening the
//! theme list does not read hundreds of files. Only depends on `std`, so
//! the tests run with a plain `zig test` of this file.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn parse(text: []const u8) ?Rgb {
        const hex = if (text.len > 0 and text[0] == '#') text[1..] else text;
        switch (hex.len) {
            6 => {
                const value = std.fmt.parseInt(u24, hex, 16) catch return null;
                return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
            },
            3 => {
                const value = std.fmt.parseInt(u12, hex, 16) catch return null;
                const r: u8 = @as(u8, @truncate(value >> 8)) & 0xF;
                const g: u8 = @as(u8, @truncate(value >> 4)) & 0xF;
                const b: u8 = @as(u8, @truncate(value)) & 0xF;
                return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
            },
            else => return null,
        }
    }
};

pub const Swatch = struct {
    /// The Ghostty defaults (`background`, `foreground`).
    background: Rgb = .{ .r = 0x28, .g = 0x2c, .b = 0x34 },
    foreground: Rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    palette: [16]?Rgb = @splat(null),

    /// Reads the colors from the contents of a theme file.
    pub fn parse(text: []const u8) Swatch {
        var self: Swatch = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
            if (std.mem.eql(u8, key, "background")) {
                if (Rgb.parse(value)) |c| self.background = c;
            } else if (std.mem.eql(u8, key, "foreground")) {
                if (Rgb.parse(value)) |c| self.foreground = c;
            } else if (std.mem.eql(u8, key, "palette")) {
                const sep = std.mem.indexOfScalar(u8, value, '=') orelse continue;
                const index = std.fmt.parseInt(u8, std.mem.trim(u8, value[0..sep], " \t"), 10) catch continue;
                if (index >= self.palette.len) continue;
                if (Rgb.parse(std.mem.trim(u8, value[sep + 1 ..], " \t"))) |c| self.palette[index] = c;
            }
        }
        return self;
    }

    /// The palette color `index`, or the foreground if the theme does not
    /// set it.
    pub fn color(self: *const Swatch, index: usize) Rgb {
        return self.palette[index] orelse self.foreground;
    }
};

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

/// The largest theme file read for a swatch.
const max_file_size = 64 * 1024;

/// Swatches by theme index, read on first use. A theme whose file cannot
/// be read gets the default colors.
pub const Cache = struct {
    map: std.AutoHashMapUnmanaged(u32, Swatch) = .empty,

    pub fn deinit(self: *Cache, alloc: Allocator) void {
        self.map.deinit(alloc);
        self.* = .{};
    }

    /// The swatch of theme `index` named `name`, looked up in `dirs` (the
    /// theme directories, highest priority first).
    pub fn get(
        self: *Cache,
        alloc: Allocator,
        io: std.Io,
        dirs: []const []const u8,
        index: u32,
        name: []const u8,
    ) Swatch {
        if (self.map.get(index)) |swatch| return swatch;
        const swatch = load(alloc, io, dirs, name);
        self.map.put(alloc, index, swatch) catch {};
        return swatch;
    }
};

/// Reads the theme `name` from the first of `dirs` that has it.
pub fn load(alloc: Allocator, io: std.Io, dirs: []const []const u8, name: []const u8) Swatch {
    for (dirs) |dir| {
        const path = std.fs.path.join(alloc, &.{ dir, name }) catch return .{};
        defer alloc.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_file_size)) catch continue;
        defer alloc.free(text);
        return Swatch.parse(text);
    }
    return .{};
}

const testing = std.testing;

test "Rgb.parse" {
    try testing.expectEqual(Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, Rgb.parse("#1e1e2e").?);
    try testing.expectEqual(Rgb{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }, Rgb.parse("CDD6F4").?);
    try testing.expectEqual(Rgb{ .r = 0xff, .g = 0x00, .b = 0x88 }, Rgb.parse("#f08").?);
    for ([_][]const u8{ "", "#", "red", "#12345", "#1234567", "#gggggg" }) |bad| {
        try testing.expectEqual(@as(?Rgb, null), Rgb.parse(bad));
    }
}

test "Swatch.parse reads the colors of a theme file" {
    const swatch = Swatch.parse(
        \\# Catppuccin-like
        \\palette = 0=#45475a
        \\palette = 1 = #f38ba8
        \\palette=15=#a6adc8
        \\palette = 16=#ffffff
        \\palette = x=#ffffff
        \\background = "#1e1e2e"
        \\foreground = #cdd6f4
        \\cursor-color = #f5e0dc
        \\selection-background = not-a-color
        \\
    );
    try testing.expectEqual(Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, swatch.background);
    try testing.expectEqual(Rgb{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }, swatch.foreground);
    try testing.expectEqual(Rgb{ .r = 0x45, .g = 0x47, .b = 0x5a }, swatch.palette[0].?);
    try testing.expectEqual(Rgb{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, swatch.palette[1].?);
    try testing.expectEqual(Rgb{ .r = 0xa6, .g = 0xad, .b = 0xc8 }, swatch.palette[15].?);
    try testing.expectEqual(@as(?Rgb, null), swatch.palette[2]);
    try testing.expectEqual(swatch.foreground, swatch.color(2));
}

test "Swatch.parse keeps the defaults for an empty or broken file" {
    const defaults: Swatch = .{};
    const swatch = Swatch.parse("background = nope\r\nforeground\r\n=#123456\r\n");
    try testing.expectEqual(defaults.background, swatch.background);
    try testing.expectEqual(defaults.foreground, swatch.foreground);
}

test "Cache reads a theme from the first directory that has it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "user");
    try tmp.dir.createDirPath(io, "resources");
    try tmp.dir.writeFile(io, .{ .sub_path = "user/A", .data = "background = #010203\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/A", .data = "background = #040506\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/B", .data = "background = #070809\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const user = try std.fs.path.join(testing.allocator, &.{ root, "user" });
    defer testing.allocator.free(user);
    const resources = try std.fs.path.join(testing.allocator, &.{ root, "resources" });
    defer testing.allocator.free(resources);
    const dirs = [_][]const u8{ user, resources };

    var cache: Cache = .{};
    defer cache.deinit(testing.allocator);
    try testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, cache.get(testing.allocator, io, &dirs, 0, "A").background);
    try testing.expectEqual(Rgb{ .r = 7, .g = 8, .b = 9 }, cache.get(testing.allocator, io, &dirs, 1, "B").background);
    const defaults: Swatch = .{};
    try testing.expectEqual(defaults.background, cache.get(testing.allocator, io, &dirs, 2, "missing").background);
    // Cached: the file is not read again.
    try tmp.dir.writeFile(io, .{ .sub_path = "user/A", .data = "background = #ffffff\n" });
    try testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, cache.get(testing.allocator, io, &dirs, 0, "A").background);
}
