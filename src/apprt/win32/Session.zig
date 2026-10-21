//! GUI-thread session adapter. The shared model/Store own the bounded file
//! format and lease. No command, argv, environment or terminal output is saved.
//! App calls tryRestore after instance selection/device setup, markDirty after
//! changes, flush at its non-modal message boundary, onQuit before teardown,
//! onWindowClose before accepted cleanup, and deinit before freeing App.
const Session = @This();
const std = @import("std");
const global = @import("../../global.zig");
const configpkg = @import("../../config.zig");
const model = @import("../../gx/session.zig");
const state_file = @import("../../gx/state_file.zig");
const profiles = @import("../../gx/profiles.zig");
const i18n = @import("../../gx/i18n.zig");
const refs = @import("../../gx/ui_ref.zig");
const Tree = @import("../../datastruct/split_tree.zig").SplitTree(Leaf);
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Leaf = @import("Leaf.zig");
const tabs = @import("tabs.zig");
const Dialogs = @import("ui/Dialogs.zig");
const log = std.log.scoped(.win32_session);

store: ?model.Store = null,
attempted: bool = false,
restoring: bool = false,
quitting: bool = false,
blocked: bool = false,
protect_file: bool = false,
dirty: bool = false,
notice: ?[:0]const u8 = null,
cli: ?Cli = null,

const Cli = struct { explicit_launch: bool = false, font: bool = false, title: bool = false };
const Approval = struct { id: []const u8, digest: [32]u8, allowed: bool };

pub fn deinit(self: *Session) void {
    if (self.store) |*store| store.deinit();
    self.* = .{};
}

fn readCli(alloc: std.mem.Allocator) !Cli {
    var args = try @import("../../cli.zig").args.argsIterator(alloc, global.args());
    defer args.deinit();
    var result: Cli = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e")) {
            result.explicit_launch = true;
            break;
        }
        const text = std.mem.trimStart(u8, arg, "-");
        const key = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
        if (std.mem.eql(u8, key, "command") or std.mem.eql(u8, key, "initial-command") or std.mem.eql(u8, key, "working-directory")) result.explicit_launch = true;
        if (std.mem.eql(u8, key, "font-size")) result.font = true;
        if (std.mem.eql(u8, key, "title")) result.title = true;
    }
    return result;
}
fn policy(self: *Session, app: *App) !Cli {
    if (self.cli == null) self.cli = try readCli(app.core_app.alloc);
    return self.cli.?;
}
fn open(self: *Session, app: *App) !void {
    if (self.store != null) return;
    const alloc = app.core_app.alloc;
    const path = try state_file.path(alloc, model.file_name);
    defer alloc.free(path);
    self.store = try model.Store.open(alloc, global.io(), path);
}
fn failure(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.WorkingDirectoryUnavailable => "A saved working directory is unavailable. The previous session was left unchanged.",
        error.Busy => "The session is already in use by another instance.",
        error.UnsupportedVersion => "The saved session format is not supported.",
        error.InvalidGeneration, error.LimitExceeded, error.InvalidTree, error.InvalidText, error.InvalidCwd, error.InvalidFontSize, error.InvalidGeometry, error.SyntaxError, error.UnexpectedToken, error.UnexpectedEndOfInput, error.MissingField, error.UnknownField, error.DuplicateField, error.InvalidNumber => "The saved session is damaged and was left unchanged.",
        else => "The previous session could not be restored.",
    };
}

