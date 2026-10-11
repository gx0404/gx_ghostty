//! The Ghostty GX About dialog (`app.gx-about`, the About entry of the GX
//! main menu). The upstream `win.about` dialog presents the build as
//! Ghostty by the Ghostty developers; this one names Ghostty GX, its
//! maintainer and links, and says on its first page that Ghostty GX is an
//! unofficial fork that the Ghostty project does not endorse. It shows no
//! logo: the Linux build keeps the upstream Ghostty application icon, which
//! this dialog must not present as the Ghostty GX logo.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const gx = @import("../../../gx/main.zig");
const adw_version = @import("../adw_version.zig");
const Application = @import("../class/application.zig").Application;
const Window = @import("../class/window.zig").Window;

const tr = gx.i18n.tr;
const branding = gx.branding;

/// Shown under the application name on the first page.
pub const byline = "Unofficial fork of Ghostty by gx0404";

/// Presents the About dialog over `window`.
pub fn present(window: *Window) void {
    var backend_buf: [512]u8 = undefined;
    const backend = graphicsBackend(window, &backend_buf);
    var graphics_buf: [640]u8 = undefined;
    var writer: std.Io.Writer = .fixed(graphics_buf[0 .. graphics_buf.len - 1]);
    gx.i18n.format(&writer, tr("Graphics: {backend}"), .{ .backend = backend }) catch {};
    const graphics_len = writer.buffered().len;
    graphics_buf[graphics_len] = 0;
    const graphics = graphics_buf[0..graphics_len :0];
    var buf: [2048]u8 = undefined;
    const comments = std.fmt.bufPrintZ(&buf, "{s}\n\n{s}\n\n{s}\n\n{s}: {s}", .{
        tr(branding.notice),
        tr(branding.license),
        graphics,
        tr("Report an Issue"),
        branding.issues_url,
    }) catch tr(branding.notice);

    if (adw_version.supportsDialogs()) {
        const dialog = adw.AboutDialog.new();
        dialog.setApplicationName(branding.name);
        dialog.setDeveloperName(tr(byline));
        dialog.setVersion(build_config.version_string);
        dialog.setComments(comments);
        dialog.setWebsite(branding.home_url);
        dialog.setIssueUrl(branding.issues_url);
        dialog.addLink(tr("Report an Issue"), branding.issues_url);
        dialog.as(adw.Dialog).present(window.as(gtk.Widget));
    } else {
        gtk.showAboutDialog(
            window.as(gtk.Window),
            "program-name",
            branding.name,
            "title",
            tr("About Ghostty GX").ptr,
            "version",
            build_config.version_string.ptr,
            "comments",
            comments.ptr,
            "website",
            branding.home_url,
            @as(?*anyopaque, null),
        );
    }
}

fn graphicsBackend(window: *Window, buf: []u8) [:0]const u8 {
    const vendor = Application.default().core().device.display.queryString(.vendor) orelse "unknown";
    const renderer = gtk_native_get_renderer(@ptrCast(window));
    const toolkit = if (renderer) |r| std.mem.span(g_type_name_from_instance(r)) else "unknown";
    return std.fmt.bufPrintZ(buf, "OpenGL (EGL: {s}); GTK: {s}", .{ vendor, toolkit }) catch "OpenGL / GTK";
}

extern fn gtk_native_get_renderer(native: *anyopaque) ?*anyopaque;
extern fn g_type_name_from_instance(instance: *anyopaque) [*:0]const u8;
