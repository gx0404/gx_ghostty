//! Keyboard shortcuts that never reach Ghostty GX: chords another program
//! registered as a global hotkey (RegisterHotKey) and the preserved keys
//! of the active input method (TSF). Windows hands neither to the focused
//! window.
//!
//! `App` probes the configured keybindings after the first window is up
//! and after every configuration reload: `candidates` lists the first
//! chord of each binding that has a modifier, without Ghostty GX's own
//! `global:` hotkeys and the chords Windows reserves but still delivers
//! (Alt+F4, the F12 debugger keys); `probe` registers each one on the
//! message-only window and unregisters it at once, where
//! ERROR_HOTKEY_ALREADY_REGISTERED means another program holds it, and
//! asks the GUI thread's TSF keystroke manager for the input method's
//! preserved keys (`ITfKeystrokeMgr::GetPreservedKey`). An input method
//! registers those only once it is active on the thread, and keys its
//! keystroke sink eats are not among them: Microsoft Pinyin's
//! Ctrl+Shift+F (simplified/traditional) is not a preserved key, so it is
//! not found.
//!
//! The results (`Conflicts`) mark the bindings in the keyboard shortcut
//! sheet, keep their hints out of the menus (`ui/trigger.zig::Hints`) and
//! decide the one-time notice (`noticeBindings`, `ui/ShortcutNotice.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const w32 = @import("win32.zig");

const Binding = input.Binding;
const Trigger = Binding.Trigger;

const log = std.log.scoped(.win32);

/// Why a chord never reaches Ghostty GX.
pub const Reason = enum {
    /// Another program registered it as a global hotkey.
    hotkey,
    /// The active input method keeps it (a TSF preserved key).
    ime,
};

/// A key chord as RegisterHotKey takes it.
pub const Chord = struct {
    /// `MOD_ALT`, `MOD_CONTROL`, `MOD_SHIFT` and `MOD_WIN` bits.
    mods: u32,
    vk: u8,

    pub fn eql(self: Chord, other: Chord) bool {
        return self.mods == other.mods and self.vk == other.vk;
    }
};

pub const Conflict = struct {
    chord: Chord,
    reason: Reason,
};

/// The chords a probe found taken.
pub const Conflicts = struct {
    list: std.ArrayList(Conflict) = .empty,

    pub fn deinit(self: *Conflicts, alloc: Allocator) void {
        self.list.deinit(alloc);
        self.* = .{};
    }

    /// Why `trigger` never reaches Ghostty GX, or null when nothing
    /// takes it.
    pub fn reason(self: *const Conflicts, trigger: Trigger) ?Reason {
        const chord = chordOf(trigger) orelse return null;
        for (self.list.items) |conflict| {
            if (conflict.chord.eql(chord)) return conflict.reason;
        }
        return null;
    }

    /// Why a key sequence (leader keys first) never starts: the reason of
    /// its first chord.
    pub fn sequenceReason(self: *const Conflicts, sequence: []const Trigger) ?Reason {
        if (sequence.len == 0) return null;
        return self.reason(sequence[0]);
    }
};

/// The chord of `trigger`, or null when its key has no fixed virtual key.
/// Physical keys map by position and characters like on the US layout
/// (letters, digits and the unshifted punctuation keys).
pub fn chordOf(trigger: Trigger) ?Chord {
    const vk = switch (trigger.key) {
        .physical => |key| physicalVk(key),
        .unicode => |cp| unicodeVk(cp),
        .catch_all => null,
    } orelse return null;
    var mods: u32 = 0;
    if (trigger.mods.alt) mods |= w32.MOD_ALT;
    if (trigger.mods.ctrl) mods |= w32.MOD_CONTROL;
    if (trigger.mods.shift) mods |= w32.MOD_SHIFT;
    if (trigger.mods.super) mods |= w32.MOD_WIN;
    return .{ .mods = mods, .vk = vk };
}

