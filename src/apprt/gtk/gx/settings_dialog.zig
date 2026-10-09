//! The Ghostty GX settings dialog (fork patch GX-0015): the settings of
//! `src/gx/settings_map.zig` in an `Adw.PreferencesDialog`. Every change
//! is saved to the settings overlay `gui-settings.ghostty` (never to the
//! user's configuration file) and the configuration is reloaded; changes
//! made in quick succession are saved together.
//!
//! Moving through the theme list previews each theme: the configuration
//! is loaded with an in-memory `--theme` override and applied without
//! saving and without the "Reloaded the configuration" toast. Applying a
//! theme saves it; closing the dialog without applying reverts the
//! preview.
//!
//! The text is translated with the Ghostty GX tables (`src/gx/i18n.zig`,
//! not gettext) into the language the configuration selects when the
//! dialog opens. Each opening builds a new dialog, so it follows a
//! language change.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
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

const settings_map = gx.settings_map;
const msg = settings_map.msg;
const CoreConfig = configpkg.Config;

const log = std.log.scoped(.gtk_ghostty_gx_settings);

/// How long changes are collected before they are saved, in milliseconds.
const save_delay_ms = 300;

/// How long the theme selection has to rest before it is previewed, in
/// milliseconds, so holding an arrow key does not reload for every row.
const preview_delay_ms = 150;

/// How often, and how many times, focusing the selected theme waits for
/// the theme list to be laid out.
const focus_retry_ms = 20;
const max_focus_attempts = 50;

/// The languages of the language row, in display order.
const languages = std.enums.values(gx.i18n.Language);

/// The material presets of the material row, in display order.
const materials = std.enums.values(settings_map.Material);

