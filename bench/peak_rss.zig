//! Peak-RSS / allocation analysis for the patchElements streaming change.
//!
//! Why a separate child per (mode × size × placement):
//!   `getrusage(RUSAGE_SELF).ru_maxrss` is a process-lifetime *peak*. Once a
//!   scenario has touched a high-water mark, later scenarios in the same
//!   process cannot report a lower peak. Spawning isolates each run.
//!
//! Metrics (all three; none alone is enough):
//!   - peak RSS delta  — OS-visible resident growth from framing
//!   - bytes requested — CountingAllocator, the figure that actually moves
//!                       when the allocation strategy changes.
//!                       ArenaAllocator.queryCapacity grows geometrically and
//!                       can make a real win look like a regression, so it is
//!                       not the primary figure.
//!   - arena capacity  — secondary; useful for the "fragment already in arena"
//!                       geometry but not the primary verdict
//!
//! Modes:
//!   ladder   — Allocating-from-zero, the pre-change shape (measured ~7× peak)
//!   alloc    — patchElementsAlloc (pre-sized writer buffer)
//!   stream   — patchElements(writer) into a discarding sink (default API)
//!   baseline — fragment only, no framing (sanity / floor)
//!
//! Run:  zig build peak-rss

const std = @import("std");
const builtin = @import("builtin");
const datastar = @import("datastar");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Mode = enum { baseline, ladder, alloc, stream };
const Placement = enum {
    /// Fragment already occupies the request arena (the amplifying shape).
    in_arena,
    /// Fragment lives outside; framing is the only arena consumer.
    outside,
};

const sizes = [_]usize{
    64 * 1024,
    512 * 1024,
    1024 * 1024,
    4 * 1024 * 1024,
    4_732_869, // a real large-fragment size observed in a rendered list
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // argv[0]=exe; optional: run <mode> <placement> <size>
    if (args.len >= 5 and std.mem.eql(u8, args[1], "run")) {
        const mode = std.meta.stringToEnum(Mode, args[2]) orelse return error.BadMode;
        const placement = std.meta.stringToEnum(Placement, args[3]) orelse return error.BadPlacement;
        const size = try std.fmt.parseInt(usize, args[4], 10);
        try runChild(init.io, init.gpa, mode, placement, size);
        return;
    }

    try runParent(init.io, init.gpa, args[0]);
}

