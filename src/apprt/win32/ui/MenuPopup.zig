//! A custom-drawn popup menu in the Windows 11 style, themed from the
//! terminal colors (`style.Tokens`): the widget behind `ui/Menu.zig`. Each
//! menu level is a `Popup` window painted with a `d2d.Canvas`: a rounded
//! container with a 1 px border and the system shadow, rows with an
//! optional icon glyph or check/radio mark, a label, right-aligned
//! shortcut text and a submenu chevron, separators, section headers and
//! disabled items. The highlighted row gets a hover fill and an accent bar.
//!
//! Build the items with a `Builder` and `run` them. `run` opens the menu
//! at an anchor point, flipped and clamped to stay within the work area of
//! the anchor's monitor and sized for the owner's DPI (or the content
//! scale in `Options.owner_scale`), and blocks in a modal message loop
//! until an action is picked (its `Item.id` is returned) or the menu is
//! dismissed (null). A new popup stays cloaked
//! until it has been painted twice: DWM may drop the first frame of a
//! window presented right after it is shown.
//!
//! Like a native menu, the menu takes neither activation nor keyboard
//! focus. The loop handles the keyboard itself (Up/Down, Home/End,
//! Enter/Space, Right to open and Left to close a submenu, Escape,
//! Alt/F10; no mnemonics) on the deepest open menu, and routes the mouse
//! by screen position while the root popup holds the mouse capture:
//! hovering a submenu item opens it after the system menu show delay, a
//! press outside the menus, losing the capture or a change of the
//! foreground window dismisses the menu. Releasing a button over an item
//! picks it when a button went down inside the menu or the pointer moved
//! since it opened (press, drag, release).
//!
//! Re-entrancy: one menu runs at a time; `run` returns null while another
//! menu is open, and `cancel` closes the open one (for example when the UI
//! language changes). The loop dispatches every other message, so timers,
//! painting and terminal output go on, and a dispatched message can free
//! anything, even the owner: `run` returns null when its owner was
//! destroyed or detached its object meanwhile (windows and terminals clear
//! their GWLP_USERDATA when they go away), and callers re-resolve other
//! pointers after it returns.
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const Popup = @import("Popup.zig");
const d2d = @import("d2d.zig");
const style = @import("style.zig");

const log = std.log.scoped(.win32_menu);

/// What the leading column of an item shows instead of its icon.
pub const Mark = enum {
    none,
    /// A check mark: a setting that is on.
    check,
    /// A bullet: the chosen one of a group of options.
    radio,
};

pub const Item = struct {
    kind: Kind = .action,
    /// What `run` returns when the item is picked.
    id: usize = 0,
    label: []const u8 = "",
    /// A glyph of the icon font (`d2d.icons`).
    icon: ?u21 = null,
    mark: Mark = .none,
    /// Right-aligned secondary text, usually a keyboard shortcut.
    shortcut: ?[]const u8 = null,
    enabled: bool = true,
    /// The items of a submenu (set by `Builder.submenu`).
    submenu: ?*const List = null,

    pub const Kind = enum { action, submenu, separator, header };

    /// Whether the item can be highlighted and activated.
    fn selectable(self: Item) bool {
        if (!self.enabled) return false;
        return switch (self.kind) {
            .action => true,
            .submenu => if (self.submenu) |list| list.items.items.len > 0 else false,
            .separator, .header => false,
        };
    }
};

/// The items of a menu or submenu.
pub const List = struct {
    items: std.ArrayList(Item) = .empty,
};

/// Builds the items of a menu. All text is copied, so labels and
/// shortcuts can come from temporary buffers.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    root: List = .{},

    pub fn init(alloc: Allocator) Builder {
        return .{ .arena = .init(alloc) };
    }

    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
    }

    /// Append `item` to `list`.
    pub fn add(self: *Builder, list: *List, item: Item) Allocator.Error!void {
        const alloc = self.arena.allocator();
        var copy = item;
        copy.label = try alloc.dupe(u8, item.label);
        if (item.shortcut) |text| copy.shortcut = try alloc.dupe(u8, text);
        try list.items.append(alloc, copy);
    }

    pub fn separator(self: *Builder, list: *List) Allocator.Error!void {
        try self.add(list, .{ .kind = .separator });
    }

    /// A section header: a caption above the items that follow.
    pub fn header(self: *Builder, list: *List, label: []const u8) Allocator.Error!void {
        try self.add(list, .{ .kind = .header, .label = label, .enabled = false });
    }

    /// Append a submenu item and return its (empty) item list. A submenu
    /// without items is shown disabled.
    pub fn submenu(self: *Builder, list: *List, item: Item) Allocator.Error!*List {
        const child = try self.arena.allocator().create(List);
        child.* = .{};
        var entry = item;
        entry.kind = .submenu;
        entry.submenu = child;
        try self.add(list, entry);
        return child;
    }
};

