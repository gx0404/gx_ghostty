//! The Ghostty GX look of the GTK app (fork patch GX-0016): the static
//! rules in `style.css` plus colors derived from the terminal theme
//! (`src/gx/gtk_css.zig`, with the CSS variables of newer libadwaita on
//! GTK 4.16 and newer), in a CSS provider of its own. `Style.apply` runs
//! from `Application.propConfig` on startup and on every configuration
//! change and reloads the provider only when the stylesheet changed; it
//! also applies `window-theme` to the style manager (from an idle
//! callback), which upstream does only once in
//! `Application.startupStyleManager`. While the system asks for high
//! contrast, only the static rules load and libadwaita's high contrast
//! style keeps its colors. `GHOSTTY_GX_ANIMATIONS=0` (`motion.env_override`)
//! appends `no_motion_css` to the static rules; otherwise the tab
//! transitions follow `gtk-enable-animations`, as all GTK CSS transitions
//! do (turning them on against the system setting would need that setting
//! changed for the whole app, which the override does not do).
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const gtk_css = @import("../../../gx/gtk_css.zig");
const motion = @import("../../../gx/motion.zig");
const ui_metrics = @import("../../../gx/ui_metrics.zig");
const gtk_version = @import("../gtk_version.zig");
const CoreConfig = configpkg.Config;

const log = std.log.scoped(.gtk_gx_style);

/// Above libadwaita and Ghostty's `style.css` (`APPLICATION`), below
/// Ghostty's runtime CSS (`APPLICATION + 3`) and `gtk-custom-css` (`USER`).
pub const priority = gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2;

/// The static rules, independent of the configuration.
pub const static_css = @embedFile("style.css");

/// Appended to the static rules when `GHOSTTY_GX_ANIMATIONS` turns
/// animations off.
pub const no_motion_css =
    \\/* GHOSTTY_GX_ANIMATIONS turns animations off. */
    \\toolbarview.gx-chrome tabbar tab,
    \\.gx-dialog .gx-record {
    \\  transition: none;
    \\}
    \\
;

