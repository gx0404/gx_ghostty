//! The policy for opening URLs that terminal output chooses: OSC 8
//! hyperlinks (`open_url` with the kind `osc8`). Programs running in a
//! terminal pick these targets, so they must not reach the system opener
//! unchecked. Like the macOS app (`macos/Sources/Helpers/UntrustedURL.swift`):
//!
//!   - web (`http`, `https`) and mail (`mailto`) links open directly;
//!   - local files (`file:`), files on other computers (a `file:` URL with
//!     a host, which Windows opens as a UNC path) and other URL schemes,
//!     which start the application registered for them, ask first;
//!   - malformed targets, invisible or line-breaking characters, files
//!     whose type can run code, and URL schemes known to run code are
//!     refused.
//!
//! The decision depends on the text alone; app runtimes show the
//! confirmation outside core callbacks and open the URL. Checking a local
//! file further (does it exist, is it executable) is up to them.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Decision = union(enum) {
    /// Open without asking.
    allow,

    /// Ask the user first, showing `writeDisplay` of the URL.
    confirm: Confirm,

    /// Do not open; tell the user why.
    deny: Deny,
};

/// Why a URL needs confirmation.
pub const Confirm = enum {
    /// A file or folder on this computer.
    local_file,

    /// A file on another computer; opening it may connect to it.
    remote_file,

    /// A URL scheme that starts another application.
    custom_scheme,

    /// The msgid of the explanation, translated in `i18n/gx.zh_CN.po`.
    /// `custom_scheme` has a `{scheme}` placeholder.
    pub fn msgid(self: Confirm) [:0]const u8 {
        return switch (self) {
            .local_file => "The link opens a file on this computer.",
            .remote_file => "The link opens a file on another computer, which may connect to it.",
            .custom_scheme => "The link opens the application registered for {scheme} links.",
        };
    }
};

/// Why a URL is refused.
pub const Deny = enum {
    /// Not an absolute URL with a scheme.
    malformed,

    /// Control, invisible, direction-changing or line-breaking
    /// characters, which can hide part of the target.
    unsafe_characters,

    /// An `http` or `https` URL without a host.
    invalid_web_url,

    /// A file whose type can run code when opened.
    unsafe_file,

    /// A URL scheme known to run code or to be abused to.
    blocked_scheme,

    /// The msgid of the explanation, translated in `i18n/gx.zh_CN.po`.
    pub fn msgid(self: Deny) [:0]const u8 {
        return switch (self) {
            .malformed => "The link target is not a valid URL.",
            .unsafe_characters => "The link target contains invisible or line-breaking characters.",
            .invalid_web_url => "The web address has no host.",
            .unsafe_file => "Opening this file could run a program.",
            .blocked_scheme => "Links of this type can run programs.",
        };
    }
};

/// The msgids of the dialogs app runtimes show for `Decision`, translated
/// in `i18n/gx.zh_CN.po`.
pub const msg = struct {
    pub const confirm_title = "Open Link?";
    pub const open = "Open";
    pub const denied_title = "Link Not Opened";
};

/// The file systems whose path rules apply to `file:` URLs.
pub const Os = enum {
    windows,
    posix,

    pub const native: Os = if (@import("builtin").target.os.tag == .windows) .windows else .posix;
};

/// Where a URL is opened.
pub const Context = struct {
    os: Os = .native,

    /// The host name of this computer, which `file:` URLs may name for a
    /// local file like `localhost` (`ls --hyperlink` does); "" when not
    /// known.
    host_name: []const u8 = "",

    fn isLocalHost(self: Context, host: []const u8) bool {
        return host.len == 0 or
            std.ascii.eqlIgnoreCase(host, "localhost") or
            (self.host_name.len > 0 and std.ascii.eqlIgnoreCase(host, self.host_name));
    }
};

