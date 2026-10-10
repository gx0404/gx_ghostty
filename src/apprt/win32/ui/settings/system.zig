//! System queries and helpers of the settings overlay: a millisecond clock,
//! the Windows build (which window materials this system can show), the
//! installed font families that suit a terminal (DirectWrite), listed on a
//! thread of their own (`FontLoader`), the mouse wheel setting, and running
//! `herdr --gx-set-default-shell` in the background.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const com = @import("../../../../font/directwrite/com.zig");
const config_types = @import("../../../../gx/config_types.zig");
const perf = @import("../../../../gx/perf.zig");
const os_windows = @import("../../../../os/windows.zig");
const w32 = @import("../../win32.zig");
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

    /// For each name, the family's name in the user's language when the
    /// font has one that differs from the English name ("Microsoft YaHei
    /// Mono" is "微软雅黑 Mono" on a Chinese system), else null.
    local_names: []const ?[:0]const u8 = &.{},

    pub fn deinit(self: *FontFamilies) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// How `terminalFontFamilies` lists.
pub const ListOptions = struct {
    /// The locales (UTF-16 names such as "zh-CN") whose family names to
    /// report as `local_names`, best first.
    locales: []const []const u16 = &.{},
    /// Ask DirectWrite for fonts installed since the process started.
    check_for_updates: bool = false,
};

/// The installed font families that suit a terminal: the monospace ones
/// (`IDWriteFont1::IsMonospacedFont`) and those whose name says so ("Mono",
/// "Code", "Nerd Font", ...). Reads every family's first font, which can
/// take a while: `FontLoader` runs it on a thread of its own.
pub fn terminalFontFamilies(alloc: Allocator, options: ListOptions) !FontFamilies {
    var result: FontFamilies = .{ .arena = .init(alloc) };
    errdefer result.deinit();
    const arena = result.arena.allocator();

    const Entry = struct { name: [:0]const u8, local: ?[:0]const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    var factory_ptr: ?*anyopaque = null;
    if (com.DWriteCreateFactory(.shared, &com.IDWriteFactory.iid, &factory_ptr) < 0) return error.DirectWrite;
    const factory: *com.IDWriteFactory = @ptrCast(@alignCast(factory_ptr orelse return error.DirectWrite));
    defer com.release(factory);
    var collection_ptr: ?*com.IDWriteFontCollection = null;
    if (factory.vtable.GetSystemFontCollection(factory, &collection_ptr, if (options.check_for_updates) .TRUE else .FALSE) < 0) {
        return error.DirectWrite;
    }
    const collection = collection_ptr orelse return error.DirectWrite;
    defer com.release(collection);

    const count = collection.getFontFamilyCount();
    for (0..count) |i| {
        const family = collection.getFontFamily(@intCast(i)) catch continue;
        defer com.release(family);
        const family_names = family.getFamilyNames() catch continue;
        defer com.release(family_names);

        var buf: [256]u16 = undefined;
        const english = family_names.findLocaleName(std.unicode.utf8ToUtf16LeStringLiteral("en-us")) orelse 0;
        const name16 = family_names.getString(english, &buf) catch continue;
        var utf8_buf: [512]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8_buf, name16) catch continue;
        const name = utf8_buf[0..len];
        if (name.len == 0 or name[0] == '@') continue;
        if (!looksMonospace(name) and !isMonospace(family)) continue;

        const gop = try seen.getOrPut(arena, name);
        if (gop.found_existing) continue;
        const copy = try arena.dupeZ(u8, name);
        gop.key_ptr.* = copy;
        try entries.append(arena, .{ .name = copy, .local = try localName(arena, family_names, english, copy, options.locales) });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return nameLessThan({}, a.name, b.name);
        }
    }.lessThan);
    const names = try arena.alloc([:0]const u8, entries.items.len);
    const local_names = try arena.alloc(?[:0]const u8, entries.items.len);
    for (entries.items, names, local_names) |entry, *name, *local| {
        name.* = entry.name;
        local.* = entry.local;
    }
    result.names = names;
    result.local_names = local_names;
    return result;
}

/// The name of a family in the first of `locales` it has one for, when it
/// differs from `english` (its name at index `english_index`).
fn localName(
    arena: Allocator,
    family_names: *com.IDWriteLocalizedStrings,
    english_index: u32,
    english: []const u8,
    locales: []const []const u16,
) Allocator.Error!?[:0]const u8 {
    for (locales) |locale| {
        var locale_buf: [com.LOCALE_NAME_MAX_LENGTH + 1]u16 = undefined;
        if (locale.len == 0 or locale.len >= locale_buf.len) continue;
        @memcpy(locale_buf[0..locale.len], locale);
        locale_buf[locale.len] = 0;
        const locale_z: [:0]const u16 = locale_buf[0..locale.len :0];
        const index = family_names.findLocaleName(locale_z.ptr) orelse continue;
        if (index == english_index) return null;
        var buf: [256]u16 = undefined;
        const name16 = family_names.getString(index, &buf) catch continue;
        var utf8_buf: [512]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8_buf, name16) catch continue;
        const name = utf8_buf[0..len];
        if (name.len == 0 or std.mem.eql(u8, name, english)) return null;
        return try arena.dupeZ(u8, name);
    }
    return null;
}

