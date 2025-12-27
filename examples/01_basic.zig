const std = @import("std");
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const rebooter = @import("rebooter.zig");

const Io = std.Io;

const PORT = 8080;

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
    try r.get("/patch/signals", patchSignals);
    try r.get("/patch/signals/onlymissing", patchSignalsOnlyIfMissing);
    try r.get("/patch/signals/remove/:names", patchSignalsRemove);
    try r.get("/executescript/:sample", executeScript);
    try r.get("/svg-morph", svgMorph);
    try r.get("/mathml-morph", mathMorph);
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
    defer std.debug.print("Index elapsed {}(ns)\n", .{t1.read()});

    return http.html(@embedFile("01_index.html"));
}

fn textHtml(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("TextHTML elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    try http.html(
        try std.fmt.allocPrint(http.arena,
            \\<p id="text-html">This is update number {d}</p>
        , .{getCountAndIncrement()}),
    );
}

fn patchElements(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("patchElements elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    var sse = try datastar.NewSSE(http);
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
    defer std.debug.print("patchElementsOpts elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    const Opts = struct {
        morph: []const u8,
    };

    const signals = try http.readSignals(Opts);
    // jump out if we didnt set anything
    if (signals.morph.len < 1) {
        return;
    }

    var sse = try datastar.NewSSE(http);
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
    defer std.debug.print("patchElementsOptsReset elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    var sse = try datastar.NewSSE(http);
    defer sse.close();

    try sse.patchElements(@embedFile("01_index_opts.html"), .{
        .selector = "#patch-element-card",
    });
}

// update signals using plain old JSON response
fn jsonSignals(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("jsonSignals elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    // this will set the following signals, by just outputting a JSON response rather than an SSE response
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    try http.json(.{ .fooj = foo, .barj = bar });
}

fn patchSignals(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("patchSignals elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    // Outputs a formatted patch-signals SSE response to update signals
    var sse = try datastar.NewSSE(http);
    defer sse.close();

    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    try sse.patchSignals(.{
        .foo = foo,
        .bar = bar,
    }, .{}, .{});
}

fn patchSignalsOnlyIfMissing(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("patchSignalsOnlyIfMissing elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    var sse = try datastar.NewSSE(http);
    defer sse.close();

    // this will set the following signals
    const foo = prng.random().intRangeAtMost(u8, 1, 100);
    const bar = prng.random().intRangeAtMost(u8, 1, 100);

    try sse.patchSignals(
        .{
            .newfoo = foo,
            .newbar = bar,
        },
        .{},
        .{ .only_if_missing = true },
    );

    try sse.executeScript("console.log('Patched newfoo and newbar, but only if missing');", .{});
}

fn patchSignalsRemove(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("patchSignalsOnlyIfMissing elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    const signals_to_remove: []const u8 = http.params.get("names").?;
    std.debug.print("s2r {any}\n", .{signals_to_remove});
    var names_iter = std.mem.splitScalar(u8, signals_to_remove, ',');

    var sse = try datastar.NewSSE(http);
    defer sse.close();

    var w = sse.patchSignalsWriter(.{});

    // Formatting of json payload
    const first = names_iter.next();
    if (first) |val| { // If receiving a list, send each signal to be removed
        var curr = val;
        _ = try w.write("{");
        while (names_iter.next()) |next| {
            try w.print("{s}: null, ", .{curr});
            curr = next;
        }
        try w.print("{s}: null }}", .{curr}); // Hack because trailing comma is not ok in json
    } else { // Otherwise, send only the single signal to be removed
        try w.print("{{ {s}: null }}", .{signals_to_remove});
    }
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

fn executeScript(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("executeScript elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    const sample = http.params.get("sample").?;
    const sample_id = try std.fmt.parseInt(u8, sample, 10);

    var sse = try datastar.NewSSE(http);
    defer sse.close();

    // make up an array of attributes for this
    var attribs = datastar.ScriptAttributes.init(http.arena);
    try attribs.put("type", "text/javascript");
    try attribs.put("trace", "true");
    try attribs.put("aardvark", "should appear last, not first");

    switch (sample_id) {
        1 => {
            try sse.executeScript("console.log('Running from executeScript() directly');", .{});
        },
        2 => {
            var w = sse.executeScriptWriter(.{
                .attributes = attribs,
            });
            try w.writeAll(
                \\console.log('Multiline Script, using executeScriptWriter and writing to it');
                \\parent = document.querySelector('#execute-script-page');
                \\console.log(parent.outerHTML);
            );
        },
        3 => {
            try sse.executeScriptFmt("console.log('Using formatted print {d}');", .{sample_id}, .{});
        },
        else => {
            try sse.executeScriptFmt("console.log('Unknown SampleID {d}');", .{sample_id}, .{});
        },
    }
}

// output some morphs to the SVG elements using svg namespace
fn svgMorph(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("svgMorph elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    prng.seed(seed);

    const SVGMorphOptions = struct {
        svgMorph: usize = 1,
    };
    const opt = blk: {
        break :blk http.readSignals(SVGMorphOptions) catch break :blk SVGMorphOptions{};
    };
    var sse = try datastar.NewSSE(http);
    defer sse.close();

    for (1..opt.svgMorph + 1) |_| {
        try sse.patchElementsFmt(
            \\<circle id="svg-circle" cx="{}" cy="{}" r="{}" class="fill-red-500 transition-all duration-500" />
        ,
            .{
                // cicrle x y r
                prng.random().intRangeAtMost(u8, 10, 100),
                prng.random().intRangeAtMost(u8, 10, 100),
                prng.random().intRangeAtMost(u8, 10, 80),
            },
            .{ .namespace = .svg },
        );
        try sse.sync();
        try http.io.sleep(.fromMilliseconds(100), .real);
        try sse.patchElementsFmt(
            \\<rect id="svg-square" x="{}" y="{}" width="{}" height="80" class="fill-green-500 transition-all duration-500" />
        ,
            .{
                // rectangle x y width
                prng.random().intRangeAtMost(u8, 10, 100),
                prng.random().intRangeAtMost(u8, 10, 100),
                prng.random().intRangeAtMost(u8, 10, 80),
            },
            .{ .namespace = .svg },
        );
        try sse.sync();
        try http.io.sleep(.fromMilliseconds(100), .real);
        try sse.patchElementsFmt(
            \\<polygon id="svg-triangle" points="{},{} {},{} {},{}" class="fill-blue-500 transition-all duration-500" />
        ,
            .{
                // polygon random points
                prng.random().intRangeAtMost(u16, 50, 300),
                prng.random().intRangeAtMost(u16, 50, 300),
                prng.random().intRangeAtMost(u16, 50, 300),
                prng.random().intRangeAtMost(u16, 50, 300),
                prng.random().intRangeAtMost(u16, 50, 300),
                prng.random().intRangeAtMost(u16, 50, 300),
            },
            .{ .namespace = .svg },
        );
        try sse.sync();
        try http.io.sleep(.fromMilliseconds(100), .real);
    }
}

const mathMLs = [_][]const u8{
    @embedFile("snippets/math1.html"),
    @embedFile("snippets/math2.html"),
    @embedFile("snippets/math3.html"),
    @embedFile("snippets/math4.html"),
    @embedFile("snippets/math5.html"),
    @embedFile("snippets/math6.html"),
    @embedFile("snippets/math7.html"),
    @embedFile("snippets/math8.html"),
    @embedFile("snippets/math9.html"),
    @embedFile("snippets/math10.html"),
    @embedFile("snippets/math11.html"),
};

// output some random MathML
fn mathMorph(http: HTTPRequest) !void {
    var t1 = try std.time.Timer.start();
    defer std.debug.print("svgMorph elapsed {}(μs)\n", .{t1.read() / std.time.ns_per_ms});

    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    prng.seed(seed);
    const MathMorphOptions = struct {
        mathmlMorph: usize = 1,
    };
    const opt = blk: {
        break :blk http.readSignals(MathMorphOptions) catch break :blk MathMorphOptions{};
    };
    var sse = try datastar.NewSSE(http);
    defer sse.close();

    if (opt.mathmlMorph == 1) {
        try sse.patchElementsFmt(
            \\<mn id="math-factor" class="text-red-500 font-bold">{}</mn>
        ,
            .{prng.random().intRangeAtMost(u16, 2, 22)},
            .{ .namespace = .mathml, .view_transition = true },
        );
        try sse.patchSignals(.{ .mathmlMorph = 1 }, .{}, .{});
        return;
    }

    var delay: i64 = 100;
    for (1..opt.mathmlMorph + 1) |i| {
        switch (mathMLs.len - 3) {
            1, 2 => delay = 2000,
            3 => delay = 1600,
            4 => delay = 1200,
            else => delay = 200,
        }
        if (i > (mathMLs.len - 3)) {}

        const r = prng.random().intRangeAtMost(u8, 1, mathMLs.len);
        try sse.patchElements(mathMLs[r - 1], .{ .namespace = .mathml });
        try sse.sync();
        try http.io.sleep(.fromMilliseconds(delay), .real);
    }
    try sse.patchSignals(.{ .mathmlMorph = 1 }, .{}, .{});
}

fn code(http: HTTPRequest) !void {
    const snip = http.params.get("snip") orelse "1";
    const snip_id = try std.fmt.parseInt(u8, snip, 10);

    if (snip_id < 1 or snip_id > snippets.len) {
        std.debug.print("Invalid code snippet {}, range is 1-{}\n", .{ snip_id, snippets.len });
        return error.InvalidCodeSnippet;
    }

    const data = snippets[snip_id - 1];

    var sse = try datastar.NewSSE(http);
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
