# Snippets of backend code for the Datastar Docs - GUIDE

## Open the Pod Bay Doors Hal

https://data-star.dev/guide/getting_started#patching-elements

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

    http.io.sleep(.fromSeconds(1), .real) catch {};

    try sse.patchElements(
        \\<div id="hal">Waiting for an order...</div>
        , .{});
}
```

## HAL, do you read me ?

https://data-star.dev/guide/reactive_signals#patching-signals

```zig
const datastar = @import("datastar");

// Example of using patchSignals
fn doYouReadMeHAL(http: *datastar.HTTPRequest) !void {
    var sse = try http.NewSSESync();
    defer sse.close();

    try sse.patchSignals(.{
        .hal = "Affirmative, Dave. I read you.",
    }, .{});

    http.io.sleep(.fromSeconds(1), .real) catch {};

    try sse.patchSignals(.{
        .hal = "...",
    }, .{});
}
```

## Executing script example

https://data-star.dev/guide/datastar_expressions

```zig
var sse = try http.NewSSE();
defer sse.close();

try sse.executeScript("alert('This mission is too important for me to allow you to jeopardize it.')", .{});

```

## Reading Signals Example

https://data-star.dev/guide/backend_requests#reading-signals

```zig
const datastar = @import("datastar");

pub const Signals = struct {
    foo: struct {
        bar: []const u8,
    },
};

pub fn handleIncomingRequest(http: *datastar.HTTPRequest) !void {
    const signals = try datastar.readSignals(Signals);
    // ... use signals
}
```

## SSE Events

https://data-star.dev/guide/backend_requests#sse-events

```zig
const datastar = @import("datastar");

var sse = http.NewSSE();
defer sse.close();

// Patches elements into the DOM.
try sse.PatchElements(
    \\<div id="question">What do you put in a toaster?</div>
    , .{});
)

// Patches signals.
try sse.patchSignals(.{
    .response: "",
    .answer: "bread"
}, .{});
```

## Backend Actions

https://data-star.dev/guide/backend_requests#backend-actions

```zig
try sse.PatchElements("<div id='question'>...</div>", .{});
try sse.PatchElements("<div id='instructions'>...</div>", .{});
try sse.PatchSignals(.{.answer: " ...", .prize: " ..."}, .{});
```


