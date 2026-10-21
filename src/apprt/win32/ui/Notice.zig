//! A notice at the bottom of a window, after the WinUI InfoBar: a severity
//! (accent, success, caution or critical color with its icon), a title, a
//! body, up to two action buttons and a close button. It generalizes
//! `ShortcutNotice` for the configuration errors, reload results, child
//! process exits and key state hints of the app.
//!
//! It never takes the focus or Escape, pauses its timeout while the
//! pointer is over it (and gives 5 more seconds after), lasts at least the
//! system's notification time (`SPI_GETMESSAGEDURATION`), fades in over
//! 167 ms (`Popup.Options.motion`) and waits while a modal dialog has its
//! window disabled. Hidden or moving Quick owners defer feedback until
//! their next settled show; closing owners discard it. Deadlines reject
//! queued old timeout messages. Key names stay on one line (`glueChord`).
//!
//! Usage: embed a `Notice` in an address-stable owner (the window); call
//! `show` from the message loop, or `post` from a core callback (it shows
//! from the message loop, through `WM_SHOW_POSTED` on its own popup
//! window), with a `Placement` (the window, its terminal area and scale)
//! and `Content`. Move it with `reposition`, close it with `hide` and free
//! it with `deinit`. `Callbacks` report the action chosen and why it
//! closed. Timers `NT` (timeout) and `NW` (waiting for a dialog) live on
//! the notice's popup window.
const Notice = @This();

const std = @import("std");
const App = @import("../App.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const controls = @import("controls.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32_notice);

pub const Severity = enum { informational, success, warning, @"error" };

pub const max_actions = 2;

/// What a notice says. The texts are copied (`max_text` bytes in all).
pub const Content = struct {
    severity: Severity = .informational,
    title: []const u8,
    body: []const u8 = "",
    /// Labels of up to two buttons, the primary one first.
    actions: []const []const u8 = &.{},
    /// Hide after this long (at least the system notification time); null
    /// keeps it until it is closed.
    duration_ms: ?u32 = 8000,
};

pub const CloseReason = enum {
    timeout,
    close_button,
    /// An action button was chosen (`Callbacks.action` follows).
    action,
    /// `hide` was called.
    owner,
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    /// Action button `index` was chosen; the notice is hidden by now.
    action: ?*const fn (ctx: *anyopaque, notice: *Notice, index: usize) void = null,
    /// The notice closed.
    closed: ?*const fn (ctx: *anyopaque, notice: *Notice, reason: CloseReason) void = null,
};

/// Where a notice shows.
pub const Placement = struct {
    /// The window it belongs to.
    owner: w32.HWND,
    /// The area to center in, in client pixels of `owner`
    /// (`Window.surfaceRect`).
    area: w32.RECT,
    /// The owner's content scale (`Window.scale`).
    scale: f32,

    pub fn disposition(self: Placement, app: *const App) Disposition {
        if (app.quick_terminal) |qt| {
            if (qt.window.hwnd == self.owner) return qt.window.feedbackDisposition();
        }
        for (app.windows.items) |window| {
            if (window.hwnd == self.owner) return window.feedbackDisposition();
        }
        return .discard;
    }
};

pub const Disposition = enum { ready, deferred, discard };

/// Posted to the notice's own popup window by `post`.
pub const WM_SHOW_POSTED: u32 = w32.WM_APP + 39;
/// Timers on the popup window.
pub const TIMEOUT_TIMER_ID: usize = 0x4E54; // 'NT'
pub const WAIT_TIMER_ID: usize = 0x4E57; // 'NW'
const wait_ms = 250;
/// How long the notice stays after the pointer left it.
const linger_ms = 5000;
pub const max_text = 2048;

const Range = struct { start: u16 = 0, len: u16 = 0 };

popup: Popup = .{},
app: ?*App = null,
callbacks: ?Callbacks = null,
placement: ?Placement = null,

/// The content, stored back to back in `text`.
text: [max_text]u8 = undefined,
title: Range = .{},
body: Range = .{},
actions: [max_actions]Range = @splat(.{}),
action_count: u8 = 0,
severity: Severity = .informational,
duration_ms: ?u32 = null,
timeout_deadline: ?u64 = null,
/// Shown by `post`, or waiting for a dialog or a settled owner.
pending: bool = false,

