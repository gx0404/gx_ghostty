//! UI language and translations for the Ghostty GX user interface, shared
//! by the win32 and GTK apprts.
//!
//! UI strings are English msgids. `tr` and `trRuntime` return the zh-CN
//! translation from the generated table `i18n/zh_CN.zig` (built by
//! `scripts/gx_i18n.py` from `po/zh_CN.po` and `i18n/gx.zh_CN.po`) while
//! the current language is zh-CN, and the msgid itself when the language
//! is English or the table has no entry. The current language is process
//! global and can be switched at runtime with `setCurrent`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zh_CN = @import("i18n/zh_CN.zig");

/// A UI language supported by Ghostty GX.
pub const Language = enum(u8) {
    zh_CN,
    en,

    /// The language used when the configuration does not set a
    /// supported value.
    pub const default: Language = .zh_CN;

    /// The canonical `language` configuration value.
    pub fn configValue(self: Language) [:0]const u8 {
        return switch (self) {
            .zh_CN => "zh-CN",
            .en => "en",
        };
    }

    /// The POSIX locale name, e.g. for `LANG` and gettext on GTK.
    pub fn posixLocale(self: Language) [:0]const u8 {
        return switch (self) {
            .zh_CN => "zh_CN.UTF-8",
            .en => "en_US.UTF-8",
        };
    }

    /// The name of the language in the language itself, for language
    /// pickers.
    pub fn nativeName(self: Language) [:0]const u8 {
        return switch (self) {
            .zh_CN => "中文",
            .en => "English",
        };
    }
};

/// Parses a language tag or locale name into a supported language.
///
/// Matching is case-insensitive and treats `_` like `-`; a POSIX codeset
/// or modifier (`.UTF-8`, `@euro`) is ignored. `zh`, `zh-CN`, `zh-SG` and
/// `zh-Hans*` map to `.zh_CN`; `en` and `en-*` map to `.en`. Anything
/// else, including traditional Chinese tags, returns null.
pub fn parseLanguage(value: []const u8) ?Language {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    const tag = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, ".@") orelse trimmed.len];

    var buf: [64]u8 = undefined;
    if (tag.len == 0 or tag.len > buf.len) return null;
    for (tag, buf[0..tag.len]) |c, *out| out.* = if (c == '_') '-' else std.ascii.toLower(c);

    var subtags = std.mem.splitScalar(u8, buf[0..tag.len], '-');
    const primary = subtags.first();
    if (std.mem.eql(u8, primary, "en")) return .en;
    if (!std.mem.eql(u8, primary, "zh")) return null;

    const region = subtags.next() orelse return .zh_CN;
    for ([_][]const u8{ "cn", "sg", "hans" }) |simplified| {
        if (std.mem.eql(u8, region, simplified)) return .zh_CN;
    }
    return null;
}

/// Resolves the `language` configuration value; unset or unsupported
/// values fall back to `Language.default`.
pub fn resolve(config_value: ?[]const u8) Language {
    const value = config_value orelse return .default;
    return parseLanguage(value) orelse .default;
}

var current_language: std.atomic.Value(Language) = .init(.default);

/// The current UI language of the process.
pub fn current() Language {
    return current_language.load(.acquire);
}

/// Switches the UI language of the process. UI code re-reads strings
/// through `tr`/`trRuntime` after switching.
pub fn setCurrent(lang: Language) void {
    current_language.store(lang, .release);
}

/// Returns the translation of `key` in `lang`, or null if there is none.
/// `key` is a msgid, or `msgctxt ++ "\x04" ++ msgid` for contextual
/// entries (see `trCtx`). English never has a translation.
pub fn lookup(lang: Language, key: []const u8) ?[:0]const u8 {
    return switch (lang) {
        .en => null,
        .zh_CN => find(&zh_CN.entries, key),
    };
}

/// Translates a comptime-known msgid into the current language. The table
/// lookup happens at compile time.
pub fn tr(comptime msgid: [:0]const u8) [:0]const u8 {
    const translated = comptime comptimeLookup(msgid);
    return switch (current()) {
        .zh_CN => translated orelse msgid,
        .en => msgid,
    };
}

/// Translates a comptime-known msgid within a gettext message context
/// (`msgctxt`), falling back to the msgid itself.
pub fn trCtx(comptime context: []const u8, comptime msgid: [:0]const u8) [:0]const u8 {
    const translated = comptime comptimeLookup(context ++ "\x04" ++ msgid);
    return switch (current()) {
        .zh_CN => translated orelse msgid,
        .en => msgid,
    };
}

/// Translates a msgid only known at runtime into the current language.
pub fn trRuntime(msgid: [:0]const u8) [:0]const u8 {
    return lookup(current(), msgid) orelse msgid;
}

fn comptimeLookup(comptime key: []const u8) ?[:0]const u8 {
    @setEvalBranchQuota(100_000);
    return find(&zh_CN.entries, key);
}

