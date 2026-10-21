//! A short confirmation centered at the bottom of a window ("Copied",
//! "Configuration reloaded"): a rounded capsule with an optional icon
//! that stays for 3 seconds by default (or until hidden for key hints).
//! It fades in (`Popup.Options.motion`), lets
//! the pointer through, never takes the focus, waits while a modal dialog
//! has its window disabled, and defers while a live Quick owner is hidden
//! or moving. Closing owners discard feedback. Showing it again replaces
//! the text and starts its deadline; queued old timer messages cannot
//! expire the replacement. Surface key hints are cancelled on occlusion
//! or destruction, without clearing another terminal's key state.
//!
//! Usage: embed a `Toast` in an address-stable owner (the window); call
//! `show` from the message loop or `post` from a core callback (it shows
//! from the message loop, through `WM_SHOW_POSTED` on its own popup
//! window), with a `Notice.Placement`. Move it with `reposition`, free it
//! with `deinit`. Timers `TS` (hide) and `TW` (waiting for a dialog) live
//! on its popup window. The caller decides whether to show one at all
//! (`app-notifications`); without Direct2D it shows nothing.
const Toast = @This();

const std = @import("std");
const App = @import("../App.zig");
const w32 = @import("../win32.zig");
const Notice = @import("Notice.zig");
const Popup = @import("Popup.zig");
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32_toast);

pub const Owner = struct {
    surface_id: u64,
    kind: enum { sequence, table },
};

pub const Content = struct {
    text: []const u8,
    /// An icon glyph (`d2d.icons`) before the text, in the accent color.
    icon: ?u21 = null,
    /// Null keeps the hint until its caller hides it.
    duration_ms: ?u32 = Toast.duration_ms,
    /// Persistent key hints follow this terminal, never another one's end.
    owner: ?Owner = null,
};

pub const Placement = Notice.Placement;

/// Posted to the toast's own popup window by `post`.
pub const WM_SHOW_POSTED: u32 = w32.WM_APP + 40;
pub const HIDE_TIMER_ID: usize = 0x5453; // 'TS'
pub const WAIT_TIMER_ID: usize = 0x5457; // 'TW'
pub const duration_ms: u32 = 3000;
const wait_ms = 250;

const layout = struct {
    const height: f32 = style.row.list;
    const pad: f32 = style.space.l;
    const icon_gap: f32 = style.space.s;
    const margin: f32 = style.space.xl;
};

popup: Popup = .{},
app: ?*App = null,
placement: ?Placement = null,
text: [256]u8 = undefined,
text_len: usize = 0,
icon: ?u21 = null,
timeout_ms: ?u32 = duration_ms,
timeout_deadline: ?u64 = null,
owner: ?Owner = null,
pending: bool = false,
uia_message_version: u64 = 0,
uia_staged_version: ?u64 = null,

/// Show `content` now (from the message loop).
pub fn show(self: *Toast, app: *App, placement: Placement, content: Content) void {
    self.app = app;
    self.placement = placement;
    self.store(content);
    self.pending = true;
    self.showStored();
}

/// Show `content` from the message loop: safe to call from core callbacks.
pub fn post(self: *Toast, app: *App, placement: Placement, content: Content) void {
    self.app = app;
    self.placement = placement;
    self.store(content);
    self.pending = true;
    if (!self.applyDisposition(placement.disposition(app))) return;
    if (!self.ensurePopup()) return;
    const hwnd = self.popup.hwnd orelse return;
    if (w32.PostMessageW(hwnd, WM_SHOW_POSTED, 0, 0) == 0) log.warn("cannot post a toast", .{});
}

pub fn hide(self: *Toast) void {
    self.pending = false;
    self.owner = null;
    self.deferUntilShown();
    self.pending = false;
}

pub fn hideOwned(self: *Toast, owner: Owner) void {
    if (self.owner) |current| if (std.meta.eql(current, owner)) self.hide();
}

pub fn hideForSurface(self: *Toast, id: u64) void {
    if (self.owner) |current| if (current.surface_id == id) self.hide();
}

/// Keep feedback for the next settled show, without a timer or reveal
/// that could bring its popup back during the owner's animation.
pub fn deferUntilShown(self: *Toast) void {
    if (self.popup.uia_view.announcement.pending) self.uia_staged_version = null;
    self.pending = self.pending or self.popup.visible;
    self.timeout_deadline = null;
    if (self.popup.hwnd) |hwnd| {
        _ = w32.KillTimer(hwnd, HIDE_TIMER_ID);
        _ = w32.KillTimer(hwnd, WAIT_TIMER_ID);
    }
    self.popup.hide();
}

