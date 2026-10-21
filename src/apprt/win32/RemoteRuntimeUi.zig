//! The terminal runtime hints of a remote pane, shown on the target window
//! that holds the pane: the read-only notice, the key sequence and key table
//! hints, OSC 9;4 progress on the tab and the taskbar button, the bell and
//! notification of a finished command and the hovered-link bubble. The
//! source sends owned values (`protocol.RuntimeEvent`); each takes the effect
//! of the matching local action in `App.performAction`, gated by this app's
//! configuration, and `handle` returns true only when something was shown,
//! hidden or changed. Nothing here touches the source's hidden windows.
//!
//! `RemotePaneUi` embeds this struct as `runtime`. The hints remember the
//! window they went to by reference (and the toast owner by value), so
//! `hide` and `onReparented` reach them without the pane or a borrowed
//! window pointer: `RemotePane` calls `hide` when the pane hides, is
//! disconnected or drops to its coordinator reference, `onReparented`
//! before it moves to another window, and `deinit` frees the link bubble.
//! GUI thread only.
const Self = @This();

const std = @import("std");
const App = @import("App.zig");
const RemotePane = @import("RemotePane.zig");
const Window = @import("Window.zig");
const LinkPreview = @import("ui/LinkPreview.zig");
const Notice = @import("ui/Notice.zig");
const Toast = @import("ui/Toast.zig");
const d2d = @import("ui/d2d.zig");
const w32 = @import("win32.zig");
const tab_status = @import("tab_status.zig");
const Config = @import("../../config/Config.zig");
const protocol = @import("../../gx/remote_protocol.zig");
const refs = @import("../../gx/ui_ref.zig");
const i18n = @import("../../gx/i18n.zig");

/// The app of the pane, from the first event: `hide` and `onReparented`
/// find the windows of earlier hints through it.
app: ?*App = null,
/// The pane's identity in a window's toast (`Toast.Owner.surface_id`),
/// derived from its stable `ui_reference` (`ownerId`).
owner_id: u64 = 0,
/// The windows the sequence and table hints and the read-only notice were
/// posted to; invalid when none shows.
sequence_window: refs.Reference = .{},
table_window: refs.Reference = .{},
readonly_window: refs.Reference = .{},
link_preview: LinkPreview = .{},

/// Free the link bubble. Toasts and the notice belong to their windows.
pub fn deinit(self: *Self) void {
    self.link_preview.deinit();
    self.* = .{};
}

/// The pane hid, was disconnected or left its windows: hide its link
/// bubble and its key hints, wherever they went. A later event shows them
/// again; this never does. The read-only notice stays, like a local one.
pub fn hide(self: *Self) void {
    self.link_preview.hide();
    _ = self.hideHint(&self.sequence_window, .sequence);
    _ = self.hideHint(&self.table_window, .table);
}

/// The pane is about to move to another window: everything it showed in
/// the old one closes, and the link bubble's popup (owned by the old
/// window) goes, to be created again for the new one.
pub fn onReparented(self: *Self) void {
    self.hide();
    self.link_preview.deinit();
    _ = self.closeReadonly();
}

/// Apply `event` from the source of `pane` on the pane's current window.
/// True when it was shown, hidden or recorded.
pub fn handle(self: *Self, app: *App, pane: *RemotePane, event: protocol.RuntimeEvent) !bool {
    self.app = app;
    self.owner_id = ownerId(pane.ui_reference);
    return switch (event) {
        .readonly => |on| self.readonly(app, pane, on),
        .key_sequence => |*value| self.keySequence(app, pane, if (value.*) |*keys| keys.slice() else null),
        .key_table => |*name| self.keyTable(app, pane, name.slice()),
        .progress => |value| progress(app, pane, value.state, value.progress),
        .command_finished => |value| commandFinished(app, pane, value.exit_code, value.duration_ns),
        .mouse_over_link => |*url| self.mouseOverLink(pane, url.slice()),
    };
}

/// The longest toast text (`Toast.text`).
const toast_text_max = 256;

/// The toast owner value of a pane: a hash of its whole `ui_reference`,
/// so a reused serial of another epoch or generation is another owner.
pub fn ownerId(reference: refs.Reference) u64 {
    var hasher = std.hash.Wyhash.init(0x67785f72656d6f74);
    hasher.update(std.mem.asBytes(&reference.epoch));
    const kind: u64 = @backingInt(reference.kind);
    hasher.update(std.mem.asBytes(&kind));
    hasher.update(std.mem.asBytes(&reference.id));
    hasher.update(std.mem.asBytes(&reference.generation));
    return hasher.final();
}

