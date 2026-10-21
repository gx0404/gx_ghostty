//! Progress reports (OSC 9;4) on GTK tabs. A terminal shows a report in
//! its progress bar (`progress_bar_overlay` of `class/surface.zig`); its
//! tab shows the same progress in the tab bar and the tab overview: a pie
//! in `AdwTabPage:indicator-icon` with the percentage as its tooltip, red
//! in the error state, or a spinner (`AdwTabPage:loading`) while the
//! amount is unknown. A tab with splits shows the progress of its active
//! split, or else of the first split that reports one.
//!
//! The terminal's progress bar is the source of truth, so the tab follows
//! `progress-style`, the 15 s timeout of stalled reports and everything
//! else `Surface.setProgressReport` decides. The tab listens to the
//! `visible`, `fraction` and `css-classes` (the `error` class) properties
//! of the bar, and to the `css-classes` of its `progress` node, which has
//! the `pulse` class while the amount is unknown.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gx = @import("../../../gx/main.zig");
const ext = @import("../ext.zig");
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;

const Color = gx.ui_color.Color;
const tr = gx.i18n.tr;

/// The size of a tab's indicator icon, in logical pixels.
pub const icon_size = 16;

/// The object data key on a surface whose progress bar is watched.
const watch_key = "gx-progress-watch";

/// The object data key on a tab page holding the `Indicator.key` it shows.
const indicator_key = "gx-progress";

/// What a tab shows of a progress report.
pub const Indicator = union(enum) {
    /// No report.
    none,

    /// An unknown amount; true in the error state.
    busy: bool,

    /// A known amount.
    value: Value,

    pub const Value = struct {
        /// 0 to 100.
        percent: u8,

        /// The error state.
        failed: bool = false,
    };

    /// The indicator of a progress bar: hidden, with the `error` style
    /// class, pulsing, or at `fraction`.
    pub fn fromBar(visible: bool, failed: bool, pulsing: bool, fraction: f64) Indicator {
        if (!visible) return .none;
        if (pulsing) return .{ .busy = failed };
        const amount = if (std.math.isNan(fraction)) 0 else std.math.clamp(fraction, 0, 1);
        return .{ .value = .{ .percent = @intFromFloat(@round(amount * 100)), .failed = failed } };
    }

    /// A number that differs between indicators that look different; 0
    /// for none.
    pub fn key(self: Indicator) usize {
        return switch (self) {
            .none => 0,
            .busy => |failed| @as(usize, 1) + @intFromBool(failed),
            .value => |value| 3 + @as(usize, value.percent) * 2 + @intFromBool(value.failed),
        };
    }

    /// How much of the pie is filled, or null when the indicator is no
    /// pie: none, or a spinner.
    pub fn pie(self: Indicator) ?f32 {
        return switch (self) {
            .none => null,
            .busy => |failed| if (failed) 1 else null,
            .value => |value| @as(f32, @floatFromInt(value.percent)) / 100,
        };
    }

    /// Whether the report is in the error state.
    pub fn isError(self: Indicator) bool {
        return switch (self) {
            .none => false,
            .busy => |failed| failed,
            .value => |value| value.failed,
        };
    }

    /// The tooltip of the pie, in the UI language, written into `buf`.
    pub fn tooltip(self: Indicator, buf: []u8) [:0]const u8 {
        std.debug.assert(buf.len > 0);
        var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        switch (self) {
            .none => return "",
            .busy => |value| return if (value) tr("Error") else tr("In progress"),
            .value => |value| {
                const template = if (value.failed) tr("Error: {percent}%") else tr("Progress: {percent}%");
                gx.i18n.format(&writer, template, .{ .percent = value.percent }) catch return "";
            },
        }
        const len = writer.buffered().len;
        buf[len] = 0;
        return buf[0..len :0];
    }
};

/// The color of a pie in the error state: libadwaita's error color for
/// the light or the dark style, after the tab bar's `foreground`.
pub fn errorColor(foreground: Color) Color {
    return if (gx.ui_color.isDark(foreground)) Color.hex(0xc01c28) else Color.hex(0xff7b63);
}

