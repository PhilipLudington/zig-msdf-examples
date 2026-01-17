# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zig-msdf-examples demonstrates MSDF (Multi-channel Signed Distance Field) text rendering using the zig-msdf library with GPU acceleration via SDL3. MSDF enables resolution-independent text rendering with crisp edges at any scale.

## Build Commands

```bash
zig build                    # Build all examples
zig build run-gpu            # Run GPU text example (recommended starting point)
zig build run-basic          # Run basic text rendering example
zig build run-atlas          # Run atlas visualization demo
zig build run-interactive    # Run interactive demo with text input/zoom/pan
zig build run-compare        # Run zig-msdf vs msdfgen comparison
zig build test               # Run unit tests
```

## Architecture

### Module Structure

```
src/
├── main.zig              # Entry point, routes to examples by argument
├── msdf_gpu.zig          # High-level MSDF GPU renderer (integrates zig-msdf + SDL3)
├── shaders.zig           # GLSL/SPIR-V/Metal shader definitions
├── assets.zig            # Embedded font resources (@embedFile)
├── renderer/
│   ├── gpu.zig           # SDL3 GPU abstraction layer
│   └── text_renderer.zig # MSDF-specific text rendering pipeline
└── examples/
    ├── basic_text.zig    # Multi-scale text demo
    ├── gpu_text.zig      # GPU rendering variant
    ├── atlas_demo.zig    # Glyph atlas visualization
    ├── interactive.zig   # Real-time text input with zoom/pan
    └── atlas_compare.zig # Comparison with external msdfgen
```

### Key Components

**MsdfGpuRenderer** (`src/msdf_gpu.zig`): Main renderer that combines zig-msdf font loading, atlas generation, and SDL3 GPU rendering. Handles the full text rendering pipeline including vertex buffer management and shader uniforms.

**GPU Abstraction** (`src/renderer/gpu.zig`): Wraps SDL3 GPU API for cross-platform rendering. Manages window creation, textures, buffers, shaders, and render pipelines.

**Shader System** (`src/shaders.zig`): Platform-specific shaders - Metal for macOS, SPIR-V for Linux/Windows. Embedded at compile time.

### Dependencies

- **zig-msdf** (local path `../zig-msdf`) - Font parsing and MSDF atlas generation
- **SDL3** - GPU rendering and windowing

### Platform Support

- macOS: Metal shaders (`.metal` files)
- Linux/Windows: SPIR-V shaders (`.spv` files)

## Development Standards

This project uses CarbideZig standards (see `carbide/CARBIDE.md` and `carbide/STANDARDS.md`). Key patterns:

- Allocator injection for all allocating functions
- `defer`/`errdefer` immediately after resource acquisition
- Specific error sets per module (e.g., `MsdfGpuError`, `GpuError`)
- Scoped logging with `std.log.scoped`

## Controls (All Examples)

- **ESC** - Exit
- **Mouse Wheel** - Zoom
- **Arrow Keys / +/-** - Scale adjustment
- **Space** - Toggle display modes (some examples)
- **Type characters** - Text input (interactive/atlas demos)
