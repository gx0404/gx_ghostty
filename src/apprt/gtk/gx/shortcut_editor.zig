//! Native keybind editor, including table/sequence/flags/action-chain state.
//! It edits reviewed blocks in the settings overlay, never shortcut display rows.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const Config = @import("../../../config/Config.zig");
const Binding = @import("../../../input/Binding.zig");
const model = @import("../../../gx/keybind_edit.zig");
const Application = @import("../class/application.zig").Application;
const Dialog = @import("../class/dialog.zig").Dialog;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const key = @import("../key.zig");
const tr = gx.i18n.tr;
const state_key = "gx-shortcut-editor";

const Row = struct { title: [:0]const u8, source: model.Source, values: []const []const u8, selected: model.Selection, readonly: bool };
const State = struct {
    alloc: std.mem.Allocator,
    app: *Application,
    dialog: *adw.Dialog,
    chooser: *gtk.ComboBoxText = undefined,
    buffer: *gtk.TextBuffer = undefined,
    editor: *gtk.TextView = undefined,
    source: *gtk.Label = undefined,
    status: *gtk.Label = undefined,
    save: *gtk.Button = undefined,
    reset: *gtk.Button = undefined,
    record: *gtk.Button = undefined,
    add: *gtk.Button = undefined,
    arena: std.heap.ArenaAllocator,
    rows: []const Row = &.{},
    selected: ?usize = null,
    changing: bool = false,
    enabled: bool = false,
    recording: bool = false,
    revision: u64 = 0,
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data orelse return));
        self.arena.deinit();
        self.alloc.destroy(self);
    }
};

pub fn present(app: *Application, parent: *gtk.Widget) void {
    const alloc = app.core().alloc;
    const state = alloc.create(State) catch return;
    const dialog = adw.Dialog.new();
    state.* = .{ .alloc = alloc, .app = app, .dialog = dialog, .arena = .init(alloc) };
    dialog.as(gobject.Object).setDataFull(state_key, state, &State.destroy);
    build(state);
    reload(state) catch |err| state.status.setText(errorText(err));
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
    _ = gtk.ComboBox.signals.changed.connect(state.chooser.as(gtk.ComboBox), *State, selectionChanged, state, .{});
    content.append(label(tr("Shortcut Source")).as(gtk.Widget));
    state.source = label("");
    content.append(state.source.as(gtk.Widget));
    content.append(label(tr("Advanced Binding")).as(gtk.Widget));
    content.append(label(tr("Enter one keybind value per line. Tables, flags, sequences, and chain actions use the configuration syntax.")).as(gtk.Widget));
    state.buffer = gtk.TextBuffer.new(null);
    state.editor = gtk.TextView.newWithBuffer(state.buffer);
    state.buffer.unref();
    state.editor.setMonospace(1);
    state.editor.setWrapMode(.word_char);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setMinContentHeight(160);
    scroll.setChild(state.editor.as(gtk.Widget));
    scroll.as(gtk.Widget).setVexpand(1);
    content.append(scroll.as(gtk.Widget));
    const actions = gtk.Box.new(.horizontal, 8);
    state.add = button(tr("New Binding"), newBinding, state);
    state.record = button(tr("Record Shortcut"), recordShortcut, state);
    state.save = button(tr("Save"), saveClicked, state);
    state.save.as(gtk.Widget).addCssClass("suggested-action");
    state.reset = button(tr("Reset Selected Override"), resetClicked, state);
    actions.append(state.add.as(gtk.Widget));
    actions.append(state.record.as(gtk.Widget));
    actions.append(state.save.as(gtk.Widget));
    actions.append(state.reset.as(gtk.Widget));
    content.append(actions.as(gtk.Widget));
    content.append(button(tr("Reload Shortcuts"), reloadClicked, state).as(gtk.Widget));
    content.append(label(tr("Reset removes only this editor's override and restores the lower configuration.")).as(gtk.Widget));
    state.status = label("");
    content.append(state.status.as(gtk.Widget));
    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    toolbar.setContent(content.as(gtk.Widget));
    state.dialog.setTitle(tr("Edit Keyboard Shortcuts"));
    state.dialog.setContentWidth(820);
    state.dialog.setContentHeight(600);
    state.dialog.setChild(toolbar.as(gtk.Widget));
    const controller = gtk.EventControllerKey.new();
    controller.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *State, recorded, state, .{});
    state.dialog.as(gtk.Widget).addController(controller.as(gtk.EventController));
}

