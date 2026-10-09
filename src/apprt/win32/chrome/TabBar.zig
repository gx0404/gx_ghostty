//! The tab bar of a top-level terminal window: GDI painting, hit-testing,
//! hover and drag-to-reorder, the right-click menu and inline renaming of
//! tab and window titles.
//!
//! The tab model (split trees, active surfaces, titles) stays in `Window`;
//! the tab bar reads it and asks the window to change it (`selectTabIndex`,
//! `closeTabByIndex`, `moveTabTo`, ...). The owning `Window` embeds this
//! struct as `tab_bar`, forwards the tab-bar part of its mouse messages to
//! the `on*` handlers and calls `paint` from `WM_PAINT`.
const TabBar = @This();

const std = @import("std");
const Window = @import("../Window.zig");
const Menu = @import("../ui/Menu.zig");
const w32 = @import("../win32.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
pub const max_tabs = Window.MAX_TABS;

/// Rename edit control child ID.
pub const RENAME_EDIT_ID: u16 = 300;

/// Whether the tab bar is visible (see `updateVisibility`).
visible: bool = false,

/// Hit-test rectangles for each tab. Zero-initialized so input handlers
/// that read it before the first paint (e.g., a synthetic WM_LBUTTONDOWN
/// during startup) get a no-match instead of stack garbage.
tab_rects: [max_tabs]w32.RECT = std.mem.zeroes([max_tabs]w32.RECT),

/// Hit-test rectangle for the "+" (new tab) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

/// Whether the "+" (new tab) button is being hovered.
hover_new_tab: bool = false,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i16 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,
rename_window: bool = false,

/// Font used for painting the tab bar (Segoe UI).
font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

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

/// (Re)create the tab bar font (Segoe UI, 12px at 96 DPI, scaled). Called
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

/// The tab bar height in pixels, or 0 when the tab bar is hidden.
pub fn height(self: *const TabBar) i32 {
    if (!self.visible) return 0;
    return @intFromFloat(@round(32.0 * self.windowConst().scale));
}

/// Recompute visibility from `window-show-tab-bar` and the tab count.
/// Returns true when it changed, so the window must lay itself out again.
pub fn updateVisibility(self: *TabBar) bool {
    const win = self.window();
    const should_show = if (win.is_quick_terminal) false else switch (win.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => win.tab_count > 1,
        .never => false,
    };
    if (should_show == self.visible) return false;
    self.visible = should_show;
    return true;
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidate(self: *TabBar) void {
    const hwnd = self.window().hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.height(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Populate equal-width tab rectangles and return their rightmost edge.
fn layoutTabRects(
    rects: []w32.RECT,
    available_w: i32,
    bar_h: i32,
    min_tab_w: i32,
    max_tab_w: i32,
) i32 {
    const tab_count: i32 = @intCast(rects.len);
    if (tab_count == 0) return 0;

    var tab_w = @divTrunc(available_w, tab_count);
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);

    var x: i32 = 0;
    for (rects) |*rect| {
        rect.* = .{
            .left = x,
            .top = 0,
            .right = x + tab_w,
            .bottom = bar_h,
        };
        x += tab_w;
    }

    return x;
}

test "tab bar keeps tab widths equal" {
    var rects: [2]w32.RECT = undefined;

    const tabs_right = layoutTabRects(&rects, 964, 30, 60, 200);

    try std.testing.expectEqual(@as(i32, 400), tabs_right);
    try std.testing.expectEqual(@as(i32, 200), rects[0].right - rects[0].left);
    try std.testing.expectEqual(@as(i32, 200), rects[1].right - rects[1].left);
    try std.testing.expectEqual(rects[0].right, rects[1].left);
}

/// Paint the tab bar into the window's paint DC (from BeginPaint) using
/// double-buffered GDI painting: tab backgrounds, text labels, close
/// buttons (x), and the new-tab (+) button.
pub fn paint(self: *TabBar, hdc_screen: w32.HDC) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;

    // If the tab bar is not visible there is nothing to draw.
    if (!self.visible) return;

    const bar_h = self.height();
    if (bar_h <= 0) return;

    // Get client rect width.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    if (client_w <= 0) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, client_w, bar_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = win.app.config.background;
    // Bar background: terminal bg + 20 brightness per channel (slightly lighter).
    const bar_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 20, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Hover background: bar bg + 15 more (total +35 from terminal bg).
    const hover_r: u8 = @min(@as(u16, bar_r) + 15, 255);
    const hover_g: u8 = @min(@as(u16, bar_g) + 15, 255);
    const hover_b: u8 = @min(@as(u16, bar_b) + 15, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    // Active tab background: terminal bg (darker than bar).
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);

    // Accent line color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // Text colors.
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);

    // Close button colors.
    const close_normal_color = w32.RGB(150, 150, 150);
    const close_hover_color = w32.RGB(232, 65, 65);

    // --- Fill bar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = bar_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (self.font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // --- Calculate tab geometry ---
    const scale = win.scale;
    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * scale));
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * scale));
    const accent_h: i32 = @intFromFloat(@round(2.0 * scale));

    const available_w = client_w - new_tab_btn_w;

    // Calculate equal tab widths within the configured bounds. Any width left
    // after the maximum is reached remains empty instead of stretching the
    // final tab.
    const min_tab_w: i32 = @intFromFloat(@round(60.0 * scale));
    const max_tab_w: i32 = @intFromFloat(@round(200.0 * scale));
    const tabs_right = layoutTabRects(
        self.tab_rects[0..win.tab_count],
        available_w,
        bar_h,
        min_tab_w,
        max_tab_w,
    );

    // --- Draw each tab ---
    for (0..win.tab_count) |i| {
        const is_active = (i == win.active_tab);
        const is_hovered = (@as(isize, @intCast(i)) == self.hover_tab);
        const x = self.tab_rects[i].left;
        const this_tab_w = self.tab_rects[i].right - x;

        // Draw tab background. CreateSolidBrush failures are rare (GDI
        // handle exhaustion), but should not skip the rest of the tab.
        if (is_active) {
            var tab_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &tab_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Draw accent line at bottom.
            var accent_rect = w32.RECT{
                .left = x,
                .top = bar_h - accent_h,
                .right = x + this_tab_w,
                .bottom = bar_h,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            var hover_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &hover_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Draw tab title text.
        const title_len = win.tab_title_lens[i];
        if (title_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = x + text_pad,
                .top = 0,
                .right = x + this_tab_w - close_btn_w - text_pad,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&win.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Draw close button (x) — visible on active or hovered tabs.
        if (is_active or is_hovered) {
            const close_x = x + this_tab_w - close_btn_w - @divTrunc(text_pad, 2);
            const close_y_center = @divTrunc(bar_h, 2);
            const close_text_color = if (is_hovered and self.hover_close and @as(isize, @intCast(i)) == self.hover_tab)
                close_hover_color
            else
                close_normal_color;

            _ = w32.SetTextColor(mem_dc, close_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // multiplication sign as close
            var close_rect = w32.RECT{
                .left = close_x,
                .top = close_y_center - @divTrunc(close_btn_w, 2),
                .right = close_x + close_btn_w,
                .bottom = close_y_center + @divTrunc(close_btn_w, 2),
            };
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }
    }

    // --- Draw new-tab (+) button ---
    {
        const btn_left = tabs_right;
        const btn_right = btn_left + new_tab_btn_w;
        self.new_tab_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };

        // Hover highlight for new-tab button.
        if (self.hover_new_tab) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            const nt_brush = w32.CreateSolidBrush(hover_color);
            if (nt_brush) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            plus_char,
            1,
            &plus_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, 0, 0, client_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// The index of the tab under client x, if any.
fn tabAt(self: *const TabBar, x: i32) ?usize {
    for (0..self.windowConst().tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) return i;
    }
    return null;
}

/// Whether a client y coordinate lies in the tab bar.
pub fn contains(self: *const TabBar, y: i32) bool {
    return y < self.height();
}

/// Handle a left-button press in the tab bar: new tab, close, or select
/// (which starts tracking a potential drag).
pub fn onLeftButtonDown(self: *TabBar, x: i16, y: i16) void {
    if (!self.visible) return;
    if (y >= self.height()) return;
    const win = self.window();

    // Check new-tab button.
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = win.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    // Check each tab.
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * win.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * win.scale));
    for (0..win.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            // Check close button area (right side of tab).
            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
            if (x >= close_left) {
                win.closeTabByIndex(i);
            } else {
                win.selectTabIndex(i);
                // Start tracking potential tab drag
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (win.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidate();
            }
            return;
        }
    }
}

/// Handle a left-button release; returns true when it ended a tab drag.
pub fn onLeftButtonUp(self: *TabBar) bool {
    if (self.drag_tab < 0) return false;
    self.cancelDrag();
    return true;
}

/// Stop tracking a tab drag and release the mouse capture.
pub fn cancelDrag(self: *TabBar) void {
    if (self.drag_tab < 0) return;
    self.drag_tab = -1;
    self.drag_active = false;
    _ = w32.ReleaseCapture();
}

/// Handle a double click in the tab bar: rename the tab under the cursor.
pub fn onDoubleClick(self: *TabBar, x: i32) void {
    if (self.tabAt(x)) |i| self.startRename(i);
}

/// Handle mouse movement: reorders tabs during a drag and updates the hover
/// state otherwise. Returns true when a drag consumed the movement.
pub fn onMouseMove(self: *TabBar, x: i32, y: i32) bool {
    const win = self.window();
    if (self.drag_tab >= 0) {
        const xi16: i16 = @truncate(x);
        const dx = if (xi16 > self.drag_start_x) xi16 - self.drag_start_x else self.drag_start_x - xi16;
        if (!self.drag_active and dx > 5) {
            self.drag_active = true;
        }
        if (self.drag_active and win.tab_count > 1) {
            // Use the uniform painted width for drag target calculation.
            const from: usize = @intCast(self.drag_tab);
            const first_w = self.tab_rects[0].right - self.tab_rects[0].left;
            var target: usize = 0;
            for (0..win.tab_count) |i| {
                const slot_left: i32 = @intCast(@as(i32, @intCast(i)) * first_w);
                const slot_mid = slot_left + @divTrunc(first_w, 2);
                if (x >= slot_mid) {
                    target = i;
                }
            }
            // Clamp to valid range
            if (target >= win.tab_count) target = win.tab_count - 1;
            if (target != from) {
                win.moveTabTo(from, target);
                self.drag_tab = @intCast(target);
                if (win.hwnd) |h| _ = w32.UpdateWindow(h);
            }
        }
        return true;
    }

    if (y < self.height()) self.updateHover(@truncate(x), @truncate(y));
    return false;
}

/// Update the hover state for mouse movement over the tab bar. Registers
/// TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn updateHover(self: *TabBar, x: i16, y: i16) void {
    if (!self.visible) return;
    const win = self.window();

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = win.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;

    if (y < self.height()) {
        // Check new-tab button.
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_new_tab = true;
        } else {
            // Check tabs.
            const close_btn_w: i32 = @intFromFloat(@round(20.0 * win.scale));
            const text_pad: i32 = @intFromFloat(@round(10.0 * win.scale));
            for (0..win.tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                    new_close = x >= close_left;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or new_close != self.hover_close or new_new_tab != self.hover_new_tab) {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.invalidate();
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
pub fn onMouseLeave(self: *TabBar) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.invalidate();
    }
}

/// Handle a right-button release in the tab bar: show the tab context menu
/// for the clicked tab (or only "New Tab" over the empty area).
pub fn onRightButtonUp(self: *TabBar, x: i16, y: i16) void {
    if (!self.visible) return;
    if (y >= self.height()) return;
    const win = self.window();
    const hwnd = win.hwnd orelse return;

    const clicked_tab = self.tabAt(x);

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    _ = w32.ClientToScreen(hwnd, &pt);

    const command = Menu.showTabContextMenu(hwnd, pt, .{
        .tab = clicked_tab,
        .tab_count = win.tab_count,
    }) orelse return;
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
}

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
    const rect = rect: {
        if (self.visible) break :rect self.tab_rects[tab_idx];

        // A single-tab window has no tab bar. Use a compact editor at the
        // top of the client area so prompt_*_title remains usable.
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        break :rect w32.RECT{
            .left = 8,
            .top = 8,
            .right = @max(168, client.right - 8),
            .bottom = 38,
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
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
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
        -@as(i32, @intFromFloat(@round(12.0 * win.scale))),
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

/// Hook for a language change: repaint (the tab bar has no translated
/// text of its own yet).
pub fn onLanguageChanged(self: *TabBar) void {
    self.invalidate();
}
