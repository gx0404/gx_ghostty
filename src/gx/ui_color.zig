//! Color math of the Ghostty GX interface, shared by the win32 and GTK
//! apprts.
//!
//! - WCAG 2 contrast from linearized sRGB (`luminance`, `contrast`), and
//!   the smallest change that reaches a contrast ratio: of the OKLab
//!   lightness (`ensureContrast`, against several surfaces with
//!   `ensureContrastAll`) or of a mix (`mixToContrast`). Whether a
//!   background is dark goes by its gamma-encoded luma instead (`isDark`).
//! - The OKLab and OKLCH spaces (Björn Ottosson,
//!   https://bottosson.github.io/posts/oklab/) for perceptual lightness
//!   and chroma. Colors converted back that fall outside sRGB keep their
//!   lightness and hue and lose chroma until they fit.
//! - The accent of a theme (`pickAccent`): the first candidate (the
//!   cursor color, palette 4, palette 12) that is colorful and contrasts
//!   3:1 with the surface; else the first colorful one with its lightness
//!   moved to the readable side like libadwaita's standalone accent color
//!   (at most 0.5 on light surfaces, at least 0.85 on dark ones). Text on
//!   the accent is black or white (`onAccent`).
//!
//! Colors are sRGB with components 0..1 and a straight alpha; contrast
//! ignores alpha (composite translucent colors with `over` first). Only
//! depends on `std`.
const std = @import("std");

/// An extern struct: it has the layout of Direct2D's D2D1_COLOR_F, so the
/// win32 UI draws with it as it is (`d2d.Color`).
pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    /// A color from 8-bit sRGB components.
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = from8(r), .g = from8(g), .b = from8(b) };
    }

    /// A color from 0xRRGGBB.
    pub fn hex(value: u24) Color {
        return rgb(@truncate(value >> 16), @truncate(value >> 8), @truncate(value));
    }

    /// 0xRRGGBB with the components rounded; alpha is ignored.
    pub fn toHex(self: Color) u24 {
        const c = self.toRgb8();
        return @as(u24, c.r) << 16 | @as(u24, c.g) << 8 | c.b;
    }

    /// The components rounded to 8 bits; alpha is ignored.
    pub fn toRgb8(self: Color) Rgb8 {
        return .{ .r = to8(self.r), .g = to8(self.g), .b = to8(self.b) };
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        var c = self;
        c.a = a;
        return c;
    }

    /// This color with its components rounded to 8 bits, as displayed.
    pub fn quantize(self: Color) Color {
        return .{ .r = from8(to8(self.r)), .g = from8(to8(self.g)), .b = from8(to8(self.b)), .a = self.a };
    }
};

/// 8-bit sRGB components, as GTK CSS and GDI take them.
pub const Rgb8 = struct { r: u8, g: u8, b: u8 };

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn from8(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255;
}

/// `a` moved toward `b` by `t` (0 is `a`, 1 is `b`, clamped), per sRGB
/// component and alpha.
pub fn mix(a: Color, b: Color, t: f32) Color {
    const k = std.math.clamp(t, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * k,
        .g = a.g + (b.g - a.g) * k,
        .b = a.b + (b.b - a.b) * k,
        .a = a.a + (b.a - a.a) * k,
    };
}

/// `top` composited over `bottom`.
pub fn over(top: Color, bottom: Color) Color {
    const a = top.a + bottom.a * (1 - top.a);
    if (a <= 0) return Color.black.withAlpha(0);
    const below = bottom.a * (1 - top.a);
    return .{
        .r = (top.r * top.a + bottom.r * below) / a,
        .g = (top.g * top.a + bottom.g * below) / a,
        .b = (top.b * top.a + bottom.b * below) / a,
        .a = a,
    };
}

