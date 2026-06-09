const std = @import("std");
const datastar = @import("datastar.zig");
const Params = @import("params.zig");
const Log = @import("log.zig");

const SSE = datastar.SSE;
const SSEOptions = datastar.SSEOptions;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const HTTPRequest = @This();

/// Member data of the HTTPRequest context
/// We want to store
///   - Some global state vars for arena and io
///   - The raw request struct
///   - Parsed params from the request
///   - detached flag - if this is a long lived SSE, tells the dispatcher loop to not expect more requests this connection
///   - extra headers to be applied when the response is created
///   - time taken for the handler to be processed
///   - status code for the response
req: *std.http.Server.Request,
io: Io,
ctx: ?*anyopaque = null,
arena: std.mem.Allocator,
params: Params,
path: []const u8 = "",
method: std.http.Method = .GET,
extra_headers: ?[]const std.http.Header = null,
detach: bool = false, // detached is set if there is any SSE acting on this request - which stops it looping looking for more requests on the same connection
replied: bool = false,
req_payload: ?[]const u8 = null,
status: std.http.Status = .ok,
timer: std.Io.Timestamp = undefined,
    log: Log = .{},

    /// Assigns: typed key-value store for middleware → handler communication.
    /// Lazy-initialized ArrayList backed by the per-request arena. No hard cap.
    assigns: ?*std.ArrayList(AssignEntry) = null,

    /// Set by middleware to stop the pipeline. Remaining middleware and the
    /// route handler are skipped when true.
    halted: bool = false,

    /// Opaque pointer to the server's Middleware chain. Set by the framework
    /// before dispatch. Cast to *const Middleware when needed.
    _middleware: ?*anyopaque = null,

/// Entry in the assigns store. Keys are arena-duped strings; values are
/// arena-allocated typed pointers cast to *anyopaque.
pub const AssignEntry = struct {
    key: []const u8,
    value: *anyopaque,
};

/// Return the context as the given type
pub fn getCtx(http: *HTTPRequest, T: type) T {
    const ptr = http.ctx orelse std.debug.panic("Attempted to access null context", .{});
    return @ptrCast(@alignCast(ptr));
}

/// Store a typed value under a string key in the request assigns store.
/// The value is arena-allocated and lives for the request duration.
/// The store is lazily initialized on first use. No hard capacity limit.
/// Returns a pointer to the stored value.
pub fn assign(self: *HTTPRequest, comptime T: type, key: []const u8, value: T) !*T {
    if (self.assigns == null) {
        const list = try self.arena.create(std.ArrayList(AssignEntry));
        list.* = std.ArrayList(AssignEntry).empty;
        self.assigns = list;
    }
    const ptr = try self.arena.create(T);
    ptr.* = value;
    try self.assigns.?.append(self.arena, .{ .key = try self.arena.dupe(u8, key), .value = ptr });
    return ptr;
}

/// Retrieve a previously stored value by key and type.
/// Returns null if no value with the given key exists.
/// The caller must match the type parameter used in assign() —
/// mismatched type results in undefined behaviour.
pub fn assigned(self: *HTTPRequest, comptime T: type, key: []const u8) ?*T {
    const list = self.assigns orelse return null;
    for (list.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return @ptrCast(@alignCast(entry.value));
        }
    }
    return null;
}

/// Return a new SSE object for a simple 1 shot response
pub fn NewSSE(http: *HTTPRequest) !SSE {
    return NewSSEOpt(http, .{});
}

/// Return a new SSE object setup for a series of synchronous responses or persistent connection
pub fn NewSSESync(http: *HTTPRequest) !SSE {
    return NewSSEOpt(http, .{ .sync = true });
}

