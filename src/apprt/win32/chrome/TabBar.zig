//! The tab bar of a top-level terminal window: the tabs inside the chrome
//! row of `chrome/TitleBar.zig`, painted with Direct2D (8 DIP rounded top
//! corners; the active tab has the terminal background and flows into the
//! terminal below), hit-testing, hover, drag-to-reorder, the per-tab close
//! button, the tab status (progress, bell, new output, zoom), the new-tab
//! and launch profile buttons, the right-click menu, middle-click close and
//! inline renaming of tab and window titles.
//!
//! The tab model (split trees, active surfaces, titles, unread and bell
//! flags, progress; the status of a tab in `Window.tabStatus`) stays in
//! `Window`; the tab bar reads it and asks the window to change it
//! (`selectTabIndex`, `closeTabByIndex`, `moveTabTo`, ...). The geometry
//! comes from the title bar `Layout` on demand (`geometry`,
//! `chrome/tab_layout.zig`), so hit tests never depend on a previous paint:
//! equal widths down to a minimum, the active tab with a floor and its
//! close button, inactive tabs with theirs while hovered; tabs that do not
//! fit scroll (wheel, scroll buttons, the active tab scrolled into view)
//! and a button lists them all (`Menu.showTabList`). Closing a tab with its
//! close button or the middle button keeps the widths until the pointer
//! leaves the tabs. In a maximized or fullscreen window the tabs take
//! clicks up to the screen edge.
//!
//! Labels (`tab_layout.label`): an idle shell shows its title, a running
//! program `program · title` with the program in the secondary color. Every
//! two seconds one process table, shared by all windows (`App.processTable`,
//! one capture per period), tells each tab's focused terminal what runs in
//! it (`gx.proc.Tree.program`), whether that is idle (`gx-idle-processes`)
//! and what kind it is (`gx.leader`: remote, superuser, container), shown
//! as an icon. New output in background tabs comes from `gx.unread.Tracker`
//! (a baseline when the tab is hidden, checked every second without waiting
//! for the terminal lock); the bell marks the tab separately
//! (`Window.ringTab`). The status is compared every second so a progress
//! report that went stale repaints.
//!
//! Dragging a tab moves it with the pointer after 10 DIPs; the others slide
//! aside (`anim`), the drop moves it in the model, and Escape (a keyboard
//! hook of the GUI thread while dragging, the terminal keeps the focus) or a
//! lost capture puts it back.
//!
//! Renaming a tab or the window opens a text field over the tab: a popup
//! with a text input (`Popup.Options.text_input`) shown from the message
//! loop. Enter or clicking elsewhere keeps the text, Escape cancels; an
//! empty text removes the title override. Without Direct2D the field is an
//! Edit control.
//!
//! The owning `Window` embeds this struct as `tab_bar` and forwards the
//! chrome row input to it, mostly through `TitleBar`.
const TabBar = @This();

