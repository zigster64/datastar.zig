const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const version = builtin.zig_version;
    std.debug.print("Building with Zig version {f}\n", .{version});

    if (version.major == 0 and version.minor == 15) {
        build_015(b);
    } else if (version.major == 0 and version.minor == 16) {
        build_016(b);
    } else {
        std.debug.print("Unsupported Zig version - use either 0.15.x or 0.16.x\n", .{});
    }
}

fn build_015(b: *std.Build) void {
    if (comptime builtin.zig_version.minor != 15) return;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_opts = .{
        .target = target,
        .optimize = optimize,
    };

    const datastar_httpz_module = b.addModule("datastar", .{
        .root_source_file = b.path("src/datastar.zig"),
        .target = target,
    });

    const httpz_module = b.lazyDependency("httpz", dep_opts) orelse return;
    const tokamak_module = b.lazyDependency("tokamak", dep_opts) orelse return;
    const logz_module = b.lazyDependency("logz", dep_opts) orelse return;

    // datastar_httpz_module.addImport("httpz", httpz_module.module("httpz"));
    if (comptime builtin.zig_version.minor == 15) {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/datastar.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        const run_test = b.addRunArtifact(tests);
        run_test.has_side_effects = true;

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }

    const httpz_examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "tests/validation.zig", .name = "validation-test" },
        .{ .file = "examples/01_basic.zig", .name = "example_1" },
        .{ .file = "examples/02_petshop.zig", .name = "example_2" },
        .{ .file = "examples/022_petshop.zig", .name = "example_22" },
        .{ .file = "examples/05_garden.zig", .name = "example_5" },
        .{ .file = "examples/tokamak_basic.zig", .name = "tokamak_basic" },
    };

    for (httpz_examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("datastar", datastar_httpz_module);

        // add some 3rd party deps to get the app working
        exe.root_module.addImport("httpz", httpz_module.module("httpz"));
        exe.root_module.addImport("tokamak", tokamak_module.module("tokamak"));
        exe.root_module.addImport("logz", logz_module.module("logz"));

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(ex.name, ex.file);
        run_step.dependOn(&run_cmd.step);
    }
}

fn build_016(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const datastar_httpz_module = b.addModule("datastar", .{
        .root_source_file = b.path("src/datastar16.zig"),
        .target = target,
        .optimize = optimize,
    });

    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "examples/16_stdlib.zig", .name = "stdlib0.16" },
    };

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("datastar", datastar_httpz_module);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(ex.name, ex.file);
        run_step.dependOn(&run_cmd.step);
    }
}
