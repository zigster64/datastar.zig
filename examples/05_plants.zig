const std = @import("std");
const Stream = std.net.Stream;
const httpz = @import("httpz");
const logz = @import("logz");
const datastar = @import("datastar");

const Allocator = std.mem.Allocator;
const PORT = 8085;

const GM = false;

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
        std.debug.print("Updating stats...\n", .{});

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
        std.debug.print("Plant stats: {{water: {d}, ph: {d}, sun: {d}}}\n", .{
            p.stats.water,
            p.stats.ph,
            p.stats.sun,
        });
    }

    pub fn render(p: Plant, id: usize, w: anytype, gpa: std.mem.Allocator) !void {
        const img_name = try std.fmt.allocPrint(gpa, image_format_string, .{p.image_base_index + @intFromEnum(p.growth_stage)});
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

pub const CarrotConfig = Plant{
    .crop_type = .Carrot,
    .image_base_index = 0,
    .desired_stats = .{
        .water = 0.4,
        .ph = 0.4,
        .sun = 0.4,
    },
    .stats = StartingStats,
};

pub const RadishConfig = Plant{
    .crop_type = .Radish,
    .image_base_index = 49,
    .desired_stats = .{
        .water = 0.5,
        .ph = 0.8,
        .sun = 0.2,
    },
    .stats = StartingStats,
};

pub const GourdConfig = Plant{
    .crop_type = .Gourd,
    .image_base_index = 28,
    .desired_stats = .{
        .water = 0.2,
        .ph = 0.3,
        .sun = 0.6,
    },
    .stats = StartingStats,
};

pub const OnionConfig = Plant{
    .crop_type = .Onion,
    .image_base_index = 70,
    .desired_stats = .{
        .water = 0.8,
        .ph = 0.3,
        .sun = 0.6,
    },
    .stats = StartingStats,
};

pub const App = struct {
    gpa: Allocator,
    plants: [4]?Plant,
    mutex: std.Thread.Mutex,
    subscribers: datastar.Subscribers(*App),

    // Represented in the order of (0) Carrot (1) Radish (2) Gourd (3) Onion
    crop_counts: [4]u32 = [_]u32{ 0, 0, 0, 0 },

    pub fn init(gpa: Allocator) !*App {
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .mutex = .{},
            .plants = .{
                CarrotConfig,
                RadishConfig,
                GourdConfig,
                OnionConfig,
            },
            .subscribers = try datastar.Subscribers(*App).init(gpa, app),
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.gpa.destroy(app);
    }

    // convenience function
    pub fn subscribe(app: *App, topic: []const u8, stream: Stream, callback: anytype) !void {
        try app.subscribers.subscribe(topic, stream, callback);
    }

    // convenience function
    pub fn publish(app: *App, topic: []const u8) !void {
        try app.subscribers.publish(topic);
    }

    pub fn publishPlantList(app: *App, stream: Stream, _: ?[]const u8) !void {
        const t1 = std.time.microTimestamp();
        defer {
            const t2 = std.time.microTimestamp();
            logz.info().string("event", "publishPlantList").int("stream", stream.handle).int("elapsed (μs)", t2 - t1).log();
        }

        var sse = datastar.NewSSEFromStream(stream, app.gpa);
        defer sse.deinit();

        var w = sse.patchElementsWriter(.{});
        try w.print(
            \\<div id="plant-list" class="grid grid-cols-2 grid-rows-2 h-fit">
        , .{});

        for (0..4) |i| {
            if (app.plants[i]) |p| {
                try p.render(i, w, app.gpa);
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
    }

    pub fn publishCropCounts(app: *App, stream: Stream, _: ?[]const u8) !void {
        const t1 = std.time.microTimestamp();
        defer {
            const t2 = std.time.microTimestamp();
            logz.info().string("event", "publishCropCounts").int("stream", stream.handle).int("elapsed (μs)", t2 - t1).log();
        }

        const Counts = struct {
            carrots: usize,
            radishes: usize,
            gourds: usize,
            onions: usize,
        };
        var sse = datastar.NewSSEFromStream(stream, app.gpa);
        defer sse.deinit();

        try sse.patchSignals(Counts{
            .carrots = app.crop_counts[0],
            .radishes = app.crop_counts[1],
            .gourds = app.crop_counts[2],
            .onions = app.crop_counts[3],
        }, .{}, .{});
    }

    pub fn updatePlants(app: *App) !void {
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
            try app.publish("plants");
        }
    }
};