const std = @import("std");
const App = @import("../App.zig");
const Window = @import("../Window.zig");
const Surface = @import("../Surface.zig");
const Pane = @import("../Pane.zig");
const PaneSnapshot = @import("../PaneSnapshot.zig");
const Menu = @import("../ui/Menu.zig");
const Popup = @import("../ui/Popup.zig");
const anim = @import("../ui/anim.zig");
const d2d = @import("../ui/d2d.zig");
const style = @import("../ui/style.zig");
const trigger = @import("../ui/trigger.zig");
const w32 = @import("../win32.zig");
const tabs = @import("../tabs.zig");
const tab_status = @import("../tab_status.zig");
const Backdrop = @import("Backdrop.zig");
const TitleBar = @import("TitleBar.zig");
const tab_layout = @import("tab_layout.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const input = @import("../../../input.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
pub const max_tabs = Window.MAX_TABS;

/// Rename edit control child ID.
pub const RENAME_EDIT_ID: u16 = 300;

/// The timer that repeats a held scroll button, on the window, with a
/// TIMERPROC (the window procedure never sees it).
const SCROLL_TIMER_ID: usize = 0x5452; // 'TR'

/// Whether the tabs are shown (see `updateVisibility`).
visible: bool = false,

/// The visible part of each tab at the last paint (client pixels), for
/// tooltips. Zero-initialized so nothing matches before the first paint.
tab_rects: [max_tabs]w32.RECT = std.mem.zeroes([max_tabs]w32.RECT),

/// The new-tab ("+") and launch profile ("▾") buttons of the last paint.
new_tab_rect: w32.RECT = TitleBar.empty_rect,
profile_rect: w32.RECT = TitleBar.empty_rect,

/// The part under the mouse and the part being pressed.
hover: Part = .none,
pressed: Part = .none,

middle_press: tab_layout.MiddlePress = .{},

/// A tab pressed and maybe dragged.
drag: ?Drag = null,

/// The tabs sliding to their places after a drag moved them (`anim`):
/// where each started, in content pixels by model index.
slide_from: [max_tabs]i32 = undefined,
slide: anim.Tween = .{ .start_ns = 0, .duration_ns = 0 },
sliding: bool = false,
animator: anim.Animator = .{ .tick = slideTick },

/// How far the tabs scroll (DIPs) when they do not fit, and whether the
/// active tab is to be scrolled into view at the next paint.
scroll: f32 = 0,
reveal_pending: bool = true,
/// The strip width of the last paint: a resize reveals the active tab.
painted_area_w: i32 = 0,

/// The widths kept since a tab closed through its close button.
frozen: ?tab_layout.Frozen = null,

geometry_cache: tab_layout.Cache = .{},
labels: [max_tabs]CachedLabel = [_]CachedLabel{.{}} ** max_tabs,
polling: tab_layout.Polling = .{},

/// Inline renaming: what is renamed, the text field over it (a popup, or
/// an Edit control and its font without Direct2D) and where the popup
/// shows (screen pixels).
rename_target: RenameTarget = .none,
rename_popup: Popup = .{},
rename_rect: w32.RECT = TitleBar.empty_rect,
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// What runs in the tabs' focused terminals.
processes: [max_tabs]ProcessName = [_]ProcessName{.{}} ** max_tabs,

/// The new-output trackers of the terminals, by core surface id.
tracked: [max_tracked]Tracked = undefined,
tracked_len: usize = 0,

/// The status each tab was painted with, to repaint when it changes.
painted_status: [max_tabs]StatusKey = [_]StatusKey{.{}} ** max_tabs,

/// Ticks of `onTimer` (one per second).
ticks: u32 = 0,

/// Whether Ghostty runs elevated (the administrator badge before the
/// tabs), looked up once.
elevated: ?bool = null,

/// The chrome colors of the last tokens painted with.
chrome_cache: ?ChromeCache = null,

/// The outline of the active tab, kept while it stays in place.
active_path: ?d2d.Path = null,
active_path_key: [4]f32 = .{ 0, 0, 0, 0 },

/// A pressed tab, and once it moved far enough, a dragged one.
const Drag = struct {
    /// The tab (the active one: a press selects it).
    tab: usize,
    reference: @import("../../../gx/ui_ref.zig").Reference,
    /// Where the press was, and how far right of the tab's left edge.
    press_x: i32,
    press_y: i32,
    grab: i32,
    /// The pointer moved far enough to drag.
    active: bool = false,
    /// The pointer (client x).
    x: i32,
    /// The slot it drops into.
    target: usize,
};

/// What an inline rename changes.
const RenameTarget = union(enum) {
    none,
    /// The title override of a tab (`Window.setTabTitleOverride`).
    tab: usize,
    /// The window title override (`Window.setWindowTitleOverride`).
    window,
};

/// What runs in a terminal, for its tab's label and icon.
const ProcessName = struct {
    pane: PaneSnapshot.Reference = .{},
    len: u8 = 0,
    buf: [48]u8 = undefined,
    /// The terminal runs a WSL distribution.
    wsl: bool = false,
    /// The program is the shell or another idle process.
    idle: bool = false,
    kind: gx.leader.Kind = .local,
    /// The shell (the process the terminal started).
    shell_len: u8 = 0,
    shell_buf: [32]u8 = undefined,

    fn name(self: *const ProcessName) []const u8 {
        return self.buf[0..self.len];
    }

    fn shell(self: *const ProcessName) []const u8 {
        return self.shell_buf[0..self.shell_len];
    }

    fn eql(a: *const ProcessName, b: *const ProcessName) bool {
        return PaneSnapshot.sameIdentity(a.pane, b.pane) and a.wsl == b.wsl and a.idle == b.idle and a.kind == b.kind and
            std.mem.eql(u8, a.name(), b.name()) and std.mem.eql(u8, a.shell(), b.shell());
    }
};

const max_tracked = 256;

const Tracked = struct {
    reference: PaneSnapshot.Reference,
    unread: Pane.UnreadTracker = .{},
};

/// What the status marks of a tab show.
const StatusKey = struct {
    state: tab_status.ProgressState = .none,
    percent: ?u8 = null,
    bell: bool = false,
    unread: bool = false,
    zoomed: bool = false,

    fn of(status: tab_status.TabStatus) StatusKey {
        return .{
            .state = status.progress.state,
            .percent = status.progress.percent,
            .bell = status.bell,
            .unread = status.unread,
            .zoomed = status.zoomed,
        };
    }
};

const ChromeCache = struct {
    tokens: style.Tokens,
    chrome: gx.chrome.Chrome,
};

const CachedLabel = struct {
    layout: ?d2d.TextLayout = null,
    text: [tabs.max_title_len * 3 + 64]u8 = undefined,
    len: usize = 0,
    width: f32 = 0,
    height: f32 = 0,

    fn get(self: *CachedLabel, factory: *d2d.Factory, text: []const u8, area: d2d.Rect) ?*const d2d.TextLayout {
        if (self.layout == null or self.width != area.w or self.height != area.h or !std.mem.eql(u8, self.text[0..self.len], text)) {
            self.deinit();
            const span: ?gx.perf.Span = if (gx.perf.enabled()) .begin(global.io()) else null;
            defer if (span) |s| {
                _ = s.end(global.io(), "tabs.layout_create");
            };
            self.layout = d2d.TextLayout.initUtf8(factory, text, .{ .size = title_font_size }, area.w, area.h) orelse return null;
            @memcpy(self.text[0..text.len], text);
            self.len = text.len;
            self.width = area.w;
            self.height = area.h;
        }
        return &self.layout.?;
    }

    fn deinit(self: *CachedLabel) void {
        if (self.layout) |*layout| layout.deinit();
        self.layout = null;
    }
};

/// A part of the tab bar.
pub const Part = union(enum) {
    none,
    tab: usize,
    tab_close: usize,
    new_tab,
    profiles,
    scroll_back,
    scroll_forward,
    tab_list,

    fn eql(a: Part, b: Part) bool {
        return std.meta.eql(a, b);
    }
};

// Sizes in DIPs.
const tab_radius: f32 = style.radius.overlay;
const tab_flare: f32 = 6;
const tab_pad_x: f32 = 12;
const text_pad_right: f32 = 8;
const icon_size: f32 = 16;
const icon_gap: f32 = 6;
const status_glyph_size: f32 = 12;
const status_gap: f32 = 4;
const title_font_size: f32 = 12;
const unread_dot_size: f32 = 6;
const close_glyph_size: f32 = 10;
const fade_width: f32 = 16;
const progress_radius: f32 = 6;
const progress_stroke: f32 = 2;

// Icon font glyphs (Segoe Fluent Icons / Segoe MDL2 Assets).
const glyph = struct {
    const close: u21 = d2d.icons.cancel;
    const bell: u21 = 0xEA8F; // Ringer
    const zoom: u21 = 0xE8A3; // ZoomIn
    const remote: u21 = 0xE774; // Globe
    const superuser: u21 = 0xE7EF; // Admin
    const container: u21 = 0xE7B8; // Package
    const scroll_back: u21 = 0xE76B; // ChevronLeft
    const scroll_forward: u21 = d2d.icons.chevron_right;
    const tab_list: u21 = 0xE8FD; // BulletedList
};

fn window(self: *TabBar) *Window {
    return @alignCast(@fieldParentPtr("tab_bar", self));
}

fn windowConst(self: *const TabBar) *const Window {
    return @alignCast(@fieldParentPtr("tab_bar", self));
}

/// Release the rename field, drag hook, animation and drawing caches.
pub fn deinit(self: *TabBar) void {
    for (&self.labels) |*label| label.deinit();
    self.rename_target = .none;
    self.rename_popup.destroy();
    if (self.rename_font) |font| {
        _ = w32.DeleteObject(font);
        self.rename_font = null;
    }
    anim.stop(&self.animator);
    self.sliding = false;
    if (self.drag != null) escape_hook.release();
    self.drag = null;
    if (self.active_path) |*path| path.deinit();
    self.active_path = null;
    if (self.window().hwnd) |hwnd| _ = w32.KillTimer(hwnd, SCROLL_TIMER_ID);
}

/// Recompute whether the tabs are shown from `window-show-tab-bar`, the
/// tab count, the frame and `Window.tab_bar_suppressed` (herdr app mode).
/// With the integrated title bar the row exists anyway, so `auto` shows
/// even a single tab. Returns true when it changed, so the window must
/// lay itself out again.
pub fn updateVisibility(self: *TabBar) bool {
    const win = self.window();
    _ = self.isElevated();
    const caption_row = win.title_bar.hasCaptionRow() or win.title_bar.frame() == .borderless;
    const should_show = if (win.is_quick_terminal or win.tab_bar_suppressed) false else switch (win.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => caption_row or win.tab_count > 1,
        .never => false,
    };
    if (should_show == self.visible) return false;
    self.visible = should_show;
    self.reveal_pending = true;
    return true;
}

/// Repaint the chrome row.
pub fn invalidate(self: *TabBar) void {
    self.window().title_bar.invalidate();
}

// -----------------------------------------------------------------------
// Geometry
// -----------------------------------------------------------------------

/// The tab bar parts for a title bar layout, in client pixels (no tabs
/// when they are hidden).
pub fn geometry(self: *const TabBar, lay: TitleBar.Layout) tab_layout.Layout {
    if (!self.visible or lay.height() <= 0) return .{ .scale = lay.scale };
    return self.geometry_cache.get(self.geometryInput(lay));
}

fn geometryInput(self: *const TabBar, lay: TitleBar.Layout) tab_layout.Input {
    const win = self.windowConst();
    return .{
        .area = .{ .left = lay.tabs.left, .top = lay.tabs.top, .right = lay.tabs.right, .bottom = lay.bar.bottom },
        .hit_top = if (self.reachesTop()) lay.bar.top else lay.tabs.top,
        .scale = lay.scale,
        .count = @min(win.tab_count, max_tabs),
        .active = win.active_tab,
        .badge = self.elevated orelse false,
        .frozen = self.frozen,
        .scroll = self.scroll,
    };
}

/// Whether the tabs take clicks up to the top of the window: it is
/// maximized or fullscreen, so its top edge is the screen's.
fn reachesTop(self: *const TabBar) bool {
    const win = self.windowConst();
    if (win.title_bar.is_fullscreen) return true;
    const hwnd = win.hwnd orelse return false;
    return w32.IsZoomed(hwnd) != 0;
}

fn rect(r: tab_layout.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// A button's rectangle over the whole height of the hit rectangles.
fn tallHit(g: *const tab_layout.Layout, r: tab_layout.Rect) tab_layout.Rect {
    if (r.isEmpty()) return r;
    return .{ .left = r.left, .top = g.hit_top, .right = r.right, .bottom = g.bottom };
}

/// The hover fill of the close button of tab `i` for `lay` (tooltip
/// anchor).
pub fn closeRect(self: *const TabBar, lay: TitleBar.Layout, i: usize) w32.RECT {
    const g = self.geometry(lay);
    if (i >= g.count) return TitleBar.empty_rect;
    return rect(g.closeRectOf(g.tabRect(i)));
}

/// The visible part of tab `i` at the last paint.
pub fn tabRect(self: *const TabBar, i: usize) w32.RECT {
    if (i >= max_tabs) return TitleBar.empty_rect;
    return self.tab_rects[i];
}

fn partAt(self: *const TabBar, g: *const tab_layout.Layout, x: i32, y: i32) Part {
    _ = self;
    if (g.count == 0 and g.new_tab.isEmpty()) return .none;
    if (g.hitRect(g.new_tab).contains(x, y)) return .new_tab;
    if (g.hitRect(g.profiles).contains(x, y)) return .profiles;
    if (g.overflow) {
        if (tallHit(g, g.scroll_back).contains(x, y)) return .scroll_back;
        if (tallHit(g, g.scroll_forward).contains(x, y)) return .scroll_forward;
        if (g.hitRect(g.list).contains(x, y)) return .tab_list;
    }
    const i = g.tabAt(x, y) orelse return .none;
    const tab = g.tabRect(i);
    if (g.closable(tab.width()) and g.closeHitOf(tab).contains(x, y)) return .{ .tab_close = i };
    return .{ .tab = i };
}

/// Whether a chrome row point hits a tab or a tab bar button.
pub fn hitsSomething(self: *const TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    return self.partAt(&g, x, y) != .none;
}

/// Scroll the tabs by `dips` (positive: toward the last tab), clamped.
fn scrollBy(self: *TabBar, lay: TitleBar.Layout, dips: f32) void {
    const g = self.geometry(lay);
    if (!g.overflow) return;
    const max: f32 = @as(f32, @floatFromInt(g.max_scroll_px)) / g.scale;
    const current: f32 = @as(f32, @floatFromInt(g.scroll_px)) / g.scale;
    const next = std.math.clamp(current + dips, 0, max);
    if (next == current) return;
    self.scroll = next;
    self.reveal_pending = false;
    self.invalidate();
    self.rehover(lay);
}

/// The tabs moved under a pointer that stayed: hover what is under it now.
fn rehover(self: *TabBar, lay: TitleBar.Layout) void {
    if (self.drag != null) return;
    const hwnd = self.window().hwnd orelse return;
    var cursor: w32.POINT = undefined;
    if (w32.GetCursorPos_(&cursor) == 0) return;
    _ = w32.ScreenToClient(hwnd, &cursor);
    const g = self.geometry(lay);
    self.setHover(self.partAt(&g, cursor.x, cursor.y));
}

// -----------------------------------------------------------------------
// Painting
// -----------------------------------------------------------------------

/// The colors of one paint (see `colorsFor`).
const Colors = struct {
    /// The active tab's title and program.
    active_text: d2d.Color,
    active_program: d2d.Color,
    /// Inactive tabs' titles and programs, and a hovered one's title.
    text: d2d.Color,
    program: d2d.Color,
    hover_text: d2d.Color,
    /// Row button glyphs, enabled and disabled.
    glyph: d2d.Color,
    glyph_disabled: d2d.Color,
    separator: d2d.Color,
    hover: d2d.Color,
    pressed: d2d.Color,
    accent: d2d.Color,
    critical: d2d.Color,
    caution: d2d.Color,
    /// Glyphs on an opaque hover or press fill (high contrast), else null
    /// for the color of the tab's text.
    on_hover: ?d2d.Color,
    /// The ring behind progress.
    track: d2d.Color,
    active_fill: u32,
    /// The strip the fades replace towards, or null over a bare material.
    strip: ?d2d.Color,
};

fn sharedTokens(t: style.Tokens) gx.ui_tokens.Tokens {
    var out: gx.ui_tokens.Tokens = undefined;
    inline for (@typeInfo(gx.ui_tokens.Tokens).@"struct".fields) |field| {
        @field(out, field.name) = @field(t, field.name);
    }
    return out;
}

/// The chrome colors (`gx.chrome`) of `tokens`, the strip `TitleBar`
/// paints, cached by the tokens.
fn chromeOf(self: *TabBar, tokens: style.Tokens) gx.chrome.Chrome {
    if (self.chrome_cache) |cache| {
        if (std.meta.eql(cache.tokens, tokens)) return cache.chrome;
    }
    const chrome: gx.chrome.Chrome = if (tokens.high_contrast)
        .fromSystem(style.system.colors)
    else blk: {
        const shared = sharedTokens(tokens);
        break :blk .derive(&shared, .{});
    };
    self.chrome_cache = .{ .tokens = tokens, .chrome = chrome };
    return chrome;
}

/// Text over a window material: white on a dark one, black on a light one
/// (Fluent text fills: primary, secondary and tertiary).
fn materialText(dark: bool, level: u2) d2d.Color {
    const base: d2d.Color = if (dark) .white else .black;
    const alpha: [3]f32 = if (dark) .{ 1.0, 0.786, 0.544 } else .{ 0.896, 0.606, 0.446 };
    return base.withAlpha(alpha[@min(level, 2)]);
}

fn colorsFor(self: *TabBar, ctx: TitleBar.PaintContext) Colors {
    const win = self.window();
    const config = &win.app.config;
    const t = ctx.tokens;
    const chrome = self.chromeOf(t);
    const strip_dark = if (ctx.translucent) Backdrop.isDark(config.@"window-theme", config.background) else chrome.dark;

    const active_fill = ctx.tab_fill;

    var c: Colors = undefined;
    if (ctx.translucent and !t.high_contrast) {
        const level: u2 = if (ctx.active) 0 else 1;
        c.text = materialText(strip_dark, level + 1);
        c.program = materialText(strip_dark, 2);
        c.hover_text = materialText(strip_dark, level);
        c.glyph = materialText(strip_dark, level);
        c.glyph_disabled = materialText(strip_dark, 0).withAlpha(0.36);
        c.separator = materialText(strip_dark, 0).withAlpha(0.16);
        c.hover = materialText(strip_dark, 0).withAlpha(if (strip_dark) 0.08 else 0.06);
        c.pressed = materialText(strip_dark, 0).withAlpha(if (strip_dark) 0.05 else 0.04);
        c.strip = null;
    } else {
        const strip = chrome.title_bar;
        const dim = gx.ui_color.ensureContrast(gx.ui_color.mix(chrome.text_inactive, strip, 0.4), strip, gx.ui_tokens.floor.non_text);
        c.text = if (ctx.active) chrome.text_inactive else dim;
        c.program = dim;
        c.hover_text = if (t.high_contrast) t.hover_text else if (ctx.active) chrome.text else chrome.text_inactive;
        c.glyph = if (ctx.active) chrome.text else t.text_disabled;
        c.glyph_disabled = t.text_disabled;
        c.separator = chrome.tab_separator;
        c.hover = t.overlay_hover;
        c.pressed = t.overlay_pressed;
        c.strip = strip;
    }
    // The active tab's text: on its own fill, or over the material when
    // that shows through it.
    if (active_fill >> 24 < 255) {
        c.active_text = materialText(strip_dark, if (ctx.active) 0 else 1);
        c.active_program = materialText(strip_dark, 2);
    } else if (ctx.active) {
        c.active_text = chrome.text;
        c.active_program = t.text_secondary;
    } else {
        c.active_text = t.text_secondary;
        c.active_program = t.text_tertiary;
    }
    c.on_hover = if (t.high_contrast) t.hover_text else null;
    c.accent = t.accent;
    c.critical = t.critical;
    c.caution = t.caution;
    c.active_fill = active_fill;
    applyCaptionColors(&c, ctx);
    c.track = c.hover_text.withAlpha(0.22);
    return c;
}

fn applyCaptionColors(colors: *Colors, ctx: anytype) void {
    const Context = @TypeOf(ctx);
    if (@hasField(Context, "strip_fill")) {
        colors.strip = if (ctx.strip_fill.a > 0) ctx.strip_fill else null;
    }
    if (@hasField(Context, "strip_text") and @hasField(Context, "strip_text_inactive")) {
        const glyph_color = if (ctx.active) ctx.strip_text else ctx.strip_text_inactive;
        colors.glyph = glyph_color;
        colors.glyph_disabled = ctx.strip_text_inactive;
        colors.hover_text = if (ctx.tokens.high_contrast) ctx.tokens.hover_text else glyph_color;
        if (!ctx.active) {
            colors.text = ctx.strip_text_inactive;
            colors.program = ctx.strip_text_inactive;
        }
    }
    if (@hasDecl(Context, "hoverGlyphColor")) colors.on_hover = ctx.hoverGlyphColor();
}

/// Paint the tabs (or, when they are hidden, the window title) into the
/// chrome row.
pub fn paint(self: *TabBar, ctx: TitleBar.PaintContext) void {
    const span: ?gx.perf.Span = if (gx.perf.enabled()) .begin(global.io()) else null;
    defer if (span) |s| {
        _ = s.end(global.io(), "tabs.paint");
    };
    const win = self.window();
    const lay = ctx.layout;
    if (!self.visible) {
        self.new_tab_rect = TitleBar.empty_rect;
        self.profile_rect = TitleBar.empty_rect;
        if (lay.caption) self.paintWindowTitle(ctx);
        return;
    }

    const area_w = lay.tabs.right - lay.tabs.left;
    if (area_w != self.painted_area_w) {
        self.painted_area_w = area_w;
        if (self.frozen) |f| if (f.area_w != area_w) {
            self.frozen = null;
        };
        self.reveal_pending = true;
    }
    if (self.reveal_pending and self.drag == null) {
        self.reveal_pending = false;
        const g0 = self.geometry(lay);
        if (g0.overflow) self.scroll = g0.revealScroll(win.active_tab);
    }

    const g = self.geometry_cache.update(self.geometryInput(lay));
    const colors = self.colorsFor(ctx);
    const canvas = ctx.canvas;
    self.new_tab_rect = rect(g.new_tab);
    self.profile_rect = rect(g.profiles);
    for (0..max_tabs) |i| self.tab_rects[i] = if (i < g.count) rect(g.visibleRect(i)) else TitleBar.empty_rect;

    if (!g.badge.isEmpty()) {
        canvas.drawIcon(d2d.icons.shield, ctx.dipRect(rect(g.badge)), status_glyph_size, colors.glyph);
    }

    var lefts: [max_tabs]i32 = undefined;
    self.displayedLefts(&g, anim.now(), &lefts);
    const dragged: ?usize = if (self.drag) |d| (if (d.active) d.tab else null) else null;

    const s = lay.scale;
    const view_left = style.dip(g.view_left, s);
    const view_right = style.dip(g.view_right, s);
    const flare: f32 = if (g.overflow) 0 else tab_flare;
    const bottom = style.dip(lay.bar.bottom - lay.bar.top, s);
    canvas.pushClip(.{ .x = view_left - flare, .y = 0, .w = view_right - view_left + flare, .h = bottom });

    // Inactive tabs first, the active (or dragged) tab last so its flares
    // overlap them. Tabs scrolled out of view are only looked at.
    const front: ?usize = dragged orelse if (g.active < g.count) g.active else null;
    for (0..g.count) |i| {
        if (front != null and i == front.?) continue;
        if (lefts[i] + g.width(i) <= g.view_left or lefts[i] >= g.view_right) {
            self.painted_status[i] = StatusKey.of(win.tabStatus(i));
            continue;
        }
        self.paintTab(ctx, &g, &colors, i, lefts[i], i == g.active);
    }
    self.paintSeparators(ctx, &g, &colors, &lefts, front);
    if (front) |i| self.paintTab(ctx, &g, &colors, i, lefts[i], i == g.active);
    canvas.popClip();

    if (g.overflow) {
        if (colors.strip) |strip| {
            if (g.clipped(true)) paintFade(canvas, view_left, bottom, strip, true);
            if (g.clipped(false)) paintFade(canvas, view_right, bottom, strip, false);
        }
        self.paintRowButton(ctx, &colors, g.scroll_back, .scroll_back, glyph.scroll_back, 10, g.clipped(true));
        self.paintRowButton(ctx, &colors, g.scroll_forward, .scroll_forward, glyph.scroll_forward, 10, g.clipped(false));
        self.paintRowButton(ctx, &colors, g.list, .tab_list, glyph.tab_list, 12, true);
    }
    self.paintRowButton(ctx, &colors, g.new_tab, .new_tab, d2d.icons.add, 12, true);
    self.paintRowButton(ctx, &colors, g.profiles, .profiles, d2d.icons.chevron_down, 9, true);
}

/// The left edge (client pixels) each tab shows at: its place, the
/// pointer for a dragged tab, on the way there while the tabs slide.
fn displayedLefts(self: *const TabBar, g: *const tab_layout.Layout, now: u64, out: *[max_tabs]i32) void {
    const base = g.view_left - g.scroll_px;
    for (0..g.count) |i| out[i] = base + self.displayedContentLeft(g, i, now);
}

/// Where (content pixels) tab `i` shows (see `displayedLefts`).
fn displayedContentLeft(self: *const TabBar, g: *const tab_layout.Layout, i: usize, now: u64) i32 {
    if (self.drag) |d| if (d.active and i == d.tab) {
        const left = d.x - d.grab - g.view_left + g.scroll_px;
        return std.math.clamp(left, 0, @max(0, g.content_w - g.width(i)));
    };
    const target = self.placeOf(g, i);
    if (!self.sliding or self.slide.done(now)) return target;
    return @intFromFloat(@round(self.slide.lerp(now, @floatFromInt(self.slide_from[i]), @floatFromInt(target))));
}

/// Where (content pixels) tab `i` belongs: its slot, or the slot the drag
/// leaves for it.
fn placeOf(self: *const TabBar, g: *const tab_layout.Layout, i: usize) i32 {
    if (self.drag) |d| if (d.active and d.tab < g.count) {
        return tab_layout.dragSlotLeft(i, d.tab, d.target, g.tab_w, g.width(d.tab));
    };
    return g.contentLeft(i);
}

fn paintSeparators(self: *TabBar, ctx: TitleBar.PaintContext, g: *const tab_layout.Layout, colors: *const Colors, lefts: *const [max_tabs]i32, front: ?usize) void {
    // Not while the tabs move.
    if (self.sliding) return;
    if (self.drag) |d| if (d.active) return;
    for (1..@max(g.count, 1)) |i| {
        const left = i - 1;
        if (left == g.active or i == g.active) continue;
        if (front != null and (left == front.? or i == front.?)) continue;
        if (self.isHoveredTab(left) or self.isHoveredTab(i)) continue;
        const x = lefts[i];
        if (x <= g.view_left or x >= g.view_right) continue;
        const r = ctx.dipRect(.{ .left = x, .top = g.top, .right = x, .bottom = g.bottom });
        const h = r.h * 0.45;
        ctx.canvas.hairlineV(r.x, r.y + (r.h - h) / 2, h, colors.separator);
    }
}

/// Replace towards the strip at a scrolled edge, including its alpha.
fn paintFade(canvas: *d2d.Canvas, edge: f32, height: f32, strip: d2d.Color, at_start: bool) void {
    if (!canvas.beginReplacement(d2d.colorPixel(strip))) return;
    const px_w = canvas.hairline();
    const steps: usize = @intFromFloat(@max(1, @round(fade_width / px_w)));
    for (0..steps) |k| {
        const share = 1 - @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
        const offset = @as(f32, @floatFromInt(k)) * px_w;
        const x = if (at_start) edge + offset else edge - offset - px_w;
        canvas.fillRect(.{ .x = x, .y = 0, .w = px_w, .h = height }, d2d.Color.white.withAlpha(share * share));
    }
    canvas.endReplacement();
}

fn isHoveredTab(self: *const TabBar, i: usize) bool {
    return switch (self.hover) {
        .tab, .tab_close => |h| h == i,
        else => false,
    };
}

fn paintTab(
    self: *TabBar,
    ctx: TitleBar.PaintContext,
    g: *const tab_layout.Layout,
    colors: *const Colors,
    i: usize,
    left: i32,
    active: bool,
) void {
    const win = self.window();
    const canvas = ctx.canvas;
    const tab: tab_layout.Rect = .{ .left = left, .top = g.top, .right = left + g.width(i), .bottom = g.bottom };
    const r = ctx.dipRect(rect(tab));
    const hovered = self.isHoveredTab(i) and self.drag == null;
    const dragged = if (self.drag) |d| d.active and d.tab == i else false;
    const status = win.tabStatus(i);
    self.painted_status[i] = StatusKey.of(status);

    if (active) {
        self.fillActiveTab(canvas, r, colors.active_fill);
    } else if (hovered or dragged) {
        // Rounded top corners only: let the bottom corners fall outside
        // the row.
        canvas.pushClip(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        canvas.fillRoundedRect(.{ .x = r.x + 1, .y = r.y + 2, .w = r.w - 2, .h = r.h + tab_radius }, tab_radius, colors.hover);
        canvas.popClip();
    }

    const title_color = if (active) colors.active_text else if (hovered or dragged) colors.hover_text else colors.text;
    const program_color = if (active) colors.active_program else colors.program;

    // The close button (active, hovered or dragged tab), else the new
    // output dot in its place.
    const close = ctx.dipRect(rect(g.closeRectOf(tab)));
    const close_visible = g.closable(tab.width()) and (active or hovered or dragged);
    var text_right = r.x + r.w - text_pad_right;
    if (close_visible) {
        const close_hovered = switch (self.hover) {
            .tab_close => |h| h == i,
            else => false,
        };
        const close_pressed = close_hovered and switch (self.pressed) {
            .tab_close => |p| p == i,
            else => false,
        };
        if (close_pressed) {
            canvas.fillRoundedRect(close, style.radius.control, colors.pressed);
        } else if (close_hovered) {
            canvas.fillRoundedRect(close, style.radius.control, colors.hover);
        }
        const close_color = if (close_pressed or close_hovered) colors.on_hover orelse title_color else title_color;
        canvas.drawIcon(glyph.close, close, close_glyph_size, close_color);
        text_right = close.x - 2;
    } else if (status.unread and !active) {
        const d = unread_dot_size;
        canvas.fillRoundedRect(.{
            .x = close.x + (close.w - d) / 2,
            .y = close.y + (close.h - d) / 2,
            .w = d,
            .h = d,
        }, d / 2, colors.accent);
        text_right = close.x - 2;
    }

    // The icon (progress, or what runs) and the status glyphs.
    var x = r.x + tab_pad_x;
    const center_y = r.y + r.h / 2;
    const progress = status.progress;
    if (r.w >= tab_layout.min_width) {
        const icon_rect: d2d.Rect = .{ .x = x, .y = center_y - icon_size / 2, .w = icon_size, .h = icon_size };
        var drew = true;
        if (progress.state != .none) {
            paintProgress(canvas, icon_rect, progress, colors);
        } else switch (self.tabIcon(i)) {
            .none => drew = false,
            .wsl => canvas.drawText("\u{1F427}", icon_rect, .{
                .size = 12,
                .color = title_color,
                .align_x = .center,
                .ellipsis = false,
            }),
            .remote => canvas.drawIcon(glyph.remote, icon_rect, status_glyph_size, title_color),
            .superuser => canvas.drawIcon(glyph.superuser, icon_rect, status_glyph_size, title_color),
            .container => canvas.drawIcon(glyph.container, icon_rect, status_glyph_size, title_color),
        }
        if (drew) x += icon_size + icon_gap;
    }
    for ([_]struct { bool, u21 }{ .{ status.bell, glyph.bell }, .{ status.zoomed, glyph.zoom } }) |mark| {
        if (!mark[0] or text_right - x < status_glyph_size + 16) continue;
        canvas.drawIcon(mark[1], .{ .x = x, .y = center_y - status_glyph_size / 2, .w = status_glyph_size, .h = status_glyph_size }, status_glyph_size, title_color);
        x += status_glyph_size + status_gap;
    }

    if (text_right - x < 4) return;
    var title_buf: [768]u8 = undefined;
    const lbl = self.labelOf(i, &title_buf);
    self.drawLabel(canvas, i, .{ .x = x, .y = r.y, .w = text_right - x, .h = r.h }, lbl, program_color, title_color);
}

/// Draw the complete label with one kept layout and a secondary program run.
fn drawLabel(self: *TabBar, canvas: *d2d.Canvas, i: usize, area: d2d.Rect, lbl: tab_layout.Label, program_color: d2d.Color, title_color: d2d.Color) void {
    var buf: [tabs.max_title_len * 3 + 64]u8 = undefined;
    const text = lbl.write(&buf);
    const layout = self.labels[i].get(canvas.factory, text, area) orelse return;
    const program_len = @import("../ui/wstr.zig").utf16Index(text, @min(lbl.program.len, text.len));
    const runs = [_]d2d.LayoutRun{.{ .start = 0, .len = @intCast(program_len), .color = program_color }};
    canvas.drawLayout(layout, .{ .x = area.x, .y = area.y }, title_color, if (program_len == 0) &.{} else &runs);
}

/// A progress ring in `area`: the share done in the accent (red for an
/// error, the caution color while paused) over a faint track; a quarter
/// ring without a value.
fn paintProgress(canvas: *d2d.Canvas, area: d2d.Rect, progress: tab_status.Progress, colors: *const Colors) void {
    const cx = area.x + area.w / 2;
    const cy = area.y + area.h / 2;
    const r = progress_radius;
    const w = progress_stroke;
    canvas.strokeRoundedRect(.{ .x = cx - r - w / 2, .y = cy - r - w / 2, .w = 2 * r + w, .h = 2 * r + w }, r + w / 2, colors.track, w);
    const color = switch (progress.state) {
        .@"error" => colors.critical,
        .paused => colors.caution,
        else => colors.accent,
    };
    const share: f32 = switch (progress.state) {
        .indeterminate => 0.25,
        else => if (progress.percent) |p| @as(f32, @floatFromInt(p)) / 100 else 0.25,
    };
    strokeArc(canvas, cx, cy, r, if (progress.state == .@"error" and progress.percent == null) 1 else share, color, w);
}

/// Stroke the arc of a circle from the top, clockwise, over `share` of
/// the circle.
fn strokeArc(canvas: *d2d.Canvas, cx: f32, cy: f32, r: f32, share: f32, color: d2d.Color, width: f32) void {
    if (share <= 0) return;
    const At = struct {
        fn point(x0: f32, y0: f32, radius: f32, s: f32) d2d.Point {
            const angle = s * 2 * std.math.pi;
            return .{ .x = x0 + radius * @sin(angle), .y = y0 - radius * @cos(angle) };
        }
    };
    var path = canvas.beginPath(At.point(cx, cy, r, 0), false) orelse return;
    defer path.deinit();
    const end = @min(share, 1);
    if (end > 0.5) {
        path.arcTo(At.point(cx, cy, r, 0.5), r, true);
        path.arcTo(At.point(cx, cy, r, @min(end, 0.9999)), r, true);
    } else {
        path.arcTo(At.point(cx, cy, r, end), r, true);
    }
    path.end(false);
    canvas.strokePath(&path, color, width);
}

/// The active tab: rounded top corners and concave flares at the bottom
/// so it flows into the terminal below. The outline is kept while the tab
/// stays where it is.
fn fillActiveTab(self: *TabBar, canvas: *d2d.Canvas, r: d2d.Rect, pixel: u32) void {
    const key: [4]f32 = .{ r.x, r.y, r.w, r.h };
    if (self.active_path == null or !std.mem.eql(f32, &key, &self.active_path_key)) {
        if (self.active_path) |*old| old.deinit();
        self.active_path = activeOutline(canvas, r);
        self.active_path_key = key;
    }
    if (!canvas.beginReplacement(pixel)) return;
    if (self.active_path) |*path| {
        canvas.fillPath(path, .white);
    } else {
        canvas.fillRoundedRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h + tab_radius }, tab_radius, .white);
    }
    canvas.endReplacement();
}

fn activeOutline(canvas: *d2d.Canvas, r: d2d.Rect) ?d2d.Path {
    const x0 = r.x;
    const x1 = r.x + r.w;
    const y0 = r.y;
    const y1 = r.y + r.h;
    const rad = tab_radius;
    const f = tab_flare;
    var path = canvas.beginPath(.{ .x = x0 - f, .y = y1 }, true) orelse return null;
    path.arcTo(.{ .x = x0, .y = y1 - f }, f, false);
    path.lineTo(.{ .x = x0, .y = y0 + rad });
    path.arcTo(.{ .x = x0 + rad, .y = y0 }, rad, true);
    path.lineTo(.{ .x = x1 - rad, .y = y0 });
    path.arcTo(.{ .x = x1, .y = y0 + rad }, rad, true);
    path.lineTo(.{ .x = x1, .y = y1 - f });
    path.arcTo(.{ .x = x1 + f, .y = y1 }, f, false);
    path.end(true);
    return path;
}

fn paintRowButton(
    self: *TabBar,
    ctx: TitleBar.PaintContext,
    colors: *const Colors,
    r_px: tab_layout.Rect,
    part: Part,
    icon: u21,
    size: f32,
    enabled: bool,
) void {
    if (r_px.isEmpty()) return;
    const r = ctx.dipRect(rect(r_px));
    const radius = style.radius.control;
    var color = if (enabled) colors.glyph else colors.glyph_disabled;
    if (enabled and (self.pressed.eql(part) or self.hover.eql(part))) {
        ctx.canvas.fillRoundedRect(r, radius, if (self.pressed.eql(part)) colors.pressed else colors.hover);
        if (colors.on_hover) |on_hover| color = on_hover;
    }
    ctx.canvas.drawIcon(icon, r, size, color);
}

/// The window title in the title bar while the tabs are hidden
/// (`window-show-tab-bar = never`, herdr app mode).
fn paintWindowTitle(self: *TabBar, ctx: TitleBar.PaintContext) void {
    const hwnd = self.window().hwnd orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(@max(0, w32.GetWindowTextW(hwnd, &wbuf, wbuf.len)));
    var buf: [768]u8 = undefined;
    const title = utf16ToUtf8(&buf, wbuf[0..wlen]);
    const area = ctx.dipRect(ctx.layout.tabs);
    const top = ctx.dipRect(ctx.layout.bar);
    const colors = self.colorsFor(ctx);
    ctx.canvas.drawText(title, .{ .x = area.x + 4, .y = top.y, .w = area.w - 4, .h = top.h }, .{
        .size = title_font_size,
        .color = if (ctx.active) colors.hover_text else colors.text,
    });
}

const Icon = enum { none, wsl, remote, superuser, container };

fn tabIcon(self: *const TabBar, i: usize) Icon {
    const entry = self.processFor(i) orelse return .none;
    return switch (entry.kind) {
        .remote => .remote,
        .superuser => .superuser,
        .container => .container,
        .local => if (entry.wsl) .wsl else .none,
    };
}

fn isElevated(self: *TabBar) bool {
    if (self.elevated) |value| return value;
    const value = processElevated();
    self.elevated = value;
    return value;
}

/// The label of tab `i` (`tab_layout.label`); its title is written into
/// `buf`.
fn labelOf(self: *const TabBar, i: usize, buf: []u8) tab_layout.Label {
    const win = self.windowConst();
    const title = utf16ToUtf8(buf, win.tab_titles[i][0..win.tab_title_lens[i]]);
    const entry = self.processFor(i);
    const program: ?tab_layout.Program = if (entry) |e| .{ .name = e.name(), .idle = e.idle, .wsl = e.wsl, .shell = e.shell() } else null;
    return tab_layout.label(win.tab_title_overrides[i] != null, title, "Ghostty", program);
}

/// The label tab `i` shows, as one line in `buf` (`program · title`), or
/// null past the last tab: for lists of the tabs such as
/// `Menu.showTabList`.
pub fn labelText(self: *const TabBar, i: usize, buf: []u8) ?[]const u8 {
    if (i >= self.windowConst().tab_count) return null;
    var title_buf: [768]u8 = undefined;
    return self.labelOf(i, &title_buf).write(buf);
}

/// The tooltip of tab `i`: its full label, and the shortcut that selects
/// it when one is bound.
pub fn tooltipText(self: *const TabBar, i: usize, buf: []u8) ?[]const u8 {
    var label_buf: [600]u8 = undefined;
    const text = self.labelText(i, &label_buf) orelse return null;
    if (text.len == 0) return null;
    return withShortcut(buf, text, self.shortcut(.{ .goto_tab = i + 1 }));
}

/// What a tooltip of the tab bar says and where it points (client
/// pixels).
pub const Tip = struct {
    text: []const u8,
    anchor: w32.RECT,
};

/// The tooltip of a part of the tab bar, with the shortcut of its action:
/// for `TitleBar.showTooltip` to show for the tab bar targets.
pub fn tooltip(self: *const TabBar, target: TitleBar.TooltipTarget, lay: TitleBar.Layout, buf: []u8) ?Tip {
    const i18n = gx.i18n;
    return switch (target) {
        .new_tab => .{ .text = withShortcut(buf, i18n.tr("New tab"), self.shortcut(.new_tab)), .anchor = self.new_tab_rect },
        .profiles => .{ .text = withShortcut(buf, i18n.tr("New Tab with Profile"), null), .anchor = self.profile_rect },
        .tab_close => |i| .{ .text = withShortcut(buf, i18n.tr("Close tab"), self.shortcut(.{ .close_tab = .this })), .anchor = self.closeRect(lay, i) },
        .tab => |i| .{ .text = self.tooltipText(i, buf) orelse return null, .anchor = self.tabRect(i) },
        else => null,
    };
}

/// The shortcut text of `action` (the hints of the menus: blocked keys
/// left out), or null.
fn shortcut(self: *const TabBar, action: input.Binding.Action) ?Shortcut {
    const app = self.windowConst().app;
    const hints: trigger.Hints = .{ .set = &app.config.keybind.set, .blocked = &app.shortcut_conflicts };
    var out: Shortcut = .{};
    const text = hints.text(action, &out.buf) orelse return null;
    out.len = text.len;
    return out;
}

const Shortcut = struct {
    buf: [48]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Shortcut) []const u8 {
        return self.buf[0..self.len];
    }
};

