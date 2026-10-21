//! The Ghostty GX shortcut editor (`app.gx-shortcut-editor`): an
//! `Adw.Dialog` with a navigation view. The first page lists every
//! keybinding of the configuration by category and key table, with its
//! keycaps, a neutral badge for the configuration layer it comes from and a
//! lock when the command line controls it; the search works as in the
//! cheat sheet. A simple binding (one key combination, one action, the root
//! table) opens a structured page: an action to choose with search, its
//! parameter, a key combination to record and the four flags. Key
//! sequences, key tables, action chains and overrides that are not one
//! binding are marked Advanced and open the keybind syntax instead.
//!
//! Both pages only write the managed groups of the settings overlay
//! through `gx.keybind_edit`, never shortcut display rows. A conflict asks
//! inline and keeps the draft, and so does a failed save; command line
//! bindings are read-only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gtk = @import("gtk");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const gx = @import("../../../gx/main.zig");
const input = @import("../../../input.zig");
const Binding = @import("../../../input/Binding.zig");
const model = @import("../../../gx/keybind_edit.zig");
const Application = @import("../class/application.zig").Application;
const key = @import("../key.zig");
const keycaps = @import("keycaps.zig");
const shortcuts = @import("shortcuts.zig");

const sheet = gx.shortcuts;
const Trigger = Binding.Trigger;
const tr = gx.i18n.tr;
const trCtx = gx.i18n.trCtx;
const trRuntime = gx.i18n.trRuntime;
const log = std.log.scoped(.gtk_gx_shortcut_editor);

const state_key = "gx-shortcut-editor";
const edit_key = "gx-shortcut-edit";
const item_key = "gx-shortcut-item";

// ---------------------------------------------------------------------
// The bindable actions.

const ParamKind = enum { none, optional, required };

/// A binding action to choose: its name in the keybind syntax (`new_tab`,
/// `gx:settings_page`), whether it takes an argument and, for enum
/// arguments, the values it accepts.
const Choice = struct {
    name: []const u8,
    param: ParamKind,
    values: []const u8,
};

fn paramKind(comptime T: type) ParamKind {
    if (T == void) return .none;
    if (T == []const u8) return .required;
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "default")) return .optional,
        else => {},
    }
    return .required;
}

fn enumValues(comptime T: type) []const u8 {
    if (@typeInfo(T) != .@"enum") return "";
    comptime var text: []const u8 = "";
    inline for (std.meta.fieldNames(T), 0..) |name, i| text = text ++ (if (i == 0) "" else ", ") ++ name;
    return text;
}

/// Every action a binding can run but `unbind` and cursor keys, which a
/// binding cannot be set to; `gx:` actions one by one.
const choices = blk: {
    @setEvalBranchQuota(200_000);
    const fields = @typeInfo(Binding.Action).@"union".fields;
    var count = 0;
    for (fields) |field| {
        if (skipChoice(field)) continue;
        count += if (std.mem.eql(u8, field.name, "gx")) @typeInfo(field.type).@"union".fields.len else 1;
    }
    var result: [count]Choice = undefined;
    var i = 0;
    for (fields) |field| {
        if (skipChoice(field)) continue;
        if (std.mem.eql(u8, field.name, "gx")) {
            for (@typeInfo(field.type).@"union".fields) |sub| {
                result[i] = .{ .name = "gx:" ++ sub.name, .param = if (sub.type == void) .none else .required, .values = enumValues(sub.type) };
                i += 1;
            }
            continue;
        }
        result[i] = .{ .name = field.name, .param = paramKind(field.type), .values = enumValues(field.type) };
        i += 1;
    }
    const final = result;
    break :blk final;
};

fn skipChoice(comptime field: std.builtin.Type.UnionField) bool {
    return std.mem.eql(u8, field.name, "unbind") or field.type == Binding.Action.CursorKey;
}

fn choiceIndex(name: []const u8) ?usize {
    for (choices, 0..) |choice, i| if (std.mem.eql(u8, choice.name, name)) return i;
    return null;
}

const ActionText = struct { name: []const u8, param: []const u8 };

/// Splits an action in the keybind syntax into its name and argument; the
/// name of a `gx:` action includes the GX action name.
fn splitAction(text: []const u8) ActionText {
    const base: usize = if (std.mem.startsWith(u8, text, "gx:")) 3 else 0;
    const colon = std.mem.indexOfScalarPos(u8, text, base, ':') orelse return .{ .name = text, .param = "" };
    return .{ .name = text[0..colon], .param = text[colon + 1 ..] };
}

// ---------------------------------------------------------------------
// State.

/// One row of the list: a live binding, or an override in the settings
/// file that is not one binding.
const Item = struct {
    entry: ?model.Entry,
    selection: ?model.Selection,
    values: []const []const u8,
    source: model.Source,
    readonly: bool,
    advanced: bool,
    /// A binding of the same key exists below the settings file, so
    /// removing the override restores it rather than deleting the key.
    lower: bool,
    title: [:0]const u8,
    /// Translated title, English title and the actions in keybind syntax.
    titles: [3][]const u8,
    sequences: []const []const Trigger,
    /// Categories first, then key tables, then other overrides.
    section: u32,
    section_title: [:0]const u8,
    rank: u16,
};

const ListRow = struct { widget: *gtk.Widget, group: usize };

const State = struct {
    alloc: Allocator,
    app: *Application,
    dialog: *adw.Dialog,
    nav: *adw.NavigationView = undefined,
    search: *gtk.SearchEntry = undefined,
    stack: *gtk.Stack = undefined,
    banner: *adw.Banner = undefined,
    add_button: *gtk.Button = undefined,
    list: ?*gtk.Widget = null,
    page: ?*adw.PreferencesPage = null,
    new_group: ?*gtk.Widget = null,
    arena: std.heap.ArenaAllocator,
    items: []const Item = &.{},
    groups: []const *gtk.Widget = &.{},
    group_visible: []bool = &.{},
    rows: []const ListRow = &.{},
    enabled: bool = false,
    /// The actions in list order, as indexes into `choices`, and their
    /// titles in the UI language.
    choice_order: []const usize = &.{},
    choice_titles: []const [:0]const u8 = &.{},
    edit: ?*Edit = null,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data orelse return));
        self.alloc.free(self.choice_order);
        for (self.choice_titles) |text| if (text.len > 0) self.alloc.free(text);
        self.alloc.free(self.choice_titles);
        self.arena.deinit();
        self.alloc.destroy(self);
    }
};

