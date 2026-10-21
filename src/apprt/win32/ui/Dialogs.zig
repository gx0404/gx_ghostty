//! Modal dialogs of the win32 apprt: confirmations (closing a terminal,
//! tabs or a window with running processes, quitting, clipboard access,
//! unsafe paste), notices (child exited, About) and the native Save As
//! dialog.
//!
//! Every function blocks in a modal loop and returns the user's choice.
//! The modal loop keeps dispatching messages, so callers must not use
//! pointers that a dispatched message can free (a surface whose child
//! exits, for example) after the call; re-resolve them instead. Core
//! callbacks must post their request to the message loop before calling
//! this module. Terminals and windows hold back their WM_CLOSE while a
//! dialog is open (`deferClose`); it is re-posted when the outermost
//! dialog returns.
//!
//! The dialogs are drawn in the colors of the terminal theme on a `Popup`
//! owned by the window, centered on it and laid out at its content scale
//! (`Window.scale`): an icon and a title, the body text, optionally the
//! running processes (by tab), a preview of clipboard text
//! (`previewLines`: line ends, control and invisible characters made
//! visible), links, a check box, and a row of `controls` buttons with the
//! default one in the accent color. They are task modal: every other
//! window of the app is disabled while a dialog is open, and dialogs
//! opened from inside a dialog nest. Enter activates the focused button
//! (initially the default button, which is Cancel for anything
//! destructive), Tab, Shift+Tab and the arrow keys move the focus and show
//! the focus ring, Space activates it, Escape and Alt+F4 cancel and Ctrl+C
//! copies the text. A close sent to the dialog from outside (WM_CLOSE, the
//! system close) cancels too and gives the activation back to the window.
//!
//! Without Direct2D, without a Ghostty window as owner, or while a screen
//! reader runs (`SPI_GETSCREENREADER`, or `GHOSTTY_GX_A11Y=screen-reader`),
//! the dialogs are native task dialogs (`TaskDialogIndirect`), and message
//! boxes where those are missing; their text is prepared the same way.
//!
//! Text is translated with `gx.i18n` at call time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("../../../gx/i18n.zig");
const branding = @import("../../../gx/branding.zig");
const policy = @import("../../../gx/policy.zig");
const ui_color = @import("../../../gx/ui_color.zig");
const unicode = @import("../../../unicode/main.zig");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const clipboard = @import("../clipboard.zig");
const open_url = @import("../open_url.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const uia = @import("uia.zig");
const uia_bridge = @import("uia_bridge.zig");
const controls = @import("controls.zig");
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

/// The processes of one tab, for the confirmations that list them by tab.
pub const ProcessGroup = struct {
    /// The tab's title.
    title: []const u8,
    /// What runs in it (see `gx.confirm.appendBusyProcesses`).
    processes: []const []const u8,
};

/// Closing a single terminal whose process is still running. `processes`
/// names what runs in it (see `gx.confirm.appendBusyProcesses`); it can
/// be empty when that is unknown.
pub fn confirmCloseSurface(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return confirmClose(owner, .surface, processes, &.{});
}

/// Closing a tab (all of its splits) whose process is still running.
pub fn confirmCloseTab(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return confirmClose(owner, .tab, processes, &.{});
}

/// `confirmCloseTab` listing the processes under the tab title.
pub fn confirmCloseTabWithTitle(owner: ?w32.HWND, group: ProcessGroup) Choice {
    return confirmClose(owner, .tab, &.{}, &.{group});
}

/// Closing several tabs (the other tabs, the tabs to the right) while a
/// process in one of them is running.
pub fn confirmCloseTabs(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return confirmClose(owner, .tabs, processes, &.{});
}

/// `confirmCloseTabs` listing the processes under the title of their tab.
pub fn confirmCloseTabsByTab(owner: ?w32.HWND, groups: []const ProcessGroup) Choice {
    return confirmClose(owner, .tabs, &.{}, groups);
}

/// Closing a whole window while a process in one of its tabs is running.
pub fn confirmCloseWindow(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return confirmClose(owner, .window, processes, &.{});
}

/// `confirmCloseWindow` listing the processes under the title of their
/// tab.
pub fn confirmCloseWindowByTab(owner: ?w32.HWND, groups: []const ProcessGroup) Choice {
    return confirmClose(owner, .window, &.{}, groups);
}

/// Quitting while processes are still running.
pub fn confirmQuit(owner: ?w32.HWND, processes: []const []const u8) Choice {
    return confirmClose(owner, .quit, processes, &.{});
}

/// `confirmQuit` listing the processes under the title of their tab.
pub fn confirmQuitByTab(owner: ?w32.HWND, groups: []const ProcessGroup) Choice {
    return confirmClose(owner, .quit, &.{}, groups);
}

const CloseKind = enum { surface, tab, tabs, window, quit };

/// A confirmation that says what closing ends and lists the processes,
/// with Cancel as the default.
fn confirmClose(
    owner: ?w32.HWND,
    kind: CloseKind,
    processes: []const []const u8,
    groups: []const ProcessGroup,
) Choice {
    const buttons = [_]Button{
        .{ .label = if (kind == .quit) i18n.tr("Quit") else i18n.tr("Close"), .choice = .accept },
        .{ .label = i18n.tr("Cancel"), .choice = .cancel },
    };
    return run(owner, .{
        .title = switch (kind) {
            .surface => i18n.tr("Close Terminal?"),
            .tab => i18n.tr("Close Tab?"),
            .tabs => i18n.tr("Close Tabs?"),
            .window => i18n.tr("Close Window?"),
            .quit => i18n.tr("Quit Ghostty GX?"),
        },
        .body = switch (kind) {
            .surface => i18n.tr("Closing this terminal will end the processes running in it."),
            .tab => i18n.tr("Closing this tab will end the processes running in it."),
            .tabs => i18n.tr("Closing these tabs will end the processes running in them."),
            .window => i18n.tr("Closing this window will end the processes running in its tabs."),
            .quit => i18n.tr("Quitting will end the processes running in all windows."),
        },
        .list = processes,
        .groups = groups,
        .buttons = &buttons,
        .default_button = 1,
    }).choice;
}

/// What a program asks to do with the clipboard (OSC 52, Kitty).
pub const ClipboardAccess = enum { read, write };

/// The answer to `askClipboardAccess`.
pub const ClipboardAnswer = struct {
    choice: Choice,
    /// The user asked to keep this answer for the terminal (only when the
    /// dialog offered it, and only for an answer given with a button).
    remember: bool = false,
};

/// A terminal program asks for clipboard access. `text` is what it would
/// read (the clipboard contents) or write.
pub fn confirmClipboardAccess(owner: ?w32.HWND, access: ClipboardAccess, text: []const u8) Choice {
    return askClipboardAccess(owner, access, text, false).choice;
}

/// `confirmClipboardAccess` that, with `can_remember` (OSC 52 requests,
/// as the GTK app does), offers "Remember choice for this split". On
/// `remember` the caller retains this terminal's access decision until
/// its configuration is reloaded.
pub fn askClipboardAccess(owner: ?w32.HWND, access: ClipboardAccess, text: []const u8, can_remember: bool) ClipboardAnswer {
    const buttons = [_]Button{
        .{ .label = i18n.tr("Allow"), .choice = .accept },
        .{ .label = i18n.tr("Deny"), .choice = .cancel },
    };
    const answer = run(owner, .{
        .title = i18n.tr("Authorize Clipboard Access"),
        .icon = .shield,
        .body = switch (access) {
            .read => i18n.tr("A program in this terminal wants to read the clipboard. It would receive this text:"),
            .write => i18n.tr("A program in this terminal wants to copy this text to the clipboard:"),
        },
        .preview = .{
            .text = text,
            .kind = switch (access) {
                .read => .read,
                .write => .write,
            },
        },
        .check = if (can_remember) i18n.tr("Remember choice for this split") else null,
        .buttons = &buttons,
        .default_button = 1,
    });
    return clipboardAnswer(answer, can_remember);
}

fn clipboardAnswer(answer: Answer, can_remember: bool) ClipboardAnswer {
    return .{ .choice = answer.choice, .remember = can_remember and answer.checked and answer.explicit };
}

/// The text being pasted can run commands (paste protection).
pub fn confirmUnsafePaste(owner: ?w32.HWND, text: []const u8) Choice {
    const buttons = [_]Button{
        .{ .label = i18n.tr("Paste Anyway"), .choice = .accept },
        .{ .label = i18n.tr("Cancel"), .choice = .cancel },
    };
    return run(owner, .{
        .title = i18n.tr("Warning: Potentially Unsafe Paste"),
        .body = i18n.tr("Pasting this text into the terminal may be dangerous as it looks like some commands may be executed."),
        .preview = .{ .text = text, .kind = .paste },
        .buttons = &buttons,
        .default_button = 1,
    }).choice;
}

/// Cross-integrity drops always require an explicit preview. This does not
/// replace the terminal's protected-paste check and never remembers approval.
pub fn confirmBrokerDrop(owner: ?w32.HWND, text: []const u8, source_pid: u32, file_count: usize) Choice {
    var buffer: [1024]u8 = undefined;
    var body: std.Io.Writer = .fixed(&buffer);
    body.writeAll(i18n.tr("A lower-privilege window wants to paste this content into an elevated terminal. Review it before allowing the paste.")) catch {};
    body.writeAll("\n\n") catch {};
    i18n.format(&body, i18n.tr("Source process: {pid}"), .{ .pid = source_pid }) catch {};
    if (file_count != 0) {
        body.writeAll("\n") catch {};
        i18n.format(&body, i18n.tr("Dropped files: {count}"), .{ .count = file_count }) catch {};
    }
    const buttons = [_]Button{
        .{ .label = i18n.tr("Allow Paste"), .choice = .accept },
        .{ .label = i18n.tr("Cancel"), .choice = .cancel },
    };
    const answer = run(owner, .{
        .title = i18n.tr("Paste into elevated terminal?"),
        .icon = .shield,
        .body = body.buffered(),
        .preview = .{ .text = text, .kind = .paste },
        .buttons = &buttons,
        .default_button = 1,
    });
    return if (answer.explicit) answer.choice else .cancel;
}

/// Tell the user that the shell process exited with a non-zero code.
pub fn showChildExited(owner: ?w32.HWND, exit_code: u32) void {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    i18n.format(&writer, i18n.tr("The shell process exited with code {code}."), .{
        .code = exit_code,
    }) catch {};
    const buttons = [_]Button{.{ .label = i18n.tr("OK"), .choice = .accept }};
    _ = run(owner, .{
        .title = i18n.tr("Command Failed"),
        .body = writer.buffered(),
        .buttons = &buttons,
    });
}

/// The About dialog: product name, version, the graphics in use, the
/// notice that Ghostty GX is an unofficial fork, and links. Copy Version
/// copies the version and the graphics for a bug report.
pub fn showAbout(owner: ?w32.HWND, version: []const u8) void {
    var body_buf: [512]u8 = undefined;
    var body: std.Io.Writer = .fixed(&body_buf);
    i18n.format(&body, i18n.tr("Version {version}"), .{ .version = version }) catch {};
    var copy_buf: [512]u8 = undefined;
    var copy: std.Io.Writer = .fixed(&copy_buf);
    copy.print("Ghostty GX {s}", .{version}) catch {};
    if (owner) |hwnd| if (windowOf(hwnd)) |window| writeGraphics(window.app, &body, &copy);

    var detail_buf: [512]u8 = undefined;
    const detail = std.mem.print(&detail_buf, "{s}\n{s}", .{
        i18n.tr(branding.notice),
        i18n.tr(branding.license),
    }) catch i18n.tr(branding.notice);
    const buttons = [_]Button{
        .{ .label = i18n.tr("Copy Version"), .choice = .accept, .copies = true },
        .{ .label = i18n.tr("OK"), .choice = .accept },
    };
    _ = run(owner, .{
        .window_title = i18n.tr("About Ghostty GX"),
        .title = i18n.tr("Ghostty GX"),
        .icon = .info,
        .body = body.buffered(),
        .detail = detail,
        .links = &.{
            .{ .label = i18n.tr("Project Home"), .url = branding.home_url },
            .{ .label = i18n.tr("Report an Issue"), .url = branding.issues_url },
            .{ .label = i18n.tr("Upstream Ghostty"), .url = branding.ghostty_url },
        },
        .copy_text = copy.buffered(),
        .buttons = &buttons,
        .default_button = 1,
    });
}

/// Append the OpenGL implementation the app renders with: a translated
/// line to `body`, an English one to `copy`. Nothing when it is unknown.
fn writeGraphics(app: *App, body: *std.Io.Writer, copy: *std.Io.Writer) void {
    const device = app.core_app.device orelse return;
    if (comptime !@hasDecl(@TypeOf(device.*), "backend")) return;
    device.wait() catch return;
    const backend = device.backend();
    if (backend.renderer.len == 0) return;
    var version_buf: [24]u8 = undefined;
    const gl_version = std.mem.print(&version_buf, "{d}.{d}", .{ backend.version.major, backend.version.minor }) catch "";
    const template = if (backend.software)
        i18n.tr("Graphics: {renderer}, OpenGL {version} (software rendering)")
    else
        i18n.tr("Graphics: {renderer}, OpenGL {version}");
    body.writeByte('\n') catch return;
    i18n.format(body, template, .{ .renderer = backend.renderer, .version = gl_version }) catch return;
    copy.print("\nOpenGL {s}: {s} ({s}){s}", .{
        gl_version,
        backend.renderer,
        backend.vendor,
        if (backend.software) ", software" else "",
    }) catch {};
}

/// A modal OK/Cancel warning that defaults to Cancel.
pub fn confirm(owner: ?w32.HWND, message: []const u8, title: []const u8) Choice {
    const buttons = [_]Button{
        .{ .label = i18n.tr("OK"), .choice = .accept },
        .{ .label = i18n.tr("Cancel"), .choice = .cancel },
    };
    return run(owner, .{
        .title = title,
        .body = message,
        .buttons = &buttons,
        .default_button = 1,
    }).choice;
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

/// Whether the dialogs (and other custom-drawn UI with a native
/// counterpart) should be native: a screen reader is running, or
/// `GHOSTTY_GX_A11Y` is `screen-reader` (to see them without one).
pub fn screenReaderActive() bool {
    if (a11yOverride()) return true;
    var running: i32 = 0;
    if (SystemParametersInfoW(SPI_GETSCREENREADER, 0, @ptrCast(&running), 0) == 0) return false;
    return running != 0;
}

/// The value of `GHOSTTY_GX_A11Y` asks for screen reader behavior.
fn a11yOverride() bool {
    var buf: [32]u16 = undefined;
    const len = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(a11y_env), &buf, buf.len);
    if (len == 0 or len >= buf.len) return false;
    var utf8: [32]u8 = undefined;
    return isScreenReaderValue(wstr.utf8Buf(&utf8, buf[0..len]));
}

const a11y_env = "GHOSTTY_GX_A11Y";

fn isScreenReaderValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "screen-reader");
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
    /// Copies `Spec.copy_text` and keeps the dialog open instead.
    copies: bool = false,
};

