//! The Ghostty GX settings overlay `gui-settings.ghostty`: a configuration
//! file next to the user's `config.ghostty` that the settings UI edits.
//! Its settings override the user configuration (see `config_layers.zig`).
//!
//! `Overlay` edits the file line by line so comments, blank lines, unknown
//! keys and the order of entries survive, and `save` replaces the file
//! atomically.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The file name of the overlay, in the directory of the preferred user
/// configuration file.
pub const file_name = "gui-settings.ghostty";

/// The comment written at the top of a new overlay file.
pub const header =
    \\# This file is managed by the Ghostty GX settings UI.
    \\#
    \\# Settings here override config.ghostty, and command-line flags override
    \\# both. The settings UI rewrites this file; to keep a setting out of its
    \\# control, remove it here and set it in config.ghostty instead.
;

pub const Error = error{
    /// A key or value cannot be represented on a configuration line.
    InvalidSetting,
};

pub const Overlay = struct {
    alloc: Allocator,

    /// The lines of the file without line terminators.
    lines: std.ArrayList([]u8) = .empty,

    /// Whether the file existed when it was loaded. A new overlay refuses
    /// to replace a file that appeared in the meantime.
    existed: bool = false,

    /// A new overlay containing only `header`.
    pub fn init(alloc: Allocator) Allocator.Error!Overlay {
        var self: Overlay = .{ .alloc = alloc };
        errdefer self.deinit();
        var it = std.mem.splitScalar(u8, header, '\n');
        while (it.next()) |line| try self.appendLine(line);
        try self.appendLine("");
        return self;
    }

    /// Parses overlay file contents. A UTF-8 byte order mark and CR line
    /// endings are dropped.
    pub fn parse(alloc: Allocator, text: []const u8) Allocator.Error!Overlay {
        var self: Overlay = .{ .alloc = alloc, .existed = true };
        errdefer self.deinit();
        const bom = "\xef\xbb\xbf";
        const body = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            if (it.index == null and raw.len == 0) break;
            try self.appendLine(std.mem.trimEnd(u8, raw, "\r"));
        }
        return self;
    }

    /// Loads the overlay at `path`. A missing file gives a new overlay
    /// (`init`); any other error is returned so a file that could not be
    /// read is never overwritten.
    pub fn load(alloc: Allocator, io: std.Io, path: []const u8) !Overlay {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => return try init(alloc),
            else => return err,
        };
        defer alloc.free(text);
        return try parse(alloc, text);
    }

    /// The largest overlay file `load` accepts.
    pub const max_file_size = 1024 * 1024;

    pub fn deinit(self: *Overlay) void {
        for (self.lines.items) |line| self.alloc.free(line);
        self.lines.deinit(self.alloc);
        self.* = undefined;
    }

    /// The value of the last `key = value` line for `key`, with one pair of
    /// surrounding double quotes removed like the configuration parser
    /// does, or null if the key is not set.
    pub fn get(self: *const Overlay, key: []const u8) ?[]const u8 {
        var i = self.lines.items.len;
        while (i > 0) {
            i -= 1;
            const entry = parseLine(self.lines.items[i]) orelse continue;
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    /// Sets `key` to `value`, replacing every existing line for `key`. The
    /// new line takes the place of the first existing one, or is appended.
    pub fn set(self: *Overlay, key: []const u8, value: []const u8) (Allocator.Error || Error)!void {
        try self.setAll(key, &.{value});
    }

    /// Sets a repeatable key (such as `font-family` or `keybind`) to
    /// `values`, one line each, replacing every existing line for `key`.
    /// An empty `values` removes the key like `delete`.
    pub fn setAll(self: *Overlay, key: []const u8, values: []const []const u8) (Allocator.Error || Error)!void {
        try validateKey(key);
        for (values) |value| try validateValue(value);

        var formatted: std.ArrayList([]u8) = .empty;
        defer {
            for (formatted.items) |line| self.alloc.free(line);
            formatted.deinit(self.alloc);
        }
        for (values) |value| try formatted.append(self.alloc, try formatLine(self.alloc, key, value));

        const position = self.removeKey(key) orelse self.lines.items.len;
        try self.lines.insertSlice(self.alloc, position, formatted.items);
        formatted.clearRetainingCapacity();
    }

    /// Removes every line for `key`. Returns true if any line was removed.
    pub fn delete(self: *Overlay, key: []const u8) bool {
        return self.removeKey(key) != null;
    }

    /// Removes the lines for `key` and returns the index of the first one.
    fn removeKey(self: *Overlay, key: []const u8) ?usize {
        var first: ?usize = null;
        var i: usize = 0;
        while (i < self.lines.items.len) {
            const entry = parseLine(self.lines.items[i]) orelse {
                i += 1;
                continue;
            };
            if (!std.mem.eql(u8, entry.key, key)) {
                i += 1;
                continue;
            }
            if (first == null) first = i;
            self.alloc.free(self.lines.orderedRemove(i));
        }
        return first;
    }

    /// Writes the overlay with LF line endings.
    pub fn write(self: *const Overlay, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.lines.items) |line| {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }

    /// Atomically writes the overlay to `path` (absolute), creating the
    /// parent directory if needed: the content goes to a temporary file
    /// that then replaces `path`. A new overlay (`existed` is false) fails
    /// with `error.PathAlreadyExists` instead of replacing a file that
    /// appeared since it was loaded.
    pub fn save(self: *Overlay, io: std.Io, path: []const u8) !void {
        const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dir.close(io);

        var buf: [4096]u8 = undefined;
        var atomic_file = try dir.createFileAtomic(io, std.fs.path.basename(path), .{
            .replace = self.existed,
        });
        defer atomic_file.deinit(io);
        var file_writer = atomic_file.file.writer(io, &buf);
        self.write(&file_writer.interface) catch return file_writer.err orelse error.WriteFailed;
        file_writer.interface.flush() catch return file_writer.err orelse error.WriteFailed;
        if (self.existed) try atomic_file.replace(io) else try atomic_file.link(io);
        self.existed = true;
    }

    fn appendLine(self: *Overlay, line: []const u8) Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, line);
        errdefer self.alloc.free(copy);
        try self.lines.append(self.alloc, copy);
    }
};

