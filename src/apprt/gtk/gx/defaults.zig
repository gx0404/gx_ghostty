const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const Config = @import("../../../config/Config.zig");
const config_layers = @import("../../../gx/config_layers.zig");

const log = std.log.scoped(.gtk_gx_defaults);

pub fn sampleSystemCursorBlink() ?bool {
    const value = cursorBlink();
    config_layers.setSystemCursorBlink(value);
    return value;
}

fn cursorBlink() ?bool {
    if (gtk.isInitialized() == 0) return null;
    const settings = gtk.Settings.getDefault() orelse return null;
    var value = gobject.ext.Value.new(c_int);
    defer value.unset();
    settings.as(gobject.Object).getProperty("gtk-cursor-blink", &value);
    return value.getInt() != 0;
}

pub const Startup = struct {
    layers: ?config_layers.Layers = null,

    pub fn load(self: *Startup, alloc: std.mem.Allocator) !Config {
        config_layers.setSystemCursorBlink(null);
        if (!config_layers.enabled(alloc)) return try Config.load(alloc);
        self.layers = try config_layers.Layers.load(alloc);
        errdefer self.deinit();
        return try self.layers.?.build(alloc, &.{});
    }

    pub fn initialized(self: *Startup, alloc: std.mem.Allocator, config: *Config) void {
        self.applySystemCursorBlink(alloc, config, sampleSystemCursorBlink()) catch |err| {
            log.warn("rebuilding the startup configuration for cursor blink failed err={}", .{err});
        };
    }

    fn applySystemCursorBlink(self: *Startup, alloc: std.mem.Allocator, config: *Config, value: ?bool) !void {
        const layers = if (self.layers) |*layers| layers else return;
        if (!layers.setSystemCursorBlink(value)) return;
        const rebuilt = try layers.build(alloc, &.{});
        config.deinit();
        config.* = rebuilt;
    }

    pub fn deinit(self: *Startup) void {
        if (self.layers) |*layers| layers.deinit();
        self.layers = null;
    }
};

test "R4 startup updates only the captured defaults after GTK initializes" {
    const alloc = std.testing.allocator;
    var startup: Startup = .{ .layers = .{ .arena = .init(alloc) } };
    defer startup.deinit();
    const layers = &startup.layers.?;
    const arena = layers.arena.allocator();
    try layers.steps.getPtr(.defaults).append(arena, .{ .arg = "--cursor-style-blink=true" });
    try layers.steps.getPtr(.user).append(arena, .{ .arg = "--font-size=17" });
    var config = try layers.build(alloc, &.{});
    defer config.deinit();
    try startup.applySystemCursorBlink(alloc, &config, false);
    try std.testing.expectEqual(@as(?bool, false), config.@"cursor-style-blink");
    try std.testing.expectEqual(@as(f32, 17), config.@"font-size");
    try layers.setOverlay("cursor-style-blink", &.{"true"});
    try startup.applySystemCursorBlink(alloc, &config, true);
    try std.testing.expectEqual(@as(?bool, true), config.@"cursor-style-blink");
    try startup.applySystemCursorBlink(alloc, &config, false);
    try std.testing.expectEqual(@as(?bool, true), config.@"cursor-style-blink");
    try layers.setOverlay("cursor-style-blink", &.{});
    var restored = try layers.build(alloc, &.{});
    defer restored.deinit();
    try std.testing.expectEqual(@as(?bool, false), restored.@"cursor-style-blink");
}

test "R4 native GTK cursor preference is sampled after initialization" {
    if (gtk.isInitialized() == 0 and gtk.initCheck() == 0) return error.SkipZigTest;
    @import("adw").init();
    defer config_layers.setSystemCursorBlink(null);
    const blink = cursorBlink() orelse return error.TestUnexpectedResult;
    const global = @import("../../../global.zig");
    if (global.environ().getPosix("GX_TEST_EXPECT_BLINK")) |expected| {
        try std.testing.expectEqual(!std.mem.eql(u8, expected, "0"), blink);
    }
    const alloc = std.testing.allocator;
    var startup: Startup = .{ .layers = .{ .arena = .init(alloc) } };
    defer startup.deinit();
    const layers = &startup.layers.?;
    try layers.steps.getPtr(.defaults).append(layers.arena.allocator(), .{ .arg = "--cursor-style-blink=true" });
    var config = try layers.build(alloc, &.{});
    defer config.deinit();
    startup.initialized(alloc, &config);
    try std.testing.expectEqual(@as(?bool, blink), config.@"cursor-style-blink");
    try std.testing.expectEqual(@as(?bool, blink), config_layers.systemCursorBlink());
    try layers.setOverlay("cursor-style-blink", &.{"true"});
    var explicit = try layers.build(alloc, &.{});
    defer explicit.deinit();
    try std.testing.expectEqual(@as(?bool, true), explicit.@"cursor-style-blink");
}
