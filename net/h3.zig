const std = @import("std");
pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("h3.h");
});

pub const Url = struct { host: []const u8, port: u16, path: []const u8 };

pub fn parseUrl(url: []const u8) ?Url {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash == rest.len) "/" else rest[slash..];
    if (authority.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
        return .{ .host = authority[0..colon], .port = port, .path = path };
    }
    return .{ .host = authority, .port = 443, .path = path };
}

pub const AltSvc = struct { port: u16, max_age: u32 };

pub fn parseAltSvc(value: []const u8) ?AltSvc {
    var entries = std.mem.tokenizeScalar(u8, value, ',');
    while (entries.next()) |raw| {
        var params = std.mem.tokenizeScalar(u8, raw, ';');
        const first = std.mem.trim(u8, params.next() orelse continue, " ");
        const eq = std.mem.indexOfScalar(u8, first, '=') orelse continue;
        if (!std.mem.eql(u8, first[0..eq], "h3")) continue;
        const target = std.mem.trim(u8, first[eq + 1 ..], "\"");
        const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse continue;
        if (colon != 0) continue;
        const port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch continue;
        var max_age: u32 = 86400;
        while (params.next()) |p| {
            const param = std.mem.trim(u8, p, " ");
            if (std.mem.startsWith(u8, param, "ma=")) max_age = std.fmt.parseInt(u32, param[3..], 10) catch max_age;
        }
        return .{ .port = port, .max_age = max_age };
    }
    return null;
}

pub const Response = struct {
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,
    handshake_ns: u64 = 0,
    total_ns: u64 = 0,
};

pub const Error = error{ Resolve, Socket, Tls, Quic, Http3, Timeout, Closed };

fn now() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn random(dest: [*c]u8, len: usize) void {
    _ = c.gnutls_rnd(c.GNUTLS_RND_RANDOM, dest, len);
}

