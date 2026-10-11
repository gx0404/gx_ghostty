const std = @import("std");
const font = @import("../font/main.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Descriptor = font.discovery.Descriptor;
const Style = font.Style;
const log = std.log.scoped(.gx_font_codepoint_map);

pub const Policy = packed struct(u8) {
    bold: bool = true,
    italic: bool = true,
    bold_italic: bool = true,
    synthetic_bold: bool = true,
    synthetic_italic: bool = true,
    synthetic_bold_italic: bool = true,
    padding: u2 = 0,

    pub fn fromConfig(config: anytype) Policy {
        return .{
            .bold = config.@"font-style-bold" != .false,
            .italic = config.@"font-style-italic" != .false,
            .bold_italic = config.@"font-style-bold-italic" != .false,
            .synthetic_bold = config.@"font-synthetic-style".bold,
            .synthetic_italic = config.@"font-synthetic-style".italic,
            .synthetic_bold_italic = config.@"font-synthetic-style".@"bold-italic",
        };
    }

    fn effective(self: Policy, style: Style) Style {
        return switch (style) {
            .regular => .regular,
            .bold => if (self.bold) .bold else .regular,
            .italic => if (self.italic) .italic else .regular,
            .bold_italic => if (self.bold_italic) .bold_italic else .regular,
        };
    }

    fn synthetic(self: Policy, style: Style) bool {
        return switch (style) {
            .regular => false,
            .bold => self.synthetic_bold,
            .italic => self.synthetic_italic,
            .bold_italic => self.synthetic_bold_italic,
        };
    }
};

pub const Traits = packed struct(u2) {
    bold: bool = false,
    italic: bool = false,

    pub fn fromStyle(style: Style) Traits {
        return .{ .bold = style == .bold or style == .bold_italic, .italic = style == .italic or style == .bold_italic };
    }

    pub fn eql(a: Traits, b: Traits) bool {
        return @as(u2, @bitCast(a)) == @as(u2, @bitCast(b));
    }

    fn missing(self: Traits, actual: Traits) Traits {
        return .{ .bold = self.bold and !actual.bold, .italic = self.italic and !actual.italic };
    }

    fn accepts(self: Traits, actual: Traits) bool {
        return (!actual.bold or self.bold) and (!actual.italic or self.italic);
    }
};

pub const Candidate = struct {
    source: union(enum) {
        deferred: font.DeferredFace,
        memory: struct { bytes: [:0]const u8, peek: font.Face },
    },
    traits: Traits,
    file: ?[:0]u8 = null,
    face_index: i32 = 0,
    variations: []const font.face.Variation = &.{},
    load: *const fn (*Candidate, font.Library, font.face.Options, Traits) anyerror!font.Face,
    indices: std.EnumArray(Style, ?font.Collection.Index) = .initFill(null),

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        switch (self.source) {
            .deferred => |*deferred| deferred.deinit(),
            .memory => |*memory| memory.peek.deinit(),
        }
        if (self.file) |file| alloc.free(file);
        alloc.free(self.variations);
    }

    fn hasCodepoint(self: *const Candidate, cp: u32) bool {
        return switch (self.source) {
            .deferred => |deferred| deferred.hasCodepoint(cp, null),
            .memory => |memory| memory.peek.glyphIndex(cp) != null,
        };
    }

    fn index(self: *Candidate, alloc: Allocator, collection: *font.Collection, family: []const u8, style: Style, synthetic: Traits) !font.Collection.Index {
        if (self.indices.get(style)) |idx| return idx;
        const opts = collection.load_options orelse return error.DeferredLoadingUnavailable;
        var face = try self.load(self, opts.library, opts.faceOptions(), synthetic);
        errdefer face.deinit();
        const idx = try collection.add(alloc, face, .{ .style = style, .fallback = false, .size_adjustment = font.default_fallback_adjustment });
        self.indices.set(style, idx);
        log.info("mapped face family={s} style={s} native-bold={} native-italic={} synthetic-bold={} synthetic-italic={} file={s} index=0x{X} axes={d}", .{
            family, @tagName(style), self.traits.bold, self.traits.italic, synthetic.bold, synthetic.italic, self.file orelse "<memory>", self.face_index, self.variations.len,
        });
        return idx;
    }
};

