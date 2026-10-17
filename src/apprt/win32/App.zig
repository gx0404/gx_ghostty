// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 application runtime. Manages the Win32 window classes, the
//! message loop, the window list and performs the apprt actions the core
//! sends (`performAction`) and the Ghostty GX binding actions (`gxAction`:
//! settings, main menu, keyboard shortcuts, launch profiles), delegating
//! window chrome to `Window` and surface popups, menus and dialogs to
//! `Surface` and the `ui/` modules.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const global = @import("../../global.zig");

const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Leaf = @import("Leaf.zig");
const RemotePane = @import("RemotePane.zig");
const RemoteSource = @import("RemoteSource.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const tabs = @import("tabs.zig");
const tab_status = @import("tab_status.zig");
const open_url = @import("open_url.zig");
const BellAudio = @import("BellAudio.zig");
const ComApartment = @import("ComApartment.zig");
const Session = @import("Session.zig");
const ShellIntegration = @import("ShellIntegration.zig");
const RemoteCoordinator = @import("RemoteCoordinator.zig");
const DropBridge = @import("DropBridge.zig");
const DropCompanion = @import("DropCompanion.zig");
const Uia = @import("ui/uia.zig");
const IpcInstance = @import("ipc/Instance.zig");
const IpcClient = @import("ipc/Client.zig");
const IpcEnvironment = @import("ipc/environment.zig");
const IpcProtocol = @import("../../gx/ipc/protocol.zig");
const OleDrop = @import("ole_drop.zig");
const w32 = @import("win32.zig");
const Backdrop = @import("chrome/Backdrop.zig");
const Dialogs = @import("ui/Dialogs.zig");
const Keybinds = @import("ui/Keybinds.zig");
const Menu = @import("ui/Menu.zig");
const Notice = @import("ui/Notice.zig");
const Settings = @import("ui/Settings.zig");
const d2d = @import("ui/d2d.zig");
const style = @import("ui/style.zig");
const trigger = @import("ui/trigger.zig");
const wstr = @import("ui/wstr.zig");
const key_conflicts = @import("shortcut_conflicts.zig");
const gx = @import("../../gx/main.zig");
const i18n = gx.i18n;
const PendingDrop = struct { attachment: gx.ui_ref.Attachment, payload: OleDrop.data.Payload };

const input = @import("../../input.zig");

/// A registered global system hotkey: the RegisterHotKey id, its chord and
/// the trigger whose binding WM_HOTKEY performs, as it is configured when
/// the hotkey is pressed (`onHotkey`).
const GlobalHotkey = struct { id: i32, chord: key_conflicts.Chord, trigger: input.Binding.Trigger };

const log = std.log.scoped(.win32);

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// Posted to the message-only window by `requestQuit`.
const WM_APP_QUIT: u32 = w32.WM_APP + 0x62;
const WM_APP_IPC: u32 = w32.WM_APP + 0x63;
const WM_APP_DROP: u32 = w32.WM_APP + 0x64;
const WM_APP_DROP_REGISTER: u32 = w32.WM_APP + 0x65;
const WM_APP_DROP_REAP: u32 = w32.WM_APP + 0x66;
const SESSION_TIMER_ID: usize = 0x5353;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// Timer ID and delay of the keybinding conflict probe (`probeShortcuts`).
const SHORTCUT_PROBE_TIMER_ID: usize = 4;
const shortcut_probe_delay_ms: u32 = 1000;

/// Posted to the message-only window by `deferGx`: a GX action that opens a
/// menu, which runs a modal loop, waits for the message loop. wparam is the
/// `DeferredGx`, lparam the core id of the surface it is for.
const WM_APP_DEFERRED_GX: u32 = w32.WM_APP + 6;

/// Timer of the taskbar progress, every second while a taskbar button shows
/// progress, so the reports that stopped coming end (`onProgressTimer`).
const PROGRESS_TIMER_ID: usize = 5;
const progress_timer_ms: u32 = 1000;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTerminal");

/// Window class for the message-only HWND (WM_APP_WAKEUP, WM_TIMER).
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg");

/// The core application.
core_app: *CoreApp,

/// The configuration for the application. Loaded during init and
/// updated in response to config_change actions.
config: Config,

/// A message-only window used to receive WM_APP_WAKEUP.
/// This is not a visible window; it just participates in the message loop.
msg_hwnd: ?w32.HWND = null,
ipc_server: ?*IpcInstance.Server = null,
ipc_forwarded: bool = false,

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atoms from RegisterClassExW.
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
msg_class_atom: u16 = 0,

/// List of active Window containers (tabbed windows).
windows: std.ArrayList(*Window) = .empty,
ui_ids: gx.ui_ref.Issuer = .{ .epoch = 0 },

/// Background brush created from the configured background color.
/// Used by WM_ERASEBKGND to fill exposed areas during resize,
/// matching the terminal background so the flash is invisible.
bg_brush: ?w32.HBRUSH = null,

/// Whether DWM can compose the terminals' frames with their alpha, so
/// the window material and `background-opacity` show per pixel
/// (`Backdrop.alphaFramesSupported`, decided once at startup).
alpha_frames: bool = false,

/// The `background-opacity` that `toggle_background_opacity` restores
/// while it holds the terminals opaque (per-pixel translucency only).
opaque_restore: ?f64 = null,

/// Quit timer state, mirroring GTK's three-state approach:
/// - off: no quit pending
/// - active: timer is running (waiting for delay to expire)
/// - expired: delay has elapsed, quit on next tick
quit_timer_state: enum { off, active, expired } = .off,

/// Whether quit has been requested.
quit_requested: bool = false,

/// Whether `run` runs the message loop. `main` starts the quit timer
/// before `run`, while the app has no terminal yet; `startQuitTimer`
/// ignores that call, since `run` opens the first window right away and a
/// WM_QUIT posted before the loop would end the first modal loop instead
/// (the dialog about a command that failed to start).
running: bool = false,

/// The quick terminal instance (if active).
quick_terminal: ?*QuickTerminal = null,

/// The window that was in front when `toggle_visibility` hid the windows;
/// it comes back to the front with them.
hidden_front: ?w32.HWND = null,

/// Registered global system hotkeys (RegisterHotKey on `msg_hwnd`, so the
/// modal loops of menus and dialogs dispatch them too). Maps the id
/// delivered in WM_HOTKEY back to the binding to perform. Generalized from
/// the old single quick-terminal hotkey to every keybind flagged `global:`.
global_hotkeys: std.ArrayList(GlobalHotkey) = .empty,

/// The keybinding chords another program or the input method takes, from
/// the last `probeShortcuts`. The shortcut sheet marks them and menus
/// leave their hints out.
shortcut_conflicts: key_conflicts.Conflicts = .{},

/// Whether this session showed the notice about taken default shortcuts.
shortcut_notice_shown: bool = false,

/// Cached ITaskbarList3 for taskbar-button progress (OSC 9;4), created lazily
/// on first progress_report. Null until then / if COM creation fails.
taskbar: ?*w32.ITaskbarList3 = null,

/// Core surface id of the surface that produced the current desktop
/// notification balloon; a balloon click focuses it. 0 = app-targeted.
/// A single id suffices: there is one NOTIF_DESKTOP_UID tray balloon and
/// each new notification overwrites it.
notif_desktop_reference: gx.ui_ref.Reference = .{},
/// Owns this GUI thread's COM/OLE references; consumers share the owner.
com_apartment: ComApartment = .{},

/// Direct2D/DirectWrite state of the custom-drawn UI (popups, chrome),
/// created on first use by `uiFactory`.
ui_factory: ?*d2d.Factory = null,
session: Session = .{},
shell: ShellIntegration = .{},
remote: RemoteCoordinator = .{},
drop_bridge: DropBridge = .{},
drop_companion: ?*DropCompanion = null,
session_save_ready: bool = false,
uia_api: ?*Uia.Api = null,
uia_queue: ?*Uia.Queue = null,
uia_initializing: bool = false,
uia_popups: @import("ui/uia_bridge.zig").Registry = .{},
fluent_icons: @import("ui/fluent_icons.zig").Cache = .{},
drop_feedback: @import("ui/DropFeedback.zig") = .{},
pending_drops: std.ArrayList(PendingDrop) = .empty,
drop_closing: bool = false,
retired_drop_targets: ?*OleDrop.Target = null,
drop_reaping: bool = false,
reaping_drop_target: ?*OleDrop.Target = null,
constructing_drop_hwnd: ?w32.HWND = null,
constructing_drop_destroy: bool = false,
constructing_drop_parent: ?w32.HWND = null,
drop_registration_pending: bool = false,

/// The command of new terminals while `command` is not configured (see
/// `updateDefaultCommand`). Null when `command` is configured or no shell
/// was found; the configured command (upstream: `cmd.exe`) applies then.
default_command: ?configpkg.Command = null,
default_profile_id: ?[]const u8 = null,

/// Owns `default_command`.
default_command_arena: std.heap.ArenaAllocator,

/// The process table the periodic checks of the GUI thread share (the tab
/// labels and herdr app mode of every window): read it with `processTable`.
proc_shared: gx.proc.Shared = .{},

/// The shells detected on this system, kept between uses: read the launch
/// profiles with `cachedLaunchProfiles`; `profiles_cache.invalidate()`
/// detects them again on the next use.
profiles_cache: gx.profiles.Cache = .{},

/// Whether `default_command` is to be picked again on the next
/// configuration change (`reload_config` detects the shells anew).
default_command_stale: bool = false,

/// Whether a `WM_APP_WAKEUP` is on its way: `wakeup` posts one only when it
/// sets this, so a burst of wakeups from the terminal threads queues a
/// single message; `msgWndProc` clears it before the core's tick.
wakeup_pending: std.atomic.Value(bool) = .init(false),

/// The color scheme `Window.WM_GHOSTTY_SIMULATE_SYSTEM_THEME` forces
/// instead of the system's (`appsUseLightTheme`); null follows Windows.
simulated_scheme: ?apprt.ColorScheme = null,

/// `gx.config_layers.diagnosticsDigest` of the configuration errors last
/// reported (0: none), so a reload that keeps them says nothing again.
diagnostics_reported: u64 = 0,

/// What the taskbar buttons show (`showTaskbarProgress`), so an unchanged
/// state is not set again; buttons without an entry show nothing.
taskbar_shown: std.ArrayList(TaskbarShown) = .empty,

/// Whether `PROGRESS_TIMER_ID` runs.
progress_timer: bool = false,

/// The message Explorer sends a window when its taskbar button exists, also
/// after Explorer restarted (`isTaskbarButtonCreated`).
taskbar_button_created: u32 = 0,

/// The large icon of desktop notifications, loaded on first use (shared,
/// never destroyed).
balloon_icon: ?w32.HICON = null,

bell_audio: ?*BellAudio.Player = null,

pub fn sampleSystemCursorBlink() ?bool {
    const value = caretBlinkPreference(w32.GetCaretBlinkTime());
    gx.config_layers.setSystemCursorBlink(value);
    return value;
}

fn loadConfig(alloc: Allocator) !Config {
    _ = sampleSystemCursorBlink();
    return try Config.load(alloc);
}

pub fn loadLayers(alloc: Allocator) !gx.config_layers.Layers {
    _ = sampleSystemCursorBlink();
    return try gx.config_layers.Layers.load(alloc);
}

fn caretBlinkPreference(milliseconds: u32) ?bool {
    if (milliseconds == 0) return null;
    return milliseconds != w32.INFINITE;
}

test "closing taskbar callbacks leave retained state untouched" {
    const alloc = std.testing.allocator;
    var app: App = .{
        .core_app = undefined,
        .config = undefined,
        .hinstance = undefined,
        .default_command_arena = undefined,
        .com_apartment = .init(),
        .progress_timer = true,
    };
    defer app.com_apartment.deinit() catch {};
    defer app.taskbar_shown.deinit(alloc);
    var window: Window = .{ .app = &app, .hwnd = @ptrFromInt(1) };
    try app.taskbar_shown.append(alloc, .{
        .hwnd = window.hwnd.?,
        .value = .{ .state = w32.TBPF_NORMAL, .percent = 50 },
    });
    try app.com_apartment.beginClose();
    app.onTaskbarButtonCreated(&window);
    try std.testing.expectEqual(@as(usize, 1), app.taskbar_shown.items.len);
    app.onProgressTimer();
    try std.testing.expectEqual(@as(usize, 1), app.taskbar_shown.items.len);
    try std.testing.expect(app.progress_timer);
}

test "R4 caret blink disables only at INFINITE" {
    try std.testing.expectEqual(@as(?bool, false), caretBlinkPreference(w32.INFINITE));
    try std.testing.expectEqual(@as(?bool, null), caretBlinkPreference(0));
    try std.testing.expectEqual(@as(?bool, true), caretBlinkPreference(500));
}

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    // The Ghostty GX defaults give a window material a background opacity
    // only where the material can show behind the terminals, which the
    // OpenGL device decides once its probe is done (`settleDevice`); until
    // then this guesses.
    const alpha_frames = expectAlphaFrames(core_app.alloc);
    gx.config_layers.setMaterialOpacity(alpha_frames);

    // Load the configuration for this application.
    const alloc = core_app.alloc;
    var config = loadConfig(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();
    repairWorkingDirectory(&config);
    const rng: std.Random.IoSource = .{ .io = global.io() };
    var epoch: gx.ui_ref.HostEpoch = 0;
    while (epoch == 0) epoch = rng.interface().int(gx.ui_ref.HostEpoch);
    const ui_ids = try gx.ui_ref.Issuer.init(epoch);

    // The UI language follows `language` (zh-CN by default).
    i18n.setCurrent(i18n.resolve(config.language));

    // Create a brush matching the configured background color so that
    // any exposed window area during resize matches the terminal
    // background, making the flash invisible.
    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));
    errdefer if (bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
    };

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
        .alpha_frames = alpha_frames,
        .ui_ids = ui_ids,
        .com_apartment = .init(),
        .default_command_arena = .init(alloc),
    };
    errdefer self.com_apartment.deinit() catch {};
    errdefer self.default_command_arena.deinit();
    errdefer if (self.ipc_server) |server| server.destroy();
    try self.shell.readStartup(alloc);
    errdefer self.shell.deinit(alloc);
    if (try self.routeInitialLaunch()) return;
    if (self.shell.startup != .drop_companion and self.shell.startup != .toast_server) self.updateDefaultCommand();

    // Register the window container class (GDI painting, no CS_OWNDC).
    // CS_DBLCLKS is required to receive WM_LBUTTONDBLCLK for divider equalize.
    // Application icon, loaded from the embedded resource. Falls back
    // to the default app icon if missing (only happens with unusual
    // build configs that strip the .rc file).
    const app_icon = w32.LoadIconW(hinstance, w32.IDI_GHOSTTY) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &Window.windowWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;
    errdefer if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
    };

    // Register the terminal surface class (OpenGL via WGL, needs CS_OWNDC).
    const tc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TERMINAL_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.terminal_class_atom = w32.RegisterClassExW(&tc);
    if (self.terminal_class_atom == 0) return error.Win32Error;
    errdefer if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
    };

    // Register the message-only window class (WM_APP_WAKEUP, WM_TIMER).
    const mc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &msgWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = MSG_CLASS_NAME,
        .hIconSm = null,
    };

    self.msg_class_atom = w32.RegisterClassExW(&mc);
    if (self.msg_class_atom == 0) return error.Win32Error;
    errdefer if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
    };

    // Create a message-only window for receiving WM_APP_WAKEUP.
    // HWND_MESSAGE makes it a message-only window (invisible, no rendering).
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        MSG_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg"),
        0, // no style needed
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;
    errdefer {
        _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.msg_hwnd.?);
        self.msg_hwnd = null;
    }

    // Store self pointer in msg_hwnd's GWLP_USERDATA for msgWndProc access
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.shell.initialize(self) catch |err| log.warn("shell integration unavailable: {}", .{err});
    errdefer self.remote.shutdown(self);
    if (self.shell.startup != .drop_companion and self.shell.startup != .toast_server) self.remote.initialize(self) catch |err| log.warn("remote transfer unavailable: {}", .{err});
    errdefer self.drop_bridge.destroy() catch {};
    if (self.shell.startup != .drop_companion and self.shell.startup != .toast_server) self.drop_bridge.initialize(self) catch |err| log.warn("drop broker unavailable: {}", .{err});

    self.taskbar_button_created = RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"));

    // Register the `global:` keybinds as system hotkeys.
    if (self.shell.startup != .toast_server and self.shell.startup != .drop_companion) self.registerGlobalHotkey();
    errdefer self.unregisterGlobalHotkeys();
    if (self.ipc_server) |server| try server.start(self.msg_hwnd.?, WM_APP_IPC);
}

pub fn run(self: *App) !void {
    if (self.ipc_forwarded) return;
    self.running = true;
    defer self.running = false;

    // The first window and its terminal start in the theme for the light or
    // dark app mode of Windows (`theme = light:…,dark:…`).
    self.syncColorScheme();

    // Device setup needs an empty HWND before restoring any terminal leaves.
    if (self.shell.startup == .drop_companion) {
        self.session.protect_file = true;
        self.drop_companion = try DropCompanion.create(self, self.shell.startup.drop_companion);
        self.stopQuitTimer();
    } else if (self.shell.startup == .toast_server) {
        self.session.protect_file = true;
        if (self.shell.worker == null) return;
        _ = w32.SetTimer(self.msg_hwnd.?, ShellIntegration.server_timer, 15000, null);
    } else if (self.config.@"initial-window" or self.shell.startup == .profile) {
        const alloc = self.core_app.alloc;
        const window = window: {
            const window = try alloc.create(Window);
            errdefer alloc.destroy(window);
            var initialized = false;
            errdefer if (initialized) window.deinit();
            try window.init(self, .{});
            initialized = true;
            if (try self.settleDevice()) {
                window.deinit();
                initialized = false;
                try window.init(self, .{});
                initialized = true;
            }
            try self.windows.append(alloc, window);
            break :window window;
        };
        const bootstrap = window.ui_reference;
        if (self.shell.startup == .profile) {
            self.session.protect_file = true;
            var profiles = try self.cachedLaunchProfiles();
            defer profiles.deinit();
            const profile_id = self.shell.startup.profile;
            if (profiles.find(profile_id) == null or !self.openProfile(window, profile_id, .tab)) {
                self.discardSessionWindow(bootstrap);
                return error.ShellProfileUnavailable;
            }
        } else if (self.session.tryRestore(self)) {
            self.discardSessionWindow(bootstrap);
        } else {
            if (self.quit_requested) return;
            const fallback = self.resolveWindow(bootstrap) orelse try self.newWindow(.{});
            _ = try fallback.addTab();
        }
        self.scheduleShortcutProbe();
        self.scheduleSessionSave();
    } else {
        self.session.protect_file = true;
        self.stopQuitTimer();
    }

    // Enter the Win32 message loop
    var msg: w32.MSG = undefined;
    loop: while (true) {
        // Only this outer loop is a safe COM-revocation boundary. A posted
        // reaper message can also arrive inside a native/modal transaction.
        self.reapDropTargets();
        self.installDropTargets();
        self.refreshUia();
        self.shell.drain(self);
        const remote_kept_alive = self.remote.keepsAlive();
        self.remote.drain(self);
        self.drop_bridge.updateTarget(self);
        self.drop_bridge.drain(self);
        if (self.drop_companion) |companion| {
            companion.drain();
            if (!companion.keepsAlive()) {
                if (companion.destroy()) |_| {
                    self.drop_companion = null;
                    self.startQuitTimer();
                } else |err| log.err("drop companion shutdown pending: {}", .{err});
            }
        }
        if (remote_kept_alive and !self.remote.keepsAlive() and self.windows.items.len == 0 and self.quick_terminal == null) self.startQuitTimer();
        if (self.session_save_ready) {
            self.session_save_ready = false;
            self.session.flush(self);
        }
        Menu.prepareIdle(self);
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT received. Check if it's still wanted — stopQuitTimer()
            // resets quit_requested if a new surface opened after
            // PostQuitMessage was called; the modal loops of the dialogs
            // and menus drop such a WM_QUIT likewise
            // (`Popup.modalQuitCode`). GetMessageW consumes the quit flag,
            // so the next call will block normally for real messages.
            if (!self.quit_requested) continue;
            break;
        }
        if (result < 0) return error.Win32Error;
        if (self.quit_requested) {
            // GetMessageW already removed this payload from the queue, so
            // terminate's remaining-queue drain cannot reclaim it.
            if (self.msg_hwnd) |hwnd| discardOwnedRequest(self.core_app.alloc, hwnd, &msg);
            break;
        }

        // Intercept keystrokes destined for popup edit controls so
        // Enter/Escape/Arrow keys can be handled by our code.
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
            if (self.routeEditKey(&msg)) continue :loop;
        }

        // Alt+Space opens the window menu (see Window.handleSystemMenuKey).
        if (Window.handleSystemMenuKey(self, &msg)) continue :loop;

        // Skip TranslateMessage for keyboard events on terminal surface
        // windows: handleKeyEvent calls ToUnicode directly, and
        // TranslateMessage's internal ToUnicodeEx mutates the same
        // per-queue dead-key state — racing
        // it broke dead-key composition on ABNT2 (`~`+`a` → `~a`). Edit
        // controls (search, palette, tab rename) still need it.
        const skip_translate = switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
                // Keys claimed by the IME arrive as VK_PROCESSKEY and MUST
                // go through TranslateMessage: that is what forwards them to
                // the IME (ImmTranslateMessage) to generate the
                // WM_IME_STARTCOMPOSITION/WM_IME_COMPOSITION messages and
                // drive the candidate window. Skipping it made CJK input
                // dead. This does not disturb the ToUnicode dead-key state:
                // handleKeyEvent never calls ToUnicode for VK_PROCESSKEY.
                if (msg.wParam == w32.VK_PROCESSKEY) break :blk false;
                // Characters injected with SendInput KEYEVENTF_UNICODE arrive
                // as VK_PACKET, which only TranslateMessage turns into the
                // WM_CHAR that carries them; it does not consult the
                // keyboard layout, so the dead-key state is untouched.
                if (msg.wParam == w32.VK_PACKET) break :blk false;
                const h = msg.hwnd orelse break :blk false;
                const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
                break :blk (atom != 0 and atom == self.terminal_class_atom) or RemotePane.isWindow(h);
            },
            else => false,
        };
        if (!skip_translate) _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

/// What `Backdrop.alphaFramesSupported` most likely says once the OpenGL
/// device has probed: per-pixel translucency on the Windows builds with
/// materials, unless software OpenGL is asked for (`GHOSTTY_GX_OPENGL`).
fn expectAlphaFrames(alloc: Allocator) bool {
    if (!Backdrop.supportsMaterials()) return false;
    const value = global.environ().getAlloc(alloc, "GHOSTTY_GX_OPENGL") catch return true;
    defer alloc.free(value);
    return !std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " "), "software");
}

/// Wait on the GUI thread after the first hidden window exists, before
/// creating any surface or taking renderer locks. Reports missing OpenGL;
/// returns true when the window must be rebuilt with the settled opacity.
fn settleDevice(self: *App) !bool {
    self.core_app.device.wait() catch |err| {
        reportOpenGLUnavailable();
        return err;
    };
    const supported = Backdrop.alphaFramesSupported(&self.core_app.device);
    if (supported == self.alpha_frames) return false;
    log.info("per-pixel translucency={} unlike guessed, loading the configuration again", .{supported});
    self.alpha_frames = supported;
    gx.config_layers.setMaterialOpacity(supported);
    var config = try loadConfig(self.core_app.alloc);
    defer config.deinit();
    try self.core_app.updateConfig(self, &config);
    return true;
}

/// Without OpenGL nothing renders, and there is no window to say so in.
fn reportOpenGLUnavailable() void {
    var text: [512]u16 = undefined;
    var caption: [64]u16 = undefined;
    _ = w32.MessageBoxW(
        null,
        wstr.bufZ(&text, i18n.tr("Ghostty GX requires OpenGL 4.3 or newer, but no usable OpenGL driver was found.\n\nUpdate the graphics driver, or put a Mesa opengl32.dll in the \"mesa\" folder next to ghostty.exe.")),
        wstr.bufZ(&caption, gx.branding.name),
        MB_ICONERROR,
    );
}

