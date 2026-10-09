//! Ghostty GX core modules shared by the win32 and GTK apprts: UI language
//! and translations, the settings overlay, configuration layering, launch
//! profiles, process inspection and process policies.
pub const action = @import("action.zig");
pub const config_layers = @import("config_layers.zig");
pub const config_types = @import("config_types.zig");
pub const gui_settings = @import("gui_settings.zig");
pub const i18n = @import("i18n.zig");
pub const policy = @import("policy.zig");
pub const proc = @import("proc.zig");
pub const profiles = @import("profiles.zig");
pub const theme = @import("theme.zig");

test {
    _ = action;
    _ = config_layers;
    _ = config_types;
    _ = gui_settings;
    _ = i18n;
    _ = policy;
    _ = proc;
    _ = profiles;
    _ = theme;
}
