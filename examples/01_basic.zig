const std = @import("std");
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const rebooter = @import("rebooter.zig");

const Io = std.Io;

const PORT = 8080;
const MAX_THREADS = 100;

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

    try rebooter.start(io, allocator);

    std.debug.print(
        "Created Threaded IO with limit of {} threads\n",
        .{threaded.async_limit.toInt() orelse 0},
    );

    var server = try datastar.Server.init(io, allocator, "0.0.0.0", PORT);
    defer server.deinit();

    const r = server.router;
    try r.get("/", index);

    try r.get("/text-html", textHtml);
    try r.get("/patch", patchElements);
    try r.post("/patch/opts", patchElementsOpts);
    try r.post("/patch/opts/reset", patchElementsOptsReset);
    try r.get("/patch/json", jsonSignals);

    try r.get("/code/:snip", code);

    // router.get("/patch/signals", patchSignals, .{});
    // router.get("/patch/signals/onlymissing", patchSignalsOnlyIfMissing, .{});
    // router.get("/patch/signals/remove/:names", patchSignalsRemove, .{});
    // router.get("/executescript/:sample", executeScript, .{});
    // router.get("/svg-morph", svgMorph, .{});
    // router.get("/mathml-morph", mathMorph, .{});

    std.debug.print("Server listening on http://localhost:8080\n", .{});
    try server.run();
}

fn index(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("Index elapsed {}(ns)\n", .{t1.read()});
    }
    const html = @embedFile("01_index.html");
    return http.html(html);
}

fn textHtml(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("TextHTML elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});
    }

    try http.html(
        try std.fmt.allocPrint(http.arena,
            \\<p id="text-html">This is update number {d}</p>
        , .{getCountAndIncrement()}),
    );
}

fn patchElements(http: HTTPRequest) !void {
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

// create a patchElements stream, which will write commands over the SSE connection
// to update parts of the DOM. It will look for the DOM with the matching ID in the default case
//
// Use a variety of patch options for this one
fn patchElementsOpts(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("patchElementsOpts elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});
    }

    const Opts = struct {
        morph: []const u8,
    };

    const signals = try http.readSignals(Opts);
    // jump out if we didnt set anything
    if (signals.morph.len < 1) {
        return;
    }

    var buf: [1024]u8 = undefined;
    var sse = try datastar.NewSSE(http, &buf);
    defer sse.close();

    // read the signals to work out which options to set, checking the name of the
    // option vs the enum values, and add them relative to the mf-patch-opt item
    var patch_mode: datastar.PatchMode = .outer;
    for (std.enums.values(datastar.PatchMode)) |mt| {
        if (std.mem.eql(u8, @tagName(mt), signals.morph)) {
            patch_mode = mt;
            break; // can only have 1 patch type
        }
    }

    if (patch_mode == .outer or patch_mode == .inner) {
        return; // dont do morphs - its not relevant to this demo card
    }

    var w = sse.patchElementsWriter(.{
        .selector = "#mf-patch-opts",
        .mode = patch_mode,
    });
    switch (patch_mode) {
        .replace => {
            try w.writeAll(
                \\<p id="mf-patch-opts" class="border-4 border-error">Complete Replacement of the OUTER HTML</p>
            );
        },
        else => {
            try w.print(
                \\<p>This is update number {d}</p>
            , .{getCountAndIncrement()});
        },
    }
}

// Just reset the options form if it gets ugly
fn patchElementsOptsReset(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("patchElementsOptsReset elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});
    }

    var buf: [1024]u8 = undefined;
    var sse = try datastar.NewSSE(http, &buf);
    defer sse.close();

    try sse.patchElements(@embedFile("01_index_opts.html"), .{
        .selector = "#patch-element-card",
    });
}

// update signals using plain old JSON response
fn jsonSignals(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("jsonSignals elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});
    }

    // this will set the following signals, by just outputting a JSON response rather than an SSE response
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    try http.json(.{ .fooj = foo, .barj = bar });
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
    const snip = http.params.get("snip") orelse "1";
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
