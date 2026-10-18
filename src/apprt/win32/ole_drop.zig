//! Native OLE COPY-only drop targets. No clipboard reads and no terminal input.
//! Foreign COM calls may pump the GUI: recheck the attachment after every call.
const std = @import("std");
const w32 = @import("win32.zig");
const ComApartment = @import("ComApartment.zig");
const refs = @import("../../gx/ui_ref.zig");
pub const data = @import("drop_data.zig");
const Allocator = std.mem.Allocator;
const HRESULT = i32;
const COPY: u32 = 1;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const IID_UNKNOWN = guid(0, 0, 0, .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 });
const IID_TARGET = guid(0x00000122, 0, 0, .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 });
const CLSID_HELPER = guid(0x4657278a, 0x411b, 0x11d2, .{ 0x83, 0x9a, 0, 0xc0, 0x4f, 0xd9, 0x18, 0xd0 });
const IID_HELPER = guid(0x4657278b, 0x411b, 0x11d2, .{ 0x83, 0x9a, 0, 0xc0, 0x4f, 0xd9, 0x18, 0xd0 });

fn guid(a: u32, b: u16, c: u16, d: [8]u8) w32.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = c, .Data4 = d };
}

pub const Phase = enum { enter, over, leave, queued, rejected };
pub const Callbacks = struct {
    context: *anyopaque,
    /// GUI-only liveness query. Must not pump messages or retain a pointer.
    is_live: *const fn (*anyopaque, refs.Attachment) bool,
    /// A true return takes ownership of the payload; false retains it here.
    /// Queue only: resolve again and protected-paste later on the GUI thread.
    post: *const fn (*anyopaque, refs.Attachment, data.Payload) bool,
    feedback: *const fn (*anyopaque, refs.Attachment, Phase, w32.POINT, bool) void,
};

pub const FormatEtc = extern struct {
    format: u16,
    target_device: ?*anyopaque = null,
    aspect: u32 = 1,
    index: i32 = -1,
    medium: u32 = 1,
};
pub const Medium = extern struct {
    kind: u32 = 0,
    handle: ?*anyopaque = null,
    release_owner: ?*anyopaque = null,
};
pub const DataObject = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetData: *const fn (*DataObject, *const FormatEtc, *Medium) callconv(.winapi) HRESULT,
        GetDataHere: *const anyopaque,
        QueryGetData: *const fn (*DataObject, *const FormatEtc) callconv(.winapi) HRESULT,
        GetCanonicalFormatEtc: *const anyopaque,
        SetData: *const anyopaque,
        EnumFormatEtc: *const anyopaque,
        DAdvise: *const anyopaque,
        DUnadvise: *const anyopaque,
        EnumDAdvise: *const anyopaque,
    };
};

pub const Interface = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*Interface, *const w32.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Interface) callconv(.winapi) u32,
        Release: *const fn (*Interface) callconv(.winapi) u32,
        DragEnter: *const fn (*Interface, *DataObject, u32, w32.POINT, *u32) callconv(.winapi) HRESULT,
        DragOver: *const fn (*Interface, u32, w32.POINT, *u32) callconv(.winapi) HRESULT,
        DragLeave: *const fn (*Interface) callconv(.winapi) HRESULT,
        Drop: *const fn (*Interface, *DataObject, u32, w32.POINT, *u32) callconv(.winapi) HRESULT,
    };
};
const Helper = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*Helper) callconv(.winapi) u32,
        Release: *const fn (*Helper) callconv(.winapi) u32,
        DragEnter: *const fn (*Helper, w32.HWND, *DataObject, *const w32.POINT, u32) callconv(.winapi) HRESULT,
        DragLeave: *const fn (*Helper) callconv(.winapi) HRESULT,
        DragOver: *const fn (*Helper, *const w32.POINT, u32) callconv(.winapi) HRESULT,
        Drop: *const fn (*Helper, *DataObject, *const w32.POINT, u32) callconv(.winapi) HRESULT,
        Show: *const fn (*Helper, i32) callconv(.winapi) HRESULT,
    },
};

const Kind = enum { files, uri, text };
const Format = struct { kind: Kind, value: u16 };

