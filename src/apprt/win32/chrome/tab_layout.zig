//! Tab bar geometry and labels that need no window: where the tabs and the
//! buttons of a window's tab strip go (`compute`), which slot a dragged tab
//! lands in (`dragTarget`, `dragSlotLeft`), the text a tab shows (`label`)
//! and the straight-alpha fill of an active tab that joins a translucent
//! terminal (`straightFill`). `chrome/TabBar.zig` paints and hit-tests with
//! them. Only depends on std.
//!
//! The tabs share the strip in equal widths from `max_width` down to
//! `min_width`; the active tab keeps at least `active_min_width`, enough for
//! its close button and some text. When even that does not fit, the tabs
//! keep those widths and scroll between two scroll buttons, with a button
//! listing every tab after them. After a tab closed through its close
//! button the widths stay (`Frozen`) until the pointer leaves the strip, so
//! the next close button lands under the pointer.
const std = @import("std");

/// A rectangle in client pixels, laid out like `w32.RECT`.
pub const Rect = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub const empty: Rect = .{};

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

// Sizes in DIPs.

/// The widest a tab gets (WinUI TabView).
pub const max_width: f32 = 240;
/// The narrowest an inactive tab gets before the tabs scroll.
pub const min_width: f32 = 72;
/// The narrowest the active tab gets: its close button and some text.
pub const active_min_width: f32 = 120;
/// The buttons that scroll the tabs (WinUI TabView): their width, the
/// height of their fill, and how far one click scrolls.
pub const scroll_button_width: f32 = 32;
pub const scroll_button_height: f32 = 24;
pub const scroll_step: f32 = 50;
/// The button that lists every tab, while they scroll.
pub const list_button_width: f32 = 28;
/// The new-tab ("+") and launch profile buttons after the tabs.
pub const new_tab_width: f32 = 32;
pub const profile_width: f32 = 20;
pub const buttons_gap: f32 = 4;
/// Height of the row buttons (`TitleBar.row_button_height`).
pub const row_button_height: f32 = 28;
/// The administrator badge before the tabs.
pub const badge_width: f32 = 28;
/// The close button of a tab: the part of the tab that takes the click (the
/// whole height of the tab), the hover fill inside it and the gap between
/// the fill and the tab's right edge.
pub const close_hit_width: f32 = 28;
pub const close_size: f32 = 24;
pub const close_margin: f32 = 4;

/// A length in DIPs as whole pixels at `scale`.
pub fn px(length: f32, scale: f32) i32 {
    return @intFromFloat(@round(length * scale));
}

/// The widths kept after a tab closed through its close button, for a strip
/// `area_w` pixels wide.
pub const Frozen = struct {
    tab_w: i32,
    active_w: i32,
    area_w: i32,
};

pub const Input = struct {
    /// The strip for the tabs and the buttons after them (client pixels);
    /// `top` is where the tabs hang from, `bottom` the bottom of the row.
    area: Rect,
    /// The top of the hit rectangles: `area.top`, or the top of the window
    /// when it is maximized or fullscreen, so a click at the screen edge
    /// reaches the tabs.
    hit_top: i32,
    scale: f32,
    count: usize,
    active: usize,
    /// Leave room before the tabs for the administrator badge.
    badge: bool = false,
    frozen: ?Frozen = null,
    /// How far the tabs scroll, in DIPs (clamped).
    scroll: f32 = 0,
};

