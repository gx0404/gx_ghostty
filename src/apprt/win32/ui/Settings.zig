//! The Ghostty GX settings UI. Opened by `gx:settings`, the main menu's
//! Settings… item and `open_config` when `gx-open-config-ui = settings`
//! (the default); all of them call `show`.
//!
//! Placeholder: until the settings overlay exists, `show` opens the
//! configuration file with the Windows file association, as `open_config`
//! does with `gx-open-config-ui = editor`. The overlay replaces the body of
//! `show` and keeps its signature, so the call sites stay unchanged.
const std = @import("std");
const Window = @import("../Window.zig");

const log = std.log.scoped(.win32);

/// Show the settings for `window`. Returns false if nothing was shown.
pub fn show(window: *Window) bool {
    return window.app.openConfigFile(.os_open) catch |err| {
        log.err("failed to open the configuration file err={}", .{err});
        return false;
    };
}
