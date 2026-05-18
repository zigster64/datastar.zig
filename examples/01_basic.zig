const std = @import("std");
const datastar = @import("datastar");
const options = @import("options");
const HTTPRequest = datastar.HTTPRequest;

const Io = std.Io;

// Selected at build time via `-Dio=zio`. When false, the example runs on the
// stdlib Io.Threaded that std.process.Init hands us. When true, we spin up a
// zio.Runtime and use its std.Io implementation so handlers run on stackful
// coroutines instead of OS threads.
const use_zio = options.io_mode == .zio;
const zio = if (use_zio) @import("zio") else void;

const PORT = 8081;

pub const std_options = std.Options{ .log_level = .debug };

var update_count: usize = 1;
var update_mutex: Io.Mutex = .init;

var prng: std.Random.DefaultPrng = .init(0);

fn getCountAndIncrement(io: Io) !usize {
    try update_mutex.lock(io);
    defer {
        update_count += 1;
        update_mutex.unlock(io);
    }
    return update_count;
}

var hotreload_id: u64 = 0;

fn setHotReload(io: Io) !void {
    const now = std.Io.Clock.real.now(io);
    prng.seed(@intCast(now.toMilliseconds()));
    hotreload_id = prng.random().int(u64);
    std.log.debug("Hotreload ID {}", .{hotreload_id});
}

pub fn main(init: std.process.Init) !void {
    const rt = if (use_zio) try zio.Runtime.init(init.gpa, .{ .executors = .auto }) else {};
    defer if (use_zio) rt.deinit();
    const io: Io = if (use_zio) rt.io() else init.io;

    if (use_zio) std.log.info("🌀 IO backend: zio (stackful coroutines)", .{}) else std.log.info("🧵 IO backend: std Io.Threaded", .{});

    try setHotReload(io);

    var server = try datastar.HTTPServer.init(init, .{
        .port = PORT,
        .io = io,
        .log = .{
            .format = .terminal,
            .theme = .monochrom,
            .level = .payload,
            .fast_us = 80,
            .slow_ms = 200,
        },
        .watch = true,
        .fd_limit = .max,
    });
    defer server.deinit();
    std.log.info("Server listening on http://localhost:{}", .{PORT});

    {
        const r = server.router;
        r.get("/", index);
        r.get("/style.css", styleCss);

        r.get("/text-html", textHtml);
        r.patch("/patch", patchElements);
        r.post("/patch/opts", patchElementsOpts);
        r.post("/patch/opts/reset", patchElementsOptsReset);
        r.get("/patch/json", jsonSignals);
        r.get("/patch/signals", patchSignals);
        r.get("/patch/signals/onlymissing", patchSignalsOnlyIfMissing);
        r.get("/patch/signals/remove/:names", patchSignalsRemove);
        r.put("/executescript/:sample", executeScript);
        r.get("/svg-morph", svgMorph);
        r.get("/mathml-morph", mathMorph);
        r.get("/code/:snip", code);

        r.get("/mime/:filename", mimeTest);

        // Reboot on recompile, and hot reload the client
        r.post("/hotreload/:id", hotreload);
    }

    try server.run();
}

fn index(http: *HTTPRequest) !void {
    return http.htmlFmt(@embedFile("01_index.html"), .{
        .hotreload_id = hotreload_id,
        .web_server = "Datastar.Zig Web Server",
    });
}

fn styleCss(http: *HTTPRequest) !void {
    return http.css(@embedFile("style.css"));
}

fn hotreload(http: *HTTPRequest) !void {
    const id = http.params.getInt(u64, "id") orelse 0;
    var sse = try http.NewSSESync();
    defer sse.close();
    if (id != hotreload_id) {
        std.log.warn("Client is stale {} != {} - reload them", .{ id, hotreload_id });
        try sse.executeScript("window.location.reload()", .{});
    }

    // client is connected to the correct app, so just wait forever
    // with regular 1minute keepalives
    // When the server restarts, the client will hit this endpoint again
    // with the old hotreload_id, causing a full page refresh
    while (true) {
        try http.io.sleep(.fromSeconds(60), .real);
        try sse.keepalive();
    }
}

fn textHtml(http: *HTTPRequest) !void {
    try http.html(
        try std.fmt.allocPrint(http.arena,
            \\<p id="text-html">This is update number {d}</p>
        , .{try getCountAndIncrement(http.io)}),
    );
}

