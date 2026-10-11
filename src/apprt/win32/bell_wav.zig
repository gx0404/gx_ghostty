const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Wave = struct {
    bytes: []u8,
    rate: u32,
    channels: u16,

    pub fn deinit(self: Wave, alloc: Allocator) void {
        alloc.free(self.bytes);
    }

    pub fn samples(self: Wave) []u8 {
        return self.bytes[44..];
    }
};

pub const max_file_bytes = 16 * 1024 * 1024;
const max_output_bytes = 32 * 1024 * 1024;
const max_seconds = 30;

const Format = struct {
    tag: u16,
    channels: u16,
    rate: u32,
    bits: u16,
    valid_bits: u16,
    block: u16,
};

fn format(bytes: []const u8) !Format {
    if (bytes.len < 16) return error.InvalidWave;
    var tag = std.mem.readInt(u16, bytes[0..2], .little);
    const channels = std.mem.readInt(u16, bytes[2..4], .little);
    const rate = std.mem.readInt(u32, bytes[4..8], .little);
    const byte_rate = std.mem.readInt(u32, bytes[8..12], .little);
    const block = std.mem.readInt(u16, bytes[12..14], .little);
    const bits = std.mem.readInt(u16, bytes[14..16], .little);
    var valid_bits = bits;
    if (bytes.len != 16) {
        if (bytes.len < 18 or std.mem.readInt(u16, bytes[16..18], .little) != bytes.len - 18)
            return error.InvalidWave;
    }
    if (tag == 0xfffe) {
        if (bytes.len != 40) return error.UnsupportedWave;
        valid_bits = std.mem.readInt(u16, bytes[18..20], .little);
        const mask = std.mem.readInt(u32, bytes[20..24], .little);
        if (mask != 0 and mask != (if (channels == 1) @as(u32, 4) else 3))
            return error.UnsupportedWave;
        if (!std.mem.eql(u8, bytes[26..40], &[_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 }))
            return error.UnsupportedWave;
        tag = std.mem.readInt(u16, bytes[24..26], .little);
    } else if (bytes.len > 18) return error.UnsupportedWave;
    if (channels == 0 or channels > 2 or rate < 1000 or rate > 384000)
        return error.UnsupportedWave;
    switch (tag) {
        1 => switch (bits) {
            8, 16, 24, 32 => {},
            else => return error.UnsupportedWave,
        },
        3 => {
            if ((bits != 32 and bits != 64) or valid_bits != bits)
                return error.UnsupportedWave;
        },
        else => return error.UnsupportedWave,
    }
    if (valid_bits == 0 or valid_bits > bits or (bits == 8 and valid_bits != bits))
        return error.InvalidWave;
    if (block != channels * (bits / 8) or byte_rate != @as(u64, rate) * block)
        return error.InvalidWave;
    return .{ .tag = tag, .channels = channels, .rate = rate, .bits = bits, .valid_bits = valid_bits, .block = block };
}

/// Mono/stereo PCM8/16/24/32 and IEEE float32/64 (also extensible) become
/// PCM16 WAVE. Gain is applied before clipping/quantization, never to a device.
pub fn decode(alloc: Allocator, bytes: []const u8, volume: f64) !Wave {
    if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidVolume;
    if (bytes.len > max_file_bytes) return error.WaveTooLarge;
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or
        !std.mem.eql(u8, bytes[8..12], "WAVE") or
        @as(u64, std.mem.readInt(u32, bytes[4..8], .little)) + 8 != bytes.len)
        return error.InvalidWave;
    var fmt: ?Format = null;
    var data: ?[]const u8 = null;
    var pos: usize = 12;
    while (pos < bytes.len) {
        if (bytes.len - pos < 8) return error.InvalidWave;
        const chunk = bytes[pos..];
        const len: usize = std.mem.readInt(u32, chunk[4..8], .little);
        if (len > chunk.len - 8) return error.InvalidWave;
        const padded = len + (len & 1);
        if (padded > chunk.len - 8) return error.InvalidWave;
        if (std.mem.eql(u8, chunk[0..4], "fmt ")) {
            if (fmt != null) return error.InvalidWave;
            fmt = try format(chunk[8..][0..len]);
        } else if (std.mem.eql(u8, chunk[0..4], "data")) {
            if (data != null) return error.InvalidWave;
            data = chunk[8..][0..len];
        }
        pos += 8 + padded;
    }
    const f = fmt orelse return error.InvalidWave;
    const source = data orelse return error.InvalidWave;
    if (source.len == 0 or source.len % f.block != 0) return error.InvalidWave;
    const frames = source.len / f.block;
    if (frames > @as(u64, f.rate) * max_seconds) return error.WaveTooLong;
    const sample_bytes: usize = f.bits / 8;
    const output_len = (source.len / sample_bytes) * 2;
    if (output_len > max_output_bytes) return error.WaveTooLarge;
    const result = try waveHeader(alloc, 1, 16, output_len);
    errdefer alloc.free(result);
    std.mem.writeInt(u16, result[22..24], f.channels, .little);
    std.mem.writeInt(u32, result[24..28], f.rate, .little);
    std.mem.writeInt(u32, result[28..32], f.rate * @as(u32, f.channels) * 2, .little);
    std.mem.writeInt(u16, result[32..34], f.channels * 2, .little);
    var i: usize = 0;
    while (i < source.len / sample_bytes) : (i += 1) {
        const value = try sample(f, source[i * sample_bytes ..][0..sample_bytes]);
        const scaled = @round(value * volume * 32768.0);
        const pcm: i16 = @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
        std.mem.writeInt(i16, result[44 + i * 2 ..][0..2], pcm, .little);
    }
    return .{ .bytes = result, .rate = f.rate, .channels = f.channels };
}