pub fn onOwnerShown(self: *Toast, placement: Placement) void {
    self.placement = placement;
    self.showStored();
}

fn applyDisposition(self: *Toast, disposition: Notice.Disposition) bool {
    switch (disposition) {
        .ready => return true,
        .deferred => self.deferUntilShown(),
        .discard => self.hide(),
    }
    return false;
}

pub fn isVisible(self: *const Toast) bool {
    return self.popup.visible;
}

/// Follow the window (moved, resized, another DPI).
pub fn reposition(self: *Toast, placement: Placement) void {
    self.placement = placement;
    if (self.app) |app| if (!self.applyDisposition(placement.disposition(app))) return;
    if (!self.popup.visible) return;
    const rect = self.bounds() orelse return;
    self.popup.setBounds(rect);
}

pub fn deinit(self: *Toast) void {
    self.popup.destroy();
    self.* = .{};
}

fn store(self: *Toast, content: Content) void {
    self.uia_message_version +%= 1;
    self.uia_staged_version = null;
    self.popup.uia_view.announcement.cancel();
    self.popup.uia_view.dirty();
    var len = @min(content.text.len, self.text.len);
    while (len < content.text.len and len > 0 and content.text[len] & 0xC0 == 0x80) len -= 1;
    @memcpy(self.text[0..len], content.text[0..len]);
    self.text_len = len;
    self.icon = content.icon;
    self.timeout_ms = content.duration_ms;
    self.owner = content.owner;
    self.timeout_deadline = null;
    if (self.popup.hwnd) |hwnd| _ = w32.KillTimer(hwnd, HIDE_TIMER_ID);
}

fn tokens(self: *const Toast) style.Tokens {
    const app = self.app orelse return style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    return style.Tokens.fromConfig(&app.config);
}

fn ensurePopup(self: *Toast) bool {
    const app = self.app orelse return false;
    const placement = self.placement orelse return false;
    if (self.popup.hwnd != null) {
        if (self.popup.owner == placement.owner) return true;
        self.popup.destroy();
    }
    const factory = app.uiFactory() orelse return false;
    const t = self.tokens();
    self.popup.create(app.hinstance, placement.owner, factory, .{
        .activate = false,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .click_through = true,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
        .motion = .{ .offset_y = 8 },
    }, .{
        .ctx = self,
        .paint = paint,
        .uia_source = .{ .app = app, .build = uiaBuild, .is_live = uiaLive, .action = uiaAction },
        .timer = onTimer,
        .message = onMessage,
    }) catch |err| {
        log.warn("cannot create a toast err={}", .{err});
        return false;
    };
    return true;
}

fn uiaLive(context: *anyopaque) bool {
    const self: *Toast = @ptrCast(@alignCast(context));
    const app = self.app orelse return false;
    const placement = self.placement orelse return false;
    return self.popup.visible and uia_bridge.ownerAttachment(app, placement.owner) != null;
}
fn uiaBuild(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
    const self: *Toast = @ptrCast(@alignCast(context));
    const app = self.app orelse return;
    const placement = self.placement orelse return;
    const attachment = uia_bridge.ownerAttachment(app, placement.owner) orelse return bridge.hide();
    _ = try bridge.publishToast(api, queue, attachment, self, .{ .context = self, .is_live = uiaLive, .action = uiaAction });
    if (bridge.publisher.current != null and self.uia_staged_version != self.uia_message_version) {
        self.uia_staged_version = self.uia_message_version;
        bridge.announce(self.text[0..self.text_len]);
    }
}
fn uiaAction(context: *anyopaque, token: u64, action: *const uia.Action) bool {
    const self: *Toast = @ptrCast(@alignCast(context));
    if (!uiaLive(context) or token != 0 or action.kind != .close) return false;
    self.hide();
    return true;
}

