//! The command palette history, kept between runs in the state file
//! `gx-palette-history` (`state_file`), never in a configuration file.
//! Entries are 64-bit FNV-1a hashes of the stable keys of palette entries
//! (an English msgid, an action, a theme name), so the file does not say
//! in clear text what was run or typed. Two kinds of memory:
//!
//!   - Picks (frecency): each picked key keeps one projected time `d`, in
//!     seconds since the Unix epoch. Its frecency at time `t` is
//!     `2^((d - t) / h)` with a half-life `h` of 14 days: the sum of all its
//!     picks, each worth 1 when made and half as much every 14 days later.
//!     A pick at `t` turns the sum `s = 2^((d - t) / h) + 1` back into
//!     `d = t + h * log2(s)` (Firefox's decay projection), so ranking by `d`
//!     ranks by frecency at any time. At most `max_picks` keys; a new key
//!     replaces the weakest.
//!   - Input history: which entry was picked after typing what. Every
//!     prefix of the normalized query keeps a use count per picked key,
//!     which grows to `0.9 u + 1` with each pick of that key and decays to
//!     `0.9 u` with each pick of another key after the same prefix; the
//!     best key for what has been typed so far is offered first
//!     (`inputMatch`). At most `max_inputs` prefix and key pairs.
//!
//! The caller passes the current time, so the model is pure. `commit`
//! reads the file again, merges it (the later time of each key, the larger
//! count of each pair) and replaces it atomically, so several Ghostty
//! processes keep each other's picks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const state_file = @import("state_file.zig");

/// The name of the state file.
pub const file_name = "gx-palette-history";

/// The half-life of a pick, in seconds.
pub const half_life_s: f64 = 14 * std.time.s_per_day;

/// The most keys remembered as picks.
pub const max_picks = 64;

/// The most prefix and key pairs of the input history.
pub const max_inputs = 256;

/// The largest score bonus `bonus` gives.
pub const max_bonus: i32 = 24;

/// The longest query the input history remembers, in code points.
pub const max_query = 32;

/// The largest history file `load` reads.
pub const max_file_size = 64 * 1024;

/// The format version of the file.
const version = 1;

/// The most keys `remove` keeps out of later merges before `commit`.
const max_removed = 32;

/// The hash a palette entry key is remembered by.
pub fn keyHash(key: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(key);
}

pub const Pick = struct {
    key: u64,

    /// The projected time, in seconds since the Unix epoch.
    d: f64,
};

pub const Input = struct {
    /// The hash of a prefix of a normalized query.
    prefix: u64,
    key: u64,
    uses: f32,
};

