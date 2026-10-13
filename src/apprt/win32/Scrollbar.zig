// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Themed scrollbar for the Win32 apprt: a layered popup owned by the
//! surface window that follows the system scrollbar mode ("Always show
//! scrollbars" in the accessibility settings). Being a top-level window,
//! the popup receives the WM_SETTINGCHANGE broadcast that announces a mode
//! change (the terminal's child window does not). `scrollbar = never`
//! turns it off (`setEnabled`).
//!
//! The thumb is a thin rounded bar in the terminal's foreground color,
//! drawn translucent so it blends with any theme: 3 DIPs wide at rest,
//! widening to 8 and brightening while the pointer is over the scrollbar
//! or it is dragged. There is no thumb while everything fits
//! (`scrollable`). With always-visible scrollbars it reserves a column of
//! the grid and stays. In overlay mode (the default) it floats over the
//! terminal's right edge, hidden until there is something to scroll and
//! the user moves the viewport (`userScrolled`; reports never reveal it) or
//! rests the pointer on that edge (`onOwnerMouseMove`), and fades out
//! after a second without use. The fades and the widening run on the
//! `anim` frame clock and jump to their end when animations are off.
//!
//! The pointer on the scrollbar: the wheel scrolls the terminal, dragging
//! the thumb scrolls along, a short track click jumps on release, and a
//! held press pages toward the pointer until the thumb gets there.
//! Shift+press jumps immediately and continues as a drag.
//!
//! The popup is painted only when what it shows changed (`PaintKey`), into
//! a DIB kept while it is shown; moving the window only moves it, the fades
//! only change its opacity, and nothing is done for a hidden scrollbar
//! until it shows (background tabs, minimized windows, an overlay
//! scrollbar at rest).

const std = @import("std");
const w32 = @import("win32.zig");
const anim = @import("ui/anim.zig");
const gx = @import("../../gx/main.zig");
const global = @import("../../global.zig");
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

/// Timers on the scrollbar window: hiding an overlay scrollbar no longer
/// in use, and repeating a held press on the track. (Timer 1 drove the
/// fades before the `anim` clock did.)
const IDLE_TIMER_ID: usize = 2;
const REPEAT_TIMER_ID: usize = 3;
const IDLE_DELAY_MS: u32 = 1000;
/// A press held on the track pages again after this, then at the interval:
/// the pace of the Windows scroll bar.
const PAGE_REPEAT_DELAY_MS: u32 = 200;
const PAGE_REPEAT_INTERVAL_MS: u32 = 50;

/// The time a fade takes over the whole range, and the widening.
const FADE_MS: u32 = anim.motion.duration.fast;
const GROW_MS: u32 = anim.motion.duration.faster;

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
    if (track_h <= 0) return .{ .y = 0, .h = 0 };
    if (total == 0 or len >= total) return .{ .y = 0, .h = track_h };
    const total_f: f64 = @floatFromInt(total);
    const len_f: f64 = @floatFromInt(len);
    const track_f: f64 = @floatFromInt(track_h);
    const computed_h: i32 = @intFromFloat(@round(len_f / total_f * track_f));
    const h = std.math.clamp(computed_h, @min(@max(min_h, 0), track_h), track_h);
    const max_offset = total - len;
    const offset_f: f64 = @floatFromInt(@min(offset, max_offset));
    const max_offset_f: f64 = @floatFromInt(max_offset);
    const range_f: f64 = @floatFromInt(track_h - h);
    const y: i32 = @intFromFloat(@round(offset_f / max_offset_f * range_f));
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

/// Whether there is more to show than fits, so there is a thumb to draw
/// and something to scroll.
pub fn scrollable(state: terminal.Scrollbar) bool {
    return state.total > state.len;
}

/// A direction to page in.
pub const Page = enum { up, down };

/// The offset a page (`len` rows) from `offset` toward `dir`, within the
/// scrollback.
pub fn pageOffset(offset: usize, len: usize, total: usize, dir: Page) usize {
    if (total <= len) return 0;
    const max = total - len;
    const from = @min(offset, max);
    return switch (dir) {
        .up => from -| len,
        .down => @min(from +| len, max),
    };
}

/// Whether a press held on the track at `y` still pages toward `dir`: the
/// thumb has not reached the pointer yet.
pub fn pagesToward(thumb: ThumbRect, y: i32, dir: Page) bool {
    return switch (dir) {
        .up => y < thumb.y,
        .down => y >= thumb.y + thumb.h,
    };
}