/// `text`, followed by ` (Ctrl+Shift+T)` when there is a shortcut, in
/// `buf`.
fn withShortcut(buf: []u8, text: []const u8, keys: ?Shortcut) []const u8 {
    const kept = tab_layout.utf8Prefix(text, buf.len);
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(kept) catch unreachable;
    if (kept.len == text.len) {
        if (keys) |k| {
            var key_buf: [64]u8 = undefined;
            const suffix = std.fmt.bufPrint(&key_buf, " ({s})", .{k.text()}) catch return writer.buffered();
            writer.writeAll(tab_layout.utf8Prefix(suffix, buf.len - kept.len)) catch unreachable;
        }
    }
    return writer.buffered();
}

fn utf16ToUtf8(buf: []u8, units: []const u16) []const u8 {
    var used: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(units);
    while (true) {
        const cp = it.nextCodepoint() catch 0xFFFD orelse break;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (len > buf.len - used) break;
        @memcpy(buf[used..][0..len], tmp[0..len]);
        used += len;
    }
    return buf[0..used];
}

// -----------------------------------------------------------------------
// Mouse input
// -----------------------------------------------------------------------

/// Handle mouse movement (client coordinates): moves a dragged tab and
/// updates the hover state otherwise. Returns true when a drag consumed
/// the movement.
pub fn onMouseMove(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    if (self.drag) |*d| {
        const win = self.window();
        const gesture = @import("../tab_transfer.zig").gesture(x - d.press_x, y - d.press_y, lay.scale);
        if (gesture == .detach and !win.is_quick_terminal and d.tab < win.tab_count) {
            const reference = d.reference;
            const app = win.app;
            const owner = win.ui_reference;
            var point: w32.POINT = .{ .x = x, .y = y };
            if (win.hwnd) |hwnd| _ = w32.ClientToScreen(hwnd, &point);
            // Release capture only after clearing drag state; WM_CAPTURECHANGED
            // must not cancel the already queued detach request.
            self.cancelDrag();
            if (app.resolveWindow(owner)) |live| _ = live.queueTabDetach(reference, point);
            return true;
        }
        if (!d.active and gesture == .reorder) {
            d.active = true;
            win.title_bar.setTabTooltipTarget(.none);
            if (win.hwnd) |hwnd| escape_hook.acquire(hwnd);
        }
        if (d.active and win.tab_count > 1) {
            d.x = x;
            const g = self.geometry(lay);
            const left = std.math.clamp(x - d.grab - g.view_left + g.scroll_px, 0, @max(0, g.content_w - g.width(d.tab)));
            const target = tab_layout.dragTarget(left, g.tab_w, g.count);
            if (target != d.target) {
                self.beginSlide(&g);
                self.drag.?.target = target;
                self.startSlide();
            }
            self.invalidate();
        }
        return true;
    }

    self.trackLeave();
    const g = self.geometry(lay);
    const part = self.partAt(&g, x, y);
    if (part == .none) self.unfreeze();
    self.setHover(part);
    return false;
}

