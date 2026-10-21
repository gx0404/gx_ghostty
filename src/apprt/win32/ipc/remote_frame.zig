//! A borrowed, generation-bound shared-memory BGRA double buffer. Mapping ACLs,
//! authenticated handle transfer and lifetime are the native transport owner's
//! responsibility. Keep the mapping alive until every local lease is released.
//! All interprocess ownership transitions use naturally aligned lock-free u64
//! CAS; no process-local mutex is stored in the mapped region.
const std = @import("std");
const model = @import("../../../gx/remote_view.zig");
pub const Layout = model.Layout;
const magic = "GXFRAME1";
const version: u32 = 2;
const control_offsets = [_]usize{ 64, 128 };
const sequence_offset = 48;
const closed_offset = 56;
const state_mask: u64 = 7;
const max_sequence = std.math.maxInt(u64) >> 3;
comptime {
    // Other targets may lower u64 atomics through process-local helper locks.
    // The Windows app transport is restricted to native 64-bit atomics.
    const arch = @import("builtin").target.cpu.arch;
    if (arch != .x86_64 and arch != .aarch64) @compileError("remote frames require native 64-bit atomics");
}
const State = enum(u3) { free = 0, writing = 1, ready = 2, reading = 3 };
pub const Error = error{ InvalidHeader, UnsupportedVersion, InvalidGeneration, InvalidLayout, MappingLength, CorruptState, InvalidFrame, Closed, WouldBlock, SequenceExhausted, StaleLease, BufferLength };

fn atomicAt(bytes: []align(8) u8, offset: usize) *u64 {
    return @ptrCast(@alignCast(bytes.ptr + offset));
}
fn state(control: u64) Error!State {
    const value = std.enums.fromInt(State, control & state_mask) orelse return error.CorruptState;
    if (value != .free and control >> 3 == 0) return error.CorruptState;
    return value;
}
fn withState(control: u64, value: State) u64 {
    return (control & ~state_mask) | @backingInt(value);
}

