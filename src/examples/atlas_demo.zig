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

    // Initialize GPU renderer
    // Larger glyph_size and px_range help reduce MSDF artifacts at sharp corners
    const glyph_size: u32 = 64;
    const px_range: f32 = 8.0;
    var renderer = msdf_gpu.MsdfGpuRenderer.init(allocator, .{
        .title = "MSDF Atlas Demo",
        .width = 1024,
        .height = 768,
        .font_data = assets.dejavu_sans,
        .glyph_size = glyph_size,
        .px_range = px_range,
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
    var zoom_level: f32 = 4.0; // Starting zoom level for atlas view
    const min_zoom: f32 = 0.5;
    const max_zoom: f32 = 20.0;

    // Pan offset for atlas view (to enable mouse-centered zoom)
    var pan_x: f32 = 0;
    var pan_y: f32 = 0;

    // Text view state
    var text_zoom: f32 = 1.0;
    var text_pan_x: f32 = 20;
    var text_pan_y: f32 = 80;
    const min_text_zoom: f32 = 0.1;
    const max_text_zoom: f32 = 8.0;

    // Mouse position tracking
    var mouse_x: f32 = 512;
    var mouse_y: f32 = 384;

    // Drag state for panning
    var is_dragging = false;
    var drag_start_x: f32 = 0;
    var drag_start_y: f32 = 0;
    var drag_start_pan_x: f32 = 0;
    var drag_start_pan_y: f32 = 0;

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
                    // Right arrow cycles forward through printable ASCII (atlas view only)
                    if (key == 0x4000004F or key == 79) {
                        if (show_atlas) {
                            selected_glyph = if (selected_glyph < '~') selected_glyph + 1 else ' ';
                        }
                    }
                    // Left arrow cycles backward (atlas view only)
                    if (key == 0x40000050 or key == 80) {
                        if (show_atlas) {
                            selected_glyph = if (selected_glyph > ' ') selected_glyph - 1 else '~';
                        }
                    }
                    // R to reset zoom and pan
                    if (key == 'r' or key == 'R') {
                        if (show_atlas) {
                            zoom_level = 4.0;
                            pan_x = 0;
                            pan_y = 0;
                        } else {
                            text_zoom = 1.0;
                            text_pan_x = 20;
                            text_pan_y = 80;
                        }
                    }
                },
                .mouse_motion => |pos| {
                    mouse_x = pos.x;
                    mouse_y = pos.y;

                    // Handle drag panning
                    if (is_dragging) {
                        const dx = pos.x - drag_start_x;
                        const dy = pos.y - drag_start_y;
                        if (show_atlas) {
                            pan_x = drag_start_pan_x + dx;
                            pan_y = drag_start_pan_y + dy;
                        } else {
                            text_pan_x = drag_start_pan_x + dx;
                            text_pan_y = drag_start_pan_y + dy;
                        }
                    }
                },
                .mouse_button_down => |btn| {
                    if (btn.button == msdf_gpu.MOUSE_BUTTON_LEFT) {
                        is_dragging = true;
                        drag_start_x = btn.x;
                        drag_start_y = btn.y;
                        if (show_atlas) {
                            drag_start_pan_x = pan_x;
                            drag_start_pan_y = pan_y;
                        } else {
                            drag_start_pan_x = text_pan_x;
                            drag_start_pan_y = text_pan_y;
                        }
                    }
                },
                .mouse_button_up => |btn| {
                    if (btn.button == msdf_gpu.MOUSE_BUTTON_LEFT) {
                        is_dragging = false;
                    }
                },
                .mouse_wheel => |wheel| {
                    // Mouse-centered zoom
                    const zoom_factor: f32 = 1.15;

                    if (show_atlas) {
                        // Atlas view zoom - content is centered at (512, 384)
                        const origin_x: f32 = 512.0;
                        const origin_y: f32 = 384.0;
                        const old_zoom = zoom_level;
                        if (wheel.delta > 0) {
                            zoom_level = @min(zoom_level * zoom_factor, max_zoom);
                        } else if (wheel.delta < 0) {
                            zoom_level = @max(zoom_level / zoom_factor, min_zoom);
                        }
                        // Adjust pan to keep mouse position fixed relative to origin
                        const zoom_ratio = zoom_level / old_zoom;
                        pan_x = (wheel.x - origin_x) * (1.0 - zoom_ratio) + pan_x * zoom_ratio;
                        pan_y = (wheel.y - origin_y) * (1.0 - zoom_ratio) + pan_y * zoom_ratio;
                    } else {
                        // Text view zoom
                        const old_zoom = text_zoom;
                        if (wheel.delta > 0) {
                            text_zoom = @min(text_zoom * zoom_factor, max_text_zoom);
                        } else if (wheel.delta < 0) {
                            text_zoom = @max(text_zoom / zoom_factor, min_text_zoom);
                        }
                        // Adjust pan to keep mouse position fixed
                        const zoom_ratio = text_zoom / old_zoom;
                        text_pan_x = wheel.x - (wheel.x - text_pan_x) * zoom_ratio;
                        text_pan_y = wheel.y - (wheel.y - text_pan_y) * zoom_ratio;
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
            var buf: [128]u8 = undefined;

            // Draw the large centered glyph FIRST (so info text renders on top)
            if (atlas.glyphs.get(selected_glyph)) |glyph| {
                const metrics = glyph.metrics;
                const glyph_size_f: f32 = @floatFromInt(glyph_size);

                const glyph_char = [_]u8{@truncate(selected_glyph)};

                // Calculate the actual rendered size
                const render_width = metrics.width * glyph_size_f * zoom_level;
                const render_height = metrics.height * glyph_size_f * zoom_level;

                // Center the glyph visual bounds at (512, 384), then apply pan offset
                const center_x: f32 = 512.0 - metrics.bearing_x * glyph_size_f * zoom_level - render_width / 2.0 + pan_x;
                const center_y: f32 = 384.0 - (1.0 - metrics.bearing_y) * glyph_size_f * zoom_level - render_height / 2.0 + pan_y;

                // Draw glyph with slightly dimmed color so text is readable on top
                const glyph_color = [4]f32{ 0.8, 0.8, 0.3, 1.0 };
                try renderer.drawText(&glyph_char, center_x, center_y, zoom_level, glyph_color);
            }

            // Now draw info text ON TOP of the glyph
            // Use smaller text sizes and proper vertical spacing
            const title_scale: f32 = 0.6;
            const info_scale: f32 = 0.4;
            const line_height: f32 = 35;

            try renderer.drawText("MSDF Atlas Visualization", 20, 25, title_scale, white);

            const info = std.fmt.bufPrint(&buf, "Atlas: {d}x{d} | Glyphs: {d}", .{
                atlas.width,
                atlas.height,
                atlas.glyphs.count(),
            }) catch "Atlas info";
            try renderer.drawText(info, 20, 25 + line_height, info_scale, gray);

            if (atlas.glyphs.get(selected_glyph)) |glyph| {
                const metrics = glyph.metrics;

                const metric_info = std.fmt.bufPrint(&buf, "Glyph: '{c}' (U+{X:0>4})", .{
                    @as(u8, @truncate(selected_glyph)),
                    selected_glyph,
                }) catch "Glyph info";
                try renderer.drawText(metric_info, 20, 25 + line_height * 2, info_scale, white);

                const uv_info = std.fmt.bufPrint(&buf, "UV: ({d:.3},{d:.3}) - ({d:.3},{d:.3})", .{
                    glyph.uv_min[0],
                    glyph.uv_min[1],
                    glyph.uv_max[0],
                    glyph.uv_max[1],
                }) catch "UV info";
                try renderer.drawText(uv_info, 20, 25 + line_height * 3, info_scale, gray);

                const size_info = std.fmt.bufPrint(&buf, "Size: {d:.1}x{d:.1} | Advance: {d:.1}", .{
                    metrics.width,
                    metrics.height,
                    metrics.advance_width,
                }) catch "Size info";
                try renderer.drawText(size_info, 20, 25 + line_height * 4, info_scale, gray);

                const bearing_info = std.fmt.bufPrint(&buf, "Bearing: ({d:.1}, {d:.1})", .{
                    metrics.bearing_x,
                    metrics.bearing_y,
                }) catch "Bearing info";
                try renderer.drawText(bearing_info, 20, 25 + line_height * 5, info_scale, gray);

                const zoom_info = std.fmt.bufPrint(&buf, "Zoom: {d:.1}x", .{zoom_level}) catch "Zoom info";
                try renderer.drawText(zoom_info, 20, 25 + line_height * 6, info_scale, gray);
            }

            // Instructions at bottom
            try renderer.drawText("Arrows: browse | Scroll: zoom | R: reset | Space: toggle", 20, 740, info_scale, gray);
        } else {
            // Show sample text with zoom and pan
            const base_scale: f32 = 0.8;
            const line_spacing: f32 = 75 * text_zoom;

            try renderer.drawText("Sample Text View", text_pan_x, text_pan_y, base_scale * text_zoom, white);
            try renderer.drawText("The quick brown fox jumps over the lazy dog.", text_pan_x, text_pan_y + line_spacing, text_zoom, white);
            try renderer.drawText("ABCDEFGHIJKLMNOPQRSTUVWXYZ", text_pan_x, text_pan_y + line_spacing * 2, base_scale * text_zoom, yellow);
            try renderer.drawText("abcdefghijklmnopqrstuvwxyz", text_pan_x, text_pan_y + line_spacing * 3, base_scale * text_zoom, yellow);
            try renderer.drawText("0123456789 !@#$%^&*()+-=[]{}|;:',.<>?", text_pan_x, text_pan_y + line_spacing * 4, 0.7 * text_zoom, gray);

            // Instructions at bottom (fixed position)
            var buf: [128]u8 = undefined;
            const zoom_info = std.fmt.bufPrint(&buf, "Zoom: {d:.2}x | R: reset | Space: atlas view", .{text_zoom}) catch "Zoom info";
            try renderer.drawText(zoom_info, 20, 738, 0.4, gray);
        }

        _ = renderer.render(.{ 0.15, 0.15, 0.2, 1.0 });
    }

    log.info("Atlas demo finished", .{});
}
