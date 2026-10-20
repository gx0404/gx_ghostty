//! Owned launch provenance, stored on each GTK surface rather than in argv.
const std = @import("std");
const gobject = @import("gobject");
const profiles = @import("../../../gx/profiles.zig");
const configpkg = @import("../../../config.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Overrides = @import("../class/Overrides.zig");
const launch = @import("launch.zig");
const key = "gx-launch-origin";
const failed_key = "gx-launch-origin-failed";
pub const LaunchOrigin = profiles.LaunchOrigin;

const Owned = struct {
    alloc: std.mem.Allocator,
    value: LaunchOrigin,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Owned = @ptrCast(@alignCast(data orelse return));
        self.value.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

/// Returns a borrowed view valid until replacement or surface finalization.
/// Async consumers must clone it and use a stable surface reference separately.
pub fn get(surface: *Surface) LaunchOrigin {
    const object = surface.as(gobject.Object);
    if (object.getData(failed_key) != null) return .unknown;
    const data = object.getData(key) orelse return .unknown;
    const owned: *Owned = @ptrCast(@alignCast(data));
    return owned.value;
}

fn set(surface: *Surface, value: LaunchOrigin) !void {
    const alloc = Application.default().allocator();
    const owned = try alloc.create(Owned);
    errdefer alloc.destroy(owned);
    owned.* = .{ .alloc = alloc, .value = try value.clone(alloc) };
    surface.as(gobject.Object).setDataFull(key, owned, &Owned.destroy);
}

/// Clone internal metadata before its arena or profile list can be released.
/// Allocation failure is sticky: later initialization must not guess a profile.
pub fn created(surface: *Surface, overrides: Overrides, command_copied: bool) void {
    if (overrides.command != null and !command_copied) {
        surface.as(gobject.Object).setData(failed_key, @ptrFromInt(1));
        return;
    }
    const value = creationOrigin(overrides.launch_origin, overrides.command != null) orelse return;
    set(surface, value) catch {
        surface.as(gobject.Object).setData(failed_key, @ptrFromInt(1));
    };
}

/// initial-command is applied by the core only to its first surface, and
/// overrides every other origin. Configured commands are never reverse-matched
/// to a profile. Only an explicit stable profile request grants profile origin,
/// besides the default launch profile: a surface without an explicit origin or
/// command, when no `command` is configured and GX Zsh is the default profile
/// (`launch.defaultCommand`), runs GX Zsh and records its id. Otherwise it
/// keeps the upstream shell of `config` and an unknown origin.
pub fn initializing(surface: *Surface, config: *configpkg.Config) !void {
    const object = surface.as(gobject.Object);
    if (object.getData(failed_key) != null) return error.OutOfMemory;
    const app = Application.default();
    if (app.core().first and config.@"initial-command" != null) {
        try set(surface, .ad_hoc);
    } else if (object.getData(key) == null) {
        if (try launch.defaultCommand(app, config, config.arenaAlloc())) |default| {
            config.command = default.command;
            try set(surface, .{ .profile = default.id });
        } else {
            try set(surface, .unknown);
        }
    }
}

fn creationOrigin(explicit: ?LaunchOrigin, command_override: bool) ?LaunchOrigin {
    if (explicit) |value| return value;
    if (command_override) return .ad_hoc;
    return null;
}

test "typed profile provenance survives the internal command wrapper" {
    const value = creationOrigin(.{ .profile = "custom:Python" }, true).?;
    try std.testing.expectEqualStrings("custom:Python", value.profileId().?);
    try std.testing.expect(creationOrigin(null, true).? == .ad_hoc);
    try std.testing.expect(creationOrigin(null, false) == null);
    try std.testing.expect(creationOrigin(.unknown, true).? == .unknown);
}
