//! The hovered-URL preview of a terminal surface: a small rounded bubble
//! at the bottom-left of the surface, like a browser status bubble, driven
//! by the `mouse_over_link` apprt action. It is a non-activating,
//! click-through `Popup` drawn with the `Canvas`, at most 60% as wide as
//! the surface: a longer URL keeps its scheme and host and loses the
//! middle of the rest (`elide`). While the pointer is over the bubble's
//! place it moves to the bottom-right corner (`placement`), so it never
//! covers the link. The same URL at the same place shows without new
//! work, and leaving a link hides the bubble after a short delay, so
//! moving between links does not flicker.
//!
//! The owning `Surface` embeds this struct as `link_preview` and calls
//! `show`/`hide` and `deinit`. `show` creates the popup again for another
//! window (the tab moved) or the other dark or light frame
//! (`Palette.ensurePopup`).
const LinkPreview = @This();

const std = @import("std");
const Surface = @import("../Surface.zig");
const Palette = @import("Palette.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const w32 = @import("../win32.zig");

/// The longest text shown, in bytes: the elided URL fits in it.
const max_text_len = 1024;

/// Bubble height and outer margin in DIPs.
const bubble_height: f32 = 28;
const margin: f32 = 6;

/// The widest the bubble gets, as a share of the surface width.
const max_width_share: f32 = 0.6;

/// How long the bubble stays after the pointer left the link.
const hide_delay_ms: u32 = 250;

/// Timer on the popup window that hides the bubble after `hide_delay_ms`.
const HIDE_TIMER_ID: usize = 0x4C48; // 'LH'

/// What replaces the elided middle of a URL.
const ellipsis = "\u{2026}";

popup: Popup = .{},

/// The URL on display, elided to fit the bubble.
text_buf: [max_text_len]u8 = undefined,
text_len: usize = 0,

/// The bubble on display, to skip a `show` that changes nothing.
shown: ?Shown = null,

const Shown = struct {
    url_hash: u64,
    url_len: usize,
    side: Side,
    /// The surface size (pixels) and scale the bubble was laid out for.
    surface_width: u32,
    surface_height: u32,
    scale: f32,
    /// The bubble's width in pixels.
    width: i32,
    tokens: style.Tokens,
};

fn surface(self: *LinkPreview) *Surface {
    return @alignCast(@fieldParentPtr("link_preview", self));
}

/// Destroy the popup.
pub fn deinit(self: *LinkPreview) void {
    self.popup.destroy();
    self.shown = null;
}

/// Hide the preview at once (the surface hides or moves).
pub fn hide(self: *LinkPreview) void {
    if (self.popup.hwnd) |hwnd| _ = w32.KillTimer(hwnd, HIDE_TIMER_ID);
    self.popup.hide();
    self.shown = null;
}

/// Hide the preview after `hide_delay_ms`, unless a link shows before.
fn hideSoon(self: *LinkPreview) void {
    const hwnd = self.popup.hwnd orelse return;
    if (!self.popup.visible) return;
    if (w32.SetTimer(hwnd, HIDE_TIMER_ID, hide_delay_ms, null) == 0) self.hide();
}

fn tokens(self: *LinkPreview) style.Tokens {
    return style.Tokens.fromConfig(&self.surface().app.config);
}

fn textStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.caption,
        .color = t.text,
        .align_y = .center,
        .ellipsis = false,
    };
}

/// The width of the bubble besides its text: the link icon and the
/// paddings, in DIPs.
const chrome_width = 2 * style.metrics.padding_x + style.metrics.icon_size + style.metrics.gap;

/// Measures text in the bubble's font for `elide`, outside the factory's
/// text cache: the candidates of one URL would only push out the texts
/// the other popups draw.
const Measurer = struct {
    factory: *d2d.Factory,
    text_style: d2d.TextStyle,

    pub fn width(self: Measurer, text: []const u8) f32 {
        var layout = d2d.TextLayout.initUtf8(self.factory, text, self.text_style, 100_000, 100_000) orelse return 0;
        defer layout.deinit();
        return layout.size().width;
    }
};

