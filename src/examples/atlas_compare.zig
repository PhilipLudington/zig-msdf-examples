//! Atlas Comparison Example
//!
//! Allows switching between different MSDF atlas sources to compare rendering:
//! - zig-msdf generated atlas (runtime)
//! - msdfgen reference atlas (loaded from file)
//!
//! Usage:
//!   msdf-examples compare [msdfgen-atlas-dir]
//!
//! The msdfgen atlas directory should contain:
//!   - atlas.png: The MSDF atlas texture (RGBA)
//!   - atlas.json: Glyph metrics in msdfgen-atlas format
//!
//! If no atlas directory is provided, only zig-msdf atlas is shown.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msdf = @import("msdf");
const assets = @import("assets");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const builtin = @import("builtin");
const log = std.log.scoped(.atlas_compare);

// Platform-specific shader selection
const is_macos = builtin.os.tag == .macos;
const vert_shader_code = if (is_macos) @embedFile("../msdf.vert.metal") else @embedFile("../msdf.vert.spv");
const frag_shader_code = if (is_macos) @embedFile("../msdf.frag.metal") else @embedFile("../msdf.frag.spv");
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

/// Atlas source type
const AtlasSource = enum {
    zig_msdf,
    msdfgen,
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

    pub fn msdfgenAtlasPath(self: FontType) []const u8 {
        return switch (self) {
            .dejavu_sans => "msdfgen-atlas",
            .sf_mono => "msdfgen-atlas-sfmono",
            .jetbrains_mono => "msdfgen-atlas-jetbrains",
        };
    }
};

/// Loaded atlas data
const LoadedAtlas = struct {
    texture: *c.SDL_GPUTexture,
    glyphs: std.AutoHashMap(u21, msdf.AtlasGlyph),
    width: u32,
    height: u32,
    px_range: f32,
    glyph_size: f32,
    padding: f32,
    /// If true, uses zig-msdf uniform cell layout with padding adjustments.
    /// If false, uses tight packing (msdfgen) where UVs map directly to glyph content.
    uses_uniform_cells: bool,

    fn deinit(self: *LoadedAtlas, device: *c.SDL_GPUDevice, allocator: Allocator) void {
        c.SDL_ReleaseGPUTexture(device, self.texture);
        self.glyphs.deinit();
        _ = allocator;
    }
};

/// Font atlas resources (font + generated atlas + GPU texture)
const FontAtlasResources = struct {
    font: msdf.Font,
    atlas_result: msdf.AtlasResult,
    loaded_atlas: LoadedAtlas,
    font_type: FontType,

    fn deinit(self: *FontAtlasResources, device: *c.SDL_GPUDevice) void {
        c.SDL_ReleaseGPUTexture(device, self.loaded_atlas.texture);
        self.atlas_result.deinit(self.font.allocator);
        self.font.deinit();
    }
};

/// Create font atlas resources for a given font type
fn createFontAtlas(
    allocator: Allocator,
    device: *c.SDL_GPUDevice,
    font_type: FontType,
    glyph_size: u32,
    px_range: f32,
    padding: u32,
    charset: []const u8,
) !FontAtlasResources {
    log.info("Loading font: {s}", .{font_type.name()});

    var font = msdf.Font.fromMemory(allocator, font_type.fontData()) catch |err| {
        log.err("Font load failed for {s}: {}", .{ font_type.name(), err });
        return error.FontLoadFailed;
    };
    errdefer font.deinit();

    var atlas_result = msdf.generateAtlas(allocator, font, .{
        .chars = charset,
        .glyph_size = glyph_size,
        .padding = padding,
        .range = px_range,
    }) catch |err| {
        log.err("Atlas generation failed for {s}: {}", .{ font_type.name(), err });
        return error.AtlasGenerationFailed;
    };
    errdefer atlas_result.deinit(allocator);

    log.info("{s} atlas: {}x{}, {} glyphs", .{
        font_type.name(),
        atlas_result.width,
        atlas_result.height,
        atlas_result.glyphs.count(),
    });

    const texture = createAtlasTexture(device, atlas_result.width, atlas_result.height) orelse
        return error.TextureCreationFailed;

    uploadAtlasData(device, texture, atlas_result.pixels, atlas_result.width, atlas_result.height);

    return FontAtlasResources{
        .font = font,
        .atlas_result = atlas_result,
        .loaded_atlas = LoadedAtlas{
            .texture = texture,
            .glyphs = atlas_result.glyphs,
            .width = atlas_result.width,
            .height = atlas_result.height,
            .px_range = px_range,
            .glyph_size = @floatFromInt(glyph_size),
            .padding = @floatFromInt(padding),
            .uses_uniform_cells = true,
        },
        .font_type = font_type,
    };
}

