// 01_basic_dusty.zig — the kitchen-sink example, ported to lalinsky/dusty.
//
// Same demo as examples/01_basic.zig but driven by Dusty's coroutine HTTP
// server. All Datastar SSE payloads are built with the framework-agnostic
// transformer functions:
//
//     datastar.patchElements(arena, html, opts)         ![]const u8
//     datastar.patchElementsFmt(arena, fmt, args, opts) ![]const u8
//     datastar.patchSignals(arena, value, opts)         ![]const u8
//     datastar.executeScript(arena, script, opts)       ![]const u8
//     datastar.executeScriptFmt(arena, fmt, args, opts) ![]const u8
//
// Each one returns a full `event: ...\ndata: ...\n\n` block ready to write to
// any response body or stream as `Content-Type: text/event-stream`.
//
// Build with:  zig build dusty
// Run with:    ./zig-out/bin/example_1_dusty

const std = @import("std");
const dusty = @import("dusty");
const datastar = @import("datastar");
const Allocator = std.mem.Allocator;
const Io = std.Io;

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

fn setHotReload(io: Io) void {
    const ts = Io.Clock.now(.real, io);
    const seed_u96: u96 = @bitCast(ts.nanoseconds);
    prng.seed(@truncate(seed_u96));
    hotreload_id = prng.random().int(u64);
    std.log.debug("Hotreload ID {}", .{hotreload_id});
}

pub fn main(init: std.process.Init) !void {
    setHotReload(init.io);

    const allocator = init.gpa;

    var server = dusty.Server(void).init(allocator, init.io, .{}, {});
    defer server.deinit();

    const r = &server.router;
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

    r.post("/hotreload/:id", hotreload);

    std.log.info("Server listening on http://localhost:{}", .{PORT});
    try server.listen(.{ .ip = .{ .ip4 = .loopback(PORT) } });
}

// ----- Helpers -----

// Read Datastar signals out of any dusty.Request — GET pulls them from the
// `datastar` query param, POST/PUT/PATCH/DELETE pulls them from the body.
fn readSignals(comptime T: type, req: *dusty.Request) !T {
    const arena = req.arena;
    const json_text: []const u8 = switch (req.method) {
        .get => req.query.get("datastar") orelse return error.MissingDatastarKey,
        else => (try req.body()) orelse return error.MissingBody,
    };
    return std.json.parseFromSliceLeaky(
        T,
        arena,
        json_text,
        .{ .ignore_unknown_fields = true },
    );
}

// Dusty's `Response.content_type` enum has no `.events` variant, so we set the
// header explicitly when the response is a Datastar SSE batch.
fn beginSseBatch(res: *dusty.Response) !void {
    try res.header("Content-Type", "text/event-stream");
    try res.header("Cache-Control", "no-cache");
}

fn paramInt(comptime T: type, req: *dusty.Request, name: []const u8) ?T {
    const raw = req.params.get(name) orelse return null;
    return std.fmt.parseInt(T, raw, 10) catch null;
}

// ----- Handlers -----

fn index(req: *dusty.Request, res: *dusty.Response) !void {
    res.content_type = .html;
    res.body = try std.fmt.allocPrint(
        req.arena,
        @embedFile("01_index.html"),
        .{
            .hotreload_id = hotreload_id,
            .web_server = "Dusty Web Server",
        },
    );
}

fn styleCss(_: *dusty.Request, res: *dusty.Response) !void {
    res.content_type = .css;
    res.body = @embedFile("style.css");
}

fn textHtml(req: *dusty.Request, res: *dusty.Response) !void {
    res.content_type = .html;
    res.body = try std.fmt.allocPrint(req.arena,
        \\<p id="text-html">This is update number {d}</p>
    , .{try getCountAndIncrement(req.io)});
}

fn patchElements(req: *dusty.Request, res: *dusty.Response) !void {
    try beginSseBatch(res);
    try res.header("X-SSE-More-Headers", "Patch Elements Example");
    try res.header("X-SSE-Even-More-Headers", "All the Headers");

    res.body = try datastar.patchElementsFmt(
        req.arena,
        \\<p id="mf-patch">This is update number {d}</p>
    ,
        .{try getCountAndIncrement(req.io)},
        .{},
    );
}

