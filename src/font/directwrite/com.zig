//! DirectWrite COM bindings, plus the few GDI and kernel32 functions, for
//! the Windows font discovery in `discovery.zig` next to this file.
//!
//! Ported from shiweis/ghostty-windows `src/font/directwrite.zig` (MIT,
//! commit 119b9270c) and extended with the font fallback, text analysis
//! source, GDI interop and variable font interfaces. Vtable layouts follow
//! the Windows SDK headers `dwrite.h` through `dwrite_3.h`; methods that
//! are never called are typed as padding so only the slot count matters.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const HRESULT = i32;
pub const BOOL = windows.BOOL;
pub const GUID = windows.GUID;

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const Error = error{DirectWrite};

const Pad = *const fn () callconv(.winapi) void;

fn check(hr: HRESULT) Error!void {
    if (hr < 0) return error.DirectWrite;
}

fn guid(
    comptime d1: u32,
    comptime d2: u16,
    comptime d3: u16,
    comptime d4: [8]u8,
) GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

pub fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

pub const FactoryType = enum(u32) { shared = 0, isolated = 1, _ };

pub const FontWeight = enum(u32) {
    thin = 100,
    extra_light = 200,
    light = 300,
    semi_light = 350,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    extra_black = 950,
    _,
};

pub const FontStyle = enum(u32) { normal = 0, oblique = 1, italic = 2, _ };

pub const FontStretch = enum(u32) {
    undefined = 0,
    ultra_condensed = 1,
    extra_condensed = 2,
    condensed = 3,
    semi_condensed = 4,
    normal = 5,
    semi_expanded = 6,
    expanded = 7,
    extra_expanded = 8,
    ultra_expanded = 9,
    _,
};

pub const FontSimulations = packed struct(u32) {
    bold: bool = false,
    oblique: bool = false,
    _padding: u30 = 0,

    pub fn any(self: FontSimulations) bool {
        return self.bold or self.oblique;
    }
};

pub const InformationalStringId = enum(u32) {
    win32_family_names = 11,
    win32_subfamily_names = 12,
    typographic_family_names = 13,
    typographic_subfamily_names = 14,
    full_name = 16,
    postscript_name = 17,
    _,
};

pub const ReadingDirection = enum(u32) { left_to_right = 0, _ };

pub const FontAxisValue = extern struct {
    /// OpenType axis tag as stored by DirectWrite: the first tag
    /// character is the least significant byte.
    tag: u32,
    value: f32,
};

/// Release any COM object: every interface starts with IUnknown.
pub fn release(obj: anytype) void {
    const unknown: *IUnknown = @ptrCast(@alignCast(obj));
    _ = unknown.vtable.Release(unknown);
}

pub fn addRef(obj: anytype) void {
    const unknown: *IUnknown = @ptrCast(@alignCast(obj));
    _ = unknown.vtable.AddRef(unknown);
}

/// QueryInterface for `T`, which must declare its IID as `iid`.
pub fn queryInterface(comptime T: type, obj: anytype) ?*T {
    const unknown: *IUnknown = @ptrCast(@alignCast(obj));
    var out: ?*anyopaque = null;
    if (unknown.vtable.QueryInterface(unknown, &T.iid, &out) < 0) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

fn UnknownMethods(comptime Self: type) type {
    return extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) u32,
        Release: *const fn (*Self) callconv(.winapi) u32,
    };
}

pub const IUnknown = extern struct {
    vtable: *const UnknownMethods(IUnknown),

    pub const iid = guid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 });
};

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const iid = guid(0xb859ee5a, 0xd838, 0x4b5b, .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 });

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetSystemFontCollection: *const fn (*Self, *?*IDWriteFontCollection, BOOL) callconv(.winapi) HRESULT,
        _pad4: [13]Pad,
        GetGdiInterop: *const fn (*Self, *?*IDWriteGdiInterop) callconv(.winapi) HRESULT,
    };

    pub fn getSystemFontCollection(self: *Self) Error!*IDWriteFontCollection {
        var out: ?*IDWriteFontCollection = null;
        try check(self.vtable.GetSystemFontCollection(self, &out, .FALSE));
        return out orelse error.DirectWrite;
    }

    pub fn getGdiInterop(self: *Self) Error!*IDWriteGdiInterop {
        var out: ?*IDWriteGdiInterop = null;
        try check(self.vtable.GetGdiInterop(self, &out));
        return out orelse error.DirectWrite;
    }
};