fn runParent(io: Io, gpa: Allocator, self_exe: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;

    try out.writeAll(
        \\# patchElements peak memory
        \\# each row is an isolated child process (ru_maxrss is a lifetime peak)
        \\# rss_delta = peak_rss_after_frame - peak_rss_after_fragment  (bytes)
        \\# req_bytes = bytes requested through the counting allocator during framing
        \\# arena_cap = ArenaAllocator.queryCapacity after framing (chunk geometry)
        \\#
        \\mode       placement   fragment     out_len   rss_delta   req_bytes  arena_cap  rss/frag  req/frag
        \\
    );

    for (sizes) |size| {
        for (std.meta.tags(Placement)) |placement| {
            for (std.meta.tags(Mode)) |mode| {
                try runOne(io, gpa, out, self_exe, mode, placement, size);
            }
        }
        try out.writeAll("\n");
    }

    // Spotlight the large in-arena shape so the table does not bury the verdict.
    try out.writeAll(
        \\# verdict @ fragment=4732869 in_arena (large fragment already in arena)
        \\#   metric          ladder        alloc       stream
        \\
    );
    const verdict_size: usize = 4_732_869;
    var ladder_req: usize = 0;
    var alloc_req: usize = 0;
    var stream_req: usize = 0;
    var ladder_arena: usize = 0;
    var alloc_arena: usize = 0;
    var stream_arena: usize = 0;
    var ladder_rss: usize = 0;
    var alloc_rss: usize = 0;
    var stream_rss: usize = 0;

    // Re-run just the three modes for the summary (cheap relative to clarity).
    for ([_]Mode{ .ladder, .alloc, .stream }) |mode| {
        const row = try measureChild(io, gpa, self_exe, mode, .in_arena, verdict_size);
        switch (mode) {
            .ladder => {
                ladder_req = row.req_bytes;
                ladder_arena = row.arena_cap;
                ladder_rss = row.rss_delta;
            },
            .alloc => {
                alloc_req = row.req_bytes;
                alloc_arena = row.arena_cap;
                alloc_rss = row.rss_delta;
            },
            .stream => {
                stream_req = row.req_bytes;
                stream_arena = row.arena_cap;
                stream_rss = row.rss_delta;
            },
            .baseline => unreachable,
        }
    }
    try out.print(
        \\#   req_bytes   {d:>12} {d:>12} {d:>12}
        \\#   arena_cap   {d:>12} {d:>12} {d:>12}
        \\#   rss_delta   {d:>12} {d:>12} {d:>12}
        \\#   req/frag        {d:>8.2}     {d:>8.2}     {d:>8.2}
        \\#
        \\# stream is the win: zero framing allocation in the request arena.
        \\# alloc beats ladder on requested bytes but still pays ArenaAllocator
        \\# 1.5×(prev+request) node geometry when the fragment is already resident.
        \\# rss_delta understates retained arena pages on Darwin when growth remaps;
        \\# prefer req_bytes / arena_cap for the allocator-level verdict.
        \\
    ,
        .{
            ladder_req,
            alloc_req,
            stream_req,
            ladder_arena,
            alloc_arena,
            stream_arena,
            ladder_rss,
            alloc_rss,
            stream_rss,
            @as(f64, @floatFromInt(ladder_req)) / @as(f64, @floatFromInt(verdict_size)),
            @as(f64, @floatFromInt(alloc_req)) / @as(f64, @floatFromInt(verdict_size)),
            @as(f64, @floatFromInt(stream_req)) / @as(f64, @floatFromInt(verdict_size)),
        },
    );
    try out.flush();
}

const ChildRow = struct {
    out_len: usize,
    rss_delta: usize,
    req_bytes: usize,
    arena_cap: usize,
};

fn measureChild(
    io: Io,
    gpa: Allocator,
    self_exe: []const u8,
    mode: Mode,
    placement: Placement,
    size: usize,
) !ChildRow {
    const mode_s = @tagName(mode);
    const place_s = @tagName(placement);
    var size_buf: [32]u8 = undefined;
    const size_s = try std.fmt.bufPrint(&size_buf, "{d}", .{size});

    var child = try std.process.spawn(io, .{
        .argv = &.{ self_exe, "run", mode_s, place_s, size_s },
        .stdout = .pipe,
        .stderr = .inherit,
        .request_resource_usage_statistics = true,
    });
    defer if (child.stdout) |*f| f.close(io);

    var line_buf: [512]u8 = undefined;
    var stdout_file = child.stdout.?;
    var file_reader = stdout_file.reader(io, &line_buf);
    const line = try file_reader.interface.takeDelimiterExclusive('\n');

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const out_len = try std.fmt.parseInt(usize, it.next() orelse return error.BadChildOutput, 10);
    const rss_frag = try std.fmt.parseInt(usize, it.next() orelse return error.BadChildOutput, 10);
    const rss_frame = try std.fmt.parseInt(usize, it.next() orelse return error.BadChildOutput, 10);
    const req_bytes = try std.fmt.parseInt(usize, it.next() orelse return error.BadChildOutput, 10);
    const arena_cap = try std.fmt.parseInt(usize, it.next() orelse return error.BadChildOutput, 10);
    _ = gpa;
    return .{
        .out_len = out_len,
        .rss_delta = rss_frame -| rss_frag,
        .req_bytes = req_bytes,
        .arena_cap = arena_cap,
    };
}