/// true suppresses the ordinary default shell. Bootstrap windows without tabs
/// may exist for WGL setup; the caller discards those after a successful restore.
pub fn tryRestore(self: *Session, app: *App) bool {
    if (!app.config.@"gx-session-restore" or self.attempted or app.ipc_forwarded) return false;
    self.attempted = true;
    const cli = self.policy(app) catch |err| {
        self.markRestoreFailure(err);
        return false;
    };
    if (cli.explicit_launch or app.core_app.surfaces.items.len != 0) {
        self.protect_file = cli.explicit_launch;
        return false;
    }
    self.open(app) catch |err| {
        self.blocked = true;
        self.notice = failure(err);
        return false;
    };
    const parsed = (self.store.?.load() catch |err| {
        self.blocked = true;
        self.notice = failure(err);
        return false;
    }) orelse return false;
    defer parsed.deinit();
    if (parsed.value.skipped_leaves != 0) self.notice = "Temporary and unknown launch commands are not restored.";
    for (parsed.value.windows) |window| for (window.tabs) |tab| for (tab.nodes) |node| {
        if (node.leaf) |leaf| if (leaf.cwd_unavailable) {
            self.notice = "Some working directories were unavailable and could not be restored.";
        };
    };
    if (parsed.value.windows.len == 0) return false;
    validateRatios(parsed.value) catch |err| {
        self.markRestoreFailure(err);
        return false;
    };
    self.restoring = true;
    self.protect_file = true;
    defer self.restoring = false;
    const restored = self.restore(app, parsed.value, cli) catch |err| {
        log.warn("session restore failed: {}", .{err});
        self.markRestoreFailure(err);
        return app.quit_requested;
    };
    if (!restored) {
        self.notice = "Some terminals were not restored because their launch profile was unavailable or not approved.";
        return app.quit_requested;
    }
    self.protect_file = false;
    self.dirty = false;
    return true;
}

fn markRestoreFailure(self: *Session, err: anyerror) void {
    self.notice = failure(err);
    // Runtime restore failures are not user deletion of the saved document.
    // Keep this write barrier for the entire process, including fallback close.
    self.blocked = true;
    self.protect_file = true;
}

test "failed restore remains write blocked through fallback removal close and quit" {
    for ([_]anyerror{ error.OutOfMemory, error.SurfaceError, error.InvalidTree, error.StaleWindow }) |err| {
        var state: Session = .{};
        state.markRestoreFailure(err);
        state.markRemoved();
        // Undefined app/window prove these lifecycle guards stop before any
        // snapshot or disk access. They are not permission to save an empty app.
        state.onWindowClose(undefined, undefined);
        state.persist(undefined, null);
        state.onQuit(undefined);
        try std.testing.expect(state.blocked and state.protect_file and state.quitting);
        try std.testing.expect(!state.dirty);
    }
    var skipped: Session = .{ .protect_file = true };
    skipped.markRemoved();
    try std.testing.expect(!skipped.protect_file and skipped.dirty);
}

fn validateRatios(document: model.Document) !void {
    for (document.windows) |window| for (window.tabs) |tab| for (tab.nodes) |node| {
        if (node.split) |split| {
            const ratio: f16 = @floatCast(split.ratio);
            if (ratio <= 0 or ratio >= 1) return error.InvalidTree;
        }
    };
}
fn digest(profile: profiles.Profile) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    switch (profile.command) {
        .command_line => |line| {
            hash.update("command\x00");
            hash.update(line);
        },
        .argv => |args| for (args) |arg| {
            hash.update("arg\x00");
            hash.update(arg);
            hash.update(&.{0});
        },
    }
    return hash.finalResult();
}
fn findApproval(approvals: []const Approval, profile: profiles.Profile) ?bool {
    for (approvals) |approval| if (std.mem.eql(u8, approval.id, profile.id) and std.mem.eql(u8, &approval.digest, &digest(profile))) return approval.allowed;
    return null;
}

/// All custom approvals happen before any PTY is started. No Window or Surface
/// pointer crosses these modal calls; each profile is reacquired afterward.
fn confirmProfiles(app: *App, alloc: std.mem.Allocator, document: model.Document) ![]const Approval {
    var approvals: std.ArrayList(Approval) = .empty;
    for (document.windows) |window| for (window.tabs) |tab| for (tab.nodes) |node| {
        const leaf = node.leaf orelse continue;
        var current = try app.cachedLaunchProfiles();
        defer current.deinit();
        const profile = current.find(leaf.profile_id) orelse continue;
        if (model.restoreDecision(profile.id, true) != .confirm_custom or findApproval(approvals.items, profile.*) != null) continue;
        const text = switch (profile.command) {
            .command_line => |line| line,
            .argv => return error.InvalidProfile,
        };
        const body = try alloc.print("{s}\n{s}\n\n{s}", .{ profile.name, text, i18n.tr("This profile runs its current configured command. Restore it for this session?") });
        const before = digest(profile.*);
        const answer = Dialogs.confirm(null, body, i18n.tr("Restore custom launch profile?"));
        if (app.quit_requested or app.ui_ids.epoch == 0) return error.Cancelled;
        var after = try app.cachedLaunchProfiles();
        defer after.deinit();
        const live = after.find(leaf.profile_id) orelse return error.ProfileChanged;
        if (!std.mem.eql(u8, &before, &digest(live.*))) return error.ProfileChanged;
        try approvals.append(alloc, .{ .id = leaf.profile_id, .digest = before, .allowed = answer == .accept });
    };
    return approvals.items;
}

