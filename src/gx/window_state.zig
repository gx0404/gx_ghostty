//! The place and size of a terminal window, remembered between runs in the
//! state file `gx-window-state` (`state_file`), never in a configuration
//! file. An app runtime saves the window that closes last and opens the
//! first window of the next run there; `use` says which parts apply under
//! the configuration (`window-save-state = never` turns it off, and
//! `window-width`/`window-height`, `window-position-x`/`-y`, `maximize` and
//! `fullscreen` win over the remembered values).
//!
//! Positions and sizes are physical pixels of the virtual screen, with the
//! DPI of the monitor the window was on. On GTK, which places windows
//! itself, only the size (in logical pixels, DPI 96) and the maximized
//! state are written.
//!
//! The remembered place goes through `restore` before it is used: the size
//! is kept in DIPs on a monitor of another scale, the window is moved and
//! shrunk into the work area, a place no longer on screen is dropped, and
//! a window that would open exactly on top of another one is offset.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");
const state_file = @import("state_file.zig");

/// The name of the state file.
pub const file_name = "gx-window-state";

/// The largest state file `load` reads.
pub const max_file_size = 4096;

/// The format version of the file.
const version = 1;

/// The DPI of 100% scale.
pub const base_dpi: u32 = 96;

/// How far `restore` offsets a window from one at the same place, and how
/// much of a window must be on screen to keep its place, in DIPs.
pub const cascade_step_dip: i32 = 32;
pub const min_visible_dip: i32 = 48;

/// The smallest window size a state file may hold, in pixels; smaller
/// sizes are treated as damaged.
const min_saved_size: i32 = 64;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn right(self: Rect) i32 {
        return self.x +| self.width;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y +| self.height;
    }

    /// The overlap of two rectangles, or null when they do not overlap.
    pub fn intersection(a: Rect, b: Rect) ?Rect {
        const left = @max(a.x, b.x);
        const top = @max(a.y, b.y);
        const r = @min(a.right(), b.right());
        const btm = @min(a.bottom(), b.bottom());
        if (r <= left or btm <= top) return null;
        return .{ .x = left, .y = top, .width = r - left, .height = btm - top };
    }
};

pub const State = struct {
    /// The top-left corner of the window when it is neither maximized nor
    /// full screen; null where the window system places windows (GTK).
    position: ?Point = null,

    /// The size of the window when it is neither maximized nor full
    /// screen.
    size: Size,

    /// The DPI of the monitor the window was on.
    dpi: u32 = base_dpi,

    maximized: bool = false,

    /// The rectangle of the window, if the state has a position.
    pub fn rect(self: State) ?Rect {
        const position = self.position orelse return null;
        return .{ .x = position.x, .y = position.y, .width = self.size.width, .height = self.size.height };
    }

    /// Parses a state file. Lines it does not understand are skipped; null
    /// for another version or without a sensible size.
    pub fn parse(text: []const u8) ?State {
        var current = false;
        var x: ?i32 = null;
        var y: ?i32 = null;
        var width: ?i32 = null;
        var height: ?i32 = null;
        var dpi: u32 = base_dpi;
        var maximized = false;

        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const key = fields.next() orelse continue;
            const value = fields.next() orelse continue;
            if (std.mem.eql(u8, key, "version")) {
                current = (std.fmt.parseInt(u32, value, 10) catch 0) == version;
            } else if (std.mem.eql(u8, key, "x")) {
                x = std.fmt.parseInt(i32, value, 10) catch continue;
            } else if (std.mem.eql(u8, key, "y")) {
                y = std.fmt.parseInt(i32, value, 10) catch continue;
            } else if (std.mem.eql(u8, key, "width")) {
                width = std.fmt.parseInt(i32, value, 10) catch continue;
            } else if (std.mem.eql(u8, key, "height")) {
                height = std.fmt.parseInt(i32, value, 10) catch continue;
            } else if (std.mem.eql(u8, key, "dpi")) {
                const parsed = std.fmt.parseInt(u32, value, 10) catch continue;
                if (parsed >= 48 and parsed <= 96 * 8) dpi = parsed;
            } else if (std.mem.eql(u8, key, "maximized")) {
                maximized = std.mem.eql(u8, value, "true");
            }
        }

        if (!current) return null;
        const w = width orelse return null;
        const h = height orelse return null;
        if (w < min_saved_size or h < min_saved_size) return null;
        return .{
            .position = if (x != null and y != null) .{ .x = x.?, .y = y.? } else null,
            .size = .{ .width = w, .height = h },
            .dpi = dpi,
            .maximized = maximized,
        };
    }

    /// Writes the state in the format `parse` reads.
    pub fn write(self: State, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("# Ghostty GX window state: the place of the last closed window.\n");
        try writer.print("version {d}\n", .{version});
        if (self.position) |position| {
            try writer.print("x {d}\ny {d}\n", .{ position.x, position.y });
        }
        try writer.print("width {d}\nheight {d}\ndpi {d}\nmaximized {}\n", .{
            self.size.width,
            self.size.height,
            self.dpi,
            self.maximized,
        });
    }
};

