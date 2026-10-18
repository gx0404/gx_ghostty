//! Hand-written Direct2D 1.1 and DirectWrite bindings for the win32 UI,
//! and `Canvas`, the drawing helper every custom-drawn surface (popups,
//! title bar, tab bar, settings) paints with.
//!
//! Only the methods the UI calls are typed; the remaining vtable slots are
//! opaque placeholders that keep the layout (checked against the mingw-w64
//! d2d1.h / dwrite*.h vtables). Methods that return structs by value are
//! never called.
//!
//! `Factory` holds the process-wide D2D/DirectWrite factories, the
//! resolved UI/icon/monospace font families (Segoe UI Variable in its
//! Small, Text and Display optical sizes when installed), the CJK font
//! fallback (chosen from the UI language and the user locale), a text
//! format cache and a cache of laid-out text (`TextCache`); the app owns
//! one (`App.uiFactory`), and a failed creation is logged and remembered
//! once. A `Canvas` belongs to one render target (an HWND or a GDI DC) and
//! draws in DIPs: 1 unit = 1 pixel at 96 DPI. HWND targets present without
//! waiting for the vertical blank; DC targets render in software (their
//! pixels go back to GDI anyway). `Canvas.snap*`, `hairline*` and
//! `strokeRoundedRectPx` put edges on device pixels so thin lines stay
//! sharp at 125 % and 150 %. `beginDib` separates coverage and glyph
//! rasterization from stored BGRA backgrounds: replacement keeps channels
//! above alpha in the terminal's linear-light storage contract.
//!
//! Text: `drawText`/`measureText` lay out UTF-8 through the cache;
//! `TextLayout` is a layout the caller keeps, with hit testing, caret
//! positions and cluster stops for text inputs; `drawTextRuns` and
//! `drawLayout` color or embolden ranges (match highlights);
//! `drawTextMiddle` puts the ellipsis in the middle (paths).
//!
//! All of it is single-threaded and must only be used on the GUI thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const i18n = @import("../../../gx/i18n.zig");
const ui_color = @import("../../../gx/ui_color.zig");
const text_edit = @import("text_edit.zig");
const wstr = @import("wstr.zig");
const dcomp = @import("dcomp.zig");

const log = std.log.scoped(.win32_d2d);

pub const HRESULT = i32;
pub const GUID = w32.GUID;
pub const BOOL = i32;

/// A placeholder for vtable slots the UI never calls.
const Unused = *const anyopaque;

pub const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));
const E_NOT_SUFFICIENT_BUFFER: HRESULT = @bitCast(@as(u32, 0x8007007A));

fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// -----------------------------------------------------------------------
// Value types
// -----------------------------------------------------------------------

/// A straight-alpha RGBA color with components in 0..1 (D2D1_COLOR_F):
/// the GX interface color `gx.ui_color.Color`, an extern struct with this
/// layout, so the tokens of `gx.ui_tokens` draw as they are.
pub const Color = ui_color.Color;

comptime {
    std.debug.assert(@sizeOf(Color) == 16 and @offsetOf(Color, "a") == 12);
}

/// The GDI COLORREF (0x00BBGGRR) of a color, ignoring alpha.
pub fn colorRef(c: Color) u32 {
    const rgb = c.toRgb8();
    return @as(u32, rgb.r) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}

pub fn colorPixel(color: Color) u32 {
    return @import("../chrome/alpha.zig").colorPixel(.{ color.r, color.g, color.b, color.a });
}

extern "gdi32" fn GdiFlush() callconv(.winapi) i32;

pub const Point = extern struct { x: f32, y: f32 };
pub const Size = extern struct { width: f32, height: f32 };
pub const SizeU = extern struct { width: u32, height: u32 };

/// A rectangle in DIPs (origin and size).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn inset(self: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = @max(0, self.w - 2 * dx), .h = @max(0, self.h - 2 * dy) };
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.y >= self.y and p.x < self.x + self.w and p.y < self.y + self.h;
    }

    fn d2d(self: Rect) RectF {
        return .{ .left = self.x, .top = self.y, .right = self.x + self.w, .bottom = self.y + self.h };
    }
};

/// `v` (DIPs) moved to the nearest device pixel at `scale` (DPI / 96).
pub fn snapValue(v: f32, scale: f32) f32 {
    if (scale <= 0) return v;
    return @round(v * scale) / scale;
}

/// `rect` with each edge on the nearest device pixel at `scale`, so it
/// covers whole pixels (its size can differ by a pixel from `rect`'s).
pub fn snapRectTo(rect: Rect, scale: f32) Rect {
    const left = snapValue(rect.x, scale);
    const top = snapValue(rect.y, scale);
    const right = snapValue(rect.x + rect.w, scale);
    const bottom = snapValue(rect.y + rect.h, scale);
    return .{ .x = left, .y = top, .w = @max(0, right - left), .h = @max(0, bottom - top) };
}

/// `v` (DIPs) rounded up to whole device pixels at `scale`.
pub fn ceilValue(v: f32, scale: f32) f32 {
    if (scale <= 0) return @ceil(v);
    // A tiny tolerance keeps 13.0000001 px from becoming 14 px.
    return @ceil(v * scale - 0.001) / scale;
}

const RectF = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const RoundedRect = extern struct { rect: RectF, radius_x: f32, radius_y: f32 };
pub const Matrix3x2 = extern struct {
    m11: f32 = 1,
    m12: f32 = 0,
    m21: f32 = 0,
    m22: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    /// Row-vector composition: apply local coordinates before the target's
    /// existing transform, including its translation and nonuniform scale.
    pub fn then(a: Matrix3x2, b: Matrix3x2) Matrix3x2 {
        return .{
            .m11 = a.m11 * b.m11 + a.m12 * b.m21,
            .m12 = a.m11 * b.m12 + a.m12 * b.m22,
            .m21 = a.m21 * b.m11 + a.m22 * b.m21,
            .m22 = a.m21 * b.m12 + a.m22 * b.m22,
            .dx = a.dx * b.m11 + a.dy * b.m21 + b.dx,
            .dy = a.dx * b.m12 + a.dy * b.m22 + b.dy,
        };
    }
};
const PixelFormat = extern struct { format: u32, alpha_mode: u32 };
const BitmapProperties = extern struct { pixel_format: PixelFormat, dpi_x: f32, dpi_y: f32 };
const ID2D1Bitmap = extern struct { vtable: *const extern struct { unknown: IUnknownVtbl } };
const RenderTargetProperties = extern struct {
    type: u32 = D2D1_RENDER_TARGET_TYPE_DEFAULT,
    pixel_format: PixelFormat,
    dpi_x: f32 = 0,
    dpi_y: f32 = 0,
    usage: u32 = 0,
    min_level: u32 = 0,
};
const HwndRenderTargetProperties = extern struct {
    hwnd: w32.HWND,
    pixel_size: SizeU,
    present_options: u32 = 0,
};
const ArcSegment = extern struct {
    point: Point,
    size: Size,
    rotation_angle: f32,
    sweep_direction: u32,
    arc_size: u32,
};
const BezierSegment = extern struct { point1: Point, point2: Point, point3: Point };
const FactoryOptions = extern struct { debug_level: u32 = 0 };
const TextRange = extern struct { start: u32, length: u32 };

const HitTestMetrics = extern struct {
    text_position: u32,
    length: u32,
    left: f32,
    top: f32,
    width: f32,
    height: f32,
    bidi_level: u32,
    is_text: BOOL,
    is_trimmed: BOOL,
};

const ClusterMetrics = extern struct {
    width: f32,
    length: u16,
    flags: u16,
};

const D2D1_RENDER_TARGET_TYPE_DEFAULT: u32 = 0;
const D2D1_RENDER_TARGET_TYPE_SOFTWARE: u32 = 1;
const D2D1_PRESENT_OPTIONS_IMMEDIATELY: u32 = 2;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_ALPHA_MODE_IGNORE: u32 = 3;
const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
const D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 2;
const D2D1_ANTIALIAS_MODE_PER_PRIMITIVE: u32 = 0;
const D2D1_DRAW_TEXT_OPTIONS_CLIP: u32 = 2;
const D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT: u32 = 4;
const D2D1_FIGURE_BEGIN_FILLED: u32 = 0;
const D2D1_FIGURE_END_OPEN: u32 = 0;
const D2D1_FIGURE_END_CLOSED: u32 = 1;

const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;
const DWRITE_FONT_STYLE_NORMAL: u32 = 0;
const DWRITE_FONT_STRETCH_NORMAL: u32 = 5;
const DWRITE_WORD_WRAPPING_WRAP: u32 = 0;
const DWRITE_WORD_WRAPPING_NO_WRAP: u32 = 1;
const DWRITE_TRIMMING_GRANULARITY_CHARACTER: u32 = 1;
const DWRITE_LINE_SPACING_METHOD_UNIFORM: u32 = 1;

const Trimming = extern struct {
    granularity: u32,
    delimiter: u32 = 0,
    delimiter_count: u32 = 0,
};

const TextMetrics = extern struct {
    left: f32,
    top: f32,
    width: f32,
    width_including_trailing_whitespace: f32,
    height: f32,
    layout_width: f32,
    layout_height: f32,
    max_bidi_reordering_depth: u32,
    line_count: u32,
};

const UnicodeRange = extern struct { first: u32, last: u32 };

// -----------------------------------------------------------------------
// COM interfaces
// -----------------------------------------------------------------------

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

/// Release any COM object (all vtables start with IUnknown).
fn release(obj: anytype) void {
    const unknown: *const *const IUnknownVtbl = @ptrCast(@alignCast(obj));
    _ = unknown.*.Release(@ptrCast(obj));
}

fn queryInterface(obj: anytype, iid: *const GUID) ?*anyopaque {
    const unknown: *const *const IUnknownVtbl = @ptrCast(@alignCast(obj));
    var out: ?*anyopaque = null;
    if (!succeeded(unknown.*.QueryInterface(@ptrCast(obj), iid, &out))) return null;
    return out;
}

const IID_ID2D1Factory: GUID = .{ .Data1 = 0x06152247, .Data2 = 0x6f50, .Data3 = 0x465a, .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
const IID_ID2D1Factory1: GUID = .{ .Data1 = 0xbb12d362, .Data2 = 0xdaee, .Data3 = 0x4b9a, .Data4 = .{ 0xaa, 0x1d, 0x14, 0xba, 0x40, 0x1c, 0xfa, 0x1f } };
const IID_IDWriteFactory: GUID = .{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
const IID_IDWriteFactory2: GUID = .{ .Data1 = 0x0439fc60, .Data2 = 0xca44, .Data3 = 0x4994, .Data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec } };
const IID_IDWriteTextFormat1: GUID = .{ .Data1 = 0x5f174b49, .Data2 = 0x0d8b, .Data3 = 0x4cfb, .Data4 = .{ 0x8b, 0xca, 0xf1, 0xcc, 0xe9, 0xd0, 0x6c, 0x67 } };

const ID2D1Factory = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        ReloadSystemMetrics: Unused,
        GetDesktopDpi: Unused,
        CreateRectangleGeometry: Unused,
        CreateRoundedRectangleGeometry: Unused,
        CreateEllipseGeometry: Unused,
        CreateGeometryGroup: Unused,
        CreateTransformedGeometry: Unused,
        CreatePathGeometry: *const fn (*ID2D1Factory, *?*ID2D1PathGeometry) callconv(.winapi) HRESULT,
        CreateStrokeStyle: Unused,
        CreateDrawingStateBlock: Unused,
        CreateWicBitmapRenderTarget: Unused,
        CreateHwndRenderTarget: *const fn (*ID2D1Factory, *const RenderTargetProperties, *const HwndRenderTargetProperties, *?*ID2D1HwndRenderTarget) callconv(.winapi) HRESULT,
        CreateDxgiSurfaceRenderTarget: Unused,
        CreateDCRenderTarget: *const fn (*ID2D1Factory, *const RenderTargetProperties, *?*ID2D1DCRenderTarget) callconv(.winapi) HRESULT,
    };
};

const ID2D1RenderTarget = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        GetFactory: Unused,
        CreateBitmap: *const fn (*ID2D1RenderTarget, SizeU, ?*const anyopaque, u32, *const BitmapProperties, *?*ID2D1Bitmap) callconv(.winapi) HRESULT,
        CreateBitmapFromWicBitmap: Unused,
        CreateSharedBitmap: Unused,
        CreateBitmapBrush: Unused,
        CreateSolidColorBrush: *const fn (*ID2D1RenderTarget, *const Color, ?*const anyopaque, *?*ID2D1SolidColorBrush) callconv(.winapi) HRESULT,
        CreateGradientStopCollection: Unused,
        CreateLinearGradientBrush: Unused,
        CreateRadialGradientBrush: Unused,
        CreateCompatibleRenderTarget: Unused,
        CreateLayer: Unused,
        CreateMesh: Unused,
        DrawLine: *const fn (*ID2D1RenderTarget, Point, Point, *ID2D1SolidColorBrush, f32, ?*anyopaque) callconv(.winapi) void,
        DrawRectangle: *const fn (*ID2D1RenderTarget, *const RectF, *ID2D1SolidColorBrush, f32, ?*anyopaque) callconv(.winapi) void,
        FillRectangle: *const fn (*ID2D1RenderTarget, *const RectF, *ID2D1SolidColorBrush) callconv(.winapi) void,
        DrawRoundedRectangle: *const fn (*ID2D1RenderTarget, *const RoundedRect, *ID2D1SolidColorBrush, f32, ?*anyopaque) callconv(.winapi) void,
        FillRoundedRectangle: *const fn (*ID2D1RenderTarget, *const RoundedRect, *ID2D1SolidColorBrush) callconv(.winapi) void,
        DrawEllipse: Unused,
        FillEllipse: Unused,
        DrawGeometry: *const fn (*ID2D1RenderTarget, *ID2D1PathGeometry, *ID2D1SolidColorBrush, f32, ?*anyopaque) callconv(.winapi) void,
        FillGeometry: *const fn (*ID2D1RenderTarget, *ID2D1PathGeometry, *ID2D1SolidColorBrush, ?*anyopaque) callconv(.winapi) void,
        FillMesh: Unused,
        FillOpacityMask: Unused,
        DrawBitmap: *const fn (*ID2D1RenderTarget, *ID2D1Bitmap, ?*const RectF, f32, u32, ?*const RectF) callconv(.winapi) void,
        DrawText: Unused,
        DrawTextLayout: *const fn (*ID2D1RenderTarget, Point, *IDWriteTextLayout, *ID2D1SolidColorBrush, u32) callconv(.winapi) void,
        DrawGlyphRun: Unused,
        SetTransform: *const fn (*ID2D1RenderTarget, *const Matrix3x2) callconv(.winapi) void,
        GetTransform: *const fn (*ID2D1RenderTarget, *Matrix3x2) callconv(.winapi) void,
        SetAntialiasMode: *const fn (*ID2D1RenderTarget, u32) callconv(.winapi) void,
        GetAntialiasMode: Unused,
        SetTextAntialiasMode: *const fn (*ID2D1RenderTarget, u32) callconv(.winapi) void,
        GetTextAntialiasMode: Unused,
        SetTextRenderingParams: Unused,
        GetTextRenderingParams: Unused,
        SetTags: Unused,
        GetTags: Unused,
        PushLayer: Unused,
        PopLayer: Unused,
        Flush: Unused,
        SaveDrawingState: Unused,
        RestoreDrawingState: Unused,
        PushAxisAlignedClip: *const fn (*ID2D1RenderTarget, *const RectF, u32) callconv(.winapi) void,
        PopAxisAlignedClip: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        Clear: *const fn (*ID2D1RenderTarget, ?*const Color) callconv(.winapi) void,
        BeginDraw: *const fn (*ID2D1RenderTarget) callconv(.winapi) void,
        EndDraw: *const fn (*ID2D1RenderTarget, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        GetPixelFormat: Unused,
        SetDpi: *const fn (*ID2D1RenderTarget, f32, f32) callconv(.winapi) void,
        GetDpi: Unused,
        GetSize: Unused,
        GetPixelSize: Unused,
        GetMaximumBitmapSize: Unused,
        IsSupported: Unused,
    };
};

