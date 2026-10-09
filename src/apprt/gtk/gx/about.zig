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
const Window = @import("../class/window.zig").Window;

const tr = gx.i18n.tr;
const branding = gx.branding;

/// Shown under the application name on the first page.
pub const byline = "Unofficial fork of Ghostty by gx0404";

/// Presents the About dialog over `window`.
pub fn present(window: *Window) void {
    var buf: [1024]u8 = undefined;
    const comments = std.fmt.bufPrintZ(&buf, "{s}\n\n{s}", .{
        tr(branding.notice),
        tr(branding.license),
    }) catch tr(branding.notice);

    if (adw_version.supportsDialogs()) {
        adw.showAboutDialog(
            window.as(gtk.Widget),
            "application-name",
            branding.name,
            "developer-name",
            tr(byline).ptr,
            "version",
            build_config.version_string.ptr,
            "comments",
            comments.ptr,
            "website",
            branding.home_url,
            "issue-url",
            branding.issues_url,
            @as(?*anyopaque, null),
        );
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