pub fn run(allocator: Allocator) !void {
    log.info("Starting Atlas Comparison Example", .{});

    // Parse command line for optional msdfgen atlas path
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var msdfgen_atlas_path: ?[]const u8 = null;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "compare") and i + 1 < args.len) {
            msdfgen_atlas_path = args[i + 1];
            break;
        }
    }

    // Initialize SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "MSDF Atlas Comparison - Press SPACE to toggle, T for test text",
        1024,
        768,
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

    // Create pipeline
    const pipeline = createPipeline(device, vert_shader, frag_shader) orelse return error.PipelineCreationFailed;
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    // Create sampler
    const sampler = createSampler(device) orelse return error.SamplerCreationFailed;
    defer c.SDL_ReleaseGPUSampler(device, sampler);

    // Atlas generation parameters
    const glyph_size: u32 = 48;
    const px_range: f32 = 4.0;
    const padding: u32 = 4;
    const charset = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-=+[]{}|;:',.<>?/~`\"\\";

    // Load fonts and generate atlases
    var font_atlases: [3]FontAtlasResources = undefined;
    var fonts_loaded: usize = 0;

    // Load DejaVu Sans (font 1)
    font_atlases[0] = createFontAtlas(allocator, device, .dejavu_sans, glyph_size, px_range, padding, charset) catch |err| {
        log.err("Failed to create DejaVu Sans atlas: {}", .{err});
        return err;
    };
    fonts_loaded = 1;
    errdefer font_atlases[0].deinit(device);

    // Load SF Mono (font 2)
    font_atlases[1] = createFontAtlas(allocator, device, .sf_mono, glyph_size, px_range, padding, charset) catch |err| {
        log.err("Failed to create SF Mono atlas: {}", .{err});
        return err;
    };
    fonts_loaded = 2;
    errdefer font_atlases[1].deinit(device);

    // Load JetBrains Mono (font 3)
    font_atlases[2] = createFontAtlas(allocator, device, .jetbrains_mono, glyph_size, px_range, padding, charset) catch |err| {
        log.err("Failed to create JetBrains Mono atlas: {}", .{err});
        return err;
    };
    fonts_loaded = 3;

    defer {
        for (0..fonts_loaded) |i| {
            font_atlases[i].deinit(device);
        }
    }

    // Current font selection (0 = DejaVu Sans, 1 = SF Mono, 2 = JetBrains Mono)
    var current_font_index: usize = 0;

    // Try to load msdfgen atlases for each font
    const MsdfgenAtlasData = struct {
        atlas: ?LoadedAtlas,
        glyphs: ?std.AutoHashMap(u21, msdf.AtlasGlyph),
        pixels: ?[]u8,
    };
    var msdfgen_atlases: [3]MsdfgenAtlasData = .{
        .{ .atlas = null, .glyphs = null, .pixels = null },
        .{ .atlas = null, .glyphs = null, .pixels = null },
        .{ .atlas = null, .glyphs = null, .pixels = null },
    };
    defer {
        for (&msdfgen_atlases) |*msdfgen_data| {
            if (msdfgen_data.atlas) |*atlas| {
                c.SDL_ReleaseGPUTexture(device, atlas.texture);
            }
            if (msdfgen_data.glyphs) |*g| {
                g.deinit();
            }
            if (msdfgen_data.pixels) |p| {
                allocator.free(p);
            }
        }
    }

    // Load msdfgen atlas for each font from their respective directories
    const font_types = [_]FontType{ .dejavu_sans, .sf_mono, .jetbrains_mono };
    for (font_types, 0..) |font_type, i| {
        const path = if (msdfgen_atlas_path != null and i == 0)
            msdfgen_atlas_path.? // Use command-line path for first font if provided
        else
            font_type.msdfgenAtlasPath();

        log.info("Loading msdfgen atlas for {s} from: {s}", .{ font_type.name(), path });
        if (loadMsdfgenAtlas(allocator, device, path)) |loaded| {
            msdfgen_atlases[i].glyphs = loaded.glyphs;
            msdfgen_atlases[i].pixels = loaded.pixels;
            msdfgen_atlases[i].atlas = LoadedAtlas{
                .texture = loaded.texture,
                .glyphs = loaded.glyphs,
                .width = loaded.width,
                .height = loaded.height,
                .px_range = loaded.px_range,
                .glyph_size = loaded.glyph_size,
                .padding = loaded.padding,
                .uses_uniform_cells = false, // msdfgen uses tight packing
            };
            log.info("{s} msdfgen atlas loaded: {}x{}, {} glyphs", .{ font_type.name(), loaded.width, loaded.height, loaded.glyphs.count() });
        } else |err| {
            log.warn("Failed to load msdfgen atlas for {s}: {}", .{ font_type.name(), err });
        }
    }

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
    var current_source: AtlasSource = .zig_msdf;
    var show_atlas: bool = false;
    var running = true;
    var vertices = std.ArrayListUnmanaged(Vertex){};
    defer vertices.deinit(allocator);

    // Text view zoom/pan state
    var text_scale: f32 = 1.0;
    var text_pan_x: f32 = 50;
    var text_pan_y: f32 = 100;
    const min_text_scale: f32 = 0.1;
    const max_text_scale: f32 = 8.0;

    // Atlas view zoom/pan state
    var atlas_scale: f32 = 1.0;
    var atlas_pan_x: f32 = 50;
    var atlas_pan_y: f32 = 80;
    const min_atlas_scale: f32 = 0.2;
    const max_atlas_scale: f32 = 10.0;

    // Mouse position
    var mouse_x: f32 = 512;
    var mouse_y: f32 = 384;

    // Drag state for panning
    var is_dragging = false;
    var drag_start_x: f32 = 0;
    var drag_start_y: f32 = 0;
    var drag_start_pan_x: f32 = 0;
    var drag_start_pan_y: f32 = 0;

    log.info("Controls:", .{});
    log.info("  1     - Select DejaVu Sans font", .{});
    log.info("  2     - Select SF Mono font", .{});
    log.info("  3     - Select JetBrains Mono font", .{});
    log.info("  SPACE - Toggle between zig-msdf and msdfgen atlas", .{});
    log.info("  T     - Toggle atlas view / text view", .{});
    log.info("  E     - Export current font atlas to zig-msdf-atlas/ directory", .{});
    log.info("  UP/DOWN or Mouse wheel - Adjust scale", .{});
    log.info("  ESC   - Exit", .{});

    while (running) {
        // Handle events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    const key = event.key.key;
                    if (key == c.SDLK_ESCAPE) running = false;
                    // Font selection with number keys
                    if (key == c.SDLK_1) {
                        if (current_font_index != 0) {
                            current_font_index = 0;
                            log.info("Switched to font: {s}", .{font_atlases[0].font_type.name()});
                        }
                    }
                    if (key == c.SDLK_2) {
                        if (current_font_index != 1) {
                            current_font_index = 1;
                            log.info("Switched to font: {s}", .{font_atlases[1].font_type.name()});
                        }
                    }
                    if (key == c.SDLK_3) {
                        if (current_font_index != 2) {
                            current_font_index = 2;
                            log.info("Switched to font: {s}", .{font_atlases[2].font_type.name()});
                        }
                    }
                    if (key == c.SDLK_SPACE) {
                        // Toggle between zig-msdf and msdfgen atlas for current font
                        if (msdfgen_atlases[current_font_index].atlas != null) {
                            current_source = if (current_source == .zig_msdf) .msdfgen else .zig_msdf;
                            log.info("Switched to: {s}", .{@tagName(current_source)});
                        } else {
                            log.info("No msdfgen atlas loaded for {s}", .{font_atlases[current_font_index].font_type.name()});
                        }
                    }
                    if (key == 't' or key == 'T') {
                        show_atlas = !show_atlas;
                    }
                    if (key == 'e' or key == 'E') {
                        exportAtlas(allocator, &font_atlases[current_font_index].atlas_result, glyph_size, px_range, padding) catch |err| {
                            log.err("Failed to export atlas: {}", .{err});
                        };
                    }
                    // R to reset zoom and pan
                    if (key == 'r' or key == 'R') {
                        if (show_atlas) {
                            atlas_scale = 1.0;
                            atlas_pan_x = 50;
                            atlas_pan_y = 80;
                        } else {
                            text_scale = 1.0;
                            text_pan_x = 50;
                            text_pan_y = 100;
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    mouse_x = event.motion.x;
                    mouse_y = event.motion.y;

                    // Handle drag panning
                    if (is_dragging) {
                        const dx = event.motion.x - drag_start_x;
                        const dy = event.motion.y - drag_start_y;
                        if (show_atlas) {
                            atlas_pan_x = drag_start_pan_x + dx;
                            atlas_pan_y = drag_start_pan_y + dy;
                        } else {
                            text_pan_x = drag_start_pan_x + dx;
                            text_pan_y = drag_start_pan_y + dy;
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        is_dragging = true;
                        drag_start_x = event.button.x;
                        drag_start_y = event.button.y;
                        if (show_atlas) {
                            drag_start_pan_x = atlas_pan_x;
                            drag_start_pan_y = atlas_pan_y;
                        } else {
                            drag_start_pan_x = text_pan_x;
                            drag_start_pan_y = text_pan_y;
                        }
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

                    if (show_atlas) {
                        // Atlas view zoom
                        const old_scale = atlas_scale;
                        if (event.wheel.y > 0) {
                            atlas_scale = @min(atlas_scale * zoom_factor, max_atlas_scale);
                        } else if (event.wheel.y < 0) {
                            atlas_scale = @max(atlas_scale / zoom_factor, min_atlas_scale);
                        }
                        // Adjust pan to keep mouse position fixed
                        const zoom_ratio = atlas_scale / old_scale;
                        atlas_pan_x = wheel_x - (wheel_x - atlas_pan_x) * zoom_ratio;
                        atlas_pan_y = wheel_y - (wheel_y - atlas_pan_y) * zoom_ratio;
                    } else {
                        // Text view zoom
                        const old_scale = text_scale;
                        if (event.wheel.y > 0) {
                            text_scale = @min(text_scale * zoom_factor, max_text_scale);
                        } else if (event.wheel.y < 0) {
                            text_scale = @max(text_scale / zoom_factor, min_text_scale);
                        }
                        // Adjust pan to keep mouse position fixed
                        const zoom_ratio = text_scale / old_scale;
                        text_pan_x = wheel_x - (wheel_x - text_pan_x) * zoom_ratio;
                        text_pan_y = wheel_y - (wheel_y - text_pan_y) * zoom_ratio;
                    }
                },
                else => {},
            }
        }

        // Get current atlas (use selected font's atlas, or msdfgen if in comparison mode)
        const zig_atlas = &font_atlases[current_font_index].loaded_atlas;
        const atlas: *const LoadedAtlas = switch (current_source) {
            .zig_msdf => zig_atlas,
            .msdfgen => if (msdfgen_atlases[current_font_index].atlas) |*a| a else zig_atlas,
        };

        // Clear vertices
        vertices.clearRetainingCapacity();

        // Draw font/source info header (shown on both screens)
        const font_name = font_atlases[current_font_index].font_type.name();
        const source_name = @tagName(current_source);
        var title_buf: [128]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Font: {s} | Source: {s}", .{ font_name, source_name }) catch "Font: ?";
        try addText(&vertices, allocator, atlas, title, 50, 30, 0.6, .{ 1.0, 0.8, 0.2, 1.0 });

        if (show_atlas) {
            // Draw the atlas texture itself with zoom and pan
            const base_size: f32 = 512;
            try addAtlasQuadScaled(&vertices, allocator, atlas, atlas_pan_x, atlas_pan_y, base_size * atlas_scale);

            // Scale indicator (fixed position)
            var scale_buf: [64]u8 = undefined;
            const scale_text = std.fmt.bufPrint(&scale_buf, "Zoom: {d:.2}x | R: reset | T: text view", .{atlas_scale}) catch "Zoom: ?";
            try addText(&vertices, allocator, atlas, scale_text, 50, 730, 0.35, .{ 0.4, 0.4, 0.4, 1.0 });
        } else {
            // Draw demo text with zoom and pan
            const line_spacing: f32 = 60 * text_scale;
            try addText(&vertices, allocator, atlas, "MSDF Text Rendering", text_pan_x, text_pan_y, text_scale, .{ 1.0, 1.0, 1.0, 1.0 });
            try addText(&vertices, allocator, atlas, "The quick brown fox jumps", text_pan_x, text_pan_y + line_spacing, text_scale * 0.6, .{ 0.8, 0.8, 0.8, 1.0 });
            try addText(&vertices, allocator, atlas, "over the lazy dog.", text_pan_x, text_pan_y + line_spacing * 1.67, text_scale * 0.6, .{ 0.8, 0.8, 0.8, 1.0 });

            // Scale indicator (fixed position)
            var scale_buf: [64]u8 = undefined;
            const scale_text = std.fmt.bufPrint(&scale_buf, "Zoom: {d:.2}x | R: reset | T: atlas view", .{text_scale}) catch "Zoom: ?";
            try addText(&vertices, allocator, atlas, scale_text, 50, 700, 0.4, .{ 0.5, 0.5, 0.5, 1.0 });

            // Instructions
            try addText(&vertices, allocator, atlas, "1/2/3=font, SPACE=source, Scroll=zoom", 50, 730, 0.35, .{ 0.4, 0.4, 0.4, 1.0 });
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
            .clear_color = c.SDL_FColor{ .r = 0.08, .g = 0.08, .b = 0.12, .a = 1.0 },
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
            c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);

            const uniforms = Uniforms{
                .screen_size = .{ @floatFromInt(swapchain_w), @floatFromInt(swapchain_h) },
                .px_range = atlas.px_range,
            };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));

            const texture_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = atlas.texture,
                .sampler = sampler,
            };
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &texture_binding, 1);

            const buffer_binding = c.SDL_GPUBufferBinding{ .buffer = vertex_buffer, .offset = 0 };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

            c.SDL_DrawGPUPrimitives(render_pass, @intCast(vertices.items.len), 1, 0, 0);
        }
        if (render_pass != null) {
            c.SDL_EndGPURenderPass(render_pass);
        }

        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    log.info("Example finished", .{});
}

