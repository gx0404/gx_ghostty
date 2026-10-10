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
//! - State kept between runs outside the configuration (`state_file`):
//!   the place of the last window (`window_state`) and the command palette
//!   history (`palette_history`).
//! - UI language and translations (`i18n`); the name, links and
//!   non-affiliation notice of the About surfaces (`branding`).
//! - `gx:` binding actions (`action`) and launch profiles (`profiles`).
//! - Processes: inspection (`proc`), the idle and helper policies
//!   (`policy`), close confirmation (`confirm`), herdr app mode
//!   (`app_mode`) and the kind of program in the foreground (`leader`).
//! - New output in tabs that are not shown (`unread`).
//! - The policy for opening links from terminal output (`url_policy`).
//! - Performance measurements, on with `GHOSTTY_GX_PERF=1` (`perf`).
//! - The colors of the GTK look, as CSS (`gtk_css`).
//! - The interface library of both apprts: color math and the accent
//!   (`ui_color`), the design tokens (`ui_tokens`) and window chrome
//!   colors (`chrome`) derived from the terminal colors, motion
//!   (`motion`), fuzzy matching with pinyin initials (`fuzzy`, `pinyin`),
//!   theme swatches (`theme_swatch`) and the keyboard shortcut sheet
//!   (`shortcuts`).
//! - Windows terminal support: win32-input-mode key records
//!   (`win32_input`), the bundled ConPTY (`conpty`), OSC 7 working
//!   directories (`osc7`) and shell quoting of dropped or pasted file
//!   paths (`path_quote`).
pub const action = @import("action.zig");
pub const app_mode = @import("app_mode.zig");
pub const branding = @import("branding.zig");
pub const chrome = @import("chrome.zig");
pub const config_layers = @import("config_layers.zig");
pub const config_types = @import("config_types.zig");
pub const confirm = @import("confirm.zig");
pub const conpty = @import("conpty.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const gtk_css = @import("gtk_css.zig");
pub const gui_settings = @import("gui_settings.zig");
pub const i18n = @import("i18n.zig");
pub const leader = @import("leader.zig");
pub const motion = @import("motion.zig");
pub const osc7 = @import("osc7.zig");
pub const palette_history = @import("palette_history.zig");
pub const path_quote = @import("path_quote.zig");
pub const perf = @import("perf.zig");
pub const pinyin = @import("pinyin.zig");
pub const policy = @import("policy.zig");
pub const proc = @import("proc.zig");
pub const profiles = @import("profiles.zig");
pub const settings_map = @import("settings_map.zig");
pub const shortcuts = @import("shortcuts.zig");
pub const state_file = @import("state_file.zig");
pub const theme = @import("theme.zig");
pub const theme_swatch = @import("theme_swatch.zig");
pub const ui_color = @import("ui_color.zig");
pub const ui_tokens = @import("ui_tokens.zig");
pub const unread = @import("unread.zig");
pub const url_policy = @import("url_policy.zig");
pub const win32_input = @import("win32_input.zig");
pub const window_state = @import("window_state.zig");

test {
    _ = action;
    _ = app_mode;
    _ = branding;
    _ = chrome;
    _ = config_layers;
    _ = config_types;
    _ = confirm;
    _ = conpty;
    _ = fuzzy;
    _ = gtk_css;
    _ = gui_settings;
    _ = i18n;
    _ = leader;
    _ = motion;
    _ = osc7;
    _ = palette_history;
    _ = path_quote;
    _ = perf;
    _ = pinyin;
    _ = policy;
    _ = proc;
    _ = profiles;
    _ = settings_map;
    _ = shortcuts;
    _ = state_file;
    _ = theme;
    _ = theme_swatch;
    _ = ui_color;
    _ = ui_tokens;
    _ = unread;
    _ = url_policy;
    _ = win32_input;
    _ = window_state;
}
