//! The dimmed backdrop behind the settings overlay: a black, translucent
//! (`WS_EX_LAYERED` with a constant alpha), non-activating popup that
//! covers the terminal window below the overlay. A click on it reports
//! through `Callbacks.click`, which closes the overlay like a click outside
//! a modal dialog. It fades in (`anim`, the entrance of `gx.motion`) and
//! has the rounded corners of the window unless the window is maximized
//! or full screen.
//!
//! Show it before the overlay so the overlay stays on top of it; both are
//! owned by the terminal window. A close sent from outside (`taskkill`
//! without /F sends one to every window) leaves it alone: the overlay and
//! the window get their own. The backdrop also hears `WM_FONTCHANGE`, which
//! Windows broadcasts to top-level windows when fonts are installed or
//! removed (`Callbacks.font_change`).
const Scrim = @This();

const std = @import("std");
const w32 = @import("../../win32.zig");
const anim = @import("../anim.zig");

hwnd: ?w32.HWND = null,
callbacks: ?Callbacks = null,
/// The darkness when faded in (0-255).
alpha: u8 = 0,
animator: anim.Animator = .{ .tick = animTick },
fade: anim.Tween = .{ .start_ns = 0, .duration_ns = 0 },

pub const Callbacks = struct {
    ctx: *anyopaque,
    click: *const fn (ctx: *anyopaque) void,
    font_change: ?*const fn (ctx: *anyopaque) void = null,
};

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxSettingsScrim");
const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWCP_DONOTROUND: u32 = 1;
const DWMWCP_ROUND: u32 = 2;
const WM_FONTCHANGE: u32 = 0x001D;
const WM_NCDESTROY: u32 = 0x0082;

extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: w32.HWND,
    attribute: u32,
    value: *anyopaque,
    size: u32,
) callconv(.winapi) i32;

extern "user32" fn IsWindow(hwnd: ?w32.HWND) callconv(.winapi) i32;

/// Create the (hidden) backdrop owned by `owner`, with `alpha` (0-255) of
/// black.
pub fn create(
    self: *Scrim,
    hinstance: w32.HINSTANCE,
    owner: w32.HWND,
    alpha: u8,
    callbacks: Callbacks,
) !void {
    if (self.hwnd != null) return;
    try registerClass(hinstance);
    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        CLASS_NAME,
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
    self.* = .{ .hwnd = hwnd, .callbacks = callbacks, .alpha = alpha };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
}

/// Destroy the window. Safe when Windows already destroyed it together
/// with its owner.
pub fn destroy(self: *Scrim) void {
    anim.stop(&self.animator);
    if (self.hwnd) |hwnd| {
        if (isOwnWindow(hwnd, self)) {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(hwnd);
        }
    }
    self.* = .{};
}

/// Cover `rect` (screen pixels), with round corners when `round` (the
/// window has them), and show without taking activation, fading in.
pub fn show(self: *Scrim, rect: w32.RECT, round: bool) void {
    const hwnd = self.hwnd orelse return;
    const corners: u32 = if (round) DWMWCP_ROUND else DWMWCP_DONOTROUND;
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, @ptrCast(&corners), @sizeOf(u32));
    const fading = anim.enabled() and !self.animator.running and w32.IsWindowVisible_(hwnd) == 0;
    if (fading) {
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, 0, w32.LWA_ALPHA);
    }
    _ = w32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        w32.SWP_NOACTIVATE,
    );
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    if (!fading) return;
    self.fade = anim.Tween.begin(anim.now(), anim.motion.duration.fast, anim.motion.enter);
    if (!anim.start(&self.animator)) self.finishFade(hwnd);
}

pub fn hide(self: *Scrim) void {
    const hwnd = self.hwnd orelse return;
    if (self.animator.running) {
        anim.stop(&self.animator);
        self.finishFade(hwnd);
    }
    _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
}

fn animTick(animator: *anim.Animator, now: u64) bool {
    const self: *Scrim = @alignCast(@fieldParentPtr("animator", animator));
    const hwnd = self.hwnd orelse return false;
    if (self.fade.done(now)) {
        self.finishFade(hwnd);
        return false;
    }
    const level = self.fade.lerp(now, 0, @floatFromInt(self.alpha));
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, @intFromFloat(@round(level)), w32.LWA_ALPHA);
    return true;
}

fn finishFade(self: *Scrim, hwnd: w32.HWND) void {
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, self.alpha, w32.LWA_ALPHA);
}

/// The visible bounds of a top-level window in screen pixels: the DWM
/// frame without the invisible resize borders, else the window rect.
pub fn visibleBounds(hwnd: w32.HWND) w32.RECT {
    var rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, @ptrCast(&rect), @sizeOf(w32.RECT)) >= 0 and
        rect.right > rect.left and rect.bottom > rect.top)
    {
        return rect;
    }
    _ = w32.GetWindowRect(hwnd, &rect);
    return rect;
}

/// Whether `hwnd` is still the window created for `owner_struct`: it
/// exists and carries its pointer (a destroyed window's handle can be
/// reused).
pub fn isOwnWindow(hwnd: w32.HWND, owner_struct: *const anyopaque) bool {
    if (IsWindow(hwnd) == 0) return false;
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    return userdata == @as(isize, @bitCast(@intFromPtr(owner_struct)));
}

var class_registered = false;

fn registerClass(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const brush: ?w32.HBRUSH = @ptrCast(w32.GetStockObject(w32.BLACK_BRUSH));
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = brush,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Scrim = @ptrFromInt(@as(usize, @bitCast(userdata)));
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_LBUTTONDOWN, w32.WM_RBUTTONDOWN, w32.WM_MBUTTONDOWN => {
            if (self.callbacks) |cb| cb.click(cb.ctx);
            return 0;
        },
        w32.WM_CLOSE => return 0,
        WM_FONTCHANGE => {
            if (self.callbacks) |cb| if (cb.font_change) |f| f(cb.ctx);
            return 0;
        },
        WM_NCDESTROY => {
            // Destroyed with its owner: forget the window.
            anim.stop(&self.animator);
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            self.hwnd = null;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
