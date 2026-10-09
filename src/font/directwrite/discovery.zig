//! Font discovery for the `freetype_windows` backend through DirectWrite.
//!
//! DirectWrite's system font collection holds the fonts of the system and
//! per-user font folders, fonts registered in the registry from any other
//! path and fonts shipped in app packages, and it finds a family by any of
//! its localized names. Codepoint fallback asks the system font fallback
//! (`IDWriteFontFallback::MapCharacters`) instead of opening every font
//! file. Fonts only GDI knows, added at runtime with AddFontResourceEx or
//! named by a GDI family name such as "Segoe UI Semibold", are looked up
//! through GDI.
//!
//! DirectWrite only finds the font: FreeType loads its file and face index
//! (`DeferredFace.Windows`) and rasterizes it, and HarfBuzz shapes the
//! text, exactly as with the font directory scanner `discovery.Windows`,
//! which discovery falls back to without DirectWrite.
//!
//! Based on the DirectWrite discovery of shiweis/ghostty-windows
//! `src/font/discovery.zig` (MIT, commit 119b9270c).
const std = @import("std");
const Allocator = std.mem.Allocator;
const com = @import("com.zig");
const match = @import("match.zig");
const font = @import("../main.zig");
const discovery = @import("../discovery.zig");
const global = @import("../../global.zig");
const DeferredFace = font.DeferredFace;
const Descriptor = discovery.Descriptor;
const Face = font.Face;
const Library = font.Library;
const Variation = font.face.Variation;

const log = std.log.scoped(.discovery);

