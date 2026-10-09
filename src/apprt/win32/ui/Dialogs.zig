//! Modal dialogs of the win32 apprt: confirmations (closing a terminal,
//! tabs or a window with running processes, quitting, clipboard access,
//! unsafe paste), notices (child exited, About) and the native Save As
//! dialog.
//!
//! Every function blocks in a modal loop and returns the user's choice.
//! The modal loop keeps dispatching messages, so callers must not use
//! pointers that a dispatched message can free (a surface whose child
//! exits, for example) after the call; re-resolve them instead. To keep
//! the code that opened a dialog (often a core callback) on safe ground,
//! terminals and windows hold back their WM_CLOSE while a dialog is open
//! (`deferClose`); it is re-posted when the outermost dialog returns.
//!
//! The dialogs are drawn in the colors of the terminal theme on a `Popup`
//! owned by the window and centered on it: an icon and a title, the body
//! text, optionally the running processes, a preview of clipboard text,
//! links, and a row of buttons with the primary one in the accent color.
//! They are task modal: every other window of the app is disabled while a
//! dialog is open, and dialogs opened from inside a dialog nest. Enter
//! activates the focused button (initially the default button, which is
//! Cancel for anything destructive), Tab, Shift+Tab and the arrow keys
//! move the focus, Space activates it, Escape and Alt+F4 cancel and
//! Ctrl+C copies the text. Without Direct2D, or without a Ghostty window
//! as owner, the confirmations fall back to MessageBoxW.
//!
//! Text is translated with `gx.i18n` at call time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../../../gx/i18n.zig");
const branding = @import("../../../gx/branding.zig");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);

/// The answer to a confirmation.
pub const Choice = enum {
    /// The user approved (OK).
    accept,

    /// The user declined or dismissed the dialog.
    cancel,
};