/// An open edit page. Owned by its navigation page, so the callbacks of
/// its widgets never outlive it.
const Edit = struct {
    state: *State,
    arena: std.heap.ArenaAllocator,
    page: *adw.NavigationPage = undefined,
    kind: Kind,
    selection: ?model.Selection,
    /// The values of the override this page edits; empty for a new
    /// binding or one only below the settings file.
    values: []const []const u8,
    /// The key of the binding this page edits, if any.
    entry_key: ?model.Key,
    readonly: bool,
    loading: bool = true,

    save: *gtk.Button = undefined,
    status: *gtk.Label = undefined,
    conflict: *gtk.Widget = undefined,
    conflict_title: *gtk.Label = undefined,
    /// The digest of the draft the conflict prompt was shown for.
    pending: ?[32]u8 = null,

    // Structured.
    combo: *adw.ComboRow = undefined,
    param: *adw.EntryRow = undefined,
    param_hint: *gtk.Label = undefined,
    record: *gtk.Button = undefined,
    record_prompt: *gtk.Label = undefined,
    record_caps: *gtk.Box = undefined,
    record_hints: *gtk.Widget = undefined,
    flags: [4]*adw.SwitchRow = undefined,
    trigger: ?Trigger = null,
    recording: bool = false,

    // Raw.
    buffer: *gtk.TextBuffer = undefined,

    const Kind = enum { structured, raw };

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Edit = @ptrCast(@alignCast(data orelse return));
        const alloc = self.state.alloc;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

const flag_names = [_][:0]const u8{ "performable", "global", "all", "unconsumed" };

// ---------------------------------------------------------------------
// The list.

pub fn present(app: *Application, parent: *gtk.Widget) void {
    const alloc = app.core().alloc;
    const state = alloc.create(State) catch return;
    const dialog = adw.Dialog.new();
    state.* = .{ .alloc = alloc, .app = app, .dialog = dialog, .arena = .init(alloc) };
    dialog.as(gobject.Object).setDataFull(state_key, state, &State.destroy);
    buildChoices(state) catch |err| log.warn("cannot list the binding actions err={}", .{err});
    build(state);
    reload(state) catch |err| showBanner(state, errorText(err));
    dialog.present(parent);
    _ = state.search.as(gtk.Widget).grabFocus();
}

/// The actions to choose from, in cheat sheet order, with their titles in
/// the UI language.
fn buildChoices(state: *State) !void {
    const order = try state.alloc.alloc(usize, choices.len);
    for (order, 0..) |*out, i| out.* = i;
    std.mem.sort(usize, order, {}, struct {
        fn lessThan(_: void, a: usize, b: usize) bool {
            const pa = sheet.placeByName(choices[a].name);
            const pb = sheet.placeByName(choices[b].name);
            if (pa.category != pb.category) return @intFromEnum(pa.category) < @intFromEnum(pb.category);
            if (pa.rank != pb.rank) return pa.rank < pb.rank;
            return sheet.naturalOrder(choices[a].name, choices[b].name) == .lt;
        }
    }.lessThan);
    state.choice_order = order;
    const titles = try state.alloc.alloc([:0]const u8, choices.len);
    @memset(titles, "");
    state.choice_titles = titles;
    for (order, 0..) |choice, position| {
        const name = choices[choice].name;
        titles[position] = try state.alloc.dupeZ(u8, if (sheet.titleForName(name)) |msgid| trRuntime(msgid) else name);
    }
}

fn build(state: *State) void {
    state.search = gtk.SearchEntry.new();
    state.search.setPlaceholderText(tr("Search keyboard shortcuts…"));
    const search_widget = state.search.as(gtk.Widget);
    search_widget.setHexpand(1);
    search_widget.setMarginStart(12);
    search_widget.setMarginEnd(12);
    search_widget.setMarginBottom(6);
    const clamp = adw.Clamp.new();
    clamp.setChild(search_widget);

    const header = adw.HeaderBar.new();
    state.add_button = gtk.Button.newFromIconName("list-add-symbolic");
    state.add_button.as(gtk.Widget).setTooltipText(tr("New Shortcut"));
    _ = gtk.Button.signals.clicked.connect(state.add_button, *State, newClicked, state, .{});
    header.packStart(state.add_button.as(gtk.Widget));

    state.banner = adw.Banner.new("");
    state.stack = gtk.Stack.new();
    const empty = adw.StatusPage.new();
    empty.setIconName("edit-find-symbolic");
    empty.setTitle(tr("No results"));
    _ = state.stack.addNamed(empty.as(gtk.Widget), "empty");

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    toolbar.addTopBar(clamp.as(gtk.Widget));
    toolbar.addTopBar(state.banner.as(gtk.Widget));
    toolbar.setContent(state.stack.as(gtk.Widget));

    state.nav = adw.NavigationView.new();
    // Escape goes back from an edit page in `keyPressed`, which lets the
    // action list's popover close first.
    state.nav.setPopOnEscape(0);
    state.nav.add(adw.NavigationPage.newWithTag(toolbar.as(gtk.Widget), tr("Edit Keyboard Shortcuts"), "list"));
    _ = adw.NavigationView.signals.popped.connect(state.nav, *State, popped, state, .{});

    state.dialog.setTitle(tr("Edit Keyboard Shortcuts"));
    state.dialog.setContentWidth(720);
    state.dialog.setContentHeight(560);
    state.dialog.setChild(state.nav.as(gtk.Widget));
    state.dialog.as(gtk.Widget).addCssClass("gx-dialog");

    _ = gtk.SearchEntry.signals.search_changed.connect(state.search, *State, searchChanged, state, .{});
    _ = gtk.SearchEntry.signals.stop_search.connect(state.search, *State, stopSearch, state, .{});
    state.search.setKeyCaptureWidget(toolbar.as(gtk.Widget));

    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *State, keyPressed, state, .{});
    _ = gtk.EventControllerKey.signals.key_released.connect(keys, *State, keyReleased, state, .{});
    state.dialog.as(gtk.Widget).addController(keys.as(gtk.EventController));
}

fn showBanner(state: *State, text: [:0]const u8) void {
    state.banner.setTitle(text);
    state.banner.setRevealed(@intFromBool(text.len > 0));
}

const Current = struct {
    entries: []model.Entry,
    policy: model.Policy,
    /// The keys bound below the settings file.
    lower: []const model.Key,
};

fn current(alloc: Allocator, app: *Application) !Current {
    var layers = gx.config_layers.Layers.load(alloc) catch {
        const config = app.getConfig();
        defer config.unref();
        const entries = try model.enumerate(alloc, &config.get().keybind);
        const keys = try alloc.alloc(model.Key, entries.len);
        for (keys, entries) |*out, entry| out.* = entry.key;
        return .{ .entries = entries, .policy = .{ .enabled = false }, .lower = keys };
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
            try values.append(alloc, try alloc.dupe(u8, value));
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

    // The same configuration without the keybinds of the settings file.
    try layers.setOverlay("keybind", &.{});
    var lower_config = try layers.build(alloc, &.{});
    defer lower_config.deinit();
    const lower_entries = try model.enumerate(alloc, &lower_config.keybind);
    const lower = try alloc.alloc(model.Key, lower_entries.len);
    for (lower, lower_entries) |*out, entry| out.* = entry.key;
    return .{ .entries = entries, .policy = .{ .cli = cli.items }, .lower = lower };
}

fn rowReadonly(alloc: Allocator, policy: model.Policy, values: []const []const u8) bool {
    if (!policy.enabled) return true;
    for (values) |value| {
        if (model.target(alloc, value) catch null) |affected| if (model.readonly(policy, affected)) return true;
    }
    return false;
}

fn cloneValues(alloc: Allocator, values: []const []const u8) ![]const []const u8 {
    const copy = try alloc.alloc([]const u8, values.len);
    for (copy, values) |*out, value| out.* = try alloc.dupe(u8, value);
    return copy;
}

const Titles = struct { translated: [:0]const u8, english: []const u8 };

/// The title of a binding by its first action, as the cheat sheet names
/// it, else the actions themselves.
fn entryTitle(alloc: Allocator, entry: model.Entry, text: []const u8, commands: []const input.Command) !Titles {
    const row: sheet.Row = .{ .category = .other, .rank = 0, .actions = entry.actions, .sequences = &.{}, .text = text };
    const found = try shortcuts.title(alloc, row, commands) orelse {
        const raw = try alloc.dupeZ(u8, text);
        return .{ .translated = raw, .english = raw };
    };
    const translated = trRuntime(found.msgid);
    const argument = found.argument orelse return .{
        .translated = try alloc.dupeZ(u8, translated),
        .english = try alloc.dupe(u8, found.msgid),
    };
    return .{
        .translated = try fillZ(alloc, tr("{title}: {argument}"), .{ .title = translated, .argument = argument }),
        .english = try fillZ(alloc, "{title}: {argument}", .{ .title = found.msgid, .argument = argument }),
    };
}

fn actionsText(alloc: Allocator, actions: []const Binding.Action) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (actions, 0..) |action, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.print("{f}", .{action});
    }
    return out.written();
}

