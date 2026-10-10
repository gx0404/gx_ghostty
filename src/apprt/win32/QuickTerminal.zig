// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Quick Terminal: a borderless, topmost popup window with one terminal
//! that slides in from an edge of a monitor (`quick-terminal-position`,
//! `quick-terminal-screen`) and out again. Owned by App, separate from the
//! normal windows list.
//!
//! Showing (`toggle`, `present`): the window is placed on its monitor and
//! shown there cloaked, so it takes that monitor's DPI and its terminal
//! presents a frame before anything is seen (at most
//! `Window.first_frame_timeout_ms`). It takes the keyboard at once, so
//! what is typed right after the hotkey goes to the terminal. Then it
//! slides in from beyond its edge (centered: from a short way above).
//!
//! Slides follow the time, one step per composed frame (`anim` clock): in
//! with `motion.enter` (decelerating), out with `motion.exit`
//! (accelerating); toggled midway, a slide turns around where it is
//! (`Slide.from`). While the window reaches onto another monitor or the
//! taskbar, a window region clips it to the work area. Without animations
//! (`anim.enabled`, `quick-terminal-animation-duration = 0`) it appears
//! and goes at once.
//!
//! Hiding: hidden by the user while it has the keyboard, the quick
//! terminal hands the keyboard back to the window that had it before as
//! the slide starts. Its terminal stops rendering and the terminal's
//! popups (find bar, scrollbar, link preview) hide then too; the window's
//! other popups hide with it. With `quick-terminal-autohide` it slides out
//! when another window is activated, except its own popups and dialogs.
//!
//! Sizes (`quick-terminal-size`, `sizeFor`) are DIPs of the target
//! monitor: `px` values and the defaults follow its DPI, percentages its
//! work area. Along an edge, a window shorter than the edge is centered on
//! it.
const QuickTerminal = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const Popup = @import("ui/Popup.zig");
const ResizeOverlay = @import("ui/ResizeOverlay.zig");
const anim = @import("ui/anim.zig");
const motion = anim.motion;

const log = std.log.scoped(.win32_quick_terminal);

const Position = configpkg.Config.QuickTerminalPosition;
const SizeConfig = configpkg.Config.QuickTerminalSize;

/// Timer 3 of the app's message window drove the slides before the `anim`
/// clock did; nothing sets it now. Kept for `App`'s WM_TIMER dispatch
/// until that goes.
pub const ANIM_TIMER_ID: usize = 3;

/// The default size in DIPs along the docked axis (`sizeFor`), and of a
/// centered window.
const default_short_dip: f32 = 400;
const default_long_dip: f32 = 800;

/// How far above its place a centered window starts its slide.
const center_slide_dip: f32 = 48;

/// The longest slide, whatever `quick-terminal-animation-duration` says.
const max_duration_s: f64 = 5;

/// A frame placed now shows at the next composition: slides are sampled
/// this far ahead, so the first step after a start already moves.
const frame_lead_ns: u64 = std.time.ns_per_s / 60;

const first_frame_timeout_ns: u64 = Window.first_frame_timeout_ms * std.time.ns_per_ms;

const empty_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

app: *App,
window: *Window,

/// Whether the quick terminal is on screen or on its way in, which is what
/// `toggle` reverses.
visible: bool = false,

/// Whether the quick terminal places its window itself right now: shown
/// cloaked while it waits for its terminal's frame, or sliding.
animating: bool = false,

phase: Phase = .hidden,
slide: Slide = .{ .opening = true, .tween = .{ .start_ns = 0, .duration_ns = 0 } },

/// When the wait for the terminal's frame started (`anim.now`).
waiting_since_ns: u64 = 0,

/// Where the window goes (screen pixels, `relayout`): in place, and where
/// its slides start and end; and the work area of its monitor.
target_rect: w32.RECT = empty_rect,
hidden_rect: w32.RECT = empty_rect,
work_rect: w32.RECT = empty_rect,

/// Whether slides need a window region: beyond its edge there is another
/// monitor or the taskbar.
clip_slides: bool = false,

/// The window region set (window coordinates), null for none.
clip: ?w32.RECT = null,

/// Whether the window has rounded corners (centered), null before set.
round_corners: ?bool = null,

/// The window that was active before the quick terminal came in, which
/// gets the keyboard back when it goes.
previous_foreground: ?w32.HWND = null,

/// Close the window once it is hidden (its last tab closed).
close_when_hidden: bool = false,

animator: anim.Animator = .{ .tick = animTick },

const Phase = enum {
    /// Off screen (SW_HIDE).
    hidden,
    /// Shown, cloaked and in place until its terminal presented a frame.
    waiting,
    /// Moving in or out (`slide`).
    sliding,
    /// In place.
    shown,
};

