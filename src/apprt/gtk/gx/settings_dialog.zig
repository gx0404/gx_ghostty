//! The Ghostty GX settings dialog (fork patch GX-0015): the settings of
//! `src/gx/settings_map.zig` in an `Adw.PreferencesDialog`. Every change
//! is saved to the settings overlay `gui-settings.ghostty` (never to the
//! user's configuration file) and applied without the "Reloaded the
//! configuration" toast; changes made in quick succession are saved
//! together, and the dialog says when they are saved. A save that fails
//! keeps the changes and offers to try again. "Reset to Default" removes
//! the setting from the overlay (`settings_map.Changes.reset`), and every
//! row shows the value the applied configuration has.
//!
//! The themes are listed on a subpage. Moving through the list previews
//! each theme: the configuration is built in memory from a snapshot of
//! the configuration layers (`gx.config_layers.Layers`) with a `--theme`
//! override. Applying a theme saves it; reverting, going back or closing
//! the dialog without applying ends the preview. Reverting, going back or
//! selecting the saved theme again also drops a theme whose saving failed;
//! when the theme was saved and only applying it failed, reverting applies
//! the saved configuration again instead. A configuration that follows the
//! system's light or dark mode with two themes shows a row for each.
//!
//! The text is translated with the Ghostty GX tables (`src/gx/i18n.zig`,
//! not gettext) into the language of the configuration, and follows it
//! when it changes while the dialog is open. Without the Ghostty GX
//! layers (`GHOSTTY_GX_DEFAULTS=0`) the overlay is not loaded, so the
//! settings are shown but cannot be changed.
//!
//! Closing the dialog only takes it out of its window, which keeps it
//! (`dialog_cache`) and presents it again at its next opening there, on
//! the page a new dialog would start on and with the values of the
//! configuration (P4). A configuration reload, a change of the UI
//! language or of the theme, or the window going away puts it out of
//! date, and the next opening builds a new one. One dialog shows at a
//! time: opening it in another window closes the one shown.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const file_load = @import("../../../config/file_load.zig");
const themepkg = @import("../../../config/theme.zig");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("../class/application.zig").Application;
const open_perf = @import("open_perf.zig");
const dialog_cache = @import("dialog_cache.zig");

const settings_map = gx.settings_map;
const msg = settings_map.msg;
const fuzzy = gx.fuzzy;
const theme_swatch = gx.theme_swatch;
const CoreConfig = configpkg.Config;
const Layers = gx.config_layers.Layers;

const log = std.log.scoped(.gtk_ghostty_gx_settings);

extern fn pango_font_family_get_type() usize;
extern fn pango_font_face_get_type() usize;
extern fn pango_font_family_is_monospace(family: *anyopaque) c_int;
extern fn pango_font_face_get_family(face: *anyopaque) *anyopaque;
extern fn pango_font_description_new() *anyopaque;
extern fn pango_font_description_free(description: *anyopaque) void;
extern fn pango_font_description_get_family(description: *const anyopaque) ?[*:0]const u8;
extern fn pango_font_description_set_family(description: *anyopaque, family: [*:0]const u8) void;

/// How long changes are collected before they are saved, in milliseconds.
const save_delay_ms = 300;

/// How long the theme selection has to rest before it is previewed, in
/// milliseconds: after moving through the list, so holding an arrow key
/// does not reload for every row, and longer after typing a search.
const preview_delay_ms = 150;

/// Compare the live theme before updateConfig; UI preview flags may already
/// have been cleared by Revert, close, or Apply.
fn themeReloadChanged(previous: *const CoreConfig, next: *const CoreConfig) bool {
    return previous.changed(next, .theme);
}
const typing_preview_delay_ms = 400;

test "theme reload changes cover preview revert close and save without duplicate counts" {
    const alloc = std.testing.allocator;
    var saved = try CoreConfig.default(alloc);
    defer saved.deinit();
    saved.theme = .{ .light = "Saved", .dark = "Saved" };
    var preview = try saved.clone(alloc);
    defer preview.deinit();
    preview.theme = .{ .light = "Preview", .dark = "Preview" };
    try std.testing.expect(themeReloadChanged(&saved, &preview));
    // Revert and close restore the saved theme after previewing was cleared.
    try std.testing.expect(themeReloadChanged(&preview, &saved));
    // Saving a different selection without a prior preview is a real change.
    try std.testing.expect(themeReloadChanged(&saved, &preview));
    // Applying an already visible preview, or changing another setting, is not.
    var applied = try preview.clone(alloc);
    defer applied.deinit();
    applied.@"cursor-style" = .bar;
    try std.testing.expect(!themeReloadChanged(&preview, &applied));
    applied.theme = null;
    try std.testing.expect(themeReloadChanged(&preview, &applied));
}

/// How long "Settings saved." shows, in seconds.
const saved_toast_seconds = 2;

/// The rows a page or arrow key moves the theme selection by.
const page_rows = 10;

/// The languages of the language row, in display order.
const languages = std.enums.values(gx.i18n.Language);

/// The material presets of the material row, in display order.
const materials = std.enums.values(settings_map.Material);

/// The opacity choices of the opacity row, in display order.
const opacities = std.enums.values(settings_map.Opacity);

/// The padding presets of the padding row, in display order.
const paddings = std.enums.values(settings_map.Padding);

/// The msgids of the dialog besides those of `settings_map.msg`,
/// translated in `src/gx/i18n/gx.zh_CN.po`.
const text = struct {
    pub const revert = "Revert";
    pub const retry = "Retry";
    pub const saved = "Settings saved.";
    pub const choose_font = "Choose a Monospace Font…";
    pub const default_font = "Use the Default Font";
    pub const open_folder = "Open Folder";
    pub const custom_value = "Custom: {value}";
    pub const layering_off = "Settings cannot be changed here because {variable} turns off the Ghostty GX settings. Edit the configuration file instead.";
    pub const bell_audio_hint = "Set bell-audio-path in the configuration file to choose the sound.";
};

/// The dialog shown, if any. Opening the settings again in its window
/// brings it to the front; opening them in another window closes it.
var open_dialog: WeakRef(GxSettingsDialog) = .empty;

/// The dialog each window keeps after it closed.
const kept_dialogs = dialog_cache.Cache(GxSettingsDialog, "gx-settings-dialog");

/// The page the dialog showed when it was last closed; the next opening
/// starts there.
var last_page: ?settings_map.Page = null;

/// Which half of the `theme` value the theme list chooses.
const ThemeTarget = enum {
    /// One theme for light and dark mode.
    single,
    light,
    dark,
};

/// The `theme` value that sets the `target` half of the saved themes
/// (`light`, `dark`) to `name`: the name alone when both halves are the
/// same, else `light:<light>,dark:<dark>`.
fn themeValue(
    alloc: Allocator,
    target: ThemeTarget,
    light: ?[]const u8,
    dark: ?[]const u8,
    name: []const u8,
) Allocator.Error![:0]u8 {
    const pair: settings_map.ThemePair = switch (target) {
        .single => .{ .light = name, .dark = name },
        .light => .{ .light = name, .dark = dark orelse name },
        .dark => .{ .light = light orelse name, .dark = name },
    };
    return try pair.value(alloc);
}

/// What a dialog shows of the configuration it was built with that only
/// building it again updates: the UI language of its static text and the
/// theme. A kept dialog opens again only while both are unchanged.
const Built = struct {
    lang: gx.i18n.Language,
    theme: u64,

    fn of(config: *const CoreConfig) Built {
        return .{ .lang = gx.i18n.resolve(config.language), .theme = themeStamp(config.theme) };
    }
};

/// A hash of a `theme` value: its light and its dark theme.
fn themeStamp(theme: ?CoreConfig.Theme) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (theme) |value| {
        hasher.update(value.light);
        hasher.update(&.{0});
        hasher.update(value.dark);
    }
    return hasher.final();
}

/// `command` without the `direct:` or `shell:` prefix that tells how it
/// runs, as the shell row shows it.
fn commandText(command: []const u8) []const u8 {
    for ([_][]const u8{ "direct:", "shell:" }) |prefix| {
        if (std.mem.startsWith(u8, command, prefix)) return command[prefix.len..];
    }
    return command;
}

/// The position in a list of `len` rows that moving `delta` rows from
/// `current` (none when null) selects, clamped to the list.
fn movedPosition(current: ?usize, delta: isize, len: usize) ?usize {
    if (len == 0) return null;
    const last: isize = @intCast(len - 1);
    const from: isize = if (current) |pos| @intCast(pos) else if (delta > 0) -1 else last + 1;
    return @intCast(std.math.clamp(from + delta, 0, last));
}

/// An opacity as a percentage (`0.85` is `85%`).
fn opacityText(buf: []u8, opacity: f64) error{NoSpaceLeft}![]const u8 {
    const percent: i64 = @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 100));
    return std.fmt.bufPrint(buf, "{d}%", .{percent});
}

/// A `window-padding-x`/`-y` value: one number, or two when the sides
/// differ.
fn paddingValue(buf: []u8, padding: CoreConfig.WindowPadding) error{NoSpaceLeft}![]const u8 {
    if (padding.top_left == padding.bottom_right) return std.fmt.bufPrint(buf, "{d}", .{padding.top_left});
    return std.fmt.bufPrint(buf, "{d},{d}", .{ padding.top_left, padding.bottom_right });
}

/// The value of the opacity row.
const OpacityValue = union(enum) {
    choice: settings_map.Opacity,
    /// A value no choice offers.
    custom: f64,

    fn eql(a: OpacityValue, b: OpacityValue) bool {
        return switch (a) {
            .choice => |x| b == .choice and b.choice == x,
            .custom => |x| b == .custom and b.custom == x,
        };
    }
};

/// The value of the padding row.
const PaddingValue = union(enum) {
    preset: settings_map.Padding,
    /// Values no preset has.
    custom: struct { x: CoreConfig.WindowPadding, y: CoreConfig.WindowPadding },

    fn eql(a: PaddingValue, b: PaddingValue) bool {
        return switch (a) {
            .preset => |x| b == .preset and b.preset == x,
            .custom => |x| b == .custom and x.x.equal(b.custom.x) and x.y.equal(b.custom.y),
        };
    }
};