/// Return a new SSE object with custom options
pub fn NewSSEOpt(http: *HTTPRequest, opt: SSEOptions) !SSE {
    const buf_size = if (opt.buffer_size != 0) opt.buffer_size else datastar.DEFAULT_BUFFER_SIZE;

    // IF we are text/event-stream AND we have no content-length (chunked encoding)
    // THEN detach the request from the connection - because the browser will never queue
    // another request over this same connection
    if (opt.sync) {
        http.detach = true;
    }

    // Always keep the SSE content-type / cache-control headers. Previously
    // `extra_headers` *replaced* the merge result and dropped them.
    const headers = try http.buildSseHeaders(opt.extra_headers);

    const allocating_writer = blk: {
        if (opt.buffer_size == 0) break :blk Io.Writer.Allocating.init(http.arena);
        break :blk Io.Writer.Allocating.initCapacity(http.arena, buf_size) catch Io.Writer.Allocating.init(http.arena);
    };

    http.replied = true;

    // One-shot (non-sync): defer the HTTP response until close() so we can emit
    // Content-Length in a single respond() — avoids chunked framing + a second
    // BodyWriter buffer for the common Datastar morph path.
    if (!opt.sync) {
        return .{
            .stream = null,
            .req = http.req,
            .headers = headers,
            .output_buffer = allocating_writer,
            .buffer_size = opt.buffer_size,
            .sync = false,
            .io = http.io,
            .start_time = Io.Clock.real.now(http.io),
        };
    }

    // Sync / long-lived: start a chunked stream immediately and flush headers.
    const buf = try http.arena.alloc(u8, buf_size);
    const res = try http.arena.create(std.http.BodyWriter);
    res.* = try http.req.respondStreaming(
        buf,
        .{ .respond_options = .{ .extra_headers = headers } },
    );
    try res.flush();

    return .{
        .stream = res,
        .req = null,
        .headers = headers,
        .output_buffer = allocating_writer,
        .buffer_size = opt.buffer_size,
        .sync = true,
        .io = http.io,
        .start_time = Io.Clock.real.now(http.io),
    };
}

const default_headers = &[_]std.http.Header{
    // Do not force Connection: keep-alive — std.http.Server owns persistence
    // and must be free to emit connection: close when the client asked for it.
    .{ .name = "X-Powered-By", .value = "datastar.zig" },
};

const sse_content_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
    .{ .name = "cache-control", .value = "no-cache" },
};

/// Build the header list for an SSE response: always include content-type /
/// cache-control, optionally merge caller extras, then fold in defaults via
/// mergeHeaders. Extracted so the merge-not-replace branch is unit-testable.
pub fn buildSseHeaders(self: *HTTPRequest, extras: ?[]const std.http.Header) ![]const std.http.Header {
    if (extras) |extra| {
        const combined = try self.arena.alloc(std.http.Header, sse_content_headers.len + extra.len);
        @memcpy(combined[0..sse_content_headers.len], &sse_content_headers);
        @memcpy(combined[sse_content_headers.len..], extra);
        return try self.mergeHeaders(combined);
    }
    return try self.mergeHeaders(&sse_content_headers);
}

/// use this to construct extra_headers when creating any response
/// it will pull in self.extra_headers, and merge them with the new set
/// to provide a complete set for the actual request
/// See http.setCookie() for an example where this is needed
pub fn mergeHeaders(self: *HTTPRequest, extra: []const std.http.Header) ![]const std.http.Header {
    const stored_extras = if (self.extra_headers) |h| h else &[_]std.http.Header{};
    const total_len = default_headers.len + stored_extras.len + extra.len;
    const combined = try self.arena.alloc(std.http.Header, total_len);

    var cursor: usize = 0;

    @memcpy(combined[cursor..][0..default_headers.len], default_headers);
    cursor += default_headers.len;

    if (stored_extras.len > 0) {
        @memcpy(combined[cursor..][0..stored_extras.len], stored_extras);
        cursor += stored_extras.len;
    }

    if (extra.len > 0) {
        @memcpy(combined[cursor..][0..extra.len], extra);
    }

    return combined;
}

// send generic data, with given mime type
pub fn sendData(self: *HTTPRequest, content: []const u8, mime_type: []const u8) !void {
    self.replied = true;
    try self.req.respond(
        content,
        .{ .extra_headers = try self.mergeHeaders(&.{.{ .name = "content-type", .value = mime_type }}) },
    );
}

/// send a response of type text/html with the given data
pub fn html(self: *HTTPRequest, content: []const u8) !void {
    try self.sendData(content, "text/html");
}

/// send a response of type text/html with a formatted print
pub fn htmlFmt(self: *HTTPRequest, comptime fmt: []const u8, args: anytype) !void {
    try self.html(try std.fmt.allocPrint(self.arena, fmt, args));
}

/// send a response of type text/css with the given data
pub fn css(self: *HTTPRequest, content: []const u8) !void {
    try self.sendData(content, "text/css; charset=UTF-8");
}

/// send a response of type text/css with a formatted print
pub fn cssFmt(self: *HTTPRequest, comptime fmt: []const u8, args: anytype) !void {
    try self.css(try std.fmt.allocPrint(self.arena, fmt, args));
}

/// send a response of type application/javascript with the given data
pub fn js(self: *HTTPRequest, content: []const u8) !void {
    try self.sendData(content, "application/javascript");
}

