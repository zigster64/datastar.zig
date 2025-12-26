const std = @import("std");
const httpz = @import("httpz");
const logz = @import("logz");
const datastar = @import("datastar");
const Allocator = std.mem.Allocator;

const Cat = struct {
    id: u8,
    name: []const u8,
    img: []const u8,
    bid: usize = 0,
    ts: i128 = 0,

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

pub const Cats = std.ArrayList(Cat);

pub const SortType = enum {
    id,
    low,
    high,
    recent,

    pub fn fromString(s: []const u8) SortType {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "recent")) return .recent;
        return .id;
    }
};

pub const SessionPrefs = struct {
    sort: SortType = .id,
};

pub const App = struct {
    gpa: Allocator,
    cats: Cats,
    mutex: std.Thread.Mutex,
    next_session_id: usize = 1,
    subscribers: datastar.Subscribers(*App),
    sessions: std.StringHashMap(SessionPrefs),
    last_sort: SortType = .id,

    pub fn init(gpa: Allocator) !*App {
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .mutex = .{},
            .cats = try createCats(gpa),
            .sessions = std.StringHashMap(SessionPrefs).init(gpa),
            .subscribers = try datastar.Subscribers(*App).init(gpa, app),
        };
        return app;
    }

    pub fn newSessionID(app: *App) !usize {
        app.mutex.lock();
        defer app.mutex.unlock();
        const s = app.next_session_id;
        app.next_session_id += 1;

        const session_id = try std.fmt.allocPrint(app.gpa, "{d}", .{s});
        try app.sessions.put(session_id, .{});

        std.debug.print("App Sessions after adding a new session ID:\n", .{});
        var it = app.sessions.keyIterator();
        while (it.next()) |k| {
            std.debug.print("- {s}\n", .{k.*});
        }

        return s;
    }

    pub fn ensureSession(app: *App, session_id: []const u8) !void {
        app.mutex.lock();
        defer app.mutex.unlock();

        if (app.sessions.get(session_id) == null) {
            try app.sessions.put(try app.gpa.dupe(u8, session_id), .{});
            std.debug.print("Had to add session {s} to my sessions list, because the client says its there, but I dont know about it\n", .{session_id});
        }
    }

    pub fn deinit(app: *App) void {
        app.streams.deinit();
        app.cats.deinit();
        app.sessions.deinit();
        app.gpa.destroy(app);
    }

    fn catSortID(_: void, cat1: Cat, cat2: Cat) bool {
        return cat1.id < cat2.id;
    }

    fn catSortLow(_: void, cat1: Cat, cat2: Cat) bool {
        if (cat1.bid == cat2.bid) return cat1.id < cat2.id;
        return cat1.bid < cat2.bid;
    }

    fn catSortHigh(_: void, cat1: Cat, cat2: Cat) bool {
        if (cat1.bid == cat2.bid) return cat1.id < cat2.id;
        return cat1.bid > cat2.bid;
    }

    fn catSortRecent(_: void, cat1: Cat, cat2: Cat) bool {
        if (cat1.ts == cat2.ts) return cat1.id < cat2.id;
        return cat1.ts > cat2.ts;
    }

    pub fn sortCats(app: *App, sort: SortType) void {
        if (app.last_sort == sort) return;

        switch (sort) {
            .id => std.sort.block(Cat, app.cats.items, {}, catSortID),
            .low => std.sort.block(Cat, app.cats.items, {}, catSortLow),
            .high => std.sort.block(Cat, app.cats.items, {}, catSortHigh),
            .recent => std.sort.block(Cat, app.cats.items, {}, catSortRecent),
        }
        app.last_sort = sort;
    }

    // convenience function
    pub fn subscribe(app: *App, topic: []const u8, stream: std.net.Stream, callback: anytype) !void {
        try app.subscribers.subscribe(topic, stream, callback);
    }

    pub fn subscribeSession(app: *App, topic: []const u8, stream: std.net.Stream, callback: anytype, session: ?[]const u8) !void {
        try app.subscribers.subscribeSession(topic, stream, callback, session);
    }

    // convenience function
    pub fn publish(app: *App, topic: []const u8) !void {
        try app.subscribers.publish(topic);
    }

    pub fn publishSession(app: *App, topic: []const u8, session: []const u8) !void {
        try app.subscribers.publishSession(topic, session);
    }

    pub fn publishCatList(app: *App, stream: std.net.Stream, session: ?[]const u8) !void {
        const t1 = std.time.microTimestamp();
        defer {
            const t2 = std.time.microTimestamp();
            logz.info().string("event", "publishCatList").int("stream", stream.handle).string("session", session orelse "null").int("elapsed (μs)", t2 - t1).log();
        }

        // TODO - this is uneccessarily ugly, but its still quick, so nobody is going to care
        // sort by id first to get all the bid signals correct
        app.sortCats(.id);
        const bids = [6]usize{
            app.cats.items[0].bid,
            app.cats.items[1].bid,
            app.cats.items[2].bid,
            app.cats.items[3].bid,
            app.cats.items[4].bid,
            app.cats.items[5].bid,
        };

        if (session) |s| {
            // then re-sort them if its different to id order to get the cards right
            if (app.sessions.get(s)) |session_prefs| {
                app.sortCats(session_prefs.sort);
            }
        }

        var sse = datastar.NewSSEFromStream(stream, app.gpa);
        defer sse.deinit();

        var w = sse.patchElementsWriter(.{ .view_transition = true });
        try w.print(
            \\<div id="cat-list" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 mt-4 h-full" data-signals="{{ bids: [{d},{d},{d},{d},{d},{d}] }}">
        , .{
            bids[0],
            bids[1],
            bids[2],
            bids[3],
            bids[4],
            bids[5],
        });

        std.debug.print("start line of cats list is\n{s}\n", .{w.buffered()});

        for (app.cats.items) |cat| {
            try cat.render(w);
        }
        try w.writeAll(
            \\</div>
        );
    }

    pub fn publishPrefs(app: *App, stream: std.net.Stream, session: ?[]const u8) !void {
        const t1 = std.time.microTimestamp();
        defer {
            const t2 = std.time.microTimestamp();
            logz.info().string("event", "publishPrefs").int("stream", stream.handle).string("session", session orelse "null").int("elapsed (μs)", t2 - t1).log();
        }

        // just get the session prefs for the given session, and broadcast them to all
        // clients sharing this same session ID, to keep them in sync
        if (session) |s| {
            if (app.sessions.get(s)) |prefs| {
                var sse = datastar.NewSSEFromStream(stream, app.gpa);
                defer sse.deinit();

                try sse.patchSignals(.{
                    .sort = @tagName(prefs.sort),
                }, .{}, .{});
            }
        }
    }
};