fn restore(self: *Session, app: *App, document: model.Document, cli: Cli) !bool {
    var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const approvals = try confirmProfiles(app, alloc, document);
    var current = try app.cachedLaunchProfiles();
    defer current.deinit();
    // Reject a config change after an earlier confirmation rather than silently
    // authorizing its new command with the old dialog response.
    for (approvals) |approval| {
        const profile = current.find(approval.id) orelse return error.ProfileChanged;
        if (!std.mem.eql(u8, &approval.digest, &digest(profile.*))) return error.ProfileChanged;
    }
    var staged: std.ArrayList(refs.Reference) = .empty;
    var plans: std.ArrayList(Reveal) = .empty;
    var committed = false;
    defer if (!committed) for (staged.items) |reference| app.discardSessionWindow(reference);
    var skipped = document.skipped_leaves;
    for (document.windows) |saved_window| {
        if (app.quit_requested) return error.Cancelled;
        const window = try app.newWindow(.{});
        const reference = window.ui_reference;
        staged.append(alloc, reference) catch |err| {
            app.discardSessionWindow(reference);
            return err;
        };
        var active: usize = 0;
        for (saved_window.tabs, 0..) |saved_tab, saved_index| {
            const surfaces = try alloc.alloc(?*Leaf, saved_tab.nodes.len);
            @memset(surfaces, null);
            var tree = (try buildTree(app, window, &current, approvals, cli, saved_tab, saved_tab.root, surfaces, &skipped)) orelse continue;
            defer tree.deinit();
            if (saved_tab.zoom) |zoom| if (surfaces[zoom]) |surface| {
                tree.zoomed = tree.locate(surface);
            };
            var iterator = tree.iterator();
            const focused = surfaces[saved_tab.active] orelse iterator.next().?.view;
            const live = app.resolveWindow(reference) orelse return error.StaleWindow;
            const title: ?tabs.Title = if (!cli.title) if (saved_tab.title_override) |text| .fromUtf8(text) else null else null;
            const index = try live.adoptSessionTab(&tree, focused, title);
            if (saved_index == saved_window.active) active = index;
        }
        const live = app.resolveWindow(reference) orelse return error.StaleWindow;
        if (live.tab_count == 0) {
            app.discardSessionWindow(reference);
            _ = staged.pop();
            continue;
        }
        if (!cli.title) if (saved_window.title_override) |title| live.setWindowTitle(try alloc.dupeSentinel(u8, title, 0));
        // Store reveal metadata in a bounded staging array below. App callbacks
        // must not show any parent during adoptSessionTab.
        try plans.append(alloc, .{ .reference = reference, .active = active, .geometry = saved_window.geometry });
    }
    if (staged.items.len == 0) return false;
    for (plans.items) |plan| {
        const window = app.resolveWindow(plan.reference) orelse return error.StaleWindow;
        try window.revealSession(plan.active, if (app.config.@"window-save-state" == .never) null else plan.geometry);
    }
    committed = true;
    if (skipped != 0) self.notice = "Some terminals were not restored because their launch profile was unavailable or not approved.";
    return true;
}

const Reveal = struct { reference: refs.Reference, active: usize, geometry: ?model.Geometry };

