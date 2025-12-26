const std = @import("std");
const httpz = @import("httpz");
const logz = @import("logz");
const datastar = @import("datastar");
const Allocator = std.mem.Allocator;

const PORT = 7331;

// Run Datastar validation test suite backend in Zig
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{
        .port = PORT,
        .address = "0.0.0.0",
        .thread_pool = .{
            .count = 1,
            .backlog = 1,
            .buffer_size = 512,
        },
        .request = .{
            .buffer_size = 8196,
        },
    }, {});
    defer {
        // clean shutdown
        server.stop();
        server.deinit();
    }

    // initialize a logging pool
    try logz.setup(allocator, .{
        .level = .Info,
        .pool_size = 1,
        .buffer_size = 256,
        .large_buffer_count = 1,
        .large_buffer_size = 512,
        .output = .stdout,
        .encoding = .logfmt,
    });
    defer logz.deinit();

    var router = try server.router(.{});

    router.get("/", index, .{});
    router.get("/test", runTest, .{}); // get will use the query params
    router.post("/test", runTest, .{}); // post will use the request body

    std.debug.print("Zig SDK Validation Test listening on http://localhost:{d}/\n", .{PORT});
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\See the docs at https://github.com/starfederation/datastar/blob/develop/sdk/tests/README.md
        \\to run the official Datastar SDK test validator against this test suite
    ;
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

fn runTest(req: *httpz.Request, res: *httpz.Response) !void {
    const t1 = std.time.microTimestamp();
    defer {
        const t2 = std.time.microTimestamp();
        logz.info()
            .string("event", "runTest")
            .string("method", req.method_string)
            .int("elapsed (μs)", t2 - t1)
            .log();
        std.debug.print("===========================================\n", .{});
    }

    // Debug the input packet
    switch (req.method) {
        .GET => {
            const query = try req.query();
            const params = query.get("datastar") orelse return error.MissingDatastarKey;
            std.debug.print("GET params:\n{s}\n", .{params});
        },
        .POST => {
            if (req.body_buffer) |payload| {
                std.debug.print("POST body:\n{s}\n", .{payload.data});
            } else {
                std.debug.print("Invalid POST with no body data\n", .{});
                res.status = 400;
                return;
            }
        },
        else => {
            std.debug.print("Invalid test HTTP method {s}\n", .{req.method_string});
            res.status = 400;
            return;
        },
    }

    // read the TestInput params
    const testInput = try datastar.readSignals(TestInput, req);
    // std.debug.print("Decoded TestInput: {any}\n", .{testInput});

    var sse = try datastar.NewSSE(req, res);
    defer sse.close(res);

    if (testInput.events.len < 1) {
        res.status = 400;
        std.debug.print("Empty Test Input\n", .{});
        return;
    }

    for (testInput.events) |event| {
        std.debug.print("Event {s}\n", .{event.type});

        if (std.mem.eql(u8, event.type, "patchElements")) {
            if (event.elements == null and event.selector == null) {
                res.status = 400;
                std.debug.print("PatchElements needs at least 1 of element, or selector\n", .{});
                return;
            }

            try sse.patchElements(event.elements orelse "", .{
                .mode = blk: {
                    if (event.mode) |mode| {
                        if (std.meta.stringToEnum(datastar.PatchMode, mode)) |parsed_mode| {
                            break :blk parsed_mode;
                        } else {
                            res.status = 400;
                            std.debug.print("Invalid patchElements mode '{s}'\n", .{mode});
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
                            res.status = 400;
                            std.debug.print("Invalid patchElements namespace '{s}'\n", .{ns});
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
                std.debug.print("    multiline signals raw string: {any}\n", .{signals});
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
                std.debug.print("    signals: {any}\n", .{signals});
                var it = signals.map.iterator();
                while (it.next()) |entry| {
                    std.debug.print("     {s}:{any}\n", .{
                        entry.key_ptr.*,
                        entry.value_ptr.*,
                    });
                }
                try sse.patchSignals(signals, .{}, .{
                    .only_if_missing = event.onlyIfMissing orelse false,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });
            } else {
                std.debug.print("    signals: null\n", .{});
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
                res.status = 400;
                std.debug.print("executeScript is missing the script param\n", .{});
                return;
            }
        }
    }
}
