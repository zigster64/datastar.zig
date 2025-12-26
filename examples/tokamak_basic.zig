const std = @import("std");
const tk = @import("tokamak");
const logz = @import("logz");
const datastar = @import("datastar");
const rebooter = @import("rebooter.zig");

const PORT = 8181;

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

const Config = struct {
    logz: logz.Config = .{
        .level = .Info,
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = .stdout,
        .encoding = .logfmt,
    },

    server: tk.ServerOptions = .{
        .listen = .{
            .port = PORT,
            .hostname = "0.0.0.0",
        },
    },
};

const App = struct {
    server: tk.Server,
    routes: []const tk.Route = &.{
        .get("/", index),
        .get("/text-html", textHTML),
        .get("/patch", patchElements),
        .get("/patch/opts", patchElementsOpts),
        .get("/patch/opts/reset", patchElementsOptsReset),
        .get("/patch/json", jsonSignals),
        .get("/patch/signals", patchSignals),
        .get("/patch/signals/onlymissing", patchSignalsOnlyIfMissing),
        .get("/patch/signals/remove/:names", patchSignalsRemove),
        .get("/executescript/:sample", executeScript),
        .get("/svg-morph", svgMorph),
        .get("/mathml-morph", mathMorph),
        .get("/code/:snip", code),
    },

    pub fn configure(bundle: *tk.Bundle) void {
        bundle.addInitHook(logz.setup);
        bundle.addDeinitHook(logz.deinit);
        bundle.addInitHook(printAddress);
    }

    fn printAddress(server: *tk.Server) void {
        std.debug.print("listening http://localhost:{d}/\n", .{server.http.config.port.?});
        std.debug.print("... or any other IP address pointing to this machine\n", .{});
    }
};

pub fn main() !void {
    var dbg = std.heap.DebugAllocator(.{}).init;
    const allocator = dbg.allocator();
    defer _ = dbg.deinit();

    try rebooter.start(allocator);
    try tk.app.run(tk.Server.start, &.{ Config, App });
}

fn index(res: *tk.Response) !void {
    res.body = @embedFile("01_index.html");
}

// Output a normal text/html response, and have it automatically patch the DOM
fn textHTML(res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "textHTML").int("elapsed (μs)", t2 - t1).log();
    }

    res.content_type = .HTML;

    res.body = try std.fmt.allocPrint(
        res.arena,
        \\<p id="text-html">This is update number {d}</p>
    ,
        .{getCountAndIncrement()},
    );
}

// create a patchElements stream, which will write commands over the SSE connection
// to update parts of the DOM. It will look for the DOM with the matching ID in the default case
fn patchElements(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "patchElements").int("elapsed (μs)", t2 - t1).log();
    }

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

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
fn patchElementsOpts(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "patchElementsOpts").int("elapsed (μs)", t2 - t1).log();
    }

    const opts = struct {
        morph: []const u8,
    };

    const signals = try datastar.readSignals(opts, req);
    // jump out if we didnt set anything
    if (signals.morph.len < 1) {
        return;
    }

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

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
fn patchElementsOptsReset(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "patchElementsOptsReset").int("elapsed (μs)", t2 - t1).log();
    }

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

    try sse.patchElements(@embedFile("01_index_opts.html"), .{
        .selector = "#patch-element-card",
    });
}

const FoojBarjResponse = struct {
    fooj: u8,
    barj: u8,
};

fn jsonSignals() !FoojBarjResponse {
    const t1 = std.time.microTimestamp();

    // this will set the following signals, by just outputting a JSON response rather than an SSE response
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "patchSignals").int("fooj", foo).int("barj", bar).int("elapsed (μs)", t2 - t1).log();
    }

    return .{
        .fooj = foo,
        .barj = bar,
    };
}

fn patchSignals(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();

    // Outputs a formatted patch-signals SSE response to update signals
    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    try sse.patchSignals(.{
        .foo = foo,
        .bar = bar,
    }, .{}, .{});

    const t2 = std.time.microTimestamp();
    logz.info().string("event", "patchSignals").int("foo", foo).int("bar", bar).int("elapsed (μs)", t2 - t1).log();
}

