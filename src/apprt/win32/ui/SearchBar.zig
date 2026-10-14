//! The find bar of a terminal surface: a rounded `Popup` at the top-right
//! of the surface with a search icon, an IME-capable needle input, the
//! "{current}/{total}" match counter and previous/next/close buttons with
//! tooltips (`ui/Tooltip.zig`), drawn in the theme colors. The bar takes
//! the surface width less its margins, between 240 and 380 DIPs
//! (`barWidth`), and the counter the width of its widest value for the
//! match count (`counterSizing`). Typing searches through the core
//! `search` binding action; Enter/Shift+Enter, F3/Shift+F3, the arrow keys
//! and the buttons navigate, and Escape or the close button ends the
//! search. When nothing matches, the field gets the caution border and
//! "No results" shows in the caution color at text contrast. The bar
//! stays open while the terminal has the focus, like the GTK and macOS
//! find bars (without its caret then), F3/Shift+F3 navigate from the
//! terminal too (performable bindings in `src/gx/defaults-windows.ghostty`),
//! and it hides with its surface (a background tab). Closing the bar any
//! way, Alt+F4 included, ends the search. Without Direct2D the bar cannot
//! open, and a message box says so.
//!
//! The owning `Surface` embeds this struct as `search_bar` and forwards the
//! `start_search`/`end_search`/`search_total`/`search_selected` apprt
//! actions (`setActive`, `onSearchEnded`, `setTotal`, `setSelected`),
//! resizes and window moves (`reposition`), its visibility
//! (`setOwnerVisible`), DPI changes, a move to another window
//! (`onReparented`) and `deinit`. The app's message loop gives keys typed
//! into the bar to `handleKey` first (see `App.run`, `ownsEdit`), then lets
//! keybindings with Ctrl reach the terminal, which takes the focus while
//! the bar stays open.
const SearchBar = @This();

const std = @import("std");
const input = @import("../../../input.zig");
const i18n = @import("../../../gx/i18n.zig");
const ui_color = @import("../../../gx/ui_color.zig");
const ui_tokens = @import("../../../gx/ui_tokens.zig");
const Surface = @import("../Surface.zig");
const Pane = @import("../Pane.zig");
const RemotePane = @import("../RemotePane.zig");
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const tooltips = @import("Tooltip.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");
const wstr = @import("wstr.zig");

const log = std.log.scoped(.win32);

/// Height of the bar, its margin from the surface's top-right corner and
/// its width limits, in DIPs.
const bar_height: f32 = 44;
const margin: f32 = 8;
const min_width: f32 = 240;
const max_width: f32 = 380;
/// Square icon buttons.
const button_size: f32 = 28;
const button_gap: f32 = 2;
const pad: f32 = 8;
const icon_width: f32 = 20;
/// The space between the field, the counter and the buttons.
const gap: f32 = 4;
/// The width the field keeps when the counter is wide.
const min_field_width: f32 = 40;

/// Timer on the parent window that shows the "Direct2D is unavailable"
/// message from the message loop (`reportUnavailable`).
pub const UNAVAILABLE_TIMER_ID: usize = 0x4644; // 'FD'

const Button = enum { previous, next, close };

/// What the button tooltip describes.
const Tip = enum { none, previous, next, close };
const ButtonTooltip = tooltips.Tooltip(Tip);

popup: Popup = .{},
remote: ?*RemotePane = null,

/// The tooltips of the buttons (timer `Tooltip.timer_id` on the bar).
tooltip: ButtonTooltip = .{},

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

pub fn bindRemote(self: *SearchBar, remote: *RemotePane) void {
    self.remote = remote;
}
fn paneView(self: *SearchBar) Pane {
    return if (self.remote) |remote| Pane.fromRemote(remote) else Pane.fromLocal(self.surface());
}
fn perform(self: *SearchBar, action: input.Binding.Action) !bool {
    const pane = self.paneView();
    return switch (pane.backend) {
        .local => |local| try local.core_surface.performBindingAction(action),
        .remote => |remote| blk: {
            try remote.ui.sendAction(remote, action, null);
            break :blk false;
        },
    };
}

/// Destroy the popup and its tooltip.
pub fn deinit(self: *SearchBar) void {
    self.tooltip.destroy();
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
    if (self.total == total) return;
    self.total = total;
    self.popup.invalidate();
}