pub const DirectWrite = struct {
    lib: Library,

    /// Null when DirectWrite could not be initialized.
    api: ?Api,

    /// Used instead of DirectWrite when `api` is null.
    scanner: discovery.Windows,

    pub fn init(lib: Library) DirectWrite {
        const api = Api.init() catch |err| api: {
            log.warn("DirectWrite unavailable, scanning font directories instead err={}", .{err});
            break :api null;
        };
        return .{ .lib = lib, .api = api, .scanner = .init(lib) };
    }

    pub fn deinit(self: *DirectWrite) void {
        if (self.api) |*api| api.deinit();
        self.scanner.deinit();
    }

    /// Discover fonts from a descriptor: the faces of `family` best match
    /// first, or the fallback fonts for `codepoint`, or every font when
    /// neither is set.
    pub fn discover(
        self: *const DirectWrite,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        const api = if (self.api) |*api| api else return .{
            .scan = try self.scanner.discover(alloc, desc),
        };

        const start: std.Io.Timestamp = .now(global.io(), .awake);
        var it: Iterator = .{
            .alloc = alloc,
            .lib = self.lib,
            .api = api,
            .codepoint = desc.codepoint,
            .variations = desc.variations,
        };
        errdefer it.deinit();

        if (desc.family) |family| {
            try it.addFamily(family, desc);
        } else if (desc.codepoint > 0) {
            try it.addFallback(desc);
        } else {
            try it.addAll();
        }

        log.debug("directwrite discover family={s} codepoint=U+{X} bold={} italic={} style={s} candidates={d} time={d}us", .{
            desc.family orelse "",
            desc.codepoint,
            desc.bold,
            desc.italic,
            desc.style orelse "",
            it.candidates.items.len,
            start.untilNow(global.io(), .awake).toMicroseconds(),
        });

        return .{ .dwrite = it };
    }

    pub fn discoverFallback(
        self: *const DirectWrite,
        alloc: Allocator,
        collection: *font.Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    /// The family name of a discovered face. FreeType decodes the font's
    /// English names, unlike `Face.name`, which returns some name records
    /// as raw UTF-16.
    pub fn familyName(face: *const Face, buf: []u8) ![]const u8 {
        const family: ?[*:0]const u8 = face.face.handle.*.family_name;
        return std.mem.span(family orelse return try face.name(buf));
    }

    /// The family and style name of a discovered face, such as
    /// "Cascadia Code Bold".
    pub fn fullName(face: *const Face, buf: []u8) ![]const u8 {
        const family_z: ?[*:0]const u8 = face.face.handle.*.family_name;
        const style_z: ?[*:0]const u8 = face.face.handle.*.style_name;
        const family = std.mem.span(family_z orelse return try face.name(buf));
        const style = std.mem.span(style_z orelse return family);
        return std.fmt.bufPrint(buf, "{s} {s}", .{ family, style }) catch family;
    }

    pub const DiscoverIterator = union(enum) {
        dwrite: Iterator,
        scan: discovery.Windows.DiscoverIterator,

        pub fn deinit(self: *DiscoverIterator) void {
            switch (self.*) {
                inline else => |*it| it.deinit(),
            }
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            return switch (self.*) {
                inline else => |*it| try it.next(),
            };
        }
    };
};

const Api = struct {
    factory: *com.IDWriteFactory,
    collection: *com.IDWriteFontCollection,

    /// Null before Windows 8.1; codepoint fallback then scans every family.
    fallback: ?*com.IDWriteFontFallback,

    gdi: ?*com.IDWriteGdiInterop,

    /// The user's locale, which the system fallback uses to pick a font
    /// for characters shared by several languages (Han ideographs).
    locale: [com.LOCALE_NAME_MAX_LENGTH:0]u16,

    fn init() !Api {
        var factory_ptr: ?*anyopaque = null;
        if (com.DWriteCreateFactory(.shared, &com.IDWriteFactory.iid, &factory_ptr) < 0)
            return error.DirectWrite;
        const factory: *com.IDWriteFactory = @ptrCast(@alignCast(factory_ptr orelse
            return error.DirectWrite));
        errdefer com.release(factory);

        const collection = try factory.getSystemFontCollection();
        errdefer com.release(collection);

        const fallback: ?*com.IDWriteFontFallback = fallback: {
            const factory2 = com.queryInterface(com.IDWriteFactory2, factory) orelse
                break :fallback null;
            defer com.release(factory2);
            break :fallback factory2.getSystemFontFallback() catch null;
        };

        var api: Api = .{
            .factory = factory,
            .collection = collection,
            .fallback = fallback,
            .gdi = factory.getGdiInterop() catch null,
            .locale = [_:0]u16{0} ** com.LOCALE_NAME_MAX_LENGTH,
        };
        if (com.GetUserDefaultLocaleName(&api.locale, api.locale.len) <= 0) {
            const en = std.unicode.utf8ToUtf16LeStringLiteral("en-US");
            @memcpy(api.locale[0..en.len], en);
        }
        return api;
    }

    fn deinit(self: *Api) void {
        if (self.gdi) |gdi| com.release(gdi);
        if (self.fallback) |fallback| com.release(fallback);
        com.release(self.collection);
        com.release(self.factory);
    }
};

const Iterator = struct {
    alloc: Allocator,
    lib: Library,
    api: *const Api,
    codepoint: u32,
    variations: []const Variation,

    /// Ordered best first; `next` loads them from `i` on.
    candidates: std.ArrayList(Candidate) = .empty,
    i: usize = 0,

    /// Codepoint fallback: once the system fallback's font is used up,
    /// look through every family.
    scan_pending: bool = false,

    pub fn deinit(self: *Iterator) void {
        for (self.candidates.items[self.i..]) |candidate| candidate.release();
        self.candidates.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn next(self: *Iterator) !?DeferredFace {
        while (true) {
            if (self.i == self.candidates.items.len) {
                if (!self.scan_pending) return null;
                self.scan_pending = false;
                try self.addScan();
                continue;
            }

            const candidate = self.candidates.items[self.i];
            self.i += 1;
            defer candidate.release();
            return self.load(candidate) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.debug("skipping font that cannot be loaded err={}", .{err});
                    continue;
                },
            };
        }
    }

    /// The faces of the family named `family` that suit `desc`.
    fn addFamily(self: *Iterator, family: [:0]const u8, desc: Descriptor) !void {
        if (family.len == 0) return;
        const name = std.unicode.wtf8ToWtf16LeAllocZ(self.alloc, family) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return,
        };
        defer self.alloc.free(name);

        var found: std.ArrayList(Candidate) = .empty;
        defer releaseAll(self.alloc, &found);

        const query: AttrQuery = .{ .style = desc.style, .monospace = desc.monospace };
        if (self.api.collection.findFamilyName(name) catch null) |index| {
            const fam = try self.api.collection.getFontFamily(index);
            defer com.release(fam);
            try self.collectFamily(fam, query, &found);
        } else {
            try self.collectGdi(name, query, &found);
        }

        try self.takeSelected(&found, .{
            .bold = desc.bold,
            .italic = desc.italic,
            .monospace = desc.monospace,
            .style = desc.style != null,
        }, null);
    }

    /// The system fallback font for `desc.codepoint`; `next` scans every
    /// family after it.
    fn addFallback(self: *Iterator, desc: Descriptor) !void {
        const cp = std.math.cast(u21, desc.codepoint) orelse return;
        if (cp > 0x10FFFF) return;
        self.scan_pending = true;

        const fallback = self.api.fallback orelse return;
        var buf: [2]u16 = undefined;
        const text = match.utf16Codepoint(cp, &buf);
        var source: com.TextAnalysisSource = .{
            .text = text.ptr,
            .len = @intCast(text.len),
            .locale = &self.api.locale,
        };
        const mapping = fallback.mapCharacters(
            &source,
            self.api.collection,
            if (desc.bold) .bold else .normal,
            if (desc.italic) .italic else .normal,
            .normal,
        ) catch |err| {
            log.debug("system font fallback failed codepoint=U+{X} err={}", .{ cp, err });
            return;
        };
        const mapped = mapping.font orelse return;
        if (mapping.len != text.len or !mapped.hasCharacter(cp)) {
            com.release(mapped);
            return;
        }
        self.candidates.append(self.alloc, .{
            .source = .{ .font = mapped },
            .attrs = .{},
            .has_codepoint = true,
        }) catch |err| {
            com.release(mapped);
            return err;
        };
    }

    /// For each family whose first face has `codepoint`, the family's
    /// best regular face. Checking a single face per family keeps a cold
    /// scan to milliseconds (checking every face loads hundreds of
    /// character maps); the styles of a family rarely differ in coverage.
    fn addScan(self: *Iterator) !void {
        const start: std.Io.Timestamp = .now(global.io(), .awake);
        const collection = self.api.collection;
        var found: std.ArrayList(Candidate) = .empty;
        defer releaseAll(self.alloc, &found);

        const before = self.candidates.items.len;
        for (0..collection.getFontFamilyCount()) |i| {
            const fam = collection.getFontFamily(@intCast(i)) catch continue;
            defer com.release(fam);
            const first = fam.getFont(0) catch continue;
            const covered = first.hasCharacter(self.codepoint);
            com.release(first);
            if (!covered) continue;

            try self.collectFamily(fam, .{}, &found);
            try self.takeSelected(&found, .{}, 1);
            releaseItems(&found);
        }

        log.debug("directwrite fallback scan codepoint=U+{X} candidates={d} time={d}us", .{
            self.codepoint,
            self.candidates.items.len - before,
            start.untilNow(global.io(), .awake).toMicroseconds(),
        });
    }

    /// Every font, for listing. Faces DirectWrite lists more than once
    /// (the same font installed in several places) are listed once.
    fn addAll(self: *Iterator) !void {
        const collection = self.api.collection;
        var found: std.ArrayList(Candidate) = .empty;
        defer releaseAll(self.alloc, &found);
        var seen: std.ArrayList(u64) = .empty;
        defer seen.deinit(self.alloc);

        for (0..collection.getFontFamilyCount()) |i| {
            const fam = collection.getFontFamily(@intCast(i)) catch continue;
            defer com.release(fam);
            try self.collectFamily(fam, .{}, &found);
            seen.clearRetainingCapacity();
            try seen.ensureUnusedCapacity(self.alloc, found.items.len);
            try self.candidates.ensureUnusedCapacity(self.alloc, found.items.len);
            for (found.items) |candidate| {
                const key = identity(candidate);
                if (std.mem.indexOfScalar(u64, seen.items, key) != null) {
                    candidate.release();
                    continue;
                }
                seen.appendAssumeCapacity(key);
                self.candidates.appendAssumeCapacity(candidate);
            }
            found.clearRetainingCapacity();
        }

        try self.addGdiOnly();
    }

    /// Fonts GDI enumerates that are not in the DirectWrite collection.
    fn addGdiOnly(self: *Iterator) !void {
        if (self.api.gdi == null) return;
        const hdc = com.CreateCompatibleDC(null) orelse return;
        defer _ = com.DeleteDC(hdc);

        var families: GdiFamilies = .{ .alloc = self.alloc };
        defer families.deinit();
        const logfont: com.LOGFONTW = .{};
        _ = com.EnumFontFamiliesExW(hdc, &logfont, GdiFamilies.add, @bitCast(@intFromPtr(&families)), 0);
        if (families.failed) return error.OutOfMemory;

        var found: std.ArrayList(Candidate) = .empty;
        defer releaseAll(self.alloc, &found);
        for (families.list.items) |*name| {
            const len = std.mem.indexOfScalar(u16, name, 0) orelse continue;
            const family = name[0..len :0];
            if (self.api.collection.findFamilyName(family) catch null) |_| continue;
            try self.collectGdi(family, .{}, &found);
            try self.candidates.ensureUnusedCapacity(self.alloc, found.items.len);
            for (found.items) |candidate| {
                const in_collection = self.api.collection.getFontFromFontFace(candidate.source.face);
                if (in_collection) |f| {
                    com.release(f);
                    candidate.release();
                    continue;
                }
                self.candidates.appendAssumeCapacity(candidate);
            }
            found.clearRetainingCapacity();
        }
    }

    /// Appends the real faces of `fam`, skipping the bold and oblique
    /// variants DirectWrite simulates: synthesizing a missing style is up
    /// to `Collection.completeStyles`.
    fn collectFamily(
        self: *Iterator,
        fam: *com.IDWriteFontFamily,
        query: AttrQuery,
        found: *std.ArrayList(Candidate),
    ) !void {
        for (0..fam.getFontCount()) |i| {
            const f = fam.getFont(@intCast(i)) catch continue;
            if (f.getSimulations().any() or
                (self.codepoint > 0 and !f.hasCharacter(self.codepoint)))
            {
                com.release(f);
                continue;
            }
            found.append(self.alloc, .{
                .source = .{ .font = f },
                .attrs = fontAttributes(f, query),
                .has_codepoint = true,
            }) catch |err| {
                com.release(f);
                return err;
            };
        }
    }

    /// Appends the faces of the GDI family `family`, which also covers
    /// fonts added with AddFontResourceEx and GDI family names that
    /// DirectWrite does not use as family names.
    fn collectGdi(
        self: *Iterator,
        family: [:0]const u16,
        query: AttrQuery,
        found: *std.ArrayList(Candidate),
    ) !void {
        const interop = self.api.gdi orelse return;
        if (family.len == 0 or family.len >= com.LF_FACESIZE) return;
        const hdc = com.CreateCompatibleDC(null) orelse return;
        defer _ = com.DeleteDC(hdc);

        var logfont: com.LOGFONTW = .{};
        @memcpy(logfont.lfFaceName[0..family.len], family);
        var styles: GdiStyles = .{ .alloc = self.alloc };
        defer styles.list.deinit(self.alloc);
        _ = com.EnumFontFamiliesExW(hdc, &logfont, GdiStyles.add, @bitCast(@intFromPtr(&styles)), 0);
        if (styles.failed) return error.OutOfMemory;

        for (styles.list.items) |*elf| {
            const hfont = com.CreateFontIndirectW(&elf.elfLogFont) orelse continue;
            defer _ = com.DeleteObject(hfont);
            const previous = com.SelectObject(hdc, hfont) orelse continue;
            defer _ = com.SelectObject(hdc, previous);

            const face = interop.createFontFaceFromHdc(hdc) catch continue;
            if (face.getSimulations().any()) {
                com.release(face);
                continue;
            }
            const attrs: match.Attributes = if (self.api.collection.getFontFromFontFace(face)) |f| attrs: {
                defer com.release(f);
                break :attrs fontAttributes(f, query);
            } else gdiAttributes(elf, query);
            found.append(self.alloc, .{
                .source = .{ .face = face },
                .attrs = attrs,
                .has_codepoint = false,
            }) catch |err| {
                com.release(face);
                return err;
            };
        }
    }

    /// Moves the candidates of `found` that suit `req` into the result,
    /// best first, at most `limit` of them.
    fn takeSelected(
        self: *Iterator,
        found: *std.ArrayList(Candidate),
        req: match.Request,
        limit: ?usize,
    ) !void {
        if (found.items.len == 0) return;
        const attrs = try self.alloc.alloc(match.Attributes, found.items.len);
        defer self.alloc.free(attrs);
        const order = try self.alloc.alloc(usize, found.items.len);
        defer self.alloc.free(order);
        for (found.items, attrs) |candidate, *a| a.* = candidate.attrs;

        const all = match.select(req, attrs, order);
        const selected = all[0..@min(all.len, limit orelse all.len)];
        try self.candidates.ensureUnusedCapacity(self.alloc, selected.len);
        for (selected) |i| self.candidates.appendAssumeCapacity(found.items[i]);

        // The taken candidates are owned by the result now.
        std.mem.sort(usize, selected, {}, std.sort.desc(usize));
        for (selected) |i| _ = found.swapRemove(i);
    }

    fn load(self: *Iterator, candidate: Candidate) !DeferredFace {
        const face = switch (candidate.source) {
            .font => |f| try f.createFontFace(),
            .face => |f| face: {
                com.addRef(f);
                break :face f;
            },
        };
        defer com.release(face);

        const path = try self.facePath(face);
        errdefer self.alloc.free(path);

        var axes_buf: [16]match.AxisValue = undefined;
        const axes = axisValues(face, &axes_buf);
        const opened = try openFace(self.lib, path, face.getIndex(), axes);
        var peek = opened.face;
        errdefer peek.deinit();

        if (!candidate.has_codepoint and
            self.codepoint > 0 and
            peek.glyphIndex(self.codepoint) == null)
            return error.CodepointMissing;

        var name_buf: [256]u8 = undefined;
        log.debug("directwrite font={s} index=0x{X} path={s}", .{
            DirectWrite.fullName(&peek, &name_buf) catch "",
            opened.index,
            path,
        });

        return .{ .win = .{
            .path = path,
            .face_index = opened.index,
            .variations = self.variations,
            .peek = peek,
            .presentation = if (peek.hasColor()) .emoji else .text,
            .alloc = self.alloc,
        } };
    }

    /// The path of the face's file in a form FreeType can open.
    fn facePath(self: *Iterator, face: *com.IDWriteFontFace) ![:0]u8 {
        const file = try face.getFile();
        defer com.release(file);
        const key = try file.getReferenceKey();
        const loader = try file.getLoader();
        defer com.release(loader);
        const local = com.queryInterface(com.IDWriteLocalFontFileLoader, loader) orelse
            return error.FontNotLocal;
        defer com.release(local);
        const wide = try local.getFilePath(self.alloc, key);
        defer self.alloc.free(wide);
        return try freetypePath(self.alloc, wide);
    }
};

