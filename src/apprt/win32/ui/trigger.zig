//! Keybinding triggers for the command palette, menus and the keyboard
//! shortcut sheet: text ("Ctrl+Shift+T") for menu hints, keycap chips for
//! the custom-drawn popups (`Keycaps`, `drawSequence`, key sequences shown
//! as `A → B`), the trigger that runs an action (`find`) and the action a
//! key press is bound to (`actionForKey`).
const std = @import("std");
const input = @import("../../../input.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const Binding = input.Binding;
const Trigger = Binding.Trigger;

/// Format a keybinding trigger into `buf` and return the written slice.
/// Text that does not fit is cut off.
pub fn format(trigger: Trigger, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    write(trigger, &writer) catch {};
    return writer.buffered();
}

/// Format a key sequence (leader keys first) as `Ctrl+A → N` into `buf`.
pub fn formatSequence(sequence: []const Trigger, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    for (sequence, 0..) |trigger, i| {
        if (i > 0) writer.writeAll(" \u{2192} ") catch break;
        write(trigger, &writer) catch break;
    }
    return writer.buffered();
}

/// A trigger that performs `action` in `set`: the set's reverse mapping,
/// else the first `performable:` binding of the action (the reverse
/// mapping leaves those out). Sequences and chains are not searched.
pub fn find(set: *const Binding.Set, action: Binding.Action) ?Trigger {
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
pub fn formatAction(set: *const Binding.Set, action: Binding.Action, buf: []u8) ?[]const u8 {
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

/// Whether `format` writes a display name for the key of `trigger`, not
/// just a tag name (`keyName`) or nothing.
fn displayable(trigger: Trigger) bool {
    return switch (trigger.key) {
        .unicode => |cp| cp >= 0x20 and cp != 0x7F,
        .physical => |k| namedKey(k) != null,
        .catch_all => false,
    };
}

fn write(trigger: Trigger, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const caps: Keycaps = .init(trigger);
    for (0..caps.count()) |i| {
        if (i > 0) try writer.writeByte('+');
        try writer.writeAll(caps.get(i));
    }
}

/// The keys of a trigger as keycap labels: the modifiers (Win, Ctrl, Alt,
/// Shift) followed by the key.
pub const Keycaps = struct {
    mods: [4][]const u8 = undefined,
    mods_len: usize = 0,
    key_buf: [16]u8 = undefined,
    key_len: usize = 0,

    pub fn init(trigger: Trigger) Keycaps {
        var self: Keycaps = .{};
        const mods = trigger.mods;
        for ([_]struct { bool, []const u8 }{
            .{ mods.super, "Win" },
            .{ mods.ctrl, "Ctrl" },
            .{ mods.alt, "Alt" },
            .{ mods.shift, "Shift" },
        }) |mod| {
            if (!mod[0]) continue;
            self.mods[self.mods_len] = mod[1];
            self.mods_len += 1;
        }

        var writer: std.Io.Writer = .fixed(&self.key_buf);
        switch (trigger.key) {
            .unicode => |cp| writeCodepoint(&writer, cp) catch {},
            .physical => |k| writer.writeAll(keyName(k)) catch {},
            .catch_all => {},
        }
        self.key_len = writer.buffered().len;
        return self;
    }

    pub fn count(self: *const Keycaps) usize {
        return self.mods_len + @intFromBool(self.key_len > 0);
    }

    /// The label of keycap `i` (< `count`).
    pub fn get(self: *const Keycaps, i: usize) []const u8 {
        if (i < self.mods_len) return self.mods[i];
        return self.key_buf[0..self.key_len];
    }
};

/// A code point as a key label: ASCII letters upper-cased, space named,
/// control characters dropped.
fn writeCodepoint(writer: *std.Io.Writer, cp: u21) std.Io.Writer.Error!void {
    if (cp >= 'a' and cp <= 'z') return writer.writeByte(@intCast(cp - 32));
    if (cp == ' ') return writer.writeAll("Space");
    if (cp < 0x20 or cp == 0x7F) return;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    try writer.writeAll(buf[0..len]);
}

/// Map physical key enum to display name: `namedKey`, else the key's tag
/// name (media and browser keys such as `paste`).
pub fn keyName(k: input.Key) []const u8 {
    return namedKey(k) orelse @tagName(k);
}

/// The display name of physical key `k`, or null when it has none.
fn namedKey(k: input.Key) ?[]const u8 {
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
        .f13 => "F13",
        .f14 => "F14",
        .f15 => "F15",
        .f16 => "F16",
        .f17 => "F17",
        .f18 => "F18",
        .f19 => "F19",
        .f20 => "F20",
        .f21 => "F21",
        .f22 => "F22",
        .f23 => "F23",
        .f24 => "F24",
        .f25 => "F25",
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
        .backslash, .intl_backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        .numpad_0 => "Num 0",
        .numpad_1 => "Num 1",
        .numpad_2 => "Num 2",
        .numpad_3 => "Num 3",
        .numpad_4 => "Num 4",
        .numpad_5 => "Num 5",
        .numpad_6 => "Num 6",
        .numpad_7 => "Num 7",
        .numpad_8 => "Num 8",
        .numpad_9 => "Num 9",
        .numpad_add => "Num +",
        .numpad_subtract => "Num -",
        .numpad_multiply => "Num *",
        .numpad_divide => "Num /",
        .numpad_decimal => "Num .",
        .numpad_enter => "Num Enter",
        .numpad_equal => "Num =",
        .caps_lock => "Caps Lock",
        .num_lock => "Num Lock",
        .scroll_lock => "Scroll Lock",
        .print_screen => "PrtSc",
        .pause => "Pause",
        .context_menu => "Menu",
        else => null,
    };
}

// -----------------------------------------------------------------------
// Keycap chips
// -----------------------------------------------------------------------

/// Chip metrics in DIPs.
pub const chip_height: f32 = 20;
const chip_padding_x: f32 = 6;
const chip_gap: f32 = 4;
const chip_radius: f32 = 4;
const step_gap: f32 = 5;
const arrow = "\u{2192}";

pub const ChipColors = struct {
    fill: d2d.Color,
    border: d2d.Color,
    text: d2d.Color,
    /// The arrow between the steps of a sequence.
    arrow: d2d.Color,

    pub fn fromTokens(tokens: style.Tokens) ChipColors {
        return .{
            .fill = style.mix(tokens.surface_raised, tokens.foreground, 0.07),
            .border = tokens.border,
            .text = tokens.text_secondary,
            .arrow = tokens.text_disabled,
        };
    }
};

fn chipTextStyle(color: d2d.Color) d2d.TextStyle {
    return .{
        .size = style.font_size.caption,
        .color = color,
        .align_x = .center,
        .align_y = .center,
        .ellipsis = false,
    };
}

fn chipWidth(canvas: *d2d.Canvas, label: []const u8) f32 {
    const text_w = canvas.measureText(label, chipTextStyle(.{ .r = 0, .g = 0, .b = 0 }), 1000).width;
    return @max(chip_height, @ceil(text_w) + 2 * chip_padding_x);
}

fn arrowWidth(canvas: *d2d.Canvas) f32 {
    return @ceil(canvas.measureText(arrow, chipTextStyle(.{ .r = 0, .g = 0, .b = 0 }), 1000).width);
}

/// The width of the chips of a key sequence.
pub fn measureSequence(canvas: *d2d.Canvas, sequence: []const Trigger) f32 {
    var width: f32 = 0;
    for (sequence, 0..) |trigger, step| {
        if (step > 0) width += 2 * step_gap + arrowWidth(canvas);
        const caps: Keycaps = .init(trigger);
        for (0..caps.count()) |i| {
            if (i > 0) width += chip_gap;
            width += chipWidth(canvas, caps.get(i));
        }
    }
    return width;
}

/// Draw the chips of a key sequence starting at `x`, vertically centered
/// on `center_y`. Returns the right edge.
pub fn drawSequence(
    canvas: *d2d.Canvas,
    sequence: []const Trigger,
    x: f32,
    center_y: f32,
    colors: ChipColors,
) f32 {
    var cx = x;
    const top = center_y - chip_height / 2;
    for (sequence, 0..) |trigger, step| {
        if (step > 0) {
            cx += step_gap;
            const w = arrowWidth(canvas);
            canvas.drawText(arrow, .{ .x = cx, .y = top, .w = w, .h = chip_height }, chipTextStyle(colors.arrow));
            cx += w + step_gap;
        }
        const caps: Keycaps = .init(trigger);
        for (0..caps.count()) |i| {
            if (i > 0) cx += chip_gap;
            const label = caps.get(i);
            const w = chipWidth(canvas, label);
            const rect: d2d.Rect = .{ .x = cx, .y = top, .w = w, .h = chip_height };
            canvas.fillRoundedRect(rect, chip_radius, colors.fill);
            canvas.strokeRoundedRect(rect, chip_radius, colors.border, style.metrics.border_width);
            canvas.drawText(label, rect, chipTextStyle(colors.text));
            cx += w;
        }
    }
    return cx;
}

// -----------------------------------------------------------------------
// Key presses
// -----------------------------------------------------------------------

const MAPVK_VK_TO_CHAR: u32 = 2;
const MAPVK_VK_TO_VSC_EX: u32 = 4;
extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;

/// The action a single-key binding of `set` performs for the virtual key
/// `vk` with `mods`, matched like the core matches key events: by the
/// physical key, then by the unshifted character of the key. Leader keys
/// and chained bindings are not considered.
pub fn actionForKey(set: *const Binding.Set, vk: u16, mods: input.Mods) ?Binding.Action {
    var t: Trigger = .{ .mods = mods.binding() };

    const scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
    if (scan != 0) {
        for (input.keycodes.entries) |entry| {
            if (entry.native != scan or entry.key == .unidentified) continue;
            t.key = .{ .physical = entry.key };
            if (leafAction(set, t)) |action| return action;
            break;
        }
    }

    const char = MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0x7FFF;
    if (char >= 0x20) {
        const cp: u21 = @intCast(if (char >= 'A' and char <= 'Z') char + 32 else char);
        t.key = .{ .unicode = cp };
        if (leafAction(set, t)) |action| return action;
    }
    return null;
}

fn leafAction(set: *const Binding.Set, t: Trigger) ?Binding.Action {
    const entry = set.get(t) orelse return null;
    return switch (entry.value_ptr.*) {
        .leaf => |leaf| leaf.action,
        .leader, .leaf_chained => null,
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
    try testing.expectEqualStrings("Win+Num +", format(.{
        .key = .{ .physical = .numpad_add },
        .mods = .{ .super = true },
    }, &buf));
    try testing.expectEqualStrings("Ctrl+\u{00E4}", format(.{
        .key = .{ .unicode = 0xE4 },
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

test "formatSequence joins the steps with arrows" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+A \u{2192} N", formatSequence(&.{
        .{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } },
        .{ .key = .{ .unicode = 'n' } },
    }, &buf));
}

test "Keycaps lists the modifiers in order" {
    const testing = std.testing;
    const caps: Keycaps = .init(.{
        .key = .{ .physical = .slash },
        .mods = .{ .shift = true, .ctrl = true, .super = true },
    });
    try testing.expectEqual(@as(usize, 4), caps.count());
    try testing.expectEqualStrings("Win", caps.get(0));
    try testing.expectEqualStrings("Ctrl", caps.get(1));
    try testing.expectEqualStrings("Shift", caps.get(2));
    try testing.expectEqualStrings("/", caps.get(3));
}