pub const History = struct {
    picks: [max_picks]Pick = undefined,
    picks_len: usize = 0,
    inputs: [max_inputs]Input = undefined,
    inputs_len: usize = 0,

    /// Keys removed since the last `commit`, which merging the file must
    /// not bring back.
    removed: [max_removed]u64 = undefined,
    removed_len: usize = 0,

    /// Set by `clear` (and when `removed` overflows) until the next
    /// `commit`, which then replaces the file instead of merging it.
    replace: bool = false,

    /// Records a pick of `key` at `now` (Unix seconds). Empty keys are not
    /// remembered.
    pub fn record(self: *History, key: []const u8, now: i64) void {
        if (key.len == 0) return;
        self.recordHash(keyHash(key), @floatFromInt(now));
    }

    fn recordHash(self: *History, key: u64, now: f64) void {
        self.forgetRemoval(key);
        if (self.findPick(key)) |i| {
            const pick = &self.picks[i];
            const sum = std.math.exp2((pick.d - now) / half_life_s) + 1;
            pick.d = now + half_life_s * std.math.log2(sum);
            return;
        }
        self.insertPick(.{ .key = key, .d = now });
    }

    /// The frecency of `key` at `now`: the decayed number of its picks, 0
    /// when it was never picked.
    pub fn frecency(self: *const History, key: []const u8, now: i64) f64 {
        const i = self.findPick(keyHash(key)) orelse return 0;
        return std.math.exp2((self.picks[i].d - @as(f64, @floatFromInt(now))) / half_life_s);
    }

    /// The score bonus of `key` in a palette ranking at `now`,
    /// `min(24, 6 log2(1 + frecency))`: 6 for one pick just made, 0 when it
    /// was never picked.
    pub fn bonus(self: *const History, key: []const u8, now: i64) i32 {
        const value = self.frecency(key, now);
        if (!(value > 0)) return 0;
        const scaled = @round(6 * std.math.log2(1 + value));
        return @intFromFloat(@min(scaled, @as(f64, max_bonus)));
    }

    /// The place of `key` among the recently used entries, higher first,
    /// the same order as the frecency at any time; 0 when it was never
    /// picked.
    pub fn rank(self: *const History, key: []const u8) u64 {
        const i = self.findPick(keyHash(key)) orelse return 0;
        const ms = self.picks[i].d * std.time.ms_per_s;
        if (!(ms >= 1)) return 1;
        return @intFromFloat(@min(ms, 1.0e19));
    }

    /// Forgets `key`: its pick and the input history that leads to it.
    pub fn remove(self: *History, key: []const u8) void {
        const hash = keyHash(key);
        if (self.findPick(hash)) |i| {
            self.picks[i] = self.picks[self.picks_len - 1];
            self.picks_len -= 1;
        }
        var i: usize = 0;
        while (i < self.inputs_len) {
            if (self.inputs[i].key == hash) {
                self.inputs[i] = self.inputs[self.inputs_len - 1];
                self.inputs_len -= 1;
            } else i += 1;
        }
        if (self.isRemoved(hash)) return;
        if (self.removed_len == max_removed) {
            self.replace = true;
            return;
        }
        self.removed[self.removed_len] = hash;
        self.removed_len += 1;
    }

    /// Forgets everything; the next `commit` empties the file.
    pub fn clear(self: *History) void {
        self.* = .{ .replace = true };
    }

    pub fn isEmpty(self: *const History) bool {
        return self.picks_len == 0 and self.inputs_len == 0;
    }

    /// Records that `key` was picked after typing `query`.
    pub fn recordInput(self: *History, query: []const u8, key: []const u8) void {
        if (key.len == 0) return;
        const hash = keyHash(key);
        self.forgetRemoval(hash);
        var prefixes: [max_query]u64 = undefined;
        for (prefixes[0..prefixHashes(query, &prefixes)]) |prefix| {
            var found = false;
            for (self.inputs[0..self.inputs_len]) |*input| {
                if (input.prefix != prefix) continue;
                if (input.key == hash) {
                    input.uses = input.uses * 0.9 + 1;
                    found = true;
                } else {
                    input.uses *= 0.9;
                }
            }
            if (!found) self.insertInput(.{ .prefix = prefix, .key = hash, .uses = 1 });
        }
    }

    /// The hash (`keyHash`) of the key picked most after typing `query`,
    /// or of a longer query that starts like it; null when there is none.
    pub fn inputMatch(self: *const History, query: []const u8) ?u64 {
        var prefixes: [max_query]u64 = undefined;
        const count = prefixHashes(query, &prefixes);
        if (count == 0) return null;
        const prefix = prefixes[count - 1];
        var best: ?Input = null;
        for (self.inputs[0..self.inputs_len]) |input| {
            if (input.prefix != prefix) continue;
            if (best == null or input.uses > best.?.uses) best = input;
        }
        return if (best) |input| input.key else null;
    }

    /// Adds what `other` remembers: the later time of every key and the
    /// larger count of every pair, except for keys removed from this
    /// history since the last commit.
    pub fn merge(self: *History, other: *const History) void {
        for (other.picks[0..other.picks_len]) |pick| {
            if (self.isRemoved(pick.key)) continue;
            if (self.findPick(pick.key)) |i| {
                self.picks[i].d = @max(self.picks[i].d, pick.d);
            } else self.insertPick(pick);
        }
        for (other.inputs[0..other.inputs_len]) |input| {
            if (self.isRemoved(input.key)) continue;
            if (self.findInput(input.prefix, input.key)) |i| {
                self.inputs[i].uses = @max(self.inputs[i].uses, input.uses);
            } else self.insertInput(input);
        }
    }

    /// Parses the contents of a history file. Lines it does not understand
    /// are skipped, and a file of another version reads as empty.
    pub fn parse(text: []const u8) History {
        var self: History = .{};
        var current = false;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const kind = fields.next() orelse continue;
            if (std.mem.eql(u8, kind, "version")) {
                const value = fields.next() orelse "";
                current = (std.fmt.parseInt(u32, value, 10) catch 0) == version;
                continue;
            }
            if (!current) continue;
            if (std.mem.eql(u8, kind, "pick")) {
                const key = parseHash(fields.next()) orelse continue;
                const d = parseFinite(f64, fields.next()) orelse continue;
                if (self.findPick(key) == null) self.insertPick(.{ .key = key, .d = d });
            } else if (std.mem.eql(u8, kind, "input")) {
                const prefix = parseHash(fields.next()) orelse continue;
                const key = parseHash(fields.next()) orelse continue;
                const uses = parseFinite(f32, fields.next()) orelse continue;
                if (!(uses > 0)) continue;
                if (self.findInput(prefix, key) == null) {
                    self.insertInput(.{ .prefix = prefix, .key = key, .uses = uses });
                }
            }
        }
        return self;
    }

    /// Writes the history in the format `parse` reads.
    pub fn write(self: *const History, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("# Ghostty GX command palette history: hashes of picked entries and typed text.\n");
        try writer.print("version {d}\n", .{version});
        for (self.picks[0..self.picks_len]) |pick| {
            try writer.print("pick {x:0>16} {d}\n", .{ pick.key, pick.d });
        }
        for (self.inputs[0..self.inputs_len]) |input| {
            try writer.print("input {x:0>16} {x:0>16} {d}\n", .{ input.prefix, input.key, input.uses });
        }
    }

    /// Loads the history file at `path`; a missing file is an empty
    /// history.
    pub fn load(alloc: Allocator, io: std.Io, path: []const u8) !History {
        const text = try state_file.read(alloc, io, path, max_file_size) orelse return .{};
        defer alloc.free(text);
        return parse(text);
    }

    /// Writes the history to `path`, merged with what the file holds now
    /// (unless `clear` or many removals asked to replace it), and
    /// atomically replaces the file.
    pub fn commit(self: *History, alloc: Allocator, io: std.Io, path: []const u8) !void {
        if (!self.replace) {
            const text = state_file.read(alloc, io, path, max_file_size) catch |err| switch (err) {
                // A file that cannot be read as a history is replaced.
                error.StreamTooLong => null,
                else => return err,
            };
            if (text) |contents| {
                defer alloc.free(contents);
                const on_disk = parse(contents);
                self.merge(&on_disk);
            }
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        self.write(&out.writer) catch return error.OutOfMemory;
        try state_file.write(io, path, out.written());
        self.replace = false;
        self.removed_len = 0;
    }

    /// The path of the history file in the state directory. The caller
    /// owns the result.
    pub fn defaultPath(alloc: Allocator) ![]u8 {
        return try state_file.path(alloc, file_name);
    }

    fn findPick(self: *const History, key: u64) ?usize {
        for (self.picks[0..self.picks_len], 0..) |pick, i| {
            if (pick.key == key) return i;
        }
        return null;
    }

    fn findInput(self: *const History, prefix: u64, key: u64) ?usize {
        for (self.inputs[0..self.inputs_len], 0..) |input, i| {
            if (input.prefix == prefix and input.key == key) return i;
        }
        return null;
    }

    /// Adds `pick`, replacing the weakest pick (the earliest projected
    /// time) when full and `pick` is stronger.
    fn insertPick(self: *History, pick: Pick) void {
        if (self.picks_len < max_picks) {
            self.picks[self.picks_len] = pick;
            self.picks_len += 1;
            return;
        }
        var weakest: usize = 0;
        for (self.picks[0..self.picks_len], 0..) |candidate, i| {
            if (candidate.d < self.picks[weakest].d) weakest = i;
        }
        if (pick.d > self.picks[weakest].d) self.picks[weakest] = pick;
    }

    /// Adds `input`, replacing the pair with the fewest uses when full.
    fn insertInput(self: *History, input: Input) void {
        if (self.inputs_len < max_inputs) {
            self.inputs[self.inputs_len] = input;
            self.inputs_len += 1;
            return;
        }
        var weakest: usize = 0;
        for (self.inputs[0..self.inputs_len], 0..) |candidate, i| {
            if (candidate.uses < self.inputs[weakest].uses) weakest = i;
        }
        if (input.uses >= self.inputs[weakest].uses) self.inputs[weakest] = input;
    }

    fn isRemoved(self: *const History, key: u64) bool {
        return std.mem.indexOfScalar(u64, self.removed[0..self.removed_len], key) != null;
    }

    fn forgetRemoval(self: *History, key: u64) void {
        const i = std.mem.indexOfScalar(u64, self.removed[0..self.removed_len], key) orelse return;
        self.removed[i] = self.removed[self.removed_len - 1];
        self.removed_len -= 1;
    }
};

