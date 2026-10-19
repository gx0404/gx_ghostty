//! The transient "columns × rows" overlay a window shows while it is
//! resized (`resize-overlay`, `resize-overlay-position`,
//! `resize-overlay-duration`): a rounded, non-activating, click-through
//! `Popup` with the grid in 14/20 semibold, drawn in the theme colors. It
//! shows only when the grid of a terminal changed (`decide`, against the
//! last grid of that terminal in `recent`): not for the first grid a
//! terminal reports with `after-first` (the default), not for a resize
//! that keeps the grid (a restore after minimizing, a few pixels), and a
//! resize that keeps it while the overlay is up only keeps it up. The
//! window forwards `WM_TIMER` to `onTimer`, which hides it again.
//!
//! The owning `Window` embeds this struct as `resize_overlay` and calls
//! `show` on every resize (or `showIn` for a terminal and an area of its
//! client, e.g. one split pane) and `deinit` with the window. `showIn`
//! creates the popup again for the other dark or light frame
//! (`Palette.ensurePopup`). The overlay belongs to the pane whose grid it
//! shows, by its stable identity and its tab (`owner`): the window hides
//! it (`hide`) as soon as that pane is no longer on screen, so a grid
//! never stays up over another tab or after its pane closed.
const ResizeOverlay = @This();

