//! Shared drawing of the controls of the custom-drawn UI, so popups,
//! dialogs and the chrome draw them alike from the `style` tokens:
//! `button`, `iconButton`, `closeButton`, `focusRing`,
//! `selectionIndicator`, `keycap`, `hairline`, and `ScrollIndicator`, a
//! thin scroll thumb that widens under the pointer and can be dragged.
//!
//! Geometry is in DIPs; edges are snapped to device pixels by the canvas
//! and strokes are whole pixels, so 125 % and 150 % stay sharp. Pressed
//! fills are fainter than hovered ones for every kind of button (Fluent;
//! the tokens `pressed` and `control_fill_pressed` of `gx.ui_tokens`); the
//! focus ring, WinUI's foreground outer and surface inner stroke, is
//! drawn only for keyboard focus (callers pass `State.focused` then). The
//! pure parts (`buttonColors`, `focusRingRects`, `indicatorRect`, the
//! `ScrollIndicator` geometry) are unit tested.
const std = @import("std");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

pub const State = struct {
    hover: bool = false,
    pressed: bool = false,
    /// Has the keyboard focus: draw the focus ring.
    focused: bool = false,
    disabled: bool = false,
};

pub const ButtonKind = enum {
    /// A bordered button on the control fill.
    standard,
    /// The default action: the accent fill.
    accent,
    /// No fill at rest (bar and inline buttons).
    subtle,
};

pub const ButtonColors = struct {
    fill: ?d2d.Color,
    border: ?d2d.Color,
    text: d2d.Color,
};

/// The colors of a button of `kind` in `state`.
pub fn buttonColors(kind: ButtonKind, state: State, t: style.Tokens) ButtonColors {
    if (state.disabled) return .{
        .fill = if (kind == .subtle) null else t.control_fill,
        .border = if (kind == .standard or t.high_contrast) t.border else null,
        .text = t.text_disabled,
    };
    const active = state.hover or state.pressed;
    return switch (kind) {
        .standard => .{
            .fill = if (state.pressed) t.control_fill_pressed else if (state.hover) t.control_fill_hover else t.control_fill,
            .border = t.control_border,
            .text = if (active and t.high_contrast) t.hover_text else if (state.pressed) t.text_secondary else t.text,
        },
        .accent => .{
            .fill = if (state.pressed)
                style.mix(t.accent, t.surface_raised, 0.2)
            else if (state.hover)
                style.mix(t.accent, t.surface_raised, 0.1)
            else
                t.accent,
            .border = if (t.high_contrast) t.border else null,
            .text = t.on_accent,
        },
        .subtle => .{
            .fill = if (state.pressed) t.pressed else if (state.hover) t.hover else null,
            .border = if (t.high_contrast and active) t.border else null,
            .text = if (active) t.hover_text else t.text,
        },
    };
}

/// A text button filling `rect` (usually `style.control.height` high).
pub fn button(canvas: *d2d.Canvas, rect: d2d.Rect, label: []const u8, kind: ButtonKind, state: State, t: style.Tokens) void {
    const r = canvas.snapRect(rect);
    const radius = style.radius.control;
    const colors = buttonColors(kind, state, t);
    if (colors.fill) |fill| canvas.fillRoundedRect(r, radius, fill);
    if (colors.border) |border| canvas.strokeRoundedRectPx(r, radius, border, 1);
    canvas.drawText(label, r.inset(style.space.m, 0), .{
        .size = style.font_size.body,
        .color = colors.text,
        .align_x = .center,
    });
    if (state.focused) focusRing(canvas, r, radius, t);
}

/// The width of a text button for `label`: the text and 12 DIPs on each
/// side, at least `min_width`.
pub fn buttonWidth(factory: *d2d.Factory, label: []const u8, min_width: f32) f32 {
    const text = factory.measureText(label, .{ .size = style.font_size.body }, 10_000).width;
    return @max(min_width, @ceil(text) + 2 * style.space.m);
}