/// A `key = value` line, parsed like `cli.args.LineIterator` does.
const Entry = struct {
    key: []const u8,
    value: []const u8,
};

const whitespace = " \t";

fn parseLine(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, whitespace ++ "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return .{ .key = trimmed, .value = "" };
    var value = std.mem.trim(u8, trimmed[eq + 1 ..], whitespace);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return .{
        .key = std.mem.trim(u8, trimmed[0..eq], whitespace),
        .value = value,
    };
}

fn validateKey(key: []const u8) Error!void {
    if (key.len == 0) return error.InvalidSetting;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidSetting;
    }
}

fn validateValue(value: []const u8) Error!void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidSetting;
}

/// Formats `key = value`, quoting the value when the parser would
/// otherwise change it (surrounding whitespace or quotes). An empty value
/// is written as `key =`, which resets the key to its default.
fn formatLine(alloc: Allocator, key: []const u8, value: []const u8) Allocator.Error![]u8 {
    if (value.len == 0) return try std.fmt.allocPrint(alloc, "{s} =", .{key});
    const needs_quotes = std.mem.indexOfScalar(u8, whitespace, value[0]) != null or
        std.mem.indexOfScalar(u8, whitespace, value[value.len - 1]) != null or
        (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"');
    return if (needs_quotes)
        try std.fmt.allocPrint(alloc, "{s} = \"{s}\"", .{ key, value })
    else
        try std.fmt.allocPrint(alloc, "{s} = {s}", .{ key, value });
}

fn expectContent(overlay: *const Overlay, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try overlay.write(&out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "new overlay starts with the header" {
    const testing = std.testing;
    var overlay = try Overlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.set("font-size", "14");
    try expectContent(&overlay, header ++ "\n\nfont-size = 14\n");
    try testing.expect(!overlay.existed);
}

test "set, get and delete preserve comments, order and unknown lines" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator,
        \\# my overlay
        \\theme = Dracula
        \\
        \\unknown-key = keep me
        \\  # indented comment
        \\font-size = 13
        \\keybind = ctrl+a=copy_to_clipboard
        \\keybind = ctrl+b=paste_from_clipboard
        \\font-size = 15
        \\
    );
    defer overlay.deinit();

    try testing.expectEqualStrings("Dracula", overlay.get("theme").?);
    try testing.expectEqualStrings("15", overlay.get("font-size").?);
    try testing.expectEqualStrings("keep me", overlay.get("unknown-key").?);
    try testing.expectEqual(@as(?[]const u8, null), overlay.get("language"));

    try overlay.set("font-size", "16");
    try overlay.set("language", "en");
    try overlay.setAll("keybind", &.{"alt+1=unbind"});
    try testing.expect(overlay.delete("theme"));
    try testing.expect(!overlay.delete("theme"));

    try expectContent(&overlay,
        \\# my overlay
        \\
        \\unknown-key = keep me
        \\  # indented comment
        \\font-size = 16
        \\keybind = alt+1=unbind
        \\language = en
        \\
    );
}

test "setAll writes repeatable keys and removes them when empty" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator, "font-family = A\nfont-size = 12\n");
    defer overlay.deinit();

    try overlay.setAll("font-family", &.{ "JetBrainsMono Nerd Font", "Noto Sans CJK SC" });
    try expectContent(&overlay,
        \\font-family = JetBrainsMono Nerd Font
        \\font-family = Noto Sans CJK SC
        \\font-size = 12
        \\
    );

    try overlay.setAll("font-family", &.{});
    try expectContent(&overlay, "font-size = 12\n");
}