const std = @import("std");
const configpkg = @import("../../../config.zig");
const Window = @import("../Window.zig");
const Surface = @import("../Surface.zig");
const Pane = @import("../Pane.zig");
const PaneSnapshot = @import("../PaneSnapshot.zig");
const w32 = @import("../win32.zig");
const Palette = @import("Palette.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

/// Timer id used to auto-hide the overlay.
pub const TIMER_ID: usize = 0x5247; // 'RG'

/// Height, horizontal padding and margin from the window edges in DIPs.
const height: f32 = 36;
const pad_x: f32 = 16;
const margin: f32 = 16;

popup: Popup = .{},

/// The text on display, e.g. "120 × 40".
text_buf: [32]u8 = undefined,
text_len: usize = 0,

/// The last grid of the terminals resized lately, shown or not (`decide`).
recent: Recent = .{},

/// The tab and pane whose grid is on display (`owner`).
shown: ?Owner = null,

/// The pane an overlay on display belongs to, by its stable identity, with
/// the tab that held it when the overlay showed.
pub const Owner = struct {
    tab: PaneSnapshot.Reference,
    pane: PaneSnapshot.Reference,
};

/// A terminal's grid.
pub const Grid = PaneSnapshot.Grid;

/// The last grids of the terminals resized lately, most recent first. The
/// oldest goes when one more terminal comes: a window resize changes one
/// terminal (the active one), a split divider two.
pub const Recent = struct {
    grids: [capacity]Grid = undefined,
    len: usize = 0,

    pub const capacity = 8;

    /// The last grid of this exact pane lifetime, when it is here.
    pub fn get(self: *const Recent, pane: PaneSnapshot.Reference) ?Grid {
        for (self.grids[0..self.len]) |grid| {
            if (grid.pane.matches(pane)) return grid;
        }
        return null;
    }

    /// Remember `grid` as the last of its terminal, first in the list.
    pub fn put(self: *Recent, grid: Grid) void {
        var i: usize = 0;
        while (i < self.len and !self.grids[i].pane.matches(grid.pane)) i += 1;
        if (i == self.len) {
            if (self.len < capacity) self.len += 1;
            i = self.len - 1;
        }
        // The ones before it move back by one, over its old entry (or the
        // oldest).
        @memmove(self.grids[1 .. i + 1], self.grids[0..i]);
        self.grids[0] = grid;
    }
};

/// When the overlay shows (`resize-overlay`).
pub const Mode = enum { never, after_first, always };

/// What a resize that leaves the terminal with `next` does with the
/// overlay.
pub const Decision = enum {
    /// Nothing.
    none,
    /// Remember the grid without showing it: the first grid of a terminal
    /// (`after-first`).
    remember,
    /// Keep the shown overlay up as long again (the grid held).
    extend,
    /// Show the new grid.
    show,
};

/// What to do with the overlay for a resize that leaves a terminal with
/// grid `next`, when its last resize reported `last` (null: this is its
/// first) and the overlay is `visible`. A terminal's first grid only sets
/// its baseline, unless the overlay always shows; an unchanged grid shows
/// nothing new.
pub fn decide(mode: Mode, last: ?Grid, next: Grid, visible: bool) Decision {
    if (mode == .never) return .none;
    const prev = last orelse return if (mode == .always) .show else .remember;
    if (prev.columns == next.columns and prev.rows == next.rows) return if (visible) .extend else .none;
    return .show;
}

fn modeOf(value: configpkg.Config.ResizeOverlay) Mode {
    return switch (value) {
        .never => .never,
        .@"after-first" => .after_first,
        .always => .always,
    };
}

fn window(self: *ResizeOverlay) *Window {
    return @alignCast(@fieldParentPtr("resize_overlay", self));
}

/// Destroy the popup.
pub fn deinit(self: *ResizeOverlay) void {
    self.shown = null;
    self.popup.destroy();
}

/// The pane the overlay on display belongs to; null while it is hidden.
pub fn owner(self: *const ResizeOverlay) ?Owner {
    return if (self.popup.visible) self.shown else null;
}

/// Whether the overlay on display shows the grid of this pane lifetime.
fn shows(self: *const ResizeOverlay, pane: PaneSnapshot.Reference) bool {
    const current = self.owner() orelse return false;
    return current.pane.matches(pane);
}

/// Hide the overlay now and stop its timer, e.g. because its pane closed,
/// moved to another tab or window or is no longer shown (`owner`).
pub fn hide(self: *ResizeOverlay) void {
    self.shown = null;
    self.popup.hide();
    if (self.window().hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMER_ID);
}

fn tokens(self: *ResizeOverlay) style.Tokens {
    return style.Tokens.fromConfig(&self.window().app.config);
}

fn textStyle(t: style.Tokens) d2d.TextStyle {
    return style.type_ramp.body_strong.text(t.text);
}

/// Set the terminal's baseline without showing an overlay, e.g. when its
/// first frame becomes visible and the window starts accepting resizes.
pub fn remember(self: *ResizeOverlay, surface: *Surface) void {
    self.rememberPane(Pane.fromLocal(surface));
}
pub fn rememberPane(self: *ResizeOverlay, pane: Pane) void {
    self.recent.put(pane.grid() orelse return);
}

/// Show the overlay for the active surface's grid over the surface area
/// of the window (`showIn`).
pub fn show(self: *ResizeOverlay) void {
    const win = self.window();
    const pane = win.activePane() orelse return;
    self.showPaneIn(pane, win.surfaceRect());
}

/// Show the grid of `surface` in `area` (client coordinates of the
/// window), placed by resize-overlay-position, when the resize changed it
/// (`decide`); the resize-overlay-duration timer hides it, and each
/// resize of the same pane that keeps it up starts the timer again.
pub fn showIn(self: *ResizeOverlay, surface: *Surface, area: w32.RECT) void {
    self.showPaneIn(Pane.fromLocal(surface), area);
}
pub fn showPaneIn(self: *ResizeOverlay, pane: Pane, area: w32.RECT) void {
    const win = self.window();
    const config = &win.app.config;
    const hwnd = win.hwnd orelse return;
    const grid = pane.grid() orelse return;
    const decision = decide(modeOf(config.@"resize-overlay"), self.recent.get(grid.pane), grid, self.shows(grid.pane));
    self.recent.put(grid);
    switch (decision) {
        .none, .remember => return,
        .extend => {
            self.armTimer(hwnd);
            return;
        },
        .show => {},
    }
    // The overlay belongs to the pane and the tab holding it (`owner`).
    const leaf = win.leafForPane(grid.pane) orelse return;
    const tab = win.findTabIndex(leaf) orelse return;

    const text = std.fmt.bufPrint(&self.text_buf, "{d} \u{00D7} {d}", .{ grid.columns, grid.rows }) catch return;
    self.text_len = text.len;

    const factory = win.app.uiFactory() orelse return;
    const t = self.tokens();
    if (!Palette.ensurePopup(&self.popup, win.app, hwnd, .{
        .activate = false,
        .click_through = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
        // Keep the first synchronous resize overlay on the existing DC path.
        .prefer_software = true,
    }, .{
        .ctx = self,
        .paint = paint,
    })) return;
    // A theme of the same brightness changes only the border.
    const border: ?d2d.Color = t.border;
    if (!std.meta.eql(self.popup.options.border_color, border)) self.popup.applyTheme(t);

    // Size to the text; place within `area` per resize-overlay-position.
    self.popup.setOwnerScale(win.scale);
    const scale = self.popup.ownerScale();
    const text_w = factory.measureText(text, textStyle(t), 1000).width;
    const ow = style.pxCeil(text_w + 2 * pad_x, scale);
    const oh = style.px(height, scale);
    const m = style.px(margin, scale);
    const aw = area.right - area.left;
    const ah = area.bottom - area.top;
    const cx = area.left + @divTrunc(aw - ow, 2);
    const cy = area.top + @divTrunc(ah - oh, 2);
    var pt: w32.POINT = switch (config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = area.left + m, .y = area.top + m },
        .@"top-center" => .{ .x = cx, .y = area.top + m },
        .@"top-right" => .{ .x = area.right - ow - m, .y = area.top + m },
        .@"bottom-left" => .{ .x = area.left + m, .y = area.bottom - oh - m },
        .@"bottom-center" => .{ .x = cx, .y = area.bottom - oh - m },
        .@"bottom-right" => .{ .x = area.right - ow - m, .y = area.bottom - oh - m },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    self.popup.show(.{ .left = pt.x, .top = pt.y, .right = pt.x + ow, .bottom = pt.y + oh });
    self.shown = .{ .tab = win.tab_references[tab], .pane = grid.pane };
    self.armTimer(hwnd);
}

/// (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
/// configured durations don't overflow the u32 SetTimer argument.
fn armTimer(self: *ResizeOverlay, hwnd: w32.HWND) void {
    const dur_ms: u32 = @max(1, self.window().app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, TIMER_ID, dur_ms, null);
}

/// Handle the window's WM_TIMER; returns true when it was the overlay's.
pub fn onTimer(self: *ResizeOverlay, timer_id: usize) bool {
    if (timer_id != TIMER_ID) return false;
    self.hide();
    return true;
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, t.surface_raised);
    var text_style = textStyle(t);
    text_style.align_x = .center;
    text_style.ellipsis = false;
    canvas.drawText(self.text_buf[0..self.text_len], full, text_style);
}

