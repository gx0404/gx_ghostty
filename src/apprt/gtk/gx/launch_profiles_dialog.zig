//! Launch profile manager. Save replays one intent on the latest overlay;
//! selection changes are explicit and failed saves leave both entries intact.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const edit = @import("../../../gx/launch_profile_edit.zig");
const Application = @import("../class/application.zig").Application;
const launch = @import("launch.zig");
const tr = gx.i18n.tr;

const State = struct {
    alloc: std.mem.Allocator,
    app: *Application,
    dialog: *adw.Dialog,
    chooser: *gtk.ComboBoxText = undefined,
    name: *gtk.Entry = undefined,
    command: *gtk.Entry = undefined,
    status: *gtk.Label = undefined,
    save: *gtk.Button = undefined,
    remove: *gtk.Button = undefined,
    set_default: *gtk.Button = undefined,
    reset_default: *gtk.Button = undefined,
    add: *gtk.Button = undefined,
    profiles: ?launch.List = null,
    overlay: ?gx.gui_settings.Overlay = null,
    arena: std.heap.ArenaAllocator,
    draft: std.heap.ArenaAllocator,
    policy: edit.Policy = .{ .enabled = false },
    old_name: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    default_expected: ?[]const u8 = null,
    selected: ?usize = null,
    changing: bool = false,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data orelse return));
        if (self.profiles) |*profiles| profiles.deinit();
        if (self.overlay) |*overlay| overlay.deinit();
        self.arena.deinit();
        self.draft.deinit();
        self.alloc.destroy(self);
    }
};

pub fn present(app: *Application, parent: *gtk.Widget) void {
    const alloc = app.allocator();
    const state = alloc.create(State) catch return;
    const dialog = adw.Dialog.new();
    state.* = .{ .alloc = alloc, .app = app, .dialog = dialog, .arena = .init(alloc), .draft = .init(alloc) };
    dialog.as(gobject.Object).setDataFull("gx-profile-editor", state, &State.destroy);
    build(state);
    reload(state, null) catch {
        state.status.setText(tr("Unable to save launch profiles. Your draft is still available."));
    };
    dialog.present(parent);
}

fn label(text: [:0]const u8) *gtk.Label {
    const result = gtk.Label.new(text);
    result.setXalign(0);
    result.setWrap(1);
    return result;
}
fn button(text: [:0]const u8, callback: *const fn (*gtk.Button, *State) callconv(.c) void, state: *State) *gtk.Button {
    const result = gtk.Button.newWithLabel(text);
    _ = gtk.Button.signals.clicked.connect(result, *State, callback, state, .{});
    return result;
}
fn build(state: *State) void {
    const content = gtk.Box.new(.vertical, 10);
    inline for (.{ "Top", "Bottom", "Start", "End" }) |side| @field(gtk.Widget, "setMargin" ++ side)(content.as(gtk.Widget), 18);
    state.chooser = gtk.ComboBoxText.new();
    content.append(state.chooser.as(gtk.Widget));
    _ = gtk.ComboBox.signals.changed.connect(state.chooser.as(gtk.ComboBox), *State, selected, state, .{});
    content.append(label(tr("Profile Name")).as(gtk.Widget));
    state.name = gtk.Entry.new();
    content.append(state.name.as(gtk.Widget));
    content.append(label(tr("Profile Command")).as(gtk.Widget));
    state.command = gtk.Entry.new();
    content.append(state.command.as(gtk.Widget));
    content.append(label(tr("Renaming changes the profile ID. Existing keybindings and saved sessions keep the old ID.")).as(gtk.Widget));
    content.append(label(tr("Changing or deleting a profile does not rewrite the default command.")).as(gtk.Widget));
    const actions = gtk.Box.new(.horizontal, 8);
    state.add = button(tr("New Profile"), newProfile, state);
    state.save = button(tr("Save"), saveProfile, state);
    state.save.as(gtk.Widget).addCssClass("suggested-action");
    state.remove = button(tr("Delete"), deleteProfile, state);
    state.remove.as(gtk.Widget).addCssClass("destructive-action");
    actions.append(state.add.as(gtk.Widget));
    actions.append(state.save.as(gtk.Widget));
    actions.append(state.remove.as(gtk.Widget));
    actions.append(button(tr("Reload Profiles"), reloadProfiles, state).as(gtk.Widget));
    content.append(actions.as(gtk.Widget));
    const defaults = gtk.Box.new(.horizontal, 8);
    state.set_default = button(tr("Use as Default"), setDefault, state);
    state.reset_default = button(tr("Reset Default Shell"), resetDefault, state);
    defaults.append(state.set_default.as(gtk.Widget));
    defaults.append(state.reset_default.as(gtk.Widget));
    content.append(defaults.as(gtk.Widget));
    state.status = label("");
    content.append(state.status.as(gtk.Widget));
    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    toolbar.setContent(content.as(gtk.Widget));
    state.dialog.setTitle(tr("Launch Profiles"));
    state.dialog.setContentWidth(720);
    state.dialog.setChild(toolbar.as(gtk.Widget));
}