/// The order of family names: case-insensitive, then by byte.
fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return switch (std.ascii.orderIgnoreCase(a, b)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a, b) == .lt,
    };
}

/// The families the picker shows: the installed ones and `extra` (the
/// configured family) when it is not installed, in order. Allocated with
/// `alloc` (an arena); the names stay those of `installed`.
pub const Picker = struct {
    names: []const [:0]const u8,
    local_names: []const ?[:0]const u8,

    pub fn init(alloc: Allocator, installed: ?*const FontFamilies, extra: []const u8) Allocator.Error!Picker {
        const names: []const [:0]const u8 = if (installed) |f| f.names else &.{};
        const local_names: []const ?[:0]const u8 = if (installed) |f| f.local_names else &.{};
        const missing = extra.len > 0 and for (names) |name| {
            if (std.mem.eql(u8, name, extra)) break false;
        } else true;
        if (!missing) return .{ .names = names, .local_names = local_names };

        const out_names = try alloc.alloc([:0]const u8, names.len + 1);
        const out_local = try alloc.alloc(?[:0]const u8, names.len + 1);
        const at = for (names, 0..) |name, i| {
            if (nameLessThan({}, extra, name)) break i;
        } else names.len;
        @memcpy(out_names[0..at], names[0..at]);
        @memcpy(out_local[0..at], local_names[0..at]);
        out_names[at] = try alloc.dupeZ(u8, extra);
        out_local[at] = null;
        @memcpy(out_names[at + 1 ..], names[at..]);
        @memcpy(out_local[at + 1 ..], local_names[at..]);
        return .{ .names = out_names, .local_names = out_local };
    }

    pub fn indexOf(self: Picker, name: []const u8) ?u32 {
        for (self.names, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return @intCast(i);
        }
        return null;
    }
};

/// Lists the terminal font families (`terminalFontFamilies`) on a thread of
/// its own and posts `msg` to the window `notify` when the list is ready.
/// The owner and the thread each hold a reference and the last one frees
/// it, so the owner may let go (`detach`) while the thread still runs.
pub const FontLoader = struct {
    alloc: Allocator,
    refs: std.atomic.Value(u32) = .init(2),
    /// The window to post `msg` to (an HWND), 0 once detached.
    notify: std.atomic.Value(usize),
    msg: u32,
    /// Also report the Chinese family names when the user's locale is not
    /// Chinese (the interface language is).
    chinese: bool,
    /// Set by the thread once `result` is written.
    done: std.atomic.Value(bool) = .init(false),
    /// The list, null when listing failed; the owner's once taken.
    result: ?FontFamilies = null,
    /// Owner thread only.
    taken: bool = false,

    pub const State = union(enum) {
        running,
        ready: FontFamilies,
        failed,
        taken,
    };

    pub fn start(alloc: Allocator, notify: ?w32.HWND, msg: u32, chinese: bool) !*FontLoader {
        const self = try alloc.create(FontLoader);
        self.* = .{
            .alloc = alloc,
            .notify = .init(if (notify) |hwnd| @intFromPtr(hwnd) else 0),
            .msg = msg,
            .chinese = chinese,
        };
        const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            alloc.destroy(self);
            return err;
        };
        thread.detach();
        return self;
    }

    fn run(self: *FontLoader) void {
        var user_buf: [com.LOCALE_NAME_MAX_LENGTH]u16 = undefined;
        const user_len = com.GetUserDefaultLocaleName(&user_buf, user_buf.len);
        var locales_buf: [2][]const u16 = undefined;
        var locales: usize = 0;
        if (user_len > 1) {
            locales_buf[locales] = user_buf[0..@intCast(user_len - 1)];
            locales += 1;
        }
        if (self.chinese) {
            locales_buf[locales] = std.unicode.utf8ToUtf16LeStringLiteral("zh-cn");
            locales += 1;
        }

        const started = GetTickCount64();
        self.result = terminalFontFamilies(self.alloc, .{
            .locales = locales_buf[0..locales],
            .check_for_updates = true,
        }) catch |err| result: {
            log.warn("cannot list the font families err={}", .{err});
            break :result null;
        };
        perf.record("settings_font_list", (GetTickCount64() -| started) * std.time.us_per_ms);
        self.done.store(true, .release);
        const notify = self.notify.load(.acquire);
        if (notify != 0) _ = w32.PostMessageW(@ptrFromInt(notify), self.msg, 0, 0);
        self.release();
    }

    /// The list once the thread finished, at most once (owner thread): the
    /// caller owns a `.ready` list.
    pub fn take(self: *FontLoader) State {
        if (!self.done.load(.acquire)) return .running;
        if (self.taken) return .taken;
        self.taken = true;
        const families = self.result orelse return .failed;
        self.result = null;
        return .{ .ready = families };
    }

    /// The owner is done with the loader: nothing is posted to it any more
    /// and it must not use the loader again.
    pub fn detach(self: *FontLoader) void {
        self.notify.store(0, .release);
        self.release();
    }

    fn release(self: *FontLoader) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*families| families.deinit();
        self.alloc.destroy(self);
    }
};

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

