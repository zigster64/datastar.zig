const std = @import("std");
const httpz = @import("httpz");
const logz = @import("logz");
const datastar = @import("datastar");
const plants = @import("05_plants.zig");
const homepage = @embedFile("05_index.html");

const App = plants.App;
const Allocator = std.mem.Allocator;

const PORT = 8085;

// SSE and pub/sub to have realtime updates of updates to the garden
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    var server = try httpz.Server(*App).init(allocator, .{
        .port = PORT,
        .address = "0.0.0.0",
    }, app);

    const game_t = try std.Thread.spawn(.{}, updateLoop, .{app});
    defer game_t.join();

    defer { // clean shutdown
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
    router.get("/plants", plantList, .{});
    router.post("/planteffect/:side/:plantid", postPlantEffect, .{});
    router.get("/assets/:assetname", postAsset, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    std.debug.print("... or any other IP address pointing to this machine\n", .{});
    try server.listen();
}

fn updateLoop(app: *App) !void {
    while (true) {
        try app.updatePlants();
        std.Thread.sleep(std.time.ns_per_s);
    }
}

fn index(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "index").int("elapsed (μs)", t2 - t1).log();
    }
    res.content_type = .HTML;
    res.body = homepage;
}

fn postAsset(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "index").int("elapsed (μs)", t2 - t1).log();
    }
    const file_name = req.param("assetname").?;

    const static_dir = "./examples/assets/fantasy_crops"; //try std.fmt.allocPrint(res.arena, "{s}/{s}", .{static_dir,file_name});
    const fullPath = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ static_dir, file_name });

    const file = try std.fs.cwd().openFile(fullPath, .{});
    defer file.close();
    res.content_type = .PNG;
    res.body = try file.readToEndAlloc(res.arena, 100000);
}

fn plantList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    app.mutex.lock();
    defer {
        app.mutex.unlock();
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "plantsList").int("elapsed (μs)", t2 - t1).log();
    }

    const sse = try datastar.NewSSESync(req, res);
    try app.subscribe("plants", sse.stream, App.publishPlantList);
    try app.subscribe("crops", sse.stream, App.publishCropCounts);
}

fn postPlantEffect(app: *App, req: *httpz.Request, _: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    app.mutex.lock();
    defer {
        app.mutex.unlock();
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "postPlantEffect").int("elapsed (μs)", t2 - t1).log();
    }

    const side_param = req.param("side").?;
    const left = if (std.mem.eql(u8, side_param, "inc")) true else false;

    const id_param = req.param("plantid").?;
    const id = try std.fmt.parseInt(usize, id_param, 10);

    if (id < 0 or id >= 4) return error.InvalidID;

    const Hand = struct {
        hand: []const u8,
    };

    const signals = try datastar.readSignals(Hand, req);

    var plant_slot = app.plants[id];
    if (plant_slot) |*plant| { // Plant exists
        if (plant.growth_stage == .Fruiting) { //Collect crop and update crop counter
            switch (plant.crop_type) {
                .Carrot => {
                    app.crop_counts[0] += 1;
                },
                .Radish => {
                    app.crop_counts[1] += 1;
                },
                .Gourd => {
                    app.crop_counts[2] += 1;
                },
                .Onion => {
                    app.crop_counts[3] += 1;
                },
            }
            app.plants[id] = null;
            try app.publish("plants");
            try app.publish("crops");
            return;
        }

        if (std.mem.eql(u8, signals.hand, "watering")) {
            app.plants[id].?.stats.water += if (left) 0.1 else 0;
        } else if (std.mem.eql(u8, signals.hand, "fertilizing")) {
            app.plants[id].?.stats.ph += if (left) 0.1 else -0.1;
        } else if (std.mem.eql(u8, signals.hand, "sunning")) {
            app.plants[id].?.stats.sun += if (left) 0.1 else -0.1;
        } else if (std.mem.eql(u8, signals.hand, "shovel")) {
            // Remove plant at index
            app.plants[id] = null;
        }
    } else {
        if (std.mem.eql(u8, signals.hand, "carrot")) {
            app.plants[id] = plants.CarrotConfig;
        } else if (std.mem.eql(u8, signals.hand, "gourd")) {
            app.plants[id] = plants.GourdConfig;
        } else if (std.mem.eql(u8, signals.hand, "radish")) {
            app.plants[id] = plants.RadishConfig;
        } else if (std.mem.eql(u8, signals.hand, "onion")) {
            app.plants[id] = plants.OnionConfig;
        }
    }
    // update any screens subscribed to "plants"
    try app.publish("plants");
}