pub const Target = struct {
    interface: Interface = .{ .vtable = &vtable },
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    alloc: Allocator,
    hwnd: w32.HWND,
    attachment: refs.Attachment,
    callbacks: ?Callbacks,
    helper: ?*Helper = null,
    active: bool = true,
    registered: bool = false,
    owner_released: bool = false,
    supported: bool = false,
    uri_format: u16 = 0,
    retired_next: ?*Target = null,
    retired_destroy_hwnd: bool = false,
    retired_destroy_parent: ?w32.HWND = null,

    pub fn create(alloc: Allocator, apartment: *ComApartment, hwnd: w32.HWND, attachment: refs.Attachment, callbacks: Callbacks) !*Target {
        if (!attachment.isValid() or attachment.object.kind != .surface) return error.InvalidTarget;
        try apartment.ensureOle();
        const self = try alloc.create(Target);
        self.* = .{ .alloc = alloc, .hwnd = hwnd, .attachment = attachment, .callbacks = callbacks };
        errdefer _ = self.destroy();
        self.uri_format = @intCast(w32.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("UniformResourceLocatorW")));
        var helper: ?*anyopaque = null;
        if (w32.CoCreateInstance(&CLSID_HELPER, null, 1, &IID_HELPER, &helper) >= 0) {
            self.helper = @ptrCast(@alignCast(helper));
        }
        // COM construction can run a modal loop. Do not register a stale view.
        if (!self.liveAt(attachment)) return error.InvalidTarget;
        if (RegisterDragDrop(hwnd, &self.interface) < 0) return error.RegistrationFailed;
        self.registered = true;
        if (!self.liveAt(attachment)) return error.InvalidTarget;
        return self;
    }

    /// Inert first, then revoke. Remaining external COM references own only this
    /// detached allocation; they cannot invoke callbacks or release GUI objects.
    pub fn destroy(self: *Target) HRESULT {
        if (self.owner_released) return 0;
        self.owner_released = true;
        self.invalidate();
        const helper = self.helper;
        self.helper = null;
        if (helper) |h| {
            _ = h.vtable.DragLeave(h);
            _ = h.vtable.Release(h);
        }
        var result: HRESULT = 0;
        if (self.registered) {
            self.registered = false;
            result = RevokeDragDrop(self.hwnd);
        }
        _ = release(&self.interface);
        return result;
    }

    /// Pure GUI retirement. Safe inside a tree transaction or Surface teardown:
    /// no foreign COM, HWND calls, allocation, or message pumping. The owner's
    /// intrusive retirement queue later calls destroy at a safe GUI boundary.
    pub fn invalidate(self: *Target) void {
        self.active = false;
        self.supported = false;
        self.callbacks = null;
    }

    /// Call on GUI attachment revision changes. A reparent that replaces HWND
    /// must revoke/destroy and create a new target instead.
    pub fn updateAttachment(self: *Target, attachment: refs.Attachment) bool {
        if (!self.active or !attachment.isValid() or !attachment.object.matches(self.attachment.object)) return false;
        self.supported = false;
        self.attachment = attachment;
        return self.live();
    }

    fn live(self: *const Target) bool {
        const callbacks = self.callbacks orelse return false;
        return self.active and callbacks.is_live(callbacks.context, self.attachment);
    }

    fn liveAt(self: *const Target, expected: refs.Attachment) bool {
        return self.attachment.matches(expected) and self.live();
    }

    fn helperRef(self: *Target, expected: refs.Attachment) ?*Helper {
        const helper = self.helper orelse return null;
        _ = helper.vtable.AddRef(helper);
        if (!self.liveAt(expected)) {
            _ = helper.vtable.Release(helper);
            return null;
        }
        return helper;
    }

    fn notify(self: *Target, expected: refs.Attachment, phase: Phase, point: w32.POINT, accepted: bool) void {
        if (!self.liveAt(expected)) return;
        const callbacks = self.callbacks.?;
        callbacks.feedback(callbacks.context, expected, phase, point, accepted);
    }

    fn choose(self: *Target, expected: refs.Attachment, object: *DataObject) ?Format {
        const formats = [_]Format{ .{ .kind = .files, .value = 15 }, .{ .kind = .uri, .value = self.uri_format }, .{ .kind = .text, .value = 13 } };
        for (formats) |format| {
            if (!self.liveAt(expected)) return null;
            if (format.value == 0) continue;
            const supported = object.vtable.QueryGetData(object, &.{ .format = format.value }) == 0;
            if (!self.liveAt(expected)) return null;
            if (supported) return format;
        }
        return null;
    }

    fn read(self: *Target, expected: refs.Attachment, object: *DataObject, format: Format) data.Error!data.Payload {
        var medium: Medium = .{};
        if (object.vtable.GetData(object, &.{ .format = format.value }, &medium) < 0) return error.Unsupported;
        defer ReleaseStgMedium(&medium);
        if (!self.liveAt(expected)) return error.InvalidData;
        if (medium.kind != 1) return error.Unsupported;
        const handle = medium.handle orelse return error.InvalidData;
        const size = w32.GlobalSize(handle);
        if (size == 0) return error.InvalidData;
        if (size > data.max_medium_bytes) return error.TooLarge;
        const memory = w32.GlobalLock(handle) orelse return error.InvalidData;
        defer _ = w32.GlobalUnlock(handle);
        const bytes = memory[0..size];
        switch (format.kind) {
            .files => return data.hdrop(self.alloc, bytes) catch |err| switch (err) {
                error.Unsupported => self.readAnsiFiles(@ptrCast(handle)),
                else => err,
            },
            .text => return data.unicodeText(self.alloc, bytes),
            .uri => {
                var text = try data.unicodeText(self.alloc, bytes);
                defer text.deinit();
                return data.fileUri(self.alloc, text.content.text);
            },
        }
    }

    fn readAnsiFiles(self: *Target, handle: w32.HDROP) data.Error!data.Payload {
        const count = w32.DragQueryFileW(handle, 0xffffffff, null, 0);
        if (count == 0) return error.InvalidData;
        if (count > data.max_files) return error.TooLarge;
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |path| self.alloc.free(path);
            paths.deinit(self.alloc);
        }
        var total: usize = 0;
        for (0..count) |index| {
            const length = w32.DragQueryFileW(handle, @intCast(index), null, 0);
            if (length == 0) return error.InvalidData;
            if (length > data.max_path_units) return error.TooLarge;
            const wide = try self.alloc.alloc(u16, length + 1);
            defer self.alloc.free(wide);
            if (w32.DragQueryFileW(handle, @intCast(index), wide.ptr, @intCast(wide.len)) != length) return error.InvalidData;
            const path = std.unicode.utf16LeToUtf8Alloc(self.alloc, wide[0..length]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidData,
            };
            errdefer self.alloc.free(path);
            total += path.len;
            if (total > data.max_bytes) return error.TooLarge;
            try paths.append(self.alloc, path);
        }
        return data.filePaths(self.alloc, paths.items);
    }
};

