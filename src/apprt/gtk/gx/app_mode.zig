//! The periodic work of the GX layer on GTK windows (fork patch GX-0016),
//! on one timer for the whole application:
//!
//! - herdr app mode. While the only tab of a window runs herdr (see
//!   `src/gx/app_mode.zig`) and `gx-herdr-app-mode` is on,
//!   `Window.getTabsVisible` hides the tab bar, so herdr looks like a
//!   standalone application. With `gtk-titlebar-style = tabs` the tab bar
//!   also holds the window controls, the new tab button and the main menu,
//!   so `Window.getHeaderbarVisible` shows the header bar in its place and
//!   the window stays usable. A window enters app mode once two checks in
//!   a row find herdr (`gx.app_mode.State`) and leaves it at the first
//!   check that does not.
//! - Unread marks. A tab that is not shown gets `needs-attention` when one
//!   of its terminals prints something new (`gx.unread`); libadwaita draws
//!   a line under the tab, and selecting the tab clears it.
//! - The kind of program in the foreground (`gx.leader`). A tab running a
//!   remote session, a superuser shell or a container shows an icon, and
//!   the window has the `gx-remote` or `gx-superuser` style class while
//!   its selected tab runs one of the first two.
//!
//! Checking the programs reads the name of each terminal's foreground
//! process, and lists the processes (one `gx.proc.Shared` table for every
//! window) only when that name is neither herdr nor a shell. Checks run
//! `gx.app_mode.min_delay_ms` after a terminal title change, a key press,
//! a tab or split change, a window shown or activated, or a configuration
//! change. While a window with a single tab has herdr app mode enabled,
//! they repeat at `gx.app_mode.nextDelay`, backing off to every 10 s while
//! nothing changes, and stop once herdr is confirmed. Disabled app mode
//! needs no timer; program icons follow events. Unread checks run every second while a
//! window has several tabs. Hidden, minimized and suspended windows are
//! skipped, and the timer stops when no shown window needs it.
//!
//! Progress reports on tabs are in `progress.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;
const progress = @import("progress.zig");

const log = std.log.scoped(.gtk_gx_app_mode);

const min_delay_ms = gx.app_mode.min_delay_ms;
const max_delay_ms = gx.app_mode.max_delay_ms;

/// How often the unread marks of a window with several tabs are checked.
pub const unread_interval_ms: u32 = 1000;

/// A check due within this many milliseconds runs now.
const slack_ms = 10;

