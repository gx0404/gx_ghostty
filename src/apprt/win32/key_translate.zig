//! Shared Windows physical-key decoder. Returned slices borrow State until
//! the next decode. TranslateMessage must skip ordinary keys for both backends,
//! but must still process VK_PROCESSKEY and VK_PACKET.
const std = @import("std");
const input = @import("../../input.zig");
const w32 = @import("win32.zig");
const wstr = @import("ui/wstr.zig");
const gx_win32_input = @import("../../gx/win32_input.zig");
const tounicode_keep_state: u32 = 0x4;
pub const Decoded = struct {
    event: input.KeyEvent,
    message: gx_win32_input.KeyMessage,
    preedit_changed: bool,
    preedit: ?[]const u8,
    ime_release: bool,
    produced_text: bool,
};
pub const State = struct {
    utf8: [16]u8 = undefined,
    key_utf16: [4]u16 = undefined,
    ime_keys: std.StaticBitSet(256) = .initEmpty(),
    dead_key_preedit: bool = false,
    key_event_produced_text: bool = false,
    pub fn reset(self: *State) void {
        self.ime_keys = .initEmpty();
        self.dead_key_preedit = false;
        self.key_event_produced_text = false;
    }
    pub fn decode(self: *State, wparam: usize, lparam: isize, action: input.Action) ?Decoded {
        const vk: u16 = @intCast(wparam & 0xFFFF);
        if (action == .press) self.key_event_produced_text = false;
        // Bits 16-23 of lparam. Bit 24 is the extended-key flag, not part of
        // the scancode; including it broke ToUnicode for AltGr layouts
        // (German, Polish) and arrow/numpad keys.
        const scancode: u8 = @truncate(@as(usize, @bitCast(lparam)) >> 16);

        // When the IME is active, physical key presses arrive as VK_PROCESSKEY.
        // The IME will produce the composed text via WM_IME_COMPOSITION — skip
        // the key event so we don't feed garbage to the terminal. The release
        // of such a key can still arrive with its real virtual-key code;
        // remember the key so that release is not reported on its own.
        if (vk == w32.VK_PROCESSKEY) {
            self.ime_keys.setValue(scancode, action == .press);
            return null;
        }
        if (action == .press) self.ime_keys.unset(scancode);

        // VK_PACKET is sent by SendInput with KEYEVENTF_UNICODE (used by
        // accessibility tools, on-screen keyboards, and Unicode injection).
        // The actual character follows as WM_CHAR — don't set the
        // key_event_produced_text flag so WM_CHAR is allowed through.
        if (vk == w32.VK_PACKET) return null;

        // Determine left/right for modifier keys using the extended key flag
        // (bit 24 of lparam) and specific left/right VK codes.
        const extended = (lparam & (1 << 24)) != 0;

        const key = mapVirtualKey(vk, extended);

        // Build modifier state
        const mods = getModifiers();

        // Check if the key is a repeat (bit 30 of lparam is set for KEYDOWN
        // if the key was already down).
        const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
            input.Action.repeat
        else
            action;

        // Try to get the unshifted codepoint for this key
        const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;

        // Use ToUnicode to translate the key press into UTF-16 text,
        // then convert to UTF-8 for the key event. Only for press/repeat.
        const utf8_buf = &self.utf8;
        var preedit_changed = false;
        var preedit: ?[]const u8 = null;
        var utf8_text: []const u8 = "";
        var consumed_mods: input.Mods = .{};
        // The modifier set actually encoded into the key event. AltGr handling
        // below may clear ctrl+alt on this copy without disturbing `mods`.
        var event_mods = mods;

        // The modifier and lock state for this message, read for every key
        // (modifiers and releases included) as the console host would.
        var keyboard_state: [256]u8 = undefined;
        const have_keyboard_state = w32.GetKeyboardState(&keyboard_state) != 0;
        if (!have_keyboard_state) @memset(&keyboard_state, 0);
        var message: gx_win32_input.KeyMessage = .{
            .vk = vk,
            .lparam = lparam,
            .down = action == .press,
            .state = .fromKeyboardState(&keyboard_state),
        };

        if (have_keyboard_state and !isModifierVk(vk)) {
            // ToUnicode's raw UTF-16 output, control characters included, is
            // the record's character. The buffer lives in the surface so the
            // message never points into a finished call.
            const utf16_buf = &self.key_utf16;
            if (actual_action == .press or actual_action == .repeat) {
                // App.run skips TranslateMessage for surface keyboard messages,
                // so this ToUnicode call owns the per-queue dead-key state.
                // result>0 means composed text (including composition with a
                // previously pending dead key); result<0 means VK is itself a
                // dead key and ToUnicode just stored it for the next call.
                const result = w32.ToUnicode(
                    @intCast(vk),
                    scancode,
                    &keyboard_state,
                    utf16_buf,
                    utf16_buf.len,
                    0,
                );
                if (result < 0) {
                    message.dead = true;
                    self.dead_key_preedit = true;
                    const text = wstr.utf8Buf(utf8_buf, utf16_buf[0..@min(@as(usize, @intCast(@abs(result))), utf16_buf.len)]);
                    preedit_changed = true;
                    preedit = if (text.len == 0) null else text;
                } else if (result > 0 or vk == w32.VK_ESCAPE or vk == w32.VK_BACK) {
                    if (self.dead_key_preedit) preedit_changed = true;
                    self.dead_key_preedit = false;
                }
                if (result > 0) {
                    const utf16_slice = utf16_buf[0..@min(@as(usize, @intCast(result)), utf16_buf.len)];
                    message.text = utf16_slice;
                    // Skip Ctrl-induced control chars (0x01-0x1A): the core
                    // handles modifier combos via key + mods, and emitting
                    // the control char here would double-encode.
                    if (utf16_slice[0] >= 0x20) {
                        const len = std.unicode.utf16LeToUtf8(utf8_buf, utf16_slice) catch 0;
                        if (len > 0) {
                            utf8_text = utf8_buf[0..len];
                            if (mods.shift) consumed_mods.shift = true;
                            self.key_event_produced_text = true;
                            // AltGr layouts: Windows reports AltGr as
                            // Left-Ctrl+Right-Alt. When that combination itself
                            // produced printable text (e.g. German AltGr+Q '@',
                            // AltGr+8 '['), strip ctrl+alt from the ENCODED mods.
                            // The core key encoder reads raw event.mods and would
                            // otherwise turn the literal into a C0/CSIu control
                            // sequence. Gate on the right-Alt physically being down
                            // so genuine Ctrl+Alt chords are left untouched.
                            if (mods.ctrl and mods.alt and
                                (keyboard_state[w32.VK_RMENU] & 0x80) != 0)
                            {
                                event_mods.ctrl = false;
                                event_mods.alt = false;
                                consumed_mods.ctrl = true;
                                consumed_mods.alt = true;
                            }
                        }
                    }
                }
            } else {
                // A release record carries the key's character too. Translate
                // without changing the keyboard state, so a pending dead key
                // survives for the next press.
                const result = w32.ToUnicode(
                    @intCast(vk),
                    scancode,
                    &keyboard_state,
                    utf16_buf,
                    utf16_buf.len,
                    tounicode_keep_state,
                );
                if (result < 0) message.dead = true;
                if (result > 0) message.text = utf16_buf[0..@intCast(result)];
            }
        }

        const event = input.KeyEvent{
            .action = actual_action,
            .key = key,
            .mods = event_mods,
            .consumed_mods = consumed_mods,
            .composing = message.dead,
            .utf8 = utf8_text,
            .unshifted_codepoint = unshifted_codepoint,
        };

        const ime_release = action == .release and self.ime_keys.isSet(scancode);
        if (ime_release) self.ime_keys.unset(scancode);
        return .{ .event = event, .message = message, .preedit_changed = preedit_changed, .preedit = preedit, .ime_release = ime_release, .produced_text = self.key_event_produced_text };
    }
};