/// Why the quick terminal hides.
const HideReason = enum {
    /// The user toggled it.
    toggle,
    /// Another window took the activation (`quick-terminal-autohide`).
    focus_lost,
    /// Its last tab closed.
    closed,
};

pub fn init(app: *App) !*QuickTerminal {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(QuickTerminal);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .window = undefined,
    };

    // Create the window in quick terminal mode.
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app, .{ .is_quick_terminal = true });
    errdefer window.deinit();
    self.window = window;

    if (window.hwnd) |hwnd| {
        // Erasing the background must not paint over the terminal.
        const style = w32.GetWindowLongPtrW(hwnd, w32.GWL_STYLE);
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWL_STYLE, style | @as(isize, w32.WS_CLIPCHILDREN));
    }

    // In place before the terminal starts, which takes the size it finds.
    self.relayout();
    _ = try window.addTab();
    // Nothing to render until it shows.
    window.setActiveTabVisible(false);

    return self;
}

pub fn deinit(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    anim.stop(&self.animator);

    // Prevent onDestroy from calling onWindowDestroyed (we're cleaning up ourselves).
    app.quick_terminal = null;

    // Clean up the window.
    self.window.close();
    alloc.destroy(self.window);
    alloc.destroy(self);
}

/// Slide the quick terminal in, or out when it is on screen or on its way
/// in (`toggle_quick_terminal`).
pub fn toggle(self: *QuickTerminal) void {
    if (self.visible) self.hide(.toggle) else self.show();
}

/// Bring the quick terminal in and give it the keyboard, also when it is
/// sliding out (`present_terminal` for its terminal).
pub fn present(self: *QuickTerminal) void {
    self.show();
}

/// See `ANIM_TIMER_ID`.
pub fn onAnimationTick(self: *QuickTerminal) void {
    _ = self;
}

/// Called when the quick terminal window is deactivated (WM_ACTIVATE);
/// `next_active` is the window that is activated instead, if Windows names
/// it. Its own popups and dialogs do not count.
pub fn onFocusLost(self: *QuickTerminal, next_active: ?w32.HWND) void {
    if (!self.app.config.@"quick-terminal-autohide") return;
    if (next_active) |next| {
        if (self.ownsWindow(next)) return;
    }
    self.hide(.focus_lost);
}

/// Called when another application is activated (WM_ACTIVATEAPP), which
/// the quick terminal window hears even while one of its popups was the
/// active window.
pub fn onAppDeactivated(self: *QuickTerminal) void {
    if (!self.app.config.@"quick-terminal-autohide") return;
    self.hide(.focus_lost);
}

/// The quick terminal's last tab closed (its shell exited): slide out
/// first, then close the window (WM_CLOSE). Returns false when it is
/// hidden already, and the caller closes the window.
pub fn onLastTabClosed(self: *QuickTerminal) bool {
    if (self.phase == .hidden) return false;
    self.close_when_hidden = true;
    self.hide(.closed);
    return true;
}

/// Whether a DPI change of the window should leave its scale alone: while
/// it slides it can reach onto another monitor, and it keeps the DPI of
/// the monitor it comes to. Otherwise the window adopts the DPI and
/// `relayout` puts the window in place again (it ignores the rectangle
/// Windows suggests).
pub fn ignoresDpiChange(self: *const QuickTerminal) bool {
    return self.phase == .sliding;
}

/// Called when the quick terminal's window is destroyed (shell exited).
/// At this point Window.onDestroy has already cleaned up font/hwnd.
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    anim.stop(&self.animator);

    alloc.destroy(self.window);
    app.quick_terminal = null;
    alloc.destroy(self);

    // Check if we should start the quit timer (after self is freed).
    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}

/// Follow a configuration reload: the window's theme and backdrop, its
/// size and place (`relayout`). The duration and autohide are read when
/// used.
pub fn onConfigChange(self: *QuickTerminal, config: *const configpkg.Config) void {
    _ = config;
    self.window.onConfigChange();
    self.relayout();
}

/// Compute where the window goes again (monitor, work area, DPI and the
/// configuration) and move it there: after a configuration reload or a
/// display change. A slide in progress goes on to the new places; a
/// hidden window waits in place (on its monitor, at its DPI and size).
pub fn relayout(self: *QuickTerminal) void {
    const config = &self.app.config;
    const position = config.@"quick-terminal-position";
    const monitor = self.getMonitor() orelse return;
    var mi = w32.MONITORINFO{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(monitor, &mi) == 0) return;
    const scale = monitorScale(monitor) orelse self.window.scale;
    const places = placesFor(position, config.@"quick-terminal-size", mi.rcWork, scale);
    self.target_rect = places.target;
    self.hidden_rect = places.hidden;
    self.work_rect = mi.rcWork;
    self.clip_slides = w32.MonitorFromRect(&places.hidden, w32.MONITOR_DEFAULTTONULL) != null;
    self.setRoundCorners(position == .center);
    if (self.phase != .sliding) self.moveTo(self.target_rect);
}

