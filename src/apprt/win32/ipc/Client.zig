//! Bounded native client. A lost ACK is an unknown result, never permission to
//! start another local action. Retain Attempt to retry the SAME request key.
const std = @import("std");
const n = @import("native.zig");
const security = @import("Security.zig");
const wire = @import("wire.zig");
const protocol = wire.protocol;
pub const Endpoint = wire.Endpoint;

pub const Attempt = struct {
    endpoint: Endpoint,
    sender_epoch: u128,
    request_id: u64,
    host_epoch: ?u128 = null,

    pub fn send(self: *Attempt, request_value: protocol.Request) !protocol.Outcome {
        if (self.sender_epoch == 0 or self.request_id == 0) return error.InvalidIdentity;
        const deadline = n.Deadline.init(10000);
        const pipe = try open(&self.endpoint, deadline);
        defer _ = n.CloseHandle(pipe);
        const local = try security.inspect(n.GetCurrentProcessId());
        defer local.deinit();
        const peer = try security.pipePeer(pipe, false);
        defer peer.deinit();
        var hello: [wire.hello_size]u8 = undefined;
        if ((try n.readMessage(pipe, &hello, null, deadline)).len != hello.len) return error.InvalidHandshake;
        const host_epoch = try wire.verifyHello(&hello, local, peer, self.endpoint.isolation);
        if (self.host_epoch) |bound| {
            if (bound != host_epoch) return error.HostRestarted;
        } else self.host_epoch = host_epoch;
        wire.hello(&hello, self.sender_epoch, local.identity, self.endpoint.isolation);
        try n.write(pipe, &hello, null, deadline);
        // Only the authenticated host receives foreground permission.
        _ = n.AllowSetForegroundWindow(peer.identity.process.pid);
        const key: protocol.Key = .{ .sender_epoch = self.sender_epoch, .host_epoch = host_epoch, .request_id = self.request_id };
        var buffer: [protocol.max_frame_size]u8 = undefined;
        const bytes = try protocol.encode(&buffer, .{ .key = key, .message = .{ .request = request_value } });
        if (n.WaitForSingleObject(peer.process, 0) != 258) return error.ProcessExited;
        n.write(pipe, bytes, null, deadline) catch return error.ResultUnknown;
        const reply = wire.readFrame(pipe, &buffer, null, deadline) catch return error.ResultUnknown;
        if (!std.meta.eql(reply.key, key) or reply.message != .acknowledgement) return error.InvalidAcknowledgement;
        // Receipt failure does not undo an already verified execution result.
        n.write(pipe, &.{1}, null, deadline) catch {};
        return reply.message.acknowledgement;
    }
};

pub fn request(endpoint: Endpoint, sender_epoch: u128, request_id: u64, request_value: protocol.Request) !protocol.Outcome {
    var attempt: Attempt = .{ .endpoint = endpoint, .sender_epoch = sender_epoch, .request_id = request_id };
    return attempt.send(request_value);
}

fn open(endpoint: *const Endpoint, deadline: n.Deadline) !n.HANDLE {
    const pause = try n.event();
    defer _ = n.CloseHandle(pause);
    while (deadline.remaining() != 0) {
        // SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: no impersonation
        // token with delegation privileges is offered to an endpoint squatter.
        const pipe = n.CreateFileW(&endpoint.name, 0xc0000000, 0, null, 3, 0x40110000, null);
        if (pipe != n.INVALID) {
            const mode: u32 = 2; // PIPE_READMODE_MESSAGE
            if (n.SetNamedPipeHandleState(pipe, &mode, null, null) == 0) {
                _ = n.CloseHandle(pipe);
                return error.PipeModeFailed;
            }
            return pipe;
        }
        switch (n.GetLastError()) {
            2, 231 => {
                _ = n.WaitNamedPipeW(&endpoint.name, @min(deadline.remaining(), 100));
                _ = n.WaitForSingleObject(pause, @min(deadline.remaining(), 10));
            },
            else => return error.OpenPipeFailed,
        }
    }
    return error.Timeout;
}
