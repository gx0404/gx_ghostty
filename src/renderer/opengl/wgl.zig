//! WGL support for the OpenGL renderer on Windows, which has no EGL.
//!
//! `Device` picks the OpenGL implementation for the whole process once, on
//! a thread of its own that `Device.init` starts, so that the main thread
//! goes on with its startup while a driver loads: the system driver
//! (`opengl32.dll` plus the vendor ICD) when it can create an OpenGL 4.3
//! core context, otherwise a Mesa `opengl32.dll` shipped in a `mesa`
//! directory next to the executable, held to its llvmpipe driver. Setting
//! `GHOSTTY_GX_OPENGL=software` skips the system driver. The WGL extension
//! entry points are loaded through a hidden dummy window. `Device.wait`
//! returns once the implementation is chosen and fails when there is none,
//! which the apprt then tells the user about. `Device.backend` reports the
//! vendor, renderer and version the probe saw.
//!
//! `Context` is the per-surface state. The apprt owns the window and its
//! device context (DC) and sets the pixel format once through
//! `Device.setPixelFormat`; the render thread creates, uses and destroys
//! the GL context, so no GL call ever happens on the main thread. Frames
//! are presented by blitting the render target into the window's default
//! framebuffer and swapping buffers. The target can lag behind the window
//! size while it is resized: the frame stays at the top left and its last
//! column and row are stretched over the rest (`edgeFills`). The apprt
//! publishes the window size and the dim of an unfocused split, which is
//! blended over the frame (`Surface.clientSize`, `Surface.unfocusedDim`).
//! Its atomic `Surface.bellBorder` snapshot draws an opaque, thin inner edge
//! after the dim, without changing the terminal grid or its render target.
//! The window pixel format has an alpha channel when the driver offers
//! one, so the frames keep the renderer's premultiplied alpha;
//! `Device.alphaFrames` tells the apprt whether it can let the desktop
//! compositor blend them with what is behind.
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
const global = @import("../../global.zig");
const perf = @import("../../gx/perf.zig");
const bell_border = @import("../../gx/bell_border.zig");
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
    /// The chosen implementation, once `state` is `ready`.
    lib: Lib = undefined,

    /// How far the probe got. The probe thread stores `ready` (after
    /// `lib`) or `unavailable` with release order and wakes the waiters.
    state: std.atomic.Value(State) = .init(.probing),

    /// The probe thread, until `wait` or `deinit` joins it.
    thread: ?std.Thread = null,
    owner_thread: std.Thread.Id,

    pub const State = enum(u32) { probing, ready, unavailable };

    const tw_spawn = @import("../../tripwire.zig").module(enum { spawn }, std.Thread.SpawnError);

    /// Start choosing the OpenGL implementation on a thread of its own.
    /// `wait` reports probe and thread-start failures after the apprt is ready.
    pub fn init(self: *Device, alloc: Allocator) error{OpenGLUnavailable}!void {
        _ = alloc;
        self.* = .{ .owner_thread = std.Thread.getCurrentId() };
        self.thread = self.spawnProbe() catch |err| {
            self.state.store(.unavailable, .release);
            log.warn("cannot start a thread for the OpenGL probe err={}", .{err});
            return;
        };
    }

    fn spawnProbe(self: *Device) std.Thread.SpawnError!std.Thread {
        try tw_spawn.check(.spawn);
        return std.Thread.spawn(.{}, probeThread, .{self});
    }

    pub fn deinit(self: *Device) void {
        self.assertOwnerThread();
        if (self.thread) |thread| thread.join();
        if (self.state.load(.acquire) == .ready) _ = FreeLibrary(self.lib.module);
        self.* = undefined;
    }

    /// Wait until the OpenGL implementation is chosen, on the initializing
    /// GUI thread, outside core callbacks and without holding renderer locks.
    /// The probe owns its hidden window and never waits for the GUI thread.
    /// `error.OpenGLUnavailable` when there is no usable one: the app
    /// cannot render anything then, and the apprt tells the user.
    pub fn wait(self: *Device) error{OpenGLUnavailable}!void {
        self.assertOwnerThread();
        const state = self.awaitProbe();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (state != .ready) return error.OpenGLUnavailable;
    }

    fn assertOwnerThread(self: *const Device) void {
        if (std.Thread.getCurrentId() != self.owner_thread) {
            @panic("WGL device wait and deinit must run on the initializing thread");
        }
    }

    /// The outcome of the probe, blocking until there is one. Any thread.
    fn awaitProbe(self: *const Device) State {
        var state = self.state.load(.acquire);
        if (state != .probing) return state;
        const io = global.io();
        const span: perf.Span = .begin(io);
        while (state == .probing) {
            io.futexWaitUncancelable(State, &self.state.raw, .probing);
            state = self.state.load(.acquire);
        }
        _ = span.end(io, "wgl.probe_wait");
        return state;
    }

    /// Choose the implementation and publish the outcome (`state`).
    fn probeThread(self: *Device) void {
        const io = global.io();
        const span: perf.Span = .begin(io);
        const state: State = if (chooseLib()) |lib| ready: {
            self.lib = lib;
            break :ready .ready;
        } else .unavailable;
        _ = span.end(io, "wgl.probe");
        self.state.store(state, .release);
        io.futexWake(State, &self.state.raw, std.math.maxInt(u32));
    }

    /// What renders the frames, as the probe saw it. Waits for the probe;
    /// empty when there is no usable OpenGL.
    pub fn backend(self: *const Device) Backend {
        if (self.awaitProbe() != .ready) return .{
            .vendor = "",
            .renderer = "",
            .version = .{ .major = 0, .minor = 0 },
            .software = false,
        };
        const lib = &self.lib;
        return .{
            .vendor = lib.vendor_buf[0..lib.vendor_len],
            .renderer = lib.renderer_buf[0..lib.renderer_len],
            .version = lib.version,
            .software = lib.software,
        };
    }

    /// Whether the frames presented to windows of this device carry an
    /// alpha channel that the desktop compositor can blend with what is
    /// behind the window (the renderer writes premultiplied alpha), or
    /// why not. Only the system driver qualifies: the Mesa fallback keeps
    /// windows opaque. Waits for the probe.
    pub fn alphaFrames(self: *const Device) AlphaFrames {
        if (self.awaitProbe() != .ready) return .no_alpha_channel;
        if (self.lib.software) return .software;
        if (!self.lib.alpha) return .no_alpha_channel;
        return .supported;
    }

    pub const AlphaFrames = enum { supported, software, no_alpha_channel };

    /// Set an OpenGL pixel format on the device context of a newly
    /// created window. A window's pixel format can only be set once, so
    /// the apprt must call this exactly once per window, before any
    /// renderer is created for it. Waits for the probe.
    pub fn setPixelFormat(self: *const Device, hdc_: *anyopaque) !void {
        if (self.awaitProbe() != .ready) return error.OpenGLUnavailable;
        const hdc: HDC = @ptrCast(hdc_);
        const lib = &self.lib;

        var pfd = basePixelFormat();
        const choice = choosePixelFormat(lib, hdc, &pfd);
        if (choice.format == 0) return error.NoPixelFormat;

        _ = lib.describePixelFormat(hdc, choice.format, @sizeOf(PIXELFORMATDESCRIPTOR), &pfd);
        if (!lib.setPixelFormat(hdc, choice.format, &pfd).toBool()) {
            log.warn("SetPixelFormat failed err={}", .{windows.GetLastError()});
            return error.SetPixelFormatFailed;
        }
        log.debug("window pixel format={d} srgb={} alpha={d} depth={d} stencil={d}", .{
            choice.format,
            choice.srgb,
            pfd.cAlphaBits,
            pfd.cDepthBits,
            pfd.cStencilBits,
        });
    }
};

/// The system driver, or else Mesa (pinned to llvmpipe while it loads,
/// see `LlvmpipePin`); null when neither can render.
fn chooseLib() ?Lib {
    if (!softwareRequested()) {
        if (probe(.system)) |lib| return lib else |err| {
            log.warn("system OpenGL driver is unusable err={}", .{err});
        }
    }

    const pin: LlvmpipePin = .apply();
    defer pin.restore();
    if (probe(.software)) |lib| return lib else |err| {
        log.err("software OpenGL ({s}) is unavailable err={}", .{ mesa_dll, err });
    }
    return null;
}

