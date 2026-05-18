const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const rlim_t = posix.rlim_t;
const builtin = @import("builtin");

const pubsub = @import("pubsub");

const datastar = @import("datastar.zig");
pub const HTTPRequest = @import("http_request.zig");
const Log = @import("log.zig");
const Params = @import("params.zig");
const Router = @import("router.zig");
const RouteHandler = Router.RouteHandler;

// probably gonna get deprecated soon ?

const Server = @This();

io: Io,
allocator: Allocator,
process_init: std.process.Init,
arena: std.heap.ArenaAllocator,
server: Io.net.Server = undefined,
router: *Router,
ctx: ?*anyopaque = null,
log: Log = undefined,
middleware: ?*Middleware = null,
watch: bool = false,
fd_limit: ?FDLimit = null,

group: Io.Group = .init,
pool_fibers: ?*Io.Evented = null,
io_fibers: ?Io = null,

pub const Concurrency = enum {
    threads,
    fibers,
};

// Config params for creating a server
pub const Config = struct {
    address: ?[]const u8 = null,
    port: u16 = 8080,
    log: Log = .{},
    io: ?Io = null,
    allocator: ?Allocator = null,
    watch: bool = false,
    fd_limit: ?FDLimit = null,
    threads: u64 = 32,
    // Debug mode consumes a lot more stack, due to carrying extra debug info
    stack_size: usize = if (builtin.mode == .Debug) 16 * 1024 * 1024 else 2 * 1024 * 1024,
    sse_concurrency: Concurrency = .threads,
};

// FD limit configuration
pub const FDLimit = enum(rlim_t) {
    max = std.math.maxInt(rlim_t),
    _,

    pub fn limited(n: rlim_t) FDLimit {
        return @enumFromInt(n);
    }
};

/// init a Server from a juicy main init, and a config
pub fn init(process_init: std.process.Init, config: Config) !*Server {
    const io = config.io orelse process_init.io;
    const allocator = config.allocator orelse process_init.gpa;

    // if address is not defined / null - then listen on all addresses
    const address = if (config.address) |addr|
        try Io.net.IpAddress.parseIp4(addr, config.port)
    else
        try Io.net.IpAddress.parseIp6("::", config.port);

    var self: *Server = try allocator.create(Server);
    errdefer allocator.destroy(self);

    self.pool_fibers = null;
    self.io_fibers = null;
    // if (config.sse_concurrency == .fibers) {
    //     self.pool_fibers = try allocator.create(std.Io.Kqueue);
    //     const pool_fibers = self.pool_fibers.?;
    //     try std.Io.Kqueue.init(pool_fibers, allocator, .{});
    //     self.io_fibers = pool_fibers.io();
    //     std.log.debug("🧵 HTTP Server Using Kqueue Fibers for handlers (Experimental)", .{});
    // } else {
    std.log.debug("🤹‍♂️ HTTP Server Using OS Threads for handlers", .{});
    // }

    self.* = .{
        .process_init = process_init,
        .server = try address.listen(io, .{ .reuse_address = true }),
        .router = undefined,
        .log = config.log,
        .io = io,
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .watch = config.watch,
        .fd_limit = config.fd_limit,
    };
    errdefer self.arena.deinit();
    self.router = try Router.init(self.arena.allocator());
    return self;
}

pub fn useContext(self: *Server, ctx: *anyopaque) void {
    self.ctx = ctx;
}

pub fn deinit(self: *Server) void {
    self.arena.deinit();
    self.allocator.destroy(self);
}