/// A window of `app` that shows feedback for `reference`, not closing.
/// Hidden source host windows are never target UI, so only the app's
/// windows and the Quick Terminal count.
fn findWindow(app: *App, reference: refs.Reference) ?*Window {
    if (!reference.isValid()) return null;
    for (app.windows.items) |window| {
        if (!window.closing and reference.matches(window.ui_reference)) return window;
    }
    if (app.quick_terminal) |quick| {
        if (!quick.window.closing and reference.matches(quick.window.ui_reference)) return quick.window;
    }
    return null;
}

/// Whether `window` can show a notice or a toast now.
fn canShow(app: *App, window: *Window) bool {
    return window.hwnd != null and !window.closing and app.uiFactory() != null;
}

fn toastOwner(self: *const Self, kind: @FieldType(Toast.Owner, "kind")) Toast.Owner {
    return .{ .surface_id = self.owner_id, .kind = kind };
}

/// Hide the `kind` hint of this pane in the window `where` names, if it
/// still shows there; forget the window. True when one was hidden.
fn hideHint(self: *Self, where: *refs.Reference, kind: @FieldType(Toast.Owner, "kind")) bool {
    const reference = where.*;
    where.* = .{};
    const app = self.app orelse return false;
    const window = findWindow(app, reference) orelse return false;
    const owner = self.toastOwner(kind);
    const current = window.toast.owner orelse return false;
    if (!std.meta.eql(current, owner)) return false;
    window.toast.hideOwned(owner);
    return true;
}

/// Show the `kind` hint `text` in the pane's window, after hiding one this
/// pane left in another window.
fn postHint(self: *Self, app: *App, pane: *RemotePane, where: *refs.Reference, kind: @FieldType(Toast.Owner, "kind"), text: []const u8) bool {
    const window = pane.parent_window;
    if (!where.matches(window.ui_reference)) _ = self.hideHint(where, kind);
    if (!pane.visible or !canShow(app, window)) return false;
    window.postToast(.{ .text = text, .icon = d2d.icons.keyboard, .duration_ms = null, .owner = self.toastOwner(kind) });
    where.* = window.ui_reference;
    return true;
}

/// `key_sequence`: the formatted keys so far followed by "…", or none to
/// end the hint, as `App.showKeySequence` shows them.
fn keySequence(self: *Self, app: *App, pane: *RemotePane, keys: ?[]const u8) bool {
    const value = keys orelse return self.hideHint(&self.sequence_window, .sequence);
    if (value.len == 0) return self.hideHint(&self.sequence_window, .sequence);
    var buf: [toast_text_max]u8 = undefined;
    return self.postHint(app, pane, &self.sequence_window, .sequence, sequenceHint(&buf, value));
}

/// `keys` and " …" in `buf`, cutting `keys` at a UTF-8 boundary so both fit.
pub fn sequenceHint(buf: []u8, keys: []const u8) []const u8 {
    const suffix = " \u{2026}";
    if (buf.len < suffix.len) return buf[0..0];
    const kept = utf8Prefix(keys[0..@min(keys.len, buf.len - suffix.len)]);
    @memcpy(buf[0..kept.len], kept);
    @memcpy(buf[kept.len..][0..suffix.len], suffix);
    return buf[0 .. kept.len + suffix.len];
}