/// The state of a window, kept in its private data. GObject zero-fills
/// private data, so every field is zero by default.
pub const AppMode = struct {
    /// Whether the window is in herdr app mode.
    active: bool = false,

    /// Checks in a row that found herdr while not `active`.
    hits: u8 = 0,

    /// The window, once it is in `scheduler.windows` with its handlers.
    window: ?*Window = null,

    /// When the kind of every tab's program is read again even if its
    /// foreground process did not change, in monotonic milliseconds.
    leaders_at: i64 = 0,

    /// Set by `deinit`; later notifications from the disposing window are
    /// ignored so that they cannot schedule it again.
    disposed: bool = false,

    /// Updates tab state and schedules a coalesced program check. The
    /// boolean argument is retained for the existing GX-0016 hook;
    /// process scans now happen only in the shared timeout.
    pub fn update(self: *AppMode, window: *Window, _: bool) void {
        if (self.disposed) return;
        self.register(window);
        if (!appModeEnabled(window) or tabCount(window) != 1) {
            var check: Check = .init();
            defer check.deinit();
            _ = self.evaluate(window, &check, false);
        }
        if (shown(window)) syncUnread(window);
        progress.syncWindow(window);
        request(window);
    }

    /// Takes the window off the timer for good. Call it when the window
    /// is disposed, before its children are.
    pub fn deinit(self: *AppMode) void {
        if (self.disposed) return;
        self.disposed = true;
        const window = self.window orelse return;
        self.window = null;
        unregister(window);
    }

    fn register(self: *AppMode, window: *Window) void {
        if (self.window != null) return;
        scheduler.windows.append(Application.default().allocator(), window) catch |err| {
            log.warn("cannot schedule checks for a window err={}", .{err});
            return;
        };
        self.window = window;
        connectWindow(window);
    }

    /// Re-evaluates herdr app mode, notifying `tabs-visible` and
    /// `headerbar-visible` when it changes. Returns whether the checks
    /// should not back off: the mode changed, or herdr was found but the
    /// window has not entered app mode yet.
    fn evaluate(self: *AppMode, window: *Window, check: *Check, scan: bool) bool {
        const enabled = appModeEnabled(window);
        const tabs = tabCount(window);
        const answers = [_]?bool{if (enabled and tabs == 1) runsHerdr(window, check, scan) else false};
        var state: gx.app_mode.State = .{ .active = self.active, .hits = self.hits };
        const active = state.update(enabled, tabs, &answers);
        self.hits = state.hits;
        if (active == self.active) return state.pending();
        self.active = active;
        log.info("herdr app mode {s}", .{if (active) "on" else "off"});
        const object = window.as(gobject.Object);
        object.notify("tabs-visible");
        object.notify("headerbar-visible");
        return true;
    }

    /// Reads the kind of every tab's foreground program, setting the tab
    /// icons and the window classes. A tab whose foreground process did
    /// not change keeps its kind, except every `max_delay_ms`.
    fn checkLeaders(self: *AppMode, window: *Window, check: *Check, now: i64) void {
        const force = now >= self.leaders_at;
        if (force) self.leaders_at = now + max_delay_ms;
        const view = window.getTabView();
        const selected = view.getSelectedPage();
        var kind: gx.leader.Kind = .local;
        for (0..tabCount(window)) |i| {
            const page = view.getNthPage(@intCast(i));
            const page_kind = pageKind(page, check, force);
            if (page == selected) kind = page_kind;
        }
        setWindowKind(window, kind);
    }
};

/// Re-evaluates herdr app mode when the title of `surface` changes and
/// watches its progress reports. `Window.connectSurfaceHandlers` calls
/// this for every surface; the title handler is disconnected with the
/// window's other surface handlers.
pub fn connectSurface(window: *Window, surface: *Surface) void {
    _ = gobject.Object.signals.notify.connect(
        surface,
        *Window,
        surfaceNotifyTitle,
        window,
        .{ .detail = "title" },
    );
    progress.watch(surface);
}

fn surfaceNotifyTitle(_: *Surface, _: *gobject.ParamSpec, window: *Window) callconv(.c) void {
    if (window.gxAppMode().disposed) return;
    request(window);
}

const window_properties = [_][:0]const u8{ "config", "visible", "suspended", "is-active", "active-surface" };

fn connectWindow(window: *Window) void {
    for (window_properties) |property| {
        _ = gobject.Object.signals.notify.connect(
            window.as(gobject.Object),
            *Window,
            windowNotify,
            window,
            .{ .detail = property },
        );
    }
    _ = gtk.Widget.signals.map.connect(window.as(gtk.Widget), *Window, windowMap, window, .{});
    _ = gtk.Widget.signals.unmap.connect(window.as(gtk.Widget), *Window, windowMap, window, .{});

    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Window, keyPressed, window, .{});
    window.as(gtk.Widget).addController(keys.as(gtk.EventController));
}

fn windowNotify(_: *gobject.Object, _: *gobject.ParamSpec, window: *Window) callconv(.c) void {
    window.gxAppMode().update(window, false);
}

fn windowMap(_: *gtk.Widget, window: *Window) callconv(.c) void {
    if (window.gxAppMode().disposed) return;
    if (window.as(gtk.Native).getSurface()) |surface| {
        const object = surface.as(gobject.Object);
        const key = "gx-toplevel-watch";
        if (object.getData(key) == null) {
            object.setData(key, @ptrFromInt(1));
            for ([_][:0]const u8{ "state", "mapped" }) |property| {
                _ = gobject.Object.signals.notify.connect(object, *Window, windowNotify, window, .{ .detail = property });
            }
        }
    }
    window.gxAppMode().update(window, false);
}

