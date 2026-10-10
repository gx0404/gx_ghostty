//! The pure parts of the settings overlay: the timing of theme previews
//! and save retries, wheel scrolling with a remainder, the layout of
//! lists and chip rows, and how commands, paths and typed font sizes show
//! and parse. Only depends on `std`, so the tests run with a plain
//! `zig test` of this file on any host.
const std = @import("std");

// -----------------------------------------------------------------------
// Timing
// -----------------------------------------------------------------------

/// What moved the cursor of the theme list, which decides how long the
/// preview waits for the cursor to come to rest.
pub const PreviewTrigger = enum {
    /// Arrow keys, Page Up/Down, Home/End: every step restarts the wait,
    /// so holding a key previews once, where it stops.
    navigate,
    /// Typing in the filter box: the first match changes with every key.
    type,
    /// A click on a theme.
    click,
};

/// The quiet time before a theme preview (a debounce: every new trigger
/// restarts it).
pub fn previewDelayMs(trigger: PreviewTrigger) u32 {
    return switch (trigger) {
        .navigate => 150,
        .type => 400,
        .click => 10,
    };
}

/// The wait before save attempt `attempt` + 1 after `attempt` failed ones
/// (1 s, 2 s, 4 s, 8 s, 16 s), or null to give up.
pub fn saveRetryDelayMs(attempt: u32) ?u32 {
    if (attempt == 0) return 0;
    if (attempt > max_save_retries) return null;
    return @as(u32, 1000) << @intCast(attempt - 1);
}

pub const max_save_retries = 5;

// -----------------------------------------------------------------------
// Wheel
// -----------------------------------------------------------------------

/// `SPI_GETWHEELSCROLLLINES` for "one screen at a time".
pub const wheel_page_scroll: u32 = std.math.maxInt(u32);

/// The lines one wheel notch scrolls for the `SPI_GETWHEELSCROLLLINES`
/// value `setting`; `page` lines when it asks for a screen at a time.
pub fn wheelLines(setting: u32, page: f32) f32 {
    if (setting == wheel_page_scroll) return @max(1, page);
    return @floatFromInt(setting);
}

/// Turns wheel notches, including the small steps of precision touchpads,
/// into whole lines, keeping the fraction for the next turn.
pub const Wheel = struct {
    rest: f32 = 0,

    /// The whole lines to scroll down (negative: up) for `notches`
    /// (positive: away from the user) at `lines_per_notch`.
    pub fn lines(self: *Wheel, notches: f32, lines_per_notch: f32) i32 {
        // Reversing direction drops what was left of the other one.
        if (self.rest != 0 and (self.rest > 0) != (-notches > 0)) self.rest = 0;
        const total = self.rest - notches * lines_per_notch;
        const whole = @trunc(total);
        self.rest = total - whole;
        return @intFromFloat(whole);
    }

    pub fn reset(self: *Wheel) void {
        self.rest = 0;
    }
};

// -----------------------------------------------------------------------
// Layout
// -----------------------------------------------------------------------

/// A list box sized to whole items: no blank band below the last row.
pub const ListFit = struct {
    /// The height of the box, `pad` above and below the items.
    box: f32,
    /// The items it shows.
    visible: usize,
};

/// The list box for at most `available` DIPs of items `item` high with
/// `pad` above and below them, at least one item.
pub fn fitList(available: f32, item: f32, pad: f32) ListFit {
    const inner = @max(0, available - 2 * pad);
    const count: usize = @max(1, @as(usize, @intFromFloat(@floor(inner / item + 0.001))));
    return .{ .box = @as(f32, @floatFromInt(count)) * item + 2 * pad, .visible = count };
}

/// Whether the chips of a choice row go on a line of their own below the
/// title: when the title (`title_w`), the chips (`chips_w`) and the `gap`
/// between them do not fit in the row (`row_w`, without its padding).
pub fn chipsWrap(title_w: f32, chips_w: f32, gap: f32, row_w: f32) bool {
    return title_w + gap + chips_w > row_w;
}

/// The scroll offset that shows the rows from `top` to `bottom` (content
/// coordinates) in a view `view` high scrolled by `scroll`, moving as
/// little as possible, with `margin` around them; clamped to `max`.
pub fn reveal(scroll: f32, top: f32, bottom: f32, view: f32, margin: f32, max: f32) f32 {
    var s = scroll;
    if (bottom + margin > s + view) s = bottom + margin - view;
    if (top - margin < s) s = top - margin;
    return std.math.clamp(s, 0, @max(0, max));
}

