//! The find bar of a terminal surface: a rounded `Popup` at the top-right
//! of the surface with a search icon, an IME-capable needle input, the
//! "{current}/{total}" match counter, previous/next buttons and a close
//! button, drawn in the theme colors. Typing searches through the core
//! `search` binding action; Enter/Shift+Enter, F3/Shift+F3, the arrow keys
//! and the buttons navigate, and Escape or the close button ends the
//! search. The bar stays open while the terminal has the focus, like the
//! GTK and macOS find bars, and hides with its surface (a background tab).
//!
//! The owning `Surface` embeds this struct as `search_bar` and forwards the
//! `start_search`/`end_search`/`search_total`/`search_selected` apprt
//! actions (`setActive`, `setTotal`, `setSelected`), resizes and window
//! moves (`reposition`), its visibility (`setOwnerVisible`), DPI changes
//! and `deinit`. The app's message loop gives keys typed into the bar to
//! `handleKey` first (see `App.run`, `ownsEdit`), which also lets
//! keybindings with Ctrl reach the terminal.
const SearchBar = @This();

const std = @import("std");
const input = @import("../../../input.zig");
const i18n = @import("../../../gx/i18n.zig");
const Surface = @import("../Surface.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32);

/// Size of the bar and its margin from the surface's top-right corner, in
/// DIPs.
const bar_width: f32 = 380;
const bar_height: f32 = 44;
const margin: f32 = 8;
/// Square icon buttons.
const button_size: f32 = 28;
const button_gap: f32 = 2;
const pad: f32 = 8;

const Button = enum { previous, next, close };

popup: Popup = .{},

/// Whether the search is active (the bar is open, though it is hidden
/// while its surface is).
active: bool = false,

/// Last reported search match count and selected index (0-based), from
/// the search_total / search_selected apprt actions.
total: ?usize = null,
selected: ?usize = null,

hover: ?Button = null,
pressed: ?Button = null,

fn surface(self: *SearchBar) *Surface {
    return @alignCast(@fieldParentPtr("search_bar", self));
}

/// Destroy the popup.
pub fn deinit(self: *SearchBar) void {
    self.popup.destroy();
}

/// Whether `hwnd` is the find bar, whose keys the app's message loop
/// routes to `handleKey`.
pub fn ownsEdit(self: *const SearchBar, hwnd: ?w32.HWND) bool {
    const popup = self.popup.hwnd orelse return false;
    return hwnd != null and hwnd.? == popup;
}

/// Store the total match count from the search_total action.
pub fn setTotal(self: *SearchBar, total: ?usize) void {
    self.total = total;
    self.popup.invalidate();
}

/// Store the selected match index (0-based) from the search_selected
/// action.
pub fn setSelected(self: *SearchBar, selected: ?usize) void {
    self.selected = selected;
    self.popup.invalidate();
}

fn tokens(self: *SearchBar) style.Tokens {
    return style.Tokens.fromConfig(&self.surface().app.config);
}

/// Show (pre-filled with `needle` when it is not empty) or hide the find
/// bar. Opening it without a needle keeps the previous text, selected and
/// searched again.
pub fn setActive(self: *SearchBar, active: bool, needle: [:0]const u8) void {
    const s = self.surface();
    if (!active) {
        const had_focus = self.popup.hwnd != null and w32.GetFocus() == self.popup.hwnd;
        self.active = false;
        self.total = null;
        self.selected = null;
        self.popup.hide();
        // Return the focus to the terminal, unless it went elsewhere.
        if (had_focus or w32.GetFocus() == null) {
            if (s.hwnd) |hwnd| _ = w32.SetFocus(hwnd);
        }
        return;
    }

    // Close the command palette if open (mutual exclusion).
    if (s.palette.active) s.palette.setActive(false);
    if (!self.ensure()) return;
    const was_active = self.active;
    self.active = true;

    // The core leaves searching to the apprt (`search_selection` only
    // passes its needle here).
    const input_field = &self.popup.input;
    if (needle.len > 0) {
        input_field.setText(self.popup.alloc, needle) catch |err| {
            log.warn("failed to set the search text err={}", .{err});
        };
        input_field.anchor = 0;
        self.search();
    } else if (input_field.buf.items.len > 0) {
        // Opened again: select the text so that typing replaces it, and
        // search for it again if the search had ended.
        input_field.anchor = 0;
        input_field.caret = input_field.buf.items.len;
        if (!was_active) self.search();
    }
    self.show();
}

/// Create the popup on first use, or again when its window went away with
/// its owner or belongs to another window than the surface's (the tab
/// moved to a new window).
fn ensure(self: *SearchBar) bool {
    const s = self.surface();
    const owner = s.parent_window.hwnd orelse return false;
    if (self.popup.hwnd) |hwnd| {
        const alive = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA) == @as(isize, @bitCast(@intFromPtr(&self.popup)));
        if (alive and self.popup.owner == owner) return true;
        if (alive) {
            self.popup.destroy();
        } else {
            // Windows destroyed it with its owner; only free the rest.
            if (self.popup.canvas) |*canvas| canvas.deinit();
            self.popup.input.deinit(self.popup.alloc);
            self.popup = .{};
        }
    }
    const factory = s.app.uiFactory() orelse return false;
    const t = self.tokens();
    self.popup.create(s.app.hinstance, owner, factory, .{
        .activate = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .text_input = true,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
    }, .{
        .ctx = self,
        .paint = paint,
        .key = onKey,
        .mouse = onMouse,
        .text_changed = onTextChanged,
        .dpi_changed = onDpiChangedPopup,
    }) catch |err| {
        log.warn("failed to create the find bar err={}", .{err});
        return false;
    };
    return true;
}