const ID2D1HwndRenderTarget = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        render_target: ID2D1RenderTarget.VTable,
        CheckWindowState: Unused,
        Resize: *const fn (*ID2D1HwndRenderTarget, *const SizeU) callconv(.winapi) HRESULT,
        GetHwnd: Unused,
    };
};

const ID2D1DCRenderTarget = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        render_target: ID2D1RenderTarget.VTable,
        BindDC: *const fn (*ID2D1DCRenderTarget, w32.HDC, *const w32.RECT) callconv(.winapi) HRESULT,
    };
};

const ID2D1SolidColorBrush = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        GetFactory: Unused,
        SetOpacity: Unused,
        SetTransform: Unused,
        GetOpacity: Unused,
        GetTransform: Unused,
        SetColor: *const fn (*ID2D1SolidColorBrush, *const Color) callconv(.winapi) void,
        GetColor: Unused,
    };
};

const ID2D1PathGeometry = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        GetFactory: Unused,
        GetBounds: Unused,
        GetWidenedBounds: Unused,
        StrokeContainsPoint: Unused,
        FillContainsPoint: Unused,
        CompareWithGeometry: Unused,
        Simplify: Unused,
        Tessellate: Unused,
        CombineWithGeometry: Unused,
        Outline: Unused,
        ComputeArea: Unused,
        ComputeLength: Unused,
        ComputePointAtLength: Unused,
        Widen: Unused,
        Open: *const fn (*ID2D1PathGeometry, *?*ID2D1GeometrySink) callconv(.winapi) HRESULT,
        Stream: Unused,
        GetSegmentCount: Unused,
        GetFigureCount: Unused,
    };
};

const ID2D1GeometrySink = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        SetFillMode: *const fn (*ID2D1GeometrySink, u32) callconv(.winapi) void,
        SetSegmentFlags: Unused,
        BeginFigure: *const fn (*ID2D1GeometrySink, Point, u32) callconv(.winapi) void,
        AddLines: Unused,
        AddBeziers: Unused,
        EndFigure: *const fn (*ID2D1GeometrySink, u32) callconv(.winapi) void,
        Close: *const fn (*ID2D1GeometrySink) callconv(.winapi) HRESULT,
        AddLine: *const fn (*ID2D1GeometrySink, Point) callconv(.winapi) void,
        AddBezier: *const fn (*ID2D1GeometrySink, *const BezierSegment) callconv(.winapi) void,
        AddQuadraticBezier: Unused,
        AddQuadraticBeziers: Unused,
        AddArc: *const fn (*ID2D1GeometrySink, *const ArcSegment) callconv(.winapi) void,
    };
};

const IDWriteFactory = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(.winapi) HRESULT,
        CreateCustomFontCollection: Unused,
        RegisterFontCollectionLoader: Unused,
        UnregisterFontCollectionLoader: Unused,
        CreateFontFileReference: Unused,
        CreateCustomFontFileReference: Unused,
        CreateFontFace: Unused,
        CreateRenderingParams: Unused,
        CreateMonitorRenderingParams: Unused,
        CreateCustomRenderingParams: Unused,
        RegisterFontFileLoader: Unused,
        UnregisterFontFileLoader: Unused,
        CreateTextFormat: *const fn (*IDWriteFactory, [*:0]const u16, ?*anyopaque, u32, u32, u32, f32, [*:0]const u16, *?*IDWriteTextFormat) callconv(.winapi) HRESULT,
        CreateTypography: Unused,
        GetGdiInterop: Unused,
        CreateTextLayout: *const fn (*IDWriteFactory, [*]const u16, u32, *IDWriteTextFormat, f32, f32, *?*IDWriteTextLayout) callconv(.winapi) HRESULT,
        CreateGdiCompatibleTextLayout: Unused,
        CreateEllipsisTrimmingSign: *const fn (*IDWriteFactory, *IDWriteTextFormat, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateTextAnalyzer: Unused,
        CreateNumberSubstitution: Unused,
        CreateGlyphRunAnalysis: Unused,
    };
};

const IDWriteFactory2 = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        factory: IDWriteFactory.VTable,
        // IDWriteFactory1
        GetEudcFontCollection: Unused,
        CreateCustomRenderingParams1: Unused,
        // IDWriteFactory2
        GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
        CreateFontFallbackBuilder: *const fn (*IDWriteFactory2, *?*IDWriteFontFallbackBuilder) callconv(.winapi) HRESULT,
        TranslateColorGlyphRun: Unused,
        CreateCustomRenderingParams2: Unused,
        CreateGlyphRunAnalysis2: Unused,
    };
};

const IDWriteFontCollection = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        GetFontFamilyCount: Unused,
        GetFontFamily: Unused,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const u16, *u32, *BOOL) callconv(.winapi) HRESULT,
        GetFontFromFontFace: Unused,
    };
};

const IDWriteFontFallback = opaque {};

const IDWriteFontFallbackBuilder = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        unknown: IUnknownVtbl,
        AddMapping: *const fn (*IDWriteFontFallbackBuilder, [*]const UnicodeRange, u32, [*]const [*:0]const u16, u32, ?*IDWriteFontCollection, ?[*:0]const u16, ?[*:0]const u16, f32) callconv(.winapi) HRESULT,
        AddMappings: *const fn (*IDWriteFontFallbackBuilder, *IDWriteFontFallback) callconv(.winapi) HRESULT,
        CreateFontFallback: *const fn (*IDWriteFontFallbackBuilder, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
    };
};

/// The format methods shared by IDWriteTextFormat and IDWriteTextLayout.
const TextFormatVTable = extern struct {
    unknown: IUnknownVtbl,
    SetTextAlignment: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
    SetParagraphAlignment: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
    SetWordWrapping: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
    SetReadingDirection: Unused,
    SetFlowDirection: Unused,
    SetIncrementalTabStop: Unused,
    SetTrimming: *const fn (*anyopaque, *const Trimming, ?*anyopaque) callconv(.winapi) HRESULT,
    SetLineSpacing: *const fn (*anyopaque, u32, f32, f32) callconv(.winapi) HRESULT,
    GetTextAlignment: Unused,
    GetParagraphAlignment: Unused,
    GetWordWrapping: Unused,
    GetReadingDirection: Unused,
    GetFlowDirection: Unused,
    GetIncrementalTabStop: Unused,
    GetTrimming: Unused,
    GetLineSpacing: Unused,
    GetFontCollection: Unused,
    GetFontFamilyNameLength: Unused,
    GetFontFamilyName: Unused,
    GetFontWeight: Unused,
    GetFontStyle: Unused,
    GetFontStretch: Unused,
    GetFontSize: Unused,
    GetLocaleNameLength: Unused,
    GetLocaleName: Unused,
};

const IDWriteTextFormat = extern struct {
    vtable: *const TextFormatVTable,
};

const IDWriteTextFormat1 = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        format: TextFormatVTable,
        SetVerticalGlyphOrientation: Unused,
        GetVerticalGlyphOrientation: Unused,
        SetLastLineWrapping: Unused,
        GetLastLineWrapping: Unused,
        SetOpticalAlignment: Unused,
        GetOpticalAlignment: Unused,
        SetFontFallback: *const fn (*IDWriteTextFormat1, *IDWriteFontFallback) callconv(.winapi) HRESULT,
        GetFontFallback: Unused,
    };
};

const IDWriteTextLayout = extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        format: TextFormatVTable,
        SetMaxWidth: Unused,
        SetMaxHeight: Unused,
        SetFontCollection: Unused,
        SetFontFamilyName: Unused,
        SetFontWeight: *const fn (*IDWriteTextLayout, u32, TextRange) callconv(.winapi) HRESULT,
        SetFontStyle: Unused,
        SetFontStretch: Unused,
        SetFontSize: Unused,
        SetUnderline: *const fn (*IDWriteTextLayout, BOOL, TextRange) callconv(.winapi) HRESULT,
        SetStrikethrough: Unused,
        SetDrawingEffect: *const fn (*IDWriteTextLayout, ?*anyopaque, TextRange) callconv(.winapi) HRESULT,
        SetInlineObject: Unused,
        SetTypography: Unused,
        SetLocaleName: Unused,
        GetMaxWidth: Unused,
        GetMaxHeight: Unused,
        GetFontCollection2: Unused,
        GetFontFamilyNameLength2: Unused,
        GetFontFamilyName2: Unused,
        GetFontWeight2: Unused,
        GetFontStyle2: Unused,
        GetFontStretch2: Unused,
        GetFontSize2: Unused,
        GetUnderline: Unused,
        GetStrikethrough: Unused,
        GetDrawingEffect: Unused,
        GetInlineObject: Unused,
        GetTypography: Unused,
        GetLocaleNameLength2: Unused,
        GetLocaleName2: Unused,
        Draw: Unused,
        GetLineMetrics: Unused,
        GetMetrics: *const fn (*IDWriteTextLayout, *TextMetrics) callconv(.winapi) HRESULT,
        GetOverhangMetrics: Unused,
        GetClusterMetrics: *const fn (*IDWriteTextLayout, ?[*]ClusterMetrics, u32, *u32) callconv(.winapi) HRESULT,
        DetermineMinWidth: Unused,
        HitTestPoint: *const fn (*IDWriteTextLayout, f32, f32, *BOOL, *BOOL, *HitTestMetrics) callconv(.winapi) HRESULT,
        HitTestTextPosition: *const fn (*IDWriteTextLayout, u32, BOOL, *f32, *f32, *HitTestMetrics) callconv(.winapi) HRESULT,
        HitTestTextRange: Unused,
    };
};

comptime {
    // Slot counts from the mingw-w64 C vtables (IUnknown included).
    const slot = @sizeOf(usize);
    std.debug.assert(@sizeOf(ID2D1Factory.VTable) == 17 * slot);
    std.debug.assert(@sizeOf(ID2D1RenderTarget.VTable) == 57 * slot);
    std.debug.assert(@sizeOf(ID2D1HwndRenderTarget.VTable) == 60 * slot);
    std.debug.assert(@sizeOf(ID2D1DCRenderTarget.VTable) == 58 * slot);
    std.debug.assert(@sizeOf(ID2D1SolidColorBrush.VTable) == 10 * slot);
    std.debug.assert(@sizeOf(ID2D1PathGeometry.VTable) == 21 * slot);
    std.debug.assert(@sizeOf(ID2D1GeometrySink.VTable) == 15 * slot);
    std.debug.assert(@sizeOf(IDWriteFactory.VTable) == 24 * slot);
    std.debug.assert(@sizeOf(IDWriteFactory2.VTable) == 31 * slot);
    std.debug.assert(@sizeOf(IDWriteFontCollection.VTable) == 7 * slot);
    std.debug.assert(@sizeOf(IDWriteFontFallbackBuilder.VTable) == 6 * slot);
    std.debug.assert(@sizeOf(TextFormatVTable) == 28 * slot);
    std.debug.assert(@sizeOf(IDWriteTextFormat1.VTable) == 36 * slot);
    std.debug.assert(@sizeOf(IDWriteTextLayout.VTable) == 67 * slot);
    // DWRITE_HIT_TEST_METRICS and DWRITE_CLUSTER_METRICS.
    std.debug.assert(@sizeOf(HitTestMetrics) == 36);
    std.debug.assert(@sizeOf(ClusterMetrics) == 8);
}

