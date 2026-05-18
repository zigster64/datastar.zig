# datastar.zig

A Zig 0.16 SDK for [Datastar](https://data-star.dev) — patch DOM elements, patch signals, and execute scripts on the browser from your backend over SSE.

![Cyberpunk Datastar Zig SDK - Sydney Metro Rail - Leica XV](assets/datastar.zig.jpg)

- Conforms to the [Datastar SDK ADR](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md) and passes the official validation suite.
- Bundles a small but fast HTTP server built on `std.http`, with tight Datastar/SSE integration.
- `patchElements` / `patchSignals` / `executeScript` with raw, `Fmt`, and `Writer` variants.
- HTML, SVG, and MathML namespace morphing.
- Optional in-process pub/sub bus (via sibling [`pubsub.zig`](https://github.com/zigster64/pubsub.zig)) for multi-player apps.

For stable Zig 0.15.2, see [`datastar.http.zig`](https://github.com/zigster64/datastar.http.zig).

## Zig Version

Requires Zig **0.16.0** or newer. Tracks the `0.16.0` release.

## Two libraries in one (for now)

This repo currently bundles two things that will likely be split into separate repos:

1. **A Datastar SDK** — a small set of generic functions for emitting SSE events that any HTTP server can use (`http.zig`, `zap`, `jetzig`, `tokamak`, the stdlib server, etc).
2. **A Datastar-aware HTTP server** — a complete framework built on `std.http` with a fast radix-tree router and tightly-integrated SSE helpers.

The HTTP server is the mature half. The generic SDK functions cover the full Datastar wire protocol — see [Generic SDK functions](#generic-sdk-functions).

## Example

```zig
const std = @import("std");
const datastar = @import("datastar");
const HTTPServer = datastar.HTTPServer;
const HTTPRequest = datastar.HTTPRequest;

pub fn main(process_init: std.process.Init) !void {
    var server = try HTTPServer.init(process_init, .{ .port = 8080 });
    defer server.deinit();

    const r = server.router;
    r.get("/", index);
    r.get("/sse/:id", sseEndpoint);

    try server.run();
}

fn index(http: *HTTPRequest) !void {
    return http.html(
        \\<!DOCTYPE html>
        \\<head>
        \\  <script type="module"
        \\    src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.1/bundles/datastar.js">
        \\  </script>
        \\</head>
        \\<body data-init="@get('/sse/zig')">
        \\  <div id="hello">Loading ...</div>
        \\  <div>Foo <span data-text="$foo"></span></div>
        \\  <pre data-json-signals></pre>
        \\</body>
    );
}

fn sseEndpoint(http: *HTTPRequest) !void {
    const id = http.params.get("id") orelse return error.NoID;

    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements("<div id='hello'>Hello World</div>", .{});
    try sse.patchSignals(.{ .foo = 42, .bar = "Datastar Rocks" }, .{}, .{});
    try sse.executeScriptFmt("alert('All your base are belong to {s}')", .{id}, .{});
}
```

See `examples/01_basic.zig` for a complete kitchen-sink demo, and `TUTORIAL.md` for a deeper walkthrough.

## Table of Contents

- [Installation](#installation)
- [Build, Run, Test](#build-run-test)
- [Function Summary](#function-summary)
  - [HTTPServer](#httpserver)
  - [HTTPRequest](#httprequest)
  - [SSE](#sse)
  - [Generic SDK functions](#generic-sdk-functions)
- [Roadmap](#roadmap)
- [More on Datastar](#more-on-datastar)

## Installation

Add the dependency:

```bash
zig fetch --save="datastar" "git+https://github.com/zigster64/datastar.zig"
```

Wire it into `build.zig`:

```zig
const datastar = b.dependency("datastar", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("datastar", datastar.module("datastar"));
```

Import in your application code:

```zig
const datastar = @import("datastar");
```

## Build, Run, Test

```bash
zig build                       # build everything into zig-out/bin
zig build test                  # run unit tests
zig build example_1             # run the kitchen-sink demo on :8081
zig build http.zig              # build the http.zig port of example_1 (opt-in)
zig build dusty                 # build the dusty port of example_1 (opt-in)
./zig-out/bin/validation-test   # serve the Datastar SDK conformance suite on :7331
```

Example binaries produced by `zig build`:

| Binary               | Description                                                       |
| -------------------- | ----------------------------------------------------------------- |
| `example_1`          | Kitchen-sink demo of every SDK function with live "show code"     |
| `example_2`          | Realtime cat auction with multi-window bid updates                |
| `example_3`          | WildCat auction with per-session preferences                      |
| `example_5`          | Multi-player farming sim                                          |
| `validation-test`    | Server for the official Datastar SDK validation suite             |

### Reference ports to other HTTP frameworks

The same kitchen-sink demo is also wired up to two third-party HTTP frameworks, using only the generic `datastar.patchElements` / `patchSignals` / `executeScript` transformer functions. They double as the canonical reference for plugging the Datastar SDK into any framework.

| Target            | Output binary           | Framework                                                                | Source                              |
| ----------------- | ----------------------- | ------------------------------------------------------------------------ | ----------------------------------- |
| `zig build http.zig` | `example_1_httpz`    | [`karlseguin/http.zig`](https://github.com/karlseguin/http.zig)          | `examples/01_basic_httpz.zig`       |
| `zig build dusty` | `example_1_dusty`       | [`lalinsky/dusty`](https://github.com/lalinsky/dusty)                    | `examples/01_basic_dusty.zig`       |

Both run on the same `:8081` port and serve the same UI as `example_1` — the navbar shows which web server is driving the page.

## Function Summary

For full prose and longer examples, see `TUTORIAL.md`.

### HTTPServer

```zig
HTTPServer.init(process_init, config) !*HTTPServer
server.run()                          // start serving
server.deinit()                       // shutdown
server.useCtx(ptr)                    // attach a global context for handlers
server.concurrent(fn, args)           // spawn a task in the server's group
server.rebooter(process_init)         // restart on executable change (dev mode)

// Router
const r = server.router;
r.get(path, handler)
r.post(path, handler)
r.patch(path, handler)
r.delete(path, handler)
r.add(method, path, handler)
// Path params: r.get("/users/:id/:action", handler)
```

Server config (see `Config` in `src/server.zig`):

```zig
.{
    .port            = 8080,
    .address         = null,           // null = listen on all addresses
    .threads         = num_cpus,       // short-lived request pool
    .sse_threads     = N,              // long-lived SSE pool
    .public_sse_threads = N,           // separate pool for untrusted SSE clients
    .fd_limit        = .max,           // or .limited(n), or null
    .watch           = false,          // reboot on executable change
}
```

### HTTPRequest

Every handler receives `*HTTPRequest`:

```zig
// State
http.req                              // underlying *std.http.Server.Request
http.arena                            // per-request arena allocator
http.params                           // route params
http.method, http.path                // request method and path

// Responses
http.data(content, mime_type) !void
http.html(content) !void
http.htmlFmt(fmt, args) !void
http.json(value) !void
http.css(content) !void
http.cssFmt(fmt, args) !void
http.js(content) !void
http.jsFmt(fmt, args) !void
http.sendFile(filename, ?mime_type) !void

// Signals / cookies / params
http.readSignals(T) !T                // populate T from GET query or POST body
http.params.get(name) ?[]const u8
http.params.getInt(T, name) ?T
http.setCookie(name, value)
http.getCookie(name) ?[]const u8
http.query() ?[]const u8

// SSE entry points
http.NewSSE() !SSE                    // batched (default)
http.NewSSESync() !SSE                // sync writes per call
http.NewSSEOpt(SSEOptions) !SSE       // custom buffer / headers
```

### SSE

```zig
// Lifecycle
sse.close()                           // finalize and write the response
sse.flush()                           // for long-lived sync streams
sse.keepalive() !void                 // ping to keep the connection tracked

// Patch DOM elements
sse.patchElements(html, opts) !void
sse.patchElementsFmt(comptime fmt, args, opts) !void
sse.patchElementsWriter(opts) *std.Io.Writer

// Patch signals
sse.patchSignals(value, json_opts, opts) !void
sse.patchSignalsWriter(opts) *std.Io.Writer

// Execute scripts
sse.executeScript(script, opts) !void
sse.executeScriptFmt(comptime fmt, args, opts) !void
sse.executeScriptWriter(opts) *std.Io.Writer
```

Options:

```zig
PatchElementsOptions { mode, selector, view_transition, event_id, retry_duration, namespace }
PatchSignalsOptions  { only_if_missing, event_id, retry_duration }
ExecuteScriptOptions { auto_remove, attributes, event_id, retry_duration }

PatchMode = .inner | .outer | .replace | .prepend | .append | .before | .after | .remove
NameSpace = .html | .svg | .mathml
```

`.{}` is almost always the right value for the options argument.

### Generic SDK functions

Plain transformer functions for use with any HTTP framework — stdlib, [`http.zig`](https://github.com/karlseguin/http.zig), `zap`, `jetzig`, `tokamak`, or whatever else. They take an arena allocator and a payload, and return a freshly-allocated string containing the full SSE event-stream block. You write that string into whatever response body your framework exposes — no further wrapping required.

```zig
// Read signals from either a GET query string or a POST body
datastar.readSignals(comptime T: type, arena: Allocator, req: *std.http.Server.Request) !T

// Patch DOM elements
datastar.patchElements(arena, html, opts) ![]const u8
datastar.patchElementsFmt(arena, comptime fmt, args, opts) ![]const u8

// Patch signals (any JSON-serializable value)
datastar.patchSignals(arena, value, opts) ![]const u8

// Execute a script on the client (wraps the script in a <script> tag and patches it into body)
datastar.executeScript(arena, script, opts) ![]const u8
datastar.executeScriptFmt(arena, comptime fmt, args, opts) ![]const u8
```

Example wiring into another framework:

```zig
const body = try datastar.patchElements(req.arena, "<div id='hello'>Hi</div>", .{});
res.header("Content-Type", "text/event-stream");
try res.write(body);
```

`readSignals` currently expects a `*std.http.Server.Request`. If your framework hides the underlying request, parse the signals JSON yourself — Datastar passes them either as `?datastar=<url-encoded-json>` on a GET, or as the raw JSON body on POST/PUT/PATCH/DELETE:

```zig
const Signals = struct { foo: u32, bar: []const u8 };

fn readSignalsAnyFramework(
    arena: Allocator,
    method: std.http.Method,
    query_string: ?[]const u8, // everything after the '?' in the URL, or null
    body: ?[]const u8,         // request body bytes, or null
) !Signals {
    const json = switch (method) {
        .GET => blk: {
            const qs = query_string orelse return error.MissingDatastarKey;
            var it = std.mem.tokenizeScalar(u8, qs, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "datastar=")) {
                    break :blk try datastar.urlDecode(arena, pair["datastar=".len..]);
                }
            }
            return error.MissingDatastarKey;
        },
        else => body orelse return error.MissingBody,
    };

    return std.json.parseFromSliceLeaky(
        Signals,
        arena,
        json,
        .{ .ignore_unknown_fields = true },
    );
}
```

`datastar.urlDecode` is re-exported for exactly this case.

## Roadmap

- **Split the repo in two.** Extract the generic SDK functions into a dedicated `datastar-sdk-zig` repo so it can be used with any HTTP framework and added to the Datastar official repo. The HTTP server stays here under its own name.
- **`Io.Evented` migration.** Examples currently use `Io.Threaded`. Work on Evented / Io-Uring / Kqueue / GrandCentralDispatch - ongoing in the 0.17 branch in this repo.

## More on Datastar

- [data-star.dev](https://data-star.dev) — official site and reference
- [Datastar SDK ADR](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md)
- [Datastar Discord](https://discord.gg/YfFn7pKx)
- [Zig Discord](https://discord.gg/Chk5WKM5)

## Contributing

PRs welcome. Please open an issue first to discuss non-trivial changes, and reference the issue in the PR title.
