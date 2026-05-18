const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const pubsub = @import("pubsub");

pub const HTTPServer = @import("server.zig");
pub const HTTPRequest = HTTPServer.HTTPRequest;
pub const Params = @import("params.zig");

pub const Command = enum {
    patchElements,
    patchSignals,
    executeScript,
};

pub const PatchMode = enum {
    inner,
    outer,
    replace,
    prepend,
    append,
    before,
    after,
    remove,
};

pub const NameSpace = enum {
    html,
    svg,
    mathml,
};

pub const PatchElementsOptions = struct {
    mode: PatchMode = .outer,
    selector: ?[]const u8 = null,
    view_transition: bool = false,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
    namespace: NameSpace = .html,
};

pub const PatchSignalsOptions = struct {
    only_if_missing: bool = false,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

pub const ScriptAttributes = struct {
    const Map = std.array_hash_map.String([]const u8);

    map: Map = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ScriptAttributes {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ScriptAttributes) void {
        self.map.deinit(self.allocator);
    }

    pub fn put(self: *ScriptAttributes, key: []const u8, value: []const u8) !void {
        try self.map.put(self.allocator, key, value);
    }

    pub fn count(self: ScriptAttributes) usize {
        return self.map.count();
    }

    pub fn get(self: ScriptAttributes, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn keys(self: ScriptAttributes) [][]const u8 {
        return self.map.keys();
    }

    pub fn values(self: ScriptAttributes) [][]const u8 {
        return self.map.values();
    }
};

pub const ExecuteScriptOptions = struct {
    auto_remove: bool = true, // by default remove the script after use, otherwise explicity set this to false if you want to keep the script loaded
    attributes: ?ScriptAttributes = null,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

pub const DEFAULT_BUFFER_SIZE = 8 * 1024;

// patchElements / patchSignals / executeScript options off the main datastar namespace to return strings
// containing the expanded SSE event stream
pub fn patchElements(arena: Allocator, elements: []const u8, opt: PatchElementsOptions) !void {
    _ = arena;
    _ = elements;
    _ = opt;
}
pub fn patchSignals(arena: Allocator, signals: anytype, opt: PatchSignalsOptions) !void {
    _ = arena;
    _ = signals;
    _ = opt;
}
pub fn executeScript(arena: Allocator, script: []const u8, opt: ExecuteScriptOptions) !void {
    _ = arena;
    _ = script;
    _ = opt;
}

pub const SSEOptions = struct {
    buffer_size: usize = DEFAULT_BUFFER_SIZE,
    sync: bool = false,
    extra_headers: ?[]const std.http.Header = null,
};

pub const SSE = struct {
    stream: *std.http.BodyWriter,
    output_buffer: Io.Writer.Allocating,
    msg: ?Message = null,
    buffer_size: usize = DEFAULT_BUFFER_SIZE,
    sync: bool, // the SSE is operating in sync mode - patches are posted immediately
    chunked: bool = false, // set to true if we want to do the chunking manually ourselves
    io: Io, // what IO implementation are we running under ?
    start_time: std.Io.Timestamp,

    pub fn deinit(self: *SSE) void {
        self.flush() catch {};
        self.output_buffer.deinit();
    }

    pub fn flush(self: *SSE) !void {
        if (self.msg) |*msg| try msg.end();
        const data = self.output_buffer.written();

        // write to the bodyWriter, on flush this gets chunked and forwarded to the final_output
        try self.stream.writer.writeAll(data);

        if (self.sync) {
            // in sync mode, we need to manually trip the end-of-chunk by adding \r\n
            // then tell the BodyWriter to flush itself to the underlying socket connection
            try self.stream.writer.writeAll("\r\n");
            try self.stream.writer.flush();
            try self.stream.flush(); // flushing the BodyWriter does the work of writing to the http_protocol_output
            _ = self.output_buffer.writer.consume(data.len + 2);
            return;
        }
        _ = self.output_buffer.writer.consume(data.len);
    }

    /// close() is used for short lived SSE only
    /// on close(), this will populate the response body the call res.write()
    /// which will output both the header and the body using async IO
    pub fn close(self: *SSE) void {
        self.stream.writer.writeAll(self.body()) catch {};
        self.stream.end() catch {};
    }

    // Sends a keepalive packet on a connected SSE
    // this is a HTML patchElement with no id, sending the time elapsed inside the SSE, in seconds
    pub fn keepalive(self: *SSE) !void {
        const now = Io.Clock.real.now(self.io);
        try self.patchElementsFmt(
            \\<keepalive data-time="{}" />
        , .{self.start_time.durationTo(now).toSeconds()}, .{});
    }

    pub fn writer(self: *Message) ?*Io.Writer {
        if (self.msg) |msg| {
            return &msg.interface;
        }
        return null;
    }

    pub fn buffered(self: *SSE) []u8 {
        return self.output_buffer.written();
    }

    pub fn body(self: *SSE) []u8 {
        self.flush() catch {};
        return self.buffered();
    }

    pub fn patchElements(self: *SSE, elements: []const u8, opt: PatchElementsOptions) !void {
        var msg: Message = .{};
        msg.init(.patchElements, opt, &self.output_buffer.writer);
        try msg.header();
        var w = &msg.interface;
        try w.writeAll(elements);
        try msg.end();
        try self.flush();
    }

    pub fn patchElementsFmt(self: *SSE, comptime elements: []const u8, args: anytype, opt: PatchElementsOptions) !void {
        var msg: Message = .{};
        msg.init(.patchElements, opt, &self.output_buffer.writer);
        try msg.header();
        var w = &msg.interface;
        try w.print(elements, args);
        try msg.end();
        try self.flush();
    }

    pub fn patchElementsWriter(self: *SSE, opt: PatchElementsOptions) *Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.patchElements, opt);
        } else {
            self.msg = .{};
            self.msg.?.init(.patchElements, opt, &self.output_buffer.writer);
        }
        return &self.msg.?.interface;
    }

    pub fn patchSignals(self: *SSE, value: anytype, json_opt: std.json.Stringify.Options, opt: PatchSignalsOptions) !void {
        var msg: Message = .{};
        msg.init(.patchSignals, opt, &self.output_buffer.writer);
        try msg.header();

        const json_formatter = std.json.fmt(value, json_opt);
        try json_formatter.format(&msg.interface);
        try msg.end();
        try self.flush();
    }

    pub fn patchSignalsWriter(self: *SSE, opt: PatchSignalsOptions) *Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.patchSignals, opt);
        } else {
            self.msg = .{};
            self.msg.?.init(.patchSignals, opt, &self.output_buffer.writer);
        }
        return &self.msg.?.interface;
    }

    pub fn executeScript(self: *SSE, script: []const u8, opt: ExecuteScriptOptions) !void {
        try self.flush();
        var msg: Message = .{};
        msg.init(.executeScript, opt, &self.output_buffer.writer);
        var w = &msg.interface;
        try msg.header();
        try w.writeAll(script);
        try msg.end();
        try self.flush();
    }

    pub fn executeScriptFmt(self: *SSE, comptime script: []const u8, args: anytype, opt: ExecuteScriptOptions) !void {
        try self.flush();
        var msg: Message = .{};
        msg.init(.executeScript, opt, &self.output_buffer.writer);
        var w = &msg.interface;
        try msg.header();
        try w.print(script, args);
        try msg.end();
        try self.flush();
    }

    pub fn executeScriptWriter(self: *SSE, opt: ExecuteScriptOptions) *Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.executeScript, opt);
        } else {
            self.msg = .{};
            self.msg.?.init(.executeScript, opt, &self.output_buffer.writer);
        }
        return &self.msg.?.interface;
    }
};