fn keyPressed(
    _: *gtk.EventControllerKey,
    _: c_uint,
    _: c_uint,
    _: gdk.ModifierType,
    window: *Window,
) callconv(.c) c_int {
    if (!window.gxAppMode().disposed) request(window);
    return @intFromBool(false);
}

fn shouldPoll(enabled: bool, tabs: usize, active: bool, visible: bool) bool {
    return visible and enabled and tabs == 1 and !active;
}

/// When the timer checks what, in monotonic milliseconds.
pub const Timeline = struct {
    /// The delay between periodic program checks (`gx.app_mode.nextDelay`).
    delay_ms: u32 = min_delay_ms,

    /// The next program check, if one is scheduled.
    check_at: ?i64 = null,

    /// The next unread check, if one is scheduled.
    unread_at: ?i64 = null,

    /// Something that can start or stop a program happened at `now`: check
    /// the programs within `min_delay_ms` and restart the backoff.
    pub fn reset(self: *Timeline, now: i64) void {
        self.delay_ms = min_delay_ms;
        const at = now + min_delay_ms;
        self.check_at = if (self.check_at) |current| @min(current, at) else at;
    }

    pub fn checkDue(self: Timeline, now: i64) bool {
        return due(self.check_at, now);
    }

    pub fn unreadDue(self: Timeline, now: i64) bool {
        return due(self.unread_at, now);
    }

    /// The programs were checked at `now`. `poll` says that a shown window
    /// needs periodic checks (app mode enabled, one tab, no confirmed herdr);
    /// `changed` that a check changed the mode of a window or found herdr
    /// without entering app mode yet, which keeps the checks frequent.
    pub fn checked(self: *Timeline, now: i64, poll: bool, changed: bool) void {
        if (!poll) {
            self.check_at = null;
            return;
        }
        self.delay_ms = gx.app_mode.nextDelay(self.delay_ms, changed);
        self.check_at = now + self.delay_ms;
    }

    /// A tick at `now`: `needed` says that a shown window has several tabs,
    /// `checked` that this tick checked their unread marks.
    pub fn unread(self: *Timeline, now: i64, needed: bool, checked_now: bool) void {
        if (!needed) {
            self.unread_at = null;
            return;
        }
        if (checked_now or self.unread_at == null) self.unread_at = now + unread_interval_ms;
    }

    /// When the timer fires next, or null when nothing is scheduled.
    pub fn next(self: Timeline) ?i64 {
        const check = self.check_at orelse return self.unread_at;
        const unread_at = self.unread_at orelse return check;
        return @min(check, unread_at);
    }

    fn due(at: ?i64, now: i64) bool {
        const time = at orelse return false;
        return time <= now + slack_ms;
    }
};

/// The app-wide timer and the windows it serves. Only the main thread
/// touches it.
const Scheduler = struct {
    windows: std.ArrayList(*Window) = .empty,
    timeline: Timeline = .{},

    /// The pending timeout, 0 when there is none.
    source: c_uint = 0,

    /// When `source` fires, in monotonic milliseconds.
    source_at: i64 = 0,

    /// The process table that the program checks of every window share.
    shared: gx.proc.Shared = .{},
};

var scheduler: Scheduler = .{};

fn request(window: *Window) void {
    if (scheduler.windows.items.len == 0) return;
    const now = nowMs();
    const self = window.gxAppMode();
    self.leaders_at = 0;
    if (shown(window)) {
        if (appModeEnabled(window) and tabCount(window) == 1) {
            scheduler.timeline.reset(now);
        } else {
            var check: Check = .init();
            defer check.deinit();
            self.checkLeaders(window, &check, now);
        }
    }
    reconcile(now);
}

