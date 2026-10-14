//! Source-owned hidden GUI container and per-surface frame publishers. App must
//! register the hidden Window separately and keep this host alive while a remote
//! input/view lease exists, even after the original visible window closes.
//! The host owns original Trees: no shell recreation or terminal-output replay.
const std = @import("std");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");
const Channel = @import("ipc/RemoteChannel.zig").Channel;
const Write = @import("ipc/RemoteChannel.zig").Write;
const refs = @import("../../gx/ui_ref.zig");
const Tree = @import("../../datastruct/split_tree.zig").SplitTree(@import("Leaf.zig"));

pub const Host = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    outputs: std.ArrayList(Binding) = .empty,
    const Binding = struct { surface: refs.Reference, output: *Output };

    /// Creates an empty hidden Window with a real native HWND, no placeholder
    /// terminal. App must register window identity before invoking adoptTree.
    pub fn create(app: *App) !*Host {
        const allocator = app.core_app.alloc;
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const window = try allocator.create(Window);
        errdefer allocator.destroy(window);
        try window.init(app, .{});
        window.is_remote_host = true;
        self.* = .{ .allocator = allocator, .window = window };
        return self;
    }

    /// Caller has already removed this owned tree from its original tab without
    /// releasing it. On failure the tree remains caller-owned and native parents
    /// are rolled back. On success adoptSessionTab consumes the entire tree.
    /// Root's transfer coordinator holds source owners alive across this call.
    pub fn adoptTree(self: *Host, tree: *Tree, focused: *@import("Leaf.zig"), title: ?@import("tabs.zig").Title) !void {
        if (tree.isEmpty() or tree.locate(focused) == null or self.window.closing) return error.InvalidTree;
        // Root owns the host allocation throughout this synchronous transaction;
        // it must not call Host.deinit from a nested callback. Window's existing
        // transfer flag defers WM_CLOSE and Window.close until commit/rollback.
        if (self.window.tab_transfer_active) return error.TransferBusy;
        const Owner = struct { window: *Window, reference: refs.Reference };
        var owners: std.ArrayList(Owner) = .empty;
        defer owners.deinit(self.allocator);
        const View = struct { surface: *Surface, reference: refs.Reference, owner: refs.Reference, hwnd: w32.HWND, parent: w32.HWND, attachment: refs.Attachment };
        var views: std.ArrayList(View) = .empty;
        defer views.deinit(self.allocator);
        // Explicit extra strong refs survive even a nested tab-tree replacement.
        var retained = try tree.clone(self.allocator);
        defer retained.deinit();
        var iterator = retained.iterator();
        while (iterator.next()) |entry| {
            const surface = entry.view.local() orelse return error.RemoteRelayUnsupported;
            const hwnd = surface.hwnd orelse return error.InvalidSurface;
            const owner = surface.parent_window;
            if (owner == self.window or owner.closing or owner.tab_transfer_active) return error.InvalidOwner;
            const seen = for (owners.items) |item| {
                if (item.window == owner) break true;
            } else false;
            if (!seen) try owners.append(self.allocator, .{ .window = owner, .reference = owner.ui_reference });
            try views.append(self.allocator, .{ .surface = surface, .reference = surface.ui_reference, .owner = owner.ui_reference, .hwnd = hwnd, .parent = w32.GetParent(hwnd) orelse return error.InvalidOwner, .attachment = try entry.view.prepareReparent(self.window) });
        }
        const destination = self.window.hwnd orelse return error.InvalidOwner;
        const destination_reference = self.window.ui_reference;
        self.window.tab_transfer_active = true;
        for (owners.items) |owner| owner.window.tab_transfer_active = true;
        defer {
            self.window.tab_transfer_active = false;
            if (self.window.tab_transfer_close) {
                self.window.tab_transfer_close = false;
                self.window.requestClose();
            }
            for (owners.items) |owner| {
                const live = self.window.app.resolveWindow(owner.reference) orelse continue;
                live.tab_transfer_active = false;
                if (live.tab_transfer_close) {
                    live.tab_transfer_close = false;
                    live.requestClose();
                }
            }
        }
        const Backend = struct {
            host: *Host,
            destination: w32.HWND,
            destination_reference: refs.Reference,
            views: []const View,
            pub fn validate(self_: *@This()) !void {
                if (self_.host.window.hwnd != self_.destination or self_.host.window.tab_transfer_close or
                    !self_.destination_reference.matches(self_.host.window.ui_reference)) return error.StaleDestination;
                for (self_.views) |view| {
                    const owner = self_.host.window.app.resolveWindow(view.owner) orelse return error.StaleSource;
                    if (owner.tab_transfer_close or view.surface.parent_window != owner or view.surface.hwnd != view.hwnd or
                        !view.reference.matches(view.surface.ui_reference)) return error.StaleSource;
                }
            }
            pub fn move(self_: *@This(), index: usize) !void {
                try self_.validate();
                const view = self_.views[index];
                if (w32.GetParent(view.hwnd) != view.parent) return error.StaleParent;
                if (w32.SetParent(view.hwnd, self_.destination) == null) return error.SetParentFailed;
            }
            pub fn restore(self_: *@This(), index: usize) !void {
                const view = self_.views[index];
                if (w32.GetParent(view.hwnd) == view.parent) return;
                if (w32.SetParent(view.hwnd, view.parent) == null) return error.RollbackFailed;
            }
        };
        var backend: Backend = .{ .host = self, .destination = destination, .destination_reference = destination_reference, .views = views.items };
        try @import("tab_transfer.zig").reparent(Backend, &backend, views.items.len);
        _ = self.window.adoptSessionTab(tree, focused, title) catch |err| {
            var rollback_failed = false;
            var index = views.items.len;
            while (index > 0) {
                index -= 1;
                backend.restore(index) catch {
                    rollback_failed = true;
                };
            }
            return if (rollback_failed) error.RollbackFailed else err;
        };
        for (views.items) |view| {
            view.surface.onReparented(self.window, view.attachment);
            view.surface.setVisible(false);
        }
    }

    /// Channel ownership passes only on success. Remote output is attached under
    /// Surface's independent lock; no GUI holds it while invoking core callbacks.
    pub fn addOutput(self: *Host, surface: *Surface, channel: *Channel) !*Output {
        return self.addOutputWithWake(surface, channel, null);
    }

    pub fn addOutputWithWake(self: *Host, surface: *Surface, channel: *Channel, transport_wake: ?w32.HANDLE) !*Output {
        if (surface.parent_window != self.window) return error.InvalidOwner;
        for (self.outputs.items) |binding| if (binding.surface.matches(surface.ui_reference)) return error.AlreadyAttached;
        try self.outputs.ensureUnusedCapacity(self.allocator, 1);
        const output = try Output.createWithWake(self.allocator, channel, transport_wake);
        self.outputs.appendAssumeCapacity(.{ .surface = surface.ui_reference, .output = output });
        surface.setRemoteOutput(output);
        return output;
    }

    /// Reserve/export frames during prepare while the original visible tree
    /// still owns its terminals. Abort detaches these previews without a move.
    pub fn prepareOutput(self: *Host, surface: *Surface, channel: *Channel, transport_wake: w32.HANDLE) !*Output {
        if (surface.parent_window.closing or surface.parent_window.is_quick_terminal or surface.remote_output != null) return error.InvalidOwner;
        try self.outputs.ensureUnusedCapacity(self.allocator, 1);
        const output = try Output.createWithWake(self.allocator, channel, transport_wake);
        self.outputs.appendAssumeCapacity(.{ .surface = surface.ui_reference, .output = output });
        surface.setRemotePreview(output);
        return output;
    }

    pub fn findOutput(self: *Host, reference: refs.Reference) ?*Output {
        for (self.outputs.items) |binding| if (binding.surface.matches(reference)) return binding.output;
        return null;
    }

    /// Called only after target-enabled, when this host owns the complete tree.
    pub fn detachPreviews(self: *Host) void {
        for (self.outputs.items) |binding| if (self.window.app.resolveSurface(binding.surface)) |surface| {
            std.debug.assert(surface.parent_window == self.window);
            surface.setRemoteOutput(binding.output);
        };
    }

    /// Resize uses a new generation/mapping. The returned old Output stays
    /// readable until the caller retires it after replacement acknowledgement
    /// or disconnect, and stops its notification wait before deinit. Never
    /// mutate old slot dimensions.
    pub fn replaceOutput(self: *Host, surface: *Surface, channel: *Channel) !*Output {
        return self.replaceOutputWithWake(surface, channel, null);
    }

    pub fn replaceOutputWithWake(self: *Host, surface: *Surface, channel: *Channel, transport_wake: ?w32.HANDLE) !*Output {
        for (self.outputs.items) |*binding| {
            if (!binding.surface.matches(surface.ui_reference)) continue;
            if (surface.parent_window != self.window or channel.mapped.generation <= binding.output.channel.mapped.generation) return error.InvalidGeneration;
            const replacement = try Output.createWithWake(self.allocator, channel, transport_wake);
            const previous = binding.output;
            surface.setRemoteOutput(replacement);
            binding.output = replacement;
            return previous;
        }
        return error.UnknownSurface;
    }

    /// GUI-only, after removing this host from App's remote-host registry.
    /// All outputs are detached before Window.deinit joins renderer/IO threads.
    pub fn deinit(self: *Host) void {
        std.debug.assert(!self.window.tab_transfer_active);
        for (self.outputs.items) |binding| if (self.window.app.resolveSurface(binding.surface)) |surface| {
            surface.setRemotePreview(null);
        };
        for (self.window.tab_trees[0..self.window.tab_count]) |*tree| {
            var iterator = tree.iterator();
            while (iterator.next()) |entry| if (entry.view.local()) |surface| surface.setRemoteOutput(null);
        }
        // IPC workers must have stopped waiting on Output.notificationHandle
        // before this call. Detached outputs have no renderer-side borrowers.
        self.window.deinit();
        self.allocator.destroy(self.window);
        for (self.outputs.items) |binding| binding.output.deinit();
        self.outputs.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

/// Stable address, GUI owns lifetime; only the render thread publishes frames.
/// Access to channel/row_scratch is serialized by Surface.remote_mutex. The
/// event and atomic snapshots can be read by an IPC worker without that lock.
pub const Output = struct {
    allocator: std.mem.Allocator,
    channel: *Channel,
    row_scratch: []u8,
    wake: w32.HANDLE,
    transport_wake: ?w32.HANDLE = null,
    latest_sequence: std.atomic.Value(u64) = .init(0),
    requested_size: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn create(allocator: std.mem.Allocator, channel: *Channel) !*Output {
        return createWithWake(allocator, channel, null);
    }

    /// Duplicate before publishing Output to Surface. This handle stays fixed
    /// until GUI detaches Output and every render guard has returned.
    pub fn createWithWake(allocator: std.mem.Allocator, channel: *Channel, transport_wake: ?w32.HANDLE) !*Output {
        if (!channel.source or channel.closing) return error.InvalidChannel;
        const self = try allocator.create(Output);
        errdefer allocator.destroy(self);
        const row = try allocator.alloc(u8, channel.mapped.layout.stride);
        errdefer allocator.free(row);
        const wake = w32.CreateEventW(null, 0, 0, null) orelse return error.EventFailed;
        errdefer _ = w32.CloseHandle(wake);
        var duplicate: ?w32.HANDLE = null;
        if (transport_wake) |event| {
            var handle: w32.HANDLE = undefined;
            if (DuplicateHandle(GetCurrentProcess(), event, GetCurrentProcess(), &handle, 0x2, 0, 0) == 0) return error.EventFailed;
            duplicate = handle;
        }
        self.* = .{ .allocator = allocator, .channel = channel, .row_scratch = row, .wake = wake, .transport_wake = duplicate };
        return self;
    }

    fn signal(self: *Output) void {
        _ = w32.SetEvent(self.wake);
        if (self.transport_wake) |wake| _ = w32.SetEvent(wake);
    }

    /// The IPC worker waits on this auto-reset event and sends latest_sequence,
    /// not one network message per render frame. No callback or HWND on render.
    pub fn notificationHandle(self: *const Output) w32.HANDLE {
        return self.wake;
    }

    pub fn begin(self: *Output, width: u32, height: u32) ?Frame {
        const layout = self.channel.mapped.layout;
        if (layout.width != width or layout.height != height) {
            const size = @as(u64, height) << 32 | width;
            if (self.requested_size.swap(size, .acq_rel) != size) self.signal();
            return null;
        }
        const writing = self.channel.beginWrite() catch |err| {
            if (err != error.WouldBlock) {
                self.failed.store(true, .release);
                self.signal();
            }
            return null;
        };
        // glReadPixels does not write stride padding; zero it before publication
        // so a newly created mapping can never expose stale allocator bytes.
        @memset(writing.lease.pixels, 0);
        return .{ .output = self, .writing = writing, .width = width, .height = height, .stride = layout.stride };
    }

    /// Only after Surface detached this output and every render guard returned.
    pub fn deinit(self: *Output) void {
        self.channel.deinit() catch @panic("remote output freed with an active frame");
        _ = w32.CloseHandle(self.wake);
        if (self.transport_wake) |wake| _ = w32.CloseHandle(wake);
        self.allocator.free(self.row_scratch);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const Frame = struct {
    output: *Output,
    writing: Write,
    width: u32,
    height: u32,
    stride: u32,
    finished: bool = false,

    pub fn pixels(self: *Frame) []u8 {
        return self.writing.lease.pixels;
    }
    /// Input is GL's bottom-up BGRA; the shared protocol is top-down BGRA.
    pub fn finish(self: *Frame, success: bool) void {
        if (self.finished) return;
        self.finished = true;
        defer self.writing.cancel();
        if (!success) {
            self.output.failed.store(true, .release);
            self.output.signal();
            return;
        }
        flipRows(self.writing.lease.pixels, self.stride, self.height, self.output.row_scratch);
        self.writing.lease.publishWritten() catch {
            self.output.failed.store(true, .release);
            self.output.signal();
            return;
        };
        self.output.latest_sequence.store(self.writing.lease.expected >> 3, .release);
        self.output.signal();
    }
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w32.HANDLE;
extern "kernel32" fn DuplicateHandle(w32.HANDLE, w32.HANDLE, w32.HANDLE, *w32.HANDLE, u32, i32, u32) callconv(.winapi) i32;

fn flipRows(pixels: []u8, stride: usize, height: usize, row: []u8) void {
    std.debug.assert(pixels.len == stride * height and row.len >= stride);
    for (0..height / 2) |y| {
        const top = pixels[y * stride ..][0..stride];
        const bottom = pixels[(height - y - 1) * stride ..][0..stride];
        @memcpy(row[0..stride], top);
        @memcpy(top, bottom);
        @memcpy(bottom, row[0..stride]);
    }
}

test "remote host flips BGRA rows including stride padding without changing channels" {
    var pixels = [_]u8{ 1, 2, 3, 4, 0, 0, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0, 9, 10, 11, 12, 0, 0, 0, 0 };
    var row: [8]u8 = undefined;
    flipRows(&pixels, 8, 3, &row);
    try std.testing.expectEqualSlices(u8, &.{ 9, 10, 11, 12, 0, 0, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0, 1, 2, 3, 4, 0, 0, 0, 0 }, &pixels);
    flipRows(&pixels, 8, 3, &row);
    try std.testing.expectEqual(@as(u8, 1), pixels[0]);
}

test "remote host production tree frame and lifetime entrypoints compile" {
    const functions = .{ &Host.create, &Host.adoptTree, &Host.addOutput, &Host.replaceOutput, &Host.deinit, &Output.create, &Output.begin, &Output.notificationHandle, &Output.deinit, &Frame.pixels, &Frame.finish };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}
