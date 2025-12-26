== patchElements handler ==

var buf: [1024]u8 = undefined;
var sse = try datastar.NewSSE(req, &buf);
defer sse.close();

try sse.patchElementsFmt(
    \\<p id="mf-patch">This is update number {d}</p>
,
    .{getCountAndIncrement()},
    .{},
);
