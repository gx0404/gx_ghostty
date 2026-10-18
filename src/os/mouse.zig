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

        // fork(gx): GX-0048 begin: Windows reads the double-click time of the mouse settings
        .windows => @import("../gx/os_mouse.zig").doubleClickTime(),
        // fork(gx): GX-0048 end
        else => null,
    };
}