pub const Batch = struct {
    family: ?[:0]u8 = null,
    candidates: std.ArrayList(Candidate) = .empty,

    pub fn deinit(self: *Batch, alloc: Allocator) void {
        for (self.candidates.items) |*candidate| candidate.deinit(alloc);
        self.candidates.deinit(alloc);
        if (self.family) |family| alloc.free(family);
    }

    fn find(self: *Batch, alloc: Allocator, collection: *font.Collection, cp: u32, style: Style, synthesize: bool) !?font.Collection.Index {
        const desired = Traits.fromStyle(style);
        for (self.candidates.items) |*candidate| {
            if (style != .regular) {
                if (!synthesize and !desired.eql(candidate.traits)) continue;
                if (synthesize and !desired.accepts(candidate.traits)) continue;
            }
            if (!candidate.hasCodepoint(cp)) continue;
            const missing: Traits = if (synthesize) desired.missing(candidate.traits) else .{};
            if (!missing.eql(.{}) and candidate.load == legacyLoad) continue;
            const idx = candidate.index(alloc, collection, self.family orelse "", style, missing) catch |err| {
                if (err == error.OutOfMemory) return err;
                log.warn("mapped face load failed family={s} style={s} err={}", .{ self.family orelse "", @tagName(style), err });
                continue;
            };
            if (collection.hasCodepoint(idx, cp, .{ .any = {} })) return idx;
        }
        return null;
    }
};

const Request = struct { descriptor: Descriptor, style: Style };
const RequestContext = struct {
    pub fn hash(_: @This(), key: Request) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const descriptor = key.descriptor;
        const autoHash = std.hash.autoHash;
        std.hash.autoHashStrat(&hasher, descriptor.family, .Deep);
        std.hash.autoHashStrat(&hasher, descriptor.style, .Deep);
        autoHash(&hasher, descriptor.codepoint);
        autoHash(&hasher, @as(u32, @bitCast(descriptor.size)));
        autoHash(&hasher, descriptor.bold);
        autoHash(&hasher, descriptor.italic);
        autoHash(&hasher, descriptor.monospace);
        autoHash(&hasher, descriptor.variations.len);
        for (descriptor.variations) |variation| {
            autoHash(&hasher, variation.id);
            autoHash(&hasher, @as(u64, @bitCast(variation.value)));
        }
        autoHash(&hasher, key.style);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Request, b: Request) bool {
        if (a.style != b.style) return false;
        const x = a.descriptor;
        const y = b.descriptor;
        if (!optionalStringEqual(x.family, y.family) or !optionalStringEqual(x.style, y.style) or
            x.codepoint != y.codepoint or @as(u32, @bitCast(x.size)) != @as(u32, @bitCast(y.size)) or
            x.bold != y.bold or x.italic != y.italic or x.monospace != y.monospace or x.variations.len != y.variations.len) return false;
        for (x.variations, y.variations) |v, w| {
            if (@as(u32, @bitCast(v.id)) != @as(u32, @bitCast(w.id)) or @as(u64, @bitCast(v.value)) != @as(u64, @bitCast(w.value))) return false;
        }
        return true;
    }
};

fn optionalStringEqual(a: ?[:0]const u8, b: ?[:0]const u8) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u8, x, y) else false;
    return b == null;
}

