//! MSDF Text Renderer
//!
//! Renders text using Multi-channel Signed Distance Fields for
//! crisp, resolution-independent text at any scale.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu = @import("renderer");
const shaders = @import("shaders");
const msdf = @import("msdf");

const log = std.log.scoped(.text_renderer);

pub const TextRendererError = error{
    AtlasGenerationFailed,
    TextureCreationFailed,
    PipelineCreationFailed,
    FontLoadFailed,
    OutOfMemory,
};

pub const TextRenderer = struct {
    allocator: Allocator,
    gpu_ctx: *gpu.Gpu,
    atlas_texture: gpu.Texture,
    sampler: gpu.Sampler,
    atlas: msdf.AtlasResult,
    font: msdf.Font,
    vertex_buffer: std.ArrayListUnmanaged(shaders.Vertex),
    px_range: f32,
    glyph_size: f32,

    pub fn init(
        allocator: Allocator,
        gpu_ctx: *gpu.Gpu,
        font_data: []const u8,
        options: Options,
    ) (TextRendererError || Allocator.Error)!TextRenderer {
        // Load font from memory
        var font = msdf.Font.fromMemory(allocator, font_data) catch |err| {
            log.err("Failed to load font: {}", .{err});
            return TextRendererError.FontLoadFailed;
        };
        errdefer font.deinit();

        // Generate MSDF atlas
        var atlas = msdf.generateAtlas(allocator, font, .{
            .chars = options.charset,
            .glyph_size = options.glyph_size,
            .padding = options.padding,
            .range = options.px_range,
        }) catch |err| {
            log.err("Failed to generate atlas: {}", .{err});
            return TextRendererError.AtlasGenerationFailed;
        };
        errdefer atlas.deinit(allocator);

        // Create GPU texture for atlas
        var atlas_texture = gpu_ctx.createTexture(
            atlas.width,
            atlas.height,
            .rgba8,
        ) catch {
            return TextRendererError.TextureCreationFailed;
        };
        errdefer gpu_ctx.destroyTexture(&atlas_texture);

        // Upload atlas pixel data
        gpu_ctx.uploadTextureData(&atlas_texture, atlas.pixels) catch {
            return TextRendererError.TextureCreationFailed;
        };

        // Create sampler
        var sampler = gpu_ctx.createSampler(.{ .linear = true }) catch {
            return TextRendererError.TextureCreationFailed;
        };
        errdefer gpu_ctx.destroySampler(&sampler);

        return TextRenderer{
            .allocator = allocator,
            .gpu_ctx = gpu_ctx,
            .atlas_texture = atlas_texture,
            .sampler = sampler,
            .atlas = atlas,
            .font = font,
            .vertex_buffer = .{},
            .px_range = options.px_range,
            .glyph_size = @floatFromInt(options.glyph_size),
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        self.vertex_buffer.deinit(self.allocator);
        self.gpu_ctx.destroySampler(&self.sampler);
        self.gpu_ctx.destroyTexture(&self.atlas_texture);
        self.atlas.deinit(self.allocator);
        self.font.deinit();
        self.* = undefined;
    }

    /// Queue text for rendering at the specified position.
    /// Call flush() to submit all queued text.
    pub fn drawText(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        scale: f32,
        color: [4]f32,
    ) Allocator.Error!void {
        var cursor_x = x;
        const cursor_y = y;
        const scaled_size = self.glyph_size * scale;

        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (utf8_iter.nextCodepoint()) |codepoint| {
            const glyph = self.atlas.glyphs.get(codepoint) orelse {
                // Skip unknown glyphs, advance by space width
                cursor_x += scaled_size * 0.3;
                continue;
            };

            // Calculate screen position using glyph metrics
            const metrics = glyph.metrics;
            const glyph_x = cursor_x + metrics.bearing_x * scale;
            const glyph_y = cursor_y + (self.glyph_size - metrics.bearing_y) * scale;
            const glyph_width = metrics.width * scale;
            const glyph_height = metrics.height * scale;

            // Create quad vertices
            const quad = shaders.createQuad(
                glyph_x,
                glyph_y,
                glyph_width,
                glyph_height,
                glyph.uv_min,
                glyph.uv_max,
                color,
            );

            try self.vertex_buffer.appendSlice(self.allocator, &quad);

            // Advance cursor
            cursor_x += metrics.advance_width * scale;
        }
    }

    /// Get the width of text in pixels at scale 1.0
    pub fn measureText(self: *const TextRenderer, text: []const u8) f32 {
        var width: f32 = 0;

        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (utf8_iter.nextCodepoint()) |codepoint| {
            const glyph = self.atlas.glyphs.get(codepoint) orelse {
                width += self.glyph_size * 0.3;
                continue;
            };
            width += glyph.metrics.advance_width;
        }

        return width;
    }

    /// Get the height of text (line height at scale 1.0)
    pub fn getLineHeight(self: *const TextRenderer) f32 {
        return self.glyph_size * 1.2;
    }

    /// Clear all queued text
    pub fn clear(self: *TextRenderer) void {
        self.vertex_buffer.clearRetainingCapacity();
    }

    /// Get vertex data for rendering
    pub fn getVertices(self: *const TextRenderer) []const shaders.Vertex {
        return self.vertex_buffer.items;
    }

    /// Get atlas texture for binding
    pub fn getAtlasTexture(self: *const TextRenderer) *const gpu.Texture {
        return &self.atlas_texture;
    }

    /// Get sampler for binding
    pub fn getSampler(self: *const TextRenderer) *const gpu.Sampler {
        return &self.sampler;
    }

    /// Get atlas result for direct access
    pub fn getAtlas(self: *const TextRenderer) *const msdf.AtlasResult {
        return &self.atlas;
    }

    /// Get uniforms for shader
    pub fn getUniforms(self: *const TextRenderer, screen_width: f32, screen_height: f32) shaders.Uniforms {
        return shaders.Uniforms{
            .screen_size = .{ screen_width, screen_height },
            .px_range = self.px_range,
        };
    }

    pub const Options = struct {
        glyph_size: u32 = 48,
        padding: u32 = 4,
        px_range: f32 = 4.0,
        charset: []const u8 = default_charset,
    };
};

/// Default ASCII charset (printable ASCII characters)
pub const default_charset: []const u8 = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

test "default charset contains printable ASCII" {
    try std.testing.expect(default_charset.len == 95);
    try std.testing.expectEqual(@as(u8, ' '), default_charset[0]);
    try std.testing.expectEqual(@as(u8, '~'), default_charset[94]);
}
