//! Geometry of the chrome row of a top-level window as pure functions of
//! what the window knows: the layout of the row (`compute`) from the client
//! width, the row height, the frame, whether the window is maximized, its
//! content scale (`Window.scale`), the top resize band and where DWM draws
//! its caption buttons; what a point of the row hits (`hit`, `ncHit`); and
//! the smallest window the row fits in (`minTrackSize`), which `Window`
//! reports in `WM_GETMINMAXINFO`. `chrome/TitleBar.zig` gathers the inputs
//! from the window. Only depends on `std` and `win32.RECT`.
const std = @import("std");
const RECT = @import("../win32.zig").RECT;

pub const empty_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Height of the integrated title bar row in DIPs (`style.metrics`).
pub const title_bar_height: f32 = 40;
/// Width of a caption button (minimize, maximize/restore, close) in DIPs.
pub const caption_button_width: f32 = 46;
/// Height of the row buttons (main menu, new tab) in DIPs.
pub const row_button_height: f32 = 28;
/// Width of the main menu button in DIPs.
pub const menu_button_width: f32 = 36;

/// Where the tabs start below the top of a row the client area extends
/// over (below the top resize band) and of a plain tab row, in DIPs.
const top_margin: f32 = 8;
const top_margin_row: f32 = 4;
/// Left margin of the tabs next to a restored integrated title bar and
/// elsewhere, in DIPs.
const left_margin_caption: f32 = 8;
const left_margin: f32 = 6;
/// Gap between the main menu button and the caption buttons, or the right
/// edge of a row without them, in DIPs.
const menu_gap_caption: f32 = 4;
const menu_gap: f32 = 6;
/// The empty title bar kept left of the main menu button to drag the
/// window by, in DIPs: next to caption buttons, on another row that drags,
/// and on one that does not.
const drag_reserve_caption: f32 = 40;
const drag_reserve_row: f32 = 24;
const drag_reserve_none: f32 = 4;
/// One 72-DIP tab and the new-tab and launch profile buttons with their gap.
const min_tab_row: f32 = 128;
/// The invisible resize border plus the visible border of a window side
/// at 100% (`SM_CXSIZEFRAME` + `SM_CXPADDEDBORDER`), in DIPs.
const frame_border: f32 = 8;

/// A size in pixels.
pub const Size = struct {
    width: i32,
    height: i32,
};

/// What frames the client area.
pub const Frame = enum {
    /// Integrated title bar row with caption buttons.
    custom,
    /// System caption; the chrome row is a plain tab row.
    native,
    /// Native resize borders without a caption.
    borderless,
    fullscreen,
    /// Quick terminal: no chrome.
    popup,

    /// Whether `WM_NCCALCSIZE` extends the client area over the caption.
    pub fn extendsClient(self: Frame) bool {
        return switch (self) {
            .custom, .borderless => true,
            .native, .fullscreen, .popup => false,
        };
    }
};

/// The buttons of the title bar row (the tab bar has its own).
pub const Button = enum { none, minimize, maximize, close, menu };

/// Who draws the caption buttons of an integrated title bar.
pub const CaptionButtons = union(enum) {
    /// The title bar draws its own.
    own,
    /// DWM draws them (a window material shows through the row), at these
    /// client pixels, or where it did not say (null): the row then leaves
    /// them no room.
    dwm: ?RECT,
};

/// What the layout of the row depends on.
pub const Input = struct {
    /// Client width in pixels.
    width: i32,
    /// Height of the chrome row in pixels; 0 when the window has none.
    bar_height: i32,
    frame: Frame,
    /// Whether the window is maximized.
    zoomed: bool = false,
    /// Content scale (`Window.scale`).
    scale: f32 = 1,
    /// Height in pixels of the invisible top resize border the system
    /// gives the other edges (at the window's real DPI). Only a restored
    /// window whose client area extends over the caption has one.
    resize_band: i32 = 0,
    buttons: CaptionButtons = .own,
};

