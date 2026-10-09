// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 Surface. Each Surface corresponds to one child HWND whose
//! private device context the renderer draws to with OpenGL (WGL).
//!
//! The Surface translates Win32 input (keys, IME, mouse, drops) for the
//! core surface, implements the apprt surface callbacks (clipboard,
//! title, cursor) and orchestrates its popups: `ui/Palette.zig`
//! (`palette`), `ui/SearchBar.zig` (`search_bar`), `ui/LinkPreview.zig`
//! (`link_preview`), the context menu in `ui/Menu.zig` and the
//! confirmations in `ui/Dialogs.zig`.
//!
//! Clipboard access that another application blocks is retried from
//! timers; dropped and pasted files are quoted for the shell running in
//! the terminal (`gx.path_quote`). The renderer thread reports frames
//! (`signalFrameDrawn`) and GPU resets (`gpuContextReset`) back here.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");
const global = @import("../../global.zig");
const gx_win32_input = @import("../../gx/win32_input.zig");
const gx_confirm = @import("../../gx/confirm.zig");
const gx_proc = @import("../../gx/proc.zig");
const path_quote = @import("../../gx/path_quote.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const Scrollbar = @import("Scrollbar.zig").Scrollbar;
const Dialogs = @import("ui/Dialogs.zig");
const LinkPreview = @import("ui/LinkPreview.zig");
const Menu = @import("ui/Menu.zig");
const Palette = @import("ui/Palette.zig");
const SearchBar = @import("ui/SearchBar.zig");

const log = std.log.scoped(.win32);

/// The Win32 window handle.
hwnd: ?w32.HWND = null,

/// Device context for the window (with CS_OWNDC, this persists for the
/// lifetime of the window). The renderer creates its OpenGL context for
/// this DC on the render thread.
hdc: ?w32.HDC = null,

/// Current client area dimensions in pixels.
width: u32 = 800,
height: u32 = 600,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// The parent App.
app: *App,

/// The parent Window that contains this Surface as a tab.
parent_window: *Window = undefined,

/// Last title reported by the core for getTitle/copy-title consumers.
title_len: usize = 0,
title: [4096]u8 = std.mem.zeroes([4096]u8),

/// The core terminal surface. Initialized by init() after creating
/// the window and WGL context. Manages fonts, renderer, PTY, and IO.
core_surface: CoreSurface = undefined,

/// Whether core_surface has been fully initialized. Win32 messages
/// (WM_SETFOCUS, WM_SIZE, etc.) can arrive during init before
/// core_surface is ready — handlers must check this flag.
core_surface_ready: bool = false,

/// Whether core_surface.init() completed successfully (ever).
/// Different from core_surface_ready which is cleared during shutdown.
core_surface_initialized: bool = false,

/// Buffered high surrogate from WM_CHAR for supplementary plane characters.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages (surrogate pair).
high_surrogate: u16 = 0,

/// Bitmask of currently-pressed mouse buttons (left=1, right=2,
/// middle=4). Used so SetCapture/ReleaseCapture only run on the
/// 0→nonzero and nonzero→0 transitions; without this, a right-click
/// in the middle of a left-button drag would call SetCapture again
/// (replacing capture) and the next button-up would release prematurely.
mouse_button_mask: u3 = 0,

/// Whether an IME composition session is active. When true, handleKeyEvent
/// skips VK_PROCESSKEY events (the IME is intercepting keys), and composed
/// text is extracted from WM_IME_COMPOSITION instead.
ime_composing: bool = false,

/// Set to true when handleKeyEvent produced text via ToUnicode. Any
/// subsequent WM_CHAR (from IME, SendInput Unicode/VK_PACKET, or
/// PostMessage) is then suppressed to avoid double input. Reset to false
/// when WM_CHAR arrives (whether suppressed or processed).
key_event_produced_text: bool = false,

/// ToUnicode output of the latest key message, the text of its
/// win32-input-mode record (`gx_win32_input.KeyMessage.text`).
key_utf16: [4]u16 = undefined,

/// Scan codes of keys whose press went to the IME (VK_PROCESSKEY), so
/// handleKeyEvent does not report their release as a key of its own.
ime_keys: std.StaticBitSet(256) = .initEmpty(),

/// Whether the log already noted that this terminal sends win32-input-mode
/// records (`noteWin32InputMode`).
win32_input_logged: bool = false,

/// Whether the user is actively dragging a window border/titlebar.
/// During live resize, handleResize blocks until the renderer draws
/// one frame at the new size (or a timeout expires), eliminating the
/// visual flicker from the DWM stretching stale content.
in_live_resize: bool = false,

/// Manual-reset event signaled by the renderer thread after presenting
/// a frame (see `signalFrameDrawn`). The main thread waits on this during
/// live resize to synchronize rendering with the DWM compositor.
frame_event: ?w32.HANDLE = null,

/// Set by `handleResize` during a live resize after it asked the renderer
/// for a frame at the new size, until something waited for that frame.
resize_frame_pending: bool = false,

/// Set by WM_GHOSTTY_SIMULATE_GPU_RESET, taken by the renderer thread
/// (`takeSimulatedGpuReset`).
simulate_gpu_reset: std.atomic.Value(bool) = .init(false),

/// Themed scrollbar (custom layered-popup overlay).
/// Created lazily after the surface HWND exists.
scrollbar: ?*Scrollbar = null,

/// The current mouse cursor. Cached so WM_SETCURSOR can restore it
/// (DefWindowProc resets the cursor to the class cursor on every
/// WM_SETCURSOR, so we must override it ourselves).
current_cursor: ?w32.HCURSOR = null,

/// When false, WM_SETCURSOR sets the cursor to null (invisible). The
/// core surface toggles this for typing-while-mouse-still etc.
mouse_visible: bool = true,

/// Find bar popup (see ui/SearchBar.zig).
search_bar: SearchBar = .{},

/// Hovered-URL preview popup (see ui/LinkPreview.zig).
link_preview: LinkPreview = .{},

/// Last visibility state DELIVERED to the core occlusionCallback, so
/// setVisible can drop redundant updates on the producer side. This must
/// happen here: occlusionCallback pushes into the renderer mailbox with
/// a bounded timeout, and the consumer-side dedupe in the renderer
/// thread never runs while that mailbox is undrained, so repeated
/// identical pushes (e.g. layoutSplits on every WM_SIZE of a resize
/// drag) would stall the GUI thread and drop. Reset to null when
/// delivery fails so the next call retries.
last_reported_visible: ?bool = null,

/// Command palette popup (see ui/Palette.zig).
palette: Palette = .{},

/// Clipboard accesses waiting for another application to close the
/// clipboard (see `retryClipboardRead` and `writeClipboard`).
pending_clipboard_read: ?PendingClipboardRead = null,
pending_clipboard_write: ?PendingClipboardWrite = null,

/// The command this terminal was started with instead of the configured
/// one (`InitOptions.command`, e.g. a launch profile), so that its tab can
/// be duplicated (see ui/Menu.zig).
launch_command: ?configpkg.Command = null,

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// SplitTree view protocol: increment reference count.
pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// SplitTree view protocol: decrement reference count.
pub fn unref(self: *Surface, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        self.deinit();
        alloc.destroy(self);
    }
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}

/// Initialize a new Surface by creating a Win32 child window, then
/// initialize the core terminal surface (fonts, renderer, PTY, IO).
pub fn init(
    self: *Surface,
    app: *App,
    parent: *Window,
    context: apprt.surface.NewSurfaceContext,
) !void {
    return self.initWithOptions(app, parent, .{ .context = context });
}

pub const InitOptions = struct {
    context: apprt.surface.NewSurfaceContext,
    command: ?*const configpkg.Command = null,
    title: ?[:0]const u8 = null,
};

/// Initialize a surface with optional per-surface config overrides. The
/// overrides are cloned into the surface config arena before this function
/// returns, so callers only need to keep them alive for the duration of init.
pub fn initWithOptions(
    self: *Surface,
    app: *App,
    parent: *Window,
    options: InitOptions,
) !void {
    self.* = .{
        .app = app,
        .parent_window = parent,
    };

    // Create a manual-reset event for synchronizing resize with the
    // renderer thread. Manual-reset so we control exactly when it's reset.
    self.frame_event = w32.CreateEventW(null, 1, 0, null);

    // Create a WS_CHILD window inside the parent Window container. OpenGL
    // windows must clip their siblings and children.
    const parent_hwnd = parent.hwnd orelse return error.Win32Error;
    const sr = parent.surfaceRect();
    const hwnd = w32.CreateWindowExW(
        0,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_CLIPCHILDREN | w32.WS_CLIPSIBLINGS,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Accept dropped files so a file dragged onto the terminal pastes
    // its path. WM_DROPFILES is delivered to surfaceWndProc.
    w32.DragAcceptFiles(hwnd, 1);

    // Store the Surface pointer in the window's GWLP_USERDATA so that
    // the WndProc can retrieve it.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get the device context. With CS_OWNDC, this DC is valid for
    // the lifetime of the window.
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;
    errdefer {
        _ = w32.ReleaseDC(hwnd, self.hdc.?);
        self.hdc = null;
    }

    // A window's pixel format can only be set once; the renderer creates
    // its context for this DC later, on the render thread.
    try app.core_app.device.setPixelFormat(self.hdc.?);

    // Query the initial DPI and size
    self.updateDpiScale();
    self.updateClientSize();

    log.debug("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });

    // Show the child window before initializing the core surface.
    // core_surface.init() spawns ConPTY + cmd.exe which needs the
    // window to be visible and have valid dimensions. On the old
    // top-level architecture, ShowWindow was called in createWindow()
    // before core_surface.init(). We must preserve that order.
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);

    // --- Core terminal surface initialization ---
    const alloc = app.core_app.alloc;

    // Create the themed scrollbar popup (owned by the surface HWND).
    self.scrollbar = try Scrollbar.create(alloc, hwnd, self);
    errdefer if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    };

    // Seed initial theme colors from the app config.
    if (self.scrollbar) |sb| {
        sb.setTheme(
            app.config.background.toTerminalRGB(),
            app.config.foreground.toTerminalRGB(),
        );
    }

    // Register this surface with the core app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Create a config copy for this surface.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, options.context);
    defer config.deinit();

    if (options.command) |command| {
        config.command = try command.clone(config.arenaAlloc());
        config.@"shell-integration" = .detect;
        self.launch_command = try command.clone(alloc);
    } else if (app.default_command) |command| {
        // `command` is not configured: the default launch profile.
        config.command = try command.clone(config.arenaAlloc());
    }
    errdefer if (self.launch_command) |*command| {
        command.deinit(alloc);
        self.launch_command = null;
    };
    if (options.title) |title| {
        config.title = try config.arenaAlloc().dupeZ(u8, title);
    }

    // Initialize the core surface. This sets up fonts, the renderer, PTY,
    // and spawns the renderer + IO threads.
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );

    // Mark the surface as ready. Before this point, Win32 messages
    // (triggered by ShowWindow etc.) must be ignored.
    self.core_surface_ready = true;
    self.core_surface_initialized = true;
}