/// Show `url` at the bottom of the surface (after a short delay, hide the
/// bubble when it is empty).
pub fn show(self: *LinkPreview, url: []const u8) void {
    if (url.len == 0) {
        self.hideSoon();
        return;
    }
    const s = self.surface();
    const hwnd = s.hwnd orelse return;
    const owner = s.parent_window.hwnd orelse return;
    const t = self.tokens();
    if (!Palette.ensurePopup(&self.popup, s.app, owner, .{
        .activate = false,
        .click_through = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .corners = .round_small,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
    }, .{
        .ctx = self,
        .paint = paint,
        .timer = onTimer,
    })) return;
    const popup_hwnd = self.popup.hwnd orelse return;
    _ = w32.KillTimer(popup_hwnd, HIDE_TIMER_ID);
    if (self.shown) |*shown| {
        if (!std.meta.eql(shown.tokens, t)) {
            self.popup.applyTheme(t);
            shown.tokens = t;
        }
    }

    // The content scale of the window, like the terminal text.
    self.popup.setOwnerScale(s.parent_window.scale);
    const scale = self.popup.ownerScale();
    const url_hash = std.hash.Wyhash.hash(0, url);
    const same_url = if (self.shown) |shown|
        shown.url_hash == url_hash and shown.url_len == url.len and
            shown.surface_width == s.width and shown.surface_height == s.height and
            shown.scale == scale
    else
        false;

    // Lay the text out again only for another URL or surface size.
    const width: i32 = if (same_url) self.shown.?.width else width: {
        const factory = s.app.uiFactory() orelse return;
        const surface_w = style.dip(@intCast(s.width), scale);
        const max_w = @max(0, @min(surface_w * max_width_share, surface_w - 2 * margin));
        const measurer: Measurer = .{ .factory = factory, .text_style = textStyle(t) };
        const text = elide(&self.text_buf, url, @max(0, max_w - chrome_width), measurer);
        self.text_len = text.len;
        const want_w = measurer.width(text) + chrome_width;
        break :width @min(style.pxCeil(want_w, scale), @as(i32, @intFromFloat(@floor(max_w * scale))));
    };

    const pointer: ?Point = pointer: {
        const pos = s.getCursorPos() catch break :pointer null;
        break :pointer .{ .x = @intFromFloat(pos.x), .y = @intFromFloat(pos.y) };
    };
    const place = placement(
        @intCast(s.width),
        @intCast(s.height),
        width,
        style.px(bubble_height, scale),
        style.px(margin, scale),
        pointer,
    );
    if (same_url and self.popup.visible and self.shown.?.side == place.side) return;

    self.shown = .{
        .url_hash = url_hash,
        .url_len = url.len,
        .side = place.side,
        .surface_width = s.width,
        .surface_height = s.height,
        .scale = scale,
        .width = width,
        .tokens = t,
    };
    var pt: w32.POINT = .{ .x = place.x, .y = place.y };
    _ = w32.ClientToScreen(hwnd, &pt);
    const rect: w32.RECT = .{
        .left = pt.x,
        .top = pt.y,
        .right = pt.x + width,
        .bottom = pt.y + style.px(bubble_height, scale),
    };
    if (!self.popup.visible) {
        self.popup.setBorderColor(t.border);
        self.popup.show(rect);
        return;
    }
    // Shown already: another place only moves it; another URL repaints
    // once (with the new size, when it has one).
    if (!same_url) self.popup.invalidate();
    self.popup.setBounds(rect);
}

fn onTimer(ctx: *anyopaque, popup: *Popup, id: usize) void {
    _ = popup;
    if (id != HIDE_TIMER_ID) return;
    const self: *LinkPreview = @ptrCast(@alignCast(ctx));
    self.hide();
}

/// A corner of the surface for the bubble.
pub const Side = enum { left, right };

/// A point in surface pixels.
pub const Point = struct { x: i32, y: i32 };

/// Where `placement` puts the bubble: its corner and top-left point
/// (surface pixels).
pub const Placement = struct { side: Side, x: i32, y: i32 };