const MB_ICONERROR: u32 = 0x00000010;

/// The chrome or popup element that owns a focused Edit control.
const EditOwner = union(enum) {
    rename: *Window,
    palette: *Window,
    search: *Surface,
    remote_search: *RemotePane,
};

/// GUI-thread-only lookup. The returned pointer is borrowed until the next
/// message pump; retain the reference and resolve again after modal/COM calls.
pub fn resolveWindow(self: *App, reference: gx.ui_ref.Reference) ?*Window {
    if (!reference.isValid() or reference.kind != .window or reference.epoch != self.ui_ids.epoch) return null;
    for (self.windows.items) |window| {
        if (!window.closing and reference.matches(window.ui_reference)) return window;
    }
    if (self.quick_terminal) |quick| {
        if (!quick.window.closing and reference.matches(quick.window.ui_reference)) return quick.window;
    }
    if (self.remote.resolveHostWindow(reference)) |window| {
        if (!window.closing) return window;
    }
    return null;
}

pub fn resolveWindowView(self: *App, attachment: gx.ui_ref.Attachment) ?*Window {
    const window = self.resolveWindow(attachment.object) orelse return null;
    if (!attachment.matches(window.ui_attachment)) return null;
    return window;
}

/// A GUI-thread borrowed tab location; indices are not persistent identities.
pub const TabLocation = struct { window: *Window, index: usize };

pub fn resolveTab(self: *App, reference: gx.ui_ref.Reference) ?TabLocation {
    if (!reference.isValid() or reference.kind != .tab or reference.epoch != self.ui_ids.epoch) return null;
    for (self.windows.items) |window| {
        if (window.resolveTab(reference)) |index| return .{ .window = window, .index = index };
    }
    if (self.quick_terminal) |quick| {
        if (quick.window.resolveTab(reference)) |index| return .{ .window = quick.window, .index = index };
    }
    return null;
}

pub fn resolveTabView(self: *App, attachment: gx.ui_ref.Attachment) ?TabLocation {
    const window = self.resolveWindow(attachment.owner) orelse return null;
    const index = window.resolveTab(attachment.object) orelse return null;
    if (!attachment.matches(window.tab_attachments[index])) return null;
    return .{ .window = window, .index = index };
}

/// GUI-thread-only core identity lookup, including temporarily hidden views.
pub fn resolveSurface(self: *App, reference: gx.ui_ref.Reference) ?*Surface {
    if (!reference.isValid() or reference.kind != .surface or reference.epoch != self.ui_ids.epoch) return null;
    for (self.core_app.surfaces.items) |surface| {
        if (!surface.core_surface_initialized or !surface.core_surface_ready) continue;
        if (surface.parent_window.closing or !surface.parent_window.ui_reference.isValid()) continue;
        if (reference.matches(surface.ui_reference)) return surface;
    }
    return null;
}

pub fn resolveSurfaceView(self: *App, attachment: gx.ui_ref.Attachment) ?*Surface {
    const surface = self.resolveSurface(attachment.object) orelse return null;
    if (!attachment.matches(surface.ui_attachment)) return null;
    if (!attachment.owner.matches(surface.parent_window.ui_reference)) return null;
    return surface;
}

/// Find which tab rename, palette or search Edit control `hwnd` is.
fn findEditOwner(self: *App, hwnd: w32.HWND) ?EditOwner {
    for (self.windows.items) |win| {
        if (findEditOwnerIn(win, hwnd)) |owner| return owner;
    }
    if (self.quick_terminal) |qt| return findEditOwnerIn(qt.window, hwnd);
    return null;
}

fn findEditOwnerIn(win: *Window, hwnd: w32.HWND) ?EditOwner {
    if (win.tab_bar.isRenameEdit(hwnd)) return .{ .rename = win };
    if (win.palette.active and win.palette.ownsEdit(hwnd)) return .{ .palette = win };
    for (0..win.tab_count) |i| {
        var it = win.tab_trees[i].iterator();
        while (it.next()) |entry| {
            switch (entry.view.backend) {
                .local => |surface| if (surface.search_bar.active and surface.search_bar.ownsEdit(hwnd)) return .{ .search = surface },
                .remote => |remote| if (remote.ui.search_bar.active and remote.ui.search_bar.ownsEdit(hwnd)) return .{ .remote_search = remote },
            }
        }
    }
    return null;
}

/// Handle a WM_KEYDOWN for one of the chrome/popup Edit controls before
/// it is translated: Enter/Escape/arrows drive the rename, palette and
/// search popups, then `editKeyRoute` decides between the edit control,
/// the surface's keybindings and nothing. Returns true when the message
/// was consumed.
fn routeEditKey(self: *App, msg: *const w32.MSG) bool {
    const hwnd = msg.hwnd orelse return false;
    const owner = self.findEditOwner(hwnd) orelse return false;
    const vk: u16 = @intCast(msg.wParam & 0xFFFF);

    switch (owner) {
        .rename => |win| if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
            if (vk == w32.VK_RETURN) {
                win.tab_bar.finishRename();
            } else {
                win.tab_bar.cancelRename();
            }
            return true;
        },
        .search => |surface| if (surface.search_bar.handleKey(vk)) return true,
        .remote_search => |remote| if (remote.ui.search_bar.handleKey(vk)) return true,
        .palette => |win| if (win.palette.handleKey(vk)) return true,
    }

    const mods: input.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
    };
    // The key goes to the pane below, so a remote one decides with the
    // source's keybind snapshot, like its find bar and the palette.
    const bindings = switch (owner) {
        .remote_search => |remote| &remote.ui.keybind_set.set,
        .palette => |win| win.palette.keybindSet(),
        .rename => |win| rename: {
            const leaf = win.activeLeaf() orelse break :rename &self.config.keybind.set;
            const remote = leaf.remote() orelse break :rename &self.config.keybind.set;
            break :rename &remote.ui.keybind_set.set;
        },
        .search => &self.config.keybind.set,
    };
    const bound = mods.ctrl and trigger.isBound(bindings, vk, mods);
    switch (editKeyRoute(vk, mods, bound)) {
        .edit => return false,
        .swallow => return true,
        .bubble => {},
    }

    // A keybinding: e.g. `Ctrl+Shift+P` while renaming toggles the palette
    // instead of being eaten by the edit control.
    const target: ?@import("Pane.zig") = switch (owner) {
        // Commit (not cancel) — matches standard Win32 inline rename
        // convention (Explorer, Edge): any action that takes focus away
        // saves the typed title.
        .rename => |win| target: {
            win.tab_bar.finishRename();
            break :target win.activePane();
        },
        .palette => |win| target: {
            win.palette.setActive(false);
            break :target win.activePane();
        },
        // The search goes on: the bar stays open, the terminal gets the
        // focus and the key.
        .search => |surface| target: {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
            break :target @import("Pane.zig").fromLocal(surface);
        },
        .remote_search => |remote| target: {
            const reference = remote.ui_reference;
            if (remote.hwnd) |h| _ = w32.SetFocus(h);
            break :target @import("Pane.zig").resolve(self, reference);
        },
    };
    const pane = target orelse return false;
    const child = pane.nativeHandle() orelse return false;
    _ = w32.SendMessageW(child, msg.message, msg.wParam, msg.lParam);
    return true;
}

/// Where a key typed into a popup edit control goes after the popup's own
/// keys (`routeEditKey`).
const EditKeyRoute = enum {
    /// The edit control or popup handles it, or ignores it.
    edit,
    /// The surface performs the keybinding it is bound to.
    bubble,
    /// Nothing: the key never reaches the shell.
    swallow,
};

/// Route the key `vk` pressed with `mods` in a popup edit control (tab
/// rename, command palette, find bar); `bound` tells whether a keybinding
/// takes it (`trigger.isBound`). Keys without Ctrl and editing keys
/// stay with the edit control (moving, selecting and deleting, the
/// clipboard, undo and redo, also with Ctrl or Ctrl+Shift); bound Ctrl
/// chords go to the surface's keybindings; other Ctrl chords do nothing,
/// except Ctrl+Alt, which is AltGr typing a character.
fn editKeyRoute(vk: u16, mods: input.Mods, bound: bool) EditKeyRoute {
    if (!mods.ctrl) return .edit;
    switch (vk) {
        w32.VK_LEFT,
        w32.VK_RIGHT,
        w32.VK_UP,
        w32.VK_DOWN,
        w32.VK_HOME,
        w32.VK_END,
        w32.VK_BACK,
        w32.VK_DELETE,
        w32.VK_INSERT,
        'A',
        'C',
        'V',
        'X',
        'Y',
        'Z',
        // The input method's and injected keys, and modifiers on their own.
        w32.VK_PROCESSKEY,
        w32.VK_PACKET,
        w32.VK_SHIFT,
        w32.VK_CONTROL,
        w32.VK_MENU,
        w32.VK_LSHIFT,
        w32.VK_RSHIFT,
        w32.VK_LCONTROL,
        w32.VK_RCONTROL,
        w32.VK_LMENU,
        w32.VK_RMENU,
        w32.VK_LWIN,
        w32.VK_RWIN,
        w32.VK_CAPITAL,
        w32.VK_NUMLOCK,
        w32.VK_SCROLL,
        => return .edit,
        else => {},
    }
    if (bound) return .bubble;
    if (mods.alt) return .edit;
    return .swallow;
}

pub fn terminate(self: *App) void {
    self.drop_bridge.beginClose();
    if (self.drop_companion) |companion| {
        // Busy means COM or an outer drain still borrows App-owned state.
        // Continuing teardown would turn that lifecycle violation into a UAF.
        companion.destroy() catch @panic("drop companion still borrowed during App termination");
        self.drop_companion = null;
    }
    // Stop remote control and detach all render exports while object identities,
    // GUI windows, COM and the message destination still belong to this app.
    self.remote.shutdown(self);
    // run has returned, so nested GUI IPC handlers have all finished. Stop
    // workers before destroying their HWND or any terminal targets.
    if (self.ipc_server) |server| {
        self.ipc_server = null;
        server.destroy();
    }
    self.shell.deinit(self.core_app.alloc);
    self.ui_ids.epoch = 0;
    if (self.uia_queue) |queue| queue.close();
    self.uia_popups.deinit();
    self.drop_closing = true;
    var pending_drops = self.pending_drops;
    self.pending_drops = .empty;
    self.drop_feedback.deinit();
    for (pending_drops.items) |*request| request.payload.deinit();
    pending_drops.deinit(self.core_app.alloc);
    self.com_apartment.beginClose() catch |err| log.err("COM apartment 关闭准备失败: {}", .{err});
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, PROGRESS_TIMER_ID);
    self.progress_timer = false;
    self.stopQuitTimer();
    if (self.bell_audio) |player| {
        player.destroy();
        self.bell_audio = null;
    }

    // Out of sight first: below, the terminals of every window shut down
    // one after the other, which takes a moment each.
    for (self.windows.items) |window| {
        if (window.hwnd) |hwnd| _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
    }
    if (self.quick_terminal) |qt| {
        if (qt.window.hwnd) |hwnd| _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
    }
    // The icon of the last desktop notification would stay in the
    // notification area until the pointer passes over it.
    self.removeNotificationIcon();

    self.unregisterGlobalHotkeys();

    // Release the taskbar COM object if we created one.
    if (self.taskbar) |tb| {
        self.taskbar = null;
        tb.Release();
    }

    // Destroy quick terminal if active.
    if (self.quick_terminal) |qt| {
        qt.deinit();
        self.quick_terminal = null;
    }

    // Deinit and free all Window containers.
    const alloc = self.core_app.alloc;
    for (self.windows.items) |window| {
        window.deinit();
        alloc.destroy(window);
    }
    self.windows.deinit(alloc);
    self.windows = .empty;
    // All model owners are inert. Revoke registered children while their HWNDs
    // and window classes still exist, before releasing shared GUI resources.
    self.reapDropTargets();

    // Concrete surface/dialog teardown has returned every owned paste receipt.
    self.drop_bridge.destroy() catch @panic("drop broker receipts still live during App termination");

    // Last: the threads of the terminals wake the message loop through it
    // until they are gone.
    if (self.msg_hwnd) |hwnd| {
        // The worker threads have joined. Windows discards queued messages on
        // destruction, so explicitly free the two owned pointer payload types.
        discardQueuedRequests(alloc, hwnd);
        // Clear GWLP_USERDATA before destroying so msgWndProc sees
        // userdata=0 and falls through to DefWindowProc for any
        // messages during destruction (e.g. WM_DESTROY).
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    // After the windows: their popups draw with the factory.
    self.fluent_icons.deinit();
    if (self.uia_queue) |queue| queue.release();
    self.uia_queue = null;
    if (self.uia_api) |api| api.release();
    self.uia_api = null;
    if (self.ui_factory) |factory| {
        factory.destroy();
        self.ui_factory = null;
    }

    if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
        self.msg_class_atom = 0;
    }
    if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
        self.terminal_class_atom = 0;
    }
    if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
        self.class_atom = 0;
    }

    self.com_apartment.deinit() catch |err| log.err("COM apartment 清理失败: {}", .{err});
    self.global_hotkeys.deinit(alloc);
    self.shortcut_conflicts.deinit(alloc);
    self.taskbar_shown.deinit(alloc);
    self.proc_shared.deinit();
    self.profiles_cache.deinit();
    self.default_command_arena.deinit();
    self.session.deinit();
    self.config.deinit();
}

/// Only used after the app loop stops. PeekMessageW returns WM_QUIT even when
/// the HWND and message filters do not match; its lParam is not an owned
/// request. Consume it here and keep draining the actual queued payloads.
fn discardQueuedRequests(alloc: Allocator, hwnd: w32.HWND) void {
    var pending: w32.MSG = undefined;
    while (w32.PeekMessageW(&pending, hwnd, WM_APP_EXPORT_TERMINAL_IO, WM_APP_EXPORT_TERMINAL_IO, w32.PM_REMOVE) != 0) {
        discardOwnedRequest(alloc, hwnd, &pending);
    }
    while (w32.PeekMessageW(&pending, hwnd, WM_APP_OPEN_LINK, WM_APP_OPEN_LINK, w32.PM_REMOVE) != 0) {
        discardOwnedRequest(alloc, hwnd, &pending);
    }
}

fn discardOwnedRequest(alloc: Allocator, hwnd: w32.HWND, pending: *const w32.MSG) void {
    if (pending.hwnd != hwnd) return;
    switch (pending.message) {
        WM_APP_EXPORT_TERMINAL_IO => {
            const request: *TerminalIoExport = @ptrFromInt(@as(usize, @bitCast(pending.lParam)));
            request.destroy(alloc);
        },
        WM_APP_OPEN_LINK => {
            const request: *LinkRequest = @ptrFromInt(@as(usize, @bitCast(pending.lParam)));
            request.destroy(alloc);
        },
        else => {},
    }
}

pub fn scheduleSessionSave(self: *App) void {
    if (!self.running or self.drop_closing or !self.config.@"gx-session-restore" or self.ipc_forwarded) return;
    self.session.markDirty();
    if (self.msg_hwnd) |hwnd| _ = w32.SetTimer(hwnd, SESSION_TIMER_ID, 300, null);
}

pub fn ensureUia(self: *App) bool {
    if (self.uia_api != null and self.uia_queue != null) return true;
    if (self.drop_closing or self.uia_initializing) return false;
    const hwnd = self.msg_hwnd orelse return false;
    self.uia_initializing = true;
    defer self.uia_initializing = false;
    self.com_apartment.ensureCom() catch return false;
    // Providers can outlive GUI owners and be released from an external MTA.
    const alloc = std.heap.page_allocator;
    const api = Uia.Api.load(alloc) catch return false;
    const queue = Uia.Queue.create(alloc, hwnd) catch {
        api.release();
        return false;
    };
    self.uia_api = api;
    self.uia_queue = queue;
    return true;
}

pub fn uiaForWindow(self: *App, window: *Window, wparam: usize, lparam: isize) isize {
    if (w32.objectId(lparam) != Uia.root_object_id) return 0;
    const reference = window.ui_reference;
    if (!self.ensureUia()) return 0;
    const live = self.resolveWindow(reference) orelse return 0;
    live.uia_bridge.publish(live, self.uia_api.?, self.uia_queue.?) catch |err| {
        log.warn("UIA snapshot unavailable err={}", .{err});
        return 0;
    };
    live.uia_dirty = false;
    return live.uia_bridge.publisher.returnProvider(wparam, lparam);
}

fn refreshUia(self: *App) void {
    const api = self.uia_api orelse return;
    const queue = self.uia_queue orelse return;
    for (self.windows.items) |window| {
        if (!window.uia_dirty) continue;
        window.uia_dirty = false;
        window.uia_bridge.publish(window, api, queue) catch |err| log.warn("UIA refresh failed err={}", .{err});
    }
    if (self.quick_terminal) |quick| {
        const window = quick.window;
        if (window.uia_dirty) {
            window.uia_dirty = false;
            window.uia_bridge.publish(window, api, queue) catch {};
        }
    }
}

fn onUia(self: *App) void {
    const queue = self.uia_queue orelse return;
    // A bounded queue can still be replenished indefinitely by external MTA
    // clients. Yield back to native messages after a bounded GUI batch.
    var budget: usize = 64;
    while (budget > 0) : (budget -= 1) {
        const value = queue.pop() orelse break;
        var action = value;
        defer action.deinit();
        if (self.uia_popups.dispatch(self, &action)) continue;
        if (self.dispatchRemoteUia(&action)) continue;
        // dispatch may close a window or enter a modal loop. Stop iterating as
        // soon as the snapshot owner matches; no list pointer survives it.
        var handled = false;
        for (self.windows.items) |window| {
            if (!window.uia_bridge.publisher.accepts(action)) continue;
            _ = window.uia_bridge.dispatch(self, &action);
            handled = true;
            break;
        }
        if (!handled) if (self.quick_terminal) |quick| {
            if (quick.window.uia_bridge.publisher.accepts(action)) _ = quick.window.uia_bridge.dispatch(self, &action);
        };
    }
    self.uia_popups.retryAnnouncements();
}

/// Remove only this staged window, without treating rollback as a user close
/// or starting the quit timer while a normal startup fallback is still pending.
pub fn discardSessionWindow(self: *App, reference: gx.ui_ref.Reference) void {
    const window = self.resolveWindow(reference) orelse return;
    for (self.windows.items, 0..) |candidate, index| {
        if (candidate != window) continue;
        _ = self.windows.orderedRemove(index);
        window.deinit();
        self.core_app.alloc.destroy(window);
        return;
    }
}

/// The Direct2D/DirectWrite factory of the custom-drawn UI, created on
/// first use. Null when Direct2D is unavailable (`d2d.Factory.create`
/// logs that once and does not retry).
pub fn uiFactory(self: *App) ?*d2d.Factory {
    if (self.ui_factory) |factory| return factory;
    self.ui_factory = d2d.Factory.create(self.core_app.alloc) catch return null;
    self.fluent_icons = .init(self.ui_factory.?);
    return self.ui_factory;
}

/// Wake up the message loop from any thread so that it runs the core's
/// tick. Wakeups coalesce: while one `WM_APP_WAKEUP` waits in the queue,
/// more do not post another, so a burst of terminal output does not crowd
/// out painting, timers and input with wakeup messages.
pub fn wakeup(self: *App) void {
    // Acquire-release: the mailbox push before this call happens before
    // the tick that clears the flag (`msgWndProc`), so that tick drains it.
    if (self.wakeup_pending.swap(true, .acq_rel)) return;
    const hwnd = self.msg_hwnd orelse {
        self.wakeup_pending.store(false, .release);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0) == 0) self.wakeup_pending.store(false, .release);
}

/// A system broadcast (`w32.SystemChange`) reached the top-level `window`
/// (`Window.onSystemSettingChange`). GUI thread. Every window hears each
/// broadcast, so the app acts for one of them (`primaryWindow`): the light
/// or dark app mode ("ImmersiveColorSet") goes to the core and the
/// terminals (`syncColorScheme`), and changed environment variables
/// ("Environment") detect the shells of the launch profiles again.
pub fn onSystemSettingChange(self: *App, window: *Window, change: w32.SystemChange) void {
    if (window != self.primaryWindow()) return;
    if (change.isArea("ImmersiveColorSet")) self.syncColorScheme();
    if (change.isArea("Environment")) {
        self.profiles_cache.invalidate();
        self.updateDefaultCommand();
        Menu.invalidateApp(self);
    }
}

/// The window that answers system broadcasts for the app: the first one,
/// else the quick terminal.
fn primaryWindow(self: *App) ?*Window {
    if (self.windows.items.len > 0) return self.windows.items[0];
    if (self.quick_terminal) |qt| return qt.window;
    return null;
}

/// Whether apps use the light theme: "Choose your app mode" in the Windows
/// settings (`Backdrop.systemUsesLightTheme`), or what
/// `Window.WM_GHOSTTY_SIMULATE_SYSTEM_THEME` forces. GUI thread.
pub fn appsUseLightTheme(self: *const App) bool {
    if (self.simulated_scheme) |scheme| return scheme == .light;
    return Backdrop.systemUsesLightTheme();
}

/// Tell the core and every terminal whether apps use the light or the dark
/// theme (`appsUseLightTheme`): `theme = light:…,dark:…` and the other
/// conditional configuration follow it, and programs that ask for the
/// color scheme (DSR 996, mode 2031) get the truth. The core does nothing
/// when it did not change.
fn syncColorScheme(self: *App) void {
    const scheme: apprt.ColorScheme = if (self.appsUseLightTheme()) .light else .dark;
    self.core_app.colorSchemeEvent(self, scheme) catch |err| {
        log.warn("cannot apply the color scheme err={}", .{err});
    };
    for (self.core_app.surfaces.items) |surface| {
        if (!surface.core_surface_ready) continue;
        surface.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.warn("cannot apply the color scheme to a terminal err={}", .{err});
        };
    }
}

/// What `Window.WM_GHOSTTY_SIMULATE_SYSTEM_THEME` asks to simulate, packed
/// into its wparam: the apps color scheme and Windows high contrast, each
/// following the system or forced.
pub const SimulatedSystemTheme = packed struct(usize) {
    scheme: enum(u2) { system = 0, light = 1, dark = 2, _ } = .system,
    high_contrast: enum(u2) { system = 0, on = 1, off = 2, _ } = .system,
    reserved: std.meta.Int(.unsigned, @bitSizeOf(usize) - 4) = 0,
};

/// Test hook (`Window.WM_GHOSTTY_SIMULATE_SYSTEM_THEME`, GUI thread): act
/// as if Windows switched to the color scheme and high contrast state that
/// `wparam` asks for (`SimulatedSystemTheme`), without touching the
/// settings of Windows. Every window then hears the broadcasts Windows
/// would send. Returns false for a wparam that is not a
/// `SimulatedSystemTheme`.
pub fn simulateSystemTheme(self: *App, wparam: usize) bool {
    const wanted = simulatedTheme(wparam) orelse return false;
    self.simulated_scheme = wanted.scheme;
    style.system.forced_high_contrast = wanted.high_contrast;
    for (self.windows.items) |window| broadcastSystemTheme(window);
    if (self.quick_terminal) |qt| broadcastSystemTheme(qt.window);
    return true;
}

/// What `SimulatedSystemTheme` `wparam` forces: the color scheme and high
/// contrast, null where it follows Windows. Null for an invalid wparam.
fn simulatedTheme(wparam: usize) ?struct { scheme: ?apprt.ColorScheme, high_contrast: ?bool } {
    const wanted: SimulatedSystemTheme = @bitCast(wparam);
    if (wanted.reserved != 0) return null;
    return .{
        .scheme = switch (wanted.scheme) {
            .system => null,
            .light => .light,
            .dark => .dark,
            _ => return null,
        },
        .high_contrast = switch (wanted.high_contrast) {
            .system => null,
            .on => true,
            .off => false,
            _ => return null,
        },
    };
}

