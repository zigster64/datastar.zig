# datastar.zig - ZIO branch

A Zig 0.16 SDK for [Datastar](https://data-star.dev) — patch DOM elements, patch signals, and execute scripts on the browser from your backend over SSE.

This branch adds an **opt-in `-Dio=zio` build flag** for the examples that swaps the stdlib `Io.Threaded` implementation for [`lalinsky/zio`](https://github.com/lalinsky/zio) — stackful coroutines instead of OS threads. See [Selecting the IO backend](#selecting-the-io-backend).

Background reading: https://lalinsky.com/2026/05/11/async-io-in-zig-016-today.html

![Cyberpunk Datastar Zig SDK - Sydney Metro Rail - Leica XV](assets/datastar.zig.jpg)

- **Tiny framework surface.** Four functions — `readSignals`, `patchElements`, `patchSignals`, `executeScript` — that take an arena allocator and return ready-to-ship SSE strings. Drop them into the stdlib HTTP server, [`http.zig`](https://github.com/karlseguin/http.zig), [`dusty`](https://github.com/lalinsky/dusty), `zap`, `jetzig`, `tokamak`, or whatever else.
- **Full Datastar wire protocol.** Raw + `Fmt` variants, HTML / SVG / MathML namespaces, `view_transition`, `only_if_missing`, custom script attributes, event IDs, retry duration — everything from the [Datastar SDK ADR](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md).
- **Passes the official Datastar validation suite.**
- **Includes a bundled Datastar-aware HTTP server** if you don't already have a framework — fast radix-tree router, batched + sync SSE, hot reload — see [Bundled HTTP server](#bundled-http-server).
- **Bundled in-process pub/sub** via [`pubsub.zig`](https://github.com/zigster64/pubsub.zig) — enough to do CQRS in a single binary, with a clean off-ramp to NATS / Redis / Postgres listen-notify when you outgrow it. See [Pub/Sub and CQRS](#pubsub-and-cqrs).

For stable Zig 0.15.2, see [`datastar.http.zig`](https://github.com/zigster64/datastar.http.zig).

## Zig Version

Requires Zig **0.16.0** or newer. Tracks the `0.16.0` release.


## Table of Contents

- [Quick Example](#quick-example)
- [Installation](#installation)
- [The SDK Functions](#the-sdk-functions)
- [Plug it into your framework](#plug-it-into-your-framework)
- [Build, Run, Test](#build-run-test)
- [Bundled HTTP server](#bundled-http-server)
- [Pub/Sub and CQRS](#pubsub-and-cqrs)
- [Roadmap](#roadmap)
- [More on Datastar](#more-on-datastar)

## Quick Example

The SDK is just four functions. Each transformer returns a complete `event: ...\ndata: ...\n\n` SSE block — concatenate as many as you want and write them as the response body with `Content-Type: text/event-stream`:

```zig
const datastar = @import("datastar");

// Inside an SSE handler, with `req.arena` and a `res` from your framework:

// 1. Patch DOM elements
const a = try datastar.patchElements(req.arena, "<div id='hello'>Hi</div>", .{});

// 2. Patch signals (any JSON-serializable value)
const b = try datastar.patchSignals(req.arena, .{ .foo = 42, .bar = "Datastar Rocks" }, .{});

// 3. Run a script on the client
const c = try datastar.executeScriptFmt(req.arena, "alert('hello {s}')", .{name}, .{});

res.header("Content-Type", "text/event-stream");
res.body = try std.mem.concat(req.arena, u8, &.{ a, b, c });

// And to read Datastar signals on the way in:
const Signals = struct { name: []const u8, count: u32 };
const signals = try datastar.readSignals(Signals, req.arena, req);
```

Full working examples in `examples/01_basic_httpz.zig` (port to [`http.zig`](https://github.com/karlseguin/http.zig)) and `examples/01_basic_dusty.zig` (port to [`dusty`](https://github.com/lalinsky/dusty)).

## Installation

```bash
zig fetch --save="datastar" "git+https://github.com/zigster64/datastar.zig"
```

Wire into `build.zig`:

```zig
const datastar = b.dependency("datastar", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("datastar", datastar.module("datastar"));
```

Import:

```zig
const datastar = @import("datastar");
```

## The SDK Functions

The whole SDK framework is just :

```zig
// Read Datastar signals from a request — GET pulls them from the
// `datastar` query param, POST/PUT/PATCH/DELETE from the body.
datastar.readSignals(comptime T: type, arena: Allocator, req: *std.http.Server.Request) !T

// Patch DOM elements
datastar.patchElements(arena, html, opts) ![]const u8
datastar.patchElementsFmt(arena, comptime fmt, args, opts) ![]const u8

// Patch signals (any JSON-serializable value)
datastar.patchSignals(arena, value, opts) ![]const u8

// Execute a script on the client (wraps the script in a <script> tag and patches it into body)
datastar.executeScript(arena, script, opts) ![]const u8
datastar.executeScriptFmt(arena, comptime fmt, args, opts) ![]const u8

// Helper — re-exported for framework adapters
datastar.urlDecode(allocator, input) ![]u8
```

These functions take an input string, and return a new string in the correct format needed to post over SSE.

Simple.

Options:

```zig
PatchElementsOptions { mode, selector, view_transition, event_id, retry_duration, namespace }
PatchSignalsOptions  { only_if_missing, event_id, retry_duration }
ExecuteScriptOptions { auto_remove, attributes, event_id, retry_duration }

PatchMode = .inner | .outer | .replace | .prepend | .append | .before | .after | .remove
NameSpace = .html | .svg | .mathml
```

`.{}` is almost always the right value for the options argument. See `src/datastar.zig` for the full option fields and defaults.

## Plug it into your framework

Wiring is two lines per response: set `Content-Type: text/event-stream`, then write the bytes returned by the transformer:

```zig
fn myHandler(req: *anyframework.Request, res: *anyframework.Response) !void {
    const body = try datastar.patchElements(req.arena, "<div id='x'>hi</div>", .{});
    try res.header("Content-Type", "text/event-stream");
    res.body = body;
}
```

For long-lived streaming (animations, multi-frame morphs, keepalive pings), grab the raw stream from your framework and write blocks as you produce them. The `examples/01_basic_httpz.zig` and `examples/01_basic_dusty.zig` files show the pattern end-to-end for two different frameworks.

### `readSignals` in frameworks that hide the underlying request

`datastar.readSignals` currently expects a `*std.http.Server.Request`. If your framework wraps the request, parse the signals JSON yourself — they arrive as `?datastar=<url-encoded-json>` on a GET, or as the raw JSON body on POST/PUT/PATCH/DELETE:

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

The same kitchen-sink demo is also wired up to two third-party HTTP frameworks, using only the generic transformer functions. They double as the canonical reference for plugging the Datastar SDK into any framework.

| Target               | Output binary       | Framework                                                       | Source                          |
| -------------------- | ------------------- | --------------------------------------------------------------- | ------------------------------- |
| `zig build http.zig` | `example_1_httpz`   | [`karlseguin/http.zig`](https://github.com/karlseguin/http.zig) | `examples/01_basic_httpz.zig`   |
| `zig build dusty`    | `example_1_dusty`   | [`lalinsky/dusty`](https://github.com/lalinsky/dusty)           | `examples/01_basic_dusty.zig`   |

Both run on the same `:8081` port and serve the same UI as `example_1` — the navbar shows which web server is driving the page.

### Selecting the IO backend

The example programs accept a `-Dio=` build flag that picks the `std.Io` implementation used at runtime:

```bash
zig build example_1              # default: -Dio=std  (stdlib Io.Threaded)
zig build example_1 -Dio=zio     # use lalinsky/zio (stackful coroutines)
```

| Flag        | Backend                | Notes                                                                  |
| ----------- | ---------------------- | ---------------------------------------------------------------------- |
| `-Dio=std`  | `std.Io.Threaded`      | Default. Handlers run on OS threads — no extra deps in the binary.     |
| `-Dio=zio`  | [`zio`](https://github.com/lalinsky/zio) `Runtime` | Spawns a zio runtime in `main` and hands its `std.Io` to the server, so handler IO suspends on coroutines rather than blocking threads. |

On startup the example logs which backend it's using:

```
info: 🧵 IO backend: std Io.Threaded            # default
info: 🌀 IO backend: zio (stackful coroutines)  # -Dio=zio
```

How it's wired:

- `build.zig` exposes the flag via `b.option(IoMode, "io", ...)` and, when `-Dio=zio` is set, adds the `zio` module to every example.
- Only `examples/01_basic.zig` currently *uses* the option — the other examples pick up the module so they're ready to be ported. The relevant snippet from `01_basic.zig`:

  ```zig
  const use_zio = options.io_mode == .zio;
  const zio = if (use_zio) @import("zio") else void;

  pub fn main(init: std.process.Init) !void {
      const rt = if (use_zio) try zio.Runtime.init(init.gpa, .{}) else {};
      defer if (use_zio) rt.deinit();
      const io: std.Io = if (use_zio) rt.io() else init.io;

      var server = try datastar.HTTPServer.init(init, .{ .port = 8081, .io = io, ... });
      ...
  }
  ```

  The `if (use_zio) @import("zio") else void` pattern keeps the `zio` import behind a comptime branch, so the `-Dio=std` build doesn't need the `zio` module at all.

## Bundled HTTP server

If you don't already have an HTTP framework picked out, this repo also ships **a complete Datastar-aware HTTP server** for Zig 0.16, built on `std.http`. It has tighter integration than the generic SDK functions — request handlers receive a `*HTTPRequest` that knows about Datastar SSE, batched vs sync streaming, hot reload, and a fast radix-tree router.

A minimal handler looks like this:

```zig
const datastar = @import("datastar");
const HTTPServer = datastar.HTTPServer;
const HTTPRequest = datastar.HTTPRequest;

pub fn main(init: std.process.Init) !void {
    var server = try HTTPServer.init(init, .{ .port = 8080 });
    defer server.deinit();

    const r = server.router;
    r.get("/", index);
    r.get("/sse/:id", sseEndpoint);

    try server.run();
}

fn sseEndpoint(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements("<div id='hello'>Hello World</div>", .{});
    try sse.patchSignals(.{ .foo = 42 }, .{}, .{});
    try sse.executeScriptFmt("alert('hello {s}')", .{"world"}, .{});
}
```

Key surface:

```zig
HTTPServer.init(process_init, config) !*HTTPServer
server.run() / server.deinit()
server.useCtx(ptr)                    // attach a global context for handlers
server.rebooter(process_init)         // restart on executable change (dev mode)

// Routing
const r = server.router;
r.get / r.post / r.patch / r.delete(path, handler)
// Path params: r.get("/users/:id/:action", handler)

// Inside a handler:
http.req                              // underlying *std.http.Server.Request
http.arena                            // per-request arena
http.params.get(name) / http.params.getInt(T, name)
http.html / htmlFmt / json / css / cssFmt / js / jsFmt / sendFile
http.readSignals(T)
http.setCookie / getCookie / query

// SSE
http.NewSSE()      // batched (default)
http.NewSSESync()  // immediate per-call writes for long-lived streams
http.NewSSEOpt(SSEOptions)

sse.patchElements / patchElementsFmt / patchElementsWriter
sse.patchSignals / patchSignalsWriter
sse.executeScript / executeScriptFmt / executeScriptWriter
sse.keepalive / flush / close
```

Server config (see `Config` in `src/server.zig`):

```zig
.{
    .port               = 8080,
    .address            = null,        // null = listen on all addresses
    .threads            = num_cpus,    // short-lived request pool
    .sse_threads        = N,           // long-lived SSE pool
    .public_sse_threads = N,           // separate pool for untrusted SSE clients
    .fd_limit           = .max,        // or .limited(n), or null
    .watch              = false,       // reboot on executable change
}
```

The full prose walkthrough — batched vs sync writes, hot reload setup, pub/sub patterns, header tricks, validation harness, benchmarking notes — lives in `TUTORIAL.md`.

## Pub/Sub and CQRS

Reactive, multi-player Datastar apps almost always end up doing CQRS in miniature: a `POST /bid` command mutates state, and every connected SSE stream that cares about that state needs to be told to re-render. That requires an in-process message bus to fan out from the command handler to all the long-lived SSE subscribers.

To make this possible out of the box, the SDK bundles [`pubsub.zig`](https://github.com/zigster64/pubsub.zig) — a small in-process broker built specifically for these Datastar SSE runners. It is wired up automatically as part of the `datastar` module and the bundled HTTP server, so there is nothing extra to add to `build.zig`:

```zig
const datastar = @import("datastar");
const pubsub = datastar.pubsub;   // re-exported for convenience
```

A typical CQRS loop looks like this — a query handler subscribes and streams updates, and a command handler publishes after mutating state:

```zig
// Query side: long-lived SSE that re-renders whenever `cats` is published
fn catsList(app: *App, http: *HTTPRequest) !void {
    var sse = try http.NewSSESync();
    defer sse.close();
    try pushCatList(app, &sse);            // initial render

    var mq = try app.pubsub.connect();
    defer mq.deinit();
    try mq.subscribe(.cats);

    while (try mq.nextTimeout(.fromSeconds(30))) |event| switch (event) {
        .msg     => try pushCatList(app, &sse),
        .timeout => try sse.keepalive(),
    }
}

// Command side: mutate, then publish
fn postBid(app: *App, http: *HTTPRequest) !void {
    // ... validate + apply the bid ...
    try app.pubsub.publish(.{ .cats = {} }, .all);
}
```

You don't have to use the bundled broker. It is bundled because it's the shortest path from "single binary" to "working multi-player demo", and because every example app in this repo that needs fan-out uses it (`example_2`, `example_3`, `example_5`). When you outgrow single-process — multiple app instances, durability, cross-language consumers — swap it for **NATS**, **Redis pub/sub**, **Postgres LISTEN/NOTIFY**, or any other broker. The handler shape stays the same: subscribe, loop, render on each message; publish from the command handler. Only the `connect` / `subscribe` / `publish` calls change.

See `examples/02_cats.zig` for a complete worked example, and the *Publish and Subscribe* section of `TUTORIAL.md` for the longer walkthrough.

## Roadmap

- **`Io.Evented` migration.** Examples currently use `Io.Threaded`. Work on Evented / io_uring / kqueue / GrandCentralDispatch — ongoing in the 0.17 branch in this repo.

## More on Datastar

- [data-star.dev](https://data-star.dev) — official site and reference
- [Datastar SDK ADR](https://github.com/starfederation/datastar/blob/develop/sdk/ADR.md)
- [Datastar Discord](https://discord.gg/YfFn7pKx)
- [Zig Discord](https://discord.gg/Chk5WKM5)

## Contributing

PRs welcome. Please open an issue first to discuss non-trivial changes, and reference the issue in the PR title.
