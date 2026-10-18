//! Transactional JumpList tasks from an owned cached-profile snapshot.
//! Publishing is a real shell write: callers enable it only for verified shell
//! registration and authorized environments. This module never registers apps.
const std = @import("std");
const Identity = @import("Identity.zig");
const argv = @import("../../../gx/windows_argv.zig");
const Interface = Identity.Interface;
const GUID = Identity.GUID;
const HRESULT = Identity.HRESULT;
pub const max_profiles = 64;
pub const Profile = struct { id: []const u8, title: []const u8 };
pub const Task = struct { profile_id: []const u8, title: [:0]const u16, arguments: [:0]const u16 };
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    tasks: []const Task,
    executable: [:0]const u16,
    fingerprint: [32]u8,
    /// Inputs come from App.cachedLaunchProfiles, never from another PATH scan.
    pub fn init(alloc: std.mem.Allocator, identity: *const Identity, profiles: []const Profile) !Snapshot {
        if (profiles.len > max_profiles) return error.LimitExceeded;
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const tasks = try owned.alloc(Task, profiles.len);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(identity.aumid_utf8);
        hash.update(&.{0});
        hash.update(identity.exe_utf8);
        hash.update(&.{0});
        for (profiles, tasks) |profile, *task| {
            try Identity.validateProfile(profile.id);
            if (profile.title.len > 2048 or std.mem.indexOfScalar(u8, profile.title, 0) != null or !std.unicode.utf8ValidateSlice(profile.title)) return error.InvalidTitle;
            const id_argument = try std.fmt.allocPrint(owned, "{s}{s}", .{ Identity.profile_switch, profile.id });
            task.* = .{ .profile_id = try owned.dupe(u8, profile.id), .title = try std.unicode.utf8ToUtf16LeAllocZ(owned, profile.title), .arguments = try argv.encode(owned, &.{ Identity.profile_argument, id_argument }) };
            hash.update(profile.id);
            hash.update(&.{0});
            hash.update(profile.title);
            hash.update(&.{0});
        }
        const executable = try owned.dupeZ(u16, identity.exe);
        return .{ .arena = arena, .tasks = tasks, .executable = executable, .fingerprint = hash.finalResult() };
    }
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Publisher = struct {
    applied: ?[32]u8 = null,
    /// COM is owned by the caller's existing apartment; this does not initialize
    /// or uninitialize the GUI STA. A failed update does not advance the digest.
    pub fn publish(self: *Publisher, identity: *const Identity, snapshot: *const Snapshot) !bool {
        return self.publishWith(identity, snapshot, Native);
    }

    fn publishWith(self: *Publisher, identity: *const Identity, snapshot: *const Snapshot, comptime Backend: type) !bool {
        if (!identity.registration_verified) return error.UnregisteredIdentity;
        if (self.applied) |previous| if (std.mem.eql(u8, &previous, &snapshot.fingerprint)) return false;
        var native = try Backend.init(identity, snapshot);
        defer native.deinit();
        try transaction(&native, snapshot.tasks);
        self.applied = snapshot.fingerprint;
        return true;
    }
};

/// A failure at BeginList, task construction, AddUserTasks, or CommitList always
/// aborts the transaction. The previous committed list is left intact by Shell.
pub fn transaction(backend: anytype, tasks: []const Task) !void {
    var committed = false;
    defer if (!committed) backend.abort();
    try backend.begin();
    for (tasks) |task| try backend.add(task);
    try backend.commit();
    committed = true;
}

