// 01_basic.zig — the kitchen-sink example, ported to karlseguin's http.zig.
//
// This is the same demo as examples/01_basic.zig, but the bundled
// datastar.HTTPServer has been swapped out for httpz. SSE payloads are now built
// with the framework-agnostic transformer functions:
//
//     datastar.patchElements(arena, html, opts)         ![]const u8
//     datastar.patchElementsFmt(arena, fmt, args, opts) ![]const u8
//     datastar.patchSignals(arena, value, opts)         ![]const u8
//     datastar.executeScript(arena, script, opts)       ![]const u8
//     datastar.executeScriptFmt(arena, fmt, args, opts) ![]const u8
//
// The string each one returns is a complete `event: ...\ndata: ...\n\n` block;
// concatenate as many as you want and ship them as the response body with
// Content-Type: text/event-stream.
//
// Build with:  zig build http.zig
// Run with:    ./zig-out/bin/example_1_httpz

const std = @import("std");
const httpz = @import("httpz");
const datastar = @import("datastar");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const PORT = 8081;

pub const std_options = std.Options{ .log_level = .debug };

var update_count: usize = 1;
var update_mutex: Io.Mutex = .init;

var prng: std.Random.DefaultPrng = .init(0);

// Shared with the spawned SSE stream handlers (svgMorph / mathMorph / hotreload).
// httpz spawns these on detached OS threads and only passes the user-supplied
// ctx + the stream — so we stash io here for them to reach.
var shared_io: Io = undefined;

fn getCountAndIncrement(io: Io) !usize {
    try update_mutex.lock(io);
    defer {
        update_count += 1;
        update_mutex.unlock(io);
    }
    return update_count;
}

var hotreload_id: u64 = 0;

fn setHotReload(io: Io) void {
    const ts = Io.Clock.now(.real, io);
    const seed_u96: u96 = @bitCast(ts.nanoseconds);
    prng.seed(@truncate(seed_u96));
    hotreload_id = prng.random().int(u64);
    std.log.debug("Hotreload ID {}", .{hotreload_id});
}