pub const GxSettingsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.PreferencesDialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyGxSettingsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        language_page: *adw.PreferencesPage,
        language_group: *adw.PreferencesGroup,
        language_row: *adw.ComboRow,
        appearance_page: *adw.PreferencesPage,
        theme_group: *adw.PreferencesGroup,
        theme_row: *adw.ActionRow,
        theme_light_row: *adw.ActionRow,
        theme_dark_row: *adw.ActionRow,
        material_group: *adw.PreferencesGroup,
        material_row: *adw.ComboRow,
        opacity_row: *adw.ComboRow,
        cursor_group: *adw.PreferencesGroup,
        cursor_style_row: *adw.ComboRow,
        cursor_blink_row: *adw.SwitchRow,
        padding_group: *adw.PreferencesGroup,
        padding_row: *adw.ComboRow,
        font_page: *adw.PreferencesPage,
        font_size_group: *adw.PreferencesGroup,
        font_size_row: *adw.SpinRow,
        font_size_reset_button: *gtk.Button,
        font_family_group: *adw.PreferencesGroup,
        font_choice_row: *adw.ActionRow,
        font_family_row: *adw.EntryRow,
        font_choose_button: *gtk.FontDialogButton,
        font_clear_button: *gtk.Button,
        interaction_page: *adw.PreferencesPage,
        interaction_group: *adw.PreferencesGroup,
        right_click_row: *adw.ComboRow,
        scrollbar_row: *adw.SwitchRow,
        close_confirmation_row: *adw.ComboRow,
        focus_follows_mouse_row: *adw.SwitchRow,
        ctrl_scroll_zoom_row: *adw.SwitchRow,
        ctrl_scroll_zoom_reset_button: *gtk.Button,
        bell_group: *adw.PreferencesGroup,
        bell_system_row: *adw.SwitchRow,
        bell_audio_row: *adw.SwitchRow,
        bell_attention_row: *adw.SwitchRow,
        bell_title_row: *adw.SwitchRow,
        bell_border_row: *adw.SwitchRow,
        shell_page: *adw.PreferencesPage,
        shell_group: *adw.PreferencesGroup,
        shell_row: *adw.ComboRow,
        about_page: *adw.PreferencesPage,
        about_group: *adw.PreferencesGroup,
        version_row: *adw.ActionRow,
        config_path_row: *adw.ActionRow,
        open_folder_button: *gtk.Button,
        open_config_button: *gtk.Button,
        settings_file_group: *adw.PreferencesGroup,
        settings_path_row: *adw.ActionRow,
        theme_subpage: *adw.NavigationPage,
        theme_search: *gtk.SearchEntry,
        theme_revert_button: *gtk.Button,
        theme_apply_button: *gtk.Button,
        theme_hint: *gtk.Label,
        theme_stack: *gtk.Stack,
        theme_list: *gtk.ListView,
        theme_empty: *gtk.Label,

        state: State,

        pub var offset: c_int = 0;
    };

    /// Everything besides the template children.
    const State = struct {
        alloc: Allocator,

        /// Owns the shell choices and other strings that live as long as
        /// the dialog.
        arena: ArenaAllocator,

        /// The language of the dialog text.
        lang: gx.i18n.Language = .default,

        /// True while the widgets are filled in, so their change handlers
        /// do not record changes.
        loading: bool = true,

        /// Set when disposing starts. Signal handlers and timers then
        /// leave the template children alone, which disposing clears.
        disposed: bool = false,

        /// Whether the configuration is loaded with the Ghostty GX layers.
        /// Without them (`GHOSTTY_GX_DEFAULTS=0`) nothing can be changed.
        layered: bool = true,
        layering_banners: [6]?*adw.Banner = @splat(null),

        /// The configuration layers, read when the dialog opens and again
        /// after every save; previews are built from them in memory. Null
        /// when they cannot be read, and then previews load from disk.
        layers: ?Layers = null,

        /// The in-app notifications of the configuration when the dialog
        /// opened; reloads keep them except the reload toast.
        notifications: CoreConfig.AppNotifications = .{},

        /// Changes not saved yet, and the timer that saves them.
        changes: settings_map.Changes,
        save_source: ?c_uint = null,
        apply_pending: bool = false,
        pending_sync: Sync = .{},

        /// The last toast the dialog showed, which the next one replaces.
        toast: ?*adw.Toast = null,

        /// The handler of the application's `notify::config`.
        config_handler: c_ulong = 0,

        /// The values of the combo rows, kept across language changes,
        /// which rebuild their models.
        material: settings_map.Material = .solid,
        opacity: OpacityValue = .{ .choice = .automatic },
        cursor_style: settings_map.CursorStyle = .block,
        padding: PaddingValue = .{ .preset = .default },
        right_click: CoreConfig.RightClickAction = .@"context-menu",
        close_confirmation: CoreConfig.ConfirmCloseSurface = .true,

        /// The configured font families, whose fallbacks a new first
        /// family keeps (`settings_map.fontFamilies`).
        font_families: []const []const u8 = &.{},

        /// The listed themes, the directories they are read from and the
        /// swatches read so far.
        themes: ?settings_map.ThemeList = null,
        theme_dirs: []const []const u8 = &.{},
        swatches: theme_swatch.Cache = .{},

        /// The saved themes.
        saved_light: ?[:0]u8 = null,
        saved_dark: ?[:0]u8 = null,

        /// What the theme list chooses, the theme indices it shows in
        /// order, and its model.
        target: ThemeTarget = .single,
        visible: std.ArrayList(u32) = .empty,
        theme_model: ?*gtk.StringList = null,
        theme_selection: ?*gtk.SingleSelection = null,

        /// The rows of the theme list that show a theme.
        bound: std.ArrayList(*gtk.ListItem) = .empty,

        /// The swatches of the theme rows of the appearance page.
        row_swatches: [3]?*ThemeSwatch = @splat(null),

        /// True while the theme selection is changed by the dialog rather
        /// than by the user, which does not preview it.
        selecting: bool = false,

        /// Whether a theme preview is applied, and the timer that
        /// previews the selection.
        previewing: bool = false,
        preview_source: ?c_uint = null,

        /// The shell choices, filled in when the shell page is first
        /// shown; a choice's index is its position in the shell row.
        shells_loaded: bool = false,
        shells: []const Shell = &.{},
        shell: usize = 0,

        /// The command new terminals run when the overlay sets none.
        default_command: [:0]const u8 = "",

        /// The herdr executable, if herdr was detected.
        herdr: ?[:0]const u8 = null,

        /// The window that keeps the dialog (`kept_dialogs`); none for a
        /// dialog in a window of its own, which every opening builds anew.
        owner: WeakRef(gtk.Window) = .empty,

        /// Whether the dialog is presented: from opening until it closes.
        shown: bool = false,

        /// Set while `apply` updates the configuration, which tells the
        /// dialog's own changes from a reload.
        applying: bool = false,

        /// Set by a configuration change the dialog did not make (a reload,
        /// another settings UI): the next opening builds a new dialog.
        stale: bool = false,

        /// The UI language and theme the dialog was built with.
        built: Built = .{ .lang = .default, .theme = 0 },
    };

    const Shell = struct {
        /// The `command` value, or null to remove `command` from the
        /// overlay.
        command: ?[:0]const u8,

        /// The GX Zsh executable, when the choice is GX Zsh.
        gx_zsh: ?[:0]const u8 = null,

        label: union(enum) {
            system_default,
            /// A detected profile: the msgid of its name and the `{name}`
            /// it fills in.
            profile: struct { msgid: [:0]const u8, name: []const u8 },
            /// A name that is not translated.
            literal: [:0]const u8,
            /// A `command` the settings UI did not write.
            custom: [:0]const u8,
        },
    };

    //---------------------------------------------------------------
    // Opening

    /// Shows the settings dialog over the active window of `app`, or
    /// brings the open one to the front.
    pub fn show(app: *Application) void {
        showPage(app, null);
    }

    /// Like `show`, and shows `page` (`gx:settings_page:<page>`); without
    /// a page, the dialog starts on the page the last one was closed on.
    pub fn showPage(app: *Application, page: ?settings_map.Page) void {
        var timing = open_perf.begin(.settings);
        if (!adw_version.supportsDialogs()) {
            log.warn("the settings dialog needs libadwaita 1.5 or newer", .{});
            return;
        }

        const window = app.as(gtk.Application).getActiveWindow();
        const parent: ?*gtk.Widget = if (window) |value| value.as(gtk.Widget) else null;
        const host: ?*gtk.Window = if (window) |value|
            if (dialog_cache.hostsDialogs(value)) value else null
        else
            null;

        if (open_dialog.get()) |shown| {
            defer shown.unref();
            if (shown.isShownIn(host)) {
                open_perf.lap(&timing, .prepare);
                if (page) |name| shown.showSettingsPage(name);
                open_perf.lap(&timing, .layout);
                open_perf.watch(shown.as(gtk.Widget), timing);
                shown.as(adw.Dialog).present(parent);
                open_perf.presented(shown.as(gtk.Widget), timing);
                return;
            }
            shown.closeElsewhere();
        }

        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();
        const reused: ?*Self = find: {
            const value = host orelse break :find null;
            const candidate = kept_dialogs.get(value) orelse break :find null;
            const st = &candidate.private().state;
            if (upToDate(st.built, st.stale, config)) break :find candidate;
            kept_dialogs.drop(value);
            break :find null;
        };
        open_perf.lap(&timing, .prepare);

        const dialog: *Self = if (reused) |candidate| candidate else build: {
            const created = gobject.ext.newInstance(Self, .{});
            open_perf.lap(&timing, .create);
            created.load(app);
            if (page orelse last_page) |name| created.showSettingsPage(name);
            if (host) |value| {
                kept_dialogs.keep(value, created);
                created.private().state.owner.set(value);
            }
            break :build created;
        };
        if (reused != null) dialog.reopen(config, page);
        dialog.private().state.shown = true;
        open_dialog.set(dialog);
        open_perf.lap(&timing, .layout);
        open_perf.watch(dialog.as(gtk.Widget), timing);
        dialog.as(adw.Dialog).present(parent);
        open_perf.presented(dialog.as(gtk.Widget), timing);
    }

    /// Whether the dialog shows in `host`, the window that keeps it (null:
    /// in a window of its own).
    fn isShownIn(self: *Self, host: ?*gtk.Window) bool {
        const owner = self.private().state.owner.get();
        defer if (owner) |value| value.unref();
        return owner == host;
    }

    /// Closes the dialog shown in another window, which saves its changes
    /// first (a failed save keeps it open). A dialog whose window went away
    /// is no longer shown.
    fn closeElsewhere(self: *Self) void {
        if (self.as(gtk.Widget).getRoot() == null) {
            self.private().state.shown = false;
            open_dialog.set(null);
            return;
        }
        _ = self.as(adw.Dialog).close();
    }

    /// Whether a dialog built with `built` still shows what a new one would
    /// show for `config`: no reload came since (`stale`), and neither the
    /// UI language nor the theme changed.
    fn upToDate(built: Built, stale: bool, config: *const CoreConfig) bool {
        const now: Built = .of(config);
        return !stale and built.lang == now.lang and built.theme == now.theme;
    }

    /// Shows a kept dialog again the way a new one opens: on `page` (else
    /// the page the last dialog was closed on), without the theme list or a
    /// toast, with the values of `config` (text typed and not applied goes),
    /// scrolled to the top and with the first control focused. A failed
    /// save keeps the dialog open, so a closed one has no changes to drop.
    fn reopen(self: *Self, config: *const CoreConfig, page: ?settings_map.Page) void {
        const priv = self.private();
        self.dismissToast();
        if (page orelse last_page) |name|
            self.showSettingsPage(name)
        else
            _ = self.as(adw.PreferencesDialog).popSubpage();
        self.syncValues(config, .{ .font_family = true });
        for ([_]*adw.PreferencesPage{
            priv.language_page,
            priv.appearance_page,
            priv.font_page,
            priv.interaction_page,
            priv.shell_page,
            priv.about_page,
        }) |preferences| preferences.scrollToTop();
        self.as(adw.Dialog).setFocus(null);
    }

    /// Handles opening the configuration in the system editor (the
    /// `.os_open` target of `open_config`): with `gx-open-config-ui =
    /// settings` this shows the settings dialog and returns true; it
    /// returns false when the caller should open the editor.
    pub fn openConfig(app: *Application) bool {
        if (!adw_version.supportsDialogs()) return false;
        const config = app.getConfig();
        defer config.unref();
        switch (config.get().@"gx-open-config-ui") {
            .editor => return false,
            .settings => {},
        }
        show(app);
        return true;
    }

    /// The `app.gx-settings` action.
    pub fn actionShow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        app: *Application,
    ) callconv(.c) void {
        show(app);
    }

    fn showSettingsPage(self: *Self, page: settings_map.Page) void {
        const dialog = self.as(adw.PreferencesDialog);
        _ = dialog.popSubpage();
        dialog.setVisiblePageName(@tagName(page));
        if (page == .shell) self.loadShells();
    }

    //---------------------------------------------------------------
    // Filling in the widgets

    fn load(self: *Self, app: *Application) void {
        const priv = self.private();
        const st = &priv.state;
        var steps: open_perf.Steps = .begin();
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();

        st.lang = gx.i18n.resolve(config.language);
        st.built = .of(config);
        st.notifications = config.@"app-notifications";
        st.layered = gx.config_layers.enabled(st.alloc);
        if (st.layered) self.reloadLayers();
        steps.step("settings.load.layers");
        st.loading = true;
        defer st.loading = false;

        self.setUpThemes();
        steps.step("settings.load.themes");
        self.setUpFontChooser();
        steps.step("settings.load.fonts");
        self.addRowSwatches();
        self.syncValues(config, .{ .font_family = true });
        steps.step("settings.load.values");
        self.loadAbout();
        if (!st.layered) self.disableEditing();
        self.applyTexts();
        steps.step("settings.load.texts");

        st.config_handler = gobject.Object.signals.notify.connect(
            app,
            *Self,
            appConfigChanged,
            self,
            .{ .detail = "config" },
        );
    }

    /// Reads the configuration layers again, so builds see the files as
    /// they are now.
    fn reloadLayers(self: *Self) void {
        const st = &self.private().state;
        if (st.layers) |*layers| layers.deinit();
        _ = @import("defaults.zig").sampleSystemCursorBlink();
        st.layers = Layers.load(st.alloc) catch |err| layers: {
            log.warn("cannot read the configuration layers err={}", .{err});
            break :layers null;
        };
    }

    /// Whether a layer above the Ghostty GX defaults sets `key`. Without
    /// the layers that is unknown, and every value counts as configured.
    fn configured(self: *Self, key: []const u8) bool {
        const layers = &(self.private().state.layers orelse return true);
        const layer = layers.provenance(key) orelse return false;
        return layer != .defaults;
    }

    /// Whether the command line sets one of `keys`, which then overrides
    /// what the dialog saves.
    fn fromCli(self: *Self, keys: []const []const u8) bool {
        const layers = &(self.private().state.layers orelse return false);
        for (keys) |key| {
            if (layers.provenance(key) == .cli) return true;
        }
        return false;
    }

    /// Whether the settings overlay sets `key`, which "Reset to Default"
    /// then removes.
    fn overlaySets(self: *Self, key: []const u8) bool {
        const st = &self.private().state;
        for (st.changes.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.values.len > 0;
        }
        const layers = &(st.layers orelse return false);
        return layers.sets(.overlay, key);
    }

    const Sync = struct {
        /// Whether to show the configured font family, which replaces
        /// what is typed in the font family row.
        font_family: bool = false,

        /// Whether `theme` is the saved theme rather than a preview.
        theme: bool = true,

        /// Whether a saved `theme` changed while another theme stays
        /// previewed, so the saved theme is read from the saved layers.
        saved_theme: bool = false,
    };

    /// What saving the recorded `changes` refreshes. A failed Apply keeps
    /// its `theme` change recorded and the theme previewed until a later
    /// save writes it (Retry, or any other change), or reverting drops it
    /// (`revertChanges`): when that `theme` is the previewed value it is no
    /// longer a preview (R3-Settings.04); while another theme stays
    /// previewed, the saved theme is read from the saved layers instead of
    /// the applied configuration (`appliedSync`).
    const SaveEffects = struct {
        sync: Sync,
        end_preview: bool = false,
    };

    fn saveEffects(
        changes: []const settings_map.Changes.Entry,
        previewing: bool,
        previewed: ?[]const u8,
        pending: ?Sync,
    ) SaveEffects {
        var effects: SaveEffects = .{ .sync = pending orelse .{ .theme = !previewing } };
        for (changes) |entry| {
            if (std.mem.eql(u8, entry.key, "font-family")) effects.sync.font_family = true;
            if (!previewing or !std.mem.eql(u8, entry.key, "theme")) continue;
            const same = if (previewed) |value|
                entry.values.len == 1 and std.mem.eql(u8, entry.values[0], value)
            else
                false;
            if (same) {
                effects.end_preview = true;
                effects.sync.theme = true;
                effects.sync.saved_theme = false;
            } else if (!effects.end_preview) {
                effects.sync.saved_theme = true;
            }
        }
        return effects;
    }

    /// How applying the saved settings refreshes the theme rows. While a
    /// theme stays previewed the applied configuration has the preview, so
    /// a saved theme is read from the saved layers (`saved_theme`) rather
    /// than shown from it: after a save whose applying failed, Retry while
    /// another theme is previewed would otherwise show that theme as
    /// saved. Without a preview the applied configuration has the saved
    /// theme.
    fn appliedSync(sync: Sync, previewing: bool) Sync {
        var applied = sync;
        if (previewing) {
            applied.saved_theme = sync.theme or sync.saved_theme;
            applied.theme = false;
        } else {
            applied.theme = true;
            applied.saved_theme = false;
        }
        return applied;
    }

    /// Drops the `theme` change a failed Apply left recorded, for Revert
    /// and going back from the theme list (D-15): the dialog shows the
    /// saved theme again, so no later save (Retry, another change or
    /// closing) may write the reverted one. The other recorded changes
    /// stay for their retry. Returns whether a change was dropped.
    fn dropThemeChange(changes: *settings_map.Changes) bool {
        for (changes.entries.items, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry.key, "theme")) continue;
            _ = changes.entries.orderedRemove(i);
            return true;
        }
        return false;
    }

    /// What reverting the theme list does with what failed saves left
    /// (D-15). Revert, going back and selecting the saved theme again all
    /// revert.
    const Revert = struct {
        /// The unsaved `theme` change was dropped, so no later save
        /// writes it.
        dropped: bool,
        /// Nothing is left to save: the retry toast goes and the dialog
        /// can close again, even while the settings folder stays read-only.
        settled: bool,
        /// A save wrote the theme already and only applying it failed:
        /// the saved configuration is applied again and shown as saved,
        /// rather than as an undone change.
        reapply: bool,
    };

    fn revertChanges(changes: *settings_map.Changes, apply_pending: bool) Revert {
        const dropped = dropThemeChange(changes);
        return .{
            .dropped = dropped,
            .settled = dropped and changes.isEmpty() and !apply_pending,
            .reapply = apply_pending,
        };
    }

    /// Shows the values of `config`, without recording them as changes.
    fn syncValues(self: *Self, config: *const CoreConfig, sync: Sync) void {
        const priv = self.private();
        const st = &priv.state;
        const loading = st.loading;
        st.loading = true;
        defer st.loading = loading;

        if (sync.theme) self.setSavedTheme(config.theme) else if (sync.saved_theme) self.refreshSavedTheme();

        const opacity = config.@"background-opacity";
        const material = settings_map.Material.fromConfig(opacity, config.@"background-blur".enabled());
        const opacity_value: OpacityValue = if (settings_map.Opacity.fromConfig(opacity, self.configured("background-opacity"))) |choice|
            .{ .choice = choice }
        else
            .{ .custom = opacity };
        const padding_x = config.@"window-padding-x";
        const padding_y = config.@"window-padding-y";
        const padding_value: PaddingValue = if (settings_map.Padding.fromConfig(
            padding_x,
            padding_y,
            self.configured("window-padding-x") or self.configured("window-padding-y"),
        )) |preset| .{ .preset = preset } else .{ .custom = .{ .x = padding_x, .y = padding_y } };

        const combos_changed = st.material != material or
            !st.opacity.eql(opacity_value) or
            st.cursor_style != config.@"cursor-style" or
            !st.padding.eql(padding_value) or
            st.right_click != config.@"right-click-action" or
            st.close_confirmation != config.@"confirm-close-surface";
        st.material = material;
        st.opacity = opacity_value;
        st.cursor_style = config.@"cursor-style";
        st.padding = padding_value;
        st.right_click = config.@"right-click-action";
        st.close_confirmation = config.@"confirm-close-surface";
        if (combos_changed) self.fillCombos();

        setSwitch(priv.cursor_blink_row, config.@"cursor-style-blink" orelse true);
        setSwitch(priv.scrollbar_row, config.scrollbar == .system);
        setSwitch(priv.focus_follows_mouse_row, config.@"focus-follows-mouse");
        setSwitch(priv.ctrl_scroll_zoom_row, config.@"gx-ctrl-scroll-zoom");
        priv.ctrl_scroll_zoom_reset_button.as(gtk.Widget).setSensitive(@intFromBool(self.overlaySets(settings_map.ctrl_scroll_zoom.key)));
        const rows = self.bellRows();
        inline for (settings_map.bell_features, 0..) |feature, i| {
            rows[i].as(gtk.Widget).setVisible(@intFromBool(feature.supports(.gtk)));
            setSwitch(rows[i], @field(config.@"bell-features", feature.field));
        }

        const size: f64 = settings_map.FontSize.normalize(config.@"font-size");
        if (priv.font_size_row.getValue() != size) priv.font_size_row.setValue(size);
        priv.font_size_reset_button.as(gtk.Widget).setSensitive(@intFromBool(self.overlaySets("font-size")));

        if (sync.font_family) {
            const arena = st.arena.allocator();
            const families = config.@"font-family".list.items;
            var copies: std.ArrayList([]const u8) = .empty;
            for (families) |family| copies.append(arena, arena.dupe(u8, family) catch break) catch break;
            st.font_families = copies.items;
            const family = if (families.len > 0) families[0] else "";
            priv.font_family_row.as(gtk.Editable).setText(family);
            const description = pango_font_description_new();
            defer pango_font_description_free(description);
            pango_font_description_set_family(description, if (family.len > 0) family else "monospace");
            priv.font_choose_button.setFontDesc(@ptrCast(description));
        }
        priv.font_clear_button.as(gtk.Widget).setSensitive(@intFromBool(self.overlaySets("font-family")));
        if (st.shells_loaded and st.shell < st.shells.len and st.shells[st.shell].command == null) {
            st.default_command = if (config.command) |command| command.string(st.arena.allocator()) catch "" else "";
        }

        self.updateNotes(config);
    }

    fn setSwitch(row: *adw.SwitchRow, on: bool) void {
        if ((row.getActive() != 0) != on) row.setActive(@intFromBool(on));
    }

    /// Remembers the saved `theme` and shows it on the theme rows.
    fn setSavedTheme(self: *Self, theme: ?CoreConfig.Theme) void {
        const priv = self.private();
        const st = &priv.state;
        for ([_]*?[:0]u8{ &st.saved_light, &st.saved_dark }) |field| {
            if (field.*) |name| st.alloc.free(name);
            field.* = null;
        }
        if (settings_map.ThemePair.fromConfig(theme)) |pair| {
            st.saved_light = st.alloc.dupeZ(u8, pair.light) catch null;
            st.saved_dark = st.alloc.dupeZ(u8, pair.dark) catch null;
        }

        const pair = self.isThemePair();
        priv.theme_row.as(gtk.Widget).setVisible(@intFromBool(!pair));
        priv.theme_light_row.as(gtk.Widget).setVisible(@intFromBool(pair));
        priv.theme_dark_row.as(gtk.Widget).setVisible(@intFromBool(pair));
        self.updateThemeGroup();
        for (self.themeRows(), st.row_swatches) |row, swatch_| {
            const swatch = swatch_ orelse continue;
            const name = self.savedTheme(self.rowTarget(row)) orelse {
                swatch.as(gtk.Widget).setVisible(0);
                continue;
            };
            swatch.set(self.swatchOf(name));
            swatch.as(gtk.Widget).setVisible(1);
        }
        self.refreshThemeChecks();
        self.updateThemeButtons();
    }

    /// Shows the theme the saved layers configure while another theme
    /// stays previewed (the applied configuration has the preview).
    fn refreshSavedTheme(self: *Self) void {
        const st = &self.private().state;
        var saved = (if (st.layers) |*layers|
            layers.build(st.alloc, &.{})
        else
            gx.config_layers.loadWithOverrides(st.alloc, &.{})) catch |err| {
            log.warn("cannot read the saved theme err={}", .{err});
            return;
        };
        defer saved.deinit();
        self.setSavedTheme(saved.theme);
    }

    fn isThemePair(self: *Self) bool {
        const st = &self.private().state;
        const light = st.saved_light orelse return false;
        const dark = st.saved_dark orelse return false;
        return !std.mem.eql(u8, light, dark);
    }

    /// Explains the two theme rows of a light and dark pair.
    fn updateThemeGroup(self: *Self) void {
        const priv = self.private();
        priv.theme_group.setDescription(if (self.isThemePair()) self.tr(msg.theme_pair_hint) else null);
    }

    /// The saved theme that `target` chooses.
    fn savedTheme(self: *Self, target: ThemeTarget) ?[:0]const u8 {
        const st = &self.private().state;
        return switch (target) {
            .single, .light => st.saved_light,
            .dark => st.saved_dark,
        };
    }

    fn themeRows(self: *Self) [3]*adw.ActionRow {
        const priv = self.private();
        return .{ priv.theme_row, priv.theme_light_row, priv.theme_dark_row };
    }

    fn rowTarget(self: *Self, row: *adw.ActionRow) ThemeTarget {
        const priv = self.private();
        if (row == priv.theme_light_row) return .light;
        if (row == priv.theme_dark_row) return .dark;
        return .single;
    }

    fn addRowSwatches(self: *Self) void {
        const st = &self.private().state;
        for (self.themeRows(), &st.row_swatches) |row, *slot| {
            const swatch = ThemeSwatch.new();
            row.addPrefix(swatch.as(gtk.Widget));
            slot.* = swatch;
        }
    }

    /// Lists the themes and sets up the model and rows of the theme list.
    fn setUpThemes(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const arena = st.arena.allocator();

        var dirs: std.ArrayList([]const u8) = .empty;
        var it: themepkg.LocationIterator = .{ .arena_alloc = arena };
        while (it.next() catch null) |location| {
            dirs.append(arena, location.dir) catch break;
        }
        st.theme_dirs = dirs.items;
        st.themes = settings_map.listThemes(st.alloc, global.io(), dirs.items) catch |err| list: {
            log.warn("cannot list the themes err={}", .{err});
            break :list null;
        };

        const model = gtk.StringList.new(null);
        const selection = gtk.SingleSelection.new(model.as(gio.ListModel));
        selection.setAutoselect(0);
        selection.setCanUnselect(1);
        st.theme_model = model;
        st.theme_selection = selection;
        _ = gobject.Object.signals.notify.connect(
            selection,
            *Self,
            themeSelectionChanged,
            self,
            .{ .detail = "selected" },
        );

        const factory = gtk.SignalListItemFactory.new();
        defer factory.unref();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Self, themeItemSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Self, themeItemBind, self, .{});
        _ = gtk.SignalListItemFactory.signals.unbind.connect(factory, *Self, themeItemUnbind, self, .{});

        priv.theme_list.setModel(selection.as(gtk.SelectionModel));
        priv.theme_list.setFactory(factory.as(gtk.ListItemFactory));

        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Self, themeSearchKeyPressed, self, .{});
        priv.theme_search.as(gtk.Widget).addController(keys.as(gtk.EventController));
        priv.theme_search.setKeyCaptureWidget(priv.theme_list.as(gtk.Widget));
    }

    /// The combo rows whose models carry translated labels, built again
    /// for the current language and values.
    fn fillCombos(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const loading = st.loading;
        st.loading = true;
        defer st.loading = loading;

        {
            const model = gtk.StringList.new(null);
            defer model.unref();
            for (languages) |lang| model.append(lang.nativeName());
            priv.language_row.setModel(model.as(gio.ListModel));
            priv.language_row.setSelected(@intCast(std.mem.indexOfScalar(gx.i18n.Language, languages, st.lang) orelse 0));
        }

        {
            const model = gtk.StringList.new(null);
            defer model.unref();
            for (materials) |material| model.append(self.tr(material.label()));
            priv.material_row.setModel(model.as(gio.ListModel));
            priv.material_row.setSelected(@intCast(std.mem.indexOfScalar(settings_map.Material, materials, st.material) orelse 0));
        }

        {
            const model = gtk.StringList.new(null);
            defer model.unref();
            for (opacities) |choice| model.append(self.tr(choice.label()));
            var selected: usize = 0;
            switch (st.opacity) {
                .choice => |choice| selected = std.mem.indexOfScalar(settings_map.Opacity, opacities, choice) orelse 0,
                .custom => |value| {
                    var buf: [16]u8 = undefined;
                    const percent = opacityText(&buf, value) catch "?";
                    self.appendCustom(model, percent);
                    selected = opacities.len;
                },
            }
            priv.opacity_row.setModel(model.as(gio.ListModel));
            priv.opacity_row.setSelected(@intCast(selected));
        }

        self.fillChoices(settings_map.CursorStyle, priv.cursor_style_row, &settings_map.cursor_style_choices, st.cursor_style);

        {
            const model = gtk.StringList.new(null);
            defer model.unref();
            for (paddings) |preset| model.append(self.tr(preset.label()));
            var selected: usize = 0;
            switch (st.padding) {
                .preset => |preset| selected = std.mem.indexOfScalar(settings_map.Padding, paddings, preset) orelse 0,
                .custom => |custom| {
                    var x_buf: [32]u8 = undefined;
                    var y_buf: [32]u8 = undefined;
                    var buf: [80]u8 = undefined;
                    const value = std.fmt.bufPrint(&buf, "{s} × {s}", .{
                        paddingValue(&x_buf, custom.x) catch "?",
                        paddingValue(&y_buf, custom.y) catch "?",
                    }) catch "?";
                    self.appendCustom(model, value);
                    selected = paddings.len;
                },
            }
            priv.padding_row.setModel(model.as(gio.ListModel));
            priv.padding_row.setSelected(@intCast(selected));
        }

        self.fillChoices(CoreConfig.RightClickAction, priv.right_click_row, &settings_map.right_click_choices, st.right_click);
        self.fillChoices(CoreConfig.ConfirmCloseSurface, priv.close_confirmation_row, &settings_map.close_confirmation_choices, st.close_confirmation);
        self.fillShells();
    }

    fn appendCustom(self: *Self, model: *gtk.StringList, value: []const u8) void {
        const alloc = self.private().state.alloc;
        const label = self.fill(alloc, text.custom_value, .{ .value = value }) catch return;
        defer alloc.free(label);
        model.append(label);
    }

    fn fillChoices(
        self: *Self,
        comptime T: type,
        row: *adw.ComboRow,
        choices: []const settings_map.Choice(T),
        value: T,
    ) void {
        const model = gtk.StringList.new(null);
        defer model.unref();
        for (choices) |choice| model.append(self.tr(choice.label));
        row.setModel(model.as(gio.ListModel));
        row.setSelected(@intCast(settings_map.choiceIndex(T, choices, value) orelse 0));
    }

    fn fillShells(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const model = gtk.StringList.new(null);
        defer model.unref();
        for (st.shells) |shell| {
            const alloc = st.alloc;
            const filled: ?[:0]u8 = switch (shell.label) {
                .system_default, .literal => null,
                .profile => |profile| self.fill(alloc, profile.msgid, .{ .name = profile.name }) catch continue,
                .custom => |command| self.fill(alloc, msg.custom_command, .{ .command = command }) catch continue,
            };
            defer if (filled) |value| alloc.free(value);
            const name: [:0]const u8 = switch (shell.label) {
                .system_default => self.tr(msg.system_default),
                .literal => |literal| literal,
                .profile, .custom => filled.?,
            };
            model.append(name);
        }
        priv.shell_row.setModel(model.as(gio.ListModel));
        if (st.shells.len > 0) priv.shell_row.setSelected(@intCast(@min(st.shell, st.shells.len - 1)));
        self.updateShellSubtitle();
    }

    /// Detects the shells and fills in the shell row, once: detecting
    /// searches `PATH`, so it waits until the shell page is shown.
    fn loadShells(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        if (st.shells_loaded or st.disposed) return;
        st.shells_loaded = true;
        const loading = st.loading;
        st.loading = true;
        defer st.loading = loading;

        const app = Application.default();
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();
        const arena = st.arena.allocator();

        if (config.command) |command| {
            st.default_command = command.string(arena) catch "";
        }
        const overlay_command = self.overlayValue(arena, "command");

        var shells: std.ArrayList(Shell) = .empty;
        shells.append(arena, .{ .command = null, .label = .system_default }) catch return;
        var selected: ?usize = if (overlay_command == null) 0 else null;

        var custom: std.ArrayList(gx.profiles.Custom) = .empty;
        const launch = config.@"gx-launch-profile".map;
        for (launch.keys(), launch.values()) |name, command| {
            custom.append(arena, .{ .name = name, .command = command }) catch break;
        }
        var env = global.environMap() catch |err| env: {
            log.warn("cannot read the environment to detect shells err={}", .{err});
            break :env std.process.Environ.Map.init(st.alloc);
        };
        defer env.deinit();
        if (gx.profiles.detectSystem(st.alloc, global.io(), &env, custom.items)) |list_| {
            var list = list_;
            defer list.deinit();
            for (list.profiles) |profile| {
                const command = settings_map.profileCommand(arena, profile, gx.profiles.Platform.native) catch continue;
                const exe: ?[:0]const u8 = switch (profile.command) {
                    .argv => |argv| if (argv.len > 0) arena.dupeZ(u8, argv[0]) catch null else null,
                    .command_line => null,
                };
                if (profile.kind == .herdr) st.herdr = exe;
                const label: @FieldType(Shell, "label") = if (profile.kind == .custom)
                    .{ .literal = arena.dupeZ(u8, profile.name) catch continue }
                else
                    .{ .profile = .{
                        .msgid = arena.dupeZ(u8, profile.name) catch continue,
                        .name = arena.dupe(u8, profile.name_arg orelse "") catch continue,
                    } };
                shells.append(arena, .{
                    .command = command,
                    .gx_zsh = if (profile.kind == .gx_zsh) exe else null,
                    .label = label,
                }) catch break;
                if (selected == null and std.mem.eql(u8, overlay_command.?, command)) {
                    selected = shells.items.len - 1;
                }
            }
        } else |err| {
            log.warn("cannot detect the shells err={}", .{err});
        }

        if (selected == null) custom: {
            // A command the settings UI did not write.
            const command = arena.dupeZ(u8, overlay_command.?) catch break :custom;
            shells.append(arena, .{ .command = command, .label = .{ .custom = command } }) catch break :custom;
            selected = shells.items.len - 1;
        }

        st.shells = shells.items;
        st.shell = selected orelse 0;
        self.fillShells();
    }

    fn loadAbout(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const arena = st.arena.allocator();

        if (file_load.preferredDefaultFilePath(arena)) |path| {
            if (arena.dupeZ(u8, path)) |path_z| priv.config_path_row.setSubtitle(path_z) else |_| {}
        } else |err| {
            log.warn("cannot locate the configuration file err={}", .{err});
        }

        if (gx.config_layers.overlayPath(arena)) |path| {
            if (arena.dupeZ(u8, path)) |path_z| priv.settings_path_row.setSubtitle(path_z) else |_| {}
        } else |err| {
            log.warn("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
        }
    }

    /// Without the Ghostty GX layers the overlay is not loaded: every
    /// page says so and the settings cannot be changed.
    fn disableEditing(self: *Self) void {
        const priv = self.private();
        for ([_]*adw.PreferencesGroup{
            priv.language_group,
            priv.theme_group,
            priv.material_group,
            priv.cursor_group,
            priv.padding_group,
            priv.font_size_group,
            priv.font_family_group,
            priv.interaction_group,
            priv.bell_group,
            priv.shell_group,
        }) |group| group.as(gtk.Widget).setSensitive(0);

        const pages = [_]struct { *adw.PreferencesPage, []const *adw.PreferencesGroup }{
            .{ priv.language_page, &.{priv.language_group} },
            .{ priv.appearance_page, &.{ priv.theme_group, priv.material_group, priv.cursor_group, priv.padding_group } },
            .{ priv.font_page, &.{ priv.font_size_group, priv.font_family_group } },
            .{ priv.interaction_page, &.{ priv.interaction_group, priv.bell_group } },
            .{ priv.shell_page, &.{priv.shell_group} },
            .{ priv.about_page, &.{ priv.about_group, priv.settings_file_group } },
        };
        for (pages, &priv.state.layering_banners) |entry, *slot| {
            const page, const groups = entry;
            for (groups) |group| {
                group.ref();
                page.remove(group);
            }
            const group = adw.PreferencesGroup.new();
            const banner = adw.Banner.new("");
            banner.setUseMarkup(0);
            banner.setRevealed(1);
            _ = adw.Banner.signals.button_clicked.connect(banner, *Self, bannerOpenClicked, self, .{});
            group.add(banner.as(gtk.Widget));
            page.add(group);
            slot.* = banner;
            for (groups) |existing| {
                page.add(existing);
                existing.unref();
            }
        }
    }

    fn bannerOpenClicked(_: *adw.Banner, self: *Self) callconv(.c) void {
        openConfigClicked(self.private().open_config_button, self);
    }

    fn bellRows(self: *Self) [settings_map.bell_features.len]*adw.SwitchRow {
        const priv = self.private();
        return .{
            priv.bell_system_row,
            priv.bell_audio_row,
            priv.bell_attention_row,
            priv.bell_title_row,
            priv.bell_border_row,
        };
    }

    comptime {
        const fields = [_][]const u8{ "system", "audio", "attention", "title", "border" };
        for (settings_map.bell_features, fields) |feature, field| {
            if (!std.mem.eql(u8, feature.field, field)) @compileError("bellRows is out of order");
        }
    }

    //---------------------------------------------------------------
    // Text

    /// Translates `msgid` into the language of the dialog.
    fn tr(self: *Self, msgid: [:0]const u8) [:0]const u8 {
        return gx.i18n.lookup(self.private().state.lang, msgid) orelse msgid;
    }

    /// Translates `msgid` and fills in its placeholders.
    fn fill(self: *Self, alloc: Allocator, msgid: [:0]const u8, args: anytype) Allocator.Error![:0]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        gx.i18n.format(&out.writer, self.tr(msgid), args) catch return error.OutOfMemory;
        return try out.toOwnedSliceSentinel(0);
    }

    /// Sets every text of the dialog in its language.
    fn applyTexts(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const loading = st.loading;
        st.loading = true;
        defer st.loading = loading;

        self.as(adw.Dialog).setTitle(self.tr(msg.settings));
        const pages = [_]struct { *adw.PreferencesPage, settings_map.Page }{
            .{ priv.language_page, .language },
            .{ priv.appearance_page, .appearance },
            .{ priv.font_page, .font },
            .{ priv.interaction_page, .interaction },
            .{ priv.shell_page, .shell },
            .{ priv.about_page, .about },
        };
        for (pages) |entry| {
            const page, const name = entry;
            page.setTitle(self.tr(settings_map.pageLabel(name)));
        }
        if (!st.layered) {
            if (self.fill(st.alloc, text.layering_off, .{ .variable = gx.config_layers.disable_env })) |notice| {
                defer st.alloc.free(notice);
                for (st.layering_banners) |slot| {
                    const banner = slot orelse continue;
                    banner.setTitle(notice);
                    banner.setButtonLabel(self.tr(msg.open_config_file));
                }
            } else |_| {}
        }

        priv.language_group.setDescription(self.tr(msg.changes_saved));
        setTitle(priv.language_row, self.tr(msg.interface_language));

        priv.theme_group.setTitle(self.tr(msg.theme));
        setTitle(priv.theme_row, self.tr(msg.theme));
        setTitle(priv.theme_light_row, self.tr(msg.light_theme));
        setTitle(priv.theme_dark_row, self.tr(msg.dark_theme));
        priv.theme_search.setPlaceholderText(self.tr(msg.search_themes));
        priv.theme_hint.setText(self.tr(msg.theme_hint));
        priv.theme_empty.setText(self.tr(msg.no_themes));
        priv.theme_apply_button.setLabel(self.tr(msg.apply));
        priv.theme_revert_button.setLabel(self.tr(text.revert));
        priv.theme_list.as(gtk.Accessible).updateProperty(.label, self.tr(msg.theme).ptr, @as(c_int, -1));
        priv.theme_subpage.setTitle(self.tr(themeTitle(st.target)));

        priv.material_group.setDescription(self.tr(msg.material_hint));
        setTitle(priv.material_row, self.tr(msg.window_material));
        setTitle(priv.opacity_row, self.tr(msg.opacity));

        priv.cursor_group.setTitle(self.tr(msg.cursor));
        setTitle(priv.cursor_style_row, self.tr(msg.cursor_style));
        setTitle(priv.cursor_blink_row, self.tr(settings_map.cursor_blink.label));

        setTitle(priv.padding_row, self.tr(msg.padding));

        setTitle(priv.font_size_row, self.tr(msg.font_size));
        setIconLabel(priv.font_size_reset_button, self.tr(msg.reset_to_default));
        priv.font_family_group.setDescription(self.tr(msg.font_family_hint));
        setTitle(priv.font_choice_row, self.tr(text.choose_font));
        setTitle(priv.font_family_row, self.tr(msg.font_family));
        priv.font_choose_button.as(gtk.Accessible).updateProperty(.label, self.tr(text.choose_font).ptr, @as(c_int, -1));
        if (priv.font_choose_button.getDialog()) |dialog| dialog.setTitle(self.tr(msg.font_family));
        setIconLabel(priv.font_clear_button, self.tr(text.default_font));

        setTitle(priv.right_click_row, self.tr(msg.right_click));
        setTitle(priv.scrollbar_row, self.tr(msg.show_scrollbar));
        setTitle(priv.close_confirmation_row, self.tr(msg.close_confirmation));
        setTitle(priv.focus_follows_mouse_row, self.tr(settings_map.focus_follows_mouse.label));
        setTitle(priv.ctrl_scroll_zoom_row, self.tr(settings_map.ctrl_scroll_zoom.label));
        setIconLabel(priv.ctrl_scroll_zoom_reset_button, self.tr(msg.reset_to_default));
        priv.bell_group.setTitle(self.tr(msg.bell));
        const rows = self.bellRows();
        inline for (settings_map.bell_features, 0..) |feature, i| {
            setTitle(rows[i], self.tr(feature.label));
        }

        priv.shell_group.setDescription(self.tr(msg.default_shell_hint));
        setTitle(priv.shell_row, self.tr(msg.default_shell));

        priv.about_group.setDescription(self.tr(msg.notice));
        setTitle(priv.version_row, self.tr(msg.app_name));
        if (self.fill(st.alloc, msg.version, .{ .version = build_config.version_string })) |version| {
            defer st.alloc.free(version);
            priv.version_row.setSubtitle(version);
        } else |_| {}
        setTitle(priv.config_path_row, self.tr(msg.config_file));
        priv.open_config_button.setLabel(self.tr(msg.open_config_file));
        setIconLabel(priv.open_folder_button, self.tr(text.open_folder));
        priv.settings_file_group.setDescription(self.tr(msg.settings_file_hint));
        setTitle(priv.settings_path_row, self.tr(msg.settings_file));

        self.fillCombos();
        self.updateThemeGroup();
        self.updateThemeButtons();
        const app = Application.default();
        const config = app.getConfig();
        defer config.unref();
        self.updateNotes(config.get());
    }

    fn setTitle(row: anytype, title: [:0]const u8) void {
        row.as(adw.PreferencesRow).setTitle(title);
    }

    /// Names an icon button for its tooltip and for screen readers.
    fn setIconLabel(button: *gtk.Button, label: [:0]const u8) void {
        button.as(gtk.Widget).setTooltipText(label);
        button.as(gtk.Accessible).updateProperty(.label, label.ptr, @as(c_int, -1));
    }

    fn themeTitle(target: ThemeTarget) [:0]const u8 {
        return switch (target) {
            .single => msg.theme,
            .light => msg.light_theme,
            .dark => msg.dark_theme,
        };
    }

    /// The lines under the rows: the saved theme, hints, and a note on
    /// the settings the command line overrides.
    fn updateNotes(self: *Self, config: *const CoreConfig) void {
        const priv = self.private();
        const st = &priv.state;
        const cli = self.tr(msg.from_cli);

        for (self.themeRows()) |row| {
            const name: []const u8 = self.savedTheme(self.rowTarget(row)) orelse self.tr(msg.from_nothing);
            self.setNote(row, name, self.fromCli(&.{"theme"}));
        }
        setPlainNote(priv.language_row, if (self.fromCli(&.{"language"})) cli else "");
        self.setNote(priv.material_row, "", self.fromCli(&.{ "background-opacity", "background-blur" }));
        self.setNote(priv.opacity_row, self.tr(msg.opacity_hint), self.fromCli(&.{"background-opacity"}));
        setPlainNote(priv.cursor_style_row, if (self.fromCli(&.{"cursor-style"})) cli else "");
        setPlainNote(priv.cursor_blink_row, if (self.fromCli(&.{settings_map.cursor_blink.key})) cli else "");
        const padding_keys = settings_map.Padding.keys;
        self.setNote(priv.padding_row, self.tr(msg.padding_hint), self.fromCli(&.{ padding_keys[0], padding_keys[1] }));
        setPlainNote(priv.font_size_row, if (self.fromCli(&.{"font-size"})) cli else "");
        setPlainNote(priv.right_click_row, if (self.fromCli(&.{"right-click-action"})) cli else "");
        setPlainNote(priv.scrollbar_row, if (self.fromCli(&.{"scrollbar"})) cli else "");
        setPlainNote(priv.close_confirmation_row, if (self.fromCli(&.{"confirm-close-surface"})) cli else "");
        self.setNote(
            priv.focus_follows_mouse_row,
            self.tr(settings_map.focus_follows_mouse.hint),
            self.fromCli(&.{settings_map.focus_follows_mouse.key}),
        );
        self.setNote(
            priv.ctrl_scroll_zoom_row,
            self.tr(settings_map.ctrl_scroll_zoom.hint),
            self.fromCli(&.{settings_map.ctrl_scroll_zoom.key}),
        );

        const bell_cli = self.fromCli(&.{"bell-features"});
        for (self.bellRows()) |row| {
            const hint: []const u8 = if (row == priv.bell_audio_row and config.@"bell-audio-path" == null)
                self.tr(text.bell_audio_hint)
            else
                "";
            self.setNote(row, hint, bell_cli);
        }

        if (st.shells_loaded) self.updateShellSubtitle();
    }

    /// Shows `line` under `row`, followed by the command-line note when
    /// `cli` is set.
    fn setNote(self: *Self, row: anytype, line: []const u8, cli: bool) void {
        const alloc = self.private().state.alloc;
        const note: []const u8 = if (cli) self.tr(msg.from_cli) else "";
        const separator: []const u8 = if (line.len > 0 and note.len > 0) "\n" else "";
        const subtitle = std.mem.concatWithSentinel(alloc, u8, &.{ line, separator, note }, 0) catch return;
        defer alloc.free(subtitle);
        row.as(adw.ActionRow).setSubtitle(subtitle);
    }

    fn setPlainNote(row: anytype, note: [:0]const u8) void {
        row.as(adw.ActionRow).setSubtitle(note);
    }

    fn updateShellSubtitle(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        if (st.shell >= st.shells.len) return;
        const command = st.shells[st.shell].command orelse st.default_command;
        self.setNote(priv.shell_row, commandText(command), self.fromCli(&.{"command"}));
    }

    //---------------------------------------------------------------
    // Toasts

    /// Shows `message` in the dialog in place of the last toast; with
    /// `retry`, until the user dismisses it or saves again.
    fn showToast(self: *Self, message: [:0]const u8, retry: bool) void {
        const st = &self.private().state;
        if (st.disposed) return;
        self.dismissToast();
        const item = adw.Toast.new(message);
        item.setUseMarkup(0);
        if (retry) {
            item.setButtonLabel(self.tr(text.retry));
            item.setPriority(.high);
            item.setTimeout(0);
            _ = adw.Toast.signals.button_clicked.connect(item, *Self, retryClicked, self, .{});
        } else {
            item.setTimeout(saved_toast_seconds);
        }
        item.ref();
        st.toast = item;
        self.as(adw.PreferencesDialog).addToast(item);
    }

    fn dismissToast(self: *Self) void {
        const st = &self.private().state;
        const item = st.toast orelse return;
        st.toast = null;
        item.dismiss();
        item.unref();
    }

    /// Shows `msgid` with the reason for `err` (`settings_map.errorReason`).
    fn toastError(self: *Self, msgid: [:0]const u8, err: anyerror, retry: bool) void {
        const alloc = self.private().state.alloc;
        const message = self.fill(alloc, msgid, .{ .reason = self.tr(settings_map.errorReason(err)) }) catch return;
        defer alloc.free(message);
        self.showToast(message, retry);
    }

    fn retryClicked(_: *adw.Toast, self: *Self) callconv(.c) void {
        _ = self.saveNow();
    }

    //---------------------------------------------------------------
    // Saving and reloading

    fn queueSet(self: *Self, key: []const u8, value: []const u8) void {
        self.queueSetAll(key, &.{value});
    }

    /// Records a change (an empty `values` removes `key`) and saves it
    /// with the other changes of the next moment.
    fn queueSetAll(self: *Self, key: []const u8, values: []const []const u8) void {
        const st = &self.private().state;
        st.changes.setAll(key, values) catch |err| {
            log.warn("cannot record the change of {s} err={}", .{ key, err });
            return;
        };
        self.queueSave();
    }

    /// "Reset to Default": removes `key` from the overlay.
    fn queueReset(self: *Self, key: []const u8) void {
        const st = &self.private().state;
        st.changes.reset(key) catch |err| {
            log.warn("cannot record the reset of {s} err={}", .{ key, err });
            return;
        };
        self.queueSave();
    }

    fn queueSave(self: *Self) void {
        const st = &self.private().state;
        self.as(adw.Dialog).setCanClose(0);
        if (st.save_source) |source| {
            st.save_source = null;
            _ = glib.Source.remove(source);
        }
        st.save_source = glib.timeoutAddFull(
            glib.PRIORITY_DEFAULT,
            save_delay_ms,
            saveTimeout,
            self.ref(),
            unrefData,
        );
    }

    fn saveTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const st = &self.private().state;
        st.save_source = null;
        if (!st.disposed) _ = self.saveNow();
        return 0;
    }

    /// Saves the recorded changes to the overlay and applies the
    /// configuration. On failure the changes are kept for another try.
    /// Returns whether the changes are saved.
    fn saveNow(self: *Self) bool {
        const st = &self.private().state;
        if (st.save_source) |source| {
            st.save_source = null;
            _ = glib.Source.remove(source);
        }
        if (st.changes.isEmpty() and !st.apply_pending) return true;

        if (!st.changes.isEmpty()) {
            const effects = saveEffects(
                st.changes.entries.items,
                st.previewing,
                self.previewArg(),
                if (st.apply_pending) st.pending_sync else null,
            );

            const path = gx.config_layers.overlayPath(st.alloc) catch |err| {
                log.warn("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
                self.toastError(msg.save_failed, err, true);
                return false;
            };
            defer st.alloc.free(path);
            st.changes.commit(st.alloc, global.io(), path) catch |err| {
                log.warn("cannot save {s} err={}", .{ path, err });
                self.toastError(msg.save_failed, err, true);
                return false;
            };
            if (effects.end_preview) st.previewing = false;
            st.apply_pending = true;
            st.pending_sync = effects.sync;
            self.reloadLayers();
        }
        return self.applyPending();
    }

    /// Applies what the last save wrote (`apply_pending`) and shows it: the
    /// saved theme, the configured font family. With nothing else left to
    /// save the dialog can close again and says the settings are saved.
    /// Returns whether applying succeeded.
    fn applyPending(self: *Self) bool {
        const st = &self.private().state;
        var config = self.apply(self.previewArg()) orelse return false;
        defer config.deinit();
        self.syncValues(&config, appliedSync(st.pending_sync, st.previewing));
        st.apply_pending = false;
        if (st.changes.isEmpty()) {
            self.as(adw.Dialog).setCanClose(1);
            if (!st.disposed) self.showToast(self.tr(text.saved), false);
        }
        return true;
    }

    /// Nothing is left to save: the retry toast goes and the dialog can
    /// close again, even while the settings folder stays read-only.
    fn settleSaves(self: *Self) void {
        const st = &self.private().state;
        if (st.save_source) |source| {
            st.save_source = null;
            _ = glib.Source.remove(source);
        }
        self.dismissToast();
        self.as(adw.Dialog).setCanClose(1);
    }

    /// Builds the configuration with in-memory overrides, the previewed
    /// `theme` value (if any) and no reload toast, and applies it without
    /// saving anything. Returns the applied configuration, owned by the
    /// caller.
    fn apply(self: *Self, theme: ?[]const u8) ?CoreConfig {
        const st = &self.private().state;
        const failed: [:0]const u8 = if (theme != null) msg.preview_failed else msg.reload_failed;

        var quiet_buf: [128]u8 = undefined;
        const quiet = settings_map.quietReloadArg(&quiet_buf, st.notifications) catch |err| {
            self.toastError(failed, err, st.apply_pending);
            return null;
        };
        var args: [2][:0]const u8 = .{ quiet, undefined };
        var len: usize = 1;
        var theme_arg: ?[:0]u8 = null;
        defer if (theme_arg) |arg| st.alloc.free(arg);
        if (theme) |value| {
            theme_arg = settings_map.themeArg(st.alloc, value) catch |err| {
                self.toastError(failed, err, st.apply_pending);
                return null;
            };
            args[1] = theme_arg.?;
            len = 2;
        }

        const blink = @import("defaults.zig").sampleSystemCursorBlink();
        if (st.layers) |*layers| _ = layers.setSystemCursorBlink(blink);
        var config = (if (st.layers) |*layers|
            layers.build(st.alloc, args[0..len])
        else
            gx.config_layers.loadWithOverrides(st.alloc, args[0..len])) catch |err| {
            log.warn("cannot load the configuration err={}", .{err});
            self.toastError(failed, err, st.apply_pending);
            return null;
        };
        const app = Application.default();
        const theme_changed = if (gx.perf.enabled()) changed: {
            const previous = app.getConfig();
            defer previous.unref();
            break :changed themeReloadChanged(previous.get(), &config);
        } else false;
        const updated = updated: {
            st.applying = true;
            defer st.applying = false;
            break :updated app.core().updateConfig(app.rt(), &config);
        };
        updated catch |err| {
            log.warn("cannot apply the configuration err={}", .{err});
            self.toastError(failed, err, st.apply_pending);
            config.deinit();
            return null;
        };
        if (theme_changed) gx.perf.count("theme.reload", 1);
        return config;
    }

    /// Applies the saved configuration again (ending a preview).
    fn applySaved(self: *Self) void {
        if (self.apply(null)) |config_| {
            var config = config_;
            config.deinit();
        }
    }

    /// Reads the value of `key` in the overlay file.
    fn overlayValue(self: *Self, alloc: Allocator, key: []const u8) ?[]const u8 {
        const st = &self.private().state;
        const path = gx.config_layers.overlayPath(st.alloc) catch return null;
        defer st.alloc.free(path);
        var overlay = gx.gui_settings.Overlay.load(st.alloc, global.io(), path) catch |err| {
            log.warn("cannot read {s} err={}", .{ path, err });
            return null;
        };
        defer overlay.deinit();
        const value = overlay.get(key) orelse return null;
        return alloc.dupe(u8, value) catch null;
    }

    fn unrefData(ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.unref();
    }

    /// Follows the zoom switch and UI language without overwriting pending
    /// edits. A change the dialog did not make puts it out of date, so the
    /// next opening builds a new one; a closed dialog leaves the rest to its
    /// next opening.
    fn appConfigChanged(app: *Application, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        if (!st.applying) st.stale = true;
        if (!st.shown) return;
        const config = app.getConfig();
        defer config.unref();
        if (st.changes.isEmpty() and !st.apply_pending) {
            const loading = st.loading;
            st.loading = true;
            defer st.loading = loading;
            const priv = self.private();
            setSwitch(priv.ctrl_scroll_zoom_row, config.get().@"gx-ctrl-scroll-zoom");
            priv.ctrl_scroll_zoom_reset_button.as(gtk.Widget).setSensitive(@intFromBool(self.overlaySets(settings_map.ctrl_scroll_zoom.key)));
        }
        const lang = gx.i18n.resolve(config.get().language);
        if (lang == st.lang) return;
        st.lang = lang;
        self.applyTexts();
    }

    //---------------------------------------------------------------
    // Themes

    fn themeNames(self: *Self) []const [:0]const u8 {
        const st = &self.private().state;
        return if (st.themes) |list| list.names else &.{};
    }

    /// The swatch of the theme `name`, read once.
    fn swatchOf(self: *Self, name: []const u8) theme_swatch.Swatch {
        const st = &self.private().state;
        const index = if (st.themes) |*list| list.indexOf(name) else null;
        if (index) |i| return st.swatches.get(st.alloc, global.io(), st.theme_dirs, @intCast(i), name);
        return theme_swatch.load(st.alloc, global.io(), st.theme_dirs, name);
    }

    /// The theme index of the selected row of the theme list.
    fn selectedTheme(self: *Self) ?u32 {
        const st = &self.private().state;
        const selection = st.theme_selection orelse return null;
        const pos = selection.getSelected();
        if (pos >= st.visible.items.len) return null;
        return st.visible.items[pos];
    }

    /// The theme index of the saved theme that `target` chooses.
    fn savedThemeIndex(self: *Self, target: ThemeTarget) ?u32 {
        const st = &self.private().state;
        const name = self.savedTheme(target) orelse return null;
        const list = &(st.themes orelse return null);
        return @intCast(list.indexOf(name) orelse return null);
    }

    fn isSavedTheme(self: *Self, index: u32) bool {
        const saved = self.savedThemeIndex(self.private().state.target) orelse return false;
        return saved == index;
    }

    /// Opens the theme list for `target`, with the saved theme selected.
    fn openThemes(self: *Self, target: ThemeTarget) void {
        const priv = self.private();
        const st = &priv.state;
        if (st.disposed or !st.layered) return;
        st.target = target;
        priv.theme_subpage.setTitle(self.tr(themeTitle(target)));
        priv.theme_search.as(gtk.Editable).setText("");
        self.as(adw.PreferencesDialog).pushSubpage(priv.theme_subpage);
    }

    const Refilter = enum {
        /// The list opens: select the saved theme.
        open,
        /// The search changed: keep the selection if it still shows,
        /// else select the first theme and preview it.
        search,
    };

    /// Lists the themes that match the search, best first
    /// (`gx.fuzzy.filter`).
    fn refilter(self: *Self, how: Refilter) void {
        const priv = self.private();
        const st = &priv.state;
        const model = st.theme_model orelse return;
        const selection = st.theme_selection orelse return;

        const kept = switch (how) {
            .open => self.savedThemeIndex(st.target),
            .search => self.selectedTheme(),
        };
        const query = std.mem.span(priv.theme_search.as(gtk.Editable).getText());
        fuzzy.filter(st.alloc, self.themeNames(), query, &st.visible) catch |err| {
            log.warn("cannot filter the themes err={}", .{err});
            return;
        };

        const names = self.themeNames();
        const strings = st.alloc.alloc(?[*:0]const u8, st.visible.items.len + 1) catch return;
        defer st.alloc.free(strings);
        for (st.visible.items, strings[0..st.visible.items.len]) |index, *string| string.* = names[index].ptr;
        strings[st.visible.items.len] = null;

        var position: ?usize = if (kept) |index| std.mem.indexOfScalar(u32, st.visible.items, index) else null;
        const first = position == null and how == .search and st.visible.items.len > 0;
        if (first) position = 0;

        st.selecting = true;
        model.splice(0, model.as(gio.ListModel).getNItems(), @ptrCast(strings.ptr));
        selection.setSelected(if (position) |pos| @intCast(pos) else gtk.INVALID_LIST_POSITION);
        st.selecting = false;

        priv.theme_stack.setVisibleChildName(if (st.visible.items.len == 0) "empty" else "list");
        if (position) |pos| priv.theme_list.scrollTo(@intCast(pos), .{}, null);
        if (first) self.queuePreview(typing_preview_delay_ms);
        self.updateThemeButtons();
    }

    /// Moves the theme selection by `delta` rows.
    fn moveSelection(self: *Self, delta: isize) void {
        const priv = self.private();
        const st = &priv.state;
        const selection = st.theme_selection orelse return;
        const current: ?usize = if (selection.getSelected() < st.visible.items.len) selection.getSelected() else null;
        const pos = movedPosition(current, delta, st.visible.items.len) orelse return;
        selection.setSelected(@intCast(pos));
        priv.theme_list.scrollTo(@intCast(pos), .{}, null);
    }

    fn updateThemeButtons(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const saved = self.savedThemeIndex(st.target);
        const changed = if (self.selectedTheme()) |selected| !self.isSavedTheme(selected) else false;
        priv.theme_apply_button.as(gtk.Widget).setSensitive(@intFromBool(changed and st.layered));
        priv.theme_revert_button.as(gtk.Widget).setSensitive(@intFromBool(
            st.previewing or st.preview_source != null or (changed and saved != null),
        ));
    }

    /// Shows which theme is saved on the rows of the theme list.
    fn refreshThemeChecks(self: *Self) void {
        const st = &self.private().state;
        for (st.bound.items) |item| self.showThemeItem(item);
    }

    fn cancelPreview(self: *Self) void {
        const st = &self.private().state;
        if (st.preview_source) |source| {
            st.preview_source = null;
            _ = glib.Source.remove(source);
        }
    }

    /// Previews the selected theme once the selection rests for
    /// `delay_ms`.
    fn queuePreview(self: *Self, delay_ms: c_uint) void {
        const st = &self.private().state;
        if (!st.layered) return;
        self.cancelPreview();
        st.preview_source = glib.timeoutAddFull(
            glib.PRIORITY_DEFAULT,
            delay_ms,
            previewTimeout,
            self.ref(),
            unrefData,
        );
        self.updateThemeButtons();
    }

    fn previewTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const st = &self.private().state;
        st.preview_source = null;
        if (st.disposed) return 0;
        self.previewSelected();
        return 0;
    }

    /// Applies the selected theme without saving it. Selecting the saved
    /// theme again reverts (`revertTheme`): the saved configuration applies
    /// and a theme whose saving failed is dropped.
    fn previewSelected(self: *Self) void {
        const st = &self.private().state;
        const index = self.selectedTheme() orelse return;
        if (self.isSavedTheme(index)) return self.revertTheme();
        const value = themeValue(st.alloc, st.target, st.saved_light, st.saved_dark, self.themeNames()[index]) catch return;
        defer st.alloc.free(value);
        if (self.apply(value)) |config_| {
            var config = config_;
            config.deinit();
            st.previewing = true;
        }
        self.updateThemeButtons();
    }

    /// The `theme` value the applied configuration previews, if any.
    fn previewArg(self: *Self) ?[]const u8 {
        const st = &self.private().state;
        if (!st.previewing) return null;
        const index = self.selectedTheme() orelse return null;
        const value = themeValue(st.arena.allocator(), st.target, st.saved_light, st.saved_dark, self.themeNames()[index]) catch return null;
        return value;
    }

    /// Applies the saved configuration again, ending a theme preview.
    fn endPreview(self: *Self) void {
        const st = &self.private().state;
        self.cancelPreview();
        if (!st.previewing) return;
        st.previewing = false;
        self.applySaved();
    }

    /// Ends the preview and selects the saved theme again (D-15). The theme
    /// a failed Apply left to save is dropped, and with nothing else to
    /// save its retry toast goes and the dialog can close again. When a
    /// save wrote the theme and only applying it failed, the saved
    /// configuration is applied again instead, so the dialog shows what the
    /// file has rather than an undone change.
    fn revertTheme(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const revert = revertChanges(&st.changes, st.apply_pending);
        if (revert.reapply) {
            self.cancelPreview();
            st.previewing = false;
            _ = self.applyPending();
        } else {
            self.endPreview();
        }
        if (revert.settled) self.settleSaves();
        if (st.theme_selection) |selection| {
            const saved = self.savedThemeIndex(st.target);
            const pos = if (saved) |index| std.mem.indexOfScalar(u32, st.visible.items, index) else null;
            st.selecting = true;
            selection.setSelected(if (pos) |p| @intCast(p) else gtk.INVALID_LIST_POSITION);
            st.selecting = false;
            if (pos) |p| priv.theme_list.scrollTo(@intCast(p), .{}, null);
        }
        self.updateThemeButtons();
    }

    /// Saves the selected theme.
    fn applyTheme(self: *Self) void {
        const st = &self.private().state;
        if (st.disposed or !st.layered) return;
        const index = self.selectedTheme() orelse return;
        if (self.isSavedTheme(index)) return;
        const value = themeValue(st.alloc, st.target, st.saved_light, st.saved_dark, self.themeNames()[index]) catch return;
        defer st.alloc.free(value);
        self.cancelPreview();
        const previewing = st.previewing;
        st.previewing = false;
        self.queueSet("theme", value);
        if (!self.saveNow() and !st.apply_pending) st.previewing = previewing;
        self.updateThemeButtons();
    }

    //---------------------------------------------------------------
    // Theme list rows

    fn themeItemSetup(_: *gtk.SignalListItemFactory, object: *gobject.Object, self: *Self) callconv(.c) void {
        _ = self;
        const item = gobject.ext.cast(gtk.ListItem, object) orelse return;
        const box = gtk.Box.new(.horizontal, 12);
        const swatch = ThemeSwatch.new();
        box.append(swatch.as(gtk.Widget));
        const label = gtk.Label.new(null);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        box.append(label.as(gtk.Widget));
        const check = gtk.Image.newFromIconName("object-select-symbolic");
        check.as(gtk.Widget).setVisible(0);
        box.append(check.as(gtk.Widget));
        item.setChild(box.as(gtk.Widget));
    }

    fn themeItemBind(_: *gtk.SignalListItemFactory, object: *gobject.Object, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        const item = gobject.ext.cast(gtk.ListItem, object) orelse return;
        st.bound.append(st.alloc, item) catch {};
        self.showThemeItem(item);
    }

    fn themeItemUnbind(_: *gtk.SignalListItemFactory, object: *gobject.Object, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        const item = gobject.ext.cast(gtk.ListItem, object) orelse return;
        for (st.bound.items, 0..) |bound, i| {
            if (bound != item) continue;
            _ = st.bound.swapRemove(i);
            break;
        }
    }

    /// Fills in a row of the theme list: the swatch, the name and whether
    /// it is the saved theme.
    fn showThemeItem(self: *Self, item: *gtk.ListItem) void {
        const st = &self.private().state;
        const pos = item.getPosition();
        if (pos >= st.visible.items.len) return;
        const index = st.visible.items[pos];
        const name = self.themeNames()[index];

        const box = item.getChild() orelse return;
        const swatch_widget = box.getFirstChild() orelse return;
        const label_widget = swatch_widget.getNextSibling() orelse return;
        const check = label_widget.getNextSibling() orelse return;
        if (gobject.ext.cast(ThemeSwatch, swatch_widget)) |swatch| {
            swatch.set(st.swatches.get(st.alloc, global.io(), st.theme_dirs, index, name));
        }
        if (gobject.ext.cast(gtk.Label, label_widget)) |label| label.setText(name.ptr);
        check.setVisible(@intFromBool(self.isSavedTheme(index)));
        item.setAccessibleLabel(name.ptr);
    }

    //---------------------------------------------------------------
    // Shells and herdr

    /// Makes herdr start GX Zsh by default, if herdr is installed:
    /// `herdr --gx-set-default-shell <gx-zsh>` runs in the background and
    /// its result is shown as a toast. Exit code 3 means the user manages
    /// the herdr configuration, which is not an error.
    fn setHerdrDefaultShell(self: *Self, gx_zsh: [:0]const u8) void {
        const herdr = self.private().state.herdr orelse return;
        const argv = [_:null]?[*:0]const u8{ herdr.ptr, "--gx-set-default-shell", gx_zsh.ptr };
        var err_: ?*glib.Error = null;
        const process = gio.Subprocess.newv(
            @ptrCast(&argv),
            .{ .stdout_silence = true },
            &err_,
        ) orelse {
            defer if (err_) |err| err.free();
            const reason: []const u8 = if (err_) |err| std.mem.span(err.f_message orelse "?") else "?";
            log.warn("cannot run {s} err={s}", .{ herdr, reason });
            self.toastText(msg.herdr_failed, .{ .reason = reason });
            return;
        };
        process.waitAsync(null, herdrFinished, self.ref());
    }

    fn herdrFinished(
        source: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const process: *gio.Subprocess = @ptrCast(@alignCast(source orelse return));
        defer process.unref();

        var err_: ?*glib.Error = null;
        if (process.waitFinish(result, &err_) == 0) {
            defer if (err_) |err| err.free();
            const reason: []const u8 = if (err_) |err| std.mem.span(err.f_message orelse "?") else "?";
            log.warn("waiting for herdr failed err={s}", .{reason});
            self.toastText(msg.herdr_failed, .{ .reason = reason });
            return;
        }
        if (process.getIfExited() == 0) {
            log.warn("herdr did not exit normally", .{});
            self.toastText(msg.herdr_failed, .{ .reason = "signal" });
            return;
        }
        switch (process.getExitStatus()) {
            0 => self.toastText(msg.herdr_updated, .{}),
            3 => self.toastText(msg.herdr_user_config, .{}),
            else => |code| {
                log.warn("herdr --gx-set-default-shell exited with {d}", .{code});
                self.toastText(msg.herdr_exit, .{ .code = code });
            },
        }
    }

    /// Shows `msgid`, with its placeholders filled in, as a toast.
    fn toastText(self: *Self, msgid: [:0]const u8, args: anytype) void {
        const alloc = self.private().state.alloc;
        const message = self.fill(alloc, msgid, args) catch return;
        defer alloc.free(message);
        self.showToast(message, false);
    }

    //---------------------------------------------------------------
    // Template callbacks

    /// Whether a change handler should record the change: not while the
    /// widgets are filled in or torn down.
    fn recording(self: *Self) bool {
        const st = &self.private().state;
        return st.layered and !st.loading and !st.disposed;
    }

    fn closeAttempted(dialog: *adw.Dialog, self: *Self) callconv(.c) void {
        if (self.private().state.disposed) return;
        if (self.saveNow()) dialog.forceClose();
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        const keep = self.ref();
        defer keep.unref();
        const st = &self.private().state;
        if (st.disposed) return;
        st.shown = false;

        // The window keeps the dialog (`kept_dialogs`) for its next
        // opening; a timer or a running herdr may keep it alive meanwhile.
        if (open_dialog.get()) |dialog| {
            defer dialog.unref();
            if (dialog == self) open_dialog.set(null);
        }
        if (self.as(adw.PreferencesDialog).getVisiblePageName()) |name| {
            last_page = std.meta.stringToEnum(settings_map.Page, std.mem.span(name));
        }

        self.cancelPreview();
        const previewed = st.previewing;
        st.previewing = false;
        if (!st.changes.isEmpty()) {
            // Saving applies the saved settings, which ends the preview.
            if (!self.saveNow() and previewed) self.applySaved();
        } else if (previewed) {
            self.applySaved();
        }
    }

    fn pageChanged(_: *adw.PreferencesDialog, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        const name = self.as(adw.PreferencesDialog).getVisiblePageName() orelse return;
        if (std.mem.eql(u8, std.mem.span(name), @tagName(settings_map.Page.shell))) self.loadShells();
    }

    fn languageSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const index = row.getSelected();
        if (index >= languages.len) return;
        self.queueSet("language", languages[index].configValue());
    }

    fn themeRowActivated(row: *adw.ActionRow, self: *Self) callconv(.c) void {
        self.openThemes(self.rowTarget(row));
    }

    fn themeSubpageShown(_: *adw.NavigationPage, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state.disposed) return;
        self.refilter(.open);
        _ = priv.theme_search.as(gtk.Widget).grabFocus();
    }

    fn themeSubpageHidden(_: *adw.NavigationPage, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        self.revertTheme();
    }

    fn themeApplyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.applyTheme();
    }

    fn themeRevertClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (self.private().state.disposed) return;
        self.revertTheme();
    }

    fn themeSearchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        if (self.private().state.disposed) return;
        self.refilter(.search);
    }

    /// Enter in the search entry, or in the theme list (which forwards
    /// its keys to the search entry), applies the selected theme.
    fn themeSearchActivated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.applyTheme();
    }

    /// Escape clears the search, or goes back when it is empty.
    fn themeSearchStopped(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        if (self.private().state.disposed) return;
        const editable = entry.as(gtk.Editable);
        if (std.mem.span(editable.getText()).len > 0) {
            editable.setText("");
            return;
        }
        _ = self.as(adw.PreferencesDialog).popSubpage();
    }

    /// The arrow and page keys in the search entry move through the list.
    fn themeSearchKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.private().state.disposed) return 0;
        if (state.control_mask or state.alt_mask or state.shift_mask) return 0;
        const delta: isize = switch (keyval) {
            gdk.KEY_Up, gdk.KEY_KP_Up => -1,
            gdk.KEY_Down, gdk.KEY_KP_Down => 1,
            gdk.KEY_Page_Up, gdk.KEY_KP_Page_Up => -page_rows,
            gdk.KEY_Page_Down, gdk.KEY_KP_Page_Down => page_rows,
            else => return 0,
        };
        self.moveSelection(delta);
        return 1;
    }

    fn themeListActivated(_: *gtk.ListView, position: c_uint, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        if (st.theme_selection) |selection| {
            if (selection.getSelected() != position) selection.setSelected(position);
        }
        self.applyTheme();
    }

    fn themeSelectionChanged(_: *gtk.SingleSelection, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        self.updateThemeButtons();
        if (st.selecting) return;
        self.queuePreview(preview_delay_ms);
    }

    fn materialSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const index = row.getSelected();
        if (index >= materials.len) return;
        const st = &self.private().state;
        st.material = materials[index];
        for (materials[index].settings()) |setting| self.queueSet(setting.key, setting.value);
    }

    fn opacitySelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const st = &self.private().state;
        const index = row.getSelected();
        if (index < opacities.len) {
            const choice = opacities[index];
            if (choice.value()) |value| self.queueSet("background-opacity", value) else self.queueReset("background-opacity");
            return;
        }
        // The custom value the configuration had.
        switch (st.opacity) {
            .custom => |value| {
                var buf: [32]u8 = undefined;
                self.queueSet("background-opacity", std.fmt.bufPrint(&buf, "{d}", .{value}) catch return);
            },
            .choice => {},
        }
    }

    fn cursorStyleSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const choices = &settings_map.cursor_style_choices;
        const index = row.getSelected();
        if (index >= choices.len) return;
        self.private().state.cursor_style = choices[index].value;
        self.queueSet("cursor-style", @tagName(choices[index].value));
    }

    fn cursorBlinkToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const item = settings_map.cursor_blink;
        self.queueSet(item.key, settings_map.Switch.value(row.getActive() != 0));
    }

    fn paddingSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const st = &self.private().state;
        const keys = settings_map.Padding.keys;
        const index = row.getSelected();
        if (index < paddings.len) {
            if (paddings[index].values()) |values| {
                for (keys, values) |key, value| self.queueSet(key, value);
            } else {
                for (keys) |key| self.queueReset(key);
            }
            return;
        }
        switch (st.padding) {
            .custom => |custom| {
                var bufs: [2][32]u8 = undefined;
                self.queueSet(keys[0], paddingValue(&bufs[0], custom.x) catch return);
                self.queueSet(keys[1], paddingValue(&bufs[1], custom.y) catch return);
            },
            .preset => {},
        }
    }

    fn fontSizeChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        var buf: [32]u8 = undefined;
        const value = settings_map.FontSize.format(
            &buf,
            settings_map.FontSize.normalize(row.getValue()),
        ) catch return;
        self.queueSet("font-size", value);
        self.private().font_size_reset_button.as(gtk.Widget).setSensitive(1);
    }

    /// Shows the font size without trailing zeros (`12`, `12.5`).
    fn fontSizeOutput(row: *adw.SpinRow, _: *Self) callconv(.c) c_int {
        var buf: [32]u8 = undefined;
        const value = settings_map.FontSize.format(
            &buf,
            settings_map.FontSize.normalize(row.getValue()),
        ) catch return 0;
        var text_buf: [33]u8 = undefined;
        const z = std.fmt.bufPrintZ(&text_buf, "{s}", .{value}) catch return 0;
        row.as(gtk.Editable).setText(z);
        return 1;
    }

    fn fontSizeResetClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        button.as(gtk.Widget).setSensitive(0);
        self.queueReset("font-size");
    }

    fn fontFamilyApplied(row: *adw.EntryRow, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        self.setFontFamily(std.mem.span(row.as(gtk.Editable).getText()));
    }

    /// Makes `name` the font family, keeping the configured fallback
    /// families; an empty name removes the font family from the overlay.
    fn setFontFamily(self: *Self, name: []const u8) void {
        const priv = self.private();
        const st = &priv.state;
        const families = settings_map.fontFamilies(st.alloc, name, st.font_families) catch return;
        defer st.alloc.free(families);
        self.queueSetAll("font-family", families);
        priv.font_clear_button.as(gtk.Widget).setSensitive(@intFromBool(families.len > 0));
    }

    fn fontClearClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        self.queueReset("font-family");
        self.private().font_clear_button.as(gtk.Widget).setSensitive(0);
    }

    fn setUpFontChooser(self: *Self) void {
        const dialog = gtk.FontDialog.new();
        defer dialog.unref();
        dialog.setModal(1);
        const filter = gtk.CustomFilter.new(monospaceFilter, null, null);
        defer filter.unref();
        dialog.setFilter(filter.as(gtk.Filter));
        self.private().font_choose_button.setDialog(dialog);
    }

    fn fontFamilySelected(button: *gtk.FontDialogButton, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const description = button.getFontDesc() orelse return;
        const name = pango_font_description_get_family(@ptrCast(description)) orelse return;
        self.private().font_family_row.as(gtk.Editable).setText(name);
        self.setFontFamily(std.mem.span(name));
    }

    /// Keeps the monospace families and their faces.
    fn monospaceFilter(item: *gobject.Object, _: ?*anyopaque) callconv(.c) c_int {
        const instance: *gobject.TypeInstance = @ptrCast(item);
        if (gobject.typeCheckInstanceIsA(instance, pango_font_family_get_type()) != 0) {
            return pango_font_family_is_monospace(@ptrCast(item));
        }
        if (gobject.typeCheckInstanceIsA(instance, pango_font_face_get_type()) != 0) {
            return pango_font_family_is_monospace(pango_font_face_get_family(@ptrCast(item)));
        }
        return 0;
    }

    fn rightClickSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const choices = &settings_map.right_click_choices;
        const index = row.getSelected();
        if (index >= choices.len) return;
        self.private().state.right_click = choices[index].value;
        self.queueSet("right-click-action", @tagName(choices[index].value));
    }

    fn scrollbarToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        self.queueSet("scrollbar", @tagName(settings_map.scrollbar(row.getActive() != 0)));
    }

    fn closeConfirmationSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const choices = &settings_map.close_confirmation_choices;
        const index = row.getSelected();
        if (index >= choices.len) return;
        self.private().state.close_confirmation = choices[index].value;
        self.queueSet("confirm-close-surface", @tagName(choices[index].value));
    }

    fn focusFollowsMouseToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const item = settings_map.focus_follows_mouse;
        self.queueSet(item.key, settings_map.Switch.value(row.getActive() != 0));
    }

    fn ctrlScrollZoomToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const item = settings_map.ctrl_scroll_zoom;
        self.queueSet(item.key, settings_map.Switch.value(row.getActive() != 0));
        self.private().ctrl_scroll_zoom_reset_button.as(gtk.Widget).setSensitive(1);
    }

    fn ctrlScrollZoomResetClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        button.as(gtk.Widget).setSensitive(0);
        self.queueReset(settings_map.ctrl_scroll_zoom.key);
    }

    fn bellToggled(_: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        var features: CoreConfig.BellFeatures = .{};
        const rows = self.bellRows();
        inline for (settings_map.bell_features, 0..) |feature, i| {
            @field(features, feature.field) = rows[i].getActive() != 0;
        }
        var buf: [128]u8 = undefined;
        const value = settings_map.formatFlags(CoreConfig.BellFeatures, features, &buf) catch return;
        self.queueSet("bell-features", value);
    }

    fn shellSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        const index = row.getSelected();
        if (index >= st.shells.len) return;
        if (st.loading) return;
        st.shell = index;
        self.updateShellSubtitle();
        const shell = st.shells[index];
        if (shell.command) |command| {
            self.queueSet("command", command);
        } else {
            self.queueReset("command");
        }
        if (shell.gx_zsh) |exe| self.setHerdrDefaultShell(exe);
    }

    fn openConfigClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("cannot get the configuration file path err={}", .{err});
            self.toastError(msg.open_failed, err, false);
            return;
        };
        defer alloc.free(path);
        // The same as the upstream `.os_open` target of `open_config`.
        app.openUrlFallback(.text, path);
    }

    /// Opens the folder of the configuration file and the settings file.
    fn openFolderClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();
        const path = file_load.preferredDefaultFilePath(alloc) catch |err| {
            log.warn("cannot locate the configuration file err={}", .{err});
            self.toastError(msg.open_failed, err, false);
            return;
        };
        defer alloc.free(path);
        app.openUrlFallback(.unknown, std.fs.path.dirname(path) orelse path);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // Before the template, whose signal handlers read the state.
        const alloc = Application.default().allocator();
        self.private().state = .{
            .alloc = alloc,
            .arena = .init(alloc),
            .changes = .init(alloc),
        };
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const st = &self.private().state;
        st.disposed = true;
        st.owner.deinit();
        self.cancelPreview();
        if (st.save_source) |source| {
            st.save_source = null;
            _ = glib.Source.remove(source);
        }
        if (st.config_handler != 0) {
            gobject.signalHandlerDisconnect(Application.default().as(gobject.Object), st.config_handler);
            st.config_handler = 0;
        }
        if (st.toast) |item| {
            st.toast = null;
            item.unref();
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const st = &self.private().state;
        st.changes.deinit();
        if (st.layers) |*layers| layers.deinit();
        if (st.themes) |*list| list.deinit();
        if (st.theme_selection) |selection| selection.unref();
        for ([_]?[:0]u8{ st.saved_light, st.saved_dark }) |name| {
            if (name) |value| st.alloc.free(value);
        }
        st.swatches.deinit(st.alloc);
        st.visible.deinit(st.alloc);
        st.bound.deinit(st.alloc);
        st.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ThemeSwatch);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "gx-settings-dialog",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("language_page", .{});
            class.bindTemplateChildPrivate("language_group", .{});
            class.bindTemplateChildPrivate("language_row", .{});
            class.bindTemplateChildPrivate("appearance_page", .{});
            class.bindTemplateChildPrivate("theme_group", .{});
            class.bindTemplateChildPrivate("theme_row", .{});
            class.bindTemplateChildPrivate("theme_light_row", .{});
            class.bindTemplateChildPrivate("theme_dark_row", .{});
            class.bindTemplateChildPrivate("material_group", .{});
            class.bindTemplateChildPrivate("material_row", .{});
            class.bindTemplateChildPrivate("opacity_row", .{});
            class.bindTemplateChildPrivate("cursor_group", .{});
            class.bindTemplateChildPrivate("cursor_style_row", .{});
            class.bindTemplateChildPrivate("cursor_blink_row", .{});
            class.bindTemplateChildPrivate("padding_group", .{});
            class.bindTemplateChildPrivate("padding_row", .{});
            class.bindTemplateChildPrivate("font_page", .{});
            class.bindTemplateChildPrivate("font_size_group", .{});
            class.bindTemplateChildPrivate("font_size_row", .{});
            class.bindTemplateChildPrivate("font_size_reset_button", .{});
            class.bindTemplateChildPrivate("font_family_group", .{});
            class.bindTemplateChildPrivate("font_choice_row", .{});
            class.bindTemplateChildPrivate("font_family_row", .{});
            class.bindTemplateChildPrivate("font_choose_button", .{});
            class.bindTemplateChildPrivate("font_clear_button", .{});
            class.bindTemplateChildPrivate("interaction_page", .{});
            class.bindTemplateChildPrivate("interaction_group", .{});
            class.bindTemplateChildPrivate("right_click_row", .{});
            class.bindTemplateChildPrivate("scrollbar_row", .{});
            class.bindTemplateChildPrivate("close_confirmation_row", .{});
            class.bindTemplateChildPrivate("focus_follows_mouse_row", .{});
            class.bindTemplateChildPrivate("ctrl_scroll_zoom_row", .{});
            class.bindTemplateChildPrivate("ctrl_scroll_zoom_reset_button", .{});
            class.bindTemplateChildPrivate("bell_group", .{});
            class.bindTemplateChildPrivate("bell_system_row", .{});
            class.bindTemplateChildPrivate("bell_audio_row", .{});
            class.bindTemplateChildPrivate("bell_attention_row", .{});
            class.bindTemplateChildPrivate("bell_title_row", .{});
            class.bindTemplateChildPrivate("bell_border_row", .{});
            class.bindTemplateChildPrivate("shell_page", .{});
            class.bindTemplateChildPrivate("shell_group", .{});
            class.bindTemplateChildPrivate("shell_row", .{});
            class.bindTemplateChildPrivate("about_page", .{});
            class.bindTemplateChildPrivate("about_group", .{});
            class.bindTemplateChildPrivate("version_row", .{});
            class.bindTemplateChildPrivate("config_path_row", .{});
            class.bindTemplateChildPrivate("open_folder_button", .{});
            class.bindTemplateChildPrivate("open_config_button", .{});
            class.bindTemplateChildPrivate("settings_file_group", .{});
            class.bindTemplateChildPrivate("settings_path_row", .{});
            class.bindTemplateChildPrivate("theme_subpage", .{});
            class.bindTemplateChildPrivate("theme_search", .{});
            class.bindTemplateChildPrivate("theme_revert_button", .{});
            class.bindTemplateChildPrivate("theme_apply_button", .{});
            class.bindTemplateChildPrivate("theme_hint", .{});
            class.bindTemplateChildPrivate("theme_stack", .{});
            class.bindTemplateChildPrivate("theme_list", .{});
            class.bindTemplateChildPrivate("theme_empty", .{});

            // Template Callbacks
            class.bindTemplateCallback("close_attempted", &closeAttempted);
            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("page_changed", &pageChanged);
            class.bindTemplateCallback("language_selected", &languageSelected);
            class.bindTemplateCallback("theme_row_activated", &themeRowActivated);
            class.bindTemplateCallback("material_selected", &materialSelected);
            class.bindTemplateCallback("opacity_selected", &opacitySelected);
            class.bindTemplateCallback("cursor_style_selected", &cursorStyleSelected);
            class.bindTemplateCallback("cursor_blink_toggled", &cursorBlinkToggled);
            class.bindTemplateCallback("padding_selected", &paddingSelected);
            class.bindTemplateCallback("font_size_changed", &fontSizeChanged);
            class.bindTemplateCallback("font_size_output", &fontSizeOutput);
            class.bindTemplateCallback("font_size_reset_clicked", &fontSizeResetClicked);
            class.bindTemplateCallback("font_family_applied", &fontFamilyApplied);
            class.bindTemplateCallback("font_family_selected", &fontFamilySelected);
            class.bindTemplateCallback("font_clear_clicked", &fontClearClicked);
            class.bindTemplateCallback("right_click_selected", &rightClickSelected);
            class.bindTemplateCallback("scrollbar_toggled", &scrollbarToggled);
            class.bindTemplateCallback("close_confirmation_selected", &closeConfirmationSelected);
            class.bindTemplateCallback("focus_follows_mouse_toggled", &focusFollowsMouseToggled);
            class.bindTemplateCallback("ctrl_scroll_zoom_toggled", &ctrlScrollZoomToggled);
            class.bindTemplateCallback("ctrl_scroll_zoom_reset_clicked", &ctrlScrollZoomResetClicked);
            class.bindTemplateCallback("bell_toggled", &bellToggled);
            class.bindTemplateCallback("shell_selected", &shellSelected);
            class.bindTemplateCallback("open_folder_clicked", &openFolderClicked);
            class.bindTemplateCallback("open_config_clicked", &openConfigClicked);
            class.bindTemplateCallback("theme_subpage_shown", &themeSubpageShown);
            class.bindTemplateCallback("theme_subpage_hidden", &themeSubpageHidden);
            class.bindTemplateCallback("theme_search_changed", &themeSearchChanged);
            class.bindTemplateCallback("theme_search_activated", &themeSearchActivated);
            class.bindTemplateCallback("theme_search_stopped", &themeSearchStopped);
            class.bindTemplateCallback("theme_revert_clicked", &themeRevertClicked);
            class.bindTemplateCallback("theme_apply_clicked", &themeApplyClicked);
            class.bindTemplateCallback("theme_list_activated", &themeListActivated);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// The colors of a theme, as the theme lists of both app runtimes show