pub const IDWriteGdiInterop = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        CreateFontFromLOGFONT: Pad,
        ConvertFontToLOGFONT: Pad,
        ConvertFontFaceToLOGFONT: Pad,
        CreateFontFaceFromHdc: *const fn (*Self, windows.HDC, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    /// The face of the font currently selected into `hdc`. Unlike the
    /// system font collection this sees every font GDI knows, including
    /// fonts added at runtime with AddFontResourceEx.
    pub fn createFontFaceFromHdc(self: *Self, hdc: windows.HDC) Error!*IDWriteFontFace {
        var out: ?*IDWriteFontFace = null;
        try check(self.vtable.CreateFontFaceFromHdc(self, hdc, &out));
        return out orelse error.DirectWrite;
    }
};

/// IDWriteFactory2 adds the system font fallback (Windows 8.1+).
pub const IDWriteFactory2 = extern struct {
    vtable: *const VTable,

    pub const iid = guid(0x0439fc60, 0xca44, 0x4994, .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec });

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        // IDWriteFactory 3-23, IDWriteFactory1 24-25.
        _pad: [23]Pad,
        GetSystemFontFallback: *const fn (*Self, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
    };

    pub fn getSystemFontFallback(self: *Self) Error!*IDWriteFontFallback {
        var out: ?*IDWriteFontFallback = null;
        try check(self.vtable.GetSystemFontFallback(self, &out));
        return out orelse error.DirectWrite;
    }
};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetFontFamilyCount: *const fn (*Self) callconv(.winapi) u32,
        GetFontFamily: *const fn (*Self, u32, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (*Self, [*:0]const u16, *u32, *BOOL) callconv(.winapi) HRESULT,
        GetFontFromFontFace: *const fn (*Self, *IDWriteFontFace, *?*IDWriteFont) callconv(.winapi) HRESULT,
    };

    /// The collection's font for `face`, or null if the face's font is
    /// not part of this collection.
    pub fn getFontFromFontFace(self: *Self, face: *IDWriteFontFace) ?*IDWriteFont {
        var out: ?*IDWriteFont = null;
        check(self.vtable.GetFontFromFontFace(self, face, &out)) catch return null;
        return out;
    }

    pub fn getFontFamilyCount(self: *Self) u32 {
        return self.vtable.GetFontFamilyCount(self);
    }

    pub fn getFontFamily(self: *Self, index: u32) Error!*IDWriteFontFamily {
        var out: ?*IDWriteFontFamily = null;
        try check(self.vtable.GetFontFamily(self, index, &out));
        return out orelse error.DirectWrite;
    }

    /// Looks the name up in every localized family name.
    pub fn findFamilyName(self: *Self, name: [*:0]const u16) Error!?u32 {
        var index: u32 = 0;
        var exists: BOOL = .FALSE;
        try check(self.vtable.FindFamilyName(self, name, &index, &exists));
        return if (exists.toBool()) index else null;
    }
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        // IDWriteFontList
        GetFontCollection: Pad,
        GetFontCount: *const fn (*Self) callconv(.winapi) u32,
        GetFont: *const fn (*Self, u32, *?*IDWriteFont) callconv(.winapi) HRESULT,
        // IDWriteFontFamily
        GetFamilyNames: *const fn (*Self, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
    };

    pub fn getFontCount(self: *Self) u32 {
        return self.vtable.GetFontCount(self);
    }

    pub fn getFont(self: *Self, index: u32) Error!*IDWriteFont {
        var out: ?*IDWriteFont = null;
        try check(self.vtable.GetFont(self, index, &out));
        return out orelse error.DirectWrite;
    }

    pub fn getFamilyNames(self: *Self) Error!*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        try check(self.vtable.GetFamilyNames(self, &out));
        return out orelse error.DirectWrite;
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetFontFamily: *const fn (*Self, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        GetWeight: *const fn (*Self) callconv(.winapi) FontWeight,
        GetStretch: *const fn (*Self) callconv(.winapi) FontStretch,
        GetStyle: *const fn (*Self) callconv(.winapi) FontStyle,
        IsSymbolFont: Pad,
        GetFaceNames: *const fn (*Self, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        GetInformationalStrings: *const fn (*Self, InformationalStringId, *?*IDWriteLocalizedStrings, *BOOL) callconv(.winapi) HRESULT,
        GetSimulations: *const fn (*Self) callconv(.winapi) FontSimulations,
        GetMetrics: Pad,
        HasCharacter: *const fn (*Self, u32, *BOOL) callconv(.winapi) HRESULT,
        CreateFontFace: *const fn (*Self, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub fn getFontFamily(self: *Self) Error!*IDWriteFontFamily {
        var out: ?*IDWriteFontFamily = null;
        try check(self.vtable.GetFontFamily(self, &out));
        return out orelse error.DirectWrite;
    }

    pub fn getWeight(self: *Self) FontWeight {
        return self.vtable.GetWeight(self);
    }

    pub fn getStretch(self: *Self) FontStretch {
        return self.vtable.GetStretch(self);
    }

    pub fn getStyle(self: *Self) FontStyle {
        return self.vtable.GetStyle(self);
    }

    pub fn getFaceNames(self: *Self) Error!*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        try check(self.vtable.GetFaceNames(self, &out));
        return out orelse error.DirectWrite;
    }

    pub fn getInformationalStrings(
        self: *Self,
        id: InformationalStringId,
    ) Error!?*IDWriteLocalizedStrings {
        var out: ?*IDWriteLocalizedStrings = null;
        var exists: BOOL = .FALSE;
        try check(self.vtable.GetInformationalStrings(self, id, &out, &exists));
        if (!exists.toBool()) {
            if (out) |strings| release(strings);
            return null;
        }
        return out;
    }

    pub fn getSimulations(self: *Self) FontSimulations {
        return self.vtable.GetSimulations(self);
    }

    pub fn hasCharacter(self: *Self, cp: u32) bool {
        var exists: BOOL = .FALSE;
        check(self.vtable.HasCharacter(self, cp, &exists)) catch return false;
        return exists.toBool();
    }

    pub fn createFontFace(self: *Self) Error!*IDWriteFontFace {
        var out: ?*IDWriteFontFace = null;
        try check(self.vtable.CreateFontFace(self, &out));
        return out orelse error.DirectWrite;
    }
};

/// IDWriteFont1 adds monospace detection (Windows 8+).
pub const IDWriteFont1 = extern struct {
    vtable: *const VTable,

    pub const iid = guid(0xacd16696, 0x8c14, 0x4f5d, .{ 0x87, 0x7e, 0xfe, 0x3f, 0xc1, 0xd3, 0x27, 0x38 });

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        // IDWriteFont 3-13, IDWriteFont1 14-16.
        _pad: [14]Pad,
        IsMonospacedFont: *const fn (*Self) callconv(.winapi) BOOL,
    };

    pub fn isMonospacedFont(self: *Self) bool {
        return self.vtable.IsMonospacedFont(self).toBool();
    }
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetType: Pad,
        GetFiles: *const fn (*Self, *u32, ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
        GetIndex: *const fn (*Self) callconv(.winapi) u32,
        GetSimulations: *const fn (*Self) callconv(.winapi) FontSimulations,
    };

    pub fn getSimulations(self: *Self) FontSimulations {
        return self.vtable.GetSimulations(self);
    }

    /// The first file of the face; DirectWrite only uses more than one
    /// file for Type 1 fonts, which FreeType loads from the first file.
    pub fn getFile(self: *Self) Error!*IDWriteFontFile {
        var count: u32 = 0;
        try check(self.vtable.GetFiles(self, &count, null));
        if (count == 0) return error.DirectWrite;
        var files: [4]?*IDWriteFontFile = @splat(null);
        if (count > files.len) return error.DirectWrite;
        try check(self.vtable.GetFiles(self, &count, &files));
        for (files[1..count]) |f| if (f) |file| release(file);
        return files[0] orelse error.DirectWrite;
    }

    pub fn getIndex(self: *Self) u32 {
        return self.vtable.GetIndex(self);
    }
};