const Link = struct {
    label: []const u8,
    url: [:0]const u8,
};

/// What a preview shows, which decides how empty text reads.
const PreviewKind = enum { paste, read, write };

const PreviewSource = struct {
    text: []const u8,
    kind: PreviewKind,
};

const Spec = struct {
    /// The window title (for accessibility tools), `title` by default.
    window_title: ?[]const u8 = null,
    title: []const u8,
    icon: Icon = .warning,
    body: []const u8,
    /// A bulleted list after the body: the running processes.
    list: []const []const u8 = &.{},
    /// The running processes by tab, instead of `list`.
    groups: []const ProcessGroup = &.{},
    /// Clipboard or paste text shown in a box after the body.
    preview: ?PreviewSource = null,
    /// Secondary text after the body.
    detail: []const u8 = "",
    links: []const Link = &.{},
    /// The label of a check box after the content; its state is returned.
    check: ?[]const u8 = null,
    /// What a copying button and Ctrl+C copy; the dialog text if null.
    copy_text: ?[]const u8 = null,
    /// In visual order, at most `max_buttons`.
    buttons: []const Button,
    /// The button that has the focus at first, answers Enter and is drawn
    /// in the accent color.
    default_button: usize = 0,
};

/// How a dialog ended.
const Answer = struct {
    choice: Choice,
    /// The state of the check box.
    checked: bool = false,
    /// The choice came from a button (not Escape or a close).
    explicit: bool = false,
};

const max_buttons = 3;
const max_links = 3;
const max_list_rows = 8;
const max_preview_rows = 8;

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
const pad: f32 = style.space.xl;
const section_gap: f32 = style.space.m;
const icon_size: f32 = style.icon.large;
const icon_gap: f32 = style.space.m;
const button_height: f32 = style.control.height;
const button_gap: f32 = style.space.s;
const footer_height: f32 = button_height + 2 * pad;
const list_label_gap: f32 = style.space.xs;
const list_row_height: f32 = 22;
const preview_row_height: f32 = 18;
const preview_pad: f32 = 10;
const preview_font_size: f32 = 13;
const link_height: f32 = style.control.compact;
const link_pad: f32 = style.space.xs;
const link_icon: f32 = style.icon.small;
const link_icon_gap: f32 = style.space.xs;
const link_gap: f32 = style.space.s;
const check_size: f32 = 20;
const check_gap: f32 = style.space.s;
const check_row_height: f32 = style.control.height;
const width_plain: f32 = 440;
const width_preview: f32 = 520;

/// Segoe Fluent Icons / MDL2 Assets "OpenInNewWindow", after a link.
const external_link_glyph: u21 = 0xE8A7;
/// The marker after a row that ends a line of a preview.
const line_end_marker = "\u{21B5}";

const Layout = struct {
    size: d2d.Size = .{ .width = width_plain, .height = 200 },
    icon: d2d.Rect = zero_rect,
    title: d2d.Rect = zero_rect,
    body: d2d.Rect = zero_rect,
    list: d2d.Rect = zero_rect,
    list_label_h: f32 = 0,
    preview: d2d.Rect = zero_rect,
    detail: d2d.Rect = zero_rect,
    links: [max_links]d2d.Rect = @splat(zero_rect),
    link_text_w: [max_links]f32 = @splat(0),
    check: d2d.Rect = zero_rect,
    footer: d2d.Rect = zero_rect,
    buttons: [max_buttons]d2d.Rect = @splat(zero_rect),
};

const zero_rect: d2d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

fn uiaLive(context: *anyopaque) bool {
    const self: *Dialog = @ptrCast(@alignCast(context));
    return self.popup.visible and self.result == null and uia_bridge.attachmentAlive(self.app, self.uia_attachment);
}
fn uiaBuild(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, api: *uia.Api, queue: *uia.Queue) anyerror!void {
    const self: *Dialog = @ptrCast(@alignCast(context));
    try bridge.publishDialog(api, queue, self.uia_attachment, self, .{ .context = self, .is_live = uiaLive, .action = uiaAction });
}
fn uiaAction(context: *anyopaque, token: u64, action: *const uia.Action) bool {
    const self: *Dialog = @ptrCast(@alignCast(context));
    if (!uiaLive(context)) return false;
    if (token == 0 and action.kind == .close) {
        self.answer(.cancel, false);
        return true;
    }
    if (token < uia_bridge.dialog_action_base) return false;
    const index = std.math.cast(usize, token - uia_bridge.dialog_action_base) orelse return false;
    if (index >= self.focusCount()) return false;
    switch (action.kind) {
        .focus => {
            self.focusTarget(index);
            const hwnd = self.popup.hwnd orelse return false;
            _ = w32.SetFocus(hwnd);
        },
        .invoke, .toggle => self.activate(index),
        else => return false,
    }
    return true;
}

/// A focusable element: the links, the check box, then the buttons.
const Target = union(enum) {
    link: usize,
    check,
    button: usize,
};

