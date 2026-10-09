//! The find bar of a terminal surface: a popup owned by the surface's
//! window at its top-right with a needle Edit control and a
//! "selected/total" match count label. Typing searches through the core
//! `search` binding action; Enter/Shift+Enter navigate and Escape ends
//! the search.
//!
//! The owning `Surface` embeds this struct as `search_bar` and forwards the
//! `start_search`/`end_search`/`search_total`/`search_selected` apprt
//! actions (`setActive`, `setTotal`, `setSelected`), resizes
//! (`reposition`), DPI changes and `deinit`. The app's message loop routes
//! keys typed into the needle Edit to `handleKey` (see `App.run`). The
//! popup has its own window class and procedure.
const SearchBar = @This();

const std = @import("std");
const input = @import("../../../input.zig");
const i18n = @import("../../../gx/i18n.zig");
const Surface = @import("../Surface.zig");
const w32 = @import("../win32.zig");

const log = std.log.scoped(.win32);

/// Child window ID for the search edit control.
pub const EDIT_ID: u16 = 100;

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchBar");

/// Search popup HWND (a small top-level window containing an Edit
/// control). Uses a popup instead of a child window because the
/// OpenGL viewport covers the entire client area and would paint
/// over a child control.
hwnd: ?w32.HWND = null,

/// The Edit control inside the search popup.
edit: ?w32.HWND = null,

/// Whether the search bar is currently visible.
active: bool = false,

/// Font handle for the search edit (must be deleted on cleanup).
font: ?*anyopaque = null,

/// Right-aligned STATIC control in the search popup showing the
/// "selected/total" match count (search_total / search_selected actions).
count_label: ?w32.HWND = null,

/// Last reported search match count and selected index (0-based), from
/// the search_total / search_selected apprt actions.
total: ?usize = null,
selected: ?usize = null,

fn surface(self: *SearchBar) *Surface {
    return @alignCast(@fieldParentPtr("search_bar", self));
}

/// Destroy the popup and its GDI resources.
pub fn deinit(self: *SearchBar) void {
    if (self.hwnd) |popup| {
        _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(popup);
        self.hwnd = null;
        self.edit = null;
        self.count_label = null;
    }
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }
}

/// Whether `hwnd` is the search bar's needle Edit control.
pub fn ownsEdit(self: *const SearchBar, hwnd: ?w32.HWND) bool {
    const edit = self.edit orelse return false;
    return hwnd != null and hwnd.? == edit;
}

/// Store the total match count from the search_total action and refresh
/// the "selected/total" label.
pub fn setTotal(self: *SearchBar, total: ?usize) void {
    self.total = total;
    self.updateCountLabel();
}

/// Store the selected match index (0-based) from the search_selected
/// action and refresh the "selected/total" label.
pub fn setSelected(self: *SearchBar, selected: ?usize) void {
    self.selected = selected;
    self.updateCountLabel();
}

fn updateCountLabel(self: *SearchBar) void {
    const label = self.count_label orelse return;
    var buf8: [32]u8 = undefined;
    const text8: []const u8 = blk: {
        const total = self.total orelse break :blk "";
        if (total == 0) break :blk "0/0";
        if (self.selected) |sel| {
            var writer: std.Io.Writer = .fixed(&buf8);
            i18n.format(&writer, i18n.tr("{current}/{total}"), .{
                .current = sel + 1,
                .total = total,
            }) catch {};
            break :blk writer.buffered();
        }
        break :blk std.fmt.bufPrint(&buf8, "-/{d}", .{total}) catch "";
    };
    var buf16: [64]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch 0;
    buf16[len16] = 0;
    _ = w32.SetWindowTextW(label, @ptrCast(&buf16));
}

/// Show (optionally pre-filled with `needle`) or hide the search bar.
pub fn setActive(self: *SearchBar, active: bool, needle: [:0]const u8) void {
    const s = self.surface();
    if (active) {
        // Close command palette if open (mutual exclusion)
        if (s.palette.active) {
            s.palette.setActive(false);
        }
        self.active = true;
        self.ensure();
        if (self.hwnd) |popup| {
            self.reposition();
            _ = w32.ShowWindow(popup, w32.SW_SHOW);

            // Set the search text if provided
            if (needle.len > 0) {
                if (self.edit) |edit| {
                    var wbuf: [512]u16 = undefined;
                    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, needle) catch 0;
                    if (wlen < wbuf.len) {
                        wbuf[wlen] = 0;
                        _ = w32.SetWindowTextW(edit, @ptrCast(&wbuf));
                    }
                }
            }

            // Focus the edit control
            if (self.edit) |edit| {
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.active = false;
        self.total = null;
        self.selected = null;
        self.updateCountLabel();
        if (self.hwnd) |popup| {
            _ = w32.ShowWindow(popup, w32.SW_HIDE);
        }
        // Return focus to the terminal
        if (s.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}

/// Create the search popup window if it doesn't exist. The popup is a
/// small top-level window (WS_POPUP) that floats over the main window.
/// A child Edit control inside it handles the actual text input.
/// We can't use a child window of the main HWND because OpenGL covers
/// the entire client area and paints over child controls.
fn ensure(self: *SearchBar) void {
    if (self.hwnd != null) return;
    const s = self.surface();
    registerClass(s.app.hinstance) catch |err| {
        log.err("failed to register the search bar window class err={}", .{err});
        return;
    };

    const scale = s.scale;
    const bar_w: i32 = @intFromFloat(@round(310.0 * scale));
    const bar_h: i32 = @intFromFloat(@round(32.0 * scale));
    const pad: i32 = @intFromFloat(@round(4.0 * scale));

    // Create the popup container (no title bar, tool window so it
    // doesn't appear in the taskbar). Owner is the top-level Window
    // HWND so it floats above the terminal surface.
    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        bar_w,
        bar_h,
        s.parent_window.hwnd.?,
        null,
        s.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        popup,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Create the Edit control inside the popup, leaving room on the right
    // for the match-count label ("3/17").
    const count_w: i32 = @intFromFloat(@round(64.0 * scale));
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        bar_w - pad * 2 - 2 - count_w,
        bar_h - pad * 2 - 2,
        popup,
        @ptrFromInt(@as(usize, EDIT_ID)),
        s.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Right-aligned match-count label, filled by search_total /
    // search_selected actions (see setTotal/setSelected).
    self.count_label = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_RIGHT | w32.SS_CENTERIMAGE,
        bar_w - pad - count_w,
        pad,
        count_w - pad,
        bar_h - pad * 2 - 2,
        popup,
        null,
        s.app.hinstance,
        null,
    );

    // Set a readable font (DPI-scaled)
    self.font = createFont(16.0 * scale);
    if (self.font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.count_label) |label| {
            _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    // Set GWLP_USERDATA on the popup so the window procedure can route
    // WM_COMMAND (EN_CHANGE) and WM_CTLCOLOREDIT to this surface.
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(s)));

    self.hwnd = popup;
    self.edit = edit;
}

fn createFont(px: f32) ?*anyopaque {
    return w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(px))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
}