/// them: its background with "Aa" in its foreground, and the six bright
/// palette colors.
const ThemeSwatch = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyGxThemeSwatch",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        swatch: theme_swatch.Swatch,

        pub var offset: c_int = 0;
    };

    const width = 76;
    const height = 22;
    const radius = 4;
    const text_width = 26;
    const dot = 6;
    const dot_gap = 2;

    /// `gsk.RoundedRect`, which is only reachable through the GTK
    /// functions that take it.
    const RoundedRect = @typeInfo(@typeInfo(@TypeOf(gtk.Snapshot.pushRoundedClip)).@"fn".params[1].type.?).pointer.child;

    fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn set(self: *Self, swatch: theme_swatch.Swatch) void {
        const priv = self.private();
        if (std.meta.eql(priv.swatch, swatch)) return;
        priv.swatch = swatch;
        self.as(gtk.Widget).queueDraw();
    }

    fn rgba(color: theme_swatch.Rgb) gdk.RGBA {
        return .{
            .f_red = @as(f32, @floatFromInt(color.r)) / 255,
            .f_green = @as(f32, @floatFromInt(color.g)) / 255,
            .f_blue = @as(f32, @floatFromInt(color.b)) / 255,
            .f_alpha = 1,
        };
    }

    fn rect(x: f32, y: f32, w: f32, h: f32) graphene.Rect {
        return .{ .f_origin = .{ .f_x = x, .f_y = y }, .f_size = .{ .f_width = w, .f_height = h } };
    }

    fn rounded(bounds: graphene.Rect, r: f32) RoundedRect {
        return .{ .f_bounds = bounds, .f_corner = @splat(.{ .f_width = r, .f_height = r }) };
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        const swatch = self.private().swatch;
        const w: f32 = @floatFromInt(widget.getWidth());
        const h: f32 = @floatFromInt(widget.getHeight());
        if (w <= 0 or h <= 0) return;

        const outline = rounded(rect(0, 0, w, h), radius);
        snap.pushRoundedClip(&outline);
        snap.appendColor(&rgba(swatch.background), &outline.f_bounds);

        const layout = widget.createPangoLayout(null);
        defer layout.unref();
        layout.setMarkup("<span weight=\"bold\" size=\"small\">Aa</span>", -1);
        var text_w: c_int = 0;
        var text_h: c_int = 0;
        layout.getPixelSize(&text_w, &text_h);
        snap.save();
        snap.translate(&.{
            .f_x = @round((text_width - @as(f32, @floatFromInt(text_w))) / 2),
            .f_y = @round((h - @as(f32, @floatFromInt(text_h))) / 2),
        });
        snap.appendLayout(layout, &rgba(swatch.foreground));
        snap.restore();

        var x: f32 = text_width;
        const y = @round((h - dot) / 2);
        for (1..7) |i| {
            const bounds = rounded(rect(x, y, dot, dot), 1.5);
            snap.pushRoundedClip(&bounds);
            snap.appendColor(&rgba(swatch.color(i)), &bounds.f_bounds);
            snap.pop();
            x += dot + dot_gap;
        }
        snap.pop();

        var border: gdk.RGBA = undefined;
        widget.getColor(&border);
        border.f_alpha *= 0.25;
        snap.appendBorder(&outline, &@as([4]f32, @splat(1)), &@as([4]gdk.RGBA, @splat(border)));
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().* = .{ .swatch = .{} };
        const widget = self.as(gtk.Widget);
        widget.setSizeRequest(width, height);
        widget.setValign(.center);
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub const as = C.Class.as;
    };
};

