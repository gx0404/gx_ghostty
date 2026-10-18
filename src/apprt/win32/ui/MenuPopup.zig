//! A custom-drawn popup menu in the Windows 11 style, themed from the
//! terminal colors (`style.Tokens`): the widget behind `ui/Menu.zig`. Each
//! open menu level is a `Popup` window painted with a `d2d.Canvas`, laid
//! out on whole device pixels: rows with an optional icon (or emoji) or a
//! check/radio mark, a label, right-aligned shortcut text and a submenu
//! chevron, separators, section headers and disabled items. The
//! highlighted row gets the hover fill; a row highlighted from the
//! keyboard also gets the accent selection indicator.
//!
//! Build the items with a `Builder` and `run` them. `run` opens the menu
//! below an anchor rectangle (a point is an empty one, `Options.at`), lined
//! up with its left or right edge (`Options.alignment`), above the anchor
//! or flipped to its other edge when it does not fit (`placeRoot`), within
//! the work area of the anchor's monitor and sized for the owner's DPI (or
//! the content scale in `Options.owner_scale`). A menu taller than the
//! work area scrolls: the wheel, the keyboard, and the arrow strips at its
//! ends, which scroll while the pointer rests on them. `run` blocks in a
//! modal message loop until an action is picked (its `Item.id` is
//! returned) or the menu is dismissed (null). The popups of one run are
//! created once per level and reused for every submenu shown at that
//! level; `Popup.show` keeps a popup cloaked until it has painted. Only the
//! main-menu root host is retained hidden per owner between runs; callbacks
//! and models are detached when a session ends. Other menus may only retain
//! their DC canvas and DIB for three seconds.
//!
//! Like a native menu, the menu takes neither activation nor keyboard
//! focus. The loop handles the keyboard itself on the deepest open menu:
//! Up/Down, Home/End, Page Up/Page Down, Enter/Space, Right to open and
//! Left to close a submenu, Escape, Alt/F10, and access keys (`Item.access`,
//! else a letter or digit of the label): the key is underlined in its
//! label while access keys are shown (opened from the keyboard, a key was
//! pressed, or the system always underlines them), and a label without it
//! (a translation) shows it as "(T)" when the menu was opened from the
//! keyboard. A key an input method takes (`VK_PROCESSKEY`) is read back
//! with `ImmGetVirtualKey`, and its composition is canceled when the menu
//! uses the key. Keys that were down when the menu opened do nothing while
//! they stay down (their auto-repeat), and their releases go on to the
//! focused window, which saw them go down.
//!
//! The mouse is routed by screen position while the root popup holds the
//! mouse capture: hovering a submenu item opens it after the system menu
//! show delay; while the pointer heads for an open submenu across other
//! rows of its parent (`inAimTriangle`), the parent keeps its highlight;
//! a parent menu always highlights the item whose submenu the pointer or
//! the keyboard is in (`highlightPath`). A press outside the menus, losing
//! the capture, hiding or minimizing its owner, or a change of the
//! foreground window dismisses the menu.
//! Releasing a button over an item picks it when a button went down inside
//! the menu or the pointer moved since it opened (press, drag, release).
//! Between messages the loop sleeps until the next deadline (the submenu
//! delay, the aim, auto-scrolling), at most `watch_ms`.
//!
//! Without Direct2D, or for screen readers (`preferNative`), `runNative`
//! shows the same items as a native menu (`TrackPopupMenuEx`).
//!
//! Re-entrancy: one menu runs at a time; `run` returns null while another
//! menu is open, and `cancel` closes the open one (for example when the UI
//! language changes). The loop dispatches every other message, so timers,
//! painting and terminal output go on, and a dispatched message can free
//! anything, even the owner: `run` returns null when its owner was
//! destroyed or detached its object meanwhile (windows and terminals clear
//! their GWLP_USERDATA when they go away), and callers re-resolve other
//! pointers after it returns.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../../global.zig");
const perf = @import("../../../gx/perf.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const App = @import("../App.zig");
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const controls = @import("controls.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32_menu);

/// What the leading column of an item shows instead of its icon.
pub const Mark = enum {
    none,
    /// A check mark: a setting that is on.
    check,
    /// A bullet: the chosen one of a group of options.
    radio,
};

pub const Item = struct {
    kind: Kind = .action,
    /// What `run` returns when the item is picked.
    id: usize = 0,
    label: []const u8 = "",
    /// A glyph of the icon font (`d2d.icons`).
    icon: ?u21 = null,
    /// Text in the icon column instead of a glyph, in the UI font (an
    /// emoji).
    icon_text: ?[]const u8 = null,
    mark: Mark = .none,
    /// Right-aligned secondary text, usually a keyboard shortcut.
    shortcut: ?[]const u8 = null,
    enabled: bool = true,
    /// The access key, an ASCII letter or digit; null takes a letter or
    /// digit of the label that no other item of the menu has
    /// (`pickAccessKey`).
    access: ?u8 = null,
    /// The items of a submenu (set by `Builder.submenu`).
    submenu: ?*const List = null,

    pub const Kind = enum { action, submenu, separator, header };

    /// Whether the item can be highlighted and activated.
    fn selectable(self: Item) bool {
        if (!self.enabled) return false;
        return switch (self.kind) {
            .action => true,
            .submenu => if (self.submenu) |list| list.items.items.len > 0 else false,
            .separator, .header => false,
        };
    }
};

/// The items of a menu or submenu.
pub const List = struct {
    items: std.ArrayList(Item) = .empty,
};

/// Builds the items of a menu. All text is copied, so labels and
/// shortcuts can come from temporary buffers.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    root: List = .{},

    pub fn init(alloc: Allocator) Builder {
        return .{ .arena = .init(alloc) };
    }

    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
    }

    /// Append `item` to `list`.
    pub fn add(self: *Builder, list: *List, item: Item) Allocator.Error!void {
        const alloc = self.arena.allocator();
        var copy = item;
        copy.label = try alloc.dupe(u8, item.label);
        if (item.shortcut) |text| copy.shortcut = try alloc.dupe(u8, text);
        if (item.icon_text) |text| copy.icon_text = try alloc.dupe(u8, text);
        if (item.access) |key| copy.access = std.ascii.toUpper(key);
        try list.items.append(alloc, copy);
    }

    pub fn separator(self: *Builder, list: *List) Allocator.Error!void {
        try self.add(list, .{ .kind = .separator });
    }

    /// A section header: a caption above the items that follow.
    pub fn header(self: *Builder, list: *List, label: []const u8) Allocator.Error!void {
        try self.add(list, .{ .kind = .header, .label = label, .enabled = false });
    }

    /// Append a submenu item and return its (empty) item list. A submenu
    /// without items is shown disabled.
    pub fn submenu(self: *Builder, list: *List, item: Item) Allocator.Error!*List {
        const child = try self.arena.allocator().create(List);
        child.* = .{};
        var entry = item;
        entry.kind = .submenu;
        entry.submenu = child;
        try self.add(list, entry);
        return child;
    }
};

/// What a menu is drawn with.
pub const Host = struct {
    app: ?*App = null,
    hinstance: w32.HINSTANCE,
    factory: *d2d.Factory,
    tokens: style.Tokens,
    /// `App.quit_requested`: whether a WM_QUIT the loop retrieves closes
    /// the menu (`Popup.modalQuitCode`).
    quit_requested: *const bool,
};

/// The edge of its anchor a menu lines up with.
pub const Align = enum { left, right };

pub const Options = struct {
    /// What the menu opens at, in screen pixels: below it, or above it
    /// when only that fits, lined up with its `alignment` edge (`placeRoot`).
    /// A point is an empty rectangle (`at`).
    anchor: w32.RECT,
    alignment: Align = .left,
    /// Opened from the keyboard: highlight the first item and show the
    /// access keys.
    keyboard: bool = false,
    /// The owner's content scale (`Window.scale` for the menus of a
    /// window), when the menu follows it (`Popup.setOwnerScale`).
    owner_scale: ?f32 = null,
    /// Only the main menu root supplies a P4 opening measurement.
    open_timing: ?Popup.OpenTiming = null,
    /// Main menu only: one address-stable hidden host per top-level owner.
    reuse_root: bool = false,

    /// The anchor of a menu that opens at a point.
    pub fn at(pt: w32.POINT) w32.RECT {
        return .{ .left = pt.x, .top = pt.y, .right = pt.x, .bottom = pt.y };
    }
};

/// Dismiss the open menu, if any; its `run` (or `runNative`) returns null.
pub fn cancel() void {
    if (current) |state| state.dismiss();
    if (native_open) _ = EndMenu();
}

/// Show the menu `root` for `owner` and run it until it is closed.
/// Returns the id of the picked item, or null when the menu was dismissed,
/// another menu is open or the owner went away.
pub fn run(host: Host, owner: w32.HWND, root: *const List, options: Options) ?usize {
    return runSession(host, owner, root, options, false);
}

/// Prepare the main menu at an event-driven idle boundary, never entering a
/// modal loop or showing/activating its host. Models remain session-owned.
pub fn prepare(host: Host, owner: w32.HWND, root: *const List, options: Options) void {
    _ = runSession(host, owner, root, options, true);
}

fn runSession(host: Host, owner: w32.HWND, root: *const List, options: Options, preparing: bool) ?usize {
    if (current != null or native_open) {
        log.debug("a menu is already open", .{});
        return null;
    }
    if (root.items.items.len == 0) return null;

    var arena: std.heap.ArenaAllocator = .init(host.factory.alloc);
    defer arena.deinit();

    var cursor: w32.POINT = .{ .x = options.anchor.left, .y = options.anchor.bottom };
    _ = w32.GetCursorPos_(&cursor);

    var state: State = .{
        .host = host,
        .owner = owner,
        .uia_attachment = if (host.app) |app| uia_bridge.ownerAttachment(app, owner) orelse .{} else .{},
        .alloc = arena.allocator(),
        .anchor = options.anchor,
        .alignment = options.alignment,
        .owner_scale = options.owner_scale,
        .open_timing = options.open_timing,
        .foreground = w32.GetForegroundWindow(),
        .start_pt = cursor,
        .last_pt = cursor,
        .drag_x = @intCast(@max(w32.GetSystemMetrics(SM_CXDRAG), 1)),
        .drag_y = @intCast(@max(w32.GetSystemMetrics(SM_CYDRAG), 1)),
        .show_delay = menuShowDelay(),
        .held_keys = heldKeys(),
        .cues = options.keyboard or keyboardCues(),
        .suffixes = options.keyboard,
        .preparing = preparing,
        .root_host = if (options.reuse_root) root_hosts.acquire(host.factory.alloc, owner) catch return null else null,
    };
    defer state.destroyPopups();

    current = &state;
    defer current = null;
    if (!state.open(root, null, options.keyboard)) return null;

    if (preparing) return null;

    // The capture keeps WM_SETCURSOR away, so set the menu cursor once.
    if (w32.LoadCursorW(null, w32.IDC_ARROW)) |arrow| _ = w32.SetCursor(arrow);

    state.loop();

    if (!ownerAlive(owner)) return null;
    return switch (state.result) {
        .picked => |id| id,
        .open, .cancelled => null,
    };
}

/// The menu that is running.
var current: ?*State = null;

/// A native menu (`runNative`) is running.
var native_open = false;

/// Address-stable root hosts. A borrowed entry can be retired during a modal
/// dispatch, but must not be freed until that session unwinds.
const RootHosts = struct {
    const Entry = struct {
        next: ?*Entry = null,
        alloc: Allocator,
        owner: w32.HWND,
        popup: Popup = .{},
        borrowed: bool = true,
        retired: bool = false,
    };
    first: ?*Entry = null,

    fn acquire(self: *RootHosts, alloc: Allocator, owner: w32.HWND) !*Entry {
        var it = self.first;
        while (it) |entry| : (it = entry.next) {
            if (entry.owner == owner) {
                if (entry.borrowed or entry.retired) return error.Busy;
                entry.borrowed = true;
                return entry;
            }
        }
        const entry = try alloc.create(Entry);
        entry.* = .{ .alloc = alloc, .owner = owner, .next = self.first };
        self.first = entry;
        return entry;
    }

    fn remove(self: *RootHosts, entry: *Entry) void {
        var link = &self.first;
        while (link.*) |current_entry| : (link = &current_entry.next) {
            if (current_entry != entry) continue;
            link.* = entry.next;
            entry.popup.destroy();
            entry.alloc.destroy(entry);
            return;
        }
    }

    fn release(self: *RootHosts, entry: *Entry) void {
        entry.popup.hide();
        entry.popup.callbacks = null;
        entry.borrowed = false;
        if (entry.retired or entry.popup.reuse_invalid) self.remove(entry);
    }

    fn invalidate(self: *RootHosts, owner: w32.HWND) void {
        var it = self.first;
        while (it) |entry| {
            it = entry.next;
            if (entry.owner != owner) continue;
            if (entry.borrowed) entry.retired = true else self.remove(entry);
        }
    }
};