extern "d2d1" fn D2D1CreateFactory(
    factory_type: u32,
    riid: *const GUID,
    options: ?*const FactoryOptions,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

extern "dwrite" fn DWriteCreateFactory(
    factory_type: u32,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn GetUserDefaultLocaleName(
    name: [*]u16,
    len: c_int,
) callconv(.winapi) c_int;

// -----------------------------------------------------------------------
// Fonts
// -----------------------------------------------------------------------

/// Which font a text style uses.
pub const FontKind = enum {
    /// The UI font ("Segoe UI Variable" in the optical size for the font
    /// size, else "Segoe UI") with the CJK fallback.
    ui,

    /// The icon font ("Segoe Fluent Icons", else "Segoe MDL2 Assets").
    icon,

    /// A monospace font for terminal text ("Cascadia Mono", else
    /// "Consolas"), with the UI font's CJK fallback.
    mono,
};

pub const FontWeight = enum(u32) {
    normal = 400,
    semibold = 600,
    bold = 700,
};

pub const TextAlign = enum(u32) {
    leading = 0,
    trailing = 1,
    center = 2,
};

pub const VerticalAlign = enum(u32) {
    top = 0,
    bottom = 1,
    center = 2,
};

/// How a piece of text is drawn or measured.
pub const TextStyle = struct {
    font: FontKind = .ui,
    /// Font size in DIPs.
    size: f32 = 14,
    weight: FontWeight = .normal,
    color: Color = .{ .r = 1, .g = 1, .b = 1 },
    align_x: TextAlign = .leading,
    align_y: VerticalAlign = .center,
    /// Wrap at word boundaries instead of keeping a single line.
    wrap: bool = false,
    /// Trim overflowing text with an ellipsis.
    ellipsis: bool = true,
    /// Line height in DIPs (e.g. 20 for the 14/20 body style); 0 keeps
    /// the font's own line spacing.
    line_height: f32 = 0,
    /// A font family by name (e.g. to preview a font), overriding `font`
    /// but keeping its CJK fallback; empty for the `font` family.
    family: []const u8 = "",
};

/// The optical size of Segoe UI Variable for a font size (Fluent type
/// ramp): Small below 13 DIPs, Display from 20 DIPs, Text in between.
pub const OpticalSize = enum { small, text, display };

pub fn opticalSize(size: f32) OpticalSize {
    if (size < 13) return .small;
    if (size >= 20) return .display;
    return .text;
}

/// The CJK font of the UI text.
pub const CjkFont = enum {
    yahei,
    jhenghei,
    yu_gothic,
    malgun,

    fn family(self: CjkFont) [:0]const u16 {
        const L = std.unicode.utf8ToUtf16LeStringLiteral;
        return switch (self) {
            .yahei => L("Microsoft YaHei UI"),
            .jhenghei => L("Microsoft JhengHei UI"),
            .yu_gothic => L("Yu Gothic UI"),
            .malgun => L("Malgun Gothic"),
        };
    }
};

/// The CJK font for the UI language and the user locale (BCP 47, from
/// `GetUserDefaultLocaleName`): the Chinese UI uses Microsoft YaHei UI;
/// the English one draws CJK text (titles, paths) in the font of the
/// user's region.
pub fn cjkFontFor(language: i18n.Language, locale: []const u8) CjkFont {
    if (language == .zh_CN) return .yahei;
    if (startsWithIgnoreCase(locale, "ja")) return .yu_gothic;
    if (startsWithIgnoreCase(locale, "ko")) return .malgun;
    if (startsWithIgnoreCase(locale, "zh")) {
        if (std.ascii.findIgnoreCase(locale, "hant") != null) return .jhenghei;
        for ([_][]const u8{ "zh-TW", "zh-HK", "zh-MO" }) |prefix| {
            if (startsWithIgnoreCase(locale, prefix)) return .jhenghei;
        }
    }
    return .yahei;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) return false;
    // "ja" must not match "jav": the language subtag ends here.
    return text.len == prefix.len or text[prefix.len] == '-' or text[prefix.len] == '_';
}

fn userLocale(buf: []u8) []const u8 {
    var units: [85]u16 = undefined;
    const n = GetUserDefaultLocaleName(&units, units.len);
    if (n <= 1) return "";
    return wstr.utf8Buf(buf, units[0..@intCast(n - 1)]);
}

// -----------------------------------------------------------------------
// Generational cache
// -----------------------------------------------------------------------

/// A cache of byte-string keys that holds at most 2 × `capacity` entries
/// and forgets the least recently used ones a generation at a time:
/// entries live in the young generation; a hit in the old one moves the
/// entry back; when the young generation is full, the old one is dropped
/// (`release` frees its values) and the young one becomes old.
pub fn GenerationalCache(comptime V: type, comptime release_value: fn (V) void) type {
    return struct {
        const Self = @This();
        const Map = std.StringHashMapUnmanaged(V);

        young: Map = .empty,
        old: Map = .empty,
        capacity: u32,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.clear(alloc);
            self.young.deinit(alloc);
            self.old.deinit(alloc);
        }

        /// Drop every entry.
        pub fn clear(self: *Self, alloc: Allocator) void {
            drop(alloc, &self.young);
            drop(alloc, &self.old);
        }

        pub fn count(self: *const Self) usize {
            return self.young.count() + self.old.count();
        }

        fn drop(alloc: Allocator, map: *Map) void {
            var it = map.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                release_value(entry.value_ptr.*);
            }
            map.clearRetainingCapacity();
        }

        fn rotate(self: *Self, alloc: Allocator) void {
            drop(alloc, &self.old);
            std.mem.swap(Map, &self.young, &self.old);
        }

        /// The value for `key`, valid until the next `put` or `get`.
        pub fn get(self: *Self, alloc: Allocator, key: []const u8) ?*V {
            if (self.young.getPtr(key)) |value| return value;
            const entry = self.old.fetchRemove(key) orelse return null;
            if (self.young.count() >= self.capacity) self.rotate(alloc);
            self.young.putNoClobber(alloc, entry.key, entry.value) catch {
                alloc.free(entry.key);
                release_value(entry.value);
                return null;
            };
            return self.young.getPtr(entry.key);
        }

        /// Add `value` for `key` (not in the cache); the cache owns it from
        /// now on, also when adding fails (it is released then).
        pub fn put(self: *Self, alloc: Allocator, key: []const u8, value: V) ?*V {
            if (self.young.count() >= self.capacity) self.rotate(alloc);
            const owned = alloc.dupe(u8, key) catch {
                release_value(value);
                return null;
            };
            self.young.putNoClobber(alloc, owned, value) catch {
                alloc.free(owned);
                release_value(value);
                return null;
            };
            return self.young.getPtr(owned);
        }
    };
}

// -----------------------------------------------------------------------
// Factory
// -----------------------------------------------------------------------

const FormatKey = struct {
    font: FontKind,
    size: f32,
    weight: FontWeight,
    /// `TextStyle.family`; owned by the cache once stored.
    family: []const u8 = "",

    fn eql(a: FormatKey, b: FormatKey) bool {
        return a.font == b.font and a.size == b.size and a.weight == b.weight and
            std.mem.eql(u8, a.family, b.family);
    }
};

const CachedFormat = struct {
    key: FormatKey,
    format: *IDWriteTextFormat,
    ellipsis: ?*anyopaque,
};

/// A laid-out text kept by `TextCache`, with its metrics once measured.
const CachedLayout = struct {
    layout: *IDWriteTextLayout,
    metrics: ?TextMetrics = null,
};

fn releaseCachedLayout(entry: CachedLayout) void {
    release(entry.layout);
}

/// Laid-out text by format, layout box and text (`Factory.text_cache`).
pub const TextCache = GenerationalCache(CachedLayout, releaseCachedLayout);

/// The layout parameters of a `TextCache` key; all fields are 4 bytes
/// wide, so the struct has no padding and hashes deterministically.
const LayoutKey = extern struct {
    font: u32,
    weight: u32,
    align_x: u32,
    align_y: u32,
    wrap: u32,
    ellipsis: u32,
    size: f32,
    max_w: f32,
    max_h: f32,
    line_height: f32,
    family_len: u32,

    fn of(style: TextStyle, max_w: f32, max_h: f32) LayoutKey {
        return .{
            .font = @intFromEnum(style.font),
            .weight = @intFromEnum(style.weight),
            .align_x = @intFromEnum(style.align_x),
            .align_y = @intFromEnum(style.align_y),
            .wrap = @intFromBool(style.wrap),
            .ellipsis = @intFromBool(style.ellipsis),
            .size = style.size,
            .max_w = @max(max_w, 0),
            .max_h = @max(max_h, 0),
            .line_height = style.line_height,
            .family_len = @intCast(style.family.len),
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(LayoutKey) == 11 * 4);
}

/// The cache key of a layout: the parameters, the family and the text;
/// null when it does not fit `buf` (such text is laid out uncached).
fn layoutKey(buf: []u8, text: []const u8, style: TextStyle, max_w: f32, max_h: f32) ?[]const u8 {
    const params = LayoutKey.of(style, max_w, max_h);
    const head = std.mem.asBytes(&params);
    const len = head.len + style.family.len + text.len;
    if (len > buf.len) return null;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..style.family.len], style.family);
    @memcpy(buf[head.len + style.family.len ..][0..text.len], text);
    return buf[0..len];
}

/// Why creating the factory failed, so later calls fail at once without
/// another log line (GUI thread only).
var create_failure: ?Factory.Error = null;

