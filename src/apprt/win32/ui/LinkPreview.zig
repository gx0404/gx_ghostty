//! The hovered-URL preview of a terminal surface: a small rounded bubble
//! at the bottom-left of the surface, like a browser status bubble, driven
//! by the `mouse_over_link` apprt action. It is a non-activating,
//! click-through `Popup` drawn with the `Canvas`.
//!
//! The owning `Surface` embeds this struct as `link_preview` and calls
//! `show`/`hide` and `deinit`.
const LinkPreview = @This();

const std = @import("std");
const Surface = @import("../Surface.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const w32 = @import("../win32.zig");

const log = std.log.scoped(.win32);

/// The longest URL shown (in bytes); longer ones are cut off.
const max_url_len = 480;

/// Bubble height and outer margin in DIPs.
const bubble_height: f32 = 28;
const margin: f32 = 6;

popup: Popup = .{},

/// The URL on display (a copy; `show` gets a borrowed slice).
url_buf: [max_url_len]u8 = undefined,
url_len: usize = 0,

fn surface(self: *LinkPreview) *Surface {
    return @alignCast(@fieldParentPtr("link_preview", self));
}

/// Destroy the popup.
pub fn deinit(self: *LinkPreview) void {
    self.popup.destroy();
}

/// Hide the preview.
pub fn hide(self: *LinkPreview) void {
    self.popup.hide();
}

fn tokens(self: *LinkPreview) style.Tokens {
    return style.Tokens.fromConfig(&self.surface().app.config);
}

fn textStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.caption,
        .color = t.text,
        .align_y = .center,
    };
}

/// Show `url` at the bottom-left of the surface (hide when it is empty).
pub fn show(self: *LinkPreview, url: []const u8) void {
    if (url.len == 0) {
        self.hide();
        return;
    }
    const s = self.surface();
    const hwnd = s.hwnd orelse return;
    const owner = s.parent_window.hwnd orelse return;
    const factory = s.app.uiFactory() orelse return;
    const t = self.tokens();

    if (self.popup.hwnd == null) {
        self.popup.create(s.app.hinstance, owner, factory, .{
            .activate = false,
            .click_through = true,
            .dismiss_on_escape = false,
            .dismiss_on_outside_click = false,
            .corners = .round,
            .shadow = true,
            .border_color = t.border,
            .dark = t.dark,
        }, .{
            .ctx = self,
            .paint = paint,
        }) catch |err| {
            log.warn("failed to create the link preview popup err={}", .{err});
            return;
        };
    } else {
        self.popup.setBorderColor(t.border);
    }

    // Keep a codepoint-aligned copy of the URL for painting.
    var len = @min(url.len, max_url_len);
    while (len > 0 and len < url.len and url[len] & 0xC0 == 0x80) len -= 1;
    @memcpy(self.url_buf[0..len], url[0..len]);
    self.url_len = len;

    // Size to the text, capped to the surface width.
    const scale = self.popup.ownerScale();
    const text_w = factory.measureText(self.url_buf[0..len], textStyle(t), 100_000).width;
    const icon_w = style.metrics.icon_size + style.metrics.gap;
    const want_w = text_w + icon_w + 2 * style.metrics.padding_x;
    const max_w = @as(f32, @floatFromInt(s.width)) / scale - 2 * margin;
    const w_dip = @max(@min(want_w, max_w), 0);
    const h_dip = bubble_height;

    var pt: w32.POINT = .{
        .x = style.px(margin, scale),
        .y = @as(i32, @intCast(s.height)) - style.px(h_dip + margin, scale),
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    self.popup.show(.{
        .left = pt.x,
        .top = pt.y,
        .right = pt.x + style.px(w_dip, scale),
        .bottom = pt.y + style.px(h_dip, scale),
    });
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self: *LinkPreview = @ptrCast(@alignCast(ctx));
    const t = self.tokens();
    const size = popup.sizeDip();
    const full: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(full, t.surface_raised);

    const pad = style.metrics.padding_x;
    const icon = style.metrics.icon_size;
    canvas.drawIcon(d2d.icons.link, .{ .x = pad, .y = 0, .w = icon, .h = size.height }, 14, t.accent);

    const text_x = pad + icon + style.metrics.gap;
    var text_style = textStyle(t);
    text_style.color = t.text;
    canvas.drawText(self.url_buf[0..self.url_len], .{
        .x = text_x,
        .y = 0,
        .w = @max(size.width - text_x - pad, 0),
        .h = size.height,
    }, text_style);
}
