//! Deterministic GL allocation checks for the GX OpenGL color pipeline.
const std = @import("std");
const gl = @import("opengl");
const OpenGL = @import("../OpenGL.zig");
const Blending = @import("../../config.zig").Config.AlphaBlending;

const Mock = struct {
    threadlocal var next: gl.c.GLuint = 1;
    threadlocal var bound: gl.c.GLuint = 0;
    threadlocal var formats: [128]gl.c.GLint = @splat(0);

    fn init() void {
        next = 1;
        bound = 0;
        formats = @splat(0);
        gl.glad.context = std.mem.zeroes(gl.glad.Context);
        gl.glad.context.GetError = &getError;
        gl.glad.context.GenTextures = &gen;
        gl.glad.context.GenFramebuffers = &gen;
        gl.glad.context.DeleteTextures = &destroy;
        gl.glad.context.DeleteFramebuffers = &destroy;
        gl.glad.context.BindTexture = &bindTexture;
        gl.glad.context.TexParameteri = &parameter;
        gl.glad.context.TexImage2D = &image;
        gl.glad.context.GetIntegerv = &getInteger;
        gl.glad.context.BindFramebuffer = &bindFramebuffer;
        gl.glad.context.FramebufferTexture2D = &attach;
        gl.glad.context.CheckFramebufferStatus = &status;
    }

    fn getError() callconv(.c) gl.c.GLenum {
        return gl.c.GL_NO_ERROR;
    }
    fn gen(n: gl.c.GLsizei, ids: [*c]gl.c.GLuint) callconv(.c) void {
        for (0..@intCast(n)) |i| {
            ids[i] = next;
            next += 1;
        }
    }
    fn destroy(_: gl.c.GLsizei, _: [*c]const gl.c.GLuint) callconv(.c) void {}
    fn bindTexture(_: gl.c.GLenum, id: gl.c.GLuint) callconv(.c) void {
        bound = id;
    }
    fn parameter(_: gl.c.GLenum, _: gl.c.GLenum, _: gl.c.GLint) callconv(.c) void {}
    fn image(_: gl.c.GLenum, _: gl.c.GLint, format: gl.c.GLint, _: gl.c.GLsizei, _: gl.c.GLsizei, _: gl.c.GLint, _: gl.c.GLenum, _: gl.c.GLenum, _: ?*const anyopaque) callconv(.c) void {
        formats[bound] = format;
    }
    fn getInteger(_: gl.c.GLenum, value: [*c]gl.c.GLint) callconv(.c) void {
        value[0] = 0;
    }
    fn bindFramebuffer(_: gl.c.GLenum, _: gl.c.GLuint) callconv(.c) void {}
    fn attach(_: gl.c.GLenum, _: gl.c.GLenum, _: gl.c.GLenum, _: gl.c.GLuint, _: gl.c.GLint) callconv(.c) void {}
    fn status(_: gl.c.GLenum) callconv(.c) gl.c.GLenum {
        return gl.c.GL_FRAMEBUFFER_COMPLETE;
    }
};

// The repeated native entry also checks that a rebuilt target uses the new
// API mode, as FrameState.resize does after changeConfig or context recovery.
const modes = [_]Blending{ .native, .linear, .@"linear-corrected", .native };

pub fn targetFormats() !void {
    Mock.init();
    defer gl.glad.context = undefined;
    var api: OpenGL = undefined;
    for (modes) |mode| {
        api.blending = mode;
        var target = try api.initTarget(4, 4);
        defer target.deinit();
        const expected: gl.c.GLint = if (mode.isLinear()) gl.c.GL_SRGB8_ALPHA8 else gl.c.GL_RGBA8;
        try std.testing.expectEqual(expected, Mock.formats[target.texture.id]);
        if (target.export_texture.id != 0) try std.testing.expectEqual(@as(gl.c.GLint, gl.c.GL_RGBA8), Mock.formats[target.export_texture.id]);
    }
}

pub fn intermediateFormats() !void {
    Mock.init();
    defer gl.glad.context = undefined;
    var api: OpenGL = undefined;
    for (modes) |mode| {
        api.blending = mode;
        // Exercise actual allocations for both sides of the shader ping-pong.
        for (0..2) |_| {
            const texture = try OpenGL.Texture.init(api.textureOptions(), 4, 4, null);
            defer texture.deinit();
            const expected: gl.c.GLint = if (mode.isLinear()) gl.c.GL_SRGB8_ALPHA8 else gl.c.GL_RGBA8;
            try std.testing.expectEqual(expected, Mock.formats[texture.texture.id]);
        }
    }
}

pub fn sampledFormats() !void {
    Mock.init();
    defer gl.glad.context = undefined;
    var api: OpenGL = undefined;
    for (modes) |mode| {
        api.blending = mode;
        for ([_]bool{ true, false }) |srgb| {
            const texture = try OpenGL.Texture.init(api.imageTextureOptions(.rgba, srgb), 4, 4, null);
            defer texture.deinit();
            try std.testing.expectEqual(@as(gl.c.GLint, if (srgb) gl.c.GL_SRGB8_ALPHA8 else gl.c.GL_RGBA8), Mock.formats[texture.texture.id]);
        }
        const color = try api.initAtlasTexture(&.{ .size = 1, .format = .bgra, .data = undefined });
        defer color.deinit();
        try std.testing.expectEqual(@as(gl.c.GLint, gl.c.GL_SRGB8_ALPHA8), Mock.formats[color.texture.id]);
        const gray = try api.initAtlasTexture(&.{ .size = 1, .format = .grayscale, .data = undefined });
        defer gray.deinit();
        try std.testing.expectEqual(@as(gl.c.GLint, gl.c.GL_RED), Mock.formats[gray.texture.id]);
    }
}