/// Current geometry only: reject buttons, close glyphs and hidden tab strips.
pub fn transferSlotAt(self: *TabBar, point: w32.POINT) ?usize {
    if (!self.visible) return null;
    const g = self.geometry(self.window().title_bar.layout());
    const index = switch (self.partAt(&g, point.x, point.y)) {
        .tab => |index| index,
        else => return null,
    };
    const tab_rect = g.tabRect(index);
    return index + @as(usize, if (point.x >= tab_rect.left + @divTrunc(tab_rect.right - tab_rect.left, 2)) 1 else 0);
}

/// Ask for WM_MOUSELEAVE on the client area of the window, which the tab
/// bar shares with the client buttons of the title bar (`TitleBar.onSize`
/// asks for one when a resize put a button under the pointer).
pub fn trackLeave(self: *TabBar) void {
    if (self.tracking_mouse) return;
    const hwnd = self.window().hwnd orelse return;
    var tme = w32.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
        .dwFlags = w32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (w32.TrackMouseEvent(&tme) != 0) self.tracking_mouse = true;
}

fn setHover(self: *TabBar, part: Part) void {
    if (part.eql(self.hover)) return;
    self.hover = part;
    self.invalidate();
    self.window().title_bar.setTabTooltipTarget(switch (part) {
        .none, .scroll_back, .scroll_forward, .tab_list => .none,
        .tab => |i| .{ .tab = i },
        .tab_close => |i| .{ .tab_close = i },
        .new_tab => .new_tab,
        .profiles => .profiles,
    });
}

/// The pointer left the tabs: let the widths follow the tab count again.
fn unfreeze(self: *TabBar) void {
    if (self.frozen == null) return;
    self.frozen = null;
    self.invalidate();
}

/// Handle WM_MOUSELEAVE: reset the hover state and repaint.
pub fn onMouseLeave(self: *TabBar) void {
    self.middle_press.cancel();
    self.tracking_mouse = false;
    if (self.drag == null) {
        self.setHover(.none);
        self.unfreeze();
    }
}

/// Whether a left press or a drag on the tab bar holds the mouse capture:
/// the title bar buttons do not react to the pointer meanwhile.
pub fn holdsPress(self: *const TabBar) bool {
    return self.drag != null or self.pressed != .none;
}

/// A left-button press on the tab bar: select (and start tracking a
/// potential drag of) a tab, or press a button.
pub fn onLeftButtonDown(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) void {
    const g = self.geometry(lay);
    self.press(lay, self.partAt(&g, x, y), x, y);
}

fn press(self: *TabBar, lay: TitleBar.Layout, part: Part, x: i32, y: i32) void {
    const win = self.window();
    switch (part) {
        .none => return,
        .tab => |i| {
            // Selecting it can scroll it into view and widen it.
            win.selectTabIndex(i);
            if (self.reveal_pending) {
                self.reveal_pending = false;
                const g0 = self.geometry(lay);
                if (g0.overflow) self.scroll = g0.revealScroll(i);
            }
            const g = self.geometry(lay);
            if (i >= g.count) return;
            self.drag = .{ .tab = i, .reference = win.tab_references[i], .press_x = x, .press_y = y, .grab = x - g.tabRect(i).left, .x = x, .target = i };
        },
        .scroll_back, .scroll_forward => {
            self.pressed = part;
            self.scrollStep(lay, part);
            self.startScrollRepeat();
        },
        .tab_close, .new_tab, .profiles, .tab_list => self.pressed = part,
    }
    if (win.hwnd) |h| _ = w32.SetCapture(h);
    self.invalidate();
}

fn scrollStep(self: *TabBar, lay: TitleBar.Layout, part: Part) void {
    const step = tab_layout.scroll_step;
    self.scrollBy(lay, if (part == .scroll_back) -step else step);
}

/// A left-button release; performs a pressed button when released over
/// it and drops a dragged tab. Returns true when the tab bar handled it.
pub fn onLeftButtonUp(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const win = self.window();
    if (self.drag != null) {
        self.drop(lay);
        return true;
    }
    const pressed = self.pressed;
    if (pressed == .none) return false;
    self.pressed = .none;
    self.stopScrollRepeat();
    if (win.hwnd) |h| {
        if (w32.GetCapture() == h) _ = w32.ReleaseCapture();
    }
    self.invalidate();
    const g = self.geometry(lay);
    if (!self.partAt(&g, x, y).eql(pressed)) return true;
    switch (pressed) {
        .none, .tab, .scroll_back, .scroll_forward => {},
        .tab_close => |i| {
            self.frozen = tab_layout.freeze(&g, lay.tabs.right - lay.tabs.left);
            win.closeTabByIndex(i);
        },
        .new_tab => _ = win.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .profiles => self.openProfileMenu(),
        .tab_list => self.openTabList(),
    }
    return true;
}