/// Get the current keyboard modifier state from Win32.
pub fn getModifiers() input.Mods {
    var mods: input.Mods = .{};

    // GetKeyState returns a value where the high bit indicates the key
    // is currently down.
    if (w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0) {
        mods.shift = true;
        // Determine which shift key is pressed
        if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0) {
            mods.sides.shift = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
        mods.ctrl = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0) {
            mods.sides.ctrl = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) {
        mods.alt = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0) {
            mods.sides.alt = .right;
        }
    }

    // Check super (Windows key)
    if (w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0)
    {
        mods.super = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) {
            mods.sides.super = .right;
        }
    }

    // Lock keys (low bit indicates toggle state)
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0) {
        mods.caps_lock = true;
    }
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0) {
        mods.num_lock = true;
    }

    return mods;
}

/// True for VKs that on their own never produce a character (Shift, Ctrl,
/// Alt, Win, lock keys). Calling ToUnicode for these is wasted at best and
/// can perturb the kernel's per-thread keyboard state at worst (in
/// particular, ToUnicode buffers any pending dead key into kernel state
/// even when the result is unused).
fn isModifierVk(vk: u16) bool {
    return switch (vk) {
        w32.VK_SHIFT,
        w32.VK_LSHIFT,
        w32.VK_RSHIFT,
        w32.VK_CONTROL,
        w32.VK_LCONTROL,
        w32.VK_RCONTROL,
        w32.VK_MENU,
        w32.VK_LMENU,
        w32.VK_RMENU,
        w32.VK_LWIN,
        w32.VK_RWIN,
        w32.VK_CAPITAL,
        w32.VK_NUMLOCK,
        w32.VK_SCROLL,
        => true,
        else => false,
    };
}

