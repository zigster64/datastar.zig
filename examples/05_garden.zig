const std = @import("std");
const datastar = @import("datastar");
const options = @import("options");
const HTTPRequest = datastar.HTTPRequest;
const pubsub = datastar.pubsub;

const Io = std.Io;
const Allocator = std.mem.Allocator;

// Selected at build time via `-Dio=zio`.
const use_zio = options.io_mode == .zio;
const zio = if (use_zio) @import("zio") else void;

const GM = false;
const homepage = @embedFile("05_index.html");

const PORT = 8085;

pub const std_options = std.Options{ .log_level = .debug };

// Schema for messages passed over pubsub
const MQSchema = union(enum) {
    plants: void,
    crops: void,
};

// SSE and pub/sub to have realtime updates of updates to the garden
pub fn main(init: std.process.Init) !void {
    const rt = if (use_zio) try zio.Runtime.init(init.gpa, .{ .executors = .auto }) else {};
    defer if (use_zio) rt.deinit();
    const io: Io = if (use_zio) rt.io() else init.io;

    if (use_zio) std.log.info("🌀 IO backend: zio (stackful coroutines)", .{}) else std.log.info("🧵 IO backend: std Io.Threaded", .{});

    // create the server
    var server = try datastar.HTTPServer.init(init, .{
        .port = PORT,
        .io = io,
        .watch = true,
        .fd_limit = .max,
        .log = .{ .theme = .newwave },
    });
    defer server.deinit();

    // Create global app instance and attach it to the server
    var app = try App.init(server.io, server.allocator);
    defer app.deinit();
    server.useContext(app);

    std.log.info("listening http://localhost:{d}", .{PORT});

    // create routes
    {
        const r = server.router;
        r.get("/", index);
        r.get("/plants", plantList);
        r.post("/planteffect/:side/:plantid", postPlantEffect);
        r.get("/assets/:assetname", getAsset);
    }

    try server.concurrent(updateLoop, .{app});
    try server.run();
}

fn updateLoop(app: *App) Io.Cancelable!void {
    while (true) {
        app.updatePlants() catch return error.Canceled;
        app.io.sleep(.fromSeconds(2), .real) catch return error.Canceled;
    }
}

fn index(http: *HTTPRequest) !void {
    try http.html(homepage);
}

fn getAsset(http: *HTTPRequest) !void {
    const file_name = http.params.get("assetname") orelse return error.NoAssetName;
    try http.sanitizeFileParam(file_name);
    const static_dir = "examples/assets/fantasy_crops";
    const full_path = try std.fmt.allocPrint(http.arena, "{s}/{s}", .{ static_dir, file_name });
    try http.sendFile(full_path, null);
}

fn plantList(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    var sse = try http.NewSSESync();

    try app.pushAll(&sse);

    var mq = try app.pubsub.connect();
    defer mq.deinit();

    try mq.subscribe(.plants);
    try mq.subscribe(.crops);

    while (try mq.nextTimeout(.fromSeconds(30))) |event| {
        switch (event) {
            .msg => |m| {
                std.log.info("Event: {}", .{m.topic});
                switch (m.topic) {
                    .plants => app.pushPlantList(&sse) catch |err|
                        return std.log.warn("Connection dropped for {t} {s} : {} - expect auto reconnect", .{
                            http.method,
                            http.getPathOnly(),
                            err,
                        }),
                    .crops => app.pushCropCounts(&sse) catch |err|
                        return std.log.warn("Connection dropped for {t} {s} : {} - expect auto reconnect", .{
                            http.method,
                            http.getPathOnly(),
                            err,
                        }),
                }
            },
            .timeout => {
                std.log.warn("timeout", .{});
                sse.keepalive() catch |err|
                    return std.log.warn("Connection dropped for {t} {s} : {} - expect auto reconnect", .{
                        http.method,
                        http.getPathOnly(),
                        err,
                    });
            },
        }
    }
    std.log.info("no more events ...", .{});
}