/// End a press or drag of a tab: a dragged tab moves to the slot it was
/// dropped on and slides into place.
fn drop(self: *TabBar, lay: TitleBar.Layout) void {
    const win = self.window();
    const d = self.drag orelse return;
    escape_hook.release();
    if (!d.active) {
        self.drag = null;
        self.releaseCapture();
        return;
    }
    const g = self.geometry(lay);
    // Where every tab shows now, by its index after the move.
    var shown: [max_tabs]i32 = undefined;
    const now = anim.now();
    for (0..g.count) |i| shown[i] = self.displayedContentLeft(&g, i, now);
    self.drag = null;
    if (d.target != d.tab and d.tab < g.count) {
        for (0..g.count) |i| self.slide_from[tab_layout.displayIndex(i, d.tab, d.target)] = shown[i];
        win.moveTabTo(d.tab, d.target);
    } else {
        for (0..g.count) |i| self.slide_from[i] = shown[i];
    }
    self.startSlide();
    self.releaseCapture();
    self.invalidate();
}

/// Put a dragged tab back where it was, sliding.
fn cancelDragAnimated(self: *TabBar) void {
    const d = self.drag orelse return;
    escape_hook.release();
    if (d.active) {
        const g = self.geometry(self.window().title_bar.layout());
        self.beginSlide(&g);
        self.drag = null;
        self.startSlide();
    } else {
        self.drag = null;
    }
    self.invalidate();
}

/// Remember where the tabs show now (`slide_from`), before what decides
/// their places changes; `startSlide` then moves them from there.
fn beginSlide(self: *TabBar, g: *const tab_layout.Layout) void {
    const now = anim.now();
    for (0..g.count) |i| self.slide_from[i] = self.displayedContentLeft(g, i, now);
}

fn startSlide(self: *TabBar) void {
    if (!anim.enabled()) {
        self.sliding = false;
        return;
    }
    self.slide = anim.Tween.begin(anim.now(), anim.motion.duration.fast, anim.motion.ease);
    self.sliding = true;
    if (!anim.start(&self.animator)) self.sliding = false;
}

fn slideTick(animator: *anim.Animator, now: u64) bool {
    const self: *TabBar = @alignCast(@fieldParentPtr("animator", animator));
    self.invalidate();
    if (self.slide.done(now)) {
        self.sliding = false;
        return false;
    }
    return true;
}

fn releaseCapture(self: *TabBar) void {
    const hwnd = self.window().hwnd orelse return;
    if (w32.GetCapture() == hwnd) _ = w32.ReleaseCapture();
}

fn openProfileMenu(self: *TabBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    var anchor = w32.POINT{ .x = self.new_tab_rect.left, .y = self.new_tab_rect.bottom };
    _ = w32.ClientToScreen(hwnd, &anchor);
    win.title_bar.tooltip.hide();
    Menu.showProfileMenu(win, anchor);
}

/// The menu of all tabs, below the list button.
fn openTabList(self: *TabBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    const g = self.geometry(win.title_bar.layout());
    if (g.list.isEmpty()) return;
    var top_left = w32.POINT{ .x = g.list.left, .y = g.list.top };
    var bottom_right = w32.POINT{ .x = g.list.right, .y = g.bottom };
    _ = w32.ClientToScreen(hwnd, &top_left);
    _ = w32.ClientToScreen(hwnd, &bottom_right);
    win.title_bar.tooltip.hide();
    Menu.showTabList(win, .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y });
}

/// The mouse capture went elsewhere: put a dragged tab back and forget
/// presses.
pub fn onCaptureLost(self: *TabBar) void {
    self.middle_press.cancel();
    self.stopScrollRepeat();
    if (self.drag != null) self.cancelDragAnimated();
    if (self.pressed == .none) return;
    self.pressed = .none;
    self.invalidate();
}

/// Stop tracking a tab press or drag at once (the tabs change) and
/// release the mouse capture.
pub fn cancelDrag(self: *TabBar) void {
    if (self.drag == null) return;
    escape_hook.release();
    self.drag = null;
    anim.stop(&self.animator);
    self.sliding = false;
    self.releaseCapture();
}

/// Handle a double click on the tab bar: rename the tab under the cursor,
/// treat the new-tab button like a second click and the other buttons
/// like a press (closing tabs one after the other, scrolling).
pub fn onDoubleClick(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    const part = self.partAt(&g, x, y);
    switch (part) {
        .tab => |i| self.startRename(i),
        .new_tab => _ = self.window().addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .none => return false,
        .tab_close, .profiles, .tab_list, .scroll_back, .scroll_forward => self.press(lay, part, x, y),
    }
    return true;
}

/// A middle-button press, paired by pane generation rather than a movable slot.
pub fn onMiddleButtonDown(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    const target = self.middleTarget(self.partAt(&g, x, y));
    self.beginMiddlePress(target);
    return target != null;
}

fn beginMiddlePress(self: *TabBar, target: ?u64) void {
    self.middle_press.down(target);
    if (target != null) {
        self.clearMiddleTooltip();
        self.trackLeave();
    }
}

fn releaseMiddlePress(self: *TabBar, target: ?u64) bool {
    const matched = self.middle_press.release(target);
    // Movement during a long press may have rearmed the tooltip.
    if (matched) self.clearMiddleTooltip();
    return matched;
}

fn clearMiddleTooltip(self: *TabBar) void {
    // The slot may name another tab after close: force the next move
    // to establish a fresh hover target even when its index is equal.
    self.window().title_bar.tooltip.hide();
    self.hover = .none;
    self.invalidate();
}

fn middleTarget(self: *const TabBar, part: Part) ?u64 {
    const i = switch (part) {
        .tab, .tab_close => |i| i,
        else => return null,
    };
    const win = self.windowConst();
    const pane = win.paneAtTab(i) orelse return null;
    if (!pane.initialized()) return null;
    const reference = pane.reference();
    // Issuer generations never repeat within this window's host lifetime.
    return if (reference.isValid()) reference.generation else null;
}

/// A release consumes its press, including one outside a tab. Missing or
/// mismatched presses never close a tab.
pub fn onMiddleButtonUp(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const g = self.geometry(lay);
    const part = self.partAt(&g, x, y);
    const matched = self.releaseMiddlePress(self.middleTarget(part));
    const i = switch (part) {
        .tab, .tab_close => |i| i,
        .none => return false,
        else => return true,
    };
    if (!matched) return true;
    self.frozen = tab_layout.freeze(&g, lay.tabs.right - lay.tabs.left);
    self.window().closeTabByIndex(i);
    return true;
}

/// The mouse wheel turned over the chrome row (client point `x`, `y`):
/// `delta` is the wheel distance (`WHEEL_DELTA` per notch, positive away
/// from the user, or to the right when `horizontal`). Scrolls the tabs
/// when they do not fit; returns whether it did.
pub fn onMouseWheel(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32, delta: i16, horizontal: bool) bool {
    _ = x;
    _ = y;
    const g = self.geometry(lay);
    if (!g.overflow) return false;
    const notches = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(w32.WHEEL_DELTA));
    self.scrollBy(lay, if (horizontal) notches * tab_layout.scroll_step else -notches * tab_layout.scroll_step);
    return true;
}

/// Handle a right-button release on the tab bar: the launch profile menu
/// over the new-tab buttons, else the tab context menu for the clicked
/// tab. Returns false when the point is not on a tab or button.
pub fn onRightButtonUp(self: *TabBar, lay: TitleBar.Layout, x: i32, y: i32) bool {
    const win = self.window();
    const hwnd = win.hwnd orelse return false;
    const g = self.geometry(lay);
    const part = self.partAt(&g, x, y);
    const clicked_tab: usize = switch (part) {
        .none => return false,
        .new_tab, .profiles => {
            self.openProfileMenu();
            return true;
        },
        .scroll_back, .scroll_forward, .tab_list => {
            self.openTabList();
            return true;
        },
        .tab, .tab_close => |i| i,
    };
    win.title_bar.tooltip.hide();

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);

    // A modal callback can close or move either object. Retain identities,
    // never a borrowed tab, window, or terminal pointer across it.
    const app = win.app;
    const owner = win.ui_reference;
    const tab = win.tab_references[clicked_tab];
    const command = Menu.showTabContextMenu(win, pt, clicked_tab) orelse return true;
    const live = app.resolveWindow(owner) orelse return true;
    Menu.performTabCommand(live, tab, command);
    return true;
}

// -----------------------------------------------------------------------
// Held scroll buttons
// -----------------------------------------------------------------------

fn startScrollRepeat(self: *TabBar) void {
    const hwnd = self.window().hwnd orelse return;
    var setting: u32 = 1;
    if (SystemParametersInfoW(SPI_GETKEYBOARDDELAY, 0, @ptrCast(&setting), 0) == 0) setting = 1;
    _ = w32.SetTimer(hwnd, SCROLL_TIMER_ID, Popup.repeatDelayMs(setting), @ptrCast(&scrollTimer));
}

fn stopScrollRepeat(self: *TabBar) void {
    const hwnd = self.window().hwnd orelse return;
    _ = w32.KillTimer(hwnd, SCROLL_TIMER_ID);
}

fn scrollTimer(hwnd: w32.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) {
        _ = w32.KillTimer(hwnd, id);
        return;
    }
    const win: *Window = @ptrFromInt(@as(usize, @bitCast(userdata)));
    win.tab_bar.onScrollRepeat(hwnd);
}

/// A held scroll button scrolls again, at the keyboard repeat rate.
fn onScrollRepeat(self: *TabBar, hwnd: w32.HWND) void {
    const part = self.pressed;
    if (part != .scroll_back and part != .scroll_forward) {
        _ = w32.KillTimer(hwnd, SCROLL_TIMER_ID);
        return;
    }
    var speed: u32 = 31;
    if (SystemParametersInfoW(SPI_GETKEYBOARDSPEED, 0, @ptrCast(&speed), 0) == 0) speed = 31;
    _ = w32.SetTimer(hwnd, SCROLL_TIMER_ID, Popup.repeatIntervalMs(speed), @ptrCast(&scrollTimer));
    var cursor: w32.POINT = undefined;
    if (w32.GetCursorPos_(&cursor) == 0) return;
    _ = w32.ScreenToClient(hwnd, &cursor);
    const lay = self.window().title_bar.layout();
    const g = self.geometry(lay);
    if (!self.partAt(&g, cursor.x, cursor.y).eql(part)) return;
    self.scrollStep(lay, part);
}

// -----------------------------------------------------------------------
// Escape while dragging
// -----------------------------------------------------------------------

/// While a tab is dragged the terminal keeps the keyboard focus, so a
/// keyboard hook of the GUI thread takes Escape: it cancels the drag
/// (`WM_CANCELMODE` releases the capture, `onCaptureLost` puts the tab
/// back) and never reaches the terminal, its repeats and release neither.
/// The hook goes once the drag ended and Escape is up (`collect`).
const escape_hook = struct {
    var hook: ?*anyopaque = null;
    /// The window of the drag, while there is one.
    var target: ?w32.HWND = null;
    /// Escape went down during the drag: take its repeats and release.
    var held = false;

    fn acquire(hwnd: w32.HWND) void {
        target = hwnd;
        if (hook != null) return;
        hook = SetWindowsHookExW(WH_KEYBOARD, @ptrCast(&proc), null, GetCurrentThreadId());
        if (hook == null) log.warn("cannot watch Escape while dragging a tab", .{});
    }

    fn release() void {
        target = null;
        collect();
    }

    /// Remove the hook unless a drag or a held Escape still needs it.
    fn collect() void {
        if (target != null or held) return;
        const h = hook orelse return;
        hook = null;
        _ = UnhookWindowsHookEx(h);
    }

    fn proc(code: i32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        if (code >= 0 and wparam == w32.VK_ESCAPE) {
            const flags: usize = @bitCast(lparam);
            const up = (flags >> 31) & 1 != 0;
            const repeat = (flags >> 30) & 1 != 0;
            if (!up and target != null) {
                held = true;
                _ = w32.PostMessageW(target.?, WM_CANCELMODE, 0, 0);
                return 1;
            }
            if (held and (up or repeat)) {
                if (up) held = false;
                return 1;
            }
        }
        return CallNextHookEx(null, code, wparam, lparam);
    }
};

// -----------------------------------------------------------------------
// Status: new output, bell, programs
// -----------------------------------------------------------------------

/// Poll visible tabs; inactive windows check content and programs every
/// five seconds, but stale progress always clears on the next tick.
pub fn onTimer(self: *TabBar) void {
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    if (w32.IsWindowVisible_(hwnd) == 0 or IsIconic(hwnd) != 0) return;
    self.ticks +%= 1;
    escape_hook.collect();
    var changed = false;
    if (self.polling.unreadDue(GetTickCount64(), win.title_bar.active, self.visible, win.tab_count)) changed = self.checkUnread();
    if (self.visible) {
        refreshProgramsOfApp(win.app);
        for (0..@min(win.tab_count, max_tabs)) |i| {
            if (!std.meta.eql(StatusKey.of(win.tabStatus(i)), self.painted_status[i])) changed = true;
        }
    }
    if (self.ticks % 16 == 0) self.pruneTrackers();
    if (changed) self.invalidate();
}

