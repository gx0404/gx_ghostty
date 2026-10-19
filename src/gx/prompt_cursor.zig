//! The prompt cursor of the shell integration `cursor` feature
//! (`gx-prompt-cursor`, fork patch GX-0047).
//!
//! Upstream `src/termio/shell_integration.zig::setupFeatures` writes the
//! `cursor:blink` or `cursor:steady` feature to `GHOSTTY_SHELL_FEATURES`, and
//! the integrations set a bar at every prompt. For `config`, `advertise` adds
//! `cursor:config` right after that feature; the bash, zsh, fish and elvish
//! integrations then send DECSCUSR 0 at the prompt, which shows the configured
//! `cursor-style` and `cursor-style-blink`. Without explicit overrides, zsh vi
//! key bindings keep their bar and block, and fish keeps its own vi cursor.
//! GTK/Windows explicit shape and blink settings override every program or
//! integration request independently (GX-0057), including `bar` and vi modes.
//! For `bar`, and when the
//! `cursor` feature is disabled, the variable stays exactly as upstream wrote
//! it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const PromptCursor = @import("config_types.zig").PromptCursor;

/// The variable that upstream `setupFeatures` writes and the integrations read.
const variable = "GHOSTTY_SHELL_FEATURES";

/// The feature that asks the integrations for the configured prompt cursor.
pub const feature = "cursor:config";

/// Adds `feature` after the `cursor` feature of `GHOSTTY_SHELL_FEATURES` when
/// `mode` is `config`; call it after upstream `setupFeatures`. Does nothing for
/// `bar`, without the variable or its `cursor` feature, or when `feature` is
/// already present.
pub fn advertise(env: *EnvMap, mode: PromptCursor) Allocator.Error!void {
    if (mode != .config) return;
    const value = env.get(variable) orelse return;
    const end = cursorEnd(value) orelse return;
    const updated = try std.mem.concat(env.allocator, u8, &.{ value[0..end], "," ++ feature, value[end..] });
    defer env.allocator.free(updated);
    try env.put(variable, updated);
}

/// Where the `cursor` feature (`cursor` or `cursor:<hint>`) of `value` ends,
/// or null when it is missing or `feature` is already present.
fn cursorEnd(value: []const u8) ?usize {
    var end: ?usize = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| {
        if (std.mem.eql(u8, item, feature)) return null;
        if (end == null and (std.mem.eql(u8, item, "cursor") or std.mem.startsWith(u8, item, "cursor:"))) {
            end = @intFromPtr(item.ptr) - @intFromPtr(value.ptr) + item.len;
        }
    }
    return end;
}

test "config follows the upstream cursor feature once" {
    const testing = std.testing;
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    // The values upstream `setupFeatures` writes for all features and for
    // `cursor` alone (`src/termio/shell_integration.zig` "setup features").
    try env.put(variable, "cursor:blink,path,ssh-env,ssh-terminfo,sudo,title");
    try advertise(&env, .config);
    try testing.expectEqualStrings("cursor:blink,cursor:config,path,ssh-env,ssh-terminfo,sudo,title", env.get(variable).?);
    try advertise(&env, .config);
    try testing.expectEqualStrings("cursor:blink,cursor:config,path,ssh-env,ssh-terminfo,sudo,title", env.get(variable).?);

    try env.put(variable, "cursor:steady");
    try advertise(&env, .config);
    try testing.expectEqualStrings("cursor:steady,cursor:config", env.get(variable).?);

    try env.put(variable, "path,cursor");
    try advertise(&env, .config);
    try testing.expectEqualStrings("path,cursor,cursor:config", env.get(variable).?);
}

test "bar and a disabled cursor feature keep the upstream value" {
    const testing = std.testing;
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    // All features disabled: upstream writes no variable at all.
    try advertise(&env, .config);
    try testing.expect(env.get(variable) == null);

    try env.put(variable, "cursor:steady,sudo");
    try advertise(&env, .bar);
    try testing.expectEqualStrings("cursor:steady,sudo", env.get(variable).?);

    try env.put(variable, "ssh-env,sudo");
    try advertise(&env, .config);
    try testing.expectEqualStrings("ssh-env,sudo", env.get(variable).?);
}
