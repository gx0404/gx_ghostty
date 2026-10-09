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
//! resolved UI/icon/monospace font families, the CJK font fallback and a text format
//! cache; the app owns one (`App.uiFactory`). A `Canvas` belongs to one
//! render target (an HWND or a GDI DC) and draws in DIPs: 1 unit = 1 pixel
//! at 96 DPI.
//!
//! All of it is single-threaded and must only be used on the GUI thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const i18n = @import("../../../gx/i18n.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32_d2d);

pub const HRESULT = i32;
pub const GUID = w32.GUID;
pub const BOOL = i32;

/// A placeholder for vtable slots the UI never calls.
const Unused = *const anyopaque;

pub const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// -----------------------------------------------------------------------
// Value types
// -----------------------------------------------------------------------

/// A straight-alpha RGBA color with components in 0..1 (D2D1_COLOR_F).
pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    /// A color from 8-bit sRGB components.
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
        };
    }

    /// A color from 0xRRGGBB.
    pub fn hex(value: u24) Color {
        return rgb(@truncate(value >> 16), @truncate(value >> 8), @truncate(value));
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        var c = self;
        c.a = a;
        return c;
    }

    /// The GDI COLORREF (0x00BBGGRR) of this color, ignoring alpha.
    pub fn colorRef(self: Color) u32 {
        const r: u32 = to8(self.r);
        const g: u32 = to8(self.g);
        const b: u32 = to8(self.b);
        return r | (g << 8) | (b << 16);
    }

    fn to8(v: f32) u8 {
        return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
    }
};

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

