//! Bounded, little-endian IPC frames. Decoded text borrows the input frame.
//! These values do not authenticate a peer; bind sender/host epochs to the
//! verified native connection before admitting a request to the GUI queue.
const std = @import("std");

pub const version: u16 = 1;
pub const header_size = 52;
pub const max_profile_bytes = 1024;
pub const max_frame_size = header_size + max_profile_bytes;
const magic = "GXIP";

pub const Error = error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    InvalidKind,
    InvalidLength,
    TrailingData,
    InvalidIdentity,
    InvalidProfile,
    InvalidOutcome,
    BufferTooSmall,
};

pub const Key = struct {
    sender_epoch: u128,
    host_epoch: u128,
    request_id: u64,

    pub fn valid(self: Key) bool {
        return self.sender_epoch != 0 and self.host_epoch != 0 and self.request_id != 0;
    }
};

pub const Kind = enum(u16) {
    activate = 1,
    toggle_quick_terminal = 2,
    new_window = 3,
    new_tab = 4,
    acknowledgement = 0x8000,
};

/// Empty profile means the current trusted default. Nonempty values must be
/// resolved as exact stable IDs by the GUI, never as commands or display names.
pub const Request = union(enum) {
    activate,
    toggle_quick_terminal,
    new_window: []const u8,
    new_tab: []const u8,

    pub fn kind(self: Request) Kind {
        return switch (self) {
            .activate => .activate,
            .toggle_quick_terminal => .toggle_quick_terminal,
            .new_window => .new_window,
            .new_tab => .new_tab,
        };
    }

    pub fn profile(self: Request) []const u8 {
        return switch (self) {
            .new_window, .new_tab => |value| value,
            else => "",
        };
    }
};

/// No success status represents merely accepting or posting a request.
pub const Outcome = enum(u8) {
    completed = 1,
    unavailable = 2,
    rejected = 3,
    target_gone = 4,
    execution_failed = 5,
    cancelled = 6,
};

pub const Message = union(enum) {
    request: Request,
    acknowledgement: Outcome,
};

pub const Frame = struct { key: Key, message: Message };
const Header = struct { key: Key, kind: Kind, payload_size: usize };

fn readHeader(bytes: []const u8) Error!Header {
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
    const kind = std.enums.fromInt(Kind, std.mem.readInt(u16, bytes[6..8], .little)) orelse return error.InvalidKind;
    const size = std.mem.readInt(u32, bytes[8..12], .little);
    switch (kind) {
        .activate, .toggle_quick_terminal => if (size != 0) return error.InvalidLength,
        .new_window, .new_tab => if (size > max_profile_bytes) return error.InvalidLength,
        .acknowledgement => if (size != 1) return error.InvalidLength,
    }
    const key: Key = .{
        .sender_epoch = std.mem.readInt(u128, bytes[12..28], .little),
        .host_epoch = std.mem.readInt(u128, bytes[28..44], .little),
        .request_id = std.mem.readInt(u64, bytes[44..52], .little),
    };
    if (!key.valid()) return error.InvalidIdentity;
    return .{ .key = key, .kind = kind, .payload_size = size };
}

/// Validate a fixed-size header before the transport allocates/reads the body.
pub fn frameSize(header: []const u8) Error!usize {
    if (header.len > header_size) return error.TrailingData;
    return header_size + (try readHeader(header)).payload_size;
}

pub fn validateProfile(profile: []const u8) Error!void {
    if (profile.len > max_profile_bytes or !std.unicode.utf8ValidateSlice(profile)) return error.InvalidProfile;
    for (profile) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidProfile;
}

pub fn decode(bytes: []const u8) Error!Frame {
    const header = try readHeader(bytes);
    const size = header_size + header.payload_size;
    if (bytes.len < size) return error.Truncated;
    if (bytes.len > size) return error.TrailingData;
    const payload = bytes[header_size..];
    const message: Message = switch (header.kind) {
        .activate => .{ .request = .activate },
        .toggle_quick_terminal => .{ .request = .toggle_quick_terminal },
        .new_window, .new_tab => result: {
            try validateProfile(payload);
            break :result .{ .request = if (header.kind == .new_window)
                .{ .new_window = payload }
            else
                .{ .new_tab = payload } };
        },
        .acknowledgement => .{ .acknowledgement = std.enums.fromInt(Outcome, payload[0]) orelse return error.InvalidOutcome },
    };
    return .{ .key = header.key, .message = message };
}

