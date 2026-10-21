const std = @import("std");
const environment = @import("../../../gx/environment.zig");
const global = @import("../../../global.zig");
const gtk_version = @import("../gtk_version.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const log = std.log.scoped(.gtk_gx_environment);

fn prepare(alloc: std.mem.Allocator, name: []const u8, current: []const u8, flags: anytype, modern: bool) std.mem.Allocator.Error![:0]u8 {
    var required: std.ArrayList([]const u8) = .empty;
    defer required.deinit(alloc);
    inline for (@typeInfo(@TypeOf(flags)).@"struct".field_names) |field_name| {
        if (@field(flags, field_name)) try required.append(alloc, field_name);
    }
    if (!modern and std.mem.eql(u8, name, "GDK_DEBUG")) try required.append(alloc, "vulkan-disable");
    return environment.appendFlags(alloc, current, required.items);
}

pub fn append(name: [:0]const u8, flags: anytype) std.Io.Writer.Error!void {
    const alloc = global.alloc();
    const current: []const u8 = if (getenv(name.ptr)) |value| std.mem.span(value) else "";
    const value = prepare(alloc, name, current, flags, gtk_version.runtimeAtLeast(4, 16, 0)) catch |err| {
        log.warn("cannot append {s} flags err={}", .{ name, err });
        return error.WriteFailed;
    };
    defer alloc.free(value);
    if (std.mem.eql(u8, current, value)) return;
    if (setenv(name.ptr, value.ptr, 1) != 0) {
        log.warn("cannot set {s}", .{name});
        return error.WriteFailed;
    }
    log.debug("setting {s}={s}", .{ name, value });
}

test "GTK environment keeps flags and adds the legacy runtime Vulkan disable" {
    const alloc = std.testing.allocator;
    const flags = .{ .opengl = true };
    const old = try prepare(alloc, "GDK_DEBUG", "user-flag", flags, false);
    defer alloc.free(old);
    try std.testing.expectEqualStrings("user-flag,opengl,vulkan-disable", old);
    const modern = try prepare(alloc, "GDK_DEBUG", "user-flag", flags, true);
    defer alloc.free(modern);
    try std.testing.expectEqualStrings("user-flag,opengl", modern);
    const again = try prepare(alloc, "GDK_DEBUG", old, flags, false);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(old, again);
}

test "GTK environment never selects or overwrites GSK renderer" {
    const alloc = std.testing.allocator;
    const value = try prepare(alloc, "GDK_DISABLE", "user-feature", .{ .vulkan = true }, false);
    defer alloc.free(value);
    try std.testing.expectEqualStrings("user-feature,vulkan", value);
}