/// What a menu is drawn with.
pub const Host = struct {
    hinstance: w32.HINSTANCE,
    factory: *d2d.Factory,
    tokens: style.Tokens,
};

pub const Options = struct {
    /// The top-left corner of the menu in screen pixels. The menu opens
    /// to the left of and above it instead when it does not fit.
    anchor: w32.POINT,
    /// Highlight the first item, for menus opened from the keyboard.
    select_first: bool = false,
    /// The owner's content scale (`Window.scale` for the menus of a
    /// window's chrome), when the menu follows it (`Popup.setOwnerScale`).
    owner_scale: ?f32 = null,
};

/// Dismiss the open menu, if any; its `run` returns null.
pub fn cancel() void {
    if (current) |state| state.dismiss();
}

/// Show the menu `root` for `owner` and run it until it is closed.
/// Returns the id of the picked item, or null when the menu was dismissed,
/// another menu is open or the owner went away.
pub fn run(host: Host, owner: w32.HWND, root: *const List, options: Options) ?usize {
    if (current != null) {
        log.debug("a menu is already open", .{});
        return null;
    }
    if (root.items.items.len == 0) return null;

    var arena: std.heap.ArenaAllocator = .init(host.factory.alloc);
    defer arena.deinit();

    var cursor = options.anchor;
    _ = w32.GetCursorPos_(&cursor);

    var state: State = .{
        .host = host,
        .owner = owner,
        .alloc = arena.allocator(),
        .anchor = options.anchor,
        .owner_scale = options.owner_scale,
        .foreground = w32.GetForegroundWindow(),
        .start_pt = cursor,
        .last_pt = cursor,
        .drag_x = @intCast(@max(w32.GetSystemMetrics(SM_CXDRAG), 1)),
        .drag_y = @intCast(@max(w32.GetSystemMetrics(SM_CYDRAG), 1)),
        .show_delay = menuShowDelay(),
        .held_keys = heldKeys(),
    };
    defer state.closeFrom(0);

    if (!state.open(root, null, options.select_first)) return null;
    current = &state;
    defer current = null;

    // The capture keeps WM_SETCURSOR away, so set the menu cursor once.
    if (w32.LoadCursorW(null, w32.IDC_ARROW)) |arrow| _ = w32.SetCursor(arrow);

    state.loop();

    if (!ownerAlive(owner)) return null;
    return switch (state.result) {
        .picked => |id| id,
        .open, .cancelled => null,
    };
}

/// The menu that is running.
var current: ?*State = null;

/// Nested submenus beyond this depth do not open.
const max_depth = 4;

/// How often the loop checks the owner, the foreground window, the
/// submenu show delay and popups to reveal while no other message arrives.
const tick_ms = 20;

/// How long a new popup stays cloaked after its first paint. DWM can drop
/// a frame presented right after a window is shown, which leaves the
/// popup empty; the popup is painted again before it is uncloaked.
const reveal_ms = 40;

const DWMWA_CLOAK: u32 = 13;

const SM_CXDRAG: i32 = 68;
const SM_CYDRAG: i32 = 69;
const SPI_GETMENUSHOWDELAY: u32 = 0x006A;

const WM_NCMOUSEMOVE: u32 = 0x00A0;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_NCLBUTTONUP: u32 = 0x00A2;
const WM_NCLBUTTONDBLCLK: u32 = 0x00A3;
const WM_NCRBUTTONDOWN: u32 = 0x00A4;
const WM_NCRBUTTONUP: u32 = 0x00A5;
const WM_NCRBUTTONDBLCLK: u32 = 0x00A6;
const WM_NCMBUTTONDOWN: u32 = 0x00A7;
const WM_NCMBUTTONUP: u32 = 0x00A8;
const WM_NCMBUTTONDBLCLK: u32 = 0x00A9;
const WM_NCXBUTTONDOWN: u32 = 0x00AB;
const WM_NCXBUTTONUP: u32 = 0x00AC;
const WM_NCXBUTTONDBLCLK: u32 = 0x00AD;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_MBUTTONDBLCLK: u32 = 0x0209;
const WM_XBUTTONDBLCLK: u32 = 0x020D;
const WM_UNICHAR: u32 = 0x0109;

