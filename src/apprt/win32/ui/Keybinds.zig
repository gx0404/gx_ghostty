//! The keyboard shortcut sheet. Opened by `gx:keybinds` and the main
//! menu's Keyboard Shortcuts item through `show`.
//!
//! Placeholder: until the sheet exists, `show` opens the command palette of
//! the window's active terminal, which lists the commands with their
//! shortcuts. The sheet replaces the body of `show` and keeps its
//! signature, so the call sites stay unchanged.
const Window = @import("../Window.zig");

/// Show the keyboard shortcuts for `window`. Returns false if nothing was
/// shown.
pub fn show(window: *Window) bool {
    const surface = window.getActiveSurface() orelse return false;
    surface.palette.setActive(true);
    return true;
}
