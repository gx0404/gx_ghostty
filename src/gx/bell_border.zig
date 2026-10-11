const std = @import("std");
const ui_color = @import("ui_color.zig");

pub const Snapshot = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    width: u7 = 0,
    active: bool = false,

    pub const none: Snapshot = .{};

    pub fn color(self: Snapshot) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255,
            @as(f32, @floatFromInt(self.g)) / 255,
            @as(f32, @floatFromInt(self.b)) / 255,
            1,
        };
    }
};

pub const State = struct {
    enabled: bool = false,
    focused: bool = true,
    ringing: bool = false,
    accepting: bool = true,

    pub fn configure(self: *State, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) self.clear();
    }

    pub fn ring(self: *State, focused: bool) void {
        self.setFocused(focused);
        if (self.accepting and self.enabled and !focused) self.ringing = true;
    }

    pub fn setFocused(self: *State, focused: bool) void {
        self.focused = focused;
        if (focused) self.clear();
    }

    pub fn clear(self: *State) void {
        self.ringing = false;
    }

    pub fn stop(self: *State) void {
        self.accepting = false;
        self.clear();
    }

    pub fn snapshot(self: State, visible: bool, color: ui_color.Rgb8, scale: f32) Snapshot {
        if (!self.accepting or !self.enabled or self.focused or !self.ringing or !visible) return .none;
        return .{ .r = color.r, .g = color.g, .b = color.b, .width = pixelWidth(scale), .active = true };
    }
};

pub fn pixelWidth(scale: f32) u7 {
    if (!std.math.isFinite(scale)) return 1;
    return @intFromFloat(@round(std.math.clamp(scale, 1, 127)));
}

pub fn thickness(width: u32, height: u32, requested: u7) u32 {
    const shortest = @min(width, height);
    if (shortest == 0) return 0;
    return @min(requested, @max(shortest / 2, 1));
}

pub fn covers(width: u32, height: u32, requested: u7, x: u32, y: u32) bool {
    if (x >= width or y >= height) return false;
    const t = thickness(width, height, requested);
    return t != 0 and (x < t or y < t or x >= width - t or y >= height - t);
}

test "bell border rings only unfocused terminals until focus or input" {
    const testing = std.testing;
    const color: ui_color.Rgb8 = .{ .r = 241, .g = 181, .b = 66 };
    var state: State = .{};
    state.configure(true);
    state.ring(true);
    try testing.expect(!state.ringing);
    state.ring(false);
    const snapshot = state.snapshot(true, color, 1.5);
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(u7, 2), snapshot.width);
    try testing.expectEqual(@as(f32, 1), snapshot.color()[3]);
    state.ring(false);
    try testing.expectEqual(snapshot, state.snapshot(true, color, 1.5));
    try testing.expectEqual(Snapshot.none, state.snapshot(false, color, 1.5));
    try testing.expect(state.ringing);
    state.setFocused(true);
    state.setFocused(false);
    try testing.expectEqual(Snapshot.none, state.snapshot(true, color, 1));
    state.ring(false);
    state.clear();
    try testing.expectEqual(Snapshot.none, state.snapshot(true, color, 1));
}

test "bell border disabling and shutdown cannot resurrect old feedback" {
    const testing = std.testing;
    var state: State = .{};
    state.configure(true);
    state.ring(false);
    state.configure(false);
    state.configure(true);
    try testing.expect(!state.ringing);
    state.ring(false);
    state.stop();
    state.configure(true);
    state.ring(false);
    try testing.expect(!state.ringing);
    try testing.expectEqual(Snapshot.none, state.snapshot(true, .{ .r = 1, .g = 2, .b = 3 }, 1));
}

test "bell border zero padding covers four edges and leaves the body" {
    const testing = std.testing;
    for ([_]u7{ 1, 2, 3, 127 }) |requested| {
        for ([_][2]u32{ .{ 0, 0 }, .{ 0, 9 }, .{ 9, 0 }, .{ 1, 1 }, .{ 1, 9 }, .{ 2, 3 }, .{ 5, 7 }, .{ 80, 24 } }) |size| {
            const width = size[0];
            const height = size[1];
            const t = thickness(width, height, requested);
            try testing.expect(t <= if (@min(width, height) == 0) @as(u32, 0) else @max(@min(width, height) / 2, 1));
            for (0..height) |y| {
                for (0..width) |x| {
                    const edge = covers(width, height, requested, @intCast(x), @intCast(y));
                    if (x == 0 or y == 0 or x == width - 1 or y == height - 1) try testing.expect(edge);
                    if (x >= t and x < width - t and y >= t and y < height - t) try testing.expect(!edge);
                }
            }
            try testing.expect(!covers(width, height, requested, width, height));
        }
    }
    try testing.expectEqual(@as(u32, 0), thickness(9, 9, 0));
    try testing.expectEqual(@as(u32, 5), thickness(13, 11, 127));
    try testing.expect(!covers(13, 11, 127, 6, 5));
    try testing.expectEqual(@as(u32, 127), thickness(std.math.maxInt(u32), std.math.maxInt(u32), 127));
    try testing.expectEqual(@as(u7, 1), pixelWidth(0));
    try testing.expectEqual(@as(u7, 1), pixelWidth(std.math.nan(f32)));
    try testing.expectEqual(@as(u7, 127), pixelWidth(1000));
}

test "bell border atomic snapshots never mix color width and activity" {
    const Published = struct {
        value: std.atomic.Value(u32) = .init(0),
        finished: std.atomic.Value(bool) = .init(false),
        fn write(self: *@This()) void {
            for (0..100_000) |i| {
                const snapshot: Snapshot = if (i % 2 == 0)
                    .{ .r = 1, .g = 2, .b = 3, .width = 1, .active = true }
                else
                    .{ .r = 4, .g = 5, .b = 6, .width = 2, .active = true };
                self.value.store(@bitCast(snapshot), .release);
            }
            self.finished.store(true, .release);
        }
    };
    var published: Published = .{};
    const thread = try std.Thread.spawn(.{}, Published.write, .{&published});
    defer thread.join();
    var reads: usize = 0;
    while (!published.finished.load(.acquire) or reads == 0) : (reads += 1) {
        const snapshot: Snapshot = @bitCast(published.value.load(.acquire));
        if (!snapshot.active) {
            try std.testing.expectEqual(Snapshot.none, snapshot);
        } else if (snapshot.r == 1) {
            try std.testing.expectEqual(Snapshot{ .r = 1, .g = 2, .b = 3, .width = 1, .active = true }, snapshot);
        } else {
            try std.testing.expectEqual(Snapshot{ .r = 4, .g = 5, .b = 6, .width = 2, .active = true }, snapshot);
        }
    }
}
