// Ported from shiweis/ghostty-windows@119b9270c (MIT). Copyright (c) Shiwei Song and Ghostty contributors.
//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const file_log = @import("win32/file_log.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;
