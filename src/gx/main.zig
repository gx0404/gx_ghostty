//! Ghostty GX core shared by the win32 and GTK apprts. None of these
//! modules depends on a UI toolkit or an apprt.
//!
//! - Configuration: layering of the GX defaults, the user configuration,
//!   `gui-settings.ghostty` and the command line (`config_layers`); value
//!   types of the `gx-*` keys (`config_types`); line-preserving edits of
//!   `gui-settings.ghostty`, the file the settings UIs write
//!   (`gui_settings`); the settings model that the GTK settings dialog
//!   and the Windows settings overlay render (`settings_map`); the
//!   built-in GX Mocha theme (`theme`).
//! - UI language and translations (`i18n`); the name, links and
//!   non-affiliation notice of the About surfaces (`branding`).
//! - `gx:` binding actions (`action`) and launch profiles (`profiles`).
//! - Processes: inspection (`proc`), the idle and herdr policies
//!   (`policy`), close confirmation (`confirm`) and herdr app mode
//!   (`app_mode`).
//! - The colors of the GTK look, as CSS (`gtk_css`).
//! - Windows terminal support: win32-input-mode key records
//!   (`win32_input`), the bundled ConPTY (`conpty`), OSC 7 working
//!   directories (`osc7`) and shell quoting of dropped or pasted file
//!   paths (`path_quote`).
pub const action = @import("action.zig");
pub const app_mode = @import("app_mode.zig");
pub const branding = @import("branding.zig");
pub const config_layers = @import("config_layers.zig");
pub const config_types = @import("config_types.zig");
pub const confirm = @import("confirm.zig");
pub const conpty = @import("conpty.zig");
pub const gtk_css = @import("gtk_css.zig");
pub const gui_settings = @import("gui_settings.zig");
pub const i18n = @import("i18n.zig");
pub const osc7 = @import("osc7.zig");
pub const path_quote = @import("path_quote.zig");
pub const policy = @import("policy.zig");
pub const proc = @import("proc.zig");
pub const profiles = @import("profiles.zig");
pub const settings_map = @import("settings_map.zig");
pub const theme = @import("theme.zig");
pub const win32_input = @import("win32_input.zig");

test {
    _ = action;
    _ = app_mode;
    _ = branding;
    _ = config_layers;
    _ = config_types;
    _ = confirm;
    _ = conpty;
    _ = gtk_css;
    _ = gui_settings;
    _ = i18n;
    _ = osc7;
    _ = path_quote;
    _ = policy;
    _ = proc;
    _ = profiles;
    _ = settings_map;
    _ = theme;
    _ = win32_input;
}
