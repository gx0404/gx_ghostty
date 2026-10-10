//! A small non-activating, click-through tooltip popup below an anchor
//! rectangle, drawn with Direct2D in the chrome colors, and the hover delay
//! before it shows.
//!
//! `Tooltip(Target)` describes one target at a time; `Target` is a tagged
//! union or an enum with a `none` member, compared with `std.meta.eql`.
//! Point it at the part under the pointer with `setTarget`: another target
//! hides the tooltip and starts the delay (timer `timer_id` on the window
//! passed as the owner). The owner hands its WM_TIMER to `delayElapsed`;
//! when that returns true it looks up the text and the rectangle of
//! `target` and calls `show`. `hide` the tooltip when the part goes away
//! and `destroy` it with the owner.
const std = @import("std");
const App = @import("../App.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32_tooltip);

/// The delay timer, on the owner window.
pub const timer_id: usize = 0x5454; // 'TT'

/// Hover time before a tooltip shows.
pub const delay_ms: u32 = 600;

pub fn Tooltip(comptime Target: type) type {
    return struct {
        const Self = @This();

        popup: Popup = .{},
        /// What the tooltip describes: shown, or waiting for the delay.
        target: Target = .none,
        text_buf: [512]u8 = undefined,
        text_len: usize = 0,
        tokens: ?style.Tokens = null,

        const font_size: f32 = 12;
        const pad_x: f32 = 8;
        const pad_y: f32 = 5;
        const max_width: f32 = 420;

        pub fn visible(self: *const Self) bool {
            return self.popup.visible;
        }

        pub fn hide(self: *Self) void {
            self.popup.hide();
        }

        pub fn destroy(self: *Self) void {
            self.popup.destroy();
            self.target = .none;
        }

        /// Point the tooltip at `target`, the part of `owner` under the
        /// pointer (`.none` for nothing). When it changed, the tooltip
        /// hides and shows for the new target after `delay_ms`.
        pub fn setTarget(self: *Self, owner: w32.HWND, target: Target) void {
            if (std.meta.eql(target, self.target)) return;
            self.target = target;
            self.hide();
            _ = w32.KillTimer(owner, timer_id);
            if (target != .none) _ = w32.SetTimer(owner, timer_id, delay_ms, null);
        }

        /// Whether the WM_TIMER `id` of `owner` is the delay `setTarget`
        /// started, which it stops; show the tooltip of `target` then.
        pub fn delayElapsed(self: *Self, owner: w32.HWND, id: usize) bool {
            _ = self;
            if (id != timer_id) return false;
            _ = w32.KillTimer(owner, timer_id);
            return true;
        }

        fn text(self: *const Self) []const u8 {
            return self.text_buf[0..self.text_len];
        }

        /// Show `value` centered below `anchor` (screen pixels), kept on the
        /// monitor of `owner`, sized for the owner's content scale `scale`
        /// (`Window.scale`).
        pub fn show(self: *Self, app: *App, owner: w32.HWND, scale: f32, value: []const u8, anchor: w32.RECT) void {
            const factory = app.uiFactory() orelse return;
            const tokens = style.Tokens.fromConfig(&app.config);
            self.tokens = tokens;
            if (self.popup.hwnd == null) {
                self.popup.create(app.hinstance, owner, factory, .{
                    .activate = false,
                    .click_through = true,
                    .dismiss_on_escape = false,
                    .dismiss_on_outside_click = false,
                    .corners = .round_small,
                    .border_color = tokens.border,
                    .dark = tokens.dark,
                }, .{
                    .ctx = @ptrCast(self),
                    .paint = paintCallback,
                }) catch |err| {
                    log.warn("cannot create the tooltip err={}", .{err});
                    return;
                };
            } else {
                self.popup.setBorderColor(tokens.border);
            }

            const len = @min(value.len, self.text_buf.len);
            @memcpy(self.text_buf[0..len], value[0..len]);
            self.text_len = len;

            self.popup.setOwnerScale(scale);
            const s = self.popup.ownerScale();
            const size = factory.measureText(self.text(), textStyle(tokens), max_width - 2 * pad_x);
            const w = style.px(@min(size.width + 2 * pad_x + 1, max_width), s);
            const h = style.px(size.height + 2 * pad_y, s);
            const gap = style.px(6, s);

            const center_x = @divTrunc(anchor.left + anchor.right, 2);
            var x = center_x - @divTrunc(w, 2);
            var y = anchor.bottom + gap;
            var mi: w32.MONITORINFO = undefined;
            mi.cbSize = @sizeOf(w32.MONITORINFO);
            const monitor = w32.MonitorFromWindow(owner, w32.MONITOR_DEFAULTTONEAREST);
            if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
                const work = mi.rcWork;
                x = std.math.clamp(x, work.left + 2, @max(work.left + 2, work.right - w - 2));
                if (y + h > work.bottom) y = anchor.top - gap - h;
            }
            self.popup.show(.{ .left = x, .top = y, .right = x + w, .bottom = y + h });
        }

        fn textStyle(tokens: style.Tokens) d2d.TextStyle {
            return .{
                .size = font_size,
                .color = tokens.text,
                .wrap = true,
                .ellipsis = false,
            };
        }

        fn paintCallback(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const tokens = self.tokens orelse return;
            const size = popup.sizeDip();
            const r: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
            canvas.fillRect(r, tokens.surface_raised);
            canvas.drawText(self.text(), r.inset(pad_x, pad_y), textStyle(tokens));
        }
    };
}
