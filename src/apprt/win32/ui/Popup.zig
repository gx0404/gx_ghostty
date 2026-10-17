//! Reusable owned popup host for custom-drawn UI (link preview, command
//! palette, menus, flyouts): a `WS_POPUP` window owned by a terminal
//! window, with Windows 11 rounded corners (`DWMWA_WINDOW_CORNER_PREFERENCE`)
//! and the system drop shadow, per-monitor DPI, Direct2D rendering through
//! a `d2d.Canvas`, keyboard, mouse (hover/click/wheel) and an optional
//! IME-capable single-line text input for filter boxes.
//!
//! Usage: embed a `Popup` in an address-stable owner struct, `create` it
//! once with `Callbacks` (paint, key, mouse, text, dismissed), position it
//! with `show(rect)` (screen pixels; size content in DIPs with `scale`),
//! repaint with `invalidate`, and `destroy` it with the owner. Dismissal
//! (Escape, click outside, lost activation) hides the popup and reports
//! the reason through `Callbacks.dismissed`. A popup that belongs to a
//! window's chrome follows the window's content scale (`setOwnerScale`);
//! `applyTheme` follows a theme change without a new window.
//!
//! Lifecycle: `show` from hidden keeps the window cloaked until it painted
//! once (synchronously) and a frame passed (timer `RV`), so DWM never
//! shows it empty; `show` and `setBounds` leave an unchanged window alone.
//! WM_CLOSE (Alt+F4, the system close) hides a shown popup instead of
//! destroying it, reports `.owner` and, for an activating popup with
//! `Options.close_owner_on_close`, closes the window it belongs to; a
//! hidden popup ignores it. When Windows destroys the popup with its owner
//! (WM_NCDESTROY), `hwnd` becomes null and the render target goes; the
//! owner frees the rest with `destroy` or recreates it with `create`.
//! With `Options.keep_owner_active` an activating popup sends
//! `WM_GX_OWNER_ACTIVE_LOCK` (wparam 1) to its root owner before it takes
//! activation and (wparam 0) once it hid or lost activation, so the owner
//! can keep painting its frame as active; the owner re-evaluates its
//! frame on unlock. With `Options.motion` the popup fades in (`anim`, the
//! 167 ms entrance of `gx.motion`) as a layered window painted through a
//! `d2d.DibTarget`.
//!
//! Text input: with `Options.text_input` the popup keeps a `TextInput`
//! (`popup.input`) that receives typing, editing keys (`text_edit`: words,
//! undo, Shift+Insert/Ctrl+Insert/Shift+Delete), clipboard (a paste keeps
//! the field within `text_edit.max_len` code units), mouse selection and
//! IME composition; draw it with `drawTextInput` (or
//! `drawTextInputEx`) in the paint callback and read it with
//! `TextInput.text`. Keys go to `Callbacks.key` first, so owners can take
//! Up/Down/Enter before the input sees them. The caret blinks at the
//! system rate (timer `CB`) only while the popup has the keyboard focus,
//! and an invisible system caret follows it for magnifiers; the IME
//! candidate window is placed below the field (`CFS_EXCLUDE`) only while
//! composing. `Callbacks.composition_changed` reports the composition.
//!
//! Owner timers and messages: `startRepeat` (timer `RP`) calls
//! `Callbacks.repeat` at the keyboard repeat rate while a button is held;
//! other timers set on the popup window go to `Callbacks.timer`, and
//! `WM_APP` messages posted to it to `Callbacks.message`.
const Popup = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard = @import("../clipboard.zig");
const w32 = @import("../win32.zig");
const anim = @import("anim.zig");
const d2d = @import("d2d.zig");
const dcomp = @import("dcomp.zig");
const style = @import("style.zig");
const text_edit = @import("text_edit.zig");
const wstr = @import("wstr.zig");
const App = @import("../App.zig");
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const perf = @import("../../../gx/perf.zig");
const global = @import("../../../global.zig");

const log = std.log.scoped(.win32_popup);

/// One GUI-thread opening, through successful painting and uncloaking (or
/// completion of its fade). Text layout performed while painting belongs to
/// raster, not to the earlier geometry/layout phase. Cancelled opens emit no
/// successful sample. The five phases partition total, including reveal waits.
pub const OpenTiming = struct {
    pub const Kind = enum { palette, menu, settings };
    pub const Phase = enum { prepare, create, layout, raster, show };
    kind: Kind,
    start: perf.Instant,
    last: perf.Instant,
    phases: [5]u64 = @splat(0),
    painted: bool = false,

    pub fn begin(kind: Kind) ?OpenTiming {
        if (!perf.enabled()) return null;
        const at = perf.now(global.io());
        return .{ .kind = kind, .start = at, .last = at };
    }

    pub fn lap(self: *OpenTiming, phase: Phase) void {
        const at = perf.now(global.io());
        self.add(phase, perf.elapsedUs(self.last, at));
        self.last = at;
    }

    fn add(self: *OpenTiming, phase: Phase, us: u64) void {
        self.phases[@intFromEnum(phase)] += us;
    }

    fn finishAt(self: *OpenTiming, at: perf.Instant) u64 {
        const total = perf.elapsedUs(self.start, at);
        var work: u64 = 0;
        for (self.phases[0..4]) |us| work += us;
        self.phases[@intFromEnum(Phase.show)] = total -| work;
        return total;
    }

    fn report(self: *OpenTiming) void {
        const total = self.finishAt(perf.now(global.io()));
        switch (self.kind) {
            inline else => |kind| {
                inline for (std.meta.fields(Phase), 0..) |phase, i| {
                    perf.record(@tagName(kind) ++ ".open." ++ phase.name, self.phases[i]);
                }
                perf.record(@tagName(kind) ++ ".open.total", total);
            },
        }
    }
};

/// DWM corner preference of the popup (DWM_WINDOW_CORNER_PREFERENCE).
pub const Corners = enum(u32) {
    default = 0,
    square = 1,
    round = 2,
    round_small = 3,
};

pub const DismissReason = enum {
    /// Escape was pressed.
    escape,
    /// The user clicked outside the popup (mouse capture).
    outside_click,
    /// The popup lost activation (clicked elsewhere, Alt+Tab).
    deactivated,
    /// The owner asked for it (`dismiss`), or the system closed it
    /// (WM_CLOSE).
    owner,
};

pub const MouseKind = enum { move, leave, down, up, double_click, wheel };
pub const MouseButton = enum { none, left, right, middle };

pub const MouseEvent = struct {
    kind: MouseKind,
    button: MouseButton = .none,
    /// Position in DIPs relative to the client area.
    pos: d2d.Point,
    /// Wheel notches (positive = away from the user).
    wheel: f32 = 0,
};

