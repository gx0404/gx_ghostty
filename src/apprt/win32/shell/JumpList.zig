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
        if (!identity.registration_verified) return error.UnregisteredIdentity;
        if (self.applied) |previous| if (std.mem.eql(u8, &previous, &snapshot.fingerprint)) return false;
        var native = try Native.init(identity, snapshot);
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
    var identity = try Identity.init(t.allocator, .portable, "C:/My App/ghostty.exe", false);
    defer identity.deinit();
    identity.registration_verified = true;
    var snapshot = try Snapshot.init(t.allocator, &identity, &.{.{ .id = "custom:Test", .title = "Test" }});
    defer snapshot.deinit();
    var publisher: Publisher = .{ .applied = snapshot.fingerprint };
    // The duplicate path returns before creating COM objects or writing Shell.
    try t.expect(!try publisher.publish(&identity, &snapshot));
    try t.expectEqual(snapshot.fingerprint, publisher.applied.?);
}