fn buildTree(app: *App, window: *Window, current: *const profiles.List, approvals: []const Approval, cli: Cli, tab: model.Tab, index: u16, surfaces: []?*Leaf, skipped: *u32) anyerror!?Tree {
    const node = tab.nodes[index];
    if (node.leaf) |leaf| {
        const profile = current.find(leaf.profile_id) orelse {
            skipped.* += 1;
            return null;
        };
        if (model.restoreDecision(profile.id, true) == .confirm_custom and findApproval(approvals, profile.*) != true) {
            skipped.* += 1;
            return null;
        }
        var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const command = try profileCommand(alloc, profile.*, leaf.cwd);
        const title = if (!cli.title) if (leaf.title_override) |text| try alloc.dupeSentinel(u8, text, 0) else null else null;
        const cwd = try localCwd(alloc, profile.*, leaf.cwd);
        const surface = try app.core_app.alloc.create(Surface);
        surface.initWithOptions(app, window, .{
            .context = .window,
            .command = &command,
            .profile_id = profile.id,
            .session_restore = true,
            .working_directory = cwd,
            .font_size = if (cli.font) null else leaf.font_size,
            .title = title,
        }) catch |err| {
            surface.deinit();
            app.core_app.alloc.destroy(surface);
            return err;
        };
        const identity = Leaf.fromLocal(app.core_app.alloc, surface) catch |err| {
            surface.deinit();
            app.core_app.alloc.destroy(surface);
            return err;
        };
        var tree = Tree.init(app.core_app.alloc, identity) catch |err| {
            identity.discardUnretained(app.core_app.alloc);
            surface.deinit();
            app.core_app.alloc.destroy(surface);
            return err;
        };
        errdefer tree.deinit();
        if (app.quit_requested) return error.Cancelled;
        surfaces[index] = identity;
        return tree;
    }
    const split = node.split.?;
    var first = try buildTree(app, window, current, approvals, cli, tab, split.first, surfaces, skipped);
    var second = buildTree(app, window, current, approvals, cli, tab, split.second, surfaces, skipped) catch |err| {
        if (first) |*tree| tree.deinit();
        return err;
    };
    if (first == null) return second;
    if (second == null) return first;
    defer first.?.deinit();
    defer second.?.deinit();
    return try first.?.split(app.core_app.alloc, .root, if (split.axis == .horizontal) .right else .down, @floatCast(split.ratio), &second.?);
}

/// Guest POSIX paths become a WSL option only for the detected WSL profile;
/// other profiles never interpret foreign-domain paths as a host cwd.
fn profileCommand(alloc: std.mem.Allocator, profile: profiles.Profile, cwd: ?model.Cwd) !configpkg.Command {
    switch (profile.command) {
        .command_line => |line| {
            var command: configpkg.Command = undefined;
            try command.parseCLI(alloc, line);
            return command;
        },
        .argv => |argv| {
            if (profile.kind == .wsl) if (cwd) |directory| if (directory.kind == .posix) {
                try model.validateCwd(directory);
                const args = try alloc.alloc([:0]const u8, argv.len + 2);
                @memcpy(args[0..argv.len], argv);
                args[argv.len] = "--cd";
                args[argv.len + 1] = try alloc.dupeSentinel(u8, directory.path, 0);
                return .{ .direct = args };
            };
            return .{ .direct = argv };
        },
    }
}
fn localCwd(alloc: std.mem.Allocator, profile: profiles.Profile, cwd: ?model.Cwd) !?[:0]const u8 {
    const directory = cwd orelse return null;
    if (directory.kind != .windows or profile.kind == .wsl) return null;
    try model.validateCwd(directory);
    var drive: [3:0]u16 = .{ directory.path[0], ':', '\\' };
    switch (GetDriveTypeW(&drive)) {
        2, 3, 5, 6 => {}, // Local removable, fixed, optical or RAM volume.
        else => return error.WorkingDirectoryUnavailable,
    }
    // Restoring a cwd does not require listing it or reading its ACL. The
    // generic directory API requests READ_CONTROL/READ_EA on Windows, which
    // rejects otherwise usable directories under restricted process tokens.
    // Query metadata only; CreateProcess still validates the cwd at launch.
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, directory.path);
    defer alloc.free(wide);
    const attributes = GetFileAttributesW(wide);
    if (attributes == 0xffffffff or attributes & 0x10 == 0) return error.WorkingDirectoryUnavailable;
    return try alloc.dupeSentinel(u8, directory.path, 0);
}

extern "kernel32" fn GetDriveTypeW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;