pub const State = struct {
    policy: Policy = .{},
    requests: std.HashMapUnmanaged(Request, *Batch, RequestContext, std.hash_map.default_max_load_percentage) = .{},

    pub fn deinit(self: *State, alloc: Allocator) void {
        var it = self.requests.valueIterator();
        while (it.next()) |value| {
            value.*.deinit(alloc);
            alloc.destroy(value.*);
        }
        self.requests.deinit(alloc);
    }

    pub fn resolve(self: *State, alloc: Allocator, collection: *font.Collection, discover: anytype, map: font.CodepointMap, cp: u32, requested: Style) !?font.Collection.Index {
        const cp21 = std.math.cast(u21, cp) orelse return null;
        const descriptor = map.get(cp21) orelse return null;
        return try self.resolveDescriptor(alloc, collection, discover, descriptor, cp, requested);
    }

    fn batch(self: *State, alloc: Allocator, library: font.Library, discover: anytype, descriptor: Descriptor, style: Style, family: ?[:0]const u8) !*Batch {
        const key: Request = .{ .descriptor = descriptor, .style = style };
        if (self.requests.get(key)) |existing| return existing;
        var found: Batch = if (comptime @hasDecl(@typeInfo(@TypeOf(discover)).pointer.child, "discoverMappedFamily"))
            try discover.discoverMappedFamily(alloc, library, descriptor, family, style)
        else
            try legacyBatch(alloc, discover, descriptor, style);
        errdefer found.deinit(alloc);
        const result = try alloc.create(Batch);
        errdefer alloc.destroy(result);
        result.* = found;
        try self.requests.put(alloc, key, result);
        return result;
    }

    pub fn resolveDescriptor(self: *State, alloc: Allocator, collection: *font.Collection, discover: anytype, descriptor: Descriptor, cp: u32, requested: Style) !?font.Collection.Index {
        const library = (collection.load_options orelse return null).library;
        const style = self.policy.effective(requested);
        const regular = try self.batch(alloc, library, discover, descriptor, .regular, null);
        const family = regular.family orelse return null;
        if (style != .regular) {
            const native = try self.batch(alloc, library, discover, descriptor, style, family);
            if (try native.find(alloc, collection, cp, style, false)) |idx| return idx;
            if (try regular.find(alloc, collection, cp, style, false)) |idx| return idx;
            if (self.policy.synthetic(style)) {
                if (style == .bold_italic) {
                    for ([_]Style{ .bold, .italic }) |partial| {
                        const base = try self.batch(alloc, library, discover, descriptor, partial, family);
                        if (try base.find(alloc, collection, cp, style, true)) |idx| return idx;
                    }
                }
                if (try regular.find(alloc, collection, cp, style, true)) |idx| return idx;
            }
        }
        return try regular.find(alloc, collection, cp, .regular, false);
    }
};

fn legacyLoad(candidate: *Candidate, library: font.Library, opts: font.face.Options, synthetic: Traits) !font.Face {
    if (!synthetic.eql(.{})) return error.SyntheticUnavailable;
    return try candidate.source.deferred.load(library, opts);
}

fn legacyBatch(alloc: Allocator, discover: anytype, descriptor: Descriptor, style: Style) !Batch {
    if (style != .regular) return .{};
    var result: Batch = .{};
    errdefer result.deinit(alloc);
    var it = try discover.discover(alloc, descriptor);
    defer it.deinit();
    var deferred = (try it.next()) orelse return result;
    errdefer deferred.deinit();
    var buffer: [1024]u8 = undefined;
    result.family = try alloc.dupeZ(u8, try deferred.familyName(&buffer));
    try result.candidates.append(alloc, .{ .source = .{ .deferred = deferred }, .traits = .{}, .load = legacyLoad });
    return result;
}