/// `key_table`: "Key table {name}" for the top table, or none (empty) to
/// end the hint, as `App.showKeyTable` shows it.
fn keyTable(self: *Self, app: *App, pane: *RemotePane, name: []const u8) bool {
    if (name.len == 0) return self.hideHint(&self.table_window, .table);
    var buf: [toast_text_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    i18n.format(&writer, i18n.tr("Key table {name}"), .{ .name = utf8Prefix(name[0..@min(name.len, 160)]) }) catch {};
    return self.postHint(app, pane, &self.table_window, .table, utf8Prefix(writer.buffered()));
}

/// The longest prefix of `bytes` that ends on a UTF-8 boundary: `bytes`
/// is valid UTF-8 cut anywhere.
pub fn utf8Prefix(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
    return bytes[0..end];
}

/// Marks the read-only notice of a remote pane (`readonlyShows`). It does
/// not read `ctx`: the notice can outlive its pane.
fn readonlyClosed(ctx: *anyopaque, notice: *Notice, reason: Notice.CloseReason) void {
    _ = ctx;
    _ = notice;
    _ = reason;
}

/// Whether `window` shows (or is about to show) this pane's read-only notice.
fn readonlyShows(self: *Self, window: *Window) bool {
    const callbacks = window.notice.callbacks orelse return false;
    const closed = callbacks.closed orelse return false;
    return closed == &readonlyClosed and callbacks.ctx == @as(*anyopaque, self) and
        (window.notice.popup.visible or window.notice.pending);
}

/// Close this pane's read-only notice, wherever it went. True when one closed.
fn closeReadonly(self: *Self) bool {
    const reference = self.readonly_window;
    self.readonly_window = .{};
    const app = self.app orelse return false;
    const window = findWindow(app, reference) orelse return false;
    if (!self.readonlyShows(window)) return false;
    window.hideNotice();
    return true;
}

/// `readonly`: a notice says what read-only means; leaving it closes that
/// notice and confirms in a toast (`App.showReadonly`).
fn readonly(self: *Self, app: *App, pane: *RemotePane, on: bool) bool {
    const window = pane.parent_window;
    if (!self.readonly_window.matches(window.ui_reference) or !on) {
        _ = self.closeReadonly();
    }
    if (!canShow(app, window)) return false;
    if (on) {
        window.postNotice(.{
            .title = i18n.tr("Read-only"),
            .body = i18n.tr("This terminal is in read-only mode. You can still view, select, and scroll through the content, but no input events will be sent to the running application."),
            .duration_ms = null,
        }, .{ .ctx = self, .closed = readonlyClosed });
        self.readonly_window = window.ui_reference;
    } else {
        window.postToast(.{ .text = i18n.tr("Read-only mode is off"), .icon = d2d.icons.check_mark });
    }
    return true;
}

/// The progress an OSC 9;4 state on the wire reports (remove, set, error,
/// indeterminate, pause), or null for an unknown state.
pub fn progressReport(state: u8, percent: ?u8, now_ms: u64) ?tab_status.Progress {
    const value: tab_status.ProgressState = switch (state) {
        0 => .none,
        1 => .normal,
        2 => .@"error",
        3 => .indeterminate,
        4 => .paused,
        else => return null,
    };
    return .{ .state = value, .percent = if (percent) |p| @min(p, 100) else null, .updated_ms = now_ms };
}

/// `progress_report`: keep the report as the pane's latest for its tab,
/// repaint the tab bar when it changed and show the window's progress on
/// its taskbar button (`Window.setSurfaceProgress`). Gated on
/// `progress-style`.
fn progress(app: *App, pane: *RemotePane, state: u8, percent: ?u8) bool {
    if (!app.config.@"progress-style") return false;
    const report = progressReport(state, percent, GetTickCount64()) orelse return false;
    const previous = pane.metadata.progress;
    pane.metadata.progress = report;
    const window = pane.parent_window;
    const changed = report.state != previous.state or !std.meta.eql(report.percent, previous.percent);
    if (changed and window.leafForPane(pane.ui_reference) != null) window.invalidateTabBar();
    app.updateTaskbarProgress(window);
    return true;
}

/// Whether a finished command is announced (`notify-on-command-finish`,
/// `notify-on-command-finish-after`): a focused pane announces only with
/// `always`, and only a command that ran longer than the threshold.
pub fn announcesCommand(mode: Config.NotifyOnCommandFinish, focused: bool, duration: Config.Duration, after: Config.Duration) bool {
    switch (mode) {
        .never => return false,
        .unfocused => if (focused) return false,
        .always => {},
    }
    return !duration.lte(after);
}

/// `command_finished`: ring the bell and/or show a desktop notification,
/// as `notify-on-command-finish-action` asks. The notification names the
/// pane, so clicking it brings the pane forward.
fn commandFinished(app: *App, pane: *RemotePane, exit_code: ?u8, duration_ns: u64) bool {
    const duration: Config.Duration = .{ .duration = duration_ns };
    if (!announcesCommand(app.config.@"notify-on-command-finish", pane.focused, duration, app.config.@"notify-on-command-finish-after")) return false;
    const act = app.config.@"notify-on-command-finish-action";
    var performed = false;
    if (act.bell) performed = ringBell(pane);
    if (act.notify) {
        const title: []const u8 = if (exit_code) |code|
            (if (code == 0) i18n.tr("Command succeeded") else i18n.tr("Command failed"))
        else
            i18n.tr("Command finished");
        var duration_buf: [32]u8 = undefined;
        const text = std.mem.print(&duration_buf, "{f}", .{duration.round(std.time.ns_per_ms)}) catch "";
        var body_buf: [256]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buf);
        if (exit_code) |code| {
            i18n.format(&body, i18n.tr("Command took {duration} and exited with code {code}."), .{ .duration = text, .code = code }) catch {};
        } else {
            i18n.format(&body, i18n.tr("Command took {duration}."), .{ .duration = text }) catch {};
        }
        if (app.showLegacyDesktopNotification(pane.ui_reference, title, utf8Prefix(body.buffered()))) performed = true;
    }
    return performed;
}