/// A subtle button with an icon glyph of `glyph_size` centered in `rect`.
pub fn iconButton(canvas: *d2d.Canvas, rect: d2d.Rect, glyph: u21, glyph_size: f32, state: State, t: style.Tokens) void {
    const r = canvas.snapRect(rect);
    const colors = buttonColors(.subtle, state, t);
    if (colors.fill) |fill| canvas.fillRoundedRect(r, style.radius.control, fill);
    if (colors.border) |border| canvas.strokeRoundedRectPx(r, style.radius.control, border, 1);
    const glyph_color = if (state.disabled)
        t.text_disabled
    else if (state.hover or state.pressed)
        colors.text
    else
        t.text_secondary;
    canvas.drawIcon(glyph, r, glyph_size, glyph_color);
    if (state.focused) focusRing(canvas, r, style.radius.control, t);
}

/// A close button: the cancel glyph at 12 DIPs with a neutral hover fill
/// (WinUI; the window's caption close keeps its red).
pub fn closeButton(canvas: *d2d.Canvas, rect: d2d.Rect, state: State, t: style.Tokens) void {
    iconButton(canvas, rect, d2d.icons.cancel, style.close_button.glyph, state, t);
}

/// The two strokes of a focus ring around `rect` at `scale`: the inner
/// one right outside the control and the outer one around it, in whole
/// pixels (1 and 2 DIPs rounded, at least one pixel each).
pub const FocusRingRects = struct {
    inner: d2d.Rect,
    inner_width: f32,
    outer: d2d.Rect,
    outer_width: f32,
};

pub fn focusRingRects(rect: d2d.Rect, scale: f32) FocusRingRects {
    const base = d2d.snapRectTo(rect, scale);
    const inner_px = @max(1, @round(style.focus_ring.inner * scale));
    const outer_px = @max(1, @round(style.focus_ring.outer * scale));
    const inner_w = inner_px / scale;
    const outer_w = outer_px / scale;
    return .{
        .inner = outset(base, inner_w),
        .inner_width = inner_w,
        .outer = outset(base, inner_w + outer_w),
        .outer_width = outer_w,
    };
}

fn outset(r: d2d.Rect, d: f32) d2d.Rect {
    return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
}

/// The keyboard focus ring around `rect`, whose corners have `radius`.
pub fn focusRing(canvas: *d2d.Canvas, rect: d2d.Rect, radius: f32, t: style.Tokens) void {
    const rings = focusRingRects(rect, canvas.scale());
    canvas.strokeRoundedRect(rings.inner, radius + rings.inner_width, t.focus_stroke_inner, rings.inner_width);
    canvas.strokeRoundedRect(rings.outer, radius + rings.inner_width + rings.outer_width, t.focus_stroke, rings.outer_width);
}

/// The selection indicator of a selected row: `style.selection_indicator`
/// at the row's leading edge, vertically centered, shorter in short rows.
pub fn indicatorRect(row: d2d.Rect) d2d.Rect {
    const h = @max(0, @min(style.selection_indicator.height, row.h - style.space.s));
    return .{ .x = row.x, .y = row.y + (row.h - h) / 2, .w = style.selection_indicator.width, .h = h };
}

pub fn selectionIndicator(canvas: *d2d.Canvas, row: d2d.Rect, t: style.Tokens) void {
    const r = canvas.snapRect(indicatorRect(row));
    canvas.fillRoundedRect(r, r.w / 2, t.accent);
}

/// Key cap metrics in DIPs (as the shortcut chips of `trigger`).
pub const keycap_height: f32 = 20;
const keycap_padding: f32 = 6;

fn keycapStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.caption, .color = color, .align_x = .center, .ellipsis = false };
}

/// The width of a key cap for `label`.
pub fn keycapWidth(factory: *d2d.Factory, label: []const u8) f32 {
    const text = factory.measureText(label, keycapStyle(.{ .r = 0, .g = 0, .b = 0 }), 1000).width;
    return @max(keycap_height, @ceil(text) + 2 * keycap_padding);
}