test "values are quoted when the parser would change them" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator, "");
    defer overlay.deinit();

    try overlay.set("a", " padded ");
    try overlay.set("b", "\"quoted\"");
    try overlay.set("c", "");
    try overlay.set("gx-launch-profile", "Python=python -i");
    try expectContent(&overlay,
        \\a = " padded "
        \\b = ""quoted""
        \\c =
        \\gx-launch-profile = Python=python -i
        \\
    );
    try testing.expectEqualStrings(" padded ", overlay.get("a").?);
    try testing.expectEqualStrings("\"quoted\"", overlay.get("b").?);
    try testing.expectEqualStrings("", overlay.get("c").?);

    try testing.expectError(error.InvalidSetting, overlay.set("bad key", "x"));
    try testing.expectError(error.InvalidSetting, overlay.set("", "x"));
    try testing.expectError(error.InvalidSetting, overlay.set("a", "two\nlines"));
    try testing.expectEqualStrings(" padded ", overlay.get("a").?);
}

test "parse drops a BOM and CR line endings" {
    const testing = std.testing;
    var overlay = try Overlay.parse(testing.allocator, "\xef\xbb\xbf# c\r\nfont-size = 11\r\n");
    defer overlay.deinit();
    try testing.expectEqualStrings("11", overlay.get("font-size").?);
    try expectContent(&overlay, "# c\nfont-size = 11\n");
}

test "load and save round-trip through a directory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "ghostty", file_name });
    defer alloc.free(path);

    {
        var overlay = try Overlay.load(alloc, io, path);
        defer overlay.deinit();
        try testing.expect(!overlay.existed);
        try overlay.set("theme", "GX Mocha");
        try overlay.save(io, path);
        try testing.expect(overlay.existed);
        try overlay.set("font-size", "13");
        try overlay.save(io, path);
    }

    var overlay = try Overlay.load(alloc, io, path);
    defer overlay.deinit();
    try testing.expect(overlay.existed);
    try testing.expectEqualStrings("GX Mocha", overlay.get("theme").?);
    try testing.expectEqualStrings("13", overlay.get("font-size").?);
    try expectContent(&overlay, header ++ "\n\ntheme = GX Mocha\nfont-size = 13\n");

    var entries = try tmp.dir.openDir(io, "ghostty", .{ .iterate = true });
    defer entries.close(io);
    var it = entries.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        try testing.expectEqualStrings(file_name, entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "a new overlay does not replace a file created after loading" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, file_name });
    defer alloc.free(path);

    var overlay = try Overlay.load(alloc, io, path);
    defer overlay.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "font-size = 20\n" });

    try overlay.set("font-size", "10");
    try testing.expectError(error.PathAlreadyExists, overlay.save(io, path));

    var again = try Overlay.load(alloc, io, path);
    defer again.deinit();
    try testing.expectEqualStrings("20", again.get("font-size").?);
}

test "load refuses unreadable paths instead of starting over" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, file_name);
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, file_name });
    defer alloc.free(path);

    try testing.expect(std.meta.isError(Overlay.load(alloc, io, path)));
}
