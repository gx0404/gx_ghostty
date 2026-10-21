//! Sole source of Windows shell identity. These are NOT Inno Setup's AppId.
//! The packaging owner exports these values to shortcut/COM registration.
//! Identity selection and process grouping never install registry entries.
const Identity = @This();
const std = @import("std");
pub const GUID = std.os.windows.GUID;
pub const HRESULT = i32;
pub const installed_aumid = "gx0404.GhosttyGX";
pub const installed_activator = "978ab84b-3cac-4593-95d5-2e04d68eed4f";
pub const action_switch = "--gx-shell-action=";
pub const profile_switch = "--gx-shell-profile=";
pub const server_argument = "--gx-shell-action=toast-server";
pub const profile_argument = "--gx-shell-action=profile";
pub const Mode = enum { installed, portable };

arena: std.heap.ArenaAllocator,
mode: Mode,
exe_utf8: []const u8,
exe: [:0]const u16,
aumid_utf8: []const u8,
aumid: [:0]const u16,
activator: GUID,
registration_verified: bool,

/// canonical_exe must come from the executable's resolved native path. The
/// caller verifies package-owned shortcut/CLSID registration before passing true.
pub fn init(alloc: std.mem.Allocator, mode: Mode, canonical_exe: []const u8, registration_verified: bool) !Identity {
    if (!std.fs.path.isAbsoluteWindows(canonical_exe) or std.mem.indexOfScalar(u8, canonical_exe, 0) != null or !std.unicode.utf8ValidateSlice(canonical_exe)) return error.InvalidExecutable;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const normalized = try owned.dupe(u8, canonical_exe);
    for (normalized) |*byte| byte.* = if (byte.* == '\\') '/' else std.ascii.toLower(byte.*);
    var path_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized, &path_hash, .{});
    const name = switch (mode) {
        .installed => installed_aumid,
        .portable => try owned.print("{s}.Portable.{s}", .{ installed_aumid, std.fmt.bytesToHex(path_hash[0..16], .lower) }),
    };
    var activator = guid(installed_activator);
    if (mode == .portable) {
        path_hash[6] = (path_hash[6] & 0x0f) | 0x50;
        path_hash[8] = (path_hash[8] & 0x3f) | 0x80;
        activator = .{ .Data1 = std.mem.readInt(u32, path_hash[0..4], .big), .Data2 = std.mem.readInt(u16, path_hash[4..6], .big), .Data3 = std.mem.readInt(u16, path_hash[6..8], .big), .Data4 = path_hash[8..16].* };
    }
    const exe_utf8 = try owned.dupe(u8, canonical_exe);
    const exe = try std.unicode.utf8ToUtf16LeAllocZ(owned, canonical_exe);
    const aumid_utf8 = try owned.dupe(u8, name);
    const aumid = try std.unicode.utf8ToUtf16LeAllocZ(owned, name);
    return .{ .arena = arena, .mode = mode, .exe_utf8 = exe_utf8, .exe = exe, .aumid_utf8 = aumid_utf8, .aumid = aumid, .activator = activator, .registration_verified = registration_verified };
}

/// Read the effective shell registration without writing registry or shortcuts.
/// A copied portable executable cannot inherit another installation's identity.
pub fn detect(alloc: std.mem.Allocator, canonical_exe: []const u8) !Identity {
    const verified = verifyRegistration(alloc, canonical_exe) catch false;
    return init(alloc, if (verified) .installed else .portable, canonical_exe, verified);
}

const aumid_key = "AppUserModelId\\" ++ installed_aumid;
const server_key = "CLSID\\{" ++ installed_activator ++ "}\\LocalServer32";
fn verifyRegistration(alloc: std.mem.Allocator, exe: []const u8) !bool {
    const activator = try registrationString(alloc, aumid_key, "CustomActivator");
    defer alloc.free(activator);
    const registered_exe = try registrationString(alloc, aumid_key, "GxExecutable");
    defer alloc.free(registered_exe);
    const command = try registrationString(alloc, server_key, "");
    defer alloc.free(command);
    const expected = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe);
    defer alloc.free(expected);
    return registrationMatches(alloc, expected, activator, registered_exe, command);
}