/// Which remembered parts a new window uses under `config`.
pub const Use = struct {
    size: bool,
    position: bool,
    maximized: bool,

    pub const none: Use = .{ .size = false, .position = false, .maximized = false };

    pub fn any(self: Use) bool {
        return self.size or self.position or self.maximized;
    }
};

/// The remembered parts that apply under `config`: none with
/// `window-save-state = never`; the size unless `window-width` and
/// `window-height` set one, the position unless `window-position-x` and
/// `window-position-y` set one, and the maximized state unless `maximize`
/// or `fullscreen` decide.
pub fn use(config: *const Config) Use {
    if (config.@"window-save-state" == .never) return .none;
    return .{
        .size = config.@"window-width" == 0 or config.@"window-height" == 0,
        .position = config.@"window-position-x" == null or config.@"window-position-y" == null,
        .maximized = !config.maximize and config.fullscreen == .false,
    };
}

/// Loads the state file at `path`: null when it does not exist or does
/// not hold a usable state.
pub fn load(alloc: Allocator, io: std.Io, path: []const u8) !?State {
    const text = try state_file.read(alloc, io, path, max_file_size) orelse return null;
    defer alloc.free(text);
    return State.parse(text);
}

/// Replaces the state file at `path` with `state`.
pub fn save(io: std.Io, path: []const u8, state: State) !void {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    state.write(&writer) catch return error.NoSpaceLeft;
    try state_file.write(io, path, writer.buffered());
}

/// The path of the state file in the state directory. The caller owns
/// the result.
pub fn defaultPath(alloc: Allocator) ![]u8 {
    return try state_file.path(alloc, file_name);
}

/// `value` DIPs in pixels at `dpi`.
pub fn scale(value: i32, dpi: u32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * dpi, base_dpi));
}

/// `rect` with its size converted from `from_dpi` to `to_dpi`, so it stays
/// the same in DIPs; the top-left corner stays put.
pub fn rescale(rect: Rect, from_dpi: u32, to_dpi: u32) Rect {
    if (from_dpi == to_dpi or from_dpi == 0) return rect;
    return .{
        .x = rect.x,
        .y = rect.y,
        .width = @intCast(@divTrunc(@as(i64, rect.width) * to_dpi + from_dpi / 2, from_dpi)),
        .height = @intCast(@divTrunc(@as(i64, rect.height) * to_dpi + from_dpi / 2, from_dpi)),
    };
}

/// `rect` moved, and shrunk if needed, to lie inside `work`.
pub fn fit(rect: Rect, work: Rect) Rect {
    const width = @min(rect.width, work.width);
    const height = @min(rect.height, work.height);
    return .{
        .x = std.math.clamp(rect.x, work.x, work.right() - width),
        .y = std.math.clamp(rect.y, work.y, work.bottom() - height),
        .width = width,
        .height = height,
    };
}

/// Whether at least `min` pixels of `rect` in each direction lie in
/// `work`, so the window can still be grabbed.
pub fn visible(rect: Rect, work: Rect, min: i32) bool {
    const overlap = rect.intersection(work) orelse return false;
    return overlap.width >= @min(min, rect.width) and overlap.height >= @min(min, rect.height);
}

