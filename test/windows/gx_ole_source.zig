//! Owned native OLE drag source. Build with scripts/zigw.py build-exe this file
//! -target x86_64-windows-gnu -lc -lole32 -luser32 -lkernel32 -lshell32.
//! Python owns the target process and mouse: press left on its terminal, launch
//! this fixture asynchronously, wait for ready.json, then release left. This
//! executable uses real DoDragDrop; it never invokes the target's Drop directly.
//! No keyboard/Enter injection, clipboard access, registry writes or file moves.
const std = @import("std");
const H = std.os.windows.HANDLE;
const HWND = std.os.windows.HWND;
const HRESULT = i32;
const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MSG = extern struct { hwnd: ?HWND, message: u32, wparam: usize, lparam: isize, time: u32, point: POINT, private: u32 };
const WindowClass = extern struct {
    style: u32 = 0,
    proc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    class_extra: i32 = 0,
    window_extra: i32 = 0,
    instance: ?H,
    icon: ?H = null,
    cursor: ?H = null,
    background: ?H = @ptrFromInt(6),
    menu: ?[*:0]const u16 = null,
    name: [*:0]const u16,
};
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const Format = extern struct { format: u16, target: ?*anyopaque = null, aspect: u32 = 1, index: i32 = -1, medium: u32 = 1 };
const Medium = extern struct { kind: u32 = 0, handle: ?H = null, owner: ?*Unknown = null };
const no_interface: HRESULT = @bitCast(@as(u32, 0x80004002));
const not_implemented: HRESULT = @bitCast(@as(u32, 0x80004001));
const bad_format: HRESULT = @bitCast(@as(u32, 0x80040064));
const pointer_error: HRESULT = @bitCast(@as(u32, 0x80004003));
const iid_unknown: GUID = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
fn iid(comptime value: u32) GUID {
    var result = iid_unknown;
    result.a = value;
    return result;
}
fn equal(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

extern "ole32" fn OleInitialize(?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn OleUninitialize() callconv(.winapi) void;
extern "ole32" fn DoDragDrop(*DataObject, *DropSource, u32, *u32) callconv(.winapi) HRESULT;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?H;
extern "kernel32" fn GetProcessTimes(H, *u64, *u64, *u64, *u64) callconv(.winapi) i32;
extern "kernel32" fn QueryFullProcessImageNameW(H, u32, [*]u16, *u32) callconv(.winapi) i32;
extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, i32) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(H, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?H) callconv(.winapi) H;
extern "kernel32" fn CloseHandle(H) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(H, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(H, u32) callconv(.winapi) u32;
extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) ?H;
extern "kernel32" fn GlobalLock(H) callconv(.winapi) ?[*]u8;
extern "kernel32" fn GlobalUnlock(H) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(H) callconv(.winapi) ?H;
extern "kernel32" fn GlobalSize(H) callconv(.winapi) usize;
extern "user32" fn GetWindowThreadProcessId(HWND, *u32) callconv(.winapi) u32;
extern "user32" fn IsWindow(HWND) callconv(.winapi) i32;
extern "user32" fn IsChild(HWND, HWND) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) i32;
extern "user32" fn SetCursorPos(i32, i32) callconv(.winapi) i32;
extern "user32" fn WindowFromPoint(POINT) callconv(.winapi) ?HWND;
extern "user32" fn GetAsyncKeyState(i32) callconv(.winapi) i16;
extern "user32" fn RegisterClipboardFormatW([*:0]const u16) callconv(.winapi) u32;
extern "user32" fn SetTimer(?HWND, usize, u32, ?*const fn (?HWND, u32, usize, u32) callconv(.winapi) void) callconv(.winapi) usize;
extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) i32;
extern "user32" fn PostThreadMessageW(u32, u32, usize, isize) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?H;
extern "user32" fn RegisterClassW(*const WindowClass) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?H, ?H, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) i32;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) i32;