pub const Mapped = struct {
    /// Header fields are copied and checked once. Never use mutable shared
    /// dimensions/offsets for addressing, even if a peer corrupts its header.
    bytes: []align(8) u8,
    layout: Layout,
    generation: u64,
    last_sequence: u64 = 0,

    /// Source-only initialization, before publishing a handle to any peer.
    /// A resize/new source uses a new mapping, never reinitializes active bytes.
    pub fn initialize(bytes: []align(8) u8, layout: Layout, generation: u64) !Mapped {
        if (generation == 0) return error.InvalidGeneration;
        const checked = try Layout.checked(layout.width, layout.height, layout.stride);
        if (!std.meta.eql(checked, layout)) return error.InvalidLayout;
        if (bytes.len != checked.total_bytes) return error.MappingLength;
        @memset(bytes[0..model.header_bytes], 0);
        @memcpy(bytes[0..8], magic);
        std.mem.writeInt(u32, bytes[8..12], version, .little);
        std.mem.writeInt(u32, bytes[12..16], model.header_bytes, .little);
        std.mem.writeInt(u32, bytes[16..20], checked.width, .little);
        std.mem.writeInt(u32, bytes[20..24], checked.height, .little);
        std.mem.writeInt(u32, bytes[24..28], checked.stride, .little);
        std.mem.writeInt(u32, bytes[28..32], checked.slot_bytes, .little);
        std.mem.writeInt(u64, bytes[32..40], generation, .little);
        std.mem.writeInt(u64, bytes[40..48], checked.total_bytes, .little);
        return .{ .bytes = bytes, .layout = checked, .generation = generation };
    }

    /// expected_generation comes from the authenticated source handshake.
    pub fn attach(bytes: []align(8) u8, expected_generation: u64) !Mapped {
        if (bytes.len < model.header_bytes) return error.MappingLength;
        if (!std.mem.eql(u8, bytes[0..8], magic) or std.mem.readInt(u32, bytes[12..16], .little) != model.header_bytes) return error.InvalidHeader;
        if (std.mem.readInt(u32, bytes[8..12], .little) != version) return error.UnsupportedVersion;
        const generation = std.mem.readInt(u64, bytes[32..40], .little);
        if (expected_generation == 0 or generation != expected_generation) return error.InvalidGeneration;
        const layout = try Layout.checked(std.mem.readInt(u32, bytes[16..20], .little), std.mem.readInt(u32, bytes[20..24], .little), std.mem.readInt(u32, bytes[24..28], .little));
        if (std.mem.readInt(u32, bytes[28..32], .little) != layout.slot_bytes) return error.InvalidLayout;
        if (std.mem.readInt(u64, bytes[40..48], .little) != layout.total_bytes or bytes.len != layout.total_bytes) return error.MappingLength;
        for (control_offsets) |offset| _ = try state(@atomicLoad(u64, atomicAt(bytes, offset), .acquire));
        if (@atomicLoad(u64, atomicAt(bytes, sequence_offset), .acquire) > max_sequence) return error.CorruptState;
        var result: Mapped = .{ .bytes = bytes, .layout = layout, .generation = generation };
        try result.ensureOpen();
        return result;
    }

    fn ensureOpen(self: *const Mapped) Error!void {
        if (@atomicLoad(u64, atomicAt(self.bytes, closed_offset), .acquire) != 0) return error.Closed;
    }

    fn nextSequence(self: *Mapped) Error!u64 {
        const counter = atomicAt(self.bytes, sequence_offset);
        var previous = @atomicLoad(u64, counter, .acquire);
        while (true) {
            if (previous >= max_sequence) return error.SequenceExhausted;
            if (@cmpxchgWeak(u64, counter, previous, previous + 1, .acq_rel, .acquire)) |changed| {
                previous = changed;
            } else return previous + 1;
        }
    }

    /// One producer and one consumer per view. Unread ready frames can be
    /// superseded; a reading slot is never selected, regardless of its age.
    pub fn beginWrite(self: *Mapped) Error!WriteLease {
        try self.ensureOpen();
        for (control_offsets, 0..) |offset, index| {
            const control = atomicAt(self.bytes, offset);
            const previous = @atomicLoad(u64, control, .acquire);
            const phase = try state(previous);
            if (phase != .free and phase != .ready) continue;
            const sequence = try self.nextSequence();
            const expected = (sequence << 3) | @backingInt(State.writing);
            if (@cmpxchgStrong(u64, control, previous, expected, .acq_rel, .acquire) != null) continue;
            const start = self.layout.offset(@intCast(index));
            return .{ .control = control, .expected = expected, .closed = atomicAt(self.bytes, closed_offset), .metadata = self.bytes[offset + 16 ..][0..32], .generation = self.generation, .pixels = self.bytes[start..][0..self.layout.frame_bytes] };
        }
        return error.WouldBlock;
    }

    /// Claims ready slots before reading metadata, then releases the older
    /// candidate. This avoids racing a producer that replaces an unread frame.
    pub fn acquire(self: *Mapped) Error!?ReadLease {
        try self.ensureOpen();
        var best: ?ReadLease = null;
        errdefer if (best) |*lease| {
            _ = lease.release();
        };
        for (control_offsets, 0..) |offset, index| {
            const control = atomicAt(self.bytes, offset);
            const previous = @atomicLoad(u64, control, .acquire);
            if (try state(previous) != .ready) continue;
            const expected = withState(previous, .reading);
            if (@cmpxchgStrong(u64, control, previous, expected, .acq_rel, .acquire) != null) continue;
            const start = self.layout.offset(@intCast(index));
            var candidate: ReadLease = .{ .control = control, .expected = expected, .generation = self.generation, .sequence = previous >> 3, .pixels = self.bytes[start..][0..self.layout.frame_bytes] };
            const generation = std.mem.readInt(u64, self.bytes[offset + 16 ..][0..8], .little);
            const size = std.mem.readInt(u32, self.bytes[offset + 24 ..][0..4], .little);
            candidate.perf_input = .{
                .sequence = std.mem.readInt(u64, self.bytes[offset + 32 ..][0..8], .little),
                .qpc = std.mem.readInt(u64, self.bytes[offset + 40 ..][0..8], .little),
            };
            if (generation != self.generation or size != self.layout.frame_bytes or !candidate.perf_input.valid()) {
                _ = candidate.release();
                return error.InvalidFrame;
            }
            if (candidate.sequence <= self.last_sequence or (best != null and candidate.sequence <= best.?.sequence)) {
                _ = candidate.release();
                continue;
            }
            if (best) |*older| _ = older.release();
            best = candidate;
        }
        try self.ensureOpen();
        if (best) |frame| self.last_sequence = frame.sequence;
        return best;
    }

    /// Source-only: prevent further publication before unmapping/shutdown.
    /// Existing leases must still be released; close does not free storage.
    pub fn close(self: *Mapped) void {
        @atomicStore(u64, atomicAt(self.bytes, closed_offset), 1, .release);
    }

    /// ONLY after native PID/birth verification proves the target process has
    /// exited and all local aliases are quiescent. A timeout or pipe disconnect
    /// alone is not proof and must never reclaim a live reader's bytes.
    pub fn reclaimReaderAfterExit(self: *Mapped) Error!void {
        for (control_offsets) |offset| {
            const control = atomicAt(self.bytes, offset);
            const previous = @atomicLoad(u64, control, .acquire);
            if (try state(previous) == .reading)
                _ = @cmpxchgStrong(u64, control, previous, withState(previous, .free), .acq_rel, .acquire);
        }
    }
};