/// Mark background tabs with new output (`gx.unread.Tracker.check`). A
/// hidden terminal without a tracker (its tab was hidden before it was
/// ready, or the tracker was dropped) gets a baseline instead, taken only
/// when its lock is free. Returns true when a tab got marked.
fn checkUnread(self: *TabBar) bool {
    const win = self.window();
    const io = global.io();
    const span: ?gx.perf.Span = if (gx.perf.enabled()) .begin(io) else null;
    defer if (span) |s| {
        _ = s.end(io, "tabs.unread_check");
    };
    var changed = false;
    for (0..win.tab_count) |i| {
        if (i == win.active_tab or win.tab_unread[i]) continue;
        var it = win.paneIterator(i);
        while (it.next()) |pane| {
            if (!pane.ready() or !pane.reference().isValid()) continue;
            const reference = pane.reference();
            const tracker = self.findTracker(reference) orelse {
                var baseline: Pane.UnreadTracker = .{};
                if (pane.captureUnread(&baseline, io)) self.trackerOf(reference).unread = baseline;
                continue;
            };
            if (pane.checkUnread(&tracker.unread, io)) {
                win.tab_unread[i] = true;
                changed = true;
                break;
            }
        }
    }
    return changed;
}

/// The bell rang in the terminal `surface` (`Window.onBell`): mark its tab
/// with the bell (`Window.ringTab`) unless it is the active tab.
pub fn markUnread(self: *TabBar, surface: anytype) void {
    self.window().ringTab(surface);
}

/// Tab `tab` stopped being shown (`Window.selectTabIndex` hid its panes):
/// remember what its terminals show, so only output after this counts as
/// new (`gx.unread.Tracker`). GUI thread.
pub fn onTabHidden(self: *TabBar, tab: usize) void {
    const win = self.window();
    if (tab >= win.tab_count) return;
    var it = win.paneIterator(tab);
    while (it.next()) |pane| {
        if (!pane.ready() or !pane.reference().isValid()) continue;
        pane.hideUnread(&self.trackerOf(pane.reference()).unread, global.io());
    }
}

/// Tab `tab` became the active tab (`Window.selectTabIndex`): its
/// terminals draw again, and it scrolls into view. GUI thread.
pub fn onTabShown(self: *TabBar, tab: usize) void {
    const win = self.window();
    if (tab >= win.tab_count) return;
    var it = win.paneIterator(tab);
    while (it.next()) |pane| {
        if (!pane.initialized()) continue;
        if (self.findTracker(pane.reference())) |tracker| tracker.unread.show();
    }
    self.reveal_pending = true;
}

fn findTracker(self: *TabBar, reference: PaneSnapshot.Reference) ?*Tracked {
    for (self.tracked[0..self.tracked_len]) |*entry| {
        if (entry.reference.matches(reference)) return entry;
    }
    return null;
}

/// The tracker of the pane with value identity `reference`, added when it
/// has none.
fn trackerOf(self: *TabBar, reference: PaneSnapshot.Reference) *Tracked {
    if (self.findTracker(reference)) |tracker| return tracker;
    if (self.tracked_len == max_tracked) self.pruneTrackers();
    if (self.tracked_len == max_tracked) {
        // Full of live terminals: reuse the oldest entry.
        std.mem.copyForwards(Tracked, self.tracked[0 .. max_tracked - 1], self.tracked[1..max_tracked]);
        self.tracked_len -= 1;
    }
    self.tracked[self.tracked_len] = .{ .reference = reference };
    self.tracked_len += 1;
    return &self.tracked[self.tracked_len - 1];
}

/// Forget the trackers of terminals that are gone.
fn pruneTrackers(self: *TabBar) void {
    const win = self.window();
    var kept: usize = 0;
    for (self.tracked[0..self.tracked_len]) |entry| {
        if (!liveTerminal(win, entry.reference)) continue;
        self.tracked[kept] = entry;
        kept += 1;
    }
    self.tracked_len = kept;
}

fn liveTerminal(win: *Window, reference: PaneSnapshot.Reference) bool {
    const pane = win.lookupPane(reference) orelse return false;
    return pane.initialized();
}

fn processFor(self: *const TabBar, i: usize) ?*const ProcessName {
    const win = self.windowConst();
    const pane = win.paneAtTab(i) orelse return null;
    for (&self.processes) |*entry| {
        if (entry.pane.matches(pane.reference()) and entry.len > 0) return entry;
    }
    return null;
}

/// How often the programs are looked up.
const programs_period_ms: u64 = 2000;

/// A single lookup shared by all windows, at least two seconds apart.
var programs_last_refresh_ms: ?u64 = null;

fn programsDue(win: *Window, now: u64) bool {
    const hwnd = win.hwnd orelse return false;
    return win.tab_bar.visible and w32.IsWindowVisible_(hwnd) != 0 and IsIconic(hwnd) == 0 and
        win.tab_bar.polling.programsDue(now, win.title_bar.active);
}

fn refreshProgramsOfApp(app: *App) void {
    const now = GetTickCount64();
    if (!tab_layout.due(programs_last_refresh_ms, now, programs_period_ms)) return;
    var needed = false;
    for (app.windows.items) |win| {
        if (programsDue(win, now)) {
            needed = true;
            break;
        }
    }
    if (!needed) return;
    programs_last_refresh_ms = now;
    const span: ?gx.perf.Span = if (gx.perf.enabled()) .begin(global.io()) else null;
    defer if (span) |s| {
        _ = s.end(global.io(), "tabs.process_poll");
    };
    const table = app.processTable() catch |err| {
        log.debug("cannot list the processes for the tab labels err={}", .{err});
        return;
    };
    for (app.windows.items) |win| {
        if (!programsDue(win, now)) continue;
        win.tab_bar.polling.programs_ms = now;
        if (win.tab_bar.refreshPrograms(table)) win.tab_bar.invalidate();
    }
}

/// Look up what runs in every tab's focused terminal in `table`. Returns
/// true when a label or icon changed.
fn refreshPrograms(self: *TabBar, table: *gx.proc.Table) bool {
    const win = self.window();
    const count = @min(win.tab_count, max_tabs);
    var next: [max_tabs]ProcessName = [_]ProcessName{.{}} ** max_tabs;
    var roots: [max_tabs]?gx.proc.Pid = [_]?gx.proc.Pid{null} ** max_tabs;
    var pids: [max_tabs]gx.proc.Pid = undefined;
    var pid_count: usize = 0;
    for (0..count) |i| {
        const pane = win.paneAtTab(i) orelse continue;
        next[i].pane = pane.reference();
        const pid = pane.foregroundPid() orelse continue;
        roots[i] = pid;
        pids[pid_count] = pid;
        pid_count += 1;
    }
    if (pid_count > 0) {
        var arena: std.heap.ArenaAllocator = .init(win.app.core_app.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const idle_list = win.app.config.@"gx-idle-processes".list.items;
        if (table.tree(alloc, pids[0..pid_count])) |tree| {
            for (roots[0..count], next[0..count]) |root, *entry| {
                const pid = root orelse continue;
                const program = (tree.program(alloc, pid) catch null) orelse continue;
                const name = tab_layout.utf8Prefix(program.name, entry.buf.len);
                @memcpy(entry.buf[0..name.len], name);
                entry.len = @intCast(name.len);
                entry.wsl = program.wsl;
                entry.idle = gx.policy.isIdle(&.{program.name}, idle_list);
                entry.kind = gx.leader.treeKind(alloc, tree, pid) catch .local;
                if (tree.find(pid)) |index| {
                    const shell = tab_layout.utf8Prefix(gx.policy.displayName(tree.processes[index].name), entry.shell_buf.len);
                    @memcpy(entry.shell_buf[0..shell.len], shell);
                    entry.shell_len = @intCast(shell.len);
                }
            }
        } else |_| {}
    }
    var changed = false;
    for (0..max_tabs) |i| {
        if (!self.processes[i].eql(&next[i])) changed = true;
    }
    self.processes = next;
    return changed;
}

// -----------------------------------------------------------------------
// Inline rename
// -----------------------------------------------------------------------

/// Whether `hwnd` is the inline rename field (the popup or the Edit
/// control), whose Enter, Escape and keybindings the app's message loop
/// routes (`App.routeEditKey`: `finishRename`, `cancelRename`).
pub fn isRenameEdit(self: *const TabBar, hwnd: ?w32.HWND) bool {
    const h = hwnd orelse return false;
    if (self.rename_edit) |edit| {
        if (h == edit) return true;
    }
    if (self.rename_target == .none) return false;
    const popup = self.rename_popup.hwnd orelse return false;
    return h == popup;
}

/// Rename tab `tab_idx` (its title override) in a text field over the tab,
/// filled with the title it shows. Enter or a click elsewhere keeps the
/// text (an empty one removes the override), Escape cancels. The field is
/// a popup that shows from the message loop, so this may run in a core
/// callback; without Direct2D it is an Edit control.
pub fn startRename(self: *TabBar, tab_idx: usize) void {
    self.beginRename(.{ .tab = tab_idx });
}

/// Rename the window (its title override) the same way, in a field over
/// the active tab or where the window title shows.
pub fn startWindowRename(self: *TabBar) void {
    self.beginRename(.window);
}

/// The rename popup posts it to itself to show from the message loop.
const WM_SHOW_RENAME: u32 = w32.WM_APP + 1;

/// The narrowest the rename field gets.
const rename_min_width: f32 = 200;

fn beginRename(self: *TabBar, target: RenameTarget) void {
    self.cancelRename();
    const win = self.window();
    const hwnd = win.hwnd orelse return;
    switch (target) {
        .none => return,
        .tab => |i| if (i >= win.tab_count) return,
        .window => if (win.tab_count == 0) return,
    }
    var title_buf: [tabs.max_title_len + 1]u16 = undefined;
    const title = self.renameTitle(target, &title_buf);
    if (win.app.uiFactory()) |factory| {
        if (self.showRenamePopup(factory, hwnd, target, title)) return;
    }
    self.startRenameEdit(hwnd, target, title);
}

/// The text a rename starts with: the tab's title, or the window's (its
/// override, else the title it shows).
fn renameTitle(self: *TabBar, target: RenameTarget, buf: *[tabs.max_title_len + 1]u16) []const u16 {
    const win = self.window();
    switch (target) {
        .none => return buf[0..0],
        .tab => |i| {
            const len = win.tab_title_lens[i];
            @memcpy(buf[0..len], win.tab_titles[i][0..len]);
            return buf[0..len];
        },
        .window => {
            if (win.window_title_override_len) |len| {
                @memcpy(buf[0..len], win.window_title_override[0..len]);
                return buf[0..len];
            }
            const hwnd = win.hwnd orelse return buf[0..0];
            const len: usize = @intCast(@max(0, w32.GetWindowTextW(hwnd, buf, buf.len)));
            return buf[0..@min(len, tabs.max_title_len)];
        },
    }
}

/// Where the rename field goes (client pixels), `height` DIPs high: over
/// the tab (scrolled into view) or the active tab, at least
/// `rename_min_width` wide and inside the window, else where the window
/// title shows.
fn renameRect(self: *TabBar, hwnd: w32.HWND, target: RenameTarget, height: f32) ?w32.RECT {
    const win = self.window();
    const s = win.scale;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return null;
    const lay = win.title_bar.layout();
    const h = style.px(height, s);
    const min_w = style.px(rename_min_width, s);
    const margin = style.px(8, s);
    const tab_idx: usize = switch (target) {
        .none => return null,
        .tab => |i| i,
        .window => win.active_tab,
    };
    if (self.visible) {
        var g = self.geometry(lay);
        if (g.overflow) {
            self.scroll = g.revealScroll(tab_idx);
            self.reveal_pending = false;
            g = self.geometry(lay);
            self.invalidate();
        }
        if (tab_idx < g.count) {
            const tab = g.tabRect(tab_idx);
            const inset = style.px(4, s);
            const w = @max(tab.width() - 2 * inset, min_w);
            const left = @max(margin, @min(tab.left + inset, client.right - margin - w));
            const top = tab.top + @divTrunc(tab.height() - h, 2);
            return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
        }
    }
    // No tabs: where the title is, or at the top of the terminal.
    const top = if (lay.height() > 0) @divTrunc(lay.height() - h, 2) else margin;
    const left = if (lay.height() > 0) lay.tabs.left else margin;
    const right = @max(left + min_w, @min(left + style.px(320, s), client.right - margin));
    return .{ .left = left, .top = top, .right = right, .bottom = top + h };
}

/// The rename field as a popup with a text input; false when it cannot be
/// created.
fn showRenamePopup(self: *TabBar, factory: *d2d.Factory, hwnd: w32.HWND, target: RenameTarget, title: []const u16) bool {
    const win = self.window();
    const t = style.Tokens.fromConfig(&win.app.config);
    const popup = &self.rename_popup;
    if (popup.hwnd == null) {
        popup.create(win.app.hinstance, hwnd, factory, .{
            .activate = true,
            .text_input = true,
            .corners = .round_small,
            .border_color = t.border,
            .dark = t.dark,
            .keep_owner_active = true,
            .release_target_on_hide = true,
        }, .{
            .ctx = self,
            .paint = paintRename,
            .key = onRenameKey,
            .dismissed = onRenameDismissed,
            .message = onRenameMessage,
        }) catch |err| {
            log.warn("cannot create the rename field err={}", .{err});
            return false;
        };
    } else {
        popup.applyTheme(t);
    }
    const field = self.renameRect(hwnd, target, style.control.compact) orelse return false;
    var top_left = w32.POINT{ .x = field.left, .y = field.top };
    var bottom_right = w32.POINT{ .x = field.right, .y = field.bottom };
    _ = w32.ClientToScreen(hwnd, &top_left);
    _ = w32.ClientToScreen(hwnd, &bottom_right);

    var utf8_buf: [tabs.max_title_len * 3]u8 = undefined;
    popup.input.setText(popup.alloc, utf16ToUtf8(&utf8_buf, title)) catch |err| {
        log.warn("cannot fill the rename field err={}", .{err});
        return false;
    };
    popup.input.anchor = 0;
    popup.input.caret = popup.input.buf.items.len;
    popup.setAccessibleName(switch (target) {
        .window => gx.i18n.tr("Change Window Title…"),
        .tab, .none => gx.i18n.tr("Rename Tab"),
    });
    popup.setOwnerScale(win.scale);
    self.rename_target = target;
    self.rename_rect = .{ .left = top_left.x, .top = top_left.y, .right = bottom_right.x, .bottom = bottom_right.y };
    const popup_hwnd = popup.hwnd orelse return false;
    if (w32.PostMessageW(popup_hwnd, WM_SHOW_RENAME, 0, 0) == 0) popup.show(self.rename_rect);
    return true;
}

fn renameOf(ctx: *anyopaque) *TabBar {
    return @ptrCast(@alignCast(ctx));
}

fn paintRename(ctx: *anyopaque, popup: *Popup, canvas: *d2d.Canvas) void {
    const self = renameOf(ctx);
    const t = style.Tokens.fromConfig(&self.window().app.config);
    const size = popup.sizeDip();
    const r: d2d.Rect = .{ .x = 0, .y = 0, .w = size.width, .h = size.height };
    canvas.fillRect(r, t.surface);
    var buf: [tabs.max_title_len * 3]u8 = undefined;
    popup.drawTextInputEx(canvas, r, t, .{ .placeholder = self.renamePlaceholder(&buf) });
}

/// What the tab or the window shows once the field is emptied: the title
/// of the tab's focused terminal, or what the active tab shows.
fn renamePlaceholder(self: *TabBar, buf: []u8) []const u8 {
    const win = self.window();
    return switch (self.rename_target) {
        .none => "",
        .tab => |i| title: {
            const pane = win.paneAtTab(i) orelse break :title "";
            const snapshot = pane.snapshot();
            if (snapshot.title.len == 0) break :title utf16ToUtf8(buf, tabs.default_title);
            const value = tab_layout.utf8Prefix(snapshot.title.slice(), buf.len);
            @memcpy(buf[0..value.len], value);
            break :title buf[0..value.len];
        },
        .window => if (win.active_tab < win.tab_count)
            utf16ToUtf8(buf, win.tab_titles[win.active_tab][0..win.tab_title_lens[win.active_tab]])
        else
            "",
    };
}

fn onRenameKey(ctx: *anyopaque, popup: *Popup, key: Popup.Key) bool {
    _ = popup;
    const self = renameOf(ctx);
    if (key.ctrl or key.alt) return false;
    switch (key.vk) {
        w32.VK_RETURN => self.finishRename(),
        w32.VK_ESCAPE => self.cancelRename(),
        else => return false,
    }
    return true;
}

/// The rename popup closed by itself: Escape cancels; losing the
/// activation keeps the text (the focus stays where it went); the system
/// closing it (Alt+F4, which closes the window too) cancels.
fn onRenameDismissed(ctx: *anyopaque, popup: *Popup, reason: Popup.DismissReason) void {
    _ = popup;
    const self = renameOf(ctx);
    switch (reason) {
        .escape => self.endRename(false, true),
        .owner => self.endRename(false, false),
        .deactivated, .outside_click => self.endRename(true, false),
    }
}

fn onRenameMessage(ctx: *anyopaque, popup: *Popup, msg: u32, wparam: usize, lparam: isize) bool {
    _ = wparam;
    _ = lparam;
    if (msg != WM_SHOW_RENAME) return false;
    const self = renameOf(ctx);
    if (self.rename_target != .none and !popup.visible) popup.show(self.rename_rect);
    return true;
}

/// The rename field without Direct2D: an Edit control over the tab.
fn startRenameEdit(self: *TabBar, hwnd: w32.HWND, target: RenameTarget, title: []const u16) void {
    const win = self.window();
    const s = win.scale;
    const r = self.renameRect(hwnd, target, 26) orelse return;

    // CreateWindowExW reads a NUL-terminated wide string.
    var title_buf: [tabs.max_title_len + 1]u16 = undefined;
    @memcpy(title_buf[0..title.len], title);
    title_buf[title.len] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        win.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(13.0 * s))),
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
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    self.rename_edit = edit;
    self.rename_target = target;
    _ = w32.SetFocus(edit);
}

