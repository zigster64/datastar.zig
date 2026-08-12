const std = @import("std");
const datastar = @import("datastar");
const options = @import("options");
const HTTPRequest = datastar.HTTPRequest;
const Io = std.Io;

// Selected at build time via `-Dio=zio`. The default `std` mode keeps the
// stdlib Io.Threaded that std.process.Init hands us; the zio mode spins up a
// zio.Runtime and feeds its std.Io into the server so handler IO suspends on
// stackful coroutines instead of OS threads.
const use_zio = options.io_mode == .zio;
const zio = if (use_zio) @import("zio") else void;

pub fn main(init: std.process.Init) !void {
    const rt = if (use_zio) try zio.Runtime.init(init.gpa, .{ .executors = .auto }) else {};
    defer if (use_zio) rt.deinit();
    const io: Io = if (use_zio) rt.io() else init.io;

    if (use_zio) {
        const n = rt.options.executors.resolve();
        std.debug.print("IO backend: zio (stackful coroutines, {d} executor threads)\n", .{n});
    } else {
        std.debug.print("IO backend: std Io.Threaded\n", .{});
    }

    var server = try datastar.HTTPServer.init(init, .{
        .port = 8090,
        .io = io,
        .allocator = std.heap.smp_allocator,
        .log = .{
            .level = .none,
            .format = .terminal,
            .theme = .monochrom,
        },
        .watch = true,
        .fd_limit = .max,
    });
    defer server.deinit();

    {
        const r = server.router;
        r.get("/", handler);
        r.get("/log", handlerLogged);
        r.get("/sse", sseHandler);
    }

    std.debug.print("Zig Datastar 0.16-dev SSE Server running at http://localhost:8090\n", .{});
    try server.run();
}

pub fn handler(http: *HTTPRequest) !void {
    return http.html(@embedFile("index.html"));
}

pub fn handlerLogged(http: *HTTPRequest) !void {
    var t1 = std.Io.Timestamp.now(http.io, std.Io.Clock.real);
    defer {
        std.debug.print("Zig index handler took {} microseconds\n", .{@divTrunc(t1.untilNow(http.io, std.Io.Clock.real).toNanoseconds(), std.time.ns_per_ms)});
    }
    return http.html(@embedFile("index.html"));
}

pub fn sseHandler(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements(@embedFile("index.html"), .{});
}
