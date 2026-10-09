//! Modal dialogs of the win32 apprt: confirmations (closing a terminal or
//! window with running processes, quitting, clipboard access, unsafe
//! paste), notices (child exited) and the native Save As dialog.
//!
//! Every function blocks in a modal loop and returns the user's choice.
//! The modal loop keeps dispatching messages, so callers must not use
//! pointers that a dispatched message can free (a surface whose child
//! exits, for example) after the call; re-resolve them instead.
//!
//! The implementation is MessageBoxW / GetSaveFileNameW today; a custom
//! dialog can replace it behind the same functions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);

/// The answer to a confirmation.
pub const Choice = enum {
    /// The user approved (OK).
    accept,

    /// The user declined or dismissed the dialog.
    cancel,
};

const confirm_flags = w32.MB_OKCANCEL | w32.MB_ICONWARNING |
    // Default to Cancel so an accidental Enter does not approve.
    w32.MB_DEFBUTTON2;

/// Closing a single terminal whose process is still running.
pub fn confirmCloseSurface(owner: ?w32.HWND) Choice {
    return confirm(
        owner,
        "A process is still running in this terminal.\nClose anyway?",
        "Ghostty",
    );
}

/// Closing a whole window while a process in one of its tabs is running.
pub fn confirmCloseWindow(owner: ?w32.HWND) Choice {
    return confirm(
        owner,
        "Processes are still running in this window.\nClose anyway?",
        "Ghostty",
    );
}

/// Quitting while processes are still running.
pub fn confirmQuit(owner: ?w32.HWND) Choice {
    return confirm(
        owner,
        "Processes are still running.\nQuit anyway?",
        "Ghostty",
    );
}

/// What a program asks to do with the clipboard (OSC 52, Kitty).
pub const ClipboardAccess = enum { read, write };

/// A terminal program asks for clipboard access.
pub fn confirmClipboardAccess(owner: ?w32.HWND, access: ClipboardAccess) Choice {
    return confirm(
        owner,
        switch (access) {
            .read => "An application is requesting access to read the clipboard.\n\nAllow this?",
            .write => "An application is requesting to write to the system clipboard.\n\nAllow this?",
        },
        "Ghostty \u{2014} Authorize Clipboard Access",
    );
}

/// The text being pasted can run commands (paste protection).
pub fn confirmUnsafePaste(owner: ?w32.HWND) Choice {
    return confirm(
        owner,
        "The text being pasted contains characters that could run " ++
            "commands unexpectedly (for example, newlines).\n\nPaste anyway?",
        "Ghostty \u{2014} Potentially Unsafe Paste",
    );
}

/// Tell the user that the shell process exited with a non-zero code.
pub fn showChildExited(owner: ?w32.HWND, exit_code: u32) void {
    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buf,
        "The shell process exited with code {d}.",
        .{exit_code},
    ) catch "The shell process exited unexpectedly.";
    _ = messageBox(owner, message, "Ghostty", w32.MB_ICONWARNING);
}

/// One file type of a Save As dialog.
pub const FileFilter = struct {
    label: []const u8,
    pattern: []const u8,
};

pub const SaveFileOptions = struct {
    title: []const u8,
    default_name: []const u8,
    default_ext: []const u8,
    filters: []const FileFilter,
};

/// Show a native Save As dialog. Returns the chosen path (UTF-8, owned by
/// the caller), or null when the user cancelled.
pub fn saveFilePath(
    alloc: Allocator,
    owner: ?w32.HWND,
    options: SaveFileOptions,
) !?[]u8 {
    var file_buf: [32768]u16 = std.mem.zeroes([32768]u16);
    _ = wstr.bufZ(&file_buf, options.default_name);

    // The common-dialog filter is a sequence of NUL-terminated label/pattern
    // pairs followed by an additional NUL.
    var filter_utf8: std.ArrayList(u8) = .empty;
    defer filter_utf8.deinit(alloc);
    for (options.filters) |filter| {
        try filter_utf8.appendSlice(alloc, filter.label);
        try filter_utf8.append(alloc, 0);
        try filter_utf8.appendSlice(alloc, filter.pattern);
        try filter_utf8.append(alloc, 0);
    }
    const filter = try wstr.allocZ(alloc, filter_utf8.items);
    defer alloc.free(filter);
    const title = try wstr.allocZ(alloc, options.title);
    defer alloc.free(title);
    const default_ext = try wstr.allocZ(alloc, options.default_ext);
    defer alloc.free(default_ext);

    var dialog: w32.OPENFILENAMEW = std.mem.zeroes(w32.OPENFILENAMEW);
    dialog.lStructSize = @sizeOf(w32.OPENFILENAMEW);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = filter.ptr;
    dialog.nFilterIndex = 1;
    dialog.lpstrFile = &file_buf;
    dialog.nMaxFile = file_buf.len;
    dialog.lpstrTitle = title.ptr;
    dialog.lpstrDefExt = default_ext.ptr;
    dialog.Flags = w32.OFN_EXPLORER |
        w32.OFN_NOCHANGEDIR |
        w32.OFN_PATHMUSTEXIST |
        w32.OFN_OVERWRITEPROMPT;

    if (w32.GetSaveFileNameW(&dialog) == 0) return null;

    const path_len = std.mem.indexOfScalar(u16, &file_buf, 0) orelse file_buf.len;
    return std.unicode.utf16LeToUtf8Alloc(alloc, file_buf[0..path_len]) catch |err| {
        log.warn("unable to decode the chosen file path: {}", .{err});
        return error.InvalidPath;
    };
}

/// A modal OK/Cancel warning that defaults to Cancel.
pub fn confirm(owner: ?w32.HWND, message: []const u8, title: []const u8) Choice {
    return switch (messageBox(owner, message, title, confirm_flags)) {
        w32.IDOK => .accept,
        else => .cancel,
    };
}

fn messageBox(owner: ?w32.HWND, message: []const u8, title: []const u8, flags: u32) i32 {
    var message_buf: [1024]u16 = undefined;
    var title_buf: [256]u16 = undefined;
    return w32.MessageBoxW(
        owner,
        wstr.bufZ(&message_buf, message),
        wstr.bufZ(&title_buf, title),
        flags,
    );
}
