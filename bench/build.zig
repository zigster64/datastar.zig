const std = @import("std");

const IoMode = enum { std, zio };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pick the IO backend. Default `std` matches the original bench (Io.Threaded);
    // `-Dio=zio` swaps in lalinsky/zio so handlers run on stackful coroutines.
    const io_mode = b.option(IoMode, "io", "IO backend: std (Io.Threaded, default) or zio (stackful coroutines)") orelse .std;

    const options = b.addOptions();
    options.addOption(IoMode, "io_mode", io_mode);

    const datastar_module = b.addModule("datastar", .{
        .root_source_file = b.path("../src/datastar.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "datastar", .module = datastar_module },
            },
        }),
    });
    exe.root_module.addOptions("options", options);

    if (io_mode == .zio) {
        const zio = b.dependency("zio", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zio", zio.module("zio"));
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