var root_hosts: RootHosts = .{};

/// Called before an owner is destroyed and on configuration/DPI changes.
/// Modal sessions may still be on the stack: retire, cancel and defer freeing
/// their borrowed root until runSession returns.
pub fn invalidateOwner(owner: w32.HWND) void {
    root_hosts.invalidate(owner);
    if (current) |state| if (state.owner == owner) state.dismiss();
}

test "P4 reuse retains one stable menu root for 100 sessions and retires a borrowed owner" {
    var hosts: RootHosts = .{};
    const owner: w32.HWND = @ptrFromInt(1);
    defer hosts.invalidate(owner);
    const first = try hosts.acquire(std.testing.allocator, owner);
    const address = @intFromPtr(first);
    hosts.release(first);
    try std.testing.expect(hosts.first != null);
    for (0..100) |_| {
        const entry = try hosts.acquire(std.testing.allocator, owner);
        try std.testing.expectEqual(address, @intFromPtr(entry));
        try std.testing.expect(entry.next == null);
        hosts.release(entry);
    }
    const borrowed = try hosts.acquire(std.testing.allocator, owner);
    hosts.invalidate(owner);
    try std.testing.expect(borrowed.retired);
    try std.testing.expectError(error.Busy, hosts.acquire(std.testing.allocator, owner));
    hosts.release(borrowed);
    try std.testing.expect(hosts.first == null);
}

/// Nested submenus beyond this depth do not open.
const max_depth = 4;

const RasterKey = struct {
    factory: usize,
    d2d_factory: usize,

    fn from(factory: *d2d.Factory) RasterKey {
        return .{ .factory = @intFromPtr(factory), .d2d_factory = @intFromPtr(factory.d2d) };
    }
};

const RasterCache = struct {
    canvas: ?d2d.Canvas = null,
    dib: d2d.DibTarget = .{},
    key: ?RasterKey = null,
    timer: usize = 0,
    expires_ms: u64 = 0,

    const lifetime_ms: u32 = 3000;

    fn clear(self: *RasterCache) void {
        self.cancelTimer();
        if (self.canvas) |*canvas| canvas.deinit();
        self.dib.deinit();
        self.* = .{};
    }

    fn cancelTimer(self: *RasterCache) void {
        if (self.timer != 0) _ = w32.KillTimer(null, self.timer);
        self.timer = 0;
    }

    fn capture(self: *RasterCache, popup: *Popup) bool {
        if (popup.composition_requested) return false;
        if (!popup.layered or popup.canvas == null) return false;
        if (popup.canvas.?.drawing) return false;
        self.clear();
        self.key = .from(popup.canvas.?.factory);
        self.canvas = popup.canvas;
        self.dib = popup.dib;
        popup.canvas = null;
        popup.dib = .{};
        return true;
    }

    fn store(self: *RasterCache, popup: *Popup) void {
        if (!self.capture(popup)) return;
        self.expires_ms = GetTickCount64() + lifetime_ms;
        self.timer = w32.SetTimer(null, 0, lifetime_ms, @ptrCast(&expireRaster));
        if (self.timer == 0) self.clear();
    }

    fn restore(self: *RasterCache, popup: *Popup) bool {
        if (popup.composition_requested) return false;
        const saved_key = self.key orelse return false;
        const factory = if (popup.canvas) |canvas| canvas.factory else return false;
        if (!popup.layered or !std.meta.eql(saved_key, RasterKey.from(factory))) {
            self.clear();
            return false;
        }
        self.cancelTimer();
        if (popup.canvas) |*canvas| canvas.deinit();
        popup.dib.deinit();
        popup.canvas = self.canvas;
        popup.dib = self.dib;
        self.* = .{};
        return true;
    }
};

var raster_cache: RasterCache = .{};

fn expireRaster(hwnd: ?w32.HWND, msg: u32, id: usize, time: u32) callconv(.winapi) void {
    _ = hwnd;
    _ = msg;
    _ = time;
    if (raster_cache.timer != id or GetTickCount64() < raster_cache.expires_ms) return;
    raster_cache.clear();
}

/// The longest the loop sleeps without a message before it checks the
/// owner and the foreground window again; activation changes wake it
/// anyway, since they reach the owner.
const watch_ms = 250;

/// How long the pointer may rest in the aim triangle before the row under
/// it takes the highlight.
const aim_ms = 100;

/// Auto-scrolling over an arrow strip moves the content once per frame.
const autoscroll_ms = 16;

const SM_CXDRAG: i32 = 68;
const SM_CYDRAG: i32 = 69;
const SPI_GETMENUSHOWDELAY: u32 = 0x006A;
const SPI_GETKEYBOARDCUES: u32 = 0x100A;
const SPI_GETSCREENREADER: u32 = 0x0046;

const WM_NCMOUSEMOVE: u32 = 0x00A0;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_NCLBUTTONUP: u32 = 0x00A2;
const WM_NCLBUTTONDBLCLK: u32 = 0x00A3;
const WM_NCRBUTTONDOWN: u32 = 0x00A4;
const WM_NCRBUTTONUP: u32 = 0x00A5;
const WM_NCRBUTTONDBLCLK: u32 = 0x00A6;
const WM_NCMBUTTONDOWN: u32 = 0x00A7;
const WM_NCMBUTTONUP: u32 = 0x00A8;
const WM_NCMBUTTONDBLCLK: u32 = 0x00A9;
const WM_NCXBUTTONDOWN: u32 = 0x00AB;
const WM_NCXBUTTONUP: u32 = 0x00AC;
const WM_NCXBUTTONDBLCLK: u32 = 0x00AD;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_MBUTTONDBLCLK: u32 = 0x0209;
const WM_XBUTTONDBLCLK: u32 = 0x020D;
const WM_UNICHAR: u32 = 0x0109;

const NI_COMPOSITIONSTR: u32 = 0x0015;
const CPS_CANCEL: u32 = 0x0004;

extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;
extern "user32" fn EndMenu() callconv(.winapi) i32;
extern "user32" fn GetAncestor(hWnd: w32.HWND, gaFlags: u32) callconv(.winapi) ?w32.HWND;
extern "imm32" fn ImmGetVirtualKey(hWnd: w32.HWND) callconv(.winapi) u32;
extern "imm32" fn ImmNotifyIME(hIMC: w32.HIMC, dwAction: u32, dwIndex: u32, dwValue: u32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;

/// The system delay before a hovered submenu opens (`MenuShowDelay`).
fn menuShowDelay() u64 {
    var delay: u32 = 400;
    if (SystemParametersInfoW(SPI_GETMENUSHOWDELAY, 0, &delay, 0) == 0) return 400;
    return @min(delay, 2000);
}

/// Whether Windows always underlines access keys ("Underline access keys
/// when available").
fn keyboardCues() bool {
    var on: i32 = 0;
    if (SystemParametersInfoW(SPI_GETKEYBOARDCUES, 0, @ptrCast(&on), 0) == 0) return false;
    return on != 0;
}

/// Whether menus should be native (`runNative`): a screen reader is
/// running, or `GHOSTTY_GX_A11Y` names `screen-reader` (to see the native
/// menus without one).
pub fn preferNative() bool {
    var running: i32 = 0;
    if (SystemParametersInfoW(SPI_GETSCREENREADER, 0, @ptrCast(&running), 0) != 0 and running != 0) return true;
    return a11yOverride();
}

var a11y_read = false;
var a11y_screen_reader = false;

fn a11yOverride() bool {
    if (!a11y_read) {
        a11y_read = true;
        var buf: [64]u16 = undefined;
        const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_A11Y"), &buf, buf.len);
        if (n > 0 and n < buf.len) {
            var ascii: [64]u8 = undefined;
            for (buf[0..n], 0..) |unit, i| ascii[i] = if (unit < 0x80) @intCast(unit) else '?';
            a11y_screen_reader = std.ascii.findIgnoreCase(ascii[0..n], "screen-reader") != null;
        }
    }
    return a11y_screen_reader;
}

/// The keys that are down now, from the thread's keyboard state.
fn heldKeys() std.StaticBitSet(256) {
    var keys: std.StaticBitSet(256) = .initEmpty();
    var state: [256]u8 = undefined;
    if (w32.GetKeyboardState(&state) == 0) return keys;
    for (state, 0..) |value, vk| {
        if (value & 0x80 != 0) keys.set(vk);
    }
    return keys;
}

/// Whether `owner` still exists with its object attached.
fn ownerAlive(owner: w32.HWND) bool {
    return w32.GetWindowLongPtrW(owner, w32.GWLP_USERDATA) != 0;
}

fn ownerAvailable(alive: bool, visible: bool, minimized: bool, active: bool) bool {
    return alive and visible and !minimized and active;
}

/// The work area of the monitor nearest to `pt`.
fn workArea(pt: w32.POINT) w32.RECT {
    const screen: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = w32.GetSystemMetrics(0),
        .bottom = w32.GetSystemMetrics(1),
    };
    const monitor = w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST) orelse return screen;
    var info: w32.MONITORINFO = .{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(monitor, &info) == 0) return screen;
    return info.rcWork;
}

var build_number: ?u32 = null;

/// Whether DWM leaves the popups without the 1 px border and the rounded
/// corners of Windows 11 (before build 22000), so the menu draws its own
/// border.
fn ownBorder() bool {
    const build = build_number orelse blk: {
        var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        const value: u32 = if (std.os.windows.ntdll.RtlGetVersion(&info) == .SUCCESS) info.dwBuildNumber else 0;
        build_number = value;
        break :blk value;
    };
    return build != 0 and build < 22000;
}

// -----------------------------------------------------------------------
// Placement, aiming and access keys (pure)
// -----------------------------------------------------------------------

/// Where a root menu `width` × `height` pixels opens for `anchor` (screen
/// pixels; an empty rectangle is a point) within the work area `work`:
/// lined up with the anchor's `alignment` edge, or with its other edge when
/// that would leave the work area; below the anchor, else above it, else
/// (taller than the room on either side) moved into the work area over the
/// anchor. A menu taller than the work area gets its height and scrolls.
pub fn placeRoot(anchor: w32.RECT, width: i32, height: i32, work: w32.RECT, alignment: Align) w32.RECT {
    const h = @min(height, @max(work.bottom - work.top, 0));
    var x = switch (alignment) {
        .left => anchor.left,
        .right => anchor.right - width,
    };
    switch (alignment) {
        .left => if (x + width > work.right) {
            x = anchor.right - width;
        },
        .right => if (x < work.left) {
            x = anchor.left;
        },
    }
    x = clampStart(x, width, work.left, work.right);
    const y = if (anchor.bottom + h <= work.bottom)
        anchor.bottom
    else if (anchor.top - h >= work.top)
        anchor.top - h
    else
        clampStart(anchor.bottom, h, work.top, work.bottom);
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + h };
}

/// Where a submenu `width` × `height` pixels opens beside its parent menu
/// `parent` (screen pixels) for the item whose top is at `item_top`: to the
/// right, overlapping the parent by `overlap`, else to the left; its first
/// row level with the item (`pad` is the space above it); within `work`,
/// and as tall as the work area at most.
pub fn placeSubmenu(parent: w32.RECT, item_top: i32, width: i32, height: i32, work: w32.RECT, overlap: i32, pad: i32) w32.RECT {
    const h = @min(height, @max(work.bottom - work.top, 0));
    var x = parent.right - overlap;
    if (x + width > work.right) x = parent.left + overlap - width;
    x = clampStart(x, width, work.left, work.right);
    const y = clampStart(item_top - pad, h, work.top, work.bottom);
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + h };
}

/// `start` moved so that `start` .. `start + len` lies within `lo` .. `hi`;
/// `lo` when it does not fit.
fn clampStart(start: i32, len: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(start, hi - len));
}