pub const Layout = struct {
    count: usize = 0,
    active: usize = 0,
    scale: f32 = 1,
    /// The width of inactive tabs and of the active tab.
    tab_w: i32 = 0,
    active_w: i32 = 0,
    /// The tabs do not fit and scroll between the scroll buttons.
    overflow: bool = false,
    /// The horizontal range the tabs show in; tabs are clipped to it.
    view_left: i32 = 0,
    view_right: i32 = 0,
    /// The tabs' top and bottom, and the top of their hit rectangles.
    top: i32 = 0,
    bottom: i32 = 0,
    hit_top: i32 = 0,
    /// The width of all tabs together.
    content_w: i32 = 0,
    /// How far the tabs scroll, and at most.
    scroll_px: i32 = 0,
    max_scroll_px: i32 = 0,
    badge: Rect = .empty,
    /// The scroll and list buttons (empty unless `overflow`).
    scroll_back: Rect = .empty,
    scroll_forward: Rect = .empty,
    list: Rect = .empty,
    new_tab: Rect = .empty,
    profiles: Rect = .empty,

    /// The width of tab `i`.
    pub fn width(self: *const Layout, i: usize) i32 {
        return if (i == self.active) self.active_w else self.tab_w;
    }

    /// Where tab `i` starts among all tabs (0 for the first).
    pub fn contentLeft(self: *const Layout, i: usize) i32 {
        const before: i32 = @intCast(@min(i, self.count));
        if (i > self.active and self.active < self.count) return (before - 1) * self.tab_w + self.active_w;
        return before * self.tab_w;
    }

    /// The client x of content x `x`.
    pub fn clientX(self: *const Layout, x: i32) i32 {
        return self.view_left + x - self.scroll_px;
    }

    /// The rectangle of tab `i` (client pixels), also where it is scrolled
    /// out of view.
    pub fn tabRect(self: *const Layout, i: usize) Rect {
        if (i >= self.count) return .empty;
        const left = self.clientX(self.contentLeft(i));
        return .{ .left = left, .top = self.top, .right = left + self.width(i), .bottom = self.bottom };
    }

    /// The part of tab `i` that shows (empty when scrolled out of view).
    pub fn visibleRect(self: *const Layout, i: usize) Rect {
        const r = self.tabRect(i);
        const shown: Rect = .{ .left = @max(r.left, self.view_left), .top = r.top, .right = @min(r.right, self.view_right), .bottom = r.bottom };
        return if (shown.isEmpty()) .empty else shown;
    }

    /// The hover fill of the close button of a tab at `tab` (client
    /// pixels), centered on the tab's height.
    pub fn closeRectOf(self: *const Layout, tab: Rect) Rect {
        const size = px(close_size, self.scale);
        const right = tab.right - px(close_margin, self.scale);
        const top = tab.top + @divTrunc(tab.height() - size, 2);
        return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
    }

    /// The part of a tab at `tab` that takes clicks for its close button:
    /// the right end, the full height of the hit rectangles.
    pub fn closeHitOf(self: *const Layout, tab: Rect) Rect {
        return .{
            .left = tab.right - px(close_hit_width, self.scale),
            .top = self.hit_top,
            .right = tab.right,
            .bottom = tab.bottom,
        };
    }

    /// Whether a tab `w` pixels wide is wide enough for a close button
    /// next to some text.
    pub fn closable(self: *const Layout, w: i32) bool {
        return w >= 2 * px(close_hit_width, self.scale);
    }

    /// `rect` reaching up to the top of the hit rectangles.
    pub fn hitRect(self: *const Layout, rect: Rect) Rect {
        if (rect.isEmpty()) return rect;
        return .{ .left = rect.left, .top = @min(rect.top, self.hit_top), .right = rect.right, .bottom = rect.bottom };
    }

    /// The tab whose hit rectangle holds client point `x`, `y`, if any and
    /// in view.
    pub fn tabAt(self: *const Layout, x: i32, y: i32) ?usize {
        if (x < self.view_left or x >= self.view_right) return null;
        if (y < self.hit_top or y >= self.bottom) return null;
        for (0..self.count) |i| {
            const r = self.tabRect(i);
            if (x >= r.left and x < r.right) return i;
        }
        return null;
    }

    /// The scroll (DIPs) that shows all of tab `i`, moving as little as
    /// possible from the current one.
    pub fn revealScroll(self: *const Layout, i: usize) f32 {
        if (!self.overflow or i >= self.count) return 0;
        const view = self.view_right - self.view_left;
        const left = self.contentLeft(i);
        const right = left + self.width(i);
        var scroll = self.scroll_px;
        if (left < scroll) scroll = left;
        if (right > scroll + view) scroll = right - view;
        scroll = std.math.clamp(scroll, 0, self.max_scroll_px);
        return @as(f32, @floatFromInt(scroll)) / self.scale;
    }

    /// Whether tabs are hidden before (`back`) or after the view.
    pub fn clipped(self: *const Layout, back: bool) bool {
        if (!self.overflow) return false;
        return if (back) self.scroll_px > 0 else self.scroll_px < self.max_scroll_px;
    }
};

/// The widths of the tabs among `count` with `avail` pixels for them.
const Widths = struct { tab_w: i32, active_w: i32, overflow: bool };

fn widthsFor(avail: i32, count: usize, scale: f32) Widths {
    const max_w = px(max_width, scale);
    const min_w = px(min_width, scale);
    const active_min = px(active_min_width, scale);
    if (count == 0) return .{ .tab_w = 0, .active_w = 0, .overflow = false };
    const n: i32 = @intCast(count);
    const room = @max(avail, 0);
    const equal = @min(@divTrunc(room, n), max_w);
    if (equal >= active_min) return .{ .tab_w = equal, .active_w = equal, .overflow = false };
    if (count == 1) return .{ .tab_w = room, .active_w = @min(room, max_w), .overflow = false };
    const others = @divTrunc(room - active_min, n - 1);
    if (others >= min_w) return .{ .tab_w = others, .active_w = active_min, .overflow = false };
    return .{ .tab_w = min_w, .active_w = active_min, .overflow = true };
}

