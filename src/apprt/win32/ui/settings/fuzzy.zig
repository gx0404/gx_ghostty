//! Forwards to the shared fuzzy matcher `src/gx/fuzzy.zig` (`gx.fuzzy`),
//! which the matching of the settings filter boxes and its tests moved to;
//! callers move to `gx.fuzzy` and this file goes away.
const fuzzy = @import("../../../../gx/fuzzy.zig");

pub const filter = fuzzy.filter;
pub const isBlank = fuzzy.isBlank;

/// The score of `pattern` against `name`: `gx.fuzzy.score` with the
/// arguments in the order this file had them.
pub fn score(name: []const u8, pattern: []const u8) ?i32 {
    const query: fuzzy.Query = .init(pattern);
    return fuzzy.score(&query, name);
}