test "gx.font_codepoint_map: Arial four native styles in either cache order" {
    if (font.options.backend != .freetype_windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var discover = font.Discover.init(lib);
    defer discover.deinit();
    try testing.expect(discover.api != null);
    var map: font.CodepointMap = .{};
    defer map.deinit(alloc);
    try map.add(alloc, .{ .range = .{ 'A', 'Z' }, .descriptor = .{ .family = "Arial" } });
    for ([_][4]font.Style{
        .{ .regular, .bold, .italic, .bold_italic },
        .{ .bold_italic, .italic, .bold, .regular },
    }) |order| {
        var collection = font.Collection.init();
        collection.load_options = .{ .library = lib, .size = .{ .points = 13, .xdpi = 96, .ydpi = 96 } };
        _ = try collection.add(alloc, try font.Face.init(lib, font.embedded.regular, collection.load_options.?.faceOptions()), .{ .style = .regular, .size_adjustment = .none, .fallback = false });
        try collection.updateMetrics();
        var resolver: font.CodepointResolver = .{ .collection = collection, .discover = &discover, .codepoint_map = map };
        defer resolver.deinit(alloc);
        for (order) |style| {
            const index = resolver.getIndex(alloc, 'A', style, null) orelse return error.MappedFontMissing;
            const face = try resolver.collection.getFace(index);
            const flags = face.face.handle.*.style_flags;
            try testing.expectEqual(style == .bold or style == .bold_italic, flags & 2 != 0);
            try testing.expectEqual(style == .italic or style == .bold_italic, flags & 1 != 0);
            try testing.expect(!face.synthetic.bold and !face.synthetic.italic);
            try testing.expectEqualStrings("Arial", std.mem.span(face.face.handle.*.family_name));
        }
    }
}

test "gx.font_codepoint_map: grid key separates disabled and synthetic policies" {
    const alloc = testing.allocator;
    var config = try @import("../config.zig").Config.default(alloc);
    defer config.deinit();
    var derived = try font.SharedGridSet.DerivedConfig.init(alloc, &config);
    defer derived.deinit();
    var first = try font.SharedGridSet.Key.init(alloc, &derived, .{ .points = 12 });
    defer first.deinit();
    inline for (.{ "font-style-bold", "font-style-italic", "font-style-bold-italic" }) |field| {
        @field(derived, field) = .false;
        var disabled = try font.SharedGridSet.Key.init(alloc, &derived, .{ .points = 12 });
        defer disabled.deinit();
        try testing.expect(first.hashcode() != disabled.hashcode());
        @field(derived, field) = @field(config, field);
    }
    inline for (.{ "bold", "italic", "bold-italic" }) |field| {
        @field(derived.@"font-synthetic-style", field) = false;
        var synthetic = try font.SharedGridSet.Key.init(alloc, &derived, .{ .points = 12 });
        defer synthetic.deinit();
        try testing.expect(first.hashcode() != synthetic.hashcode());
        @field(derived.@"font-synthetic-style", field) = true;
    }
    if (comptime font.face.FreetypeLoadFlags != void) {
        derived.@"freetype-load-flags".light = false;
        var load_flags = try font.SharedGridSet.Key.init(alloc, &derived, .{ .points = 12 });
        defer load_flags.deinit();
        try testing.expect(first.hashcode() != load_flags.hashcode());
    }
}

const FixtureProvider = struct {
    mask: u4 = 0b1111,
    calls: std.EnumArray(Style, usize) = .initFill(0),
    missing_first: bool = false,
    fail_once: bool = false,

    pub fn discoverMappedFamily(self: *@This(), alloc: Allocator, library: font.Library, descriptor: Descriptor, family: ?[:0]const u8, style: Style) !Batch {
        const ft = @import("font_map_freetype.zig");
        self.calls.getPtr(style).* += 1;
        if (self.fail_once) {
            self.fail_once = false;
            return error.OutOfMemory;
        }
        if (self.mask == 0) return .{};
        var result: Batch = .{ .family = try alloc.dupeZ(u8, family orelse "Fixture") };
        errdefer result.deinit(alloc);
        if (self.mask & (@as(u4, 1) << @intCast(@intFromEnum(style))) == 0) return result;
        if (self.missing_first) {
            var first = try ft.fromMemory(alloc, library, font.embedded.arabic, &.{});
            errdefer first.deinit(alloc);
            first.traits = Traits.fromStyle(style);
            try result.candidates.append(alloc, first);
        }
        const bytes = switch (style) {
            .regular => font.embedded.regular,
            .bold => font.embedded.bold,
            .italic => font.embedded.italic,
            .bold_italic => font.embedded.bold_italic,
        };
        var candidate = try ft.fromMemory(alloc, library, bytes, descriptor.variations);
        errdefer candidate.deinit(alloc);
        try result.candidates.append(alloc, candidate);
        return result;
    }
};

fn testCollection(alloc: Allocator, library: font.Library) !font.Collection {
    var collection = font.Collection.init();
    errdefer collection.deinit(alloc);
    collection.load_options = .{ .library = library, .size = .{ .points = 13, .xdpi = 96, .ydpi = 96 } };
    var face = try font.Face.init(library, font.embedded.regular, collection.load_options.?.faceOptions());
    _ = collection.add(alloc, face, .{ .style = .regular, .size_adjustment = .none, .fallback = false }) catch |err| {
        face.deinit();
        return err;
    };
    try collection.updateMetrics();
    return collection;
}

fn expectTraits(collection: *font.Collection, idx: font.Collection.Index, native: Traits, synthetic: Traits) !void {
    const ft = @import("font_map_freetype.zig");
    const face = try collection.getFace(idx);
    try testing.expect(native.eql(try ft.traits(face)));
    try testing.expectEqual(synthetic.bold, face.synthetic.bold);
    try testing.expectEqual(synthetic.italic, face.synthetic.italic);
    const metrics = face.getMetrics();
    try testing.expect(metrics.px_per_em > 0 and metrics.cell_width > 0);
}

test "gx.font_codepoint_map: native faces ignore synthetic switches and disabled styles normalize" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    for ([_]Policy{
        .{},
        .{ .synthetic_bold = false, .synthetic_italic = false, .synthetic_bold_italic = false },
        .{ .bold = false, .italic = false, .bold_italic = false },
    }) |policy| {
        var collection = try testCollection(alloc, library);
        defer collection.deinit(alloc);
        var state: State = .{ .policy = policy };
        defer state.deinit(alloc);
        var provider: FixtureProvider = .{};
        for ([_]Style{ .regular, .bold, .italic, .bold_italic }) |style| {
            const idx = (try state.resolveDescriptor(alloc, &collection, &provider, .{ .family = "Fixture" }, 'A', style)).?;
            try expectTraits(&collection, idx, Traits.fromStyle(policy.effective(style)), .{});
        }
    }
}