/// The chrome row of the window in client pixels.
pub const Layout = struct {
    /// The whole row; empty when the window has no chrome row.
    bar: RECT = empty_rect,
    /// Whether the row has caption buttons (integrated title bar).
    caption: bool = false,
    minimize: RECT = empty_rect,
    maximize: RECT = empty_rect,
    close: RECT = empty_rect,
    menu: RECT = empty_rect,
    /// Where the tab bar lays out its tabs and new-tab buttons.
    tabs: RECT = empty_rect,
    /// Top of the tabs (and the row buttons) inside `bar`.
    content_top: i32 = 0,
    /// Where hits on the tabs and the main menu button start: the top of
    /// the row when it touches the top of the screen (a maximized window
    /// whose client area extends over the caption, a fullscreen one), so
    /// a pointer pushed against the screen edge still hits them; else
    /// `content_top`.
    hit_top: i32 = 0,
    /// Height of the top resize band, 0 when the top edge does not resize.
    resize_band: i32 = 0,
    /// Whether the empty parts of the row drag the window.
    draggable: bool = false,
    scale: f32 = 1.0,

    pub fn height(self: Layout) i32 {
        return self.bar.bottom - self.bar.top;
    }

    /// Client `y` as the tab bar should see it: a point above the tabs
    /// within `hit_top` moves down onto their top edge.
    pub fn tabY(self: Layout, y: i32) i32 {
        return if (y >= self.hit_top and y < self.content_top) self.content_top else y;
    }

    /// The rectangle of `button` (empty for `.none` and for buttons the
    /// row does not draw), what changes when it is hovered or pressed.
    pub fn buttonRect(self: Layout, button: Button) RECT {
        return switch (button) {
            .none => empty_rect,
            .minimize => self.minimize,
            .maximize => self.maximize,
            .close => self.close,
            .menu => self.menu,
        };
    }

    /// Where the main menu button takes hits: its rectangle, reaching up
    /// to `hit_top`.
    pub fn menuHitRect(self: Layout) RECT {
        var rect = self.menu;
        if (rect.right > rect.left) rect.top = @min(rect.top, self.hit_top);
        return rect;
    }
};

/// A DIP length in pixels at `scale` (`style.px`).
fn px(length: f32, scale: f32) i32 {
    return @intFromFloat(@round(length * scale));
}

pub fn contains(rect: RECT, x: i32, y: i32) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

/// The chrome row for `in`.
pub fn compute(in: Input) Layout {
    const s = in.scale;
    const bar_h = in.bar_height;
    if (bar_h <= 0 or in.width <= 0) return .{ .scale = s };
    const caption = in.frame == .custom;
    const extends = in.frame.extendsClient();
    var lay: Layout = .{
        .bar = .{ .left = 0, .top = 0, .right = in.width, .bottom = bar_h },
        .caption = caption,
        .scale = s,
        .draggable = in.frame != .fullscreen and in.frame != .popup,
        .resize_band = if (extends and !in.zoomed) @max(in.resize_band, 0) else 0,
    };

    // Tabs hang from the top margin (below the top resize band of an
    // extended client area) and touch the bottom of the row.
    lay.content_top = px(if (extends) top_margin else top_margin_row, s);
    const at_screen_top = (extends and in.zoomed) or in.frame == .fullscreen;
    lay.hit_top = if (at_screen_top) 0 else lay.content_top;

    var right = in.width;
    // Next to the caption buttons, the main menu button is centered on
    // them like their glyphs: on all of the buttons DWM draws, also where
    // they reach past the top of the client area (a maximized window).
    var caption_top: i32 = 0;
    var caption_bottom: i32 = bar_h;
    if (caption) switch (in.buttons) {
        .own => {
            const bw = px(caption_button_width, s);
            lay.close = .{ .left = right - bw, .top = 0, .right = right, .bottom = bar_h };
            right -= bw;
            lay.maximize = .{ .left = right - bw, .top = 0, .right = right, .bottom = bar_h };
            right -= bw;
            lay.minimize = .{ .left = right - bw, .top = 0, .right = right, .bottom = bar_h };
            right -= bw;
        },
        .dwm => |bounds| {
            if (bounds) |b| {
                right = @min(right, b.left);
                if (b.bottom > b.top) {
                    caption_top = b.top;
                    caption_bottom = b.bottom;
                }
            } else {
                right -= 3 * px(caption_button_width, s);
            }
        },
    };

    // The main menu button, square-ish like the new-tab button.
    const btn_h = px(row_button_height, s);
    const btn_w = px(menu_button_width, s);
    const btn_top = if (caption)
        caption_top + @divTrunc(caption_bottom - caption_top - btn_h, 2)
    else
        lay.content_top + @divTrunc(bar_h - lay.content_top - btn_h, 2);
    right -= px(if (caption) menu_gap_caption else menu_gap, s);
    lay.menu = .{ .left = right - btn_w, .top = btn_top, .right = right, .bottom = btn_top + btn_h };
    right = lay.menu.left;

    // Keep a strip of empty title bar to drag the window by.
    const drag_reserve: f32 = if (lay.draggable)
        (if (caption) drag_reserve_caption else drag_reserve_row)
    else
        drag_reserve_none;
    const left = px(if (caption and !in.zoomed) left_margin_caption else left_margin, s);
    lay.tabs = .{
        .left = left,
        .top = lay.content_top,
        .right = @max(left, right - px(drag_reserve, s)),
        .bottom = bar_h,
    };
    return lay;
}

