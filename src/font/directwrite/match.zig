//! Platform independent pieces of the DirectWrite font discovery in
//! `discovery.zig` next to this file: ranking the faces of a family
//! against a discovery request, picking the FreeType named instance of a
//! variable font and matching style names. Kept free of Windows APIs so
//! the unit tests run on every platform.
const std = @import("std");

pub const Slant = enum { upright, italic, oblique };

/// How well a face's style names match a requested style name.
pub const StyleMatch = enum(u2) { none, fuzzy, exact };

/// What discovery knows about a candidate face.
pub const Attributes = struct {
    /// CSS / OpenType weight class, 1 through 999.
    weight: u16 = 400,

    /// DirectWrite stretch, 1 (ultra-condensed) through 9 (ultra-expanded);
    /// 0 means unknown and is treated as normal (5).
    stretch: u8 = 5,

    slant: Slant = .upright,
    monospace: bool = false,

    /// Only meaningful when the request names a style.
    style_match: StyleMatch = .none,
};

/// The parts of a discovery descriptor that select a face within a family.
pub const Request = struct {
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,

    /// The request names a style (`font-style*`). The named style then
    /// decides alone and `bold`/`italic` are ignored.
    style: bool = false,
};

pub const normal_weight = 400;
pub const bold_weight = 700;
pub const normal_stretch = 5;

/// Position of `actual` in the CSS Fonts 4 weight matching order for
/// `desired` (0 is the best). Between 400 and 500 the weights up to 500
/// come first, then lighter ones, then heavier ones; below 400 lighter
/// weights come first, above 500 heavier ones.
pub fn weightRank(desired: u16, actual: u16) u16 {
    const d: i32 = desired;
    const a: i32 = actual;
    const rank: i32 = if (desired >= 400 and desired <= 500) rank: {
        if (a >= d and a <= 500) break :rank a - d;
        if (a < d) break :rank 1000 + (d - a);
        break :rank 2000 + (a - 500);
    } else if (desired < 400) rank: {
        if (a <= d) break :rank d - a;
        break :rank 1000 + (a - d);
    } else rank: {
        if (a >= d) break :rank a - d;
        break :rank 1000 + (d - a);
    };
    return @intCast(rank);
}

/// Position of `actual` in the CSS Fonts 4 stretch matching order for
/// `desired`: at or below normal narrower widths come first, above
/// normal wider ones.
pub fn stretchRank(desired: u8, actual: u8) u8 {
    const d: u8 = if (desired == 0) normal_stretch else desired;
    const a: u8 = if (actual == 0) normal_stretch else actual;
    if (d <= normal_stretch) {
        if (a <= d) return d - a;
        return 10 + (a - d);
    }
    if (a >= d) return a - d;
    return 10 + (d - a);
}

/// Italic requests prefer italic, then oblique, then upright faces;
/// other requests the reverse.
pub fn slantRank(italic: bool, actual: Slant) u8 {
    return if (italic) switch (actual) {
        .italic => 0,
        .oblique => 1,
        .upright => 2,
    } else switch (actual) {
        .upright => 0,
        .oblique => 1,
        .italic => 2,
    };
}

/// Sort key for `attrs` under `req`, smaller is better. Width is matched
/// first, then slant, then weight (the CSS order); the named style match
/// and monospace break ties around them.
fn rankKey(req: Request, attrs: Attributes) u64 {
    const style: u64 = if (req.style) 2 - @as(u64, @intFromEnum(attrs.style_match)) else 0;
    const stretch: u64 = stretchRank(normal_stretch, attrs.stretch);
    const slant: u64 = slantRank(req.italic and !req.style, attrs.slant);
    const desired_weight: u16 = if (req.bold and !req.style) bold_weight else normal_weight;
    const weight: u64 = weightRank(desired_weight, attrs.weight);
    const mono: u64 = @intFromBool(req.monospace and !attrs.monospace);
    return style << 56 | stretch << 48 | slant << 40 | weight << 8 | mono;
}