/// The static rules: `static_css`, with `no_motion_css` unless
/// `animations`.
pub fn staticRules(animations: bool) []const u8 {
    return if (animations) static_css else static_css ++ no_motion_css;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// False when `GHOSTTY_GX_ANIMATIONS` turns animations off.
fn animationsAllowed() bool {
    const value = getenv(motion.env_override) orelse return true;
    return motion.parseOverride(std.mem.span(value)) orelse true;
}

const alloc = std.heap.c_allocator;

/// The Ghostty GX stylesheet and color scheme of the application.
pub const Style = struct {
    provider: ?*gtk.CssProvider = null,

    /// The stylesheet of the last configuration (`writeCss`), kept to
    /// switch to and from the static rules when high contrast changes.
    sheet: std.ArrayList(u8) = .empty,

    /// Whether the style manager reports high contrast.
    high_contrast: bool = false,

    /// The `notify::high-contrast` handler on the style manager, 0 while
    /// there is no provider.
    high_contrast_handler: c_ulong = 0,

    /// The hash of the stylesheet the provider holds (`stylesheetHash`),
    /// null before the first load.
    loaded: ?u64 = null,

    /// The color scheme that `idle` sets on the style manager.
    scheme: adw.ColorScheme = .default,

    /// The pending idle source that sets `scheme`.
    idle: ?c_uint = null,

    /// Whether `apply` ran before.
    applied: bool = false,

    /// False when `GHOSTTY_GX_ANIMATIONS` turns animations off, read once
    /// with the provider.
    animations: bool = true,

    /// Loads the stylesheet for `config`, adding the provider to the
    /// default display the first time, and applies `window-theme`.
    pub fn apply(self: *Style, config: *const CoreConfig) void {
        self.update(config);

        // The first call comes from `Application.new`, like
        // `startupStyleManager`. Later calls leave a circular scheme alone:
        // deriving it again could switch light and dark back and forth.
        if (!self.applied or !circularScheme(config)) {
            // A new scheme can reload the configuration right away
            // (`Application.handleStyleManagerDark`), which frees `config`
            // and nests a configuration change inside this one, so the
            // scheme is set from the main loop instead.
            self.scheme = colorScheme(config);
            if (self.idle == null) self.idle = glib.idleAdd(setScheme, self);
        }
        self.applied = true;
    }

    /// Removes the provider from the display and drops a pending scheme.
    pub fn deinit(self: *Style) void {
        if (self.idle) |idle| {
            _ = glib.Source.remove(idle);
            self.idle = null;
        }
        if (self.high_contrast_handler != 0) {
            gobject.signalHandlerDisconnect(
                adw.StyleManager.getDefault().as(gobject.Object),
                self.high_contrast_handler,
            );
            self.high_contrast_handler = 0;
        }
        self.sheet.deinit(alloc);
        self.sheet = .empty;
        self.loaded = null;
        const provider = self.provider orelse return;
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
        }
        provider.unref();
        self.provider = null;
    }

    fn update(self: *Style, config: *const CoreConfig) void {
        if (!self.ensureProvider()) return;
        var out: std.Io.Writer.Allocating = .fromArrayList(alloc, &self.sheet);
        out.clearRetainingCapacity();
        writeCss(&out.writer, config, .{
            .variables = gtk_version.runtimeAtLeast(4, 16, 0),
            .animations = self.animations,
        }) catch {
            log.warn("out of memory writing the Ghostty GX stylesheet, using the static rules", .{});
            out.clearRetainingCapacity();
        };
        self.sheet = out.toArrayList();
        self.reload();
    }

    /// Loads `stylesheet` into the provider unless it holds it already:
    /// every load restyles all widgets of the display, and most
    /// configuration changes (a theme preview step, a keybinding, the UI
    /// language) leave the stylesheet as it was.
    fn reload(self: *Style) void {
        const provider = self.provider orelse return;
        const css = stylesheet(self.sheet.items, self.high_contrast, self.animations);
        const hash = stylesheetHash(css);
        if (self.loaded == hash) {
            log.debug("Ghostty GX stylesheet unchanged, not reloaded", .{});
            return;
        }
        const bytes = glib.Bytes.new(css.ptr, css.len);
        defer bytes.unref();
        provider.loadFromBytes(bytes);
        self.loaded = hash;
        log.debug("Ghostty GX stylesheet reloaded ({d} bytes)", .{css.len});
    }

    /// Adds the provider to the default display and follows high contrast
    /// the first time. Returns false without a display.
    fn ensureProvider(self: *Style) bool {
        if (self.provider != null) return true;
        const display = gdk.Display.getDefault() orelse {
            log.warn("no default display, Ghostty GX styles not loaded", .{});
            return false;
        };
        const provider = gtk.CssProvider.new();
        _ = gtk.CssProvider.signals.parsing_error.connect(
            provider,
            *gtk.CssProvider,
            cssParsingError,
            provider,
            .{},
        );
        gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), priority);
        self.provider = provider;
        self.loaded = null;
        self.animations = animationsAllowed();

        const manager = adw.StyleManager.getDefault();
        self.high_contrast = manager.getHighContrast() != 0;
        self.high_contrast_handler = gobject.Object.signals.notify.connect(
            manager,
            *Style,
            highContrastChanged,
            self,
            .{ .detail = "high-contrast" },
        );
        return true;
    }
};

fn highContrastChanged(
    manager: *adw.StyleManager,
    _: *gobject.ParamSpec,
    self: *Style,
) callconv(.c) void {
    const high_contrast = manager.getHighContrast() != 0;
    if (high_contrast == self.high_contrast) return;
    log.debug("high contrast changed to {}", .{high_contrast});
    self.high_contrast = high_contrast;
    self.reload();
}

fn setScheme(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Style = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
    self.idle = null;
    adw.StyleManager.getDefault().setColorScheme(self.scheme);
    return @intFromBool(glib.SOURCE_REMOVE);
}

fn cssParsingError(
    _: *gtk.CssProvider,
    section: *gtk.CssSection,
    err: *glib.Error,
    _: *gtk.CssProvider,
) callconv(.c) void {
    const location = section.toString();
    defer glib.free(location);
    log.warn("Ghostty GX css parsing failed at {s}: {s}", .{ location, err.f_message orelse "«unknown»" });
}

/// The style manager color scheme for `window-theme`, as
/// `Application.startupStyleManager` computes it.
pub fn colorScheme(config: *const CoreConfig) adw.ColorScheme {
    return switch (config.@"window-theme") {
        .auto, .ghostty => if (config.background.toTerminalRGB().perceivedLuminance() > 0.5)
            .prefer_light
        else
            .prefer_dark,
        .system => .prefer_light,
        .dark => .force_dark,
        .light => .force_light,
    };
}

