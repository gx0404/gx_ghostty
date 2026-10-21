//! The launch profiles of the settings dialog's Shell page (GX-0015): a
//! group below the default shell that lists every launch profile, and a
//! subpage that edits one. Edits go through `gx/launch_profile_edit.zig`:
//! saving replays one intent on the latest settings overlay, so values
//! another editor wrote meanwhile stay, and a profile that changed outside
//! the settings is reported instead of overwritten. Profiles of the
//! configuration files, the command line and the detected shells open
//! read-only; "Use as Default" and "Reset Default Shell" only write
//! `command` to the overlay. A failed save keeps the draft on the subpage
//! and says why; a successful one goes back to the list.
//!
//! The settings dialog owns one `Section` per dialog and calls `refresh`
//! when the configuration changes or the dialog opens again, `applyTexts`
//! when the UI language changes and `setEditable(false)` without the
//! Ghostty GX layers. Refreshing rebuilds the list and keeps the text of
//! an open subpage.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const edit = @import("../../../gx/launch_profile_edit.zig");
const Application = @import("../class/application.zig").Application;
const launch = @import("launch.zig");

const log = std.log.scoped(.gtk_gx_launch_profiles);

/// The msgids of the section, translated in `src/gx/i18n/gx.zh_CN.po`.
const text = struct {
    pub const title = "Launch Profiles";
    pub const description = "The menu next to the new tab button lists these launch profiles.";
    pub const new_profile = "New Launch Profile";
    pub const default_mark = "Default";
    pub const from_config = gx.settings_map.msg.from_user;
    pub const from_cli = "From the command line";
    pub const name = "Profile Name";
    pub const command = "Profile Command";
    pub const save = "Save";
    pub const use_default = "Use as Default";
    pub const reset_default = "Reset Default Shell";
    pub const delete = "Delete Launch Profile";
    pub const rename_hint = "Renaming changes the profile ID. Existing keybindings and saved sessions keep the old ID.";
    pub const no_rewrite = "Changing or deleting a profile does not rewrite the default command.";
    pub const overlay_only = "Use as Default only writes the settings file and leaves the configuration files unchanged.";
    pub const already_default = "{name} is already the default launch profile.";
    pub const command_cli = "The default shell is set on the command line and cannot be changed here.";
    pub const detected = "This launch profile is detected on this system and cannot be edited.";
    pub const readonly_config = "This launch profile comes from the configuration file and is read-only.";
    pub const readonly_config_hint = "To change it, edit the configuration file and reload the configuration.";
    pub const readonly_cli = "This launch profile is set on the command line and is read-only.";
    pub const disabled = "Launch profiles cannot be changed here while the Ghostty GX settings are turned off.";
    pub const saved = "Launch profiles saved.";
    pub const conflict = "The profile changed outside the settings. Go back and open it again before saving.";
    pub const duplicate = "A profile with this name already exists.";
    pub const invalid = "Enter a name and a command. Names cannot contain “=”, and neither can contain line breaks.";
    pub const readonly = "This profile is read-only because it comes from another configuration source.";
    pub const failed = "Unable to save launch profiles. Your draft is still available.";
    pub const unreadable = "Unable to read the launch profiles.";
    pub const missing = "This launch profile no longer exists.";
};

/// How long "Launch profiles saved." shows, in seconds.
const saved_toast_seconds = 2;

/// A listed launch profile; the strings are in `Section.data`.
const Entry = struct {
    /// The stable profile id (`custom:<name>` for `gx-launch-profile`).
    id: [:0]const u8,
    /// The name shown, in the UI language of the last refresh.
    title: [:0]const u8,
    /// The name the editor shows: the `gx-launch-profile` name of a custom
    /// profile, else the title.
    name: [:0]const u8,
    /// The command shown; for an overlay profile its raw overlay value.
    command: [:0]const u8,
    /// The overlay-owned command of an editable profile.
    owned: ?[]const u8,
    source: edit.Source,
    /// Whether new terminals start this profile.
    is_default: bool,

    fn dupe(self: Entry, alloc: Allocator) Allocator.Error!Entry {
        return .{
            .id = try alloc.dupeSentinel(u8, self.id, 0),
            .title = try alloc.dupeSentinel(u8, self.title, 0),
            .name = try alloc.dupeSentinel(u8, self.name, 0),
            .command = try alloc.dupeSentinel(u8, self.command, 0),
            .owned = if (self.owned) |value| try alloc.dupe(u8, value) else null,
            .source = self.source,
            .is_default = self.is_default,
        };
    }
};

