# Snippets of backend code for the Datastar Docs

## Open the Pod Bay Doors Hal

```zig
const datastar = @import("datastar");

// Example of using patchElements
fn openTheDoorsHal(http: *datastar.HTTPRequest) !void {
    // Use NewSSESync here for synchronous writes over the SSE connection
    var sse = try http.NewSSESync();
    defer sse.close();

    try sse.patchElements(
        \\<div id="hal">I’m sorry, Dave. I’m afraid I can’t do that.</div>
        , .{});
    );

    try http.io.sleep(.fromSeconds(1), .real);

    try sse.patchElements(
        \\<div id="hal">Waiting for an order...</div>
        , .{});
}
```

## HAL, do you read me ?

```zig
const datastar = @import("datastar");

// Example of using patchSignals
fn doYouReadMeHAL(http: *datastar.HTTPRequest) !void {
    var sse = try http.NewSSESync();
    defer sse.close();

    try sse.patchSignals(.{
        .hal = "Affirmative, Dave. I read you.",
    }, .{}, .{});

    try http.io.sleep(.fromSeconds(1), .real);

    try sse.patchSignals(.{
        .hal = "...",
    }, .{}, .{});
}

```

## Reading Signals Example


```zig
const datastar = @import("datastar");

const Signals = struct {
    foo: struct {
        bar: []const u8,
    },
};

fn yourHandler(http: *datastar.HTTPRequest) !void {
    const signals = try datastar.readSignals(Signals);
    // ... use signals ...
}
```
