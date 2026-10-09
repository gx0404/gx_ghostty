// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Themed scrollbar for the Win32 apprt: a layered popup owned by the
//! surface window that follows the system scrollbar mode ("Always show
//! scrollbars" in the accessibility settings).
//!
//! Like WezTerm GX, the thumb is a thin rounded bar in the foreground
//! color: 3 DIPs wide at rest, widening to 8 and brightening while the
//! pointer is over the scrollbar or it is dragged. In overlay mode (the
//! default) it floats over the terminal's right edge, fades in when the
//! terminal scrolls and fades out after a second of inactivity; with
//! always-visible scrollbars it reserves a column of the grid and stays.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const testing = std.testing;

const log = std.log.scoped(.win32_scrollbar);

/// Width of the scrollbar window in DIPs, the hover and click target: the
/// column an always-visible scrollbar reserves, and the strip an overlay
/// scrollbar floats over at the right edge.
const SCROLLBAR_WIDTH_BASE: i32 = 14;
const SCROLLBAR_WIDTH_OVERLAY: i32 = 12;
const THUMB_MIN_HEIGHT_BASE: i32 = 20;

/// Thumb width in DIPs at rest and while hovered or dragged, and its gap
/// to the right edge.
const THUMB_WIDTH_REST: f32 = 3;
const THUMB_WIDTH_ACTIVE: f32 = 8;
const THUMB_MARGIN: f32 = 2;

const FADE_TIMER_ID: usize = 1;
const IDLE_TIMER_ID: usize = 2;
const FADE_INTERVAL_MS: u32 = 16; // ~60Hz
const FADE_STEP: u8 = 32;
/// Widening takes four ticks (about 64 ms).
const GROW_STEP: u8 = 64;
const IDLE_DELAY_MS: u32 = 1000;

const ALPHA_IDLE: u8 = 90;
const ALPHA_HOVER: u8 = 160;
const ALPHA_DRAG: u8 = 220;
/// The track tint while the pointer is over the scrollbar.
const ALPHA_TRACK_HOVER: u8 = 20;

/// Computed thumb rectangle within the track.
pub const ThumbRect = struct { y: i32, h: i32 };

/// Compute thumb_y and thumb_h given scrollback state and track height.
/// Enforces a 20-px minimum (DPI-scaled by caller via min_h).
pub fn thumbRect(
    total: usize,
    offset: usize,
    len: usize,
    track_h: i32,
    min_h: i32,
) ThumbRect {
    if (total == 0 or len >= total) {
        return .{ .y = 0, .h = track_h };
    }
    const total_f: f32 = @floatFromInt(total);
    const offset_f: f32 = @floatFromInt(offset);
    const len_f: f32 = @floatFromInt(len);
    const track_f: f32 = @floatFromInt(track_h);

    const computed_h_f = (len_f / total_f) * track_f;
    const computed_h: i32 = @intFromFloat(@round(computed_h_f));
    const h = @min(track_h, @max(min_h, computed_h));

    const computed_y_f = (offset_f / total_f) * track_f;
    var y: i32 = @intFromFloat(@round(computed_y_f));
    // Clamp so the thumb never extends past the track.
    if (y + h > track_h) y = track_h - h;
    if (y < 0) y = 0;

    return .{ .y = y, .h = h };
}

/// Compute new scroll offset from a thumb position during a drag.
/// Returns null if there's nothing to scroll (track_range <= 0 or total <= len).
pub fn dragOffset(
    mouse_y: i32,
    drag_anchor: i32,
    track_h: i32,
    thumb_h: i32,
    total: usize,
    len: usize,
) ?usize {
    if (total <= len) return null;
    const track_range = track_h - thumb_h;
    if (track_range <= 0) return null;

    const new_thumb_y = std.math.clamp(mouse_y - drag_anchor, 0, track_range);
    const range_f: f32 = @floatFromInt(track_range);
    const thumb_y_f: f32 = @floatFromInt(new_thumb_y);
    const max_off_f: f32 = @floatFromInt(total - len);

    return @intFromFloat(@round(thumb_y_f / range_f * max_off_f));
}

/// Effective alpha = base_alpha * fade / 255, saturating at 255.
pub fn effectiveAlpha(base_alpha: u8, fade: u8) u8 {
    const product: u16 = @as(u16, base_alpha) * @as(u16, fade) / 255;
    return @intCast(@min(product, 255));
}

