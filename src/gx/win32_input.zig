//! win32-input-mode (DECSET 9001): key input as Win32 KEY_EVENT_RECORDs.
//!
//! ConPTY requests this mode from the terminal when it starts
//! (`CSI ? 9001 h`, and `CSI ? 9001 l` when it shuts down) so console
//! programs receive the key events the classic console delivered: every
//! press and release, modifier keys included, with virtual-key code, scan
//! code and control key state. Programs reading VT input from the console
//! (herdr, for example) can request it too. While the mode is on, each key
//! event is sent as
//!
//!     CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _
//!
//! with the KEY_EVENT_RECORD fields wVirtualKeyCode, wVirtualScanCode,
//! uChar.UnicodeChar (one UTF-16 code unit per record), bKeyDown,
//! dwControlKeyState and wRepeatCount. Like Windows Terminal
//! (microsoft/terminal doc/specs "#4999 - Improved keyboard handling in
//! Conpty", `TerminalInput::_makeWin32Output`) all six parameters are
//! always written in decimal, and the kitty keyboard protocol wins over
//! this mode while kitty flags are active, since ConPTY never turns
//! win32-input-mode off.
//!
//! Only the apprt has the Win32 message data, so the core switches encodings
//! only for key events that `Surface.gxWin32KeyCallback` delivers together
//! with their `KeyMessage` (or as text input). Apprts that keep calling
//! `Surface.keyCallback` keep the regular encodings even with the mode on,
//! so typing never depends on the integration.
//!
//! The Windows apprt integration (src/apprt/win32/Surface.zig):
//!
//! - WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP (`handleKeyEvent`):
//!   after the VK_PROCESSKEY and VK_PACKET early returns, read
//!   `GetKeyboardState` for every message, modifier keys and releases
//!   included, and build a `KeyMessage` with `vk = wParam`, `lparam`,
//!   `down` (true for the KEYDOWN messages, repeats included) and
//!   `state = .fromKeyboardState(&keyboard_state)`. `text` is the raw
//!   UTF-16 output of the ToUnicode call the apprt already makes for
//!   presses (`utf16_buf[0..result]` when result > 0), control characters
//!   included: Ctrl+C must report Uc = 3 even though the core key event
//!   carries no text for it. A negative result is a dead key: set `dead`,
//!   its record has Uc = 0. For releases, translate without consuming the
//!   dead-key state (ToUnicode wFlags bit 2, 0x4) or leave `text` empty.
//!   Then call `core_surface.gxWin32KeyCallback(event, message)` instead
//!   of `keyCallback(event)`.
//! - WM_CHAR (`handleCharEvent`) and IME results (`sendImeText`): call
//!   `gxWin32KeyCallback(event, null)`; the text becomes VK = 0 records, a
//!   press and a release per UTF-16 code unit. Pastes and dropped files
//!   stay raw text, as in Windows Terminal.
//! - Nothing else: the records go to the pty through the regular
//!   `Surface.queueIo` path, so bindings, KAM, read-only mode,
//!   scroll-to-bottom and selection clearing behave as for any key.
const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const global = @import("../global.zig");
const Surface = @import("../Surface.zig");

const WriteReq = termio.Message.WriteReq;