/// Selects and orders the faces of one family for a request. `attrs`
/// describes every candidate; `order` must have the same length and
/// receives candidate indices. Returns the leading part of `order` with
/// the usable candidates, best first, keeping the input order for ties.
///
/// A request that names a style keeps only faces whose style names match
/// it. Otherwise only faces of the family's width closest to normal are
/// kept, so every style uses the same width, and a bold or italic
/// request keeps only faces that really have that trait relative to the
/// family's regular face: bold means at least semibold and heavier than
/// the regular face, italic means italic or oblique. An empty result for
/// a styled request lets the caller synthesize the style instead of
/// silently reusing the regular face. A regular request always keeps
/// every remaining face.
pub fn select(req: Request, attrs: []const Attributes, order: []usize) []usize {
    std.debug.assert(order.len == attrs.len);
    var len: usize = 0;

    if (req.style) {
        for (attrs, 0..) |a, i| {
            if (a.style_match == .none) continue;
            order[len] = i;
            len += 1;
        }
        sort(req, attrs, order[0..len]);
        return order[0..len];
    }

    var best_stretch: u8 = std.math.maxInt(u8);
    for (attrs) |a| best_stretch = @min(best_stretch, stretchRank(normal_stretch, a.stretch));

    // The regular face of this width decides what counts as bold.
    var base: ?Attributes = null;
    for (attrs) |a| {
        if (stretchRank(normal_stretch, a.stretch) != best_stretch) continue;
        if (base == null or rankKey(.{}, a) < rankKey(.{}, base.?)) base = a;
    }
    const base_weight: u16 = if (base) |b| b.weight else normal_weight;
    const bold_threshold: u16 = @max(600, base_weight + 100);

    for (attrs, 0..) |a, i| {
        if (stretchRank(normal_stretch, a.stretch) != best_stretch) continue;
        if (req.bold and a.weight < bold_threshold) continue;
        if (!req.bold and req.italic and a.weight >= bold_threshold) continue;
        if (req.italic and a.slant == .upright) continue;
        if (!req.italic and req.bold and a.slant != .upright) continue;
        order[len] = i;
        len += 1;
    }
    sort(req, attrs, order[0..len]);
    return order[0..len];
}

fn sort(req: Request, attrs: []const Attributes, order: []usize) void {
    const Ctx = struct {
        req: Request,
        attrs: []const Attributes,

        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return rankKey(ctx.req, ctx.attrs[a]) < rankKey(ctx.req, ctx.attrs[b]);
        }
    };
    std.mem.sort(usize, order, Ctx{ .req = req, .attrs = attrs }, Ctx.lessThan);
}

/// Compares the style names of a face (in any language) with a requested
/// style: equal ignoring ASCII case is exact, containing it is fuzzy.
pub fn styleMatch(names: []const []const u8, wanted: []const u8) StyleMatch {
    var result: StyleMatch = .none;
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, wanted)) return .exact;
        if (wanted.len > 0 and std.ascii.indexOfIgnoreCase(name, wanted) != null) result = .fuzzy;
    }
    return result;
}

/// A variation axis value. `tag` uses the FreeType layout (first tag
/// character in the most significant byte); DirectWrite stores tags
/// byte swapped.
pub const AxisValue = struct {
    tag: u32,
    value: f32,

    pub fn fromDirectWrite(tag: u32, value: f32) AxisValue {
        return .{ .tag = @byteSwap(tag), .value = value };
    }
};

pub fn axisTag(comptime str: *const [4]u8) u32 {
    return std.mem.readInt(u32, str, .big);
}

/// Distance between the design coordinates of one named instance
/// (`coords`, ordered like `axis_tags`) and the axis values DirectWrite
/// reports for a face. Axes only one side knows are ignored; null when
/// they share no axis. The caller picks the instance with the smallest
/// distance, 0 being an exact match.
pub fn instanceDistance(
    axis_tags: []const u32,
    coords: []const f32,
    target: []const AxisValue,
) ?f32 {
    var distance: f32 = 0;
    var shared = false;
    for (axis_tags, coords) |tag, coord| {
        for (target) |t| {
            if (t.tag != tag) continue;
            distance += @abs(coord - t.value);
            shared = true;
            break;
        }
    }
    return if (shared) distance else null;
}

/// UTF-16 encoding of one codepoint, as DirectWrite expects it.
pub fn utf16Codepoint(cp: u21, buf: *[2]u16) []const u16 {
    if (cp < 0x10000) {
        buf[0] = @intCast(cp);
        return buf[0..1];
    }
    const v = cp - 0x10000;
    buf[0] = @intCast(0xD800 + (v >> 10));
    buf[1] = @intCast(0xDC00 + (v & 0x3FF));
    return buf[0..2];
}

fn testSelect(req: Request, attrs: []const Attributes, buf: []usize) []usize {
    return select(req, attrs, buf[0..attrs.len]);
}