fn reconcile(now: i64) void {
    var eligible = false;
    var poll = false;
    var several = false;
    for (scheduler.windows.items) |window| {
        if (!shown(window)) continue;
        const tabs = tabCount(window);
        const enabled = appModeEnabled(window);
        eligible = eligible or (enabled and tabs == 1);
        poll = poll or shouldPoll(enabled, tabs, window.gxAppMode().active, true);
        several = several or tabs >= 2;
    }
    if (!eligible) scheduler.timeline.check_at = null;
    if (poll and scheduler.timeline.check_at == null) scheduler.timeline.reset(now);
    scheduler.timeline.unread(now, several, false);
    if (scheduler.timeline.check_at == null) scheduler.shared.invalidate();
    reschedule(now);
}

fn unregister(window: *Window) void {
    const windows = &scheduler.windows;
    for (windows.items, 0..) |item, i| {
        if (item != window) continue;
        _ = windows.swapRemove(i);
        break;
    }
    if (windows.items.len > 0) return reconcile(nowMs());
    windows.deinit(Application.default().allocator());
    windows.* = .empty;
    cancel();
    scheduler.timeline = .{};
    scheduler.shared.invalidate();
}

fn reschedule(now: i64) void {
    const at = scheduler.timeline.next() orelse return cancel();
    if (scheduler.source != 0 and scheduler.source_at <= at) return;
    cancel();
    const delay: c_uint = @intCast(std.math.clamp(at - now, 0, std.math.maxInt(i32)));
    scheduler.source = glib.timeoutAdd(delay, tick, null);
    scheduler.source_at = now + delay;
}

fn cancel() void {
    if (scheduler.source == 0) return;
    if (glib.Source.remove(scheduler.source) == 0) log.warn("unable to remove the GX check timer", .{});
    scheduler.source = 0;
}

fn tick(_: ?*anyopaque) callconv(.c) c_int {
    scheduler.source = 0;
    const io = global.io();
    const span: gx.perf.Span = .begin(io);
    const now = nowMs();
    const timeline = &scheduler.timeline;
    const programs = timeline.checkDue(now);
    const unread = timeline.unreadDue(now);
    const captures = scheduler.shared.captures;

    var check: Check = .init();
    defer check.deinit();
    var poll = false;
    var several = false;
    var changed = false;
    var shown_windows: usize = 0;
    for (scheduler.windows.items) |window| {
        if (!shown(window)) continue;
        shown_windows += 1;
        const self = window.gxAppMode();
        const tabs = tabCount(window);
        if (tabs >= 2) several = true;
        if (programs and self.evaluate(window, &check, true)) changed = true;
        poll = poll or shouldPoll(appModeEnabled(window), tabs, self.active, true);
        if (programs or unread) self.checkLeaders(window, &check, now);
        if (unread and tabs >= 2) checkUnread(window);
    }
    if (programs) timeline.checked(now, poll, changed);
    timeline.unread(now, several, unread);

    if (timeline.check_at) |at| {
        if (at - now >= gx.proc.Shared.default_ttl_ms) scheduler.shared.invalidate();
    } else scheduler.shared.invalidate();

    reschedule(now);
    log.debug("checks programs={} unread={} windows={d}/{d} process_tables={d} next={?d}ms", .{
        programs,
        unread,
        shown_windows,
        scheduler.windows.items.len,
        scheduler.shared.captures - captures,
        if (timeline.next()) |at| at - now else null,
    });
    _ = span.end(io, "gtk_gx_checks");
    return @intFromBool(glib.SOURCE_REMOVE);
}

fn nowMs() i64 {
    return @divFloor(glib.getMonotonicTime(), std.time.us_per_ms);
}

/// Whether `window` is on screen: visible, mapped, not minimized and not
/// suspended by the compositor.
fn shown(window: *Window) bool {
    const widget = window.as(gtk.Widget);
    if (widget.getVisible() == 0 or widget.getMapped() == 0) return false;
    if (window.as(gtk.Window).isSuspended() != 0) return false;
    const surface = window.as(gtk.Native).getSurface() orelse return false;
    if (surface.getMapped() == 0) return false;
    const toplevel = gobject.ext.cast(gdk.Toplevel, surface) orelse return true;
    return !toplevel.getState().minimized;
}