/// Draws the pie of `fraction` (0 to 1) into `pixels`, `size` by `size`
/// premultiplied RGBA: a ring in `color` around a sector that grows
/// clockwise from the top, with 16 samples per pixel.
pub fn drawPie(pixels: []u8, size: usize, fraction: f32, color: Color) void {
    std.debug.assert(pixels.len >= size * size * 4);
    // Measured on a 32 by 32 grid: a ring from radius 12.5 to 15 and a
    // gap of 2.5 around the sector.
    const unit = @as(f32, @floatFromInt(size)) / 32;
    const shape: Pie = .{
        .outer = 15 * unit,
        .inner = 12.5 * unit,
        .sector = 10 * unit,
        .sweep = std.math.clamp(fraction, 0, 1) * std.math.tau,
    };
    const center = 16 * unit;
    const samples = 4;
    for (0..size) |y| {
        for (0..size) |x| {
            var hits: u32 = 0;
            for (0..samples) |sy| {
                for (0..samples) |sx| {
                    const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / samples;
                    const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples;
                    if (shape.contains(px - center, py - center)) hits += 1;
                }
            }
            const alpha = color.a * @as(f32, @floatFromInt(hits)) / (samples * samples);
            const pixel = pixels[(y * size + x) * 4 ..][0..4];
            pixel.* = .{ channel(color.r * alpha), channel(color.g * alpha), channel(color.b * alpha), channel(alpha) };
        }
    }
}

const Pie = struct {
    outer: f32,
    inner: f32,
    sector: f32,
    sweep: f32,

    /// Whether the point at `dx`, `dy` from the center (y down) is on the
    /// ring or in the sector.
    fn contains(self: Pie, dx: f32, dy: f32) bool {
        const r = @sqrt(dx * dx + dy * dy);
        if (r <= self.outer and r >= self.inner) return true;
        if (r > self.sector or self.sweep <= 0) return false;
        if (self.sweep >= std.math.tau) return true;
        // Clockwise from the top.
        var angle = std.math.atan2(dx, -dy);
        if (angle < 0) angle += std.math.tau;
        return angle <= self.sweep;
    }
};

