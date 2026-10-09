//! The command palette of a terminal surface: a popup owned by the
//! surface's window with a filter Edit control and a GDI-painted list of
//! the configured `command-palette-entry` commands (with their keybinding
//! hints). Picking an entry performs its binding action on the surface.
//! Entry titles are English msgids shown in the UI language
//! (`gx.i18n.trRuntime`); the filter matches either form.
//!
//! The owning `Surface` embeds this struct as `palette` and calls
//! `setActive` (from `toggle_command_palette`), `reposition` (on resize),
//! `onDpiChanged`, `onLanguageChanged` and `deinit`. The app's message
//! loop routes keys typed into the filter Edit to `handleKey` (see
//! `App.run`). The popup has its own window class and procedure.
const Palette = @This();

const std = @import("std");
const input = @import("../../../input.zig");
const Surface = @import("../Surface.zig");
const w32 = @import("../win32.zig");
const trigger = @import("trigger.zig");
const i18n = @import("../../../gx/i18n.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);

/// Cap on the command-palette-entry commands shown in the palette
/// (bounds the fixed-size `filtered` index array).
pub const MAX_ENTRIES = 512;

/// Child window ID for the palette edit control.
pub const EDIT_ID: u16 = 200;

/// Layout constants for the palette list (unscaled, multiply by scale).
const LIST_TOP: f32 = 40.0;
const ITEM_HEIGHT: f32 = 28.0;

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyPalette");

/// Command palette popup HWND.
hwnd: ?w32.HWND = null,
/// Edit control inside the command palette popup.
edit: ?w32.HWND = null,
/// Font handle for the palette edit (must be deleted on cleanup).
font: ?*anyopaque = null,
/// Cached paint-time font for the palette list (14pt Segoe UI). The edit
/// control uses `font` (16pt); this is for FillRect/DrawText in `paint`.
/// Cached so we don't allocate a new HFONT on every keystroke-driven
/// repaint.
paint_font: ?*anyopaque = null,
/// Cached brush for palette background (reused in WM_CTLCOLOREDIT).
brush: ?w32.HBRUSH = null,
/// Whether the command palette is currently visible.
active: bool = false,
/// Currently selected item in the filtered palette list.
selected: u16 = 0,
/// Number of items currently in the filtered list.
count: u16 = 0,
/// Indices into the configured command-palette-entry list for the
/// current filter.
filtered: [MAX_ENTRIES]u16 = undefined,

fn surface(self: *Palette) *Surface {
    return @alignCast(@fieldParentPtr("palette", self));
}

/// Destroy the popup and its GDI resources.
pub fn deinit(self: *Palette) void {
    if (self.hwnd) |popup| {
        _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(popup);
        self.hwnd = null;
        self.edit = null;
    }
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }
    if (self.brush) |b| {
        _ = w32.DeleteObject(b);
        self.brush = null;
    }
    if (self.paint_font) |f| {
        _ = w32.DeleteObject(f);
        self.paint_font = null;
    }
}

/// The palette lists the configured command-palette-entry commands,
/// which default to every command Ghostty knows about.
fn entries(self: *Palette) []const input.Command {
    const all = self.surface().app.config.@"command-palette-entry".value.items;
    return all[0..@min(all.len, MAX_ENTRIES)];
}

/// Whether `hwnd` is the palette's filter Edit control.
pub fn ownsEdit(self: *const Palette, hwnd: ?w32.HWND) bool {
    const edit = self.edit orelse return false;
    return hwnd != null and hwnd.? == edit;
}