/// The decision for `url` opened in `context`.
pub fn decide(url: []const u8, context: Context) Decision {
    if (url.len == 0) return .{ .deny = .malformed };
    if (!std.unicode.utf8ValidateSlice(url)) return .{ .deny = .malformed };
    if (containsUnsafe(url)) return .{ .deny = .unsafe_characters };
    // RFC 3986 has no spaces in URLs; well-behaved programs percent-encode
    // them (`ls --hyperlink`, ripgrep).
    if (std.mem.indexOfScalar(u8, url, ' ') != null) return .{ .deny = .malformed };

    const name = scheme(url) orelse return .{ .deny = .malformed };
    const rest = url[name.len + 1 ..];

    if (eql(name, "http") or eql(name, "https")) {
        const host = authorityHost(rest) orelse return .{ .deny = .invalid_web_url };
        if (host.len == 0) return .{ .deny = .invalid_web_url };
        return .allow;
    }
    if (eql(name, "mailto")) {
        const address = rest[0 .. std.mem.indexOfAny(u8, rest, "?#") orelse rest.len];
        if (address.len == 0) return .{ .deny = .malformed };
        return .allow;
    }
    if (eql(name, "file")) return fileDecision(rest, context);

    for (blocked_schemes) |blocked| {
        if (eql(name, blocked)) return .{ .deny = .blocked_scheme };
    }
    return .{ .confirm = .custom_scheme };
}

/// The scheme of `url` (before the first colon), or null when `url` does
/// not start with one. Single letters are drive letters (`C:\…`), not
/// schemes.
pub fn scheme(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (colon < 2) return null;
    const name = url[0..colon];
    if (!std.ascii.isAlphabetic(name[0])) return null;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return name;
}

/// Writes `url` on one line for a confirmation or error dialog: the
/// characters `decide` refuses as unsafe are written as `\u{XXXX}`, so
/// nothing in the text can hide or reorder the rest of it.
pub fn writeDisplay(writer: *std.Io.Writer, url: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < url.len) {
        const len = std.unicode.utf8ByteSequenceLength(url[i]) catch {
            try writer.print("\\x{X:0>2}", .{url[i]});
            i += 1;
            continue;
        };
        if (i + len > url.len) {
            try writer.print("\\x{X:0>2}", .{url[i]});
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(url[i .. i + len]) catch {
            try writer.print("\\x{X:0>2}", .{url[i]});
            i += 1;
            continue;
        };
        if (isUnsafe(cp)) {
            try writer.print("\\u{{{X:0>4}}}", .{cp});
        } else {
            try writer.writeAll(url[i .. i + len]);
        }
        i += len;
    }
}

/// The path a `file:` URL names, percent-decoded, in the syntax of the
/// `context` file system: `C:\dir\file`, `\\server\share\file` (a URL
/// with the host of another computer) or `/dir/file`. Null for other URLs,
/// malformed escapes, queries and fragments. The caller owns the result.
pub fn filePath(alloc: Allocator, url: []const u8, context: Context) Allocator.Error!?[]u8 {
    const name = scheme(url) orelse return null;
    if (!eql(name, "file")) return null;
    const parts = fileParts(url[name.len + 1 ..]) orelse return null;
    const remote = !context.isLocalHost(parts.host);

    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(alloc);
    switch (context.os) {
        .posix => {
            if (remote) {
                try path.appendSlice(alloc, "//");
                try path.appendSlice(alloc, parts.host);
            }
            if (!try appendDecoded(alloc, &path, parts.path)) {
                path.deinit(alloc);
                return null;
            }
        },
        .windows => {
            var raw = parts.path;
            if (remote) {
                try path.appendSlice(alloc, "\\\\");
                try path.appendSlice(alloc, parts.host);
            } else if (raw.len >= 3 and raw[0] == '/' and isDrive(raw[1..])) {
                // `file:///C:/dir` names `C:\dir`.
                raw = raw[1..];
            }
            if (!try appendDecoded(alloc, &path, raw)) {
                path.deinit(alloc);
                return null;
            }
            std.mem.replaceScalar(u8, path.items, '/', '\\');
        },
    }
    if (path.items.len == 0) {
        path.deinit(alloc);
        return null;
    }
    return try path.toOwnedSlice(alloc);
}