fn fillZ(alloc: Allocator, template: []const u8, args: anytype) Allocator.Error![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    gx.i18n.format(&out.writer, template, args) catch return error.OutOfMemory;
    return try out.toOwnedSliceSentinel(0);
}

fn hasKey(keys: []const model.Key, wanted: model.Key) bool {
    for (keys) |candidate| if (candidate.equal(wanted)) return true;
    return false;
}

fn selectionEql(a: model.Selection, b: model.Selection) bool {
    return switch (a) {
        .lower => false,
        .group => |x| b == .group and x.id == b.group.id and std.mem.eql(u8, &x.digest, &b.group.digest),
        .block => |x| b == .block and std.mem.eql(u8, &x.digest, &b.block.digest),
    };
}

fn isUsed(used: []const model.Selection, selection: model.Selection) bool {
    for (used) |candidate| if (selectionEql(candidate, selection)) return true;
    return false;
}

const table_sections: u32 = 1000;
const other_section: u32 = std.math.maxInt(u32);

fn reload(state: *State) !void {
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const live = try current(alloc, state.app);
    const path = try gx.config_layers.overlayPath(alloc);
    var overlay = try gx.gui_settings.Overlay.load(alloc, global.io(), path);
    defer overlay.deinit();
    const scanned = try model.scan(alloc, &overlay);

    const config = state.app.getConfig();
    defer config.unref();
    const commands = config.get().@"command-palette-entry".value.items;

    // Key tables become sections after the categories, by name.
    var tables: std.ArrayList([]const u8) = .empty;
    for (live.entries) |entry| {
        if (entry.key.table.len == 0) continue;
        for (tables.items) |name| {
            if (std.mem.eql(u8, name, entry.key.table)) break;
        } else try tables.append(alloc, entry.key.table);
    }
    std.mem.sort([]const u8, tables.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return sheet.naturalOrder(a, b) == .lt;
        }
    }.lessThan);

    var items: std.ArrayList(Item) = .empty;
    var used: std.ArrayList(model.Selection) = .empty;
    for (live.entries) |entry| {
        if (entry.actions.len == 0) continue;
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
        if (selection != .lower) try used.append(alloc, selection);
        const text = try actionsText(alloc, entry.actions);
        const titles = try entryTitle(alloc, entry, text, commands);
        const formatted = try std.fmt.allocPrint(alloc, "{f}", .{entry.actions[0]});
        const where = sheet.place(entry.actions[0]);
        var section: u32 = @intFromEnum(where.category);
        var section_title: [:0]const u8 = trRuntime(where.category.title());
        if (entry.key.table.len > 0) {
            for (tables.items, 0..) |name, i| if (std.mem.eql(u8, name, entry.key.table)) {
                section = table_sections + @as(u32, @intCast(i));
            };
            section_title = try fillZ(alloc, trRuntime("Key Table: {name}"), .{ .name = entry.key.table });
        }
        const sequences = try alloc.alloc([]const Trigger, 1);
        sequences[0] = entry.key.triggers;
        try items.append(alloc, .{
            .entry = entry,
            .selection = selection,
            .values = values,
            .source = entry.source,
            .readonly = model.readonly(live.policy, .{ .key = entry.key }),
            .advanced = !model.isSimple(entry) or choiceIndex(splitAction(formatted).name) == null,
            .lower = hasKey(live.lower, entry.key),
            .title = titles.translated,
            .titles = .{ titles.translated, titles.english, text },
            .sequences = sequences,
            .section = section,
            .section_title = section_title,
            .rank = where.rank,
        });
    }

    // Overrides of the settings file that are not one live binding, such
    // as unbinds, resets and table declarations.
    const other_title = tr("Other Overrides");
    for (scanned.groups) |group| {
        const selection: model.Selection = .{ .group = .{ .id = group.id, .digest = group.digest } };
        if (isUsed(used.items, selection)) continue;
        try items.append(alloc, try overrideItem(alloc, live.policy, selection, group.values, other_title));
    }
    for (scanned.blocks) |block| {
        const selection: model.Selection = .{ .block = .{ .digest = block.digest } };
        if (isUsed(used.items, selection)) continue;
        try items.append(alloc, try overrideItem(alloc, live.policy, selection, block.values, other_title));
    }

    std.mem.sort(Item, items.items, {}, struct {
        fn lessThan(_: void, a: Item, b: Item) bool {
            if (a.section != b.section) return a.section < b.section;
            if (a.rank != b.rank) return a.rank < b.rank;
            const order = sheet.naturalOrder(a.titles[2], b.titles[2]);
            if (order != .eq) return order == .lt;
            return sheet.naturalOrder(a.titles[0], b.titles[0]) == .lt;
        }
    }.lessThan);

    state.enabled = live.policy.enabled;
    try buildList(state, alloc, items.items);
    state.arena.deinit();
    state.arena = arena;
    state.items = items.items;
    state.add_button.as(gtk.Widget).setSensitive(@intFromBool(state.enabled));
    showBanner(state, if (state.enabled) "" else tr("Shortcuts are read-only because the configuration layers are unavailable."));
    applySearch(state);
}

fn overrideItem(alloc: Allocator, policy: model.Policy, selection: model.Selection, values: []const []const u8, section_title: [:0]const u8) !Item {
    const first = if (values.len == 0 or values[0].len == 0) "keybind =" else values[0];
    const title = if (values.len > 1)
        try std.fmt.allocPrintSentinel(alloc, "{s} …", .{first}, 0)
    else
        try alloc.dupeZ(u8, first);
    const text = try model.valuesText(alloc, values);
    return .{
        .entry = null,
        .selection = selection,
        .values = try cloneValues(alloc, values),
        .source = .overlay,
        .readonly = rowReadonly(alloc, policy, values),
        .advanced = true,
        .lower = true,
        .title = title,
        .titles = .{ title, title, text },
        .sequences = &.{},
        .section = other_section,
        .section_title = section_title,
        .rank = 0,
    };
}

const Badge = struct { text: [:0]const u8, class: [:0]const u8 };

