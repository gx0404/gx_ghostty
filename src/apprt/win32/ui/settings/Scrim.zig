//! The dimmed backdrop behind the settings overlay: a black, translucent
//! (`WS_EX_LAYERED` with a constant alpha), non-activating popup that
//! covers the terminal window below the overlay. A click on it reports
//! through `on_click`, which closes the overlay like a click outside a
//! modal dialog.
//!
//! Show it before the overlay so the overlay stays on top of it; both are
//! owned by the terminal window.
const Scrim = @This();

const std = @import("std");
const w32 = @import("../../win32.zig");

hwnd: ?w32.HWND = null,
ctx: ?*anyopaque = null,
on_click: ?*const fn (ctx: *anyopaque) void = null,

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxSettingsScrim");
const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWCP_ROUND: u32 = 2;

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
    ctx: *anyopaque,
    on_click: *const fn (ctx: *anyopaque) void,
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
    self.* = .{ .hwnd = hwnd, .ctx = ctx, .on_click = on_click };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    const corners: u32 = DWMWCP_ROUND;
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, @ptrCast(&corners), @sizeOf(u32));
}

/// Destroy the window. Safe when Windows already destroyed it together
/// with its owner.
pub fn destroy(self: *Scrim) void {
    if (self.hwnd) |hwnd| {
        if (isOwnWindow(hwnd, self)) {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(hwnd);
        }
    }
    self.* = .{};
}

/// Change the darkness (0-255).
pub fn setAlpha(self: *Scrim, alpha: u8) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
}

/// Cover `rect` (screen pixels) and show without taking activation.
pub fn show(self: *Scrim, rect: w32.RECT) void {
    const hwnd = self.hwnd orelse return;
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
}

pub fn hide(self: *Scrim) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
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
            if (self.on_click) |f| if (self.ctx) |ctx| f(ctx);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
