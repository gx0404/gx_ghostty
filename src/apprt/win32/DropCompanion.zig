//! Explicit medium-integrity receiver for one verified elevated process.
//! A visible, self-owned OLE target forwards only typed drop data. It never
//! changes UIPI filters, installs hooks, elevates, or pastes into a local PTY.
const Self = @This();
const std = @import("std");
const App = @import("App.zig");
const w32 = @import("win32.zig");
const native = @import("ipc/native.zig");
const security = @import("ipc/Security.zig");
const transport = @import("ipc/DropBroker.zig");
const Ole = @import("ole_drop.zig");
const refs = @import("../../gx/ui_ref.zig");
const i18n = @import("../../gx/i18n.zig");
const d2d = @import("ui/d2d.zig");
const style = @import("ui/style.zig");
const wstr = @import("ui/wstr.zig");
const log = std.log.scoped(.win32_drop_companion);
pub const Process = security.policy.Process;
pub const wake_message = w32.WM_APP + 0x6c;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDropCompanion");
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

app: *App,
endpoint: transport.Endpoint,
target_process: security.Facts,
hwnd: ?w32.HWND = null,
reference: refs.Reference,
attachment: refs.Attachment,
canvas: d2d.Canvas,
target: ?*Ole.Target = null,
queued: ?Ole.data.Payload = null,
worker: ?*Worker = null,
closing: bool = false,
draining: bool = false,
status: Status = .ready,
const Status = enum { ready, queued, waiting, pasted, cancelled, rejected, target_gone, expired, failed, unknown };

const Worker = struct {
    allocator: std.mem.Allocator,
    attempt: transport.Attempt,
    payload: Ole.data.Payload,
    stop: native.HANDLE,
    notify_hwnd: w32.HWND,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    outcome: ?transport.contract.Outcome = null,
    failure: ?anyerror = null,

    fn create(allocator: std.mem.Allocator, attempt: transport.Attempt, payload: Ole.data.Payload, notify_hwnd: w32.HWND) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const stop = try native.event();
        errdefer _ = native.CloseHandle(stop);
        self.* = .{ .allocator = allocator, .attempt = attempt, .payload = payload, .stop = stop, .notify_hwnd = notify_hwnd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *Worker) void {
        defer {
            self.done.store(true, .release);
            _ = w32.PostMessageW(self.notify_hwnd, wake_message, 0, 0);
        }
        var paths: [Ole.data.max_files][]const u8 = undefined;
        const payload: transport.contract.Payload = switch (self.payload.content) {
            .text => |text| .{ .text = text },
            .files => |files| blk: {
                if (files.len > paths.len) {
                    self.failure = error.TooLarge;
                    return;
                }
                for (files, 0..) |file, index| paths[index] = file;
                break :blk .{ .files = paths[0..files.len] };
            },
        };
        self.outcome = self.attempt.sendCancelable(self.allocator, payload, self.stop) catch |err| {
            self.failure = err;
            return;
        };
    }
    fn destroy(self: *Worker) void {
        _ = native.SetEvent(self.stop);
        if (self.thread) |thread| thread.join();
        self.payload.deinit();
        _ = native.CloseHandle(self.stop);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

/// Called only for an explicit launch with a target PID and creation time.
/// App retains this owner and continues its ordinary outer message loop.
pub fn create(app: *App, target_process: Process) !*Self {
    const local = try security.inspect(native.GetCurrentProcessId());
    defer local.deinit();
    if (local.identity.integrity != .medium or local.identity.elevated) return error.MediumIntegrityRequired;
    const peer = try security.inspect(target_process.pid);
    errdefer peer.deinit();
    if (!std.meta.eql(peer.identity.process, target_process) or peer.identity.integrity != .high or !peer.identity.elevated) return error.ElevatedTargetRequired;
    const domain = try App.instanceIsolation(app.core_app.alloc, app.config.class);
    // Verify before displaying any trusted receiver UI, using the very process
    // object retained by this owner. Pipe establishment repeats these checks.
    try transport.contract.authenticate(local.identity, peer.identity, target_process, domain, domain);
    try security.verifyImage(local, peer);
    const endpoint = try transport.Endpoint.forTarget(domain, target_process);
    const factory = app.uiFactory() orelse return error.Direct2DUnavailable;
    const allocator = app.core_app.alloc;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const owner = try app.ui_ids.create(.window);
    // Reserve a separate synthetic identity for this receiver, never register it
    // as a core Surface or resolve it through App's terminal registry.
    const serial = try app.ui_ids.create(.tab);
    const attachment = try app.ui_ids.attach(try app.ui_ids.surface(serial.id), owner);
    self.* = .{ .app = app, .endpoint = endpoint, .target_process = peer, .reference = owner, .attachment = attachment, .canvas = d2d.Canvas.init(factory) };
    errdefer self.canvas.deinit();
    const definition: w32.WNDCLASSEXW = .{ .cbSize = @sizeOf(w32.WNDCLASSEXW), .style = w32.CS_HREDRAW | w32.CS_VREDRAW, .lpfnWndProc = &wndProc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = app.hinstance, .hIcon = w32.LoadIconW(app.hinstance, w32.IDI_GHOSTTY), .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW), .hbrBackground = null, .lpszMenuName = null, .lpszClassName = class_name, .hIconSm = null };
    if (w32.RegisterClassExW(&definition) == 0 and GetLastError() != 1410) return error.ClassRegistrationFailed;
    var title: [256]u16 = undefined;
    const hwnd = w32.CreateWindowExW(0, class_name, wstr.bufZ(&title, i18n.tr("Drop into elevated terminal")).ptr, w32.WS_OVERLAPPEDWINDOW, w32.CW_USEDEFAULT, w32.CW_USEDEFAULT, 520, 260, null, null, app.hinstance, null) orelse return error.WindowCreateFailed;
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    errdefer self.retireWindow();
    // Construction can pump WM_CLOSE. Reserve this native handle until OLE has
    // unwound registration, exactly as the regular Surface path does.
    {
        app.beginDropRegistration(hwnd);
        defer app.endDropRegistration();
        self.target = try Ole.Target.create(allocator, &app.com_apartment, hwnd, attachment, .{ .context = self, .is_live = live, .post = post, .feedback = feedback });
    }
    if (self.closing or native.WaitForSingleObject(peer.process, 0) != 258) return error.TargetExited;
    _ = w32.ShowWindow(hwnd, 1);
    if (self.closing or self.hwnd != hwnd) return error.Closed;
    _ = w32.SetForegroundWindow(hwnd);
    if (self.closing or self.hwnd != hwnd) return error.Closed;
    app.stopQuitTimer();
    return self;
}

pub fn keepsAlive(self: *const Self) bool {
    return !self.closing;
}
fn live(context: *anyopaque, attachment: refs.Attachment) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return !self.closing and !self.app.quit_requested and !self.app.drop_closing and self.hwnd != null and self.attachment.matches(attachment) and native.WaitForSingleObject(self.target_process.process, 0) == 258;
}
fn post(context: *anyopaque, attachment: refs.Attachment, payload: Ole.data.Payload) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!live(context, attachment) or self.queued != null or self.worker != null) return false;
    const destination = self.app.msg_hwnd orelse return false;
    self.queued = payload;
    if (w32.PostMessageW(destination, wake_message, 0, 0) == 0) {
        self.queued = null;
        return false;
    }
    self.status = .queued;
    self.invalidate();
    return true;
}
fn feedback(context: *anyopaque, _: refs.Attachment, phase: Ole.Phase, _: w32.POINT, _: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (phase == .rejected and self.worker == null and self.queued == null) self.status = .rejected;
    self.invalidate();
}