fn tabCount(window: *Window) usize {
    return std.math.cast(usize, window.getTabView().getNPages()) orelse 0;
}

fn appModeEnabled(window: *Window) bool {
    const config = window.getConfig() orelse return false;
    return config.get().@"gx-herdr-app-mode";
}

fn foregroundPid(surface: *Surface) ?gx.proc.Pid {
    const core = surface.core() orelse return null;
    return std.math.cast(gx.proc.Pid, core.getProcessInfo(.foreground_pid) orelse return null);
}

/// Whether a terminal of the window's only tab runs herdr; null when a
/// terminal runs another program in the foreground and `scan` is false.
/// Stops at the first terminal that runs herdr.
fn runsHerdr(window: *Window, check: *Check, scan: bool) ?bool {
    const page = window.getTabView().getNthPage(0);
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return false;
    const tree = tab.getSurfaceTree() orelse return false;
    var unknown = false;
    var others: std.ArrayList(gx.proc.Pid) = .empty;
    var it = tree.iterator();
    while (it.next()) |entry| {
        const pid = foregroundPid(entry.view) orelse continue;
        switch (check.foreground(pid)) {
            .herdr => return true,
            .idle, .gone => {},
            .other => if (scan) {
                others.append(check.arena.allocator(), pid) catch {
                    unknown = true;
                };
            } else {
                unknown = true;
            },
        }
    }
    if (others.items.len > 0 and check.runsHerdrBelow(others.items)) return true;
    return if (unknown) null else false;
}

/// What one round of checks shares: `/proc` and an arena.
const Check = struct {
    alloc: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    proc_dir: ?std.Io.Dir = null,
    proc_opened: bool = false,
    table: ?*gx.proc.Table = null,
    table_attempted: bool = false,

    fn init() Check {
        const alloc = Application.default().allocator();
        return .{ .alloc = alloc, .io = global.io(), .arena = .init(alloc) };
    }

    fn deinit(self: *Check) void {
        if (self.proc_dir) |dir| dir.close(self.io);
        self.arena.deinit();
    }

    /// `/proc`, opened on first use; null on systems without it.
    fn procDir(self: *Check) ?std.Io.Dir {
        if (builtin.os.tag != .linux) return null;
        if (!self.proc_opened) {
            self.proc_opened = true;
            self.proc_dir = std.Io.Dir.openDirAbsolute(self.io, "/proc", .{}) catch |err| dir: {
                log.warn("cannot open /proc err={}", .{err});
                break :dir null;
            };
        }
        return self.proc_dir;
    }

    const Foreground = enum { herdr, idle, other, gone };

    /// What the name of the foreground process `pid` says about herdr.
    fn foreground(self: *Check, pid: gx.proc.Pid) Foreground {
        const dir = self.procDir() orelse return .gone;
        const name = (gx.proc.processName(self.alloc, self.io, dir, pid) catch return .gone) orelse return .gone;
        defer self.alloc.free(name);
        return switch (gx.app_mode.classify(name)) {
            .herdr => .herdr,
            .idle => .idle,
            .other => .other,
        };
    }

    /// Whether herdr runs below any of the foreground processes `roots`,
    /// from the shared process table.
    fn runsHerdrBelow(self: *Check, roots: []const gx.proc.Pid) bool {
        if (!self.table_attempted) {
            self.table_attempted = true;
            self.table = scheduler.shared.get(self.alloc, self.io) catch |err| {
                log.warn("cannot list processes err={}", .{err});
                return false;
            };
        }
        const table = self.table orelse return false;
        const arena = self.arena.allocator();
        const tree = table.tree(arena, roots) catch return false;
        for (roots) |root| {
            if (gx.app_mode.treeRunsHerdr(arena, tree, root, .leader) catch false) return true;
        }
        return false;
    }

    /// The kind of the foreground program `pid` (`gx.leader`).
    fn kind(self: *Check, pid: gx.proc.Pid) gx.leader.Kind {
        switch (builtin.os.tag) {
            .linux => {
                const dir = self.procDir() orelse return .local;
                return gx.leader.procKind(self.alloc, self.io, dir, pid, std.os.linux.geteuid()) catch .local;
            },
            else => return .local,
        }
    }
};

