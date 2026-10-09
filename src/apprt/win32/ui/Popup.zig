//! Reusable owned popup host for custom-drawn UI (link preview, command
//! palette, menus, flyouts): a `WS_POPUP` window owned by a terminal
//! window, with Windows 11 rounded corners (`DWMWA_WINDOW_CORNER_PREFERENCE`)
//! and the system drop shadow, per-monitor DPI, Direct2D rendering through
//! a `d2d.Canvas`, keyboard, mouse (hover/click/wheel) and an optional
//! IME-capable single-line text input for filter boxes.
//!
//! Usage: embed a `Popup` in an address-stable owner struct, `create` it
//! once with `Callbacks` (paint, key, mouse, text, dismissed), position it
//! with `show(rect)` (screen pixels; size content in DIPs with `scale`),
//! repaint with `invalidate`, and `destroy` it with the owner. Dismissal
//! (Escape, click outside, lost activation) hides the popup and reports
//! the reason through `Callbacks.dismissed`.
//!
//! Text input: with `Options.text_input` the popup keeps a `TextInput`
//! (`popup.input`) that receives typing, editing keys, clipboard and IME
//! composition; draw it with `drawTextInput` in the paint callback (this
//! also positions the IME candidate window) and read it with
//! `TextInput.text`. Keys go to `Callbacks.key` first, so owners can take
//! Up/Down/Enter before the input sees them.
const Popup = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32_popup);

/// DWM corner preference of the popup (DWM_WINDOW_CORNER_PREFERENCE).
pub const Corners = enum(u32) {
    default = 0,
    square = 1,
    round = 2,
    round_small = 3,
};

pub const DismissReason = enum {
    /// Escape was pressed.
    escape,
    /// The user clicked outside the popup (mouse capture).
    outside_click,
    /// The popup lost activation (clicked elsewhere, Alt+Tab).
    deactivated,
    /// The owner asked for it (`dismiss`).
    owner,
};

pub const MouseKind = enum { move, leave, down, up, double_click, wheel };
pub const MouseButton = enum { none, left, right, middle };

pub const MouseEvent = struct {
    kind: MouseKind,
    button: MouseButton = .none,
    /// Position in DIPs relative to the client area.
    pos: d2d.Point,
    /// Wheel notches (positive = away from the user).
    wheel: f32 = 0,
};