/// Holds Mesa to llvmpipe while `chooseLib` loads it. Without
/// `GALLIUM_DRIVER`, Mesa prefers its D3D12 driver when it finds
/// `dxil.dll` and a D3D12 adapter, which in a virtual machine is the WARP
/// software rasterizer with stability problems of its own; and llvmpipe
/// gives every context as many rasterizer threads as there are CPUs, one
/// context per terminal. The variables are only set where the user has not
/// set them, and removed again after the probe: Mesa's DLLs carry their
/// own C runtime, which copies the environment when they load, and Mesa
/// picks the driver and its thread count when the probe makes the first
/// context. The probe runs at startup, before any terminal starts a
/// process that could inherit them.
const LlvmpipePin = struct {
    driver: bool = false,
    threads: bool = false,

    const driver_var = std.unicode.utf8ToUtf16LeStringLiteral("GALLIUM_DRIVER");
    const threads_var = std.unicode.utf8ToUtf16LeStringLiteral("LP_NUM_THREADS");

    fn apply() LlvmpipePin {
        var pin: LlvmpipePin = .{};
        if (!envSet(driver_var)) {
            pin.driver = SetEnvironmentVariableW(
                driver_var,
                std.unicode.utf8ToUtf16LeStringLiteral("llvmpipe"),
            ).toBool();
        }
        const cpus = std.Thread.getCpuCount() catch 0;
        if (!envSet(threads_var) and limitsLlvmpipeThreads(cpus)) {
            pin.threads = SetEnvironmentVariableW(
                threads_var,
                std.unicode.utf8ToUtf16LeStringLiteral(std.fmt.comptimePrint("{d}", .{llvmpipe_max_threads})),
            ).toBool();
        }
        return pin;
    }

    fn restore(self: LlvmpipePin) void {
        if (self.driver) _ = SetEnvironmentVariableW(driver_var, null);
        if (self.threads) _ = SetEnvironmentVariableW(threads_var, null);
    }

    fn envSet(name: [*:0]const u16) bool {
        return GetEnvironmentVariableW(name, null, 0) != 0;
    }
};

/// The most rasterizer threads an llvmpipe context gets: plenty for a
/// terminal, and every terminal has a context of its own.
const llvmpipe_max_threads = 4;

/// Whether llvmpipe would start more than `llvmpipe_max_threads` threads
/// per context on a machine with `cpus` processors.
fn limitsLlvmpipeThreads(cpus: usize) bool {
    return cpus > llvmpipe_max_threads;
}

/// The OpenGL implementation behind a `Device` (`Device.backend`), for
/// the about page and the logs.
pub const Backend = struct {
    /// GL_VENDOR and GL_RENDERER of the probe context, e.g. "Mesa" and
    /// "llvmpipe (LLVM 19.1.7, 256 bits)"; cut to 63 and 127 bytes.
    vendor: []const u8,
    renderer: []const u8,
    /// The core profile version the probe context got.
    version: Version,
    /// The Mesa software fallback (`mesa\opengl32.dll`) rather than the
    /// system driver.
    software: bool,
};

/// A window pixel format (`choosePixelFormat`); `format` is zero when
/// there is none.
const PixelFormatChoice = struct {
    format: c_int,
    /// Chosen as sRGB-capable.
    srgb: bool = false,
};

/// The pixel format for a window: through WGL_ARB_pixel_format an
/// sRGB-capable RGBA8 format, then any RGBA8 one, either without depth and
/// stencil buffers where the driver has such a format (the renderer draws
/// into its own target and only copies frames to the window, so they would
/// only take memory); otherwise the format ChoosePixelFormat picks for
/// `pfd`.
fn choosePixelFormat(lib: *const Lib, hdc: HDC, pfd: *const PIXELFORMATDESCRIPTOR) PixelFormatChoice {
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
            var formats: [max_pixel_formats]c_int = undefined;
            var count: u32 = 0;
            if (!choose(hdc, &attribs, null, formats.len, &formats, &count).toBool()) continue;
            const found = formats[0..@min(count, formats.len)];
            if (found.len == 0 or found[0] <= 0) continue;

            var buffers: [max_pixel_formats]DepthStencil = undefined;
            for (found, buffers[0..found.len]) |format, *b| {
                var described: PIXELFORMATDESCRIPTOR = .{};
                b.* = if (lib.describePixelFormat(hdc, format, @sizeOf(PIXELFORMATDESCRIPTOR), &described) == 0)
                    .unknown
                else
                    .{ .depth = described.cDepthBits, .stencil = described.cStencilBits };
            }
            return .{ .format = found[leanestPixelFormat(buffers[0..found.len])], .srgb = srgb == 1 };
        }
    }
    return .{ .format = lib.choosePixelFormat(hdc, pfd) };
}

/// How many matching formats `choosePixelFormat` looks through for one
/// without depth and stencil buffers.
const max_pixel_formats = 64;

/// The depth and stencil bits of a pixel format.
const DepthStencil = struct {
    depth: u8,
    stencil: u8,

    /// A format that could not be described.
    const unknown: DepthStencil = .{ .depth = 0xff, .stencil = 0xff };
};

/// The first of the formats, in the driver's order of preference, without
/// depth and stencil buffers; the first one when they all have some.
fn leanestPixelFormat(formats: []const DepthStencil) usize {
    for (formats, 0..) |f, i| {
        if (f.depth == 0 and f.stencil == 0) return i;
    }
    return 0;
}