fn unicodeVk(cp: u21) ?u8 {
    return switch (cp) {
        'a'...'z' => @intCast(cp - 'a' + 'A'),
        'A'...'Z', '0'...'9' => @intCast(cp),
        ' ' => w32.VK_SPACE,
        ';' => w32.VK_OEM_1,
        '=' => w32.VK_OEM_PLUS,
        ',' => w32.VK_OEM_COMMA,
        '-' => w32.VK_OEM_MINUS,
        '.' => w32.VK_OEM_PERIOD,
        '/' => w32.VK_OEM_2,
        '`' => w32.VK_OEM_3,
        '[' => w32.VK_OEM_4,
        '\\' => w32.VK_OEM_5,
        ']' => w32.VK_OEM_6,
        '\'' => w32.VK_OEM_7,
        else => null,
    };
}

/// The virtual key of a physical key (US positions), or null.
pub fn physicalVk(key: input.Key) ?u8 {
    return switch (key) {
        .key_a => 'A',
        .key_b => 'B',
        .key_c => 'C',
        .key_d => 'D',
        .key_e => 'E',
        .key_f => 'F',
        .key_g => 'G',
        .key_h => 'H',
        .key_i => 'I',
        .key_j => 'J',
        .key_k => 'K',
        .key_l => 'L',
        .key_m => 'M',
        .key_n => 'N',
        .key_o => 'O',
        .key_p => 'P',
        .key_q => 'Q',
        .key_r => 'R',
        .key_s => 'S',
        .key_t => 'T',
        .key_u => 'U',
        .key_v => 'V',
        .key_w => 'W',
        .key_x => 'X',
        .key_y => 'Y',
        .key_z => 'Z',
        .digit_0 => '0',
        .digit_1 => '1',
        .digit_2 => '2',
        .digit_3 => '3',
        .digit_4 => '4',
        .digit_5 => '5',
        .digit_6 => '6',
        .digit_7 => '7',
        .digit_8 => '8',
        .digit_9 => '9',
        .backquote => w32.VK_OEM_3,
        .minus => w32.VK_OEM_MINUS,
        .equal => w32.VK_OEM_PLUS,
        .bracket_left => w32.VK_OEM_4,
        .bracket_right => w32.VK_OEM_6,
        .backslash => w32.VK_OEM_5,
        .semicolon => w32.VK_OEM_1,
        .quote => w32.VK_OEM_7,
        .comma => w32.VK_OEM_COMMA,
        .period => w32.VK_OEM_PERIOD,
        .slash => w32.VK_OEM_2,
        .enter => w32.VK_RETURN,
        .tab => w32.VK_TAB,
        .space => w32.VK_SPACE,
        .backspace => w32.VK_BACK,
        .escape => w32.VK_ESCAPE,
        .insert => w32.VK_INSERT,
        .delete => w32.VK_DELETE,
        .home => w32.VK_HOME,
        .end => w32.VK_END,
        .page_up => w32.VK_PRIOR,
        .page_down => w32.VK_NEXT,
        .arrow_left => w32.VK_LEFT,
        .arrow_up => w32.VK_UP,
        .arrow_right => w32.VK_RIGHT,
        .arrow_down => w32.VK_DOWN,
        .f1 => w32.VK_F1,
        .f2 => w32.VK_F2,
        .f3 => w32.VK_F3,
        .f4 => w32.VK_F4,
        .f5 => w32.VK_F5,
        .f6 => w32.VK_F6,
        .f7 => w32.VK_F7,
        .f8 => w32.VK_F8,
        .f9 => w32.VK_F9,
        .f10 => w32.VK_F10,
        .f11 => w32.VK_F11,
        .f12 => w32.VK_F12,
        .f13 => w32.VK_F13,
        .f14 => w32.VK_F14,
        .f15 => w32.VK_F15,
        .f16 => w32.VK_F16,
        .f17 => w32.VK_F17,
        .f18 => w32.VK_F18,
        .f19 => w32.VK_F19,
        .f20 => w32.VK_F20,
        .f21 => w32.VK_F21,
        .f22 => w32.VK_F22,
        .f23 => w32.VK_F23,
        .f24 => w32.VK_F24,
        else => null,
    };
}