fn fromInterface(value: *Interface) *Target {
    return @alignCast(@fieldParentPtr("interface", value));
}
fn addRef(value: *Interface) callconv(.winapi) u32 {
    return fromInterface(value).count.fetchAdd(1, .monotonic) + 1;
}
fn release(value: *Interface) callconv(.winapi) u32 {
    const self = fromInterface(value);
    const remaining = self.count.fetchSub(1, .acq_rel) - 1;
    if (remaining == 0) self.alloc.destroy(self);
    return remaining;
}
fn query(value: *Interface, iid: *const w32.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&IID_UNKNOWN)) or
        std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&IID_TARGET)))
    {
        _ = addRef(value);
        out.* = value;
        return 0;
    }
    return E_NOINTERFACE;
}
fn enter(value: *Interface, object: *DataObject, _: u32, point: w32.POINT, effect: *u32) callconv(.winapi) HRESULT {
    _ = addRef(value);
    defer _ = release(value);
    const self = fromInterface(value);
    const expected = self.attachment;
    const allowed = effect.* & COPY != 0;
    effect.* = 0;
    self.supported = allowed and self.choose(expected, object) != null;
    if (!self.liveAt(expected)) return 0;
    effect.* = if (self.supported) COPY else 0;
    if (self.helperRef(expected)) |helper| {
        defer _ = helper.vtable.Release(helper);
        _ = helper.vtable.DragEnter(helper, self.hwnd, object, &point, effect.*);
    }
    if (!self.liveAt(expected)) {
        effect.* = 0;
        return 0;
    }
    self.notify(expected, .enter, point, effect.* != 0);
    if (!self.liveAt(expected)) effect.* = 0;
    return 0;
}
fn over(value: *Interface, _: u32, point: w32.POINT, effect: *u32) callconv(.winapi) HRESULT {
    _ = addRef(value);
    defer _ = release(value);
    const self = fromInterface(value);
    const expected = self.attachment;
    effect.* = if (self.liveAt(expected) and self.supported and effect.* & COPY != 0) COPY else 0;
    if (!self.liveAt(expected)) return 0;
    if (self.helperRef(expected)) |helper| {
        defer _ = helper.vtable.Release(helper);
        _ = helper.vtable.DragOver(helper, &point, effect.*);
    }
    if (!self.liveAt(expected)) {
        effect.* = 0;
        return 0;
    }
    self.notify(expected, .over, point, effect.* != 0);
    if (!self.liveAt(expected)) effect.* = 0;
    return 0;
}
fn leave(value: *Interface) callconv(.winapi) HRESULT {
    _ = addRef(value);
    defer _ = release(value);
    const self = fromInterface(value);
    const expected = self.attachment;
    return leaveAt(self, expected);
}
fn leaveAt(self: *Target, expected: refs.Attachment) HRESULT {
    self.supported = false;
    if (self.helperRef(expected)) |helper| {
        defer _ = helper.vtable.Release(helper);
        _ = helper.vtable.DragLeave(helper);
    }
    self.notify(expected, .leave, .{ .x = 0, .y = 0 }, false);
    return 0;
}
/// Diagnostic counts are GUI/COM-apartment owned and contain no payload data.
pub const FixtureCounts = struct {
    drops: usize = 0,
    queued: usize = 0,
    pub fn record(self: *FixtureCounts, enabled: bool, comptime field: []const u8) void {
        if (enabled) @field(self, field) +|= 1;
    }
};
pub var fixture_counts: FixtureCounts = .{};

