const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

const log = std.log.scoped(.os);

/// The system-configured double-click interval if its available.
pub fn clickInterval() ?u32 {
    return switch (builtin.os.tag) {
        // On macOS, we can ask the system.
        .macos => macos: {
            const NSEvent = objc.getClass("NSEvent") orelse {
                log.err("NSEvent class not found. Can't get click interval.", .{});
                return null;
            };

            // Get the interval and convert to ms
            const interval = NSEvent.msgSend(f64, objc.sel("doubleClickInterval"), .{});
            const ms = @as(u32, @intFromFloat(@ceil(interval * 1000)));
            break :macos ms;
        },

        // fork(gx): GX-0048 begin: Windows reports the user's double-click time
        .windows => windows: {
            const ms = gxWindowsDoubleClickTime();
            break :windows if (ms == 0) null else ms;
        },
        // fork(gx): GX-0048 end

        else => null,
    };
}

// fork(gx): GX-0048 begin: the Windows mouse setting, and a test that the
// configured default follows it.
fn gxWindowsDoubleClickTime() u32 {
    const user32 = struct {
        extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;
    };
    return user32.GetDoubleClickTime();
}

test "gx clickInterval follows the Windows double-click time" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const system = gxWindowsDoubleClickTime();
    try std.testing.expect(system != 0);
    try std.testing.expectEqual(@as(?u32, system), clickInterval());
}
// fork(gx): GX-0048 end