pub const Mode = enum { overlay, always_visible };

/// Parse the registry DynamicScrollbars value into a Mode.
/// `value == null` means the value didn't exist.
pub fn parseMode(value: ?u32) Mode {
    if (value) |v| {
        return if (v == 0) .always_visible else .overlay;
    }
    return .overlay;
}

/// Read the raw DynamicScrollbars DWORD from
/// HKCU\Control Panel\Accessibility. Returns null on any error or absence.
pub fn readDynamicScrollbars() ?u32 {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\Accessibility");
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("DynamicScrollbars");

    var hkey: w32.HKEY = undefined;
    const open_ret = w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey,
        0,
        w32.KEY_READ,
        &hkey,
    );
    if (open_ret != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(hkey);

    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    const query_ret = w32.RegQueryValueExW(
        hkey,
        valname,
        null,
        &kind,
        @ptrCast(&val),
        &cb,
    );
    if (query_ret != w32.ERROR_SUCCESS) return null;
    if (kind != w32.REG_DWORD) return null;
    return val;
}

/// Read the current mode from the registry.
pub fn readMode() Mode {
    return parseMode(readDynamicScrollbars());
}

// ---------------------------------------------------------------------------
// Scrollbar window class + struct
// ---------------------------------------------------------------------------

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyScrollbar");

/// Test-only message: SendMessage(hwnd, WM_GHOSTTY_SCROLLBAR_QUERY, 0, 0)
/// returns the current visibility state as an LRESULT.
/// 0=hidden, 1=fading_in, 2=shown, 3=fading_out.
pub const WM_GHOSTTY_SCROLLBAR_QUERY: u32 = w32.WM_USER + 1;

pub const Visibility = enum(isize) {
    hidden = 0,
    fading_in = 1,
    shown = 2,
    fading_out = 3,
};

