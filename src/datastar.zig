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

pub const ScriptAttributes = std.StringArrayHashMap([]const u8);

pub const ExecuteScriptOptions = struct {
    auto_remove: bool = true, // by default remove the script after use, otherwise explicity set this to false if you want to keep the script loaded
    attributes: ?ScriptAttributes = null,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

pub const SSEOptions = struct {
    buffer_size: usize = 16 * 1024,
};

pub const HTTPRequest = struct {
    req: *std.http.Server.Request,
    io: Io,
    arena: std.mem.Allocator,
};

pub const SSE = struct {
    stream: *std.http.BodyWriter,
    output_buffer: std.Io.Writer.Allocating,
    msg: ?Message = null,
    buffer_size: usize = 16 * 1024,
    arena: ?std.mem.Allocator,

    pub fn deinit(self: *SSE) void {
        self.flush() catch {};
        self.output_buffer.deinit();
    }

    pub fn flush(self: *SSE) !void {
        if (self.msg) |*msg| try msg.end();
        const data = self.output_buffer.written();
        if (data.len == 0) return;

        try self.stream.writer.writeAll(data);
        try self.stream.flush();
        _ = self.output_buffer.writer.consume(data.len);
    }

    /// close() is used for short lived SSE only
    /// on close(), this will populate the response body the call res.write()
    /// which will output both the header and the body using async IO
    pub fn close(self: *SSE) void {
        self.stream.writer.writeAll(self.body()) catch {};
        self.stream.end() catch {};
    }

    pub fn writer(self: *Message) ?*std.Io.Writer {
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
        var msg: Message = undefined;
        msg.init(.patchElements, opt, &self.output_buffer.writer);
        try msg.header();
        var w = &msg.interface;
        try w.writeAll(elements);
        try msg.end();
        try self.flush();
    }

    pub fn patchElementsFmt(self: *SSE, comptime elements: []const u8, args: anytype, opt: PatchElementsOptions) !void {
        var msg: Message = undefined;
        msg.init(.patchElements, opt, &self.output_buffer.writer);
        try msg.header();
        var w = &msg.interface;
        try w.print(elements, args);
        try msg.end();
        try self.flush();
    }

    pub fn patchElementsWriter(self: *SSE, opt: PatchElementsOptions) *std.Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.patchElements, opt);
        } else {
            var msg: Message = undefined;
            msg.init(.patchElements, opt, &self.output_buffer.writer);
            self.msg = msg;
        }
        return &self.msg.?.interface;
    }

    pub fn patchSignals(self: *SSE, value: anytype, json_opt: std.json.Stringify.Options, opt: PatchSignalsOptions) !void {
        var msg: Message = undefined;
        msg.init(.patchSignals, opt, &self.output_buffer.writer);
        try msg.header();

        const json_formatter = std.json.fmt(value, json_opt);
        try json_formatter.format(&msg.interface);
        try msg.end();
        try self.flush();
    }

    pub fn patchSignalsWriter(self: *SSE, opt: PatchSignalsOptions) *std.Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.patchSignals, opt);
        } else {
            var msg: Message = undefined;
            msg.init(.patchSignals, opt, &self.output_buffer.writer);
            self.msg = msg;
        }
        return &self.msg.?.interface;
    }

    pub fn executeScript(self: *SSE, script: []const u8, opt: ExecuteScriptOptions) !void {
        try self.flush();
        var msg: Message = undefined;
        msg.init(.executeScript, opt, &self.output_buffer.writer);
        var w = &msg.interface;
        try msg.header();
        try w.writeAll(script);
        try msg.end();
        try self.flush();
    }

    pub fn executeScriptFmt(self: *SSE, comptime script: []const u8, args: anytype, opt: ExecuteScriptOptions) !void {
        try self.flush();
        var msg: Message = undefined;
        msg.init(.executeScript, opt, &self.output_buffer.writer);
        var w = &msg.interface;
        try msg.header();
        try w.print(script, args);
        try msg.end();
        try self.flush();
    }

    pub fn executeScriptWriter(self: *SSE, opt: ExecuteScriptOptions) *std.Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.executeScript, opt);
        } else {
            var msg: Message = undefined;
            msg.init(.executeScript, opt, &self.output_buffer.writer);
            self.msg = msg;
        }
        return &self.msg.?.interface;
    }
};