pub const Key = struct {
    vk: u16,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

pub const Callbacks = struct {
    /// Passed to every callback.
    ctx: *anyopaque,
    /// Paint the content in DIPs. The canvas is cleared to transparent
    /// black; fill the background yourself.
    paint: *const fn (ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void,
    /// A key press. Return true when handled; unhandled keys go to the
    /// text input and then to Escape dismissal.
    key: ?*const fn (ctx: *anyopaque, popup: *Popup, key: Key) bool = null,
    mouse: ?*const fn (ctx: *anyopaque, popup: *Popup, event: MouseEvent) void = null,
    /// The text input changed (typing, deletion, paste, IME commit).
    text_changed: ?*const fn (ctx: *anyopaque, popup: *Popup) void = null,
    /// The popup was dismissed and is now hidden.
    dismissed: ?*const fn (ctx: *anyopaque, popup: *Popup, reason: DismissReason) void = null,
    /// The popup moved to a monitor with another DPI; resize it.
    dpi_changed: ?*const fn (ctx: *anyopaque, popup: *Popup) void = null,
};

pub const Options = struct {
    /// Take activation and keyboard focus when shown. Non-activating
    /// popups (previews, tooltips) never take focus.
    activate: bool = false,
    /// Dismiss on Escape.
    dismiss_on_escape: bool = true,
    /// Dismiss when an activating popup loses activation, or (with
    /// `capture_mouse`) on a click outside.
    dismiss_on_outside_click: bool = true,
    /// Capture the mouse while shown, like a menu.
    capture_mouse: bool = false,
    /// Let mouse input fall through to the window below (status bubbles).
    click_through: bool = false,
    corners: Corners = .round,
    /// The system drop shadow (CS_DROPSHADOW).
    shadow: bool = true,
    /// Keep a `TextInput` and route typing and IME input to it.
    text_input: bool = false,
    /// The 1px DWM border color (Windows 11), or the system default.
    border_color: ?d2d.Color = null,
    /// Use the dark DWM frame variant.
    dark: bool = true,
};

hwnd: ?w32.HWND = null,
owner: ?w32.HWND = null,
canvas: ?d2d.Canvas = null,
alloc: Allocator = undefined,
options: Options = .{},
callbacks: ?Callbacks = null,
visible: bool = false,
dpi: u32 = 96,
tracking_leave: bool = false,

/// The text input (with `Options.text_input`).
input: TextInput = .{},

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxPopup");
const CLASS_NAME_SHADOW = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGxPopupShadow");

const CS_DROPSHADOW: u32 = 0x00020000;
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const HTTRANSPARENT: isize = -1;
const WM_NCHITTEST: u32 = 0x0084;
const WM_CAPTURECHANGED: u32 = 0x0215;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_IME_CHAR: u32 = 0x0286;

/// Create the (hidden) popup window owned by `owner`.
pub fn create(
    self: *Popup,
    hinstance: w32.HINSTANCE,
    owner: w32.HWND,
    factory: *d2d.Factory,
    options: Options,
    callbacks: Callbacks,
) !void {
    if (self.hwnd != null) return;
    try registerClasses(hinstance);

    var ex_style: u32 = w32.WS_EX_TOOLWINDOW;
    if (!options.activate) ex_style |= w32.WS_EX_NOACTIVATE;
    const hwnd = w32.CreateWindowExW(
        ex_style,
        if (options.shadow) CLASS_NAME_SHADOW else CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        1,
        1,
        owner,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;

    self.* = .{
        .hwnd = hwnd,
        .owner = owner,
        .canvas = d2d.Canvas.init(factory),
        .alloc = factory.alloc,
        .options = options,
        .callbacks = callbacks,
        .dpi = dpiOf(owner),
    };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    const corners: u32 = @intFromEnum(options.corners);
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, @ptrCast(&corners), @sizeOf(u32));
    const dark: u32 = @intFromBool(options.dark);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&dark), @sizeOf(u32));
    if (options.border_color) |color| self.setBorderColor(color);
}

/// Destroy the window and its resources.
pub fn destroy(self: *Popup) void {
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
    }
    if (self.canvas) |*canvas| canvas.deinit();
    self.input.deinit(self.alloc);
    self.* = .{};
}

/// Set the 1px DWM border color (Windows 11).
pub fn setBorderColor(self: *Popup, color: d2d.Color) void {
    const hwnd = self.hwnd orelse return;
    const ref: u32 = color.colorRef();
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_BORDER_COLOR, @ptrCast(&ref), @sizeOf(u32));
}

/// DPI scale (DPI / 96) of the popup.
pub fn scale(self: *const Popup) f32 {
    return @as(f32, @floatFromInt(self.dpi)) / 96.0;
}

/// DPI scale of the owner window: size a popup with it before it is
/// shown on the owner's monitor.
pub fn ownerScale(self: *const Popup) f32 {
    const owner = self.owner orelse return 1.0;
    return @as(f32, @floatFromInt(dpiOf(owner))) / 96.0;
}

/// The client size in DIPs.
pub fn sizeDip(self: *const Popup) d2d.Size {
    const hwnd = self.hwnd orelse return .{ .width = 0, .height = 0 };
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return .{ .width = 0, .height = 0 };
    const s = self.scale();
    return .{
        .width = @as(f32, @floatFromInt(client.right - client.left)) / s,
        .height = @as(f32, @floatFromInt(client.bottom - client.top)) / s,
    };
}

/// Move/resize the popup to `rect` (screen pixels) and show it.
pub fn show(self: *Popup, rect: w32.RECT) void {
    const hwnd = self.hwnd orelse return;
    var flags: u32 = w32.SWP_NOZORDER;
    if (!self.options.activate) flags |= w32.SWP_NOACTIVATE;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, flags);
    self.dpi = dpiOf(hwnd);
    if (self.options.activate) {
        _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
        _ = w32.SetFocus(hwnd);
    } else {
        _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    }
    if (self.options.capture_mouse) _ = w32.SetCapture(hwnd);
    self.visible = true;
    self.invalidate();
}

