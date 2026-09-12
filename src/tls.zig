//! Optional TLS termination for the Datastar HTTP server.
//!
//! Datastar apps normally run behind a reverse proxy, which terminates TLS.
//! This module is for the other case: serving HTTPS directly, with no proxy.
//! It is off unless the caller asks for it (`Config.tls`), and it never
//! generates or invents a certificate — the caller supplies one, and an
//! unloadable certificate is a startup error rather than a silent fallback to
//! plaintext or to a self-signed cert.
//!
//! BearSSL arrives as the `.bearssl` dependency in `build.zig.zon` (a wrapper
//! that supplies a build.zig for upstream BearSSL, which ships a Makefile).
//! It is a C library, so everything here is a thin, explicit wrapper: no hidden
//! allocation, no global state. Zig's stdlib has no TLS *server* (only the
//! client side of std.crypto), which is why the C dependency exists at all.
//!
//! Three BearSSL rules drive the whole file and are all easy to get wrong:
//!
//!   1. `br_skey_decoder_push` takes **DER**, not PEM. Feed it PEM text and it
//!      reports `BR_ERR_X509_UNEXPECTED` (41), which looks like a broken key
//!      rather than a wrong encoding. We decode the PEM envelope with
//!      `br_pem_decoder` first.
//!   2. The engine needs a caller-owned I/O buffer, sized `BR_SSL_BUFSIZE_BIDI`
//!      (~33 KB) per direction. Far too big for a thread stack, so it is
//!      heap-allocated per connection — allocate it once per connection on the
//!      heap, and remember that every accepted connection costs that much.
//!   3. `allocator.free` requires the slice the allocator handed out. The
//!      certificate list is a sub-slice of a larger allocation, so freeing the
//!      sub-slice is undefined behaviour; `Credentials` keeps the original.

const std = @import("std");

pub const c = @cImport({
    @cInclude("bearssl.h");
});

/// AES-256-GCM with ECDHE and a SHA-384 PRF. BearSSL's `full` profiles also
/// enable CBC and CCM suites; this constant exists so the negotiated suite is
/// pinned to one strong option rather than depending on profile ordering.
pub const server_context_size = @sizeOf(c.br_ssl_server_context);
pub const io_buffer_size = c.BR_SSL_BUFSIZE_BIDI;

/// Caller-supplied TLS settings, as passed in `Server.Config.tls`.
pub const Config = struct {
    /// Path to a PEM certificate bundle. For a chain, put the leaf first and
    /// each issuer after it — the order clients need them in.
    cert: []const u8,
    /// Path to the PEM private key. PKCS#8 or PKCS#1, RSA or EC.
    key: []const u8,
};

/// A loaded certificate chain plus private key, ready for handshakes.
///
/// The DER blobs are owned by this struct and must outlive every server
/// context built from it: BearSSL keeps pointers into the certificate chain
/// and key, it does not copy them.
pub const Credentials = struct {
    /// The certificate list handed to BearSSL. This is a *sub-slice* of
    /// `certs_alloc`; only `certs_alloc` may be freed.
    certs: []c.br_x509_certificate,
    /// The allocation backing `certs` at full length. Kept so `deinit` frees
    /// what the allocator actually handed out — `allocator.free` requires the
    /// original slice, not a sub-slice of it.
    certs_alloc: []c.br_x509_certificate,
    rsa_key: ?*const c.br_rsa_private_key = null,
    ec_key: ?*const c.br_ec_private_key = null,
    /// Backing storage. `der` holds the decoded certificate bytes; `key_storage`
    /// holds the decoded private key structure, which BearSSL exposes as a
    /// pointer into a decoder context that must stay alive.
    der: []u8,
    key_storage: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Credentials) void {
        self.allocator.free(self.certs_alloc);
        self.allocator.free(self.der);
        self.allocator.free(self.key_storage);
        self.* = undefined;
    }
};

pub const LoadError = error{
    MissingPemHeader,
    PemDecodeFailed,
    KeyDecodeFailed,
    UnsupportedKeyType,
    OutOfMemory,
};

/// Result of decoding one PEM object.
const PemObject = struct {
    body: []u8,
    /// Object name as it appeared in the `-----BEGIN <name>-----` line.
    name: []const u8,
};