/// Whether the pointer moving from `from` to `to` heads for a submenu
/// whose near edge is the vertical segment at `edge_x` from `top` to
/// `bottom` (screen pixels): `to` lies in the triangle of `from` and the
/// two ends of that edge (its sides included).
pub fn inAimTriangle(from: w32.POINT, to: w32.POINT, edge_x: i32, top: i32, bottom: i32) bool {
    if (from.x == edge_x or bottom <= top) return false;
    if (from.x == to.x and from.y == to.y) return false;
    const a: [2]f32 = .{ @floatFromInt(from.x), @floatFromInt(from.y) };
    const b: [2]f32 = .{ @floatFromInt(edge_x), @floatFromInt(top) };
    const c: [2]f32 = .{ @floatFromInt(edge_x), @floatFromInt(bottom) };
    const p: [2]f32 = .{ @floatFromInt(to.x), @floatFromInt(to.y) };
    const d1 = cross(a, b, p);
    const d2 = cross(b, c, p);
    const d3 = cross(c, a, p);
    const negative = d1 < 0 or d2 < 0 or d3 < 0;
    const positive = d1 > 0 or d2 > 0 or d3 > 0;
    return !(negative and positive);
}

fn cross(o: [2]f32, a: [2]f32, b: [2]f32) f32 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

/// Light the path to menu `active` of `levels` (the open menus, root
/// first): every menu above it highlights the item that opened the next
/// one, so each open menu shows one highlighted row and Left or Escape
/// return to that row. The levels have `parent_item` and
/// `setHot(item, keyboard)`.
fn highlightPath(levels: anytype, active: usize) void {
    if (levels.len == 0) return;
    var i = @min(active, levels.len - 1);
    while (i > 0) : (i -= 1) levels[i - 1].setHot(levels[i].parent_item, false);
}

/// Access keys taken in one menu: a bit per digit, then per letter.
pub const AccessSet = std.StaticBitSet(36);

fn accessBit(key: u8) ?usize {
    return switch (key) {
        '0'...'9' => key - '0',
        'A'...'Z' => 10 + @as(usize, key - 'A'),
        'a'...'z' => 10 + @as(usize, key - 'a'),
        else => null,
    };
}

fn isWordStart(label: []const u8, i: usize) bool {
    return i == 0 or !std.ascii.isAlphanumeric(label[i - 1]);
}

/// The access key a label without one gets: its first ASCII letter or
/// digit that starts a word and is not `used`, else its first one that is
/// not `used`; uppercase.
pub fn pickAccessKey(label: []const u8, used: AccessSet) ?u8 {
    for ([_]bool{ true, false }) |word_start| {
        for (label, 0..) |c, i| {
            const bit = accessBit(c) orelse continue;
            if (used.isSet(bit)) continue;
            if (word_start and !isWordStart(label, i)) continue;
            return std.ascii.toUpper(c);
        }
    }
    return null;
}

/// Where access key `key` is in `label` (bytes): its first occurrence that
/// starts a word, else its first one, ignoring ASCII case; null when the
/// label lacks it.
pub fn accessIndex(label: []const u8, key: u8) ?usize {
    const lower = std.ascii.toLower(key);
    var first: ?usize = null;
    for (label, 0..) |c, i| {
        if (std.ascii.toLower(c) != lower) continue;
        if (isWordStart(label, i)) return i;
        if (first == null) first = i;
    }
    return first;
}

/// A label as drawn with its access key: the text and the byte offset of
/// the key to underline.
pub const Cue = struct {
    text: []const u8,
    underline: ?usize,
};

/// `label` with access key `key`: unchanged when it holds the key; else,
/// with `suffix`, followed by "(K)" (before a trailing ellipsis, as in
/// "设置(S)…"), allocated with `alloc`.
pub fn cueLabel(alloc: Allocator, label: []const u8, key: u8, suffix: bool) Allocator.Error!Cue {
    if (accessIndex(label, key)) |i| return .{ .text = label, .underline = i };
    if (!suffix) return .{ .text = label, .underline = null };
    const ellipses = [_][]const u8{ "\u{2026}", "..." };
    var head = label;
    var tail: []const u8 = "";
    for (ellipses) |ellipsis| {
        if (std.mem.endsWith(u8, label, ellipsis)) {
            head = label[0 .. label.len - ellipsis.len];
            tail = ellipsis;
            break;
        }
    }
    const upper = std.ascii.toUpper(key);
    const text = try std.fmt.allocPrint(alloc, "{s}({c}){s}", .{ head, upper, tail });
    return .{ .text = text, .underline = head.len + 1 };
}

/// What pressing access key `key` does in a menu whose rows have the
/// access keys `keys` (null for rows that cannot be picked) and `hot`
/// highlighted: highlight `item`, and pick it when it is the only row
/// with that key; with several, each press moves to the next one.
pub const AccessHit = struct {
    item: usize,
    unique: bool,
};

pub fn accessTarget(keys: []const ?u8, hot: ?usize, key: u8) ?AccessHit {
    const wanted = std.ascii.toUpper(key);
    var first: ?usize = null;
    var after_hot: ?usize = null;
    var count: usize = 0;
    for (keys, 0..) |k, i| {
        const have = k orelse continue;
        if (have != wanted) continue;
        count += 1;
        if (first == null) first = i;
        if (after_hot == null) if (hot) |h| if (i > h) {
            after_hot = i;
        };
    }
    const item = first orelse return null;
    if (count == 1) return .{ .item = item, .unique = true };
    return .{ .item = after_hot orelse item, .unique = false };
}

// -----------------------------------------------------------------------
// Drawing
// -----------------------------------------------------------------------

/// Layout metrics in DIPs.
const metrics = struct {
    /// Space above the first and below the last row.
    const pad_y: f32 = 4;
    /// Inset of the row highlight from the menu edges.
    const inset: f32 = 4;
    /// Space between the menu edges and the row content.
    const pad_x: f32 = 12;
    const item_height: f32 = style.row.menu;
    const header_height: f32 = 28;
    const separator_height: f32 = 9;
    const icon_size: f32 = style.icon.standard;
    const icon_gap: f32 = 12;
    /// Label indent when no row has an icon or mark.
    const plain_indent: f32 = 4;
    /// The least space between a label and its shortcut (WinUI
    /// MenuFlyout).
    const shortcut_gap: f32 = 24;
    const chevron_size: f32 = style.icon.small;
    const chevron_gap: f32 = 8;
    const min_width: f32 = 200;
    const max_width: f32 = 480;
    /// How far a submenu overlaps its parent menu.
    const submenu_overlap: f32 = 4;
    const radio_size: f32 = 6;
    /// The height of the arrow strips at the ends of a scrolling menu.
    const arrow_height: f32 = 16;
    /// How far a wheel notch scrolls, in rows.
    const wheel_rows: f32 = 3;
    /// How far auto-scrolling moves per frame.
    const autoscroll_step: f32 = 8;
    /// How far a root menu slides toward its place while it fades in.
    const slide: f32 = 4;
};

const chevron_up_glyph: u21 = 0xE70E;

fn labelStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.body, .color = color };
}

/// Shortcuts: the caption size in the secondary text color (WinUI).
fn shortcutStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.caption, .color = color, .align_x = .trailing, .ellipsis = false };
}

fn headerStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.caption, .weight = .semibold, .color = color };
}

/// The fills of a menu. Windows 11 raises flyouts above the window in both
/// modes, lighter than it; the shared popup surface steps toward the
/// foreground, which raises it in a dark theme but darkens it in a light
/// one, so a light theme's menu blends its background toward white
/// instead, with hover and pressed shades of that.
pub const Fills = struct {
    surface: d2d.Color,
    hover: d2d.Color,
    pressed: d2d.Color,

    /// How far a light theme's menu moves from the background to white.
    pub const light_lift: f32 = 0.6;

    pub fn of(t: style.Tokens) Fills {
        if (t.dark or t.high_contrast) return .{ .surface = t.surface_raised, .hover = t.hover, .pressed = t.pressed };
        const surface = style.mix(t.background, d2d.Color.white, light_lift);
        return .{
            .surface = surface,
            .hover = style.hoverOf(surface, t),
            .pressed = style.pressedOf(surface, t),
        };
    }
};

const Result = union(enum) {
    open,
    cancelled,
    picked: usize,
};

const ItemRef = struct {
    level: usize,
    item: usize,
};

/// A submenu change that waits for the show delay.
const Pending = struct {
    /// The level whose submenu changes.
    level: usize,
    /// The submenu item to open, or null to only close the open submenu.
    item: ?usize,
    due: u64,
};

const Direction = enum { next, previous };

const Scroll = enum { up, down };

/// Scrolling while the pointer rests on an arrow strip.
const AutoScroll = struct {
    level: usize,
    direction: Scroll,
    due: u64,
};

/// The selectable item about a view of `view` pixels after (`next`) or
/// before `from` in rows `rows` of items `all`: the farthest one whose top
/// is within the view, or the next one when none is; `from` at the end.
fn pageFrom(rows: []const Row, all: []const Item, from: usize, view: i32, direction: Direction) usize {
    var best: ?usize = null;
    switch (direction) {
        .next => {
            const limit = rows[from].top + view;
            var i = from + 1;
            while (i < all.len) : (i += 1) {
                if (!all[i].selectable()) continue;
                if (rows[i].top + rows[i].height > limit) {
                    if (best == null) best = i;
                    break;
                }
                best = i;
            }
        },
        .previous => {
            const limit = rows[from].top + rows[from].height - view;
            var i = from;
            while (i > 0) {
                i -= 1;
                if (!all[i].selectable()) continue;
                if (rows[i].top < limit) {
                    if (best == null) best = i;
                    break;
                }
                best = i;
            }
        },
    }
    return best orelse from;
}

const Row = struct {
    /// Top (from the top of the content) and height in pixels.
    top: i32 = 0,
    height: i32 = 0,
    shortcut_width: f32 = 0,
    /// The label as drawn: with "(K)" when its access key is shown that
    /// way.
    text: []const u8 = "",
    /// The access key, and its byte offset in `text` when it is there.
    access: ?u8 = null,
    underline: ?usize = null,
    label_layout: ?d2d.TextLayout = null,
    label_width: f32 = 0,
    shortcut_layout: ?d2d.TextLayout = null,
    shortcut_layout_width: f32 = 0,
};