/// True if `window-theme` derives the color scheme from the background
/// while the background follows the color scheme (different light and
/// dark themes). Upstream turns `auto` into `system` in that case but
/// keeps `ghostty`.
fn circularScheme(config: *const CoreConfig) bool {
    return switch (config.@"window-theme") {
        .auto, .ghostty => config._conditional_set.contains(.theme),
        .system, .light, .dark => false,
    };
}

pub const Options = struct {
    /// Also write the CSS variables of libadwaita 1.6 and newer (GTK 4.16
    /// and newer).
    variables: bool = false,
    /// False to stop the tab transitions (`no_motion_css`).
    animations: bool = true,
};

/// Writes the whole stylesheet for `config`: the static rules
/// (`staticRules`), then the colors when the window follows the terminal
/// colors, as libadwaita named colors and, with `variables`, also as the
/// CSS variables of libadwaita 1.6 and newer.
pub fn writeCss(writer: *std.Io.Writer, config: *const CoreConfig, options: Options) std.Io.Writer.Error!void {
    try writer.writeAll(staticRules(options.animations));
    const colors = gtk_css.fromConfig(config) orelse return;
    try gtk_css.write(writer, colors);
    if (options.variables) try gtk_css.writeVariables416(writer, colors);
}

/// The stylesheet to load: `sheet` (from `writeCss`), or only the static
/// rules in high contrast or when `sheet` could not be written.
pub fn stylesheet(sheet: []const u8, high_contrast: bool, animations: bool) []const u8 {
    return if (high_contrast or sheet.len == 0) staticRules(animations) else sheet;
}

/// The hash `Style` compares to skip loading the stylesheet it holds.
pub fn stylesheetHash(css: []const u8) u64 {
    return std.hash.Wyhash.hash(0, css);
}

const testing = std.testing;

fn generate(config: *const CoreConfig, variables: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try writeCss(&out.writer, config, .{ .variables = variables });
    return out.toOwnedSlice();
}

test "writeCss appends the colors for auto and ghostty only" {
    var config = try CoreConfig.default(testing.allocator);
    defer config.deinit();

    for ([_]CoreConfig.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        const css = try generate(&config, false);
        defer testing.allocator.free(css);
        try testing.expect(std.mem.startsWith(u8, css, static_css));
        try testing.expect(std.mem.indexOf(u8, css, "@define-color window_bg_color ") != null);
        try testing.expect(std.mem.indexOf(u8, css, "toolbarview.gx-chrome > .top-bar,") != null);
        try testing.expect(std.mem.indexOf(u8, css, ":root") == null);

        const with_variables = try generate(&config, true);
        defer testing.allocator.free(with_variables);
        try testing.expect(std.mem.startsWith(u8, with_variables, css));
        try testing.expect(std.mem.indexOf(u8, with_variables[css.len..], ":root,\nwindow {\n  --accent-bg-color: ") != null);
    }

    for ([_]CoreConfig.WindowTheme{ .system, .light, .dark }) |theme| {
        config.@"window-theme" = theme;
        const css = try generate(&config, true);
        defer testing.allocator.free(css);
        try testing.expectEqualStrings(static_css, css);
    }
}

test "high contrast loads only the static rules" {
    var config = try CoreConfig.default(testing.allocator);
    defer config.deinit();
    const css = try generate(&config, false);
    defer testing.allocator.free(css);
    try testing.expectEqualStrings(css, stylesheet(css, false, true));
    try testing.expectEqualStrings(static_css, stylesheet(css, true, true));
    // A stylesheet that could not be written falls back to the static rules.
    try testing.expectEqualStrings(static_css, stylesheet("", false, true));
    // Animations stay off in high contrast too.
    try testing.expect(std.mem.endsWith(u8, stylesheet(css, true, false), no_motion_css));
}

test "GHOSTTY_GX_ANIMATIONS=0 stops the tab transitions" {
    var config = try CoreConfig.default(testing.allocator);
    defer config.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCss(&out.writer, &config, .{ .animations = false });
    const css = out.written();
    try testing.expect(std.mem.startsWith(u8, css, static_css ++ no_motion_css));
    // The GX colors follow and do not bring transitions back.
    try testing.expect(std.mem.indexOf(u8, css[static_css.len + no_motion_css.len ..], "transition") == null);
    try testing.expectEqualStrings(static_css, staticRules(true));
}

