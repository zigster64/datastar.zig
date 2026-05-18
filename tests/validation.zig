const std = @import("std");
const datastar = @import("datastar");
const options = @import("options");
const HTTPRequest = datastar.HTTPRequest;

const Allocator = std.mem.Allocator;
const Io = std.Io;

// Selected at build time via `-Dio=zio`.
const use_zio = options.io_mode == .zio;
const zio = if (use_zio) @import("zio") else void;

const PORT = 7331;

// Run Datastar validation test suite backend in Zig
pub fn main(init: std.process.Init) !void {
    const rt = if (use_zio) try zio.Runtime.init(init.gpa, .{ .executors = .auto }) else {};
    defer if (use_zio) rt.deinit();
    const io: Io = if (use_zio) rt.io() else init.io;

    if (use_zio) std.log.info("🌀 IO backend: zio (stackful coroutines)", .{}) else std.log.info("🧵 IO backend: std Io.Threaded", .{});

    var server = try datastar.HTTPServer.init(init, .{
        .port = PORT,
        .io = io,
        .watch = true,
    });
    defer server.deinit();

    {
        var r = server.router;
        r.get("/", index);
        r.get("/test", runTest); // get will use the query params
        r.post("/test", runTest); // post will use the request body
    }

    try server.run();
}

fn index(http: *HTTPRequest) !void {
    try http.html(
        \\See the docs at https://github.com/starfederation/datastar/blob/develop/sdk/tests/README.md
        \\to run the official Datastar SDK test validator against this test suite
    );
}

/// Data mapping for how test cases are passed in
const TestInput = struct {
    events: []TestEvent,
};

const TestEvent = struct {
    type: []const u8,
    eventId: ?[]const u8 = null,
    retryDuration: ?i64 = null,

    // patchElements options
    elements: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    useViewTransition: ?bool = null,
    namespace: ?[]const u8 = null,

    // patch Signals options
    signals: ?std.json.ArrayHashMap(std.json.Value) = null,
    @"signals-raw": ?[]const u8 = null,
    onlyIfMissing: ?bool = null,

    // executeScript options
    script: ?[]const u8 = null,
    attributes: ?TestEventAttribute = null,
    autoRemove: ?bool = null,
};

const TestEventAttribute = struct {
    type: []const u8,
    blocking: ?[]const u8 = null,
};

fn runTest(http: *HTTPRequest) !void {
    // Debug the input packet
    switch (http.method) {
        .GET, .POST => {},
        else => {
            std.debug.print("Invalid test HTTP method {t}\n", .{http.method});
            try http.req.respond("Invalid test HTTP method", .{ .status = .bad_request });
            return;
        },
    }

    // read the TestInput params
    const testInput = try http.readSignals(struct { events: []TestEvent });

    var sse = try http.NewSSE();
    defer sse.close();

    if (testInput.events.len < 1) {
        http.status = .bad_request;
        try http.req.respond("Empty Test Input", .{ .status = http.status });
        std.log.err("Empty Test Input\n", .{});
        return;
    }

    for (testInput.events) |event| {
        std.log.debug("Event {s}", .{event.type});

        if (std.mem.eql(u8, event.type, "patchElements")) {
            if (event.elements == null and event.selector == null) {
                http.status = .bad_request;
                try http.req.respond("PatchElements needs at least 1 of element or selector", .{ .status = http.status });
                std.log.err("PatchElements needs at least 1 of element, or selector\n", .{});
                return;
            }

            try sse.patchElements(event.elements orelse "", .{
                .mode = blk: {
                    if (event.mode) |mode| {
                        if (std.meta.stringToEnum(datastar.PatchMode, mode)) |parsed_mode| {
                            break :blk parsed_mode;
                        } else {
                            http.status = .bad_request;
                            try http.req.respond("Invalid PatchElements mode", .{ .status = http.status });
                            std.log.err("Invalid patchElements mode '{s}'\n", .{mode});
                            return;
                        }
                    }
                    break :blk .outer;
                },
                .selector = event.selector,
                .view_transition = if (event.useViewTransition) |vt| vt else false,
                .event_id = event.eventId,
                .retry_duration = event.retryDuration,
                .namespace = blk: {
                    if (event.namespace) |ns| {
                        if (std.meta.stringToEnum(datastar.NameSpace, ns)) |parsed_namespace| {
                            break :blk parsed_namespace;
                        } else {
                            http.status = .bad_request;
                            try http.req.respond("Invalid PatchElements namespace", .{ .status = http.status });
                            std.log.err("Invalid patchElements namespace '{s}'\n", .{ns});
                            return;
                        }
                    }
                    break :blk .html;
                },
            });
        }

        if (std.mem.eql(u8, event.type, "patchSignals")) {
            // check if multiline signals are present first !!
            if (event.@"signals-raw") |signals| {
                std.log.debug("    multiline signals raw string: {s}", .{signals});
                var w = sse.patchSignalsWriter(.{
                    .only_if_missing = event.onlyIfMissing orelse false,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });

                var escape: bool = false;
                for (signals) |ch| {
                    switch (ch) {
                        else => {
                            if (escape) {
                                switch (ch) {
                                    else => try w.writeByte(ch),
                                    'n' => try w.writeAll("\n"),
                                }
                                escape = false;
                            } else {
                                try w.writeByte(ch);
                            }
                        },
                        '\\' => escape = true,
                    }
                }

                return;
            }

            // Check if the 'signals' field was present and parsed
            if (event.signals) |signals| {
                try sse.patchSignals(signals, .{}, .{
                    .only_if_missing = event.onlyIfMissing orelse false,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });
            } else {
                std.log.debug("    signals: null", .{});
            }
        }

        if (std.mem.eql(u8, event.type, "executeScript")) {
            if (event.script) |script| {
                try sse.executeScript(script, .{
                    .auto_remove = event.autoRemove orelse true,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });
            } else {
                http.status = .bad_request;
                try http.req.respond("executeScript is missing the script param", .{ .status = http.status });
                std.log.err("executeScript is missing the script param\n", .{});
                return;
            }
        }
    }
}
