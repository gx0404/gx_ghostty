//! Factory-bound Fluent geometry cache. Call deinit before releasing the factory.
//! The caller keeps system glyphs as the fallback when draw returns false.
const std = @import("std");
const d2d = @import("d2d.zig");
const model = @import("../../../gx/fluent/model.zig");
const data = @import("../../../gx/fluent/paths.zig");

pub const Id = data.Id;

pub const Cache = struct {
    factory: ?*d2d.Factory = null,
    alloc: ?std.mem.Allocator = null,
    entries: [data.icons.len]?[]d2d.Path = @splat(null),

    pub fn init(factory: *d2d.Factory) Cache {
        return .{ .factory = factory, .alloc = factory.alloc };
    }

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*entry| {
            if (entry.*) |paths| {
                for (paths) |*path| path.deinit();
                self.alloc.?.free(paths);
                entry.* = null;
            }
        }
        self.factory = null;
        self.alloc = null;
    }

    fn get(self: *Cache, id: Id) ?[]d2d.Path {
        const factory = self.factory orelse return null;
        const index = @backingInt(id);
        if (self.entries[index]) |paths| return paths;
        const source = data.icons[index];
        const paths = self.alloc.?.alloc(d2d.Path, source.paths.len) catch return null;
        var count: usize = 0;
        var committed = false;
        defer if (!committed) {
            for (paths[0..count]) |*path| path.deinit();
            self.alloc.?.free(paths);
        };
        for (source.paths) |source_path| {
            paths[count] = factory.createPath() orelse return null;
            const path = &paths[count];
            count += 1;
            path.setFillMode(switch (source_path.fill_rule) {
                .nonzero => .nonzero,
                .evenodd => .evenodd,
            });
            var open = false;
            for (source_path.commands) |command| switch (command) {
                .move => |p| {
                    if (open) path.endFigure(false);
                    path.beginFigure(point(p));
                    open = true;
                },
                .line => |p| {
                    if (!open) return null;
                    path.lineTo(point(p));
                },
                .cubic => |curve| {
                    if (!open) return null;
                    path.bezierTo(point(curve.c1), point(curve.c2), point(curve.end));
                },
                .close => {
                    if (!open) return null;
                    path.endFigure(true);
                    open = false;
                },
            };
            if (open) path.endFigure(false);
            if (!path.finish()) return null;
        }
        self.entries[index] = paths;
        committed = true;
        return paths;
    }

    /// Geometry is device independent. Color and placement always come from this frame.
    pub fn draw(self: *Cache, canvas: *d2d.Canvas, id: Id, rect: d2d.Rect, color: d2d.Color) bool {
        const factory = self.factory orelse return false;
        if (canvas.factory != factory) return false;
        const placement = model.fit(data.icons[@backingInt(id)], rect.x, rect.y, rect.w, rect.h) orelse return false;
        const paths = self.get(id) orelse return false;
        const transform: d2d.Matrix3x2 = .{
            .m11 = placement.scale,
            .m22 = placement.scale,
            .dx = placement.x,
            .dy = placement.y,
        };
        for (paths) |*path| {
            if (!canvas.fillPathTransformed(path, color, transform)) return false;
        }
        return true;
    }
};

fn point(p: model.Point) d2d.Point {
    return .{ .x = p.x, .y = p.y };
}

test "fluent cache can be inert and deinitialized repeatedly" {
    var cache: Cache = .{};
    try std.testing.expect(cache.get(.language) == null);
    cache.deinit();
    cache.deinit();
    for (cache.entries) |entry| try std.testing.expect(entry == null);
}