extern "user32" fn SystemParametersInfoW(
    uiAction: u32,
    uiParam: u32,
    pvParam: ?*anyopaque,
    fWinIni: u32,
) callconv(.winapi) i32;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// The system delay before a hovered submenu opens (`MenuShowDelay`).
fn menuShowDelay() u64 {
    var delay: u32 = 400;
    if (SystemParametersInfoW(SPI_GETMENUSHOWDELAY, 0, &delay, 0) == 0) return 400;
    return @min(delay, 2000);
}

/// The keys that are down now, from the thread's keyboard state.
fn heldKeys() std.StaticBitSet(256) {
    var keys: std.StaticBitSet(256) = .initEmpty();
    var state: [256]u8 = undefined;
    if (w32.GetKeyboardState(&state) == 0) return keys;
    for (state, 0..) |value, vk| {
        if (value & 0x80 != 0) keys.set(vk);
    }
    return keys;
}

/// Hide (`cloaked`) or show a window in DWM composition only; it keeps
/// painting while cloaked.
fn setCloaked(hwnd: w32.HWND, cloaked: bool) void {
    const value: u32 = @intFromBool(cloaked);
    _ = w32.DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, @ptrCast(&value), @sizeOf(u32));
}

/// Whether `owner` still exists with its object attached.
fn ownerAlive(owner: w32.HWND) bool {
    return w32.GetWindowLongPtrW(owner, w32.GWLP_USERDATA) != 0;
}

/// The work area of the monitor nearest to `pt`.
fn workArea(pt: w32.POINT) w32.RECT {
    const screen: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = w32.GetSystemMetrics(0),
        .bottom = w32.GetSystemMetrics(1),
    };
    const monitor = w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST) orelse return screen;
    var info: w32.MONITORINFO = .{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(monitor, &info) == 0) return screen;
    return info.rcWork;
}

/// Layout metrics in DIPs.
const metrics = struct {
    /// Space above the first and below the last row.
    const pad_y: f32 = 4;
    /// Inset of the row highlight from the menu edges.
    const inset: f32 = 4;
    /// Space between the menu edges and the row content.
    const pad_x: f32 = 12;
    const item_height: f32 = style.metrics.item_height;
    const header_height: f32 = 28;
    const separator_height: f32 = 9;
    const icon_size: f32 = style.metrics.icon_size;
    const icon_gap: f32 = 12;
    /// Label indent when no row has an icon or mark.
    const plain_indent: f32 = 4;
    /// The least space between a label and its shortcut.
    const shortcut_gap: f32 = 32;
    const chevron_size: f32 = 12;
    const chevron_gap: f32 = 8;
    const min_width: f32 = 200;
    const max_width: f32 = 480;
    /// How far a submenu overlaps its parent menu.
    const submenu_overlap: f32 = 4;
    const highlight_radius: f32 = 4;
    const accent_width: f32 = 3;
    const accent_height: f32 = 16;
    const radio_size: f32 = 6;
};

/// The check mark glyph of the icon font.
const check_glyph: u21 = 0xE73E;

fn labelStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.body, .color = color };
}

fn shortcutStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.body, .color = color, .align_x = .trailing, .ellipsis = false };
}

fn headerStyle(color: d2d.Color) d2d.TextStyle {
    return .{ .size = style.font_size.caption, .weight = .semibold, .color = color };
}

/// A DIP coordinate snapped to the pixel grid at `scale`.
fn snap(value: f32, scale: f32) f32 {
    return @round(value * scale) / scale;
}

const Result = union(enum) {
    open,
    cancelled,
    picked: usize,
};

const ItemRef = struct {
    level: usize,
    item: usize,
};

/// A submenu change that waits for the show delay.
const Pending = struct {
    /// The level whose submenu changes.
    level: usize,
    /// The submenu item to open, or null to only close the open submenu.
    item: ?usize,
    due: u64,
};

const Direction = enum { next, previous };

const Row = struct {
    y: f32,
    height: f32,
    shortcut_width: f32 = 0,
};