pub fn deinit(self: *Surface) void {
    log.debug("surface deinit: start addr={x}", .{@intFromPtr(self)});

    if (self.core_surface_initialized) {
        // This joins the renderer thread, which destroys its GL context.
        log.debug("surface deinit: core_surface.deinit start", .{});
        self.core_surface.deinit();
        log.debug("surface deinit: core_surface.deinit done", .{});

        self.app.core_app.deleteSurface(self);
        log.debug("surface deinit: deleteSurface done", .{});
    }

    if (self.frame_event) |event| {
        _ = w32.CloseHandle(event);
        self.frame_event = null;
    }
    log.debug("surface deinit: frame_event closed", .{});

    if (self.launch_command) |*command| {
        command.deinit(self.app.core_app.alloc);
        self.launch_command = null;
    }

    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            log.debug("surface deinit: ReleaseDC", .{});
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }
    log.debug("surface deinit: DC released", .{});

    self.deinitGui();
}

/// Destroy resources only the GUI thread touches: the scrollbar, popup
/// windows, GDI objects, and the GWLP_USERDATA back-pointer.
fn deinitGui(self: *Surface) void {
    // Drop clipboard accesses still waiting for the clipboard.
    if (self.hwnd) |hwnd| {
        _ = w32.KillTimer(hwnd, CLIPBOARD_READ_TIMER);
        _ = w32.KillTimer(hwnd, CLIPBOARD_WRITE_TIMER);
    }
    if (self.pending_clipboard_read) |pending| destroyClipboardRequest(pending.state);
    self.pending_clipboard_read = null;
    if (self.pending_clipboard_write) |pending| _ = w32.GlobalFree(pending.data);
    self.pending_clipboard_write = null;

    // Destroy the themed scrollbar before the surface HWND is gone.
    if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    }

    // Destroy popup windows and their GDI resources.
    self.search_bar.deinit();
    self.link_preview.deinit();
    self.palette.deinit();

    // Don't call DestroyWindow on the child HWND here; it is destroyed
    // with its parent Window HWND. Just null the hwnd field so nothing
    // else tries to use it.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    }
    self.hwnd = null;
    log.debug("surface deinit: complete", .{});
}

/// Update the DPI scale factor from the window's DPI.
fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}

/// Update the cached client area size.
fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}

// -----------------------------------------------------------------------
// Methods called by the core Surface.zig (rt_surface.*)
// -----------------------------------------------------------------------

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    // Signal failure rather than returning a bogus {0,0} origin, so the
    // core skips the mouse computation instead of resolving it against the
    // top-left cell (which produced spurious hover/selection at 0,0).
    return error.GetCursorPosFailed;
}

pub fn getTitle(self: *const Surface) ?[:0]const u8 {
    if (self.title_len == 0) return null;
    return self.title[0..self.title_len :0];
}

/// Notify the core whether this surface is currently visible. When a surface
/// is occluded (background tab, hidden split-zoom pane, minimized window) the
/// renderer skips rebuilding/rendering frames until it is visible again
/// (src/renderer/Thread.zig). We must dedupe redundant states here on the
/// producer side: the core pushes every call into the renderer mailbox with
/// a bounded timeout, and the consumer-side dedupe in the renderer thread
/// never runs while that mailbox is undrained, so unconditionally
/// re-asserting the same visibility on every layout pass (one per WM_SIZE)
/// would fill the queue and stall the GUI thread for the push timeout each,
/// then drop.
pub fn setVisible(self: *Surface, visible: bool) void {
    // Hide the hovered-URL bubble when this surface is occluded so a stale
    // preview doesn't float over the newly-active tab, and the find bar
    // with the surface (it stays open and comes back with it).
    if (!visible) self.link_preview.hide();
    self.search_bar.setOwnerVisible(visible);
    if (!self.core_surface_ready) return;
    if (self.last_reported_visible == visible) return;
    self.last_reported_visible = visible;
    self.core_surface.occlusionCallback(visible) catch |err| {
        // Not delivered (mailbox full or wakeup failed): clear the
        // latch so the next call retries instead of treating this
        // state as sent — otherwise a dropped .visible=true could
        // leave the renderer invisible forever.
        self.last_reported_visible = null;
        log.warn("occlusionCallback failed err={}", .{err});
    };
}

/// Posted by `close` when the terminal to close still runs a program;
/// surfaceWndProc hands it to `confirmClose`.
pub const WM_APP_CONFIRM_CLOSE: u32 = w32.WM_APP + 0x60;

/// Close this terminal. `process_active` is the core's
/// `needsConfirmQuit`: with the GX idle-process check, true only while a
/// program other than an idle shell runs, so then the user is asked
/// first. The core calls this from its callbacks (a `close_surface`
/// binding, the child exiting), where the surface must stay alive, so
/// both the question and the close run from the message loop: WM_CLOSE
/// reaches `Window.closeSplitSurface` through surfaceWndProc.
pub fn close(self: *Surface, process_active: bool) void {
    log.debug("Surface.close called process_active={}", .{process_active});
    if (self.hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, if (process_active) WM_APP_CONFIRM_CLOSE else w32.WM_CLOSE, 0, 0);
    }
}

/// Handle `WM_APP_CONFIRM_CLOSE`: ask whether to close this terminal while
/// it still runs a program, listing those processes, then close it. The
/// dialog's modal loop keeps dispatching messages and can close the
/// terminal meanwhile.
pub fn confirmClose(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    if (self.core_surface_ready and self.core_surface.needsConfirmQuit()) {
        var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
        defer arena.deinit();
        var processes: std.ArrayList([]const u8) = .empty;
        self.appendBusyProcesses(arena.allocator(), &processes);
        if (Dialogs.confirmCloseSurface(self.parent_window.hwnd, processes.items) != .accept) return;
        const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (userdata == 0 or @as(usize, @bitCast(userdata)) != @intFromPtr(self)) return;
    }
    self.parent_window.closeSplitSurface(self);
}

/// Append the processes of this terminal that make closing it need a
/// confirmation (see `gx.confirm.appendBusyProcesses`), copied with
/// `arena`, to `out`. Appends nothing when they are unknown.
pub fn appendBusyProcesses(self: *Surface, arena: Allocator, out: *std.ArrayList([]const u8)) void {
    if (!self.core_surface_ready) return;
    gx_confirm.appendBusyProcesses(
        arena,
        global.io(),
        self.core_surface.getProcessInfo(.foreground_pid),
        self.core_surface.config.gx_idle_processes.list.items,
        out,
    ) catch |err| log.warn("cannot list the busy processes err={}", .{err});
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

/// Normalize the newline convention required by CF_UNICODETEXT before the
/// shared paste encoder sees it. Windows clipboard producers conventionally
/// use CRLF, while the non-bracketed encoder turns LF into CR. Passing CRLF
/// through unchanged would therefore produce CRCR and submit an extra blank
/// line for every pasted line. Preserve lone CR and LF bytes as supplied.
fn normalizeWindowsClipboardNewlines(data: []u8) []u8 {
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < data.len) {
        if (data[read_idx] == '\r' and
            read_idx + 1 < data.len and
            data[read_idx + 1] == '\n')
        {
            data[write_idx] = '\n';
            read_idx += 2;
        } else {
            data[write_idx] = data[read_idx];
            read_idx += 1;
        }
        write_idx += 1;
    }

    return data[0..write_idx];
}

test "normalize Windows clipboard newlines" {
    var data = "one\r\ntwo\r\n\r\nthree\rfour\n".*;
    const normalized = normalizeWindowsClipboardNewlines(data[0..]);
    try std.testing.expectEqualStrings("one\ntwo\n\nthree\rfour\n", normalized);
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return .unsupported;

    // Kitty writes carry their committed representations in the request, so
    // they only need to pass through the core's authorization flow.
    if (state == .kitty_write) {
        return self.completeClipboardRequestWithConfirmation(
            state,
            &.{},
            &.{},
        );
    }

    return self.readClipboard(state) catch |err| switch (err) {
        // Another application holds the clipboard open: try again shortly.
        error.ClipboardBusy => if (self.retryClipboardRead(state)) .started else busy: {
            log.warn("OpenClipboard failed", .{});
            break :busy .unavailable;
        },
        else => |e| return e,
    };
}