/// Per-surface WGL state.
pub const Context = struct {
    /// The apprt surface that owns the window.
    surface: *apprt.Surface,

    /// The window's private device context (CS_OWNDC), owned by the apprt.
    hdc: HDC,

    /// `window-vsync`: whether buffer swaps wait for the vertical blank.
    vsync: bool,

    /// The GL context, alive between `threadEnter` and `threadExit`.
    hglrc: ?HGLRC = null,

    /// glGetGraphicsResetStatus, when the context reports GPU resets.
    get_reset_status: ?GetGraphicsResetStatusFn = null,

    /// What dims the frames of an unfocused split: made for the first
    /// frame that needs it, gone with the GL context.
    dim_pass: ?DimPass = null,

    /// Making `dim_pass` failed on this GL context; frames stay undimmed.
    dim_failed: bool = false,

    border_pass: ?BorderPass = null,
    border_failed: bool = false,

    /// Called on the main thread when the renderer is created. Only
    /// records the device context; it makes no GL calls.
    pub fn init(rt_surface: *apprt.Surface, vsync: bool) !Context {
        if (comptime !@hasField(apprt.Surface, "hdc")) return error.UnsupportedApprt;
        const hdc = rt_surface.hdc orelse return error.InvalidSurface;
        return .{ .surface = rt_surface, .hdc = @ptrCast(hdc), .vsync = vsync };
    }

    pub fn deinit(self: *Context) void {
        std.debug.assert(self.hglrc == null);
        self.* = undefined;
    }

    /// Create a core profile context for the window on the render thread
    /// and make it current. glad is loaded by the caller afterwards.
    pub fn threadEnter(self: *Context, device: *const Device) !void {
        if (device.state.load(.acquire) != .ready) return error.OpenGLUnavailable;
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
        gl.glad.context = std.mem.zeroes(gl.glad.Context);
        thread_lib = lib;
        if (lib.swapInterval) |swapInterval| _ = swapInterval(@intFromBool(self.vsync));
        self.get_reset_status = if (robust)
            lib.extension("glGetGraphicsResetStatus", GetGraphicsResetStatusFn) orelse
                lib.extension("glGetGraphicsResetStatusARB", GetGraphicsResetStatusFn)
        else
            null;
        log.debug("created the OpenGL context reports_resets={} vsync={}", .{ self.get_reset_status != null, self.vsync });
    }

    /// Release and destroy the context on the render thread.
    pub fn threadExit(self: *Context, device: *const Device) void {
        if (self.dim_pass) |pass| pass.deinit();
        self.dim_pass = null;
        self.dim_failed = false;
        if (self.border_pass) |pass| pass.deinit();
        self.border_pass = null;
        self.border_failed = false;
        if (device.state.load(.acquire) != .ready) return;
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

        // fork(gx): GX-0043 begin: source-owned remote views export the actual
        // target FBO instead of relying on a hidden window's back buffer.
        // Only this renderer thread touches GL; the apprt guard owns the bounded
        // mapped write slot and its independent lifetime lock until finish.
        if (comptime @hasDecl(apprt.Surface, "gxRemoteRenderingEnabled")) {
            if (self.surface.gxRemoteRenderingEnabled()) {
                if (self.surface.gxBeginRemoteFrame(@intCast(target.width), @intCast(target.height))) |value| {
                    var remote = value;
                    var success = false;
                    defer remote.finish(success);
                    const ctx = &gl.glad.context;
                    // GL_FRAMEBUFFER_BINDING aliases DRAW, not READ. Preserve
                    // the actual read binding when these two targets differ.
                    var read_framebuffer: gl.c.GLint = 0;
                    ctx.GetIntegerv.?(gl.c.GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
                    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, target.framebuffer.id);
                    defer ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, @intCast(read_framebuffer));
                    var pack_buffer: gl.c.GLint = 0;
                    var alignment: gl.c.GLint = 0;
                    var row_length: gl.c.GLint = 0;
                    var skip_rows: gl.c.GLint = 0;
                    var skip_pixels: gl.c.GLint = 0;
                    var read_buffer: gl.c.GLint = 0;
                    ctx.GetIntegerv.?(gl.c.GL_PIXEL_PACK_BUFFER_BINDING, &pack_buffer);
                    ctx.GetIntegerv.?(gl.c.GL_PACK_ALIGNMENT, &alignment);
                    ctx.GetIntegerv.?(gl.c.GL_PACK_ROW_LENGTH, &row_length);
                    ctx.GetIntegerv.?(gl.c.GL_PACK_SKIP_ROWS, &skip_rows);
                    ctx.GetIntegerv.?(gl.c.GL_PACK_SKIP_PIXELS, &skip_pixels);
                    ctx.GetIntegerv.?(gl.c.GL_READ_BUFFER, &read_buffer);
                    defer {
                        ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, @intCast(pack_buffer));
                        ctx.PixelStorei.?(gl.c.GL_PACK_ALIGNMENT, alignment);
                        ctx.PixelStorei.?(gl.c.GL_PACK_ROW_LENGTH, row_length);
                        ctx.PixelStorei.?(gl.c.GL_PACK_SKIP_ROWS, skip_rows);
                        ctx.PixelStorei.?(gl.c.GL_PACK_SKIP_PIXELS, skip_pixels);
                        ctx.ReadBuffer.?(@intCast(read_buffer));
                    }
                    ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, 0);
                    ctx.PixelStorei.?(gl.c.GL_PACK_ALIGNMENT, 4);
                    ctx.PixelStorei.?(gl.c.GL_PACK_ROW_LENGTH, @intCast(remote.frame.stride / 4));
                    ctx.PixelStorei.?(gl.c.GL_PACK_SKIP_ROWS, 0);
                    ctx.PixelStorei.?(gl.c.GL_PACK_SKIP_PIXELS, 0);
                    ctx.ReadBuffer.?(gl.c.GL_COLOR_ATTACHMENT0);
                    ctx.ReadPixels.?(0, 0, @intCast(target.width), @intCast(target.height), gl.c.GL_BGRA, gl.c.GL_UNSIGNED_BYTE, remote.frame.pixels().ptr);
                    try gl.errors.getError();
                    success = true;
                }
                if (self.surface.gxRemoteViewDetached()) {
                    if (comptime @hasDecl(apprt.Surface, "signalFrameDrawn")) self.surface.signalFrameDrawn(@intCast(target.width), @intCast(target.height));
                    return;
                }
            }
        }
        // fork(gx): GX-0043 end

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
        // is being resized, and the target leaves out the column of a
        // scrollbar that reserves one: the frame stays at the top left and
        // its edges cover the rest, so nothing needs clearing. The size is
        // the one the apprt laid the window out at; the render thread does
        // not ask the window.
        const frame: Size = .{ .width = @intCast(target.width), .height = @intCast(target.height) };
        const window = self.windowSize() orelse unknown: {
            gl.clearColor(0, 0, 0, 0);
            gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
            break :unknown frame;
        };
        try blit(frameBlit(frame, window));
        const fills = edgeFills(frame, window);
        for (fills.slice()) |fill| try blit(fill);

        if (self.unfocusedDim()) |color| self.dim(color, window);
        if (comptime @hasDecl(apprt.Surface, "bellBorder")) {
            self.border(self.surface.bellBorder(), window);
        }

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
            self.surface.signalFrameDrawn(@intCast(target.width), @intCast(target.height));
        }
    }

    /// The window's client size as the apprt last laid it out, null where
    /// the apprt does not publish it.
    fn windowSize(self: *const Context) ?Size {
        if (comptime !@hasDecl(apprt.Surface, "clientSize")) return null;
        const size = self.surface.clientSize() orelse return null;
        return .{ .width = size.width, .height = size.height };
    }

    /// The color the apprt asks to blend over the frame of an unfocused
    /// split, or null.
    fn unfocusedDim(self: *const Context) ?[4]f32 {
        if (comptime !@hasDecl(apprt.Surface, "unfocusedDim")) return null;
        const dim_color = self.surface.unfocusedDim();
        return dimColor(dim_color.r, dim_color.g, dim_color.b, dim_color.a);
    }

    /// Blend `color` over the `window`-sized default framebuffer, which is
    /// bound for drawing. A dim that cannot be drawn is left out.
    fn dim(self: *Context, color: [4]f32, window: Size) void {
        if (self.dim_failed) return;
        const pass = self.dim_pass orelse pass: {
            const pass = DimPass.init() catch |err| {
                log.warn("cannot dim unfocused splits err={}", .{err});
                self.dim_failed = true;
                return;
            };
            self.dim_pass = pass;
            break :pass pass;
        };
        pass.draw(color, window) catch |err| {
            log.warn("error dimming the frame err={}", .{err});
        };
    }

    fn border(self: *Context, snapshot: bell_border.Snapshot, window: Size) void {
        if (!snapshot.active or snapshot.width == 0 or self.border_failed) return;
        if (window.width == 0 or window.height == 0) return;
        const pass = self.border_pass orelse pass: {
            const pass = BorderPass.init() catch |err| {
                self.border_failed = true;
                log.warn("cannot draw bell borders on this GL context err={}", .{err});
                return;
            };
            self.border_pass = pass;
            break :pass pass;
        };
        pass.draw(snapshot, window) catch |err| {
            self.border_failed = true;
            log.warn("bell border disabled until the GL context is rebuilt err={}", .{err});
        };
    }
};

const BorderPass = struct {
    program: gl.Program,
    vao: gl.VertexArray,

    const fragment_source =
        \\#version 430 core
        \\layout(location = 0) uniform vec4 ring;
        \\layout(location = 1) uniform vec3 bounds;
        \\layout(location = 0) out vec4 color;
        \\void main() {
        \\    vec2 p = gl_FragCoord.xy;
        \\    if (p.x >= bounds.z && p.y >= bounds.z && p.x < bounds.x - bounds.z && p.y < bounds.y - bounds.z) discard;
        \\    color = vec4(ring.rgb, 1.0);
        \\}
    ;

    fn init() !BorderPass {
        const program = try gl.Program.createVF(DimPass.vertex_source, fragment_source);
        errdefer program.destroy();
        const vao = try gl.VertexArray.create();
        return .{ .program = program, .vao = vao };
    }

    fn deinit(self: BorderPass) void {
        self.vao.destroy();
        self.program.destroy();
    }

    fn draw(self: BorderPass, snapshot: bell_border.Snapshot, window: Size) !void {
        const thickness = bell_border.thickness(window.width, window.height, snapshot.width);
        if (!snapshot.active or thickness == 0) return;
        const state = BorderDrawState.capture();
        defer state.restore();
        const ctx = &gl.glad.context;
        for (BorderDrawState.capabilities) |cap| ctx.Disable.?(cap);
        ctx.ColorMask.?(gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE);
        try gl.viewport(0, 0, @intCast(window.width), @intCast(window.height));
        _ = try self.program.use();
        _ = try self.vao.bind();
        const color = snapshot.color();
        ctx.Uniform4f.?(0, color[0], color[1], color[2], color[3]);
        ctx.Uniform3f.?(1, @floatFromInt(window.width), @floatFromInt(window.height), @floatFromInt(thickness));
        // Opaque source-over also covers a fully transparent terminal background.
        try gl.drawArrays(gl.c.GL_TRIANGLES, 0, 3);
    }
};

const BorderDrawState = struct {
    viewport: [4]gl.c.GLint,
    program: gl.c.GLint,
    vao: gl.c.GLint,
    enabled: [capabilities.len]bool,
    color_mask: [4]gl.c.GLboolean,

    const capabilities = [_]gl.c.GLenum{
        gl.c.GL_BLEND,
        gl.c.GL_SCISSOR_TEST,
        gl.c.GL_DEPTH_TEST,
        gl.c.GL_STENCIL_TEST,
        gl.c.GL_CULL_FACE,
        gl.c.GL_RASTERIZER_DISCARD,
    };

    fn capture() BorderDrawState {
        const ctx = &gl.glad.context;
        var state: BorderDrawState = undefined;
        ctx.GetIntegerv.?(gl.c.GL_VIEWPORT, &state.viewport);
        ctx.GetIntegerv.?(gl.c.GL_CURRENT_PROGRAM, &state.program);
        ctx.GetIntegerv.?(gl.c.GL_VERTEX_ARRAY_BINDING, &state.vao);
        ctx.GetBooleanv.?(gl.c.GL_COLOR_WRITEMASK, &state.color_mask);
        for (capabilities, &state.enabled) |cap, *enabled| enabled.* = ctx.IsEnabled.?(cap) == gl.c.GL_TRUE;
        return state;
    }

    fn restore(self: BorderDrawState) void {
        const ctx = &gl.glad.context;
        ctx.Viewport.?(self.viewport[0], self.viewport[1], self.viewport[2], self.viewport[3]);
        ctx.UseProgram.?(@intCast(self.program));
        ctx.BindVertexArray.?(@intCast(self.vao));
        ctx.ColorMask.?(self.color_mask[0], self.color_mask[1], self.color_mask[2], self.color_mask[3]);
        for (capabilities, self.enabled) |cap, enabled| {
            if (enabled) ctx.Enable.?(cap) else ctx.Disable.?(cap);
        }
    }
};