/// GUI outer boundary only. Worker has no App, Surface, COM or UI callbacks.
pub fn drain(self: *Self) void {
    if (self.draining) return;
    self.draining = true;
    defer self.draining = false;
    if (self.closing) return;
    if (self.app.quit_requested or self.app.drop_closing) {
        self.beginClose();
        return;
    }
    if (self.worker) |worker| if (worker.done.load(.acquire)) {
        if (worker.outcome) |outcome| {
            self.status = switch (outcome) {
                .pasted => .pasted,
                .cancelled => .cancelled,
                .rejected => .rejected,
                .target_gone => .target_gone,
                .expired => .expired,
                .paste_failed => .failed,
            };
        } else if (worker.failure) |err| {
            self.status = if (err == error.ResultUnknown) .unknown else .failed;
            log.warn("drop companion request failed: {}", .{err});
        }
        // Pin the authenticated epoch for later drops to this same process.
        self.endpoint.host_epoch = worker.attempt.endpoint.host_epoch;
        worker.destroy();
        self.worker = null;
        self.invalidate();
    };
    if (native.WaitForSingleObject(self.target_process.process, 0) != 258) {
        self.status = .target_gone;
        if (self.queued) |*payload| payload.deinit();
        self.queued = null;
        self.invalidate();
        return;
    }
    if (self.worker == null) if (self.queued) |payload| {
        // Use the App's lifetime issuer so closing/reopening a companion in the
        // same process never reuses a broker key for different payload bytes.
        const request = self.app.ui_ids.create(.tab) catch {
            self.beginClose();
            return;
        };
        const worker = Worker.create(self.app.core_app.alloc, .{ .endpoint = self.endpoint, .source_epoch = self.app.ui_ids.epoch, .request = request.id }, payload, self.app.msg_hwnd orelse return) catch |err| {
            log.warn("drop companion worker unavailable: {}", .{err});
            var owned = payload;
            owned.deinit();
            self.queued = null;
            self.status = .failed;
            self.invalidate();
            return;
        };
        self.queued = null;
        self.worker = worker;
        self.status = .waiting;
        self.invalidate();
    };
}