test "gx.font_codepoint_map: independent synthetic switches and partial native bold italic" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    for ([_]Policy{
        .{},
        .{ .synthetic_bold = false, .synthetic_italic = false, .synthetic_bold_italic = false },
        .{ .synthetic_bold = true, .synthetic_italic = false, .synthetic_bold_italic = false },
        .{ .synthetic_bold = false, .synthetic_italic = true, .synthetic_bold_italic = false },
        .{ .synthetic_bold = false, .synthetic_italic = false, .synthetic_bold_italic = true },
    }) |policy| {
        var collection = try testCollection(alloc, library);
        defer collection.deinit(alloc);
        var state: State = .{ .policy = policy };
        defer state.deinit(alloc);
        var provider: FixtureProvider = .{ .mask = 1 };
        for ([_]Style{ .bold_italic, .italic, .bold, .regular }) |style| {
            const idx = (try state.resolveDescriptor(alloc, &collection, &provider, .{ .family = "Fixture" }, 'A', style)).?;
            try expectTraits(&collection, idx, .{}, if (policy.synthetic(style)) Traits.fromStyle(style) else .{});
        }
    }
    for ([_]u4{ 0b0011, 0b0101, 0b1001 }) |mask| {
        var collection = try testCollection(alloc, library);
        defer collection.deinit(alloc);
        var state: State = .{ .policy = .{ .synthetic_bold = false, .synthetic_italic = false } };
        defer state.deinit(alloc);
        var provider: FixtureProvider = .{ .mask = mask };
        const idx = (try state.resolveDescriptor(alloc, &collection, &provider, .{ .family = "Fixture" }, 'A', .bold_italic)).?;
        const actual: Traits = if (mask == 0b0011) .{ .bold = true } else if (mask == 0b0101) .{ .italic = true } else .{ .bold = true, .italic = true };
        try expectTraits(&collection, idx, actual, Traits.fromStyle(.bold_italic).missing(actual));
    }
}

test "gx.font_codepoint_map: synthetic faces own handles sizes and mutexes" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var collection = try testCollection(alloc, library);
    defer collection.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);
    var provider: FixtureProvider = .{ .mask = 1 };
    const desc: Descriptor = .{ .family = "Fixture" };
    const regular_idx = (try state.resolveDescriptor(alloc, &collection, &provider, desc, 'A', .regular)).?;
    const regular = try collection.getFace(regular_idx);
    const size = regular.size;
    const metrics = regular.getMetrics();
    for ([_]Style{ .bold, .italic, .bold_italic }) |style| {
        const idx = (try state.resolveDescriptor(alloc, &collection, &provider, desc, 'A', style)).?;
        const face = try collection.getFace(idx);
        try testing.expect(face.face.handle != regular.face.handle);
        try testing.expect(face.ft_mutex != regular.ft_mutex);
        try face.setSize(.{ .size = .{ .points = 28, .xdpi = 144, .ydpi = 144 } });
        try testing.expectEqual(size, regular.size);
        try testing.expectEqual(metrics, regular.getMetrics());
        try testing.expect(!regular.synthetic.bold and !regular.synthetic.italic);
    }
}