const testing = std.testing;

test "themeValue sets one half of a light and dark pair" {
    const alloc = testing.allocator;
    const cases = [_]struct { ThemeTarget, ?[]const u8, ?[]const u8, []const u8, []const u8 }{
        .{ .single, "Old", "Old", "GX Mocha", "GX Mocha" },
        .{ .single, null, null, "GX Mocha", "GX Mocha" },
        .{ .light, "Old Light", "Old Dark", "New Light", "light:New Light,dark:Old Dark" },
        .{ .dark, "Old Light", "Old Dark", "New Dark", "light:Old Light,dark:New Dark" },
        // Choosing the other half's theme leaves one theme.
        .{ .light, "Old Light", "Same", "Same", "Same" },
        .{ .dark, null, null, "Only", "Only" },
    };
    for (cases) |case| {
        const value = try themeValue(alloc, case[0], case[1], case[2], case[3]);
        defer alloc.free(value);
        try testing.expectEqualStrings(case[4], value);
    }
}

test "commandText drops the prefix of the command syntax" {
    try testing.expectEqualStrings("/usr/bin/zsh -l", commandText("direct:/usr/bin/zsh -l"));
    try testing.expectEqualStrings("fish", commandText("shell:fish"));
    try testing.expectEqualStrings("'/opt/my shell/zsh' -l", commandText("'/opt/my shell/zsh' -l"));
    try testing.expectEqualStrings("", commandText(""));
}

