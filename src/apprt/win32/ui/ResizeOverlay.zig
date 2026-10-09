//! The transient "columns × rows" overlay a window shows while it is
//! resized (`resize-overlay`, `resize-overlay-position`,
//! `resize-overlay-duration`). It is a STATIC popup owned by the window;
//! the window colors it in `WM_CTLCOLORSTATIC` and forwards `WM_TIMER`
//! to `onTimer`, which hides it again.
//!
//! The owning `Window` embeds this struct as `resize_overlay`.
const ResizeOverlay = @This();

const std = @import("std");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");

/// Timer id used to auto-hide the overlay.
pub const TIMER_ID: usize = 0x5247; // 'RG'

/// The overlay popup. Owned by the window: destroyed with it.
hwnd: ?w32.HWND = null,

/// True once the initial WM_SIZE has been seen; resize-overlay =
/// after-first suppresses the overlay for that first layout pass.
seen_first: bool = false,

fn window(self: *ResizeOverlay) *Window {
    return @alignCast(@fieldParentPtr("resize_overlay", self));
}

/// Show the overlay for the active surface's grid, honoring the
/// resize-overlay / -position / -duration config. Auto-hides via a timer
/// that each subsequent resize re-arms.
pub fn show(self: *ResizeOverlay) void {
    const win = self.window();
    switch (win.app.config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (!self.seen_first) {
            // Suppress for the initial layout pass at window creation.
            self.seen_first = true;
            return;
        },
        .always => {},
    }
    self.seen_first = true;
    const hwnd = win.hwnd orelse return;

    // Grid dimensions from the active surface.
    const surface = win.getActiveSurface() orelse return;
    if (!surface.core_surface_ready) return;
    const grid = surface.core_surface.size.grid();

    var buf8: [32]u8 = undefined;
    const text8 = std.fmt.bufPrint(&buf8, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    var buf16: [32]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch return;
    buf16[len16] = 0;

    if (self.hwnd == null) {
        self.hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            hwnd,
            null,
            win.app.hinstance,
            null,
        );
        if (self.hwnd) |h| {
            if (win.tab_bar.font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const overlay = self.hwnd orelse return;
    _ = w32.SetWindowTextW(overlay, @ptrCast(&buf16));

    // Position within the client area per resize-overlay-position.
    const s = win.scale;
    const ow: i32 = @intFromFloat(@round(110.0 * s));
    const oh: i32 = @intFromFloat(@round(34.0 * s));
    const margin: i32 = @intFromFloat(@round(16.0 * s));
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const cx = @divTrunc(cw - ow, 2);
    const cy = @divTrunc(ch - oh, 2);
    var pt: w32.POINT = switch (win.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = margin, .y = margin },
        .@"top-center" => .{ .x = cx, .y = margin },
        .@"top-right" => .{ .x = cw - ow - margin, .y = margin },
        .@"bottom-left" => .{ .x = margin, .y = ch - oh - margin },
        .@"bottom-center" => .{ .x = cx, .y = ch - oh - margin },
        .@"bottom-right" => .{ .x = cw - ow - margin, .y = ch - oh - margin },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(overlay, null, pt.x, pt.y, ow, oh, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(overlay, w32.SW_SHOWNOACTIVATE);

    // (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
    // configured durations don't overflow the u32 SetTimer argument.
    const dur_ms: u32 = @max(1, win.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, TIMER_ID, dur_ms, null);
}

/// Handle the window's WM_TIMER; returns true when it was the overlay's.
pub fn onTimer(self: *ResizeOverlay, timer_id: usize) bool {
    if (timer_id != TIMER_ID) return false;
    if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    if (self.window().hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMER_ID);
    return true;
}