// -----------------------------------------------------------------------
// Showing and hiding
// -----------------------------------------------------------------------

fn show(self: *QuickTerminal) void {
    // Its last tab closed: it is on its way out for good.
    if (self.close_when_hidden) return;
    switch (self.phase) {
        .waiting, .shown => return self.activate(),
        .sliding => {
            if (!self.slide.opening) {
                const now = anim.now();
                self.slide = .from(self.slide.openness(now + frame_lead_ns), true, now + frame_lead_ns, self.durationNs());
                self.setPhase(.sliding);
                self.rememberForeground();
                self.window.setActiveTabVisible(true);
            }
            return self.activate();
        },
        .hidden => {},
    }
    const hwnd = self.window.hwnd orelse return;
    self.rememberForeground();
    self.relayout();
    setCloaked(hwnd, true);
    _ = w32.SetWindowPos(hwnd, w32.HWND_TOPMOST, 0, 0, 0, 0, w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE);
    // Wait for a frame presented from now on, not one drawn before.
    if (self.window.getActiveSurface()) |surface| {
        if (surface.frame_event) |event| _ = w32.ResetEvent(event);
    }
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    self.window.setActiveTabVisible(true);
    // The find bar and the scrollbar come back once the terminal is in.
    self.setTerminalPopupsShown(false);
    // Take the keyboard now, not after the slide: what is typed right
    // after the hotkey belongs to the terminal.
    self.activate();
    self.waiting_since_ns = anim.now();
    self.setPhase(.waiting);
    if (!anim.start(&self.animator)) self.finishShow();
}

/// Slide out, or hide at once without a slide.
fn hide(self: *QuickTerminal, reason: HideReason) void {
    const now = anim.now();
    const duration = self.durationNs();
    switch (self.phase) {
        .hidden => return,
        .sliding => {
            if (!self.slide.opening) return;
            self.slide = .from(self.slide.openness(now + frame_lead_ns), false, now + frame_lead_ns, duration);
        },
        .shown => {
            if (duration > 0) self.slide = .from(1, false, now, duration);
        },
        .waiting => {},
    }
    const slides = (self.phase == .sliding or self.phase == .shown) and duration > 0;
    // Set before the keyboard moves: the deactivation it causes finds the
    // quick terminal going already.
    self.setPhase(if (slides) .sliding else .hidden);
    if (reason != .focus_lost) self.restoreForeground();
    self.window.setActiveTabVisible(false);
    self.setTerminalPopupsShown(false);
    if (!slides) return self.hideWindow();
    if (!self.step(now)) return;
    if (!anim.start(&self.animator)) self.hideWindow();
}

/// The terminal presented its frame (or the wait timed out): slide in.
/// Returns whether the slide goes on.
fn reveal(self: *QuickTerminal, now_ns: u64) bool {
    const hwnd = self.window.hwnd orelse return false;
    log.debug("quick terminal revealed after {d}ms", .{(now_ns -| self.waiting_since_ns) / std.time.ns_per_ms});
    const duration = self.durationNs();
    if (duration == 0) {
        self.finishShow();
        return false;
    }
    self.slide = .from(0, true, now_ns, duration);
    self.setPhase(.sliding);
    self.place(self.slide.openness(now_ns + frame_lead_ns));
    setCloaked(hwnd, false);
    return true;
}

/// In place: no region, uncloaked, the terminal's popups back.
fn finishShow(self: *QuickTerminal) void {
    anim.stop(&self.animator);
    self.setPhase(.shown);
    const hwnd = self.window.hwnd orelse return;
    self.moveTo(self.target_rect);
    const clipped = self.clip != null;
    self.applyClip(null);
    setCloaked(hwnd, false);
    // Popups that did not follow the window while it slid.
    if (comptime @hasDecl(Window, "repositionPopups")) self.window.repositionPopups();
    self.setTerminalPopupsShown(true);
    reshowPopup(&self.window.notice.popup);
    reshowPopup(&self.window.toast.popup);
    // A terminal whose frames the region cut short draws a whole one.
    if (clipped) _ = w32.RedrawWindow(hwnd, null, null, w32.RDW_INVALIDATE | w32.RDW_ALLCHILDREN);
}

/// Off screen: hidden with every popup it owns, and closed when its last
/// tab closed.
fn hideWindow(self: *QuickTerminal) void {
    anim.stop(&self.animator);
    self.setPhase(.hidden);
    const hwnd = self.window.hwnd orelse return;
    _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
    // Owned windows do not hide with their owner: the toast, the notice,
    // the size overlay. Those that come back do so when it shows.
    _ = w32.ShowOwnedPopups(hwnd, 0);
    setCloaked(hwnd, false);
    self.applyClip(null);
    if (self.close_when_hidden) _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
}

