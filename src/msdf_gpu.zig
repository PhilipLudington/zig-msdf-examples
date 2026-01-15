//! MSDF GPU Text Renderer
//!
//! Hardware-accelerated MSDF text rendering using SDL3 GPU API.
//! This provides crisp, resolution-independent text at any scale.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const msdf = @import("msdf");
const assets = @import("assets");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const log = std.log.scoped(.msdf_gpu);

// Platform-specific shader selection
const is_macos = builtin.os.tag == .macos;

// Embedded shaders - use Metal on macOS, SPIR-V elsewhere
const vert_shader_code = if (is_macos) @embedFile("msdf.vert.metal") else @embedFile("msdf.vert.spv");
const frag_shader_code = if (is_macos) @embedFile("msdf.frag.metal") else @embedFile("msdf.frag.spv");
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

pub const MsdfGpuError = error{
    SdlInitFailed,
    WindowCreationFailed,
    DeviceCreationFailed,
    ShaderCreationFailed,
    PipelineCreationFailed,
    TextureCreationFailed,
    BufferCreationFailed,
    FontLoadFailed,
    AtlasGenerationFailed,
};

pub const MsdfGpuRenderer = struct {
    allocator: Allocator,
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    atlas_texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    vertex_buffer: *c.SDL_GPUBuffer,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    atlas: msdf.AtlasResult,
    font: msdf.Font,
    vertices: std.ArrayListUnmanaged(Vertex),
    px_range: f32,
    glyph_size: f32,
    max_vertices: u32,

    pub fn init(allocator: Allocator, config: Config) MsdfGpuError!MsdfGpuRenderer {
        // Initialize SDL
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
            return MsdfGpuError.SdlInitFailed;
        }
        errdefer c.SDL_Quit();

        // Create window with HiDPI support
        const window = c.SDL_CreateWindow(
            config.title.ptr,
            @intCast(config.width),
            @intCast(config.height),
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse {
            log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
            return MsdfGpuError.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        // Create GPU device with the shader format we have compiled
        const device = c.SDL_CreateGPUDevice(
            shader_format,
            true, // debug mode
            null,
        ) orelse {
            log.err("SDL_CreateGPUDevice failed: {s}", .{c.SDL_GetError()});
            log.err("No supported GPU backend found for {s} shaders. Try the software renderer example instead.", .{
                if (is_macos) "MSL" else "SPIR-V",
            });
            return MsdfGpuError.DeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        // Claim window for GPU
        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
            return MsdfGpuError.DeviceCreationFailed;
        }

        // Load font
        var font = msdf.Font.fromMemory(allocator, config.font_data) catch |err| {
            log.err("Font load failed: {}", .{err});
            return MsdfGpuError.FontLoadFailed;
        };
        errdefer font.deinit();

        // Generate atlas
        var atlas = msdf.generateAtlas(allocator, font, .{
            .chars = config.charset,
            .glyph_size = config.glyph_size,
            .padding = 4,
            .range = config.px_range,
        }) catch |err| {
            log.err("Atlas generation failed: {}", .{err});
            return MsdfGpuError.AtlasGenerationFailed;
        };
        errdefer atlas.deinit(allocator);

        log.info("Atlas: {}x{}, {} glyphs", .{ atlas.width, atlas.height, atlas.glyphs.count() });

        // Create shaders (using platform-specific format)
        log.info("Loading shaders in {s} format", .{if (is_macos) "MSL" else "SPIR-V"});
        const vert_shader = createShader(device, vert_shader_code, .vertex) orelse {
            return MsdfGpuError.ShaderCreationFailed;
        };
        defer c.SDL_ReleaseGPUShader(device, vert_shader);

        const frag_shader = createShader(device, frag_shader_code, .fragment) orelse {
            return MsdfGpuError.ShaderCreationFailed;
        };
        defer c.SDL_ReleaseGPUShader(device, frag_shader);

        // Create pipeline
        const pipeline = createPipeline(device, vert_shader, frag_shader) orelse {
            return MsdfGpuError.PipelineCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        // Create atlas texture
        const atlas_texture = createAtlasTexture(device, &atlas) orelse {
            return MsdfGpuError.TextureCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUTexture(device, atlas_texture);

        // Upload atlas data
        uploadAtlasData(device, atlas_texture, &atlas);

        // Create sampler
        const sampler = createSampler(device) orelse {
            return MsdfGpuError.TextureCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);

        // Create vertex buffer
        const max_vertices: u32 = 10000;
        const vertex_buffer = createVertexBuffer(device, max_vertices) orelse {
            return MsdfGpuError.BufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        // Create transfer buffer for vertex uploads
        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = max_vertices * @sizeOf(Vertex),
            .props = 0,
        }) orelse {
            return MsdfGpuError.BufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

        return MsdfGpuRenderer{
            .allocator = allocator,
            .window = window,
            .device = device,
            .pipeline = pipeline,
            .atlas_texture = atlas_texture,
            .sampler = sampler,
            .vertex_buffer = vertex_buffer,
            .transfer_buffer = transfer_buffer,
            .atlas = atlas,
            .font = font,
            .vertices = .{},
            .px_range = config.px_range,
            .glyph_size = @floatFromInt(config.glyph_size),
            .max_vertices = max_vertices,
        };
    }

    pub fn deinit(self: *MsdfGpuRenderer) void {
        self.vertices.deinit(self.allocator);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.atlas_texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        self.atlas.deinit(self.allocator);
        self.font.deinit();
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.* = undefined;
    }

    /// Add text to render queue
    pub fn drawText(self: *MsdfGpuRenderer, text: []const u8, x: f32, y: f32, scale: f32, color: [4]f32) !void {
        var cursor_x = x;

        // Padding fraction (padding=4 is hardcoded in atlas generation)
        const padding: f32 = 4.0;
        const padding_frac = padding / self.glyph_size;

        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (utf8_iter.nextCodepoint()) |codepoint| {
            const glyph = self.atlas.glyphs.get(codepoint) orelse {
                cursor_x += self.glyph_size * 0.3 * scale;
                continue;
            };

            const m = glyph.metrics;

            // Skip glyphs with no visible size (like space)
            if (m.width <= 0.001 or m.height <= 0.001) {
                cursor_x += m.advance_width * self.glyph_size * scale;
                continue;
            }

            // Position based on bearing (original logic)
            const gx = cursor_x + m.bearing_x * self.glyph_size * scale;
            const gy = y + (1.0 - m.bearing_y) * self.glyph_size * scale;
            const gw = m.width * self.glyph_size * scale;
            const gh = m.height * self.glyph_size * scale;

            // Calculate inner UV coordinates (excluding padding)
            // The glyph is rendered in the inner cell area and centered
            const uv_full_width = glyph.uv_max[0] - glyph.uv_min[0];
            const uv_full_height = glyph.uv_max[1] - glyph.uv_min[1];

            // Available space after padding (as fraction of cell)
            const available_frac = 1.0 - 2.0 * padding_frac;

            // The glyph is scaled to fit in available space, maintaining aspect ratio
            // Calculate how much of the available space the glyph actually uses
            const aspect = m.width / m.height;
            var used_width_frac: f32 = undefined;
            var used_height_frac: f32 = undefined;

            if (aspect >= 1.0) {
                // Wide glyph - fills available width
                used_width_frac = available_frac;
                used_height_frac = available_frac / aspect;
            } else {
                // Tall glyph - fills available height
                used_height_frac = available_frac;
                used_width_frac = available_frac * aspect;
            }

            // Calculate margins (glyph is centered in available space)
            const h_margin = (1.0 - used_width_frac) / 2.0;
            const v_margin = (1.0 - used_height_frac) / 2.0;

            // Adjust UV coordinates
            const tex_u0 = glyph.uv_min[0] + uv_full_width * h_margin;
            const tex_v0 = glyph.uv_min[1] + uv_full_height * v_margin;
            const tex_u1 = glyph.uv_max[0] - uv_full_width * h_margin;
            const tex_v1 = glyph.uv_max[1] - uv_full_height * v_margin;

            // Two triangles for the quad
            try self.vertices.appendSlice(self.allocator, &[_]Vertex{
                .{ .pos = .{ gx, gy }, .uv = .{ tex_u0, tex_v0 }, .color = color },
                .{ .pos = .{ gx + gw, gy }, .uv = .{ tex_u1, tex_v0 }, .color = color },
                .{ .pos = .{ gx, gy + gh }, .uv = .{ tex_u0, tex_v1 }, .color = color },
                .{ .pos = .{ gx + gw, gy }, .uv = .{ tex_u1, tex_v0 }, .color = color },
                .{ .pos = .{ gx + gw, gy + gh }, .uv = .{ tex_u1, tex_v1 }, .color = color },
                .{ .pos = .{ gx, gy + gh }, .uv = .{ tex_u0, tex_v1 }, .color = color },
            });

            cursor_x += m.advance_width * self.glyph_size * scale;
        }
    }

    /// Clear the render queue
    pub fn clear(self: *MsdfGpuRenderer) void {
        self.vertices.clearRetainingCapacity();
    }

    /// Get display scale factor (for HiDPI/Retina displays)
    pub fn getDisplayScale(self: *const MsdfGpuRenderer) f32 {
        // Try SDL_GetWindowDisplayScale first (SDL3 preferred method)
        const scale = c.SDL_GetWindowDisplayScale(self.window);
        if (scale > 0) {
            return scale;
        }
        // Fallback to computing from window sizes
        var logical_w: c_int = 0;
        var physical_w: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &logical_w, null);
        _ = c.SDL_GetWindowSizeInPixels(self.window, &physical_w, null);
        if (logical_w > 0 and physical_w > logical_w) {
            return @as(f32, @floatFromInt(physical_w)) / @as(f32, @floatFromInt(logical_w));
        }
        return 1.0;
    }

    /// Render a frame
    pub fn render(self: *MsdfGpuRenderer, clear_color: [4]f32) bool {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return false;

        // Get swapchain texture
        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var swapchain_w: u32 = 0;
        var swapchain_h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, &swapchain_w, &swapchain_h)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }
        if (swapchain_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return false;
        }

        // Upload vertex data if we have any
        if (self.vertices.items.len > 0) {
            const data_size = self.vertices.items.len * @sizeOf(Vertex);
            const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.transfer_buffer, false);
            if (mapped != null) {
                const dest: [*]Vertex = @ptrCast(@alignCast(mapped));
                // Scale vertex positions for HiDPI displays
                // Use swapchain size vs logical window size for accurate scale
                var logical_w: c_int = 0;
                _ = c.SDL_GetWindowSize(self.window, &logical_w, null);
                const display_scale: f32 = if (logical_w > 0)
                    @as(f32, @floatFromInt(swapchain_w)) / @as(f32, @floatFromInt(logical_w))
                else
                    1.0;
                for (self.vertices.items, 0..) |vert, i| {
                    dest[i] = Vertex{
                        .pos = .{ vert.pos[0] * display_scale, vert.pos[1] * display_scale },
                        .uv = vert.uv,
                        .color = vert.color,
                    };
                }
                c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer_buffer);

                // Copy to vertex buffer
                const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
                if (copy_pass != null) {
                    c.SDL_UploadToGPUBuffer(
                        copy_pass,
                        &c.SDL_GPUTransferBufferLocation{ .transfer_buffer = self.transfer_buffer, .offset = 0 },
                        &c.SDL_GPUBufferRegion{ .buffer = self.vertex_buffer, .offset = 0, .size = @intCast(data_size) },
                        false,
                    );
                    c.SDL_EndGPUCopyPass(copy_pass);
                }
            }
        }

        // Begin render pass
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
            .clear_color = c.SDL_FColor{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] },
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
        if (render_pass != null and self.vertices.items.len > 0) {
            // Bind pipeline
            c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

            // Use swapchain dimensions for uniforms (accurate for HiDPI)

            // Push uniforms
            const uniforms = Uniforms{
                .screen_size = .{ @floatFromInt(swapchain_w), @floatFromInt(swapchain_h) },
                .px_range = self.px_range,
            };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &uniforms, @sizeOf(Uniforms));

            // Bind texture and sampler
            const texture_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = self.atlas_texture,
                .sampler = self.sampler,
            };
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &texture_binding, 1);

            // Bind vertex buffer
            const buffer_binding = c.SDL_GPUBufferBinding{ .buffer = self.vertex_buffer, .offset = 0 };
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &buffer_binding, 1);

            // Draw
            c.SDL_DrawGPUPrimitives(render_pass, @intCast(self.vertices.items.len), 1, 0, 0);

            c.SDL_EndGPURenderPass(render_pass);
        } else if (render_pass != null) {
            c.SDL_EndGPURenderPass(render_pass);
        }

        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return true;
    }

    pub fn getAtlas(self: *const MsdfGpuRenderer) *const msdf.AtlasResult {
        return &self.atlas;
    }

    pub const Config = struct {
        title: [:0]const u8 = "MSDF Demo",
        width: u32 = 1024,
        height: u32 = 768,
        font_data: []const u8,
        charset: []const u8 = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-=+[]{}|;:',.<>?/~`\"\\",
        glyph_size: u32 = 48,
        px_range: f32 = 4.0,
    };
};

