const std = @import("std");
const fontconfig = @import("fontconfig");
const font = @import("../font/main.zig");
const mapped = @import("font_codepoint_map.zig");
const ft = @import("font_map_freetype.zig");
const Allocator = std.mem.Allocator;

pub fn discover(config: *fontconfig.Config, alloc: Allocator, library: font.Library, descriptor: font.Descriptor, family: ?[:0]const u8, style: font.Style) !mapped.Batch {
    var request = descriptor;
    if (family) |locked| {
        request.family = locked;
        request.style = null;
        const desired = mapped.Traits.fromStyle(style);
        request.bold = desired.bold;
        request.italic = desired.italic;
    }
    request.codepoint = 0;
    const pattern = request.toFcPattern();
    defer pattern.destroy();
    if (!config.substituteWithPat(pattern, .pattern)) return error.OutOfMemory;
    pattern.defaultSubstitute();
    const sorted = config.fontSort(pattern, false, null);
    try sorted.result.toError();
    defer sorted.fs.destroy();
    var result: mapped.Batch = .{};
    errdefer result.deinit(alloc);
    if (family) |locked| result.family = try alloc.dupeZ(u8, locked);
    var base_traits: ?mapped.Traits = null;
    for (sorted.fs.fonts()) |raw| {
        const metadata = (try rawMetadata(raw)) orelse continue;
        if (result.family == null) {
            result.family = try alloc.dupeZ(u8, metadata.family);
            base_traits = metadata.traits;
        }
        if (!try hasFamily(raw, result.family.?)) continue;
        if (style == .regular) {
            if (!metadata.traits.eql(base_traits.?)) continue;
        } else if (!metadata.traits.eql(mapped.Traits.fromStyle(style))) continue;
        var variations: std.ArrayList(font.face.Variation) = .empty;
        defer variations.deinit(alloc);
        if (raw.get(.font_variations, 0)) |value| {
            if (value == .string) try parseVariations(alloc, &variations, value.string);
        } else |err| if (err == error.OutOfMemory) return err;
        for (descriptor.variations) |variation| try variations.append(alloc, variation);
        const prepared = try config.fontRenderPrepare(pattern, raw);
        var deferred: font.DeferredFace = .{ .fc = .{
            .pattern = prepared,
            .charset = (prepared.get(.charset, 0) catch |err| {
                prepared.destroy();
                return err;
            }).char_set,
            .langset = (prepared.get(.lang, 0) catch |err| {
                prepared.destroy();
                return err;
            }).lang_set,
            .variations = &.{},
        } };
        var candidate = ft.fromDeferred(alloc, library, deferred, variations.items) catch |err| {
            deferred.deinit();
            return err;
        };
        errdefer candidate.deinit(alloc);
        if (!std.mem.eql(u8, candidate.file.?, metadata.file) or candidate.face_index != metadata.index or
            (style != .regular and !candidate.traits.eql(mapped.Traits.fromStyle(style))))
        {
            candidate.deinit(alloc);
            continue;
        }
        try result.candidates.append(alloc, candidate);
    }
    return result;
}

const RawMetadata = struct { family: [:0]const u8, file: [:0]const u8, index: i32, traits: mapped.Traits };

fn rawMetadata(pattern: *fontconfig.Pattern) !?RawMetadata {
    const family = pattern.get(.family, 0) catch |err| return if (err == error.OutOfMemory) err else null;
    const weight = pattern.get(.weight, 0) catch |err| return if (err == error.OutOfMemory) err else null;
    const slant = pattern.get(.slant, 0) catch |err| return if (err == error.OutOfMemory) err else null;
    const file = pattern.get(.file, 0) catch |err| return if (err == error.OutOfMemory) err else null;
    const index = pattern.get(.index, 0) catch |err| return if (err == error.OutOfMemory) err else null;
    if (family != .string or family.string.len == 0 or file != .string or file.string.len == 0 or index != .integer or index.integer < 0 or slant != .integer) return null;
    const bold = switch (weight) {
        .integer => weight.integer >= @intFromEnum(fontconfig.Weight.demibold),
        .double => weight.double >= @as(f64, @floatFromInt(@intFromEnum(fontconfig.Weight.demibold))),
        else => return null,
    };
    return .{ .family = family.string, .file = file.string, .index = index.integer, .traits = .{ .bold = bold, .italic = slant.integer != @intFromEnum(fontconfig.Slant.roman) } };
}