fn setPhase(self: *QuickTerminal, phase: Phase) void {
    self.phase = phase;
    self.visible = switch (phase) {
        .hidden => false,
        .waiting, .shown => true,
        .sliding => self.slide.opening,
    };
    self.animating = phase == .waiting or phase == .sliding;
}

/// The slide duration, 0 without animations.
fn durationNs(self: *const QuickTerminal) u64 {
    const seconds = self.app.config.@"quick-terminal-animation-duration";
    if (!(seconds > 0) or !anim.enabled()) return 0;
    return @intFromFloat(@min(seconds, max_duration_s) * std.time.ns_per_s);
}

// -----------------------------------------------------------------------
// Frames
// -----------------------------------------------------------------------

fn animTick(animator: *anim.Animator, now_ns: u64) bool {
    const self: *QuickTerminal = @fieldParentPtr("animator", animator);
    return self.step(now_ns);
}

/// One frame of the wait or the slide; returns whether more follow.
fn step(self: *QuickTerminal, now_ns: u64) bool {
    switch (self.phase) {
        .waiting => {
            // A DPI change can resize the window meanwhile.
            self.moveTo(self.target_rect);
            if (!self.frameReady() and now_ns -| self.waiting_since_ns < first_frame_timeout_ns) return true;
            return self.reveal(now_ns);
        },
        .sliding => {
            const at = now_ns + frame_lead_ns;
            self.place(self.slide.openness(at));
            if (!self.slide.done(at)) return true;
            if (self.slide.opening) self.finishShow() else self.hideWindow();
            return false;
        },
        .hidden, .shown => return false,
    }
}

/// Whether the terminal presented a frame since `show` asked for one.
fn frameReady(self: *QuickTerminal) bool {
    const surface = self.window.getActiveSurface() orelse return true;
    const event = surface.frame_event orelse return true;
    return w32.WaitForSingleObject(event, 0) == w32.WAIT_OBJECT_0;
}

/// Put the window `openness` of the way from its hidden place (0) to its
/// place (1), clipped to the work area. The region shrinks before a move
/// out and grows after a move in, so nothing shows beyond the work area
/// in between.
fn place(self: *QuickTerminal, openness: f32) void {
    const rect = lerpRect(self.hidden_rect, self.target_rect, openness);
    const clip = if (self.clip_slides) clipFor(rect, self.work_rect) else null;
    if (!self.slide.opening) self.applyClip(clip);
    self.moveTo(rect);
    if (self.slide.opening) self.applyClip(clip);
}

/// Move and size the window to `rect` (screen pixels) unless it is there.
fn moveTo(self: *QuickTerminal, rect: w32.RECT) void {
    const hwnd = self.window.hwnd orelse return;
    var current: w32.RECT = undefined;
    const known = w32.GetWindowRect(hwnd, &current) != 0;
    if (known and std.meta.eql(current, rect)) return;
    const resized = !known or
        current.right - current.left != rect.right - rect.left or
        current.bottom - current.top != rect.bottom - rect.top;
    var flags: u32 = w32.SWP_NOZORDER | w32.SWP_NOACTIVATE;
    if (!resized) flags |= w32.SWP_NOSIZE;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, flags);
    // Its size only ever changes because of the configuration, the
    // monitor or its DPI: no size overlay for that.
    if (resized) _ = self.window.resize_overlay.onTimer(ResizeOverlay.TIMER_ID);
}

/// Set the window region (window coordinates; null for none) unless it
/// is set. Not redrawn: the window keeps its content.
fn applyClip(self: *QuickTerminal, clip: ?w32.RECT) void {
    if (std.meta.eql(clip, self.clip)) return;
    const hwnd = self.window.hwnd orelse return;
    const region: ?*anyopaque = if (clip) |c|
        w32.CreateRectRgn(c.left, c.top, c.right, c.bottom) orelse return
    else
        null;
    if (w32.SetWindowRgn(hwnd, region, 0) == 0) {
        if (region) |r| _ = w32.DeleteObject(r);
        return;
    }
    self.clip = clip;
}

fn setRoundCorners(self: *QuickTerminal, round: bool) void {
    if (self.round_corners == round) return;
    const hwnd = self.window.hwnd orelse return;
    const value: u32 = if (round) w32.DWMWCP_ROUND else w32.DWMWCP_DONOTROUND;
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_WINDOW_CORNER_PREFERENCE, @ptrCast(&value), @sizeOf(u32));
    self.round_corners = round;
}

/// Cloak or uncloak the window (DWMWA_CLOAK): DWM keeps a cloaked window
/// off the screen while it is shown and painted as usual.
fn setCloaked(hwnd: w32.HWND, cloaked: bool) void {
    const value: u32 = @intFromBool(cloaked);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_CLOAK, @ptrCast(&value), @sizeOf(u32));
}

