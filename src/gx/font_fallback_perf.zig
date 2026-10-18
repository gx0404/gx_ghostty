//! C6: ordinary CJK fallback through the first uncached raster and atlas write.
//! State belongs to one SharedGrid lifetime; no registry retains grid pointers.
//! Grid exclusive locking protects identity fields. Shared cache hits can only
//! atomically reject, never bind or complete. The process claim is never reset.
//! Only the fixed single-codepoint C6 stimulus can establish text identity;
//! this is not a general cluster timer and does not include GPU upload/present.
const std = @import("std");
const perf = @import("perf.zig");
const global = @import("../global.zig");

const prefix = "font.first_cjk_fallback.";
const target: u32 = 0x4E2D;
var claimed: std.atomic.Value(bool) = .init(false);
threadlocal var resolving: ?*State = null;

const Phase = enum(u8) { idle, discovering, loading, waiting, rejected, complete };
const Reason = enum(u8) {
    wrong_codepoint = 1,
    discovery_failed,
    face_failed,
    missing_glyph,
    codepoint_alias,
    thread_mismatch,
    glyph_mismatch,
    cached,
    raster_failed,
    empty_glyph,
    atlas_unavailable,
    repeated_lookup,
    grid_mismatch,
    font_mismatch,
};

/// Embedded in a grid, initialized with it and discarded with it. Never copied
/// after publication. Grid/collection addresses are checked only while alive.
pub const State = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    resolver: usize = 0,
    grid: usize = 0,
    cp: u32 = 0,
    index: u16 = 0,
    glyph: u32 = 0,
    thread: std.Thread.Id = 0,
    start: perf.Instant = .zero,

    fn begin(self: *State, on: bool, once: *std.atomic.Value(bool), cp: u32, thread: std.Thread.Id, start: perf.Instant) bool {
        if (!on or !isCjk(cp) or self.phase.load(.acquire) != .idle) return false;
        if (once.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return false;
        self.cp = cp;
        self.thread = thread;
        self.start = start;
        self.phase.store(.discovering, .release);
        return true;
    }

    fn reject(self: *State) bool {
        var old = self.phase.load(.acquire);
        while (old == .discovering or old == .loading or old == .waiting) {
            old = self.phase.cmpxchgStrong(old, .rejected, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    fn bindIndex(self: *State, index: u16) void {
        if (self.phase.load(.acquire) != .discovering) return;
        self.index = index;
        self.phase.store(.loading, .release);
    }

    fn bindGlyph(self: *State, index: u16, glyph: ?u32) bool {
        if (self.phase.load(.acquire) != .loading or self.index != index) return false;
        self.glyph = glyph orelse 0;
        if (self.glyph == 0) return false;
        self.phase.store(.waiting, .release);
        return true;
    }

    fn observe(self: *State, cp: u32, index: ?u16, thread: std.Thread.Id, fresh: bool) ?Reason {
        if (self.phase.load(.acquire) != .waiting or index != self.index) return null;
        if (thread != self.thread) return .thread_mismatch;
        if (cp != self.cp) return .codepoint_alias;
        if (!fresh) return .repeated_lookup;
        return null;
    }

    fn match(self: *State, grid: usize, index: u16, glyph: u32, thread: std.Thread.Id, cached: bool) ?Reason {
        if (self.phase.load(.acquire) != .waiting) return null;
        if (grid != self.grid) return .grid_mismatch;
        if (index != self.index) return .font_mismatch;
        if (thread != self.thread) return .thread_mismatch;
        if (glyph != self.glyph) return .glyph_mismatch;
        if (cached) return .cached;
        return null;
    }

    fn complete(self: *State, now: perf.Instant) ?u64 {
        if (self.phase.cmpxchgStrong(.waiting, .complete, .acq_rel, .acquire) != null) return null;
        return perf.elapsedUs(self.start, now);
    }
};

fn isCjk(cp: u32) bool {
    return (cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0x20000 and cp <= 0x323AF);
}

fn reject(state: *State, reason: Reason) void {
    if (state.reject()) perf.count(prefix ++ "rejected", @intFromEnum(reason));
}

/// A stack-scoped bridge from SharedGrid.getIndex to recursive resolver calls.
/// It is thread-local, restored on every exit, and never outlives the call.
pub const Scope = struct {
    state: ?*State = null,
    previous: ?*State = null,

    pub fn end(self: Scope) void {
        const state = self.state orelse return;
        switch (state.phase.load(.acquire)) {
            .discovering => reject(state, .discovery_failed),
            .loading => reject(state, .face_failed),
            else => {},
        }
        resolving = self.previous;
    }
};

/// Called under the grid exclusive lock, before invoking the resolver.
pub fn enter(state: *State, grid: anytype) Scope {
    if (!perf.enabled()) return .{};
    const previous = resolving;
    if (state.phase.load(.acquire) == .idle) {
        state.grid = @intFromPtr(grid);
        state.resolver = @intFromPtr(&grid.resolver);
    }
    resolving = state;
    return .{ .state = state, .previous = previous };
}

/// Called only at the ordinary discovery boundary, before discoverFallback.
pub fn discoveryBegin(resolver: anytype, cp: u32) ?*State {
    if (!perf.enabled() or !isCjk(cp)) return null;
    const state = resolving orelse return null;
    if (state.resolver != @intFromPtr(resolver)) return null;
    // A failed mapped lookup must not be relabelled as an ordinary user path.
    if (resolver.codepoint_map) |map| if (map.get(@intCast(cp)) != null) return null;
    if (claimed.load(.acquire)) return null;
    if (!state.begin(true, &claimed, cp, std.Thread.getCurrentId(), perf.now(global.io()))) return null;
    perf.count(prefix ++ "started", 1);
    perf.count(prefix ++ "codepoint", cp);
    if (cp != target) reject(state, .wrong_codepoint);
    return state;
}

pub fn discoveryIndex(state: ?*State, index: anytype) void {
    if (state) |s| s.bindIndex(index.int());
}

pub fn discoveryEnd(state: ?*State) void {
    if (state) |s| if (s.phase.load(.acquire) == .discovering) reject(s, .discovery_failed);
}

/// No face operations at all unless this exact request owns the active claim.
pub fn faceReady(state: *State, cp: u32, index: anytype, face: anytype) void {
    if (!perf.enabled() or state.phase.load(.acquire) != .loading) return;
    if (state.cp != cp or state.index != index.int()) {
        reject(state, .codepoint_alias);
        return;
    }
    if (!state.bindGlyph(index.int(), face.glyphIndex(cp))) {
        reject(state, .missing_glyph);
        return;
    }
    perf.count(prefix ++ "request", 1);
    perf.count(prefix ++ "grid", 1); // Process-once lifetime token, not a reusable address.
    perf.count(prefix ++ "font_index", state.index);
    perf.count(prefix ++ "glyph", state.glyph);
    perf.count(prefix ++ "bound", 1);
}

/// Runs under either grid lock. It only reads immutable identity and may reject.
pub fn indexObserved(state: *State, cp: u32, index: anytype, fresh: bool) void {
    if (!perf.enabled()) return;
    const n: ?u16 = if (index) |i| i.int() else null;
    if (state.observe(cp, n, std.Thread.getCurrentId(), fresh)) |reason| reject(state, reason);
}

/// The fixed stimulus puts CJK alone on a row, so no earlier Latin run should
/// render after binding. Any grid/font/glyph mismatch consumes the candidate;
/// a later matching glyph cannot repair an ambiguous rendering sequence.
pub fn rasterBegin(state: *State, grid: anytype, index: anytype, glyph: u32, cached: bool) bool {
    if (!perf.enabled()) return false;
    if (state.match(@intFromPtr(grid), index.int(), glyph, std.Thread.getCurrentId(), cached)) |reason| {
        reject(state, reason);
        return false;
    }
    return @intFromPtr(grid) == state.grid and state.phase.load(.acquire) == .waiting and
        state.index == index.int() and state.glyph == glyph;
}

pub fn rasterFailed(state: *State, active: bool) void {
    if (active) reject(state, .raster_failed);
}

/// Called after the cache write, still under the exclusive grid lock, after any
/// AtlasFull grow/retry. No successful timing exists for an empty/invalid bitmap.
pub fn rasterReady(state: *State, active: bool, glyph: anytype, atlas: anytype) void {
    if (!active) return;
    if (glyph.width == 0 or glyph.height == 0) {
        reject(state, .empty_glyph);
        return;
    }
    if (@as(u64, glyph.atlas_x) + glyph.width > atlas.size or
        @as(u64, glyph.atlas_y) + glyph.height > atlas.size or atlas.data.len == 0)
    {
        reject(state, .atlas_unavailable);
        return;
    }
    const us = state.complete(perf.now(global.io())) orelse return;
    perf.record(prefix ++ "raster_ready", us);
    perf.count(prefix ++ "completed", 1);
}

test "gx.font_fallback_perf disabled and non CJK never claim" {
    var once: std.atomic.Value(bool) = .init(false);
    var s: State = .{};
    try std.testing.expect(!s.begin(false, &once, target, 1, .zero));
    try std.testing.expect(!s.begin(true, &once, 'A', 1, .zero));
    try std.testing.expect(!once.load(.acquire));
}

test "gx.font_fallback_perf success includes loading scheduling and retry time exactly once" {
    var once: std.atomic.Value(bool) = .init(false);
    var s: State = .{ .grid = 10 };
    try std.testing.expect(s.begin(true, &once, target, 1, .{ .nanoseconds = 1000 }));
    s.bindIndex(7);
    try std.testing.expect(s.bindGlyph(7, 99));
    try std.testing.expectEqual(@as(?Reason, null), s.match(10, 7, 99, 1, false));
    // AtlasFull does not complete or restart the span. The retry ends at 9us.
    try std.testing.expectEqual(Phase.waiting, s.phase.load(.acquire));
    try std.testing.expectEqual(@as(?u64, 8), s.complete(.{ .nanoseconds = 9000 }));
    try std.testing.expectEqual(@as(?u64, null), s.complete(.{ .nanoseconds = 10000 }));
}

test "gx.font_fallback_perf rejection is terminal and cannot close on the next glyph" {
    for ([_]Reason{ .discovery_failed, .face_failed, .glyph_mismatch, .cached, .raster_failed, .empty_glyph, .atlas_unavailable }) |_| {
        var once: std.atomic.Value(bool) = .init(false);
        var s: State = .{};
        try std.testing.expect(s.begin(true, &once, target, 1, .zero));
        s.bindIndex(7);
        try std.testing.expect(s.bindGlyph(7, 99));
        try std.testing.expect(s.reject());
        try std.testing.expect(!s.reject());
        try std.testing.expectEqual(@as(?u64, null), s.complete(.{ .nanoseconds = 9000 }));
        try std.testing.expect(!s.begin(true, &once, target, 1, .zero));
    }
}

test "gx.font_fallback_perf grid reuse and competing grids cannot steal process claim" {
    var once: std.atomic.Value(bool) = .init(false);
    var old: State = .{ .grid = 10 };
    try std.testing.expect(old.begin(true, &once, target, 1, .zero));
    // The old object may die unfinished. Even at the same address a new grid
    // starts idle and cannot use the old request's index/glyph or restart once.
    var replacement: State = .{ .grid = 10 };
    try std.testing.expect(!replacement.begin(true, &once, target, 1, .zero));
    try std.testing.expectEqual(@as(?u64, null), replacement.complete(.zero));
    var other: State = .{ .grid = 20 };
    try std.testing.expect(!other.begin(true, &once, target, 2, .zero));
}

test "gx.font_fallback_perf identity rejects aliases threads shaped mismatch and cache" {
    var once: std.atomic.Value(bool) = .init(false);
    var s: State = .{ .grid = 10 };
    _ = s.begin(true, &once, target, 1, .zero);
    s.bindIndex(7);
    try std.testing.expect(!s.bindGlyph(8, 99));
    try std.testing.expect(!s.bindGlyph(7, null));
    try std.testing.expect(!s.bindGlyph(7, 0));
    try std.testing.expect(s.bindGlyph(7, 99));
    try std.testing.expectEqual(Reason.codepoint_alias, s.observe(target + 1, 7, 1, false).?);
    try std.testing.expectEqual(Reason.thread_mismatch, s.observe(target, 7, 2, false).?);
    try std.testing.expectEqual(Reason.repeated_lookup, s.observe(target, 7, 1, false).?);
    try std.testing.expectEqual(Reason.glyph_mismatch, s.match(10, 7, 100, 1, false).?);
    try std.testing.expectEqual(Reason.cached, s.match(10, 7, 99, 1, true).?);
    try std.testing.expectEqual(Reason.thread_mismatch, s.match(10, 7, 99, 2, false).?);
    try std.testing.expectEqual(Reason.grid_mismatch, s.match(20, 7, 99, 1, false).?);
    try std.testing.expectEqual(Reason.font_mismatch, s.match(10, 8, 99, 1, false).?);
}

// Tests below exercise the actual SharedGrid hooks, not just State methods.
fn testGrid(lib: @import("../font/main.zig").Library) !@import("../font/main.zig").SharedGrid {
    const font = @import("../font/main.zig");
    const alloc = std.testing.allocator;
    var collection = font.Collection.init();
    errdefer collection.deinit(alloc);
    collection.load_options = .{ .library = lib };
    _ = try collection.add(alloc, try .init(lib, font.embedded.regular, .{
        .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 },
    }), .{ .style = .regular, .fallback = false, .size_adjustment = .none });
    return try font.SharedGrid.init(alloc, .{ .collection = collection });
}

test "gx.font_fallback_perf actual isolated CJK shaping raster and AtlasFull retry" {
    const font = @import("../font/main.zig");
    if (comptime font.options.backend != .freetype_windows) return error.SkipZigTest;
    const terminal = @import("../terminal/main.zig");
    const alloc = std.testing.allocator;
    const before = perf.enabled();
    const prior_claim = claimed.swap(false, .acq_rel);
    defer perf.setEnabled(before);
    defer claimed.store(prior_claim, .release);
    perf.setEnabled(true);
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var disco = font.Discover.init(lib);
    defer disco.deinit();
    var grid = try testGrid(lib);
    defer grid.deinit(alloc);
    grid.resolver.discover = &disco;

    var term = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 3 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("中\r\n");
    var screen: terminal.RenderState = .empty;
    defer screen.deinit(alloc);
    try screen.update(alloc, &term);
    var shaper = try font.Shaper.init(alloc, .{});
    defer shaper.deinit();
    var it = shaper.runIterator(.{ .grid = &grid, .cells = screen.row_data.get(0).cells.slice() });
    const run = (try it.next(alloc)).?;
    try std.testing.expectEqual(Phase.waiting, grid.fallback_timing.phase.load(.acquire));
    try std.testing.expectEqual(target, grid.fallback_timing.cp);
    const cells = try shaper.shape(run);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqual(grid.fallback_timing.glyph, cells[0].glyph_index);
    // Fill the real atlas. SharedGrid must grow and retry before completing.
    const size = grid.atlas_grayscale.size;
    _ = try grid.atlas_grayscale.reserve(alloc, size - 2, size - 2);
    const result = try grid.renderGlyph(alloc, run.font_index, cells[0].glyph_index, .{ .grid_metrics = grid.metrics });
    try std.testing.expect(result.glyph.width > 0 and result.glyph.height > 0);
    try std.testing.expectEqual(size * 2, grid.atlas_grayscale.size);
    try std.testing.expectEqual(Phase.complete, grid.fallback_timing.phase.load(.acquire));
    _ = try grid.renderGlyph(alloc, run.font_index, cells[0].glyph_index, .{ .grid_metrics = grid.metrics });
    try std.testing.expectEqual(Phase.complete, grid.fallback_timing.phase.load(.acquire));
    try std.testing.expect(resolving == null);
}

test "gx.font_fallback_perf real raster and atlas grow errors cannot close on retry" {
    const font = @import("../font/main.zig");
    const alloc = std.testing.allocator;
    const before = perf.enabled();
    defer perf.setEnabled(before);
    for ([_]bool{ false, true }) |grow_failure| {
        perf.setEnabled(false);
        var lib = try font.Library.init(alloc);
        defer lib.deinit();
        var grid = try testGrid(lib);
        defer grid.deinit(alloc);
        const idx = (try grid.getIndex(alloc, 'A', .regular, null)).?;
        const face = try grid.resolver.collection.getFace(idx);
        const glyph = face.glyphIndex('A').?;
        // Inject identity to isolate raster errors from system discovery.
        var once: std.atomic.Value(bool) = .init(false);
        grid.fallback_timing.grid = @intFromPtr(&grid);
        _ = grid.fallback_timing.begin(true, &once, target, std.Thread.getCurrentId(), .zero);
        grid.fallback_timing.bindIndex(idx.int());
        try std.testing.expect(grid.fallback_timing.bindGlyph(idx.int(), glyph));
        perf.setEnabled(true);
        const tw = font.SharedGrid.renderGlyph_tw;
        const grow_tw = font.Atlas.grow_tw;
        defer tw.reset();
        defer grow_tw.reset();
        if (grow_failure) {
            const size = grid.atlas_grayscale.size;
            _ = try grid.atlas_grayscale.reserve(alloc, size - 2, size - 2);
            grow_tw.errorAlways(.alloc_data, error.OutOfMemory);
        } else {
            tw.errorAlways(.get_presentation, error.OutOfMemory);
        }
        try std.testing.expectError(error.OutOfMemory, grid.renderGlyph(alloc, idx, glyph, .{ .grid_metrics = grid.metrics }));
        try std.testing.expectEqual(Phase.rejected, grid.fallback_timing.phase.load(.acquire));
        if (grow_failure) try grow_tw.end(.reset) else try tw.end(.reset);
        _ = try grid.renderGlyph(alloc, idx, glyph, .{ .grid_metrics = grid.metrics });
        try std.testing.expectEqual(Phase.rejected, grid.fallback_timing.phase.load(.acquire));
    }
}

test "gx.font_fallback_perf real cache hits empty glyph and failed shaping stay terminal" {
    const font = @import("../font/main.zig");
    const alloc = std.testing.allocator;
    const before = perf.enabled();
    defer perf.setEnabled(before);
    for ([_]u8{ 0, 1, 2 }) |scenario| {
        perf.setEnabled(false);
        var lib = try font.Library.init(alloc);
        defer lib.deinit();
        var grid = try testGrid(lib);
        defer grid.deinit(alloc);
        const cp: u32 = if (scenario == 1) ' ' else 'A';
        const idx = (try grid.getIndex(alloc, cp, .regular, null)).?;
        const face = try grid.resolver.collection.getFace(idx);
        const glyph = face.glyphIndex(cp).?;
        if (scenario == 0) _ = try grid.renderGlyph(alloc, idx, glyph, .{ .grid_metrics = grid.metrics });
        var once: std.atomic.Value(bool) = .init(false);
        grid.fallback_timing.grid = @intFromPtr(&grid);
        _ = grid.fallback_timing.begin(true, &once, target, std.Thread.getCurrentId(), .zero);
        grid.fallback_timing.cp = cp; // Isolate cached lookup cancellation.
        grid.fallback_timing.bindIndex(idx.int());
        try std.testing.expect(grid.fallback_timing.bindGlyph(idx.int(), glyph));
        perf.setEnabled(true);
        // A shaping failure/empty run has no raster callback. Its next lookup
        // must cancel, rather than letting a later frame complete the old span.
        if (scenario == 2) _ = try grid.getIndex(alloc, cp, .regular, null);
        _ = try grid.renderGlyph(alloc, idx, glyph, .{ .grid_metrics = grid.metrics });
        try std.testing.expectEqual(Phase.rejected, grid.fallback_timing.phase.load(.acquire));
        _ = try grid.renderGlyph(alloc, idx, glyph, .{ .grid_metrics = grid.metrics });
        try std.testing.expectEqual(Phase.rejected, grid.fallback_timing.phase.load(.acquire));
    }
}

test "gx.font_fallback_perf scope restores and mapped fallback cannot claim" {
    const font = @import("../font/main.zig");
    const alloc = std.testing.allocator;
    const before = perf.enabled();
    const prior_claim = claimed.swap(false, .acq_rel);
    defer perf.setEnabled(before);
    defer claimed.store(prior_claim, .release);
    perf.setEnabled(true);
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var grid = try testGrid(lib);
    defer grid.deinit(alloc);
    var map: font.CodepointMap = .{};
    defer map.deinit(alloc);
    try map.add(alloc, .{ .range = .{ target, target }, .descriptor = .{ .family = "Missing Test Family" } });
    grid.resolver.codepoint_map = map;
    const scope = enter(&grid.fallback_timing, &grid);
    defer scope.end();
    try std.testing.expect(discoveryBegin(&grid.resolver, target) == null);
    try std.testing.expect(!claimed.load(.acquire));
    grid.resolver.codepoint_map = null;
    const span = discoveryBegin(&grid.resolver, target);
    try std.testing.expect(span != null);
    discoveryEnd(span); // An iterator/null/error failure never binds an index.
    try std.testing.expectEqual(Phase.rejected, grid.fallback_timing.phase.load(.acquire));
    scope.end();
    try std.testing.expect(resolving == null);
}

test "gx.font_fallback_perf concurrent grids claim exactly once" {
    const Worker = struct {
        fn run(once: *std.atomic.Value(bool), wins: *std.atomic.Value(u32)) void {
            var s: State = .{};
            if (s.begin(true, once, target, std.Thread.getCurrentId(), .zero)) _ = wins.fetchAdd(1, .monotonic);
        }
    };
    var once: std.atomic.Value(bool) = .init(false);
    var wins: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &once, &wins });
        spawned += 1;
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 1), wins.load(.acquire));
}