/// Show the bar at its place and give it the focus.
fn show(self: *SearchBar) void {
    const rect = self.screenRect() orelse return;
    const t = self.tokens();
    self.popup.setBorderColor(t.border);
    self.popup.show(rect);
}

/// The bar's screen rectangle: the top-right corner of the surface.
fn screenRect(self: *SearchBar) ?w32.RECT {
    const s = self.surface();
    const hwnd = s.hwnd orelse return null;
    const scale = self.popup.ownerScale();
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return null;
    const w = style.px(bar_width, scale);
    const h = style.px(bar_height, scale);
    const m = style.px(margin, scale);
    // Keep clear of an always-visible scrollbar, which sits inside the
    // surface's right edge.
    const right: i32 = @as(i32, @intCast(s.width));
    var pt: w32.POINT = .{ .x = @max(client.left + m, right - w - m), .y = client.top + m };
    _ = w32.ClientToScreen(hwnd, &pt);
    return .{ .left = pt.x, .top = pt.y, .right = pt.x + w, .bottom = pt.y + h };
}

/// Move the bar after the surface or its window moved or resized.
pub fn reposition(self: *SearchBar) void {
    if (!self.active or !self.popup.visible) return;
    const rect = self.screenRect() orelse return;
    self.popup.setBounds(rect);
}

/// Hide the bar with its surface (a background tab, a minimized window)
/// and show it again with it, without ending the search.
pub fn setOwnerVisible(self: *SearchBar, visible: bool) void {
    if (!self.active) return;
    if (!visible) {
        self.popup.hide();
        return;
    }
    if (self.popup.visible) return;
    const rect = self.screenRect() orelse return;
    // Shown again without taking the focus from the terminal.
    const hwnd = self.popup.hwnd orelse return;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    self.popup.visible = true;
    self.popup.invalidate();
}

/// Run the search for the current text.
fn search(self: *SearchBar) void {
    const s = self.surface();
    if (!s.core_surface_ready) return;
    const alloc = self.popup.alloc;
    const text = self.popup.input.text(alloc) catch return;
    defer alloc.free(text);
    const needle = alloc.dupeZ(u8, text) catch return;
    defer alloc.free(needle);
    _ = s.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}

fn navigate(self: *SearchBar, direction: input.Binding.Action.NavigateSearch) void {
    const s = self.surface();
    if (!s.core_surface_ready) return;
    _ = s.core_surface.performBindingAction(.{ .navigate_search = direction }) catch |err| {
        log.err("navigate_search error: {}", .{err});
    };
}

fn endSearch(self: *SearchBar) void {
    const s = self.surface();
    if (!s.core_surface_ready) {
        self.setActive(false, "");
        return;
    }
    _ = s.core_surface.performBindingAction(.end_search) catch |err| {
        log.err("end_search error: {}", .{err});
    };
}

/// Handle a key typed into the bar. Returns true if handled; other keys
/// edit the needle.
pub fn handleKey(self: *SearchBar, vk: u16) bool {
    const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
    switch (vk) {
        // Enter = next match, Shift+Enter = previous match; F3 likewise.
        w32.VK_RETURN, w32.VK_F3 => self.navigate(if (shift) .previous else .next),
        w32.VK_UP => self.navigate(.previous),
        w32.VK_DOWN => self.navigate(.next),
        w32.VK_ESCAPE => self.endSearch(),
        else => return false,
    }
    return true;
}

/// The DPI of the surface changed: move and resize the bar.
pub fn onDpiChanged(self: *SearchBar) void {
    self.reposition();
}

/// The UI language changed: repaint the placeholder and counter.
pub fn onLanguageChanged(self: *SearchBar) void {
    self.popup.invalidate();
}

fn selfOf(ctx: *anyopaque) *SearchBar {
    return @ptrCast(@alignCast(ctx));
}

fn onKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
    _ = popup;
    const self = selfOf(ctx);
    if (key.ctrl or key.alt) return false;
    return self.handleKey(key.vk);
}

fn onTextChanged(ctx: *anyopaque, popup: *Popup) void {
    const self = selfOf(ctx);
    // An empty needle stops the search without a new count.
    if (popup.input.buf.items.len == 0) {
        self.total = null;
        self.selected = null;
    }
    self.search();
}

