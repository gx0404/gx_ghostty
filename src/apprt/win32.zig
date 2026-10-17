// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const file_log = @import("win32/file_log.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;

// Every file below win32/ that declares tests is imported here, so its tests
// run even when no other code analyzes it (scripts/test_gx_test_roots.py).
test {
    _ = @import("../renderer/opengl/wgl.zig");
    _ = @import("win32/App.zig");
    _ = @import("win32/BellAudio.zig");
    _ = @import("win32/ComApartment.zig");
    _ = @import("win32/bell_wav.zig");
    _ = @import("win32/Scrollbar.zig");
    _ = @import("win32/Surface.zig");
    _ = @import("win32/Session.zig");
    _ = @import("win32/shell/Identity.zig");
    _ = @import("win32/shell/ToastActivation.zig");
    _ = @import("win32/shell/WinRTToast.zig");
    _ = @import("win32/shell/JumpList.zig");
    _ = @import("win32/Window.zig");
    _ = @import("win32/chrome/Backdrop.zig");
    _ = @import("win32/chrome/TabBar.zig");
    _ = @import("win32/chrome/alpha.zig");
    _ = @import("win32/chrome/caption_layout.zig");
    _ = @import("win32/clipboard.zig");
    _ = @import("win32/ipc/Security.zig");
    _ = @import("win32/ipc/wire.zig");
    _ = @import("win32/ipc/Instance.zig");
    _ = @import("win32/ipc/environment.zig");
    _ = @import("win32/ipc/remote_frame.zig");
    _ = @import("win32/ipc/RemoteChannel.zig");
    _ = @import("win32/RemoteSurfaceView.zig");
    _ = @import("win32/RemoteHost.zig");
    _ = @import("win32/RemotePane.zig");
    _ = @import("win32/RemotePaneUi.zig");
    _ = @import("win32/RemoteRuntimeUi.zig");
    _ = @import("win32/RemoteSource.zig");
    _ = @import("win32/Leaf.zig");
    _ = @import("win32/key_translate.zig");
    _ = @import("win32/ui/uia_remote.zig");
    _ = @import("win32/RemoteInput.zig");
    _ = @import("win32/RemotePerf.zig");
    _ = @import("win32/RemoteCoordinator.zig");
    _ = @import("win32/DropBridge.zig");
    _ = @import("win32/DropCompanion.zig");
    _ = @import("win32/drop_companion_launch.zig");
    _ = @import("win32/Pane.zig");
    _ = @import("win32/PaneSnapshot.zig");
    _ = @import("win32/ipc/RemoteService.zig");
    _ = @import("win32/ipc/DropBroker.zig");
    _ = @import("win32/ole_drop.zig");
    _ = @import("win32/drop_data.zig");
    _ = @import("win32/ui/DropFeedback.zig");
    _ = @import("win32/ui/uia.zig");
    _ = @import("win32/ui/uia_bridge.zig");
    _ = @import("win32/shortcut_conflicts.zig");
    _ = @import("win32/split_layout.zig");
    _ = @import("win32/splits.zig");
    _ = @import("win32/tab_status.zig");
    _ = @import("win32/tabs.zig");
    _ = @import("win32/tab_transfer.zig");
    _ = @import("win32/win32.zig");
    _ = @import("win32/ui/Dialogs.zig");
    _ = @import("win32/ui/Notice.zig");
    _ = @import("win32/ui/Palette.zig");
    _ = @import("win32/ui/Popup.zig");
    _ = @import("win32/ui/Toast.zig");
    _ = @import("win32/ui/anim.zig");
    _ = @import("win32/ui/controls.zig");
    _ = @import("win32/ui/d2d.zig");
    _ = @import("win32/ui/dcomp.zig");
    _ = @import("win32/ui/fluent_icons.zig");
    _ = @import("win32/ui/style.zig");
    _ = @import("win32/ui/text_edit.zig");
    _ = @import("win32/ui/wstr.zig");
    _ = @import("win32/ui/Keybinds.zig");
    _ = @import("win32/ui/trigger.zig");
    _ = @import("win32/ui/Menu.zig");
    _ = @import("win32/ui/MenuPopup.zig");
    _ = @import("win32/ui/settings/hit_test.zig");
    _ = @import("win32/ui/settings/system.zig");
    _ = @import("win32/open_url.zig");
    _ = @import("win32/ui/settings/model.zig");
    _ = @import("win32/ui/Settings.zig");
    _ = @import("win32/ui/settings/draw.zig");
    _ = @import("win32/QuickTerminal.zig");
    _ = @import("win32/ui/LinkPreview.zig");
    _ = @import("win32/ui/ResizeOverlay.zig");
    _ = @import("win32/ui/SearchBar.zig");
    _ = @import("win32/chrome/TitleBar.zig");
    _ = @import("win32/ui/Tooltip.zig");
    _ = @import("win32/chrome/tab_layout.zig");
    _ = @import("win32/ui/palette_model.zig");
}
