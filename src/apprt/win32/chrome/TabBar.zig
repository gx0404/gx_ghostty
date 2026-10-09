//! The tab bar of a top-level terminal window: the tabs inside the chrome
//! row of `chrome/TitleBar.zig`, painted with Direct2D (8 DIP rounded top
//! corners; the active tab has the terminal background and flows into the
//! terminal below), hit-testing, hover, drag-to-reorder, the per-tab close
//! button, the unread-output badge, `process ~ title` labels, the new-tab
//! and launch profile buttons, the right-click menu, middle-click close and
//! inline renaming of tab and window titles.
//!
//! The tab model (split trees, active surfaces, titles, unread flags)
//! stays in `Window`; the tab bar reads it and asks the window to change it
//! (`selectTabIndex`, `closeTabByIndex`, `moveTabTo`, ...). Tab geometry is
//! derived from the title bar `Layout` on demand (`geometry`), so hit tests
//! never depend on a previous paint.
//!
//! Unread output: a background tab gets an accent dot when its terminal
//! changed since it was last shown (`onTimer` polls the terminal dirty
//! state, which the renderer of an occluded surface leaves untouched) or
//! rang the bell (`markUnread`). Labels: every two seconds `onTimer` looks
//! up the program running in each tab's focused terminal (the deepest
//! process below its shell, ignoring helpers) and shows `program ~ title`.
//!
//! The owning `Window` embeds this struct as `tab_bar` and forwards the
//! chrome row input to it through `TitleBar`.
const TabBar = @This();