/// Do not copy a lease or keep writing after publishing/cancelling it. Fill the
/// entire frame (including stride padding) before publishWritten; publishCopy
/// enforces an exact source length for callers that already own BGRA bytes.
pub const WriteLease = struct {
    control: *u64,
    expected: u64,
    closed: *u64,
    metadata: []u8,
    generation: u64,
    pixels: []u8,
    perf_input: model.InputStamp = .{},
    active: bool = true,

    pub fn publishCopy(self: *WriteLease, pixels: []const u8) Error!void {
        if (!self.active or @atomicLoad(u64, self.control, .acquire) != self.expected) return error.StaleLease;
        if (pixels.len != self.pixels.len) return error.BufferLength;
        @memcpy(self.pixels, pixels);
        try self.publishWritten();
    }
    pub fn publishWritten(self: *WriteLease) Error!void {
        if (!self.active or @atomicLoad(u64, self.control, .acquire) != self.expected) return error.StaleLease;
        if (!self.perf_input.valid()) return error.InvalidFrame;
        if (@atomicLoad(u64, self.closed, .acquire) != 0) {
            _ = self.cancel();
            return error.Closed;
        }
        std.mem.writeInt(u64, self.metadata[0..8], self.generation, .little);
        std.mem.writeInt(u32, self.metadata[8..12], @intCast(self.pixels.len), .little);
        // v2 uses existing header padding; pixel offsets and bounds are intact.
        // The ready release publishes the stamp and pixels as one borrowed slot.
        std.mem.writeInt(u64, self.metadata[16..24], self.perf_input.sequence, .little);
        std.mem.writeInt(u64, self.metadata[24..32], self.perf_input.qpc, .little);
        self.active = false;
        if (@cmpxchgStrong(u64, self.control, self.expected, withState(self.expected, .ready), .release, .monotonic) != null) return error.StaleLease;
    }
    pub fn cancel(self: *WriteLease) bool {
        if (!self.active) return false;
        self.active = false;
        return @cmpxchgStrong(u64, self.control, self.expected, withState(self.expected, .free), .release, .monotonic) == null;
    }
};

pub const ReadLease = struct {
    control: *u64,
    expected: u64,
    generation: u64,
    sequence: u64,
    pixels: []const u8,
    perf_input: model.InputStamp = .{},
    active: bool = true,
    pub fn release(self: *ReadLease) bool {
        if (!self.active) return false;
        self.active = false;
        return @cmpxchgStrong(u64, self.control, self.expected, withState(self.expected, .free), .release, .monotonic) == null;
    }
};