const Native = struct {
    identity: *const Identity,
    snapshot: *const Snapshot,
    destination: *Interface,
    collection: ?*Interface = null,
    fn init(identity: *const Identity, snapshot: *const Snapshot) !Native {
        return .{ .identity = identity, .snapshot = snapshot, .destination = try create(&clsid_destination, &iid_destination) };
    }
    fn deinit(self: *Native) void {
        if (self.collection) |collection| Identity.release(collection);
        Identity.release(self.destination);
    }
    fn begin(self: *Native) !void {
        // SDK shobjidl_core.h ICustomDestinationList slots 3=SetAppID,4=BeginList.
        try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, self.destination, 3)(self.destination, self.identity.aumid));
        var slots: u32 = 0;
        var removed: ?*Interface = null;
        const hr = Identity.method(*const fn (*Interface, *u32, *const GUID, *?*Interface) callconv(.winapi) HRESULT, self.destination, 4)(self.destination, &slots, &iid_array, &removed);
        defer if (removed) |object| Identity.release(object);
        try check(hr);
        self.collection = try create(&clsid_collection, &iid_collection);
    }
    fn add(self: *Native, task: Task) !void {
        const link = try create(&clsid_link, &iid_link);
        defer Identity.release(link);
        // IShellLinkW slots are taken from SDK shobjidl_core.h, not IDispatch.
        try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 20)(link, self.snapshot.executable));
        try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 11)(link, task.arguments));
        try check(Identity.method(*const fn (*Interface, [*:0]const u16, c_int) callconv(.winapi) HRESULT, link, 17)(link, self.snapshot.executable, 0));
        try check(Identity.method(*const fn (*Interface, c_int) callconv(.winapi) HRESULT, link, 15)(link, 1));
        const properties = try Identity.query(link, &iid_property_store);
        defer Identity.release(properties);
        try setString(properties, &pkey_title, task.title);
        try setString(properties, &pkey_aumid, self.identity.aumid);
        try check(Identity.method(*const fn (*Interface) callconv(.winapi) HRESULT, properties, 7)(properties));
        const collection = self.collection orelse return error.NotStarted;
        try check(Identity.method(*const fn (*Interface, *Interface) callconv(.winapi) HRESULT, collection, 5)(collection, link));
    }
    fn commit(self: *Native) !void {
        const array = try Identity.query(self.collection orelse return error.NotStarted, &iid_array);
        defer Identity.release(array);
        try check(Identity.method(*const fn (*Interface, *Interface) callconv(.winapi) HRESULT, self.destination, 7)(self.destination, array));
        try check(Identity.method(*const fn (*Interface) callconv(.winapi) HRESULT, self.destination, 8)(self.destination));
    }
    fn abort(self: *Native) void {
        _ = Identity.method(*const fn (*Interface) callconv(.winapi) HRESULT, self.destination, 11)(self.destination);
    }
};
fn check(hr: HRESULT) !void {
    if (hr < 0) return error.ShellTransactionFailed;
}
fn create(clsid: *const GUID, iid: *const GUID) !*Interface {
    var object: ?*Interface = null;
    try check(CoCreateInstance(clsid, null, 1, iid, &object));
    return object orelse return error.ShellUnavailable;
}
extern "ole32" fn CoCreateInstance(*const GUID, ?*Interface, u32, *const GUID, *?*Interface) callconv(.winapi) HRESULT;
const PropertyKey = extern struct { fmtid: GUID, pid: u32 };
const PropertyVariant = extern struct {
    vt: u16 = 31,
    reserved: [3]u16 = @splat(0),
    value: extern union { string: [*:0]const u16, storage: [2]usize },
};
fn setString(store: *Interface, property: *const PropertyKey, text: [:0]const u16) !void {
    const value: PropertyVariant = .{ .value = .{ .string = text } };
    try check(Identity.method(*const fn (*Interface, *const PropertyKey, *const PropertyVariant) callconv(.winapi) HRESULT, store, 6)(store, property, &value));
}
const clsid_destination = Identity.guid("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
const iid_destination = Identity.guid("6332debf-87b5-4670-90c0-5e57b408a49e");
const clsid_collection = Identity.guid("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");
const iid_collection = Identity.guid("5632b1a4-e38a-400a-928a-d4cd63230295");
const iid_array = Identity.guid("92ca9dcd-5622-4bba-a805-5e9f541bd8c9");
const clsid_link = Identity.guid("00021401-0000-0000-c000-000000000046");
const iid_link = Identity.guid("000214f9-0000-0000-c000-000000000046");
const iid_property_store = Identity.guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
const pkey_title: PropertyKey = .{ .fmtid = Identity.guid("f29f85e0-4ff9-1068-ab91-08002b27b3d9"), .pid = 2 };
const pkey_aumid: PropertyKey = .{ .fmtid = Identity.guid("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), .pid = 5 };

test "every failed native transaction phase aborts and success commits once" {
    const testing = std.testing;
    const Fake = struct {
        fail: u8,
        phase: u8 = 0,
        aborted: usize = 0,
        committed: usize = 0,
        fn step(self: *@This()) !void {
            self.phase += 1;
            if (self.phase == self.fail) return error.InjectedFailure;
        }
        fn begin(self: *@This()) !void {
            try self.step();
        }
        fn add(self: *@This(), _: Task) !void {
            try self.step();
        }
        fn commit(self: *@This()) !void {
            try self.step();
            self.committed += 1;
        }
        fn abort(self: *@This()) void {
            self.aborted += 1;
        }
    };
    const tasks = [_]Task{.{ .profile_id = "id", .title = &.{0}, .arguments = &.{0} }};
    for (1..4) |phase| {
        var fake: Fake = .{ .fail = @intCast(phase) };
        try testing.expectError(error.InjectedFailure, transaction(&fake, &tasks));
        try testing.expectEqual(@as(usize, 1), fake.aborted);
        try testing.expectEqual(@as(usize, 0), fake.committed);
    }
    var success: Fake = .{ .fail = 0 };
    try transaction(&success, &tasks);
    try testing.expectEqual(@as(usize, 0), success.aborted);
    try testing.expectEqual(@as(usize, 1), success.committed);
}
test "owned task snapshot carries stable IDs only and rejects host publication when portable" {
    const testing = std.testing;
    var identity = try Identity.init(testing.allocator, .portable, "C:/My App/ghostty.exe", false);
    defer identity.deinit();
    var snapshot = try Snapshot.init(testing.allocator, &identity, &.{.{ .id = "custom:A B", .title = "A B" }});
    defer snapshot.deinit();
    const text = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, snapshot.tasks[0].arguments);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "--gx-shell-profile=custom:A B") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--command") == null);
    var publisher: Publisher = .{};
    try testing.expectError(error.UnregisteredIdentity, publisher.publish(&identity, &snapshot));
    try testing.expectEqual(@as(usize, 20), @sizeOf(PropertyKey));
    try testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 16), @sizeOf(PropertyVariant));
}