// -----------------------------------------------------------------------
// Text
// -----------------------------------------------------------------------

/// A `command` value as the shell list shows it: without the `direct:`
/// prefix of commands that run without a shell.
pub fn displayCommand(command: []const u8) []const u8 {
    const prefix = "direct:";
    if (std.mem.startsWith(u8, command, prefix)) return command[prefix.len..];
    return command;
}

/// `path` with every separator a backslash, like Windows shows paths
/// (paths joined from `XDG_CONFIG_HOME` and a relative part mix both);
/// in `buf`, or `path` when it does not fit.
pub fn windowsPath(buf: []u8, path: []const u8) []const u8 {
    if (path.len > buf.len) return path;
    for (path, buf[0..path.len]) |c, *out| out.* = if (c == '/') '\\' else c;
    return buf[0..path.len];
}

/// The key of a configuration file line (`key = value`), or null for
/// blank lines and comments, parsed like the overlay file parser does.
pub fn lineKey(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const end = std.mem.indexOfScalar(u8, trimmed, '=') orelse trimmed.len;
    const key = std.mem.trim(u8, trimmed[0..end], " \t");
    return if (key.len == 0) null else key;
}

/// A font size typed into the size field: a positive decimal number with
/// a point or a comma; null for anything else.
pub fn parseFontSize(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0 or trimmed.len > 16) return null;
    var buf: [16]u8 = undefined;
    for (trimmed, 0..) |c, i| {
        buf[i] = switch (c) {
            '0'...'9', '.' => c,
            ',' => '.',
            else => return null,
        };
    }
    const value = std.fmt.parseFloat(f64, buf[0..trimmed.len]) catch return null;
    if (!std.math.isFinite(value) or value <= 0) return null;
    return value;
}

/// Whether `c` starts a typed font size: a digit, a point or a comma.
pub fn startsFontSize(c: u21) bool {
    return switch (c) {
        '0'...'9', '.', ',' => true,
        else => false,
    };
}

// -----------------------------------------------------------------------
// Confirmation
// -----------------------------------------------------------------------

/// A destructive button that asks for a second press within `window_ms`.
pub const Confirm = struct {
    armed_ms: ?u64 = null,

    pub const window_ms: u64 = 5000;

    /// A press at `now`: true when it confirms an earlier one, else it
    /// arms the button.
    pub fn press(self: *Confirm, now: u64) bool {
        if (self.armed(now)) {
            self.armed_ms = null;
            return true;
        }
        self.armed_ms = now;
        return false;
    }

    pub fn armed(self: *const Confirm, now: u64) bool {
        const at = self.armed_ms orelse return false;
        return now -| at < window_ms;
    }

    pub fn cancel(self: *Confirm) void {
        self.armed_ms = null;
    }
};

const testing = std.testing;

test "previews wait longer while typing" {
    try testing.expect(previewDelayMs(.type) > previewDelayMs(.navigate));
    try testing.expect(previewDelayMs(.navigate) > previewDelayMs(.click));
    // Holding an arrow key repeats faster than the wait, so the preview
    // waits for the key to be released.
    try testing.expect(previewDelayMs(.navigate) > 100);
}

test "save retries back off and give up" {
    try testing.expectEqual(@as(?u32, 1000), saveRetryDelayMs(1));
    try testing.expectEqual(@as(?u32, 2000), saveRetryDelayMs(2));
    try testing.expectEqual(@as(?u32, 16000), saveRetryDelayMs(5));
    try testing.expectEqual(@as(?u32, null), saveRetryDelayMs(6));
}

test "the wheel keeps the fraction of small steps" {
    var wheel: Wheel = .{};
    // A precision touchpad sends a tenth of a notch at a time.
    var total: i32 = 0;
    for (0..10) |_| total += wheel.lines(-0.1, 3);
    try testing.expectEqual(@as(i32, 3), total);
    // A whole notch away from the user scrolls up.
    try testing.expectEqual(@as(i32, -3), wheel.lines(1, 3));
    // Turning back drops the rest of the other direction.
    _ = wheel.lines(0.2, 1);
    try testing.expectEqual(@as(i32, 0), wheel.lines(-0.5, 1));
    try testing.expectEqual(@as(i32, 1), wheel.lines(-0.5, 1));
    wheel.reset();
    try testing.expectEqual(@as(f32, 0), wheel.rest);
}

