//! Bounded session structure, never a transcript or command replay format.
//! App runtimes resolve each stable profile against CURRENT trusted config and
//! ask before restoring custom profiles. Parsed values own all strings.
const std = @import("std");

pub const version = 1;
pub const max_file_bytes = 1024 * 1024;
pub const max_windows = 16;
pub const max_tabs = 64;
pub const max_nodes = 511;
pub const max_total_leaves = 4096;
pub const max_depth = 32;
pub const file_name = "gx-session.json";

pub const Cwd = struct {
    kind: enum { posix, windows },
    path: []const u8,
};

pub const Leaf = struct {
    profile_id: []const u8,
    cwd: ?Cwd = null,
    cwd_unavailable: bool = false,
    font_size: ?f32 = null,
    title_override: ?[]const u8 = null,
};

pub const Split = struct {
    axis: enum { horizontal, vertical },
    ratio: f32,
    first: u16,
    second: u16,
};

/// Exactly one payload must be present. Flat indices avoid unbounded recursive
/// JSON allocation and let validation reject cycles, aliases and orphan nodes.
pub const Node = struct { leaf: ?Leaf = null, split: ?Split = null };
pub const Tab = struct {
    nodes: []const Node,
    root: u16 = 0,
    active: u16,
    zoom: ?u16 = null,
    title_override: ?[]const u8 = null,
};
pub const Geometry = struct {
    width: u32,
    height: u32,
    x: ?i32 = null,
    y: ?i32 = null,
    dpi: u32 = 96,
    maximized: bool = false,
};
pub const Window = struct {
    tabs: []const Tab,
    active: u16,
    geometry: ?Geometry = null,
    title_override: ?[]const u8 = null,
};
pub const Document = struct {
    version: u32,
    generation: u64,
    windows: []const Window,
    /// Count only; no commands, titles or other data from non-restorable leaves.
    skipped_leaves: u32 = 0,
};