/// Send `window` the broadcasts of an app mode or high contrast change.
fn broadcastSystemTheme(window: *Window) void {
    const hwnd = window.hwnd orelse return;
    const area = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet");
    _ = w32.SendMessageW(hwnd, w32.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(area)));
    _ = w32.SendMessageW(hwnd, w32.WM_SYSCOLORCHANGE, 0, 0);
}

pub fn instanceIsolation(alloc: Allocator, class: ?[]const u8) !@import("ipc/Security.zig").policy.Isolation {
    const path = try gx.config_layers.overlayPath(alloc);
    defer alloc.free(path);
    const directory = std.fs.path.dirname(path) orelse return error.InvalidPath;
    return IpcEnvironment.isolation(alloc, directory, class, @import("../../build_config.zig").version_string);
}

/// Runs before hotkeys and surfaces exist. Never independently launch after an
/// ambiguous IPC result: the primary may already have created the window.
fn routeInitialLaunch(self: *App) !bool {
    if (self.shell.startup == .toast_server or self.shell.startup == .drop_companion) return false;
    if (!self.config.@"gx-single-instance" or self.config.@"initial-command" != null) return false;
    var iter = try cli.args.argsIterator(self.core_app.alloc, global.args());
    defer iter.deinit();
    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--gx-shell-action=") or std.mem.startsWith(u8, arg, "--gx-shell-profile=")) continue;
        if (!IpcEnvironment.canForwardArgument(arg)) return false;
    }
    const isolation = try instanceIsolation(self.core_app.alloc, self.config.class);
    switch (try IpcInstance.elect(self.core_app.alloc, isolation, self.ui_ids.epoch)) {
        .primary => |server| self.ipc_server = server,
        .secondary => |endpoint| {
            const profile_id = if (self.shell.startup == .profile) self.shell.startup.profile else "";
            const outcome = try IpcClient.request(endpoint, self.ui_ids.epoch, 1, .{ .new_window = profile_id });
            if (outcome != .completed) return error.IPCExecutionFailed;
            self.ipc_forwarded = true;
            return true;
        },
    }
    return false;
}

/// CLI actions connect to the same authenticated namespace as ordinary starts.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) anyerror!bool {
    const request: IpcProtocol.Request = switch (action) {
        .toggle_quick_terminal => .toggle_quick_terminal,
        .new_window => if (value.arguments == null) .{ .new_window = "" } else return error.UnsupportedIPCOverrides,
        .new_tab => if (value.arguments == null and value.surface_id == 0) .{ .new_tab = "" } else return error.UnsupportedIPCOverrides,
    };
    var config = try Config.load(alloc);
    defer config.deinit();
    const class = switch (target) {
        .class => |name| name,
        .detect => config.class,
    };
    const isolation = try instanceIsolation(alloc, class);
    const security = @import("ipc/Security.zig");
    const native = @import("ipc/native.zig");
    const local = try security.inspect(native.GetCurrentProcessId());
    defer local.deinit();
    const endpoint = try IpcInstance.Endpoint.init(isolation, local.identity);
    const outcome = try IpcClient.request(endpoint, try IpcInstance.freshEpoch(), 1, request);
    return switch (outcome) {
        .completed => true,
        .unavailable => error.IPCUnavailable,
        .rejected => error.IPCRejected,
        .target_gone => error.IPCTargetGone,
        .execution_failed => error.IPCExecutionFailed,
        .cancelled => error.IPCCancelled,
    };
}

fn onIpc(self: *App) void {
    const server = self.ipc_server orelse return;
    while (server.take()) |work| {
        const outcome = if (self.quit_requested) IpcProtocol.Outcome.cancelled else self.executeIpc(work.request) catch |err| result: {
            log.err("IPC action failed err={}", .{err});
            break :result IpcProtocol.Outcome.execution_failed;
        };
        server.finish(work.key, outcome) catch |err| log.err("IPC completion failed err={}", .{err});
    }
}

pub fn dropCallbacks(self: *App) OleDrop.Callbacks {
    return .{ .context = self, .is_live = dropIsLive, .post = postDrop, .feedback = dropFeedback };
}

/// No allocation or foreign COM here: moves and surface teardown may still be
/// using borrowed tree pointers. Native revocation runs at a GUI safe point.
pub fn retireDropTarget(self: *App, target: *OleDrop.Target) void {
    target.invalidate();
    target.retired_next = self.retired_drop_targets;
    self.retired_drop_targets = target;
    if (self.msg_hwnd) |hwnd| _ = w32.PostMessageW(hwnd, WM_APP_DROP_REAP, 0, 0);
}

/// Keep a registered terminal HWND alive until native revoke releases OLE's
/// registration reference. Surface/core resources may already be gone.
pub fn deferDropWindowDestroy(self: *App, hwnd: w32.HWND) bool {
    if (self.constructing_drop_hwnd == hwnd) {
        self.constructing_drop_destroy = true;
        return true;
    }
    if (self.reaping_drop_target) |target| {
        if (target.hwnd == hwnd) {
            target.retired_destroy_hwnd = true;
            return true;
        }
    }
    var cursor = self.retired_drop_targets;
    while (cursor) |target| : (cursor = target.retired_next) {
        if (target.hwnd == hwnd) {
            target.retired_destroy_hwnd = true;
            return true;
        }
    }
    return false;
}

/// Destroy the parent only after the final registered child in reaper order.
pub fn deferDropParentDestroy(self: *App, hwnd: w32.HWND) bool {
    var last: ?*OleDrop.Target = null;
    if (self.reaping_drop_target) |target| {
        if (w32.GetParent(target.hwnd) == hwnd) last = target;
    }
    var cursor = self.retired_drop_targets;
    while (cursor) |target| : (cursor = target.retired_next) {
        if (w32.GetParent(target.hwnd) == hwnd) last = target;
    }
    const target = last orelse {
        if (self.constructing_drop_hwnd) |child| {
            if (w32.GetParent(child) == hwnd) {
                self.constructing_drop_parent = hwnd;
                return true;
            }
        }
        return false;
    };
    target.retired_destroy_parent = hwnd;
    return true;
}

pub fn beginDropRegistration(self: *App, hwnd: w32.HWND) void {
    std.debug.assert(self.constructing_drop_hwnd == null);
    self.constructing_drop_hwnd = hwnd;
    self.constructing_drop_destroy = false;
    self.constructing_drop_parent = null;
}

pub fn endDropRegistration(self: *App) void {
    const terminal = if (self.constructing_drop_destroy) self.constructing_drop_hwnd else null;
    const parent = self.constructing_drop_parent;
    self.constructing_drop_hwnd = null;
    self.constructing_drop_destroy = false;
    self.constructing_drop_parent = null;
    if (terminal) |hwnd| _ = w32.DestroyWindow(hwnd);
    if (parent) |hwnd| _ = w32.DestroyWindow(hwnd);
}

pub fn queueDropTargets(self: *App) void {
    if (self.drop_closing or self.drop_registration_pending) return;
    self.drop_registration_pending = true;
    if (self.msg_hwnd) |hwnd| _ = w32.PostMessageW(hwnd, WM_APP_DROP_REGISTER, 0, 0);
}

fn installDropTargets(self: *App) void {
    if (self.drop_closing or !self.drop_registration_pending) return;
    self.drop_registration_pending = false;
    var references: [64]gx.ui_ref.Reference = undefined;
    var count: usize = 0;
    for (self.core_app.surfaces.items) |surface| {
        if (!surface.drop_target_pending) continue;
        if (count == references.len) {
            self.queueDropTargets();
            break;
        }
        surface.drop_target_pending = false;
        references[count] = surface.ui_reference;
        count += 1;
    }
    // Every remote pane of the model, shown or not: a pane skipped here would
    // keep its pending flag, and `RemotePane.queueDropTarget` never queues a
    // pending pane again. `installDropTarget` itself skips hidden views.
    const quick_window: ?*Window = if (self.quick_terminal) |quick| quick.window else null;
    remotes: for (0..self.windows.items.len + 1) |slot| {
        const window = if (slot < self.windows.items.len) self.windows.items[slot] else quick_window orelse break;
        for (0..window.tab_count) |tab| {
            var panes = window.paneIterator(tab);
            while (panes.next()) |pane| {
                const remote = switch (pane.backend) {
                    .remote => |value| value,
                    .local => continue,
                };
                if (!remote.drop_target_pending) continue;
                if (count == references.len) {
                    self.queueDropTargets();
                    break :remotes;
                }
                remote.drop_target_pending = false;
                references[count] = remote.ui_reference;
                count += 1;
            }
        }
    }
    // Foreign COM may mutate the app list. Iterate owned identity values and
    // re-resolve each one, never a borrowed slice of the live surface list.
    for (references[0..count]) |reference| {
        if (self.resolveSurface(reference)) |surface| surface.installDropTarget() else if (self.resolveRemote(reference)) |remote| remote.installDropTarget();
    }
}

fn reapDropTargets(self: *App) void {
    if (self.drop_reaping or self.retired_drop_targets == null) return;
    self.drop_reaping = true;
    defer self.drop_reaping = false;
    self.drop_feedback.hide();
    while (self.retired_drop_targets) |target| {
        self.retired_drop_targets = target.retired_next;
        target.retired_next = null;
        // Keep the record alive through foreign COM and any nested close that
        // adds a deferred native destruction to the record being reaped.
        const interface = &target.interface;
        _ = interface.vtable.AddRef(interface);
        self.reaping_drop_target = target;
        const result = target.destroy();
        if (result < 0) log.warn("OLE drop revocation failed hr={x}", .{@as(u32, @bitCast(result))});
        const terminal = if (target.retired_destroy_hwnd) target.hwnd else null;
        const parent = target.retired_destroy_parent;
        self.reaping_drop_target = null;
        if (terminal) |hwnd| _ = w32.DestroyWindow(hwnd);
        if (parent) |hwnd| _ = w32.DestroyWindow(hwnd);
        _ = interface.vtable.Release(interface);
    }
}

fn dropIsLive(context: *anyopaque, attachment: gx.ui_ref.Attachment) bool {
    const self: *App = @ptrCast(@alignCast(context));
    return !self.drop_closing and !self.quit_requested and self.resolvePaneView(attachment) != null;
}

fn postDrop(context: *anyopaque, attachment: gx.ui_ref.Attachment, payload: OleDrop.data.Payload) bool {
    const self: *App = @ptrCast(@alignCast(context));
    if (self.pending_drops.items.len >= 8 or !dropIsLive(context, attachment)) return false;
    const hwnd = self.msg_hwnd orelse return false;
    self.pending_drops.append(self.core_app.alloc, .{ .attachment = attachment, .payload = payload }) catch return false;
    if (w32.PostMessageW(hwnd, WM_APP_DROP, 0, 0) == 0) {
        _ = self.pending_drops.pop();
        return false;
    }
    return true;
}

fn dropFeedback(context: *anyopaque, attachment: gx.ui_ref.Attachment, phase: OleDrop.Phase, point: w32.POINT, accepted: bool) void {
    const self: *App = @ptrCast(@alignCast(context));
    switch (phase) {
        .enter, .over => {
            const pane = self.resolvePaneView(attachment) orelse return;
            const owner = pane.ownerWindow().hwnd orelse return;
            self.drop_feedback.show(self, attachment, owner, pane.ownerWindow().scale, point, accepted);
        },
        .leave, .queued, .rejected => self.drop_feedback.hide(),
    }
}

fn onDrop(self: *App) void {
    if (self.drop_closing) return;
    while (self.pending_drops.items.len != 0) {
        var request = self.pending_drops.orderedRemove(0);
        defer request.payload.deinit();
        const pane = self.resolvePaneView(request.attachment) orelse continue;
        const quoting = switch (pane.backend) {
            .local => |surface| surface.pathQuoting(),
            .remote => |remote| remote.ui.path_quoting,
        };
        const text = request.payload.toPaste(self.core_app.alloc, quoting) catch |err| {
            log.warn("drop paste rejected err={}", .{err});
            pane.ownerWindow().showNotice(.{ .severity = .warning, .title = i18n.tr("Cannot drop here"), .body = i18n.tr("The dropped content could not be pasted safely.") }, null);
            continue;
        };
        defer self.core_app.alloc.free(text);
        if (pane.nativeHandle()) |hwnd| _ = w32.SetFocus(hwnd);
        const live = self.resolvePaneView(request.attachment) orelse continue;
        switch (live.backend) {
            .local => |surface| surface.pasteDroppedText(text),
            .remote => |remote| remote.ui.paste(remote, text, null) catch |err| log.warn("remote drop could not be accepted err={}", .{err}),
        }
    }
}

fn executeIpc(self: *App, request: IpcProtocol.Request) !IpcProtocol.Outcome {
    switch (request) {
        .toggle_quick_terminal => try self.toggleQuickTerminal(),
        .activate => {
            const window = self.targetWindow(.app) orelse return .target_gone;
            const hwnd = window.hwnd orelse return .target_gone;
            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
            _ = w32.SetForegroundWindow(hwnd);
        },
        .new_window, .new_tab => |profile| {
            if (profile.len > 0) {
                var list = try self.cachedLaunchProfiles();
                defer list.deinit();
                if (list.find(profile) == null) return .target_gone;
            }
            const create_window = request == .new_window;
            const window = if (create_window)
                try self.newWindow(.{})
            else
                self.targetWindow(.app) orelse return .target_gone;
            if (window.is_quick_terminal) return .rejected;
            if (profile.len > 0) {
                if (!self.openProfile(window, profile, .tab)) {
                    if (create_window) window.requestClose();
                    return .execution_failed;
                }
            } else {
                _ = window.addTabWithOptions(.{ .context = if (create_window) .window else .tab }) catch |err| {
                    if (create_window) window.requestClose();
                    return err;
                };
            }
        },
    }
    return .completed;
}

fn toggleQuickTerminal(self: *App) !void {
    const qt = self.quick_terminal orelse value: {
        const created = try QuickTerminal.init(self);
        self.quick_terminal = created;
        break :value created;
    };
    qt.toggle();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    if (try RemoteSource.routeAction(self, target, action, value)) |handled| return handled;
    switch (action) {
        .quit => {
            self.requestQuit();
            return true;
        },

        .new_window => {
            const font_size = switch (target) {
                .app => if (self.core_app.focusedSurface()) |surface| surface.rt_surface.inheritedFontSize(.window) else null,
                .surface => |surface| surface.rt_surface.inheritedFontSize(.window),
            };
            // Inherit opacity-toggle state from the parent window: if the
            // user toggled it to opaque via toggle_background_opacity, the
            // new window should start opaque too. Mirrors macOS behavior
            // from upstream e5c31e8b3 (#11583).
            const force_opaque: bool = switch (target) {
                .app => false,
                .surface => |cs| blk: {
                    // Per-pixel translucency toggles the configuration.
                    if (self.alpha_frames) break :blk false;
                    if (self.config.@"background-opacity" >= 1.0) break :blk false;
                    const h = cs.rt_surface.parent_window.hwnd orelse break :blk false;
                    break :blk !Backdrop.isTranslucent(h);
                },
            };

            const alloc = self.core_app.alloc;
            const window = alloc.create(Window) catch |err| {
                log.err("failed to allocate new window err={}", .{err});
                return true;
            };
            window.init(self, .{ .force_opaque = force_opaque }) catch |err| {
                log.err("failed to init new window err={}", .{err});
                alloc.destroy(window);
                return true;
            };
            self.windows.append(alloc, window) catch |err| {
                log.err("failed to track new window err={}", .{err});
                window.deinit();
                alloc.destroy(window);
                return true;
            };
            // The window context: `window-inherit-working-directory`.
            _ = window.addTabWithOptions(.{ .context = .window, .font_size = font_size }) catch |err| {
                log.err("failed to add tab to new window err={}", .{err});
                // The window never showed: the message loop destroys it,
                // which also drops it from `windows`.
                window.requestClose();
                return true;
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .ring_bell => {
            self.ringBell(switch (target) {
                .app => null,
                .surface => |core_surface| core_surface.rt_surface,
            });
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .config_change => {
            switch (target) {
                // A surface reports its own (possibly conditional) config;
                // only that surface's GUI state follows it.
                .surface => |core_surface| core_surface.rt_surface.onConfigChange(value.config),
                .app => self.updateConfig(value.config),
            }
            return true;
        },

        .toggle_fullscreen => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleFullscreen();
                },
            }
            return true;
        },

        .toggle_maximize => {
            const window = self.targetWindow(target) orelse return false;
            window.toggleMaximize();
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                // Close the entire window (all tabs), not just one tab,
                // after asking if a tab still runs a program (WM_CLOSE).
                .surface => |core_surface| core_surface.rt_surface.parent_window.requestClose(),
            }
            return true;
        },

        .open_config => {
            // `gx-open-config-ui` picks the settings UI or the file.
            if (self.config.@"gx-open-config-ui" == .settings) {
                if (self.targetWindow(target)) |window| return Settings.show(window);
            }
            return try self.openConfigFile(value);
        },

        .scrollbar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setScrollbar(value);
                },
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },

        .open_url => {
            // The core asks with the terminal locked when a link is
            // clicked; the shell opens the URL on a thread of its own.
            // Links the terminal output chose go through the link policy.
            switch (value.kind) {
                .osc8 => self.openLink(target, value.url),
                .unknown, .text, .html => open_url.open(value.url),
            }
            return true;
        },

        .mouse_over_link => {
            // Show the hovered URL in a small status bubble at the bottom
            // of the surface (cursor shape is handled by mouse_shape).
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseOverLink(value.url);
                },
            }
            return true;
        },

        .start_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.search_bar.setActive(true, value.needle);
                },
            }
            return true;
        },

        .end_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.search_bar.onSearchEnded();
                },
            }
            return true;
        },

        .search_total => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.search_bar.setTotal(value.total);
                },
            }
            return true;
        },

        .search_selected => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.search_bar.setSelected(value.selected);
                },
            }
            return true;
        },

        .desktop_notification => {
            self.showDesktopNotification(target, value);
            return true;
        },

        .new_tab => {
            const parent = self.targetWindow(target) orelse return false;
            if (parent.is_quick_terminal) return false;
            _ = parent.addTab() catch |err| {
                log.err("failed to add new tab err={}", .{err});
                return false;
            };
            return true;
        },

        .close_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // The confirmation and the close run from the message
                    // loop (`Window.closeTabMode`).
                    core_surface.rt_surface.parent_window.closeTabMode(
                        value,
                        core_surface.rt_surface,
                    );
                },
            }
            return true;
        },

        // The tab, split and window navigation actions return whether they
        // did something: the core passes the keys of `performable:`
        // bindings that did nothing on to the terminal.
        .goto_tab => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window.selectTab(value),
        },

        .set_tab_title => return switch (target) {
            .app => false,
            .surface => |core_surface| title: {
                const surface = core_surface.rt_surface;
                const window = surface.parent_window;
                const tab = window.findTabIndex(surface) orelse break :title false;
                window.setTabTitleOverride(tab, .fromUtf8(value.title));
                break :title true;
            },
        },

        .set_window_title => {
            switch (target) {
                .app => return false,
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.setWindowTitle(value.title);
                },
            }
            return true;
        },

        .move_tab => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window
                .moveTab(core_surface.rt_surface, value.amount),
        },

        .move_tab_to_new_window => {
            return switch (target) {
                .app => false,
                .surface => |core_surface| try core_surface.rt_surface.parent_window
                    .moveTabToNewWindow(core_surface.rt_surface),
            };
        },

        .toggle_tab_overview => {
            const window = self.targetWindow(target) orelse return false;
            return self.performGx(window, .tab_switcher);
        },

        .initial_size => {
            switch (target) {
                .app => {},
                // The window adds its frame and chrome to the terminal size.
                .surface => |core_surface| core_surface.rt_surface.parent_window
                    .setInitialSize(value.width, value.height),
            }
            return true;
        },

        .reload_config => {
            if (!value.soft) {
                self.reloadConfigFromDisk(target);
                return true;
            }
            // A soft reload applies the configuration again for a changed
            // conditional state (the color scheme): of one terminal, or of
            // the app and so every terminal. Each terminal asks for its
            // own, so the app is not reloaded once per terminal.
            switch (target) {
                .surface => |core_surface| core_surface.updateConfig(&self.config) catch |err| {
                    log.err("soft config reload error: {}", .{err});
                },
                .app => self.core_app.updateConfig(self, &self.config) catch |err| {
                    log.err("soft config reload error: {}", .{err});
                },
            }
            return true;
        },

        // A command that ran is left to the core, which prints "Process
        // exited" in the terminal (and closes it unless
        // `wait-after-command`). A command that failed to start is told in
        // a notice at the bottom of the window, which blocks nothing.
        .show_child_exited => return switch (target) {
            .app => false,
            .surface => |core_surface| switch (childExitKind(
                value,
                core_surface.config.abnormal_command_exit_runtime_ms,
            )) {
                .normal => false,
                .abnormal => showChildExited(core_surface.rt_surface, value.exit_code),
            },
        },

        .toggle_window_decorations => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleWindowDecorations();
                },
            }
            return true;
        },

        .close_all_windows => {
            // Closing every window quits; ask like quit does.
            self.requestQuit();
            return true;
        },

        .toggle_background_opacity => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (self.alpha_frames) {
                        self.toggleBackgroundOpaque();
                    } else if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        Backdrop.toggleOpacity(h, self.config.@"background-opacity");
                    }
                },
            }
            return true;
        },

        .goto_window => return self.gotoWindow(target, value),

        .resize_window => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window
                .resizeForSurface(core_surface.rt_surface, value),
        },

        .reset_window_size => {
            switch (target) {
                .app => {},
                // Back to the window-width/-height size, or the default.
                .surface => |core_surface| core_surface.rt_surface.parent_window.resetWindowSize(),
            }
            return true;
        },

        .copy_title_to_clipboard => return switch (target) {
            .app => false,
            .surface => |core_surface| self.copyTitle(core_surface.rt_surface),
        },

        .export_terminal_io => return self.exportTerminalIo(target, value.contents),

        // The renderer presents directly to the surface window.
        .render => return true,

        // The leader keys typed so far, the active key table and read-only
        // mode show at the bottom of the window.
        .key_sequence => {
            switch (target) {
                .app => {},
                .surface => |core_surface| showKeySequence(core_surface.rt_surface, value),
            }
            return true;
        },

        .key_table => {
            switch (target) {
                .app => {},
                .surface => |core_surface| showKeyTable(core_surface.rt_surface, value),
            }
            return true;
        },

        .readonly => {
            switch (target) {
                .app => {},
                .surface => |core_surface| showReadonly(core_surface.rt_surface.parent_window, value),
            }
            return true;
        },

        .pwd,
        .cell_size,
        => {
            if (target == .surface and !target.surface.rt_surface.parent_window.is_quick_terminal) self.scheduleSessionSave();
            return true;
        },
        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        // Platform-specific actions that don't apply on Windows:
        .secure_input, // macOS EnableSecureEventInput
        .undo, // macOS NSUndoManager
        .redo, // macOS NSUndoManager
        .show_gtk_inspector, // GTK-only
        .show_on_screen_keyboard, // GTK/mobile
        .inspector, // Not yet implemented (debug overlay)
        .render_inspector, // Not yet implemented (debug overlay)
        => return true,

        .renderer_health => {
            // Surface a warning when the GPU renderer degrades so a frozen
            // display is explainable (macOS shows an in-window message).
            switch (value) {
                .healthy => {},
                .unhealthy => {
                    self.notif_desktop_reference = .{};
                    _ = self.showDesktopNotificationText(
                        i18n.tr("Renderer Unhealthy"),
                        i18n.tr("The GPU renderer is in an unhealthy state; terminal output may stop updating."),
                    );
                },
            }
            return true;
        },

        .progress_report => {
            // Shell and TUI progress (OSC 9;4): the terminal's tab keeps it
            // and the window's taskbar button shows what all its terminals
            // report, the Windows equivalent of the macOS Dock progress.
            // Gated on progress-style.
            if (!self.config.@"progress-style") return true;
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const window = core_surface.rt_surface.parent_window;
                    window.setSurfaceProgress(core_surface.rt_surface, value);
                    self.updateTaskbarProgress(window);
                },
            }
            return true;
        },

        .color_change => {
            if (value.kind != .background) return true;
            switch (target) {
                .app => {},
                .surface => |core_surface| core_surface.rt_surface.setEraseColor(.{ .r = value.r, .g = value.g, .b = value.b }),
            }
            return true;
        },

        .size_limit => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    win.min_track_w = @intCast(value.min_width);
                    win.min_track_h = @intCast(value.min_height);
                    win.max_track_w = @intCast(value.max_width);
                    win.max_track_h = @intCast(value.max_height);
                },
            }
            return true;
        },

        .toggle_visibility => {
            self.toggleVisibility();
            return true;
        },

        .float_window => {
            // Toggle WS_EX_TOPMOST so the window stays above non-topmost
            // windows. Equivalent to macOS NSWindow.level = .floating.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return true;
                    const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
                    const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
                    const want: bool = switch (value) {
                        .on => true,
                        .off => false,
                        .toggle => !is_topmost,
                    };
                    if (want == is_topmost) return true;
                    const insert_after = if (want) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
                    _ = w32.SetWindowPos(
                        win_hwnd,
                        insert_after,
                        0,
                        0,
                        0,
                        0,
                        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
                    );
                },
            }
            return true;
        },

        .command_finished => {
            // The core emits this for every finished command; all gating is
            // apprt-side (config notify-on-command-finish*), matching the
            // GTK and macOS runtimes.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    switch (self.config.@"notify-on-command-finish") {
                        .never => return true,
                        .unfocused => if (core_surface.focused) return true,
                        .always => {},
                    }
                    if (value.duration.lte(self.config.@"notify-on-command-finish-after"))
                        return true;

                    const act = self.config.@"notify-on-command-finish-action";
                    // The bell as `bell-features` has it.
                    if (act.bell) self.ringBell(core_surface.rt_surface);
                    if (act.notify) {
                        const title: []const u8 = if (value.exit_code) |code|
                            (if (code == 0) i18n.tr("Command succeeded") else i18n.tr("Command failed"))
                        else
                            i18n.tr("Command finished");
                        var duration_buf: [32]u8 = undefined;
                        const duration = std.fmt.bufPrint(
                            &duration_buf,
                            "{f}",
                            .{value.duration.round(std.time.ns_per_ms)},
                        ) catch "";
                        var body_buf: [256]u8 = undefined;
                        var body: std.Io.Writer = .fixed(&body_buf);
                        if (value.exit_code) |code| {
                            i18n.format(&body, i18n.tr("Command took {duration} and exited with code {code}."), .{
                                .duration = duration,
                                .code = code,
                            }) catch {};
                        } else {
                            i18n.format(&body, i18n.tr("Command took {duration}."), .{
                                .duration = duration,
                            }) catch {};
                        }
                        self.notif_desktop_reference = core_surface.rt_surface.ui_reference;
                        _ = self.showDesktopNotificationText(title, body.buffered());
                    }
                },
            }
            return true;
        },

        .mouse_visibility => {
            switch (target) {
                .app => {},
                .surface => |core_surface| core_surface.rt_surface.setMouseVisibility(value == .visible),
            }
            return true;
        },

        .present_terminal => {
            switch (target) {
                .app => {},
                .surface => |core_surface| self.presentSurface(core_surface.rt_surface),
            }
            return true;
        },

        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const dir: SplitTree(Leaf).Split.Direction = switch (value) {
                        .left => .left,
                        .right => .right,
                        .up => .up,
                        .down => .down,
                    };
                    core_surface.rt_surface.parent_window.newSplit(dir) catch |err| {
                        log.err("failed to create split: {}", .{err});
                    };
                },
            }
            return true;
        },

        .goto_split => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window
                .gotoSplit(core_surface.rt_surface, value),
        },

        .resize_split => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window
                .resizeSplit(core_surface.rt_surface, value),
        },

        .equalize_splits => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window
                .equalizeSplits(core_surface.rt_surface),
        },

        .toggle_split_zoom => return switch (target) {
            .app => false,
            .surface => |core_surface| core_surface.rt_surface.parent_window
                .toggleSplitZoom(core_surface.rt_surface),
        },

        .prompt_title => {
            return switch (target) {
                .app => false,
                .surface => |core_surface| blk: {
                    const window = core_surface.rt_surface.parent_window;
                    switch (value) {
                        .surface, .tab => window.tab_bar.startRename(window.active_tab),
                        .window => window.tab_bar.startWindowRename(),
                    }
                    break :blk true;
                },
            };
        },

        // There is no update mechanism yet.
        .check_for_updates => return false,

        .toggle_command_palette => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const palette = &core_surface.rt_surface.parent_window.palette;
                    palette.setActive(!palette.active);
                },
            }
            return true;
        },

        .toggle_quick_terminal => {
            try self.toggleQuickTerminal();
            return true;
        },

        .selection_changed => {
            // Win32 has no primary-selection clipboard to keep in sync (that
            // is an X11/Wayland concept), so there is nothing to do when the
            // core selection changes. Acknowledge the notification, mirroring
            // the GTK apprt which also treats selection_changed as a no-op.
            return true;
        },

        // All 66 apprt actions are now handled above.
    }
}