/// One open menu: the root or a submenu.
const Level = struct {
    state: *State,
    index: usize,
    popup: *Popup,
    list: *const List,
    /// The item of the parent menu that opened this submenu.
    parent_item: ?usize,
    rows: []Row = &.{},
    /// The scale of the layout, and the size of the content in pixels.
    scale: f32 = 1,
    width_px: i32 = 0,
    content_px: i32 = 0,
    label_x: f32 = 0,
    /// Whether a row is a submenu (reserves the chevron column).
    chevron: bool = false,
    /// The highlighted item, and whether the keyboard chose it.
    hot: ?usize = null,
    hot_keyboard: bool = false,
    /// The popup in screen pixels.
    bounds: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// A menu taller than its popup scrolls: the pixels of content above
    /// the view, and the height of the arrow strips (0 when it does not
    /// scroll).
    scroll_px: i32 = 0,
    arrow_px: i32 = 0,

    fn uiaLive(context: *anyopaque) bool {
        const self: *Level = @ptrCast(@alignCast(context));
        const app = self.state.host.app orelse return false;
        return current == self.state and self.index < self.state.depth and self.popup.visible and
            self.state.result == .open and uia_bridge.attachmentAlive(app, self.state.uia_attachment);
    }
    fn uiaBuild(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
        const self: *Level = @ptrCast(@alignCast(context));
        try bridge.publishMenu(api, queue, self.state.uia_attachment, self, .{ .context = self, .is_live = uiaLive, .action = uiaAction });
    }
    fn uiaAction(context: *anyopaque, token: u64, action: *const uia.Action) bool {
        const self: *Level = @ptrCast(@alignCast(context));
        if (!uiaLive(context) or token == 0) return false;
        const index = std.math.cast(usize, token - 1) orelse return false;
        if (index >= self.items().len or !self.items()[index].selectable()) return false;
        switch (action.kind) {
            .focus => self.select(index),
            .invoke => self.state.activate(self.index, index),
            .expand => {
                if (self.items()[index].kind != .submenu) return false;
                self.state.openSubmenu(self.index, index, true);
            },
            .collapse => {
                if (self.items()[index].kind != .submenu) return false;
                self.state.closeFrom(self.index + 1);
                self.popup.invalidate();
            },
            else => return false,
        }
        return true;
    }

    fn items(self: *const Level) []const Item {
        return self.list.items.items;
    }

    /// Lay the rows out in whole pixels at `scale`, with their access
    /// keys, and measure the menu.
    fn layout(self: *Level) void {
        const state = self.state;
        const factory = state.host.factory;
        const text = state.host.tokens.text;
        const s = self.scale;
        self.releaseLayouts();
        var lead = false;
        self.chevron = false;
        var used: AccessSet = .initEmpty();
        for (self.items()) |item| {
            if (item.icon != null or item.icon_text != null or item.mark != .none) lead = true;
            if (item.kind == .submenu) self.chevron = true;
            if (item.access) |key| if (accessBit(key)) |bit| used.set(bit);
        }
        self.label_x = metrics.pad_x + if (lead)
            metrics.icon_size + metrics.icon_gap
        else
            metrics.plain_indent;

        var content: f32 = 0;
        var y = style.px(metrics.pad_y, s);
        for (self.items(), self.rows) |item, *row| {
            const height = style.px(switch (item.kind) {
                .separator => metrics.separator_height,
                .header => metrics.header_height,
                .action, .submenu => metrics.item_height,
            }, s);
            row.* = .{ .top = y, .height = height, .text = item.label };
            y += height;
            switch (item.kind) {
                .separator => {},
                .header => content = @max(content, factory.measureText(item.label, headerStyle(text), 100_000).width),
                .action, .submenu => {
                    row.access = item.access orelse if (item.selectable()) pick: {
                        const key = pickAccessKey(item.label, used) orelse break :pick null;
                        used.set(accessBit(key).?);
                        break :pick key;
                    } else null;
                    if (row.access) |key| {
                        const cue = cueLabel(state.alloc, item.label, key, state.suffixes) catch
                            Cue{ .text = item.label, .underline = accessIndex(item.label, key) };
                        row.text = cue.text;
                        row.underline = cue.underline;
                    }
                    var width = factory.measureText(row.text, labelStyle(text), 100_000).width;
                    if (item.shortcut) |shortcut| {
                        row.shortcut_width = factory.measureText(shortcut, shortcutStyle(text), 100_000).width;
                        width += metrics.shortcut_gap + row.shortcut_width;
                    }
                    content = @max(content, width);
                },
            }
        }
        self.content_px = y + style.px(metrics.pad_y, s);
        const trailing = metrics.pad_x + if (self.chevron) metrics.chevron_size + metrics.chevron_gap else 0;
        self.width_px = std.math.clamp(
            style.pxCeil(self.label_x + content + trailing, s),
            style.px(metrics.min_width, s),
            style.px(metrics.max_width, s),
        );
    }

    /// Compute `bounds`: at the anchor for the root, beside the parent
    /// item for a submenu, within the monitor's work area.
    fn place(self: *Level) void {
        const state = self.state;
        if (self.index == 0) {
            const anchor = state.anchor;
            const work = workArea(.{
                .x = anchor.left + @divTrunc(anchor.right - anchor.left, 2),
                .y = anchor.top + @divTrunc(anchor.bottom - anchor.top, 2),
            });
            self.bounds = placeRoot(anchor, self.width_px, self.content_px, work, state.alignment);
        } else {
            const parent = &state.levels[self.index - 1];
            const item_top = parent.screenTop(self.parent_item.?);
            const work = workArea(.{ .x = @divTrunc(parent.bounds.left + parent.bounds.right, 2), .y = item_top });
            self.bounds = placeSubmenu(
                parent.bounds,
                item_top,
                self.width_px,
                self.content_px,
                work,
                style.px(metrics.submenu_overlap, self.scale),
                style.px(metrics.pad_y, self.scale),
            );
        }
        const view = self.bounds.bottom - self.bounds.top;
        self.arrow_px = if (self.content_px > view) style.px(metrics.arrow_height, self.scale) else 0;
        self.scroll_px = std.math.clamp(self.scroll_px, 0, self.maxScroll());
    }

    fn releaseLayouts(self: *Level) void {
        for (self.rows) |*row| {
            if (row.label_layout) |*text_layout| text_layout.deinit();
            if (row.shortcut_layout) |*text_layout| text_layout.deinit();
            row.label_layout = null;
            row.shortcut_layout = null;
        }
    }

    /// The top of row `item` on the screen.
    fn screenTop(self: *const Level, item: usize) i32 {
        return self.bounds.top + self.arrow_px + self.rows[item].top - self.scroll_px;
    }

    /// The height of the rows' view in pixels (between the arrow strips).
    fn viewHeight(self: *const Level) i32 {
        return self.bounds.bottom - self.bounds.top - 2 * self.arrow_px;
    }

    fn maxScroll(self: *const Level) i32 {
        if (self.arrow_px == 0) return 0;
        return @max(0, self.content_px - self.viewHeight());
    }

    /// Scroll to `offset` pixels; whether that moved the content.
    fn scrollTo(self: *Level, offset: i32) bool {
        const value = std.math.clamp(offset, 0, self.maxScroll());
        if (value == self.scroll_px) return false;
        self.scroll_px = value;
        self.popup.invalidate();
        return true;
    }

    /// Scroll row `item` into the view.
    fn ensureVisible(self: *Level, item: usize) void {
        if (self.arrow_px == 0) return;
        const row = self.rows[item];
        const pad = style.px(metrics.pad_y, self.scale);
        if (row.top < self.scroll_px) {
            _ = self.scrollTo(row.top - pad);
        } else if (row.top + row.height > self.scroll_px + self.viewHeight()) {
            _ = self.scrollTo(row.top + row.height + pad - self.viewHeight());
        }
    }

    /// The row at `y` pixels from the top of the content.
    fn rowAt(self: *const Level, y: i32) ?usize {
        for (self.rows, 0..) |row, index| {
            if (y >= row.top and y < row.top + row.height) return index;
        }
        return null;
    }

    fn setHot(self: *Level, item: ?usize, keyboard: bool) void {
        const by_keyboard = keyboard and item != null;
        if (self.hot == item and self.hot_keyboard == by_keyboard) return;
        self.hot = item;
        self.hot_keyboard = by_keyboard;
        // Highlight/focus alone keeps item tokens stable. ensureVisible still
        // invalidates when it actually scrolls the layout.
        self.popup.repaint();
    }

    /// Highlight `item` from the keyboard and scroll it into view.
    fn select(self: *Level, item: ?usize) void {
        self.setHot(item, true);
        if (item) |i| self.ensureVisible(i);
    }

    /// The next selectable item after `from` (or the first/last one),
    /// wrapping around.
    fn step(self: *const Level, from: ?usize, direction: Direction) ?usize {
        const all = self.items();
        const n = all.len;
        if (n == 0) return null;
        var i: usize = from orelse switch (direction) {
            .next => n - 1,
            .previous => 0,
        };
        for (0..n) |_| {
            i = switch (direction) {
                .next => (i + 1) % n,
                .previous => (i + n - 1) % n,
            };
            if (all[i].selectable()) return i;
        }
        return from;
    }

    /// The item Page Up or Page Down moves to from `from`: about a view
    /// further in a scrolling menu, else the first or last item.
    fn page(self: *const Level, from: ?usize, direction: Direction) ?usize {
        const start = from orelse return self.step(null, direction);
        if (self.arrow_px == 0) return self.step(null, switch (direction) {
            .next => .previous,
            .previous => .next,
        });
        return pageFrom(self.rows, self.items(), start, self.viewHeight(), direction);
    }

    /// The access keys of the rows that can be picked.
    fn accessKeys(self: *const Level, buf: []?u8) []const ?u8 {
        const n = @min(buf.len, self.rows.len);
        for (self.items()[0..n], self.rows[0..n], buf[0..n]) |item, row, *key| {
            key.* = if (item.selectable()) row.access else null;
        }
        return buf[0..n];
    }

    fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
        const self: *Level = @ptrCast(@alignCast(ctx));
        const tokens = self.state.host.tokens;
        const size = popup.sizeDip();
        const s = self.scale;
        canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, Fills.of(tokens).surface);

        const arrow = style.dip(self.arrow_px, s);
        const scrolls = self.arrow_px > 0;
        if (scrolls) canvas.pushClip(.{ .x = 0, .y = arrow, .w = size.width, .h = @max(0, size.height - 2 * arrow) });
        for (self.items(), self.rows, 0..) |item, *row, i| {
            const top = style.dip(row.top + self.arrow_px - self.scroll_px, s);
            const height = style.dip(row.height, s);
            if (top + height <= arrow or top >= size.height - arrow) continue;
            switch (item.kind) {
                .separator => canvas.hairlineH(
                    metrics.inset,
                    top + style.dip(@divTrunc(row.height, 2), s),
                    size.width - 2 * metrics.inset,
                    tokens.border,
                ),
                .header => canvas.drawText(item.label, .{
                    .x = self.label_x,
                    .y = top,
                    .w = @max(size.width - self.label_x - metrics.pad_x, 0),
                    .h = height,
                }, headerStyle(tokens.text_secondary)),
                .action, .submenu => self.paintItem(canvas, item, row, top, height, i, size.width),
            }
        }
        if (scrolls) {
            canvas.popClip();
            const up = if (self.scroll_px > 0) tokens.text_secondary else tokens.text_disabled;
            const down = if (self.scroll_px < self.maxScroll()) tokens.text_secondary else tokens.text_disabled;
            canvas.drawIcon(chevron_up_glyph, .{ .x = 0, .y = 0, .w = size.width, .h = arrow }, style.icon.small, up);
            canvas.drawIcon(d2d.icons.chevron_down, .{ .x = 0, .y = size.height - arrow, .w = size.width, .h = arrow }, style.icon.small, down);
        }
        if (ownBorder()) canvas.strokeRoundedRectPx(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, 0, tokens.border, 1);
    }

    fn paintItem(self: *Level, canvas: *d2d.Canvas, item: Item, row: *Row, top: f32, height: f32, index: usize, width: f32) void {
        const state = self.state;
        const tokens = state.host.tokens;
        const hot = item.selectable() and self.hot == index;
        if (hot) {
            const pressed = if (state.press) |p| p.level == self.index and p.item == index else false;
            const fill = canvas.snapRect(.{
                .x = metrics.inset,
                .y = top + 2,
                .w = width - 2 * metrics.inset,
                .h = height - 4,
            });
            const fills = Fills.of(tokens);
            canvas.fillRoundedRect(fill, style.radius.control, if (pressed) fills.pressed else fills.hover);
            // Only the keyboard's choice gets the indicator, as in the
            // command palette; the pointer is its own.
            if (self.hot_keyboard) controls.selectionIndicator(canvas, fill, tokens);
        }

        const on_hover = hot and tokens.high_contrast;
        const text_color = if (!item.enabled) tokens.text_disabled else if (on_hover) tokens.hover_text else tokens.text;
        const secondary = if (!item.enabled) tokens.text_disabled else if (on_hover) tokens.hover_text else tokens.text_secondary;

        const lead: d2d.Rect = .{ .x = metrics.pad_x, .y = top, .w = metrics.icon_size, .h = height };
        switch (item.mark) {
            .check => canvas.drawIcon(d2d.icons.check_mark, lead, style.icon.small, text_color),
            .radio => {
                const d = metrics.radio_size;
                canvas.fillRoundedRect(canvas.snapRect(.{
                    .x = lead.x + (lead.w - d) / 2,
                    .y = top + (height - d) / 2,
                    .w = d,
                    .h = d,
                }), d / 2, text_color);
            },
            .none => if (item.icon_text) |emoji| {
                canvas.drawText(emoji, lead, .{
                    .size = style.font_size.body,
                    .color = text_color,
                    .align_x = .center,
                    .ellipsis = false,
                });
            } else if (item.icon) |glyph| canvas.drawIcon(glyph, lead, metrics.icon_size, text_color),
        }

        var right = width - metrics.pad_x;
        if (self.chevron) {
            if (item.kind == .submenu) canvas.drawIcon(d2d.icons.chevron_right, .{
                .x = right - metrics.chevron_size,
                .y = top,
                .w = metrics.chevron_size,
                .h = height,
            }, metrics.chevron_size, secondary);
            right -= metrics.chevron_size + metrics.chevron_gap;
        }
        if (item.shortcut) |text| {
            const shortcut_rect: d2d.Rect = .{
                .x = self.label_x,
                .y = top,
                .w = @max(right - self.label_x, 0),
                .h = height,
            };
            if (row.shortcut_layout == null or row.shortcut_layout_width != shortcut_rect.w) {
                if (row.shortcut_layout) |*text_layout| text_layout.deinit();
                row.shortcut_layout = d2d.TextLayout.initUtf8(canvas.factory, text, shortcutStyle(secondary), shortcut_rect.w, height);
                row.shortcut_layout_width = shortcut_rect.w;
            }
            if (row.shortcut_layout) |*text_layout| {
                canvas.drawLayout(text_layout, .{ .x = shortcut_rect.x, .y = top }, secondary, &.{});
            } else canvas.drawText(text, shortcut_rect, shortcutStyle(secondary));
            right -= row.shortcut_width + metrics.shortcut_gap;
        }
        const label_rect: d2d.Rect = .{
            .x = self.label_x,
            .y = top,
            .w = @max(right - self.label_x, 0),
            .h = height,
        };
        if (row.label_layout == null or row.label_width != label_rect.w) {
            if (row.label_layout) |*text_layout| text_layout.deinit();
            row.label_layout = d2d.TextLayout.initUtf8(canvas.factory, row.text, labelStyle(text_color), label_rect.w, height);
            row.label_width = label_rect.w;
        }
        if (row.label_layout) |*text_layout| {
            var runs: [1]d2d.LayoutRun = undefined;
            const underline = if (state.cues) row.underline else null;
            if (underline) |at| {
                const start = wstr.utf16Index(row.text, at);
                const len = std.unicode.utf8ByteSequenceLength(row.text[at]) catch 1;
                const stop = wstr.utf16Index(row.text, at + len);
                runs[0] = .{ .start = @intCast(start), .len = @intCast(stop - start), .underline = true };
            }
            canvas.drawLayout(text_layout, .{ .x = label_rect.x, .y = top }, text_color, if (underline != null) &runs else &.{});
        } else canvas.drawText(row.text, label_rect, labelStyle(text_color));
    }

    /// The root popup lost the mouse capture.
    fn dismissed(ctx: *anyopaque, popup: *Popup, reason: Popup.DismissReason) void {
        _ = popup;
        _ = reason;
        const self: *Level = @ptrCast(@alignCast(ctx));
        self.state.dismiss();
    }

    /// The popup moved to a monitor with another DPI: lay it out for it.
    fn dpiChanged(ctx: *anyopaque, popup: *Popup) void {
        const self: *Level = @ptrCast(@alignCast(ctx));
        self.scale = popup.scale();
        self.layout();
        self.place();
        popup.setBounds(self.bounds);
    }
};

