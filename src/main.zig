//! MSDF Examples - Main Entry Point
//!
//! Usage:
//!   msdf-examples [example]
//!
//! Examples:
//!   basic       - Basic text rendering at multiple scales
//!   gpu         - GPU accelerated rendering with MSDF shaders
//!   atlas       - Atlas texture visualization
//!   interactive - Interactive demo with zoom and pan
//!
//! If no example is specified, shows usage help.

const std = @import("std");
const basic_text = @import("examples/basic_text.zig");
const atlas_demo = @import("examples/atlas_demo.zig");
const interactive = @import("examples/interactive.zig");
const gpu_text = @import("examples/gpu_text.zig");
const atlas_compare = @import("examples/atlas_compare.zig");
const coloring_demo = @import("examples/coloring_demo.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const example = args[1];

    if (std.mem.eql(u8, example, "basic")) {
        try basic_text.run(allocator);
    } else if (std.mem.eql(u8, example, "atlas")) {
        try atlas_demo.run(allocator);
    } else if (std.mem.eql(u8, example, "interactive")) {
        try interactive.run(allocator);
    } else if (std.mem.eql(u8, example, "gpu")) {
        try gpu_text.run(allocator);
    } else if (std.mem.eql(u8, example, "compare")) {
        try atlas_compare.run(allocator);
    } else if (std.mem.eql(u8, example, "coloring")) {
        try coloring_demo.run(allocator);
    } else if (std.mem.eql(u8, example, "--help") or std.mem.eql(u8, example, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown example: {s}\n\n", .{example});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\MSDF Examples - Multi-channel Signed Distance Field Text Rendering
        \\
        \\Usage: msdf-examples <example>
        \\
        \\Available examples:
        \\  basic       Basic text rendering at multiple scales
        \\              Shows MSDF text at various sizes with crisp edges.
        \\
        \\  gpu         GPU accelerated rendering
        \\              Same as basic but with different demo layout.
        \\
        \\  atlas       Atlas texture visualization
        \\              Displays the generated glyph atlas and shows
        \\              glyph metrics. Type characters to select glyphs.
        \\
        \\  interactive Interactive text demo
        \\              Type text, zoom with mouse wheel, drag to pan.
        \\              Demonstrates real-time MSDF rendering.
        \\
        \\  compare     Atlas comparison (zig-msdf vs msdfgen)
        \\              Compare rendering between zig-msdf and an external
        \\              msdfgen atlas. Provide atlas directory as argument.
        \\
        \\  coloring    Edge coloring features demo
        \\              Explore new coloring options: modes (.simple/.distance_based),
        \\              seeds, corner thresholds, and overlap correction.
        \\
        \\Controls (common):
        \\  ESC         Exit
        \\
        \\Build commands:
        \\  zig build run-gpu         Run GPU example (recommended)
        \\  zig build run-basic       Run basic example
        \\  zig build run-atlas       Run atlas demo
        \\  zig build run-interactive Run interactive demo
        \\  zig build run-compare     Run atlas comparison
        \\  zig build run-coloring    Run coloring features demo
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}