pub fn concurrent(self: *Server, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Io.ConcurrentError!void {
    return self.group.concurrent(self.io, function, args);
}

pub fn run(self: *Server) !void {
    self.setFdLimits() catch |err| std.log.err("Failed to raise FD limits {}", .{err});
    defer self.group.cancel(self.io);

    if (self.watch) {
        self.group.concurrent(self.io, Server.watchLoop, .{self}) catch |err| {
            std.log.err("Failed to init watch loop for rebooting {}", .{err});
        };
    }

    while (true) {
        const conn = try self.server.accept(self.io);
        if (self.io_fibers) |io_fibers| {
            _ = io_fibers.concurrent(handleConnection, .{ self, conn }) catch |err| {
                std.log.err("spawn handler in fiber error {}\n", .{err});
                conn.close(self.io);
                continue; // ah well failed - try another one, dont exit the loop yet
            };
        } else self.group.concurrent(self.io, handleConnection, .{ self, conn }) catch |err| {
            std.log.err("spawn handler error {}\n", .{err});
            conn.close(self.io);
            continue; // ah well failed - try another one, dont exit the loop yet
        };
    }
}

fn nonBlocking(conn: Io.net.Stream) !void {
    const fd = conn.socket.handle;
    const fl_raw = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    var fl_flags: usize = @intCast(fl_raw);
    fl_flags |= @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

    while (true) {
        const rc = posix.system.fcntl(fd, posix.F.SETFL, fl_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            .CANCELED => return error.Canceled,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn handleConnection(self: *Server, conn: Io.net.Stream) Io.Cancelable!void {
    // dont do this until Kqueue is complete please
    // nonBlocking(conn) catch return error.Canceled;

    var close_conn = true;
    defer if (close_conn) conn.close(self.io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = conn.reader(self.io, &read_buffer);
    var writer = conn.writer(self.io, &write_buffer);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch break;

        var http = HTTPRequest{
            .io = self.io,
            .io_fibers = self.io_fibers,
            .ctx = self.ctx,
            .req = &request,
            .arena = arena.allocator(),
            .params = .{},
            .path = arena.allocator().dupe(u8, request.head.target) catch return error.Canceled,
            .method = request.head.method,
            .timer = .now(self.io, std.Io.Clock.real),
            .log = self.log,
        };

        self.router.dispatch(&http) catch return;

        // Anything asking for a Sync SSE connection will detach the request from this inner loop
        // this is because any SSE created over this connection will be treated as the last action
        // in this connection. The trigger for the browser is text/event-stream + chunked encoding
        if (http.detach) {
            // if we are running with fibers, then the long SSE handler is a fiber that we have
            // handed over to, so we dont want to close this connection, thats the job of the
            // handler instead
            if (http.disowned) close_conn = false;
            break;
        }
    }
}

/// watch the executable for changes, and if found, then reboot the server
/// only intended for local development !!!
fn watchLoop(self: *Server) Io.Cancelable!void {
    const args = self.process_init.minimal.args;
    const self_path = std.process.executablePathAlloc(self.io, self.allocator) catch |err| {
        std.log.err("WatchLoop terminating - failed to get path of executable {}", .{err});
        return error.Canceled;
    };
    defer self.allocator.free(self_path);
    std.log.warn("♻️  Monitoring Executable File {s}", .{self_path});

    var initial_inode: u64 = 0;
    var initial_mtime: Io.Timestamp = .zero;

    // wait around till the inital inode is available
    while (true) {
        const stat = std.Io.Dir.cwd().statFile(self.io, self_path, .{}) catch |err| {
            std.log.err("WatchLoop error - Path {s} cannot stat: {}", .{ self_path, err });
            self.io.sleep(.fromSeconds(1), .real) catch {};
            continue;
        };
        initial_inode = stat.inode;
        initial_mtime = stat.mtime;
        break;
    }

    while (true) {
        self.io.sleep(.fromSeconds(2), .real) catch |err| {
            std.log.err("WatchLoop terminating - failed to sleep for 2 seconds ?? {}", .{err});
            return error.Canceled;
        };

        const stat = std.Io.Dir.cwd().statFile(self.io, self_path, .{}) catch |err| {
            std.log.err("Path {s} cannot stat: {}", .{ self_path, err });
            continue;
        };

        const inode_changed = (stat.inode != initial_inode);
        const mtime_changed = (stat.mtime.toMilliseconds() > initial_mtime.toMilliseconds());

        if (inode_changed or mtime_changed) {
            std.log.warn("♻️ Binary Changed - Reboot", .{});

            const argv = self.allocator.alloc([]const u8, args.vector.len) catch |err| {
                std.log.err("WatchLoop terminating - failed to allocate argv {}", .{err});
                return error.Canceled;
            };
            defer self.allocator.free(argv);
            for (args.vector, 0..) |arg, i| {
                argv[i] = std.mem.span(arg);
            }

            const replace_error = std.process.replace(self.io, .{ .argv = argv });
            // if we get here - it means we failed to replace
            std.log.err("WatchLoop terminating - failed to replace executable {}", .{replace_error});
            return error.Canceled;
        }
    }
}

fn setFdLimits(self: *Server) !void {
    if (self.fd_limit) |fd_limit| {
        // Get current limits
        const system_limit = try posix.getrlimit(.NOFILE);
        var limit = @intFromEnum(fd_limit);

        switch (builtin.os.tag) {
            // tested on Linux as well - was concerned because the rlimit types on BSDs are
            // just u64, but linux has a struct type instead. Works though
            .macos, .freebsd, .openbsd, .linux => {
                // system limit has simple u64s
                if (limit > system_limit.max) limit = system_limit.max;

                if (limit == system_limit.cur) {
                    return std.log.warn("🚀 Process FD limit currently at {} - no change", .{system_limit.cur});
                }
                std.log.warn("🚀 Process FD limit currently at {} - change to {}", .{ system_limit.cur, limit });

                posix.setrlimit(.NOFILE, .{ .cur = limit, .max = system_limit.max }) catch |err| {
                    std.log.err("🚀 Failed to bump limits: {}", .{err});
                    return err;
                };
            },
            else => return,
        }
    }
}

// Middleware functions take a HTTPRequest, and return
// - err if there is an error, no more processing
// - true = continue, hand over to the next middleware in the chain
// - false = do not continue .. response has been sent already, no more middleware
const MiddlewareFunc = *const fn (req: HTTPRequest) anyerror!bool;
const Middlewares = std.ArrayList(MiddlewareFunc);

const Middleware = struct {
    before: ?*Middlewares = null,
    after: ?*Middlewares = null,
    err: ?*Middlewares = null,
};

// Regiter onBefore middleware
pub fn onBefore(self: *HTTPRequest, func: MiddlewareFunc) !void {
    if (self.middleware == null) {
        self.middleware = try self.arena.create(Middleware);
        self.middleware.* = .{};
    }
    std.debug.assert(self.middleware != null);
    if (self.middleware.before == null) {
        self.middleware.before = try self.arena.create(Middlewares);
        self.middleware.before = .{};
    }
    std.debug.assert(self.middleware.before != null);
    try self.middleware.before.?.append(self.arena, func);
}

// Register onAfter middleware
pub fn onAfter(self: *HTTPRequest, func: MiddlewareFunc) !void {
    if (self.middleware == null) {
        self.middleware = try self.arena.create(Middleware);
        self.middleware.* = .{};
    }
    std.debug.assert(self.middleware != null);
    if (self.middleware.after == null) {
        self.middleware.after = try self.arena.create(Middlewares);
        self.middleware.after = .{};
    }
    std.debug.assert(self.middleware.after != null);
    try self.middleware.after.?.append(self.arena, func);
}

// Register onError middleware
pub fn onError(self: *HTTPRequest, func: MiddlewareFunc) !void {
    if (self.middleware == null) {
        self.middleware = try self.arena.create(Middleware);
        self.middleware.* = .{};
    }
    std.debug.assert(self.middleware != null);
    if (self.middleware.err == null) {
        self.middleware.err = try self.arena.create(Middlewares);
        self.middleware.err = .{};
    }
    std.debug.assert(self.middleware.err != null);
    try self.middleware.err.?.append(self.arena, func);
}

const TestApp = struct { data: i32 };

fn testAppHandler(_: *HTTPRequest) !void {
    std.debug.print("test app handler\n", .{});
}

fn testHandler(_: *HTTPRequest) !void {
    std.debug.print("test handler\n", .{});
}

fn testGetHandler(_: *HTTPRequest) !void {
    std.debug.print("test get handler\n", .{});
}

fn testPostHandler(_: *HTTPRequest) !void {
    std.debug.print("test post handler\n", .{});
}

test "Params.get returns correct value" {
    var params = Params{};
    params.names[0] = "id";
    params.values[0] = "123";
    params.names[1] = "name";
    params.values[1] = "alice";
    params.count = 2;

    try std.testing.expectEqualStrings("123", params.get("id").?);
    try std.testing.expectEqualStrings("alice", params.get("name").?);
    try std.testing.expect(params.get("missing") == null);
}

test "Router can add and store routes" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.get("/test", testAppHandler);

    // Verify the route was added
    try std.testing.expect(router.root.children.items.len == 1);
    try std.testing.expectEqualStrings("test", router.root.children.items[0].segment);
}

test "Router handles parameterized routes" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.get("/user/:id", testAppHandler);

    // Navigate to /user
    try std.testing.expect(router.root.children.items.len == 1);
    try std.testing.expectEqualStrings("user", router.root.children.items[0].segment);

    // Check :id parameter
    const user_node = router.root.children.items[0];
    try std.testing.expect(user_node.children.items.len == 1);
    try std.testing.expect(user_node.children.items[0].is_param);
    try std.testing.expectEqualStrings("id", user_node.children.items[0].param_name);
}

test "Router deduplicates identical paths" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.get("/test", testGetHandler);
    router.post("/test", testPostHandler);

    // Should only have one child node for "/test", with both GET and POST handlers
    try std.testing.expect(router.root.children.items.len == 1);
    try std.testing.expectEqualStrings("test", router.root.children.items[0].segment);

    const test_node = router.root.children.items[0];
    const get_idx = @intFromEnum(std.http.Method.GET);
    const post_idx = @intFromEnum(std.http.Method.POST);

    try std.testing.expect(test_node.handlers[get_idx] != null);
    try std.testing.expect(test_node.handlers[post_idx] != null);
}

test "urlDecode handles percent encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try datastar.urlDecode(arena.allocator(), "hello%20world");
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "urlDecode handles plus signs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try datastar.urlDecode(arena.allocator(), "hello+world");
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "urlDecode handles mixed encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try datastar.urlDecode(arena.allocator(), "foo+bar%3Dbaz");
    try std.testing.expectEqualStrings("foo bar=baz", decoded);
}