fn addText(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, atlas: *const LoadedAtlas, text: []const u8, x: f32, y: f32, scale: f32, color: [4]f32) !void {
    var cursor_x = x;
    const padding_frac = atlas.padding / atlas.glyph_size;

    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |codepoint| {
        const glyph = atlas.glyphs.get(codepoint) orelse {
            cursor_x += atlas.glyph_size * 0.3 * scale;
            continue;
        };

        const m = glyph.metrics;
        if (m.width <= 0.001 or m.height <= 0.001) {
            cursor_x += m.advance_width * atlas.glyph_size * scale;
            continue;
        }

        const gx = cursor_x + m.bearing_x * atlas.glyph_size * scale;
        const gy = y + (1.0 - m.bearing_y) * atlas.glyph_size * scale;
        const gw = m.width * atlas.glyph_size * scale;
        const gh = m.height * atlas.glyph_size * scale;

        // Calculate UV coordinates
        var tex_u0: f32 = undefined;
        var tex_v0: f32 = undefined;
        var tex_u1: f32 = undefined;
        var tex_v1: f32 = undefined;

        if (atlas.uses_uniform_cells) {
            // zig-msdf: glyphs are in uniform cells with padding, need to calculate inner UVs
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

            tex_u0 = glyph.uv_min[0] + uv_full_width * h_margin;
            tex_v0 = glyph.uv_min[1] + uv_full_height * v_margin;
            tex_u1 = glyph.uv_max[0] - uv_full_width * h_margin;
            tex_v1 = glyph.uv_max[1] - uv_full_height * v_margin;
        } else {
            // msdfgen: UVs already point directly to glyph content, use as-is
            tex_u0 = glyph.uv_min[0];
            tex_v0 = glyph.uv_min[1];
            tex_u1 = glyph.uv_max[0];
            tex_v1 = glyph.uv_max[1];
        }

        try vertices.appendSlice(allocator, &[_]Vertex{
            .{ .pos = .{ gx, gy }, .uv = .{ tex_u0, tex_v0 }, .color = color },
            .{ .pos = .{ gx + gw, gy }, .uv = .{ tex_u1, tex_v0 }, .color = color },
            .{ .pos = .{ gx, gy + gh }, .uv = .{ tex_u0, tex_v1 }, .color = color },
            .{ .pos = .{ gx + gw, gy }, .uv = .{ tex_u1, tex_v0 }, .color = color },
            .{ .pos = .{ gx + gw, gy + gh }, .uv = .{ tex_u1, tex_v1 }, .color = color },
            .{ .pos = .{ gx, gy + gh }, .uv = .{ tex_u0, tex_v1 }, .color = color },
        });

        cursor_x += m.advance_width * atlas.glyph_size * scale;
    }
}