fn find(entries: []const zh_CN.Entry, key: []const u8) ?[:0]const u8 {
    const index = std.sort.binarySearch(
        zh_CN.Entry,
        entries,
        key,
        compareKey,
    ) orelse return null;
    return entries[index].msgstr;
}

fn compareKey(key: []const u8, entry: zh_CN.Entry) std.math.Order {
    return std.mem.order(u8, key, entry.key);
}

/// Writes `template` to `writer`, replacing every `{name}` placeholder
/// with the field `name` of `args` (a struct or tuple-like anonymous
/// struct). Strings are written as-is, numbers in decimal, enums and enum
/// literals by tag name; a null optional writes nothing. Placeholders that
/// `args` does not provide and braces that do not form a placeholder are
/// written verbatim.
pub fn format(
    writer: *std.Io.Writer,
    template: []const u8,
    args: anytype,
) std.Io.Writer.Error!void {
    var rest = template;
    outer: while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try writer.writeAll(rest[0..open]);
        rest = rest[open..];

        const close = std.mem.indexOfScalar(u8, rest, '}') orelse break;
        const name = rest[1..close];
        if (!isPlaceholderName(name)) {
            try writer.writeByte('{');
            rest = rest[1..];
            continue;
        }

        inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                try writeValue(writer, @field(args, field.name));
                rest = rest[close + 1 ..];
                continue :outer;
            }
        }

        try writer.writeAll(rest[0 .. close + 1]);
        rest = rest[close + 1 ..];
    }
    try writer.writeAll(rest);
}

/// Like `format`, but returns a newly allocated string owned by the
/// caller.
pub fn fill(
    alloc: Allocator,
    template: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    format(&out.writer, template, args) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn isPlaceholderName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8) return writer.writeAll(value),
            .one => switch (@typeInfo(info.child)) {
                .array => |array| if (array.child == u8) return writer.writeAll(value),
                else => {},
            },
            else => {},
        },
        .int, .comptime_int, .float, .comptime_float => return writer.print("{d}", .{value}),
        .@"enum", .enum_literal => return writer.writeAll(@tagName(value)),
        .bool => return writer.writeAll(if (value) "true" else "false"),
        .optional => {
            if (value) |v| try writeValue(writer, v);
            return;
        },
        else => {},
    }
    @compileError("unsupported placeholder value type: " ++ @typeName(T));
}

test "parseLanguage accepts zh-CN spellings" {
    const testing = std.testing;
    for ([_][]const u8{
        "zh-CN",
        "zh_CN",
        "zh-cn",
        "ZH_cn",
        "zh",
        "ZH",
        "zh-Hans",
        "zh-Hans-CN",
        "zh_hans_SG",
        "zh-SG",
        "zh_CN.UTF-8",
        " zh-CN\n",
    }) |value| {
        try testing.expectEqual(@as(?Language, .zh_CN), parseLanguage(value));
    }
}

test "parseLanguage accepts English spellings" {
    const testing = std.testing;
    for ([_][]const u8{ "en", "EN", "en-US", "en_GB", "en-us", "en_US.UTF-8", "en@euro" }) |value| {
        try testing.expectEqual(@as(?Language, .en), parseLanguage(value));
    }
}

test "parseLanguage rejects unsupported languages" {
    const testing = std.testing;
    for ([_][]const u8{
        "",
        " ",
        "C",
        "POSIX",
        "fr",
        "de-DE",
        "english",
        "eng",
        "zh-TW",
        "zh-Hant",
        "zh_HK",
        "zhx",
        "-en",
        ".UTF-8",
        "en" ** 40,
    }) |value| {
        try testing.expectEqual(@as(?Language, null), parseLanguage(value));
    }
}

test "resolve defaults to zh-CN" {
    const testing = std.testing;
    try testing.expectEqual(Language.zh_CN, resolve(null));
    try testing.expectEqual(Language.zh_CN, resolve(""));
    try testing.expectEqual(Language.zh_CN, resolve("fr"));
    try testing.expectEqual(Language.zh_CN, resolve("zh-CN"));
    try testing.expectEqual(Language.en, resolve("en"));
    try testing.expectEqual(Language.en, resolve("en-US"));
}

test "Language config values round-trip" {
    const testing = std.testing;
    for (std.enums.values(Language)) |lang| {
        try testing.expectEqual(@as(?Language, lang), parseLanguage(lang.configValue()));
        try testing.expectEqual(@as(?Language, lang), parseLanguage(lang.posixLocale()));
    }
    try testing.expectEqualStrings("中文", Language.zh_CN.nativeName());
    try testing.expectEqualStrings("English", Language.en.nativeName());
}

test "current language can be switched" {
    const testing = std.testing;
    const saved = current();
    defer setCurrent(saved);

    setCurrent(.en);
    try testing.expectEqual(Language.en, current());
    setCurrent(.zh_CN);
    try testing.expectEqual(Language.zh_CN, current());
}

