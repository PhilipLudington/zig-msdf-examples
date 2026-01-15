//! SDL3 GPU wrapper for hardware-accelerated rendering.
//!
//! Provides a Zig-friendly interface to SDL3's GPU API.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const GpuError = error{
    SdlInitFailed,
    WindowCreationFailed,
    DeviceCreationFailed,
    WindowClaimFailed,
    TextureCreationFailed,
    SamplerCreationFailed,
    BufferCreationFailed,
    ShaderCreationFailed,
    PipelineCreationFailed,
    TransferFailed,
};

pub const Config = struct {
    title: [:0]const u8 = "MSDF Example",
    width: u32 = 800,
    height: u32 = 600,
    vsync: bool = true,
};

pub const Gpu = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    width: u32,
    height: u32,

    pub fn init(config: Config) GpuError!Gpu {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
            return GpuError.SdlInitFailed;
        }
        errdefer c.SDL_Quit();

        const window = c.SDL_CreateWindow(
            config.title.ptr,
            @intCast(config.width),
            @intCast(config.height),
            c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
            return GpuError.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        const device = c.SDL_CreateGPUDevice(
            c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_DXIL,
            true,
            null,
        ) orelse {
            std.log.err("SDL_CreateGPUDevice failed: {s}", .{c.SDL_GetError()});
            return GpuError.DeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
            return GpuError.WindowClaimFailed;
        }

        return Gpu{
            .window = window,
            .device = device,
            .width = config.width,
            .height = config.height,
        };
    }

    pub fn deinit(self: *Gpu) void {
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.* = undefined;
    }

    pub fn getWindowSize(self: *const Gpu) struct { width: u32, height: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        return .{
            .width = @intCast(@max(1, w)),
            .height = @intCast(@max(1, h)),
        };
    }

    pub fn beginFrame(self: *Gpu) ?*c.SDL_GPUCommandBuffer {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
            return null;
        };

        return cmd;
    }

    pub fn beginRenderPass(self: *Gpu, cmd: *c.SDL_GPUCommandBuffer, clear_color: [4]f32) ?*c.SDL_GPURenderPass {
        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, null, null)) {
            std.log.err("SDL_WaitAndAcquireGPUSwapchainTexture failed: {s}", .{c.SDL_GetError()});
            return null;
        }

        if (swapchain_texture == null) {
            return null;
        }

        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
            .clear_color = c.SDL_FColor{
                .r = clear_color[0],
                .g = clear_color[1],
                .b = clear_color[2],
                .a = clear_color[3],
            },
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
        return render_pass;
    }

    pub fn endRenderPass(_: *Gpu, render_pass: *c.SDL_GPURenderPass) void {
        c.SDL_EndGPURenderPass(render_pass);
    }

    pub fn endFrame(_: *Gpu, cmd: *c.SDL_GPUCommandBuffer) void {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    pub fn createTexture(self: *Gpu, width: u32, height: u32, format: TextureFormat) GpuError!Texture {
        const sdl_format: c.SDL_GPUTextureFormat = switch (format) {
            .rgba8 => c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .rgb8 => c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        };

        const create_info = c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        };

        const texture = c.SDL_CreateGPUTexture(self.device, &create_info) orelse {
            std.log.err("SDL_CreateGPUTexture failed: {s}", .{c.SDL_GetError()});
            return GpuError.TextureCreationFailed;
        };

        return Texture{
            .handle = texture,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn uploadTextureData(self: *Gpu, texture: *const Texture, data: []const u8) GpuError!void {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return GpuError.TransferFailed;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return GpuError.TransferFailed;
        };

        const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @intCast(data.len),
            .props = 0,
        };

        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(self.device, &transfer_info) orelse {
            c.SDL_EndGPUCopyPass(copy_pass);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return GpuError.TransferFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer_buffer);

        const mapped = c.SDL_MapGPUTransferBuffer(self.device, transfer_buffer, false);
        if (mapped == null) {
            c.SDL_EndGPUCopyPass(copy_pass);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return GpuError.TransferFailed;
        }

        @memcpy(@as([*]u8, @ptrCast(mapped))[0..data.len], data);
        c.SDL_UnmapGPUTransferBuffer(self.device, transfer_buffer);

        const transfer_src = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
            .pixels_per_row = texture.width,
            .rows_per_layer = texture.height,
        };

        const transfer_dst = c.SDL_GPUTextureRegion{
            .texture = texture.handle,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = texture.width,
            .h = texture.height,
            .d = 1,
        };

        c.SDL_UploadToGPUTexture(copy_pass, &transfer_src, &transfer_dst, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    pub fn destroyTexture(self: *Gpu, texture: *Texture) void {
        c.SDL_ReleaseGPUTexture(self.device, texture.handle);
        texture.* = undefined;
    }

    pub fn createSampler(self: *Gpu, config: SamplerConfig) GpuError!Sampler {
        const create_info = c.SDL_GPUSamplerCreateInfo{
            .min_filter = if (config.linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = if (config.linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST,
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

        const sampler = c.SDL_CreateGPUSampler(self.device, &create_info) orelse {
            std.log.err("SDL_CreateGPUSampler failed: {s}", .{c.SDL_GetError()});
            return GpuError.SamplerCreationFailed;
        };

        return Sampler{ .handle = sampler };
    }

    pub fn destroySampler(self: *Gpu, sampler: *Sampler) void {
        c.SDL_ReleaseGPUSampler(self.device, sampler.handle);
        sampler.* = undefined;
    }

    pub fn createBuffer(self: *Gpu, size: u32, usage: BufferUsage) GpuError!Buffer {
        const sdl_usage: c.SDL_GPUBufferUsageFlags = switch (usage) {
            .vertex => c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .index => c.SDL_GPU_BUFFERUSAGE_INDEX,
        };

        const create_info = c.SDL_GPUBufferCreateInfo{
            .usage = sdl_usage,
            .size = size,
            .props = 0,
        };

        const buffer = c.SDL_CreateGPUBuffer(self.device, &create_info) orelse {
            std.log.err("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
            return GpuError.BufferCreationFailed;
        };

        return Buffer{
            .handle = buffer,
            .size = size,
            .usage = usage,
        };
    }

    pub fn uploadBufferData(self: *Gpu, buffer: *const Buffer, data: []const u8) GpuError!void {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return GpuError.TransferFailed;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return GpuError.TransferFailed;
        };

        const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @intCast(data.len),
            .props = 0,
        };

        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(self.device, &transfer_info) orelse {
            c.SDL_EndGPUCopyPass(copy_pass);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return GpuError.TransferFailed;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer_buffer);

        const mapped = c.SDL_MapGPUTransferBuffer(self.device, transfer_buffer, false);
        if (mapped == null) {
            c.SDL_EndGPUCopyPass(copy_pass);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return GpuError.TransferFailed;
        }

        @memcpy(@as([*]u8, @ptrCast(mapped))[0..data.len], data);
        c.SDL_UnmapGPUTransferBuffer(self.device, transfer_buffer);

        const transfer_src = c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        };

        const transfer_dst = c.SDL_GPUBufferRegion{
            .buffer = buffer.handle,
            .offset = 0,
            .size = @intCast(data.len),
        };

        c.SDL_UploadToGPUBuffer(copy_pass, &transfer_src, &transfer_dst, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    pub fn destroyBuffer(self: *Gpu, buffer: *Buffer) void {
        c.SDL_ReleaseGPUBuffer(self.device, buffer.handle);
        buffer.* = undefined;
    }
};

pub const TextureFormat = enum {
    rgba8,
    rgb8,
};

pub const Texture = struct {
    handle: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
    format: TextureFormat,
};

pub const SamplerConfig = struct {
    linear: bool = true,
};

pub const Sampler = struct {
    handle: *c.SDL_GPUSampler,
};

pub const BufferUsage = enum {
    vertex,
    index,
};

pub const Buffer = struct {
    handle: *c.SDL_GPUBuffer,
    size: u32,
    usage: BufferUsage,
};

// Event handling
pub const Event = union(enum) {
    quit,
    key_down: KeyEvent,
    key_up: KeyEvent,
    text_input: TextInputEvent,
    mouse_motion: MouseMotionEvent,
    mouse_button_down: MouseButtonEvent,
    mouse_button_up: MouseButtonEvent,
    mouse_wheel: MouseWheelEvent,
    window_resized: WindowResizeEvent,
    unknown,
};

pub const KeyEvent = struct {
    scancode: u32,
    keycode: u32,
    mod: u16,
};

pub const TextInputEvent = struct {
    text: []const u8,
};

pub const MouseMotionEvent = struct {
    x: f32,
    y: f32,
    xrel: f32,
    yrel: f32,
    button_mask: u32,
};

pub const MouseButtonEvent = struct {
    x: f32,
    y: f32,
    button: u8,
    clicks: u8,
};

pub const MouseWheelEvent = struct {
    x: f32,
    y: f32,
};

pub const WindowResizeEvent = struct {
    width: u32,
    height: u32,
};

pub fn pollEvent() ?Event {
    var sdl_event: c.SDL_Event = undefined;
    if (!c.SDL_PollEvent(&sdl_event)) {
        return null;
    }

    return switch (sdl_event.type) {
        c.SDL_EVENT_QUIT => .quit,
        c.SDL_EVENT_KEY_DOWN => .{ .key_down = .{
            .scancode = sdl_event.key.scancode,
            .keycode = sdl_event.key.key,
            .mod = sdl_event.key.mod,
        } },
        c.SDL_EVENT_KEY_UP => .{ .key_up = .{
            .scancode = sdl_event.key.scancode,
            .keycode = sdl_event.key.key,
            .mod = sdl_event.key.mod,
        } },
        c.SDL_EVENT_TEXT_INPUT => blk: {
            const text = std.mem.span(@as([*:0]const u8, @ptrCast(&sdl_event.text.text)));
            break :blk .{ .text_input = .{ .text = text } };
        },
        c.SDL_EVENT_MOUSE_MOTION => .{ .mouse_motion = .{
            .x = sdl_event.motion.x,
            .y = sdl_event.motion.y,
            .xrel = sdl_event.motion.xrel,
            .yrel = sdl_event.motion.yrel,
            .button_mask = sdl_event.motion.state,
        } },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .mouse_button_down = .{
            .x = sdl_event.button.x,
            .y = sdl_event.button.y,
            .button = sdl_event.button.button,
            .clicks = sdl_event.button.clicks,
        } },
        c.SDL_EVENT_MOUSE_BUTTON_UP => .{ .mouse_button_up = .{
            .x = sdl_event.button.x,
            .y = sdl_event.button.y,
            .button = sdl_event.button.button,
            .clicks = sdl_event.button.clicks,
        } },
        c.SDL_EVENT_MOUSE_WHEEL => .{ .mouse_wheel = .{
            .x = sdl_event.wheel.x,
            .y = sdl_event.wheel.y,
        } },
        c.SDL_EVENT_WINDOW_RESIZED => .{ .window_resized = .{
            .width = @intCast(@max(1, sdl_event.window.data1)),
            .height = @intCast(@max(1, sdl_event.window.data2)),
        } },
        else => .unknown,
    };
}

// Re-export C types for external use
pub const c_api = c;

test "gpu initialization smoke test" {
    // Skip actual GPU init in tests as it requires display
}
