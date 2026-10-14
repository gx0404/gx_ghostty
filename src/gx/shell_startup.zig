//! Filter internal Windows shell launch flags from real process CLI iteration.
//! The app separately validates and executes them from argv. Never apply this
//! adapter to a configuration file or replay iterator.
const std = @import("std");

pub fn Filter(comptime Iterator: type) type {
    return struct {
        const Self = @This();
        iterator: *Iterator,
        child_command: bool = false,
        toast_server: bool = false,

        pub fn next(self: *Self) ?[]const u8 {
            while (self.iterator.next()) |arg| {
                if (self.child_command) return arg;
                if (std.mem.eql(u8, arg, "-e")) {
                    self.child_command = true;
                    return arg;
                }
                if (std.mem.eql(u8, arg, "--gx-shell-action=toast-server")) self.toast_server = true;
                // COM appends this switch when launching a LocalServer32.
                if (self.toast_server and std.ascii.eqlIgnoreCase(arg, "-Embedding")) continue;
                if (std.mem.startsWith(u8, arg, "--gx-shell-action=") or
                    std.mem.startsWith(u8, arg, "--gx-shell-profile=") or
                    std.mem.startsWith(u8, arg, "--gx-drop-target-pid=") or
                    std.mem.startsWith(u8, arg, "--gx-drop-target-birth=")) continue;
                return arg;
            }
            return null;
        }

        pub fn location(self: *const Self, alloc: std.mem.Allocator) @typeInfo(@TypeOf(Iterator.location)).@"fn".return_type.? {
            return self.iterator.location(alloc);
        }
    };
}

const Fixture = struct {
    args: []const []const u8,
    index: usize = 0,
    fail_location: bool = false,
    pub fn next(self: *Fixture) ?[]const u8 {
        if (self.index == self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
    pub fn location(self: *const Fixture, _: std.mem.Allocator) error{LocationUnavailable}!?usize {
        if (self.fail_location) return error.LocationUnavailable;
        return self.index;
    }
};

test "shell CLI filtering preserves original diagnostic locations and unrelated options" {
    var fixture: Fixture = .{ .args = &.{ "--gx-shell-action=profile", "--gx-shell-profile=custom:work", "--font-size=14", "--gx-shell-action", "--gx-shell-profile-other=x" } };
    var iter: Filter(Fixture) = .{ .iterator = &fixture };
    try std.testing.expectEqualStrings("--font-size=14", iter.next().?);
    try std.testing.expectEqual(@as(?usize, 3), try iter.location(std.testing.allocator));
    try std.testing.expectEqualStrings("--gx-shell-action", iter.next().?);
    try std.testing.expectEqualStrings("--gx-shell-profile-other=x", iter.next().?);
    try std.testing.expect(iter.next() == null);
    fixture.fail_location = true;
    try std.testing.expectError(error.LocationUnavailable, iter.location(std.testing.allocator));
}

test "shell flags after execute marker remain literal child arguments" {
    var fixture: Fixture = .{ .args = &.{ "-e", "child", "--gx-shell-action=toast-server", "--gx-shell-profile=custom:x" } };
    var iter: Filter(Fixture) = .{ .iterator = &fixture };
    for (fixture.args) |expected| try std.testing.expectEqualStrings(expected, iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "drop companion routing fields are not configuration and preserve original locations" {
    var fixture: Fixture = .{ .args = &.{ "--gx-shell-action=drop-companion", "--gx-drop-target-pid=123", "--gx-drop-target-birth=456", "--font-size=14", "-e", "--gx-drop-target-pid=999" } };
    var iter: Filter(Fixture) = .{ .iterator = &fixture };
    try std.testing.expectEqualStrings("--font-size=14", iter.next().?);
    try std.testing.expectEqual(@as(?usize, 4), try iter.location(std.testing.allocator));
    try std.testing.expectEqualStrings("-e", iter.next().?);
    try std.testing.expectEqualStrings("--gx-drop-target-pid=999", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "COM embedding marker is internal only for a toast server before execute" {
    var fixture: Fixture = .{ .args = &.{ "--gx-shell-action=toast-server", "-Embedding", "--font-size=14", "-e", "-Embedding" } };
    var iter: Filter(Fixture) = .{ .iterator = &fixture };
    try std.testing.expectEqualStrings("--font-size=14", iter.next().?);
    try std.testing.expectEqualStrings("-e", iter.next().?);
    try std.testing.expectEqualStrings("-Embedding", iter.next().?);
    try std.testing.expect(iter.next() == null);
    var unrelated: Fixture = .{ .args = &.{ "--gx-shell-action=profile", "-Embedding" } };
    var other: Filter(Fixture) = .{ .iterator = &unrelated };
    try std.testing.expectEqualStrings("-Embedding", other.next().?);
}