pub fn main(init: std.process.Init) !void {
    shared_io = init.io;
    setHotReload(init.io);

    const allocator = init.gpa;

    var server = try httpz.Server(void).init(init.io, allocator, .{
        .address = .localhost(PORT),
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", index, .{});
    router.get("/style.css", styleCss, .{});

    router.get("/text-html", textHtml, .{});
    router.patch("/patch", patchElements, .{});
    router.post("/patch/opts", patchElementsOpts, .{});
    router.post("/patch/opts/reset", patchElementsOptsReset, .{});
    router.get("/patch/json", jsonSignals, .{});
    router.get("/patch/signals", patchSignals, .{});
    router.get("/patch/signals/onlymissing", patchSignalsOnlyIfMissing, .{});
    router.get("/patch/signals/remove/:names", patchSignalsRemove, .{});
    router.put("/executescript/:sample", executeScript, .{});
    router.get("/svg-morph", svgMorph, .{});
    router.get("/mathml-morph", mathMorph, .{});
    router.get("/code/:snip", code, .{});

    router.get("/mime/:filename", mimeTest, .{});

    router.post("/hotreload/:id", hotreload, .{});

    std.log.info("Server listening on http://localhost:{}", .{PORT});
    try server.listen();
}

// Read Datastar signals out of any httpz.Request — GET pulls them from the
// `datastar` query param, POST/PUT/PATCH/DELETE pulls them from the body.
fn readSignals(comptime T: type, req: *httpz.Request) !T {
    const arena = req.arena;
    const json_text: []const u8 = switch (req.method) {
        .GET => blk: {
            const qs = try req.query();
            // httpz already URL-decodes query values, so this is raw JSON.
            break :blk qs.get("datastar") orelse return error.MissingDatastarKey;
        },
        else => req.body() orelse return error.MissingBody,
    };
    return std.json.parseFromSliceLeaky(
        T,
        arena,
        json_text,
        .{ .ignore_unknown_fields = true },
    );
}

// Helper — set up `res` for a Datastar SSE response.
fn beginSse(res: *httpz.Response) void {
    res.content_type = .EVENTS;
    res.header("Cache-Control", "no-cache");
}

fn paramInt(comptime T: type, req: *httpz.Request, name: []const u8) ?T {
    const raw = req.param(name) orelse return null;
    return std.fmt.parseInt(T, raw, 10) catch null;
}

// Wrap an Io.net.Stream as an Io.Writer so we can blast SSE blocks at it.
fn streamWriteAll(stream: Io.net.Stream, io: Io, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = try std.fmt.allocPrint(
        res.arena,
        @embedFile("01_index.html"),
        .{
            .hotreload_id = hotreload_id,
            .web_server = "http.zig Web Server",
        },
    );
}

fn styleCss(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.body = @embedFile("style.css");
}

fn textHtml(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = try std.fmt.allocPrint(res.arena,
        \\<p id="text-html">This is update number {d}</p>
    , .{try getCountAndIncrement(shared_io)});
}

fn patchElements(_: *httpz.Request, res: *httpz.Response) !void {
    beginSse(res);
    res.header("X-SSE-More-Headers", "Patch Elements Example");
    res.header("X-SSE-Even-More-Headers", "All the Headers");

    res.body = try datastar.patchElementsFmt(
        res.arena,
        \\<p id="mf-patch">This is update number {d}</p>
    ,
        .{try getCountAndIncrement(shared_io)},
        .{},
    );
}

fn patchElementsOpts(req: *httpz.Request, res: *httpz.Response) !void {
    const signals = try readSignals(struct { morph: []const u8 }, req);
    if (signals.morph.len < 1) return;

    var patch_mode: datastar.PatchMode = .outer;
    for (std.enums.values(datastar.PatchMode)) |mt| {
        if (std.mem.eql(u8, @tagName(mt), signals.morph)) {
            patch_mode = mt;
            break;
        }
    }
    if (patch_mode == .outer or patch_mode == .inner) return;

    const opts: datastar.PatchElementsOptions = .{
        .selector = "#mf-patch-opts",
        .mode = patch_mode,
    };

    beginSse(res);
    res.body = switch (patch_mode) {
        .replace => try datastar.patchElements(
            res.arena,
            \\<p id="mf-patch-opts" class="border-4 border-error">Complete Replacement of the OUTER HTML</p>
        ,
            opts,
        ),
        else => try datastar.patchElementsFmt(
            res.arena,
            \\<p>This is update number {d}</p>
        ,
            .{try getCountAndIncrement(shared_io)},
            opts,
        ),
    };
}

fn patchElementsOptsReset(_: *httpz.Request, res: *httpz.Response) !void {
    beginSse(res);
    res.body = try datastar.patchElements(res.arena, @embedFile("01_index_opts.html"), .{});
}

// Plain JSON response — Datastar can pick up signals from a regular JSON body.
fn jsonSignals(_: *httpz.Request, res: *httpz.Response) !void {
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);
    try res.json(.{ .fooj = foo, .barj = bar }, .{});
}

fn patchSignals(_: *httpz.Request, res: *httpz.Response) !void {
    beginSse(res);
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);
    res.body = try datastar.patchSignals(res.arena, .{ .foo = foo, .bar = bar }, .{});
}

// Two SSE blocks in one response — just concatenate.
fn patchSignalsOnlyIfMissing(_: *httpz.Request, res: *httpz.Response) !void {
    beginSse(res);
    const foo = prng.random().intRangeAtMost(u8, 1, 100);
    const bar = prng.random().intRangeAtMost(u8, 1, 100);

    const signals_block = try datastar.patchSignals(
        res.arena,
        .{ .newfoo = foo, .newbar = bar },
        .{ .only_if_missing = true },
    );
    const script_block = try datastar.executeScript(
        res.arena,
        "console.log('Patched newfoo and newbar, but only if missing');",
        .{},
    );
    res.body = try std.mem.concat(res.arena, u8, &.{ signals_block, script_block });
}