fn runOne(
    io: Io,
    gpa: Allocator,
    out: *Io.Writer,
    self_exe: []const u8,
    mode: Mode,
    placement: Placement,
    size: usize,
) !void {
    const row = try measureChild(io, gpa, self_exe, mode, placement, size);
    const rss_ratio = if (size == 0) 0 else @as(f64, @floatFromInt(row.rss_delta)) / @as(f64, @floatFromInt(size));
    const req_ratio = if (size == 0) 0 else @as(f64, @floatFromInt(row.req_bytes)) / @as(f64, @floatFromInt(size));

    try out.print("{s:<10} {s:<10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>8.2} {d:>8.2}\n", .{
        @tagName(mode),
        @tagName(placement),
        size,
        row.out_len,
        row.rss_delta,
        row.req_bytes,
        row.arena_cap,
        rss_ratio,
        req_ratio,
    });
}

fn runChild(io: Io, gpa: Allocator, mode: Mode, placement: Placement, size: usize) !void {
    var counting: CountingAllocator = .{ .child = gpa };
    const counted = counting.allocator();

    var arena_inst = std.heap.ArenaAllocator.init(counted);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Build the fragment. For in_arena it is the first (large) arena resident;
    // for outside it lives on the GPA and is not an arena consumer.
    const fragment = switch (placement) {
        .in_arena => try arena.alloc(u8, size),
        .outside => try gpa.alloc(u8, size),
    };
    defer if (placement == .outside) gpa.free(fragment);
    @memset(fragment, 'x');
    if (size > 0) {
        fragment[0] = '<';
        fragment[size - 1] = '>';
        if (size > 1000) fragment[1000] = '\n';
        if (size > 100_000) fragment[100_000] = '\n';
    }

    // Force the pages resident so ru_maxrss reflects the fragment before framing.
    touchPages(fragment);
    const rss_after_frag = peakRssBytes();

    // Reset counters so req_bytes is framing-only.
    counting.bytes = 0;
    counting.count = 0;
    const arena_before = arena_inst.queryCapacity();

    var out_len: usize = 0;
    switch (mode) {
        .baseline => {},
        .ladder => {
            // Pre-fix shape: stream into an Allocating writer that grows from
            // zero in the request arena (doubling ladder; free is a no-op).
            var buf: Io.Writer.Allocating = .init(arena);
            try datastar.patchElements(&buf.writer, fragment, .{});
            out_len = buf.written().len;
        },
        .alloc => {
            const framed = try datastar.patchElementsAlloc(arena, fragment, .{});
            out_len = framed.len;
        },
        .stream => {
            // Discarding sink: framing must not retain an intermediate copy.
            var discard_buf: [4096]u8 = undefined;
            var discarding: Io.Writer.Discarding = .init(&discard_buf);
            try datastar.patchElements(&discarding.writer, fragment, .{});
            out_len = discarding.fullCount();
        },
    }

    const rss_after_frame = peakRssBytes();
    const arena_after = arena_inst.queryCapacity();
    const arena_grown = arena_after -| arena_before;

    var stdout_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("{d} {d} {d} {d} {d}\n", .{
        out_len,
        rss_after_frag,
        rss_after_frame,
        counting.bytes,
        arena_grown,
    });
    try stdout.interface.flush();
}

fn touchPages(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += std.heap.pageSize()) {
        buf[i] = buf[i];
    }
    if (buf.len > 0) buf[buf.len - 1] = buf[buf.len - 1];
}

fn peakRssBytes() usize {
    // RUSAGE_SELF == 0 on Linux and Darwin.
    const ru = std.posix.getrusage(0);
    return switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .serenity => @as(usize, @intCast(ru.maxrss)) * 1024,
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => @as(usize, @intCast(ru.maxrss)),
        else => @as(usize, @intCast(ru.maxrss)),
    };
}

/// Counts bytes actually requested. Prefer this over ArenaAllocator.queryCapacity
/// for allocation-strategy verdicts (queryCapacity reports chunk geometry).
const CountingAllocator = struct {
    child: Allocator,
    bytes: usize = 0,
    count: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.bytes += len;
        self.count += 1;
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) self.bytes += new_len - buf.len;
        return self.child.rawResize(buf, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) self.bytes += new_len - buf.len;
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }
    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
};