/// The process-wide D2D and DirectWrite state of the UI.
pub const Factory = struct {
    alloc: Allocator,
    d2d: *ID2D1Factory,
    /// Whether `d2d` is a Direct2D 1.1 factory (color fonts).
    d2d_1_1: bool,
    dwrite: *IDWriteFactory,
    fallback: ?*IDWriteFontFallback = null,
    /// The CJK font `fallback` maps to.
    cjk: ?CjkFont = null,
    ui_family: [:0]const u16,
    /// The optical sizes of Segoe UI Variable, when installed.
    ui_small: ?[:0]const u16 = null,
    ui_display: ?[:0]const u16 = null,
    icon_family: [:0]const u16,
    mono_family: [:0]const u16,
    formats: std.ArrayList(CachedFormat) = .empty,
    text_cache: TextCache = .{ .capacity = text_cache_capacity },
    popup_device: ?dcomp.Device = null,
    popup_device_attempted: bool = false,

    /// One optional D3D/D2D composition device shared by every popup. Failure
    /// stays legacy for this factory lifetime instead of retrying every paint.
    pub fn popupDevice(self: *Factory) ?*dcomp.Device {
        if (!self.popup_device_attempted) {
            self.popup_device_attempted = true;
            if (self.d2d_1_1 and dcomp.enabled()) self.popup_device = dcomp.Device.init(self.d2d) catch |err| result: {
                log.warn("popup composition device unavailable; using legacy err={}", .{err});
                break :result null;
            };
        }
        return if (self.popup_device) |*device| device else null;
    }

    pub const Error = error{ Direct2DUnavailable, DirectWriteUnavailable, OutOfMemory };

    /// Empty factory-owned geometry. Call beginFigure/endFigure for each
    /// contour, then finish once; only successful geometry may be cached.
    pub fn createPath(self: *Factory) ?Path {
        var geometry: ?*ID2D1PathGeometry = null;
        if (!succeeded(self.d2d.vtable.CreatePathGeometry(self.d2d, &geometry))) return null;
        const g = geometry orelse return null;
        var sink: ?*ID2D1GeometrySink = null;
        if (!succeeded(g.vtable.Open(g, &sink)) or sink == null) {
            release(g);
            return null;
        }
        return .{ .geometry = g, .sink = sink };
    }

    /// Entries per `TextCache` generation.
    pub const text_cache_capacity = 256;
    /// Formats with a custom family kept at most (font previews).
    const max_family_formats = 64;

    const cjk_ranges = [_]UnicodeRange{
        .{ .first = 0x2E80, .last = 0x2FDF },
        .{ .first = 0x3000, .last = 0x303F },
        .{ .first = 0x3040, .last = 0x30FF },
        .{ .first = 0x3100, .last = 0x312F },
        .{ .first = 0x3190, .last = 0x31FF },
        .{ .first = 0x3400, .last = 0x4DBF },
        .{ .first = 0x4E00, .last = 0x9FFF },
        .{ .first = 0xF900, .last = 0xFAFF },
        .{ .first = 0xFE30, .last = 0xFE4F },
        .{ .first = 0xFF00, .last = 0xFFEF },
        .{ .first = 0x20000, .last = 0x2FFFF },
    };

    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    /// Create the factory; a failure is logged once and returned again by
    /// later calls without retrying.
    pub fn create(alloc: Allocator) Error!*Factory {
        if (create_failure) |err| return err;
        return createNew(alloc) catch |err| {
            create_failure = err;
            log.warn("Direct2D UI unavailable err={}", .{err});
            return err;
        };
    }

    fn createNew(alloc: Allocator) Error!*Factory {
        var d2d_ptr: ?*anyopaque = null;
        var d2d_1_1 = true;
        if (!succeeded(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory1, null, &d2d_ptr))) {
            d2d_1_1 = false;
            if (!succeeded(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory, null, &d2d_ptr)))
                return error.Direct2DUnavailable;
        }
        const d2d: *ID2D1Factory = @ptrCast(@alignCast(d2d_ptr orelse return error.Direct2DUnavailable));
        errdefer release(d2d);

        var dwrite_ptr: ?*anyopaque = null;
        if (!succeeded(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, &dwrite_ptr)))
            return error.DirectWriteUnavailable;
        const dwrite: *IDWriteFactory = @ptrCast(@alignCast(dwrite_ptr orelse return error.DirectWriteUnavailable));
        errdefer release(dwrite);

        const self = try alloc.create(Factory);
        self.* = .{
            .alloc = alloc,
            .d2d = d2d,
            .d2d_1_1 = d2d_1_1,
            .dwrite = dwrite,
            .ui_family = L("Segoe UI"),
            .icon_family = L("Segoe MDL2 Assets"),
            .mono_family = L("Consolas"),
        };

        if (self.systemFontCollection()) |collection| {
            defer release(collection);
            if (hasFamily(collection, L("Segoe UI Variable Text"))) {
                self.ui_family = L("Segoe UI Variable Text");
                if (hasFamily(collection, L("Segoe UI Variable Small"))) self.ui_small = L("Segoe UI Variable Small");
                if (hasFamily(collection, L("Segoe UI Variable Display"))) self.ui_display = L("Segoe UI Variable Display");
            }
            if (hasFamily(collection, L("Segoe Fluent Icons"))) self.icon_family = L("Segoe Fluent Icons");
            if (hasFamily(collection, L("Cascadia Mono"))) self.mono_family = L("Cascadia Mono");
        }
        self.updateFallback();
        return self;
    }

    pub fn destroy(self: *Factory) void {
        if (self.popup_device) |*device| device.deinit();
        self.flushFormats();
        self.formats.deinit(self.alloc);
        self.text_cache.deinit(self.alloc);
        if (self.fallback) |f| release(f);
        release(self.dwrite);
        release(self.d2d);
        self.alloc.destroy(self);
    }

    /// Drop the cached text formats and laid-out text, e.g. after a UI
    /// language change (formats carry the locale, and the CJK fallback
    /// follows the language).
    pub fn flushFormats(self: *Factory) void {
        self.text_cache.clear(self.alloc);
        for (self.formats.items) |cached| freeFormat(self.alloc, cached);
        self.formats.clearRetainingCapacity();
        self.updateFallback();
    }

    fn freeFormat(alloc: Allocator, cached: CachedFormat) void {
        if (cached.ellipsis) |sign| release(sign);
        release(cached.format);
        if (cached.key.family.len > 0) alloc.free(cached.key.family);
    }

    fn systemFontCollection(self: *Factory) ?*IDWriteFontCollection {
        var collection: ?*IDWriteFontCollection = null;
        if (!succeeded(self.dwrite.vtable.GetSystemFontCollection(self.dwrite, &collection, 0))) return null;
        return collection;
    }

    fn hasFamily(collection: *IDWriteFontCollection, name: [*:0]const u16) bool {
        var index: u32 = 0;
        var exists: BOOL = 0;
        if (!succeeded(collection.vtable.FindFamilyName(collection, name, &index, &exists))) return false;
        return exists != 0;
    }

    /// Build the font fallback for the current UI language and user locale
    /// when it changed.
    fn updateFallback(self: *Factory) void {
        var locale_buf: [96]u8 = undefined;
        const cjk = cjkFontFor(i18n.current(), userLocale(&locale_buf));
        if (self.cjk == cjk and self.fallback != null) return;
        if (self.fallback) |f| release(f);
        self.fallback = self.createFallback(cjk);
        self.cjk = cjk;
    }

    /// A font fallback that maps CJK text to `cjk` before the system
    /// fallback. Null before Windows 8.1 (no IDWriteFactory2).
    fn createFallback(self: *Factory, cjk: CjkFont) ?*IDWriteFontFallback {
        const factory2: *IDWriteFactory2 = @ptrCast(@alignCast(queryInterface(self.dwrite, &IID_IDWriteFactory2) orelse return null));
        defer release(factory2);

        var builder: ?*IDWriteFontFallbackBuilder = null;
        if (!succeeded(factory2.vtable.CreateFontFallbackBuilder(factory2, &builder))) return null;
        const b = builder orelse return null;
        defer release(b);

        const families = [_][*:0]const u16{cjk.family()};
        if (!succeeded(b.vtable.AddMapping(b, &cjk_ranges, cjk_ranges.len, &families, families.len, null, null, null, 1.0))) return null;

        var system: ?*IDWriteFontFallback = null;
        if (succeeded(factory2.vtable.GetSystemFontFallback(factory2, &system))) {
            if (system) |sys| {
                defer release(sys);
                _ = b.vtable.AddMappings(b, sys);
            }
        }

        var fallback: ?*IDWriteFontFallback = null;
        if (!succeeded(b.vtable.CreateFontFallback(b, &fallback))) return null;
        return fallback;
    }

    /// The UI family for a font size: Segoe UI Variable in its optical
    /// size when installed.
    fn uiFamily(self: *const Factory, size: f32) [:0]const u16 {
        return switch (opticalSize(size)) {
            .small => self.ui_small orelse self.ui_family,
            .text => self.ui_family,
            .display => self.ui_display orelse self.ui_family,
        };
    }

    /// The (cached) text format for a font, size, weight and family.
    fn textFormat(self: *Factory, key: FormatKey) ?*CachedFormat {
        for (self.formats.items) |*cached| {
            if (cached.key.eql(key)) return cached;
        }

        var family_buf: [128]u16 = undefined;
        const family: [:0]const u16 = if (key.family.len > 0)
            wstr.bufZ(&family_buf, key.family)
        else switch (key.font) {
            .ui => self.uiFamily(key.size),
            .icon => self.icon_family,
            .mono => self.mono_family,
        };
        const locale = switch (i18n.current()) {
            .zh_CN => L("zh-CN"),
            .en => L("en-US"),
        };
        var format: ?*IDWriteTextFormat = null;
        if (!succeeded(self.dwrite.vtable.CreateTextFormat(
            self.dwrite,
            family,
            null,
            @intFromEnum(key.weight),
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            key.size,
            locale,
            &format,
        ))) return null;
        const f = format orelse return null;

        if (key.font != .icon or key.family.len > 0) {
            if (self.fallback) |fallback| {
                if (queryInterface(f, &IID_IDWriteTextFormat1)) |ptr| {
                    const format1: *IDWriteTextFormat1 = @ptrCast(@alignCast(ptr));
                    defer release(format1);
                    _ = format1.vtable.SetFontFallback(format1, fallback);
                }
            }
        }

        var sign: ?*anyopaque = null;
        if (!succeeded(self.dwrite.vtable.CreateEllipsisTrimmingSign(self.dwrite, f, &sign))) sign = null;

        var stored = key;
        if (key.family.len > 0) {
            self.dropFamilyFormats();
            stored.family = self.alloc.dupe(u8, key.family) catch {
                if (sign) |s| release(s);
                release(f);
                return null;
            };
        }
        self.formats.append(self.alloc, .{ .key = stored, .format = f, .ellipsis = sign }) catch {
            freeFormat(self.alloc, .{ .key = stored, .format = f, .ellipsis = sign });
            return null;
        };
        return &self.formats.items[self.formats.items.len - 1];
    }

    /// Keep the formats of custom families (previews of many fonts) from
    /// piling up: drop them all past `max_family_formats`.
    fn dropFamilyFormats(self: *Factory) void {
        var families: usize = 0;
        for (self.formats.items) |cached| {
            if (cached.key.family.len > 0) families += 1;
        }
        if (families < max_family_formats) return;
        var i: usize = 0;
        while (i < self.formats.items.len) {
            const cached = self.formats.items[i];
            if (cached.key.family.len > 0) {
                freeFormat(self.alloc, cached);
                _ = self.formats.swapRemove(i);
            } else i += 1;
        }
    }

    fn formatOf(self: *Factory, style: TextStyle) ?*CachedFormat {
        return self.textFormat(.{ .font = style.font, .size = style.size, .weight = style.weight, .family = style.family });
    }

    /// Lay out UTF-16 `text` in a box; the caller releases the layout.
    fn createLayout16(self: *Factory, text: []const u16, style: TextStyle, max_w: f32, max_h: f32) ?*IDWriteTextLayout {
        const cached = self.formatOf(style) orelse return null;
        var out: ?*IDWriteTextLayout = null;
        @import("../../../gx/perf.zig").count("d2d.layout_create", 1);
        if (!succeeded(self.dwrite.vtable.CreateTextLayout(
            self.dwrite,
            text.ptr,
            @intCast(text.len),
            cached.format,
            @max(max_w, 0),
            @max(max_h, 0),
            &out,
        ))) return null;
        const l = out orelse return null;

        const vt = &l.vtable.format;
        _ = vt.SetTextAlignment(l, @intFromEnum(style.align_x));
        _ = vt.SetParagraphAlignment(l, @intFromEnum(style.align_y));
        _ = vt.SetWordWrapping(l, if (style.wrap) DWRITE_WORD_WRAPPING_WRAP else DWRITE_WORD_WRAPPING_NO_WRAP);
        if (style.ellipsis) {
            _ = vt.SetTrimming(l, &.{ .granularity = DWRITE_TRIMMING_GRANULARITY_CHARACTER }, cached.ellipsis);
        }
        if (style.line_height > 0) {
            // Baseline at 80 % of the line centers Segoe UI's ascent and
            // descent in the line.
            _ = vt.SetLineSpacing(l, DWRITE_LINE_SPACING_METHOD_UNIFORM, style.line_height, style.line_height * 0.8);
        }
        return l;
    }

    /// Lay out UTF-8 `text`; the caller releases the layout.
    fn createLayout(self: *Factory, text: []const u8, style: TextStyle, max_w: f32, max_h: f32) ?*IDWriteTextLayout {
        var stack: [512]u16 = undefined;
        var heap: ?[:0]u16 = null;
        defer if (heap) |h| self.alloc.free(h);
        const text16: []const u16 = if (wstr.utf16Len(text) < stack.len)
            wstr.bufZ(&stack, text)
        else blk: {
            heap = wstr.allocZ(self.alloc, text) catch return null;
            break :blk heap.?;
        };
        return self.createLayout16(text16, style, max_w, max_h);
    }

    /// A layout of UTF-8 `text` from the text cache, laid out on a miss.
    fn layout(self: *Factory, text: []const u8, style: TextStyle, max_w: f32, max_h: f32) ?LayoutRef {
        var key_buf: [1024]u8 = undefined;
        const key = layoutKey(&key_buf, text, style, max_w, max_h) orelse {
            const l = self.createLayout(text, style, max_w, max_h) orelse return null;
            return .{ .layout = l, .entry = null };
        };
        if (self.text_cache.get(self.alloc, key)) |entry| return .{ .layout = entry.layout, .entry = entry };
        const l = self.createLayout(text, style, max_w, max_h) orelse return null;
        const entry = self.text_cache.put(self.alloc, key, .{ .layout = l }) orelse return null;
        return .{ .layout = entry.layout, .entry = entry };
    }

    /// Measure UTF-8 `text` laid out with `style`, at most `max_width`
    /// wide.
    pub fn measureText(self: *Factory, text: []const u8, style: TextStyle, max_width: f32) Size {
        var s = style;
        s.ellipsis = false;
        const ref = self.layout(text, s, max_width, 100_000) orelse return .{ .width = 0, .height = 0 };
        defer ref.deinit();
        const metrics = ref.metrics() orelse return .{ .width = 0, .height = 0 };
        return .{ .width = metrics.width_including_trailing_whitespace, .height = metrics.height };
    }

    /// `measureText` rounded up to whole device pixels at `scale`, so
    /// boxes sized from it never cut the last pixel column of the text.
    pub fn measureTextCeil(self: *Factory, text: []const u8, style: TextStyle, max_width: f32, scale: f32) Size {
        const s = self.measureText(text, style, max_width);
        return .{ .width = ceilValue(s.width, scale), .height = ceilValue(s.height, scale) };
    }

    /// The number of laid-out texts in the cache.
    pub fn cachedLayouts(self: *const Factory) usize {
        return self.text_cache.count();
    }
};

/// A laid-out text: from the cache (`entry`, not released) or not.
const LayoutRef = struct {
    layout: *IDWriteTextLayout,
    entry: ?*CachedLayout,

    fn deinit(self: LayoutRef) void {
        if (self.entry == null) release(self.layout);
    }

    fn metrics(self: LayoutRef) ?TextMetrics {
        if (self.entry) |entry| if (entry.metrics) |m| return m;
        var m: TextMetrics = undefined;
        if (!succeeded(self.layout.vtable.GetMetrics(self.layout, &m))) return null;
        if (self.entry) |entry| entry.metrics = m;
        return m;
    }
};

// -----------------------------------------------------------------------
// Text layouts kept by the caller
// -----------------------------------------------------------------------

/// A range of a `TextLayout` (UTF-16 code units) drawn differently.
pub const LayoutRun = struct {
    start: u32,
    len: u32,
    /// Draw the range in this color instead of the default one.
    color: ?Color = null,
    weight: ?FontWeight = null,
    underline: bool = false,
};

/// A range of UTF-8 text (bytes) drawn differently by `drawTextRuns`.
pub const TextRun = struct {
    start: usize,
    len: usize,
    color: ?Color = null,
    weight: ?FontWeight = null,
    underline: bool = false,
};

/// A laid-out UTF-16 text the caller keeps (a text input lays its text out
/// once per change): measure it, hit-test points, find caret positions and
/// cluster stops, draw it with `Canvas.drawLayout`. Positions are UTF-16
/// code units from the start of the text.
pub const TextLayout = struct {
    ptr: *IDWriteTextLayout,
    /// The length of the text in code units.
    len: u32,
    weight: FontWeight,

    pub fn initUtf16(factory: *Factory, text: []const u16, style: TextStyle, max_w: f32, max_h: f32) ?TextLayout {
        const l = factory.createLayout16(text, style, max_w, max_h) orelse return null;
        return .{ .ptr = l, .len = @intCast(text.len), .weight = style.weight };
    }

    /// Own a reference to the factory's bounded text cache. Callers only read
    /// the base layout; Canvas.drawLayout restores its temporary run effects.
    /// The reference remains valid if the cache evicts its own reference.
    pub fn initUtf8(factory: *Factory, text: []const u8, style: TextStyle, max_w: f32, max_h: f32) ?TextLayout {
        const ref = factory.layout(text, style, max_w, max_h) orelse return null;
        defer ref.deinit();
        const unknown: *const *const IUnknownVtbl = @ptrCast(@alignCast(ref.layout));
        _ = unknown.*.AddRef(@ptrCast(ref.layout));
        return .{ .ptr = ref.layout, .len = @intCast(wstr.utf16Len(text)), .weight = style.weight };
    }

    pub fn deinit(self: *TextLayout) void {
        release(self.ptr);
        self.* = undefined;
    }

    /// The size of the text, trailing whitespace included.
    pub fn size(self: *const TextLayout) Size {
        var m: TextMetrics = undefined;
        if (!succeeded(self.ptr.vtable.GetMetrics(self.ptr, &m))) return .{ .width = 0, .height = 0 };
        return .{ .width = m.width_including_trailing_whitespace, .height = m.height };
    }

    pub const Hit = struct {
        /// The caret position closest to the point.
        position: u32,
        /// Whether the point is on the text.
        inside: bool,
    };

    /// The caret position for a point relative to the layout origin.
    pub fn hitTest(self: *const TextLayout, x: f32, y: f32) Hit {
        var trailing: BOOL = 0;
        var inside: BOOL = 0;
        var m: HitTestMetrics = undefined;
        if (!succeeded(self.ptr.vtable.HitTestPoint(self.ptr, x, y, &trailing, &inside, &m)))
            return .{ .position = 0, .inside = false };
        const pos = m.text_position + if (trailing != 0) m.length else 0;
        return .{ .position = @min(pos, self.len), .inside = inside != 0 };
    }

    /// The x of the caret before code unit `position` (after the text at
    /// its end), relative to the layout origin.
    pub fn caretX(self: *const TextLayout, position: u32) f32 {
        if (self.len == 0) return 0;
        var x: f32 = 0;
        var y: f32 = 0;
        var m: HitTestMetrics = undefined;
        const at_end = position >= self.len;
        const pos = if (at_end) self.len - 1 else position;
        if (!succeeded(self.ptr.vtable.HitTestTextPosition(self.ptr, pos, @intFromBool(at_end), &x, &y, &m))) return 0;
        return x;
    }

    /// The grapheme cluster stops of the text: 0, the end of each cluster,
    /// the last one `len` (see `text_edit.handleKey`).
    pub fn clusterStops(self: *const TextLayout, alloc: Allocator, out: *std.ArrayList(u32)) Allocator.Error!void {
        out.clearRetainingCapacity();
        var stack: [256]ClusterMetrics = undefined;
        var heap: ?[]ClusterMetrics = null;
        defer if (heap) |h| alloc.free(h);
        var actual: u32 = 0;
        var clusters: []ClusterMetrics = &stack;
        var hr = self.ptr.vtable.GetClusterMetrics(self.ptr, &stack, stack.len, &actual);
        if (hr == E_NOT_SUFFICIENT_BUFFER) {
            heap = try alloc.alloc(ClusterMetrics, actual);
            clusters = heap.?;
            hr = self.ptr.vtable.GetClusterMetrics(self.ptr, clusters.ptr, actual, &actual);
        }
        if (!succeeded(hr)) return;
        try out.ensureTotalCapacity(alloc, actual + 1);
        var pos: u32 = 0;
        out.appendAssumeCapacity(0);
        for (clusters[0..actual]) |cluster| {
            pos += cluster.length;
            out.appendAssumeCapacity(pos);
        }
    }
};

// -----------------------------------------------------------------------
// Middle ellipsis
// -----------------------------------------------------------------------

