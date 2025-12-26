== mathMorph handler ==

prng.seed(@intCast(std.time.timestamp()));
const MathMorphOptions = struct {
    mathmlMorph: usize = 1,
};
const opt = blk: {
    break :blk datastar.readSignals(MathMorphOptions, req) catch break :blk MathMorphOptions{ .mathmlMorph = 1 };
};
var sse = try datastar.NewSSESync(req, res);
defer sse.close(res);

if (opt.mathmlMorph == 1) {
    try sse.patchElementsFmt(
        \\<mn id="math-factor" class="text-red-500 font-bold">{}</mn>
    ,
        .{prng.random().intRangeAtMost(u16, 2, 22)},
        .{ .namespace = .mathml, .view_transition = true },
    );
    try sse.patchSignals(.{ .mathmlMorph = 1 }, .{}, .{});
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
    std.Thread.sleep(std.time.ns_per_ms * delay);
}
try sse.patchSignals(.{ .mathmlMorph = 1 }, .{}, .{});