/// One open menu: the root or a submenu.
const Level = struct {
    state: *State,
    index: usize,
    list: *const List,
    /// The item of the parent menu that opened this submenu.
    parent_item: ?usize,
    popup: Popup = .{},
    rows: []Row = &.{},
    /// Size in DIPs.
    width: f32 = 0,
    height: f32 = 0,
    label_x: f32 = 0,
    /// Whether a row is a submenu (reserves the chevron column).
    chevron: bool = false,
    /// The highlighted item.
    hot: ?usize = null,
    /// The popup in screen pixels, and the scale of its layout.
    bounds: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    scale: f32 = 1,
    /// When the cloaked popup is painted again and uncloaked.
    reveal_at: ?u64 = null,

    fn items(self: *const Level) []const Item {
        return self.list.items.items;
    }

    /// Measure the rows and the menu size in DIPs.
    fn layout(self: *Level) void {
        const factory = self.state.host.factory;
        const tokens = self.state.host.tokens;
        var lead = false;
        self.chevron = false;
        for (self.items()) |item| {
            if (item.icon != null or item.mark != .none) lead = true;
            if (item.kind == .submenu) self.chevron = true;
        }
        self.label_x = metrics.pad_x + if (lead)
            metrics.icon_size + metrics.icon_gap
        else
            metrics.plain_indent;

        var content: f32 = 0;
        var y: f32 = metrics.pad_y;
        for (self.items(), self.rows) |item, *row| {
            row.* = .{ .y = y, .height = switch (item.kind) {
                .separator => metrics.separator_height,
                .header => metrics.header_height,
                .action, .submenu => metrics.item_height,
            } };
            switch (item.kind) {
                .separator => {},
                .header => content = @max(content, factory.measureText(item.label, headerStyle(tokens.text), 100_000).width),
                .action, .submenu => {
                    var width = factory.measureText(item.label, labelStyle(tokens.text), 100_000).width;
                    if (item.shortcut) |text| {
                        row.shortcut_width = factory.measureText(text, shortcutStyle(tokens.text), 100_000).width;
                        width += metrics.shortcut_gap + row.shortcut_width;
                    }
                    content = @max(content, width);
                },
            }
            y += row.height;
        }
        self.height = y + metrics.pad_y;
        const trailing = metrics.pad_x + if (self.chevron) metrics.chevron_size + metrics.chevron_gap else 0;
        self.width = std.math.clamp(@ceil(self.label_x + content + trailing), metrics.min_width, metrics.max_width);
    }

    /// Compute `bounds`: at the anchor for the root, beside the parent
    /// item for a submenu, kept within the monitor's work area.
    fn place(self: *Level) void {
        const state = self.state;
        const w = style.px(self.width, self.scale);
        const h = style.px(self.height, self.scale);
        var x: i32 = undefined;
        var y: i32 = undefined;
        var work: w32.RECT = undefined;
        if (self.index == 0) {
            const anchor = state.anchor;
            work = workArea(anchor);
            x = if (anchor.x + w <= work.right) anchor.x else anchor.x - w;
            y = if (anchor.y + h <= work.bottom) anchor.y else anchor.y - h;
        } else {
            const parent = &state.levels[self.index - 1];
            const row = parent.rows[self.parent_item.?];
            const overlap = style.px(metrics.submenu_overlap, self.scale);
            const item_top = parent.bounds.top + style.px(row.y, parent.scale);
            work = workArea(.{ .x = @divTrunc(parent.bounds.left + parent.bounds.right, 2), .y = item_top });
            x = parent.bounds.right - overlap;
            if (x + w > work.right) x = parent.bounds.left + overlap - w;
            y = item_top - style.px(metrics.pad_y, self.scale);
        }
        x = @max(work.left, @min(x, work.right - w));
        y = @max(work.top, @min(y, work.bottom - h));
        self.bounds = .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    }

    fn setHot(self: *Level, item: ?usize) void {
        if (self.hot == item) return;
        self.hot = item;
        self.popup.invalidate();
    }

    /// The next selectable item after `from` (or the first/last one),
    /// wrapping around.
    fn step(self: *const Level, from: ?usize, direction: Direction) ?usize {
        const all = self.items();
        const n = all.len;
        if (n == 0) return null;
        var i: usize = from orelse switch (direction) {
            .next => n - 1,
            .previous => 0,
        };
        for (0..n) |_| {
            i = switch (direction) {
                .next => (i + 1) % n,
                .previous => (i + n - 1) % n,
            };
            if (all[i].selectable()) return i;
        }
        return from;
    }

    /// Whether `item` is drawn highlighted: it is hot, or its submenu is
    /// open.
    fn highlighted(self: *const Level, item: usize) bool {
        if (self.hot == item) return true;
        const state = self.state;
        return state.depth > self.index + 1 and state.levels[self.index + 1].parent_item == item;
    }

    fn paint(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
        const self: *Level = @ptrCast(@alignCast(ctx));
        const tokens = self.state.host.tokens;
        const size = popup.sizeDip();
        const scale = popup.scale();
        canvas.fillRect(.{ .x = 0, .y = 0, .w = size.width, .h = size.height }, tokens.surface_raised);

        for (self.items(), self.rows, 0..) |item, row, i| switch (item.kind) {
            .separator => canvas.fillRect(.{
                .x = metrics.inset,
                .y = snap(row.y + row.height / 2, scale),
                .w = size.width - 2 * metrics.inset,
                .h = 1 / scale,
            }, tokens.border),
            .header => canvas.drawText(item.label, .{
                .x = self.label_x,
                .y = row.y,
                .w = @max(size.width - self.label_x - metrics.pad_x, 0),
                .h = row.height,
            }, headerStyle(tokens.text_secondary)),
            .action, .submenu => self.paintItem(canvas, item, row, i, size.width),
        };
    }

    fn paintItem(self: *Level, canvas: *d2d.Canvas, item: Item, row: Row, index: usize, width: f32) void {
        const tokens = self.state.host.tokens;
        if (item.selectable() and self.highlighted(index)) {
            const pressed = if (self.state.press) |p| p.level == self.index and p.item == index else false;
            canvas.fillRoundedRect(.{
                .x = metrics.inset,
                .y = row.y + 2,
                .w = width - 2 * metrics.inset,
                .h = row.height - 4,
            }, metrics.highlight_radius, if (pressed) tokens.pressed else tokens.hover);
            canvas.fillRoundedRect(.{
                .x = metrics.inset,
                .y = row.y + (row.height - metrics.accent_height) / 2,
                .w = metrics.accent_width,
                .h = metrics.accent_height,
            }, metrics.accent_width / 2, tokens.accent);
        }

        const text_color = if (item.enabled) tokens.text else tokens.text_disabled;
        const secondary = if (item.enabled) tokens.text_secondary else tokens.text_disabled;

        const lead: d2d.Rect = .{ .x = metrics.pad_x, .y = row.y, .w = metrics.icon_size, .h = row.height };
        switch (item.mark) {
            .check => canvas.drawIcon(check_glyph, lead, 14, text_color),
            .radio => {
                const d = metrics.radio_size;
                canvas.fillRoundedRect(.{
                    .x = lead.x + (lead.w - d) / 2,
                    .y = row.y + (row.height - d) / 2,
                    .w = d,
                    .h = d,
                }, d / 2, text_color);
            },
            .none => if (item.icon) |glyph| canvas.drawIcon(glyph, lead, metrics.icon_size, text_color),
        }

        var right = width - metrics.pad_x;
        if (self.chevron) {
            if (item.kind == .submenu) canvas.drawIcon(d2d.icons.chevron_right, .{
                .x = right - metrics.chevron_size,
                .y = row.y,
                .w = metrics.chevron_size,
                .h = row.height,
            }, 10, secondary);
            right -= metrics.chevron_size + metrics.chevron_gap;
        }
        if (item.shortcut) |text| {
            canvas.drawText(text, .{
                .x = self.label_x,
                .y = row.y,
                .w = @max(right - self.label_x, 0),
                .h = row.height,
            }, shortcutStyle(secondary));
            right -= row.shortcut_width + metrics.shortcut_gap;
        }
        canvas.drawText(item.label, .{
            .x = self.label_x,
            .y = row.y,
            .w = @max(right - self.label_x, 0),
            .h = row.height,
        }, labelStyle(text_color));
    }

    /// The root popup lost the mouse capture.
    fn dismissed(ctx: *anyopaque, popup: *Popup, reason: Popup.DismissReason) void {
        _ = popup;
        _ = reason;
        const self: *Level = @ptrCast(@alignCast(ctx));
        self.state.dismiss();
    }

    /// The popup moved to a monitor with another DPI: lay it out for it.
    fn dpiChanged(ctx: *anyopaque, popup: *Popup) void {
        const self: *Level = @ptrCast(@alignCast(ctx));
        self.scale = popup.scale();
        self.place();
        popup.setBounds(self.bounds);
    }
};

