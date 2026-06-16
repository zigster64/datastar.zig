# Snippets of backend code for the Datastar Docs - HOW-TO

## Load more list items

https://data-star.dev/how_tos/load_more_list_items#steps
```zig
const datastar = @import("datastar");

fn listHandler(http: *datastar.HTTPRequest) !void {
    const OffsetSignals = struct {
        offset: usize,
    };

    const signals = try datastar.readSignals(OffsetSignals);

    const max: usize = 5;
    const limit: usize = 1;

    var sse = try http.NewSSE();
    defer sse.close();

    if (signals.offset < max) {
        const newOffset: usize = signals.offset + limit;
        try sse.patchElementsFmt("<div>Item {}</div>", newOffset, .{
            .selector = "#list",
            .mode = .append,
        });

        if (newOffset.offset < max) {
            try sse.patchSignals(.{.offset = newOFfset}, .{});
        } else {
            try sse.patchElements("", .{
                .selector = "#load-more",
                .mode = .remove,
            });
        }
    }
}
```

## How to poll the backend at regular intervals

https://data-star.dev/how_tos/poll_the_backend_at_regular_intervals#steps

```zig
const datastar = @import("datastar");
const ISOTime = @import("iso_time");
const Io = std.Io;

fn timeHandler(http: *datastar.HTTPRequest) !void {
    const now = ISOTime.init(Io.clock.real.now(http.io));

    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElementsFmt(
        \\<div id="time" data-on-interval__duration.5s="@get('/endpoint')">
        \\ {s}
        \\div>
        , .{now}, .{});
}
```

## How to redirect the page from the backend

https://data-star.dev/how_tos/redirect_the_page_from_the_backend#steps

```zig
const datastar = @import("datastar");

fn redirectHandler(http: *datastar.HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements(
        \\<div id="indicator">Redirecting in 3 seconds...</div>
        , .{});
    http.io.sleep(.fromSeconds(3), .real) catch {};
    try sse.executeScript(
        \\window.location = "/guide"
        .{});
}
```