/// What a client point in the chrome row hits.
pub const Hit = union(enum) {
    /// Not in the chrome row.
    none,
    /// Empty title bar (drag).
    caption,
    button: Button,
    /// The tab bar (tabs, their close buttons, new tab, profiles).
    tabs,
};

/// What client point (`x`, `y`) of `lay` hits; `tabs` says whether the tab
/// bar has a tab or a button at (`x`, `lay.tabY(y)`).
pub fn hit(lay: Layout, x: i32, y: i32, tabs: bool) Hit {
    if (lay.height() <= 0 or y < lay.bar.top or y >= lay.bar.bottom or x < 0 or x >= lay.bar.right) return .none;
    if (lay.caption) {
        if (contains(lay.close, x, y)) return .{ .button = .close };
        if (contains(lay.maximize, x, y)) return .{ .button = .maximize };
        if (contains(lay.minimize, x, y)) return .{ .button = .minimize };
    }
    if (contains(lay.menuHitRect(), x, y)) return .{ .button = .menu };
    if (tabs) return .tabs;
    return .caption;
}

/// The `WM_NCHITTEST` answers for the chrome row.
pub const NcHit = enum { client, caption, top, top_left, top_right, minimize, maximize, close };

/// What `WM_NCHITTEST` reports for client point (`x`, `y`) of `lay` that
/// the default handling put in the client area (`tabs` as for `hit`).
/// Caption buttons reach the top edge, like Windows Terminal's; the rest
/// of the top resize band resizes the window, its ends diagonally.
pub fn ncHit(lay: Layout, x: i32, y: i32, tabs: bool) NcHit {
    const h = hit(lay, x, y, tabs);
    switch (h) {
        .button => |button| switch (button) {
            .minimize => return .minimize,
            .maximize => return .maximize,
            .close => return .close,
            .menu, .none => {},
        },
        else => {},
    }
    if (lay.resize_band > 0 and y >= 0 and y < lay.resize_band) {
        const corner = lay.resize_band * 2;
        if (x < corner) return .top_left;
        if (x >= lay.bar.right - corner) return .top_right;
        return .top;
    }
    return switch (h) {
        .none, .tabs, .button => .client,
        .caption => if (lay.draggable) .caption else .client,
    };
}

/// The smallest window rectangle (pixels, frame included) the chrome of a
/// window at content scale `scale` needs: the least `ptMinTrackSize` of
/// `WM_GETMINMAXINFO`. The integrated title bar row then still holds the
/// caption buttons, the main menu button, a strip to drag the window by
/// and a tab with the new-tab buttons; a terminal's `size_limit` can raise
/// it further.
pub fn minTrackSize(scale: f32) Size {
    const width = 2 * frame_border + left_margin_caption + min_tab_row + drag_reserve_caption +
        menu_button_width + menu_gap_caption + 3 * caption_button_width;
    const height = title_bar_height + frame_border;
    return .{ .width = px(width, scale), .height = px(height, scale) };
}

const testing = std.testing;

fn rectWidth(rect: RECT) i32 {
    return rect.right - rect.left;
}