test "movedPosition clamps to the list" {
    try testing.expectEqual(@as(?usize, null), movedPosition(null, 1, 0));
    try testing.expectEqual(@as(?usize, 0), movedPosition(null, 1, 5));
    try testing.expectEqual(@as(?usize, 4), movedPosition(null, -1, 5));
    try testing.expectEqual(@as(?usize, 3), movedPosition(2, 1, 5));
    try testing.expectEqual(@as(?usize, 0), movedPosition(2, -10, 5));
    try testing.expectEqual(@as(?usize, 4), movedPosition(2, 10, 5));
    try testing.expectEqual(@as(?usize, 9), movedPosition(null, 10, 20));
}

test "opacity and padding texts" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("85%", try opacityText(&buf, 0.85));
    try testing.expectEqualStrings("100%", try opacityText(&buf, 1.5));
    try testing.expectEqualStrings("12", try paddingValue(&buf, .{ .top_left = 12, .bottom_right = 12 }));
    try testing.expectEqualStrings("4,8", try paddingValue(&buf, .{ .top_left = 4, .bottom_right = 8 }));
}

test "values the custom padding writes parse back" {
    for ([_]CoreConfig.WindowPadding{
        .{ .top_left = 12, .bottom_right = 12 },
        .{ .top_left = 4, .bottom_right = 8 },
    }) |padding| {
        var buf: [32]u8 = undefined;
        var arg_buf: [64]u8 = undefined;
        const arg = try std.fmt.bufPrint(&arg_buf, "--window-padding-x={s}", .{try paddingValue(&buf, padding)});
        var cfg = try CoreConfig.default(testing.allocator);
        defer cfg.deinit();
        var it = @import("../../../cli.zig").args.sliceIterator(&.{arg});
        try cfg.loadIter(testing.allocator, &it);
        try testing.expect(cfg.@"window-padding-x".equal(padding));
    }
}