/// Timer ids on the surface window.
const CLIPBOARD_READ_TIMER: usize = 0x4352; // 'CR'
const CLIPBOARD_WRITE_TIMER: usize = 0x4357; // 'CW'

/// Opening a clipboard that another application holds open (clipboard
/// managers, remote desktop) is retried this many times from a timer,
/// after 10, 20, 40, ... ms (about 0.6 s in total), so a busy clipboard
/// never blocks the GUI thread.
const clipboard_retries = 6;

fn clipboardRetryDelay(attempt: u8) u32 {
    return @as(u32, 10) << @intCast(@min(attempt, 10));
}

/// Read the clipboard for `state` and complete the request. Fails with
/// `error.ClipboardBusy`, before touching the request, when the clipboard
/// cannot be opened.
fn readClipboard(self: *Surface, state: apprt.ClipboardRequest) !apprt.ClipboardReadResult {
    // Paste events request a target listing without reading clipboard data.
    // Win32 exposes files and Unicode text as a text/plain representation.
    if (state == .list) {
        const has_text = has_text: {
            if (w32.OpenClipboard(self.hwnd) == 0) return error.ClipboardBusy;
            defer _ = w32.CloseClipboard();
            break :has_text w32.GetClipboardData(w32.CF_HDROP) != null or
                w32.GetClipboardData(w32.CF_UNICODETEXT) != null;
        };
        if (!has_text) return .unavailable;

        return self.completeClipboardRequestWithConfirmation(
            state,
            &.{},
            &.{"text/plain"},
        );
    }

    const alloc = self.app.core_app.alloc;
    // Pasted files are quoted for the shell running in the terminal, which
    // is looked up before the clipboard is opened.
    const quoting: path_quote.Style = if (w32.IsClipboardFormatAvailable(w32.CF_HDROP) != 0)
        self.pathQuoting()
    else
        .windows;

    // Read the clipboard into an owned UTF-8 string in a tight scope so the
    // system clipboard is CLOSED before any modal confirmation dialog — the
    // dialog can be up for an unbounded time and would otherwise block every
    // other process's clipboard access.
    const utf8z: [:0]const u8 = blk: {
        if (w32.OpenClipboard(self.hwnd) == 0) return error.ClipboardBusy;
        defer _ = w32.CloseClipboard();

        // Files copied in Explorer land on the clipboard as CF_HDROP with no
        // text format at all, so a plain CF_UNICODETEXT read pastes nothing.
        // Paste them as space-separated, quoted paths — the same rendering
        // WM_DROPFILES already produces, and the parity match for macOS,
        // which pastes shell-escaped paths for file pasteboards.
        //
        // CF_HDROP wins when a source offers both formats: its text is
        // normally the same paths unquoted, and the quoted form is the one
        // that actually works when the paste lands on a shell command line.
        if (w32.GetClipboardData(w32.CF_HDROP)) |hdrop_handle| hdrop: {
            // Pass the handle straight to DragQueryFileW, which locks it
            // internally — exactly as handleDropFiles does with the HDROP
            // from WM_DROPFILES. Do NOT GlobalLock and pass the resulting
            // pointer: clipboard data is moveable, so the handle and the
            // locked address are different values. And never DragFinish it;
            // the clipboard owns this handle, not us.
            const paths = (try hdropPathsToUtf8(alloc, @ptrCast(hdrop_handle), quoting)) orelse
                break :hdrop;
            defer alloc.free(paths);
            break :blk try alloc.dupeZ(u8, paths);
        }

        const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse
            return .unavailable;
        const ptr16 = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed", .{});
            return .unavailable;
        };
        defer _ = w32.GlobalUnlock(hglobal);

        const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));
        var wlen: usize = 0;
        while (wptr[wlen] != 0) wlen += 1;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
            log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
            return .unavailable;
        };
        defer alloc.free(utf8);
        break :blk try alloc.dupeZ(
            u8,
            normalizeWindowsClipboardNewlines(utf8),
        );
    };
    defer alloc.free(utf8z);

    return self.completeClipboardRequestWithConfirmation(
        state,
        &.{.{ .mime = "text/plain", .data = utf8z }},
        &.{},
    );
}

/// A clipboard read waiting for another application to release the
/// clipboard (see `retryClipboardRead`).
const PendingClipboardRead = struct {
    state: apprt.ClipboardRequest,
    attempt: u8,
};

/// A clipboard write waiting likewise: a CF_UNICODETEXT HGLOBAL that the
/// surface owns until it is handed to the clipboard.
const PendingClipboardWrite = struct {
    data: *anyopaque,
    attempt: u8,
};

/// Start retrying a clipboard read from a timer. Returns false when the
/// read cannot wait, because another one already does.
fn retryClipboardRead(self: *Surface, state: apprt.ClipboardRequest) bool {
    if (self.pending_clipboard_read != null) return false;
    const hwnd = self.hwnd orelse return false;
    if (w32.SetTimer(hwnd, CLIPBOARD_READ_TIMER, clipboardRetryDelay(0), null) == 0) return false;
    self.pending_clipboard_read = .{ .state = state, .attempt = 0 };
    return true;
}

fn onClipboardReadTimer(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.KillTimer(hwnd, CLIPBOARD_READ_TIMER);
    const pending = self.pending_clipboard_read orelse return;
    self.pending_clipboard_read = null;
    if (!self.core_surface_ready) {
        destroyClipboardRequest(pending.state);
        return;
    }

    // The core already treats the request as started, so a read that does
    // not complete it denies it.
    const result = self.readClipboard(pending.state) catch |err| {
        if (err == error.ClipboardBusy and pending.attempt + 1 < clipboard_retries) {
            const attempt = pending.attempt + 1;
            if (w32.SetTimer(hwnd, CLIPBOARD_READ_TIMER, clipboardRetryDelay(attempt), null) != 0) {
                self.pending_clipboard_read = .{ .state = pending.state, .attempt = attempt };
                return;
            }
        }
        log.warn("clipboard read failed err={}", .{err});
        self.core_surface.denyClipboardRequest(pending.state);
        return;
    };
    if (result != .started) self.core_surface.denyClipboardRequest(pending.state);
}

/// Release what a clipboard request owns when it can no longer be
/// completed (its surface is going away).
fn destroyClipboardRequest(state: apprt.ClipboardRequest) void {
    switch (state) {
        .kitty_read => |kitty| kitty.destroy(),
        .kitty_write => |kitty| kitty.destroy(),
        else => {},
    }
}

/// Handle WM_TIMER for the surface's own timers; returns false for others.
pub fn handleTimer(self: *Surface, id: usize) bool {
    switch (id) {
        CLIPBOARD_READ_TIMER => self.onClipboardReadTimer(),
        CLIPBOARD_WRITE_TIMER => self.onClipboardWriteTimer(),
        GPU_RESET_TIMER => self.onGpuResetTimer(),
        else => return false,
    }
    return true;
}

/// Complete a structured clipboard request and run the native authorization
/// prompt when the core requires it. The modal dialog can destroy the surface,
/// so all post-dialog access re-resolves the core surface by id.
fn completeClipboardRequestWithConfirmation(
    self: *Surface,
    state: apprt.ClipboardRequest,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) apprt.ClipboardReadResult {
    const core_app = self.app.core_app;
    const surface_id = self.core_surface.id;

    // Complete with confirmed=false so the core runs its safety checks. If it
    // flags the paste as unsafe (paste-protection) or the OSC 52 read as
    // unauthorized (clipboard-read = ask), prompt and only re-complete with
    // confirmed=true on approval. Passing confirmed=true up front — as this
    // used to — silently disabled both guards on Windows.
    self.core_surface.completeClipboardRequest(state, .{
        .contents = contents,
        .available = available,
    }) catch |err| {
        // `self` may be freed while the modal dialog pumps messages, so
        // re-resolve the surface by id before re-completing.
        const owner = self.parent_window.hwnd;
        // The dialogs show the text being pasted, read or written; a Kitty
        // write carries its text in the request.
        const text = switch (state) {
            .kitty_write => |kitty| clipboardText(kitty.contents),
            else => clipboardText(contents),
        };
        const choice: Dialogs.Choice = switch (err) {
            error.UnsafePaste => Dialogs.confirmUnsafePaste(owner, text),
            error.UnauthorizedPaste => switch (state) {
                .kitty_write, .osc_52_write => Dialogs.confirmClipboardAccess(owner, .write, text),
                else => Dialogs.confirmClipboardAccess(owner, .read, text),
            },
            else => {
                log.err("completeClipboardRequest error: {}", .{err});
                return .started;
            },
        };

        const cs = core_app.findSurfaceByID(surface_id) orelse {
            // Kitty requests own arenas that the apprt must release even if
            // their surface disappeared while the modal dialog was open.
            switch (state) {
                .kitty_read => |kitty| kitty.destroy(),
                .kitty_write => |kitty| kitty.destroy(),
                else => {},
            }
            return .started;
        };

        if (choice == .accept) {
            cs.completeClipboardRequest(state, .{
                .contents = contents,
                .available = available,
                .confirmed = true,
            }) catch |e| {
                log.err("completeClipboardRequest (confirmed) error: {}", .{e});
            };
        } else {
            cs.denyClipboardRequest(state);
        }
    };

    return .started;
}