/// Safe inside WndProc: make COM inert but revoke/destroy only at outer boundary.
pub fn beginClose(self: *Self) void {
    if (self.closing) return;
    self.closing = true;
    self.attachment = .{};
    self.retireWindow();
    if (self.worker) |worker| _ = native.SetEvent(worker.stop);
    if (self.app.msg_hwnd) |hwnd| _ = w32.PostMessageW(hwnd, wake_message, 0, 0);
}

/// Once callbacks and GWLP_USERDATA are inert, App's existing outer reaper owns
/// native destruction after RevokeDragDrop. It never retains this owner.
fn retireWindow(self: *Self) void {
    const hwnd = self.hwnd;
    if (hwnd) |window| {
        _ = w32.SetWindowLongPtrW(window, w32.GWLP_USERDATA, 0);
        _ = w32.ShowWindow(window, w32.SW_HIDE);
    }
    if (self.target) |target| {
        self.target = null;
        self.app.retireDropTarget(target);
    }
    if (hwnd) |window| {
        if (!self.app.deferDropWindowDestroy(window)) _ = w32.DestroyWindow(window);
    }
    self.hwnd = null;
}

/// App invokes at the outer boundary, before COM apartment/msg_hwnd teardown.
/// Cancellation stops local waiting; a submitted request is never replayed.
pub fn destroy(self: *Self) !void {
    if (self.draining) return error.Busy;
    self.beginClose();
    if (self.worker) |worker| worker.destroy();
    if (self.queued) |*payload| payload.deinit();
    self.canvas.deinit();
    self.target_process.deinit();
    const allocator = self.app.core_app.alloc;
    allocator.destroy(self);
}

fn invalidate(self: *Self) void {
    if (self.hwnd) |hwnd| _ = w32.InvalidateRect(hwnd, null, 0);
}
fn statusText(status: Status) []const u8 {
    return switch (status) {
        .ready => i18n.tr("Drop text or files here. The elevated terminal will ask for confirmation."),
        .queued, .waiting => i18n.tr("Waiting for confirmation and paste in the elevated terminal..."),
        .pasted => i18n.tr("Pasted into the elevated terminal. No Enter key was sent."),
        .cancelled => i18n.tr("The paste was cancelled."),
        .rejected => i18n.tr("The dropped content was rejected."),
        .target_gone => i18n.tr("The selected elevated terminal is no longer available."),
        .expired => i18n.tr("The drop request expired. Drop again only if you still want to paste."),
        .failed => i18n.tr("The drop could not be completed."),
        .unknown => i18n.tr("The paste result is unknown. Check the elevated terminal before dropping again."),
    };
}
fn paint(self: *Self) void {
    const hwnd = self.hwnd orelse return;
    var painting: w32.PAINTSTRUCT = undefined;
    _ = w32.BeginPaint(hwnd, &painting) orelse return;
    defer _ = w32.EndPaint(hwnd, &painting);
    const dpi = @max(48, w32.GetDpiForWindow(hwnd));
    if (!self.canvas.beginHwnd(hwnd, dpi)) return;
    const colors = style.Tokens.fromConfig(&self.app.config);
    self.canvas.clear(colors.background);
    var rect: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rect);
    const scale = @as(f32, @floatFromInt(dpi)) / 96;
    const width = @as(f32, @floatFromInt(@max(0, rect.right))) / scale;
    const height = @as(f32, @floatFromInt(@max(0, rect.bottom))) / scale;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    i18n.format(&writer, i18n.tr("Elevated terminal process: {pid}"), .{ .pid = self.endpoint.host.pid }) catch {};
    self.canvas.drawText(writer.buffered(), .{ .x = 24, .y = 20, .w = @max(0, width - 48), .h = 28 }, .{ .size = 16, .color = colors.foreground });
    self.canvas.drawText(statusText(self.status), .{ .x = 24, .y = 62, .w = @max(0, width - 48), .h = @max(0, height - 86) }, .{ .size = 14, .color = colors.foreground, .wrap = true });
    if (self.canvas.finish() == .recreate) self.invalidate();
}
pub fn wndProc(hwnd: w32.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const pointer = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self: *Self = if (pointer != 0) @ptrFromInt(@as(usize, @bitCast(pointer))) else return w32.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        w32.WM_PAINT => {
            self.paint();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_SIZE => {
            self.invalidate();
            return 0;
        },
        w32.WM_DPICHANGED => {
            if (lparam != 0) {
                const rect: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER);
            }
            self.canvas.discardTarget();
            self.invalidate();
            return 0;
        },
        w32.WM_CLOSE => {
            self.beginClose();
            return 0;
        },
        w32.WM_GETOBJECT => if (w32.objectId(lparam) == w32.OBJID_CLIENT) return 0,
        else => {},
    }
    return w32.DefWindowProcW(hwnd, message, wparam, lparam);
}

test "drop companion production receiver and lifecycle entrypoints compile" {
    inline for (.{ &create, &drain, &beginClose, &destroy, &wndProc }) |function| try std.testing.expect(@intFromPtr(function) != 0);
}