fn registrationString(alloc: std.mem.Allocator, comptime key: []const u8, comptime value: []const u8) ![:0]u16 {
    const data = try alloc.alloc(u16, 32768);
    defer alloc.free(data);
    var bytes: u32 = @intCast(data.len * 2);
    const hkcr: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2147483648))));
    // REG_SZ only, no expansion, effective merged user/machine classes view.
    if (RegGetValueW(hkcr, std.unicode.utf8ToUtf16LeStringLiteral(key), std.unicode.utf8ToUtf16LeStringLiteral(value), 0x10000002, null, data.ptr, &bytes) != 0) return error.MissingRegistration;
    if (bytes < 2 or bytes % 2 != 0 or bytes > data.len * 2) return error.InvalidRegistration;
    const text = data[0 .. bytes / 2 - 1];
    if (data[bytes / 2 - 1] != 0 or std.mem.indexOfScalar(u16, text, 0) != null) return error.InvalidRegistration;
    return alloc.dupeSentinel(u16, text, 0);
}

fn registrationMatches(alloc: std.mem.Allocator, exe: [:0]const u16, activator: []const u16, registered_exe: [:0]const u16, command: [:0]const u16) !bool {
    if (!wideEqual(activator, std.unicode.utf8ToUtf16LeStringLiteral("{" ++ installed_activator ++ "}"))) return false;
    var count: c_int = 0;
    const args = CommandLineToArgvW(command, &count) orelse return false;
    defer _ = LocalFree(@ptrCast(args));
    if (count != 2 or !std.mem.eql(u16, std.mem.span(args[1]), std.unicode.utf8ToUtf16LeStringLiteral(server_argument))) return false;
    // Resolve all three paths through native handles, including reparse points
    // and short names. Merely sharing a basename or textual prefix is insufficient.
    const actual = try finalPath(alloc, exe);
    defer alloc.free(actual);
    const owned = try finalPath(alloc, registered_exe);
    defer alloc.free(owned);
    const server = try finalPath(alloc, args[0]);
    defer alloc.free(server);
    return wideEqual(actual, owned) and wideEqual(actual, server);
}
pub fn finalPath(alloc: std.mem.Allocator, path: [*:0]const u16) ![]u16 {
    const text = std.mem.span(path);
    const slash = struct {
        fn is(c: u16) bool {
            return c == '\\' or c == '/';
        }
    }.is;
    const absolute = (text.len >= 3 and ((text[0] >= 'a' and text[0] <= 'z') or (text[0] >= 'A' and text[0] <= 'Z')) and text[1] == ':' and slash(text[2])) or (text.len >= 2 and slash(text[0]) and slash(text[1]));
    if (!absolute) return error.InvalidExecutable;
    // Attribute-only read, with no filesystem mutation and all sharing enabled.
    const file = CreateFileW(path, 0, 7, null, 3, 0, null);
    if (file == std.os.windows.INVALID_HANDLE_VALUE) return error.InvalidExecutable;
    defer _ = CloseHandle(file);
    const data = try alloc.alloc(u16, 32768);
    errdefer alloc.free(data);
    const count = GetFinalPathNameByHandleW(file, data.ptr, @intCast(data.len), 0);
    if (count == 0 or count >= data.len) return error.InvalidExecutable;
    const result = try alloc.dupe(u16, data[0..count]);
    alloc.free(data);
    return result;
}
pub fn wideEqual(a: []const u16, b: []const u16) bool {
    return CompareStringOrdinal(a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), 1) == 2;
}
extern "advapi32" fn RegGetValueW(*anyopaque, [*:0]const u16, [*:0]const u16, u32, ?*u32, ?*anyopaque, *u32) callconv(.winapi) i32;
extern "shell32" fn CommandLineToArgvW([*:0]const u16, *c_int) callconv(.winapi) ?[*][*:0]u16;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn CloseHandle(std.os.windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(std.os.windows.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn CompareStringOrdinal([*]const u16, c_int, [*]const u16, c_int, i32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]u16, u32) callconv(.winapi) u32;
pub fn clone(self: *const Identity, alloc: std.mem.Allocator) !Identity {
    return init(alloc, self.mode, self.exe_utf8, self.registration_verified);
}
pub fn deinit(self: *Identity) void {
    self.arena.deinit();
    self.* = undefined;
}
pub fn applyProcess(self: *const Identity) !void {
    if (SetCurrentProcessExplicitAppUserModelID(self.aumid) < 0) return error.IdentityUnavailable;
}
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID([*:0]const u16) callconv(.winapi) HRESULT;

/// Consumed only from real process argv, never from Config fields/files. The
/// main entrypoint must handle this before creating a default terminal.
pub const Startup = union(enum) { none, profile: []const u8, toast_server, drop_companion: @import("../../../gx/ipc/policy.zig").Process };
pub fn parseStartup(args: []const []const u8) !Startup {
    var action: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var drop_pid: ?u32 = null;
    var drop_birth: ?u64 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-e")) {
            if (action != null or profile != null or drop_pid != null or drop_birth != null) return error.ConflictingLaunch;
            break;
        }
        if (std.mem.cutPrefix(u8, arg, action_switch)) |value| {
            if (action != null) return error.InvalidActivation;
            action = value;
        }
        if (std.mem.cutPrefix(u8, arg, profile_switch)) |value| {
            if (profile != null) return error.InvalidActivation;
            try validateProfile(value);
            profile = value;
        }
        if (std.mem.cutPrefix(u8, arg, "--gx-drop-target-pid=")) |value| {
            if (drop_pid != null) return error.InvalidActivation;
            drop_pid = try decimalIdentity(u32, value);
        }
        if (std.mem.cutPrefix(u8, arg, "--gx-drop-target-birth=")) |value| {
            if (drop_birth != null) return error.InvalidActivation;
            drop_birth = try decimalIdentity(u64, value);
        }
    }
    const value = action orelse {
        if (profile != null or drop_pid != null or drop_birth != null) return error.InvalidActivation;
        return .none;
    };
    if (std.mem.eql(u8, value, "drop-companion")) {
        if (profile != null) return error.InvalidActivation;
        return .{ .drop_companion = .{ .pid = drop_pid orelse return error.InvalidActivation, .birth = drop_birth orelse return error.InvalidActivation } };
    }
    if (drop_pid != null or drop_birth != null) return error.InvalidActivation;
    if (std.mem.eql(u8, value, "toast-server") and profile == null) return .toast_server;
    if (std.mem.eql(u8, value, "profile")) return .{ .profile = profile orelse return error.InvalidActivation };
    return error.InvalidActivation;
}
fn decimalIdentity(comptime T: type, text: []const u8) !T {
    if (text.len == 0 or text.len > 20) return error.InvalidActivation;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidActivation;
    const number = std.fmt.parseInt(T, text, 10) catch return error.InvalidActivation;
    if (number == 0) return error.InvalidActivation;
    return number;
}