test "D18 ShellLink arguments preserve profile IDs through Ghostty argv parsing" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const t = std.testing;
    const Com = struct {
        extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
        extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    };
    const initialized = Com.CoInitializeEx(null, 2);
    // A test runner thread may already own an MTA. ShellLink works in either.
    if (initialized != @as(i32, @bitCast(@as(u32, 0x80010106)))) try check(initialized);
    defer if (initialized >= 0) Com.CoUninitialize();
    var identity = try Identity.init(t.allocator, .portable, "C:/My App/ghostty.exe", false);
    defer identity.deinit();
    const profiles = [_]Profile{
        .{ .id = "custom:Space Name", .title = "Space Name" },
        .{ .id = "custom:中文", .title = "中文" },
        .{ .id = "custom:Trail\\", .title = "Trail\\" },
        .{ .id = "custom:嵌入\"引号\\\\", .title = "Quote" },
    };
    var snapshot = try Snapshot.init(t.allocator, &identity, &profiles);
    defer snapshot.deinit();
    for (snapshot.tasks) |task| {
        // An in-memory ShellLink only: no Save, registration or JumpList write.
        const link = try create(&clsid_link, &iid_link);
        defer Identity.release(link);
        try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 11)(link, task.arguments));
        var buffer: [4096]u16 = @splat(0);
        try check(Identity.method(*const fn (*Interface, [*]u16, c_int) callconv(.winapi) HRESULT, link, 10)(link, &buffer, buffer.len));
        const stored = std.mem.sliceTo(&buffer, 0);
        try t.expectEqualSlices(u16, task.arguments, stored);
        const command = try std.mem.concat(t.allocator, u16, &.{ std.unicode.utf8ToUtf16LeStringLiteral("ghostty.exe "), stored });
        defer t.allocator.free(command);
        var iter = try std.process.Args.Iterator.Windows.init(t.allocator, command);
        defer iter.deinit();
        try t.expectEqualStrings("ghostty.exe", iter.next().?);
        try t.expectEqualStrings(Identity.profile_argument, iter.next().?);
        const expected = try std.fmt.allocPrint(t.allocator, "{s}{s}", .{ Identity.profile_switch, task.profile_id });
        defer t.allocator.free(expected);
        try t.expectEqualStrings(expected, iter.next().?);
        try t.expect(iter.next() == null);
    }
}

test "D19 already committed fingerprint skips the native Shell transaction" {
    const t = std.testing;
    const Backend = struct {
        fn init(_: *const Identity, _: *const Snapshot) error{UnexpectedNativeCall}!@This() {
            return error.UnexpectedNativeCall;
        }
        fn deinit(_: *@This()) void {}
        fn begin(_: *@This()) !void {}
        fn add(_: *@This(), _: Task) !void {}
        fn commit(_: *@This()) !void {}
        fn abort(_: *@This()) void {}
    };
    var identity = try Identity.init(t.allocator, .portable, "C:/My App/ghostty.exe", false);
    defer identity.deinit();
    identity.registration_verified = true;
    var snapshot = try Snapshot.init(t.allocator, &identity, &.{.{ .id = "custom:Test", .title = "Test" }});
    defer snapshot.deinit();
    var publisher: Publisher = .{ .applied = snapshot.fingerprint };
    // A regression must fail the test, never publish to the real user's Shell.
    try t.expect(!try publisher.publishWith(&identity, &snapshot, Backend));
    try t.expectEqual(snapshot.fingerprint, publisher.applied.?);
}