pub const Key = struct {
    vk: u16,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

/// The pointer shape over a point of the popup.
pub const Cursor = enum { arrow, ibeam, hand };

pub const Callbacks = struct {
    /// Passed to every callback.
    ctx: *anyopaque,
    uia_source: ?UiaSource = null,
    /// Paint the content in DIPs. The canvas is cleared to transparent
    /// black; fill the background yourself.
    paint: *const fn (ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void,
    /// A key press. Return true when handled; unhandled keys go to the
    /// text input and then to Escape dismissal.
    key: ?*const fn (ctx: *anyopaque, popup: *Popup, key: Key) bool = null,
    mouse: ?*const fn (ctx: *anyopaque, popup: *Popup, event: MouseEvent) void = null,
    /// The text input changed (typing, deletion, paste, IME commit).
    text_changed: ?*const fn (ctx: *anyopaque, popup: *Popup) void = null,
    /// The popup was dismissed and is now hidden.
    dismissed: ?*const fn (ctx: *anyopaque, popup: *Popup, reason: DismissReason) void = null,
    /// The popup moved to a monitor with another DPI; resize it.
    dpi_changed: ?*const fn (ctx: *anyopaque, popup: *Popup) void = null,
    /// The IME composition of the text input changed (started, edited,
    /// committed or canceled); `popup.input.composition` holds it.
    composition_changed: ?*const fn (ctx: *anyopaque, popup: *Popup) void = null,
    /// The pointer shape at a point (DIPs); null for the default (an
    /// I-beam over the text input, else the arrow).
    cursor: ?*const fn (ctx: *anyopaque, popup: *Popup, pos: d2d.Point) ?Cursor = null,
    /// A timer the owner set on the popup window fired (not `RV`, `CB`,
    /// `RP`).
    timer: ?*const fn (ctx: *anyopaque, popup: *Popup, id: usize) void = null,
    /// `startRepeat(tag)` is held down: repeat its action.
    repeat: ?*const fn (ctx: *anyopaque, popup: *Popup, tag: u32) void = null,
    /// A `WM_APP` message the owner posted to the popup window (e.g. to
    /// show itself from the message loop); return true when handled.
    message: ?*const fn (ctx: *anyopaque, popup: *Popup, msg: u32, wparam: usize, lparam: isize) bool = null,
};

pub const UiaSource = struct {
    app: *App,
    /// GUI-only data copy. Must not pump messages or destroy the widget.
    build: *const fn (*anyopaque, *Popup, *uia_bridge.PopupBridge, *uia.Api, *uia.Queue) anyerror!void,
    is_live: *const fn (*anyopaque) bool,
    action: *const fn (*anyopaque, u64, *const uia.Action) bool,
};

// Every popup is created on the one GUI thread. Zero is the revoked cookie.
var next_uia_cookie: u64 = 1;

/// How a popup with `Options.motion` comes in.
pub const Motion = struct {
    /// Where it starts relative to its place, in DIPs (e.g. y = -8 for a
    /// dropdown, 8 for a bar at the bottom); it slides there while fading.
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const Options = struct {
    /// Take activation and keyboard focus when shown. Non-activating
    /// popups (previews, tooltips) never take focus.
    activate: bool = false,
    /// Dismiss on Escape.
    dismiss_on_escape: bool = true,
    /// Dismiss when an activating popup loses activation, or (with
    /// `capture_mouse`) on a click outside.
    dismiss_on_outside_click: bool = true,
    /// Capture the mouse while shown, like a menu.
    capture_mouse: bool = false,
    /// Let mouse input fall through to the window below (status bubbles).
    click_through: bool = false,
    corners: Corners = .round,
    /// The system drop shadow (CS_DROPSHADOW).
    shadow: bool = true,
    /// Keep a `TextInput` and route typing and IME input to it.
    text_input: bool = false,
    /// The 1px DWM border color (Windows 11), or the system default.
    border_color: ?d2d.Color = null,
    /// Use the dark DWM frame variant.
    dark: bool = true,
    /// Keep the owner painted as active while this activating popup has
    /// the focus (`WM_GX_OWNER_ACTIVE_LOCK`); modal dialogs leave it off.
    keep_owner_active: bool = false,
    /// Fade in when shown (when `anim.enabled`).
    motion: ?Motion = null,
    /// The name screen readers and automation tools see.
    accessible_name: []const u8 = "",
    /// Release the render target while hidden (popups shown rarely).
    release_target_on_hide: bool = false,
    /// When an activating popup gets WM_CLOSE (Alt+F4, the system close),
    /// also close its root owner window: Alt+F4 closes the window, not just
    /// the popup. Modal dialogs turn it off and treat the close as Cancel
    /// (`Callbacks.dismissed` with `.owner`). Popups that never take the
    /// focus only hide.
    close_owner_on_close: bool = true,
};

/// Sent (not posted) to the root owner window of a popup with
/// `Options.keep_owner_active`: wparam 1 before the popup takes
/// activation, 0 after it hid or lost activation; lparam is the popup.
pub const WM_GX_OWNER_ACTIVE_LOCK: u32 = w32.WM_APP + 38;

/// Timers on the popup window: the first-frame reveal, the caret blink and
/// the held-button repeat.
pub const REVEAL_TIMER_ID: usize = 0x5256; // 'RV'
pub const CARET_TIMER_ID: usize = 0x4342; // 'CB'
pub const REPEAT_TIMER_ID: usize = 0x5250; // 'RP'

hwnd: ?w32.HWND = null,
owner: ?w32.HWND = null,
canvas: ?d2d.Canvas = null,
composition: ?dcomp.Backend = null,
composition_requested: bool = false,
composition_attempted: bool = false,
composition_failed: bool = false,
composition_frame: ?dcomp.FrameKey = null,
composition_generation: u64 = 0,
composition_failure: dcomp.Failure = .none,
alloc: Allocator = undefined,
options: Options = .{},
callbacks: ?Callbacks = null,
uia_view: uia_bridge.PopupBridge = .{},
uia_cookie: u64 = 0,
uia_refreshing: bool = false,
uia_layout_pending: bool = true,
visible: bool = false,
open_timing: ?OpenTiming = null,
dpi: u32 = 96,
/// The owner's content scale relative to its window DPI (`setOwnerScale`),
/// applied on top of `dpi`.
zoom: f32 = 1,
tracking_leave: bool = false,
/// The popup has the keyboard focus.
focused: bool = false,

/// The text input (with `Options.text_input`).
input: TextInput = .{},

/// The scale of the last paint, to repaint when it changes.
paint_scale: f32 = 0,
/// Cloaked until the reveal timer, after the first paint.
revealing: bool = false,
/// Created as a layered window for `Options.motion`; painted through `dib`.
layered: bool = false,
dib: d2d.DibTarget = .{},
/// The fade-in: its animator, progress and the final place.
animator: anim.Animator = .{ .tick = animTick },
fade: anim.Tween = .{ .start_ns = 0, .duration_ns = 0 },
fade_pending: bool = false,
fade_target: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
/// Sent the owner a lock (`WM_GX_OWNER_ACTIVE_LOCK`).
owner_locked: bool = false,
/// The invisible system caret exists.
system_caret: bool = false,
/// When the caret blink started, for the system caret timeout.
blink_started: u64 = 0,
/// `startRepeat` is running with this tag; the first tick waits longer.
repeat_tag: ?u32 = null,
repeat_started: bool = false,
/// The last click on the text input, for triple clicks.
last_click_time: u64 = 0,
last_click_count: u8 = 0,

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxPopup");
const CLASS_NAME_SHADOW = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxPopupShadow");

const CS_DROPSHADOW: u32 = 0x00020000;
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWA_CLOAK: u32 = 13;
const HTTRANSPARENT: isize = -1;
const WM_NCHITTEST: u32 = 0x0084;
const WM_NCDESTROY: u32 = 0x0082;
const WM_CAPTURECHANGED: u32 = 0x0215;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_IME_CHAR: u32 = 0x0286;
const WM_SYSCOMMAND: u32 = 0x0112;
const SC_CLOSE: usize = 0xF060;
const SW_PARENTOPENING: isize = 3;
const GA_ROOTOWNER: u32 = 3;
const RDW_UPDATENOW: u32 = 0x0100;
const GCS_COMPATTR: u32 = 0x0010;
const GCS_CURSORPOS: u32 = 0x0080;
const ATTR_TARGET_CONVERTED: u8 = 1;
const ATTR_TARGET_NOTCONVERTED: u8 = 3;
const SPI_GETCARETWIDTH: u32 = 0x2006;
const SPI_GETCARETTIMEOUT: u32 = 0x2022;
const SPI_GETKEYBOARDDELAY: u32 = 0x0016;
const SPI_GETKEYBOARDSPEED: u32 = 0x000A;

/// How long a new popup stays cloaked after its first paint: about a
/// frame, so DWM composed it before it appears.
const reveal_ms: u32 = 16;

/// Create the (hidden) popup window owned by `owner`.
pub fn create(
    self: *Popup,
    hinstance: w32.HINSTANCE,
    owner: w32.HWND,
    factory: *d2d.Factory,
    options: Options,
    callbacks: Callbacks,
) !void {
    if (self.hwnd != null) return;
    self.uiaDetach();
    if (next_uia_cookie == std.math.maxInt(u64)) return error.Exhausted;
    const uia_cookie = next_uia_cookie;
    next_uia_cookie += 1;
    try registerClasses(hinstance);
    // A popup Windows destroyed with its owner may come back: free what
    // the old window left.
    self.freeResources();

    const layered = options.motion != null and anim.enabled();
    var ex_style: u32 = w32.WS_EX_TOOLWINDOW;
    if (!options.activate) ex_style |= w32.WS_EX_NOACTIVATE;
    if (layered) ex_style |= w32.WS_EX_LAYERED;
    const hwnd = w32.CreateWindowExW(
        ex_style,
        if (options.shadow) CLASS_NAME_SHADOW else CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        1,
        1,
        owner,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;

    self.* = .{
        .hwnd = hwnd,
        .owner = owner,
        .canvas = d2d.Canvas.init(factory),
        .composition_requested = dcomp.enabled(),
        .alloc = factory.alloc,
        .options = options,
        .callbacks = callbacks,
        .uia_cookie = uia_cookie,
        .dpi = dpiOf(owner),
        .layered = layered,
        .input = .{ .alloc = factory.alloc },
    };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    const corners: u32 = @intFromEnum(options.corners);
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, @ptrCast(&corners), @sizeOf(u32));
    const dark: u32 = @intFromBool(options.dark);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&dark), @sizeOf(u32));
    if (options.border_color) |color| self.setBorderColor(color);
    if (layered) _ = w32.SetLayeredWindowAttributes(hwnd, 0, 255, w32.LWA_ALPHA);
    if (options.accessible_name.len > 0) self.setAccessibleName(options.accessible_name);
}

/// Free the canvas and text input of a popup whose window Windows already
/// destroyed (they outlive it).
fn freeResources(self: *Popup) void {
    self.releaseComposition();
    if (self.canvas) |*canvas| canvas.deinit();
    self.canvas = null;
    self.dib.deinit();
    if (self.input.alloc) |alloc| self.input.deinit(alloc);
}

/// Destroy the window and its resources.
pub fn destroy(self: *Popup) void {
    self.uiaDetach();
    self.releaseComposition();
    if (self.hwnd) |hwnd| {
        self.unlockOwner();
        anim.stop(&self.animator);
        if (self.system_caret) _ = DestroyCaret();
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
    }
    if (self.canvas) |*canvas| canvas.deinit();
    self.dib.deinit();
    if (self.input.alloc) |alloc| self.input.deinit(alloc);
    self.* = .{};
}

/// Set the 1px DWM border color (Windows 11).
pub fn setBorderColor(self: *Popup, color: d2d.Color) void {
    const hwnd = self.hwnd orelse return;
    const ref: u32 = d2d.colorRef(color);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_BORDER_COLOR, @ptrCast(&ref), @sizeOf(u32));
}

/// Follow a theme change: the border color and the dark or light frame,
/// without a new window.
pub fn applyTheme(self: *Popup, tokens: style.Tokens) void {
    self.options.dark = tokens.dark;
    self.options.border_color = tokens.border;
    const hwnd = self.hwnd orelse return;
    const dark: u32 = @intFromBool(tokens.dark);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&dark), @sizeOf(u32));
    self.setBorderColor(tokens.border);
    self.invalidate();
}

/// Name the popup for screen readers and automation (its window text),
/// e.g. the translated "Command Palette".
pub fn setAccessibleName(self: *Popup, name: []const u8) void {
    const hwnd = self.hwnd orelse return;
    var buf: [256]u16 = undefined;
    _ = w32.SetWindowTextW(hwnd, wstr.bufZ(&buf, name));
}

/// Release the render target (it is recreated by the next paint).
pub fn discardTarget(self: *Popup) void {
    if (self.composition) |*backend| backend.reset();
    self.composition_frame = null;
    if (self.canvas) |*canvas| canvas.discardTarget();
    self.dib.deinit();
}

/// Whether the popup has the keyboard focus.
pub fn hasFocus(self: *const Popup) bool {
    return self.focused;
}

/// The scale (DPI / 96) the popup lays out and draws at: its DPI, zoomed
/// by `setOwnerScale`.
pub fn scale(self: *const Popup) f32 {
    return dpiScale(self.dpi) * self.zoom;
}

/// Scale of the owner window (its DPI, or the content scale given to
/// `setOwnerScale`): size a popup with it before it is shown on the
/// owner's monitor.
pub fn ownerScale(self: *const Popup) f32 {
    const owner = self.owner orelse return 1.0;
    return dpiScale(dpiOf(owner)) * self.zoom;
}

/// Lay the popup out and draw it at the content scale of its owner
/// (`Window.scale` for parts of a window's chrome) instead of the owner's
/// DPI; the two differ after `Window.WM_GHOSTTY_SIMULATE_DPI`. On another
/// monitor the popup's own DPI still applies on top. `scale` and
/// `ownerScale` include it. All popups of a window take its scale this
/// way.
pub fn setOwnerScale(self: *Popup, owner_scale: f32) void {
    const owner = self.owner orelse return;
    const zoom = owner_scale / dpiScale(dpiOf(owner));
    if (zoom == self.zoom) return;
    self.zoom = zoom;
    self.invalidate();
}