test "a failed snapshot is not retried within the same check" {
    const testing = std.testing;
    var check: Check = .{
        .alloc = testing.allocator,
        .io = testing.io,
        .arena = .init(testing.allocator),
        .table_attempted = true,
    };
    defer check.deinit();
    const captures = scheduler.shared.captures;
    try testing.expect(!check.runsHerdrBelow(&.{9999}));
    try testing.expect(!check.runsHerdrBelow(&.{10000}));
    try testing.expectEqual(captures, scheduler.shared.captures);
}

/// The object data key on a tab page holding `Leader.encode` of the
/// program its icon is for.
const leader_key = "gx-leader";

/// The foreground program of a tab when its icon was set.
pub const Leader = struct {
    pid: gx.proc.Pid,
    kind: gx.leader.Kind,

    /// A value for object data: never 0, so never null.
    pub fn encode(self: Leader) usize {
        return @as(usize, self.pid) << 8 | (@as(usize, @intFromEnum(self.kind)) + 1);
    }

    pub fn decode(value: usize) ?Leader {
        const tag = value & 0xff;
        if (tag == 0 or tag > std.meta.fields(gx.leader.Kind).len) return null;
        return .{
            .pid = @truncate(value >> 8),
            .kind = @enumFromInt(@as(@typeInfo(gx.leader.Kind).@"enum".tag_type, @intCast(tag - 1))),
        };
    }
};

/// The kind of the foreground program of the tab of `page`, setting the
/// page's icon when it changes. `force` reads it again even if the
/// foreground process is the same.
fn pageKind(page: *adw.TabPage, check: *Check, force: bool) gx.leader.Kind {
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return .local;
    const pid: gx.proc.Pid = pid: {
        const surface = tab.getActiveSurface() orelse break :pid 0;
        break :pid foregroundPid(surface) orelse 0;
    };
    const object = page.as(gobject.Object);
    const cached = Leader.decode(@intFromPtr(object.getData(leader_key)));
    if (!force) if (cached) |leader| if (leader.pid == pid) return leader.kind;

    const kind: gx.leader.Kind = if (pid == 0) .local else check.kind(pid);
    object.setData(leader_key, @ptrFromInt((Leader{ .pid = pid, .kind = kind }).encode()));
    const previous: gx.leader.Kind = if (cached) |leader| leader.kind else .local;
    if (kind != previous) setPageIcon(page, kind);
    progress.setKind(page, kind);
    return kind;
}

/// The icon of a tab running a program of `kind`, with fallbacks for icon
/// themes without the first name.
pub fn iconNames(kind: gx.leader.Kind) []const [:0]const u8 {
    return switch (kind) {
        .local => &.{},
        .remote => &.{ "network-server-symbolic", "network-workgroup-symbolic", "computer-symbolic" },
        .superuser => &.{ "dialog-password-symbolic", "changes-prevent-symbolic" },
        .container => &.{ "package-x-generic-symbolic", "application-x-addon-symbolic" },
    };
}

fn setPageIcon(page: *adw.TabPage, kind: gx.leader.Kind) void {
    const names = iconNames(kind);
    if (names.len == 0) return page.setIcon(null);
    const icon = gio.ThemedIcon.new(names[0]);
    defer icon.unref();
    for (names[1..]) |name| icon.appendName(name);
    page.setIcon(icon.as(gio.Icon));
}

fn setWindowKind(window: *Window, kind: gx.leader.Kind) void {
    const widget = window.as(gtk.Widget);
    inline for (.{ .{ "gx-remote", .remote }, .{ "gx-superuser", .superuser } }) |class| {
        if (kind == class[1]) widget.addCssClass(class[0]) else widget.removeCssClass(class[0]);
    }
}