/// The first text representation of clipboard contents (core or apprt
/// content structs), if any.
fn findClipboardText(contents: anytype) ?[]const u8 {
    for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) return content.data;
    }
    return null;
}

/// `findClipboardText`, or "" when there is no text.
fn clipboardText(contents: anytype) []const u8 {
    return findClipboardText(contents) orelse "";
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return;

    // Without a text representation there is nothing to write.
    const text = findClipboardText(contents) orelse return;

    // When the core requests confirmation (e.g. an OSC 52 clipboard write
    // with clipboard-write = ask), prompt before writing. Previously the
    // flag was discarded, so remote apps could write the clipboard silently.
    // The dialog pumps messages and can free `self` (child exit → surface
    // close), so the surface is re-resolved by id afterwards.
    var surface = self;
    if (confirm) {
        const app = self.app;
        const id = self.core_surface.id;
        if (Dialogs.confirmClipboardAccess(self.parent_window.hwnd, .write, text) != .accept) return;
        const cs = app.core_app.findSurfaceByID(id) orelse return;
        surface = cs.rt_surface;
    }

    const data = (try unicodeTextGlobal(surface.app.core_app.alloc, text)) orelse return;
    surface.writeClipboard(data, 0);
}

/// `text` as a moveable CF_UNICODETEXT memory block (UTF-16LE, NUL
/// terminated), or null when it could not be allocated.
fn unicodeTextGlobal(alloc: Allocator, text: []const u8) !?*anyopaque {
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);

    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, (utf16.len + 1) * @sizeOf(u16)) orelse {
        log.warn("GlobalAlloc failed for clipboard write", .{});
        return null;
    };
    const dst_bytes = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return null;
    };
    const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0;
    _ = w32.GlobalUnlock(hglobal);
    return hglobal;
}

/// Put `data` (from `unicodeTextGlobal`, owned by this call) on the
/// clipboard. While another application holds the clipboard open the
/// write is retried from a timer; a newer write replaces a waiting one.
fn writeClipboard(self: *Surface, data: *anyopaque, attempt: u8) void {
    if (self.pending_clipboard_write) |pending| {
        if (pending.data != data) _ = w32.GlobalFree(pending.data);
        self.pending_clipboard_write = null;
        if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, CLIPBOARD_WRITE_TIMER);
    }

    // null owner: the write is not tied to the surface hwnd.
    if (w32.OpenClipboard(null) == 0) {
        if (attempt + 1 < clipboard_retries) {
            if (self.hwnd) |hwnd| {
                if (w32.SetTimer(hwnd, CLIPBOARD_WRITE_TIMER, clipboardRetryDelay(attempt), null) != 0) {
                    self.pending_clipboard_write = .{ .data = data, .attempt = attempt };
                    return;
                }
            }
        }
        log.warn("OpenClipboard failed for clipboard write", .{});
        _ = w32.GlobalFree(data);
        return;
    }
    defer _ = w32.CloseClipboard();

    _ = w32.EmptyClipboard();

    // SetClipboardData takes ownership of the data on success.
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, data) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(data);
    }
}

fn onClipboardWriteTimer(self: *Surface) void {
    if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, CLIPBOARD_WRITE_TIMER);
    const pending = self.pending_clipboard_write orelse return;
    self.pending_clipboard_write = null;
    self.writeClipboard(pending.data, pending.attempt + 1);
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
    _ = self;
    const env = try global.environMap();

    // TERM and COLORTERM are set by termio/Exec.zig with platform-aware
    // logic (checking for terminfo, resources_dir, etc.). Do not set them here.

    return env;
}

/// Set the window title. Called from performAction(.set_title).
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const len = @min(title.len, self.title.len - 1);
    @memcpy(self.title[0..len], title[0..len]);
    self.title[len] = 0;
    self.title_len = len;
    self.parent_window.onTabTitleChanged(self, title);
}

/// Toggle fullscreen mode. Delegates to the parent Window.
pub fn toggleFullscreen(self: *Surface) void {
    self.parent_window.toggleFullscreen();
}

/// Set the mouse cursor shape. Caches the handle so WM_SETCURSOR can
/// restore it (Windows resets the cursor on every mouse move otherwise).
pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const cursor = switch (shape) {
        .text => w32.LoadCursorW(null, w32.IDC_IBEAM),
        .pointer => w32.LoadCursorW(null, w32.IDC_HAND),
        .crosshair => w32.LoadCursorW(null, w32.IDC_CROSS),
        .e_resize, .w_resize, .ew_resize => w32.LoadCursorW(null, w32.IDC_SIZEWE),
        .n_resize, .s_resize, .ns_resize => w32.LoadCursorW(null, w32.IDC_SIZENS),
        .nwse_resize, .nw_resize, .se_resize => w32.LoadCursorW(null, w32.IDC_SIZENWSE),
        .nesw_resize, .ne_resize, .sw_resize => w32.LoadCursorW(null, w32.IDC_SIZENESW),
        .not_allowed => w32.LoadCursorW(null, w32.IDC_NO),
        .progress => w32.LoadCursorW(null, w32.IDC_APPSTARTING),
        .wait => w32.LoadCursorW(null, w32.IDC_WAIT),
        else => w32.LoadCursorW(null, w32.IDC_ARROW),
    };
    self.current_cursor = cursor;
    if (cursor) |c| _ = w32.SetCursor(c);
}

/// Handle WM_SETCURSOR — restore our cached cursor so Windows doesn't
/// reset it to the class cursor (IDC_ARROW) on every mouse move.
/// Returns true if we handled it (caller should return TRUE).
pub fn handleSetCursor(self: *Surface) bool {
    // Hidden cursor: pass NULL.
    if (!self.mouse_visible) {
        _ = w32.SetCursor(null);
        return true;
    }
    if (self.current_cursor) |c| {
        _ = w32.SetCursor(c);
        return true;
    }
    return false;
}

/// Show (or clear, when url is empty) the hovered-URL preview at the
/// bottom-left of the surface, like a browser status bubble. Driven by the
/// mouse_over_link action.
pub fn setMouseOverLink(self: *Surface, url: []const u8) void {
    self.link_preview.show(url);
}

/// The window moved: keep the screen-positioned popups on the surface.
pub fn repositionPopups(self: *Surface) void {
    if (self.scrollbar) |sb| _ = sb.repositionAndResize();
    self.search_bar.reposition();
    self.link_preview.hide();
}

/// The UI language changed: refresh the translated text of the popups.
pub fn onLanguageChanged(self: *Surface) void {
    self.palette.onLanguageChanged();
    self.search_bar.onLanguageChanged();
}

/// Toggle window decorations (title bar + borders) on/off.
/// Delegates to the parent Window.
pub fn toggleWindowDecorations(self: *Surface) void {
    self.parent_window.toggleWindowDecorations();
}

/// Follow a config change reported for this surface. Its conditional
/// configuration (e.g. a light/dark theme) can differ from the app's.
pub fn onConfigChange(self: *Surface, config: *const configpkg.Config) void {
    if (self.scrollbar) |sb| sb.setTheme(
        config.background.toTerminalRGB(),
        config.foreground.toTerminalRGB(),
    );
}

/// Update the themed scrollbar to reflect the terminal's scroll state.
/// Called from performAction(.scrollbar) when the viewport changes.
pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    if (self.scrollbar) |sb| sb.update(scrollbar);
}

/// Scroll the terminal to the given absolute row offset.
/// Called by the themed scrollbar during drag / click.
pub fn scrollToOffset(self: *Surface, offset: usize) void {
    if (!self.core_surface_ready) return;
    _ = self.core_surface.performBindingAction(.{ .scroll_to_row = offset }) catch |err| {
        log.err("scrollToOffset error: {}", .{err});
    };
}

// -----------------------------------------------------------------------
// Message handlers called from App.surfaceWndProc
// -----------------------------------------------------------------------

/// Handle WM_SIZE.
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    // Skip zero-size events (minimized windows).
    if (width == 0 or height == 0) return;

    self.height = height;

    // Pre-flight the scrollbar so we know whether to subtract its width.
    // This must happen before sizeCallback so the grid gets the right width.
    var grid_width = width;
    if (self.scrollbar) |sb| {
        const sub = sb.repositionAndResize();
        if (sub > 0 and grid_width > @as(u32, @intCast(sub))) {
            grid_width -= @as(u32, @intCast(sub));
        }
    }
    self.width = grid_width;

    // Reposition popups with corrected width.
    if (self.search_bar.active) self.search_bar.reposition();
    if (self.palette.active) self.palette.reposition();

    if (!self.core_surface_ready) return;

    // Notify the core surface so it recalculates the terminal grid,
    // updates the renderer viewport, and sends SIGWINCH to the PTY.
    self.core_surface.sizeCallback(.{ .width = grid_width, .height = height }) catch |err| {
        log.err("sizeCallback error: {}", .{err});
        return;
    };
    if (self.ime_composing) self.positionImeWindow();

    // During live resize (user dragging the border), block until the
    // renderer has presented one frame at the new size. This prevents
    // the DWM from stretching stale framebuffer content to fill the
    // new window area, which causes visible flicker.
    if (self.in_live_resize) {
        if (self.frame_event) |event| {
            // Reset the event before waking the renderer, so we
            // wait for a NEW frame, not a previously drawn one.
            _ = w32.ResetEvent(event);
        }

        // Wake the renderer to redraw at the new size.
        self.core_surface.renderer_thread.wakeup.notify() catch {};

        // When the window lays out its panes it waits for all of them at
        // once afterwards (`Window.layoutSplits`), so split panes render
        // in parallel.
        self.resize_frame_pending = true;
        if (!self.parent_window.laying_out) self.awaitResizeFrame();
    } else {
        // Outside live resize (programmatic resize, initial layout),
        // just wake the renderer asynchronously.
        self.core_surface.renderer_thread.wakeup.notify() catch {};
    }
}