const Client = struct {
    gpa: std.mem.Allocator,
    url: Url,
    host_z: [:0]u8,
    fd: c_int = -1,
    local: c.struct_sockaddr_storage = undefined,
    local_len: c.socklen_t = @sizeOf(c.struct_sockaddr_storage),
    remote: c.struct_sockaddr_storage = undefined,
    remote_len: c.socklen_t = 0,
    path: c.ngtcp2_path = undefined,
    conn: ?*c.ngtcp2_conn = null,
    h3: ?*c.nghttp3_conn = null,
    session: c.gnutls_session_t = null,
    cred: c.gnutls_certificate_credentials_t = null,
    ref: c.ngtcp2_crypto_conn_ref = undefined,
    stream: i64 = -1,
    finished: bool = false,
    start: u64 = 0,
    response: *Response,

    fn of(user: ?*anyopaque) *Client {
        return @ptrCast(@alignCast(user.?));
    }

    fn resolve(self: *Client) Error!void {
        var hints = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_socktype = c.SOCK_DGRAM;
        var port_buf: [8]u8 = undefined;
        const port = std.fmt.bufPrintZ(&port_buf, "{d}", .{self.url.port}) catch return error.Resolve;
        var res: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(self.host_z.ptr, port.ptr, &hints, &res) != 0) return error.Resolve;
        defer c.freeaddrinfo(res);
        var it = res;
        while (it) |ai| : (it = ai.ai_next) {
            const fd = c.socket(ai.ai_family, ai.ai_socktype | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, ai.ai_protocol);
            if (fd < 0) continue;
            if (c.connect(fd, ai.ai_addr, ai.ai_addrlen) != 0) {
                _ = c.close(fd);
                continue;
            }
            self.fd = fd;
            @memcpy(@as([*]u8, @ptrCast(&self.remote))[0..ai.ai_addrlen], @as([*]const u8, @ptrCast(ai.ai_addr))[0..ai.ai_addrlen]);
            self.remote_len = ai.ai_addrlen;
            if (c.getsockname(fd, @ptrCast(&self.local), &self.local_len) != 0) return error.Socket;
            return;
        }
        return error.Socket;
    }

    fn getConn(ref: [*c]c.ngtcp2_crypto_conn_ref) callconv(.c) ?*c.ngtcp2_conn {
        return of(ref.*.user_data).conn;
    }

    fn setupTls(self: *Client) Error!void {
        if (c.gnutls_certificate_allocate_credentials(&self.cred) != 0) return error.Tls;
        if (c.gnutls_certificate_set_x509_system_trust(self.cred) < 0) return error.Tls;
        if (c.gnutls_init(&self.session, c.GNUTLS_CLIENT | c.GNUTLS_ENABLE_EARLY_DATA | c.GNUTLS_NO_END_OF_EARLY_DATA) != 0) return error.Tls;
        if (c.ngtcp2_crypto_gnutls_configure_client_session(self.session) != 0) return error.Tls;
        const priority = "NORMAL:-VERS-ALL:+VERS-TLS1.3:-CIPHER-ALL:+AES-128-GCM:+AES-256-GCM:+CHACHA20-POLY1305:-GROUP-ALL:+GROUP-X25519:+GROUP-SECP256R1:+GROUP-SECP384R1:%DISABLE_TLS13_COMPAT_MODE";
        if (c.gnutls_priority_set_direct(self.session, priority, null) != 0) return error.Tls;
        self.ref = .{ .get_conn = getConn, .user_data = self };
        c.gnutls_session_set_ptr(self.session, &self.ref);
        if (c.gnutls_credentials_set(self.session, c.GNUTLS_CRD_CERTIFICATE, self.cred) != 0) return error.Tls;
        var alpn = c.gnutls_datum_t{ .data = @constCast("h3"), .size = 2 };
        if (c.gnutls_alpn_set_protocols(self.session, &alpn, 1, c.GNUTLS_ALPN_MANDATORY) != 0) return error.Tls;
        if (c.gnutls_server_name_set(self.session, c.GNUTLS_NAME_DNS, self.host_z.ptr, self.host_z.len) != 0) return error.Tls;
        c.gnutls_session_set_verify_cert(self.session, self.host_z.ptr, 0);
    }

    fn onRand(dest: [*c]u8, len: usize, _: [*c]const c.ngtcp2_rand_ctx) callconv(.c) void {
        random(dest, len);
    }

    fn onNewCid(_: ?*c.ngtcp2_conn, cid: [*c]c.ngtcp2_cid, token: [*c]u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
        random(&cid.*.data[0], len);
        cid.*.datalen = len;
        random(token, c.NGTCP2_STATELESS_RESET_TOKENLEN);
        return 0;
    }

    fn onHandshake(_: ?*c.ngtcp2_conn, user: ?*anyopaque) callconv(.c) c_int {
        const self = of(user);
        self.response.handshake_ns = now() - self.start;
        self.setupHttp3() catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn consume(self: *Client, stream: i64, n: usize) void {
        _ = c.ngtcp2_conn_extend_max_stream_offset(self.conn, stream, n);
        c.ngtcp2_conn_extend_max_offset(self.conn, n);
    }

    fn onStreamData(_: ?*c.ngtcp2_conn, flags: u32, stream: i64, _: u64, data: [*c]const u8, len: usize, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = of(user);
        const h3 = self.h3 orelse return c.NGTCP2_ERR_CALLBACK_FAILURE;
        const fin: c_int = @intFromBool(flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0);
        const used = c.nghttp3_conn_read_stream(h3, stream, data, len, fin);
        if (used < 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        self.consume(stream, @intCast(used));
        return 0;
    }

    fn onAcked(_: ?*c.ngtcp2_conn, stream: i64, _: u64, len: u64, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const h3 = of(user).h3 orelse return 0;
        return if (c.nghttp3_conn_add_ack_offset(h3, stream, len) != 0) c.NGTCP2_ERR_CALLBACK_FAILURE else 0;
    }

    fn onStreamClose(_: ?*c.ngtcp2_conn, flags: u32, stream: i64, code: u64, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const h3 = of(user).h3 orelse return 0;
        const app = if (flags & c.NGTCP2_STREAM_CLOSE_FLAG_APP_ERROR_CODE_SET != 0) code else c.NGHTTP3_H3_NO_ERROR;
        const rv = c.nghttp3_conn_close_stream(h3, stream, app);
        return if (rv != 0 and rv != c.NGHTTP3_ERR_STREAM_NOT_FOUND) c.NGTCP2_ERR_CALLBACK_FAILURE else 0;
    }

    fn onStreamReset(_: ?*c.ngtcp2_conn, stream: i64, _: u64, _: u64, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const h3 = of(user).h3 orelse return 0;
        return if (c.nghttp3_conn_shutdown_stream_read(h3, stream) != 0) c.NGTCP2_ERR_CALLBACK_FAILURE else 0;
    }

    fn onStopSending(_: ?*c.ngtcp2_conn, stream: i64, _: u64, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const h3 = of(user).h3 orelse return 0;
        return if (c.nghttp3_conn_shutdown_stream_read(h3, stream) != 0) c.NGTCP2_ERR_CALLBACK_FAILURE else 0;
    }

    fn onMaxStreamData(_: ?*c.ngtcp2_conn, stream: i64, _: u64, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const h3 = of(user).h3 orelse return 0;
        return if (c.nghttp3_conn_unblock_stream(h3, stream) != 0) c.NGTCP2_ERR_CALLBACK_FAILURE else 0;
    }

    fn setupQuic(self: *Client) Error!void {
        var cb = std.mem.zeroes(c.ngtcp2_callbacks);
        cb.client_initial = c.ngtcp2_crypto_client_initial_cb;
        cb.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
        cb.encrypt = c.ngtcp2_crypto_encrypt_cb;
        cb.decrypt = c.ngtcp2_crypto_decrypt_cb;
        cb.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
        cb.recv_retry = c.ngtcp2_crypto_recv_retry_cb;
        cb.update_key = c.ngtcp2_crypto_update_key_cb;
        cb.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
        cb.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
        cb.get_path_challenge_data = c.ngtcp2_crypto_get_path_challenge_data_cb;
        cb.version_negotiation = c.ngtcp2_crypto_version_negotiation_cb;
        cb.rand = onRand;
        cb.get_new_connection_id = onNewCid;
        cb.handshake_completed = onHandshake;
        cb.recv_stream_data = onStreamData;
        cb.acked_stream_data_offset = onAcked;
        cb.stream_close = onStreamClose;
        cb.stream_reset = onStreamReset;
        cb.stream_stop_sending = onStopSending;
        cb.extend_max_stream_data = onMaxStreamData;

        var settings: c.ngtcp2_settings = undefined;
        c.ngtcp2_settings_default_versioned(c.NGTCP2_SETTINGS_VERSION, &settings);
        settings.initial_ts = now();
        var params: c.ngtcp2_transport_params = undefined;
        c.ngtcp2_transport_params_default_versioned(c.NGTCP2_TRANSPORT_PARAMS_VERSION, &params);
        params.initial_max_streams_uni = 3;
        params.initial_max_stream_data_bidi_local = 1 << 20;
        params.initial_max_stream_data_uni = 1 << 20;
        params.initial_max_data = 8 << 20;

        var dcid: c.ngtcp2_cid = undefined;
        var scid: c.ngtcp2_cid = undefined;
        dcid.datalen = 18;
        random(&dcid.data[0], dcid.datalen);
        scid.datalen = 17;
        random(&scid.data[0], scid.datalen);
        self.path = .{
            .local = .{ .addr = @ptrCast(&self.local), .addrlen = self.local_len },
            .remote = .{ .addr = @ptrCast(&self.remote), .addrlen = self.remote_len },
            .user_data = null,
        };
        if (c.ngtcp2_conn_client_new_versioned(&self.conn, &dcid, &scid, &self.path, c.NGTCP2_PROTO_VER_V1, c.NGTCP2_CALLBACKS_VERSION, &cb, c.NGTCP2_SETTINGS_VERSION, &settings, c.NGTCP2_TRANSPORT_PARAMS_VERSION, &params, null, self) != 0) return error.Quic;
        c.ngtcp2_conn_set_tls_native_handle(self.conn, self.session);
    }

    fn onHeader(_: ?*c.nghttp3_conn, stream: i64, _: i32, name: ?*c.nghttp3_rcbuf, value: ?*c.nghttp3_rcbuf, _: u8, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = of(user);
        if (stream != self.stream) return 0;
        const n = c.nghttp3_rcbuf_get_buf(name);
        if (!std.mem.eql(u8, n.base[0..n.len], ":status")) return 0;
        const v = c.nghttp3_rcbuf_get_buf(value);
        self.response.status = std.fmt.parseInt(u16, v.base[0..v.len], 10) catch 0;
        return 0;
    }

    fn onData(_: ?*c.nghttp3_conn, stream: i64, data: [*c]const u8, len: usize, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = of(user);
        self.consume(stream, len);
        if (stream == self.stream) self.response.body.appendSlice(self.gpa, data[0..len]) catch return c.NGHTTP3_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onDeferred(_: ?*c.nghttp3_conn, stream: i64, consumed: usize, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        of(user).consume(stream, consumed);
        return 0;
    }

    fn onEnd(_: ?*c.nghttp3_conn, stream: i64, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = of(user);
        if (stream == self.stream) self.finished = true;
        return 0;
    }

    fn onH3Acked(_: ?*c.nghttp3_conn, _: i64, _: u64, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }

    fn setupHttp3(self: *Client) Error!void {
        var cb = std.mem.zeroes(c.nghttp3_callbacks);
        cb.recv_header = onHeader;
        cb.recv_data = onData;
        cb.deferred_consume = onDeferred;
        cb.end_stream = onEnd;
        cb.acked_stream_data = onH3Acked;
        var settings: c.nghttp3_settings = undefined;
        c.nghttp3_settings_default_versioned(c.NGHTTP3_SETTINGS_VERSION, &settings);
        if (c.nghttp3_conn_client_new_versioned(&self.h3, c.NGHTTP3_CALLBACKS_VERSION, &cb, c.NGHTTP3_SETTINGS_VERSION, &settings, c.nghttp3_mem_default(), self) != 0) return error.Http3;
        var control: i64 = -1;
        var enc: i64 = -1;
        var dec: i64 = -1;
        if (c.ngtcp2_conn_open_uni_stream(self.conn, &control, null) != 0) return error.Http3;
        if (c.nghttp3_conn_bind_control_stream(self.h3, control) != 0) return error.Http3;
        if (c.ngtcp2_conn_open_uni_stream(self.conn, &enc, null) != 0) return error.Http3;
        if (c.ngtcp2_conn_open_uni_stream(self.conn, &dec, null) != 0) return error.Http3;
        if (c.nghttp3_conn_bind_qpack_streams(self.h3, enc, dec) != 0) return error.Http3;
        if (c.ngtcp2_conn_open_bidi_stream(self.conn, &self.stream, null) != 0) return error.Http3;
        const headers = [_][2][]const u8{
            .{ ":method", "GET" },
            .{ ":scheme", "https" },
            .{ ":authority", self.url.host },
            .{ ":path", self.url.path },
            .{ "user-agent", "fotone-h3" },
        };
        var nva: [headers.len]c.nghttp3_nv = undefined;
        for (headers, 0..) |h, i| nva[i] = .{
            .name = @constCast(h[0].ptr),
            .namelen = h[0].len,
            .value = @constCast(h[1].ptr),
            .valuelen = h[1].len,
            .flags = c.NGHTTP3_NV_FLAG_NONE,
        };
        if (c.nghttp3_conn_submit_request(self.h3, self.stream, &nva, nva.len, null, null) != 0) return error.Http3;
    }

    fn flush(self: *Client) Error!void {
        var buf: [1452]u8 = undefined;
        var ps: c.ngtcp2_path_storage = undefined;
        c.ngtcp2_path_storage_zero(&ps);
        var pi: c.ngtcp2_pkt_info = undefined;
        const ts = now();
        while (true) {
            var stream: i64 = -1;
            var fin: c_int = 0;
            var vec: [16]c.nghttp3_vec = undefined;
            var count: isize = 0;
            if (self.h3) |h3| {
                if (c.ngtcp2_conn_get_max_data_left(self.conn) > 0) {
                    count = c.nghttp3_conn_writev_stream(h3, &stream, &fin, &vec, vec.len);
                    if (count < 0) return error.Http3;
                }
            }
            var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_MORE;
            if (fin != 0) flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;
            var written: isize = -1;
            const n = c.ngtcp2_conn_writev_stream_versioned(self.conn, &ps.path, c.NGTCP2_PKT_INFO_VERSION, &pi, &buf, buf.len, &written, flags, stream, @ptrCast(&vec), @intCast(count), ts);
            if (n < 0) {
                switch (n) {
                    c.NGTCP2_ERR_STREAM_DATA_BLOCKED => {
                        c.nghttp3_conn_block_stream(self.h3, stream);
                        continue;
                    },
                    c.NGTCP2_ERR_STREAM_SHUT_WR => {
                        c.nghttp3_conn_shutdown_stream_write(self.h3, stream);
                        continue;
                    },
                    c.NGTCP2_ERR_WRITE_MORE => {
                        if (c.nghttp3_conn_add_write_offset(self.h3, stream, @intCast(written)) != 0) return error.Http3;
                        continue;
                    },
                    else => return error.Quic,
                }
            }
            if (written >= 0 and self.h3 != null) {
                if (c.nghttp3_conn_add_write_offset(self.h3, stream, @intCast(written)) != 0) return error.Http3;
            }
            if (n == 0) return;
            _ = c.send(self.fd, &buf, @intCast(n), 0);
        }
    }

    fn receive(self: *Client) Error!void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = c.recv(self.fd, &buf, buf.len, 0);
            if (n <= 0) return;
            var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
            const rv = c.ngtcp2_conn_read_pkt_versioned(self.conn, &self.path, c.NGTCP2_PKT_INFO_VERSION, &pi, &buf, @intCast(n), now());
            if (rv == c.NGTCP2_ERR_DRAINING or rv == c.NGTCP2_ERR_CLOSING) return error.Closed;
            if (rv != 0) return error.Quic;
        }
    }

    fn run(self: *Client, timeout_ns: u64) Error!void {
        try self.flush();
        while (!self.finished) {
            const t = now();
            if (t - self.start > timeout_ns) return error.Timeout;
            const expiry = c.ngtcp2_conn_get_expiry(self.conn);
            const wait_ms: c_int = if (expiry <= t) 0 else @intCast(@min((expiry - t) / std.time.ns_per_ms + 1, 200));
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pfd, 1, wait_ms);
            if (ready > 0) {
                try self.receive();
            } else if (c.ngtcp2_conn_get_expiry(self.conn) <= now()) {
                const rv = c.ngtcp2_conn_handle_expiry(self.conn, now());
                if (rv != 0) return error.Quic;
            }
            try self.flush();
        }
        self.response.total_ns = now() - self.start;
    }

    fn deinit(self: *Client) void {
        if (self.h3) |h| c.nghttp3_conn_del(h);
        if (self.conn) |q| c.ngtcp2_conn_del(q);
        if (self.session != null) c.gnutls_deinit(self.session);
        if (self.cred != null) c.gnutls_certificate_free_credentials(self.cred);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.gpa.free(self.host_z);
    }
};