/// Fills `out` with the hashes of the prefixes of the normalized `query`,
/// one per code point, shortest first, and returns how many there are.
/// Normalizing drops surrounding blanks, turns inner runs of blanks into
/// one space, folds ASCII letters to lower case and full-width ASCII (as a
/// CJK input method types it) to ASCII. Queries that are not UTF-8 have no
/// prefixes.
fn prefixHashes(query: []const u8, out: *[max_query]u64) usize {
    const view = std.unicode.Utf8View.init(query) catch return 0;
    var it = view.iterator();
    var hasher: std.hash.Fnv1a_64 = .init();
    var count: usize = 0;
    var blank = false;
    while (it.nextCodepoint()) |raw| {
        if (count == max_query) break;
        const cp = fold(raw);
        if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') {
            blank = count > 0;
            continue;
        }
        if (blank) {
            hasher.update(" ");
            blank = false;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        hasher.update(buf[0..len]);
        out[count] = hasher.final();
        count += 1;
    }
    return count;
}

fn fold(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + ('a' - 'A'),
        0xFF21...0xFF3A => cp - 0xFEE0 + ('a' - 'A'),
        0xFF01...0xFF20, 0xFF3B...0xFF5E => cp - 0xFEE0,
        0x3000 => ' ',
        else => cp,
    };
}