/// How long a live resize waits for the renderer to present a frame at
/// the new size. Short, so a slow renderer never stalls the UI.
pub const resize_frame_timeout_ms: u32 = 16;

/// Wait for the frame `handleResize` asked for during a live resize.
fn awaitResizeFrame(self: *Surface) void {
    self.resize_frame_pending = false;
    if (self.frame_event) |event| _ = w32.WaitForSingleObject(event, resize_frame_timeout_ms);
}

/// Called by the parent Window when it moved to a monitor with another
/// DPI. Child windows never receive WM_DPICHANGED themselves.
pub fn handleDpiChange(self: *Surface, dpi: u32) void {
    self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;

    if (self.core_surface_ready) {
        self.core_surface.contentScaleCallback(.{
            .x = self.scale,
            .y = self.scale,
        }) catch |err| log.err("contentScaleCallback error: {}", .{err});
    }

    // Popup fonts were created at the previous DPI. Rebuild them at
    // the new scale so search-bar / palette text doesn't render
    // tiny/huge after dragging the window between monitors.
    self.search_bar.onDpiChanged();
    self.palette.onDpiChanged();
    self.link_preview.hide();

    // Notify the scrollbar of the new DPI.
    if (self.scrollbar) |sb| sb.onDpiChanged(dpi);

    // The IME windows follow the cursor, which moved in pixels.
    self.positionImeWindow();
}

/// Handle WM_KEYDOWN / WM_SYSKEYDOWN / WM_KEYUP / WM_SYSKEYUP.
///
/// Every message also reaches the core as a `gx_win32_input.KeyMessage`
/// (`gxWin32KeyCallback`), so while the terminal has win32-input-mode on
/// (ConPTY requests it) the key goes to the pty as a KEY_EVENT_RECORD:
/// presses, repeats and releases, modifier keys included. See
/// src/gx/win32_input.zig for the contract.
pub fn handleKeyEvent(self: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    if (!self.core_surface_ready) return;
    const vk: u16 = @intCast(wparam & 0xFFFF);
    // Bits 16-23 of lparam. Bit 24 is the extended-key flag, not part of
    // the scancode; including it broke ToUnicode for AltGr layouts
    // (German, Polish) and arrow/numpad keys.
    const scancode: u8 = @truncate(@as(usize, @bitCast(lparam)) >> 16);

    // When the IME is active, physical key presses arrive as VK_PROCESSKEY.
    // The IME will produce the composed text via WM_IME_COMPOSITION — skip
    // the key event so we don't feed garbage to the terminal. The release
    // of such a key can still arrive with its real virtual-key code;
    // remember the key so that release is not reported on its own.
    if (vk == w32.VK_PROCESSKEY) {
        self.ime_keys.setValue(scancode, action == .press);
        return;
    }
    if (action == .press) self.ime_keys.unset(scancode);

    // VK_PACKET is sent by SendInput with KEYEVENTF_UNICODE (used by
    // accessibility tools, on-screen keyboards, and Unicode injection).
    // The actual character follows as WM_CHAR — don't set the
    // key_event_produced_text flag so WM_CHAR is allowed through.
    if (vk == w32.VK_PACKET) return;

    // Determine left/right for modifier keys using the extended key flag
    // (bit 24 of lparam) and specific left/right VK codes.
    const extended = (lparam & (1 << 24)) != 0;

    const key = mapVirtualKey(vk, extended);

    // Build modifier state
    const mods = getModifiers();

    // Check if the key is a repeat (bit 30 of lparam is set for KEYDOWN
    // if the key was already down).
    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;

    // Try to get the unshifted codepoint for this key
    const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;

    // Use ToUnicode to translate the key press into UTF-16 text,
    // then convert to UTF-8 for the key event. Only for press/repeat.
    var utf8_buf: [16]u8 = undefined;
    var utf8_text: []const u8 = "";
    var consumed_mods: input.Mods = .{};
    // The modifier set actually encoded into the key event. AltGr handling
    // below may clear ctrl+alt on this copy without disturbing `mods`.
    var event_mods = mods;

    // Reset the flag — WM_CHAR should be allowed through unless
    // ToUnicode produces text below.
    self.key_event_produced_text = false;

    // The modifier and lock state for this message, read for every key
    // (modifiers and releases included) as the console host would.
    var keyboard_state: [256]u8 = undefined;
    const have_keyboard_state = w32.GetKeyboardState(&keyboard_state) != 0;
    if (!have_keyboard_state) @memset(&keyboard_state, 0);
    var message: gx_win32_input.KeyMessage = .{
        .vk = vk,
        .lparam = lparam,
        .down = action == .press,
        .state = .fromKeyboardState(&keyboard_state),
    };

    if (have_keyboard_state and !isModifierVk(vk)) {
        // ToUnicode's raw UTF-16 output, control characters included, is
        // the record's character. The buffer lives in the surface so the
        // message never points into a finished call.
        const utf16_buf = &self.key_utf16;
        if (actual_action == .press or actual_action == .repeat) {
            // App.run skips TranslateMessage for surface keyboard messages,
            // so this ToUnicode call owns the per-queue dead-key state.
            // result>0 means composed text (including composition with a
            // previously pending dead key); result<0 means VK is itself a
            // dead key and ToUnicode just stored it for the next call.
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result < 0) message.dead = true;
            if (result > 0) {
                const utf16_slice = utf16_buf[0..@intCast(result)];
                message.text = utf16_slice;
                // Skip Ctrl-induced control chars (0x01-0x1A): the core
                // handles modifier combos via key + mods, and emitting
                // the control char here would double-encode.
                if (utf16_slice[0] >= 0x20) {
                    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16_slice) catch 0;
                    if (len > 0) {
                        utf8_text = utf8_buf[0..len];
                        if (mods.shift) consumed_mods.shift = true;
                        self.key_event_produced_text = true;
                        // AltGr layouts: Windows reports AltGr as
                        // Left-Ctrl+Right-Alt. When that combination itself
                        // produced printable text (e.g. German AltGr+Q '@',
                        // AltGr+8 '['), strip ctrl+alt from the ENCODED mods.
                        // The core key encoder reads raw event.mods and would
                        // otherwise turn the literal into a C0/CSIu control
                        // sequence. Gate on the right-Alt physically being down
                        // so genuine Ctrl+Alt chords are left untouched.
                        if (mods.ctrl and mods.alt and
                            (keyboard_state[w32.VK_RMENU] & 0x80) != 0)
                        {
                            event_mods.ctrl = false;
                            event_mods.alt = false;
                            consumed_mods.ctrl = true;
                            consumed_mods.alt = true;
                        }
                    }
                }
            }
        } else {
            // A release record carries the key's character too. Translate
            // without changing the keyboard state, so a pending dead key
            // survives for the next press.
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                utf16_buf,
                utf16_buf.len,
                tounicode_keep_state,
            );
            if (result < 0) message.dead = true;
            if (result > 0) message.text = utf16_buf[0..@intCast(result)];
        }
    }

    const event = input.KeyEvent{
        .action = actual_action,
        .key = key,
        .mods = event_mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_text,
        .unshifted_codepoint = unshifted_codepoint,
    };

    // The press of this key went to the IME, so its release is not
    // reported on its own either.
    if (action == .release and self.ime_keys.isSet(scancode)) {
        self.ime_keys.unset(scancode);
        _ = self.core_surface.keyCallback(event) catch |err| {
            log.err("key callback error: {}", .{err});
        };
        return;
    }

    const effect = self.core_surface.gxWin32KeyCallback(event, message) catch |err| {
        log.err("key callback error: {}", .{err});
        return;
    };
    if (effect != .closed) self.noteWin32InputMode();
}

/// ToUnicode wFlags bit 2: translate without changing the keyboard state
/// (Windows 10 version 1607 and later).
const tounicode_keep_state: u32 = 0x4;

/// Log once per terminal when its key input starts going out as
/// win32-input-mode records, i.e. ConPTY (or a program) turned the mode on.
fn noteWin32InputMode(self: *Surface) void {
    if (self.win32_input_logged) return;
    const core_surface = &self.core_surface;
    const active = active: {
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        break :active gx_win32_input.active(&core_surface.io.terminal);
    };
    if (!active) return;
    self.win32_input_logged = true;
    log.info("win32-input-mode (9001) active: keys go to the pty as KEY_EVENT_RECORDs", .{});
}