fn drop(value: *Interface, object: *DataObject, _: u32, point: w32.POINT, effect: *u32) callconv(.winapi) HRESULT {
    fixture_counts.record(@import("remote_test.zig").enabled(), "drops");
    _ = addRef(value);
    defer _ = release(value);
    const self = fromInterface(value);
    const expected = self.attachment;
    const allowed = effect.* & COPY != 0;
    effect.* = 0;
    self.supported = false;
    if (!allowed) return leaveAt(self, expected);
    const format = self.choose(expected, object) orelse return leaveAt(self, expected);
    var payload = self.read(expected, object, format) catch {
        self.notify(expected, .rejected, point, false);
        return leaveAt(self, expected);
    };
    var transferred = false;
    defer if (!transferred) payload.deinit();
    // ReleaseStgMedium above may itself invoke foreign IUnknown::Release.
    if (!self.liveAt(expected)) return 0;
    const callbacks = self.callbacks.?;
    transferred = callbacks.post(callbacks.context, expected, payload);
    if (transferred) fixture_counts.record(@import("remote_test.zig").enabled(), "queued");
    if (transferred) effect.* = COPY;
    if (self.helperRef(expected)) |helper| {
        defer _ = helper.vtable.Release(helper);
        _ = helper.vtable.Drop(helper, object, &point, effect.*);
    }
    self.notify(expected, if (transferred) .queued else .rejected, point, transferred);
    if (!self.liveAt(expected)) effect.* = 0;
    return 0;
}

test "OLE fixture counters do not change without the test gate" {
    var counts: FixtureCounts = .{};
    counts.record(false, "drops");
    counts.record(false, "queued");
    try std.testing.expectEqualDeep(FixtureCounts{}, counts);
    counts.record(true, "drops");
    try std.testing.expectEqual(@as(usize, 1), counts.drops);
}
const vtable: Interface.VTable = .{ .QueryInterface = query, .AddRef = addRef, .Release = release, .DragEnter = enter, .DragOver = over, .DragLeave = leave, .Drop = drop };
extern "ole32" fn RegisterDragDrop(w32.HWND, *Interface) callconv(.winapi) HRESULT;
extern "ole32" fn RevokeDragDrop(w32.HWND) callconv(.winapi) HRESULT;
extern "ole32" fn ReleaseStgMedium(*Medium) callconv(.winapi) void;

test "OLE wire layouts retain COM pointer alignment" {
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 32 else 20), @sizeOf(FormatEtc));
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 12), @sizeOf(Medium));
    try std.testing.expectEqual(@as(usize, 7 * @sizeOf(usize)), @sizeOf(Interface.VTable));
    try std.testing.expectEqual(@as(usize, 12 * @sizeOf(usize)), @sizeOf(DataObject.VTable));
}

