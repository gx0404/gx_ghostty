//! The Ghostty GX look of the GTK app (fork patch GX-0016): the static
//! rules in `style.css` plus colors derived from the terminal theme
//! (`src/gx/gtk_css.zig`), in a CSS provider of its own. `Style.apply` runs
//! from `Application.propConfig` on startup and on every configuration
//! change; it also applies `window-theme` to the style manager, which
//! upstream does only once in `Application.startupStyleManager`.
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

/// The Ghostty GX stylesheet of the application.
pub const Style = struct {
    provider: ?*gtk.CssProvider = null,

    /// Applies `window-theme` and loads the stylesheet for `config`,
    /// adding the provider to the default display the first time.
    pub fn apply(self: *Style, app: *adw.Application, config: *const CoreConfig) void {
        app.getStyleManager().setColorScheme(colorScheme(config));

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

    /// Removes the provider from the display.
    pub fn deinit(self: *Style) void {
        const provider = self.provider orelse return;
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
        }
        provider.unref();
        self.provider = null;
    }
};

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

/// Writes the whole stylesheet for `config`: the static rules, then the
/// colors when the window follows the terminal colors.
pub fn writeCss(writer: *std.Io.Writer, config: *const CoreConfig) std.Io.Writer.Error!void {
    try writer.writeAll(static_css);
    if (gtk_css.fromConfig(config)) |colors| try gtk_css.write(writer, colors);
}