/// Apply the text of the rename field as the title override of the tab or
/// the window (an empty text removes it), close the field and give the
/// active terminal the focus.
pub fn finishRename(self: *TabBar) void {
    self.endRename(true, true);
}

/// Close the rename field without applying it.
pub fn cancelRename(self: *TabBar) void {
    self.endRename(false, true);
}

/// Close the rename field, applying its text when `commit`, and give the
/// active terminal the focus when `focus` (not when the focus went
/// elsewhere, such as to another program).
fn endRename(self: *TabBar, commit: bool, focus: bool) void {
    const target = self.rename_target;
    if (target == .none) return;
    // First: closing the field re-enters (EN_KILLFOCUS, WM_ACTIVATE).
    self.rename_target = .none;
    const win = self.window();
    if (commit) {
        var title: tabs.Title = .{};
        if (self.rename_edit) |edit| {
            var wbuf: [tabs.max_title_len + 1]u16 = undefined;
            const wlen: usize = @intCast(@max(0, w32.GetWindowTextW(edit, &wbuf, wbuf.len)));
            title = .fromUtf16(wbuf[0..wlen]);
        } else {
            title = .fromUtf16(self.rename_popup.input.buf.items);
        }
        switch (target) {
            .none => {},
            .tab => |i| win.setTabTitleOverride(i, title),
            .window => win.setWindowTitleOverride(title.slice()),
        }
    }
    if (self.rename_edit) |edit| {
        self.rename_edit = null;
        _ = w32.DestroyWindow(edit);
    }
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.rename_popup.hide();
    self.invalidate();
    if (focus) win.focusActiveSurface();
}

/// Handle WM_COMMAND from the rename edit; returns true when handled.
pub fn onCommand(self: *TabBar, wparam: usize) bool {
    const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
    const control_id: u16 = @intCast(wparam & 0xFFFF);
    // Tab rename Edit lost focus — commit (standard Win32 convention,
    // matches Explorer file rename and Edge tabs). Esc still cancels via
    // the message-loop intercept that catches VK_ESCAPE before it reaches
    // the Edit.
    if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
        self.finishRename();
        return true;
    }
    return false;
}

/// The UI language changed: repaint (labels come from the model; the
/// tooltips are translated when shown).
pub fn onLanguageChanged(self: *TabBar) void {
    for (&self.labels) |*label| label.deinit();
    self.invalidate();
    self.rename_popup.invalidate();
}

// -----------------------------------------------------------------------
// Win32 declarations used only by the tab bar
// -----------------------------------------------------------------------

const WH_KEYBOARD: i32 = 2;
const WM_CANCELMODE: u32 = 0x001F;
const SPI_GETKEYBOARDDELAY: u32 = 0x0016;
const SPI_GETKEYBOARDSPEED: u32 = 0x000A;

