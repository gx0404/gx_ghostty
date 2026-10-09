//! The notice that default shortcuts for copying, pasting, searching or
//! splitting never reach Ghostty GX because another program or the input
//! method takes them (`shortcut_conflicts`): a non-activating `Popup` at
//! the bottom of the window that names the keys, points to the
//! alternatives (the copy and paste keys that still work, the right-click
//! menu and the command palette) and opens the keyboard shortcut sheet.
//! It hides after `duration_ms`, with its close button or when it opens
//! the sheet.
//!
//! The owning `Window` embeds this struct as `shortcut_notice`, forwards
//! `WM_TIMER` to `onTimer`, moves it with `reposition` and destroys it with
//! `deinit`; `App` shows it at most once per session.
const ShortcutNotice = @This();

const std = @import("std");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Keybinds = @import("Keybinds.zig");
const Palette = @import("Palette.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32);

/// Timer id used to hide the notice.
pub const TIMER_ID: usize = 0x534E; // 'SN'
const duration_ms: u32 = 20_000;

/// Layout in DIPs.
const layout = struct {
    const width: f32 = 520;
    const margin: f32 = 16;
    const pad: f32 = 16;
    const icon: f32 = 20;
    const text_x: f32 = pad + icon + 10;
    const title_h: f32 = 24;
    const gap: f32 = 6;
    const button_h: f32 = 30;
    const button_pad: f32 = 12;
    const close: f32 = 28;
    const radius: f32 = 6;
};

/// What the notice says: the taken keys and the keys of the alternatives,
/// formatted (e.g. "Ctrl+Shift+C"); empty when there is none.
pub const Content = struct {
    keys: []const u8,
    copy: []const u8 = "",
    paste: []const u8 = "",
    palette: []const u8 = "",
    sheet: []const u8 = "",
};

const Piece = enum { keys, copy, paste, palette, sheet };

popup: Popup = .{},

/// The `Content` pieces, stored back to back.
buf: [512]u8 = undefined,
ends: [std.enums.values(Piece).len]usize = @splat(0),

hover: Target = .none,
pressed: Target = .none,

const Target = enum { none, button, close };

fn window(self: *ShortcutNotice) *Window {
    return @alignCast(@fieldParentPtr("shortcut_notice", self));
}

fn tokens(self: *ShortcutNotice) style.Tokens {
    return style.Tokens.fromConfig(&self.window().app.config);
}

/// Destroy the popup (or forget it when Windows destroyed it with the
/// window).
pub fn deinit(self: *ShortcutNotice) void {
    Palette.releasePopup(&self.popup);
}

/// Show `content` at the bottom of the window.
pub fn show(self: *ShortcutNotice, content: Content) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    const t = self.tokens();
    if (!Palette.ensurePopup(&self.popup, win.app, hwnd, .{
        .activate = false,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
    }, .{
        .ctx = self,
        .paint = paint,
        .mouse = onMouse,
    })) return;
    self.popup.setBorderColor(t.border);

    var end: usize = 0;
    inline for (std.meta.fields(Content), 0..) |field, i| {
        const text = @field(content, field.name);
        const len = @min(text.len, self.buf.len - end);
        @memcpy(self.buf[end..][0..len], text[0..len]);
        end += len;
        self.ends[i] = end;
    }
    self.hover = .none;
    self.pressed = .none;

    const rect = self.bounds() orelse return;
    self.popup.show(rect);
    _ = w32.SetTimer(hwnd, TIMER_ID, duration_ms, null);
}

/// Hide the notice.
pub fn hide(self: *ShortcutNotice) void {
    self.popup.hide();
    if (self.window().hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMER_ID);
}

/// Handle the window's WM_TIMER; returns true when it was the notice's.
pub fn onTimer(self: *ShortcutNotice, timer_id: usize) bool {
    if (timer_id != TIMER_ID) return false;
    self.hide();
    return true;
}