/// Chords Windows reserves as hotkeys of its own (RegisterHotKey reports
/// them taken) but still delivers to the focused window: Alt+F4, which
/// closes the window through DefWindowProc, and F12 and Shift+F12, the
/// debugger keys.
fn deliveredBySystem(chord: Chord) bool {
    return switch (chord.vk) {
        w32.VK_F4 => chord.mods == w32.MOD_ALT,
        w32.VK_F12 => chord.mods == 0 or chord.mods == w32.MOD_SHIFT,
        else => false,
    };
}

fn contains(chords: []const Chord, chord: Chord) bool {
    for (chords) |c| if (c.eql(chord)) return true;
    return false;
}

/// The chords of `set` worth probing, each once: the first chord of every
/// binding (key sequences included, `ignore` left out) that has a
/// modifier and a virtual key, except `own` (Ghostty GX's registered
/// global hotkeys) and the chords Windows delivers although it reserves
/// them.
pub fn candidates(
    alloc: Allocator,
    set: *const Binding.Set,
    own: []const Chord,
) Allocator.Error!std.ArrayList(Chord) {
    var list: std.ArrayList(Chord) = .empty;
    errdefer list.deinit(alloc);
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .leaf => |leaf| if (leaf.action == .ignore) continue,
            .leader, .leaf_chained => {},
        }
        const chord = chordOf(entry.key_ptr.*) orelse continue;
        if (chord.mods == 0 or deliveredBySystem(chord)) continue;
        if (contains(own, chord) or contains(list.items, chord)) continue;
        try list.append(alloc, chord);
    }
    return list;
}

/// A binding the notice names (`noticeBindings`).
pub const Affected = struct {
    trigger: Trigger,
    reason: Reason,
};

/// Whether a taken default binding of `action` deserves the notice:
/// copying, pasting, searching and splitting.
fn noticeAction(action: Binding.Action) bool {
    return switch (action) {
        .copy_to_clipboard,
        .paste_from_clipboard,
        .paste_from_selection,
        .start_search,
        .search_selection,
        .new_split,
        => true,
        else => false,
    };
}

/// The bindings of `set` the notice names, one per chord: those that copy,
/// paste, search or split, are bound as in `defaults` (the built-in
/// keybindings) and whose chord is taken.
pub fn noticeBindings(
    alloc: Allocator,
    set: *const Binding.Set,
    defaults: *const Binding.Set,
    conflicts: *const Conflicts,
) Allocator.Error!std.ArrayList(Affected) {
    var list: std.ArrayList(Affected) = .empty;
    errdefer list.deinit(alloc);
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leaf => |leaf| leaf,
            .leader, .leaf_chained => continue,
        };
        if (!noticeAction(leaf.action)) continue;
        const builtin_binding = defaults.get(entry.key_ptr.*) orelse continue;
        switch (builtin_binding.value_ptr.*) {
            .leaf => |d| if (!d.action.equal(leaf.action)) continue,
            .leader, .leaf_chained => continue,
        }
        const r = conflicts.reason(entry.key_ptr.*) orelse continue;
        const chord = chordOf(entry.key_ptr.*).?;
        const seen = for (list.items) |affected| {
            if (chordOf(affected.trigger).?.eql(chord)) break true;
        } else false;
        if (!seen) try list.append(alloc, .{ .trigger = entry.key_ptr.*, .reason = r });
    }
    return list;
}

/// Log a warning for every binding of `set` whose first chord is taken.
pub fn logConflicts(set: *const Binding.Set, conflicts: *const Conflicts) void {
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const r = conflicts.reason(entry.key_ptr.*) orelse continue;
        const why = switch (r) {
            .hotkey => "another program registered it as a global hotkey",
            .ime => "the input method keeps it (TSF preserved key)",
        };
        switch (entry.value_ptr.*) {
            .leaf => |leaf| log.warn(
                "keybind {f}={f} does not reach Ghostty GX: {s}",
                .{ entry.key_ptr.*, leaf.action, why },
            ),
            .leaf_chained => |chained| log.warn(
                "keybind {f} ({d} chained actions) does not reach Ghostty GX: {s}",
                .{ entry.key_ptr.*, chained.actions.items.len, why },
            ),
            .leader => log.warn(
                "key sequences starting with {f} do not reach Ghostty GX: {s}",
                .{ entry.key_ptr.*, why },
            ),
        }
    }
}

