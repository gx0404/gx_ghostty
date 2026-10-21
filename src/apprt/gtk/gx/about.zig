//! The Ghostty GX About dialog (`app.gx-about`, the About entry of the GX
//! main menu). The upstream `win.about` dialog presents the build as
//! Ghostty by the Ghostty developers; this one names Ghostty GX, its
//! maintainer and links, and says on its first page that Ghostty GX is an
//! unofficial fork that the Ghostty project does not endorse.
//!
//! The logo is the icon named `ghostty-gx`, which only the GTK resources
//! have (GX-0058): the application id the fork keeps
//! (`com.mitchellh.ghostty`) can resolve to the upstream Ghostty logo on a
//! system that installed the upstream hicolor icons (`zig build install`,
//! the Debian 13 tarball), which this dialog must not present as the
//! Ghostty GX logo. The license is the MIT license type, the graphics
//! backend and runtime versions are the debug information, and the project
//! and issue links show once each.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const gx = @import("../../../gx/main.zig");
const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;

const tr = gx.i18n.tr;
const branding = gx.branding;

/// Shown under the application name on the first page.
pub const byline = "Unofficial fork of Ghostty by gx0404";

/// The icon of the dialog, only in the GTK resources (GX-0058).
pub const icon_name = "ghostty-gx";

/// Presents the About dialog over `window`.
pub fn present(window: *Window) void {
    var backend_buf: [512]u8 = undefined;
    const backend = graphicsBackend(window, &backend_buf);
    var debug_buf: [1024]u8 = undefined;
    const debug = debugInfo(&debug_buf, backend);

    if (adw_version.supportsDialogs()) {
        const dialog = adw.AboutDialog.new();
        dialog.as(gtk.Widget).addCssClass("gx-dialog");
        dialog.setApplicationIcon(icon_name);
        dialog.setApplicationName(branding.name);
        dialog.setDeveloperName(tr(byline));
        dialog.setVersion(build_config.version_string);
        dialog.setComments(tr(branding.notice));
        dialog.setLicenseType(.mit_x11);
        dialog.setWebsite(branding.home_url);
        dialog.setIssueUrl(branding.issues_url);
        dialog.setDebugInfo(debug);
        dialog.setDebugInfoFilename("ghostty-gx-debug-info.txt");
        dialog.as(adw.Dialog).present(window.as(gtk.Widget));
    } else {
        gtk.showAboutDialog(
            window.as(gtk.Window),
            "program-name",
            branding.name,
            "title",
            tr("About Ghostty GX").ptr,
            "logo-icon-name",
            icon_name,
            "version",
            build_config.version_string.ptr,
            "comments",
            tr(branding.notice).ptr,
            "license-type",
            @as(c_int, @intFromEnum(gtk.License.mit_x11)),
            "website",
            branding.home_url,
            "system-information",
            debug.ptr,
            @as(?*anyopaque, null),
        );
    }
}

/// The debug information: the version, the graphics backend and the GTK
/// and libadwaita versions the dialog runs with.
fn debugInfo(buf: []u8, backend: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s} {s}\n{s}\nGTK {f}\nlibadwaita {f}\n", .{
        branding.name,
        build_config.version_string,
        backend,
        gtk_version.getRuntimeVersion(),
        adw_version.getRuntimeVersion(),
    }) catch branding.name;
}

fn graphicsBackend(window: *Window, buf: []u8) [:0]const u8 {
    const vendor = Application.default().core().device.display.queryString(.vendor) orelse "unknown";
    const renderer = gtk_native_get_renderer(@ptrCast(window));
    const toolkit = if (renderer) |r| std.mem.span(g_type_name_from_instance(r)) else "unknown";
    return std.fmt.bufPrintZ(buf, "OpenGL (EGL: {s}); GTK renderer: {s}", .{ vendor, toolkit }) catch "OpenGL / GTK";
}

extern fn gtk_native_get_renderer(native: *anyopaque) ?*anyopaque;
extern fn g_type_name_from_instance(instance: *anyopaque) [*:0]const u8;

test "the debug information names the version and the toolkit" {
    var buf: [1024]u8 = undefined;
    const info = debugInfo(&buf, "OpenGL (EGL: test); GTK renderer: GskGLRenderer");
    try std.testing.expect(std.mem.startsWith(u8, info, branding.name ++ " " ++ build_config.version_string ++ "\n"));
    try std.testing.expect(std.mem.indexOf(u8, info, "GskGLRenderer") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "\nGTK ") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "\nlibadwaita ") != null);
}
