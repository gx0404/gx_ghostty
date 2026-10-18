//! A posted tab detach followed by the native move loop and a same-host merge.
//! Native loops may destroy windows: only value references survive SendMessage.
const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const refs = @import("../../gx/ui_ref.zig");
const WM_SYSCOMMAND: u32 = 0x0112;
const SC_MOVE: usize = 0xF010;
extern "user32" fn GetTopWindow(?w32.HWND) callconv(.winapi) ?w32.HWND;
extern "user32" fn GetWindow(w32.HWND, u32) callconv(.winapi) ?w32.HWND;
extern "user32" fn GetAsyncKeyState(i32) callconv(.winapi) i16;
extern "user32" fn SetWindowsHookExW(i32, *const anyopaque, ?w32.HINSTANCE, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn UnhookWindowsHookEx(*anyopaque) callconv(.winapi) i32;
extern "user32" fn CallNextHookEx(?*anyopaque, i32, usize, isize) callconv(.winapi) isize;
extern "dwmapi" fn DwmGetWindowAttribute(w32.HWND, u32, *anyopaque, u32) callconv(.winapi) i32;
extern "user32" fn GetClassNameW(w32.HWND, [*]u16, i32) callconv(.winapi) i32;
extern "user32" fn GetWindowThreadProcessId(w32.HWND, *u32) callconv(.winapi) u32;
const log = std.log.scoped(.win32);

const escape = struct {
    var hook: ?*anyopaque = null;
    var active = false;
    var held = false;
    var cancelled = false;
    fn begin() !void {
        if (active) return error.TransferBusy;
        if (hook == null) hook = SetWindowsHookExW(2, @ptrCast(&keyboard), null, w32.GetCurrentThreadId());
        if (hook == null) return error.KeyboardHookFailed;
        cancelled = false;
        active = true;
    }
    fn end() void {
        active = false;
        if (!held) if (hook) |value| {
            hook = null;
            _ = UnhookWindowsHookEx(value);
        };
    }
    fn keyboard(code: i32, key: usize, flags: isize) callconv(.winapi) isize {
        if (code >= 0 and key == w32.VK_ESCAPE) {
            const up = @as(usize, @bitCast(flags)) >> 31 & 1 != 0;
            if (active and !up) {
                cancelled = true;
                held = true;
            } else if (!active and held) {
                if (up) {
                    held = false;
                    end();
                }
                return 1;
            } else if (up) held = false;
        }
        // The native move loop must itself see Escape to restore its rectangle.
        return CallNextHookEx(null, code, key, flags);
    }
};

/// Native move cancellation is broader than Escape (e.g. WM_CANCELMODE).
/// Only the GUI thread and the currently active move loop can set this flag.
pub fn cancelNativeMove() void {
    if (escape.active) escape.cancelled = true;
}

pub fn run(app: *App, source_reference: refs.Reference, tab: refs.Reference, point: w32.POINT) !void {
    const source = app.resolveWindow(source_reference) orelse return;
    if (source.is_quick_terminal or source.tab_transfer_active) return;
    const original_index = source.resolveTab(tab) orelse return;
    try escape.begin();
    defer escape.end();
    const detached = source.tab_count > 1;
    const moving_reference = if (detached) try source.detachTabForDrag(tab) else source_reference;
    const moving = app.resolveWindow(moving_reference) orelse return;
    const hwnd = moving.hwnd orelse return;
    if (detached) {
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &rect) != 0) {
            _ = w32.SetWindowPos(hwnd, null, point.x - @divTrunc(rect.right - rect.left, 2), point.y - @divTrunc(moving.chromeHeight(), 2), 0, 0, w32.SWP_NOSIZE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        }
    }
    const current = app.resolveWindow(moving_reference) orelse return;
    if (current.hwnd != hwnd) return;
    if (@as(u16, @bitCast(GetAsyncKeyState(1))) & 0x8000 != 0) {
        const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
        const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
        _ = w32.SendMessageW(hwnd, WM_SYSCOMMAND, SC_MOVE | 2, @bitCast(@as(usize, @as(u32, x) | (@as(u32, y) << 16))));
    }
    const location = app.resolveTab(tab) orelse return;
    if (escape.cancelled or @as(u16, @bitCast(GetAsyncKeyState(1))) & 0x8000 != 0) {
        if (detached and app.resolveWindow(source_reference) != null) {
            _ = try location.window.moveTabToWindow(tab, source_reference, original_index);
        }
        return;
    }
    var cursor: w32.POINT = undefined;
    if (w32.GetCursorPos_(&cursor) == 0) return;
    // Test-gated drop evidence; off-gate the counters never change.
    const fixture_gate = @import("remote_test.zig").enabled();
    app.fixture.count(fixture_gate, "transfer_drops");
    const destination = targetAt(app, location.window.ui_reference, cursor) orelse return;
    const fresh = app.resolveTab(tab) orelse return;
    switch (destination) {
        .local => |local| if (try fresh.window.moveTabToWindow(tab, local.window, local.position)) app.fixture.count(fixture_gate, "transfer_merges"),
        .remote => |process| {
            const returned = app.remote.returnRemoteTab(app, tab, process) catch |err| {
                showRemoteError(fresh.window, err);
                return;
            };
            if (!returned) app.remote.beginAt(app, fresh.window.ui_reference, tab, process, .{ .x = cursor.x, .y = cursor.y }) catch |err| {
                showRemoteError(fresh.window, err);
            };
        },
    }
}
fn showRemoteError(window: *@import("Window.zig"), err: anyerror) void {
    const i18n = @import("../../gx/i18n.zig");
    const text = switch (err) {
        error.MixedRemoteTransfer => i18n.tr("A tab containing local and remote panes cannot move to another process."),
        error.WrongSourceHost => i18n.tr("Return this remote tab to its original process."),
        else => i18n.tr("The tab could not be transferred. Its terminals are unchanged."),
    };
    window.showNotice(.{ .severity = .warning, .title = i18n.tr("Cannot move tab"), .body = text }, null);
}