fn showStored(self: *Toast) void {
    if (!self.pending) return;
    const placement = self.placement orelse return;
    const app = self.app orelse return;
    if (!self.applyDisposition(placement.disposition(app))) return;
    if (!self.ensurePopup()) return;
    const hwnd = self.popup.hwnd orelse return;
    if (w32.IsWindowEnabled(placement.owner) == 0) {
        _ = w32.SetTimer(hwnd, WAIT_TIMER_ID, wait_ms, null);
        return;
    }
    _ = w32.KillTimer(hwnd, WAIT_TIMER_ID);
    self.popup.applyTheme(self.tokens());
    self.popup.setAccessibleName(self.text[0..self.text_len]);
    const rect = self.bounds() orelse return;
    self.pending = false;
    self.popup.show(rect);
    _ = w32.KillTimer(hwnd, HIDE_TIMER_ID);
    self.timeout_deadline = if (self.timeout_ms) |ms| GetTickCount64() +| ms else null;
    if (self.timeout_ms) |ms| _ = w32.SetTimer(hwnd, HIDE_TIMER_ID, ms, null);
}

fn textStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.body, .color = color, .ellipsis = true };
}

/// The width of a toast with text `text_w` wide, with or without an icon,
/// fitted into `max_w` (DIPs).
pub fn widthFor(text_w: f32, icon: bool, max_w: f32) f32 {
    const icon_w: f32 = if (icon) style.icon.standard + layout.icon_gap else 0;
    return @max(0, @min(max_w, @ceil(text_w) + icon_w + 2 * layout.pad));
}

fn bounds(self: *Toast) ?w32.RECT {
    const placement = self.placement orelse return null;
    const app = self.app orelse return null;
    const factory = app.uiFactory() orelse return null;
    self.popup.setOwnerScale(placement.scale);
    const scale = self.popup.ownerScale();
    const area = placement.area;
    const area_w = style.dip(area.right - area.left, scale);
    const text_w = factory.measureText(self.text[0..self.text_len], textStyle(.{ .r = 0, .g = 0, .b = 0 }), 10_000).width;
    const width = widthFor(text_w, self.icon != null, area_w - 2 * layout.margin);
    const w = style.px(width, scale);
    const h = style.px(layout.height, scale);
    var pt: w32.POINT = .{
        .x = area.left + @divTrunc(area.right - area.left - w, 2),
        .y = area.bottom - h - style.px(layout.margin, scale),
    };
    _ = w32.ClientToScreen(placement.owner, &pt);
    return .{ .left = pt.x, .top = pt.y, .right = pt.x + w, .bottom = pt.y + h };
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *Toast = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, t.surface_raised);
    if (t.high_contrast) canvas.strokeRoundedRectPx(full, 0, t.border, 1);
    var x = layout.pad;
    if (self.icon) |glyph| {
        canvas.drawIcon(glyph, .{ .x = x, .y = 0, .w = style.icon.standard, .h = size.height }, style.icon.standard, t.accent);
        x += style.icon.standard + layout.icon_gap;
    }
    canvas.drawText(self.text[0..self.text_len], .{ .x = x, .y = 0, .w = @max(0, size.width - x - layout.pad), .h = size.height }, textStyle(t.text));
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn timeoutDue(self: *const Toast, now: u64) bool {
    const deadline = self.timeout_deadline orelse return false;
    return self.popup.visible and !self.pending and now >= deadline;
}

fn onTimer(ctx: *anyopaque, popup: *Popup, id: usize) void {
    const self: *Toast = @ptrCast(@alignCast(ctx));
    switch (id) {
        HIDE_TIMER_ID => if (self.timeoutDue(GetTickCount64())) self.hide(),
        WAIT_TIMER_ID => self.showStored(),
        else => if (popup.hwnd) |hwnd| {
            _ = w32.KillTimer(hwnd, id);
        },
    }
}

fn onMessage(ctx: *anyopaque, _: *Popup, msg: u32, _: usize, _: isize) bool {
    const self: *Toast = @ptrCast(@alignCast(ctx));
    if (msg != WM_SHOW_POSTED) return false;
    self.showStored();
    return true;
}

test "toast width fits the text and the window" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 60 + 32), widthFor(60, false, 1000));
    try testing.expectEqual(@as(f32, 60 + 16 + 8 + 32), widthFor(59.2, true, 1000));
    try testing.expectEqual(@as(f32, 200), widthFor(500, true, 200));
    try testing.expectEqual(@as(f32, 0), widthFor(10, false, -5));
}

