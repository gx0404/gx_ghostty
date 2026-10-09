//! Human-readable keybinding triggers ("Ctrl+Shift+T") for the command
//! palette, menus and the keyboard shortcut sheet.
const std = @import("std");
const input = @import("../../../input.zig");

/// Format a keybinding trigger into `buf` and return the written slice.
/// Text that does not fit is cut off.
pub fn format(trigger: input.Binding.Trigger, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    write(trigger, &writer) catch {};
    return writer.buffered();
}

/// A trigger that performs `action` in `set`: the set's reverse mapping,
/// else the first `performable:` binding of the action (the reverse
/// mapping leaves those out). Sequences and chains are not searched.
pub fn find(set: *const input.Binding.Set, action: input.Binding.Action) ?input.Binding.Trigger {
    if (set.getTrigger(action)) |t| return t;
    var it = set.bindings.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .leaf => |leaf| if (leaf.action.equal(action)) return entry.key_ptr.*,
        .leader, .leaf_chained => {},
    };
    return null;
}

/// The formatted trigger of `action` in `set`, or null: the one `find`
/// returns, or when that key has no display name (such as the `paste` media
/// key) another binding of the action.
pub fn formatAction(set: *const input.Binding.Set, action: input.Binding.Action, buf: []u8) ?[]const u8 {
    if (find(set, action)) |trigger| {
        if (displayable(trigger)) return format(trigger, buf);
    }
    var it = set.bindings.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .leaf => |leaf| if (leaf.action.equal(action) and displayable(entry.key_ptr.*)) {
            return format(entry.key_ptr.*, buf);
        },
        .leader, .leaf_chained => {},
    };
    return null;
}

/// Whether `format` writes a name for the key of `trigger`.
fn displayable(trigger: input.Binding.Trigger) bool {
    return switch (trigger.key) {
        .unicode => |cp| cp >= ' ' and cp <= '~',
        .physical => |k| keyName(k).len > 0,
        .catch_all => false,
    };
}

fn write(trigger: input.Binding.Trigger, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (trigger.mods.super) try writer.writeAll("Win+");
    if (trigger.mods.ctrl) try writer.writeAll("Ctrl+");
    if (trigger.mods.alt) try writer.writeAll("Alt+");
    if (trigger.mods.shift) try writer.writeAll("Shift+");

    switch (trigger.key) {
        .unicode => |cp| {
            // Convert to upper-case letter for display
            if (cp >= 'a' and cp <= 'z') {
                try writer.writeByte(@intCast(cp - 32));
            } else if (cp >= ' ' and cp <= '~') {
                try writer.writeByte(@intCast(cp));
            }
        },
        .physical => |k| try writer.writeAll(keyName(k)),
        .catch_all => {},
    }
}

/// Map physical key enum to display name.
pub fn keyName(k: input.Key) []const u8 {
    return switch (k) {
        .key_a => "A",
        .key_b => "B",
        .key_c => "C",
        .key_d => "D",
        .key_e => "E",
        .key_f => "F",
        .key_g => "G",
        .key_h => "H",
        .key_i => "I",
        .key_j => "J",
        .key_k => "K",
        .key_l => "L",
        .key_m => "M",
        .key_n => "N",
        .key_o => "O",
        .key_p => "P",
        .key_q => "Q",
        .key_r => "R",
        .key_s => "S",
        .key_t => "T",
        .key_u => "U",
        .key_v => "V",
        .key_w => "W",
        .key_x => "X",
        .key_y => "Y",
        .key_z => "Z",
        .digit_0 => "0",
        .digit_1 => "1",
        .digit_2 => "2",
        .digit_3 => "3",
        .digit_4 => "4",
        .digit_5 => "5",
        .digit_6 => "6",
        .digit_7 => "7",
        .digit_8 => "8",
        .digit_9 => "9",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .space => "Space",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Escape",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Delete",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .semicolon => ";",
        .quote => "'",
        .bracket_left => "[",
        .bracket_right => "]",
        .backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        else => "",
    };
}

test "format modifiers and keys" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+T", format(.{
        .key = .{ .unicode = 't' },
        .mods = .{ .ctrl = true, .shift = true },
    }, &buf));
    try testing.expectEqualStrings("Alt+F4", format(.{
        .key = .{ .physical = .f4 },
        .mods = .{ .alt = true },
    }, &buf));
    try testing.expectEqualStrings("Ctrl+,", format(.{
        .key = .{ .unicode = ',' },
        .mods = .{ .ctrl = true },
    }, &buf));
}

test "formatAction skips keys without a display name" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "paste=paste_from_clipboard");
    try set.parseAndPut(alloc, "ctrl+shift+v=paste_from_clipboard");
    try set.parseAndPut(alloc, "copy=copy_to_clipboard");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+V", formatAction(&set, .paste_from_clipboard, &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), formatAction(&set, .{ .copy_to_clipboard = .mixed }, &buf));
}

test "format cuts off at the buffer end" {
    const testing = std.testing;
    var buf: [8]u8 = undefined;
    const out = format(.{
        .key = .{ .physical = .page_down },
        .mods = .{ .ctrl = true, .shift = true },
    }, &buf);
    try testing.expect(out.len <= buf.len);
    try testing.expect(std.mem.startsWith(u8, "Ctrl+Shift+PgDn", out));
}