/// The low word of KEY_EVENT_RECORD.dwControlKeyState, which holds every
/// flag a key record uses. Windows Terminal writes only these 16 bits and
/// ConPTY clamps larger parameters to 65535.
pub const ControlKeyState = packed struct(u16) {
    /// RIGHT_ALT_PRESSED (0x0001). AltGr is RIGHT_ALT_PRESSED together
    /// with LEFT_CTRL_PRESSED.
    right_alt: bool = false,
    /// LEFT_ALT_PRESSED (0x0002)
    left_alt: bool = false,
    /// RIGHT_CTRL_PRESSED (0x0004)
    right_ctrl: bool = false,
    /// LEFT_CTRL_PRESSED (0x0008)
    left_ctrl: bool = false,
    /// SHIFT_PRESSED (0x0010)
    shift: bool = false,
    /// NUMLOCK_ON (0x0020)
    num_lock: bool = false,
    /// SCROLLLOCK_ON (0x0040)
    scroll_lock: bool = false,
    /// CAPSLOCK_ON (0x0080)
    caps_lock: bool = false,
    /// ENHANCED_KEY (0x0100): the extended-key flag of the key message.
    enhanced_key: bool = false,
    _padding: u7 = 0,

    pub fn int(self: ControlKeyState) u16 {
        return @bitCast(self);
    }

    /// The state the console host derives for a key message, from the
    /// `GetKeyboardState` array read while handling that message: a set
    /// high bit means pressed, a set low bit means toggled on.
    pub fn fromKeyboardState(state: *const [256]u8) ControlKeyState {
        return .{
            .right_alt = state[vk_rmenu] & 0x80 != 0,
            .left_alt = state[vk_lmenu] & 0x80 != 0,
            .right_ctrl = state[vk_rcontrol] & 0x80 != 0,
            .left_ctrl = state[vk_lcontrol] & 0x80 != 0,
            .shift = state[vk_shift] & 0x80 != 0,
            .num_lock = state[vk_numlock] & 0x01 != 0,
            .scroll_lock = state[vk_scroll] & 0x01 != 0,
            .caps_lock = state[vk_capital] & 0x01 != 0,
        };
    }

    /// An approximation from core modifiers, for input that has no key
    /// message. Mods track one side per modifier and no scroll lock.
    pub fn fromMods(mods: input.Mods) ControlKeyState {
        return .{
            .right_alt = mods.alt and mods.sides.alt == .right,
            .left_alt = mods.alt and mods.sides.alt == .left,
            .right_ctrl = mods.ctrl and mods.sides.ctrl == .right,
            .left_ctrl = mods.ctrl and mods.sides.ctrl == .left,
            .shift = mods.shift,
            .num_lock = mods.num_lock,
            .caps_lock = mods.caps_lock,
        };
    }

    const vk_shift = 0x10;
    const vk_capital = 0x14;
    const vk_numlock = 0x90;
    const vk_scroll = 0x91;
    const vk_lcontrol = 0xA2;
    const vk_rcontrol = 0xA3;
    const vk_lmenu = 0xA4;
    const vk_rmenu = 0xA5;
};

/// One KEY_EVENT_RECORD.
pub const KeyRecord = struct {
    /// wVirtualKeyCode; 0 for text without a key (WM_CHAR, IME results).
    vk: u16 = 0,
    /// wVirtualScanCode, without the extended-key prefix.
    sc: u16 = 0,
    /// uChar.UnicodeChar: a single UTF-16 code unit, 0 for none.
    uc: u16 = 0,
    /// bKeyDown
    down: bool = false,
    /// dwControlKeyState
    cs: ControlKeyState = .{},
    /// wRepeatCount
    rc: u16 = 1,
};

/// The longest encoding of a single record.
pub const max_record_len = max: {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    encodeRecord(&discarding.writer, .{
        .vk = std.math.maxInt(u16),
        .sc = std.math.maxInt(u16),
        .uc = std.math.maxInt(u16),
        .down = true,
        .cs = @bitCast(@as(u16, std.math.maxInt(u16))),
        .rc = std.math.maxInt(u16),
    }) catch unreachable;
    break :max discarding.count;
};

/// Write `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _` for one record.
pub fn encodeRecord(
    writer: *std.Io.Writer,
    rec: KeyRecord,
) std.Io.Writer.Error!void {
    try writer.print("\x1b[{d};{d};{d};{d};{d};{d}_", .{
        rec.vk,
        rec.sc,
        rec.uc,
        @intFromBool(rec.down),
        rec.cs.int(),
        rec.rc,
    });
}

