const std = @import("std");
const HTTPRequest = @import("http_request.zig");
const Params = @import("params.zig");

const Io = std.Io;
const Router = @This();
pub const RouteHandlerFn = *const fn (req: *HTTPRequest) anyerror!void;

allocator: std.mem.Allocator,
root: *Node,
static_dir: ?[]const u8 = null,

const Node = struct {
    segment: []const u8 = "",
    is_param: bool = false,
    param_name: []const u8 = "",
    handlers: [std.enums.values(std.http.Method).len]?RouteHandlerFn = [_]?RouteHandlerFn{null} ** std.enums.values(std.http.Method).len,
    fiber: [std.enums.values(std.http.Method).len]bool = [_]bool{false} ** std.enums.values(std.http.Method).len,
    children: std.ArrayList(*Node) = .empty,

    fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        for (self.children.items) |child| child.deinit(alloc);
        self.children.deinit(alloc);
        if (!self.is_param and self.segment.len > 0) alloc.free(self.segment);
        if (self.is_param and self.param_name.len > 0) alloc.free(self.param_name);
        alloc.destroy(self);
    }
};

pub fn init(allocator: std.mem.Allocator) !*Router {
    const root = try allocator.create(Node);
    const self = try allocator.create(Router);
    root.* = .{};
    self.* = .{
        .allocator = allocator,
        .root = root,
    };
    return self;
}

pub fn deinit(self: *Router) void {
    self.root.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// declare a path to fetch static assets from - any URL that cant be found,
/// check if the same name file exists in the static dir, and fetch that
pub fn static(self: *Router, path: []const u8) void {
    self.static_dir = path;
    std.log.debug("  > STATIC files served from '{s}'", .{
        path,
    });
}

/// GET request
pub fn get(self: *Router, path: []const u8, handler: RouteHandlerFn) void {
    self.add(.GET, path, handler, false) catch unreachable;
}

/// GET request - but run it in a fiber instead of a thread, and take
/// control of the underlying connection
pub fn sse(self: *Router, path: []const u8, handler: RouteHandlerFn) void {
    self.add(.GET, path, handler, true) catch unreachable;
}

pub fn post(self: *Router, path: []const u8, handler: RouteHandlerFn) void {
    self.add(.POST, path, handler, false) catch unreachable;
}

pub fn put(self: *Router, path: []const u8, handler: RouteHandlerFn) void {
    self.add(.PUT, path, handler, false) catch unreachable;
}

pub fn patch(self: *Router, path: []const u8, handler: RouteHandlerFn) void {
    self.add(.PATCH, path, handler, false) catch unreachable;
}

pub fn delete(self: *Router, path: []const u8, handler: RouteHandlerFn) void {
    self.add(.DELETE, path, handler, false) catch unreachable;
}

pub fn add(self: *Router, method: std.http.Method, path: []const u8, handler: RouteHandlerFn, fiber: bool) !void {
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
            const node = self.allocator.create(Node) catch unreachable;
            node.* = .{
                .segment = if (is_param) "" else try self.allocator.dupe(u8, seg),
                .is_param = is_param,
                .param_name = if (is_param) try self.allocator.dupe(u8, seg[1..]) else "",
            };
            try current.children.append(self.allocator, node);
            current = node;
        }
    }
    current.handlers[@intFromEnum(method)] = handler;

    // on bootup - just always print the routes in effect
    std.log.debug("  > {t} {s}{s}", .{
        method,
        path,
        if (fiber) " (Long SSE)" else "",
    });
}

pub fn dispatch(self: *Router, http: *HTTPRequest) !void {
    var params = Params{};
    const log = http.log;

    // Sanitize the path - if it has ".." or various dodgy attack vectors, then reject it
    if (std.mem.find(u8, http.path, "..") != null) {
        return http.respond("Not Found", .not_found);
    }

    const target = http.path;
    const query_index = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path_only = target[0..query_index];

    var processed: bool = false;

    var it = std.mem.tokenizeScalar(u8, path_only, '/');
    var current = self.root;
    while (it.next()) |seg| {
        var match: ?*Node = null;
        for (current.children.items) |child| {
            if (child.is_param) {
                // fill in the local params var from the actual URL in the request
                if (params.count < params.names.len) {
                    params.names[params.count] = child.param_name;
                    params.values[params.count] = seg;
                    params.count += 1;
                }
                match = child;
                break;
            } else if (std.mem.eql(u8, child.segment, seg)) {
                match = child;
                break;
            }
        }

        if (match) |m| current = m else {
            // didnt find it - check if its a static file asset to serve up
            if (self.static_dir) |sd| {
                var extended_path: Io.Writer.Allocating = .init(http.arena);
                try extended_path.writer.print("{s}{s}", .{ sd, http.path });
                http.sendFile(extended_path.written(), null) catch |err| {
                    switch (err) {
                        error.FileNotFound => return http.respond("Not Found", .not_found),
                        else => return err,
                    }
                };
                processed = true;
                break;
            } else {
                return http.respond("Not Found", .not_found);
            }
        }
    }

    http.params = params;
    var path = http.path;
    const q = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    path = path[0..q];

    // TODO - apply the onBefore middlewares
    // TODO - errdefer the onError middlewares

    const method_idx = @intFromEnum(http.method);
    if (!processed) {
        if (current.handlers[method_idx]) |h| {
            h(http) catch |err| {
                log.err(http, err, .internal_server_error);
                try http.respond("Error", .internal_server_error);
            };
            processed = true;
        }
    }

    if (processed) {
        // TODO - run middlewares onAfter
    }

    if (!http.replied) {
        // this is probably a user error - handler didnt bother
        // replying.  So raise a log error and terminate the call anyway
        http.html("") catch {};
        // std.log.warn("request {t} {s} didnt reply - generate auto response", .{ http.method, http.path });
    }

    // TODO - remove this after its done in logging middleware instead
    // format=.none mutes request logging (same as level=.none for the info path).
    if (log.level != .none and log.format != .none) {
        log.info(http);

        switch (log.level) {
            .payload => log.payload(http),
            .signals => log.signals(http),
            .all => {
                log.signals(http);
                log.payload(http);
            },
            else => {},
        }
    }
    if (!processed) {
        return http.respond("Method Not Allowed", .method_not_allowed);
    }
}
