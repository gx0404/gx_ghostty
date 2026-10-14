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
//! A `Surface` embeds this struct as `link_preview` and calls `show`; the
//! runtime UI of a remote pane (`RemoteRuntimeUi.zig`) embeds one and
//! calls `showRemote` with the pane, which has no `Surface`. Both call
//! `hide` and `deinit`. A show places the bubble on the terminal's own
//! child window (`Host`), colors it from that terminal's app and creates
//! the popup again for another window (the tab moved) or the other dark
//! or light frame (`Palette.ensurePopup`).
const LinkPreview = @This();

const std = @import("std");
const App = @import("../App.zig");
const RemotePane = @import("../RemotePane.zig");
const Surface = @import("../Surface.zig");
const Palette = @import("Palette.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const text_edit = @import("text_edit.zig");
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

/// The app of the terminal the bubble showed for last: its configuration
/// colors the bubble.
app: ?*App = null,

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

fn tokens(self: *LinkPreview) ?style.Tokens {
    const app = self.app orelse return null;
    return style.Tokens.fromConfig(&app.config);
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
const text_slack_px: i32 = 2;

fn textBudget(max_pixels: i32, scale: f32) f32 {
    return @max(0, style.dip(@max(0, max_pixels - text_slack_px), scale) - chrome_width);
}

fn bubbleWidth(text_width: f32, max_pixels: i32, scale: f32) i32 {
    return @min(@max(0, max_pixels), style.pxCeil(text_width + chrome_width, scale) + text_slack_px);
}

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

/// Where a bubble shows: the terminal's own child window and its size in
/// pixels, the top-level window that owns the popup and its content scale
/// (`Window.scale`, like the terminal text), and the pointer in client
/// pixels of the terminal window (null when unknown).
const Host = struct {
    app: *App,
    hwnd: w32.HWND,
    owner: w32.HWND,
    scale: f32,
    width: u32,
    height: u32,
    pointer: ?Point,
};

/// Show `url` at the bottom of the owning `Surface` (after a short delay,
/// hide the bubble when it is empty).
pub fn show(self: *LinkPreview, url: []const u8) void {
    if (url.len == 0) {
        self.hideSoon();
        return;
    }
    const s = self.surface();
    const pointer: ?Point = pointer: {
        const pos = s.getCursorPos() catch break :pointer null;
        break :pointer .{ .x = @intFromFloat(pos.x), .y = @intFromFloat(pos.y) };
    };
    self.showOn(.{
        .app = s.app,
        .hwnd = s.hwnd orelse return,
        .owner = s.parent_window.hwnd orelse return,
        .scale = s.parent_window.scale,
        .width = s.width,
        .height = s.height,
        .pointer = pointer,
    }, url);
}

/// `show` for a remote pane, whose runtime UI owns this preview: the
/// bubble sits on the pane's child window at its size and moves away from
/// the pointer where the pane maps it for its input (client pixels of
/// that window, `clientPointer`).
pub fn showRemote(self: *LinkPreview, pane: *RemotePane, url: []const u8) void {
    if (url.len == 0) {
        self.hideSoon();
        return;
    }
    const hwnd = pane.hwnd orelse return;
    self.showOn(.{
        .app = pane.app,
        .hwnd = hwnd,
        .owner = pane.parent_window.hwnd orelse return,
        .scale = pane.parent_window.scale,
        .width = pane.width,
        .height = pane.height,
        .pointer = clientPointer(hwnd, pane.width, pane.height),
    }, url);
}

/// Whether a bubble is on display: placed by a show and not hidden since.
pub fn isShown(self: *const LinkPreview) bool {
    return self.shown != null and self.popup.visible;
}

/// The pointer in client pixels of `hwnd` while it is over that window's
/// `width` x `height` area (`pointerIn`), else null.
fn clientPointer(hwnd: w32.HWND, width: u32, height: u32) ?Point {
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0 or w32.ScreenToClient(hwnd, &pt) == 0) return null;
    return pointerIn(.{ .x = pt.x, .y = pt.y }, width, height);
}

/// `p` when it lies in a `width` x `height` area at the origin, else null:
/// a pointer outside the terminal covers no link.
pub fn pointerIn(p: Point, width: u32, height: u32) ?Point {
    if (p.x < 0 or p.y < 0) return null;
    if (@as(i64, p.x) >= width or @as(i64, p.y) >= height) return null;
    return p;
}

fn showOn(self: *LinkPreview, host: Host, url: []const u8) void {
    self.app = host.app;
    const t = self.tokens() orelse return;
    if (!Palette.ensurePopup(&self.popup, host.app, host.owner, .{
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
    self.popup.setOwnerScale(host.scale);
    const scale = self.popup.ownerScale();
    const url_hash = std.hash.Wyhash.hash(0, url);
    const same_url = if (self.shown) |shown|
        shown.url_hash == url_hash and shown.url_len == url.len and
            shown.surface_width == host.width and shown.surface_height == host.height and
            shown.scale == scale
    else
        false;

    // Lay the text out again only for another URL or surface size.
    const width: i32 = if (same_url) self.shown.?.width else width: {
        const factory = host.app.uiFactory() orelse return;
        const surface_w = style.dip(@intCast(host.width), scale);
        const max_w = @max(0, @min(surface_w * max_width_share, surface_w - 2 * margin));
        const max_pixels: i32 = @intFromFloat(@floor(max_w * scale));
        const measurer: Measurer = .{ .factory = factory, .text_style = textStyle(t) };
        const text = elide(&self.text_buf, url, textBudget(max_pixels, scale), measurer);
        self.text_len = text.len;
        break :width bubbleWidth(measurer.width(text), max_pixels, scale);
    };

    const place = placement(
        @intCast(host.width),
        @intCast(host.height),
        width,
        style.px(bubble_height, scale),
        style.px(margin, scale),
        host.pointer,
    );
    if (same_url and self.popup.visible and self.shown.?.side == place.side) return;

    self.shown = .{
        .url_hash = url_hash,
        .url_len = url.len,
        .side = place.side,
        .surface_width = host.width,
        .surface_height = host.height,
        .scale = scale,
        .width = width,
        .tokens = t,
    };
    var pt: w32.POINT = .{ .x = place.x, .y = place.y };
    _ = w32.ClientToScreen(host.hwnd, &pt);
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
/// as much of its start and its end around "…" as fits. Cuts use the
/// shared `text_edit` grapheme boundaries, including the authority cut.
pub fn elide(buf: []u8, url: []const u8, max_w: f32, measurer: anytype) []const u8 {
    if (url.len <= buf.len and measurer.width(url) <= max_w) {
        @memcpy(buf[0..url.len], url);
        return buf[0..url.len];
    }

    const authority_end = hostEnd(url);
    var head_end: usize = 0;
    while (head_end < authority_end) head_end = text_edit.nextCharUtf8(url, head_end);
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
        if (longest(buf, tail, characterCount(rest), max_w, measurer)) |text| return text;
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
    if (longest(buf, around, characterCount(url), max_w, measurer)) |text| return text;
    if (buf.len < ellipsis.len) return buf[0..0];
    @memcpy(buf[0..ellipsis.len], ellipsis);
    return buf[0..ellipsis.len];
}

/// The largest number `k` of whole grapheme clusters in 0..`n` for which
/// `parts.build(buf, k)` fits both `buf` and the measured `max_w`, or null
/// when not even `k` = 0 fits. The width grows with `k`.
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

fn characterCount(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) i = text_edit.nextCharUtf8(text, i);
    return n;
}

/// The byte index where the last `k` whole grapheme clusters start.
fn startOfLast(text: []const u8, k: usize) usize {
    return endOfFirst(text, characterCount(text) -| k);
}

/// The byte index where the first `k` whole grapheme clusters end.
fn endOfFirst(text: []const u8, k: usize) usize {
    var i: usize = 0;
    var left = k;
    while (left > 0 and i < text.len) : (left -= 1) i = text_edit.nextCharUtf8(text, i);
    return i;
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *LinkPreview = @ptrCast(@alignCast(ctx));
    const t = self.tokens() orelse return;
    const size = popup.sizeDip();
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, t.surface_raised);

    const pad = style.metrics.padding_x;
    const icon = style.metrics.icon_size;
    canvas.drawIcon(d2d.icons.link, .{ .x = pad, .y = 0, .w = icon, .h = size.height }, 14, t.accent);

    const text_x = pad + icon + style.metrics.gap;
    canvas.drawText(self.text_buf[0..self.text_len], .{
        .x = text_x,
        .y = 0,
        .w = @max(size.width - text_x - pad, 0),
        .h = size.height,
    }, textStyle(t));
}

fn codepoints(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Measures one unit per code point, independent of grapheme boundaries.
const TestMeasurer = struct {
    pub fn width(_: TestMeasurer, text: []const u8) f32 {
        return @floatFromInt(codepoints(text));
    }
};

fn isCharacterBoundary(text: []const u8, pos: usize) bool {
    if (pos > text.len) return false;
    var i: usize = 0;
    while (i < pos) i = text_edit.nextCharUtf8(text, i);
    return i == pos;
}

fn expectWholeCharacters(url: []const u8, text: []const u8) !void {
    const testing = std.testing;
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    if (text.len == 0) return;
    const cut = std.mem.indexOf(u8, text, ellipsis) orelse {
        try testing.expectEqualStrings(url, text);
        return;
    };
    const head = text[0..cut];
    const tail = text[cut + ellipsis.len ..];
    try testing.expect(std.mem.startsWith(u8, url, head));
    try testing.expect(std.mem.endsWith(u8, url, tail));
    try testing.expect(isCharacterBoundary(url, head.len));
    try testing.expect(isCharacterBoundary(url, url.len - tail.len));
}

test "elide preserves complete combining and emoji URL tails" {
    const testing = std.testing;
    const host = "https://example.com";
    for ([_][]const u8{
        "e\u{0301}",
        "\u{1f469}\u{200d}\u{1f4bb}",
        "\u{1f44d}\u{1f3fd}",
        "\u{1f1e8}\u{1f1f3}",
        "\u{2764}\u{fe0f}",
    }) |cluster| {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/aaa/{s}", .{ host, cluster });
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(host ++ ellipsis, elide(&buf, url, 21, TestMeasurer{}));
        var expected_buf: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "{s}{s}{s}", .{ host, ellipsis, cluster });
        const budget: f32 = @floatFromInt(20 + codepoints(cluster));
        const text = elide(&buf, url, budget, TestMeasurer{});
        try testing.expectEqualStrings(expected, text);
        try expectWholeCharacters(url, text);
    }
}

test "elide fallback and buffer limits keep character boundaries" {
    const testing = std.testing;
    for ([_][]const u8{
        "e\u{0301}/" ++ "x" ** 32 ++ "/\u{1f469}\u{200d}\u{1f4bb}",
        "\u{1f44d}\u{1f3fd}/" ++ "x" ** 32 ++ "/\u{1f1e8}\u{1f1f3}\u{1f1ef}\u{1f1f5}",
        "https://example.com/aaa/e\u{0301}",
        "https://example.com\u{200d}/aaa/e\u{0301}",
    }) |url| {
        var buf: [256]u8 = undefined;
        for (0..codepoints(url) + 2) |budget| {
            const text = elide(&buf, url, @floatFromInt(budget), TestMeasurer{});
            try testing.expect((TestMeasurer{}).width(text) <= @as(f32, @floatFromInt(@max(1, budget))));
            try expectWholeCharacters(url, text);
        }
        for (0..url.len + 1) |len| {
            const text = elide(buf[0..len], url, 1000, TestMeasurer{});
            try testing.expect(text.len <= len);
            try expectWholeCharacters(url, text);
        }
    }
}

test "elide fits complete characters in measured DirectWrite DPI budgets" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    const t = style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    const measurer: Measurer = .{ .factory = factory, .text_style = textStyle(t) };
    const url = "https://example.com/" ++ "segment/" ** 32 ++ "e\u{0301}/\u{1f469}\u{200d}\u{1f4bb}/\u{1f44d}\u{1f3fd}/\u{1f1e8}\u{1f1f3}/troubleshooting.html";
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        const cap: i32 = 519;
        const budget = textBudget(cap, scale);
        var buf: [max_text_len]u8 = undefined;
        const text = elide(&buf, url, budget, measurer);
        const width = measurer.width(text);
        try testing.expect(width > 0 and width <= budget);
        try testing.expect(bubbleWidth(width, cap, scale) <= cap);
        try testing.expect(text.len <= buf.len);
        try expectWholeCharacters(url, text);
        try testing.expect(std.mem.startsWith(u8, text, "https://example.com"));
        try testing.expect(std.mem.endsWith(u8, text, ".html"));
    }
}

test "the bubble reserves rounding room within its physical width cap" {
    const testing = std.testing;
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        const cap: i32 = 519;
        const budget = textBudget(cap, scale);
        for ([_]f32{ 0, budget / 2, budget }) |width| {
            const pixels = bubbleWidth(width, cap, scale);
            try testing.expect(pixels <= cap);
            try testing.expect(textBudget(pixels, scale) + 1e-4 >= width);
        }
        try testing.expectEqual(@as(i32, 0), bubbleWidth(0, 0, scale));
        try testing.expectEqual(@as(f32, 0), textBudget(1, scale));
    }
}

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

test "elide cuts on grapheme boundaries within measured code point widths" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const url = "https://例子.测试/路径/很长的文件名.html";
    for (0..40) |w| {
        const text = elide(&buf, url, @floatFromInt(w), TestMeasurer{});
        try testing.expect(codepoints(text) <= @max(w, 1));
        try expectWholeCharacters(url, text);
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