const ellipsis_text = "\u{2026}";

/// `text` fitted into `max_w` with "…" in the middle when it is too wide:
/// its start and as much as possible of its end, keeping the whole last
/// path component ("C:\Users\…\config.ghostty") when that fits. It cuts
/// between characters (`text_edit.nextCharUtf8`), so an accent stays with
/// its letter and an emoji sequence stays whole. `measure` returns the
/// width of a string; the result lives in `buf` or is `text`.
pub fn middleEllipsis(
    buf: []u8,
    text: []const u8,
    max_w: f32,
    ctx: anytype,
    comptime measure: fn (@TypeOf(ctx), []const u8) f32,
) []const u8 {
    if (measure(ctx, text) <= max_w) return text;

    // Character starts, enough for any path the UI shows.
    var starts_buf: [512]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < starts_buf.len) {
        starts_buf[n] = i;
        n += 1;
        i = text_edit.nextCharUtf8(text, i);
    }
    if (i < text.len) return text;
    const starts = starts_buf[0..n];

    const Fit = struct {
        /// The byte offset of character `k` (the end for `k` past the last).
        fn at(chars: []const usize, src: []const u8, k: usize) usize {
            return if (k < chars.len) chars[k] else src.len;
        }

        fn compose(out: []u8, src: []const u8, head_end: usize, tail_start: usize) ?[]const u8 {
            const len = head_end + ellipsis_text.len + (src.len - tail_start);
            if (len > out.len) return null;
            @memcpy(out[0..head_end], src[0..head_end]);
            @memcpy(out[head_end..][0..ellipsis_text.len], ellipsis_text);
            @memcpy(out[head_end + ellipsis_text.len ..][0 .. src.len - tail_start], src[tail_start..]);
            return out[0..len];
        }
    };

    // Keep the last path component and as much of the start as fits.
    if (std.mem.findLastAny(u8, text, "\\/")) |sep| if (sep > 0) {
        if (Fit.compose(buf, text, 0, sep)) |only_tail| if (measure(ctx, only_tail) <= max_w) {
            // The most characters of the head before `sep` that fit.
            var lo: usize = 0;
            var hi: usize = 0;
            while (hi < starts.len and starts[hi] < sep) hi += 1;
            while (lo < hi) {
                const mid = (lo + hi + 1) / 2;
                const candidate = Fit.compose(buf, text, Fit.at(starts, text, mid), sep) orelse break;
                if (measure(ctx, candidate) <= max_w) lo = mid else hi = mid - 1;
            }
            return Fit.compose(buf, text, Fit.at(starts, text, lo), sep).?;
        };
    };

    // Otherwise keep the same number of characters at both ends.
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        const head = (mid + 1) / 2;
        const tail = mid / 2;
        const candidate = Fit.compose(buf, text, Fit.at(starts, text, head), Fit.at(starts, text, starts.len - tail)) orelse {
            hi = mid - 1;
            continue;
        };
        if (measure(ctx, candidate) <= max_w) lo = mid else hi = mid - 1;
    }
    const head = (lo + 1) / 2;
    const tail = lo / 2;
    return Fit.compose(buf, text, Fit.at(starts, text, head), Fit.at(starts, text, starts.len - tail)) orelse ellipsis_text;
}

// -----------------------------------------------------------------------
// Canvas
// -----------------------------------------------------------------------

/// A path built from lines, arcs and curves; fill or stroke it with the
/// canvas that created it.
pub const Path = struct {
    geometry: *ID2D1PathGeometry,
    sink: ?*ID2D1GeometrySink,
    finished: bool = false,

    pub fn setFillMode(self: *Path, mode: enum { nonzero, evenodd }) void {
        const sink = self.sink orelse return;
        sink.vtable.SetFillMode(sink, if (mode == .nonzero) 1 else 0);
    }

    pub fn beginFigure(self: *Path, start: Point) void {
        const sink = self.sink orelse return;
        sink.vtable.BeginFigure(sink, start, D2D1_FIGURE_BEGIN_FILLED);
    }

    pub fn endFigure(self: *Path, closed: bool) void {
        const sink = self.sink orelse return;
        sink.vtable.EndFigure(sink, if (closed) D2D1_FIGURE_END_CLOSED else D2D1_FIGURE_END_OPEN);
    }

    pub fn finish(self: *Path) bool {
        const sink = self.sink orelse return self.finished;
        self.finished = succeeded(sink.vtable.Close(sink));
        release(sink);
        self.sink = null;
        return self.finished;
    }

    pub fn lineTo(self: *Path, p: Point) void {
        const sink = self.sink orelse return;
        sink.vtable.AddLine(sink, p);
    }

    /// A circular arc to `p` with radius `r`.
    pub fn arcTo(self: *Path, p: Point, r: f32, clockwise: bool) void {
        const sink = self.sink orelse return;
        sink.vtable.AddArc(sink, &.{
            .point = p,
            .size = .{ .width = r, .height = r },
            .rotation_angle = 0,
            .sweep_direction = if (clockwise) 1 else 0,
            .arc_size = 0,
        });
    }

    pub fn bezierTo(self: *Path, c1: Point, c2: Point, p: Point) void {
        const sink = self.sink orelse return;
        sink.vtable.AddBezier(sink, &.{ .point1 = c1, .point2 = c2, .point3 = p });
    }

    /// Finish the figure (closing it back to its start when `closed`).
    pub fn end(self: *Path, closed: bool) void {
        self.endFigure(closed);
        _ = self.finish();
    }

    pub fn deinit(self: *Path) void {
        if (self.sink) |sink| {
            _ = sink.vtable.Close(sink);
            release(sink);
        }
        release(self.geometry);
    }
};

/// How a frame ended (`Canvas.finish`).
pub const EndResult = enum {
    /// Drawn and presented.
    ok,
    /// The device was lost: the target is gone; paint again to draw on a
    /// new one.
    recreate,
    /// Drawing failed for another reason (logged once per canvas).
    failed,
};

fn endResultOf(hr: HRESULT) EndResult {
    if (hr == D2DERR_RECREATE_TARGET) return .recreate;
    if (!succeeded(hr)) return .failed;
    return .ok;
}

fn borrowedTransform(offset: w32.POINT, dpi: f32) Matrix3x2 {
    return .{ .dx = @as(f32, @floatFromInt(offset.x)) * 96 / dpi, .dy = @as(f32, @floatFromInt(offset.y)) * 96 / dpi };
}

test "DComp atlas offset is converted from physical pixels to canvas DIPs" {
    const transform = borrowedTransform(.{ .x = 30, .y = -15 }, 144);
    try std.testing.expectEqual(@as(f32, 20), transform.dx);
    try std.testing.expectEqual(@as(f32, -10), transform.dy);
}

test "DComp borrowed canvas leaves the native draw transaction to its owner" {
    const factory = try Factory.create(std.testing.allocator);
    defer factory.destroy();
    var canvas = Canvas.init(factory);
    defer canvas.deinit();
    const software = canvas.createDcTarget(D2D1_RENDER_TARGET_TYPE_SOFTWARE, true, 96) orelse return error.SoftwareD2DUnavailable;
    defer release(software);
    var output: DibTarget = .{};
    defer output.deinit();
    const dc = output.ensure(null, 32, 32) orelse return error.CreateDibFailed;
    try std.testing.expect(succeeded(software.vtable.BindDC(software, dc, &.{ .left = 0, .top = 0, .right = 32, .bottom = 32 })));
    const rt: *ID2D1RenderTarget = @ptrCast(software);
    rt.vtable.BeginDraw(rt);
    try std.testing.expect(canvas.beginBorrowed(rt, .{ .width = 32, .height = 32 }, 144, .{ .x = 3, .y = 6 }));
    canvas.clear(Color.black.withAlpha(0));
    canvas.fillRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .white);
    var transform: Matrix3x2 = undefined;
    rt.vtable.GetTransform(rt, &transform);
    try std.testing.expectEqual(@as(f32, 2), transform.dx);
    try std.testing.expectEqual(@as(f32, 4), transform.dy);
    // Accidentally using the owned finish API must not call native EndDraw.
    try std.testing.expectEqual(EndResult.failed, canvas.finish());
    canvas.finishBorrowed();
    try std.testing.expect(!canvas.hasTarget() and !canvas.drawing and canvas.brush == null);
    try std.testing.expect(succeeded(rt.vtable.EndDraw(rt, null, null)));
}

