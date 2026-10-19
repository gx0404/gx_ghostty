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
//! When the reveal timer next gets to run 300 ms or more after `show`
//! without a successful frame of its size and DPI, the popup applies its
//! timeout policy: it cancels its opening, or with `RevealTimeout.reveal`
//! (modal questions) comes up anyway and keeps painting (timer `RV`, from
//! 100 ms up to 1 s apart) until a frame succeeds. A busy thread can run
//! the timer later than 300 ms; nothing is decided before it runs.
//! WM_CLOSE (Alt+F4, the system close) hides a shown popup instead of
//! destroying it, reports `.owner` and, for an activating popup with
//! `Options.close_owner_on_close`, closes the window it belongs to; a
//! hidden popup ignores it. When Windows destroys the popup with its owner
//! (WM_NCDESTROY), `hwnd` becomes null and the render target goes; the
//! owner frees the rest with `destroy` or recreates it with `create`.
//! A host kept hidden between openings (`Options.reuse_host`) cannot be
//! activated while hidden; any show makes a popup that takes input
//! activatable, also when it bypasses `show` (`mayActivate`).
//! With `Options.keep_owner_active` an activating popup sends
//! `WM_GX_OWNER_ACTIVE_LOCK` (wparam 1) to its root owner before it takes
//! activation and (wparam 0) once it hid or lost activation, so the owner
//! can keep painting its frame as active; the owner re-evaluates its
//! frame on unlock. With `Options.motion` the popup fades in (`anim`, the
//! 167 ms entrance of `gx.motion`) as a layered window painted through a
//! `d2d.DibTarget`; whether a window is layered is decided when it is
//! created (`animationMatches`).
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
const builtin = @import("builtin");
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
    const Frame = struct { width: u32, height: u32, dpi: u32 };
    kind: Kind,
    start: perf.Instant,
    last: perf.Instant,
    phases: [5]u64 = @splat(0),
    painted: bool = false,
    frame: ?Frame = null,
    ready: ?perf.Instant = null,
    /// Paints during ShowWindow/RedrawWindow must wait for the rest of the
    /// synchronous show path before capturing ready (just before the RV timer).
    showing: bool = false,

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

    pub fn addSince(self: *OpenTiming, phase: Phase, start: perf.Instant) void {
        self.add(phase, perf.sinceUs(global.io(), start));
    }

    fn readyAt(self: *OpenTiming, at: perf.Instant, current: Frame) void {
        if (self.showing or self.ready != null) return;
        const frame = self.frame orelse return;
        if (current.width == 0 or current.height == 0 or !std.meta.eql(frame, current)) return;
        self.ready = at;
    }

    fn finishAt(self: *OpenTiming, at: perf.Instant) u64 {
        const total = perf.elapsedUs(self.start, at);
        var work: u64 = 0;
        for (self.phases[0..4]) |us| work += us;
        self.phases[@intFromEnum(Phase.show)] = total -| work;
        return total;
    }

    fn reportAt(self: *OpenTiming, comptime Recorder: type, at: perf.Instant) void {
        const total = self.finishAt(at);
        switch (self.kind) {
            inline else => |kind| {
                inline for (std.meta.fields(Phase), 0..) |phase, i| {
                    Recorder.record(@tagName(kind) ++ ".open." ++ phase.name, self.phases[i]);
                }
                Recorder.record(@tagName(kind) ++ ".open.ready", perf.elapsedUs(self.start, self.ready.?));
                Recorder.record(@tagName(kind) ++ ".open.total", total);
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

/// Whether a popup with `Options.motion` fades in (`anim.enabled`), asked
/// when a host is created (layered or not) and when it is shown. Tests
/// replace it and never change the system setting. GUI thread.
pub var animation_policy: *const fn () bool = &anim.enabled;

/// What a popup does when its reveal timer next gets to run at least
/// `reveal_timeout_ms` after `show` and there is still no successful frame
/// of its current size and DPI (a lost or failing device).
pub const RevealTimeout = enum {
    /// Cancel the opening and log it: the popup hides and reports a
    /// dismissal (`.owner`). Menus, the command palette, the settings and
    /// the other popups, which are opened again at will.
    cancel,
    /// Reveal it anyway and log it, then keep painting until a frame
    /// succeeds: modal questions (`Dialogs`), which must stay answerable
    /// from the keyboard and UI Automation and never answer by themselves.
    reveal,
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
    /// Prefer the software-first DC/DIB path for legacy painting, including
    /// its default-target fallback if software target creation fails. False
    /// keeps HWND painting for non-layered popups. DirectComposition still
    /// takes priority; this does not change activation, layering or reveal.
    prefer_software: bool = false,
    /// When an activating popup gets WM_CLOSE (Alt+F4, the system close),
    /// also close its root owner window: Alt+F4 closes the window, not just
    /// the popup. Modal dialogs turn it off and treat the close as Cancel
    /// (`Callbacks.dismissed` with `.owner`). Popups that never take the
    /// focus only hide.
    close_owner_on_close: bool = true,
    /// A host kept hidden between openings for reuse (the command palette,
    /// the settings): while hidden (created, prepared or closed) it cannot
    /// be activated (`WS_EX_NOACTIVATE`), so neither preparing it nor an
    /// outside caller takes the focus from the window. Any show makes an
    /// activating host activatable again (`mayActivate`).
    reuse_host: bool = false,
    /// What the first-frame reveal does when it next runs 300 ms or more
    /// after `show` without a successful frame (`RevealTimeout`).
    reveal_timeout: RevealTimeout = .cancel,
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
/// The keyboard focus moved and is reported once the next paint laid the
/// popup out (`focusMovedAtPaint`).
uia_focus_pending: bool = false,
visible: bool = false,
/// Created with `Options.activate`: the popup takes input, so it is
/// activatable whenever it is shown (`mayActivate`). Owners that clear
/// `options.activate` around one `show` that must not take the focus (the
/// remote inspector) do not change it.
activatable: bool = false,
/// An invalidated host may finish its active transaction, but cannot be reused
/// by a later opening (configuration/DPI/device generation changed).
reuse_invalid: bool = false,
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
reveal_started_ms: u64 = 0,
successful_frame: ?OpenTiming.Frame = null,
/// Revealed without a successful frame (`RevealTimeout.reveal`): the reveal
/// timer paints again after `repaint_retry_delay_ms` until a frame succeeds.
repaint_retry: bool = false,
/// The wait before the next paint retry: `repaint_retry_first_ms`, doubled
/// after each retry that still painted no frame, at most
/// `repaint_retry_max_ms` (`nextRepaintRetry`).
repaint_retry_delay_ms: u32 = repaint_retry_first_ms,
/// Created as a layered window for `Options.motion`; painted through `dib`.
layered: bool = false,
dib: d2d.DibTarget = .{},
/// Native tests can reject the copy after a successful EndDraw. No state or
/// failure branch exists in production builds.
test_fail_blit: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},
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
const WM_WINDOWPOSCHANGING: u32 = 0x0046;
const WM_WINDOWPOSCHANGED: u32 = 0x0047;
const SWP_HIDEWINDOW: u32 = 0x0080;
const WINDOWPOS = extern struct {
    hwnd: ?w32.HWND,
    hwndInsertAfter: ?w32.HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: u32,
};
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
const reveal_timeout_ms: u64 = 300;
/// How long a modal popup revealed without a frame waits before it paints
/// again: 100 ms at first, doubled after each failed paint, at most 1 s.
const repaint_retry_first_ms: u32 = 100;
const repaint_retry_max_ms: u32 = 1000;

/// The wait after a paint retry that still produced no frame.
fn nextRepaintRetry(delay_ms: u32) u32 {
    return @min(delay_ms *| 2, repaint_retry_max_ms);
}

const RevealStep = enum { reveal, wait, cancel, reveal_unpainted };

fn revealStep(ready: bool, elapsed_ms: u64, timeout: RevealTimeout) RevealStep {
    if (ready) return .reveal;
    if (elapsed_ms < reveal_timeout_ms) return .wait;
    return switch (timeout) {
        .cancel => .cancel,
        .reveal => .reveal_unpainted,
    };
}

/// Coalesced event work for the hidden UI of one owner, consumed one unit at
/// a time at an outer message-loop idle boundary (`Menu.prepareIdle`). A
/// blocked owner keeps its units; a consumed unit never polls itself.
pub const Preparation = struct {
    /// The hidden UI one owner prepares, in this order; each is one unit of
    /// idle work.
    pub const Unit = enum { palette, main_menu, settings };

    pending: std.EnumSet(Unit) = .initFull(),

    /// Prepare every unit again, at the next idle boundaries.
    pub fn request(self: *Preparation) void {
        self.pending = .initFull();
    }

    /// Whether a unit waits.
    pub fn isPending(self: *const Preparation) bool {
        return self.pending.count() > 0;
    }

    /// Consume the next waiting unit of an `eligible` owner; an owner that is
    /// not eligible keeps them all.
    pub fn takeNext(self: *Preparation, eligible: bool) ?Unit {
        if (!eligible) return null;
        var units = self.pending.iterator();
        const unit = units.next() orelse return null;
        self.pending.remove(unit);
        return unit;
    }
};

test "P4 reuse preparation hands out one unit at a time and never polls" {
    const testing = std.testing;
    var preparation: Preparation = .{};
    try testing.expect(preparation.takeNext(false) == null);
    try testing.expect(preparation.isPending());
    for (std.enums.values(Preparation.Unit)) |unit| try testing.expectEqual(unit, preparation.takeNext(true).?);
    try testing.expect(!preparation.isPending());
    for (0..100) |_| try testing.expect(preparation.takeNext(true) == null);
    preparation.request();
    preparation.request();
    try testing.expectEqual(Preparation.Unit.palette, preparation.takeNext(true).?);
    try testing.expect(preparation.takeNext(false) == null);
    try testing.expectEqual(Preparation.Unit.main_menu, preparation.takeNext(true).?);
    try testing.expectEqual(Preparation.Unit.settings, preparation.takeNext(true).?);
    try testing.expect(preparation.takeNext(true) == null);
}

test "P4 reuse reveal requires a current frame and bounds failure by 300ms" {
    for ([_]RevealTimeout{ .cancel, .reveal }) |timeout| {
        try std.testing.expectEqual(RevealStep.wait, revealStep(false, 16, timeout));
        try std.testing.expectEqual(RevealStep.wait, revealStep(false, 299, timeout));
        try std.testing.expectEqual(RevealStep.reveal, revealStep(true, 16, timeout));
        try std.testing.expectEqual(RevealStep.reveal, revealStep(true, 300, timeout));
    }
    // Without a frame by 300 ms: non-modal popups cancel, modal ones come up.
    try std.testing.expectEqual(RevealStep.cancel, revealStep(false, 300, .cancel));
    try std.testing.expectEqual(RevealStep.reveal_unpainted, revealStep(false, 300, .reveal));
}

test "P4 a modal popup's paint retry backs off from 100ms to at most 1s" {
    var delay: u32 = repaint_retry_first_ms;
    var waits: [7]u32 = undefined;
    for (&waits) |*wait| {
        wait.* = delay;
        delay = nextRepaintRetry(delay);
    }
    try std.testing.expectEqualSlices(u32, &.{ 100, 200, 400, 800, 1000, 1000, 1000 }, &waits);
    try std.testing.expectEqual(repaint_retry_max_ms, nextRepaintRetry(std.math.maxInt(u32)));
}

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

    const layered = options.motion != null and animation_policy();
    // TOOLWINDOW keeps every popup out of Alt+Tab. A hidden reuse host must
    // never activate; an input popup is activatable in every show path.
    var ex_style: u32 = w32.WS_EX_TOOLWINDOW;
    if (!mayActivate(options.activate, options.reuse_host, false)) ex_style |= w32.WS_EX_NOACTIVATE;
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
        .activatable = options.activate,
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
    self.repaint();
}

/// Whether this host can play the entrance an opening plays now
/// (`animation_policy`): a host created while animations were off has no
/// layered surface to fade with, and one created while they were on still
/// paints as a layered window. `WS_EX_LAYERED` decides how a window is
/// painted, not only its alpha, so a kept host that does not match is
/// rebuilt hidden (`MenuPopup`), never restyled.
pub fn animationMatches(self: *const Popup) bool {
    return self.layered == (self.options.motion != null and animation_policy());
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
    self.reuse_invalid = true;
    self.successful_frame = null;
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

    self.uiaDetach();
    self.successful_frame = null;
    self.syncActivationStyle(true);
    if (self.open_timing) |*timing| timing.showing = true;
    if (self.options.activate and self.options.keep_owner_active) self.lockOwner();
    const motion = if (self.layered) self.options.motion else null;
    const animate = motion != null and animation_policy();
    self.composition_frame = null;
    // Cloaked until it painted and DWM had a frame for it.
    setCloaked(hwnd, true);
    self.revealing = true;
    self.reveal_started_ms = GetTickCount64();
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
    var current: w32.RECT = undefined;
    const known = w32.GetWindowRect(hwnd, &current) != 0;
    const flags = showPlacementFlags(if (known) current else null, start, self.options.activate);
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
    if (self.open_timing) |*timing| {
        timing.showing = false;
        self.markOpenReady(hwnd, perf.now(global.io()));
    }
    if (w32.SetTimer(hwnd, REVEAL_TIMER_ID, reveal_ms, null) == 0) self.reveal(hwnd);
}

fn showPlacementFlags(current: ?w32.RECT, target: w32.RECT, activate: bool) u32 {
    var flags: u32 = if (activate) 0 else w32.SWP_NOACTIVATE;
    if (current) |rect| {
        if (rect.left == target.left and rect.top == target.top) flags |= w32.SWP_NOMOVE;
        if (rect.right - rect.left == target.right - target.left and
            rect.bottom - rect.top == target.bottom - target.top) flags |= w32.SWP_NOSIZE;
    }
    return flags;
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

/// Prelayout/rasterize an owned hidden host without showing, activating,
/// capturing input, publishing UIA or starting an opening measurement. Every
/// real show still clears the frame proof and paints synchronously.
pub fn prepareHidden(self: *Popup, rect: w32.RECT) void {
    if (self.visible) return;
    const hwnd = self.hwnd orelse return;
    self.setBounds(rect);
    self.dpi = dpiOf(hwnd);
    self.repaint();
    _ = w32.SendMessageW(hwnd, w32.WM_PAINT, 0, 0);
}

/// Whether the popup window may be activated (no `WS_EX_NOACTIVATE`): one
/// that takes input may be in every show path, including those that bypass
/// `show` (`SearchBar.showInactive`, `Palette.adoptShown`, the owner coming
/// back from minimized), except a reuse host while it is hidden.
fn mayActivate(activatable: bool, reuse_host: bool, shown: bool) bool {
    return activatable and (shown or !reuse_host);
}

/// Set the activation style for the popup being `shown` or hidden. Every
/// show and hide passes here (`show`, `hide`, and WM_WINDOWPOSCHANGING /
/// WM_WINDOWPOSCHANGED for the paths that do not use them).
fn syncActivationStyle(self: *Popup, shown: bool) void {
    self.setActivationStyle(mayActivate(self.activatable, self.options.reuse_host, shown));
}

fn setActivationStyle(self: *Popup, activate: bool) void {
    const hwnd = self.hwnd orelse return;
    const old = w32.GetWindowLongPtrW(hwnd, w32.GWL_EXSTYLE);
    const next = activationStyle(old, activate);
    if (old != next) _ = w32.SetWindowLongPtrW(hwnd, w32.GWL_EXSTYLE, next);
}

fn activationStyle(old: isize, activate: bool) isize {
    const flag: isize = w32.WS_EX_NOACTIVATE;
    return if (activate) old & ~flag else old | flag;
}

test "P4 reuse hidden hosts cannot activate and remain tool windows" {
    const tool: isize = w32.WS_EX_TOOLWINDOW | w32.WS_EX_LAYERED;
    const hidden = activationStyle(tool, false);
    try std.testing.expect(hidden & w32.WS_EX_NOACTIVATE != 0);
    try std.testing.expect(hidden & tool == tool);
    try std.testing.expectEqual(tool, activationStyle(hidden, true));
}

test "P4 only a hidden reuse host refuses activation" {
    // Input popups (find bar, dialogs, inspector): activatable hidden or shown.
    try std.testing.expect(mayActivate(true, false, false));
    try std.testing.expect(mayActivate(true, false, true));
    // Palette and settings hosts: not while hidden or prepared, yes once shown.
    try std.testing.expect(!mayActivate(true, true, false));
    try std.testing.expect(mayActivate(true, true, true));
    // Previews, tooltips, menus: never.
    for ([_]bool{ false, true }) |reuse| for ([_]bool{ false, true }) |shown| {
        try std.testing.expect(!mayActivate(false, reuse, shown));
    };
}

/// Real (hidden, cloaked, off-screen) popup windows for activation tests;
/// nothing is ever activated or drawn on the desktop.
const ActivationFixture = struct {
    const MA_ACTIVATE_: isize = 1;

    fn paint(_: *anyopaque, _: *Popup, _: *d2d.Canvas) void {}

    fn owner() !w32.HWND {
        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        return w32.CreateWindowExW(0, class, class, 0, -32000, -32000, 32, 32, null, null, null, null) orelse error.TestWindowFailed;
    }

    fn noActivate(hwnd: w32.HWND) bool {
        const bits: usize = @bitCast(w32.GetWindowLongPtrW(hwnd, w32.GWL_EXSTYLE));
        return bits & w32.WS_EX_NOACTIVATE != 0;
    }

    /// What a left click asks the popup before Windows activates it.
    fn mouseActivate(hwnd: w32.HWND, owner_hwnd: w32.HWND) isize {
        const lparam: isize = (@as(isize, w32.WM_LBUTTONDOWN) << 16) | @as(isize, w32.HTCLIENT);
        return w32.SendMessageW(hwnd, w32.WM_MOUSEACTIVATE, @intFromPtr(owner_hwnd), lparam);
    }

    /// `SearchBar.showInactive` (and an outside `ShowWindow` that
    /// `Palette.adoptShown` adopts): shown without `Popup.show`.
    fn showInactive(popup: *Popup) void {
        const hwnd = popup.hwnd.?;
        setCloaked(hwnd, true);
        _ = w32.SetWindowPos(hwnd, null, -32000, -32000, 64, 32, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
        popup.visible = true;
    }
};

test "P4 an input popup shown outside Popup.show stays click-activatable" {
    // The find bar comes back with SearchBar.showInactive when its tab is
    // shown again or its split moved to another window. A click on it must
    // activate it and give it the keyboard (WM_MOUSEACTIVATE answers
    // MA_ACTIVATE and no WS_EX_NOACTIVATE refuses it), or typing goes on to
    // the terminal under it and Enter runs in the shell.
    const testing = std.testing;
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    var context: u8 = 0;
    var find: Popup = .{};
    defer find.destroy();
    try find.create(hinstance, owner, factory, .{
        .activate = true,
        .text_input = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .keep_owner_active = true,
    }, .{ .ctx = &context, .paint = ActivationFixture.paint });
    const hwnd = find.hwnd.?;
    try testing.expect(!ActivationFixture.noActivate(hwnd));
    ActivationFixture.showInactive(&find);
    try testing.expect(!ActivationFixture.noActivate(hwnd));
    try testing.expectEqual(ActivationFixture.MA_ACTIVATE_, ActivationFixture.mouseActivate(hwnd, owner));
    // The tab is hidden again and comes back once more.
    find.hide();
    try testing.expect(!ActivationFixture.noActivate(hwnd));
    ActivationFixture.showInactive(&find);
    try testing.expect(!ActivationFixture.noActivate(hwnd));
    try testing.expectEqual(ActivationFixture.MA_ACTIVATE_, ActivationFixture.mouseActivate(hwnd, owner));

    // The remote inspector clears options.activate around one show that must
    // not take the focus; clicking it afterwards still activates it.
    var inspector: Popup = .{};
    defer inspector.destroy();
    try inspector.create(hinstance, owner, factory, .{ .activate = true, .dismiss_on_outside_click = false, .close_owner_on_close = false }, .{ .ctx = &context, .paint = ActivationFixture.paint });
    inspector.options.activate = false;
    inspector.show(.{ .left = -32000, .top = -32000, .right = -31936, .bottom = -31968 });
    inspector.options.activate = true;
    try testing.expect(inspector.visible);
    try testing.expect(!ActivationFixture.noActivate(inspector.hwnd.?));
    inspector.hide();
    try testing.expect(!ActivationFixture.noActivate(inspector.hwnd.?));

    // A reuse host (palette, settings) refuses activation only while hidden,
    // also when an outside caller shows it by handle (Palette.adoptShown).
    var host: Popup = .{};
    defer host.destroy();
    try host.create(hinstance, owner, factory, .{ .activate = true, .text_input = true, .reuse_host = true }, .{ .ctx = &context, .paint = ActivationFixture.paint });
    const host_hwnd = host.hwnd.?;
    try testing.expect(ActivationFixture.noActivate(host_hwnd));
    ActivationFixture.showInactive(&host);
    try testing.expect(!ActivationFixture.noActivate(host_hwnd));
    try testing.expectEqual(ActivationFixture.MA_ACTIVATE_, ActivationFixture.mouseActivate(host_hwnd, owner));
    host.hide();
    try testing.expect(ActivationFixture.noActivate(host_hwnd));

    // A preview never activates, shown or not.
    var preview: Popup = .{};
    defer preview.destroy();
    try preview.create(hinstance, owner, factory, .{ .activate = false }, .{ .ctx = &context, .paint = ActivationFixture.paint });
    try testing.expect(ActivationFixture.noActivate(preview.hwnd.?));
    ActivationFixture.showInactive(&preview);
    try testing.expect(ActivationFixture.noActivate(preview.hwnd.?));
    try testing.expectEqual(w32.MA_NOACTIVATE, ActivationFixture.mouseActivate(preview.hwnd.?, owner));
    preview.hide();
}

test "P4 a modal popup with no first frame is revealed after 300ms, others cancel" {
    // A popup without callbacks paints no frame, as a lost device does: its
    // show stays cloaked, waiting for one. After 300 ms a modal question must
    // come up anyway (keyboard and UI Automation work, nothing answers for
    // the user); any other popup cancels its opening.
    const testing = std.testing;
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    var context: u8 = 0;
    const rect: w32.RECT = .{ .left = -32000, .top = -32000, .right = -31936, .bottom = -31968 };
    for ([_]RevealTimeout{ .reveal, .cancel }) |timeout| {
        var popup: Popup = .{};
        defer popup.destroy();
        try popup.create(hinstance, owner, factory, .{ .reveal_timeout = timeout }, .{ .ctx = &context, .paint = ActivationFixture.paint });
        const hwnd = popup.hwnd.?;
        popup.callbacks = null;
        popup.show(rect);
        try testing.expect(popup.visible and popup.revealing);
        try testing.expect(popup.successful_frame == null);
        // The reveal timer, 300 ms later.
        popup.reveal_started_ms -|= reveal_timeout_ms;
        popup.reveal(hwnd);
        try testing.expect(!popup.revealing);
        switch (timeout) {
            .reveal => {
                try testing.expect(popup.visible and w32.IsWindowVisible_(hwnd) != 0);
                try testing.expect(popup.repaint_retry);
                try testing.expectEqual(repaint_retry_first_ms, popup.repaint_retry_delay_ms);
                // The next reveal timers paint again, each waiting twice as
                // long; once a frame succeeds they stop.
                popup.reveal(hwnd);
                try testing.expect(popup.repaint_retry and popup.visible);
                try testing.expectEqual(@as(u32, 200), popup.repaint_retry_delay_ms);
                popup.reveal(hwnd);
                try testing.expect(popup.repaint_retry and popup.visible);
                try testing.expectEqual(@as(u32, 400), popup.repaint_retry_delay_ms);
                popup.callbacks = .{ .ctx = &context, .paint = ActivationFixture.paint };
                popup.reveal(hwnd);
                try testing.expect(!popup.repaint_retry and popup.visible);
                try testing.expect(popup.successful_frame != null);
            },
            .cancel => {
                try testing.expect(!popup.visible and w32.IsWindowVisible_(hwnd) == 0);
                try testing.expect(!popup.repaint_retry);
            },
        }
        popup.hide();
        try testing.expect(!popup.repaint_retry);
        try testing.expectEqual(repaint_retry_first_ms, popup.repaint_retry_delay_ms);
    }
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
    self.successful_frame = null;
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
    self.syncActivationStyle(false);
    if (self.options.release_target_on_hide) self.discardTarget();
}

/// Hide and report `reason` through `Callbacks.dismissed`.
pub fn dismiss(self: *Popup, reason: DismissReason) void {
    if (!self.visible) return;
    self.hide();
    if (self.callbacks) |cb| if (cb.dismissed) |f| f(cb.ctx, self, reason);
}

/// Repaint after a model/layout edit. Revoke index-based UIA actions until the
/// changed model is published; visual-only changes must use `repaint` instead.
pub fn invalidate(self: *Popup) void {
    self.uiaDirty();
    self.repaint();
}

/// Schedule drawing without changing the accessible model or its lifetime.
/// A caret blink or hover color must not revoke an external COM provider.
pub fn repaint(self: *Popup) void {
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

/// The keyboard focus moved within the popup, or into or out of it, and the
/// model did not change: repaint, and let UI Automation report the new
/// focus at once (`HasKeyboardFocus`, `GetFocus` and the focus changed
/// event, `reportFocus`) without revoking the elements clients hold. For
/// widgets whose accessible model comes from their state, not from a paint.
pub fn focusMoved(self: *Popup) void {
    self.repaint();
    self.reportFocus();
}

/// `focusMoved` for a widget whose accessible model comes from its last
/// paint (the hit rectangles of the settings): the focus is reported after
/// the paint that shows it, which may also scroll it into view. A paint that
/// laid out anything else publishes everything anew instead, the focus
/// included (`uiaLayoutChanged`).
pub fn focusMovedAtPaint(self: *Popup) void {
    self.uia_focus_pending = true;
    self.repaint();
}

/// Report where the keyboard focus is now: the widget rebuilds its specs
/// only to say so (`PopupBridge.focus_only`), the focus moves within the
/// published snapshot and its changed event is queued for the message loop.
/// Specs that differ in anything else revoke the snapshot, which is then
/// published anew at once; so does a pending model change, at the paint it
/// waits for.
fn reportFocus(self: *Popup) void {
    self.uia_focus_pending = false;
    if (!self.visible or self.uia_refreshing or self.uia_view.needs_publish or self.uia_view.publisher.current == null) return;
    const cb = self.callbacks orelse return;
    const source = cb.uia_source orelse return;
    if (source.app.drop_closing or !source.is_live(cb.ctx)) return;
    const api = source.app.uia_api orelse return;
    const queue = source.app.uia_queue orelse return;
    {
        self.uia_refreshing = true;
        defer self.uia_refreshing = false;
        self.uia_view.focus_only = true;
        defer self.uia_view.focus_only = false;
        source.build(cb.ctx, self, &self.uia_view, api, queue) catch self.uiaDirty();
    }
    if (self.uia_view.needs_publish) self.uiaRefresh();
}

fn uiaDirty(self: *Popup) void {
    self.uia_view.dirty();
    self.uia_layout_pending = true;
}

/// What the published accessible model was built from was laid out anew
/// while painting (a widget whose tokens are positions scrolled): revoke
/// the elements clients hold. The paint that is running publishes the new
/// layout when it ends.
pub fn uiaLayoutChanged(self: *Popup) void {
    self.uiaDirty();
}

fn uiaDetach(self: *Popup) void {
    if (self.callbacks) |cb| if (cb.uia_source) |source| {
        source.app.uia_popups.unregister(&self.uia_view);
    };
    self.uia_view.hide();
    self.uia_layout_pending = true;
    self.uia_focus_pending = false;
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
    if (current.uia_layout_pending or current.uia_focus_pending) current.paint(hwnd);
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
/// first frame of a new window), uncloak and start the fade-in. Without a
/// successful frame it waits; the first time it runs `reveal_timeout_ms` or
/// more after `show` it cancels or (with `RevealTimeout.reveal`) reveals the
/// popup unpainted and paints again.
fn reveal(self: *Popup, hwnd: w32.HWND) void {
    _ = w32.KillTimer(hwnd, REVEAL_TIMER_ID);
    if (!self.revealing) {
        if (self.repaint_retry) self.retryPaint(hwnd);
        return;
    }
    const cookie = self.uia_cookie;
    _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | RDW_UPDATENOW);
    const current = livePopup(hwnd, cookie) orelse return;
    // Neither a reused host nor the opt-in composition fallback may reveal a
    // failed/stale frame. Bound recovery rather than leaving a cloaked zombie.
    const timeout = current.options.reveal_timeout;
    var step = revealStep(current.frameReady(hwnd), GetTickCount64() -| current.reveal_started_ms, timeout);
    if (step == .wait and w32.SetTimer(hwnd, REVEAL_TIMER_ID, reveal_ms, null) == 0) {
        // No timer to wait with: decide as at the timeout.
        step = revealStep(false, reveal_timeout_ms, timeout);
    }
    switch (step) {
        .wait => return,
        .cancel => {
            log.warn("popup first frame unavailable after 300ms; cancelling reveal", .{});
            current.dismiss(.owner);
            return;
        },
        .reveal_unpainted => {
            // A modal question must not answer itself: up for the keyboard
            // and UI Automation, painted as soon as the device lets it.
            log.warn("popup first frame unavailable after 300ms; revealing it unpainted and painting again", .{});
            current.repaint_retry = true;
            current.repaint_retry_delay_ms = repaint_retry_first_ms;
        },
        .reveal => {},
    }
    current.revealing = false;
    setCloaked(hwnd, false);
    if (current.repaint_retry) {
        // Opaque in place at once; an unpainted opening reports no sample.
        current.fade_pending = false;
        current.open_timing = null;
        if (current.layered) _ = w32.SetLayeredWindowAttributes(hwnd, 0, 255, w32.LWA_ALPHA);
        if (w32.SetTimer(hwnd, REVEAL_TIMER_ID, current.repaint_retry_delay_ms, null) == 0) current.repaint_retry = false;
        return;
    }
    if (!self.fade_pending) {
        self.finishOpenTiming();
        return;
    }
    self.fade_pending = false;
    self.fade = anim.Tween.begin(anim.now(), anim.motion.duration.fast, anim.motion.enter);
    if (!anim.start(&self.animator)) self.finishMotion(hwnd);
}

/// Whether the last successful paint is of the current size and DPI (the
/// opt-in composition path checks its own frame).
fn frameReady(self: *Popup, hwnd: w32.HWND) bool {
    if (self.composition_requested) return self.compositionReady(hwnd);
    const frame = self.successful_frame orelse return false;
    const size = self.openFrame(hwnd) orelse return false;
    return std.meta.eql(frame, size);
}

/// A modal popup revealed without a frame (`RevealTimeout.reveal`): paint
/// again, backing off (`nextRepaintRetry`), until a frame of its size and
/// DPI succeeds.
fn retryPaint(self: *Popup, hwnd: w32.HWND) void {
    const cookie = self.uia_cookie;
    _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | RDW_UPDATENOW);
    const current = livePopup(hwnd, cookie) orelse return;
    if (!current.repaint_retry) return;
    if (current.frameReady(hwnd)) {
        current.repaint_retry = false;
        log.info("popup painted after an unpainted reveal", .{});
        return;
    }
    current.repaint_retry_delay_ms = nextRepaintRetry(current.repaint_retry_delay_ms);
    if (w32.SetTimer(hwnd, REVEAL_TIMER_ID, current.repaint_retry_delay_ms, null) == 0) current.repaint_retry = false;
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
    if (self.open_timing == null) return;
    self.finishOpenTimingAt(perf, perf.now(global.io()));
}

fn finishOpenTimingAt(self: *Popup, comptime Recorder: type, at: perf.Instant) void {
    var timing = self.open_timing orelse return;
    // Take before logging: an opening can report only once, even on reentry.
    self.open_timing = null;
    if (timing.painted and timing.ready != null) timing.reportAt(Recorder, at);
}

fn openFrame(self: *const Popup, hwnd: w32.HWND) ?OpenTiming.Frame {
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0 or client.right <= 0 or client.bottom <= 0) return null;
    return .{ .width = @intCast(client.right), .height = @intCast(client.bottom), .dpi = self.canvasDpi() };
}

fn markOpenReady(self: *Popup, hwnd: w32.HWND, at: perf.Instant) void {
    const timing = if (self.open_timing) |*value| value else return;
    if (timing.showing or timing.ready != null or timing.frame == null) return;
    timing.readyAt(at, self.openFrame(hwnd) orelse return);
}

/// Stop a reveal or fade in progress (hiding).
fn endMotion(self: *Popup, hwnd: w32.HWND) void {
    self.open_timing = null;
    if (self.revealing or self.repaint_retry) _ = w32.KillTimer(hwnd, REVEAL_TIMER_ID);
    self.repaint_retry = false;
    self.repaint_retry_delay_ms = repaint_retry_first_ms;
    if (self.revealing) {
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
    if (!self.blinkCaret(GetTickCount64() -| self.blink_started, timeout)) {
        _ = w32.KillTimer(hwnd, CARET_TIMER_ID);
    }
}

/// Update the visual caret state; false asks the caller to stop its timer.
/// Elapsed time and the system timeout are inputs so this transition can be
/// tested without a native window, a desktop, a timer or wall-clock waits.
fn blinkCaret(self: *Popup, elapsed_ms: u64, timeout_ms: u32) bool {
    self.input.caret_on = !self.input.caret_on;
    // No input on screen: nothing blinks.
    const drawn = self.input.field.w > 0;
    if (!self.focused or !drawn) {
        self.input.caret_on = true;
        return false;
    }
    // Stop blinking after a while without input, like Windows text boxes,
    // so an idle field costs nothing.
    const running = elapsed_ms < timeout_ms;
    if (!running) {
        self.input.caret_on = true;
    }
    self.repaint();
    return running;
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
    self.focusMoved();
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
        self.repaint();
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
    self.repaint();
    return true;
}

fn dragInput(self: *Popup, pos: d2d.Point) void {
    if (!self.input.dragging) return;
    const at = self.input.positionAt(pos) orelse return;
    if (at == self.input.caret) return;
    text_edit.pointerDrag(&self.input, at);
    self.restartBlink();
    self.repaint();
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
    self.repaint_retry = false;
    self.repaint_retry_delay_ms = repaint_retry_first_ms;
    self.repeat_tag = null;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
}

fn paint(self: *Popup, hwnd: w32.HWND) void {
    const cookie = self.uia_cookie;
    const raster = if (self.open_timing != null) perf.Span.begin(global.io()) else null;
    defer if (raster) |span| {
        if (livePopup(hwnd, cookie)) |current| {
            if (current.open_timing) |*timing| {
                const at = perf.now(global.io());
                timing.add(.raster, perf.elapsedUs(span.start, at));
                // If synchronous show could not paint, take the first later
                // successful current-size/DPI frame after EndPaint/UIA refresh.
                current.markOpenReady(hwnd, at);
            }
        }
    };
    defer if (livePopup(hwnd, cookie)) |current| {
        current.uia_layout_pending = false;
        const published = current.uia_view.publisher.current;
        current.uiaRefresh();
        // A new publication reports the focus itself.
        if (current.uia_view.publisher.current != published) current.uia_focus_pending = false;
        if (current.uia_focus_pending) current.reportFocus();
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
    if (self.layered or self.options.prefer_software) {
        // Layered windows require the GDI path. Small, non-layered popups
        // can opt into the same DIB without creating an HWND render target.
        const dc = hdc orelse return;
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        const mem = self.dib.ensure(dc, client.right, client.bottom) orelse return;
        const dpi = self.canvasDpi();
        if (!canvas.beginDc(mem, .{ .left = 0, .top = 0, .right = client.right, .bottom = client.bottom }, dpi)) return;
        const frame: OpenTiming.Frame = .{ .width = @intCast(client.right), .height = @intCast(client.bottom), .dpi = dpi };
        canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        cb.paint(cb.ctx, self, canvas);
        switch (canvas.finish()) {
            .ok => {
                const source: w32.HDC = if (builtin.is_test)
                    (if (self.test_fail_blit) @ptrFromInt(1) else mem)
                else
                    mem;
                if (w32.BitBlt(dc, 0, 0, client.right, client.bottom, source, 0, 0, w32.SRCCOPY) != 0) self.markLegacyFrame(hwnd, frame);
            },
            .recreate => {
                self.reuse_invalid = true;
                self.repaint();
            },
            .failed => self.reuse_invalid = true,
        }
        return;
    }
    if (!canvas.beginHwnd(hwnd, self.canvasDpi())) return;
    const frame = self.openFrame(hwnd);
    canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    cb.paint(cb.ctx, self, canvas);
    switch (canvas.finish()) {
        .ok => self.markLegacyFrame(hwnd, frame),
        .recreate => {
            self.reuse_invalid = true;
            self.repaint();
        },
        .failed => self.reuse_invalid = true,
    }
}

const SoftwarePaintFixture = struct {
    fail_end_draw: bool = false,
    dc_paints: usize = 0,
    borrowed_paints: usize = 0,

    // Off-screen, owned windows exercise show/reveal without taking focus.
    const rect: w32.RECT = .{ .left = -32000, .top = -32000, .right = -31880, .bottom = -31940 };

    fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
        const self: *SoftwarePaintFixture = @ptrCast(@alignCast(ctx));
        const size = popup.sizeDip();
        const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
        canvas.clear(.{ .r = 1, .g = 0, .b = 0 });
        canvas.fillRect(.{ .x = size.width / 2, .y = 0, .w = size.width / 2, .h = size.height }, .{ .r = 0, .g = 0, .b = 1 });
        canvas.drawText("P7", full, .{ .size = 14, .color = .white, .align_x = .center, .align_y = .center });
        switch (canvas.target) {
            .dc => |rt| {
                self.dc_paints += 1;
                // A real D2D error, reported by EndDraw: no clip was pushed.
                if (self.fail_end_draw) rt.vtable.render_target.PopAxisAlignedClip(@ptrCast(rt));
            },
            .borrowed => self.borrowed_paints += 1,
            else => {},
        }
    }

    fn expectPixels(_: *const SoftwarePaintFixture, popup: *const Popup) !void {
        try std.testing.expect(GdiFlush() != 0);
        const frame = popup.openFrame(popup.hwnd.?) orelse return error.NoTestFrame;
        const pixels: [*]const u32 = @ptrCast(@alignCast(popup.dib.bits orelse return error.NoTestPixels));
        const row: usize = @intCast(popup.dib.width);
        // Away from the centered label, both colored halves must be present.
        try std.testing.expectEqual(@as(u32, 0xff0000), pixels[row * 2 + 2] & 0xffffff);
        try std.testing.expectEqual(@as(u32, 0x0000ff), pixels[row * 2 + frame.width - 3] & 0xffffff);
    }

    extern "gdi32" fn GdiFlush() callconv(.winapi) i32;
};

test "P7 software popup paints current frames and releases its raster resources" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    var context: SoftwarePaintFixture = .{};
    var popup: Popup = .{};
    defer popup.destroy();
    try testing.expect(!popup.options.prefer_software);
    try popup.create(hinstance, owner, factory, .{ .prefer_software = true }, .{
        .ctx = &context,
        .paint = SoftwarePaintFixture.paint,
    });
    // Exercise only legacy painting, independent of the caller's DComp opt-in.
    // The popup stays hidden and never takes focus.
    popup.composition_requested = false;
    const hwnd = popup.hwnd.?;
    try testing.expect(w32.SetWindowPos(hwnd, null, -32000, -32000, 120, 60, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE) != 0);
    try testing.expect(!popup.layered);
    try testing.expect(ActivationFixture.noActivate(hwnd));
    try testing.expect(!popup.frameReady(hwnd));
    popup.paint(hwnd);
    try testing.expect(popup.canvas.?.target == .dc);
    try testing.expect(popup.frameReady(hwnd));
    try context.expectPixels(&popup);
    const target = popup.canvas.?.target.dc;
    const bitmap = popup.dib.bitmap.?;

    // A smaller frame reuses the buffer but cannot reveal the old dimensions.
    try testing.expect(w32.SetWindowPos(hwnd, null, -32000, -32000, 100, 50, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE) != 0);
    try testing.expect(!popup.frameReady(hwnd));
    popup.paint(hwnd);
    try testing.expect(popup.frameReady(hwnd));
    try testing.expectEqual(target, popup.canvas.?.target.dc);
    try testing.expectEqual(bitmap, popup.dib.bitmap.?);

    // The owner's content scale changes the frame's DPI without a new HWND.
    popup.setOwnerScale(popup.ownerScale() * 1.5);
    try testing.expect(!popup.frameReady(hwnd));
    popup.paint(hwnd);
    try testing.expect(popup.frameReady(hwnd));
    try testing.expectEqual(@as(f32, @floatFromInt(popup.canvasDpi())), popup.canvas.?.dpi);

    popup.discardTarget();
    try testing.expect(popup.canvas.?.target == .none);
    try testing.expect(popup.dib.dc == null and popup.dib.bitmap == null);
    try testing.expect(!popup.frameReady(hwnd));
    const callbacks = popup.callbacks;
    popup.callbacks = null;
    popup.paint(hwnd);
    try testing.expect(!popup.frameReady(hwnd));
    popup.callbacks = callbacks;
    popup.paint(hwnd);
    try testing.expect(popup.canvas.?.target == .dc);
    try testing.expect(popup.frameReady(hwnd));
    try context.expectPixels(&popup);
    try testing.expect(w32.IsWindowVisible_(hwnd) == 0);
    try testing.expect(ActivationFixture.noActivate(hwnd));
}

test "P7 software first paint failures cancel at 300ms and recover on reopening" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    const Failure = enum { end_draw, bitblt };
    for ([_]Failure{ .end_draw, .bitblt }) |failure| {
        var context: SoftwarePaintFixture = .{ .fail_end_draw = failure == .end_draw };
        var popup: Popup = .{};
        defer popup.destroy();
        try popup.create(hinstance, owner, factory, .{ .prefer_software = true }, .{
            .ctx = &context,
            .paint = SoftwarePaintFixture.paint,
        });
        popup.composition_requested = false;
        popup.test_fail_blit = failure == .bitblt;
        const hwnd = popup.hwnd.?;
        popup.show(SoftwarePaintFixture.rect);
        try testing.expect(context.dc_paints > 0);
        try testing.expect(popup.visible and popup.revealing);
        try testing.expect(popup.successful_frame == null and !popup.frameReady(hwnd));
        if (failure == .end_draw) {
            try testing.expect(popup.reuse_invalid and popup.canvas.?.warned);
        } else {
            // EndDraw produced pixels; the actual BitBlt rejects HDC(1).
            try testing.expect(!popup.canvas.?.warned);
            try context.expectPixels(&popup);
        }

        // Advance only the existing reveal deadline; no sleep or message pump.
        popup.reveal_started_ms -|= reveal_timeout_ms;
        popup.reveal(hwnd);
        try testing.expect(!popup.visible and !popup.revealing and !popup.repaint_retry);
        try testing.expect(w32.IsWindowVisible_(hwnd) == 0);
        try testing.expect(popup.successful_frame == null);

        context.fail_end_draw = false;
        popup.test_fail_blit = false;
        popup.discardTarget();
        popup.show(SoftwarePaintFixture.rect);
        try testing.expect(popup.revealing and popup.frameReady(hwnd));
        try context.expectPixels(&popup);
        popup.reveal(hwnd);
        try testing.expect(popup.visible and !popup.revealing and !popup.repaint_retry);
        try testing.expect(w32.IsWindowVisible_(hwnd) != 0);
        try testing.expect(popup.frameReady(hwnd) and ActivationFixture.noActivate(hwnd));
        popup.hide();
    }
}

test "P7 DComp precedes software painting and failed composition waits for a DC frame" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    // Populate the existing factory-owned device without changing the process
    // environment. Missing native DComp is a failure, not a skipped assertion.
    factory.popup_device = try dcomp.Device.init(factory.d2d);
    factory.popup_device_attempted = true;
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    for ([_]dcomp.Failure{ .none, .begin, .end, .commit }) |failure| {
        var context: SoftwarePaintFixture = .{};
        var popup: Popup = .{};
        defer popup.destroy();
        try popup.create(hinstance, owner, factory, .{ .prefer_software = true }, .{
            .ctx = &context,
            .paint = SoftwarePaintFixture.paint,
        });
        popup.composition_requested = true;
        popup.composition_failure = failure;
        // Successful composition must bypass even a failing legacy copy.
        popup.test_fail_blit = true;
        const hwnd = popup.hwnd.?;
        popup.show(SoftwarePaintFixture.rect);
        try testing.expect(popup.visible and popup.revealing);
        if (failure == .none) {
            try testing.expect(context.borrowed_paints > 0 and context.dc_paints == 0);
            try testing.expect(popup.dib.dc == null and popup.successful_frame == null);
            try testing.expect(popup.frameReady(hwnd));
            try testing.expectEqual(@as(isize, 6), popup.compositionStatus(hwnd) & 6);
        } else {
            try testing.expect(popup.composition_failed and context.dc_paints > 0);
            // Retain the failed composition resource domain until the fallback
            // copy actually succeeds; no successful/stale frame may reveal it.
            try testing.expect(popup.composition != null);
            try testing.expect(popup.successful_frame == null and !popup.frameReady(hwnd));
            try testing.expectEqual(@as(isize, 16), popup.compositionStatus(hwnd) & 22);
            try context.expectPixels(&popup);
            const borrowed_paints = context.borrowed_paints;
            popup.test_fail_blit = false;
            popup.reveal(hwnd);
            try testing.expectEqual(borrowed_paints, context.borrowed_paints);
            try testing.expect(popup.composition == null and popup.canvas.?.target == .dc);
            try testing.expectEqual(@as(isize, 20), popup.compositionStatus(hwnd) & 22);
            try context.expectPixels(&popup);
        }
        popup.reveal(hwnd);
        try testing.expect(popup.visible and !popup.revealing and popup.frameReady(hwnd));
        try testing.expect(ActivationFixture.noActivate(hwnd));
        popup.hide();
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

fn markLegacyFrame(self: *Popup, hwnd: w32.HWND, frame: ?OpenTiming.Frame) void {
    self.successful_frame = frame;
    if (self.open_timing) |*timing| {
        timing.painted = true;
        timing.frame = frame;
    }
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
    if (self.open_timing) |*timing| {
        timing.painted = true;
        timing.frame = .{ .width = frame.key.width, .height = frame.key.height, .dpi = frame.key.dpi };
    }
    return true;
}

fn failComposition(self: *Popup) void {
    self.reuse_invalid = true;
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
        WM_WINDOWPOSCHANGING => {
            // Before the window appears, whichever path shows it (`show`,
            // `SearchBar.showInactive`, an outside ShowWindow, the owner
            // restored): a popup that takes input can be clicked active.
            const pos: *const WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (pos.flags & w32.SWP_SHOWWINDOW != 0) self.syncActivationStyle(true);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_WINDOWPOSCHANGED => {
            // Hidden by any path: a reuse host refuses activation again.
            const pos: *const WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (pos.flags & SWP_HIDEWINDOW != 0) self.syncActivationStyle(false);
            // DefWindowProc sends WM_SIZE and WM_MOVE.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
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
            self.repaint();
            _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | w32.RDW_UPDATENOW);
            const current = livePopup(hwnd, cookie) orelse return 0;
            return current.compositionStatus(hwnd);
        },
        w32.WM_SIZE => {
            self.invalidate();
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.reuse_invalid = true;
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

test "caret blinking preserves the live UIA snapshot and queued Value action" {
    const testing = std.testing;
    // Snapshot ownership and COM lifetime checks only: no DLL load, HWND,
    // message dispatch, desktop interaction or externally configured timeout.
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
        .{ .id = 1, .name = "Palette", .role = .window, .patterns = .{ .window = true } },
        .{ .id = 2, .parent = 0, .name = "Search", .role = .edit, .patterns = .{ .value = true }, .read_only = false },
    };
    var popup: Popup = .{ .visible = true, .focused = true, .uia_layout_pending = false };
    defer popup.destroy();
    popup.input.field.w = 100;
    popup.input.caret_on = true;
    try popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    popup.uia_view.needs_publish = false;
    const snapshot_id = popup.uia_view.publisher.current.?.id;
    // IRawElementProviderSimple's first four SDK slots. Retain the actual COM
    // face so hiding/reopening cannot make the old pointer appear live again.
    const LifetimeTable = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    const retained = &popup.uia_view.publisher.current.?.nodes[1].faces[0];
    const abi: *const LifetimeTable = @ptrCast(@alignCast(retained.vtable));
    _ = abi.AddRef(retained);
    defer _ = abi.Release(retained);
    const unavailable: i32 = @bitCast(@as(u32, 0x80040201));
    var options: u32 = 0;
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(retained, &options));
    const action: uia.Action = .{
        .attachment = attachment,
        .snapshot_id = snapshot_id,
        .node_id = 2,
        .kind = .set_value,
        .value = &.{},
        .alloc = testing.allocator,
    };
    try testing.expect(popup.uia_view.publisher.accepts(action));
    for (0..4) |i| {
        try testing.expect(popup.blinkCaret(i * 500, 5000));
        try testing.expectEqual(i % 2 != 0, popup.input.caret_on);
        try testing.expect(popup.uia_view.publisher.accepts(action));
        try testing.expect(!popup.uia_layout_pending);
        try testing.expect(!popup.uia_view.needs_publish);
        try testing.expectEqual(snapshot_id, popup.uia_view.publisher.current.?.id);
        try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(retained, &options));
    }
    try testing.expect(!popup.blinkCaret(5000, 5000));
    try testing.expect(popup.input.caret_on);
    try testing.expect(popup.uia_view.publisher.accepts(action));
    popup.repaint();
    // Native keyboard focus is visual too. With text_input disabled this
    // exercises WM_SETFOCUS's handler without calling any desktop/caret API.
    popup.options.text_input = false;
    popup.onFocus(@ptrFromInt(1), true);
    try testing.expect(popup.uia_view.publisher.accepts(action));
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(retained, &options));

    // Model edits must still revoke index-based actions immediately.
    popup.invalidate();
    try testing.expect(!popup.uia_view.publisher.accepts(action));
    try testing.expect(popup.uia_layout_pending);
    try testing.expectEqual(unavailable, abi.ProviderOptions(retained, &options));
    try popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    const reopened_id = popup.uia_view.publisher.current.?.id;
    try testing.expect(reopened_id != snapshot_id);
    var reopened = action;
    reopened.snapshot_id = reopened_id;
    const before_hide = &popup.uia_view.publisher.current.?.nodes[1].faces[0];
    _ = abi.AddRef(before_hide);
    defer _ = abi.Release(before_hide);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(before_hide, &options));
    try testing.expect(popup.uia_view.publisher.accepts(reopened));
    try testing.expect(!popup.uia_view.publisher.accepts(action));
    popup.hide();
    try testing.expect(!popup.uia_view.publisher.accepts(reopened));
    try testing.expectEqual(unavailable, abi.ProviderOptions(before_hide, &options));
    try testing.expectEqual(unavailable, abi.ProviderOptions(retained, &options));
    try popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    var last = action;
    last.snapshot_id = popup.uia_view.publisher.current.?.id;
    const before_destroy = &popup.uia_view.publisher.current.?.nodes[1].faces[0];
    _ = abi.AddRef(before_destroy);
    defer _ = abi.Release(before_destroy);
    try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(before_destroy, &options));
    try testing.expectEqual(unavailable, abi.ProviderOptions(before_hide, &options));
    try testing.expect(last.snapshot_id != reopened_id);
    try testing.expect(!popup.uia_view.publisher.accepts(reopened));
    try testing.expect(popup.uia_view.publisher.accepts(last));
    try testing.expectEqual(unavailable, abi.ProviderOptions(retained, &options));
    popup.destroy();
    try testing.expect(!popup.uia_view.publisher.accepts(last));
    try testing.expectEqual(unavailable, abi.ProviderOptions(before_destroy, &options));
    try testing.expectEqual(unavailable, abi.ProviderOptions(retained, &options));
    var previous_id = last.snapshot_id;
    for (0..100) |_| {
        try popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
        const snapshot = popup.uia_view.publisher.current.?;
        try testing.expect(snapshot.id != previous_id);
        previous_id = snapshot.id;
        const provider = &snapshot.nodes[1].faces[0];
        _ = abi.AddRef(provider);
        try testing.expectEqual(@as(i32, 0), abi.ProviderOptions(provider, &options));
        popup.hide();
        try testing.expectEqual(unavailable, abi.ProviderOptions(provider, &options));
        _ = abi.Release(provider);
        try testing.expect(popup.uia_view.publisher.current == null);
    }
}