/// Blends the dim of an unfocused split over a presented frame: a
/// triangle covering the window in one premultiplied color, blended as
/// `rgb = color.rgb * dst.a + dst.rgb * (1 - color.a)` with the
/// destination alpha kept, so the dim only covers what the frame covers
/// where the window is translucent.
const DimPass = struct {
    program: gl.Program,
    vao: gl.VertexArray,

    const vertex_source =
        \\#version 430 core
        \\void main() {
        \\    gl_Position = vec4(gl_VertexID == 2 ? 3.0 : -1.0, gl_VertexID == 0 ? -3.0 : 1.0, 0.0, 1.0);
        \\}
    ;

    const fragment_source =
        \\#version 430 core
        \\layout(location = 0) uniform vec4 dim;
        \\layout(location = 0) out vec4 color;
        \\void main() {
        \\    color = dim;
        \\}
    ;

    /// The location of the `dim` uniform.
    const dim_location = 0;

    fn init() !DimPass {
        const program = try gl.Program.createVF(vertex_source, fragment_source);
        errdefer program.destroy();
        const vao = try gl.VertexArray.create();
        return .{ .program = program, .vao = vao };
    }

    fn deinit(self: DimPass) void {
        self.vao.destroy();
        self.program.destroy();
    }

    fn draw(self: DimPass, color: [4]f32, window: Size) !void {
        // The renderer keeps its viewport at the target size (and reads
        // the size back from it), so put it back.
        var viewport: [4]gl.c.GLint = undefined;
        gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
        defer gl.viewport(viewport[0], viewport[1], viewport[2], viewport[3]) catch |err| {
            log.warn("error restoring the viewport err={}", .{err});
        };
        try gl.viewport(0, 0, @intCast(window.width), @intCast(window.height));

        try gl.enable(gl.c.GL_BLEND);
        defer gl.disable(gl.c.GL_BLEND) catch {};
        gl.glad.context.BlendFuncSeparate.?(
            gl.c.GL_DST_ALPHA,
            gl.c.GL_ONE_MINUS_SRC_ALPHA,
            gl.c.GL_ZERO,
            gl.c.GL_ONE,
        );

        const program = try self.program.use();
        defer program.unbind();
        const vao = try self.vao.bind();
        defer vao.unbind();
        gl.glad.context.Uniform4f.?(dim_location, color[0], color[1], color[2], color[3]);
        try gl.drawArrays(gl.c.GL_TRIANGLES, 0, 3);
    }
};

/// The premultiplied color, as the shader takes it, of a dim with the
/// sRGB color `r`, `g`, `b` times its coverage `a` (all 0 to 255); null
/// for no dim.
fn dimColor(r: u8, g: u8, b: u8, a: u8) ?[4]f32 {
    if (a == 0) return null;
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

/// Turn off the notification-severity GL debug messages outside Debug
/// builds, which do not log them: drivers send plenty (NVIDIA describes
/// every buffer it places) and would still format each one for the
/// callback. glad must be loaded on this thread.
pub fn quietDebugOutput() void {
    if (comptime builtin.mode == .Debug) return;
    const control = gl.glad.context.DebugMessageControl orelse return;
    control(gl.c.GL_DONT_CARE, gl.c.GL_DONT_CARE, gl.c.GL_DEBUG_SEVERITY_NOTIFICATION, 0, null, gl.c.GL_FALSE);
}

/// A size in pixels.
const Size = struct { width: u32, height: u32 };

/// A rectangle in GL window coordinates (origin at the bottom left), as
/// glBlitFramebuffer takes them: `x0`, `y0` inclusive, `x1`, `y1`
/// exclusive.
const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// A copy from the render target to the window, scaled to fit `dst`.
const Blit = struct { src: Box, dst: Box };

fn blit(b: Blit) !void {
    try gl.blitFramebuffer(
        b.src.x0,
        b.src.y0,
        b.src.x1,
        b.src.y1,
        b.dst.x0,
        b.dst.y0,
        b.dst.x1,
        b.dst.y1,
        .{ .color_buffer_bit = true },
        .nearest,
    );
}

/// The copy of a `frame`-sized target into a `window`-sized framebuffer:
/// at the top left, cut off where the window is smaller.
fn frameBlit(frame: Size, window: Size) Blit {
    const w: i32 = @intCast(frame.width);
    const h: i32 = @intCast(frame.height);
    const y = @as(i32, @intCast(window.height)) - h;
    return .{
        .src = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h },
        .dst = .{ .x0 = 0, .y0 = y, .x1 = w, .y1 = y + h },
    };
}

/// The copies that cover what `frameBlit` leaves of a larger window: the
/// frame's last column stretched over the strip to its right, its last
/// row over the strip below, and its bottom right pixel over the corner.
fn edgeFills(frame: Size, window: Size) Fills {
    var fills: Fills = .{};
    if (frame.width == 0 or frame.height == 0) return fills;
    const fw: i32 = @intCast(frame.width);
    const fh: i32 = @intCast(frame.height);
    const ww: i32 = @intCast(window.width);
    // Where the frame's bottom row lands; GL's rows count from the bottom.
    const y = @as(i32, @intCast(window.height)) - fh;
    if (ww > fw) fills.add(.{
        .src = .{ .x0 = fw - 1, .y0 = 0, .x1 = fw, .y1 = fh },
        .dst = .{ .x0 = fw, .y0 = y, .x1 = ww, .y1 = y + fh },
    });
    if (y > 0) {
        fills.add(.{
            .src = .{ .x0 = 0, .y0 = 0, .x1 = fw, .y1 = 1 },
            .dst = .{ .x0 = 0, .y0 = 0, .x1 = fw, .y1 = y },
        });
        if (ww > fw) fills.add(.{
            .src = .{ .x0 = fw - 1, .y0 = 0, .x1 = fw, .y1 = 1 },
            .dst = .{ .x0 = fw, .y0 = 0, .x1 = ww, .y1 = y },
        });
    }
    return fills;
}

/// Up to three `edgeFills` copies.
const Fills = struct {
    blits: [3]Blit = undefined,
    len: usize = 0,

    fn add(self: *Fills, b: Blit) void {
        self.blits[self.len] = b;
        self.len += 1;
    }

    fn slice(self: *const Fills) []const Blit {
        return self.blits[0..self.len];
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

    /// GL_VERSION, GL_VENDOR and GL_RENDERER of the probe context
    /// (`Device.backend`).
    version: Version = .{ .major = 0, .minor = 0 },
    vendor_buf: [63]u8 = undefined,
    vendor_len: u8 = 0,
    renderer_buf: [127]u8 = undefined,
    renderer_len: u8 = 0,

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
        if (window_format.format == 0) break :alpha false;
        if (lib.describePixelFormat(hdc, window_format.format, @sizeOf(PIXELFORMATDESCRIPTOR), &window_pfd) == 0) break :alpha false;
        log.info("window pixel format={d} srgb={} alpha={d} depth={d} stencil={d}", .{
            window_format.format,
            window_format.srgb,
            window_pfd.cAlphaBits,
            window_pfd.cDepthBits,
            window_pfd.cStencilBits,
        });
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
    const vendor = glString(get_string, gl.c.GL_VENDOR);
    const renderer = glString(get_string, gl.c.GL_RENDERER);
    log.info("{t} OpenGL {d}.{d} vendor={s} renderer={s}", .{
        kind,
        version.major,
        version.minor,
        vendor,
        renderer,
    });
    if (version.major < OpenGL.MIN_VERSION_MAJOR or
        (version.major == OpenGL.MIN_VERSION_MAJOR and version.minor < OpenGL.MIN_VERSION_MINOR))
    {
        return error.OpenGLOutdated;
    }

    lib.version = version;
    lib.vendor_len = copyText(&lib.vendor_buf, vendor);
    lib.renderer_len = copyText(&lib.renderer_buf, renderer);
    return lib;
}

/// Copy `text` into `buf`, cut at a character boundary when it is longer;
/// returns the number of bytes copied.
fn copyText(buf: []u8, text: []const u8) u8 {
    var len = @min(text.len, buf.len, std.math.maxInt(u8));
    while (len < text.len and len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
    @memcpy(buf[0..len], text[0..len]);
    return @intCast(len);
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

pub const Version = struct { major: u32, minor: u32 };

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

test "bell border failure latch resets with the context without touching GUI state" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var context: Context = .{ .surface = undefined, .hdc = undefined, .vsync = false, .border_failed = true };
    context.border(.{ .r = 20, .g = 40, .b = 60, .width = 1, .active = true }, .{ .width = 8, .height = 8 });
    try std.testing.expect(context.border_failed);
    try std.testing.expect(context.border_pass == null);
    const device: Device = .{ .state = .init(.unavailable), .owner_thread = std.Thread.getCurrentId() };
    context.threadExit(&device);
    try std.testing.expect(!context.border_failed);
}

test "native bell border hidden FBO pixels state restore and context rebuild" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_BELL_BORDER_NATIVE"), null, 0) == 0) return error.SkipZigTest;
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    const outcome = NativeBellBorder.run(&report.writer, .none);
    try report.writer.print("outcome={s} last_error={}\n", .{ if (outcome) |_| "PASS" else |err| @errorName(err), windows.GetLastError() });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".local");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = if (softwareRequested()) ".local/native-border-software.txt" else ".local/native-border-system.txt",
        .data = report.written(),
    });
    try outcome;
}