const Candidate = struct {
    source: Source,
    attrs: match.Attributes,

    /// DirectWrite already checked the requested codepoint; otherwise
    /// the loaded face is checked.
    has_codepoint: bool,

    /// One COM reference, released with the candidate.
    const Source = union(enum) {
        font: *com.IDWriteFont,
        face: *com.IDWriteFontFace,
    };

    fn release(self: Candidate) void {
        switch (self.source) {
            inline else => |obj| com.release(obj),
        }
    }
};

fn releaseItems(list: *std.ArrayList(Candidate)) void {
    for (list.items) |candidate| candidate.release();
    list.clearRetainingCapacity();
}

fn releaseAll(alloc: Allocator, list: *std.ArrayList(Candidate)) void {
    releaseItems(list);
    list.deinit(alloc);
}

/// Identifies a face within its family for listing: weight, width,
/// slant and the English face name.
fn identity(candidate: Candidate) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, candidate.attrs.weight);
    std.hash.autoHash(&hasher, candidate.attrs.stretch);
    std.hash.autoHash(&hasher, candidate.attrs.slant);
    switch (candidate.source) {
        .font => |f| if (f.getFaceNames()) |names| {
            defer com.release(names);
            var buf: [256]u16 = undefined;
            const en = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
            const index = names.findLocaleName(en) orelse 0;
            if (names.getString(index, &buf)) |name| {
                hasher.update(std.mem.sliceAsBytes(name));
            } else |_| {}
        } else |_| {},
        .face => {},
    }
    return hasher.final();
}