// Single STA only. Synchronous writes survive fixture termination; no payload
// text, paths, clipboard contents or unbounded callback log is recorded.
var trace_file: ?H = null;
var trace_count: usize = 0;
var trace_last: u64 = 0;
var trace_suppressed: usize = 0;
fn trace(comptime event: []const u8, comptime fields: []const u8, args: anytype, critical: bool) void {
    const file = trace_file orelse return;
    const now = GetTickCount64();
    if (trace_count >= 256 or (!critical and trace_count >= 128 and now -| trace_last < 1000)) {
        trace_suppressed +|= 1;
        return;
    }
    var detail: [512]u8 = undefined;
    const extra = std.fmt.bufPrint(&detail, fields, args) catch return;
    var buffer: [768]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{{\"event\":\"{s}\",\"tick_ms\":{d},\"thread_id\":{d},\"suppressed\":{d}{s}}}\n", .{ event, now, GetCurrentThreadId(), trace_suppressed, extra }) catch return;
    var written: u32 = 0;
    _ = WriteFile(file, line.ptr, @intCast(line.len), &written, null);
    trace_count += 1;
    trace_last = now;
}

const Case = enum { text, unicode, multiline, single_file, files, shell_metachar_files, quoted_path, uri, unterminated, bad_hdrop, bad_uri, text_limit, too_many_files };
const Options = struct {
    run: bool = false,
    source_window: bool = false,
    hwnd: usize = 0,
    pid: u32 = 0,
    birth: u64 = 0,
    exe: []const u8 = "",
    sha256: []const u8 = "",
    work_dir: []const u8 = "",
    case: Case = .text,
    timeout_ms: u32 = 5000,
    x: ?i32 = null,
    y: ?i32 = null,
};
const usage =
    \\gx_ole_source --run --hwnd=0xHEX --pid=N --birth=FILETIME --exe=ABS --sha256=HEX
    \\  --work-dir=OWNED_PARENT --case=text|unicode|multiline|single_file|files|shell_metachar_files|quoted_path|uri|unterminated|bad_hdrop|bad_uri|text_limit|too_many_files
    \\  [--timeout-ms=5000] [--x=SCREEN_X --y=SCREEN_Y]
    \\Press and hold left on the verified target first; release after ready.json appears.
    \\--source-window instead starts from this fixture's real visible source window.
    \\Exit: 0 COPY accepted; 3 cancelled; 4 drop rejected/NONE; 2 invalid invocation/identity/error.
    \\COPY is OLE admission, not proof that protected paste completed; inspect target separately.
;

fn parse(args: []const []const u8) !Options {
    var opts: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--run")) {
            opts.run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--source-window")) {
            opts.source_window = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--")) return error.InvalidArgument;
        const at = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidArgument;
        const key = arg[2..at];
        const value = arg[at + 1 ..];
        if (std.mem.eql(u8, key, "hwnd")) opts.hwnd = try std.fmt.parseInt(usize, value, 0) else if (std.mem.eql(u8, key, "pid")) opts.pid = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "birth")) opts.birth = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, key, "exe")) opts.exe = value else if (std.mem.eql(u8, key, "sha256")) opts.sha256 = value else if (std.mem.eql(u8, key, "work-dir")) opts.work_dir = value else if (std.mem.eql(u8, key, "case")) opts.case = std.meta.stringToEnum(Case, value) orelse return error.InvalidCase else if (std.mem.eql(u8, key, "timeout-ms")) opts.timeout_ms = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "x")) opts.x = try std.fmt.parseInt(i32, value, 10) else if (std.mem.eql(u8, key, "y")) opts.y = try std.fmt.parseInt(i32, value, 10) else return error.InvalidArgument;
    }
    if (!opts.run or opts.hwnd == 0 or opts.pid == 0 or opts.birth == 0 or opts.sha256.len != 64 or
        !std.fs.path.isAbsolute(opts.exe) or !std.fs.path.isAbsolute(opts.work_dir) or
        opts.timeout_ms < 100 or opts.timeout_ms > 30000 or (opts.x == null) != (opts.y == null)) return error.InvalidArgument;
    for (opts.sha256) |byte| if (!std.ascii.isHex(byte)) return error.InvalidHash;
    return opts;
}

const Target = struct {
    hwnd: HWND,
    pid: u32,
    process: H,
    fn live(self: Target) bool {
        if (WaitForSingleObject(self.process, 0) != 258 or IsWindow(self.hwnd) == 0) return false;
        var actual: u32 = 0;
        _ = GetWindowThreadProcessId(self.hwnd, &actual);
        return actual == self.pid;
    }
    fn contains(self: Target, point: POINT) bool {
        if (!self.live()) return false;
        const hit = WindowFromPoint(point) orelse return false;
        return hit == self.hwnd or IsChild(self.hwnd, hit) != 0;
    }
};

fn verifyTarget(init: std.process.Init, opts: Options) !Target {
    const alloc = init.arena.allocator();
    const hwnd: HWND = @ptrFromInt(opts.hwnd);
    const process = OpenProcess(0x00101000, 0, opts.pid) orelse return error.OpenTargetFailed;
    errdefer _ = CloseHandle(process);
    const target: Target = .{ .hwnd = hwnd, .pid = opts.pid, .process = process };
    if (!target.live()) return error.TargetChanged;
    var birth: u64 = 0;
    var unused: u64 = 0;
    if (GetProcessTimes(process, &birth, &unused, &unused, &unused) == 0 or birth != opts.birth) return error.TargetChanged;
    var actual: [32768]u16 = undefined;
    var count: u32 = actual.len;
    if (QueryFullProcessImageNameW(process, 0, &actual, &count) == 0) return error.TargetImageFailed;
    const expected = try std.unicode.utf8ToUtf16LeAllocZ(alloc, opts.exe);
    // Canonicalize both file paths via handles to reject path spelling tricks.
    const actual_z = try alloc.dupeZ(u16, actual[0..count]);
    var expected_path: [32768]u16 = undefined;
    var actual_path: [32768]u16 = undefined;
    const a = try canonical(actual_z, &actual_path);
    const b = try canonical(expected, &expected_path);
    if (CompareStringOrdinal(a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), 1) != 2) return error.TargetImageMismatch;
    const image = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.exe, alloc, .limited(512 * 1024 * 1024));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&hex, opts.sha256)) return error.TargetHashMismatch;
    if (!target.live()) return error.TargetChanged;
    return target;
}