const std = @import("std");
const Window = @import("../Window.zig");
const Surface = @import("../Surface.zig");
const Menu = @import("../ui/Menu.zig");
const d2d = @import("../ui/d2d.zig");
const style = @import("../ui/style.zig");
const w32 = @import("../win32.zig");
const TitleBar = @import("TitleBar.zig");
const global = @import("../../../global.zig");
const terminal = @import("../../../terminal/main.zig");
const gx_proc = @import("../../../gx/proc.zig");
const policy = @import("../../../gx/policy.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
pub const max_tabs = Window.MAX_TABS;

/// Rename edit control child ID.
pub const RENAME_EDIT_ID: u16 = 300;

/// Whether the tabs are shown (see `updateVisibility`).
visible: bool = false,

/// Tab rectangles (client pixels) of the last paint, for the rename edit
/// and tooltips. Zero-initialized so nothing matches before the first
/// paint.
tab_rects: [max_tabs]w32.RECT = std.mem.zeroes([max_tabs]w32.RECT),

/// The new-tab ("+") and launch profile ("▾") buttons of the last paint.
new_tab_rect: w32.RECT = TitleBar.empty_rect,
profile_rect: w32.RECT = TitleBar.empty_rect,

/// The part under the mouse and the part being pressed.
hover: Part = .none,
pressed: Part = .none,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i32 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,
rename_window: bool = false,

/// GDI UI font (Segoe UI) at the window DPI, shared with the resize
/// overlay.
font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// The programs running in the tabs' focused terminals.
processes: [max_tabs]ProcessName = [_]ProcessName{.{}} ** max_tabs,

/// Ticks of `onTimer` (one per second).
ticks: u32 = 0,

/// Whether Ghostty runs elevated (shield icon on the tabs), looked up
/// once.
elevated: ?bool = null,

/// The name of the program running in a terminal, without `.exe`.
const ProcessName = struct {
    surface: ?*const Surface = null,
    len: u8 = 0,
    buf: [48]u8 = undefined,
    /// The terminal runs a WSL distribution.
    wsl: bool = false,

    fn name(self: *const ProcessName) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A part of the tab bar.
pub const Part = union(enum) {
    none,
    tab: usize,
    tab_close: usize,
    new_tab,
    profiles,

    fn eql(a: Part, b: Part) bool {
        return std.meta.eql(a, b);
    }
};

// Geometry in DIPs.
const tab_max_width: f32 = 240;
const tab_min_width: f32 = 96;
const tab_floor_width: f32 = 40;
const tab_radius: f32 = 8;
const tab_flare: f32 = 6;
const tab_pad_x: f32 = 12;
const close_size: f32 = 20;
const close_pad_right: f32 = 8;
const icon_size: f32 = 16;
const new_tab_width: f32 = 32;
const profile_width: f32 = 20;
const buttons_gap: f32 = 4;
const title_font_size: f32 = 12;
const unread_dot_size: f32 = 6;
const drag_threshold: f32 = 5;

fn window(self: *TabBar) *Window {
    return @alignCast(@fieldParentPtr("tab_bar", self));
}

fn windowConst(self: *const TabBar) *const Window {
    return @alignCast(@fieldParentPtr("tab_bar", self));
}

/// Release the GDI objects of the tab bar.
pub fn deinit(self: *TabBar) void {
    if (self.font) |font| {
        _ = w32.DeleteObject(font);
        self.font = null;
    }
    if (self.rename_font) |font| {
        _ = w32.DeleteObject(font);
        self.rename_font = null;
    }
}

/// (Re)create the GDI UI font (Segoe UI, 12px at 96 DPI, scaled). Called
/// at window creation and whenever the DPI changes.
pub fn createFont(self: *TabBar) void {
    if (self.font) |font| _ = w32.DeleteObject(font);
    const font_height: i32 = -@as(i32, @intFromFloat(16.0 * self.window().scale));
    self.font = w32.CreateFontW(
        font_height, // cHeight (negative = character height)
        0, // cWidth
        0, // cEscapement
        0, // cOrientation
        w32.FW_NORMAL, // cWeight
        0, // bItalic
        0, // bUnderline
        0, // bStrikeOut
        w32.DEFAULT_CHARSET, // iCharSet
        0, // iOutPrecision
        0, // iClipPrecision
        0, // iQuality
        0, // iPitchAndFamily
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
}

/// Recompute whether the tabs are shown from `window-show-tab-bar`, the
/// tab count, the frame and `Window.tab_bar_suppressed` (herdr app mode).
/// With the integrated title bar the row exists anyway, so `auto` shows
/// even a single tab. Returns true when it changed, so the window must
/// lay itself out again.
pub fn updateVisibility(self: *TabBar) bool {
    const win = self.window();
    const caption_row = win.title_bar.hasCaptionRow() or win.title_bar.frame() == .borderless;
    const should_show = if (win.is_quick_terminal or win.tab_bar_suppressed) false else switch (win.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => caption_row or win.tab_count > 1,
        .never => false,
    };
    if (should_show == self.visible) return false;
    self.visible = should_show;
    return true;
}

/// Repaint the chrome row.
pub fn invalidate(self: *TabBar) void {
    self.window().title_bar.invalidate();
}

// -----------------------------------------------------------------------
// Geometry
// -----------------------------------------------------------------------

/// The tab bar parts for a title bar layout, in client pixels.
pub const Geometry = struct {
    count: usize = 0,
    tabs: [max_tabs]w32.RECT = undefined,
    new_tab: w32.RECT = TitleBar.empty_rect,
    profiles: w32.RECT = TitleBar.empty_rect,
    /// The right end the tabs are clipped to.
    clip_right: i32 = 0,
    /// Whether the tabs are wide enough for a close button.
    closable: bool = true,
};

/// Lay out equal-width tabs in `area` followed by the new-tab and profile
/// buttons. Tabs shrink from `max_w` down to `min_w`, then down to
/// `floor_w` before they overflow (and get clipped).
fn layoutTabRects(
    rects: []w32.RECT,
    area: w32.RECT,
    bottom: i32,
    buttons_w: i32,
    min_w: i32,
    max_w: i32,
    floor_w: i32,
) i32 {
    const count: i32 = @intCast(rects.len);
    if (count == 0) return area.left;
    const available = @max(0, area.right - area.left - buttons_w);
    var tab_w = @divTrunc(available, count);
    tab_w = @min(tab_w, max_w);
    if (tab_w < min_w) tab_w = @max(tab_w, floor_w);

    var x = area.left;
    for (rects) |*rect| {
        rect.* = .{ .left = x, .top = area.top, .right = x + tab_w, .bottom = bottom };
        x += tab_w;
    }
    return x;
}

test "tab bar keeps tab widths equal" {
    var rects: [2]w32.RECT = undefined;
    const area = w32.RECT{ .left = 8, .top = 8, .right = 972, .bottom = 40 };
    const tabs_right = layoutTabRects(&rects, area, 40, 56, 96, 200, 40);
    try std.testing.expectEqual(@as(i32, 408), tabs_right);
    try std.testing.expectEqual(@as(i32, 200), rects[0].right - rects[0].left);
    try std.testing.expectEqual(@as(i32, 200), rects[1].right - rects[1].left);
    try std.testing.expectEqual(rects[0].right, rects[1].left);
    try std.testing.expectEqual(@as(i32, 8), rects[0].top);
}

test "tab bar squeezes tabs below the comfortable width" {
    var rects: [10]w32.RECT = undefined;
    const area = w32.RECT{ .left = 0, .top = 0, .right = 656, .bottom = 32 };
    _ = layoutTabRects(&rects, area, 32, 56, 96, 240, 40);
    try std.testing.expectEqual(@as(i32, 60), rects[0].right - rects[0].left);
    var many: [30]w32.RECT = undefined;
    _ = layoutTabRects(&many, area, 32, 56, 96, 240, 40);
    try std.testing.expectEqual(@as(i32, 40), many[29].right - many[29].left);
}

/// The tab bar parts for `lay` (empty when the tabs are hidden).
pub fn geometry(self: *const TabBar, lay: TitleBar.Layout) Geometry {
    var g: Geometry = .{};
    if (!self.visible or lay.height() <= 0) return g;
    const win = self.windowConst();
    const s = lay.scale;
    const area = lay.tabs;
    const gap = style.px(buttons_gap, s);
    const new_w = style.px(new_tab_width, s);
    const prof_w = style.px(profile_width, s);
    const n = @min(win.tab_count, max_tabs);
    const tabs_right = layoutTabRects(
        g.tabs[0..n],
        area,
        lay.bar.bottom,
        gap + new_w + prof_w,
        style.px(tab_min_width, s),
        style.px(tab_max_width, s),
        style.px(tab_floor_width, s),
    );
    g.count = n;
    g.clip_right = area.right - (gap + new_w + prof_w);
    if (n > 0) g.closable = g.tabs[0].right - g.tabs[0].left >= style.px(close_size + 2 * tab_pad_x + 8, s);

    const btn_h = style.px(TitleBar.row_button_height, s);
    const btn_top = area.top + @divTrunc(lay.bar.bottom - area.top - btn_h, 2);
    const btn_left = @min(tabs_right, g.clip_right) + gap;
    g.new_tab = .{ .left = btn_left, .top = btn_top, .right = btn_left + new_w, .bottom = btn_top + btn_h };
    g.profiles = .{ .left = g.new_tab.right, .top = btn_top, .right = g.new_tab.right + prof_w, .bottom = btn_top + btn_h };
    return g;
}

/// The close button of tab `i` in `g`.
fn closeRectIn(g: *const Geometry, i: usize, s: f32) w32.RECT {
    const tab = g.tabs[i];
    const size = style.px(close_size, s);
    const right = tab.right - style.px(close_pad_right, s);
    const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
    return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
}

/// The close button of tab `i` for `lay` (tooltip anchor).
pub fn closeRect(self: *const TabBar, lay: TitleBar.Layout, i: usize) w32.RECT {
    const g = self.geometry(lay);
    if (i >= g.count) return TitleBar.empty_rect;
    return closeRectIn(&g, i, lay.scale);
}

/// The rectangle of tab `i` at the last paint.
pub fn tabRect(self: *const TabBar, i: usize) w32.RECT {
    if (i >= max_tabs) return TitleBar.empty_rect;
    return self.tab_rects[i];
}

/// Whether tab `i` shows its close button.
fn showsClose(self: *const TabBar, g: *const Geometry, i: usize) bool {
    if (!g.closable) return false;
    const win = self.windowConst();
    if (i == win.active_tab) return true;
    return switch (self.hover) {
        .tab, .tab_close => |h| h == i,
        else => false,
    };
}

fn partAt(self: *const TabBar, g: *const Geometry, s: f32, x: i32, y: i32) Part {
    if (TitleBar.contains(g.new_tab, x, y)) return .new_tab;
    if (TitleBar.contains(g.profiles, x, y)) return .profiles;
    for (0..g.count) |i| {
        const tab = g.tabs[i];
        if (tab.left >= g.clip_right) break;
        if (!TitleBar.contains(tab, x, y)) continue;
        if (self.showsCloseFor(g, i, x, y, s)) return .{ .tab_close = i };
        return .{ .tab = i };
    }
    return .none;
}

/// Whether a point over tab `i` is on its close button. The close button
/// of a hovered tab appears with the hover, so the point itself makes the
/// tab hovered.
fn showsCloseFor(self: *const TabBar, g: *const Geometry, i: usize, x: i32, y: i32, s: f32) bool {
    if (!g.closable) return false;
    _ = self;
    return TitleBar.contains(closeRectIn(g, i, s), x, y);
}

/// Whether a chrome row point hits a tab or a tab bar button.
pub fn hitsSomething(self: *const TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    return self.partAt(&g, lay.scale, x, y) != .none;
}

// -----------------------------------------------------------------------
// Painting
// -----------------------------------------------------------------------

/// Paint the tabs (or, when they are hidden, the window title) into the
/// chrome row.
pub fn paint(self: *TabBar, ctx: TitleBar.PaintContext) void {
    const win = self.window();
    const lay = ctx.layout;
    if (!self.visible) {
        self.new_tab_rect = TitleBar.empty_rect;
        self.profile_rect = TitleBar.empty_rect;
        if (lay.caption) self.paintWindowTitle(ctx);
        return;
    }

    const g = self.geometry(lay);
    for (0..g.count) |i| self.tab_rects[i] = g.tabs[i];
    self.new_tab_rect = g.new_tab;
    self.profile_rect = g.profiles;
    const s = lay.scale;
    const canvas = ctx.canvas;
    const tokens = ctx.tokens;

    const clip = ctx.dipRect(.{
        .left = lay.tabs.left - style.px(tab_flare, s),
        .top = 0,
        .right = g.clip_right,
        .bottom = lay.bar.bottom,
    });
    canvas.pushClip(clip);

    // Inactive tabs first, the active tab last so its flares overlap.
    for (0..g.count) |i| {
        if (i == win.active_tab) continue;
        self.paintTab(ctx, &g, i, false);
    }
    // Separators between inactive, unhovered neighbors.
    for (1..@max(g.count, 1)) |i| {
        const left = i - 1;
        if (left == win.active_tab or i == win.active_tab) continue;
        if (self.isHoveredTab(left) or self.isHoveredTab(i)) continue;
        const r = ctx.dipRect(g.tabs[i]);
        const h = r.h * 0.45;
        const y0 = r.y + (r.h - h) / 2;
        canvas.fillRect(.{ .x = r.x - 0.5, .y = y0, .w = 1, .h = h }, tokens.foreground.withAlpha(0.16));
    }
    if (win.active_tab < g.count) self.paintTab(ctx, &g, win.active_tab, true);
    canvas.popClip();

    self.paintRowButton(ctx, g.new_tab, .new_tab, d2d.icons.add, 12);
    self.paintRowButton(ctx, g.profiles, .profiles, d2d.icons.chevron_down, 9);
}

fn isHoveredTab(self: *const TabBar, i: usize) bool {
    return switch (self.hover) {
        .tab, .tab_close => |h| h == i,
        else => false,
    };
}

fn paintTab(self: *TabBar, ctx: TitleBar.PaintContext, g: *const Geometry, i: usize, active: bool) void {
    const win = self.window();
    const canvas = ctx.canvas;
    const tokens = ctx.tokens;
    const s = ctx.layout.scale;
    const r = ctx.dipRect(g.tabs[i]);
    const hovered = self.isHoveredTab(i);
    const dragging = self.drag_active and self.drag_tab == @as(isize, @intCast(i));

    if (active) {
        self.fillActiveTab(canvas, r, tokens.background);
    } else if (hovered or dragging) {
        // Rounded top corners only: let the bottom corners fall outside
        // the row.
        canvas.pushClip(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        canvas.fillRoundedRect(.{ .x = r.x + 1, .y = r.y + 2, .w = r.w - 2, .h = r.h + tab_radius }, tab_radius, tokens.overlay_hover);
        canvas.popClip();
    }

    // Close button, or the unread dot in its place.
    const close_visible = self.showsClose(g, i);
    const close = ctx.dipRect(closeRectIn(g, i, s));
    if (close_visible) {
        const close_hovered = switch (self.hover) {
            .tab_close => |h| h == i,
            else => false,
        };
        const close_pressed = switch (self.pressed) {
            .tab_close => |p| p == i,
            else => false,
        };
        var glyph = if (active or hovered) tokens.text else tokens.text_secondary;
        if (close_hovered or close_pressed) {
            canvas.fillRoundedRect(close, 4, if (close_pressed) tokens.close_pressed else tokens.close_hover);
            glyph = tokens.close_hover_text;
        }
        canvas.drawIcon(d2d.icons.close, close, 8, glyph);
    } else if (win.tab_unread[i] and !active) {
        const d = unread_dot_size;
        canvas.fillRoundedRect(.{
            .x = close.x + (close.w - d) / 2,
            .y = close.y + (close.h - d) / 2,
            .w = d,
            .h = d,
        }, d / 2, tokens.accent);
    }

    // Icon (elevated / WSL) and title.
    var text_x = r.x + tab_pad_x;
    const icon = self.tabIcon(i);
    if (icon != .none and r.w >= tab_min_width) {
        const icon_rect: d2d.Rect = .{ .x = text_x, .y = r.y + (r.h - icon_size) / 2, .w = icon_size, .h = icon_size };
        switch (icon) {
            .none => {},
            .shield => canvas.drawIcon(d2d.icons.shield, icon_rect, 12, tokens.text_secondary),
            .wsl => canvas.drawText("\u{1F427}", icon_rect, .{
                .size = 12,
                .color = tokens.text,
                .align_x = .center,
                .ellipsis = false,
            }),
        }
        text_x += icon_size + 6;
    }
    const text_right = if (g.closable) close.x - 4 else r.x + r.w - tab_pad_x / 2;
    if (text_right - text_x < 4) return;
    var buf: [600]u8 = undefined;
    const text = self.label(i, &buf);
    canvas.drawText(text, .{ .x = text_x, .y = r.y, .w = text_right - text_x, .h = r.h }, .{
        .size = title_font_size,
        .color = if (active or hovered) tokens.text else tokens.text_secondary,
    });
}

/// The active tab: rounded top corners and concave flares at the bottom
/// so it flows into the terminal below.
fn fillActiveTab(self: *TabBar, canvas: *d2d.Canvas, r: d2d.Rect, color: d2d.Color) void {
    _ = self;
    const x0 = r.x;
    const x1 = r.x + r.w;
    const y0 = r.y;
    const y1 = r.y + r.h;
    const rad = tab_radius;
    const f = tab_flare;
    var path = canvas.beginPath(.{ .x = x0 - f, .y = y1 }, true) orelse {
        canvas.fillRoundedRect(.{ .x = x0, .y = y0, .w = r.w, .h = r.h + rad }, rad, color);
        return;
    };
    defer path.deinit();
    path.arcTo(.{ .x = x0, .y = y1 - f }, f, false);
    path.lineTo(.{ .x = x0, .y = y0 + rad });
    path.arcTo(.{ .x = x0 + rad, .y = y0 }, rad, true);
    path.lineTo(.{ .x = x1 - rad, .y = y0 });
    path.arcTo(.{ .x = x1, .y = y0 + rad }, rad, true);
    path.lineTo(.{ .x = x1, .y = y1 - f });
    path.arcTo(.{ .x = x1 + f, .y = y1 }, f, false);
    path.end(true);
    canvas.fillPath(&path, color);
}

fn paintRowButton(self: *TabBar, ctx: TitleBar.PaintContext, rect: w32.RECT, part: Part, glyph: u21, size: f32) void {
    const r = ctx.dipRect(rect);
    if (r.w <= 0) return;
    const radius = style.metrics.corner_radius / 2;
    if (self.pressed.eql(part)) {
        ctx.canvas.fillRoundedRect(r, radius, ctx.tokens.overlay_pressed);
    } else if (self.hover.eql(part)) {
        ctx.canvas.fillRoundedRect(r, radius, ctx.tokens.overlay_hover);
    }
    ctx.canvas.drawIcon(glyph, r, size, ctx.glyphColor());
}

/// The window title in the title bar while the tabs are hidden
/// (`window-show-tab-bar = never`, herdr app mode).
fn paintWindowTitle(self: *TabBar, ctx: TitleBar.PaintContext) void {
    const hwnd = self.window().hwnd orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(@max(0, w32.GetWindowTextW(hwnd, &wbuf, wbuf.len)));
    var buf: [768]u8 = undefined;
    const title = utf16ToUtf8(&buf, wbuf[0..wlen]);
    const area = ctx.dipRect(ctx.layout.tabs);
    const top = ctx.dipRect(ctx.layout.bar);
    ctx.canvas.drawText(title, .{ .x = area.x + 4, .y = top.y, .w = area.w - 4, .h = top.h }, .{
        .size = title_font_size,
        .color = if (ctx.active) ctx.tokens.text else ctx.tokens.text_secondary,
    });
}

const Icon = enum { none, shield, wsl };

fn tabIcon(self: *TabBar, i: usize) Icon {
    if (self.processFor(i)) |entry| {
        if (entry.wsl) return .wsl;
    }
    if (self.isElevated()) return .shield;
    return .none;
}

fn isElevated(self: *TabBar) bool {
    if (self.elevated) |value| return value;
    const value = processElevated();
    self.elevated = value;
    return value;
}

/// The label of tab `i`: `program ~ title` when the running program is
/// known and the title does not already name it, else the title.
fn label(self: *const TabBar, i: usize, buf: []u8) []const u8 {
    const win = self.windowConst();
    var title_buf: [768]u8 = undefined;
    const title = utf16ToUtf8(&title_buf, win.tab_titles[i][0..win.tab_title_lens[i]]);
    const entry = self.processForConst(i) orelse return copyInto(buf, title);
    return formatLabel(buf, entry.name(), title);
}

fn copyInto(buf: []u8, text: []const u8) []const u8 {
    const len = @min(buf.len, text.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

/// `program ~ title`, simplified: a title that is the path of an
/// executable shows as its name, and a title that is or starts with the
/// program name shows alone.
pub fn formatLabel(buf: []u8, program: []const u8, title_raw: []const u8) []const u8 {
    const title = simplifyTitle(title_raw);
    if (program.len == 0) return copyInto(buf, title);
    if (title.len == 0) return copyInto(buf, program);
    if (std.ascii.eqlIgnoreCase(title, program)) return copyInto(buf, program);
    if (title.len > program.len and std.ascii.startsWithIgnoreCase(title, program) and
        (title[program.len] == ' ' or title[program.len] == ':'))
    {
        return copyInto(buf, title);
    }
    return std.fmt.bufPrint(buf, "{s} ~ {s}", .{ program, title }) catch copyInto(buf, title);
}

/// A title that is an executable path (`C:\Windows\system32\cmd.exe`,
/// also with an `Administrator: ` prefix) becomes the executable name, and
/// the `<shell path> - <command>` title of a console shell running a
/// command becomes the command.
fn simplifyTitle(title: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, title, " ");
    if (std.ascii.findIgnoreCase(trimmed, ".exe - ")) |i| {
        return std.mem.trim(u8, trimmed[i + ".exe - ".len ..], " ");
    }
    if (!std.ascii.endsWithIgnoreCase(trimmed, ".exe")) return trimmed;
    const sep = std.mem.lastIndexOfAny(u8, trimmed, "\\/") orelse return trimmed[0 .. trimmed.len - 4];
    return trimmed[sep + 1 .. trimmed.len - 4];
}

test "formatLabel" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("pwsh", formatLabel(&buf, "pwsh", "C:\\Program Files\\PowerShell\\7\\pwsh.exe"));
    try testing.expectEqualStrings("cmd", formatLabel(&buf, "cmd", "Administrator: C:\\WINDOWS\\system32\\cmd.exe"));
    try testing.expectEqualStrings("vim ~ pwsh", formatLabel(&buf, "vim", "C:\\Program Files\\PowerShell\\7\\pwsh.exe"));
    try testing.expectEqualStrings("ping  -t 127.0.0.1", formatLabel(&buf, "PING", "C:\\WINDOWS\\SYSTEM32\\cmd.exe - ping  -t 127.0.0.1"));
    try testing.expectEqualStrings("zsh ~ ~/src/ghostty", formatLabel(&buf, "zsh", "~/src/ghostty"));
    try testing.expectEqualStrings("vim notes.md", formatLabel(&buf, "vim", "vim notes.md"));
    try testing.expectEqualStrings("Ghostty", formatLabel(&buf, "", "Ghostty"));
    try testing.expectEqualStrings("herdr", formatLabel(&buf, "herdr", ""));
}

/// The tooltip of tab `i`: its full label.
pub fn tooltipText(self: *const TabBar, i: usize, buf: []u8) ?[]const u8 {
    if (i >= self.windowConst().tab_count) return null;
    const text = self.label(i, buf);
    return if (text.len == 0) null else text;
}

fn utf16ToUtf8(buf: []u8, units: []const u16) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    var it = std.unicode.Utf16LeIterator.init(units);
    while (true) {
        const cp = it.nextCodepoint() catch 0xFFFD orelse break;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch continue;
        out.writeAll(tmp[0..len]) catch break;
    }
    return out.buffered();
}

// -----------------------------------------------------------------------
// Mouse input
// -----------------------------------------------------------------------

/// Handle mouse movement (client coordinates): reorders tabs during a drag
/// and updates the hover state otherwise. Returns true when a drag
/// consumed the movement.
pub fn onMouseMove(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const win = self.window();
    if (self.drag_tab >= 0) {
        const dx = @abs(x - self.drag_start_x);
        if (!self.drag_active and dx > style.px(drag_threshold, lay.scale)) {
            self.drag_active = true;
            win.title_bar.setTabTooltipTarget(.none);
        }
        if (self.drag_active and win.tab_count > 1) {
            const g = self.geometry(lay);
            const from: usize = @intCast(self.drag_tab);
            var target: usize = from;
            if (g.count > 0) {
                if (x < g.tabs[0].left) {
                    target = 0;
                } else {
                    target = g.count - 1;
                    for (0..g.count) |i| {
                        if (x < g.tabs[i].right) {
                            target = i;
                            break;
                        }
                    }
                }
            }
            if (target != from) {
                win.moveTabTo(from, target);
                self.drag_tab = @intCast(target);
            }
            self.invalidate();
        }
        return true;
    }

    self.trackLeave();
    const g = self.geometry(lay);
    self.setHover(self.partAt(&g, lay.scale, x, y));
    return false;
}

fn trackLeave(self: *TabBar) void {
    if (self.tracking_mouse) return;
    const hwnd = self.window().hwnd orelse return;
    var tme = w32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
        .dwFlags = w32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (w32.TrackMouseEvent(&tme) != 0) self.tracking_mouse = true;
}

fn setHover(self: *TabBar, part: Part) void {
    if (part.eql(self.hover)) return;
    self.hover = part;
    self.invalidate();
    self.window().title_bar.setTabTooltipTarget(switch (part) {
        .none => .none,
        .tab => |i| .{ .tab = i },
        .tab_close => |i| .{ .tab_close = i },
        .new_tab => .new_tab,
        .profiles => .profiles,
    });
}

/// Handle WM_MOUSELEAVE: reset the hover state and repaint.
pub fn onMouseLeave(self: *TabBar) void {
    self.tracking_mouse = false;
    if (self.drag_tab < 0) self.setHover(.none);
}

/// A left-button press on the tab bar: select (and start tracking a
/// potential drag of) a tab, or press a button.
pub fn onLeftButtonDown(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) void {
    const win = self.window();
    const g = self.geometry(lay);
    const part = self.partAt(&g, lay.scale, x, y);
    switch (part) {
        .none => return,
        .tab => |i| {
            win.selectTabIndex(i);
            self.drag_tab = @intCast(i);
            self.drag_start_x = x;
            self.drag_active = false;
        },
        .tab_close, .new_tab, .profiles => self.pressed = part,
    }
    if (win.hwnd) |h| _ = w32.SetCapture(h);
    self.invalidate();
}

/// A left-button release; performs a pressed button when released over
/// it and ends a drag. Returns true when the tab bar handled it.
pub fn onLeftButtonUp(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const win = self.window();
    if (self.drag_tab >= 0) {
        self.cancelDrag();
        self.invalidate();
        return true;
    }
    const pressed = self.pressed;
    if (pressed == .none) return false;
    self.pressed = .none;
    if (win.hwnd) |h| {
        if (w32.GetCapture() == h) _ = w32.ReleaseCapture();
    }
    self.invalidate();
    const g = self.geometry(lay);
    if (!self.partAt(&g, lay.scale, x, y).eql(pressed)) return true;
    switch (pressed) {
        .none, .tab => {},
        .tab_close => |i| win.closeTabByIndex(i),
        .new_tab => _ = win.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .profiles => self.openProfileMenu(),
    }
    return true;
}

fn openProfileMenu(self: *TabBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    var anchor = w32.POINT{ .x = self.new_tab_rect.left, .y = self.new_tab_rect.bottom };
    _ = w32.ClientToScreen(hwnd, &anchor);
    win.title_bar.tooltip.hide();
    Menu.showProfileMenu(win, anchor);
}

/// The mouse capture went elsewhere: forget drags and presses.
pub fn onCaptureLost(self: *TabBar) void {
    if (self.drag_tab < 0 and self.pressed == .none) return;
    self.drag_tab = -1;
    self.drag_active = false;
    self.pressed = .none;
    self.invalidate();
}

/// Stop tracking a tab drag and release the mouse capture.
pub fn cancelDrag(self: *TabBar) void {
    if (self.drag_tab < 0) return;
    self.drag_tab = -1;
    self.drag_active = false;
    _ = w32.ReleaseCapture();
}

/// Handle a double click on the tab bar: rename the tab under the cursor,
/// or treat the new-tab button like a second click.
pub fn onDoubleClick(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    switch (self.partAt(&g, lay.scale, x, y)) {
        .tab => |i| self.startRename(i),
        .new_tab => _ = self.window().addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .none => return false,
        .tab_close, .profiles => {},
    }
    return true;
}

/// Middle click: close the tab under the cursor.
pub fn onMiddleButtonUp(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    switch (self.partAt(&g, lay.scale, x, y)) {
        .tab, .tab_close => |i| self.window().closeTabByIndex(i),
        .none => return false,
        .new_tab, .profiles => {},
    }
    return true;
}

/// Handle a right-button release on the tab bar: the launch profile menu
/// over the new-tab buttons, else the tab context menu for the clicked
/// tab. Returns false when the point is not on a tab or button.
pub fn onRightButtonUp(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const win = self.window();
    const hwnd = win.hwnd orelse return false;
    const g = self.geometry(lay);
    const part = self.partAt(&g, lay.scale, x, y);
    const clicked_tab: ?usize = switch (part) {
        .none => return false,
        .new_tab, .profiles => {
            self.openProfileMenu();
            return true;
        },
        .tab, .tab_close => |i| i,
    };
    win.title_bar.tooltip.hide();

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);

    const command = Menu.showTabContextMenu(hwnd, pt, .{
        .tab = clicked_tab,
        .tab_count = win.tab_count,
    }) orelse return true;
    switch (command) {
        .close => if (clicked_tab) |tab| win.closeTabByIndex(tab),
        .close_others => if (clicked_tab) |tab| win.closeOtherTabs(tab),
        .close_right => if (clicked_tab) |tab| win.closeTabsRightOf(tab),
        .new_tab => {
            _ = win.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
    }
    return true;
}

// -----------------------------------------------------------------------
// Unread output and program names
// -----------------------------------------------------------------------

/// Called once per second by the window: badge background tabs whose
/// terminal changed, and every other second refresh the program names.
pub fn onTimer(self: *TabBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    if (w32.IsWindowVisible_(hwnd) == 0 or IsIconic(hwnd) != 0) return;
    self.ticks +%= 1;
    var changed = false;
    for (0..win.tab_count) |i| {
        if (i == win.active_tab or win.tab_unread[i]) continue;
        var it = win.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (terminalChanged(entry.view)) {
                win.tab_unread[i] = true;
                changed = true;
                break;
            }
        }
    }
    if (self.visible and self.ticks % 2 == 0) {
        if (self.refreshProcesses()) changed = true;
    }
    if (changed) self.invalidate();
}

/// Mark the tab of `surface` unread (e.g. it rang the bell) unless it is
/// the active tab.
pub fn markUnread(self: *TabBar, surface: *Surface) void {
    const win = self.window();
    const i = win.findTabIndex(surface) orelse return;
    if (i == win.active_tab or win.tab_unread[i]) return;
    win.tab_unread[i] = true;
    self.invalidate();
}

/// Whether the terminal of an occluded surface changed since its renderer
/// last drew it: the renderer clears the dirty state when it draws, and it
/// does not draw occluded surfaces.
fn terminalChanged(surface: *Surface) bool {
    if (!surface.core_surface_ready) return false;
    const state = &surface.core_surface.renderer_state;
    const io = global.io();
    state.lockDemand(io);
    defer state.unlockDemand(io);
    const t = state.terminal;
    if (anyFlag(t.flags.dirty)) return true;
    const screen = t.screens.active;
    if (anyFlag(screen.dirty)) return true;
    var it = screen.pages.pageIterator(.right_down, .{ .viewport = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.pageIfResident() orelse continue;
        if (page.dirty) return true;
        for (page.rows.ptr(page.memory)[chunk.start..chunk.end]) |row| {
            if (row.dirty) return true;
        }
    }
    return false;
}

fn anyFlag(flags: anytype) bool {
    const Int = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(flags)));
    return @as(Int, @bitCast(flags)) != 0;
}

/// Helper processes that never count as the program running in a tab.
const helper_processes = [_][:0]const u8{
    "conhost.exe",
    "OpenConsole.exe",
    "gitstatusd*",
    "wslhost.exe",
    "wslrelay.exe",
};

fn processForConst(self: *const TabBar, i: usize) ?*const ProcessName {
    const win = self.windowConst();
    if (i >= win.tab_count) return null;
    const surface = win.tab_active_surface[i];
    for (&self.processes) |*entry| {
        if (entry.surface == surface and entry.len > 0) return entry;
    }
    return null;
}

fn processFor(self: *TabBar, i: usize) ?*const ProcessName {
    return self.processForConst(i);
}

/// Look up the program of every tab's focused terminal. Returns true
/// when a label changed.
fn refreshProcesses(self: *TabBar) bool {
    const win = self.window();
    const alloc = win.app.core_app.alloc;
    var changed = false;
    var next: [max_tabs]ProcessName = [_]ProcessName{.{}} ** max_tabs;
    for (0..win.tab_count) |i| {
        const surface = win.tab_active_surface[i];
        next[i].surface = surface;
        if (!surface.core_surface_ready) continue;
        const pid64 = surface.core_surface.getProcessInfo(.foreground_pid) orelse continue;
        const pid = std.math.cast(gx_proc.Pid, pid64) orelse continue;
        lookupProgram(alloc, pid, &next[i]);
    }
    for (0..max_tabs) |i| {
        const old = &self.processes[i];
        const new = &next[i];
        if (old.surface != new.surface or old.wsl != new.wsl or !std.mem.eql(u8, old.name(), new.name())) changed = true;
    }
    self.processes = next;
    return changed;
}

/// The program running in the terminal whose child process is `pid`: the
/// deepest descendant that is not a helper (newest first), else the
/// child process itself.
fn lookupProgram(alloc: std.mem.Allocator, pid: gx_proc.Pid, out: *ProcessName) void {
    var snapshot = gx_proc.snapshot(alloc, global.io(), pid) catch return;
    defer snapshot.deinit();
    const tree = snapshot.tree;
    const root = tree.find(pid) orelse return;
    var best: ?gx_proc.Descendant = null;
    const list = tree.descendants(alloc, pid) catch return;
    defer alloc.free(list);
    for (list) |candidate| {
        const process = tree.processes[candidate.index];
        if (policy.matchesAny(process.name, &helper_processes)) continue;
        if (best) |current| {
            if (candidate.depth < current.depth) continue;
            if (candidate.depth == current.depth) {
                const a = process.created orelse continue;
                const b = tree.processes[current.index].created orelse 0;
                if (a <= b) continue;
            }
        }
        best = candidate;
    }
    const name = if (best) |found| tree.processes[found.index].name else tree.processes[root].name;
    const root_name = tree.processes[root].name;
    out.wsl = policy.nameMatches(root_name, "wsl.exe") or policy.nameMatches(name, "wsl.exe");
    const bare = if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - 4] else name;
    const len = @min(bare.len, out.buf.len);
    @memcpy(out.buf[0..len], bare[0..len]);
    out.len = @intCast(len);
}