// -----------------------------------------------------------------------
// Popups and the keyboard
// -----------------------------------------------------------------------

/// Show or hide the find bar and the scrollbar of the shown terminals.
fn setTerminalPopupsShown(self: *QuickTerminal, shown: bool) void {
    const window = self.window;
    if (window.active_tab >= window.tab_count) return;
    const tree = &window.tab_trees[window.active_tab];
    var it = tree.iterator();
    while (it.next()) |entry| {
        const pane_shown = if (tree.zoomed) |zoomed| entry.handle == zoomed else true;
        const surface = entry.view;
        surface.search_bar.setOwnerVisible(shown and pane_shown);
        if (surface.scrollbar) |sb| sb.setOwnerVisible(shown and pane_shown);
    }
}

/// Show again a popup of the window that `hideWindow` hid while it was
/// up (the notice, the toast).
fn reshowPopup(popup: *const Popup) void {
    if (!popup.visible) return;
    const hwnd = popup.hwnd orelse return;
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
}

/// Whether `hwnd` is the quick terminal's window or one it owns (a popup,
/// a dialog).
fn ownsWindow(self: *const QuickTerminal, hwnd: w32.HWND) bool {
    const own = self.window.hwnd orelse return false;
    return hwnd == own or w32.GetAncestor(hwnd, w32.GA_ROOTOWNER) == own;
}

/// Remember the active window to give the keyboard back to it later.
fn rememberForeground(self: *QuickTerminal) void {
    const foreground = w32.GetForegroundWindow() orelse return;
    if (self.ownsWindow(foreground)) return;
    self.previous_foreground = foreground;
}

/// Give the keyboard back to the window that had it before the quick
/// terminal came in, if the quick terminal still has it.
fn restoreForeground(self: *QuickTerminal) void {
    const previous = self.previous_foreground orelse return;
    self.previous_foreground = null;
    const foreground = w32.GetForegroundWindow() orelse return;
    if (!self.ownsWindow(foreground)) return;
    if (w32.IsWindow(previous) == 0 or w32.IsWindowVisible_(previous) == 0 or w32.IsIconic(previous) != 0) return;
    _ = w32.SetForegroundWindow(previous);
}

/// Bring the quick terminal to the foreground and give its terminal the
/// keyboard. Windows lets the process handling the global hotkey take the
/// foreground; when it refuses anyway, `forceForeground` tries again.
fn activate(self: *QuickTerminal) void {
    const hwnd = self.window.hwnd orelse return;
    if (w32.SetForegroundWindow(hwnd) == 0) forceForeground(hwnd);
    self.window.focusActiveSurface();
}

/// The fallback of `activate`: SetForegroundWindow while attached to the
/// input of the foreground window's thread, which works around the Win32
/// SetForegroundWindow restriction.
fn forceForeground(hwnd: w32.HWND) void {
    const fg_hwnd = w32.GetForegroundWindow() orelse return;
    const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
    const our_tid = w32.GetCurrentThreadId();
    if (fg_tid == 0 or fg_tid == our_tid) return;
    if (w32.AttachThreadInput(our_tid, fg_tid, 1) == 0) return;
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
}

// -----------------------------------------------------------------------
// Places
// -----------------------------------------------------------------------

fn getMonitor(self: *QuickTerminal) ?w32.HMONITOR {
    const screen = self.app.config.@"quick-terminal-screen";
    switch (screen) {
        .main, .@"macos-menu-bar" => {
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
        .mouse => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                return w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST);
            }
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
    }
}

/// The DPI scale of `monitor`, null when Windows does not say.
fn monitorScale(monitor: w32.HMONITOR) ?f32 {
    var x: u32 = 0;
    var y: u32 = 0;
    if (w32.GetDpiForMonitor(monitor, w32.MDT_EFFECTIVE_DPI, &x, &y) < 0 or x == 0) return null;
    return @as(f32, @floatFromInt(x)) / 96.0;
}

const Places = struct {
    /// In place.
    target: w32.RECT,
    /// Where slides start and end.
    hidden: w32.RECT,
};

/// Where the window goes in the work area `work` (screen pixels) of a
/// monitor with DPI scale `scale`: in place, docked to its edge (centered
/// along it) or in the middle; and hidden, just beyond that edge, or for
/// the middle `center_slide_dip` above.
fn placesFor(position: Position, size: SizeConfig, work: w32.RECT, scale: f32) Places {
    const work_w = work.right - work.left;
    const work_h = work.bottom - work.top;
    const dims = sizeFor(size, position, work_w, work_h, scale);
    const w = dims.width;
    const h = dims.height;
    const mid_x = work.left + @divTrunc(work_w - w, 2);
    const mid_y = work.top + @divTrunc(work_h - h, 2);
    const target: w32.RECT = switch (position) {
        .top => rectAt(mid_x, work.top, w, h),
        .bottom => rectAt(mid_x, work.bottom - h, w, h),
        .left => rectAt(work.left, mid_y, w, h),
        .right => rectAt(work.right - w, mid_y, w, h),
        .center => rectAt(mid_x, mid_y, w, h),
    };
    const hidden: w32.RECT = switch (position) {
        .top => rectAt(target.left, work.top - h, w, h),
        .bottom => rectAt(target.left, work.bottom, w, h),
        .left => rectAt(work.left - w, target.top, w, h),
        .right => rectAt(work.right, target.top, w, h),
        .center => rectAt(target.left, target.top - dipToPx(center_slide_dip, scale), w, h),
    };
    return .{ .target = target, .hidden = hidden };
}