/// WCAG 2 relative luminance: 0 for black, 1 for white.
pub fn luminance(c: Color) f32 {
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

/// The WCAG 2 contrast ratio of two colors, 1 (none) to 21 (black on
/// white).
pub fn contrast(a: Color, b: Color) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// Whether `c` counts as a dark background: its gamma-encoded Rec. 709
/// luma is below one half. This is how the interface picks between its
/// dark and light variants; contrast uses `luminance`.
pub fn isDark(c: Color) bool {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.5;
}

fn linear(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn encode(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) 12.92 * c else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

pub const Oklab = struct { l: f32, a: f32, b: f32 };

pub const Oklch = struct {
    l: f32,
    c: f32,
    /// The hue angle in degrees, 0..360.
    h: f32,
};

pub fn toOklab(c: Color) Oklab {
    const r = linear(c.r);
    const g = linear(c.g);
    const b = linear(c.b);
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

pub fn toOklch(c: Color) Oklch {
    const lab = toOklab(c);
    var h = std.math.atan2(lab.b, lab.a) * 180 / std.math.pi;
    if (h < 0) h += 360;
    return .{ .l = lab.l, .c = std.math.hypot(lab.a, lab.b), .h = h };
}

/// The opaque sRGB color of `lab` (see `fromOklch` for colors outside
/// sRGB).
pub fn fromOklab(lab: Oklab) Color {
    var h = std.math.atan2(lab.b, lab.a) * 180 / std.math.pi;
    if (h < 0) h += 360;
    return fromOklch(.{ .l = lab.l, .c = std.math.hypot(lab.a, lab.b), .h = h });
}

/// The opaque sRGB color of `lch`. Lightness is clamped to 0..1; a color
/// outside sRGB keeps its lightness and hue and loses chroma until it
/// fits.
pub fn fromOklch(lch: Oklch) Color {
    const l = std.math.clamp(lch.l, 0, 1);
    const angle = lch.h * std.math.pi / 180;
    const cos = @cos(angle);
    const sin = @sin(angle);
    const c = @max(lch.c, 0);
    if (linearRgb(l, c * cos, c * sin)) |rgb| return encodeRgb(rgb);
    var lo: f32 = 0;
    var hi: f32 = c;
    for (0..24) |_| {
        const mid = (lo + hi) / 2;
        if (linearRgb(l, mid * cos, mid * sin) != null) lo = mid else hi = mid;
    }
    return encodeRgb(linearRgb(l, lo * cos, lo * sin) orelse .{ l * l * l, l * l * l, l * l * l });
}

/// The linear sRGB components of an OKLab color, or null when it falls
/// outside sRGB.
fn linearRgb(l: f32, a: f32, b: f32) ?[3]f32 {
    const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    const lc = l_ * l_ * l_;
    const mc = m_ * m_ * m_;
    const sc = s_ * s_ * s_;
    const rgb: [3]f32 = .{
        4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
        -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
        -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
    };
    const tolerance = 1e-5;
    for (rgb) |v| if (v < -tolerance or v > 1 + tolerance) return null;
    return rgb;
}

fn encodeRgb(rgb: [3]f32) Color {
    return .{ .r = encode(rgb[0]), .g = encode(rgb[1]), .b = encode(rgb[2]) };
}

/// The OKLCH chroma of `c`: about 0 for grays, 0.1 and more for vivid
/// colors.
pub fn chroma(c: Color) f32 {
    return toOklch(c).c;
}

/// `c` with its OKLCH chroma at most `max`, keeping its lightness and
/// hue.
pub fn limitChroma(c: Color, max: f32) Color {
    const lch = toOklch(c);
    if (lch.c <= max) return c;
    return fromOklch(.{ .l = lch.l, .c = max, .h = lch.h }).withAlpha(c.a);
}

/// `c` with its OKLab lightness moved as little as possible to contrast at
/// least `ratio` with `against`: away from `against` on the side `c` is
/// on, or on the other side when that one cannot reach `ratio`. Returned
/// unchanged when it already does. An adjusted color is rounded to 8-bit
/// components and checked after rounding, so the floor holds as
/// displayed. When no lightness reaches `ratio`, the result is black or
/// white, whichever contrasts more. Alpha is kept.
pub fn ensureContrast(c: Color, against: Color, ratio: f32) Color {
    if (contrast(c, against) >= ratio) return c;
    const can_lighten = contrast(Color.white, against) >= ratio;
    const can_darken = contrast(Color.black, against) >= ratio;
    const lighten = if (can_lighten and can_darken)
        luminance(c) >= luminance(against)
    else if (can_lighten or can_darken)
        can_lighten
    else
        return (if (contrast(Color.white, against) >= contrast(Color.black, against)) Color.white else Color.black).withAlpha(c.a);

    const lch = toOklch(c);
    var fail = lch.l;
    var pass: f32 = if (lighten) 1 else 0;
    var best = if (lighten) Color.white else Color.black;
    for (0..24) |_| {
        const mid = (fail + pass) / 2;
        const candidate = fromOklch(.{ .l = mid, .c = lch.c, .h = lch.h }).quantize();
        if (contrast(candidate, against) >= ratio) {
            pass = mid;
            best = candidate;
        } else {
            fail = mid;
        }
    }
    return best.withAlpha(c.a);
}

/// `ensureContrast` against every color of `against`, such as all the
/// surfaces a text is drawn on: adjusted against the one it contrasts
/// least with. For surfaces on the same side of `c` (all darker or all
/// lighter) that one decides and the others follow; otherwise up to three
/// rounds, keeping the last adjustment.
pub fn ensureContrastAll(c: Color, against: []const Color, ratio: f32) Color {
    var out = c;
    for (0..3) |_| {
        var worst: ?Color = null;
        var lowest = ratio;
        for (against) |surface| {
            const value = contrast(out, surface);
            if (value < lowest) {
                lowest = value;
                worst = surface;
            }
        }
        out = ensureContrast(out, worst orelse break, ratio);
    }
    return out;
}

/// `mix(a, b, t)` with the smallest `t` from `t_min` up that contrasts at
/// least `ratio` with `against`, rounded to 8-bit components when `t`
/// had to grow; null when even `b` does not reach `ratio`. Assumes the
/// contrast grows toward `b`, as when `against` is `a`.
pub fn mixToContrast(a: Color, b: Color, t_min: f32, against: Color, ratio: f32) ?Color {
    const start = mix(a, b, t_min);
    if (contrast(start, against) >= ratio) return start;
    var best = b.quantize();
    if (contrast(best, against) < ratio) return null;
    var fail = std.math.clamp(t_min, 0, 1);
    var pass: f32 = 1;
    for (0..24) |_| {
        const mid = (fail + pass) / 2;
        const candidate = mix(a, b, mid).quantize();
        if (contrast(candidate, against) >= ratio) {
            pass = mid;
            best = candidate;
        } else {
            fail = mid;
        }
    }
    return best;
}

/// The least OKLCH chroma of an accent candidate.
pub const accent_min_chroma: f32 = 0.05;

/// The least contrast of an accent with the surface it is drawn on.
pub const accent_min_contrast: f32 = 3;

/// The accent when no candidate is given: the Windows default accent
/// blue.
pub const default_accent = Color.hex(0x0067c0);

/// The accent for a surface (see the file header): `candidates` in order
/// of preference, null for colors the theme does not set.
pub fn pickAccent(candidates: []const ?Color, against: Color) Color {
    for (candidates) |candidate| {
        const c = candidate orelse continue;
        if (chroma(c) >= accent_min_chroma and contrast(c, against) >= accent_min_contrast) return c;
    }
    for (candidates) |candidate| {
        const c = candidate orelse continue;
        const lch = toOklch(c);
        if (lch.c < accent_min_chroma) continue;
        const l = if (isDark(against)) @max(lch.l, 0.85) else @min(lch.l, 0.5);
        const moved = fromOklch(.{ .l = l, .c = lch.c, .h = lch.h }).withAlpha(c.a);
        return ensureContrast(moved, against, accent_min_contrast);
    }
    for (candidates) |candidate| {
        const c = candidate orelse continue;
        return ensureContrast(c, against, accent_min_contrast);
    }
    return ensureContrast(default_accent, against, accent_min_contrast);
}

/// Text on `accent`: black or white, whichever contrasts more.
pub fn onAccent(accent: Color) Color {
    return if (contrast(Color.white, accent) >= contrast(Color.black, accent)) Color.white else Color.black;
}

const testing = std.testing;

fn expectNear(expected: f32, actual: f32, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "hex, toHex and quantize" {
    const c = Color.hex(0x1e66f5);
    try testing.expectEqual(@as(u24, 0x1e66f5), c.toHex());
    try testing.expectEqual(Rgb8{ .r = 0x1e, .g = 0x66, .b = 0xf5 }, c.toRgb8());
    const q = mix(Color.black, Color.white, 0.5).quantize();
    try testing.expectEqual(@as(u24, 0x808080), q.toHex());
    try testing.expectEqual(q, q.quantize());
    // Out-of-range components clamp.
    try testing.expectEqual(@as(u24, 0xff0000), (Color{ .r = 1.5, .g = -0.2, .b = 0 }).toHex());
}

test "mix and over" {
    try testing.expectEqual(@as(u24, 0x808080), mix(Color.black, Color.white, 0.5).toHex());
    try testing.expectEqual(Color.white, mix(Color.black, Color.white, 2));
    try testing.expectEqual(Color.black, mix(Color.black, Color.white, -1));
    const half = Color.white.withAlpha(0.5);
    try testing.expectEqual(@as(u24, 0x808080), over(half, Color.black).toHex());
    try testing.expectEqual(@as(f32, 1), over(half, Color.black).a);
    try testing.expectEqual(Color.black, over(Color.white.withAlpha(0), Color.black));
    try testing.expectEqual(@as(f32, 0), over(Color.white.withAlpha(0), Color.black.withAlpha(0)).a);
}

test "luminance and contrast follow WCAG 2" {
    try expectNear(0, luminance(Color.black), 1e-6);
    try expectNear(1, luminance(Color.white), 1e-5);
    try expectNear(21, contrast(Color.black, Color.white), 1e-3);
    try expectNear(21, contrast(Color.white, Color.black), 1e-3);
    // The usual examples: #777 on white is just under AA, #767676 is the
    // lightest gray that passes.
    try expectNear(4.48, contrast(Color.hex(0x777777), Color.white), 0.01);
    try testing.expect(contrast(Color.hex(0x767676), Color.white) >= 4.5);
    try expectNear(1, contrast(Color.hex(0x89b4fa), Color.hex(0x89b4fa)), 1e-6);
}

test "isDark classifies by gamma luma" {
    try testing.expect(isDark(Color.hex(0x1f1f28)));
    try testing.expect(isDark(Color.hex(0x000000)));
    try testing.expect(!isDark(Color.hex(0xeff1f5)));
    try testing.expect(!isDark(Color.hex(0xfdf6e3)));
}

test "OKLab and OKLCH of known colors" {
    const red = toOklab(Color.hex(0xff0000));
    try expectNear(0.62796, red.l, 1e-3);
    try expectNear(0.22486, red.a, 1e-3);
    try expectNear(0.12585, red.b, 1e-3);
    const red_lch = toOklch(Color.hex(0xff0000));
    try expectNear(0.25768, red_lch.c, 1e-3);
    try expectNear(29.23, red_lch.h, 0.1);
    const white = toOklab(Color.white);
    try expectNear(1, white.l, 1e-3);
    try expectNear(0, white.a, 1e-3);
    try expectNear(0, white.b, 1e-3);
    try expectNear(0, toOklab(Color.black).l, 1e-6);
    // Grays have no chroma, saturated colors plenty.
    try testing.expect(chroma(Color.hex(0x808080)) < 1e-3);
    try testing.expect(chroma(Color.hex(0xf5e0dc)) < accent_min_chroma);
    try testing.expect(chroma(Color.hex(0x89b4fa)) > 0.1);
}

test "OKLab round trips" {
    for ([_]u24{ 0x000000, 0xffffff, 0x1f1f28, 0x89b4fa, 0xf38ba8, 0x00ff00, 0x0067c0, 0xfdf6e3, 0x123456 }) |value| {
        const c = Color.hex(value);
        try testing.expectEqual(value, fromOklab(toOklab(c)).toHex());
        try testing.expectEqual(value, fromOklch(toOklch(c)).toHex());
    }
}

test "fromOklch maps colors outside sRGB into it" {
    const c = fromOklch(.{ .l = 0.7, .c = 0.4, .h = 150 });
    for ([_]f32{ c.r, c.g, c.b }) |v| try testing.expect(v >= 0 and v <= 1);
    const back = toOklch(c);
    try expectNear(0.7, back.l, 0.01);
    try expectNear(150, back.h, 2);
    try testing.expect(back.c < 0.4);
    // Lightness out of range clamps.
    try testing.expectEqual(@as(u24, 0xffffff), fromOklch(.{ .l = 1.5, .c = 0, .h = 0 }).toHex());
    try testing.expectEqual(@as(u24, 0x000000), fromOklch(.{ .l = -1, .c = 0.2, .h = 0 }).toHex());
}

test "limitChroma keeps lightness and hue" {
    const vivid = Color.hex(0x00a2ff);
    const muted = limitChroma(vivid, 0.04);
    const before = toOklch(vivid);
    const after = toOklch(muted);
    try testing.expect(after.c <= 0.0405);
    try expectNear(before.l, after.l, 0.01);
    try expectNear(before.h, after.h, 3);
    try testing.expectEqual(Color.hex(0x808080), limitChroma(Color.hex(0x808080), 0.04));
}

test "ensureContrast leaves good colors alone" {
    const fg = Color.hex(0xcdd6f4);
    try testing.expectEqual(fg, ensureContrast(fg, Color.hex(0x1e1e2e), 4.5));
}

test "ensureContrast moves lightness away from the background" {
    const dark_bg = Color.hex(0x1e1e2e);
    const dim = ensureContrast(Color.hex(0x45475a), dark_bg, 4.5);
    try testing.expect(contrast(dim, dark_bg) >= 4.5);
    try testing.expect(luminance(dim) > luminance(Color.hex(0x45475a)));
    // Just enough: a slightly darker color fails.
    const lch = toOklch(dim);
    const less = fromOklch(.{ .l = lch.l - 0.02, .c = lch.c, .h = lch.h });
    try testing.expect(contrast(less, dark_bg) < 4.5);

    const light_bg = Color.hex(0xfdf6e3);
    const pale = Color.hex(0x93a1a1);
    const darker = ensureContrast(pale, light_bg, 4.5);
    try testing.expect(contrast(darker, light_bg) >= 4.5);
    try testing.expect(luminance(darker) < luminance(pale));
    // The result is what an 8-bit display shows.
    try testing.expectEqual(darker, darker.quantize());
}

test "ensureContrast keeps the hue of colored text" {
    const bg = Color.hex(0x101116);
    const red = Color.hex(0x5c1f24);
    const fixed = ensureContrast(red, bg, 4.5);
    try testing.expect(contrast(fixed, bg) >= 4.5);
    try expectNear(toOklch(red).h, toOklch(fixed).h, 8);
    try testing.expectEqual(@as(f32, 0.5), ensureContrast(red.withAlpha(0.5), bg, 4.5).a);
}

test "ensureContrast crosses to the other side when it must" {
    // Lighter than a light gray, but nothing lighter reaches 4.5:1.
    const bg = Color.hex(0xb0b0b0);
    const fixed = ensureContrast(Color.hex(0xc0c0c0), bg, 4.5);
    try testing.expect(contrast(fixed, bg) >= 4.5);
    try testing.expect(luminance(fixed) < luminance(bg));
    // No color reaches 21:1 with a mid gray: the best of black and white.
    const mid = Color.hex(0x777777);
    try testing.expectEqual(Color.black, ensureContrast(Color.hex(0x707070), mid, 21));
}

test "ensureContrast reaches the floor for hard pairs, as displayed" {
    for ([_][2]u24{
        .{ 0x585b70, 0x1e1e2e }, // dim text on a dark theme
        .{ 0xacb0be, 0xeff1f5 }, // dim text on a light theme
        .{ 0x0000ee, 0x000000 }, // xterm blue on black
        .{ 0x808080, 0x808080 }, // the same color
    }) |pair| {
        const c = Color.hex(pair[0]);
        const against = Color.hex(pair[1]);
        for ([_]f32{ 3, 4.5 }) |ratio| {
            const out = ensureContrast(c, against, ratio);
            try testing.expect(contrast(out, against) >= ratio);
            try testing.expect(contrast(out.quantize(), against) >= ratio);
        }
    }
}

test "ensureContrastAll meets every surface" {
    const dark_bg = Color.hex(0x1e1e2e);
    const raised = mix(dark_bg, Color.white, 0.10);
    const dim = Color.hex(0x585b70);
    const out = ensureContrastAll(dim, &.{ dark_bg, raised }, 4.5);
    try testing.expect(contrast(out, dark_bg) >= 4.5);
    try testing.expect(contrast(out, raised) >= 4.5);
    // The closest surface decides: the same as against it alone.
    try testing.expectEqual(ensureContrast(dim, raised, 4.5), out);
    // Enough everywhere: unchanged.
    try testing.expectEqual(Color.white, ensureContrastAll(Color.white, &.{ dark_bg, raised }, 4.5));
    try testing.expectEqual(dim, ensureContrastAll(dim, &.{}, 4.5));
}

test "mixToContrast finds the smallest mix that reaches a ratio" {
    const bg = Color.hex(0x1f1f28);
    // Enough already at t_min.
    try testing.expectEqual(mix(bg, Color.black, 0.5), mixToContrast(bg, Color.black, 0.5, bg, 1.05).?);
    const strip = mixToContrast(bg, Color.black, 0.32, bg, 1.12).?;
    try testing.expect(contrast(strip, bg) >= 1.12);
    try testing.expect(contrast(strip, bg) < 1.14);
    try testing.expect(luminance(strip) < luminance(mix(bg, Color.black, 0.32)));
    // Black cannot get darker.
    try testing.expectEqual(@as(?Color, null), mixToContrast(Color.black, Color.black, 0.5, Color.black, 1.12));
}

test "pickAccent takes the first colorful candidate with enough contrast" {
    // GX Mocha: the rosewater cursor is almost gray, palette 4 is used.
    const surface = mix(Color.hex(0x1f1f28), Color.white, 0.10);
    const accent = pickAccent(&.{ Color.hex(0xf5e0dc), Color.hex(0x89b4fa), Color.hex(0x89b4fa) }, surface);
    try testing.expectEqual(@as(u24, 0x89b4fa), accent.toHex());
    // A colorful cursor color wins.
    try testing.expectEqual(@as(u24, 0xf38ba8), pickAccent(&.{ Color.hex(0xf38ba8), Color.hex(0x89b4fa) }, surface).toHex());
    // Missing candidates are skipped.
    try testing.expectEqual(@as(u24, 0x89b4fa), pickAccent(&.{ null, Color.hex(0x89b4fa) }, surface).toHex());
}

test "pickAccent moves a colorful candidate to the readable side" {
    // A pale blue on a light surface becomes darker, keeping its hue.
    const light = Color.hex(0xfafafa);
    const pale = Color.hex(0xa0c4ff);
    const darker = pickAccent(&.{ null, pale }, light);
    try testing.expect(contrast(darker, light) >= accent_min_contrast);
    try testing.expect(toOklch(darker).l <= 0.5 + 0.01);
    try expectNear(toOklch(pale).h, toOklch(darker).h, 5);
    // A dark blue on a dark surface becomes lighter.
    const dark = Color.hex(0x202020);
    const navy = Color.hex(0x000080);
    const lighter = pickAccent(&.{navy}, dark);
    try testing.expect(contrast(lighter, dark) >= accent_min_contrast);
    try testing.expect(toOklch(lighter).l >= 0.85 - 0.01);
    // A gray cursor color is skipped for the colorful candidate, which
    // stays blue.
    const popup = Color.hex(0x2a2b3c);
    const dark_blue = Color.hex(0x00006b);
    const blue = pickAccent(&.{ Color.hex(0xcccccc), dark_blue, dark_blue }, popup);
    try testing.expect(contrast(blue, popup) >= accent_min_contrast);
    try testing.expect(blue.b > blue.r);
}

test "pickAccent falls back for gray themes and without candidates" {
    const dark = Color.hex(0x202020);
    const gray = pickAccent(&.{ Color.hex(0x303030), Color.hex(0x3a3a3a) }, dark);
    try testing.expect(contrast(gray, dark) >= accent_min_contrast);
    try testing.expect(chroma(gray) < accent_min_chroma);
    const popup = Color.hex(0x2a2b3c);
    const grays = pickAccent(&.{ Color.hex(0x444444), Color.hex(0x555555), Color.hex(0x666666) }, popup);
    try testing.expect(contrast(grays, popup) >= accent_min_contrast);
    try testing.expect(chroma(grays) < 0.02);
    const fallback = pickAccent(&.{}, Color.white);
    try testing.expectEqual(default_accent.toHex(), fallback.toHex());
    try testing.expect(contrast(pickAccent(&.{ null, null }, Color.hex(0x0060c0)), Color.hex(0x0060c0)) >= accent_min_contrast);
}

test "onAccent picks the more readable of black and white" {
    try testing.expectEqual(Color.black, onAccent(Color.hex(0x89b4fa)));
    try testing.expectEqual(Color.black, onAccent(Color.hex(0xf9e2af)));
    try testing.expectEqual(Color.white, onAccent(Color.hex(0x0067c0)));
    try testing.expectEqual(Color.white, onAccent(Color.hex(0x000080)));
}