/// Lay out the tab strip (see the file header).
pub fn compute(input: Input) Layout {
    const s = input.scale;
    const area = input.area;
    const gap = px(buttons_gap, s);
    const new_w = px(new_tab_width, s);
    const prof_w = px(profile_width, s);
    const trailing = gap + new_w + prof_w;
    const count = input.count;
    const active = @min(input.active, if (count > 0) count - 1 else 0);

    var lay: Layout = .{
        .count = count,
        .active = active,
        .scale = s,
        .top = area.top,
        .bottom = area.bottom,
        .hit_top = @min(input.hit_top, area.top),
    };

    var left = area.left;
    if (input.badge) {
        const w = px(badge_width, s);
        lay.badge = .{ .left = left, .top = area.top, .right = left + w, .bottom = area.bottom };
        left += w;
    }

    const avail = area.right - left - trailing;
    var widths = widthsFor(avail, count, s);
    if (input.frozen) |frozen| {
        if (frozen.area_w == area.width() and count > 0) {
            const content = frozen.active_w + @as(i32, @intCast(count - 1)) * frozen.tab_w;
            if (content <= avail) widths = .{ .tab_w = frozen.tab_w, .active_w = frozen.active_w, .overflow = false };
        }
    }
    lay.tab_w = widths.tab_w;
    lay.active_w = widths.active_w;
    lay.overflow = widths.overflow;
    lay.content_w = if (count == 0) 0 else widths.active_w + @as(i32, @intCast(count - 1)) * widths.tab_w;

    const btn_h = px(row_button_height, s);
    const btn_top = area.top + @divTrunc(area.bottom - area.top - btn_h, 2);
    const scroll_w = px(scroll_button_width, s);
    const scroll_h = px(scroll_button_height, s);
    const scroll_top = area.top + @divTrunc(area.bottom - area.top - scroll_h, 2);

    var x: i32 = undefined;
    if (lay.overflow) {
        const list_w = px(list_button_width, s);
        lay.scroll_back = .{ .left = left, .top = scroll_top, .right = left + scroll_w, .bottom = scroll_top + scroll_h };
        lay.view_left = lay.scroll_back.right;
        lay.view_right = @max(lay.view_left, area.right - trailing - scroll_w - list_w);
        lay.scroll_forward = .{ .left = lay.view_right, .top = scroll_top, .right = lay.view_right + scroll_w, .bottom = scroll_top + scroll_h };
        lay.list = .{ .left = lay.scroll_forward.right, .top = btn_top, .right = lay.scroll_forward.right + list_w, .bottom = btn_top + btn_h };
        lay.max_scroll_px = @max(0, lay.content_w - (lay.view_right - lay.view_left));
        lay.scroll_px = std.math.clamp(px(input.scroll, s), 0, lay.max_scroll_px);
        x = lay.list.right + gap;
    } else {
        lay.view_left = left;
        lay.view_right = @max(left, area.right - trailing);
        x = @min(left + lay.content_w, lay.view_right) + gap;
    }
    lay.new_tab = .{ .left = x, .top = btn_top, .right = x + new_w, .bottom = btn_top + btn_h };
    lay.profiles = .{ .left = lay.new_tab.right, .top = btn_top, .right = lay.new_tab.right + prof_w, .bottom = btn_top + btn_h };
    return lay;
}

/// Freeze the widths of `lay` (see `Frozen`).
pub fn freeze(lay: *const Layout, area_w: i32) Frozen {
    return .{ .tab_w = lay.tab_w, .active_w = lay.active_w, .area_w = area_w };
}

// -----------------------------------------------------------------------
// Dragging
// -----------------------------------------------------------------------

/// The slot (0 to `count` - 1) a dragged tab lands in when its left edge is
/// at content x `left` and the other tabs are `tab_w` wide: it takes a
/// neighbor's place once it moved over half of it (its leading edge passed
/// the neighbor's middle).
pub fn dragTarget(left: i32, tab_w: i32, count: usize) usize {
    if (count <= 1 or tab_w <= 0) return 0;
    const slot = @divFloor(2 * left + tab_w, 2 * tab_w);
    const last: i32 = @intCast(count - 1);
    return @intCast(std.math.clamp(slot, 0, last));
}

/// The index tab `index` shows at while the tab at `from` sits at `to`, the
/// others shifted over (like `tabs.movedIndex`).
pub fn displayIndex(index: usize, from: usize, to: usize) usize {
    if (index == from) return to;
    if (from < to and index > from and index <= to) return index - 1;
    if (to < from and index >= to and index < from) return index + 1;
    return index;
}