fn patchElements(http: *HTTPRequest) !void {
    // Apply extra headers to the HTTPRequest before the response is sent
    http.extra_headers = &.{
        .{ .name = "X-More-Headers", .value = "Top level http extra headers" },
        .{ .name = "X-Even-More-Headers", .value = "Top level http more headers" },
    };

    // Append additional headers to a HTTPRequest before the response is sent
    http.extra_headers = try http.mergeHeaders(&.{
        .{ .name = "X-Appended-Headers", .value = "These were appended to the top level" },
        .{ .name = "X-Even-More-Appended-eaders", .value = "More appended to the top level" },
    });

    // Define extra headers here when creating the SSE response
    var sse = try http.NewSSEOpt(.{ .extra_headers = &.{
        .{ .name = "X-SSE-More-Headers", .value = "Patch Elements Example" },
        .{ .name = "X-SSE-Even-More-Headers", .value = "All the Headers" },
    } });
    defer sse.close();

    try sse.patchElementsFmt(
        \\<p id="mf-patch">This is update number {d}</p>
    ,
        .{try getCountAndIncrement(http.io)},
        .{},
    );
}

// create a patchElements stream, which will write commands over the SSE connection
// to update parts of the DOM. It will look for the DOM with the matching ID in the default case
//
// Use a variety of patch options for this one
fn patchElementsOpts(http: *HTTPRequest) !void {
    const signals = try http.readSignals(struct { morph: []const u8 });

    // jump out if we didnt set anything
    if (signals.morph.len < 1) {
        return;
    }

    var sse = try http.NewSSE();
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
            , .{try getCountAndIncrement(http.io)});
        },
    }
}

// Just reset the options form if it gets ugly
fn patchElementsOptsReset(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements(@embedFile("01_index_opts.html"), .{});
}

// update signals using plain old JSON response
fn jsonSignals(http: *HTTPRequest) !void {
    // this will set the following signals, by just outputting a JSON response rather than an SSE response
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    try http.json(.{ .fooj = foo, .barj = bar });
}

fn patchSignals(http: *HTTPRequest) !void {
    // Outputs a formatted patch-signals SSE response to update signals
    var sse = try http.NewSSE();
    defer sse.close();

    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    try sse.patchSignals(.{
        .foo = foo,
        .bar = bar,
    }, .{}, .{});
}

fn patchSignalsOnlyIfMissing(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
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

fn patchSignalsRemove(http: *HTTPRequest) !void {
    const signals_to_remove: []const u8 = http.params.get("names") orelse return error.InvalidSignalName;
    var names_iter = std.mem.splitScalar(u8, signals_to_remove, ',');

    var sse = try http.NewSSE();
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
    @embedFile("snippets/code11.zig"),
};

fn executeScript(http: *HTTPRequest) !void {
    const sample = http.params.getInt(u8, "sample") orelse 0;

    var sse = try http.NewSSE();
    defer sse.close();

    // make up an array of attributes for this
    var attribs = datastar.ScriptAttributes.init(http.arena);
    try attribs.put("type", "text/javascript");
    try attribs.put("trace", "true");
    try attribs.put("aardvark", "should appear last, not first");

    switch (sample) {
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
            try sse.executeScriptFmt("console.log('Using formatted print {d}');", .{sample}, .{});
        },
        else => {
            try sse.executeScriptFmt("console.log('Unknown SampleID {d}');", .{sample}, .{});
        },
    }
}

// output some morphs to the SVG elements using svg namespace
fn svgMorph(http: *HTTPRequest) !void {
    const opt = try http.readSignals(struct { svgMorph: usize = 1 });
    var sse = try http.NewSSESync();
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
fn mathMorph(http: *HTTPRequest) !void {
    const opt = try http.readSignals(struct { mathmlMorph: usize = 1 });
    var sse = try http.NewSSESync();
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
        try http.io.sleep(.fromMilliseconds(delay), .real);
    }
    try sse.patchSignals(.{ .mathmlMorph = 1 }, .{}, .{});
}

fn code(http: *HTTPRequest) !void {
    const snip = http.params.getInt(u8, "snip") orelse 1;

    if (snip < 1 or snip > snippets.len) {
        std.log.warn("Invalid code snippet {}, range is 1-{}", .{ snip, snippets.len });
        return error.InvalidCodeSnippet;
    }

    const data = snippets[snip - 1];

    var sse = try http.NewSSE();
    defer sse.close();

    const selector = try std.fmt.allocPrint(http.arena, "#code-{}", .{snip});
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
}

fn mimeTest(http: *HTTPRequest) !void {
    const filename = http.params.get("filename") orelse return error.NoFilename;
    return http.sendFile(
        try std.fmt.allocPrint(
            http.arena,
            "examples/assets/mime-tests/{s}",
            .{filename},
        ),
        null,
    );
}
