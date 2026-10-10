//! Geometry of the integrated title bar that needs no window, as pure
//! functions of the content scale (`Window.scale`): the smallest window the
//! chrome row fits in (`minTrackSize`), which `Window` reports in
//! `WM_GETMINMAXINFO`.
const std = @import("std");

/// A size in pixels.
pub const Size = struct {
    width: i32,
    height: i32,
};

/// The smallest window rectangle (pixels, frame included) the chrome of a
/// window at content scale `scale` needs: the least `ptMinTrackSize` of
/// `WM_GETMINMAXINFO`. A zero dimension asks for nothing beyond the system
/// minimum (`SM_CXMINTRACK`, `SM_CYMINTRACK`), which is all the chrome asks
/// for so far; a terminal's `size_limit` raises it further.
pub fn minTrackSize(scale: f32) Size {
    _ = scale;
    return .{ .width = 0, .height = 0 };
}

test "minTrackSize leaves the system minimum" {
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        try std.testing.expectEqual(Size{ .width = 0, .height = 0 }, minTrackSize(scale));
    }
}