/// The object data key on a surface holding its `gx.unread.Tracker`.
const unread_key = "gx-unread";

fn tracker(surface: *Surface, create: bool) ?*gx.unread.Tracker {
    const object = surface.as(gobject.Object);
    if (object.getData(unread_key)) |data| return @ptrCast(@alignCast(data));
    if (!create) return null;
    const value = glib.ext.new(gx.unread.Tracker, .{});
    object.setDataFull(unread_key, value, &glib.free);
    return value;
}

/// Brings the unread baselines up to date with the selected tab, right
/// when it changes: the terminals of the selected tab are shown and drop
/// theirs, those of the other tabs take one if they have none.
fn syncUnread(window: *Window) void {
    const view = window.getTabView();
    const selected = view.getSelectedPage();
    const io = global.io();
    for (0..tabCount(window)) |i| {
        const page = view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (page == selected) {
                if (tracker(entry.view, false)) |value| value.show();
                continue;
            }
            const core = entry.view.core() orelse continue;
            const value = tracker(entry.view, true) orelse continue;
            if (value.baseline == null) value.hide(&core.renderer_state, io);
        }
    }
}

/// Marks the tabs that are not shown and whose terminals have new output.
fn checkUnread(window: *Window) void {
    const view = window.getTabView();
    const selected = view.getSelectedPage();
    const io = global.io();
    for (0..tabCount(window)) |i| {
        const page = view.getNthPage(@intCast(i));
        if (page == selected or page.getNeedsAttention() != 0) continue;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const core = entry.view.core() orelse continue;
            const value = tracker(entry.view, true) orelse continue;
            if (!prepareUnread(value, &core.renderer_state, io)) continue;
            if (value.check(&core.renderer_state, io)) {
                page.setNeedsAttention(@intFromBool(true));
                break;
            }
        }
    }
}

fn prepareUnread(value: *gx.unread.Tracker, state: *@import("../../../renderer/State.zig"), io: std.Io) bool {
    if (value.baseline != null) return true;
    if (!state.mutex.tryLock()) return false;
    defer state.mutex.unlock(io);
    value.* = .{ .baseline = gx.unread.baseline(state.terminal) };
    return false;
}

test "unread baseline setup never waits for the renderer lock" {
    const testing = std.testing;
    const Terminal = @import("../../../terminal/main.zig").Terminal;
    const RendererState = @import("../../../renderer/State.zig");
    var terminal: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(testing.allocator);
    var mutex: std.Io.Mutex = .init;
    var state: RendererState = .{ .mutex = &mutex, .terminal = &terminal };
    var value: gx.unread.Tracker = .{};
    try testing.expect(mutex.tryLock());
    try testing.expect(!prepareUnread(&value, &state, testing.io));
    try testing.expect(value.baseline == null);
    mutex.unlock(testing.io);
    try testing.expect(!prepareUnread(&value, &state, testing.io));
    try testing.expect(value.baseline != null);
    try testing.expect(prepareUnread(&value, &state, testing.io));
    try testing.expect(!value.check(&state, testing.io));
    try terminal.printString("new output");
    try testing.expect(value.check(&state, testing.io));
}

test "polling stops for disabled hidden multiple tabs and confirmed herdr" {
    const testing = std.testing;
    try testing.expect(shouldPoll(true, 1, false, true));
    try testing.expect(!shouldPoll(false, 1, false, true));
    try testing.expect(!shouldPoll(true, 1, false, false));
    try testing.expect(!shouldPoll(true, 0, false, true));
    try testing.expect(!shouldPoll(true, 2, false, true));
    try testing.expect(!shouldPoll(true, 1, true, true));
    var state: gx.app_mode.State = .{};
    _ = state.update(true, 1, &.{true});
    try testing.expect(shouldPoll(true, 1, state.active, true));
    _ = state.update(true, 1, &.{true});
    var timeline: Timeline = .{};
    timeline.reset(0);
    timeline.checked(min_delay_ms, shouldPoll(true, 1, state.active, true), true);
    try testing.expectEqual(@as(?i64, null), timeline.next());
}