fn createCats(gpa: Allocator) !Cats {
    var cats: Cats = .empty;
    errdefer cats.deinit(gpa);
    try cats.append(gpa, .{
        .id = 0,
        .name = "Harry",
        .img = "https://images.unsplash.com/photo-1514888286974-6c03e2ca1dba?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8Mnx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(gpa, .{
        .id = 1,
        .name = "Meghan",
        .img = "https://images.unsplash.com/photo-1574144611937-0df059b5ef3e?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8MTR8fGNhdHxlbnwwfHwwfHx8MA%3D%3D",
    });
    try cats.append(gpa, .{
        .id = 2,
        .name = "Prince",
        .img = "https://images.unsplash.com/photo-1574158622682-e40e69881006?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8MjB8fGNhdHxlbnwwfHwwfHx8MA%3D%3D",
    });
    try cats.append(gpa, .{
        .id = 3,
        .name = "Fluffy",
        .img = "https://plus.unsplash.com/premium_photo-1664299749481-ac8dc8b49754?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8OXx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(gpa, .{
        .id = 4,
        .name = "Princessa",
        .img = "https://images.unsplash.com/photo-1472491235688-bdc81a63246e?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8Nnx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(gpa, .{
        .id = 5,
        .name = "Tiger",
        .img = "https://plus.unsplash.com/premium_photo-1673967770669-91b5c2f2d0ce?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8NXx8a2l0dGVufGVufDB8fDB8fHww",
    });
    return cats;
}