pub const Scrollbar = struct {
    alloc: std.mem.Allocator,
    surface: *Surface,
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Latest scroll state from the core. Initially zero.
    state: terminal.Scrollbar = .zero,
    /// True until the first update() call — used to suppress fade-in on startup.
    first_update: bool = true,

    /// Current mode; re-read on WM_SETTINGCHANGE.
    mode: Mode = .overlay,

    /// Cached theme colors. Updated via setTheme.
    bg: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 0 },
    fg: terminal.color.RGB = .{ .r = 255, .g = 255, .b = 255 },

    /// DPI scale (1.0 at 96 DPI).
    scale: f32 = 1.0,

    /// Visibility state (overlay mode only).
    visibility: Visibility = .hidden,
    /// Fade alpha [0..255]. Multiplied into base_alpha at paint time.
    fade: u8 = 0,
    /// How far the thumb has widened toward its hover width [0..255],
    /// animated on the fade timer.
    grow: u8 = 0,

    /// Hover tracking.
    hover: bool = false,
    /// Drag tracking.
    dragging: bool = false,
    drag_anchor: i32 = 0,

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        surface: *Surface,
    ) !*Scrollbar {
        try registerClassOnce(surface.app.hinstance);

        const self = try alloc.create(Scrollbar);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .surface = surface,
            .owner = owner,
            .hwnd = undefined,
            .scale = surface.scale,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL.
        // WS_EX_NOACTIVATE — clicking us does not steal focus from the terminal.
        // WS_EX_TOOLWINDOW — keep us out of the taskbar / Alt-Tab list.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        // WS_POPUP — owned popup, follows the surface in z-order.
        const style: u32 = w32.WS_POPUP;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            style,
            0,
            0,
            1,
            1, // placeholder rect — repositionAndResize() sets the real one
            owner, // owner (popup, not parent)
            null,
            surface.app.hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);

        // Stash self pointer in GWLP_USERDATA so the WndProc can find us.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.hwnd = hwnd;

        // Read the OS mode before the first repositionAndResize so that
        // the correct width is used from the very first layout pass.
        self.mode = readMode();

        // Position and size the popup against the owner's current client
        // area. Without this, the popup stays at the (0,0,1,1) placeholder
        // until the first WM_SIZE fires on the owner — making the scrollbar
        // invisible until the user resizes the window.
        _ = self.repositionAndResize();

        return self;
    }

    pub fn destroy(self: *Scrollbar) void {
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    /// Update the cached scroll state and repaint if anything changed.
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
        const was_first = self.first_update;
        const changed =
            self.state.total != state.total or
            self.state.offset != state.offset or
            self.state.len != state.len;
        self.state = state;
        self.first_update = false;

        if (was_first) {
            switch (self.mode) {
                .overlay => {
                    // Initial state — silent. Start hidden + transparent.
                    // The popup is already painted with .zero placeholder (alpha=0 = invisible).
                    self.visibility = .hidden;
                    self.fade = 0;
                    self.setTransparent();
                    self.repaint(); // Re-paint with new alpha=0 + transparent style.
                },
                .always_visible => {
                    // Always-visible: show immediately at full opacity.
                    self.visibility = .shown;
                    self.fade = 255;
                    self.clearTransparent();
                    self.repaint();
                },
            }
            return;
        }

        if (changed) {
            switch (self.mode) {
                .overlay => {
                    if (self.visibility == .hidden or self.visibility == .fading_out) {
                        self.startFadeIn();
                    }
                    self.restartIdleTimer();
                },
                .always_visible => {
                    // No fade logic — always shown at full opacity.
                },
            }
            self.repaint();
        }
    }

    /// Reposition and resize the popup to stay glued to the surface.
    /// Returns the new scrollbar width.
    pub fn repositionAndResize(self: *Scrollbar) i32 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.owner, &rect) == 0) return 0;

        const client_h = rect.bottom - rect.top;
        const width = self.currentWidth();

        // Convert top-right corner of client area to screen coords.
        var top_right = w32.POINT{ .x = rect.right - width, .y = rect.top };
        _ = w32.ClientToScreen(self.owner, &top_right);

        // Only show it with its surface: the surfaces of background tabs
        // are hidden and so are their scrollbars.
        const show: u32 = if (w32.IsWindowVisible_(self.owner) != 0) w32.SWP_SHOWWINDOW else 0;
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            top_right.x,
            top_right.y,
            width,
            client_h,
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | show,
        );

        self.repaint();

        // Return the width that the caller should subtract from the grid area.
        // Always-visible steals a column of grid space; overlay floats on top.
        return switch (self.mode) {
            .always_visible => width,
            .overlay => 0,
        };
    }

    /// Show or hide the popup when the owner surface is shown/hidden.
    pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void {
        _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNOACTIVATE else w32.SW_HIDE);
    }

    /// Update cached theme colors and repaint if they changed.
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
        if (std.meta.eql(self.bg, bg) and std.meta.eql(self.fg, fg)) return;
        self.bg = bg;
        self.fg = fg;
        self.repaint();
    }

    fn dpiScaled(self: *const Scrollbar, base: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * self.scale));
    }

    fn currentWidth(self: *const Scrollbar) i32 {
        return switch (self.mode) {
            .always_visible => self.dpiScaled(SCROLLBAR_WIDTH_BASE),
            .overlay => self.dpiScaled(SCROLLBAR_WIDTH_OVERLAY),
        };
    }

    fn repaint(self: *Scrollbar) void {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return;
        const w = client.right - client.left;
        const h = client.bottom - client.top;
        if (w <= 0 or h <= 0) return;

        // Allocate a temp BGRA buffer, fill it, blit via UpdateLayeredWindow.
        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);

        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                // Negative for top-down DIB so row 0 is the top row.
                .biHeight = -h,
            },
        };

        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bitmap);

        const old = w32.SelectObject(mem_dc, bitmap);
        defer _ = w32.SelectObject(mem_dc, old.?);

        self.drawBitmap(@ptrCast(@alignCast(bits.?)), w, h);

        var window_rect: w32.RECT = undefined;
        _ = w32.GetWindowRect(self.hwnd, &window_rect);
        const dst_pt = w32.POINT{ .x = window_rect.left, .y = window_rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{
            .SourceConstantAlpha = 255, // per-pixel alpha only
        };

        _ = w32.UpdateLayeredWindow(
            self.hwnd,
            screen_dc,
            &dst_pt,
            &dst_size,
            mem_dc,
            &src_pt,
            0,
            &blend,
            w32.ULW_ALPHA,
        );
    }

    fn drawBitmap(self: *Scrollbar, pixels: [*]u32, w: i32, h: i32) void {
        // Premultiplied BGRA. Layout per pixel: 0xAARRGGBB.
        // Overlay mode: the track is tinted while hovered, and otherwise
        // all but transparent while shown: a layered window lets the mouse
        // through pixels of alpha 0, and the whole strip, not only the
        // thin thumb, should catch the hover that widens the thumb.
        // Always-visible mode: the track is the opaque background color.
        const track: Rgba = switch (self.mode) {
            .always_visible => .{ .rgb = self.bg, .a = 255 },
            .overlay => .{
                .rgb = self.fg,
                .a = @max(
                    effectiveAlpha(lerpU8(0, ALPHA_TRACK_HOVER, self.grow), self.fade),
                    @as(u8, @intFromBool(self.fade > 0)),
                ),
            },
        };
        const track_px = track.premultiplied();
        for (pixels[0..@intCast(w * h)]) |*px| px.* = track_px;
        if (self.mode == .always_visible and self.grow > 0) {
            const tint: Rgba = .{ .rgb = self.fg, .a = lerpU8(0, ALPHA_TRACK_HOVER, self.grow) };
            for (pixels[0..@intCast(w * h)]) |*px| px.* = blendOver(tint, 1, px.*);
        }

        // The thumb: a capsule against the right edge, anti-aliased.
        const min_h = self.dpiScaled(THUMB_MIN_HEIGHT_BASE);
        const r = thumbRect(self.state.total, self.state.offset, self.state.len, h, min_h);
        if (r.h <= 0) return;
        const thumb: Rgba = .{ .rgb = self.fg, .a = self.thumbAlpha() };
        if (thumb.a == 0) return;

        const grow: f32 = @as(f32, @floatFromInt(self.grow)) / 255.0;
        const thumb_w = (THUMB_WIDTH_REST + (THUMB_WIDTH_ACTIVE - THUMB_WIDTH_REST) * grow) * self.scale;
        const right = @as(f32, @floatFromInt(w)) - THUMB_MARGIN * self.scale;
        const capsule: Capsule = .{
            .x0 = @max(right - thumb_w, 0),
            .x1 = right,
            .y0 = @floatFromInt(r.y),
            .y1 = @floatFromInt(r.y + r.h),
        };
        const x_start: i32 = @max(@as(i32, @intFromFloat(@floor(capsule.x0))), 0);
        const x_end: i32 = @min(@as(i32, @intFromFloat(@ceil(capsule.x1))), w);
        var y: i32 = r.y;
        while (y < r.y + r.h and y < h) : (y += 1) {
            var x: i32 = x_start;
            while (x < x_end) : (x += 1) {
                const coverage = capsule.coverage(@floatFromInt(x), @floatFromInt(y));
                if (coverage <= 0) continue;
                const px = &pixels[@intCast(y * w + x)];
                px.* = blendOver(thumb, coverage, px.*);
            }
        }
    }

    /// The thumb's alpha: brighter while hovered (following the widening)
    /// and dragged, times the fade in overlay mode.
    fn thumbAlpha(self: *const Scrollbar) u8 {
        const base = if (self.dragging) ALPHA_DRAG else lerpU8(ALPHA_IDLE, ALPHA_HOVER, self.grow);
        return switch (self.mode) {
            .always_visible => base,
            .overlay => effectiveAlpha(base, self.fade),
        };
    }

    /// Animate the thumb width toward its hover or rest width.
    fn animateGrow(self: *Scrollbar) void {
        const target: u8 = if (self.hover or self.dragging) 255 else 0;
        if (self.grow == target) return;
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
    }

    fn ensureLeaveTracking(self: *Scrollbar) void {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
    }

    fn trackHeight(self: *const Scrollbar) i32 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == 0) return 0;
        return rect.bottom - rect.top;
    }

    fn currentThumbRect(self: *const Scrollbar) ThumbRect {
        return thumbRect(
            self.state.total,
            self.state.offset,
            self.state.len,
            self.trackHeight(),
            self.dpiScaled(THUMB_MIN_HEIGHT_BASE),
        );
    }

    fn onMouseMove(self: *Scrollbar, x: i32, y: i32) void {
        _ = x;
        if (self.visibility == .hidden or self.visibility == .fading_out) {
            self.startFadeIn();
        }
        self.ensureLeaveTracking();

        if (self.dragging) {
            if (dragOffset(
                y,
                self.drag_anchor,
                self.trackHeight(),
                self.currentThumbRect().h,
                self.state.total,
                self.state.len,
            )) |off| {
                self.state.offset = off;
                self.surface.scrollToOffset(off);
                self.repaint();
            }
            return;
        }

        if (!self.hover) {
            self.hover = true;
            self.animateGrow();
            self.repaint();
        }
    }

    fn onMouseLeave(self: *Scrollbar) void {
        if (self.hover) {
            self.hover = false;
            self.animateGrow();
            self.repaint();
        }
        if (!self.dragging) self.restartIdleTimer();
    }

    fn onLeftDown(self: *Scrollbar, y: i32) void {
        const r = self.currentThumbRect();
        if (y >= r.y and y < r.y + r.h) {
            // Drag.
            _ = w32.SetCapture(self.hwnd);
            self.drag_anchor = y - r.y;
            self.dragging = true;
            self.animateGrow();
            self.repaint();
        } else {
            // Page click.
            const total = self.state.total;
            const len = self.state.len;
            if (total <= len) return;
            const max = total - len;
            const new_off = if (y < r.y)
                (if (self.state.offset > len) self.state.offset - len else 0)
            else
                @min(self.state.offset + len, max);
            self.state.offset = new_off;
            self.surface.scrollToOffset(new_off);
            self.repaint();
        }
    }

    fn onLeftUp(self: *Scrollbar) void {
        if (self.dragging) {
            _ = w32.ReleaseCapture();
            self.dragging = false;
            self.animateGrow();
            self.repaint();
        }
    }

    /// Called on WM_SETTINGCHANGE. Returns true if a mode change
    /// requires the terminal grid to be re-flowed.
    pub fn onSettingsChange(self: *Scrollbar) bool {
        const new_mode = readMode();
        if (new_mode == self.mode) return false;

        self.mode = new_mode;

        // Apply the initial state for the new mode.
        switch (new_mode) {
            .overlay => {
                self.visibility = .hidden;
                self.fade = 0;
                self.setTransparent();
                self.repaint();
            },
            .always_visible => {
                self.visibility = .shown;
                self.fade = 255;
                self.clearTransparent();
                self.repaint();
            },
        }

        // Mode changed — caller must reflow the grid (trigger WM_SIZE).
        return true;
    }

    /// Update the DPI scale factor and resize to it.
    pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        _ = self.repositionAndResize();
    }

    fn startFadeIn(self: *Scrollbar) void {
        self.visibility = .fading_in;
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
        self.clearTransparent();
        self.repaint();
    }

    fn startFadeOut(self: *Scrollbar) void {
        self.visibility = .fading_out;
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
        self.repaint();
    }

    fn restartIdleTimer(self: *Scrollbar) void {
        _ = w32.SetTimer(self.hwnd, IDLE_TIMER_ID, IDLE_DELAY_MS, null);
    }

    /// One step of the fade and widening animations; the timer stops once
    /// both have settled.
    fn onFadeTick(self: *Scrollbar) void {
        var animating = false;
        switch (self.visibility) {
            .fading_in => {
                const new_fade = @min(@as(u16, self.fade) + FADE_STEP, 255);
                self.fade = @intCast(new_fade);
                if (self.fade == 255) self.visibility = .shown else animating = true;
            },
            .fading_out => {
                const new_fade = if (self.fade > FADE_STEP) self.fade - FADE_STEP else 0;
                self.fade = new_fade;
                if (self.fade == 0) {
                    self.visibility = .hidden;
                    self.setTransparent();
                } else animating = true;
            },
            .hidden, .shown => {},
        }

        const target: u8 = if (self.hover or self.dragging) 255 else 0;
        self.grow = stepToward(self.grow, target, GROW_STEP);
        if (self.grow != target) animating = true;

        if (!animating) _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        self.repaint();
    }

    fn onIdleTick(self: *Scrollbar) void {
        _ = w32.KillTimer(self.hwnd, IDLE_TIMER_ID);
        if (self.dragging or self.hover) return;
        self.startFadeOut();
    }

    fn setTransparent(self: *Scrollbar) void {
        const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur | w32.WS_EX_TRANSPARENT);
    }

    fn clearTransparent(self: *Scrollbar) void {
        const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur & ~w32.WS_EX_TRANSPARENT);
    }
};

