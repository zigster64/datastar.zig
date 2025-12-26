const std = @import("std");
const httpz = @import("httpz");
const logz = @import("logz");
const datastar = @import("datastar");
const App = @import("02_cats.zig").App;

const Allocator = std.mem.Allocator;

const PORT = 8082;

// This example demonstrates a simple auction site that uses
// SSE and pub/sub to have realtime updates of bids on a Cat auction
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    var server = try httpz.Server(*App).init(allocator, .{
        .port = PORT,
        .address = "0.0.0.0",
    }, app);
    defer {
        // clean shutdown
        server.stop();
        server.deinit();
    }

    // initialize a logging pool
    try logz.setup(allocator, .{
        .level = .Info,
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = .stdout,
        .encoding = .logfmt,
    });
    defer logz.deinit();

    var router = try server.router(.{});

    router.get("/", index, .{});
    router.get("/cats", catsList, .{});
    router.post("/bid/:id", postBid, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    std.debug.print("... or any other IP address pointing to this machine\n", .{});
    try server.listen();
}

fn index(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "index").int("elapsed (μs)", t2 - t1).log();
    }

    res.content_type = .HTML;
    res.body = @embedFile("02_index.html");
}

fn catsList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    app.mutex.lock();
    defer {
        app.mutex.unlock();
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "catsList").int("elapsed (μs)", t2 - t1).log();
    }

    const sse = try datastar.NewSSESync(req, res);
    try app.subscribe("cats", sse.stream, App.publishCatList);
}

fn postBid(app: *App, req: *httpz.Request, _: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    app.mutex.lock();
    defer {
        app.mutex.unlock();
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "postBid").int("elapsed (μs)", t2 - t1).log();
    }

    const id_param = req.param("id").?;
    const id = try std.fmt.parseInt(usize, id_param, 10);

    if (id < 0 or id >= app.cats.items.len) {
        return error.InvalidID;
    }

    const Bids = struct {
        bids: []usize,
    };
    const signals = try datastar.readSignals(Bids, req);
    // std.debug.print("bids {any}\n", .{signals.bids});
    const new_bid = signals.bids[id];
    // std.debug.print("new bid {}\n", .{new_bid});
    app.cats.items[id].bid = new_bid;

    // update any screens subscribed to "cats"
    try app.publish("cats");
}