/// Store the selected match index (0-based) from the search_selected
/// action.
pub fn setSelected(self: *SearchBar, selected: ?usize) void {
    if (self.selected == selected) return;
    self.selected = selected;
    self.popup.invalidate();
}

fn tokens(self: *SearchBar) style.Tokens {
    return style.Tokens.fromConfig(&self.paneView().app().config);
}

/// Show (pre-filled with `needle` when it is not empty) or close the find
/// bar. Opening it without a needle keeps the previous text, selected and
/// searched again. Closing it ends the search in the core, which clears
/// the highlighted matches and then hides the bar (`onSearchEnded`).
pub fn setActive(self: *SearchBar, active: bool, needle: [:0]const u8) void {
    const pane = self.paneView();
    if (!active) {
        self.endSearch();
        return;
    }

    // Close the command palette if open (mutual exclusion).
    if (pane.ownerWindow().palette.active) pane.ownerWindow().palette.setActive(false);
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

/// Make the popup ready for the surface's window: create it on first use,
/// or again when it belongs to another window (the tab moved) or went
/// away with its owner, keeping the text; else follow the theme (the dark
/// or light frame, the border). Without Direct2D the user, who asked for
/// the bar, hears why it does not open (`reportUnavailable`).
fn ensure(self: *SearchBar) bool {
    const pane = self.paneView();
    const owner = pane.ownerWindow().hwnd orelse return false;
    const t = self.tokens();
    if (self.popup.hwnd != null and self.popup.owner == owner) {
        const border: ?d2d.Color = t.border;
        if (self.popup.options.dark != t.dark or !std.meta.eql(self.popup.options.border_color, border)) {
            self.popup.applyTheme(t);
        }
        return true;
    }
    const factory = pane.app().uiFactory() orelse {
        self.reportUnavailable();
        return false;
    };

    // The needle outlives the window it was typed in.
    const alloc = factory.alloc;
    const kept: []const u8 = if (self.popup.input.buf.items.len > 0)
        self.popup.input.text(alloc) catch ""
    else
        "";
    defer alloc.free(kept);
    if (self.popup.hwnd != null) {
        self.tooltip.destroy();
        self.popup.destroy();
    }

    self.popup.create(pane.app().hinstance, owner, factory, .{
        .activate = true,
        .dismiss_on_escape = false,
        .dismiss_on_outside_click = false,
        .text_input = true,
        .corners = .round,
        .shadow = true,
        .border_color = t.border,
        .dark = t.dark,
        .keep_owner_active = true,
        .accessible_name = i18n.tr("Find"),
    }, .{
        .ctx = self,
        .paint = paint,
        .key = onKey,
        .mouse = onMouse,
        .text_changed = onTextChanged,
        .dismissed = onDismissed,
        .dpi_changed = onDpiChangedPopup,
        .timer = onTimer,
    }) catch |err| {
        log.warn("failed to create the find bar err={}", .{err});
        return false;
    };
    if (kept.len > 0) self.popup.input.setText(alloc, kept) catch |err| {
        log.warn("failed to keep the search text err={}", .{err});
    };
    return true;
}

/// The find bar needs Direct2D: tell the user, from the message loop, as
/// `setActive` runs inside a core callback, where a message box would run
/// a modal loop.
fn reportUnavailable(self: *SearchBar) void {
    log.warn("the find bar cannot open without Direct2D", .{});
    const owner = self.paneView().ownerWindow().hwnd orelse return;
    _ = w32.SetTimer(owner, UNAVAILABLE_TIMER_ID, 0, @ptrCast(&unavailableTimer));
}

fn unavailableTimer(hwnd: w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w32.KillTimer(hwnd, id);
    var text: [256]u16 = undefined;
    var caption: [64]u16 = undefined;
    _ = w32.MessageBoxW(
        hwnd,
        wstr.bufZ(&text, i18n.tr("Find is not available: Direct2D could not be started.")),
        wstr.bufZ(&caption, i18n.tr("Find")),
        w32.MB_ICONWARNING,
    );
}

/// Show the bar at its place and give it the focus.
fn show(self: *SearchBar) void {
    const rect = self.screenRect() orelse return;
    self.popup.show(rect);
}

/// The bar's width in DIPs on a surface `surface_width` DIPs wide: the
/// surface less the margins, from 240 to 380.
fn barWidth(surface_width: f32) f32 {
    return std.math.clamp(surface_width - 2 * margin, min_width, max_width);
}

/// The bar's screen rectangle: the top-right corner of the surface. The
/// bar takes the content scale of the window first, like the terminal
/// text (`Popup.setOwnerScale`).
fn screenRect(self: *SearchBar) ?w32.RECT {
    const pane = self.paneView();
    const hwnd = pane.nativeHandle() orelse return null;
    self.popup.setOwnerScale(pane.ownerWindow().scale);
    const scale = self.popup.ownerScale();
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return null;
    // Keep clear of an always-visible scrollbar, which sits inside the
    // surface's right edge (`width` leaves it out).
    const right: i32 = switch (pane.backend) {
        .local => |local| @intCast(local.width),
        .remote => |remote| @intCast(remote.width),
    };
    const w = style.px(barWidth(style.dip(right, scale)), scale);
    const h = style.px(bar_height, scale);
    const m = style.px(margin, scale);
    var pt: w32.POINT = .{ .x = @max(client.left + m, right - w - m), .y = client.top + m };
    _ = w32.ClientToScreen(hwnd, &pt);
    return .{ .left = pt.x, .top = pt.y, .right = pt.x + w, .bottom = pt.y + h };
}

/// Move and resize the bar after the surface or its window moved or
/// resized.
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
        self.resetPointer();
        self.popup.hide();
        return;
    }
    self.showInactive();
}

