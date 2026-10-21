//! The Ghostty GX UI language on the GTK apprt: applies the `language`
//! configuration to gettext (the upstream GTK strings) and to `gx.i18n`
//! (the Ghostty GX strings), at startup and when it changes at runtime.
//!
//! The language picks the gettext catalogs through `LANGUAGE`. glibc
//! ignores `LANGUAGE` while the messages locale is `C`, `POSIX` or
//! `C.UTF-8` (the WSL default), so the messages locale is switched to the
//! UTF-8 locale of the language when it is installed, else kept if it is
//! already a real locale, else set to the locale of another supported
//! language. Without any such locale only the `gx.i18n` strings follow the
//! language.
//!
//! Pango picks the fonts for Han characters, which Chinese, Japanese and
//! Korean write differently, by the first language of `PANGO_LANGUAGE` or
//! `LANGUAGE` that uses them. Switching `LANGUAGE` would lose the system's
//! preference, so `PANGO_LANGUAGE` (unless set) lists the UI language
//! followed by the language Ghostty was started with. Child processes get
//! the original `LANG`, `LANGUAGE` and `PANGO_LANGUAGE` back (see
//! `restoreChildEnv`). `hanGlyphAvailable` tells whether any font can show
//! the Chinese UI at all.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const input = @import("../../../input.zig");
const i18n = @import("../../../os/main.zig").i18n;
const gx = @import("../../../gx/main.zig");

const Language = gx.i18n.Language;
const log = std.log.scoped(.gtk_gx_language);

const c = @import("locale-c");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn textdomain(domainname: ?[*:0]const u8) ?[*:0]const u8;
extern "c" fn bind_textdomain_codeset(domainname: [*:0]const u8, codeset: ?[*:0]const u8) ?[*:0]const u8;

/// The value an environment variable had when Ghostty started, captured
/// once by `startup` on the main thread before anything else reads it, so
/// that child processes keep the system language.
const OriginalEnv = struct {
    name: [:0]const u8,
    state: enum { unknown, unset, set } = .unknown,
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn capture(self: *OriginalEnv) void {
        const env = global.environ().getPosix(self.name) orelse {
            self.state = .unset;
            return;
        };
        if (env.len > self.buf.len) {
            // Too long to keep: child processes then go without it.
            log.warn("{s} is {d} bytes, child processes will not inherit it", .{ self.name, env.len });
            self.state = .unset;
            return;
        }
        @memcpy(self.buf[0..env.len], env);
        self.len = env.len;
        self.state = .set;
    }

    fn get(self: *const OriginalEnv) ?[]const u8 {
        return switch (self.state) {
            .unknown, .unset => null,
            .set => self.buf[0..self.len],
        };
    }
};

var original_language: OriginalEnv = .{ .name = "LANGUAGE" };
var original_pango_language: OriginalEnv = .{ .name = "PANGO_LANGUAGE" };

/// Whether `startup` set `PANGO_LANGUAGE`, which child processes then go
/// without.
var pango_language_set = false;

/// Applies the configured language before GTK is initialized. This
/// replaces upstream's `LANG = language`, which breaks with GX values such
/// as `zh-CN` that are not locale names: `LANG` becomes the UTF-8 locale
/// of the language when that locale is installed, `LANGUAGE` selects the
/// catalogs, and GTK is told not to reset the locale again.
///
/// `config` was loaded before the language was known, so its command
/// palette entries were translated for the previous messages language;
/// when that changes the translation, the configuration is rebuilt in
/// memory from the inputs it recorded (`gx.config_layers.rebuild`).
pub fn startup(alloc: Allocator, config: *configpkg.Config) void {
    const lang = gx.i18n.resolve(config.language);
    const palette_before = paletteFingerprint();

    original_language.capture();
    original_pango_language.capture();
    var pango_buf: [320]u8 = undefined;
    const pango = pangoLanguages(
        &pango_buf,
        lang,
        original_language.get(),
        global.environ().getPosix("LANG"),
    );
    if (original_pango_language.state == .unset) {
        if (pango) |value| {
            _ = setenv("PANGO_LANGUAGE", value, 1);
            pango_language_set = true;
        }
    }
    if (localeInstalled(lang.posixLocale())) {
        _ = setenv("LANG", lang.posixLocale(), 1);
    } else {
        log.warn("locale {s} is not installed, keeping LANG", .{lang.posixLocale()});
    }
    _ = setenv("LANGUAGE", gettextLanguages(lang), 1);
    global.syncEnviron();

    // GTK would call setlocale(LC_ALL, "") again during initialization and
    // reset the messages locale chosen below.
    gtk.disableSetlocale();
    if (c.setlocale(c.LC_ALL, "") == null) {
        log.warn("locale not supported by the C library, using the fallback 'C' locale", .{});
    }
    selectMessagesLocale(lang);
    if (comptime build_config.i18n) {
        _ = bind_textdomain_codeset(build_config.bundle_id, "UTF-8");
    }
    gx.i18n.setCurrent(lang);
    log.info("UI language={s} LC_MESSAGES={s}", .{ lang.configValue(), messagesLocale() });

    if (paletteFingerprint() != palette_before) {
        const rebuilt = gx.config_layers.rebuild(config, alloc, &.{}) catch |err| {
            log.warn("rebuilding the configuration for the UI language failed err={}", .{err});
            return;
        };
        config.deinit();
        config.* = rebuilt;
    }
}