test "toast text is stored up to a character boundary" {
    const testing = std.testing;
    var toast: Toast = .{};
    toast.store(.{ .text = "Copied", .icon = d2d.icons.check_mark });
    try testing.expectEqualStrings("Copied", toast.text[0..toast.text_len]);
    try testing.expectEqual(@as(?u21, d2d.icons.check_mark), toast.icon);
    toast.store(.{ .text = std.mem.asBytes(&@as([100]["\u{6C49}".len]u8, @splat("\u{6C49}".*))) });
    try testing.expect(toast.text_len <= toast.text.len);
    try testing.expect(std.unicode.utf8ValidateSlice(toast.text[0..toast.text_len]));
    try testing.expectEqual(@as(?u21, null), toast.icon);
}

test "toast duration defaults, replaces and keeps persistent hints" {
    const testing = std.testing;
    var toast: Toast = .{};
    toast.store(.{ .text = "Copied" });
    try testing.expectEqual(@as(?u32, 3000), toast.timeout_ms);
    toast.store(.{ .text = "Reloaded", .duration_ms = 2000 });
    try testing.expectEqual(@as(?u32, 2000), toast.timeout_ms);
    toast.store(.{ .text = "Leader", .duration_ms = null });
    toast.pending = true;
    onTimer(&toast, &toast.popup, HIDE_TIMER_ID);
    try testing.expectEqual(@as(?u32, null), toast.timeout_ms);
    try testing.expect(toast.pending);
    toast.store(.{ .text = "Copied again" });
    try testing.expectEqual(@as(?u32, 3000), toast.timeout_ms);
}

test "toast replacement cancels queued speech while deferred pending speech is restaged" {
    var toast: Toast = .{};
    toast.store(.{ .text = "Copied" });
    const first = toast.uia_message_version;
    toast.uia_staged_version = first;
    toast.popup.uia_view.announcement.stage("Copied");
    toast.popup.uia_view.dirty();
    try std.testing.expect(toast.popup.uia_view.announcement.pending);
    try std.testing.expectEqual(first, toast.uia_staged_version.?);
    toast.deferUntilShown();
    try std.testing.expect(toast.uia_staged_version == null);
    try std.testing.expect(!toast.popup.uia_view.announcement.pending);
    toast.store(.{ .text = "Reloaded" });
    try std.testing.expect(toast.uia_message_version != first);
    try std.testing.expect(toast.uia_staged_version == null);
}

test "toast terminal owners and replacement never cancel unrelated feedback" {
    const testing = std.testing;
    const a: Owner = .{ .surface_id = 1, .kind = .sequence };
    var toast: Toast = .{ .pending = true, .owner = a };
    toast.hideOwned(.{ .surface_id = 2, .kind = .sequence });
    toast.hideOwned(.{ .surface_id = 1, .kind = .table });
    try testing.expect(toast.pending);
    toast.hideForSurface(2);
    try testing.expect(toast.pending);
    toast.hideForSurface(1);
    try testing.expect(!toast.pending);
    toast.store(.{ .text = "Copied" });
    toast.pending = true;
    toast.hideOwned(a);
    try testing.expect(toast.pending);
}

test "toast deferred feedback, deadlines and late messages respect cancellation" {
    const testing = std.testing;
    var toast: Toast = .{};
    toast.popup.visible = true;
    toast.timeout_deadline = 2000;
    try testing.expect(!toast.timeoutDue(1999));
    try testing.expect(toast.timeoutDue(2000));
    try testing.expect(!toast.applyDisposition(.deferred));
    try testing.expect(toast.pending and !toast.popup.visible);
    try testing.expect(toast.timeout_deadline == null);
    toast.store(.{ .text = "Persistent", .duration_ms = null });
    try testing.expect(!toast.timeoutDue(10_000));
    toast.store(.{ .text = "New timed", .duration_ms = 2000 });
    toast.pending = false;
    toast.popup.visible = true;
    toast.timeout_deadline = 5000;
    try testing.expect(!toast.timeoutDue(2000));
    try testing.expect(toast.timeoutDue(5000));
    try testing.expect(!toast.applyDisposition(.discard));
    _ = onMessage(&toast, &toast.popup, WM_SHOW_POSTED, 0, 0);
    onTimer(&toast, &toast.popup, WAIT_TIMER_ID);
    onTimer(&toast, &toast.popup, HIDE_TIMER_ID);
    try testing.expect(!toast.pending and !toast.popup.visible);
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
