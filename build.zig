const std = @import("std");
const builtin = @import("builtin");

const IoMode = enum { std, zio };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check = b.step("check", "Check if everything compiles (for ZLS)");

    // Select IO backend for the example programs. Default `std` uses the stdlib
    // Io.Threaded supplied by std.process.Init. `-Dio=zio` swaps in lalinsky/zio
    // so handlers run on stackful coroutines instead of OS threads.
    const io_mode = b.option(IoMode, "io", "Examples IO backend: std (Io.Threaded, default) or zio (stackful coroutines)") orelse .std;

    const options = b.addOptions();
    options.addOption(IoMode, "io_mode", io_mode);

    const pubsub = b.dependency("pubsub", .{
        .target = target,
        .optimize = optimize,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const zio = b.dependency("zio", .{
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
        if (io_mode == .zio) {
            exe.root_module.addImport("zio", zio.module("zio"));
        }
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
        if (io_mode == .zio) {
            exe_check.root_module.addImport("zio", zio.module("zio"));
        }
        check.dependOn(&exe_check.step); // <--- Add to check
    }

    // Standalone example showing the framework-agnostic SDK functions wired
    // into karlseguin's http.zig. Built only on demand via `zig build http.zig`.
    const httpz_example = b.addExecutable(.{
        .name = "example_1_httpz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/01_basic_httpz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    httpz_example.root_module.addImport("datastar", datastar_module);
    httpz_example.root_module.addImport("httpz", httpz.module("httpz"));

    const httpz_step = b.step("http.zig", "Build the http.zig example to zig-out/bin/example_1_httpz");
    httpz_step.dependOn(&b.addInstallArtifact(httpz_example, .{}).step);

    // Also include the httpz example in the global `check` step.
    const httpz_check = b.addExecutable(.{
        .name = "example_1_httpz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/01_basic_httpz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    httpz_check.root_module.addImport("datastar", datastar_module);
    httpz_check.root_module.addImport("httpz", httpz.module("httpz"));
    check.dependOn(&httpz_check.step);

    // Same idea for lalinsky/dusty. Built only on demand via `zig build dusty`.
    const dusty_example = b.addExecutable(.{
        .name = "example_1_dusty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/01_basic_dusty.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dusty_example.root_module.addImport("datastar", datastar_module);
    dusty_example.root_module.addImport("dusty", dusty.module("dusty"));

    const dusty_step = b.step("dusty", "Build the dusty example to zig-out/bin/example_1_dusty");
    dusty_step.dependOn(&b.addInstallArtifact(dusty_example, .{}).step);

    const dusty_check = b.addExecutable(.{
        .name = "example_1_dusty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/01_basic_dusty.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dusty_check.root_module.addImport("datastar", datastar_module);
    dusty_check.root_module.addImport("dusty", dusty.module("dusty"));
    check.dependOn(&dusty_check.step);

    // Peak-RSS / allocation analysis for the streaming patchElements change.
    // ReleaseFast so DebugAllocator metadata does not dominate the RSS signal.
    const peak_rss = b.addExecutable(.{
        .name = "peak-rss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/peak_rss.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    peak_rss.root_module.addImport("datastar", datastar_module);
    const peak_rss_step = b.step("peak-rss", "Measure patchElements peak RSS / allocation (ladder vs alloc vs stream)");
    const run_peak_rss = b.addRunArtifact(peak_rss);
    peak_rss_step.dependOn(&run_peak_rss.step);
}