/// The open dialog, if any. Opening the settings again presents it.
var open_dialog: WeakRef(GxSettingsDialog) = .empty;

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
        theme_apply_button: *gtk.Button,
        theme_search: *gtk.SearchEntry,
        theme_list: *gtk.ListBox,
        material_group: *adw.PreferencesGroup,
        material_row: *adw.ComboRow,
        font_page: *adw.PreferencesPage,
        font_size_row: *adw.SpinRow,
        font_family_group: *adw.PreferencesGroup,
        font_family_row: *adw.EntryRow,
        interaction_page: *adw.PreferencesPage,
        right_click_row: *adw.ComboRow,
        scrollbar_row: *adw.SwitchRow,
        close_confirmation_row: *adw.ComboRow,
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
        version_row: *adw.ActionRow,
        config_path_row: *adw.ActionRow,
        open_config_button: *gtk.Button,
        settings_file_group: *adw.PreferencesGroup,
        settings_path_row: *adw.ActionRow,

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
        /// Without them (`GHOSTTY_GX_DEFAULTS=0`) themes are not previewed.
        layered: bool = true,

        /// Changes not saved yet, and the timer that saves them.
        changes: settings_map.Changes,
        save_source: ?c_uint = null,

        /// The listed themes (a theme's index is its row index), the
        /// saved theme, the previewed theme and the timer that previews it.
        themes: ?settings_map.ThemeList = null,
        saved_theme: ?usize = null,
        preview_theme: ?usize = null,
        preview_source: ?c_uint = null,

        /// The timer of `focusSelectedTheme` and how often it waited for
        /// the list layout.
        focus_source: ?c_uint = null,
        focus_attempts: u8 = 0,

        /// The in-app notifications of the configuration when the dialog
        /// opened; previews keep them except the reload toast.
        notifications: CoreConfig.AppNotifications = .{},

        /// The shell choices; a choice's index is its position in the
        /// shell row.
        shells: []const Shell = &.{},

        /// The command new terminals run when the overlay sets none.
        default_command: [:0]const u8 = "",

        /// The herdr executable, if herdr was detected.
        herdr: ?[:0]const u8 = null,
    };

    const Shell = struct {
        /// The `command` value, or null to remove `command` from the
        /// overlay.
        command: ?[:0]const u8,

        /// The GX Zsh executable, when the choice is GX Zsh.
        gx_zsh: ?[:0]const u8 = null,
    };

    //---------------------------------------------------------------
    // Opening

    /// Shows the settings dialog over the active window of `app`, or
    /// brings the open one to the front.
    pub fn show(app: *Application) void {
        if (!adw_version.supportsDialogs()) {
            log.warn("the settings dialog needs libadwaita 1.5 or newer", .{});
            return;
        }

        const parent: ?*gtk.Widget = if (app.as(gtk.Application).getActiveWindow()) |window|
            window.as(gtk.Widget)
        else
            null;

        if (open_dialog.get()) |dialog| {
            defer dialog.unref();
            dialog.as(adw.Dialog).present(parent);
            return;
        }

        const dialog = gobject.ext.newInstance(Self, .{});
        dialog.load(app);
        open_dialog.set(dialog);
        dialog.as(adw.Dialog).present(parent);
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

    //---------------------------------------------------------------
    // Filling in the widgets

    fn load(self: *Self, app: *Application) void {
        const st = &self.private().state;
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();

        st.lang = gx.i18n.resolve(config.language);
        st.notifications = config.@"app-notifications";
        st.layered = gx.config_layers.enabled(st.alloc);
        st.loading = true;
        defer st.loading = false;

        self.loadLanguage();
        self.loadAppearance(config);
        self.loadFont(config);
        self.loadInteraction(config);
        self.loadShell(config);
        self.loadAbout();
    }

    fn loadLanguage(self: *Self) void {
        const priv = self.private();
        self.as(adw.Dialog).setTitle(self.tr(msg.settings));
        priv.language_page.setTitle(self.tr(msg.language));
        priv.language_group.setDescription(self.tr(msg.changes_saved));
        priv.language_row.as(adw.PreferencesRow).setTitle(self.tr(msg.interface_language));

        const model = gtk.StringList.new(null);
        defer model.unref();
        for (languages) |lang| model.append(lang.nativeName());
        priv.language_row.setModel(model.as(gio.ListModel));
        const index = std.mem.indexOfScalar(gx.i18n.Language, languages, priv.state.lang) orelse 0;
        priv.language_row.setSelected(@intCast(index));
    }

    fn loadAppearance(self: *Self, config: *const CoreConfig) void {
        const priv = self.private();
        const st = &priv.state;
        priv.appearance_page.setTitle(self.tr(msg.appearance));
        priv.theme_group.setTitle(self.tr(msg.theme));
        priv.theme_group.setDescription(self.tr(msg.theme_hint));
        priv.theme_apply_button.setLabel(self.tr(msg.apply));
        priv.theme_search.setPlaceholderText(self.tr(msg.search_themes));
        priv.theme_search.setKeyCaptureWidget(priv.theme_list.as(gtk.Widget));

        const placeholder = gtk.Label.new(self.tr(msg.no_themes));
        placeholder.as(gtk.Widget).addCssClass("dim-label");
        placeholder.as(gtk.Widget).setMarginTop(12);
        placeholder.as(gtk.Widget).setMarginBottom(12);
        priv.theme_list.setPlaceholder(placeholder.as(gtk.Widget));
        priv.theme_list.setFilterFunc(themeFilter, self, null);

        var dirs_arena: ArenaAllocator = .init(st.alloc);
        defer dirs_arena.deinit();
        var dirs: std.ArrayList([]const u8) = .empty;
        var it: themepkg.LocationIterator = .{ .arena_alloc = dirs_arena.allocator() };
        while (it.next() catch null) |location| {
            dirs.append(dirs_arena.allocator(), location.dir) catch break;
        }
        st.themes = settings_map.listThemes(st.alloc, global.io(), dirs.items) catch |err| list: {
            log.warn("cannot list the themes err={}", .{err});
            break :list null;
        };

        for (self.themeNames()) |name| {
            const label = gtk.Label.new(name.ptr);
            label.setXalign(0);
            const row = gtk.ListBoxRow.new();
            row.setChild(label.as(gtk.Widget));
            priv.theme_list.append(row.as(gtk.Widget));
        }

        if (settings_map.themeName(config.theme)) |current| {
            for (self.themeNames(), 0..) |name, index| {
                if (!std.mem.eql(u8, name, current)) continue;
                st.saved_theme = index;
                if (priv.theme_list.getRowAtIndex(@intCast(index))) |row| priv.theme_list.selectRow(row);
                break;
            }
        }

        priv.material_row.as(adw.PreferencesRow).setTitle(self.tr(msg.window_material));
        priv.material_group.setDescription(self.tr(msg.material_hint));
        const model = gtk.StringList.new(null);
        defer model.unref();
        for (materials) |material| model.append(self.tr(material.label()));
        priv.material_row.setModel(model.as(gio.ListModel));
        const current = settings_map.Material.fromConfig(
            config.@"background-opacity",
            config.@"background-blur".enabled(),
        );
        const index = std.mem.indexOfScalar(settings_map.Material, materials, current) orelse 0;
        priv.material_row.setSelected(@intCast(index));
    }

    fn loadFont(self: *Self, config: *const CoreConfig) void {
        const priv = self.private();
        priv.font_page.setTitle(self.tr(msg.font));

        priv.font_size_row.as(adw.PreferencesRow).setTitle(self.tr(msg.font_size));
        priv.font_size_row.setValue(settings_map.FontSize.normalize(config.@"font-size"));
        const reset = gtk.Button.newWithLabel(self.tr(msg.reset_to_default));
        reset.as(gtk.Widget).setValign(.center);
        reset.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(reset, *Self, fontSizeResetClicked, self, .{});
        priv.font_size_row.as(adw.ActionRow).addSuffix(reset.as(gtk.Widget));

        priv.font_family_group.setDescription(self.tr(msg.font_family_hint));
        priv.font_family_row.as(adw.PreferencesRow).setTitle(self.tr(msg.font_family));
        const families = config.@"font-family".list.items;
        priv.font_family_row.as(gtk.Editable).setText(if (families.len > 0) families[0] else "");
    }

    fn loadInteraction(self: *Self, config: *const CoreConfig) void {
        const priv = self.private();
        priv.interaction_page.setTitle(self.tr(msg.interaction));

        priv.right_click_row.as(adw.PreferencesRow).setTitle(self.tr(msg.right_click));
        self.setChoices(
            CoreConfig.RightClickAction,
            priv.right_click_row,
            &settings_map.right_click_choices,
            config.@"right-click-action",
        );

        priv.scrollbar_row.as(adw.PreferencesRow).setTitle(self.tr(msg.show_scrollbar));
        priv.scrollbar_row.setActive(@intFromBool(config.scrollbar == .system));

        priv.close_confirmation_row.as(adw.PreferencesRow).setTitle(self.tr(msg.close_confirmation));
        self.setChoices(
            CoreConfig.ConfirmCloseSurface,
            priv.close_confirmation_row,
            &settings_map.close_confirmation_choices,
            config.@"confirm-close-surface",
        );

        priv.bell_group.setTitle(self.tr(msg.bell));
        const rows = self.bellRows();
        inline for (settings_map.bell_features, 0..) |feature, i| {
            rows[i].as(adw.PreferencesRow).setTitle(self.tr(feature.label));
            rows[i].setActive(@intFromBool(@field(config.@"bell-features", feature.field)));
        }
    }

    fn loadShell(self: *Self, config: *const CoreConfig) void {
        const priv = self.private();
        const st = &priv.state;
        const arena = st.arena.allocator();
        priv.shell_page.setTitle(self.tr(msg.shell));
        priv.shell_group.setDescription(self.tr(msg.default_shell_hint));
        priv.shell_row.as(adw.PreferencesRow).setTitle(self.tr(msg.default_shell));

        if (config.command) |command| {
            st.default_command = command.string(arena) catch "";
        }
        const overlay_command = self.overlayValue(arena, "command");

        var shells: std.ArrayList(Shell) = .empty;
        const model = gtk.StringList.new(null);
        defer model.unref();
        model.append(self.tr(msg.system_default));
        shells.append(arena, .{ .command = null }) catch return;
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
                const name = self.profileName(arena, profile) catch continue;
                const exe: ?[:0]const u8 = switch (profile.command) {
                    .argv => |argv| if (argv.len > 0) arena.dupeZ(u8, argv[0]) catch null else null,
                    .command_line => null,
                };
                if (profile.kind == .herdr) st.herdr = exe;
                shells.append(arena, .{
                    .command = command,
                    .gx_zsh = if (profile.kind == .gx_zsh) exe else null,
                }) catch break;
                model.append(name);
                if (selected == null and std.mem.eql(u8, overlay_command.?, command)) {
                    selected = shells.items.len - 1;
                }
            }
        } else |err| {
            log.warn("cannot detect the shells err={}", .{err});
        }

        if (selected == null) {
            // A command the settings UI did not write.
            selected = self.appendCustomShell(arena, &shells, model, overlay_command.?) catch null;
        }

        st.shells = shells.items;
        priv.shell_row.setModel(model.as(gio.ListModel));
        priv.shell_row.setSelected(@intCast(selected orelse 0));
        self.updateShellSubtitle();
    }

    /// Adds a shell choice for a `command` that is none of the profiles
    /// and returns its position.
    fn appendCustomShell(
        self: *Self,
        arena: Allocator,
        shells: *std.ArrayList(Shell),
        model: *gtk.StringList,
        command: []const u8,
    ) Allocator.Error!usize {
        const name = try self.fill(arena, msg.custom_command, .{ .command = command });
        try shells.append(arena, .{ .command = try arena.dupeZ(u8, command) });
        model.append(name);
        return shells.items.len - 1;
    }

    fn loadAbout(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const arena = st.arena.allocator();
        priv.about_page.setTitle(self.tr(msg.about));

        priv.version_row.as(adw.PreferencesRow).setTitle(self.tr(msg.app_name));
        if (self.fill(arena, msg.version, .{ .version = build_config.version_string })) |version| {
            priv.version_row.setSubtitle(version);
        } else |_| {}

        priv.config_path_row.as(adw.PreferencesRow).setTitle(self.tr(msg.config_file));
        priv.open_config_button.setLabel(self.tr(msg.open_config_file));
        if (file_load.preferredDefaultFilePath(arena)) |path| {
            if (arena.dupeZ(u8, path)) |path_z| priv.config_path_row.setSubtitle(path_z) else |_| {}
        } else |err| {
            log.warn("cannot locate the configuration file err={}", .{err});
        }

        priv.settings_file_group.setDescription(self.tr(msg.settings_file_hint));
        priv.settings_path_row.as(adw.PreferencesRow).setTitle(self.tr(msg.settings_file));
        if (gx.config_layers.overlayPath(arena)) |path| {
            if (arena.dupeZ(u8, path)) |path_z| priv.settings_path_row.setSubtitle(path_z) else |_| {}
        } else |err| {
            log.warn("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
        }
    }

    fn setChoices(
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

    /// The name of a launch profile in the language of the dialog, like
    /// `gx.profiles.displayName`.
    fn profileName(self: *Self, alloc: Allocator, profile: gx.profiles.Profile) Allocator.Error![:0]u8 {
        if (profile.kind == .custom) return try alloc.dupeZ(u8, profile.name);
        return try self.fill(alloc, profile.name, .{ .name = profile.name_arg orelse "" });
    }

    /// Shows `msgid`, with its placeholders filled in, as a toast.
    fn toast(self: *Self, msgid: [:0]const u8, args: anytype) void {
        const st = &self.private().state;
        if (st.disposed) return;
        const alloc = st.alloc;
        const text = self.fill(alloc, msgid, args) catch return;
        defer alloc.free(text);
        const item = adw.Toast.new(text);
        item.setUseMarkup(0);
        item.setTimeout(5);
        self.as(adw.PreferencesDialog).addToast(item);
    }

    fn toastError(self: *Self, msgid: [:0]const u8, err: anyerror) void {
        self.toast(msgid, .{ .reason = @errorName(err) });
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
        if (!st.disposed) self.saveNow();
        return 0;
    }

    /// Saves the recorded changes to the overlay and reloads the
    /// configuration.
    fn saveNow(self: *Self) void {
        const st = &self.private().state;
        if (st.save_source) |source| {
            st.save_source = null;
            _ = glib.Source.remove(source);
        }
        if (st.changes.isEmpty()) return;

        const path = gx.config_layers.overlayPath(st.alloc) catch |err| {
            log.warn("cannot locate {s} err={}", .{ gx.gui_settings.file_name, err });
            st.changes.clear();
            self.toastError(msg.save_failed, err);
            return;
        };
        defer st.alloc.free(path);
        st.changes.commit(st.alloc, global.io(), path) catch |err| {
            log.warn("cannot save {s} err={}", .{ path, err });
            st.changes.clear();
            self.toastError(msg.save_failed, err);
            return;
        };
        self.reload();
    }

    /// Applies the saved settings, and the previewed theme if there is
    /// one, to the running application.
    fn reload(self: *Self) void {
        const st = &self.private().state;
        if (st.preview_theme) |index| {
            self.reloadWith(self.themeNames()[index]);
            return;
        }
        const app = Application.default();
        app.core().performAction(app.rt(), .reload_config) catch |err| {
            log.warn("cannot reload the configuration err={}", .{err});
            self.toastError(msg.reload_failed, err);
        };
    }

    /// Loads the configuration with in-memory overrides, the previewed
    /// `theme` (if any) and no reload toast, and applies it without
    /// saving anything.
    fn reloadWith(self: *Self, theme: ?[]const u8) void {
        const st = &self.private().state;
        const failed: [:0]const u8 = if (theme != null) msg.preview_failed else msg.reload_failed;

        var quiet_buf: [128]u8 = undefined;
        const quiet = settings_map.quietReloadArg(&quiet_buf, st.notifications) catch |err| {
            self.toastError(failed, err);
            return;
        };
        var args: [2][:0]const u8 = .{ quiet, undefined };
        var len: usize = 1;
        var theme_arg: ?[:0]u8 = null;
        defer if (theme_arg) |arg| st.alloc.free(arg);
        if (theme) |name| {
            theme_arg = settings_map.themeArg(st.alloc, name) catch |err| {
                self.toastError(failed, err);
                return;
            };
            args[1] = theme_arg.?;
            len = 2;
        }

        var config = gx.config_layers.loadWithOverrides(st.alloc, args[0..len]) catch |err| {
            log.warn("cannot load the configuration err={}", .{err});
            self.toastError(failed, err);
            return;
        };
        defer config.deinit();
        const app = Application.default();
        app.core().updateConfig(app.rt(), &config) catch |err| {
            log.warn("cannot apply the configuration err={}", .{err});
            self.toastError(failed, err);
        };
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

    //---------------------------------------------------------------
    // Themes

    fn themeNames(self: *Self) []const [:0]const u8 {
        const st = &self.private().state;
        return if (st.themes) |list| list.names else &.{};
    }

    fn themeIndex(self: *Self, row: *gtk.ListBoxRow) ?usize {
        const index = row.getIndex();
        if (index < 0 or index >= self.themeNames().len) return null;
        return @intCast(index);
    }

    fn themeFilter(row: *gtk.ListBoxRow, ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 1));
        const query = std.mem.trim(
            u8,
            std.mem.span(self.private().theme_search.as(gtk.Editable).getText()),
            &std.ascii.whitespace,
        );
        if (query.len == 0) return 1;
        const index = self.themeIndex(row) orelse return 0;
        return @intFromBool(std.ascii.indexOfIgnoreCase(self.themeNames()[index], query) != null);
    }

    fn cancelPreview(self: *Self) void {
        const st = &self.private().state;
        if (st.preview_source) |source| {
            st.preview_source = null;
            _ = glib.Source.remove(source);
        }
    }

    fn previewTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const st = &self.private().state;
        st.preview_source = null;
        if (st.disposed) return 0;
        if (st.preview_theme) |index| self.reloadWith(self.themeNames()[index]);
        return 0;
    }

    /// Saves the selected theme.
    fn applyTheme(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        if (st.disposed) return;
        const row = priv.theme_list.getSelectedRow() orelse return;
        const index = self.themeIndex(row) orelse return;
        self.cancelPreview();
        st.preview_theme = null;
        st.saved_theme = index;
        priv.theme_apply_button.as(gtk.Widget).setSensitive(0);
        self.queueSet("theme", self.themeNames()[index]);
        self.saveNow();
    }

    /// Focuses the selected theme, which scrolls the list to it. Rows are
    /// only laid out a frame after the list is mapped, so this retries
    /// until the row has a size (at most `max_focus_attempts` times).
    fn focusSelectedTheme(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        const st = &priv.state;
        const again = again: {
            if (st.disposed) break :again false;
            if (priv.theme_list.as(gtk.Widget).getMapped() == 0) break :again false;
            const row = priv.theme_list.getSelectedRow() orelse break :again false;
            const widget = row.as(gtk.Widget);
            if (widget.getHeight() == 0 and widget.getChildVisible() != 0) {
                st.focus_attempts += 1;
                break :again st.focus_attempts < max_focus_attempts;
            }
            _ = widget.grabFocus();
            break :again false;
        };
        if (!again) st.focus_source = null;
        return @intFromBool(again);
    }

    //---------------------------------------------------------------
    // Shells and herdr

    fn updateShellSubtitle(self: *Self) void {
        const priv = self.private();
        const st = &priv.state;
        const index = priv.shell_row.getSelected();
        if (index >= st.shells.len) return;
        priv.shell_row.as(adw.ActionRow).setSubtitle(st.shells[index].command orelse st.default_command);
    }

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
            self.toast(msg.herdr_failed, .{ .reason = reason });
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
            self.toast(msg.herdr_failed, .{ .reason = reason });
            return;
        }
        if (process.getIfExited() == 0) {
            log.warn("herdr did not exit normally", .{});
            self.toast(msg.herdr_failed, .{ .reason = "signal" });
            return;
        }
        switch (process.getExitStatus()) {
            0 => self.toast(msg.herdr_updated, .{}),
            3 => self.toast(msg.herdr_user_config, .{}),
            else => |code| {
                log.warn("herdr --gx-set-default-shell exited with {d}", .{code});
                self.toast(msg.herdr_exit, .{ .code = code });
            },
        }
    }

    //---------------------------------------------------------------
    // Template callbacks

    /// Whether a change handler should record the change: not while the
    /// widgets are filled in or torn down.
    fn recording(self: *Self) bool {
        const st = &self.private().state;
        return !st.loading and !st.disposed;
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        const keep = self.ref();
        defer keep.unref();
        const st = &self.private().state;
        if (st.disposed) return;

        // The next opening builds a new dialog, even while this one is
        // kept alive by a timer or a running herdr.
        if (open_dialog.get()) |dialog| {
            defer dialog.unref();
            if (dialog == self) open_dialog.set(null);
        }

        self.cancelPreview();
        const previewed = st.preview_theme != null;
        st.preview_theme = null;
        if (!st.changes.isEmpty()) {
            // Saving reloads the saved settings, which ends the preview.
            self.saveNow();
        } else if (previewed) {
            self.reloadWith(null);
        }
    }

    fn languageSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const index = row.getSelected();
        if (index >= languages.len) return;
        self.queueSet("language", languages[index].configValue());
    }

    fn themeApplyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.applyTheme();
    }

    fn themeSearchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state.disposed) return;
        priv.theme_list.invalidateFilter();
    }

    /// Enter in the search entry, or in the theme list (which forwards
    /// its keys to the search entry), applies the selected theme if the
    /// search shows it.
    fn themeSearchActivated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state.disposed) return;
        const row = priv.theme_list.getSelectedRow() orelse return;
        if (row.as(gtk.Widget).getChildVisible() == 0) return;
        self.applyTheme();
    }

    fn themeListMapped(_: *gtk.ListBox, self: *Self) callconv(.c) void {
        const st = &self.private().state;
        if (st.disposed) return;
        if (st.focus_source) |source| {
            st.focus_source = null;
            _ = glib.Source.remove(source);
        }
        st.focus_attempts = 0;
        st.focus_source = glib.timeoutAddFull(
            glib.PRIORITY_DEFAULT_IDLE,
            focus_retry_ms,
            focusSelectedTheme,
            self.ref(),
            unrefData,
        );
    }

    fn themeRowSelected(_: *gtk.ListBox, row_: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const priv = self.private();
        const st = &priv.state;
        if (st.disposed) return;
        const index = if (row_) |row| self.themeIndex(row) else null;
        priv.theme_apply_button.as(gtk.Widget).setSensitive(@intFromBool(index != null and index != st.saved_theme));
        if (st.loading or !st.layered) return;
        const selected = index orelse return;
        if (st.preview_theme == null and selected == st.saved_theme) return;
        st.preview_theme = selected;
        self.cancelPreview();
        st.preview_source = glib.timeoutAddFull(
            glib.PRIORITY_DEFAULT,
            preview_delay_ms,
            previewTimeout,
            self.ref(),
            unrefData,
        );
    }

    fn themeRowActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        self.applyTheme();
    }

    fn materialSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const index = row.getSelected();
        if (index >= materials.len) return;
        for (materials[index].settings()) |setting| self.queueSet(setting.key, setting.value);
    }

    fn fontSizeChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        var buf: [32]u8 = undefined;
        const value = settings_map.FontSize.format(
            &buf,
            settings_map.FontSize.normalize(row.getValue()),
        ) catch return;
        self.queueSet("font-size", value);
    }

    fn fontSizeResetClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state.disposed) return;
        priv.font_size_row.setValue(settings_map.FontSize.default);
    }

    fn fontFamilyApplied(row: *adw.EntryRow, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const family = std.mem.trim(
            u8,
            std.mem.span(row.as(gtk.Editable).getText()),
            &std.ascii.whitespace,
        );
        if (family.len == 0) {
            self.queueSetAll("font-family", &.{});
        } else {
            self.queueSet("font-family", family);
        }
    }

    fn rightClickSelected(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.recording()) return;
        const choices = &settings_map.right_click_choices;
        const index = row.getSelected();
        if (index >= choices.len) return;
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
        self.queueSet("confirm-close-surface", @tagName(choices[index].value));
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
        self.updateShellSubtitle();
        if (st.loading) return;
        const index = row.getSelected();
        if (index >= st.shells.len) return;
        const shell = st.shells[index];
        if (shell.command) |command| {
            self.queueSet("command", command);
        } else {
            self.queueSetAll("command", &.{});
        }
        if (shell.gx_zsh) |exe| self.setHerdrDefaultShell(exe);
    }

    fn openConfigClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("cannot get the configuration file path err={}", .{err});
            self.toastError(msg.open_failed, err);
            return;
        };
        defer alloc.free(path);
        // The same as the upstream `.os_open` target of `open_config`.
        app.openUrlFallback(.text, path);
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
        self.cancelPreview();
        for ([_]*?c_uint{ &st.save_source, &st.focus_source }) |source_| {
            if (source_.*) |source| {
                source_.* = null;
                _ = glib.Source.remove(source);
            }
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
        if (st.themes) |*list| list.deinit();
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
            class.bindTemplateChildPrivate("theme_apply_button", .{});
            class.bindTemplateChildPrivate("theme_search", .{});
            class.bindTemplateChildPrivate("theme_list", .{});
            class.bindTemplateChildPrivate("material_group", .{});
            class.bindTemplateChildPrivate("material_row", .{});
            class.bindTemplateChildPrivate("font_page", .{});
            class.bindTemplateChildPrivate("font_size_row", .{});
            class.bindTemplateChildPrivate("font_family_group", .{});
            class.bindTemplateChildPrivate("font_family_row", .{});
            class.bindTemplateChildPrivate("interaction_page", .{});
            class.bindTemplateChildPrivate("right_click_row", .{});
            class.bindTemplateChildPrivate("scrollbar_row", .{});
            class.bindTemplateChildPrivate("close_confirmation_row", .{});
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
            class.bindTemplateChildPrivate("version_row", .{});
            class.bindTemplateChildPrivate("config_path_row", .{});
            class.bindTemplateChildPrivate("open_config_button", .{});
            class.bindTemplateChildPrivate("settings_file_group", .{});
            class.bindTemplateChildPrivate("settings_path_row", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("language_selected", &languageSelected);
            class.bindTemplateCallback("theme_apply_clicked", &themeApplyClicked);
            class.bindTemplateCallback("theme_search_changed", &themeSearchChanged);
            class.bindTemplateCallback("theme_search_activated", &themeSearchActivated);
            class.bindTemplateCallback("theme_list_mapped", &themeListMapped);
            class.bindTemplateCallback("theme_row_selected", &themeRowSelected);
            class.bindTemplateCallback("theme_row_activated", &themeRowActivated);
            class.bindTemplateCallback("material_selected", &materialSelected);
            class.bindTemplateCallback("font_size_changed", &fontSizeChanged);
            class.bindTemplateCallback("font_family_applied", &fontFamilyApplied);
            class.bindTemplateCallback("right_click_selected", &rightClickSelected);
            class.bindTemplateCallback("scrollbar_toggled", &scrollbarToggled);
            class.bindTemplateCallback("close_confirmation_selected", &closeConfirmationSelected);
            class.bindTemplateCallback("bell_toggled", &bellToggled);
            class.bindTemplateCallback("shell_selected", &shellSelected);
            class.bindTemplateCallback("open_config_clicked", &openConfigClicked);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