hover: Target = .none,
pressed: Target = .none,

const Target = union(enum) {
    none,
    close,
    action: u8,

    fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

/// Show `content` now (from the message loop).
pub fn show(self: *Notice, app: *App, placement: Placement, content: Content, callbacks: ?Callbacks) void {
    self.app = app;
    self.placement = placement;
    self.callbacks = callbacks;
    self.store(content);
    self.pending = true;
    self.showStored();
}

/// Show `content` from the message loop: safe to call from core callbacks
/// that must not open windows or pump messages.
pub fn post(self: *Notice, app: *App, placement: Placement, content: Content, callbacks: ?Callbacks) void {
    self.app = app;
    self.placement = placement;
    self.callbacks = callbacks;
    self.store(content);
    self.pending = true;
    if (!self.applyDisposition(placement.disposition(app))) return;
    if (!self.ensurePopup()) return;
    const hwnd = self.popup.hwnd orelse return;
    if (w32.PostMessageW(hwnd, WM_SHOW_POSTED, 0, 0) == 0) log.warn("cannot post a notice", .{});
}

/// Hide the notice (reported as `.owner`).
pub fn hide(self: *Notice) void {
    self.close(.owner);
}

/// Defer feedback without dismissing it. Its timeout starts again only
/// after the live owner finishes showing; closing owners discard it.
pub fn deferUntilShown(self: *Notice) void {
    self.pending = self.pending or self.popup.visible;
    self.timeout_deadline = null;
    if (self.popup.hwnd) |hwnd| {
        _ = w32.KillTimer(hwnd, TIMEOUT_TIMER_ID);
        _ = w32.KillTimer(hwnd, WAIT_TIMER_ID);
    }
    self.popup.hide();
}

pub fn onOwnerShown(self: *Notice, placement: Placement) void {
    self.placement = placement;
    self.showStored();
}

fn applyDisposition(self: *Notice, disposition: Disposition) bool {
    switch (disposition) {
        .ready => return true,
        .deferred => self.deferUntilShown(),
        .discard => self.hide(),
    }
    return false;
}

/// Whether the notice is on screen.
pub fn isVisible(self: *const Notice) bool {
    return self.popup.visible;
}

/// Follow the window (moved, resized, another DPI or language).
pub fn reposition(self: *Notice, placement: Placement) void {
    self.placement = placement;
    if (self.app) |app| if (!self.applyDisposition(placement.disposition(app))) return;
    if (!self.popup.visible) return;
    const rect = self.bounds() orelse return;
    self.popup.setBounds(rect);
    self.popup.invalidate();
}

pub fn deinit(self: *Notice) void {
    self.popup.destroy();
    self.* = .{};
}

fn tokens(self: *const Notice) style.Tokens {
    const app = self.app orelse return style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    return style.Tokens.fromConfig(&app.config);
}

fn ensurePopup(self: *Notice) bool {
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
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
        .motion = .{ .offset_y = 8 },
    }, .{
        .ctx = self,
        .paint = paint,
        .mouse = onMouse,
        .timer = onTimer,
        .message = onMessage,
    }) catch |err| {
        log.warn("cannot create a notice err={}", .{err});
        return false;
    };
    return true;
}

fn showStored(self: *Notice) void {
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
    self.hover = .none;
    self.pressed = .none;
    self.popup.applyTheme(self.tokens());
    self.popup.setAccessibleName(self.slice(self.title));
    const rect = self.bounds() orelse return;
    self.pending = false;
    self.popup.show(rect);
    self.popup.invalidate();
    self.armTimeout(self.durationMs());
}