test "P4 opening placement avoids redundant size and position changes" {
    const rect: w32.RECT = .{ .left = 100, .top = 200, .right = 740, .bottom = 680 };
    try std.testing.expect(w32.SWP_NOMOVE | w32.SWP_NOSIZE == showPlacementFlags(rect, rect, true));
    try std.testing.expectEqual(w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE, showPlacementFlags(rect, rect, false));
    try std.testing.expectEqual(w32.SWP_NOSIZE, showPlacementFlags(rect, .{ .left = 101, .top = 202, .right = 741, .bottom = 682 }, true));
    try std.testing.expectEqual(w32.SWP_NOMOVE, showPlacementFlags(rect, .{ .left = 100, .top = 200, .right = 800, .bottom = 700 }, true));
    try std.testing.expectEqual(@as(u32, 0), showPlacementFlags(null, rect, true));
    try std.testing.expectEqual(w32.SWP_NOACTIVATE, showPlacementFlags(null, rect, false));
    // Geometry hints must not suppress z-order placement, activation or show.
    try std.testing.expect(showPlacementFlags(rect, rect, true) & w32.SWP_NOZORDER == 0);
}

/// An in-process UI Automation client for tests: `IUIAutomation`, on an MTA
/// thread of its own, asks one popup window for its element and subscribes,
/// as screen readers do, to the focus changed and ElementSelected events of
/// the whole desktop; it keeps the names of the senders that are elements of
/// this process. The test thread pumps messages meanwhile (`pump`): UI
/// Automation asks the popup for its provider (WM_GETOBJECT) and the queued
/// events are raised from that loop, as `App.onUia` does. Nothing is shown,
/// activated or drawn on the desktop.
pub const UiaTestClient = struct {
    pub const Kind = enum(u8) { focus, selected };
    pub const Event = struct {
        kind: Kind,
        name: [64]u16 = undefined,
        len: usize = 0,

        fn is(self: *const Event, kind: Kind, name: []const u8) bool {
            if (self.kind != kind or self.len != name.len) return false;
            for (self.name[0..self.len], name) |unit, byte| if (unit != byte) return false;
            return true;
        }
    };

    const HR = i32;
    const E_NOINTERFACE: HR = @bitCast(@as(u32, 0x80004002));
    const E_POINTER: HR = @bitCast(@as(u32, 0x80004003));
    const Handler = extern struct { vtable: *const anyopaque, client: *UiaTestClient };
    const Query = *const fn (*Handler, *const w32.GUID, *?*anyopaque) callconv(.winapi) HR;
    const Ref = *const fn (*Handler) callconv(.winapi) u32;
    const FocusTable = extern struct {
        QueryInterface: Query = queryFocus,
        AddRef: Ref = addRef,
        Release: Ref = release,
        HandleFocusChangedEvent: *const fn (*Handler, ?*anyopaque) callconv(.winapi) HR = handleFocus,
    };
    const EventTable = extern struct {
        QueryInterface: Query = queryEvent,
        AddRef: Ref = addRef,
        Release: Ref = release,
        HandleAutomationEvent: *const fn (*Handler, ?*anyopaque, i32) callconv(.winapi) HR = handleEvent,
    };
    const focus_table: FocusTable = .{};
    const event_table: EventTable = .{};

    // uiautomationclient.h
    const clsid_automation = w32.GUID.parse("{ff48dba4-60ef-4201-aa87-54103eef594e}");
    const iid_automation = w32.GUID.parse("{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}");
    const iid_focus_handler = w32.GUID.parse("{c270f6b5-5c69-4290-9745-7a7f97169468}");
    const iid_event_handler = w32.GUID.parse("{146c3c17-f12e-4e22-8c27-f894b9b79c69}");
    const iid_unknown = w32.GUID.parse("{00000000-0000-0000-c000-000000000046}");
    const iid_agile = w32.GUID.parse("{94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90}");
    /// IUIAutomation methods, after IUnknown's three.
    const slot_root_element = 5;
    const slot_element_from_handle = 6;
    const slot_add_event_handler = 32;
    const slot_add_focus_handler = 39;
    const slot_remove_all = 41;
    /// IUIAutomationElement::GetCurrentPropertyValue.
    const slot_property = 10;
    const element_selected_event = 20012;
    const tree_scope_subtree = 7;

    extern "oleaut32" fn VariantClear(variant: *uia.Variant) callconv(.winapi) HR;
    extern "oleaut32" fn SysStringLen(text: ?[*]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    hwnd: w32.HWND,
    thread: ?std.Thread = null,
    stop_event: ?std.os.windows.HANDLE = null,
    /// 0 starting, 1 subscribed, 2 failed, 3 unsubscribed.
    state: std.atomic.Value(u8) = .init(0),
    failure: std.atomic.Value(i32) = .init(0),
    refs: std.atomic.Value(u32) = .init(0),
    lock: std.os.windows.SRWLOCK = .{},
    events: [32]Event = undefined,
    count: usize = 0,
    focus_handler: Handler = undefined,
    event_handler: Handler = undefined,

    /// Subscribe to the events of the popup window `hwnd`; the caller pumps
    /// (`ready`). The client lives on the page allocator: UI Automation may
    /// release its handlers after they were removed (`destroy`).
    pub fn create(hwnd: w32.HWND) !*UiaTestClient {
        const self = try std.heap.page_allocator.create(UiaTestClient);
        self.* = .{ .hwnd = hwnd };
        self.focus_handler = .{ .vtable = &focus_table, .client = self };
        self.event_handler = .{ .vtable = &event_table, .client = self };
        self.stop_event = w32.CreateEventW(null, 1, 0, null) orelse {
            std.heap.page_allocator.destroy(self);
            return error.TestUnexpectedResult;
        };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            std.os.windows.CloseHandle(self.stop_event.?);
            std.heap.page_allocator.destroy(self);
            return err;
        };
        return self;
    }

    /// Wait, pumping messages for `app`, until the client subscribed.
    pub fn ready(self: *UiaTestClient, app: *App) !void {
        _ = pump(app, 10_000, self, started);
        if (self.state.load(.acquire) == 1) return;
        std.debug.print("UIA test client failed hr=0x{x}\n", .{@as(u32, @bitCast(self.failure.load(.acquire)))});
        return error.TestUnexpectedResult;
    }

    /// Unsubscribe and end the client thread, pumping (UI Automation may
    /// still ask the popup while it removes the handlers), then free it once
    /// UI Automation released its handlers.
    pub fn destroy(self: *UiaTestClient, app: *App) void {
        if (self.stop_event) |event| _ = w32.SetEvent(event);
        if (self.thread) |thread| {
            _ = pump(app, 10_000, self, unsubscribed);
            thread.join();
        }
        if (self.stop_event) |event| std.os.windows.CloseHandle(event);
        _ = pump(app, 1_000, self, released);
        // Still held by UI Automation: keep the memory rather than free it.
        if (self.refs.load(.acquire) == 0) std.heap.page_allocator.destroy(self);
    }

    /// Forget what was recorded so far.
    pub fn clear(self: *UiaTestClient) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.lock);
        self.count = 0;
    }

    /// Whether an event of `kind` came from an element named `name`.
    pub fn saw(self: *UiaTestClient, kind: Kind, name: []const u8) bool {
        return self.times(kind, name) > 0;
    }

    /// How many events of `kind` came from elements named `name`.
    pub fn times(self: *UiaTestClient, kind: Kind, name: []const u8) usize {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.lock);
        var found: usize = 0;
        for (self.events[0..self.count]) |*event| found += @intFromBool(event.is(kind, name));
        return found;
    }

    /// Pump messages for `app` until an event of `kind` came from an
    /// element named `name` (5 s at most).
    pub fn expect(self: *UiaTestClient, app: *App, kind: Kind, name: []const u8) !void {
        const Wanted = struct {
            client: *UiaTestClient,
            kind: Kind,
            name: []const u8,
            fn done(wanted: *const @This()) bool {
                return wanted.client.saw(wanted.kind, wanted.name);
            }
        };
        const wanted: Wanted = .{ .client = self, .kind = kind, .name = name };
        if (pump(app, 5_000, &wanted, Wanted.done)) return;
        std.debug.print("UIA test client: no {t} event from \"{s}\"; {d} recorded\n", .{ kind, name, self.count });
        return error.TestExpectedEqual;
    }

    /// Pump messages for `timeout_ms` (events already queued arrive).
    pub fn settle(self: *UiaTestClient, app: *App, timeout_ms: u64) void {
        _ = pump(app, timeout_ms, self, never);
    }

    /// Pump messages until `done(context)` or `timeout_ms`: sent messages
    /// (WM_GETOBJECT) are answered, and the UI Automation queue of `app` is
    /// dispatched to its popups as `App.onUia` does.
    pub fn pump(app: *App, timeout_ms: u64, context: anytype, comptime done: fn (@TypeOf(context)) bool) bool {
        const deadline = GetTickCount64() + timeout_ms;
        while (true) {
            var msg: w32.MSG = undefined;
            while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                if (msg.message == uia.wake_message) {
                    const queue = app.uia_queue orelse continue;
                    while (queue.pop()) |value| {
                        var action = value;
                        defer action.deinit();
                        _ = app.uia_popups.dispatch(app, &action);
                    }
                    continue;
                }
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
            if (done(context)) return true;
            if (GetTickCount64() >= deadline) return false;
            _ = w32.MsgWaitForMultipleObjectsEx(0, null, 10, w32.QS_ALLINPUT, w32.MWMO_INPUTAVAILABLE);
        }
    }

    fn started(self: *UiaTestClient) bool {
        return self.state.load(.acquire) != 0;
    }
    fn unsubscribed(self: *UiaTestClient) bool {
        return self.state.load(.acquire) >= 2;
    }
    fn released(self: *UiaTestClient) bool {
        return self.refs.load(.acquire) == 0;
    }
    fn never(_: *UiaTestClient) bool {
        return false;
    }

    fn fail(self: *UiaTestClient, hr: HR) void {
        self.failure.store(hr, .release);
        self.state.store(2, .release);
    }

    fn run(self: *UiaTestClient) void {
        const initialized = w32.CoInitializeEx(null, 0); // COINIT_MULTITHREADED
        if (initialized < 0) return self.fail(initialized);
        defer w32.CoUninitialize();
        var automation: ?*anyopaque = null;
        var hr = w32.CoCreateInstance(&clsid_automation, null, w32.CLSCTX_INPROC_SERVER, &iid_automation, &automation);
        const client = automation orelse return self.fail(if (hr < 0) hr else E_POINTER);
        defer _ = unknownRelease(client);
        var root: ?*anyopaque = null;
        hr = method(client, slot_element_from_handle, *const fn (*anyopaque, w32.HWND, *?*anyopaque) callconv(.winapi) HR)(client, self.hwnd, &root);
        const element = root orelse return self.fail(if (hr < 0) hr else E_POINTER);
        defer _ = unknownRelease(element);
        var desktop_root: ?*anyopaque = null;
        hr = method(client, slot_root_element, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HR)(client, &desktop_root);
        const desktop = desktop_root orelse return self.fail(if (hr < 0) hr else E_POINTER);
        defer _ = unknownRelease(desktop);
        hr = method(client, slot_add_focus_handler, *const fn (*anyopaque, ?*anyopaque, *Handler) callconv(.winapi) HR)(client, null, &self.focus_handler);
        if (hr < 0) return self.fail(hr);
        hr = method(client, slot_add_event_handler, *const fn (*anyopaque, i32, *anyopaque, i32, ?*anyopaque, *Handler) callconv(.winapi) HR)(client, element_selected_event, desktop, tree_scope_subtree, null, &self.event_handler);
        if (hr < 0) {
            _ = method(client, slot_remove_all, *const fn (*anyopaque) callconv(.winapi) HR)(client);
            return self.fail(hr);
        }
        self.state.store(1, .release);
        _ = w32.WaitForSingleObject(self.stop_event.?, 0xFFFFFFFF);
        _ = method(client, slot_remove_all, *const fn (*anyopaque) callconv(.winapi) HR)(client);
        self.state.store(3, .release);
    }

    fn method(object: *anyopaque, comptime slot: usize, comptime F: type) F {
        const vtable: *const [*]const *const anyopaque = @ptrCast(@alignCast(object));
        return @ptrCast(vtable.*[slot]);
    }
    fn unknownRelease(object: *anyopaque) u32 {
        return method(object, 2, *const fn (*anyopaque) callconv(.winapi) u32)(object);
    }
    fn property(element: *anyopaque, id: i32, out: *uia.Variant) HR {
        return method(element, slot_property, *const fn (*anyopaque, i32, *uia.Variant) callconv(.winapi) HR)(element, id, out);
    }

    fn queryFocus(handler: *Handler, iid: *const w32.GUID, out: *?*anyopaque) callconv(.winapi) HR {
        return query(handler, iid, &iid_focus_handler, out);
    }
    fn queryEvent(handler: *Handler, iid: *const w32.GUID, out: *?*anyopaque) callconv(.winapi) HR {
        return query(handler, iid, &iid_event_handler, out);
    }
    fn query(handler: *Handler, iid: *const w32.GUID, own: *const w32.GUID, out: *?*anyopaque) HR {
        if (std.meta.eql(iid.*, own.*) or std.meta.eql(iid.*, iid_unknown) or std.meta.eql(iid.*, iid_agile)) {
            _ = addRef(handler);
            out.* = handler;
            return 0;
        }
        out.* = null;
        return E_NOINTERFACE;
    }
    fn addRef(handler: *Handler) callconv(.winapi) u32 {
        return handler.client.refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(handler: *Handler) callconv(.winapi) u32 {
        return handler.client.refs.fetchSub(1, .acq_rel) -% 1;
    }
    fn handleFocus(handler: *Handler, sender: ?*anyopaque) callconv(.winapi) HR {
        handler.client.record(.focus, sender);
        return 0;
    }
    fn handleEvent(handler: *Handler, sender: ?*anyopaque, event_id: i32) callconv(.winapi) HR {
        if (event_id == element_selected_event) handler.client.record(.selected, sender);
        return 0;
    }

    /// On a UI Automation thread: keep the sender's name if it is an
    /// element of this process.
    fn record(self: *UiaTestClient, kind: Kind, sender: ?*anyopaque) void {
        const element = sender orelse return;
        var pid: uia.Variant = .{};
        if (property(element, 30002, &pid) < 0) return;
        defer _ = VariantClear(&pid);
        if (pid.tag != 3 or @as(u32, @bitCast(@as(i32, @truncate(pid.data.integer)))) != GetCurrentProcessId()) return;
        var name: uia.Variant = .{};
        if (property(element, 30005, &name) < 0) return;
        defer _ = VariantClear(&name);
        var event: Event = .{ .kind = kind };
        if (name.tag == 8) if (name.data.pointer) |pointer| {
            const text: [*]const u16 = @ptrCast(@alignCast(pointer));
            event.len = @min(SysStringLen(text), event.name.len);
            @memcpy(event.name[0..event.len], text[0..event.len]);
        };
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.lock);
        if (self.count < self.events.len) {
            self.events[self.count] = event;
            self.count += 1;
        }
    }

    /// What `pump` and popups need of an App: the real UI Automation API and
    /// queue (on a message-only window of the test thread), its popup
    /// registry, and one window the attachment of the popups resolves to.
    pub const AppFixture = struct {
        app: App,
        window: @import("../Window.zig"),
        windows: [1]*@import("../Window.zig"),
        queue_hwnd: w32.HWND,

        pub fn init(self: *AppFixture, attachment: @import("../../../gx/ui_ref.zig").Attachment) !void {
            const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
            self.queue_hwnd = w32.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.TestWindowFailed;
            errdefer _ = w32.DestroyWindow(self.queue_hwnd);
            self.app = .{
                .core_app = undefined,
                .config = undefined,
                .hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed,
                .default_command_arena = undefined,
                .ui_ids = .{ .epoch = attachment.owner.epoch },
            };
            const api = try uia.Api.load(std.heap.page_allocator);
            errdefer api.release();
            self.app.uia_api = api;
            self.app.uia_queue = try uia.Queue.create(std.heap.page_allocator, self.queue_hwnd);
            self.window = .{ .app = &self.app, .ui_reference = attachment.object, .ui_attachment = attachment };
            self.windows = .{&self.window};
            self.app.windows = .{ .items = &self.windows, .capacity = self.windows.len };
        }

        pub fn deinit(self: *AppFixture) void {
            self.app.uia_popups.deinit();
            if (self.app.uia_queue) |queue| queue.release();
            if (self.app.uia_api) |api| api.release();
            _ = w32.DestroyWindow(self.queue_hwnd);
        }
    };
};