/// The surface moved to another window: an open bar comes back there,
/// with its text and without taking the focus. A closed one is created
/// for the new window when it opens again.
pub fn onReparented(self: *SearchBar) void {
    if (!self.active) return;
    self.resetPointer();
    self.popup.hide();
    if (!self.ensure()) return;
    self.showInactive();
}

/// Show the open bar at its place without taking the focus from the
/// terminal.
fn showInactive(self: *SearchBar) void {
    if (self.popup.visible) return;
    const rect = self.screenRect() orelse return;
    const hwnd = self.popup.hwnd orelse return;
    _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    self.popup.visible = true;
    self.popup.invalidate();
}

/// Forget the hovered and pressed button and close their tooltip (the bar
/// hides, or the pointer left it).
fn resetPointer(self: *SearchBar) void {
    self.hover = null;
    self.pressed = null;
    if (self.popup.hwnd) |hwnd| self.tooltip.setTarget(hwnd, .none);
}

/// Run the search for the current text.
fn search(self: *SearchBar) void {
    const pane = self.paneView();
    if (!pane.ready()) return;
    const alloc = self.popup.alloc;
    const text = self.popup.input.text(alloc) catch return;
    defer alloc.free(text);
    const needle = alloc.dupeZ(u8, text) catch return;
    defer alloc.free(needle);
    _ = self.perform(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}

fn navigate(self: *SearchBar, direction: input.Binding.Action.NavigateSearch) void {
    const pane = self.paneView();
    if (!pane.ready()) return;
    _ = self.perform(.{ .navigate_search = direction }) catch |err| {
        log.err("navigate_search error: {}", .{err});
    };
}

fn endSearch(self: *SearchBar) void {
    const pane = self.paneView();
    if (!pane.ready()) {
        self.onSearchEnded();
        return;
    }
    _ = self.perform(.end_search) catch |err| {
        log.err("end_search error: {}", .{err});
    };
}

/// The search ended (the `end_search` apprt action): hide the bar and
/// give the focus back to the terminal, unless it went elsewhere.
pub fn onSearchEnded(self: *SearchBar) void {
    const pane = self.paneView();
    const had_focus = self.popup.hwnd != null and w32.GetFocus() == self.popup.hwnd;
    self.active = false;
    self.total = null;
    self.selected = null;
    self.resetPointer();
    self.popup.hide();
    if (had_focus or w32.GetFocus() == null) {
        if (pane.nativeHandle()) |hwnd| _ = w32.SetFocus(hwnd);
    }
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
    self.tooltip.hide();
    self.reposition();
}

/// The UI language changed: repaint the placeholder and counter, and a
/// shown tooltip.
pub fn onLanguageChanged(self: *SearchBar) void {
    self.popup.setAccessibleName(i18n.tr("Find"));
    if (self.tooltip.visible()) self.showTooltip();
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

/// The bar closed itself (WM_CLOSE: Alt+F4 in the bar, a close from
/// outside): the search ends with it, or the matches would stay
/// highlighted without a bar, e.g. after canceling the window close that
/// Alt+F4 goes on to ask about.
fn onDismissed(ctx: *anyopaque, popup: *Popup, reason: Popup.DismissReason) void {
    _ = popup;
    _ = reason;
    const self = selfOf(ctx);
    if (self.active) self.endSearch();
}

fn onDpiChangedPopup(ctx: *anyopaque, popup: *Popup) void {
    _ = popup;
    selfOf(ctx).reposition();
}

fn onTimer(ctx: *anyopaque, popup: *Popup, id: usize) void {
    const self = selfOf(ctx);
    const hwnd = popup.hwnd orelse return;
    if (self.tooltip.delayElapsed(hwnd, id)) self.showTooltip();
}

const Layout = struct {
    icon: d2d.Rect,
    field: d2d.Rect,
    counter: d2d.Rect,
    previous: d2d.Rect,
    next: d2d.Rect,
    close: d2d.Rect,

    /// The parts of a bar of `size` whose counter needs `counter_width`
    /// (0 without a counter). The buttons keep their place at the right;
    /// the counter yields to the field's minimum width.
    fn of(size: d2d.Size, counter_width: f32) Layout {
        const y = (size.height - button_size) / 2;
        const close_x = size.width - pad - button_size;
        const next_x = close_x - button_gap - button_size;
        const previous_x = next_x - button_gap - button_size;
        const field_x = pad + icon_width + gap;
        const room = @max(0, previous_x - gap - field_x - min_field_width - gap);
        const counter_w = @min(counter_width, room);
        const counter_x = previous_x - gap - counter_w;
        const field_end = if (counter_w > 0) counter_x - gap else previous_x - gap;
        return .{
            .icon = .{ .x = pad, .y = 0, .w = icon_width, .h = size.height },
            .field = .{ .x = field_x, .y = 6, .w = @max(field_end - field_x, 0), .h = size.height - 12 },
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

fn tipOf(which: ?Button) Tip {
    const b = which orelse return .none;
    return switch (b) {
        .previous => .previous,
        .next => .next,
        .close => .close,
    };
}

fn buttonOf(tip: Tip) ?Button {
    return switch (tip) {
        .none => null,
        .previous => .previous,
        .next => .next,
        .close => .close,
    };
}

/// The tooltip of a button: what it does and its key in the bar.
fn tooltipText(buf: []u8, which: Button) []const u8 {
    const label: []const u8, const key: []const u8 = switch (which) {
        .previous => .{ i18n.tr("Previous Match"), "Shift+Enter" },
        .next => .{ i18n.tr("Next Match"), "Enter" },
        .close => .{ i18n.tr("Close"), "Esc" },
    };
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ label, key }) catch label;
}

/// Show the tooltip of the button the pointer rests on, below the bar
/// under that button.
fn showTooltip(self: *SearchBar) void {
    const hwnd = self.popup.hwnd orelse return;
    if (!self.popup.visible) return;
    const which = buttonOf(self.tooltip.target) orelse return;
    const s = self.popup.scale();
    const size = self.popup.sizeDip();
    const rect = Layout.of(size, 0).button(which);
    var top_left: w32.POINT = .{ .x = style.px(rect.x, s), .y = 0 };
    var bottom_right: w32.POINT = .{ .x = style.px(rect.x + rect.w, s), .y = style.px(size.height, s) };
    _ = w32.ClientToScreen(hwnd, &top_left);
    _ = w32.ClientToScreen(hwnd, &bottom_right);
    var buf: [128]u8 = undefined;
    self.tooltip.show(self.paneView().app(), hwnd, s, tooltipText(&buf, which), .{
        .left = top_left.x,
        .top = top_left.y,
        .right = bottom_right.x,
        .bottom = bottom_right.y,
    });
}

fn onMouse(ctx: *anyopaque, popup: *Popup, event: Popup.MouseEvent) void {
    const self = selfOf(ctx);
    // The buttons do not depend on the counter.
    const layout = Layout.of(popup.sizeDip(), 0);
    switch (event.kind) {
        .move => {
            const hit = layout.hit(event.pos);
            if (hit != self.hover) {
                self.hover = hit;
                popup.invalidate();
            }
            if (popup.hwnd) |hwnd| self.tooltip.setTarget(hwnd, tipOf(hit));
        },
        .leave => {
            self.resetPointer();
            popup.invalidate();
        },
        // The second press of a quick double click arrives as a double
        // click: it presses the button again.
        .down, .double_click => if (event.button == .left) {
            self.tooltip.hide();
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
        .wheel => {},
    }
}

/// The counter: "3/17", "-/17" before a match is selected, "No results"
/// when the needle matches nothing, or nothing without a count.
fn counterText(buf: []u8, total: ?usize, selected: ?usize, has_needle: bool) []const u8 {
    const count = total orelse return "";
    if (count == 0) return if (has_needle) i18n.tr("No results") else "";
    var writer: std.Io.Writer = .fixed(buf);
    if (selected) |sel| {
        i18n.format(&writer, i18n.tr("{current}/{total}"), .{ .current = sel + 1, .total = count }) catch {};
    } else {
        writer.print("-/{d}", .{count}) catch {};
    }
    return writer.buffered();
}

/// What the counter is sized for: its widest value for `total` matches,
/// so the field keeps its width while the selection moves.
fn counterSizing(buf: []u8, total: ?usize, has_needle: bool) []const u8 {
    const count = total orelse return "";
    if (count == 0) return counterText(buf, total, null, has_needle);
    var writer: std.Io.Writer = .fixed(buf);
    i18n.format(&writer, i18n.tr("{current}/{total}"), .{ .current = count, .total = count }) catch {};
    const text = writer.buffered();
    for (text) |*c| {
        if (c.* >= '1' and c.* <= '9') c.* = '0';
    }
    return text;
}

/// The color of "No results": the caution color, at the contrast of text
/// on the bar.
fn noResultsColor(t: style.Tokens) d2d.Color {
    return ui_color.ensureContrast(t.caution, t.surface_raised, ui_tokens.floor.text);
}

fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self = selfOf(ctx);
    const t = self.tokens();
    const size = popup.sizeDip();
    canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, t.surface_raised);

    const has_needle = popup.input.buf.items.len > 0;
    const no_results = has_needle and self.total != null and self.total.? == 0;
    var counter_buf: [64]u8 = undefined;
    var sizing_buf: [64]u8 = undefined;
    const counter = counterText(&counter_buf, self.total, self.selected, has_needle);
    const sizing = counterSizing(&sizing_buf, self.total, has_needle);
    const counter_style: d2d.TextStyle = .{
        .size = style.font_size.caption,
        .color = if (no_results) noResultsColor(t) else t.text_secondary,
        .align_x = .trailing,
        .align_y = .center,
    };
    const counter_w = if (sizing.len == 0) 0 else canvas.measureTextCeil(sizing, counter_style, size.width).width;
    const layout = Layout.of(size, counter_w);

    canvas.drawIcon(d2d.icons.search, layout.icon, style.metrics.icon_size - 2, t.text_secondary);
    var field_tokens = t;
    field_tokens.critical = t.caution;
    popup.drawTextInputEx(canvas, layout.field, field_tokens, .{
        .placeholder = i18n.tr("Find…"),
        .invalid = no_results,
        .focused = popup.hwnd != null and w32.GetFocus() == popup.hwnd,
    });
    if (counter.len > 0) canvas.drawText(counter, layout.counter, counter_style);

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

test "the find bar fits the surface between 240 and 380 DIPs" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 380), barWidth(1200));
    try testing.expectEqual(@as(f32, 300), barWidth(316));
    try testing.expectEqual(@as(f32, 240), barWidth(256));
    // Narrower surfaces still get the smallest usable bar.
    try testing.expectEqual(@as(f32, 240), barWidth(120));
}

