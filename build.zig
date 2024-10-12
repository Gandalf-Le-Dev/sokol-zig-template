const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const sokol = @import("sokol");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_zigbeam = b.dependency("zigbeam", .{
        .target = target,
        .optimize = optimize,
    });

    // map where the key is the module name and the value *Dependency
    var dependencies = std.StringHashMap(*Build.Dependency).init(b.allocator);
    try dependencies.put("zigbeam", dep_zigbeam);

    // shaders build step
    try buildShaders(b);

    // special case handling for native vs web build
    if (target.result.isWasm()) {
        try buildWeb(b, target, optimize, dep_sokol, dependencies);
    } else {
        try buildNative(b, target, optimize, dep_sokol, dependencies);
    }
}

// this is the regular build for all native platforms, nothing surprising here
fn buildNative(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, dep_sokol: *Build.Dependency, dependencies: std.StringHashMap(*Build.Dependency)) !void {
    const exe = b.addExecutable(.{
        .name = "sokol-zig-template",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    exe.root_module.addImport("sokol", dep_sokol.module("sokol"));

    var iter = dependencies.keyIterator();
    while (iter.next()) |key| {
        exe.root_module.addImport(key.*, dependencies.get(key.*).?.module(key.*));
    }

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run pacman").dependOn(&run.step);
}

// for web builds, the Zig code needs to be built into a library and linked with the Emscripten linker
fn buildWeb(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, dep_sokol: *Build.Dependency, dependencies: std.StringHashMap(*Build.Dependency)) !void {
    const lib = b.addStaticLibrary(.{
        .name = "index",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    lib.root_module.addImport("sokol", dep_sokol.module("sokol"));

    var iter = dependencies.keyIterator();
    while (iter.next()) |key| {
        lib.root_module.addImport(key.*, dependencies.get(key.*).?.module(key.*));
    }

    // create a build step which invokes the Emscripten linker
    const emsdk = dep_sokol.builder.dependency("emsdk", .{});
    _ = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = b.path("web/shell.html"),
    });

    // ...and a special run step to start the web build output via 'emrun'
    // const run = sokol.emRunStep(b, .{ .name = "index", .emsdk = emsdk });
    // run.step.dependOn(&link_step.step);
    // const browser = "/Applications/Zen Browser.app/Contents/MacOS/zen";
    // const browser = "/Applications/Arc.app/Contents/MacOS/Arc";
    // run.addArgs(&[_][]const u8{
    //     "--browser",
    //     browser,
    // });
    // b.step("run", "Run sokol-zig-template").dependOn(&run.step);
}

fn buildShaders(b: *Build) !void {
    const shadersStep = b.step("shaders", "Compile shaders using sokol-shdc");

    var dir = try std.fs.cwd().openDir("src/shaders", .{ .iterate = true });
    defer dir.close();

    var dirIterator = dir.iterate();

    while (try dirIterator.next()) |file| {
        if (file.kind == .file) {
            if (std.mem.endsWith(u8, file.name, ".glsl")) {
                const shader_dir = b.fmt("src/shaders", .{});
                const input_path = b.fmt("{s}/{s}", .{ shader_dir, file.name });
                const output_path = b.fmt("{s}/{s}.zig", .{ shader_dir, file.name });

                const shader = b.addSystemCommand(&[_][]const u8{
                    "sokol-shdc",
                    "--input",
                    input_path,
                    "--output",
                    output_path,
                    "--slang",
                    "glsl430:hlsl5:metal_macos:glsl300es:wgsl",
                    "--format",
                    "sokol_zig",
                });

                shadersStep.dependOn(&shader.step);
            }
        }
    }
}