fn dpiScale(dpi: u32) f32 {
    return @as(f32, @floatFromInt(dpi)) / 96.0;
}

/// The DPI the canvas draws at: the popup's DPI with the owner's zoom.
fn canvasDpi(self: *const Popup) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(self.dpi)) * self.zoom));
}

/// The client size in DIPs.
pub fn sizeDip(self: *const Popup) d2d.Size {
    const hwnd = self.hwnd orelse return .{ .width = 0, .height = 0 };
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return .{ .width = 0, .height = 0 };
    const s = self.scale();
    return .{
        .width = @as(f32, @floatFromInt(client.right - client.left)) / s,
        .height = @as(f32, @floatFromInt(client.bottom - client.top)) / s,
    };
}

/// Move/resize the popup to `rect` (screen pixels) and show it. A visible
/// popup only moves when `rect` changed, and repaints.
pub fn show(self: *Popup, rect: w32.RECT) void {
    const hwnd = self.hwnd orelse return;
    if (self.visible and w32.IsWindowVisible_(hwnd) != 0) {
        self.open_timing = null;
        if (self.animator.running) self.fade_target = rect else self.place(hwnd, rect);
        if (self.options.activate) _ = w32.SetFocus(hwnd);
        if (self.options.capture_mouse) _ = w32.SetCapture(hwnd);
        self.invalidate();
        return;
    }

    if (self.options.activate and self.options.keep_owner_active) self.lockOwner();
    const motion = if (self.layered) self.options.motion else null;
    const animate = motion != null and anim.enabled();
    self.composition_frame = null;
    // Cloaked until it painted and DWM had a frame for it.
    setCloaked(hwnd, true);
    self.revealing = true;
    if (self.layered) _ = w32.SetLayeredWindowAttributes(hwnd, 0, if (animate) 0 else 255, w32.LWA_ALPHA);

    var start = rect;
    if (animate) {
        const s = self.ownerScale();
        const dx = style.px(motion.?.offset_x, s);
        const dy = style.px(motion.?.offset_y, s);
        start = .{ .left = rect.left + dx, .top = rect.top + dy, .right = rect.right + dx, .bottom = rect.bottom + dy };
    }
    self.fade_target = rect;
    self.fade_pending = animate;

    // On top of the owner's other popups, also when it does not activate.
    var flags: u32 = 0;
    if (!self.options.activate) flags |= w32.SWP_NOACTIVATE;
    _ = w32.SetWindowPos(hwnd, null, start.left, start.top, start.right - start.left, start.bottom - start.top, flags);
    self.dpi = dpiOf(hwnd);
    if (self.options.activate) {
        _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
        _ = w32.SetFocus(hwnd);
    } else {
        _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    }
    if (self.options.capture_mouse) _ = w32.SetCapture(hwnd);
    self.visible = true;
    _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | RDW_UPDATENOW);
    if (w32.SetTimer(hwnd, REVEAL_TIMER_ID, reveal_ms, null) == 0) self.reveal(hwnd);
}

/// Move/resize without changing visibility (screen pixels); nothing
/// happens when neither the place nor the scale changed, and a pure move
/// does not repaint.
pub fn setBounds(self: *Popup, rect: w32.RECT) void {
    const hwnd = self.hwnd orelse return;
    if (self.animator.running) {
        self.fade_target = rect;
        return;
    }
    self.place(hwnd, rect);
}

fn place(self: *Popup, hwnd: w32.HWND, rect: w32.RECT) void {
    var current: w32.RECT = undefined;
    const known = w32.GetWindowRect(hwnd, &current) != 0;
    const rescaled = self.paint_scale != self.scale();
    if (known and std.meta.eql(current, rect)) {
        if (rescaled) self.invalidate();
        return;
    }
    const resized = !known or
        current.right - current.left != rect.right - rect.left or
        current.bottom - current.top != rect.bottom - rect.top;
    self.uiaDirty();
    var flags: u32 = w32.SWP_NOZORDER | w32.SWP_NOACTIVATE;
    if (!resized) flags |= w32.SWP_NOSIZE;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, flags);
    if ((resized or rescaled) and self.visible) {
        // Repaint at once so the new size never shows stale content.
        _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | RDW_UPDATENOW);
    }
}

/// Hide without reporting a dismissal.
pub fn hide(self: *Popup) void {
    self.open_timing = null;
    self.uiaDetach();
    const was_visible = self.visible;
    self.visible = false;
    const hwnd = self.hwnd orelse return;
    self.stopRepeat();
    self.input.dragging = false;
    // The window can be visible behind a stale flag (shown by something
    // else than `show`), so check it too.
    if (was_visible or w32.IsWindowVisible_(hwnd) != 0) {
        if (self.options.capture_mouse and w32.GetCapture() == hwnd) _ = w32.ReleaseCapture();
        _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
    }
    // Uncloak only once hidden, so a reveal in progress never flashes.
    self.endMotion(hwnd);
    // After hiding: the owner has the activation back by now.
    self.unlockOwner();
    if (self.options.release_target_on_hide) self.discardTarget();
}

/// Hide and report `reason` through `Callbacks.dismissed`.
pub fn dismiss(self: *Popup, reason: DismissReason) void {
    if (!self.visible) return;
    self.hide();
    if (self.callbacks) |cb| if (cb.dismissed) |f| f(cb.ctx, self, reason);
}

/// Repaint the popup.
pub fn invalidate(self: *Popup) void {
    self.uiaDirty();
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

fn uiaDirty(self: *Popup) void {
    self.uia_view.dirty();
    self.uia_layout_pending = true;
}

fn uiaDetach(self: *Popup) void {
    if (self.callbacks) |cb| if (cb.uia_source) |source| {
        source.app.uia_popups.unregister(&self.uia_view);
    };
    self.uia_view.hide();
    self.uia_layout_pending = true;
}

fn uiaRefresh(self: *Popup) void {
    if (self.uia_refreshing or !self.visible) return;
    if (!self.uia_view.needs_publish and self.uia_view.publisher.current != null) return;
    const cb = self.callbacks orelse return;
    const source = cb.uia_source orelse return;
    if (source.app.drop_closing) return self.uiaDetach();
    const api = source.app.uia_api orelse return;
    const queue = source.app.uia_queue orelse return;
    if (!source.is_live(cb.ctx)) return self.uia_view.hide();
    source.app.uia_popups.register(&self.uia_view) catch return self.uia_view.hide();
    self.uia_refreshing = true;
    defer self.uia_refreshing = false;
    source.build(cb.ctx, self, &self.uia_view, api, queue) catch self.uia_view.hide();
}

fn livePopup(hwnd: w32.HWND, cookie: u64) ?*Popup {
    const address = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (address == 0) return null;
    const current: *Popup = @ptrFromInt(@as(usize, @bitCast(address)));
    if (current.uia_cookie != cookie or current.hwnd != hwnd) return null;
    return current;
}
pub fn uiaAlive(hwnd: w32.HWND, cookie: u64) bool {
    return livePopup(hwnd, cookie) != null;
}

fn uiaGetObject(self: *Popup, hwnd: w32.HWND, wparam: usize, lparam: isize) isize {
    const cb = self.callbacks orelse return 0;
    const source = cb.uia_source orelse return 0;
    const cookie = self.uia_cookie;
    if (!source.app.ensureUia()) return 0;
    const current = livePopup(hwnd, cookie) orelse return 0;
    if (current.uia_layout_pending) current.paint(hwnd);
    const ready = livePopup(hwnd, cookie) orelse return 0;
    ready.uiaRefresh();
    return ready.uia_view.publisher.returnProvider(wparam, lparam);
}

/// What the modal loop of a dialog or menu does with a WM_QUIT (exit code
/// `wparam`) it retrieves: a quit the app asked for (`App.quit_requested`)
/// ends the loop, which posts the code again for `App.run`; one that
/// `App.stopQuitTimer` withdrew is dropped (null), as `App.run` drops it.
pub fn modalQuitCode(quit_requested: bool, wparam: usize) ?i32 {
    if (!quit_requested) return null;
    return @bitCast(@as(u32, @truncate(wparam)));
}

fn dpiOf(hwnd: w32.HWND) u32 {
    const dpi = w32.GetDpiForWindow(hwnd);
    return if (dpi == 0) 96 else dpi;
}

/// Hide (`cloaked`) or show a window in DWM composition only; it keeps
/// painting while cloaked.
fn setCloaked(hwnd: w32.HWND, cloaked: bool) void {
    const value: u32 = @intFromBool(cloaked);
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, @ptrCast(&value), @sizeOf(u32));
}

/// A frame passed since the first paint: paint again (DWM can drop the
/// first frame of a new window), uncloak and start the fade-in.
fn reveal(self: *Popup, hwnd: w32.HWND) void {
    _ = w32.KillTimer(hwnd, REVEAL_TIMER_ID);
    if (!self.revealing) return;
    const cookie = self.uia_cookie;
    _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | RDW_UPDATENOW);
    const current = livePopup(hwnd, cookie) orelse return;
    // The opt-in path (including its legacy fallback) must have a successful
    // current-size/current-DPI frame. Do not reveal a failed or stale surface.
    if (current.composition_requested and !current.compositionReady(hwnd)) {
        log.warn("popup has no successful frame after composition fallback", .{});
        current.hide();
        return;
    }
    current.revealing = false;
    setCloaked(hwnd, false);
    if (!self.fade_pending) {
        self.finishOpenTiming();
        return;
    }
    self.fade_pending = false;
    self.fade = anim.Tween.begin(anim.now(), anim.motion.duration.fast, anim.motion.enter);
    if (!anim.start(&self.animator)) self.finishMotion(hwnd);
}

fn animTick(animator: *anim.Animator, now: u64) bool {
    const self: *Popup = @alignCast(@fieldParentPtr("animator", animator));
    const hwnd = self.hwnd orelse return false;
    if (self.fade.done(now)) {
        self.finishMotion(hwnd);
        return false;
    }
    const p = self.fade.progress(now);
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, @intFromFloat(@round(255 * p)), w32.LWA_ALPHA);
    var current: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &current) != 0) {
        const target = self.fade_target;
        const motion = self.options.motion orelse Motion{};
        const s = self.ownerScale();
        const rest = 1 - p;
        const x = target.left + style.px(motion.offset_x * rest, s);
        const y = target.top + style.px(motion.offset_y * rest, s);
        const w = target.right - target.left;
        const h = target.bottom - target.top;
        if (current.left != x or current.top != y or current.right - current.left != w or current.bottom - current.top != h) {
            _ = w32.SetWindowPos(hwnd, null, x, y, w, h, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        }
    }
    return true;
}