/// Perform a Ghostty GX binding action (`gx:<name>` in `keybind` and
/// `command-palette-entry`). The core surface calls this for the `gx`
/// binding action (fork patch GX-0014). Returns whether the action was
/// performed.
pub fn gxAction(self: *App, target: apprt.Target, action: gx.action.Action) !bool {
    const window = self.targetWindow(target) orelse {
        log.info("no window for GX action action=gx:{f}", .{action});
        return false;
    };
    return self.performGx(window, action);
}

/// Perform a GX action for `window`. Menus and buttons call this directly.
/// The main menu opens after the current message has been handled.
pub fn performGx(self: *App, window: *Window, action: gx.action.Action) bool {
    return switch (action) {
        .settings => Settings.show(window),
        .main_menu => window.queueMainMenu(null),
        .keybinds => Keybinds.show(window),
        .new_tab_profile => |id| self.openProfile(window, id, .tab),
        .new_window_profile => |id| self.openProfile(window, id, .window),
        .new_tab_menu => self.deferGx(.new_tab_menu, window),
        .context_menu => self.deferGx(.context_menu, window),
        .settings_page => |page| Settings.showSection(window, switch (page) {
            .language => .language,
            .appearance => .appearance,
            .font => .font,
            .interaction => .interaction,
            .shell => .shell,
            .about => .about,
        }),
        .move_split_to_tab => moved: {
            const surface = window.activeLeaf() orelse break :moved false;
            break :moved window.moveSplitToTab(surface) catch |err| {
                log.warn("cannot move split to tab err={}", .{err});
                break :moved false;
            };
        },
        .move_split_to_window => moved: {
            const surface = window.activeLeaf() orelse break :moved false;
            break :moved window.moveSplitToNewWindow(surface) catch |err| {
                log.warn("cannot move split to window err={}", .{err});
                break :moved false;
            };
        },
        .tab_switcher => tabs: {
            if (window.activeLeaf() == null) break :tabs false;
            window.palette.toggle(.tabs);
            break :tabs true;
        },
    };
}

/// A GX action that opens a menu (`WM_APP_DEFERRED_GX`).
const DeferredGx = enum(usize) {
    /// The launch profile menu of the new tab button.
    new_tab_menu,
    /// The terminal's context menu, at its cursor.
    context_menu,
};

/// Open the menu of `kind` for the focused terminal of `window` once the
/// message loop is back: a menu runs a modal loop, which must not run in
/// the key binding that asks for it. Returns false if it cannot.
fn deferGx(self: *App, kind: DeferredGx, window: *Window) bool {
    const hwnd = self.msg_hwnd orelse return false;
    if (window.closing) return false;
    if (window.activePane() == null) return false;
    return w32.PostMessageW(hwnd, WM_APP_DEFERRED_GX, @intFromEnum(kind), @bitCast(window.ui_reference.id)) != 0;
}

/// Handle `WM_APP_DEFERRED_GX` (`deferGx`), if the terminal is still there.
fn onDeferredGx(self: *App, wparam: usize, lparam: isize) void {
    const kind = std.enums.fromInt(DeferredGx, wparam) orelse return;
    const id: u64 = @bitCast(lparam);
    const window = for (self.windows.items) |candidate| {
        if (candidate.ui_reference.id == id and !candidate.closing) break candidate;
    } else if (self.quick_terminal) |quick| quick.window else return;
    if (window.closing or window.ui_reference.id != id) return;
    switch (kind) {
        .new_tab_menu => Menu.showNewTabMenu(window),
        .context_menu => Menu.showPaneContextMenuAtCursor(window.activePane() orelse return),
    }
}

/// The window an action applies to: the surface's window, or for app
/// targets the foreground window, else the most recently opened one.
fn targetWindow(self: *App, target: apprt.Target) ?*Window {
    switch (target) {
        .surface => |core_surface| return core_surface.rt_surface.parent_window,
        .app => {
            const foreground = if (w32.GetForegroundWindow()) |hwnd| GetAncestor(hwnd, 3) else null;
            for (self.windows.items) |window| {
                if (window.hwnd != null and window.hwnd == foreground) return window;
            }
            if (self.quick_terminal) |qt| {
                if (qt.window.hwnd != null and qt.window.hwnd == foreground) return qt.window;
            }
            if (self.windows.items.len > 0) return self.windows.items[self.windows.items.len - 1];
            return if (self.quick_terminal) |qt| qt.window else null;
        },
    }
}

extern "user32" fn GetAncestor(hwnd: w32.HWND, flags: u32) callconv(.winapi) ?w32.HWND;

/// `goto_window`: bring the next (or previous) visible window after the
/// window of `target` to the front, wrapping around. Returns false when
/// there is no other window, so that the key reaches the terminal.
fn gotoWindow(self: *App, target: apprt.Target, direction: apprt.action.GotoWindow) bool {
    const windows = self.windows.items;
    if (windows.len < 2) return false;
    const current = self.targetWindow(target) orelse return false;
    var index = std.mem.indexOfScalar(*Window, windows, current) orelse return false;
    for (1..windows.len) |_| {
        index = tabs.cycleIndex(index, windows.len, direction == .next);
        const window = windows[index];
        if (window.closing) continue;
        const hwnd = window.hwnd orelse continue;
        if (w32.IsWindowVisible_(hwnd) == 0) continue;
        if (IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        _ = w32.SetForegroundWindow(hwnd);
        window.focusActiveSurface();
        return true;
    }
    return false;
}

/// The window of the core surface `id`, if it still exists.
fn windowOfSurface(self: *App, id: u64) ?*Window {
    if (id == 0) return null;
    const core_surface = self.core_app.findSurfaceByID(id) orelse return null;
    return core_surface.rt_surface.parent_window;
}

/// Whether `hwnd` is on screen: visible and not minimized.
fn onScreen(hwnd: w32.HWND) bool {
    return w32.IsWindowVisible_(hwnd) != 0 and w32.IsIconic(hwnd) == 0;
}

/// `toggle_visibility`: hide every window, or when none is on screen (a
/// minimized window counts as hidden) show them all again, each in its
/// size and state (a maximized one stays maximized), and bring back to the
/// front the one that was in front. Hidden windows stop rendering. The
/// quick terminal toggles on its own (`toggle_quick_terminal`).
fn toggleVisibility(self: *App) void {
    const any_shown = for (self.windows.items) |window| {
        const hwnd = window.hwnd orelse continue;
        if (onScreen(hwnd)) break true;
    } else false;

    if (any_shown) {
        const front = self.targetWindow(.app);
        self.hidden_front = if (front) |window| window.hwnd else null;
        for (self.windows.items) |window| {
            const hwnd = window.hwnd orelse continue;
            window.setActiveTabVisible(false);
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
        return;
    }

    var front: ?*Window = null;
    for (self.windows.items) |window| {
        const hwnd = window.hwnd orelse continue;
        if (window.closing) continue;
        if (w32.IsWindowVisible_(hwnd) == 0) _ = w32.ShowWindow(hwnd, SW_SHOWNA);
        if (w32.IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        window.setActiveTabVisible(true);
        if (front == null or hwnd == self.hidden_front) front = window;
    }
    self.hidden_front = null;
    const window = front orelse return;
    if (window.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
    window.focusActiveSurface();
}

/// `present_terminal`: bring `surface` to the user (`presentReference`).
fn presentSurface(self: *App, surface: *Surface) void {
    _ = self.presentReference(surface.ui_reference);
}

/// Bring the pane or window `reference` names to the user, for
/// `present_terminal` and a click on a desktop notification (tray balloon or
/// toast). Its window comes back from hidden or minimized (the quick terminal
/// slides in) to the front without leaving a maximized state, with the
/// pane's tab selected and the pane focused. Showing and activating dispatch
/// messages, so every step resolves the reference again. Returns false when
/// nothing it names is left.
pub fn presentReference(self: *App, reference: gx.ui_ref.Reference) bool {
    if (self.resolveLeaf(reference)) |leaf| {
        self.presentWindow(leaf.ownerWindow());
        const shown = self.resolveLeaf(reference) orelse return true;
        const window = shown.ownerWindow();
        if (window.findTabIndex(shown)) |index| {
            if (index != window.active_tab) window.selectTabIndex(index);
        }
        const live = self.resolveLeaf(reference) orelse return true;
        _ = live.ownerWindow().setActiveSurface(live);
        live.pane().focus();
        return true;
    }
    if (self.resolveSurface(reference)) |surface| {
        // An exported terminal in a hidden remote host: `RemoteSource`
        // forwards the request to the view that shows it.
        if (surface.remote_source_state == null) return false;
        _ = self.performAction(.{ .surface = &surface.core_surface }, .present_terminal, {}) catch return false;
        return true;
    }
    const window = self.resolveWindow(reference) orelse return false;
    if (window.is_remote_host) return false;
    self.presentWindow(window);
    if (self.resolveWindow(reference)) |live| live.focusActiveSurface();
    return true;
}

/// Show `window` and bring it to the front: back from hidden with its active
/// tab visible again, or from minimized (SW_RESTORE would also un-maximize,
/// so only then); the quick terminal slides in.
fn presentWindow(self: *App, window: *Window) void {
    if (window.closing or window.is_remote_host) return;
    const reference = window.ui_reference;
    const hwnd = window.hwnd orelse return;
    if (window.is_quick_terminal) {
        const qt = self.quick_terminal orelse return;
        if (qt.window != window) return;
        qt.present();
    } else {
        if (w32.IsWindowVisible_(hwnd) == 0) {
            _ = w32.ShowWindow(hwnd, SW_SHOWNA);
            const live = self.resolveWindow(reference) orelse return;
            live.setActiveTabVisible(true);
        }
        if (w32.IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
    }
    _ = w32.SetForegroundWindow(hwnd);
}

/// Whether the pointer is over the window `hwnd` itself (not a window in
/// front of it).
fn pointerOver(hwnd: ?w32.HWND) bool {
    const target = hwnd orelse return false;
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return false;
    return WindowFromPoint(pt) == target;
}

/// Posted to `msg_hwnd` by `openLink`; lparam is a `LinkRequest`.
const WM_APP_OPEN_LINK: u32 = w32.WM_APP + 34;

/// A link the link policy holds back, waiting for the message loop to ask
/// about it or to tell why it stays closed (`onLinkRequest`).
const LinkRequest = struct {
    /// Stable lifetime identity, or null for an explicit application target.
    surface_ref: ?gx.ui_ref.Reference,
    decision: gx.url_policy.Decision,
    url: []u8,

    fn destroy(self: *LinkRequest, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.destroy(self);
    }
};

/// Open a link that terminal output chose (OSC 8) as `gx.url_policy`
/// decides: web and mail links right away; files on this or another
/// computer and the applications of other schemes once the user agrees;
/// nothing that can run code. The core asks with the terminal locked, so
/// the question and the refusal wait for the message loop
/// (`WM_APP_OPEN_LINK`).
fn openLink(self: *App, target: apprt.Target, url: []const u8) void {
    var name_buf: [host_name_size]u8 = undefined;
    const decision = gx.url_policy.decide(url, .{ .host_name = hostName(&name_buf) });
    if (decision == .allow) return open_url.open(url);
    log.info("link held back decision={t} len={}", .{ decision, url.len });

    const hwnd = self.msg_hwnd orelse return;
    const alloc = self.core_app.alloc;
    const request = alloc.create(LinkRequest) catch return;
    request.* = .{
        .surface_ref = switch (target) {
            .app => null,
            .surface => |core_surface| core_surface.rt_surface.ui_reference,
        },
        .decision = decision,
        .url = alloc.dupe(u8, url) catch {
            alloc.destroy(request);
            return;
        },
    };
    if (w32.PostMessageW(hwnd, WM_APP_OPEN_LINK, 0, @bitCast(@intFromPtr(request))) == 0) {
        request.destroy(alloc);
    }
}

/// Handle `WM_APP_OPEN_LINK`: ask before opening the link, or tell in a
/// notice why it is not opened, in the window of the terminal that showed
/// it. Frees the request.
fn onLinkRequest(self: *App, request: *LinkRequest) void {
    const alloc = self.core_app.alloc;
    defer request.destroy(alloc);
    const window = if (request.surface_ref) |reference|
        (self.resolveSurface(reference) orelse return).parent_window
    else
        self.targetWindow(.app);

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    switch (request.decision) {
        .allow => return open_url.open(request.url),
        .confirm => |reason| {
            const scheme = gx.url_policy.scheme(request.url) orelse "";
            i18n.format(&body.writer, i18n.trRuntime(reason.msgid()), .{ .scheme = scheme }) catch return;
            body.writer.writeAll("\n\n") catch return;
            gx.url_policy.writeDisplay(&body.writer, request.url) catch return;
            const owner = if (window) |w| w.hwnd else null;
            // A modal loop: nothing here uses the window after it.
            if (Dialogs.confirm(owner, body.written(), i18n.tr(gx.url_policy.msg.confirm_title)) != .accept) return;
            if (request.surface_ref) |reference| {
                if (self.resolveSurface(reference) == null) return;
            }
            var name_buf: [host_name_size]u8 = undefined;
            const path = gx.url_policy.filePath(alloc, request.url, .{ .host_name = hostName(&name_buf) }) catch null;
            defer if (path) |p| alloc.free(p);
            // A `file:` URL opens as the path it names.
            open_url.open(path orelse request.url);
        },
        .deny => |reason| {
            const w = window orelse return;
            body.writer.writeAll(i18n.trRuntime(reason.msgid())) catch return;
            body.writer.writeAll("\n") catch return;
            gx.url_policy.writeDisplay(&body.writer, request.url) catch return;
            w.showNotice(.{
                .severity = .warning,
                .title = i18n.tr(gx.url_policy.msg.denied_title),
                .body = body.written(),
            }, null);
        },
    }
}

/// Room for `hostName` (a DNS host name in UTF-8).
const host_name_size = 3 * 64;

/// The DNS host name of this computer, which `file:` URLs may name for a
/// local file (`ls --hyperlink` does); "" when unknown.
fn hostName(buf: *[host_name_size]u8) []const u8 {
    var wide: [64]u16 = undefined;
    var len: u32 = wide.len;
    if (GetComputerNameExW(COMPUTER_NAME_DNS_HOSTNAME, &wide, &len) == 0) return "";
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..@min(len, wide.len)]) catch return "";
    return buf[0..n];
}

const COMPUTER_NAME_DNS_HOSTNAME: c_int = 1;
const SW_SHOWNA: i32 = 8;
extern "kernel32" fn GetComputerNameExW(name_type: c_int, buffer: [*]u16, size: *u32) callconv(.winapi) i32;
extern "user32" fn WindowFromPoint(point: w32.POINT) callconv(.winapi) ?w32.HWND;

/// Create and track a top-level window without tabs. It is shown with its
/// first tab (`Window.addTab*`).
pub fn newWindow(self: *App, options: Window.InitOptions) !*Window {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, options);
    errdefer window.deinit();
    try self.windows.append(alloc, window);
    return window;
}

/// The launch profiles: the shells detected on this system followed by the
/// `gx-launch-profile` entries. The caller owns the list (`deinit`). This
/// probes the file system on every call; `cachedLaunchProfiles` does not.
pub fn launchProfiles(self: *App) !gx.profiles.List {
    const alloc = self.core_app.alloc;
    const custom = try self.customProfiles(alloc);
    defer alloc.free(custom);

    var env = try global.environMap();
    defer env.deinit();
    return try gx.profiles.detectSystem(alloc, global.io(), &env, custom);
}

/// `launchProfiles` with the detected shells kept in `profiles_cache`:
/// detected again when the environment variables detection reads change or
/// after `profiles_cache.invalidate()`. GUI thread. The caller owns the
/// list (`deinit`).
pub fn cachedLaunchProfiles(self: *App) !gx.profiles.List {
    const alloc = self.core_app.alloc;
    const custom = try self.customProfiles(alloc);
    defer alloc.free(custom);

    var env = try global.environMap();
    defer env.deinit();
    return try self.profiles_cache.list(alloc, global.io(), &env, custom);
}

/// The `gx-launch-profile` entries, allocated with `alloc` (the strings
/// stay in the configuration).
fn customProfiles(self: *const App, alloc: Allocator) ![]gx.profiles.Custom {
    const map = &self.config.@"gx-launch-profile".map;
    const custom = try alloc.alloc(gx.profiles.Custom, map.count());
    for (map.keys(), map.values(), custom) |name, command, *entry| {
        entry.* = .{ .name = name, .command = command };
    }
    return custom;
}

/// The process table the tab labels and herdr app mode of every window
/// share (`gx.proc.Shared`), captured anew when it is older than its TTL
/// (one second). GUI thread; valid until the next call. Close
/// confirmations read a table of their own (`gx.confirm.Scope`).
pub fn processTable(self: *App) gx.proc.SnapshotError!*gx.proc.Table {
    return self.proc_shared.get(self.core_app.alloc, global.io());
}

pub const ProfileTarget = enum { tab, window };

/// Open the launch profile `id` (`gx.profiles.Profile.id`, e.g. `pwsh` or
/// `wsl:Ubuntu`; a bare `gx-launch-profile` name also finds `custom:<name>`)
/// in a new tab of `window` or in a new window. Returns false, after
/// logging why, when there is no such profile or the terminal could not
/// be created.
pub fn openProfile(self: *App, window: *Window, id: []const u8, where: ProfileTarget) bool {
    if (where == .tab and window.is_quick_terminal) return false;
    var list = self.cachedLaunchProfiles() catch |err| {
        log.err("launch profile detection failed err={}", .{err});
        return false;
    };
    defer list.deinit();
    const profile = list.resolve(id) orelse {
        log.warn("no launch profile with id={s}", .{id});
        return false;
    };

    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const command: configpkg.Command = switch (profile.command) {
        .argv => |argv| .{ .direct = argv },
        .command_line => |line| parsed: {
            var parsed: configpkg.Command = undefined;
            parsed.parseCLI(arena.allocator(), line) catch |err| {
                log.warn("invalid launch profile command id={s} err={}", .{ profile.id, err });
                return false;
            };
            break :parsed parsed;
        },
    };

    const context: apprt.surface.NewSurfaceContext = switch (where) {
        .tab => .tab,
        .window => .window,
    };
    const font_size = if (window.getActiveSurface()) |surface| surface.inheritedFontSize(context) else null;
    const destination = switch (where) {
        .tab => window,
        .window => self.newWindow(.{}) catch |err| {
            log.err("failed to create a window for launch profile id={s} err={}", .{ profile.id, err });
            return false;
        },
    };
    _ = destination.addTabWithOptions(.{
        .context = context,
        .font_size = font_size,
        .command = &command,
        .profile_id = profile.id,
    }) catch |err| {
        log.err("failed to open launch profile id={s} err={}", .{ profile.id, err });
        if (where == .window) destination.close();
        return false;
    };
    return true;
}

/// The command new terminals run unless a launch profile or `-e` passes
/// their own: the default launch profile's (`default_command`) when
/// `command` is not configured, else `command`. The menus and the settings
/// show it as the current default.
pub fn defaultTerminalCommand(self: *const App) ?configpkg.Command {
    return self.default_command orelse self.config.command;
}

/// Pick the command of new terminals (first window, tabs, splits and
/// windows) for when `command` is not configured on the command line, in
/// a configuration file or by the settings: the default launch profile,
/// i.e. GX Zsh, then PowerShell 7, Windows PowerShell and Command Prompt
/// (`gx.profiles.defaultProfile`). `-e` still runs its command in the
/// first terminal, and launch profiles pass their own command.
fn updateDefaultCommand(self: *App) void {
    self.default_command_stale = false;
    self.default_command = null;
    self.default_profile_id = null;
    _ = self.default_command_arena.reset(.free_all);
    if (gx.profiles.commandConfigured(self.config._replay_steps.items)) return;

    var list = self.cachedLaunchProfiles() catch |err| {
        log.warn("cannot detect the default shell err={}", .{err});
        return;
    };
    defer list.deinit();
    const profile = gx.profiles.defaultProfile(list.profiles, .native) orelse {
        log.info("no default shell detected, new terminals run the command default", .{});
        return;
    };

    const alloc = self.default_command_arena.allocator();
    self.default_command = switch (profile.command) {
        .argv => |argv| (configpkg.Command{ .direct = argv }).clone(alloc),
        .command_line => |line| parsed: {
            var parsed: configpkg.Command = undefined;
            parsed.parseCLI(alloc, line) catch |err| {
                log.warn("invalid default shell command id={s} err={}", .{ profile.id, err });
                return;
            };
            break :parsed parsed;
        },
    } catch |err| {
        log.warn("cannot keep the default shell command err={}", .{err});
        return;
    };
    self.default_profile_id = alloc.dupe(u8, profile.id) catch null;
    log.info("default shell profile={s}", .{profile.id});
}

/// Repair a `working-directory` path that lost its trailing backslash to
/// the Windows command-line quoting rules (`restoreTrailingBackslash`):
/// Explorer's "open here" passes `--working-directory="%V"`, which is
/// `"C:\"` for a drive root. A path that still has characters Windows
/// paths cannot contain is dropped (terminals then start in the directory
/// Ghostty GX was started in): the file APIs treat such names as a
/// programming error and terminate the process.
fn repairWorkingDirectory(config: *Config) void {
    var path = switch (config.@"working-directory" orelse return) {
        .path => |path| path,
        .home, .inherit => return,
    };
    if (restoreTrailingBackslash(config.arenaAlloc(), path) catch null) |repaired| {
        log.info("repaired working-directory from={s} to={s}", .{ path, repaired });
        config.@"working-directory" = .{ .path = repaired };
        path = repaired;
    }
    if (!validWindowsPath(path)) {
        log.warn("working-directory is not a valid Windows path, ignoring it path={s}", .{path});
        config.@"working-directory" = .inherit;
    }
}

/// Whether `path` has none of the characters that Windows file names
/// cannot contain (`"<>|*` and control characters). `?` and `:` are left
/// to the file APIs: they appear in `\\?\` and drive prefixes.
fn validWindowsPath(path: []const u8) bool {
    for (path) |c| switch (c) {
        0...0x1F, '"', '<', '>', '|', '*' => return false,
        else => {},
    };
    return true;
}

/// In a Windows command line `\"` is an escaped quote, so the argument
/// `"C:\"` reaches the program as `C:"`. Windows paths cannot contain a
/// double quote, so trailing quotes stand for the swallowed backslash.
/// Returns the path with them replaced by one backslash, or null if the
/// path does not end in a quote.
fn restoreTrailingBackslash(alloc: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "\"");
    if (trimmed.len == path.len or trimmed.len == 0) return null;
    if (std.mem.endsWith(u8, trimmed, "\\") or std.mem.endsWith(u8, trimmed, "/")) {
        return try alloc.dupe(u8, trimmed);
    }
    return try std.mem.concat(alloc, u8, &.{ trimmed, "\\" });
}

/// Open the configuration file: `.os_open` with the Windows file
/// association; `.new_window` in a new window running $VISUAL or $EDITOR,
/// else with the file association. Returns whether it is being opened.
pub fn openConfigFile(self: *App, mode: apprt.action.OpenConfig) !bool {
    const config_path = configpkg.edit.openPath(
        self.core_app.alloc,
    ) catch |err| {
        log.err("failed to get config path: {}", .{err});
        return false;
    };
    defer self.core_app.alloc.free(config_path);

    return switch (mode) {
        .os_open => openConfigWithOs(config_path),
        .new_window => (try self.openConfigInNewWindow(config_path)) or
            openConfigWithOs(config_path),
    };
}

/// Replace the app config after a reload and refresh the app-wide GUI
/// state that depends on it. Every theme preview step and conditional
/// reload comes here, so only what depends on a changed value is redone:
/// the default shell, the global hotkeys and the shortcut probe, the
/// background brush.
fn updateConfig(self: *App, config: *const Config) void {
    const new_config = config.clone(self.core_app.alloc) catch |err| {
        log.err("error updating app config err={}", .{err});
        return;
    };
    var old = self.config;
    defer old.deinit();
    self.config = new_config;
    if (old.changed(&self.config, .@"gx-launch-profile") or old.changed(&self.config, .language)) self.shell.jump_list_dirty = true;
    repairWorkingDirectory(&self.config);
    if (old.changed(&self.config, .@"bell-audio-path") or
        old.changed(&self.config, .@"bell-audio-volume") or
        old.changed(&self.config, .@"bell-features"))
    {
        if (self.bell_audio) |player| player.invalidate();
    }

    if (self.default_command_stale or
        old.changed(&self.config, .command) or
        old.changed(&self.config, .@"gx-launch-profile") or
        gx.profiles.commandConfigured(old._replay_steps.items) !=
            gx.profiles.commandConfigured(self.config._replay_steps.items))
    {
        self.updateDefaultCommand();
    }

    const language = i18n.resolve(self.config.language);
    if (language != i18n.current()) {
        i18n.setCurrent(language);
        if (self.ui_factory) |factory| factory.flushFormats();
        for (self.windows.items) |w| w.onLanguageChanged();
        if (self.quick_terminal) |qt| qt.window.onLanguageChanged();
    }

    if (old.changed(&self.config, .background)) {
        if (self.bg_brush) |old_brush| _ = w32.DeleteObject(@ptrCast(old_brush));
        const bg = self.config.background;
        self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));
    }

    for (self.windows.items) |w| w.onConfigChange();

    if (old.changed(&self.config, .keybind)) {
        self.unregisterGlobalHotkeys();
        self.shortcut_conflicts.deinit(self.core_app.alloc);
        self.registerGlobalHotkey();
        self.scheduleShortcutProbe();
    }

    if (self.quick_terminal) |qt| qt.onConfigChange(&self.config);
    if (old.changed(&self.config, .@"progress-style")) self.onProgressTimer();

    self.reportConfigDiagnostics(.post);
    Settings.onConfigChange(self);
}

