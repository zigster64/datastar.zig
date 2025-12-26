== patchSignalsOnlyIfMissing handler ==

var sse = try datastar.NewSSE(req, res);
defer sse.close(res);

const foo = prng.random().intRangeAtMost(u8, 1, 100);
const bar = prng.random().intRangeAtMost(u8, 1, 100);

try sse.patchSignals(
    .{
        .new_foo = foo,
        .new_bar = bar,
    },
    .{},
    .{ .only_if_missing = true },
);