fn rectAt(x: i32, y: i32, w: i32, h: i32) w32.RECT {
    return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
}

const Dimensions = struct { width: i32, height: i32 };

/// The size of the window in pixels in a work area of `work_w` × `work_h`
/// pixels with DPI scale `scale`. The axes are those of
/// `QuickTerminalSize.calculate`; percentages are of the work area, while
/// `px` values and the defaults (400 DIPs along the docked axis, the work
/// area across it; 800 × 400 DIPs centered) are DIPs. At most the work
/// area, at least a pixel.
fn sizeFor(size: SizeConfig, position: Position, work_w: i32, work_h: i32, scale: f32) Dimensions {
    return switch (position) {
        .left, .right => .{
            .width = axisLength(size.primary, work_w, default_short_dip, scale),
            .height = axisLength(size.secondary, work_h, null, scale),
        },
        .top, .bottom => .{
            .width = axisLength(size.secondary, work_w, null, scale),
            .height = axisLength(size.primary, work_h, default_short_dip, scale),
        },
        .center => if (work_w >= work_h) .{
            .width = axisLength(size.primary, work_w, default_long_dip, scale),
            .height = axisLength(size.secondary, work_h, default_short_dip, scale),
        } else .{
            .width = axisLength(size.secondary, work_w, default_short_dip, scale),
            .height = axisLength(size.primary, work_h, default_long_dip, scale),
        },
    };
}

/// One side of `sizeFor`: `value`, or `default_dip`, or (null) the whole
/// `work` length, within 1..`work` pixels.
fn axisLength(value: ?SizeConfig.Size, work: i32, default_dip: ?f32, scale: f32) i32 {
    const full: f32 = @floatFromInt(@max(work, 1));
    const length: f32 = if (value) |v| switch (v) {
        .percentage => |percent| if (percent >= 0) @floor(percent / 100 * full) else full,
        .pixels => |pixels| @round(@as(f32, @floatFromInt(pixels)) * scale),
    } else if (default_dip) |dip| @round(dip * scale) else full;
    return @intFromFloat(std.math.clamp(length, 1, full));
}

fn dipToPx(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

/// The window at `openness` of the way from `hidden` (0) to `target` (1):
/// the size of `target`, the place in between.
fn lerpRect(hidden: w32.RECT, target: w32.RECT, openness: f32) w32.RECT {
    const t = std.math.clamp(openness, 0, 1);
    const x = lerp(hidden.left, target.left, t);
    const y = lerp(hidden.top, target.top, t);
    return rectAt(x, y, target.right - target.left, target.bottom - target.top);
}

fn lerp(a: i32, b: i32, t: f32) i32 {
    return a + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(b - a)) * t)));
}

/// The part of a window at `rect` (screen pixels) that lies in `area`, in
/// window coordinates, for its window region; null when all of it does.
/// Empty when none of it does.
fn clipFor(rect: w32.RECT, area: w32.RECT) ?w32.RECT {
    if (rect.left >= area.left and rect.top >= area.top and
        rect.right <= area.right and rect.bottom <= area.bottom) return null;
    const left = std.math.clamp(area.left, rect.left, rect.right);
    const top = std.math.clamp(area.top, rect.top, rect.bottom);
    const right = std.math.clamp(area.right, left, rect.right);
    const bottom = std.math.clamp(area.bottom, top, rect.bottom);
    return .{
        .left = left - rect.left,
        .top = top - rect.top,
        .right = right - rect.left,
        .bottom = bottom - rect.top,
    };
}

