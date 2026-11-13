const std = @import("std");
const Log = @import("log.zig");

pub const Theme = enum {
    classic,
    newwave,
    monochrom,

    pub fn get(self: Theme) Colorizer {
        return switch (self) {
            .classic => Classic.init(),
            .newwave => NewWave.init(),
            .monochrom => Monochrom.init(),
        };
    }
};

pub const Colorizer = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,
    reset: []const u8 = "\x1b[0m",

    pub const VTable = struct {
        statusColor: *const fn (ctx: *const anyopaque, status: std.http.Status) []const u8,
        methodColor: *const fn (ctx: *const anyopaque, method: std.http.Method) []const u8,
        timerColor: *const fn (ctx: *const anyopaque, fast_us: u64, slow_ms: u64, elapsed_ns: i96, detached: bool) []const u8,
        timestampColor: *const fn (ctx: *const anyopaque) []const u8,
        debugColor: *const fn (ctx: *const anyopaque) []const u8,
    };

    // --- Wrappers for easy calling ---

    pub fn statusColor(self: Colorizer, status: std.http.Status) []const u8 {
        return self.vtable.statusColor(self.ptr, status);
    }

    pub fn methodColor(self: Colorizer, method: std.http.Method) []const u8 {
        return self.vtable.methodColor(self.ptr, method);
    }

    pub fn timerColor(self: Colorizer, fast_us: u64, slow_ms: u64, elapsed_ns: i96, detached: bool) []const u8 {
        return self.vtable.timerColor(self.ptr, fast_us, slow_ms, elapsed_ns, detached);
    }

    pub fn timestampColor(self: Colorizer) []const u8 {
        return self.vtable.timestampColor(self.ptr);
    }
    pub fn debugColor(self: Colorizer) []const u8 {
        return self.vtable.debugColor(self.ptr);
    }
};

/// Classic 4bit old school terminal colors
pub const Classic = struct {
    // Since these functions are pure/stateless, we use a dummy 0-size struct for the ptr
    var dummy_state: u8 = 0;

    pub fn init() Colorizer {
        return .{
            .ptr = &dummy_state,
            .vtable = &vtable,
        };
    }

    const vtable = Colorizer.VTable{
        .statusColor = statusColorImpl,
        .methodColor = methodColorImpl,
        .timerColor = timerColorImpl,
        .timestampColor = timestampColor,
        .debugColor = debugColor,
    };

    fn statusColorImpl(_: *const anyopaque, status: std.http.Status) []const u8 {
        const code = @backingInt(status);
        return switch (code) {
            200...299 => "\x1b[1;32m", // Green bold
            300...399 => "\x1b[1;36m", // Cyan bold
            400...499 => "\x1b[1;33m", // Yellow bold
            500...599 => "\x1b[1;31m", // Red bold
            else => "\x1b[0m",
        };
    }

    fn methodColorImpl(_: *const anyopaque, method: std.http.Method) []const u8 {
        return switch (method) {
            .GET => "\x1b[1;30;45m", // purple bg
            .DELETE => "\x1b[1;30;41m", // red bg
            else => "\x1b[1;30;46m", // cyan bg
        };
    }

    fn timerColorImpl(_: *const anyopaque, fast_us: u64, slow_ms: u64, elapsed_ns: i96, detached: bool) []const u8 {
        const elapsed_us = @divTrunc(elapsed_ns, 1000);
        const elapsed_ms = @divTrunc(elapsed_us, 1000);

        if (2 * elapsed_us <= fast_us) return "\x1b[1;96m";
        if (elapsed_us <= fast_us) return "\x1b[32m";
        if (elapsed_ms >= 2 * slow_ms) return if (detached) "\x1b[41;30m" else "\x1b[0;91m";
        if (elapsed_ms >= slow_ms) return if (detached) "\x1b[41;30m" else "\x1b[31m";
        return "\x1b[33m";
    }

    fn timestampColor(_: *const anyopaque) []const u8 {
        return "\x1b[0;35m";
    }
    fn debugColor(_: *const anyopaque) []const u8 {
        return "\x1b[36m";
    }
};