/// Handle WM_CHAR — character input after translation.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages
/// containing a UTF-16 surrogate pair (high then low).
///
/// Text is routed through keyCallback (not textCallback!) with
/// key=.unidentified, mirroring how GTK handles IME commits.
/// textCallback is for clipboard paste; keyCallback is for keyboard/IME text.
pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const char_code: u16 = @intCast(wparam & 0xFFFF);

    // Skip control characters that are handled via WM_KEYDOWN
    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;

    // Handle UTF-16 surrogate pairs for codepoints > U+FFFF (e.g. emoji).
    const codepoint: u21 = if (char_code >= 0xD800 and char_code <= 0xDBFF) {
        // High surrogate — buffer it and wait for the low surrogate.
        self.high_surrogate = char_code;
        return;
    } else if (char_code >= 0xDC00 and char_code <= 0xDFFF) blk: {
        // Low surrogate — combine with buffered high surrogate.
        if (self.high_surrogate != 0) {
            const hi: u21 = self.high_surrogate;
            self.high_surrogate = 0;
            break :blk @intCast((@as(u21, hi - 0xD800) << 10) + (@as(u21, char_code) - 0xDC00) + 0x10000);
        }
        // Low surrogate without preceding high — invalid, skip.
        return;
    } else blk: {
        self.high_surrogate = 0; // Reset any stale high surrogate.
        break :blk @intCast(char_code);
    };

    // Convert codepoint to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit).
    // keyCallback will encode the utf8 text and write it to the PTY, as
    // VK = 0 records while win32-input-mode is on.
    _ = self.core_surface.gxWin32KeyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }, null) catch |err| {
        log.err("text input callback error: {}", .{err});
    };
}

/// Handle WM_LBUTTONDOWN / WM_RBUTTONDOWN / WM_MBUTTONDOWN /
/// WM_LBUTTONUP / WM_RBUTTONUP / WM_MBUTTONUP.
pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    const mods = getModifiers();

    // Capture mouse on the first pressed button; release only when all
    // buttons are up. Otherwise a right-click in the middle of a left-
    // button drag clobbers capture, and the next up-event releases it
    // for everyone.
    const bit: u3 = switch (button) {
        .left => 1,
        .right => 2,
        .middle => 4,
        else => 0,
    };
    if (bit != 0) {
        const prev = self.mouse_button_mask;
        if (action == .press) {
            self.mouse_button_mask |= bit;
            if (prev == 0) {
                if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
            }
        } else {
            self.mouse_button_mask &= ~bit;
            if (prev != 0 and self.mouse_button_mask == 0) {
                _ = w32.ReleaseCapture();
            }
        }
    }

    // Update cursor position first
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };

    const consumed = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| blk: {
        log.err("mouse button callback error: {}", .{err});
        break :blk true;
    };

    // Unconsumed right-press under the default right-click-action =
    // context-menu: the core has already selected the hovered word/link
    // and returned false, signalling the apprt to show its context menu
    // (same contract the GTK apprt follows).
    if (!consumed and button == .right and action == .press) {
        self.showContextMenu(lparam);
    }
}

/// Show the surface right-click context menu at the given client coords
/// (packed in lparam like a mouse message). Items dispatch through the
/// core's binding actions, mirroring the macOS surface menu.
fn showContextMenu(self: *Surface, lparam: isize) void {
    const hwnd = self.hwnd orelse return;

    // The press handler took mouse capture; release it and clear the mask
    // before the modal menu loop, otherwise the pending button-up is
    // captured and immediately dismisses the menu.
    if (self.mouse_button_mask != 0) {
        self.mouse_button_mask = 0;
        _ = w32.ReleaseCapture();
    }

    // The menu's modal loop takes capture and swallows the physical
    // WM_RBUTTONUP, so the core would never see the right-button release and
    // would leave click_state[right] stuck at .press (corrupting later mouse
    // motion). Synthesize the release now.
    _ = self.core_surface.mouseButtonCallback(.release, .right, getModifiers()) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };

    var pt = w32.POINT{
        .x = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF)))),
        .y = @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF)))),
    };
    _ = w32.ClientToScreen(hwnd, &pt);

    // Null also when this terminal closed while the menu was open.
    const binding = Menu.showSurfaceContextMenu(self, pt) orelse return;
    _ = self.core_surface.performBindingAction(binding) catch |err| {
        log.err("context menu action failed err={}", .{err});
    };
}

/// Handle WM_MOUSEMOVE.
pub fn handleMouseMove(self: *Surface, lparam: isize) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    // Pass modifiers so the core can detect Ctrl+hover for link highlighting.
    const mods = getModifiers();

    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}

/// Handle WM_DROPFILES — a file (or files) was dropped onto this
/// surface. Convert each path to UTF-8, quote it for the shell running in
/// the terminal, and type the paths at the cursor.
pub fn handleDropFiles(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const hdrop: w32.HDROP = @ptrFromInt(wparam);
    defer w32.DragFinish(hdrop);

    const alloc = self.app.core_app.alloc;
    const text = (hdropPathsToUtf8(alloc, hdrop, self.pathQuoting()) catch |err| {
        log.err("drop-files path conversion: {}", .{err});
        return;
    }) orelse return;
    defer alloc.free(text);

    // Send through keyCallback as text (PTY-bound, encoding-correct).
    // Like a paste, and as in Windows Terminal, the paths stay raw text
    // even while win32-input-mode is on, so this is not gxWin32KeyCallback.
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = text,
        .unshifted_codepoint = 0,
    }) catch |err| {
        log.err("drop-files keyCallback: {}", .{err});
    };
}

/// How dropped and pasted file paths are quoted: for the innermost shell
/// running in the terminal (`gx.path_quote.styleFor`), in double quotes
/// when it is unknown.
fn pathQuoting(self: *Surface) path_quote.Style {
    if (!self.core_surface_ready) return .windows;
    const root = self.core_surface.getProcessInfo(.foreground_pid) orelse return .windows;
    const pid = std.math.cast(gx_proc.Pid, root) orelse return .windows;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    var snapshot = gx_proc.snapshot(arena.allocator(), global.io(), pid) catch return .windows;
    defer snapshot.deinit();
    const names = snapshot.tree.names(arena.allocator(), pid) catch return .windows;
    return path_quote.styleFor(names);
}

/// Convert the path list in an HDROP into one shell-ready UTF-8 string:
/// each path quoted in `quoting` (`gx.path_quote`), joined with single
/// spaces.
///
/// Used by both WM_DROPFILES and CF_HDROP clipboard pastes. The caller owns
/// the returned slice; this function never releases the HDROP. A
/// WM_DROPFILES handle must be DragFinish'd by the caller. A clipboard
/// handle from GetClipboardData(CF_HDROP) must NOT be freed, DragFinish'd,
/// or unlocked — the clipboard owns it, and DragQueryFileW takes and drops
/// its own lock internally, so the caller neither locks nor unlocks it.
/// Returns null when there is nothing usable.
fn hdropPathsToUtf8(alloc: Allocator, hdrop: w32.HDROP, quoting: path_quote.Style) Allocator.Error!?[]u8 {
    // Number of files (passing 0xFFFFFFFF as iFile).
    const count = w32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    if (count == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // First call with NULL gets length (in chars, excluding NUL).
        const u16_len = w32.DragQueryFileW(hdrop, i, null, 0);
        if (u16_len == 0) continue;
        const u16_buf = try alloc.alloc(u16, u16_len + 1);
        defer alloc.free(u16_buf);
        const got = w32.DragQueryFileW(hdrop, i, u16_buf.ptr, @intCast(u16_buf.len));
        if (got == 0) continue;

        // UTF-16 → UTF-8.
        const utf8_buf = try alloc.alloc(u8, u16_buf.len * 4);
        defer alloc.free(utf8_buf);
        const utf8_len = std.unicode.utf16LeToUtf8(utf8_buf, u16_buf[0..got]) catch continue;
        const path = utf8_buf[0..utf8_len];

        // Quote unconditionally, not just for whitespace. Windows filenames
        // may legally contain & | ( ) ; ^ < > and glob characters; the
        // quoting matches the shell, so $ and backticks stay literal in
        // PowerShell and POSIX shells (single quotes). Residual: %VAR%
        // still expands inside cmd.exe's double quotes. The core
        // unsafe-paste check does not cover these (input/paste.zig isSafe
        // only looks for \n and \x1b[201~), but typing paths never submits
        // a line on its own.
        //
        // Separate from whatever we already appended rather than keying off
        // `i`, so a skipped entry can't leave a leading or doubled space.
        const mark = buf.items.len;
        if (buf.items.len > 0) try buf.append(alloc, ' ');
        if (!try path_quote.appendQuoted(alloc, &buf, path, quoting)) {
            // A path the quoting cannot contain (a double quote for cmd.exe,
            // control characters), possible on volumes written by WSL,
            // Samba/NFS or via \\?\ paths: it would let the rest of the
            // name be read as shell syntax, so it is not emitted at all.
            // Logged without the name, which can hold control characters.
            buf.shrinkRetainingCapacity(mark);
            log.warn("refusing to paste a path the shell cannot quote", .{});
        }
    }

    if (buf.items.len == 0) {
        buf.deinit(alloc);
        return null;
    }
    return try buf.toOwnedSlice(alloc);
}

/// Handle WM_MOUSEWHEEL (vertical) and WM_MOUSEHWHEEL (horizontal).
/// `axis` selects which scroll axis to deliver the delta on.
pub fn handleMouseWheel(self: *Surface, wparam: usize, axis: enum { vertical, horizontal }) void {
    if (!self.core_surface_ready) return;
    // The high word of wparam contains the wheel delta (signed).
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));

    const scroll_mods: input.ScrollMods = .{};

    // Win32 horizontal wheel positive-right; core API positive-right also.
    const xoff: f64 = if (axis == .horizontal) delta else 0;
    const yoff: f64 = if (axis == .vertical) delta else 0;
    self.core_surface.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}

