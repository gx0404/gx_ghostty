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
};

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