/// A popup widget publishing through the real `PopupBridge`: a check box and
/// a button that take the focus (`focus` names one by token), and a list the
/// keyboard selects in while the focus stays (`selected`).
const ClientWidget = struct {
    attachment: @import("../../../gx/ui_ref.zig").Attachment,
    focus: u64 = 10,
    selected: u64 = 30,
    label: []const u8 = "Remember",

    fn paint(_: *anyopaque, _: *Popup, _: *d2d.Canvas) void {}
    fn live(_: *anyopaque) bool {
        return true;
    }
    fn action(_: *anyopaque, _: u64, _: *const uia.Action) bool {
        return true;
    }
    fn build(context: *anyopaque, popup: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
        const self: *ClientWidget = @ptrCast(@alignCast(context));
        const nodes = [_]uia.NodeSpec{
            .{ .id = 1, .name = "Widget", .role = .window, .patterns = .{ .window = true } },
            .{ .id = 2, .parent = 0, .name = self.label, .role = .checkbox, .patterns = .{ .toggle = true }, .focusable = true, .focused = self.focus == 10 },
            .{ .id = 3, .parent = 0, .name = "OK", .role = .button, .patterns = .{ .invoke = true }, .focusable = true, .focused = self.focus == 20 },
            .{ .id = 4, .parent = 0, .name = "Results", .role = .list, .patterns = .{ .selection = true }, .selection_required = true },
            .{ .id = 5, .parent = 3, .name = "Split Left", .role = .list_item, .patterns = .{ .selection_item = true }, .selected = self.selected == 30 },
            .{ .id = 6, .parent = 3, .name = "Split Right", .role = .list_item, .patterns = .{ .selection_item = true }, .selected = self.selected == 31 },
        };
        // A publication that moved the selection of the shown list raises
        // its ElementSelected event (`PopupBridge.trackSelection`).
        try bridge.publish(api, queue, self.attachment, popup.hwnd.?, &nodes, &.{ 0, 10, 20, 29, 30, 31 }, .{ .context = self, .is_live = live, .action = action });
    }
};