test "native bell border fixture first enter failure has no GLAD unload" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_BELL_BORDER_NATIVE"), null, 0) == 0) return error.SkipZigTest;
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    gl.glad.context = undefined;
    try std.testing.expectError(error.WglCreateContextFailed, NativeBellBorder.run(&report.writer, .first_enter));
}

test "native bell border fixture reenter failure after unload has no second unload" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_BELL_BORDER_NATIVE"), null, 0) == 0) return error.SkipZigTest;
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expectError(error.WglCreateContextFailed, NativeBellBorder.run(&report.writer, .reenter));
}

test "native bell border fixture failed loads release only entered contexts" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_BELL_BORDER_NATIVE"), null, 0) == 0) return error.SkipZigTest;
    for ([_]NativeBellBorder.Fault{ .first_load, .reload }) |fault| {
        var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer report.deinit();
        try std.testing.expectError(error.GLInitFailed, NativeBellBorder.run(&report.writer, fault));
    }
}

const NativeBellBorder = struct {
    const Fault = enum { none, first_enter, first_load, reenter, reload };

    fn rejectContext(_: HDC, _: ?HGLRC, _: [*]const c_int) callconv(.winapi) ?HGLRC {
        return null;
    }

    fn rejectProc(_: [*:0]const u8) callconv(.c) ?GlProc {
        return null;
    }

    fn run(report: *std.Io.Writer, fault: Fault) !void {
        const kind: Lib.Kind = if (softwareRequested()) .software else .system;
        const lib = try probe(kind);
        defer _ = FreeLibrary(lib.module);
        try report.print("kind={t} vendor={s} renderer={s} version={}.{} hidden=true shown=false activated=false\n", .{
            kind, lib.vendor_buf[0..lib.vendor_len], lib.renderer_buf[0..lib.renderer_len], lib.version.major, lib.version.minor,
        });
        const instance = GetModuleHandleW(null);
        const name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBellBorderNative");
        const class: WNDCLASSEXW = .{ .style = CS_OWNDC, .lpfnWndProc = &DefWindowProcW, .hInstance = instance, .lpszClassName = name };
        if (RegisterClassExW(&class) == 0) return error.RegisterClassFailed;
        defer _ = UnregisterClassW(name, instance);
        const hwnd = CreateWindowExW(0, name, name, WS_OVERLAPPEDWINDOW, 0, 0, 32, 32, null, null, instance, null) orelse return error.CreateWindowFailed;
        defer _ = DestroyWindow(hwnd);
        const hdc = GetDC(hwnd) orelse return error.GetDCFailed;
        defer _ = ReleaseDC(hwnd, hdc);
        var device: Device = .{ .lib = lib, .state = .init(.ready), .owner_thread = std.Thread.getCurrentId() };
        if (fault == .first_enter) device.lib.createContextAttribs = &rejectContext;
        try device.setPixelFormat(hdc);
        var surface: apprt.Surface = .{ .app = undefined, .hdc = @ptrCast(hdc) };
        const snapshot: bell_border.Snapshot = .{ .r = 211, .g = 159, .b = 62, .width = 1, .active = true };
        surface.bell_border_snapshot.store(@bitCast(snapshot), .release);
        var context = try Context.init(&surface, false);
        defer context.deinit();
        var entered = false;
        var loaded = false;
        defer {
            if (entered) context.threadExit(&device);
            if (loaded) gl.glad.unload();
        }
        try context.threadEnter(&device);
        entered = true;
        _ = if (fault == .first_load) try gl.glad.load(&rejectProc) else try gl.glad.load(&getProcAddress);
        loaded = true;
        for ([_]Size{ .{ .width = 13, .height = 11 }, .{ .width = 1, .height = 1 }, .{ .width = 2, .height = 3 }, .{ .width = 1, .height = 7 } }) |size| {
            for ([_]u7{ 1, 2, 127 }) |width| {
                var current = snapshot;
                current.width = width;
                try drawCase(&context, current, size, report);
            }
        }
        var themed = snapshot;
        themed.r = 17;
        themed.g = 112;
        themed.b = 226;
        themed.width = 2;
        try drawCase(&context, themed, .{ .width = 13, .height = 11 }, report);
        try drawCase(&context, .none, .{ .width = 13, .height = 11 }, report);
        gl.glad.context.Enable.?(std.math.maxInt(gl.c.GLenum));
        context.border(snapshot, .{ .width = 13, .height = 11 });
        try std.testing.expect(context.border_failed);
        context.border(snapshot, .{ .width = 13, .height = 11 });
        try std.testing.expect(context.border_failed);
        try report.writeAll("failure_latched=true retry_suppressed=true\n");
        context.threadExit(&device);
        entered = false;
        gl.glad.unload();
        loaded = false;
        try std.testing.expect(context.border_pass == null);
        try std.testing.expect(!context.border_failed);
        try std.testing.expectEqual(snapshot, surface.bellBorder());
        if (fault == .reenter) device.lib.createContextAttribs = &rejectContext;
        try context.threadEnter(&device);
        entered = true;
        _ = if (fault == .reload) try gl.glad.load(&rejectProc) else try gl.glad.load(&getProcAddress);
        loaded = true;
        try drawCase(&context, surface.bellBorder(), .{ .width = 13, .height = 11 }, report);
        try report.writeAll("context_recreated=true ringing_preserved=true pass_rebuilt=true\n");
    }

    fn extraState() [12]gl.c.GLint {
        var result: [12]gl.c.GLint = undefined;
        const ctx = &gl.glad.context;
        ctx.GetIntegerv.?(gl.c.GL_SCISSOR_BOX, @ptrCast(&result));
        for ([_]gl.c.GLenum{
            gl.c.GL_BLEND_SRC_RGB,      gl.c.GL_BLEND_DST_RGB,        gl.c.GL_BLEND_SRC_ALPHA,          gl.c.GL_BLEND_DST_ALPHA,
            gl.c.GL_BLEND_EQUATION_RGB, gl.c.GL_BLEND_EQUATION_ALPHA, gl.c.GL_DRAW_FRAMEBUFFER_BINDING, gl.c.GL_READ_FRAMEBUFFER_BINDING,
        }, result[4..]) |parameter, *value| ctx.GetIntegerv.?(parameter, value);
        return result;
    }

    fn drawCase(context: *Context, snapshot: bell_border.Snapshot, size: Size, report: *std.Io.Writer) !void {
        const ctx = &gl.glad.context;
        var framebuffer: gl.c.GLuint = 0;
        var storage: gl.c.GLuint = 0;
        ctx.GenFramebuffers.?(1, &framebuffer);
        defer ctx.DeleteFramebuffers.?(1, &framebuffer);
        ctx.GenRenderbuffers.?(1, &storage);
        defer ctx.DeleteRenderbuffers.?(1, &storage);
        ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, framebuffer);
        ctx.BindRenderbuffer.?(gl.c.GL_RENDERBUFFER, storage);
        ctx.RenderbufferStorage.?(gl.c.GL_RENDERBUFFER, gl.c.GL_RGBA8, @intCast(size.width), @intCast(size.height));
        ctx.FramebufferRenderbuffer.?(gl.c.GL_FRAMEBUFFER, gl.c.GL_COLOR_ATTACHMENT0, gl.c.GL_RENDERBUFFER, storage);
        try std.testing.expectEqual(@as(gl.c.GLenum, gl.c.GL_FRAMEBUFFER_COMPLETE), ctx.CheckFramebufferStatus.?(gl.c.GL_FRAMEBUFFER));
        for (BorderDrawState.capabilities) |cap| ctx.Disable.?(cap);
        ctx.Disable.?(gl.c.GL_FRAMEBUFFER_SRGB);
        ctx.ColorMask.?(gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
        const sentinel = try DimPass.init();
        defer sentinel.deinit();
        _ = try sentinel.program.use();
        _ = try sentinel.vao.bind();
        try gl.viewport(3, 2, 5, 4);
        for (BorderDrawState.capabilities) |cap| ctx.Enable.?(cap);
        ctx.Scissor.?(4, 3, 1, 1);
        ctx.BlendFuncSeparate.?(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA, gl.c.GL_ONE, gl.c.GL_ZERO);
        ctx.BlendEquationSeparate.?(gl.c.GL_FUNC_REVERSE_SUBTRACT, gl.c.GL_MAX);
        ctx.ColorMask.?(gl.c.GL_FALSE, gl.c.GL_TRUE, gl.c.GL_FALSE, gl.c.GL_FALSE);
        const before = BorderDrawState.capture();
        const extra_before = extraState();
        context.border(snapshot, size);
        try std.testing.expect(!context.border_failed);
        try std.testing.expectEqualDeep(before, BorderDrawState.capture());
        try std.testing.expectEqualDeep(extra_before, extraState());
        var bytes: [13 * 11 * 4]u8 = undefined;
        ctx.PixelStorei.?(gl.c.GL_PACK_ALIGNMENT, 1);
        ctx.ReadPixels.?(0, 0, @intCast(size.width), @intCast(size.height), gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, &bytes);
        try gl.errors.getError();
        for (0..size.height) |y| {
            for (0..size.width) |x| {
                const offset = (y * size.width + x) * 4;
                const expected: [4]u8 = if (snapshot.active and bell_border.covers(size.width, size.height, snapshot.width, @intCast(x), @intCast(y)))
                    .{ snapshot.r, snapshot.g, snapshot.b, 255 }
                else
                    .{ 0, 0, 0, 0 };
                try std.testing.expectEqualSlices(u8, &expected, bytes[offset..][0..4]);
            }
        }
        try report.print("FBO={}x{} padding=0 requested={} active={} four_edges={} alpha=255 center_unchanged=true restore=true samples={x}\n", .{
            size.width, size.height, snapshot.width, snapshot.active, snapshot.active, bytes[0..@min(@as(usize, size.width) * size.height * 4, 32)],
        });
        ctx.UseProgram.?(0);
        ctx.BindVertexArray.?(0);
        for (BorderDrawState.capabilities) |cap| ctx.Disable.?(cap);
        ctx.ColorMask.?(gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE);
        ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);
    }
};