test "Timeline backs off while a window polls and nothing changes" {
    const testing = std.testing;
    var timeline: Timeline = .{};
    try testing.expectEqual(@as(?i64, null), timeline.next());
    try testing.expect(!timeline.checkDue(0));

    timeline.reset(1000);
    try testing.expectEqual(@as(?i64, 1000 + min_delay_ms), timeline.next());
    try testing.expect(!timeline.checkDue(1000));
    try testing.expect(timeline.checkDue(1000 + min_delay_ms - slack_ms));

    var now: i64 = 1000 + min_delay_ms;
    const expected = [_]u32{ 1000, 2000, 4000, 8000, max_delay_ms, max_delay_ms };
    for (expected) |delay| {
        timeline.checked(now, true, false);
        try testing.expectEqual(delay, timeline.delay_ms);
        try testing.expectEqual(@as(?i64, now + delay), timeline.next());
        now += delay;
    }

    // A check that changed something or found herdr keeps it frequent.
    timeline.checked(now, true, true);
    try testing.expectEqual(min_delay_ms, timeline.delay_ms);

    // A reset never postpones a check that is already sooner.
    timeline.checked(now, true, false);
    timeline.reset(now + 900);
    try testing.expectEqual(@as(?i64, now + 1000), timeline.check_at);
    timeline.reset(now + 100);
    try testing.expectEqual(@as(?i64, now + 100 + min_delay_ms), timeline.check_at);
    try testing.expectEqual(min_delay_ms, timeline.delay_ms);
}

test "Timeline stops when no window polls" {
    const testing = std.testing;
    var timeline: Timeline = .{};
    timeline.reset(0);
    timeline.checked(min_delay_ms, false, false);
    try testing.expectEqual(@as(?i64, null), timeline.next());

    // Unread checks every second while a window has several tabs.
    timeline.unread(100, true, false);
    try testing.expectEqual(@as(?i64, 100 + unread_interval_ms), timeline.next());
    // A tick for something else keeps the second.
    timeline.unread(600, true, false);
    try testing.expectEqual(@as(?i64, 100 + unread_interval_ms), timeline.unread_at);
    try testing.expect(timeline.unreadDue(1100));
    timeline.unread(1100, true, true);
    try testing.expectEqual(@as(?i64, 2100), timeline.unread_at);

    // The earlier of the two checks fires first.
    timeline.reset(1200);
    try testing.expectEqual(@as(?i64, 1200 + min_delay_ms), timeline.next());

    timeline.unread(1300, false, false);
    timeline.checked(1700, false, false);
    try testing.expectEqual(@as(?i64, null), timeline.next());
}

test "Leader round-trips through object data" {
    const testing = std.testing;
    try testing.expectEqual(@as(?Leader, null), Leader.decode(0));
    inline for (std.meta.fields(gx.leader.Kind)) |field| {
        const kind: gx.leader.Kind = @enumFromInt(field.value);
        for ([_]gx.proc.Pid{ 0, 1, 4_194_304 }) |pid| {
            const value = (Leader{ .pid = pid, .kind = kind }).encode();
            try testing.expect(value != 0);
            try testing.expectEqual(@as(?Leader, .{ .pid = pid, .kind = kind }), Leader.decode(value));
        }
    }
    try testing.expectEqual(@as(?Leader, null), Leader.decode(0x1ff));
}

test "iconNames has an icon for every kind but local" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), iconNames(.local).len);
    for ([_]gx.leader.Kind{ .remote, .superuser, .container }) |kind| {
        const names = iconNames(kind);
        try testing.expect(names.len >= 2);
        for (names) |name| try testing.expect(std.mem.endsWith(u8, name, "-symbolic"));
    }
}