test "UIA a real UI Automation client hears a popup's focus moves and selections" {
    // IUIAutomation in this process subscribes to focus changed events and to
    // the ElementSelected events under a popup window that is never shown.
    // Tab moves the focus within the published snapshot, a model change that
    // also moves it publishes a new one, and the keyboard selects in a list
    // while the focus stays: each is heard once, from the element it is about.
    const attachment: @import("../../../gx/ui_ref.zig").Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    var fixture: UiaTestClient.AppFixture = undefined;
    try fixture.init(attachment);
    defer fixture.deinit();
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    const factory = try d2d.Factory.create(std.testing.allocator);
    defer factory.destroy();
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    var widget: ClientWidget = .{ .attachment = attachment };
    var popup: Popup = .{};
    defer popup.destroy();
    try popup.create(hinstance, owner, factory, .{}, .{
        .ctx = &widget,
        .paint = ClientWidget.paint,
        .uia_source = .{ .app = &fixture.app, .build = ClientWidget.build, .is_live = ClientWidget.live, .action = ClientWidget.action },
    });
    // Never shown: a hidden window that counts as shown.
    popup.visible = true;
    const client = try UiaTestClient.create(popup.hwnd.?);
    defer client.destroy(&fixture.app);
    try client.ready(&fixture.app);
    // What came with the first publication is not looked at.
    client.settle(&fixture.app, 200);
    client.clear();
    // Tab: the focus moves within the snapshot.
    widget.focus = 20;
    popup.focusMoved();
    try client.expect(&fixture.app, .focus, "OK");
    // A model change that moves the focus too: a new snapshot reports it.
    client.clear();
    widget.focus = 10;
    widget.label = "Remember me";
    popup.invalidate();
    popup.paint(popup.hwnd.?);
    try client.expect(&fixture.app, .focus, "Remember me");
    // The keyboard selects another result while the focus stays.
    client.clear();
    widget.selected = 31;
    popup.invalidate();
    popup.paint(popup.hwnd.?);
    try client.expect(&fixture.app, .selected, "Split Right");
    // Published again unchanged: neither is announced a second time.
    popup.invalidate();
    popup.paint(popup.hwnd.?);
    client.settle(&fixture.app, 100);
    try std.testing.expectEqual(@as(usize, 1), client.times(.selected, "Split Right"));
    try std.testing.expect(!client.saw(.focus, "Remember me"));
    popup.visible = false;
}