/// Draws on one render target in DIPs. Create it with the app's
/// `Factory`, call `beginHwnd` (or `beginDc`) / draw / `finish` (or `end`)
/// from the paint handler and `deinit` when the target window goes away.
pub const Canvas = struct {
    factory: *Factory,
    target: Target = .none,
    brush: ?*ID2D1SolidColorBrush = null,
    /// Brushes of `drawLayout` runs with their own color.
    run_brushes: [max_run_colors]?*ID2D1SolidColorBrush = @splat(null),
    /// Pixel size and DPI of the current HWND target.
    pixel_size: SizeU = .{ .width = 0, .height = 0 },
    dpi: f32 = 96,
    drawing: bool = false,
    /// Whether the DC target keeps per-pixel alpha (`beginDcAlpha`).
    dc_alpha: bool = false,
    dib_stage: DibTarget = .{},
    dib_output: ?*DibTarget = null,
    dib_result: EndResult = .ok,
    replacement: ?u32 = null,
    clips: [16]Rect = undefined,
    clip_len: usize = 0,
    /// Whether a failure was logged already.
    warned: bool = false,

    /// Distinct run colors one `drawLayout` call can use.
    pub const max_run_colors = 4;

    const Target = union(enum) {
        none,
        hwnd: *ID2D1HwndRenderTarget,
        dc: *ID2D1DCRenderTarget,
        borrowed: *ID2D1RenderTarget,
    };

    pub fn init(factory: *Factory) Canvas {
        return .{ .factory = factory };
    }

    pub fn deinit(self: *Canvas) void {
        self.discardTarget();
        self.dib_stage.deinit();
    }

    fn renderTarget(self: *Canvas) ?*ID2D1RenderTarget {
        if (self.dib_output != null and self.dib_result != .ok) return null;
        return switch (self.target) {
            .none => null,
            .hwnd => |rt| @ptrCast(rt),
            .dc => |rt| @ptrCast(rt),
            .borrowed => |rt| rt,
        };
    }

    /// Release the render target and its resources; the next begin
    /// recreates them (after D2DERR_RECREATE_TARGET, or to free a hidden
    /// popup's target).
    pub fn discardTarget(self: *Canvas) void {
        if (self.brush) |b| release(b);
        self.brush = null;
        for (&self.run_brushes) |*slot| {
            if (slot.*) |b| release(b);
            slot.* = null;
        }
        switch (self.target) {
            .none => {},
            .hwnd => |rt| release(rt),
            .dc => |rt| release(rt),
            .borrowed => {},
        }
        self.target = .none;
    }

    /// DirectComposition owns this BeginDraw/EndDraw pair. Never AddRef,
    /// BeginDraw or EndDraw the borrowed device context; brushes live only for
    /// this draw, so neither a returned atlas context nor a device generation
    /// leaks into a later frame or the legacy raster cache.
    pub fn beginBorrowed(self: *Canvas, context: *anyopaque, pixels: SizeU, dpi: u32, offset: w32.POINT) bool {
        if (self.drawing or self.dib_output != null or dpi == 0) return false;
        self.discardTarget();
        const rt: *ID2D1RenderTarget = @ptrCast(@alignCast(context));
        self.target = .{ .borrowed = rt };
        self.pixel_size = pixels;
        self.dpi = @floatFromInt(dpi);
        rt.vtable.SetDpi(rt, self.dpi, self.dpi);
        var brush: ?*ID2D1SolidColorBrush = null;
        if (!succeeded(rt.vtable.CreateSolidColorBrush(rt, &Color.black, null, &brush)) or brush == null) {
            self.discardTarget();
            return false;
        }
        self.brush = brush;
        rt.vtable.SetTransform(rt, &borrowedTransform(offset, self.dpi));
        rt.vtable.SetAntialiasMode(rt, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        rt.vtable.SetTextAntialiasMode(rt, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        self.drawing = true;
        return true;
    }

    pub fn finishBorrowed(self: *Canvas) void {
        std.debug.assert(self.target == .borrowed);
        self.drawing = false;
        self.discardTarget();
    }

    /// Whether the canvas holds a render target.
    pub fn hasTarget(self: *const Canvas) bool {
        return self.target != .none;
    }

    fn warnOnce(self: *Canvas, comptime fmt: []const u8, args: anytype) void {
        if (self.warned) return;
        self.warned = true;
        log.warn(fmt, args);
    }

    /// Begin drawing into the client area of `hwnd` (`dpi` from
    /// GetDpiForWindow). Returns false when there is nothing to draw on.
    pub fn beginHwnd(self: *Canvas, hwnd: w32.HWND, dpi: u32) bool {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return false;
        const client_size: SizeU = .{
            .width = @intCast(@max(client.right - client.left, 1)),
            .height = @intCast(@max(client.bottom - client.top, 1)),
        };
        const dpi_f: f32 = @floatFromInt(if (dpi == 0) 96 else dpi);

        if (self.target == .dc or self.target == .borrowed) self.discardTarget();
        if (self.target == .hwnd) {
            const rt = self.target.hwnd;
            if (client_size.width != self.pixel_size.width or client_size.height != self.pixel_size.height) {
                if (succeeded(rt.vtable.Resize(rt, &client_size))) {
                    self.pixel_size = client_size;
                } else {
                    self.discardTarget();
                }
            }
        }
        if (self.target == .none) {
            var rt: ?*ID2D1HwndRenderTarget = null;
            const props: RenderTargetProperties = .{
                .pixel_format = .{ .format = DXGI_FORMAT_B8G8R8A8_UNORM, .alpha_mode = D2D1_ALPHA_MODE_PREMULTIPLIED },
                .dpi_x = dpi_f,
                .dpi_y = dpi_f,
            };
            // Present without waiting for the vertical blank: DWM composes
            // the popup anyway, and waiting would block the GUI thread.
            const hwnd_props: HwndRenderTargetProperties = .{
                .hwnd = hwnd,
                .pixel_size = client_size,
                .present_options = D2D1_PRESENT_OPTIONS_IMMEDIATELY,
            };
            if (!succeeded(self.factory.d2d.vtable.CreateHwndRenderTarget(self.factory.d2d, &props, &hwnd_props, &rt))) {
                self.warnOnce("CreateHwndRenderTarget failed", .{});
                return false;
            }
            self.target = .{ .hwnd = rt orelse return false };
            self.pixel_size = client_size;
            self.dpi = dpi_f;
        } else if (dpi_f != self.dpi) {
            const rt = self.target.hwnd;
            rt.vtable.render_target.SetDpi(@ptrCast(rt), dpi_f, dpi_f);
            self.dpi = dpi_f;
        }
        return self.beginDraw();
    }

    /// Begin drawing into `rect` (pixels) of a GDI device context, e.g.
    /// the memory DC of a double-buffered WM_PAINT (see `DibTarget`).
    pub fn beginDc(self: *Canvas, hdc: w32.HDC, rect: w32.RECT, dpi: u32) bool {
        return self.beginDcMode(hdc, rect, dpi, false);
    }

    /// Like `beginDc`, but keeps per-pixel alpha (premultiplied) so the
    /// result can be blitted over a DWM backdrop. `hdc` must have a 32bpp
    /// DIB section selected.
    pub fn beginDcAlpha(self: *Canvas, hdc: w32.HDC, rect: w32.RECT, dpi: u32) bool {
        return self.beginDcMode(hdc, rect, dpi, true);
    }

    /// D2D rasterizes masks and glyphs into a separate alpha DIB. The caller
    /// owns `output` until `finish`; only this GUI thread may access its bits.
    pub fn beginDib(self: *Canvas, output: *DibTarget, size_px: SizeU, dpi: u32) bool {
        std.debug.assert(!self.drawing and self.dib_output == null);
        const w: i32 = @intCast(size_px.width);
        const h: i32 = @intCast(size_px.height);
        if (w <= 0 or h <= 0 or w > output.width or h > output.height or output.bits == null) return false;
        if (GdiFlush() == 0) return false;
        const dc = self.dib_stage.ensure(output.dc, w, h) orelse return false;
        if (!self.beginDcAlpha(dc, .{ .left = 0, .top = 0, .right = w, .bottom = h }, dpi)) return false;
        self.dib_output = output;
        self.dib_result = .ok;
        self.replacement = null;
        self.clip_len = 0;
        const rt = self.renderTarget().?;
        rt.vtable.Clear(rt, &Color.black.withAlpha(0));
        return true;
    }

    pub fn beginReplacement(self: *Canvas, pixel: u32) bool {
        std.debug.assert(self.dib_output != null and self.replacement == null);
        if (!self.commitDib(null, true)) return false;
        self.replacement = pixel;
        return true;
    }

    pub fn endReplacement(self: *Canvas) void {
        const pixel = self.replacement orelse return;
        self.replacement = null;
        _ = self.commitDib(pixel, true);
    }

    fn commitDib(self: *Canvas, replacement: ?u32, restart: bool) bool {
        const output = self.dib_output orelse return false;
        if (self.dib_result != .ok) return false;
        const rt = self.renderTarget() orelse return false;
        for (0..self.clip_len) |_| rt.vtable.PopAxisAlignedClip(rt);
        self.dib_result = self.finishTarget();
        if (self.dib_result != .ok) return false;
        // EndDraw copies the software target to the DC; GDI must finish all
        // queued access to both DIBs before the CPU reads or writes them.
        if (GdiFlush() == 0) {
            self.dib_result = .failed;
            return false;
        }
        const alpha = @import("../chrome/alpha.zig");
        const source: [*]const u32 = @ptrCast(@alignCast(self.dib_stage.bits.?));
        const dest: [*]u32 = @ptrCast(@alignCast(output.bits.?));
        const src_stride: usize = @intCast(self.dib_stage.width);
        const dst_stride: usize = @intCast(output.width);
        for (0..self.pixel_size.height) |y| {
            for (0..self.pixel_size.width) |x| {
                const top = source[y * src_stride + x];
                const pixel = &dest[y * dst_stride + x];
                pixel.* = if (replacement) |value| alpha.replace(pixel.*, value, top >> 24) else alpha.over(pixel.*, top);
            }
        }
        if (!restart) return true;
        if (!self.beginDraw()) {
            self.dib_result = .failed;
            return false;
        }
        const next = self.renderTarget().?;
        next.vtable.Clear(next, &Color.black.withAlpha(0));
        for (self.clips[0..self.clip_len]) |clip| next.vtable.PushAxisAlignedClip(next, &clip.d2d(), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        return true;
    }

    fn beginDcMode(self: *Canvas, hdc: w32.HDC, rect: w32.RECT, dpi: u32, alpha: bool) bool {
        const dpi_f: f32 = @floatFromInt(if (dpi == 0) 96 else dpi);
        if (self.target == .hwnd or self.target == .borrowed or (self.target == .dc and self.dc_alpha != alpha)) self.discardTarget();
        if (self.target == .none) {
            // The pixels go back to GDI, so render in software: a hardware
            // target would only add a device and a read-back.
            const rt = self.createDcTarget(D2D1_RENDER_TARGET_TYPE_SOFTWARE, alpha, dpi_f) orelse
                self.createDcTarget(D2D1_RENDER_TARGET_TYPE_DEFAULT, alpha, dpi_f) orelse
                {
                    self.warnOnce("CreateDCRenderTarget failed", .{});
                    return false;
                };
            self.target = .{ .dc = rt };
            self.dc_alpha = alpha;
            self.dpi = dpi_f;
        }
        const rt = self.target.dc;
        if (dpi_f != self.dpi) {
            rt.vtable.render_target.SetDpi(@ptrCast(rt), dpi_f, dpi_f);
            self.dpi = dpi_f;
        }
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w > 0 and h > 0) self.pixel_size = .{ .width = @intCast(w), .height = @intCast(h) };
        if (!succeeded(rt.vtable.BindDC(rt, hdc, &rect))) return false;
        return self.beginDraw();
    }

    fn createDcTarget(self: *Canvas, kind: u32, alpha: bool, dpi: f32) ?*ID2D1DCRenderTarget {
        var rt: ?*ID2D1DCRenderTarget = null;
        const props: RenderTargetProperties = .{
            .type = kind,
            .pixel_format = .{
                .format = DXGI_FORMAT_B8G8R8A8_UNORM,
                .alpha_mode = if (alpha) D2D1_ALPHA_MODE_PREMULTIPLIED else D2D1_ALPHA_MODE_IGNORE,
            },
            .dpi_x = dpi,
            .dpi_y = dpi,
        };
        if (!succeeded(self.factory.d2d.vtable.CreateDCRenderTarget(self.factory.d2d, &props, &rt))) return null;
        return rt;
    }

    fn beginDraw(self: *Canvas) bool {
        const rt = self.renderTarget() orelse return false;
        if (self.brush == null) {
            var brush: ?*ID2D1SolidColorBrush = null;
            if (!succeeded(rt.vtable.CreateSolidColorBrush(rt, &.{ .r = 0, .g = 0, .b = 0 }, null, &brush))) {
                self.discardTarget();
                return false;
            }
            self.brush = brush;
        }
        rt.vtable.BeginDraw(rt);
        rt.vtable.SetTransform(rt, &.{});
        rt.vtable.SetAntialiasMode(rt, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        rt.vtable.SetTextAntialiasMode(rt, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        self.drawing = true;
        return true;
    }

    /// Finish drawing and report how it went: on `.recreate` the target is
    /// discarded, and the caller paints again (invalidates) to draw on a
    /// new one.
    pub fn finish(self: *Canvas) EndResult {
        if (self.dib_output != null) {
            std.debug.assert(self.replacement == null);
            _ = self.commitDib(null, false);
            self.dib_output = null;
            self.clip_len = 0;
            return self.dib_result;
        }
        return self.finishTarget();
    }

    fn finishTarget(self: *Canvas) EndResult {
        // The surface owner must finish the DComp transaction instead.
        if (self.target == .borrowed) return .failed;
        if (!self.drawing) return .ok;
        self.drawing = false;
        const rt = self.renderTarget() orelse return .failed;
        const hr = rt.vtable.EndDraw(rt, null, null);
        const result = endResultOf(hr);
        switch (result) {
            .ok => {},
            .recreate => self.discardTarget(),
            .failed => self.warnOnce("EndDraw failed hr=0x{x}", .{@as(u32, @bitCast(hr))}),
        }
        return result;
    }

    /// Finish drawing (see `finish`); the next begin recreates a lost
    /// target.
    pub fn end(self: *Canvas) void {
        _ = self.finish();
    }

    /// The size of the current target in DIPs.
    pub fn size(self: *const Canvas) Size {
        const s = self.scale();
        return .{
            .width = @as(f32, @floatFromInt(self.pixel_size.width)) / s,
            .height = @as(f32, @floatFromInt(self.pixel_size.height)) / s,
        };
    }

    /// The scale (DPI / 96) the canvas draws at.
    pub fn scale(self: *const Canvas) f32 {
        return self.dpi / 96.0;
    }

    /// `v` (DIPs) on the nearest device pixel.
    pub fn snap(self: *const Canvas, v: f32) f32 {
        return snapValue(v, self.scale());
    }

    /// `rect` with its edges on device pixels.
    pub fn snapRect(self: *const Canvas, rect: Rect) Rect {
        return snapRectTo(rect, self.scale());
    }

    /// One device pixel in DIPs: the width of a hairline.
    pub fn hairline(self: *const Canvas) f32 {
        return 1.0 / self.scale();
    }

    fn brushFor(self: *Canvas, color: Color) ?*ID2D1SolidColorBrush {
        const brush = self.brush orelse return null;
        brush.vtable.SetColor(brush, &color);
        return brush;
    }

    pub fn clear(self: *Canvas, color: Color) void {
        if (self.dib_output != null) {
            if (!self.beginReplacement(colorPixel(color))) return;
            const rt = self.renderTarget().?;
            rt.vtable.Clear(rt, &Color.white);
            self.endReplacement();
            return;
        }
        const rt = self.renderTarget() orelse return;
        rt.vtable.Clear(rt, &color);
    }

    pub fn fillRect(self: *Canvas, rect: Rect, color: Color) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.FillRectangle(rt, &rect.d2d(), brush);
    }

    /// Copy a top-down BGRA frame while the caller holds its read lease. D2D
    /// owns the uploaded bytes before this returns, so no mapping is retained.
    /// The bitmap belongs to this target and is released before a target reset.
    pub fn drawBgra(self: *Canvas, pixels: []const u8, width: u32, height: u32, stride: u32, rect: Rect) bool {
        const layout = @import("../../../gx/remote_view.zig").Layout.checked(width, height, stride) catch return false;
        const required = std.math.mul(usize, stride, height) catch return false;
        _ = layout;
        if (!self.drawing or pixels.len != required) return false;
        const rt = self.renderTarget() orelse return false;
        const properties: BitmapProperties = .{
            .pixel_format = .{ .format = 87, .alpha_mode = 3 }, // BGRA8, opaque terminal frame.
            .dpi_x = 96,
            .dpi_y = 96,
        };
        var bitmap: ?*ID2D1Bitmap = null;
        if (!succeeded(rt.vtable.CreateBitmap(rt, .{ .width = width, .height = height }, pixels.ptr, stride, &properties, &bitmap))) return false;
        const owned = bitmap orelse return false;
        defer _ = owned.vtable.unknown.Release(@ptrCast(owned));
        rt.vtable.DrawBitmap(rt, owned, &rect.d2d(), 1, 0, null);
        return true;
    }

    pub fn fillRoundedRect(self: *Canvas, rect: Rect, radius: f32, color: Color) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.FillRoundedRectangle(rt, &.{ .rect = rect.d2d(), .radius_x = radius, .radius_y = radius }, brush);
    }

    /// Stroke a rounded rectangle with the stroke centered inside `rect`
    /// (so a 1 DIP border stays within the rectangle and its outer edge
    /// follows the corner radius of a fill of `rect`).
    pub fn strokeRoundedRect(self: *Canvas, rect: Rect, radius: f32, color: Color, width: f32) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        const r = rect.inset(width / 2, width / 2);
        const rr = @max(0, radius - width / 2);
        rt.vtable.DrawRoundedRectangle(rt, &.{ .rect = r.d2d(), .radius_x = rr, .radius_y = rr }, brush, width, null);
    }

    /// Stroke a rounded rectangle `width_px` device pixels wide on whole
    /// pixels inside `rect` (snapped): a sharp border at any scale.
    pub fn strokeRoundedRectPx(self: *Canvas, rect: Rect, radius: f32, color: Color, width_px: u32) void {
        const w = @as(f32, @floatFromInt(@max(width_px, 1))) * self.hairline();
        self.strokeRoundedRect(self.snapRect(rect), radius, color, w);
    }

    /// A horizontal hairline of one device pixel at `y` (snapped down to a
    /// pixel row), from `x` for `w` DIPs.
    pub fn hairlineH(self: *Canvas, x: f32, y: f32, w: f32, color: Color) void {
        const s = self.scale();
        const top = @floor(y * s) / s;
        const left = self.snap(x);
        self.fillRect(.{ .x = left, .y = top, .w = @max(0, self.snap(x + w) - left), .h = self.hairline() }, color);
    }

    /// A vertical hairline of one device pixel at `x` (snapped down to a
    /// pixel column), from `y` for `h` DIPs.
    pub fn hairlineV(self: *Canvas, x: f32, y: f32, h: f32, color: Color) void {
        const s = self.scale();
        const left = @floor(x * s) / s;
        const top = self.snap(y);
        self.fillRect(.{ .x = left, .y = top, .w = self.hairline(), .h = @max(0, self.snap(y + h) - top) }, color);
    }

    pub fn drawLine(self: *Canvas, p0: Point, p1: Point, color: Color, width: f32) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.DrawLine(rt, p0, p1, brush, width, null);
    }

    /// Start a path at `start`; finish it with `Path.end`, draw it with
    /// `fillPath`/`strokePath` and release it with `Path.deinit`.
    pub fn beginPath(self: *Canvas, start: Point, filled: bool) ?Path {
        const path = self.factory.createPath() orelse return null;
        path.sink.?.vtable.BeginFigure(path.sink.?, start, if (filled) D2D1_FIGURE_BEGIN_FILLED else 1);
        return path;
    }

    pub fn fillPathTransformed(self: *Canvas, path: *const Path, color: Color, transform: Matrix3x2) bool {
        if (!path.finished) return false;
        const rt = self.renderTarget() orelse return false;
        const brush = self.brushFor(color) orelse return false;
        var previous: Matrix3x2 = undefined;
        rt.vtable.GetTransform(rt, &previous);
        const combined = transform.then(previous);
        rt.vtable.SetTransform(rt, &combined);
        defer rt.vtable.SetTransform(rt, &previous);
        rt.vtable.FillGeometry(rt, path.geometry, brush, null);
        return true;
    }

    pub fn fillPath(self: *Canvas, path: *const Path, color: Color) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.FillGeometry(rt, path.geometry, brush, null);
    }

    pub fn strokePath(self: *Canvas, path: *const Path, color: Color, width: f32) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.DrawGeometry(rt, path.geometry, brush, width, null);
    }

    /// Clip drawing to `rect` until `popClip`.
    pub fn pushClip(self: *Canvas, rect: Rect) void {
        const rt = self.renderTarget() orelse return;
        if (self.dib_output != null) {
            std.debug.assert(self.clip_len < self.clips.len);
            self.clips[self.clip_len] = rect;
            self.clip_len += 1;
        }
        rt.vtable.PushAxisAlignedClip(rt, &rect.d2d(), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    }

    pub fn popClip(self: *Canvas) void {
        const rt = self.renderTarget() orelse return;
        if (self.dib_output != null) {
            std.debug.assert(self.clip_len > 0);
            self.clip_len -= 1;
        }
        rt.vtable.PopAxisAlignedClip(rt);
    }

    fn textOptions(self: *const Canvas) u32 {
        var options: u32 = D2D1_DRAW_TEXT_OPTIONS_CLIP;
        if (self.factory.d2d_1_1) options |= D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
        return options;
    }

    /// Draw UTF-8 `text` inside `rect`, aligned and trimmed per `style`.
    pub fn drawText(self: *Canvas, text: []const u8, rect: Rect, style: TextStyle) void {
        if (text.len == 0) return;
        const rt = self.renderTarget() orelse return;
        const ref = self.factory.layout(text, style, rect.w, rect.h) orelse return;
        defer ref.deinit();
        const brush = self.brushFor(style.color) orelse return;
        rt.vtable.DrawTextLayout(rt, .{ .x = rect.x, .y = rect.y }, ref.layout, brush, self.textOptions());
    }

    /// Draw UTF-8 `text` like `drawText` with some byte ranges in other
    /// colors or weights (e.g. the characters a search matched).
    pub fn drawTextRuns(self: *Canvas, text: []const u8, rect: Rect, style: TextStyle, runs: []const TextRun) void {
        if (text.len == 0) return;
        if (runs.len == 0) return self.drawText(text, rect, style);
        var layout = TextLayout.initUtf8(self.factory, text, style, rect.w, rect.h) orelse return;
        defer layout.deinit();
        var converted: [32]LayoutRun = undefined;
        const n = @min(runs.len, converted.len);
        for (runs[0..n], converted[0..n]) |run, *out| {
            const start = wstr.utf16Index(text, run.start);
            const stop = wstr.utf16Index(text, run.start + run.len);
            out.* = .{
                .start = @intCast(start),
                .len = @intCast(stop - start),
                .color = run.color,
                .weight = run.weight,
                .underline = run.underline,
            };
        }
        self.drawLayout(&layout, .{ .x = rect.x, .y = rect.y }, style.color, converted[0..n]);
    }

    /// Draw UTF-8 `text` in `rect` with an ellipsis in the middle when it
    /// does not fit (`middleEllipsis`), for paths.
    pub fn drawTextMiddle(self: *Canvas, text: []const u8, rect: Rect, style: TextStyle) void {
        const Measure = struct {
            factory: *Factory,
            style: TextStyle,
            fn width(ctx: @This(), s: []const u8) f32 {
                return ctx.factory.measureText(s, ctx.style, 100_000).width;
            }
        };
        var single = style;
        single.wrap = false;
        var buf: [1024]u8 = undefined;
        const fitted = middleEllipsis(&buf, text, rect.w, Measure{ .factory = self.factory, .style = single }, Measure.width);
        self.drawText(fitted, rect, single);
    }

    /// Draw a kept `TextLayout` at `origin` in `color`, with `runs` in
    /// their own colors, weights or underline. The runs apply to this draw
    /// only.
    pub fn drawLayout(self: *Canvas, layout: *const TextLayout, origin: Point, color: Color, runs: []const LayoutRun) void {
        const rt = self.renderTarget() orelse return;
        const l = layout.ptr;
        var colors: [max_run_colors]Color = undefined;
        var used: usize = 0;
        var weighted = false;
        var underlined = false;
        var colored = false;
        for (runs) |run| {
            if (run.len == 0) continue;
            const range: TextRange = .{ .start = run.start, .length = run.len };
            if (run.weight) |w| {
                _ = l.vtable.SetFontWeight(l, @intFromEnum(w), range);
                weighted = true;
            }
            if (run.underline) {
                _ = l.vtable.SetUnderline(l, 1, range);
                underlined = true;
            }
            if (run.color) |c| {
                const b = self.runBrush(&colors, &used, c) orelse continue;
                _ = l.vtable.SetDrawingEffect(l, @ptrCast(b), range);
                colored = true;
            }
        }
        if (self.brushFor(color)) |brush| rt.vtable.DrawTextLayout(rt, origin, l, brush, self.textOptions());
        // Leave the layout as it was: no brush of this target stays in it.
        const all: TextRange = .{ .start = 0, .length = layout.len };
        if (colored) _ = l.vtable.SetDrawingEffect(l, null, all);
        if (weighted) _ = l.vtable.SetFontWeight(l, @intFromEnum(layout.weight), all);
        if (underlined) _ = l.vtable.SetUnderline(l, 0, all);
    }

    /// The brush for run color `color` in this draw: a run brush already
    /// set to it, or the next free one.
    fn runBrush(self: *Canvas, colors: *[max_run_colors]Color, used: *usize, color: Color) ?*ID2D1SolidColorBrush {
        for (colors[0..used.*], 0..) |c, i| {
            if (std.meta.eql(c, color)) return self.run_brushes[i];
        }
        if (used.* == max_run_colors) return null;
        const rt = self.renderTarget() orelse return null;
        const i = used.*;
        if (self.run_brushes[i] == null) {
            var brush: ?*ID2D1SolidColorBrush = null;
            if (!succeeded(rt.vtable.CreateSolidColorBrush(rt, &color, null, &brush))) return null;
            self.run_brushes[i] = brush;
        }
        const brush = self.run_brushes[i] orelse return null;
        brush.vtable.SetColor(brush, &color);
        colors[i] = color;
        used.* += 1;
        return brush;
    }

    /// Measure UTF-8 `text` (see `Factory.measureText`).
    pub fn measureText(self: *Canvas, text: []const u8, style: TextStyle, max_width: f32) Size {
        return self.factory.measureText(text, style, max_width);
    }

    /// Measure UTF-8 `text` rounded up to whole pixels of this canvas.
    pub fn measureTextCeil(self: *Canvas, text: []const u8, style: TextStyle, max_width: f32) Size {
        return self.factory.measureTextCeil(text, style, max_width, self.scale());
    }

    /// Draw an icon glyph of the icon font centered in `rect`.
    pub fn drawIcon(self: *Canvas, glyph: u21, rect: Rect, size_dip: f32, color: Color) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(glyph, &buf) catch return;
        self.drawText(buf[0..len], rect, .{
            .font = .icon,
            .size = size_dip,
            .color = color,
            .align_x = .center,
            .align_y = .center,
            .ellipsis = false,
        });
    }
};