test "drop companion startup binds a complete process identity and never consumes child flags" {
    const testing = std.testing;
    const args = [_][]const u8{ "--gx-shell-action=drop-companion", "--gx-drop-target-pid=123", "--gx-drop-target-birth=456" };
    const parsed = try parseStartup(&args);
    try testing.expectEqual(@as(u32, 123), parsed.drop_companion.pid);
    try testing.expectEqual(@as(u64, 456), parsed.drop_companion.birth);
    try testing.expectError(error.InvalidActivation, parseStartup(args[0..2]));
    try testing.expectError(error.InvalidActivation, parseStartup(&.{ "--gx-drop-target-pid=123", "--gx-drop-target-birth=456" }));
    try testing.expectError(error.InvalidActivation, parseStartup(&.{ "--gx-shell-action=toast-server", "--gx-drop-target-pid=123" }));
    try testing.expectError(error.InvalidActivation, parseStartup(&.{ "--gx-shell-action=drop-companion", "--gx-drop-target-pid=0", "--gx-drop-target-birth=456" }));
    try testing.expect((try parseStartup(&.{ "-e", "--gx-shell-action=drop-companion", "--gx-drop-target-pid=123" })) == .none);
}
pub fn validateProfile(id: []const u8) !void {
    if (id.len == 0 or id.len > 1024 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidProfile;
    for (id) |byte| if (byte < 32 or byte == 127) return error.InvalidProfile;
}

/// Straight C ABI helpers shared by the three shell modules, verified against
/// Windows SDK 10.0.26100.0 headers. No interface implicitly initializes COM.
pub const Interface = extern struct { vtable: [*]const *const anyopaque };
pub fn method(comptime F: type, object: *Interface, comptime slot: usize) F {
    return @ptrCast(object.vtable[slot]);
}
pub fn release(object: *Interface) void {
    _ = method(*const fn (*Interface) callconv(.winapi) u32, object, 2)(object);
}
pub fn query(object: *Interface, iid: *const GUID) !*Interface {
    var out: ?*Interface = null;
    if (method(*const fn (*Interface, *const GUID, *?*Interface) callconv(.winapi) HRESULT, object, 0)(object, iid, &out) < 0) return error.InterfaceUnavailable;
    return out orelse return error.InterfaceUnavailable;
}
pub fn guid(comptime value: []const u8) GUID {
    @setEvalBranchQuota(5000);
    return .{ .Data1 = std.fmt.parseInt(u32, value[0..8], 16) catch unreachable, .Data2 = std.fmt.parseInt(u16, value[9..13], 16) catch unreachable, .Data3 = std.fmt.parseInt(u16, value[14..18], 16) catch unreachable, .Data4 = .{
        std.fmt.parseInt(u8, value[19..21], 16) catch unreachable, std.fmt.parseInt(u8, value[21..23], 16) catch unreachable,
        std.fmt.parseInt(u8, value[24..26], 16) catch unreachable, std.fmt.parseInt(u8, value[26..28], 16) catch unreachable,
        std.fmt.parseInt(u8, value[28..30], 16) catch unreachable, std.fmt.parseInt(u8, value[30..32], 16) catch unreachable,
        std.fmt.parseInt(u8, value[32..34], 16) catch unreachable, std.fmt.parseInt(u8, value[34..36], 16) catch unreachable,
    } };
}
pub fn sameGuid(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}
pub const iid_unknown = guid("00000000-0000-0000-c000-000000000046");
pub const iid_agile = guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");

/// Dynamic registration manifest value for portable VM fixtures; production
/// installation uses the stable exported manifest below.
pub fn activatorText(self: *const Identity, buffer: *[36]u8) []const u8 {
    const value = self.activator;
    return std.mem.print(buffer, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        value.Data1, value.Data2, value.Data3, value.Data4[0], value.Data4[1], value.Data4[2], value.Data4[3], value.Data4[4], value.Data4[5], value.Data4[6], value.Data4[7],
    }) catch unreachable;
}