/// Move/resize without changing visibility (screen pixels).
pub fn setBounds(self: *Popup, rect: w32.RECT) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    self.invalidate();
}

/// Hide without reporting a dismissal.
pub fn hide(self: *Popup) void {
    if (!self.visible) return;
    self.visible = false;
    const hwnd = self.hwnd orelse return;
    if (self.options.capture_mouse and w32.GetCapture() == hwnd) _ = w32.ReleaseCapture();
    _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
}

/// Hide and report `reason` through `Callbacks.dismissed`.
pub fn dismiss(self: *Popup, reason: DismissReason) void {
    if (!self.visible) return;
    self.hide();
    if (self.callbacks) |cb| if (cb.dismissed) |f| f(cb.ctx, self, reason);
}

/// Repaint the popup.
pub fn invalidate(self: *Popup) void {
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}

fn dpiOf(hwnd: w32.HWND) u32 {
    const dpi = w32.GetDpiForWindow(hwnd);
    return if (dpi == 0) 96 else dpi;
}

/// Draw the text input into `rect` (DIPs): field background, border, text
/// or placeholder, IME composition and caret. Also positions the IME
/// candidate window at the caret.
pub fn drawTextInput(
    self: *Popup,
    canvas: *d2d.Canvas,
    rect: d2d.Rect,
    tokens: style.Tokens,
    placeholder: []const u8,
) void {
    const input = &self.input;
    input.field = rect;
    const radius = style.metrics.corner_radius / 2;
    canvas.fillRoundedRect(rect, radius, tokens.surface);
    canvas.strokeRoundedRect(rect, radius, tokens.border, style.metrics.border_width);
    // Focus underline in the accent color (Fluent text box).
    canvas.fillRect(.{ .x = rect.x + radius, .y = rect.y + rect.h - 2, .w = rect.w - 2 * radius, .h = 2 }, tokens.accent);

    const pad = style.metrics.padding_x;
    const text_rect: d2d.Rect = .{ .x = rect.x + pad, .y = rect.y, .w = rect.w - 2 * pad, .h = rect.h };
    const text_style: d2d.TextStyle = .{
        .size = style.font_size.body,
        .color = tokens.text,
        .ellipsis = false,
    };

    var buf: [1024]u8 = undefined;
    const before = input.utf8Range(&buf, 0, input.caret);
    const before_w = canvas.measureText(before, text_style, 100_000).width;
    // Scroll so the caret stays visible.
    const scroll = @max(0, before_w - text_rect.w + 2);

    canvas.pushClip(text_rect);
    defer canvas.popClip();

    if (input.buf.items.len == 0 and input.composition.items.len == 0) {
        var placeholder_style = text_style;
        placeholder_style.color = tokens.text_disabled;
        canvas.drawText(placeholder, text_rect, placeholder_style);
    } else {
        const origin_x = text_rect.x - scroll;
        // Selection highlight.
        if (input.anchor != input.caret) {
            const lo = @min(input.anchor, input.caret);
            const hi = @max(input.anchor, input.caret);
            var tmp: [1024]u8 = undefined;
            const x0 = canvas.measureText(input.utf8Range(&tmp, 0, lo), text_style, 100_000).width;
            const x1 = canvas.measureText(input.utf8Range(&tmp, 0, hi), text_style, 100_000).width;
            canvas.fillRect(.{ .x = origin_x + x0, .y = rect.y + 6, .w = x1 - x0, .h = rect.h - 12 }, tokens.selected);
        }
        var all: [1024]u8 = undefined;
        const text = input.utf8Range(&all, 0, input.buf.items.len);
        canvas.drawText(text, .{ .x = origin_x, .y = rect.y, .w = 100_000, .h = rect.h }, text_style);

        // Inline IME composition after the caret, underlined.
        if (input.composition.items.len > 0) {
            var comp_buf: [512]u8 = undefined;
            const comp = utf16ToUtf8(&comp_buf, input.composition.items);
            const cx = origin_x + before_w;
            const comp_w = canvas.measureText(comp, text_style, 100_000).width;
            canvas.fillRect(.{ .x = cx, .y = rect.y + 4, .w = comp_w, .h = rect.h - 8 }, tokens.surface);
            var comp_style = text_style;
            comp_style.color = tokens.text;
            canvas.drawText(comp, .{ .x = cx, .y = rect.y, .w = comp_w + 1, .h = rect.h }, comp_style);
            canvas.fillRect(.{ .x = cx, .y = rect.y + rect.h - 9, .w = comp_w, .h = 1 }, tokens.text_secondary);
        }
    }

    // Caret.
    const caret_x = text_rect.x - scroll + before_w;
    canvas.fillRect(.{ .x = caret_x, .y = rect.y + 7, .w = 1, .h = rect.h - 14 }, tokens.text);
    input.caret_x = caret_x;
    self.positionIme();
}