test "gx.font_codepoint_map: missing glyph continues candidates and misses are per style" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var collection = try testCollection(alloc, library);
    defer collection.deinit(alloc);
    var state: State = .{ .policy = .{ .synthetic_bold = false, .synthetic_italic = false, .synthetic_bold_italic = false } };
    defer state.deinit(alloc);
    var provider: FixtureProvider = .{ .mask = 0b0011, .missing_first = true };
    const desc: Descriptor = .{ .family = "Fixture" };
    const batch_regular = try state.batch(alloc, library, &provider, desc, .regular, null);
    var cp: u32 = 0;
    for (0x20..0x300) |candidate_cp| {
        const value: u32 = @intCast(candidate_cp);
        if (!batch_regular.candidates.items[0].hasCodepoint(value) and batch_regular.candidates.items[1].hasCodepoint(value)) {
            cp = value;
            break;
        }
    }
    try testing.expect(cp != 0);
    const bold_idx = (try state.resolveDescriptor(alloc, &collection, &provider, desc, cp, .bold)).?;
    try expectTraits(&collection, bold_idx, .{ .bold = true }, .{});
    _ = try state.resolveDescriptor(alloc, &collection, &provider, desc, cp, .italic);
    _ = try state.resolveDescriptor(alloc, &collection, &provider, desc, cp + 1, .italic);
    _ = try state.resolveDescriptor(alloc, &collection, &provider, desc, cp, .bold_italic);
    try testing.expectEqual(@as(usize, 1), provider.calls.get(.bold));
    try testing.expectEqual(@as(usize, 1), provider.calls.get(.italic));
    try testing.expectEqual(@as(usize, 1), provider.calls.get(.bold_italic));
    var absent: FixtureProvider = .{ .mask = 0 };
    try testing.expect(try state.resolveDescriptor(alloc, &collection, &absent, .{ .family = "Absent" }, cp, .bold) == null);
    try testing.expect(try state.resolveDescriptor(alloc, &collection, &absent, .{ .family = "Absent" }, cp + 1, .italic) == null);
    try testing.expectEqual(@as(usize, 1), absent.calls.get(.regular));
}

test "gx.font_codepoint_map: allocation and loading failures do not cache missing fonts" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var collection = try testCollection(alloc, library);
    defer collection.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);
    var provider: FixtureProvider = .{ .fail_once = true };
    const desc: Descriptor = .{ .family = "Fixture" };
    try testing.expectError(error.OutOfMemory, state.resolveDescriptor(alloc, &collection, &provider, desc, 'A', .bold));
    try testing.expectEqual(@as(u32, 0), state.requests.count());
    var failing: testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, state.resolveDescriptor(failing.allocator(), &collection, &provider, desc, 'A', .bold));
    try testing.expectEqual(@as(u32, 0), state.requests.count());
    const idx = (try state.resolveDescriptor(alloc, &collection, &provider, desc, 'A', .bold)).?;
    try expectTraits(&collection, idx, .{ .bold = true }, .{});
    const regular = try state.batch(alloc, library, &provider, desc, .regular, null);
    const saved_load = regular.candidates.items[0].load;
    regular.candidates.items[0].load = struct {
        fn fail(_: *Candidate, _: font.Library, _: font.face.Options, _: Traits) anyerror!font.Face {
            return error.OutOfMemory;
        }
    }.fail;
    try testing.expectError(error.OutOfMemory, state.resolveDescriptor(alloc, &collection, &provider, desc, 'A', .regular));
    regular.candidates.items[0].load = saved_load;
    try testing.expect(try state.resolveDescriptor(alloc, &collection, &provider, desc, 'A', .regular) != null);
}

test "gx.font_codepoint_map: descriptor equality checks content even on hash collision" {
    const ctx: RequestContext = .{};
    const x: Request = .{ .style = .bold, .descriptor = .{ .family = "Fixture", .variations = &.{.{ .id = .init("wght"), .value = 450.25 }} } };
    const y: Request = .{ .style = .bold, .descriptor = .{ .family = "Fixture", .variations = &.{.{ .id = .init("wght"), .value = 450.75 }} } };
    try testing.expect(!ctx.eql(x, y));
    try testing.expect(x.descriptor.hashcode() == y.descriptor.hashcode());
    try testing.expect(ctx.hash(x) != ctx.hash(y));
    const ConstantContext = struct {
        pub fn hash(_: @This(), _: Request) u64 {
            return 1;
        }
        pub fn eql(_: @This(), a: Request, b: Request) bool {
            return RequestContext.eql(.{}, a, b);
        }
    };
    var map: std.HashMapUnmanaged(Request, u8, ConstantContext, std.hash_map.default_max_load_percentage) = .{};
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, x, 1);
    try map.put(testing.allocator, y, 2);
    var z = x;
    z.style = .italic;
    try map.put(testing.allocator, z, 3);
    try testing.expectEqual(@as(u32, 3), map.count());
    try testing.expectEqual(@as(u8, 1), map.get(x).?);
    try testing.expectEqual(@as(u8, 2), map.get(y).?);
    const duplicated = try testing.allocator.dupeZ(u8, "Fixture");
    defer testing.allocator.free(duplicated);
    var copy = x;
    copy.descriptor.family = duplicated;
    try testing.expect(ctx.eql(x, copy));
}