pub fn encode(buffer: []u8, frame: Frame) Error![]u8 {
    if (!frame.key.valid()) return error.InvalidIdentity;
    const kind: Kind = switch (frame.message) {
        .request => |request| request.kind(),
        .acknowledgement => .acknowledgement,
    };
    var outcome_byte: [1]u8 = undefined;
    const payload: []const u8 = switch (frame.message) {
        .request => |request| value: {
            try validateProfile(request.profile());
            break :value request.profile();
        },
        .acknowledgement => |outcome| value: {
            outcome_byte[0] = @backingInt(outcome);
            break :value &outcome_byte;
        },
    };
    const size = header_size + payload.len;
    if (buffer.len < size) return error.BufferTooSmall;
    @memcpy(buffer[0..4], magic);
    std.mem.writeInt(u16, buffer[4..6], version, .little);
    std.mem.writeInt(u16, buffer[6..8], @backingInt(kind), .little);
    std.mem.writeInt(u32, buffer[8..12], @intCast(payload.len), .little);
    std.mem.writeInt(u128, buffer[12..28], frame.key.sender_epoch, .little);
    std.mem.writeInt(u128, buffer[28..44], frame.key.host_epoch, .little);
    std.mem.writeInt(u64, buffer[44..52], frame.key.request_id, .little);
    @memcpy(buffer[header_size..size], payload);
    return buffer[0..size];
}

const test_key: Key = .{ .sender_epoch = 11, .host_epoch = 22, .request_id = 33 };

test "gx.ipc.protocol typed frames round trip and borrow only bounded text" {
    var buffer: [max_frame_size]u8 = undefined;
    const requests = [_]Request{ .activate, .toggle_quick_terminal, .{ .new_window = "" }, .{ .new_tab = "custom:中文" } };
    for (requests) |request| {
        const bytes = try encode(&buffer, .{ .key = test_key, .message = .{ .request = request } });
        try std.testing.expectEqual(bytes.len, try frameSize(bytes[0..header_size]));
        const decoded = try decode(bytes);
        try std.testing.expectEqualDeep(test_key, decoded.key);
        try std.testing.expectEqual(request.kind(), decoded.message.request.kind());
        try std.testing.expectEqualStrings(request.profile(), decoded.message.request.profile());
    }
    inline for (std.meta.tags(Outcome)) |outcome| {
        const bytes = try encode(&buffer, .{ .key = test_key, .message = .{ .acknowledgement = outcome } });
        try std.testing.expectEqual(outcome, (try decode(bytes)).message.acknowledgement);
    }
}

test "gx.ipc.protocol rejects malformed header before body allocation" {
    var buffer: [max_frame_size]u8 = undefined;
    const bytes = try encode(&buffer, .{ .key = test_key, .message = .{ .request = .activate } });
    for (0..header_size) |size| try std.testing.expectError(error.Truncated, frameSize(bytes[0..size]));
    buffer[0] = 0;
    try std.testing.expectError(error.InvalidMagic, decode(bytes));
    buffer[0] = 'G';
    buffer[4] = 2;
    try std.testing.expectError(error.UnsupportedVersion, decode(bytes));
    buffer[4] = 1;
    buffer[6] = 0;
    try std.testing.expectError(error.InvalidKind, decode(bytes));
    buffer[6] = @backingInt(Kind.new_window);
    std.mem.writeInt(u32, buffer[8..12], max_profile_bytes + 1, .little);
    try std.testing.expectError(error.InvalidLength, frameSize(bytes));
    std.mem.writeInt(u32, buffer[8..12], 0, .little);
    std.mem.writeInt(u64, buffer[44..52], 0, .little);
    try std.testing.expectError(error.InvalidIdentity, decode(bytes));
}

test "gx.ipc.protocol rejects trailing bytes truncated text and control characters" {
    var buffer: [max_frame_size]u8 = undefined;
    const bytes = try encode(&buffer, .{ .key = test_key, .message = .{ .request = .{ .new_tab = "pwsh" } } });
    try std.testing.expectError(error.Truncated, decode(bytes[0 .. bytes.len - 1]));
    try std.testing.expectError(error.TrailingData, decode(buffer[0 .. bytes.len + 1]));
    try std.testing.expectError(error.TrailingData, frameSize(bytes));
    for ([_][]const u8{ "custom:a\n", "custom:a\x00", "\xff", "\x7f" }) |invalid|
        try std.testing.expectError(error.InvalidProfile, validateProfile(invalid));
    const too_long = @as([(max_profile_bytes + 1)]u8, @splat('a'));
    try std.testing.expectError(error.InvalidProfile, validateProfile(&too_long));
    try std.testing.expectError(error.BufferTooSmall, encode(buffer[0..1], .{ .key = test_key, .message = .{ .request = .activate } }));
    const ack = try encode(&buffer, .{ .key = test_key, .message = .{ .acknowledgement = .completed } });
    buffer[header_size] = 0;
    try std.testing.expectError(error.InvalidOutcome, decode(ack));
}