test "remote frame attach validates size stride generation and header version" {
    var bytes: [384]u8 align(8) = undefined;
    const layout = try Layout.checked(4, 2, 16);
    _ = try Mapped.initialize(&bytes, layout, 7);
    _ = try Mapped.attach(&bytes, 7);
    try std.testing.expectError(error.InvalidGeneration, Mapped.attach(&bytes, 8));
    try std.testing.expectError(error.MappingLength, Mapped.attach(bytes[0..383], 7));
    std.mem.writeInt(u32, bytes[24..28], 12, .little);
    try std.testing.expectError(error.InvalidStride, Mapped.attach(&bytes, 7));
    _ = try Mapped.initialize(&bytes, layout, 7);
    for ([_]u32{ 1, 3 }) |unsupported| {
        std.mem.writeInt(u32, bytes[8..12], unsupported, .little);
        try std.testing.expectError(error.UnsupportedVersion, Mapped.attach(&bytes, 7));
    }
    std.mem.writeInt(u32, bytes[8..12], version, .little);
    _ = try Mapped.attach(&bytes, 7);
}

test "remote frame never overwrites borrowed slots and stale release cannot free a replacement" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var first = try producer.beginWrite();
    try first.publishCopy(&(@as([32]u8, @splat(1))));
    var a = (try consumer.acquire()).?;
    var stale = a;
    var second = try producer.beginWrite();
    try second.publishCopy(&(@as([32]u8, @splat(2))));
    var b = (try consumer.acquire()).?;
    try std.testing.expectError(error.WouldBlock, producer.beginWrite());
    try std.testing.expectEqual(@as(u8, 1), a.pixels[0]);
    try std.testing.expectEqual(@as(u8, 2), b.pixels[0]);
    try std.testing.expect(a.release());
    var third = try producer.beginWrite();
    try third.publishCopy(&(@as([32]u8, @splat(3))));
    var c = (try consumer.acquire()).?;
    try std.testing.expect(!stale.release());
    try std.testing.expectEqual(@as(u8, 3), c.pixels[0]);
    try std.testing.expect(b.release());
    try std.testing.expect(c.release());
}

test "remote frame rejects stale metadata and source close cancels in-flight publication" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var first = try producer.beginWrite();
    try first.publishCopy(&(@as([32]u8, @splat(1))));
    std.mem.writeInt(u64, bytes[80..88], 6, .little);
    try std.testing.expectError(error.InvalidFrame, consumer.acquire());
    var writing = try producer.beginWrite();
    producer.close();
    try std.testing.expectError(error.Closed, writing.publishWritten());
    try std.testing.expectError(error.Closed, consumer.acquire());
    try std.testing.expectError(error.Closed, producer.beginWrite());
}

test "remote frame acquisition releases its earlier lease when a later slot is corrupt" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var first = try producer.beginWrite();
    // Keep slot 0 writing while claiming slot 1: a ready slot is reusable.
    var second = try producer.beginWrite();
    try first.publishCopy(&(@as([32]u8, @splat(1))));
    try second.publishCopy(&(@as([32]u8, @splat(2))));
    // acquire takes slot 0 before discovering slot 1's stale generation.
    std.mem.writeInt(u64, bytes[control_offsets[1] + 16 ..][0..8], 6, .little);
    try std.testing.expectError(error.InvalidFrame, consumer.acquire());
    // Both the failed candidate and previously acquired best must be returned.
    try std.testing.expectEqual(State.free, try state(@atomicLoad(u64, atomicAt(&bytes, control_offsets[0]), .acquire)));
    try std.testing.expectEqual(State.free, try state(@atomicLoad(u64, atomicAt(&bytes, control_offsets[1]), .acquire)));
    var recovered = try producer.beginWrite();
    try std.testing.expect(recovered.cancel());
}

test "remote frame peer-exit reclamation invalidates the exact old reader token" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var writing = try producer.beginWrite();
    try writing.publishCopy(&(@as([32]u8, @splat(1))));
    var abandoned = (try consumer.acquire()).?;
    try producer.reclaimReaderAfterExit();
    try std.testing.expect(!abandoned.release());
    var recovered = try producer.beginWrite();
    try std.testing.expect(recovered.cancel());
    try std.testing.expect(!recovered.cancel());
}