/// Accumulator passed to BearSSL's PEM sink callback. The callback receives
/// decoded bytes in chunks, so we track how much of the destination we filled.
const PemSink = struct {
    out: []u8,
    len: usize = 0,

    fn write(ctx: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void {
        const self: *PemSink = @ptrCast(@alignCast(ctx.?));
        const bytes: [*]const u8 = @ptrCast(src.?);
        const room = self.out.len - self.len;
        const n = @min(room, len);
        @memcpy(self.out[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }
};

/// Decode the first PEM object found in `pem` into `out`, returning its DER
/// bytes and the object name from its header line.
///
/// BearSSL's `br_pem_decoder` rejects a buffer that has trailing junk, so we
/// stop at the first `BR_PEM_END_OBJ` rather than feeding the whole file
/// (which may hold a chain of several certificates).
fn decodeFirstPem(pem: []const u8, out: []u8, name_buf: []u8) LoadError!PemObject {
    var decoder: c.br_pem_decoder_context = undefined;
    c.br_pem_decoder_init(&decoder);

    var sink = PemSink{ .out = out };
    // `br_pem_decoder_name` points into the decoder's own name buffer, which is
    // reused once decoding continues, so the name is copied into caller-owned
    // `name_buf` — never into a local, which would dangle once we return.
    var name: []const u8 = &.{};
    var offset: usize = 0;

    while (offset < pem.len) {
        const used = c.br_pem_decoder_push(&decoder, pem.ptr + offset, pem.len - offset);
        if (used == 0) break;
        offset += used;

        switch (c.br_pem_decoder_event(&decoder)) {
            c.BR_PEM_BEGIN_OBJ => {
                // NUL-terminated, normalised (uppercase) object name.
                const raw: [*:0]const u8 = c.br_pem_decoder_name(&decoder);
                const span = std.mem.span(raw);
                const n = @min(span.len, name_buf.len);
                @memcpy(name_buf[0..n], span[0..n]);
                name = name_buf[0..n];
                c.br_pem_decoder_setdest(&decoder, PemSink.write, &sink);
            },
            c.BR_PEM_END_OBJ => return .{ .body = out[0..sink.len], .name = name },
            else => {},
        }
    }
    if (sink.len == 0) return error.PemDecodeFailed;
    return .{ .body = out[0..sink.len], .name = name };
}

/// Decode every `-----BEGIN` block in `pem` as a certificate chain.
///
/// Certificates arrive as several PEM blocks in one file, so unlike the key we
/// cannot stop at the first object. Each decoded body is copied into its own
/// `per_cert`-sized slab of `arena`, and its length recorded in `lengths`.
/// Returns the number of certificates decoded.
fn decodeChain(
    pem: []const u8,
    arena: []u8,
    per_cert: usize,
    lengths: []usize,
) LoadError!usize {
    var decoder: c.br_pem_decoder_context = undefined;
    c.br_pem_decoder_init(&decoder);

    var slab_idx: usize = 0;
    var sink: PemSink = undefined;
    var offset: usize = 0;

    while (offset < pem.len and slab_idx < lengths.len) {
        const used = c.br_pem_decoder_push(&decoder, pem.ptr + offset, pem.len - offset);
        if (used == 0) break;
        offset += used;

        switch (c.br_pem_decoder_event(&decoder)) {
            c.BR_PEM_BEGIN_OBJ => {
                const base = slab_idx * per_cert;
                sink = PemSink{ .out = arena[base..][0..per_cert] };
                c.br_pem_decoder_setdest(&decoder, PemSink.write, &sink);
            },
            c.BR_PEM_END_OBJ => {
                if (sink.len == 0) continue;
                lengths[slab_idx] = sink.len;
                slab_idx += 1;
            },
            else => {},
        }
    }
    return slab_idx;
}

/// Load a certificate chain and private key from PEM files.
///
/// Certificates are concatenated PEM blocks in `cert_path`. The key may be
/// PKCS#8 (`PRIVATE KEY`) or PKCS#1 (`RSA PRIVATE KEY`) — BearSSL accepts both
/// once decoded — and either RSA or EC.
pub fn loadCredentials(
    io: std.Io,
    allocator: std.mem.Allocator,
    cert_path: []const u8,
    key_path: []const u8,
) !Credentials {
    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, cert_path, allocator, std.Io.Limit.limited(1 << 20));
    defer allocator.free(cert_pem);
    const key_pem = try std.Io.Dir.cwd().readFileAlloc(io, key_path, allocator, std.Io.Limit.limited(1 << 20));
    defer allocator.free(key_pem);

    // Decode the chain. BearSSL keeps pointers into these bytes for the life
    // of every server context built from them, so each certificate is copied
    // into its own slab of a single arena that `Credentials` owns.
    const max_certs = 8;
    const per_cert = 8 * 1024;
    const der = try allocator.alloc(u8, max_certs * per_cert);
    const certs = try allocator.alloc(c.br_x509_certificate, max_certs);
    // No `errdefer` here: ownership passes into `creds` below, which installs a
    // single cleanup block covering all three allocations. Adding early errdefers
    // as well would free these twice on the error path.

    // One length per slab, so the certificate slices are exact.
    var cert_lengths: [max_certs]usize = @splat(0);
    const n_certs = try decodeChain(cert_pem, der, per_cert, &cert_lengths);
    if (n_certs == 0) return error.PemDecodeFailed;
    for (0..n_certs) |i| {
        certs[i] = .{
            .data = der.ptr + i * per_cert,
            .data_len = cert_lengths[i],
        };
    }

    var creds = Credentials{
        // `certs` is a sub-slice of the full allocation; `certs_alloc` below is
        // what actually gets freed, because freeing a sub-slice would be invalid.
        .certs = certs[0..n_certs],
        .certs_alloc = certs,
        .der = der,
        .key_storage = try allocator.alloc(u8, 4096),
        .allocator = allocator,
    };
    errdefer {
        // Free the original allocations, never the slices stored in `creds`.
        allocator.free(certs);
        allocator.free(der);
        allocator.free(creds.key_storage);
    }

    // The private key: decode the PEM envelope, then hand DER to BearSSL.
    var key_der: [8192]u8 = undefined;
    // The name is unused for the key, but the buffer must still outlive the
    // call rather than living on decodeFirstPem's frame.
    var key_name_buf: [64]u8 = undefined;
    const key_obj = try decodeFirstPem(key_pem, &key_der, &key_name_buf);

    // BearSSL's key decoder is stateful and returns pointers into its own
    // context, so the decoded context itself has to be kept alive. Copy it
    // into `key_storage` and point at the copy.
    const KeyStorage = extern struct {
        ctx: c.br_skey_decoder_context align(8),
        pad: [256]u8 = [_]u8{0} ** 256,
    };
    const storage: *KeyStorage = @ptrCast(@alignCast(creds.key_storage.ptr));
    c.br_skey_decoder_init(&storage.ctx);
    c.br_skey_decoder_push(&storage.ctx, key_obj.body.ptr, key_obj.body.len);

    switch (c.br_skey_decoder_last_error(&storage.ctx)) {
        0 => {},
        else => |e| {
            std.debug.print("bearssl: key decode failed (err={d}) for {s}\n", .{ e, key_path });
            return error.KeyDecodeFailed;
        },
    }
    switch (c.br_skey_decoder_key_type(&storage.ctx)) {
        c.BR_KEYTYPE_RSA => creds.rsa_key = c.br_skey_decoder_get_rsa(&storage.ctx),
        c.BR_KEYTYPE_EC => creds.ec_key = c.br_skey_decoder_get_ec(&storage.ctx),
        else => return error.UnsupportedKeyType,
    }
    return creds;
}

/// Per-connection TLS state: a server context plus its I/O buffer.
///
/// Extracted as a type so callers can keep it on the heap; at ~37 KB it must
/// not land on a connection thread's stack.
pub const Connection = struct {
    ctx: c.br_ssl_server_context,
    io_buf: []u8,
    sock: std.posix.socket_t,
    io: std.Io,
    sslio: c.br_sslio_context,
    allocator: std.mem.Allocator,
    /// Set once the handshake completes, for logging and for deciding whether
    /// a plaintext fallback should be offered.
    handshaken: bool = false,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, sock: std.posix.socket_t, creds: *const Credentials) !*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        const io_buf = try allocator.alloc(u8, io_buffer_size);
        errdefer allocator.free(io_buf);

        self.* = .{
            .ctx = undefined,
            .io_buf = io_buf,
            .sock = sock,
            .io = io,
            .sslio = undefined,
            .allocator = allocator,
        };

        if (creds.rsa_key) |sk| {
            c.br_ssl_server_init_full_rsa(&self.ctx, creds.certs.ptr, creds.certs.len, sk);
        } else if (creds.ec_key) |sk| {
            // EC needs the issuing key type so BearSSL can filter suites;
            // self-signed EC certificates sign with themselves.
            c.br_ssl_server_init_full_ec(&self.ctx, creds.certs.ptr, creds.certs.len, c.BR_KEYTYPE_EC, sk);
        } else {
            return error.UnsupportedKeyType;
        }
        c.br_ssl_engine_set_buffer(&self.ctx.eng, io_buf.ptr, io_buf.len, 1);
        _ = c.br_ssl_server_reset(&self.ctx);

        c.br_sslio_init(&self.sslio, &self.ctx.eng, readFromSock, self, writeToSock, self);
        return self;
    }

    pub fn destroy(self: *Connection) void {
        self.allocator.free(self.io_buf);
        self.allocator.destroy(self);
    }

    /// Blocking read of up to `buf.len` decrypted bytes.
    ///
    /// Returns 0 at clean end of stream. A peer that simply goes away (browser
    /// navigating off an SSE stream, a port scanner, a plain-HTTP probe against
    /// the TLS port) reaches here as `BR_SSL_CLOSED` with no error code; that is
    /// ordinary for a dev server, so it is reported as `error.EndOfStream`
    /// rather than logged as a fault.
    pub fn read(self: *Connection, buf: []u8) !usize {
        const n = c.br_sslio_read(&self.sslio, buf.ptr, buf.len);
        if (n < 0) {
            const state = c.br_ssl_engine_current_state(&self.ctx.eng);
            const err = c.br_ssl_engine_last_error(&self.ctx.eng);
            // The engine is closed and BearSSL logged no protocol error: the
            // peer went away (browser leaving an SSE stream, keep-alive socket
            // timing out). Report it as a normal end of stream.
            if (state & c.BR_SSL_CLOSED != 0 and err == 0) return 0;
            // A plain-HTTP request against the TLS port decodes as a TLS record
            // with an unknown version. Dev servers get probed like this
            // constantly, so it is not worth a line per occurrence.
            if (err == c.BR_ERR_UNSUPPORTED_VERSION) return 0;
            std.debug.print("tls read failed: br_err={d} state={d}\n", .{ err, state });
            return error.TlsReadFailed;
        }
        self.handshaken = true;
        return @intCast(n);
    }

    pub fn writeAll(self: *Connection, buf: []const u8) !void {
        const n = c.br_sslio_write_all(&self.sslio, buf.ptr, buf.len);
        if (n < 0) {
            // BearSSL funnels every underlying write failure through BR_ERR_IO,
            // so a vanished client shows up as BR_ERR_IO rather than the
            // socket-level cause.
            if (c.br_ssl_engine_last_error(&self.ctx.eng) == c.BR_ERR_IO) return error.PeerGone;
            return error.TlsWriteFailed;
        }
    }

    pub fn flush(self: *Connection) !void {
        if (c.br_sslio_flush(&self.sslio) < 0) {
            // Flushing to a peer that has gone is the same class of event as a
            // failed write: report it as such so callers can stay quiet.
            if (c.br_ssl_engine_last_error(&self.ctx.eng) == c.BR_ERR_IO) return error.PeerGone;
            return error.TlsFlushFailed;
        }
    }

    pub fn close(self: *Connection) void {
        _ = c.br_sslio_close(&self.sslio);
    }
};