/// IDWriteFontFace5 exposes the variation axis values of a face, which
/// identify the named instance of a variable font (Windows 10 1803+).
pub const IDWriteFontFace5 = extern struct {
    vtable: *const VTable,

    pub const iid = guid(0x98eff3a5, 0xb667, 0x479a, .{ 0xb1, 0x45, 0xe2, 0xfa, 0x5b, 0x9f, 0xdc, 0x29 });

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        // IDWriteFontFace 3-17, IDWriteFontFace1 18-29,
        // IDWriteFontFace2 30-34, IDWriteFontFace3 35-48,
        // IDWriteFontFace4 49-52.
        _pad: [50]Pad,
        GetFontAxisValueCount: *const fn (*Self) callconv(.winapi) u32,
        GetFontAxisValues: *const fn (*Self, [*]FontAxisValue, u32) callconv(.winapi) HRESULT,
        HasVariations: *const fn (*Self) callconv(.winapi) BOOL,
    };

    pub fn hasVariations(self: *Self) bool {
        return self.vtable.HasVariations(self).toBool();
    }

    /// Writes the axis values into `buf` and returns the filled part.
    pub fn getFontAxisValues(self: *Self, buf: []FontAxisValue) Error![]FontAxisValue {
        const count = self.vtable.GetFontAxisValueCount(self);
        if (count == 0) return buf[0..0];
        if (count > buf.len) return error.DirectWrite;
        try check(self.vtable.GetFontAxisValues(self, buf.ptr, count));
        return buf[0..count];
    }
};