test "remote frame out-of-order publication cannot display an older sequence" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var older = try producer.beginWrite();
    var newer = try producer.beginWrite();
    try newer.publishCopy(&(@as([32]u8, @splat(2))));
    var displayed = (try consumer.acquire()).?;
    try older.publishCopy(&(@as([32]u8, @splat(1))));
    try std.testing.expect((try consumer.acquire()) == null);
    try std.testing.expectEqual(@as(u8, 2), displayed.pixels[0]);
    try std.testing.expect(displayed.release());
}

test "remote frame copied stale writer cannot publish after cancellation and reuse" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var writing = try producer.beginWrite();
    var stale = writing;
    try std.testing.expect(writing.cancel());
    var replacement = try producer.beginWrite();
    try std.testing.expectError(error.StaleLease, stale.publishCopy(&(@as([32]u8, @splat(9)))));
    try std.testing.expectError(error.BufferLength, replacement.publishCopy(&.{1}));
    try std.testing.expect(replacement.cancel());
    @atomicStore(u64, atomicAt(&bytes, sequence_offset), max_sequence, .release);
    try std.testing.expectError(error.SequenceExhausted, producer.beginWrite());
}

test "remote frame validated addresses do not follow later shared header corruption" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    std.mem.writeInt(u32, bytes[24..28], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, bytes[28..32], std.math.maxInt(u32), .little);
    var writing = try producer.beginWrite();
    try writing.publishCopy(&(@as([32]u8, @splat(4))));
    var reading = (try consumer.acquire()).?;
    try std.testing.expectEqual(@as(usize, 32), reading.pixels.len);
    try std.testing.expectEqual(@as(u8, 4), reading.pixels[31]);
    try std.testing.expect(reading.release());
}

test "remote frame performance stamp belongs to its pixel lease and resets on reuse" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var first = try producer.beginWrite();
    first.perf_input = .{ .sequence = 3, .qpc = 12345 };
    try first.publishCopy(&(@as([32]u8, @splat(1))));
    var held = (try consumer.acquire()).?;
    var second = try producer.beginWrite();
    second.perf_input = .{ .sequence = 5, .qpc = 23456 };
    try second.publishCopy(&(@as([32]u8, @splat(2))));
    var replacement = try producer.beginWrite();
    replacement.perf_input = .{ .sequence = 9, .qpc = 34567 };
    try replacement.publishCopy(&(@as([32]u8, @splat(3))));
    try std.testing.expectEqual(first.perf_input, held.perf_input);
    try std.testing.expectEqual(@as(u8, 1), held.pixels[0]);
    var latest = (try consumer.acquire()).?;
    try std.testing.expectEqual(replacement.perf_input, latest.perf_input);
    try std.testing.expectEqual(@as(u8, 3), latest.pixels[0]);
    try std.testing.expect(held.release());
    try std.testing.expect(latest.release());
    var off = try producer.beginWrite();
    try off.publishCopy(&(@as([32]u8, @splat(4))));
    var plain = (try consumer.acquire()).?;
    try std.testing.expectEqual(model.InputStamp{}, plain.perf_input);
    try std.testing.expect(plain.release());
    try std.testing.expectEqual(@as(usize, 256), producer.layout.offset(0));
    try std.testing.expectEqual(@as(usize, 384), producer.layout.total_bytes);
}

test "remote frame malformed stamp rejects publication and releases corrupt read candidates" {
    var bytes: [384]u8 align(8) = undefined;
    var producer = try Mapped.initialize(&bytes, try Layout.checked(4, 2, 16), 7);
    var consumer = try Mapped.attach(&bytes, 7);
    var writing = try producer.beginWrite();
    writing.perf_input = .{ .sequence = 1 };
    try std.testing.expectError(error.InvalidFrame, writing.publishWritten());
    try std.testing.expect(writing.cancel());
    var first = try producer.beginWrite();
    var second = try producer.beginWrite();
    try first.publishCopy(&(@as([32]u8, @splat(1))));
    try second.publishCopy(&(@as([32]u8, @splat(2))));
    std.mem.writeInt(u64, bytes[control_offsets[1] + 32 ..][0..8], 9, .little);
    try std.testing.expectError(error.InvalidFrame, consumer.acquire());
    for (control_offsets) |offset| {
        try std.testing.expectEqual(State.free, try state(@atomicLoad(u64, atomicAt(&bytes, offset), .acquire)));
    }
}