test "a save that writes the previewed theme ends the preview" {
    const Dialog = GxSettingsDialog;
    const theme: []const settings_map.Changes.Entry = &.{.{ .key = "theme", .values = &.{"Chalkboard"} }};

    // Retry after a failed Apply: the recorded theme is the previewed one,
    // so the save ends the preview and shows the theme as saved.
    const retried = Dialog.saveEffects(theme, true, "Chalkboard", null);
    try testing.expect(retried.end_preview);
    try testing.expect(retried.sync.theme and !retried.sync.saved_theme);

    // Another theme is previewed meanwhile: it stays previewed and the
    // saved theme is read from the saved layers.
    const other = Dialog.saveEffects(theme, true, "Dracula", null);
    try testing.expect(!other.end_preview);
    try testing.expect(!other.sync.theme and other.sync.saved_theme);

    // A pair value and a removed theme are not the previewed single theme.
    const pair: []const settings_map.Changes.Entry = &.{.{ .key = "theme", .values = &.{"light:Chalkboard,dark:Dracula"} }};
    try testing.expect(Dialog.saveEffects(pair, true, "Chalkboard", null).sync.saved_theme);
    const reset: []const settings_map.Changes.Entry = &.{.{ .key = "theme", .values = &.{} }};
    try testing.expect(!Dialog.saveEffects(reset, true, "Chalkboard", null).end_preview);

    // Without a preview the applied configuration has the saved theme.
    const plain = Dialog.saveEffects(theme, false, null, null);
    try testing.expect(!plain.end_preview and plain.sync.theme and !plain.sync.saved_theme);

    // Other settings saved during a preview leave the theme as it was, and a
    // pending font family survives a retry that also saves the theme.
    const font: []const settings_map.Changes.Entry = &.{.{ .key = "font-size", .values = &.{"14"} }};
    const during = Dialog.saveEffects(font, true, "Chalkboard", null);
    try testing.expect(!during.end_preview and !during.sync.theme and !during.sync.saved_theme);
    const resumed = Dialog.saveEffects(theme, true, "Chalkboard", .{ .font_family = true, .theme = false });
    try testing.expect(resumed.end_preview and resumed.sync.theme and resumed.sync.font_family);
}

