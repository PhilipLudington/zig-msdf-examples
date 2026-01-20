//! Coloring Features Demo
//!
//! Demonstrates the new edge coloring features in zig-msdf:
//! - ColoringMode: .simple vs .distance_based algorithms
//! - Seed: Different seeds produce different valid colorings
//! - Corner angle threshold: Controls corner detection sensitivity
//! - Overlap correction: Fixes overlapping same-winding contours
//!
//! Controls:
//!   SPACE       - Toggle between .simple and .distance_based modes
//!   LEFT/RIGHT  - Cycle through different seeds (0-9)
//!   UP/DOWN     - Adjust corner angle threshold
//!   T           - Toggle text view / atlas view
//!   V           - Toggle raw RGB view (shows coloring directly)
//!   R           - Reset zoom and pan
//!   1/2/3       - Select font
//!   O           - Toggle overlap correction
//!   ESC         - Exit

const std = @import("std");
const Allocator = std.mem.Allocator;
const msdf = @import("msdf");
const assets = @import("assets");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const builtin = @import("builtin");
const log = std.log.scoped(.coloring_demo);

// Platform-specific shader selection
const is_macos = builtin.os.tag == .macos;
const vert_shader_code = if (is_macos) @embedFile("../msdf.vert.metal") else @embedFile("../msdf.vert.spv");
const frag_shader_code = if (is_macos) @embedFile("../msdf.frag.metal") else @embedFile("../msdf.frag.spv");
const passthrough_frag_code = if (is_macos) @embedFile("../passthrough.frag.metal") else @embedFile("../passthrough.frag.spv");
const shader_format = if (is_macos) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
const shader_entrypoint = if (is_macos) "main0" else "main";

/// Vertex structure matching shader input
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// Uniform buffer structure
const Uniforms = extern struct {
    screen_size: [2]f32,
    px_range: f32,
    _padding: f32 = 0,
};

/// Font selection
const FontType = enum {
    dejavu_sans,
    sf_mono,
    jetbrains_mono,

    pub fn name(self: FontType) []const u8 {
        return switch (self) {
            .dejavu_sans => "DejaVu Sans",
            .sf_mono => "SF Mono",
            .jetbrains_mono => "JetBrains Mono",
        };
    }

    pub fn fontData(self: FontType) []const u8 {
        return switch (self) {
            .dejavu_sans => assets.dejavu_sans,
            .sf_mono => assets.sf_mono,
            .jetbrains_mono => assets.jetbrains_mono,
        };
    }
};

/// Coloring configuration state
const ColoringState = struct {
    mode: msdf.coloring.ColoringMode = .simple,
    seed: u64 = 0,
    corner_threshold: f64 = 3.0, // Default: ~172 degrees
    correct_overlaps: bool = false,

    pub fn toConfig(self: ColoringState) msdf.coloring.ColoringConfig {
        return .{
            .mode = self.mode,
            .seed = self.seed,
            .corner_angle_threshold = self.corner_threshold,
            .distance_threshold = 0.5,
        };
    }

    pub fn formatDescription(self: ColoringState, buf: []u8) []const u8 {
        const mode_str = switch (self.mode) {
            .simple => "simple",
            .distance_based => "distance",
        };
        const threshold_deg = self.corner_threshold * 180.0 / std.math.pi;
        return std.fmt.bufPrint(buf, "Mode: {s} | Seed: {d} | Threshold: {d:.0}deg | Overlaps: {s}", .{
            mode_str,
            self.seed,
            threshold_deg,
            if (self.correct_overlaps) "ON" else "OFF",
        }) catch "???";
    }
};

/// Loaded atlas data
const LoadedAtlas = struct {
    texture: *c.SDL_GPUTexture,
    glyphs: std.AutoHashMap(u21, msdf.AtlasGlyph),
    pixels: []u8,
    width: u32,
    height: u32,
    px_range: f32,
    glyph_size: f32,
    padding: f32,
    coloring_state: ColoringState,

    fn deinit(self: *LoadedAtlas, device: *c.SDL_GPUDevice, allocator: Allocator) void {
        c.SDL_ReleaseGPUTexture(device, self.texture);
        self.glyphs.deinit();
        allocator.free(self.pixels);
    }
};

