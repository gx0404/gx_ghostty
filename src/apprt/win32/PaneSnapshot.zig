//! Pointer-free GUI metadata. Titles are owned UTF-8 bytes; identities remain
//! value references, never proof of liveness. This is not a session document.
const Self = @This();
const std = @import("std");
const refs = @import("../../gx/ui_ref.zig");
pub const Reference = refs.Reference;
pub const Grid = struct { pane: Reference, columns: u32, rows: u32 };
pub const Tab = struct { window: Reference, tab: ?Reference, split: bool, zoomed: bool, other_tabs: bool };
pub const CursorAnchor = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scale: f32,
    cell_width: u32,
    cell_height: u32,
    pane_width: u32,
    pane_height: u32,
};
pub const Title = struct {
    bytes: [4096]u8 = undefined,
    len: u16 = 0,
    truncated: bool = false,
    pub fn init(value: []const u8) !Title {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        var result: Title = .{};
        var end = @min(value.len, result.bytes.len);
        while (end > 0 and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
        @memcpy(result.bytes[0..end], value[0..end]);
        result.len = @intCast(end);
        result.truncated = end != value.len;
        return result;
    }
    pub fn slice(self: *const Title) []const u8 {
        return self.bytes[0..self.len];
    }
};

reference: Reference = .{},
attachment: refs.Attachment = .{},
initialized: bool = false,
ready: bool = false,
title: Title = .{},
grid: ?Grid = null,
selection: bool = false,
needs_confirm: bool = false,
unread: bool = false,
bell: bool = false,
progress: @import("tab_status.zig").Progress = .none,
cursor: ?CursorAnchor = null,
cwd: Title = .{},
busy: Title = .{},

/// Equality for cache identity includes generation and host epoch. Empty
/// records may compare equal, while matching a live pane still requires valid refs.
pub fn sameIdentity(a: Reference, b: Reference) bool {
    return std.meta.eql(a, b);
}

test "pane metadata owns its title and truncates only at UTF-8 boundaries" {
    var original = "owned title".*;
    const title = try Title.init(&original);
    @memset(&original, 'x');
    try std.testing.expectEqualStrings("owned title", title.slice());
    var long: [4098]u8 = undefined;
    @memset(long[0..4095], 'a');
    @memcpy(long[4095..], "\xe4\xb8\xad");
    const truncated = try Title.init(&long);
    try std.testing.expectEqual(@as(u16, 4095), truncated.len);
    try std.testing.expect(truncated.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated.slice()));
    try std.testing.expectError(error.InvalidUtf8, Title.init("\xff"));
}

test "pane snapshot identity distinguishes reused IDs and foreign epochs" {
    const first: Reference = .{ .epoch = 1, .kind = .surface, .id = 2, .generation = 3 };
    var other = first;
    other.generation += 1;
    try std.testing.expect(!sameIdentity(first, other));
    other = first;
    other.epoch += 1;
    try std.testing.expect(!sameIdentity(first, other));
    try std.testing.expect(sameIdentity(.{}, .{}));
}
