//! Interactive Example
//!
//! An interactive demo with text input, zoom controls,
//! and pan functionality to explore MSDF text rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msdf_gpu = @import("msdf_gpu");
const assets = @import("assets");

const log = std.log.scoped(.interactive);

const max_input_len = 256;

pub fn run(allocator: Allocator) !void {
    log.info("Starting interactive demo", .{});

    // Initialize GPU renderer
    var renderer = msdf_gpu.MsdfGpuRenderer.init(allocator, .{
        .title = "MSDF Interactive Demo",
        .width = 1024,
        .height = 768,
        .font_data = assets.dejavu_sans,
        .glyph_size = 64,
        .px_range = 4.0,
    }) catch |err| {
        log.err("Failed to initialize GPU renderer: {}", .{err});
        return err;
    };
    defer renderer.deinit();

    log.info("GPU renderer initialized!", .{});
    log.info("Controls: Type text, mouse wheel to zoom, ESC to exit", .{});

    // Interactive state
    var input_buffer: [max_input_len]u8 = undefined;
    var input_len: usize = 0;
    @memcpy(input_buffer[0..11], "Hello MSDF!");
    input_len = 11;

    var scale: f32 = 1.0;
    var pan_x: f32 = 50;
    var pan_y: f32 = 200;

    const min_scale: f32 = 0.25;
    const max_scale: f32 = 8.0;

    // Color options
    const colors = [_][4]f32{
        .{ 1.0, 1.0, 1.0, 1.0 }, // White
        .{ 1.0, 0.6, 0.2, 1.0 }, // Orange
        .{ 0.4, 1.0, 0.4, 1.0 }, // Green
        .{ 0.4, 0.6, 1.0, 1.0 }, // Blue
        .{ 1.0, 0.4, 0.6, 1.0 }, // Pink
        .{ 1.0, 1.0, 0.4, 1.0 }, // Yellow
    };
    var color_index: usize = 0;

    // Main loop
    var running = true;
    while (running) {
        // Process events
        while (msdf_gpu.pollEvent()) |event| {
            switch (event) {
                .quit => running = false,
                .key_down => |key| {
                    // Escape to exit
                    if (key == 0x1B or key == 27) running = false;
                    // Backspace
                    if (key == 0x08 or key == 8 or key == 42) {
                        if (input_len > 0) {
                            // Handle UTF-8 backspace
                            var i = input_len - 1;
                            while (i > 0 and (input_buffer[i] & 0xC0) == 0x80) {
                                i -= 1;
                            }
                            input_len = i;
                        }
                    }
                    // Tab cycles colors
                    if (key == '\t' or key == 9) {
                        color_index = (color_index + 1) % colors.len;
                    }
                    // R resets view
                    if (key == 'r' or key == 'R') {
                        scale = 1.0;
                        pan_x = 50;
                        pan_y = 200;
                    }
                    // Arrow keys for panning
                    if (key == 0x40000052) pan_y -= 20; // UP
                    if (key == 0x40000051) pan_y += 20; // DOWN
                    if (key == 0x40000050) pan_x -= 20; // LEFT
                    if (key == 0x4000004F) pan_x += 20; // RIGHT
                    // +/= and - for zoom
                    if (key == '=' or key == '+') scale = @min(scale * 1.2, max_scale);
                    if (key == '-' or key == '_') scale = @max(scale / 1.2, min_scale);
                    // Handle printable ASCII characters
                    if (key >= 32 and key < 127) {
                        if (input_len < max_input_len - 1) {
                            input_buffer[input_len] = @truncate(key);
                            input_len += 1;
                        }
                    }
                },
                .mouse_wheel => |y| {
                    // Zoom with mouse wheel
                    const zoom_factor: f32 = 1.1;
                    if (y > 0) {
                        scale = @min(scale * zoom_factor, max_scale);
                    } else if (y < 0) {
                        scale = @max(scale / zoom_factor, min_scale);
                    }
                },
                else => {},
            }
        }

        renderer.clear();

        const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const gray = [4]f32{ 0.5, 0.5, 0.5, 1.0 };
        const dark_gray = [4]f32{ 0.3, 0.3, 0.3, 1.0 };

        // Draw user input text at current position and scale
        const current_color = colors[color_index];
        if (input_len > 0) {
            try renderer.drawText(input_buffer[0..input_len], pan_x, pan_y, scale, current_color);
        }

        // Draw cursor (blinking)
        const time_ms: u64 = @intCast(std.time.milliTimestamp());
        if ((time_ms / 500) % 2 == 0) {
            try renderer.drawText("|", pan_x + measureTextWidth(&renderer, input_buffer[0..input_len]) * scale, pan_y, scale, current_color);
        }

        // UI overlay - always at screen coordinates
        try renderer.drawText("Interactive MSDF Demo", 20, 20, 0.7, white);

        // Show current state
        var buf: [128]u8 = undefined;
        const state_info = std.fmt.bufPrint(&buf, "Scale: {d:.2}x | Position: ({d:.0}, {d:.0})", .{
            scale,
            pan_x,
            pan_y,
        }) catch "State info";
        try renderer.drawText(state_info, 20, 50, 0.5, gray);

        // Instructions
        try renderer.drawText("Type to enter text | Mouse wheel to zoom | Arrows to pan", 20, 708, 0.5, gray);
        try renderer.drawText("Tab: Change color | R: Reset view | +/-: Zoom | ESC: Exit", 20, 733, 0.5, dark_gray);

        // Show color indicator
        try renderer.drawText("Color:", 874, 20, 0.5, gray);
        try renderer.drawText("Sample", 944, 20, 0.5, current_color);

        _ = renderer.render(.{ 0.12, 0.12, 0.18, 1.0 });
    }

    log.info("Interactive demo finished", .{});
}

fn measureTextWidth(renderer: *const msdf_gpu.MsdfGpuRenderer, text: []const u8) f32 {
    var width: f32 = 0;
    const atlas = renderer.getAtlas();

    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |codepoint| {
        const glyph = atlas.glyphs.get(codepoint) orelse {
            width += renderer.glyph_size * 0.3;
            continue;
        };
        // Metrics are normalized, multiply by glyph_size
        width += glyph.metrics.advance_width * renderer.glyph_size;
    }

    return width;
}
