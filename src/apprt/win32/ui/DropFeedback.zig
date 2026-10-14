//! Non-activating drop feedback state; the owner paints it on its existing
//! overlay. Updating this state never changes focus or reads clipboard data.
const std = @import("std");
const refs = @import("../../../gx/ui_ref.zig");
const d2d = @import("d2d.zig");
const ole = @import("../ole_drop.zig");
const App = @import("../App.zig");
const Popup = @import("Popup.zig");
const w32 = @import("../win32.zig");
const style = @import("style.zig");
const i18n = @import("../../../gx/i18n.zig");

const Self = @This();
attachment: refs.Attachment = .{},
visible: bool = false,
accepted: bool = false,
popup: Popup = .{},
app: ?*App = null,
tokens: ?style.Tokens = null,

pub fn update(self: *Self, attachment: refs.Attachment, phase: ole.Phase, accepted: bool) void {
    switch (phase) {
        .enter, .over => {
            self.attachment = attachment;
            self.visible = attachment.isValid();
            self.accepted = accepted;
        },
        .leave, .queued, .rejected => self.clear(),
    }
}

pub fn clear(self: *Self) void {
    self.hide();
}

pub fn hide(self: *Self) void {
    self.visible = false;
    self.accepted = false;
    self.attachment = .{};
    self.popup.hide();
}

pub fn deinit(self: *Self) void {
    self.hide();
    self.popup.destroy();
    self.app = null;
    self.tokens = null;
}

/// App owns this address-stable popup; it never retains a Surface pointer.
pub fn show(self: *Self, app: *App, attachment: refs.Attachment, owner: w32.HWND, scale: f32, cursor: w32.POINT, accepted: bool) void {
    if (app.resolveSurfaceView(attachment) == null) return self.hide();
    const factory = app.uiFactory() orelse return self.hide();
    if (app.resolveSurfaceView(attachment) == null) return self.hide();
    if (self.popup.hwnd != null and self.popup.owner != owner) self.popup.destroy();
    const tokens = style.Tokens.fromConfig(&app.config);
    self.app = app;
    self.tokens = tokens;
    self.attachment = attachment;
    self.visible = true;
    self.accepted = accepted;
    if (self.popup.hwnd == null) {
        self.popup.create(app.hinstance, owner, factory, .{
            .activate = false,
            .click_through = true,
            .capture_mouse = false,
            .dismiss_on_escape = false,
            .dismiss_on_outside_click = false,
            .close_owner_on_close = false,
            .corners = .round_small,
            .dark = tokens.dark,
            .border_color = tokens.border,
        }, .{ .ctx = self, .paint = paint }) catch return self.hide();
    } else self.popup.applyTheme(tokens);
    if (app.resolveSurfaceView(attachment) == null) return self.hide();
    self.popup.setOwnerScale(scale);
    const s = self.popup.ownerScale();
    const measured = factory.measureText(self.label(), .{ .size = 12, .color = tokens.text }, 280);
    const width = style.px(@min(measured.width + 48, 328), s);
    const height = style.px(32, s);
    const gap = style.px(16, s);
    var x = cursor.x + gap;
    var y = cursor.y + gap;
    var monitor: w32.MONITORINFO = undefined;
    monitor.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(w32.MonitorFromWindow(owner, w32.MONITOR_DEFAULTTONEAREST), &monitor) != 0) {
        x = std.math.clamp(x, monitor.rcWork.left, @max(monitor.rcWork.left, monitor.rcWork.right - width));
        y = std.math.clamp(y, monitor.rcWork.top, @max(monitor.rcWork.top, monitor.rcWork.bottom - height));
    }
    self.popup.show(.{ .left = x, .top = y, .right = x + width, .bottom = y + height });
    if (app.resolveSurfaceView(attachment) == null) return self.hide();
    self.popup.invalidate();
}

fn label(self: *const Self) []const u8 {
    return if (self.accepted) i18n.tr("Drop to paste") else i18n.tr("Cannot drop here");
}

fn paint(context: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const app = self.app orelse return;
    if (!self.visible or app.resolveSurfaceView(self.attachment) == null) return;
    const tokens = self.tokens orelse return;
    const size = popup.sizeDip();
    canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, tokens.surface_raised);
    canvas.drawIcon(if (self.accepted) d2d.icons.copy else d2d.icons.cancel, .{ .x = 8, .y = 4, .w = 24, .h = 24 }, 16, if (self.accepted) tokens.accent else tokens.critical);
    canvas.drawText(self.label(), .{ .x = 36, .y = 0, .w = size.width - 44, .h = size.height }, .{ .size = 12, .color = tokens.text, .align_y = .center });
}

/// Both colors come from the owner's current tokens (accent / critical),
/// including high contrast. Bounds are DIPs; Canvas applies current DPI.
pub fn draw(self: *const Self, canvas: *d2d.Canvas, live: refs.Attachment, bounds: d2d.Rect, accent: d2d.Color, rejected: d2d.Color) void {
    if (!self.visible or !self.attachment.matches(live) or bounds.w < 4 or bounds.h < 4) return;
    const color = if (self.accepted) accent else rejected;
    const border: d2d.Rect = .{ .x = bounds.x + 1, .y = bounds.y + 1, .w = bounds.w - 2, .h = bounds.h - 2 };
    canvas.strokeRoundedRect(border, 4, color, 2);
    const badge: d2d.Rect = .{ .x = bounds.x + 8, .y = bounds.y + 8, .w = 24, .h = 24 };
    canvas.drawIcon(if (self.accepted) d2d.icons.copy else d2d.icons.cancel, badge, 16, color);
}

test "drop feedback clears on cancel and has no live default" {
    var state: Self = .{};
    state.update(.{}, .enter, true);
    try std.testing.expect(!state.visible);
    state.visible = true;
    state.update(.{}, .leave, false);
    try std.testing.expect(!state.visible);
    try std.testing.expect(!state.attachment.isValid());
}