/// Handle WM_IME_STARTCOMPOSITION — an IME composition session has begun.
/// Position the candidate window near the terminal cursor and let Windows
/// show its default composition UI.
pub fn handleImeStartComposition(self: *Surface) void {
    self.ime_composing = true;
    // Drop any buffered high surrogate so it can't pair with IME output.
    self.high_surrogate = 0;
    self.positionImeWindow();
}

/// Handle WM_IME_ENDCOMPOSITION — the IME composition session has ended.
pub fn handleImeEndComposition(self: *Surface) void {
    self.ime_composing = false;
    // Clear any leftover inline preedit (e.g. composition cancelled with Esc).
    if (self.core_surface_ready) {
        self.core_surface.preeditCallback(null) catch {};
    }
}

/// Handle WM_IME_COMPOSITION — intermediate or final text from the IME.
/// When the result string is available (GCS_RESULTSTR), extract it and
/// send it to the terminal. Returns true if we handled the result string.
pub fn handleImeComposition(self: *Surface, lparam: isize) bool {
    if (!self.core_surface_ready) return false;

    const flags: u32 = @intCast(lparam & 0xFFFFFFFF);

    // Intermediate composition text: mirror it inline at the cursor via the
    // core's preedit (underlined, like macOS/GTK) instead of the default
    // floating composition window (suppressed via WM_IME_SETCONTEXT).
    if (flags & w32.GCS_RESULTSTR == 0) {
        if (flags & w32.GCS_COMPSTR != 0) {
            self.updateImePreedit();
            return true;
        }
        return false;
    }

    // Result string: clear the inline preedit, then commit the text below.
    self.core_surface.preeditCallback(null) catch {};

    const hwnd = self.hwnd orelse return false;
    const himc = w32.ImmGetContext(hwnd) orelse return false;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Query the length of the result string (in bytes).
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, null, 0);
    if (byte_len <= 0) return false;
    // The W variant always returns an even byte count, but reject odd
    // values defensively rather than panicking via @divExact.
    if (byte_len & 1 != 0) return false;

    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));

    // Stack buffer for typical IME results (up to 64 UTF-16 code units).
    var stack_buf: [64]u16 = undefined;

    if (u16_len <= stack_buf.len) {
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &stack_buf, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        self.sendImeText(stack_buf[0..actual_len]);
    } else {
        // Unusual: very long composition. Allocate on the heap.
        const alloc = self.app.core_app.alloc;
        const buf = alloc.alloc(u16, u16_len) catch return false;
        defer alloc.free(buf);
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, buf.ptr, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        self.sendImeText(buf[0..actual_len]);
    }

    // GCS_RESULTSTR and GCS_COMPSTR can arrive together (e.g. an IME commits
    // a syllable while starting the next). We cleared the preedit above for
    // the result; re-mirror the new composition so it isn't invisible until
    // the next keystroke.
    if (flags & w32.GCS_COMPSTR != 0) self.updateImePreedit();

    // Reposition the IME window for the next composition
    self.positionImeWindow();
    return true;
}

/// Convert a UTF-16 IME result to UTF-8 and send it to the terminal.
/// Read the current GCS_COMPSTR composition string and mirror it into the
/// core's preedit so it renders inline at the cursor. An empty composition
/// clears the preedit.
fn updateImePreedit(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    var buf16: [128]u16 = undefined;
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, null, 0);
    if (byte_len <= 0 or byte_len & 1 != 0) {
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));
    if (u16_len > buf16.len) {
        // Absurdly long composition; clear rather than truncate mid-pair.
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const got = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, &buf16, @intCast(byte_len));
    if (got <= 0 or got & 1 != 0) return;
    const n: usize = @intCast(@divTrunc(got, 2));

    // Worst case 3 bytes of UTF-8 per UTF-16 code unit.
    var buf8: [buf16.len * 3]u8 = undefined;
    const len8 = std.unicode.utf16LeToUtf8(&buf8, buf16[0..n]) catch return;
    self.core_surface.preeditCallback(if (len8 == 0) null else buf8[0..len8]) catch |err| {
        log.warn("preeditCallback failed err={}", .{err});
    };

    // Output can move the cursor while composing; keep the candidate
    // list with it.
    self.positionImeWindow();
}

fn sendImeText(self: *Surface, utf16: []const u16) void {
    // Convert UTF-16LE to UTF-8 in a stack buffer (256 bytes covers
    // even long CJK phrases — each CJK char is 3 bytes in UTF-8).
    var utf8_buf: [256]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16) catch |err| {
        log.warn("IME utf16→utf8 error: {}", .{err});
        return;
    };
    if (len == 0) return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit); VK = 0
    // records while win32-input-mode is on.
    _ = self.core_surface.gxWin32KeyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }, null) catch |err| {
        log.err("IME text callback error: {}", .{err});
    };
}

/// Anchor the IME windows at the terminal cursor, in client pixels: the
/// composition window (hidden, the composition is drawn inline, but its
/// position tells the IME where the text is) at the cursor cell, and the
/// candidate list below that cell without covering it (above it when the
/// screen has no room below). Called when a composition starts or
/// changes, after a resize during a composition and after a DPI change.
fn positionImeWindow(self: *Surface) void {
    if (!self.core_surface_ready) return;
    const hwnd = self.hwnd orelse return;
    const cell = imeCellRect(
        self.core_surface.imePoint(),
        self.scale,
        self.core_surface.size.cell.width,
        self.core_surface.size.cell.height,
        self.width,
        self.height,
    );

    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    _ = w32.ImmSetCompositionWindow(himc, &.{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = .{ .x = cell.left, .y = cell.top },
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    });
    _ = w32.ImmSetCandidateWindow(himc, &.{
        .dwIndex = 0,
        .dwStyle = w32.CFS_EXCLUDE,
        .ptCurrentPos = .{ .x = cell.left, .y = cell.bottom },
        .rcArea = cell,
    });
}

/// The cursor cell in client pixels from the core's `imePoint`, which is
/// in unscaled points (divided by the content scale): the middle of the
/// cell horizontally and its bottom edge vertically. Clamped to the
/// surface, since the cursor can be outside the viewport (scrolled back).
fn imeCellRect(
    point: apprt.IMEPos,
    scale: f32,
    cell_width: u32,
    cell_height: u32,
    surface_width: u32,
    surface_height: u32,
) w32.RECT {
    const cw: i32 = @intCast(@max(cell_width, 1));
    const ch: i32 = @intCast(@max(cell_height, 1));
    const max_x: i32 = @max(@as(i32, @intCast(surface_width)) - cw, 0);
    const max_bottom: i32 = @max(@as(i32, @intCast(surface_height)), ch);
    const center_x: i32 = @intFromFloat(@round(point.x * scale));
    const bottom_y: i32 = @intFromFloat(@round(point.y * scale));
    const left = std.math.clamp(center_x - @divTrunc(cw, 2), 0, max_x);
    const bottom = std.math.clamp(bottom_y, ch, max_bottom);
    return .{ .left = left, .top = bottom - ch, .right = left + cw, .bottom = bottom };
}

test "imeCellRect scales points to pixels" {
    // A 10x20 px cell at 1.5x: imePoint reports the cell's center x and
    // bottom y divided by the scale.
    const rect = imeCellRect(.{ .x = 25, .y = 40, .width = 0, .height = 0 }, 1.5, 10, 20, 800, 600);
    try std.testing.expectEqual(w32.RECT{ .left = 33, .top = 40, .right = 43, .bottom = 60 }, rect);
}

test "imeCellRect clamps to the surface" {
    const rect = imeCellRect(.{ .x = 2000, .y = 2000, .width = 0, .height = 0 }, 1, 10, 20, 800, 600);
    try std.testing.expectEqual(w32.RECT{ .left = 790, .top = 580, .right = 800, .bottom = 600 }, rect);
}

/// Called by the renderer thread after SwapBuffers to signal that a
/// frame has been presented. Wakes the main thread if it's blocking
/// in handleResize during live resize.
pub fn signalFrameDrawn(self: *Surface) void {
    if (self.frame_event) |event| {
        _ = w32.SetEvent(event);
    }
}

/// Posted to the surface window by `gpuContextReset`.
pub const WM_APP_GPU_RESET: u32 = w32.WM_APP + 30;

/// Test-only message: SendMessage(surface, WM_GHOSTTY_SIMULATE_GPU_RESET,
/// 0, 0) makes the renderer treat its next frame as if the GPU had been
/// reset, exercising the context recovery (`gpuContextReset`).
pub const WM_GHOSTTY_SIMULATE_GPU_RESET: u32 = w32.WM_USER + 0x48;

/// Timer of `recoverGpuResources`.
const GPU_RESET_TIMER: usize = 0x4752; // 'GR'

/// Called by the renderer thread (src/renderer/opengl/wgl.zig) inside a
/// frame, with the renderer's draw mutex held, after it replaced an
/// OpenGL context lost to a GPU reset: every GPU object the renderer made
/// belongs to the dead context. Like `Renderer.threadExit`, mark the
/// display unrealized (nothing is drawn with those objects, and the next
/// render releases the swap chain and shaders while the new context is
/// still empty, so no name of a new object is deleted by mistake) and
/// drop the uploaded images; then let the GUI thread realize it again
/// (`recoverGpuResources`).
pub fn gpuContextReset(self: *Surface) void {
    const renderer = &self.core_surface.renderer;
    renderer.display_realized = false;
    renderer.images.deinit(renderer.alloc);
    renderer.images = .empty;
    if (renderer.bg_image) |image| {
        image.deinit(renderer.alloc);
        renderer.bg_image = null;
    }
    if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, WM_APP_GPU_RESET, 0, 0);
}

