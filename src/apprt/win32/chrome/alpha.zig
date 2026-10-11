const std = @import("std");

pub fn backgroundPixel(rgb: [3]u8, opacity: f64, linear: bool) u32 {
    const a8: u32 = @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255));
    const a = @as(f64, @floatFromInt(a8)) / 255;
    var pixel = a8 << 24;
    for (rgb, [_]u5{ 16, 8, 0 }) |value, shift| {
        const c = @as(f64, @floatFromInt(value)) / 255;
        const p = if (linear) encode(decode(c) * a) else c * a;
        const stored: u32 = @intFromFloat(@round(p * 255));
        pixel |= stored << shift;
    }
    return pixel;
}

pub fn colorPixel(rgba: [4]f32) u32 {
    const a = std.math.clamp(rgba[3], 0, 1);
    var pixel: u32 = @as(u32, @intFromFloat(@round(a * 255))) << 24;
    for (rgba[0..3], [_]u5{ 16, 8, 0 }) |value, shift| {
        pixel |= @as(u32, @intFromFloat(@round(std.math.clamp(value, 0, 1) * a * 255))) << shift;
    }
    return pixel;
}

pub fn replace(bottom: u32, top: u32, coverage: u32) u32 {
    std.debug.assert(coverage <= 255);
    if (coverage == 0) return bottom;
    if (coverage == 255) return top;
    var pixel: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const below = (bottom >> shift) & 255;
        const above = (top >> shift) & 255;
        pixel |= ((below * (255 - coverage) + above * coverage + 127) / 255) << shift;
    }
    return pixel;
}

pub fn over(bottom: u32, top: u32) u32 {
    const a = top >> 24;
    if (a == 0) return bottom;
    if (a == 255) return top;
    var pixel: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const below = (bottom >> shift) & 255;
        const above = (top >> shift) & 255;
        pixel |= @as(u32, @min(255, above + (below * (255 - a) + 127) / 255)) << shift;
    }
    return pixel;
}

fn decode(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn encode(v: f64) f64 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
}

test "ChromeAlpha stored background covers every channel and opacity" {
    const testing = std.testing;
    const opacities = [_]f64{ 0, 0.01, 0.1, 0.3, 0.75, 1 };
    for ([_]bool{ false, true }) |linear| {
        for (opacities) |opacity| {
            const a8: u32 = @intFromFloat(@round(opacity * 255));
            var previous: u32 = 0;
            for (0..256) |value| {
                const c: u8 = @intCast(value);
                const pixel = backgroundPixel(.{ c, c, c }, opacity, linear);
                try testing.expectEqual(a8, pixel >> 24);
                const channel = pixel & 255;
                try testing.expect(channel >= previous);
                try testing.expectEqual(channel, (pixel >> 8) & 255);
                try testing.expectEqual(channel, (pixel >> 16) & 255);
                if (!linear) try testing.expect(channel <= a8);
                if (a8 == 0) try testing.expectEqual(@as(u32, 0), pixel);
                if (a8 == 255) try testing.expectEqual(@as(u32, c), channel);
                previous = channel;
            }
        }
    }
    try testing.expectEqual(@as(u32, 0x4d959595), backgroundPixel(.{ 255, 255, 255 }, 0.3, true));
    try testing.expectEqual(@as(u32, 0xcc1b1b23), backgroundPixel(.{ 31, 31, 40 }, 0.8, true));
    try testing.expectEqual(@as(u32, 0x80102080), backgroundPixel(.{ 32, 64, 255 }, 0.5, false));
}

test "ChromeAlpha coverage replaces alpha instead of compositing it twice" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0x4d959595), replace(0x4d353535, 0x4d959595, 255));
    try testing.expectEqual(@as(u32, 0x4d353535), replace(0x4d353535, 0x4d959595, 0));
    try testing.expectEqual(@as(u32, 0x4d656565), replace(0x4d353535, 0x4d959595, 128));
    try testing.expectEqual(@as(u32, 0), replace(0xffabcdef, 0, 255));
    try testing.expectEqual(@as(u32, 0xfffdfdfd), over(0x4dfafafa, 0x80808080) | 0xff000000);
    for (0..256) |coverage| {
        const pixel = replace(0x4d353535, 0x4d959595, @intCast(coverage));
        try testing.expectEqual(@as(u32, 77), pixel >> 24);
        try testing.expect((pixel & 255) >= 53 and (pixel & 255) <= 149);
    }
}