fn addAtlasQuadScaled(vertices: *std.ArrayListUnmanaged(Vertex), allocator: Allocator, atlas: *const LoadedAtlas, x: f32, y: f32, size: f32) !void {
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

const MsdfgenLoadResult = struct {
    texture: *c.SDL_GPUTexture,
    glyphs: std.AutoHashMap(u21, msdf.AtlasGlyph),
    pixels: []u8,
    width: u32,
    height: u32,
    px_range: f32,
    glyph_size: f32,
    padding: f32,
};

fn loadMsdfgenAtlas(allocator: Allocator, device: *c.SDL_GPUDevice, dir_path: []const u8) !MsdfgenLoadResult {
    // Build paths
    var png_path_buf: [1024]u8 = undefined;
    var json_path_buf: [1024]u8 = undefined;

    const png_path = std.fmt.bufPrint(&png_path_buf, "{s}/atlas.png", .{dir_path}) catch return error.PathTooLong;
    const json_path = std.fmt.bufPrint(&json_path_buf, "{s}/atlas.json", .{dir_path}) catch return error.PathTooLong;

    // Load PNG using SDL
    const png_path_z = try allocator.dupeZ(u8, png_path);
    defer allocator.free(png_path_z);

    const surface = c.SDL_LoadBMP(png_path_z.ptr); // Try BMP first, then we'll handle PNG
    if (surface == null) {
        // SDL3 base doesn't have PNG support, try loading raw RGBA data
        log.warn("SDL_LoadBMP failed, trying raw RGBA format", .{});

        // Try loading as raw RGBA file
        var rgba_path_buf: [1024]u8 = undefined;
        const rgba_path = std.fmt.bufPrint(&rgba_path_buf, "{s}/atlas.rgba", .{dir_path}) catch return error.PathTooLong;

        const rgba_file = std.fs.cwd().openFile(rgba_path, .{}) catch |err| {
            log.err("Cannot open atlas file (tried .bmp and .rgba): {}", .{err});
            return error.CannotOpenAtlas;
        };
        defer rgba_file.close();

        // Read dimensions from first 8 bytes (width u32, height u32)
        var dim_buf: [8]u8 = undefined;
        _ = rgba_file.readAll(&dim_buf) catch return error.InvalidAtlasFormat;
        const width = std.mem.readInt(u32, dim_buf[0..4], .little);
        const height = std.mem.readInt(u32, dim_buf[4..8], .little);

        const pixel_count = @as(usize, width) * @as(usize, height) * 4;
        const pixels = try allocator.alloc(u8, pixel_count);
        errdefer allocator.free(pixels);

        const bytes_read = rgba_file.readAll(pixels) catch return error.InvalidAtlasFormat;
        if (bytes_read != pixel_count) {
            return error.InvalidAtlasFormat;
        }

        // Load JSON metrics
        var glyphs = try loadMsdfgenJson(allocator, json_path, width, height);
        errdefer glyphs.deinit();

        // Create texture
        const texture = createAtlasTexture(device, width, height) orelse return error.TextureCreationFailed;
        uploadAtlasData(device, texture, pixels, width, height);

        return MsdfgenLoadResult{
            .texture = texture,
            .glyphs = glyphs,
            .pixels = pixels,
            .width = width,
            .height = height,
            .px_range = 4.0,
            .glyph_size = 48.0,
            .padding = 0.0, // msdfgen uses tight packing, no uniform cell padding
        };
    }
    defer c.SDL_DestroySurface(surface);

    const width: u32 = @intCast(surface.*.w);
    const height: u32 = @intCast(surface.*.h);

    // Convert to RGBA if needed
    const rgba_surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA8888);
    if (rgba_surface == null) {
        return error.SurfaceConversionFailed;
    }
    defer c.SDL_DestroySurface(rgba_surface);

    // Copy pixel data
    const pixel_count = @as(usize, width) * @as(usize, height) * 4;
    const pixels = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(pixels);

    const src: [*]const u8 = @ptrCast(rgba_surface.*.pixels);
    @memcpy(pixels, src[0..pixel_count]);

    // Load JSON metrics
    var glyphs = try loadMsdfgenJson(allocator, json_path, width, height);
    errdefer glyphs.deinit();

    // Create texture
    const texture = createAtlasTexture(device, width, height) orelse return error.TextureCreationFailed;
    uploadAtlasData(device, texture, pixels, width, height);

    return MsdfgenLoadResult{
        .texture = texture,
        .glyphs = glyphs,
        .pixels = pixels,
        .width = width,
        .height = height,
        .px_range = 4.0,
        .glyph_size = 48.0,
        .padding = 0.0, // msdfgen uses tight packing, no uniform cell padding
    };
}