pub fn markDirty(self: *Session) void {
    self.dirty = true;
}
pub fn markRemoved(self: *Session) void {
    if (self.blocked or self.restoring or self.quitting) return;
    self.protect_file = false;
    self.dirty = true;
}
pub fn flush(self: *Session, app: *App) void {
    if (self.dirty and !self.restoring and !self.quitting and !self.protect_file) {
        self.dirty = false;
        self.persist(app, null);
    }
    for (app.windows.items) |window| {
        if (!window.closing and !window.is_quick_terminal and window.shown) {
            self.showPendingNotice(window);
            break;
        }
    }
}
pub fn showPendingNotice(self: *Session, window: *Window) void {
    if (window.closing or window.is_quick_terminal or !window.shown) return;
    const message = self.notice orelse return;
    self.notice = null;
    window.showToast(.{ .text = i18n.trRuntime(message) });
}
pub fn onWindowClose(self: *Session, app: *App, window: *Window) void {
    if (self.blocked or self.restoring or self.quitting or window.is_quick_terminal) return;
    self.protect_file = false;
    self.dirty = false;
    self.persist(app, window);
}
pub fn onQuit(self: *Session, app: *App) void {
    if (self.quitting) return;
    if (!self.restoring and !self.protect_file) self.persist(app, null);
    self.quitting = true;
    self.dirty = false;
}
fn persist(self: *Session, app: *App, exclude: ?*Window) void {
    if (self.blocked or self.restoring or !app.config.@"gx-session-restore" or app.ipc_forwarded) return;
    const cli = self.policy(app) catch return;
    if (cli.explicit_launch) return;
    self.open(app) catch |err| {
        self.blocked = true;
        self.notice = failure(err);
        return;
    };
    const next = std.math.add(u64, self.store.?.generation, 1) catch {
        self.notice = "The session could not be saved.";
        return;
    };
    var arena = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena.deinit();
    const document = snapshot(app, arena.allocator(), next, exclude) catch |err| {
        if (err == error.NotReady) {
            self.dirty = true;
            return;
        }
        log.warn("session snapshot failed: {}", .{err});
        self.notice = "The session could not be saved.";
        return;
    };
    self.store.?.save(document) catch |err| {
        log.warn("session save failed: {}", .{err});
        self.notice = "The session could not be saved.";
    };
}

