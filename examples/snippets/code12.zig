== Middleware — per-request assigns ==

// Middleware attaches data to every request via http.assign()
var mw_request_count: usize = 0;
var mw_count_mutex: Io.Mutex = .init;

fn requestInfoMiddleware(http: *HTTPRequest) !void {
    try mw_count_mutex.lock(http.io);
    defer mw_count_mutex.unlock(http.io);
    const id = mw_request_count;
    mw_request_count += 1;
    _ = try http.assign(usize, "mw.request_id", id);
    _ = try http.assign(Io.Timestamp, "mw.start_time", Io.Clock.real.now(http.io));
}

// Register with server.use() — runs before every route handler
server.use(requestInfoMiddleware);

// Route handler reads assigns via http.assigned()
r.get("/middleware-demo", middlewareDemo);

fn middlewareDemo(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    const id: usize = http.assigned(usize, "mw.request_id") orelse 0;
    const start_time: Io.Timestamp = http.assigned(Io.Timestamp, "mw.start_time") orelse .zero;
    const elapsed = start_time.untilNow(http.io, .real).toMicroseconds();

    try sse.patchElementsFmt(
        \\<div id="mw-demo-output" class="p-4 text-center">
        \\  <p class="text-lg">Request <span class="font-bold text-primary"># {}</span></p>
        \\  <p class="text-sm opacity-70">Middleware attached this data via http.assign()</p>
        \\  <p class="text-xs opacity-50">Handler elapsed: {} µs</p>
        \\</div>
    , .{id, elapsed}, .{});
}