/// Map a Win32 virtual key code to a Ghostty input.Key.
pub fn mapVirtualKey(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        // Letter keys (A-Z: 0x41-0x5A)
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        // Number keys (0-9: 0x30-0x39)
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        // Function keys
        w32.VK_F1 => .f1,
        w32.VK_F2 => .f2,
        w32.VK_F3 => .f3,
        w32.VK_F4 => .f4,
        w32.VK_F5 => .f5,
        w32.VK_F6 => .f6,
        w32.VK_F7 => .f7,
        w32.VK_F8 => .f8,
        w32.VK_F9 => .f9,
        w32.VK_F10 => .f10,
        w32.VK_F11 => .f11,
        w32.VK_F12 => .f12,
        w32.VK_F13 => .f13,
        w32.VK_F14 => .f14,
        w32.VK_F15 => .f15,
        w32.VK_F16 => .f16,
        w32.VK_F17 => .f17,
        w32.VK_F18 => .f18,
        w32.VK_F19 => .f19,
        w32.VK_F20 => .f20,
        w32.VK_F21 => .f21,
        w32.VK_F22 => .f22,
        w32.VK_F23 => .f23,
        w32.VK_F24 => .f24,

        // Navigation / editing keys
        w32.VK_RETURN => if (extended) .numpad_enter else .enter,
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_END => .end,
        w32.VK_HOME => .home,
        w32.VK_LEFT => .arrow_left,
        w32.VK_UP => .arrow_up,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_DOWN => .arrow_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,

        // Modifier keys
        w32.VK_LSHIFT => .shift_left,
        w32.VK_RSHIFT => .shift_right,
        w32.VK_LCONTROL => .control_left,
        w32.VK_RCONTROL => .control_right,
        w32.VK_LMENU => .alt_left,
        w32.VK_RMENU => .alt_right,
        w32.VK_LWIN => .meta_left,
        w32.VK_RWIN => .meta_right,
        w32.VK_SHIFT => if (extended) .shift_right else .shift_left,
        w32.VK_CONTROL => if (extended) .control_right else .control_left,
        w32.VK_MENU => if (extended) .alt_right else .alt_left,

        // Lock keys
        w32.VK_CAPITAL => .caps_lock,
        w32.VK_NUMLOCK => .num_lock,
        w32.VK_SCROLL => .scroll_lock,

        // OEM keys (US keyboard layout)
        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,
        w32.VK_OEM_102 => .intl_backslash,

        // Numpad keys
        w32.VK_NUMPAD0 => .numpad_0,
        w32.VK_NUMPAD1 => .numpad_1,
        w32.VK_NUMPAD2 => .numpad_2,
        w32.VK_NUMPAD3 => .numpad_3,
        w32.VK_NUMPAD4 => .numpad_4,
        w32.VK_NUMPAD5 => .numpad_5,
        w32.VK_NUMPAD6 => .numpad_6,
        w32.VK_NUMPAD7 => .numpad_7,
        w32.VK_NUMPAD8 => .numpad_8,
        w32.VK_NUMPAD9 => .numpad_9,
        w32.VK_MULTIPLY => .numpad_multiply,
        w32.VK_ADD => .numpad_add,
        w32.VK_SEPARATOR => .numpad_separator,
        w32.VK_SUBTRACT => .numpad_subtract,
        w32.VK_DECIMAL => .numpad_decimal,
        w32.VK_DIVIDE => .numpad_divide,

        // Misc
        w32.VK_APPS => .context_menu,
        w32.VK_PAUSE => .pause,

        else => .unidentified,
    };
}