pub const manifest = .{ .aumid = installed_aumid, .activator_clsid = installed_activator, .local_server_argument = server_argument, .profile_action_argument = profile_argument, .profile_id_prefix = profile_switch };

test "installed identity is stable while portable identities are path isolated and unregistered" {
    const testing = std.testing;
    var one = try init(testing.allocator, .portable, "C:\\One\\ghostty.exe", false);
    defer one.deinit();
    var same = try init(testing.allocator, .portable, "c:/one/ghostty.exe", false);
    defer same.deinit();
    var two = try init(testing.allocator, .portable, "C:\\Two\\ghostty.exe", false);
    defer two.deinit();
    try testing.expectEqualStrings(one.aumid_utf8, same.aumid_utf8);
    try testing.expect(!std.mem.eql(u8, one.aumid_utf8, two.aumid_utf8));
    try testing.expect(!sameGuid(&one.activator, &two.activator));
    try testing.expect(!one.registration_verified);
    var installed = try init(testing.allocator, .installed, "C:\\Installed\\ghostty.exe", true);
    defer installed.deinit();
    try testing.expectEqualStrings(installed_aumid, installed.aumid_utf8);
}
test "internal shell startup comes only from exact argv before child command" {
    const testing = std.testing;
    try testing.expect((try parseStartup(&.{ "-e", server_argument })) == .none);
    try testing.expect((try parseStartup(&.{server_argument})) == .toast_server);
    try testing.expectError(error.InvalidActivation, parseStartup(&.{profile_argument}));
    try testing.expectError(error.ConflictingLaunch, parseStartup(&.{ server_argument, "-e", "cmd" }));
    try testing.expectEqualStrings("custom:A B", (try parseStartup(&.{ profile_argument, "--gx-shell-profile=custom:A B" })).profile);
}

test "registration rejects foreign activator and extra server arguments without host registration" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(!try registrationMatches(std.testing.allocator, wide("C:\\gx\\ghostty.exe"), wide("{foreign}"), wide("C:\\gx\\ghostty.exe"), wide("unused")));
    try std.testing.expect(!try registrationMatches(std.testing.allocator, wide("C:\\gx\\ghostty.exe"), wide("{" ++ installed_activator ++ "}"), wide("C:\\gx\\ghostty.exe"), wide("\"C:\\gx\\ghostty.exe\" --gx-shell-action=toast-server --extra")));
    try std.testing.expect(@intFromPtr(&detect) != 0);
}

test "registration fixture matches the real executable through native handles without registry writes" {
    const alloc = std.testing.allocator;
    var path: [32768]u16 = undefined;
    const count = GetModuleFileNameW(null, &path, path.len);
    try std.testing.expect(count > 0 and count < path.len);
    const exe = path[0..count :0];
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, exe);
    defer alloc.free(utf8);
    const command = try @import("../../../gx/windows_argv.zig").encode(alloc, &.{ utf8, server_argument });
    defer alloc.free(command);
    try std.testing.expect(try registrationMatches(alloc, exe, std.unicode.utf8ToUtf16LeStringLiteral("{" ++ installed_activator ++ "}"), exe, command));
    try std.testing.expectError(error.InvalidExecutable, finalPath(alloc, std.unicode.utf8ToUtf16LeStringLiteral("ghostty.exe")));
}