fn postPlantEffect(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    try app.lock();
    defer app.unlock();

    const side_param = http.params.get("side") orelse return error.NoSide;
    const left = if (std.mem.eql(u8, side_param, "inc")) true else false;

    const id = http.params.getInt(u8, "plantid") orelse return error.NoPlantID;

    if (id < 0 or id >= 4) return error.InvalidID;

    const signals = try http.readSignals(struct { hand: []const u8 });

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
            try app.pubsub.publish(.{ .plants = {} }, .all);
            try app.pubsub.publish(.{ .crops = {} }, .all);
            return;
        }

        if (app.plants[id] == null) {
            return error.InvalidID;
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
            app.plants[id] = CarrotConfig;
        } else if (std.mem.eql(u8, signals.hand, "gourd")) {
            app.plants[id] = GourdConfig;
        } else if (std.mem.eql(u8, signals.hand, "radish")) {
            app.plants[id] = RadishConfig;
        } else if (std.mem.eql(u8, signals.hand, "onion")) {
            app.plants[id] = OnionConfig;
        }
    }
    // update any screens subscribed to "plants"
    try app.pubsub.publish(.{ .plants = {} }, .all);

    // need to respond
    try http.json(.{ .id = id, .side = side_param, .left = left, .hand = signals.hand, .plant = app.plants[id] });
}