fn patchElementsOpts(req: *dusty.Request, res: *dusty.Response) !void {
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

    try beginSseBatch(res);
    res.body = switch (patch_mode) {
        .replace => try datastar.patchElements(
            req.arena,
            \\<p id="mf-patch-opts" class="border-4 border-error">Complete Replacement of the OUTER HTML</p>
        ,
            opts,
        ),
        else => try datastar.patchElementsFmt(
            req.arena,
            \\<p>This is update number {d}</p>
        ,
            .{try getCountAndIncrement(req.io)},
            opts,
        ),
    };
}

fn patchElementsOptsReset(req: *dusty.Request, res: *dusty.Response) !void {
    try beginSseBatch(res);
    res.body = try datastar.patchElements(req.arena, @embedFile("01_index_opts.html"), .{});
}

fn jsonSignals(_: *dusty.Request, res: *dusty.Response) !void {
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);
    try res.json(.{ .fooj = foo, .barj = bar }, .{});
}

fn patchSignals(req: *dusty.Request, res: *dusty.Response) !void {
    try beginSseBatch(res);
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);
    res.body = try datastar.patchSignals(req.arena, .{ .foo = foo, .bar = bar }, .{});
}

fn patchSignalsOnlyIfMissing(req: *dusty.Request, res: *dusty.Response) !void {
    try beginSseBatch(res);
    const foo = prng.random().intRangeAtMost(u8, 1, 100);
    const bar = prng.random().intRangeAtMost(u8, 1, 100);

    const signals_block = try datastar.patchSignals(
        req.arena,
        .{ .newfoo = foo, .newbar = bar },
        .{ .only_if_missing = true },
    );
    const script_block = try datastar.executeScript(
        req.arena,
        "console.log('Patched newfoo and newbar, but only if missing');",
        .{},
    );
    res.body = try std.mem.concat(req.arena, u8, &.{ signals_block, script_block });
}

fn patchSignalsRemove(req: *dusty.Request, res: *dusty.Response) !void {
    const signals_to_remove = req.params.get("names") orelse return error.InvalidSignalName;

    var json_buf: Io.Writer.Allocating = .init(req.arena);
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
        req.arena,
        json_buf.written(),
        .{},
    );

    try beginSseBatch(res);
    res.body = try datastar.patchSignals(req.arena, parsed, .{});
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

fn executeScript(req: *dusty.Request, res: *dusty.Response) !void {
    const sample = paramInt(u8, req, "sample") orelse 0;

    var attribs = datastar.ScriptAttributes.init(req.arena);
    try attribs.put("type", "text/javascript");
    try attribs.put("trace", "true");
    try attribs.put("aardvark", "should appear last, not first");

    try beginSseBatch(res);
    res.body = switch (sample) {
        1 => try datastar.executeScript(
            req.arena,
            "console.log('Running from executeScript() directly');",
            .{},
        ),
        2 => try datastar.executeScript(
            req.arena,
            \\console.log('Multiline Script, using executeScript with a built-up payload');
            \\parent = document.querySelector('#execute-script-page');
            \\console.log(parent.outerHTML);
        ,
            .{ .attributes = attribs },
        ),
        3 => try datastar.executeScriptFmt(
            req.arena,
            "console.log('Using formatted print {d}');",
            .{sample},
            .{},
        ),
        else => try datastar.executeScriptFmt(
            req.arena,
            "console.log('Unknown SampleID {d}');",
            .{sample},
            .{},
        ),
    };
}

// ----- Long-lived streaming SSE -----
//
// `svgMorph`, `mathMorph`, and `hotreload` push many SSE events spaced over
// time. Dusty exposes streaming via `res.startEventStream()` which writes the
// SSE headers and returns an `EventStream` wrapping the underlying writer.
// Its `send()` helper only accepts single-line payloads, so we bypass it and
// write our pre-formatted Datastar SSE blocks directly to `stream.conn` —
// each block is already a fully-formed `event: ...\ndata: ...\n\n` chunk.
//
// The handler stays running for the whole stream, so `req.arena` is valid
// throughout. We allocate each frame's SSE block on a `FixedBufferAllocator`
// over a stack buffer and reset between frames to keep memory bounded.

fn writeBlock(conn: *Io.Writer, block: []const u8) !void {
    try conn.writeAll(block);
    try conn.flush();
}