/// URL schemes that run code, or are abused to, when their handler opens
/// them: script and data URLs, Windows search and help handlers (search-ms
/// and ms-msdt phishing), Office handlers that fetch and open remote
/// documents, and the app installer.
const blocked_schemes = [_][]const u8{
    "javascript",
    "vbscript",
    "jscript",
    "data",
    "search",
    "search-ms",
    "ms-search",
    "ms-msdt",
    "ms-officecmd",
    "ms-appinstaller",
    "ms-cxh",
    "ms-cxh-full",
    "shell",
    "hcp",
    "its",
    "ms-its",
    "mk",
    "res",
    "ms-excel",
    "ms-word",
    "ms-powerpoint",
    "ms-visio",
    "ms-access",
    "ms-publisher",
    "ms-project",
    "ms-infopath",
    "ms-spd",
    "ms-officeapp",
};

/// File extensions (lowercase, without the dot) of files that run code or
/// change the system when opened, on Windows and Linux desktops: a
/// terminal can show a Windows path in WSL and the other way around.
const unsafe_extensions = windows_extensions ++ macro_extensions ++ unix_extensions;

/// Windows programs, scripts, installers, shortcuts and shell handlers.
const windows_extensions = [_][]const u8{
    "exe",         "com",       "scr",                "pif",
    "cpl",         "bat",       "cmd",                "ps1",
    "psm1",        "psd1",      "ps1xml",             "psc1",
    "vbs",         "vbe",       "js",                 "jse",
    "wsf",         "wsh",       "wsc",                "hta",
    "msi",         "msp",       "mst",                "msix",
    "msixbundle",  "appx",      "appxbundle",         "appinstaller",
    "application", "appref-ms", "gadget",             "msc",
    "reg",         "inf",       "ins",                "isp",
    "lnk",         "url",       "website",            "chm",
    "hlp",         "jar",       "jnlp",               "sct",
    "shb",         "shs",       "scf",                "settingcontent-ms",
    "library-ms",  "search-ms", "searchconnector-ms", "diagcab",
    "xbap",        "vsto",      "ade",                "adp",
    "mde",         "mdb",       "accde",              "py",
    "pyw",         "pl",        "rb",                 "dll",
    "ocx",         "sys",       "drv",                "msh",
    "msh1",        "msh2",      "mshxml",             "msh1xml",
    "msh2xml",
};

/// Office documents with macros.
const macro_extensions = [_][]const u8{
    "docm", "dotm", "xlsm", "xltm", "xlam",
    "pptm", "potm", "ppam", "ppsm", "sldm",
};

/// Linux and macOS launchers, scripts and packages.
const unix_extensions = [_][]const u8{
    "desktop",    "sh",      "bash",         "zsh",
    "fish",       "csh",     "ksh",          "run",
    "appimage",   "deb",     "rpm",          "flatpak",
    "flatpakref", "snap",    "command",      "tool",
    "app",        "pkg",     "mpkg",         "terminal",
    "workflow",   "action",  "scpt",         "applescript",
    "webloc",     "inetloc", "mobileconfig",
};

fn fileDecision(rest: []const u8, context: Context) Decision {
    const parts = fileParts(rest) orelse return .{ .deny = .malformed };

    var buf: [4096]u8 = undefined;
    const path = decode(&buf, parts.path) orelse return .{ .deny = .malformed };
    if (containsUnsafe(path)) return .{ .deny = .unsafe_characters };
    if (unsafeFile(path, context.os)) return .{ .deny = .unsafe_file };

    if (!context.isLocalHost(parts.host)) return .{ .confirm = .remote_file };
    if (path.len == 0) return .{ .deny = .malformed };
    return .{ .confirm = .local_file };
}

const FileParts = struct {
    host: []const u8,
    path: []const u8,
};

/// The host and path of the text after `file:`: `//host/path`, `///path`
/// or `/path`. Null with a query or a fragment, which name no file.
fn fileParts(rest: []const u8) ?FileParts {
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return null;
    if (std.mem.startsWith(u8, rest, "//")) {
        const authority = rest[2..];
        const slash = std.mem.indexOfScalar(u8, authority, '/') orelse authority.len;
        const host = authority[0..slash];
        if (std.mem.indexOfScalar(u8, host, '@') != null) return null;
        return .{ .host = host, .path = authority[slash..] };
    }
    return .{ .host = "", .path = rest };
}

