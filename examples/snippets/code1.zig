== text/html handler ==

return try http.html(
    try std.fmt.allocPrint(http.arena,
        \\<p id="text-html">This is update number {d}</p>
    , .{getCountAndIncrement()}),
);
