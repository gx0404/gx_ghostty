//! System queries and helpers of the settings overlay: a millisecond clock,
//! the Windows build (which window materials this system can show), the
//! installed font families that suit a terminal (DirectWrite), and running
//! `herdr --gx-set-default-shell` in the background.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const com = @import("../../../../font/directwrite/com.zig");
const config_types = @import("../../../../gx/config_types.zig");
const os_windows = @import("../../../../os/windows.zig");
const wstr = @import("../wstr.zig");

const log = std.log.scoped(.win32_settings);

const kernel32 = os_windows.exp.kernel32;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// Milliseconds since the system started.
pub fn nowMs() u64 {
    return GetTickCount64();
}

// -----------------------------------------------------------------------
// Window materials
// -----------------------------------------------------------------------

/// The first Windows 11 build; Mica works from here on.
pub const build_windows_11: u32 = 22000;

/// The first build with the system backdrop types (Mica, Acrylic and Mica
/// Alt through `DWMWA_SYSTEMBACKDROP_TYPE`), Windows 11 22H2.
pub const build_system_backdrop: u32 = 22621;

/// The Windows build number, e.g. 26100; 0 if it cannot be read.
pub fn windowsBuild() u32 {
    var info: windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
    if (windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return 0;
    return info.dwBuildNumber;
}

/// Whether Windows build `build` can show `material`.
pub fn materialSupported(material: config_types.WindowMaterial, build: u32) bool {
    return switch (material) {
        .solid => true,
        .mica => build >= build_windows_11,
        .acrylic, .tabbed => build >= build_system_backdrop,
    };
}

test "materialSupported" {
    const testing = std.testing;
    try testing.expect(materialSupported(.solid, 0));
    try testing.expect(!materialSupported(.mica, 19045));
    try testing.expect(materialSupported(.mica, 22000));
    try testing.expect(!materialSupported(.acrylic, 22000));
    try testing.expect(materialSupported(.tabbed, 22621));
    try testing.expect(materialSupported(.acrylic, 26100));
}

// -----------------------------------------------------------------------
// Font families
// -----------------------------------------------------------------------

/// Installed font families for the font family picker. All memory is owned
/// by `arena`.
pub const FontFamilies = struct {
    arena: std.heap.ArenaAllocator,

    /// English family names, sorted case-insensitively.
    names: []const [:0]const u8 = &.{},

    pub fn deinit(self: *FontFamilies) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The installed font families that suit a terminal: the monospace ones
/// (`IDWriteFont1::IsMonospacedFont`) and those whose name says so ("Mono",
/// "Code", "Nerd Font", ...), plus the `extra` names (the configured
/// families) even when they are not installed.
pub fn terminalFontFamilies(alloc: Allocator, extra: []const []const u8) !FontFamilies {
    var result: FontFamilies = .{ .arena = .init(alloc) };
    errdefer result.deinit();
    const arena = result.arena.allocator();

    var names: std.ArrayList([:0]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (extra) |name| {
        if (name.len == 0) continue;
        const gop = try seen.getOrPut(arena, name);
        if (gop.found_existing) continue;
        const copy = try arena.dupeZ(u8, name);
        gop.key_ptr.* = copy;
        try names.append(arena, copy);
    }

    var factory_ptr: ?*anyopaque = null;
    if (com.DWriteCreateFactory(.shared, &com.IDWriteFactory.iid, &factory_ptr) < 0) return error.DirectWrite;
    const factory: *com.IDWriteFactory = @ptrCast(@alignCast(factory_ptr orelse return error.DirectWrite));
    defer com.release(factory);
    const collection = try factory.getSystemFontCollection();
    defer com.release(collection);

    const count = collection.getFontFamilyCount();
    for (0..count) |i| {
        const family = collection.getFontFamily(@intCast(i)) catch continue;
        defer com.release(family);

        var buf: [256]u16 = undefined;
        const name16 = familyName(family, &buf) orelse continue;
        var utf8_buf: [512]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8_buf, name16) catch continue;
        const name = utf8_buf[0..len];
        if (name.len == 0 or name[0] == '@') continue;
        if (!looksMonospace(name) and !isMonospace(family)) continue;

        const gop = try seen.getOrPut(arena, name);
        if (gop.found_existing) continue;
        const copy = try arena.dupeZ(u8, name);
        gop.key_ptr.* = copy;
        try names.append(arena, copy);
    }

    std.mem.sort([:0]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: [:0]const u8, b: [:0]const u8) bool {
            return switch (std.ascii.orderIgnoreCase(a, b)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a, b) == .lt,
            };
        }
    }.lessThan);
    result.names = names.items;
    return result;
}

