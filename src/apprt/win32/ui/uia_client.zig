//! Test support only, never used by the application: an in-process UI
//! Automation client (UIAutomationCore's CUIAutomation, as an assistive
//! technology uses it) for tests of this app's providers. The client runs on
//! its own MTA thread while the thread that owns the HWNDs keeps answering
//! the WM_GETOBJECT messages UIA sends them (`pumpUntil`). Vtable slots are
//! those of the SDK's uiautomationclient.h.
const std = @import("std");
const w32 = @import("../win32.zig");
const uia = @import("uia.zig");

/// UIA_E_ELEMENTNOTAVAILABLE: what a revoked or destroyed element answers.
pub const element_not_available: i32 = @bitCast(@as(u32, 0x80040201));

const clsid_automation: w32.GUID = .{ .Data1 = 0xff48dba4, .Data2 = 0x60ef, .Data3 = 0x4201, .Data4 = .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e } };
const iid_automation: w32.GUID = .{ .Data1 = 0x30cbe57d, .Data2 = 0xd9d0, .Data3 = 0x452a, .Data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee } };

fn method(comptime T: type, object: *anyopaque, slot: usize) T {
    const table: *const [*]const ?*const anyopaque = @ptrCast(@alignCast(object));
    return @ptrCast(table.*[slot].?);
}
fn releaseObject(object: *anyopaque) void {
    _ = method(*const fn (*anyopaque) callconv(.winapi) u32, object, 2)(object);
}

pub const Client = struct {
    automation: *anyopaque,

    /// Makes the calling thread an MTA thread until `deinit`.
    pub fn init() !Client {
        if (w32.CoInitializeEx(null, 0) < 0) return error.ComUnavailable;
        errdefer w32.CoUninitialize();
        var out: ?*anyopaque = null;
        if (w32.CoCreateInstance(&clsid_automation, null, w32.CLSCTX_INPROC_SERVER, &iid_automation, &out) < 0) return error.UiaUnavailable;
        return .{ .automation = out orelse return error.UiaUnavailable };
    }
    pub fn deinit(self: Client) void {
        releaseObject(self.automation);
        w32.CoUninitialize();
    }
    /// IUIAutomation::ElementFromHandle (slot 6).
    pub fn fromHandle(self: Client, hwnd: w32.HWND) !Element {
        var out: ?*anyopaque = null;
        const call = method(*const fn (*anyopaque, w32.HWND, *?*anyopaque) callconv(.winapi) w32.HRESULT, self.automation, 6);
        if (call(self.automation, hwnd, &out) < 0) return error.ElementUnavailable;
        return .{ .object = out orelse return error.ElementUnavailable };
    }
    /// IUIAutomation::AddFocusChangedEventHandler (slot 39), no cache
    /// request: from now on UIA calls `watch` for every FocusChanged event.
    pub fn addFocusHandler(self: Client, watch: *FocusWatch) !void {
        const call = method(*const fn (*anyopaque, ?*anyopaque, *FocusWatch) callconv(.winapi) w32.HRESULT, self.automation, 39);
        if (call(self.automation, null, watch) < 0) return error.SubscriptionFailed;
    }
    /// IUIAutomation::RemoveFocusChangedEventHandler (slot 40), from this
    /// MTA thread, never from inside the handler.
    pub fn removeFocusHandler(self: Client, watch: *FocusWatch) void {
        const call = method(*const fn (*anyopaque, *FocusWatch) callconv(.winapi) w32.HRESULT, self.automation, 40);
        _ = call(self.automation, watch);
    }
};

/// An IUIAutomationFocusChangedEventHandler as a screen reader registers
/// one. UIA calls it on its own threads; it counts the events and keeps the
/// AutomationIds of the first `slots` senders in arrival order. The test owns
/// its lifetime (no reference counting): it must outlive
/// `removeFocusHandler` and `deinit`.
pub const FocusWatch = extern struct {
    vtable: *const FocusVtable = &focus_vtable,
    events: u32 = 0,
    /// Slot `i` is readable once `ready[i]` is set.
    ready: [slots]u32 = [_]u32{0} ** slots,
    lengths: [slots]u32 = [_]u32{0} ** slots,
    ids: [slots][96]u8 = undefined,
    /// Each sender's NativeWindowHandle (0 when it has none).
    windows: [slots]i32 = [_]i32{0} ** slots,

    pub const slots = 8;

    pub fn count(self: *const FocusWatch) u32 {
        return @atomicLoad(u32, &self.events, .acquire);
    }
    /// Whether one of the recorded senders has AutomationId `id`.
    pub fn heard(self: *const FocusWatch, id: []const u8) bool {
        for (0..slots) |index| {
            if (@atomicLoad(u32, &self.ready[index], .acquire) == 0) continue;
            if (std.mem.eql(u8, self.ids[index][0..self.lengths[index]], id)) return true;
        }
        return false;
    }
    /// The recorded senders as "|AutomationId@NativeWindowHandle", for a
    /// failure message.
    pub fn senders(self: *const FocusWatch, buffer: []u8) []const u8 {
        var length: usize = 0;
        for (0..slots) |index| {
            if (@atomicLoad(u32, &self.ready[index], .acquire) == 0) continue;
            const id = self.ids[index][0..self.lengths[index]];
            const entry = std.fmt.bufPrint(buffer[length..], "|{s}@0x{x}", .{ id, @as(u32, @bitCast(self.windows[index])) }) catch break;
            length += entry.len;
        }
        return buffer[0..length];
    }
};