/// Pack RGB + alpha into premultiplied BGRA (UpdateLayeredWindow expects
/// premultiplied per-pixel alpha).
fn packBGRA(c: terminal.color.RGB, a: u8) u32 {
    // Premultiply: each channel *= a / 255.
    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.r)) * af));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.g)) * af));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.b)) * af));
    return (@as(u32, a) << 24) | (r << 16) | (g << 8) | b;
}

/// A straight-alpha color.
const Rgba = struct {
    rgb: terminal.color.RGB,
    a: u8,

    fn premultiplied(self: Rgba) u32 {
        return packBGRA(self.rgb, self.a);
    }
};

/// `src` drawn with `coverage` (0..1) over the premultiplied pixel `dst`.
fn blendOver(src: Rgba, coverage: f32, dst: u32) u32 {
    const a = @as(f32, @floatFromInt(src.a)) / 255.0 * std.math.clamp(coverage, 0, 1);
    const keep = 1 - a;
    const channel = struct {
        fn of(value: u32, shift: u5) f32 {
            return @floatFromInt((value >> shift) & 0xFF);
        }

        fn to8(v: f32) u32 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
        }
    };
    const out_a = 255 * a + channel.of(dst, 24) * keep;
    const r = @as(f32, @floatFromInt(src.rgb.r)) * a + channel.of(dst, 16) * keep;
    const g = @as(f32, @floatFromInt(src.rgb.g)) * a + channel.of(dst, 8) * keep;
    const b = @as(f32, @floatFromInt(src.rgb.b)) * a + channel.of(dst, 0) * keep;
    return (channel.to8(out_a) << 24) | (channel.to8(r) << 16) | (channel.to8(g) << 8) | channel.to8(b);
}