extern "user32" fn IsIconic(hWnd: w32.HWND) callconv(.winapi) i32;
extern "user32" fn SetWindowsHookExW(idHook: i32, lpfn: *const anyopaque, hmod: ?w32.HINSTANCE, dwThreadId: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn UnhookWindowsHookEx(hhk: *anyopaque) callconv(.winapi) i32;
extern "user32" fn CallNextHookEx(hhk: ?*anyopaque, nCode: i32, wParam: usize, lParam: isize) callconv(.winapi) isize;
extern "user32" fn SystemParametersInfoW(uiAction: u32, uiParam: u32, pvParam: ?*anyopaque, fWinIni: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w32.HANDLE;
extern "advapi32" fn OpenProcessToken(ProcessHandle: w32.HANDLE, DesiredAccess: u32, TokenHandle: *w32.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(
    TokenHandle: w32.HANDLE,
    TokenInformationClass: u32,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: u32,
    ReturnLength: *u32,
) callconv(.winapi) i32;

const TOKEN_QUERY: u32 = 0x0008;
const TokenElevation: u32 = 20;

/// Whether this process runs elevated (as administrator).
fn processElevated() bool {
    var token: w32.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return false;
    defer _ = w32.CloseHandle(token);
    var elevation: u32 = 0;
    var size: u32 = 0;
    if (GetTokenInformation(token, TokenElevation, &elevation, @sizeOf(u32), &size) == 0) return false;
    return elevation != 0;
}

test "tooltips append the shortcut" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var keys: Shortcut = .{};
    const text = "Ctrl+Shift+T";
    @memcpy(keys.buf[0..text.len], text);
    keys.len = text.len;
    try testing.expectEqualStrings("New tab (Ctrl+Shift+T)", withShortcut(&buf, "New tab", keys));
    try testing.expectEqualStrings("New tab", withShortcut(&buf, "New tab", null));
}

test "middle press cancels the old tab tooltip before closing its target" {
    var win: Window = undefined;
    win.hwnd = null;
    win.title_bar = .{};
    win.tab_bar = .{};
    win.title_bar.tooltip.target = .{ .tab = 0 };
    win.tab_bar.hover = .{ .tab = 0 };
    win.tab_bar.beginMiddlePress(42);
    try std.testing.expectEqual(TitleBar.TooltipTarget.none, win.title_bar.tooltip.target);
    try std.testing.expectEqual(Part.none, win.tab_bar.hover);
    // A move during the press can arm the same slot again. Closing it
    // must clear the tooltip without needing any subsequent movement.
    win.title_bar.tooltip.target = .{ .tab = 0 };
    win.tab_bar.hover = .{ .tab = 0 };
    try std.testing.expect(win.tab_bar.releaseMiddlePress(42));
    try std.testing.expectEqual(TitleBar.TooltipTarget.none, win.title_bar.tooltip.target);
    try std.testing.expectEqual(Part.none, win.tab_bar.hover);

    // Non-tab presses do not disturb another chrome control's tooltip.
    win.title_bar.tooltip.target = .new_tab;
    win.tab_bar.beginMiddlePress(null);
    try std.testing.expectEqual(TitleBar.TooltipTarget.new_tab, win.title_bar.tooltip.target);
    try std.testing.expect(!win.tab_bar.releaseMiddlePress(42));
    try std.testing.expectEqual(TitleBar.TooltipTarget.new_tab, win.title_bar.tooltip.target);
}

test "tooltip and title buffers keep complete utf8 codepoints" {
    const testing = std.testing;
    var keys: Shortcut = .{};
    const chord = "Ctrl+\u{2192}";
    @memcpy(keys.buf[0..chord.len], chord);
    keys.len = chord.len;
    var buf: [40]u8 = undefined;
    const title = "\u{6C49}\u{1F47B}";
    const units = std.unicode.utf8ToUtf16LeStringLiteral(title);
    for (0..buf.len + 1) |limit| {
        try testing.expect(std.unicode.utf8ValidateSlice(withShortcut(buf[0..limit], title, keys)));
        try testing.expect(std.unicode.utf8ValidateSlice(utf16ToUtf8(buf[0..limit], units)));
    }
    try testing.expectEqualStrings("\u{6C49}", utf16ToUtf8(buf[0..6], units));
}

test "caption colors are consumed without tinting a bare material" {
    const testing = std.testing;
    const Context = struct {
        active: bool = false,
        tokens: struct {
            high_contrast: bool = false,
            hover_text: d2d.Color = .black,
        } = .{},
        strip_fill: d2d.Color = d2d.Color.black.withAlpha(0.8),
        strip_text: d2d.Color = .white,
        strip_text_inactive: d2d.Color = d2d.Color.white.withAlpha(0.36),

        fn hoverGlyphColor(self: @This()) d2d.Color {
            return if (self.tokens.high_contrast) self.tokens.hover_text else self.strip_text;
        }
    };
    var ctx: Context = .{};
    var colors: Colors = undefined;
    applyCaptionColors(&colors, ctx);
    try testing.expectEqual(ctx.strip_fill, colors.strip.?);
    try testing.expectEqual(ctx.strip_text_inactive, colors.text);
    try testing.expectEqual(ctx.strip_text_inactive, colors.program);
    try testing.expectEqual(ctx.strip_text_inactive, colors.glyph);
    try testing.expectEqual(ctx.strip_text, colors.on_hover.?);
    ctx.active = true;
    ctx.strip_fill.a = 0;
    applyCaptionColors(&colors, ctx);
    try testing.expectEqual(@as(?d2d.Color, null), colors.strip);
    try testing.expectEqual(ctx.strip_text, colors.glyph);
    ctx.tokens.high_contrast = true;
    applyCaptionColors(&colors, ctx);
    try testing.expectEqual(ctx.tokens.hover_text, colors.hover_text);
    try testing.expectEqual(ctx.tokens.hover_text, colors.on_hover.?);
}

fn testActivePixel(strip: d2d.Color, rgb: [3]u8, opacity: f64, expected: u32) !void {
    const factory = try d2d.Factory.create(std.testing.allocator);
    defer factory.destroy();
    var canvas = d2d.Canvas.init(factory);
    defer canvas.deinit();
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    _ = target.ensure(null, 64, 32) orelse return error.CreateDibFailed;
    try std.testing.expect(canvas.beginDib(&target, .{ .width = 64, .height = 32 }, 96));
    canvas.clear(strip);
    var bar: TabBar = .{};
    defer if (bar.active_path) |*path| path.deinit();
    const pixel = tab_layout.backgroundPixel(rgb, opacity, true);
    bar.fillActiveTab(&canvas, .{ .x = 8, .y = 4, .w = 48, .h = 28 }, pixel);
    try std.testing.expectEqual(d2d.EndResult.ok, canvas.finish());
    try std.testing.expect(GdiFlush() != 0);
    const pixels: [*]u32 = @ptrCast(@alignCast(target.bits.?));
    const actual = pixels[16 * 64 + 32];
    std.debug.print("ChromeAlpha native expected=0x{x:0>8} actual=0x{x:0>8}\n", .{ expected, actual });
    try std.testing.expectEqual(expected, actual);
}

extern "gdi32" fn GdiFlush() callconv(.winapi) i32;

test "ChromeAlpha native light linear active fill matches terminal stored bytes" {
    try testActivePixel(d2d.Color.black.withAlpha(0), .{ 255, 255, 255 }, 0.3, 0x4d959595);
}

test "ChromeAlpha native active fill replaces translucent strip without double alpha" {
    try testActivePixel(d2d.Color.white.withAlpha(0.3), .{ 0, 0, 0 }, 0.3, 0x4d000000);
}

test "ChromeAlpha native active coverage matches rounded outline at every DPI and opacity" {
    const testing = std.testing;
    const alpha = @import("alpha.zig");
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = d2d.Canvas.init(factory);
    defer canvas.deinit();
    var mask_canvas = d2d.Canvas.init(factory);
    defer mask_canvas.deinit();
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    var mask: d2d.DibTarget = .{};
    defer mask.deinit();
    var bar: TabBar = .{};
    defer if (bar.active_path) |*path| path.deinit();
    const r: d2d.Rect = .{ .x = 24, .y = 4, .w = 80, .h = 36 };
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const s = @as(f32, @floatFromInt(dpi)) / 96;
        const w = style.px(128, s);
        const h = style.px(40, s);
        const size: d2d.SizeU = .{ .width = @intCast(w), .height = @intCast(h) };
        _ = target.ensure(null, w, h) orelse return error.CreateDibFailed;
        const mask_dc = mask.ensure(null, w, h) orelse return error.CreateDibFailed;
        try testing.expect(mask_canvas.beginDcAlpha(mask_dc, .{ .left = 0, .top = 0, .right = w, .bottom = h }, dpi));
        mask_canvas.clear(d2d.Color.black.withAlpha(0));
        var outline = activeOutline(&mask_canvas, r) orelse return error.CreateGeometryFailed;
        defer outline.deinit();
        mask_canvas.fillPath(&outline, .white);
        try testing.expectEqual(d2d.EndResult.ok, mask_canvas.finish());
        try testing.expect(GdiFlush() != 0);
        const coverage: [*]const u32 = @ptrCast(@alignCast(mask.bits.?));
        var partial: usize = 0;
        for (0..@intCast(h)) |y| {
            for (0..@intCast(w)) |x| {
                const a = coverage[y * @as(usize, @intCast(mask.width)) + x] >> 24;
                if (a > 0 and a < 255) partial += 1;
            }
        }
        try testing.expect(partial > 0);
        for ([_][3]u8{ .{ 0, 0, 0 }, .{ 31, 31, 40 }, .{ 240, 248, 255 }, .{ 255, 255, 255 } }) |rgb| {
            const tokens = style.Tokens.fromColors(d2d.Color.rgb(rgb[0], rgb[1], rgb[2]), .white, .white);
            for ([_]f64{ 0, 0.01, 0.1, 0.3, 0.75, 1 }) |opacity| {
                for ([_]bool{ false, true }) |linear| {
                    const pixel = tab_layout.backgroundPixel(rgb, opacity, linear);
                    const strip = tokens.title_bar.withAlpha(@floatCast(opacity));
                    const below = d2d.colorPixel(strip);
                    try testing.expect(canvas.beginDib(&target, size, dpi));
                    canvas.pushClip(.{ .x = 0, .y = 0, .w = 128, .h = 40 });
                    canvas.clear(strip);
                    bar.fillActiveTab(&canvas, r, pixel);
                    canvas.popClip();
                    try testing.expectEqual(d2d.EndResult.ok, canvas.finish());
                    try testing.expect(GdiFlush() != 0);
                    const actual: [*]const u32 = @ptrCast(@alignCast(target.bits.?));
                    const stride: usize = @intCast(target.width);
                    for (0..@intCast(h)) |y| {
                        for (0..@intCast(w)) |x| {
                            const a = coverage[y * @as(usize, @intCast(mask.width)) + x] >> 24;
                            try testing.expectEqual(alpha.replace(below, pixel, a), actual[y * stride + x]);
                        }
                    }
                    const center: usize = @intCast(style.px(64, s));
                    try testing.expectEqual(pixel, actual[(@as(usize, @intCast(h)) - 1) * stride + center]);
                }
            }
        }
    }
}

fn testChromeScene(canvas: *d2d.Canvas, bar: *TabBar, tokens: style.Tokens, strip: d2d.Color, pixel: u32, dirty: d2d.Rect, state: u2) void {
    canvas.pushClip(dirty);
    canvas.clear(strip);
    canvas.drawText("Inactive", .{ .x = 0, .y = 0, .w = 24, .h = 40 }, .{ .size = 12, .color = tokens.text });
    bar.fillActiveTab(canvas, .{ .x = 24, .y = 4, .w = 80, .h = 36 }, pixel);
    const close: d2d.Rect = .{ .x = 78, .y = 10, .w = 24, .h = 24 };
    if (state > 0) canvas.fillRoundedRect(close, style.radius.control, if (state == 2) tokens.overlay_pressed else tokens.overlay_hover);
    canvas.drawText("Active", .{ .x = 32, .y = 4, .w = 42, .h = 36 }, .{ .size = 12, .color = tokens.text });
    canvas.drawIcon(glyph.close, close, close_glyph_size, if (tokens.high_contrast and state > 0) tokens.hover_text else tokens.text);
    canvas.pushClip(.{ .x = 112, .y = 0, .w = 16, .h = 40 });
    canvas.clear(d2d.Color.black.withAlpha(0));
    canvas.popClip();
    canvas.popClip();
}

test "ChromeAlpha native dirty repaints preserve glyphs caption transparency and cached DC" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = d2d.Canvas.init(factory);
    defer canvas.deinit();
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    var bar: TabBar = .{};
    defer if (bar.active_path) |*path| path.deinit();
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const s = @as(f32, @floatFromInt(dpi)) / 96;
        const w = style.px(128, s);
        const h = style.px(40, s);
        const size: d2d.SizeU = .{ .width = @intCast(w), .height = @intCast(h) };
        _ = target.ensure(null, w, h) orelse return error.CreateDibFailed;
        for ([_]bool{ false, true }) |high_contrast| {
            const tokens = if (high_contrast) style.Tokens.fromSystem(.{
                .window = .black,
                .window_text = .white,
                .highlight = d2d.Color.hex(0x1aebff),
                .highlight_text = .black,
                .button_face = .black,
                .button_text = .white,
                .gray_text = d2d.Color.hex(0x3ff23f),
                .hotlight = d2d.Color.hex(0xffff00),
            }) else style.Tokens.fromColors(d2d.Color.hex(0xf0f8ff), .black, .black);
            const strip = if (high_contrast) tokens.title_bar else tokens.title_bar.withAlpha(0.3);
            const pixel = if (high_contrast) d2d.colorPixel(tokens.background) else tab_layout.backgroundPixel(.{ 240, 248, 255 }, 0.3, true);
            for ([_]u2{ 0, 1, 2 }) |state| {
                try testing.expect(canvas.beginDib(&target, size, dpi));
                testChromeScene(&canvas, &bar, tokens, strip, pixel, .{ .x = 0, .y = 0, .w = 128, .h = 40 }, state);
                try testing.expectEqual(d2d.EndResult.ok, canvas.finish());
                try testing.expect(GdiFlush() != 0);
                const pixels: [*]const u32 = @ptrCast(@alignCast(target.bits.?));
                const len: usize = @intCast(target.width * target.height);
                const saved = try testing.allocator.dupe(u32, pixels[0..len]);
                defer testing.allocator.free(saved);
                const dc = canvas.dib_stage.dc;
                const bitmap = canvas.dib_stage.bitmap;
                const caption_x: usize = @intCast(style.px(120, s));
                try testing.expectEqual(@as(u32, 0), pixels[caption_x]);
                var glyph_pixels: usize = 0;
                for (0..@intCast(h)) |y| {
                    for (@as(usize, @intCast(style.px(32, s)))..@intCast(style.px(74, s))) |x| {
                        if (pixels[y * @as(usize, @intCast(target.width)) + x] != pixel and y > @as(usize, @intCast(style.px(12, s)))) glyph_pixels += 1;
                    }
                }
                try testing.expect(glyph_pixels > 0);
                for (0..5) |_| {
                    try testing.expect(canvas.beginDib(&target, size, dpi));
                    testChromeScene(&canvas, &bar, tokens, strip, pixel, .{ .x = 46 / s, .y = 6 / s, .w = 44 / s, .h = 30 / s }, state);
                    try testing.expectEqual(d2d.EndResult.ok, canvas.finish());
                    try testing.expect(GdiFlush() != 0);
                    try testing.expectEqualSlices(u32, saved, pixels[0..len]);
                    try testing.expectEqual(dc, canvas.dib_stage.dc);
                    try testing.expectEqual(bitmap, canvas.dib_stage.bitmap);
                }
            }
        }
    }
}

test "ChromeAlpha native replacement leaves neighboring antialiased glyphs outside coverage" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = d2d.Canvas.init(factory);
    defer canvas.deinit();
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    _ = target.ensure(null, 128, 40) orelse return error.CreateDibFailed;
    var bar: TabBar = .{};
    defer if (bar.active_path) |*path| path.deinit();
    const strip = d2d.Color.black.withAlpha(0.3);
    try testing.expect(canvas.beginDib(&target, .{ .width = 128, .height = 40 }, 96));
    canvas.clear(strip);
    canvas.drawText("Neighbor W", .{ .x = 0, .y = 0, .w = 40, .h = 24 }, .{ .size = 16, .color = .white });
    try testing.expect(canvas.beginReplacement(0));
    canvas.endReplacement();
    const pixels: [*]const u32 = @ptrCast(@alignCast(target.bits.?));
    var saved: [128 * 40]u32 = undefined;
    @memcpy(&saved, pixels[0..saved.len]);
    bar.fillActiveTab(&canvas, .{ .x = 24, .y = 4, .w = 80, .h = 36 }, 0x4d959595);
    try testing.expectEqual(d2d.EndResult.ok, canvas.finish());
    try testing.expect(GdiFlush() != 0);
    var antialiased: usize = 0;
    for (0..24) |y| {
        for (0..24) |x| {
            const old = saved[y * 128 + x];
            try testing.expectEqual(old, pixels[y * 128 + x]);
            if (old >> 24 > 77 and old >> 24 < 255) antialiased += 1;
        }
    }
    try testing.expect(antialiased > 0);
    try testing.expectEqual(@as(u32, 0x4d959595), pixels[39 * 128 + 64]);
}

test "ChromeAlpha native fade replaces strip alpha without accumulating underlay" {
    const testing = std.testing;
    const factory = try d2d.Factory.create(testing.allocator);
    defer factory.destroy();
    var canvas = d2d.Canvas.init(factory);
    defer canvas.deinit();
    var target: d2d.DibTarget = .{};
    defer target.deinit();
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const s = @as(f32, @floatFromInt(dpi)) / 96;
        const w = style.px(64, s);
        const h = style.px(16, s);
        _ = target.ensure(null, w, h) orelse return error.CreateDibFailed;
        for ([_]f32{ 0, 0.01, 0.1, 0.3, 0.75, 1 }) |opacity| {
            const strip = d2d.Color.white.withAlpha(opacity);
            const pixel = d2d.colorPixel(strip);
            for ([_]bool{ false, true }) |blank| {
                try testing.expect(canvas.beginDib(&target, .{ .width = @intCast(w), .height = @intCast(h) }, dpi));
                canvas.clear(if (blank) strip else d2d.Color.black.withAlpha(opacity));
                paintFade(&canvas, 0, 16, strip, true);
                paintFade(&canvas, 64, 16, strip, false);
                try testing.expectEqual(d2d.EndResult.ok, canvas.finish());
                try testing.expect(GdiFlush() != 0);
                const pixels: [*]const u32 = @ptrCast(@alignCast(target.bits.?));
                try testing.expectEqual(pixel, pixels[0]);
                try testing.expectEqual(pixel, pixels[@intCast(w - 1)]);
                for (0..@intCast(w)) |x| {
                    try testing.expectEqual(pixel >> 24, pixels[x] >> 24);
                    if (blank) try testing.expectEqual(pixel, pixels[x]);
                }
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