test "D19 failed commit preserves the fingerprint and identical snapshot can retry" {
    const t = std.testing;
    const Factory = struct {
        fn backend(comptime fail: bool) type {
            return struct {
                committed: bool = false,
                aborted: bool = false,
                fn init(_: *const Identity, _: *const Snapshot) !@This() {
                    return .{};
                }
                fn deinit(self: *@This()) void {
                    std.debug.assert(if (fail) self.aborted and !self.committed else self.committed and !self.aborted);
                }
                fn begin(_: *@This()) !void {}
                fn add(_: *@This(), _: Task) !void {}
                fn commit(self: *@This()) !void {
                    if (fail) return error.ShellTransactionFailed;
                    self.committed = true;
                }
                fn abort(self: *@This()) void {
                    self.aborted = true;
                }
            };
        }
    };
    var identity = try Identity.init(t.allocator, .portable, "C:/My App/ghostty.exe", false);
    defer identity.deinit();
    identity.registration_verified = true;
    var snapshot = try Snapshot.init(t.allocator, &identity, &.{.{ .id = "custom:Test", .title = "Test" }});
    defer snapshot.deinit();
    var previous = snapshot.fingerprint;
    previous[0] ^= 1;
    var publisher: Publisher = .{ .applied = previous };
    try t.expectError(error.ShellTransactionFailed, publisher.publishWith(&identity, &snapshot, Factory.backend(true)));
    try t.expectEqual(previous, publisher.applied.?);
    try t.expect(try publisher.publishWith(&identity, &snapshot, Factory.backend(false)));
    try t.expectEqual(snapshot.fingerprint, publisher.applied.?);
    try t.expect(!try publisher.publishWith(&identity, &snapshot, Factory.backend(true)));
}

const iid_persist_file = Identity.guid("0000010b-0000-0000-c000-000000000046");
extern "ole32" fn PropVariantClear(*PropertyVariant) callconv(.winapi) HRESULT;

fn emptyAppId(store: *Interface) !bool {
    var value: PropertyVariant = .{ .vt = 0, .value = .{ .storage = .{ 0, 0 } } };
    try check(Identity.method(*const fn (*Interface, *const PropertyKey, *PropertyVariant) callconv(.winapi) HRESULT, store, 5)(store, &pkey_aumid, &value));
    defer _ = PropVariantClear(&value);
    return value.vt == 0 or (value.vt == 31 and @intFromPtr(value.value.string) != 0 and value.value.string[0] == 0);
}

fn pinCandidate(identity: *const Identity, empty: bool, target: []const u16, executable: []const u16) bool {
    return identity.mode == .installed and identity.registration_verified and
        std.mem.eql(u8, identity.aumid_utf8, Identity.installed_aumid) and empty and Identity.wideEqual(target, executable);
}

fn migrateShortcut(alloc: std.mem.Allocator, identity: *const Identity, path: [:0]const u16) !bool {
    if (identity.mode != .installed or !identity.registration_verified or
        !std.mem.eql(u8, identity.aumid_utf8, Identity.installed_aumid)) return false;
    const link = try loadLink(path);
    defer Identity.release(link);
    const properties = try Identity.query(link, &iid_property_store);
    defer Identity.release(properties);
    if (!try emptyAppId(properties)) return false;
    var target_buffer: [32768:0]u16 = @splat(0);
    try check(Identity.method(*const fn (*Interface, [*]u16, c_int, ?*anyopaque, u32) callconv(.winapi) HRESULT, link, 3)(link, &target_buffer, target_buffer.len, null, 0));
    // Native handles normalize short names, separators and reparse points.
    // Do not invoke ShellLink Resolve: it can search for moved foreign targets.
    const target = try Identity.finalPath(alloc, &target_buffer);
    defer alloc.free(target);
    const executable = try Identity.finalPath(alloc, identity.exe);
    defer alloc.free(executable);
    if (!pinCandidate(identity, true, target, executable)) return false;
    try setString(properties, &pkey_aumid, identity.aumid);
    try check(Identity.method(*const fn (*Interface) callconv(.winapi) HRESULT, properties, 7)(properties));
    try saveLink(link, path);
    return true;
}

