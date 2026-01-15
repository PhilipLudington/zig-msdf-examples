//! Atlas Demo Example
//!
//! Displays the generated MSDF atlas texture and shows
//! glyph boundaries and metrics information.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msdf_gpu = @import("msdf_gpu");
const assets = @import("assets");

const log = std.log.scoped(.atlas_demo);

pub fn run(allocator: Allocator) !void {
    log.info("Starting atlas demo", .{});

    // Initialize GPU renderer with a smaller glyph size for better atlas visibility
    var renderer = msdf_gpu.MsdfGpuRenderer.init(allocator, .{
        .title = "MSDF Atlas Demo",
        .width = 1024,
        .height = 768,
        .font_data = assets.dejavu_sans,
        .glyph_size = 32,
        .px_range = 4.0,
    }) catch |err| {
        log.err("Failed to initialize GPU renderer: {}", .{err});
        return err;
    };
    defer renderer.deinit();

    const atlas = renderer.getAtlas();
    log.info("Atlas generated: {}x{} pixels, {} glyphs", .{
        atlas.width,
        atlas.height,
        atlas.glyphs.count(),
    });

    // Interactive state
    var show_atlas = true;
    var selected_glyph: u21 = 'A';

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
                    // Space toggles atlas view
                    if (key == ' ' or key == 32) show_atlas = !show_atlas;
                    // Right arrow cycles forward through printable ASCII
                    if (key == 0x4000004F or key == 79) {
                        selected_glyph = if (selected_glyph < '~') selected_glyph + 1 else ' ';
                    }
                    // Left arrow cycles backward
                    if (key == 0x40000050 or key == 80) {
                        selected_glyph = if (selected_glyph > ' ') selected_glyph - 1 else '~';
                    }
                },
                else => {},
            }
        }

        renderer.clear();

        const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const yellow = [4]f32{ 1.0, 1.0, 0.4, 1.0 };
        const gray = [4]f32{ 0.6, 0.6, 0.6, 1.0 };

        if (show_atlas) {
            // Draw atlas visualization header
            try renderer.drawText("MSDF Atlas Visualization", 20, 30, 0.8, white);

            // Show atlas info
            var buf: [128]u8 = undefined;
            const info = std.fmt.bufPrint(&buf, "Atlas: {d}x{d} | Glyphs: {d}", .{
                atlas.width,
                atlas.height,
                atlas.glyphs.count(),
            }) catch "Atlas info";
            try renderer.drawText(info, 20, 60, 0.5, gray);

            // If a glyph is selected, show its details
            if (atlas.glyphs.get(selected_glyph)) |glyph| {
                const metrics = glyph.metrics;

                // Show selected glyph large
                const glyph_char = [_]u8{@truncate(selected_glyph)};
                try renderer.drawText(&glyph_char, 874, 100, 4.0, yellow);

                // Show metrics
                const metric_info = std.fmt.bufPrint(&buf, "Glyph: '{c}' (U+{X:0>4})", .{
                    @as(u8, @truncate(selected_glyph)),
                    selected_glyph,
                }) catch "Glyph info";
                try renderer.drawText(metric_info, 20, 100, 0.6, white);

                const uv_info = std.fmt.bufPrint(&buf, "UV: ({d:.3},{d:.3}) - ({d:.3},{d:.3})", .{
                    glyph.uv_min[0],
                    glyph.uv_min[1],
                    glyph.uv_max[0],
                    glyph.uv_max[1],
                }) catch "UV info";
                try renderer.drawText(uv_info, 20, 130, 0.5, gray);

                const size_info = std.fmt.bufPrint(&buf, "Size: {d:.1}x{d:.1} | Advance: {d:.1}", .{
                    metrics.width,
                    metrics.height,
                    metrics.advance_width,
                }) catch "Size info";
                try renderer.drawText(size_info, 20, 155, 0.5, gray);

                const bearing_info = std.fmt.bufPrint(&buf, "Bearing: ({d:.1}, {d:.1})", .{
                    metrics.bearing_x,
                    metrics.bearing_y,
                }) catch "Bearing info";
                try renderer.drawText(bearing_info, 20, 180, 0.5, gray);
            }

            // Instructions
            try renderer.drawText("Arrow keys to browse glyphs | Space to toggle view | ESC to exit", 20, 738, 0.5, gray);
        } else {
            // Show sample text
            try renderer.drawText("Sample Text View", 20, 30, 0.8, white);
            try renderer.drawText("The quick brown fox jumps over the lazy dog.", 20, 80, 1.0, white);
            try renderer.drawText("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 20, 130, 0.8, yellow);
            try renderer.drawText("abcdefghijklmnopqrstuvwxyz", 20, 170, 0.8, yellow);
            try renderer.drawText("0123456789 !@#$%^&*()+-=[]{}|;:',.<>?", 20, 210, 0.7, gray);

            try renderer.drawText("Press Space to view atlas", 20, 738, 0.5, gray);
        }

        _ = renderer.render(.{ 0.15, 0.15, 0.2, 1.0 });
    }

    log.info("Atlas demo finished", .{});
}