/// The faces of a published element as a UI Automation client holds them:
/// IRawElementProviderSimple (`faces[0]`) and, on the root, the fragment
/// root (`faces[2]`).
const FaceProbe = struct {
    const Simple = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
        GetPatternProvider: *const fn (*uia.Face, i32, *?*uia.Face) callconv(.winapi) i32,
        GetPropertyValue: *const fn (*uia.Face, i32, *uia.Variant) callconv(.winapi) i32,
    };
    const Root = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ElementProviderFromPoint: *const fn (*uia.Face, f64, f64, *?*uia.Face) callconv(.winapi) i32,
        GetFocus: *const fn (*uia.Face, *?*uia.Face) callconv(.winapi) i32,
    };
    /// UIA_E_ELEMENTNOTAVAILABLE: the element was revoked.
    const unavailable: i32 = @bitCast(@as(u32, 0x80040201));

    fn simple(face: *uia.Face) *const Simple {
        return @ptrCast(@alignCast(face.vtable));
    }
    fn retain(face: *uia.Face) void {
        _ = simple(face).AddRef(face);
    }
    fn release(face: *uia.Face) void {
        _ = simple(face).Release(face);
    }
    /// ProviderOptions: S_OK while the element is usable.
    fn options(face: *uia.Face) i32 {
        var value: u32 = 0;
        return simple(face).ProviderOptions(face, &value);
    }
    /// UIA_HasKeyboardFocusPropertyId.
    fn hasFocus(face: *uia.Face) !bool {
        var value: uia.Variant = .{};
        try std.testing.expectEqual(@as(i32, 0), simple(face).GetPropertyValue(face, 30008, &value));
        try std.testing.expectEqual(@as(u16, 11), value.tag);
        return value.data.integer != 0;
    }
    /// The element the root reports focused, released again.
    fn rootFocus(root: *uia.Face) !?*uia.Face {
        const table: *const Root = @ptrCast(@alignCast(root.vtable));
        var focused: ?*uia.Face = null;
        try std.testing.expectEqual(@as(i32, 0), table.GetFocus(root, &focused));
        const face = focused orelse return null;
        _ = table.Release(face);
        return face;
    }
};