/// Fancy 8 bit color theme
pub const NewWave = struct {
    var dummy_state: u8 = 0;

    pub fn init() Colorizer {
        return .{ .ptr = &dummy_state, .vtable = &vtable };
    }

    const vtable = Colorizer.VTable{
        .statusColor = statusColorImpl,
        .methodColor = methodColorImpl,
        .timerColor = timerColorImpl,
        .timestampColor = timestampColor,
        .debugColor = debugColor,
    };

    fn statusColorImpl(_: *const anyopaque, status: std.http.Status) []const u8 {
        const code = @backingInt(status);
        return switch (code) {
            200...299 => "\x1b[38;5;158m",
            300...399 => "\x1b[38;5;146m",
            400...499 => "\x1b[38;5;134m",
            500...599 => "\x1b[48;5;134;1;30m",
            else => "\x1b[0m", // Reset/White
        };
    }

    fn methodColorImpl(_: *const anyopaque, method: std.http.Method) []const u8 {
        return switch (method) {
            .GET => "\x1b[48;5;024m",
            .POST => "\x1b[48;5;061m",
            .PATCH, .PUT => "\x1b[48;5;023m",
            .DELETE => "\x1b[48;5;089m",
            else => "\x1b[48;5;055m",
        };
    }

    fn timerColorImpl(_: *const anyopaque, fast_us: u64, slow_ms: u64, elapsed_ns: i96, detached: bool) []const u8 {
        const elapsed_us = @divTrunc(elapsed_ns, 1000);
        const elapsed_ms = @divTrunc(elapsed_us, 1000);

        // is it fast ?
        if (2 * elapsed_us <= fast_us) return "\x1b[38;5;118m";
        if (elapsed_us <= fast_us) return "\x1b[38;5;120m";

        // is it too slow ?
        if (elapsed_ms >= 2 * slow_ms) return if (detached) "\x1b[48;5;105;1;30m" else "\x1b[38;5;202;1m";
        if (elapsed_ms >= slow_ms) return if (detached) "\x1b[48;5;075;1;30m" else "\x1b[38;5;175m";

        return "\x1b[38;5;108m";
    }

    fn timestampColor(_: *const anyopaque) []const u8 {
        return "\x1b[38;5;103m";
    }
    fn debugColor(_: *const anyopaque) []const u8 {
        return "\x1b[48;5;238m";
    }
};

/// Sophisticated and Expressive B+W Monochrom theme for the discerning artist
pub const Monochrom = struct {
    var dummy_state: u8 = 0;

    pub fn init() Colorizer {
        return .{ .ptr = &dummy_state, .vtable = &vtable };
    }

    const vtable = Colorizer.VTable{
        .statusColor = statusColorImpl,
        .methodColor = methodColorImpl,
        .timerColor = timerColorImpl,
        .timestampColor = timestampColor,
        .debugColor = debugColor,
    };

    fn statusColorImpl(_: *const anyopaque, status: std.http.Status) []const u8 {
        const code = @backingInt(status);
        return switch (code) {
            200...299 => "\x1b[38;5;245m",
            300...399 => "\x1b[38;5;251m",
            400...499 => "\x1b[38;5;215m",
            500...599 => "\x1b[48;5;202m",
            else => "\x1b[0m", // Reset/White
        };
    }

    fn methodColorImpl(_: *const anyopaque, method: std.http.Method) []const u8 {
        return switch (method) {
            .GET => "\x1b[48;5;239m",
            .POST => "\x1b[48;5;242m",
            .DELETE => "\x1b[48;5;088m",
            else => "\x1b[48;5;245m",
        };
    }

    fn timerColorImpl(_: *const anyopaque, fast_us: u64, slow_ms: u64, elapsed_ns: i96, detached: bool) []const u8 {
        const elapsed_us = @divTrunc(elapsed_ns, 1000);
        const elapsed_ms = @divTrunc(elapsed_us, 1000);

        // is it fast ?
        if (2 * elapsed_us <= fast_us) return "\x1b[38;5;118m";
        if (elapsed_us <= fast_us) return "\x1b[38;5;120m";

        // is it too slow ?
        if (elapsed_ms >= 2 * slow_ms) return if (detached) "\x1b[48;5;244;1;30m" else "\x1b[38;5;202;1m";
        if (elapsed_ms >= slow_ms) return if (detached) "\x1b[48;5;250;1;30m" else "\x1b[38;5;175m";

        return "\x1b[38;5;108m";
    }

    fn timestampColor(_: *const anyopaque) []const u8 {
        return "\x1b[38;5;242m";
    }

    fn debugColor(_: *const anyopaque) []const u8 {
        return "\x1b[48;5;238;1m\x1b[0;38;5;217m";
    }
};