fn channel(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

/// Shows the progress reports of `surface` on its tab from now on. Safe
/// to call again for the same surface.
pub fn watch(surface: *Surface) void {
    const object = surface.as(gobject.Object);
    if (object.getData(watch_key) != null) return;
    const bar = progressBar(surface) orelse return;
    object.setData(watch_key, @ptrFromInt(1));
    for ([_][:0]const u8{ "visible", "fraction", "css-classes" }) |property| {
        _ = gobject.Object.signals.notify.connect(
            bar.as(gobject.Object),
            *Surface,
            barChanged,
            surface,
            .{ .detail = property },
        );
    }
    if (activityNode(bar)) |node| {
        _ = gobject.Object.signals.notify.connect(
            node.as(gobject.Object),
            *Surface,
            barChanged,
            surface,
            .{ .detail = "css-classes" },
        );
    }
    _ = gobject.Object.signals.notify.connect(object, *Surface, scaleChanged, surface, .{ .detail = "scale-factor" });
}

fn barChanged(_: *gobject.Object, _: *gobject.ParamSpec, surface: *Surface) callconv(.c) void {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
    syncTab(tab);
}

fn scaleChanged(_: *gobject.Object, _: *gobject.ParamSpec, surface: *Surface) callconv(.c) void {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
    syncTabWith(tab, true);
}

pub fn syncWindow(window: *Window) void {
    const view = window.getTabView();
    var i: c_int = 0;
    while (i < view.getNPages()) : (i += 1) {
        const page = view.getNthPage(i);
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        show(page, tab, tabIndicator(tab), true);
    }
}

pub fn syncTab(tab: *Tab) void {
    syncTabWith(tab, false);
}

fn syncTabWith(tab: *Tab, force: bool) void {
    const view = ext.getAncestor(adw.TabView, tab.as(gtk.Widget)) orelse return;
    show(view.getPage(tab.as(gtk.Widget)), tab, tabIndicator(tab), force);
}

const kind_key = "gx-progress-kind";

pub fn setKind(page: *adw.TabPage, kind: gx.leader.Kind) void {
    page.as(gobject.Object).setData(kind_key, @ptrFromInt(@backingInt(kind)));
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    setTooltip(page, tabIndicator(tab));
}

fn statusText(kind: gx.leader.Kind) [:0]const u8 {
    return switch (kind) {
        .local => "",
        .remote => tr("Remote session"),
        .superuser => tr("Superuser session"),
        .container => tr("Container session"),
    };
}

fn combinedTooltip(indicator: Indicator, kind: gx.leader.Kind, buf: []u8) [:0]const u8 {
    if (kind == .local) return indicator.tooltip(buf);
    const status = statusText(kind);
    var progress_buf: [128]u8 = undefined;
    const text = indicator.tooltip(&progress_buf);
    if (text.len == 0) return status;
    return std.mem.printSentinel(buf, "{s} · {s}", .{ status, text }, 0) catch status;
}

fn tabTooltip(base: [:0]const u8, indicator: Indicator, kind: gx.leader.Kind, buf: []u8) [:0]const u8 {
    var detail_buf: [256]u8 = undefined;
    const detail = combinedTooltip(indicator, kind, &detail_buf);
    if (detail.len == 0) return base;
    if (base.len == 0) return std.mem.printSentinel(buf, "{s}", .{detail}, 0) catch base;
    return std.mem.printSentinel(buf, "{s}\n{s}", .{ base, detail }, 0) catch base;
}

fn tabTooltipChanged(_: *gobject.Object, _: *gobject.ParamSpec, tab: *Tab) callconv(.c) void {
    syncTab(tab);
}

fn setTooltip(page: *adw.TabPage, indicator: Indicator) void {
    const kind = std.enums.fromInt(gx.leader.Kind, @intFromPtr(page.as(gobject.Object).getData(kind_key))) orelse .local;
    var buf: [256]u8 = undefined;
    page.setIndicatorTooltip(combinedTooltip(indicator, kind, &buf));
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    const object = tab.as(gobject.Object);
    const key = "gx-progress-tab-watch";
    if (object.getData(key) == null) {
        object.setData(key, @ptrFromInt(1));
        _ = gobject.Object.signals.notify.connect(object, *Tab, tabTooltipChanged, tab, .{ .detail = "tooltip", .after = true });
    }
    var value = gobject.ext.Value.new(?[*:0]const u8);
    defer value.unset();
    object.getProperty("tooltip", &value);
    const base = if (value.getString()) |ptr| std.mem.span(ptr) else "";
    var page_buf: [1024]u8 = undefined;
    page.setTooltip(tabTooltip(base, indicator, kind, &page_buf));
}

fn tabIndicator(tab: *Tab) Indicator {
    if (tab.getActiveSurface()) |surface| {
        const indicator = surfaceIndicator(surface);
        if (indicator != .none) return indicator;
    }
    const tree = tab.getSurfaceTree() orelse return .none;
    var it = tree.iterator();
    while (it.next()) |entry| {
        const indicator = surfaceIndicator(entry.view);
        if (indicator != .none) return indicator;
    }
    return .none;
}

fn surfaceIndicator(surface: *Surface) Indicator {
    const bar = progressBar(surface) orelse return .none;
    const widget = bar.as(gtk.Widget);
    const pulsing = if (activityNode(bar)) |node| node.hasCssClass("pulse") != 0 else false;
    return .fromBar(widget.getVisible() != 0, widget.hasCssClass("error") != 0, pulsing, bar.getFraction());
}

fn show(page: *adw.TabPage, tab: *Tab, indicator: Indicator, force: bool) void {
    const object = page.as(gobject.Object);
    const key = indicator.key();
    setTooltip(page, indicator);
    if (!force and @intFromPtr(object.getData(indicator_key)) == key) return;
    object.setData(indicator_key, @ptrFromInt(key));

    page.setLoading(@intFromBool(indicator == .busy and indicator.pie() == null));
    const fraction = indicator.pie() orelse return page.setIndicatorIcon(null);
    const texture = pieTexture(tab, fraction, indicator.isError());
    defer texture.unref();
    page.setIndicatorIcon(texture.as(gio.Icon));
}

/// The pie in the colors of the tab bar of the window of `tab`, for its
/// scale factor.
fn pieTexture(tab: *Tab, fraction: f32, failed: bool) *gdk.MemoryTexture {
    const window = ext.getAncestor(Window, tab.as(gtk.Widget));
    const reference: *gtk.Widget = if (window) |w| tabBar(w) orelse w.as(gtk.Widget) else tab.as(gtk.Widget);
    var rgba: gdk.RGBA = undefined;
    reference.getColor(&rgba);
    const foreground: Color = .{ .r = rgba.f_red, .g = rgba.f_green, .b = rgba.f_blue, .a = rgba.f_alpha };
    const scale: usize = @intCast(std.math.clamp(reference.getScaleFactor(), 1, 4));
    const size = icon_size * scale;
    const pixels = glib.ext.alloc(u8, size * size * 4);
    drawPie(pixels, size, fraction, if (failed) errorColor(foreground) else foreground);
    const bytes = glib.Bytes.newTake(pixels.ptr, pixels.len);
    defer bytes.unref();
    return gdk.MemoryTexture.new(@intCast(size), @intCast(size), .r8g8b8a8_premultiplied, bytes, size * 4);
}

fn progressBar(surface: *Surface) ?*gtk.ProgressBar {
    const object = gtk_widget_get_template_child(
        surface.as(gtk.Widget),
        Surface.getGObjectType(),
        "progress_bar_overlay",
    ) orelse return null;
    return gobject.ext.cast(gtk.ProgressBar, object);
}

/// The `progress` node of a progress bar (`progressbar > trough >
/// progress`), which has the `pulse` style class while the bar pulses.
fn activityNode(bar: *gtk.ProgressBar) ?*gtk.Widget {
    const trough = childNamed(bar.as(gtk.Widget), "trough") orelse return null;
    return childNamed(trough, "progress");
}

fn childNamed(widget: *gtk.Widget, css_name: []const u8) ?*gtk.Widget {
    var child = widget.getFirstChild();
    while (child) |current| : (child = current.getNextSibling()) {
        if (std.mem.eql(u8, std.mem.span(current.getCssName()), css_name)) return current;
    }
    return null;
}

/// The tab bar below the window's toolbar, whose colors the pie takes.
fn tabBar(window: *Window) ?*gtk.Widget {
    const object = gtk_widget_get_template_child(
        window.as(gtk.Widget),
        Window.getGObjectType(),
        "toolbar",
    ) orelse return null;
    return findTabBar(gobject.ext.cast(gtk.Widget, object) orelse return null);
}

fn findTabBar(widget: *gtk.Widget) ?*gtk.Widget {
    var child = widget.getFirstChild();
    while (child) |current| : (child = current.getNextSibling()) {
        if (gobject.ext.isA(current, adw.TabBar)) return current;
        if (gobject.ext.isA(current, adw.TabView)) continue;
        if (findTabBar(current)) |found| return found;
    }
    return null;
}

// The generated binding declares the result as non-null, but GTK returns
// null for names that are not template children.
extern fn gtk_widget_get_template_child(
    widget: *gtk.Widget,
    widget_type: usize,
    name: [*:0]const u8,
) ?*gobject.Object;

test "Indicator.fromBar" {
    const testing = std.testing;
    try testing.expectEqual(@as(Indicator, .none), Indicator.fromBar(false, true, true, 0.5));
    try testing.expectEqual(Indicator{ .busy = false }, Indicator.fromBar(true, false, true, 0.5));
    try testing.expectEqual(Indicator{ .busy = true }, Indicator.fromBar(true, true, true, 0));
    try testing.expectEqual(Indicator{ .value = .{ .percent = 42 } }, Indicator.fromBar(true, false, false, 0.4249));
    try testing.expectEqual(Indicator{ .value = .{ .percent = 100, .failed = true } }, Indicator.fromBar(true, true, false, 1.5));
    try testing.expectEqual(Indicator{ .value = .{ .percent = 0 } }, Indicator.fromBar(true, false, false, std.math.nan(f64)));
}

test "Indicator.key tells every indicator apart" {
    const testing = std.testing;
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(testing.allocator);
    try seen.put(testing.allocator, @as(Indicator, .none).key(), {});
    for ([_]bool{ false, true }) |failed| {
        try testing.expect(!(try seen.getOrPut(testing.allocator, (Indicator{ .busy = failed }).key())).found_existing);
        for (0..101) |percent| {
            const indicator: Indicator = .{ .value = .{ .percent = @intCast(percent), .failed = failed } };
            try testing.expect(!(try seen.getOrPut(testing.allocator, indicator.key())).found_existing);
        }
    }
    try testing.expectEqual(@as(usize, 0), @as(Indicator, .none).key());
}

test "Indicator.pie and tooltip" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?f32, null), @as(Indicator, .none).pie());
    try testing.expectEqualStrings("", @as(Indicator, .none).tooltip(&buf));
    try testing.expectEqual(@as(?f32, null), (Indicator{ .busy = false }).pie());
    try testing.expect((Indicator{ .busy = false }).tooltip(&buf).len > 0);
    try testing.expectEqual(@as(?f32, 1), (Indicator{ .busy = true }).pie());
    try testing.expect((Indicator{ .busy = true }).tooltip(&buf).len > 0);

    const value: Indicator = .{ .value = .{ .percent = 42 } };
    try testing.expectEqual(@as(?f32, 0.42), value.pie());
    try testing.expect(!value.isError());
    try testing.expect(std.mem.indexOf(u8, value.tooltip(&buf), "42%") != null);
    const failing: Indicator = .{ .value = .{ .percent = 7, .failed = true } };
    try testing.expect(failing.isError());
    try testing.expect((Indicator{ .busy = true }).isError());
    try testing.expect(!@as(Indicator, .none).isError());
    const text = failing.tooltip(&buf);
    try testing.expect(std.mem.indexOf(u8, text, "7%") != null);
    try testing.expectEqual(@as(u8, 0), text.ptr[text.len]);

    // Too small a buffer cuts nothing in half: the text is empty instead.
    var tiny: [3]u8 = undefined;
    try testing.expectEqualStrings("", value.tooltip(&tiny));
}