/// Where a bubble `w` × `h` goes on a surface `area_w` × `area_h`, `m`
/// from its edges (pixels): the bottom-left corner, or the bottom-right
/// one while the pointer (`pointer`, surface pixels; null when unknown)
/// is within `m` of the bubble's place on the left, so the bubble never
/// covers the link under the pointer (Chromium's status bubble does the
/// same). When the pointer is near both places, the bubble takes the one
/// whose middle is farther from it.
pub fn placement(area_w: i32, area_h: i32, w: i32, h: i32, m: i32, pointer: ?Point) Placement {
    const y = area_h - h - m;
    const left: Placement = .{ .side = .left, .x = m, .y = y };
    const right: Placement = .{ .side = .right, .x = @max(m, area_w - w - m), .y = y };
    const p = pointer orelse return left;
    if (!isNear(p, left, w, h, m)) return left;
    if (!isNear(p, right, w, h, m)) return right;
    const left_mid = left.x + @divTrunc(w, 2);
    const right_mid = right.x + @divTrunc(w, 2);
    return if (@abs(p.x - left_mid) >= @abs(p.x - right_mid)) left else right;
}

/// Whether `p` is within `slack` of a bubble `w` × `h` at `at`.
fn isNear(p: Point, at: Placement, w: i32, h: i32, slack: i32) bool {
    return p.x >= at.x - slack and p.x < at.x + w + slack and
        p.y >= at.y - slack and p.y < at.y + h + slack;
}

/// The end of the scheme and host of `url` ("https://example.com:8080" of
/// "https://example.com:8080/a?b#c"), or 0 when it has no `scheme://`
/// authority.
pub fn hostEnd(url: []const u8) usize {
    const sep = std.mem.indexOf(u8, url, "://") orelse return 0;
    if (sep == 0) return 0;
    for (url[0..sep]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return 0;
    }
    return std.mem.indexOfAnyPos(u8, url, sep + 3, "/?#") orelse url.len;
}

/// `url` as the bubble shows it in `max_w` DIPs (`measurer.width(text)`
/// measures text), written to `buf`: all of it when it fits; else its
/// scheme and host (`hostEnd`), "…" and as much of its end as fits (the
/// host shows where the link goes); else, when not even the host fits,
/// as much of its start and its end around "…" as fits. Cuts fall on
/// code point boundaries.
pub fn elide(buf: []u8, url: []const u8, max_w: f32, measurer: anytype) []const u8 {
    if (url.len <= buf.len and measurer.width(url) <= max_w) {
        @memcpy(buf[0..url.len], url);
        return buf[0..url.len];
    }

    const head_end = hostEnd(url);
    if (head_end > 0) {
        const head = url[0..head_end];
        const rest = url[head_end..];
        const Tail = struct {
            head: []const u8,
            rest: []const u8,
            fn build(self: @This(), out: []u8, k: usize) ?[]const u8 {
                return join(out, self.head, self.rest[startOfLast(self.rest, k)..]);
            }
        };
        const tail: Tail = .{ .head = head, .rest = rest };
        if (longest(buf, tail, codepoints(rest), max_w, measurer)) |text| return text;
    }

    const Around = struct {
        url: []const u8,
        fn build(self: @This(), out: []u8, k: usize) ?[]const u8 {
            const front = endOfFirst(self.url, (k + 1) / 2);
            const back = startOfLast(self.url, k / 2);
            return join(out, self.url[0..front], self.url[@max(front, back)..]);
        }
    };
    const around: Around = .{ .url = url };
    if (longest(buf, around, codepoints(url), max_w, measurer)) |text| return text;
    if (buf.len < ellipsis.len) return buf[0..0];
    @memcpy(buf[0..ellipsis.len], ellipsis);
    return buf[0..ellipsis.len];
}