/// A popup widget publishing through the real `PopupBridge`: a window with
/// two focusable elements (tokens 10 and 20), the focus on `focus`.
const FocusWidget = struct {
    focus: u64 = 10,
    attachment: @import("../../../gx/ui_ref.zig").Attachment,

    fn paint(_: *anyopaque, _: *Popup, _: *d2d.Canvas) void {}
    fn live(_: *anyopaque) bool {
        return true;
    }
    fn action(_: *anyopaque, _: u64, _: *const uia.Action) bool {
        return true;
    }
    fn build(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
        const self: *FocusWidget = @ptrCast(@alignCast(context));
        const nodes = [_]uia.NodeSpec{
            .{ .id = 1, .name = "Dialog", .role = .window, .patterns = .{ .window = true } },
            .{ .id = 2, .parent = 0, .name = "Remember", .role = .checkbox, .patterns = .{ .toggle = true }, .focusable = true, .focused = self.focus == 10 },
            .{ .id = 3, .parent = 0, .name = "OK", .role = .button, .patterns = .{ .invoke = true }, .focusable = true, .focused = self.focus == 20 },
        };
        try bridge.publish(api, queue, self.attachment, @ptrFromInt(1), &nodes, &.{ 0, 10, 20 }, .{ .context = self, .is_live = FocusWidget.live, .action = FocusWidget.action });
    }
};