fn canonical(path: [*:0]const u16, buffer: []u16) ![]u16 {
    const file = CreateFileW(path, 0, 7, null, 3, 0, null);
    if (file == std.os.windows.INVALID_HANDLE_VALUE) return error.ImageOpenFailed;
    defer _ = CloseHandle(file);
    const len = GetFinalPathNameByHandleW(file, buffer.ptr, @intCast(buffer.len), 0);
    if (len == 0 or len >= buffer.len) return error.ImagePathFailed;
    return buffer[0..len];
}

const Unknown = extern struct { vtable: *const UnknownVTable };
const UnknownVTable = extern struct {
    query: *const fn (*Unknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    add: *const fn (*Unknown) callconv(.winapi) u32,
    release: *const fn (*Unknown) callconv(.winapi) u32,
};
const DataObject = extern struct { vtable: *const DataVTable };
const DataVTable = extern struct {
    query: *const fn (*DataObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    add: *const fn (*DataObject) callconv(.winapi) u32,
    release: *const fn (*DataObject) callconv(.winapi) u32,
    get: *const fn (*DataObject, *const Format, *Medium) callconv(.winapi) HRESULT,
    get_here: *const fn (*DataObject, *const Format, *Medium) callconv(.winapi) HRESULT,
    query_get: *const fn (*DataObject, *const Format) callconv(.winapi) HRESULT,
    canonical: *const fn (*DataObject, *const Format, *Format) callconv(.winapi) HRESULT,
    set: *const fn (*DataObject, *const Format, *Medium, i32) callconv(.winapi) HRESULT,
    enumerate: *const fn (*DataObject, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    advise: *const fn (*DataObject, *const Format, u32, ?*anyopaque, *u32) callconv(.winapi) HRESULT,
    unadvise: *const fn (*DataObject, u32) callconv(.winapi) HRESULT,
    enum_advise: *const fn (*DataObject, *?*anyopaque) callconv(.winapi) HRESULT,
};
const DropSource = extern struct { vtable: *const DropVTable };
const DropVTable = extern struct {
    query: *const fn (*DropSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    add: *const fn (*DropSource) callconv(.winapi) u32,
    release: *const fn (*DropSource) callconv(.winapi) u32,
    continue_drag: *const fn (*DropSource, i32, u32) callconv(.winapi) HRESULT,
    feedback: *const fn (*DropSource, u32) callconv(.winapi) HRESULT,
};

const Source = struct {
    data: DataObject = .{ .vtable = &data_vtable },
    drop: DropSource = .{ .vtable = &drop_vtable },
    refs: std.atomic.Value(u32) = .init(1),
    alloc: std.mem.Allocator,
    bytes: []const u8,
    format: u16,
    target: Target,
    deadline: u64,
    gets: usize = 0,
    queries: usize = 0,
    releases: usize = 0,
    continuations: usize = 0,
    cancelled: bool = false,
    unterminated: bool = false,
    source_window: bool = false,
    fn retain(self: *Source) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(self: *Source) u32 {
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) self.alloc.destroy(self);
        return remaining;
    }
    fn fromData(value: *DataObject) *Source {
        return @alignCast(@fieldParentPtr("data", value));
    }
    fn fromDrop(value: *DropSource) *Source {
        return @alignCast(@fieldParentPtr("drop", value));
    }
    fn queryData(value: *DataObject, id: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        trace("query_data", ",\"iid_a\":{d}", .{id.a}, false);
        out.* = null;
        if (!equal(id, &iid_unknown) and !equal(id, &iid(0x10e))) return no_interface;
        _ = fromData(value).retain();
        out.* = value;
        return 0;
    }
    fn queryDrop(value: *DropSource, id: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        trace("query_drop", ",\"iid_a\":{d}", .{id.a}, false);
        out.* = null;
        if (!equal(id, &iid_unknown) and !equal(id, &iid(0x121))) return no_interface;
        _ = fromDrop(value).retain();
        out.* = value;
        return 0;
    }
    fn addData(value: *DataObject) callconv(.winapi) u32 {
        return fromData(value).retain();
    }
    fn releaseData(value: *DataObject) callconv(.winapi) u32 {
        return fromData(value).release();
    }
    fn addDrop(value: *DropSource) callconv(.winapi) u32 {
        return fromDrop(value).retain();
    }
    fn releaseDrop(value: *DropSource) callconv(.winapi) u32 {
        return fromDrop(value).release();
    }
    fn queryGet(value: *DataObject, format: *const Format) callconv(.winapi) HRESULT {
        trace("query_get_enter", ",\"format\":{d}", .{format.format}, false);
        const self = fromData(value);
        self.queries += 1;
        const result: HRESULT = if (self.target.live() and format.format == self.format and format.aspect == 1 and format.index == -1 and format.medium & 1 != 0) 0 else bad_format;
        trace("query_get_return", ",\"hresult\":{d}", .{@as(u32, @bitCast(result))}, false);
        return result;
    }
    fn get(value: *DataObject, format: *const Format, medium: *Medium) callconv(.winapi) HRESULT {
        trace("get_data_enter", ",\"format\":{d}", .{format.format}, true);
        defer trace("get_data_return", ",\"medium_kind\":{d}", .{medium.kind}, true);
        medium.* = .{};
        const self = fromData(value);
        if (queryGet(value, format) != 0) return bad_format;
        const handle = GlobalAlloc(0x0042, self.bytes.len) orelse return @bitCast(@as(u32, 0x8007000e));
        const memory = GlobalLock(handle) orelse {
            _ = GlobalFree(handle);
            return pointer_error;
        };
        // GlobalAlloc may round the requested length upward. Make padding
        // nonzero too, otherwise a malformed unterminated test gains a valid
        // UTF-16 NUL from the allocator and accidentally exercises success.
        if (self.unterminated) @memset(memory[0..GlobalSize(handle)], 0x7f);
        @memcpy(memory[0..self.bytes.len], self.bytes);
        _ = GlobalUnlock(handle);
        const owner = self.alloc.create(MediumOwner) catch {
            _ = GlobalFree(handle);
            return @bitCast(@as(u32, 0x8007000e));
        };
        _ = self.retain();
        owner.* = .{ .source = self, .handle = handle };
        self.gets += 1;
        medium.* = .{ .kind = 1, .handle = handle, .owner = &owner.interface };
        return 0;
    }
    fn getHere(_: *DataObject, _: *const Format, _: *Medium) callconv(.winapi) HRESULT {
        return not_implemented;
    }
    fn canonicalFormat(_: *DataObject, _: *const Format, out: *Format) callconv(.winapi) HRESULT {
        out.target = null;
        return not_implemented;
    }
    fn set(_: *DataObject, _: *const Format, _: *Medium, _: i32) callconv(.winapi) HRESULT {
        return not_implemented;
    }
    fn enumerate(value: *DataObject, direction: u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (direction != 1) return not_implemented;
        const source = fromData(value);
        const enumerator = source.alloc.create(Enumerator) catch return @bitCast(@as(u32, 0x8007000e));
        _ = source.retain();
        enumerator.* = .{ .source = source };
        out.* = &enumerator.interface;
        return 0;
    }
    fn advise(_: *DataObject, _: *const Format, _: u32, _: ?*anyopaque, out: *u32) callconv(.winapi) HRESULT {
        out.* = 0;
        return @bitCast(@as(u32, 0x80040003));
    }
    fn unadvise(_: *DataObject, _: u32) callconv(.winapi) HRESULT {
        return @bitCast(@as(u32, 0x80040003));
    }
    fn enumAdvise(_: *DataObject, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        return @bitCast(@as(u32, 0x80040003));
    }
    fn continueDrag(value: *DropSource, escape: i32, keys: u32) callconv(.winapi) HRESULT {
        const self = fromDrop(value);
        self.continuations += 1;
        trace("continue_enter", ",\"keys\":{d},\"escape\":{d},\"async_left\":{d},\"calls\":{d}", .{ keys, escape, @as(u16, @bitCast(GetAsyncKeyState(1))), self.continuations }, false);
        var point: POINT = undefined;
        if (self.cancelled or escape != 0 or GetTickCount64() >= self.deadline or GetCursorPos(&point) == 0 or
            ((!self.source_window or keys & 1 == 0) and !self.target.contains(point)))
        {
            self.cancelled = true;
            trace("continue_cancel", "", .{}, true);
            return 0x00040101;
        }
        trace("continue_point_valid", ",\"keys\":{d}", .{keys}, false);
        if (keys & 1 == 0) trace("continue_drop", "", .{}, true);
        return if (keys & 1 == 0) 0x00040100 else 0;
    }
    fn feedback(_: *DropSource, effect: u32) callconv(.winapi) HRESULT {
        trace("feedback", ",\"effect\":{d}", .{effect}, false);
        return 0x00040102;
    }
    const data_vtable: DataVTable = .{ .query = queryData, .add = addData, .release = releaseData, .get = get, .get_here = getHere, .query_get = queryGet, .canonical = canonicalFormat, .set = set, .enumerate = enumerate, .advise = advise, .unadvise = unadvise, .enum_advise = enumAdvise };
    const drop_vtable: DropVTable = .{ .query = queryDrop, .add = addDrop, .release = releaseDrop, .continue_drag = continueDrag, .feedback = feedback };
};

/// One owned visible source. OLE starts on the same STA that received the real
/// press and drag gesture, after releasing this window's mouse capture.
const DragWindow = struct {
    source: *Source,
    hwnd: ?HWND = null,
    timeout_ms: u32,
    idle_deadline: u64,
    down: ?POINT = null,
    dragging: bool = false,
    finished: bool = false,
    result: HRESULT = 0x00040101,
    effect: u32 = 0,
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GxOwnedOleDragSource");
    var current: ?*DragWindow = null;

    fn create(self: *DragWindow) !void {
        _ = SetProcessDpiAwarenessContext(-4);
        const instance = GetModuleHandleW(null) orelse return error.ModuleHandleFailed;
        if (RegisterClassW(&.{ .proc = proc, .instance = instance, .name = class_name }) == 0) return error.SourceClassFailed;
        var rect: RECT = undefined;
        if (GetWindowRect(self.source.target.hwnd, &rect) == 0) return error.TargetChanged;
        self.hwnd = CreateWindowExW(0, class_name, std.unicode.utf8ToUtf16LeStringLiteral("GX owned OLE source - drag this white area"), 0x00cf0000, rect.left + 24, rect.top + 24, 300, 160, null, null, instance, null) orelse return error.SourceWindowFailed;
        current = self;
        _ = ShowWindow(self.hwnd.?, 1);
        if (SetTimer(self.hwnd, 1, 100, null) == 0) return error.SourceTimerFailed;
        trace("source_window_ready", ",\"hwnd\":{d}", .{@intFromPtr(self.hwnd.?)}, true);
    }
    fn deinit(self: *DragWindow) void {
        current = null;
        if (self.hwnd) |hwnd| {
            _ = KillTimer(hwnd, 1);
            _ = DestroyWindow(hwnd);
        }
        self.hwnd = null;
    }
    fn pump(self: *DragWindow) !void {
        var message: MSG = undefined;
        while (!self.finished) {
            const result = GetMessageW(&message, null, 0, 0);
            if (result < 0) return error.SourceMessageFailed;
            if (result == 0) return error.SourceQuit;
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
    }
    fn proc(hwnd: HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        const self = current orelse return DefWindowProcW(hwnd, message, wparam, lparam);
        if (self.hwnd != hwnd) return DefWindowProcW(hwnd, message, wparam, lparam);
        switch (message) {
            0x201 => { // WM_LBUTTONDOWN
                if (!self.dragging and !self.finished) {
                    self.down = point(lparam);
                    _ = SetCapture(hwnd);
                    trace("source_mouse_down", "", .{}, true);
                }
                return 0;
            },
            0x200 => { // WM_MOUSEMOVE
                const origin = self.down orelse return 0;
                const now = point(lparam);
                if (!self.dragging and !self.finished and wparam & 1 != 0 and (@abs(now.x - origin.x) >= 6 or @abs(now.y - origin.y) >= 6)) {
                    self.dragging = true;
                    self.down = null;
                    _ = ReleaseCapture();
                    self.source.deadline = GetTickCount64() + self.timeout_ms;
                    trace("dodragdrop_enter", ",\"source_hwnd\":{d}", .{@intFromPtr(hwnd)}, true);
                    self.result = DoDragDrop(&self.source.data, &self.source.drop, 1, &self.effect);
                    trace("dodragdrop_return", ",\"hresult\":{d},\"effect\":{d}", .{ @as(u32, @bitCast(self.result)), self.effect }, true);
                    self.dragging = false;
                    self.finished = true;
                }
                return 0;
            },
            0x202 => { // WM_LBUTTONUP before crossing the drag threshold.
                self.down = null;
                _ = ReleaseCapture();
                return 0;
            },
            0x113 => if (!self.dragging and GetTickCount64() >= self.idle_deadline) {
                self.source.cancelled = true;
                self.finished = true;
                return 0;
            },
            0x10 => { // WM_CLOSE
                self.source.cancelled = true;
                if (!self.dragging) self.finished = true;
                return 0;
            },
            else => {},
        }
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    fn point(value: isize) POINT {
        const bits: usize = @bitCast(value);
        return .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
    }
};

const EnumInterface = extern struct { vtable: *const EnumVTable };
const EnumVTable = extern struct {
    query: *const fn (*EnumInterface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    add: *const fn (*EnumInterface) callconv(.winapi) u32,
    release: *const fn (*EnumInterface) callconv(.winapi) u32,
    next: *const fn (*EnumInterface, u32, [*]Format, ?*u32) callconv(.winapi) HRESULT,
    skip: *const fn (*EnumInterface, u32) callconv(.winapi) HRESULT,
    reset: *const fn (*EnumInterface) callconv(.winapi) HRESULT,
    clone: *const fn (*EnumInterface, *?*EnumInterface) callconv(.winapi) HRESULT,
};
const Enumerator = struct {
    interface: EnumInterface = .{ .vtable = &vtable },
    source: *Source,
    refs: u32 = 1,
    consumed: bool = false,
    fn parent(value: *EnumInterface) *Enumerator {
        return @alignCast(@fieldParentPtr("interface", value));
    }
    fn query(value: *EnumInterface, id: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!equal(id, &iid_unknown) and !equal(id, &iid(0x103))) return no_interface;
        _ = add(value);
        out.* = value;
        return 0;
    }
    fn add(value: *EnumInterface) callconv(.winapi) u32 {
        const self = parent(value);
        self.refs += 1;
        return self.refs;
    }
    fn release(value: *EnumInterface) callconv(.winapi) u32 {
        const self = parent(value);
        self.refs -= 1;
        const remaining = self.refs;
        if (remaining == 0) {
            const source = self.source;
            source.alloc.destroy(self);
            _ = source.release();
        }
        return remaining;
    }
    fn next(value: *EnumInterface, count: u32, formats: [*]Format, fetched: ?*u32) callconv(.winapi) HRESULT {
        if (fetched) |out| out.* = 0 else if (count != 1) return pointer_error;
        const self = parent(value);
        if (count == 0) return 0;
        if (self.consumed) return 1;
        formats[0] = .{ .format = self.source.format };
        self.consumed = true;
        if (fetched) |out| out.* = 1;
        return if (count == 1) 0 else 1;
    }
    fn skip(value: *EnumInterface, count: u32) callconv(.winapi) HRESULT {
        if (count == 0) return 0;
        const self = parent(value);
        const available = !self.consumed;
        self.consumed = true;
        return if (available and count == 1) 0 else 1;
    }
    fn reset(value: *EnumInterface) callconv(.winapi) HRESULT {
        parent(value).consumed = false;
        return 0;
    }
    fn clone(value: *EnumInterface, out: *?*EnumInterface) callconv(.winapi) HRESULT {
        out.* = null;
        const self = parent(value);
        const copy = self.source.alloc.create(Enumerator) catch return @bitCast(@as(u32, 0x8007000e));
        _ = self.source.retain();
        copy.* = .{ .source = self.source, .consumed = self.consumed };
        out.* = &copy.interface;
        return 0;
    }
    const vtable: EnumVTable = .{ .query = query, .add = add, .release = release, .next = next, .skip = skip, .reset = reset, .clone = clone };
};

/// Wake only this fixture's OLE modal loop; do not inject global mouse/keyboard
/// input or send synthetic messages to the target. This lets QueryContinueDrag
/// enforce the deadline even while the physical pointer does not move.
fn dragTimer(_: ?HWND, _: u32, _: usize, _: u32) callconv(.winapi) void {
    var point: POINT = undefined;
    if (GetCursorPos(&point) == 0) return;
    const packed_point: u32 = @as(u16, @bitCast(@as(i16, @truncate(point.x)))) |
        (@as(u32, @as(u16, @bitCast(@as(i16, @truncate(point.y))))) << 16);
    const buttons: usize = if (@as(u16, @bitCast(GetAsyncKeyState(1))) & 0x8000 != 0) 1 else 0;
    const posted = PostThreadMessageW(GetCurrentThreadId(), 0x200, buttons, @bitCast(@as(usize, packed_point)));
    trace("timer", ",\"buttons\":{d},\"posted\":{d}", .{ buttons, posted }, false);
}

const MediumOwner = struct {
    interface: Unknown = .{ .vtable = &vtable },
    refs: u32 = 1,
    source: *Source,
    handle: H,
    fn parent(value: *Unknown) *MediumOwner {
        return @alignCast(@fieldParentPtr("interface", value));
    }
    fn query(value: *Unknown, id: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!equal(id, &iid_unknown)) return no_interface;
        _ = add(value);
        out.* = value;
        return 0;
    }
    fn add(value: *Unknown) callconv(.winapi) u32 {
        const self = parent(value);
        self.refs += 1;
        return self.refs;
    }
    fn release(value: *Unknown) callconv(.winapi) u32 {
        const self = parent(value);
        trace("medium_release_enter", ",\"refs\":{d}", .{self.refs}, true);
        self.refs -= 1;
        const remaining = self.refs;
        if (remaining == 0) {
            const source = self.source;
            _ = GlobalFree(self.handle);
            source.releases += 1;
            source.alloc.destroy(self);
            _ = source.release();
        }
        trace("medium_release_return", ",\"refs\":{d}", .{remaining}, true);
        return remaining;
    }
    const vtable: UnknownVTable = .{ .query = query, .add = add, .release = release };
};

fn widePayload(alloc: std.mem.Allocator, text: []const u8, terminated: bool) ![]const u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(wide);
    return alloc.dupe(u8, std.mem.sliceAsBytes(wide[0 .. wide.len + @as(usize, if (terminated) 1 else 0)]));
}
fn filePayload(alloc: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.appendNTimes(alloc, 0, 20);
    std.mem.writeInt(u32, list.items[0..4], 20, .little);
    std.mem.writeInt(u32, list.items[16..20], 1, .little);
    for (paths) |path| {
        const wide = try widePayload(alloc, path, true);
        defer alloc.free(wide);
        try list.appendSlice(alloc, wide);
    }
    try list.appendSlice(alloc, &.{ 0, 0 });
    return list.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stderr().writer(init.io, &buffer);
        writer.interface.print("{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        return 2;
    };
}

fn run(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const arguments = (try init.minimal.args.toSlice(alloc))[1..];
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "--help")) {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        try writer.interface.print("{s}\n", .{usage});
        try writer.interface.flush();
        return 0;
    }
    const opts = try parse(arguments);
    const target = try verifyTarget(init, opts);
    defer _ = CloseHandle(target.process);
    const folder = try std.fmt.allocPrint(alloc, "gx-ole-{d}-{d}", .{ GetCurrentProcessId(), GetTickCount64() });
    var parent = try std.Io.Dir.openDirAbsolute(init.io, opts.work_dir, .{});
    defer parent.close(init.io);
    try parent.createDir(init.io, folder, .default_dir);
    var dir = try parent.openDir(init.io, folder, .{});
    defer dir.close(init.io);
    const root = try dir.realPathFileAlloc(init.io, ".", alloc);
    const trace_path = try std.unicode.utf8ToUtf16LeAllocZ(alloc, try std.fs.path.join(alloc, &.{ root, "trace.jsonl" }));
    const trace_handle = CreateFileW(trace_path, 0x40000000, 1, null, 1, 0, null);
    if (trace_handle == std.os.windows.INVALID_HANDLE_VALUE) return error.TraceCreateFailed;
    trace_file = trace_handle;
    defer {
        trace_file = null;
        _ = CloseHandle(trace_handle);
    }
    trace("fixture_verified", ",\"target_pid\":{d},\"target_hwnd\":{d}", .{ opts.pid, opts.hwnd }, true);
    const marker = try std.fmt.allocPrint(alloc, "GX_OLE_FIXTURE_{d}", .{GetCurrentProcessId()});
    var format: u16 = 13;
    const bytes: []const u8 = switch (opts.case) {
        .text => try widePayload(alloc, marker, true),
        .unicode => try widePayload(alloc, try std.fmt.allocPrint(alloc, "{s} 中文 café 🧪", .{marker}), true),
        .multiline => try widePayload(alloc, try std.fmt.allocPrint(alloc, "# {s}\r\n# second-line", .{marker}), true),
        .unterminated => try widePayload(alloc, marker, false),
        .text_limit => try widePayload(alloc, try alloc.dupe(u8, &(@as([1024 * 1024 + 1]u8, @splat('x')))), true),
        .single_file, .files, .shell_metachar_files, .quoted_path, .too_many_files, .uri, .bad_uri => blk: {
            try dir.writeFile(init.io, .{ .sub_path = "GX OLE 中文 🧪 sample.txt", .data = "Owned OLE test input.\n" });
            const path = try std.fs.path.join(alloc, &.{ root, "GX OLE 中文 🧪 sample.txt" });
            if (opts.case == .single_file or opts.case == .files or opts.case == .shell_metachar_files or opts.case == .quoted_path or opts.case == .too_many_files) {
                format = 15;
                if (opts.case == .single_file) break :blk try filePayload(alloc, &.{path});
                // Quotes are illegal in real Win32 filenames. This is explicitly
                // a synthetic hostile HDROP value; no such file is opened.
                if (opts.case == .quoted_path) break :blk try filePayload(alloc, &.{try std.fs.path.join(alloc, &.{ root, "bad\"&echo GX_MUST_NOT_EXECUTE.txt" })});
                if (opts.case == .too_many_files) {
                    const paths = try alloc.alloc([]const u8, 257);
                    @memset(paths, path);
                    break :blk try filePayload(alloc, paths);
                }
                const second = if (opts.case == .shell_metachar_files) "GX ! percent%.txt" else "GX second sample.txt";
                try dir.writeFile(init.io, .{ .sub_path = second, .data = "Owned boundary filename.\n" });
                break :blk try filePayload(alloc, &.{ path, try std.fs.path.join(alloc, &.{ root, second }) });
            }
            format = @intCast(RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("UniformResourceLocatorW")));
            if (format == 0) return error.FormatRegistrationFailed;
            if (opts.case == .bad_uri) break :blk try widePayload(alloc, "file:///C:/bad%00path", true);
            var uri: std.ArrayList(u8) = .empty;
            try uri.appendSlice(alloc, "file:///");
            for (path) |byte| {
                if (byte == '\\') try uri.append(alloc, '/') else if (std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '-' or byte == '_' or byte == '.') try uri.append(alloc, byte) else {
                    const hex = "0123456789ABCDEF";
                    try uri.appendSlice(alloc, &.{ '%', hex[byte >> 4], hex[byte & 15] });
                }
            }
            break :blk try widePayload(alloc, uri.items, true);
        },
        .bad_hdrop => blk: {
            format = 15;
            const data = try alloc.alloc(u8, 24);
            @memset(data, 0);
            std.mem.writeInt(u32, data[0..4], 0xfffffff0, .little);
            std.mem.writeInt(u32, data[16..20], 1, .little);
            break :blk data;
        },
    };
    const hr = OleInitialize(null);
    trace("ole_initialized", ",\"hresult\":{d}", .{@as(u32, @bitCast(hr))}, true);
    if (hr < 0) return error.OleInitializeFailed;
    defer OleUninitialize();
    var point: POINT = undefined;
    if (opts.x) |x| {
        point = .{ .x = x, .y = opts.y.? };
        if (!target.contains(point)) return error.UnownedTargetPoint;
        if (SetCursorPos(point.x, point.y) == 0) return error.CursorMoveFailed;
    }
    if (!opts.source_window) {
        if (GetCursorPos(&point) == 0 or !target.contains(point)) return error.UnownedTargetPoint;
        if (@as(u16, @bitCast(GetAsyncKeyState(1))) & 0x8000 == 0) return error.LeftButtonNotHeld;
    }
    const source = try init.gpa.create(Source);
    source.* = .{ .alloc = init.gpa, .bytes = bytes, .format = format, .target = target, .deadline = GetTickCount64() + opts.timeout_ms, .unterminated = opts.case == .unterminated, .source_window = opts.source_window };
    defer _ = source.release();
    var source_window: DragWindow = .{ .source = source, .timeout_ms = opts.timeout_ms, .idle_deadline = GetTickCount64() + 30000 };
    defer source_window.deinit();
    if (opts.source_window) try source_window.create();
    const ready = try std.json.Stringify.valueAlloc(alloc, .{ .status = "ready", .source_pid = GetCurrentProcessId(), .source_hwnd = if (source_window.hwnd) |hwnd| @intFromPtr(hwnd) else 0, .target_pid = opts.pid, .target_birth = opts.birth, .target_hwnd = opts.hwnd, .case = @tagName(opts.case), .app_sha256 = opts.sha256 }, .{});
    try dir.writeFile(init.io, .{ .sub_path = "ready.json", .data = ready });
    const timer = SetTimer(null, 0, 50, dragTimer);
    trace("timer_installed", ",\"timer\":{d}", .{timer}, true);
    if (timer == 0) return error.DragTimerFailed;
    defer _ = KillTimer(null, timer);
    var effect: u32 = 0;
    const result = if (opts.source_window) result: {
        try source_window.pump();
        effect = source_window.effect;
        break :result source_window.result;
    } else result: {
        trace("dodragdrop_enter", "", .{}, true);
        const native_result = DoDragDrop(&source.data, &source.drop, 1, &effect);
        trace("dodragdrop_return", ",\"hresult\":{d},\"effect\":{d}", .{ @as(u32, @bitCast(native_result)), effect }, true);
        break :result native_result;
    };
    const evidence = try std.json.Stringify.valueAlloc(alloc, .{ .status = "finished", .hresult = @as(u32, @bitCast(result)), .effect = effect, .source_pid = GetCurrentProcessId(), .target_pid = opts.pid, .target_birth = opts.birth, .target_hwnd = opts.hwnd, .app_sha256 = opts.sha256, .case = @tagName(opts.case), .payload_bytes = bytes.len, .query_get_data = source.queries, .get_data = source.gets, .medium_releases = source.releases, .continue_drag_calls = source.continuations, .cancelled = source.cancelled, .target_alive = target.live(), .evidence_dir = root, .paste_completed = "PENDING_TARGET_VERIFICATION", .clipboard_access = false, .enter_injected = false }, .{});
    try dir.writeFile(init.io, .{ .sub_path = "evidence.json", .data = evidence });
    var out_buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    try writer.interface.print("{s}\n", .{evidence});
    try writer.interface.flush();
    if (source.gets != source.releases) return error.MediumNotReleased;
    if (result == 0x00040101 or source.cancelled) return 3;
    if (result < 0) return error.DoDragDropFailed;
    return if (result == 0x00040100 and effect == 1) 0 else 4;
}

test "fixture requires explicit run and complete owned target identity" {
    try std.testing.expectError(error.InvalidArgument, parse(&.{}));
    try std.testing.expectError(error.InvalidArgument, parse(&.{ "--run", "--pid=1" }));
}
test "fixture native payload encodes bounded terminated Unicode and HDROP" {
    const alloc = std.testing.allocator;
    const text = try widePayload(alloc, "中文", true);
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 6), text.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, text[text.len - 2 ..]);
    const files = try filePayload(alloc, &.{ "C:\\owned\\a.txt", "C:\\owned\\b.txt" });
    defer alloc.free(files);
    try std.testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, files[0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, files[16..20], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, files[files.len - 4 ..]);
}