fn sample(f: Format, bytes: []const u8) !f64 {
    if (f.tag == 3) {
        const value: f64 = if (f.bits == 32)
            @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)))
        else
            @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
        if (!std.math.isFinite(value)) return error.NonFiniteSample;
        return value;
    }
    const value: i32 = switch (f.bits) {
        8 => @as(i32, bytes[0]) - 128,
        16 => std.mem.readInt(i16, bytes[0..2], .little),
        24 => std.mem.readInt(i24, bytes[0..3], .little),
        32 => std.mem.readInt(i32, bytes[0..4], .little),
        else => unreachable,
    };
    const padding: u5 = @intCast(f.bits - f.valid_bits);
    if (@as(u32, @bitCast(value)) & ((@as(u32, 1) << padding) - 1) != 0)
        return error.InvalidWave;
    const range: f64 = switch (f.bits) {
        8 => 128,
        16 => 32768,
        24 => 8388608,
        32 => 2147483648,
        else => unreachable,
    };
    return @as(f64, @floatFromInt(value)) / range;
}

fn waveHeader(alloc: Allocator, tag: u16, bits: u16, len: usize) ![]u8 {
    const result = try alloc.alloc(u8, 44 + len + (len & 1));
    @memset(result, 0);
    @memcpy(result[0..4], "RIFF");
    std.mem.writeInt(u32, result[4..8], @intCast(result.len - 8), .little);
    @memcpy(result[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, result[16..20], 16, .little);
    std.mem.writeInt(u16, result[20..22], tag, .little);
    std.mem.writeInt(u16, result[22..24], 1, .little);
    std.mem.writeInt(u32, result[24..28], 8000, .little);
    std.mem.writeInt(u32, result[28..32], 8000 * @as(u32, bits / 8), .little);
    std.mem.writeInt(u16, result[32..34], bits / 8, .little);
    std.mem.writeInt(u16, result[34..36], bits, .little);
    @memcpy(result[36..40], "data");
    std.mem.writeInt(u32, result[40..44], @intCast(len), .little);
    return result;
}

fn fixture(alloc: Allocator, tag: u16, bits: u16, data: []const u8) ![]u8 {
    const result = try waveHeader(alloc, tag, bits, data.len);
    @memcpy(result[44..][0..data.len], data);
    return result;
}

fn expectPcm(bytes: []const u8, volume: f64, expected: []const i16) !void {
    const alloc = std.testing.allocator;
    const wave = try decode(alloc, bytes, volume);
    defer wave.deinit(alloc);
    try std.testing.expectEqual(expected.len * 2, wave.samples().len);
    for (expected, 0..) |value, i| {
        try std.testing.expectEqual(value, std.mem.readInt(i16, wave.samples()[i * 2 ..][0..2], .little));
    }
    const unity = try decode(alloc, wave.bytes, 1);
    defer unity.deinit(alloc);
    try std.testing.expectEqualSlices(u8, wave.bytes, unity.bytes);
}

test "bell audio default volume halves PCM16 playback data" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 16, &.{ 0x20, 0x4e, 0xe0, 0xb1 });
    defer alloc.free(input);
    const wave = try decode(alloc, input, 0.5);
    defer wave.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x27, 0xf0, 0xd8 }, wave.samples());
}