/// Follow the window (moved, resized, other language or DPI).
pub fn reposition(self: *ShortcutNotice) void {
    if (!self.popup.visible or !Palette.popupAlive(&self.popup)) return;
    const rect = self.bounds() orelse return;
    self.popup.setBounds(rect);
}

fn piece(self: *const ShortcutNotice, p: Piece) []const u8 {
    const i = @intFromEnum(p);
    const start = if (i == 0) 0 else self.ends[i - 1];
    return self.buf[start..self.ends[i]];
}

/// The translated texts, formatted into fixed buffers.
const Texts = struct {
    line1_buf: [512]u8 = undefined,
    line2_buf: [512]u8 = undefined,
    button_buf: [128]u8 = undefined,
    title: []const u8 = "",
    line1: []const u8 = "",
    line2: []const u8 = "",
    button: []const u8 = "",
};

fn texts(self: *const ShortcutNotice, out: *Texts) void {
    out.title = i18n.tr("Some keyboard shortcuts do not reach Ghostty GX");
    out.line1 = fill(&out.line1_buf, i18n.tr("{keys}: another program or the input method takes these keys first."), .{
        .keys = self.piece(.keys),
    });
    const copy = self.piece(.copy);
    const paste = self.piece(.paste);
    const palette = self.piece(.palette);
    out.line2 = if (copy.len > 0 and paste.len > 0 and palette.len > 0)
        fill(&out.line2_buf, i18n.tr("Copy with {copy} and paste with {paste}, or use the right-click menu or the command palette ({palette})."), .{
            .copy = copy,
            .paste = paste,
            .palette = palette,
        })
    else
        i18n.tr("Use the right-click menu or the command palette instead.");
    const sheet = self.piece(.sheet);
    out.button = if (sheet.len > 0)
        fill(&out.button_buf, i18n.tr("Keyboard Shortcuts ({keys})"), .{ .keys = sheet })
    else
        i18n.tr("Keyboard Shortcuts");
}

fn fill(buf: []u8, template: []const u8, args: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    i18n.format(&writer, template, args) catch {};
    return writer.buffered();
}

fn titleStyle(t: style.Tokens) d2d.TextStyle {
    return .{ .size = style.font_size.body, .weight = .semibold, .color = t.text };
}

fn bodyStyle(t: style.Tokens) d2d.TextStyle {
    return .{ .size = style.font_size.caption, .color = t.text_secondary, .align_y = .top, .wrap = true, .ellipsis = false };
}

fn buttonStyle(t: style.Tokens) d2d.TextStyle {
    return .{ .size = style.font_size.caption, .weight = .semibold, .color = t.accent, .align_x = .center };
}

/// The heights of the two body lines at width `w`.
fn bodyHeights(self: *const ShortcutNotice, factory: *d2d.Factory, t: style.Tokens, w: f32) [2]f32 {
    var out: Texts = .{};
    self.texts(&out);
    return .{
        @ceil(factory.measureText(out.line1, bodyStyle(t), w).height),
        @ceil(factory.measureText(out.line2, bodyStyle(t), w).height),
    };
}