/// A vertical capsule (a rectangle with fully rounded ends) in pixels.
const Capsule = struct {
    x0: f32,
    x1: f32,
    y0: f32,
    y1: f32,

    /// How much of the pixel at (x, y) the capsule covers, 0..1, from the
    /// distance of the pixel center to the capsule's edge (antialiasing).
    fn coverage(self: Capsule, x: f32, y: f32) f32 {
        const radius = (self.x1 - self.x0) / 2;
        const top = self.y0 + radius;
        const bottom = @max(self.y1 - radius, top);
        const px = x + 0.5;
        const py = y + 0.5;
        const dx = px - (self.x0 + self.x1) / 2;
        const dy = py - std.math.clamp(py, top, bottom);
        const distance = @sqrt(dx * dx + dy * dy) - radius;
        return std.math.clamp(0.5 - distance, 0, 1);
    }
};

/// `a` moved toward `b` by `t`/255.
fn lerpU8(a: u8, b: u8, t: u8) u8 {
    const ai: i32 = a;
    const bi: i32 = b;
    return @intCast(ai + @divTrunc((bi - ai) * @as(i32, t), 255));
}

/// `value` moved by at most `step` toward `target`.
fn stepToward(value: u8, target: u8, step: u8) u8 {
    if (value < target) return @intCast(@min(@as(u16, value) + step, target));
    if (value > target) return if (value - target > step) value - step else target;
    return value;
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = scrollbarWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // we paint via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn scrollbarWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*Scrollbar = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_TIMER => {
            switch (wparam) {
                FADE_TIMER_ID => self.onFadeTick(),
                IDLE_TIMER_ID => self.onIdleTick(),
                else => {},
            }
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onMouseMove(x, y);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onLeftDown(y);
            return 0;
        },

        w32.WM_LBUTTONUP => {
            self.onLeftUp();
            return 0;
        },

        WM_GHOSTTY_SCROLLBAR_QUERY => return @intFromEnum(self.visibility),

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "thumbRect: thumb at top when offset is 0" {
    const r = thumbRect(1000, 0, 50, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 20), r.h); // 50/1000 * 400 = 20
}