pub fn readSignals(comptime T: type, arena: std.mem.Allocator, req: *std.http.Server.Request) !T {
    switch (req.head.method) {
        .GET => {
            const target = req.head.target;
            const query_idx = std.mem.findScalar(u8, target, '?') orelse return error.MissingDatastarKey;
            const query_string = target[query_idx + 1 ..];

            var it = std.mem.tokenizeScalar(u8, query_string, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "datastar=")) {
                    const encoded_val = pair["datastar=".len..];
                    const decoded = try HTTPServer.urlDecode(arena, encoded_val);

                    return std.json.parseFromSliceLeaky(
                        T,
                        arena,
                        decoded,
                        .{ .ignore_unknown_fields = true },
                    );
                }
            }
            return error.MissingDatastarKey;
        },
        else => {
            const length = req.head.content_length orelse return error.MissingContentLength;
            const body = try arena.alloc(u8, @intCast(length));

            var reader_buffer: [8192]u8 = undefined;
            const reader = req.readerExpectNone(&reader_buffer);

            try reader.readSliceAll(body);
            return std.json.parseFromSliceLeaky(
                T,
                arena,
                body,
                .{ .ignore_unknown_fields = true },
            );
        },
    }
}

pub const Message = struct {
    out_buffer: *Io.Writer = undefined, // an intermediate buffer to write the expanded Datastar event stream to
    input_buffer: [8 * 1024]u8 = undefined,
    started: bool = false,
    command: Command = .patchElements,

    patch_element_options: PatchElementsOptions = .{},
    patch_signal_options: PatchSignalsOptions = .{},
    execute_script_options: ExecuteScriptOptions = .{},

    line_in_progress: bool = false,
    interface: Io.Writer = undefined,

    fn init(m: *Message, comptime command: Command, opt: anytype, out_buffer: *Io.Writer) void {
        m.out_buffer = out_buffer;
        m.command = command;
        m.interface = .{
            .buffer = &m.input_buffer,
            .vtable = &.{
                .drain = &drain,
            },
        };
        switch (command) {
            .patchElements => {
                m.patch_element_options = opt;
            },
            .patchSignals => {
                m.patch_signal_options = opt;
            },
            .executeScript => {
                m.execute_script_options = opt;
            },
        }
    }

    pub fn swapTo(self: *Message, comptime command: Command, opt: anytype) void {
        // always just swap to new command
        self.end() catch {};
        self.command = command;
        switch (command) {
            .patchElements => {
                self.patch_element_options = opt;
            },
            .patchSignals => {
                self.patch_signal_options = opt;
            },
            .executeScript => {
                self.execute_script_options = opt;
            },
        }
    }

    pub fn end(self: *Message) !void {
        var me = &self.interface;
        try me.flush();

        if (self.started) {
            self.started = false;
            self.line_in_progress = false;

            // const w = self.stream_writer;
            const w = self.out_buffer;

            switch (self.command) {
                else => {},
                .executeScript => {
                    // need to close off the script tag !!
                    try w.writeAll("</script>");
                },
            }
            try w.writeAll("\n\n");
            try w.flush();
        }
    }

    pub fn header(self: *Message) !void {
        // var w = self.stream_writer;
        var w = self.out_buffer;

        switch (self.command) {
            .patchElements => {
                try w.writeAll("event: datastar-patch-elements\n");
                if (self.patch_element_options.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (self.patch_element_options.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                if (self.patch_element_options.selector) |s| {
                    try w.print("data: selector {s}\n", .{s});
                }
                if (self.patch_element_options.view_transition) {
                    try w.print("data: useViewTransition true\n", .{});
                }
                const mt = self.patch_element_options.mode;
                switch (mt) {
                    .outer => {},
                    else => try w.print("data: mode {t}\n", .{mt}),
                }
                switch (self.patch_element_options.namespace) {
                    .html => {},
                    .svg => try w.writeAll("data: namespace svg\n"),
                    .mathml => try w.writeAll("data: namespace mathml\n"),
                }
            },
            .patchSignals => {
                try w.writeAll("event: datastar-patch-signals\n");
                if (self.patch_signal_options.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (self.patch_signal_options.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                if (self.patch_signal_options.only_if_missing) {
                    try w.writeAll("data: onlyIfMissing true\n");
                }
            },
            .executeScript => {
                try w.writeAll("event: datastar-patch-elements\n");
                if (self.execute_script_options.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (self.execute_script_options.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                try w.writeAll("data: mode append\ndata: selector body\ndata: elements <script");

                // now add the attribs if any are supplied
                if (self.execute_script_options.attributes) |attribs| {
                    for (attribs.keys(), attribs.values()) |key, value| {
                        try w.print(" {s}=\"{s}\"", .{ key, value });
                    }
                }
                if (self.execute_script_options.auto_remove) {
                    try w.writeAll(" data-effect=\"el.remove()\"");
                }

                try w.writeAll(">");
                self.line_in_progress = true; // because the script content is appended to the script declaration line !!
            },
        }
        self.started = true;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        var self: *Message = @fieldParentPtr("interface", w);
        _ = splat;

        if (!self.started) {
            try self.header();
        }

        var written: usize = 0;

        if (w.end > 0) {
            written += try writeBytesScan(self, self.out_buffer, w.buffered());
        }
        written += try writeBytesScan(self, self.out_buffer, data[0]);

        // TODO - we have the expanded contents in self.out_buffer here - debug that, then send the whole contents of the out_buffer to the self.stream_writer
        return w.consume(written);
    }

    // implementation of writeBytes using SIMD scan of the input to find newlines
    fn writeBytesScan(self: *Message, stream_writer: *Io.Writer, bytes: []const u8) !usize {
        const prefix = switch (self.command) {
            .patchElements, .executeScript => "data: elements ",
            .patchSignals => "data: signals ",
        };

        var rest = bytes;

        while (std.mem.findScalar(u8, rest, '\n')) |idx| {
            const line = rest[0 .. idx + 1];

            // Start a line if we aren't already in one
            if (!self.line_in_progress) {
                try stream_writer.writeAll(prefix);
            }
            try stream_writer.writeAll(line); // includes \n
            self.line_in_progress = false;

            // Advance past the newline, if there is more
            rest = rest[idx + 1 ..];
        }

        if (rest.len > 0) {
            if (!self.line_in_progress) {
                try stream_writer.writeAll(prefix);
                self.line_in_progress = true;
            }
            try stream_writer.writeAll(rest);
        }

        return bytes.len;
    }
};

pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            out[j] = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch input[i];
            i += 3;
        } else if (input[i] == '+') {
            out[j] = ' ';
            i += 1;
        } else {
            out[j] = input[i];
            i += 1;
        }
        j += 1;
    }
    return out[0..j];
}

test "PatchElementsOptions default values" {
    const opts = PatchElementsOptions{};
    try std.testing.expectEqual(PatchMode.outer, opts.mode);
    try std.testing.expect(opts.selector == null);
    try std.testing.expect(opts.view_transition == false);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
    try std.testing.expectEqual(NameSpace.html, opts.namespace);
}

test "PatchSignalsOptions default values" {
    const opts = PatchSignalsOptions{};
    try std.testing.expect(opts.only_if_missing == false);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
}

test "ExecuteScriptOptions default values" {
    const opts = ExecuteScriptOptions{};
    try std.testing.expect(opts.auto_remove == true);
    try std.testing.expect(opts.attributes == null);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
}

test "SSEOptions default values" {
    const opts = SSEOptions{};
    try std.testing.expectEqual(DEFAULT_BUFFER_SIZE, opts.buffer_size);
    try std.testing.expect(opts.sync == false);
}

test "Command enum values" {
    try std.testing.expect(@typeInfo(Command) == .@"enum");
    const cmd1: Command = .patchElements;
    const cmd2: Command = .patchSignals;
    const cmd3: Command = .executeScript;

    try std.testing.expect(cmd1 != cmd2);
    try std.testing.expect(cmd2 != cmd3);
    try std.testing.expect(cmd1 != cmd3);
}

test "PatchMode enum values" {
    const modes = [_]PatchMode{
        .inner,
        .outer,
        .replace,
        .prepend,
        .append,
        .before,
        .after,
        .remove,
    };

    // Just verify all modes are distinct
    for (modes, 0..) |mode1, i| {
        for (modes[i + 1 ..]) |mode2| {
            try std.testing.expect(mode1 != mode2);
        }
    }
}

test "NameSpace enum values" {
    try std.testing.expectEqual(NameSpace.html, NameSpace.html);
    try std.testing.expectEqual(NameSpace.svg, NameSpace.svg);
    try std.testing.expectEqual(NameSpace.mathml, NameSpace.mathml);

    try std.testing.expect(NameSpace.html != NameSpace.svg);
    try std.testing.expect(NameSpace.svg != NameSpace.mathml);
}

test "Message.init sets correct command and options for patchElements" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var msg: Message = undefined;
    const opts = PatchElementsOptions{ .mode = .inner, .selector = "#test" };
    msg.init(.patchElements, opts, &writer);

    try std.testing.expectEqual(Command.patchElements, msg.command);
    try std.testing.expectEqual(PatchMode.inner, msg.patch_element_options.mode);
    try std.testing.expectEqualStrings("#test", msg.patch_element_options.selector.?);
}

test "Message.init sets correct command and options for patchSignals" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var msg: Message = undefined;
    const opts = PatchSignalsOptions{ .only_if_missing = true };
    msg.init(.patchSignals, opts, &writer);

    try std.testing.expectEqual(Command.patchSignals, msg.command);
    try std.testing.expect(msg.patch_signal_options.only_if_missing);
}

test "Message.init sets correct command and options for executeScript" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var msg: Message = undefined;
    const opts = ExecuteScriptOptions{ .auto_remove = false };
    msg.init(.executeScript, opts, &writer);

    try std.testing.expectEqual(Command.executeScript, msg.command);
    try std.testing.expect(!msg.execute_script_options.auto_remove);
}

test "ScriptAttributes can store key-value pairs" {
    var attrs = ScriptAttributes.init(std.testing.allocator);
    defer attrs.deinit();

    try attrs.put("type", "module");
    try attrs.put("async", "true");

    try std.testing.expectEqual(2, attrs.count());
    try std.testing.expectEqualStrings("module", attrs.get("type").?);
    try std.testing.expectEqualStrings("true", attrs.get("async").?);
}

test "PatchElementsOptions with custom values" {
    const opts = PatchElementsOptions{
        .mode = .inner,
        .selector = "#content",
        .view_transition = true,
        .event_id = "evt-123",
        .retry_duration = 5000,
        .namespace = .svg,
    };

    try std.testing.expectEqual(PatchMode.inner, opts.mode);
    try std.testing.expectEqualStrings("#content", opts.selector.?);
    try std.testing.expect(opts.view_transition);
    try std.testing.expectEqualStrings("evt-123", opts.event_id.?);
    try std.testing.expectEqual(5000, opts.retry_duration.?);
    try std.testing.expectEqual(NameSpace.svg, opts.namespace);
}