/// What a candidate's attributes have to answer beyond weight, width and
/// slant.
const AttrQuery = struct {
    /// A requested style name, matched against the face names.
    style: ?[:0]const u8 = null,

    /// Whether to ask if the face is monospace, which can load the font.
    monospace: bool = false,
};

fn fontAttributes(f: *com.IDWriteFont, query: AttrQuery) match.Attributes {
    return .{
        .weight = @intCast(std.math.clamp(@intFromEnum(f.getWeight()), 1, 999)),
        .stretch = @intCast(@min(@intFromEnum(f.getStretch()), 9)),
        .slant = switch (f.getStyle()) {
            .italic => .italic,
            .oblique => .oblique,
            else => .upright,
        },
        .monospace = monospace: {
            if (!query.monospace) break :monospace false;
            const f1 = com.queryInterface(com.IDWriteFont1, f) orelse break :monospace false;
            defer com.release(f1);
            break :monospace f1.isMonospacedFont();
        },
        .style_match = if (query.style) |s| fontStyleMatch(f, s) else .none,
    };
}

/// Matches `wanted` against the face names of `f` in every language.
fn fontStyleMatch(f: *com.IDWriteFont, wanted: []const u8) match.StyleMatch {
    var storage: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&storage);
    var names_buf: [32][]const u8 = undefined;
    var names: std.ArrayList([]const u8) = .initBuffer(&names_buf);

    if (f.getFaceNames()) |strings| {
        defer com.release(strings);
        appendNames(fba.allocator(), &names, strings);
    } else |_| {}
    for ([_]com.InformationalStringId{
        .win32_subfamily_names,
        .typographic_subfamily_names,
    }) |id| {
        const strings = (f.getInformationalStrings(id) catch null) orelse continue;
        defer com.release(strings);
        appendNames(fba.allocator(), &names, strings);
    }
    return match.styleMatch(names.items, wanted);
}