const Current = struct { entries: []model.Entry, policy: model.Policy };
fn current(alloc: std.mem.Allocator, app: *Application) !Current {
    var layers = gx.config_layers.Layers.load(alloc) catch {
        const config = app.getConfig();
        defer config.unref();
        return .{ .entries = try model.enumerate(alloc, &config.get().keybind), .policy = .{ .enabled = false } };
    };
    defer layers.deinit();
    var config = try layers.build(alloc, &.{});
    defer config.deinit();
    const entries = try model.enumerate(alloc, &config.keybind);
    var inputs: std.ArrayList(model.SourceInputs) = .empty;
    var cli: std.ArrayList(model.Target) = .empty;
    inline for (.{ .{ gx.config_layers.Layer.defaults, model.Source.defaults }, .{ gx.config_layers.Layer.user, model.Source.user }, .{ gx.config_layers.Layer.overlay, model.Source.overlay }, .{ gx.config_layers.Layer.cli, model.Source.cli } }) |mapping| {
        var values: std.ArrayList([]const u8) = .empty;
        var cli_has_parent = false;
        for (layers.steps.get(mapping[0]).items) |step| {
            if (step != .arg) continue;
            const arg = std.mem.trimStart(u8, step.arg, "-");
            const value = std.mem.cutPrefix(u8, arg, "keybind=") orelse continue;
            try values.append(alloc, value);
            if (mapping[1] == .cli) {
                if (model.target(alloc, value) catch null) |affected| {
                    try cli.append(alloc, affected);
                    cli_has_parent = affected == .key;
                } else if (std.mem.startsWith(u8, value, "chain=") and !cli_has_parent) try cli.append(alloc, .all);
            }
        }
        try inputs.append(alloc, .{ .source = mapping[1], .values = values.items });
    }
    for (entries) |*entry| entry.source = model.sourceOf(alloc, entry.key, inputs.items);
    return .{ .entries = entries, .policy = .{ .cli = cli.items } };
}
fn sourceName(source: model.Source) [:0]const u8 {
    return switch (source) {
        .defaults => tr("Defaults"),
        .user => tr("User Configuration"),
        .overlay => tr("Settings File"),
        .cli => tr("Command Line"),
    };
}
fn rowReadonly(policy: model.Policy, values: []const []const u8, alloc: std.mem.Allocator) bool {
    if (!policy.enabled) return true;
    for (values) |value| {
        if (model.target(alloc, value) catch null) |affected| if (model.readonly(policy, affected)) return true;
    }
    return false;
}
fn reload(state: *State) !void {
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const live = try current(alloc, state.app);
    const path = try gx.config_layers.overlayPath(alloc);
    var overlay = try gx.gui_settings.Overlay.load(alloc, global.io(), path);
    defer overlay.deinit();
    const scanned = try model.scan(alloc, &overlay);
    var rows: std.ArrayList(Row) = .empty;
    for (live.entries) |entry| {
        const selection = try model.selectionFor(alloc, scanned, entry);
        const values = switch (selection) {
            .lower => try model.formatEntry(alloc, entry),
            .group => |selected| values: {
                for (scanned.groups) |group| if (group.id == selected.id) break :values try cloneValues(alloc, group.values);
                return error.Conflict;
            },
            .block => |selected| values: {
                for (scanned.blocks) |block| if (std.mem.eql(u8, &block.digest, &selected.digest)) break :values try cloneValues(alloc, block.values);
                return error.Conflict;
            },
        };
        try rows.append(alloc, .{
            .title = try std.fmt.allocPrintSentinel(alloc, "{s} — {f}", .{ try model.formatKey(alloc, entry.key), entry.actions[0] }, 0),
            .source = entry.source,
            .values = values,
            .selected = selection,
            .readonly = model.readonly(live.policy, .{ .key = entry.key }),
        });
    }
    for (scanned.groups) |group| try rows.append(alloc, .{
        .title = try std.fmt.allocPrintSentinel(alloc, "{s} {d}", .{ tr("Saved Override"), group.id }, 0),
        .source = .overlay,
        .values = try cloneValues(alloc, group.values),
        .selected = .{ .group = .{ .id = group.id, .digest = group.digest } },
        .readonly = rowReadonly(live.policy, group.values, alloc),
    });
    for (scanned.blocks) |block| try rows.append(alloc, .{
        .title = try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ tr("Settings File"), if (block.values[0].len == 0) "keybind =" else block.values[0] }, 0),
        .source = .overlay,
        .values = try cloneValues(alloc, block.values),
        .selected = .{ .block = .{ .digest = block.digest } },
        .readonly = rowReadonly(live.policy, block.values, alloc),
    });
    state.changing = true;
    defer state.changing = false;
    state.chooser.removeAll();
    for (rows.items) |row| state.chooser.appendText(row.title);
    state.arena.deinit();
    state.arena = arena;
    state.rows = rows.items;
    state.enabled = live.policy.enabled;
    state.add.as(gtk.Widget).setSensitive(@intFromBool(state.enabled));
    state.chooser.as(gtk.ComboBox).setActive(if (rows.items.len == 0) -1 else 0);
    showSelection(state);
}
fn cloneValues(alloc: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const copy = try alloc.alloc([]const u8, values.len);
    for (copy, values) |*out, value| out.* = try alloc.dupe(u8, value);
    return copy;
}
fn selectionChanged(_: *gtk.ComboBox, state: *State) callconv(.c) void {
    if (!state.changing) showSelection(state);
}
fn showSelection(state: *State) void {
    state.revision +|= 1;
    state.recording = false;
    const index = state.chooser.as(gtk.ComboBox).getActive();
    state.selected = if (index >= 0) @intCast(index) else null;
    const editable = if (state.selected) |selected| !state.rows[selected].readonly else state.enabled;
    state.editor.setEditable(@intFromBool(editable));
    state.save.as(gtk.Widget).setSensitive(@intFromBool(editable));
    state.record.as(gtk.Widget).setSensitive(@intFromBool(editable));
    state.reset.as(gtk.Widget).setSensitive(@intFromBool(editable and state.selected != null and state.rows[state.selected.?].selected != .lower));
    const selected = state.selected orelse return;
    const row = state.rows[selected];
    state.source.setText(sourceName(row.source));
    const value = model.valuesText(state.alloc, row.values) catch return;
    defer state.alloc.free(value);
    state.buffer.setText(value, @intCast(value.len));
    state.status.setText(if (editable) "" else tr("This shortcut is controlled by the command line and cannot be edited here."));
}
fn newBinding(_: *gtk.Button, state: *State) callconv(.c) void {
    if (!state.enabled) return;
    state.chooser.as(gtk.ComboBox).setActive(-1);
    state.selected = null;
    state.buffer.setText("", 0);
    state.source.setText(tr("Settings File"));
    state.status.setText("");
    showSelection(state);
}
fn bufferText(state: *State) [*:0]u8 {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    state.buffer.getBounds(&start, &end);
    return state.buffer.getText(&start, &end, 1);
}
fn errorText(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.Conflict => tr("The shortcut changed outside this dialog. Reload it before saving."),
        error.ReadOnly => tr("This shortcut is controlled by the command line and cannot be edited here."),
        error.InvalidFormat, error.InvalidAction, error.InvalidSetting, error.ValueRequired => tr("Invalid keybinding syntax. The draft was not saved."),
        else => tr("Unable to save keyboard shortcuts. Your draft is still available."),
    };
}