fn currentPolicy(alloc: std.mem.Allocator, profiles: launch.List, overlay: *const gx.gui_settings.Overlay) !edit.Policy {
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
    _ = profiles;
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

fn reload(state: *State, selected_id: ?[]const u8) !void {
    const config = state.app.getConfig();
    defer config.unref();
    var installed = false;
    var profiles = try launch.list(state.app, config.get());
    errdefer if (!installed) profiles.deinit();
    const path = try gx.config_layers.overlayPath(state.alloc);
    defer state.alloc.free(path);
    var overlay = try gx.gui_settings.Overlay.load(state.alloc, global.io(), path);
    errdefer if (!installed) overlay.deinit();
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    errdefer if (!installed) arena.deinit();
    const policy = try currentPolicy(arena.allocator(), profiles, &overlay);
    const default_expected = if (overlay.get("command")) |command| try arena.allocator().dupe(u8, command) else null;
    state.changing = true;
    defer state.changing = false;
    state.chooser.removeAll();
    var chosen: c_int = -1;
    for (profiles.items, 0..) |profile, i| {
        state.chooser.appendText(profile.name);
        if (selected_id) |id| if (std.mem.eql(u8, profile.id, id)) {
            chosen = @intCast(i);
        };
    }
    if (state.profiles) |*old| old.deinit();
    if (state.overlay) |*old| old.deinit();
    state.arena.deinit();
    state.profiles = profiles;
    state.overlay = overlay;
    state.arena = arena;
    state.policy = policy;
    installed = true;
    state.add.as(gtk.Widget).setSensitive(@intFromBool(policy.enabled and !policy.cli_all));
    state.reset_default.as(gtk.Widget).setSensitive(@intFromBool(policy.enabled and !policy.command_readonly));
    state.default_expected = default_expected;
    if (chosen < 0 and profiles.items.len > 0) chosen = 0;
    state.chooser.as(gtk.ComboBox).setActive(chosen);
    try selectCurrent(state);
}

fn profileCommand(alloc: std.mem.Allocator, profile: launch.Item) ![:0]const u8 {
    if (profile.args.len == 0) return error.InvalidProfile;
    if (std.mem.cutPrefix(u8, profile.args[0], "--command=")) |command| return try alloc.dupeZ(u8, command);
    if (!std.mem.eql(u8, profile.args[0], "-e")) return error.InvalidProfile;
    return try gx.settings_map.profileCommand(alloc, .{ .id = profile.id, .name = profile.name, .kind = .custom, .command = .{ .argv = profile.args[1..] } }, gx.profiles.Platform.native);
}
fn selectCurrent(state: *State) !void {
    state.save.as(gtk.Widget).setSensitive(0);
    state.remove.as(gtk.Widget).setSensitive(0);
    state.set_default.as(gtk.Widget).setSensitive(0);
    _ = state.draft.reset(.retain_capacity);
    const alloc = state.draft.allocator();
    state.old_name = null;
    state.expected = null;
    state.selected = null;
    const index = state.chooser.as(gtk.ComboBox).getActive();
    if (index < 0) return;
    const profiles = state.profiles orelse return;
    const profile = profiles.items[@intCast(index)];
    state.selected = @intCast(index);
    const name = std.mem.cutPrefix(u8, profile.id, "custom:");
    const values = try state.overlay.?.getAll(alloc, "gx-launch-profile");
    const own_command = if (name) |n| edit.owned(values, n) else null;
    const editable = if (name) |n| own_command != null and state.policy.editable(n) else false;
    state.name.as(gtk.Editable).setText(if (name) |n| try alloc.dupeZ(u8, n) else profile.name);
    state.command.as(gtk.Editable).setText(try profileCommand(alloc, profile));
    state.name.as(gtk.Editable).setEditable(@intFromBool(editable));
    state.command.as(gtk.Editable).setEditable(@intFromBool(editable));
    state.save.as(gtk.Widget).setSensitive(@intFromBool(editable));
    state.remove.as(gtk.Widget).setSensitive(@intFromBool(editable));
    state.set_default.as(gtk.Widget).setSensitive(@intFromBool(state.policy.enabled and !state.policy.command_readonly));
    if (editable) {
        state.old_name = try alloc.dupe(u8, name.?);
        state.expected = try alloc.dupe(u8, own_command.?);
        state.status.setText("");
    } else state.status.setText(tr("This profile is read-only because it comes from another configuration source."));
}
fn selected(_: *gtk.ComboBox, state: *State) callconv(.c) void {
    if (state.changing) return;
    selectCurrent(state) catch state.status.setText(tr("Unable to save launch profiles. Your draft is still available."));
}
fn newProfile(_: *gtk.Button, state: *State) callconv(.c) void {
    if (!state.policy.enabled or state.policy.cli_all) return;
    state.changing = true;
    defer state.changing = false;
    state.chooser.as(gtk.ComboBox).setActive(-1);
    _ = state.draft.reset(.retain_capacity);
    state.old_name = null;
    state.expected = null;
    state.selected = null;
    state.name.as(gtk.Editable).setText("");
    state.command.as(gtk.Editable).setText("");
    state.name.as(gtk.Editable).setEditable(1);
    state.command.as(gtk.Editable).setEditable(1);
    state.save.as(gtk.Widget).setSensitive(1);
    state.remove.as(gtk.Widget).setSensitive(0);
    state.set_default.as(gtk.Widget).setSensitive(0);
    state.status.setText("");
    _ = state.name.as(gtk.Widget).grabFocus();
}
fn errorText(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.Conflict => tr("The profile changed outside this dialog. Reload it before saving."),
        error.DuplicateName => tr("A profile with this name already exists."),
        error.InvalidProfile, error.InvalidSetting => tr("Profile names and commands must not contain newlines or NUL characters."),
        error.ReadOnly => tr("This profile is read-only because it comes from another configuration source."),
        else => tr("Unable to save launch profiles. Your draft is still available."),
    };
}

