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
//!
//! The delay is the one of the system's tooltips (`delayFor`): the
//! double-click time before the first tooltip, a fifth of it when the
//! pointer moves on to a neighbor while a tooltip shows or just showed.
const std = @import("std");
const App = @import("../App.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32_tooltip);

/// The delay timer, on the owner window.
pub const timer_id: usize = 0x5454; // 'TT'

/// Hover time before a first tooltip shows when the system reports no
/// double-click time (the Windows default).
pub const delay_ms: u32 = 500;

/// The hover delay before a tooltip shows, as the system's tooltips have
/// it (`TTDT_INITIAL`, `TTDT_RESHOW`): `initial_ms` (the double-click
/// time), or a fifth of it when a tooltip of another target shows or
/// showed less than `initial_ms` ago (`last_shown_ms`; times in ms on one
/// clock), so moving along a row of buttons does not wait the full delay
/// at each.
pub fn delayFor(initial_ms: u32, now_ms: u64, last_shown_ms: ?u64) u32 {
    const recent = if (last_shown_ms) |t| now_ms -| t < initial_ms else false;
    return if (recent) @max(initial_ms / 5, 1) else initial_ms;
}

/// The first-tooltip delay: the double-click time.
fn initialDelay() u32 {
    const value = GetDoubleClickTime();
    return if (value == 0) delay_ms else value;
}

pub fn Tooltip(comptime Target: type) type {
    return struct {
        const Self = @This();

        popup: Popup = .{},
        /// What the tooltip describes: shown, or waiting for the delay.
        target: Target = .none,
        text_buf: [512]u8 = undefined,
        text_len: usize = 0,
        tokens: ?style.Tokens = null,
        timer_owner: ?w32.HWND = null,
        /// When the tooltip last hid after showing (GetTickCount64).
        hidden_ms: ?u64 = null,

        const font_size: f32 = 12;
        const pad_x: f32 = 8;
        const pad_y: f32 = 5;
        const max_width: f32 = 420;

        pub fn visible(self: *const Self) bool {
            return self.popup.visible;
        }

        pub fn hide(self: *Self) void {
            if (self.timer_owner) |owner| _ = w32.KillTimer(owner, timer_id);
            self.timer_owner = null;
            self.target = .none;
            if (self.popup.visible) self.hidden_ms = GetTickCount64();
            self.popup.hide();
        }

        pub fn destroy(self: *Self) void {
            self.hide();
            self.popup.destroy();
        }

        /// Point the tooltip at `target`, hiding the old target and starting
        /// its hover delay (`delayFor`). Hiding also cancels a pending delay.
        pub fn setTarget(self: *Self, owner: w32.HWND, target: Target) void {
            if (std.meta.eql(target, self.target)) return;
            const now = GetTickCount64();
            const last_shown = if (self.visible()) now else self.hidden_ms;
            self.hide();
            self.target = target;
            if (target != .none and w32.SetTimer(owner, timer_id, delayFor(initialDelay(), now, last_shown), null) != 0) {
                self.timer_owner = owner;
            }
        }

        /// Whether WM_TIMER belongs to the tooltip delay. Canceled or stale
        /// timers are consumed without showing a target.
        pub fn delayElapsed(self: *Self, owner: w32.HWND, id: usize) bool {
            if (id != timer_id) return false;
            _ = w32.KillTimer(owner, timer_id);
            self.timer_owner = null;
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

            var len = @min(value.len, self.text_buf.len);
            if (len < value.len) {
                while (len > 0 and value[len] & 0xc0 == 0x80) : (len -= 1) {}
            }
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

extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

test delayFor {
    const testing = std.testing;
    // The first tooltip waits the double-click time.
    try testing.expectEqual(@as(u32, 500), delayFor(500, 10_000, null));
    // Moving on while one shows, or soon after it hid: a fifth.
    try testing.expectEqual(@as(u32, 100), delayFor(500, 10_000, 10_000));
    try testing.expectEqual(@as(u32, 100), delayFor(500, 10_000, 9_600));
    // Long after: the full delay again.
    try testing.expectEqual(@as(u32, 500), delayFor(500, 10_000, 9_500));
    try testing.expectEqual(@as(u32, 500), delayFor(500, 10_000, 2_000));
    // A clock that went backwards counts as recent; tiny delays stay positive.
    try testing.expectEqual(@as(u32, 100), delayFor(500, 10_000, 12_000));
    try testing.expectEqual(@as(u32, 1), delayFor(3, 10, 10));
    try testing.expectEqual(@as(u32, 200), delayFor(1000, 0, 0));
}

test "hiding a pending tooltip clears its target before a stale timer" {
    const Target = enum { none, button };
    var tooltip: Tooltip(Target) = .{ .target = .button };
    tooltip.hide();
    try std.testing.expectEqual(Target.none, tooltip.target);
    try std.testing.expectEqual(@as(?w32.HWND, null), tooltip.timer_owner);
    tooltip.destroy();
    try std.testing.expectEqual(Target.none, tooltip.target);
}
