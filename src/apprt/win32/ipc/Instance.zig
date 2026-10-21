//! Election occurs before any Surface or global hotkey is created. The primary
//! reserves the FIRST_PIPE_INSTANCE handle, then starts serving once GUI-ready.
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
pub const Server = @import("Server.zig");
pub const Endpoint = @import("wire.zig").Endpoint;
pub const Election = union(enum) { primary: *Server, secondary: Endpoint };

pub fn elect(allocator: std.mem.Allocator, isolation: security.policy.Isolation, epoch: u128) !Election {
    if (epoch == 0) return error.InvalidEpoch;
    const local = try security.inspect(n.GetCurrentProcessId());
    defer local.deinit();
    const endpoint = try Endpoint.init(isolation, local.identity);
    const descriptor = try security.Descriptor.init();
    defer descriptor.deinit();
    var attributes = descriptor.attributes();
    const pipe = n.CreateNamedPipeW(&endpoint.name, 0x40080003, 14, 1, 4096, 4096, 1000, &attributes);
    if (pipe == n.INVALID) {
        // A squatter can cause denial, but cannot be accepted without the
        // client's independent process/token/image authentication.
        if (n.GetLastError() == 5 or n.GetLastError() == 231) return .{ .secondary = endpoint };
        return error.CreatePipeFailed;
    }
    errdefer _ = n.CloseHandle(pipe);
    return .{ .primary = try Server.create(allocator, endpoint, epoch, pipe) };
}

pub const freshEpoch = n.epoch;

test "apprt.win32.ipc.Instance native election delivery and replay ACK" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const w32 = @import("../win32.zig");
    const Client = @import("Client.zig");
    const host_epoch = try freshEpoch();
    var isolation: security.policy.Isolation = .{ .config_root = @splat(0), .build = @splat(2), .class = @splat(3), .install = @splat(4) };
    std.mem.writeInt(u128, isolation.config_root[0..16], host_epoch, .little);
    const election = try elect(std.testing.allocator, isolation, host_epoch);
    try std.testing.expect(election == .primary);
    const server = election.primary;
    defer server.destroy();
    const secondary = try elect(std.testing.allocator, isolation, try freshEpoch());
    try std.testing.expect(secondary == .secondary);
    const hwnd = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("GX IPC test"), 0, 0, 0, 0, 0, @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))), null, null, null) orelse return error.TestWindowFailed;
    defer _ = w32.DestroyWindow(hwnd);
    try server.start(hwnd, 0x8063);
    const Probe = struct {
        attempt: Client.Attempt,
        done: std.atomic.Value(bool) = .init(false),
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            for (0..2) |_| {
                const outcome = self.attempt.send(.toggle_quick_terminal) catch |err| {
                    self.result = err;
                    return;
                };
                if (outcome != .completed) {
                    self.result = error.UnexpectedOutcome;
                    return;
                }
            }
        }
    };
    var probe: Probe = .{ .attempt = .{ .endpoint = secondary.secondary, .sender_epoch = try freshEpoch(), .request_id = 1 } };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    defer thread.join();
    const deadline = n.Deadline.init(25000);
    var executions: usize = 0;
    while (!probe.done.load(.acquire) and deadline.remaining() != 0) {
        if (server.take()) |work| {
            executions += 1;
            try server.finish(work.key, .completed);
        }
        _ = n.WaitForSingleObject(server.stop, 1);
    }
    if (!probe.done.load(.acquire)) {
        server.shutdown();
        return error.TestTimeout;
    }
    if (probe.result) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), executions);
}