fn onDpiChangedPopup(ctx: *anyopaque, popup: *Popup) void {
    _ = popup;
    selfOf(ctx).reposition();
}

const Layout = struct {
    icon: d2d.Rect,
    field: d2d.Rect,
    counter: d2d.Rect,
    previous: d2d.Rect,
    next: d2d.Rect,
    close: d2d.Rect,

    fn of(size: d2d.Size) Layout {
        const y = (size.height - button_size) / 2;
        const close_x = size.width - pad - button_size;
        const next_x = close_x - button_gap - button_size;
        const previous_x = next_x - button_gap - button_size;
        const counter_w: f32 = 64;
        const counter_x = previous_x - 4 - counter_w;
        const icon_w: f32 = 20;
        const field_x = pad + icon_w + 4;
        return .{
            .icon = .{ .x = pad, .y = 0, .w = icon_w, .h = size.height },
            .field = .{ .x = field_x, .y = 6, .w = @max(counter_x - 4 - field_x, 40), .h = size.height - 12 },
            .counter = .{ .x = counter_x, .y = 0, .w = counter_w, .h = size.height },
            .previous = .{ .x = previous_x, .y = y, .w = button_size, .h = button_size },
            .next = .{ .x = next_x, .y = y, .w = button_size, .h = button_size },
            .close = .{ .x = close_x, .y = y, .w = button_size, .h = button_size },
        };
    }

    fn button(self: Layout, which: Button) d2d.Rect {
        return switch (which) {
            .previous => self.previous,
            .next => self.next,
            .close => self.close,
        };
    }

    fn hit(self: Layout, pos: d2d.Point) ?Button {
        inline for (.{ Button.previous, Button.next, Button.close }) |which| {
            if (self.button(which).contains(pos)) return which;
        }
        return null;
    }
};

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self = selfOf(ctx);
    const layout = Layout.of(popup.sizeDip());
    switch (event.kind) {
        .move => {
            const hit = layout.hit(event.pos);
            if (hit != self.hover) {
                self.hover = hit;
                popup.invalidate();
            }
        },
        .leave => {
            self.hover = null;
            self.pressed = null;
            popup.invalidate();
        },
        .down => if (event.button == .left) {
            self.pressed = layout.hit(event.pos);
            popup.invalidate();
        },
        .up => if (event.button == .left) {
            const pressed = self.pressed;
            self.pressed = null;
            popup.invalidate();
            const hit = layout.hit(event.pos) orelse return;
            if (pressed != hit) return;
            switch (hit) {
                .previous => self.navigate(.previous),
                .next => self.navigate(.next),
                .close => self.endSearch(),
            }
        },
        .double_click, .wheel => {},
    }
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self = selfOf(ctx);
    const t = self.tokens();
    const size = popup.sizeDip();
    const layout = Layout.of(size);
    canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

    canvas.drawIcon(d2d.icons.search, layout.icon, style.metrics.icon_size - 2, t.text_secondary);
    popup.drawTextInput(canvas, layout.field, t, i18n.tr("Find…"));

    // "3/17", "-/17" before a match is selected, "No results" for none.
    var buf: [64]u8 = undefined;
    const counter: []const u8 = counter: {
        const total = self.total orelse break :counter "";
        if (total == 0) {
            if (popup.input.buf.items.len == 0) break :counter "";
            break :counter i18n.tr("No results");
        }
        var writer: std.Io.Writer = .fixed(&buf);
        if (self.selected) |sel| {
            i18n.format(&writer, i18n.tr("{current}/{total}"), .{ .current = sel + 1, .total = total }) catch {};
        } else {
            writer.print("-/{d}", .{total}) catch {};
        }
        break :counter writer.buffered();
    };
    canvas.drawText(counter, layout.counter, .{
        .size = style.font_size.caption,
        .color = if (self.total != null and self.total.? == 0) t.text_disabled else t.text_secondary,
        .align_x = .trailing,
        .align_y = .center,
    });

    const has_matches = (self.total orelse 0) > 0;
    self.paintButton(canvas, t, layout, .previous, 0xE70E, has_matches);
    self.paintButton(canvas, t, layout, .next, d2d.icons.chevron_down, has_matches);
    self.paintButton(canvas, t, layout, .close, d2d.icons.cancel, true);
}

fn paintButton(
    self: *SearchBar,
    canvas: *d2d.Canvas,
    t: style.Tokens,
    layout: Layout,
    which: Button,
    glyph: u21,
    enabled: bool,
) void {
    const rect = layout.button(which);
    if (enabled and self.hover == which) {
        const fill = if (self.pressed == which) t.pressed else t.hover;
        canvas.fillRoundedRect(rect, 4, fill);
    }
    canvas.drawIcon(glyph, rect, 12, if (enabled) t.text else t.text_disabled);
}