test "failed settings saves preserve font edits and resets for retry" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "not a directory" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const blocked = try std.fs.path.join(alloc, &.{ root, "blocked", gx.gui_settings.file_name });
    defer alloc.free(blocked);
    const path = try std.fs.path.join(alloc, &.{ root, gx.gui_settings.file_name });
    defer alloc.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = gx.gui_settings.file_name, .data = "font-size = 18\n" });

    var changes = settings_map.Changes.init(alloc);
    defer changes.deinit();
    const families = try settings_map.fontFamilies(alloc, "New Mono", &.{ "Old Mono", "CJK Fallback" });
    defer alloc.free(families);
    try changes.setAll("font-family", families);
    try changes.reset("font-size");
    try testing.expectError(error.NotDir, changes.commit(alloc, io, blocked));
    try testing.expectEqual(@as(usize, 2), changes.entries.items.len);
    try changes.commit(alloc, io, path);
    try testing.expect(changes.isEmpty());
    var overlay = try gx.gui_settings.Overlay.load(alloc, io, path);
    defer overlay.deinit();
    try testing.expectEqual(@as(?[]const u8, null), overlay.get("font-size"));
    var saved: std.Io.Writer.Allocating = .init(alloc);
    defer saved.deinit();
    try overlay.write(&saved.writer);
    try testing.expectEqualStrings("font-family = New Mono\nfont-family = CJK Fallback\n", saved.written());
}

