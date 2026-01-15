//! GPU Text Example
//!
//! Demonstrates MSDF text rendering using SDL3's GPU API with
//! the actual MSDF shader. This provides crisp text at any scale.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msdf_gpu = @import("msdf_gpu");
const assets = @import("assets");

const log = std.log.scoped(.gpu_text);

pub fn run(allocator: Allocator) !void {
    log.info("Starting GPU MSDF text example", .{});

    var renderer = msdf_gpu.MsdfGpuRenderer.init(allocator, .{
        .title = "MSDF GPU Text Demo",
        .width = 1024,
        .height = 768,
        .font_data = assets.dejavu_sans,
        .glyph_size = 48,
        .px_range = 4.0,
    }) catch |err| {
        log.err("Failed to initialize GPU renderer: {}", .{err});
        return err;
    };
    defer renderer.deinit();

    log.info("GPU renderer initialized!", .{});
    log.info("Controls: ESC=exit, SPACE=toggle mode, UP/DOWN or wheel=zoom", .{});

    var scale_mode = false;
    var demo_scale: f32 = 1.0;
    var running = true;

    while (running) {
        // Handle events
        while (msdf_gpu.pollEvent()) |event| {
            switch (event) {
                .quit => running = false,
                .key_down => |key| {
                    if (key == 0x1B) running = false; // ESC
                    if (key == ' ') scale_mode = !scale_mode;
                    if (key == 0x40000052 or key == '=') demo_scale = @min(demo_scale * 1.2, 8.0); // UP
                    if (key == 0x40000051 or key == '-') demo_scale = @max(demo_scale / 1.2, 0.1); // DOWN
                },
                .mouse_wheel => |y| {
                    if (y > 0) demo_scale = @min(demo_scale * 1.1, 8.0);
                    if (y < 0) demo_scale = @max(demo_scale / 1.1, 0.1);
                },
                else => {},
            }
        }

        // Clear vertex buffer
        renderer.clear();

        if (scale_mode) {
            // Interactive scale mode
            try renderer.drawText("MSDF GPU Text", 50, 100, demo_scale, .{ 1.0, 1.0, 1.0, 1.0 });
            try renderer.drawText("Zoom with mouse wheel!", 50, 100 + 60 * demo_scale, demo_scale * 0.4, .{ 0.4, 1.0, 0.6, 1.0 });

            var buf: [64]u8 = undefined;
            const info = std.fmt.bufPrint(&buf, "Scale: {d:.2}x", .{demo_scale}) catch "Scale: ?";
            try renderer.drawText(info, 50, 700, 0.5, .{ 0.6, 0.6, 0.6, 1.0 });
            try renderer.drawText("SPACE for multi-scale view", 50, 730, 0.4, .{ 0.4, 0.4, 0.4, 1.0 });
        } else {
            // Multi-scale demonstration
            try renderer.drawText("MSDF GPU Text Rendering", 50, 30, 1.0, .{ 1.0, 1.0, 1.0, 1.0 });
            try renderer.drawText("Crisp at ANY scale!", 50, 80, 0.5, .{ 0.6, 0.6, 0.6, 1.0 });

            try renderer.drawText("Scale 0.3x - tiny", 50, 140, 0.3, .{ 0.4, 1.0, 0.6, 1.0 });
            try renderer.drawText("Scale 0.5x - small", 50, 170, 0.5, .{ 0.4, 1.0, 0.6, 1.0 });
            try renderer.drawText("Scale 0.75x - medium", 50, 210, 0.75, .{ 0.4, 0.8, 1.0, 1.0 });
            try renderer.drawText("Scale 1.0x - normal", 50, 260, 1.0, .{ 1.0, 1.0, 1.0, 1.0 });
            try renderer.drawText("Scale 1.5x - large", 50, 320, 1.5, .{ 1.0, 0.7, 0.4, 1.0 });
            try renderer.drawText("Scale 2.0x - bigger", 50, 400, 2.0, .{ 1.0, 0.6, 0.8, 1.0 });
            try renderer.drawText("Scale 3.0x", 50, 510, 3.0, .{ 0.4, 0.8, 1.0, 1.0 });

            try renderer.drawText("SPACE for interactive zoom, ESC to exit", 50, 730, 0.4, .{ 0.4, 0.4, 0.4, 1.0 });
        }

        // Render frame
        _ = renderer.render(.{ 0.08, 0.08, 0.12, 1.0 });
    }

    log.info("Example finished", .{});
}