// Build the signals-removal payload as a JSON object of {name: null, ...},
// then hand it to patchSignals so we get a properly formatted SSE block back.
fn patchSignalsRemove(req: *httpz.Request, res: *httpz.Response) !void {
    const signals_to_remove = req.param("names") orelse return error.InvalidSignalName;

    var json_buf: Io.Writer.Allocating = .init(res.arena);
    try json_buf.writer.writeAll("{");
    var it = std.mem.splitScalar(u8, signals_to_remove, ',');
    var first = true;
    while (it.next()) |name| {
        if (!first) try json_buf.writer.writeAll(",");
        try json_buf.writer.print("\"{s}\":null", .{name});
        first = false;
    }
    try json_buf.writer.writeAll("}");

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        res.arena,
        json_buf.written(),
        .{},
    );

    beginSse(res);
    res.body = try datastar.patchSignals(res.arena, parsed, .{});
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

fn executeScript(req: *httpz.Request, res: *httpz.Response) !void {
    const sample = paramInt(u8, req, "sample") orelse 0;

    var attribs = datastar.ScriptAttributes.init(res.arena);
    try attribs.put("type", "text/javascript");
    try attribs.put("trace", "true");
    try attribs.put("aardvark", "should appear last, not first");

    beginSse(res);
    res.body = switch (sample) {
        1 => try datastar.executeScript(
            res.arena,
            "console.log('Running from executeScript() directly');",
            .{},
        ),
        2 => try datastar.executeScript(
            res.arena,
            \\console.log('Multiline Script, using executeScript with a built-up payload');
            \\parent = document.querySelector('#execute-script-page');
            \\console.log(parent.outerHTML);
        ,
            .{ .attributes = attribs },
        ),
        3 => try datastar.executeScriptFmt(
            res.arena,
            "console.log('Using formatted print {d}');",
            .{sample},
            .{},
        ),
        else => try datastar.executeScriptFmt(
            res.arena,
            "console.log('Unknown SampleID {d}');",
            .{sample},
            .{},
        ),
    };
}

// ----- Long-lived streaming SSE -----
//
// `svgMorph`, `mathMorph`, and `hotreload` push many SSE events spaced over
// time. httpz exposes this through `startEventStreamSync` which keeps the
// handler alive, hands back the raw `Io.net.Stream`, and lets us drive the
// loop right here on the request thread. That means `res.arena` is still
// valid while we're streaming — no need to spawn a background thread or
// build a parallel allocator.
//
// For frame-by-frame allocations we use a small `FixedBufferAllocator` over
// a stack buffer and reset between frames, so total memory stays bounded
// even for the infinite hotreload loop.

fn svgMorph(req: *httpz.Request, res: *httpz.Response) !void {
    const opt = try readSignals(struct { svgMorph: usize = 1 }, req);
    const stream = try res.startEventStreamSync();
    defer stream.close(shared_io);

    var frame_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    for (0..opt.svgMorph) |_| {
        try emitSvgFrame(stream, &fba,
            \\<circle id="svg-circle" cx="{}" cy="{}" r="{}" class="fill-red-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 80),
        });
        try shared_io.sleep(.fromMilliseconds(100), .real);

        try emitSvgFrame(stream, &fba,
            \\<rect id="svg-square" x="{}" y="{}" width="{}" height="80" class="fill-green-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 80),
        });
        try shared_io.sleep(.fromMilliseconds(100), .real);

        try emitSvgFrame(stream, &fba,
            \\<polygon id="svg-triangle" points="{},{} {},{} {},{}" class="fill-blue-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
        });
        try shared_io.sleep(.fromMilliseconds(100), .real);
    }
}