/// Where (content x) the tab at `index` starts while the tab at `from`,
/// `drag_w` wide, is dragged to slot `to` and the other tabs are `tab_w`
/// wide.
pub fn dragSlotLeft(index: usize, from: usize, to: usize, tab_w: i32, drag_w: i32) i32 {
    const d: i32 = @intCast(displayIndex(index, from, to));
    const t: i32 = @intCast(to);
    if (index == from) return t * tab_w;
    if (d < t) return d * tab_w;
    return (d - 1) * tab_w + drag_w;
}

// -----------------------------------------------------------------------
// Labels
// -----------------------------------------------------------------------

/// Between the program and the title of a label.
pub const separator = " \u{00B7} ";

/// What runs in a tab's focused terminal, as far as its label goes.
pub const Program = struct {
    /// The display name (no directory or `.exe`).
    name: []const u8,
    /// The shell itself or another process that counts as idle
    /// (`gx-idle-processes`): the label is the title alone.
    idle: bool = false,
    /// WSL, whose programs Windows does not see: `wsl` is no program name.
    wsl: bool = false,
    /// The display name of the terminal's shell, if known. A title that
    /// names it is the shell's own: the program just exited and the label
    /// is the title alone until the next lookup.
    shell: []const u8 = "",
};

/// The text of a tab: `program` (drawn in the secondary color) and
/// `title`, with `separator` between them when both are there.
pub const Label = struct {
    program: []const u8 = "",
    title: []const u8 = "",

    /// Write the label as one line into `buf`, cut at a codepoint boundary.
    pub fn write(self: Label, buf: []u8) []const u8 {
        const parts = [_][]const u8{ self.program, if (self.program.len > 0 and self.title.len > 0) separator else "", self.title };
        var len: usize = 0;
        for (parts) |part| {
            const kept = utf8Prefix(part, buf.len - len);
            @memcpy(buf[len..][0..kept.len], kept);
            len += kept.len;
            if (kept.len < part.len) break;
        }
        return buf[0..len];
    }
};

/// The label of a tab (D4) whose title is `title_raw` (UTF-8): an
/// `overridden` title (renamed, `set_tab_title`) shows as it is. Otherwise
/// the title is simplified (`simplifyTitle`) and counts as none when it is
/// empty or `default_title`; an idle shell, WSL or a title that names the
/// shell shows the title alone, a running program shows as
/// `program · title` unless the title already names it. Without a title the
/// program names the tab, and without either `default_title` does.
pub fn label(overridden: bool, title_raw: []const u8, default_title: []const u8, program: ?Program) Label {
    if (overridden) return .{ .title = title_raw };
    const simplified = simplifyTitle(title_raw);
    const title: ?[]const u8 = if (simplified.len == 0 or std.mem.eql(u8, simplified, default_title)) null else simplified;
    const p = program orelse return .{ .title = title orelse default_title };
    if (p.name.len == 0) return .{ .title = title orelse default_title };
    const t = title orelse return .{ .title = p.name };
    if (p.idle or p.wsl) return .{ .title = t };
    if (p.shell.len > 0 and std.ascii.eqlIgnoreCase(t, p.shell)) return .{ .title = t };
    if (std.ascii.eqlIgnoreCase(t, p.name)) return .{ .title = p.name };
    if (t.len > p.name.len and std.ascii.startsWithIgnoreCase(t, p.name) and
        (t[p.name.len] == ' ' or t[p.name.len] == ':'))
    {
        return .{ .title = t };
    }
    return .{ .program = p.name, .title = t };
}

/// A title that is an executable path (`C:\Windows\system32\cmd.exe`,
/// also with an `Administrator: ` prefix) becomes the executable name, and
/// the `<shell path> - <command>` title of a console shell running a
/// command becomes the command.
pub fn simplifyTitle(title: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, title, " ");
    if (std.ascii.findIgnoreCase(trimmed, ".exe - ")) |i| {
        return std.mem.trim(u8, trimmed[i + ".exe - ".len ..], " ");
    }
    if (!std.ascii.endsWithIgnoreCase(trimmed, ".exe")) return trimmed;
    const sep = std.mem.lastIndexOfAny(u8, trimmed, "\\/") orelse return trimmed[0 .. trimmed.len - 4];
    return trimmed[sep + 1 .. trimmed.len - 4];
}

// -----------------------------------------------------------------------
// Colors
// -----------------------------------------------------------------------

/// A color in sRGB components and alpha, 0 to 1.
pub const Rgba = struct { r: f32, g: f32, b: f32, a: f32 };