fn appendNames(
    alloc: Allocator,
    names: *std.ArrayList([]const u8),
    strings: *com.IDWriteLocalizedStrings,
) void {
    var wide: [256]u16 = undefined;
    for (0..strings.getCount()) |i| {
        if (names.unusedCapacitySlice().len == 0) return;
        const name = strings.getString(@intCast(i), &wide) catch continue;
        const utf8 = std.unicode.wtf16LeToWtf8Alloc(alloc, name) catch return;
        names.appendAssumeCapacity(utf8);
    }
}

fn gdiAttributes(elf: *const com.ENUMLOGFONTEXW, query: AttrQuery) match.Attributes {
    const lf = elf.elfLogFont;
    var attrs: match.Attributes = .{
        .weight = if (lf.lfWeight > 0) @intCast(@min(lf.lfWeight, 999)) else match.normal_weight,
        .slant = if (lf.lfItalic != 0) .italic else .upright,
        .monospace = lf.lfPitchAndFamily & 0x3 == com.FIXED_PITCH,
    };
    if (query.style) |wanted| {
        var buf: [com.LF_FACESIZE * 3]u8 = undefined;
        const len = std.unicode.wtf16LeToWtf8(&buf, std.mem.sliceTo(&elf.elfStyle, 0));
        attrs.style_match = match.styleMatch(&.{buf[0..len]}, wanted);
    }
    return attrs;
}