/// Background generation task
const GenerationTask = struct {
    // Input parameters
    allocator: Allocator,
    font_data: []const u8,
    coloring_state: ColoringState,
    glyph_size: u32,
    px_range: f32,
    padding: u32,
    charset: []const u8,

    // Output (set by worker thread)
    result: ?AtlasGenResult = null,
    err: ?anyerror = null,

    // Synchronization
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    start_time: i64 = 0,

    const AtlasGenResult = struct {
        pixels: []u8,
        glyphs: std.AutoHashMap(u21, msdf.AtlasGlyph),
        width: u32,
        height: u32,
    };

    fn workerFn(self: *GenerationTask) void {
        self.doGenerate() catch |e| {
            self.err = e;
        };
        self.completed.store(true, .release);
    }

    fn doGenerate(self: *GenerationTask) !void {
        // Load font in worker thread
        var font = msdf.Font.fromMemory(self.allocator, self.font_data) catch |err| {
            log.err("Worker: Font load failed: {}", .{err});
            return err;
        };
        defer font.deinit();

        // Generate atlas
        const atlas_result = msdf.generateAtlas(self.allocator, font, .{
            .chars = self.charset,
            .glyph_size = self.glyph_size,
            .padding = self.padding,
            .range = self.px_range,
            .coloring_config = self.coloring_state.toConfig(),
            .correct_overlaps = self.coloring_state.correct_overlaps,
        }) catch |err| {
            log.err("Worker: Atlas generation failed: {}", .{err});
            return err;
        };

        // Copy pixels (we'll free atlas_result.pixels but keep glyphs)
        const pixel_count = @as(usize, atlas_result.width) * @as(usize, atlas_result.height) * 4;
        const pixels = try self.allocator.alloc(u8, pixel_count);
        @memcpy(pixels, atlas_result.pixels);

        // Store result
        self.result = .{
            .pixels = pixels,
            .glyphs = atlas_result.glyphs,
            .width = atlas_result.width,
            .height = atlas_result.height,
        };

        // Free original pixels
        self.allocator.free(atlas_result.pixels);
    }

    fn isCompleted(self: *GenerationTask) bool {
        return self.completed.load(.acquire);
    }

    fn getElapsedMs(self: *GenerationTask) i64 {
        const now = std.time.milliTimestamp();
        return now - self.start_time;
    }
};

