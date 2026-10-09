//! The Ghostty GX look of the GTK app (fork patch GX-0016): the static
//! rules in `style.css` plus colors derived from the terminal theme
//! (`src/gx/gtk_css.zig`), in a CSS provider of its own. `Style.apply` runs
//! from `Application.propConfig` on startup and on every configuration
//! change; it also applies `window-theme` to the style manager (from an
//! idle callback), which upstream does only once in
//! `Application.startupStyleManager`.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const gtk_css = @import("../../../gx/gtk_css.zig");
const CoreConfig = configpkg.Config;

const log = std.log.scoped(.gtk_gx_style);

/// Above libadwaita and Ghostty's `style.css` (`APPLICATION`), below
/// Ghostty's runtime CSS (`APPLICATION + 3`) and `gtk-custom-css` (`USER`).
pub const priority = gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2;

/// The static rules, independent of the configuration.
pub const static_css = @embedFile("style.css");

/// The Ghostty GX stylesheet and color scheme of the application.
pub const Style = struct {
    provider: ?*gtk.CssProvider = null,

    /// The color scheme that `idle` sets on the style manager.
    scheme: adw.ColorScheme = .default,

    /// The pending idle source that sets `scheme`.
    idle: ?c_uint = null,

    /// Whether `apply` ran before.
    applied: bool = false,

    /// Loads the stylesheet for `config`, adding the provider to the
    /// default display the first time, and applies `window-theme`.
    pub fn apply(self: *Style, config: *const CoreConfig) void {
        self.load(config);

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
        const provider = self.provider orelse return;
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
        }
        provider.unref();
        self.provider = null;
    }

    fn load(self: *Style, config: *const CoreConfig) void {
        const provider = self.provider orelse provider: {
            const display = gdk.Display.getDefault() orelse {
                log.warn("no default display, Ghostty GX styles not loaded", .{});
                return;
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
            break :provider provider;
        };

        var buf: [static_css.len + 4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        writeCss(&writer, config) catch {
            log.warn("Ghostty GX stylesheet does not fit its buffer, using the static rules", .{});
            writer = .fixed(&buf);
            writer.writeAll(static_css) catch unreachable;
        };
        const css = writer.buffered();
        const bytes = glib.Bytes.new(css.ptr, css.len);
        defer bytes.unref();
        provider.loadFromBytes(bytes);
    }
};

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

/// Writes the whole stylesheet for `config`: the static rules, then the
/// colors when the window follows the terminal colors.
pub fn writeCss(writer: *std.Io.Writer, config: *const CoreConfig) std.Io.Writer.Error!void {
    try writer.writeAll(static_css);
    if (gtk_css.fromConfig(config)) |colors| try gtk_css.write(writer, colors);
}