fn utf16ToUtf8(buf: []u8, units: []const u16) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    var it = std.unicode.Utf16LeIterator.init(units);
    while (it.nextCodepoint() catch null) |cp| {
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch continue;
        out.writeAll(tmp[0..len]) catch break;
    }
    return out.buffered();
}

/// Put the IME composition/candidate window at the caret.
fn positionIme(self: *Popup) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    const s = self.scale();
    const field = self.input.field;
    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = .{
            .x = style.px(self.input.caret_x, s),
            .y = style.px(field.y + field.h - 4, s),
        },
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
}

/// A single-line, IME-capable text field model (UTF-16, with a caret and
/// selection anchor in code units).
pub const TextInput = struct {
    buf: std.ArrayList(u16) = .empty,
    caret: usize = 0,
    anchor: usize = 0,
    /// The in-progress IME composition (shown at the caret).
    composition: std.ArrayList(u16) = .empty,
    /// Where `drawTextInput` last drew the field, and the caret, in DIPs.
    field: d2d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    caret_x: f32 = 0,

    pub fn deinit(self: *TextInput, alloc: Allocator) void {
        self.buf.deinit(alloc);
        self.composition.deinit(alloc);
        self.* = .{};
    }

    /// The text as UTF-8, allocated.
    pub fn text(self: *const TextInput, alloc: Allocator) ![]u8 {
        return std.unicode.utf16LeToUtf8Alloc(alloc, self.buf.items) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => try alloc.dupe(u8, ""),
        };
    }

    /// The UTF-8 of code units [from, to) in `buf` (cut off when it does
    /// not fit).
    pub fn utf8Range(self: *const TextInput, buf: []u8, from: usize, to: usize) []const u8 {
        return utf16ToUtf8(buf, self.buf.items[from..to]);
    }

    pub fn setText(self: *TextInput, alloc: Allocator, utf8: []const u8) !void {
        self.buf.clearRetainingCapacity();
        const units = try wstr.allocZ(alloc, utf8);
        defer alloc.free(units);
        try self.buf.appendSlice(alloc, units);
        self.caret = self.buf.items.len;
        self.anchor = self.caret;
    }

    pub fn clear(self: *TextInput) void {
        self.buf.clearRetainingCapacity();
        self.composition.clearRetainingCapacity();
        self.caret = 0;
        self.anchor = 0;
    }

    fn selection(self: *const TextInput) struct { usize, usize } {
        return .{ @min(self.anchor, self.caret), @max(self.anchor, self.caret) };
    }

    fn deleteSelection(self: *TextInput) bool {
        const lo, const hi = self.selection();
        if (lo == hi) return false;
        self.buf.replaceRangeAssumeCapacity(lo, hi - lo, &.{});
        self.caret = lo;
        self.anchor = lo;
        return true;
    }

    /// Insert code units at the caret, replacing the selection.
    fn insert(self: *TextInput, alloc: Allocator, units: []const u16) !void {
        _ = self.deleteSelection();
        try self.buf.insertSlice(alloc, self.caret, units);
        self.caret += units.len;
        self.anchor = self.caret;
    }

    fn isLowSurrogate(u: u16) bool {
        return u >= 0xDC00 and u <= 0xDFFF;
    }

    fn prevBoundary(self: *const TextInput, pos: usize) usize {
        if (pos == 0) return 0;
        var p = pos - 1;
        if (p > 0 and isLowSurrogate(self.buf.items[p])) p -= 1;
        return p;
    }

    fn nextBoundary(self: *const TextInput, pos: usize) usize {
        if (pos >= self.buf.items.len) return self.buf.items.len;
        var p = pos + 1;
        if (p < self.buf.items.len and isLowSurrogate(self.buf.items[p])) p += 1;
        return p;
    }

    fn moveCaret(self: *TextInput, pos: usize, extend: bool) void {
        self.caret = pos;
        if (!extend) self.anchor = pos;
    }

    pub const KeyResult = enum { ignored, moved, changed };

    /// Handle an editing key; `hwnd` is used for the clipboard.
    fn handleKey(self: *TextInput, alloc: Allocator, hwnd: w32.HWND, key: Key) KeyResult {
        const len = self.buf.items.len;
        switch (key.vk) {
            w32.VK_LEFT => {
                const lo, _ = self.selection();
                const target = if (!key.shift and self.anchor != self.caret) lo else self.prevBoundary(self.caret);
                self.moveCaret(target, key.shift);
                return .moved;
            },
            w32.VK_RIGHT => {
                _, const hi = self.selection();
                const target = if (!key.shift and self.anchor != self.caret) hi else self.nextBoundary(self.caret);
                self.moveCaret(target, key.shift);
                return .moved;
            },
            w32.VK_HOME => {
                self.moveCaret(0, key.shift);
                return .moved;
            },
            w32.VK_END => {
                self.moveCaret(len, key.shift);
                return .moved;
            },
            w32.VK_BACK => {
                if (!self.deleteSelection()) {
                    if (self.caret == 0) return .moved;
                    const start = self.prevBoundary(self.caret);
                    self.buf.replaceRangeAssumeCapacity(start, self.caret - start, &.{});
                    self.moveCaret(start, false);
                }
                return .changed;
            },
            w32.VK_DELETE => {
                if (!self.deleteSelection()) {
                    if (self.caret >= len) return .moved;
                    const end = self.nextBoundary(self.caret);
                    self.buf.replaceRangeAssumeCapacity(self.caret, end - self.caret, &.{});
                }
                return .changed;
            },
            'A' => if (key.ctrl) {
                self.anchor = 0;
                self.caret = len;
                return .moved;
            },
            'C', 'X' => if (key.ctrl) {
                const lo, const hi = self.selection();
                if (lo == hi) return .moved;
                copyToClipboard(hwnd, self.buf.items[lo..hi]);
                if (key.vk == 'X') {
                    _ = self.deleteSelection();
                    return .changed;
                }
                return .moved;
            },
            'V' => if (key.ctrl) {
                self.pasteFromClipboard(alloc, hwnd) catch |err| {
                    log.warn("paste into popup input failed err={}", .{err});
                };
                return .changed;
            },
            else => {},
        }
        return .ignored;
    }

    fn pasteFromClipboard(self: *TextInput, alloc: Allocator, hwnd: w32.HWND) !void {
        if (w32.OpenClipboard(hwnd) == 0) return;
        defer _ = w32.CloseClipboard();
        const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return;
        const ptr = w32.GlobalLock(handle) orelse return;
        defer _ = w32.GlobalUnlock(handle);
        const units: [*:0]const u16 = @ptrCast(@alignCast(ptr));
        const slice = std.mem.span(units);
        // Single line: stop at the first line break.
        var end: usize = 0;
        while (end < slice.len and slice[end] != '\r' and slice[end] != '\n') end += 1;
        try self.insert(alloc, slice[0..end]);
    }
};