test "status and progress tooltips coexist and translate" {
    const testing = std.testing;
    const language = gx.i18n.current();
    defer gx.i18n.setCurrent(language);
    var buf: [256]u8 = undefined;
    const value: Indicator = .{ .value = .{ .percent = 42 } };
    gx.i18n.setCurrent(.en);
    try testing.expectEqualStrings("Remote session · Progress: 42%", combinedTooltip(value, .remote, &buf));
    try testing.expectEqualStrings("Superuser session", combinedTooltip(.none, .superuser, &buf));
    try testing.expectEqualStrings("Container session · In progress", combinedTooltip(.{ .busy = false }, .container, &buf));
    gx.i18n.setCurrent(.zh_CN);
    try testing.expectEqualStrings("远程会话 · 进度：42%", combinedTooltip(value, .remote, &buf));
    try testing.expectEqualStrings("超级用户会话 · 出错", combinedTooltip(.{ .busy = true }, .superuser, &buf));
    var tiny: [2]u8 = undefined;
    try testing.expectEqualStrings("远程会话", combinedTooltip(value, .remote, &tiny));
    try testing.expectEqualStrings("<b>title</b>\n远程会话 · 进度：42%", tabTooltip("<b>title</b>", value, .remote, &buf));
    try testing.expectEqualStrings("进行中", tabTooltip("", .{ .busy = false }, .local, &buf));
    try testing.expectEqualStrings("title", tabTooltip("title", .none, .local, &buf));
    try testing.expectEqualStrings("title", tabTooltip("title", value, .remote, &tiny));
}

