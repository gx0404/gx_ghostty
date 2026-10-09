//! The transient "columns × rows" overlay a window shows while it is
//! resized (`resize-overlay`, `resize-overlay-position`,
//! `resize-overlay-duration`): a rounded, non-activating, click-through
//! `Popup` drawn in the theme colors. The window forwards `WM_TIMER` to
//! `onTimer`, which hides it again.
//!
//! The owning `Window` embeds this struct as `resize_overlay` and calls
//! `show` on every resize and `deinit` with the window.
const ResizeOverlay = @This();

const std = @import("std");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32);

/// Timer id used to auto-hide the overlay.
pub const TIMER_ID: usize = 0x5247; // 'RG'

/// Height, horizontal padding and margin from the window edges in DIPs.
const height: f32 = 36;
const pad_x: f32 = 16;
const margin: f32 = 16;
const text_size: f32 = 15;

popup: Popup = .{},

/// The text on display, e.g. "120 × 40".
text_buf: [32]u8 = undefined,
text_len: usize = 0,

/// True once the initial WM_SIZE has been seen; resize-overlay =
/// after-first suppresses the overlay for that first layout pass.
seen_first: bool = false,

fn window(self: *ResizeOverlay) *Window {
    return @alignCast(@fieldParentPtr("resize_overlay", self));
}

/// Destroy the popup.
pub fn deinit(self: *ResizeOverlay) void {
    self.popup.destroy();
}

fn tokens(self: *ResizeOverlay) style.Tokens {
    return style.Tokens.fromConfig(&self.window().app.config);
}

fn textStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = text_size,
        .weight = .semibold,
        .color = t.text,
        .align_x = .center,
        .align_y = .center,
        .ellipsis = false,
    };
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
    const text = std.fmt.bufPrint(&self.text_buf, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    self.text_len = text.len;

    const factory = win.app.uiFactory() orelse return;
    const t = self.tokens();
    if (self.popup.hwnd == null) {
        self.popup.create(win.app.hinstance, hwnd, factory, .{
            .activate = false,
            .click_through = true,
            .dismiss_on_escape = false,
            .dismiss_on_outside_click = false,
            .corners = .round,
            .shadow = true,
            .border_color = t.border,
            .dark = t.dark,
        }, .{
            .ctx = self,
            .paint = paint,
        }) catch |err| {
            log.warn("failed to create the resize overlay err={}", .{err});
            return;
        };
    } else {
        self.popup.setBorderColor(t.border);
    }

    // Size to the text; position within the surface area of the client
    // per resize-overlay-position.
    self.popup.setOwnerScale(win.scale);
    const scale = self.popup.ownerScale();
    const text_w = factory.measureText(text, textStyle(t), 1000).width;
    const ow = style.px(text_w + 2 * pad_x, scale);
    const oh = style.px(height, scale);
    const m = style.px(margin, scale);
    const area = win.surfaceRect();
    const aw = area.right - area.left;
    const ah = area.bottom - area.top;
    const cx = area.left + @divTrunc(aw - ow, 2);
    const cy = area.top + @divTrunc(ah - oh, 2);
    var pt: w32.POINT = switch (win.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = area.left + m, .y = area.top + m },
        .@"top-center" => .{ .x = cx, .y = area.top + m },
        .@"top-right" => .{ .x = area.right - ow - m, .y = area.top + m },
        .@"bottom-left" => .{ .x = area.left + m, .y = area.bottom - oh - m },
        .@"bottom-center" => .{ .x = cx, .y = area.bottom - oh - m },
        .@"bottom-right" => .{ .x = area.right - ow - m, .y = area.bottom - oh - m },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    self.popup.show(.{ .left = pt.x, .top = pt.y, .right = pt.x + ow, .bottom = pt.y + oh });

    // (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
    // configured durations don't overflow the u32 SetTimer argument.
    const dur_ms: u32 = @max(1, win.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, TIMER_ID, dur_ms, null);
}

/// Handle the window's WM_TIMER; returns true when it was the overlay's.
pub fn onTimer(self: *ResizeOverlay, timer_id: usize) bool {
    if (timer_id != TIMER_ID) return false;
    self.popup.hide();
    if (self.window().hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMER_ID);
    return true;
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, t.surface_raised);
    canvas.drawText(self.text_buf[0..self.text_len], full, textStyle(t));
}