/// A key cap ("Ctrl") starting at `x`, vertically centered on `center_y`;
/// returns its width.
pub fn keycap(canvas: *d2d.Canvas, x: f32, center_y: f32, label: []const u8, t: style.Tokens) f32 {
    const w = keycapWidth(canvas.factory, label);
    const r = canvas.snapRect(.{ .x = x, .y = center_y - keycap_height / 2, .w = w, .h = keycap_height });
    canvas.fillRoundedRect(r, style.radius.control, style.mix(t.surface_raised, t.foreground, 0.07));
    canvas.strokeRoundedRectPx(r, style.radius.control, t.border, 1);
    canvas.drawText(label, r, keycapStyle(t.text_secondary));
    return w;
}

/// A horizontal separator of one device pixel in the border color.
pub fn hairline(canvas: *d2d.Canvas, x: f32, y: f32, w: f32, t: style.Tokens) void {
    canvas.hairlineH(x, y, w, t.border);
}

/// A vertical separator of one device pixel in the border color.
pub fn hairlineVertical(canvas: *d2d.Canvas, x: f32, y: f32, h: f32, t: style.Tokens) void {
    canvas.hairlineV(x, y, h, t.border);
}

/// A thin scroll thumb over the right edge of a scrolling view (`view`,
/// DIPs; content `content` high, `viewport` of it visible, scrolled by
/// `offset`). It widens under the pointer; a press on it starts a drag, a
/// press on the track jumps there and drags from there.
pub const ScrollIndicator = struct {
    /// While dragging, where the thumb was grabbed (DIPs from its top).
    grab: ?f32 = null,
    hover: bool = false,

    /// Thumb widths at rest and while hovered or dragged, and the width
    /// of the strip that takes the pointer.
    pub const rest_width: f32 = 3;
    pub const active_width: f32 = 6;
    pub const hit_width: f32 = 12;
    pub const min_thumb: f32 = 24;
    const margin: f32 = 2;

    /// The strip of `view` the indicator takes the pointer in.
    pub fn track(view: d2d.Rect) d2d.Rect {
        return .{
            .x = view.x + view.w - hit_width,
            .y = view.y + margin,
            .w = hit_width,
            .h = @max(0, view.h - 2 * margin),
        };
    }

    /// The thumb in `track_rect`, or null when everything is visible.
    pub fn thumb(track_rect: d2d.Rect, content: f32, viewport: f32, offset: f32) ?d2d.Rect {
        if (content <= viewport or viewport <= 0 or track_rect.h <= 0) return null;
        const h = @min(track_rect.h, @max(min_thumb, track_rect.h * viewport / content));
        const range = track_rect.h - h;
        const y = track_rect.y + range * std.math.clamp(offset / (content - viewport), 0, 1);
        return .{ .x = track_rect.x, .y = y, .w = track_rect.w, .h = h };
    }

    /// The offset that puts the top of a thumb `thumb_h` high at
    /// `thumb_top`.
    pub fn offsetForThumb(track_rect: d2d.Rect, content: f32, viewport: f32, thumb_h: f32, thumb_top: f32) f32 {
        const range = track_rect.h - thumb_h;
        if (range <= 0 or content <= viewport) return 0;
        const share = std.math.clamp((thumb_top - track_rect.y) / range, 0, 1);
        return share * (content - viewport);
    }

    /// A press at `pos`: null when it is not on the indicator, else the
    /// offset to scroll to (unchanged on the thumb, the pointer's place on
    /// the track); the drag goes on with `drag` until `release`.
    pub fn press(self: *ScrollIndicator, view: d2d.Rect, content: f32, viewport: f32, offset: f32, pos: d2d.Point) ?f32 {
        const tr = track(view);
        if (!tr.contains(pos)) return null;
        const th = thumb(tr, content, viewport, offset) orelse return null;
        if (pos.y >= th.y and pos.y < th.y + th.h) {
            self.grab = pos.y - th.y;
            return offset;
        }
        self.grab = th.h / 2;
        return offsetForThumb(tr, content, viewport, th.h, pos.y - th.h / 2);
    }

    /// The pointer moved to `pos` while dragging: the offset to scroll
    /// to; null when not dragging.
    pub fn drag(self: *const ScrollIndicator, view: d2d.Rect, content: f32, viewport: f32, pos: d2d.Point) ?f32 {
        const grab = self.grab orelse return null;
        const tr = track(view);
        const th = thumb(tr, content, viewport, 0) orelse return null;
        return offsetForThumb(tr, content, viewport, th.h, pos.y - grab);
    }

    pub fn release(self: *ScrollIndicator) void {
        self.grab = null;
    }

    pub fn dragging(self: *const ScrollIndicator) bool {
        return self.grab != null;
    }

    /// Track the pointer for the hover width; whether that changed.
    pub fn updateHover(self: *ScrollIndicator, view: d2d.Rect, pos: d2d.Point) bool {
        const hover = track(view).contains(pos);
        defer self.hover = hover;
        return hover != self.hover;
    }

    pub fn draw(self: *const ScrollIndicator, canvas: *d2d.Canvas, view: d2d.Rect, content: f32, viewport: f32, offset: f32, t: style.Tokens) void {
        const tr = track(view);
        const th = thumb(tr, content, viewport, offset) orelse return;
        const active = self.hover or self.grab != null;
        const w = if (active) active_width else rest_width;
        const x = tr.x + tr.w - w - margin;
        if (active) {
            canvas.fillRoundedRect(canvas.snapRect(.{ .x = x, .y = tr.y, .w = w, .h = tr.h }), w / 2, t.overlay_hover);
        }
        const r = canvas.snapRect(.{ .x = x, .y = th.y, .w = w, .h = th.h });
        canvas.fillRoundedRect(r, w / 2, if (active) t.text_secondary else t.text_tertiary);
    }
};