/// Closing a single terminal whose process is still running. `processes`
/// names what runs in it (see `gx.confirm.appendBusyProcesses`); it can
/// be empty when that is unknown.
pub fn confirmCloseSurface(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Close Terminal?"),
        .body = i18n.tr("A process is still running in this terminal. Close it anyway?"),
        .list = processes,
        .buttons = &.{
            .{ .label = i18n.tr("Close"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// Closing a tab (all of its splits) whose process is still running.
pub fn confirmCloseTab(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Close Tab?"),
        .body = i18n.tr("A process is still running in this tab. Close it anyway?"),
        .list = processes,
        .buttons = &.{
            .{ .label = i18n.tr("Close"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// Closing several tabs (the other tabs, the tabs to the right) while a
/// process in one of them is running.
pub fn confirmCloseTabs(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Close Tabs?"),
        .body = i18n.tr("Processes are still running in the tabs to be closed. Close them anyway?"),
        .list = processes,
        .buttons = &.{
            .{ .label = i18n.tr("Close"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// Closing a whole window while a process in one of its tabs is running.
pub fn confirmCloseWindow(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Close Window?"),
        .body = i18n.tr("Processes are still running in this window. Close it anyway?"),
        .list = processes,
        .buttons = &.{
            .{ .label = i18n.tr("Close"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// Quitting while processes are still running.
pub fn confirmQuit(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Quit Ghostty GX?"),
        .body = i18n.tr("Processes are still running. Quit anyway?"),
        .list = processes,
        .buttons = &.{
            .{ .label = i18n.tr("Quit"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// What a program asks to do with the clipboard (OSC 52, Kitty).
pub const ClipboardAccess = enum { read, write };

/// A terminal program asks for clipboard access. `text` is what it would
/// read (the clipboard contents) or write.
pub fn confirmClipboardAccess(owner: ?w32.HWND, access: ClipboardAccess, text: []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Authorize Clipboard Access"),
        .icon = .shield,
        .body = switch (access) {
            .read => i18n.tr("A program in this terminal wants to read the clipboard. It would receive this text:"),
            .write => i18n.tr("A program in this terminal wants to copy this text to the clipboard:"),
        },
        .preview = text,
        .buttons = &.{
            .{ .label = i18n.tr("Allow"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Deny"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// The text being pasted can run commands (paste protection).
pub fn confirmUnsafePaste(owner: ?w32.HWND, text: []const u8) Choice {
    return run(owner, .{
        .title = i18n.tr("Warning: Potentially Unsafe Paste"),
        .body = i18n.tr("Pasting this text into the terminal may be dangerous as it looks like some commands may be executed."),
        .preview = text,
        .buttons = &.{
            .{ .label = i18n.tr("Paste Anyway"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// Tell the user that the shell process exited with a non-zero code.
pub fn showChildExited(owner: ?w32.HWND, exit_code: u32) void {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    i18n.format(&writer, i18n.tr("The shell process exited with code {code}."), .{
        .code = exit_code,
    }) catch {};
    _ = run(owner, .{
        .title = i18n.tr("Command Failed"),
        .body = writer.buffered(),
        .buttons = &.{
            .{ .label = i18n.tr("OK"), .choice = .accept, .primary = true },
        },
    });
}

/// The About dialog: product name, version, the notice that Ghostty GX
/// is an unofficial fork, and links.
pub fn showAbout(owner: ?w32.HWND, version: []const u8) void {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    i18n.format(&writer, i18n.tr("Version {version}"), .{ .version = version }) catch {};
    var detail_buf: [512]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{s}\n{s}", .{
        i18n.tr(branding.notice),
        i18n.tr(branding.license),
    }) catch i18n.tr(branding.notice);
    var copy_buf: [128]u8 = undefined;
    const copy_text = std.fmt.bufPrint(&copy_buf, "Ghostty GX {s}", .{version}) catch "Ghostty GX";
    _ = run(owner, .{
        .window_title = i18n.tr("About Ghostty GX"),
        .title = i18n.tr("Ghostty GX"),
        .icon = .info,
        .body = writer.buffered(),
        .detail = detail,
        .links = &.{
            .{ .label = i18n.tr("Project Home"), .url = branding.home_url },
            .{ .label = i18n.tr("Upstream Ghostty"), .url = branding.ghostty_url },
        },
        .copy_text = copy_text,
        .buttons = &.{
            .{ .label = i18n.tr("Copy Version"), .choice = .accept, .copies = true },
            .{ .label = i18n.tr("OK"), .choice = .accept, .primary = true },
        },
        .default_button = 1,
    });
}

/// A modal OK/Cancel warning that defaults to Cancel.
pub fn confirm(owner: ?w32.HWND, message: []const u8, title: []const u8) Choice {
    return run(owner, .{
        .title = title,
        .body = message,
        .buttons = &.{
            .{ .label = i18n.tr("OK"), .choice = .accept, .primary = true },
            .{ .label = i18n.tr("Cancel"), .choice = .cancel },
        },
        .default_button = 1,
    });
}

/// Hold back the WM_CLOSE of a terminal or window while a dialog is open.
/// Returns true when `hwnd`'s close was deferred: it is re-posted when
/// the outermost dialog returns. Window procedures call this first thing
/// in their WM_CLOSE handler.
pub fn deferClose(hwnd: w32.HWND) bool {
    if (depth == 0) return false;
    for (deferred[0..deferred_len]) |pending| {
        if (pending == hwnd) return true;
    }
    if (deferred_len == deferred.len) return false;
    deferred[deferred_len] = hwnd;
    deferred_len += 1;
    return true;
}

/// One file type of a Save As dialog.
pub const FileFilter = struct {
    label: []const u8,
    pattern: []const u8,
};

pub const SaveFileOptions = struct {
    title: []const u8,
    default_name: []const u8,
    default_ext: []const u8,
    filters: []const FileFilter,
};

/// Show a native Save As dialog. Returns the chosen path (UTF-8, owned by
/// the caller), or null when the user cancelled.
pub fn saveFilePath(
    alloc: Allocator,
    owner: ?w32.HWND,
    options: SaveFileOptions,
) !?[]u8 {
    var file_buf: [32768]u16 = std.mem.zeroes([32768]u16);
    _ = wstr.bufZ(&file_buf, options.default_name);

    // The common-dialog filter is a sequence of NUL-terminated label/pattern
    // pairs followed by an additional NUL.
    var filter_utf8: std.ArrayList(u8) = .empty;
    defer filter_utf8.deinit(alloc);
    for (options.filters) |filter| {
        try filter_utf8.appendSlice(alloc, filter.label);
        try filter_utf8.append(alloc, 0);
        try filter_utf8.appendSlice(alloc, filter.pattern);
        try filter_utf8.append(alloc, 0);
    }
    const filter = try wstr.allocZ(alloc, filter_utf8.items);
    defer alloc.free(filter);
    const title = try wstr.allocZ(alloc, options.title);
    defer alloc.free(title);
    const default_ext = try wstr.allocZ(alloc, options.default_ext);
    defer alloc.free(default_ext);

    var dialog: w32.OPENFILENAMEW = std.mem.zeroes(w32.OPENFILENAMEW);
    dialog.lStructSize = @sizeOf(w32.OPENFILENAMEW);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = filter.ptr;
    dialog.nFilterIndex = 1;
    dialog.lpstrFile = &file_buf;
    dialog.nMaxFile = file_buf.len;
    dialog.lpstrTitle = title.ptr;
    dialog.lpstrDefExt = default_ext.ptr;
    dialog.Flags = w32.OFN_EXPLORER |
        w32.OFN_NOCHANGEDIR |
        w32.OFN_PATHMUSTEXIST |
        w32.OFN_OVERWRITEPROMPT;

    if (w32.GetSaveFileNameW(&dialog) == 0) return null;

    const path_len = std.mem.indexOfScalar(u16, &file_buf, 0) orelse file_buf.len;
    return std.unicode.utf16LeToUtf8Alloc(alloc, file_buf[0..path_len]) catch |err| {
        log.warn("unable to decode the chosen file path: {}", .{err});
        return error.InvalidPath;
    };
}

// -----------------------------------------------------------------------
// Dialog model
// -----------------------------------------------------------------------

const Icon = enum { none, warning, info, shield };

const Button = struct {
    label: []const u8,
    /// What the dialog returns when the button is activated.
    choice: Choice,
    /// Drawn in the accent color: the action the dialog asks about.
    primary: bool = false,
    /// Copies `Spec.copy_text` and keeps the dialog open instead.
    copies: bool = false,
};

const Link = struct {
    label: []const u8,
    url: [:0]const u8,
};

const Spec = struct {
    /// The window title (for accessibility tools), `title` by default.
    window_title: ?[]const u8 = null,
    title: []const u8,
    icon: Icon = .warning,
    body: []const u8,
    /// A bulleted list after the body: the running processes.
    list: []const []const u8 = &.{},
    /// Text shown verbatim in a box after the body.
    preview: ?[]const u8 = null,
    /// Secondary text after the body.
    detail: []const u8 = "",
    links: []const Link = &.{},
    /// What a copying button and Ctrl+C copy; the dialog text if null.
    copy_text: ?[]const u8 = null,
    /// In visual order, at most `max_buttons`.
    buttons: []const Button,
    /// The button that has the focus at first, and so answers Enter.
    default_button: usize = 0,
};

const max_buttons = 3;
const max_links = 3;
const max_list_items = 6;
const max_preview_lines = 8;
/// Bytes kept per preview line; DirectWrite trims what does not fit.
const max_preview_line_len = 240;

/// Dialogs nested inside the modal loop of another dialog. A request past
/// this depth is answered with `.cancel` without showing anything, so a
/// program flooding the terminal with clipboard requests cannot pile up
/// modal loops.
const max_depth = 4;

/// The number of modal loops running (all on the GUI thread).
var depth: u32 = 0;

/// Windows whose WM_CLOSE arrived while a dialog was open.
var deferred: [32]w32.HWND = undefined;
var deferred_len: usize = 0;

// Metrics in DIPs.
const pad: f32 = 24;
const section_gap: f32 = 12;
const icon_size: f32 = 20;
const icon_gap: f32 = 12;
const button_height: f32 = 32;
const button_gap: f32 = 8;
const button_radius: f32 = 4;
const footer_height: f32 = button_height + 2 * pad;
const list_item_height: f32 = 22;
const preview_line_height: f32 = 18;
const preview_pad: f32 = 10;
const preview_font_size: f32 = 13;
const link_height: f32 = 22;
const link_gap: f32 = 24;
const width_plain: f32 = 440;
const width_preview: f32 = 520;

const Layout = struct {
    size: d2d.Size = .{ .width = width_plain, .height = 200 },
    icon: d2d.Rect = zero_rect,
    title: d2d.Rect = zero_rect,
    body: d2d.Rect = zero_rect,
    list: d2d.Rect = zero_rect,
    preview: d2d.Rect = zero_rect,
    detail: d2d.Rect = zero_rect,
    links: [max_links]d2d.Rect = .{zero_rect} ** max_links,
    footer: d2d.Rect = zero_rect,
    buttons: [max_buttons]d2d.Rect = .{zero_rect} ** max_buttons,
};

const zero_rect: d2d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// A focusable element: the links come first, then the buttons.
const Target = union(enum) {
    link: usize,
    button: usize,
};

const Dialog = struct {
    app: *App,
    owner: w32.HWND,
    spec: Spec,
    tokens: style.Tokens,
    popup: Popup = .{},
    layout: Layout = .{},

    /// Index into the focus order (links, then buttons).
    focus: usize = 0,
    hover: ?usize = null,
    pressed: ?usize = null,
    /// Set by a button (or Escape); ends the modal loop.
    result: ?Choice = null,
    copied: bool = false,

    /// The preview text split into display lines.
    preview_buf: [max_preview_lines * max_preview_line_len]u8 = undefined,
    preview_lines: [max_preview_lines][]const u8 = undefined,
    preview_line_count: usize = 0,
    /// Lines of the preview that are not shown.
    preview_more: usize = 0,

    fn focusCount(self: *const Dialog) usize {
        return self.spec.links.len + self.spec.buttons.len;
    }

    fn target(self: *const Dialog, index: usize) Target {
        if (index < self.spec.links.len) return .{ .link = index };
        return .{ .button = index - self.spec.links.len };
    }

    fn targetRect(self: *const Dialog, index: usize) d2d.Rect {
        return switch (self.target(index)) {
            .link => |i| self.layout.links[i],
            .button => |i| self.layout.buttons[i],
        };
    }

    fn hitTest(self: *const Dialog, pos: d2d.Point) ?usize {
        for (0..self.focusCount()) |i| {
            if (self.targetRect(i).contains(pos)) return i;
        }
        return null;
    }

    fn activate(self: *Dialog, index: usize) void {
        switch (self.target(index)) {
            .link => |i| openUrl(self.spec.links[i].url),
            .button => |i| {
                const button = self.spec.buttons[i];
                if (button.copies) {
                    var buf: [4096]u8 = undefined;
                    if (self.popup.hwnd) |hwnd| copyToClipboard(hwnd, self.copyText(&buf));
                    self.copied = true;
                    self.popup.invalidate();
                    return;
                }
                self.result = button.choice;
            },
        }
    }

    /// The text Ctrl+C and a copying button put on the clipboard.
    fn copyText(self: *const Dialog, buf: []u8) []const u8 {
        if (self.spec.copy_text) |text| return text;
        var writer: std.Io.Writer = .fixed(buf);
        writer.print("{s}\n\n{s}", .{ self.spec.title, self.spec.body }) catch {};
        for (self.spec.list) |item| writer.print("\n- {s}", .{item}) catch {};
        if (self.spec.preview) |text| writer.print("\n\n{s}", .{text}) catch {};
        if (self.spec.detail.len > 0) writer.print("\n\n{s}", .{self.spec.detail}) catch {};
        return writer.buffered();
    }

    fn moveFocus(self: *Dialog, forward: bool) void {
        const count = self.focusCount();
        if (count == 0) return;
        self.focus = if (forward) (self.focus + 1) % count else (self.focus + count - 1) % count;
        self.popup.invalidate();
    }

    /// Split the preview into at most `max_preview_lines` lines, showing
    /// tabs as spaces and other control characters as their Unicode
    /// control pictures (ESC as ␛), so escape sequences hidden in pasted
    /// text are visible.
    fn preparePreview(self: *Dialog) void {
        const text = self.spec.preview orelse return;
        var total_lines: usize = 1;
        for (text, 0..) |c, i| {
            if (c == '\n' and i + 1 < text.len) total_lines += 1;
        }

        var used: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (self.preview_line_count == max_preview_lines) break;
            // Keep the last line when it is the only one left, instead of
            // saying "1 more line".
            if (self.preview_line_count == max_preview_lines - 1 and
                total_lines > max_preview_lines) break;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const out = self.preview_buf[used..][0..max_preview_line_len];
            const len = sanitizeLine(line, out);
            self.preview_lines[self.preview_line_count] = out[0..len];
            self.preview_line_count += 1;
            used += max_preview_line_len;
        }
        // A trailing line break does not start a line of its own.
        if (self.preview_line_count > 1 and text.len > 0 and text[text.len - 1] == '\n' and
            self.preview_lines[self.preview_line_count - 1].len == 0)
        {
            self.preview_line_count -= 1;
        }
        self.preview_more = total_lines -| self.preview_line_count;
    }

    fn computeLayout(self: *Dialog, factory: *d2d.Factory) void {
        const spec = self.spec;
        const t = self.tokens;
        const width: f32 = if (spec.preview != null) width_preview else width_plain;
        const content_w = width - 2 * pad;
        var layout: Layout = .{};
        var y: f32 = pad;

        // Icon and title.
        const icon_w: f32 = if (spec.icon == .none) 0 else icon_size + icon_gap;
        const title_style = titleStyle(t);
        var line_style = title_style;
        line_style.wrap = false;
        const title_line_h = factory.measureText("Ag", line_style, content_w).height;
        const title_h = factory.measureText(spec.title, title_style, content_w - icon_w).height;
        if (spec.icon != .none) layout.icon = .{
            .x = pad,
            .y = y + @max(0, (title_line_h - icon_size) / 2),
            .w = icon_size,
            .h = icon_size,
        };
        layout.title = .{ .x = pad + icon_w, .y = y, .w = content_w - icon_w, .h = @max(title_h, title_line_h) };
        y += layout.title.h + section_gap;

        // Body.
        const body_h = factory.measureText(spec.body, bodyStyle(t), content_w).height;
        layout.body = .{ .x = pad, .y = y, .w = content_w, .h = body_h };
        y += body_h;

        // Running processes.
        if (spec.list.len > 0) {
            y += section_gap;
            const label_h = factory.measureText(i18n.tr("Running processes:"), secondaryStyle(t), content_w).height;
            const shown = @min(spec.list.len, max_list_items);
            const rows: f32 = @floatFromInt(shown + @intFromBool(spec.list.len > shown));
            layout.list = .{ .x = pad, .y = y, .w = content_w, .h = label_h + 4 + rows * list_item_height };
            y += layout.list.h;
        }

        // Preview.
        if (spec.preview != null) {
            y += section_gap;
            const rows: f32 = @floatFromInt(@max(1, self.preview_line_count) + @intFromBool(self.preview_more > 0));
            layout.preview = .{ .x = pad, .y = y, .w = content_w, .h = rows * preview_line_height + 2 * preview_pad };
            y += layout.preview.h;
        }

        // Detail.
        if (spec.detail.len > 0) {
            y += section_gap;
            const detail_h = factory.measureText(spec.detail, secondaryStyle(t), content_w).height;
            layout.detail = .{ .x = pad, .y = y, .w = content_w, .h = detail_h };
            y += detail_h;
        }

        // Links, side by side.
        if (spec.links.len > 0) {
            y += section_gap;
            var x: f32 = pad;
            for (spec.links[0..@min(spec.links.len, max_links)], 0..) |link, i| {
                const w = factory.measureText(link.label, linkStyle(t), content_w).width;
                layout.links[i] = .{ .x = x, .y = y, .w = w, .h = link_height };
                x += w + link_gap;
            }
            y += link_height;
        }

        // Footer with the buttons sharing its width, like a WinUI
        // ContentDialog; a single button takes the right half.
        y += pad;
        layout.footer = .{ .x = 0, .y = y, .w = width, .h = footer_height };
        const count = @min(spec.buttons.len, max_buttons);
        const columns: f32 = @floatFromInt(@max(count, 2));
        const button_w = (content_w - (columns - 1) * button_gap) / columns;
        const first_column = @max(count, 2) - count;
        for (0..count) |i| {
            const column: f32 = @floatFromInt(first_column + i);
            layout.buttons[i] = .{
                .x = pad + column * (button_w + button_gap),
                .y = y + pad,
                .w = button_w,
                .h = button_height,
            };
        }
        layout.size = .{ .width = width, .height = y + footer_height };
        self.layout = layout;
    }

    /// The popup's screen rectangle: centered on the owner window (or on
    /// its monitor when the owner is minimized), inside the work area.
    fn screenRect(self: *const Dialog) w32.RECT {
        const scale = self.popup.ownerScale();
        const w = style.px(self.layout.size.width, scale);
        const h = style.px(self.layout.size.height, scale);

        var work: w32.RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
        var mi: w32.MONITORINFO = .{
            .cbSize = @sizeOf(w32.MONITORINFO),
            .rcMonitor = undefined,
            .rcWork = undefined,
            .dwFlags = 0,
        };
        if (w32.GetMonitorInfoW(w32.MonitorFromWindow(self.owner, w32.MONITOR_DEFAULTTONEAREST), &mi) != 0) {
            work = mi.rcWork;
        }

        var anchor = work;
        if (w32.IsIconic(self.owner) == 0 and w32.IsWindowVisible_(self.owner) != 0) {
            var rect: w32.RECT = undefined;
            if (w32.GetWindowRect(self.owner, &rect) != 0) anchor = rect;
        }
        var x = anchor.left + @divTrunc(anchor.right - anchor.left - w, 2);
        var y = anchor.top + @divTrunc(anchor.bottom - anchor.top - h, 2);
        x = @max(work.left, @min(x, work.right - w));
        y = @max(work.top, @min(y, work.bottom - h));
        return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    }

    fn paint(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const l = &self.layout;
        const full: d2d.Rect = .{ .x = 0, .y = 0, .w = l.size.width, .h = l.size.height };
        canvas.fillRect(full, t.surface_raised);

        if (iconGlyph(self.spec.icon, t)) |icon| canvas.drawIcon(icon.glyph, l.icon, icon_size, icon.color);
        canvas.drawText(self.spec.title, l.title, titleStyle(t));
        canvas.drawText(self.spec.body, l.body, bodyStyle(t));

        if (self.spec.list.len > 0) self.paintList(canvas);
        if (self.spec.preview != null) self.paintPreview(canvas);
        if (self.spec.detail.len > 0) canvas.drawText(self.spec.detail, l.detail, secondaryStyle(t));

        for (self.spec.links[0..@min(self.spec.links.len, max_links)], 0..) |link, i| {
            const active = self.hover == i or self.focus == i;
            canvas.drawText(link.label, l.links[i], linkStyle(t));
            if (active) {
                const r = l.links[i];
                canvas.fillRect(.{ .x = r.x, .y = r.y + r.h - 3, .w = r.w, .h = 1 }, t.accent);
            }
            if (self.focus == i) focusRing(canvas, l.links[i].inset(-4, -1), 2, t);
        }

        // Footer band and buttons.
        canvas.fillRect(l.footer, t.surface);
        canvas.fillRect(.{ .x = 0, .y = l.footer.y, .w = l.footer.w, .h = 1 }, t.border);
        for (self.spec.buttons[0..@min(self.spec.buttons.len, max_buttons)], 0..) |button, i| {
            const index = self.spec.links.len + i;
            self.paintButton(canvas, button, l.buttons[i], index);
        }
    }

    fn paintList(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const r = self.layout.list;
        const label = i18n.tr("Running processes:");
        const label_h = canvas.measureText(label, secondaryStyle(t), r.w).height;
        canvas.drawText(label, .{ .x = r.x, .y = r.y, .w = r.w, .h = label_h }, secondaryStyle(t));

        var y = r.y + label_h + 4;
        const shown = @min(self.spec.list.len, max_list_items);
        var item_style = bodyStyle(t);
        item_style.wrap = false;
        item_style.ellipsis = true;
        item_style.align_y = .center;
        item_style.font = .mono;
        for (self.spec.list[0..shown]) |name| {
            canvas.fillRoundedRect(.{ .x = r.x + 4, .y = y + list_item_height / 2 - 2, .w = 4, .h = 4 }, 2, t.text_secondary);
            canvas.drawText(name, .{ .x = r.x + 16, .y = y, .w = r.w - 16, .h = list_item_height }, item_style);
            y += list_item_height;
        }
        if (self.spec.list.len > shown) {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            i18n.format(&writer, i18n.tr("…and {count} more"), .{ .count = self.spec.list.len - shown }) catch {};
            var more_style = secondaryStyle(t);
            more_style.align_y = .center;
            canvas.drawText(writer.buffered(), .{ .x = r.x + 16, .y = y, .w = r.w - 16, .h = list_item_height }, more_style);
        }
    }

    fn paintPreview(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const r = self.layout.preview;
        canvas.fillRoundedRect(r, button_radius, t.background);
        canvas.strokeRoundedRect(r, button_radius, t.border, 1);

        const text_style: d2d.TextStyle = .{
            .font = .mono,
            .size = preview_font_size,
            .color = t.foreground,
            .align_y = .center,
            .ellipsis = true,
        };
        var y = r.y + preview_pad;
        const x = r.x + preview_pad;
        const w = r.w - 2 * preview_pad;
        if (self.preview_line_count == 0 or self.spec.preview.?.len == 0) {
            var empty_style = text_style;
            empty_style.font = .ui;
            empty_style.color = t.text_secondary;
            canvas.drawText(i18n.tr("The clipboard is empty."), .{ .x = x, .y = y, .w = w, .h = preview_line_height }, empty_style);
            return;
        }
        for (self.preview_lines[0..self.preview_line_count]) |line| {
            canvas.drawText(line, .{ .x = x, .y = y, .w = w, .h = preview_line_height }, text_style);
            y += preview_line_height;
        }
        if (self.preview_more > 0) {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            i18n.format(&writer, i18n.tr("… {count} more lines"), .{ .count = self.preview_more }) catch {};
            var more_style = text_style;
            more_style.font = .ui;
            more_style.color = t.text_secondary;
            canvas.drawText(writer.buffered(), .{ .x = x, .y = y, .w = w, .h = preview_line_height }, more_style);
        }
    }

    fn paintButton(self: *Dialog, canvas: *d2d.Canvas, button: Button, rect: d2d.Rect, index: usize) void {
        const t = self.tokens;
        const hovered = self.hover == index;
        const pressed = hovered and self.pressed == index;
        var fill = style.mix(t.surface_raised, t.foreground, 0.05);
        var text_color = t.text;
        if (button.primary) {
            fill = if (pressed)
                style.mix(t.accent, t.on_accent, 0.2)
            else if (hovered)
                style.mix(t.accent, t.on_accent, 0.1)
            else
                t.accent;
            text_color = t.on_accent;
        } else if (pressed) {
            fill = t.pressed;
        } else if (hovered) {
            fill = t.hover;
        }
        canvas.fillRoundedRect(rect, button_radius, fill);
        if (!button.primary) canvas.strokeRoundedRect(rect, button_radius, t.border, 1);

        const label = if (button.copies and self.copied) i18n.tr("Copied to clipboard") else button.label;
        canvas.drawText(label, rect.inset(8, 0), .{
            .size = style.font_size.body,
            .color = text_color,
            .align_x = .center,
            .align_y = .center,
        });
        if (self.focus == index) focusRing(canvas, rect, button_radius, t);
    }
};

fn titleStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.subtitle,
        .weight = .semibold,
        .color = t.text,
        .align_y = .top,
        .wrap = true,
        .ellipsis = false,
    };
}

fn bodyStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.body,
        .color = t.text,
        .align_y = .top,
        .wrap = true,
        .ellipsis = false,
    };
}

fn secondaryStyle(t: style.Tokens) d2d.TextStyle {
    var s = bodyStyle(t);
    s.color = t.text_secondary;
    return s;
}

fn linkStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.body,
        .color = t.accent,
        .align_y = .center,
        .ellipsis = false,
    };
}

const IconGlyph = struct { glyph: u21, color: d2d.Color };

/// The Segoe Fluent Icons glyph of a dialog icon and its color.
fn iconGlyph(icon: Icon, t: style.Tokens) ?IconGlyph {
    return switch (icon) {
        .none => null,
        // Warning, and the Windows 11 caution color.
        .warning => .{
            .glyph = 0xE7BA,
            .color = if (t.dark) d2d.Color.hex(0xFCE100) else d2d.Color.hex(0x9D5D00),
        },
        // Info.
        .info => .{ .glyph = 0xE946, .color = t.accent },
        // Shield.
        .shield => .{ .glyph = 0xEA18, .color = t.accent },
    };
}

/// The keyboard focus visual: a 2 DIP ring just outside `rect`.
fn focusRing(canvas: *d2d.Canvas, rect: d2d.Rect, radius: f32, t: style.Tokens) void {
    canvas.strokeRoundedRect(rect.inset(-3, -3), radius + 3, t.text, 2);
}

/// Copy `line` into `out` for display: tabs become spaces and other
/// control characters their Unicode control pictures. Returns the length
/// written; text that does not fit is cut at a codepoint boundary.
fn sanitizeLine(line: []const u8, out: []u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        // Invalid UTF-8 shows as U+FFFD, one byte at a time.
        var cp: u21 = 0xFFFD;
        var advance: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(line[i])) |seq_len| {
            if (i + seq_len <= line.len) {
                if (std.unicode.utf8Decode(line[i..][0..seq_len])) |decoded| {
                    cp = decoded;
                    advance = seq_len;
                } else |_| {}
            }
        } else |_| {}
        i += advance;

        var buf: [8]u8 = undefined;
        const piece: []const u8 = switch (cp) {
            '\t' => "    ",
            0x00...0x08, 0x0A...0x1F => buf[0 .. std.unicode.utf8Encode(0x2400 + cp, &buf) catch 0],
            0x7F => "\u{2421}",
            else => buf[0 .. std.unicode.utf8Encode(cp, &buf) catch 0],
        };
        if (len + piece.len > out.len) break;
        @memcpy(out[len..][0..piece.len], piece);
        len += piece.len;
    }
    return len;
}

// -----------------------------------------------------------------------
// Modal loop
// -----------------------------------------------------------------------

/// The app behind a Ghostty window handle, if `hwnd` is one.
fn appOf(hwnd: w32.HWND) ?*App {
    const proc: usize = @bitCast(w32.GetWindowLongPtrW(hwnd, w32.GWLP_WNDPROC));
    if (proc != @intFromPtr(&Window.windowWndProc)) return null;
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return null;
    const window: *Window = @ptrFromInt(@as(usize, @bitCast(userdata)));
    return window.app;
}

fn run(owner_: ?w32.HWND, spec: Spec) Choice {
    if (depth >= max_depth) {
        log.warn("too many nested dialogs, declining title={s}", .{spec.title});
        return .cancel;
    }
    const owner = owner_ orelse return fallback(null, spec);
    const app = appOf(owner) orelse return fallback(owner, spec);
    const factory = app.uiFactory() orelse return fallback(owner, spec);

    var dialog: Dialog = .{
        .app = app,
        .owner = owner,
        .spec = spec,
        .tokens = style.Tokens.fromConfig(&app.config),
    };
    dialog.focus = spec.links.len + @min(spec.default_button, spec.buttons.len -| 1);
    dialog.preparePreview();
    dialog.computeLayout(factory);

    dialog.popup.create(app.hinstance, owner, factory, .{
        .activate = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .corners = .round,
        .shadow = true,
        .border_color = dialog.tokens.border,
        .dark = dialog.tokens.dark,
    }, .{
        .ctx = &dialog,
        .paint = onPaint,
        .key = onKey,
        .mouse = onMouse,
        .dpi_changed = onDpiChanged,
    }) catch |err| {
        log.warn("failed to create a dialog window err={}", .{err});
        return fallback(owner, spec);
    };
    const hwnd = dialog.popup.hwnd.?;
    var title_buf: [256]u16 = undefined;
    _ = w32.SetWindowTextW(hwnd, wstr.bufZ(&title_buf, spec.window_title orelse spec.title));

    depth += 1;
    var disabled: DisabledWindows = .{ .except = hwnd };
    disabled.disableAll();

    dialog.popup.show(dialog.screenRect());
    if (w32.GetForegroundWindow() != hwnd) flash(owner);
    const quit_code = modalLoop(&dialog);

    // Re-enable the other windows before the dialog goes away, so that
    // activation returns to the owner instead of another application.
    disabled.restore();
    if (w32.IsWindow(owner) != 0 and w32.GetActiveWindow() == hwnd) _ = w32.SetActiveWindow(owner);
    dialog.popup.destroy();

    depth -= 1;
    if (depth == 0) replayDeferred();
    if (quit_code) |code| w32.PostQuitMessage(code);
    return dialog.result orelse .cancel;
}

/// Pump messages until the dialog has a result, its window is gone (its
/// owner was destroyed) or WM_QUIT arrives. Returns the WM_QUIT exit code,
/// which the caller posts again once the dialog is closed.
fn modalLoop(dialog: *Dialog) ?i32 {
    while (dialog.result == null) {
        const hwnd = dialog.popup.hwnd orelse return null;
        if (w32.IsWindow(hwnd) == 0) return null;
        var msg: w32.MSG = undefined;
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            if (msg.message == w32.WM_QUIT) {
                return @bitCast(@as(u32, @truncate(msg.wParam)));
            }
            // The dialog handles Alt+F4 itself; translating system keys
            // would only produce WM_SYSCHAR menu beeps.
            const system_key = msg.message == w32.WM_SYSKEYDOWN or msg.message == w32.WM_SYSKEYUP;
            if (!(system_key and msg.hwnd == hwnd)) _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
            if (dialog.result != null) return null;
        }
        // Wake up regularly so a dialog destroyed with its owner is noticed
        // even when no message arrives.
        _ = w32.MsgWaitForMultipleObjectsEx(0, null, 250, w32.QS_ALLINPUT, w32.MWMO_INPUTAVAILABLE);
    }
    return null;
}

fn replayDeferred() void {
    const pending = deferred[0..deferred_len];
    deferred_len = 0;
    for (pending) |hwnd| {
        if (w32.IsWindow(hwnd) != 0) _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    }
}

/// The windows of the GUI thread that a dialog disables, as MessageBox
/// does with MB_TASKMODAL, so that no other window takes input (keys typed
/// into a terminal would otherwise skip the app's own message loop).
const DisabledWindows = struct {
    except: w32.HWND,
    list: [64]w32.HWND = undefined,
    len: usize = 0,

    fn disableAll(self: *DisabledWindows) void {
        _ = w32.EnumThreadWindows(w32.GetCurrentThreadId(), &disableOne, @bitCast(@intFromPtr(self)));
    }

    fn disableOne(hwnd: w32.HWND, lparam: isize) callconv(.winapi) i32 {
        const self: *DisabledWindows = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (hwnd == self.except) return 1;
        if (w32.IsWindowVisible_(hwnd) == 0 or w32.IsWindowEnabled(hwnd) == 0) return 1;
        if (self.len == self.list.len) return 0;
        _ = w32.EnableWindow(hwnd, 0);
        self.list[self.len] = hwnd;
        self.len += 1;
        return 1;
    }

    fn restore(self: *DisabledWindows) void {
        for (self.list[0..self.len]) |hwnd| {
            if (w32.IsWindow(hwnd) != 0) _ = w32.EnableWindow(hwnd, 1);
        }
        self.len = 0;
    }
};

/// Flash the owner's taskbar button when the dialog could not come to the
/// foreground (another application is active).
fn flash(owner: w32.HWND) void {
    var info: w32.FLASHWINFO = .{
        .cbSize = @sizeOf(w32.FLASHWINFO),
        .hwnd = owner,
        .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
        .uCount = 3,
        .dwTimeout = 0,
    };
    _ = w32.FlashWindowEx(&info);
}

fn dialogOf(ctx: *anyopaque) *Dialog {
    return @ptrCast(@alignCast(ctx));
}

fn onPaint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    _ = popup;
    dialogOf(ctx).paint(canvas);
}

fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
    _ = popup;
    const self = dialogOf(ctx);
    switch (key.vk) {
        w32.VK_ESCAPE => self.result = .cancel,
        w32.VK_F4 => if (key.alt) {
            self.result = .cancel;
        },
        w32.VK_RETURN, w32.VK_SPACE => if (self.focusCount() > 0) self.activate(self.focus),
        w32.VK_TAB => self.moveFocus(!key.shift),
        w32.VK_LEFT, w32.VK_UP => self.moveFocus(false),
        w32.VK_RIGHT, w32.VK_DOWN => self.moveFocus(true),
        'C' => if (key.ctrl) {
            var buf: [4096]u8 = undefined;
            if (self.popup.hwnd) |hwnd| copyToClipboard(hwnd, self.copyText(&buf));
        },
        else => {},
    }
    // Every key belongs to the dialog; nothing reaches DefWindowProc (which
    // would turn Alt combinations into menu beeps).
    return true;
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    _ = popup;
    const self = dialogOf(ctx);
    switch (event.kind) {
        .move => {
            const hit = self.hitTest(event.pos);
            if (hit != self.hover) {
                self.hover = hit;
                self.popup.invalidate();
            }
        },
        .leave => {
            self.hover = null;
            self.pressed = null;
            self.popup.invalidate();
        },
        .down => if (event.button == .left) {
            self.pressed = self.hitTest(event.pos);
            if (self.pressed) |index| self.focus = index;
            self.popup.invalidate();
        },
        .up => if (event.button == .left) {
            const pressed = self.pressed;
            self.pressed = null;
            self.popup.invalidate();
            if (pressed != null and pressed == self.hitTest(event.pos)) self.activate(pressed.?);
        },
        .double_click, .wheel => {},
    }
}

fn onDpiChanged(ctx: *anyopaque, popup: *Popup) void {
    const self = dialogOf(ctx);
    const scale = popup.scale();
    var rect: w32.RECT = undefined;
    const hwnd = popup.hwnd orelse return;
    if (w32.GetWindowRect(hwnd, &rect) == 0) return;
    const w = style.px(self.layout.size.width, scale);
    const h = style.px(self.layout.size.height, scale);
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    popup.setBounds(.{
        .left = cx - @divTrunc(w, 2),
        .top = cy - @divTrunc(h, 2),
        .right = cx - @divTrunc(w, 2) + w,
        .bottom = cy - @divTrunc(h, 2) + h,
    });
}

fn openUrl(url: [:0]const u8) void {
    var buf: [512]u16 = undefined;
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        wstr.bufZ(&buf, url),
        null,
        null,
        w32.SW_SHOW,
    );
}

fn copyToClipboard(hwnd: w32.HWND, text: []const u8) void {
    const units = wstr.utf16Len(text) + 1;
    const handle = w32.GlobalAlloc(w32.GMEM_MOVEABLE, units * @sizeOf(u16)) orelse return;
    const ptr = w32.GlobalLock(handle) orelse {
        _ = w32.GlobalFree(handle);
        return;
    };
    const dst: [*]u16 = @ptrCast(@alignCast(ptr));
    _ = wstr.bufZ(dst[0..units], text);
    _ = w32.GlobalUnlock(handle);
    if (w32.OpenClipboard(hwnd) == 0) {
        _ = w32.GlobalFree(handle);
        return;
    }
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, handle) == null) _ = w32.GlobalFree(handle);
}

/// A MessageBoxW stand-in for `spec` when the custom dialog cannot be
/// shown: the first button maps to OK, any other to Cancel.
fn fallback(owner: ?w32.HWND, spec: Spec) Choice {
    var text_buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text_buf);
    writer.writeAll(spec.body) catch {};
    for (spec.list) |item| writer.print("\n- {s}", .{item}) catch {};
    if (spec.preview) |preview| {
        writer.writeAll("\n\n") catch {};
        writer.writeAll(preview[0..@min(preview.len, 512)]) catch {};
    }
    if (spec.detail.len > 0) writer.print("\n\n{s}", .{spec.detail}) catch {};

    const two_buttons = spec.buttons.len > 1 and spec.buttons[1].choice == .cancel;
    var flags: u32 = if (spec.icon == .info) w32.MB_ICONINFORMATION else w32.MB_ICONWARNING;
    if (two_buttons) {
        flags |= w32.MB_OKCANCEL;
        if (spec.default_button == 1) flags |= w32.MB_DEFBUTTON2;
    }

    var message_buf: [2048]u16 = undefined;
    var title_buf: [256]u16 = undefined;
    const result = w32.MessageBoxW(
        owner,
        wstr.bufZ(&message_buf, writer.buffered()),
        wstr.bufZ(&title_buf, spec.window_title orelse spec.title),
        flags,
    );
    if (!two_buttons) return .accept;
    return if (result == w32.IDOK) spec.buttons[0].choice else .cancel;
}

test "sanitizeLine shows control characters" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const len = sanitizeLine("a\tb\x1b[201~\x7f", &buf);
    try testing.expectEqualStrings("a    b\u{241B}[201~\u{2421}", buf[0..len]);
}

test "sanitizeLine cuts at a codepoint boundary" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    const len = sanitizeLine("ab\u{4E2D}", &buf);
    try testing.expectEqualStrings("ab", buf[0..len]);
}