fn saveLink(link: *Interface, path: [:0]const u16) !void {
    const file = try Identity.query(link, &iid_persist_file);
    defer Identity.release(file);
    try check(Identity.method(*const fn (*Interface, [*:0]const u16, i32) callconv(.winapi) HRESULT, file, 6)(file, path, 1));
}

fn loadLink(path: [:0]const u16) !*Interface {
    const link = try create(&clsid_link, &iid_link);
    errdefer Identity.release(link);
    const file = try Identity.query(link, &iid_persist_file);
    defer Identity.release(file);
    try check(Identity.method(*const fn (*Interface, [*:0]const u16, u32) callconv(.winapi) HRESULT, file, 5)(file, path, 2));
    return link;
}

test "apprt.win32.shell.D28 pin filtering requires installed identity empty AUMID and exact canonical path" {
    const t = std.testing;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    var installed = try Identity.init(t.allocator, .installed, "C:/GX/ghostty.exe", true);
    defer installed.deinit();
    var portable = try Identity.init(t.allocator, .portable, "C:/GX/ghostty.exe", false);
    defer portable.deinit();
    try t.expect(pinCandidate(&installed, true, wide("C:\\GX\\GHOSTTY.EXE"), wide("c:\\gx\\ghostty.exe")));
    try t.expect(!pinCandidate(&installed, false, installed.exe, installed.exe));
    try t.expect(!pinCandidate(&portable, true, installed.exe, installed.exe));
    try migratePinned(t.allocator, t.io, &portable);
    try t.expect(!pinCandidate(&installed, true, wide("C:\\Other\\ghostty.exe"), installed.exe));
    try t.expect(!pinCandidate(&installed, true, wide("C:\\GX\\ghostty.exe.other"), installed.exe));
}

test "apprt.win32.shell.D28 real saved links migrate only empty matching pin and are idempotent" {
    const t = std.testing;
    const alloc = t.allocator;
    const Com = struct {
        extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
        extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    };
    const initialized = Com.CoInitializeEx(null, 2);
    if (initialized != @as(i32, @bitCast(@as(u32, 0x80010106)))) try check(initialized);
    defer if (initialized >= 0) Com.CoUninitialize();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "ghostty.exe", "other.exe" }) |name| {
        const file = try tmp.dir.createFile(t.io, name, .{});
        file.close(t.io);
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", alloc);
    defer alloc.free(root);
    const exe = try std.fs.path.join(alloc, &.{ root, "ghostty.exe" });
    defer alloc.free(exe);
    var identity = try Identity.init(alloc, .installed, exe, true);
    defer identity.deinit();
    const other = try std.fs.path.join(alloc, &.{ root, "other.exe" });
    defer alloc.free(other);
    const other_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, other);
    defer alloc.free(other_w);
    try tmp.dir.createDir(t.io, "nested", .default_dir);
    for (0..4) |index| {
        const name = if (index == 0) try alloc.dupe(u8, "nested/0.LNK") else try std.fmt.allocPrint(alloc, "{d}.lnk", .{index});
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        defer alloc.free(wide);
        {
            const link = try create(&clsid_link, &iid_link);
            defer Identity.release(link);
            try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 20)(link, if (index == 2) other_w else identity.exe));
            if (index == 0) {
                const w = std.unicode.utf8ToUtf16LeStringLiteral;
                const cwd = try std.unicode.utf8ToUtf16LeAllocZ(alloc, root);
                defer alloc.free(cwd);
                try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 11)(link, w("--title=\"Custom pin\" --working-directory=\"C:\\Some Folder\"")));
                try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 9)(link, cwd));
                try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 7)(link, w("Custom legacy pin description")));
                try check(Identity.method(*const fn (*Interface, [*:0]const u16, c_int) callconv(.winapi) HRESULT, link, 17)(link, other_w, 7));
                try check(Identity.method(*const fn (*Interface, c_int) callconv(.winapi) HRESULT, link, 15)(link, 3));
                try check(Identity.method(*const fn (*Interface, u16) callconv(.winapi) HRESULT, link, 13)(link, 0x0647));
            }
            const properties = try Identity.query(link, &iid_property_store);
            defer Identity.release(properties);
            if (index == 1 or index == 3) {
                try setString(properties, &pkey_aumid, if (index == 1) std.unicode.utf8ToUtf16LeStringLiteral("another.application") else identity.aumid);
                try check(Identity.method(*const fn (*Interface) callconv(.winapi) HRESULT, properties, 7)(properties));
            }
            try saveLink(link, wide);
        }
        const before = try tmp.dir.readFileAlloc(t.io, name, alloc, .limited(1024 * 1024));
        defer alloc.free(before);
        const semantics = if (index == 0) try PinSemantics.read(wide) else null;
        if (index == 0) {
            var changed: usize = 0;
            try migratePinDirectory(alloc, t.io, &identity, root, &changed);
            try t.expectEqual(@as(usize, 1), changed);
            try migratePinDirectory(alloc, t.io, &identity, root, &changed);
            try t.expectEqual(@as(usize, 1), changed);
        } else try t.expect(!try migrateShortcut(alloc, &identity, wide));
        const after = try tmp.dir.readFileAlloc(t.io, name, alloc, .limited(1024 * 1024));
        defer alloc.free(after);
        if (index != 0) try t.expectEqualSlices(u8, before, after);
        try t.expect(!try migrateShortcut(alloc, &identity, wide));
        const twice = try tmp.dir.readFileAlloc(t.io, name, alloc, .limited(1024 * 1024));
        defer alloc.free(twice);
        try t.expectEqualSlices(u8, after, twice);
        if (index == 0) {
            const after_semantics = try PinSemantics.read(wide);
            try t.expectEqualDeep(semantics.?, after_semantics);
            try t.expect(semantics.?.text[0][0] != 0);
            try t.expect(semantics.?.text[1][0] != 0);
            try t.expect(semantics.?.text[2][0] != 0);
            try t.expect(semantics.?.text[3][0] != 0);
            try t.expectEqual(@as(c_int, 7), semantics.?.icon_index);
            try t.expectEqual(@as(c_int, 3), semantics.?.show);
            try t.expectEqual(@as(u16, 0x0647), semantics.?.hotkey);
            const link = try loadLink(wide);
            defer Identity.release(link);
            const properties = try Identity.query(link, &iid_property_store);
            defer Identity.release(properties);
            var value: PropertyVariant = .{ .vt = 0, .value = .{ .storage = .{ 0, 0 } } };
            try check(Identity.method(*const fn (*Interface, *const PropertyKey, *PropertyVariant) callconv(.winapi) HRESULT, properties, 5)(properties, &pkey_aumid, &value));
            defer _ = PropVariantClear(&value);
            try t.expectEqual(@as(u16, 31), value.vt);
            try t.expectEqualSlices(u16, identity.aumid, std.mem.span(value.value.string));
        }
    }
}

