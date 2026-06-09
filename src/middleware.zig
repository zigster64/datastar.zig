const std = @import("std");
const HTTPRequest = @import("http_request.zig");

/// Middleware function signature.
/// Receives the request, may mutate it, may set http.halted = true to stop
/// the pipeline. Errors are caught by the dispatch loop and result in a
/// 500 response.
pub const Func = *const fn (req: *HTTPRequest) anyerror!void;

pub const Chain = std.ArrayList(Func);

pub const Middleware = struct {
    chain: Chain,
};