test "native bell border idle worker publication reaches present without output or animation" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_BELL_BORDER_NATIVE"), null, 0) == 0) return error.SkipZigTest;
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    const outcome = NativeBellWorker.run(&report.writer);
    try report.writer.print("outcome={s}\n", .{if (outcome) |_| "PASS" else |err| @errorName(err)});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".local");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = if (softwareRequested()) ".local/native-bell-worker-software.txt" else ".local/native-bell-worker-system.txt",
        .data = report.written(),
    });
    try outcome;
}

const NativeBellWorker = struct {
    const rendererpkg = @import("../../renderer.zig");
    const font = @import("../../font/main.zig");
    const configpkg = @import("../../config.zig");
    const terminalpkg = @import("../../terminal/main.zig");
    const CoreApp = @import("../../App.zig");
    const WinApp = @import("../../apprt/win32/App.zig");
    const WinWindow = @import("../../apprt/win32/Window.zig");
    const win32 = @import("../../apprt/win32/win32.zig");
    const xev = global.xev;
    const width = 64;
    const height = 48;
    const gl_callconv = @typeInfo(@typeInfo(@typeInfo(gl.c.PFNGLBINDFRAMEBUFFERPROC).optional.child).pointer.child).@"fn".calling_convention;

    thread: *rendererpkg.Thread,
    renderer: *rendererpkg.Renderer,
    surface: *apprt.Surface,
    native_lib: *const Lib,
    sink: gl.c.GLuint = 0,
    storage: gl.c.GLuint = 0,
    bind_framebuffer: gl.c.PFNGLBINDFRAMEBUFFERPROC = null,
    frames: std.atomic.Value(u32) = .init(0),
    snapshot_lock: std.Io.Mutex = .init,
    pixels: [width * height * 4]u8 = undefined,
    audit: Audit = .{},
    control: xev.Async,
    control_c: xev.Completion = .{},
    ack: windows.HANDLE,

    const Audit = struct {
        updates: usize = 0,
        cells_rebuilt: bool = true,
        animation: bool = true,
        cursor_timer: bool = true,
        swap_chain: bool = false,
    };

    threadlocal var current: ?*NativeBellWorker = null;

    fn loadProc(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque {
        const self = current orelse return null;
        const proc = self.native_lib.getProcAddress(name) orelse return null;
        if (std.mem.eql(u8, std.mem.span(name), "glBindFramebuffer")) {
            self.bind_framebuffer = @ptrCast(proc);
            return @ptrCast(&bindFramebuffer);
        }
        return proc;
    }

    // Only the test worker maps framebuffer zero to an owned RGBA8 FBO.
    fn bindFramebuffer(target: gl.c.GLenum, id: gl.c.GLuint) callconv(gl_callconv) void {
        const self = current.?;
        if (id == 0 and self.sink == 0) {
            const ctx = &gl.glad.context;
            ctx.GenFramebuffers.?(1, &self.sink);
            self.bind_framebuffer.?(gl.c.GL_FRAMEBUFFER, self.sink);
            ctx.GenRenderbuffers.?(1, &self.storage);
            ctx.BindRenderbuffer.?(gl.c.GL_RENDERBUFFER, self.storage);
            ctx.RenderbufferStorage.?(gl.c.GL_RENDERBUFFER, gl.c.GL_RGBA8, width, height);
            ctx.FramebufferRenderbuffer.?(gl.c.GL_FRAMEBUFFER, gl.c.GL_COLOR_ATTACHMENT0, gl.c.GL_RENDERBUFFER, self.storage);
        }
        self.bind_framebuffer.?(target, if (id == 0) self.sink else id);
    }

    fn swap(_: HDC) callconv(.winapi) BOOL {
        const self = current.?;
        const ctx = &gl.glad.context;
        var old_read: gl.c.GLint = 0;
        ctx.GetIntegerv.?(gl.c.GL_READ_FRAMEBUFFER_BINDING, &old_read);
        self.bind_framebuffer.?(gl.c.GL_READ_FRAMEBUFFER, self.sink);
        self.snapshot_lock.lockUncancelable(global.io());
        ctx.ReadPixels.?(0, 0, width, height, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, &self.pixels);
        self.snapshot_lock.unlock(global.io());
        self.bind_framebuffer.?(gl.c.GL_READ_FRAMEBUFFER, @intCast(old_read));
        gl.finish();
        const result: BOOL = if (gl.errors.getError()) .TRUE else |_| .FALSE;
        if (result.toBool()) _ = self.frames.fetchAdd(1, .release);
        return result;
    }

    fn workerMain(self: *NativeBellWorker) void {
        current = self;
        defer current = null;
        self.control.wait(&self.thread.loop, &self.control_c, NativeBellWorker, self, auditCallback);
        self.thread.threadMain();
    }

    fn auditCallback(self_: ?*NativeBellWorker, _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
        result catch return .rearm;
        const self = self_.?;
        self.snapshot_lock.lockUncancelable(global.io());
        self.audit = .{
            .updates = self.renderer.terminal_state_frame_count,
            .cells_rebuilt = self.renderer.cells_rebuilt,
            .animation = self.renderer.animationWake() != null,
            .cursor_timer = self.thread.cursor_c.state() == .active,
            .swap_chain = self.renderer.swap_chain != null,
        };
        self.snapshot_lock.unlock(global.io());
        _ = win32.SetEvent(self.ack);
        return .rearm;
    }

    fn checkIdle(self: *NativeBellWorker) !Audit {
        _ = win32.ResetEvent(self.ack);
        try self.control.notify();
        if (win32.WaitForSingleObject(self.ack, 2000) != win32.WAIT_OBJECT_0) return error.WorkerAuditTimeout;
        self.snapshot_lock.lockUncancelable(global.io());
        defer self.snapshot_lock.unlock(global.io());
        try std.testing.expect(!self.audit.cells_rebuilt);
        try std.testing.expect(!self.audit.animation);
        try std.testing.expect(!self.audit.cursor_timer);
        try std.testing.expect(self.audit.swap_chain);
        return self.audit;
    }

    fn awaitFrame(self: *NativeBellWorker, count: u32, report: *std.Io.Writer) !void {
        for (0..200) |_| {
            if (self.frames.load(.acquire) >= count) return;
            try std.Io.sleep(global.io(), .fromMilliseconds(10), .awake);
        }
        try report.print("notification timeout: wanted={} observed={}\n", .{ count, self.frames.load(.acquire) });
        return error.BellPublicationDidNotPresent;
    }

    fn checkPixels(self: *NativeBellWorker, snapshot: bell_border.Snapshot, report: *std.Io.Writer, label: []const u8) !void {
        self.snapshot_lock.lockUncancelable(global.io());
        defer self.snapshot_lock.unlock(global.io());
        for (0..height) |y| {
            for (0..width) |x| {
                const edge = snapshot.active and bell_border.covers(width, height, snapshot.width, @intCast(x), @intCast(y));
                const wanted: [4]u8 = if (edge) .{ snapshot.r, snapshot.g, snapshot.b, 255 } else .{ 0, 0, 0, 0 };
                try std.testing.expectEqualSlices(u8, &wanted, self.pixels[(y * width + x) * 4 ..][0..4]);
            }
        }
        try report.print("{s}: presents={} updates={} active={} RGBA={x} native_pixels=true\n", .{
            label, self.frames.load(.acquire), self.audit.updates, snapshot.active, self.pixels[0..16],
        });
    }

    fn run(report: *std.Io.Writer) !void {
        const alloc = std.testing.allocator;
        const lib = try probe(if (softwareRequested()) .software else .system);
        defer _ = FreeLibrary(lib.module);
        try report.print("vendor={s} renderer={s} hidden=true no_output=true sink=RGBA8 test_only_framebuffer_zero_mapping=true completion=native-glFinish/readPixels NOT-desktop-SwapBuffers\n", .{
            lib.vendor_buf[0..lib.vendor_len], lib.renderer_buf[0..lib.renderer_len],
        });
        const instance = GetModuleHandleW(null);
        const name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBellWorkerNative");
        const class: WNDCLASSEXW = .{ .style = CS_OWNDC, .lpfnWndProc = &DefWindowProcW, .hInstance = instance, .lpszClassName = name };
        if (RegisterClassExW(&class) == 0) return error.RegisterClassFailed;
        defer _ = UnregisterClassW(name, instance);
        const hwnd = CreateWindowExW(0, name, name, 0x80000000, 0, 0, width, height, null, null, instance, null) orelse return error.CreateWindowFailed;
        defer _ = DestroyWindow(hwnd);
        const hdc = GetDC(hwnd) orelse return error.GetDCFailed;
        defer _ = ReleaseDC(hwnd, hdc);
        var device: Device = .{ .lib = lib, .state = .init(.ready), .owner_thread = std.Thread.getCurrentId() };
        try device.setPixelFormat(hdc);
        device.lib.getProcAddress = &loadProc;
        device.lib.swapBuffers = &swap;
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        config.@"bell-features".border = true;
        config.@"window-vsync" = false;
        config.@"background-opacity" = 0;
        config.@"scrollback-compression" = false;
        config.scrollbar = .never;
        config.background = .{ .r = 0, .g = 0, .b = 0 };
        var mailbox: CoreApp.Mailbox.Queue = .{};
        var app: WinApp = .{ .core_app = undefined, .config = config, .hinstance = undefined, .default_command_arena = .init(alloc) };
        defer app.default_command_arena.deinit();
        var window: WinWindow = .{ .app = &app };
        const surface = try alloc.create(apprt.Surface);
        defer alloc.destroy(surface);
        surface.* = .{ .app = &app, .parent_window = &window, .hdc = @ptrCast(hdc), .width = width, .height = height, .core_surface_ready = true };
        surface.core_surface.focused = false;
        surface.client_size.store(@as(u64, height) << 32 | width, .release);
        surface.bell_border_state.configure(true);
        surface.bell_border_color = .{ .r = 211, .g = 159, .b = 62 };
        var terminal = try terminalpkg.Terminal.init(std.testing.io, alloc, .{ .cols = 4, .rows = 2, .max_scrollback_bytes = null });
        defer terminal.deinit(alloc);
        terminal.modes.set(.cursor_visible, false);
        var mutex: std.Io.Mutex = .init;
        var state: rendererpkg.State = .{ .mutex = &mutex, .terminal = &terminal };
        surface.core_surface.renderer_state = state;
        var library = try font.Library.init(alloc);
        defer library.deinit();
        var collection = font.Collection.init();
        collection.load_options = .{ .library = library };
        _ = try collection.add(alloc, try font.Face.init(library, font.embedded.regular, .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } }), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
        var grid = try font.SharedGrid.init(alloc, .{ .collection = collection });
        defer grid.deinit(alloc);
        const render = try alloc.create(rendererpkg.Renderer);
        defer alloc.destroy(render);
        render.* = try rendererpkg.Renderer.init(alloc, .{
            .device = &device,
            .config = try .init(alloc, &config),
            .font_grid = &grid,
            .size = .{ .screen = .{ .width = width, .height = height }, .cell = grid.cellSize(), .padding = .{} },
            .surface_mailbox = .{ .surface = &surface.core_surface, .app = .{ .rt_app = &app, .mailbox = &mailbox } },
            .rt_surface = surface,
            .thread = &surface.core_surface.renderer_thread,
        });
        defer render.deinit();
        const thread = &surface.core_surface.renderer_thread;
        thread.* = try rendererpkg.Thread.init(alloc, &config, surface, render, &state);
        defer thread.deinit();
        _ = thread.mailbox.push(global.io(), .{ .focus = false }, .instant);
        var control = try xev.Async.init();
        defer control.deinit();
        const ack = win32.CreateEventW(null, 1, 0, null) orelse return error.Win32Error;
        defer _ = win32.CloseHandle(ack);
        var worker: NativeBellWorker = .{ .thread = thread, .renderer = render, .surface = surface, .native_lib = &lib, .control = control, .ack = @ptrCast(ack) };
        const native_thread = try std.Thread.spawn(.{}, workerMain, .{&worker});
        defer {
            thread.stop.notify() catch {};
            native_thread.join();
        }
        try worker.awaitFrame(1, report);
        const before = try worker.checkIdle();
        try worker.checkPixels(.none, report, "completed-idle-frame");
        try std.Io.sleep(global.io(), .fromMilliseconds(700), .awake);
        try std.testing.expectEqual(@as(u32, 1), worker.frames.load(.acquire));
        surface.ringBellBorder();
        try worker.awaitFrame(2, report);
        const ring = try worker.checkIdle();
        try std.testing.expect(ring.updates > before.updates);
        try worker.checkPixels(surface.bellBorder(), report, "ring-notification");
        surface.ringBellBorder();
        try std.Io.sleep(global.io(), .fromMilliseconds(100), .awake);
        try std.testing.expectEqual(@as(u32, 2), worker.frames.load(.acquire));
        surface.bell_border_color = .{ .r = 17, .g = 112, .b = 226 };
        surface.ringBellBorder();
        try worker.awaitFrame(3, report);
        const recolor = try worker.checkIdle();
        try std.testing.expect(recolor.updates > ring.updates);
        try worker.checkPixels(surface.bellBorder(), report, "color-notification");
        surface.handleKeyEvent(win32.VK_PACKET, 0, .press);
        try worker.awaitFrame(4, report);
        const clear = try worker.checkIdle();
        try std.testing.expect(clear.updates > recolor.updates);
        try worker.checkPixels(.none, report, "clear-notification");
        try report.writeAll("actual_chain=Surface-publication/xev-wakeup/Thread/updateFrame/rebuildCells/drawFrame/OpenGL-present/WGL-present/native-GL no_direct_border_call=true\n");
    }
};