const PinSemantics = struct {
    text: [4][4096]u16 = @splat(@splat(0)),
    icon_index: c_int = 0,
    show: c_int = 0,
    hotkey: u16 = 0,

    fn read(path: [:0]const u16) !PinSemantics {
        const link = try loadLink(path);
        defer Identity.release(link);
        var result: PinSemantics = .{};
        // IShellLinkW: arguments, working directory, description, icon.
        inline for (.{ 10, 8, 6 }, 0..) |slot, i| {
            try check(Identity.method(*const fn (*Interface, [*]u16, c_int) callconv(.winapi) HRESULT, link, slot)(link, &result.text[i], result.text[i].len));
        }
        try check(Identity.method(*const fn (*Interface, [*]u16, c_int, *c_int) callconv(.winapi) HRESULT, link, 16)(link, &result.text[3], result.text[3].len, &result.icon_index));
        try check(Identity.method(*const fn (*Interface, *c_int) callconv(.winapi) HRESULT, link, 14)(link, &result.show));
        try check(Identity.method(*const fn (*Interface, *u16) callconv(.winapi) HRESULT, link, 12)(link, &result.hotkey));
        return result;
    }
};

// Only used with paths inside the test's own temporary tree. Junctions do not
// require the symbolic-link privilege or any change to host settings.
fn testJunction(path: [:0]const u16, target: []const u16) !void {
    const w = std.os.windows;
    const Api = struct {
        extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
        extern "kernel32" fn DeviceIoControl(w.HANDLE, u32, ?*const anyopaque, u32, ?*anyopaque, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
    };
    const handle = Api.CreateFileW(path, 0x40000000, 7, null, 3, 0x02200000, null);
    if (handle == w.INVALID_HANDLE_VALUE) return error.JunctionOpenFailed;
    defer w.CloseHandle(handle);
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    const substitute = try std.mem.concat(std.testing.allocator, u16, &.{ prefix, target });
    defer std.testing.allocator.free(substitute);
    // REPARSE_DATA_BUFFER mount-point header, followed by two terminated names.
    var data: [16384]u8 align(4) = @splat(0);
    const bytes = (substitute.len + 1 + target.len + 1) * 2;
    try std.testing.expect(16 + bytes <= data.len);
    std.mem.writeInt(u32, data[0..4], 0xa0000003, .little);
    std.mem.writeInt(u16, data[4..6], @intCast(8 + bytes), .little);
    std.mem.writeInt(u16, data[10..12], @intCast(substitute.len * 2), .little);
    std.mem.writeInt(u16, data[12..14], @intCast((substitute.len + 1) * 2), .little);
    std.mem.writeInt(u16, data[14..16], @intCast(target.len * 2), .little);
    @memcpy(data[16..][0 .. substitute.len * 2], std.mem.sliceAsBytes(substitute));
    @memcpy(data[16 + (substitute.len + 1) * 2 ..][0 .. target.len * 2], std.mem.sliceAsBytes(target));
    var returned: u32 = 0;
    if (Api.DeviceIoControl(handle, 0x000900a4, &data, @intCast(16 + bytes), null, 0, &returned, null) == 0) return error.JunctionCreateFailed;
}

fn testPinLinks(comptime junction: bool) !void {
    const t = std.testing;
    const alloc = t.allocator;
    const initialized = CoInitializeEx(null, 2);
    if (initialized != @as(i32, @bitCast(@as(u32, 0x80010106)))) try check(initialized);
    defer if (initialized >= 0) CoUninitialize();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", alloc);
    defer alloc.free(root);
    const file = try tmp.dir.createFile(t.io, "ghostty.exe", .{});
    file.close(t.io);
    const exe = try std.fs.path.join(alloc, &.{ root, "ghostty.exe" });
    defer alloc.free(exe);
    var identity = try Identity.init(alloc, .installed, exe, true);
    defer identity.deinit();
    for ([_][]const u8{ "target", "scan" }) |name| try tmp.dir.createDir(t.io, name, .default_dir);
    for ([_][]const u8{ "target/pin.lnk", "scan/normal.lnk" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        defer alloc.free(wide);
        const link = try create(&clsid_link, &iid_link);
        defer Identity.release(link);
        try check(Identity.method(*const fn (*Interface, [*:0]const u16) callconv(.winapi) HRESULT, link, 20)(link, identity.exe));
        try saveLink(link, wide);
    }
    const target = try std.fs.path.join(alloc, &.{ root, "target" });
    defer alloc.free(target);
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target);
    defer alloc.free(target_w);
    for ([_][]const u8{ "root-link", "scan/child-link" }) |name| {
        if (junction) {
            try tmp.dir.createDir(t.io, name, .default_dir);
            const path = try std.fs.path.join(alloc, &.{ root, name });
            defer alloc.free(path);
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
            defer alloc.free(wide);
            try testJunction(wide, target_w);
        } else try tmp.dir.symLink(t.io, target, name, .{ .is_directory = true });
    }
    if (!junction) {
        const target_pin = try std.fs.path.join(alloc, &.{ target, "pin.lnk" });
        defer alloc.free(target_pin);
        try tmp.dir.symLink(t.io, target_pin, "scan/alias.lnk", .{});
    }
    const before = try tmp.dir.readFileAlloc(t.io, "target/pin.lnk", alloc, .limited(1024 * 1024));
    defer alloc.free(before);
    const linked_root = try std.fs.path.join(alloc, &.{ root, "root-link" });
    defer alloc.free(linked_root);
    const scan = try std.fs.path.join(alloc, &.{ root, "scan" });
    defer alloc.free(scan);
    var changed: usize = 0;
    try migratePinDirectory(alloc, t.io, &identity, linked_root, &changed);
    try t.expectEqual(@as(usize, 0), changed);
    try migratePinDirectory(alloc, t.io, &identity, scan, &changed);
    try t.expectEqual(@as(usize, 1), changed);
    const after = try tmp.dir.readFileAlloc(t.io, "target/pin.lnk", alloc, .limited(1024 * 1024));
    defer alloc.free(after);
    try t.expectEqualSlices(u8, before, after);
    const normal = try tmp.dir.readFileAlloc(t.io, "scan/normal.lnk", alloc, .limited(1024 * 1024));
    defer alloc.free(normal);
    try migratePinDirectory(alloc, t.io, &identity, linked_root, &changed);
    try migratePinDirectory(alloc, t.io, &identity, scan, &changed);
    try t.expectEqual(@as(usize, 1), changed);
    const twice = try tmp.dir.readFileAlloc(t.io, "scan/normal.lnk", alloc, .limited(1024 * 1024));
    defer alloc.free(twice);
    try t.expectEqualSlices(u8, normal, twice);
    const target_twice = try tmp.dir.readFileAlloc(t.io, "target/pin.lnk", alloc, .limited(1024 * 1024));
    defer alloc.free(target_twice);
    try t.expectEqualSlices(u8, before, target_twice);
}

test "apprt.win32.shell.D28 root and child junctions leave target pins untouched" {
    try testPinLinks(true);
}

test "apprt.win32.shell.D28 root directory symlink child directory and lnk symlinks leave target pins untouched" {
    // PermissionDenied remains a real environment failure, never a silent skip.
    try testPinLinks(false);
}

extern "shell32" fn SHGetKnownFolderPath(*const GUID, u32, ?std.os.windows.HANDLE, *?[*:0]u16) callconv(.winapi) HRESULT;
extern "shell32" fn SHChangeNotify(i32, u32, ?*const anyopaque, ?*const anyopaque) callconv(.winapi) void;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
const migration_log = std.log.scoped(.win32_shell);

/// Runs only on the existing shell worker, using its owned identity snapshot.
/// Every COM object stays on that thread. No registration or pin is created.
pub fn migratePinned(alloc: std.mem.Allocator, io: std.Io, identity: *const Identity) !void {
    if (identity.mode != .installed or !identity.registration_verified or
        !std.mem.eql(u8, identity.aumid_utf8, Identity.installed_aumid)) return;
    try check(CoInitializeEx(null, 0));
    defer CoUninitialize();
    var roaming: ?[*:0]u16 = null;
    const folder = Identity.guid("3eb685db-65f9-4cf6-a03a-e3ef65729f3d");
    try check(SHGetKnownFolderPath(&folder, 0, null, &roaming));
    defer CoTaskMemFree(@ptrCast(roaming));
    const base = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(roaming orelse return error.ShellUnavailable));
    defer alloc.free(base);
    var changed: usize = 0;
    // SHCNE_ASSOCCHANGED, SHCNF_IDLIST: let Explorer refresh cached grouping.
    defer if (changed != 0) SHChangeNotify(0x08000000, 0, null, null);
    for ([_][]const u8{ "TaskBar", "StartMenu", "ImplicitAppShortcuts" }) |name| {
        const root = try std.fs.path.join(alloc, &.{ base, "Microsoft", "Internet Explorer", "Quick Launch", "User Pinned", name });
        defer alloc.free(root);
        migratePinDirectory(alloc, io, identity, root, &changed) catch |err| {
            migration_log.warn("Pinned shortcut scan failed ({s}): {}", .{ name, err });
        };
    }
}