/// The text of `parts.build(buf, k)` for the largest `k` in 0..`n` whose
/// text fits in `buf` and `max_w`, or null when not even `k` = 0 fits.
/// The width grows with `k`.
fn longest(buf: []u8, parts: anytype, n: usize, max_w: f32, measurer: anytype) ?[]const u8 {
    if (!fitsWith(buf, parts, 0, max_w, measurer)) return null;
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (fitsWith(buf, parts, mid, max_w, measurer)) lo = mid else hi = mid - 1;
    }
    return parts.build(buf, lo);
}

fn fitsWith(buf: []u8, parts: anytype, k: usize, max_w: f32, measurer: anytype) bool {
    const text = parts.build(buf, k) orelse return false;
    return measurer.width(text) <= max_w;
}

/// `head`, "…" and `tail` in `buf`, or null when they do not fit in it.
fn join(buf: []u8, head: []const u8, tail: []const u8) ?[]const u8 {
    const len = head.len + ellipsis.len + tail.len;
    if (len > buf.len) return null;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..ellipsis.len], ellipsis);
    @memcpy(buf[head.len + ellipsis.len ..][0..tail.len], tail);
    return buf[0..len];
}

fn codepoints(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// The byte index where the last `k` code points of `text` start.
fn startOfLast(text: []const u8, k: usize) usize {
    var i = text.len;
    var left = k;
    while (left > 0 and i > 0) : (left -= 1) {
        i -= 1;
        while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    }
    return i;
}

/// The byte index where the first `k` code points of `text` end.
fn endOfFirst(text: []const u8, k: usize) usize {
    var i: usize = 0;
    var left = k;
    while (left > 0 and i < text.len) : (left -= 1) {
        i += 1;
        while (i < text.len and text[i] & 0xC0 == 0x80) i += 1;
    }
    return i;
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *LinkPreview = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, t.surface_raised);

    const pad = style.metrics.padding_x;
    const icon = style.metrics.icon_size;
    canvas.drawIcon(d2d.icons.link, .{ .x = pad, .y = 0, .w = icon, .h = size.height }, 14, t.accent);

    const text_x = pad + icon + style.metrics.gap;
    var text_style = textStyle(t);
    // A text cut by rounding still ends in an ellipsis.
    text_style.ellipsis = true;
    canvas.drawText(self.text_buf[0..self.text_len], .{
        .x = text_x,
        .y = 0,
        .w = @max(size.width - text_x - pad, 0),
        .h = size.height,
    }, text_style);
}

/// Measures one unit per code point.
const TestMeasurer = struct {
    pub fn width(_: TestMeasurer, text: []const u8) f32 {
        return @floatFromInt(codepoints(text));
    }
};

test "elide keeps a URL that fits" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const url = "https://example.com/a/b";
    try testing.expectEqualStrings(url, elide(&buf, url, 23, TestMeasurer{}));
    try testing.expectEqualStrings(url, elide(&buf, url, 100, TestMeasurer{}));
}

test "elide keeps the host and the end of a long URL" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const url = "https://example.com/aaaa/bbbb/cccc/file.txt";
    // "https://example.com" (19) + "…" leaves 8 for the end.
    try testing.expectEqualStrings("https://example.com\u{2026}file.txt", elide(&buf, url, 28, TestMeasurer{}));
    // Only the host fits.
    try testing.expectEqualStrings("https://example.com\u{2026}", elide(&buf, url, 20, TestMeasurer{}));
    // A port belongs to the host; the query and fragment to the end.
    try testing.expectEqualStrings(
        "http://h:8080\u{2026}?q=1#top",
        elide(&buf, "http://h:8080/very/long/path?q=1#top", 22, TestMeasurer{}),
    );
}

test "elide falls back to both ends when the host does not fit" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const url = "https://a-very-long-host-name.example.com/x";
    // 11 code points and the ellipsis: 6 from the start, 5 from the end.
    try testing.expectEqualStrings("https:\u{2026}com/x", elide(&buf, url, 12, TestMeasurer{}));
    // Not a scheme://host URL at all: 5 from the start, 4 from the end.
    try testing.expectEqualStrings("mailt\u{2026}.org", elide(&buf, "mailto:someone@example.org", 10, TestMeasurer{}));
    // Nothing fits but the ellipsis.
    try testing.expectEqualStrings("\u{2026}", elide(&buf, url, 1, TestMeasurer{}));
    try testing.expectEqualStrings("\u{2026}", elide(&buf, url, 0, TestMeasurer{}));
}

