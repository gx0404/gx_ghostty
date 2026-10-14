//! Explicit opt-in native fixture messages. They exercise the same transfer
//! coordinator as dragging; they do not bypass pipe or object authentication.
const std = @import("std");
pub const begin_message: u32 = 0x0400 + 0x4f;
pub const query_message: u32 = 0x0400 + 0x50;
pub const magic: isize = 0x47585231; // GXR1
pub const Flags = struct {
    pub const remote: usize = 1;
    pub const ready: usize = 2;
    pub const frames: usize = 4;
    pub const lease: usize = 8;
    pub const visible: usize = 16;
    pub const unavailable: usize = 32;
};
pub fn enabled() bool {
    var value: [4]u16 = undefined;
    return GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_GX_REMOTE_TEST"), &value, value.len) == 1 and value[0] == '1';
}
extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, [*]u16, u32) callconv(.winapi) u32;