fn svgMorph(req: *dusty.Request, res: *dusty.Response) !void {
    const opt = try readSignals(struct { svgMorph: usize = 1 }, req);
    const stream = try res.startEventStream();

    var frame_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    for (0..opt.svgMorph) |_| {
        try emitSvgFrame(stream.conn, &fba,
            \\<circle id="svg-circle" cx="{}" cy="{}" r="{}" class="fill-red-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 80),
        });
        try req.io.sleep(.fromMilliseconds(100), .real);

        try emitSvgFrame(stream.conn, &fba,
            \\<rect id="svg-square" x="{}" y="{}" width="{}" height="80" class="fill-green-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 80),
        });
        try req.io.sleep(.fromMilliseconds(100), .real);

        try emitSvgFrame(stream.conn, &fba,
            \\<polygon id="svg-triangle" points="{},{} {},{} {},{}" class="fill-blue-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
        });
        try req.io.sleep(.fromMilliseconds(100), .real);
    }
}

fn emitSvgFrame(
    conn: *Io.Writer,
    fba: *std.heap.FixedBufferAllocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    fba.reset();
    const block = try datastar.patchElementsFmt(fba.allocator(), fmt, args, .{ .namespace = .svg });
    try writeBlock(conn, block);
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

fn mathMorph(req: *dusty.Request, res: *dusty.Response) !void {
    const opt = try readSignals(struct { mathmlMorph: usize = 1 }, req);

    if (opt.mathmlMorph == 1) {
        try beginSseBatch(res);
        const a = try datastar.patchElementsFmt(
            req.arena,
            \\<mn id="math-factor" class="text-red-500 font-bold">{}</mn>
        ,
            .{prng.random().intRangeAtMost(u16, 2, 22)},
            .{ .namespace = .mathml, .view_transition = true },
        );
        const b = try datastar.patchSignals(req.arena, .{ .mathmlMorph = 1 }, .{});
        res.body = try std.mem.concat(req.arena, u8, &.{ a, b });
        return;
    }

    const stream = try res.startEventStream();
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
        try writeBlock(stream.conn, block);
        try req.io.sleep(.fromMilliseconds(delay_ms), .real);
    }

    fba.reset();
    const reset_block = try datastar.patchSignals(fba.allocator(), .{ .mathmlMorph = 1 }, .{});
    try writeBlock(stream.conn, reset_block);
}

fn code(req: *dusty.Request, res: *dusty.Response) !void {
    const snip = paramInt(u8, req, "snip") orelse 1;

    if (snip < 1 or snip > snippets.len) {
        std.log.warn("Invalid code snippet {}, range is 1-{}", .{ snip, snippets.len });
        return error.InvalidCodeSnippet;
    }

    const data = snippets[snip - 1];

    var html: Io.Writer.Allocating = .init(req.arena);
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

    const selector = try std.fmt.allocPrint(req.arena, "#code-{}", .{snip});

    try beginSseBatch(res);
    res.body = try datastar.patchElements(
        req.arena,
        html.written(),
        .{ .selector = selector, .mode = .append },
    );
}

fn mimeTest(req: *dusty.Request, res: *dusty.Response) !void {
    const filename = req.params.get("filename") orelse return error.NoFilename;
    const path = try std.fmt.allocPrint(req.arena, "examples/assets/mime-tests/{s}", .{filename});

    res.body = try Io.Dir.cwd().readFileAlloc(req.io, path, req.arena, .limited(8 * 1024 * 1024));

    const ext = std.fs.path.extension(filename);
    res.content_type = if (std.mem.eql(u8, ext, ".css"))
        .css
    else if (std.mem.eql(u8, ext, ".js"))
        .js
    else if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm"))
        .html
    else if (std.mem.eql(u8, ext, ".json"))
        .json
    else
        .unknown;
}

fn hotreload(req: *dusty.Request, res: *dusty.Response) !void {
    const id = paramInt(u64, req, "id") orelse 0;
    const stream = try res.startEventStream();

    var frame_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    if (id != hotreload_id) {
        std.log.warn("Client is stale {} != {} - reload them", .{ id, hotreload_id });
        const block = try datastar.executeScript(fba.allocator(), "window.location.reload()", .{});
        try writeBlock(stream.conn, block);
        return;
    }

    // Stay connected with a one-minute keepalive ping. When the server is
    // restarted by `zig build`, the stream closes and the client reconnects
    // with the stale id, which trips the reload path above.
    var seconds: u64 = 0;
    while (true) {
        try req.io.sleep(.fromMilliseconds(60_000), .real);
        seconds += 60;

        fba.reset();
        const ping = try std.fmt.allocPrint(
            fba.allocator(),
            \\<keepalive data-time="{}" />
        ,
            .{seconds},
        );
        const block = try datastar.patchElements(fba.allocator(), ping, .{});
        try writeBlock(stream.conn, block);
    }
}