/// `reload_config`: read the configuration files again and apply them, then
/// say in the window that asked how it went: the configuration errors, if
/// there are any (`reportConfigDiagnostics`), else a short confirmation
/// (`app-notifications = config-reload`). The shells are detected again, so
/// one installed in the meantime shows up in the launch profiles and can be
/// the default now. From a core callback: the feedback is posted.
fn reloadConfigFromDisk(self: *App, target: apprt.Target) void {
    const alloc = self.core_app.alloc;
    self.profiles_cache.invalidate();
    self.default_command_stale = true;
    var new_config = loadConfig(alloc) catch |err| {
        log.err("failed to reload config: {}", .{err});
        const window = self.targetWindow(target) orelse return;
        var buf: [256]u8 = undefined;
        var title: std.Io.Writer = .fixed(&buf);
        i18n.format(&title, i18n.tr("Could not reload the configuration: {reason}"), .{
            .reason = i18n.trRuntime(gx.settings_map.errorReason(err)),
        }) catch {};
        window.postNotice(.{ .severity = .@"error", .title = title.buffered() }, null);
        return;
    };
    defer new_config.deinit();
    self.applyConfig(&new_config) catch |err| {
        log.err("config update error: {}", .{err});
        return;
    };
    // The errors are in a notice already.
    if (self.diagnostics_reported != 0) return;
    if (!self.config.@"app-notifications".@"config-reload") return;
    const window = self.targetWindow(target) orelse return;
    window.postToast(.{ .text = i18n.tr("Reloaded the configuration"), .icon = d2d.icons.check_mark, .duration_ms = 2000 });
}

/// `toggle_background_opacity` with per-pixel translucency: every window
/// switches between the configured `background-opacity` and an opaque
/// background, as on macOS. The renderers draw the opacity, so the switch
/// is a configuration input the core hands to every surface (and that
/// theme and conditional reloads replay).
fn toggleBackgroundOpaque(self: *App) void {
    const restore = self.opaque_restore;
    if (restore == null and self.config.@"background-opacity" >= 1.0) return;
    var config = self.config.clone(self.core_app.alloc) catch |err| {
        log.err("error toggling the background opacity err={}", .{err});
        return;
    };
    defer config.deinit();
    if (restore) |opacity| {
        self.opaque_restore = null;
        self.setBackgroundOpacity(&config, opacity);
    } else {
        self.holdOpaque(&config);
    }
    self.core_app.updateConfig(self, &config) catch |err| {
        log.err("config update error: {}", .{err});
    };
}

/// Apply a configuration loaded anew (`reload_config`, the settings, a
/// theme preview) to the app and every surface. While
/// `toggle_background_opacity` holds the terminals opaque they stay so,
/// and the new `background-opacity` is what the next toggle restores.
/// Not for re-applying `config` itself, which is already held opaque.
pub fn applyConfig(self: *App, config: *Config) !void {
    if (self.opaque_restore != null) self.holdOpaque(config);
    try self.core_app.updateConfig(self, config);
}

/// Make `config` opaque while `toggle_background_opacity` holds the
/// terminals opaque, remembering its opacity for the next toggle.
fn holdOpaque(self: *App, config: *Config) void {
    self.opaque_restore = config.@"background-opacity";
    self.setBackgroundOpacity(config, 1.0);
}

fn setBackgroundOpacity(self: *App, config: *Config, opacity: f64) void {
    var buf: [64]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&buf, "--background-opacity={d}", .{opacity}) catch return;
    gx.config_layers.applyArg(config, self.core_app.alloc, arg) catch |err| {
        log.err("error setting the background opacity err={}", .{err});
    };
}

/// Open the configuration with the Windows file association, or the "Open
/// with" dialog or Notepad when `.ghostty` files have none, on a thread of
/// its own (`open_url.openFile`): the shell may pump messages, and the core
/// asks from its tick.
fn openConfigWithOs(path: [:0]const u8) bool {
    return open_url.openFile(path);
}

/// Open the configuration in a new Ghostty window using VISUAL or EDITOR.
/// Returns false when no terminal editor is configured so callers can fall
/// back to the Windows file association.
fn openConfigInNewWindow(self: *App, path: [:0]const u8) !bool {
    const alloc = self.core_app.alloc;
    const editor = global.environ().getAlloc(alloc, "VISUAL") catch
        global.environ().getAlloc(alloc, "EDITOR") catch return false;
    defer alloc.free(editor);
    if (std.mem.trim(u8, editor, " \t\r\n").len == 0) return false;

    // Windows paths cannot contain a double quote, so quoting the path is
    // sufficient while leaving editor arguments supplied by the user intact.
    const command_text = try std.fmt.allocPrintSentinel(
        alloc,
        "{s} \"{s}\"",
        .{ editor, path },
        0,
    );
    defer alloc.free(command_text);
    const command: configpkg.Command = .{ .shell = command_text };

    const title_text = try i18n.fill(alloc, i18n.tr("Editing configuration file {path}"), .{
        .path = path,
    });
    defer alloc.free(title_text);
    const title = try alloc.dupeZ(u8, title_text);
    defer alloc.free(title);

    const window = try alloc.create(Window);
    window.init(self, .{}) catch |err| {
        alloc.destroy(window);
        return err;
    };
    self.windows.append(alloc, window) catch |err| {
        window.deinit();
        alloc.destroy(window);
        return err;
    };

    _ = window.addTabWithOptions(.{
        .context = .window,
        .command = &command,
        .title = title,
    }) catch |err| {
        // `open_config` asks from a core callback: the message loop
        // destroys the window that never showed.
        window.requestClose();
        return err;
    };
    return true;
}

/// Posted to `msg_hwnd` by `exportTerminalIo`; lparam is a
/// `TerminalIoExport`.
const WM_APP_EXPORT_TERMINAL_IO: u32 = w32.WM_APP + 36;

/// A terminal-I/O log waiting for the message loop to save it.
const TerminalIoExport = struct {
    /// The core surface that asked: the Save As dialog belongs to its window.
    surface_ref: gx.ui_ref.Reference,
    contents: []u8,

    fn destroy(self: *TerminalIoExport, alloc: Allocator) void {
        alloc.free(self.contents);
        alloc.destroy(self);
    }
};

/// The `export_terminal_io` action: save the terminal-I/O log the inspector
/// lends. The inspector asks while it holds the terminal lock, so the log
/// is copied and the Save As dialog runs from the message loop
/// (`saveTerminalIo`), as the GTK app's file chooser runs after the action.
fn exportTerminalIo(self: *App, target: apprt.Target, contents: []const u8) bool {
    const core_surface = switch (target) {
        .app => return false,
        .surface => |v| v,
    };
    const hwnd = self.msg_hwnd orelse return false;
    const alloc = self.core_app.alloc;
    const request = alloc.create(TerminalIoExport) catch return false;
    request.* = .{
        .surface_ref = core_surface.rt_surface.ui_reference,
        .contents = alloc.dupe(u8, contents) catch {
            alloc.destroy(request);
            return false;
        },
    };
    if (w32.PostMessageW(hwnd, WM_APP_EXPORT_TERMINAL_IO, 0, @bitCast(@intFromPtr(request))) == 0) {
        request.destroy(alloc);
        return false;
    }
    return true;
}

/// Handle `WM_APP_EXPORT_TERMINAL_IO`: ask where to save the log, write it
/// there and free the request.
fn saveTerminalIo(self: *App, request: *TerminalIoExport) void {
    const alloc = self.core_app.alloc;
    defer request.destroy(alloc);

    const owner = (self.resolveSurface(request.surface_ref) orelse return).parent_window.hwnd;
    const path = Dialogs.saveFilePath(alloc, owner, .{
        .title = i18n.tr("Export Terminal IO Events"),
        .default_name = "ghostty-terminal-io.txt",
        .default_ext = "txt",
        .filters = &.{
            .{ .label = i18n.tr("Text files (*.txt)"), .pattern = "*.txt" },
            .{ .label = i18n.tr("All files (*.*)"), .pattern = "*.*" },
        },
    }) catch |err| {
        log.warn("unable to choose the terminal IO export path: {}", .{err});
        return;
    } orelse return;
    defer alloc.free(path);

    // Save dialogs pump messages. A closed/replaced origin cannot authorize a
    // delayed write on behalf of a new terminal that happens to reuse its ID.
    if (self.resolveSurface(request.surface_ref) == null) return;

    var file = std.Io.Dir.createFileAbsolute(global.io(), path, .{ .truncate = true }) catch |err| {
        log.warn("unable to create terminal IO export file: {}", .{err});
        return;
    };
    defer file.close(global.io());
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(global.io(), &write_buf);
    writer.interface.writeAll(request.contents) catch |err| {
        log.warn("unable to write terminal IO export file: {}", .{err});
        return;
    };
    writer.interface.flush() catch |err| {
        log.warn("unable to flush terminal IO export file: {}", .{err});
    };
}

const ChildExitKind = enum {
    /// The command ran: the core reports the exit in the terminal.
    normal,
    /// The command failed to start: it exited with a nonzero code within
    /// `abnormal-command-exit-runtime`.
    abnormal,
};

/// How the child process of a terminal exited, judged like the core does
/// (`Surface.childExited`) with its `abnormal-command-exit-runtime`.
fn childExitKind(info: apprt.surface.Message.ChildExited, abnormal_runtime_ms: u32) ChildExitKind {
    if (info.runtime_ms > abnormal_runtime_ms or info.exit_code == 0) return .normal;
    return .abnormal;
}

/// Lazily create (and cache) the shell ITaskbarList3 used for taskbar-button
/// progress. Returns null if COM or the taskbar object is unavailable.
fn taskbarList(self: *App) ?*w32.ITaskbarList3 {
    // COM must be initialized on this (the UI) thread before CoCreateInstance.
    // S_FALSE (already initialized) is fine; we only need it done once.
    self.com_apartment.ensureCom() catch return null;
    if (self.taskbar) |tb| return tb;

    var ptr: ?*anyopaque = null;
    const hr = w32.CoCreateInstance(
        &w32.CLSID_TaskbarList,
        null,
        w32.CLSCTX_INPROC_SERVER,
        &w32.IID_ITaskbarList3,
        &ptr,
    );
    if (hr < 0 or ptr == null) return null;

    const tb: *w32.ITaskbarList3 = @ptrCast(@alignCast(ptr.?));
    _ = tb.HrInit();
    self.taskbar = tb;
    return tb;
}

/// Register a system-wide hotkey (RegisterHotKey) for every keybind with
/// the `global` flag, on the message-only window: the hotkeys work while a
/// menu or a dialog runs its modal loop too. A chord another program holds
/// goes into `shortcut_conflicts` right away, for the shortcut sheet.
fn registerGlobalHotkey(self: *App) void {
    const alloc = self.core_app.alloc;
    const hwnd = self.msg_hwnd orelse return;
    var next_id: i32 = 1;
    var it = self.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leaf => |l| l,
            // Leader and chained bindings are not registered as global hotkeys.
            .leader, .leaf_chained => continue,
        };
        if (!leaf.flags.global) continue;

        const chord = key_conflicts.chordOf(entry.key_ptr.*) orelse {
            log.warn("unsupported key for global hotkey action={s}", .{@tagName(leaf.action)});
            continue;
        };

        const id = next_id;
        if (w32.RegisterHotKey(hwnd, id, chord.mods | w32.MOD_NOREPEAT, chord.vk) == 0) {
            const err = GetLastError();
            log.warn("failed to register global hotkey action={s} err={}", .{ @tagName(leaf.action), err });
            if (err == ERROR_HOTKEY_ALREADY_REGISTERED) self.noteShortcutConflict(chord, .hotkey);
            continue;
        }
        self.global_hotkeys.append(alloc, .{ .id = id, .chord = chord, .trigger = entry.key_ptr.* }) catch {
            _ = w32.UnregisterHotKey(hwnd, id);
            continue;
        };
        next_id += 1;
        log.info("registered global hotkey id={} action={s}", .{ id, @tagName(leaf.action) });
    }
}

/// Unregister the hotkeys of `registerGlobalHotkey`.
fn unregisterGlobalHotkeys(self: *App) void {
    for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(self.msg_hwnd, hk.id);
    self.global_hotkeys.clearRetainingCapacity();
}

/// WM_HOTKEY `id`: perform the binding of that global hotkey as the
/// configuration has it now.
fn onHotkey(self: *App, id: usize) void {
    for (self.global_hotkeys.items) |hk| {
        if (@as(usize, @intCast(hk.id)) != id) continue;
        const entry = self.config.keybind.set.get(hk.trigger) orelse return;
        const action = switch (entry.value_ptr.*) {
            .leaf => |leaf| leaf.action,
            .leader, .leaf_chained => return,
        };
        // apprt.App is this win32 App, so `self` is the rt_app.
        self.core_app.performAllAction(self, action) catch |err| {
            log.warn("global hotkey action failed err={}", .{err});
        };
        return;
    }
}

/// Record that `chord` never reaches Ghostty GX, unless it is known.
fn noteShortcutConflict(self: *App, chord: key_conflicts.Chord, reason: key_conflicts.Reason) void {
    for (self.shortcut_conflicts.list.items) |conflict| {
        if (conflict.chord.eql(chord)) return;
    }
    self.shortcut_conflicts.list.append(self.core_app.alloc, .{ .chord = chord, .reason = reason }) catch {};
}

const ERROR_HOTKEY_ALREADY_REGISTERED: u32 = 1409;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// Probe the keybindings for chords another program or the input method
/// takes (`shortcut_conflicts`) a moment from now: after the first window
/// is up, and once after a burst of configuration reloads.
fn scheduleShortcutProbe(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    _ = w32.SetTimer(hwnd, SHORTCUT_PROBE_TIMER_ID, shortcut_probe_delay_ms, null);
}

/// Find the keybinding chords another program registered as a global
/// hotkey or the input method preserves, log one warning per binding
/// that uses one, and, once per session, show the notice when default
/// bindings for copying, pasting, searching or splitting are among them.
fn probeShortcuts(self: *App) void {
    const alloc = self.core_app.alloc;
    const set = &self.config.keybind.set;
    var own: std.ArrayList(key_conflicts.Chord) = .empty;
    defer own.deinit(alloc);
    for (self.global_hotkeys.items) |hk| own.append(alloc, hk.chord) catch return;
    var chords = key_conflicts.candidates(alloc, set, own.items) catch return;
    defer chords.deinit(alloc);
    const found = key_conflicts.probe(alloc, self.msg_hwnd, chords.items) catch |err| {
        log.warn("cannot probe the keybindings for conflicts err={}", .{err});
        return;
    };
    self.shortcut_conflicts.deinit(alloc);
    self.shortcut_conflicts = found;
    log.info("probed {} keybinding chords, {} taken by other programs or the input method", .{
        chords.items.len,
        found.list.items.len,
    });
    key_conflicts.logConflicts(set, &self.shortcut_conflicts);
    if (!self.shortcut_notice_shown) self.showShortcutNotice();
}

/// Show the notice about taken default copy, paste, search and split
/// bindings in the foreground window, when there are any.
fn showShortcutNotice(self: *App) void {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var defaults: configpkg.Keybinds = .{};
    defaults.init(a) catch return;
    const set = &self.config.keybind.set;
    const affected = key_conflicts.noticeBindings(a, set, &defaults.set, &self.shortcut_conflicts) catch return;
    if (affected.items.len == 0) return;
    const window = self.targetWindow(.app) orelse return;

    var keys_buf: [256]u8 = undefined;
    var keys: std.Io.Writer = .fixed(&keys_buf);
    for (affected.items, 0..) |item, i| {
        var buf: [64]u8 = undefined;
        if (i > 0) keys.writeAll(", ") catch break;
        keys.writeAll(trigger.format(item.trigger, &buf)) catch break;
    }
    const hints: trigger.Hints = .{ .set = set, .blocked = &self.shortcut_conflicts };
    var copy_buf: [64]u8 = undefined;
    var paste_buf: [64]u8 = undefined;
    var palette_buf: [64]u8 = undefined;
    var sheet_buf: [64]u8 = undefined;
    window.shortcut_notice.show(.{
        .keys = keys.buffered(),
        .copy = hints.text(.{ .copy_to_clipboard = .mixed }, &copy_buf) orelse "",
        .paste = hints.text(.paste_from_clipboard, &paste_buf) orelse "",
        .palette = hints.text(.toggle_command_palette, &palette_buf) orelse "",
        .sheet = hints.text(.{ .gx = .keybinds }, &sheet_buf) orelse "",
    });
    self.shortcut_notice_shown = true;
    log.info("shortcut conflict notice shown keys={s}", .{keys.buffered()});
}

// -----------------------------------------------------------------------
// Feedback: notices and toasts at the bottom of a window
// -----------------------------------------------------------------------

/// Whether a notice shows now (from the message loop) or is posted (from a
/// core callback, which must not show windows).
const NoticeTiming = enum { now, post };

/// The most configuration errors a notice lists.
const max_listed_diagnostics = 3;

