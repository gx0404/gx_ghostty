//! The DMABUF export of the OpenGL renderer once it cannot work (fork
//! patch GX-0029, used by `src/renderer/OpenGL.zig::present`).
//!
//! While the app runtime can present DMABUFs (GTK), upstream exports every
//! frame as a DMABUF and, when that fails, logs a warning, reads the frame
//! back into CPU memory and tries again with the next frame. An EGL display
//! without `EGL_MESA_image_dma_buf_export` fails every time: Mesa's
//! software renderer on a surfaceless display (Xvfb, machines without a
//! GPU) pays for a full-frame blit and an EGLImage and logs a warning for
//! every frame before the readback. `Export` keeps a renderer from trying
//! again once exporting cannot work: its first frame checks the extension,
//! and `max_failures` failed exports in a row switch exporting off for the
//! life of the renderer. The first renderer of the process that switches
//! exporting off logs one warning naming the GL renderer; frames are then
//! read back without a warning.
//!
//! The state belongs to one renderer and is only used on its render thread.
const std = @import("std");

const log = std.log.scoped(.opengl);

/// The EGL display extension that exporting needs.
pub const extension = "EGL_MESA_image_dma_buf_export";

/// Failed exports in a row that switch exporting off.
pub const max_failures = 3;

/// Set by the first renderer that switches exporting off, the one that
/// warns.
var warned: std.atomic.Value(bool) = .init(false);

/// The DMABUF export state of one renderer. `gl` is the `opengl` package
/// (`pkg/opengl`); the warning names its GL renderer.
pub fn Export(comptime gl: type) type {
    return struct {
        const Self = @This();

        state: State = .unchecked,

        /// Failed exports since the last exported frame.
        failures: u8 = 0,

        pub const State = enum {
            /// No frame asked yet.
            unchecked,
            on,
            off,
        };

        /// Whether to export this frame. The first call checks the
        /// extensions of `display`, the EGL display of the renderer.
        pub fn enabled(self: *Self, display: anytype) bool {
            if (self.state == .unchecked and
                !self.check(display.queryString(.extensions) orelse ""))
            {
                switchedOff("the EGL display does not support {s}", .{extension});
            }
            return self.state == .on;
        }

        /// Passes on `result`, what an export returned, after recording
        /// it: an exported frame resets the count of failures in a row.
        pub fn track(self: *Self, result: anytype) @TypeOf(result) {
            if (result) |_| {
                self.failures = 0;
            } else |err| {
                self.failed(err);
            }
            return result;
        }

        fn failed(self: *Self, err: anyerror) void {
            if (self.count()) {
                switchedOff("{d} failures in a row, the last err={}", .{ self.failures, err });
            } else {
                log.debug("DMABUF export failed err={} ({d} in a row), presenting the frame from CPU memory", .{
                    err,
                    self.failures,
                });
            }
        }

        /// Decides from `extensions`, a space-separated EGL extension
        /// string, whether exporting can work.
        fn check(self: *Self, extensions: []const u8) bool {
            self.state = if (hasExtension(extensions, extension)) .on else .off;
            return self.state == .on;
        }

        /// Counts a failed export; true when it switches exporting off.
        fn count(self: *Self) bool {
            self.failures +|= 1;
            if (self.failures < max_failures) return false;
            self.state = .off;
            return true;
        }

        fn switchedOff(comptime fmt: []const u8, args: anytype) void {
            var buf: [256]u8 = undefined;
            const reason = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
            if (!firstToSwitchOff()) {
                log.debug("DMABUF export off ({s}), presenting frames from CPU memory", .{reason});
                return;
            }
            log.warn("failed to export DMABUF ({s}), presenting frames from CPU memory from now on renderer={s}", .{
                reason,
                rendererName(),
            });
        }

        fn rendererName() []const u8 {
            const get_string = gl.glad.context.GetString orelse return "(unknown)";
            const name: ?[*:0]const u8 = @ptrCast(get_string(gl.c.GL_RENDERER));
            return std.mem.sliceTo(name orelse return "(unknown)", 0);
        }
    };
}

/// Whether the space-separated extension string `extensions` lists `name`.
fn hasExtension(extensions: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, extensions, ' ');
    while (it.next()) |ext| {
        if (std.mem.eql(u8, ext, name)) return true;
    }
    return false;
}

/// True for the first renderer of the process that switches exporting off.
fn firstToSwitchOff() bool {
    return !warned.swap(true, .monotonic);
}