/// The bell of a remote pane as `bell-features` asks, the target's half
/// of `App.ringBell` for a BEL of its source (`RemotePane.ringBell`) or a
/// finished command: the system sound, the `bell-audio-path` sound, the
/// tab badge and the taskbar flash, the bell mark on the tab and the bell
/// border (`RemotePane.ringBellBorder`). True when any of them happened.
pub fn ringBell(pane: *RemotePane) bool {
    const app = pane.app;
    const features = app.config.@"bell-features";
    var rang = false;
    if (features.system and w32.MessageBeep(0xFFFFFFFF) != 0) rang = true;
    if (features.audio and app.config.@"bell-audio-path" != null) {
        app.playBellAudio();
        rang = true;
    }
    const window = pane.parent_window;
    if (window.leafForPane(pane.ui_reference)) |leaf| {
        if (features.attention) {
            window.onBell(leaf);
            flashTaskbarButton(window);
            rang = true;
        }
        if (features.title) {
            window.ringTab(leaf);
            rang = true;
        }
    }
    if (features.border) {
        pane.ringBellBorder();
        if (pane.bell_border_state.ringing) rang = true;
    }
    return rang;
}

/// Flash the taskbar button of `window` until it comes to the front,
/// unless it is the foreground window (`App.flashTaskbarButton`).
fn flashTaskbarButton(window: *Window) void {
    const hwnd = window.hwnd orelse return;
    if (w32.GetForegroundWindow() == hwnd) return;
    var info: w32.FLASHWINFO = .{
        .cbSize = @sizeOf(w32.FLASHWINFO),
        .hwnd = hwnd,
        .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
        .uCount = 2,
        .dwTimeout = 0,
    };
    _ = w32.FlashWindowEx(&info);
}

/// `mouse_over_link`: the hovered URL in a bubble on the pane, or none to
/// hide it after a short delay (`Surface.setMouseOverLink`).
fn mouseOverLink(self: *Self, pane: *RemotePane, url: []const u8) bool {
    if (url.len == 0) {
        const shown = self.link_preview.isShown();
        self.link_preview.showRemote(pane, url);
        return shown;
    }
    if (!pane.visible or !pane.ready()) {
        self.link_preview.hide();
        return false;
    }
    self.link_preview.showRemote(pane, url);
    return self.link_preview.isShown();
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

test "remote progress maps the OSC 9;4 wire states and clamps the percent" {
    const testing = std.testing;
    try testing.expectEqual(tab_status.ProgressState.none, progressReport(0, null, 1).?.state);
    try testing.expectEqual(tab_status.ProgressState.normal, progressReport(1, 40, 1).?.state);
    try testing.expectEqual(tab_status.ProgressState.@"error", progressReport(2, null, 1).?.state);
    try testing.expectEqual(tab_status.ProgressState.indeterminate, progressReport(3, null, 1).?.state);
    try testing.expectEqual(tab_status.ProgressState.paused, progressReport(4, 7, 1).?.state);
    try testing.expectEqual(@as(?u8, 100), progressReport(1, 250, 1).?.percent);
    try testing.expectEqual(@as(u64, 9), progressReport(1, null, 9).?.updated_ms);
    try testing.expect(progressReport(5, null, 1) == null);
}

test "remote command announcements follow the local configuration gates" {
    const testing = std.testing;
    const after: Config.Duration = .{ .duration = 5 * std.time.ns_per_s };
    const long: Config.Duration = .{ .duration = 6 * std.time.ns_per_s };
    try testing.expect(!announcesCommand(.never, false, long, after));
    try testing.expect(announcesCommand(.unfocused, false, long, after));
    try testing.expect(!announcesCommand(.unfocused, true, long, after));
    try testing.expect(announcesCommand(.always, true, long, after));
    try testing.expect(!announcesCommand(.always, false, after, after));
}

test "remote key hints keep whole UTF-8 characters within the toast text" {
    const testing = std.testing;
    var buf: [toast_text_max]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+A \u{2192} B \u{2026}", sequenceHint(&buf, "Ctrl+A \u{2192} B"));
    const long = std.mem.asBytes(&@as([120]["\u{2192}".len]u8, @splat("\u{2192}".*)));
    const hint = sequenceHint(&buf, long);
    try testing.expect(hint.len <= buf.len);
    try testing.expect(std.unicode.utf8ValidateSlice(hint));
    try testing.expect(std.mem.endsWith(u8, hint, " \u{2026}"));
    try testing.expectEqualStrings("", sequenceHint(buf[0..2], "abc"));
    try testing.expectEqualStrings("a\u{00e9}", utf8Prefix("a\u{00e9}\xe2\x86"));
}

test "remote toast owners differ by every part of the pane identity" {
    const testing = std.testing;
    const base: refs.Reference = .{ .epoch = 7, .kind = .surface, .id = 3, .generation = 1 };
    var other = base;
    other.generation = 2;
    try testing.expect(ownerId(base) != ownerId(other));
    other = base;
    other.epoch = 8;
    try testing.expect(ownerId(base) != ownerId(other));
    try testing.expectEqual(ownerId(base), ownerId(base));
}
