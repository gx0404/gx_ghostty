//! The hovered-URL preview of a terminal surface: a small popup at the
//! bottom-left of the surface, like a browser status bubble, driven by the
//! `mouse_over_link` apprt action.
//!
//! The owning `Surface` embeds this struct as `link_preview` and calls
//! `show`/`hide` and `deinit`. The popup is a STATIC control owned by the
//! surface's window, which colors it in `WM_CTLCOLORSTATIC`.
const LinkPreview = @This();

const std = @import("std");
const Surface = @import("../Surface.zig");
const w32 = @import("../win32.zig");

/// The preview popup.
hwnd: ?w32.HWND = null,

/// Font for the preview popup (deleted on cleanup).
font: ?*anyopaque = null,

fn surface(self: *LinkPreview) *Surface {
    return @alignCast(@fieldParentPtr("link_preview", self));
}

/// Destroy the popup and its font.
pub fn deinit(self: *LinkPreview) void {
    if (self.hwnd) |h| {
        _ = w32.DestroyWindow(h);
        self.hwnd = null;
    }
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }
}

/// Hide the preview.
pub fn hide(self: *LinkPreview) void {
    if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
}

/// Show `url` at the bottom-left of the surface (hide when it is empty).
pub fn show(self: *LinkPreview, url: []const u8) void {
    if (url.len == 0) {
        self.hide();
        return;
    }
    const s = self.surface();
    const hwnd = s.hwnd orelse return;
    const scale = s.scale;

    if (self.hwnd == null) {
        self.hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            s.parent_window.hwnd.?,
            null,
            s.app.hinstance,
            null,
        );
        if (self.hwnd) |h| {
            if (self.font == null) {
                self.font = w32.CreateFontW(
                    -@as(i32, @intFromFloat(@round(13.0 * scale))),
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
            }
            if (self.font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const preview = self.hwnd orelse return;

    var buf16: [512]u16 = undefined;
    const truncated = if (url.len > 480) url[0..480] else url;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, truncated) catch return;
    buf16[@min(len16, buf16.len - 1)] = 0;
    _ = w32.SetWindowTextW(preview, @ptrCast(&buf16));

    // Rough width from character count, capped to the surface width.
    const char_w: i32 = @intFromFloat(@round(7.0 * scale));
    const pad: i32 = @intFromFloat(@round(12.0 * scale));
    const pw: i32 = @min(
        @as(i32, @intCast(s.width)),
        @as(i32, @intCast(len16)) * char_w + pad,
    );
    const ph: i32 = @intFromFloat(@round(22.0 * scale));
    var pt = w32.POINT{ .x = 0, .y = @as(i32, @intCast(s.height)) - ph };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(preview, null, pt.x, pt.y, pw, ph, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(preview, w32.SW_SHOWNOACTIVATE);
}