fn hasFamily(pattern: *fontconfig.Pattern, family: []const u8) !bool {
    var i: u32 = 0;
    while (pattern.get(.family, i)) |value| : (i += 1) {
        if (value == .string and std.ascii.eqlIgnoreCase(value.string, family)) return true;
    } else |err| if (err == error.OutOfMemory) return err;
    return false;
}

fn parseVariations(alloc: Allocator, variations: *std.ArrayList(font.face.Variation), text: []const u8) !void {
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const equal = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (equal != 4) continue;
        const value = std.fmt.parseFloat(f64, part[equal + 1 ..]) catch continue;
        if (!std.math.isFinite(value)) continue;
        try variations.append(alloc, .{ .id = font.face.Variation.Id.init(part[0..4]), .value = value });
    }
}

test "gx.font_codepoint_map: Fontconfig raw metadata rejects regular and foreign sorted candidates" {
    if (font.options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const testing = std.testing;
    const raw = fontconfig.Pattern.create();
    defer raw.destroy();
    try testing.expect(raw.add(.family, .{ .string = "Fixture" }, false));
    try testing.expect(raw.add(.file, .{ .string = "regular.ttf" }, false));
    try testing.expect(raw.add(.index, .{ .integer = 0 }, false));
    try testing.expect(raw.add(.weight, .{ .integer = @intFromEnum(fontconfig.Weight.regular) }, false));
    try testing.expect(raw.add(.slant, .{ .integer = @intFromEnum(fontconfig.Slant.roman) }, false));
    try testing.expect(!(try rawMetadata(raw)).?.traits.bold);
    try testing.expect(!try hasFamily(raw, "Other"));
    try testing.expect(raw.add(.family, .{ .string = "本地族名" }, true));
    try testing.expect(try hasFamily(raw, "本地族名"));
    _ = raw.delete(.file);
    try testing.expect(try rawMetadata(raw) == null);
}

test "gx.font_codepoint_map: isolated Fontconfig four embedded faces alias and missing styles" {
    if (font.options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const names = [_][]const u8{ "regular.ttf", "bold.ttf", "italic.ttf", "bold-italic.ttf", "foreign.ttf" };
    const bytes = [_][:0]const u8{ font.embedded.regular, font.embedded.bold, font.embedded.italic, font.embedded.bold_italic, font.embedded.inconsolata };
    for (names, bytes) |name, data| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    for ([_]u4{ 0b1111, 0b0001, 0b0011 }) |mask| {
        const config: *fontconfig.Config = @ptrCast(fontconfig.c.FcConfigCreate() orelse return error.OutOfMemory);
        defer config.destroy();
        const alias = "<?xml version=\"1.0\"?><!DOCTYPE fontconfig SYSTEM \"fonts.dtd\"><fontconfig><match target=\"pattern\"><test name=\"family\" compare=\"eq\"><string>GX Alias</string></test><edit name=\"family\" mode=\"assign\" binding=\"strong\"><string>JetBrains Mono</string></edit></match></fontconfig>";
        try testing.expect(fontconfig.c.FcConfigParseAndLoadFromMemory(config.cval(), alias, 1) != 0);
        for ([_]usize{ 4, 0, 1, 2, 3 }) |i| {
            if (i != 4 and mask & (@as(u4, 1) << @intCast(i)) == 0) continue;
            const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ root, names[i] }, 0);
            defer alloc.free(path);
            try testing.expect(fontconfig.c.FcConfigAppFontAddFile(config.cval(), path) != 0);
        }
        try testing.expect(fontconfig.c.FcConfigBuildFonts(config.cval()) != 0);
        var discovery: font.Discover = .{ .fc_config = config };
        var collection = font.Collection.init();
        defer collection.deinit(alloc);
        collection.load_options = .{ .library = library, .size = .{ .points = 13, .xdpi = 96, .ydpi = 96 } };
        _ = try collection.add(alloc, try font.Face.init(library, font.embedded.regular, collection.load_options.?.faceOptions()), .{ .style = .regular, .fallback = false, .size_adjustment = .none });
        try collection.updateMetrics();
        var state: mapped.State = .{};
        defer state.deinit(alloc);
        const descriptor: font.Descriptor = .{ .family = "GX Alias" };
        for ([_]font.Style{ .bold_italic, .bold, .italic, .regular }) |style| {
            const idx = (try state.resolveDescriptor(alloc, &collection, &discovery, descriptor, 'M', style)).?;
            const face = try collection.getFace(idx);
            const desired = mapped.Traits.fromStyle(style);
            const native: mapped.Traits = switch (mask) {
                0b1111 => desired,
                0b0011 => .{ .bold = desired.bold },
                else => .{},
            };
            try testing.expect(native.eql(try ft.traits(face)));
            try testing.expectEqual(desired.bold and !native.bold, face.synthetic.bold);
            try testing.expectEqual(desired.italic and !native.italic, face.synthetic.italic);
            try testing.expectEqualStrings("JetBrains Mono", std.mem.span(face.face.handle.*.family_name));
            const metrics = face.getMetrics();
            try testing.expect(metrics.cell_width > 0 and metrics.px_per_em > 0);
        }
        const regular = (try state.resolveDescriptor(alloc, &collection, &discovery, descriptor, 'M', .regular)).?;
        try testing.expect(!(try collection.getFace(regular)).synthetic.bold);
    }
}