test "the caption buttons sit at the right edge, the main menu button left of them" {
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |s| {
        const bar_h = px(title_bar_height, s);
        const lay = compute(.{ .width = 1000, .bar_height = bar_h, .frame = .custom, .scale = s, .resize_band = px(8, s) });
        const bw = px(caption_button_width, s);
        try testing.expectEqual(@as(i32, 1000), lay.close.right);
        try testing.expectEqual(bw, rectWidth(lay.close));
        try testing.expectEqual(lay.close.left, lay.maximize.right);
        try testing.expectEqual(lay.maximize.left, lay.minimize.right);
        try testing.expectEqual(@as(i32, 0), lay.close.top);
        try testing.expectEqual(bar_h, lay.close.bottom);
        try testing.expectEqual(lay.minimize.left - px(menu_gap_caption, s), lay.menu.right);
        // The main menu button is centered on the caption buttons.
        try testing.expect(@abs((lay.menu.top + lay.menu.bottom) - bar_h) <= 1);
        try testing.expectEqual(lay.menu.left - px(drag_reserve_caption, s), lay.tabs.right);
        try testing.expectEqual(px(left_margin_caption, s), lay.tabs.left);
        try testing.expectEqual(px(top_margin, s), lay.content_top);
        try testing.expectEqual(lay.content_top, lay.hit_top);
        try testing.expect(lay.caption and lay.draggable);
    }
}

test "a maximized window has no resize band and takes hits up to the screen edge" {
    const lay = compute(.{ .width = 1920, .bar_height = 60, .frame = .custom, .zoomed = true, .scale = 1.5, .resize_band = 12 });
    try testing.expectEqual(@as(i32, 0), lay.resize_band);
    try testing.expectEqual(@as(i32, 0), lay.hit_top);
    try testing.expectEqual(px(left_margin, 1.5), lay.tabs.left);
    // y = 0 above a tab reaches the tab bar at the top of the tabs.
    try testing.expectEqual(lay.content_top, lay.tabY(0));
    try testing.expectEqual(lay.content_top + 3, lay.tabY(lay.content_top + 3));
    // The main menu button takes hits from the top edge too.
    try testing.expectEqual(Hit{ .button = .menu }, hit(lay, lay.menu.left + 2, 0, false));
    try testing.expectEqual(NcHit.caption, ncHit(lay, lay.tabs.right + 4, 0, false));
    try testing.expectEqual(NcHit.client, ncHit(lay, 100, 0, true));

    // A restored window: tabY leaves the point alone, the band resizes.
    const restored = compute(.{ .width = 1920, .bar_height = 60, .frame = .custom, .scale = 1.5, .resize_band = 12 });
    try testing.expectEqual(@as(i32, 0), restored.tabY(0));
    try testing.expectEqual(NcHit.top, ncHit(restored, 400, 0, false));
    // A fullscreen tab row reaches the screen edge as well.
    const full = compute(.{ .width = 1920, .bar_height = 54, .frame = .fullscreen, .scale = 1.5 });
    try testing.expectEqual(@as(i32, 0), full.hit_top);
    try testing.expect(!full.draggable);
    // The system caption is above a native tab row: no.
    const native = compute(.{ .width = 1920, .bar_height = 54, .frame = .native, .zoomed = true, .scale = 1.5 });
    try testing.expectEqual(native.content_top, native.hit_top);
}

test "ncHit: corners, the top edge and the caption buttons" {
    const lay = compute(.{ .width = 800, .bar_height = 40, .frame = .custom, .resize_band = 8 });
    // y = 0 over the close button closes, as in Windows Terminal.
    try testing.expectEqual(NcHit.close, ncHit(lay, 799, 0, false));
    try testing.expectEqual(NcHit.maximize, ncHit(lay, lay.maximize.left, 0, false));
    try testing.expectEqual(NcHit.minimize, ncHit(lay, lay.minimize.left + 1, 39, false));
    try testing.expectEqual(NcHit.top_left, ncHit(lay, 0, 0, false));
    try testing.expectEqual(NcHit.top_left, ncHit(lay, 15, 7, false));
    try testing.expectEqual(NcHit.top, ncHit(lay, 16, 7, false));
    // The right corner is under the close button, which wins.
    try testing.expectEqual(NcHit.close, ncHit(lay, lay.bar.right - 1, 3, false));
    // Below the band: tabs are client, empty title bar drags.
    try testing.expectEqual(NcHit.client, ncHit(lay, 100, 20, true));
    try testing.expectEqual(NcHit.caption, ncHit(lay, 100, 20, false));
    try testing.expectEqual(NcHit.client, ncHit(lay, lay.menu.left + 1, lay.resize_band, false));
    // The resize band crosses the top of the main menu button.
    try testing.expectEqual(NcHit.top, ncHit(lay, lay.menu.left + 1, lay.menu.top, false));
    // Outside the row: client (the terminals).
    try testing.expectEqual(NcHit.client, ncHit(lay, 100, 300, false));
}