/// Jump to the end of the fade-in: opaque, in place.
fn finishMotion(self: *Popup, hwnd: w32.HWND) void {
    if (self.layered) _ = w32.SetLayeredWindowAttributes(hwnd, 0, 255, w32.LWA_ALPHA);
    const target = self.fade_target;
    if (target.right > target.left) self.place(hwnd, target);
    self.finishOpenTiming();
}

fn finishOpenTiming(self: *Popup) void {
    if (self.open_timing) |*timing| {
        if (timing.painted) timing.report();
        self.open_timing = null;
    }
}

/// Stop a reveal or fade in progress (hiding).
fn endMotion(self: *Popup, hwnd: w32.HWND) void {
    self.open_timing = null;
    if (self.revealing) {
        _ = w32.KillTimer(hwnd, REVEAL_TIMER_ID);
        setCloaked(hwnd, false);
        self.revealing = false;
    }
    self.fade_pending = false;
    if (self.animator.running) {
        anim.stop(&self.animator);
        if (self.layered) _ = w32.SetLayeredWindowAttributes(hwnd, 0, 255, w32.LWA_ALPHA);
    }
}

/// The top-level window the popup belongs to (its root owner).
fn rootOwner(self: *const Popup) ?w32.HWND {
    const hwnd = self.hwnd orelse return self.owner;
    return GetAncestor(hwnd, GA_ROOTOWNER) orelse self.owner;
}

fn lockOwner(self: *Popup) void {
    if (self.owner_locked) return;
    const root = self.rootOwner() orelse return;
    if (self.hwnd) |hwnd| if (hwnd == root) return;
    self.owner_locked = true;
    _ = w32.SendMessageW(root, WM_GX_OWNER_ACTIVE_LOCK, 1, @bitCast(@intFromPtr(self.hwnd)));
}

fn unlockOwner(self: *Popup) void {
    if (!self.owner_locked) return;
    self.owner_locked = false;
    const root = self.rootOwner() orelse return;
    if (w32.IsWindow(root) == 0) return;
    _ = w32.SendMessageW(root, WM_GX_OWNER_ACTIVE_LOCK, 0, @bitCast(@intFromPtr(self.hwnd)));
}

/// Call `Callbacks.repeat` with `tag` at the keyboard repeat rate (after
/// the keyboard delay) until `stopRepeat`: a held stepper or scroll
/// button. The owner acts once itself on the press.
pub fn startRepeat(self: *Popup, tag: u32) void {
    const hwnd = self.hwnd orelse return;
    self.repeat_tag = tag;
    self.repeat_started = false;
    var setting: u32 = 1;
    if (SystemParametersInfoW(SPI_GETKEYBOARDDELAY, 0, @ptrCast(&setting), 0) == 0) setting = 1;
    _ = w32.SetTimer(hwnd, REPEAT_TIMER_ID, repeatDelayMs(setting), null);
}

pub fn stopRepeat(self: *Popup) void {
    if (self.repeat_tag == null) return;
    self.repeat_tag = null;
    if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, REPEAT_TIMER_ID);
}

/// The delay before a held key repeats for `SPI_GETKEYBOARDDELAY` 0..3.
pub fn repeatDelayMs(setting: u32) u32 {
    const steps: u32 = @min(setting, 3);
    return (steps + 1) * 250;
}

/// The repeat interval for `SPI_GETKEYBOARDSPEED` 0..31 (about 2.5 to 30
/// repeats a second).
pub fn repeatIntervalMs(setting: u32) u32 {
    const rate = 2.5 + @as(f32, @floatFromInt(@min(setting, 31))) * (27.5 / 31.0);
    return @intFromFloat(@round(1000 / rate));
}

fn onRepeatTimer(self: *Popup, hwnd: w32.HWND) void {
    const tag = self.repeat_tag orelse {
        _ = w32.KillTimer(hwnd, REPEAT_TIMER_ID);
        return;
    };
    if (!self.repeat_started) {
        self.repeat_started = true;
        var setting: u32 = 31;
        if (SystemParametersInfoW(SPI_GETKEYBOARDSPEED, 0, @ptrCast(&setting), 0) == 0) setting = 31;
        _ = w32.SetTimer(hwnd, REPEAT_TIMER_ID, repeatIntervalMs(setting), null);
    }
    if (self.callbacks) |cb| if (cb.repeat) |f| f(cb.ctx, self, tag);
}

// -----------------------------------------------------------------------
// Text input drawing
// -----------------------------------------------------------------------

/// How `drawTextInputEx` draws the field.
pub const TextInputStyle = struct {
    placeholder: []const u8 = "",
    /// Draw it focused (caret, selection, accent underline); null for
    /// whether the popup has the keyboard focus.
    focused: ?bool = null,
    /// Mark the field as wrong (no results): critical border and
    /// underline.
    invalid: bool = false,
};

/// Draw the text input into `rect` (DIPs): field background, border, text
/// or placeholder, IME composition and caret. Also places the system
/// caret and, while composing, the IME windows.
pub fn drawTextInput(
    self: *Popup,
    canvas: *d2d.Canvas,
    rect: d2d.Rect,
    tokens: style.Tokens,
    placeholder: []const u8,
) void {
    self.drawTextInputEx(canvas, rect, tokens, .{ .placeholder = placeholder });
}

/// `drawTextInput` with more options (`TextInputStyle`).
pub fn drawTextInputEx(
    self: *Popup,
    canvas: *d2d.Canvas,
    rect: d2d.Rect,
    tokens: style.Tokens,
    opts: TextInputStyle,
) void {
    const input = &self.input;
    const focused = opts.focused orelse self.focused;
    const field = canvas.snapRect(rect);
    input.field = field;
    const radius = style.radius.control;
    canvas.fillRoundedRect(field, radius, tokens.surface);
    canvas.strokeRoundedRectPx(field, radius, if (opts.invalid) tokens.critical else tokens.border, 1);
    if (focused) {
        // Focus underline in the accent color (Fluent text box).
        const line = 2 * canvas.hairline();
        canvas.fillRect(.{ .x = field.x + radius, .y = field.y + field.h - line, .w = @max(0, field.w - 2 * radius), .h = line }, if (opts.invalid) tokens.critical else tokens.accent);
    }

    const pad = style.space.m;
    const text_rect: d2d.Rect = .{ .x = field.x + pad, .y = field.y, .w = @max(0, field.w - 2 * pad), .h = field.h };
    const text_style: d2d.TextStyle = .{ .size = style.font_size.body, .color = tokens.text, .ellipsis = false };

    if (input.buf.items.len == 0 and input.composition.items.len == 0) {
        input.dropLayout();
        input.scroll_x = 0;
        canvas.pushClip(text_rect);
        canvas.drawText(opts.placeholder, text_rect, .{ .size = style.font_size.body, .color = tokens.text_placeholder });
        canvas.popClip();
        input.caret_x = text_rect.x;
        input.layout_origin = .{ .x = text_rect.x, .y = text_rect.y };
        self.drawCaret(canvas, text_rect.x, field, focused, tokens);
        return;
    }

    const composing = input.composition.items.len > 0;
    input.relayout(canvas.factory, text_style, text_rect.h) catch return;
    const layout = input.layout orelse return;
    const caret_pos: u32 = @intCast(if (composing) input.caret + input.composition_cursor else input.caret);
    const caret_rel = layout.caretX(caret_pos);
    input.scroll_x = scrollToShow(input.scroll_x, caret_rel, layout.size().width, text_rect.w);
    const origin: d2d.Point = .{ .x = text_rect.x - input.scroll_x, .y = text_rect.y };
    input.layout_origin = origin;

    canvas.pushClip(text_rect);
    defer canvas.popClip();

    var runs: [1]d2d.LayoutRun = undefined;
    var run_count: usize = 0;
    if (focused and !composing and input.anchor != input.caret) {
        const sel = text_edit.selection(input);
        const x0 = origin.x + layout.caretX(@intCast(sel.start));
        const x1 = origin.x + layout.caretX(@intCast(sel.end));
        const inset = @max(4, field.h * 0.18);
        canvas.fillRect(canvas.snapRect(.{ .x = x0, .y = field.y + inset, .w = x1 - x0, .h = field.h - 2 * inset }), tokens.text_selection);
        runs[0] = .{ .start = @intCast(sel.start), .len = @intCast(sel.len()), .color = tokens.on_text_selection };
        run_count = 1;
    }
    canvas.drawLayout(&layout, origin, tokens.text, runs[0..run_count]);

    if (composing) {
        // Underline the composition; thicker under the clause being
        // converted.
        const start = input.caret;
        const comp = input.composition.items;
        const y = field.y + field.h - 9;
        var i: usize = 0;
        while (i < comp.len) {
            const target = input.isTargetClause(i);
            var j = i + 1;
            while (j < comp.len and input.isTargetClause(j) == target) j += 1;
            const x0 = origin.x + layout.caretX(@intCast(start + i));
            const x1 = origin.x + layout.caretX(@intCast(start + j));
            const h = (if (target) @as(f32, 2) else 1) * canvas.hairline();
            canvas.fillRect(.{ .x = x0, .y = y, .w = @max(0, x1 - x0 - canvas.hairline()), .h = h }, if (target) tokens.text else tokens.text_secondary);
            i = j;
        }
    }

    input.caret_x = origin.x + caret_rel;
    self.drawCaret(canvas, input.caret_x, field, focused, tokens);
}

/// The caret (while focused and in its blink phase), the system caret and
/// the IME windows.
fn drawCaret(self: *Popup, canvas: *d2d.Canvas, x: f32, field: d2d.Rect, focused: bool, tokens: style.Tokens) void {
    const input = &self.input;
    input.caret_x = x;
    if (!focused) return;
    const composing = input.composition.items.len > 0;
    const width = @as(f32, @floatFromInt(caretWidthPx())) * canvas.hairline();
    const top = field.y + 7;
    const caret_x = canvas.snap(x);
    if (input.caret_on or composing) {
        canvas.fillRect(.{ .x = caret_x, .y = top, .w = width, .h = @max(0, field.h - 14) }, tokens.text);
    }
    if (self.system_caret) {
        const s = self.scale();
        _ = SetCaretPos(style.px(caret_x, s), style.px(top, s));
    }
    if (composing) self.positionIme();
}

