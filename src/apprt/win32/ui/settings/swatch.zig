//! Forwards to the theme colors shared with GTK, `src/gx/theme_swatch.zig`
//! (`gx.theme_swatch`), which the swatches and their tests moved to;
//! callers move to `gx.theme_swatch` and this file goes away.
const theme_swatch = @import("../../../../gx/theme_swatch.zig");

pub const Rgb = theme_swatch.Rgb;
pub const Swatch = theme_swatch.Swatch;
pub const Cache = theme_swatch.Cache;
pub const load = theme_swatch.load;