/// The straight-alpha color that Direct2D, premultiplying in gamma space,
/// turns into the pixel the OpenGL renderer writes for the terminal
/// background `rgb` at `opacity`: the alpha quantized to 8 bits first, the
/// color premultiplied in linear light when `linear` (`alpha-blending`),
/// as `Backdrop.fillBackground` writes the window background. The active
/// tab filled with it over a transparent strip matches the terminal below.
pub fn straightFill(rgb: [3]u8, opacity: f64, linear: bool) Rgba {
    const a8 = @round(std.math.clamp(opacity, 0, 1) * 255);
    const a = a8 / 255;
    if (a8 == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    var out: [3]f32 = undefined;
    for (rgb, &out) |value, *channel| {
        const c = @as(f64, @floatFromInt(value)) / 255;
        const premultiplied = if (linear) linearToSrgb(srgbToLinear(c) * a) else c * a;
        // The renderer writes whole 8-bit values.
        const stored = @round(premultiplied * 255) / 255;
        channel.* = @floatCast(@min(1, stored / a));
    }
    return .{ .r = out[0], .g = out[1], .b = out[2], .a = @floatCast(a) };
}

fn srgbToLinear(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f64) f64 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
}

pub const Cache = struct {
    input: ?Input = null,
    layout: Layout = .{},

    pub fn get(self: *const Cache, input: Input) Layout {
        if (self.input) |old| {
            if (std.meta.eql(old, input)) return self.layout;
        }
        return compute(input);
    }

    pub fn update(self: *Cache, input: Input) Layout {
        const result = self.get(input);
        self.* = .{ .input = input, .layout = result };
        return result;
    }
};

pub const Polling = struct {
    unread_ms: ?u64 = null,
    programs_ms: ?u64 = null,

    pub fn unreadDue(self: *Polling, now: u64, active: bool, visible: bool, count: usize) bool {
        if (!visible or count <= 1) return false;
        if (!due(self.unread_ms, now, if (active) 1000 else 5000)) return false;
        self.unread_ms = now;
        return true;
    }

    pub fn programsDue(self: *const Polling, now: u64, active: bool) bool {
        return due(self.programs_ms, now, if (active) 2000 else 5000);
    }
};

pub const MiddlePress = struct {
    target: ?u64 = null,

    pub fn down(self: *MiddlePress, target: ?u64) void {
        self.target = target;
    }

    pub fn cancel(self: *MiddlePress) void {
        self.target = null;
    }

    pub fn release(self: *MiddlePress, target: ?u64) bool {
        const pressed = self.target;
        self.cancel();
        return pressed != null and pressed == target;
    }
};

pub fn due(last: ?u64, now: u64, interval: u64) bool {
    return if (last) |previous| now -| previous >= interval else true;
}

pub fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end < text.len and end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "middle presses close only one matched live target" {
    var press: MiddlePress = .{};
    try testing.expect(!press.release(10));
    press.down(10);
    try testing.expect(press.release(10));
    try testing.expect(!press.release(10));
    press.down(10);
    try testing.expect(!press.release(20));
    try testing.expect(!press.release(10));
    press.down(null);
    try testing.expect(!press.release(10));
    press.down(10);
    try testing.expect(!press.release(null));
    press.down(10);
    press.cancel();
    try testing.expect(!press.release(10));
    press.down(10);
    press.down(20);
    try testing.expect(press.release(20));
}

test "cached geometry follows every layout input" {
    var cache: Cache = .{};
    var input = testInput(800, 30);
    _ = cache.update(input);
    try testing.expectEqualDeep(compute(input), cache.get(input));
    input.active = 12;
    input.scroll = 50;
    input.hit_top = 0;
    input.scale = 1.5;
    input.badge = true;
    try testing.expectEqualDeep(compute(input), cache.get(input));
    _ = cache.update(input);
    input.frozen = freeze(&cache.layout, input.area.width());
    input.count -= 1;
    try testing.expectEqualDeep(compute(input), cache.get(input));
    input.area.right += 100;
    try testing.expectEqualDeep(compute(input), cache.get(input));
}

test "unread polling skips hidden and single tab bars and slows inactive windows" {
    var polling: Polling = .{};
    try testing.expect(!polling.unreadDue(0, true, false, 10));
    try testing.expect(!polling.unreadDue(0, true, true, 1));
    try testing.expectEqual(@as(?u64, null), polling.unread_ms);
    try testing.expect(polling.unreadDue(0, true, true, 2));
    try testing.expect(!polling.unreadDue(999, true, true, 2));
    try testing.expect(polling.unreadDue(1000, true, true, 2));
    try testing.expect(!polling.unreadDue(5999, false, true, 2));
    try testing.expect(polling.unreadDue(6000, false, true, 2));
    try testing.expect(polling.unreadDue(7000, true, true, 2));
}

test "program polling never refreshes twice around a time bucket boundary" {
    var polling: Polling = .{};
    try testing.expect(polling.programsDue(1999, true));
    polling.programs_ms = 1999;
    try testing.expect(!polling.programsDue(2000, true));
    try testing.expect(!polling.programsDue(3998, true));
    try testing.expect(polling.programsDue(3999, true));
    try testing.expect(!polling.programsDue(6998, false));
    try testing.expect(polling.programsDue(6999, false));
    try testing.expect(!due(1999, 100, 2000));
}