pub fn NewSSE(http: HTTPRequest, buf: []u8) !SSE {
    return NewSSEOpt(http, buf, .{});
}

pub fn NewSSEOpt(http: HTTPRequest, buf: []u8, opt: SSEOptions) !SSE {
    var res = try http.req.respondStreaming(
        buf,
        .{ .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        } } },
    );
    const allocating_writer = blk: {
        if (opt.buffer_size == 0) break :blk std.Io.Writer.Allocating.init(http.arena);
        break :blk std.Io.Writer.Allocating.initCapacity(http.arena, opt.buffer_size) catch std.Io.Writer.Allocating.init(http.arena);
    };
    return SSE{
        .stream = &res,
        .arena = http.arena,
        .output_buffer = allocating_writer,
        .buffer_size = opt.buffer_size,
    };
}

pub fn NewSSEFromStream(stream: *std.http.BodyWriter, allocator: std.mem.Allocator) SSE {
    const allocating_writer = std.Io.Writer.Allocating.initCapacity(allocator, 16 * 1024) catch std.Io.Writer.Allocating.init(allocator);
    return SSE{
        .stream = stream,
        .output_buffer = allocating_writer,
        .buffer_size = 0,
    };
}

pub const Message = struct {
    // stream: std.net.Stream,
    stream_writer: *std.Io.Writer, // the final destination where the output gets sent
    out_buffer: *std.Io.Writer, // an intermediate buffer to write the expanded Datastar event stream to
    input_buffer: [8 * 1024]u8 = undefined,
    started: bool = false,
    command: Command = .patchElements,

    patch_element_options: PatchElementsOptions = .{},
    patch_signal_options: PatchSignalsOptions = .{},
    execute_script_options: ExecuteScriptOptions = .{},

    line_in_progress: bool = false,
    interface: std.Io.Writer,

    fn init(m: *Message, comptime command: Command, opt: anytype, out_buffer: *std.Io.Writer) void {
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

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
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
    fn writeBytesScan(self: *Message, stream_writer: *std.Io.Writer, bytes: []const u8) !usize {
        const prefix = switch (self.command) {
            .patchElements, .executeScript => "data: elements ",
            .patchSignals => "data: signals ",
        };

        var rest = bytes;

        while (std.mem.indexOfScalar(u8, rest, '\n')) |idx| {
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

pub fn readSignals(comptime T: type, req: anytype) !T {
    switch (req.method) {
        .GET => {
            const query = try req.query();
            const signals = query.get("datastar") orelse return error.MissingDatastarKey;
            return std.json.parseFromSliceLeaky(
                T,
                req.arena,
                signals,
                .{ .ignore_unknown_fields = true },
            );
        },
        else => {
            const body = req.body() orelse return error.MissingBody;
            return std.json.parseFromSliceLeaky(
                T,
                req.arena,
                body,
                .{ .ignore_unknown_fields = true },
            );
        },
    }
}

const SessionType = ?[]const u8;
const StreamList = std.ArrayList(std.net.Stream);

pub fn Subscribers(comptime T: type) type {
    return struct {
        gpa: Allocator,
        app: T,
        subs: Subscriptions,
        stream_topics: StreamTopicMap,
        mutex: std.Thread.Mutex = .{},

        const Self = @This();
        const Subscription = struct {
            stream: std.net.Stream,
            action: Callback(T),
            session: SessionType = null,
        };

        // A collection of subscriptions for each topic
        const Subscriptions = std.StringHashMap(std.ArrayList(Subscription));

        // A map of which topics each stream is subscribed to, for quick lookup by stream
        const StreamTopicMap = std.AutoHashMap(std.net.Stream, std.ArrayList([]const u8));

        pub fn init(gpa: Allocator, ctx: T) !Self {
            return .{
                .gpa = gpa,
                .app = ctx,
                .subs = Subscriptions.init(gpa),
                .stream_topics = StreamTopicMap.init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.subs) |s| {
                for (s) |sub| {
                    sub.stream.close() catch {};
                    if (sub.session != null) {
                        self.gpa.free(sub.session);
                    }
                }
                s.deinit();
            }
            self.sub.deinit();
            for (self.stream_topics) |st| {
                for (st.items) |topic| {
                    self.gpa.free(topic);
                }
            }
            self.stream_map.deinit();
        }

        pub fn debugState(self: *Self, desc: []const u8) void {
            {
                std.debug.print("Subscription States - {s}\n", .{desc});
                var iterator = self.subs.iterator();
                while (iterator.next()) |entry| {
                    std.debug.print("  Topic: {s} Streams: [ ", .{entry.key_ptr.*});
                    for (entry.value_ptr.*.items) |sub| {
                        std.debug.print(" {d}", .{sub.stream.handle});
                        if (sub.session) |ss| {
                            std.debug.print(":{s}", .{ss});
                        }
                    }
                    std.debug.print(" ]\n", .{});
                }
            }

            {
                var iterator = self.stream_topics.iterator();
                while (iterator.next()) |entry| {
                    std.debug.print("  Stream: {d} Topics: [", .{entry.key_ptr.*.handle});

                    for (entry.value_ptr.*.items) |topic| {
                        std.debug.print(" {s}", .{topic});
                    }
                    std.debug.print(" ]\n", .{});
                }
            }
        }

        pub fn subscribe(self: *Self, topic: []const u8, stream: std.net.Stream, func: Callback(T)) !void {
            return self.subscribeSession(topic, stream, func, null);
        }

        pub fn subscribeSession(self: *Self, topic: []const u8, stream: std.net.Stream, func: Callback(T), session: SessionType) !void {
            self.mutex.lock();
            defer {
                self.debugState("after subscribe session");
                self.mutex.unlock();
            }

            // check first that the given stream isnt already subscribed to this topic !!
            {
                if (self.stream_topics.get(stream)) |topics| {
                    for (topics.items) |subscribed_topic| {
                        if (std.mem.eql(u8, topic, subscribed_topic)) {
                            std.debug.print("Stream {d} is already subscribed to topic {s} ... ignoring.!\n", .{ stream.handle, topic });
                            return;
                        }
                    }
                }
            }

            // on first subscription, try to write the output first
            // if it works, then we add them to the subscriber list
            std.debug.print("calling the initial subscribe callback function for topic {s} on stream {d}\n", .{ topic, stream.handle });
            @call(.auto, func, .{ self.app, stream, session }) catch |err| {
                stream.close();
                return err;
            };

            var new_sub = Subscription{
                .stream = stream,
                .action = func,
            };
            if (session) |sv| {
                // we need to dupe the session passed in, because its often just a stack variable
                // pay careful attention to freeing this dupe whenever the session is terminated
                // which can happen during publish and it detects that the connection has closed
                new_sub.session = try self.gpa.dupe(u8, sv);
            }
            if (self.subs.getPtr(topic)) |subs| {
                try subs.append(self.gpa, new_sub);
            } else {
                var new_sub_list: std.ArrayList(Subscription) = .empty;
                try new_sub_list.append(self.gpa, new_sub);
                try self.subs.put(topic, new_sub_list);
            }

            const topic_copy = try self.gpa.dupe(u8, topic);
            if (self.stream_topics.getPtr(stream)) |topics| {
                try topics.append(self.gpa, topic_copy);
            } else {
                var new_topic_list: std.ArrayList([]const u8) = .empty;
                try new_topic_list.append(self.gpa, topic_copy);
                try self.stream_topics.put(stream, new_topic_list);
            }

            // // Debug output the current state of the maps
            // std.debug.print("Updated subs on topic {s} :\n", .{topic});
            // for (self.subs.get(topic).?.items, 0..) |s, ii| {
            //     std.debug.print("  {d} - {any} Session {?s}\n", .{ ii, s.stream, s.session });
            // }
            // std.debug.print("Updated topics by stream {d} :\n", .{stream.handle});
            // for (self.stream_topics.get(stream).?.items, 0..) |t, ii| {
            //     std.debug.print("  {d} - {s}\n", .{ ii, t });
            // }
            std.debug.print("Total {d} topics and {d} streams tracked\n", .{ self.subs.count(), self.stream_topics.count() });
        }

        fn purge(self: *Self, streams: StreamList) void {
            if (streams.items.len == 0) return;

            const t1 = std.time.microTimestamp();
            defer {
                self.debugState("after purge session");
                std.debug.print("Purge took {d}μs\n", .{std.time.microTimestamp() - t1});
            }

            // get the topics that the stream was subscribed to
            // so we can limit the number of subscription lists to look through
            for (streams.items) |stream| {
                if (self.stream_topics.getPtr(stream)) |topics| {
                    for (topics.items) |topic| {
                        // remove the stream from the subscriptions for this topic
                        if (self.subs.getPtr(topic)) |subs| {
                            // traverse the list backwards so its safe to drop elements during traversal
                            var i: usize = subs.items.len;
                            while (i > 0) {
                                i -= 1;
                                const sub = subs.items[i];
                                for (streams.items) |st| {
                                    if (sub.stream.handle == st.handle) {
                                        _ = subs.swapRemove(i);
                                        std.debug.print("Closing subscriber Stream {d} on topic {s}\n", .{ sub.stream.handle, topic });
                                    }
                                }
                            }
                        }
                        // the topic was duped in SubscribeSession, so get rid of it now
                        self.gpa.free(topic);
                    }
                    topics.deinit(self.gpa);
                }
                std.debug.print("Removing topic list for Stream {d}\n", .{stream.handle});
                _ = self.stream_topics.remove(stream);
            }
        }

        pub fn publish(self: *Self, topic: []const u8) !void {
            return self.publishSession(topic, null);
        }

        pub fn publishSession(self: *Self, topic: []const u8, session: SessionType) !void {
            self.mutex.lock();
            var dead_streams: StreamList = .empty;
            defer {
                if (dead_streams.items.len > 0) {
                    self.purge(dead_streams);
                }
                dead_streams.deinit(self.gpa);
                self.mutex.unlock();
            }

            // std.debug.print("publish on topic {s} for session {?s}\n", .{ topic, session });
            if (self.subs.getPtr(topic)) |subs| {
                // traverse the list backwards, so its safe to drop elements during the traversal
                var i: usize = subs.items.len;
                while (i > 0) {
                    i -= 1;
                    const sub = subs.items[i];
                    if (sub.session == null) {
                        // we publish everything, without passing a session value
                        // std.debug.print("calling the publish callback for topic {s} on stream {d}\n", .{ topic, sub.stream.handle });
                        @call(.auto, sub.action, .{ self.app, sub.stream, null }) catch |err| {
                            try dead_streams.append(self.gpa, sub.stream);
                            std.debug.print(" 💀 Stream {d} to be removed because {}\n", .{ sub.stream.handle, err });
                        };
                    } else {
                        if (session) |sv| {
                            // only publish subs where the session value matches what we ask for
                            if (sub.session) |ss| {
                                if (std.mem.eql(u8, sv, ss)) {
                                    // std.debug.print("calling the publish callback for topic {s} on stream {d} with session {s}\n", .{ topic, sub.stream.handle, ss });
                                    @call(.auto, sub.action, .{ self.app, sub.stream, ss }) catch |err| {
                                        if (sub.session) |subsession| self.gpa.free(subsession);
                                        try dead_streams.append(self.gpa, sub.stream);
                                        std.debug.print(" 💀 Stream {d} to be removed because {}\n", .{ sub.stream.handle, err });
                                    };
                                }
                            }
                        } else {
                            // publish all
                            // std.debug.print("calling the publish callback for topic {s} on stream {d} with session {?s}\n", .{ topic, sub.stream.handle, sub.session });
                            @call(.auto, sub.action, .{ self.app, sub.stream, sub.session }) catch |err| {
                                if (sub.session) |subsession| self.gpa.free(subsession);
                                try dead_streams.append(self.gpa, sub.stream);
                                std.debug.print(" 💀 Stream {d} to be removed because {}\n", .{ sub.stream.handle, err });
                            };
                        }
                    }
                }

                // std.debug.print("Remaining subs on topic {s} :\n", .{topic});
                // for (subs.items, 0..) |s, ii| {
                //     std.debug.print("  {d} - {any} Session {?s}\n", .{ ii, s.stream, s.session });
                // }
            }
        }
    };
}

pub fn Callback(comptime ctx: type) type {
    if (ctx == void) {
        return *const fn (std.net.Stream) anyerror!void;
    }
    return *const fn (ctx, std.net.Stream, SessionType) anyerror!void;
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