const State = struct {
    host: Host,
    owner: w32.HWND,
    alloc: Allocator,
    anchor: w32.POINT,
    owner_scale: ?f32,
    levels: [max_depth]Level = undefined,
    depth: usize = 0,
    result: Result = .open,
    /// The foreground window when the menu opened.
    foreground: ?w32.HWND,
    pending: ?Pending = null,
    /// The item a mouse button is held on.
    press: ?ItemRef = null,
    /// A mouse button went down inside the menu.
    pressed: bool = false,
    /// The pointer left the drag rectangle around `start_pt`.
    dragged: bool = false,
    start_pt: w32.POINT,
    last_pt: w32.POINT,
    /// How far the pointer moves before it counts as dragged
    /// (SM_CXDRAG, SM_CYDRAG).
    drag_x: u32,
    drag_y: u32,
    show_delay: u64,
    /// The keys that were down when the menu opened. Their releases go on
    /// to the focused window, which saw them go down.
    held_keys: std.StaticBitSet(256),

    /// Open `list` as the next level; `parent_item` is the item of the
    /// current deepest level it belongs to.
    fn open(self: *State, list: *const List, parent_item: ?usize, select_first: bool) bool {
        if (self.depth >= max_depth) return false;
        const index = self.depth;
        const level = &self.levels[index];
        level.* = .{ .state = self, .index = index, .list = list, .parent_item = parent_item };
        level.rows = self.alloc.alloc(Row, list.items.items.len) catch return false;
        const tokens = self.host.tokens;
        level.popup.create(self.host.hinstance, self.owner, self.host.factory, .{
            .activate = false,
            .capture_mouse = index == 0,
            .dismiss_on_escape = false,
            .dismiss_on_outside_click = index == 0,
            .corners = .round,
            .shadow = true,
            .border_color = tokens.border,
            .dark = tokens.dark,
        }, .{
            .ctx = level,
            .paint = Level.paint,
            .dismissed = Level.dismissed,
            .dpi_changed = Level.dpiChanged,
        }) catch |err| {
            log.warn("failed to create a menu popup err={}", .{err});
            return false;
        };
        self.depth += 1;

        if (self.owner_scale) |owner_scale| level.popup.setOwnerScale(owner_scale);
        level.scale = level.popup.ownerScale();
        level.layout();
        if (select_first) level.hot = level.step(null, .next);
        level.place();
        const hwnd = level.popup.hwnd.?;
        setCloaked(hwnd, true);
        level.popup.show(level.bounds);
        if (level.popup.scale() != level.scale) {
            level.scale = level.popup.scale();
            level.place();
            level.popup.setBounds(level.bounds);
        }
        _ = w32.UpdateWindow(hwnd);
        level.reveal_at = GetTickCount64() + reveal_ms;
        if (index > 0) self.levels[index - 1].popup.invalidate();
        return true;
    }

    /// Paint popups that are due again and uncloak them.
    fn reveal(self: *State, now: u64) void {
        for (self.levels[0..self.depth]) |*level| {
            const due = level.reveal_at orelse continue;
            if (now < due) continue;
            level.reveal_at = null;
            const hwnd = level.popup.hwnd orelse continue;
            level.popup.invalidate();
            _ = w32.UpdateWindow(hwnd);
            setCloaked(hwnd, false);
        }
    }

    /// Close the levels from `index` on.
    fn closeFrom(self: *State, index: usize) void {
        if (self.depth <= index) return;
        while (self.depth > index) {
            self.depth -= 1;
            self.levels[self.depth].popup.destroy();
        }
        if (self.press) |p| if (p.level >= index) {
            self.press = null;
        };
        if (index > 0) self.levels[index - 1].popup.invalidate();
    }

    fn dismiss(self: *State) void {
        if (self.result != .open) return;
        self.result = .cancelled;
        for (self.levels[0..self.depth]) |*level| level.popup.hide();
    }

    fn openSubmenu(self: *State, level_index: usize, item: usize, keyboard: bool) void {
        self.pending = null;
        const level = &self.levels[level_index];
        const entry = level.items()[item];
        if (!entry.selectable() or entry.kind != .submenu) return;
        level.setHot(item);
        if (self.depth > level_index + 1 and self.levels[level_index + 1].parent_item == item) {
            if (keyboard) {
                const child = &self.levels[level_index + 1];
                if (child.hot == null) child.setHot(child.step(null, .next));
            }
            return;
        }
        self.closeFrom(level_index + 1);
        _ = self.open(entry.submenu.?, item, keyboard);
    }

    /// Pick an action or open a submenu.
    fn activate(self: *State, level_index: usize, item: usize) void {
        const entry = self.levels[level_index].items()[item];
        if (!entry.selectable()) return;
        switch (entry.kind) {
            .action => self.result = .{ .picked = entry.id },
            .submenu => self.openSubmenu(level_index, item, true),
            .separator, .header => {},
        }
    }

    /// Open or close a submenu once the pointer rests for the show delay.
    fn schedule(self: *State, level: usize, item: ?usize) void {
        if (self.pending) |p| if (p.level == level and p.item == item) return;
        self.pending = .{ .level = level, .item = item, .due = GetTickCount64() + self.show_delay };
    }

    fn loop(self: *State) void {
        const timer = w32.SetTimer(null, 0, tick_ms, null);
        defer if (timer != 0) {
            _ = w32.KillTimer(null, timer);
        };
        var msg: w32.MSG = undefined;
        while (self.result == .open) {
            const got = w32.GetMessageW(&msg, null, 0, 0);
            if (got == 0) {
                // Leave WM_QUIT for the main loop.
                self.dismiss();
                w32.PostQuitMessage(@bitCast(@as(u32, @truncate(msg.wParam))));
                break;
            }
            if (got < 0) {
                self.dismiss();
                break;
            }
            const own_tick = msg.message == w32.WM_TIMER and msg.hwnd == null and msg.wParam == timer;
            if (!own_tick and !self.input(&msg)) _ = w32.DispatchMessageW(&msg);
            self.tick();
        }
    }

    /// Dismiss the menu when its owner went away or another window came
    /// to the foreground, reveal new popups and apply a due submenu change.
    fn tick(self: *State) void {
        if (self.result != .open) return;
        if (!ownerAlive(self.owner) or w32.GetForegroundWindow() != self.foreground) {
            self.dismiss();
            return;
        }
        const now = GetTickCount64();
        self.reveal(now);
        const pending = self.pending orelse return;
        if (now < pending.due) return;
        self.pending = null;
        if (pending.level >= self.depth) return;
        if (pending.item) |item| {
            self.openSubmenu(pending.level, item, false);
        } else {
            self.closeFrom(pending.level + 1);
        }
    }

    /// Handle keyboard and mouse input. Returns false for messages to
    /// dispatch normally.
    fn input(self: *State, msg: *const w32.MSG) bool {
        switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => self.key(@truncate(msg.wParam)),
            w32.WM_KEYUP, w32.WM_SYSKEYUP => {
                const vk: u8 = @truncate(msg.wParam);
                if (self.held_keys.isSet(vk)) {
                    self.held_keys.unset(vk);
                    return false;
                }
            },
            w32.WM_CHAR,
            w32.WM_DEADCHAR,
            w32.WM_SYSCHAR,
            w32.WM_SYSDEADCHAR,
            WM_UNICHAR,
            w32.WM_MOUSEWHEEL,
            w32.WM_MOUSEHWHEEL,
            => {},
            w32.WM_MOUSEMOVE, WM_NCMOUSEMOVE => self.mouseMove(msg.pt),
            w32.WM_LBUTTONDOWN,
            w32.WM_LBUTTONDBLCLK,
            w32.WM_RBUTTONDOWN,
            WM_RBUTTONDBLCLK,
            w32.WM_MBUTTONDOWN,
            WM_MBUTTONDBLCLK,
            w32.WM_XBUTTONDOWN,
            WM_XBUTTONDBLCLK,
            WM_NCLBUTTONDOWN,
            WM_NCLBUTTONDBLCLK,
            WM_NCRBUTTONDOWN,
            WM_NCRBUTTONDBLCLK,
            WM_NCMBUTTONDOWN,
            WM_NCMBUTTONDBLCLK,
            WM_NCXBUTTONDOWN,
            WM_NCXBUTTONDBLCLK,
            => self.mouseDown(msg.pt),
            w32.WM_LBUTTONUP,
            w32.WM_RBUTTONUP,
            w32.WM_MBUTTONUP,
            w32.WM_XBUTTONUP,
            WM_NCLBUTTONUP,
            WM_NCRBUTTONUP,
            WM_NCMBUTTONUP,
            WM_NCXBUTTONUP,
            => self.mouseUp(msg.pt),
            else => return false,
        }
        return true;
    }

    fn key(self: *State, vk: u16) void {
        const level = &self.levels[self.depth - 1];
        self.pending = null;
        switch (vk) {
            w32.VK_UP => level.setHot(level.step(level.hot, .previous)),
            w32.VK_DOWN => level.setHot(level.step(level.hot, .next)),
            w32.VK_HOME, w32.VK_PRIOR => level.setHot(level.step(null, .next)),
            w32.VK_END, w32.VK_NEXT => level.setHot(level.step(null, .previous)),
            w32.VK_RIGHT => if (level.hot) |item| {
                if (level.items()[item].kind == .submenu) self.openSubmenu(level.index, item, true);
            },
            w32.VK_LEFT => if (self.depth > 1) self.closeFrom(self.depth - 1),
            w32.VK_ESCAPE => if (self.depth > 1) self.closeFrom(self.depth - 1) else self.dismiss(),
            w32.VK_RETURN, w32.VK_SPACE => if (level.hot) |item| self.activate(level.index, item),
            w32.VK_MENU, w32.VK_F10 => self.dismiss(),
            else => {},
        }
    }

    const Hit = struct {
        level: usize,
        /// The row under the point, of any kind.
        item: ?usize,
    };

    /// The menu (deepest first) and row at screen point `pt`.
    fn hitTest(self: *State, pt: w32.POINT) ?Hit {
        var i = self.depth;
        while (i > 0) {
            i -= 1;
            const level = &self.levels[i];
            const b = level.bounds;
            if (pt.x < b.left or pt.x >= b.right or pt.y < b.top or pt.y >= b.bottom) continue;
            const y = @as(f32, @floatFromInt(pt.y - b.top)) / level.scale;
            for (level.rows, 0..) |row, index| {
                if (y >= row.y and y < row.y + row.height) return .{ .level = i, .item = index };
            }
            return .{ .level = i, .item = null };
        }
        return null;
    }

    /// The selectable item of a hit, if any.
    fn hitItem(self: *State, hit: Hit) ?usize {
        const index = hit.item orelse return null;
        return if (self.levels[hit.level].items()[index].selectable()) index else null;
    }

    fn mouseMove(self: *State, pt: w32.POINT) void {
        // Windows also reports a move when windows change under a resting
        // pointer; only real movement changes the highlight.
        if (pt.x == self.last_pt.x and pt.y == self.last_pt.y) return;
        self.last_pt = pt;
        if (@abs(pt.x - self.start_pt.x) > self.drag_x or
            @abs(pt.y - self.start_pt.y) > self.drag_y) self.dragged = true;

        const hit = self.hitTest(pt) orelse {
            self.levels[self.depth - 1].setHot(null);
            self.pending = null;
            return;
        };
        const level = &self.levels[hit.level];
        const item = self.hitItem(hit);
        level.setHot(item);
        for (self.levels[hit.level + 1 .. self.depth]) |*deeper| deeper.setHot(null);

        const submenu_item: ?usize = if (item) |i|
            (if (level.items()[i].kind == .submenu) i else null)
        else
            null;
        if (hit.level + 1 < self.depth) {
            if (submenu_item != null and submenu_item == self.levels[hit.level + 1].parent_item) {
                self.pending = null;
            } else {
                self.schedule(hit.level, submenu_item);
            }
        } else if (submenu_item) |i| {
            self.schedule(hit.level, i);
        } else {
            self.pending = null;
        }
    }

    fn mouseDown(self: *State, pt: w32.POINT) void {
        const hit = self.hitTest(pt) orelse {
            self.dismiss();
            return;
        };
        self.pressed = true;
        const item = self.hitItem(hit) orelse return;
        const level = &self.levels[hit.level];
        switch (level.items()[item].kind) {
            .submenu => self.openSubmenu(hit.level, item, false),
            .action => {
                level.setHot(item);
                self.press = .{ .level = hit.level, .item = item };
                level.popup.invalidate();
            },
            .separator, .header => {},
        }
    }

    fn mouseUp(self: *State, pt: w32.POINT) void {
        if (self.press) |p| {
            self.press = null;
            if (p.level < self.depth) self.levels[p.level].popup.invalidate();
        }
        const hit = self.hitTest(pt) orelse return;
        const item = self.hitItem(hit) orelse return;
        const entry = self.levels[hit.level].items()[item];
        if (entry.kind != .action) return;
        // The release of the click that opened the menu picks nothing
        // unless the pointer was dragged onto the item.
        if (!self.pressed and !self.dragged) return;
        self.result = .{ .picked = entry.id };
    }
};