/// The horizontal scroll that keeps a caret at `caret` (DIPs from the text
/// start) inside a field `view` wide, moving as little as possible, for
/// text `text_w` wide.
pub fn scrollToShow(scroll: f32, caret: f32, text_w: f32, view: f32) f32 {
    const margin: f32 = 2;
    var s = scroll;
    if (caret - s > view - margin) s = caret - view + margin;
    if (caret - s < 0) s = caret;
    // Do not scroll past the end once the text got shorter.
    s = @min(s, @max(0, @max(text_w, caret) - view + margin));
    return @max(0, s);
}

fn caretWidthPx() u32 {
    var width: u32 = 1;
    if (SystemParametersInfoW(SPI_GETCARETWIDTH, 0, @ptrCast(&width), 0) == 0) return 1;
    return std.math.clamp(width, 1, 20);
}

/// Put the IME composition window at the caret and the candidate window
/// below the field, never over it.
fn positionIme(self: *Popup) void {
    const hwnd = self.hwnd orelse return;
    if (!self.focused) return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    const s = self.scale();
    const field = self.input.field;
    const caret: w32.POINT = .{ .x = style.px(self.input.caret_x, s), .y = style.px(field.y + field.h - 4, s) };
    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = caret,
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
    const exclude: w32.RECT = .{
        .left = style.px(field.x, s),
        .top = style.px(field.y, s),
        .right = style.px(field.x + field.w, s),
        .bottom = style.px(field.y + field.h, s),
    };
    const candidate = w32.CANDIDATEFORM{
        .dwIndex = 0,
        .dwStyle = w32.CFS_EXCLUDE,
        .ptCurrentPos = .{ .x = caret.x, .y = exclude.bottom },
        .rcArea = exclude,
    };
    _ = w32.ImmSetCandidateWindow(himc, &candidate);
}

/// A single-line, IME-capable text field model (UTF-16, with a caret and
/// selection anchor in code units), edited by `text_edit`.
pub const TextInput = struct {
    buf: std.ArrayList(u16) = .empty,
    caret: usize = 0,
    anchor: usize = 0,
    /// The undo steps (`text_edit`).
    history: text_edit.History = .{},
    /// The in-progress IME composition (shown at the caret), the caret in
    /// it and the clause attributes (one per code unit, ATTR_*).
    composition: std.ArrayList(u16) = .empty,
    composition_cursor: usize = 0,
    composition_attrs: std.ArrayList(u8) = .empty,
    /// Where `drawTextInput` last drew the field, and the caret, in DIPs.
    field: d2d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    caret_x: f32 = 0,
    /// The horizontal scroll of the text in the field (DIPs).
    scroll_x: f32 = 0,
    /// The text as laid out by the last paint (composition included), the
    /// origin it was drawn at, and the cluster stops of `buf` with the
    /// hash of the text they belong to.
    layout: ?d2d.TextLayout = null,
    layout_key: u64 = 0,
    layout_origin: d2d.Point = .{ .x = 0, .y = 0 },
    display: std.ArrayList(u16) = .empty,
    stops: std.ArrayList(u32) = .empty,
    stops_hash: u64 = 0,
    /// The caret blink phase.
    caret_on: bool = true,
    /// A high surrogate from WM_CHAR waiting for its low half.
    pending_high: ?u16 = null,
    /// A pointer drag is selecting.
    dragging: bool = false,
    /// The allocator of the buffers (set by `Popup.create`).
    alloc: ?Allocator = null,

    pub fn deinit(self: *TextInput, alloc: Allocator) void {
        self.dropLayout();
        self.buf.deinit(alloc);
        self.history.deinit(alloc);
        self.composition.deinit(alloc);
        self.composition_attrs.deinit(alloc);
        self.display.deinit(alloc);
        self.stops.deinit(alloc);
        self.* = .{};
    }

    /// The text as UTF-8, allocated (unpaired surrogates become U+FFFD).
    pub fn text(self: *const TextInput, alloc: Allocator) ![]u8 {
        return wstr.utf8Alloc(alloc, self.buf.items);
    }

    /// The UTF-8 of code units [from, to) in `buf` (cut off when it does
    /// not fit).
    pub fn utf8Range(self: *const TextInput, buf: []u8, from: usize, to: usize) []const u8 {
        return wstr.utf8Buf(buf, self.buf.items[from..to]);
    }

    /// Replace the text (a new session: no undo across it).
    pub fn setText(self: *TextInput, alloc: Allocator, utf8: []const u8) !void {
        const units = try wstr.allocZ(alloc, utf8);
        defer alloc.free(units);
        try text_edit.reset(alloc, self, units);
        self.stops_hash = 0;
    }

    pub fn clear(self: *TextInput) void {
        self.buf.clearRetainingCapacity();
        self.composition.clearRetainingCapacity();
        self.composition_attrs.clearRetainingCapacity();
        self.composition_cursor = 0;
        self.caret = 0;
        self.anchor = 0;
        self.scroll_x = 0;
        self.stops_hash = 0;
        self.pending_high = null;
        if (self.alloc) |alloc| self.history.clear(alloc);
    }

    /// The selection (empty at the caret).
    pub fn selection(self: *const TextInput) text_edit.Range {
        return text_edit.selection(self);
    }

    fn dropLayout(self: *TextInput) void {
        if (self.layout) |*l| l.deinit();
        self.layout = null;
    }

    fn hashOf(units: []const u16) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(units));
    }

    /// Lay out the text with the composition at the caret (unless the
    /// last layout is of the same text); record the cluster stops of `buf`
    /// when not composing.
    fn relayout(self: *TextInput, factory: *d2d.Factory, text_style: d2d.TextStyle, height: f32) !void {
        const alloc = self.alloc orelse return error.NoAllocator;
        const caret = @min(self.caret, self.buf.items.len);
        const split: usize = if (self.composition.items.len > 0) caret else 0;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(self.buf.items));
        hasher.update(std.mem.sliceAsBytes(self.composition.items));
        hasher.update(std.mem.asBytes(&split));
        hasher.update(std.mem.asBytes(&height));
        hasher.update(std.mem.asBytes(&text_style.size));
        const key = hasher.final();
        if (self.layout != null and key == self.layout_key) return;

        self.dropLayout();
        self.display.clearRetainingCapacity();
        try self.display.appendSlice(alloc, self.buf.items[0..caret]);
        try self.display.appendSlice(alloc, self.composition.items);
        try self.display.appendSlice(alloc, self.buf.items[caret..]);
        self.layout = d2d.TextLayout.initUtf16(factory, self.display.items, text_style, 100_000, height) orelse return;
        self.layout_key = key;
        if (self.composition.items.len == 0) {
            try self.layout.?.clusterStops(alloc, &self.stops);
            self.stops_hash = hashOf(self.buf.items);
        }
    }

    /// The cluster stops of the current text, when the last layout was of
    /// this text.
    fn currentStops(self: *const TextInput) ?[]const u32 {
        if (self.stops.items.len == 0 or self.stops_hash != hashOf(self.buf.items)) return null;
        return self.stops.items;
    }

    /// The caret position in `buf` under a point (DIPs), from the last
    /// layout; null while composing or before the first paint.
    fn positionAt(self: *const TextInput, pos: d2d.Point) ?usize {
        if (self.composition.items.len > 0) return null;
        const layout = self.layout orelse return if (self.buf.items.len == 0) 0 else null;
        const hit = layout.hitTest(pos.x - self.layout_origin.x, pos.y - self.layout_origin.y);
        return @min(hit.position, self.buf.items.len);
    }

    fn isTargetClause(self: *const TextInput, i: usize) bool {
        if (i >= self.composition_attrs.items.len) return false;
        const attr = self.composition_attrs.items[i];
        return attr == ATTR_TARGET_CONVERTED or attr == ATTR_TARGET_NOTCONVERTED;
    }

    pub const KeyResult = enum { ignored, moved, changed };
};

fn copyToClipboard(hwnd: w32.HWND, units: []const u16) void {
    const bytes = (units.len + 1) * @sizeOf(u16);
    const handle = w32.GlobalAlloc(w32.GMEM_MOVEABLE, bytes) orelse return;
    const ptr = w32.GlobalLock(handle) orelse {
        _ = w32.GlobalFree(handle);
        return;
    };
    const dst: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dst[0..units.len], units);
    dst[units.len] = 0;
    _ = w32.GlobalUnlock(handle);
    clipboard.setUnicodeText(hwnd, handle) catch |err| {
        log.warn("copy from popup input failed err={}", .{err});
        _ = w32.GlobalFree(handle);
    };
}

/// Insert the clipboard text into the input: its first line, as much as
/// fits in `text_edit.max_len` code units (`text_edit.paste`).
fn pasteFromClipboard(self: *Popup, hwnd: w32.HWND) !void {
    if (!clipboard.open(hwnd)) return error.ClipboardBusy;
    defer _ = w32.CloseClipboard();
    const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return;
    const ptr = w32.GlobalLock(handle) orelse return;
    defer _ = w32.GlobalUnlock(handle);
    // Bounded by the block size, in case the text lacks its terminator,
    // and by what a paste can use: the first line, one unit past
    // `text_edit.max_len` to see where the character at the limit ends.
    const max_units = @min(GlobalSize(handle) / @sizeOf(u16), text_edit.max_len + 1);
    const units: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (len < max_units and units[len] != 0 and units[len] != '\r' and units[len] != '\n') len += 1;
    try text_edit.paste(self.alloc, &self.input, units[0..len]);
}

fn keyFromWparam(wparam: usize) Key {
    return .{
        .vk = @intCast(wparam & 0xFFFF),
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
    };
}

fn pointFromLparam(self: *const Popup, lparam: isize) d2d.Point {
    const x: i16 = @truncate(lparam & 0xFFFF);
    const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
    const s = self.scale();
    return .{ .x = @as(f32, @floatFromInt(x)) / s, .y = @as(f32, @floatFromInt(y)) / s };
}

fn insideClient(self: *const Popup, lparam: isize) bool {
    const hwnd = self.hwnd orelse return false;
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return false;
    return x >= client.left and y >= client.top and x < client.right and y < client.bottom;
}

fn emitMouse(self: *Popup, event: MouseEvent) void {
    if (self.callbacks) |cb| if (cb.mouse) |f| f(cb.ctx, self, event);
}