fn copyToClipboard(hwnd: w32.HWND, units: []const u16) void {
    const bytes = (units.len + 1) * @sizeOf(u16);
    const handle = w32.GlobalAlloc(w32.GMEM_MOVEABLE, bytes) orelse return;
    const ptr = w32.GlobalLock(handle) orelse {
        _ = w32.GlobalFree(handle);
        return;
    };
    const dst: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dst[0..units.len], units);
    dst[units.len] = 0;
    _ = w32.GlobalUnlock(handle);
    if (w32.OpenClipboard(hwnd) == 0) {
        _ = w32.GlobalFree(handle);
        return;
    }
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, handle) == null) _ = w32.GlobalFree(handle);
}

fn keyFromWparam(wparam: usize) Key {
    return .{
        .vk = @intCast(wparam & 0xFFFF),
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
    };
}

fn pointFromLparam(self: *const Popup, lparam: isize) d2d.Point {
    const x: i16 = @truncate(lparam & 0xFFFF);
    const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
    const s = self.scale();
    return .{ .x = @as(f32, @floatFromInt(x)) / s, .y = @as(f32, @floatFromInt(y)) / s };
}

fn insideClient(self: *const Popup, lparam: isize) bool {
    const hwnd = self.hwnd orelse return false;
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return false;
    return x >= client.left and y >= client.top and x < client.right and y < client.bottom;
}