test "gx.font_fallback_perf mismatched grid or font rejects before later matching glyph" {
    const font = @import("../font/main.zig");
    const before = perf.enabled();
    defer perf.setEnabled(before);
    perf.setEnabled(true);
    for ([_]bool{ false, true }) |wrong_grid| {
        var grid: u8 = 0;
        var other_grid: u8 = 0;
        var s: State = .{ .grid = @intFromPtr(&grid) };
        var once: std.atomic.Value(bool) = .init(false);
        _ = s.begin(true, &once, target, std.Thread.getCurrentId(), .zero);
        s.bindIndex(0);
        try std.testing.expect(s.bindGlyph(0, 99));
        const idx: font.Collection.Index = .{ .idx = if (wrong_grid) 0 else 1 };
        try std.testing.expect(!rasterBegin(&s, if (wrong_grid) &other_grid else &grid, idx, 99, false));
        try std.testing.expectEqual(Phase.rejected, s.phase.load(.acquire));
        const matching: font.Collection.Index = .{};
        try std.testing.expect(!rasterBegin(&s, &grid, matching, 99, false));
    }
}

test "gx.font_fallback_perf face failure missing cmap and wrong CJK are rejected" {
    const font = @import("../font/main.zig");
    const FakeFace = struct {
        pub fn glyphIndex(_: @This(), _: u32) ?u32 {
            return null;
        }
    };
    const before = perf.enabled();
    const prior_claim = claimed.load(.acquire);
    defer perf.setEnabled(before);
    defer claimed.store(prior_claim, .release);
    var lib = try font.Library.init(std.testing.allocator);
    defer lib.deinit();
    for (0..3) |scenario| {
        claimed.store(false, .release); // Test isolation only; no production reset.
        var grid = try testGrid(lib);
        defer grid.deinit(std.testing.allocator);
        perf.setEnabled(false);
        const off_scope = enter(&grid.fallback_timing, &grid);
        defer off_scope.end();
        try std.testing.expect(discoveryBegin(&grid.resolver, target) == null);
        try std.testing.expect(!claimed.load(.acquire));
        perf.setEnabled(true);
        const scope = enter(&grid.fallback_timing, &grid);
        defer scope.end();
        const cp = if (scenario == 2) target + 1 else target;
        const span = discoveryBegin(&grid.resolver, cp);
        try std.testing.expect(span != null);
        const idx: font.Collection.Index = .{};
        discoveryIndex(span, idx);
        if (scenario == 1) faceReady(&grid.fallback_timing, cp, idx, FakeFace{});
        scope.end(); // Scenario 0 exits before a deferred face can be loaded.
        try std.testing.expectEqual(Phase.rejected, grid.fallback_timing.phase.load(.acquire));
        try std.testing.expect(!rasterBegin(&grid.fallback_timing, &grid, idx, 99, false));
        try std.testing.expect(resolving == null);
    }
}