fn textChanged(self: *Popup) void {
    self.restartBlink();
    self.invalidate();
    if (self.callbacks) |cb| if (cb.text_changed) |f| f(cb.ctx, self);
}

fn compositionChanged(self: *Popup) void {
    self.invalidate();
    if (self.callbacks) |cb| if (cb.composition_changed) |f| f(cb.ctx, self);
}

/// Show the caret at once and blink again from the start.
fn restartBlink(self: *Popup) void {
    self.input.caret_on = true;
    const hwnd = self.hwnd orelse return;
    if (!self.focused or !self.options.text_input) return;
    self.blink_started = GetTickCount64();
    const ms = GetCaretBlinkTime();
    if (ms == 0 or ms == w32.INFINITE) {
        _ = w32.KillTimer(hwnd, CARET_TIMER_ID);
        return;
    }
    _ = w32.SetTimer(hwnd, CARET_TIMER_ID, ms, null);
}

fn onBlink(self: *Popup, hwnd: w32.HWND) void {
    var timeout: u32 = 5000;
    if (SystemParametersInfoW(SPI_GETCARETTIMEOUT, 0, @ptrCast(&timeout), 0) == 0) timeout = 5000;
    self.input.caret_on = !self.input.caret_on;
    // No input on screen: nothing blinks.
    const drawn = self.input.field.w > 0;
    if (!self.focused or !drawn) {
        self.input.caret_on = true;
        _ = w32.KillTimer(hwnd, CARET_TIMER_ID);
        return;
    }
    // Stop blinking after a while without input, like Windows text boxes,
    // so an idle field costs nothing.
    if (GetTickCount64() -| self.blink_started >= timeout) {
        self.input.caret_on = true;
        _ = w32.KillTimer(hwnd, CARET_TIMER_ID);
    }
    self.invalidate();
}

fn onFocus(self: *Popup, hwnd: w32.HWND, focused: bool) void {
    self.focused = focused;
    if (self.options.text_input) {
        if (focused) {
            // An invisible system caret for magnifiers and the text cursor
            // indicator to follow (`drawCaret` moves it).
            const s = self.scale();
            if (CreateCaret(hwnd, null, @intCast(caretWidthPx()), style.px(18, s)) != 0) self.system_caret = true;
            self.restartBlink();
        } else {
            if (self.system_caret) _ = DestroyCaret();
            self.system_caret = false;
            _ = w32.KillTimer(hwnd, CARET_TIMER_ID);
            self.input.dragging = false;
        }
    }
    self.invalidate();
}

fn handleKey(self: *Popup, hwnd: w32.HWND, key: Key) bool {
    const input = &self.input;
    const result = text_edit.handleKey(self.alloc, input, .{
        .vk = key.vk,
        .ctrl = key.ctrl,
        .shift = key.shift,
        .alt = key.alt,
    }, input.currentStops()) catch return true;
    if (!result.handled) return false;
    var changed = result.changed;
    switch (result.clipboard) {
        .none => {},
        .copy => {
            const sel = input.selection();
            copyToClipboard(hwnd, input.buf.items[sel.start..sel.end]);
        },
        .cut => {
            const sel = input.selection();
            copyToClipboard(hwnd, input.buf.items[sel.start..sel.end]);
            changed = text_edit.deleteSelection(self.alloc, input) catch false;
        },
        .paste => {
            const before = input.buf.items.len;
            const caret = input.caret;
            self.pasteFromClipboard(hwnd) catch |err| {
                log.warn("paste into popup input failed err={}", .{err});
            };
            changed = input.buf.items.len != before or input.caret != caret;
        },
    }
    if (changed) {
        self.textChanged();
    } else {
        self.restartBlink();
        self.invalidate();
    }
    return true;
}

fn handleChar(self: *Popup, unit: u16) void {
    const input = &self.input;
    var units: [2]u16 = undefined;
    var len: usize = 1;
    if (std.unicode.utf16IsHighSurrogate(unit)) {
        input.pending_high = unit;
        return;
    }
    if (std.unicode.utf16IsLowSurrogate(unit)) {
        const high = input.pending_high orelse return;
        units = .{ high, unit };
        len = 2;
    } else {
        units[0] = unit;
    }
    input.pending_high = null;
    text_edit.typeText(self.alloc, input, units[0..len]) catch return;
    self.textChanged();
}

/// A press of the left button on the text input: place the caret, select
/// a word (double click) or everything (triple click) and start a drag.
fn pressInput(self: *Popup, hwnd: w32.HWND, pos: d2d.Point, double: bool) bool {
    if (!self.options.text_input or !self.input.field.contains(pos)) return false;
    const at = self.input.positionAt(pos) orelse return false;
    const now = GetTickCount64();
    var clicks: u8 = if (double) 2 else 1;
    if (!double and self.last_click_count == 2 and now -| self.last_click_time <= GetDoubleClickTime()) clicks = 3;
    self.last_click_count = clicks;
    self.last_click_time = now;
    text_edit.pointerDown(&self.input, at, clicks, w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0);
    self.input.dragging = clicks == 1;
    if (self.input.dragging and !self.options.capture_mouse) _ = w32.SetCapture(hwnd);
    self.restartBlink();
    self.invalidate();
    return true;
}

fn dragInput(self: *Popup, pos: d2d.Point) void {
    if (!self.input.dragging) return;
    const at = self.input.positionAt(pos) orelse return;
    if (at == self.input.caret) return;
    text_edit.pointerDrag(&self.input, at);
    self.restartBlink();
    self.invalidate();
}

fn releaseInput(self: *Popup, hwnd: w32.HWND) void {
    if (!self.input.dragging) return;
    self.input.dragging = false;
    if (!self.options.capture_mouse and w32.GetCapture() == hwnd) _ = w32.ReleaseCapture();
}

fn cursorAt(self: *Popup, pos: d2d.Point) Cursor {
    if (self.callbacks) |cb| if (cb.cursor) |f| {
        if (f(cb.ctx, self, pos)) |cursor| return cursor;
    };
    if (self.options.text_input and self.input.field.contains(pos)) return .ibeam;
    return .arrow;
}

fn setCursorShape(cursor: Cursor) void {
    const id = switch (cursor) {
        .arrow => w32.IDC_ARROW,
        .ibeam => w32.IDC_IBEAM,
        .hand => w32.IDC_HAND,
    };
    _ = w32.SetCursor(w32.LoadCursorW(null, id));
}

/// WM_CLOSE (Alt+F4, the system close, a close sent from outside): hide
/// instead of being destroyed, report `.owner`, and close the window the
/// popup belongs to when asked to (`Options.close_owner_on_close`). A
/// popup that is not shown ignores it: a close sent to every window of
/// the app (`taskkill` without /F) reaches that window itself, and passing
/// it on as well would ask to close it twice.
fn handleClose(self: *Popup, hwnd: w32.HWND) void {
    if (!self.visible and w32.IsWindowVisible_(hwnd) == 0) return;
    const root = self.rootOwner();
    if (self.visible) self.dismiss(.owner) else self.hide();
    if (!self.options.close_owner_on_close or !self.options.activate) return;
    const target = root orelse return;
    if (hwnd == target) return;
    _ = w32.PostMessageW(target, w32.WM_CLOSE, 0, 0);
}

/// Windows destroyed the window (with its owner): forget it.
fn onNcDestroy(self: *Popup, hwnd: w32.HWND) void {
    self.open_timing = null;
    self.uiaDetach();
    self.releaseComposition();
    self.unlockOwner();
    anim.stop(&self.animator);
    if (self.system_caret) _ = DestroyCaret();
    self.system_caret = false;
    if (self.canvas) |*canvas| canvas.discardTarget();
    self.dib.deinit();
    self.hwnd = null;
    self.visible = false;
    self.focused = false;
    self.revealing = false;
    self.repeat_tag = null;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
}

fn paint(self: *Popup, hwnd: w32.HWND) void {
    const cookie = self.uia_cookie;
    const raster = if (self.open_timing != null) perf.Span.begin(global.io()) else null;
    defer if (raster) |span| {
        if (livePopup(hwnd, cookie)) |current| {
            if (current.open_timing) |*timing| timing.add(.raster, perf.sinceUs(global.io(), span.start));
        }
    };
    defer if (livePopup(hwnd, cookie)) |current| {
        current.uia_layout_pending = false;
        current.uiaRefresh();
    };
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps);
    defer _ = w32.EndPaint(hwnd, &ps);
    const cb = self.callbacks orelse return;
    // The canvas keeps its render target between paints: borrow it, don't
    // copy it.
    const canvas = if (self.canvas) |*canvas| canvas else return;
    self.paint_scale = self.scale();
    // Only a text input drawn by this paint takes clicks and the I-beam.
    self.input.field = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (self.paintComposition(hwnd, canvas, cb)) return;
    if (self.layered) {
        // A layered window shows GDI content reliably: draw into a DIB.
        const dc = hdc orelse return;
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        const mem = self.dib.ensure(dc, client.right, client.bottom) orelse return;
        if (!canvas.beginDc(mem, .{ .left = 0, .top = 0, .right = client.right, .bottom = client.bottom }, self.canvasDpi())) return;
        canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        cb.paint(cb.ctx, self, canvas);
        switch (canvas.finish()) {
            .ok => if (w32.BitBlt(dc, 0, 0, client.right, client.bottom, mem, 0, 0, w32.SRCCOPY) != 0) self.markLegacyFrame(hwnd),
            .recreate => self.invalidate(),
            .failed => {},
        }
        return;
    }
    if (!canvas.beginHwnd(hwnd, self.canvasDpi())) return;
    canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    cb.paint(cb.ctx, self, canvas);
    switch (canvas.finish()) {
        .ok => self.markLegacyFrame(hwnd),
        .recreate => self.invalidate(),
        .failed => {},
    }
}

fn releaseComposition(self: *Popup) void {
    if (self.composition) |*backend| backend.deinit();
    self.composition = null;
    self.composition_frame = null;
}

fn compositionReady(self: *Popup, hwnd: w32.HWND) bool {
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0 or client.right <= 0 or client.bottom <= 0) return false;
    const width: u32 = @intCast(client.right);
    const height: u32 = @intCast(client.bottom);
    if (!self.composition_failed) if (self.composition) |*backend| return backend.ready(width, height, self.canvasDpi());
    const frame = self.composition_frame orelse return false;
    return frame.width == width and frame.height == height and frame.dpi == self.canvasDpi();
}