test "UIA a focus move keeps the popup's elements and reports the new focus" {
    // The real provider faces: HasKeyboardFocus of the element that had the
    // focus and of the one that has it now, and the root's GetFocus. Both
    // elements stay usable. No HWND, desktop or UIAutomationCore is involved.
    const testing = std.testing;
    var api: uia.Api = undefined;
    api.count = .init(1);
    api.event = null;
    api.notification = null;
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    var app: App = undefined;
    app.uia_api = &api;
    app.uia_queue = &queue;
    app.drop_closing = false;
    app.uia_popups = .{};
    var widget: FocusWidget = .{ .attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    } };
    var popup: Popup = .{ .visible = true, .uia_layout_pending = false, .callbacks = .{
        .ctx = &widget,
        .paint = FocusWidget.paint,
        .uia_source = .{ .app = &app, .build = FocusWidget.build, .is_live = FocusWidget.live, .action = FocusWidget.action },
    } };
    defer popup.destroy();
    popup.uiaRefresh();
    const snapshot = popup.uia_view.publisher.current.?;
    const remember = &snapshot.nodes[1].faces[0];
    const ok = &snapshot.nodes[2].faces[0];
    const root = &snapshot.nodes[0].faces[2];
    for ([_]*uia.Face{ remember, ok, root }) |face| FaceProbe.retain(face);
    defer for ([_]*uia.Face{ remember, ok, root }) |face| FaceProbe.release(face);
    try testing.expect(try FaceProbe.hasFocus(remember));
    try testing.expect(!try FaceProbe.hasFocus(ok));
    try testing.expect((try FaceProbe.rootFocus(root)).?.node == remember.node);
    // The focus moves on (Tab, an arrow key, WM_SETFOCUS): nothing else changed.
    widget.focus = 20;
    popup.onFocus(@ptrFromInt(1), true);
    try testing.expectEqual(@as(i32, 0), FaceProbe.options(remember));
    try testing.expectEqual(@as(i32, 0), FaceProbe.options(ok));
    try testing.expect(!try FaceProbe.hasFocus(remember));
    try testing.expect(try FaceProbe.hasFocus(ok));
    try testing.expect((try FaceProbe.rootFocus(root)).?.node == ok.node);
    try testing.expectEqual(snapshot, popup.uia_view.publisher.current.?);
    // And away from both elements (the popup lost the focus).
    widget.focus = 0;
    popup.onFocus(@ptrFromInt(1), false);
    try testing.expectEqual(@as(i32, 0), FaceProbe.options(ok));
    try testing.expect(!try FaceProbe.hasFocus(remember));
    try testing.expect(!try FaceProbe.hasFocus(ok));
    try testing.expect(try FaceProbe.rootFocus(root) == null);
}

