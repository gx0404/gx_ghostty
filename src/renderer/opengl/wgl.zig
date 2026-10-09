//! WGL support for the OpenGL renderer on Windows, which has no EGL.
//!
//! `Device` picks the OpenGL implementation for the whole process once:
//! the system driver (`opengl32.dll` plus the vendor ICD) when it can
//! create an OpenGL 4.3 core context, otherwise a Mesa `opengl32.dll`
//! shipped in a `mesa` directory next to the executable. Setting
//! `GHOSTTY_GX_OPENGL=software` skips the system driver. The WGL
//! extension entry points are loaded through a hidden dummy window.
//!
//! `Context` is the per-surface state. The apprt owns the window and its
//! device context (DC) and sets the pixel format once through
//! `Device.setPixelFormat`; the render thread creates, uses and destroys
//! the GL context, so no GL call ever happens on the main thread. Frames
//! are presented by blitting the render target into the window's default
//! framebuffer and swapping buffers. The window pixel format has an alpha
//! channel when the driver offers one, so the frames keep the renderer's
//! premultiplied alpha; `Device.alphaFrames` tells the apprt whether it
//! can let the desktop compositor blend them with what is behind.
//!
//! The context asks to be told about GPU resets (driver timeout recovery,
//! a driver update) where the driver supports it
//! (WGL_ARB_create_context_robustness). After a reset `present` replaces
//! the lost context with a new one and calls the apprt's
//! `gpuContextReset`, which makes the renderer rebuild its GPU resources.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const gl = @import("opengl");

const apprt = @import("../../apprt.zig");
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.opengl);

const BOOL = windows.BOOL;
const HDC = windows.HDC;
const HGLRC = windows.HGLRC;
const HMODULE = windows.HMODULE;
const HWND = windows.HWND;

/// A generic GL entry point, as glad expects it from a loader.
const GlProc = *const fn () callconv(.c) void;

/// glGetGraphicsResetStatus (OpenGL 4.5, GL_ARB_robustness), which the
/// generated loader does not include.
const GetGraphicsResetStatusFn = *const fn () callconv(.winapi) u32;
const GL_NO_ERROR: u32 = 0;

/// The DLL name of the Mesa fallback, relative to the executable.
const mesa_dll = "mesa\\opengl32.dll";

/// The environment variable that selects the OpenGL implementation.
const env_var = "GHOSTTY_GX_OPENGL";

/// How often, and how far apart, `Context.threadEnter` tries to make its
/// context current before giving up.
const make_current_attempts = 20;
const make_current_retry_ms = 10;

/// The driver whose entry points the current render thread uses for
/// loading GL functions. glad's loader callback has no user pointer, so
/// this is set on the render thread while its context is current.
threadlocal var thread_lib: ?*const Lib = null;

pub const Device = struct {
    lib: Lib,

    pub fn init(self: *Device, alloc: Allocator) !void {
        _ = alloc;

        const want_software = softwareRequested();
        if (!want_software) {
            if (probe(.system)) |lib| {
                self.* = .{ .lib = lib };
                return;
            } else |err| {
                log.warn("system OpenGL driver is unusable err={}", .{err});
            }
        }

        if (probe(.software)) |lib| {
            self.* = .{ .lib = lib };
            return;
        } else |err| {
            log.err("software OpenGL ({s}) is unavailable err={}", .{ mesa_dll, err });
        }

        reportMissingOpenGL();
        return error.OpenGLUnavailable;
    }

    pub fn deinit(self: *Device) void {
        _ = FreeLibrary(self.lib.module);
        self.* = undefined;
    }

    /// Whether the frames presented to windows of this device carry an
    /// alpha channel that the desktop compositor can blend with what is
    /// behind the window (the renderer writes premultiplied alpha), or
    /// why not. Only the system driver qualifies: the Mesa fallback keeps
    /// windows opaque.
    pub fn alphaFrames(self: *const Device) AlphaFrames {
        if (self.lib.software) return .software;
        if (!self.lib.alpha) return .no_alpha_channel;
        return .supported;
    }

    pub const AlphaFrames = enum { supported, software, no_alpha_channel };

    /// Set an OpenGL pixel format on the device context of a newly
    /// created window. A window's pixel format can only be set once, so
    /// the apprt must call this exactly once per window, before any
    /// renderer is created for it.
    pub fn setPixelFormat(self: *const Device, hdc_: *anyopaque) !void {
        const hdc: HDC = @ptrCast(hdc_);
        const lib = &self.lib;

        var pfd = basePixelFormat();
        const format = choosePixelFormat(lib, hdc, &pfd);
        if (format == 0) return error.NoPixelFormat;

        _ = lib.describePixelFormat(hdc, format, @sizeOf(PIXELFORMATDESCRIPTOR), &pfd);
        if (!lib.setPixelFormat(hdc, format, &pfd).toBool()) {
            log.warn("SetPixelFormat failed err={}", .{windows.GetLastError()});
            return error.SetPixelFormatFailed;
        }
    }
};