test "UIA menu focus preserves Invoke unless revealing the row scrolls layout" {
    var api: uia.Api = undefined;
    api.count = .init(1);
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: @import("../../../gx/ui_ref.zig").Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const nodes = [_]uia.NodeSpec{
        .{ .id = 1, .name = "Menu", .role = .menu },
        .{ .id = 2, .parent = 0, .name = "Action", .role = .menu_item, .patterns = .{ .invoke = true } },
    };
    const Abi = extern struct {
        query: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        retain: *const fn (*uia.Face) callconv(.winapi) u32,
        release: *const fn (*uia.Face) callconv(.winapi) u32,
        options: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    for ([_]bool{ false, true }) |scrolls| {
        var popup: Popup = .{};
        defer popup.destroy();
        try popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
        const snapshot = popup.uia_view.publisher.current.?;
        const face = &snapshot.nodes[1].faces[0];
        const abi: *const Abi = @ptrCast(@alignCast(face.vtable));
        _ = abi.retain(face);
        defer _ = abi.release(face);
        const action: uia.Action = .{ .attachment = attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .invoke, .value = &.{}, .alloc = testing.allocator };
        var items = [_]Item{.{ .id = 42, .label = "Action" }};
        var list: List = .{ .items = .{ .items = &items, .capacity = items.len } };
        var rows = [_]Row{.{ .top = if (scrolls) 40 else 0, .height = 20 }};
        var state: State = undefined;
        state.levels[0] = .{
            .state = &state,
            .index = 0,
            .popup = &popup,
            .list = &list,
            .parent_item = null,
            .rows = &rows,
            .content_px = 100,
            .arrow_px = if (scrolls) 4 else 0,
            .bounds = .{ .left = 0, .top = 0, .right = 100, .bottom = if (scrolls) 24 else 100 },
        };
        state.levels[0].select(0); // The same method called by uiaAction(.focus).
        var options: u32 = 0;
        if (!scrolls) {
            try testing.expectEqual(@as(i32, 0), abi.options(face, &options));
            try testing.expect(popup.uia_view.publisher.accepts(action));
            state.activate(0, 0); // Actual Invoke implementation, no OS dispatch.
            try testing.expectEqual(@as(usize, 42), state.result.picked);
        } else {
            try testing.expect(state.levels[0].scroll_px > 0);
            try testing.expect(!popup.uia_view.publisher.accepts(action));
            try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), abi.options(face, &options));
        }
        popup.hide();
        try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), abi.options(face, &options));
    }
}

