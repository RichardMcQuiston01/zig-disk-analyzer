const std = @import("std");
const builtin = @import("builtin");

/// Where to find a prebuilt raylib: its library and header directories.
const RaylibDirs = struct {
    lib: std.Build.LazyPath,
    include: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    // On a Windows host, default to the GNU ABI so the vendored MinGW-w64
    // raylib links without extra flags. Elsewhere, use the normal native target.
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .windows) .{ .abi = .gnu } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});

    // -Draylib_path=<dir> overrides; Windows otherwise uses the vendored copy
    // in vendor/raylib; Linux/macOS otherwise use the system raylib (pkg-config).
    const raylib_path = b.option(
        []const u8,
        "raylib_path",
        "Path to a prebuilt raylib (folder containing lib/ and include/)",
    );
    const raylib_dirs: ?RaylibDirs = if (raylib_path) |p| .{
        .lib = .{ .cwd_relative = b.pathJoin(&.{ p, "lib" }) },
        .include = .{ .cwd_relative = b.pathJoin(&.{ p, "include" }) },
    } else if (target.result.os.tag == .windows) .{
        .lib = b.path("vendor/raylib/lib"),
        .include = b.path("vendor/raylib/include"),
    } else null;

    const exe = b.addExecutable(.{
        .name = "diskviz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    linkRaylib(exe.root_module, target, raylib_dirs);

    // Release builds on Windows are pure GUI apps (no console window behind
    // them). Debug keeps the console so panics and logs stay visible.
    // Compared case-insensitively: 0.16 spells the tag `.Debug`, 0.17 `.debug`.
    const is_debug = std.ascii.eqlIgnoreCase(@tagName(optimize), "debug");
    if (target.result.os.tag == .windows and !is_debug) {
        exe.subsystem = .windows;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the analyzer");
    run_step.dependOn(&run_cmd.step);

    // Unit tests cover the pure logic and the threaded scanner (no GUI needed).
    const test_step = b.step("test", "Run unit tests");
    inline for (.{
        "src/format.zig",
        "src/treemap.zig",
        "src/model.zig",
        "src/scanner.zig",
        "src/settings.zig",
        "src/typography.zig",
        "src/shell.zig",
    }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn linkRaylib(
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    raylib_dirs: ?RaylibDirs,
) void {
    if (raylib_dirs) |dirs| {
        mod.addLibraryPath(dirs.lib);
        mod.addIncludePath(dirs.include);
        mod.linkSystemLibrary("raylib", .{ .use_pkg_config = .no, .preferred_link_mode = .static });
    } else {
        mod.linkSystemLibrary("raylib", .{});
    }

    switch (target.result.os.tag) {
        .windows => {
            inline for (.{ "gdi32", "winmm", "opengl32", "user32", "shell32", "kernel32" }) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        },
        .macos => {
            inline for (.{ "CoreVideo", "IOKit", "Cocoa", "GLUT", "OpenGL" }) |fw| {
                mod.linkFramework(fw, .{});
            }
        },
        else => {
            inline for (.{ "GL", "m", "pthread", "dl", "rt", "X11" }) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        },
    }
}
