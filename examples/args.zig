//! Shared CLI parsing for the example apps.
//!
//! Examples run on plain HTTP by default, which matches how Datastar apps are
//! normally deployed (behind a reverse proxy that terminates TLS). `--tls`
//! switches the app to serving HTTPS *directly* on the same port, with no proxy
//! in front. There is no dual-port mode: one process, one port, one transport.
//!
//!     ./example_1                                  # http://localhost:8081
//!     ./example_1 --tls                            # https://localhost:8081
//!     ./example_1 --port 9000 --tls \
//!         --cert devcert/cert.pem --key devcert/key.pem
//!
//! Certificate paths default to `devcert/cert.pem` and `devcert/key.pem`,
//! which `tools/make_devcert.sh` writes. The certificate is never generated
//! here or by the library — a missing one is an error, not a prompt.

const std = @import("std");
const datastar = @import("datastar");

pub const Args = struct {
    /// Port to listen on. Defaults to the example's own compiled-in port.
    port: u16,
    /// TLS settings, or null to serve plain HTTP.
    tls: ?datastar.TlsConfig = null,
    /// True when `--help` was requested; the caller prints usage and exits.
    help: bool = false,
};

pub const DEFAULT_CERT = "devcert/cert.pem";
pub const DEFAULT_KEY = "devcert/key.pem";

/// Parse `argv` for the flags the examples share.
///
/// `default_port` is the example's compiled-in port, used when `--port` is
/// absent. Errors are returned rather than printed so the caller controls
/// messaging.
pub fn parse(default_port: u16, program_args: std.process.Args) !Args {
    var out: Args = .{ .port = default_port };

    var port: ?u16 = null;
    var tls_enabled = false;
    var cert: ?[]const u8 = null;
    var key: ?[]const u8 = null;

    var args = std.process.Args.Iterator.init(program_args);
    _ = args.next(); // exe name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const v = args.next() orelse return error.InvalidArgs;
            port = std.fmt.parseInt(u16, v, 10) catch return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--tls")) {
            tls_enabled = true;
        } else if (std.mem.eql(u8, arg, "--cert")) {
            cert = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--key")) {
            key = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out.help = true;
        } else {
            return error.InvalidArgs;
        }
    }

    if (port) |p| out.port = p;

    // --cert/--key without --tls is almost certainly a mistake, and silently
    // ignoring them would leave the app serving plaintext while the operator
    // believes it is encrypted.
    if (!tls_enabled and (cert != null or key != null)) return error.InvalidArgs;

    if (tls_enabled) {
        out.tls = .{
            .cert = cert orelse DEFAULT_CERT,
            .key = key orelse DEFAULT_KEY,
        };
    }
    return out;
}

/// Print the flags every example accepts.
///
/// Goes to stderr via std.debug.print, matching how the examples already report
/// startup problems — that keeps this helper free of any Io plumbing.
pub fn printUsage(default_port: u16) void {
    std.debug.print(
        \\Options:
        \\  --port, -p <N>   Port to listen on (default: {d})
        \\  --tls            Serve HTTPS directly instead of HTTP, on the same port
        \\  --cert <PEM>     Certificate chain (default: {s})
        \\  --key <PEM>      Private key (default: {s})
        \\  --help, -h       Show this help
        \\
    , .{ default_port, DEFAULT_CERT, DEFAULT_KEY });
}

/// Log the URL the server is reachable on, so the scheme is never ambiguous.
pub fn logListenUrl(port: u16, tls: ?datastar.TlsConfig) void {
    const scheme = if (tls != null) "https" else "http";
    std.log.info("Server listening on {s}://localhost:{d}", .{ scheme, port });
    if (tls != null) {
        std.log.info("  (self-signed dev certificate — your browser will warn)", .{});
    }
}