const State = struct {
    host: Host,
    owner: w32.HWND,
    uia_attachment: @import("../../../gx/ui_ref.zig").Attachment = .{},
    alloc: Allocator,
    anchor: w32.RECT,
    alignment: Align,
    owner_scale: ?f32,
    open_timing: ?Popup.OpenTiming = null,
    root_host: ?*RootHosts.Entry = null,
    preparing: bool = false,
    /// The popup of each level, created when the level first opens and
    /// reused by every submenu shown there until the menu closes.
    popups: [max_depth]Popup = @splat(.{}),
    levels: [max_depth]Level = undefined,
    depth: usize = 0,
    result: Result = .open,
    /// The foreground window when the menu opened.
    foreground: ?w32.HWND,
    pending: ?Pending = null,
    /// The pointer rests in the aim triangle of an open submenu: when to
    /// let the row under it take the highlight.
    aim_due: ?u64 = null,
    autoscroll: ?AutoScroll = null,
    /// The item a mouse button is held on.
    press: ?ItemRef = null,
    /// A mouse button went down inside the menu.
    pressed: bool = false,
    /// The pointer left the drag rectangle around `start_pt`.
    dragged: bool = false,
    start_pt: w32.POINT,
    last_pt: w32.POINT,
    /// How far the pointer moves before it counts as dragged
    /// (SM_CXDRAG, SM_CYDRAG).
    drag_x: u32,
    drag_y: u32,
    show_delay: u64,
    /// The keys that were down when the menu opened. While they stay down
    /// their auto-repeat does nothing, and their releases go on to the
    /// focused window, which saw them go down.
    held_keys: std.StaticBitSet(256),
    /// Underline the access keys (opened from the keyboard, a key was
    /// pressed, or Windows always underlines them).
    cues: bool,
    /// Show the access key of a label without it as "(K)": opened from
    /// the keyboard.
    suffixes: bool,

    fn popupAt(self: *State, index: usize) *Popup {
        if (index == 0) if (self.root_host) |entry| return &entry.popup;
        return &self.popups[index];
    }

    /// Open `list` as the next level; `parent_item` is the item of the
    /// current deepest level it belongs to.
    fn open(self: *State, list: *const List, parent_item: ?usize, keyboard: bool) bool {
        if (self.depth >= max_depth) return false;
        const span = if (!self.preparing and perf.enabled()) perf.Span.begin(global.io()) else null;
        defer if (span) |value| {
            _ = value.end(global.io(), "menu.open");
        };
        const index = self.depth;
        var timing = if (index == 0) self.open_timing else null;
        if (index == 0) self.open_timing = null;
        if (timing) |*value| value.lap(.prepare);
        const level = &self.levels[index];
        const popup = self.popupAt(index);
        level.* = .{ .state = self, .index = index, .popup = popup, .list = list, .parent_item = parent_item };
        level.rows = self.alloc.alloc(Row, list.items.items.len) catch return false;
        @memset(level.rows, .{});
        const callbacks: Popup.Callbacks = .{
            .ctx = level,
            .paint = Level.paint,
            .uia_source = if (self.host.app) |app| .{ .app = app, .build = Level.uiaBuild, .is_live = Level.uiaLive, .action = Level.uiaAction } else null,
            .dismissed = Level.dismissed,
            .dpi_changed = Level.dpiChanged,
        };
        if (popup.reuse_invalid) popup.destroy();
        if (popup.hwnd == null) {
            const tokens = self.host.tokens;
            popup.create(self.host.hinstance, self.owner, self.host.factory, .{
                .activate = false,
                .capture_mouse = index == 0,
                .dismiss_on_escape = false,
                .dismiss_on_outside_click = index == 0,
                .corners = .round,
                .shadow = true,
                .border_color = tokens.border,
                .dark = tokens.dark,
                // Fade in (`anim.enabled`); `open` sets the direction.
                .motion = .{},
            }, callbacks) catch |err| {
                log.warn("failed to create a menu popup err={}", .{err});
                return false;
            };
            if (index == 0 and self.root_host == null) {
                const reused = raster_cache.restore(popup);
                if (perf.enabled()) log.info("menu raster reused={}", .{reused});
            }
        }
        // No callbacks or stack addresses survive a closed session. Rebind
        // only while this Level lives, without moving the Popup itself.
        popup.callbacks = callbacks;
        if (self.owner_scale) |owner_scale| popup.setOwnerScale(owner_scale);
        self.depth += 1;
        if (timing) |*value| value.lap(.create);

        level.scale = popup.ownerScale();
        level.layout();
        if (keyboard) level.hot = level.step(null, .next);
        level.hot_keyboard = level.hot != null;
        level.place();
        popup.options.motion = .{ .offset_y = if (index == 0) self.slideFor(level.bounds) else 0 };
        if (timing) |*value| value.lap(.layout);
        if (self.preparing) {
            popup.prepareHidden(level.bounds);
            return true;
        }
        popup.open_timing = timing;
        popup.show(level.bounds);
        if (popup.scale() != level.scale) {
            const layout_span = if (popup.open_timing != null) perf.Span.begin(global.io()) else null;
            level.scale = popup.scale();
            level.layout();
            level.place();
            if (layout_span) |value| {
                if (popup.open_timing) |*opened| opened.addSince(.layout, value.start);
            }
            popup.setBounds(level.bounds);
        }
        if (level.hot) |item| level.ensureVisible(item);
        if (index > 0) self.levels[index - 1].popup.invalidate();
        return true;
    }

    fn slideFor(self: *const State, bounds: w32.RECT) f32 {
        return if (bounds.top >= self.anchor.bottom) -metrics.slide else metrics.slide;
    }

    /// Close the levels from `index` on; their popups hide for reuse.
    fn closeFrom(self: *State, index: usize) void {
        if (self.depth <= index) return;
        while (self.depth > index) {
            self.depth -= 1;
            self.popupAt(self.depth).hide();
            self.levels[self.depth].releaseLayouts();
        }
        if (self.press) |p| if (p.level >= index) {
            self.press = null;
        };
        if (self.autoscroll) |a| if (a.level >= index) {
            self.autoscroll = null;
        };
        if (index > 0) self.levels[index - 1].popup.invalidate();
    }

    fn destroyPopups(self: *State) void {
        self.closeFrom(0);
        if (self.root_host) |entry| {
            root_hosts.release(entry);
            self.root_host = null;
        } else raster_cache.store(&self.popups[0]);
        for (&self.popups) |*popup| popup.destroy();
    }

    fn dismiss(self: *State) void {
        if (self.result != .open) return;
        self.result = .cancelled;
        for (self.levels[0..self.depth]) |*level| level.popup.hide();
    }

    /// Show the access key underlines (a key was pressed).
    fn showCues(self: *State) void {
        if (self.cues) return;
        self.cues = true;
        for (self.levels[0..self.depth]) |*level| level.popup.repaint();
    }

    fn openSubmenu(self: *State, level_index: usize, item: usize, keyboard: bool) void {
        self.pending = null;
        const level = &self.levels[level_index];
        const entry = level.items()[item];
        if (!entry.selectable() or entry.kind != .submenu) return;
        level.setHot(item, keyboard);
        if (self.depth > level_index + 1 and self.levels[level_index + 1].parent_item == item) {
            if (keyboard) {
                const child = &self.levels[level_index + 1];
                if (child.hot == null) child.select(child.step(null, .next));
            }
            return;
        }
        self.closeFrom(level_index + 1);
        _ = self.open(entry.submenu.?, item, keyboard);
    }

    /// Pick an action or open a submenu.
    fn activate(self: *State, level_index: usize, item: usize) void {
        const entry = self.levels[level_index].items()[item];
        if (!entry.selectable()) return;
        switch (entry.kind) {
            .action => self.result = .{ .picked = entry.id },
            .submenu => self.openSubmenu(level_index, item, true),
            .separator, .header => {},
        }
    }

    /// Open or close a submenu once the pointer rests for the show delay.
    fn schedule(self: *State, level: usize, item: ?usize) void {
        if (self.pending) |p| if (p.level == level and p.item == item) return;
        self.pending = .{ .level = level, .item = item, .due = GetTickCount64() + self.show_delay };
    }

    fn loop(self: *State) void {
        var msg: w32.MSG = undefined;
        while (self.result == .open) {
            if (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) == 0) {
                const wait = self.waitMs(GetTickCount64());
                _ = w32.MsgWaitForMultipleObjectsEx(0, null, wait, w32.QS_ALLINPUT, w32.MWMO_INPUTAVAILABLE);
                self.tick();
                continue;
            }
            if (msg.message == w32.WM_QUIT) {
                // Leave a requested quit for the main loop; drop a
                // withdrawn one.
                const code = Popup.modalQuitCode(self.host.quit_requested.*, msg.wParam) orelse continue;
                self.dismiss();
                w32.PostQuitMessage(code);
                break;
            }
            if (!self.input(&msg)) _ = w32.DispatchMessageW(&msg);
            self.tick();
        }
    }

    /// How long the loop may sleep: until the next deadline, at most
    /// `watch_ms`.
    fn waitMs(self: *const State, now: u64) u32 {
        var due = now + watch_ms;
        if (self.pending) |p| due = @min(due, p.due);
        if (self.aim_due) |aim| due = @min(due, aim);
        if (self.autoscroll) |a| due = @min(due, a.due);
        return @intCast(due -| now);
    }

    /// Dismiss when the owner is gone, hidden or minimized, or the
    /// foreground changed, and act on the deadlines that passed.
    fn tick(self: *State) void {
        if (self.result != .open) return;
        const root = GetAncestor(self.owner, 2) orelse self.owner;
        if (!ownerAvailable(
            ownerAlive(self.owner),
            w32.IsWindowVisible_(self.owner) != 0,
            w32.IsIconic(root) != 0,
            w32.GetForegroundWindow() == self.foreground,
        )) {
            self.dismiss();
            return;
        }
        const now = GetTickCount64();
        if (self.aim_due) |due| if (now >= due) {
            self.aim_due = null;
            if (self.hitTest(self.last_pt)) |hit| self.pointAt(hit);
        };
        if (self.autoscroll) |*auto| if (now >= auto.due) {
            auto.due = now + autoscroll_ms;
            self.autoscrollStep(auto.*);
        };
        const pending = self.pending orelse return;
        if (now < pending.due) return;
        self.pending = null;
        if (pending.level >= self.depth) return;
        if (pending.item) |item| {
            self.openSubmenu(pending.level, item, false);
        } else {
            self.closeFrom(pending.level + 1);
        }
    }

    fn autoscrollStep(self: *State, auto: AutoScroll) void {
        if (auto.level >= self.depth) {
            self.autoscroll = null;
            return;
        }
        const level = &self.levels[auto.level];
        const step_px = style.px(metrics.autoscroll_step, level.scale);
        const target = switch (auto.direction) {
            .up => level.scroll_px - step_px,
            .down => level.scroll_px + step_px,
        };
        if (!level.scrollTo(target)) {
            self.autoscroll = null;
            return;
        }
        self.closeFrom(auto.level + 1);
    }

    /// Handle keyboard and mouse input. Returns false for messages to
    /// dispatch normally.
    fn input(self: *State, msg: *const w32.MSG) bool {
        switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => self.key(@truncate(msg.wParam), msg.hwnd),
            w32.WM_KEYUP, w32.WM_SYSKEYUP => {
                const vk: u8 = @truncate(msg.wParam);
                if (self.held_keys.isSet(vk)) {
                    self.held_keys.unset(vk);
                    return false;
                }
            },
            w32.WM_MOUSEWHEEL => self.wheel(msg),
            w32.WM_CHAR,
            w32.WM_DEADCHAR,
            w32.WM_SYSCHAR,
            w32.WM_SYSDEADCHAR,
            WM_UNICHAR,
            w32.WM_MOUSEHWHEEL,
            => {},
            w32.WM_MOUSEMOVE, WM_NCMOUSEMOVE => self.mouseMove(msg.pt),
            w32.WM_LBUTTONDOWN,
            w32.WM_LBUTTONDBLCLK,
            w32.WM_RBUTTONDOWN,
            WM_RBUTTONDBLCLK,
            w32.WM_MBUTTONDOWN,
            WM_MBUTTONDBLCLK,
            w32.WM_XBUTTONDOWN,
            WM_XBUTTONDBLCLK,
            WM_NCLBUTTONDOWN,
            WM_NCLBUTTONDBLCLK,
            WM_NCRBUTTONDOWN,
            WM_NCRBUTTONDBLCLK,
            WM_NCMBUTTONDOWN,
            WM_NCMBUTTONDBLCLK,
            WM_NCXBUTTONDOWN,
            WM_NCXBUTTONDBLCLK,
            => self.mouseDown(msg.pt),
            w32.WM_LBUTTONUP,
            w32.WM_RBUTTONUP,
            w32.WM_MBUTTONUP,
            w32.WM_XBUTTONUP,
            WM_NCLBUTTONUP,
            WM_NCRBUTTONUP,
            WM_NCMBUTTONUP,
            WM_NCXBUTTONUP,
            => self.mouseUp(msg.pt),
            else => return false,
        }
        return true;
    }

    /// A key went down in `target` (the focused window).
    fn key(self: *State, raw: u16, target: ?w32.HWND) void {
        var vk = raw;
        if (vk == w32.VK_PROCESSKEY) {
            // The input method took the key: act on the key itself.
            const hwnd = target orelse return;
            const real = ImmGetVirtualKey(hwnd);
            if (real == 0 or real > 0xFF or real == w32.VK_PROCESSKEY) return;
            vk = @intCast(real);
        }
        if (perf.enabled()) log.debug("menu key raw={} vk={} held={} ctrl={} depth={}", .{
            raw, vk, vk < 256 and self.held_keys.isSet(vk), w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0, self.depth,
        });
        // The auto-repeat of a key that opened the menu.
        if (vk < 256 and self.held_keys.isSet(vk)) return;
        if (!self.handleKey(vk)) return;
        if (raw == w32.VK_PROCESSKEY) if (target) |hwnd| cancelComposition(hwnd);
    }

    /// Act on key `vk` in the deepest menu; whether the menu used it.
    fn handleKey(self: *State, vk: u16) bool {
        const level = &self.levels[self.depth - 1];
        highlightPath(self.levels[0..self.depth], level.index);
        self.pending = null;
        self.aim_due = null;
        self.autoscroll = null;
        switch (vk) {
            w32.VK_UP => level.select(level.step(level.hot, .previous)),
            w32.VK_DOWN => level.select(level.step(level.hot, .next)),
            w32.VK_HOME => level.select(level.step(null, .next)),
            w32.VK_END => level.select(level.step(null, .previous)),
            w32.VK_PRIOR => level.select(level.page(level.hot, .previous)),
            w32.VK_NEXT => level.select(level.page(level.hot, .next)),
            w32.VK_RIGHT => if (level.hot) |item| {
                if (level.items()[item].kind == .submenu) self.openSubmenu(level.index, item, true);
            },
            w32.VK_LEFT, w32.VK_ESCAPE => {
                if (self.depth > 1) {
                    const parent = &self.levels[self.depth - 2];
                    self.closeFrom(self.depth - 1);
                    parent.select(parent.hot);
                } else if (vk == w32.VK_ESCAPE) self.dismiss();
            },
            w32.VK_RETURN, w32.VK_SPACE => if (level.hot) |item| self.activate(level.index, item),
            w32.VK_MENU, w32.VK_F10 => self.dismiss(),
            else => {
                const key_char = accessChar(vk) orelse return false;
                if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) return false;
                self.accessKey(level, key_char);
            },
        }
        self.showCues();
        return true;
    }

    fn accessKey(self: *State, level: *Level, key_char: u8) void {
        const buf = self.alloc.alloc(?u8, level.rows.len) catch return;
        defer self.alloc.free(buf);
        const target = accessTarget(level.accessKeys(buf), level.hot, key_char) orelse return;
        level.select(target.item);
        if (target.unique) self.activate(level.index, target.item);
    }

    /// The wheel turned (`WM_MOUSEWHEEL`): scroll the menu under the
    /// pointer.
    fn wheel(self: *State, msg: *const w32.MSG) void {
        const pt: w32.POINT = .{
            .x = @as(i16, @truncate(msg.lParam & 0xFFFF)),
            .y = @as(i16, @truncate((msg.lParam >> 16) & 0xFFFF)),
        };
        const delta: i16 = @bitCast(@as(u16, @truncate(msg.wParam >> 16)));
        const hit = self.hitTest(pt) orelse return;
        const level = &self.levels[hit.level];
        if (level.arrow_px == 0) return;
        const notches = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(w32.WHEEL_DELTA));
        const distance = style.px(notches * metrics.wheel_rows * metrics.item_height, level.scale);
        if (!level.scrollTo(level.scroll_px - distance)) return;
        self.closeFrom(hit.level + 1);
        // The rows moved under the pointer.
        if (self.hitTest(self.last_pt)) |now| self.pointAt(now);
    }

    const Hit = struct {
        level: usize,
        /// The row under the point, of any kind.
        item: ?usize = null,
        /// The arrow strip under the point.
        arrow: ?Scroll = null,
    };

    /// The menu (deepest first) and row or arrow strip at screen point
    /// `pt`.
    fn hitTest(self: *const State, pt: w32.POINT) ?Hit {
        var i = self.depth;
        while (i > 0) {
            i -= 1;
            const level = &self.levels[i];
            const b = level.bounds;
            if (pt.x < b.left or pt.x >= b.right or pt.y < b.top or pt.y >= b.bottom) continue;
            const y = pt.y - b.top;
            if (level.arrow_px > 0) {
                if (y < level.arrow_px) return .{ .level = i, .arrow = .up };
                if (y >= b.bottom - b.top - level.arrow_px) return .{ .level = i, .arrow = .down };
            }
            return .{ .level = i, .item = level.rowAt(y - level.arrow_px + level.scroll_px) };
        }
        return null;
    }

    /// The selectable item of a hit, if any.
    fn hitItem(self: *const State, hit: Hit) ?usize {
        const index = hit.item orelse return null;
        return if (self.levels[hit.level].items()[index].selectable()) index else null;
    }

    fn mouseMove(self: *State, pt: w32.POINT) void {
        // Windows also reports a move when windows change under a resting
        // pointer; only real movement changes the highlight.
        if (pt.x == self.last_pt.x and pt.y == self.last_pt.y) return;
        const from = self.last_pt;
        self.last_pt = pt;
        if (@abs(pt.x - self.start_pt.x) > self.drag_x or
            @abs(pt.y - self.start_pt.y) > self.drag_y) self.dragged = true;

        const hit = self.hitTest(pt) orelse {
            self.aim_due = null;
            self.autoscroll = null;
            self.levels[self.depth - 1].setHot(null, false);
            self.pending = null;
            return;
        };
        if (self.aiming(from, pt, hit)) {
            self.aim_due = GetTickCount64() + aim_ms;
            return;
        }
        self.aim_due = null;
        self.pointAt(hit);
    }

    /// Whether the pointer, moving from `from` to `to` over another row of
    /// a menu with an open submenu, heads for that submenu.
    fn aiming(self: *const State, from: w32.POINT, to: w32.POINT, hit: Hit) bool {
        if (hit.arrow != null or hit.level + 1 >= self.depth) return false;
        const child = &self.levels[hit.level + 1];
        if (self.hitItem(hit)) |item| if (item == child.parent_item) return false;
        const parent = &self.levels[hit.level];
        const b = child.bounds;
        const right = b.left >= @divTrunc(parent.bounds.left + parent.bounds.right, 2);
        return inAimTriangle(from, to, if (right) b.left else b.right, b.top, b.bottom);
    }

    /// The pointer is at `hit`: highlight the row (and the path to its
    /// menu), auto-scroll on an arrow strip, and open or close submenus
    /// after the show delay.
    fn pointAt(self: *State, hit: Hit) void {
        const level = &self.levels[hit.level];
        if (hit.arrow) |direction| {
            level.setHot(null, false);
            highlightPath(self.levels[0..self.depth], hit.level);
            self.pending = null;
            const same = if (self.autoscroll) |a| a.level == hit.level and a.direction == direction else false;
            if (!same) self.autoscroll = .{ .level = hit.level, .direction = direction, .due = GetTickCount64() };
            return;
        }
        self.autoscroll = null;
        const item = self.hitItem(hit);
        level.setHot(item, false);
        for (self.levels[hit.level + 1 .. self.depth]) |*deeper| deeper.setHot(null, false);
        highlightPath(self.levels[0..self.depth], hit.level);

        const submenu_item: ?usize = if (item) |i|
            (if (level.items()[i].kind == .submenu) i else null)
        else
            null;
        if (hit.level + 1 < self.depth) {
            if (submenu_item != null and submenu_item == self.levels[hit.level + 1].parent_item) {
                self.pending = null;
            } else {
                self.schedule(hit.level, submenu_item);
            }
        } else if (submenu_item) |i| {
            self.schedule(hit.level, i);
        } else {
            self.pending = null;
        }
    }

    fn mouseDown(self: *State, pt: w32.POINT) void {
        const hit = self.hitTest(pt) orelse {
            self.dismiss();
            return;
        };
        self.pressed = true;
        const item = self.hitItem(hit) orelse return;
        const level = &self.levels[hit.level];
        switch (level.items()[item].kind) {
            .submenu => self.openSubmenu(hit.level, item, false),
            .action => {
                level.setHot(item, false);
                highlightPath(self.levels[0..self.depth], hit.level);
                self.press = .{ .level = hit.level, .item = item };
                level.popup.repaint();
            },
            .separator, .header => {},
        }
    }

    fn mouseUp(self: *State, pt: w32.POINT) void {
        if (self.press) |p| {
            self.press = null;
            if (p.level < self.depth) self.levels[p.level].popup.repaint();
        }
        const hit = self.hitTest(pt) orelse return;
        const item = self.hitItem(hit) orelse return;
        const entry = self.levels[hit.level].items()[item];
        if (entry.kind != .action) return;
        // The release of the click that opened the menu picks nothing
        // unless the pointer was dragged onto the item.
        if (!self.pressed and !self.dragged) return;
        self.result = .{ .picked = entry.id };
    }
};