const Plant = struct {
    crop_type: CropType,
    image_base_index: u32 = 0,

    state: PlantState = .Alive,
    growth_stage: GrowthStage = .Seedling,
    growth_steps: u32 = 0,
    stats: PlantStats = .{}, // Current Stats of plant, dynamic
    desired_stats: PlantStats = .{}, // Desired status of plant, static

    changed: bool = true,

    const CropType = enum {
        Carrot,
        Radish,
        Gourd,
        Onion,
    };
    // Balance stats that prefer to be around 0.5 and dislike being around 0 or 1
    const PlantStats = struct {
        water: f32 = 0.5, // Water saturation, depletes over time based on sun exposure, increased by bucket
        ph: f32 = 0.5, // Abstracted soil level, refers to ph and nutrient levels, depletes over time, increased by fertilizer
        sun: f32 = 0.5, // Availability of sunlight, static but increases water loss
    };
    const image_format_string = "./assets/tile{d:0>3}.png";
    const PlantState = enum {
        Dead,
        Dying,
        Alive,
        Thriving,
    };

    const GrowthStage = enum {
        Seedling,
        Sprout,
        Young,
        Medium,
        Adult,
        Elder,
        Fruiting,
    };

    pub fn update(p: *Plant) !void {
        p.changed = false;
        if (p.state == .Dead or p.growth_stage == .Fruiting) {
            return;
        }
        p.changed = true;
        // Update state based on stats and desired stats
        switch (p.state) {
            .Dead => {},
            .Dying => {
                // Move to alive if conditions are met
                const water_diff = @abs(p.desired_stats.water - p.stats.water);
                const ph_diff = @abs(p.desired_stats.ph - p.stats.ph);
                const sun_diff = @abs(p.desired_stats.sun - p.stats.sun);

                if (water_diff <= 0.3 and ph_diff <= 0.3 and sun_diff <= 0.3) {
                    p.state = .Alive;
                } else if (water_diff > 0.5 or ph_diff > 0.5 or sun_diff > 0.5) {
                    p.state = .Dead;
                }
            },
            .Alive => {
                p.growth_steps += 2;

                const water_diff = @abs(p.desired_stats.water - p.stats.water);
                const ph_diff = @abs(p.desired_stats.ph - p.stats.ph);
                const sun_diff = @abs(p.desired_stats.sun - p.stats.sun);

                if (water_diff <= 0.1 and ph_diff <= 0.1 and sun_diff <= 0.1) {
                    p.state = .Thriving;
                } else if (water_diff > 0.3 or ph_diff > 0.3 or sun_diff > 0.3) {
                    p.state = .Dying;
                }
            },
            .Thriving => {
                p.growth_steps += 4;
                if (GM) {
                    p.growth_steps += 10;
                }

                const water_diff = @abs(p.desired_stats.water - p.stats.water);
                const ph_diff = @abs(p.desired_stats.ph - p.stats.ph);
                const sun_diff = @abs(p.desired_stats.sun - p.stats.sun);

                if (water_diff > 0.1 or ph_diff > 0.1 or sun_diff > 0.1) {
                    p.state = .Alive;
                }
            },
        }

        // Update water
        // std.debug.print("Updating stats...\n", .{});

        if (GM) {
            // Do not reduce stats
            p.stats = p.desired_stats;
        } else {
            p.stats.water -= 0.01;

            // Update ph
            if (p.stats.ph < 0.5) {
                p.stats.ph += 0.01;
            } else {
                p.stats.ph -= 0.01;
            }
        }

        // Grow plant if it breaches the threshold of growth
        if (p.growth_steps > 25 and p.growth_stage != .Fruiting) {
            p.growth_stage = @enumFromInt(@intFromEnum(p.growth_stage) + 1);
            p.growth_steps = 0;
        }
        std.log.debug("Plant stats: {t}:{t}:{t} {{water: {d}, ph: {d}, sun: {d}}}", .{
            p.crop_type,
            p.growth_stage,
            p.state,
            p.stats.water,
            p.stats.ph,
            p.stats.sun,
        });
    }

    pub fn render(p: Plant, id: usize, w: anytype, allocator: std.mem.Allocator) !void {
        const img_name = try std.fmt.allocPrint(
            allocator,
            image_format_string,
            .{
                p.image_base_index + @intFromEnum(p.growth_stage),
            },
        );
        defer allocator.free(img_name);

        const img_class: []const u8 = switch (p.state) {
            .Dead => "dead",
            .Dying => "dying",
            .Alive => "alive",
            .Thriving => "thriving",
        };

        const water_diff = p.stats.water - p.desired_stats.water;
        const ph_diff = p.stats.ph - p.desired_stats.ph;
        const sun_diff = p.stats.sun - p.desired_stats.sun;
        try w.print(
            \\<div class="card-md px-16 w-fit h-fit bg-yellow-700 card-lg shadow-sm m-auto mt-4 border-4 border-solid border-yellow-900">
            \\  <div class="card-body" id="plant-{[id]}">
            \\    <div class="w-full h-full flex flex-col justify-center items-center">
            \\      <div class="avatar w-32 h-32 rounded-md pb-4">
            \\        <img class="{[class]s} rounded-md"
            \\          data-on:click="@post('/planteffect/inc/{[id]}')"
            \\          data-on:contextmenu="evt.preventDefault();@post('/planteffect/dec/{[id]}')"
            \\          src="{[img]s}"
            \\        >
            \\      </div>
            \\      <div id="notifications-bar" class="flex items-center w-10/12 h-4/12 border-4 border-solid border-gray-800 bg-gray-600 rounded-md">
            \\        {[water_n]s}
            \\        {[ph_n]s}
            \\        {[sun_n]s}
            \\      </div>
            \\    </div>
            \\  </div>
            \\</div>
        , .{
            .id = id,
            .img = img_name,
            .class = img_class,
            .water_n = if (water_diff < -0.1)
                \\<div id="water-notif" class="w-10 h-10 bg-blue-500 text-center text-sm overflow-hidden"><img class="m-auto w-6 h-6" src="assets/water.png"> Low </div>
            else if (water_diff > 0.1)
                \\<div id="water-notif" class="w-10 h-10 bg-blue-500 text-center text-sm overflow-hidden"><img class="m-auto w-6 h-6" src="assets/water.png"> High </div>
            else
                \\<div id="water-notif" class="w-10 h-10"></div>
            ,
            .ph_n = if (ph_diff < -0.1)
                \\<div id="ph-notif" class="w-10 h-10 bg-green-500"><img class="m-auto w-6 h-6" src="assets/ph.png"> Low </div>
            else if (ph_diff > 0.1)
                \\<div id="ph-notif" class="w-10 h-10 bg-green-500"><img class="m-auto w-6 h-6" src="assets/ph.png"> High </div>
            else
                \\<div id="ph-notif" class="w-10 h-10"></div>
            ,
            .sun_n = if (sun_diff < -0.1)
                \\<div id="sun-notif" class="w-10 h-10 bg-red-500"><img class="m-auto w-6 h-6" src="assets/sun.png"> Low </div>
            else if (sun_diff > 0.1)
                \\<div id="sun-notif" class="w-10 h-10 bg-red-500"><img class="m-auto w-6 h-6" src="assets/sun.png"> High </div>
            else
                \\<div id="sun-notif" class="w-10 h-10"></div>
            ,
        });
    }
};