test "thumbRect: thumb at bottom when offset = total - len" {
    const r = thumbRect(1000, 950, 50, 400, 20);
    // (950/1000) * 400 = 380; thumb_h = 20; bottom = 400. OK.
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
}

test "thumbRect: enforces minimum height" {
    // len/total = 1/10000, computed_h = 0; floor of min is 20.
    const r = thumbRect(10000, 0, 1, 400, 20);
    try testing.expectEqual(@as(i32, 20), r.h);
}

test "thumbRect: total == 0 returns full track" {
    const r = thumbRect(0, 0, 0, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 400), r.h);
}

test "dragOffset: top of track" {
    const off = dragOffset(0, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}

test "dragOffset: bottom of track" {
    // mouse_y = 380 (track_range = 400 - 20 = 380); should land at total - len = 950.
    const off = dragOffset(380, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}

test "dragOffset: middle of track" {
    const off = dragOffset(190, 0, 400, 20, 1000, 50).?;
    // 190/380 * 950 ≈ 475
    try testing.expectEqual(@as(usize, 475), off);
}

test "dragOffset: clamped above" {
    const off = dragOffset(-100, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}

test "dragOffset: clamped below" {
    const off = dragOffset(99999, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}

test "dragOffset: returns null when total <= len" {
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 100));
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 50));
}

