//! GUI-thread-only, optional DirectComposition popup surfaces. The existing
//! D2D factory owns one shared Device; each Popup owns its Backend. No apartment
//! initialization, WGL state, renderer locks, or application callbacks live here.
const std = @import("std");
const w32 = @import("../win32.zig");
const HR = i32;
const GUID = w32.GUID;
const Unused = *const anyopaque;
const Unknown = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HR,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
const Object = extern struct { table: *const Unknown };
fn release(object: anytype) void {
    const obj: *Object = @ptrCast(@alignCast(object));
    _ = obj.table.Release(obj);
}
fn query(object: *anyopaque, iid: *const GUID) ?*anyopaque {
    const obj: *Object = @ptrCast(@alignCast(object));
    var result: ?*anyopaque = null;
    if (obj.table.QueryInterface(obj, iid, &result) < 0) return null;
    return result;
}
const iid_factory1: GUID = .{ .Data1 = 0xbb12d362, .Data2 = 0xdaee, .Data3 = 0x4b9a, .Data4 = .{ 0xaa, 0x1d, 0x14, 0xba, 0x40, 0x1c, 0xfa, 0x1f } };
const iid_dxgi: GUID = .{ .Data1 = 0x54ec77fa, .Data2 = 0x1377, .Data3 = 0x44e6, .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const iid_desktop: GUID = .{ .Data1 = 0x5f4633fe, .Data2 = 0x1e08, .Data3 = 0x4cb8, .Data4 = .{ 0x8c, 0x75, 0xce, 0x24, 0x33, 0x3f, 0x56, 0x02 } };
const iid_context: GUID = .{ .Data1 = 0xe8f7fe7a, .Data2 = 0x191c, .Data3 = 0x466d, .Data4 = .{ 0xad, 0x95, 0x97, 0x56, 0x78, 0xbd, 0xa9, 0x98 } };
const Factory1 = extern struct {
    table: *const extern struct {
        base: [17]Unused,
        CreateDevice: *const fn (*Factory1, *anyopaque, *?*anyopaque) callconv(.winapi) HR,
    },
};
const Desktop = extern struct {
    table: *const Table,
    const Table = extern struct {
        unknown: Unknown,
        Commit: *const fn (*Desktop) callconv(.winapi) HR,
        wait_statistics: [2]Unused,
        CreateVisual: *const fn (*Desktop, *?*Visual) callconv(.winapi) HR,
        surface_factory: Unused,
        CreateSurface: *const fn (*Desktop, u32, u32, u32, u32, *?*Surface) callconv(.winapi) HR,
        remaining_device2: [15]Unused,
        CreateTargetForHwnd: *const fn (*Desktop, w32.HWND, i32, *?*Target) callconv(.winapi) HR,
    };
};
const Target = extern struct {
    table: *const extern struct {
        unknown: Unknown,
        SetRoot: *const fn (*Target, ?*Visual) callconv(.winapi) HR,
    },
};
const Visual = extern struct {
    table: *const extern struct {
        unknown: Unknown,
        transforms_effects_clip: [12]Unused,
        SetContent: *const fn (*Visual, ?*anyopaque) callconv(.winapi) HR,
    },
};
const Surface = extern struct {
    table: *const extern struct {
        unknown: Unknown,
        BeginDraw: *const fn (*Surface, ?*const w32.RECT, *const GUID, *?*anyopaque, *w32.POINT) callconv(.winapi) HR,
        EndDraw: *const fn (*Surface) callconv(.winapi) HR,
    },
};
const CreateD3D = *const fn (?*anyopaque, u32, ?*anyopaque, u32, ?[*]const u32, u32, u32, *?*anyopaque, ?*u32, ?*?*anyopaque) callconv(.winapi) HR;
const CreateComposition = *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HR;

/// Exact opt-in only. Unknown and absent values keep the legacy path.
pub fn enabled() bool {
    var value: [8]u16 = undefined;
    const len = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_POPUP_DCOMP"), &value, value.len);
    return len == 1 and value[0] == '1';
}
extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;

pub const Device = struct {
    d3d_module: *anyopaque,
    comp_module: *anyopaque,
    d3d: *anyopaque,
    d2d: *anyopaque,
    desktop: *Desktop,
    warp: bool,

    pub fn init(factory: *anyopaque) !Device {
        const d3d_module = w32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll"), null, 0x800) orelse return error.Unavailable;
        errdefer _ = w32.FreeLibrary(d3d_module);
        const comp_module = w32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll"), null, 0x800) orelse return error.Unavailable;
        errdefer _ = w32.FreeLibrary(comp_module);
        const create_d3d: CreateD3D = @ptrCast(w32.GetProcAddress(d3d_module, "D3D11CreateDevice") orelse return error.Unavailable);
        const create_comp: CreateComposition = @ptrCast(w32.GetProcAddress(comp_module, "DCompositionCreateDevice2") orelse return error.Unavailable);
        const factory1: *Factory1 = @ptrCast(@alignCast(query(factory, &iid_factory1) orelse return error.Unavailable));
        defer release(factory1);
        // Retry the entire device chain with WARP, including unsupported
        // hardware D2D/DComp devices, not just D3D11CreateDevice failure.
        for ([_]u32{ 1, 5 }) |driver| {
            if (initDriver(factory1, create_d3d, create_comp, driver)) |result| return .{
                .d3d_module = d3d_module,
                .comp_module = comp_module,
                .d3d = result.d3d,
                .d2d = result.d2d,
                .desktop = result.desktop,
                .warp = driver == 5,
            } else |_| {}
        }
        return error.Unavailable;
    }
    fn initDriver(factory: *Factory1, create_d3d: CreateD3D, create_comp: CreateComposition, driver: u32) !struct { d3d: *anyopaque, d2d: *anyopaque, desktop: *Desktop } {
        var d3d_out: ?*anyopaque = null;
        if (create_d3d(null, driver, null, 0x20, null, 0, 7, &d3d_out, null, null) < 0) return error.Unavailable;
        const d3d = d3d_out orelse return error.Unavailable;
        errdefer release(d3d);
        const dxgi = query(d3d, &iid_dxgi) orelse return error.Unavailable;
        defer release(dxgi);
        var d2d_out: ?*anyopaque = null;
        if (factory.table.CreateDevice(factory, dxgi, &d2d_out) < 0) return error.Unavailable;
        const d2d = d2d_out orelse return error.Unavailable;
        errdefer release(d2d);
        var comp_out: ?*anyopaque = null;
        if (create_comp(d2d, &iid_desktop, &comp_out) < 0) return error.Unavailable;
        return .{ .d3d = d3d, .d2d = d2d, .desktop = @ptrCast(@alignCast(comp_out orelse return error.Unavailable)) };
    }
    pub fn deinit(self: *Device) void {
        release(self.desktop);
        release(self.d2d);
        release(self.d3d);
        _ = w32.FreeLibrary(self.comp_module);
        _ = w32.FreeLibrary(self.d3d_module);
        self.* = undefined;
    }
};

pub const FrameKey = struct { width: u32, height: u32, dpi: u32, generation: u64 };
pub const Failure = enum(u32) { none, target, surface, begin, end, commit };
pub const Borrowed = struct { context: *anyopaque, offset: w32.POINT, key: FrameKey };

pub const Backend = struct {
    device: *Device,
    target: *Target,
    visual: *Visual,
    surface: ?*Surface = null,
    key: FrameKey = .{ .width = 0, .height = 0, .dpi = 0, .generation = 0 },
    presented: ?FrameKey = null,
    drawing: bool = false,
    failure: Failure = .none,

    pub fn init(device: *Device, hwnd: w32.HWND) !Backend {
        var target_out: ?*Target = null;
        if (device.desktop.table.CreateTargetForHwnd(device.desktop, hwnd, 1, &target_out) < 0) return error.TargetFailed;
        const target = target_out orelse return error.TargetFailed;
        errdefer release(target);
        var visual_out: ?*Visual = null;
        if (device.desktop.table.CreateVisual(device.desktop, &visual_out) < 0) return error.VisualFailed;
        const visual = visual_out orelse return error.VisualFailed;
        errdefer release(visual);
        if (target.table.SetRoot(target, visual) < 0) return error.RootFailed;
        return .{ .device = device, .target = target, .visual = visual };
    }
    pub fn deinit(self: *Backend) void {
        self.reset();
        _ = self.target.table.SetRoot(self.target, null);
        _ = self.device.desktop.table.Commit(self.device.desktop);
        release(self.visual);
        release(self.target);
        self.* = undefined;
    }
    pub fn reset(self: *Backend) void {
        if (self.surface) |surface| {
            if (self.drawing) _ = surface.table.EndDraw(surface);
            self.drawing = false;
            _ = self.visual.table.SetContent(self.visual, null);
            release(surface);
        }
        self.surface = null;
        self.presented = null;
    }
    pub fn begin(self: *Backend, width: u32, height: u32, dpi: u32) !Borrowed {
        if (self.drawing or width == 0 or height == 0 or dpi == 0) return error.InvalidFrame;
        if (self.failure == .target) return error.InjectedFailure;
        if (self.surface == null or self.key.width != width or self.key.height != height or self.key.dpi != dpi) {
            self.reset();
            if (self.key.generation == std.math.maxInt(u64)) return error.Exhausted;
            self.key = .{ .width = width, .height = height, .dpi = dpi, .generation = self.key.generation + 1 };
            if (self.failure == .surface) return error.InjectedFailure;
            var surface_out: ?*Surface = null;
            if (self.device.desktop.table.CreateSurface(self.device.desktop, width, height, 87, 1, &surface_out) < 0) return error.SurfaceFailed;
            self.surface = surface_out orelse return error.SurfaceFailed;
            if (self.visual.table.SetContent(self.visual, self.surface.?) < 0) return error.ContentFailed;
        }
        self.presented = null;
        if (self.failure == .begin) return error.InjectedFailure;
        const surface = self.surface.?;
        var context: ?*anyopaque = null;
        var offset: w32.POINT = undefined;
        if (surface.table.BeginDraw(surface, null, &iid_context, &context, &offset) < 0) return error.BeginFailed;
        self.drawing = true;
        return .{ .context = context orelse return error.BeginFailed, .offset = offset, .key = self.key };
    }
    /// Caller releases the borrowed context and all context-bound brushes first.
    pub fn finish(self: *Backend, frame: FrameKey) !void {
        if (!self.drawing) return error.InvalidFrame;
        self.drawing = false;
        const surface = self.surface orelse return error.InvalidFrame;
        const ended = surface.table.EndDraw(surface);
        if (ended < 0 or self.failure == .end) return error.EndFailed;
        if (!std.meta.eql(frame, self.key)) return error.StaleFrame;
        if (self.failure == .commit or self.device.desktop.table.Commit(self.device.desktop) < 0) return error.CommitFailed;
        self.presented = frame;
    }
    pub fn ready(self: *const Backend, width: u32, height: u32, dpi: u32) bool {
        const frame = self.presented orelse return false;
        return frame.width == width and frame.height == height and frame.dpi == dpi and std.meta.eql(frame, self.key);
    }
};

pub fn releaseContext(context: *anyopaque) void {
    release(context);
}

test "DComp desktop SDK slots preserve Device2 inheritance" {
    try std.testing.expectEqual(@as(usize, 24 * @sizeOf(usize)), @offsetOf(Desktop.Table, "CreateTargetForHwnd"));
    try std.testing.expectEqual(@as(usize, 8 * @sizeOf(usize)), @offsetOf(Desktop.Table, "CreateSurface"));
}
test "DComp first frame requires current size DPI and generation" {
    var backend: Backend = undefined;
    backend.key = .{ .width = 640, .height = 480, .dpi = 144, .generation = 2 };
    backend.presented = null;
    try std.testing.expect(!backend.ready(640, 480, 144));
    backend.presented = .{ .width = 640, .height = 480, .dpi = 144, .generation = 1 };
    try std.testing.expect(!backend.ready(640, 480, 144));
    backend.presented = backend.key;
    try std.testing.expect(backend.ready(640, 480, 144));
    try std.testing.expect(!backend.ready(640, 480, 192));
    try std.testing.expect(!backend.ready(641, 480, 144));
}