fn readFromSock(ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
    const self: *Connection = @ptrCast(@alignCast(ctx.?));
    const n = std.posix.read(self.sock, buf[0..len]) catch return -1;
    if (n == 0) return -1;
    return @intCast(n);
}

fn writeToSock(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
    const self: *Connection = @ptrCast(@alignCast(ctx.?));
    std.Io.File.writeStreamingAll(
        .{ .handle = self.sock, .flags = .{ .nonblocking = false } },
        self.io,
        buf[0..len],
    ) catch return -1;
    return @intCast(len);
}

test "pem decoder names the object it finds" {
    // A complete, minimal DER body: SEQUENCE { INTEGER 1 }.
    const pem =
        \\-----BEGIN CERTIFICATE-----
        \\MAMCAQE=
        \\-----END CERTIFICATE-----
        \\
    ;
    var out: [1024]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const obj = try decodeFirstPem(pem, &out, &name_buf);
    try std.testing.expectEqualStrings("CERTIFICATE", obj.name);
    // 0x30 0x03 0x02 0x01 0x01 — the decoded body, not the base64 text.
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x03, 0x02, 0x01, 0x01 }, obj.body);
}

test "pem decoder reports the decoded length, not the base64 length" {
    // BearSSL's PEM layer decodes the base64 envelope but does not validate the
    // ASN.1 inside it, so a truncated DER body still reaches END_OBJ. What it
    // must get right is the byte count: 3 base64 chars -> ~2 bytes plus padding.
    const pem =
        \\-----BEGIN CERTIFICATE-----
        \\MAMCAQE=
        \\-----END CERTIFICATE-----
        \\
    ;
    var out: [1024]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const obj = try decodeFirstPem(pem, &out, &name_buf);
    try std.testing.expectEqual(@as(usize, 5), obj.body.len);
    // Anything outside the declared object must not be left in the buffer.
    try std.testing.expectEqual(@as(u8, 0x30), obj.body[0]);
}