/// `rect` moved down and right by `step` until no rectangle of `occupied`
/// starts at the same place (within a few pixels), starting over at the
/// top left of `work` when it would leave it.
pub fn cascade(rect: Rect, occupied: []const Rect, step: i32, work: Rect) Rect {
    var result = rect;
    var moves: usize = 0;
    while (moves <= occupied.len) : (moves += 1) {
        const taken = for (occupied) |other| {
            if (@abs(other.x - result.x) <= 2 and @abs(other.y - result.y) <= 2) break true;
        } else false;
        if (!taken) break;
        result.x += step;
        result.y += step;
        if (result.right() > work.right() or result.bottom() > work.bottom()) {
            result.x = work.x + step * @as(i32, @intCast(moves % 8));
            result.y = work.y;
        }
    }
    return result;
}

/// Where a window opens on a monitor with the work area `work` and `dpi`:
/// the remembered rectangle with its size kept in DIPs, at least `min` in
/// pixels, moved into `work` and offset from the windows at `occupied`.
/// Null when the state has no position or too little of it is on that
/// monitor; the window then opens where it would without a state.
pub fn restore(state: State, work: Rect, dpi: u32, min: Size, occupied: []const Rect) ?Rect {
    var rect = rescale(state.rect() orelse return null, state.dpi, dpi);
    if (!visible(rect, work, scale(min_visible_dip, dpi))) return null;
    rect.width = @max(rect.width, min.width);
    rect.height = @max(rect.height, min.height);
    return cascade(fit(rect, work), occupied, scale(cascade_step_dip, dpi), work);
}

const testing = std.testing;

test "parse and write round-trip" {
    const states = [_]State{
        .{ .position = .{ .x = -1200, .y = 40 }, .size = .{ .width = 1600, .height = 900 }, .dpi = 144, .maximized = true },
        .{ .size = .{ .width = 800, .height = 600 } },
    };
    for (states) |state| {
        var buf: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try state.write(&writer);
        const parsed = State.parse(writer.buffered()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualDeep(state, parsed);
    }
}

test "parse rejects other versions and damaged sizes" {
    try testing.expectEqual(@as(?State, null), State.parse(""));
    try testing.expectEqual(@as(?State, null), State.parse("width 800\nheight 600\n"));
    try testing.expectEqual(@as(?State, null), State.parse("version 2\nwidth 800\nheight 600\n"));
    try testing.expectEqual(@as(?State, null), State.parse("version 1\nwidth 800\n"));
    try testing.expectEqual(@as(?State, null), State.parse("version 1\nwidth 10\nheight 600\n"));
    const lenient = State.parse("version 1\r\nx 5\r\nwidth 800\r\nheight 600\r\ndpi 9999\r\nbogus\r\nmaximized yes\r\n").?;
    try testing.expectEqual(@as(?Point, null), lenient.position);
    try testing.expectEqual(base_dpi, lenient.dpi);
    try testing.expect(!lenient.maximized);
}

test "use follows window-save-state and the window settings" {
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    try testing.expectEqual(Use{ .size = true, .position = true, .maximized = true }, use(&config));

    config.@"window-width" = 100;
    try testing.expect(use(&config).size);
    config.@"window-height" = 30;
    try testing.expect(!use(&config).size);
    config.@"window-position-x" = 10;
    config.@"window-position-y" = 10;
    try testing.expect(!use(&config).position);
    config.maximize = true;
    try testing.expect(!use(&config).maximized);
    config.maximize = false;
    config.fullscreen = .true;
    try testing.expect(!use(&config).maximized);

    config.fullscreen = .false;
    config.@"window-save-state" = .never;
    try testing.expect(!use(&config).any());
    config.@"window-save-state" = .always;
    try testing.expectEqual(Use{ .size = false, .position = false, .maximized = true }, use(&config));
}

test "rescale keeps the size in DIPs" {
    const rect: Rect = .{ .x = 10, .y = 20, .width = 1500, .height = 900 };
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 1000, .height = 600 }, rescale(rect, 144, 96));
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 3000, .height = 1800 }, rescale(rect, 96, 192));
    try testing.expectEqual(rect, rescale(rect, 120, 120));
    try testing.expectEqual(@as(i32, 48), scale(32, 144));
}

