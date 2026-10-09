//! The Ghostty GX layer of the GTK apprt (fork patch GX-0011), on top of
//! the shared core in `src/gx`: the UI language at startup and at runtime,
//! the GX menus with launch profiles, the keyboard shortcuts cheat sheet
//! and the handler of the `gx:` binding actions. The settings dialog
//! (`settings_dialog.zig`, GX-0015), herdr app mode and the GX look
//! (`app_mode.zig` and `style.zig`, GX-0016) live next to these modules
//! and are imported by their own hooks. Upstream GTK files only call into
//! these modules from small marked hooks.
pub const app = @import("app.zig");
pub const language = @import("language.zig");
pub const launch = @import("launch.zig");
pub const menus = @import("menus.zig");
pub const shortcuts = @import("shortcuts.zig");
pub const shortcuts_dialog = @import("shortcuts_dialog.zig");
pub const window = @import("window.zig");

test {
    _ = app;
    _ = language;
    _ = launch;
    _ = menus;
    _ = shortcuts;
    _ = shortcuts_dialog;
    _ = window;
}