// -----------------------------------------------------------------------
// Probing (GUI thread)
// -----------------------------------------------------------------------

const ERROR_HOTKEY_ALREADY_REGISTERED: u32 = 1409;

/// The hotkey id of a probe, apart from the ids of the global hotkeys.
const probe_id: i32 = 0xBFFF;

extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// Probe `chords` (from `candidates`) on the GUI thread: a chord another
/// program registered as a hotkey, else one the thread's input method
/// preserves, is a conflict. `hwnd` receives a WM_HOTKEY if the chord is
/// pressed in the instant it is registered.
pub fn probe(alloc: Allocator, hwnd: ?w32.HWND, chords: []const Chord) Allocator.Error!Conflicts {
    var result: Conflicts = .{};
    errdefer result.deinit(alloc);
    var ime: PreservedKeys = .open();
    defer ime.close();
    log.debug("probing keybinding chords count={} tsf_keystroke={} tsf_context={}", .{
        chords.len,
        ime.keystroke != null,
        ime.context != null,
    });
    for (chords) |chord| {
        const r: Reason = if (hotkeyTaken(hwnd, chord))
            .hotkey
        else if (ime.has(chord))
            .ime
        else
            continue;
        try result.list.append(alloc, .{ .chord = chord, .reason = r });
    }
    return result;
}

fn hotkeyTaken(hwnd: ?w32.HWND, chord: Chord) bool {
    if (w32.RegisterHotKey(hwnd, probe_id, chord.mods | w32.MOD_NOREPEAT, chord.vk) != 0) {
        _ = w32.UnregisterHotKey(hwnd, probe_id);
        return false;
    }
    const err = GetLastError();
    if (err == ERROR_HOTKEY_ALREADY_REGISTERED) return true;
    log.debug("cannot probe hotkey mods=0x{x} vk=0x{x} err={}", .{ chord.mods, chord.vk, err });
    return false;
}

/// The preserved keys of the input method active on the calling thread,
/// read through its TSF thread manager. Empty when the thread has none.
const PreservedKeys = struct {
    keystroke: ?*ITfKeystrokeMgr = null,
    context: ?*ITfContext = null,

    fn open() PreservedKeys {
        var thread: ?*ITfThreadMgr = null;
        if (TF_GetThreadMgr(&thread) < 0) return .{};
        const tim = thread orelse return .{};
        defer _ = tim.vtable.Release(tim);

        var keystroke: ?*anyopaque = null;
        if (tim.vtable.QueryInterface(tim, &IID_ITfKeystrokeMgr, &keystroke) < 0) return .{};
        return .{
            .keystroke = @ptrCast(@alignCast(keystroke orelse return .{})),
            .context = topContext(tim),
        };
    }

    fn close(self: *PreservedKeys) void {
        if (self.context) |context| _ = context.vtable.Release(context);
        if (self.keystroke) |keystroke| _ = keystroke.vtable.Release(keystroke);
        self.* = .{};
    }

    /// Whether the input method preserves `chord`. TSF knows no Win key.
    fn has(self: *const PreservedKeys, chord: Chord) bool {
        const keystroke = self.keystroke orelse return false;
        if (chord.mods & w32.MOD_WIN != 0) return false;
        const key: TF_PRESERVEDKEY = .{
            .uVKey = chord.vk,
            .uModifiers = chord.mods & (TF_MOD_ALT | TF_MOD_CONTROL | TF_MOD_SHIFT),
        };
        var guid: w32.GUID = std.mem.zeroes(w32.GUID);
        const hr = keystroke.vtable.GetPreservedKey(keystroke, self.context, &key, &guid);
        return hr == 0 and !std.meta.eql(guid, std.mem.zeroes(w32.GUID));
    }

    /// The top context of the focused document manager, else of the first
    /// one that has a context.
    fn topContext(tim: *ITfThreadMgr) ?*ITfContext {
        var focus: ?*ITfDocumentMgr = null;
        if (tim.vtable.GetFocus(tim, &focus) >= 0) if (focus) |dim| {
            defer _ = dim.vtable.Release(dim);
            var context: ?*ITfContext = null;
            if (dim.vtable.GetTop(dim, &context) >= 0) if (context) |c| return c;
        };

        var list: ?*IEnumTfDocumentMgrs = null;
        if (tim.vtable.EnumDocumentMgrs(tim, &list) < 0) return null;
        const docs = list orelse return null;
        defer _ = docs.vtable.Release(docs);
        while (true) {
            var next: ?*ITfDocumentMgr = null;
            var fetched: u32 = 0;
            if (docs.vtable.Next(docs, 1, &next, &fetched) != 0 or fetched == 0) return null;
            const dim = next orelse return null;
            defer _ = dim.vtable.Release(dim);
            var context: ?*ITfContext = null;
            if (dim.vtable.GetTop(dim, &context) >= 0) if (context) |c| return c;
        }
    }
};