const Dialog = struct {
    app: *App,
    owner: w32.HWND,
    uia_attachment: @import("../../../gx/ui_ref.zig").Attachment = .{},
    spec: Spec,
    tokens: style.Tokens,
    popup: Popup = .{},
    layout: Layout = .{},

    /// Index into the focus order (links, check box, buttons).
    focus: usize = 0,
    /// Draw the focus ring: the keyboard moved the focus, or Windows
    /// always shows keyboard cues.
    keyboard: bool = false,
    hover: ?usize = null,
    pressed: ?usize = null,
    /// Set by a button (or Escape, or a close); ends the modal loop.
    result: ?Choice = null,
    /// The result came from a button.
    explicit: bool = false,
    checked: bool = false,
    copied: bool = false,

    /// The process list rows.
    list: ListRows = .{},
    /// The preview text prepared for display.
    preview: Preview = .{},

    /// The window procedure of the popup before `subclass`.
    popup_proc: isize = 0,

    fn focusTarget(self: *Dialog, index: usize) void {
        self.focus = index;
        self.keyboard = true;
        self.popup.focusMoved();
    }

    fn linkCount(self: *const Dialog) usize {
        return @min(self.spec.links.len, max_links);
    }

    fn buttonCount(self: *const Dialog) usize {
        return @min(self.spec.buttons.len, max_buttons);
    }

    fn focusCount(self: *const Dialog) usize {
        return self.linkCount() + @intFromBool(self.spec.check != null) + self.buttonCount();
    }

    fn checkIndex(self: *const Dialog) ?usize {
        if (self.spec.check == null) return null;
        return self.linkCount();
    }

    fn buttonIndex(self: *const Dialog, button: usize) usize {
        return self.linkCount() + @intFromBool(self.spec.check != null) + button;
    }

    fn defaultButton(self: *const Dialog) usize {
        return @min(self.spec.default_button, self.buttonCount() -| 1);
    }

    fn target(self: *const Dialog, index: usize) Target {
        const links = self.linkCount();
        if (index < links) return .{ .link = index };
        var i = index - links;
        if (self.spec.check != null) {
            if (i == 0) return .check;
            i -= 1;
        }
        return .{ .button = i };
    }

    fn targetRect(self: *const Dialog, index: usize) d2d.Rect {
        return switch (self.target(index)) {
            .link => |i| self.layout.links[i],
            .check => self.layout.check,
            .button => |i| self.layout.buttons[i],
        };
    }

    fn hitTest(self: *const Dialog, pos: d2d.Point) ?usize {
        for (0..self.focusCount()) |i| {
            if (self.targetRect(i).contains(pos)) return i;
        }
        return null;
    }

    fn answer(self: *Dialog, choice: Choice, explicit: bool) void {
        if (self.result != null) return;
        self.result = choice;
        self.explicit = explicit;
    }

    fn activate(self: *Dialog, index: usize) void {
        switch (self.target(index)) {
            .link => |i| open_url.open(self.spec.links[i].url),
            .check => {
                self.checked = !self.checked;
                self.popup.invalidate();
            },
            .button => |i| {
                const button = self.spec.buttons[i];
                if (button.copies) {
                    var buf: [4096]u8 = undefined;
                    if (self.popup.hwnd) |hwnd| copyToClipboard(hwnd, self.copyText(&buf));
                    self.copied = true;
                    self.popup.invalidate();
                    return;
                }
                self.answer(button.choice, true);
            },
        }
    }

    /// Enter: the focused button or link; on the check box, the default
    /// button.
    fn activateFocused(self: *Dialog, enter: bool) void {
        if (self.focusCount() == 0) return;
        if (enter and self.target(self.focus) == .check) {
            self.activate(self.buttonIndex(self.defaultButton()));
            return;
        }
        self.activate(self.focus);
    }

    /// The text Ctrl+C and a copying button put on the clipboard.
    fn copyText(self: *const Dialog, buf: []u8) []const u8 {
        if (self.spec.copy_text) |text| return text;
        var writer: std.Io.Writer = .fixed(buf);
        writeDialogText(&writer, self.spec, &self.list, if (self.spec.preview != null) &self.preview else null);
        return writer.buffered();
    }

    fn moveFocus(self: *Dialog, forward: bool) void {
        const count = self.focusCount();
        if (count == 0) return;
        self.focusTarget(if (forward) (self.focus + 1) % count else (self.focus + count - 1) % count);
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
        const title_line_h = style.type_ramp.subtitle.line;
        const title_h = factory.measureText(spec.title, titleStyle(t), content_w - icon_w).height;
        if (spec.icon != .none) layout.icon = .{
            .x = pad,
            .y = y + (title_line_h - icon_size) / 2,
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
        self.list = listRows(spec.list, spec.groups);
        if (self.list.count > 0) {
            y += section_gap;
            const label_h = factory.measureText(i18n.tr("Running processes:"), secondaryStyle(t), content_w).height;
            const rows: f32 = @floatFromInt(self.list.count + @intFromBool(self.list.more > 0));
            layout.list_label_h = label_h;
            layout.list = .{ .x = pad, .y = y, .w = content_w, .h = label_h + list_label_gap + rows * list_row_height };
            y += layout.list.h;
        }

        // Preview, wrapped at the columns of the monospace font.
        if (spec.preview) |source| {
            y += section_gap;
            const text_w = content_w - 2 * preview_pad;
            const advance = factory.measureText("0000000000", previewStyle(t), 10_000).width / 10;
            const columns: usize = if (advance > 0) @intFromFloat(@floor(text_w / advance)) else 60;
            previewLines(&self.preview, source.text, columns, max_preview_rows, unicode.codepointWidth);
            const rows: f32 = @floatFromInt(previewRows(&self.preview));
            layout.preview = .{ .x = pad, .y = y, .w = content_w, .h = rows * preview_row_height + 2 * preview_pad };
            y += layout.preview.h;
        }

        // Detail.
        if (spec.detail.len > 0) {
            y += section_gap;
            const detail_h = factory.measureText(spec.detail, secondaryStyle(t), content_w).height;
            layout.detail = .{ .x = pad, .y = y, .w = content_w, .h = detail_h };
            y += detail_h;
        }

        // Links, side by side, wrapping onto more rows; the text lines up
        // with the content and the hover fill reaches past it.
        const links = self.linkCount();
        if (links > 0) {
            y += section_gap - link_pad;
            var x: f32 = pad - link_pad;
            for (spec.links[0..links], 0..) |link, i| {
                const text_w = @ceil(factory.measureText(link.label, linkStyle(t), content_w).width);
                const w = text_w + link_icon_gap + link_icon + 2 * link_pad;
                if (x > pad and x + w > pad + content_w + link_pad) {
                    x = pad - link_pad;
                    y += link_height;
                }
                layout.links[i] = .{ .x = x, .y = y, .w = w, .h = link_height };
                layout.link_text_w[i] = text_w;
                x += w + link_gap;
            }
            y += link_height - link_pad;
        }

        // Check box.
        if (spec.check) |label| {
            y += section_gap;
            const text_w = @ceil(factory.measureText(label, bodyStyle(t), content_w - check_size - check_gap).width);
            layout.check = .{ .x = pad, .y = y, .w = check_size + check_gap + text_w, .h = check_row_height };
            y += check_row_height;
        }

        // Footer with the buttons sharing its width, like a WinUI
        // ContentDialog; a single button takes the right half.
        y += pad;
        layout.footer = .{ .x = 0, .y = y, .w = width, .h = footer_height };
        const count = self.buttonCount();
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

    fn state(self: *const Dialog, index: usize) controls.State {
        const hovered = self.hover == index;
        return .{
            .hover = hovered,
            .pressed = hovered and self.pressed == index,
            .focused = self.keyboard and self.focus == index,
        };
    }

    fn paint(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const l = &self.layout;
        const full: d2d.Rect = .{ .x = 0, .y = 0, .w = l.size.width, .h = l.size.height };
        canvas.fillRect(full, t.surface_raised);

        if (iconGlyph(self.spec.icon, t)) |icon| canvas.drawIcon(icon.glyph, l.icon, icon_size, icon.color);
        canvas.drawText(self.spec.title, l.title, titleStyle(t));
        canvas.drawText(self.spec.body, l.body, bodyStyle(t));

        if (self.list.count > 0) self.paintList(canvas);
        if (self.spec.preview != null) self.paintPreview(canvas);
        if (self.spec.detail.len > 0) canvas.drawText(self.spec.detail, l.detail, secondaryStyle(t));
        for (0..self.linkCount()) |i| self.paintLink(canvas, i);
        if (self.spec.check != null) self.paintCheck(canvas);

        // Footer band and buttons.
        canvas.fillRect(l.footer, t.surface);
        controls.hairline(canvas, 0, l.footer.y, l.footer.w, t);
        const default = self.defaultButton();
        for (self.spec.buttons[0..self.buttonCount()], 0..) |button, i| {
            const label = if (button.copies and self.copied) i18n.tr("Copied to clipboard") else button.label;
            const kind: controls.ButtonKind = if (i == default) .accent else .standard;
            controls.button(canvas, l.buttons[i], label, kind, self.state(self.buttonIndex(i)), t);
        }
    }

    fn paintList(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const r = self.layout.list;
        const label_h = self.layout.list_label_h;
        canvas.drawText(i18n.tr("Running processes:"), .{ .x = r.x, .y = r.y, .w = r.w, .h = label_h }, secondaryStyle(t));

        // Processes under tab titles are indented below them.
        const indent: f32 = if (self.spec.groups.len > 0) style.space.m else 0;
        var y = r.y + label_h + list_label_gap;
        for (self.list.rows[0..self.list.count]) |row| {
            if (row.header) {
                const title = if (row.text.len > 0) row.text else "\u{2014}";
                canvas.drawText(title, .{ .x = r.x, .y = y, .w = r.w, .h = list_row_height }, headerStyle(t));
            } else {
                const dot = canvas.snapRect(.{ .x = r.x + indent + 4, .y = y + list_row_height / 2 - 2, .w = 4, .h = 4 });
                canvas.fillRoundedRect(dot, 2, t.text_secondary);
                const x = r.x + indent + 16;
                canvas.drawText(policy.displayName(row.text), .{ .x = x, .y = y, .w = r.x + r.w - x, .h = list_row_height }, itemStyle(t));
            }
            y += list_row_height;
        }
        if (self.list.more > 0) {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            i18n.format(&writer, i18n.tr("…and {count} more"), .{ .count = self.list.more }) catch {};
            var more_style = secondaryStyle(t);
            more_style.align_y = .center;
            const x = r.x + indent + 16;
            canvas.drawText(writer.buffered(), .{ .x = x, .y = y, .w = r.x + r.w - x, .h = list_row_height }, more_style);
        }
    }

    fn paintPreview(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const r = self.layout.preview;
        const box = canvas.snapRect(r);
        canvas.fillRoundedRect(box, style.radius.control, t.background);
        canvas.strokeRoundedRectPx(box, style.radius.control, t.border, 1);

        const p = &self.preview;
        const x = r.x + preview_pad;
        const w = r.w - 2 * preview_pad;
        var y = r.y + preview_pad;
        const note = noteStyle(t);
        if (p.chars == 0) {
            canvas.drawText(emptyText(self.spec.preview.?.kind), .{ .x = x, .y = y, .w = w, .h = preview_row_height }, note);
            return;
        }
        const mark_color = ui_color.ensureContrast(t.caution, t.background, 4.5);
        for (p.shown()) |*row| {
            var text_buf: [Preview.row_bytes + line_end_marker.len]u8 = undefined;
            var runs: [Preview.max_marks + 1]d2d.TextRun = undefined;
            var run_count: usize = 0;
            const text = p.rowText(row);
            @memcpy(text_buf[0..text.len], text);
            var len = text.len;
            for (row.markSlice()) |mark| {
                runs[run_count] = .{ .start = mark.start, .len = mark.len, .color = mark_color };
                run_count += 1;
            }
            if (row.line_end) {
                @memcpy(text_buf[len..][0..line_end_marker.len], line_end_marker);
                runs[run_count] = .{ .start = len, .len = line_end_marker.len, .color = t.text_tertiary };
                run_count += 1;
                len += line_end_marker.len;
            }
            canvas.drawTextRuns(text_buf[0..len], .{ .x = x, .y = y, .w = w, .h = preview_row_height }, previewStyle(t), runs[0..run_count]);
            y += preview_row_height;
        }
        var buf: [160]u8 = undefined;
        if (p.truncated) {
            canvas.drawText(moreText(&buf, p), .{ .x = x, .y = y, .w = w, .h = preview_row_height }, note);
            y += preview_row_height;
        }
        canvas.drawText(statsText(&buf, p), .{ .x = x, .y = y, .w = w, .h = preview_row_height }, note);
    }

    fn paintLink(self: *Dialog, canvas: *d2d.Canvas, i: usize) void {
        const t = self.tokens;
        const r = canvas.snapRect(self.layout.links[i]);
        const s = self.state(i);
        if (s.hover) canvas.fillRoundedRect(r, style.radius.control, if (s.pressed) t.pressed else t.hover);
        const label = self.spec.links[i].label;
        const text_w = self.layout.link_text_w[i];
        const text_rect: d2d.Rect = .{ .x = r.x + link_pad, .y = r.y, .w = text_w, .h = r.h };
        // Always underlined: the color alone does not say it is a link.
        canvas.drawTextRuns(label, text_rect, linkStyle(t), &.{.{ .start = 0, .len = label.len, .underline = true }});
        const icon_rect: d2d.Rect = .{ .x = text_rect.x + text_w + link_icon_gap, .y = r.y, .w = link_icon, .h = r.h };
        canvas.drawIcon(external_link_glyph, icon_rect, link_icon, t.accent_text);
        if (s.focused) controls.focusRing(canvas, r, style.radius.control, t);
    }

    fn paintCheck(self: *Dialog, canvas: *d2d.Canvas) void {
        const t = self.tokens;
        const r = self.layout.check;
        const s = self.state(self.checkIndex().?);
        const box = canvas.snapRect(.{ .x = r.x, .y = r.y + (r.h - check_size) / 2, .w = check_size, .h = check_size });
        const radius = style.radius.control;
        if (self.checked) {
            const colors = controls.buttonColors(.accent, .{ .hover = s.hover, .pressed = s.pressed }, t);
            canvas.fillRoundedRect(box, radius, colors.fill orelse t.accent);
            canvas.drawIcon(d2d.icons.check_mark, box, style.icon.small, t.on_accent);
        } else {
            const colors = controls.buttonColors(.standard, .{ .hover = s.hover, .pressed = s.pressed }, t);
            canvas.fillRoundedRect(box, radius, colors.fill orelse t.control_fill);
            // A strong stroke: the box is the control (WCAG 3:1).
            canvas.strokeRoundedRectPx(box, radius, t.text_secondary, 1);
        }
        const x = r.x + check_size + check_gap;
        var label_style = bodyStyle(t);
        label_style.align_y = .center;
        label_style.wrap = false;
        canvas.drawText(self.spec.check.?, .{ .x = x, .y = r.y, .w = r.x + r.w - x, .h = r.h }, label_style);
        if (s.focused) controls.focusRing(canvas, canvas.snapRect(r), radius, t);
    }
};

test "UIA dialog focus preserves checkbox Toggle until the checkbox changes" {
    var api: uia.Api = undefined;
    api.count = .init(1);
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    const attachment: @import("../../../gx/ui_ref.zig").Attachment = .{
        .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
        .revision = 1,
    };
    const nodes = [_]uia.NodeSpec{
        .{ .id = 1, .name = "Dialog", .role = .window },
        .{ .id = 2, .parent = 0, .name = "Remember", .role = .checkbox, .patterns = .{ .toggle = true } },
    };
    var dialog: Dialog = .{
        .app = undefined,
        .owner = @ptrFromInt(1),
        .tokens = undefined,
        .spec = .{ .title = "Test", .body = "", .check = "Remember", .buttons = &.{.{ .label = "OK", .choice = .accept }} },
    };
    defer dialog.popup.destroy();
    dialog.layout.check = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    try dialog.popup.uia_view.publisher.publish(testing.allocator, &api, &queue, attachment, @ptrFromInt(1), &nodes);
    const snapshot = dialog.popup.uia_view.publisher.current.?;
    const face = &snapshot.nodes[1].faces[0];
    const Abi = extern struct {
        query: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        retain: *const fn (*uia.Face) callconv(.winapi) u32,
        release: *const fn (*uia.Face) callconv(.winapi) u32,
        options: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
    };
    const abi: *const Abi = @ptrCast(@alignCast(face.vtable));
    _ = abi.retain(face);
    defer _ = abi.release(face);
    const action: uia.Action = .{ .attachment = attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .toggle, .value = &.{}, .alloc = testing.allocator };
    var options: u32 = 0;
    dialog.focusTarget(dialog.checkIndex().?);
    try testing.expectEqual(@as(i32, 0), abi.options(face, &options));
    dialog.moveFocus(true);
    dialog.moveFocus(false);
    onMouse(&dialog, &dialog.popup, .{ .kind = .move, .pos = .{ .x = 1, .y = 1 } });
    onMouse(&dialog, &dialog.popup, .{ .kind = .leave, .pos = .{ .x = 1, .y = 1 } });
    try testing.expectEqual(@as(i32, 0), abi.options(face, &options));
    try testing.expect(dialog.popup.uia_view.publisher.accepts(action));
    // This is the actual Toggle implementation, without the desktop/queue
    // boundary. Unlike focus it mutates the model and must revoke the snapshot.
    dialog.activate(dialog.checkIndex().?);
    try testing.expect(dialog.checked);
    try testing.expect(!dialog.popup.uia_view.publisher.accepts(action));
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040201))), abi.options(face, &options));
}