fn emitMouse(self: *Popup, event: MouseEvent) void {
    if (self.callbacks) |cb| if (cb.mouse) |f| f(cb.ctx, self, event);
}

fn textChanged(self: *Popup) void {
    self.invalidate();
    if (self.callbacks) |cb| if (cb.text_changed) |f| f(cb.ctx, self);
}

fn paint(self: *Popup, hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    _ = w32.BeginPaint(hwnd, &ps);
    defer _ = w32.EndPaint(hwnd, &ps);
    const cb = self.callbacks orelse return;
    const canvas = &(self.canvas orelse return);
    if (!canvas.beginHwnd(hwnd, self.dpi)) return;
    canvas.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    cb.paint(cb.ctx, self, canvas);
    canvas.end();
}

fn handleImeComposition(self: *Popup, hwnd: w32.HWND, lparam: isize) void {
    const flags: u32 = @intCast(lparam & 0xFFFFFFFF);
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    if (flags & w32.GCS_RESULTSTR != 0) {
        var buf: [256]u16 = undefined;
        const bytes = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &buf, @sizeOf(@TypeOf(buf)));
        if (bytes > 0) {
            const n: usize = @intCast(@divTrunc(bytes, 2));
            self.input.composition.clearRetainingCapacity();
            self.input.insert(self.alloc, buf[0..n]) catch {};
            self.textChanged();
        }
    }
    if (flags & w32.GCS_COMPSTR != 0) {
        var buf: [256]u16 = undefined;
        const bytes = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, &buf, @sizeOf(@TypeOf(buf)));
        self.input.composition.clearRetainingCapacity();
        if (bytes > 0) {
            const n: usize = @intCast(@divTrunc(bytes, 2));
            self.input.composition.appendSlice(self.alloc, buf[0..n]) catch {};
        }
        self.invalidate();
    }
}

var classes_registered = false;