test "wheel lines follow the system setting" {
    try testing.expectEqual(@as(f32, 3), wheelLines(3, 10));
    try testing.expectEqual(@as(f32, 0), wheelLines(0, 10));
    try testing.expectEqual(@as(f32, 10), wheelLines(wheel_page_scroll, 10));
    try testing.expectEqual(@as(f32, 1), wheelLines(wheel_page_scroll, 0));
}

test "lists show whole items" {
    const fit = fitList(300, 30, 4);
    try testing.expectEqual(@as(usize, 9), fit.visible);
    try testing.expectEqual(@as(f32, 278), fit.box);
    try testing.expectEqual(@as(usize, 1), fitList(10, 30, 4).visible);
    try testing.expectEqual(@as(usize, 2), fitList(68, 30, 4).visible);
}

test "chips go below the title when they do not fit" {
    try testing.expect(!chipsWrap(120, 300, 16, 600));
    try testing.expect(chipsWrap(220, 400, 16, 600));
}

test "reveal moves the view as little as possible" {
    // Already visible: no change.
    try testing.expectEqual(@as(f32, 100), reveal(100, 150, 200, 300, 8, 1000));
    // Below the view: just enough to show it.
    try testing.expectEqual(@as(f32, 158), reveal(100, 400, 450, 300, 8, 1000));
    // Above the view.
    try testing.expectEqual(@as(f32, 42), reveal(100, 50, 80, 300, 8, 1000));
    // Clamped.
    try testing.expectEqual(@as(f32, 0), reveal(100, 0, 20, 300, 8, 1000));
    try testing.expectEqual(@as(f32, 50), reveal(0, 900, 1000, 300, 8, 50));
}

test "displayCommand drops direct:" {
    try testing.expectEqualStrings("C:\\Windows\\system32\\cmd.exe", displayCommand("direct:C:\\Windows\\system32\\cmd.exe"));
    try testing.expectEqualStrings("\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"", displayCommand("\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\""));
    try testing.expectEqualStrings("", displayCommand(""));
}

test "windowsPath uses backslashes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("C:\\Users\\me\\ghostty\\config.ghostty", windowsPath(&buf, "C:\\Users\\me\\ghostty/config.ghostty"));
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("a/b/c/d", windowsPath(&small, "a/b/c/d"));
}

test "lineKey" {
    try testing.expectEqualStrings("font-size", lineKey("font-size = 13").?);
    try testing.expectEqualStrings("theme", lineKey("  theme=GX Mocha\r").?);
    try testing.expectEqualStrings("keybind", lineKey("keybind").?);
    try testing.expectEqual(@as(?[]const u8, null), lineKey("# font-size = 13"));
    try testing.expectEqual(@as(?[]const u8, null), lineKey("   "));
    try testing.expectEqual(@as(?[]const u8, null), lineKey("= x"));
}

test "parseFontSize" {
    try testing.expectEqual(@as(?f64, 12), parseFontSize("12"));
    try testing.expectEqual(@as(?f64, 12.5), parseFontSize(" 12.5 "));
    try testing.expectEqual(@as(?f64, 13.5), parseFontSize("13,5"));
    for ([_][]const u8{ "", "abc", "-3", "0", "1e3", "12pt", "1.2.3", "99999999999999999" }) |text| {
        try testing.expectEqual(@as(?f64, null), parseFontSize(text));
    }
    try testing.expect(startsFontSize('1'));
    try testing.expect(startsFontSize(','));
    try testing.expect(!startsFontSize('a'));
}

test "Confirm needs a second press in time" {
    var confirm: Confirm = .{};
    try testing.expect(!confirm.press(1000));
    try testing.expect(confirm.armed(1500));
    try testing.expect(confirm.press(2000));
    try testing.expect(!confirm.armed(2001));
    // Too late: the second press arms again.
    try testing.expect(!confirm.press(10_000));
    try testing.expect(!confirm.press(10_000 + Confirm.window_ms));
    confirm.cancel();
    try testing.expect(!confirm.armed(10_000 + Confirm.window_ms));
}