fn sourceBadge(source: model.Source) Badge {
    return switch (source) {
        .defaults => .{ .text = trCtx("shortcut source", "Default"), .class = "gx-source-defaults" },
        .user => .{ .text = trCtx("shortcut source", "User Config"), .class = "gx-source-user" },
        .overlay => .{ .text = trCtx("shortcut source", "Settings"), .class = "gx-source-settings" },
        .cli => .{ .text = trCtx("shortcut source", "Command Line"), .class = "gx-source-cli" },
    };
}

fn sourceName(source: model.Source) [:0]const u8 {
    return switch (source) {
        .defaults => tr("Defaults"),
        .user => tr("User Configuration"),
        .overlay => tr("Settings File"),
        .cli => tr("Command Line"),
    };
}

fn badge(text: [:0]const u8, class: [:0]const u8) *gtk.Widget {
    const label = gtk.Label.new(text);
    const widget = label.as(gtk.Widget);
    widget.addCssClass("gx-badge");
    widget.addCssClass(class);
    widget.setValign(.center);
    return widget;
}

/// The source badge of a row, and the lock of a read-only one.
fn sourceWidget(source: model.Source, readonly: bool) *gtk.Widget {
    const box = gtk.Box.new(.horizontal, 6);
    const found = sourceBadge(source);
    box.append(badge(found.text, found.class));
    if (readonly) {
        const image = gtk.Image.newFromIconName("changes-prevent-symbolic");
        const lock = image.as(gtk.Widget);
        lock.addCssClass("dim-label");
        lock.setTooltipText(tr("Read-only"));
        box.append(lock);
    }
    box.as(gtk.Widget).setValign(.center);
    box.as(gtk.Widget).setTooltipText(sourceName(source));
    return box.as(gtk.Widget);
}

fn buildList(state: *State, alloc: Allocator, items: []const Item) !void {
    const page = adw.PreferencesPage.new();
    var groups: std.ArrayList(*gtk.Widget) = .empty;
    var rows: std.ArrayList(ListRow) = .empty;
    const sources = gtk.SizeGroup.new(.horizontal);
    defer sources.unref();
    var group: ?*adw.PreferencesGroup = null;
    var section: ?u32 = null;
    for (items, 0..) |item, index| {
        if (section == null or section.? != item.section) {
            const next = adw.PreferencesGroup.new();
            next.setTitle(item.section_title);
            page.add(next);
            try groups.append(alloc, next.as(gtk.Widget));
            group = next;
            section = item.section;
        }
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setUseMarkup(0);
        row.as(adw.PreferencesRow).setTitle(item.title);
        row.as(gtk.ListBoxRow).setActivatable(1);
        if (item.entry == null) row.setSubtitle(tr("Saved Override"));
        if (item.advanced) row.addSuffix(badge(tr("Advanced"), "gx-advanced"));
        if (item.sequences.len > 0) row.addSuffix(try keycaps.sequence(alloc, item.sequences[0]));
        const source = sourceWidget(item.source, item.readonly);
        sources.addWidget(source);
        row.addSuffix(source);
        row.as(gobject.Object).setData(item_key, @ptrFromInt(index + 1));
        _ = adw.ActionRow.signals.activated.connect(row, *State, rowActivated, state, .{});
        group.?.add(row.as(gtk.Widget));
        try rows.append(alloc, .{ .widget = row.as(gtk.Widget), .group = groups.items.len - 1 });
    }

    // New bindings in the keybind syntax, for what the structured page
    // cannot express.
    const extra = adw.PreferencesGroup.new();
    const add_raw = adw.ActionRow.new();
    add_raw.as(adw.PreferencesRow).setTitle(tr("New Advanced Shortcut"));
    add_raw.setSubtitle(tr("Key sequences, key tables and action chains in the configuration syntax"));
    add_raw.addPrefix(gtk.Image.newFromIconName("list-add-symbolic").as(gtk.Widget));
    add_raw.as(gtk.ListBoxRow).setActivatable(1);
    add_raw.as(gtk.Widget).setSensitive(@intFromBool(state.enabled));
    _ = adw.ActionRow.signals.activated.connect(add_raw, *State, newRawActivated, state, .{});
    extra.add(add_raw.as(gtk.Widget));
    page.add(extra);

    if (state.list) |old| state.stack.remove(old);
    _ = state.stack.addNamed(page.as(gtk.Widget), "list");
    state.list = page.as(gtk.Widget);
    state.page = page;
    state.new_group = extra.as(gtk.Widget);
    state.groups = groups.items;
    state.group_visible = try alloc.alloc(bool, groups.items.len);
    state.rows = rows.items;
}

fn applySearch(state: *State) void {
    const search: sheet.Search = .init(std.mem.span(state.search.as(gtk.Editable).getText()));
    @memset(state.group_visible, false);
    var visible_rows: usize = 0;
    for (state.rows, state.items) |row, item| {
        const visible = search.score(&item.titles, item.sequences) != null;
        row.widget.setVisible(@intFromBool(visible));
        if (visible) {
            visible_rows += 1;
            state.group_visible[row.group] = true;
        }
    }
    for (state.groups, state.group_visible) |group, visible| group.setVisible(@intFromBool(visible));
    if (state.new_group) |group| group.setVisible(@intFromBool(search.isEmpty()));
    state.stack.setVisibleChildName(if (visible_rows > 0 or search.isEmpty()) "list" else "empty");
    if (state.page) |page| page.scrollToTop();
}

fn searchChanged(_: *gtk.SearchEntry, state: *State) callconv(.c) void {
    applySearch(state);
}

/// Escape clears the search, or closes the editor when there is nothing
/// to clear.
fn stopSearch(entry: *gtk.SearchEntry, state: *State) callconv(.c) void {
    const editable = entry.as(gtk.Editable);
    if (std.mem.span(editable.getText()).len > 0) {
        editable.setText("");
        return;
    }
    _ = state.dialog.close();
}

fn rowActivated(row: *adw.ActionRow, state: *State) callconv(.c) void {
    const data = row.as(gobject.Object).getData(item_key) orelse return;
    const index = @intFromPtr(data) - 1;
    if (index >= state.items.len) return;
    const item = state.items[index];
    if (item.advanced) openRaw(state, item) else openStructured(state, item);
}

fn newClicked(_: *gtk.Button, state: *State) callconv(.c) void {
    if (state.enabled) openStructured(state, null);
}

fn newRawActivated(_: *adw.ActionRow, state: *State) callconv(.c) void {
    if (state.enabled) openRaw(state, null);
}

fn popped(_: *adw.NavigationView, page: *adw.NavigationPage, state: *State) callconv(.c) void {
    const edit = state.edit orelse return;
    if (edit.page == page) state.edit = null;
}

// ---------------------------------------------------------------------
// Edit pages.

fn newEdit(state: *State, item: ?Item, kind: Edit.Kind) !*Edit {
    const edit = try state.alloc.create(Edit);
    errdefer state.alloc.destroy(edit);
    edit.* = .{
        .state = state,
        .arena = .init(state.alloc),
        .kind = kind,
        .selection = null,
        .values = &.{},
        .entry_key = null,
        .readonly = !state.enabled,
    };
    errdefer edit.arena.deinit();
    const alloc = edit.arena.allocator();
    if (item) |found| {
        edit.readonly = found.readonly;
        edit.values = try cloneValues(alloc, found.values);
        if (found.entry) |entry| edit.entry_key = try cloneKey(alloc, entry.key);
        if (found.selection) |selection| edit.selection = switch (selection) {
            .lower => |entry| .{ .lower = try cloneEntry(alloc, entry) },
            else => selection,
        };
    }
    return edit;
}