/// The host of the authority (`//[user@]host[:port]`) at the start of the
/// text after an `http:` or `https:` scheme, or null without one.
fn authorityHost(rest: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rest, "//")) return null;
    const authority = rest[2..];
    const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    var host = authority[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.startsWith(u8, host, "[")) {
        // An IPv6 literal.
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        return host[0 .. close + 1];
    }
    return host[0 .. std.mem.indexOfScalar(u8, host, ':') orelse host.len];
}

/// Whether opening `path` (percent-decoded) could run code: its file name
/// ends in one of `unsafe_extensions`. On Windows, trailing dots and
/// spaces are ignored like the file system ignores them, and a colon in
/// the file name (an alternate data stream) is refused as well.
fn unsafeFile(path: []const u8, os: Os) bool {
    const sep: []const u8 = switch (os) {
        .windows => "/\\",
        .posix => "/",
    };
    var name = path[if (std.mem.lastIndexOfAny(u8, path, sep)) |i| i + 1 else 0..];
    if (os == .windows) {
        name = std.mem.trimEnd(u8, name, ". ");
        if (std.mem.indexOfScalar(u8, name, ':') != null) return true;
    }
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (unsafe_extensions) |unsafe| {
        if (std.ascii.eqlIgnoreCase(ext, unsafe)) return true;
    }
    return false;
}

/// Percent-decodes `text` into `buf`; null on a malformed escape, an
/// escaped NUL or when `buf` is too small.
fn decode(buf: []u8, text: []const u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (len == buf.len) return null;
        if (text[i] != '%') {
            buf[len] = text[i];
            len += 1;
            i += 1;
            continue;
        }
        if (i + 3 > text.len) return null;
        const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
        if (byte == 0) return null;
        buf[len] = byte;
        len += 1;
        i += 3;
    }
    if (!std.unicode.utf8ValidateSlice(buf[0..len])) return null;
    return buf[0..len];
}

fn appendDecoded(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!bool {
    var buf: [4096]u8 = undefined;
    const decoded = decode(&buf, text) orelse return false;
    try out.appendSlice(alloc, decoded);
    return true;
}

fn isDrive(text: []const u8) bool {
    return text.len >= 2 and std.ascii.isAlphabetic(text[0]) and text[1] == ':' and
        (text.len == 2 or text[2] == '/' or text[2] == '\\');
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Whether valid UTF-8 `text` contains a character `isUnsafe` refuses.
fn containsUnsafe(text: []const u8) bool {
    const view = std.unicode.Utf8View.init(text) catch return true;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isUnsafe(cp)) return true;
    }
    return false;
}

/// Control characters (C0, DEL, C1), direction marks and overrides,
/// zero-width characters, line and paragraph separators, the word joiner
/// and the byte order mark.
fn isUnsafe(cp: u21) bool {
    return switch (cp) {
        0x00...0x1F, 0x7F...0x9F => true,
        0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069 => true,
        0x2028...0x2029 => true,
        0x2060, 0xFEFF => true,
        else => false,
    };
}

const testing = std.testing;

fn expectDecision(expected: Decision, url: []const u8, os: Os) !void {
    const actual = decide(url, .{ .os = os });
    if (!std.meta.eql(expected, actual)) {
        std.debug.print("{s}: expected {any}, got {any}\n", .{ url, expected, actual });
        return error.TestUnexpectedResult;
    }
}

test "web and mail links open directly" {
    for ([_][]const u8{
        "http://example.com",
        "https://example.com/path?q=1#frag",
        "HTTPS://Example.COM",
        "https://user:pass@example.com:8443/x",
        "https://[::1]:8080/",
        "https://例子.测试/路径",
        "mailto:someone@example.com",
        "mailto:someone@example.com?subject=hi",
    }) |url| {
        try expectDecision(.allow, url, .windows);
        try expectDecision(.allow, url, .posix);
    }
}

test "web links need a host" {
    for ([_][]const u8{
        "https:relative",
        "https:/one-slash",
        "https://",
        "https:///path",
        "http://user@/x",
        "https://:443/",
    }) |url| {
        try expectDecision(.{ .deny = .invalid_web_url }, url, .posix);
    }
    try expectDecision(.{ .deny = .malformed }, "mailto:", .posix);
    try expectDecision(.{ .deny = .malformed }, "mailto:?subject=x", .posix);
}