/// The English family name (or the first one) of `family`.
fn familyName(family: *com.IDWriteFontFamily, buf: []u16) ?[]u16 {
    const names = family.getFamilyNames() catch return null;
    defer com.release(names);
    const index = names.findLocaleName(std.unicode.utf8ToUtf16LeStringLiteral("en-us")) orelse 0;
    return names.getString(index, buf) catch null;
}

fn isMonospace(family: *com.IDWriteFontFamily) bool {
    if (family.getFontCount() == 0) return false;
    const font = family.getFont(0) catch return false;
    defer com.release(font);
    const font1 = com.queryInterface(com.IDWriteFont1, font) orelse return false;
    defer com.release(font1);
    return font1.isMonospacedFont();
}

/// Families whose name marks them as made for code, including patched
/// fonts whose wide icons make DirectWrite report them as proportional.
fn looksMonospace(name: []const u8) bool {
    for ([_][]const u8{ "mono", "code", "nerd font", "console", "consolas", "courier", "terminal", "fixed" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return true;
    }
    return false;
}

test "looksMonospace" {
    const testing = std.testing;
    try testing.expect(looksMonospace("JetBrainsMono Nerd Font"));
    try testing.expect(looksMonospace("Cascadia Code"));
    try testing.expect(looksMonospace("Consolas"));
    try testing.expect(!looksMonospace("Segoe UI"));
}

test "terminalFontFamilies lists installed monospace families and the extras" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var families = try terminalFontFamilies(testing.allocator, &.{ "Not Installed Mono", "" });
    defer families.deinit();
    var consolas = false;
    var extra = false;
    var segoe = false;
    for (families.names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "Consolas")) consolas = true;
        if (std.mem.eql(u8, name, "Not Installed Mono")) extra = true;
        if (std.mem.eql(u8, name, "Segoe UI")) segoe = true;
        if (i > 0) try testing.expect(std.ascii.orderIgnoreCase(families.names[i - 1], name) != .gt);
    }
    // Consolas ships with every Windows installation.
    try testing.expect(consolas);
    try testing.expect(extra);
    try testing.expect(!segoe);
}

// -----------------------------------------------------------------------
// herdr
// -----------------------------------------------------------------------

/// `herdr.exe` in the directory of the GX Zsh executable `gx_zsh`, if it
/// exists. The caller owns the path.
pub fn herdrNextTo(alloc: Allocator, io: std.Io, gx_zsh: []const u8) ?[]u8 {
    const dir = std.fs.path.dirname(gx_zsh) orelse return null;
    const path = std.fs.path.join(alloc, &.{ dir, "herdr.exe" }) catch return null;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch {
        alloc.free(path);
        return null;
    };
    return path;
}

/// The exit code of `herdr --gx-set-default-shell` when the user manages
/// the herdr configuration (not an error).
pub const herdr_user_config_exit: u32 = 3;