/// Collects the styles of one GDI family; GDI reports each face once per
/// character set.
const GdiStyles = struct {
    alloc: Allocator,
    list: std.ArrayList(com.ENUMLOGFONTEXW) = .empty,
    failed: bool = false,

    fn add(
        elf: *const com.ENUMLOGFONTEXW,
        _: *const anyopaque,
        font_type: u32,
        param: isize,
    ) callconv(.winapi) c_int {
        const self: *GdiStyles = @ptrFromInt(@as(usize, @bitCast(param)));
        if (font_type & com.RASTER_FONTTYPE != 0) return 1;
        const full_name = std.mem.sliceTo(&elf.elfFullName, 0);
        for (self.list.items) |*seen| {
            if (seen.elfLogFont.lfWeight == elf.elfLogFont.lfWeight and
                seen.elfLogFont.lfItalic == elf.elfLogFont.lfItalic and
                std.mem.eql(u16, std.mem.sliceTo(&seen.elfFullName, 0), full_name))
                return 1;
        }
        self.list.append(self.alloc, elf.*) catch {
            self.failed = true;
            return 0;
        };
        return 1;
    }
};

/// Collects the family names GDI knows, skipping the "@" names of the
/// vertical variants.
const GdiFamilies = struct {
    alloc: Allocator,
    list: std.ArrayList([com.LF_FACESIZE]u16) = .empty,
    failed: bool = false,

    fn deinit(self: *GdiFamilies) void {
        self.list.deinit(self.alloc);
    }

    fn add(
        elf: *const com.ENUMLOGFONTEXW,
        _: *const anyopaque,
        font_type: u32,
        param: isize,
    ) callconv(.winapi) c_int {
        const self: *GdiFamilies = @ptrFromInt(@as(usize, @bitCast(param)));
        if (font_type & com.RASTER_FONTTYPE != 0) return 1;
        const name = elf.elfLogFont.lfFaceName;
        if (name[0] == 0 or name[0] == '@') return 1;
        for (self.list.items) |*seen| {
            if (std.mem.eql(u16, std.mem.sliceTo(seen, 0), std.mem.sliceTo(&name, 0))) return 1;
        }
        self.list.append(self.alloc, name) catch {
            self.failed = true;
            return 0;
        };
        return 1;
    }
};