pub fn run(allocator: Allocator) !void {
    log.info("Starting Coloring Features Demo", .{});

    // Initialize SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "MSDF Coloring Features Demo",
        1200,
        800,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    // Create GPU device
    const device = c.SDL_CreateGPUDevice(
        shader_format,
        true,
        null,
    ) orelse {
        log.err("SDL_CreateGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.DeviceCreationFailed;
    };
    defer c.SDL_DestroyGPUDevice(device);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.DeviceCreationFailed;
    }
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    // Create shaders
    const vert_shader = createShader(device, vert_shader_code, .vertex) orelse return error.ShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, frag_shader_code, .fragment) orelse return error.ShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    const passthrough_frag = createShader(device, passthrough_frag_code, .fragment) orelse return error.ShaderCreationFailed;
    defer c.SDL_ReleaseGPUShader(device, passthrough_frag);

    // Create pipelines
    const pipeline = createPipeline(device, vert_shader, frag_shader) orelse return error.PipelineCreationFailed;
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    const passthrough_pipeline = createPipeline(device, vert_shader, passthrough_frag) orelse return error.PipelineCreationFailed;
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, passthrough_pipeline);

    // Create sampler
    const sampler = createSampler(device) orelse return error.SamplerCreationFailed;
    defer c.SDL_ReleaseGPUSampler(device, sampler);

    // Create 1x1 white texture for UI elements (progress bar, etc.)
    const white_texture = createAtlasTexture(device, 1, 1) orelse return error.TextureCreationFailed;
    defer c.SDL_ReleaseGPUTexture(device, white_texture);
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    uploadAtlasData(device, white_texture, &white_pixel, 1, 1);

    // Atlas parameters
    const glyph_size: u32 = 48;
    const px_range: f32 = 4.0;
    const padding: u32 = 4;
    // Include complex glyphs that benefit from good coloring
    const charset = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@&$%#*{}[]<>|/\\";

    // Current font and coloring state
    var current_font: FontType = .dejavu_sans;
    var coloring_state = ColoringState{};

    // Generate initial atlas (blocking for first load)
    var font = msdf.Font.fromMemory(allocator, current_font.fontData()) catch |err| {
        log.err("Font load failed: {}", .{err});
        return error.FontLoadFailed;
    };
    defer font.deinit();

    var atlas = try generateAtlasSync(allocator, device, font, coloring_state, glyph_size, px_range, padding, charset);
    defer atlas.deinit(device, allocator);

    // Create vertex and transfer buffers
    const max_vertices: u32 = 10000;
    const vertex_buffer = createVertexBuffer(device, max_vertices) orelse return error.BufferCreationFailed;
    defer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = max_vertices * @sizeOf(Vertex),
        .props = 0,
    }) orelse return error.BufferCreationFailed;
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // State
    var running = true;
    var show_atlas: bool = true; // Start with atlas view to see coloring
    var raw_view: bool = true; // Start with raw view to see RGB channels
    var vertices = std.ArrayListUnmanaged(Vertex){};
    defer vertices.deinit(allocator);

    // Zoom/pan state
    var scale: f32 = 2.0; // Start zoomed in
    var pan_x: f32 = 50;
    var pan_y: f32 = 100;
    const min_scale: f32 = 0.2;
    const max_scale: f32 = 10.0;

    // Drag state
    var is_dragging = false;
    var drag_start_x: f32 = 0;
    var drag_start_y: f32 = 0;
    var drag_start_pan_x: f32 = 0;
    var drag_start_pan_y: f32 = 0;

    // Background generation state
    var gen_task: ?*GenerationTask = null;
    var gen_thread: ?std.Thread = null;
    var needs_regenerate = false;

    defer {
        // Clean up any pending generation
        if (gen_thread) |thread| {
            thread.join();
        }
        if (gen_task) |task| {
            if (task.result) |*result| {
                allocator.free(result.pixels);
                result.glyphs.deinit();
            }
            allocator.destroy(task);
        }
    }

    log.info("Controls:", .{});
    log.info("  SPACE     - Toggle .simple / .distance_based mode", .{});
    log.info("  LEFT/RIGHT- Cycle seed (0-9)", .{});
    log.info("  UP/DOWN   - Adjust corner threshold", .{});
    log.info("  O         - Toggle overlap correction", .{});
    log.info("  T         - Toggle atlas/text view", .{});
    log.info("  V         - Toggle raw RGB view", .{});
    log.info("  1/2/3     - Select font", .{});
    log.info("  R         - Reset view", .{});
    log.info("  ESC       - Exit", .{});

    while (running) {
        // Handle events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    // Ignore input while generating
                    if (gen_task != null) continue;

                    const key = event.key.key;
                    if (key == c.SDLK_ESCAPE) running = false;

                    // Toggle coloring mode
                    if (key == c.SDLK_SPACE) {
                        coloring_state.mode = if (coloring_state.mode == .simple) .distance_based else .simple;
                        needs_regenerate = true;
                        log.info("Mode: {s}", .{if (coloring_state.mode == .simple) "simple" else "distance_based"});
                    }

                    // Cycle seed
                    if (key == c.SDLK_RIGHT) {
                        coloring_state.seed = (coloring_state.seed + 1) % 10;
                        needs_regenerate = true;
                        log.info("Seed: {d}", .{coloring_state.seed});
                    }
                    if (key == c.SDLK_LEFT) {
                        coloring_state.seed = if (coloring_state.seed == 0) 9 else coloring_state.seed - 1;
                        needs_regenerate = true;
                        log.info("Seed: {d}", .{coloring_state.seed});
                    }

                    // Adjust threshold
                    if (key == c.SDLK_UP) {
                        coloring_state.corner_threshold = @min(coloring_state.corner_threshold + 0.1, std.math.pi);
                        needs_regenerate = true;
                        const deg = coloring_state.corner_threshold * 180.0 / std.math.pi;
                        log.info("Corner threshold: {d:.1} rad ({d:.0} deg)", .{ coloring_state.corner_threshold, deg });
                    }
                    if (key == c.SDLK_DOWN) {
                        coloring_state.corner_threshold = @max(coloring_state.corner_threshold - 0.1, 0.1);
                        needs_regenerate = true;
                        const deg = coloring_state.corner_threshold * 180.0 / std.math.pi;
                        log.info("Corner threshold: {d:.1} rad ({d:.0} deg)", .{ coloring_state.corner_threshold, deg });
                    }

                    // Toggle overlap correction
                    if (key == 'o' or key == 'O') {
                        coloring_state.correct_overlaps = !coloring_state.correct_overlaps;
                        needs_regenerate = true;
                        log.info("Overlap correction: {s}", .{if (coloring_state.correct_overlaps) "ON" else "OFF"});
                    }

                    // View toggles
                    if (key == 't' or key == 'T') {
                        show_atlas = !show_atlas;
                    }
                    if (key == 'v' or key == 'V') {
                        raw_view = !raw_view;
                        log.info("Raw view: {s}", .{if (raw_view) "enabled" else "disabled"});
                    }
                    if (key == 'r' or key == 'R') {
                        scale = 2.0;
                        pan_x = 50;
                        pan_y = 100;
                    }

                    // Font selection
                    if (key == c.SDLK_1 and current_font != .dejavu_sans) {
                        current_font = .dejavu_sans;
                        needs_regenerate = true;
                        log.info("Font: {s}", .{current_font.name()});
                    }
                    if (key == c.SDLK_2 and current_font != .sf_mono) {
                        current_font = .sf_mono;
                        needs_regenerate = true;
                        log.info("Font: {s}", .{current_font.name()});
                    }
                    if (key == c.SDLK_3 and current_font != .jetbrains_mono) {
                        current_font = .jetbrains_mono;
                        needs_regenerate = true;
                        log.info("Font: {s}", .{current_font.name()});
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    if (is_dragging) {
                        pan_x = drag_start_pan_x + (event.motion.x - drag_start_x);
                        pan_y = drag_start_pan_y + (event.motion.y - drag_start_y);
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        is_dragging = true;
                        drag_start_x = event.button.x;
                        drag_start_y = event.button.y;
                        drag_start_pan_x = pan_x;
                        drag_start_pan_y = pan_y;
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        is_dragging = false;
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    const zoom_factor: f32 = 1.15;
                    const wheel_x = event.wheel.mouse_x;
                    const wheel_y = event.wheel.mouse_y;

                    const old_scale = scale;
                    if (event.wheel.y > 0) {
                        scale = @min(scale * zoom_factor, max_scale);
                    } else if (event.wheel.y < 0) {
                        scale = @max(scale / zoom_factor, min_scale);
                    }
                    // Mouse-centered zoom
                    const zoom_ratio = scale / old_scale;
                    pan_x = wheel_x - (wheel_x - pan_x) * zoom_ratio;
                    pan_y = wheel_y - (wheel_y - pan_y) * zoom_ratio;
                },
                else => {},
            }
        }

        // Start background generation if needed
        if (needs_regenerate and gen_task == null) {
            needs_regenerate = false;

            // Create task
            const task = try allocator.create(GenerationTask);
            task.* = GenerationTask{
                .allocator = allocator,
                .font_data = current_font.fontData(),
                .coloring_state = coloring_state,
                .glyph_size = glyph_size,
                .px_range = px_range,
                .padding = padding,
                .charset = charset,
                .start_time = std.time.milliTimestamp(),
            };
            gen_task = task;

            // Spawn worker thread
            gen_thread = try std.Thread.spawn(.{}, GenerationTask.workerFn, .{task});
        }

        // Check if background generation completed
        if (gen_task) |task| {
            if (task.isCompleted()) {
                // Join thread
                if (gen_thread) |thread| {
                    thread.join();
                    gen_thread = null;
                }

                // Handle result
                if (task.result) |*result| {
                    // Create new atlas from result
                    const texture = createAtlasTexture(device, result.width, result.height) orelse {
                        log.err("Failed to create texture", .{});
                        allocator.free(result.pixels);
                        result.glyphs.deinit();
                        allocator.destroy(task);
                        gen_task = null;
                        continue;
                    };
                    uploadAtlasData(device, texture, result.pixels, result.width, result.height);

                    // Swap atlas
                    atlas.deinit(device, allocator);
                    atlas = LoadedAtlas{
                        .texture = texture,
                        .glyphs = result.glyphs,
                        .pixels = result.pixels,
                        .width = result.width,
                        .height = result.height,
                        .px_range = px_range,
                        .glyph_size = @floatFromInt(glyph_size),
                        .padding = @floatFromInt(padding),
                        .coloring_state = task.coloring_state,
                    };

                    const elapsed = task.getElapsedMs();
                    log.info("Atlas generated in {d}ms: {}x{}, {} glyphs", .{ elapsed, result.width, result.height, result.glyphs.count() });
                } else if (task.err) |err| {
                    log.err("Generation failed: {}", .{err});
                }

                allocator.destroy(task);
                gen_task = null;
            }
        }

        // Clear vertices
        vertices.clearRetainingCapacity();

        // Track vertex ranges for multi-pass rendering
        var bg_panel_start: usize = 0;
        var bg_panel_count: usize = 0;
        var progress_bar_start: usize = 0;
        var progress_bar_count: usize = 0;

        // If generating, draw background panel FIRST (will be rendered with white texture)
        if (gen_task != null) {
            bg_panel_start = vertices.items.len;
            // Dark background panel behind the progress area
            try addQuad(&vertices, allocator, 10, 680, 540, 80, .{ 0.05, 0.05, 0.08, 0.98 });
            bg_panel_count = vertices.items.len - bg_panel_start;
        }

        // Draw header
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Font: {s}", .{current_font.name()}) catch "???";
        try addText(&vertices, allocator, &atlas, header, 20, 30, 0.5, .{ 1.0, 0.8, 0.2, 1.0 });

        // Draw coloring config
        var config_buf: [256]u8 = undefined;
        const config_text = coloring_state.formatDescription(&config_buf);
        try addText(&vertices, allocator, &atlas, config_text, 20, 55, 0.4, .{ 0.6, 0.9, 0.6, 1.0 });

        if (show_atlas) {
            // Draw atlas with zoom/pan
            const base_size: f32 = 400;
            try addAtlasQuad(&vertices, allocator, &atlas, pan_x, pan_y, base_size * scale);

            // Instructions
            if (gen_task == null) {
                try addText(&vertices, allocator, &atlas, "SPACE=mode LEFT/RIGHT=seed UP/DOWN=threshold T=text V=raw", 20, 760, 0.3, .{ 0.5, 0.5, 0.5, 1.0 });
            }
        } else {
            // Draw sample text with complex glyphs
            const samples = [_][]const u8{
                "Complex glyphs: @&$%#{}[]<>",
                "S-curves: S s 8 3 & @",
                "Multi-contour: B 8 0 @ # %",
                "Corners: M W V A K X Z",
                "The quick brown fox jumps over the lazy dog",
            };

            var y: f32 = pan_y;
            for (samples) |text| {
                try addText(&vertices, allocator, &atlas, text, pan_x, y, scale * 0.6, .{ 1.0, 1.0, 1.0, 1.0 });
                y += 50 * scale;
            }

            if (gen_task == null) {
                try addText(&vertices, allocator, &atlas, "SPACE=mode LEFT/RIGHT=seed UP/DOWN=threshold T=atlas", 20, 760, 0.3, .{ 0.5, 0.5, 0.5, 1.0 });
            }
        }

        // Draw generating text (rendered with atlas texture as part of main content)
        if (gen_task) |task| {
            const elapsed_ms = task.getElapsedMs();
            const seconds = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
            var gen_buf: [64]u8 = undefined;
            const gen_text = std.fmt.bufPrint(&gen_buf, "Generating atlas... {d:.1}s", .{seconds}) catch "Generating...";
            try addText(&vertices, allocator, &atlas, gen_text, 20, 695, 0.45, .{ 1.0, 0.95, 0.4, 1.0 });

            // Now add the animated progress bar (rendered with white texture)
            progress_bar_start = vertices.items.len;
            try drawProgressBar(&vertices, allocator, elapsed_ms, 20, 725, 500, 24);
            progress_bar_count = vertices.items.len - progress_bar_start;
        }

        // Render
        const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse continue;

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var swapchain_w: u32 = 0;
        var swapchain_h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain_texture, &swapchain_w, &swapchain_h)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        }
        if (swapchain_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        }

        // Upload vertices
        if (vertices.items.len > 0) {
            const data_size = vertices.items.len * @sizeOf(Vertex);
            const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false);
            if (mapped != null) {
                const dest: [*]Vertex = @ptrCast(@alignCast(mapped));
                var logical_w: c_int = 0;
                _ = c.SDL_GetWindowSize(window, &logical_w, null);
                const display_scale: f32 = if (logical_w > 0)
                    @as(f32, @floatFromInt(swapchain_w)) / @as(f32, @floatFromInt(logical_w))
                else
                    1.0;
                for (vertices.items, 0..) |vert, i| {
                    dest[i] = Vertex{
                        .pos = .{ vert.pos[0] * display_scale, vert.pos[1] * display_scale },
                        .uv = vert.uv,
                        .color = vert.color,
                    };
                }
                c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

                const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
                if (copy_pass != null) {
                    c.SDL_UploadToGPUBuffer(
                        copy_pass,
                        &c.SDL_GPUTransferBufferLocation{ .transfer_buffer = transfer_buffer, .offset = 0 },
                        &c.SDL_GPUBufferRegion{ .buffer = vertex_buffer, .offset = 0, .size = @intCast(data_size) },
                        false,
                    );
                    c.SDL_EndGPUCopyPass(copy_pass);
                }
            }
        }

        // Render pass
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
            .clear_color = c.SDL_FColor{ .r = 0.05, .g = 0.05, .b = 0.08, .a = 1.0 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
        };

        const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
        if (render_pass != null and vertices.items.len > 0) {
            const uniforms = Uniforms{
                .screen_size = .{ @floatFromInt(swapchain_w), @floatFromInt(swapchain_h) },
                .px_range = atlas.px_range,
            };

            const buffer_binding = c.SDL_GPUBufferBinding{ .buffer = vertex_buffer, .offset = 0 };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

            const white_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = white_texture,
                .sampler = sampler,
            };
            const atlas_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = atlas.texture,
                .sampler = sampler,
            };

            // Pass 1: Draw background panel with white texture (if generating)
            if (bg_panel_count > 0) {
                c.SDL_BindGPUGraphicsPipeline(render_pass, passthrough_pipeline);
                c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
                c.SDL_BindGPUFragmentSamplers(render_pass, 0, &white_binding, 1);
                c.SDL_DrawGPUPrimitives(render_pass, @intCast(bg_panel_count), 1, @intCast(bg_panel_start), 0);
            }

            // Pass 2: Draw main content (header, config, atlas/text, generating label) with atlas texture
            const main_start = bg_panel_start + bg_panel_count;
            const main_end = if (progress_bar_count > 0) progress_bar_start else vertices.items.len;
            const main_count = main_end - main_start;

            if (main_count > 0) {
                const use_passthrough = show_atlas and raw_view;
                const content_pipeline = if (use_passthrough) passthrough_pipeline else pipeline;
                c.SDL_BindGPUGraphicsPipeline(render_pass, content_pipeline);
                c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
                c.SDL_BindGPUFragmentSamplers(render_pass, 0, &atlas_binding, 1);
                c.SDL_DrawGPUPrimitives(render_pass, @intCast(main_count), 1, @intCast(main_start), 0);
            }

            // Pass 3: Draw progress bar animation with white texture
            if (progress_bar_count > 0) {
                c.SDL_BindGPUGraphicsPipeline(render_pass, passthrough_pipeline);
                c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
                c.SDL_BindGPUFragmentSamplers(render_pass, 0, &white_binding, 1);
                c.SDL_DrawGPUPrimitives(render_pass, @intCast(progress_bar_count), 1, @intCast(progress_bar_start), 0);
            }
        }
        if (render_pass != null) {
            c.SDL_EndGPURenderPass(render_pass);
        }

        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    log.info("Coloring demo finished", .{});
}