test "dragOffset: returns null when thumb fills track" {
    // thumb_h == track_h → track_range == 0
    try testing.expectEqual(@as(?usize, null), dragOffset(0, 0, 400, 400, 1000, 50));
}

test "effectiveAlpha: full fade" {
    try testing.expectEqual(@as(u8, 80), effectiveAlpha(80, 255));
}

test "effectiveAlpha: half fade" {
    try testing.expectEqual(@as(u8, 40), effectiveAlpha(80, 128));
}

test "effectiveAlpha: zero fade" {
    try testing.expectEqual(@as(u8, 0), effectiveAlpha(80, 0));
}

test "parseMode: missing value defaults to overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(null));
}

test "parseMode: 1 is overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(1));
}

test "parseMode: 0 is always_visible" {
    try testing.expectEqual(Mode.always_visible, parseMode(0));
}

test "thumbRect: clamps when min_h exceeds track_h" {
    // Tiny track + normal min_h: h should not exceed track_h.
    const r = thumbRect(1000, 0, 50, 10, 20);
    try testing.expect(r.h <= 10);
    try testing.expect(r.y + r.h <= 10);
}

test "thumbRect: clamps when offset would push thumb past bottom" {
    // offset=999 → naive y = round(999/1000 * 400) = 400; with h=20 the
    // thumb would extend to 420. Clamp must pull y back to track_h - h = 380.
    const r = thumbRect(1000, 999, 50, 400, 20);
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
    try testing.expect(r.y + r.h <= 400);
}

test "dragOffset: applies drag_anchor" {
    // drag_anchor=100 should be equivalent to mouse_y shifted by -100.
    const a = dragOffset(190, 100, 400, 20, 1000, 50).?;
    const b = dragOffset(90, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(b, a);
}

test "dragOffset: rounds half to nearest" {
    // mouse_y=191, drag_anchor=0 → 191/380 * 950 = 477.5 → 478 (round-half-to-even rounds .5 up here).
    const off = dragOffset(191, 0, 400, 20, 1000, 50).?;
    try testing.expect(off == 477 or off == 478);
}

test "lerpU8 and stepToward" {
    try testing.expectEqual(@as(u8, 90), lerpU8(90, 160, 0));
    try testing.expectEqual(@as(u8, 160), lerpU8(90, 160, 255));
    try testing.expectEqual(@as(u8, 20), lerpU8(20, 0, 0));
    try testing.expectEqual(@as(u8, 64), stepToward(0, 255, 64));
    try testing.expectEqual(@as(u8, 255), stepToward(240, 255, 64));
    try testing.expectEqual(@as(u8, 0), stepToward(30, 0, 64));
}

test "Capsule coverage is full inside and fades at the edge" {
    const capsule: Capsule = .{ .x0 = 10, .x1 = 16, .y0 = 0, .y1 = 40 };
    try testing.expectEqual(@as(f32, 1), capsule.coverage(12, 20));
    try testing.expectEqual(@as(f32, 0), capsule.coverage(20, 20));
    // The rounded top end leaves its corner pixels uncovered.
    try testing.expectEqual(@as(f32, 0), capsule.coverage(10, 0));
    try testing.expect(capsule.coverage(12, 0) > 0);
}

test "parseMode: non-{0,1} value treated as overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(2));
    try testing.expectEqual(Mode.overlay, parseMode(99));
}