const Mode = enum {
    /// The subpage is not shown.
    closed,
    /// The subpage shows the listed profile `Section.draft_entry`.
    edit,
    /// The subpage creates a profile.
    create,
};

pub const Section = struct {
    alloc: Allocator,
    app: *Application,
    dialog: *adw.PreferencesDialog,
    page: *adw.PreferencesPage,

    /// The language of the section text, that of the configuration.
    lang: gx.i18n.Language = .default,

    /// False without the Ghostty GX layers (`setEditable`).
    editable: bool = true,

    /// The language the profile titles were last read in.
    refreshed_lang: ?gx.i18n.Language = null,

    group: *adw.PreferencesGroup,
    list: *gtk.ListBox,

    /// Owns `entries` and the strings of `policy` and `default_expected`.
    data: ArenaAllocator,
    entries: []const Entry = &.{},
    policy: edit.Policy = .{ .enabled = false },
    /// The overlay's `command` at the last refresh, which "Use as Default"
    /// and "Reset Default Shell" expect to replace.
    default_expected: ?[]const u8 = null,

    subpage: *adw.NavigationPage,
    save_button: *gtk.Button,
    banner: *adw.Banner,
    form_group: *adw.PreferencesGroup,
    name_row: *adw.EntryRow,
    command_row: *adw.EntryRow,
    /// What a read-only profile shows instead of the entry rows.
    name_view: *adw.ActionRow,
    command_view: *adw.ActionRow,
    default_group: *adw.PreferencesGroup,
    default_list: *gtk.ListBox,
    use_default_row: *gtk.ListBoxRow,
    use_default_label: *gtk.Label,
    reset_default_row: *gtk.ListBoxRow,
    reset_default_label: *gtk.Label,
    delete_group: *adw.PreferencesGroup,
    delete_list: *gtk.ListBox,
    delete_row: *gtk.ListBoxRow,
    delete_label: *gtk.Label,

    /// Owns `draft_entry`, which outlives refreshes while the subpage shows.
    draft: ArenaAllocator,
    mode: Mode = .closed,
    draft_entry: ?Entry = null,

    /// True while the subpage fields are filled in.
    filling: bool = false,

    /// The last toast of the section, and whether it reports an error.
    toast: ?*adw.Toast = null,
    toast_error: bool = false,

    /// Adds the launch profile group to `page` of `dialog`.
    pub fn create(
        alloc: Allocator,
        app: *Application,
        dialog: *adw.PreferencesDialog,
        page: *adw.PreferencesPage,
    ) !*Section {
        const self = try alloc.create(Section);
        errdefer alloc.destroy(self);

        const group = adw.PreferencesGroup.new();
        const list = boxedList();
        group.add(list.as(gtk.Widget));

        const header = adw.HeaderBar.new();
        const save_button = gtk.Button.newWithLabel("");
        save_button.as(gtk.Widget).addCssClass("suggested-action");
        header.packEnd(save_button.as(gtk.Widget));
        const banner = adw.Banner.new("");
        banner.setUseMarkup(0);

        const form_group = adw.PreferencesGroup.new();
        const name_row = adw.EntryRow.new();
        const command_row = adw.EntryRow.new();
        const name_view = propertyRow();
        const command_view = propertyRow();
        form_group.add(name_row.as(gtk.Widget));
        form_group.add(command_row.as(gtk.Widget));
        form_group.add(name_view.as(gtk.Widget));
        form_group.add(command_view.as(gtk.Widget));

        const default_group = adw.PreferencesGroup.new();
        const default_list = boxedList();
        var use_default_label: *gtk.Label = undefined;
        var reset_default_label: *gtk.Label = undefined;
        const use_default_row = centeredRow(&use_default_label);
        const reset_default_row = centeredRow(&reset_default_label);
        default_list.append(use_default_row.as(gtk.Widget));
        default_list.append(reset_default_row.as(gtk.Widget));
        default_group.add(default_list.as(gtk.Widget));

        const delete_group = adw.PreferencesGroup.new();
        const delete_list = boxedList();
        var delete_label: *gtk.Label = undefined;
        const delete_row = centeredRow(&delete_label);
        delete_label.as(gtk.Widget).addCssClass("error");
        delete_list.append(delete_row.as(gtk.Widget));
        delete_group.add(delete_list.as(gtk.Widget));

        const content = adw.PreferencesPage.new();
        content.add(form_group);
        content.add(default_group);
        content.add(delete_group);
        const toolbar = adw.ToolbarView.new();
        toolbar.addTopBar(header.as(gtk.Widget));
        toolbar.addTopBar(banner.as(gtk.Widget));
        toolbar.setContent(content.as(gtk.Widget));
        const subpage = adw.NavigationPage.new(toolbar.as(gtk.Widget), "");
        subpage.setTag("launch-profile");
        _ = subpage.as(gobject.Object).refSink();

        const config = app.getConfig();
        defer config.unref();
        self.* = .{
            .alloc = alloc,
            .app = app,
            .dialog = dialog,
            .page = page,
            .lang = gx.i18n.resolve(config.get().language),
            .group = group,
            .list = list,
            .data = .init(alloc),
            .subpage = subpage,
            .save_button = save_button,
            .banner = banner,
            .form_group = form_group,
            .name_row = name_row,
            .command_row = command_row,
            .name_view = name_view,
            .command_view = command_view,
            .default_group = default_group,
            .default_list = default_list,
            .use_default_row = use_default_row,
            .use_default_label = use_default_label,
            .reset_default_row = reset_default_row,
            .reset_default_label = reset_default_label,
            .delete_group = delete_group,
            .delete_list = delete_list,
            .delete_row = delete_row,
            .delete_label = delete_label,
            .draft = .init(alloc),
        };

        _ = gtk.ListBox.signals.row_activated.connect(list, *Section, listActivated, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(default_list, *Section, defaultActivated, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(delete_list, *Section, deleteActivated, self, .{});
        _ = gtk.Button.signals.clicked.connect(save_button, *Section, saveClicked, self, .{});
        _ = gtk.Editable.signals.changed.connect(name_row, *Section, fieldChanged, self, .{});
        _ = gtk.Editable.signals.changed.connect(command_row, *Section, fieldChanged, self, .{});
        _ = adw.EntryRow.signals.entry_activated.connect(name_row, *Section, fieldActivated, self, .{});
        _ = adw.EntryRow.signals.entry_activated.connect(command_row, *Section, fieldActivated, self, .{});
        _ = adw.NavigationPage.signals.hidden.connect(subpage, *Section, subpageHidden, self, .{});
        _ = adw.NavigationPage.signals.shown.connect(subpage, *Section, subpageShown, self, .{});

        page.add(group);
        self.applyTexts();
        return self;
    }

    pub fn destroy(self: *Section) void {
        const objects = [_]*gobject.Object{
            self.list.as(gobject.Object),
            self.default_list.as(gobject.Object),
            self.delete_list.as(gobject.Object),
            self.save_button.as(gobject.Object),
            self.name_row.as(gobject.Object),
            self.command_row.as(gobject.Object),
            self.subpage.as(gobject.Object),
        };
        for (objects) |object| {
            _ = gobject.signalHandlersDisconnectMatched(object, .{ .data = true }, 0, 0, null, null, self);
        }
        if (self.toast) |item| {
            self.toast = null;
            item.as(gobject.Object).unref();
        }
        self.subpage.as(gobject.Object).unref();
        self.data.deinit();
        self.draft.deinit();
        self.alloc.destroy(self);
    }

    /// Reads the profiles and the overlay again and rebuilds the list. An
    /// open subpage keeps its text and follows the new default.
    pub fn refresh(self: *Section) void {
        if (self.reload()) {
            self.refreshed_lang = self.lang;
        } else |err| {
            log.warn("cannot read the launch profiles err={}", .{err});
            self.showToast(self.t(text.unreadable), true);
        }
        self.rebuildRows();
        if (self.mode != .closed) {
            self.followDraft();
            self.updateSubpage();
        }
    }

    /// Sets every text of the section in the language of the configuration.
    pub fn applyTexts(self: *Section) void {
        const config = self.app.getConfig();
        defer config.unref();
        self.lang = gx.i18n.resolve(config.get().language);

        self.group.setTitle(self.t(text.title));
        self.group.setDescription(self.t(text.description).ptr);
        self.name_row.as(adw.PreferencesRow).setTitle(self.t(text.name));
        self.command_row.as(adw.PreferencesRow).setTitle(self.t(text.command));
        self.name_view.as(adw.PreferencesRow).setTitle(self.t(text.name));
        self.command_view.as(adw.PreferencesRow).setTitle(self.t(text.command));
        self.save_button.setLabel(self.t(text.save));
        self.use_default_label.setText(self.t(text.use_default));
        self.reset_default_label.setText(self.t(text.reset_default));
        self.delete_label.setText(self.t(text.delete));
        // The profile titles come from the list in the new language.
        if (self.refreshed_lang != self.lang) self.refresh();
        if (self.mode != .closed) self.updateTexts();
    }

    /// Without the Ghostty GX layers nothing can be changed. The group
    /// moves after the notice the settings dialog puts on the page.
    pub fn setEditable(self: *Section, editable: bool) void {
        self.editable = editable;
        if (!editable) {
            _ = self.group.as(gobject.Object).ref();
            self.page.remove(self.group);
            self.page.add(self.group);
            self.group.as(gobject.Object).unref();
        }
        self.rebuildRows();
        if (self.mode != .closed) {
            self.fillFields();
            self.updateTexts();
            self.updateSubpage();
        }
    }

    //---------------------------------------------------------------
    // Data

    fn t(self: *const Section, msgid: [:0]const u8) [:0]const u8 {
        return gx.i18n.lookup(self.lang, msgid) orelse msgid;
    }

    fn reload(self: *Section) !void {
        const config = self.app.getConfig();
        defer config.unref();
        var profiles = try launch.list(self.app, config.get());
        defer profiles.deinit();

        var arena = ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const path = try gx.config_layers.overlayPath(alloc);
        var overlay = try gx.gui_settings.Overlay.load(self.alloc, global.io(), path);
        defer overlay.deinit();
        const policy = try currentPolicy(alloc, &overlay);
        const values = try overlay.getAll(alloc, "gx-launch-profile");

        const entries = try alloc.alloc(Entry, profiles.items.len);
        for (profiles.items, entries, 0..) |profile, *entry, i| {
            const source = edit.source(policy, values, profile.id);
            const custom = std.mem.cutPrefix(u8, profile.id, "custom:");
            const owned: ?[]const u8 = if (source == .overlay) edit.owned(values, custom.?) else null;
            const command: [:0]const u8 = if (owned) |value|
                try alloc.dupeSentinel(u8, value, 0)
            else
                profileCommand(alloc, profile) catch "";
            const name: [:0]const u8 = if (custom) |value| try alloc.dupeSentinel(u8, value, 0) else profile.name;
            entry.* = try (Entry{
                .id = profile.id,
                .title = profile.name,
                .name = name,
                .command = command,
                .owned = owned,
                .source = source,
                .is_default = profiles.default == i,
            }).dupe(alloc);
        }
        const default_expected: ?[]const u8 = if (overlay.get("command")) |value| try alloc.dupe(u8, value) else null;

        self.data.deinit();
        self.data = arena;
        self.entries = entries;
        self.policy = policy;
        self.default_expected = default_expected;
    }

    fn find(self: *const Section, id: []const u8) ?Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    /// The source as the section shows it: everything is read-only while
    /// editing is off.
    fn shownSource(self: *const Section, source: edit.Source) edit.Source {
        return if (self.editable) source else .disabled;
    }

    fn canCreate(self: *const Section) bool {
        return self.editable and self.policy.enabled and !self.policy.cli_all;
    }

    fn canChangeDefault(self: *const Section) bool {
        return self.editable and self.policy.enabled and !self.policy.command_readonly;
    }

    //---------------------------------------------------------------
    // The list

    fn rebuildRows(self: *Section) void {
        self.list.removeAll();
        for (self.entries) |entry| self.list.append(self.profileRow(entry));
        self.list.append(self.newRow());
    }

    fn profileRow(self: *Section, entry: Entry) *gtk.Widget {
        const box = rowBox();
        box.append(gtk.Image.newFromIconName("utilities-terminal-symbolic").as(gtk.Widget));

        const texts = gtk.Box.new(.vertical, 2);
        texts.as(gtk.Widget).setHexpand(1);
        texts.as(gtk.Widget).setValign(.center);
        const heading = gtk.Box.new(.horizontal, 8);
        const title = gtk.Label.new(entry.title);
        title.setXalign(0);
        title.setEllipsize(.end);
        heading.append(title.as(gtk.Widget));
        if (entry.is_default) {
            const badge = gtk.Label.new(self.t(text.default_mark));
            badge.as(gtk.Widget).addCssClass("gx-badge");
            badge.as(gtk.Widget).addCssClass("gx-mark");
            badge.as(gtk.Widget).setValign(.center);
            heading.append(badge.as(gtk.Widget));
        }
        texts.append(heading.as(gtk.Widget));
        if (entry.command.len > 0) {
            const subtitle = gtk.Label.new(entry.command);
            subtitle.setXalign(0);
            subtitle.setEllipsize(.middle);
            for ([_][:0]const u8{ "caption", "dim-label", "monospace" }) |class| subtitle.as(gtk.Widget).addCssClass(class);
            texts.append(subtitle.as(gtk.Widget));
        }
        box.append(texts.as(gtk.Widget));

        switch (self.shownSource(entry.source)) {
            .overlay, .detected => box.append(dimIcon("go-next-symbolic").as(gtk.Widget)),
            .config_file, .command_line => |source| {
                const note = gtk.Label.new(self.t(if (source == .config_file) text.from_config else text.from_cli));
                note.as(gtk.Widget).addCssClass("dim-label");
                note.setEllipsize(.end);
                box.append(note.as(gtk.Widget));
                box.append(lockIcon().as(gtk.Widget));
            },
            .disabled => box.append(lockIcon().as(gtk.Widget)),
        }

        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn newRow(self: *Section) *gtk.Widget {
        const box = rowBox();
        box.append(gtk.Image.newFromIconName("list-add-symbolic").as(gtk.Widget));
        const label = gtk.Label.new(self.t(text.new_profile));
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        box.append(label.as(gtk.Widget));
        const row = gtk.ListBoxRow.new();
        row.setChild(box.as(gtk.Widget));
        row.as(gtk.Widget).setSensitive(@intFromBool(self.canCreate()));
        return row.as(gtk.Widget);
    }

    fn listActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Section) callconv(.c) void {
        const index = row.getIndex();
        if (index < 0) return;
        const i: usize = @intCast(index);
        if (i >= self.entries.len) return self.openNew();
        // Read the profile again, so the draft expects what is saved now;
        // the rows are rebuilt when the subpage goes.
        const id = self.alloc.dupe(u8, self.entries[i].id) catch return;
        defer self.alloc.free(id);
        self.openProfile(id);
    }

    //---------------------------------------------------------------
    // The subpage

    fn openProfile(self: *Section, id: []const u8) void {
        self.reload() catch |err| {
            log.warn("cannot read the launch profiles err={}", .{err});
            self.showToast(self.t(text.unreadable), true);
            return;
        };
        const entry = self.find(id) orelse {
            self.showToast(self.t(text.missing), true);
            return;
        };
        _ = self.draft.reset(.retain_capacity);
        self.draft_entry = entry.dupe(self.draft.allocator()) catch return;
        self.mode = .edit;
        self.present();
    }

    fn openNew(self: *Section) void {
        if (!self.canCreate()) return;
        _ = self.draft.reset(.retain_capacity);
        self.draft_entry = null;
        self.mode = .create;
        self.present();
    }

    fn present(self: *Section) void {
        self.dismissError();
        self.fillFields();
        self.updateTexts();
        self.updateSubpage();
        self.dialog.pushSubpage(self.subpage);
        self.focusName();
    }

    /// An editable subpage starts on the name, not on the field the
    /// navigation view remembers from the last profile shown.
    fn focusName(self: *Section) void {
        if (self.fieldsEditable()) _ = self.name_row.as(gtk.Widget).grabFocus();
    }

    fn subpageShown(_: *adw.NavigationPage, self: *Section) callconv(.c) void {
        self.focusName();
    }

    /// Whether the name and command of the subpage can be changed.
    fn fieldsEditable(self: *const Section) bool {
        return switch (self.mode) {
            .closed => false,
            .create => self.canCreate(),
            .edit => self.shownSource(self.draft_entry.?.source) == .overlay,
        };
    }

    fn fillFields(self: *Section) void {
        self.filling = true;
        defer self.filling = false;
        const entry = self.draft_entry;
        const name: [:0]const u8 = if (entry) |value| value.name else "";
        const command: [:0]const u8 = if (entry) |value| value.command else "";
        self.name_row.as(gtk.Editable).setText(name);
        self.command_row.as(gtk.Editable).setText(command);
        self.name_view.setSubtitle(name);
        self.command_view.setSubtitle(command);
        // A read-only profile shows its values with a lock instead of the
        // entries, whose edit icons would suggest otherwise.
        const editable = self.fieldsEditable();
        for ([_]*adw.EntryRow{ self.name_row, self.command_row }) |row| {
            row.as(gtk.Editable).setEditable(@intFromBool(editable));
            row.as(gtk.Widget).setVisible(@intFromBool(editable));
        }
        self.name_view.as(gtk.Widget).setVisible(@intFromBool(!editable));
        self.command_view.as(gtk.Widget).setVisible(@intFromBool(!editable));
        self.default_group.as(gtk.Widget).setVisible(@intFromBool(self.mode == .edit));
        self.delete_group.as(gtk.Widget).setVisible(@intFromBool(self.mode == .edit));
    }

    /// The title, the read-only notice and the hints of the subpage.
    fn updateTexts(self: *Section) void {
        const entry = self.draft_entry orelse {
            self.subpage.setTitle(self.t(text.new_profile));
            self.banner.setTitle(self.t(text.disabled));
            self.banner.setRevealed(@intFromBool(!self.canCreate()));
            self.form_group.setDescription(null);
            return;
        };
        self.subpage.setTitle(entry.title);
        const source = self.shownSource(entry.source);
        const notice: ?[:0]const u8 = switch (source) {
            .overlay => null,
            .detected => text.detected,
            .config_file => text.readonly_config,
            .command_line => text.readonly_cli,
            .disabled => text.disabled,
        };
        if (notice) |msgid| self.banner.setTitle(self.t(msgid));
        self.banner.setRevealed(@intFromBool(notice != null));
        const hint: ?[*:0]const u8 = switch (source) {
            .overlay => self.t(text.rename_hint).ptr,
            .config_file => self.t(text.readonly_config_hint).ptr,
            .detected, .command_line, .disabled => null,
        };
        self.form_group.setDescription(hint);
        self.updateDefaultHint();
    }

    fn updateDefaultHint(self: *Section) void {
        const entry = self.draft_entry orelse return;
        const base: [:0]const u8 = if (self.policy.command_readonly)
            self.t(text.command_cli)
        else if (entry.source == .overlay)
            self.t(text.no_rewrite)
        else
            self.t(text.overlay_only);
        if (!entry.is_default) return self.default_group.setDescription(base.ptr);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        gx.i18n.format(&out.writer, self.t(text.already_default), .{ .name = entry.title }) catch return;
        out.writer.print("\n{s}", .{base}) catch return;
        const hint = out.toOwnedSliceSentinel(0) catch return;
        defer self.alloc.free(hint);
        self.default_group.setDescription(hint.ptr);
    }

    /// Follows the refreshed default for the profile the subpage shows.
    fn followDraft(self: *Section) void {
        const entry = &(self.draft_entry orelse return);
        if (self.find(entry.id)) |current| entry.is_default = current.is_default;
    }

    /// What the buttons of the subpage can do now.
    fn updateSubpage(self: *Section) void {
        const editable = self.fieldsEditable();
        const dirty = editable and edit.draftChanged(
            if (self.draft_entry) |entry| entry.name else null,
            if (self.draft_entry) |entry| entry.owned else null,
            std.mem.span(self.name_row.as(gtk.Editable).getText()),
            std.mem.span(self.command_row.as(gtk.Editable).getText()),
        );
        self.save_button.as(gtk.Widget).setSensitive(@intFromBool(dirty));
        self.save_button.as(gtk.Widget).setVisible(@intFromBool(editable));
        const entry = self.draft_entry orelse return;
        const change_default = self.canChangeDefault() and entry.source != .disabled;
        self.use_default_row.as(gtk.Widget).setSensitive(@intFromBool(change_default and !entry.is_default and entry.command.len > 0));
        self.reset_default_row.as(gtk.Widget).setSensitive(@intFromBool(change_default and self.default_expected != null));
        self.delete_row.as(gtk.Widget).setSensitive(@intFromBool(self.shownSource(entry.source) == .overlay));
        self.updateDefaultHint();
    }

    fn fieldChanged(_: *adw.EntryRow, self: *Section) callconv(.c) void {
        if (self.filling or self.mode == .closed) return;
        self.updateSubpage();
    }

    fn fieldActivated(_: *adw.EntryRow, self: *Section) callconv(.c) void {
        if (self.save_button.as(gtk.Widget).getSensitive() != 0) self.save();
    }

    fn saveClicked(_: *gtk.Button, self: *Section) callconv(.c) void {
        self.save();
    }

    fn defaultActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Section) callconv(.c) void {
        const entry = self.draft_entry orelse return;
        if (row == self.use_default_row) {
            self.commit(.{ .default = .{ .expected = self.default_expected, .command = entry.command } });
        } else if (row == self.reset_default_row) {
            self.commit(.{ .default = .{ .expected = self.default_expected, .command = null } });
        }
    }

    fn deleteActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, self: *Section) callconv(.c) void {
        const entry = self.draft_entry orelse return;
        const expected = entry.owned orelse return;
        self.commit(.{ .remove = .{ .name = entry.name, .expected = expected } });
    }

    fn save(self: *Section) void {
        if (!self.fieldsEditable()) return;
        const entry = self.draft_entry;
        self.commit(.{ .put = .{
            .old_name = if (entry) |value| value.name else null,
            .expected = if (entry) |value| value.owned else null,
            .name = std.mem.span(self.name_row.as(gtk.Editable).getText()),
            .command = std.mem.span(self.command_row.as(gtk.Editable).getText()),
        } });
    }

    /// Going back from the subpage drops its draft and shows the list as
    /// it is now.
    fn subpageHidden(_: *adw.NavigationPage, self: *Section) callconv(.c) void {
        if (self.mode == .closed) return;
        self.mode = .closed;
        self.dismissError();
        self.refresh();
        self.focusRow(if (self.draft_entry) |entry| entry.id else null);
    }

    /// Gives the keyboard focus back to the row of `id`, else to the row
    /// that creates a profile.
    fn focusRow(self: *Section, id: ?[]const u8) void {
        var index: usize = self.entries.len;
        if (id) |value| for (self.entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, value)) index = i;
        };
        const row = self.list.getRowAtIndex(@intCast(index)) orelse return;
        _ = row.as(gtk.Widget).grabFocus();
    }

    //---------------------------------------------------------------
    // Saving

    /// Replays `intent` on the latest overlay with the policy of the live
    /// configuration sources, saves it and applies the configuration. A
    /// failure leaves the draft on the subpage and says why.
    fn commit(self: *Section, intent: edit.Edit) void {
        if (!self.editable) return;
        commitOverlay(self.alloc, intent) catch |err| {
            log.warn("cannot save the launch profiles err={}", .{err});
            self.showToast(self.t(errorText(err)), true);
            return;
        };
        self.mode = .closed;
        self.dismissError();
        _ = self.dialog.popSubpage();
        @import("app.zig").reloadQuietly(self.app);
        self.refresh();
        // Back on the list, on the row of the profile just changed.
        const id: ?[]u8 = switch (intent) {
            .put => |change| self.alloc.print("custom:{s}", .{change.name}) catch null,
            .default => if (self.draft_entry) |entry| self.alloc.dupe(u8, entry.id) catch null else null,
            .remove => null,
        };
        defer if (id) |value| self.alloc.free(value);
        self.focusRow(id);
        self.showToast(self.t(text.saved), false);
    }

    fn errorText(err: anyerror) [:0]const u8 {
        return switch (err) {
            error.Conflict => text.conflict,
            error.DuplicateName => text.duplicate,
            error.InvalidProfile, error.InvalidSetting => text.invalid,
            error.ReadOnly => text.readonly,
            else => text.failed,
        };
    }

    //---------------------------------------------------------------
    // Toasts

    fn showToast(self: *Section, message: [:0]const u8, failure: bool) void {
        self.dismissToast();
        const item = adw.Toast.new(message);
        item.setUseMarkup(0);
        if (failure) {
            item.setPriority(.high);
            item.setTimeout(0);
        } else item.setTimeout(saved_toast_seconds);
        _ = item.as(gobject.Object).ref();
        self.toast = item;
        self.toast_error = failure;
        self.dialog.addToast(item);
    }

    fn dismissToast(self: *Section) void {
        const item = self.toast orelse return;
        self.toast = null;
        self.toast_error = false;
        item.dismiss();
        item.as(gobject.Object).unref();
    }

    fn dismissError(self: *Section) void {
        if (self.toast_error) self.dismissToast();
    }
};