const Target = union(enum) {
    local: struct { window: refs.Reference, position: usize },
    remote: @import("ipc/Security.zig").policy.Process,
};
fn targetAt(app: *App, moving: refs.Reference, point: w32.POINT) ?Target {
    const trace = @import("remote_test.zig").enabled();
    var cursor = GetTopWindow(null);
    while (cursor) |hwnd| : (cursor = GetWindow(hwnd, 2)) {
        if (w32.IsWindowVisible_(hwnd) == 0 or w32.IsIconic(hwnd) != 0) continue;
        var cloaked: u32 = 0;
        if (DwmGetWindowAttribute(hwnd, 14, &cloaked, @sizeOf(u32)) >= 0 and cloaked != 0) continue;
        if (app.resolveWindow(moving)) |window| if (window.hwnd == hwnd) continue;
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &rect) == 0 or point.x < rect.left or point.x >= rect.right or point.y < rect.top or point.y >= rect.bottom) continue;
        // The first visible window under the pointer owns the hit. Do not drop
        // through an unrelated app to a Ghostty window behind it.
        for (app.windows.items) |window| {
            if (window.hwnd != hwnd) continue;
            const full = window.tab_count >= @import("Window.zig").MAX_TABS;
            if (window.closing or !window.ui_attachment.isValid() or window.is_quick_terminal or full) {
                // Gated evidence that a real drop hit a live full target.
                if (full and !window.closing and !window.is_quick_terminal) app.fixture.count(trace, "transfer_full_refusals");
                fixtureTarget(trace, hwnd, if (full) "full" else "unavailable");
                return null;
            }
            var client = point;
            if (w32.ScreenToClient(hwnd, &client) == 0) return null;
            const position = window.tab_bar.transferSlotAt(client) orelse {
                fixtureTarget(trace, hwnd, "no_slot");
                return null;
            };
            fixtureTarget(trace, hwnd, "local");
            return .{ .local = .{ .window = window.ui_reference, .position = position } };
        }
        // This is discovery only. A class name/PID is never authentication:
        // the remote service rechecks both tokens, executable and isolation.
        var name: [64]u16 = undefined;
        const length = GetClassNameW(hwnd, &name, name.len);
        if (length <= 0 or !std.mem.eql(u16, name[0..@intCast(length)], App.WINDOW_CLASS_NAME)) {
            fixtureTarget(trace, hwnd, "foreign");
            return null;
        }
        fixtureTarget(trace, hwnd, "peer");
        var client = point;
        if (w32.ScreenToClient(hwnd, &client) == 0 or client.y < 0 or client.y >= @divTrunc(@as(i32, @intCast(w32.GetDpiForWindow(hwnd))), 2)) return null;
        var pid: u32 = 0;
        if (GetWindowThreadProcessId(hwnd, &pid) == 0 or pid == 0) return null;
        const security = @import("ipc/Security.zig");
        const peer = security.inspect(pid) catch return null;
        defer peer.deinit();
        const local = security.inspect(@import("ipc/native.zig").GetCurrentProcessId()) catch return null;
        defer local.deinit();
        security.verifyImage(local, peer) catch return null;
        return .{ .remote = peer.identity.process };
    }
    fixtureTarget(trace, null, "none");
    return null;
}

/// Test-gated record of the window that decided a real drop (class names are
/// ASCII; anything else is written as '?'). Off-gate it reads nothing.
fn fixtureTarget(enabled: bool, hwnd: ?w32.HWND, outcome: []const u8) void {
    if (!enabled) return;
    var pid: u32 = 0;
    var wide: [64]u16 = undefined;
    var class: [64]u8 = undefined;
    var count: usize = 0;
    if (hwnd) |value| {
        _ = GetWindowThreadProcessId(value, &pid);
        const length = GetClassNameW(value, &wide, wide.len);
        if (length > 0) for (wide[0..@intCast(length)]) |unit| {
            class[count] = if (unit >= 0x20 and unit < 0x7f) @intCast(unit) else '?';
            count += 1;
        };
    }
    log.info("fixture_transfer_target outcome={s} hwnd=0x{x} pid={d} class={s}", .{ outcome, if (hwnd) |value| @intFromPtr(value) else 0, pid, class[0..count] });
}

test "tab transfer target trace is inert without the explicit test gate" {
    // Undefined handle proves the disabled path reads no window state.
    fixtureTarget(false, @ptrFromInt(0x10), "foreign");
}
