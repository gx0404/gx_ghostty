const std = @import("std");

pub fn prepareBackground(renderer: anytype, comptime prepare: anytype) !void {
    if (renderer.config.bg_image != null and renderer.bg_image == null)
        try prepare(renderer);
}

test "gx.renderer_recovery: prepare only a configured missing image" {
    const Stub = struct {
        config: struct { bg_image: ?u8 = null } = .{},
        bg_image: ?u8 = null,
        attempts: usize = 0,
        fail: bool = false,
        fn prepare(self: *@This()) !void {
            self.attempts += 1;
            if (self.fail) return error.OutOfMemory;
            self.bg_image = 1;
        }
    };
    var renderer: Stub = .{};
    try prepareBackground(&renderer, Stub.prepare);
    try std.testing.expectEqual(0, renderer.attempts);
    renderer.config.bg_image = 1;
    renderer.fail = true;
    try std.testing.expectError(error.OutOfMemory, prepareBackground(&renderer, Stub.prepare));
    try std.testing.expectEqual(null, renderer.bg_image);
    renderer.fail = false;
    try prepareBackground(&renderer, Stub.prepare);
    try prepareBackground(&renderer, Stub.prepare);
    try std.testing.expectEqual(2, renderer.attempts);
}

pub fn testRenderer(comptime Renderer: type) !void {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var png: [68]u8 = undefined;
    try std.base64.standard.Decoder.decode(&png, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
    try tmp.dir.writeFile(io, .{ .sub_path = "bg.png", .data = &png });
    const path = try tmp.dir.realPathFileAlloc(io, "bg.png", alloc);
    defer alloc.free(path);
    var renderer: Renderer = undefined;
    renderer.alloc = alloc;
    renderer.draw_mutex = .init;
    renderer.config = undefined;
    renderer.config.bg_image = .{ .required = path };
    renderer.bg_image = null;
    renderer.display_realized = false;
    renderer.reinitialize_shaders = false;
    renderer.target_config_modified = 0;
    defer if (renderer.bg_image) |image| image.deinit(alloc);
    try renderer.displayRealized();
    try std.testing.expect(renderer.display_realized);
    try std.testing.expect(renderer.bg_image != null);
    try std.testing.expect(renderer.bg_image.?.isPending());
    const pixels = renderer.bg_image.?.pending.data;
    try tmp.dir.deleteFile(io, "bg.png");
    try renderer.displayRealized();
    try std.testing.expectEqual(pixels, renderer.bg_image.?.pending.data);
    renderer.bg_image.?.deinit(alloc);
    renderer.bg_image = null;
    renderer.display_realized = false;
    try renderer.displayRealized();
    try std.testing.expect(renderer.display_realized);
    try std.testing.expectEqual(null, renderer.bg_image);
    try tmp.dir.writeFile(io, .{ .sub_path = "bg.png", .data = "invalid png" });
    renderer.display_realized = false;
    if (renderer.displayRealized()) |_| return error.ExpectedDecodeFailure else |_| {}
    try std.testing.expect(!renderer.display_realized);
    try std.testing.expectEqual(null, renderer.bg_image);
    try tmp.dir.writeFile(io, .{ .sub_path = "bg.png", .data = &png });
    var decode_oom: usize = 0;
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        renderer.alloc = failing.allocator();
        renderer.display_realized = false;
        renderer.reinitialize_shaders = false;
        renderer.target_config_modified = 0;
        if (renderer.displayRealized()) |_| {
            try std.testing.expect(renderer.display_realized);
            if (renderer.bg_image) |image| image.deinit(renderer.alloc);
            renderer.bg_image = null;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!renderer.display_realized);
            try std.testing.expect(!renderer.reinitialize_shaders);
            try std.testing.expectEqual(0, renderer.target_config_modified);
            try std.testing.expectEqual(null, renderer.bg_image);
            decode_oom += 1;
        }
    }
    try std.testing.expect(decode_oom > 0);
    renderer.alloc = alloc;
    try renderer.displayRealized();
    try std.testing.expect(renderer.bg_image != null);
}