const testing = std.testing;

fn testTokens() style.Tokens {
    return style.Tokens.fromTheme(
        d2d.Color.hex(0x1e1e2e),
        d2d.Color.hex(0xcdd6f4),
        d2d.Color.hex(0xf5e0dc),
        d2d.Color.hex(0x89b4fa),
        d2d.Color.hex(0x89b4fa),
    );
}

test "buttons: pressed is fainter than hovered, disabled is disabled" {
    const t = testTokens();
    const rest = buttonColors(.standard, .{}, t);
    const hover = buttonColors(.standard, .{ .hover = true }, t);
    const pressed = buttonColors(.standard, .{ .hover = true, .pressed = true }, t);
    const base = t.surface_raised;
    try testing.expect(style.contrast(hover.fill.?, base) > style.contrast(rest.fill.?, base));
    try testing.expect(style.contrast(pressed.fill.?, base) < style.contrast(hover.fill.?, base));
    try testing.expectEqual(t.control_border, rest.border.?);
    // Subtle and accent buttons too.
    const subtle_hover = buttonColors(.subtle, .{ .hover = true }, t);
    const subtle_pressed = buttonColors(.subtle, .{ .hover = true, .pressed = true }, t);
    try testing.expect(style.contrast(subtle_pressed.fill.?, base) < style.contrast(subtle_hover.fill.?, base));
    const accent_hover = buttonColors(.accent, .{ .hover = true }, t);
    const accent_pressed = buttonColors(.accent, .{ .hover = true, .pressed = true }, t);
    try testing.expect(style.contrast(accent_pressed.fill.?, base) < style.contrast(accent_hover.fill.?, base));
    const disabled = buttonColors(.accent, .{ .disabled = true, .hover = true }, t);
    try testing.expectEqual(t.text_disabled, disabled.text);
    // Subtle buttons have no fill at rest.
    try testing.expectEqual(@as(?d2d.Color, null), buttonColors(.subtle, .{}, t).fill);
    try testing.expectEqual(t.hover, buttonColors(.subtle, .{ .hover = true }, t).fill.?);
    try testing.expectEqual(t.on_accent, buttonColors(.accent, .{ .pressed = true }, t).text);
}

test "buttons in high contrast keep borders and use the highlight text" {
    const t = style.Tokens.fromSystem(.{});
    const hover = buttonColors(.subtle, .{ .hover = true }, t);
    try testing.expectEqual(t.hover_text, hover.text);
    try testing.expect(hover.border != null);
    try testing.expect(buttonColors(.accent, .{}, t).border != null);
}