test parseVersion {
    const testing = std.testing;
    try testing.expectEqual(Version{ .major = 4, .minor = 6 }, parseVersion("4.6.0 NVIDIA 555.85"));
    try testing.expectEqual(Version{ .major = 4, .minor = 5 }, parseVersion("4.5 (Core Profile) Mesa 24.2.0"));
    try testing.expectEqual(Version{ .major = 0, .minor = 0 }, parseVersion(""));
}

test "Device.backend reports what the probe saw" {
    const testing = std.testing;
    var device: Device = .{ .state = .init(.ready), .owner_thread = std.Thread.getCurrentId() };
    device.lib.software = true;
    device.lib.alpha = false;
    device.lib.version = .{ .major = 4, .minor = 5 };
    device.lib.vendor_len = copyText(&device.lib.vendor_buf, "Mesa");
    device.lib.renderer_len = copyText(&device.lib.renderer_buf, "llvmpipe (LLVM 19.1.7, 256 bits)");
    try device.wait();
    const backend = device.backend();
    try testing.expectEqualStrings("Mesa", backend.vendor);
    try testing.expectEqualStrings("llvmpipe (LLVM 19.1.7, 256 bits)", backend.renderer);
    try testing.expectEqual(Version{ .major = 4, .minor = 5 }, backend.version);
    try testing.expect(backend.software);
    try testing.expectEqual(Device.AlphaFrames.software, device.alphaFrames());

    // Long strings are cut at a character boundary.
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("1234567", buf[0..copyText(&buf, "1234567\u{00E9}")]);
    try testing.expectEqualStrings("12345678", buf[0..copyText(&buf, "123456789")]);
    try testing.expectEqualStrings("", buf[0..copyText(&buf, "")]);
}