pub const Parsed = std.json.Parsed(Document);
pub const Error = error{
    UnsupportedVersion,
    InvalidGeneration,
    LimitExceeded,
    InvalidTree,
    InvalidText,
    InvalidCwd,
    InvalidFontSize,
    InvalidGeometry,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len > max_file_bytes) return error.LimitExceeded;
    const parsed = try std.json.parseFromSlice(Document, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_file_bytes,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn encode(allocator: std.mem.Allocator, document: Document) ![]u8 {
    try validate(document);
    const bytes = try std.json.Stringify.valueAlloc(allocator, document, .{});
    errdefer allocator.free(bytes);
    if (bytes.len > max_file_bytes) return error.LimitExceeded;
    return bytes;
}

pub fn validate(document: Document) Error!void {
    if (document.version != version) return error.UnsupportedVersion;
    if (document.generation == 0) return error.InvalidGeneration;
    if (document.windows.len > max_windows) return error.LimitExceeded;
    if (document.skipped_leaves > max_total_leaves) return error.LimitExceeded;
    var leaves: usize = 0;
    for (document.windows) |window| {
        if (window.tabs.len == 0 or window.tabs.len > max_tabs) return error.LimitExceeded;
        if (window.active >= window.tabs.len) return error.InvalidTree;
        try title(window.title_override);
        if (window.geometry) |g| {
            if (g.width < 64 or g.height < 64 or g.width > 32768 or g.height > 32768 or
                g.dpi < 48 or g.dpi > 768 or (g.x == null) != (g.y == null)) return error.InvalidGeometry;
        }
        for (window.tabs) |tab| {
            if (tab.nodes.len == 0 or tab.nodes.len > max_nodes) return error.LimitExceeded;
            if (!isLeaf(tab, tab.active)) return error.InvalidTree;
            if (tab.zoom) |zoom| if (!isLeaf(tab, zoom)) return error.InvalidTree;
            try title(tab.title_override);
            var visited = [_]bool{false} ** max_nodes;
            leaves += try visit(tab, tab.root, 0, &visited);
            for (visited[0..tab.nodes.len]) |seen| if (!seen) return error.InvalidTree;
            if (leaves > max_total_leaves) return error.LimitExceeded;
        }
    }
}

fn isLeaf(tab: Tab, index: u16) bool {
    return index < tab.nodes.len and tab.nodes[index].leaf != null and tab.nodes[index].split == null;
}

fn visit(tab: Tab, index: u16, depth: usize, visited: *[max_nodes]bool) Error!usize {
    if (depth > max_depth) return error.LimitExceeded;
    if (index >= tab.nodes.len or visited[index]) return error.InvalidTree;
    visited[index] = true;
    const node = tab.nodes[index];
    if ((node.leaf == null) == (node.split == null)) return error.InvalidTree;
    if (node.leaf) |leaf| {
        try text(leaf.profile_id, 1024, false);
        try title(leaf.title_override);
        if (leaf.font_size) |size| {
            if (!std.math.isFinite(size) or size < 1 or size > 512) return error.InvalidFontSize;
        }
        if (leaf.cwd) |cwd| try validateCwd(cwd);
        return 1;
    }
    const split = node.split.?;
    if (!std.math.isFinite(split.ratio) or split.ratio <= 0 or split.ratio >= 1) return error.InvalidTree;
    const first = try visit(tab, split.first, depth + 1, visited);
    return first + try visit(tab, split.second, depth + 1, visited);
}

fn text(value: []const u8, limit: usize, allow_empty: bool) Error!void {
    if (value.len > limit or (!allow_empty and value.len == 0) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidText;
}

fn title(value: ?[]const u8) Error!void {
    if (value) |v| try text(v, 1024, true);
}

/// Does not probe a path or contact a network. Runtime checks existence only
/// after this lexical gate and only in the profile's matching local domain.
pub fn validateCwd(cwd: Cwd) Error!void {
    try text(cwd.path, 4096, false);
    switch (cwd.kind) {
        .posix => {
            if (cwd.path[0] != '/' or std.mem.startsWith(u8, cwd.path, "//")) return error.InvalidCwd;
            if (std.mem.indexOfScalar(u8, cwd.path, '\\') != null) return error.InvalidCwd;
        },
        .windows => {
            if (cwd.path.len < 3 or !std.ascii.isAlphabetic(cwd.path[0]) or cwd.path[1] != ':' or
                (cwd.path[2] != '/' and cwd.path[2] != '\\')) return error.InvalidCwd;
            for (cwd.path[2..]) |byte| {
                if (byte == ':' or byte == '*' or byte == '?' or byte == '"' or byte == '<' or byte == '>' or byte == '|') return error.InvalidCwd;
            }
        },
    }
    var parts = std.mem.tokenizeAny(u8, cwd.path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidCwd;
    }
}

pub const RestoreDecision = enum { restore, confirm_custom, skip_missing };

/// The caller must find an EXACT stable ID in the current trusted profile list.
/// Neither a display-name fallback nor a stored command can authorize restore.
pub fn restoreDecision(profile_id: []const u8, exact_current_profile_exists: bool) RestoreDecision {
    if (!exact_current_profile_exists) return .skip_missing;
    return if (std.mem.startsWith(u8, profile_id, "custom:")) .confirm_custom else .restore;
}

/// Single-writer lease on a separate inode, retained across atomic replacement
/// of the document. Kernel handle lifetime, never lock age, controls recovery.
/// The caller supplies its private state directory (Windows ACL inherited).
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    lock: std.Io.File,
    name: []u8,
    generation: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !Store {
        if (!std.fs.path.isAbsolute(absolute_path)) return error.InvalidPath;
        const parent = std.fs.path.dirname(absolute_path) orelse return error.InvalidPath;
        const name = try allocator.dupe(u8, std.fs.path.basename(absolute_path));
        errdefer allocator.free(name);
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, parent, .{});
        errdefer dir.close(io);
        const lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{name});
        defer allocator.free(lock_name);
        const lock = dir.createFile(io, lock_name, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = private_permissions,
        }) catch |err| return if (err == error.WouldBlock) error.Busy else err;
        errdefer lock.close(io);
        var self: Store = .{ .allocator = allocator, .io = io, .dir = dir, .lock = lock, .name = name };
        if (try self.load()) |parsed| {
            defer parsed.deinit();
            self.generation = parsed.value.generation;
        }
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.lock.unlock(self.io);
        self.lock.close(self.io);
        self.dir.close(self.io);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn load(self: *const Store) !?Parsed {
        const bytes = self.dir.readFileAlloc(self.io, self.name, self.allocator, .limited(max_file_bytes + 1)) catch |err| return switch (err) {
            error.FileNotFound => null,
            else => err,
        };
        defer self.allocator.free(bytes);
        return try parse(self.allocator, bytes);
    }

    /// Persist exactly the next generation. Validation, serialization and file
    /// sync finish before replacement; all earlier failures preserve the file.
    pub fn save(self: *Store, document: Document) !void {
        const next = std.math.add(u64, self.generation, 1) catch return error.GenerationExhausted;
        if (document.generation != next) return error.StaleGeneration;
        if (try self.load()) |current| {
            defer current.deinit();
            if (current.value.generation != self.generation) return error.StaleGeneration;
        } else if (self.generation != 0) return error.StaleGeneration;
        const bytes = try encode(self.allocator, document);
        defer self.allocator.free(bytes);
        var pending = try self.dir.createFileAtomic(self.io, self.name, .{ .replace = true, .permissions = private_permissions });
        defer pending.deinit(self.io);
        try pending.file.writeStreamingAll(self.io, bytes);
        try pending.file.sync(self.io);
        try pending.replace(self.io);
        self.generation = next;
    }
};

const private_permissions: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows)
    .default_file
else
    .fromMode(0o600);

