== patchSignals handler ==

try res.json(.{
    .fooj = prng.random().intRangeAtMost(u8, 0, 255),
    .barj = prng.random().intRangeAtMost(u8, 0, 255),
}, .{});
