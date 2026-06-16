== mathMorph handler ==

prng.seed(@intCast(std.time.timestamp()));

opt = try http.readSignals(struct{mathmlMorph: usize = 1});

var sse = try http.NewSSESync();
defer sse.close();

if (opt.mathmlMorph == 1) {
    try sse.patchElementsFmt(
        \\<mn id="math-factor" class="text-red-500 font-bold">{}</mn>
    ,
        .{prng.random().intRangeAtMost(u16, 2, 22)},
        .{ .namespace = .mathml, .view_transition = true },
    );
    try sse.patchSignals(.{ .mathmlMorph = 1 }, .{});
    return;
}

var delay: u64 = 100;
for (1..opt.mathmlMorph + 1) |i| {
    switch (mathMLs.len - 3) {
        1 => delay = 2000,
        2 => delay = 1600,
        3 => delay = 800,
        4 => delay = 400,
        else => delay = 200,
    }
    if (i > (mathMLs.len - 3)) {}

    const r = prng.random().intRangeAtMost(u8, 1, mathMLs.len);
    try sse.patchElements(mathMLs[r - 1], .{ .namespace = .mathml });
    try http.io.sleep(.fromMilliseconds(delay), .real);
}
try sse.patchSignals(.{ .mathmlMorph = 1 }, .{});
