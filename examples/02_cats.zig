const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const pubsub = datastar.pubsub;
const options = @import("options");

const PORT = 8082;

pub const std_options = std.Options{ .log_level = .debug };

// This example demonstrates a simple auction site that uses
// SSE and pub/sub to have realtime updates of bids on a Cat auction
pub fn main(init: std.process.Init) !void {
    // create the server
    var server = try datastar.HTTPServer.init(init, .{
        .port = PORT,
        .allocator = if (options.enable_fibers) std.heap.smp_allocator else null,
        .sse_concurrency = if (options.enable_fibers) .fibers else .threads,
        .watch = true,
        .fd_limit = .limited(2048),
    });
    defer server.deinit();

    // Create the global app instance and attach it to the server
    var app = try App.init(server.io, server.allocator);
    defer app.deinit();
    server.useContext(app);

    std.log.info("listening http://localhost:{d}", .{PORT});

    // create the routes
    {
        const r = server.router;
        r.get("/", index);
        r.get("/style.css", styleCss);
        r.sse("/cats", catsList);
        r.post("/bid/:id", postBid);
    }

    // run the server
    try server.run();
}

fn index(http: *HTTPRequest) !void {
    try http.html(@embedFile("02_index.html"));
}

fn styleCss(http: *HTTPRequest) !void {
    return http.css(@embedFile("style.css"));
}

fn catsList(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    var sse = try http.NewSSESync();
    defer sse.close();
    try pushCatList(app, &sse);

    var mq = try app.pubsub.connect();
    defer mq.deinit();

    try mq.subscribe(.cats);

    while (try mq.nextTimeout(.fromSeconds(30))) |event| {
        switch (event) {
            .msg => pushCatList(app, &sse) catch |err|
                return std.log.warn("Connection lost {t} {s} : {} - expect reconnect", .{
                    http.method,
                    http.path,
                    err,
                }),
            .timeout => sse.keepalive() catch |err|
                return std.log.warn("Connection lost {t} {s} : {} - expect reconnect", .{
                    http.method,
                    http.path,
                    err,
                }),
        }
    }
}

fn pushCatList(app: *App, sse: *datastar.SSE) !void {
    var w = sse.patchElementsWriter(.{});
    try w.print(
        \\<div id="cat-list" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 mt-4 h-full" data-signals="{{ bids: [{d},{d},{d},{d},{d},{d}] }}">
    , .{
        app.cats.items[0].bid,
        app.cats.items[1].bid,
        app.cats.items[2].bid,
        app.cats.items[3].bid,
        app.cats.items[4].bid,
        app.cats.items[5].bid,
    });

    for (app.cats.items) |cat| {
        try cat.render(w);
    }
    try w.writeAll(
        \\</div>
    );
    try sse.flush();
}

fn postBid(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    try app.lock();
    defer app.unlock();

    const id = http.params.getInt(usize, "id") orelse 0;

    if (id < 0 or id >= app.cats.items.len) {
        return error.InvalidID;
    }

    const signals = try http.readSignals(struct { bids: []usize });
    const new_bid = signals.bids[id];
    app.cats.items[id].bid = new_bid;

    // update any screens subscribed to "cats"
    try app.broadcast();

    // If you dont reply here, the connection will be left open
    // and the browser will be a response
    //
    // The router will detect this, and issue an automatic
    // response 200 ok
    //
    // If you uncomment this next line, we send a custom json
    // response to terminate the call, and the router wont intervene
    //
    // try http.json(.{ .bid = "ok", .id = id, .value = new_bid });
}

const Cat = struct {
    id: u8,
    name: []const u8,
    img: []const u8,
    bid: usize = 0,

    pub fn render(cat: Cat, w: anytype) !void {
        try w.print(
            \\<div class="card w-8/12 bg-slate-300 card-lg shadow-sm m-auto mt-4">
            \\  <div class="card-body" id="cat-{[id]}">
            \\    <h2 class="card-title">#{[id]} {[name]s}</h2>
            \\    <div class="avatar">
            \\      <div class="w-48 h-48 rounded-full">
            \\        <img src="{[img]s}">
            \\      </div>
            \\    </div>
            \\    <label class="input">$ 
            \\      <input type="number" placeholder="Bid" class="grow" data-bind:bids.{[id]} />
            \\    </label>
            \\    <div class="justify-end card-actions">
            \\      <button class="btn btn-primary" data-on:click="@post('/bid/{[id]}', {{filterSignals: {{include: '^bids$'}}}})">Place Bid</button>
            \\    </div>
            \\  </div>
            \\</div>
        , .{
            .id = cat.id,
            .name = cat.name,
            .img = cat.img,
        });
    }
};

const Cats = std.ArrayList(Cat);

// Schema for messages passed over pubsub
const MQSchema = union(enum) {
    cats: void,
};

const App = struct {
    io: Io,
    allocator: Allocator,
    cats: Cats,
    mutex: Io.Mutex,
    pubsub: pubsub.PubSub(MQSchema),

    pub fn init(io: Io, allocator: Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .io = io,
            .allocator = allocator,
            .mutex = .init,
            .cats = try createCats(allocator),
            // OK, for now pubsub over fibers is completely borked due to the way
            // timers are in transition - use Threaded IO for pubsub for now
            // .pubsub = pubsub.PubSub(MQSchema).init(pubsub_io, allocator),
            .pubsub = pubsub.PubSub(MQSchema).init(io, allocator),
        };
        return app;
    }

    pub fn lock(app: *App) !void {
        try app.mutex.lock(app.io);
    }

    pub fn unlock(app: *App) void {
        app.mutex.unlock(app.io);
    }

    pub fn deinit(app: *App) void {
        app.cats.deinit(app.allocator);
        app.allocator.destroy(app);
    }

    pub fn broadcast(app: *App) !void {
        try app.pubsub.publish(.{ .cats = {} }, .all);
    }
};

fn createCats(allocator: Allocator) !Cats {
    var cats: Cats = .empty;
    errdefer cats.deinit(allocator);
    try cats.append(allocator, .{
        .id = 0,
        .name = "Harry",
        .img = "https://images.unsplash.com/photo-1514888286974-6c03e2ca1dba?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8Mnx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(allocator, .{
        .id = 1,
        .name = "Meghan",
        .img = "https://images.unsplash.com/photo-1574144611937-0df059b5ef3e?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8MTR8fGNhdHxlbnwwfHwwfHx8MA%3D%3D",
    });
    try cats.append(allocator, .{
        .id = 2,
        .name = "Prince",
        .img = "https://images.unsplash.com/photo-1574158622682-e40e69881006?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8MjB8fGNhdHxlbnwwfHwwfHx8MA%3D%3D",
    });
    try cats.append(allocator, .{
        .id = 3,
        .name = "Fluffy",
        .img = "https://plus.unsplash.com/premium_photo-1664299749481-ac8dc8b49754?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8OXx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(allocator, .{
        .id = 4,
        .name = "Princessa",
        .img = "https://images.unsplash.com/photo-1472491235688-bdc81a63246e?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8Nnx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(allocator, .{
        .id = 5,
        .name = "Tiger",
        .img = "https://plus.unsplash.com/premium_photo-1673967770669-91b5c2f2d0ce?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8NXx8a2l0dGVufGVufDB8fDB8fHww",
    });
    return cats;
}
