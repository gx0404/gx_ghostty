//! Owned admission, replay protection and GUI completion for authenticated IPC.
//! This type is NOT internally synchronized: native workers and GUI must call
//! every method under one external lock. Never hold that lock while running GUI
//! actions or writing a pipe. Only the GUI calls take/finish; worker submission
//! merely queues bytes and cannot generate a success acknowledgement.
const std = @import("std");
const protocol = @import("protocol.zig");
const policy = @import("policy.zig");

pub const Error = error{
    InvalidEpoch,
    InvalidMessage,
    NotReady,
    ShuttingDown,
    Full,
    Exhausted,
    RequestConflict,
    UnknownRequest,
    NotExecuting,
    PeerBusy,
};
pub const Phase = enum { starting, ready, stopping };
pub const State = enum { queued, executing, completed };
pub const Admission = union(enum) {
    accepted,
    pending: State,
    completed: protocol.Outcome,
};

/// The request text borrows the queue's owned frame until finish. shutdown does
/// not invalidate executing work. Do not retain this value after finish, and do
/// not deinit the queue until every executing GUI action has returned.
pub const Work = struct { key: protocol.Key, request: protocol.Request };

pub const Queue = BoundedQueue(64);

pub fn BoundedQueue(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 4096) @compileError("IPC queue capacity must be 1..4096");
    return struct {
        const Self = @This();
        const Entry = struct {
            key: protocol.Key,
            bytes: []u8,
            order: u64,
            state: State = .queued,
            outcome: ?protocol.Outcome = null,
        };

        allocator: std.mem.Allocator,
        host_epoch: u128,
        phase: Phase = .starting,
        serial: u64 = 0,
        entries: [capacity]?Entry = @splat(null),

        pub fn init(allocator: std.mem.Allocator, host_epoch: u128) Error!Self {
            if (host_epoch == 0) return error.InvalidEpoch;
            return .{ .allocator = allocator, .host_epoch = host_epoch };
        }

        pub fn deinit(self: *Self) void {
            for (&self.entries) |*slot| if (slot.*) |entry| {
                std.debug.assert(entry.state != .executing);
                self.allocator.free(entry.bytes);
                slot.* = null;
            };
            self.phase = .stopping;
        }

        pub fn setReady(self: *Self) Error!void {
            if (self.phase == .stopping) return error.ShuttingDown;
            self.phase = .ready;
        }

        /// bound_sender comes from the verified connection binding, never the
        /// received frame. A retry must carry identical bytes for the same key.
        /// Memory and replay entries are bounded, including completed requests.
        pub fn submit(self: *Self, bound_sender: u128, frame: protocol.Frame) !Admission {
            try policy.checkEpochs(bound_sender, self.host_epoch, frame.key.sender_epoch, frame.key.host_epoch);
            if (frame.message != .request) return error.InvalidMessage;
            var buffer: [protocol.max_frame_size]u8 = undefined;
            const bytes = try protocol.encode(&buffer, frame);
            if (self.find(frame.key)) |entry| {
                if (!std.mem.eql(u8, bytes, entry.bytes)) return error.RequestConflict;
                return if (entry.outcome) |outcome|
                    .{ .completed = outcome }
                else
                    .{ .pending = entry.state };
            }
            switch (self.phase) {
                .starting => return error.NotReady,
                .stopping => return error.ShuttingDown,
                .ready => {},
            }
            const slot = for (&self.entries) |*entry| {
                if (entry.* == null) break entry;
            } else return error.Full;
            const order = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
            const owned = try self.allocator.dupe(u8, bytes);
            slot.* = .{ .key = frame.key, .bytes = owned, .order = order };
            self.serial = order;
            return .accepted;
        }

        /// FIFO even after older completed entries have been reclaimed.
        pub fn take(self: *Self) ?Work {
            if (self.phase != .ready) return null;
            var next: ?*Entry = null;
            for (&self.entries) |*slot| if (slot.*) |*entry| {
                if (entry.state != .queued) continue;
                if (next == null or entry.order < next.?.order) next = entry;
            };
            const entry = next orelse return null;
            entry.state = .executing;
            const frame = protocol.decode(entry.bytes) catch unreachable;
            return .{ .key = entry.key, .request = frame.message.request };
        }

        /// Call after the GUI action actually returns. A modal action may finish
        /// during shutdown; preserve its real result instead of claiming that
        /// a completed side effect was cancelled.
        pub fn finish(self: *Self, key: protocol.Key, outcome: protocol.Outcome) Error!void {
            const entry = self.find(key) orelse return error.UnknownRequest;
            if (entry.state != .executing) return error.NotExecuting;
            entry.state = .completed;
            entry.outcome = outcome;
        }

        /// Repeatable so an ACK lost on disconnect never re-executes a toggle.
        /// null means admitted/executing or unknown, never success.
        pub fn acknowledgement(self: *Self, key: protocol.Key) ?protocol.Outcome {
            const entry = self.find(key) orelse return null;
            return entry.outcome;
        }

        /// Cancel queued work but retain executing payloads through finish.
        pub fn shutdown(self: *Self) void {
            self.phase = .stopping;
            for (&self.entries) |*slot| if (slot.*) |*entry| {
                if (entry.state == .queued) {
                    entry.state = .completed;
                    entry.outcome = .cancelled;
                }
            };
        }

        /// Reclaim only after the native owner independently proves the bound
        /// PID/birth has exited and retires that epoch from ALL connections.
        /// Disconnect, elapsed time or a peer's own claim is insufficient. No
        /// replay entry is evicted automatically: saturation rejects new work.
        pub fn forgetExitedPeer(self: *Self, sender_epoch: u128) Error!void {
            if (sender_epoch == 0) return error.InvalidEpoch;
            for (self.entries) |slot| if (slot) |entry| {
                if (entry.key.sender_epoch == sender_epoch and entry.state != .completed) return error.PeerBusy;
            };
            for (&self.entries) |*slot| if (slot.*) |entry| {
                if (entry.key.sender_epoch != sender_epoch) continue;
                self.allocator.free(entry.bytes);
                slot.* = null;
            };
        }

        fn find(self: *Self, key: protocol.Key) ?*Entry {
            for (&self.entries) |*slot| if (slot.*) |*entry| {
                if (std.meta.eql(entry.key, key)) return entry;
            };
            return null;
        }
    };
}