/// The variation axis values of a variable font's named instance.
fn axisValues(face: *com.IDWriteFontFace, buf: []match.AxisValue) []match.AxisValue {
    const face5 = com.queryInterface(com.IDWriteFontFace5, face) orelse return buf[0..0];
    defer com.release(face5);
    if (!face5.hasVariations()) return buf[0..0];
    var raw: [16]com.FontAxisValue = undefined;
    const values = face5.getFontAxisValues(&raw) catch return buf[0..0];
    const len = @min(values.len, buf.len);
    for (values[0..len], buf[0..len]) |v, *out| out.* = .fromDirectWrite(v.tag, v.value);
    return buf[0..len];
}

const OpenedFace = struct { face: Face, index: i32 };

/// Opens the face with FreeType. DirectWrite lists every named instance
/// of a variable font as its own face of the same file and index; the
/// FreeType face index selects the instance with the same axis values.
fn openFace(
    lib: Library,
    path: [:0]const u8,
    index: u32,
    axes: []const match.AxisValue,
) !OpenedFace {
    const base: i32 = @intCast(index & 0xFFFF);
    const opts: font.face.Options = .{ .size = .{ .points = 12 } };
    var face = try Face.initFile(lib, path, base, opts);
    if (axes.len == 0 or !face.face.hasMultipleMasters()) return .{ .face = face, .index = base };

    const instance = namedInstance(lib, face, axes) orelse return .{ .face = face, .index = base };
    face.deinit();
    const named = base | @as(i32, instance) << 16;
    return .{ .face = try Face.initFile(lib, path, named, opts), .index = named };
}

