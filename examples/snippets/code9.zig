== svgMorph handler ==

const SVGMorphOptions = struct {
    svgMorph: usize = 1,
};
const opt = blk: {
    break :blk datastar.readSignals(SVGMorphOptions, req) catch break :blk SVGMorphOptions{ .svgMorph = 5 };
};
var sse = try datastar.NewSSESync(req, res);
defer sse.close(res);

for (1..opt.svgMorph + 1) |_| {
    try sse.patchElementsFmt(
        \\<circle id="svg-circle" cx="{}" cy="{}" r="{}" class="fill-red-500 transition-all duration-500" />
    ,
        .{
            // cicrle x y r
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 80),
        },
        .{ .namespace = .svg },
    );
    std.Thread.sleep(std.time.ns_per_ms * 100);
    try sse.patchElementsFmt(
        \\<rect id="svg-square" x="{}" y="{}" width="{}" height="80" class="fill-green-500 transition-all duration-500" />
    ,
        .{
            // rectangle x y width
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 100),
            prng.random().intRangeAtMost(u8, 10, 80),
        },
        .{ .namespace = .svg },
    );
    std.Thread.sleep(std.time.ns_per_ms * 100);
    try sse.patchElementsFmt(
        \\<polygon id="svg-triangle" points="{},{} {},{} {},{}" class="fill-blue-500 transition-all duration-500" />
    ,
        .{
            // polygon random points
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300),
        },
        .{ .namespace = .svg },
    );
    std.Thread.sleep(std.time.ns_per_ms * 200);
}