/// A WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP or WM_SYSKEYUP message, with the
/// keyboard state and translation the apprt read while handling it.
pub const KeyMessage = struct {
    /// wParam: the virtual-key code.
    vk: u16,

    /// lParam: repeat count (bits 0-15), scan code (bits 16-23) and the
    /// extended-key flag (bit 24).
    lparam: isize,

    /// True for WM_KEYDOWN and WM_SYSKEYDOWN, auto-repeat included.
    down: bool,

    /// Modifier and lock state, usually `ControlKeyState.fromKeyboardState`.
    /// `enhanced_key` is taken from `lparam` and ignored here.
    state: ControlKeyState,

    /// The UTF-16 code units ToUnicode produced for this key, control
    /// characters included; empty if it produced none.
    text: []const u16 = &.{},

    /// ToUnicode reported a dead key. Its record has Uc = 0.
    dead: bool = false,

    pub fn repeatCount(self: KeyMessage) u16 {
        const count: u16 = @truncate(self.bits());
        return @max(count, 1);
    }

    pub fn scanCode(self: KeyMessage) u16 {
        return @as(u8, @truncate(self.bits() >> 16));
    }

    pub fn extended(self: KeyMessage) bool {
        return (self.bits() >> 24) & 1 != 0;
    }

    /// The records for this message: one per UTF-16 code unit of `text`,
    /// or a single record with Uc = 0.
    pub fn records(self: KeyMessage) Records {
        return .{ .message = self };
    }

    fn bits(self: KeyMessage) usize {
        return @bitCast(self.lparam);
    }

    pub const Records = struct {
        message: KeyMessage,
        index: usize = 0,

        pub fn next(self: *Records) ?KeyRecord {
            const msg = self.message;
            const units: []const u16 = if (msg.dead) &.{} else msg.text;
            if (self.index >= @max(units.len, 1)) return null;
            defer self.index += 1;

            var cs = msg.state;
            cs.enhanced_key = msg.extended();
            return .{
                .vk = msg.vk,
                .sc = msg.scanCode(),
                .uc = if (units.len == 0) 0 else units[self.index],
                .down = msg.down,
                .cs = cs,
                .rc = msg.repeatCount(),
            };
        }
    };
};

/// Write every record of a key message.
pub fn encodeKeyMessage(
    writer: *std.Io.Writer,
    msg: KeyMessage,
) std.Io.Writer.Error!void {
    var it = msg.records();
    while (it.next()) |rec| try encodeRecord(writer, rec);
}

/// Write text that arrived without a key (WM_CHAR, IME results) as VK = 0
/// records: a press and a release for each UTF-16 code unit, so a
/// character outside the BMP is a high and then a low surrogate. Invalid
/// UTF-8 is replaced with U+FFFD.
pub fn encodeText(
    writer: *std.Io.Writer,
    utf8: []const u8,
    cs: ControlKeyState,
) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < utf8.len) {
        const cp: u21, const len: usize = decode: {
            const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch
                break :decode .{ std.unicode.replacement_character, 1 };
            if (i + len > utf8.len) break :decode .{ std.unicode.replacement_character, 1 };
            const cp = std.unicode.utf8Decode(utf8[i..][0..len]) catch
                break :decode .{ std.unicode.replacement_character, 1 };
            break :decode .{ cp, len };
        };
        i += len;

        var units: [2]u16 = undefined;
        const unit_count: usize = if (cp < 0x10000) one: {
            units[0] = @intCast(cp);
            break :one 1;
        } else two: {
            const v = cp - 0x10000;
            units[0] = @intCast(0xD800 + (v >> 10));
            units[1] = @intCast(0xDC00 + (v & 0x3FF));
            break :two 2;
        };

        for (units[0..unit_count]) |unit| {
            for ([_]bool{ true, false }) |down| try encodeRecord(writer, .{
                .uc = unit,
                .down = down,
                .cs = cs,
            });
        }
    }
}

/// The Win32 description of the key event passing through
/// `Surface.keyCallback`, set by `Surface.gxWin32KeyCallback`.
pub const Pending = struct {
    key: input.Key,
    action: input.Action,

    /// The key message behind the event, or null for text input.
    message: ?KeyMessage,

    /// Bindings can emit other key events while one is being processed,
    /// for example releases when focus moves away; only the event the
    /// message describes may use it.
    pub fn matches(self: Pending, event: input.KeyEvent) bool {
        return self.key == event.key and self.action == event.action;
    }
};