// -----------------------------------------------------------------------
// Inline rename
// -----------------------------------------------------------------------

/// Whether `hwnd` is the inline rename edit control.
pub fn isRenameEdit(self: *const TabBar, hwnd: ?w32.HWND) bool {
    const edit = self.rename_edit orelse return false;
    return hwnd != null and hwnd.? == edit;
}

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startRename(self: *TabBar, tab_idx: usize) void {
    // Cancel any existing rename
    self.cancelRename();
    self.rename_window = false;

    const win = self.window();
    const hwnd = win.hwnd orelse return;
    if (tab_idx >= win.tab_count) return;
    const s = win.scale;
    const lay = win.title_bar.layout();
    const rect = rect: {
        if (self.visible) {
            const g = self.geometry(lay);
            if (tab_idx < g.count) {
                const tab = g.tabs[tab_idx];
                const pad = style.px(6, s);
                const h = style.px(26, s);
                const top = tab.top + @divTrunc(tab.bottom - tab.top - h, 2);
                break :rect w32.RECT{ .left = tab.left + pad, .top = top, .right = tab.right - pad, .bottom = top + h };
            }
        }
        // No tabs: put the editor where the title is, or at the top of
        // the terminal.
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        const h = style.px(26, s);
        const top = if (lay.height() > 0) @divTrunc(lay.height() - h, 2) else style.px(8, s);
        const left = if (lay.height() > 0) lay.tabs.left else style.px(8, s);
        break :rect w32.RECT{
            .left = left,
            .top = top,
            .right = @min(left + style.px(320, s), client.right - style.px(8, s)),
            .bottom = top + h,
        };
    };

    // tab_titles stores only `tab_title_lens` valid u16s; the rest is
    // uninitialized. CreateWindowExW reads a NUL-terminated wide string,
    // so a NUL-terminated copy avoids the Edit displaying garbage past
    // the real title.
    var title_buf: [257]u16 = undefined;
    const tlen = win.tab_title_lens[tab_idx];
    @memcpy(title_buf[0..tlen], win.tab_titles[tab_idx][0..tlen]);
    title_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        win.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(13.0 * s))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_tab = tab_idx;
}

