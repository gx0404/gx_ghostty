//! Drawing helpers of the settings overlay: cards, switches, radio
//! buttons, chips, buttons, key caps, theme swatches and the font sample in
//! the Fluent look of `ui/style.zig`, with the hover, pressed and disabled
//! states of `ui/controls.zig` (pressed fainter than hovered). Everything
//! is in DIPs on a `d2d.Canvas`.
const std = @import("std");
const i18n = @import("../../../../gx/i18n.zig");
const ui_color = @import("../../../../gx/ui_color.zig");

pub const Measurements = struct {
    entries: [128]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    const Entry = struct { key: u64, size: d2d.Size };

    pub fn clear(self: *Measurements) void {
        self.len = 0;
        self.next = 0;
    }

    fn get(self: *const Measurements, key: u64) ?d2d.Size {
        for (self.entries[0..self.len]) |entry| if (entry.key == key) return entry.size;
        return null;
    }

    fn put(self: *Measurements, key: u64, size: d2d.Size) void {
        self.entries[self.next] = .{ .key = key, .size = size };
        self.len = @min(self.len + 1, self.entries.len);
        self.next = (self.next + 1) % self.entries.len;
    }

    pub fn measure(self: *Measurements, canvas: *d2d.Canvas, text: []const u8, text_style: d2d.TextStyle, width: f32) d2d.Size {
        const key = measurementKey(text, text_style, width, canvas.dpi, i18n.current());
        if (self.get(key)) |size| return size;
        const size = canvas.measureText(text, text_style, width);
        self.put(key, size);
        return size;
    }
};

fn measurementKey(text: []const u8, text_style: d2d.TextStyle, width: f32, dpi: f32, language: i18n.Language) u64 {
    var hash: std.hash.Wyhash = .init(0);
    const parameters = [_]u32{
        @intFromEnum(text_style.font),
        @intFromEnum(text_style.weight),
        @intFromBool(text_style.wrap),
        @bitCast(text_style.size),
        @bitCast(text_style.line_height),
        @bitCast(width),
        @bitCast(dpi),
        @intFromEnum(language),
        @intCast(text_style.family.len),
    };
    hash.update(std.mem.asBytes(&parameters));
    hash.update(text_style.family);
    hash.update(text);
    return hash.final();
}
const d2d = @import("../d2d.zig");
const controls = @import("../controls.zig");
const style = @import("../style.zig");
const swatch = @import("../../../../gx/theme_swatch.zig");

const Rect = d2d.Rect;
const Color = d2d.Color;
const Tokens = style.Tokens;

/// The state of a control: hovered, pressed, keyboard focus, disabled.
pub const State = controls.State;

pub const radius: f32 = 6;
pub const chip_height: f32 = 28;
pub const chip_gap: f32 = 6;
pub const button_height: f32 = 30;
pub const icon_button_size: f32 = 28;
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
    pub const delete: u21 = 0xE74D;
};

/// The red of errors in the status line (text on the panel).
pub fn errorColor(t: Tokens) Color {
    return ui_color.ensureContrast(t.critical, t.surface_raised, 4.5);
}

/// The green of success messages.
pub fn successColor(t: Tokens) Color {
    return ui_color.ensureContrast(t.success, t.surface_raised, 4.5);
}

/// The color of a warning line under a setting (a value the command line
/// overrides): text on a card.
pub fn cautionColor(t: Tokens) Color {
    return ui_color.ensureContrast(t.caution, t.surface, 4.5);
}

/// A settings card: a rounded panel with a hairline border, shaded when a
/// click on it does something and the pointer is on it.
pub fn card(canvas: *d2d.Canvas, rect: Rect, t: Tokens, state: State) void {
    const fill = if (state.disabled)
        t.surface
    else if (state.pressed)
        style.pressedOf(t.surface, t)
    else if (state.hover)
        style.hoverOf(t.surface, t)
    else
        t.surface;
    canvas.fillRoundedRect(rect, radius, fill);
    canvas.strokeRoundedRect(rect, radius, t.border, style.metrics.border_width);
}

/// The keyboard focus ring around `rect`, whose corners have `corner`.
pub fn focusRing(canvas: *d2d.Canvas, rect: Rect, corner: f32, t: Tokens) void {
    controls.focusRing(canvas, rect, corner, t);
}

/// A toggle switch at `rect` (`switch_width` x `switch_height`).
pub fn switchControl(canvas: *d2d.Canvas, rect: Rect, on: bool, state: State, t: Tokens) void {
    const r = rect.h / 2;
    const knob = rect.h - 8;
    if (on) {
        const fill = if (state.disabled)
            t.text_disabled
        else if (state.pressed)
            style.mix(t.accent, t.surface_raised, 0.2)
        else if (state.hover)
            style.hoverOf(t.accent, t)
        else
            t.accent;
        canvas.fillRoundedRect(rect, r, fill);
        // The knob stretches while pressed (WinUI).
        const w = if (state.pressed) knob + 3 else knob;
        canvas.fillRoundedRect(.{ .x = rect.x + rect.w - 4 - w, .y = rect.y + 4, .w = w, .h = knob }, knob / 2, t.on_accent);
    } else {
        const fill = if (state.disabled) t.surface_raised else if (state.pressed) t.pressed else if (state.hover) t.hover else t.surface_raised;
        const ink = if (state.disabled) t.text_disabled else t.text_secondary;
        canvas.fillRoundedRect(rect, r, fill);
        canvas.strokeRoundedRect(rect, r, ink, 1);
        const w = if (state.pressed) knob + 1 else knob - 2;
        canvas.fillRoundedRect(.{ .x = rect.x + 5, .y = rect.y + 5, .w = w, .h = knob - 2 }, (knob - 2) / 2, ink);
    }
}