test "UIA dialog focus moves report the focused element and keep every element" {
    // The real publishDialog through a hidden (never shown) dialog window: a
    // client holds the check box and the OK button. A focus request, then
    // Shift+Tab and Tab, move HasKeyboardFocus between them in place; both
    // stay usable, and the Toggle the client sends after focusing the check
    // box is accepted, until the check box itself toggles.
    const hinstance = w32.GetModuleHandleW(null) orelse return error.TestWindowFailed;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const owner = w32.CreateWindowExW(0, class, class, 0, -32000, -32000, 32, 32, null, null, null, null) orelse return error.TestWindowFailed;
    defer _ = w32.DestroyWindow(owner);
    var api: uia.Api = undefined;
    api.count = .init(1);
    api.event = null;
    api.notification = null;
    var queue: uia.Queue = .{ .alloc = testing.allocator, .hwnd = @ptrFromInt(1) };
    defer testing.expectEqual(@as(usize, 1), api.count.load(.acquire)) catch unreachable;
    defer testing.expectEqual(@as(usize, 1), queue.refs_count.load(.acquire)) catch unreachable;
    var app: App = undefined;
    app.uia_api = &api;
    app.uia_queue = &queue;
    app.drop_closing = false;
    app.uia_popups = .{};
    const tokens = style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    var dialog: Dialog = .{
        .app = undefined,
        .owner = owner,
        .tokens = tokens,
        .uia_attachment = .{
            .object = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
            .owner = .{ .epoch = 1, .kind = .window, .id = 1, .generation = 1 },
            .revision = 1,
        },
        .spec = .{ .title = "Test", .body = "", .check = "Remember", .buttons = &.{ .{ .label = "OK", .choice = .accept }, .{ .label = "Cancel", .choice = .cancel } } },
    };
    const Source = struct {
        fn live(_: *anyopaque) bool {
            return true;
        }
        fn build(context: *anyopaque, _: *Popup, bridge: *uia_bridge.PopupBridge, a: *uia.Api, q: *uia.Queue) anyerror!void {
            const self: *Dialog = @ptrCast(@alignCast(context));
            try bridge.publishDialog(a, q, self.uia_attachment, self, .{ .context = self, .is_live = live, .action = uiaAction });
        }
    };
    try dialog.popup.create(hinstance, owner, factory, popupOptions(dialog.spec, tokens), .{
        .ctx = &dialog,
        .paint = onPaint,
        .uia_source = .{ .app = &app, .build = Source.build, .is_live = Source.live, .action = uiaAction },
    });
    defer dialog.popup.destroy();
    dialog.popup.visible = true;
    dialog.popup.focused = true;
    dialog.popup.uia_layout_pending = false;
    dialog.focus = dialog.checkIndex().? + 1;
    // What WM_GETOBJECT publishes (Popup.uiaRefresh).
    try Source.build(&dialog, &dialog.popup, &dialog.popup.uia_view, &api, &queue);
    const snapshot = dialog.popup.uia_view.publisher.current.?;
    const Simple = extern struct {
        QueryInterface: *const fn (*uia.Face, *const w32.GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*uia.Face) callconv(.winapi) u32,
        Release: *const fn (*uia.Face) callconv(.winapi) u32,
        ProviderOptions: *const fn (*uia.Face, *u32) callconv(.winapi) i32,
        GetPatternProvider: *const fn (*uia.Face, i32, *?*uia.Face) callconv(.winapi) i32,
        GetPropertyValue: *const fn (*uia.Face, i32, *uia.Variant) callconv(.winapi) i32,
    };
    const Probe = struct {
        /// Usable (ProviderOptions succeeds) and whether it has the focus.
        fn hasFocus(face: *uia.Face) !bool {
            const table: *const Simple = @ptrCast(@alignCast(face.vtable));
            var options: u32 = 0;
            try testing.expectEqual(@as(i32, 0), table.ProviderOptions(face, &options));
            var value: uia.Variant = .{};
            try testing.expectEqual(@as(i32, 0), table.GetPropertyValue(face, 30008, &value));
            return value.data.integer != 0;
        }
    };
    // Nodes: the dialog, the check box, OK, Cancel.
    const check = &snapshot.nodes[1].faces[0];
    const ok = &snapshot.nodes[2].faces[0];
    for ([_]*uia.Face{ check, ok }) |face| _ = @as(*const Simple, @ptrCast(@alignCast(face.vtable))).AddRef(face);
    defer for ([_]*uia.Face{ check, ok }) |face| {
        _ = @as(*const Simple, @ptrCast(@alignCast(face.vtable))).Release(face);
    };
    try testing.expect(!try Probe.hasFocus(check));
    try testing.expect(try Probe.hasFocus(ok));
    // A UIA SetFocus (or a click) on the check box, then Shift+Tab and Tab.
    dialog.focusTarget(dialog.checkIndex().?);
    try testing.expect(try Probe.hasFocus(check));
    try testing.expect(!try Probe.hasFocus(ok));
    dialog.moveFocus(true);
    try testing.expect(!try Probe.hasFocus(check));
    try testing.expect(try Probe.hasFocus(ok));
    dialog.moveFocus(false);
    try testing.expect(try Probe.hasFocus(check));
    try testing.expectEqual(snapshot, dialog.popup.uia_view.publisher.current.?);
    const toggle: uia.Action = .{ .attachment = dialog.uia_attachment, .snapshot_id = snapshot.id, .node_id = 2, .kind = .toggle, .value = &.{}, .alloc = testing.allocator };
    try testing.expect(dialog.popup.uia_view.publisher.accepts(toggle));
    // The Toggle itself changes the model and revokes the elements.
    dialog.activate(dialog.checkIndex().?);
    try testing.expect(dialog.checked);
    try testing.expect(!dialog.popup.uia_view.publisher.accepts(toggle));
}

fn titleStyle(t: style.Tokens) d2d.TextStyle {
    var s = style.type_ramp.subtitle.text(t.text);
    s.align_y = .top;
    s.wrap = true;
    s.ellipsis = false;
    return s;
}

fn bodyStyle(t: style.Tokens) d2d.TextStyle {
    var s = style.type_ramp.body.text(t.text);
    s.align_y = .top;
    s.wrap = true;
    s.ellipsis = false;
    return s;
}

fn secondaryStyle(t: style.Tokens) d2d.TextStyle {
    var s = bodyStyle(t);
    s.color = t.text_secondary;
    return s;
}

/// A tab title in the process list.
fn headerStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.body,
        .weight = .semibold,
        .color = t.text_secondary,
        .align_y = .center,
        .ellipsis = true,
    };
}

/// A process name in the process list.
fn itemStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .font = .mono,
        .size = style.font_size.body,
        .color = t.text,
        .align_y = .center,
        .ellipsis = true,
    };
}

/// A row of preview text: clipped, not trimmed, so every row ends where
/// its text does.
fn previewStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .font = .mono,
        .size = preview_font_size,
        .color = t.foreground,
        .align_y = .center,
        .ellipsis = false,
    };
}

/// The notes in a preview box (empty, more lines, totals).
fn noteStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.caption,
        .color = t.text_secondary,
        .align_y = .center,
        .ellipsis = true,
    };
}

fn linkStyle(t: style.Tokens) d2d.TextStyle {
    return .{
        .size = style.font_size.body,
        .color = t.accent_text,
        .align_y = .center,
        .ellipsis = false,
    };
}

const IconGlyph = struct { glyph: u21, color: d2d.Color };

/// The Segoe Fluent Icons glyph of a dialog icon and its color.
fn iconGlyph(icon: Icon, t: style.Tokens) ?IconGlyph {
    return switch (icon) {
        .none => null,
        .warning => .{ .glyph = d2d.icons.warning, .color = t.caution },
        .info => .{ .glyph = d2d.icons.info, .color = t.accent },
        .shield => .{ .glyph = d2d.icons.shield, .color = t.accent },
    };
}

fn emptyText(kind: PreviewKind) []const u8 {
    return switch (kind) {
        .read => i18n.tr("The clipboard is empty."),
        .paste, .write => i18n.tr("The text is empty."),
    };
}

/// What the row after the last shown one says: how many lines are left,
/// or an ellipsis when only the rest of a long line is.
fn moreText(buf: []u8, p: *const Preview) []const u8 {
    if (p.hidden_lines == 0) return "\u{2026}";
    var writer: std.Io.Writer = .fixed(buf);
    i18n.format(&writer, i18n.tr("… {count} more lines"), .{ .count = p.hidden_lines }) catch {};
    return writer.buffered();
}

fn statsText(buf: []u8, p: *const Preview) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    i18n.format(&writer, i18n.tr("Lines: {lines} · Characters: {chars}"), .{
        .lines = p.lines,
        .chars = p.chars,
    }) catch {};
    return writer.buffered();
}

/// The rows of the preview box: the text rows, the "more" row when the
/// text does not fit, and the totals; one row for empty text.
fn previewRows(p: *const Preview) usize {
    if (p.chars == 0) return 1;
    return p.row_count + @intFromBool(p.truncated) + 1;
}

/// The text of a dialog as plain text, as the native dialogs show it and
/// Ctrl+C copies it: title, body, processes, the preview as displayed
/// (rows with the line end marker, escapes, the totals) and the detail.
fn writeDialogText(writer: *std.Io.Writer, spec: Spec, list: *const ListRows, preview: ?*const Preview) void {
    writer.print("{s}\n\n{s}", .{ spec.title, spec.body }) catch {};
    writeContent(writer, spec, list, preview);
}

