//! The ConPTY implementation behind the Windows pty (src/pty.zig).
//!
//! The inbox ConPTY (kernel32 CreatePseudoConsole and conhost.exe) is as old
//! as the Windows build. The Microsoft.Windows.Console.ConPTY package ships
//! the current one from microsoft/terminal as two files: conpty.dll, which
//! exports the pseudoconsole functions as ConptyCreatePseudoConsole,
//! ConptyResizePseudoConsole and ConptyClosePseudoConsole with the kernel32
//! signatures, and OpenConsole.exe, the console host conpty.dll starts from
//! its own directory (it silently falls back to the inbox conhost.exe if
//! that file is missing). An HPCON from conpty.dll works with
//! PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE like a kernel32 one.
//!
//! `Instance.create` uses conpty.dll when both files sit next to the
//! executable, and kernel32 otherwise or when loading or creating fails.
//! `GHOSTTY_GX_CONPTY=system` forces kernel32. Each pseudoconsole keeps
//! the `Instance` that created it, because it must be resized and closed by
//! the same implementation; every creation logs which one is used.
//!
//! Flags: the bundled ConPTY gets PSEUDOCONSOLE_RESIZE_QUIRK and
//! PSEUDOCONSOLE_WIN32_INPUT_MODE, which conpty.dll builds before 1.22
//! need; 1.22 and newer always behave that way and ignore both bits (they
//! do not overlap the GLYPH_WIDTH bits, 0x18). The inbox ConPTY keeps
//! upstream's 0. PSEUDOCONSOLE_INHERIT_CURSOR stays off, as in Windows
//! Terminal by default: Ghostty answers the cursor position request it
//! sends (CSI 6 n), but a surface always starts with an empty screen and
//! the cursor at the origin, so there is nothing to inherit, and an
//! unanswered request blocks older hosts' input indefinitely.
const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../os/main.zig").windows;

const log = std.log.scoped(.gx_conpty);

/// PSEUDOCONSOLE_INHERIT_CURSOR: the host asks for the cursor position
/// (CSI 6 n) at startup and waits for the reply. Not used, see above.
pub const inherit_cursor: windows.DWORD = 0x1;

/// PSEUDOCONSOLE_RESIZE_QUIRK
pub const resize_quirk: windows.DWORD = 0x2;

/// PSEUDOCONSOLE_WIN32_INPUT_MODE
pub const win32_input_mode: windows.DWORD = 0x4;

/// The flags the bundled ConPTY is created with.
pub const bundled_flags: windows.DWORD = resize_quirk | win32_input_mode;

/// The environment variable that selects the ConPTY implementation.
pub const env_var = "GHOSTTY_GX_CONPTY";

/// The two files of the bundled ConPTY, next to the executable.
pub const dll_name = "conpty.dll";
pub const host_name = "OpenConsole.exe";

pub const Source = enum { bundled, system };

/// What `GHOSTTY_GX_CONPTY` asks for.
pub const Preference = enum {
    /// Unset, empty or `bundled`: the bundled ConPTY when it is present.
    auto,
    /// `system`: always the inbox ConPTY.
    system,
};

/// Parse a `GHOSTTY_GX_CONPTY` value (ASCII, case-insensitive). Returns
/// null for values it does not know.
pub fn parsePreference(value: []const u16) ?Preference {
    if (value.len == 0) return .auto;
    if (eqlAsciiIgnoreCase(value, "system")) return .system;
    if (eqlAsciiIgnoreCase(value, "bundled")) return .auto;
    return null;
}

fn eqlAsciiIgnoreCase(value: []const u16, comptime ascii: []const u8) bool {
    if (value.len != ascii.len) return false;
    for (value, ascii) |unit, c| {
        if (unit > 0x7f) return false;
        if (std.ascii.toLower(@intCast(unit)) != c) return false;
    }
    return true;
}

/// Write `<directory of exe_path>\<name>` NUL-terminated into `buf`.
/// Returns null if `exe_path` has no directory or the result does not fit.
pub fn siblingPath(
    buf: []u16,
    exe_path: []const u16,
    comptime name: []const u8,
) ?[:0]const u16 {
    const name_w = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const dir_len = (std.mem.lastIndexOfScalar(u16, exe_path, '\\') orelse
        return null) + 1;
    if (dir_len + name_w.len + 1 > buf.len) return null;
    @memcpy(buf[0..dir_len], exe_path[0..dir_len]);
    @memcpy(buf[dir_len..][0..name_w.len], name_w);
    buf[dir_len + name_w.len] = 0;
    return buf[0 .. dir_len + name_w.len :0];
}