test "the overlay shows only when the grid changed" {
    const testing = std.testing;
    const a: Grid = .{ .pane = testPane(1), .columns = 120, .rows = 40 };
    const wider: Grid = .{ .pane = testPane(1), .columns = 121, .rows = 40 };

    // A terminal's first grid (the window's first layout): the baseline
    // with after-first.
    try testing.expectEqual(Decision.remember, decide(.after_first, null, a, false));
    try testing.expectEqual(Decision.show, decide(.always, null, a, false));
    try testing.expectEqual(Decision.none, decide(.never, null, a, false));

    // A resize that keeps the grid (restoring a minimized window) shows
    // nothing, and only keeps a shown overlay up.
    try testing.expectEqual(Decision.none, decide(.after_first, a, a, false));
    try testing.expectEqual(Decision.extend, decide(.after_first, a, a, true));
    try testing.expectEqual(Decision.none, decide(.always, a, a, false));

    // A new grid shows.
    try testing.expectEqual(Decision.show, decide(.after_first, a, wider, false));
    try testing.expectEqual(Decision.show, decide(.after_first, a, wider, true));
    try testing.expectEqual(Decision.none, decide(.never, a, wider, true));
}

test "each terminal keeps its own baseline" {
    const testing = std.testing;
    var recent: Recent = .{};
    try testing.expectEqual(@as(?Grid, null), recent.get(testPane(1)));

    // Dragging a divider resizes two panes in turn: each compares with its
    // own last grid, so both show their changes.
    recent.put(.{ .pane = testPane(1), .columns = 60, .rows = 40 });
    recent.put(.{ .pane = testPane(2), .columns = 59, .rows = 40 });
    const left: Grid = .{ .pane = testPane(1), .columns = 61, .rows = 40 };
    try testing.expectEqual(Decision.show, decide(.after_first, recent.get(left.pane), left, false));
    recent.put(left);
    try testing.expectEqual(@as(u32, 61), recent.get(testPane(1)).?.columns);
    try testing.expectEqual(@as(u32, 59), recent.get(testPane(2)).?.columns);
    try testing.expectEqual(@as(usize, 2), recent.len);
    try testing.expectEqual(@as(u64, 1), recent.grids[0].pane.id);

    // A terminal more than the list holds pushes out the one resized
    // longest ago.
    for (3..Recent.capacity + 2) |id| recent.put(.{ .pane = testPane(id), .columns = 80, .rows = 24 });
    try testing.expectEqual(@as(usize, Recent.capacity), recent.len);
    try testing.expectEqual(@as(?Grid, null), recent.get(testPane(2)));
    try testing.expect(recent.get(testPane(1)) != null);
    try testing.expectEqual(@as(u64, Recent.capacity + 1), recent.grids[0].pane.id);
}

fn testPane(id: u64) PaneSnapshot.Reference {
    return .{ .epoch = 1, .kind = .surface, .id = id, .generation = 1 };
}

test "resize baseline cannot follow a reused pane id into a new lifetime" {
    var recent: Recent = .{};
    const old = testPane(1);
    recent.put(.{ .pane = old, .columns = 80, .rows = 24 });
    var replacement = old;
    replacement.generation += 1;
    try std.testing.expect(recent.get(replacement) == null);
    replacement = old;
    replacement.epoch += 1;
    try std.testing.expect(recent.get(replacement) == null);
}

test "an overlay keeps up only for the pane lifetime it shows" {
    var overlay: ResizeOverlay = .{};
    const pane = testPane(1);
    overlay.shown = .{ .tab = .{ .epoch = 1, .kind = .tab, .id = 7, .generation = 1 }, .pane = pane };
    // Hidden, it belongs to no pane, whatever it showed last.
    try std.testing.expect(overlay.owner() == null);
    try std.testing.expect(!overlay.shows(pane));
    overlay.popup.visible = true;
    try std.testing.expect(overlay.shows(pane));
    // Another pane, or a new lifetime of a reused id, does not extend it.
    try std.testing.expect(!overlay.shows(testPane(2)));
    var replacement = pane;
    replacement.generation += 1;
    try std.testing.expect(!overlay.shows(replacement));
}

test "remember ignores a surface that is not ready" {
    var s: Surface = undefined;
    s.core_surface_ready = false;
    var overlay: ResizeOverlay = .{};
    overlay.remember(&s);
    try std.testing.expectEqual(@as(usize, 0), overlay.recent.len);
}

test {
    std.testing.refAllDecls(@This());
}