test "Builder copies text and nests submenus" {
    const testing = std.testing;
    var builder: Builder = .init(testing.allocator);
    defer builder.deinit();

    var label_buf = "Copy".*;
    var shortcut_buf = "Ctrl+C".*;
    try builder.add(&builder.root, .{ .id = 1, .label = &label_buf, .shortcut = &shortcut_buf });
    label_buf[0] = 'X';
    shortcut_buf[0] = 'X';
    try builder.separator(&builder.root);
    try builder.header(&builder.root, "Section");
    const split = try builder.submenu(&builder.root, .{ .label = "Split" });
    try builder.add(split, .{ .id = 2, .label = "Right" });
    _ = try builder.submenu(&builder.root, .{ .label = "Empty" });

    const items = builder.root.items.items;
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("Copy", items[0].label);
    try testing.expectEqualStrings("Ctrl+C", items[0].shortcut.?);
    try testing.expect(items[0].selectable());
    try testing.expect(!items[1].selectable());
    try testing.expect(!items[2].selectable());
    try testing.expectEqual(Item.Kind.submenu, items[3].kind);
    try testing.expect(items[3].selectable());
    try testing.expectEqualStrings("Right", items[3].submenu.?.items.items[0].label);
    try testing.expect(!items[4].selectable());
}