// -----------------------------------------------------------------------
// DIB target
// -----------------------------------------------------------------------

/// A memory DC with a 32bpp top-down DIB section kept between paints, for
/// `Canvas.beginDc`/`beginDcAlpha` and a BitBlt to the window: no new DIB
/// per paint while the size fits.
pub const DibTarget = struct {
    dc: ?w32.HDC = null,
    bitmap: ?w32.HANDLE = null,
    old_bitmap: ?*anyopaque = null,
    /// The pixels (premultiplied BGRA rows, top-down, `width` wide).
    bits: ?*anyopaque = null,
    width: i32 = 0,
    height: i32 = 0,

    /// The memory DC with a DIB of at least `w` × `h` pixels selected,
    /// compatible with `reference`; null on failure. The DIB is kept and
    /// replaced only when it is too small or far too big.
    pub fn ensure(self: *DibTarget, reference: ?w32.HDC, w: i32, h: i32) ?w32.HDC {
        if (w <= 0 or h <= 0) return null;
        if (self.dc) |dc| {
            if (fits(self.width, self.height, w, h)) return dc;
        }
        self.deinit();
        const dc = w32.CreateCompatibleDC(reference) orelse return null;
        const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        var bits: ?*anyopaque = null;
        const bitmap = w32.CreateDIBSection(dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(dc);
            return null;
        };
        self.* = .{
            .dc = dc,
            .bitmap = bitmap,
            .old_bitmap = w32.SelectObject(dc, bitmap),
            .bits = bits,
            .width = w,
            .height = h,
        };
        return dc;
    }

    pub fn deinit(self: *DibTarget) void {
        if (self.dc) |dc| {
            _ = w32.SelectObject(dc, self.old_bitmap);
            _ = w32.DeleteDC(dc);
        }
        if (self.bitmap) |bitmap| _ = w32.DeleteObject(bitmap);
        self.* = .{};
    }

    /// Whether a DIB of `have_w` × `have_h` serves `w` × `h`: big enough,
    /// and not more than four times the area.
    fn fits(have_w: i32, have_h: i32, w: i32, h: i32) bool {
        if (w > have_w or h > have_h) return false;
        const have: i64 = @as(i64, have_w) * have_h;
        const need: i64 = @as(i64, w) * h;
        return have <= 4 * need;
    }
};

/// Segoe Fluent Icons / Segoe MDL2 Assets code points shared by both
/// fonts.
pub const icons = struct {
    pub const add: u21 = 0xE710;
    pub const cancel: u21 = 0xE711;
    pub const chevron_down: u21 = 0xE70D;
    pub const chevron_right: u21 = 0xE76C;
    pub const global_nav: u21 = 0xE700;
    pub const link: u21 = 0xE71B;
    pub const search: u21 = 0xE721;
    pub const settings: u21 = 0xE713;
    pub const keyboard: u21 = 0xE765;
    pub const minimize: u21 = 0xE921;
    pub const maximize: u21 = 0xE922;
    pub const restore: u21 = 0xE923;
    pub const close: u21 = 0xE8BB;
    pub const more: u21 = 0xE712;
    pub const shield: u21 = 0xEA18;
    pub const warning: u21 = 0xE7BA;
    pub const info: u21 = 0xE946;
    pub const completed: u21 = 0xE930;
    pub const error_badge: u21 = 0xE783;
    pub const check_mark: u21 = 0xE73E;
    pub const copy: u21 = 0xE8C8;
};

test "snapValue and snapRectTo put edges on device pixels" {
    const testing = std.testing;
    // 150 %: 1 DIP is 1.5 px; 10.3 DIP = 15.45 px -> 15 px = 10 DIP.
    try testing.expectApproxEqAbs(@as(f32, 10), snapValue(10.3, 1.5), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10.6667), snapValue(10.5, 1.5), 1e-3);
    try testing.expectEqual(@as(f32, 7), snapValue(7.2, 1.0));
    const r = snapRectTo(.{ .x = 0.4, .y = 1.1, .w = 10.3, .h = 0.4 }, 1.25);
    // Each edge is a multiple of 0.8 DIP (one pixel at 125 %).
    for ([_]f32{ r.x, r.y, r.x + r.w, r.y + r.h }) |edge| {
        const px = edge * 1.25;
        try testing.expectApproxEqAbs(@round(px), px, 1e-4);
    }
    try testing.expectApproxEqAbs(@as(f32, 14), ceilValue(13.2, 1.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 13), ceilValue(13.0000001, 1.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20.0 / 1.5), ceilValue(13.2, 1.5), 1e-4);
}

test "endResultOf maps EndDraw results" {
    const testing = std.testing;
    try testing.expectEqual(EndResult.ok, endResultOf(0));
    try testing.expectEqual(EndResult.recreate, endResultOf(D2DERR_RECREATE_TARGET));
    try testing.expectEqual(EndResult.failed, endResultOf(@bitCast(@as(u32, 0x80004005))));
}

test "ChromeAlpha native explicitly software DC and BitBlt preserve linear BGRA" {
    const testing = std.testing;
    const factory = try Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = Canvas.init(factory);
    defer canvas.deinit();
    const software = canvas.createDcTarget(D2D1_RENDER_TARGET_TYPE_SOFTWARE, true, 96) orelse return error.SoftwareD2DUnavailable;
    canvas.target = .{ .dc = software };
    canvas.dc_alpha = true;
    var output: DibTarget = .{};
    defer output.deinit();
    var copied: DibTarget = .{};
    defer copied.deinit();
    const output_dc = output.ensure(null, 32, 16) orelse return error.CreateDibFailed;
    const copied_dc = copied.ensure(null, 32, 16) orelse return error.CreateDibFailed;
    try testing.expect(canvas.beginDib(&output, .{ .width = 32, .height = 16 }, 96));
    canvas.clear(Color.black.withAlpha(0));
    for ([_]u32{ 0x031c1c1c, 0x4d959595 }, 0..) |pixel, i| {
        try testing.expect(canvas.beginReplacement(pixel));
        canvas.fillRect(.{ .x = @as(f32, @floatFromInt(i)) * 16, .y = 0, .w = 16, .h = 16 }, .white);
        canvas.endReplacement();
    }
    try testing.expectEqual(EndResult.ok, canvas.finish());
    try testing.expectEqual(software, canvas.target.dc);
    try testing.expect(w32.BitBlt(copied_dc, 0, 0, 32, 16, output_dc, 0, 0, w32.SRCCOPY) != 0);
    try testing.expect(GdiFlush() != 0);
    const pixels: [*]const u32 = @ptrCast(@alignCast(copied.bits.?));
    for (0..16) |y| {
        for (0..32) |x| try testing.expectEqual(@as(u32, if (x < 16) 0x031c1c1c else 0x4d959595), pixels[y * 32 + x]);
    }
    try testing.expectEqualSlices(u8, &.{ 0x1c, 0x1c, 0x1c, 0x03 }, std.mem.asBytes(&pixels[0]));
    try testing.expectEqualSlices(u8, &.{ 0x95, 0x95, 0x95, 0x4d }, std.mem.asBytes(&pixels[16]));
}