/// Prompt for an explicit top-level window title using the same lightweight
/// inline editor as tab renaming.
pub fn startWindowRename(self: *TabBar) void {
    const win = self.window();
    self.startRename(win.active_tab);
    const edit = self.rename_edit orelse return;
    self.rename_window = true;

    var title: [257]u16 = undefined;
    const len: usize = if (win.window_title_override_len) |override_len| len: {
        @memcpy(title[0..override_len], win.window_title_override[0..override_len]);
        break :len override_len;
    } else @intCast(w32.GetWindowTextW(win.hwnd.?, &title, 256));
    title[len] = 0;
    _ = w32.SetWindowTextW(edit, @ptrCast(&title));
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
}

/// Apply the edit text as the new tab (or window) title and destroy the
/// edit control.
pub fn finishRename(self: *TabBar) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;
    const win = self.window();

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (self.rename_window) {
        win.setWindowTitleOverride(wbuf[0..wlen]);
    } else if (wlen > 0) {
        win.setTabTitle(tab_idx, wbuf[0..wlen]);
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    self.rename_window = false;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidate();

    // Return focus to the active surface
    win.focusActiveSurface();
}

/// Cancel inline rename without applying changes.
pub fn cancelRename(self: *TabBar) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishRename: null before destroy.
        self.rename_edit = null;
        self.rename_window = false;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        self.window().focusActiveSurface();
    }
}