const RectF = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const RoundedRect = extern struct { rect: RectF, radius_x: f32, radius_y: f32 };
const Matrix3x2 = extern struct {
    m11: f32 = 1,
    m12: f32 = 0,
    m21: f32 = 0,
    m22: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,
};
const PixelFormat = extern struct { format: u32, alpha_mode: u32 };
const RenderTargetProperties = extern struct {
    type: u32 = 0, // D2D1_RENDER_TARGET_TYPE_DEFAULT
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
        CreateBitmap: Unused,
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
        DrawBitmap: Unused,
        DrawText: Unused,
        DrawTextLayout: *const fn (*ID2D1RenderTarget, Point, *IDWriteTextLayout, *ID2D1SolidColorBrush, u32) callconv(.winapi) void,
        DrawGlyphRun: Unused,
        SetTransform: *const fn (*ID2D1RenderTarget, *const Matrix3x2) callconv(.winapi) void,
        GetTransform: Unused,
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
        SetFillMode: Unused,
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
    SetLineSpacing: Unused,
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
        SetFontWeight: Unused,
        SetFontStyle: Unused,
        SetFontStretch: Unused,
        SetFontSize: Unused,
        SetUnderline: Unused,
        SetStrikethrough: Unused,
        SetDrawingEffect: Unused,
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
        GetClusterMetrics: Unused,
        DetermineMinWidth: Unused,
        HitTestPoint: Unused,
        HitTestTextPosition: Unused,
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

// -----------------------------------------------------------------------
// Factory
// -----------------------------------------------------------------------

/// Which font a text style uses.
pub const FontKind = enum {
    /// The UI font ("Segoe UI Variable Text", else "Segoe UI") with
    /// "Microsoft YaHei UI" for CJK text.
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
};

const FormatKey = struct {
    font: FontKind,
    size: f32,
    weight: FontWeight,
};

const CachedFormat = struct {
    key: FormatKey,
    format: *IDWriteTextFormat,
    ellipsis: ?*anyopaque,
};

/// The process-wide D2D and DirectWrite state of the UI.
pub const Factory = struct {
    alloc: Allocator,
    d2d: *ID2D1Factory,
    /// Whether `d2d` is a Direct2D 1.1 factory (color fonts).
    d2d_1_1: bool,
    dwrite: *IDWriteFactory,
    fallback: ?*IDWriteFontFallback = null,
    ui_family: [:0]const u16,
    icon_family: [:0]const u16,
    mono_family: [:0]const u16,
    formats: std.ArrayList(CachedFormat) = .empty,

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

    pub fn create(alloc: Allocator) !*Factory {
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
            if (hasFamily(collection, L("Segoe UI Variable Text"))) self.ui_family = L("Segoe UI Variable Text");
            if (hasFamily(collection, L("Segoe Fluent Icons"))) self.icon_family = L("Segoe Fluent Icons");
            if (hasFamily(collection, L("Cascadia Mono"))) self.mono_family = L("Cascadia Mono");
        }
        self.fallback = self.createFallback();
        return self;
    }

    pub fn destroy(self: *Factory) void {
        self.flushFormats();
        self.formats.deinit(self.alloc);
        if (self.fallback) |f| release(f);
        release(self.dwrite);
        release(self.d2d);
        self.alloc.destroy(self);
    }

    /// Drop the cached text formats, e.g. after a UI language change
    /// (formats carry the locale).
    pub fn flushFormats(self: *Factory) void {
        for (self.formats.items) |cached| {
            if (cached.ellipsis) |sign| release(sign);
            release(cached.format);
        }
        self.formats.clearRetainingCapacity();
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

    /// A font fallback that maps CJK text to "Microsoft YaHei UI" before
    /// the system fallback. Null before Windows 8.1 (no IDWriteFactory2).
    fn createFallback(self: *Factory) ?*IDWriteFontFallback {
        const factory2: *IDWriteFactory2 = @ptrCast(@alignCast(queryInterface(self.dwrite, &IID_IDWriteFactory2) orelse return null));
        defer release(factory2);

        var builder: ?*IDWriteFontFallbackBuilder = null;
        if (!succeeded(factory2.vtable.CreateFontFallbackBuilder(factory2, &builder))) return null;
        const b = builder orelse return null;
        defer release(b);

        const families = [_][*:0]const u16{L("Microsoft YaHei UI")};
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

    /// The (cached) text format for a font, size and weight.
    fn textFormat(self: *Factory, key: FormatKey) ?*CachedFormat {
        for (self.formats.items) |*cached| {
            if (std.meta.eql(cached.key, key)) return cached;
        }

        const family = switch (key.font) {
            .ui => self.ui_family,
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

        if (key.font != .icon) {
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

        self.formats.append(self.alloc, .{ .key = key, .format = f, .ellipsis = sign }) catch {
            if (sign) |s| release(s);
            release(f);
            return null;
        };
        return &self.formats.items[self.formats.items.len - 1];
    }

    /// Lay out UTF-8 `text` in a box; the caller releases the layout.
    fn layout(self: *Factory, text: []const u8, style: TextStyle, max_w: f32, max_h: f32) ?*IDWriteTextLayout {
        const cached = self.textFormat(.{ .font = style.font, .size = style.size, .weight = style.weight }) orelse return null;

        var stack: [512]u16 = undefined;
        var heap: ?[:0]u16 = null;
        defer if (heap) |h| self.alloc.free(h);
        const text16: []const u16 = if (wstr.utf16Len(text) < stack.len)
            wstr.bufZ(&stack, text)
        else blk: {
            heap = wstr.allocZ(self.alloc, text) catch return null;
            break :blk heap.?;
        };

        var out: ?*IDWriteTextLayout = null;
        if (!succeeded(self.dwrite.vtable.CreateTextLayout(
            self.dwrite,
            text16.ptr,
            @intCast(text16.len),
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
        return l;
    }

    /// Measure UTF-8 `text` laid out with `style`, at most `max_width`
    /// wide.
    pub fn measureText(self: *Factory, text: []const u8, style: TextStyle, max_width: f32) Size {
        var s = style;
        s.ellipsis = false;
        const l = self.layout(text, s, max_width, 100_000) orelse return .{ .width = 0, .height = 0 };
        defer release(l);
        var metrics: TextMetrics = undefined;
        if (!succeeded(l.vtable.GetMetrics(l, &metrics))) return .{ .width = 0, .height = 0 };
        return .{ .width = metrics.width_including_trailing_whitespace, .height = metrics.height };
    }
};

// -----------------------------------------------------------------------
// Canvas
// -----------------------------------------------------------------------

/// A path built from lines, arcs and curves; fill or stroke it with the
/// canvas that created it.
pub const Path = struct {
    geometry: *ID2D1PathGeometry,
    sink: ?*ID2D1GeometrySink,

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
        const sink = self.sink orelse return;
        sink.vtable.EndFigure(sink, if (closed) D2D1_FIGURE_END_CLOSED else D2D1_FIGURE_END_OPEN);
        _ = sink.vtable.Close(sink);
        release(sink);
        self.sink = null;
    }

    pub fn deinit(self: *Path) void {
        if (self.sink) |sink| {
            _ = sink.vtable.Close(sink);
            release(sink);
        }
        release(self.geometry);
    }
};

/// Draws on one render target in DIPs. Create it with the app's
/// `Factory`, call `beginHwnd` (or `beginDc`) / draw / `end` from the
/// paint handler and `deinit` when the target window goes away.
pub const Canvas = struct {
    factory: *Factory,
    target: Target = .none,
    brush: ?*ID2D1SolidColorBrush = null,
    /// Pixel size and DPI of the current HWND target.
    pixel_size: SizeU = .{ .width = 0, .height = 0 },
    dpi: f32 = 96,
    drawing: bool = false,
    /// Whether the DC target keeps per-pixel alpha (`beginDcAlpha`).
    dc_alpha: bool = false,

    const Target = union(enum) {
        none,
        hwnd: *ID2D1HwndRenderTarget,
        dc: *ID2D1DCRenderTarget,
    };

    pub fn init(factory: *Factory) Canvas {
        return .{ .factory = factory };
    }

    pub fn deinit(self: *Canvas) void {
        self.discardTarget();
    }

    fn renderTarget(self: *Canvas) ?*ID2D1RenderTarget {
        return switch (self.target) {
            .none => null,
            .hwnd => |rt| @ptrCast(rt),
            .dc => |rt| @ptrCast(rt),
        };
    }

    /// Release the render target and its resources; the next begin
    /// recreates them (needed after D2DERR_RECREATE_TARGET).
    pub fn discardTarget(self: *Canvas) void {
        if (self.brush) |b| release(b);
        self.brush = null;
        switch (self.target) {
            .none => {},
            .hwnd => |rt| release(rt),
            .dc => |rt| release(rt),
        }
        self.target = .none;
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

        if (self.target == .dc) self.discardTarget();
        if (self.target == .none) {
            var rt: ?*ID2D1HwndRenderTarget = null;
            const props: RenderTargetProperties = .{
                .pixel_format = .{ .format = DXGI_FORMAT_B8G8R8A8_UNORM, .alpha_mode = D2D1_ALPHA_MODE_PREMULTIPLIED },
                .dpi_x = dpi_f,
                .dpi_y = dpi_f,
            };
            const hwnd_props: HwndRenderTargetProperties = .{ .hwnd = hwnd, .pixel_size = client_size };
            if (!succeeded(self.factory.d2d.vtable.CreateHwndRenderTarget(self.factory.d2d, &props, &hwnd_props, &rt))) {
                log.warn("CreateHwndRenderTarget failed", .{});
                return false;
            }
            self.target = .{ .hwnd = rt orelse return false };
            self.pixel_size = client_size;
            self.dpi = dpi_f;
        } else if (self.target == .hwnd) {
            const rt = self.target.hwnd;
            if (client_size.width != self.pixel_size.width or client_size.height != self.pixel_size.height) {
                _ = rt.vtable.Resize(rt, &client_size);
                self.pixel_size = client_size;
            }
            if (dpi_f != self.dpi) {
                rt.vtable.render_target.SetDpi(@ptrCast(rt), dpi_f, dpi_f);
                self.dpi = dpi_f;
            }
        }
        return self.beginDraw();
    }

    /// Begin drawing into `rect` (pixels) of a GDI device context, e.g.
    /// the memory DC of a double-buffered WM_PAINT.
    pub fn beginDc(self: *Canvas, hdc: w32.HDC, rect: w32.RECT, dpi: u32) bool {
        return self.beginDcMode(hdc, rect, dpi, false);
    }

    /// Like `beginDc`, but keeps per-pixel alpha (premultiplied) so the
    /// result can be blitted over a DWM backdrop. `hdc` must have a 32bpp
    /// DIB section selected.
    pub fn beginDcAlpha(self: *Canvas, hdc: w32.HDC, rect: w32.RECT, dpi: u32) bool {
        return self.beginDcMode(hdc, rect, dpi, true);
    }

    fn beginDcMode(self: *Canvas, hdc: w32.HDC, rect: w32.RECT, dpi: u32, alpha: bool) bool {
        const dpi_f: f32 = @floatFromInt(if (dpi == 0) 96 else dpi);
        if (self.target == .hwnd or (self.target == .dc and self.dc_alpha != alpha)) self.discardTarget();
        if (self.target == .none) {
            var rt: ?*ID2D1DCRenderTarget = null;
            const props: RenderTargetProperties = .{
                .pixel_format = .{
                    .format = DXGI_FORMAT_B8G8R8A8_UNORM,
                    .alpha_mode = if (alpha) D2D1_ALPHA_MODE_PREMULTIPLIED else D2D1_ALPHA_MODE_IGNORE,
                },
                .dpi_x = dpi_f,
                .dpi_y = dpi_f,
            };
            if (!succeeded(self.factory.d2d.vtable.CreateDCRenderTarget(self.factory.d2d, &props, &rt))) {
                log.warn("CreateDCRenderTarget failed", .{});
                return false;
            }
            self.target = .{ .dc = rt orelse return false };
            self.dc_alpha = alpha;
            self.dpi = dpi_f;
        }
        const rt = self.target.dc;
        if (dpi_f != self.dpi) {
            rt.vtable.render_target.SetDpi(@ptrCast(rt), dpi_f, dpi_f);
            self.dpi = dpi_f;
        }
        if (!succeeded(rt.vtable.BindDC(rt, hdc, &rect))) return false;
        return self.beginDraw();
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

    /// Finish drawing; recreates the target on the next begin when the
    /// device was lost.
    pub fn end(self: *Canvas) void {
        if (!self.drawing) return;
        self.drawing = false;
        const rt = self.renderTarget() orelse return;
        const hr = rt.vtable.EndDraw(rt, null, null);
        if (hr == D2DERR_RECREATE_TARGET) {
            self.discardTarget();
        } else if (!succeeded(hr)) {
            log.warn("EndDraw failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        }
    }

    /// The size of the current HWND target in DIPs.
    pub fn size(self: *const Canvas) Size {
        const scale = self.dpi / 96.0;
        return .{
            .width = @as(f32, @floatFromInt(self.pixel_size.width)) / scale,
            .height = @as(f32, @floatFromInt(self.pixel_size.height)) / scale,
        };
    }

    fn brushFor(self: *Canvas, color: Color) ?*ID2D1SolidColorBrush {
        const brush = self.brush orelse return null;
        brush.vtable.SetColor(brush, &color);
        return brush;
    }

    pub fn clear(self: *Canvas, color: Color) void {
        const rt = self.renderTarget() orelse return;
        rt.vtable.Clear(rt, &color);
    }

    pub fn fillRect(self: *Canvas, rect: Rect, color: Color) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.FillRectangle(rt, &rect.d2d(), brush);
    }

    pub fn fillRoundedRect(self: *Canvas, rect: Rect, radius: f32, color: Color) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.FillRoundedRectangle(rt, &.{ .rect = rect.d2d(), .radius_x = radius, .radius_y = radius }, brush);
    }

    /// Stroke a rounded rectangle with the stroke centered inside `rect`
    /// (so a 1 DIP border stays within the rectangle).
    pub fn strokeRoundedRect(self: *Canvas, rect: Rect, radius: f32, color: Color, width: f32) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        const r = rect.inset(width / 2, width / 2);
        rt.vtable.DrawRoundedRectangle(rt, &.{ .rect = r.d2d(), .radius_x = radius, .radius_y = radius }, brush, width, null);
    }

    pub fn drawLine(self: *Canvas, p0: Point, p1: Point, color: Color, width: f32) void {
        const rt = self.renderTarget() orelse return;
        const brush = self.brushFor(color) orelse return;
        rt.vtable.DrawLine(rt, p0, p1, brush, width, null);
    }

    /// Start a path at `start`; finish it with `Path.end`, draw it with
    /// `fillPath`/`strokePath` and release it with `Path.deinit`.
    pub fn beginPath(self: *Canvas, start: Point, filled: bool) ?Path {
        var geometry: ?*ID2D1PathGeometry = null;
        if (!succeeded(self.factory.d2d.vtable.CreatePathGeometry(self.factory.d2d, &geometry))) return null;
        const g = geometry orelse return null;
        var sink: ?*ID2D1GeometrySink = null;
        if (!succeeded(g.vtable.Open(g, &sink)) or sink == null) {
            release(g);
            return null;
        }
        sink.?.vtable.BeginFigure(sink.?, start, if (filled) D2D1_FIGURE_BEGIN_FILLED else 1);
        return .{ .geometry = g, .sink = sink };
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
        rt.vtable.PushAxisAlignedClip(rt, &rect.d2d(), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    }

    pub fn popClip(self: *Canvas) void {
        const rt = self.renderTarget() orelse return;
        rt.vtable.PopAxisAlignedClip(rt);
    }

    /// Draw UTF-8 `text` inside `rect`, aligned and trimmed per `style`.
    pub fn drawText(self: *Canvas, text: []const u8, rect: Rect, style: TextStyle) void {
        if (text.len == 0) return;
        const rt = self.renderTarget() orelse return;
        const l = self.factory.layout(text, style, rect.w, rect.h) orelse return;
        defer release(l);
        const brush = self.brushFor(style.color) orelse return;
        var options: u32 = D2D1_DRAW_TEXT_OPTIONS_CLIP;
        if (self.factory.d2d_1_1) options |= D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
        rt.vtable.DrawTextLayout(rt, .{ .x = rect.x, .y = rect.y }, l, brush, options);
    }

    /// Measure UTF-8 `text` (see `Factory.measureText`).
    pub fn measureText(self: *Canvas, text: []const u8, style: TextStyle, max_width: f32) Size {
        return self.factory.measureText(text, style, max_width);
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
};