/// A widget whose accessible model comes from its last paint, as the hit
/// rectangles of the settings do: two of the three rows show, from `scroll`
/// on. The tokens are positions and the keys the rows (`publishKeyed`); a
/// paint that laid the rows out otherwise than the published model revokes
/// it (`uiaLayoutChanged`), as `Settings.checkUiaHits` does.
const PaintWidget = struct {
    attachment: @import("../../../gx/ui_ref.zig").Attachment,
    /// The row with the focus, and the first row shown.
    focus: usize = 0,
    scroll: usize = 0,
    /// The first row the last paint laid out, and the one the published
    /// model shows.
    laid: usize = 0,
    published: ?usize = null,

    const row_names = [_][]const u8{ "Font", "Theme", "Cursor" };

    fn paint(context: *anyopaque, popup: *Popup, _: *d2d.Canvas) void {
        const self: *PaintWidget = @ptrCast(@alignCast(context));
        self.laid = self.scroll;
        const published = self.published orelse return;
        if (published == self.laid) return;
        self.published = null;
        popup.uiaLayoutChanged();
    }
    fn live(_: *anyopaque) bool {
        return true;
    }
    fn action(_: *anyopaque, _: u64, _: *const uia.Action) bool {
        return true;
    }
    fn build(context: *anyopaque, popup: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
        const self: *PaintWidget = @ptrCast(@alignCast(context));
        var nodes: [3]uia.NodeSpec = undefined;
        var keys: [3]u64 = @splat(0);
        nodes[0] = .{ .id = 1, .name = "Settings", .role = .window, .patterns = .{ .window = true } };
        for (1..3) |slot| {
            const row = self.laid + slot - 1;
            nodes[slot] = .{ .id = @intCast(slot + 1), .parent = 0, .name = row_names[row], .role = .checkbox, .patterns = .{ .toggle = true }, .focusable = true, .focused = self.focus == row };
            keys[slot] = 100 + @as(u64, @intCast(row));
        }
        const published = bridge.publisher.current;
        try bridge.publishKeyed(api, queue, self.attachment, popup.hwnd.?, &nodes, &.{ 0, 1, 2 }, &keys, .{ .context = self, .is_live = PaintWidget.live, .action = PaintWidget.action });
        if (bridge.publisher.current != published) self.published = self.laid;
    }
};

test "UIA a real UI Automation client hears a focus move at the paint that shows it" {
    // The settings move the keyboard focus with the arrow keys and report it
    // after the paint that scrolls it into view (`focusMovedAtPaint`). A move
    // that kept the layout is heard in place and the elements the client
    // holds stay usable; one that scrolled revokes them, and the publication
    // of the new layout is heard from the element that has the focus now.
    const attachment: @import("../../../gx/ui_ref.zig").Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    var fixture: UiaTestClient.AppFixture = undefined;
    try fixture.init(attachment);
    defer fixture.deinit();
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    const factory = try d2d.Factory.create(std.testing.allocator);
    defer factory.destroy();
    const owner = try ActivationFixture.owner();
    defer _ = w32.DestroyWindow(owner);
    var widget: PaintWidget = .{ .attachment = attachment };
    var popup: Popup = .{};
    defer popup.destroy();
    try popup.create(hinstance, owner, factory, .{}, .{
        .ctx = &widget,
        .paint = PaintWidget.paint,
        .uia_source = .{ .app = &fixture.app, .build = PaintWidget.build, .is_live = PaintWidget.live, .action = PaintWidget.action },
    });
    // Never shown: a hidden window that counts as shown.
    popup.visible = true;
    const client = try UiaTestClient.create(popup.hwnd.?);
    defer client.destroy(&fixture.app);
    try client.ready(&fixture.app);
    client.settle(&fixture.app, 200);
    client.clear();
    const first = popup.uia_view.publisher.current.?;
    const font = &first.nodes[1].faces[0];
    FaceProbe.retain(font);
    defer FaceProbe.release(font);
    // Down to the next row, shown already: reported in place.
    widget.focus = 1;
    popup.focusMovedAtPaint();
    popup.paint(popup.hwnd.?);
    try client.expect(&fixture.app, .focus, "Theme");
    try std.testing.expectEqual(first, popup.uia_view.publisher.current.?);
    try std.testing.expectEqual(@as(i32, 0), FaceProbe.options(font));
    try std.testing.expect(!try FaceProbe.hasFocus(font));
    // Down to the row below the view: the paint scrolls, the elements the
    // client holds would name other rows now, and the new layout is
    // published with the focus.
    client.clear();
    widget.focus = 2;
    widget.scroll = 1;
    popup.focusMovedAtPaint();
    popup.paint(popup.hwnd.?);
    try client.expect(&fixture.app, .focus, "Cursor");
    try std.testing.expect(popup.uia_view.publisher.current.? != first);
    try std.testing.expectEqual(FaceProbe.unavailable, FaceProbe.options(font));
    popup.visible = false;
}

test "opening ready waits for synchronous show and a current-size DPI frame" {
    const expected: OpenTiming.Frame = .{ .width = 640, .height = 480, .dpi = 144 };
    var timing: OpenTiming = .{
        .kind = .palette,
        .start = .{ .nanoseconds = 0 },
        .last = .{ .nanoseconds = 0 },
        .showing = true,
        .painted = true,
        .frame = expected,
    };
    timing.readyAt(.{ .nanoseconds = 1000 }, expected);
    try std.testing.expect(timing.ready == null);
    timing.showing = false;
    timing.readyAt(.{ .nanoseconds = 2000 }, expected);
    try std.testing.expectEqual(@as(i96, 2000), timing.ready.?.nanoseconds);
    timing.readyAt(.{ .nanoseconds = 9000 }, expected);
    try std.testing.expectEqual(@as(i96, 2000), timing.ready.?.nanoseconds);

    // The synchronous frame failed. Later successful drawing, not the failed
    // show return or an old-size/old-DPI bitmap, establishes the ready endpoint.
    timing.ready = null;
    timing.frame = null;
    timing.readyAt(.{ .nanoseconds = 10_000 }, expected);
    try std.testing.expect(timing.ready == null);
    timing.frame = .{ .width = 640, .height = 480, .dpi = 96 };
    timing.readyAt(.{ .nanoseconds = 11_000 }, expected);
    try std.testing.expect(timing.ready == null);
    timing.frame = .{ .width = 800, .height = 480, .dpi = 144 };
    timing.readyAt(.{ .nanoseconds = 12_000 }, expected);
    try std.testing.expect(timing.ready == null);
    timing.frame = expected;
    timing.readyAt(.{ .nanoseconds = 13_000 }, expected);
    try std.testing.expectEqual(@as(i96, 13_000), timing.ready.?.nanoseconds);
}

test "opening emits seven metrics once on reveal and none when cancelled" {
    const Capture = struct {
        var length: usize = 0;
        var names: [32][]const u8 = undefined;
        var values: [32]u64 = undefined;
        pub fn record(name: []const u8, us: u64) void {
            names[length] = name;
            values[length] = us;
            length += 1;
        }
    };
    for (std.meta.tags(OpenTiming.Kind)) |kind| {
        const opening: OpenTiming = .{
            .kind = kind,
            .start = .{ .nanoseconds = 1000 },
            .last = .{ .nanoseconds = 1000 },
            .painted = true,
            .ready = .{ .nanoseconds = 151_000 },
        };
        Capture.length = 0;
        var popup: Popup = .{ .open_timing = opening };
        popup.finishOpenTimingAt(Capture, .{ .nanoseconds = 401_000 });
        popup.finishOpenTimingAt(Capture, .{ .nanoseconds = 901_000 });
        try std.testing.expect(popup.open_timing == null);
        try std.testing.expectEqual(@as(usize, 7), Capture.length);
        inline for (.{ "prepare", "create", "layout", "raster", "show", "ready", "total" }, 0..) |phase, i| {
            var buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "{s}.open.{s}", .{ @tagName(kind), phase });
            try std.testing.expectEqualStrings(name, Capture.names[i]);
        }
        try std.testing.expectEqual(@as(u64, 150), Capture.values[5]);
        try std.testing.expectEqual(@as(u64, 400), Capture.values[6]);

        Capture.length = 0;
        popup.open_timing = opening;
        popup.hide(); // Escape/dismiss cancels even an already-ready opening.
        popup.finishOpenTimingAt(Capture, .{ .nanoseconds = 401_000 });
        popup.open_timing = opening;
        popup.destroy();
        popup.finishOpenTimingAt(Capture, .{ .nanoseconds = 401_000 });
        popup.open_timing = opening;
        popup.open_timing.?.painted = false;
        popup.finishOpenTimingAt(Capture, .{ .nanoseconds = 401_000 });
        popup.open_timing = opening;
        popup.open_timing.?.ready = null;
        popup.finishOpenTimingAt(Capture, .{ .nanoseconds = 401_000 });
        try std.testing.expectEqual(@as(usize, 0), Capture.length);
        try std.testing.expect(popup.open_timing == null);
    }
}

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