/// Draw an animated progress bar (just the visual bar, no text)
fn drawProgressBar(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, elapsed_ms: i64, x: f32, y: f32, width: f32, height: f32) !void {
    _ = elapsed_ms; // Used for animation timing

    // Background bar (dark)
    try addQuad(vertices, allocator, x, y, width, height, .{ 0.15, 0.15, 0.2, 1.0 });

    // Animated progress (indeterminate style - sliding highlight)
    const cycle_ms: f32 = 1200.0; // Full cycle time
    const now_ms: f32 = @floatFromInt(@mod(std.time.milliTimestamp(), 100000));
    const progress = @mod(now_ms, cycle_ms) / cycle_ms;

    // Create a sliding highlight effect
    const highlight_width = width * 0.25;
    const highlight_x = x + (width - highlight_width) * progress;

    // Glow effect (wider, more transparent) - draw first
    const glow_width = highlight_width * 2.0;
    const glow_x = highlight_x - (glow_width - highlight_width) / 2;
    try addQuad(vertices, allocator, glow_x, y, glow_width, height, .{ 0.2, 0.5, 1.0, 0.4 });

    // Main highlight
    try addQuad(vertices, allocator, highlight_x, y + 3, highlight_width, height - 6, .{ 0.4, 0.8, 1.0, 1.0 });

    // Border
    try addQuadOutline(vertices, allocator, x, y, width, height, 2, .{ 0.5, 0.5, 0.6, 1.0 });
}

