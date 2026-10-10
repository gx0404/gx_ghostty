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
    _ = @import("win32/App.zig");
    _ = @import("win32/Scrollbar.zig");
    _ = @import("win32/Surface.zig");
    _ = @import("win32/Window.zig");
    _ = @import("win32/chrome/Backdrop.zig");
    _ = @import("win32/chrome/TabBar.zig");
    _ = @import("win32/chrome/caption_layout.zig");
    _ = @import("win32/clipboard.zig");
    _ = @import("win32/shortcut_conflicts.zig");
    _ = @import("win32/splits.zig");
    _ = @import("win32/tab_status.zig");
    _ = @import("win32/tabs.zig");
    _ = @import("win32/win32.zig");
    _ = @import("win32/ui/Dialogs.zig");
    _ = @import("win32/ui/Notice.zig");
    _ = @import("win32/ui/Palette.zig");
    _ = @import("win32/ui/Popup.zig");
    _ = @import("win32/ui/Toast.zig");
    _ = @import("win32/ui/anim.zig");
    _ = @import("win32/ui/controls.zig");
    _ = @import("win32/ui/d2d.zig");
    _ = @import("win32/ui/style.zig");
    _ = @import("win32/ui/text_edit.zig");
    _ = @import("win32/ui/wstr.zig");
    _ = @import("win32/ui/Keybinds.zig");
    _ = @import("win32/ui/trigger.zig");
    _ = @import("win32/ui/fuzzy.zig");
    _ = @import("win32/ui/Menu.zig");
    _ = @import("win32/ui/MenuPopup.zig");
    _ = @import("win32/ui/settings/fuzzy.zig");
    _ = @import("win32/ui/settings/hit_test.zig");
    _ = @import("win32/ui/settings/swatch.zig");
    _ = @import("win32/ui/settings/system.zig");
    _ = @import("win32/ui/palette_model.zig");
}
