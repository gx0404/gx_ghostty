// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const file_log = @import("win32/file_log.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    _ = @import("win32/shortcut_conflicts.zig");
    _ = @import("win32/ui/Keybinds.zig");
    _ = @import("win32/ui/trigger.zig");
    _ = @import("win32/ui/fuzzy.zig");
    _ = @import("win32/ui/MenuPopup.zig");
    _ = @import("win32/ui/settings/fuzzy.zig");
    _ = @import("win32/ui/settings/swatch.zig");
    _ = @import("win32/ui/settings/system.zig");
}