/// Report the configuration errors in a notice that stays until it is
/// closed, with buttons to open the configuration file and to reload it.
/// Once for each set of errors (`gx.config_layers.diagnosticsDigest`), so
/// the reloads and theme preview steps that keep them say nothing again;
/// closes the notice once they are fixed. Waits for a window to exist.
fn reportConfigDiagnostics(self: *App, timing: NoticeTiming) void {
    const digest = gx.config_layers.diagnosticsDigest(&self.config);
    if (digest == self.diagnostics_reported) return;
    if (digest == 0) {
        self.diagnostics_reported = 0;
        for (self.windows.items) |window| {
            if (showsNotice(window, diagnosticsClosed)) window.hideNotice();
        }
        return;
    }
    const window = self.targetWindow(.app) orelse return;
    self.diagnostics_reported = digest;
    const diagnostics = self.config._diagnostics.items();
    var body_buf: [1024]u8 = undefined;
    const actions = [_][]const u8{ i18n.tr("Open Configuration File"), i18n.tr("Reload Configuration") };
    const content: Notice.Content = .{
        .severity = .@"error",
        .title = i18n.tr("Configuration Errors"),
        .body = diagnosticsText(&body_buf, diagnostics, i18n.tr("…and {count} more.")),
        .actions = &actions,
        .duration_ms = null,
    };
    const callbacks: Notice.Callbacks = .{ .ctx = self, .action = diagnosticsAction, .closed = diagnosticsClosed };
    switch (timing) {
        .now => window.showNotice(content, callbacks),
        .post => window.postNotice(content, callbacks),
    }
    log.info("configuration errors reported count={}", .{diagnostics.len});
}

/// The configuration errors `diagnostics` for a notice: the first
/// `max_listed_diagnostics`, one per line, then `more` (a template with a
/// `{count}` placeholder) for the rest. Cut to `buf`.
fn diagnosticsText(buf: []u8, diagnostics: []const cli.Diagnostic, more: []const u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    const listed = @min(diagnostics.len, max_listed_diagnostics);
    for (diagnostics[0..listed], 0..) |*diagnostic, i| {
        if (i > 0) writer.writeAll("\n") catch break;
        diagnostic.format(&writer) catch break;
    }
    if (diagnostics.len > listed) {
        writer.writeAll("\n") catch return writer.buffered();
        i18n.format(&writer, more, .{ .count = diagnostics.len - listed }) catch {};
    }
    return writer.buffered();
}

/// A button of the configuration errors notice.
fn diagnosticsAction(ctx: *anyopaque, notice: *Notice, index: usize) void {
    _ = notice;
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (index) {
        0 => _ = self.openConfigFile(.os_open) catch false,
        1 => self.core_app.performAction(self, .reload_config) catch |err| {
            log.warn("cannot reload the configuration err={}", .{err});
        },
        else => {},
    }
}

/// The configuration errors notice closed: closed with its close button,
/// the errors are ignored until they change; closed for one of its buttons,
/// they are reported again if they stay.
fn diagnosticsClosed(ctx: *anyopaque, notice: *Notice, reason: Notice.CloseReason) void {
    _ = notice;
    const self: *App = @ptrCast(@alignCast(ctx));
    if (reason == .action) self.diagnostics_reported = 0;
}

const NoticeClosedFn = *const fn (ctx: *anyopaque, notice: *Notice, reason: Notice.CloseReason) void;

/// Whether the notice of `window` is (or is about to show) the one whose
/// `Notice.Callbacks.closed` is `closed`.
fn showsNotice(window: *const Window, closed: NoticeClosedFn) bool {
    const callbacks = window.notice.callbacks orelse return false;
    const f = callbacks.closed orelse return false;
    return f == closed;
}

/// A terminal's command failed to start (an abnormal exit): say so in a
/// notice at the bottom of its window, which blocks nothing, unlike a
/// dialog. It stays until it is closed; any key closes the terminal. From a
/// core callback. Returns whether it is shown, which keeps the core from
/// printing its own message.
fn showChildExited(surface: *Surface, exit_code: u32) bool {
    surface.app.hideChildExitedNotice(surface);
    const window = surface.parent_window;
    if (window.hwnd == null) return false;
    var buf: [512]u8 = undefined;
    var body: std.Io.Writer = .fixed(&buf);
    i18n.format(&body, i18n.tr("The shell process exited with code {code}."), .{ .code = exit_code }) catch {};
    body.writeAll("\n") catch {};
    body.writeAll(i18n.tr("Press any key to close the terminal.")) catch {};
    window.postNotice(.{
        .severity = .@"error",
        .title = i18n.tr("Command Failed"),
        .body = body.buffered(),
        .duration_ms = null,
    }, .{ .ctx = surface, .closed = childExitedNoticeClosed });
    surface.child_exit_notice_window = window.ui_reference;
    return true;
}

// The marker identifies ownership without dereferencing a terminal that a
// window-level notice could outlive.
fn childExitedNoticeClosed(_: *anyopaque, _: *Notice, _: Notice.CloseReason) void {}

/// Removing the failed terminal must not leave its instruction over another
/// terminal, or dismiss a newer unrelated notice in the same window.
pub fn hideChildExitedNotice(self: *App, surface: *Surface) void {
    const reference = surface.child_exit_notice_window;
    surface.child_exit_notice_window = .{};
    const window = self.resolveWindow(reference) orelse return;
    if (!showsNotice(window, childExitedNoticeClosed)) return;
    const callbacks = window.notice.callbacks orelse return;
    if (callbacks.ctx != @as(*anyopaque, surface)) return;
    window.hideNotice();
}

/// The sequence belongs to its terminal. Other terminals ending a sequence
/// cannot clear its buffer or a table/action toast that replaced its hint.
fn showKeySequence(surface: *Surface, value: apprt.action.KeySequence) void {
    const window = surface.parent_window;
    const owner: @import("ui/Toast.zig").Owner = .{ .surface_id = surface.core_surface.id, .kind = .sequence };
    switch (value) {
        .trigger => |key| {
            var key_buf: [64]u8 = undefined;
            const text = trigger.format(key, &key_buf);
            var writer: std.Io.Writer = .fixed(surface.key_sequence[surface.key_sequence_len..]);
            if (surface.key_sequence_len > 0) writer.writeAll(" \u{2192} ") catch {};
            writer.writeAll(text) catch {};
            surface.key_sequence_len += writer.buffered().len;
            var toast_buf: [160]u8 = undefined;
            const keys = surface.key_sequence[0..surface.key_sequence_len];
            const toast_text = std.fmt.bufPrint(&toast_buf, "{s} \u{2026}", .{keys}) catch keys;
            window.postToast(.{ .text = toast_text, .icon = d2d.icons.keyboard, .duration_ms = null, .owner = owner });
        },
        .end => {
            surface.key_sequence_len = 0;
            window.toast.hideOwned(owner);
        },
    }
}

/// A table hint has a distinct owner from a sequence hint of the same
/// terminal. Occlusion cancels the visual hint, not the core key state.
fn showKeyTable(surface: *Surface, value: apprt.action.KeyTable) void {
    const window = surface.parent_window;
    const owner: @import("ui/Toast.zig").Owner = .{ .surface_id = surface.core_surface.id, .kind = .table };
    switch (value) {
        .activate => |name| {
            var buf: [160]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            i18n.format(&writer, i18n.tr("Key table {name}"), .{ .name = name }) catch {};
            window.postToast(.{ .text = writer.buffered(), .icon = d2d.icons.keyboard, .duration_ms = null, .owner = owner });
        },
        .deactivate, .deactivate_all => window.toast.hideOwned(owner),
    }
}

/// `readonly`: a terminal went read-only (a notice says what that means)
/// or writable again (a toast). From a core callback.
fn showReadonly(window: *Window, value: apprt.action.Readonly) void {
    switch (value) {
        .on => window.postNotice(.{
            .title = i18n.tr("Read-only"),
            .body = i18n.tr("This terminal is in read-only mode. You can still view, select, and scroll through the content, but no input events will be sent to the running application."),
            .duration_ms = null,
        }, .{ .ctx = window, .closed = readonlyClosed }),
        .off => {
            if (showsNotice(window, readonlyClosed)) window.hideNotice();
            window.postToast(.{ .text = i18n.tr("Read-only mode is off"), .icon = d2d.icons.check_mark });
        },
    }
}

/// Marks the read-only notice (`showsNotice`).
fn readonlyClosed(ctx: *anyopaque, notice: *Notice, reason: Notice.CloseReason) void {
    _ = ctx;
    _ = notice;
    _ = reason;
}

/// Confirm a write to the clipboard in a toast at the bottom of `window`,
/// as `app-notifications = clipboard-copy` (the default) asks: "Copied to
/// clipboard", or "Cleared clipboard" for an empty text. For the standard
/// clipboard only. For the terminal's clipboard writes
/// (`Surface.setClipboard`), from core callbacks too.
pub fn notifyClipboardCopy(self: *App, window: *Window, clipboard: apprt.Clipboard, empty: bool) void {
    if (clipboard != .standard) return;
    if (!self.config.@"app-notifications".@"clipboard-copy") return;
    window.postToast(.{
        .text = if (empty) i18n.tr("Cleared clipboard") else i18n.tr("Copied to clipboard"),
        .icon = d2d.icons.copy,
    });
}

/// `copy_title_to_clipboard`: copy the effective title of `surface`, the
/// tab title set by renaming the tab, else the title the terminal set.
/// Returns false when there is none.
fn copyTitle(self: *App, surface: *Surface) bool {
    const alloc = self.core_app.alloc;
    const window = surface.parent_window;
    var override: ?[]u8 = null;
    defer if (override) |text| alloc.free(text);
    if (window.findTabIndex(surface)) |tab| {
        if (window.tab_title_overrides[tab]) |*title| {
            override = std.unicode.wtf16LeToWtf8Alloc(alloc, title.slice()) catch return false;
        }
    }
    const title: []const u8 = if (override) |text| text else (surface.getTitle() orelse return false);
    if (title.len == 0) return false;
    const text = alloc.dupeZ(u8, title) catch return false;
    defer alloc.free(text);
    surface.setClipboard(.standard, &.{.{ .mime = "text/plain", .data = text }}, false) catch return false;
    return true;
}

// -----------------------------------------------------------------------
// Bell and taskbar progress
// -----------------------------------------------------------------------

/// The bell of `surface` (BEL, or a finished command with
/// `notify-on-command-finish-action = bell`), as `bell-features` asks:
/// `system` plays the Windows default sound, `audio` the
/// `bell-audio-path` sound (mono/stereo PCM or float WAV, scaled by
/// `bell-audio-volume` before PCM16 playback),
/// `attention` badges the tab and flashes the taskbar button of a window
/// in the background, `title` marks the tab with a bell until it is
/// selected. `border` highlights an unfocused terminal until focus or input.
fn ringBell(self: *App, surface: ?*Surface) void {
    const features = self.config.@"bell-features";
    if (features.system) _ = w32.MessageBeep(0xFFFFFFFF);
    if (features.audio) self.playBellAudio();
    const s = surface orelse return;
    const window = s.parent_window;
    if (features.attention) {
        window.onBell(s);
        flashTaskbarButton(window);
    }
    if (features.title) window.ringTab(s);
    if (features.border) s.ringBellBorder();
}

test "bell border App routes only to its unfocused terminal" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    config.@"bell-features" = .{ .system = false, .audio = false, .attention = false, .title = false, .border = true };
    var app: App = .{ .core_app = undefined, .config = config, .hinstance = undefined, .default_command_arena = .init(std.testing.allocator) };
    defer app.default_command_arena.deinit();
    var window: Window = .{ .app = &app };
    var surface: Surface = .{ .app = &app, .parent_window = &window, .core_surface_ready = true };
    surface.bell_border_state.configure(true);
    surface.core_surface.focused = false;
    surface.core_surface.renderer_thread.wakeup = try global.xev.Async.init();
    defer surface.core_surface.renderer_thread.wakeup.deinit();
    app.ringBell(&surface);
    try std.testing.expect(surface.bellBorder().active);
    app.ringBell(null);
    try std.testing.expect(surface.bellBorder().active);
    surface.core_surface.focused = true;
    app.ringBell(&surface);
    try std.testing.expect(!surface.bellBorder().active);
    surface.core_surface.focused = false;
    app.config.@"bell-features".border = false;
    app.ringBell(&surface);
    try std.testing.expect(!surface.bellBorder().active);
}

/// Flash the taskbar button of `window` until it comes to the front,
/// unless it is the foreground window.
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

/// Play `bell-audio-path` without waiting for file I/O or playback.
pub fn playBellAudio(self: *App) void {
    if (self.config.@"bell-audio-path" == null) return;
    const player = self.bell_audio orelse blk: {
        const player = BellAudio.create() catch |err| {
            log.warn("cannot create bell audio player err={}", .{err});
            return;
        };
        self.bell_audio = player;
        break :blk player;
    };
    self.queueBellAudio(player);
}

fn queueBellAudio(self: *App, player: anytype) void {
    const path = self.config.@"bell-audio-path" orelse return;
    const text = switch (path) {
        inline else => |p| p,
    };
    player.request(text, self.config.@"bell-audio-volume") catch |err| switch (err) {
        error.PlayerFaulted, error.PlayerStopped => {},
        else => log.warn("cannot queue bell audio err={}", .{err}),
    };
}

test "bell audio App playback passes configured relative volume and resolved path" {
    var app: App = undefined;
    app.config = try Config.default(std.testing.allocator);
    defer app.config.deinit();
    app.config.@"bell-audio-path" = .{ .required = "C:\\isolated\\bell.wav" };
    const Spy = struct {
        volume: f64 = -1,
        path: ?[]const u8 = null,
        fn request(self: *@This(), path: []const u8, volume: f64) !void {
            self.path = path;
            self.volume = volume;
        }
    };
    var spy: Spy = .{};
    app.queueBellAudio(&spy);
    try std.testing.expectEqualStrings("C:\\isolated\\bell.wav", spy.path.?);
    try std.testing.expectEqual(@as(f64, 0.5), spy.volume);
    for ([_]f64{ 0, 0.01, 0.1, 0.3, 0.75, 1 }) |volume| {
        app.config.@"bell-audio-volume" = volume;
        app.queueBellAudio(&spy);
        try std.testing.expectEqual(volume, spy.volume);
    }
    app.config.@"bell-audio-path" = null;
    spy.path = null;
    app.queueBellAudio(&spy);
    try std.testing.expect(spy.path == null);
}

test "bell audio App ring routes the enabled custom feature to a joined silent player" {
    var app: App = undefined;
    app.config = try Config.default(std.testing.allocator);
    defer app.config.deinit();
    app.bell_audio = null;
    defer if (app.bell_audio) |player| player.destroy();
    app.config.@"bell-audio-path" = .{ .required = "C:\\isolated\\not-opened-at-zero-volume.wav" };
    app.config.@"bell-audio-volume" = 0;
    app.config.@"bell-features" = .{ .audio = false, .system = false };
    app.ringBell(null);
    try std.testing.expect(app.bell_audio == null);
    app.config.@"bell-features".audio = true;
    app.ringBell(null);
    try std.testing.expect(app.bell_audio != null);
    app.bell_audio.?.invalidate();
}

/// What a taskbar button shows: a `TBPF_*` state and, for the states with a
/// bar, its percent.
const TaskbarValue = struct {
    state: c_int,
    percent: ?u8,
};

/// A taskbar button and what it shows.
const TaskbarShown = struct {
    hwnd: w32.HWND,
    value: TaskbarValue,
};

/// The taskbar button state for `progress`. A bar without a value is empty
/// while running and full when paused or failed, so that its color shows.
fn taskbarValue(progress: tab_status.Progress) TaskbarValue {
    return switch (progress.state) {
        .none => .{ .state = w32.TBPF_NOPROGRESS, .percent = null },
        .indeterminate => .{ .state = w32.TBPF_INDETERMINATE, .percent = null },
        .normal => .{ .state = w32.TBPF_NORMAL, .percent = progress.percent orelse 0 },
        .paused => .{ .state = w32.TBPF_PAUSED, .percent = progress.percent orelse 100 },
        .@"error" => .{ .state = w32.TBPF_ERROR, .percent = progress.percent orelse 100 },
    };
}

/// The progress that the terminals of all tabs of `window` report together
/// (`tab_status.merge`: error, then paused, normal and indeterminate),
/// leaving out the reports older than `tab_status.stale_after_ms`.
fn windowProgress(window: *const Window, now_ms: u64) tab_status.Progress {
    if (!window.app.config.@"progress-style") return .none;
    var acc: tab_status.Progress = .none;
    for (0..window.tab_count) |i| acc = tab_status.merge(acc, window.tabStatus(i).progress, now_ms);
    return acc;
}

/// Show the progress of `window` (`windowProgress`) on its taskbar button
/// and keep `PROGRESS_TIMER_ID` running while there is some.
pub fn updateTaskbarProgress(self: *App, window: *Window) void {
    if (self.com_apartment.isClosing()) return;
    const hwnd = window.hwnd orelse return;
    const progress = windowProgress(window, GetTickCount64());
    self.showTaskbarProgress(hwnd, taskbarValue(progress));
    if (progress.state != .none) self.startProgressTimer();
}

/// Set `value` on the taskbar button of `hwnd` unless it shows it already.
fn showTaskbarProgress(self: *App, hwnd: w32.HWND, value: TaskbarValue) void {
    if (self.com_apartment.isClosing()) return;
    for (self.taskbar_shown.items) |*shown| {
        if (shown.hwnd != hwnd) continue;
        if (std.meta.eql(shown.value, value)) return;
        if (self.setTaskbarValue(hwnd, value)) shown.value = value;
        return;
    }
    if (value.state == w32.TBPF_NOPROGRESS) return;
    if (!self.setTaskbarValue(hwnd, value)) return;
    self.taskbar_shown.append(self.core_app.alloc, .{ .hwnd = hwnd, .value = value }) catch {};
}

fn setTaskbarValue(self: *App, hwnd: w32.HWND, value: TaskbarValue) bool {
    const taskbar = self.taskbarList() orelse return false;
    taskbar.SetProgressState(hwnd, value.state);
    if (value.percent) |percent| taskbar.SetProgressValue(hwnd, percent, 100);
    return true;
}

fn startProgressTimer(self: *App) void {
    if (self.com_apartment.isClosing() or self.progress_timer) return;
    const hwnd = self.msg_hwnd orelse return;
    if (w32.SetTimer(hwnd, PROGRESS_TIMER_ID, progress_timer_ms, null) != 0) self.progress_timer = true;
}

/// `PROGRESS_TIMER_ID`: end on the taskbar buttons the progress of the
/// terminals that stopped reporting or closed, and stop once no button
/// shows progress.
fn onProgressTimer(self: *App) void {
    if (self.com_apartment.isClosing()) return;
    const now = GetTickCount64();
    var active = false;
    for (self.windows.items) |window| {
        const hwnd = window.hwnd orelse continue;
        const progress = windowProgress(window, now);
        self.showTaskbarProgress(hwnd, taskbarValue(progress));
        if (progress.state != .none) active = true;
    }
    // Buttons that show nothing, and the buttons of closed windows.
    var i: usize = 0;
    while (i < self.taskbar_shown.items.len) {
        const shown = self.taskbar_shown.items[i];
        if (shown.value.state == w32.TBPF_NOPROGRESS or self.windowOfHwnd(shown.hwnd) == null) {
            _ = self.taskbar_shown.swapRemove(i);
        } else i += 1;
    }
    if (active) return;
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, PROGRESS_TIMER_ID);
    self.progress_timer = false;
}

fn windowOfHwnd(self: *App, hwnd: w32.HWND) ?*Window {
    for (self.windows.items) |window| {
        if (window.hwnd == hwnd) return window;
    }
    return null;
}

/// Whether `msg` is the message Explorer sends a window when its taskbar
/// button exists (`TaskbarButtonCreated`): the window passes it to
/// `onTaskbarButtonCreated`.
pub fn isTaskbarButtonCreated(self: *const App, msg: u32) bool {
    return self.taskbar_button_created != 0 and msg == self.taskbar_button_created;
}

/// Explorer made the taskbar button of `window`, again after it restarted:
/// show the window's progress on it anew.
pub fn onTaskbarButtonCreated(self: *App, window: *Window) void {
    if (self.com_apartment.isClosing()) return;
    const hwnd = window.hwnd orelse return;
    for (self.taskbar_shown.items, 0..) |shown, i| {
        if (shown.hwnd != hwnd) continue;
        _ = self.taskbar_shown.swapRemove(i);
        break;
    }
    self.updateTaskbarProgress(window);
}

extern "user32" fn RegisterWindowMessageW(name: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

// -----------------------------------------------------------------------
// Notifications
// -----------------------------------------------------------------------

/// Tray-icon notification callback (uCallbackMessage). The wparam is
/// the tray icon's uID; lparam carries NIN_* events.
const WM_APP_TRAY: u32 = w32.WM_APP + 3;

/// Tray icon and timer IDs for desktop notifications.
const NOTIF_DESKTOP_UID: u32 = 1;
const NOTIF_DESKTOP_TIMER_ID: usize = 2;

extern "user32" fn IsIconic(hWnd: w32.HWND) callconv(.winapi) i32;

/// What `startQuitTimer` does (`quitTimerStart`).
const QuitTimerStart = union(enum) {
    /// Nothing: the message loop has not started, or the app stays open.
    none,
    /// Quit once the configured delay (milliseconds) has passed.
    timer: u32,
    /// Quit right away.
    quit,
};

/// What `startQuitTimer` does while the message loop is `running` or not,
/// with `quit-after-last-window-closed` (`enabled`) and its delay.
fn quitTimerStart(running: bool, enabled: bool, delay_ms: ?u32) QuitTimerStart {
    if (!running or !enabled) return .none;
    const ms = delay_ms orelse return .quit;
    return .{ .timer = ms };
}

/// Start the quit timer. Called when the last surface closes; `main` also
/// calls it before `run`, which this ignores (see `running`).
pub fn startQuitTimer(self: *App) void {
    // Cancel any existing timer first.
    self.stopQuitTimer();
    if (self.remote.keepsAlive()) return;
    if (self.drop_companion) |companion| if (companion.keepsAlive()) return;

    const delay = self.config.@"quit-after-last-window-closed-delay";
    switch (quitTimerStart(
        self.running,
        self.config.@"quit-after-last-window-closed",
        if (delay) |v| v.asMilliseconds() else null,
    )) {
        .none => {},
        .timer => |ms| if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        },
        .quit => {
            self.quit_timer_state = .expired;
            self.quit_requested = true;
            w32.PostQuitMessage(0);
        },
    }
}

/// Cancel the quit timer. Called when a new surface opens.
pub fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => {
            self.quit_timer_state = .off;
            // Reset quit_requested. The WM_QUIT posted by startQuitTimer's
            // no-delay path can't be removed from the queue (it's a flag,
            // not a real message). Instead, the loop that retrieves it
            // checks quit_requested — if false, it ignores the spurious
            // WM_QUIT and continues: `run`, and the modal loops of the
            // dialogs and menus (`Popup.modalQuitCode`). This happens when
            // a terminal opens after the last one closed, before the loop
            // got to the WM_QUIT.
            self.quit_requested = false;
        },
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}

/// Quit on behalf of the user (the `quit` and `close_all_windows`
/// actions). The core asks from its tick, so the confirmation runs from
/// the message loop (`WM_APP_QUIT`, `confirmQuit`).
fn requestQuit(self: *App) void {
    // The core leaves the rest of its mailbox after a quit to the next
    // tick, and wakeups coalesce: ask for that tick.
    self.wakeup();
    if (self.msg_hwnd) |hwnd| {
        if (w32.PostMessageW(hwnd, WM_APP_QUIT, 0, 0) != 0) return;
    }
    self.quitNow();
}

/// Quit after one process snapshot and an arena-owned confirmation grouped
/// by tab. The modal dialog does not borrow live window or surface data.
fn confirmQuit(self: *App) void {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    var groups: std.ArrayList(Dialogs.ProcessGroup) = .empty;
    var scope: gx.confirm.Scope = undefined;
    scope.begin(self.core_app.alloc, global.io());
    defer scope.end();
    for (self.windows.items) |window| appendQuitGroups(window, arena.allocator(), &groups) catch |err| {
        log.err("cannot prepare the quit confirmation err={}", .{err});
        return;
    };
    if (self.quick_terminal) |qt| appendQuitGroups(qt.window, arena.allocator(), &groups) catch |err| {
        log.err("cannot prepare the quick terminal quit confirmation err={}", .{err});
        return;
    };
    scope.end();
    if (groups.items.len != 0) {
        const owner = if (self.targetWindow(.app)) |window| window.hwnd else null;
        if (Dialogs.confirmQuitByTab(owner, groups.items) != .accept) return;
    }
    self.quitNow();
}

