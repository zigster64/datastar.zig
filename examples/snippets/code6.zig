== patchSignalsOnlyIfMissing handler ==

var sse = try http.NewSSE();
defer sse.close();

const foo = prng.random().intRangeAtMost(u8, 1, 100);
const bar = prng.random().intRangeAtMost(u8, 1, 100);

try sse.patchSignals(
    .{
        .new_foo = foo,
        .new_bar = bar,
    },
    .{ .only_if_missing = true },
);