fn requestFrame(id: u64, request: protocol.Request) protocol.Frame {
    return .{
        .key = .{ .sender_epoch = 11, .host_epoch = 22, .request_id = id },
        .message = .{ .request = request },
    };
}

test "gx.ipc.queue admission and execution cannot acknowledge success early" {
    var queue = try BoundedQueue(2).init(std.testing.allocator, 22);
    defer queue.deinit();
    const frame = requestFrame(1, .toggle_quick_terminal);
    try std.testing.expectError(error.NotReady, queue.submit(11, frame));
    try queue.setReady();
    try std.testing.expectEqual(Admission.accepted, try queue.submit(11, frame));
    try std.testing.expect(queue.acknowledgement(frame.key) == null);
    try std.testing.expectError(error.NotExecuting, queue.finish(frame.key, .completed));
    try std.testing.expectEqualDeep(Admission{ .pending = .queued }, try queue.submit(11, frame));
    const work = queue.take().?;
    try std.testing.expectEqualDeep(frame.key, work.key);
    try std.testing.expect(queue.acknowledgement(frame.key) == null);
    try std.testing.expectEqualDeep(Admission{ .pending = .executing }, try queue.submit(11, frame));
    try std.testing.expect(queue.take() == null);
    try queue.finish(work.key, .completed);
    try std.testing.expectEqual(protocol.Outcome.completed, queue.acknowledgement(frame.key).?);
    try std.testing.expectEqualDeep(Admission{ .completed = .completed }, try queue.submit(11, frame));
    try std.testing.expectError(error.NotExecuting, queue.finish(work.key, .completed));
    try std.testing.expect(queue.take() == null);
}