fn addQuad(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
    try vertices.appendSlice(allocator, &[_]Vertex{
        .{ .pos = .{ x, y }, .uv = .{ 0, 0 }, .color = color },
        .{ .pos = .{ x + w, y }, .uv = .{ 0, 0 }, .color = color },
        .{ .pos = .{ x, y + h }, .uv = .{ 0, 0 }, .color = color },
        .{ .pos = .{ x + w, y }, .uv = .{ 0, 0 }, .color = color },
        .{ .pos = .{ x + w, y + h }, .uv = .{ 0, 0 }, .color = color },
        .{ .pos = .{ x, y + h }, .uv = .{ 0, 0 }, .color = color },
    });
}

fn addQuadOutline(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: [4]f32) !void {
    // Top
    try addQuad(vertices, allocator, x, y, w, thickness, color);
    // Bottom
    try addQuad(vertices, allocator, x, y + h - thickness, w, thickness, color);
    // Left
    try addQuad(vertices, allocator, x, y, thickness, h, color);
    // Right
    try addQuad(vertices, allocator, x + w - thickness, y, thickness, h, color);
}

fn generateAtlasSync(
    allocator: Allocator,
    device: *c.SDL_GPUDevice,
    font: msdf.Font,
    coloring_state: ColoringState,
    glyph_size: u32,
    px_range: f32,
    padding: u32,
    charset: []const u8,
) !LoadedAtlas {
    log.info("Generating atlas with {s} mode, seed={d}, threshold={d:.2}", .{
        if (coloring_state.mode == .simple) "simple" else "distance_based",
        coloring_state.seed,
        coloring_state.corner_threshold,
    });

    var atlas_result = msdf.generateAtlas(allocator, font, .{
        .chars = charset,
        .glyph_size = glyph_size,
        .padding = padding,
        .range = px_range,
        .coloring_config = coloring_state.toConfig(),
        .correct_overlaps = coloring_state.correct_overlaps,
    }) catch |err| {
        log.err("Atlas generation failed: {}", .{err});
        return error.AtlasGenerationFailed;
    };
    errdefer atlas_result.deinit(allocator);

    // Copy pixels
    const pixel_count = @as(usize, atlas_result.width) * @as(usize, atlas_result.height) * 4;
    const pixels = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(pixels);
    @memcpy(pixels, atlas_result.pixels);

    // Create texture
    const texture = createAtlasTexture(device, atlas_result.width, atlas_result.height) orelse
        return error.TextureCreationFailed;
    uploadAtlasData(device, texture, atlas_result.pixels, atlas_result.width, atlas_result.height);

    const result = LoadedAtlas{
        .texture = texture,
        .glyphs = atlas_result.glyphs,
        .pixels = pixels,
        .width = atlas_result.width,
        .height = atlas_result.height,
        .px_range = px_range,
        .glyph_size = @floatFromInt(glyph_size),
        .padding = @floatFromInt(padding),
        .coloring_state = coloring_state,
    };

    // Free original pixels but keep glyphs
    allocator.free(atlas_result.pixels);

    log.info("Atlas: {}x{}, {} glyphs", .{ result.width, result.height, result.glyphs.count() });

    return result;
}