/// send a response of type application/javascript with a formatted print
pub fn jsFmt(self: *HTTPRequest, comptime fmt: []const u8, args: anytype) !void {
    try self.js(try std.fmt.allocPrint(self.arena, fmt, args));
}

/// send a response of type application/json with the given data
pub fn json(self: *HTTPRequest, content: anytype) !void {
    var buffer: [4096]u8 = undefined;

    var body_writer = try self.req.respondStreaming(
        &buffer,
        .{
            .respond_options = .{
                .extra_headers = try self.mergeHeaders(&.{.{ .name = "content-type", .value = "application/json" }}),
            },
        },
    );

    try std.json.Stringify.value(content, .{}, &body_writer.writer);
    try body_writer.end();

    self.replied = true;
}

/// get just the path without the query params
pub fn getPathOnly(self: HTTPRequest) []const u8 {
    const query_idx = std.mem.indexOfScalar(u8, self.path, '?') orelse return self.path;
    return self.path[0..query_idx];
}

/// extract the full query params from the request
pub fn query(self: HTTPRequest) ?[]const u8 {
    const query_idx = std.mem.indexOfScalar(u8, self.path, '?') orelse return null;
    return self.path[query_idx + 1 ..];
}

/// read Datastar signals from the request into the given struct type, return an instance of this struct
pub fn readSignals(self: *HTTPRequest, comptime T: type) !T {
    const req = self.req;
    const arena = self.arena;

    switch (req.head.method) {
        .GET => {
            const target = self.path;
            const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingDatastarKey;
            const query_string = target[query_idx + 1 ..];

            var it = std.mem.tokenizeScalar(u8, query_string, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "datastar=")) {
                    const encoded_val = pair["datastar=".len..];
                    const decoded = try datastar.urlDecode(arena, encoded_val);

                    return std.json.parseFromSliceLeaky(
                        T,
                        arena,
                        decoded,
                        .{ .ignore_unknown_fields = true },
                    );
                }
            }
            return error.MissingDatastarKey;
        },
        else => {
            const length = req.head.content_length orelse return error.MissingContentLength;
            const body = try arena.alloc(u8, @intCast(length));

            var reader_buffer: [8192]u8 = undefined;
            const reader = req.readerExpectNone(&reader_buffer);

            try reader.readSliceAll(body);
            self.req_payload = self.arena.dupe(u8, body) catch null;
            return std.json.parseFromSliceLeaky(
                T,
                arena,
                body,
                .{ .ignore_unknown_fields = true },
            );
        },
    }
}

/// set a cookie that will be included in the response header
pub fn setCookie(self: *HTTPRequest, name: []const u8, value: []const u8) !void {
    const cookie_val = try std.fmt.allocPrint(self.arena, "{s}={s}; Path=/; HttpOnly; SameSite=Lax", .{ name, value });
    const current_list = if (self.extra_headers) |h| h else &[_]std.http.Header{};
    const new_list = try self.arena.alloc(std.http.Header, current_list.len + 1);

    if (current_list.len > 0) {
        @memcpy(new_list[0..current_list.len], current_list);
    }

    new_list[current_list.len] = .{ .name = "set-cookie", .value = cookie_val };

    self.extra_headers = new_list;
}

/// get a cookie from the request
pub fn getCookie(self: *HTTPRequest, name: []const u8) ?[]const u8 {
    var it = self.req.iterateHeaders();
    while (it.next()) |header| {
        // Find the "Cookie" header (case-insensitive check)
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {

            // Tokenize by ';' to handle "key1=val1; key2=val2"
            var cookie_it = std.mem.tokenizeScalar(u8, header.value, ';');
            while (cookie_it.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " ");

                if (std.mem.findScalar(u8, trimmed, '=')) |idx| {
                    const key = trimmed[0..idx];

                    if (std.mem.eql(u8, key, name)) {
                        return trimmed[idx + 1 ..];
                    }
                }
            }
        }
    }
    return null;
}

/// Wrapper around raw std.http.Server.Request.respond, where we save the status
pub fn respond(http: *HTTPRequest, content: []const u8, status: std.http.Status) std.http.Server.Request.ExpectContinueError!void {
    http.status = status;
    return http.req.respond(content, .{ .status = status });
}

pub fn redirect(http: *HTTPRequest, path: []const u8) std.http.Server.Request.ExpectContinueError!void {
    return http.req.respond("", .{
        .extra_headers = &.{.{ .name = "Location", .value = path }},
        .status = .see_other,
    });
}

