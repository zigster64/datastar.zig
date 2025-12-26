== patchSignals handler ==

const FoojBarjResponse = struct {
    fooj: u8,
    barj: u8,
};

// Tokamak can return a struct, which gets automatically converted to JSON response
fn jsonSignals() !FoojBarjResponse {
    const t1 = std.time.microTimestamp();

    // this will set the following signals, by just outputting a JSON response rather than an SSE response
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);

    defer {
        const t2 = std.time.microTimestamp();
        logz.info().string("event", "patchSignals").int("fooj", foo).int("barj", bar).int("elapsed (μs)", t2 - t1).log();
    }

    return .{
        .fooj = foo,
        .barj = bar,
    };
}