// Text Services Framework (msctf.h), only the methods used above; later
// vtable entries are left out.

const TF_MOD_ALT: u32 = 0x0001;
const TF_MOD_CONTROL: u32 = 0x0002;
const TF_MOD_SHIFT: u32 = 0x0004;

const TF_PRESERVEDKEY = extern struct {
    uVKey: u32,
    uModifiers: u32,
};

// {AA80E7F0-2021-11D2-93E0-0060B067B86E}
const IID_ITfKeystrokeMgr: w32.GUID = .{
    .Data1 = 0xAA80E7F0,
    .Data2 = 0x2021,
    .Data3 = 0x11D2,
    .Data4 = .{ 0x93, 0xE0, 0x00, 0x60, 0xB0, 0x67, 0xB8, 0x6E },
};

extern "msctf" fn TF_GetThreadMgr(pptim: *?*ITfThreadMgr) callconv(.winapi) w32.HRESULT;

const Unused = *const anyopaque;

const ITfThreadMgr = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*ITfThreadMgr, *const w32.GUID, *?*anyopaque) callconv(.winapi) w32.HRESULT,
        AddRef: *const fn (*ITfThreadMgr) callconv(.winapi) u32,
        Release: *const fn (*ITfThreadMgr) callconv(.winapi) u32,
        Activate: Unused,
        Deactivate: Unused,
        CreateDocumentMgr: Unused,
        EnumDocumentMgrs: *const fn (*ITfThreadMgr, *?*IEnumTfDocumentMgrs) callconv(.winapi) w32.HRESULT,
        GetFocus: *const fn (*ITfThreadMgr, *?*ITfDocumentMgr) callconv(.winapi) w32.HRESULT,
    },
};

const ITfDocumentMgr = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*ITfDocumentMgr) callconv(.winapi) u32,
        Release: *const fn (*ITfDocumentMgr) callconv(.winapi) u32,
        CreateContext: Unused,
        Push: Unused,
        Pop: Unused,
        GetTop: *const fn (*ITfDocumentMgr, *?*ITfContext) callconv(.winapi) w32.HRESULT,
    },
};

const IEnumTfDocumentMgrs = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*IEnumTfDocumentMgrs) callconv(.winapi) u32,
        Release: *const fn (*IEnumTfDocumentMgrs) callconv(.winapi) u32,
        Clone: Unused,
        Next: *const fn (*IEnumTfDocumentMgrs, u32, *?*ITfDocumentMgr, ?*u32) callconv(.winapi) w32.HRESULT,
    },
};

const ITfContext = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*ITfContext) callconv(.winapi) u32,
        Release: *const fn (*ITfContext) callconv(.winapi) u32,
    },
};