/// The px values of every `property: …;` declaration in `css`, in order,
/// with each declaration's values ending in a null.
fn pxValues(css: []const u8, property: []const u8, out: []?f32) ![]?f32 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, css, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, property)) continue;
        const value = std.mem.trimEnd(u8, trimmed[property.len..], ";");
        var parts = std.mem.tokenizeScalar(u8, value, ' ');
        while (parts.next()) |part| {
            const number = if (std.mem.endsWith(u8, part, "px")) part[0 .. part.len - 2] else part;
            out[n] = try std.fmt.parseFloat(f32, number);
            n += 1;
        }
        out[n] = null;
        n += 1;
    }
    return out[0..n];
}

fn hasText(comptime fmt: []const u8, args: anytype) !bool {
    var buf: [256]u8 = undefined;
    return std.mem.indexOf(u8, static_css, try std.fmt.bufPrint(&buf, fmt, args)) != null;
}

test "the static px values and transitions come from ui_metrics and motion" {
    // Every corner radius is a ui_metrics radius, 0 (the link overlay's
    // square corners) or the badge pill (half its height).
    var buf: [64]?f32 = undefined;
    const radii = try pxValues(static_css, "border-radius:", &buf);
    try testing.expect(radii.len > 0);
    var overlay_corners: usize = 0;
    for (radii) |value| {
        const v = value orelse continue;
        if (v == ui_metrics.radius.overlay) overlay_corners += 1;
        try testing.expect(v == 0 or v == ui_metrics.radius.control or v == ui_metrics.radius.overlay or
            v == ui_metrics.radius.window or v == badge_height / 2);
    }
    // The tabs (with their focus ring and the dragged tab), the find, key
    // table and resize overlays, and one corner of each link overlay.
    try testing.expectEqual(@as(usize, 4), overlay_corners);
    try testing.expect(try hasText("dnd tab {{\n  border-radius: {d}px;", .{ui_metrics.radius.overlay}));
    try testing.expect(try hasText("toolbarview.gx-chrome label.resize-overlay {{\n  border-radius: {d}px;", .{ui_metrics.radius.overlay}));
    try testing.expect(try hasText("url-overlay.left {{\n  border-radius: 0 {d}px 0 0;", .{ui_metrics.radius.overlay}));
    try testing.expect(try hasText("url-overlay.right {{\n  border-radius: {d}px 0 0 0;", .{ui_metrics.radius.overlay}));

    // The badge: caption type, a pill padded by the small spacing step.
    try testing.expect(try hasText(".gx-badge {{\n  min-height: {d}px;\n  padding: 0 {d}px;\n  border-radius: {d}px;\n  font-size: {d}px;", .{
        badge_height, ui_metrics.space.s, badge_height / 2, ui_metrics.type_ramp.caption.size,
    }));

    // The signature bar and the tab transitions.
    try testing.expect(try hasText("tab:selected,\ndnd tab {{\n  box-shadow: inset 0 {d}px 0 0 @accent_bg_color;", .{ui_metrics.signature.bar}));
    const ease = motion.ease;
    try testing.expect(try hasText("toolbarview.gx-chrome tabbar tab {{\n  transition: background-color {d}ms cubic-bezier({d}, {d}, {d}, {d});", .{
        motion.duration.faster, ease.x1, ease.y1, ease.x2, ease.y2,
    }));
    try testing.expect(try hasText("tab:active {{\n  transition-duration: {d}ms;", .{motion.duration.fast}));
}

/// The height of the dialog badges (`.gx-badge`), a pill.
const badge_height: f32 = 20;

test "the static rules only select the main window" {
    try testing.expect(std.mem.indexOf(u8, static_css, ".window ") == null);
    try testing.expect(std.mem.indexOf(u8, static_css, "#555555") == null);
    try testing.expect(std.mem.indexOf(u8, static_css, "scrollbar") == null);
    try testing.expect(std.mem.indexOf(u8, static_css, "toolbarview.gx-chrome tabbar tabbox > tabboxchild") != null);
}

test "stylesheetHash tells stylesheets apart" {
    var config = try CoreConfig.default(testing.allocator);
    defer config.deinit();
    const first = try generate(&config, false);
    defer testing.allocator.free(first);
    const again = try generate(&config, false);
    defer testing.allocator.free(again);
    try testing.expectEqual(stylesheetHash(first), stylesheetHash(again));

    config.background = .{ .r = 0xfa, .g = 0xfa, .b = 0xfa };
    const light = try generate(&config, false);
    defer testing.allocator.free(light);
    try testing.expect(stylesheetHash(first) != stylesheetHash(light));
}