test "gx.font_codepoint_map: Fontconfig variable named instances keep file index and actual axes" {
    if (font.options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);
    const config: *fontconfig.Config = @ptrCast(fontconfig.c.FcConfigCreate() orelse return error.OutOfMemory);
    defer config.destroy();
    for ([_][]const u8{ "variable.ttf", "variable-italic.ttf" }, [_][:0]const u8{ font.embedded.variable, font.embedded.variable_italic }) |name, bytes| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ root, name }, 0);
        defer alloc.free(path);
        try testing.expect(fontconfig.c.FcConfigAppFontAddFile(config.cval(), path) != 0);
    }
    try testing.expect(fontconfig.c.FcConfigBuildFonts(config.cval()) != 0);
    var discovery: font.Discover = .{ .fc_config = config };
    for ([_]font.Style{ .regular, .bold, .italic, .bold_italic }) |style| {
        var batch = try discovery.discoverMappedFamily(alloc, library, .{ .family = "JetBrains Mono" }, if (style == .regular) null else "JetBrains Mono", style);
        defer batch.deinit(alloc);
        try testing.expect(batch.candidates.items.len != 0);
        const candidate = &batch.candidates.items[0];
        try testing.expect(candidate.traits.eql(mapped.Traits.fromStyle(style)));
        try testing.expectEqual(@as(usize, 1), candidate.variations.len);
        const weight = candidate.variations[0].value;
        try testing.expectEqualStrings("wght", &candidate.variations[0].id.str());
        try testing.expectEqual(style == .bold or style == .bold_italic, weight >= 600);
        if (style == .bold or style == .bold_italic) try testing.expect(candidate.face_index >> 16 != 0);
        var face = try candidate.load(candidate, library, .{ .size = .{ .points = 13 } }, .{});
        defer face.deinit();
        try testing.expect(candidate.traits.eql(try ft.traits(&face)));
        try testing.expect(!face.synthetic.bold and !face.synthetic.italic);
        try testing.expectEqual(candidate.face_index, @as(i32, @intCast(face.face.handle.*.face_index)));
    }
}