/// The notice's place in screen pixels: centered at the bottom of the
/// window's terminal area.
fn bounds(self: *ShortcutNotice) ?w32.RECT {
    const win = self.window();
    const hwnd = win.hwnd orelse return null;
    const factory = win.app.uiFactory() orelse return null;
    const t = self.tokens();
    self.popup.setOwnerScale(win.scale);
    const scale = self.popup.ownerScale();
    const area = win.surfaceRect();
    const area_w = style.dip(area.right - area.left, scale);
    const width = @max(0, @min(layout.width, area_w - 2 * layout.margin));
    const heights = self.bodyHeights(factory, t, width - layout.text_x - layout.pad);
    const height = layout.pad + layout.title_h + layout.gap + heights[0] + layout.gap + heights[1] +
        layout.gap * 2 + layout.button_h + layout.pad;

    const w = style.px(width, scale);
    const h = style.px(height, scale);
    var pt: w32.POINT = .{
        .x = area.left + @divTrunc(area.right - area.left - w, 2),
        .y = area.bottom - h - style.px(layout.margin, scale),
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    return .{ .left = pt.x, .top = pt.y, .right = pt.x + w, .bottom = pt.y + h };
}

fn closeRect(size: d2d.Size) d2d.Rect {
    return .{ .x = size.width - 8 - layout.close, .y = 8, .w = layout.close, .h = layout.close };
}

fn buttonRect(self: *ShortcutNotice, canvas: ?*d2d.Canvas, size: d2d.Size, t: style.Tokens) d2d.Rect {
    var out: Texts = .{};
    self.texts(&out);
    const factory = self.window().app.uiFactory();
    const text_w = if (canvas) |c|
        c.measureText(out.button, buttonStyle(t), 1000).width
    else if (factory) |f|
        f.measureText(out.button, buttonStyle(t), 1000).width
    else
        160;
    return .{
        .x = layout.text_x - layout.button_pad,
        .y = size.height - layout.pad - layout.button_h,
        .w = @ceil(text_w) + 2 * layout.button_pad,
        .h = layout.button_h,
    };
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self: *ShortcutNotice = @ptrCast(@alignCast(ctx));
    const size = popup.sizeDip();
    const t = self.tokens();
    const target: Target = if (closeRect(size).contains(event.pos))
        .close
    else if (self.buttonRect(null, size, t).contains(event.pos))
        .button
    else
        .none;
    switch (event.kind) {
        .move => if (target != self.hover) {
            self.hover = target;
            popup.invalidate();
        },
        .leave => {
            self.hover = .none;
            self.pressed = .none;
            popup.invalidate();
        },
        .down => if (event.button == .left) {
            self.pressed = target;
            popup.invalidate();
        },
        .up => if (event.button == .left) {
            const pressed = self.pressed;
            self.pressed = .none;
            if (pressed != target or target == .none) {
                popup.invalidate();
                return;
            }
            self.hide();
            if (target == .button and !Keybinds.show(self.window())) {
                log.warn("the keyboard shortcut sheet could not be opened", .{});
            }
        },
        .double_click, .wheel => {},
    }
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *ShortcutNotice = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

    var out: Texts = .{};
    self.texts(&out);
    canvas.drawIcon(d2d.icons.warning, .{ .x = layout.pad, .y = layout.pad, .w = layout.icon, .h = layout.title_h }, 16, t.caution);
    const text_w = @max(0, size.width - layout.text_x - layout.pad);
    canvas.drawText(out.title, .{
        .x = layout.text_x,
        .y = layout.pad,
        .w = @max(0, text_w - layout.close),
        .h = layout.title_h,
    }, titleStyle(t));

    const close = closeRect(size);
    if (self.hover == .close) canvas.fillRoundedRect(close, layout.radius, if (self.pressed == .close) t.pressed else t.hover);
    canvas.drawIcon(d2d.icons.cancel, close, 10, t.text_secondary);

    const heights = if (self.window().app.uiFactory()) |factory| self.bodyHeights(factory, t, text_w) else [2]f32{ 32, 32 };
    var y = layout.pad + layout.title_h + layout.gap;
    canvas.drawText(out.line1, .{ .x = layout.text_x, .y = y, .w = text_w, .h = heights[0] }, bodyStyle(t));
    y += heights[0] + layout.gap;
    canvas.drawText(out.line2, .{ .x = layout.text_x, .y = y, .w = text_w, .h = heights[1] }, bodyStyle(t));

    const button = self.buttonRect(canvas, size, t);
    if (self.hover == .button) canvas.fillRoundedRect(button, layout.radius, if (self.pressed == .button) t.pressed else t.hover);
    canvas.drawText(out.button, button, buttonStyle(t));
}