fn parseHash(text: ?[]const u8) ?u64 {
    const value = text orelse return null;
    if (value.len != 16) return null;
    return std.fmt.parseInt(u64, value, 16) catch null;
}

fn parseFinite(comptime T: type, text: ?[]const u8) ?T {
    const value = std.fmt.parseFloat(T, text orelse return null) catch return null;
    if (!std.math.isFinite(value)) return null;
    return value;
}

const testing = std.testing;
const day: i64 = std.time.s_per_day;
const t0: i64 = 1_760_000_000;

test "frecency decays with a half-life of 14 days and adds picks" {
    var history: History = .{};
    try testing.expectEqual(@as(f64, 0), history.frecency("a", t0));
    try testing.expectEqual(@as(u64, 0), history.rank("a"));
    try testing.expectEqual(@as(i32, 0), history.bonus("a", t0));

    history.record("a", t0);
    try testing.expectApproxEqAbs(@as(f64, 1), history.frecency("a", t0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), history.frecency("a", t0 + 14 * day), 1e-9);
    try testing.expectEqual(@as(i32, 6), history.bonus("a", t0));

    history.record("a", t0 + 14 * day);
    try testing.expectApproxEqAbs(@as(f64, 1.5), history.frecency("a", t0 + 14 * day), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.75), history.frecency("a", t0 + 28 * day), 1e-9);

    // Empty keys are not remembered.
    history.record("", t0);
    try testing.expectEqual(@as(usize, 1), history.picks_len);
}

test "the bonus is capped and rank follows frecency" {
    var history: History = .{};
    for (0..40) |_| history.record("often", t0);
    try testing.expectEqual(max_bonus, history.bonus("often", t0));

    history.record("old", t0 - 60 * day);
    history.record("old", t0 - 60 * day);
    history.record("new", t0);
    // One recent pick beats two picks two months ago.
    try testing.expect(history.rank("new") > history.rank("old"));
    try testing.expect(history.frecency("new", t0) > history.frecency("old", t0));
    try testing.expect(history.rank("often") > history.rank("new"));
    try testing.expect(history.rank("old") > 0);
}

test "a full history replaces its weakest pick" {
    var history: History = .{};
    var buf: [16]u8 = undefined;
    for (0..max_picks) |i| {
        history.record(try std.mem.print(&buf, "k{d}", .{i}), t0 + @as(i64, @intCast(i)));
    }
    history.record("newest", t0 + 1000);
    try testing.expectEqual(@as(usize, max_picks), history.picks_len);
    try testing.expectEqual(@as(u64, 0), history.rank("k0"));
    try testing.expect(history.rank("k1") > 0);
    try testing.expect(history.rank("newest") > 0);
}

test "remove and clear" {
    var history: History = .{};
    history.record("a", t0);
    history.record("b", t0);
    history.recordInput("x", "a");
    history.remove("a");
    try testing.expectEqual(@as(u64, 0), history.rank("a"));
    try testing.expect(history.rank("b") > 0);
    try testing.expectEqual(@as(?u64, null), history.inputMatch("x"));

    // A removed key does not come back from a merge until picked again.
    var other: History = .{};
    other.record("a", t0);
    history.merge(&other);
    try testing.expectEqual(@as(u64, 0), history.rank("a"));
    history.record("a", t0 + 1);
    try testing.expect(history.rank("a") > 0);

    history.clear();
    try testing.expect(history.isEmpty());
    try testing.expect(history.replace);
}