const CreateFn = *const fn (
    size: windows.COORD,
    input: windows.HANDLE,
    output: windows.HANDLE,
    flags: windows.DWORD,
    hpc: *windows.HPCON,
) callconv(.winapi) windows.HRESULT;
const ResizeFn = *const fn (
    hpc: windows.HPCON,
    size: windows.COORD,
) callconv(.winapi) windows.HRESULT;
const CloseFn = *const fn (hpc: windows.HPCON) callconv(.winapi) void;

/// The ConPTY implementation that created a pseudoconsole.
pub const Instance = struct {
    source: Source,

    /// The dwFlags the pseudoconsole was created with.
    flags: windows.DWORD,

    /// conpty.dll, loaded once per pseudoconsole and released when the
    /// pseudoconsole is closed.
    module: ?HMODULE,

    create_fn: CreateFn,
    resize_fn: ResizeFn,
    close_fn: CloseFn,

    pub const system: Instance = .{
        .source = .system,
        .flags = 0,
        .module = null,
        .create_fn = &windows.exp.kernel32.CreatePseudoConsole,
        .resize_fn = &windows.exp.kernel32.ResizePseudoConsole,
        .close_fn = &windows.exp.kernel32.ClosePseudoConsole,
    };

    /// Create a pseudoconsole that reads input from `input` and writes
    /// output to `output`, and return the implementation that created it.
    pub fn create(
        size: windows.COORD,
        input: windows.HANDLE,
        output: windows.HANDLE,
        hpc: *windows.HPCON,
    ) error{Unexpected}!Instance {
        var path_buf: [path_max]u16 = undefined;
        const reason: []const u8 = switch (loadBundled(&path_buf)) {
            .loaded => |loaded| bundled: {
                const hr = loaded.instance.create_fn(size, input, output, loaded.instance.flags, hpc);
                if (hr == windows.S_OK) {
                    log.info("ConPTY: bundled {f} flags=0x{x}", .{
                        std.unicode.fmtUtf16Le(loaded.path),
                        loaded.instance.flags,
                    });
                    return loaded.instance;
                }

                log.warn("bundled ConPTY {f} failed to create a pseudoconsole hr=0x{x}", .{
                    std.unicode.fmtUtf16Le(loaded.path),
                    @as(u32, @bitCast(hr)),
                });
                loaded.instance.unload();
                break :bundled "bundled ConPTY failed";
            },
            .skipped => |why| why,
        };

        const instance = system;
        const hr = instance.create_fn(size, input, output, instance.flags, hpc);
        if (hr != windows.S_OK) {
            log.err("CreatePseudoConsole failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.Unexpected;
        }
        log.info("ConPTY: system (kernel32) flags=0x{x}, {s}", .{ instance.flags, reason });
        return instance;
    }

    pub fn resize(
        self: Instance,
        hpc: windows.HPCON,
        size: windows.COORD,
    ) windows.HRESULT {
        return self.resize_fn(hpc, size);
    }

    pub fn close(self: Instance, hpc: windows.HPCON) void {
        self.close_fn(hpc);
        self.unload();
    }

    fn unload(self: Instance) void {
        if (self.module) |module| _ = FreeLibrary(module);
    }
};

const Bundled = union(enum) {
    loaded: struct {
        instance: Instance,
        path: []const u16,
    },

    /// Why the bundled ConPTY is not used.
    skipped: []const u8,
};

/// Load conpty.dll from the executable's directory unless the environment
/// asks for the system ConPTY. `path_buf` receives the DLL path.
fn loadBundled(path_buf: *[path_max]u16) Bundled {
    var env_buf: [32]u16 = undefined;
    const env_len = GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral(env_var),
        &env_buf,
        env_buf.len,
    );
    // A value too long for the buffer is not one we know.
    const value: []const u16 = if (env_len < env_buf.len)
        env_buf[0..env_len]
    else
        &[_]u16{0xFFFD};
    switch (parsePreference(value) orelse pref: {
        log.warn("ignoring unknown {s} value; use \"system\" or \"bundled\"", .{env_var});
        break :pref .auto;
    }) {
        .auto => {},
        .system => return .{ .skipped = env_var ++ "=system" },
    }

    var exe_buf: [path_max]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (exe_len == 0 or exe_len >= exe_buf.len) {
        return .{ .skipped = "the executable path is unknown" };
    }
    const exe_path = exe_buf[0..exe_len];

    const dll_path = siblingPath(path_buf, exe_path, dll_name) orelse
        return .{ .skipped = "the executable path is too long" };
    if (!isFile(dll_path)) return .{ .skipped = dll_name ++ " is not next to the executable" };

    var host_buf: [path_max]u16 = undefined;
    const host_path = siblingPath(&host_buf, exe_path, host_name) orelse
        return .{ .skipped = "the executable path is too long" };
    if (!isFile(host_path)) {
        log.warn("{s} is next to the executable but {s} is not", .{ dll_name, host_name });
        return .{ .skipped = host_name ++ " is missing" };
    }

    // Only the DLL's own directory and System32 are searched for its
    // dependencies.
    const module = LoadLibraryExW(
        dll_path.ptr,
        null,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse {
        log.warn("cannot load {f} err={d}", .{
            std.unicode.fmtUtf16Le(dll_path),
            @intFromEnum(windows.GetLastError()),
        });
        return .{ .skipped = "conpty.dll failed to load" };
    };

    const instance: Instance = .{
        .source = .bundled,
        .flags = bundled_flags,
        .module = module,
        .create_fn = symbol(module, "ConptyCreatePseudoConsole", CreateFn) orelse
            return unloadSkipped(module),
        .resize_fn = symbol(module, "ConptyResizePseudoConsole", ResizeFn) orelse
            return unloadSkipped(module),
        .close_fn = symbol(module, "ConptyClosePseudoConsole", CloseFn) orelse
            return unloadSkipped(module),
    };
    return .{ .loaded = .{ .instance = instance, .path = dll_path } };
}

fn unloadSkipped(module: HMODULE) Bundled {
    _ = FreeLibrary(module);
    return .{ .skipped = "conpty.dll lacks the Conpty* exports" };
}

fn symbol(module: HMODULE, comptime name: [:0]const u8, comptime T: type) ?T {
    const proc = GetProcAddress(module, name) orelse {
        log.warn("conpty.dll does not export {s}", .{name});
        return null;
    };
    return @ptrCast(proc);
}

fn isFile(path: [:0]const u16) bool {
    const attributes = GetFileAttributesW(path.ptr);
    return attributes != INVALID_FILE_ATTRIBUTES and
        attributes & FILE_ATTRIBUTE_DIRECTORY == 0;
}

/// Room for the executable path and a sibling file name. A longer path
/// (beyond the classic MAX_PATH by far) uses the system ConPTY.
const path_max = 1024;

const HMODULE = std.os.windows.HMODULE;
const INVALID_FILE_ATTRIBUTES: windows.DWORD = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: windows.DWORD = 0x10;
const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: windows.DWORD = 0x00000100;
const LOAD_LIBRARY_SEARCH_SYSTEM32: windows.DWORD = 0x00000800;

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: [*:0]const u16,
    hFile: ?windows.HANDLE,
    dwFlags: windows.DWORD,
) callconv(.winapi) ?HMODULE;
extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetProcAddress(
    hModule: HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetModuleFileNameW(
    hModule: ?HMODULE,
    lpFilename: [*]u16,
    nSize: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: [*]u16,
    nSize: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) windows.DWORD;

const testing = std.testing;

test "parsePreference" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqual(Preference.auto, parsePreference(L("")).?);
    try testing.expectEqual(Preference.system, parsePreference(L("system")).?);
    try testing.expectEqual(Preference.system, parsePreference(L("SYSTEM")).?);
    try testing.expectEqual(Preference.auto, parsePreference(L("Bundled")).?);
    try testing.expectEqual(null, parsePreference(L("kernel32")));
    try testing.expectEqual(null, parsePreference(L("system ")));
    try testing.expectEqual(null, parsePreference(L("s\u{fd}stem")));
}

test "siblingPath replaces the file name" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [64]u16 = undefined;
    const path = siblingPath(&buf, L("C:\\Program Files\\Ghostty\\ghostty.exe"), dll_name).?;
    try testing.expectEqualSlices(u16, L("C:\\Program Files\\Ghostty\\conpty.dll"), path);
    try testing.expectEqual(@as(u16, 0), path.ptr[path.len]);

    try testing.expectEqual(null, siblingPath(&buf, L("ghostty.exe"), dll_name));

    var small: [12]u16 = undefined;
    try testing.expectEqual(null, siblingPath(&small, L("C:\\a\\ghostty.exe"), host_name));
}

test "bundled flags stay clear of the glyph width bits" {
    try testing.expectEqual(@as(windows.DWORD, 0x6), bundled_flags);
    try testing.expectEqual(@as(windows.DWORD, 0), bundled_flags & 0x18);
    try testing.expectEqual(@as(windows.DWORD, 0), bundled_flags & inherit_cursor);
}
