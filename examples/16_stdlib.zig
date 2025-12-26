const std = @import("std");
const builtin = @import("builtin");
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const rebooter = @import("rebooter16.zig");
const Io = std.Io;

const PORT = 8080;
const MAX_THREADS = 2000;

var update_count: usize = 1;
var update_mutex: std.Thread.Mutex = .{};

var prng = std.Random.DefaultPrng.init(0);

fn getCountAndIncrement() usize {
    update_mutex.lock();
    defer {
        update_count += 1;
        update_mutex.unlock();
    }
    return update_count;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Evented isnt really working yet, so stick with Threaded IO for now
    // Once Evented is functional, its just a 1 line change here to swap
    // from heavy threads to coroutines
    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    threaded.setAsyncLimit(std.Io.Limit.limited64(MAX_THREADS));
    const io = threaded.io();

    std.debug.print(
        "Created Threaded IO with limit of {} threads\n",
        .{threaded.async_limit.toInt() orelse 0},
    );

    const address = try Io.net.IpAddress.parseIp4("0.0.0.0", PORT);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try rebooter.start(io, allocator);

    std.debug.print("Server listening on http://localhost:8080\n", .{});

    while (true) {
        const conn = try server.accept(io);
        // this should spawn a thread, because line 12 above
        // if io is Evented, then io.concurrent should run this as a coroutine
        var future = try io.concurrent(handleConnection, .{ io, allocator, conn });
        std.debug.print("Handled connection - new concurrent func\n", .{});
        _ = future.await(io);
        std.debug.print("Connection ended\n", .{});
    }
}

fn handleConnection(io: Io, gpa: std.mem.Allocator, conn: Io.net.Stream) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    defer {
        conn.close(io);
        arena.deinit();
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &write_buffer);

    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            return;
        };
        router(io, &request, alloc) catch |err| {
            std.debug.print("Routing error: {}\n", .{err});
        };
    }
}

fn router(io: Io, req: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    const path = req.head.target;
    const http = HTTPRequest{
        .io = io,
        .req = req,
        .arena = arena,
    };
    if (std.mem.eql(u8, path, "/")) {
        return index(http);
    } else if (match(path, "/text-html")) {
        return textHtml(http);
    } else if (match(path, "/patch")) {
        return patch(http);
    } else if (match(path, "/code")) {
        return code(http);
    } else {
        return req.respond("Not Found", .{ .status = .not_found });
    }
}

fn match(path: []const u8, pattern: []const u8) bool {
    return (std.mem.eql(u8, path[0..pattern.len], pattern));
}

fn index(http: HTTPRequest) !void {
    const html = @embedFile("01_index.html");
    return try http.req.respond(html, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

fn textHtml(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("TextHTML elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});
    }

    return try http.req.respond(try std.fmt.allocPrint(http.arena,
        \\<p id="text-html">This is update number {d}</p>
    , .{getCountAndIncrement()}), .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

fn patch(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("patchElements elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});
    }

    var buf: [1024]u8 = undefined;
    var sse = try datastar.NewSSE(http, &buf);
    defer sse.close();

    try sse.patchElementsFmt(
        \\<p id="mf-patch">This is update number {d}</p>
    ,
        .{getCountAndIncrement()},
        .{},
    );
}

const snippets = [_][]const u8{
    @embedFile("snippets/code1.zig"),
    @embedFile("snippets/code2.zig"),
    @embedFile("snippets/code3.zig"),
    @embedFile("snippets/code4.zig"),
    @embedFile("snippets/code5.zig"),
    @embedFile("snippets/code6.zig"),
    @embedFile("snippets/code7.zig"),
    @embedFile("snippets/code8.zig"),
    @embedFile("snippets/code9.zig"),
    @embedFile("snippets/code10.zig"),
};

fn code(http: HTTPRequest) !void {
    const path_only = std.mem.sliceTo(http.req.head.target, '?');
    var path_iter = std.mem.tokenizeScalar(u8, path_only, '/');
    _ = path_iter.next();
    const snip = path_iter.next() orelse {
        return http.req.respond("Missing ID", .{ .status = .bad_request });
    };
    const snip_id = try std.fmt.parseInt(u8, snip, 10);

    if (snip_id < 1 or snip_id > snippets.len) {
        std.debug.print("Invalid code snippet {}, range is 1-{}\n", .{ snip_id, snippets.len });
        return error.InvalidCodeSnippet;
    }

    const data = snippets[snip_id - 1];

    var buf: [1024]u8 = undefined;
    var sse = try datastar.NewSSE(http, &buf);
    defer sse.close();

    const selector = try std.fmt.allocPrint(http.arena, "#code-{s}", .{snip});
    var w = sse.patchElementsWriter(.{
        .selector = selector,
        .mode = .append,
    });

    try w.writeAll("<pre><code>");

    var it = std.mem.splitAny(u8, data, "\n");
    while (it.next()) |line| {
        try w.writeAll("&nbsp;&nbsp;"); // pad each line to the right
        for (line) |c| {
            switch (c) {
                '<' => try w.writeAll("&lt;"),
                '>' => try w.writeAll("&gt;"),
                ' ' => try w.writeAll("&nbsp;"),
                else => try w.writeByte(c),
            }
        }
        try w.writeAll("\n");
    }

    try w.writeAll("</code></pre>\n");

    // return try req.respond(sse.body(), .{
    //     .extra_headers = &.{
    //         .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
    //         .{ .name = "cache-control", .value = "no-cache" },
    //     },
    //     .wait_for_body = true,
    // });
}