test "the counter takes the width it needs and the field the rest" {
    const testing = std.testing;
    const size: d2d.Size = .{ .width = 380, .height = 44 };
    const plain = Layout.of(size, 0);
    const counted = Layout.of(size, 40);
    // The buttons stay at the right edge with or without a counter.
    try testing.expectEqual(plain.close, counted.close);
    try testing.expectEqual(plain.previous, counted.previous);
    try testing.expectApproxEqAbs(@as(f32, 380 - pad - button_size), plain.close.x, 1e-4);
    // Field, counter and buttons in a row, without overlap.
    try testing.expectApproxEqAbs(@as(f32, 40), counted.counter.w, 1e-4);
    try testing.expect(counted.field.x + counted.field.w <= counted.counter.x);
    try testing.expect(counted.counter.x + counted.counter.w <= counted.previous.x);
    // Without a counter the field reaches the buttons.
    try testing.expectApproxEqAbs(counted.field.w + 40 + gap, plain.field.w, 1e-4);
    try testing.expectEqual(@as(f32, 0), plain.counter.w);
    // On the narrowest bar a long counter yields to the field.
    const narrow = Layout.of(.{ .width = min_width, .height = 44 }, 200);
    try testing.expect(narrow.field.w >= min_field_width);
    try testing.expect(narrow.field.x + narrow.field.w <= narrow.counter.x);
    try testing.expect(narrow.counter.x + narrow.counter.w <= narrow.previous.x);
    // The field is a 32 DIP control centered in the bar.
    try testing.expectApproxEqAbs(@as(f32, 32), plain.field.h, 1e-4);
    try testing.expectEqual(Button.next, plain.hit(.{ .x = plain.next.x + 1, .y = 22 }).?);
    try testing.expectEqual(@as(?Button, null), plain.hit(.{ .x = plain.field.x + 1, .y = 22 }));
}

