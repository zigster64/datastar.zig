const std = @import("std");
const HTTPRequest = @import("http_request.zig");
const Params = @import("params.zig");
const Pipeline = @import("middleware.zig").Pipeline;

const Io = std.Io;
const Router = @This();
pub const RouteHandlerFn = *const fn (req: *HTTPRequest) anyerror!void;

/// Options for route registration via getOpt / postOpt etc.
pub const RouteOpts = struct {
    /// Pipeline applied only to this route, after group and global pipelines.
    pipeline: ?*const Pipeline = null,
    /// Run handler in a fiber (long-lived SSE).
    fiber: bool = false,
};

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
    /// Pipeline for route groups — applies to this node and all descendants.
    group_pipeline: ?*const Pipeline = null,
    /// Per-route (per-method) pipelines.
    route_pipelines: [std.enums.values(std.http.Method).len]?*const Pipeline = [_]?*const Pipeline{null} ** std.enums.values(std.http.Method).len,

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

/// GET request with options (pipeline, fiber).
pub fn getOpt(self: *Router, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) void {
    self.addOpt(.GET, path, handler, opts) catch unreachable;
}

/// POST request with options.
pub fn postOpt(self: *Router, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) void {
    self.addOpt(.POST, path, handler, opts) catch unreachable;
}

/// PUT request with options.
pub fn putOpt(self: *Router, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) void {
    self.addOpt(.PUT, path, handler, opts) catch unreachable;
}

/// PATCH request with options.
pub fn patchOpt(self: *Router, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) void {
    self.addOpt(.PATCH, path, handler, opts) catch unreachable;
}

/// DELETE request with options.
pub fn deleteOpt(self: *Router, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) void {
    self.addOpt(.DELETE, path, handler, opts) catch unreachable;
}

/// Long-lived SSE GET with options.
pub fn sseOpt(self: *Router, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) void {
    var o = opts;
    o.fiber = true;
    self.addOpt(.GET, path, handler, o) catch unreachable;
}

/// Assign a pipeline to a route prefix so it applies to all descendant routes.
/// Creates intermediate radix-tree nodes as needed.
pub fn group(self: *Router, prefix: []const u8, pipeline: *const Pipeline) !void {
    var current = self.root;
    var it = std.mem.tokenizeScalar(u8, prefix, '/');
    while (it.next()) |seg| {
        const is_param = std.mem.startsWith(u8, seg, ":");
        var found: ?*Node = null;
        for (current.children.items) |child| {
            if (is_param and child.is_param) { found = child; break; }
            if (!is_param and std.mem.eql(u8, child.segment, seg)) { found = child; break; }
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
    current.group_pipeline = pipeline;
    std.log.debug("  > GROUP {s} ({d} middleware)", .{ prefix, pipeline.chain.items.len });
}

pub fn addOpt(self: *Router, method: std.http.Method, path: []const u8, handler: RouteHandlerFn, opts: RouteOpts) !void {
    var current = self.root;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        const is_param = std.mem.startsWith(u8, seg, ":");
        var found: ?*Node = null;
        for (current.children.items) |child| {
            if (is_param and child.is_param) { found = child; break; }
            if (!is_param and std.mem.eql(u8, child.segment, seg)) { found = child; break; }
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
    const mi = @intFromEnum(method);
    current.handlers[mi] = handler;
    current.fiber[mi] = opts.fiber;
    current.route_pipelines[mi] = opts.pipeline;
    std.log.debug("  > {t} {s}{s}{s}", .{
        method,
        path,
        if (opts.fiber) " (Long SSE)" else "",
        if (opts.pipeline != null) " [piped]" else "",
    });
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

    // Track visited nodes for pipeline accumulation (max 16 path segments).
    var visited_nodes: [16]*Node = undefined;
    var visited_len: usize = 0;
    visited_nodes[0] = self.root; // root is always visited
    visited_len = 1;

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

        if (match) |m| {
            current = m;
            if (visited_len < visited_nodes.len) { visited_nodes[visited_len] = current; visited_len += 1; }
        } else {
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

    // Pipeline accumulation: global → group (root→leaf) → route-level.
    // Run middleware from each source in order; halt stops the chain.
    const middleware_mod = @import("middleware.zig");
    const method_idx = @intFromEnum(http.method);

    // 1. Global pipeline (set via server.usePipeline)
    if (http._global_pipeline) |gp_ptr| {
        const gp: *const middleware_mod.Pipeline = @ptrCast(@alignCast(gp_ptr));
        for (gp.chain.items) |mw| {
            if (http.halted) break;
            mw(http) catch |err| {
                log.err(http, err, .internal_server_error);
                try http.respond("Internal Server Error", .internal_server_error);
                return;
            };
        }
    }

    // 2. Group pipelines from visited nodes (root-first, leaf-last)
    if (!http.halted) {
        for (visited_nodes[0..visited_len]) |node| {
            if (node.group_pipeline) |gp| {
                for (gp.chain.items) |mw| {
                    if (http.halted) break;
                    mw(http) catch |err| {
                        log.err(http, err, .internal_server_error);
                        try http.respond("Internal Server Error", .internal_server_error);
                        return;
                    };
                }
            }
        }
    }

    // 3. Route-level pipeline (set via getOpt / postOpt etc.)
    if (!http.halted) {
        if (current.route_pipelines[method_idx]) |rp| {
            for (rp.chain.items) |mw| {
                if (http.halted) break;
                mw(http) catch |err| {
                    log.err(http, err, .internal_server_error);
                    try http.respond("Internal Server Error", .internal_server_error);
                    return;
                };
            }
        }
    }

    // 4. Run the route handler
    if (!http.halted and !processed) {
        if (current.handlers[method_idx]) |h| {
            h(http) catch |err| {
                log.err(http, err, .internal_server_error);
                try http.respond("Error", .internal_server_error);
            };
            processed = true;
        }
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