fn cloneKey(alloc: Allocator, value: model.Key) !model.Key {
    return .{ .table = try alloc.dupe(u8, value.table), .triggers = try alloc.dupe(Trigger, value.triggers) };
}

fn cloneEntry(alloc: Allocator, entry: model.Entry) !model.Entry {
    const actions = try alloc.alloc(Binding.Action, entry.actions.len);
    for (actions, entry.actions) |*out, action| out.* = try action.clone(alloc);
    return .{ .key = try cloneKey(alloc, entry.key), .flags = entry.flags, .actions = actions, .source = entry.source };
}

/// Pushes the page of `edit`, which then owns it.
fn pushEdit(state: *State, edit: *Edit, content: *gtk.Widget, title: [:0]const u8) void {
    const header = adw.HeaderBar.new();
    edit.save = gtk.Button.newWithLabel(tr("Save"));
    edit.save.as(gtk.Widget).addCssClass("suggested-action");
    edit.save.as(gtk.Widget).setSensitive(@intFromBool(!edit.readonly));
    _ = gtk.Button.signals.clicked.connect(edit.save, *Edit, saveClicked, edit, .{});
    header.packEnd(edit.save.as(gtk.Widget));

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    if (edit.readonly) {
        const banner = adw.Banner.new(if (state.enabled)
            tr("This shortcut is controlled by the command line and cannot be edited here.")
        else
            tr("Shortcuts are read-only because the configuration layers are unavailable."));
        banner.setRevealed(1);
        toolbar.addTopBar(banner.as(gtk.Widget));
    }
    toolbar.setContent(content);
    edit.page = adw.NavigationPage.new(toolbar.as(gtk.Widget), title);
    edit.page.as(gobject.Object).setDataFull(edit_key, edit, &Edit.destroy);
    if (state.enabled) showBanner(state, "");
    state.edit = edit;
    state.nav.push(edit.page);
    edit.loading = false;
}

/// The error line and the inline conflict prompt, below the fields of an
/// edit page.
fn feedback(edit: *Edit, group: *adw.PreferencesGroup) void {
    edit.status = gtk.Label.new("");
    edit.status.setXalign(0);
    edit.status.setWrap(1);
    edit.status.as(gtk.Widget).addCssClass("error");
    edit.status.as(gtk.Widget).setVisible(0);
    edit.status.as(gtk.Widget).setMarginTop(12);
    group.add(edit.status.as(gtk.Widget));

    const conflict = gtk.Box.new(.horizontal, 12);
    const widget = conflict.as(gtk.Widget);
    widget.addCssClass("card");
    widget.addCssClass("gx-conflict");
    widget.setMarginTop(12);
    const icon = gtk.Image.newFromIconName("dialog-warning-symbolic");
    icon.as(gtk.Widget).addCssClass("warning");
    icon.as(gtk.Widget).setMarginStart(12);
    icon.as(gtk.Widget).setValign(.center);
    conflict.append(icon.as(gtk.Widget));
    const text = gtk.Box.new(.vertical, 2);
    text.as(gtk.Widget).setHexpand(1);
    text.as(gtk.Widget).setMarginTop(10);
    text.as(gtk.Widget).setMarginBottom(10);
    edit.conflict_title = gtk.Label.new(tr("Shortcut Conflict"));
    edit.conflict_title.setXalign(0);
    edit.conflict_title.setWrap(1);
    edit.conflict_title.as(gtk.Widget).addCssClass("heading");
    text.append(edit.conflict_title.as(gtk.Widget));
    const body = gtk.Label.new(tr("This shortcut replaces an existing binding or overlaps a leader sequence. Save it anyway?"));
    body.setXalign(0);
    body.setWrap(1);
    body.as(gtk.Widget).addCssClass("caption");
    body.as(gtk.Widget).addCssClass("dim-label");
    text.append(body.as(gtk.Widget));
    conflict.append(text.as(gtk.Widget));
    const anyway = gtk.Button.newWithLabel(tr("Save Anyway"));
    anyway.as(gtk.Widget).setValign(.center);
    anyway.as(gtk.Widget).setMarginEnd(12);
    _ = gtk.Button.signals.clicked.connect(anyway, *Edit, saveAnywayClicked, edit, .{});
    conflict.append(anyway.as(gtk.Widget));
    widget.setVisible(0);
    edit.conflict = widget;
    group.add(widget);
}

/// "Restore Default" when a binding of the key exists below the settings
/// file, else "Delete Shortcut"; only for an override this editor can
/// remove.
fn removeGroup(edit: *Edit, lower: bool) ?*adw.PreferencesGroup {
    const selection = edit.selection orelse return null;
    if (selection == .lower or edit.readonly) return null;
    const group = adw.PreferencesGroup.new();
    const button = gtk.Button.newWithLabel(if (lower) tr("Restore Default") else tr("Delete Shortcut"));
    const widget = button.as(gtk.Widget);
    widget.addCssClass("pill");
    if (!lower) widget.addCssClass("destructive-action");
    widget.setHalign(.center);
    _ = gtk.Button.signals.clicked.connect(button, *Edit, resetClicked, edit, .{});
    group.add(widget);
    return group;
}