fn patchSignalsOnlyIfMissing(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

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

    const t2 = std.time.microTimestamp();
    logz.info().string("event", "patchSignals").int("foo", foo).int("bar", bar).int("elapsed (μs)", t2 - t1).log();
}

fn patchSignalsRemove(req: *tk.Request, res: *tk.Response, signals_to_remove: []const u8) !void {
    const t1 = std.time.microTimestamp();

    // const signals_to_remove: []const u8 = req.param("names").?;
    var names_iter = std.mem.splitScalar(u8, signals_to_remove, ',');

    // Would normally want to escape and validate the provided names here

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

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

    const t2 = std.time.microTimestamp();
    logz.info().string("event", "patchSignalsRemove").string("remove", signals_to_remove).int("elapsed (μs)", t2 - t1).log();
}

fn executeScript(req: *tk.Request, res: *tk.Response, sample_id: u8) !void {
    const t1 = std.time.microTimestamp();

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

    // make up an array of attributes for this
    var attribs = datastar.ScriptAttributes.init(res.arena);
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

    const t2 = std.time.microTimestamp();
    logz.info().string("event", "executeScript").int("sample_id", sample_id).int("elapsed (μs)", t2 - t1).log();
}

// output some morphs to the SVG elements using svg namespace
fn svgMorph(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "svgMorph").int("elapsed (μs)", t2 - t1).log();
    }

    prng.seed(@intCast(std.time.timestamp()));
    const SVGMorphOptions = struct {
        svgMorph: usize = 1,
    };
    const opt = blk: {
        break :blk datastar.readSignals(SVGMorphOptions, req) catch break :blk SVGMorphOptions{ .svgMorph = 1 };
    };
    var sse = try datastar.NewSSESync(req, res);
    defer sse.close(res);

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
        std.Thread.sleep(std.time.ns_per_ms * 100);
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
        std.Thread.sleep(std.time.ns_per_ms * 100);
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
        std.Thread.sleep(std.time.ns_per_ms * 200);
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
fn mathMorph(req: *tk.Request, res: *tk.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "mathMorph").int("elapsed (μs)", t2 - t1).log();
    }

    prng.seed(@intCast(std.time.timestamp()));
    const MathMorphOptions = struct {
        mathmlMorph: usize = 1,
    };
    const opt = blk: {
        break :blk datastar.readSignals(MathMorphOptions, req) catch break :blk MathMorphOptions{ .mathmlMorph = 1 };
    };
    var sse = try datastar.NewSSESync(req, res);
    defer sse.close(res);

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

    var delay: u64 = 100;
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
        std.Thread.sleep(std.time.ns_per_ms * delay);
    }
    try sse.patchSignals(.{ .mathmlMorph = 1 }, .{}, .{});
}
const snippets = [_][]const u8{
    @embedFile("snippets/code1.zig"),
    @embedFile("snippets/code2.zig"),
    @embedFile("snippets/code3.zig"),
    @embedFile("snippets/code4.zig"),
    @embedFile("snippets/code5t.zig"),
    @embedFile("snippets/code6.zig"),
    @embedFile("snippets/code7.zig"),
    @embedFile("snippets/code8.zig"),
    @embedFile("snippets/code9.zig"),
    @embedFile("snippets/code10.zig"),
};

fn code(req: *tk.Request, res: *tk.Response, snip_id: u8) !void {
    if (snip_id < 1 or snip_id > snippets.len) {
        std.debug.print("Invalid code snippet {}, range is 1-{}\n", .{ snip_id, snippets.len });
        return error.InvalidCodeSnippet;
    }

    const data = snippets[snip_id - 1];

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

    const selector = try std.fmt.allocPrint(res.arena, "#code-{d}", .{snip_id});
    var w = sse.patchElementsWriter(.{
        .selector = selector,
        .mode = .append,
    });

    try w.writeAll("<pre><code>");

    var it = std.mem.splitAny(u8, data, "\n");
    while (it.next()) |line| {
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
}