fn snapshotNode(alloc: std.mem.Allocator, tree: *const Tree, index: Tree.Node.Handle, nodes: *std.ArrayList(model.Node), mapping: []?u16, skipped: *u32) anyerror!?u16 {
    const result: u16 = switch (tree.nodes[index.idx()]) {
        .leaf => |identity| leaf: {
            const surface = identity.local() orelse {
                skipped.* += 1;
                return null;
            };
            if (!surface.core_surface_ready) return error.NotReady;
            const id = surface.launch_origin.profileId() orelse {
                skipped.* += 1;
                return null;
            };
            var cwd: ?model.Cwd = null;
            var cwd_unavailable = false;
            if (std.mem.startsWith(u8, id, "wsl:")) {
                // Never reinterpret a host Windows cwd as a guest path.
                const guest = try surface.snapshotGuestCwd(alloc);
                if (guest.path) |path| cwd = .{ .kind = .posix, .path = path };
                cwd_unavailable = guest.unavailable;
            } else if (try surface.core_surface.pwd(alloc)) |path| {
                const typed: model.Cwd = .{ .kind = .windows, .path = path };
                if (model.validateCwd(typed)) |_| {
                    cwd = typed;
                } else |_| cwd_unavailable = true;
            }
            const result: u16 = @intCast(nodes.items.len);
            try nodes.append(alloc, .{ .leaf = .{
                .profile_id = try alloc.dupe(u8, id),
                .cwd = cwd,
                .cwd_unavailable = cwd_unavailable,
                .font_size = surface.core_surface.font_size.points,
                .title_override = if (surface.sessionTitle()) |title| try alloc.dupe(u8, title) else null,
            } });
            break :leaf result;
        },
        .split => |split| split: {
            const first = try snapshotNode(alloc, tree, split.left, nodes, mapping, skipped);
            const second = try snapshotNode(alloc, tree, split.right, nodes, mapping, skipped);
            if (first == null) return second;
            if (second == null) return first;
            const result: u16 = @intCast(nodes.items.len);
            try nodes.append(alloc, .{ .split = .{ .axis = if (split.layout == .horizontal) .horizontal else .vertical, .ratio = @floatCast(split.ratio), .first = first.?, .second = second.? } });
            break :split result;
        },
    };
    mapping[index.idx()] = result;
    return result;
}
fn snapshot(app: *App, alloc: std.mem.Allocator, generation: u64, exclude: ?*Window) !model.Document {
    var windows: std.ArrayList(model.Window) = .empty;
    var skipped: u32 = 0;
    for (app.windows.items) |window| {
        if (window == exclude or window.closing or window.is_quick_terminal or !window.shown or window.tab_count == 0) continue;
        if (windows.items.len >= model.max_windows) return error.LimitExceeded;
        var saved_tabs: std.ArrayList(model.Tab) = .empty;
        var active: u16 = 0;
        for (window.tab_trees[0..window.tab_count], 0..) |*tree, index| {
            if (tree.nodes.len == 0) continue;
            if (tree.nodes.len > model.max_nodes or saved_tabs.items.len >= model.max_tabs) return error.LimitExceeded;
            var nodes: std.ArrayList(model.Node) = .empty;
            const mapping = try alloc.alloc(?u16, tree.nodes.len);
            @memset(mapping, null);
            const root = (try snapshotNode(alloc, tree, .root, &nodes, mapping, &skipped)) orelse continue;
            var active_leaf: u16 = for (nodes.items, 0..) |node, leaf_index| {
                if (node.leaf != null) break @intCast(leaf_index);
            } else return error.InvalidTree;
            if (tree.locate(window.tab_active_surface[index])) |handle| active_leaf = mapping[handle.idx()] orelse active_leaf;
            if (index == window.active_tab) active = @intCast(saved_tabs.items.len);
            try saved_tabs.append(alloc, .{
                .nodes = nodes.items,
                .root = root,
                .active = active_leaf,
                .zoom = if (tree.zoomed) |zoom| mapping[zoom.idx()] else null,
                .title_override = if (window.tab_title_overrides[index]) |title| try std.unicode.utf16LeToUtf8Alloc(alloc, title.buf[0..title.len]) else null,
            });
        }
        if (saved_tabs.items.len == 0) continue;
        var geometry: ?model.Geometry = null;
        if (app.config.@"window-save-state" != .never) if (window.normal_rect) |rect| {
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;
            if (width >= 64 and height >= 64 and width <= 32768 and height <= 32768) geometry = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .x = rect.left,
                .y = rect.top,
                .dpi = if (std.math.isFinite(window.scale) and window.scale >= 0.5 and window.scale <= 8) @intFromFloat(window.scale * 96) else 96,
                .maximized = window.maximized,
            };
        };
        try windows.append(alloc, .{
            .tabs = saved_tabs.items,
            .active = active,
            .geometry = geometry,
            .title_override = if (window.window_title_override_len) |len| try std.unicode.utf16LeToUtf8Alloc(alloc, window.window_title_override[0..len]) else null,
        });
    }
    const document: model.Document = .{ .version = model.version, .generation = generation, .windows = windows.items, .skipped_leaves = skipped };
    try model.validate(document);
    return document;
}

test "WSL restore carries typed guest cwd as an argument without host cwd interpretation" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const profile: profiles.Profile = .{ .id = "wsl:Ubuntu", .name = "Ubuntu", .kind = .wsl, .command = .{ .argv = &.{ "wsl.exe", "-d", "Ubuntu" } } };
    const command = try profileCommand(arena.allocator(), profile, .{ .kind = .posix, .path = "/home/user/work dir" });
    try testing.expectEqual(@as(usize, 5), command.direct.len);
    try testing.expectEqualStrings("--cd", command.direct[3]);
    try testing.expectEqualStrings("/home/user/work dir", command.direct[4]);
    try testing.expect((try localCwd(arena.allocator(), profile, .{ .kind = .posix, .path = "/home/user" })) == null);
}