test "terminalFontFamilies lists installed monospace families" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var families = try terminalFontFamilies(testing.allocator, .{
        .locales = &.{std.unicode.utf8ToUtf16LeStringLiteral("zh-cn")},
        .check_for_updates = true,
    });
    defer families.deinit();
    try testing.expectEqual(families.names.len, families.local_names.len);
    var consolas = false;
    var segoe = false;
    for (families.names, families.local_names, 0..) |name, local, i| {
        if (std.mem.eql(u8, name, "Consolas")) consolas = true;
        if (std.mem.eql(u8, name, "Segoe UI")) segoe = true;
        if (i > 0) try testing.expect(std.ascii.orderIgnoreCase(families.names[i - 1], name) != .gt);
        if (local) |l| try testing.expect(!std.mem.eql(u8, l, name));
    }
    // Consolas ships with every Windows installation.
    try testing.expect(consolas);
    try testing.expect(!segoe);
}

test "the picker adds the configured family in order" {
    const testing = std.testing;
    var families: FontFamilies = .{ .arena = .init(testing.allocator) };
    defer families.deinit();
    families.names = &.{ "Cascadia Mono", "Consolas", "JetBrains Mono" };
    families.local_names = &.{ null, null, "JB" };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const same = try Picker.init(alloc, &families, "Consolas");
    try testing.expectEqual(families.names.ptr, same.names.ptr);
    try testing.expectEqual(@as(?u32, 1), same.indexOf("Consolas"));

    const added = try Picker.init(alloc, &families, "Iosevka");
    try testing.expectEqual(@as(usize, 4), added.names.len);
    try testing.expectEqualStrings("Iosevka", added.names[2]);
    try testing.expectEqual(@as(?[:0]const u8, null), added.local_names[2]);
    try testing.expectEqualStrings("JB", added.local_names[3].?);

    const first = try Picker.init(alloc, &families, "Anonymous Pro");
    try testing.expectEqualStrings("Anonymous Pro", first.names[0]);
    const none = try Picker.init(alloc, null, "Iosevka");
    try testing.expectEqual(@as(usize, 1), none.names.len);
    const empty = try Picker.init(alloc, null, "");
    try testing.expectEqual(@as(usize, 0), empty.names.len);
}

test "FontLoader lists on its thread and is freed by the last owner" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    // Taken by the owner: the owner frees the list.
    const loader = try FontLoader.start(testing.allocator, null, w32.WM_APP + 2, true);
    var tries: usize = 0;
    const listed = while (tries < 1000) : (tries += 1) {
        switch (loader.take()) {
            .running => Sleep(10),
            .ready => |families| break families,
            .failed, .taken => return error.TestUnexpectedResult,
        }
    } else return error.Timeout;
    var families = listed;
    defer families.deinit();
    try testing.expect(families.names.len > 0);
    try testing.expectEqual(families.names.len, families.local_names.len);
    try testing.expect(loader.take() == .taken);
    releaseLast(loader);

    // Let go of before the list was taken: the last release frees the list
    // too (the testing allocator reports a leak otherwise).
    const early = try FontLoader.start(testing.allocator, null, w32.WM_APP + 2, false);
    releaseLast(early);
}

/// Detaches like the owner, waits for the thread to let go and releases
/// last, so everything is freed before the test ends.
fn releaseLast(loader: *FontLoader) void {
    _ = loader.refs.fetchAdd(1, .monotonic);
    loader.detach();
    var tries: usize = 0;
    while (loader.refs.load(.acquire) > 1 and tries < 3000) : (tries += 1) Sleep(10);
    loader.release();
}

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

// -----------------------------------------------------------------------
// Mouse wheel
// -----------------------------------------------------------------------

const SPI_GETWHEELSCROLLLINES: u32 = 0x0068;

extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;

/// The `SPI_GETWHEELSCROLLLINES` setting: lines per wheel notch, or
/// `model.wheel_page_scroll` for a screen at a time (3 when unknown).
pub fn wheelScrollLines() u32 {
    var lines: u32 = 3;
    if (SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, @ptrCast(&lines), 0) == 0) return 3;
    return lines;
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