fn appendQuitGroups(window: *Window, alloc: Allocator, groups: *std.ArrayList(Dialogs.ProcessGroup)) Allocator.Error!void {
    for (0..window.tab_count) |i| {
        const group = try window.closeGroup(i, alloc) orelse continue;
        try groups.append(alloc, group);
    }
}

fn quitNow(self: *App) void {
    self.session.onQuit(self);
    self.quit_requested = true;
    w32.PostQuitMessage(0);
}

/// Show a Windows balloon notification via Shell_NotifyIconW.
/// Creates a temporary tray icon, shows the balloon, then removes
/// the icon after a short delay.
fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    const reference: gx.ui_ref.Reference = switch (target) {
        .surface => |surface| surface.rt_surface.ui_reference,
        .app => if (self.targetWindow(.app)) |window| window.ui_reference else return,
    };
    if (self.shell.notify(self, reference, value.title, value.body)) return;
    _ = self.showLegacyDesktopNotification(reference, value.title, value.body);
}

pub fn showLegacyDesktopNotification(self: *App, reference: gx.ui_ref.Reference, title: []const u8, body: []const u8) bool {
    // Remember the originating surface so a balloon click can focus it.
    self.notif_desktop_reference = reference;
    return self.showDesktopNotificationText(title, body);
}

/// Show a desktop toast with the given title/body via the tray icon. The
/// balloon click is delivered as WM_APP_TRAY (NIF_MESSAGE) and presents the
/// pane or window in notif_desktop_reference, mirroring macOS/GTK where
/// clicking a notification presents the originating surface.
fn showDesktopNotificationText(self: *App, title: []const u8, body: []const u8) bool {
    const hwnd = self.msg_hwnd orelse return false;

    var nid: w32.NOTIFYICONDATAW_V3 = std.mem.zeroes(w32.NOTIFYICONDATAW_V3);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW_V3);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID;
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    // The app icon, large, rather than the generic information icon.
    nid.hBalloonIcon = self.balloonIcon();
    nid.dwInfoFlags = if (nid.hBalloonIcon != null) w32.NIIF_USER | w32.NIIF_LARGE_ICON else w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000; // 5 second timeout

    // Title and body (UTF-8 → UTF-16LE), cut to the fixed fields at a
    // codepoint boundary.
    _ = wstr.bufZ(&nid.szInfoTitle, title);
    _ = wstr.bufZ(&nid.szInfo, body);
    _ = wstr.bufZ(&nid.szTip, gx.branding.name);

    // Add the icon with the balloon, then remove the icon. While the icon
    // of an earlier notification still exists adding fails and modifying
    // it shows the new balloon; doing both would show it twice.
    const data: *w32.NOTIFYICONDATAW = @ptrCast(&nid);
    const shown = w32.Shell_NotifyIconW(w32.NIM_ADD, data) != 0 or
        w32.Shell_NotifyIconW(w32.NIM_MODIFY, data) != 0;
    if (shown) {
        log.info("desktop notification shown surface_id={x}", .{self.notif_desktop_reference.id});
    } else {
        log.warn("desktop notification could not be shown", .{});
    }

    // Schedule icon removal via a timer.
    _ = w32.SetTimer(hwnd, NOTIF_DESKTOP_TIMER_ID, 6000, null);
    return shown;
}

/// The app icon at the size of large icons, for desktop notifications.
fn balloonIcon(self: *App) ?w32.HICON {
    if (self.balloon_icon) |icon| return icon;
    const handle = LoadImageW(
        self.hinstance,
        w32.IDI_GHOSTTY,
        IMAGE_ICON,
        w32.GetSystemMetrics(SM_CXICON),
        w32.GetSystemMetrics(SM_CYICON),
        LR_SHARED,
    ) orelse return null;
    const icon: w32.HICON = @ptrCast(handle);
    self.balloon_icon = icon;
    return icon;
}

const IMAGE_ICON: u32 = 1;
const LR_SHARED: u32 = 0x00008000;
const SM_CXICON: i32 = 11;
const SM_CYICON: i32 = 12;
extern "user32" fn LoadImageW(
    instance: ?w32.HINSTANCE,
    name: usize,
    image_type: u32,
    width: i32,
    height: i32,
    load: u32,
) callconv(.winapi) ?*anyopaque;

/// Remove the notification area icon a desktop notification added, if it
/// is still there.
fn removeNotificationIcon(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    _ = w32.KillTimer(hwnd, NOTIF_DESKTOP_TIMER_ID);
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID;
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
    for (self.core_app.surfaces.items) |surface| {
        surface.drainScrollbarActivity();
        if (surface.guest_cwd_dirty.swap(false, .acq_rel)) self.scheduleSessionSave();
    }
}

/// Window procedure for terminal surface child HWNDs (GhosttyTerminal class).
/// GWLP_USERDATA stores a *Surface pointer.
fn surfaceWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0 and msg == w32.WM_DROPFILES) {
        if (wparam != 0) w32.DragFinish(@ptrFromInt(wparam));
        return 0;
    }
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Guard: verify this is the surface window itself.
    if (surface.hwnd == null or surface.hwnd.? != hwnd)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (surface.app.drop_closing) {
        if (msg == w32.WM_DROPFILES and wparam != 0) w32.DragFinish(@ptrFromInt(wparam));
        return 0;
    }

    switch (msg) {
        w32.WM_ENTERSIZEMOVE => {
            surface.in_live_resize = true;
            return 0;
        },

        w32.WM_EXITSIZEMOVE => {
            surface.in_live_resize = false;
            return 0;
        },

        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },

        w32.WM_MOVE => {
            if (surface.scrollbar) |sb| _ = sb.repositionAndResize();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SHOWWINDOW => {
            surface.onShowWindow(wparam != 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CLOSE => {
            // Posted by Surface.close() to defer destruction to the
            // message loop. This is the safe place to call closeSplitSurface
            // (outside of core_surface callbacks) — unless a dialog's modal
            // loop dispatched it, in which case it waits for the dialog.
            if (Dialogs.deferClose(hwnd)) return 0;
            surface.parent_window.closeSplitSurface(surface);
            return 0;
        },

        Surface.WM_APP_CONFIRM_CLOSE => {
            surface.confirmClose();
            return 0;
        },

        Surface.WM_APP_CONFIRM_CLIPBOARD => {
            surface.confirmClipboard();
            return 0;
        },

        Surface.WM_APP_CHILD_EXITED => {
            _ = showChildExited(surface, @truncate(wparam));
            return 0;
        },

        Surface.WM_APP_RELEASE_BUTTONS => {
            surface.releaseButtons(@truncate(wparam));
            return 0;
        },

        w32.WM_CAPTURECHANGED => {
            surface.handleCaptureChanged();
            return 0;
        },

        w32.WM_TIMER => {
            if (surface.handleTimer(wparam)) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        Surface.WM_APP_GPU_RESET => {
            surface.recoverGpuResources();
            return 0;
        },

        Surface.WM_GHOSTTY_SIMULATE_GPU_RESET => {
            // Test-only: the next presented frame acts as if the GPU had
            // been reset; draw one now.
            surface.simulate_gpu_reset.store(true, .release);
            surface.refreshRenderer();
            return 1;
        },

        w32.WM_DESTROY => {
            // The child HWND is being destroyed (by Surface.deinit or
            // parent Window destruction). Clear state so deinit()
            // doesn't double-destroy. Lifecycle is managed by Window.
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            surface.hwnd = null;
            surface.core_surface_ready = false;
            return 0;
        },

        w32.WM_ERASEBKGND => {
            surface.eraseBackground(@ptrFromInt(wparam));
            return 1;
        },

        w32.WM_PAINT => {
            _ = w32.ValidateRect(hwnd, null);
            if (surface.core_surface_ready and !surface.in_live_resize) {
                surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            surface.handleKeyEvent(wparam, lparam, .press);
            return 0;
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            surface.handleKeyEvent(wparam, lparam, .release);
            return 0;
        },

        w32.WM_SYSCHAR => {
            // TranslateMessage is skipped for terminal surface windows
            // (see App.run), so WM_SYSCHAR is never posted by it for our
            // windows. This handler guards against WM_SYSCHAR arriving via
            // SendInput, PostMessage, or other injection paths: forwarding
            // it to DefWindowProc would treat it as an unmatched menu
            // accelerator and ring MessageBeep. Consume it unconditionally.
            return 0;
        },

        w32.WM_DEADCHAR, w32.WM_SYSDEADCHAR => {
            // The message loop skips TranslateMessage for surface windows,
            // so WM_DEADCHAR is normally never posted for them. If one
            // arrives via another path (e.g. SendInput), drop it — dead
            // keys are composed via ToUnicode in handleKeyEvent.
            return 0;
        },

        w32.WM_CHAR => {
            // If handleKeyEvent already produced text via ToUnicode for
            // the preceding WM_KEYDOWN, suppress this WM_CHAR to avoid
            // double input. Otherwise, process it — the character came
            // from IME, SendInput Unicode (VK_PACKET), PostMessage, or
            // another source that didn't go through handleKeyEvent.
            if (surface.key_event_produced_text) {
                surface.key_event_produced_text = false;
                return 0;
            }
            surface.handleCharEvent(wparam);
            return 0;
        },

        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT. Without this,
            // DefWindowProc creates an oleacc AccWrap proxy for each surface
            // HWND. When focus moves between split panes (which are sibling
            // child HWNDs in our layout), oleacc destroys the outgoing
            // surface's AccWrap synchronously inside DefWindowProc; the
            // destructor re-enters our WindowProc via SetFocus, which fires
            // ImeSystemHandler -> oleacc!CreateClient -> COM marshaling that
            // waits for a reply this thread cannot pump (deep WindowProc
            // stack). The GUI thread then hangs in SleepConditionVariableSRW
            // forever.
            //
            // The hang needs focus to move between HWNDs that each carry an
            // AccWrap, which never happens in a terminal that draws all of
            // its panes into one HWND (WezTerm, for example). With one child
            // HWND per surface, the chain is broken at its source instead:
            // returning 0 for OBJID_CLIENT keeps oleacc from creating
            // AccWraps for surface windows. Terminal cells are not exposed
            // to accessibility tools anyway, so this only drops the generic
            // window-frame proxy that screen readers would otherwise see.
            if (w32.objectId(lparam) == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_SETCONTEXT => {
            // The composition (preedit) is rendered inline in the terminal
            // by the core, so tell the system not to show the default
            // floating composition window. The IME candidate list is
            // unaffected and still anchors to ImmSetCompositionWindow.
            const cleared = lparam & ~w32.ISC_SHOWUICOMPOSITIONWINDOW;
            return w32.DefWindowProcW(hwnd, msg, wparam, cleared);
        },

        w32.WM_IME_REQUEST => {
            return surface.handleImeRequest(wparam, lparam) orelse w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_STARTCOMPOSITION => {
            surface.handleImeStartComposition();
            // Consume: we draw the composition inline; no default window.
            return 0;
        },

        w32.WM_IME_COMPOSITION => {
            // Handles both intermediate preedit (GCS_COMPSTR, mirrored
            // inline) and the final result string (GCS_RESULTSTR, committed
            // to the terminal). Always consume so DefWindowProc doesn't
            // generate WM_IME_CHAR or draw a default composition window.
            _ = surface.handleImeComposition(lparam);
            return 0;
        },

        w32.WM_IME_ENDCOMPOSITION => {
            surface.handleImeEndComposition();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONDOWN => {
            // Take keyboard focus on click. WS_CHILD windows don't
            // auto-focus the way top-level windows do, so without this
            // an active sibling popup edit (tab rename, search, palette)
            // keeps focus and the click never commits/dismisses it.
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.left, .press, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            surface.handleMouseButton(.left, .release, lparam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.right, .press, lparam);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            surface.handleMouseButton(.right, .release, lparam);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.middle, .press, lparam);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            surface.handleMouseButton(.middle, .release, lparam);
            return 0;
        },
        w32.WM_XBUTTONDOWN => {
            // X1 = back (button eight), X2 = forward (button nine), as in
            // the GTK and macOS apprts. Deliver to the terminal for mouse
            // reporting instead of the shell navigation.
            _ = w32.SetFocus(hwnd);
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .nine else .eight;
            surface.handleMouseButton(btn, .press, lparam);
            return 1; // TRUE: handled; suppresses the default WM_APPCOMMAND.
        },
        w32.WM_XBUTTONUP => {
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .nine else .eight;
            surface.handleMouseButton(btn, .release, lparam);
            return 1;
        },

        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            surface.handleMouseLeave();
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam, lparam, .vertical);
            return 0;
        },

        w32.WM_MOUSEHWHEEL => {
            surface.handleMouseWheel(wparam, lparam, .horizontal);
            // TRUE: some mouse drivers (Logitech) send the following tilt
            // messages only to windows that answer TRUE.
            return 1;
        },

        w32.WM_DROPFILES => {
            surface.handleDropFiles(wparam);
            return 0;
        },

        w32.WM_SETCURSOR => {
            // Only override the cursor in the client area. For non-client
            // areas (resize borders, title bar), let DefWindowProc handle it.
            const hit_test: u16 = @intCast(lparam & 0xFFFF);
            if (hit_test == w32.HTCLIENT and surface.handleSetCursor()) {
                return 1; // TRUE = we set the cursor
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => {
            // The pane becomes the focused one of the tab that holds it,
            // which is not necessarily the active tab.
            _ = surface.parent_window.setActiveSurface(surface);
            surface.handleFocus(true);
            return 0;
        },
        w32.WM_KILLFOCUS => {
            surface.handleFocus(false);
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Window procedure for the message-only HWND (GhosttyMsg class).
/// GWLP_USERDATA stores an *App pointer.
fn msgWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    if (app.drop_closing) {
        if (msg == WM_APP_EXPORT_TERMINAL_IO) {
            const request: *TerminalIoExport = @ptrFromInt(@as(usize, @bitCast(lparam)));
            request.destroy(app.core_app.alloc);
        } else if (msg == WM_APP_OPEN_LINK) {
            const request: *LinkRequest = @ptrFromInt(@as(usize, @bitCast(lparam)));
            request.destroy(app.core_app.alloc);
        }
        return 0;
    }

    if (msg == WM_APP_WAKEUP) {
        // Cleared before the tick: what is pushed during it wakes again.
        _ = app.wakeup_pending.swap(false, .acq_rel);
        app.tick();
        return 0;
    }

    if (msg == WM_APP_QUIT) {
        app.confirmQuit();
        return 0;
    }

    if (msg == WM_APP_IPC) {
        app.onIpc();
        return 0;
    }

    if (msg == WM_APP_DROP) {
        app.onDrop();
        return 0;
    }

    if (msg == WM_APP_DROP_REAP) {
        // Wake the outer loop; never revoke COM while nested dispatch still
        // holds borrowed model pointers.
        return 0;
    }

    if (msg == WM_APP_DROP_REGISTER) return 0;
    if (msg == ShellIntegration.wake_message) return 0;
    if (msg == DropBridge.wake_message) return 0;
    if (msg == DropCompanion.wake_message) return 0;
    if (msg == RemoteCoordinator.wake_message or (msg == w32.WM_TIMER and wparam == RemoteCoordinator.timer_id)) return 0;
    if (msg == w32.WM_TIMER and wparam == ShellIntegration.server_timer) {
        _ = w32.KillTimer(hwnd, ShellIntegration.server_timer);
        // KillTimer cannot retract a WM_TIMER already queued before activation.
        // In particular, its dispatch inside a result dialog must not quit it.
        if (!app.shell.serverTimeoutShouldQuit()) return 0;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }

    if (msg == Uia.wake_message) {
        app.onUia();
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == SESSION_TIMER_ID) {
        _ = w32.KillTimer(hwnd, SESSION_TIMER_ID);
        app.session_save_ready = true;
        return 0;
    }

    if (msg == w32.WM_HOTKEY) {
        app.onHotkey(wparam);
        return 0;
    }

    if (msg == WM_APP_DEFERRED_GX) {
        app.onDeferredGx(wparam, lparam);
        return 0;
    }

    if (msg == WM_APP_EXPORT_TERMINAL_IO) {
        app.saveTerminalIo(@ptrFromInt(@as(usize, @bitCast(lparam))));
        return 0;
    }

    if (msg == WM_APP_OPEN_LINK) {
        app.onLinkRequest(@ptrFromInt(@as(usize, @bitCast(lparam))));
        return 0;
    }

    if (msg == WM_APP_TRAY) {
        // wparam = uID, lparam = NIN_* event. We only act on
        // NIN_BALLOONUSERCLICK on the desktop notification.
        const event: u32 = @intCast(lparam & 0xFFFF);
        if (wparam == NOTIF_DESKTOP_UID and event == w32.NIN_BALLOONUSERCLICK) {
            _ = app.presentReference(app.notif_desktop_reference);
            return 0;
        }
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        // KillTimer cannot remove an already queued WM_TIMER. New local or
        // remote windows may have cancelled this shutdown in the meantime.
        if (app.quit_timer_state != .active or app.remote.keepsAlive() or (if (app.drop_companion) |companion| companion.keepsAlive() else false)) {
            app.stopQuitTimer();
            return 0;
        }
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }

    // Timer ID 3: quick terminal animation tick.
    if (msg == w32.WM_TIMER and wparam == QuickTerminal.ANIM_TIMER_ID) {
        if (app.quick_terminal) |qt| qt.onAnimationTick();
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == SHORTCUT_PROBE_TIMER_ID) {
        _ = w32.KillTimer(hwnd, SHORTCUT_PROBE_TIMER_ID);
        app.probeShortcuts();
        // The configuration errors of the start, once the window is up.
        app.reportConfigDiagnostics(.now);
        return 0;
    }

    // Notification icon cleanup timer.
    if (msg == w32.WM_TIMER and wparam == NOTIF_DESKTOP_TIMER_ID) {
        app.removeNotificationIcon();
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == PROGRESS_TIMER_ID) {
        app.onProgressTimer();
        return 0;
    }

    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test {
    std.testing.refAllDecls(@This());
}

test "runtime references resolve only live windows in this app epoch" {
    const testing = std.testing;
    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = undefined, .default_command_arena = undefined, .ui_ids = try gx.ui_ref.Issuer.init(123) };
    defer app.windows.deinit(testing.allocator);
    var window: Window = .{ .app = &app, .ui_reference = try app.ui_ids.create(.window) };
    const reference = window.ui_reference;
    try testing.expect(app.resolveWindow(reference) == null);
    try app.windows.append(testing.allocator, &window);
    try testing.expect(app.resolveWindow(reference) == &window);
    try testing.expect(app.resolveWindow(.{}) == null);
    var stale = reference;
    stale.generation += 1;
    try testing.expect(app.resolveWindow(stale) == null);
    stale = reference;
    stale.kind = .tab;
    try testing.expect(app.resolveWindow(stale) == null);
    window.closing = true;
    try testing.expect(app.resolveWindow(reference) == null);
    window.closing = false;
    app.ui_ids.epoch += 1;
    try testing.expect(app.resolveWindow(reference) == null);
}

test "runtime references reject unready disposed and reused core surfaces" {
    const testing = std.testing;
    var core_app: CoreApp = undefined;
    core_app.surfaces = .empty;
    defer core_app.surfaces.deinit(testing.allocator);
    var app: App = .{ .core_app = &core_app, .config = undefined, .hinstance = undefined, .default_command_arena = undefined, .ui_ids = try gx.ui_ref.Issuer.init(123) };
    var window: Window = .{ .app = &app, .ui_reference = try app.ui_ids.create(.window) };
    var surface: Surface = .{ .app = &app, .parent_window = &window, .ui_reference = try app.ui_ids.surface(42) };
    surface.core_surface.id = 42;
    const reference = surface.ui_reference;
    try core_app.surfaces.append(testing.allocator, &surface);
    try testing.expect(app.resolveSurface(reference) == null);
    surface.core_surface_initialized = true;
    surface.core_surface_ready = true;
    try testing.expect(app.resolveSurface(reference) == &surface);
    try testing.expect(app.resolveSurface(window.ui_reference) == null);
    window.closing = true;
    try testing.expect(app.resolveSurface(reference) == null);
    window.closing = false;
    surface.ui_reference = try app.ui_ids.surface(42);
    try testing.expect(app.resolveSurface(reference) == null);
    try testing.expect(app.resolveSurface(surface.ui_reference) == &surface);
    surface.core_surface_ready = false;
    try testing.expect(app.resolveSurface(surface.ui_reference) == null);
    surface.core_surface_ready = true;
    app.ui_ids.epoch += 1;
    try testing.expect(app.resolveSurface(surface.ui_reference) == null);
}

test "export terminal IO requires a surface target" {
    var app: App = undefined;
    try std.testing.expect(!app.exportTerminalIo(.app, "test contents"));
}

test "shutdown request drain handles quit and already dequeued owned payloads" {
    const Worker = struct {
        fn run(result: *?anyerror) void {
            check() catch |err| {
                result.* = err;
            };
        }

        fn check() !void {
            const testing = std.testing;
            const alloc = testing.allocator;
            const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
            const hwnd = w32.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.TestWindowFailed;
            defer _ = w32.DestroyWindow(hwnd);
            defer discardQueuedRequests(alloc, hwnd);

            // A queued quit bypasses the filter even without any payloads.
            w32.PostQuitMessage(0);
            var pending: w32.MSG = undefined;
            try testing.expect(w32.PeekMessageW(&pending, hwnd, WM_APP_EXPORT_TERMINAL_IO, WM_APP_EXPORT_TERMINAL_IO, 0) != 0);
            try testing.expectEqual(w32.WM_QUIT, pending.message);
            discardQueuedRequests(alloc, hwnd);

            for ([_]?u32{ null, WM_APP_EXPORT_TERMINAL_IO, WM_APP_OPEN_LINK }) |dequeued| {
                {
                    const request = try alloc.create(TerminalIoExport);
                    errdefer alloc.destroy(request);
                    request.* = .{ .surface_ref = .{}, .contents = try alloc.dupe(u8, "pending terminal output") };
                    errdefer alloc.free(request.contents);
                    try testing.expect(w32.PostMessageW(hwnd, WM_APP_EXPORT_TERMINAL_IO, 0, @bitCast(@intFromPtr(request))) != 0);
                }
                {
                    const request = try alloc.create(LinkRequest);
                    errdefer alloc.destroy(request);
                    request.* = .{ .surface_ref = null, .decision = .allow, .url = try alloc.dupe(u8, "https://example.com") };
                    errdefer alloc.free(request.url);
                    try testing.expect(w32.PostMessageW(hwnd, WM_APP_OPEN_LINK, 0, @bitCast(@intFromPtr(request))) != 0);
                }
                // Model run's quit branch with either owned message already
                // removed. The queue drain must free only the other one.
                if (dequeued) |message| {
                    try testing.expect(w32.GetMessageW(&pending, hwnd, message, message) > 0);
                    discardOwnedRequest(alloc, hwnd, &pending);
                }
                try testing.expect(w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 1) != 0);
                w32.PostQuitMessage(0);
                discardQueuedRequests(alloc, hwnd);
                try testing.expect(w32.PeekMessageW(&pending, hwnd, WM_APP_OPEN_LINK, WM_APP_EXPORT_TERMINAL_IO, w32.PM_REMOVE) == 0);
                // Ordinary messages remain queued and have no owned payload.
                try testing.expect(w32.PeekMessageW(&pending, hwnd, WM_APP_WAKEUP, WM_APP_WAKEUP, w32.PM_REMOVE) != 0);
                try testing.expectEqual(WM_APP_WAKEUP, pending.message);
                discardOwnedRequest(alloc, hwnd, &pending);
                // Quit has lower priority than the ordinary queued message.
                discardQueuedRequests(alloc, hwnd);
                try testing.expect(w32.PeekMessageW(&pending, hwnd, WM_APP_OPEN_LINK, WM_APP_EXPORT_TERMINAL_IO, w32.PM_REMOVE) == 0);
            }
        }
    };
    // Quit belongs to a thread's queue, so never disturb the test runner's.
    var result: ?anyerror = null;
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&result});
    worker.join();
    if (result) |err| return err;
}

test "runtime tab locations follow objects while old owner views stay inert" {
    const testing = std.testing;
    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = undefined, .default_command_arena = undefined, .ui_ids = try gx.ui_ref.Issuer.init(123) };
    defer app.windows.deinit(testing.allocator);
    var source: Window = .{ .app = &app, .ui_reference = try app.ui_ids.create(.window), .tab_count = 1 };
    var destination: Window = .{ .app = &app, .ui_reference = try app.ui_ids.create(.window) };
    try app.windows.append(testing.allocator, &source);
    try app.windows.append(testing.allocator, &destination);
    source.ui_attachment = try app.ui_ids.attach(source.ui_reference, source.ui_reference);
    const root = source.ui_attachment;
    try testing.expect(app.resolveWindowView(root) == &source);
    source.tab_references[0] = try app.ui_ids.create(.tab);
    source.tab_attachments[0] = try app.ui_ids.attach(source.tab_references[0], source.ui_reference);
    const tab = source.tab_references[0];
    const old_view = source.tab_attachments[0];
    try testing.expect(app.resolveTab(tab).?.window == &source);
    try testing.expect(app.resolveTabView(old_view).?.window == &source);
    destination.tab_count = 1;
    destination.tab_references[0] = tab;
    destination.tab_attachments[0] = try app.ui_ids.attach(tab, destination.ui_reference);
    source.tab_count = 0;
    try testing.expect(app.resolveTab(tab).?.window == &destination);
    try testing.expect(app.resolveTabView(old_view) == null);
    const moved = destination.tab_attachments[0];
    try testing.expectEqual(@as(usize, 0), app.resolveTabView(moved).?.index);
    try destination.tab_attachments[0].setVisible(&app.ui_ids, tab, destination.ui_reference, false);
    try testing.expect(app.resolveTab(tab) != null);
    try testing.expect(app.resolveTabView(moved) == null);
    try destination.tab_attachments[0].setVisible(&app.ui_ids, tab, destination.ui_reference, true);
    try testing.expect(app.resolveTabView(moved) == null);
    destination.closing = true;
    try testing.expect(app.resolveTab(tab) == null);
    source.ui_attachment = .{};
    try testing.expect(app.resolveWindow(source.ui_reference) == &source);
    try testing.expect(app.resolveWindowView(root) == null);
    app.ui_ids.epoch = 0;
    try testing.expect(app.resolveWindow(source.ui_reference) == null);
}

test "OLE outer-loop retirement revokes before destroying registered child and parent" {
    const testing = std.testing;
    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = undefined, .default_command_arena = undefined };
    var apartment = ComApartment.init();
    defer apartment.deinit() catch {};
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const parent = w32.CreateWindowExW(0, class, class, 0, 0, 0, 32, 32, null, null, null, null) orelse return error.TestWindowFailed;
    defer if (w32.IsWindow(parent) != 0) {
        _ = w32.DestroyWindow(parent);
    };
    const child = w32.CreateWindowExW(0, class, class, w32.WS_CHILD, 0, 0, 32, 32, parent, null, null, null) orelse return error.TestWindowFailed;
    var issuer = try gx.ui_ref.Issuer.init(42);
    const owner = try issuer.create(.window);
    const attachment = try issuer.attach(try issuer.surface(1), owner);
    const Callbacks = struct {
        fn live(_: *anyopaque, _: gx.ui_ref.Attachment) bool {
            return true;
        }
        fn post(_: *anyopaque, _: gx.ui_ref.Attachment, _: OleDrop.data.Payload) bool {
            return false;
        }
        fn feedback(_: *anyopaque, _: gx.ui_ref.Attachment, _: OleDrop.Phase, _: w32.POINT, _: bool) void {}
    };
    const target = try OleDrop.Target.create(testing.allocator, &apartment, child, attachment, .{
        .context = &app,
        .is_live = Callbacks.live,
        .post = Callbacks.post,
        .feedback = Callbacks.feedback,
    });
    app.retireDropTarget(target);
    try testing.expect(app.deferDropWindowDestroy(child));
    try testing.expect(app.deferDropParentDestroy(parent));
    try testing.expect(w32.IsWindow(child) != 0 and w32.IsWindow(parent) != 0);
    app.reapDropTargets();
    try testing.expect(app.retired_drop_targets == null);
    try testing.expect(w32.IsWindow(child) == 0 and w32.IsWindow(parent) == 0);
}

test "SimulatedSystemTheme packs the scheme and high contrast" {
    const testing = std.testing;
    const follow: SimulatedSystemTheme = @bitCast(@as(usize, 0));
    try testing.expect(follow.scheme == .system and follow.high_contrast == .system);
    const dark: SimulatedSystemTheme = @bitCast(@as(usize, 2));
    try testing.expect(dark.scheme == .dark and dark.high_contrast == .system);
    const light_hc: SimulatedSystemTheme = @bitCast(@as(usize, 0b0101));
    try testing.expect(light_hc.scheme == .light and light_hc.high_contrast == .on);
    const hc_off: SimulatedSystemTheme = @bitCast(@as(usize, 0b1000));
    try testing.expect(hc_off.scheme == .system and hc_off.high_contrast == .off);
    try testing.expectEqual(@as(usize, 0b0110), @as(usize, @bitCast(SimulatedSystemTheme{ .scheme = .dark, .high_contrast = .on })));
}

test "editKeyRoute keeps editing keys and unbound chords out of the shell" {
    const testing = std.testing;
    const ctrl: input.Mods = .{ .ctrl = true };
    const ctrl_shift: input.Mods = .{ .ctrl = true, .shift = true };
    const altgr: input.Mods = .{ .ctrl = true, .alt = true };

    // Typing, with or without Shift, and keys a binding may use without
    // Ctrl stay with the edit control.
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute('Q', .{}, false));
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute('Q', .{ .shift = true }, false));
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(w32.VK_INSERT, .{ .shift = true }, true));
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(w32.VK_F3, .{}, true));

    // Editing keys stay with the edit control even when bound
    // (Ctrl+Shift+V pastes, Ctrl+Shift+Left selects a word).
    for ([_]u16{ w32.VK_LEFT, w32.VK_RIGHT, w32.VK_HOME, w32.VK_END, w32.VK_BACK, w32.VK_DELETE, w32.VK_INSERT, 'A', 'C', 'V', 'X', 'Y', 'Z' }) |vk| {
        try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(vk, ctrl, true));
        try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(vk, ctrl_shift, true));
        try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(vk, ctrl_shift, false));
    }
    // So do keys for the input method and modifiers on their own.
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(w32.VK_PROCESSKEY, ctrl, false));
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(w32.VK_CONTROL, ctrl, false));
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute(w32.VK_SHIFT, ctrl_shift, false));

    // Bound chords reach the terminal's bindings.
    try testing.expectEqual(EditKeyRoute.bubble, editKeyRoute('T', ctrl_shift, true));
    try testing.expectEqual(EditKeyRoute.bubble, editKeyRoute(w32.VK_PRIOR, ctrl, true));
    try testing.expectEqual(EditKeyRoute.bubble, editKeyRoute(w32.VK_TAB, ctrl, true));

    // Unbound Ctrl chords do nothing.
    try testing.expectEqual(EditKeyRoute.swallow, editKeyRoute('Q', ctrl, false));
    try testing.expectEqual(EditKeyRoute.swallow, editKeyRoute('T', ctrl_shift, false));
    try testing.expectEqual(EditKeyRoute.swallow, editKeyRoute(w32.VK_F3, ctrl, false));

    // Ctrl+Alt is AltGr typing a character unless a binding takes it.
    try testing.expectEqual(EditKeyRoute.edit, editKeyRoute('Q', altgr, false));
    try testing.expectEqual(EditKeyRoute.bubble, editKeyRoute('Q', altgr, true));
}