const FocusVtable = extern struct {
    query_interface: *const fn (*FocusWatch, *const w32.GUID, *?*anyopaque) callconv(.winapi) w32.HRESULT,
    add_ref: *const fn (*FocusWatch) callconv(.winapi) u32,
    release: *const fn (*FocusWatch) callconv(.winapi) u32,
    handle: *const fn (*FocusWatch, ?*anyopaque) callconv(.winapi) w32.HRESULT,
};
const focus_vtable: FocusVtable = .{ .query_interface = focusQuery, .add_ref = focusReference, .release = focusReference, .handle = focusChanged };
const iid_unknown: w32.GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_focus_handler: w32.GUID = .{ .Data1 = 0xc270f6b5, .Data2 = 0x5c69, .Data3 = 0x4290, .Data4 = .{ 0x97, 0x45, 0x7a, 0x7f, 0x97, 0x16, 0x94, 0x68 } };

fn focusQuery(self: *FocusWatch, iid: *const w32.GUID, out: *?*anyopaque) callconv(.winapi) w32.HRESULT {
    if (std.meta.eql(iid.*, iid_unknown) or std.meta.eql(iid.*, iid_focus_handler)) {
        out.* = self;
        return 0;
    }
    out.* = null;
    return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
}
fn focusReference(_: *FocusWatch) callconv(.winapi) u32 {
    return 1;
}
fn focusChanged(self: *FocusWatch, sender: ?*anyopaque) callconv(.winapi) w32.HRESULT {
    // Each event owns one slot. The sender belongs to UIA: read it, never
    // release it.
    const index = @atomicRmw(u32, &self.events, .Add, 1, .acq_rel);
    if (index >= FocusWatch.slots) return 0;
    if (sender) |object| {
        const element: Element = .{ .object = object };
        const id: []const u8 = element.string(30011, &self.ids[index]) catch "";
        self.lengths[index] = @intCast(id.len);
        self.windows[index] = element.int(30020) catch 0;
    }
    @atomicStore(u32, &self.ready[index], 1, .release);
    return 0;
}

pub const Element = struct {
    object: *anyopaque,

    pub fn release(self: Element) void {
        releaseObject(self.object);
    }
    /// IUIAutomationElement::GetCurrentPropertyValue (slot 10). The caller
    /// clears `value`.
    fn get(self: Element, id: i32, value: *uia.Variant) w32.HRESULT {
        const call = method(*const fn (*anyopaque, i32, *uia.Variant) callconv(.winapi) w32.HRESULT, self.object, 10);
        return call(self.object, id, value);
    }
    /// The HRESULT of reading property `id`, whatever its value.
    pub fn result(self: Element, id: i32) i32 {
        var value: uia.Variant = .{};
        const hr = self.get(id, &value);
        _ = VariantClear(&value);
        return hr;
    }
    /// A VT_I4 property.
    pub fn int(self: Element, id: i32) !i32 {
        var value: uia.Variant = .{};
        defer _ = VariantClear(&value);
        if (self.get(id, &value) < 0) return error.PropertyUnavailable;
        if (value.tag != 3) return error.UnexpectedType;
        return @truncate(value.data.integer);
    }
    /// A VT_BSTR property, as UTF-8 in `buffer`.
    pub fn string(self: Element, id: i32, buffer: []u8) ![]const u8 {
        var value: uia.Variant = .{};
        defer _ = VariantClear(&value);
        if (self.get(id, &value) < 0) return error.PropertyUnavailable;
        if (value.tag != 8) return error.UnexpectedType;
        const text: [*]const u16 = @ptrCast(@alignCast(value.data.pointer orelse return buffer[0..0]));
        const units = text[0..SysStringLen(text)];
        if (units.len * 3 > buffer.len) return error.NoSpaceLeft;
        return buffer[0..try std.unicode.utf16LeToUtf8(buffer, units)];
    }
};

/// The GUI side of a test: dispatch this thread's messages (UIA's
/// WM_GETOBJECT among them) until `stage` reaches `at_least`, or fail after
/// `timeout_ms` instead of hanging the test run.
pub fn pumpUntil(stage: *const std.atomic.Value(u32), at_least: u32, timeout_ms: u64) !void {
    const deadline = GetTickCount64() + timeout_ms;
    while (stage.load(.acquire) < at_least) {
        var message: w32.MSG = undefined;
        while (w32.PeekMessageW(&message, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&message);
            _ = w32.DispatchMessageW(&message);
        }
        if (GetTickCount64() >= deadline) return error.Timeout;
        _ = w32.MsgWaitForMultipleObjectsEx(0, null, 5, w32.QS_ALLINPUT, w32.MWMO_INPUTAVAILABLE);
    }
}

extern "oleaut32" fn SysStringLen(?[*]const u16) callconv(.winapi) u32;
extern "oleaut32" fn VariantClear(*uia.Variant) callconv(.winapi) w32.HRESULT;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