/// Everything after the body (see `writeDialogText`).
fn writeContent(writer: *std.Io.Writer, spec: Spec, list: *const ListRows, preview: ?*const Preview) void {
    if (list.count > 0) {
        writer.print("\n\n{s}", .{i18n.tr("Running processes:")}) catch {};
        const indent = if (spec.groups.len > 0) "    " else "";
        for (list.rows[0..list.count]) |row| {
            if (row.header) {
                writer.print("\n{s}", .{row.text}) catch {};
            } else {
                writer.print("\n{s}\u{2022} {s}", .{ indent, policy.displayName(row.text) }) catch {};
            }
        }
        if (list.more > 0) {
            writer.print("\n{s}", .{indent}) catch {};
            i18n.format(writer, i18n.tr("…and {count} more"), .{ .count = list.more }) catch {};
        }
    }
    if (preview) |p| {
        writer.writeAll("\n\n") catch {};
        writePreview(writer, p, spec.preview.?.kind);
    }
    if (spec.detail.len > 0) writer.print("\n\n{s}", .{spec.detail}) catch {};
}

fn writePreview(writer: *std.Io.Writer, p: *const Preview, kind: PreviewKind) void {
    if (p.chars == 0) {
        writer.writeAll(emptyText(kind)) catch {};
        return;
    }
    for (p.shown(), 0..) |*row, i| {
        if (i > 0) writer.writeByte('\n') catch {};
        writer.writeAll(p.rowText(row)) catch {};
        if (row.line_end) writer.writeAll(line_end_marker) catch {};
    }
    var buf: [160]u8 = undefined;
    if (p.truncated) writer.print("\n{s}", .{moreText(&buf, p)}) catch {};
    writer.print("\n{s}", .{statsText(&buf, p)}) catch {};
}

// -----------------------------------------------------------------------
// Process list
// -----------------------------------------------------------------------

const ListRow = struct {
    text: []const u8,
    /// A tab title above its processes.
    header: bool = false,
};

const ListRows = struct {
    rows: [max_list_rows]ListRow = undefined,
    count: usize = 0,
    /// Processes left out.
    more: usize = 0,
};

/// The rows of a process list: the processes of `flat`, or the title and
/// processes of each group in `groups` (groups without processes are left
/// out), at most `max_list_rows`. When they do not all fit, the last row
/// is left for "…and N more" (`more` processes), and a title always has at
/// least one of its processes under it.
fn listRows(flat: []const []const u8, groups: []const ProcessGroup) ListRows {
    var out: ListRows = .{};
    var total_rows: usize = 0;
    var total: usize = 0;
    if (groups.len > 0) {
        for (groups) |group| {
            if (group.processes.len == 0) continue;
            total_rows += 1 + group.processes.len;
            total += group.processes.len;
        }
    } else {
        total_rows = flat.len;
        total = flat.len;
    }
    const limit: usize = if (total_rows <= max_list_rows) max_list_rows else max_list_rows - 1;
    var shown: usize = 0;
    if (groups.len > 0) {
        outer: for (groups) |group| {
            if (group.processes.len == 0) continue;
            if (out.count + 2 > limit) break;
            out.rows[out.count] = .{ .text = group.title, .header = true };
            out.count += 1;
            for (group.processes) |name| {
                if (out.count == limit) break :outer;
                out.rows[out.count] = .{ .text = name };
                out.count += 1;
                shown += 1;
            }
        }
    } else {
        for (flat[0..@min(flat.len, limit)]) |name| {
            out.rows[out.count] = .{ .text = name };
            out.count += 1;
            shown += 1;
        }
    }
    out.more = total - shown;
    return out;
}

// -----------------------------------------------------------------------
// Preview text
// -----------------------------------------------------------------------

/// The text of a paste or clipboard dialog prepared for display
/// (`previewLines`): wrapped into rows, with control, invisible and
/// reordering characters as `<U+XXXX>`, marked to draw in a warning color.
const Preview = struct {
    const max_rows = max_preview_rows;
    const max_marks = 8;
    /// Bytes of display text per row.
    const row_bytes = 512;

    /// A byte range of a row's text.
    const Mark = struct { start: u16, len: u16 };

    const Row = struct {
        start: u16 = 0,
        len: u16 = 0,
        /// The row ends a line of the text: the line end marker follows.
        line_end: bool = false,
        /// The first row of a line (not a continuation of a wrapped one).
        line_start: bool = false,
        /// Escaped and control characters in the row.
        marks: [max_marks]Mark = undefined,
        mark_count: u8 = 0,

        fn markSlice(self: *const Row) []const Mark {
            return self.marks[0..self.mark_count];
        }
    };

    buf: [max_rows * row_bytes]u8 = undefined,
    rows: [max_rows]Row = undefined,
    row_count: usize = 0,
    /// Lines of the text: one more than its line breaks, not counting a
    /// break at the very end; 0 for empty text.
    lines: usize = 0,
    /// Characters (code points; an invalid byte counts as one).
    chars: usize = 0,
    /// The text goes on past the rows shown.
    truncated: bool = false,
    /// Lines with no row shown.
    hidden_lines: usize = 0,

    fn rowText(self: *const Preview, row: *const Row) []const u8 {
        return self.buf[row.start..][0..row.len];
    }

    fn shown(self: *const Preview) []const Row {
        return self.rows[0..self.row_count];
    }
};

/// The display width of a code point in cells (0, 1 or 2).
const WidthFn = fn (cp: u21) u2;

/// Fill `out` with `text` prepared for display in rows of `columns` cells
/// (at least 16; the last cell is for the line end marker), at most
/// `max_rows` (at most `Preview.max_rows`) of them. Line breaks (LF, CRLF
/// and a lone CR, which a shell takes as Enter too) end a row with the
/// marker; a tab moves to the next multiple of four cells; an escape
/// never splits across rows. When the text needs more rows, the last one
/// is left for the caller to say how much is hidden (`truncated`,
/// `hidden_lines`); lines and characters are counted over all the text.
fn previewLines(out: *Preview, text: []const u8, columns: usize, max_rows: usize, comptime widthOf: WidthFn) void {
    out.* = .{};
    const cells_per_row = @max(columns, 16) - 1;
    const row_limit = @max(1, @min(max_rows, Preview.max_rows));

    var builder: RowBuilder = .{ .out = out, .cells_limit = cells_per_row, .row_limit = row_limit };
    var i: usize = 0;
    var at_line_start = true;
    while (i < text.len) {
        const byte = text[i];
        if (byte == '\n' or byte == '\r') {
            const len: usize = if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') 2 else 1;
            out.chars += len;
            i += len;
            if (at_line_start) builder.openRow(true);
            builder.finishRow(true);
            out.lines += 1;
            at_line_start = true;
            continue;
        }
        if (at_line_start) {
            builder.openRow(true);
            at_line_start = false;
        }

        var cp: ?u21 = null;
        var advance: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(byte)) |seq_len| {
            if (i + seq_len <= text.len) {
                if (std.unicode.utf8Decode(text[i..][0..seq_len])) |decoded| {
                    cp = decoded;
                    advance = seq_len;
                } else |_| {}
            }
        } else |_| {}
        i += advance;
        out.chars += 1;

        var piece_buf: [16]u8 = undefined;
        builder.append(displayPiece(&piece_buf, cp, byte, builder.cells, widthOf));
    }
    // A last line without a line break.
    if (!at_line_start) {
        builder.finishRow(false);
        out.lines += 1;
    }
    builder.finish();
}

const Piece = struct {
    text: []const u8,
    cells: usize,
    marked: bool,
};

/// How one code point (or an invalid `byte`, when `cp` is null) shows at
/// cell `column` of a row.
fn displayPiece(buf: *[16]u8, cp_: ?u21, byte: u8, column: usize, comptime widthOf: WidthFn) Piece {
    const cp = cp_ orelse {
        const s = std.mem.print(buf, "<0x{X:0>2}>", .{byte}) catch unreachable;
        return .{ .text = s, .cells = s.len, .marked = true };
    };
    switch (cp) {
        '\t' => {
            const n = 4 - column % 4;
            @memset(buf[0..n], ' ');
            return .{ .text = buf[0..n], .cells = n, .marked = false };
        },
        0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F => {
            const s = std.mem.print(buf, "<U+{X:0>4}>", .{cp}) catch unreachable;
            return .{ .text = s, .cells = s.len, .marked = true };
        },
        else => {},
    }
    if (isHidden(cp)) {
        const s = std.mem.print(buf, "<U+{X:0>4}>", .{cp}) catch unreachable;
        return .{ .text = s, .cells = s.len, .marked = true };
    }
    const len = std.unicode.utf8Encode(cp, buf) catch unreachable;
    return .{ .text = buf[0..len], .cells = widthOf(cp), .marked = false };
}

/// Code points that do not show or that reorder the text around them
/// (Trojan Source), so pasted text could run something other than what it
/// seems to say: C1 controls, bidirectional controls, zero width and
/// other invisible format characters, line and paragraph separators,
/// fillers that render as blanks, and tag characters.
fn isHidden(cp: u21) bool {
    return switch (cp) {
        0x80...0x9F,
        0xAD,
        0x34F,
        0x61C,
        0x115F,
        0x1160,
        0x17B4,
        0x17B5,
        0x180B...0x180F,
        0x200B...0x200F,
        0x2028...0x202E,
        0x2060...0x2064,
        0x2066...0x206F,
        0x3164,
        0xFEFF,
        0xFFA0,
        0xFFF9...0xFFFB,
        0x1D173...0x1D17A,
        0xE0000...0xE007F,
        => true,
        else => false,
    };
}

/// Fills the rows of a `Preview`, counting the rows the text needs past
/// the last one.
const RowBuilder = struct {
    out: *Preview,
    cells_limit: usize,
    row_limit: usize,
    /// Cells used in the current row.
    cells: usize = 0,
    /// The current row has a slot.
    open: bool = false,
    /// Rows needed so far, shown or not.
    needed: usize = 0,
    /// Lines that got a row.
    shown_lines: usize = 0,

    fn current(self: *RowBuilder) ?*Preview.Row {
        if (!self.open) return null;
        return &self.out.rows[self.out.row_count];
    }

    fn openRow(self: *RowBuilder, line_start: bool) void {
        self.needed += 1;
        self.cells = 0;
        if (self.out.row_count >= self.row_limit) {
            self.open = false;
            return;
        }
        const start = self.out.row_count * Preview.row_bytes;
        self.out.rows[self.out.row_count] = .{ .start = @intCast(start), .line_start = line_start };
        self.open = true;
    }

    fn finishRow(self: *RowBuilder, line_end: bool) void {
        if (self.open) {
            const row = &self.out.rows[self.out.row_count];
            row.line_end = line_end;
            if (row.line_start) self.shown_lines += 1;
            self.out.row_count += 1;
        }
        self.open = false;
    }

    fn append(self: *RowBuilder, piece: Piece) void {
        const wrap = self.cells > 0 and self.cells + piece.cells > self.cells_limit;
        const full = if (self.current()) |row| row.len + piece.text.len > Preview.row_bytes else false;
        if (wrap or full) {
            self.finishRow(false);
            self.openRow(false);
        }
        self.cells += piece.cells;
        const row = self.current() orelse return;
        @memcpy(self.out.buf[row.start + row.len ..][0..piece.text.len], piece.text);
        if (piece.marked) {
            const adjacent = row.mark_count > 0 and
                row.marks[row.mark_count - 1].start + row.marks[row.mark_count - 1].len == row.len;
            if (adjacent) {
                row.marks[row.mark_count - 1].len += @intCast(piece.text.len);
            } else if (row.mark_count < Preview.max_marks) {
                row.marks[row.mark_count] = .{ .start = row.len, .len = @intCast(piece.text.len) };
                row.mark_count += 1;
            }
        }
        row.len += @intCast(piece.text.len);
    }

    /// Leave the last slot for the "more" row when not everything fit.
    fn finish(self: *RowBuilder) void {
        const out = self.out;
        if (self.needed > out.row_count) {
            out.truncated = true;
            if (out.row_count == self.row_limit and out.row_count > 0) {
                out.row_count -= 1;
                if (out.rows[out.row_count].line_start) self.shown_lines -= 1;
            }
        }
        out.hidden_lines = out.lines -| self.shown_lines;
    }
};

