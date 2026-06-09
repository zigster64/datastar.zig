const std = @import("std");
const HTTPRequest = @import("http_request.zig");

/// Middleware function signature.
pub const Func = *const fn (req: *HTTPRequest) anyerror!void;

pub const Chain = std.ArrayList(Func);

/// A named pipeline of middleware functions. Created via server.pipeline()
/// and assigned to the server (global), route groups, or individual routes.
/// Pipelines accumulate: a request to /admin/dashboard picks up the global
/// pipeline + the /admin group pipeline + any route-level pipeline.
pub const Pipeline = struct {
    chain: Chain = .empty,
};