/// The pixel format for a window: through WGL_ARB_pixel_format an
/// sRGB-capable RGBA8 format, then any RGBA8 one; otherwise the format
/// ChoosePixelFormat picks for `pfd`. Zero when there is none.
fn choosePixelFormat(lib: *const Lib, hdc: HDC, pfd: *const PIXELFORMATDESCRIPTOR) c_int {
    if (lib.choosePixelFormatArb) |choose| {
        for ([_]c_int{ 1, 0 }) |srgb| {
            const attribs = [_]c_int{
                WGL_DRAW_TO_WINDOW_ARB,           1,
                WGL_SUPPORT_OPENGL_ARB,           1,
                WGL_DOUBLE_BUFFER_ARB,            1,
                WGL_PIXEL_TYPE_ARB,               WGL_TYPE_RGBA_ARB,
                WGL_RED_BITS_ARB,                 8,
                WGL_GREEN_BITS_ARB,               8,
                WGL_BLUE_BITS_ARB,                8,
                WGL_ALPHA_BITS_ARB,               8,
                WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB, srgb,
                0,
            };
            var format: c_int = 0;
            var count: u32 = 0;
            if (choose(hdc, &attribs, null, 1, @ptrCast(&format), &count).toBool() and
                count > 0 and format > 0) return format;
        }
    }
    return lib.choosePixelFormat(hdc, pfd);
}