fn addText(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, atlas: *const LoadedAtlas, text: []const u8, x: f32, y: f32, text_scale: f32, color: [4]f32) !void {
    var cursor_x = x;
    const padding_frac = atlas.padding / atlas.glyph_size;

    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |codepoint| {
        const glyph = atlas.glyphs.get(codepoint) orelse {
            cursor_x += atlas.glyph_size * 0.3 * text_scale;
            continue;
        };

        const m = glyph.metrics;
        if (m.width <= 0.001 or m.height <= 0.001) {
            cursor_x += m.advance_width * atlas.glyph_size * text_scale;
            continue;
        }

        const gx = cursor_x + m.bearing_x * atlas.glyph_size * text_scale;
        const gy = y + (1.0 - m.bearing_y) * atlas.glyph_size * text_scale;
        const gw = m.width * atlas.glyph_size * text_scale;
        const gh = m.height * atlas.glyph_size * text_scale;

        // Calculate UV coordinates (zig-msdf uniform cell layout)
        const uv_full_width = glyph.uv_max[0] - glyph.uv_min[0];
        const uv_full_height = glyph.uv_max[1] - glyph.uv_min[1];
        const available_frac = 1.0 - 2.0 * padding_frac;
        const aspect = m.width / m.height;

        var used_width_frac: f32 = undefined;
        var used_height_frac: f32 = undefined;
        if (aspect >= 1.0) {
            used_width_frac = available_frac;
            used_height_frac = available_frac / aspect;
        } else {
            used_height_frac = available_frac;
            used_width_frac = available_frac * aspect;
        }

        const h_margin = (1.0 - used_width_frac) / 2.0;
        const v_margin = (1.0 - used_height_frac) / 2.0;

        const tex_u0 = glyph.uv_min[0] + uv_full_width * h_margin;
        const tex_v0 = glyph.uv_min[1] + uv_full_height * v_margin;
        const tex_u1 = glyph.uv_max[0] - uv_full_width * h_margin;
        const tex_v1 = glyph.uv_max[1] - uv_full_height * v_margin;

        try vertices.appendSlice(allocator, &[_]Vertex{
            .{ .pos = .{ gx, gy }, .uv = .{ tex_u0, tex_v0 }, .color = color },
            .{ .pos = .{ gx + gw, gy }, .uv = .{ tex_u1, tex_v0 }, .color = color },
            .{ .pos = .{ gx, gy + gh }, .uv = .{ tex_u0, tex_v1 }, .color = color },
            .{ .pos = .{ gx + gw, gy }, .uv = .{ tex_u1, tex_v0 }, .color = color },
            .{ .pos = .{ gx + gw, gy + gh }, .uv = .{ tex_u1, tex_v1 }, .color = color },
            .{ .pos = .{ gx, gy + gh }, .uv = .{ tex_u0, tex_v1 }, .color = color },
        });

        cursor_x += m.advance_width * atlas.glyph_size * text_scale;
    }
}