fn commit(state: *State, intent: edit.Edit, selected_id: ?[]const u8) void {
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const path = gx.config_layers.overlayPath(alloc) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    // Recheck live CLI/lower sources as well as re-reading the overlay.
    const config = state.app.getConfig();
    defer config.unref();
    var profiles = launch.list(state.app, config.get()) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    defer profiles.deinit();
    var latest = gx.gui_settings.Overlay.load(alloc, global.io(), path) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    defer latest.deinit();
    const policy = currentPolicy(alloc, profiles, &latest) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    edit.apply(alloc, &latest, intent, policy) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    latest.save(global.io(), path) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    // The application hook is installed with the manager's route after validation.
    @import("app.zig").reloadQuietly(state.app);
    reload(state, selected_id) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    state.status.setText(tr("Launch profiles saved."));
}
fn saveProfile(_: *gtk.Button, state: *State) callconv(.c) void {
    const name = std.mem.span(state.name.as(gtk.Editable).getText());
    const command = std.mem.span(state.command.as(gtk.Editable).getText());
    const id = std.fmt.allocPrint(state.alloc, "custom:{s}", .{name}) catch return;
    defer state.alloc.free(id);
    commit(state, .{ .put = .{ .old_name = state.old_name, .expected = state.expected, .name = name, .command = command } }, id);
}
fn deleteProfile(_: *gtk.Button, state: *State) callconv(.c) void {
    const name = state.old_name orelse return;
    const expected = state.expected orelse return;
    commit(state, .{ .remove = .{ .name = name, .expected = expected } }, null);
}
fn setDefault(_: *gtk.Button, state: *State) callconv(.c) void {
    const index = state.selected orelse return;
    const profile = state.profiles.?.items[index];
    const command = profileCommand(state.alloc, profile) catch return;
    defer state.alloc.free(command);
    // Copy identity because reload replaces the list owning profile.id.
    const id = state.alloc.dupe(u8, profile.id) catch return;
    defer state.alloc.free(id);
    commit(state, .{ .default = .{ .expected = state.default_expected, .command = command } }, id);
}
fn resetDefault(_: *gtk.Button, state: *State) callconv(.c) void {
    commit(state, .{ .default = .{ .expected = state.default_expected, .command = null } }, null);
}
fn reloadProfiles(_: *gtk.Button, state: *State) callconv(.c) void {
    reload(state, null) catch |err| state.status.setText(errorText(err));
}

test "profile manager compiles with GTK controls" {
    try std.testing.expect(@intFromPtr(&present) != 0);
}