/// Per-surface WGL state.
pub const Context = struct {
    /// The apprt surface that owns the window.
    surface: *apprt.Surface,

    /// The window's private device context (CS_OWNDC), owned by the apprt.
    hdc: HDC,

    /// The GL context, alive between `threadEnter` and `threadExit`.
    hglrc: ?HGLRC = null,

    /// glGetGraphicsResetStatus, when the context reports GPU resets.
    get_reset_status: ?GetGraphicsResetStatusFn = null,

    /// Called on the main thread when the renderer is created. Only
    /// records the device context; it makes no GL calls.
    pub fn init(rt_surface: *apprt.Surface) !Context {
        if (comptime !@hasField(apprt.Surface, "hdc")) return error.UnsupportedApprt;
        const hdc = rt_surface.hdc orelse return error.InvalidSurface;
        return .{ .surface = rt_surface, .hdc = @ptrCast(hdc) };
    }

    pub fn deinit(self: *Context) void {
        std.debug.assert(self.hglrc == null);
        self.* = undefined;
    }

    /// Create a core profile context for the window on the render thread
    /// and make it current. glad is loaded by the caller afterwards.
    pub fn threadEnter(self: *Context, device: *const Device) !void {
        const lib = &device.lib;
        const create = lib.createContextAttribs orelse return error.WglCreateContextUnsupported;
        const attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, OpenGL.MIN_VERSION_MAJOR,
            WGL_CONTEXT_MINOR_VERSION_ARB, OpenGL.MIN_VERSION_MINOR,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        // Prefer a context that reports GPU resets (it is lost on a reset
        // instead of failing silently); drivers without
        // WGL_ARB_create_context_robustness reject the attributes.
        const robust_attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB,               OpenGL.MIN_VERSION_MAJOR,
            WGL_CONTEXT_MINOR_VERSION_ARB,               OpenGL.MIN_VERSION_MINOR,
            WGL_CONTEXT_PROFILE_MASK_ARB,                WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            WGL_CONTEXT_FLAGS_ARB,                       WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB,
            WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB, WGL_LOSE_CONTEXT_ON_RESET_ARB,
            0,
        };
        var robust = true;
        const hglrc = create(self.hdc, null, &robust_attribs) orelse robust: {
            robust = false;
            break :robust create(self.hdc, null, &attribs) orelse {
                log.warn("wglCreateContextAttribsARB failed err={}", .{windows.GetLastError()});
                return error.WglCreateContextFailed;
            };
        };
        errdefer _ = lib.deleteContext(hglrc);

        // NVIDIA's threaded driver can fail this transiently (for example
        // with ERROR_TRANSFORM_NOT_SUPPORTED) while the main thread shows
        // or moves the window, and then succeeds on a retry.
        var attempt: u32 = 1;
        while (!lib.makeCurrent(self.hdc, hglrc).toBool()) : (attempt += 1) {
            const err = windows.GetLastError();
            if (attempt >= make_current_attempts) {
                log.warn("wglMakeCurrent failed err={} attempts={}", .{ err, attempt });
                return error.WglMakeCurrentFailed;
            }
            log.debug("wglMakeCurrent failed err={}, retrying", .{err});
            Sleep(make_current_retry_ms);
        }
        if (attempt > 1) log.info("wglMakeCurrent succeeded attempts={}", .{attempt});

        self.hglrc = hglrc;
        thread_lib = lib;
        if (lib.swapInterval) |swapInterval| _ = swapInterval(1);
        self.get_reset_status = if (robust)
            lib.extension("glGetGraphicsResetStatus", GetGraphicsResetStatusFn) orelse
                lib.extension("glGetGraphicsResetStatusARB", GetGraphicsResetStatusFn)
        else
            null;
        log.debug("created the OpenGL context reports_resets={}", .{self.get_reset_status != null});
    }

    /// Release and destroy the context on the render thread.
    pub fn threadExit(self: *Context, device: *const Device) void {
        const lib = &device.lib;
        _ = lib.makeCurrent(null, null);
        if (self.hglrc) |hglrc| _ = lib.deleteContext(hglrc);
        self.hglrc = null;
        self.get_reset_status = null;
        thread_lib = null;
    }

    /// Whether the context was lost to a GPU reset (or the apprt simulates
    /// one, see `takeSimulatedGpuReset`).
    fn lost(self: *Context) bool {
        if (comptime @hasDecl(apprt.Surface, "takeSimulatedGpuReset")) {
            if (self.surface.takeSimulatedGpuReset()) return true;
        }
        const status = (self.get_reset_status orelse return false)();
        if (status == GL_NO_ERROR) return false;
        log.warn("the GPU was reset status=0x{x}", .{status});
        return true;
    }

    /// Replace a lost context with a new one on the render thread, load
    /// the GL functions and the state `OpenGL.threadEnter` sets up again,
    /// and tell the apprt that the renderer's GPU resources are gone with
    /// the old context (`gpuContextReset`, called with the renderer's draw
    /// mutex held by this thread).
    fn recover(self: *Context, device: *const Device) void {
        log.warn("recreating the lost OpenGL context", .{});
        self.threadExit(device);
        gl.glad.unload();
        self.threadEnter(device) catch |err| {
            log.err("cannot recreate the OpenGL context err={}", .{err});
            return;
        };
        _ = gl.glad.load(&getProcAddress) catch |err| {
            log.err("cannot load OpenGL after recreating the context err={}", .{err});
            return;
        };
        gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
            log.warn("error enabling GL_FRAMEBUFFER_SRGB err={}", .{err});
        };
        if (comptime @hasDecl(apprt.Surface, "gpuContextReset")) {
            self.surface.gpuContextReset();
        }
    }

    /// Log the implementation behind the current context. glad must be
    /// loaded on this thread.
    pub fn logImplementation(self: *const Context, device: *const Device) void {
        _ = self;
        const ctx = &gl.glad.context;
        const version = parseVersion(glString(ctx.GetString, gl.c.GL_VERSION));
        log.info("loaded OpenGL {d}.{d} vendor={s} renderer={s} software={}", .{
            version.major,
            version.minor,
            glString(ctx.GetString, gl.c.GL_VENDOR),
            glString(ctx.GetString, gl.c.GL_RENDERER),
            device.lib.software,
        });
    }

    /// Copy the rendered target into the window and swap buffers.
    /// Called on the render thread with the context current. After a GPU
    /// reset nothing is presented: the context is recreated (`recover`)
    /// and the frame fails with `error.ContextLost`.
    pub fn present(self: *Context, device: *const Device, target: Target) !void {
        if (self.lost()) {
            self.recover(device);
            return error.ContextLost;
        }

        // The target holds sRGB-encoded values; copy them verbatim.
        try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
        defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
            log.err("error re-enabling GL_FRAMEBUFFER_SRGB err={}", .{err});
        };

        const default_fbo: gl.Framebuffer = .{ .id = 0 };
        const draw = try default_fbo.bind(.draw);
        defer draw.unbind();
        const read = try target.framebuffer.bind(.read);
        defer read.unbind();

        // The window can briefly differ in size from the target while it
        // is being resized. GL's origin is the bottom-left corner, so
        // offset the copy to keep the grid anchored at the top.
        const width: c_int = @intCast(target.width);
        const height: c_int = @intCast(target.height);
        const window_height: c_int = height: {
            const hwnd = WindowFromDC(self.hdc) orelse break :height height;
            var rect: RECT = undefined;
            if (!GetClientRect(hwnd, &rect).toBool()) break :height height;
            break :height rect.bottom - rect.top;
        };
        const y = window_height - height;

        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
        try gl.blitFramebuffer(
            0,
            0,
            width,
            height,
            0,
            y,
            width,
            y + height,
            .{ .color_buffer_bit = true },
            .nearest,
        );

        if (!device.lib.swapBuffers(self.hdc).toBool()) {
            log.warn("SwapBuffers failed err={}", .{windows.GetLastError()});
            if (self.lost()) {
                self.recover(device);
                return error.ContextLost;
            }
            return error.SwapBuffersFailed;
        }

        // Let an apprt that waits for frames during a live resize go on.
        if (comptime @hasDecl(apprt.Surface, "signalFrameDrawn")) {
            self.surface.signalFrameDrawn();
        }
    }
};