/// Rebuild the renderer's GPU resources after a GPU reset: wake the
/// renderer so it releases the dead objects (it is unrealized), then,
/// from a timer once they are gone, realize the display again so the next
/// frame recreates everything.
pub fn recoverGpuResources(self: *Surface) void {
    if (!self.core_surface_ready) return;
    log.warn("the GPU context was reset, rebuilding the renderer resources", .{});
    self.core_surface.renderer_thread.wakeup.notify() catch {};
    if (self.hwnd) |hwnd| _ = w32.SetTimer(hwnd, GPU_RESET_TIMER, 16, null);
}

fn onGpuResetTimer(self: *Surface) void {
    if (!self.core_surface_ready) {
        if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, GPU_RESET_TIMER);
        return;
    }
    // Unrealized, the renderer releases its swap chain and shaders
    // together, under the draw mutex.
    const renderer = &self.core_surface.renderer;
    const released = released: {
        renderer.draw_mutex.lockUncancelable(global.io());
        defer renderer.draw_mutex.unlock(global.io());
        break :released renderer.swap_chain == null;
    };
    if (!released) {
        self.core_surface.renderer_thread.wakeup.notify() catch {};
        return;
    }
    if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, GPU_RESET_TIMER);
    self.core_surface.displayRealized() catch |err| {
        log.warn("displayRealized failed err={}", .{err});
    };
    self.core_surface.renderer_thread.wakeup.notify() catch {};
    log.info("renderer resources rebuilt after the GPU reset", .{});
}

/// Called by the renderer thread (wgl.zig) on every frame: whether to
/// treat this frame as if the GPU had been reset (test-only).
pub fn takeSimulatedGpuReset(self: *Surface) bool {
    return self.simulate_gpu_reset.swap(false, .acq_rel);
}

/// Make the renderer draw a complete new frame even though the terminal
/// did not change: it releases its frame buffers (swap chain) and builds
/// them again, as when the surface is hidden and shown. Used after
/// sleep/resume, display changes and GPU resets, which can lose the
/// window contents; an unchanged terminal is otherwise never redrawn. A
/// hidden surface needs nothing: it is rebuilt when shown.
pub fn refreshRenderer(self: *Surface) void {
    if (!self.core_surface_ready) return;
    if (self.last_reported_visible != true) return;
    self.core_surface.occlusionCallback(false) catch |err| {
        log.warn("occlusionCallback failed err={}", .{err});
        return;
    };
    self.core_surface.occlusionCallback(true) catch |err| {
        // The renderer believes it is hidden; the next layout retries.
        self.last_reported_visible = null;
        log.warn("occlusionCallback failed err={}", .{err});
    };
}

/// Handle WM_SETFOCUS / WM_KILLFOCUS.
pub fn handleFocus(self: *Surface, focused: bool) void {
    if (!self.core_surface_ready) return;
    // Drop any buffered high surrogate and pending dead key on focus loss —
    // otherwise they would combine with the next character when focus returns.
    if (!focused) {
        self.high_surrogate = 0;
        // Composition messages follow keyboard focus, so a split losing
        // focus mid-composition never gets its own WM_IME_ENDCOMPOSITION.
        // Cancel the composition and clear its inline preedit now.
        if (self.ime_composing) {
            self.ime_composing = false;
            if (self.hwnd) |hwnd| {
                if (w32.ImmGetContext(hwnd)) |himc| {
                    defer _ = w32.ImmReleaseContext(hwnd, himc);
                    _ = w32.ImmNotifyIME(himc, w32.NI_COMPOSITIONSTR, w32.CPS_CANCEL, 0);
                }
            }
            self.core_surface.preeditCallback(null) catch {};
        }
        // Drain any pending dead-key state so an unfinished compose
        // doesn't bleed into the next focused surface or another app.
        var ks: [256]u8 = undefined;
        if (w32.GetKeyboardState(&ks) != 0) {
            var buf: [4]u16 = undefined;
            // 0x39 is the standard scancode for VK_SPACE on all layouts.
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
        }
    }
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("focus callback error: {}", .{err});
    };
}

/// Get the current keyboard modifier state from Win32.
fn getModifiers() input.Mods {
    var mods: input.Mods = .{};

    // GetKeyState returns a value where the high bit indicates the key
    // is currently down.
    if (w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0) {
        mods.shift = true;
        // Determine which shift key is pressed
        if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0) {
            mods.sides.shift = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
        mods.ctrl = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0) {
            mods.sides.ctrl = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) {
        mods.alt = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0) {
            mods.sides.alt = .right;
        }
    }

    // Check super (Windows key)
    if (w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0)
    {
        mods.super = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) {
            mods.sides.super = .right;
        }
    }

    // Lock keys (low bit indicates toggle state)
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0) {
        mods.caps_lock = true;
    }
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0) {
        mods.num_lock = true;
    }

    return mods;
}

/// True for VKs that on their own never produce a character (Shift, Ctrl,
/// Alt, Win, lock keys). Calling ToUnicode for these is wasted at best and
/// can perturb the kernel's per-thread keyboard state at worst (in
/// particular, ToUnicode buffers any pending dead key into kernel state
/// even when the result is unused).
fn isModifierVk(vk: u16) bool {
    return switch (vk) {
        w32.VK_SHIFT,
        w32.VK_LSHIFT,
        w32.VK_RSHIFT,
        w32.VK_CONTROL,
        w32.VK_LCONTROL,
        w32.VK_RCONTROL,
        w32.VK_MENU,
        w32.VK_LMENU,
        w32.VK_RMENU,
        w32.VK_LWIN,
        w32.VK_RWIN,
        w32.VK_CAPITAL,
        w32.VK_NUMLOCK,
        w32.VK_SCROLL,
        => true,
        else => false,
    };
}

/// Map a Win32 virtual key code to a Ghostty input.Key.
fn mapVirtualKey(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        // Letter keys (A-Z: 0x41-0x5A)
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        // Number keys (0-9: 0x30-0x39)
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        // Function keys
        w32.VK_F1 => .f1,
        w32.VK_F2 => .f2,
        w32.VK_F3 => .f3,
        w32.VK_F4 => .f4,
        w32.VK_F5 => .f5,
        w32.VK_F6 => .f6,
        w32.VK_F7 => .f7,
        w32.VK_F8 => .f8,
        w32.VK_F9 => .f9,
        w32.VK_F10 => .f10,
        w32.VK_F11 => .f11,
        w32.VK_F12 => .f12,
        w32.VK_F13 => .f13,
        w32.VK_F14 => .f14,
        w32.VK_F15 => .f15,
        w32.VK_F16 => .f16,
        w32.VK_F17 => .f17,
        w32.VK_F18 => .f18,
        w32.VK_F19 => .f19,
        w32.VK_F20 => .f20,
        w32.VK_F21 => .f21,
        w32.VK_F22 => .f22,
        w32.VK_F23 => .f23,
        w32.VK_F24 => .f24,

        // Navigation / editing keys
        w32.VK_RETURN => if (extended) .numpad_enter else .enter,
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_END => .end,
        w32.VK_HOME => .home,
        w32.VK_LEFT => .arrow_left,
        w32.VK_UP => .arrow_up,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_DOWN => .arrow_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,

        // Modifier keys
        w32.VK_LSHIFT => .shift_left,
        w32.VK_RSHIFT => .shift_right,
        w32.VK_LCONTROL => .control_left,
        w32.VK_RCONTROL => .control_right,
        w32.VK_LMENU => .alt_left,
        w32.VK_RMENU => .alt_right,
        w32.VK_LWIN => .meta_left,
        w32.VK_RWIN => .meta_right,
        w32.VK_SHIFT => if (extended) .shift_right else .shift_left,
        w32.VK_CONTROL => if (extended) .control_right else .control_left,
        w32.VK_MENU => if (extended) .alt_right else .alt_left,

        // Lock keys
        w32.VK_CAPITAL => .caps_lock,
        w32.VK_NUMLOCK => .num_lock,
        w32.VK_SCROLL => .scroll_lock,

        // OEM keys (US keyboard layout)
        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,

        // Numpad keys
        w32.VK_NUMPAD0 => .numpad_0,
        w32.VK_NUMPAD1 => .numpad_1,
        w32.VK_NUMPAD2 => .numpad_2,
        w32.VK_NUMPAD3 => .numpad_3,
        w32.VK_NUMPAD4 => .numpad_4,
        w32.VK_NUMPAD5 => .numpad_5,
        w32.VK_NUMPAD6 => .numpad_6,
        w32.VK_NUMPAD7 => .numpad_7,
        w32.VK_NUMPAD8 => .numpad_8,
        w32.VK_NUMPAD9 => .numpad_9,
        w32.VK_MULTIPLY => .numpad_multiply,
        w32.VK_ADD => .numpad_add,
        w32.VK_SEPARATOR => .numpad_separator,
        w32.VK_SUBTRACT => .numpad_subtract,
        w32.VK_DECIMAL => .numpad_decimal,
        w32.VK_DIVIDE => .numpad_divide,

        // Misc
        w32.VK_APPS => .context_menu,
        w32.VK_PAUSE => .pause,

        else => .unidentified,
    };
}

/// Return a pointer to the core terminal surface.
pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

/// Return a reference to the App for use by core code.
pub fn rtApp(self: *Surface) *App {
    return self.app;
}