// -----------------------------------------------------------------------
// Modal loop
// -----------------------------------------------------------------------

/// The Ghostty window behind a window handle, if `hwnd` is one.
fn windowOf(hwnd: w32.HWND) ?*Window {
    const proc: usize = @bitCast(w32.GetWindowLongPtrW(hwnd, w32.GWLP_WNDPROC));
    if (proc != @intFromPtr(&Window.windowWndProc)) return null;
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(userdata)));
}

/// The dialogs on screen, innermost last (GUI thread).
var open_dialogs: [max_depth]*Dialog = undefined;
var open_count: usize = 0;

/// The popup of a dialog: activating, closed only by an answer (Escape and
/// Alt+F4 answer Cancel themselves), and revealed even when its first frame
/// cannot be painted, so the question stays answerable and never answers
/// itself (`Popup.RevealTimeout.reveal`).
fn popupOptions(spec: Spec, tokens: style.Tokens) Popup.Options {
    return .{
        .activate = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .close_owner_on_close = false,
        .corners = .round,
        .shadow = true,
        .border_color = tokens.border,
        .dark = tokens.dark,
        .accessible_name = spec.window_title orelse spec.title,
        .reveal_timeout = .reveal,
    };
}

test "P4 a dialog stays up and answerable when its first frame fails" {
    const tokens = style.Tokens.fromColors(d2d.Color.hex(0x1e1e2e), d2d.Color.hex(0xcdd6f4), d2d.Color.hex(0x89b4fa));
    const options = popupOptions(.{ .title = "Close Terminal?", .body = "", .buttons = &.{.{ .label = "Close", .choice = .accept }} }, tokens);
    try std.testing.expectEqual(Popup.RevealTimeout.reveal, options.reveal_timeout);
    try std.testing.expect(options.activate and !options.dismiss_on_outside_click and !options.dismiss_on_escape);
    try std.testing.expect(!options.reuse_host);
    try std.testing.expectEqualStrings("Close Terminal?", options.accessible_name);
    // Everything else (menus, the palette, settings) cancels instead.
    try std.testing.expectEqual(Popup.RevealTimeout.cancel, (Popup.Options{}).reveal_timeout);
}

fn run(owner_: ?w32.HWND, spec: Spec) Answer {
    if (depth >= max_depth) {
        log.warn("too many nested dialogs, declining title={s}", .{spec.title});
        return .{ .choice = .cancel };
    }
    const owner = owner_ orelse return native(null, spec);
    const window = windowOf(owner) orelse return native(owner, spec);
    const app = window.app;
    if (screenReaderActive()) return native(owner, spec);
    const factory = app.uiFactory() orelse return native(owner, spec);

    var dialog: Dialog = .{
        .app = app,
        .owner = owner,
        .uia_attachment = uia_bridge.ownerAttachment(app, owner) orelse .{},
        .spec = spec,
        .tokens = style.Tokens.fromConfig(&app.config),
        .keyboard = keyboardCues(),
    };
    dialog.focus = dialog.buttonIndex(dialog.defaultButton());

    dialog.popup.create(app.hinstance, owner, factory, popupOptions(spec, dialog.tokens), .{
        .ctx = &dialog,
        .paint = onPaint,
        .uia_source = .{ .app = app, .build = uiaBuild, .is_live = uiaLive, .action = uiaAction },
        .key = onKey,
        .mouse = onMouse,
        .dismissed = onDismissed,
        .dpi_changed = onDpiChanged,
        .cursor = onCursor,
    }) catch |err| {
        log.warn("failed to create a dialog window err={}", .{err});
        return native(owner, spec);
    };
    // Laid out at the window's content scale, like its chrome.
    dialog.popup.setOwnerScale(window.scale);
    dialog.computeLayout(factory);
    const hwnd = dialog.popup.hwnd.?;
    subclass(&dialog, hwnd);

    depth += 1;
    open_dialogs[open_count] = &dialog;
    open_count += 1;
    var disabled: DisabledWindows = .{ .except = hwnd };
    disabled.disableAll();

    dialog.popup.show(dialog.screenRect());
    if (w32.GetForegroundWindow() != hwnd) flash(owner);
    const quit_code = modalLoop(&dialog);

    // Re-enable the other windows before the dialog goes away, so that
    // activation returns to the owner instead of another application.
    disabled.restore();
    if (w32.IsWindow(owner) != 0 and w32.GetActiveWindow() == hwnd) _ = w32.SetActiveWindow(owner);
    if (dialog.popup.hwnd) |h| _ = w32.SetWindowLongPtrW(h, w32.GWLP_WNDPROC, dialog.popup_proc);
    dialog.popup.destroy();

    open_count -= 1;
    depth -= 1;
    if (depth == 0) replayDeferred();
    if (quit_code) |code| w32.PostQuitMessage(code);
    return .{ .choice = dialog.result orelse .cancel, .checked = dialog.checked, .explicit = dialog.explicit };
}