/// Position the search popup at the top-right corner of the parent window.
pub fn reposition(self: *SearchBar) void {
    const popup = self.hwnd orelse return;
    const s = self.surface();
    const hwnd = s.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const scale = s.scale;
        const bar_width: i32 = @intFromFloat(@round(310.0 * scale));
        const bar_height: i32 = @intFromFloat(@round(32.0 * scale));
        const padding: i32 = @intFromFloat(@round(8.0 * scale));
        const title_bar: i32 = @intFromFloat(@round(32.0 * scale));
        // Position at top-right of the window, below the title bar
        _ = w32.MoveWindow(
            popup,
            rect.right - bar_width - padding,
            rect.top + title_bar + padding,
            bar_width,
            bar_height,
            1,
        );
    }
}

/// Handle text changes in the search edit control (EN_CHANGE).
fn handleChange(self: *SearchBar) void {
    const s = self.surface();
    if (!s.core_surface_ready) return;
    const search = self.edit orelse return;

    // Get the current search text
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(search, &wbuf, @intCast(wbuf.len)));

    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;

    // Need a null-terminated slice for performBindingAction
    var needle_buf: [1025]u8 = undefined;
    @memcpy(needle_buf[0..utf8_len], utf8_buf[0..utf8_len]);
    needle_buf[utf8_len] = 0;
    const needle: [:0]const u8 = needle_buf[0..utf8_len :0];

    _ = s.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}

/// Handle key events in the search bar. Returns true if handled.
pub fn handleKey(self: *SearchBar, vk: u16) bool {
    const s = self.surface();
    if (!s.core_surface_ready) return false;

    switch (vk) {
        w32.VK_RETURN => {
            // Enter = next match, Shift+Enter = previous match
            const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const nav: input.Binding.Action = if (shift)
                .{ .navigate_search = .previous }
            else
                .{ .navigate_search = .next };
            _ = s.core_surface.performBindingAction(nav) catch |err| {
                log.err("navigate_search error: {}", .{err});
            };
            return true;
        },
        w32.VK_ESCAPE => {
            _ = s.core_surface.performBindingAction(.end_search) catch |err| {
                log.err("end_search error: {}", .{err});
            };
            return true;
        },
        else => return false,
    }
}

/// The DPI of the surface changed: rebuild the font at the new scale.
pub fn onDpiChanged(self: *SearchBar) void {
    if (self.font) |old| {
        _ = w32.DeleteObject(old);
        self.font = null;
    }
    if (self.edit) |edit| {
        self.font = createFont(16.0 * self.surface().scale);
        if (self.font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
            // The count label shares the search font; re-send it too or the
            // label keeps a handle to the just-deleted HFONT.
            if (self.count_label) |label| {
                _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
}

/// The UI language changed: refresh the count label.
pub fn onLanguageChanged(self: *SearchBar) void {
    self.updateCountLabel();
}

var class_registered = false;

fn registerClass(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

/// Window procedure of the search popup. GWLP_USERDATA stores the owning
/// *Surface.
fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const s: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const self = &s.search_bar;

    switch (msg) {
        w32.WM_ERASEBKGND => {
            // Fill with the terminal background color.
            if (s.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == EDIT_ID and notification == w32.EN_CHANGE) {
                self.handleChange();
                return 0;
            }
            // Auto-dismiss when the Edit loses focus (click outside,
            // Alt+Tab away). setActive clears `active` first, so any
            // re-entrant EN_KILLFOCUS falls through this guard.
            if (control_id == EDIT_ID and notification == w32.EN_KILLFOCUS and self.active) {
                self.setActive(false, &[_:0]u8{});
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for the needle edit control.
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, w32.RGB(45, 45, 45));
            if (s.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLORSTATIC => {
            // Dark mode colors for the match-count label.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(160, 160, 160));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (s.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
