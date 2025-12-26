== patchSignalsRemove handler ==

const signals_to_remove: []const u8 = req.param("names").?;
var names_iter = std.mem.splitScalar(u8, signals_to_remove, ',');

var sse = try datastar.NewSSE(req, res);
defer sse.close(res);

var w = sse.patchSignalsWriter(.{});

// Formatting of json payload
const first = names_iter.next();
if (first) |val| {
    var curr = val;
    _ = try w.write("{");
    while (names_iter.next()) |next| {
        try w.print("{s}: null, ", .{curr});
        curr = next;
    }
    try w.print("{s}: null }}", .{curr}); 
} else {
    try w.print("{{ {s}: null }}", .{signals_to_remove});
}