pub const IDWriteFontFile = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetReferenceKey: *const fn (*Self, *?*const anyopaque, *u32) callconv(.winapi) HRESULT,
        GetLoader: *const fn (*Self, *?*IUnknown) callconv(.winapi) HRESULT,
    };

    pub const ReferenceKey = struct { ptr: *const anyopaque, len: u32 };

    /// The key stays valid as long as the file object is alive.
    pub fn getReferenceKey(self: *Self) Error!ReferenceKey {
        var key: ?*const anyopaque = null;
        var len: u32 = 0;
        try check(self.vtable.GetReferenceKey(self, &key, &len));
        return .{ .ptr = key orelse return error.DirectWrite, .len = len };
    }

    pub fn getLoader(self: *Self) Error!*IUnknown {
        var out: ?*IUnknown = null;
        try check(self.vtable.GetLoader(self, &out));
        return out orelse error.DirectWrite;
    }
};

/// The loader behind fonts that live in local files; other loaders
/// (memory, remote, app-defined) have no path FreeType could open.
pub const IDWriteLocalFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const iid = guid(0xb2d9f3ec, 0xc9fe, 0x4a11, .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 });

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        CreateStreamFromKey: Pad,
        GetFilePathLengthFromKey: *const fn (*Self, *const anyopaque, u32, *u32) callconv(.winapi) HRESULT,
        GetFilePathFromKey: *const fn (*Self, *const anyopaque, u32, [*]u16, u32) callconv(.winapi) HRESULT,
    };

    pub fn getFilePath(
        self: *Self,
        alloc: std.mem.Allocator,
        key: IDWriteFontFile.ReferenceKey,
    ) (Error || std.mem.Allocator.Error)![:0]u16 {
        var len: u32 = 0;
        try check(self.vtable.GetFilePathLengthFromKey(self, key.ptr, key.len, &len));
        const path = try alloc.allocSentinel(u16, len, 0);
        errdefer alloc.free(path);
        try check(self.vtable.GetFilePathFromKey(self, key.ptr, key.len, path.ptr, len + 1));
        return path;
    }
};

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetCount: *const fn (*Self) callconv(.winapi) u32,
        FindLocaleName: *const fn (*Self, [*:0]const u16, *u32, *BOOL) callconv(.winapi) HRESULT,
        GetLocaleNameLength: *const fn (*Self, u32, *u32) callconv(.winapi) HRESULT,
        GetLocaleName: *const fn (*Self, u32, [*]u16, u32) callconv(.winapi) HRESULT,
        GetStringLength: *const fn (*Self, u32, *u32) callconv(.winapi) HRESULT,
        GetString: *const fn (*Self, u32, [*]u16, u32) callconv(.winapi) HRESULT,
    };

    pub fn getCount(self: *Self) u32 {
        return self.vtable.GetCount(self);
    }

    pub fn findLocaleName(self: *Self, locale: [*:0]const u16) ?u32 {
        var index: u32 = 0;
        var exists: BOOL = .FALSE;
        check(self.vtable.FindLocaleName(self, locale, &index, &exists)) catch return null;
        return if (exists.toBool()) index else null;
    }

    /// Writes the string at `index` into `buf` (UTF-16, no terminator).
    pub fn getString(self: *Self, index: u32, buf: []u16) Error![]u16 {
        var len: u32 = 0;
        try check(self.vtable.GetStringLength(self, index, &len));
        if (len + 1 > buf.len) return error.DirectWrite;
        try check(self.vtable.GetString(self, index, buf.ptr, len + 1));
        return buf[0..len];
    }
};