test "elide cuts on code point boundaries" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const url = "https://例子.测试/路径/很长的文件名.html";
    for (0..40) |w| {
        const text = elide(&buf, url, @floatFromInt(w), TestMeasurer{});
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(codepoints(text) <= @max(w, 1));
    }
    try testing.expectEqualStrings("https://例子.测试\u{2026}名.html", elide(&buf, url, 20, TestMeasurer{}));
}

test "elide stays within its buffer" {
    const testing = std.testing;
    var buf: [16]u8 = undefined;
    const url = "https://example.com/" ++ "x" ** 100;
    // Wide enough for all of it, but the buffer is not.
    const text = elide(&buf, url, 1000, TestMeasurer{});
    try testing.expect(text.len <= buf.len);
    try testing.expect(std.mem.indexOf(u8, text, ellipsis) != null);
    const narrow = elide(&buf, url, 0, TestMeasurer{});
    try testing.expectEqualStrings(ellipsis, narrow);
    try testing.expectEqualStrings(ellipsis, buf[0..narrow.len]);
    try testing.expectEqual(@intFromPtr(&buf), @intFromPtr(narrow.ptr));
    var tiny: [2]u8 = undefined;
    try testing.expectEqualStrings("", elide(&tiny, url, 0, TestMeasurer{}));
}

test "hostEnd finds the scheme and host" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 19), hostEnd("https://example.com/path"));
    try testing.expectEqual(@as(usize, 19), hostEnd("https://example.com"));
    try testing.expectEqual(@as(usize, 13), hostEnd("http://h:8080?q"));
    try testing.expectEqual(@as(usize, 7), hostEnd("file:///C:/x"));
    try testing.expectEqual(@as(usize, 0), hostEnd("mailto:a@b.c"));
    try testing.expectEqual(@as(usize, 0), hostEnd("://nothing"));
    try testing.expectEqual(@as(usize, 0), hostEnd("a b://c"));
}

test "placement moves the bubble away from the pointer" {
    const testing = std.testing;
    // An 800 × 600 surface, a 300 × 28 bubble, 6 from the edges.
    const left: Placement = .{ .side = .left, .x = 6, .y = 566 };
    const right: Placement = .{ .side = .right, .x = 494, .y = 566 };
    try testing.expectEqual(left, placement(800, 600, 300, 28, 6, null));
    // The pointer away from the bottom-left corner.
    try testing.expectEqual(left, placement(800, 600, 300, 28, 6, .{ .x = 100, .y = 300 }));
    try testing.expectEqual(left, placement(800, 600, 300, 28, 6, .{ .x = 600, .y = 580 }));
    // Over the bubble's place, or just above it.
    try testing.expectEqual(right, placement(800, 600, 300, 28, 6, .{ .x = 100, .y = 580 }));
    try testing.expectEqual(right, placement(800, 600, 300, 28, 6, .{ .x = 100, .y = 562 }));
    // A wide bubble (at 6 or 314) covers the middle from both corners:
    // the place whose middle (246 or 554) is farther from the pointer.
    try testing.expectEqual(Side.right, placement(800, 600, 480, 28, 6, .{ .x = 300, .y = 580 }).side);
    try testing.expectEqual(Side.right, placement(800, 600, 480, 28, 6, .{ .x = 380, .y = 580 }).side);
    try testing.expectEqual(Side.left, placement(800, 600, 480, 28, 6, .{ .x = 420, .y = 580 }).side);
    try testing.expectEqual(Side.left, placement(800, 600, 480, 28, 6, .{ .x = 500, .y = 580 }).side);
    // A surface narrower than the bubble keeps it at the left margin.
    try testing.expectEqual(@as(i32, 6), placement(200, 600, 300, 28, 6, .{ .x = 10, .y = 580 }).x);
}
