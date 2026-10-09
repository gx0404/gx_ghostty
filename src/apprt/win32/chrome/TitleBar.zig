//! Title bar and non-client frame of a top-level terminal window.
//!
//! Today the system draws the caption: `windowStyle` picks the Win32
//! styles from `window-decoration`, `height` is 0 (the caption is not part
//! of the client area) and `handleMessage` lets every message fall through
//! to the default handling. A custom title bar replaces exactly these
//! hooks: extend the client area over the caption in `WM_NCCALCSIZE`,
//! report caption/resize/button regions from `WM_NCHITTEST`, paint the
//! caption in `paint` and return its client height from `height` so the
//! window lays the tab bar and terminals out below it.
//!
//! Fullscreen and decoration toggling change the frame styles and live
//! here too. The owning `Window` embeds this struct as `title_bar`.
const TitleBar = @This();

const std = @import("std");
const configpkg = @import("../../../config.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

pub const Style = struct {
    style: u32,
    ex_style: u32,
};

/// The Win32 styles for a new top-level window.
pub fn windowStyle(config: *const configpkg.Config, is_quick_terminal: bool) Style {
    const style: u32 = if (is_quick_terminal)
        w32.WS_POPUP
    else if (config.@"window-decoration" == .none)
        // Borderless but still resizable: thin sizing frame, no title bar.
        w32.WS_POPUP | w32.WS_THICKFRAME | w32.WS_CLIPCHILDREN
    else
        w32.WS_OVERLAPPEDWINDOW | w32.WS_CLIPCHILDREN;
    const ex_style: u32 = if (is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;
    return .{ .style = style, .ex_style = ex_style };
}

fn window(self: *TitleBar) *Window {
    return @alignCast(@fieldParentPtr("title_bar", self));
}

/// Height in pixels of the title bar inside the client area. The system
/// caption is non-client, so this is 0.
pub fn height(self: *const TitleBar) i32 {
    _ = self;
    return 0;
}

/// Non-client hook, called first by the window procedure for every
/// message. Returns the message result when the title bar handled the
/// message, or null for the default handling.
pub fn handleMessage(
    self: *TitleBar,
    msg: u32,
    wparam: usize,
    lparam: isize,
) ?isize {
    _ = self;
    _ = msg;
    _ = wparam;
    _ = lparam;
    return null;
}

/// Paint the client-area part of the title bar into the window's paint
/// DC. Nothing to paint while the system draws the caption.
pub fn paint(self: *TitleBar, hdc: w32.HDC) void {
    _ = self;
    _ = hdc;
}

/// The DPI of the window changed (metrics, fonts and caption buttons).
pub fn onDpiChanged(self: *TitleBar) void {
    _ = self;
}

/// The UI language changed (caption button tooltips).
pub fn onLanguageChanged(self: *TitleBar) void {
    _ = self;
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *TitleBar) void {
    const hwnd = self.window().hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleDecorations(self: *TitleBar) void {
    const hwnd = self.window().hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}