fn markLegacyFrame(self: *Popup, hwnd: w32.HWND) void {
    if (self.open_timing) |*timing| timing.painted = true;
    if (!self.composition_requested) return;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0 or client.right <= 0 or client.bottom <= 0) return;
    // Present the legacy pixels before detaching the old composition root.
    // A failed legacy draw therefore keeps the last native frame, rather than
    // committing an empty root while no replacement pixels exist yet.
    if (self.composition_failed) self.releaseComposition();
    self.composition_frame = .{ .width = @intCast(client.right), .height = @intCast(client.bottom), .dpi = self.canvasDpi(), .generation = 0 };
}

/// Failure disables composition for this popup lifetime. The caller immediately
/// paints the same content through its original HWND/DC path; no blank reveal
/// and no repeated device creation loop on a failing driver.
fn paintComposition(self: *Popup, hwnd: w32.HWND, canvas: *d2d.Canvas, cb: Callbacks) bool {
    if (!self.composition_requested) return false;
    self.composition_frame = null;
    if (self.composition_failed) return false;
    if (!self.composition_attempted) {
        self.composition_attempted = true;
        if (canvas.factory.popupDevice()) |device| {
            self.composition = dcomp.Backend.init(device, hwnd) catch |err| result: {
                log.warn("popup composition target unavailable; using legacy err={}", .{err});
                break :result null;
            };
            if (self.composition) |*backend| {
                backend.key.generation = self.composition_generation;
                backend.failure = self.composition_failure;
            }
        }
    }
    const backend = if (self.composition) |*value| value else return false;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0 or client.right <= 0 or client.bottom <= 0) return false;
    const frame = backend.begin(@intCast(client.right), @intCast(client.bottom), self.canvasDpi()) catch |err| {
        log.warn("popup composition BeginDraw failed; using legacy err={}", .{err});
        self.failComposition();
        return false;
    };
    self.composition_generation = frame.key.generation;
    if (!canvas.beginBorrowed(frame.context, .{ .width = frame.key.width, .height = frame.key.height }, frame.key.dpi, frame.offset)) {
        dcomp.releaseContext(frame.context);
        self.failComposition();
        return false;
    }
    canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    cb.paint(cb.ctx, self, canvas);
    canvas.finishBorrowed();
    dcomp.releaseContext(frame.context);
    backend.finish(frame.key) catch |err| {
        log.warn("popup composition EndDraw/Commit failed; using legacy err={}", .{err});
        self.failComposition();
        return false;
    };
    self.composition_frame = frame.key;
    if (self.open_timing) |*timing| timing.painted = true;
    return true;
}

fn failComposition(self: *Popup) void {
    self.composition_failed = true;
    if (self.composition) |*backend| backend.reset();
}

/// Popup-only native test hook. wparam=0 queries bits: opted-in=1, native=2,
/// current frame=4, WARP=8, legacy fallback=16. wparam=1 resets the popup
/// resource domain and injects Failure(lparam) at its next native draw phase.
/// It never touches a terminal context, and does nothing without explicit opt-in.
pub const WM_GHOSTTY_POPUP_DCOMP: u32 = w32.WM_USER + 0x4E;

fn compositionStatus(self: *Popup, hwnd: w32.HWND) isize {
    var result: isize = if (self.composition_requested) 1 else 0;
    if (!self.composition_failed and self.composition != null) {
        const backend = &self.composition.?;
        result |= 2;
        if (backend.device.warp) result |= 8;
    } else if (self.composition_requested and self.composition_attempted) result |= 16;
    if (self.compositionReady(hwnd)) result |= 4;
    return result;
}

/// An IME string or attribute array read by `imeData`.
const ImeData = struct {
    storage: []u16,
    /// Bytes returned.
    len: usize,

    fn units(self: ImeData) []const u16 {
        return self.storage[0 .. self.len / 2];
    }

    fn bytes(self: ImeData) []const u8 {
        return std.mem.sliceAsBytes(self.storage)[0..self.len];
    }
};

/// Read an IME string (`GCS_RESULTSTR`, `GCS_COMPSTR`) or attributes
/// (`GCS_COMPATTR`), however long, asking for its size first. The caller
/// frees `storage`.
fn imeData(self: *Popup, himc: w32.HIMC, index: u32) ?ImeData {
    const len = w32.ImmGetCompositionStringW(himc, index, null, 0);
    if (len <= 0) return null;
    const size: usize = @intCast(len);
    const storage = self.alloc.alloc(u16, (size + 1) / 2) catch return null;
    const got = w32.ImmGetCompositionStringW(himc, index, storage.ptr, @intCast(size));
    if (got <= 0) {
        self.alloc.free(storage);
        return null;
    }
    return .{ .storage = storage, .len = @min(@as(usize, @intCast(got)), size) };
}

fn handleImeComposition(self: *Popup, hwnd: w32.HWND, lparam: isize) void {
    const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    const input = &self.input;

    if (flags & w32.GCS_RESULTSTR != 0) {
        if (self.imeData(himc, w32.GCS_RESULTSTR)) |data| {
            defer self.alloc.free(data.storage);
            input.composition.clearRetainingCapacity();
            input.composition_attrs.clearRetainingCapacity();
            input.composition_cursor = 0;
            text_edit.insertText(self.alloc, input, data.units()) catch {};
            self.compositionChanged();
            self.textChanged();
        }
    }
    if (flags & w32.GCS_COMPSTR != 0) {
        input.composition.clearRetainingCapacity();
        input.composition_attrs.clearRetainingCapacity();
        input.composition_cursor = 0;
        if (self.imeData(himc, w32.GCS_COMPSTR)) |data| {
            defer self.alloc.free(data.storage);
            input.composition.appendSlice(self.alloc, data.units()) catch return;
        }
        if (flags & GCS_COMPATTR != 0) {
            if (self.imeData(himc, GCS_COMPATTR)) |data| {
                defer self.alloc.free(data.storage);
                input.composition_attrs.appendSlice(self.alloc, data.bytes()) catch {};
            }
        }
        const cursor = w32.ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
        input.composition_cursor = if (cursor >= 0) @min(@as(usize, @intCast(cursor)), input.composition.items.len) else input.composition.items.len;
        self.compositionChanged();
    } else if (flags == 0) {
        // The composition was canceled.
        input.composition.clearRetainingCapacity();
        input.composition_attrs.clearRetainingCapacity();
        input.composition_cursor = 0;
        self.compositionChanged();
    }
}

var classes_registered = false;