test "weightRank follows the CSS matching order" {
    const testing = std.testing;

    // Normal: 400, then up to 500, then lighter, then heavier.
    try testing.expect(weightRank(400, 400) < weightRank(400, 500));
    try testing.expect(weightRank(400, 500) < weightRank(400, 300));
    try testing.expect(weightRank(400, 300) < weightRank(400, 100));
    try testing.expect(weightRank(400, 100) < weightRank(400, 600));
    try testing.expect(weightRank(400, 600) < weightRank(400, 900));

    // Bold: heavier first, then lighter.
    try testing.expect(weightRank(700, 700) < weightRank(700, 800));
    try testing.expect(weightRank(700, 900) < weightRank(700, 600));
    try testing.expect(weightRank(700, 600) < weightRank(700, 400));

    // Light: lighter first, then heavier.
    try testing.expect(weightRank(300, 200) < weightRank(300, 400));
}

test "stretchRank prefers normal, then narrower, then wider" {
    const testing = std.testing;
    try testing.expectEqual(0, stretchRank(normal_stretch, 5));
    try testing.expectEqual(0, stretchRank(normal_stretch, 0));
    try testing.expect(stretchRank(normal_stretch, 4) < stretchRank(normal_stretch, 3));
    try testing.expect(stretchRank(normal_stretch, 1) < stretchRank(normal_stretch, 6));
    try testing.expect(stretchRank(7, 8) < stretchRank(7, 6));
}

test "select regular, bold, italic and bold italic of a full family" {
    const testing = std.testing;
    // Order as DirectWrite lists Cascadia Code: weights, then italics.
    const attrs = [_]Attributes{
        .{ .weight = 200 },
        .{ .weight = 400 },
        .{ .weight = 600 },
        .{ .weight = 700 },
        .{ .weight = 400, .slant = .italic },
        .{ .weight = 700, .slant = .italic },
        .{ .weight = 200, .slant = .italic },
    };
    var buf: [attrs.len]usize = undefined;

    try testing.expectEqual(1, testSelect(.{}, &attrs, &buf)[0]);

    const bold = testSelect(.{ .bold = true }, &attrs, &buf);
    try testing.expectEqualSlices(usize, &.{ 3, 2 }, bold);

    const italic = testSelect(.{ .italic = true }, &attrs, &buf);
    try testing.expectEqualSlices(usize, &.{ 4, 6 }, italic);

    const bold_italic = testSelect(.{ .bold = true, .italic = true }, &attrs, &buf);
    try testing.expectEqualSlices(usize, &.{5}, bold_italic);
}

test "select leaves missing styles to synthesis" {
    const testing = std.testing;
    var buf: [4]usize = undefined;

    // Only a regular face: nothing qualifies for the styled requests.
    const regular_only = [_]Attributes{.{ .weight = 400 }};
    try testing.expectEqual(1, testSelect(.{}, &regular_only, &buf).len);
    try testing.expectEqual(0, testSelect(.{ .bold = true }, &regular_only, &buf).len);
    try testing.expectEqual(0, testSelect(.{ .italic = true }, &regular_only, &buf).len);

    // Regular and bold italic: italic must not borrow the bold italic
    // face and bold must not borrow it either.
    const sparse = [_]Attributes{
        .{ .weight = 400 },
        .{ .weight = 700, .slant = .italic },
    };
    try testing.expectEqual(0, testSelect(.{ .italic = true }, &sparse, &buf).len);
    try testing.expectEqual(0, testSelect(.{ .bold = true }, &sparse, &buf).len);
    try testing.expectEqualSlices(usize, &.{1}, testSelect(.{ .bold = true, .italic = true }, &sparse, &buf));

    // A medium face is not bold enough.
    const medium = [_]Attributes{ .{ .weight = 400 }, .{ .weight = 500 } };
    try testing.expectEqual(0, testSelect(.{ .bold = true }, &medium, &buf).len);
}

test "select treats bold relative to a semibold regular face" {
    const testing = std.testing;
    var buf: [2]usize = undefined;

    // A GDI family such as "Segoe UI Semibold": the regular face is
    // already semibold, so bold must be synthesized but its italic is
    // a real italic.
    const attrs = [_]Attributes{
        .{ .weight = 600 },
        .{ .weight = 600, .slant = .italic },
    };
    try testing.expectEqual(0, testSelect(.{}, &attrs, &buf)[0]);
    try testing.expectEqual(0, testSelect(.{ .bold = true }, &attrs, &buf).len);
    try testing.expectEqualSlices(usize, &.{1}, testSelect(.{ .italic = true }, &attrs, &buf));
}