test "errorColor follows the style" {
    const testing = std.testing;
    try testing.expectEqual(@as(u24, 0xc01c28), errorColor(Color.black).toHex());
    try testing.expectEqual(@as(u24, 0xff7b63), errorColor(Color.white).toHex());
}

fn testAlpha(pixels: []const u8, size: usize, x: usize, y: usize) u8 {
    return pixels[(y * size + x) * 4 + 3];
}

test "drawPie fills the sector clockwise from the top" {
    const testing = std.testing;
    const size = 32;
    var pixels: [size * size * 4]u8 = undefined;
    const white = Color.white;

    drawPie(&pixels, size, 0, white);
    // The ring at the top and the corners.
    try testing.expectEqual(@as(u8, 255), testAlpha(&pixels, size, 16, 2));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 0, 0));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 31, 31));
    // An empty sector and the gap.
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 20, 12));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 16, 5));

    drawPie(&pixels, size, 0.25, white);
    // Top right is filled, the other quarters are not.
    try testing.expectEqual(@as(u8, 255), testAlpha(&pixels, size, 20, 12));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 20, 20));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 11, 20));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 11, 11));

    drawPie(&pixels, size, 1, white);
    for ([_][2]usize{ .{ 20, 12 }, .{ 20, 20 }, .{ 11, 20 }, .{ 11, 11 } }) |point| {
        try testing.expectEqual(@as(u8, 255), testAlpha(&pixels, size, point[0], point[1]));
    }
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 0, 0));
}

test "drawPie premultiplies and scales" {
    const testing = std.testing;
    const size = icon_size;
    var pixels: [size * size * 4]u8 = undefined;
    drawPie(&pixels, size, 0.5, Color.hex(0xff8000).withAlpha(0.5));
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const pixel = pixels[i..][0..4];
        try testing.expect(pixel[0] <= pixel[3] and pixel[1] <= pixel[3] and pixel[2] <= pixel[3]);
        try testing.expect(pixel[3] <= 128);
    }
    // The right half of the sector, the ring, and not the left half.
    try testing.expectEqual(@as(u8, 128), testAlpha(&pixels, size, 10, 6));
    try testing.expectEqual(@as(u8, 128), testAlpha(&pixels, size, 10, 9));
    try testing.expect(testAlpha(&pixels, size, 8, 1) > 0);
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 6, 9));
    try testing.expectEqual(@as(u8, 0), testAlpha(&pixels, size, 5, 6));
}