/// The access key a virtual key types: its letter or digit (the main
/// keyboard and the number pad).
fn accessChar(vk: u16) ?u8 {
    return switch (vk) {
        '0'...'9', 'A'...'Z' => @intCast(vk),
        w32.VK_NUMPAD0...w32.VK_NUMPAD9 => @intCast('0' + (vk - w32.VK_NUMPAD0)),
        else => null,
    };
}

/// Drop the composition the input method started with a key the menu
/// used.
fn cancelComposition(hwnd: w32.HWND) void {
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    _ = ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
}

// -----------------------------------------------------------------------
// Native menus
// -----------------------------------------------------------------------

const TPMPARAMS = extern struct {
    cbSize: u32 = @sizeOf(TPMPARAMS),
    rcExclude: w32.RECT,
};

const MF_CHECKED: u32 = 0x0008;
const MF_DISABLED: u32 = 0x0002;
const MF_BYCOMMAND: u32 = 0x0000;
const TPM_RIGHTBUTTON: u32 = 0x0002;
const TPM_RIGHTALIGN: u32 = 0x0008;
const TPM_VERTICAL: u32 = 0x0040;
const TPM_NONOTIFY: u32 = 0x0080;

extern "user32" fn CheckMenuRadioItem(hmenu: w32.HMENU, first: u32, last: u32, check: u32, flags: u32) callconv(.winapi) i32;

/// Show the menu `root` as a native menu (`TrackPopupMenuEx`), for screen
/// readers and when Direct2D is unavailable: the same items, access keys
/// and shortcuts, with the same anchor and alignment. Returns like `run`.
pub fn runNative(alloc: Allocator, owner: w32.HWND, root: *const List, options: Options) ?usize {
    if (current != null or native_open) return null;
    if (root.items.items.len == 0) return null;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const menu = nativeMenu(arena.allocator(), root) catch |err| {
        log.err("failed to build a native menu err={}", .{err});
        return null;
    };
    defer _ = w32.DestroyMenu(menu);

    const anchor = options.anchor;
    var flags: u32 = w32.TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | w32.TPM_TOPALIGN;
    const x = switch (options.alignment) {
        .left => anchor.left,
        .right => anchor.right,
    };
    if (options.alignment == .right) flags |= TPM_RIGHTALIGN;
    const empty = anchor.right <= anchor.left and anchor.bottom <= anchor.top;
    if (!empty) flags |= TPM_VERTICAL;
    const params: TPMPARAMS = .{ .rcExclude = anchor };
    // Highlight the first item of a menu opened from the keyboard.
    if (options.keyboard) _ = w32.PostMessageW(owner, w32.WM_KEYDOWN, w32.VK_DOWN, 0);

    native_open = true;
    defer native_open = false;
    const cmd = w32.TrackPopupMenuEx(menu, flags, x, anchor.bottom, owner, if (empty) null else @ptrCast(&params));
    if (!ownerAlive(owner) or cmd <= 0) return null;
    return @intCast(cmd);
}

fn nativeMenu(alloc: Allocator, list: *const List) error{ Win32Error, OutOfMemory }!w32.HMENU {
    const menu = w32.CreatePopupMenu() orelse return error.Win32Error;
    errdefer _ = w32.DestroyMenu(menu);
    var used: AccessSet = .initEmpty();
    for (list.items.items) |item| if (item.access) |key| if (accessBit(key)) |bit| used.set(bit);
    for (list.items.items) |item| {
        switch (item.kind) {
            .separator => _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null),
            .header => {
                const text = try nativeLabel(alloc, item.label, null, null);
                _ = w32.AppendMenuW(menu, w32.MF_STRING | w32.MF_GRAYED | MF_DISABLED, 0, text);
            },
            .action, .submenu => {
                const key = item.access orelse if (item.selectable()) pick: {
                    const k = pickAccessKey(item.label, used) orelse break :pick null;
                    used.set(accessBit(k).?);
                    break :pick k;
                } else null;
                const text = try nativeLabel(alloc, item.label, key, item.shortcut);
                var flags: u32 = w32.MF_STRING;
                if (!item.selectable()) flags |= w32.MF_GRAYED;
                if (item.mark != .none) flags |= MF_CHECKED;
                var id: usize = item.id;
                if (item.kind == .submenu) {
                    const child = try nativeMenu(alloc, item.submenu.?);
                    flags |= w32.MF_POPUP;
                    id = @intFromPtr(child);
                }
                if (w32.AppendMenuW(menu, flags, id, text) == 0 and item.kind == .submenu) {
                    _ = w32.DestroyMenu(@ptrFromInt(id));
                }
                if (item.kind == .action and item.mark == .radio) {
                    const command: u32 = @intCast(item.id);
                    _ = CheckMenuRadioItem(menu, command, command, command, MF_BYCOMMAND);
                }
            },
        }
    }
    return menu;
}

/// A native menu label: `label` with `&` doubled, the access key marked
/// with `&` (or appended as "(&K)"), then a tab and the shortcut.
fn nativeLabel(alloc: Allocator, label: []const u8, key: ?u8, shortcut: ?[]const u8) Allocator.Error![*:0]const u16 {
    var text: std.ArrayList(u8) = .empty;
    const at = if (key) |k| accessIndex(label, k) else null;
    for (label, 0..) |c, i| {
        if (at != null and i == at.?) try text.append(alloc, '&');
        if (c == '&') try text.append(alloc, '&');
        try text.append(alloc, c);
    }
    if (key != null and at == null) try text.print(alloc, "(&{c})", .{std.ascii.toUpper(key.?)});
    if (shortcut) |keys| try text.print(alloc, "\t{s}", .{keys});
    return try wstr.allocZ(alloc, text.items);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "Builder copies text and nests submenus" {
    var builder: Builder = .init(testing.allocator);
    defer builder.deinit();

    var label_buf = "Copy".*;
    var shortcut_buf = "Ctrl+C".*;
    try builder.add(&builder.root, .{ .id = 1, .label = &label_buf, .shortcut = &shortcut_buf, .access = 'c' });
    label_buf[0] = 'X';
    shortcut_buf[0] = 'X';
    try builder.separator(&builder.root);
    try builder.header(&builder.root, "Section");
    const split = try builder.submenu(&builder.root, .{ .label = "Split" });
    try builder.add(split, .{ .id = 2, .label = "Right" });
    _ = try builder.submenu(&builder.root, .{ .label = "Empty" });

    const items = builder.root.items.items;
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("Copy", items[0].label);
    try testing.expectEqualStrings("Ctrl+C", items[0].shortcut.?);
    try testing.expectEqual(@as(?u8, 'C'), items[0].access);
    try testing.expect(items[0].selectable());
    try testing.expect(!items[1].selectable());
    try testing.expect(!items[2].selectable());
    try testing.expectEqual(Item.Kind.submenu, items[3].kind);
    try testing.expect(items[3].selectable());
    try testing.expectEqualStrings("Right", items[3].submenu.?.items.items[0].label);
    try testing.expect(!items[4].selectable());
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) w32.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

test "placeRoot lines up with the anchor and flips at the work area edges" {
    const work = rect(0, 0, 1920, 1040);
    // A button at the right: right-aligned below it.
    const button = rect(1800, 0, 1836, 40);
    try testing.expectEqual(rect(1536, 40, 1836, 440), placeRoot(button, 300, 400, work, .right));
    // Left-aligned, it would leave the screen: flipped to the right edge.
    try testing.expectEqual(rect(1536, 40, 1836, 440), placeRoot(button, 300, 400, work, .left));
    // A button at the left edge, right-aligned: flipped to its left edge.
    const left_button = rect(10, 0, 46, 40);
    try testing.expectEqual(rect(10, 40, 310, 440), placeRoot(left_button, 300, 400, work, .right));
    // A point: below and to the right of it, else above or to the left.
    const point = Options.at(.{ .x = 100, .y = 100 });
    try testing.expectEqual(rect(100, 100, 400, 500), placeRoot(point, 300, 400, work, .left));
    const corner = Options.at(.{ .x = 1900, .y = 1000 });
    try testing.expectEqual(rect(1600, 600, 1900, 1000), placeRoot(corner, 300, 400, work, .left));
    // No room below a button near the bottom: above it.
    const low = rect(500, 900, 540, 940);
    try testing.expectEqual(rect(500, 500, 800, 900), placeRoot(low, 300, 400, work, .left));
}

test "placeRoot keeps a tall menu on the screen and limits its height" {
    const work = rect(0, 40, 1920, 1080);
    // Fits neither below nor above the point: moved over it.
    const middle = Options.at(.{ .x = 100, .y = 560 });
    try testing.expectEqual(rect(100, 380, 400, 1080), placeRoot(middle, 300, 700, work, .left));
    // Taller than the work area: as tall as it, from its top.
    try testing.expectEqual(rect(100, 40, 400, 1080), placeRoot(middle, 300, 5000, work, .left));
    // Wider than the work area: at its left edge.
    try testing.expectEqual(@as(i32, 0), placeRoot(middle, 3000, 100, work, .right).left);
    // A work area on a monitor left of the primary one.
    const left_monitor = rect(-1920, 0, 0, 1040);
    const anchor = rect(-60, 0, -24, 40);
    try testing.expectEqual(rect(-324, 40, -24, 240), placeRoot(anchor, 300, 200, left_monitor, .right));
}

test "placeSubmenu opens beside the item and flips to the left" {
    const work = rect(0, 0, 1920, 1040);
    const parent = rect(100, 100, 400, 600);
    try testing.expectEqual(rect(396, 196, 646, 496), placeSubmenu(parent, 200, 250, 300, work, 4, 4));
    // No room on the right.
    const right_parent = rect(1600, 100, 1900, 600);
    try testing.expectEqual(rect(1354, 196, 1604, 496), placeSubmenu(right_parent, 200, 250, 300, work, 4, 4));
    // Near the bottom: moved up to stay on the screen.
    try testing.expectEqual(rect(396, 740, 646, 1040), placeSubmenu(parent, 900, 250, 300, work, 4, 4));
}

test "inAimTriangle follows a pointer heading for the submenu" {
    // A submenu whose left edge runs at x = 300 from y = 100 to y = 400.
    const from: w32.POINT = .{ .x = 200, .y = 150 };
    // Diagonally down toward the submenu: in the triangle.
    try testing.expect(inAimTriangle(from, .{ .x = 220, .y = 170 }, 300, 100, 400));
    // Straight down along the parent: out of it.
    try testing.expect(!inAimTriangle(from, .{ .x = 200, .y = 190 }, 300, 100, 400));
    // Away from the submenu.
    try testing.expect(!inAimTriangle(from, .{ .x = 180, .y = 160 }, 300, 100, 400));
    // Too steep: below the line to the submenu's bottom corner.
    try testing.expect(!inAimTriangle(from, .{ .x = 210, .y = 300 }, 300, 100, 400));
    // No movement is no aim.
    try testing.expect(!inAimTriangle(from, from, 300, 100, 400));
    // A submenu on the left (its right edge at x = 100).
    try testing.expect(inAimTriangle(from, .{ .x = 180, .y = 160 }, 100, 100, 400));
}

const FakeLevel = struct {
    hot: ?usize = null,
    keyboard: bool = false,
    parent_item: ?usize = null,

    fn setHot(self: *FakeLevel, item: ?usize, keyboard: bool) void {
        self.hot = item;
        self.keyboard = keyboard;
    }
};

test "highlightPath lights the entries of the open submenus" {
    // Root, a submenu opened from root item 2, and one from its item 1;
    // the root's highlight had moved to item 5 on the way.
    var levels = [_]FakeLevel{
        .{ .hot = 5 },
        .{ .hot = 3, .parent_item = 2 },
        .{ .hot = null, .parent_item = 1 },
    };
    highlightPath(levels[0..], 2);
    try testing.expectEqual(@as(?usize, 2), levels[0].hot);
    try testing.expectEqual(@as(?usize, 1), levels[1].hot);
    try testing.expectEqual(@as(?usize, null), levels[2].hot);
    // In the middle level only the root follows.
    levels[0].hot = 7;
    levels[1].hot = 4;
    highlightPath(levels[0..], 1);
    try testing.expectEqual(@as(?usize, 2), levels[0].hot);
    try testing.expectEqual(@as(?usize, 4), levels[1].hot);
    // The root alone has no path.
    highlightPath(levels[0..1], 0);
    try testing.expectEqual(@as(?usize, 2), levels[0].hot);
}

test "pickAccessKey prefers word starts and skips taken keys" {
    var used: AccessSet = .initEmpty();
    try testing.expectEqual(@as(?u8, 'N'), pickAccessKey("New Tab", used));
    used.set(accessBit('N').?);
    try testing.expectEqual(@as(?u8, 'T'), pickAccessKey("New Tab", used));
    used.set(accessBit('T').?);
    try testing.expectEqual(@as(?u8, 'E'), pickAccessKey("New Tab", used));
    try testing.expectEqual(@as(?u8, '7'), pickAccessKey("pwsh 7", blk: {
        var s: AccessSet = .initEmpty();
        s.set(accessBit('P').?);
        break :blk s;
    }));
    // No ASCII letters: no key.
    try testing.expectEqual(@as(?u8, null), pickAccessKey("简体中文", .initEmpty()));
    try testing.expectEqual(@as(?u8, 'G'), pickAccessKey("新建 GX Zsh", .initEmpty()));
}

test "access keys in labels and the (K) suffix" {
    const alloc = testing.allocator;
    try testing.expectEqual(@as(?usize, 4), accessIndex("New Tab", 'T'));
    // A word start wins over an earlier letter.
    try testing.expectEqual(@as(?usize, 19), accessIndex("Open Configuration File", 'F'));
    try testing.expectEqual(@as(?usize, 1), accessIndex("Settings…", 'E'));
    try testing.expectEqual(@as(?usize, null), accessIndex("设置…", 'E'));

    const in_label = try cueLabel(alloc, "New Tab", 't', true);
    try testing.expectEqualStrings("New Tab", in_label.text);
    try testing.expectEqual(@as(?usize, 4), in_label.underline);

    const suffixed = try cueLabel(alloc, "新建标签页", 't', true);
    defer alloc.free(suffixed.text);
    try testing.expectEqualStrings("新建标签页(T)", suffixed.text);
    try testing.expectEqual('T', suffixed.text[suffixed.underline.?]);

    const ellipsis = try cueLabel(alloc, "设置…", 'E', true);
    defer alloc.free(ellipsis.text);
    try testing.expectEqualStrings("设置(E)…", ellipsis.text);
    try testing.expectEqual('E', ellipsis.text[ellipsis.underline.?]);

    // Without the suffix a translated label stays as it is.
    const plain = try cueLabel(alloc, "设置…", 'E', false);
    try testing.expectEqualStrings("设置…", plain.text);
    try testing.expectEqual(@as(?usize, null), plain.underline);
}

test "accessTarget picks a unique key and cycles through shared ones" {
    const keys = [_]?u8{ 'N', null, 'S', 'P', 'S', null };
    try testing.expectEqual(AccessHit{ .item = 0, .unique = true }, accessTarget(&keys, null, 'n').?);
    try testing.expectEqual(AccessHit{ .item = 3, .unique = true }, accessTarget(&keys, 4, 'P').?);
    try testing.expectEqual(AccessHit{ .item = 2, .unique = false }, accessTarget(&keys, null, 'S').?);
    try testing.expectEqual(AccessHit{ .item = 4, .unique = false }, accessTarget(&keys, 2, 'S').?);
    // Wraps around after the last one.
    try testing.expectEqual(AccessHit{ .item = 2, .unique = false }, accessTarget(&keys, 4, 'S').?);
    try testing.expectEqual(@as(?AccessHit, null), accessTarget(&keys, null, 'X'));
}

test "native labels mark the access key and keep ampersands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqualSlices(u16, L("New &Tab\tCtrl+Shift+T"), std.mem.span(try nativeLabel(alloc, "New Tab", 'T', "Ctrl+Shift+T")));
    try testing.expectEqualSlices(u16, L("R&&D &Tools"), std.mem.span(try nativeLabel(alloc, "R&D Tools", 'T', null)));
    try testing.expectEqualSlices(u16, L("设置(&E)"), std.mem.span(try nativeLabel(alloc, "设置", 'E', null)));
    try testing.expectEqualSlices(u16, L("Header"), std.mem.span(try nativeLabel(alloc, "Header", null, null)));
}