/// Show or hide the command palette.
pub fn setActive(self: *Palette, active: bool) void {
    const s = self.surface();
    if (active) {
        // Close search bar if open (mutual exclusion)
        if (s.search_bar.active) {
            s.search_bar.setActive(false, &[_:0]u8{});
        }
        self.active = true;
        self.ensure();
        if (self.hwnd) |popup| {
            self.reposition();
            self.filter("");
            _ = w32.ShowWindow(popup, w32.SW_SHOW);
            if (self.edit) |edit| {
                _ = w32.SetWindowTextW(edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.active = false;
        if (self.hwnd) |popup| {
            _ = w32.ShowWindow(popup, w32.SW_HIDE);
        }
        if (s.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}

/// Create the command palette popup if it doesn't exist.
fn ensure(self: *Palette) void {
    if (self.hwnd != null) return;
    const s = self.surface();
    registerClass(s.app.hinstance) catch |err| {
        log.err("failed to register the palette window class err={}", .{err});
        return;
    };

    const scale = s.scale;
    const pal_w: i32 = @intFromFloat(@round(500.0 * scale));
    const pal_h: i32 = @intFromFloat(@round(450.0 * scale));
    const pad: i32 = @intFromFloat(@round(8.0 * scale));
    const edit_h: i32 = @intFromFloat(@round(24.0 * scale));

    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        pal_w,
        pal_h,
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

    // Create the search edit at the top (DPI-scaled)
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        pal_w - pad * 2 - 2,
        edit_h,
        popup,
        @ptrFromInt(@as(usize, EDIT_ID)),
        s.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Set font (DPI-scaled) — stored for cleanup in deinit
    self.font = createFont(16.0 * scale);
    if (self.font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Create cached brush for WM_CTLCOLOREDIT (avoids leak on every repaint)
    self.brush = w32.CreateSolidBrush(w32.RGB(30, 30, 30));

    self.edit = edit;
    self.setPlaceholder();

    // Store the surface pointer for message routing.
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(s)));

    self.hwnd = popup;
}

/// Set the filter's placeholder text via EM_SETCUEBANNER.
fn setPlaceholder(self: *Palette) void {
    const edit = self.edit orelse return;
    var buf: [128]u16 = undefined;
    const placeholder = wstr.bufZ(&buf, i18n.tr("Execute a command…"));
    _ = w32.SendMessageW(edit, 0x1501, 1, @bitCast(@intFromPtr(placeholder.ptr))); // EM_SETCUEBANNER
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

/// Position the command palette centered at the top of the parent window.
pub fn reposition(self: *Palette) void {
    const popup = self.hwnd orelse return;
    const s = self.surface();
    const hwnd = s.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const scale = s.scale;
        const win_width = rect.right - rect.left;
        const pal_width: i32 = @intFromFloat(@round(500.0 * scale));
        const pal_height: i32 = @intFromFloat(@round(450.0 * scale));
        const title_bar: i32 = @intFromFloat(@round(40.0 * scale));
        const x = rect.left + @divTrunc(win_width - pal_width, 2);
        const y = rect.top + title_bar;
        _ = w32.MoveWindow(popup, x, y, pal_width, pal_height, 1);
    }
}

/// Filter palette entries by a case-insensitive substring match.
fn filter(self: *Palette, text: []const u8) void {
    var count: u16 = 0;
    for (self.entries(), 0..) |entry, i| {
        if (text.len == 0 or
            std.ascii.indexOfIgnoreCase(entry.title, text) != null or
            std.ascii.indexOfIgnoreCase(i18n.trRuntime(entry.title), text) != null)
        {
            self.filtered[count] = @intCast(i);
            count += 1;
        }
    }
    self.count = count;
    self.selected = 0;
    // Trigger repaint of the list area
    if (self.hwnd) |popup| {
        _ = w32.InvalidateRect(popup, null, 1);
    }
}

/// Handle text changes in the palette search edit (EN_CHANGE).
fn handleChange(self: *Palette) void {
    const edit = self.edit orelse return;

    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, @intCast(wbuf.len)));

    var utf8_buf: [512]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;

    self.filter(utf8_buf[0..utf8_len]);
}

/// Handle key events in the command palette. Returns true if handled.
pub fn handleKey(self: *Palette, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.setActive(false);
            return true;
        },
        w32.VK_RETURN => {
            self.executeSelection();
            return true;
        },
        w32.VK_UP => {
            if (self.selected > 0) {
                self.selected -= 1;
                if (self.hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        w32.VK_DOWN => {
            if (self.count > 0 and self.selected < self.count - 1) {
                self.selected += 1;
                if (self.hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        else => return false,
    }
}

/// Execute the currently selected palette entry.
fn executeSelection(self: *Palette) void {
    const s = self.surface();
    if (!s.core_surface_ready) return;
    if (self.selected >= self.count) return;

    const all = self.entries();
    const entry_idx = self.filtered[self.selected];
    if (entry_idx >= all.len) return;
    const action = all[entry_idx].action;

    // Close the palette first
    self.setActive(false);

    // Execute the action
    _ = s.core_surface.performBindingAction(action) catch |err| {
        log.err("palette action error: {}", .{err});
    };
}

/// Paint the command palette list area.
fn paint(self: *Palette, hwnd: w32.HWND) void {
    const s = self.surface();
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;

    // Fill background. Reuse the cached brush set up by `ensure` — falling
    // back to a one-shot brush only if it's somehow missing.
    if (self.brush) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
    } else if (w32.CreateSolidBrush(w32.RGB(30, 30, 30))) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
        _ = w32.DeleteObject(b);
    }

    // Reuse a cached 14pt font; create on first paint and keep it for
    // the lifetime of this popup. Rebuilt by onDpiChanged.
    const scale = s.scale;
    if (self.paint_font == null) self.paint_font = createFont(14.0 * scale);
    const old_font = if (self.paint_font) |f| w32.SelectObject(hdc, f) else null;
    defer {
        if (old_font) |of| _ = w32.SelectObject(hdc, of);
    }

    _ = w32.SetBkMode(hdc, 1); // TRANSPARENT

    const item_height: i32 = @intFromFloat(@round(ITEM_HEIGHT * scale));
    const list_top: i32 = @intFromFloat(@round(LIST_TOP * scale));
    const max_visible = @divTrunc(client_rect.bottom - list_top, item_height);
    if (max_visible <= 0) return; // popup too small to render any items

    // Calculate scroll offset to keep selected item visible
    var scroll_offset: i32 = 0;
    if (self.selected >= max_visible) {
        scroll_offset = self.selected - @as(u16, @intCast(max_visible)) + 1;
    }

    const all = self.entries();
    var i: u16 = 0;
    while (i < self.count) : (i += 1) {
        const visual_idx = @as(i32, i) - scroll_offset;
        if (visual_idx < 0) continue;
        if (visual_idx >= max_visible) break;

        const y = list_top + visual_idx * item_height;
        const entry_idx = self.filtered[i];
        if (entry_idx >= all.len) continue;
        const entry_name = i18n.trRuntime(all[entry_idx].title);
        const entry_action = all[entry_idx].action;

        // Draw selection highlight
        if (i == self.selected) {
            if (w32.CreateSolidBrush(w32.RGB(60, 60, 80))) |sel_brush| {
                const sel_rect = w32.RECT{
                    .left = 0,
                    .top = y,
                    .right = client_rect.right,
                    .bottom = y + item_height,
                };
                _ = w32.FillRect(hdc, &sel_rect, sel_brush);
                _ = w32.DeleteObject(sel_brush);
            }
        }

        // Draw action name
        const text_pad: i32 = @intFromFloat(@round(12.0 * scale));
        const text_top_pad: i32 = @intFromFloat(@round(4.0 * scale));
        const kb_area: i32 = @intFromFloat(@round(160.0 * scale));
        _ = w32.SetTextColor(hdc, w32.RGB(220, 220, 220));
        var name_rect = w32.RECT{
            .left = text_pad,
            .top = y + text_top_pad,
            .right = client_rect.right - kb_area,
            .bottom = y + item_height,
        };
        // User-configured palette titles are arbitrary length; bufZ
        // truncates on a codepoint boundary instead of overflowing the
        // stack buffer.
        var wname_buf: [128]u16 = undefined;
        const wname = wstr.bufZ(&wname_buf, entry_name);
        _ = w32.DrawTextW(hdc, wname.ptr, @intCast(wname.len), &name_rect, 0);

        // Draw keybinding hint on the right
        if (trigger.find(&s.app.config.keybind.set, entry_action)) |t| {
            _ = w32.SetTextColor(hdc, w32.RGB(140, 140, 140));
            var kb_buf: [64]u8 = undefined;
            const kb = trigger.format(t, &kb_buf);
            var wkb_buf: [64]u16 = undefined;
            const wkb_len = std.unicode.utf8ToUtf16Le(&wkb_buf, kb) catch 0;
            var kb_rect = w32.RECT{
                .left = client_rect.right - kb_area + text_top_pad,
                .top = y + text_top_pad,
                .right = client_rect.right - text_pad,
                .bottom = y + item_height,
            };
            _ = w32.DrawTextW(hdc, @ptrCast(&wkb_buf), @intCast(wkb_len), &kb_rect, 0x0002); // DT_RIGHT
        }
    }
}

/// Handle a click in the popup: run the clicked entry.
fn onClick(self: *Palette, lparam: isize) void {
    const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
    const scale = self.surface().scale;
    const list_top: i32 = @intFromFloat(@round(LIST_TOP * scale));
    const item_height: i32 = @intFromFloat(@round(ITEM_HEIGHT * scale));
    if (y >= list_top) {
        const clicked = @divTrunc(y - list_top, item_height);
        if (clicked >= 0 and clicked < self.count) {
            self.selected = @intCast(clicked);
            self.executeSelection();
        }
    }
}

/// The DPI of the surface changed: rebuild the fonts at the new scale so
/// the palette text doesn't render tiny/huge after dragging the window
/// between monitors.
pub fn onDpiChanged(self: *Palette) void {
    if (self.font) |old| {
        _ = w32.DeleteObject(old);
        self.font = null;
    }
    if (self.paint_font) |old| {
        _ = w32.DeleteObject(old);
        self.paint_font = null;
    }
    if (self.edit) |edit| {
        self.font = createFont(16.0 * self.surface().scale);
        if (self.font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
}

/// The UI language changed: refresh the placeholder and repaint.
pub fn onLanguageChanged(self: *Palette) void {
    self.setPlaceholder();
    if (self.hwnd) |popup| _ = w32.InvalidateRect(popup, null, 1);
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

/// Window procedure of the palette popup. GWLP_USERDATA stores the
/// owning *Surface.
fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const s: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const self = &s.palette;

    switch (msg) {
        w32.WM_ERASEBKGND => {
            // WM_PAINT fills the whole client area.
            return 1;
        },

        w32.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            self.onClick(lparam);
            return 0;
        },

        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == EDIT_ID and notification == w32.EN_CHANGE) {
                self.handleChange();
                return 0;
            }
            // Auto-dismiss when the Edit loses focus (click outside,
            // Alt+Tab away). Matches standard popup UX (VS Code palette,
            // macOS Spotlight). setActive clears `active` first, so any
            // re-entrant EN_KILLFOCUS during ShowWindow(SW_HIDE) /
            // SetFocus falls through this guard as a no-op.
            if (control_id == EDIT_ID and notification == w32.EN_KILLFOCUS and self.active) {
                self.setActive(false);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for the filter edit control.
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, w32.RGB(30, 30, 30));
            if (self.brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            if (s.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_ACTIVATE => {
            // Dismiss the command palette when it loses activation.
            const activate = @as(u16, @intCast(wparam & 0xFFFF));
            if (activate == w32.WA_INACTIVE and self.active) {
                self.setActive(false);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
