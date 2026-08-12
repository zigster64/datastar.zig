const std = @import("std");
const Themes = @import("themes.zig");
const HTTPRequest = @import("http_request.zig");

const Log = @This();

pub const Level = enum {
    none,
    path,
    payload,
    signals,
    all,
};

pub const Format = enum {
    none,
    json,
    terminal,
};

level: Level = .path,
format: Format = .terminal,
theme: Themes.Theme = .classic,

// units here are microseconds
slow_ms: u64 = 200, // 200ms
fast_us: u64 = 20, // 20us

pub fn info(log: Log, http: *HTTPRequest) void {
    // format=.none is a mute switch. Historically only level=.none skipped
    // logging in the router while format=.none still ran this path (clocks +
    // std.log.info) every request — a ~3× throughput cliff on the bench.
    if (log.format == .none) return;

    const elapsed_ns: i96 = http.timer.untilNow(http.io, std.Io.Clock.real).toNanoseconds();
    const c = log.theme.get();
    const payload_size: []const u8 = switch (http.method) {
        .PUT, .PATCH, .POST, .DELETE => if (http.req.head.content_length) |l|
            // No semicolon here: the result of allocPrint flows to the if
            std.fmt.allocPrint(http.arena, " ({} bytes)", .{l}) catch ""
        else
            "", // Result of the else flows to the if

        else => "",
    };

    std.log.info(
        "{s}{s}{s} {s}{}{s} {s}{t:<6}{s} {s:<60} {s}{:>8}{s} μs{s}",
        .{
            c.timestampColor(),
            formatTimeAlloc(http),
            c.reset,
            c.statusColor(http.status),
            @intFromEnum(http.status),
            c.reset,
            c.methodColor(http.method),
            http.method,
            c.reset,
            http.getPathOnly(),
            c.timerColor(log.fast_us, log.slow_ms, elapsed_ns, http.detach),
            @divTrunc(elapsed_ns, 1_000),
            c.reset,
            payload_size,
        },
    );
}

pub fn debug(_: Log, comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
}

pub fn payload(self: Log, http: *HTTPRequest) void {
    if (self.format == .none) return;
    if (http.req_payload) |p| {
        const c = self.theme.get();
        self.debug(" {t} >\n{s}{s}{s}", .{ http.method, c.debugColor(), p, c.reset });
    }
}

pub fn signals(self: Log, http: *HTTPRequest) void {
    if (self.format == .none) return;
    if (http.query()) |query_params| {
        if (http.method == .GET and query_params.len > 0) {
            const buf: []u8 = "";
            var decode_params = http.arena.dupe(u8, query_params) catch blk: {
                break :blk buf;
            };
            const start_index = if (std.mem.findScalar(u8, decode_params, '=')) |idx| idx + 1 else 0;
            decode_params = decode_params[start_index..];
            _ = std.mem.replaceScalar(u8, decode_params, '+', ' ');
            std.log.debug(" > Signals: {s}", .{
                std.Uri.percentDecodeInPlace(decode_params),
            });
        }
    }
}

/// Post-handler logging — called by the dispatch loop after the handler
/// completes. Logs the request line, timing, and optional payload/signals
/// based on the configured log level.
pub fn logRequest(http: *HTTPRequest) void {
    const log = http.log;
    switch (log.level) {
        .none => {},
        else => {
            log.info(http);
            switch (log.level) {
                .payload => log.payload(http),
                .signals => log.signals(http),
                .all => {
                    log.signals(http);
                    log.payload(http);
                },
                else => {},
            }
        },
    }
}

pub fn err(_: Log, http: *HTTPRequest, error_value: anyerror, status: std.http.Status) void {
    std.log.err("{} {t} - {t} {s}", .{ error_value, status, http.method, http.path });
}

/// Returns a formatted string "YYYY-MM-DD HH:MM:SS.UUUUUU"
/// Caller owns the returned slice.
pub fn formatTimeAlloc(http: *HTTPRequest) []u8 {
    const micros_utc_ts: std.Io.Timestamp = std.Io.Clock.real.now(http.io);
    const micros_utc: u64 = @intCast(micros_utc_ts.toMilliseconds());
    const seconds: u47 = @intCast(@divTrunc(micros_utc, std.time.ms_per_s));
    const micros = micros_utc % std.time.ms_per_s;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const epoch_day = std.time.epoch.EpochDay{ .day = @divTrunc(seconds, std.time.epoch.secs_per_day) };
    const epoch_yearday = epoch_day.calculateYearDay();
    const epoch_monthday = epoch_yearday.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    // Extract Date Components
    const year = epoch_yearday.year;
    const month = epoch_monthday.month;
    const day = epoch_monthday.day_index;

    // Extract Time Components
    const hour = day_seconds.getHoursIntoDay();
    const min = day_seconds.getMinutesIntoHour();
    const sec = day_seconds.getSecondsIntoMinute();

    // return std.fmt.allocPrint(http.arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
    return std.fmt.allocPrint(http.arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year,
        month,
        day,
        hour,
        min,
        sec,
        micros,
    }) catch "";
}

test "format=.none mutes info payload and signals without touching timer" {
    // format=.none must return before reading http.timer / http.io — otherwise
    // muted benches still pay a clock syscall every request.
    var req: HTTPRequest = undefined;
    req.method = .GET;
    req.path = "/";
    req.req_payload = "secret";
    // Intentionally leave timer/io/arena undefined; mute must not touch them.
    const log: Log = .{ .format = .none, .level = .all };
    log.info(&req);
    log.payload(&req);
    log.signals(&req);
}
