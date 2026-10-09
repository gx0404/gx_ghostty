//! Drawing helpers of the settings overlay: cards, switches, radio
//! buttons, chips, buttons, key caps and theme swatches in the Fluent look
//! of `ui/style.zig`. Everything is in DIPs on a `d2d.Canvas`.
const std = @import("std");
const d2d = @import("../d2d.zig");
const style = @import("../style.zig");
const swatch = @import("swatch.zig");

const Rect = d2d.Rect;
const Color = d2d.Color;
const Tokens = style.Tokens;

pub const radius: f32 = 6;
pub const chip_height: f32 = 28;
pub const button_height: f32 = 30;
pub const switch_width: f32 = 40;
pub const switch_height: f32 = 20;

/// Extra glyphs of Segoe Fluent Icons / Segoe MDL2 Assets.
pub const icons = struct {
    pub const globe: u21 = 0xE774;
    pub const color: u21 = 0xE790;
    pub const font: u21 = 0xE8D2;
    pub const touch: u21 = 0xE7C9;
    pub const command_prompt: u21 = 0xE756;
    pub const info: u21 = 0xE946;
    pub const settings: u21 = d2d.icons.settings;
    pub const check: u21 = 0xE73E;
    pub const remove: u21 = 0xE738;
    pub const add: u21 = d2d.icons.add;
    pub const reset: u21 = 0xE72C;
    pub const open_file: u21 = 0xE8E5;
    pub const folder: u21 = 0xE838;
    pub const close: u21 = d2d.icons.close;
    pub const search: u21 = d2d.icons.search;
};

/// The red of errors in the status line.
pub fn errorColor(t: Tokens) Color {
    return if (t.dark) Color.hex(0xff99a4) else Color.hex(0xc42b1c);
}

/// The green of success messages.
pub fn successColor(t: Tokens) Color {
    return if (t.dark) Color.hex(0x6ccb5f) else Color.hex(0x0f7b0f);
}

/// A settings card: a rounded panel with a hairline border.
pub fn card(canvas: *d2d.Canvas, rect: Rect, t: Tokens, hover: bool) void {
    canvas.fillRoundedRect(rect, radius, if (hover) style.hoverOf(t.surface, t) else t.surface);
    canvas.strokeRoundedRect(rect, radius, t.border, style.metrics.border_width);
}

/// The keyboard focus ring around `rect`.
pub fn focusRing(canvas: *d2d.Canvas, rect: Rect, t: Tokens) void {
    canvas.strokeRoundedRect(rect.inset(-2, -2), radius + 2, t.accent, 2);
}

/// A toggle switch at `rect` (`switch_width` x `switch_height`).
pub fn switchControl(canvas: *d2d.Canvas, rect: Rect, on: bool, hover: bool, t: Tokens) void {
    const r = rect.h / 2;
    const knob = rect.h - 8;
    if (on) {
        canvas.fillRoundedRect(rect, r, if (hover) style.hoverOf(t.accent, t) else t.accent);
        canvas.fillRoundedRect(.{ .x = rect.x + rect.w - 4 - knob, .y = rect.y + 4, .w = knob, .h = knob }, knob / 2, t.on_accent);
    } else {
        canvas.fillRoundedRect(rect, r, if (hover) t.hover else t.surface_raised);
        canvas.strokeRoundedRect(rect, r, t.text_secondary, 1);
        canvas.fillRoundedRect(.{ .x = rect.x + 5, .y = rect.y + 5, .w = knob - 2, .h = knob - 2 }, (knob - 2) / 2, t.text_secondary);
    }
}

/// A radio button centered in `rect` (18 x 18).
pub fn radio(canvas: *d2d.Canvas, rect: Rect, checked: bool, hover: bool, t: Tokens) void {
    const size: f32 = 18;
    const outer: Rect = .{ .x = rect.x + (rect.w - size) / 2, .y = rect.y + (rect.h - size) / 2, .w = size, .h = size };
    if (checked) {
        canvas.fillRoundedRect(outer, size / 2, t.accent);
        const dot: f32 = if (hover) 10 else 8;
        canvas.fillRoundedRect(.{ .x = outer.x + (size - dot) / 2, .y = outer.y + (size - dot) / 2, .w = dot, .h = dot }, dot / 2, t.on_accent);
    } else {
        canvas.fillRoundedRect(outer, size / 2, if (hover) t.hover else t.surface_raised);
        canvas.strokeRoundedRect(outer, size / 2, t.text_secondary, 1);
    }
}

const label_style: d2d.TextStyle = .{
    .size = style.font_size.body,
    .align_x = .center,
    .align_y = .center,
    .ellipsis = false,
};

fn labelStyle(t: Tokens) d2d.TextStyle {
    var s = label_style;
    s.color = t.text;
    return s;
}

/// The width of a chip showing `label` (measured semibold, like a selected
/// chip).
pub fn chipWidth(canvas: *d2d.Canvas, label: []const u8) f32 {
    var s = label_style;
    s.weight = .semibold;
    return @ceil(canvas.measureText(label, s, 1000).width) + 24;
}