/// A slide of the window between its hidden place (openness 0) and its
/// place (1), in with `motion.enter` or out with `motion.exit`.
const Slide = struct {
    /// In (towards 1) or out.
    opening: bool,
    tween: anim.Tween,

    /// A slide in (`opening`) or out over `duration_ns` whose openness is
    /// `current` at `now_ns`. A slide turned around midway continues from
    /// where it is: it starts as far into its curve as the curve needs to
    /// be there (`CubicBezier.timeAt`).
    fn from(current: f32, opening: bool, now_ns: u64, duration_ns: u64) Slide {
        const curve = if (opening) motion.enter else motion.exit;
        const change = std.math.clamp(if (opening) current else 1 - current, 0, 1);
        const elapsed: u64 = @intFromFloat(@as(f64, curve.timeAt(change)) * @as(f64, @floatFromInt(duration_ns)));
        return .{
            .opening = opening,
            .tween = .{ .start_ns = now_ns -| elapsed, .duration_ns = duration_ns, .curve = curve },
        };
    }

    /// 0 hidden .. 1 in place at `now_ns`.
    fn openness(self: Slide, now_ns: u64) f32 {
        const change = self.tween.progress(now_ns);
        return if (self.opening) change else 1 - change;
    }

    fn done(self: Slide, now_ns: u64) bool {
        return self.tween.done(now_ns);
    }
};

test "sizeFor: DIPs of the monitor, percentages of the work area" {
    const testing = std.testing;
    // Defaults: 400 DIPs along the docked axis, the work area across.
    try testing.expectEqual(Dimensions{ .width = 3840, .height = 600 }, sizeFor(.{}, .top, 3840, 2088, 1.5));
    try testing.expectEqual(Dimensions{ .width = 600, .height = 2088 }, sizeFor(.{}, .left, 3840, 2088, 1.5));
    try testing.expectEqual(Dimensions{ .width = 1200, .height = 600 }, sizeFor(.{}, .center, 3840, 2088, 1.5));
    // A portrait monitor swaps the centered axes.
    try testing.expectEqual(Dimensions{ .width = 600, .height = 1200 }, sizeFor(.{}, .center, 2088, 3840, 1.5));
    // `px` values are DIPs.
    try testing.expectEqual(
        Dimensions{ .width = 3840, .height = 450 },
        sizeFor(.{ .primary = .{ .pixels = 300 } }, .bottom, 3840, 2088, 1.5),
    );
    // Percentages of the work area, at any DPI.
    try testing.expectEqual(
        Dimensions{ .width = 1920, .height = 1044 },
        sizeFor(.{ .primary = .{ .percentage = 50 }, .secondary = .{ .percentage = 50 } }, .top, 3840, 2088, 1.5),
    );
    // Within the work area.
    try testing.expectEqual(
        Dimensions{ .width = 3840, .height = 2088 },
        sizeFor(.{ .primary = .{ .pixels = 5000 }, .secondary = .{ .percentage = 250 } }, .top, 3840, 2088, 2),
    );
    try testing.expectEqual(
        Dimensions{ .width = 1, .height = 2088 },
        sizeFor(.{ .primary = .{ .percentage = 0 } }, .right, 3840, 2088, 1),
    );
    // A percentage that is not a number takes the whole axis.
    try testing.expectEqual(
        Dimensions{ .width = 3840, .height = 2088 },
        sizeFor(.{ .primary = .{ .percentage = std.math.nan(f32) } }, .top, 3840, 2088, 1),
    );
}

test "sizeFor at 100% matches the upstream calculation" {
    const testing = std.testing;
    const work: SizeConfig.Dimensions = .{ .width = 1920, .height = 1040 };
    const sizes = [_]SizeConfig{
        .{},
        .{ .primary = .{ .percentage = 30 } },
        .{ .primary = .{ .pixels = 500 } },
        .{ .primary = .{ .percentage = 40 }, .secondary = .{ .pixels = 700 } },
        .{ .primary = .{ .pixels = 640 }, .secondary = .{ .percentage = 75 } },
    };
    for (sizes) |size| {
        for ([_]Position{ .top, .bottom, .left, .right, .center }) |position| {
            const want = size.calculate(position, work);
            const got = sizeFor(size, position, @intCast(work.width), @intCast(work.height), 1);
            try testing.expectEqual(@as(i32, @intCast(want.width)), got.width);
            try testing.expectEqual(@as(i32, @intCast(want.height)), got.height);
        }
    }
}

test "placesFor: docked to an edge, hidden beyond it" {
    const testing = std.testing;
    const work: w32.RECT = .{ .left = 0, .top = 0, .right = 3840, .bottom = 2088 };
    const half: SizeConfig = .{ .primary = .{ .percentage = 25 }, .secondary = .{ .percentage = 50 } };

    const top = placesFor(.top, half, work, 1.5);
    try testing.expectEqual(rectAt(960, 0, 1920, 522), top.target);
    try testing.expectEqual(rectAt(960, -522, 1920, 522), top.hidden);

    const bottom = placesFor(.bottom, half, work, 1.5);
    try testing.expectEqual(rectAt(960, 1566, 1920, 522), bottom.target);
    try testing.expectEqual(rectAt(960, 2088, 1920, 522), bottom.hidden);

    const left = placesFor(.left, .{}, work, 1.5);
    try testing.expectEqual(rectAt(0, 0, 600, 2088), left.target);
    try testing.expectEqual(rectAt(-600, 0, 600, 2088), left.hidden);

    // A monitor left of the primary one.
    const other: w32.RECT = .{ .left = -3840, .top = -419, .right = 0, .bottom = 1669 };
    const right = placesFor(.right, .{ .secondary = .{ .percentage = 50 } }, other, 1.5);
    try testing.expectEqual(rectAt(-600, -419 + 522, 600, 1044), right.target);
    try testing.expectEqual(rectAt(0, -419 + 522, 600, 1044), right.hidden);

    // Centered: from a short way above.
    const center = placesFor(.center, .{}, work, 1.5);
    try testing.expectEqual(rectAt(1320, 744, 1200, 600), center.target);
    try testing.expectEqual(rectAt(1320, 744 - 72, 1200, 600), center.hidden);
}

