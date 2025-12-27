const std = @import("std");
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const Io = std.Io;

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    // Evented isnt really working yet, so stick with Threaded IO for now
    // Once Evented is functional, its just a 1 line change here to swap
    // from heavy threads to coroutines
    var threaded: Io.Threaded = .init(gpa);
    defer threaded.deinit();
    threaded.setAsyncLimit(std.Io.Limit.limited64(10));
    const io = threaded.io();

    var server = try datastar.Server.init(io, gpa, "0.0.0.0", 8090);
    defer server.deinit();

    const r = server.router;
    try r.get("/", handler);
    try r.get("/log", handlerLogged);
    try r.get("/sse", sseHandler);

    std.debug.print("Zig Datastar 0.16-dev SSE Server running at http://localhost:8090\n", .{});
    try server.run();
}

pub fn handler(http: HTTPRequest) !void {
    return http.html(@embedFile("index.html"));
}

pub fn handlerLogged(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("Zig index handler took {} microseconds\n", .{t1.read() / std.time.ns_per_ms});
    }
    return http.html(@embedFile("index.html"));
}

pub fn sseHandler(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("Zig SSE handler took {} microseconds\n", .{t1.read() / std.time.ns_per_ms});
    }
    var sse = try datastar.NewSSE(http);
    defer sse.close();

    try sse.patchElements(@embedFile("index.html"), .{});
}
