const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check = b.step("check", "Check if everything compiles (for ZLS)");
    //
    // Add CLI flag for using Kqueue fibers (experimental)
    const enable_fibers = b.option(bool, "enable-kqueue-fibers", "Enable KQueue backed Fibers") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "enable_fibers", enable_fibers);

    const pubsub = b.dependency("pubsub", .{
        .target = target,
        .optimize = optimize,
    });

    const datastar_module = b.addModule("datastar", .{
        .root_source_file = b.path("src/datastar.zig"),
        .target = target,
        .optimize = optimize,
    });
    datastar_module.addImport("pubsub", pubsub.module("pubsub"));

    // Add test step for server.zig
    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    server_tests.root_module.addImport("pubsub", pubsub.module("pubsub"));
    check.dependOn(&server_tests.step);

    const run_server_tests = b.addRunArtifact(server_tests);

    // Add test step for datastar.zig
    const datastar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/datastar.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    datastar_tests.root_module.addImport("pubsub", pubsub.module("pubsub"));

    const run_datastar_tests = b.addRunArtifact(datastar_tests);

    // Create a "test" step that runs all tests
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_datastar_tests.step);

    // Individual test steps
    const test_server_step = b.step("test-server", "Run server tests");
    test_server_step.dependOn(&run_server_tests.step);

    const test_datastar_step = b.step("test-datastar", "Run datastar tests");
    test_datastar_step.dependOn(&run_datastar_tests.step);

    // Examples
    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "tests/validation.zig", .name = "validation-test" },
        .{ .file = "examples/01_basic.zig", .name = "example_1" },
        .{ .file = "examples/02_cats.zig", .name = "example_2" },
        .{ .file = "examples/03_wildcats.zig", .name = "example_3" },
        .{ .file = "examples/05_garden.zig", .name = "example_5" },
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
        exe.root_module.addImport("datastar", datastar_module);
        exe.root_module.addOptions("options", options);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(ex.name, ex.file);
        run_step.dependOn(&run_cmd.step);

        // Now add a check step just for this example that we add to the global check
        const exe_check = b.addExecutable(.{
            .name = ex.name, // Name doesn't strictly matter here
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe_check.root_module.addImport("datastar", datastar_module);
        exe_check.root_module.addOptions("options", options);
        check.dependOn(&exe_check.step); // <--- Add to check
    }
}
