//! Basic Text Example
//!
//! Demonstrates MSDF text rendering at multiple scales.
//! Uses SDL3's 2D renderer which provides hardware acceleration
//! for texture blitting. For the full MSDF shader effect (crisp edges
//! at any scale), the GPU pipeline with proper platform shaders is needed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msdf = @import("msdf");
const assets = @import("assets");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const log = std.log.scoped(.basic_text);

pub fn run(allocator: Allocator) !void {
    log.info("Starting MSDF text example", .{});

    // Initialize SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "MSDF Text Demo",
        1024,
        768,
        c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    // Create renderer (hardware accelerated 2D)
    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // Load font and generate atlas
    log.info("Loading font and generating MSDF atlas...", .{});
    var font = msdf.Font.fromMemory(allocator, assets.dejavu_sans) catch |err| {
        log.err("Failed to load font: {}", .{err});
        return error.FontLoadFailed;
    };
    defer font.deinit();

    var atlas = msdf.generateAtlas(allocator, font, .{
        .chars = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-=+,.?:'\"",
        .glyph_size = 48,
        .padding = 4,
        .range = 4.0,
    }) catch |err| {
        log.err("Failed to generate atlas: {}", .{err});
        return error.AtlasGenerationFailed;
    };
    defer atlas.deinit(allocator);

    log.info("Atlas: {}x{} pixels, {} glyphs", .{ atlas.width, atlas.height, atlas.glyphs.count() });

    // Create texture from atlas
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_STATIC,
        @intCast(atlas.width),
        @intCast(atlas.height),
    ) orelse {
        log.err("Failed to create texture: {s}", .{c.SDL_GetError()});
        return error.TextureCreationFailed;
    };
    defer c.SDL_DestroyTexture(texture);

    _ = c.SDL_UpdateTexture(texture, null, atlas.pixels.ptr, @intCast(atlas.width * 4));
    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

    log.info("Ready! ESC=exit, SPACE=toggle mode, UP/DOWN or mouse wheel=zoom", .{});

    var scale_mode = false;
    var demo_scale: f32 = 1.0;

    // Main loop
    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    const key = event.key.key;
                    if (key == c.SDLK_ESCAPE) running = false;
                    if (key == c.SDLK_SPACE) scale_mode = !scale_mode;
                    if (key == c.SDLK_UP or key == c.SDLK_EQUALS) demo_scale = @min(demo_scale * 1.2, 8.0);
                    if (key == c.SDLK_DOWN or key == c.SDLK_MINUS) demo_scale = @max(demo_scale / 1.2, 0.1);
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    if (event.wheel.y > 0) demo_scale = @min(demo_scale * 1.1, 8.0);
                    if (event.wheel.y < 0) demo_scale = @max(demo_scale / 1.1, 0.1);
                },
                else => {},
            }
        }

        // Clear
        _ = c.SDL_SetRenderDrawColor(renderer, 20, 20, 30, 255);
        _ = c.SDL_RenderClear(renderer);

        if (scale_mode) {
            // Interactive scale mode
            renderText(renderer, texture, &atlas, "MSDF Text", 50, 100, demo_scale, .{ 255, 255, 255 });
            renderText(renderer, texture, &atlas, "Zoom with mouse wheel!", 50, 100 + 60 * demo_scale, demo_scale * 0.4, .{ 100, 255, 150 });

            var buf: [64]u8 = undefined;
            const info = std.fmt.bufPrint(&buf, "Scale: {d:.2}x", .{demo_scale}) catch "Scale: ?";
            renderText(renderer, texture, &atlas, info, 50, 700, 0.5, .{ 150, 150, 150 });
            renderText(renderer, texture, &atlas, "SPACE for multi-scale view", 50, 730, 0.4, .{ 100, 100, 100 });
        } else {
            // Multi-scale demonstration
            renderText(renderer, texture, &atlas, "MSDF Text Rendering Demo", 50, 30, 1.0, .{ 255, 255, 255 });
            renderText(renderer, texture, &atlas, "Multi-channel Signed Distance Fields", 50, 80, 0.5, .{ 150, 150, 150 });

            renderText(renderer, texture, &atlas, "Scale 0.3x - tiny", 50, 140, 0.3, .{ 100, 255, 150 });
            renderText(renderer, texture, &atlas, "Scale 0.5x - small", 50, 170, 0.5, .{ 100, 255, 150 });
            renderText(renderer, texture, &atlas, "Scale 0.75x - medium", 50, 210, 0.75, .{ 100, 200, 255 });
            renderText(renderer, texture, &atlas, "Scale 1.0x - normal", 50, 260, 1.0, .{ 255, 255, 255 });
            renderText(renderer, texture, &atlas, "Scale 1.5x - large", 50, 320, 1.5, .{ 255, 180, 100 });
            renderText(renderer, texture, &atlas, "Scale 2.0x - bigger", 50, 400, 2.0, .{ 255, 150, 200 });
            renderText(renderer, texture, &atlas, "Scale 3.0x", 50, 510, 3.0, .{ 100, 200, 255 });

            renderText(renderer, texture, &atlas, "Note: Full MSDF shader gives crisp edges at ALL scales", 50, 680, 0.5, .{ 200, 200, 100 });
            renderText(renderer, texture, &atlas, "SPACE for interactive zoom, ESC to exit", 50, 730, 0.4, .{ 100, 100, 100 });
        }

        _ = c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16);
    }

    log.info("Example finished", .{});
}

fn renderText(
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    atlas: *const msdf.AtlasResult,
    text: []const u8,
    x: f32,
    y: f32,
    scale: f32,
    color: [3]u8,
) void {
    _ = c.SDL_SetTextureColorMod(texture, color[0], color[1], color[2]);

    var cursor_x = x;
    const atlas_w: f32 = @floatFromInt(atlas.width);
    const atlas_h: f32 = @floatFromInt(atlas.height);
    const glyph_size: f32 = 48.0;

    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |codepoint| {
        const glyph = atlas.glyphs.get(codepoint) orelse {
            cursor_x += glyph_size * 0.3 * scale;
            continue;
        };

        const m = glyph.metrics;

        const src = c.SDL_FRect{
            .x = glyph.uv_min[0] * atlas_w,
            .y = glyph.uv_min[1] * atlas_h,
            .w = (glyph.uv_max[0] - glyph.uv_min[0]) * atlas_w,
            .h = (glyph.uv_max[1] - glyph.uv_min[1]) * atlas_h,
        };

        const dst = c.SDL_FRect{
            .x = cursor_x + m.bearing_x * scale,
            .y = y + (glyph_size - m.bearing_y) * scale,
            .w = m.width * scale,
            .h = m.height * scale,
        };

        _ = c.SDL_RenderTexture(renderer, texture, &src, &dst);
        cursor_x += m.advance_width * scale;
    }
}