test "accessChar reads letters, digits and the number pad" {
    try testing.expectEqual(@as(?u8, 'A'), accessChar('A'));
    try testing.expectEqual(@as(?u8, '7'), accessChar('7'));
    try testing.expectEqual(@as(?u8, '3'), accessChar(w32.VK_NUMPAD3));
    try testing.expectEqual(@as(?u8, null), accessChar(w32.VK_F5));
}

test "pageFrom moves by a viewport and skips disabled rows" {
    var items: [12]Item = @splat(.{ .label = "row" });
    items[3].enabled = false;
    var rows: [12]Row = undefined;
    for (&rows, 0..) |*row, i| row.* = .{ .top = @intCast(i * 48), .height = 48 };
    try testing.expectEqual(@as(usize, 2), pageFrom(&rows, &items, 0, 192, .next));
    try testing.expectEqual(@as(usize, 5), pageFrom(&rows, &items, 2, 192, .next));
    try testing.expectEqual(@as(usize, 2), pageFrom(&rows, &items, 5, 192, .previous));
    try testing.expectEqual(@as(usize, 11), pageFrom(&rows, &items, 11, 192, .next));
    try testing.expectEqual(@as(usize, 0), pageFrom(&rows, &items, 0, 192, .previous));
}

test "scrolling a long menu keeps the selected row visible" {
    var popup: Popup = .{};
    var rows: [40]Row = undefined;
    for (&rows, 0..) |*row, i| row.* = .{ .top = @intCast(6 + i * 48), .height = 48 };
    var level: Level = .{
        .state = undefined,
        .index = 0,
        .popup = &popup,
        .list = undefined,
        .parent_item = null,
        .rows = &rows,
        .scale = 1.5,
        .content_px = 1932,
        .bounds = rect(0, 0, 300, 600),
        .arrow_px = 24,
    };
    level.ensureVisible(39);
    try testing.expect(level.scroll_px > 0);
    try testing.expect(rows[39].top + rows[39].height <= level.scroll_px + level.viewHeight());
    level.ensureVisible(0);
    try testing.expectEqual(@as(i32, 0), level.scroll_px);
    try testing.expectEqual(@as(?usize, 0), level.rowAt(6));
    try testing.expectEqual(@as(?usize, 1), level.rowAt(54));
    try testing.expect(!level.scrollTo(0));
}

test "waitMs sleeps until a deadline rather than polling at 50 Hz" {
    var state: State = undefined;
    state.pending = null;
    state.aim_due = null;
    state.autoscroll = null;
    try testing.expectEqual(@as(u32, 250), state.waitMs(1000));
    state.pending = .{ .level = 0, .item = 1, .due = 1400 };
    try testing.expectEqual(@as(u32, 250), state.waitMs(1000));
    state.aim_due = 1100;
    try testing.expectEqual(@as(u32, 100), state.waitMs(1000));
    state.autoscroll = .{ .level = 0, .direction = .down, .due = 1016 };
    try testing.expectEqual(@as(u32, 16), state.waitMs(1000));
    try testing.expectEqual(@as(u32, 0), state.waitMs(1020));
}

test "light menus lift toward white without changing dark surfaces" {
    const light = style.Tokens.fromColors(d2d.Color.hex(0xeeeeee), d2d.Color.hex(0x202020), d2d.Color.hex(0x0067c0));
    const fills = Fills.of(light);
    try testing.expect(fills.surface.r > light.background.r);
    try testing.expect(style.contrast(light.text_secondary, fills.surface) >= 4.5);
    const dark = style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    try testing.expectEqual(dark.surface_raised, Fills.of(dark).surface);
}

test "Left restores the parent entry after hovering a sibling" {
    var state: State = undefined;
    state.depth = 2;
    state.result = .open;
    state.popups = @splat(.{});
    state.press = null;
    state.pending = null;
    state.aim_due = null;
    state.autoscroll = null;
    state.cues = true;
    for (0..2) |i| state.levels[i] = .{
        .state = &state,
        .index = i,
        .popup = &state.popups[i],
        .list = undefined,
        .parent_item = if (i == 0) null else 2,
        .hot = if (i == 0) 5 else null,
    };
    try testing.expect(state.handleKey(w32.VK_LEFT));
    try testing.expectEqual(@as(usize, 1), state.depth);
    try testing.expectEqual(@as(?usize, 2), state.levels[0].hot);
    try testing.expect(state.levels[0].hot_keyboard);
}

test "inAimTriangle rejects degenerate edges" {
    try testing.expect(!inAimTriangle(.{ .x = 300, .y = 150 }, .{ .x = 300, .y = 500 }, 300, 100, 400));
    try testing.expect(!inAimTriangle(.{ .x = 200, .y = 150 }, .{ .x = 220, .y = 170 }, 300, 400, 400));
}

test "a hidden or minimized owner cancels the menu even while foreground" {
    try testing.expect(ownerAvailable(true, true, false, true));
    try testing.expect(!ownerAvailable(true, false, false, true));
    try testing.expect(!ownerAvailable(true, true, true, true));
    try testing.expect(!ownerAvailable(false, true, false, true));
    try testing.expect(!ownerAvailable(true, true, false, false));
}

test "raster keys include the Direct2D factory identity" {
    const key: RasterKey = .{ .factory = 1, .d2d_factory = 2 };
    try testing.expect(std.meta.eql(key, RasterKey{ .factory = 1, .d2d_factory = 2 }));
    try testing.expect(!std.meta.eql(key, RasterKey{ .factory = 1, .d2d_factory = 3 }));
    try testing.expect(!std.meta.eql(key, RasterKey{ .factory = 4, .d2d_factory = 2 }));
}

test "raster resources transfer once without keeping a popup or callback" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var factory: d2d.Factory = .{
        .alloc = testing.allocator,
        .d2d = @ptrFromInt(0x1000),
        .d2d_1_1 = false,
        .dwrite = @ptrFromInt(0x2000),
        .ui_family = L("test"),
        .icon_family = L("test"),
        .mono_family = L("test"),
    };
    var source: Popup = .{ .layered = true, .canvas = .init(&factory) };
    defer source.destroy();
    source.canvas.?.warned = true;
    var saved: RasterCache = .{};
    defer saved.clear();
    try testing.expect(saved.capture(&source));
    try testing.expect(source.canvas == null);
    try testing.expect(saved.canvas.?.warned);
    try testing.expect(!saved.capture(&source));

    var destination: Popup = .{ .layered = true, .canvas = .init(&factory) };
    defer destination.destroy();
    try testing.expect(saved.restore(&destination));
    try testing.expect(destination.canvas.?.warned);
    try testing.expect(saved.canvas == null and saved.key == null);
    try testing.expect(!saved.restore(&destination));

    try testing.expect(saved.capture(&destination));
    destination.canvas = .init(&factory);
    factory.d2d = @ptrFromInt(0x3000);
    try testing.expect(!saved.restore(&destination));
    try testing.expect(saved.canvas == null and saved.key == null);
    try testing.expect(saved.capture(&destination));
    destination.canvas = .init(&factory);
    destination.layered = false;
    try testing.expect(!saved.restore(&destination));
    try testing.expect(saved.canvas == null and saved.key == null);
}