test "the counter shows the position and keeps its width while it moves" {
    const testing = std.testing;
    var text_buf: [64]u8 = undefined;
    var sizing_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("3/17", counterText(&text_buf, 17, 2, true));
    try testing.expectEqualStrings("-/17", counterText(&text_buf, 17, null, true));
    try testing.expectEqualStrings("", counterText(&text_buf, null, null, true));
    try testing.expectEqualStrings("", counterText(&text_buf, 0, null, false));
    try testing.expectEqualStrings(i18n.tr("No results"), counterText(&text_buf, 0, null, true));
    // Sized for the widest position of the count: the field does not move
    // while the selection goes from 1/17 to 17/17.
    try testing.expectEqualStrings("00/00", counterSizing(&sizing_buf, 17, true));
    try testing.expectEqualStrings("000/000", counterSizing(&sizing_buf, 100, true));
    try testing.expectEqualStrings(i18n.tr("No results"), counterSizing(&sizing_buf, 0, true));
    try testing.expectEqualStrings("", counterSizing(&sizing_buf, null, true));
}

test "No results is readable on the bar in every theme" {
    const testing = std.testing;
    for ([_][2]u24{
        .{ 0x1e1e2e, 0xcdd6f4 }, // GX Mocha
        .{ 0x2e3440, 0xd8dee9 }, // Nord
        .{ 0xeff1f5, 0x4c4f69 }, // Catppuccin Latte
        .{ 0xffffff, 0x000000 },
    }) |colors| {
        const t = style.Tokens.fromColors(d2d.Color.hex(colors[0]), d2d.Color.hex(colors[1]), d2d.Color.hex(0x89b4fa));
        try testing.expect(style.contrast(noResultsColor(t), t.surface_raised) >= ui_tokens.floor.text);
    }
}