const Pending = struct {
    alloc: std.mem.Allocator,
    owner: WeakRef(adw.Dialog) = .empty,
    digest: [32]u8,
    revision: u64,
    fn destroy(self: *Pending) callconv(.c) void {
        self.owner.deinit();
        self.alloc.destroy(self);
    }
};
fn hashText(value: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}
fn askConflict(state: *State, value: []const u8) void {
    const pending = state.alloc.create(Pending) catch return;
    pending.* = .{ .alloc = state.alloc, .digest = hashText(value), .revision = state.revision };
    pending.owner.set(state.dialog);
    const dialog = gobject.ext.newInstance(Dialog, .{});
    dialog.as(Dialog.Parent).setHeading(tr("Shortcut Conflict"));
    dialog.as(Dialog.Parent).setBody(tr("This shortcut replaces an existing binding or overlaps a leader sequence. Save it anyway?"));
    dialog.as(Dialog.Parent).addResponse("cancel", tr("Cancel"));
    dialog.as(Dialog.Parent).addResponse("save", tr("Save Anyway"));
    dialog.as(Dialog.Parent).setDefaultResponse("cancel");
    dialog.as(Dialog.Parent).setCloseResponse("cancel");
    _ = Dialog.Parent.signals.response.connect(dialog.as(Dialog.Parent), *Pending, conflictResponse, pending, .{ .destroyData = Pending.destroy });
    dialog.present(state.dialog.as(gtk.Widget));
}
fn conflictResponse(_: *Dialog.Parent, response: [*:0]const u8, pending: *Pending) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.span(response), "save")) return;
    const dialog = pending.owner.get() orelse return;
    defer dialog.unref();
    const data = dialog.as(gobject.Object).getData(state_key) orelse return;
    const state: *State = @ptrCast(@alignCast(data));
    const raw = bufferText(state);
    defer glib.free(raw);
    if (pending.revision != state.revision or !std.mem.eql(u8, &pending.digest, &hashText(std.mem.span(raw)))) {
        state.status.setText(tr("The shortcut changed outside this dialog. Reload it before saving."));
        return;
    }
    save(state, false, true);
}
fn save(state: *State, reset: bool, confirmed: bool) void {
    const raw = bufferText(state);
    defer glib.free(raw);
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const draft = if (reset) null else model.parseText(alloc, std.mem.span(raw)) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    const live = current(alloc, state.app) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    const path = gx.config_layers.overlayPath(alloc) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    var overlay = gx.gui_settings.Overlay.load(alloc, global.io(), path) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    defer overlay.deinit();
    const intent: model.Intent = .{
        .selected = if (state.selected) |index| state.rows[index].selected else null,
        .values = if (draft) |value| value.values else &.{},
        .reset = reset,
        .conflicts_confirmed = confirmed,
    };
    model.apply(alloc, &overlay, live.entries, live.policy, intent) catch |err| {
        if (err == error.ConfirmationRequired) {
            askConflict(state, std.mem.span(raw));
            return;
        }
        state.status.setText(errorText(err));
        return;
    };
    overlay.save(global.io(), path) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    @import("app.zig").reloadQuietly(state.app);
    reload(state) catch |err| {
        state.status.setText(errorText(err));
        return;
    };
    state.status.setText(tr("Keyboard shortcuts saved."));
}
fn saveClicked(_: *gtk.Button, state: *State) callconv(.c) void {
    save(state, false, false);
}
fn resetClicked(_: *gtk.Button, state: *State) callconv(.c) void {
    save(state, true, false);
}
fn reloadClicked(_: *gtk.Button, state: *State) callconv(.c) void {
    @import("app.zig").reloadQuietly(state.app);
    reload(state) catch |err| state.status.setText(errorText(err));
}
fn recordShortcut(_: *gtk.Button, state: *State) callconv(.c) void {
    state.recording = true;
    state.status.setText(tr("Press the shortcut now. Escape cancels recording."));
}
fn recorded(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, modifiers: gdk.ModifierType, state: *State) callconv(.c) c_int {
    if (!state.recording) return 0;
    const physical = key.keyFromKeyval(keyval);
    if (physical == .escape) {
        state.recording = false;
        state.status.setText("");
        return 1;
    }
    if (physical) |value| switch (value) {
        .shift_left, .shift_right, .control_left, .control_right, .alt_left, .alt_right, .meta_left, .meta_right => return 1,
        else => {},
    };
    var mods = key.translateMods(modifiers);
    mods.caps_lock = false;
    const unicode = gdk.keyvalToUnicode(gdk.keyvalToLower(keyval));
    const trigger: Binding.Trigger = .{ .mods = mods, .key = if (unicode != 0) .{ .unicode = @intCast(unicode) } else if (physical) |value| .{ .physical = value } else return 1 };
    replaceRecorded(state, trigger) catch |err| {
        state.status.setText(errorText(err));
        return 1;
    };
    state.recording = false;
    state.status.setText("");
    return 1;
}
fn replaceRecorded(state: *State, trigger: Binding.Trigger) !void {
    const raw = bufferText(state);
    defer glib.free(raw);
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    var entry: model.Entry = .{ .key = .{ .triggers = &.{trigger} }, .flags = .{}, .actions = &.{.ignore} };
    var values: []const []const u8 = &.{};
    var old_key: ?model.Key = null;
    if (std.mem.trim(u8, std.mem.span(raw), &std.ascii.whitespace).len > 0) {
        const draft = try model.parseText(alloc, std.mem.span(raw));
        var bindings: Config.Keybinds = .{};
        for (draft.values) |value| try bindings.parseCLI(alloc, value);
        const entries = try model.enumerate(alloc, &bindings);
        if (entries.len != 1) return error.InvalidFormat;
        entry = entries[0];
        old_key = entry.key;
        entry.key.triggers = &.{trigger};
        values = draft.values;
    }
    const replacement = try model.formatEntry(alloc, entry);
    var result: std.ArrayList([]const u8) = .empty;
    if (old_key) |old| {
        for (values) |value| {
            const target = try model.target(alloc, value);
            try result.append(alloc, if (target != null and target.? == .key and target.?.key.equal(old)) replacement[0] else value);
        }
    } else try result.appendSlice(alloc, replacement);
    const text = try model.valuesText(alloc, result.items);
    state.buffer.setText(text, @intCast(text.len));
}

test "full shortcut editor compiles against native GTK controls" {
    try std.testing.expect(@intFromPtr(&present) != 0);
}