test "reverting after a failed theme save keeps the reverted theme out of later saves" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "not a directory" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const blocked = try std.fs.path.join(alloc, &.{ root, "blocked", gx.gui_settings.file_name });
    defer alloc.free(blocked);
    const path = try std.fs.path.join(alloc, &.{ root, gx.gui_settings.file_name });
    defer alloc.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = gx.gui_settings.file_name, .data = "theme = Saved\n" });

    // Apply fails while a font size waits for the same save (D-15).
    var changes = settings_map.Changes.init(alloc);
    defer changes.deinit();
    try changes.set("font-size", "14");
    try changes.set("theme", "Chalkboard");
    try testing.expectError(error.NotDir, changes.commit(alloc, io, blocked));

    // Revert, then the next save: Retry, another change or closing.
    const dropped = GxSettingsDialog.dropThemeChange(&changes);
    try changes.commit(alloc, io, path);
    var overlay = try gx.gui_settings.Overlay.load(alloc, io, path);
    defer overlay.deinit();
    try testing.expectEqualStrings("Saved", overlay.get("theme") orelse "");
    try testing.expectEqualStrings("14", overlay.get("font-size") orelse "");
    try testing.expect(dropped);

    // Only the theme is dropped; without a recorded theme nothing is.
    try changes.set("cursor-style", "bar");
    try testing.expect(!GxSettingsDialog.dropThemeChange(&changes));
    try testing.expectEqual(@as(usize, 1), changes.entries.items.len);
}

test "reverting settles a failed theme save, or applies a theme that was saved but not applied" {
    const alloc = testing.allocator;
    const Dialog = GxSettingsDialog;

    // Only the theme failed to save: Revert, going back or selecting the
    // saved theme again drop it, nothing is left to save or retry, and the
    // dialog can close while the folder stays read-only.
    var only = settings_map.Changes.init(alloc);
    defer only.deinit();
    try only.set("theme", "Chalkboard");
    const settled = Dialog.revertChanges(&only, false);
    try testing.expect(settled.dropped and settled.settled and !settled.reapply);
    try testing.expect(only.isEmpty());

    // Another change still waits for its retry: it stays, and so does the
    // retry toast.
    var mixed = settings_map.Changes.init(alloc);
    defer mixed.deinit();
    try mixed.set("font-size", "14");
    try mixed.set("theme", "Chalkboard");
    const waiting = Dialog.revertChanges(&mixed, false);
    try testing.expect(waiting.dropped and !waiting.settled and !waiting.reapply);
    try testing.expectEqual(@as(usize, 1), mixed.entries.items.len);
    try testing.expectEqualStrings("font-size", mixed.entries.items[0].key);

    // The save wrote the theme and only applying it failed: nothing is
    // dropped, the saved configuration is applied again and shown as saved
    // rather than as undone; a theme that failed to save after that is
    // dropped as well.
    var written = settings_map.Changes.init(alloc);
    defer written.deinit();
    const reapplied = Dialog.revertChanges(&written, true);
    try testing.expect(!reapplied.dropped and !reapplied.settled and reapplied.reapply);
    try written.set("theme", "Dracula");
    const both = Dialog.revertChanges(&written, true);
    try testing.expect(both.dropped and !both.settled and both.reapply);
    try testing.expect(written.isEmpty());

    // Reverting a plain preview has nothing to settle.
    const plain = Dialog.revertChanges(&written, false);
    try testing.expect(!plain.dropped and !plain.settled and !plain.reapply);
}

test "applying saved settings while another theme stays previewed reads the saved theme from the layers" {
    const Dialog = GxSettingsDialog;

    // A save wrote the theme, applying it failed, another theme is previewed
    // and Retry applies: the applied configuration has the preview, so the
    // saved theme comes from the layers.
    const retried = Dialog.appliedSync(.{ .theme = true }, true);
    try testing.expect(!retried.theme and retried.saved_theme);
    const kept = Dialog.appliedSync(.{ .theme = false, .saved_theme = true, .font_family = true }, true);
    try testing.expect(!kept.theme and kept.saved_theme and kept.font_family);

    // Other settings saved during a preview leave the theme rows.
    const font = Dialog.appliedSync(.{ .theme = false, .font_family = true }, true);
    try testing.expect(!font.theme and !font.saved_theme and font.font_family);

    // Without a preview the applied configuration has the saved theme.
    const plain = Dialog.appliedSync(.{ .theme = false, .saved_theme = true }, false);
    try testing.expect(plain.theme and !plain.saved_theme);
}

test "a kept dialog opens again only while its language and theme stay and no reload came" {
    const alloc = testing.allocator;
    var config = try CoreConfig.default(alloc);
    defer config.deinit();
    config.language = "en";
    config.theme = .{ .light = "Light", .dark = "Dark" };
    const built: Built = .of(&config);
    try testing.expect(GxSettingsDialog.upToDate(built, false, &config));
    // A reload, or another settings UI, came while it was closed.
    try testing.expect(!GxSettingsDialog.upToDate(built, true, &config));

    var other = try config.clone(alloc);
    defer other.deinit();
    other.theme = .{ .light = "Dark", .dark = "Light" };
    try testing.expect(!GxSettingsDialog.upToDate(built, false, &other));
    other.theme = null;
    try testing.expect(!GxSettingsDialog.upToDate(built, false, &other));
    other.theme = config.theme;
    try testing.expect(GxSettingsDialog.upToDate(built, false, &other));
    other.language = "zh-CN";
    try testing.expect(!GxSettingsDialog.upToDate(built, false, &other));

    // Other settings it shows are synced at the next opening instead.
    other.language = config.language;
    other.@"font-size" = 18;
    try testing.expect(GxSettingsDialog.upToDate(built, false, &other));
    try testing.expect(themeStamp(.{ .light = "ab", .dark = "c" }) != themeStamp(.{ .light = "a", .dark = "bc" }));
}

test "the dialog strings are translated" {
    var missing: usize = 0;
    inline for (@typeInfo(text).@"struct".decls) |decl| {
        const id = @field(text, decl.name);
        if (gx.i18n.lookup(.zh_CN, id) == null) {
            std.debug.print("missing zh-CN translation for {s}\n", .{id});
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}