fn durationMs(self: *const Notice) ?u32 {
    const ms = self.duration_ms orelse return null;
    var seconds: u32 = 5;
    if (SystemParametersInfoW(SPI_GETMESSAGEDURATION, 0, @ptrCast(&seconds), 0) == 0) seconds = 5;
    return @max(ms, seconds * 1000);
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn timeoutDue(self: *const Notice, now: u64) bool {
    const deadline = self.timeout_deadline orelse return false;
    return self.popup.visible and !self.pending and now >= deadline;
}

fn armTimeout(self: *Notice, ms: ?u32) void {
    self.timeout_deadline = if (ms) |duration| GetTickCount64() +| duration else null;
    const hwnd = self.popup.hwnd orelse return;
    if (ms) |duration| {
        _ = w32.SetTimer(hwnd, TIMEOUT_TIMER_ID, duration, null);
    } else {
        _ = w32.KillTimer(hwnd, TIMEOUT_TIMER_ID);
    }
}

fn close(self: *Notice, reason: CloseReason) void {
    const was_shown = self.popup.visible or self.pending;
    self.pending = false;
    self.timeout_deadline = null;
    if (self.popup.hwnd) |hwnd| {
        _ = w32.KillTimer(hwnd, TIMEOUT_TIMER_ID);
        _ = w32.KillTimer(hwnd, WAIT_TIMER_ID);
    }
    self.popup.hide();
    if (!was_shown) return;
    if (self.callbacks) |cb| if (cb.closed) |f| f(cb.ctx, self, reason);
}

// -----------------------------------------------------------------------
// Content
// -----------------------------------------------------------------------

fn slice(self: *const Notice, range: Range) []const u8 {
    return self.text[range.start..][0..range.len];
}

fn store(self: *Notice, content: Content) void {
    var end: usize = 0;
    self.title = self.append(&end, content.title, 256);
    // The body with its key names glued together.
    var glued: [1536]u8 = undefined;
    self.body = self.append(&end, glueChord(&glued, content.body), glued.len);
    self.action_count = @intCast(@min(content.actions.len, max_actions));
    for (content.actions[0..self.action_count], 0..) |label, i| {
        self.actions[i] = self.append(&end, label, 96);
    }
    self.severity = content.severity;
    self.duration_ms = content.duration_ms;
    self.timeout_deadline = null;
    if (self.popup.hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMEOUT_TIMER_ID);
}

fn append(self: *Notice, end: *usize, text: []const u8, limit: usize) Range {
    const room = @min(limit, self.text.len - end.*);
    const len = utf8Prefix(text, room);
    @memcpy(self.text[end.*..][0..len], text[0..len]);
    const range: Range = .{ .start = @intCast(end.*), .len = @intCast(len) };
    end.* += len;
    return range;
}

/// The length of the longest prefix of `text` of at most `max` bytes that
/// ends on a codepoint boundary.
fn utf8Prefix(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var len = max;
    while (len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
    return len;
}

/// `text` without an incomplete codepoint at its end.
fn trimPartial(text: []const u8) []const u8 {
    var start = text.len;
    while (start > 0 and text[start - 1] & 0xC0 == 0x80) start -= 1;
    if (start == 0) return text;
    const lead = start - 1;
    const len = std.unicode.utf8ByteSequenceLength(text[lead]) catch return text;
    return if (lead + len > text.len) text[0..lead] else text;
}

/// `text` with a word joiner (U+2060) on both sides of every "+", so
/// chords like "Ctrl+Shift+P" never break across lines. Cut to `buf`.
pub fn glueChord(buf: []u8, text: []const u8) []const u8 {
    const joiner = "\u{2060}";
    var out: usize = 0;
    for (text, 0..) |byte, i| {
        const glue = byte == '+' and i > 0 and i + 1 < text.len and text[i - 1] != ' ' and text[i + 1] != ' ';
        const need: usize = if (glue) 1 + 2 * joiner.len else 1;
        if (out + need > buf.len) break;
        if (glue) {
            @memcpy(buf[out..][0..joiner.len], joiner);
            out += joiner.len;
        }
        buf[out] = byte;
        out += 1;
        if (glue) {
            @memcpy(buf[out..][0..joiner.len], joiner);
            out += joiner.len;
        }
    }
    return trimPartial(buf[0..out]);
}

// -----------------------------------------------------------------------
// Layout and painting
// -----------------------------------------------------------------------

const layout = struct {
    const width: f32 = 560;
    const margin: f32 = style.space.l;
    const pad: f32 = style.space.l;
    const icon_box: f32 = 20;
    const text_x: f32 = pad + icon_box + style.space.m;
    const title_h: f32 = style.type_ramp.body_strong.line;
    const body_gap: f32 = style.space.xs;
    const actions_gap: f32 = style.space.m;
    const button_gap: f32 = style.space.s;
    const button_min: f32 = 64;
    const close_inset: f32 = style.space.s;
};

/// Where the parts of a notice go, in DIPs.
pub const Geometry = struct {
    width: f32,
    height: f32,
    icon: d2d.Rect,
    title: d2d.Rect,
    body: d2d.Rect,
    close: d2d.Rect,
    actions: [max_actions]d2d.Rect,
    action_count: usize,
};

/// The geometry of a notice `width` wide with a body `body_h` high and
/// buttons `button_widths` wide.
pub fn geometry(width: f32, body_h: f32, button_widths: []const f32) Geometry {
    const close_size = style.close_button.size;
    const text_w = @max(0, width - layout.text_x - layout.pad);
    var y = layout.pad;
    var g: Geometry = .{
        .width = width,
        .height = 0,
        .icon = .{ .x = layout.pad, .y = y, .w = layout.icon_box, .h = layout.title_h },
        .title = .{ .x = layout.text_x, .y = y, .w = @max(0, text_w - close_size + layout.pad - layout.close_inset), .h = layout.title_h },
        .body = .{ .x = layout.text_x, .y = 0, .w = text_w, .h = 0 },
        .close = .{ .x = width - layout.close_inset - close_size, .y = layout.close_inset, .w = close_size, .h = close_size },
        .actions = undefined,
        .action_count = @min(button_widths.len, max_actions),
    };
    y += layout.title_h;
    if (body_h > 0) {
        y += layout.body_gap;
        g.body = .{ .x = layout.text_x, .y = y, .w = text_w, .h = body_h };
        y += body_h;
    }
    if (g.action_count > 0) {
        y += layout.actions_gap;
        var x = layout.text_x;
        for (button_widths[0..g.action_count], 0..) |w, i| {
            g.actions[i] = .{ .x = x, .y = y, .w = w, .h = style.control.height };
            x += w + layout.button_gap;
        }
        y += style.control.height;
    }
    g.height = y + layout.pad;
    return g;
}

fn bodyStyle(color: d2d.Color) d2d.TextStyle {
    var s = style.type_ramp.body.text(color);
    s.align_y = .top;
    s.wrap = true;
    s.ellipsis = false;
    return s;
}

fn geometryFor(self: *const Notice, factory: *d2d.Factory, width: f32) Geometry {
    const text_w = @max(0, width - layout.text_x - layout.pad);
    const body = self.slice(self.body);
    const body_h = if (body.len > 0) @ceil(factory.measureText(body, bodyStyle(.{ .r = 0, .g = 0, .b = 0 }), text_w).height) else 0;
    var widths: [max_actions]f32 = undefined;
    for (self.actions[0..self.action_count], 0..) |range, i| {
        widths[i] = controls.buttonWidth(factory, self.slice(range), layout.button_min);
    }
    return geometry(width, body_h, widths[0..self.action_count]);
}

/// The notice's place in screen pixels: centered at the bottom of the
/// window's terminal area.
fn bounds(self: *Notice) ?w32.RECT {
    const placement = self.placement orelse return null;
    const app = self.app orelse return null;
    const factory = app.uiFactory() orelse return null;
    self.popup.setOwnerScale(placement.scale);
    const scale = self.popup.ownerScale();
    const area = placement.area;
    const area_w = style.dip(area.right - area.left, scale);
    const width = @max(0, @min(layout.width, area_w - 2 * layout.margin));
    const g = self.geometryFor(factory, width);
    const w = style.px(width, scale);
    const h = style.px(g.height, scale);
    var pt: w32.POINT = .{
        .x = area.left + @divTrunc(area.right - area.left - w, 2),
        .y = area.bottom - h - style.px(layout.margin, scale),
    };
    _ = w32.ClientToScreen(placement.owner, &pt);
    return .{ .left = pt.x, .top = pt.y, .right = pt.x + w, .bottom = pt.y + h };
}

fn severityColor(severity: Severity, t: style.Tokens) d2d.Color {
    return switch (severity) {
        .informational => t.accent,
        .success => t.success,
        .warning => t.caution,
        .@"error" => t.critical,
    };
}

fn severityIcon(severity: Severity) u21 {
    return switch (severity) {
        .informational => d2d.icons.info,
        .success => d2d.icons.completed,
        .warning => d2d.icons.warning,
        .@"error" => d2d.icons.error_badge,
    };
}

fn targetAt(g: Geometry, pos: d2d.Point) Target {
    if (g.close.contains(pos)) return .close;
    for (g.actions[0..g.action_count], 0..) |rect, i| {
        if (rect.contains(pos)) return .{ .action = @intCast(i) };
    }
    return .none;
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *Notice = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    const g = self.geometryFor(canvas.factory, size.width);
    const color = severityColor(self.severity, t);
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, style.mix(t.surface_raised, color, if (self.severity == .informational) 0.06 else 0.10));
    if (t.high_contrast) canvas.strokeRoundedRectPx(full, 0, t.border, 1);

    canvas.drawIcon(severityIcon(self.severity), g.icon, style.icon.standard, color);
    canvas.drawText(self.slice(self.title), g.title, style.type_ramp.body_strong.text(t.text));
    const body = self.slice(self.body);
    if (body.len > 0) canvas.drawText(body, g.body, bodyStyle(t.text));

    for (self.actions[0..self.action_count], 0..) |range, i| {
        const target: Target = .{ .action = @intCast(i) };
        controls.button(canvas, g.actions[i], self.slice(range), .standard, .{
            .hover = self.hover.eql(target),
            .pressed = self.pressed.eql(target) and self.hover.eql(target),
        }, t);
    }
    controls.closeButton(canvas, g.close, .{
        .hover = self.hover == .close,
        .pressed = self.pressed == .close and self.hover == .close,
    }, t);
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self: *Notice = @ptrCast(@alignCast(ctx));
    const factory = (self.app orelse return).uiFactory() orelse return;
    const g = self.geometryFor(factory, popup.sizeDip().width);
    const target = targetAt(g, event.pos);
    switch (event.kind) {
        .move => {
            // The pointer is over the notice: hold the timeout.
            self.timeout_deadline = null;
            if (popup.hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMEOUT_TIMER_ID);
            if (!target.eql(self.hover)) {
                self.hover = target;
                popup.invalidate();
            }
        },
        .leave => {
            self.hover = .none;
            self.pressed = .none;
            if (self.duration_ms != null) self.armTimeout(linger_ms);
            popup.invalidate();
        },
        .down => if (event.button == .left) {
            self.pressed = target;
            popup.invalidate();
        },
        .up => if (event.button == .left) {
            const pressed = self.pressed;
            self.pressed = .none;
            if (!pressed.eql(target) or target == .none) {
                popup.invalidate();
                return;
            }
            switch (target) {
                .none => {},
                .close => self.close(.close_button),
                .action => |index| {
                    self.close(.action);
                    if (self.callbacks) |cb| if (cb.action) |f| f(cb.ctx, self, index);
                },
            }
        },
        .double_click, .wheel => {},
    }
}

fn onTimer(ctx: *anyopaque, popup: *Popup, id: usize) void {
    const self: *Notice = @ptrCast(@alignCast(ctx));
    switch (id) {
        TIMEOUT_TIMER_ID => if (self.timeoutDue(GetTickCount64())) self.close(.timeout),
        WAIT_TIMER_ID => self.showStored(),
        else => if (popup.hwnd) |hwnd| {
            _ = w32.KillTimer(hwnd, id);
        },
    }
}

fn onMessage(ctx: *anyopaque, _: *Popup, msg: u32, _: usize, _: isize) bool {
    const self: *Notice = @ptrCast(@alignCast(ctx));
    if (msg != WM_SHOW_POSTED) return false;
    self.showStored();
    return true;
}

const SPI_GETMESSAGEDURATION: u32 = 0x2016;

extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;

test "glueChord keeps chords on one line" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const wj = "\u{2060}";
    try testing.expectEqualStrings("Ctrl" ++ wj ++ "+" ++ wj ++ "Shift" ++ wj ++ "+" ++ wj ++ "P", glueChord(&buf, "Ctrl+Shift+P"));
    // Spaced plus signs and text without them stay as they are.
    try testing.expectEqualStrings("1 + 1", glueChord(&buf, "1 + 1"));
    try testing.expectEqualStrings("no chords here", glueChord(&buf, "no chords here"));
    try testing.expectEqualStrings("+x", glueChord(&buf, "+x"));
    // Chinese text around a chord.
    const zh = glueChord(&buf, "\u{6309} Ctrl+C \u{590D}\u{5236}");
    try testing.expect(std.mem.indexOf(u8, zh, "Ctrl" ++ wj ++ "+" ++ wj ++ "C") != null);
    try testing.expect(std.unicode.utf8ValidateSlice(zh));
    // Cut at a character when the buffer is short.
    var small: [8]u8 = undefined;
    const cut = glueChord(&small, "Ctrl+Shift+P");
    try testing.expect(cut.len <= small.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("\u{6C49}", glueChord(&tiny, "\u{6C49}\u{6C49}"));
}

test "notice geometry stacks title, body and buttons" {
    const testing = std.testing;
    const plain = geometry(560, 0, &.{});
    try testing.expectEqual(@as(f32, 16 + 20 + 16), plain.height);
    try testing.expectEqual(@as(usize, 0), plain.action_count);
    try testing.expectEqual(@as(f32, 48), plain.title.x);
    // The close button sits in the top right corner and the title stops
    // before it.
    try testing.expectEqual(@as(f32, 560 - 8 - 32), plain.close.x);
    try testing.expect(plain.title.x + plain.title.w <= plain.close.x);

    const full = geometry(560, 40, &.{ 120, 90 });
    try testing.expectEqual(@as(f32, 16 + 20 + 4 + 40 + 12 + 32 + 16), full.height);
    try testing.expectEqual(@as(usize, 2), full.action_count);
    try testing.expectEqual(full.body.y + full.body.h + 12, full.actions[0].y);
    try testing.expectEqual(@as(f32, 48), full.actions[0].x);
    try testing.expectEqual(@as(f32, 48 + 120 + 8), full.actions[1].x);
    try testing.expectEqual(@as(f32, 32), full.actions[1].h);
    // At most two buttons.
    try testing.expectEqual(@as(usize, 2), geometry(400, 0, &.{ 70, 70, 70 }).action_count);
}

test "notice targets and content storage" {
    const testing = std.testing;
    const g = geometry(560, 20, &.{100});
    try testing.expect(targetAt(g, .{ .x = g.close.x + 4, .y = g.close.y + 4 }).eql(.close));
    try testing.expect(targetAt(g, .{ .x = g.actions[0].x + 1, .y = g.actions[0].y + 1 }).eql(.{ .action = 0 }));
    try testing.expect(targetAt(g, .{ .x = 1, .y = 1 }).eql(.none));

    var notice: Notice = .{};
    notice.store(.{
        .severity = .@"error",
        .title = "Configuration errors",
        .body = "Press Ctrl+Shift+, to open it.",
        .actions = &.{ "Open Configuration", "Reload", "Ignored third" },
        .duration_ms = null,
    });
    try testing.expectEqualStrings("Configuration errors", notice.slice(notice.title));
    try testing.expect(std.mem.indexOf(u8, notice.slice(notice.body), "\u{2060}+\u{2060}") != null);
    try testing.expectEqual(@as(u8, 2), notice.action_count);
    try testing.expectEqualStrings("Reload", notice.slice(notice.actions[1]));
    try testing.expectEqual(@as(?u32, null), notice.duration_ms);
    // Long texts are cut on a character boundary.
    notice.store(.{ .title = std.mem.asBytes(&@as([200]["\u{6C49}".len]u8, @splat("\u{6C49}".*))) });
    try testing.expect(notice.title.len <= 256);
    try testing.expect(std.unicode.utf8ValidateSlice(notice.slice(notice.title)));
}

test "notice deferred feedback and stale timeout messages do not resurrect it" {
    const testing = std.testing;
    var notice: Notice = .{};
    notice.popup.visible = true;
    notice.timeout_deadline = 2000;
    try testing.expect(!notice.timeoutDue(1999));
    try testing.expect(notice.timeoutDue(2000));
    try testing.expect(!notice.applyDisposition(.deferred));
    try testing.expect(notice.pending and !notice.popup.visible);
    try testing.expect(!notice.timeoutDue(10_000));
    try testing.expect(!notice.applyDisposition(.discard));
    _ = onMessage(&notice, &notice.popup, WM_SHOW_POSTED, 0, 0);
    onTimer(&notice, &notice.popup, WAIT_TIMER_ID);
    onTimer(&notice, &notice.popup, TIMEOUT_TIMER_ID);
    try testing.expect(!notice.pending and !notice.popup.visible);
    notice.store(.{ .title = "Persistent", .duration_ms = null });
    try testing.expect(notice.timeout_deadline == null);
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