test "utf8 prefixes never split a codepoint" {
    const text = "a\u{6C49}\u{1F47B}z";
    for (0..text.len + 2) |limit| {
        const kept = utf8Prefix(text, limit);
        try testing.expect(kept.len <= limit);
        try testing.expect(std.unicode.utf8ValidateSlice(kept));
        try testing.expect(std.mem.startsWith(u8, text, kept));
    }
    try testing.expectEqualStrings("a", utf8Prefix(text, 3));
    try testing.expectEqualStrings("a\u{6C49}", utf8Prefix(text, 7));
}

test "labels truncate at codepoint boundaries" {
    const lbl: Label = .{ .program = "\u{6C49}", .title = "\u{1F47B}notes" };
    var buffer: [20]u8 = undefined;
    for (0..buffer.len + 1) |limit| {
        const text = lbl.write(buffer[0..limit]);
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(std.mem.startsWith(u8, "\u{6C49} \u{00B7} \u{1F47B}notes", text));
    }
}

fn testInput(right: i32, count: usize) Input {
    return .{
        .area = .{ .left = 8, .top = 8, .right = right, .bottom = 40 },
        .hit_top = 8,
        .scale = 1,
        .count = count,
        .active = 0,
    };
}

test "tabs share the strip in equal widths up to the maximum" {
    const two = compute(testInput(1000, 2));
    try testing.expect(!two.overflow);
    try testing.expectEqual(@as(i32, 240), two.tab_w);
    try testing.expectEqual(@as(i32, 240), two.active_w);
    try testing.expectEqual(@as(i32, 8), two.tabRect(0).left);
    try testing.expectEqual(two.tabRect(0).right, two.tabRect(1).left);
    // The new-tab button follows the last tab.
    try testing.expectEqual(@as(i32, 8 + 480 + 4), two.new_tab.left);
    try testing.expectEqual(two.new_tab.right, two.profiles.left);
    try testing.expectEqual(@as(i32, 8), two.tabRect(1).top);
    try testing.expectEqual(@as(i32, 40), two.tabRect(1).bottom);

    // Twelve tabs in 1200 px: 1136 px for the tabs, 94 each would leave
    // the active tab under its floor, so it keeps 120 and the rest get 92.
    var twelve = testInput(1200, 12);
    twelve.active = 5;
    const lay = compute(twelve);
    try testing.expect(!lay.overflow);
    try testing.expectEqual(@as(i32, 120), lay.active_w);
    try testing.expectEqual(@as(i32, 92), lay.tab_w);
    try testing.expectEqual(lay.tabRect(4).right, lay.tabRect(5).left);
    try testing.expectEqual(@as(i32, 120), lay.tabRect(5).width());
    try testing.expectEqual(lay.tabRect(5).right, lay.tabRect(6).left);
    try testing.expect(lay.tabRect(11).right <= lay.view_right);
}

test "the active tab keeps its floor and the rest scroll" {
    var input = testInput(800, 30);
    input.active = 20;
    const lay = compute(input);
    try testing.expect(lay.overflow);
    try testing.expectEqual(@as(i32, 72), lay.tab_w);
    try testing.expectEqual(@as(i32, 120), lay.active_w);
    try testing.expectEqual(@as(i32, 29 * 72 + 120), lay.content_w);
    // Scroll buttons around the view, the list button and "+" after it.
    try testing.expectEqual(@as(i32, 8), lay.scroll_back.left);
    try testing.expectEqual(lay.scroll_back.right, lay.view_left);
    try testing.expectEqual(lay.view_right, lay.scroll_forward.left);
    try testing.expectEqual(lay.scroll_forward.right, lay.list.left);
    try testing.expectEqual(lay.list.right + 4, lay.new_tab.left);
    try testing.expectEqual(@as(i32, 800), lay.profiles.right);
    try testing.expectEqual(lay.content_w - (lay.view_right - lay.view_left), lay.max_scroll_px);
    try testing.expect(!lay.clipped(true));
    try testing.expect(lay.clipped(false));

    // Revealing the active tab scrolls just enough.
    input.scroll = lay.revealScroll(20);
    const shown = compute(input);
    try testing.expectEqual(shown.view_right, shown.tabRect(20).right);
    try testing.expect(shown.clipped(true));
    try testing.expectEqual(@as(?usize, 20), shown.tabAt(shown.view_right - 1, 20));
    // Tabs scrolled out of view take no clicks.
    try testing.expectEqual(@as(?usize, null), shown.tabAt(shown.view_left - 1, 20));
    try testing.expect(shown.visibleRect(0).isEmpty());

    // The scroll is clamped.
    input.scroll = 1e6;
    const end = compute(input);
    try testing.expectEqual(end.max_scroll_px, end.scroll_px);
    try testing.expect(!end.clipped(false));
    input.scroll = -5;
    try testing.expectEqual(@as(i32, 0), compute(input).scroll_px);
}

