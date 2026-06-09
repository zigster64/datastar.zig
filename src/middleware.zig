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

    /// Return a new pipeline that inherits this one's chain plus extra funcs.
    /// The returned Pipeline owns its chain in `allocator`; the caller decides
    /// where the Pipeline value itself lives (stack, heap, arena).
    pub fn extend(self: *const Pipeline, allocator: std.mem.Allocator, funcs: []const Func) !Pipeline {
        var p = Pipeline{ .chain = .empty };
        try p.chain.appendSlice(allocator, self.chain.items);
        try p.chain.appendSlice(allocator, funcs);
        return p;
    }
};