test "bell audio PCM8 zero midpoint and unsigned extrema" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 8, &.{ 0, 128, 255 });
    defer alloc.free(input);
    try expectPcm(input, 1, &.{ -32768, 0, 32512 });
    try expectPcm(input, 0.5, &.{ -16384, 0, 16256 });
    try expectPcm(input, 0, &.{ 0, 0, 0 });
}

test "bell audio signed PCM16 PCM24 PCM32 boundaries and gains" {
    const alloc = std.testing.allocator;
    inline for (.{ @as(u16, 16), @as(u16, 24), @as(u16, 32) }) |bits| {
        const T = std.meta.Int(.signed, bits);
        var data: [6 * (bits / 8)]u8 = undefined;
        const values = [_]T{ std.math.minInt(T), std.math.maxInt(T), 0, 1 << (bits - 2), -(1 << (bits - 2)), -1 };
        for (values, 0..) |v, i| std.mem.writeInt(T, data[i * (bits / 8) ..][0 .. bits / 8], v, .little);
        const input = try fixture(alloc, 1, bits, &data);
        defer alloc.free(input);
        for ([_]f64{ 0, 0.01, 0.1, 0.3, 0.5, 0.75, 1 }) |gain| {
            var expected: [6]i16 = undefined;
            for (values, 0..) |v, i| {
                const scaled = @as(f64, @floatFromInt(v)) * gain / std.math.pow(f64, 2, bits - 16);
                expected[i] = @intFromFloat(std.math.clamp(@round(scaled), -32768, 32767));
            }
            try expectPcm(input, gain, &expected);
        }
    }
}

test "bell audio float gain precedes clipping and nonfinite is rejected" {
    const alloc = std.testing.allocator;
    inline for (.{ f32, f64 }) |T| {
        const U = std.meta.Int(.unsigned, @bitSizeOf(T));
        var data: [5 * @sizeOf(T)]u8 = undefined;
        for ([_]T{ -1, 0, 0.5, 1, 1.5 }, 0..) |v, i|
            std.mem.writeInt(U, data[i * @sizeOf(T) ..][0..@sizeOf(T)], @bitCast(v), .little);
        const input = try fixture(alloc, 3, @bitSizeOf(T), &data);
        defer alloc.free(input);
        try expectPcm(input, 0.5, &.{ -16384, 0, 8192, 16384, 24576 });
        try expectPcm(input, 1, &.{ -32768, 0, 16384, 32767, 32767 });
        for ([_]T{ std.math.nan(T), std.math.inf(T), -std.math.inf(T) }) |v| {
            std.mem.writeInt(U, input[44..][0..@sizeOf(T)], @bitCast(v), .little);
            try std.testing.expectError(error.NonFiniteSample, decode(alloc, input, 0));
        }
    }
}

fn extensible(alloc: Allocator, input: []const u8, tag: u16, valid: u16) ![]u8 {
    const out = try alloc.alloc(u8, input.len + 24);
    @memcpy(out[0..36], input[0..36]);
    @memcpy(out[60..], input[36..]);
    std.mem.writeInt(u32, out[4..8], @intCast(out.len - 8), .little);
    std.mem.writeInt(u32, out[16..20], 40, .little);
    std.mem.writeInt(u16, out[20..22], 0xfffe, .little);
    std.mem.writeInt(u16, out[36..38], 22, .little);
    std.mem.writeInt(u16, out[38..40], valid, .little);
    std.mem.writeInt(u32, out[40..44], 4, .little);
    std.mem.writeInt(u16, out[44..46], tag, .little);
    @memcpy(out[46..60], &[_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 });
    return out;
}

test "bell audio extensible PCM valid bits float GUID and channel mask" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 24, &.{ 0, 0, 0x80, 0xf0, 0xff, 0x7f });
    defer alloc.free(input);
    const ext = try extensible(alloc, input, 1, 20);
    defer alloc.free(ext);
    try expectPcm(ext, 0.5, &.{ -16384, 16384 });
    ext[68] = 1;
    try std.testing.expectError(error.InvalidWave, decode(alloc, ext, 1));
    ext[68] = 0;
    ext[59] = 0;
    try std.testing.expectError(error.UnsupportedWave, decode(alloc, ext, 1));
    ext[59] = 0x71;
    ext[40] = 1;
    try std.testing.expectError(error.UnsupportedWave, decode(alloc, ext, 1));
    const float = try fixture(alloc, 3, 32, &.{ 0, 0, 0, 0x3f });
    defer alloc.free(float);
    const float_ext = try extensible(alloc, float, 3, 32);
    defer alloc.free(float_ext);
    try expectPcm(float_ext, 0.5, &.{8192});
}