test "the layout follows the scale" {
    var input = testInput(1500, 3);
    input.scale = 1.5;
    const lay = compute(input);
    try testing.expectEqual(@as(i32, 360), lay.tab_w);
    try testing.expectEqual(@as(i32, 42), lay.closeHitOf(lay.tabRect(0)).width());
    try testing.expectEqual(@as(i32, 36), lay.closeRectOf(lay.tabRect(0)).width());
    try testing.expectEqual(lay.tabRect(0).right - 6, lay.closeRectOf(lay.tabRect(0)).right);
}

test "a single tab takes the strip up to the maximum" {
    const narrow = compute(testInput(100, 1));
    try testing.expect(!narrow.overflow);
    try testing.expectEqual(@as(i32, 100 - 8 - 56), narrow.active_w);
    const wide = compute(testInput(2000, 1));
    try testing.expectEqual(@as(i32, 240), wide.active_w);
    const none = compute(testInput(2000, 0));
    try testing.expectEqual(@as(i32, 0), none.content_w);
    try testing.expectEqual(@as(i32, 8 + 4), none.new_tab.left);
}

test "frozen widths hold until the strip changes" {
    var input = testInput(1000, 6);
    const before = compute(input);
    try testing.expectEqual(@as(i32, 156), before.tab_w);
    const frozen = freeze(&before, input.area.width());
    input.count = 5;
    input.frozen = frozen;
    const after = compute(input);
    try testing.expectEqual(@as(i32, 156), after.tab_w);
    // The next tab's close button is where the closed one's was.
    try testing.expectEqual(before.closeHitOf(before.tabRect(2)), after.closeHitOf(after.tabRect(2)));
    // A resized strip lays out anew.
    input.area.right = 1200;
    try testing.expect(compute(input).tab_w != 156);
}

test "the badge comes before the tabs" {
    var input = testInput(1000, 2);
    input.badge = true;
    const lay = compute(input);
    try testing.expectEqual(@as(i32, 8), lay.badge.left);
    try testing.expectEqual(@as(i32, 36), lay.tabRect(0).left);
}

test "hit rectangles reach the top of a maximized window" {
    var input = testInput(1000, 2);
    input.hit_top = 0;
    const lay = compute(input);
    try testing.expectEqual(@as(?usize, 0), lay.tabAt(10, 0));
    try testing.expectEqual(@as(i32, 0), lay.closeHitOf(lay.tabRect(1)).top);
    try testing.expectEqual(@as(i32, 0), lay.hitRect(lay.new_tab).top);
    const normal = compute(testInput(1000, 2));
    try testing.expectEqual(@as(?usize, null), normal.tabAt(10, 4));
    try testing.expectEqual(@as(?usize, 1), normal.tabAt(250, 39));
    try testing.expectEqual(@as(?usize, null), normal.tabAt(250, 40));
}

test "a dragged tab passes a neighbor at its middle" {
    try testing.expectEqual(@as(usize, 0), dragTarget(-30, 100, 4));
    try testing.expectEqual(@as(usize, 0), dragTarget(49, 100, 4));
    try testing.expectEqual(@as(usize, 1), dragTarget(50, 100, 4));
    try testing.expectEqual(@as(usize, 1), dragTarget(149, 100, 4));
    try testing.expectEqual(@as(usize, 3), dragTarget(1000, 100, 4));
    try testing.expectEqual(@as(usize, 0), dragTarget(500, 100, 1));

    // [A B C D], B (120 wide) dragged to slot 3: A C D B.
    try testing.expectEqual(@as(i32, 0), dragSlotLeft(0, 1, 3, 100, 120));
    try testing.expectEqual(@as(i32, 100), dragSlotLeft(2, 1, 3, 100, 120));
    try testing.expectEqual(@as(i32, 200), dragSlotLeft(3, 1, 3, 100, 120));
    try testing.expectEqual(@as(i32, 300), dragSlotLeft(1, 1, 3, 100, 120));
    // D dragged to slot 0: D A B C.
    try testing.expectEqual(@as(i32, 120), dragSlotLeft(0, 3, 0, 100, 120));
    try testing.expectEqual(@as(i32, 320), dragSlotLeft(2, 3, 0, 100, 120));
    try testing.expectEqual(@as(usize, 2), displayIndex(1, 3, 0));
}