pub const IDWriteFontFallback = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        MapCharacters: *const fn (
            *Self,
            source: *TextAnalysisSource,
            position: u32,
            length: u32,
            base_collection: ?*IDWriteFontCollection,
            base_family_name: ?[*:0]const u16,
            base_weight: FontWeight,
            base_style: FontStyle,
            base_stretch: FontStretch,
            mapped_length: *u32,
            mapped_font: *?*IDWriteFont,
            scale: *f32,
        ) callconv(.winapi) HRESULT,
    };

    pub const Mapping = struct {
        /// UTF-16 code units of the source text covered by `font`.
        len: u32,
        /// Null when no font on the system supports the text.
        font: ?*IDWriteFont,
    };

    pub fn mapCharacters(
        self: *Self,
        source: *TextAnalysisSource,
        collection: ?*IDWriteFontCollection,
        weight: FontWeight,
        style: FontStyle,
        stretch: FontStretch,
    ) Error!Mapping {
        var len: u32 = 0;
        var font: ?*IDWriteFont = null;
        var scale: f32 = 1;
        try check(self.vtable.MapCharacters(
            self,
            source,
            0,
            source.len,
            collection,
            null,
            weight,
            style,
            stretch,
            &len,
            &font,
            &scale,
        ));
        return .{ .len = len, .font = font };
    }
};