test "gx.ipc.queue rejects changed payload epochs and bounded replay overflow" {
    var queue = try BoundedQueue(1).init(std.testing.allocator, 22);
    defer queue.deinit();
    try queue.setReady();
    const frame = requestFrame(1, .activate);
    try std.testing.expectError(error.EpochMismatch, queue.submit(12, frame));
    var foreign = frame;
    foreign.key.host_epoch = 23;
    try std.testing.expectError(error.EpochMismatch, queue.submit(11, foreign));
    _ = try queue.submit(11, frame);
    try std.testing.expectError(error.RequestConflict, queue.submit(11, requestFrame(1, .toggle_quick_terminal)));
    try std.testing.expectError(error.PeerBusy, queue.forgetExitedPeer(11));
    _ = queue.take().?;
    try queue.finish(frame.key, .target_gone);
    try std.testing.expectEqual(protocol.Outcome.target_gone, queue.acknowledgement(frame.key).?);
    try std.testing.expectError(error.Full, queue.submit(11, requestFrame(2, .activate)));
    try queue.forgetExitedPeer(11);
    try std.testing.expectEqual(Admission.accepted, try queue.submit(11, requestFrame(2, .activate)));
}

test "gx.ipc.queue owns input and shutdown preserves borrowed executing payload" {
    var queue = try BoundedQueue(2).init(std.testing.allocator, 22);
    defer queue.deinit();
    try queue.setReady();
    var profile = "pwsh".*;
    const first = requestFrame(1, .{ .new_tab = &profile });
    _ = try queue.submit(11, first);
    profile[0] = 'X';
    const work = queue.take().?;
    try std.testing.expectEqualStrings("pwsh", work.request.profile());
    const second = requestFrame(2, .activate);
    _ = try queue.submit(11, second);
    queue.shutdown();
    queue.shutdown();
    try std.testing.expectEqualStrings("pwsh", work.request.profile());
    try std.testing.expect(queue.acknowledgement(first.key) == null);
    try std.testing.expectEqual(protocol.Outcome.cancelled, queue.acknowledgement(second.key).?);
    try std.testing.expectError(error.PeerBusy, queue.forgetExitedPeer(11));
    try std.testing.expectError(error.ShuttingDown, queue.submit(11, requestFrame(3, .activate)));
    try std.testing.expectError(error.ShuttingDown, queue.setReady());
    try std.testing.expect(queue.take() == null);
    try queue.finish(work.key, .execution_failed);
    try std.testing.expectEqual(protocol.Outcome.execution_failed, queue.acknowledgement(first.key).?);
    try queue.forgetExitedPeer(11);
}

test "gx.ipc.queue reclaimed slots preserve FIFO admission order" {
    var queue = try BoundedQueue(2).init(std.testing.allocator, 22);
    defer queue.deinit();
    try queue.setReady();
    const first = requestFrame(1, .activate);
    var second = requestFrame(1, .activate);
    second.key.sender_epoch = 12;
    _ = try queue.submit(11, first);
    _ = try queue.submit(12, second);
    try std.testing.expectEqualDeep(first.key, queue.take().?.key);
    try queue.finish(first.key, .completed);
    try queue.forgetExitedPeer(11);
    var third = requestFrame(1, .activate);
    third.key.sender_epoch = 13;
    _ = try queue.submit(13, third);
    try std.testing.expectEqualDeep(second.key, queue.take().?.key);
    try queue.finish(second.key, .completed);
    try std.testing.expectEqualDeep(third.key, queue.take().?.key);
    try queue.finish(third.key, .completed);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var queue = try BoundedQueue(1).init(allocator, 22);
    defer queue.deinit();
    try queue.setReady();
    const frame = requestFrame(1, .{ .new_window = "custom:work" });
    _ = queue.submit(11, frame) catch |err| {
        try std.testing.expectEqual(@as(u64, 0), queue.serial);
        try std.testing.expect(queue.take() == null);
        return err;
    };
    _ = queue.take().?;
    try queue.finish(frame.key, .completed);
}

test "gx.ipc.queue allocation failure does not reserve request or leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