test "the focus ring sits outside the control on whole pixels" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const control: d2d.Rect = .{ .x = 10.3, .y = 5.1, .w = 80, .h = 32 };
        const rings = focusRingRects(control, scale);
        const base = d2d.snapRectTo(control, scale);
        try testing.expect(rings.inner.x < base.x and rings.inner.x + rings.inner.w > base.x + base.w);
        try testing.expect(rings.outer.x < rings.inner.x);
        // Stroke widths are whole pixels.
        for ([_]f32{ rings.inner_width, rings.outer_width, rings.outer.x, rings.outer.y }) |v| {
            try testing.expectApproxEqAbs(@round(v * scale), v * scale, 1e-3);
        }
        try testing.expectApproxEqAbs(rings.inner_width + rings.outer_width, base.x - rings.outer.x, 1e-4);
    }
}

test "the selection indicator is centered and shrinks in short rows" {
    const tall = indicatorRect(.{ .x = 4, .y = 100, .w = 300, .h = 36 });
    try testing.expectEqual(@as(f32, 3), tall.w);
    try testing.expectEqual(@as(f32, 16), tall.h);
    try testing.expectEqual(@as(f32, 110), tall.y);
    try testing.expectEqual(@as(f32, 4), tall.x);
    const short = indicatorRect(.{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try testing.expectEqual(@as(f32, 12), short.h);
    try testing.expectEqual(@as(f32, 4), short.y);
}

test "scroll indicator geometry and dragging" {
    const view: d2d.Rect = .{ .x = 0, .y = 40, .w = 300, .h = 204 };
    const tr = ScrollIndicator.track(view);
    try testing.expectEqual(@as(f32, 288), tr.x);
    try testing.expectEqual(@as(f32, 200), tr.h);
    // Everything visible: no thumb.
    try testing.expectEqual(@as(?d2d.Rect, null), ScrollIndicator.thumb(tr, 100, 204, 0));
    // A quarter visible: a quarter of the track, at the top, then the bottom.
    const top = ScrollIndicator.thumb(tr, 816, 204, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 50), top.h, 1e-3);
    try testing.expectApproxEqAbs(tr.y, top.y, 1e-3);
    const bottom = ScrollIndicator.thumb(tr, 816, 204, 612).?;
    try testing.expectApproxEqAbs(tr.y + tr.h - 50, bottom.y, 1e-3);
    // Long content keeps the minimum thumb.
    try testing.expectEqual(ScrollIndicator.min_thumb, ScrollIndicator.thumb(tr, 100_000, 204, 0).?.h);
    // offsetForThumb inverts thumb.
    const mid = ScrollIndicator.thumb(tr, 816, 204, 306).?;
    try testing.expectApproxEqAbs(@as(f32, 306), ScrollIndicator.offsetForThumb(tr, 816, 204, mid.h, mid.y), 0.01);

    var indicator: ScrollIndicator = .{};
    // Not on the strip.
    try testing.expectEqual(@as(?f32, null), indicator.press(view, 816, 204, 0, .{ .x = 100, .y = 60 }));
    // On the thumb: same offset, dragging with the grab point.
    try testing.expectEqual(@as(?f32, 0), indicator.press(view, 816, 204, 0, .{ .x = 295, .y = 52 }));
    try testing.expect(indicator.dragging());
    const dragged = indicator.drag(view, 816, 204, .{ .x = 295, .y = 52 + 75 }).?;
    try testing.expectApproxEqAbs(@as(f32, 306), dragged, 0.01);
    // Dragging past the end clamps.
    try testing.expectApproxEqAbs(@as(f32, 612), indicator.drag(view, 816, 204, .{ .x = 0, .y = 1000 }).?, 0.01);
    indicator.release();
    try testing.expectEqual(@as(?f32, null), indicator.drag(view, 816, 204, .{ .x = 295, .y = 60 }));
    // On the track below the thumb: jump so the thumb centers there.
    const jumped = indicator.press(view, 816, 204, 0, .{ .x = 295, .y = 42 + 100 }).?;
    try testing.expectApproxEqAbs(@as(f32, 306), jumped, 0.01);
    try testing.expect(indicator.updateHover(view, .{ .x = 295, .y = 100 }) != indicator.updateHover(view, .{ .x = 295, .y = 100 }));
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