fn registerClasses(hinstance: w32.HINSTANCE) !void {
    if (classes_registered) return;
    for ([_]struct { [*:0]const u16, u32 }{
        .{ CLASS_NAME, 0 },
        .{ CLASS_NAME_SHADOW, CS_DROPSHADOW },
    }) |class| {
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = w32.CS_DBLCLKS | class[1],
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class[0],
            .hIconSm = null,
        };
        if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    }
    classes_registered = true;
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Popup = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        0x000A => { // WM_ENABLE: modal dialogs changed the actual input gate.
            self.invalidate();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETOBJECT => {
            if (w32.objectId(lparam) == w32.OBJID_CLIENT) return 0;
            if (w32.objectId(lparam) == uia.root_object_id) return self.uiaGetObject(hwnd, wparam, lparam);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_NCHITTEST => {
            if (self.options.click_through) return HTTRANSPARENT;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_NCDESTROY => {
            self.onNcDestroy(hwnd);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEACTIVATE => {
            if (!self.options.activate) return w32.MA_NOACTIVATE;
            // Lock before the owner hears it loses activation.
            if (self.options.keep_owner_active) self.lockOwner();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SHOWWINDOW => {
            // Restoring the owner shows the popups that minimizing it hid,
            // including one hidden in the meantime (a find bar whose
            // search ended): keep that one hidden.
            if (wparam != 0 and lparam == SW_PARENTOPENING and !self.visible) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        WM_GHOSTTY_POPUP_DCOMP => {
            if (wparam == 0) return self.compositionStatus(hwnd);
            if (wparam != 1 or !self.composition_requested) return 0;
            const raw = std.math.cast(u32, lparam) orelse return 0;
            const failure = std.enums.fromInt(dcomp.Failure, raw) orelse return 0;
            const cookie = self.uia_cookie;
            self.releaseComposition();
            self.composition_attempted = false;
            self.composition_failed = false;
            self.composition_failure = failure;
            self.invalidate();
            _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | w32.RDW_UPDATENOW);
            const current = livePopup(hwnd, cookie) orelse return 0;
            return current.compositionStatus(hwnd);
        },
        w32.WM_SIZE => {
            self.invalidate();
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.dpi = @intCast((wparam >> 16) & 0xFFFF);
            const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
            if (self.callbacks) |cb| if (cb.dpi_changed) |f| f(cb.ctx, self);
            self.invalidate();
            return 0;
        },
        w32.WM_TIMER => {
            switch (wparam) {
                REVEAL_TIMER_ID => self.reveal(hwnd),
                CARET_TIMER_ID => self.onBlink(hwnd),
                REPEAT_TIMER_ID => self.onRepeatTimer(hwnd),
                else => if (self.callbacks) |cb| if (cb.timer) |f| f(cb.ctx, self, wparam),
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            const hit: u16 = @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF);
            if (hit != w32.HTCLIENT or wparam != @intFromPtr(hwnd)) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            _ = w32.ScreenToClient(hwnd, &pt);
            const s = self.scale();
            setCursorShape(self.cursorAt(.{ .x = @as(f32, @floatFromInt(pt.x)) / s, .y = @as(f32, @floatFromInt(pt.y)) / s }));
            return 1;
        },
        w32.WM_SETFOCUS => {
            self.onFocus(hwnd, true);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_KILLFOCUS => {
            self.onFocus(hwnd, false);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_SYSCOMMAND => {
            if (wparam & 0xFFF0 == SC_CLOSE) {
                self.handleClose(hwnd);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            self.handleClose(hwnd);
            return 0;
        },
        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            const key = keyFromWparam(wparam);
            if (self.callbacks) |cb| {
                if (cb.key) |f| {
                    if (f(cb.ctx, self, key)) return 0;
                }
            }
            if (self.options.text_input and self.handleKey(hwnd, key)) return 0;
            if (key.vk == w32.VK_ESCAPE and self.options.dismiss_on_escape) {
                self.dismiss(.escape);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CHAR => {
            if (!self.options.text_input) return 0;
            const unit: u16 = @intCast(wparam & 0xFFFF);
            // Control characters (Enter, Escape, Backspace, Ctrl+letter)
            // are handled as keys.
            if (unit < 0x20 or unit == 0x7F) return 0;
            self.handleChar(unit);
            return 0;
        },
        WM_IME_CHAR => return 0,
        w32.WM_IME_SETCONTEXT => {
            if (!self.options.text_input) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            // The composition is drawn inline by drawTextInput.
            const cleared = lparam & ~w32.ISC_SHOWUICOMPOSITIONWINDOW;
            return w32.DefWindowProcW(hwnd, msg, wparam, cleared);
        },
        w32.WM_IME_STARTCOMPOSITION => {
            if (!self.options.text_input) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.positionIme();
            return 0;
        },
        w32.WM_IME_COMPOSITION => {
            if (!self.options.text_input) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.handleImeComposition(hwnd, lparam);
            return 0;
        },
        w32.WM_IME_ENDCOMPOSITION => {
            if (self.options.text_input and self.input.composition.items.len > 0) {
                self.input.composition.clearRetainingCapacity();
                self.input.composition_attrs.clearRetainingCapacity();
                self.input.composition_cursor = 0;
                self.compositionChanged();
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = w32.TrackMouseEvent(&tme);
                self.tracking_leave = true;
            }
            const pos = self.pointFromLparam(lparam);
            self.dragInput(pos);
            self.emitMouse(.{ .kind = .move, .pos = pos });
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            self.emitMouse(.{ .kind = .leave, .pos = .{ .x = -1, .y = -1 } });
            return 0;
        },
        w32.WM_LBUTTONDOWN, w32.WM_RBUTTONDOWN, w32.WM_MBUTTONDOWN => {
            if (self.options.capture_mouse and self.options.dismiss_on_outside_click and !self.insideClient(lparam)) {
                self.dismiss(.outside_click);
                return 0;
            }
            const pos = self.pointFromLparam(lparam);
            if (msg == w32.WM_LBUTTONDOWN) _ = self.pressInput(hwnd, pos, false);
            self.emitMouse(.{ .kind = .down, .button = buttonOf(msg), .pos = pos });
            return 0;
        },
        w32.WM_LBUTTONUP, w32.WM_RBUTTONUP, w32.WM_MBUTTONUP => {
            if (msg == w32.WM_LBUTTONUP) self.releaseInput(hwnd);
            self.emitMouse(.{ .kind = .up, .button = buttonOf(msg), .pos = self.pointFromLparam(lparam) });
            return 0;
        },
        w32.WM_LBUTTONDBLCLK, WM_RBUTTONDBLCLK => {
            const pos = self.pointFromLparam(lparam);
            if (msg == w32.WM_LBUTTONDBLCLK) _ = self.pressInput(hwnd, pos, true);
            self.emitMouse(.{ .kind = .double_click, .button = buttonOf(msg), .pos = pos });
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            // Wheel coordinates are in screen space.
            var pt = w32.POINT{
                .x = @as(i16, @truncate(lparam & 0xFFFF)),
                .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
            };
            _ = w32.ScreenToClient(hwnd, &pt);
            const raw: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            const s = self.scale();
            self.emitMouse(.{
                .kind = .wheel,
                .pos = .{ .x = @as(f32, @floatFromInt(pt.x)) / s, .y = @as(f32, @floatFromInt(pt.y)) / s },
                .wheel = @as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt(w32.WHEEL_DELTA)),
            });
            return 0;
        },
        w32.WM_ACTIVATE => {
            const state: u16 = @truncate(wparam & 0xFFFF);
            if (state == w32.WA_INACTIVE) {
                // The owner paints its own activation again.
                self.unlockOwner();
                if (self.options.activate and self.options.dismiss_on_outside_click) self.dismiss(.deactivated);
            } else if (self.options.keep_owner_active and self.visible) {
                self.lockOwner();
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_CAPTURECHANGED => {
            const new_capture: usize = @bitCast(lparam);
            self.input.dragging = false;
            if (self.options.capture_mouse and self.options.dismiss_on_outside_click and new_capture != @intFromPtr(hwnd)) {
                self.dismiss(.outside_click);
            }
            return 0;
        },
        else => {
            if (msg >= w32.WM_APP and msg < 0xC000) {
                if (self.callbacks) |cb| if (cb.message) |f| {
                    if (f(cb.ctx, self, msg, wparam, lparam)) return 0;
                };
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

fn buttonOf(msg: u32) MouseButton {
    return switch (msg) {
        w32.WM_LBUTTONDOWN, w32.WM_LBUTTONUP, w32.WM_LBUTTONDBLCLK => .left,
        w32.WM_RBUTTONDOWN, w32.WM_RBUTTONUP, WM_RBUTTONDBLCLK => .right,
        w32.WM_MBUTTONDOWN, w32.WM_MBUTTONUP => .middle,
        else => .none,
    };
}

extern "user32" fn GetAncestor(hwnd: w32.HWND, gaFlags: u32) callconv(.winapi) ?w32.HWND;
extern "user32" fn GetCaretBlinkTime() callconv(.winapi) u32;
extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
extern "user32" fn CreateCaret(hWnd: w32.HWND, hBitmap: ?*anyopaque, nWidth: i32, nHeight: i32) callconv(.winapi) i32;
extern "user32" fn DestroyCaret() callconv(.winapi) i32;
extern "user32" fn SetCaretPos(X: i32, Y: i32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GlobalSize(hMem: *anyopaque) callconv(.winapi) usize;
extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;

test "opening phases partition the action through reveal including repeated raster" {
    var timing: OpenTiming = .{
        .kind = .menu,
        .start = .{ .nanoseconds = 1000 },
        .last = .{ .nanoseconds = 1000 },
    };
    timing.add(.prepare, 10);
    timing.add(.create, 20);
    timing.add(.layout, 30);
    timing.add(.raster, 40);
    timing.add(.raster, 50);
    const total = timing.finishAt(.{ .nanoseconds = 1_001_000 });
    try std.testing.expectEqual(@as(u64, 1000), total);
    try std.testing.expectEqual(@as(u64, 850), timing.phases[@intFromEnum(OpenTiming.Phase.show)]);
    var sum: u64 = 0;
    for (timing.phases) |us| sum += us;
    try std.testing.expectEqual(total, sum);
    var popup: Popup = .{ .open_timing = timing };
    popup.hide(); // Even a never-created/cancelled host drops the pending sample.
    try std.testing.expect(popup.open_timing == null);
    const before = perf.enabled();
    defer perf.setEnabled(before);
    perf.setEnabled(false);
    try std.testing.expect(OpenTiming.begin(.settings) == null);
}

test "modalQuitCode drops a withdrawn quit" {
    const testing = std.testing;
    // The WM_QUIT of a quit that a new terminal withdrew: the dialog stays.
    try testing.expectEqual(@as(?i32, null), modalQuitCode(false, 0));
    try testing.expectEqual(@as(?i32, null), modalQuitCode(false, 3));
    // A requested quit ends the loop and keeps its exit code.
    try testing.expectEqual(@as(?i32, 0), modalQuitCode(true, 0));
    try testing.expectEqual(@as(?i32, 3), modalQuitCode(true, 3));
    try testing.expectEqual(@as(?i32, -1), modalQuitCode(true, 0xFFFF_FFFF));
}

test "scrollToShow keeps the caret in view and moves little" {
    const testing = std.testing;
    // Fits: no scroll.
    try testing.expectEqual(@as(f32, 0), scrollToShow(0, 50, 100, 200));
    // The caret runs past the right edge: scroll just enough.
    try testing.expectApproxEqAbs(@as(f32, 102), scrollToShow(0, 300, 300, 200), 1e-4);
    // Moving the caret left inside the view keeps the scroll.
    try testing.expectApproxEqAbs(@as(f32, 102), scrollToShow(102, 150, 300, 200), 1e-4);
    // Past the left edge: the caret at the edge.
    try testing.expectApproxEqAbs(@as(f32, 40), scrollToShow(102, 40, 300, 200), 1e-4);
    // The text got shorter: no blank space after it.
    try testing.expectApproxEqAbs(@as(f32, 0), scrollToShow(102, 120, 150, 200), 1e-4);
}

test "held buttons repeat at the keyboard rate" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 250), repeatDelayMs(0));
    try testing.expectEqual(@as(u32, 500), repeatDelayMs(1));
    try testing.expectEqual(@as(u32, 1000), repeatDelayMs(3));
    try testing.expectEqual(@as(u32, 1000), repeatDelayMs(9));
    try testing.expectEqual(@as(u32, 400), repeatIntervalMs(0));
    try testing.expectEqual(@as(u32, 33), repeatIntervalMs(31));
    try testing.expect(repeatIntervalMs(15) > repeatIntervalMs(16));
}

test "the text input edits through text_edit and frees everything" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var input: TextInput = .{ .alloc = alloc };
    defer input.deinit(alloc);
    try input.setText(alloc, "hello world");
    try testing.expectEqual(@as(usize, 11), input.caret);
    _ = try text_edit.handleKey(alloc, &input, .{ .vk = text_edit.vk.back, .ctrl = true }, input.currentStops());
    const text = try input.text(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("hello ", text);
    // Undo comes back; clear forgets the history.
    try testing.expect(try text_edit.undo(alloc, &input));
    try testing.expectEqual(@as(usize, 11), input.buf.items.len);
    input.clear();
    try testing.expect(!input.history.canUndo());
    try testing.expectEqual(@as(usize, 0), input.buf.items.len);
    // Unpaired surrogates come out as U+FFFD, not as an empty string.
    try input.buf.appendSlice(alloc, &.{ 'a', 0xD83D });
    const odd = try input.text(alloc);
    defer alloc.free(odd);
    try testing.expectEqualStrings("a\u{FFFD}", odd);
    var small: [3]u8 = undefined;
    try testing.expectEqualStrings("a", input.utf8Range(&small, 0, 2));
}

test "stale cluster stops are not used" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var input: TextInput = .{ .alloc = alloc };
    defer input.deinit(alloc);
    try input.setText(alloc, "abcd");
    try input.stops.appendSlice(alloc, &.{ 0, 1, 2, 3, 4 });
    input.stops_hash = TextInput.hashOf(input.buf.items);
    try testing.expect(input.currentStops() != null);
    // Same length, other text (a surrogate pair where "bc" was).
    input.buf.items[1] = 0xD83D;
    input.buf.items[2] = 0xDC7B;
    try testing.expectEqual(@as(?[]const u32, null), input.currentStops());
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
