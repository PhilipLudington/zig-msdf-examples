//! Build configuration for zig-msdf-examples.
//!
//! ## Build Commands
//! - `zig build` - Build all examples
//! - `zig build run-basic` - Run basic text example
//! - `zig build run-atlas` - Run atlas demo example
//! - `zig build run-interactive` - Run interactive example
//! - `zig build test` - Run unit tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const msdf_dep = b.dependency("zig-msdf", .{
        .target = target,
        .optimize = optimize,
    });

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    // Renderer module
    const renderer_mod = b.addModule("renderer", .{
        .root_source_file = b.path("src/renderer/gpu.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shaders module
    const shaders_mod = b.addModule("shaders", .{
        .root_source_file = b.path("src/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Assets module (embeds fonts and resources)
    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("src/assets.zig"),
        .target = target,
        .optimize = optimize,
    });

    // MSDF GPU renderer module
    const msdf_gpu_mod = b.addModule("msdf_gpu", .{
        .root_source_file = b.path("src/msdf_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "msdf", .module = msdf_dep.module("msdf") },
            .{ .name = "assets", .module = assets_mod },
        },
    });

    // Text renderer module
    const text_renderer_mod = b.addModule("text_renderer", .{
        .root_source_file = b.path("src/renderer/text_renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "shaders", .module = shaders_mod },
            .{ .name = "msdf", .module = msdf_dep.module("msdf") },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "msdf-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msdf", .module = msdf_dep.module("msdf") },
                .{ .name = "renderer", .module = renderer_mod },
                .{ .name = "text_renderer", .module = text_renderer_mod },
                .{ .name = "shaders", .module = shaders_mod },
                .{ .name = "assets", .module = assets_mod },
                .{ .name = "msdf_gpu", .module = msdf_gpu_mod },
            },
        }),
    });

    // Link SDL3
    exe.linkLibrary(sdl_dep.artifact("SDL3"));

    b.installArtifact(exe);

    // Run steps for each example
    const run_gpu = b.addRunArtifact(exe);
    run_gpu.addArg("gpu");
    run_gpu.step.dependOn(b.getInstallStep());
    const gpu_step = b.step("run-gpu", "Run GPU accelerated text example (recommended)");
    gpu_step.dependOn(&run_gpu.step);

    const run_basic = b.addRunArtifact(exe);
    run_basic.addArg("basic");
    run_basic.step.dependOn(b.getInstallStep());
    const basic_step = b.step("run-basic", "Run basic text example");
    basic_step.dependOn(&run_basic.step);

    const run_atlas = b.addRunArtifact(exe);
    run_atlas.addArg("atlas");
    run_atlas.step.dependOn(b.getInstallStep());
    const atlas_step = b.step("run-atlas", "Run atlas demo example");
    atlas_step.dependOn(&run_atlas.step);

    const run_interactive = b.addRunArtifact(exe);
    run_interactive.addArg("interactive");
    run_interactive.step.dependOn(b.getInstallStep());
    const interactive_step = b.step("run-interactive", "Run interactive example");
    interactive_step.dependOn(&run_interactive.step);

    const run_compare = b.addRunArtifact(exe);
    run_compare.addArg("compare");
    run_compare.addArg("msdfgen-atlas");
    run_compare.setCwd(b.path("."));
    run_compare.step.dependOn(b.getInstallStep());
    const compare_step = b.step("run-compare", "Run atlas comparison example (zig-msdf vs msdfgen)");
    compare_step.dependOn(&run_compare.step);

    const run_coloring = b.addRunArtifact(exe);
    run_coloring.addArg("coloring");
    run_coloring.step.dependOn(b.getInstallStep());
    const coloring_step = b.step("run-coloring", "Run edge coloring features demo");
    coloring_step.dependOn(&run_coloring.step);

    // Tests
    const renderer_tests = b.addTest(.{
        .root_module = renderer_mod,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(renderer_tests).step);
}