fn emitSvgFrame(
    stream: Io.net.Stream,
    fba: *std.heap.FixedBufferAllocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    fba.reset();
    const block = try datastar.patchElementsFmt(fba.allocator(), fmt, args, .{ .namespace = .svg });
    try streamWriteAll(stream, shared_io, block);
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

fn mathMorph(req: *httpz.Request, res: *httpz.Response) !void {
    const opt = try readSignals(struct { mathmlMorph: usize = 1 }, req);

    if (opt.mathmlMorph == 1) {
        // Quick-fire single update — no streaming needed.
        beginSse(res);
        const a = try datastar.patchElementsFmt(
            res.arena,
            \\<mn id="math-factor" class="text-red-500 font-bold">{}</mn>
        ,
            .{prng.random().intRangeAtMost(u16, 2, 22)},
            .{ .namespace = .mathml, .view_transition = true },
        );
        const b = try datastar.patchSignals(res.arena, .{ .mathmlMorph = 1 }, .{});
        res.body = try std.mem.concat(res.arena, u8, &.{ a, b });
        return;
    }

    const stream = try res.startEventStreamSync();
    defer stream.close(shared_io);

    var frame_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    const delay_ms: u64 = switch (mathMLs.len - 3) {
        1, 2 => 2000,
        3 => 1600,
        4 => 1200,
        else => 200,
    };

    for (0..opt.mathmlMorph) |_| {
        fba.reset();
        const r = prng.random().intRangeAtMost(u8, 1, mathMLs.len);
        const block = try datastar.patchElements(
            fba.allocator(),
            mathMLs[r - 1],
            .{ .namespace = .mathml },
        );
        try streamWriteAll(stream, shared_io, block);
        try shared_io.sleep(.fromMilliseconds(delay_ms), .real);
    }

    fba.reset();
    const reset_block = try datastar.patchSignals(fba.allocator(), .{ .mathmlMorph = 1 }, .{});
    try streamWriteAll(stream, shared_io, reset_block);
}

fn code(req: *httpz.Request, res: *httpz.Response) !void {
    const snip = paramInt(u8, req, "snip") orelse 1;

    if (snip < 1 or snip > snippets.len) {
        std.log.warn("Invalid code snippet {}, range is 1-{}", .{ snip, snippets.len });
        return error.InvalidCodeSnippet;
    }

    const data = snippets[snip - 1];

    // Build the HTML payload up-front, then hand it to patchElements.
    var html: Io.Writer.Allocating = .init(res.arena);
    try html.writer.writeAll("<pre><code>");
    var it = std.mem.splitAny(u8, data, "\n");
    while (it.next()) |line| {
        try html.writer.writeAll("&nbsp;&nbsp;");
        for (line) |c| {
            switch (c) {
                '<' => try html.writer.writeAll("&lt;"),
                '>' => try html.writer.writeAll("&gt;"),
                ' ' => try html.writer.writeAll("&nbsp;"),
                else => try html.writer.writeByte(c),
            }
        }
        try html.writer.writeAll("\n");
    }
    try html.writer.writeAll("</code></pre>\n");

    const selector = try std.fmt.allocPrint(res.arena, "#code-{}", .{snip});

    beginSse(res);
    res.body = try datastar.patchElements(
        res.arena,
        html.written(),
        .{ .selector = selector, .mode = .append },
    );
}

fn mimeTest(req: *httpz.Request, res: *httpz.Response) !void {
    const filename = req.param("filename") orelse return error.NoFilename;
    const path = try std.fmt.allocPrint(res.arena, "examples/assets/mime-tests/{s}", .{filename});

    res.body = try Io.Dir.cwd().readFileAlloc(shared_io, path, res.arena, .limited(8 * 1024 * 1024));

    // Best-effort mime sniff by extension.
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".css")) {
        res.content_type = .CSS;
    } else if (std.mem.eql(u8, ext, ".js")) {
        res.content_type = .JS;
    } else if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) {
        res.content_type = .HTML;
    } else if (std.mem.eql(u8, ext, ".json")) {
        res.content_type = .JSON;
    } else {
        res.content_type = .BINARY;
    }
}

fn hotreload(req: *httpz.Request, res: *httpz.Response) !void {
    const id = paramInt(u64, req, "id") orelse 0;
    const stream = try res.startEventStreamSync();
    defer stream.close(shared_io);

    var frame_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    if (id != hotreload_id) {
        std.log.warn("Client is stale {} != {} - reload them", .{ id, hotreload_id });
        const block = try datastar.executeScript(fba.allocator(), "window.location.reload()", .{});
        try streamWriteAll(stream, shared_io, block);
        return;
    }

    // Stay connected with a one-minute keepalive ping. When the server is
    // restarted by `zig build`, the stream closes and the client reconnects
    // with the stale id, which trips the reload path above.
    var seconds: u64 = 0;
    while (true) {
        try shared_io.sleep(.fromMilliseconds(60_000), .real);
        seconds += 60;

        fba.reset();
        const ping = try std.fmt.allocPrint(
            fba.allocator(),
            \\<keepalive data-time="{}" />
        ,
            .{seconds},
        );
        const block = try datastar.patchElements(fba.allocator(), ping, .{});
        try streamWriteAll(stream, shared_io, block);
    }
}
