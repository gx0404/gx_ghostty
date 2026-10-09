//! Ghostty GX identity for the About surfaces of both apprts: the name,
//! the maintainer, the project links and the notice that Ghostty GX is an
//! unofficial fork, not affiliated with or endorsed by the Ghostty
//! project (the Ghostty maintainers ask unofficial builds to say so).
//! The texts are English msgids translated in `i18n/gx.zh_CN.po`.
const std = @import("std");
const i18n = @import("i18n.zig");

pub const name = "Ghostty GX";
pub const maintainer = "gx0404";
pub const home_url = "https://github.com/gx0404/gx_ghostty";
pub const issues_url = home_url ++ "/issues";
pub const ghostty_url = "https://ghostty.org";

/// The non-affiliation notice.
pub const notice = "Ghostty GX is an unofficial fork of Ghostty maintained by gx0404. It is not affiliated with or endorsed by the Ghostty project.";

/// The license line that follows the notice in About dialogs.
pub const license = "Ghostty GX is free software under the MIT License.";

test "the notice and the license line are translated" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        "Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书。",
        i18n.lookup(.zh_CN, notice).?,
    );
    try testing.expect(i18n.lookup(.zh_CN, license) != null);
}
