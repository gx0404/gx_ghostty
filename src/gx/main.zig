//! Ghostty GX core modules shared by the win32 and GTK apprts: UI language
//! and translations, the settings overlay, configuration layering, launch
//! profiles, process inspection and process policies, close confirmation,
//! herdr app mode, shell quoting of dropped file paths, the colors of the
//! GTK look, plus the Windows terminal
//! support behind fork patches: win32-input-mode key records, the bundled
//! ConPTY and OSC 7 working directories.
pub const action = @import("action.zig");
pub const app_mode = @import("app_mode.zig");
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