test "Device.wait publishes a completed probe and joins once" {
    const testing = std.testing;
    const Probe = struct {
        fn finish(device: *Device) void {
            device.lib.software = false;
            device.lib.alpha = true;
            device.lib.version = .{ .major = 4, .minor = 6 };
            device.lib.vendor_len = copyText(&device.lib.vendor_buf, "Test vendor");
            device.lib.renderer_len = copyText(&device.lib.renderer_buf, "Test renderer");
            device.state.store(.ready, .release);
            global.io().futexWake(Device.State, &device.state.raw, std.math.maxInt(u32));
        }
    };
    var device: Device = .{ .owner_thread = std.Thread.getCurrentId() };
    device.thread = try std.Thread.spawn(.{}, Probe.finish, .{&device});
    defer if (device.thread) |thread| thread.join();
    try device.wait();
    try testing.expect(device.thread == null);
    try testing.expectEqualStrings("Test vendor", device.backend().vendor);
    try testing.expectEqualStrings("Test renderer", device.backend().renderer);
    try testing.expectEqual(Version{ .major = 4, .minor = 6 }, device.backend().version);
    try testing.expectEqual(Device.AlphaFrames.supported, device.alphaFrames());
    try device.wait();
}

test "Device.wait waits for the probe thread and reports a missing OpenGL" {
    const testing = std.testing;
    const Probe = struct {
        fn finish(device: *Device) void {
            std.Io.sleep(global.io(), .fromMilliseconds(20), .awake) catch {};
            device.state.store(.unavailable, .release);
            global.io().futexWake(Device.State, &device.state.raw, std.math.maxInt(u32));
        }
    };
    var device: Device = .{ .owner_thread = std.Thread.getCurrentId() };
    device.thread = try std.Thread.spawn(.{}, Probe.finish, .{&device});

    try testing.expectEqual(Device.AlphaFrames.no_alpha_channel, device.alphaFrames());
    try testing.expectEqualStrings("", device.backend().renderer);
    var hdc: u8 = 0;
    try testing.expectError(error.OpenGLUnavailable, device.setPixelFormat(&hdc));
    try testing.expectError(error.OpenGLUnavailable, device.wait());
    try testing.expect(device.thread == null);
    try testing.expectError(error.OpenGLUnavailable, device.wait());
    try testing.expectError(error.OpenGLUnavailable, device.setPixelFormat(&hdc));
    device.deinit();
}

test "Device.init defers probe thread startup failures to wait" {
    const testing = std.testing;
    for ([_]std.Thread.SpawnError{ error.ThreadQuotaExceeded, error.SystemResources, error.OutOfMemory }) |err| {
        Device.tw_spawn.errorAlways(.spawn, err);
        defer Device.tw_spawn.reset();
        var device: Device = undefined;
        try device.init(testing.allocator);
        defer device.deinit();
        try Device.tw_spawn.end(.reset);
        try testing.expectEqual(std.Thread.getCurrentId(), device.owner_thread);
        try testing.expectEqual(Device.State.unavailable, device.state.load(.acquire));
        try testing.expect(device.thread == null);
        try testing.expectError(error.OpenGLUnavailable, device.wait());
        try testing.expectError(error.OpenGLUnavailable, device.wait());
    }
}

test "Device accessors wait from another thread without taking join ownership" {
    const testing = std.testing;
    const Reader = struct {
        fn read(device: *Device, thread_differs: *bool) void {
            thread_differs.* = std.Thread.getCurrentId() != device.owner_thread;
            _ = device.backend();
            _ = device.alphaFrames();
        }
    };
    var device: Device = .{ .state = .init(.unavailable), .owner_thread = std.Thread.getCurrentId() };
    defer device.deinit();
    var thread_differs = false;
    device.thread = try std.Thread.spawn(.{}, Reader.read, .{ &device, &thread_differs });
    try testing.expectError(error.OpenGLUnavailable, device.wait());
    try testing.expect(thread_differs);
    try testing.expect(device.thread == null);
}

test "frameBlit and edgeFills cover the window once" {
    const testing = std.testing;
    const cases = [_]struct { frame: Size, window: Size }{
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 4, .height = 3 } },
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 7, .height = 3 } },
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 4, .height = 5 } },
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 6, .height = 6 } },
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 2, .height = 2 } },
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 6, .height = 2 } },
        .{ .frame = .{ .width = 4, .height = 3 }, .window = .{ .width = 3, .height = 5 } },
        .{ .frame = .{ .width = 1, .height = 1 }, .window = .{ .width = 3, .height = 2 } },
    };
    for (cases) |case| {
        const fw: i32 = @intCast(case.frame.width);
        const fh: i32 = @intCast(case.frame.height);
        const ww: i32 = @intCast(case.window.width);
        const wh: i32 = @intCast(case.window.height);
        var blits: [4]Blit = undefined;
        blits[0] = frameBlit(case.frame, case.window);
        const fills = edgeFills(case.frame, case.window);
        @memcpy(blits[1..][0..fills.len], fills.slice());
        const all = blits[0 .. 1 + fills.len];

        // Each window pixel is written exactly once, from a frame pixel
        // that the nearest-filter scaling maps it to.
        var y: i32 = 0;
        while (y < wh) : (y += 1) {
            var x: i32 = 0;
            while (x < ww) : (x += 1) {
                var hits: usize = 0;
                for (all) |b| {
                    if (x < b.dst.x0 or x >= b.dst.x1 or y < b.dst.y0 or y >= b.dst.y1) continue;
                    hits += 1;
                    try testing.expect(b.src.x0 >= 0 and b.src.x1 <= fw and b.src.x0 < b.src.x1);
                    try testing.expect(b.src.y0 >= 0 and b.src.y1 <= fh and b.src.y0 < b.src.y1);
                }
                try testing.expectEqual(@as(usize, 1), hits);
            }
        }
    }

    // The frame is anchored at the top: GL counts rows from the bottom.
    try testing.expectEqual(Blit{
        .src = .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 3 },
        .dst = .{ .x0 = 0, .y0 = 2, .x1 = 4, .y1 = 5 },
    }, frameBlit(.{ .width = 4, .height = 3 }, .{ .width = 6, .height = 5 }));

    // A larger window stretches the last column, the last row and the
    // corner pixel; a window of the frame's size needs nothing more.
    const fills = edgeFills(.{ .width = 4, .height = 3 }, .{ .width = 6, .height = 5 });
    try testing.expectEqualSlices(Blit, &.{
        .{ .src = .{ .x0 = 3, .y0 = 0, .x1 = 4, .y1 = 3 }, .dst = .{ .x0 = 4, .y0 = 2, .x1 = 6, .y1 = 5 } },
        .{ .src = .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 1 }, .dst = .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 2 } },
        .{ .src = .{ .x0 = 3, .y0 = 0, .x1 = 4, .y1 = 1 }, .dst = .{ .x0 = 4, .y0 = 0, .x1 = 6, .y1 = 2 } },
    }, fills.slice());
    try testing.expectEqual(@as(usize, 0), edgeFills(.{ .width = 4, .height = 3 }, .{ .width = 4, .height = 3 }).len);
    try testing.expectEqual(@as(usize, 0), edgeFills(.{ .width = 0, .height = 0 }, .{ .width = 4, .height = 3 }).len);
}

test "dimColor scales the premultiplied dim for the shader" {
    const testing = std.testing;
    try testing.expectEqual(@as(?[4]f32, null), dimColor(0, 0, 0, 0));
    try testing.expectEqual(@as(?[4]f32, .{ 0, 0, 0, 1 }), dimColor(0, 0, 0, 255));
    const color = dimColor(9, 9, 14, 77).?;
    try testing.expectApproxEqAbs(@as(f32, 9.0 / 255.0), color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 14.0 / 255.0), color[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 77.0 / 255.0), color[3], 1e-6);
}

test "leanestPixelFormat prefers formats without depth and stencil" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 2), leanestPixelFormat(&.{
        .{ .depth = 24, .stencil = 8 },
        .{ .depth = 0, .stencil = 8 },
        .{ .depth = 0, .stencil = 0 },
        .{ .depth = 0, .stencil = 0 },
    }));
    try testing.expectEqual(@as(usize, 0), leanestPixelFormat(&.{
        .{ .depth = 24, .stencil = 8 },
        DepthStencil.unknown,
    }));
    try testing.expectEqual(@as(usize, 0), leanestPixelFormat(&.{.{ .depth = 0, .stencil = 0 }}));
}

test "llvmpipe threads are limited on machines with more CPUs" {
    const testing = std.testing;
    try testing.expect(!limitsLlvmpipeThreads(0));
    try testing.expect(!limitsLlvmpipeThreads(llvmpipe_max_threads));
    try testing.expect(limitsLlvmpipeThreads(llvmpipe_max_threads + 1));
    try testing.expect(limitsLlvmpipeThreads(32));
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

const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_TYPE_RGBA = 0;

const CS_OWNDC = 0x0020;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
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
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) BOOL;
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

extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn DescribePixelFormat(hdc: HDC, iPixelFormat: c_int, nBytes: u32, ppfd: ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