fn addAtlasQuad(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, atlas: *const LoadedAtlas, x: f32, y: f32, size: f32) !void {
    const aspect = @as(f32, @floatFromInt(atlas.width)) / @as(f32, @floatFromInt(atlas.height));
    const w = size;
    const h = size / aspect;

    try vertices.appendSlice(allocator, &[_]Vertex{
        .{ .pos = .{ x, y }, .uv = .{ 0, 0 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ x + w, y }, .uv = .{ 1, 0 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ x, y + h }, .uv = .{ 0, 1 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ x + w, y }, .uv = .{ 1, 0 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ x + w, y + h }, .uv = .{ 1, 1 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ x, y + h }, .uv = .{ 0, 1 }, .color = .{ 1, 1, 1, 1 } },
    });
}

fn createShader(device: *c.SDL_GPUDevice, code: []const u8, stage: enum { vertex, fragment }) ?*c.SDL_GPUShader {
    const sdl_stage: c.SDL_GPUShaderStage = switch (stage) {
        .vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
        .fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    };

    const num_samplers: u32 = if (stage == .fragment) 1 else 0;

    const create_info = c.SDL_GPUShaderCreateInfo{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = shader_entrypoint,
        .format = shader_format,
        .stage = sdl_stage,
        .num_samplers = num_samplers,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 1,
        .props = 0,
    };

    return c.SDL_CreateGPUShader(device, &create_info);
}