test "clipFor keeps the window in its work area" {
    const testing = std.testing;
    const work: w32.RECT = .{ .left = 0, .top = 0, .right = 3840, .bottom = 2088 };
    // All of it in: no region.
    try testing.expectEqual(@as(?w32.RECT, null), clipFor(rectAt(0, 1488, 3840, 600), work));
    try testing.expectEqual(@as(?w32.RECT, null), clipFor(work, work));
    // Coming up from below the work area (over the taskbar): its top rows.
    try testing.expectEqual(@as(?w32.RECT, .{ .left = 0, .top = 0, .right = 3840, .bottom = 200 }), clipFor(rectAt(0, 1888, 3840, 600), work));
    // Coming in from the monitor on the left: its right part.
    try testing.expectEqual(@as(?w32.RECT, .{ .left = 450, .top = 0, .right = 600, .bottom = 2088 }), clipFor(rectAt(-450, 0, 600, 2088), work));
    // Down from above: its bottom rows.
    try testing.expectEqual(@as(?w32.RECT, .{ .left = 0, .top = 500, .right = 3840, .bottom = 600 }), clipFor(rectAt(0, -500, 3840, 600), work));
    // Entirely outside: empty.
    const none = clipFor(rectAt(0, 2088, 3840, 600), work).?;
    try testing.expect(none.right <= none.left or none.bottom <= none.top);
    const beyond = clipFor(rectAt(-700, 0, 600, 2088), work).?;
    try testing.expect(beyond.right <= beyond.left or beyond.bottom <= beyond.top);
}

test "lerpRect moves the window and keeps its size" {
    const testing = std.testing;
    const hidden = rectAt(960, -522, 1920, 522);
    const target = rectAt(960, 0, 1920, 522);
    try testing.expectEqual(hidden, lerpRect(hidden, target, 0));
    try testing.expectEqual(target, lerpRect(hidden, target, 1));
    try testing.expectEqual(rectAt(960, -261, 1920, 522), lerpRect(hidden, target, 0.5));
    try testing.expectEqual(target, lerpRect(hidden, target, 1.5));
}

test "slides enter decelerating, leave accelerating, turn around in place" {
    const testing = std.testing;
    const ms = std.time.ns_per_ms;
    const start: u64 = 10_000 * ms;
    const duration: u64 = 200 * ms;

    const in = Slide.from(0, true, start, duration);
    try testing.expectEqual(@as(f32, 0), in.openness(start));
    try testing.expectEqual(@as(f32, 1), in.openness(start + duration));
    try testing.expect(in.done(start + duration));
    try testing.expect(!in.done(start + duration / 2));
    // Fast at first: more than half way at a fifth of the time.
    try testing.expect(in.openness(start + duration / 5) > 0.5);

    const out = Slide.from(1, false, start, duration);
    try testing.expectEqual(@as(f32, 1), out.openness(start));
    try testing.expectEqual(@as(f32, 0), out.openness(start + duration));
    // Slow at first: barely moved at a fifth of the time.
    try testing.expect(out.openness(start + duration / 5) > 0.95);

    // Turned around midway, either way, the slide goes on from where it
    // is, and goes all the way.
    for ([_]u64{ 10, 40, 100, 160, 190 }) |elapsed_ms| {
        const now = start + elapsed_ms * ms;
        const back = Slide.from(in.openness(now), false, now, duration);
        try testing.expectApproxEqAbs(in.openness(now), back.openness(now), 2e-3);
        try testing.expect(back.openness(now + ms) <= back.openness(now));
        try testing.expectEqual(@as(f32, 0), back.openness(now + duration));

        const again = Slide.from(out.openness(now), true, now, duration);
        try testing.expectApproxEqAbs(out.openness(now), again.openness(now), 2e-3);
        try testing.expect(again.openness(now + ms) >= again.openness(now));
        try testing.expectEqual(@as(f32, 1), again.openness(now + duration));
    }

    // No duration: there at once.
    try testing.expectEqual(@as(f32, 1), Slide.from(0, true, start, 0).openness(start));
    try testing.expect(Slide.from(1, false, start, 0).done(start));
}