test "many tabs still leave a strip to drag the window by" {
    // However many tabs the tab bar lays out, they end at `tabs.right`.
    for ([_]f32{ 1, 1.5, 2 }) |s| {
        const lay = compute(.{ .width = px(500, s), .bar_height = px(title_bar_height, s), .frame = .custom, .scale = s });
        try testing.expect(lay.menu.left - lay.tabs.right >= px(drag_reserve_caption, s));
        const x = lay.tabs.right + 1;
        try testing.expectEqual(NcHit.caption, ncHit(lay, x, lay.content_top + 4, false));
    }
}

test "the main menu button centers on DWM's caption buttons" {
    // A material: DWM draws the buttons, here reaching past the top of the
    // client area like those of a maximized window.
    const bounds: RECT = .{ .left = 1700, .top = -6, .right = 1920, .bottom = 42 };
    const lay = compute(.{ .width = 1920, .bar_height = 60, .frame = .custom, .zoomed = true, .scale = 1.5, .buttons = .{ .dwm = bounds } });
    try testing.expectEqual(empty_rect, lay.close);
    try testing.expectEqual(bounds.left - px(menu_gap_caption, 1.5), lay.menu.right);
    // Centered on all of DWM's buttons (center 18), not on the visible part.
    try testing.expectEqual(@as(i32, 36), lay.menu.top + lay.menu.bottom);
    const unknown = compute(.{ .width = 1920, .bar_height = 60, .frame = .custom, .scale = 1.5, .buttons = .{ .dwm = null } });
    try testing.expectEqual(@as(i32, 1920 - 3 * px(caption_button_width, 1.5) - px(menu_gap_caption, 1.5)), unknown.menu.right);
    try testing.expectEqual(empty_rect, unknown.close);
}

test "rows without caption buttons" {
    const row = compute(.{ .width = 800, .bar_height = 36, .frame = .borderless, .resize_band = 8 });
    try testing.expect(!row.caption);
    try testing.expectEqual(empty_rect, row.close);
    try testing.expectEqual(@as(i32, 800 - px(menu_gap, 1)), row.menu.right);
    try testing.expectEqual(@as(i32, 8), row.resize_band);
    const native = compute(.{ .width = 800, .bar_height = 36, .frame = .native, .resize_band = 8 });
    try testing.expectEqual(@as(i32, 0), native.resize_band);
    try testing.expectEqual(px(top_margin_row, 1), native.content_top);
    const none = compute(.{ .width = 800, .bar_height = 0, .frame = .popup, .scale = 2 });
    try testing.expectEqual(@as(i32, 0), none.height());
    try testing.expectEqual(Hit.none, hit(none, 10, 0, true));
}

test "buttonRect names what a hover change repaints" {
    const lay = compute(.{ .width = 800, .bar_height = 40, .frame = .custom });
    try testing.expectEqual(lay.close, lay.buttonRect(.close));
    try testing.expectEqual(lay.menu, lay.buttonRect(.menu));
    try testing.expectEqual(empty_rect, lay.buttonRect(.none));
}

test "minTrackSize fits the caption buttons, the main menu button, a tab and a drag strip" {
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |s| {
        const size = minTrackSize(s);
        try testing.expectEqual(px(370, s), size.width);
        try testing.expectEqual(px(title_bar_height + frame_border, s), size.height);
        // The client area of such a window.
        const client = size.width - 2 * px(frame_border, s);
        const lay = compute(.{ .width = client, .bar_height = px(title_bar_height, s), .frame = .custom, .scale = s });
        try testing.expect(rectWidth(lay.tabs) >= px(min_tab_row, s) - 1);
        try testing.expect(lay.tabs.left < lay.tabs.right);
        try testing.expect(lay.menu.right <= lay.minimize.left);
        try testing.expect(lay.menu.left - lay.tabs.right >= px(drag_reserve_caption, s));
    }
}