test "malformed targets are refused" {
    for ([_][]const u8{
        "",
        "example.com",
        "/etc/passwd",
        "C:\\Windows\\system32\\calc.exe",
        "c:/x",
        ":nothing",
        "1http://x",
        "ht tp://x",
        "https://example.com/a b",
        "\xff\xfe",
    }) |url| {
        try expectDecision(.{ .deny = .malformed }, url, .windows);
    }
}

test "invisible and line-breaking characters are refused" {
    for ([_][]const u8{
        "https://example.com/\x1b[31m",
        "https://example.com/a\nb",
        "https://example.com/\u{202E}gpj.exe",
        "https://exa\u{200B}mple.com",
        "https://example.com/\u{2028}",
        "https://example.com/\u{FEFF}",
        "https://example.com/\u{0085}",
        "file:///tmp/a%0Ab",
        "file:///tmp/%E2%80%AEgpj.exe",
    }) |url| {
        try expectDecision(.{ .deny = .unsafe_characters }, url, .posix);
    }
}

test "local files ask first, executable ones are refused" {
    try expectDecision(.{ .confirm = .local_file }, "file:///home/me/notes.txt", .posix);
    try expectDecision(.{ .confirm = .local_file }, "file://localhost/home/me/dir/", .posix);
    try expectDecision(.{ .confirm = .local_file }, "file:/tmp/report.pdf", .posix);
    try expectDecision(.{ .confirm = .local_file }, "file:///C:/Users/me/My%20Notes.md", .windows);

    for ([_][]const u8{
        "file:///home/me/run.sh",
        "file:///home/me/app.desktop",
        "file:///home/me/Tool.AppImage",
        "file:///C:/Users/me/setup.exe",
        "file:///C:/Users/me/SETUP.EXE",
        "file:///C:/Users/me/script.ps1",
        "file:///C:/Users/me/link.lnk",
        "file:///C:/Users/me/evil%2Eexe",
        "file:///C:/Users/me/evil.exe.",
        "file:///C:/Users/me/evil.exe%20",
        "file:///C:/Users/me/x.search-ms",
    }) |url| {
        try expectDecision(.{ .deny = .unsafe_file }, url, .windows);
    }
    // A colon in a Windows file name names an alternate data stream.
    try expectDecision(.{ .deny = .unsafe_file }, "file:///C:/x/notes.txt:payload", .windows);
    try expectDecision(.{ .confirm = .local_file }, "file:///tmp/notes.txt:v2", .posix);
}

test "files on other computers ask first" {
    try expectDecision(.{ .confirm = .remote_file }, "file://server/share/report.docx", .windows);
    try expectDecision(.{ .confirm = .remote_file }, "file://myhost/home/me/x.txt", .posix);
    try expectDecision(.{ .deny = .unsafe_file }, "file://server/share/payload.exe", .windows);
    try expectDecision(.{ .deny = .malformed }, "file://user@server/share/x", .windows);
}

test "file URLs that name this computer are local" {
    const context: Context = .{ .os = .posix, .host_name = "myhost" };
    try testing.expectEqual(Decision{ .confirm = .local_file }, decide("file://myhost/home/me/x.txt", context));
    try testing.expectEqual(Decision{ .confirm = .local_file }, decide("file://MyHost/home/me/x.txt", context));
    try testing.expectEqual(Decision{ .confirm = .remote_file }, decide("file://other/home/me/x.txt", context));
    try testing.expectEqual(Decision{ .confirm = .remote_file }, decide("file://myhost/home/me/x.txt", .{ .os = .posix }));

    const posix = (try filePath(testing.allocator, "file://myhost/home/me/x.txt", context)).?;
    defer testing.allocator.free(posix);
    try testing.expectEqualStrings("/home/me/x.txt", posix);
    const windows = (try filePath(testing.allocator, "file://PC/C:/x", .{ .os = .windows, .host_name = "pc" })).?;
    defer testing.allocator.free(windows);
    try testing.expectEqualStrings("C:\\x", windows);
}

