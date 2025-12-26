const std = @import("std");
const httpz = @import("httpz");
const logz = @import("logz");
const datastar = @import("datastar");
const App = @import("022_cats.zig").App;
const SortType = @import("022_cats.zig").SortType;

const Allocator = std.mem.Allocator;

const PORT = 8082;

// This example demonstrates a simple auction site that uses
// SSE and pub/sub to have realtime updates of bids on a Cat auction
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    const app = try App.init(allocator);

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
    router.post("/sort", postSort, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    std.debug.print("... or any other IP address pointing to this machine\n", .{});
    try server.listen();
}

fn index(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "index").int("elapsed (μs)", t2 - t1).log();
    }

    // IF the new connection already has a session cookie, then use that, otherwise generate a brand new session
    var session_id: usize = 0;

    var cookies = req.cookies();
    if (cookies.get("session")) |session_cookie| {
        session_id = std.fmt.parseInt(usize, session_cookie, 10) catch 0;
        logz.info().string("existing session", session_cookie).int("numeric_value", session_id).log();

        try app.ensureSession(session_cookie);
    } else {
        session_id = try app.newSessionID();
        //
        // generate a Session ID and attach it to this user via a cookie
        try res.setCookie("session", try std.fmt.allocPrint(res.arena, "{d}", .{session_id}), .{
            .path = "/",
            // .domain = "localhost",
            // .max_age = 9001,
            // .secure = true,
            .http_only = true,
            // .partitioned = true,
            // .same_site = .none, // or .none, or .strict (or null to leave out)
        });
        logz.info().string("new session", "no initial cookie").int("numeric_value", session_id).log();
    }

    res.content_type = .HTML;
    res.body = @embedFile("022_index.html");
}

fn catsList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    app.mutex.lock();
    defer {
        app.mutex.unlock();
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "catsList").int("elapsed (μs)", t2 - t1).log();
    }

    var cookies = req.cookies();
    if (cookies.get("session")) |session| {
        // validated session
        const sse = try datastar.NewSSESync(req, res);
        try app.subscribeSession("cats", sse.stream, App.publishCatList, session);
        try app.subscribeSession("prefs", sse.stream, App.publishPrefs, session);
    } else {
        std.debug.print("cant find session cookie - redirect to new login\n", .{});
        // no valid session - create a new one
        // redirect them to /
        var sse = try datastar.NewSSE(req, res);
        defer sse.close(res);
        try sse.executeScript("window.location='/'", .{});
    }
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

    app.sortCats(.id);

    const Bids = struct {
        bids: []usize,
    };
    const signals = try datastar.readSignals(Bids, req);
    // std.debug.print("bids {any}\n", .{signals.bids});
    const new_bid = signals.bids[id];
    // std.debug.print("new bid {}\n", .{new_bid});

    app.cats.items[id].bid = new_bid;
    app.cats.items[id].ts = std.time.nanoTimestamp();

    // update any screens subscribed to "cats"
    try app.publish("cats");
}

fn postSort(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    app.mutex.lock();
    defer {
        app.mutex.unlock();
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "postSort").int("elapsed (μs)", t2 - t1).log();
    }

    // const x = req.body();
    // std.debug.print("request body for sort = {?s}\n", .{x});

    const params = struct {
        sort: []const u8,
    };
    if (try req.json(params)) |p| {
        const new_sort = SortType.fromString(p.sort);

        var cookies = req.cookies();
        if (cookies.get("session")) |session| {
            std.debug.print("postSort got session cookie {s}\n", .{session});
            if (app.sessions.getPtr(session)) |app_session| {
                std.debug.print("  PostSort for Session {s} changed prefs from {t} -> {t}\n", .{ session, app_session.sort, new_sort });
                app_session.sort = new_sort;
                try app.publishSession("cats", session);
                try app.publishSession("prefs", session);
                return;
            }
        }
    }
    std.debug.print("no cookie / no session - user must reconnect to get a new cookie", .{});
    res.status = 400;
    res.body = "No session";
    return;
}