test "labels show the title of an idle shell and the program otherwise" {
    const ghostty = "Ghostty";
    const zsh: Program = .{ .name = "zsh", .idle = true };
    const vim: Program = .{ .name = "vim" };
    var buf: [128]u8 = undefined;

    // Idle shells: the title alone, or the shell without one.
    try testing.expectEqualStrings("~/src/ghostty", label(false, "~/src/ghostty", ghostty, zsh).write(&buf));
    try testing.expectEqualStrings("zsh", label(false, "", ghostty, zsh).write(&buf));
    try testing.expectEqualStrings("zsh", label(false, "Ghostty", ghostty, zsh).write(&buf));
    const cmd: Program = .{ .name = "cmd", .idle = true };
    try testing.expectEqualStrings("cmd", label(false, "C:\\WINDOWS\\system32\\cmd.exe", ghostty, cmd).write(&buf));
    try testing.expectEqualStrings("cmd", label(false, "Administrator: C:\\WINDOWS\\system32\\cmd.exe", ghostty, cmd).write(&buf));

    // A running program comes first, in its own part.
    const busy = label(false, "~/src", ghostty, vim);
    try testing.expectEqualStrings("vim", busy.program);
    try testing.expectEqualStrings("~/src", busy.title);
    try testing.expectEqualStrings("vim \u{00B7} ~/src", busy.write(&buf));
    try testing.expectEqualStrings("vim notes.md", label(false, "vim notes.md", ghostty, vim).write(&buf));
    try testing.expectEqualStrings("vim", label(false, "VIM", ghostty, vim).write(&buf));
    try testing.expectEqualStrings("vim", label(false, "Ghostty", ghostty, vim).write(&buf));
    const ping: Program = .{ .name = "PING" };
    try testing.expectEqualStrings("ping  -t 127.0.0.1", label(false, "C:\\WINDOWS\\SYSTEM32\\cmd.exe - ping  -t 127.0.0.1", ghostty, ping).write(&buf));
    // The program exited and the shell took its title back before the
    // next lookup.
    const ping_in_cmd: Program = .{ .name = "PING", .shell = "cmd" };
    try testing.expectEqualStrings("cmd", label(false, "C:\\WINDOWS\\SYSTEM32\\cmd.exe", ghostty, ping_in_cmd).write(&buf));
    try testing.expectEqualStrings("PING \u{00B7} ~/src", label(false, "~/src", ghostty, ping_in_cmd).write(&buf));

    // WSL: the title alone.
    const wsl: Program = .{ .name = "wsl", .wsl = true };
    try testing.expectEqualStrings("user@host: ~", label(false, "user@host: ~", ghostty, wsl).write(&buf));
    try testing.expectEqualStrings("wsl", label(false, "", ghostty, wsl).write(&buf));

    // Unknown program: the simplified title, else the default.
    try testing.expectEqualStrings("pwsh", label(false, "C:\\Program Files\\PowerShell\\7\\pwsh.exe", ghostty, null).write(&buf));
    try testing.expectEqualStrings("Ghostty", label(false, "", ghostty, null).write(&buf));

    // A renamed tab shows its name as it is.
    try testing.expectEqualStrings("Build", label(true, "Build", ghostty, vim).write(&buf));
    try testing.expectEqualStrings("Ghostty", label(true, "Ghostty", ghostty, vim).write(&buf));

    // A buffer too small cuts the label off.
    var small: [5]u8 = undefined;
    const cut = busy.write(&small);
    try testing.expect(cut.len <= small.len);
    try testing.expect(std.mem.startsWith(u8, "vim \u{00B7} ~/src", cut));
}

test "the active tab fill premultiplies like the renderer" {
    const opaque_fill = straightFill(.{ 0x1f, 0x1f, 0x28 }, 1, true);
    try testing.expectApproxEqAbs(@as(f32, 0x1f) / 255, opaque_fill.r, 1e-6);
    try testing.expectEqual(@as(f32, 1), opaque_fill.a);
    try testing.expectEqual(@as(f32, 0), straightFill(.{ 0xff, 0xff, 0xff }, 0, true).a);

    // GX Mocha at 0.8 in linear light: the renderer writes 0xcc1b1b23.
    const fill = straightFill(.{ 0x1f, 0x1f, 0x28 }, 0.8, true);
    try testing.expectApproxEqAbs(@as(f32, 0xcc) / 255, fill.a, 1e-6);
    for ([_]f32{ fill.r, fill.g, fill.b }, [_]u8{ 0x1b, 0x1b, 0x23 }) |channel, expected| {
        const stored: u8 = @intFromFloat(@round(channel * fill.a * 255));
        try testing.expectEqual(expected, stored);
    }
    // Without linear blending it is the color itself.
    const plain = straightFill(.{ 0x20, 0x40, 0xff }, 0.5, false);
    try testing.expectApproxEqAbs(@as(f32, 0x10) / 255 / plain.a, plain.r, 1e-6);
}