/// Pump messages until the dialog has a result, its window is gone (its
/// owner was destroyed) or a requested quit arrives (`Popup.modalQuitCode`;
/// a withdrawn one leaves the dialog open). Returns the WM_QUIT exit code,
/// which the caller posts again once the dialog is closed.
fn modalLoop(dialog: *Dialog) ?i32 {
    while (dialog.result == null) {
        const hwnd = dialog.popup.hwnd orelse return null;
        if (w32.IsWindow(hwnd) == 0) return null;
        var msg: w32.MSG = undefined;
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            if (msg.message == w32.WM_QUIT) {
                if (Popup.modalQuitCode(dialog.app.quit_requested, msg.wParam)) |code| return code;
                continue;
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

/// Take WM_CLOSE and the system close of the dialog's popup before
/// `Popup` hides it: hidden while the other windows are still disabled,
/// it would leave the activation to another application. The close
/// answers Cancel instead, and the popup goes after the window has the
/// activation back.
fn subclass(dialog: *Dialog, hwnd: w32.HWND) void {
    dialog.popup_proc = w32.GetWindowLongPtrW(hwnd, w32.GWLP_WNDPROC);
    if (popup_proc == 0) popup_proc = dialog.popup_proc;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_WNDPROC, @bitCast(@intFromPtr(&dialogWndProc)));
}

/// `Popup`'s window procedure, for a dialog popup that is no longer on
/// `open_dialogs`.
var popup_proc: isize = 0;

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const dialog = openDialogOf(hwnd);
    if (dialog) |d| {
        const close = msg == w32.WM_CLOSE or (msg == WM_SYSCOMMAND and wparam & 0xFFF0 == SC_CLOSE);
        if (close) {
            d.answer(.cancel, false);
            return 0;
        }
    }
    const previous = if (dialog) |d| d.popup_proc else popup_proc;
    if (previous == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const proc: WNDPROC = @ptrFromInt(@as(usize, @bitCast(previous)));
    return CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

fn openDialogOf(hwnd: w32.HWND) ?*Dialog {
    for (open_dialogs[0..open_count]) |dialog| {
        if (dialog.popup.hwnd == hwnd) return dialog;
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
    /// The window left alone (the dialog, or the owner a native dialog
    /// disables and enables itself).
    except: ?w32.HWND,
    list: [64]w32.HWND = undefined,
    len: usize = 0,

    fn disableAll(self: *DisabledWindows) void {
        _ = w32.EnumThreadWindows(w32.GetCurrentThreadId(), &disableOne, @bitCast(@intFromPtr(self)));
    }

    fn disableOne(hwnd: w32.HWND, lparam: isize) callconv(.winapi) i32 {
        const self: *DisabledWindows = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (self.except) |except| if (hwnd == except) return 1;
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

/// Windows shows keyboard cues (focus rectangles) all the time, not only
/// after keyboard use.
fn keyboardCues() bool {
    var on: i32 = 0;
    if (SystemParametersInfoW(SPI_GETKEYBOARDCUES, 0, @ptrCast(&on), 0) == 0) return false;
    return on != 0;
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
        w32.VK_ESCAPE => self.answer(.cancel, false),
        w32.VK_F4 => if (key.alt) self.answer(.cancel, false),
        w32.VK_RETURN => self.activateFocused(true),
        w32.VK_SPACE => self.activateFocused(false),
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
                self.popup.repaint();
            }
        },
        .leave => {
            self.hover = null;
            self.pressed = null;
            self.popup.repaint();
        },
        .down => if (event.button == .left) {
            self.pressed = self.hitTest(event.pos);
            if (self.pressed) |index| self.focus = index;
            // Pointer use hides the focus ring again (unless Windows
            // always shows it).
            self.keyboard = keyboardCues();
            self.popup.focusMoved();
        },
        .up => if (event.button == .left) {
            const pressed = self.pressed;
            self.pressed = null;
            self.popup.repaint();
            if (pressed != null and pressed == self.hitTest(event.pos)) self.activate(pressed.?);
        },
        .double_click, .wheel => {},
    }
}

/// The hand over links.
fn onCursor(ctx: *anyopaque, popup: *Popup, pos: d2d.Point) ?Popup.Cursor {
    _ = popup;
    const self = dialogOf(ctx);
    for (self.layout.links[0..self.linkCount()]) |rect| {
        if (rect.contains(pos)) return .hand;
    }
    return null;
}

/// The popup was dismissed some other way than a close (`dialogWndProc`
/// takes those) and is hidden: answer like Cancel, which ends the modal
/// loop.
fn onDismissed(ctx: *anyopaque, popup: *Popup, reason: Popup.DismissReason) void {
    _ = popup;
    _ = reason;
    dialogOf(ctx).answer(.cancel, false);
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
    clipboard.setUnicodeText(hwnd, handle) catch |err| {
        log.warn("copy from dialog failed err={}", .{err});
        _ = w32.GlobalFree(handle);
    };
}

// -----------------------------------------------------------------------
// Native dialogs
// -----------------------------------------------------------------------

/// Show `spec` as a native task dialog (or a message box where comctl32 6
/// is missing), task modal like the custom dialogs, with the same text:
/// the processes, the preview as displayed, the links and the check box.
fn native(owner: ?w32.HWND, spec: Spec) Answer {
    depth += 1;
    defer {
        depth -= 1;
        if (depth == 0) replayDeferred();
    }
    // The owner stays enabled for the native dialog to disable and enable
    // again itself, so the activation comes back to it.
    var disabled: DisabledWindows = .{ .except = owner };
    disabled.disableAll();
    defer disabled.restore();

    const list = listRows(spec.list, spec.groups);
    var preview: Preview = undefined;
    if (spec.preview) |source| previewLines(&preview, source.text, native_columns, max_preview_rows, unicode.codepointWidth);
    const preview_ptr: ?*const Preview = if (spec.preview != null) &preview else null;

    var content_buf: [6144]u8 = undefined;
    var content: std.Io.Writer = .fixed(&content_buf);
    content.writeAll(spec.body) catch {};
    writeContent(&content, spec, &list, preview_ptr);

    var copy_buf: [4096]u8 = undefined;
    const copy_text = spec.copy_text orelse blk: {
        var copy: std.Io.Writer = .fixed(&copy_buf);
        writeDialogText(&copy, spec, &list, preview_ptr);
        break :blk copy.buffered();
    };
    return taskDialog(owner, spec, content.buffered(), copy_text) orelse messageBox(owner, spec, content.buffered());
}

/// Preview columns of the native dialogs.
const native_columns = 72;

const TaskDialogContext = struct {
    spec: *const Spec,
    copy_text: []const u8,
};

fn taskDialog(owner: ?w32.HWND, spec: Spec, content: []const u8, copy_text: []const u8) ?Answer {
    const task_dialog = taskDialogIndirect() orelse return null;

    var title_buf: [256]u16 = undefined;
    var instruction_buf: [512]u16 = undefined;
    var content_buf: [6144]u16 = undefined;
    var footer_buf: [1024]u16 = undefined;
    var check_buf: [256]u16 = undefined;
    var label_bufs: [max_buttons][128]u16 = undefined;
    var buttons: [max_buttons]TASKDIALOG_BUTTON = undefined;

    const button_count = @min(spec.buttons.len, max_buttons);
    for (spec.buttons[0..button_count], 0..) |button, i| {
        var label: [128]u8 = undefined;
        buttons[i] = .{
            .nButtonID = button_id_base + @as(i32, @intCast(i)),
            .pszButtonText = wstr.bufZ(&label_bufs[i], escapeAmpersands(&label, button.label)).ptr,
        };
    }

    // The links go in the footer as task dialog hyperlinks: their href is
    // the index of the link. Dialogs that show untrusted text have none,
    // so text like <a href=...> in a preview stays text.
    var footer: [512]u8 = undefined;
    var footer_writer: std.Io.Writer = .fixed(&footer);
    for (spec.links[0..@min(spec.links.len, max_links)], 0..) |link, i| {
        if (i > 0) footer_writer.writeAll("    ") catch {};
        footer_writer.print("<a href=\"{d}\">{s}</a>", .{ i, link.label }) catch {};
    }

    var flags: u32 = TDF_ALLOW_DIALOG_CANCELLATION;
    if (owner != null) flags |= TDF_POSITION_RELATIVE_TO_WINDOW;
    if (spec.links.len > 0) flags |= TDF_ENABLE_HYPERLINKS;

    var context: TaskDialogContext = .{ .spec = &spec, .copy_text = copy_text };
    const default = @min(spec.default_button, button_count -| 1);
    const config: TASKDIALOGCONFIG = .{
        .hwndParent = owner,
        .dwFlags = flags,
        .pszWindowTitle = wstr.bufZ(&title_buf, spec.window_title orelse branding.name).ptr,
        .pszMainIcon = mainIcon(spec.icon),
        .pszMainInstruction = wstr.bufZ(&instruction_buf, spec.title).ptr,
        .pszContent = wstr.bufZ(&content_buf, content).ptr,
        .cButtons = @intCast(button_count),
        .pButtons = &buttons,
        .nDefaultButton = button_id_base + @as(i32, @intCast(default)),
        .pszVerificationText = if (spec.check) |label| wstr.bufZ(&check_buf, label).ptr else null,
        .pszFooter = if (spec.links.len > 0) wstr.bufZ(&footer_buf, footer_writer.buffered()).ptr else null,
        .pfCallback = &taskDialogCallback,
        .lpCallbackData = @bitCast(@intFromPtr(&context)),
    };
    var pressed: i32 = 0;
    var verified: i32 = 0;
    const hr = task_dialog(&config, &pressed, null, &verified);
    if (hr < 0) {
        log.warn("TaskDialogIndirect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return null;
    }
    const index = pressed - button_id_base;
    if (index < 0 or index >= button_count) return .{ .choice = .cancel, .checked = verified != 0 };
    return .{
        .choice = spec.buttons[@intCast(index)].choice,
        .checked = verified != 0,
        .explicit = true,
    };
}

/// The task dialog's notifications: a click on a link opens it, a copying
/// button copies and keeps the dialog open.
fn taskDialogCallback(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize, data: isize) callconv(.winapi) w32.HRESULT {
    const context: *const TaskDialogContext = @ptrFromInt(@as(usize, @bitCast(data)));
    const spec = context.spec;
    switch (msg) {
        TDN_HYPERLINK_CLICKED => {
            const href: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const digit = href[0];
            if (digit >= '0' and digit <= '9') {
                const index: usize = digit - '0';
                if (index < @min(spec.links.len, max_links)) open_url.open(spec.links[index].url);
            }
        },
        TDN_BUTTON_CLICKED => {
            const id: i32 = @truncate(@as(isize, @bitCast(wparam)));
            const index = id - button_id_base;
            if (index >= 0 and index < @min(spec.buttons.len, max_buttons) and spec.buttons[@intCast(index)].copies) {
                copyToClipboard(hwnd, context.copy_text);
                return S_FALSE;
            }
        },
        else => {},
    }
    return S_OK;
}

/// A message box for `spec`, where task dialogs are missing: the first
/// button maps to OK, any other to Cancel.
fn messageBox(owner: ?w32.HWND, spec: Spec, content: []const u8) Answer {
    const two_buttons = spec.buttons.len > 1 and spec.buttons[1].choice == .cancel;
    var flags: u32 = if (spec.icon == .info) w32.MB_ICONINFORMATION else w32.MB_ICONWARNING;
    if (two_buttons) {
        flags |= w32.MB_OKCANCEL;
        if (spec.default_button == 1) flags |= w32.MB_DEFBUTTON2;
    }

    var message_buf: [6144]u16 = undefined;
    var title_buf: [256]u16 = undefined;
    const result = w32.MessageBoxW(
        owner,
        wstr.bufZ(&message_buf, content),
        wstr.bufZ(&title_buf, spec.window_title orelse spec.title),
        flags,
    );
    if (!two_buttons) return .{ .choice = .accept, .explicit = true };
    return .{
        .choice = if (result == w32.IDOK) spec.buttons[0].choice else .cancel,
        .explicit = result == w32.IDOK or result == w32.IDCANCEL,
    };
}

/// `text` with "&" doubled, so a button label shows it instead of an
/// access key underline. Cut to `buf`.
fn escapeAmpersands(buf: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        const need: usize = if (byte == '&') 2 else 1;
        if (len + need > buf.len) break;
        buf[len] = byte;
        if (byte == '&') buf[len + 1] = '&';
        len += need;
    }
    return buf[0..len];
}

fn mainIcon(icon: Icon) ?*const anyopaque {
    // MAKEINTRESOURCEW of the TD_*_ICON ids.
    const id: usize = switch (icon) {
        .none => return null,
        .warning => 0xFFFF,
        .info => 0xFFFD,
        .shield => 0xFFFC,
    };
    return @ptrFromInt(id);
}

const TaskDialogIndirectFn = *const fn (
    config: *const TASKDIALOGCONFIG,
    button: ?*i32,
    radio_button: ?*i32,
    verification: ?*i32,
) callconv(.winapi) w32.HRESULT;

/// `TaskDialogIndirect` from comctl32 6 (the app manifest asks for it);
/// null where it is missing (an executable without the manifest).
fn taskDialogIndirect() ?TaskDialogIndirectFn {
    if (!task_dialog_loaded) {
        task_dialog_loaded = true;
        const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("comctl32.dll"), null, 0) orelse return null;
        const proc = GetProcAddress(module, "TaskDialogIndirect") orelse return null;
        task_dialog_fn = @ptrCast(proc);
    }
    return task_dialog_fn;
}

var task_dialog_loaded = false;
var task_dialog_fn: ?TaskDialogIndirectFn = null;

const button_id_base: i32 = 100;

const TaskDialogCallback = *const fn (
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
    data: isize,
) callconv(.winapi) w32.HRESULT;

/// TASKDIALOG_BUTTON (commctrl.h, packed to 1 byte).
const TASKDIALOG_BUTTON = extern struct {
    nButtonID: i32 align(1),
    pszButtonText: [*:0]const u16 align(1),
};

/// TASKDIALOGCONFIG (commctrl.h, packed to 1 byte).
const TASKDIALOGCONFIG = extern struct {
    cbSize: u32 align(1) = @sizeOf(TASKDIALOGCONFIG),
    hwndParent: ?w32.HWND align(1) = null,
    hInstance: ?*anyopaque align(1) = null,
    dwFlags: u32 align(1) = 0,
    dwCommonButtons: u32 align(1) = 0,
    pszWindowTitle: ?[*:0]const u16 align(1) = null,
    pszMainIcon: ?*const anyopaque align(1) = null,
    pszMainInstruction: ?[*:0]const u16 align(1) = null,
    pszContent: ?[*:0]const u16 align(1) = null,
    cButtons: u32 align(1) = 0,
    pButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultButton: i32 align(1) = 0,
    cRadioButtons: u32 align(1) = 0,
    pRadioButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultRadioButton: i32 align(1) = 0,
    pszVerificationText: ?[*:0]const u16 align(1) = null,
    pszExpandedInformation: ?[*:0]const u16 align(1) = null,
    pszExpandedControlText: ?[*:0]const u16 align(1) = null,
    pszCollapsedControlText: ?[*:0]const u16 align(1) = null,
    pszFooterIcon: ?*const anyopaque align(1) = null,
    pszFooter: ?[*:0]const u16 align(1) = null,
    pfCallback: ?TaskDialogCallback align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: u32 align(1) = 0,
};

const TDF_ENABLE_HYPERLINKS: u32 = 0x0001;
const TDF_ALLOW_DIALOG_CANCELLATION: u32 = 0x0008;
const TDF_POSITION_RELATIVE_TO_WINDOW: u32 = 0x1000;
const TDN_BUTTON_CLICKED: u32 = 2;
const TDN_HYPERLINK_CLICKED: u32 = 3;
const S_OK: w32.HRESULT = 0;
const S_FALSE: w32.HRESULT = 1;

const WNDPROC = *const fn (w32.HWND, u32, usize, isize) callconv(.winapi) isize;
const WM_SYSCOMMAND: u32 = 0x0112;
const SC_CLOSE: usize = 0xF060;
const SPI_GETSCREENREADER: u32 = 0x0046;
const SPI_GETKEYBOARDCUES: u32 = 0x100A;

extern "user32" fn CallWindowProcW(
    lpPrevWndFunc: WNDPROC,
    hWnd: w32.HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.winapi) isize;
extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW(lpLibFileName: [*:0]const u16, hFile: ?*anyopaque, dwFlags: u32) callconv(.winapi) ?std.os.windows.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: std.os.windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

fn testWidth(cp: u21) u2 {
    return switch (cp) {
        0x0300...0x036F => 0,
        0x4E00...0x9FFF, 0x1F300...0x1FAFF => 2,
        else => 1,
    };
}

fn expectRows(p: *const Preview, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, p.row_count);
    for (expected, p.shown()) |want, *row| try testing.expectEqualStrings(want, p.rowText(row));
}

test "preview: line ends are marked and a trailing break starts no line" {
    var p: Preview = undefined;
    previewLines(&p, "echo hi\n", 60, 8, testWidth);
    try expectRows(&p, &.{"echo hi"});
    try testing.expect(p.rows[0].line_end);
    try testing.expectEqual(@as(usize, 1), p.lines);
    try testing.expectEqual(@as(usize, 8), p.chars);
    try testing.expect(!p.truncated);

    // CRLF, a lone CR (Enter for a shell) and an empty line.
    previewLines(&p, "a\r\nb\rc\n\n", 60, 8, testWidth);
    try expectRows(&p, &.{ "a", "b", "c", "" });
    for (p.shown()) |row| try testing.expect(row.line_end);
    try testing.expectEqual(@as(usize, 4), p.lines);

    previewLines(&p, "no break", 60, 8, testWidth);
    try expectRows(&p, &.{"no break"});
    try testing.expect(!p.rows[0].line_end);

    previewLines(&p, "", 60, 8, testWidth);
    try testing.expectEqual(@as(usize, 0), p.row_count);
    try testing.expectEqual(@as(usize, 0), p.lines);
    try testing.expectEqual(@as(usize, 0), p.chars);
    try testing.expectEqual(@as(usize, 1), previewRows(&p));
}

test "preview: control and hidden characters show and are marked" {
    var p: Preview = undefined;
    previewLines(&p, "\x1b[201~ls\x7f", 60, 8, testWidth);
    try expectRows(&p, &.{"<U+001B>[201~ls<U+007F>"});
    try testing.expectEqual(@as(u8, 2), p.rows[0].mark_count);
    try testing.expectEqual(Preview.Mark{ .start = 0, .len = 8 }, p.rows[0].marks[0]);

    previewLines(&p, "a\u{202E}b\u{2066}c\u{200B}d\u{E0041}", 60, 8, testWidth);
    try expectRows(&p, &.{"a<U+202E>b<U+2066>c<U+200B>d<U+E0041>"});
    try testing.expectEqual(@as(u8, 4), p.rows[0].mark_count);
    try testing.expectEqual(Preview.Mark{ .start = 1, .len = 8 }, p.rows[0].marks[0]);
    try testing.expectEqual(@as(usize, 8), p.chars);

    previewLines(&p, "\x1b\x1b\xff", 60, 8, testWidth);
    try expectRows(&p, &.{"<U+001B><U+001B><0xFF>"});
    try testing.expectEqual(@as(u8, 1), p.rows[0].mark_count);
    try testing.expectEqual(@as(usize, 3), p.chars);

    previewLines(&p, "\x00\x07\u{85}", 60, 8, testWidth);
    try expectRows(&p, &.{"<U+0000><U+0007><U+0085>"});
    try testing.expectEqual(@as(u8, 1), p.rows[0].mark_count);

    previewLines(&p, "caf\u{E9} \u{4E2D}\u{1F600}", 60, 8, testWidth);
    try expectRows(&p, &.{"caf\u{E9} \u{4E2D}\u{1F600}"});
    try testing.expectEqual(@as(u8, 0), p.rows[0].mark_count);
}

test "preview: tabs move to the next stop" {
    var p: Preview = undefined;
    previewLines(&p, "a\tb\tc", 60, 8, testWidth);
    try expectRows(&p, &.{"a   b   c"});
}

test "preview: long lines wrap by cells, wide characters take two" {
    var p: Preview = undefined;
    // 16 columns: 15 cells of text per row, one for the marker.
    previewLines(&p, "0123456789abcdefXYZ\n", 16, 8, testWidth);
    try expectRows(&p, &.{ "0123456789abcde", "fXYZ" });
    try testing.expect(!p.rows[0].line_end and p.rows[0].line_start);
    try testing.expect(p.rows[1].line_end and !p.rows[1].line_start);
    try testing.expectEqual(@as(usize, 1), p.lines);

    previewLines(&p, std.mem.asBytes(&@as([9]["\u{4E00}".len]u8, @splat("\u{4E00}".*))), 16, 8, testWidth);
    try expectRows(&p, &.{ std.mem.asBytes(&@as([7]["\u{4E00}".len]u8, @splat("\u{4E00}".*))), std.mem.asBytes(&@as([2]["\u{4E00}".len]u8, @splat("\u{4E00}".*))) });

    // An escape does not split across rows.
    previewLines(&p, "0123456789\u{202E}", 16, 8, testWidth);
    try expectRows(&p, &.{ "0123456789", "<U+202E>" });
    try testing.expectEqual(@as(u8, 1), p.rows[1].mark_count);
}

test "preview: text past the last row is counted, not shown" {
    var p: Preview = undefined;
    // Exactly as many lines as rows: all shown.
    previewLines(&p, "1\n2\n3\n4\n", 60, 4, testWidth);
    try expectRows(&p, &.{ "1", "2", "3", "4" });
    try testing.expect(!p.truncated);
    try testing.expectEqual(@as(usize, 0), p.hidden_lines);

    // One more: the last row is left for the "more" row.
    previewLines(&p, "1\n2\n3\n4\n5", 60, 4, testWidth);
    try expectRows(&p, &.{ "1", "2", "3" });
    try testing.expect(p.truncated);
    try testing.expectEqual(@as(usize, 2), p.hidden_lines);
    try testing.expectEqual(@as(usize, 5), p.lines);
    try testing.expectEqual(@as(usize, 9), p.chars);
    try testing.expectEqual(@as(usize, 5), previewRows(&p));

    // One long line: part of it shows, no whole line is hidden.
    previewLines(&p, std.mem.asBytes(&@as([200]["x".len]u8, @splat("x".*))), 16, 4, testWidth);
    try testing.expectEqual(@as(usize, 3), p.row_count);
    try testing.expect(p.truncated);
    try testing.expectEqual(@as(usize, 0), p.hidden_lines);
    try testing.expectEqual(@as(usize, 1), p.lines);
    try testing.expectEqual(@as(usize, 200), p.chars);

    // A wrapped line cut at the reserved row counts as hidden when none of
    // its rows remain.
    previewLines(&p, "1\n2\n3\n" ++ std.mem.asBytes(&@as([40]["y".len]u8, @splat("y".*))), 16, 4, testWidth);
    try expectRows(&p, &.{ "1", "2", "3" });
    try testing.expectEqual(@as(usize, 1), p.hidden_lines);
}

test "preview: combining marks without end stay within the row buffer" {
    var p: Preview = undefined;
    previewLines(&p, "e" ++ std.mem.asBytes(&@as([400]["\u{0301}".len]u8, @splat("\u{0301}".*))), 60, 8, testWidth);
    for (p.shown()) |row| try testing.expect(row.len <= Preview.row_bytes);
    try testing.expectEqual(@as(usize, 401), p.chars);
    try testing.expect(std.unicode.utf8ValidateSlice(p.rowText(&p.rows[0])));
}

test "preview: the dialog text shows what the box shows" {
    var p: Preview = undefined;
    previewLines(&p, "ls\n\x1b]52;c;?\x07\n", 60, 8, testWidth);
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writePreview(&writer, &p, .paste);
    const text = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "ls\u{21B5}\n<U+001B>]52;c;?<U+0007>\u{21B5}\n"));
    // No raw control character reaches the native dialog or the clipboard.
    for (text) |byte| try testing.expect(byte >= 0x20 or byte == '\n');

    previewLines(&p, "", 60, 8, testWidth);
    writer = .fixed(&buf);
    writePreview(&writer, &p, .read);
    try testing.expectEqualStrings(emptyText(.read), writer.buffered());
    try testing.expect(!std.mem.eql(u8, emptyText(.read), emptyText(.write)));
}

