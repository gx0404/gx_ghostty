//! Forwards to the shared fuzzy matcher `src/gx/fuzzy.zig` (`gx.fuzzy`),
//! which matching and its tests moved to; callers move to `gx.fuzzy` and
//! this file goes away.
const fuzzy = @import("../../../gx/fuzzy.zig");

pub const max_query = fuzzy.max_query;
pub const max_text = fuzzy.max_text;
pub const Query = fuzzy.Query;
pub const score = fuzzy.score;
pub const matches = fuzzy.matches;