/// One choice of a segmented control.
pub fn chip(canvas: *d2d.Canvas, rect: Rect, label: []const u8, selected: bool, enabled: bool, hover: bool, t: Tokens) void {
    var text = labelStyle(t);
    if (selected) {
        canvas.fillRoundedRect(rect, rect.h / 2, if (hover) style.hoverOf(t.accent, t) else t.accent);
        text.color = t.on_accent;
        text.weight = .semibold;
    } else {
        canvas.fillRoundedRect(rect, rect.h / 2, if (hover and enabled) t.hover else t.surface_raised);
        canvas.strokeRoundedRect(rect, rect.h / 2, t.border, 1);
        text.color = if (enabled) t.text else t.text_disabled;
    }
    canvas.drawText(label, rect, text);
}

pub const ButtonKind = enum { normal, primary, subtle };

/// The width of a button with an optional icon and a label.
pub fn buttonWidth(canvas: *d2d.Canvas, label: []const u8, icon: ?u21) f32 {
    var w = @ceil(canvas.measureText(label, label_style, 1000).width) + 28;
    if (icon != null) w += 22;
    if (label.len == 0) w = button_height;
    return w;
}

pub fn button(
    canvas: *d2d.Canvas,
    rect: Rect,
    label: []const u8,
    icon: ?u21,
    kind: ButtonKind,
    enabled: bool,
    hover: bool,
    t: Tokens,
) void {
    var text = labelStyle(t);
    var fg = t.text;
    // A disabled primary button looks like a disabled normal one.
    switch (if (kind == .primary and !enabled) .normal else kind) {
        .primary => {
            canvas.fillRoundedRect(rect, 4, if (hover) style.hoverOf(t.accent, t) else t.accent);
            fg = t.on_accent;
        },
        .normal => {
            canvas.fillRoundedRect(rect, 4, if (hover and enabled) t.hover else t.surface);
            canvas.strokeRoundedRect(rect, 4, t.border, 1);
            fg = if (enabled) t.text else t.text_disabled;
        },
        .subtle => {
            if (hover and enabled) canvas.fillRoundedRect(rect, 4, t.hover);
            fg = if (enabled) t.text else t.text_disabled;
        },
    }
    text.color = fg;
    if (icon) |glyph| {
        if (label.len == 0) {
            canvas.drawIcon(glyph, rect, style.metrics.icon_size - 2, fg);
            return;
        }
        canvas.drawIcon(glyph, .{ .x = rect.x + 10, .y = rect.y, .w = 16, .h = rect.h }, 13, fg);
        canvas.drawText(label, .{ .x = rect.x + 30, .y = rect.y, .w = rect.w - 40, .h = rect.h }, text);
        return;
    }
    canvas.drawText(label, rect, text);
}

/// A key cap like `Esc`, followed by its description; returns the width
/// used.
pub fn keyHint(canvas: *d2d.Canvas, x: f32, y: f32, h: f32, key: []const u8, label: []const u8, t: Tokens) f32 {
    const small: d2d.TextStyle = .{ .size = style.font_size.caption, .color = t.text_secondary, .align_y = .center, .ellipsis = false };
    var cap_style = small;
    cap_style.align_x = .center;
    const cap_w = @ceil(canvas.measureText(key, cap_style, 200).width) + 12;
    const cap: Rect = .{ .x = x, .y = y + (h - 20) / 2, .w = cap_w, .h = 20 };
    canvas.fillRoundedRect(cap, 4, t.surface);
    canvas.strokeRoundedRect(cap, 4, t.border, 1);
    canvas.drawText(key, cap, cap_style);
    const label_w = @ceil(canvas.measureText(label, small, 400).width);
    canvas.drawText(label, .{ .x = x + cap_w + 6, .y = y, .w = label_w + 2, .h = h }, small);
    return cap_w + 6 + label_w;
}

/// The colors of a theme: its background with "Aa" in the foreground and
/// the six bright palette colors.
pub fn themeSwatch(canvas: *d2d.Canvas, rect: Rect, s: swatch.Swatch, t: Tokens) void {
    canvas.fillRoundedRect(rect, 4, rgb(s.background));
    canvas.strokeRoundedRect(rect, 4, t.border, 1);
    const text: d2d.TextStyle = .{ .size = 11, .weight = .semibold, .color = rgb(s.foreground), .align_x = .center, .align_y = .center, .ellipsis = false };
    canvas.drawText("Aa", .{ .x = rect.x + 2, .y = rect.y, .w = 22, .h = rect.h }, text);
    const dot: f32 = 6;
    var x = rect.x + 26;
    const y = rect.y + (rect.h - dot) / 2;
    for (1..7) |i| {
        canvas.fillRoundedRect(.{ .x = x, .y = y, .w = dot, .h = dot }, 1.5, rgb(s.color(i)));
        x += dot + 2;
    }
}

/// The width `themeSwatch` needs.
pub const swatch_width: f32 = 26 + 6 * 8 + 2;

fn rgb(c: swatch.Rgb) Color {
    return Color.rgb(c.r, c.g, c.b);
}