test "gx.font_codepoint_map: unmapped sprites and overlapping mappings keep priority" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var collection = try testCollection(alloc, library);
    defer collection.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);
    var provider: FixtureProvider = .{};
    var map: font.CodepointMap = .{};
    defer map.deinit(alloc);
    try map.add(alloc, .{ .range = .{ 'A', 'C' }, .descriptor = .{ .family = "Old" } });
    try map.add(alloc, .{ .range = .{ 'A', 'B' }, .descriptor = .{ .family = "New" } });
    try testing.expect(try state.resolve(alloc, &collection, &provider, map, 'Z', .bold) == null);
    try testing.expect(try state.resolve(alloc, &collection, &provider, map, 0x110000, .bold) == null);
    try testing.expect(try state.resolve(alloc, &collection, &provider, map, 'A', .bold) != null);
    try testing.expectEqual(@as(u32, 2), state.requests.count());
    try testing.expect(state.requests.get(.{ .descriptor = .{ .family = "Old" }, .style = .regular }) == null);
    try testing.expect(try state.resolve(alloc, &collection, &provider, map, 'C', .regular) != null);
}

test "gx.font_codepoint_map: variable axes preserve native weight and decimal identity" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    const ft = @import("font_map_freetype.zig");
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    for ([_]f64{ 400.25, 700.75 }) |weight| {
        var candidate = try ft.fromMemory(alloc, library, font.embedded.variable, &.{.{ .id = .init("wght"), .value = weight }});
        defer candidate.deinit(alloc);
        try testing.expectEqual(weight >= 600, candidate.traits.bold);
        try testing.expectEqual(weight, candidate.variations[0].value);
        var face = try candidate.load(&candidate, library, .{ .size = .{ .points = 13 } }, .{});
        defer face.deinit();
        try testing.expect(candidate.traits.eql(try ft.traits(&face)));
        const mm = try face.face.getMMVar();
        defer library.lib.doneMMVar(mm);
        var coords: [32]@import("freetype").c.FT_Fixed = undefined;
        try face.face.getVarDesignCoordinates(coords[0..mm.num_axis]);
        for (coords[0..mm.num_axis], 0..) |coord, i| {
            if (@as(u32, @truncate(mm.axis[i].tag)) == @as(u32, @bitCast(font.face.Variation.Id.init("wght")))) try testing.expectEqual(weight, @as(f64, @floatFromInt(coord)) / 65536.0);
        }
    }
}

fn allocationScenario(alloc: Allocator) !void {
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var collection = try testCollection(alloc, library);
    defer collection.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);
    var provider: FixtureProvider = .{ .mask = 1 };
    _ = try state.resolveDescriptor(alloc, &collection, &provider, .{ .family = "Fixture" }, 'A', .bold_italic);
    _ = try state.resolveDescriptor(alloc, &collection, &provider, .{ .family = "Fixture" }, 'B', .regular);
}

test "gx.font_codepoint_map: every allocation failure releases candidates and owned faces" {
    if (!font.options.backend.hasFreetype()) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "gx.font_codepoint_map: backend without discovery preserves regular fallback" {
    if (font.Discover != void or !font.options.backend.hasFreetype()) return error.SkipZigTest;
    const alloc = testing.allocator;
    var library = try font.Library.init(alloc);
    defer library.deinit();
    var map: font.CodepointMap = .{};
    defer map.deinit(alloc);
    try map.add(alloc, .{ .range = .{ 'A', 'Z' }, .descriptor = .{ .family = "Unavailable" } });
    var resolver: font.CodepointResolver = .{ .collection = try testCollection(alloc, library), .codepoint_map = map };
    defer resolver.deinit(alloc);
    for ([_]Style{ .regular, .bold, .italic, .bold_italic }) |style| {
        const index = resolver.getIndex(alloc, 'A', style, null).?;
        try testing.expectEqual(@as(u16, 0), index.int());
    }
    try testing.expectEqual(@as(u32, 0), resolver.descriptor_cache.requests.count());
}