const sample =
    \\{"version":1,"generation":1,"windows":[{"active":0,"tabs":[{"active":1,"zoom":2,"nodes":[{"split":{"axis":"horizontal","ratio":0.35,"first":1,"second":2}},{"leaf":{"profile_id":"pwsh","cwd":{"kind":"windows","path":"C:/work"},"font_size":13.5}},{"leaf":{"profile_id":"custom:中文","title_override":"标题 🚀"}}]}]}]}
;

test "session structural round trip owns its strings and preserves nested state" {
    const alloc = std.testing.allocator;
    const parsed = try parse(alloc, sample);
    defer parsed.deinit();
    const bytes = try encode(alloc, parsed.value);
    defer alloc.free(bytes);
    const again = try parse(alloc, bytes);
    defer again.deinit();
    try std.testing.expectEqualDeep(parsed.value, again.value);
    try std.testing.expectEqual(RestoreDecision.confirm_custom, restoreDecision("custom:中文", true));
    try std.testing.expectEqual(RestoreDecision.skip_missing, restoreDecision("pwsh", false));
    try std.testing.expectEqual(RestoreDecision.restore, restoreDecision("pwsh", true));
}

test "session rejects unknown executable fields future versions and bad generations" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnknownField, parse(alloc, "{\"version\":1,\"generation\":1,\"windows\":[],\"command\":\"bad\"}"));
    try std.testing.expectError(error.UnsupportedVersion, parse(alloc, "{\"version\":2,\"generation\":1,\"windows\":[]}"));
    try std.testing.expectError(error.InvalidGeneration, parse(alloc, "{\"version\":1,\"generation\":0,\"windows\":[]}"));
}

test "session rejects cycles aliases disconnected nodes and invalid active leaves" {
    var nodes = [_]Node{
        .{ .split = .{ .axis = .horizontal, .ratio = 0.5, .first = 1, .second = 2 } },
        .{ .leaf = .{ .profile_id = "pwsh" } },
        .{ .leaf = .{ .profile_id = "pwsh" } },
    };
    var tabs = [_]Tab{.{ .nodes = &nodes, .active = 1 }};
    const windows = [_]Window{.{ .tabs = &tabs, .active = 0 }};
    const doc: Document = .{ .version = 1, .generation = 1, .windows = &windows };
    try validate(doc);
    nodes[0].split.?.first = 0;
    try std.testing.expectError(error.InvalidTree, validate(doc));
    nodes[0].split.?.first = 2;
    try std.testing.expectError(error.InvalidTree, validate(doc));
    nodes[0].split.?.first = 1;
    tabs[0].root = 1;
    try std.testing.expectError(error.InvalidTree, validate(doc));
    tabs[0].root = 0;
    tabs[0].active = 0;
    try std.testing.expectError(error.InvalidTree, validate(doc));
    tabs[0].active = 1;
    nodes[0].split.?.ratio = std.math.nan(f32);
    try std.testing.expectError(error.InvalidTree, validate(doc));
}

test "session cwd gate rejects remote device relative traversal and injection paths" {
    for ([_][]const u8{ "\\\\server\\share", "\\\\?\\C:\\x", "C:relative", "C:/../x", "C:/x:stream", "C:/line\nnext" }) |path| {
        if (validateCwd(.{ .kind = .windows, .path = path })) |_| return error.TestUnexpectedResult else |_| {}
    }
    for ([_][]const u8{ "relative", "//server/share", "/a/../b" }) |path| {
        try std.testing.expectError(error.InvalidCwd, validateCwd(.{ .kind = .posix, .path = path }));
    }
    try validateCwd(.{ .kind = .posix, .path = "/home/user/中文" });
    try validateCwd(.{ .kind = .windows, .path = "C:\\work\\中文" });
}

test "session store holds a writer lease and preserves prior state on rejected writes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, file_name });
    defer alloc.free(path);
    var store = try Store.open(alloc, io, path);
    var closed = false;
    defer if (!closed) store.deinit();
    try std.testing.expect((try store.load()) == null);
    try std.testing.expectError(error.Busy, Store.open(alloc, io, path));
    const parsed = try parse(alloc, sample);
    defer parsed.deinit();
    try store.save(parsed.value);
    try std.testing.expectError(error.StaleGeneration, store.save(parsed.value));
    var bad = parsed.value;
    bad.generation = 2;
    bad.version = 99;
    try std.testing.expectError(error.UnsupportedVersion, store.save(bad));
    const saved = (try store.load()).?;
    defer saved.deinit();
    try std.testing.expectEqualDeep(parsed.value, saved.value);
    // Closing the last normal window saves an empty document, not the old tree.
    try store.save(.{ .version = 1, .generation = 2, .windows = &.{} });
    store.deinit();
    closed = true;
    var reopened = try Store.open(alloc, io, path);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 2), reopened.generation);
    const empty = (try reopened.load()).?;
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.windows.len);
}