/// Write the records for `event` described by `pending`. Returns false,
/// having written nothing, if the regular key encoding applies instead.
pub fn encodeEvent(
    writer: *std.Io.Writer,
    pending: Pending,
    event: input.KeyEvent,
) std.Io.Writer.Error!bool {
    if (!pending.matches(event)) return false;
    if (pending.message) |msg| {
        try encodeKeyMessage(writer, msg);
        return true;
    }

    // Text input: only presses carry text.
    if (event.utf8.len == 0 or event.action == .release) return false;
    try encodeText(writer, event.utf8, .fromMods(event.mods));
    return true;
}

/// Whether key input to `t` has to be win32-input-mode records.
pub fn active(t: *const terminal.Terminal) bool {
    return t.modes.get(.win32_input_mode) and
        t.screens.active.kitty_keyboard.current().int() == 0;
}

/// `encodeEvent` into a pty write request; null for the regular encoding.
pub fn writeReq(
    alloc: Allocator,
    pending: Pending,
    event: input.KeyEvent,
) Allocator.Error!?WriteReq {
    var data: WriteReq.Small.Array = undefined;
    var fixed: std.Io.Writer = .fixed(&data);
    if (encodeEvent(&fixed, pending, event)) |encoded| {
        if (!encoded) return null;
        return .{ .small = .{ .data = data, .len = @intCast(fixed.end) } };
    } else |err| switch (err) {
        // Too large for a small request.
        error.WriteFailed => {},
    }

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const encoded = encodeEvent(&buf.writer, pending, event) catch
        return error.OutOfMemory;
    if (!encoded) return null;
    return .{ .alloc = .{ .alloc = alloc, .data = try buf.toOwnedSlice() } };
}

/// The pty bytes for `event` if the surface has to send it as
/// win32-input-mode records; null to use the regular key encoding.
pub fn surfaceWriteReq(
    surface: *Surface,
    event: input.KeyEvent,
) Allocator.Error!?WriteReq {
    const pending = surface.gx_win32_key orelse return null;
    if (!pending.matches(event)) return null;

    // Nothing reads the records once the child is gone, and the regular
    // encoding decides which key closes the surface then.
    if (surface.child_exited) return null;

    {
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        if (!active(&surface.io.terminal)) return null;
    }

    return try writeReq(surface.alloc, pending, event);
}

const testing = std.testing;

fn expectMessage(expected: []const u8, msg: KeyMessage) !void {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeKeyMessage(&writer, msg);
    try testing.expectEqualStrings(expected, writer.buffered());
}

fn keyLParam(scan_code: u8, extended: bool, down: bool, repeat: u16) isize {
    var bits: usize = repeat;
    bits |= @as(usize, scan_code) << 16;
    if (extended) bits |= 1 << 24;
    if (!down) bits |= (1 << 30) | (1 << 31);
    return @bitCast(bits);
}

test "ControlKeyState uses the Win32 flag values" {
    try testing.expectEqual(@as(u16, 0x0001), (ControlKeyState{ .right_alt = true }).int());
    try testing.expectEqual(@as(u16, 0x0002), (ControlKeyState{ .left_alt = true }).int());
    try testing.expectEqual(@as(u16, 0x0004), (ControlKeyState{ .right_ctrl = true }).int());
    try testing.expectEqual(@as(u16, 0x0008), (ControlKeyState{ .left_ctrl = true }).int());
    try testing.expectEqual(@as(u16, 0x0010), (ControlKeyState{ .shift = true }).int());
    try testing.expectEqual(@as(u16, 0x0020), (ControlKeyState{ .num_lock = true }).int());
    try testing.expectEqual(@as(u16, 0x0040), (ControlKeyState{ .scroll_lock = true }).int());
    try testing.expectEqual(@as(u16, 0x0080), (ControlKeyState{ .caps_lock = true }).int());
    try testing.expectEqual(@as(u16, 0x0100), (ControlKeyState{ .enhanced_key = true }).int());
}