const TestContext = struct {
    payload: ?data.Payload = null,
    fn live(_: *anyopaque, _: refs.Attachment) bool {
        return true;
    }
    fn post(context: *anyopaque, _: refs.Attachment, payload: data.Payload) bool {
        const self: *TestContext = @ptrCast(@alignCast(context));
        self.payload = payload;
        return true;
    }
    fn feedback(_: *anyopaque, _: refs.Attachment, _: Phase, _: w32.POINT, _: bool) void {}
    fn callbacks(self: *TestContext) Callbacks {
        return .{ .context = self, .is_live = live, .post = post, .feedback = feedback };
    }
};

fn testAttachment() refs.Attachment {
    return .{
        .object = .{ .epoch = 1, .kind = .surface, .id = 1, .generation = 1 },
        .owner = .{ .epoch = 1, .kind = .window, .id = 2, .generation = 1 },
        .revision = 1,
    };
}

const TestSource = struct {
    object: DataObject = .{ .vtable = &object_vtable },
    release_object: Unknown = .{ .vtable = &unknown_vtable },
    handle: ?*anyopaque = null,
    releases: usize = 0,
    invalidates: ?*Target = null,
    renew_at_get: ?*Target = null,
    renew_at_release: ?*Target = null,

    const Unknown = extern struct {
        vtable: *const VTable,
        const VTable = extern struct {
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*Unknown) callconv(.winapi) u32,
        };
    };
    fn unused() callconv(.winapi) void {}
    const unknown_vtable: Unknown.VTable = .{
        .QueryInterface = @ptrCast(&unused),
        .AddRef = @ptrCast(&unused),
        .Release = releaseMedium,
    };
    fn releaseMedium(value: *Unknown) callconv(.winapi) u32 {
        const self: *TestSource = @fieldParentPtr("release_object", value);
        self.releases += 1;
        if (self.handle) |handle| _ = w32.GlobalFree(handle);
        self.handle = null;
        if (self.renew_at_release) |target| renew(target);
        return 0;
    }
    fn get(value: *DataObject, _: *const FormatEtc, medium: *Medium) callconv(.winapi) HRESULT {
        const self: *TestSource = @fieldParentPtr("object", value);
        const handle = w32.GlobalAlloc(0x0042, 8) orelse return @bitCast(@as(u32, 0x8007000e));
        const memory = w32.GlobalLock(handle) orelse {
            _ = w32.GlobalFree(handle);
            return @bitCast(@as(u32, 0x8007000e));
        };
        @memcpy(memory[0..8], &[_]u8{ 'a', 0, '\r', 0, '\n', 0, 0, 0 });
        _ = w32.GlobalUnlock(handle);
        self.handle = handle;
        medium.* = .{ .kind = 1, .handle = handle, .release_owner = &self.release_object };
        if (self.renew_at_get) |target| renew(target);
        return 0;
    }
    fn renew(target: *Target) void {
        var attachment = target.attachment;
        attachment.revision += 1;
        _ = target.updateAttachment(attachment);
    }
    fn queryData(value: *DataObject, format: *const FormatEtc) callconv(.winapi) HRESULT {
        const self: *TestSource = @fieldParentPtr("object", value);
        if (self.invalidates) |target| target.active = false;
        return if (format.format == 13) 0 else @bitCast(@as(u32, 0x80040064));
    }
    const object_vtable: DataObject.VTable = .{
        .QueryInterface = @ptrCast(&unused),
        .AddRef = @ptrCast(&unused),
        .Release = @ptrCast(&unused),
        .GetData = get,
        .GetDataHere = @ptrCast(&unused),
        .QueryGetData = queryData,
        .GetCanonicalFormatEtc = @ptrCast(&unused),
        .SetData = @ptrCast(&unused),
        .EnumFormatEtc = @ptrCast(&unused),
        .DAdvise = @ptrCast(&unused),
        .DUnadvise = @ptrCast(&unused),
        .EnumDAdvise = @ptrCast(&unused),
    };
};

test "OLE medium releases its owned IUnknown exactly once after copying" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var context: TestContext = .{};
    defer if (context.payload) |*payload| payload.deinit();
    var target: Target = .{ .alloc = std.testing.allocator, .hwnd = @ptrFromInt(1), .attachment = testAttachment(), .callbacks = context.callbacks() };
    var source: TestSource = .{};
    var effect: u32 = COPY;
    try std.testing.expectEqual(@as(HRESULT, 0), drop(&target.interface, &source.object, 0, .{ .x = 1, .y = 2 }, &effect));
    try std.testing.expectEqual(COPY, effect);
    try std.testing.expectEqual(@as(usize, 1), source.releases);
    try std.testing.expect(source.handle == null);
    try std.testing.expectEqualStrings("a\r\n", context.payload.?.content.text);
}