fn loadMsdfgenJson(allocator: Allocator, path: []const u8, atlas_width: u32, atlas_height: u32) !std.AutoHashMap(u21, msdf.AtlasGlyph) {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.CannotOpenMetrics;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.MetricsReadFailed;
    defer allocator.free(contents);

    var glyphs = std.AutoHashMap(u21, msdf.AtlasGlyph).init(allocator);
    errdefer glyphs.deinit();

    // Parse msdfgen-atlas JSON format
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return error.JsonParseFailed;
    defer parsed.deinit();

    const root = parsed.value;

    // Get atlas info
    const atlas_info = root.object.get("atlas") orelse return error.MissingAtlasInfo;
    const atlas_obj = atlas_info.object;

    // Get pixel range from atlas info (default to 4)
    _ = atlas_obj.get("distanceRange") orelse null;

    // Get glyphs array
    const glyphs_array = root.object.get("glyphs") orelse return error.MissingGlyphsArray;

    for (glyphs_array.array.items) |glyph_value| {
        const glyph_obj = glyph_value.object;

        // Get unicode codepoint
        const unicode_value = glyph_obj.get("unicode") orelse continue;
        const codepoint: u21 = @intCast(switch (unicode_value) {
            .integer => |i| @as(u32, @intCast(i)),
            else => continue,
        });

        // Get advance (required)
        const advance = getJsonFloat(glyph_obj.get("advance") orelse continue);

        // Get atlas bounds (optional - space and other invisible glyphs don't have these)
        var uv_min = [2]f32{ 0, 0 };
        var uv_max = [2]f32{ 0, 0 };

        if (glyph_obj.get("atlasBounds")) |atlas_bounds_value| {
            const ab = atlas_bounds_value.object;

            const ab_left = getJsonFloat(ab.get("left") orelse continue);
            const ab_bottom = getJsonFloat(ab.get("bottom") orelse continue);
            const ab_right = getJsonFloat(ab.get("right") orelse continue);
            const ab_top = getJsonFloat(ab.get("top") orelse continue);

            // Convert pixel coordinates to UV coordinates
            // msdfgen uses bottom-left origin (yOrigin: "bottom"), we need top-left
            const atlas_w: f32 = @floatFromInt(atlas_width);
            const atlas_h: f32 = @floatFromInt(atlas_height);

            // Flip Y: uv_y = 1.0 - (pixel_y / atlas_h)
            uv_min = [2]f32{ ab_left / atlas_w, (atlas_h - ab_top) / atlas_h };
            uv_max = [2]f32{ ab_right / atlas_w, (atlas_h - ab_bottom) / atlas_h };
        }

        // Get plane bounds (optional - for metrics)
        var bearing_x: f32 = 0;
        var bearing_y: f32 = 0;
        var width: f32 = 0;
        var height: f32 = 0;

        if (glyph_obj.get("planeBounds")) |pb_value| {
            const pb = pb_value.object;
            const pb_left = getJsonFloat(pb.get("left") orelse continue);
            const pb_bottom = getJsonFloat(pb.get("bottom") orelse continue);
            const pb_right = getJsonFloat(pb.get("right") orelse continue);
            const pb_top = getJsonFloat(pb.get("top") orelse continue);

            bearing_x = pb_left;
            bearing_y = pb_top;
            width = pb_right - pb_left;
            height = pb_top - pb_bottom;
        }

        try glyphs.put(codepoint, msdf.AtlasGlyph{
            .uv_min = uv_min,
            .uv_max = uv_max,
            .metrics = msdf.GlyphMetrics{
                .advance_width = advance,
                .bearing_x = bearing_x,
                .bearing_y = bearing_y,
                .width = width,
                .height = height,
            },
        });
    }

    return glyphs;
}