/// Parse args and handle `--help`/bad usage in one step.
///
/// Returns null when the caller should exit cleanly (help was requested) or
/// non-null `Args` otherwise; bad usage returns an error after printing the
/// flags. Collapsing this to one call means a new example cannot forget to
/// honour `--tls` or `--help` — the two things easiest to leave out when
/// copying an existing example.
///
///     const args = (try example_args.init(PORT, init.minimal.args)) orelse return;
pub fn init(default_port: u16, program_args: std.process.Args) !?Args {
    const args = parse(default_port, program_args) catch {
        std.debug.print("unrecognised argument\n", .{});
        printUsage(default_port);
        return error.InvalidArgs;
    };
    if (args.help) {
        printUsage(default_port);
        return null;
    }
    return args;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "defaults to the example's port and plain HTTP" {
    const args = try parse(8081, try testArgs(&.{"prog"}));
    try testing.expectEqual(@as(u16, 8081), args.port);
    try testing.expect(args.tls == null);
}

test "--port overrides the default" {
    const args = try parse(8081, try testArgs(&.{ "prog", "--port", "9000" }));
    try testing.expectEqual(@as(u16, 9000), args.port);
    try testing.expect(args.tls == null);
}

test "--tls fills in the default certificate paths" {
    const args = try parse(8081, try testArgs(&.{ "prog", "--tls" }));
    try testing.expect(args.tls != null);
    try testing.expectEqualStrings(DEFAULT_CERT, args.tls.?.cert);
    try testing.expectEqualStrings(DEFAULT_KEY, args.tls.?.key);
    // Same port: TLS replaces HTTP rather than moving to another port.
    try testing.expectEqual(@as(u16, 8081), args.port);
}

test "--tls keeps an explicit port" {
    const args = try parse(8081, try testArgs(&.{ "prog", "--tls", "--port", "9443" }));
    try testing.expectEqual(@as(u16, 9443), args.port);
    try testing.expect(args.tls != null);
}

test "--tls honours explicit certificate paths" {
    const args = try parse(8081, try testArgs(&.{
        "prog", "--tls", "--cert", "/tmp/c.pem", "--key", "/tmp/k.pem",
    }));
    try testing.expectEqualStrings("/tmp/c.pem", args.tls.?.cert);
    try testing.expectEqualStrings("/tmp/k.pem", args.tls.?.key);
}

test "certificate flags without --tls are rejected" {
    // Silently ignoring these would leave the server in plaintext while the
    // operator believes it is encrypted.
    try testing.expectError(error.InvalidArgs, parse(8081, try testArgs(&.{ "prog", "--cert", "/tmp/c.pem" })));
    try testing.expectError(error.InvalidArgs, parse(8081, try testArgs(&.{ "prog", "--key", "/tmp/k.pem" })));
}

test "unknown flags and bad ports are rejected" {
    try testing.expectError(error.InvalidArgs, parse(8081, try testArgs(&.{ "prog", "--nope" })));
    try testing.expectError(error.InvalidArgs, parse(8081, try testArgs(&.{ "prog", "--port", "notanumber" })));
    try testing.expectError(error.InvalidArgs, parse(8081, try testArgs(&.{ "prog", "--port" })));
}

test "--help is reported to the caller" {
    const args = try parse(8081, try testArgs(&.{ "prog", "--help" }));
    try testing.expect(args.help);
}

test "init() returns null for --help and Args otherwise" {
    try testing.expect((try init(8081, try testArgs(&.{ "prog", "--help" }))) == null);
    const a = (try init(8081, try testArgs(&.{ "prog", "--tls" }))) orelse return error.Unexpected;
    try testing.expect(a.tls != null);
    try testing.expectError(error.InvalidArgs, init(8081, try testArgs(&.{ "prog", "--nope" })));
}

/// Build a `std.process.Args` from a test slice.
///
/// `Args.Vector` is `[]const [*:0]const u8` on POSIX, so the slice has to be
/// collected into NUL-terminated pointers first.
fn testArgs(comptime argv: []const [:0]const u8) !std.process.Args {
    const S = struct {
        var ptrs: [8][*:0]const u8 = undefined;
    };
    if (argv.len > S.ptrs.len) return error.InvalidArgs;
    // String literals already carry a sentinel, so their pointers can be used
    // directly — no separate NUL-terminated storage needed.
    for (argv, 0..) |a, i| S.ptrs[i] = a.ptr;
    return .{ .vector = S.ptrs[0..argv.len] };
}