/// Adapts a TLS `Connection` to a `std.Io.Reader`.
///
/// This is the piece that makes the rest of the server TLS-agnostic: above this
/// seam, `std.http.Server` reads plaintext bytes and never learns whether they
/// arrived over a socket or through a TLS engine. It lives here rather than in
/// `server.zig` so every BearSSL detail stays in one file.
pub const Reader = struct {
    conn: *Connection,
    interface: std.Io.Reader,
    err: ?anyerror = null,

    pub fn init(conn: *Connection, buffer: []u8) Reader {
        return .{
            .conn = conn,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn self(r: *std.Io.Reader) *Reader {
        return @alignCast(@fieldParentPtr("interface", r));
    }

    /// Decrypt into the caller's destination slices.
    ///
    /// `fillMore` calls this with an *empty* first slice, meaning "put data in
    /// `Reader.buffer` and record it via seek/end". Handling only the non-empty
    /// case stalls forever on the very first read — the connection appears to
    /// hang with no error — so both paths are covered here.
    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const me = self(r);

        if (data[0].len == 0) {
            const dest = r.buffer[r.end..];
            if (dest.len == 0) return 0;
            const n = me.conn.read(dest) catch |err| {
                me.err = err;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            r.end += n;
            return n;
        }

        const n = me.conn.read(data[0]) catch |err| {
            me.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        return n;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(r, &data);
        w.advance(n);
        return n;
    }
};

/// Adapts a TLS `Connection` to a `std.Io.Writer`.
///
/// Writes are buffered in `interface.buffer` and handed to BearSSL on flush, so
/// a response does not cost one TLS record per `write` call. Note that a
/// detached SSE stream keeps writing through this long after the request loop
/// has exited, which is why the connection must outlive the loop.
pub const Writer = struct {
    conn: *Connection,
    interface: std.Io.Writer,
    err: ?anyerror = null,

    pub fn init(conn: *Connection, buffer: []u8) Writer {
        return .{
            .conn = conn,
            .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = buffer },
        };
    }

    fn self(w: *std.Io.Writer) *Writer {
        return @alignCast(@fieldParentPtr("interface", w));
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const me = self(w);
        const buffered = w.buffered();
        var total: usize = 0;

        if (buffered.len > 0) {
            me.conn.writeAll(buffered) catch |err| {
                me.err = err;
                return error.WriteFailed;
            };
            total += buffered.len;
        }
        for (data, 0..) |chunk, i| {
            const times = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                me.conn.writeAll(chunk) catch |err| {
                    me.err = err;
                    return error.WriteFailed;
                };
                total += chunk.len;
            }
        }
        _ = w.consume(total);
        return total;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const me = self(w);
        const buffered = w.buffered();
        if (buffered.len > 0) {
            me.conn.writeAll(buffered) catch |err| {
                me.err = err;
                return error.WriteFailed;
            };
            _ = w.consume(buffered.len);
        }
        me.conn.flush() catch |err| {
            me.err = err;
            return error.WriteFailed;
        };
    }
};