test "select keeps the width closest to normal for every style" {
    const testing = std.testing;
    var buf: [4]usize = undefined;
    const attrs = [_]Attributes{
        .{ .weight = 400, .stretch = 3 },
        .{ .weight = 700, .stretch = 3 },
        .{ .weight = 400, .stretch = 5 },
        .{ .weight = 300, .stretch = 5 },
    };
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, testSelect(.{}, &attrs, &buf));
    try testing.expectEqual(0, testSelect(.{ .bold = true }, &attrs, &buf).len);

    // A condensed-only family still resolves.
    const condensed = [_]Attributes{
        .{ .weight = 400, .stretch = 3 },
        .{ .weight = 700, .stretch = 3 },
    };
    try testing.expectEqualSlices(usize, &.{1}, testSelect(.{ .bold = true }, &condensed, &buf));
}

test "select prefers italic over oblique and keeps input order on ties" {
    const testing = std.testing;
    var buf: [4]usize = undefined;
    const attrs = [_]Attributes{
        .{ .weight = 400 },
        .{ .weight = 400, .slant = .oblique },
        .{ .weight = 400, .slant = .italic },
        .{ .weight = 400, .slant = .italic },
    };
    try testing.expectEqualSlices(usize, &.{ 2, 3, 1 }, testSelect(.{ .italic = true }, &attrs, &buf));
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, testSelect(.{}, &attrs, &buf));
}

test "select by style name ignores the traits" {
    const testing = std.testing;
    var buf: [3]usize = undefined;
    const attrs = [_]Attributes{
        .{ .weight = 400 },
        .{ .weight = 900, .style_match = .fuzzy },
        .{ .weight = 900, .style_match = .exact },
    };
    try testing.expectEqualSlices(usize, &.{ 2, 1 }, testSelect(.{ .style = true, .bold = true }, &attrs, &buf));

    const none = [_]Attributes{.{ .weight = 400 }};
    try testing.expectEqual(0, testSelect(.{ .style = true }, &none, &buf).len);
}

test "select ranks monospace faces first when asked" {
    const testing = std.testing;
    var buf: [2]usize = undefined;
    const attrs = [_]Attributes{ .{}, .{ .monospace = true } };
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, testSelect(.{ .monospace = true }, &attrs, &buf));
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, testSelect(.{}, &attrs, &buf));
}

test "styleMatch" {
    const testing = std.testing;
    try testing.expectEqual(.exact, styleMatch(&.{ "Fett", "Bold" }, "bold"));
    try testing.expectEqual(.fuzzy, styleMatch(&.{"Bold Italic"}, "italic"));
    try testing.expectEqual(.none, styleMatch(&.{"Regular"}, "Heavy"));
    try testing.expectEqual(.none, styleMatch(&.{}, "Heavy"));
}

test "instanceDistance picks the named instance" {
    const testing = std.testing;
    const wght = axisTag("wght");
    const ital = axisTag("ital");
    const wdth = axisTag("wdth");
    const tags = [_]u32{ wght, wdth };

    // DirectWrite reports Cascadia Code Bold as wght=700 ital=0 ...
    const target = [_]AxisValue{
        .fromDirectWrite(@byteSwap(wght), 700),
        .fromDirectWrite(@byteSwap(ital), 0),
        .fromDirectWrite(@byteSwap(wdth), 100),
    };
    try testing.expectEqual(0, instanceDistance(&tags, &.{ 700, 100 }, &target).?);
    try testing.expectEqual(300, instanceDistance(&tags, &.{ 400, 100 }, &target).?);
    try testing.expectEqual(null, instanceDistance(&.{axisTag("opsz")}, &.{12}, &target));
}

test "axisTag matches the DirectWrite byte order" {
    const testing = std.testing;
    // DWRITE_MAKE_FONT_AXIS_TAG('w','g','h','t')
    const dwrite: u32 = 't' << 24 | 'h' << 16 | 'g' << 8 | 'w';
    try testing.expectEqual(axisTag("wght"), AxisValue.fromDirectWrite(dwrite, 0).tag);
}

test "utf16Codepoint" {
    const testing = std.testing;
    var buf: [2]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{0x4E2D}, utf16Codepoint(0x4E2D, &buf));
    try testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE00 }, utf16Codepoint(0x1F600, &buf));
}