//---------------------------------------------------------------
// Helpers

/// Replays `intent` on the latest overlay with the policy of the live
/// configuration sources and saves it.
fn commitOverlay(gpa: Allocator, intent: edit.Edit) !void {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const path = try gx.config_layers.overlayPath(alloc);
    var latest = try gx.gui_settings.Overlay.load(alloc, global.io(), path);
    defer latest.deinit();
    // Recheck the live command line and lower sources too.
    const policy = try currentPolicy(alloc, &latest);
    try edit.apply(alloc, &latest, intent, policy);
    try latest.save(global.io(), path);
}

/// What the live configuration sources allow: names the command line sets
/// cannot be edited, and new names may not shadow a profile of another
/// source. Without the Ghostty GX layers nothing can be edited.
fn currentPolicy(alloc: Allocator, overlay: *const gx.gui_settings.Overlay) !edit.Policy {
    var policy: edit.Policy = .{};
    var layers = gx.config_layers.Layers.load(alloc) catch return .{ .enabled = false };
    defer layers.deinit();
    var locked: std.ArrayList([]const u8) = .empty;
    for (layers.steps.get(.cli).items) |step| {
        if (step != .arg) continue;
        const arg = std.mem.trimStart(u8, step.arg, "-");
        if (std.mem.cutPrefix(u8, arg, "gx-launch-profile=")) |value| {
            if (value.len == 0) policy.cli_all = true;
            if (edit.pair(value)) |entry| try locked.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }
    policy.cli_names = locked.items;
    policy.command_readonly = layers.sets(.cli, "command");
    const values = try overlay.getAll(alloc, "gx-launch-profile");
    var effective = try layers.build(alloc, &.{});
    defer effective.deinit();
    var reserved: std.ArrayList([]const u8) = .empty;
    for (effective.@"gx-launch-profile".map.keys()) |name| {
        if (edit.owned(values, name) == null or !policy.editable(name)) try reserved.append(alloc, try alloc.dupe(u8, name));
    }
    policy.reserved_names = reserved.items;
    return policy;
}

/// The command a launch profile runs, as the overlay writes it.
fn profileCommand(alloc: Allocator, profile: launch.Item) ![:0]const u8 {
    if (profile.args.len == 0) return error.InvalidProfile;
    if (std.mem.cutPrefix(u8, profile.args[0], "--command=")) |command| return try alloc.dupeSentinel(u8, command, 0);
    if (!std.mem.eql(u8, profile.args[0], "-e")) return error.InvalidProfile;
    return try gx.settings_map.profileCommand(alloc, .{
        .id = profile.id,
        .name = profile.name,
        .kind = .custom,
        .command = .{ .argv = profile.args[1..] },
    }, gx.profiles.Platform.native);
}

fn boxedList() *gtk.ListBox {
    const list = gtk.ListBox.new();
    list.setSelectionMode(.none);
    list.as(gtk.Widget).addCssClass("boxed-list");
    return list;
}

fn rowBox() *gtk.Box {
    const box = gtk.Box.new(.horizontal, 12);
    const widget = box.as(gtk.Widget);
    widget.setMarginStart(12);
    widget.setMarginEnd(12);
    widget.setMarginTop(8);
    widget.setMarginBottom(8);
    widget.setSizeRequest(-1, 34);
    return box;
}

/// A row with a centered label, which reads like a button.
fn centeredRow(label: **gtk.Label) *gtk.ListBoxRow {
    const result = gtk.Label.new("");
    result.setJustify(.center);
    result.setWrap(1);
    const widget = result.as(gtk.Widget);
    widget.setHexpand(1);
    widget.setMarginStart(12);
    widget.setMarginEnd(12);
    widget.setMarginTop(14);
    widget.setMarginBottom(14);
    widget.addCssClass("heading");
    label.* = result;
    const row = gtk.ListBoxRow.new();
    row.setChild(widget);
    return row;
}

/// A row that shows a read-only value under its title, with a lock.
fn propertyRow() *adw.ActionRow {
    const row = adw.ActionRow.new();
    row.as(gtk.Widget).addCssClass("property");
    row.setSubtitleSelectable(1);
    row.addSuffix(lockIcon().as(gtk.Widget));
    return row;
}

fn lockIcon() *gtk.Image {
    return dimIcon("changes-prevent-symbolic");
}

fn dimIcon(name: [:0]const u8) *gtk.Image {
    const image = gtk.Image.newFromIconName(name);
    image.as(gtk.Widget).addCssClass("dim-label");
    image.as(gtk.Widget).setValign(.center);
    return image;
}

test "launch profile section compiles with GTK controls" {
    try std.testing.expect(@intFromPtr(&Section.create) != 0);
    try std.testing.expect(@intFromPtr(&Section.refresh) != 0);
    try std.testing.expect(@intFromPtr(&Section.destroy) != 0);
}

test "launch profile save failures name a translated reason" {
    const testing = std.testing;
    try testing.expectEqualStrings(text.conflict, Section.errorText(error.Conflict));
    try testing.expectEqualStrings(text.duplicate, Section.errorText(error.DuplicateName));
    try testing.expectEqualStrings(text.invalid, Section.errorText(error.InvalidProfile));
    try testing.expectEqualStrings(text.readonly, Section.errorText(error.ReadOnly));
    try testing.expectEqualStrings(text.failed, Section.errorText(error.AccessDenied));
    inline for (@typeInfo(text).@"struct".decl_names) |decl_name| {
        const msgid: [:0]const u8 = @field(text, decl_name);
        try testing.expect(gx.i18n.lookup(.zh_CN, msgid) != null);
    }
}