/// A background `herdr --gx-set-default-shell <gx-zsh>` run.
pub const HerdrRun = struct {
    process: windows.HANDLE,
    started_ms: u64,

    pub const Status = union(enum) {
        running,
        exited: u32,
        failed,
    };

    /// Starts `herdr --gx-set-default-shell <gx_zsh>` without a console
    /// window.
    pub fn start(alloc: Allocator, herdr: []const u8, gx_zsh: []const u8) !HerdrRun {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        try appendQuoted(alloc, &line, herdr);
        try line.appendSlice(alloc, " --gx-set-default-shell ");
        try appendQuoted(alloc, &line, gx_zsh);

        const app_w = try wstr.allocZ(alloc, herdr);
        defer alloc.free(app_w);
        const line_w = try wstr.allocZ(alloc, line.items);
        defer alloc.free(line_w);

        var startup = std.mem.zeroes(os_windows.STARTUPINFOW);
        startup.cb = @sizeOf(os_windows.STARTUPINFOW);
        var info: os_windows.PROCESS_INFORMATION = undefined;
        if (kernel32.CreateProcessW(
            app_w.ptr,
            line_w.ptr,
            null,
            null,
            os_windows.FALSE,
            create_no_window,
            null,
            null,
            &startup,
            &info,
        ) == os_windows.FALSE) {
            const err = os_windows.GetLastError();
            log.warn("cannot start {s} err={t}", .{ herdr, err });
            return error.ProcessStartFailed;
        }
        _ = kernel32.CloseHandle(info.hThread);
        return .{ .process = info.hProcess, .started_ms = nowMs() };
    }

    /// Checks without waiting whether herdr has exited.
    pub fn poll(self: *const HerdrRun) Status {
        const wait = kernel32.WaitForSingleObject(self.process, 0);
        if (wait == wait_timeout) return .running;
        if (wait != wait_object_0) return .failed;
        var code: os_windows.DWORD = 0;
        if (kernel32.GetExitCodeProcess(self.process, &code) == os_windows.FALSE) return .failed;
        return .{ .exited = code };
    }

    /// Stops watching the process (it keeps running if it has not exited).
    pub fn deinit(self: *HerdrRun) void {
        _ = kernel32.CloseHandle(self.process);
        self.* = undefined;
    }

    const create_no_window: u32 = 0x08000000;
    const wait_object_0: u32 = 0;
    const wait_timeout: u32 = 0x102;
};

/// Appends `arg` in double quotes for the C runtime command-line rules:
/// backslashes before a quote are doubled and quotes are escaped.
fn appendQuoted(alloc: Allocator, out: *std.ArrayList(u8), arg: []const u8) Allocator.Error!void {
    try out.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                try out.appendNTimes(alloc, '\\', backslashes * 2 + 1);
                try out.append(alloc, '"');
                backslashes = 0;
            },
            else => {
                try out.appendNTimes(alloc, '\\', backslashes);
                try out.append(alloc, c);
                backslashes = 0;
            },
        }
    }
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
}

test "HerdrRun reports the exit code of the process" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    // where.exe rejects the unknown option and exits with an error code.
    var run = try HerdrRun.start(testing.allocator, "C:\\Windows\\System32\\where.exe", "C:\\no such\\gx-zsh.exe");
    defer run.deinit();
    _ = kernel32.WaitForSingleObject(run.process, 10_000);
    switch (run.poll()) {
        .exited => |code| try testing.expect(code != 0),
        .running, .failed => return error.TestUnexpectedResult,
    }
    try testing.expectError(error.ProcessStartFailed, HerdrRun.start(testing.allocator, "C:\\no such\\herdr.exe", "x"));
}

test "appendQuoted" {
    const testing = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendQuoted(testing.allocator, &out, "C:\\Program Files\\GX\\bin\\herdr.exe");
    try testing.expectEqualStrings("\"C:\\Program Files\\GX\\bin\\herdr.exe\"", out.items);
    out.clearRetainingCapacity();
    try appendQuoted(testing.allocator, &out, "C:\\dir\\");
    try testing.expectEqualStrings("\"C:\\dir\\\\\"", out.items);
}