test "input history offers the entry picked after typing the same text" {
    var history: History = .{};
    try testing.expectEqual(@as(?u64, null), history.inputMatch("se"));

    history.recordInput("sett", "settings");
    try testing.expectEqual(keyHash("settings"), history.inputMatch("s").?);
    try testing.expectEqual(keyHash("settings"), history.inputMatch("SETT").?);
    try testing.expectEqual(keyHash("settings"), history.inputMatch("ｓｅ").?);
    try testing.expectEqual(@as(?u64, null), history.inputMatch("setti"));
    try testing.expectEqual(@as(?u64, null), history.inputMatch("x"));
    try testing.expectEqual(@as(?u64, null), history.inputMatch(""));

    // An entry picked twice after the same text needs two picks of another
    // one to give way.
    history.recordInput("sett", "settings");
    history.recordInput("se", "search");
    try testing.expectEqual(keyHash("settings"), history.inputMatch("se").?);
    history.recordInput("se", "search");
    try testing.expectEqual(keyHash("search"), history.inputMatch("se").?);
    try testing.expectEqual(keyHash("settings"), history.inputMatch("set").?);

    // Blanks are normalized.
    history.recordInput("  new   tab ", "new_tab");
    try testing.expectEqual(keyHash("new_tab"), history.inputMatch("new tab").?);
    try testing.expectEqual(keyHash("new_tab"), history.inputMatch("new\u{3000}t").?);
    try testing.expectEqual(@as(?u64, null), history.inputMatch("newt"));
}

test "merge keeps the later time and the larger count" {
    var a: History = .{};
    var b: History = .{};
    a.record("x", t0);
    b.record("x", t0 + day);
    b.record("y", t0);
    b.recordInput("q", "y");
    b.recordInput("q", "y");
    a.recordInput("q", "y");
    a.merge(&b);
    try testing.expectEqual(b.rank("x"), a.rank("x"));
    try testing.expect(a.rank("y") > 0);
    try testing.expectEqual(keyHash("y"), a.inputMatch("q").?);
    try testing.expectApproxEqAbs(@as(f32, 1.9), a.inputs[a.findInput(a.inputs[0].prefix, keyHash("y")).?].uses, 1e-6);
}

test "write and parse round-trip; other versions and junk are skipped" {
    var history: History = .{};
    history.record("secret-entry", t0);
    history.record("secret-entry", t0 + 3 * day);
    history.record("b", t0 - 2 * day);
    history.recordInput("typed-text", "secret-entry");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try history.write(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "secret-entry") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "typed-text") == null);

    const parsed = History.parse(out.written());
    try testing.expectEqual(history.picks_len, parsed.picks_len);
    try testing.expectEqual(history.inputs_len, parsed.inputs_len);
    try testing.expectEqual(history.rank("secret-entry"), parsed.rank("secret-entry"));
    try testing.expectEqual(history.rank("b"), parsed.rank("b"));
    try testing.expectEqual(keyHash("secret-entry"), parsed.inputMatch("typed").?);

    try testing.expect(History.parse("version 2\npick 0000000000000001 1\n").isEmpty());
    try testing.expect(History.parse("pick 0000000000000001 1\n").isEmpty());
    const junk = History.parse(
        \\version 1
        \\pick zz 1
        \\pick 0000000000000001 nan
        \\pick 0000000000000001
        \\input 0000000000000001 0000000000000002 -1
        \\bogus line
        \\pick 0000000000000003 1760000000
        \\
    );
    try testing.expectEqual(@as(usize, 1), junk.picks_len);
    try testing.expectEqual(@as(usize, 0), junk.inputs_len);
}

test "commit merges with the file and replaces it" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "ghostty", file_name });
    defer alloc.free(path);

    try testing.expect((try History.load(alloc, io, path)).isEmpty());

    // Two processes pick different entries.
    var first: History = .{};
    var second: History = .{};
    first.record("a", t0);
    try first.commit(alloc, io, path);
    second.record("b", t0 + 1);
    try second.commit(alloc, io, path);

    var loaded = try History.load(alloc, io, path);
    try testing.expect(loaded.rank("a") > 0);
    try testing.expect(loaded.rank("b") > 0);

    // A removal sticks although the file still had the key.
    loaded.remove("a");
    try loaded.commit(alloc, io, path);
    const after_remove = try History.load(alloc, io, path);
    try testing.expectEqual(@as(u64, 0), after_remove.rank("a"));
    try testing.expect(after_remove.rank("b") > 0);

    // Clearing empties the file.
    second.clear();
    try second.commit(alloc, io, path);
    try testing.expect((try History.load(alloc, io, path)).isEmpty());
}