/// Whether the pointer at `x` over a terminal `client_w` pixels wide is on
/// the strip of its right edge where a scrollbar `strip_w` wide shows.
pub fn inEdgeStrip(x: i32, client_w: i32, strip_w: i32) bool {
    return strip_w > 0 and x >= client_w - strip_w and x < client_w;
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

/// The pixels a scrollbar `width` pixels wide takes from the grid: its
/// column when it is enabled and always visible; an overlay scrollbar
/// floats over the grid, a disabled one is hidden.
pub fn reservedWidth(enabled: bool, mode: Mode, width: i32) i32 {
    if (!enabled) return 0;
    return switch (mode) {
        .always_visible => width,
        .overlay => 0,
    };
}

// ---------------------------------------------------------------------------
// Scrollbar window class + struct
// ---------------------------------------------------------------------------

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyScrollbar");

/// Read-only test query. wparam: 0 visibility (hidden/fading_in/shown/
/// fading_out = 0/1/2/3), 1 paints, 2 total rows, 3 offset, 4 viewport rows,
/// 5 press (none/thumb/track = 0/1/2), 6 grow, 7 fade, 8 scroll requests.
pub const WM_GHOSTTY_SCROLLBAR_QUERY: u32 = w32.WM_USER + 1;
/// Per-window test hook; never changes the OS accessibility setting.
/// wparam: 0 system, 1 overlay, 2 always visible.
pub const WM_GHOSTTY_SIMULATE_SCROLLBAR_MODE: u32 = w32.WM_USER + 2;

/// WM_LBUTTONDOWN wParam flag: Shift is down.
const MK_SHIFT: usize = 0x0004;
const WM_CANCELMODE: u32 = 0x001F;
const WM_NCDESTROY: u32 = 0x0082;
const GA_ROOT: u32 = 2;
const GWLP_HWNDPARENT: i32 = -8;

pub const Visibility = enum(isize) {
    hidden = 0,
    fading_in = 1,
    shown = 2,
    fading_out = 3,
};

/// What a press on the scrollbar does while the button is held.
const Press = union(enum) {
    none,
    /// Dragging the thumb, grabbed this many pixels below its top.
    thumb: i32,
    track: struct {
        direction: Page,
        repeated: bool = false,
    },
};

/// Everything the pixels of the popup depend on: equal keys, equal
/// pixels.
const PaintKey = struct {
    w: i32,
    h: i32,
    mode: Mode,
    bg: terminal.color.RGB,
    fg: terminal.color.RGB,
    scale: f32,
    grow: u8,
    dragging: bool,
    /// Null when everything fits.
    thumb: ?ThumbRect,
};

/// A value animated from `from` to `to` along `tween`.
const Ramp = struct {
    from: u8,
    to: u8,
    tween: anim.Tween,

    /// A ramp at the pace of `full_ms` for the whole range 0..255, so
    /// turning back halfway takes half the time.
    fn begin(now_ns: u64, from: u8, to: u8, full_ms: u32, curve: anim.motion.CubicBezier) Ramp {
        const distance: u32 = @abs(@as(i32, to) - @as(i32, from));
        return .{ .from = from, .to = to, .tween = .begin(now_ns, (full_ms * distance + 254) / 255, curve) };
    }

    fn at(self: Ramp, now_ns: u64) u8 {
        const value = self.tween.lerp(now_ns, @floatFromInt(self.from), @floatFromInt(self.to));
        return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
    }
};

/// The pixels of a shown popup: a top-down 32-bit DIB selected into a
/// memory DC, kept while the size stays.
const Canvas = struct {
    dc: ?w32.HDC = null,
    bitmap: ?w32.HANDLE = null,
    previous: ?*anyopaque = null,
    bits: ?[*]u32 = null,
    w: i32 = 0,
    h: i32 = 0,

    /// The pixels of a `w`×`h` canvas, made anew when the size changed;
    /// null when GDI fails.
    fn pixels(self: *Canvas, w: i32, h: i32) ?[]u32 {
        if (self.bits == null or self.w != w or self.h != h) {
            self.deinit();
            const dc = w32.CreateCompatibleDC(null) orelse return null;
            const bmi: w32.BITMAPINFO = .{
                .bmiHeader = .{
                    .biWidth = w,
                    // Negative for top-down DIB so row 0 is the top row.
                    .biHeight = -h,
                },
            };
            var bits: ?*anyopaque = null;
            const bitmap = w32.CreateDIBSection(dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
                _ = w32.DeleteDC(dc);
                return null;
            };
            const first = bits orelse {
                _ = w32.DeleteObject(bitmap);
                _ = w32.DeleteDC(dc);
                return null;
            };
            self.* = .{
                .dc = dc,
                .bitmap = bitmap,
                .previous = w32.SelectObject(dc, bitmap),
                .bits = @as([*]u32, @ptrCast(@alignCast(first))),
                .w = w,
                .h = h,
            };
        }
        return self.bits.?[0..@intCast(w * h)];
    }

    fn deinit(self: *Canvas) void {
        if (self.dc) |dc| {
            if (self.previous) |previous| _ = w32.SelectObject(dc, previous);
            _ = w32.DeleteDC(dc);
        }
        if (self.bitmap) |bitmap| _ = w32.DeleteObject(bitmap);
        self.* = .{};
    }
};

/// Where the popup goes on screen: the strip at the right edge of the
/// terminal's client area.
const Target = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Scrollbar = struct {
    alloc: std.mem.Allocator,
    surface: *Surface,
    /// The terminal's window: the popup sits over its right edge.
    owner: w32.HWND,
    hwnd: w32.HWND,
    /// The popup went down with the top-level window that owned it (the
    /// terminal had moved to another window without `onReparented`); it is
    /// created again when needed.
    window_lost: bool = false,

    /// Latest scroll state from the core. Initially zero.
    state: terminal.Scrollbar = .zero,
    /// True until the first update() call — used to suppress fade-in on startup.
    first_update: bool = true,

    /// Current mode; re-read on WM_SETTINGCHANGE.
    mode: Mode = .overlay,
    mode_override: ?Mode = null,
    /// False with `scrollbar = never`: hidden, reserving no width.
    enabled: bool = true,
    owner_visible: bool = true,

    /// Cached theme colors. Updated via setTheme.
    bg: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 0 },
    fg: terminal.color.RGB = .{ .r = 255, .g = 255, .b = 255 },

    /// DPI scale (1.0 at 96 DPI).
    scale: f32 = 1.0,

    /// Visibility state (overlay mode only; always-visible is `shown`).
    visibility: Visibility = .hidden,
    /// The opacity of the popup [0..255]: UpdateLayeredWindow's constant
    /// alpha over the per-pixel alpha of its pixels.
    fade: u8 = 0,
    /// How far the thumb has widened toward its hover width [0..255].
    grow: u8 = 0,
    fade_ramp: ?Ramp = null,
    grow_ramp: ?Ramp = null,
    animator: anim.Animator = .{ .tick = animTick },

    /// Hover tracking.
    hover: bool = false,
    /// A WM_MOUSELEAVE was asked for (TrackMouseEvent) and has not come.
    tracking_leave: bool = false,
    press: Press = .none,
    /// The pointer's y over the scrollbar, followed during a press.
    pointer_y: i32 = 0,

    /// The popup as last presented: the pixels kept while it is shown,
    /// what they show, where and how opaque.
    canvas: Canvas = .{},
    painted: ?PaintKey = null,
    placed: ?w32.POINT = null,
    alpha: u8 = 0,
    /// Paints since the scrollbar was made (`WM_GHOSTTY_SCROLLBAR_QUERY`).
    paints: u32 = 0,
    scroll_requests: u32 = 0,

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        surface: *Surface,
        enabled: bool,
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
            .enabled = enabled,
        };
        self.hwnd = try self.createWindow();

        // Read the OS mode before the first layout so that the correct
        // width is used from the very first pass.
        self.mode = readMode();
        self.resetVisibility();
        return self;
    }

    /// Create the popup window. Its owner is the terminal's window, of
    /// which the system takes the top-level window.
    fn createWindow(self: *Scrollbar) !w32.HWND {
        // WS_EX_LAYERED — DWM-composited above OpenGL.
        // WS_EX_NOACTIVATE — clicking us does not steal focus from the terminal.
        // WS_EX_TOOLWINDOW — keep us out of the taskbar / Alt-Tab list.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        // WS_POPUP — owned popup, follows the surface in z-order.
        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1, // placeholder rect — `present` places it when it shows
            self.owner, // owner (popup, not parent)
            null,
            self.surface.app.hinstance,
            null,
        ) orelse return error.Win32Error;

        // Stash self pointer in GWLP_USERDATA so the WndProc can find us.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return hwnd;
    }

    pub fn destroy(self: *Scrollbar) void {
        anim.stop(&self.animator);
        if (!self.window_lost) {
            // What the window gets while it goes (WM_CAPTURECHANGED) finds
            // no scrollbar.
            _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(self.hwnd);
        }
        self.canvas.deinit();
        self.alloc.destroy(self);
    }

    /// The popup window, made again if it went down with its owner.
    fn liveWindow(self: *Scrollbar) ?w32.HWND {
        if (!self.window_lost) return self.hwnd;
        const hwnd = self.createWindow() catch |err| {
            log.warn("cannot create the scrollbar window again err={}", .{err});
            return null;
        };
        self.hwnd = hwnd;
        self.window_lost = false;
        return hwnd;
    }

    /// The popup was destroyed by the system, with the top-level window
    /// that owned it.
    fn onWindowLost(self: *Scrollbar, hwnd: w32.HWND) void {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        log.warn("the scrollbar window went down with its owner", .{});
        anim.stop(&self.animator);
        self.window_lost = true;
        self.press = .none;
        self.hover = false;
        self.tracking_leave = false;
        self.grow = 0;
        self.grow_ramp = null;
        if (self.mode == .overlay) {
            self.visibility = .hidden;
            self.fade = 0;
            self.fade_ramp = null;
        }
        self.canvas.deinit();
        self.painted = null;
        self.placed = null;
    }

    /// Synchronize a current terminal snapshot without inferring its source.
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
        const prev = self.state;
        self.state = state;
        if (self.first_update) {
            // Initial state — silent.
            self.first_update = false;
            if (self.enabled) self.resetVisibility();
            return;
        }
        if (!self.enabled or prev.eql(state)) return;

        if (!scrollable(state)) {
            // Nothing to scroll any more (a full-screen program, a clear).
            _ = self.releasePress();
            if (self.mode == .overlay) self.conceal();
        }
        self.flush();
    }

    pub fn userScrolled(self: *Scrollbar) void {
        self.reveal();
    }

    /// Follow the surface after it moved or was resized: a shown popup
    /// moves (painted again only when its size changed), a hidden one
    /// waits until it shows. Returns the width it takes from the grid
    /// (`reservedWidth`).
    pub fn repositionAndResize(self: *Scrollbar) i32 {
        if (!self.enabled) return 0;
        self.flush();
        return self.currentReservedWidth();
    }

    /// The width of the grid of a surface `surface_width` pixels wide whose
    /// scrollbar reserves `reserved` pixels (`repositionAndResize`); a
    /// surface too narrow to spare them keeps its width.
    pub fn gridWidth(surface_width: u32, reserved: i32) u32 {
        if (reserved <= 0) return surface_width;
        const sub: u32 = @intCast(reserved);
        return if (surface_width > sub) surface_width - sub else surface_width;
    }

    /// The width the scrollbar takes from the grid now.
    pub fn currentReservedWidth(self: *const Scrollbar) i32 {
        return reservedWidth(self.enabled, self.mode, self.currentWidth());
    }

    /// Turn the scrollbar on or off (`scrollbar = never`): hidden and
    /// reserving no width while off. Returns whether the width it takes
    /// from the grid changed, so the caller must lay the grid out again.
    pub fn setEnabled(self: *Scrollbar, enabled: bool) bool {
        if (enabled == self.enabled) return false;
        const before = self.currentReservedWidth();
        self.enabled = enabled;
        if (!enabled) {
            _ = self.releasePress();
            self.hover = false;
            self.grow = 0;
            self.grow_ramp = null;
        }
        self.resetVisibility();
        return self.currentReservedWidth() != before;
    }

    /// The surface is shown or hidden (WM_SHOWWINDOW, which comes before
    /// the change, or the layout showing a tab's panes). Cheap when nothing
    /// changes, so it can be said again on every layout.
    pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void {
        self.owner_visible = visible;
        if (!self.enabled) return;
        if (visible) return self.flushOwner(true);
        _ = self.releasePress();
        // Not over a hidden scrollbar, and an overlay one is back at rest
        // when the surface shows again.
        self.hover = false;
        self.grow = 0;
        self.grow_ramp = null;
        if (self.mode == .overlay) {
            self.killTimer(IDLE_TIMER_ID);
            self.visibility = .hidden;
            self.fade = 0;
            self.fade_ramp = null;
        }
        self.hidePopup();
    }

    /// Update cached theme colors and repaint if they changed.
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
        if (std.meta.eql(self.bg, bg) and std.meta.eql(self.fg, fg)) return;
        self.bg = bg;
        self.fg = fg;
        self.flush();
    }

    /// The pointer moved over the terminal (its WM_MOUSEMOVE, `x` in client
    /// pixels): resting on the strip of the right edge where the scrollbar
    /// shows brings up an overlay scrollbar. Not during a press: a
    /// selection dragged to the edge shows nothing.
    pub fn onOwnerMouseMove(self: *Scrollbar, x: i32) void {
        if (!self.enabled or self.mode != .overlay or !scrollable(self.state)) return;
        if (self.visibility == .fading_in or self.visibility == .shown) return;
        if (w32.GetCapture() != null) return;
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.owner, &rect) == 0) return;
        if (!inEdgeStrip(x, rect.right - rect.left, self.currentWidth())) return;
        self.reveal();
    }

    /// The terminal's window moved to another top-level window
    /// (`Surface.onReparented`): let that window own the popup, so it stays
    /// above that window and does not go down with the old one.
    pub fn onReparented(self: *Scrollbar) void {
        if (!self.window_lost) {
            const root = GetAncestor(self.owner, GA_ROOT) orelse return;
            _ = w32.SetWindowLongPtrW(self.hwnd, GWLP_HWNDPARENT, @bitCast(@intFromPtr(root)));
        }
        self.flush();
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

    /// Whether the popup should be on screen as far as the scrollbar is
    /// concerned (the surface may still be hidden).
    fn wantsVisible(self: *const Scrollbar) bool {
        if (!self.enabled or !self.owner_visible) return false;
        return switch (self.mode) {
            .always_visible => true,
            .overlay => self.visibility != .hidden,
        };
    }

    /// Whether the terminal is on screen: its window is visible
    /// (`owner_showing`: is about to be) and the top-level window is not
    /// minimized.
    fn ownerShown(self: *const Scrollbar, owner_showing: bool) bool {
        if (!self.owner_visible) return false;
        const window = self.surface.parent_window;
        if (window.is_quick_terminal) {
            const qt = window.app.quick_terminal orelse return false;
            if (qt.window != window or qt.animating or !qt.visible) return false;
        }
        const root = GetAncestor(self.owner, GA_ROOT) orelse return false;
        if (w32.IsIconic(root) != 0) return false;
        if (owner_showing) return w32.IsWindowVisible_(root) != 0;
        return w32.IsWindowVisible_(self.owner) != 0;
    }

    /// Bring the popup in line with the state: shown over the right edge
    /// of the terminal with what it should show, or hidden.
    fn flush(self: *Scrollbar) void {
        self.flushOwner(false);
    }

    /// `flush`, where `owner_showing` says the terminal's window is about
    /// to be shown (WM_SHOWWINDOW comes before it is).
    fn flushOwner(self: *Scrollbar, owner_showing: bool) void {
        if (!self.wantsVisible() or !self.ownerShown(owner_showing)) return self.hidePopup();
        const hwnd = self.liveWindow() orelse return;
        if (!self.present(hwnd)) return self.hidePopup();
        if (w32.IsWindowVisible_(hwnd) == 0) _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    }

    /// Hide the popup and let go of its pixels; it is painted anew when it
    /// shows again.
    fn hidePopup(self: *Scrollbar) void {
        if (!self.window_lost and w32.IsWindowVisible_(self.hwnd) != 0) _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.canvas.deinit();
        self.painted = null;
        self.placed = null;
    }

    /// The strip at the right edge of the terminal, in screen pixels; null
    /// while the terminal has no area.
    fn target(self: *const Scrollbar) ?Target {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.owner, &rect) == 0) return null;
        const w = self.currentWidth();
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) return null;
        var top_left: w32.POINT = .{ .x = rect.right - w, .y = rect.top };
        if (w32.ClientToScreen(self.owner, &top_left) == 0) return null;
        return .{ .x = top_left.x, .y = top_left.y, .w = w, .h = h };
    }

    fn paintKey(self: *const Scrollbar, w: i32, h: i32) PaintKey {
        return .{
            .w = w,
            .h = h,
            .mode = self.mode,
            .bg = self.bg,
            .fg = self.fg,
            .scale = self.scale,
            .grow = self.grow,
            .dragging = self.press == .thumb,
            .thumb = if (scrollable(self.state))
                thumbRect(self.state.total, self.state.offset, self.state.len, h, self.dpiScaled(THUMB_MIN_HEIGHT_BASE))
            else
                null,
        };
    }

    /// The constant alpha of the popup: an overlay scrollbar fades.
    fn windowAlpha(self: *const Scrollbar) u8 {
        return switch (self.mode) {
            .always_visible => 255,
            .overlay => self.fade,
        };
    }

    /// Place the popup, draw its pixels and set its opacity, each only as
    /// far as it changed. False when there is nowhere to put it or GDI
    /// failed.
    fn present(self: *Scrollbar, hwnd: w32.HWND) bool {
        const at = self.target() orelse return false;
        const key = self.paintKey(at.w, at.h);
        const alpha = self.windowAlpha();
        const blend: w32.BLENDFUNCTION = .{ .SourceConstantAlpha = alpha };
        const pos: w32.POINT = .{ .x = at.x, .y = at.y };

        if (self.painted == null or !std.meta.eql(self.painted.?, key)) {
            const span: gx.perf.Span = .begin(global.io());
            const pixels = self.canvas.pixels(at.w, at.h) orelse return false;
            render(key, pixels);
            const size: w32.SIZE = .{ .cx = at.w, .cy = at.h };
            const src: w32.POINT = .{ .x = 0, .y = 0 };
            if (w32.UpdateLayeredWindow(hwnd, null, &pos, &size, self.canvas.dc, &src, 0, &blend, w32.ULW_ALPHA) == 0) return false;
            self.painted = key;
            self.placed = pos;
            self.alpha = alpha;
            self.paints +%= 1;
            _ = span.end(global.io(), "scrollbar.paint");
            return true;
        }

        // The same pixels: move the window and change its opacity only.
        const moved = if (self.placed) |placed| placed.x != pos.x or placed.y != pos.y else true;
        if (!moved and alpha == self.alpha) return true;
        if (w32.UpdateLayeredWindow(hwnd, null, if (moved) &pos else null, null, null, null, 0, &blend, w32.ULW_ALPHA) == 0) return false;
        self.placed = pos;
        self.alpha = alpha;
        return true;
    }

    fn setTimer(self: *Scrollbar, id: usize, ms: u32) void {
        const hwnd = self.liveWindow() orelse return;
        _ = w32.SetTimer(hwnd, id, ms, null);
    }

    fn killTimer(self: *Scrollbar, id: usize) void {
        if (!self.window_lost) _ = w32.KillTimer(self.hwnd, id);
    }

    /// Hide an overlay scrollbar a second after its last use.
    fn restartIdleTimer(self: *Scrollbar) void {
        if (self.mode == .overlay) self.setTimer(IDLE_TIMER_ID, IDLE_DELAY_MS);
    }

    /// Bring up an overlay scrollbar, while there is something to scroll
    /// and the terminal is on screen, and keep it up for another second.
    fn reveal(self: *Scrollbar) void {
        if (!self.enabled or self.mode != .overlay or !scrollable(self.state)) return;
        if (!self.ownerShown(false)) return;
        switch (self.visibility) {
            .hidden, .fading_out => {
                self.visibility = .fading_in;
                self.animateFade(255);
            },
            .fading_in, .shown => {},
        }
        self.restartIdleTimer();
        self.flush();
    }

    /// Fade out a shown overlay scrollbar.
    fn conceal(self: *Scrollbar) void {
        self.killTimer(IDLE_TIMER_ID);
        switch (self.visibility) {
            .fading_in, .shown => {
                self.visibility = .fading_out;
                self.animateFade(0);
            },
            .hidden, .fading_out => {},
        }
    }

    fn onIdleTick(self: *Scrollbar) void {
        self.killTimer(IDLE_TIMER_ID);
        // An always-visible scrollbar never fades: faded out, it would let
        // the mouse through.
        if (self.mode != .overlay or self.press != .none or self.hover) return;
        self.conceal();
    }

    /// Start over in the resting state of the mode: an overlay scrollbar
    /// hidden until it is used, an always-visible one shown at full
    /// opacity.
    fn resetVisibility(self: *Scrollbar) void {
        self.killTimer(IDLE_TIMER_ID);
        self.fade_ramp = null;
        if (self.grow_ramp == null) anim.stop(&self.animator);
        switch (self.mode) {
            .overlay => {
                self.visibility = .hidden;
                self.fade = 0;
            },
            .always_visible => {
                self.visibility = .shown;
                self.fade = 255;
            },
        }
        self.flush();
    }

    fn animateFade(self: *Scrollbar, to: u8) void {
        const curve = if (to > self.fade) anim.motion.enter else anim.motion.exit;
        self.fade_ramp = Ramp.begin(anim.now(), self.fade, to, FADE_MS, curve);
        self.runAnimations();
    }

    /// Widen the thumb while it is hovered or pressed, narrow it otherwise.
    fn animateGrow(self: *Scrollbar) void {
        const to: u8 = if (self.hover or self.press != .none) 255 else 0;
        if (self.grow_ramp) |ramp| {
            if (ramp.to == to) return;
        } else if (self.grow == to) return;
        self.grow_ramp = Ramp.begin(anim.now(), self.grow, to, GROW_MS, anim.motion.ease);
        self.runAnimations();
    }

    /// Run the ramps on the frame clock, or jump to their ends when
    /// animations are off (or there is no clock).
    fn runAnimations(self: *Scrollbar) void {
        if (anim.enabled() and anim.start(&self.animator)) return;
        anim.stop(&self.animator);
        if (self.fade_ramp) |ramp| {
            self.fade = ramp.to;
            self.fade_ramp = null;
            self.fadeSettled();
        }
        if (self.grow_ramp) |ramp| {
            self.grow = ramp.to;
            self.grow_ramp = null;
        }
        self.flush();
    }

    fn animTick(animator: *anim.Animator, now_ns: u64) bool {
        const self: *Scrollbar = @alignCast(@fieldParentPtr("animator", animator));
        var running = false;
        if (self.fade_ramp) |ramp| {
            self.fade = ramp.at(now_ns);
            if (ramp.tween.done(now_ns)) {
                self.fade_ramp = null;
                self.fadeSettled();
            } else running = true;
        }
        if (self.grow_ramp) |ramp| {
            self.grow = ramp.at(now_ns);
            if (ramp.tween.done(now_ns)) self.grow_ramp = null else running = true;
        }
        self.flush();
        return running;
    }

    /// A fade reached its end.
    fn fadeSettled(self: *Scrollbar) void {
        self.visibility = switch (self.visibility) {
            .fading_in => .shown,
            .fading_out => .hidden,
            .hidden, .shown => self.visibility,
        };
    }

    fn trackLeave(self: *Scrollbar) void {
        if (self.tracking_leave or self.window_lost) return;
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        if (w32.TrackMouseEvent(&tme) != 0) self.tracking_leave = true;
    }

    fn trackHeight(self: *const Scrollbar) i32 {
        if (self.painted) |key| return key.h;
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == 0) return 0;
        return rect.bottom - rect.top;
    }

    /// The thumb as the popup shows it, null when there is none.
    fn shownThumb(self: *const Scrollbar) ?ThumbRect {
        if (self.painted) |key| return key.thumb;
        if (!scrollable(self.state)) return null;
        return thumbRect(self.state.total, self.state.offset, self.state.len, self.trackHeight(), self.dpiScaled(THUMB_MIN_HEIGHT_BASE));
    }

    /// Scroll the terminal to `offset`, unless it is there already.
    fn scrollTo(self: *Scrollbar, offset: usize) void {
        if (offset == self.state.offset) return;
        self.state.offset = offset;
        self.scroll_requests +%= 1;
        self.surface.scrollToOffset(offset);
        self.flush();
    }

    fn pageOnce(self: *Scrollbar, dir: Page) void {
        self.scrollTo(pageOffset(self.state.offset, self.state.len, self.state.total, dir));
    }

    fn onMouseMove(self: *Scrollbar, y: i32, left_down: bool) void {
        self.pointer_y = y;
        switch (self.press) {
            .thumb => |anchor| {
                // The button went up where the scrollbar did not see it.
                if (!left_down) return self.endPress();
                const thumb = self.shownThumb() orelse return;
                if (dragOffset(y, anchor, self.trackHeight(), thumb.h, self.state.total, self.state.len)) |off| self.scrollTo(off);
                return;
            },
            .track => {
                if (!left_down) self.endPress();
                return;
            },
            .none => {},
        }
        if (self.visibility == .fading_out) self.reveal();
        self.trackLeave();
        if (!self.hover) {
            self.hover = true;
            self.animateGrow();
        }
    }

    fn onMouseLeave(self: *Scrollbar) void {
        self.tracking_leave = false;
        // A press keeps the thumb wide; its end asks again.
        if (self.press != .none) return;
        if (self.hover) {
            self.hover = false;
            self.animateGrow();
        }
        self.restartIdleTimer();
    }

    fn jumpTo(self: *Scrollbar, y: i32) void {
        const thumb = self.shownThumb() orelse return;
        if (dragOffset(y, @divTrunc(thumb.h, 2), self.trackHeight(), thumb.h, self.state.total, self.state.len)) |off| self.scrollTo(off);
    }

    fn onLeftDown(self: *Scrollbar, y: i32, shift: bool) void {
        self.pointer_y = y;
        const thumb = self.shownThumb() orelse return;
        if (y >= thumb.y and y < thumb.y + thumb.h) return self.beginPress(.{ .thumb = y - thumb.y });
        if (shift) {
            self.beginPress(.{ .thumb = @divTrunc(thumb.h, 2) });
            self.jumpTo(y);
            return;
        }
        const dir: Page = if (y < thumb.y) .up else .down;
        self.beginPress(.{ .track = .{ .direction = dir } });
        self.setTimer(REPEAT_TIMER_ID, PAGE_REPEAT_DELAY_MS);
    }

    fn onLeftUp(self: *Scrollbar, y: i32) void {
        if (self.press == .track and !self.press.track.repeated) self.jumpTo(y);
        self.endPress();
    }

    fn beginPress(self: *Scrollbar, press: Press) void {
        self.press = press;
        _ = w32.SetCapture(self.hwnd);
        if (w32.GetCapture() != self.hwnd) {
            self.press = .none;
            return;
        }
        self.animateGrow();
        self.flush();
    }

    /// A short track click jumps on release; holding instead pages toward
    /// the pointer, without a final jump when released.
    fn onRepeatTick(self: *Scrollbar) void {
        const dir = switch (self.press) {
            .track => |*track| dir: {
                track.repeated = true;
                break :dir track.direction;
            },
            .none, .thumb => return self.killTimer(REPEAT_TIMER_ID),
        };
        self.setTimer(REPEAT_TIMER_ID, PAGE_REPEAT_INTERVAL_MS);
        const thumb = self.shownThumb() orelse return self.endPress();
        if (pagesToward(thumb, self.pointer_y, dir)) self.pageOnce(dir);
    }

    /// End a press: on button release, and when the capture went elsewhere
    /// (WM_CAPTURECHANGED) or the button is found released.
    fn endPress(self: *Scrollbar) void {
        if (!self.releasePress()) return;
        // WM_MOUSELEAVE comes at once if the pointer is off the scrollbar.
        self.trackLeave();
        self.animateGrow();
        self.restartIdleTimer();
        self.flush();
    }

    /// Forget the press without changing the look; whether there was one.
    fn releasePress(self: *Scrollbar) bool {
        if (self.press == .none) return false;
        // First, so the WM_CAPTURECHANGED of the release finds no press.
        self.press = .none;
        self.killTimer(REPEAT_TIMER_ID);
        if (!self.window_lost and w32.GetCapture() == self.hwnd) _ = w32.ReleaseCapture();
        self.tracking_leave = false;
        return true;
    }

    /// Called on WM_SETTINGCHANGE: follow the system scrollbar mode.
    /// Returns true when the width the scrollbar takes from the grid
    /// changed, so the grid must be laid out again (`Surface.refitGrid`).
    pub fn onSettingsChange(self: *Scrollbar) bool {
        if ((self.fade_ramp != null or self.grow_ramp != null) and !anim.enabled()) self.runAnimations();
        const new_mode = self.mode_override orelse readMode();
        if (new_mode == self.mode) return false;

        const before = self.currentReservedWidth();
        self.mode = new_mode;
        if (self.enabled) self.resetVisibility();
        return self.currentReservedWidth() != before;
    }

    /// Update the DPI scale factor and resize to it.
    pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        self.flush();
    }
};