test "the button tooltips name the key" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const text = tooltipText(&buf, .previous);
    try testing.expect(std.mem.startsWith(u8, text, i18n.tr("Previous Match")));
    try testing.expect(std.mem.endsWith(u8, text, "(Shift+Enter)"));
    try testing.expect(std.mem.endsWith(u8, tooltipText(&buf, .close), "(Esc)"));
    // A buffer too small for the key keeps the label.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings(i18n.tr("Next Match"), tooltipText(&small, .next));
}

test "F3 and Shift+F3 move through the matches from the terminal" {
    const testing = std.testing;
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const config_layers = @import("../../../gx/config_layers.zig");
    var cfg = try config_layers.defaultConfig(testing.allocator);
    defer cfg.deinit();
    for ([_]struct { []const u8, input.Binding.Action.NavigateSearch }{
        .{ "f3", .next },
        .{ "shift+f3", .previous },
    }) |binding| {
        const trigger = try input.Binding.Trigger.parse(binding[0]);
        const entry = cfg.keybind.set.get(trigger) orelse return error.TestUnexpectedResult;
        try testing.expect(entry.value_ptr.* == .leaf);
        try testing.expect(entry.value_ptr.leaf.action.equal(.{ .navigate_search = binding[1] }));
        // Without a search the key goes on to the terminal.
        try testing.expect(entry.value_ptr.leaf.flags.performable);
    }
}

test "dismissal ends the search before the surface is ready" {
    var s: Surface = undefined;
    s.core_surface_ready = false;
    s.hwnd = null;
    s.search_bar = .{ .active = true, .total = 3, .selected = 1 };
    onDismissed(&s.search_bar, &s.search_bar.popup, .owner);
    try std.testing.expect(!s.search_bar.active);
    try std.testing.expectEqual(@as(?usize, null), s.search_bar.total);
    try std.testing.expectEqual(@as(?usize, null), s.search_bar.selected);
}

test {
    std.testing.refAllDecls(@This());
}