fn openStructured(state: *State, item: ?Item) void {
    if (state.edit != null) return;
    const edit = newEdit(state, item, .structured) catch return;
    const alloc = edit.arena.allocator();
    const prefs = adw.PreferencesPage.new();

    var choice: usize = choiceIndex("new_tab") orelse 0;
    var param: []const u8 = "";
    var flags: Binding.Flags = .{};
    if (item) |found| if (found.entry) |entry| {
        const formatted = std.fmt.allocPrint(alloc, "{f}", .{entry.actions[0]}) catch "";
        const split = splitAction(formatted);
        choice = choiceIndex(split.name) orelse choice;
        param = split.param;
        flags = entry.flags;
        edit.trigger = entry.key.triggers[0];
    };

    // The action and its argument.
    const action_group = adw.PreferencesGroup.new();
    edit.combo = adw.ComboRow.new();
    edit.combo.as(adw.PreferencesRow).setTitle(tr("Action"));
    edit.combo.as(adw.PreferencesRow).setUseMarkup(0);
    const list = gtk.StringList.new(null);
    for (state.choice_titles) |text| list.append(text);
    edit.combo.setModel(list.as(gio.ListModel));
    list.unref();
    const expression = gtk.PropertyExpression.new(gtk.StringObject.getGObjectType(), null, "string");
    edit.combo.setExpression(expression.as(gtk.Expression));
    expression.as(gtk.Expression).unref();
    edit.combo.setEnableSearch(1);
    const position = std.mem.indexOfScalar(usize, state.choice_order, choice) orelse 0;
    edit.combo.setSelected(@intCast(position));
    action_group.add(edit.combo.as(gtk.Widget));
    edit.param = adw.EntryRow.new();
    edit.param.as(adw.PreferencesRow).setTitle(tr("Parameter"));
    edit.param.as(gtk.Editable).setText(alloc.dupeZ(u8, param) catch "");
    action_group.add(edit.param.as(gtk.Widget));
    edit.param_hint = gtk.Label.new("");
    edit.param_hint.setXalign(0);
    edit.param_hint.setWrap(1);
    edit.param_hint.as(gtk.Widget).addCssClass("caption");
    edit.param_hint.as(gtk.Widget).addCssClass("dim-label");
    edit.param_hint.as(gtk.Widget).setMarginTop(6);
    action_group.add(edit.param_hint.as(gtk.Widget));
    prefs.add(action_group);

    // The key combination.
    const key_group = adw.PreferencesGroup.new();
    key_group.setTitle(tr("Shortcut"));
    edit.record = gtk.Button.new();
    const record = edit.record.as(gtk.Widget);
    record.addCssClass("card");
    record.addCssClass("gx-record");
    const record_box = gtk.Box.new(.vertical, 8);
    record_box.as(gtk.Widget).setMarginTop(12);
    record_box.as(gtk.Widget).setMarginBottom(12);
    record_box.as(gtk.Widget).setHalign(.center);
    edit.record_prompt = gtk.Label.new("");
    record_box.append(edit.record_prompt.as(gtk.Widget));
    edit.record_caps = gtk.Box.new(.horizontal, 0);
    edit.record_caps.as(gtk.Widget).setHalign(.center);
    edit.record_caps.as(gtk.Widget).addCssClass("gx-record-keys");
    // Keeps the card from shrinking while no combination is set.
    edit.record_caps.as(gtk.Widget).setSizeRequest(-1, 32);
    record_box.append(edit.record_caps.as(gtk.Widget));
    const hints = gtk.Box.new(.horizontal, 16);
    hints.as(gtk.Widget).setHalign(.center);
    hints.as(gtk.Widget).addCssClass("caption");
    const hint_keys = [_][]const u8{ "Esc", "Backspace" };
    const hint_texts = [_][:0]const u8{ tr("Cancel"), tr("Clear") };
    for (hint_keys, hint_texts) |cap, text| {
        const pair = gtk.Box.new(.horizontal, 6);
        if (keycaps.fromLabels(alloc, &.{cap}, false)) |caps| pair.append(caps) else |_| {}
        pair.append(keycaps.dimLabel(text));
        hints.append(pair.as(gtk.Widget));
    }
    edit.record_hints = hints.as(gtk.Widget);
    record_box.append(edit.record_hints);
    edit.record.setChild(record_box.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(edit.record, *Edit, recordClicked, edit, .{});
    key_group.add(record);
    feedback(edit, key_group);
    prefs.add(key_group);

    // The flags.
    const flag_group = adw.PreferencesGroup.new();
    flag_group.setTitle(tr("Flags"));
    const descriptions = [_][:0]const u8{
        tr("Take the key only when the action can run; otherwise pass it to the program"),
        tr("Work even when the app is not focused, if the desktop supports it"),
        tr("Apply to every terminal, not just the focused one"),
        tr("Also pass the key to the program in the terminal after the action"),
    };
    const values = [_]bool{ flags.performable, flags.global, flags.all, !flags.consumed };
    for (&edit.flags, flag_names, descriptions, values) |*row, name, description, value| {
        row.* = adw.SwitchRow.new();
        row.*.as(adw.PreferencesRow).setTitle(name);
        row.*.as(adw.ActionRow).setSubtitle(description);
        row.*.as(gtk.Widget).addCssClass("gx-flag");
        row.*.setActive(@intFromBool(value));
        _ = gobject.Object.signals.notify.connect(row.*, *Edit, flagChanged, edit, .{ .detail = "active" });
        flag_group.add(row.*.as(gtk.Widget));
    }
    prefs.add(flag_group);
    if (removeGroup(edit, if (item) |found| found.lower else true)) |group| prefs.add(group);

    const editable: c_int = @intFromBool(!edit.readonly);
    edit.combo.as(gtk.Widget).setSensitive(editable);
    edit.param.as(gtk.Widget).setSensitive(editable);
    record.setSensitive(editable);
    for (edit.flags) |row| row.as(gtk.Widget).setSensitive(editable);
    _ = gobject.Object.signals.notify.connect(edit.combo, *Edit, comboChanged, edit, .{ .detail = "selected" });
    _ = gtk.Editable.signals.changed.connect(edit.param.as(gtk.Editable), *Edit, paramChanged, edit, .{});
    showChoice(edit);
    showRecord(edit, &.{}, false);

    pushEdit(state, edit, prefs.as(gtk.Widget), if (item != null) tr("Edit Shortcut") else tr("New Shortcut"));
}

fn selectedChoice(edit: *Edit) Choice {
    const position = edit.combo.getSelected();
    const order = edit.state.choice_order;
    return choices[if (position < order.len) order[position] else 0];
}

/// Shows the name of the chosen action and whether it takes an argument.
fn showChoice(edit: *Edit) void {
    const alloc = edit.arena.allocator();
    const choice = selectedChoice(edit);
    edit.combo.as(adw.ActionRow).setSubtitle(alloc.dupeZ(u8, choice.name) catch "");
    edit.param.as(gtk.Widget).setVisible(@intFromBool(choice.param != .none));
    edit.param_hint.as(gtk.Widget).setVisible(@intFromBool(choice.param != .none));
    const hint: [:0]const u8 = switch (choice.param) {
        .none => "",
        .optional => if (choice.values.len > 0)
            fillZ(alloc, tr("Optional. One of: {values}."), .{ .values = choice.values }) catch ""
        else
            tr("Optional."),
        .required => if (choice.values.len > 0)
            fillZ(alloc, tr("Required. One of: {values}."), .{ .values = choice.values }) catch ""
        else
            tr("Required."),
    };
    edit.param_hint.setText(hint);
}

/// The recorder: the recorded key combination, or while recording the
/// modifiers held so far and a keycap for the key to come.
fn showRecord(edit: *Edit, held: []const []const u8, pending: bool) void {
    const alloc = edit.arena.allocator();
    const box = edit.record_caps;
    while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
    const record = edit.record.as(gtk.Widget);
    const prompt = edit.record_prompt.as(gtk.Widget);
    if (edit.recording) {
        record.addCssClass("gx-recording");
        edit.record_prompt.setText(tr("Press a key combination"));
        prompt.removeCssClass("dim-label");
        prompt.addCssClass("accent");
        if (keycaps.fromLabels(alloc, held, pending)) |caps| box.append(caps) else |_| {}
    } else {
        record.removeCssClass("gx-recording");
        edit.record_prompt.setText(if (edit.readonly) tr("Shortcut") else tr("Click to record a shortcut"));
        prompt.removeCssClass("accent");
        prompt.addCssClass("dim-label");
        if (edit.trigger) |trigger| {
            if (keycaps.chord(alloc, trigger)) |caps| box.append(caps) else |_| {}
        } else {
            box.append(keycaps.dimLabel(tr("Not set")));
        }
    }
    edit.record_hints.setVisible(@intFromBool(edit.recording));
}

fn recordClicked(_: *gtk.Button, edit: *Edit) callconv(.c) void {
    if (edit.readonly) return;
    edit.recording = !edit.recording;
    showRecord(edit, &.{}, true);
}

fn modifierKey(physical: ?input.Key) ?input.Mods {
    const value = physical orelse return null;
    return switch (value) {
        .shift_left, .shift_right => .{ .shift = true },
        .control_left, .control_right => .{ .ctrl = true },
        .alt_left, .alt_right => .{ .alt = true },
        .meta_left, .meta_right => .{ .super = true },
        else => null,
    };
}

fn heldLabels(buf: *[4][]const u8, mods: input.Mods) []const []const u8 {
    const caps: sheet.Keycaps = .init(.{ .mods = mods, .key = .{ .unicode = 0 } }, .gtk);
    for (0..caps.mods_len) |i| buf[i] = caps.mods[i];
    return buf[0..caps.mods_len];
}

fn withMods(base: input.Mods, change: input.Mods, set: bool) input.Mods {
    var result = base;
    inline for (.{ "shift", "ctrl", "alt", "super" }) |name| {
        if (@field(change, name)) @field(result, name) = set;
    }
    return result;
}

fn plain(mods: input.Mods) bool {
    return !mods.shift and !mods.ctrl and !mods.alt and !mods.super;
}

/// While recording, the dialog takes every key before its widgets do:
/// Escape cancels, Backspace clears, modifiers alone only show up.
/// Otherwise Escape on an edit page goes back to the list, unless a popover
/// such as the searchable action list has the focus and closes instead.
fn keyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, modifiers: gdk.ModifierType, state: *State) callconv(.c) c_int {
    const edit = state.edit orelse return 0;
    const physical = key.keyFromKeyval(keyval);
    var mods = key.translateMods(modifiers);
    mods.caps_lock = false;
    if (!edit.recording) {
        if (physical != .escape or !plain(mods) or focusInPopover(state)) return 0;
        _ = state.nav.pop();
        return 1;
    }
    if (physical == .escape and plain(mods)) {
        edit.recording = false;
        showRecord(edit, &.{}, false);
        return 1;
    }
    if (physical == .backspace and plain(mods)) {
        edit.recording = false;
        edit.trigger = null;
        showRecord(edit, &.{}, false);
        draftChanged(edit);
        return 1;
    }
    if (modifierKey(physical)) |pressed| {
        var buf: [4][]const u8 = undefined;
        showRecord(edit, heldLabels(&buf, withMods(mods, pressed, true)), true);
        return 1;
    }
    const unicode = gdk.keyvalToUnicode(gdk.keyvalToLower(keyval));
    edit.trigger = .{ .mods = mods, .key = if (unicode != 0) .{ .unicode = @intCast(unicode) } else if (physical) |value| .{ .physical = value } else return 1 };
    edit.recording = false;
    showRecord(edit, &.{}, false);
    draftChanged(edit);
    return 1;
}

