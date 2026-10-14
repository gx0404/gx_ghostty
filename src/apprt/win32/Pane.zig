//! Borrowed GUI adapter for local and remote leaves. Never retain across a
//! modal operation; re-resolve the value identity after model mutations.
const Self = @This();
const std = @import("std");
const Surface = @import("Surface.zig");
const RemotePane = @import("RemotePane.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const Action = @import("../../input.zig").Binding.Action;
const Snapshot = @import("PaneSnapshot.zig");
const refs = @import("../../gx/ui_ref.zig");
const unread = @import("../../gx/unread.zig");
const RendererState = @import("../../renderer/State.zig");

backend: union(enum) { local: *Surface, remote: *RemotePane },

pub fn fromRemote(remote: *RemotePane) Self {
    return .{ .backend = .{ .remote = remote } };
}

pub fn fromLocal(surface: *Surface) Self {
    return .{ .backend = .{ .local = surface } };
}
pub fn reference(self: Self) refs.Reference {
    return switch (self.backend) {
        .remote => |remote| remote.ui_reference,
        .local => |surface| surface.ui_reference,
    };
}
pub fn attachment(self: Self) refs.Attachment {
    return switch (self.backend) {
        .remote => |remote| remote.ui_attachment,
        .local => |surface| surface.ui_attachment,
    };
}
pub fn initialized(self: Self) bool {
    return switch (self.backend) {
        .remote => |remote| remote.snapshot().initialized,
        .local => |surface| surface.core_surface_initialized,
    };
}
pub fn ready(self: Self) bool {
    return switch (self.backend) {
        .remote => |remote| remote.snapshot().ready,
        .local => |surface| surface.core_surface_ready,
    };
}
pub fn app(self: Self) *App {
    return switch (self.backend) {
        .remote => |remote| remote.app,
        .local => |surface| surface.app,
    };
}
/// Borrowed owner, never held across a modal operation. Capture its ui_reference
/// and resolve the Window again after a callback that may dispatch messages.
pub fn ownerWindow(self: Self) *Window {
    return switch (self.backend) {
        .remote => |remote| remote.parent_window,
        .local => |surface| surface.parent_window,
    };
}
pub fn nativeHandle(self: Self) ?w32.HWND {
    return switch (self.backend) {
        .remote => |remote| remote.hwnd,
        .local => |surface| surface.hwnd,
    };
}
pub fn focus(self: Self) void {
    if (self.nativeHandle()) |hwnd| _ = w32.SetFocus(hwnd);
}
pub fn dismissSearch(self: Self) void {
    switch (self.backend) {
        .remote => |remote| remote.dismissSearch(),
        .local => |surface| if (surface.search_bar.active) surface.search_bar.setActive(false, &[_:0]u8{}),
    }
}
/// Visible-window model lookup; hidden remote hosts are not UI action targets.
pub fn resolve(application: *App, identity: refs.Reference) ?Self {
    if (!identity.isValid() or identity.epoch != application.ui_ids.epoch) return null;
    for (application.windows.items) |window| if (window.lookupPane(identity)) |pane| return pane;
    if (application.quick_terminal) |quick| return quick.window.lookupPane(identity);
    return null;
}
pub fn tabInfo(self: Self) Snapshot.Tab {
    const window = self.ownerWindow();
    const leaf = window.leafForPane(self.reference());
    const index = if (leaf) |value| window.findTabIndex(value) else null;
    return .{ .window = window.ui_reference, .tab = if (index) |i| window.tab_references[i] else null, .split = if (index) |i| window.tab_trees[i].isSplit() else false, .zoomed = if (index) |i| window.tab_trees[i].zoomed != null else false, .other_tabs = window.tab_count > 1 };
}

pub fn hasSelection(self: Self) bool {
    return switch (self.backend) {
        .remote => |remote| remote.snapshot().selection,
        .local => |surface| surface.core_surface_ready and surface.core_surface.hasSelection(),
    };
}
/// Owned returned bytes, with exactly the core cwd semantics. The consumer
/// applies its existing domain/path policy before using the value in native UI.
pub fn workingDirectory(self: Self, alloc: std.mem.Allocator) !?[]const u8 {
    return switch (self.backend) {
        .remote => |remote| try remote.workingDirectory(alloc),
        .local => |surface| if (surface.core_surface_ready) try surface.core_surface.pwd(alloc) else null,
    };
}
pub fn cursorAnchor(self: Self) ?Snapshot.CursorAnchor {
    return switch (self.backend) {
        .remote => |remote| remote.cursorAnchor(),
        .local => |surface| block: {
            if (!surface.core_surface_ready) break :block null;
            const point = surface.core_surface.imePoint();
            break :block .{ .x = point.x, .y = point.y, .width = point.width, .height = point.height, .scale = surface.scale, .cell_width = surface.core_surface.size.cell.width, .cell_height = surface.core_surface.size.cell.height, .pane_width = surface.width, .pane_height = surface.height };
        },
    };
}
/// A potentially reentrant action invalidates the borrowed adapter. Resolve
/// its value Reference before each subsequent action in a chain.
pub fn performBindingAction(self: Self, action: Action) !bool {
    return switch (self.backend) {
        .remote => |remote| try remote.performBindingAction(action),
        .local => |surface| if (surface.core_surface_ready) try surface.core_surface.performBindingAction(action) else false,
    };
}
pub fn moveTabToNewWindow(self: Self) !bool {
    return switch (self.backend) {
        .remote => |remote| try remote.parent_window.moveTabToNewWindow(remote.parent_window.leafForPane(remote.ui_reference) orelse return false),
        .local => |surface| try surface.parent_window.moveTabToNewWindow(surface),
    };
}
pub fn showKeybinds(self: Self) bool {
    return switch (self.backend) {
        .remote => @import("ui/Keybinds.zig").show(self.ownerWindow()),
        .local => |surface| @import("ui/Keybinds.zig").showLocal(surface),
    };
}

/// Transitional bridge to Menu.performTabCommand's existing core-ID contract.
/// This is deliberately named local: remove it when that consumer takes Pane refs.
pub fn legacyLocalCoreId(self: Self) ?u64 {
    return switch (self.backend) {
        .remote => null,
        .local => |surface| if (surface.core_surface_initialized) surface.core_surface.id else null,
    };
}
pub fn grid(self: Self) ?Snapshot.Grid {
    return switch (self.backend) {
        .remote => |remote| remote.snapshot().grid,
        .local => |surface| block: {
            if (!surface.core_surface_ready) break :block null;
            const size = surface.core_surface.size.grid();
            if (size.columns == 0 or size.rows == 0) break :block null;
            break :block .{ .pane = surface.ui_reference, .columns = size.columns, .rows = size.rows };
        },
    };
}
pub fn snapshot(self: Self) Snapshot {
    return switch (self.backend) {
        .remote => |remote| remote.snapshot(),
        .local => |surface| .{
            .reference = surface.ui_reference,
            .attachment = surface.ui_attachment,
            .initialized = surface.core_surface_initialized,
            .ready = surface.core_surface_ready,
            .title = Snapshot.Title.init(surface.getTitle() orelse "") catch .{},
            .grid = self.grid(),
        },
    };
}
/// Called only by the existing bounded process poll, not by paint/snapshot.
pub fn foregroundPid(self: Self) ?u32 {
    return switch (self.backend) {
        .remote => null,
        .local => |surface| block: {
            if (!surface.core_surface_ready) break :block null;
            const pid = surface.core_surface.getProcessInfo(.foreground_pid) orelse break :block null;
            break :block std.math.cast(u32, pid);
        },
    };
}

pub const UnreadTracker = struct {
    remote_unread: bool = false,
    tracker: unread.Tracker = .{},
    grid: ?[2]usize = null,
    fn capture(self: *UnreadTracker, state: *RendererState) void {
        self.tracker = .{ .baseline = unread.baseline(state.terminal) };
        self.grid = .{ state.terminal.cols, state.terminal.rows };
    }
    pub fn show(self: *UnreadTracker) void {
        self.remote_unread = false;
        self.tracker.show();
        self.grid = null;
    }
    fn hide(self: *UnreadTracker, state: *RendererState, io: std.Io) void {
        state.lockDemand(io);
        defer state.unlockDemand(io);
        self.capture(state);
    }
    fn check(self: *UnreadTracker, state: *RendererState, io: std.Io) bool {
        if (!state.mutex.tryLock()) {
            self.tracker.busy +|= 1;
            return self.tracker.busy >= unread.busy_checks;
        }
        defer state.mutex.unlock(io);
        const dimensions: [2]usize = .{ state.terminal.cols, state.terminal.rows };
        if (self.grid == null or !std.meta.eql(self.grid.?, dimensions) or self.tracker.baseline == null) {
            self.capture(state);
            return false;
        }
        self.tracker.busy = 0;
        return unread.changed(state.terminal, self.tracker.baseline);
    }
};
/// First baseline never blocks; ordinary hide uses the existing lockDemand rule.
pub fn captureUnread(self: Self, tracker: *UnreadTracker, io: std.Io) bool {
    return switch (self.backend) {
        .remote => |remote| block: {
            _ = remote;
            tracker.remote_unread = self.snapshot().unread;
            break :block true;
        },
        .local => |surface| block: {
            if (!surface.core_surface_ready) break :block false;
            const state = &surface.core_surface.renderer_state;
            if (!state.mutex.tryLock()) break :block false;
            defer state.mutex.unlock(io);
            tracker.capture(state);
            break :block true;
        },
    };
}
pub fn hideUnread(self: Self, tracker: *UnreadTracker, io: std.Io) void {
    switch (self.backend) {
        .remote => |remote| tracker.remote_unread = remote.snapshot().unread,
        .local => |surface| if (surface.core_surface_ready) tracker.hide(&surface.core_surface.renderer_state, io),
    }
}
pub fn checkUnread(self: Self, tracker: *UnreadTracker, io: std.Io) bool {
    return switch (self.backend) {
        .remote => |remote| remote.snapshot().unread and !tracker.remote_unread,
        .local => |surface| if (surface.core_surface_ready) tracker.check(&surface.core_surface.renderer_state, io) else false,
    };
}

test "pane hidden tracking ignores reflow but sees subsequent output" {
    const testing = std.testing;
    const Terminal = @import("../../terminal/main.zig").Terminal;
    var terminal: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(testing.allocator);
    var mutex: std.Io.Mutex = .init;
    var state: RendererState = .{ .mutex = &mutex, .terminal = &terminal };
    var tracked: UnreadTracker = .{};
    try terminal.printString("$ ");
    tracked.hide(&state, testing.io);
    try testing.expect(!tracked.check(&state, testing.io));
    try terminal.resize(testing.allocator, .{ .cols = 40, .rows = 7 });
    try testing.expect(!tracked.check(&state, testing.io));
    try terminal.printString("new output\n");
    try testing.expect(tracked.check(&state, testing.io));
    tracked.show();
    try testing.expect(!tracked.check(&state, testing.io));
}

test "pane hidden tracking never waits for a busy terminal" {
    const testing = std.testing;
    const Terminal = @import("../../terminal/main.zig").Terminal;
    var terminal: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(testing.allocator);
    var mutex: std.Io.Mutex = .init;
    var state: RendererState = .{ .mutex = &mutex, .terminal = &terminal };
    var tracked: UnreadTracker = .{};
    tracked.hide(&state, testing.io);
    try testing.expect(mutex.tryLock());
    for (1..unread.busy_checks) |_| try testing.expect(!tracked.check(&state, testing.io));
    try testing.expect(tracked.check(&state, testing.io));
    mutex.unlock(testing.io);
    try testing.expect(!tracked.check(&state, testing.io));
}

test "pane adapter keeps unready core state opaque" {
    var surface: Surface = undefined;
    surface.core_surface_ready = false;
    surface.core_surface_initialized = false;
    const pane = fromLocal(&surface);
    try std.testing.expect(pane.grid() == null);
    try std.testing.expect(pane.foregroundPid() == null);
    try std.testing.expect(pane.legacyLocalCoreId() == null);
    var tracker: UnreadTracker = .{};
    try std.testing.expect(!pane.captureUnread(&tracker, std.testing.io));
    try std.testing.expect(!pane.checkUnread(&tracker, std.testing.io));
    pane.hideUnread(&tracker, std.testing.io);
}

test "pane snapshot copies local title without retaining the surface" {
    var surface: Surface = .{ .app = undefined, .parent_window = undefined, .ui_reference = .{ .epoch = 1, .kind = .surface, .id = 2, .generation = 3 } };
    @memcpy(surface.title[0..5], "alpha");
    surface.title[5] = 0;
    surface.title_len = 5;
    const pane = fromLocal(&surface);
    const owned = pane.snapshot();
    @memcpy(surface.title[0..5], "other");
    try std.testing.expectEqualStrings("alpha", owned.title.slice());
    try std.testing.expect(owned.reference.matches(surface.ui_reference));
    try std.testing.expect(owned.grid == null);
    try std.testing.expectEqual(@as(u32, 0), surface.ref_count);
}