fn createShader(device: *c.SDL_GPUDevice, code: []const u8, stage: enum { vertex, fragment }) ?*c.SDL_GPUShader {
    const sdl_stage: c.SDL_GPUShaderStage = switch (stage) {
        .vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
        .fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    };

    const num_samplers: u32 = if (stage == .fragment) 1 else 0;
    const num_uniform_buffers: u32 = 1;

    const create_info = c.SDL_GPUShaderCreateInfo{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = shader_entrypoint,
        .format = shader_format,
        .stage = sdl_stage,
        .num_samplers = num_samplers,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    };

    const shader = c.SDL_CreateGPUShader(device, &create_info);
    if (shader == null) {
        log.err("Shader creation failed ({s} format): {s}", .{
            if (is_macos) "MSL" else "SPIR-V",
            c.SDL_GetError(),
        });
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
        .format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM, // Common swapchain format
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

fn createAtlasTexture(device: *c.SDL_GPUDevice, atlas: *const msdf.AtlasResult) ?*c.SDL_GPUTexture {
    const create_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = atlas.width,
        .height = atlas.height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };

    return c.SDL_CreateGPUTexture(device, &create_info);
}

fn uploadAtlasData(device: *c.SDL_GPUDevice, texture: *c.SDL_GPUTexture, atlas: *const msdf.AtlasResult) void {
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    const data_size = atlas.pixels.len;
    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @intCast(data_size),
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
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..atlas.pixels.len], atlas.pixels);
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);
    }

    c.SDL_UploadToGPUTexture(
        copy_pass,
        &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
            .pixels_per_row = atlas.width,
            .rows_per_layer = atlas.height,
        },
        &c.SDL_GPUTextureRegion{
            .texture = texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = atlas.width,
            .h = atlas.height,
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

/// Poll for SDL events
pub fn pollEvent() ?Event {
    var sdl_event: c.SDL_Event = undefined;
    if (!c.SDL_PollEvent(&sdl_event)) return null;

    return switch (sdl_event.type) {
        c.SDL_EVENT_QUIT => .quit,
        c.SDL_EVENT_KEY_DOWN => .{ .key_down = sdl_event.key.key },
        c.SDL_EVENT_KEY_UP => .{ .key_up = sdl_event.key.key },
        c.SDL_EVENT_MOUSE_WHEEL => .{ .mouse_wheel = sdl_event.wheel.y },
        else => .other,
    };
}

pub const Event = union(enum) {
    quit,
    key_down: u32,
    key_up: u32,
    mouse_wheel: f32,
    other,
};