const ITfKeystrokeMgr = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: *const fn (*ITfKeystrokeMgr) callconv(.winapi) u32,
        Release: *const fn (*ITfKeystrokeMgr) callconv(.winapi) u32,
        AdviseKeyEventSink: Unused,
        UnadviseKeyEventSink: Unused,
        GetForeground: Unused,
        TestKeyDown: Unused,
        TestKeyUp: Unused,
        KeyDown: Unused,
        KeyUp: Unused,
        GetPreservedKey: *const fn (*ITfKeystrokeMgr, ?*ITfContext, *const TF_PRESERVEDKEY, *w32.GUID) callconv(.winapi) w32.HRESULT,
    },
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "chordOf maps modifiers and keys" {
    const ctrl_shift = w32.MOD_CONTROL | w32.MOD_SHIFT;
    try testing.expectEqual(Chord{ .mods = ctrl_shift, .vk = 'C' }, chordOf(.{
        .key = .{ .unicode = 'c' },
        .mods = .{ .ctrl = true, .shift = true },
    }).?);
    try testing.expectEqual(Chord{ .mods = ctrl_shift, .vk = 'C' }, chordOf(.{
        .key = .{ .physical = .key_c },
        .mods = .{ .ctrl = true, .shift = true },
    }).?);
    try testing.expectEqual(Chord{ .mods = ctrl_shift, .vk = w32.VK_OEM_2 }, chordOf(.{
        .key = .{ .physical = .slash },
        .mods = .{ .ctrl = true, .shift = true },
    }).?);
    try testing.expectEqual(Chord{ .mods = w32.MOD_CONTROL | w32.MOD_WIN, .vk = w32.VK_OEM_4 }, chordOf(.{
        .key = .{ .unicode = '[' },
        .mods = .{ .ctrl = true, .super = true },
    }).?);
    try testing.expectEqual(Chord{ .mods = w32.MOD_SHIFT, .vk = w32.VK_INSERT }, chordOf(.{
        .key = .{ .physical = .insert },
        .mods = .{ .shift = true },
    }).?);
    try testing.expectEqual(Chord{ .mods = w32.MOD_ALT, .vk = '1' }, chordOf(.{
        .key = .{ .unicode = '1' },
        .mods = .{ .alt = true },
    }).?);
    // Shifted characters and keys without a fixed virtual key.
    try testing.expectEqual(@as(?Chord, null), chordOf(.{ .key = .{ .unicode = '+' }, .mods = .{ .ctrl = true } }));
    try testing.expectEqual(@as(?Chord, null), chordOf(.{ .key = .{ .physical = .paste } }));
    try testing.expectEqual(@as(?Chord, null), chordOf(.{ .key = .catch_all, .mods = .{ .ctrl = true } }));
}

test "candidates take the first chord of bindings with modifiers once" {
    const alloc = testing.allocator;
    var set: Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "ctrl+shift+c=copy_to_clipboard");
    try set.parseAndPut(alloc, "ctrl+shift+key_c=copy_to_clipboard");
    try set.parseAndPut(alloc, "ctrl+a>n=new_window");
    try set.parseAndPut(alloc, "ctrl+a>t=new_tab");
    try set.parseAndPut(alloc, "f1=new_tab");
    try set.parseAndPut(alloc, "alt+f4=close_window");
    try set.parseAndPut(alloc, "shift+f12=new_tab");
    try set.parseAndPut(alloc, "ctrl+shift+x=ignore");
    try set.parseAndPut(alloc, "ctrl+grave_accent=toggle_quick_terminal");
    try set.parseAndPut(alloc, "ctrl+`=toggle_quick_terminal");
    try set.parseAndPut(alloc, "ctrl+shift+o=new_split:right");

    const own = [_]Chord{.{ .mods = w32.MOD_CONTROL, .vk = w32.VK_OEM_3 }};
    var list = try candidates(alloc, &set, &own);
    defer list.deinit(alloc);

    const ctrl_shift = w32.MOD_CONTROL | w32.MOD_SHIFT;
    try testing.expectEqualSlices(Chord, &.{
        .{ .mods = ctrl_shift, .vk = 'C' },
        .{ .mods = w32.MOD_CONTROL, .vk = 'A' },
        .{ .mods = ctrl_shift, .vk = 'O' },
    }, list.items);
}