test "P4 styled text reuses bounded layouts and restores plain pixels" {
    const testing = std.testing;
    const factory = try Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = Canvas.init(factory);
    defer canvas.deinit();
    canvas.target = .{ .dc = canvas.createDcTarget(D2D1_RENDER_TARGET_TYPE_SOFTWARE, true, 96) orelse return error.SoftwareD2DUnavailable };
    canvas.dc_alpha = true;
    var output: DibTarget = .{};
    defer output.deinit();
    const pixels_size: SizeU = .{ .width = 256, .height = 48 };
    const rect: Rect = .{ .x = 0, .y = 0, .w = 256, .h = 48 };
    const text = "Menu and shortcuts";
    const text_style: TextStyle = .{ .color = .black, .size = 14 };
    const runs = [_]TextRun{.{ .start = 0, .len = 4, .color = .{ .r = 1, .g = 0, .b = 0 }, .weight = .bold, .underline = true }};
    const before = factory.cachedLayouts();
    _ = output.ensure(null, 256, 48) orelse return error.CreateDibFailed;
    try testing.expect(canvas.beginDib(&output, pixels_size, 96));
    canvas.clear(.white);
    canvas.drawTextRuns(text, rect, text_style, &runs);
    try testing.expectEqual(EndResult.ok, canvas.finish());
    try testing.expect(before + 1 == factory.cachedLayouts());

    try testing.expect(canvas.beginDib(&output, pixels_size, 96));
    canvas.clear(.white);
    canvas.drawText(text, rect, text_style);
    try testing.expectEqual(EndResult.ok, canvas.finish());
    try testing.expect(GdiFlush() != 0);
    const pixels: [*]const u32 = @ptrCast(@alignCast(output.bits.?));
    const plain = try testing.allocator.dupe(u32, pixels[0 .. 256 * 48]);
    defer testing.allocator.free(plain);
    const cached = (factory.layout(text, text_style, rect.w, rect.h) orelse return error.LayoutFailed).layout;
    for (0..100) |_| {
        try testing.expect(canvas.beginDib(&output, pixels_size, 96));
        canvas.clear(.white);
        canvas.drawTextRuns(text, rect, text_style, &runs);
        try testing.expectEqual(EndResult.ok, canvas.finish());
        try testing.expect(canvas.beginDib(&output, pixels_size, 96));
        canvas.clear(.white);
        canvas.drawText(text, rect, text_style);
        try testing.expectEqual(EndResult.ok, canvas.finish());
        try testing.expect(GdiFlush() != 0);
        try testing.expectEqualSlices(u32, plain, pixels[0 .. 256 * 48]);
        try testing.expectEqual(before + 1, factory.cachedLayouts());
        try testing.expectEqual(cached, (factory.layout(text, text_style, rect.w, rect.h) orelse return error.LayoutFailed).layout);
    }
    var held = TextLayout.initUtf8(factory, text, text_style, rect.w, rect.h) orelse return error.LayoutFailed;
    defer held.deinit();
    factory.text_cache.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), factory.cachedLayouts());
    try testing.expect(held.size().width > 0);
    try testing.expect(canvas.beginDib(&output, pixels_size, 96));
    canvas.clear(.white);
    canvas.drawLayout(&held, .{ .x = rect.x, .y = rect.y }, .black, &.{});
    try testing.expectEqual(EndResult.ok, canvas.finish());
    try testing.expect(GdiFlush() != 0);
    try testing.expectEqualSlices(u32, plain, pixels[0 .. 256 * 48]);
}

test "opticalSize follows the Fluent type ramp" {
    const testing = std.testing;
    try testing.expectEqual(OpticalSize.small, opticalSize(10));
    try testing.expectEqual(OpticalSize.small, opticalSize(12));
    try testing.expectEqual(OpticalSize.text, opticalSize(13));
    try testing.expectEqual(OpticalSize.text, opticalSize(14));
    try testing.expectEqual(OpticalSize.text, opticalSize(18));
    try testing.expectEqual(OpticalSize.display, opticalSize(20));
    try testing.expectEqual(OpticalSize.display, opticalSize(28));
}

test "Fluent native evenodd contours preserve holes and restore target transform" {
    const testing = std.testing;
    const factory = try Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = Canvas.init(factory);
    defer canvas.deinit();
    const software = canvas.createDcTarget(D2D1_RENDER_TARGET_TYPE_SOFTWARE, true, 96) orelse return error.SoftwareD2DUnavailable;
    canvas.target = .{ .dc = software };
    canvas.dc_alpha = true;
    var output: DibTarget = .{};
    defer output.deinit();
    _ = output.ensure(null, 48, 48) orelse return error.CreateDibFailed;
    var path = factory.createPath() orelse return error.CreatePathFailed;
    defer path.deinit();
    path.setFillMode(.evenodd);
    for ([_][2]f32{ .{ 0, 12 }, .{ 3, 9 } }) |sides| {
        path.beginFigure(.{ .x = sides[0], .y = sides[0] });
        path.lineTo(.{ .x = sides[1], .y = sides[0] });
        path.lineTo(.{ .x = sides[1], .y = sides[1] });
        path.lineTo(.{ .x = sides[0], .y = sides[1] });
        path.endFigure(true);
    }
    try testing.expect(path.finish());
    try testing.expect(canvas.beginDib(&output, .{ .width = 48, .height = 48 }, 96));
    canvas.clear(Color.black.withAlpha(0));
    const rt = canvas.renderTarget().?;
    const original: Matrix3x2 = .{ .dx = 2, .dy = 3 };
    rt.vtable.SetTransform(rt, &original);
    try testing.expect(canvas.fillPathTransformed(&path, .white, .{ .m11 = 2, .m22 = 2, .dx = 4, .dy = 4 }));
    var restored: Matrix3x2 = undefined;
    rt.vtable.GetTransform(rt, &restored);
    try testing.expectEqualDeep(original, restored);
    try testing.expectEqual(EndResult.ok, canvas.finish());
    const pixels: [*]const u32 = @ptrCast(@alignCast(output.bits.?));
    try testing.expectEqual(@as(u32, 0xffffffff), pixels[9 * 48 + 9]);
    try testing.expectEqual(@as(u32, 0), pixels[19 * 48 + 18]);
    try testing.expectEqual(@as(u32, 0), pixels[40 * 48 + 40]);
}

test "remote BGRA upload owns pixels and preserves padded rows" {
    const testing = std.testing;
    const factory = try Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = Canvas.init(factory);
    defer canvas.deinit();
    const software = canvas.createDcTarget(D2D1_RENDER_TARGET_TYPE_SOFTWARE, true, 96) orelse return error.SoftwareD2DUnavailable;
    canvas.target = .{ .dc = software };
    canvas.dc_alpha = true;
    var output: DibTarget = .{};
    defer output.deinit();
    _ = output.ensure(null, 2, 2) orelse return error.CreateDibFailed;
    try testing.expect(canvas.beginDib(&output, .{ .width = 2, .height = 2 }, 96));
    canvas.clear(.black);
    var source = [_]u32{ 0xffff0000, 0xff00ff00, 0xdeadbeef, 0xff0000ff, 0xffffffff, 0xdeadbeef };
    const rect: Rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 };
    try testing.expect(!canvas.drawBgra(std.mem.asBytes(&source)[0..8], 2, 2, 12, rect));
    try testing.expect(canvas.drawBgra(std.mem.asBytes(&source), 2, 2, 12, rect));
    @memset(&source, 0); // The producer can reuse the slot before EndDraw.
    try testing.expectEqual(EndResult.ok, canvas.finish());
    const pixels: [*]const u32 = @ptrCast(@alignCast(output.bits.?));
    try testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff }, pixels[0..4]);
}

test "cjkFontFor picks the font of the language, then of the region" {
    const testing = std.testing;
    try testing.expectEqual(CjkFont.yahei, cjkFontFor(.zh_CN, "ja-JP"));
    try testing.expectEqual(CjkFont.yu_gothic, cjkFontFor(.en, "ja-JP"));
    try testing.expectEqual(CjkFont.malgun, cjkFontFor(.en, "ko-KR"));
    try testing.expectEqual(CjkFont.jhenghei, cjkFontFor(.en, "zh-TW"));
    try testing.expectEqual(CjkFont.jhenghei, cjkFontFor(.en, "zh-HK"));
    try testing.expectEqual(CjkFont.jhenghei, cjkFontFor(.en, "zh-Hant-SG"));
    try testing.expectEqual(CjkFont.yahei, cjkFontFor(.en, "zh-CN"));
    try testing.expectEqual(CjkFont.yahei, cjkFontFor(.en, "zh-SG"));
    try testing.expectEqual(CjkFont.yahei, cjkFontFor(.en, "en-US"));
    try testing.expectEqual(CjkFont.yahei, cjkFontFor(.en, ""));
    // A language subtag that only starts like one.
    try testing.expectEqual(CjkFont.yahei, cjkFontFor(.en, "jv-ID"));
    try testing.expectEqual(CjkFont.yu_gothic, cjkFontFor(.en, "JA"));
}

test "layoutKey is deterministic and tells styles apart" {
    const testing = std.testing;
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const style: TextStyle = .{ .size = 14 };
    const k1 = layoutKey(&a, "Settings", style, 100, 20).?;
    const k2 = layoutKey(&b, "Settings", style, 100, 20).?;
    try testing.expectEqualSlices(u8, k1, k2);
    var c: [1024]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, k1, layoutKey(&c, "Settings", .{ .size = 12 }, 100, 20).?));
    try testing.expect(!std.mem.eql(u8, k1, layoutKey(&c, "Settings", style, 101, 20).?));
    try testing.expect(!std.mem.eql(u8, k1, layoutKey(&c, "Settings", .{ .size = 14, .weight = .semibold }, 100, 20).?));
    try testing.expect(!std.mem.eql(u8, k1, layoutKey(&c, "Settings", .{ .size = 14, .family = "Consolas" }, 100, 20).?));
    // The family length is part of the key: "ab"+"c" differs from "a"+"bc".
    var d: [1024]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, layoutKey(&c, "c", .{ .family = "ab" }, 1, 1).?, layoutKey(&d, "bc", .{ .family = "a" }, 1, 1).?));
    // Text too long for the buffer is not cached.
    var small: [48]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), layoutKey(&small, "a long piece of text", style, 1, 1));
}

var test_released: usize = 0;

fn testRelease(_: u32) void {
    test_released += 1;
}

test "GenerationalCache keeps recent entries and drops a generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Cache = GenerationalCache(u32, testRelease);
    var cache: Cache = .{ .capacity = 2 };
    defer cache.deinit(alloc);
    test_released = 0;

    _ = cache.put(alloc, "a", 1).?;
    _ = cache.put(alloc, "b", 2).?;
    try testing.expectEqual(@as(usize, 2), cache.count());
    // Young is full: "c" starts a new generation; "a" and "b" are old.
    _ = cache.put(alloc, "c", 3).?;
    try testing.expectEqual(@as(usize, 3), cache.count());
    try testing.expectEqual(@as(usize, 0), test_released);
    // A hit on "a" moves it back to the young generation.
    try testing.expectEqual(@as(u32, 1), cache.get(alloc, "a").?.*);
    // The next put rotates: old ("b") is dropped, young ("c", "a") ages.
    _ = cache.put(alloc, "d", 4).?;
    try testing.expectEqual(@as(usize, 1), test_released);
    try testing.expectEqual(@as(?*u32, null), cache.get(alloc, "b"));
    try testing.expectEqual(@as(u32, 3), cache.get(alloc, "c").?.*);
    try testing.expectEqual(@as(u32, 1), cache.get(alloc, "a").?.*);
    try testing.expectEqual(@as(u32, 4), cache.get(alloc, "d").?.*);
    try testing.expect(cache.count() <= 4);
    cache.clear(alloc);
    try testing.expectEqual(@as(usize, 0), cache.count());
    try testing.expectEqual(@as(usize, 4), test_released);
}

test "middleEllipsis keeps the start and the file name" {
    const testing = std.testing;
    // One unit of width per byte, "…" (3 bytes) counted as 3.
    const Measure = struct {
        fn width(_: void, s: []const u8) f32 {
            return @floatFromInt(s.len);
        }
    };
    var buf: [256]u8 = undefined;
    const path = "C:\\Users\\someone\\AppData\\Local\\ghostty\\config.ghostty";
    try testing.expectEqualStrings(path, middleEllipsis(&buf, path, 100, {}, Measure.width));
    const fitted = middleEllipsis(&buf, path, 30, {}, Measure.width);
    try testing.expect(fitted.len <= 30);
    try testing.expect(std.mem.endsWith(u8, fitted, "\\config.ghostty"));
    try testing.expect(std.mem.startsWith(u8, fitted, "C:\\Use"));
    try testing.expect(std.mem.indexOf(u8, fitted, "\u{2026}") != null);
    // A file name that does not fit alone: both ends kept evenly.
    const name = "a-very-long-file-name-without-separators.txt";
    const short = middleEllipsis(&buf, name, 15, {}, Measure.width);
    try testing.expect(short.len <= 15);
    try testing.expect(std.mem.startsWith(u8, short, "a-ver"));
    try testing.expect(std.mem.endsWith(u8, short, ".txt"));
    // Multi-byte text is cut at codepoints.
    const cjk = "\u{914D}\u{7F6E}\u{6587}\u{4EF6}\u{5939}\\\u{6587}\u{4EF6}.txt";
    const cut = middleEllipsis(&buf, cjk, 20, {}, Measure.width);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(std.mem.endsWith(u8, cut, "\\\u{6587}\u{4EF6}.txt"));
    // Nothing fits: just the ellipsis.
    try testing.expectEqualStrings("\u{2026}", middleEllipsis(&buf, name, 1, {}, Measure.width));

    // Characters stay whole: no accent without its letter, no emoji
    // sequence cut apart.
    const accents = "e\u{301}" ** 12;
    var width: f32 = 4;
    while (width < accents.len) : (width += 1) {
        const fitted_accents = middleEllipsis(&buf, accents, width, {}, Measure.width);
        const sides = std.mem.indexOf(u8, fitted_accents, "\u{2026}").?;
        for ([_][]const u8{ fitted_accents[0..sides], fitted_accents[sides + "\u{2026}".len ..] }) |side| {
            try testing.expectEqual(@as(usize, 0), side.len % "e\u{301}".len);
            try testing.expectEqual(side.len / "e\u{301}".len, std.mem.count(u8, side, "e\u{301}"));
        }
    }
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const families = family ** 3;
    const fitted_families = middleEllipsis(&buf, families, 2 * family.len + 3, {}, Measure.width);
    try testing.expectEqualStrings(family ++ "\u{2026}" ++ family, fitted_families);
}

test "DibTarget reuses a buffer that fits" {
    const testing = std.testing;
    try testing.expect(DibTarget.fits(100, 40, 100, 40));
    try testing.expect(DibTarget.fits(100, 40, 80, 30));
    try testing.expect(!DibTarget.fits(100, 40, 101, 40));
    try testing.expect(!DibTarget.fits(100, 40, 100, 41));
    // Far too big: replaced so a shrunk title bar does not keep 4K pixels.
    try testing.expect(!DibTarget.fits(3840, 80, 800, 80));
}

test {
    @import("../../../lib/compat/testing.zig").refAllDeclsRecursive(@This());
}