test "custom approval is bound to exact current command and stable identity" {
    const testing = std.testing;
    const profile: profiles.Profile = .{ .id = "custom:A", .name = "A", .kind = .custom, .command = .{ .command_line = "direct:pwsh" } };
    const approvals = [_]Approval{.{ .id = profile.id, .digest = digest(profile), .allowed = true }};
    try testing.expectEqual(@as(?bool, true), findApproval(&approvals, profile));
    var changed = profile;
    changed.command = .{ .command_line = "direct:other" };
    try testing.expect(findApproval(&approvals, changed) == null);
    changed = profile;
    changed.id = "custom:B";
    try testing.expect(findApproval(&approvals, changed) == null);
}

test "session entrypoints compile against Windows production adapters" {
    const functions = .{ &tryRestore, &onWindowClose, &onQuit, &flush, &deinit };
    inline for (functions) |function| try std.testing.expect(@intFromPtr(function) != 0);
}

test "snapshot excludes unknown and ad hoc surfaces without reading terminal state" {
    const testing = std.testing;
    for ([_]@import("../../gx/profiles.zig").LaunchOrigin{ .unknown, .ad_hoc }) |origin| {
        // The undefined core state would be invalid to read: rejected origins
        // must stop before accessing cwd, titles, commands, or terminal memory.
        var surface: Surface = .{ .app = undefined, .launch_origin = origin, .core_surface_ready = true, .ref_count = 1 };
        var tree = try Tree.init(testing.allocator, try Leaf.fromLocal(testing.allocator, &surface));
        defer tree.deinit();
        var nodes: std.ArrayList(model.Node) = .empty;
        defer nodes.deinit(testing.allocator);
        var mapping = [_]?u16{null};
        var skipped: u32 = 0;
        try testing.expect((try snapshotNode(testing.failing_allocator, &tree, .root, &nodes, &mapping, &skipped)) == null);
        try testing.expectEqual(@as(u32, 1), skipped);
        try testing.expectEqual(@as(usize, 0), nodes.items.len);
    }
}

test "foreign and network cwd fail before probing the host" {
    const testing = std.testing;
    const profile: profiles.Profile = .{ .id = "custom:Shell", .name = "Shell", .kind = .custom, .command = .{ .command_line = "direct:cmd.exe" } };
    try testing.expect((try localCwd(testing.failing_allocator, profile, .{ .kind = .posix, .path = "/home/user" })) == null);
    try testing.expectError(error.InvalidCwd, localCwd(testing.failing_allocator, profile, .{ .kind = .windows, .path = "\\\\server\\share" }));
}

test "local cwd metadata accepts a directory and rejects missing and file paths" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(directory);
    const profile: profiles.Profile = .{ .id = "custom:Shell", .name = "Shell", .kind = .custom, .command = .{ .command_line = "direct:cmd.exe" } };
    const restored = (try localCwd(testing.allocator, profile, .{ .kind = .windows, .path = directory })).?;
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(directory, restored);
    const absent = try std.fs.path.join(testing.allocator, &.{ directory, "missing" });
    defer testing.allocator.free(absent);
    try testing.expectError(error.WorkingDirectoryUnavailable, localCwd(testing.allocator, profile, .{ .kind = .windows, .path = absent }));
    var file = try tmp.dir.createFile(io, "file", .{});
    file.close(io);
    const ordinary_file = try std.fs.path.join(testing.allocator, &.{ directory, "file" });
    defer testing.allocator.free(ordinary_file);
    try testing.expectError(error.WorkingDirectoryUnavailable, localCwd(testing.allocator, profile, .{ .kind = .windows, .path = ordinary_file }));
}

test "session prunes remote leaves without inspecting remote terminal metadata" {
    const testing = std.testing;
    var remote: @import("RemotePane.zig") = undefined;
    remote.ref_count = 1;
    remote.destroying = true;
    const identity = try Leaf.fromRemote(testing.allocator, &remote);
    var tree = try Tree.init(testing.allocator, identity);
    defer tree.deinit();
    var nodes: std.ArrayList(model.Node) = .empty;
    defer nodes.deinit(testing.allocator);
    var mapping = [_]?u16{null};
    var skipped: u32 = 0;
    try testing.expect((try snapshotNode(testing.failing_allocator, &tree, .root, &nodes, &mapping, &skipped)) == null);
    try testing.expectEqual(@as(u32, 1), skipped);
    try testing.expectEqual(@as(usize, 0), nodes.items.len);
    try testing.expect(mapping[0] == null);
}