test "Conflicts answer by trigger and sequence" {
    const alloc = testing.allocator;
    var conflicts: Conflicts = .{};
    defer conflicts.deinit(alloc);
    try conflicts.list.append(alloc, .{ .chord = .{ .mods = w32.MOD_CONTROL | w32.MOD_SHIFT, .vk = 'C' }, .reason = .hotkey });
    try conflicts.list.append(alloc, .{ .chord = .{ .mods = w32.MOD_CONTROL | w32.MOD_SHIFT, .vk = 'F' }, .reason = .ime });

    try testing.expectEqual(@as(?Reason, .hotkey), conflicts.reason(try Trigger.parse("ctrl+shift+key_c")));
    try testing.expectEqual(@as(?Reason, .hotkey), conflicts.reason(try Trigger.parse("ctrl+shift+c")));
    try testing.expectEqual(@as(?Reason, .ime), conflicts.reason(try Trigger.parse("ctrl+shift+f")));
    try testing.expectEqual(@as(?Reason, null), conflicts.reason(try Trigger.parse("ctrl+c")));
    try testing.expectEqual(@as(?Reason, null), conflicts.reason(try Trigger.parse("ctrl+insert")));

    const leader = try Trigger.parse("ctrl+shift+c");
    const next = try Trigger.parse("n");
    try testing.expectEqual(@as(?Reason, .hotkey), conflicts.sequenceReason(&.{ leader, next }));
    try testing.expectEqual(@as(?Reason, null), conflicts.sequenceReason(&.{ next, leader }));
    try testing.expectEqual(@as(?Reason, null), conflicts.sequenceReason(&.{}));
}

test "noticeBindings names taken default bindings that copy, paste, search or split" {
    const alloc = testing.allocator;
    var defaults: Binding.Set = .{};
    defer defaults.deinit(alloc);
    try defaults.parseAndPut(alloc, "ctrl+shift+c=copy_to_clipboard");
    try defaults.parseAndPut(alloc, "ctrl+shift+o=new_split:right");
    try defaults.parseAndPut(alloc, "ctrl+shift+f=start_search");
    try defaults.parseAndPut(alloc, "ctrl+shift+n=new_window");
    try defaults.parseAndPut(alloc, "ctrl+shift+e=new_split:down");

    var set: Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "ctrl+shift+c=copy_to_clipboard");
    try set.parseAndPut(alloc, "ctrl+shift+key_c=copy_to_clipboard");
    try set.parseAndPut(alloc, "ctrl+shift+o=new_split:right");
    try set.parseAndPut(alloc, "ctrl+shift+f=start_search");
    // Taken, but not copy, paste, search or split.
    try set.parseAndPut(alloc, "ctrl+shift+n=new_window");
    // Taken, but configured by the user.
    try set.parseAndPut(alloc, "ctrl+shift+e=new_split:left");
    // Free.
    try set.parseAndPut(alloc, "ctrl+shift+v=paste_from_clipboard");

    var conflicts: Conflicts = .{};
    defer conflicts.deinit(alloc);
    const ctrl_shift = w32.MOD_CONTROL | w32.MOD_SHIFT;
    for ("COFNE", [_]Reason{ .hotkey, .hotkey, .ime, .hotkey, .hotkey }) |vk, r| {
        try conflicts.list.append(alloc, .{ .chord = .{ .mods = ctrl_shift, .vk = vk }, .reason = r });
    }

    var affected = try noticeBindings(alloc, &set, &defaults, &conflicts);
    defer affected.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), affected.items.len);
    try testing.expectEqual(Chord{ .mods = ctrl_shift, .vk = 'C' }, chordOf(affected.items[0].trigger).?);
    try testing.expectEqual(Reason.hotkey, affected.items[0].reason);
    try testing.expectEqual(Chord{ .mods = ctrl_shift, .vk = 'O' }, chordOf(affected.items[1].trigger).?);
    try testing.expectEqual(Chord{ .mods = ctrl_shift, .vk = 'F' }, chordOf(affected.items[2].trigger).?);
    try testing.expectEqual(Reason.ime, affected.items[2].reason);
}