fn createPipeline(device: *c.SDL_GPUDevice, vert: *c.SDL_GPUShader, frag: *c.SDL_GPUShader) ?*c.SDL_GPUGraphicsPipeline {
    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 16 },
    };

    const vertex_buffer_desc = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(Vertex),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };

    const blend_state = c.SDL_GPUColorTargetBlendState{
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = 0xF,
        .enable_blend = true,
        .enable_color_write_mask = false,
    };

    const color_target = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
        .blend_state = blend_state,
    };

    const create_info = c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buffer_desc,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vertex_attributes,
            .num_vertex_attributes = vertex_attributes.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS,
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = false,
            .enable_depth_write = false,
            .enable_stencil_test = false,
        },
        .target_info = .{
            .color_target_descriptions = &color_target,
            .num_color_targets = 1,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            .has_depth_stencil_target = false,
        },
        .props = 0,
    };

    return c.SDL_CreateGPUGraphicsPipeline(device, &create_info);
}

fn createSampler(device: *c.SDL_GPUDevice) ?*c.SDL_GPUSampler {
    const create_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .compare_op = c.SDL_GPU_COMPAREOP_ALWAYS,
        .min_lod = 0,
        .max_lod = 1000,
        .enable_anisotropy = false,
        .enable_compare = false,
        .props = 0,
    };

    return c.SDL_CreateGPUSampler(device, &create_info);
}

fn createVertexBuffer(device: *c.SDL_GPUDevice, max_vertices: u32) ?*c.SDL_GPUBuffer {
    const create_info = c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = max_vertices * @sizeOf(Vertex),
        .props = 0,
    };

    return c.SDL_CreateGPUBuffer(device, &create_info);
}

fn createAtlasTexture(device: *c.SDL_GPUDevice, width: u32, height: u32) ?*c.SDL_GPUTexture {
    const create_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };

    return c.SDL_CreateGPUTexture(device, &create_info);
}

fn uploadAtlasData(device: *c.SDL_GPUDevice, texture: *c.SDL_GPUTexture, pixels: []const u8, width: u32, height: u32) void {
    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @intCast(pixels.len),
        .props = 0,
    }) orelse return;
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false);
    if (mapped != null) {
        const dest: [*]u8 = @ptrCast(mapped);
        @memcpy(dest[0..pixels.len], pixels);
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);
    }

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    if (copy_pass != null) {
        c.SDL_UploadToGPUTexture(
            copy_pass,
            &c.SDL_GPUTextureTransferInfo{
                .transfer_buffer = transfer_buffer,
                .offset = 0,
                .pixels_per_row = width,
                .rows_per_layer = height,
            },
            &c.SDL_GPUTextureRegion{
                .texture = texture,
                .mip_level = 0,
                .layer = 0,
                .x = 0,
                .y = 0,
                .z = 0,
                .w = width,
                .h = height,
                .d = 1,
            },
            false,
        );
        c.SDL_EndGPUCopyPass(copy_pass);
    }
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}