/// Switches the running app to `lang`: `LANGUAGE`, the messages locale,
/// the gettext caches and `gx.i18n`. Widgets that already exist keep their
/// text. Returns true if the default command palette entries translate
/// differently now; the configuration must then be loaded again because
/// `Config.default` translated them.
pub fn switchTo(lang: Language) bool {
    const palette_before = paletteFingerprint();

    // Runtime switching is the one place the GTK apprt changes the process
    // environment after startup: gettext reads LANGUAGE on every lookup.
    _ = setenv("LANGUAGE", gettextLanguages(lang), 1);
    global.syncEnviron();
    selectMessagesLocale(lang);
    // textdomain() bumps the catalog counter that invalidates the
    // translations gettext has cached for the previous language.
    if (comptime build_config.i18n) _ = textdomain(build_config.bundle_id);
    gx.i18n.setCurrent(lang);
    log.info("switched UI language={s} LC_MESSAGES={s}", .{ lang.configValue(), messagesLocale() });

    return paletteFingerprint() != palette_before;
}

/// Gives a child process environment the `LANGUAGE` value Ghostty was
/// started with (upstream restores `LANG` the same way), and removes the
/// `PANGO_LANGUAGE` that `startup` set.
pub fn restoreChildEnv(env: *std.process.Environ.Map) Allocator.Error!void {
    if (original_language.state == .unknown) return;
    try applyOriginal(env, "LANGUAGE", original_language.get());
    if (pango_language_set) try applyOriginal(env, "PANGO_LANGUAGE", null);
}

fn applyOriginal(env: *std.process.Environ.Map, name: []const u8, original: ?[]const u8) Allocator.Error!void {
    if (original) |value| {
        try env.put(name, value);
    } else {
        _ = env.orderedRemove(name);
    }
}

/// The `PANGO_LANGUAGE` list for the UI language `lang` when Ghostty
/// started with `LANGUAGE` (`language_env`) and `LANG` (`lang_env`): the
/// UI language, then the first of the two that names a language. Null
/// when there is nothing to add to `LANGUAGE = gettextLanguages(lang)`.
pub fn pangoLanguages(
    buf: []u8,
    lang: Language,
    language_env: ?[]const u8,
    lang_env: ?[]const u8,
) ?[:0]const u8 {
    const preferred: []const u8 = preferred: {
        if (language_env) |value| {
            if (value.len > 0) break :preferred value;
        }
        const locale = lang_env orelse return null;
        if (locale.len == 0 or isCLocale(locale)) return null;
        const end = std.mem.indexOfAny(u8, locale, ".@") orelse locale.len;
        break :preferred locale[0..end];
    };
    const ui = gettextLanguages(lang);
    if (std.mem.eql(u8, preferred, ui)) return null;
    return std.mem.printSentinel(buf, "{s}:{s}", .{ ui, preferred }, 0) catch null;
}

/// A common Han character (中) that every Chinese font has.
const han_sample: u32 = 0x4E2D;

/// Whether the fonts Pango picks for the text of `widget` in Chinese have
/// a glyph for Han characters, so the Chinese UI does not show boxes.
pub fn hanGlyphAvailable(widget: *gtk.Widget) bool {
    const context: *anyopaque = @ptrCast(widget.getPangoContext());
    const description = pango_context_get_font_description(context) orelse return true;
    const fontset = pango_context_load_fontset(
        context,
        description,
        pango_language_from_string("zh-cn"),
    ) orelse return true;
    defer gobject.Object.unref(@ptrCast(@alignCast(fontset)));
    const font = pango_fontset_get_font(fontset, han_sample) orelse return false;
    defer gobject.Object.unref(@ptrCast(@alignCast(font)));
    return pango_font_has_char(font, han_sample) != 0;
}

extern fn pango_context_get_font_description(context: *anyopaque) ?*anyopaque;
extern fn pango_context_load_fontset(context: *anyopaque, desc: *anyopaque, language: ?*anyopaque) ?*anyopaque;
extern fn pango_language_from_string(language: [*:0]const u8) ?*anyopaque;
extern fn pango_fontset_get_font(fontset: *anyopaque, wc: c_uint) ?*anyopaque;
extern fn pango_font_has_char(font: *anyopaque, wc: u32) c_int;

/// The window and tab title used before the terminal sets one.
pub fn fallbackTitle() [:0]const u8 {
    return gx.i18n.tr("Ghostty GX");
}