/// Draw the scrollbar `key` describes into `pixels`: premultiplied BGRA
/// (0xAARRGGBB), top-down rows `key.w` wide.
fn render(key: PaintKey, pixels: []u32) void {
    const hover_tint = lerpU8(0, ALPHA_TRACK_HOVER, key.grow);
    const track: u32 = switch (key.mode) {
        // The opaque background color, tinted while hovered.
        .always_visible => blendOver(.{ .rgb = key.fg, .a = hover_tint }, 1, packBGRA(key.bg, 255)),
        // Tinted while hovered, otherwise all but transparent: a layered
        // window lets the mouse through pixels of alpha 0, and the whole
        // strip, not only the thin thumb, should catch the hover that
        // widens the thumb.
        .overlay => packBGRA(key.fg, @max(hover_tint, 1)),
    };
    @memset(pixels, track);

    // The thumb: a capsule against the right edge, anti-aliased.
    const r = key.thumb orelse return;
    if (r.h <= 0) return;
    const thumb: Rgba = .{
        .rgb = key.fg,
        .a = if (key.dragging) ALPHA_DRAG else lerpU8(ALPHA_IDLE, ALPHA_HOVER, key.grow),
    };
    const grow: f32 = @as(f32, @floatFromInt(key.grow)) / 255.0;
    const thumb_w = (THUMB_WIDTH_REST + (THUMB_WIDTH_ACTIVE - THUMB_WIDTH_REST) * grow) * key.scale;
    const right = @as(f32, @floatFromInt(key.w)) - THUMB_MARGIN * key.scale;
    const capsule: Capsule = .{
        .x0 = @max(right - thumb_w, 0),
        .x1 = right,
        .y0 = @floatFromInt(r.y),
        .y1 = @floatFromInt(r.y + r.h),
    };
    const x_start: i32 = @max(@as(i32, @intFromFloat(@floor(capsule.x0))), 0);
    const x_end: i32 = @min(@as(i32, @intFromFloat(@ceil(capsule.x1))), key.w);
    var y: i32 = @max(r.y, 0);
    while (y < r.y + r.h and y < key.h) : (y += 1) {
        var x: i32 = x_start;
        while (x < x_end) : (x += 1) {
            const coverage = capsule.coverage(@floatFromInt(x), @floatFromInt(y));
            if (coverage <= 0) continue;
            const px = &pixels[@intCast(y * key.w + x)];
            px.* = blendOver(thumb, coverage, px.*);
        }
    }
}

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