fn migratePinDirectory(alloc: std.mem.Allocator, io: std.Io, identity: *const Identity, root: []const u8, changed: *usize) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);
    // Inspect the opened root itself before enumeration. Entry-kind filtering
    // below only protects children, not a root that is a junction or symlink.
    const w = std.os.windows;
    var status: w.IO_STATUS_BLOCK = undefined;
    var attributes: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
    if (w.ntdll.NtQueryInformationFile(dir.handle, &status, &attributes, @sizeOf(w.FILE.ATTRIBUTE_TAG_INFO), .AttributeTag) != .SUCCESS)
        return error.PinnedRootInspectionFailed;
    if (attributes.FileAttributes & 0x400 != 0) return; // FILE_ATTRIBUTE_REPARSE_POINT
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    // Drain the walker even after individual failures, so one damaged pin or
    // unreadable subdirectory cannot prevent migration of its siblings.
    while (true) {
        const entry = (walker.next(io) catch |err| {
            migration_log.warn("Pinned shortcut enumeration failed: {}", .{err});
            continue;
        }) orelse break;
        if (entry.kind == .directory) {
            walker.enter(io, entry) catch |err| {
                migration_log.warn("Pinned shortcut subdirectory failed: {}", .{err});
            };
            continue;
        }
        if (entry.kind != .file or !std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.basename), ".lnk")) continue;
        const path = try std.fs.path.join(alloc, &.{ root, entry.path });
        defer alloc.free(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        defer alloc.free(wide);
        if (migrateShortcut(alloc, identity, wide) catch |err| {
            migration_log.warn("Pinned shortcut migration failed ({s}): {}", .{ entry.path, err });
            continue;
        }) changed.* += 1;
    }
}