test "childExitKind follows the core's abnormal exit rule" {
    const testing = std.testing;
    const threshold: u32 = 250;
    // A failed command: a nonzero exit within the threshold.
    try testing.expectEqual(ChildExitKind.abnormal, childExitKind(.{ .exit_code = 1, .runtime_ms = 20 }, threshold));
    try testing.expectEqual(ChildExitKind.abnormal, childExitKind(.{ .exit_code = 1, .runtime_ms = 250 }, threshold));
    // A command that ran, whatever its exit code (`exit 1` in a shell).
    try testing.expectEqual(ChildExitKind.normal, childExitKind(.{ .exit_code = 1, .runtime_ms = 251 }, threshold));
    try testing.expectEqual(ChildExitKind.normal, childExitKind(.{ .exit_code = 130, .runtime_ms = 60_000 }, threshold));
    // A quick but successful exit.
    try testing.expectEqual(ChildExitKind.normal, childExitKind(.{ .exit_code = 0, .runtime_ms = 5 }, threshold));
}

test "quitTimerStart ignores the call before the message loop runs" {
    const testing = std.testing;
    const none: QuitTimerStart = .none;
    // `main` starts the quit timer before `run`: no WM_QUIT, no timer.
    try testing.expectEqual(none, quitTimerStart(false, true, null));
    try testing.expectEqual(none, quitTimerStart(false, true, 500));
    // The last terminal closed.
    try testing.expectEqual(@as(QuitTimerStart, .quit), quitTimerStart(true, true, null));
    try testing.expectEqual(@as(QuitTimerStart, .{ .timer = 500 }), quitTimerStart(true, true, 500));
    try testing.expectEqual(none, quitTimerStart(true, false, null));
    try testing.expectEqual(none, quitTimerStart(true, false, 500));
}

test "toast server watchdog ignores queued timeout after activation" {
    var shell: ShellIntegration = .{ .startup = .toast_server };
    try std.testing.expect(shell.serverTimeoutShouldQuit());
    shell.activationReceived(null);
    try std.testing.expect(!shell.serverTimeoutShouldQuit());
    // A second callback cannot rearm the watchdog while its result is visible.
    shell.activationReceived(null);
    try std.testing.expect(!shell.serverTimeoutShouldQuit());
}

test "toast server watchdog does not affect ordinary warm instances" {
    var shell: ShellIntegration = .{};
    try std.testing.expect(!shell.serverTimeoutShouldQuit());
    shell.activationReceived(null);
    try std.testing.expect(!shell.server_activation_received);
    try std.testing.expect(!shell.serverTimeoutShouldQuit());
}

test "ending key hints preserves another terminal, table and action feedback" {
    var window: Window = .{ .app = undefined };
    var other_window: Window = .{ .app = undefined };
    var surface: Surface = .{ .app = undefined, .parent_window = &window, .key_sequence_len = 4 };
    var other: Surface = .{ .app = undefined, .parent_window = &other_window, .key_sequence_len = 7 };
    surface.core_surface.id = 1;
    other.core_surface.id = 2;
    window.toast = .{ .pending = true, .owner = .{ .surface_id = 1, .kind = .sequence } };
    showKeySequence(&other, .end);
    try std.testing.expectEqual(@as(usize, 4), surface.key_sequence_len);
    try std.testing.expectEqual(@as(usize, 0), other.key_sequence_len);
    try std.testing.expect(window.toast.pending);
    showKeyTable(&surface, .deactivate_all);
    try std.testing.expect(window.toast.pending);
    showKeySequence(&surface, .end);
    try std.testing.expect(!window.toast.pending);

    window.toast = .{ .pending = true, .owner = .{ .surface_id = 1, .kind = .table } };
    showKeySequence(&surface, .end);
    try std.testing.expect(window.toast.pending);
    showKeyTable(&surface, .deactivate);
    try std.testing.expect(!window.toast.pending);
    window.toast = .{ .pending = true, .icon = d2d.icons.copy };
    showKeySequence(&surface, .end);
    showKeyTable(&surface, .deactivate_all);
    try std.testing.expect(window.toast.pending);
}

test "simulatedTheme decodes the test hook and rejects invalid values" {
    const testing = std.testing;
    const follow = simulatedTheme(0).?;
    try testing.expectEqual(@as(?apprt.ColorScheme, null), follow.scheme);
    try testing.expectEqual(@as(?bool, null), follow.high_contrast);
    const dark_hc = simulatedTheme(@bitCast(SimulatedSystemTheme{ .scheme = .dark, .high_contrast = .on })).?;
    try testing.expectEqual(@as(?apprt.ColorScheme, .dark), dark_hc.scheme);
    try testing.expectEqual(@as(?bool, true), dark_hc.high_contrast);
    const light_off = simulatedTheme(@bitCast(SimulatedSystemTheme{ .scheme = .light, .high_contrast = .off })).?;
    try testing.expectEqual(@as(?apprt.ColorScheme, .light), light_off.scheme);
    try testing.expectEqual(@as(?bool, false), light_off.high_contrast);
    // The unused values of each field and the reserved bits.
    try testing.expect(simulatedTheme(0b0011) == null);
    try testing.expect(simulatedTheme(0b1100) == null);
    try testing.expect(simulatedTheme(0b1_0000) == null);
}

test "diagnosticsText lists the first configuration errors and counts the rest" {
    const testing = std.testing;
    var diagnostics: [5]cli.Diagnostic = undefined;
    for (&diagnostics, 0..) |*diagnostic, i| diagnostic.* = .{
        .location = .{ .file = .{ .path = "C:\\cfg\\config.ghostty", .line = i + 1 } },
        .key = "font-size",
        .message = "invalid value",
    };
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\cfg\\config.ghostty:1:font-size: invalid value",
        diagnosticsText(&buf, diagnostics[0..1], "…and {count} more."),
    );
    try testing.expectEqualStrings(
        "C:\\cfg\\config.ghostty:1:font-size: invalid value\n" ++
            "C:\\cfg\\config.ghostty:2:font-size: invalid value\n" ++
            "C:\\cfg\\config.ghostty:3:font-size: invalid value\n" ++
            "…and 2 more.",
        diagnosticsText(&buf, &diagnostics, "…and {count} more."),
    );
    // Cut to the buffer.
    var small: [16]u8 = undefined;
    const cut = diagnosticsText(&small, &diagnostics, "…and {count} more.");
    try testing.expect(cut.len <= small.len);
    try testing.expect(std.mem.startsWith(u8, "C:\\cfg\\config.ghostty:1:", cut));
    try testing.expectEqualStrings("", diagnosticsText(&buf, &.{}, "…and {count} more."));
}

test "taskbarValue shows the merged progress on the taskbar button" {
    const testing = std.testing;
    const none = taskbarValue(.none);
    try testing.expectEqual(w32.TBPF_NOPROGRESS, none.state);
    try testing.expectEqual(@as(?u8, null), none.percent);
    try testing.expectEqual(w32.TBPF_INDETERMINATE, taskbarValue(.{ .state = .indeterminate, .percent = 40 }).state);
    try testing.expectEqual(@as(?u8, null), taskbarValue(.{ .state = .indeterminate, .percent = 40 }).percent);
    try testing.expectEqual(TaskbarValue{ .state = w32.TBPF_NORMAL, .percent = 40 }, taskbarValue(.{ .state = .normal, .percent = 40 }));
    // A bar without a value: empty while running, full and colored when
    // paused or failed.
    try testing.expectEqual(TaskbarValue{ .state = w32.TBPF_NORMAL, .percent = 0 }, taskbarValue(.{ .state = .normal }));
    try testing.expectEqual(TaskbarValue{ .state = w32.TBPF_PAUSED, .percent = 100 }, taskbarValue(.{ .state = .paused }));
    try testing.expectEqual(TaskbarValue{ .state = w32.TBPF_ERROR, .percent = 100 }, taskbarValue(.{ .state = .@"error" }));
    try testing.expectEqual(TaskbarValue{ .state = w32.TBPF_ERROR, .percent = 7 }, taskbarValue(.{ .state = .@"error", .percent = 7 }));
}

test "restoreTrailingBackslash repairs quoted drive roots" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `--working-directory="C:\"` arrives as `C:"`.
    try testing.expectEqualStrings("C:\\", (try restoreTrailingBackslash(alloc, "C:\"")).?);
    try testing.expectEqualStrings("D:\\My Files\\", (try restoreTrailingBackslash(alloc, "D:\\My Files\"")).?);
    try testing.expectEqualStrings("\\\\server\\share\\", (try restoreTrailingBackslash(alloc, "\\\\server\\share\"")).?);
    try testing.expectEqualStrings("C:\\", (try restoreTrailingBackslash(alloc, "C:\\\"\"")).?);

    try testing.expectEqual(null, try restoreTrailingBackslash(alloc, "C:\\"));
    try testing.expectEqual(null, try restoreTrailingBackslash(alloc, "C:\\Users\\me"));
    try testing.expectEqual(null, try restoreTrailingBackslash(alloc, "\""));
    try testing.expectEqual(null, try restoreTrailingBackslash(alloc, ""));
}

test "validWindowsPath rejects characters file names cannot contain" {
    const testing = std.testing;
    try testing.expect(validWindowsPath("C:\\"));
    try testing.expect(validWindowsPath("D:\\My Files\\项目"));
    try testing.expect(validWindowsPath("\\\\?\\C:\\Users\\me"));
    try testing.expect(validWindowsPath("~/projects"));
    try testing.expect(!validWindowsPath("C:\""));
    try testing.expect(!validWindowsPath("C:\\a\"b"));
    try testing.expect(!validWindowsPath("C:\\a|b"));
    try testing.expect(!validWindowsPath("C:\\*"));
    try testing.expect(!validWindowsPath("C:\\a\nb"));
}

test "quick terminal tab profiles are rejected before shell detection" {
    var app: App = undefined;
    var window: Window = .{ .app = &app, .is_quick_terminal = true };
    try std.testing.expect(!app.openProfile(&window, "cmd", .tab));
    try std.testing.expect(!app.performGx(&window, .{ .new_tab_profile = "cmd" }));
}

test "D11: native wakeup dispatch drains the GUI snapshot and rearms" {
    const testing = std.testing;
    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;
    core_app.mailbox = .{};
    core_app.surfaces = .empty;
    defer core_app.surfaces.deinit(testing.allocator);
    var app: App = undefined;
    app.core_app = &core_app;
    app.wakeup_pending = .init(false);
    app.msg_hwnd = null;
    var surface: Surface = .{ .app = &app, .core_surface_ready = true };
    const core_surface = &surface.core_surface;
    core_surface.io.terminal = try @import("../../terminal/main.zig").Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
    defer core_surface.io.terminal.deinit(testing.allocator);
    for (0..99) |_| try core_surface.io.terminal.linefeed();
    var mutex: std.Io.Mutex = .init;
    core_surface.renderer_state = .{ .mutex = &mutex, .terminal = &core_surface.io.terminal };
    core_surface.rt_surface = &surface;
    core_surface.io.renderer_state = &core_surface.renderer_state;
    core_surface.io.surface_mailbox = .{ .surface = core_surface, .app = undefined };
    surface.scrollbar_activity.setAccepting(true);
    try core_app.surfaces.append(testing.allocator, &surface);
    const class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyD11WakeTest");
    var wc = std.mem.zeroes(w32.WNDCLASSEXW);
    wc.cbSize = @sizeOf(w32.WNDCLASSEXW);
    wc.lpfnWndProc = msgWndProc;
    wc.lpszClassName = class;
    try testing.expect(w32.RegisterClassExW(&wc) != 0);
    const hwnd = w32.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);
    app.msg_hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&app)));
    for ([_]isize{ -1, 1 }) |delta| {
        const scroll: @import("../../terminal/main.zig").Terminal.ScrollViewport = .{ .delta = delta };
        const worker = try std.Thread.spawn(.{}, @import("../../termio.zig").Termio.scrollViewport, .{ &core_surface.io, scroll });
        worker.join();
        try testing.expect(app.wakeup_pending.load(.acquire));
        var msg: w32.MSG = undefined;
        try testing.expect(w32.PeekMessageW(&msg, hwnd, WM_APP_WAKEUP, WM_APP_WAKEUP, w32.PM_REMOVE) != 0);
        _ = w32.DispatchMessageW(&msg);
        try testing.expect(!app.wakeup_pending.load(.acquire));
        try testing.expect(!surface.scrollbar_activity.pending);
        try testing.expectEqual(@as(usize, if (delta < 0) 75 else 76), surface.scrollbar_state.offset);
        try testing.expect(w32.PeekMessageW(&msg, hwnd, WM_APP_WAKEUP, WM_APP_WAKEUP, w32.PM_REMOVE) == 0);
    }
}

/// Visible model only: hidden source hosts are never target-side UI contexts.
pub fn resolveLeaf(self: *App, reference: gx.ui_ref.Reference) ?*Leaf {
    for (self.windows.items) |window| if (window.leafForPane(reference)) |leaf| return leaf;
    if (self.quick_terminal) |quick| return quick.window.leafForPane(reference);
    return null;
}
pub fn resolveRemote(self: *App, reference: gx.ui_ref.Reference) ?*RemotePane {
    return (self.resolveLeaf(reference) orelse return null).remote();
}
pub fn resolvePaneView(self: *App, attachment: gx.ui_ref.Attachment) ?@import("Pane.zig") {
    const leaf = self.resolveLeaf(attachment.object) orelse return null;
    if (!attachment.matches(leaf.attachment())) return null;
    return leaf.pane();
}
pub const VisiblePaneIterator = struct {
    app: *App,
    window: usize = 0,
    iterator: Window.PaneIterator = .{},
    pub fn next(self: *VisiblePaneIterator) ?@import("Pane.zig") {
        while (true) {
            while (self.iterator.next()) |pane| {
                const hwnd = pane.nativeHandle() orelse continue;
                if (pane.attachment().isValid() and w32.IsWindowVisible_(hwnd) != 0) return pane;
            }
            if (self.window > self.app.windows.items.len) return null;
            const owner = if (self.window < self.app.windows.items.len) self.app.windows.items[self.window] else if (self.app.quick_terminal) |quick| quick.window else return null;
            self.window += 1;
            if (owner.closing or owner.is_remote_host or owner.tab_count == 0) continue;
            const hwnd = owner.hwnd orelse continue;
            if (w32.IsIconic(hwnd) != 0 or w32.IsWindowVisible_(hwnd) == 0) continue;
            self.iterator = owner.paneIterator(owner.active_tab);
        }
    }
};

pub fn visiblePanes(self: *App) VisiblePaneIterator {
    return .{ .app = self };
}

fn dispatchRemoteUia(self: *App, action: *const Uia.Action) bool {
    var iterator = self.visiblePanes();
    while (iterator.next()) |pane| switch (pane.backend) {
        .local => {},
        .remote => |remote| if (remote.ui.accessibility.dispatch(self, remote, action)) return true,
    };
    return false;
}

/// Target-owned app actions preserve actual execution results. Close-all and
/// Quit require the coordinator's asynchronous close receipts, never queue ACK.
pub fn performRemoteAppAction(self: *App, action: input.Binding.Action) !bool {
    switch (action) {
        .ignore => return true,
        .new_window => {
            const window = try self.newWindow(.{});
            _ = window.addTabWithOptions(.{ .context = .window }) catch |err| {
                self.discardSessionWindow(window.ui_reference);
                return err;
            };
            return true;
        },
        .open_config => |mode| return self.openConfigFile(switch (mode) {
            .os_open => .os_open,
            .new_window => .new_window,
        }),
        .reload_config => return self.performAction(.app, .reload_config, .{}),
        .toggle_quick_terminal => {
            try self.toggleQuickTerminal();
            return true;
        },
        .toggle_visibility => {
            self.toggleVisibility();
            return self.windows.items.len != 0;
        },
        .check_for_updates, .show_gtk_inspector, .undo, .redo => return false,
        .quit, .close_all_windows => return false,
        else => return false,
    }
}