test "encodeRecord writes all six parameters" {
    var buf: [max_record_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeRecord(&writer, .{});
    try testing.expectEqualStrings("\x1b[0;0;0;0;0;1_", writer.buffered());

    writer = .fixed(&buf);
    const max = std.math.maxInt(u16);
    try encodeRecord(&writer, .{
        .vk = max,
        .sc = max,
        .uc = max,
        .down = true,
        .cs = @bitCast(@as(u16, max)),
        .rc = max,
    });
    try testing.expectEqualStrings("\x1b[65535;65535;65535;1;65535;65535_", writer.buffered());
    try testing.expectEqual(buf.len, writer.buffered().len);
}

test "Ctrl+C is the C key with Uc 3 and LEFT_CTRL_PRESSED" {
    // The vector GX Zsh's herdr probe injects for Ctrl+C.
    var buf: [2 * max_record_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    for ([_]bool{ true, false }) |down| try encodeKeyMessage(&writer, .{
        .vk = 'C',
        .lparam = keyLParam(0x2E, false, down, 1),
        .down = down,
        .state = .{ .left_ctrl = true },
        .text = &.{0x03},
    });
    try testing.expectEqualStrings(
        "\x1b[67;46;3;1;8;1_\x1b[67;46;3;0;8;1_",
        writer.buffered(),
    );
}

test "Shift+A matches the win32-input-mode specification" {
    // doc/specs/#4999: the four records of typing a capital A.
    try expectMessage("\x1b[16;42;0;1;16;1_", .{
        .vk = 0x10,
        .lparam = keyLParam(0x2A, false, true, 1),
        .down = true,
        .state = .{ .shift = true },
    });
    try expectMessage("\x1b[65;30;65;1;16;1_", .{
        .vk = 'A',
        .lparam = keyLParam(0x1E, false, true, 1),
        .down = true,
        .state = .{ .shift = true },
        .text = &.{'A'},
    });
    try expectMessage("\x1b[16;42;0;0;0;1_", .{
        .vk = 0x10,
        .lparam = keyLParam(0x2A, false, false, 1),
        .down = false,
        .state = .{},
    });
    try expectMessage("\x1b[65;30;97;0;0;1_", .{
        .vk = 'A',
        .lparam = keyLParam(0x1E, false, false, 1),
        .down = false,
        .state = .{},
        .text = &.{'a'},
    });
}

test "Ctrl+F1 with NumLock matches the specification" {
    const ctrl_numlock: ControlKeyState = .{ .left_ctrl = true, .num_lock = true };
    try expectMessage("\x1b[17;29;0;1;40;1_", .{
        .vk = 0x11,
        .lparam = keyLParam(0x1D, false, true, 1),
        .down = true,
        .state = ctrl_numlock,
    });
    try expectMessage("\x1b[112;59;0;1;40;1_", .{
        .vk = 0x70,
        .lparam = keyLParam(0x3B, false, true, 1),
        .down = true,
        .state = ctrl_numlock,
    });
    try expectMessage("\x1b[17;29;0;0;32;1_", .{
        .vk = 0x11,
        .lparam = keyLParam(0x1D, false, false, 1),
        .down = false,
        .state = .{ .num_lock = true },
    });
}

test "AltGr reports RIGHT_ALT_PRESSED with LEFT_CTRL_PRESSED" {
    // AltGr+Q on a German layout types '@'.
    var keyboard_state = [_]u8{0} ** 256;
    keyboard_state[0x11] = 0x80; // VK_CONTROL
    keyboard_state[0x12] = 0x80; // VK_MENU
    keyboard_state[0xA2] = 0x80; // VK_LCONTROL
    keyboard_state[0xA5] = 0x80; // VK_RMENU
    const state: ControlKeyState = .fromKeyboardState(&keyboard_state);
    try testing.expectEqual(
        ControlKeyState{ .right_alt = true, .left_ctrl = true },
        state,
    );
    try expectMessage("\x1b[81;16;64;1;9;1_", .{
        .vk = 'Q',
        .lparam = keyLParam(0x10, false, true, 1),
        .down = true,
        .state = state,
        .text = &.{'@'},
    });
}

test "fromKeyboardState reads pressed and toggled bits" {
    var keyboard_state = [_]u8{0} ** 256;
    keyboard_state[0x10] = 0x81; // VK_SHIFT, pressed (toggle bit ignored)
    keyboard_state[0x14] = 0x01; // VK_CAPITAL toggled
    keyboard_state[0x90] = 0x81; // VK_NUMLOCK toggled (press bit ignored)
    keyboard_state[0x91] = 0x01; // VK_SCROLL toggled
    keyboard_state[0xA3] = 0x80; // VK_RCONTROL
    keyboard_state[0xA4] = 0x01; // VK_LMENU toggled only: not pressed
    try testing.expectEqual(ControlKeyState{
        .right_ctrl = true,
        .shift = true,
        .num_lock = true,
        .scroll_lock = true,
        .caps_lock = true,
    }, ControlKeyState.fromKeyboardState(&keyboard_state));
}

test "fromMods maps sides and lock keys" {
    try testing.expectEqual(
        ControlKeyState{ .right_alt = true, .left_ctrl = true, .caps_lock = true },
        ControlKeyState.fromMods(.{
            .ctrl = true,
            .alt = true,
            .caps_lock = true,
            .sides = .{ .alt = .right },
        }),
    );
    try testing.expectEqual(
        ControlKeyState{ .left_alt = true, .right_ctrl = true, .shift = true, .num_lock = true },
        ControlKeyState.fromMods(.{
            .shift = true,
            .ctrl = true,
            .alt = true,
            .num_lock = true,
            .sides = .{ .ctrl = .right, .shift = .right },
        }),
    );
}

test "extended keys set ENHANCED_KEY" {
    try expectMessage("\x1b[39;77;0;1;256;1_", .{
        .vk = 0x27, // VK_RIGHT
        .lparam = keyLParam(0x4D, true, true, 1),
        .down = true,
        .state = .{},
    });
}

test "repeat counts come from lParam" {
    try expectMessage("\x1b[65;30;97;1;0;3_", .{
        .vk = 'A',
        .lparam = keyLParam(0x1E, false, true, 3),
        .down = true,
        .state = .{},
        .text = &.{'a'},
    });

    // A zero count, possible for posted messages, is still one key event.
    try expectMessage("\x1b[65;30;97;1;0;1_", .{
        .vk = 'A',
        .lparam = keyLParam(0x1E, false, true, 0),
        .down = true,
        .state = .{},
        .text = &.{'a'},
    });

    // lParam bits above the scan code do not leak into it.
    const msg: KeyMessage = .{
        .vk = 'A',
        .lparam = keyLParam(0x1E, true, false, 1) | (1 << 29),
        .down = false,
        .state = .{},
    };
    try testing.expectEqual(@as(u16, 0x1E), msg.scanCode());
    try testing.expect(msg.extended());
    try testing.expectEqual(@as(u16, 1), msg.repeatCount());
}

test "dead keys report Uc 0" {
    // '^' on a German layout is a dead key; ToUnicode returns -1 and the
    // spacing accent, which the record does not carry.
    try expectMessage("\x1b[220;41;0;1;0;1_", .{
        .vk = 0xDC, // VK_OEM_5
        .lparam = keyLParam(0x29, false, true, 1),
        .down = true,
        .state = .{},
        .text = &.{'^'},
        .dead = true,
    });
}

test "each UTF-16 code unit gets its own record" {
    // A layout key that types U+1F600 sends the surrogate pair as two
    // records of the same key.
    const pair = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F600}");
    try testing.expectEqual(@as(usize, 2), pair.len);
    try expectMessage(
        "\x1b[65;30;55357;1;0;1_\x1b[65;30;56832;1;0;1_",
        .{
            .vk = 'A',
            .lparam = keyLParam(0x1E, false, true, 1),
            .down = true,
            .state = .{},
            .text = pair,
        },
    );
}

test "text input is VK 0 presses and releases per code unit" {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeText(&writer, "a\u{4F60}\u{1F600}", .{});
    try testing.expectEqualStrings(
        "\x1b[0;0;97;1;0;1_\x1b[0;0;97;0;0;1_" ++
            "\x1b[0;0;20320;1;0;1_\x1b[0;0;20320;0;0;1_" ++
            "\x1b[0;0;55357;1;0;1_\x1b[0;0;55357;0;0;1_" ++
            "\x1b[0;0;56832;1;0;1_\x1b[0;0;56832;0;0;1_",
        writer.buffered(),
    );

    // Invalid and truncated UTF-8 become U+FFFD.
    writer = .fixed(&buf);
    try encodeText(&writer, "\xff\xe4\xbd", .{ .shift = true });
    try testing.expectEqualStrings(
        "\x1b[0;0;65533;1;16;1_\x1b[0;0;65533;0;16;1_" ++
            "\x1b[0;0;65533;1;16;1_\x1b[0;0;65533;0;16;1_" ++
            "\x1b[0;0;65533;1;16;1_\x1b[0;0;65533;0;16;1_",
        writer.buffered(),
    );
}

test "encodeEvent only describes the pending event" {
    var buf: [256]u8 = undefined;
    const message: KeyMessage = .{
        .vk = 'C',
        .lparam = keyLParam(0x2E, false, true, 1),
        .down = true,
        .state = .{ .left_ctrl = true },
        .text = &.{0x03},
    };
    const pending: Pending = .{ .key = .key_c, .action = .press, .message = message };

    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expect(try encodeEvent(&writer, pending, .{
        .key = .key_c,
        .action = .press,
        .mods = .{ .ctrl = true },
    }));
    try testing.expectEqualStrings("\x1b[67;46;3;1;8;1_", writer.buffered());

    // A release synthesized while the press is processed keeps the regular
    // encoding.
    writer = .fixed(&buf);
    try testing.expect(!try encodeEvent(&writer, pending, .{
        .key = .key_c,
        .action = .release,
    }));
    try testing.expect(!try encodeEvent(&writer, pending, .{
        .key = .control_left,
        .action = .press,
    }));
    try testing.expectEqual(@as(usize, 0), writer.end);
}

test "encodeEvent sends text input as VK 0 records" {
    var buf: [256]u8 = undefined;
    const pending: Pending = .{ .key = .unidentified, .action = .press, .message = null };

    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expect(try encodeEvent(&writer, pending, .{ .utf8 = "x" }));
    try testing.expectEqualStrings("\x1b[0;0;120;1;0;1_\x1b[0;0;120;0;0;1_", writer.buffered());

    // Without text there is nothing to describe.
    writer = .fixed(&buf);
    try testing.expect(!try encodeEvent(&writer, pending, .{}));
    try testing.expect(!try encodeEvent(&writer, .{
        .key = .unidentified,
        .action = .release,
        .message = null,
    }, .{ .action = .release, .utf8 = "x" }));
    try testing.expectEqual(@as(usize, 0), writer.end);
}

test "writeReq uses a small request when the records fit" {
    const alloc = testing.allocator;
    const pending: Pending = .{ .key = .key_c, .action = .press, .message = .{
        .vk = 'C',
        .lparam = keyLParam(0x2E, false, true, 1),
        .down = true,
        .state = .{ .left_ctrl = true },
        .text = &.{0x03},
    } };

    const req = (try writeReq(alloc, pending, .{ .key = .key_c })).?;
    defer req.deinit();
    try testing.expect(req == .small);
    try testing.expectEqualStrings("\x1b[67;46;3;1;8;1_", req.slice());

    try testing.expectEqual(null, try writeReq(alloc, pending, .{ .key = .key_d }));
}

test "writeReq allocates for long text input" {
    const alloc = testing.allocator;
    const pending: Pending = .{ .key = .unidentified, .action = .press, .message = null };
    const text = "\u{4F60}\u{597D}" ** 8;

    const req = (try writeReq(alloc, pending, .{ .utf8 = text })).?;
    defer req.deinit();
    try testing.expect(req == .alloc);

    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    try encodeText(&expected.writer, text, .{});
    try testing.expectEqualStrings(expected.written(), req.slice());
}

test "active follows mode 9001 and yields to the kitty keyboard protocol" {
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(testing.allocator);

    try testing.expect(!active(&t));
    t.modes.set(.win32_input_mode, true);
    try testing.expect(active(&t));

    t.screens.active.kitty_keyboard.push(.{ .disambiguate = true });
    try testing.expect(!active(&t));
    t.screens.active.kitty_keyboard.pop(1);
    try testing.expect(active(&t));

    t.modes.set(.win32_input_mode, false);
    try testing.expect(!active(&t));
}