test "tr translates in zh-CN and passes msgids through in English" {
    const testing = std.testing;
    const saved = current();
    defer setCurrent(saved);

    setCurrent(.zh_CN);
    try testing.expectEqualStrings("新建标签页", tr("New Tab"));
    try testing.expectEqualStrings("设置…", tr("Settings…"));
    try testing.expectEqualStrings("确定", tr("OK"));
    try testing.expectEqualStrings("Not a translated string", tr("Not a translated string"));

    setCurrent(.en);
    try testing.expectEqualStrings("New Tab", tr("New Tab"));
    try testing.expectEqualStrings("OK", tr("OK"));
}

test "trRuntime looks up runtime msgids" {
    const testing = std.testing;
    const saved = current();
    defer setCurrent(saved);

    var buf: [32]u8 = undefined;
    const msgid = try std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ "Close", "Tab" }, 0);

    setCurrent(.zh_CN);
    try testing.expectEqualStrings("关闭标签页", trRuntime(msgid));
    try testing.expectEqualStrings("unknown", trRuntime("unknown"));

    setCurrent(.en);
    try testing.expectEqualStrings("Close Tab", trRuntime(msgid));
}

test "trCtx falls back to the msgid" {
    const testing = std.testing;
    const saved = current();
    defer setCurrent(saved);

    setCurrent(.zh_CN);
    try testing.expectEqualStrings("Close", trCtx("no-such-context", "Close"));
    try testing.expectEqual(@as(?[:0]const u8, null), lookup(.zh_CN, "no-such-context\x04Close"));
}

test "lookup never translates English" {
    const testing = std.testing;
    try testing.expectEqual(@as(?[:0]const u8, null), lookup(.en, "New Tab"));
    try testing.expectEqualStrings("新建窗口", lookup(.zh_CN, "New Window").?);
    try testing.expectEqual(@as(?[:0]const u8, null), lookup(.zh_CN, ""));
}

test "generated table is sorted and unique" {
    const testing = std.testing;
    const entries = &zh_CN.entries;
    try testing.expect(entries.len > 0);
    for (entries[0 .. entries.len - 1], entries[1..]) |a, b| {
        try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, a.key, b.key));
    }
    for (entries) |entry| {
        try testing.expect(entry.key.len > 0);
        try testing.expect(entry.msgstr.len > 0);
        try testing.expectEqualStrings(entry.msgstr, lookup(.zh_CN, entry.key).?);
    }
}

test "seeded GX strings are translated" {
    for ([_][]const u8{
        "Language",
        "Appearance",
        "Font",
        "Interaction",
        "Shell",
        "About",
        "Solid",
        "Mica",
        "Acrylic",
        "Tabbed",
        "Font Size",
        "Right-Click Menu",
        "Bell",
        "Close Confirmation",
        "Default Shell",
        "Open Configuration File",
        "Search themes…",
        "Split Right",
        "Split Down",
        "Split Left",
        "Split Up",
        "Close Other Tabs",
        "Rename Tab",
        "Keyboard Shortcuts",
        "Command Palette",
        "Reload Configuration",
        "About Ghostty GX",
        "Quit",
        "New tab",
        "Main menu",
        "Close",
        "Command Prompt",
        "WSL: {name}",
        "Cancel",
        "Find…",
        "No results",
        "{current}/{total}",
        "Command finished",
    }) |msgid| {
        if (lookup(.zh_CN, msgid) == null) {
            std.debug.print("missing zh-CN translation for {s}\n", .{msgid});
            return error.TestUnexpectedResult;
        }
    }
}

test "format replaces placeholders" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;

    {
        var writer: std.Io.Writer = .fixed(&buf);
        try format(&writer, "WSL: {name}", .{ .name = "Ubuntu-24.04" });
        try testing.expectEqualStrings("WSL: Ubuntu-24.04", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try format(&writer, "{current}/{total}", .{ .current = 3, .total = @as(u32, 10) });
        try testing.expectEqualStrings("3/10", writer.buffered());
    }
    {
        const name: []const u8 = "herdr";
        const code: ?i32 = 1;
        const none: ?[]const u8 = null;
        var writer: std.Io.Writer = .fixed(&buf);
        try format(&writer, "{name} {code}{none} {mode} {ok}", .{
            .name = name,
            .code = code,
            .none = none,
            .mode = .dark,
            .ok = true,
        });
        try testing.expectEqualStrings("herdr 1 dark true", writer.buffered());
    }
}

test "format keeps unknown placeholders and stray braces" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try format(&writer, "{missing} {} {1x} {a b} {{x}} {open", .{ .x = "X" });
    try testing.expectEqualStrings("{missing} {} {1x} {a b} {X} {open", writer.buffered());
}

test "fill allocates the result" {
    const testing = std.testing;
    const saved = current();
    defer setCurrent(saved);
    setCurrent(.zh_CN);

    const result = try fill(testing.allocator, tr("The shell process exited with code {code}."), .{ .code = 127 });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Shell 进程已退出，退出码 127。", result);

    const empty = try fill(testing.allocator, "", .{});
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}