fn registerClasses(hinstance: w32.HINSTANCE) !void {
    if (classes_registered) return;
    for ([_]struct { [*:0]const u16, u32 }{
        .{ CLASS_NAME, 0 },
        .{ CLASS_NAME_SHADOW, CS_DROPSHADOW },
    }) |class| {
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = w32.CS_DBLCLKS | class[1],
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class[0],
            .hIconSm = null,
        };
        if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    }
    classes_registered = true;
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Popup = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        WM_NCHITTEST => {
            if (self.options.click_through) return HTTRANSPARENT;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEACTIVATE => {
            if (!self.options.activate) return w32.MA_NOACTIVATE;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        w32.WM_SIZE => {
            self.invalidate();
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.dpi = @intCast((wparam >> 16) & 0xFFFF);
            const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
            if (self.callbacks) |cb| if (cb.dpi_changed) |f| f(cb.ctx, self);
            self.invalidate();
            return 0;
        },
        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            const key = keyFromWparam(wparam);
            if (self.callbacks) |cb| {
                if (cb.key) |f| {
                    if (f(cb.ctx, self, key)) return 0;
                }
            }
            if (self.options.text_input) {
                switch (self.input.handleKey(self.alloc, hwnd, key)) {
                    .ignored => {},
                    .moved => {
                        self.invalidate();
                        return 0;
                    },
                    .changed => {
                        self.textChanged();
                        return 0;
                    },
                }
            }
            if (key.vk == w32.VK_ESCAPE and self.options.dismiss_on_escape) {
                self.dismiss(.escape);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CHAR => {
            if (!self.options.text_input) return 0;
            const unit: u16 = @intCast(wparam & 0xFFFF);
            // Control characters (Enter, Escape, Backspace, Ctrl+letter)
            // are handled as keys.
            if (unit < 0x20 or unit == 0x7F) return 0;
            self.input.insert(self.alloc, &.{unit}) catch return 0;
            self.textChanged();
            return 0;
        },
        WM_IME_CHAR => return 0,
        w32.WM_IME_SETCONTEXT => {
            if (!self.options.text_input) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            // The composition is drawn inline by drawTextInput.
            const cleared = lparam & ~w32.ISC_SHOWUICOMPOSITIONWINDOW;
            return w32.DefWindowProcW(hwnd, msg, wparam, cleared);
        },
        w32.WM_IME_STARTCOMPOSITION => {
            if (!self.options.text_input) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.positionIme();
            return 0;
        },
        w32.WM_IME_COMPOSITION => {
            if (!self.options.text_input) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.handleImeComposition(hwnd, lparam);
            return 0;
        },
        w32.WM_IME_ENDCOMPOSITION => {
            if (self.options.text_input) {
                self.input.composition.clearRetainingCapacity();
                self.invalidate();
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = w32.TrackMouseEvent(&tme);
                self.tracking_leave = true;
            }
            self.emitMouse(.{ .kind = .move, .pos = self.pointFromLparam(lparam) });
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            self.emitMouse(.{ .kind = .leave, .pos = .{ .x = -1, .y = -1 } });
            return 0;
        },
        w32.WM_LBUTTONDOWN, w32.WM_RBUTTONDOWN, w32.WM_MBUTTONDOWN => {
            if (self.options.capture_mouse and self.options.dismiss_on_outside_click and !self.insideClient(lparam)) {
                self.dismiss(.outside_click);
                return 0;
            }
            self.emitMouse(.{ .kind = .down, .button = buttonOf(msg), .pos = self.pointFromLparam(lparam) });
            return 0;
        },
        w32.WM_LBUTTONUP, w32.WM_RBUTTONUP, w32.WM_MBUTTONUP => {
            self.emitMouse(.{ .kind = .up, .button = buttonOf(msg), .pos = self.pointFromLparam(lparam) });
            return 0;
        },
        w32.WM_LBUTTONDBLCLK, WM_RBUTTONDBLCLK => {
            self.emitMouse(.{ .kind = .double_click, .button = buttonOf(msg), .pos = self.pointFromLparam(lparam) });
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            // Wheel coordinates are in screen space.
            var pt = w32.POINT{
                .x = @as(i16, @truncate(lparam & 0xFFFF)),
                .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
            };
            _ = w32.ScreenToClient(hwnd, &pt);
            const raw: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            const s = self.scale();
            self.emitMouse(.{
                .kind = .wheel,
                .pos = .{ .x = @as(f32, @floatFromInt(pt.x)) / s, .y = @as(f32, @floatFromInt(pt.y)) / s },
                .wheel = @as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt(w32.WHEEL_DELTA)),
            });
            return 0;
        },
        w32.WM_ACTIVATE => {
            const state: u16 = @truncate(wparam & 0xFFFF);
            if (state == w32.WA_INACTIVE and self.options.activate and self.options.dismiss_on_outside_click) {
                self.dismiss(.deactivated);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_CAPTURECHANGED => {
            const new_capture: usize = @bitCast(lparam);
            if (self.options.capture_mouse and self.options.dismiss_on_outside_click and new_capture != @intFromPtr(hwnd)) {
                self.dismiss(.outside_click);
            }
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn buttonOf(msg: u32) MouseButton {
    return switch (msg) {
        w32.WM_LBUTTONDOWN, w32.WM_LBUTTONUP, w32.WM_LBUTTONDBLCLK => .left,
        w32.WM_RBUTTONDOWN, w32.WM_RBUTTONUP, WM_RBUTTONDBLCLK => .right,
        w32.WM_MBUTTONDOWN, w32.WM_MBUTTONUP => .middle,
        else => .none,
    };
}