/// return the mime type based on the file extension
pub fn mimeTypeByExtension(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return "text/html; charset=UTF-8";
    if (std.ascii.eqlIgnoreCase(ext, ".css")) return "text/css; charset=UTF-8";
    if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs")) return "application/javascript; charset=UTF-8";
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".avif")) return "image/avif";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(ext, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "text/plain; charset=UTF-8";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(ext, ".woff")) return "font/woff";
    if (std.ascii.eqlIgnoreCase(ext, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}

/// use this function to sanity check the contents of a filename param
pub fn sanitizeFileParam(_: *HTTPRequest, filename: []const u8) !void {
    if (filename.len < 1 or filename.len > 256 or
        std.mem.indexOfScalar(u8, filename, 0) != null or
        std.mem.indexOf(u8, filename, "..") != null or
        std.mem.indexOf(u8, filename, "/") != null or
        std.mem.indexOf(u8, filename, "\\") != null)
    {
        return error.InvalidFilename;
    }
}

/// send a file response - pass a filename, and on optional mime_type
/// if the mime_type is null, will calculate using the obove function
pub fn sendFile(self: *HTTPRequest, filename: []const u8, mime_type: ?[]const u8) !void {
    if (filename.len < 1) return error.InvalidFilename;

    // sanitize the filename to prevent path traversal attacks

    const dir = std.Io.Dir.cwd();
    var path = filename;
    if (path[0] == '/') {
        path = path[1..]; // path must be relative
    }

    const file = dir.openFile(self.io, path, .{}) catch |err| {
        // std.log.err("failed to open file {s} : {}", .{ path, err });
        return err;
    };
    defer file.close(self.io);

    // get the size of the file
    const stat = try file.stat(self.io);

    // get a reference to the file contents
    const mapped_memory = try posix.mmap(
        null,
        stat.size,
        .{ .READ = true, .WRITE = false, .EXEC = false },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer posix.munmap(mapped_memory);

    // Hint to the kernel that we will read this sequentially
    try posix.madvise(mapped_memory.ptr, stat.size, posix.MADV.SEQUENTIAL);

    const mt = mime: {
        if (mime_type) |m| break :mime m;
        break :mime mimeTypeByExtension(path);
    };

    try self.req.respond(mapped_memory, .{
        .extra_headers = try self.mergeHeaders(&.{
            .{ .name = "content-type", .value = mt },
        }),
    });

    self.replied = true;
}

test "mimeTypeByExtension" {
    try std.testing.expectEqualStrings("text/html; charset=UTF-8", mimeTypeByExtension("test.html"));
    try std.testing.expectEqualStrings("text/html; charset=UTF-8", mimeTypeByExtension("test.htm"));
    try std.testing.expectEqualStrings("text/css; charset=UTF-8", mimeTypeByExtension("style.css"));
    try std.testing.expectEqualStrings("application/javascript; charset=UTF-8", mimeTypeByExtension("script.js"));
    try std.testing.expectEqualStrings("application/javascript; charset=UTF-8", mimeTypeByExtension("mod.mjs"));
    try std.testing.expectEqualStrings("image/png", mimeTypeByExtension("image.png"));
    try std.testing.expectEqualStrings("image/jpeg", mimeTypeByExtension("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", mimeTypeByExtension("photo.jpeg"));
    try std.testing.expectEqualStrings("image/gif", mimeTypeByExtension("anim.gif"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeTypeByExtension("vector.svg"));
    try std.testing.expectEqualStrings("image/x-icon", mimeTypeByExtension("favicon.ico"));
    try std.testing.expectEqualStrings("application/json", mimeTypeByExtension("data.json"));
    try std.testing.expectEqualStrings("application/wasm", mimeTypeByExtension("app.wasm"));
    try std.testing.expectEqualStrings("text/plain; charset=UTF-8", mimeTypeByExtension("readme.txt"));
    try std.testing.expectEqualStrings("application/pdf", mimeTypeByExtension("doc.pdf"));
    try std.testing.expectEqualStrings("font/woff", mimeTypeByExtension("font.woff"));
    try std.testing.expectEqualStrings("font/woff2", mimeTypeByExtension("font.woff2"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeByExtension("unknown.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeByExtension("no_extension"));
}

test "query" {
    var req = HTTPRequest{
        .req = undefined,
        .io = undefined,
        .arena = std.testing.allocator,
        .params = .{},
        .path = "/foo?bar=baz",
    };
    try std.testing.expectEqualStrings("bar=baz", req.query().?);

    req.path = "/foo";
    try std.testing.expect(req.query() == null);
}

test "setCookie" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HTTPRequest{
        .req = undefined,
        .io = undefined,
        .arena = arena.allocator(),
        .params = .{},
    };

    try req.setCookie("foo", "bar");
    try std.testing.expect(req.extra_headers != null);
    try std.testing.expectEqual(1, req.extra_headers.?.len);
    try std.testing.expectEqualStrings("set-cookie", req.extra_headers.?[0].name);
    try std.testing.expect(std.mem.startsWith(u8, req.extra_headers.?[0].value, "foo=bar;"));
}

test "mergeHeaders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HTTPRequest{
        .req = undefined,
        .io = undefined,
        .arena = arena.allocator(),
        .params = .{},
    };

    const extra = &[_]std.http.Header{
        .{ .name = "X-Test", .value = "True" },
    };

    const merged = try req.mergeHeaders(extra);

    // defaults (1: X-Powered-By) + extra (1) = 2 — no forced Connection.
    try std.testing.expectEqual(2, merged.len);

    var found_test_header = false;
    var found_powered_by = false;
    var found_connection = false;

    for (merged) |h| {
        if (std.mem.eql(u8, h.name, "X-Test") and std.mem.eql(u8, h.value, "True")) {
            found_test_header = true;
        }
        if (std.mem.eql(u8, h.name, "X-Powered-By")) {
            found_powered_by = true;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "Connection")) {
            found_connection = true;
        }
    }

    try std.testing.expect(found_test_header);
    try std.testing.expect(found_powered_by);
    try std.testing.expect(!found_connection);
}

test "buildSseHeaders keeps content-type when extras present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HTTPRequest{
        .req = undefined,
        .io = undefined,
        .arena = arena.allocator(),
        .params = .{},
    };

    const headers = try req.buildSseHeaders(&.{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    });

    var found_ct = false;
    var found_cc = false;
    var found_cors = false;
    var found_powered_by = false;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type") and
            std.mem.indexOf(u8, h.value, "text/event-stream") != null) found_ct = true;
        if (std.ascii.eqlIgnoreCase(h.name, "cache-control")) found_cc = true;
        if (std.mem.eql(u8, h.name, "Access-Control-Allow-Origin")) found_cors = true;
        if (std.mem.eql(u8, h.name, "X-Powered-By")) found_powered_by = true;
    }
    try std.testing.expect(found_ct);
    try std.testing.expect(found_cc);
    try std.testing.expect(found_cors);
    try std.testing.expect(found_powered_by);
}