fn focusInPopover(state: *State) bool {
    const widget = state.dialog.as(gtk.Widget);
    const root = widget.getRoot() orelse return false;
    const focus = root.getFocus() orelse return false;
    const native = focus.getNative() orelse return false;
    return native != (widget.getNative() orelse return false);
}

fn keyReleased(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, modifiers: gdk.ModifierType, state: *State) callconv(.c) void {
    const edit = state.edit orelse return;
    if (!edit.recording) return;
    const released = modifierKey(key.keyFromKeyval(keyval)) orelse return;
    var buf: [4][]const u8 = undefined;
    showRecord(edit, heldLabels(&buf, withMods(key.translateMods(modifiers), released, false)), true);
}

fn comboChanged(_: *adw.ComboRow, _: *gobject.ParamSpec, edit: *Edit) callconv(.c) void {
    if (edit.loading) return;
    edit.param.as(gtk.Editable).setText("");
    showChoice(edit);
    draftChanged(edit);
}

fn paramChanged(_: *gtk.Editable, edit: *Edit) callconv(.c) void {
    draftChanged(edit);
}

fn flagChanged(_: *adw.SwitchRow, _: *gobject.ParamSpec, edit: *Edit) callconv(.c) void {
    draftChanged(edit);
}

/// A changed draft drops a pending conflict prompt and the last error.
fn draftChanged(edit: *Edit) void {
    if (edit.loading) return;
    edit.pending = null;
    edit.conflict.setVisible(0);
    edit.status.as(gtk.Widget).setVisible(0);
}

fn showError(edit: *Edit, text: [:0]const u8) void {
    edit.status.setText(text);
    edit.status.as(gtk.Widget).setVisible(1);
}

fn openRaw(state: *State, item: ?Item) void {
    if (state.edit != null) return;
    const edit = newEdit(state, item, .raw) catch return;
    const alloc = edit.arena.allocator();
    const prefs = adw.PreferencesPage.new();
    const group = adw.PreferencesGroup.new();
    group.setTitle(tr("Advanced Binding"));
    group.setDescription(tr("Enter one keybind value per line. Tables, flags, sequences, and chain actions use the configuration syntax."));
    if (item) |found| group.setHeaderSuffix(sourceWidget(found.source, found.readonly));
    edit.buffer = gtk.TextBuffer.new(null);
    const view = gtk.TextView.newWithBuffer(edit.buffer);
    edit.buffer.unref();
    view.setMonospace(1);
    view.setWrapMode(.word_char);
    view.setEditable(@intFromBool(!edit.readonly));
    view.setTopMargin(10);
    view.setBottomMargin(10);
    view.setLeftMargin(12);
    view.setRightMargin(12);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setMinContentHeight(180);
    scroll.setChild(view.as(gtk.Widget));
    scroll.as(gtk.Widget).addCssClass("card");
    scroll.as(gtk.Widget).addCssClass("gx-raw-editor");
    group.add(scroll.as(gtk.Widget));
    feedback(edit, group);
    prefs.add(group);
    if (removeGroup(edit, if (item) |found| found.lower else true)) |remove| prefs.add(remove);

    if (model.valuesText(alloc, edit.values)) |text| edit.buffer.setText(text, @intCast(text.len)) else |_| {}
    _ = gtk.TextBuffer.signals.changed.connect(edit.buffer, *Edit, bufferChanged, edit, .{});
    pushEdit(state, edit, prefs.as(gtk.Widget), if (item != null) tr("Advanced Shortcut") else tr("New Advanced Shortcut"));
    _ = view.as(gtk.Widget).grabFocus();
}

fn bufferChanged(_: *gtk.TextBuffer, edit: *Edit) callconv(.c) void {
    draftChanged(edit);
}

// ---------------------------------------------------------------------
// Saving.

