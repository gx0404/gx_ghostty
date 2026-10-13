//! Configuration errors are reported once (fork patch GX-0028).
//!
//! Upstream `Application.showConfigErrorsDialog` runs for every
//! configuration change of the app and shows the configuration errors
//! dialog again while the configuration has diagnostics: a dismissed dialog
//! comes back, and an open one is presented again, which raises it and
//! takes the keyboard focus. Ghostty GX changes the configuration far more
//! often than a user edits it: each step of a theme preview in the settings
//! dialog, each saved setting (which reloads the files), a UI language
//! switch and a light or dark switch of the system. With an error in the
//! user's files, browsing themes with the arrow keys would bring the dialog
//! back on every step and move the focus away from the theme list.
//!
//! `Reports` remembers the diagnostics the app reported, by their digest
//! (`gx.config_layers.diagnosticsDigest`), so the dialog only appears, or
//! comes to the front, for diagnostics not reported before: a reload that
//! keeps the same errors does not report them again. A configuration
//! without diagnostics clears the record, so the same errors made again
//! later are reported. The dialog's own Reload Configuration button clears
//! it too: the errors that are still there after that reload are shown
//! again rather than the dialog just going away.
const std = @import("std");

const gx = @import("../../../gx/main.zig");
const CoreConfig = @import("../../../config.zig").Config;

/// The configuration diagnostics an app reported, kept in its private data.
pub const Reports = struct {
    /// Digests of the diagnostics reported since the configuration last had
    /// none or since `forget`; `digests[0..len]`, replaced oldest first.
    digests: [capacity]u64 = undefined,
    len: usize = 0,

    /// The slot that the next digest replaces once `digests` is full.
    oldest: usize = 0,

    /// Sets of diagnostics remembered at once. A theme preview can switch
    /// between a few (those of the user's files, plus those of a theme file
    /// with errors), so returning to one of them does not show it again.
    pub const capacity = 8;

    /// Whether to show the diagnostics of `config` now: true for
    /// diagnostics not reported before, which then count as reported.
    pub fn update(self: *Reports, config: *const CoreConfig) bool {
        return self.updateDigest(gx.config_layers.diagnosticsDigest(config));
    }

    /// Lets the next diagnostics be shown even if they were reported
    /// before. Called before the reload that the configuration errors
    /// dialog asks for.
    pub fn forget(self: *Reports) void {
        self.len = 0;
        self.oldest = 0;
    }

    fn updateDigest(self: *Reports, digest: u64) bool {
        if (digest == 0) {
            self.forget();
            return false;
        }
        for (self.digests[0..self.len]) |reported| {
            if (reported == digest) return false;
        }
        if (self.len < capacity) {
            self.digests[self.len] = digest;
            self.len += 1;
        } else {
            self.digests[self.oldest] = digest;
            self.oldest = (self.oldest + 1) % capacity;
        }
        return true;
    }
};

test "each set of diagnostics is shown once" {
    const testing = std.testing;
    var reports: Reports = .{};
    try testing.expect(!reports.updateDigest(0));
    try testing.expect(reports.updateDigest(1));
    try testing.expect(!reports.updateDigest(1));
    try testing.expect(reports.updateDigest(2));
    try testing.expect(!reports.updateDigest(1));
    try testing.expect(!reports.updateDigest(2));

    // Fixing the configuration clears the record: the same errors made
    // again later are shown again.
    try testing.expect(!reports.updateDigest(0));
    try testing.expect(reports.updateDigest(1));
}

test "forget shows the same diagnostics again" {
    const testing = std.testing;
    var reports: Reports = .{};
    try testing.expect(reports.updateDigest(5));
    reports.forget();
    try testing.expect(reports.updateDigest(5));
    try testing.expect(!reports.updateDigest(5));
}

test "the oldest diagnostics are forgotten first" {
    const testing = std.testing;
    var reports: Reports = .{};
    for (1..Reports.capacity + 1) |digest| try testing.expect(reports.updateDigest(digest));
    try testing.expect(reports.updateDigest(Reports.capacity + 1));
    for (2..Reports.capacity + 2) |digest| try testing.expect(!reports.updateDigest(digest));
    try testing.expect(reports.updateDigest(1));
    try testing.expect(!reports.updateDigest(Reports.capacity + 1));
}

test "update reads the diagnostics of a configuration" {
    const testing = std.testing;
    var config = try CoreConfig.default(testing.allocator);
    defer config.deinit();
    var reports: Reports = .{};
    try testing.expect(!reports.update(&config));

    try config.addDiagnosticFmt("unknown field {s}", .{"fontsize"});
    try testing.expect(reports.update(&config));
    try testing.expect(!reports.update(&config));

    var other = try CoreConfig.default(testing.allocator);
    defer other.deinit();
    try other.addDiagnosticFmt("unknown field {s}", .{"fontsize"});
    try testing.expect(!reports.update(&other));
    try other.addDiagnosticFmt("unknown field {s}", .{"colour"});
    try testing.expect(reports.update(&other));
}
