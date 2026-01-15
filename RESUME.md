# MSDF Examples - Project Complete

## Project Status: Fully Working GPU Pipeline

The project has a fully working GPU pipeline with MSDF shaders on macOS (Metal) and Linux/Windows (SPIR-V/Vulkan). Text renders crisply at any scale thanks to the MSDF algorithm.

## What's Working

- **zig-msdf integration** - Font loading and MSDF atlas generation
- **SDL3 GPU rendering** - Hardware-accelerated MSDF text rendering with shaders
- **Platform-specific shaders** - Metal on macOS, SPIR-V elsewhere
- **HiDPI/Retina support** - Automatic scaling for high-DPI displays
- **All examples working**:
  - `zig build run-gpu` - GPU accelerated demo (recommended)
  - `zig build run-basic` - SDL3 2D renderer demo (simpler fallback)
  - `zig build run-atlas` - Atlas visualization with glyph metrics
  - `zig build run-interactive` - Interactive text with zoom/pan/colors

## Controls

- **ESC** - Exit
- **SPACE** - Toggle view mode
- **Mouse wheel / UP/DOWN** - Zoom in/out
- **Arrow keys** - Pan (interactive example)
- **Tab** - Change text color (interactive example)
- **R** - Reset view (interactive example)

## Commands

```bash
# Build
zig build

# Run examples
zig build run-gpu         # GPU accelerated (recommended)
zig build run-basic       # SDL3 2D renderer
zig build run-atlas       # Atlas visualization
zig build run-interactive # Interactive demo

# Recompile shaders (if GLSL changed)
glslc -fshader-stage=vertex shaders/msdf.vert -o src/msdf.vert.spv
glslc -fshader-stage=fragment shaders/msdf.frag -o src/msdf.frag.spv
spirv-cross --msl src/msdf.vert.spv --output src/msdf.vert.metal
spirv-cross --msl src/msdf.frag.spv --output src/msdf.frag.metal
```

## Key Implementation Details

### Platform Shader Selection (src/msdf_gpu.zig)

```zig
const is_macos = builtin.os.tag == .macos;
const vert_shader_code = if (is_macos) @embedFile("msdf.vert.metal") else @embedFile("msdf.vert.spv");
const frag_shader_code = if (is_macos) @embedFile("msdf.frag.metal") else @embedFile("msdf.frag.spv");
const shader_format = if (is_macos) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
const shader_entrypoint = if (is_macos) "main0" else "main";
```

### HiDPI Support

- Window created with `SDL_WINDOW_HIGH_PIXEL_DENSITY` flag
- Swapchain dimensions used for uniforms (physical pixels)
- Vertex positions scaled by display scale factor

### Glyph Metrics

The zig-msdf library returns **normalized metrics** (0-1 range). Multiply by `glyph_size` to get pixel dimensions:
```zig
const gw = m.width * self.glyph_size * scale;
const gh = m.height * self.glyph_size * scale;
```

## Dependencies

- zig-msdf: `git+https://github.com/PhilipLudington/zig-msdf#main`
- SDL3: `git+https://github.com/allyourcodebase/SDL3#main`
- Font: DejaVu Sans (OFL licensed, bundled)
- spirv-cross: For generating Metal shaders (`brew install spirv-cross`)

## File Structure

```
zig-msdf-examples/
├── build.zig                 # Build configuration
├── build.zig.zon             # Dependencies
├── src/
│   ├── main.zig              # Entry point
│   ├── assets.zig            # Embedded font
│   ├── msdf_gpu.zig          # GPU pipeline
│   ├── msdf.vert.spv         # SPIR-V vertex shader
│   ├── msdf.frag.spv         # SPIR-V fragment shader
│   ├── msdf.vert.metal       # Metal vertex shader
│   ├── msdf.frag.metal       # Metal fragment shader
│   └── examples/
│       ├── basic_text.zig    # SDL3 2D renderer
│       ├── gpu_text.zig      # GPU shader example
│       ├── atlas_demo.zig    # Atlas visualization
│       └── interactive.zig   # Interactive demo
```
