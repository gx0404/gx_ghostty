//! herdr app mode for GTK windows (fork patch GX-0016). While the only tab
//! of a window runs herdr (see `src/gx/app_mode.zig`) and
//! `gx-herdr-app-mode` is on, `Window.getTabsVisible` hides the tab bar,
//! so herdr looks like a standalone application. With
//! `gtk-titlebar-style = tabs` the tab bar also holds the window controls,
//! the new tab button and the main menu, so `Window.getHeaderbarVisible`
//! shows the header bar in its place and the window stays usable.
//!
//! A window re-evaluates when its number of pages, its selected page or
//! the splits of a tab change, when a terminal title changes (shells and
//! herdr set titles as programs start and exit), and every `interval_ms`
//! while it has exactly one tab. A title change only reads the name of the
//! foreground process; the other events may also list the processes below
//! it when that name is not conclusive.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");

const global = @import("../../../global.zig");
const gx_app_mode = @import("../../../gx/app_mode.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;

const log = std.log.scoped(.gtk_gx_app_mode);

/// How often a window with exactly one tab re-evaluates herdr app mode.
pub const interval_ms = 1500;

/// The herdr app mode state of a window, kept in its private data.
pub const AppMode = struct {
    /// Whether the window is in herdr app mode.
    active: bool = false,

    /// The periodic re-evaluation, running while the window has exactly
    /// one tab.
    timer: ?c_uint = null,

    /// Set by `deinit`; later notifications from the disposing window are
    /// ignored so that they cannot start the timer again.
    disposed: bool = false,

    /// Re-evaluates herdr app mode, then starts or stops the timer. `scan`
    /// allows listing processes (see `gx_app_mode.terminalRunsHerdr`).
    pub fn update(self: *AppMode, window: *Window, scan: bool) void {
        if (self.disposed) return;
        self.evaluate(window, scan);
        if (tabCount(window) == 1) {
            if (self.timer == null) self.timer = glib.timeoutAdd(interval_ms, tick, window);
        } else {
            self.stopTimer();
        }
    }

    /// Stops the timer for good. Call it when the window is disposed,
    /// before its children are.
    pub fn deinit(self: *AppMode) void {
        self.stopTimer();
        self.disposed = true;
    }

    fn stopTimer(self: *AppMode) void {
        const timer = self.timer orelse return;
        if (glib.Source.remove(timer) == 0) log.warn("unable to remove the herdr app mode timer", .{});
        self.timer = null;
    }

    fn evaluate(self: *AppMode, window: *Window, scan: bool) void {
        const active = compute(window, self.active, scan);
        if (active == self.active) return;
        self.active = active;
        log.info("herdr app mode {s}", .{if (active) "on" else "off"});
        const object = window.as(gobject.Object);
        object.notify("tabs-visible");
        object.notify("headerbar-visible");
    }
};

/// Re-evaluates herdr app mode when the title of `surface` changes.
/// `Window.connectSurfaceHandlers` calls this for every surface; the
/// handler is disconnected with the window's other surface handlers.
pub fn connectSurface(window: *Window, surface: *Surface) void {
    _ = gobject.Object.signals.notify.connect(
        surface,
        *Window,
        surfaceNotifyTitle,
        window,
        .{ .detail = "title" },
    );
}

fn surfaceNotifyTitle(_: *Surface, _: *gobject.ParamSpec, window: *Window) callconv(.c) void {
    window.gxAppMode().update(window, false);
}

fn tick(ud: ?*anyopaque) callconv(.c) c_int {
    const window: *Window = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
    const self = window.gxAppMode();
    if (tabCount(window) != 1) {
        self.timer = null;
        self.evaluate(window, true);
        return @intFromBool(glib.SOURCE_REMOVE);
    }
    self.evaluate(window, true);
    return @intFromBool(glib.SOURCE_CONTINUE);
}

fn tabCount(window: *Window) usize {
    return std.math.cast(usize, window.getTabView().getNPages()) orelse 0;
}

/// Whether `window` should be in herdr app mode now; `current` is its
/// current state, kept while the answer is unknown.
fn compute(window: *Window, current: bool, scan: bool) bool {
    const config = window.getConfig() orelse return false;
    if (!config.get().@"gx-herdr-app-mode" or tabCount(window) != 1) return false;

    const page = window.getTabView().getNthPage(0);
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return false;
    const tree = tab.getSurfaceTree() orelse return false;

    const alloc = Application.default().allocator();
    var answers: std.ArrayList(?bool) = .empty;
    defer answers.deinit(alloc);
    var it = tree.iterator();
    while (it.next()) |entry| {
        const core = entry.view.core() orelse continue;
        const answer = gx_app_mode.terminalRunsHerdr(
            alloc,
            global.io(),
            core.getProcessInfo(.foreground_pid),
            scan,
        );
        answers.append(alloc, answer) catch return current;
    }
    return gx_app_mode.decide(true, 1, answers.items, current);
}
