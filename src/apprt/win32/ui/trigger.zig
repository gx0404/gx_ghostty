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