test "fit moves and shrinks into the work area" {
    const work: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 };
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .width = 800, .height = 600 }, fit(.{ .x = 100, .y = 100, .width = 800, .height = 600 }, work));
    try testing.expectEqual(Rect{ .x = 1120, .y = 440, .width = 800, .height = 600 }, fit(.{ .x = 1500, .y = 900, .width = 800, .height = 600 }, work));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 1920, .height = 1040 }, fit(.{ .x = -50, .y = -50, .width = 3000, .height = 2000 }, work));
    // A work area left of the primary monitor.
    const left: Rect = .{ .x = -1920, .y = 0, .width = 1920, .height = 1080 };
    try testing.expectEqual(Rect{ .x = -1920, .y = 0, .width = 800, .height = 600 }, fit(.{ .x = -2500, .y = -10, .width = 800, .height = 600 }, left));
}

test "visible needs a grabbable part on the monitor" {
    const work: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 };
    try testing.expect(visible(.{ .x = 100, .y = 100, .width = 800, .height = 600 }, work, 48));
    try testing.expect(visible(.{ .x = 1870, .y = 100, .width = 800, .height = 600 }, work, 48));
    try testing.expect(!visible(.{ .x = 1900, .y = 100, .width = 800, .height = 600 }, work, 48));
    try testing.expect(!visible(.{ .x = 3000, .y = 100, .width = 800, .height = 600 }, work, 48));
    try testing.expect(!visible(.{ .x = 100, .y = -590, .width = 800, .height = 600 }, work, 48));
}

test "cascade offsets windows at the same place" {
    const work: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 };
    const rect: Rect = .{ .x = 100, .y = 100, .width = 800, .height = 600 };
    try testing.expectEqual(rect, cascade(rect, &.{}, 32, work));
    try testing.expectEqual(rect, cascade(rect, &.{.{ .x = 500, .y = 100, .width = 800, .height = 600 }}, 32, work));
    try testing.expectEqual(
        Rect{ .x = 164, .y = 164, .width = 800, .height = 600 },
        cascade(rect, &.{ .{ .x = 101, .y = 99, .width = 800, .height = 600 }, .{ .x = 132, .y = 132, .width = 1, .height = 1 } }, 32, work),
    );
    // Leaving the work area starts over at its top left.
    const corner: Rect = .{ .x = 1100, .y = 430, .width = 800, .height = 600 };
    const moved = cascade(corner, &.{corner}, 32, work);
    try testing.expectEqual(work.y, moved.y);
    try testing.expect(moved.right() <= work.right());
}

test "restore places the remembered window on the monitor" {
    const work: Rect = .{ .x = 0, .y = 0, .width = 2880, .height = 1560 };
    const state: State = .{ .position = .{ .x = 200, .y = 150 }, .size = .{ .width = 1000, .height = 700 }, .dpi = 96 };
    const min: Size = .{ .width = 300, .height = 200 };

    // The same size in DIPs on a 150% monitor.
    try testing.expectEqual(Rect{ .x = 200, .y = 150, .width = 1500, .height = 1050 }, restore(state, work, 144, min, &.{}).?);
    // Offset from a window already there.
    const occupied = [_]Rect{.{ .x = 200, .y = 150, .width = 1500, .height = 1050 }};
    try testing.expectEqual(@as(i32, 248), restore(state, work, 144, min, &occupied).?.x);
    // At least the minimum size.
    const tiny: State = .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 300, .height = 200 }, restore(tiny, work, 96, min, &.{}).?);
    // Off this monitor, or without a position.
    const away: State = .{ .position = .{ .x = 5000, .y = 0 }, .size = .{ .width = 1000, .height = 700 } };
    try testing.expectEqual(@as(?Rect, null), restore(away, work, 96, min, &.{}));
    try testing.expectEqual(@as(?Rect, null), restore(.{ .size = .{ .width = 1000, .height = 700 } }, work, 96, min, &.{}));
}

test "save and load through the state file" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "ghostty", file_name });
    defer alloc.free(path);

    try testing.expectEqual(@as(?State, null), try load(alloc, io, path));
    const state: State = .{ .position = .{ .x = 10, .y = 20 }, .size = .{ .width = 1280, .height = 800 }, .dpi = 120 };
    try save(io, path, state);
    try testing.expectEqualDeep(@as(?State, state), try load(alloc, io, path));
}