test "file URLs with queries, fragments or bad escapes are refused" {
    for ([_][]const u8{
        "file:///tmp/x?y",
        "file:///tmp/x#y",
        "file:///tmp/%zz",
        "file:///tmp/%4",
        "file:///tmp/%00x",
        "file://",
        "file:",
    }) |url| {
        try expectDecision(.{ .deny = .malformed }, url, .posix);
    }
}

test "custom schemes ask first and known abused schemes are refused" {
    for ([_][]const u8{
        "ssh://host",
        "vscode://file/x",
        "slack://open",
        "ms-settings:display",
        "tel:+123",
        "x-my-app+v1.2:go",
    }) |url| {
        try expectDecision(.{ .confirm = .custom_scheme }, url, .windows);
    }
    for ([_][]const u8{
        "javascript:alert(1)",
        "JavaScript:alert(1)",
        "data:text/html,<b>x</b>",
        "search-ms:query=x&crumb=location:\\\\evil\\share",
        "ms-msdt:/id",
        "ms-officecmd:{}",
        "ms-word:ofe|u|https://evil/x.docx",
        "ms-appinstaller:?source=https://evil/x.msix",
        "vbscript:x",
        "shell:startup",
    }) |url| {
        try expectDecision(.{ .deny = .blocked_scheme }, url, .windows);
    }
}

test "dialog texts are translated" {
    const i18n = @import("i18n.zig");
    var missing: usize = 0;
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(testing.allocator);
    inline for (@typeInfo(msg).@"struct".decl_names) |decl| try texts.append(testing.allocator, @field(msg, decl));
    for (std.enums.values(Confirm)) |reason| try texts.append(testing.allocator, reason.msgid());
    for (std.enums.values(Deny)) |reason| try texts.append(testing.allocator, reason.msgid());
    for (texts.items) |text| {
        if (i18n.lookup(.zh_CN, text) != null) continue;
        std.debug.print("missing zh-CN translation for {s}\n", .{text});
        missing += 1;
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "scheme" {
    try testing.expectEqualStrings("https", scheme("https://x").?);
    try testing.expectEqualStrings("x-a+b.c", scheme("x-a+b.c:y").?);
    try testing.expectEqual(@as(?[]const u8, null), scheme("C:\\x"));
    try testing.expectEqual(@as(?[]const u8, null), scheme("no-colon"));
    try testing.expectEqual(@as(?[]const u8, null), scheme("1a:x"));
    try testing.expectEqual(@as(?[]const u8, null), scheme("a b:x"));
}

test "writeDisplay escapes what could hide the target" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeDisplay(&out.writer, "https://a.com/\u{202E}gpj.exe\n中文\xff");
    try testing.expectEqualStrings("https://a.com/\\u{202E}gpj.exe\\u{000A}中文\\xFF", out.written());
}

test "filePath decodes local and remote file URLs" {
    const cases = [_]struct { []const u8, Os, ?[]const u8 }{
        .{ "file:///C:/Users/me/My%20Notes.md", .windows, "C:\\Users\\me\\My Notes.md" },
        .{ "file://localhost/C:/x", .windows, "C:\\x" },
        .{ "file://server/share/dir/a.txt", .windows, "\\\\server\\share\\dir\\a.txt" },
        .{ "file:///home/me/a%20b", .posix, "/home/me/a b" },
        .{ "file://host/home/x", .posix, "//host/home/x" },
        .{ "file:/tmp/%E4%B8%AD", .posix, "/tmp/中" },
        .{ "file:///tmp/x?q", .posix, null },
        .{ "file:///tmp/%zz", .posix, null },
        .{ "https://x/y", .posix, null },
        .{ "file:", .posix, null },
    };
    for (cases) |case| {
        const path = try filePath(testing.allocator, case[0], .{ .os = case[1] });
        defer if (path) |p| testing.allocator.free(p);
        if (case[2]) |expected| {
            try testing.expectEqualStrings(expected, path.?);
        } else {
            try testing.expectEqual(@as(?[]u8, null), path);
        }
    }
}