pub fn get(gpa: std.mem.Allocator, url: []const u8, timeout_ns: u64, response: *Response) Error!void {
    const parsed = parseUrl(url) orelse return error.Resolve;
    var client = Client{
        .gpa = gpa,
        .url = parsed,
        .host_z = gpa.dupeZ(u8, parsed.host) catch return error.Resolve,
        .response = response,
    };
    defer client.deinit();
    client.start = now();
    try client.resolve();
    try client.setupTls();
    try client.setupQuic();
    try client.run(timeout_ns);
}

test "urls split into host, port and path" {
    const u = parseUrl("https://teams.microsoft.com/v2/").?;
    try std.testing.expectEqualStrings("teams.microsoft.com", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/v2/", u.path);
    const p = parseUrl("https://localhost:4433").?;
    try std.testing.expectEqual(@as(u16, 4433), p.port);
    try std.testing.expectEqualStrings("/", p.path);
    try std.testing.expect(parseUrl("http://example.com/") == null);
}

test "alt-svc picks the same-host h3 entry" {
    const a = parseAltSvc("h3=\":443\"; ma=2592000,h3-29=\":443\"; ma=2592000").?;
    try std.testing.expectEqual(@as(u16, 443), a.port);
    try std.testing.expectEqual(@as(u32, 2592000), a.max_age);
    const b = parseAltSvc("h2=\"alt.example.com:443\", h3=\":8443\"").?;
    try std.testing.expectEqual(@as(u16, 8443), b.port);
    try std.testing.expectEqual(@as(u32, 86400), b.max_age);
    try std.testing.expect(parseAltSvc("h3=\"other.example.com:443\"") == null);
    try std.testing.expect(parseAltSvc("clear") == null);
}