const StartingStats: Plant.PlantStats = .{
    .water = 0.5,
    .ph = 0.5,
    .sun = 0.5,
};

const CarrotConfig = Plant{
    .crop_type = .Carrot,
    .image_base_index = 0,
    .desired_stats = .{
        .water = 0.4,
        .ph = 0.4,
        .sun = 0.4,
    },
    .stats = StartingStats,
};

const RadishConfig = Plant{
    .crop_type = .Radish,
    .image_base_index = 49,
    .desired_stats = .{
        .water = 0.5,
        .ph = 0.8,
        .sun = 0.2,
    },
    .stats = StartingStats,
};

const GourdConfig = Plant{
    .crop_type = .Gourd,
    .image_base_index = 28,
    .desired_stats = .{
        .water = 0.2,
        .ph = 0.3,
        .sun = 0.6,
    },
    .stats = StartingStats,
};

const OnionConfig = Plant{
    .crop_type = .Onion,
    .image_base_index = 70,
    .desired_stats = .{
        .water = 0.8,
        .ph = 0.3,
        .sun = 0.6,
    },
    .stats = StartingStats,
};

const App = struct {
    io: Io,
    allocator: Allocator,
    plants: [4]?Plant,
    mutex: Io.Mutex,
    pubsub: pubsub.PubSub(MQSchema),

    // Represented in the order of (0) Carrot (1) Radish (2) Gourd (3) Onion
    crop_counts: [4]u32 = [_]u32{ 0, 0, 0, 0 },

    pub fn init(io: Io, allocator: Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .io = io,
            .allocator = allocator,
            .mutex = .init,
            .plants = .{
                CarrotConfig,
                RadishConfig,
                GourdConfig,
                OnionConfig,
            },
            .pubsub = pubsub.PubSub(MQSchema).init(io, allocator),
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.allocator.destroy(app);
    }

    pub fn lock(app: *App) !void {
        try app.mutex.lock(app.io);
    }

    pub fn unlock(app: *App) void {
        app.mutex.unlock(app.io);
    }

    pub fn pushAll(app: *App, sse: *datastar.SSE) !void {
        try app.pushPlantList(sse);
        try app.pushCropCounts(sse);
    }

    pub fn pushPlantList(app: *App, sse: *datastar.SSE) !void {
        try app.lock();
        defer app.unlock();

        var w = sse.patchElementsWriter(.{});
        try w.print(
            \\<div id="plant-list" class="grid grid-cols-2 grid-rows-2 h-fit">
        , .{});

        for (0..4) |i| {
            if (app.plants[i]) |p| {
                try p.render(i, w, app.allocator);
            } else {
                try w.print(
                    \\<div class="card px-16 py-6 w-fit h-fit bg-yellow-700 card-lg shadow-sm m-auto mt-4 border-4 border-solid border-yellow-900">
                    \\  <div class="avatar">
                    \\      <div class="m-auto w-48 h-48 rounded-md" data-on:click="@post('/planteffect/inc/{[id]}')"> </div>
                    \\  </div>
                    \\</div>
                , .{ .id = i });
            }
        }
        try w.writeAll(
            \\</div>
        );
        try w.flush();
        try sse.flush();
    }

    pub fn pushCropCounts(app: *App, sse: *datastar.SSE) !void {
        try app.lock();
        defer app.unlock();

        try sse.patchSignals(.{
            .carrots = app.crop_counts[0],
            .radishes = app.crop_counts[1],
            .gourds = app.crop_counts[2],
            .onions = app.crop_counts[3],
        }, .{}, .{});
    }

    pub fn updatePlants(app: *App) !void {
        try app.lock();
        defer app.unlock();

        var has_changes: bool = false;
        for (0..4) |i| {
            if (app.plants[i]) |*p| {
                try p.update();
                if (p.changed) {
                    has_changes = true;
                }
            }
        }
        if (has_changes) {
            try app.pubsub.publish(.{ .plants = {} }, .all);
        }
    }
};
