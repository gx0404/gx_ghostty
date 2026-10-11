//! The notice that default shortcuts for copying, pasting, searching or
//! splitting never reach Ghostty GX because another program or the input
//! method takes them (`shortcut_conflicts`): a warning `Notice` at the
//! bottom of the window that names the keys, points to the alternatives
//! (the copy and paste keys that still work, the right-click menu and the
//! command palette) and opens the keyboard shortcut sheet. It is the shared
//! notice of the window chrome, so it fades in, keeps chords on one line,
//! holds while the pointer is over it, waits for an open dialog and closes
//! with its close button, its button (which opens the sheet) or after
//! `duration_ms`. When the window's own notice (`Window.notice`) is on
//! screen, this one sits above it.
//!
//! The owning `Window` embeds this struct as `shortcut_notice`, moves it
//! with `reposition` (which also follows a change of the interface
//! language) and destroys it with `deinit`; `App` shows it at most once
//! per session. Its timers are on the notice's own popup window.
const ShortcutNotice = @This();

const std = @import("std");
const gx = @import("../../../gx/main.zig");
const i18n = gx.i18n;
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Keybinds = @import("Keybinds.zig");
const Notice = @import("Notice.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32);

const duration_ms: u32 = 20_000;

/// The gap to the window's own notice when both show.
const stack_gap: f32 = style.space.s;

/// What the notice says: the taken keys and the keys of the alternatives,
/// formatted (e.g. "Ctrl+Shift+C"); empty when there is none.
pub const Content = struct {
    keys: []const u8,
    copy: []const u8 = "",
    paste: []const u8 = "",
    palette: []const u8 = "",
    sheet: []const u8 = "",
};

const Piece = enum { keys, copy, paste, palette, sheet };

notice: Notice = .{},

/// The `Content` pieces, stored back to back, to say it again in another
/// language.
buf: [512]u8 = undefined,
ends: [std.enums.values(Piece).len]usize = @splat(0),
/// The language the notice on screen is in.
language: ?i18n.Language = null,

fn window(self: *ShortcutNotice) *Window {
    return @alignCast(@fieldParentPtr("shortcut_notice", self));
}

/// Destroy the notice.
pub fn deinit(self: *ShortcutNotice) void {
    self.notice.deinit();
    self.language = null;
}

/// Show `content` at the bottom of the window.
pub fn show(self: *ShortcutNotice, content: Content) void {
    var end: usize = 0;
    inline for (std.meta.fields(Content), 0..) |field, i| {
        const text = @field(content, field.name);
        const len = @min(text.len, self.buf.len - end);
        @memcpy(self.buf[end..][0..len], text[0..len]);
        end += len;
        self.ends[i] = end;
    }
    self.showStored();
}

fn showStored(self: *ShortcutNotice) void {
    const win = self.window();
    const where = self.noticePlacement() orelse return;
    var strings: Texts = .{};
    self.texts(&strings);
    self.notice.show(win.app, where, .{
        .severity = .warning,
        .title = strings.title,
        .body = strings.body,
        .actions = &.{strings.button},
        .duration_ms = duration_ms,
    }, .{
        .ctx = self,
        .action = onAction,
        .closed = onClosed,
    });
    self.language = i18n.current();
}

/// Hide the notice.
pub fn hide(self: *ShortcutNotice) void {
    self.notice.hide();
}

/// The window's WM_TIMER dispatch asks here first; the notice's timers
/// are on its own popup window, so none of the window's are.
pub fn onTimer(self: *ShortcutNotice, timer_id: usize) bool {
    _ = self;
    _ = timer_id;
    return false;
}

/// Follow the window (moved, resized, another DPI or language).
pub fn reposition(self: *ShortcutNotice) void {
    if (!self.notice.isVisible() and !self.notice.pending) return;
    if (self.language) |language| if (language != i18n.current()) {
        self.showStored();
        return;
    };
    const where = self.noticePlacement() orelse return;
    self.notice.reposition(where);
}

/// The window's terminal area, above the window's own notice when it is
/// on screen (both sit at the bottom).
fn noticePlacement(self: *ShortcutNotice) ?Notice.Placement {
    const win = self.window();
    const hwnd = win.hwnd orelse return null;
    var area = win.surfaceRect();
    if (win.notice.isVisible()) if (win.notice.popup.hwnd) |other| {
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(other, &rect) != 0) {
            area.bottom -= (rect.bottom - rect.top) + style.px(stack_gap, win.scale);
        }
    };
    return .{ .owner = hwnd, .area = area, .scale = win.scale };
}

fn piece(self: *const ShortcutNotice, p: Piece) []const u8 {
    const i = @intFromEnum(p);
    const start = if (i == 0) 0 else self.ends[i - 1];
    return self.buf[start..self.ends[i]];
}

/// The translated texts, formatted into fixed buffers.
const Texts = struct {
    body_buf: [1024]u8 = undefined,
    button_buf: [128]u8 = undefined,
    title: []const u8 = "",
    body: []const u8 = "",
    button: []const u8 = "",
};

fn texts(self: *const ShortcutNotice, out: *Texts) void {
    out.title = i18n.tr("Some keyboard shortcuts do not reach Ghostty GX");
    var body: std.Io.Writer = .fixed(&out.body_buf);
    i18n.format(&body, i18n.tr("{keys}: another program or the input method takes these keys first."), .{
        .keys = self.piece(.keys),
    }) catch {};
    body.writeByte('\n') catch {};
    const copy = self.piece(.copy);
    const paste = self.piece(.paste);
    const palette = self.piece(.palette);
    if (copy.len > 0 and paste.len > 0 and palette.len > 0) {
        i18n.format(&body, i18n.tr("Copy with {copy} and paste with {paste}, or use the right-click menu or the command palette ({palette})."), .{
            .copy = copy,
            .paste = paste,
            .palette = palette,
        }) catch {};
    } else {
        body.writeAll(i18n.tr("Use the right-click menu or the command palette instead.")) catch {};
    }
    out.body = body.buffered();

    const sheet = self.piece(.sheet);
    if (sheet.len > 0) {
        var button: std.Io.Writer = .fixed(&out.button_buf);
        i18n.format(&button, i18n.tr("Keyboard Shortcuts ({keys})"), .{ .keys = sheet }) catch {};
        out.button = button.buffered();
    } else {
        out.button = i18n.tr("Keyboard Shortcuts");
    }
}

fn onAction(ctx: *anyopaque, notice: *Notice, index: usize) void {
    _ = notice;
    const self: *ShortcutNotice = @ptrCast(@alignCast(ctx));
    if (index != 0) return;
    if (!Keybinds.show(self.window())) log.warn("the keyboard shortcut sheet could not be opened", .{});
}

fn onClosed(ctx: *anyopaque, notice: *Notice, reason: Notice.CloseReason) void {
    _ = notice;
    _ = reason;
    const self: *ShortcutNotice = @ptrCast(@alignCast(ctx));
    self.language = null;
}
