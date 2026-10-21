const std = @import("std");
const font = @import("../font/main.zig");
const mapped = @import("font_codepoint_map.zig");
const freetype = @import("freetype");
const Allocator = std.mem.Allocator;

pub fn traits(face: *const font.Face) !mapped.Traits {
    const flags = face.face.handle.*.style_flags;
    var result: mapped.Traits = .{ .bold = flags & 2 != 0, .italic = flags & 1 != 0 };
    if (face.face.getSfntTable(.os2)) |os2| result.bold = result.bold or os2.usWeightClass >= 600;
    if (!face.face.hasMultipleMasters()) return result;
    const mm = try face.face.getMMVar();
    defer face.lib.lib.doneMMVar(mm);
    if (mm.num_axis > 32) return error.TooManyFontAxes;
    var coords: [32]freetype.c.FT_Fixed = undefined;
    try face.face.getVarDesignCoordinates(coords[0..mm.num_axis]);
    for (coords[0..mm.num_axis], 0..) |coord, i| {
        const tag: u32 = @truncate(mm.axis[i].tag);
        if (tag == @as(u32, @bitCast(font.face.Variation.Id.init("wght")))) result.bold = coord >= 600 * 65536;
        if (tag == @as(u32, @bitCast(font.face.Variation.Id.init("ital")))) result.italic = coord != 0;
        if (tag == @as(u32, @bitCast(font.face.Variation.Id.init("slnt"))) and coord != 0) result.italic = true;
    }
    return result;
}

fn ownVariations(alloc: Allocator, variations: []const font.face.Variation) ![]font.face.Variation {
    var result: std.ArrayList(font.face.Variation) = .empty;
    errdefer result.deinit(alloc);
    for (variations) |variation| {
        var replaced = false;
        for (result.items) |*existing| {
            if (@as(u32, @bitCast(existing.id)) == @as(u32, @bitCast(variation.id))) {
                existing.* = variation;
                replaced = true;
                break;
            }
        }
        if (!replaced) try result.append(alloc, variation);
    }
    return try result.toOwnedSlice(alloc);
}

fn coordinates(alloc: Allocator, face: *const font.Face, defaults: []const font.face.Variation) ![]font.face.Variation {
    if (!face.face.hasMultipleMasters()) return try alloc.dupe(font.face.Variation, defaults);
    const mm = try face.face.getMMVar();
    defer face.lib.lib.doneMMVar(mm);
    if (mm.num_axis > 32) return error.TooManyFontAxes;
    var raw: [32]freetype.c.FT_Fixed = undefined;
    try face.face.getVarDesignCoordinates(raw[0..mm.num_axis]);
    const result = try alloc.alloc(font.face.Variation, mm.num_axis);
    for (result, 0..) |*variation, i| variation.* = .{ .id = @bitCast(@as(u32, @truncate(mm.axis[i].tag))), .value = @as(f64, @floatFromInt(raw[i])) / 65536.0 };
    return result;
}

pub fn fromDeferred(alloc: Allocator, library: font.Library, deferred: font.DeferredFace, variations: []const font.face.Variation) !mapped.Candidate {
    var source = deferred;
    const inputs = try ownVariations(alloc, variations);
    defer alloc.free(inputs);
    const file: [:0]const u8, const index: i32 = if (comptime font.options.backend == .freetype_windows) blk: {
        source.win.?.variations = inputs;
        break :blk .{ source.win.?.path, source.win.?.face_index };
    } else blk: {
        source.fc.?.variations = inputs;
        break :blk .{ (try source.fc.?.pattern.get(.file, 0)).string, (try source.fc.?.pattern.get(.index, 0)).integer };
    };
    const path = try alloc.dupeSentinel(u8, file, 0);
    errdefer alloc.free(path);
    var peek = try source.load(library, .{ .size = .{ .points = 12 } });
    defer peek.deinit();
    const actual = try traits(&peek);
    const owned = try coordinates(alloc, &peek, inputs);
    if (comptime font.options.backend == .freetype_windows) source.win.?.variations = owned else source.fc.?.variations = owned;
    return .{
        .source = .{ .deferred = source },
        .traits = actual,
        .file = path,
        .face_index = index,
        .variations = owned,
        .load = load,
    };
}

pub fn fromMemory(alloc: Allocator, library: font.Library, bytes: [:0]const u8, variations: []const font.face.Variation) !mapped.Candidate {
    const owned = try ownVariations(alloc, variations);
    errdefer alloc.free(owned);
    const opts: font.face.Options = .{ .size = .{ .points = 12 } };
    var peek = try font.Face.init(library, bytes, opts);
    errdefer peek.deinit();
    try peek.setVariations(owned, opts);
    return .{
        .source = .{ .memory = .{ .bytes = bytes, .peek = peek } },
        .traits = try traits(&peek),
        .variations = owned,
        .load = load,
    };
}

fn load(candidate: *mapped.Candidate, library: font.Library, opts: font.face.Options, synthetic: mapped.Traits) !font.Face {
    var face = switch (candidate.source) {
        .deferred => |*deferred| try deferred.load(library, opts),
        .memory => |memory| try font.Face.init(library, memory.bytes, opts),
    };
    errdefer face.deinit();
    try face.setVariations(candidate.variations, opts);
    face.synthetic = .{ .bold = synthetic.bold, .italic = synthetic.italic };
    return face;
}