test "NewSSEOpt one-shot has no stream and keeps sync false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // One-shot path only stores the request pointer until close(); a placeholder
    // Request is enough to cover the !sync branch without respondStreaming.
    var server_req: std.http.Server.Request = undefined;
    var req = HTTPRequest{
        .req = &server_req,
        .io = std.testing.io,
        .arena = arena.allocator(),
        .params = .{},
        .path = "/",
        .method = .GET,
    };

    var sse = try NewSSEOpt(&req, .{
        .extra_headers = &.{
            .{ .name = "X-Test", .value = "1" },
        },
    });
    defer sse.output_buffer.deinit();

    try std.testing.expect(sse.stream == null);
    try std.testing.expect(!sse.sync);
    try std.testing.expect(req.replied);
    try std.testing.expect(!req.detach);

    var found_ct = false;
    var found_x = false;
    for (sse.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) found_ct = true;
        if (std.mem.eql(u8, h.name, "X-Test")) found_x = true;
    }
    try std.testing.expect(found_ct);
    try std.testing.expect(found_x);
}

test "readSignals GET" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Head = @TypeOf(@as(std.http.Server.Request, undefined).head);

    const head = Head{
        .method = .GET,
        .target = "/?datastar=%7B%22foo%22%3A%22bar%22%7D", // {"foo":"bar"} url encoded
        .version = .@"HTTP/1.1",
        .expect = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .transfer_compression = .identity,
        .keep_alive = false,
    };

    var server_req = std.http.Server.Request{
        .server = undefined,
        .head = head,
        .head_buffer = undefined,
    };

    var req = HTTPRequest{
        .req = &server_req,
        .io = undefined,
        .arena = arena.allocator(),
        .params = .{},
        .path = "/?datastar=%7B%22foo%22%3A%22bar%22%7D",
    };

    const SignalType = struct { foo: []const u8 };
    const sig = try req.readSignals(SignalType);
    try std.testing.expectEqualStrings("bar", sig.foo);
}