/// Handle WM_COMMAND from the rename edit; returns true when handled.
pub fn onCommand(self: *TabBar, wparam: usize) bool {
    const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
    const control_id: u16 = @intCast(wparam & 0xFFFF);
    // Tab rename Edit lost focus — commit (standard Win32 convention,
    // matches Explorer file rename and Edge tabs). Esc still cancels via
    // the message-loop intercept that catches VK_ESCAPE before it reaches
    // the Edit.
    if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
        self.finishRename();
        return true;
    }
    return false;
}

/// The UI language changed: repaint (labels come from the model; the
/// tooltips are translated when shown).
pub fn onLanguageChanged(self: *TabBar) void {
    self.invalidate();
}

// -----------------------------------------------------------------------
// Win32 declarations used only by the tab bar
// -----------------------------------------------------------------------

extern "user32" fn IsIconic(hWnd: w32.HWND) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w32.HANDLE;
extern "advapi32" fn OpenProcessToken(ProcessHandle: w32.HANDLE, DesiredAccess: u32, TokenHandle: *w32.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(
    TokenHandle: w32.HANDLE,
    TokenInformationClass: u32,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: u32,
    ReturnLength: *u32,
) callconv(.winapi) i32;

const TOKEN_QUERY: u32 = 0x0008;
const TokenElevation: u32 = 20;

/// Whether this process runs elevated (as administrator).
fn processElevated() bool {
    var token: w32.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return false;
    defer _ = w32.CloseHandle(token);
    var elevation: u32 = 0;
    var size: u32 = 0;
    if (GetTokenInformation(token, TokenElevation, &elevation, @sizeOf(u32), &size) == 0) return false;
    return elevation != 0;
}
