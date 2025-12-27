const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// Server is a basic 0.16 web server
io: Io,
allocator: Allocator,
server: std.Io.net.Server = undefined,
router: *Router,

const Server = @This();

pub const HTTPRequest = struct {
    req: *std.http.Server.Request,
    io: Io,
    arena: std.mem.Allocator,
    params: Params,

    // return the given data as text/html
    pub fn html(self: HTTPRequest, data: []const u8) !void {
        try self.req.respond(data, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
        });
    }

    pub fn htmlFmt(self: HTTPRequest, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [4096]u8 = undefined;

        var body_writer = try self.req.respondStreaming(&buffer, .{
            .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
            },
        });

        const w = body_writer.writer();
        try w.print(fmt, args);
        try body_writer.end();
    }

    pub fn json(self: HTTPRequest, data: anytype) !void {
        // Use a small stack buffer for the body writer
        var buffer: [4096]u8 = undefined;

        var body_writer = try self.req.respondStreaming(&buffer, .{
            .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            },
        });

        try std.json.Stringify.value(data, .{}, &body_writer.writer); // default to minified JSON on the wire
        try body_writer.end();
    }

    pub fn readSignals(self: HTTPRequest, comptime T: type) !T {
        const req = self.req;
        const arena = self.arena;

        switch (req.head.method) {
            .GET => {
                const target = req.head.target;
                const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingDatastarKey;
                const query_string = target[query_idx + 1 ..];

                // Manually find "datastar=" in the query string
                var it = std.mem.tokenizeScalar(u8, query_string, '&');
                while (it.next()) |pair| {
                    if (std.mem.startsWith(u8, pair, "datastar=")) {
                        const encoded_val = pair["datastar=".len..];
                        const decoded = try urlDecode(arena, encoded_val);

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
                return std.json.parseFromSliceLeaky(
                    T,
                    arena,
                    body,
                    .{ .ignore_unknown_fields = true },
                );
            },
        }
    }

    fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var out = try allocator.alloc(u8, input.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < input.len) {
            if (input[i] == '%' and i + 2 < input.len) {
                out[j] = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch input[i];
                i += 3;
            } else if (input[i] == '+') {
                out[j] = ' ';
                i += 1;
            } else {
                out[j] = input[i];
                i += 1;
            }
            j += 1;
        }
        return out[0..j];
    }
};

pub fn init(io: Io, allocator: Allocator, addr: []const u8, port: u16) !Server {
    const address = try Io.net.IpAddress.parseIp4(addr, port);
    const server = try address.listen(io, .{ .reuse_address = true });
    return .{
        .io = io,
        .allocator = allocator,
        .server = server,
        .router = try Router.init(allocator),
    };
}

pub fn deinit(self: *Server) void {
    self.server.deinit(self.io);
}

pub fn run(self: *Server) !void {
    while (true) {
        const conn = try self.server.accept(self.io);
        _ = try self.io.concurrent(handleConnection, .{ self, conn });
    }
}

// Added 'router' to the arguments
fn handleConnection(self: *Server, conn: Io.net.Stream) void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    const arena_alloc = arena.allocator();
    defer {
        conn.close(self.io);
        arena.deinit();
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = conn.reader(self.io, &read_buffer);
    var writer = conn.writer(self.io, &write_buffer);

    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            return;
        };

        // Wrap the standard request into your Datastar HTTPRequest struct
        var http = HTTPRequest{
            .io = self.io,
            .req = &request,
            .arena = arena_alloc,
            .params = .{},
        };

        self.router.dispatch(&http) catch |err| {
            std.debug.print("Routing error: {}\n", .{err});
        };
    }
}

pub const RouteHandler = *const fn (req: HTTPRequest) anyerror!void;

pub const Params = struct {
    names: [8][]const u8 = undefined,
    values: [8][]const u8 = undefined,
    count: usize = 0,

    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        }
        return null;
    }

    pub fn format(self: Params, writer: *std.Io.Writer) !void {
        try writer.writeAll("Params { ");
        for (0..self.count) |i| {
            if (i > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("  {s}: \"{s}\"", .{ self.names[i], self.values[i] });
        }
        try writer.writeAll("}");
    }
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    root: *Node,

    const Node = struct {
        segment: []const u8 = "",
        is_param: bool = false,
        param_name: []const u8 = "",
        handlers: [std.enums.values(std.http.Method).len]?RouteHandler = [_]?RouteHandler{null} ** std.enums.values(std.http.Method).len,
        children: std.ArrayListUnmanaged(*Node) = .{},

        fn deinit(self: *Node, alloc: std.mem.Allocator) void {
            for (self.children.items) |child| child.deinit(alloc);
            self.children.deinit(alloc);
            if (!self.is_param and self.segment.len > 0) alloc.free(self.segment);
            if (self.is_param and self.param_name.len > 0) alloc.free(self.param_name);
            alloc.destroy(self);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !*Router {
        const self = try allocator.create(Router);
        const root = try allocator.create(Node);
        root.* = .{};
        self.* = .{ .allocator = allocator, .root = root };
        return self;
    }

    // Convenience helpers
    pub fn get(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.add(.GET, path, handler);
    }
    pub fn post(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.add(.POST, path, handler);
    }
    pub fn put(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.add(.PUT, path, handler);
    }
    pub fn patch(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.add(.PATCH, path, handler);
    }
    pub fn delete(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.add(.DELETE, path, handler);
    }

    pub fn add(self: *Router, method: std.http.Method, path: []const u8, handler: RouteHandler) !void {
        var current = self.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');

        while (it.next()) |seg| {
            const is_param = std.mem.startsWith(u8, seg, ":");
            var found: ?*Node = null;

            for (current.children.items) |child| {
                if (is_param and child.is_param) {
                    found = child;
                    break;
                }
                if (!is_param and std.mem.eql(u8, child.segment, seg)) {
                    found = child;
                    break;
                }
            }

            if (found) |node| {
                current = node;
            } else {
                const node = try self.allocator.create(Node);
                node.* = .{
                    .segment = if (is_param) "" else try self.allocator.dupe(u8, seg),
                    .is_param = is_param,
                    .param_name = if (is_param) try self.allocator.dupe(u8, seg[1..]) else "",
                };
                try current.children.append(self.allocator, node);
                current = node;
            }
        }
        // Save the handler for the specific method
        current.handlers[@intFromEnum(method)] = handler;
    }

    pub fn dispatch(self: *Router, http_req: *HTTPRequest) !void {
        var params = Params{};
        var current = self.root;

        const target = http_req.req.head.target;
        const query_index = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const path_only = target[0..query_index];

        var it = std.mem.tokenizeScalar(u8, path_only, '/');

        while (it.next()) |seg| {
            var match: ?*Node = null;
            for (current.children.items) |child| {
                if (child.is_param) {
                    params.names[params.count] = child.param_name;
                    params.values[params.count] = seg;
                    params.count += 1;
                    match = child;
                    break;
                } else if (std.mem.eql(u8, child.segment, seg)) {
                    match = child;
                    break;
                }
            }
            if (match) |m| current = m else return http_req.req.respond("", .{ .status = .not_found });
        }

        http_req.params = params;

        // Check if a handler exists for the request's method
        const method_idx = @intFromEnum(http_req.req.head.method);
        if (current.handlers[method_idx]) |h| {
            return h(http_req.*);
        }

        return http_req.req.respond("Method Not Allowed", .{ .status = .method_not_allowed });
    }
};