/// Stands in for `pkg/opengl` in tests: no GL context, so no renderer name.
const TestGl = struct {
    pub const c = struct {
        pub const GL_RENDERER = 0x1F01;
    };
    pub const glad = struct {
        pub var context: struct {
            GetString: ?*const fn (c_uint) callconv(.c) [*c]const u8 = null,
        } = .{};
    };
};

const TestDisplay = struct {
    extensions: ?[:0]const u8,
    queries: usize = 0,

    pub fn queryString(self: *TestDisplay, name: enum { vendor, extensions }) ?[:0]const u8 {
        std.debug.assert(name == .extensions);
        self.queries += 1;
        return self.extensions;
    }
};

/// Runs a test as if another renderer had warned already, so that switching
/// exporting off only logs at the debug level.
fn assumeWarned() void {
    warned.store(true, .monotonic);
}

test "a display without the extension never exports" {
    const testing = std.testing;
    const saved = warned.load(.monotonic);
    defer warned.store(saved, .monotonic);
    assumeWarned();

    var display: TestDisplay = .{ .extensions = "EGL_KHR_image_base EGL_EXT_image_dma_buf_import" };
    var state: Export(TestGl) = .{};
    try testing.expect(!state.enabled(&display));
    try testing.expect(!state.enabled(&display));
    try testing.expectEqual(Export(TestGl).State.off, state.state);
    try testing.expectEqual(@as(usize, 1), display.queries);

    var unknown: TestDisplay = .{ .extensions = null };
    var other: Export(TestGl) = .{};
    try testing.expect(!other.enabled(&unknown));
}

test "failures in a row switch exporting off" {
    const testing = std.testing;
    const saved = warned.load(.monotonic);
    defer warned.store(saved, .monotonic);
    assumeWarned();

    var display: TestDisplay = .{ .extensions = "EGL_KHR_image_base " ++ extension ++ " EGL_KHR_fence_sync" };
    var state: Export(TestGl) = .{};
    try testing.expect(state.enabled(&display));

    const failure: error{BadMatch}!u32 = error.BadMatch;
    const success: error{BadMatch}!u32 = 7;
    for (0..max_failures - 1) |_| try testing.expectError(error.BadMatch, state.track(failure));
    try testing.expect(state.enabled(&display));
    try testing.expectEqual(@as(u32, 7), try state.track(success));
    for (0..max_failures - 1) |_| _ = state.track(failure) catch {};
    try testing.expect(state.enabled(&display));
    _ = state.track(failure) catch {};
    try testing.expect(!state.enabled(&display));

    // Exporting stays off; the display is asked only once.
    _ = state.track(success) catch unreachable;
    try testing.expect(!state.enabled(&display));
    try testing.expectEqual(@as(usize, 1), display.queries);
}

test "the extension must be listed by its whole name" {
    const testing = std.testing;
    try testing.expect(hasExtension(extension, extension));
    try testing.expect(hasExtension("  " ++ extension ++ "  EGL_KHR_image_base ", extension));
    try testing.expect(!hasExtension(extension ++ "_v2 EGL_KHR_image_base", extension));
    try testing.expect(!hasExtension("EGL_MESA_image_dma_buf", extension));
    try testing.expect(!hasExtension("", extension));
}

test "the warning names the GL renderer when there is one" {
    const testing = std.testing;
    const saved = TestGl.glad.context;
    defer TestGl.glad.context = saved;

    TestGl.glad.context = .{};
    try testing.expectEqualStrings("(unknown)", Export(TestGl).rendererName());

    const Fake = struct {
        fn getString(name: c_uint) callconv(.c) [*c]const u8 {
            return if (name == TestGl.c.GL_RENDERER) "llvmpipe (LLVM 17.0.6, 256 bits)" else null;
        }
    };
    TestGl.glad.context = .{ .GetString = &Fake.getString };
    try testing.expectEqualStrings("llvmpipe (LLVM 17.0.6, 256 bits)", Export(TestGl).rendererName());
}

test "only the first renderer that switches exporting off warns" {
    const testing = std.testing;
    const saved = warned.load(.monotonic);
    defer warned.store(saved, .monotonic);

    warned.store(false, .monotonic);
    try testing.expect(firstToSwitchOff());
    try testing.expect(!firstToSwitchOff());
    try testing.expect(!firstToSwitchOff());
}