fn namedInstance(lib: Library, face: Face, axes: []const match.AxisValue) ?u15 {
    const mm = face.face.getMMVar() catch return null;
    defer lib.lib.doneMMVar(mm);

    var tags: [16]u32 = undefined;
    var coords: [16]f32 = undefined;
    const axis_count = @min(mm.num_axis, tags.len);
    for (tags[0..axis_count], 0..) |*tag, i| tag.* = @truncate(mm.axis[i].tag);

    var best: ?u15 = null;
    var best_distance = std.math.inf(f32);
    for (0..@min(mm.num_namedstyles, std.math.maxInt(u15))) |s| {
        const style_coords = mm.namedstyle[s].coords;
        for (coords[0..axis_count], 0..) |*coord, i| {
            coord.* = @as(f32, @floatFromInt(style_coords[i])) / 65536.0;
        }
        const distance = match.instanceDistance(tags[0..axis_count], coords[0..axis_count], axes) orelse continue;
        if (distance < best_distance) {
            best_distance = distance;
            best = @intCast(s + 1);
        }
    }
    return best;
}

/// FreeType opens font files with CreateFileA, which reads the path in
/// the ANSI code page. A path with characters outside of it is replaced by
/// its 8.3 short form.
fn freetypePath(alloc: Allocator, wide: [:0]const u16) ![:0]u8 {
    if (ansiPath(alloc, wide)) |path| return path else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FontPathUnsupported => {},
    }

    const len = com.GetShortPathNameW(wide.ptr, null, 0);
    if (len == 0) return error.FontPathUnsupported;
    const short = try alloc.alloc(u16, len);
    defer alloc.free(short);
    const written = com.GetShortPathNameW(wide.ptr, short.ptr, len);
    if (written == 0 or written >= len) return error.FontPathUnsupported;
    return ansiPath(alloc, short[0..written :0]);
}

fn ansiPath(alloc: Allocator, wide: [:0]const u16) error{ OutOfMemory, FontPathUnsupported }![:0]u8 {
    const ascii = for (wide) |c| {
        if (c >= 0x80) break false;
    } else true;
    if (ascii or com.GetACP() == com.CP_UTF8) {
        return try std.unicode.wtf16LeToWtf8AllocZ(alloc, wide);
    }

    var used_default: com.BOOL = .FALSE;
    const wide_len: c_int = @intCast(wide.len);
    const len = com.WideCharToMultiByte(com.CP_ACP, com.WC_NO_BEST_FIT_CHARS, wide.ptr, wide_len, null, 0, null, &used_default);
    if (len <= 0 or used_default.toBool()) return error.FontPathUnsupported;
    const path = try alloc.allocSentinel(u8, @intCast(len), 0);
    errdefer alloc.free(path);
    const written = com.WideCharToMultiByte(com.CP_ACP, com.WC_NO_BEST_FIT_CHARS, wide.ptr, wide_len, path.ptr, len, null, &used_default);
    if (written != len or used_default.toBool()) return error.FontPathUnsupported;
    return path;
}

test "directwrite discovers the real face of every style" {
    if (font.options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var dw: DirectWrite = .init(lib);
    defer dw.deinit();
    if (dw.api == null) return error.SkipZigTest;

    // Arial ships with every Windows installation, in all four styles.
    const cases = [_]struct { bold: bool, italic: bool, name: []const u8 }{
        .{ .bold = false, .italic = false, .name = "Arial Regular" },
        .{ .bold = true, .italic = false, .name = "Arial Bold" },
        .{ .bold = false, .italic = true, .name = "Arial Italic" },
        .{ .bold = true, .italic = true, .name = "Arial Bold Italic" },
    };
    for (cases) |case| {
        var it = try dw.discover(alloc, .{
            .family = "Arial",
            .bold = case.bold,
            .italic = case.italic,
        });
        defer it.deinit();
        var face = (try it.next()) orelse return error.TestFontNotFound;
        defer face.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(case.name, try face.name(&buf));
    }
}

test "directwrite falls back by codepoint" {
    if (font.options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var dw: DirectWrite = .init(lib);
    defer dw.deinit();
    if (dw.api == null) return error.SkipZigTest;

    var it = try dw.discover(alloc, .{ .codepoint = 0x3A9 });
    defer it.deinit();
    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    try testing.expect(face.hasCodepoint(0x3A9, null));
}