/// The y of the pointer in a mouse message's lparam.
fn mouseY(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
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
                IDLE_TIMER_ID => self.onIdleTick(),
                REPEAT_TIMER_ID => self.onRepeatTick(),
                else => {},
            }
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            self.onMouseMove(mouseY(lparam), wparam & w32.MK_LBUTTON != 0);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            self.onLeftDown(mouseY(lparam), wparam & MK_SHIFT != 0);
            return 0;
        },

        w32.WM_LBUTTONUP => {
            self.onLeftUp(mouseY(lparam));
            return 0;
        },

        w32.WM_CAPTURECHANGED, WM_CANCELMODE => {
            self.endPress();
            return 0;
        },

        // The wheel over the scrollbar scrolls the terminal (the popup
        // has no parent to pass it on to).
        w32.WM_MOUSEWHEEL, w32.WM_MOUSEHWHEEL => return w32.SendMessageW(self.owner, msg, wparam, lparam),

        w32.WM_SETTINGCHANGE => {
            if (self.onSettingsChange()) self.surface.refitGrid();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SHOWWINDOW => {
            // Restoring a minimized window shows again the popups the
            // system hid with it, not one that has to stay hidden.
            if (wparam != 0 and lparam != 0 and !self.wantsVisible()) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_NCDESTROY => {
            self.onWindowLost(hwnd);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_GHOSTTY_SIMULATE_SCROLLBAR_MODE => {
            self.mode_override = switch (wparam) {
                0 => null,
                1 => .overlay,
                2 => .always_visible,
                else => return 0,
            };
            if (self.onSettingsChange()) self.surface.refitGrid();
            return 1;
        },

        WM_GHOSTTY_SCROLLBAR_QUERY => return switch (wparam) {
            1 => @intCast(self.paints),
            2 => @intCast(self.state.total),
            3 => @intCast(self.state.offset),
            4 => @intCast(self.state.len),
            5 => switch (self.press) {
                .none => 0,
                .thumb => 1,
                .track => 2,
            },
            6 => self.grow,
            7 => self.fade,
            8 => @intCast(self.scroll_requests),
            else => @intFromEnum(self.visibility),
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

extern "user32" fn GetAncestor(hwnd: w32.HWND, gaFlags: u32) callconv(.winapi) ?w32.HWND;

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

test "dragOffset from the middle of the thumb: Shift+click centers it on the pointer" {
    // A 20 px thumb grabbed at 10 px: the pointer at 200 puts its top at
    // 190, half way down the 380 px range.
    try testing.expectEqual(@as(usize, 475), dragOffset(200, 10, 400, 20, 1000, 50).?);
    try testing.expectEqual(@as(usize, 0), dragOffset(3, 10, 400, 20, 1000, 50).?);
    try testing.expectEqual(@as(usize, 950), dragOffset(399, 10, 400, 20, 1000, 50).?);
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

test "D11: full scrollback pruning must not reveal the scrollbar" {
    var sb: Scrollbar = .{
        .alloc = testing.allocator,
        .surface = undefined,
        .owner = undefined,
        .hwnd = undefined,
        .window_lost = true,
        .first_update = false,
        .state = .{ .total = 100, .offset = 50, .len = 24 },
    };
    sb.update(.{ .total = 100, .offset = 49, .len = 24 });
    try testing.expectEqual(Visibility.hidden, sb.visibility);
    for ([_]terminal.Scrollbar{
        .{ .total = 101, .offset = 77, .len = 24 },
        .{ .total = 102, .offset = 77, .len = 24 },
        .{ .total = 100, .offset = 70, .len = 30 },
        .{ .total = 24, .offset = 0, .len = 24 },
    }) |state| {
        sb.update(state);
        try testing.expectEqual(Visibility.hidden, sb.visibility);
    }
}

test "scrollable: only with more rows than fit" {
    try testing.expect(scrollable(.{ .total = 25, .offset = 1, .len = 24 }));
    try testing.expect(!scrollable(.{ .total = 24, .offset = 0, .len = 24 }));
    try testing.expect(!scrollable(.zero));
}

test "pageOffset: a page each way within the scrollback" {
    try testing.expectEqual(@as(usize, 26), pageOffset(50, 24, 100, .up));
    try testing.expectEqual(@as(usize, 74), pageOffset(50, 24, 100, .down));
    try testing.expectEqual(@as(usize, 0), pageOffset(10, 24, 100, .up));
    try testing.expectEqual(@as(usize, 76), pageOffset(70, 24, 100, .down));
    try testing.expectEqual(@as(usize, 76), pageOffset(76, 24, 100, .down));
    try testing.expectEqual(@as(usize, 0), pageOffset(0, 24, 100, .up));
    // An offset past the end (the scrollback shrank) counts from the end.
    try testing.expectEqual(@as(usize, 52), pageOffset(500, 24, 100, .up));
    try testing.expectEqual(@as(usize, 0), pageOffset(3, 24, 20, .down));
}

test "pagesToward: a held press pages until the thumb reaches the pointer" {
    const thumb: ThumbRect = .{ .y = 100, .h = 40 };
    try testing.expect(pagesToward(thumb, 99, .up));
    try testing.expect(!pagesToward(thumb, 100, .up));
    try testing.expect(!pagesToward(thumb, 139, .down));
    try testing.expect(pagesToward(thumb, 140, .down));
    // Past the thumb the other way: no paging back.
    try testing.expect(!pagesToward(thumb, 200, .up));
    try testing.expect(!pagesToward(thumb, 10, .down));
}

test "inEdgeStrip: the strip at the right edge" {
    try testing.expect(inEdgeStrip(782, 800, 18));
    try testing.expect(inEdgeStrip(799, 800, 18));
    try testing.expect(!inEdgeStrip(781, 800, 18));
    try testing.expect(!inEdgeStrip(800, 800, 18));
    try testing.expect(!inEdgeStrip(-5, 800, 18));
    try testing.expect(!inEdgeStrip(799, 800, 0));
}

test "Ramp: paced by the distance, continuous when turned back" {
    const ms = std.time.ns_per_ms;
    const up = Ramp.begin(0, 0, 255, 160, anim.motion.linear);
    try testing.expectEqual(@as(u8, 0), up.at(0));
    try testing.expectEqual(@as(u8, 128), up.at(80 * ms));
    try testing.expectEqual(@as(u8, 255), up.at(160 * ms));
    try testing.expect(up.tween.done(160 * ms));
    // Turning back from half way starts where the value is and takes
    // half the time.
    const back = Ramp.begin(80 * ms, up.at(80 * ms), 0, 160, anim.motion.linear);
    try testing.expectEqual(@as(u8, 128), back.at(80 * ms));
    try testing.expect(!back.tween.done(159 * ms));
    try testing.expect(back.tween.done(161 * ms));
    try testing.expectEqual(@as(u8, 0), back.at(200 * ms));
    // No distance, no time.
    const none = Ramp.begin(5 * ms, 40, 40, 160, anim.motion.enter);
    try testing.expect(none.tween.done(5 * ms));
    try testing.expectEqual(@as(u8, 40), none.at(5 * ms));
}

test "render: the track, and a thumb only when there is one" {
    var pixels: [12 * 60]u32 = undefined;
    const fg: terminal.color.RGB = .{ .r = 200, .g = 200, .b = 200 };
    const bg: terminal.color.RGB = .{ .r = 10, .g = 20, .b = 30 };
    var key: PaintKey = .{
        .w = 12,
        .h = 60,
        .mode = .overlay,
        .bg = bg,
        .fg = fg,
        .scale = 1,
        .grow = 0,
        .dragging = false,
        .thumb = null,
    };

    // Overlay without a thumb: all but transparent, so the strip still
    // catches the pointer.
    render(key, &pixels);
    for (pixels) |px| try testing.expectEqual(packBGRA(fg, 1), px);

    // A thumb at rows 20..40 against the right edge.
    key.thumb = .{ .y = 20, .h = 20 };
    render(key, &pixels);
    const center = pixels[30 * 12 + 8];
    try testing.expect(center >> 24 >= ALPHA_IDLE);
    try testing.expectEqual(packBGRA(fg, 1), pixels[30 * 12 + 0]);
    try testing.expectEqual(packBGRA(fg, 1), pixels[5 * 12 + 8]);

    // Dragged, the thumb is brighter.
    key.dragging = true;
    render(key, &pixels);
    try testing.expect(pixels[30 * 12 + 8] >> 24 > center >> 24);

    // Always visible: the opaque background, no thumb while it all fits.
    key = .{ .w = 12, .h = 60, .mode = .always_visible, .bg = bg, .fg = fg, .scale = 1, .grow = 0, .dragging = false, .thumb = null };
    render(key, &pixels);
    for (pixels) |px| try testing.expectEqual(packBGRA(bg, 255), px);
}

test "PaintKey: a scroll that moves no pixel paints nothing new" {
    const min_h = 20;
    const a = thumbRect(100_000, 50_000, 40, 800, min_h);
    const b = thumbRect(100_001, 50_000, 40, 800, min_h);
    const c = thumbRect(100_000, 60_000, 40, 800, min_h);
    const key = struct {
        fn of(thumb: ThumbRect) PaintKey {
            return .{ .w = 18, .h = 800, .mode = .overlay, .bg = .{}, .fg = .{}, .scale = 1.5, .grow = 0, .dragging = false, .thumb = thumb };
        }
    };
    try testing.expect(std.meta.eql(key.of(a), key.of(b)));
    try testing.expect(!std.meta.eql(key.of(a), key.of(c)));
}

test "lerpU8" {
    try testing.expectEqual(@as(u8, 90), lerpU8(90, 160, 0));
    try testing.expectEqual(@as(u8, 160), lerpU8(90, 160, 255));
    try testing.expectEqual(@as(u8, 20), lerpU8(20, 0, 0));
    try testing.expectEqual(@as(u8, 10), lerpU8(0, 20, 128));
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

test "reservedWidth: only an enabled always-visible scrollbar takes a column" {
    try testing.expectEqual(@as(i32, 14), reservedWidth(true, .always_visible, 14));
    try testing.expectEqual(@as(i32, 0), reservedWidth(true, .overlay, 12));
    // scrollbar = never
    try testing.expectEqual(@as(i32, 0), reservedWidth(false, .always_visible, 14));
    try testing.expectEqual(@as(i32, 0), reservedWidth(false, .overlay, 12));
}

test "gridWidth: subtracts the reserved width when the surface can spare it" {
    try testing.expectEqual(@as(u32, 800), Scrollbar.gridWidth(800, 0));
    try testing.expectEqual(@as(u32, 779), Scrollbar.gridWidth(800, 21));
    try testing.expectEqual(@as(u32, 21), Scrollbar.gridWidth(21, 21));
    try testing.expectEqual(@as(u32, 10), Scrollbar.gridWidth(10, 21));
}

test "thumbRect: minimum height keeps the position inverse to dragging" {
    const middle = thumbRect(10_000, 4999, 2, 400, 20);
    try testing.expectEqual(@as(i32, 190), middle.y);
    try testing.expectEqual(@as(i32, 20), middle.h);
    try testing.expectEqual(@as(usize, 4999), dragOffset(middle.y, 0, 400, middle.h, 10_000, 2).?);
    const bottom = thumbRect(10_000, 9998, 2, 400, 20);
    try testing.expectEqual(@as(i32, 380), bottom.y);
    try testing.expectEqual(@as(usize, 9998), dragOffset(bottom.y, 0, 400, bottom.h, 10_000, 2).?);
    try testing.expectEqual(ThumbRect{ .y = 0, .h = 0 }, thumbRect(100, 10, 2, -5, 20));
}

test "scrollTo: unchanged offset never touches the terminal or its window" {
    var scrollbar: Scrollbar = .{
        .alloc = testing.allocator,
        .surface = undefined,
        .owner = undefined,
        .hwnd = undefined,
        .state = .{ .total = 100, .offset = 50, .len = 24 },
    };
    scrollbar.scrollTo(50);
    try testing.expectEqual(@as(u32, 0), scrollbar.scroll_requests);
    try testing.expectEqual(@as(u32, 0), scrollbar.paints);
}

test "owner visibility intent survives layout, output and disabled scrollbar" {
    var scrollbar: Scrollbar = .{
        .alloc = testing.allocator,
        .surface = undefined,
        .owner = undefined,
        .hwnd = undefined,
        .window_lost = true,
        .enabled = false,
        .mode = .always_visible,
    };
    scrollbar.setOwnerVisible(false);
    try testing.expect(!scrollbar.owner_visible);
    scrollbar.enabled = true;
    try testing.expect(!scrollbar.wantsVisible());
    try testing.expect(!scrollbar.ownerShown(true));
    _ = scrollbar.repositionAndResize();
    scrollbar.update(.{ .total = 100, .offset = 40, .len = 24 });
    try testing.expect(!scrollbar.owner_visible);
    try testing.expectEqual(@as(u32, 0), scrollbar.paints);
    scrollbar.enabled = false;
    scrollbar.setOwnerVisible(true);
    try testing.expect(scrollbar.owner_visible);
}

test {
    testing.refAllDecls(Scrollbar);
}