test "hidden characters cover bidi controls and invisibles, not text" {
    for ([_]u21{ 0x202A, 0x202E, 0x2066, 0x2069, 0x200B, 0x200C, 0x200D, 0x200E, 0xFEFF, 0x2028, 0x85, 0xE0001 }) |cp| {
        try testing.expect(isHidden(cp));
    }
    for ([_]u21{ 'a', 0xFE0F, 0x4E2D, 0x1F600, 0xA0 }) |cp| {
        try testing.expect(!isHidden(cp));
    }
    var p: Preview = undefined;
    previewLines(&p, "a\u{200C}\u{200D}b", 60, 8, testWidth);
    try expectRows(&p, &.{"a<U+200C><U+200D>b"});
    try testing.expectEqual(@as(u8, 1), p.rows[0].mark_count);
}

test "process list: flat, by tab, and cut with a count" {
    const few = listRows(&.{ "vim", "PING" }, &.{});
    try testing.expectEqual(@as(usize, 2), few.count);
    try testing.expectEqual(@as(usize, 0), few.more);

    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    const many = listRows(&names, &.{});
    try testing.expectEqual(@as(usize, max_list_rows - 1), many.count);
    try testing.expectEqual(@as(usize, names.len - (max_list_rows - 1)), many.more);
    // Exactly as many as fit: no "more" row.
    try testing.expectEqual(@as(usize, 0), listRows(names[0..max_list_rows], &.{}).more);

    const groups = [_]ProcessGroup{
        .{ .title = "build", .processes = &.{ "cargo", "rustc" } },
        .{ .title = "idle", .processes = &.{} },
        .{ .title = "logs", .processes = &.{"tail"} },
    };
    const by_tab = listRows(&.{}, &groups);
    try testing.expectEqual(@as(usize, 5), by_tab.count);
    try testing.expect(by_tab.rows[0].header and std.mem.eql(u8, "build", by_tab.rows[0].text));
    try testing.expect(by_tab.rows[3].header and std.mem.eql(u8, "logs", by_tab.rows[3].text));
    try testing.expectEqual(@as(usize, 0), by_tab.more);

    // Too many: no title is left without a process under it.
    const big = [_]ProcessGroup{
        .{ .title = "one", .processes = &.{ "a", "b", "c" } },
        .{ .title = "two", .processes = &.{ "d", "e" } },
        .{ .title = "three", .processes = &.{ "f", "g" } },
    };
    const cut = listRows(&.{}, &big);
    try testing.expectEqual(@as(usize, max_list_rows - 1), cut.count);
    try testing.expect(!cut.rows[cut.count - 1].header);
    var shown: usize = 0;
    for (cut.rows[0..cut.count]) |row| shown += @intFromBool(!row.header);
    try testing.expectEqual(@as(usize, 7), shown + cut.more);
}

test "the task dialog structures have the packed commctrl layout" {
    // Eight 32-bit fields and sixteen pointer-sized ones, no padding
    // (160 bytes on x64, as `sizeof(TASKDIALOGCONFIG)` in the SDK).
    const p = @sizeOf(usize);
    try testing.expectEqual(@as(usize, 32 + 16 * p), @sizeOf(TASKDIALOGCONFIG));
    try testing.expectEqual(@as(usize, 4 + p), @sizeOf(TASKDIALOG_BUTTON));
    try testing.expectEqual(@as(usize, 4), @offsetOf(TASKDIALOGCONFIG, "hwndParent"));
    try testing.expectEqual(@as(usize, 12 + 6 * p), @offsetOf(TASKDIALOGCONFIG, "cButtons"));
    try testing.expectEqual(@as(usize, 28 + 8 * p), @offsetOf(TASKDIALOGCONFIG, "pszVerificationText"));
    try testing.expectEqual(@as(usize, 28 + 14 * p), @offsetOf(TASKDIALOGCONFIG, "pfCallback"));
    try testing.expectEqual(@as(usize, 28 + 16 * p), @offsetOf(TASKDIALOGCONFIG, "cxWidth"));
}

test "button labels keep their ampersands" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Save && Quit", escapeAmpersands(&buf, "Save & Quit"));
    try testing.expectEqualStrings("Paste Anyway", escapeAmpersands(&buf, "Paste Anyway"));
    // Cut to the buffer, never between the two halves of "&&".
    var three: [3]u8 = undefined;
    try testing.expectEqualStrings("a&&", escapeAmpersands(&three, "a&b"));
    var two: [2]u8 = undefined;
    try testing.expectEqualStrings("a", escapeAmpersands(&two, "a&b"));
}

test "GHOSTTY_GX_A11Y asks for screen reader behavior" {
    try testing.expect(isScreenReaderValue("screen-reader"));
    try testing.expect(isScreenReaderValue(" Screen-Reader\n"));
    try testing.expect(!isScreenReaderValue(""));
    try testing.expect(!isScreenReaderValue("1"));
}

test "clipboard remembers only explicit checked allow or deny" {
    inline for (.{ Choice.accept, Choice.cancel }) |choice| {
        try testing.expect(clipboardAnswer(.{ .choice = choice, .checked = true, .explicit = true }, true).remember);
        try testing.expect(!clipboardAnswer(.{ .choice = choice, .checked = true }, true).remember);
        try testing.expect(!clipboardAnswer(.{ .choice = choice, .explicit = true }, true).remember);
        try testing.expect(!clipboardAnswer(.{ .choice = choice, .checked = true, .explicit = true }, false).remember);
    }
}

test {
    std.testing.refAllDecls(@This());
}