test "bell audio stereo keeps channel order and sample rate" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 16, &.{ 0, 0x40, 0, 0xc0 });
    defer alloc.free(input);
    std.mem.writeInt(u16, input[22..24], 2, .little);
    std.mem.writeInt(u32, input[24..28], 44100, .little);
    std.mem.writeInt(u32, input[28..32], 44100 * 4, .little);
    std.mem.writeInt(u16, input[32..34], 4, .little);
    const wave = try decode(alloc, input, 0.5);
    defer wave.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 2), wave.channels);
    try std.testing.expectEqual(@as(u32, 44100), wave.rate);
    try expectPcm(input, 0.5, &.{ 8192, -8192 });
}

test "bell audio RIFF truncations huge chunk malformed fmt and unsupported codecs" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 16, &.{ 0, 0x40 });
    defer alloc.free(input);
    for (0..input.len) |len| try std.testing.expectError(error.InvalidWave, decode(alloc, input[0..len], 0.5));
    std.mem.writeInt(u32, input[40..44], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidWave, decode(alloc, input, 0.5));
    std.mem.writeInt(u32, input[40..44], 2, .little);
    input[32] = 4;
    try std.testing.expectError(error.InvalidWave, decode(alloc, input, 0.5));
    input[32] = 2;
    input[28] = 0;
    input[29] = 0;
    try std.testing.expectError(error.InvalidWave, decode(alloc, input, 0.5));
    std.mem.writeInt(u32, input[28..32], 16000, .little);
    for ([_]u16{ 2, 6, 7, 0x55 }) |tag| {
        std.mem.writeInt(u16, input[20..22], tag, .little);
        try std.testing.expectError(error.UnsupportedWave, decode(alloc, input, 0.5));
    }
}

test "bell audio RIFF padding metadata chunk ordering and duplicates" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 8, &.{255});
    defer alloc.free(input);
    const padded = try alloc.alloc(u8, input.len + 10);
    defer alloc.free(padded);
    @memcpy(padded[0..12], input[0..12]);
    @memcpy(padded[12..22], &[_]u8{ 'J', 'U', 'N', 'K', 1, 0, 0, 0, 0x12, 0 });
    @memcpy(padded[22..], input[12..]);
    std.mem.writeInt(u32, padded[4..8], @intCast(padded.len - 8), .little);
    try expectPcm(padded, 0.5, &.{16256});
    const reordered = try alloc.dupe(u8, input);
    defer alloc.free(reordered);
    @memcpy(reordered[12..22], input[36..46]);
    @memcpy(reordered[22..46], input[12..36]);
    try expectPcm(reordered, 1, &.{32512});
    const duplicate = try alloc.alloc(u8, input.len + 10);
    defer alloc.free(duplicate);
    @memcpy(duplicate[0..input.len], input);
    @memcpy(duplicate[input.len..], input[36..46]);
    std.mem.writeInt(u32, duplicate[4..8], @intCast(duplicate.len - 8), .little);
    try std.testing.expectError(error.InvalidWave, decode(alloc, duplicate, 0.5));
    std.mem.writeInt(u32, input[4..8], @intCast(input.len - 9), .little);
    try std.testing.expectError(error.InvalidWave, decode(alloc, input[0 .. input.len - 1], 0.5));
}

test "bell audio invalid gain duration and file bounds fail safely" {
    const alloc = std.testing.allocator;
    const input = try fixture(alloc, 1, 16, &.{ 0, 0 });
    defer alloc.free(input);
    for ([_]f64{ -0.1, 1.01, std.math.nan(f64), std.math.inf(f64) }) |gain|
        try std.testing.expectError(error.InvalidVolume, decode(alloc, input, gain));
    const long = try waveHeader(alloc, 1, 16, 8000 * 31 * 2);
    defer alloc.free(long);
    try std.testing.expectError(error.WaveTooLong, decode(alloc, long, 1));
    const huge = try alloc.alloc(u8, max_file_bytes + 1);
    defer alloc.free(huge);
    try std.testing.expectError(error.WaveTooLarge, decode(alloc, huge, 1));
}

test "bell audio decoder allocation failures do not leak" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const input = try fixture(alloc, 1, 16, &.{ 0, 0x40 });
            defer alloc.free(input);
            const wave = try decode(alloc, input, 0.5);
            defer wave.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