fn getJsonFloat(value: std.json.Value) f32 {
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
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

    const shader = c.SDL_CreateGPUShader(device, &create_info);
    if (shader == null) {
        log.err("Shader creation failed: {s}", .{c.SDL_GetError()});
    }
    return shader;
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

    const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &create_info);
    if (pipeline == null) {
        log.err("Pipeline creation failed: {s}", .{c.SDL_GetError()});
    }
    return pipeline;
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
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @intCast(pixels.len),
        .props = 0,
    };

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false);
    if (mapped != null) {
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..pixels.len], pixels);
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);
    }

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
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}

fn createSampler(device: *c.SDL_GPUDevice) ?*c.SDL_GPUSampler {
    const create_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0,
        .max_lod = 0,
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

/// Export the zig-msdf atlas to files for comparison with msdfgen
fn exportAtlas(allocator: Allocator, atlas: *const msdf.AtlasResult, glyph_size: u32, px_range: f32, padding: u32) !void {
    const dir_path = "zig-msdf-atlas";

    // Create output directory
    std.fs.cwd().makeDir(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Export raw RGBA data (with dimensions header)
    {
        const rgba_path = dir_path ++ "/atlas.rgba";
        const file = try std.fs.cwd().createFile(rgba_path, .{});
        defer file.close();

        // Write dimensions
        var dim_buf: [8]u8 = undefined;
        std.mem.writeInt(u32, dim_buf[0..4], atlas.width, .little);
        std.mem.writeInt(u32, dim_buf[4..8], atlas.height, .little);
        try file.writeAll(&dim_buf);

        // Write pixel data
        try file.writeAll(atlas.pixels);

        log.info("Exported atlas texture to {s} ({}x{})", .{ rgba_path, atlas.width, atlas.height });
    }

    // Export as PPM (easy to view without special tools)
    {
        const ppm_path = dir_path ++ "/atlas.ppm";
        const file = try std.fs.cwd().createFile(ppm_path, .{});
        defer file.close();

        // PPM header
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ atlas.width, atlas.height }) catch unreachable;
        try file.writeAll(header);

        // Write RGB data (skip alpha)
        const pixel_count = @as(usize, atlas.width) * @as(usize, atlas.height);
        const rgb_data = try allocator.alloc(u8, pixel_count * 3);
        defer allocator.free(rgb_data);

        for (0..pixel_count) |i| {
            rgb_data[i * 3 + 0] = atlas.pixels[i * 4 + 0]; // R
            rgb_data[i * 3 + 1] = atlas.pixels[i * 4 + 1]; // G
            rgb_data[i * 3 + 2] = atlas.pixels[i * 4 + 2]; // B
        }
        try file.writeAll(rgb_data);

        log.info("Exported atlas as PPM to {s}", .{ppm_path});
    }

    // Export JSON metrics in msdfgen-atlas format
    {
        const json_path = dir_path ++ "/atlas.json";
        const file = try std.fs.cwd().createFile(json_path, .{});
        defer file.close();

        var buf: [65536]u8 = undefined;
        var offset: usize = 0;

        // Write header
        const header_fmt =
            \\{{
            \\  "atlas": {{
            \\    "type": "msdf",
            \\    "distanceRange": {d:.1},
            \\    "size": {d},
            \\    "width": {d},
            \\    "height": {d},
            \\    "yOrigin": "top"
            \\  }},
            \\  "glyphs": [
            \\
        ;
        const header = std.fmt.bufPrint(buf[offset..], header_fmt, .{ px_range, glyph_size, atlas.width, atlas.height }) catch unreachable;
        offset += header.len;

        // Write glyphs
        var first = true;
        var iter = atlas.glyphs.iterator();
        while (iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const glyph = entry.value_ptr.*;

            if (!first) {
                buf[offset] = ',';
                offset += 1;
                buf[offset] = '\n';
                offset += 1;
            }
            first = false;

            // Convert UV to pixel coordinates
            const atlas_w: f32 = @floatFromInt(atlas.width);
            const atlas_h: f32 = @floatFromInt(atlas.height);
            const ab_left = glyph.uv_min[0] * atlas_w;
            const ab_top = glyph.uv_min[1] * atlas_h;
            const ab_right = glyph.uv_max[0] * atlas_w;
            const ab_bottom = glyph.uv_max[1] * atlas_h;

            const glyph_fmt =
                \\    {{
                \\      "unicode": {d},
                \\      "advance": {d:.6},
                \\      "planeBounds": {{
                \\        "left": {d:.6},
                \\        "bottom": {d:.6},
                \\        "right": {d:.6},
                \\        "top": {d:.6}
                \\      }},
                \\      "atlasBounds": {{
                \\        "left": {d:.1},
                \\        "bottom": {d:.1},
                \\        "right": {d:.1},
                \\        "top": {d:.1}
                \\      }}
                \\    }}
            ;

            const m = glyph.metrics;
            const glyph_str = std.fmt.bufPrint(buf[offset..], glyph_fmt, .{
                codepoint,
                m.advance_width,
                m.bearing_x,
                m.bearing_y - m.height,
                m.bearing_x + m.width,
                m.bearing_y,
                ab_left,
                ab_bottom,
                ab_right,
                ab_top,
            }) catch {
                log.warn("Buffer overflow writing glyph {d}", .{codepoint});
                break;
            };
            offset += glyph_str.len;
        }

        // Write footer
        const footer = "\n  ]\n}\n";
        @memcpy(buf[offset..][0..footer.len], footer);
        offset += footer.len;

        try file.writeAll(buf[0..offset]);

        log.info("Exported glyph metrics to {s} ({d} glyphs)", .{ json_path, atlas.glyphs.count() });
        _ = padding;
    }

    log.info("Atlas export complete! Files in {s}/", .{dir_path});
    log.info("  atlas.ppm  - Viewable with most image viewers", .{});
    log.info("  atlas.rgba - Raw RGBA with dimension header", .{});
    log.info("  atlas.json - Glyph metrics (msdfgen-atlas format)", .{});
}