/// glad loader for the render thread's current context. Extension and
/// post-1.1 functions come from wglGetProcAddress; OpenGL 1.1 functions
/// are only exported by the driver DLL itself.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?GlProc {
    const lib = thread_lib orelse return null;
    if (lib.getProcAddress(name)) |proc| {
        // Some drivers return small sentinel values instead of null.
        switch (@intFromPtr(proc)) {
            1, 2, 3, std.math.maxInt(usize) => {},
            else => return @ptrCast(proc),
        }
    }
    return @ptrCast(GetProcAddress(lib.module, name));
}

/// The entry points of the OpenGL implementation in use.
const Lib = struct {
    module: HMODULE,
    software: bool,
    /// Whether the pixel format windows get has an alpha channel.
    alpha: bool = false,

    createContext: *const fn (HDC) callconv(.winapi) ?HGLRC,
    deleteContext: *const fn (HGLRC) callconv(.winapi) BOOL,
    makeCurrent: *const fn (?HDC, ?HGLRC) callconv(.winapi) BOOL,
    getProcAddress: *const fn ([*:0]const u8) callconv(.winapi) ?*const anyopaque,
    swapBuffers: *const fn (HDC) callconv(.winapi) BOOL,
    choosePixelFormat: *const fn (HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int,
    setPixelFormat: *const fn (HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL,
    describePixelFormat: *const fn (HDC, c_int, u32, ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int,

    createContextAttribs: ?CreateContextAttribsFn = null,
    choosePixelFormatArb: ?ChoosePixelFormatArbFn = null,
    swapInterval: ?SwapIntervalFn = null,

    const CreateContextAttribsFn = *const fn (HDC, ?HGLRC, [*]const c_int) callconv(.winapi) ?HGLRC;
    const ChoosePixelFormatArbFn = *const fn (HDC, [*]const c_int, ?[*]const f32, u32, [*]c_int, *u32) callconv(.winapi) BOOL;
    const SwapIntervalFn = *const fn (c_int) callconv(.winapi) BOOL;

    const Kind = enum { system, software };

    /// Load the base WGL entry points of an implementation. The system
    /// driver goes through gdi32 for pixel formats and buffer swaps, as
    /// documented; Mesa must be called directly since gdi32 always
    /// dispatches to the system opengl32.dll.
    fn load(kind: Kind) !Lib {
        const module: HMODULE = switch (kind) {
            .system => LoadLibraryExW(
                std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"),
                null,
                LOAD_LIBRARY_SEARCH_SYSTEM32,
            ) orelse return error.OpenGLLibraryNotFound,
            .software => try loadMesa(),
        };
        errdefer _ = FreeLibrary(module);

        var lib: Lib = .{
            .module = module,
            .software = kind == .software,
            .createContext = try symbol(module, "wglCreateContext", @FieldType(Lib, "createContext")),
            .deleteContext = try symbol(module, "wglDeleteContext", @FieldType(Lib, "deleteContext")),
            .makeCurrent = try symbol(module, "wglMakeCurrent", @FieldType(Lib, "makeCurrent")),
            .getProcAddress = try symbol(module, "wglGetProcAddress", @FieldType(Lib, "getProcAddress")),
            .swapBuffers = &SwapBuffers,
            .choosePixelFormat = &ChoosePixelFormat,
            .setPixelFormat = &SetPixelFormat,
            .describePixelFormat = &DescribePixelFormat,
        };

        if (kind == .software) {
            lib.swapBuffers = try symbol(module, "wglSwapBuffers", @FieldType(Lib, "swapBuffers"));
            lib.choosePixelFormat = try symbol(module, "wglChoosePixelFormat", @FieldType(Lib, "choosePixelFormat"));
            lib.setPixelFormat = try symbol(module, "wglSetPixelFormat", @FieldType(Lib, "setPixelFormat"));
            lib.describePixelFormat = try symbol(module, "wglDescribePixelFormat", @FieldType(Lib, "describePixelFormat"));
        }

        return lib;
    }

    /// Resolve a WGL extension. A context must be current.
    fn extension(self: *const Lib, name: [*:0]const u8, comptime T: type) ?T {
        const proc = self.getProcAddress(name) orelse return null;
        return switch (@intFromPtr(proc)) {
            1, 2, 3, std.math.maxInt(usize) => null,
            else => @ptrCast(proc),
        };
    }
};

/// Load an implementation and check, on a hidden window, that it can
/// create an OpenGL core context of the required version. On success the
/// returned `Lib` also has the WGL extensions loaded.
fn probe(kind: Lib.Kind) !Lib {
    var lib = try Lib.load(kind);
    errdefer _ = FreeLibrary(lib.module);

    const instance = GetModuleHandleW(null);
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWglProbe");
    const class: WNDCLASSEXW = .{
        .style = CS_OWNDC,
        .lpfnWndProc = &DefWindowProcW,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    if (RegisterClassExW(&class) == 0) return error.RegisterClassFailed;
    defer _ = UnregisterClassW(class_name, instance);

    const hwnd = CreateWindowExW(
        0,
        class_name,
        class_name,
        WS_OVERLAPPEDWINDOW,
        0,
        0,
        16,
        16,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    defer _ = DestroyWindow(hwnd);

    const hdc = GetDC(hwnd) orelse return error.GetDCFailed;
    defer _ = ReleaseDC(hwnd, hdc);

    var pfd = basePixelFormat();
    const format = lib.choosePixelFormat(hdc, &pfd);
    if (format == 0) return error.NoPixelFormat;
    if (!lib.setPixelFormat(hdc, format, &pfd).toBool()) return error.SetPixelFormatFailed;

    // A legacy context is required to look up the extensions.
    const legacy = lib.createContext(hdc) orelse return error.WglCreateContextFailed;
    defer _ = lib.deleteContext(legacy);
    if (!lib.makeCurrent(hdc, legacy).toBool()) return error.WglMakeCurrentFailed;
    defer _ = lib.makeCurrent(null, null);

    lib.createContextAttribs = lib.extension("wglCreateContextAttribsARB", Lib.CreateContextAttribsFn);
    lib.choosePixelFormatArb = lib.extension("wglChoosePixelFormatARB", Lib.ChoosePixelFormatArbFn);
    lib.swapInterval = lib.extension("wglSwapIntervalEXT", Lib.SwapIntervalFn);
    lib.alpha = alpha: {
        var window_pfd = basePixelFormat();
        const window_format = choosePixelFormat(&lib, hdc, &window_pfd);
        if (window_format == 0) break :alpha false;
        if (lib.describePixelFormat(hdc, window_format, @sizeOf(PIXELFORMATDESCRIPTOR), &window_pfd) == 0) break :alpha false;
        break :alpha window_pfd.cAlphaBits >= 8;
    };
    const create = lib.createContextAttribs orelse return error.WglCreateContextUnsupported;

    const attribs = [_]c_int{
        WGL_CONTEXT_MAJOR_VERSION_ARB, OpenGL.MIN_VERSION_MAJOR,
        WGL_CONTEXT_MINOR_VERSION_ARB, OpenGL.MIN_VERSION_MINOR,
        WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        0,
    };
    const core = create(hdc, null, &attribs) orelse return error.OpenGLOutdated;
    defer _ = lib.deleteContext(core);
    if (!lib.makeCurrent(hdc, core).toBool()) return error.WglMakeCurrentFailed;

    const get_string = try symbol(lib.module, "glGetString", gl.c.PFNGLGETSTRINGPROC);
    const version = parseVersion(glString(get_string, gl.c.GL_VERSION));
    log.info("{t} OpenGL {d}.{d} vendor={s} renderer={s}", .{
        kind,
        version.major,
        version.minor,
        glString(get_string, gl.c.GL_VENDOR),
        glString(get_string, gl.c.GL_RENDERER),
    });
    if (version.major < OpenGL.MIN_VERSION_MAJOR or
        (version.major == OpenGL.MIN_VERSION_MAJOR and version.minor < OpenGL.MIN_VERSION_MINOR))
    {
        return error.OpenGLOutdated;
    }

    return lib;
}

/// Load the Mesa DLL from the `mesa` directory next to the executable.
/// Its own dependencies are resolved from that directory first.
fn loadMesa() !HMODULE {
    var buf: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const len = GetModuleFileNameW(null, &buf, windows.PATH_MAX_WIDE);
    if (len == 0 or len >= windows.PATH_MAX_WIDE) return error.ExecutablePathUnknown;
    const dir_len = (std.mem.lastIndexOfScalar(u16, buf[0..len], '\\') orelse
        return error.ExecutablePathUnknown) + 1;

    const name = std.unicode.utf8ToUtf16LeStringLiteral(mesa_dll);
    if (dir_len + name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[dir_len..][0..name.len], name);
    buf[dir_len + name.len] = 0;

    const path: [*:0]const u16 = @ptrCast(&buf);
    return LoadLibraryExW(path, null, LOAD_WITH_ALTERED_SEARCH_PATH) orelse
        error.OpenGLLibraryNotFound;
}

fn softwareRequested() bool {
    var buf: [32]u16 = undefined;
    const len = GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral(env_var),
        &buf,
        buf.len,
    );
    if (len == 0 or len >= buf.len) return false;
    const value = std.unicode.utf8ToUtf16LeStringLiteral("software");
    if (len != value.len) return false;
    for (buf[0..len], value) |a, b| {
        if (std.ascii.toLower(@truncate(a)) != b or a > 0x7f) return false;
    }
    return true;
}

/// Without OpenGL the app cannot render anything, and a GUI subsystem
/// executable has no console to report that on.
fn reportMissingOpenGL() void {
    if (comptime builtin.is_test) return;
    _ = MessageBoxW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Ghostty requires OpenGL 4.3 or newer, but no usable OpenGL driver was found.\n\n" ++
                "Update the graphics driver, or put a Mesa opengl32.dll in the \"mesa\" " ++
                "folder next to ghostty.exe.",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        MB_ICONERROR,
    );
}

fn symbol(module: HMODULE, name: [*:0]const u8, comptime T: type) !T {
    const proc = GetProcAddress(module, name) orelse {
        log.warn("missing WGL entry point name={s}", .{name});
        return error.MissingEntryPoint;
    };
    return @ptrCast(proc);
}

fn glString(get_string: gl.c.PFNGLGETSTRINGPROC, name: gl.c.GLenum) []const u8 {
    const f = get_string orelse return "";
    const ptr: ?[*:0]const u8 = @ptrCast(f(name));
    return std.mem.sliceTo(ptr orelse return "", 0);
}

const Version = struct { major: u32, minor: u32 };

/// Parse the leading "major.minor" of a GL_VERSION string.
fn parseVersion(s: []const u8) Version {
    var it = std.mem.tokenizeAny(u8, s, ". ");
    const major = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    return .{ .major = major, .minor = minor };
}

fn basePixelFormat() PIXELFORMATDESCRIPTOR {
    return .{
        .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        .iPixelType = PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
    };
}

test parseVersion {
    const testing = std.testing;
    try testing.expectEqual(Version{ .major = 4, .minor = 6 }, parseVersion("4.6.0 NVIDIA 555.85"));
    try testing.expectEqual(Version{ .major = 4, .minor = 5 }, parseVersion("4.5 (Core Profile) Mesa 24.2.0"));
    try testing.expectEqual(Version{ .major = 0, .minor = 0 }, parseVersion(""));
}

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HMODULE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_TYPE_RGBA = 0;

const CS_OWNDC = 0x0020;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const MB_ICONERROR = 0x00000010;
const LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;

const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_RED_BITS_ARB = 0x2015;
const WGL_GREEN_BITS_ARB = 0x2017;
const WGL_BLUE_BITS_ARB = 0x2019;
const WGL_ALPHA_BITS_ARB = 0x201B;
const WGL_TYPE_RGBA_ARB = 0x202B;
const WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB = 0x20A9;
const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB = 0x00000004;
const WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB = 0x8256;
const WGL_LOSE_CONTEXT_ON_RESET_ARB = 0x8252;

extern "kernel32" fn LoadLibraryExW(lpLibFileName: [*:0]const u16, hFile: ?*anyopaque, dwFlags: u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetModuleFileNameW(hModule: ?HMODULE, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn UnregisterClassW(lpClassName: [*:0]const u16, hInstance: ?HMODULE) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: ?HMODULE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
extern "user32" fn WindowFromDC(hDC: HDC) callconv(.winapi) ?HWND;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: u32) callconv(.winapi) c_int;

extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn DescribePixelFormat(hdc: HDC, iPixelFormat: c_int, nBytes: u32, ppfd: ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