/// The keybind values the page would save.
fn draftValues(edit: *Edit, alloc: Allocator) ![]const []const u8 {
    switch (edit.kind) {
        .raw => {
            var start: gtk.TextIter = undefined;
            var end: gtk.TextIter = undefined;
            edit.buffer.getBounds(&start, &end);
            const raw = edit.buffer.getText(&start, &end, 1);
            defer glib.free(raw);
            const draft = try model.parseText(alloc, try alloc.dupe(u8, std.mem.span(raw)));
            return draft.values;
        },
        .structured => {
            const trigger = edit.trigger orelse return error.NoShortcut;
            const choice = selectedChoice(edit);
            const param = std.mem.span(edit.param.as(gtk.Editable).getText());
            if (choice.param == .required and param.len == 0) return error.ParamRequired;
            const text = if (choice.param == .none or param.len == 0)
                try alloc.dupe(u8, choice.name)
            else
                try std.fmt.allocPrint(alloc, "{s}:{s}", .{ choice.name, param });
            const action = Binding.Action.parse(text) catch return error.InvalidParam;
            var flags: Binding.Flags = .{};
            flags.performable = edit.flags[0].getActive() != 0;
            flags.global = edit.flags[1].getActive() != 0;
            flags.all = edit.flags[2].getActive() != 0;
            flags.consumed = edit.flags[3].getActive() == 0;
            const triggers = try alloc.alloc(Trigger, 1);
            triggers[0] = trigger;
            const actions = try alloc.alloc(Binding.Action, 1);
            actions[0] = action;
            const replacement = try model.formatEntry(alloc, .{ .key = .{ .triggers = triggers }, .flags = flags, .actions = actions });
            _ = model.parseValues(alloc, replacement) catch return error.InvalidParam;
            const selection = edit.selection orelse return replacement;
            if (selection == .lower) return replacement;
            const old = edit.entry_key orelse return replacement;
            return try model.replaceBinding(alloc, edit.values, old, replacement);
        },
    }
}

fn hashValues(values: []const []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (values) |value| {
        hash.update(value);
        hash.update("\n");
    }
    return hash.finalResult();
}

fn errorText(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.Conflict => tr("The shortcut changed outside this dialog. Reload it before saving."),
        error.ReadOnly => tr("This shortcut is controlled by the command line and cannot be edited here."),
        error.NoShortcut => tr("Record a key combination first."),
        error.ParamRequired => tr("This action needs a parameter."),
        error.InvalidParam => tr("The parameter is not valid for this action."),
        error.InvalidFormat, error.InvalidAction, error.InvalidSetting, error.ValueRequired => tr("Invalid keybinding syntax. The draft was not saved."),
        else => tr("Unable to save keyboard shortcuts. Your draft is still available."),
    };
}

fn saveClicked(_: *gtk.Button, edit: *Edit) callconv(.c) void {
    commit(edit, false, false);
}

fn saveAnywayClicked(_: *gtk.Button, edit: *Edit) callconv(.c) void {
    commit(edit, false, true);
}

fn resetClicked(_: *gtk.Button, edit: *Edit) callconv(.c) void {
    commit(edit, true, false);
}

/// Saves the draft, or removes the override with `reset`, in the settings
/// file. A confirmed save only goes through for the draft the conflict
/// prompt was shown for; otherwise it asks again.
fn commit(edit: *Edit, reset: bool, confirmed: bool) void {
    if (edit.readonly) return;
    const state = edit.state;
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const values: []const []const u8 = if (reset) &.{} else draftValues(edit, alloc) catch |err| return showError(edit, errorText(err));
    const digest = hashValues(values);
    const pending_ok = if (edit.pending) |pending| std.mem.eql(u8, &pending, &digest) else false;
    const live = current(alloc, state.app) catch |err| return showError(edit, errorText(err));
    const path = gx.config_layers.overlayPath(alloc) catch |err| return showError(edit, errorText(err));
    var overlay = gx.gui_settings.Overlay.load(alloc, global.io(), path) catch |err| return showError(edit, errorText(err));
    defer overlay.deinit();
    const intent: model.Intent = .{
        .selected = edit.selection,
        .values = values,
        .reset = reset,
        .conflicts_confirmed = confirmed and pending_ok,
    };
    model.apply(alloc, &overlay, live.entries, live.policy, intent) catch |err| {
        if (err == error.ConfirmationRequired) return showConflict(edit, alloc, values, live.entries, digest);
        return showError(edit, errorText(err));
    };
    overlay.save(global.io(), path) catch |err| return showError(edit, errorText(err));
    @import("app.zig").reloadQuietly(state.app);
    state.edit = null;
    // Without the transition the list is back at once.
    state.nav.setAnimateTransitions(0);
    _ = state.nav.popToTag("list");
    state.nav.setAnimateTransitions(1);
    reload(state) catch |err| return showBanner(state, errorText(err));
    showBanner(state, tr("Keyboard shortcuts saved."));
    focusSearchLater(state);
}

/// The focused widget of the saved page and the focused row of the old
/// list are gone, which leaves the dialog without a focus, so keys such as
/// Escape no longer reach it. The search takes the focus once the
/// navigation view has dropped the page.
fn focusSearchLater(state: *State) void {
    _ = state.dialog.as(gobject.Object).ref();
    _ = glib.idleAdd(focusSearch, state.dialog);
}

fn focusSearch(data: ?*anyopaque) callconv(.c) c_int {
    const dialog: *adw.Dialog = @ptrCast(@alignCast(data orelse return 0));
    defer dialog.as(gobject.Object).unref();
    const found = dialog.as(gobject.Object).getData(state_key) orelse return 0;
    const state: *State = @ptrCast(@alignCast(found));
    if (state.edit == null) _ = state.search.as(gtk.Widget).grabFocus();
    return 0;
}

fn showConflict(edit: *Edit, alloc: Allocator, values: []const []const u8, entries: []const model.Entry, digest: [32]u8) void {
    edit.pending = digest;
    edit.status.as(gtk.Widget).setVisible(0);
    var title: [:0]const u8 = tr("Shortcut Conflict");
    if (model.parseValues(alloc, values)) |draft| {
        if (model.firstConflict(draft, entries, edit.entry_key)) |index| {
            const entry = entries[index];
            const config = edit.state.app.getConfig();
            defer config.unref();
            const commands = config.get().@"command-palette-entry".value.items;
            if (actionsText(alloc, entry.actions)) |text| {
                if (entryTitle(alloc, entry, text, commands)) |titles| {
                    title = fillZ(alloc, tr("Conflicts with “{title}” ({source})"), .{ .title = titles.translated, .source = sourceName(entry.source) }) catch title;
                } else |_| {}
            } else |_| {}
        }
    } else |_| {}
    edit.conflict_title.setText(title);
    edit.conflict.setVisible(1);
}

test "every bindable action has a choice and parses by name or with an argument" {
    const testing = std.testing;
    try testing.expect(choices.len > 50);
    try testing.expect(choiceIndex("new_tab") != null);
    try testing.expect(choiceIndex("gx:settings_page") != null);
    try testing.expect(choiceIndex("unbind") == null);
    for (choices) |choice| {
        if (choice.param == .required) continue;
        _ = try Binding.Action.parse(choice.name);
    }
    const copy = choices[choiceIndex("copy_to_clipboard").?];
    try testing.expectEqual(ParamKind.optional, copy.param);
    try testing.expect(std.mem.indexOf(u8, copy.values, "html") != null);
    try testing.expectEqualStrings("gx:settings_page", splitAction("gx:settings_page:font").name);
    try testing.expectEqualStrings("font", splitAction("gx:settings_page:font").param);
    try testing.expectEqualStrings("text", splitAction("text:a:b").name);
    try testing.expectEqualStrings("a:b", splitAction("text:a:b").param);
    try testing.expectEqualStrings("new_tab", splitAction("new_tab").name);
}

test "full shortcut editor compiles against native GTK controls" {
    try std.testing.expect(@intFromPtr(&present) != 0);
}