test "OLE QueryGetData reentrancy revokes acceptance before GetData" {
    var context: TestContext = .{};
    var target: Target = .{ .alloc = std.testing.allocator, .hwnd = @ptrFromInt(1), .attachment = testAttachment(), .callbacks = context.callbacks() };
    var source: TestSource = .{ .invalidates = &target };
    var effect: u32 = COPY;
    _ = enter(&target.interface, &source.object, 0, .{ .x = 0, .y = 0 }, &effect);
    try std.testing.expectEqual(@as(u32, 0), effect);
    try std.testing.expect(context.payload == null);
    try std.testing.expectEqual(@as(usize, 0), source.releases);
    try std.testing.expectEqual(@as(u32, 1), target.count.load(.monotonic));
}

test "OLE detached target outlives its owner with inert callbacks" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var context: TestContext = .{};
    const target = try std.testing.allocator.create(Target);
    target.* = .{ .alloc = std.testing.allocator, .hwnd = @ptrFromInt(1), .attachment = testAttachment(), .callbacks = context.callbacks() };
    _ = addRef(&target.interface);
    try std.testing.expectEqual(@as(HRESULT, 0), target.destroy());
    try std.testing.expect(!target.live());
    try std.testing.expect(target.callbacks == null);
    try std.testing.expectEqual(@as(u32, 0), release(&target.interface));
}

test "OLE old Drop never upgrades to a renewed attachment during GetData or medium release" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |during_release| {
        var context: TestContext = .{};
        defer if (context.payload) |*payload| payload.deinit();
        var target: Target = .{ .alloc = std.testing.allocator, .hwnd = @ptrFromInt(1), .attachment = testAttachment(), .callbacks = context.callbacks() };
        var source: TestSource = .{
            .renew_at_get = if (during_release) null else &target,
            .renew_at_release = if (during_release) &target else null,
        };
        var effect: u32 = COPY;
        _ = drop(&target.interface, &source.object, 0, .{ .x = 1, .y = 2 }, &effect);
        try std.testing.expectEqual(@as(u64, 2), target.attachment.revision);
        try std.testing.expect(target.live());
        try std.testing.expect(!target.liveAt(testAttachment()));
        try std.testing.expectEqual(@as(u32, 0), effect);
        try std.testing.expect(context.payload == null);
        try std.testing.expectEqual(@as(usize, 1), source.releases);
        try std.testing.expect(source.handle == null);
        try std.testing.expectEqual(@as(u32, 1), target.count.load(.monotonic));
    }
}

test "OLE invalidation is pure and preserves native resources for deferred retirement" {
    var context: TestContext = .{};
    var target: Target = .{
        .alloc = std.testing.allocator,
        .hwnd = @ptrFromInt(1),
        .attachment = testAttachment(),
        .callbacks = context.callbacks(),
        .helper = @ptrFromInt(@alignOf(Helper)),
        .registered = true,
        .supported = true,
    };
    target.invalidate();
    target.invalidate();
    try std.testing.expect(!target.active and !target.supported and target.callbacks == null);
    try std.testing.expect(target.registered and target.helper != null);
    try std.testing.expect(!target.owner_released);
    try std.testing.expectEqual(@as(u32, 1), target.count.load(.monotonic));
}

test "OLE deferred retirement revokes before its registered HWND is destroyed" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var apartment = ComApartment.init();
    defer apartment.deinit() catch {};
    const hwnd = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("GX owned OLE retirement test"), 0, 0, 0, 0, 0, w32.HWND_MESSAGE, null, null, null) orelse return error.TestWindowFailed;
    defer _ = w32.DestroyWindow(hwnd);
    var context: TestContext = .{};
    const target = try Target.create(std.testing.allocator, &apartment, hwnd, testAttachment(), context.callbacks());
    try std.testing.expect(target.registered);
    target.invalidate();
    try std.testing.expectEqual(@as(HRESULT, 0), target.destroy());
    // The test allocator checks both owner and OLE registration refs released.
}