/// A caller-owned IDWriteTextAnalysisSource over one UTF-16 run with a
/// single locale, which is all IDWriteFontFallback.MapCharacters needs.
/// DirectWrite only uses it during the call, so it lives on the stack
/// and reference counting is a no-op.
pub const TextAnalysisSource = extern struct {
    vtable: *const VTable = &vtable_impl,
    text: [*]const u16,
    len: u32,
    locale: [*:0]const u16,

    pub const iid = guid(0x688e1a58, 0x5094, 0x47c8, .{ 0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b });

    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownMethods(Self),
        GetTextAtPosition: *const fn (*Self, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetTextBeforePosition: *const fn (*Self, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
        GetParagraphReadingDirection: *const fn (*Self) callconv(.winapi) ReadingDirection,
        GetLocaleName: *const fn (*Self, u32, *u32, *?[*:0]const u16) callconv(.winapi) HRESULT,
        GetNumberSubstitution: *const fn (*Self, u32, *u32, *?*IUnknown) callconv(.winapi) HRESULT,
    };

    const vtable_impl: VTable = .{
        .unknown = .{
            .QueryInterface = queryInterfaceImpl,
            .AddRef = refCount,
            .Release = refCount,
        },
        .GetTextAtPosition = getTextAtPosition,
        .GetTextBeforePosition = getTextBeforePosition,
        .GetParagraphReadingDirection = getParagraphReadingDirection,
        .GetLocaleName = getLocaleName,
        .GetNumberSubstitution = getNumberSubstitution,
    };

    fn queryInterfaceImpl(self: *Self, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (guidEql(riid, &iid) or guidEql(riid, &IUnknown.iid)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn refCount(_: *Self) callconv(.winapi) u32 {
        return 1;
    }

    fn getTextAtPosition(self: *Self, pos: u32, text: *?[*]const u16, len: *u32) callconv(.winapi) HRESULT {
        if (pos >= self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text + pos;
            len.* = self.len - pos;
        }
        return S_OK;
    }

    fn getTextBeforePosition(self: *Self, pos: u32, text: *?[*]const u16, len: *u32) callconv(.winapi) HRESULT {
        if (pos == 0 or pos > self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text;
            len.* = pos;
        }
        return S_OK;
    }

    fn getParagraphReadingDirection(_: *Self) callconv(.winapi) ReadingDirection {
        return .left_to_right;
    }

    fn getLocaleName(self: *Self, pos: u32, len: *u32, locale: *?[*:0]const u16) callconv(.winapi) HRESULT {
        len.* = self.len -| pos;
        locale.* = self.locale;
        return S_OK;
    }

    fn getNumberSubstitution(self: *Self, pos: u32, len: *u32, out: *?*IUnknown) callconv(.winapi) HRESULT {
        len.* = self.len -| pos;
        out.* = null;
        return S_OK;
    }
};

pub extern "dwrite" fn DWriteCreateFactory(
    factory_type: FactoryType,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub const LOCALE_NAME_MAX_LENGTH = 85;

pub extern "kernel32" fn GetUserDefaultLocaleName(
    name: [*]u16,
    len: c_int,
) callconv(.winapi) c_int;

pub const CP_ACP = 0;
pub const CP_UTF8 = 65001;
pub const WC_NO_BEST_FIT_CHARS = 0x400;

pub extern "kernel32" fn GetACP() callconv(.winapi) u32;

pub extern "kernel32" fn WideCharToMultiByte(
    code_page: u32,
    flags: u32,
    wide: [*]const u16,
    wide_len: c_int,
    multi: ?[*]u8,
    multi_len: c_int,
    default_char: ?[*:0]const u8,
    used_default_char: ?*BOOL,
) callconv(.winapi) c_int;

pub extern "kernel32" fn GetShortPathNameW(
    long_path: [*:0]const u16,
    short_path: ?[*]u16,
    len: u32,
) callconv(.winapi) u32;

pub const LF_FACESIZE = 32;
pub const LF_FULLFACESIZE = 64;
pub const DEFAULT_CHARSET = 1;
pub const RASTER_FONTTYPE = 1;
pub const FIXED_PITCH = 1;

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = DEFAULT_CHARSET,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [LF_FACESIZE]u16 = @splat(0),
};

pub const ENUMLOGFONTEXW = extern struct {
    elfLogFont: LOGFONTW,
    elfFullName: [LF_FULLFACESIZE]u16,
    elfStyle: [LF_FACESIZE]u16,
    elfScript: [LF_FACESIZE]u16,
};

pub const FONTENUMPROCW = *const fn (
    *const ENUMLOGFONTEXW,
    *const anyopaque,
    u32,
    isize,
) callconv(.winapi) c_int;

pub extern "gdi32" fn CreateCompatibleDC(hdc: ?windows.HDC) callconv(.winapi) ?windows.HDC;
pub extern "gdi32" fn DeleteDC(hdc: windows.HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateFontIndirectW(lf: *const LOGFONTW) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn SelectObject(hdc: windows.HDC, obj: *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn EnumFontFamiliesExW(
    hdc: windows.HDC,
    lf: *const LOGFONTW,
    proc: FONTENUMPROCW,
    param: isize,
    flags: u32,
) callconv(.winapi) c_int;

fn testCollection() !struct { *IDWriteFactory, *IDWriteFontCollection } {
    var factory_ptr: ?*anyopaque = null;
    try check(DWriteCreateFactory(.shared, &IDWriteFactory.iid, &factory_ptr));
    const factory: *IDWriteFactory = @ptrCast(@alignCast(factory_ptr.?));
    errdefer release(factory);
    return .{ factory, try factory.getSystemFontCollection() };
}

test "system collection finds a family and the file of its faces" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const factory, const collection = try testCollection();
    defer release(factory);
    defer release(collection);

    // Arial ships with every Windows installation.
    const name = std.unicode.utf8ToUtf16LeStringLiteral("arial");
    const index = (try collection.findFamilyName(name)) orelse return error.TestFontNotFound;
    const family = try collection.getFontFamily(index);
    defer release(family);
    try testing.expect(family.getFontCount() >= 4);

    const font = try family.getFont(0);
    defer release(font);
    try testing.expect(font.hasCharacter('A'));
    try testing.expect(!font.getSimulations().any());

    const face = try font.createFontFace();
    defer release(face);
    const file = try face.getFile();
    defer release(file);
    const loader = try file.getLoader();
    defer release(loader);
    const local = queryInterface(IDWriteLocalFontFileLoader, loader) orelse
        return error.TestUnexpectedResult;
    defer release(local);
    const path = try local.getFilePath(testing.allocator, try file.getReferenceKey());
    defer testing.allocator.free(path);
    const utf8 = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, path);
    defer testing.allocator.free(utf8);
    try testing.expect(std.ascii.endsWithIgnoreCase(utf8, ".ttf"));
}

test "system font fallback maps a character outside the base font" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const factory, const collection = try testCollection();
    defer release(factory);
    defer release(collection);
    const factory2 = queryInterface(IDWriteFactory2, factory) orelse return error.SkipZigTest;
    defer release(factory2);
    const fallback = try factory2.getSystemFontFallback();
    defer release(fallback);

    const text = [_]u16{ 0xD83D, 0xDE00 }; // U+1F600
    var source: TextAnalysisSource = .{
        .text = &text,
        .len = text.len,
        .locale = std.unicode.utf8ToUtf16LeStringLiteral("en-US"),
    };
    const mapping = try fallback.mapCharacters(&source, collection, .normal, .normal, .normal);
    const font = mapping.font orelse return error.TestFontNotFound;
    defer release(font);
    try testing.expectEqual(2, mapping.len);
    try testing.expect(font.hasCharacter(0x1F600));
}