/// A radio button centered in `rect` (18 x 18).
pub fn radio(canvas: *d2d.Canvas, rect: Rect, checked: bool, state: State, t: Tokens) void {
    const size: f32 = 18;
    const outer: Rect = .{ .x = rect.x + (rect.w - size) / 2, .y = rect.y + (rect.h - size) / 2, .w = size, .h = size };
    if (checked) {
        const fill = if (state.pressed) style.mix(t.accent, t.surface_raised, 0.2) else t.accent;
        canvas.fillRoundedRect(outer, size / 2, fill);
        // The dot grows under the pointer and shrinks while pressed (WinUI).
        const dot: f32 = if (state.pressed) 6 else if (state.hover) 10 else 8;
        canvas.fillRoundedRect(.{ .x = outer.x + (size - dot) / 2, .y = outer.y + (size - dot) / 2, .w = dot, .h = dot }, dot / 2, t.on_accent);
    } else {
        const fill = if (state.pressed) t.pressed else if (state.hover) t.hover else t.surface_raised;
        canvas.fillRoundedRect(outer, size / 2, fill);
        canvas.strokeRoundedRect(outer, size / 2, t.text_secondary, 1);
        if (state.pressed) {
            const dot: f32 = 10;
            canvas.fillRoundedRect(.{ .x = outer.x + (size - dot) / 2, .y = outer.y + (size - dot) / 2, .w = dot, .h = dot }, dot / 2, t.text_secondary);
        }
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
pub fn chipWidth(canvas: *d2d.Canvas, measurements: *Measurements, label: []const u8) f32 {
    var s = label_style;
    s.weight = .semibold;
    return @ceil(measurements.measure(canvas, label, s, 1000).width) + 24;
}

/// The width of the chips for `labels`, with `chip_gap` between them.
pub fn chipsWidth(canvas: *d2d.Canvas, measurements: *Measurements, labels: []const []const u8) f32 {
    var total: f32 = 0;
    for (labels, 0..) |label, i| {
        total += chipWidth(canvas, measurements, label);
        if (i > 0) total += chip_gap;
    }
    return total;
}

/// One choice of a segmented control.
pub fn chip(canvas: *d2d.Canvas, rect: Rect, label: []const u8, selected: bool, state: State, t: Tokens) void {
    var text = labelStyle(t);
    if (selected) {
        const fill = if (state.disabled)
            t.text_disabled
        else if (state.pressed)
            style.mix(t.accent, t.surface_raised, 0.2)
        else if (state.hover)
            style.hoverOf(t.accent, t)
        else
            t.accent;
        canvas.fillRoundedRect(rect, rect.h / 2, fill);
        text.color = t.on_accent;
        text.weight = .semibold;
    } else {
        const fill = if (state.disabled) t.surface_raised else if (state.pressed) t.pressed else if (state.hover) t.hover else t.surface_raised;
        canvas.fillRoundedRect(rect, rect.h / 2, fill);
        canvas.strokeRoundedRect(rect, rect.h / 2, t.border, 1);
        text.color = if (state.disabled) t.text_disabled else if (state.pressed) t.text_secondary else t.text;
    }
    canvas.drawText(label, rect, text);
    if (state.focused) focusRing(canvas, rect, rect.h / 2, t);
}

pub const ButtonKind = enum { normal, primary, subtle };

/// The width of a button with an optional icon and a label.
pub fn buttonWidth(canvas: *d2d.Canvas, measurements: *Measurements, label: []const u8, icon: ?u21) f32 {
    var w = @ceil(measurements.measure(canvas, label, label_style, 1000).width) + 28;
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
    state: State,
    t: Tokens,
) void {
    // A disabled primary button looks like a disabled normal one.
    const control_kind: controls.ButtonKind = switch (kind) {
        .normal => .standard,
        .primary => if (state.disabled) .standard else .accent,
        .subtle => .subtle,
    };
    const colors = controls.buttonColors(control_kind, state, t);
    if (colors.fill) |fill| canvas.fillRoundedRect(rect, 4, fill);
    if (colors.border) |border| canvas.strokeRoundedRect(rect, 4, border, 1);
    var text = labelStyle(t);
    text.color = colors.text;
    if (icon) |glyph| {
        if (label.len == 0) {
            canvas.drawIcon(glyph, rect, style.metrics.icon_size - 2, colors.text);
        } else {
            canvas.drawIcon(glyph, .{ .x = rect.x + 10, .y = rect.y, .w = 16, .h = rect.h }, 13, colors.text);
            canvas.drawText(label, .{ .x = rect.x + 30, .y = rect.y, .w = rect.w - 40, .h = rect.h }, text);
        }
    } else {
        canvas.drawText(label, rect, text);
    }
    if (state.focused) focusRing(canvas, rect, 4, t);
}

/// A subtle square button with an icon (reset, close).
pub fn iconButton(canvas: *d2d.Canvas, rect: Rect, glyph: u21, state: State, t: Tokens) void {
    controls.iconButton(canvas, rect, glyph, style.icon.small, state, t);
}

/// A key cap like `Esc`, followed by its description; returns the width
/// used.
pub fn keyHint(canvas: *d2d.Canvas, measurements: *Measurements, x: f32, y: f32, h: f32, key: []const u8, label: []const u8, t: Tokens) f32 {
    const small: d2d.TextStyle = .{ .size = style.font_size.caption, .color = t.text_secondary, .align_y = .center, .ellipsis = false };
    var cap_style = small;
    cap_style.align_x = .center;
    const cap_w = @ceil(measurements.measure(canvas, key, cap_style, 200).width) + 12;
    const cap: Rect = .{ .x = x, .y = y + (h - 20) / 2, .w = cap_w, .h = 20 };
    canvas.fillRoundedRect(cap, 4, t.surface);
    canvas.strokeRoundedRect(cap, 4, t.border, 1);
    canvas.drawText(key, cap, cap_style);
    const label_w = @ceil(measurements.measure(canvas, label, small, 400).width);
    canvas.drawText(label, .{ .x = x + cap_w + 6, .y = y, .w = label_w + 2, .h = h }, small);
    return cap_w + 6 + label_w;
}

/// The width `keyHint` uses.
pub fn keyHintWidth(canvas: *d2d.Canvas, measurements: *Measurements, key: []const u8, label: []const u8) f32 {
    const small: d2d.TextStyle = .{ .size = style.font_size.caption, .ellipsis = false };
    return @ceil(measurements.measure(canvas, key, small, 200).width) + 12 + 6 + @ceil(measurements.measure(canvas, label, small, 400).width);
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

/// The place of a swatch whose file was not read yet.
pub fn swatchPlaceholder(canvas: *d2d.Canvas, rect: Rect, t: Tokens) void {
    canvas.fillRoundedRect(rect, 4, t.surface_raised);
    canvas.strokeRoundedRect(rect, 4, t.border, 1);
}

/// The width `themeSwatch` needs.
pub const swatch_width: f32 = 26 + 6 * 8 + 2;

/// The text of the font sample: letters, digits that look alike in poor
/// fonts, the brackets and operators of code, and CJK (the GX defaults
/// map it to a CJK font).
pub const sample_text = "AaBb 0O 1lI {}[]() => != ~/.config 中文 漢字";

/// The font sample: `sample_text` in `family` at `size` DIPs on the
/// terminal colors.
pub fn fontSample(canvas: *d2d.Canvas, rect: Rect, family: []const u8, size: f32, t: Tokens) void {
    canvas.fillRoundedRect(rect, radius, t.background);
    canvas.strokeRoundedRect(rect, radius, t.border, style.metrics.border_width);
    canvas.pushClip(rect.inset(1, 1));
    defer canvas.popClip();
    canvas.drawText(sample_text, rect.inset(16, 0), .{
        .font = .mono,
        .family = family,
        .size = size,
        .color = t.foreground,
        .ellipsis = false,
    });
}

fn rgb(c: swatch.Rgb) Color {
    return Color.rgb(c.r, c.g, c.b);
}

test "measurement keys follow layout, locale and DPI but not colors" {
    const expect = std.testing.expect;
    const s: d2d.TextStyle = .{};
    const key = measurementKey("Apply", s, 400, 144, .en);
    var changed = s;
    changed.color = Color.rgb(0, 0, 0);
    try expect(key == measurementKey("Apply", changed, 400, 144, .en));
    try expect(key != measurementKey("Close", s, 400, 144, .en));
    try expect(key != measurementKey("Apply", s, 300, 144, .en));
    try expect(key != measurementKey("Apply", s, 400, 96, .en));
    try expect(key != measurementKey("Apply", s, 400, 144, .zh_CN));
    changed = s;
    changed.size = 18;
    try expect(key != measurementKey("Apply", changed, 400, 144, .en));
    changed = s;
    changed.family = "Consolas";
    try expect(key != measurementKey("Apply", changed, 400, 144, .en));
}

test "measurement cache is bounded and can be invalidated" {
    var cache: Measurements = .{};
    cache.put(1, .{ .width = 20, .height = 18 });
    try std.testing.expectEqual(@as(f32, 20), cache.get(1).?.width);
    for (2..130) |key| cache.put(key, .{ .width = @floatFromInt(key), .height = 18 });
    try std.testing.expectEqual(cache.entries.len, cache.len);
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expect(cache.get(129) != null);
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.len);
    try std.testing.expect(cache.get(129) == null);
}