/// The `LANGUAGE` list for `lang`. English has no catalog, so gettext
/// returns the msgids.
pub fn gettextLanguages(lang: Language) [:0]const u8 {
    return switch (lang) {
        .zh_CN => "zh_CN",
        .en => "en",
    };
}

/// Whether gettext ignores `LANGUAGE` under the locale `name`.
pub fn isCLocale(name: []const u8) bool {
    return std.mem.eql(u8, name, "C") or
        std.mem.eql(u8, name, "POSIX") or
        std.mem.startsWith(u8, name, "C.");
}

fn selectMessagesLocale(lang: Language) void {
    if (c.setlocale(c.LC_MESSAGES, lang.posixLocale()) != null) return;
    if (!isCLocale(messagesLocale())) return;
    for (std.enums.values(Language)) |other| {
        if (other == lang) continue;
        if (c.setlocale(c.LC_MESSAGES, other.posixLocale()) != null) return;
    }
    log.warn(
        "no UTF-8 locale for messages is installed (generate {s} or {s}); GTK texts stay in English",
        .{ Language.zh_CN.posixLocale(), Language.en.posixLocale() },
    );
}

fn messagesLocale() [:0]const u8 {
    if (c.setlocale(c.LC_MESSAGES, null)) |name| return std.mem.sliceTo(name, 0);
    return "C";
}

fn localeInstalled(name: [:0]const u8) bool {
    const loc = c.newlocale(c.LC_ALL_MASK, name, null);
    if (loc == null) return false;
    c.freelocale(loc);
    return true;
}

/// A hash of the default command palette entries as gettext translates
/// them right now.
fn paletteFingerprint() u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (input.command.defaults) |cmd| {
        const translated = cmd.translated();
        hasher.update(translated.title);
        hasher.update(translated.description);
    }
    return hasher.final();
}

test "gettextLanguages names a catalog per language" {
    const testing = std.testing;
    try testing.expectEqualStrings("zh_CN", gettextLanguages(.zh_CN));
    try testing.expectEqualStrings("en", gettextLanguages(.en));
    for (std.enums.values(Language)) |lang| {
        try testing.expectEqual(@as(?Language, lang), gx.i18n.parseLanguage(gettextLanguages(lang)));
    }
}

test "isCLocale matches the locales where gettext ignores LANGUAGE" {
    const testing = std.testing;
    for ([_][]const u8{ "C", "POSIX", "C.UTF-8", "C.utf8" }) |name| {
        try testing.expect(isCLocale(name));
    }
    for ([_][]const u8{ "en_US.UTF-8", "zh_CN.utf8", "de_DE", "Ca_ES", "" }) |name| {
        try testing.expect(!isCLocale(name));
    }
}

test "applyOriginal restores or strips LANGUAGE" {
    const testing = std.testing;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try env.put("LANGUAGE", "zh_CN");
    try applyOriginal(&env, "LANGUAGE", "de:en");
    try testing.expectEqualStrings("de:en", env.get("LANGUAGE").?);

    try applyOriginal(&env, "LANGUAGE", null);
    try testing.expectEqual(@as(?[]const u8, null), env.get("LANGUAGE"));
    try applyOriginal(&env, "LANGUAGE", null);
    try testing.expectEqual(@as(?[]const u8, null), env.get("LANGUAGE"));

    try env.put("PANGO_LANGUAGE", "zh_CN:en");
    try applyOriginal(&env, "PANGO_LANGUAGE", null);
    try testing.expectEqual(@as(?[]const u8, null), env.get("PANGO_LANGUAGE"));
}

test "pangoLanguages puts the UI language before the language Ghostty started with" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("en:zh_CN", pangoLanguages(&buf, .en, null, "zh_CN.UTF-8").?);
    try testing.expectEqualStrings("zh_CN:ja_JP", pangoLanguages(&buf, .zh_CN, null, "ja_JP.UTF-8@euro").?);
    try testing.expectEqualStrings("en:zh_TW:en", pangoLanguages(&buf, .en, "zh_TW:en", "de_DE.UTF-8").?);
    try testing.expectEqualStrings("en:de_DE", pangoLanguages(&buf, .en, "", "de_DE").?);

    // Nothing to add to LANGUAGE.
    try testing.expectEqual(@as(?[:0]const u8, null), pangoLanguages(&buf, .zh_CN, null, null));
    try testing.expectEqual(@as(?[:0]const u8, null), pangoLanguages(&buf, .zh_CN, null, "C.UTF-8"));
    try testing.expectEqual(@as(?[:0]const u8, null), pangoLanguages(&buf, .en, null, "POSIX"));
    try testing.expectEqual(@as(?[:0]const u8, null), pangoLanguages(&buf, .zh_CN, "zh_CN", "en_US.UTF-8"));

    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(?[:0]const u8, null), pangoLanguages(&small, .zh_CN, null, "en_US.UTF-8"));
}
