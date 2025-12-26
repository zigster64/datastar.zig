== text/html handler ==

res.content_type = .HTML;
res.body = try std.fmt.allocPrint(
    res.arena,
    \\<p id="mf-patch">This is update number {d}</p>
,
    .{getCountAndIncrement()},
);
