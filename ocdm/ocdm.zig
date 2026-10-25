const std = @import("std");
const c = @import("c.zig").c;
const cenc = @import("cenc.zig");
const clearkey = @import("clearkey.zig");
const widevine = @import("widevine.zig");

const MAX_KEYS = 64;

pub const Kind = enum { clearkey, widevine };

pub const System = struct {
    kind: Kind,
    cert: ?[]u8 = null,
};

pub const Key = struct {
    id: clearkey.Kid,
    value: [16]u8 = undefined,
    status: c.KeyStatus = c.StatusPending,
};

pub const Session = struct {
    refs: std.atomic.Value(u32) = .init(1),
    system: *System,
    id: [40:0]u8 = undefined,
    callbacks: ?c.OpenCDMSessionCallbacks,
    data: ?*anyopaque,
    persistent: bool,
    keys: [MAX_KEYS]Key = undefined,
    count: usize = 0,
    closed: bool = false,
    cdm: ?*widevine.Session = null,

    pub fn find(s: *Session, kid: []const u8) ?*Key {
        if (kid.len != 16) return null;
        for (s.keys[0..s.count]) |*k| if (std.mem.eql(u8, &k.id, kid)) return k;
        return null;
    }

    pub fn setKey(s: *Session, id: clearkey.Kid, value: ?[16]u8, status: c.KeyStatus) void {
        const k = s.find(&id) orelse blk: {
            if (s.count == MAX_KEYS) return;
            s.keys[s.count] = .{ .id = id };
            s.count += 1;
            break :blk &s.keys[s.count - 1];
        };
        if (value) |v| k.value = v;
        k.status = status;
        c.g_mutex_lock(&lock);
        c.g_cond_broadcast(&cond);
        c.g_mutex_unlock(&lock);
    }

    pub fn challenge(s: *Session, kind: u8, payload: []const u8) void {
        const cb = s.callbacks orelse return;
        const f = cb.process_challenge_callback orelse return;
        const buf = std.heap.c_allocator.alloc(u8, payload.len + 7) catch return;
        defer std.heap.c_allocator.free(buf);
        buf[0] = '0' + kind;
        @memcpy(buf[1..7], ":Type:");
        @memcpy(buf[7..], payload);
        f(@ptrCast(s), s.data, "", buf.ptr, @intCast(@min(buf.len, std.math.maxInt(u16))));
    }

    pub fn keyUpdated(s: *Session, id: *const clearkey.Kid) void {
        const cb = s.callbacks orelse return;
        if (cb.key_update_callback) |f| f(@ptrCast(s), s.data, id, 16);
    }

    pub fn updated(s: *Session) void {
        const cb = s.callbacks orelse return;
        if (cb.keys_updated_callback) |f| f(@ptrCast(s), s.data);
    }

    pub fn failed(s: *Session, message: [*:0]const u8) void {
        const cb = s.callbacks orelse return;
        if (cb.error_message_callback) |f| f(@ptrCast(s), s.data, message);
    }
};

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var cond: c.GCond = std.mem.zeroes(c.GCond);
var sessions: std.ArrayList(*Session) = .empty;
var serial: std.atomic.Value(u32) = .init(0);

fn kindOf(key_system: ?[*:0]const u8) ?Kind {
    const name = std.mem.span(key_system orelse return null);
    if (std.mem.eql(u8, name, clearkey.KEY_SYSTEM)) return .clearkey;
    if (std.mem.eql(u8, name, widevine.KEY_SYSTEM)) return .widevine;
    return null;
}

fn mimeSupported(kind: Kind, mime: []const u8) bool {
    if (mime.len == 0) return true;
    const base = std.mem.sliceTo(mime, ';');
    const known = [_][]const u8{ "video/mp4", "audio/mp4", "video/webm", "audio/webm", "video/x-h264", "video/x-vp9", "audio/mpeg", "audio/x-opus" };
    for (known) |k| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, base, " "), k)) return kind == .clearkey or widevine.available();
    return false;
}

pub export fn opencdm_is_type_supported(key_system: ?[*:0]const u8, mime_type: ?[*:0]const u8) c.OpenCDMError {
    const kind = kindOf(key_system) orelse return c.ERROR_KEYSYSTEM_NOT_SUPPORTED;
    if (kind == .widevine and !widevine.available()) return c.ERROR_KEYSYSTEM_NOT_SUPPORTED;
    const mime = if (mime_type) |m| std.mem.span(m) else "";
    return if (mimeSupported(kind, mime)) c.ERROR_NONE else c.ERROR_KEYSYSTEM_NOT_SUPPORTED;
}

pub export fn opencdm_create_system(key_system: ?[*:0]const u8) ?*c.OpenCDMSystem {
    const kind = kindOf(key_system) orelse return null;
    if (kind == .widevine and !widevine.available()) return null;
    const s = std.heap.c_allocator.create(System) catch return null;
    s.* = .{ .kind = kind };
    return @ptrCast(s);
}

pub export fn opencdm_destruct_system(system: ?*c.OpenCDMSystem) c.OpenCDMError {
    const s: *System = @ptrCast(@alignCast(system orelse return c.ERROR_INVALID_ARG));
    if (s.cert) |b| std.heap.c_allocator.free(b);
    std.heap.c_allocator.destroy(s);
    return c.ERROR_NONE;
}

pub export fn opencdm_system_supports_server_certificate(system: ?*c.OpenCDMSystem) bool {
    const s: *System = @ptrCast(@alignCast(system orelse return false));
    return s.kind == .widevine;
}

pub export fn opencdm_system_set_server_certificate(system: ?*c.OpenCDMSystem, cert: [*c]const u8, length: u32) c.OpenCDMError {
    const s: *System = @ptrCast(@alignCast(system orelse return c.ERROR_INVALID_ARG));
    if (s.kind != .widevine) return c.ERROR_METHOD_NOT_IMPLEMENTED;
    const copy = std.heap.c_allocator.dupe(u8, cert[0..length]) catch return c.ERROR_OUT_OF_MEMORY;
    if (s.cert) |b| std.heap.c_allocator.free(b);
    s.cert = copy;
    return c.ERROR_NONE;
}

fn release(s: *Session) void {
    if (s.refs.fetchSub(1, .acq_rel) != 1) return;
    c.g_mutex_lock(&lock);
    for (sessions.items, 0..) |x, i| if (x == s) {
        _ = sessions.swapRemove(i);
        break;
    };
    c.g_mutex_unlock(&lock);
    if (s.cdm) |w| widevine.close(w);
    std.crypto.secureZero(u8, std.mem.sliceAsBytes(&s.keys));
    std.heap.c_allocator.destroy(s);
}

fn clearkeyRequest(s: *Session, init_type: []const u8, init: []const u8) c.OpenCDMError {
    var kids: [16]clearkey.Kid = undefined;
    const n = clearkey.initKids(init_type, init, &kids) catch return c.ERROR_INVALID_ARG;
    if (n == 0) return c.ERROR_INVALID_ARG;
    for (kids[0..n]) |k| s.setKey(k, null, c.StatusPending);
    var buf: [1024]u8 = undefined;
    const msg = clearkey.request(&buf, kids[0..n], s.persistent) catch return c.ERROR_BUFFER_TOO_SMALL;
    s.challenge(0, msg);
    return c.ERROR_NONE;
}

pub export fn opencdm_construct_session(
    system: ?*c.OpenCDMSystem,
    license_type: c.LicenseType,
    init_data_type: ?[*:0]const u8,
    init_data: [*c]const u8,
    init_data_length: u16,
    cdm_data: [*c]const u8,
    cdm_data_length: u16,
    callbacks: ?*c.OpenCDMSessionCallbacks,
    user_data: ?*anyopaque,
    out: ?*?*c.OpenCDMSession,
) c.OpenCDMError {
    _ = cdm_data;
    _ = cdm_data_length;
    const result = out orelse return c.ERROR_INVALID_ARG;
    result.* = null;
    const sys: *System = @ptrCast(@alignCast(system orelse return c.ERROR_INVALID_ARG));
    const s = std.heap.c_allocator.create(Session) catch return c.ERROR_OUT_OF_MEMORY;
    s.* = .{
        .system = sys,
        .callbacks = if (callbacks) |cb| cb.* else null,
        .data = user_data,
        .persistent = license_type != c.Temporary,
    };
    _ = std.fmt.bufPrintZ(&s.id, "fotone-{d}-{d}", .{ std.c.getpid(), serial.fetchAdd(1, .monotonic) + 1 }) catch unreachable;
    c.g_mutex_lock(&lock);
    sessions.append(std.heap.c_allocator, s) catch {
        c.g_mutex_unlock(&lock);
        std.heap.c_allocator.destroy(s);
        return c.ERROR_OUT_OF_MEMORY;
    };
    c.g_mutex_unlock(&lock);
    result.* = @ptrCast(s);
    const init_type = if (init_data_type) |t| std.mem.span(t) else "";
    const init = if (init_data_length > 0) init_data[0..init_data_length] else &[_]u8{};
    if (init_type.len == 0) return c.ERROR_NONE;
    const r = switch (sys.kind) {
        .clearkey => clearkeyRequest(s, init_type, init),
        .widevine => widevine.open(s, sys.cert, init_type, init),
    };
    if (r != c.ERROR_NONE) s.failed("license request failed");
    return r;
}

fn holder(kid: []const u8) ?*Session {
    for (sessions.items) |s| {
        if (s.closed) continue;
        if (s.find(kid)) |k| if (k.status == c.Usable) {
            _ = s.refs.fetchAdd(1, .monotonic);
            return s;
        };
    }
    return null;
}

pub export fn opencdm_get_system_session(system: ?*c.OpenCDMSystem, key_id: [*c]const u8, length: u8, wait_time: u32) ?*c.OpenCDMSession {
    _ = system;
    if (key_id == null) return null;
    const kid = key_id[0..length];
    const deadline = c.g_get_monotonic_time() + @as(i64, wait_time) * 1000;
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    while (true) {
        if (holder(kid)) |s| return @ptrCast(s);
        if (c.g_get_monotonic_time() >= deadline) return null;
        _ = c.g_cond_wait_until(&cond, &lock, deadline);
    }
}

pub export fn opencdm_destruct_session(session: ?*c.OpenCDMSession) c.OpenCDMError {
    release(@ptrCast(@alignCast(session orelse return c.ERROR_INVALID_ARG)));
    return c.ERROR_NONE;
}

pub export fn opencdm_session_id(session: ?*const c.OpenCDMSession) [*c]const u8 {
    const s: *const Session = @ptrCast(@alignCast(session orelse return null));
    return &s.id;
}

pub export fn opencdm_session_status(session: ?*const c.OpenCDMSession, key_id: [*c]const u8, length: u8) c.KeyStatus {
    const s: *Session = @constCast(@ptrCast(@alignCast(session orelse return c.InternalError)));
    if (key_id == null) return c.InternalError;
    const k = s.find(key_id[0..length]) orelse return c.StatusPending;
    return k.status;
}

fn clearkeyUpdate(s: *Session, message: []const u8) c.OpenCDMError {
    var keys: [MAX_KEYS]clearkey.Key = undefined;
    const n = clearkey.license(message, &keys) catch {
        s.failed("license is not a JSON web key set");
        return c.ERROR_INVALID_ARG;
    };
    defer std.crypto.secureZero(u8, std.mem.sliceAsBytes(keys[0..n]));
    for (keys[0..n]) |k| s.setKey(k.id, k.value, c.Usable);
    for (keys[0..n]) |k| s.keyUpdated(&k.id);
    s.updated();
    return c.ERROR_NONE;
}

pub export fn opencdm_session_update(session: ?*c.OpenCDMSession, key_message: [*c]const u8, length: u32) c.OpenCDMError {
    const s: *Session = @ptrCast(@alignCast(session orelse return c.ERROR_INVALID_SESSION));
    if (key_message == null or length == 0) return c.ERROR_INVALID_ARG;
    const message = key_message[0..length];
    return switch (s.system.kind) {
        .clearkey => clearkeyUpdate(s, message),
        .widevine => widevine.update(s, message),
    };
}

pub export fn opencdm_session_load(session: ?*c.OpenCDMSession) c.OpenCDMError {
    const s: *Session = @ptrCast(@alignCast(session orelse return c.ERROR_INVALID_SESSION));
    return switch (s.system.kind) {
        .clearkey => c.ERROR_METHOD_NOT_IMPLEMENTED,
        .widevine => widevine.load(s),
    };
}

pub export fn opencdm_session_remove(session: ?*c.OpenCDMSession) c.OpenCDMError {
    const s: *Session = @ptrCast(@alignCast(session orelse return c.ERROR_INVALID_SESSION));
    if (s.system.kind == .widevine) return widevine.remove(s);
    for (s.keys[0..s.count]) |*k| k.status = c.Released;
    for (s.keys[0..s.count]) |*k| s.keyUpdated(&k.id);
    s.updated();
    return c.ERROR_NONE;
}

pub export fn opencdm_session_close(session: ?*c.OpenCDMSession) c.OpenCDMError {
    const s: *Session = @ptrCast(@alignCast(session orelse return c.ERROR_INVALID_SESSION));
    c.g_mutex_lock(&lock);
    s.closed = true;
    c.g_mutex_unlock(&lock);
    if (s.cdm) |w| {
        s.cdm = null;
        widevine.close(w);
    }
    return c.ERROR_NONE;
}

const Mapped = struct {
    buf: ?*c.GstBuffer,
    info: c.GstMapInfo = undefined,
    ok: bool = false,

    fn of(buf: ?*c.GstBuffer, flags: c.GstMapFlags) Mapped {
        var m: Mapped = .{ .buf = buf };
        if (buf) |b| m.ok = c.gst_buffer_map(b, &m.info, flags) != 0;
        return m;
    }

    fn bytes(m: *Mapped) []u8 {
        return if (m.ok) m.info.data[0..m.info.size] else &[_]u8{};
    }

    fn done(m: *Mapped) void {
        if (m.ok) c.gst_buffer_unmap(m.buf, &m.info);
    }
};

fn metaPattern(buffer: *c.GstBuffer, mode: *cenc.Mode, pattern: *cenc.Pattern) void {
    const meta: ?*c.GstProtectionMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(buffer, c.gst_protection_meta_api_get_type())));
    const info = (meta orelse return).info orelse return;
    if (c.gst_structure_get_string(info, "cipher-mode")) |m| {
        if (std.ascii.eqlIgnoreCase(std.mem.span(m), "cbcs")) mode.* = .cbcs;
    }
    var v: c.guint = 0;
    if (c.gst_structure_get_uint(info, "crypt_byte_block", &v) != 0) pattern.crypt = v;
    if (c.gst_structure_get_uint(info, "skip_byte_block", &v) != 0) pattern.skip = v;
}

pub export fn opencdm_gstreamer_session_decrypt(
    session: ?*c.OpenCDMSession,
    buffer: ?*c.GstBuffer,
    sub_samples: ?*c.GstBuffer,
    sub_sample_count: u32,
    iv: ?*c.GstBuffer,
    key_id: ?*c.GstBuffer,
    init_with_last_15: u32,
) c.OpenCDMError {
    _ = init_with_last_15;
    const s: *Session = @ptrCast(@alignCast(session orelse return c.ERROR_INVALID_SESSION));
    const data_buf = buffer orelse return c.ERROR_INVALID_DECRYPT_BUFFER;
    var mode: cenc.Mode = .ctr;
    var pattern: cenc.Pattern = .{};
    metaPattern(data_buf, &mode, &pattern);
    var kid_map = Mapped.of(key_id, c.GST_MAP_READ);
    defer kid_map.done();
    var iv_map = Mapped.of(iv, c.GST_MAP_READ);
    defer iv_map.done();
    var sub_map = Mapped.of(sub_samples, c.GST_MAP_READ);
    defer sub_map.done();
    var data_map = Mapped.of(data_buf, c.GST_MAP_READWRITE);
    defer data_map.done();
    if (!data_map.ok) return c.ERROR_INVALID_DECRYPT_BUFFER;
    var subs: [512]cenc.Subsample = undefined;
    const list = if (sub_sample_count == 0) subs[0..0] else cenc.parseSubsamples(sub_map.bytes(), sub_sample_count, &subs) catch return c.ERROR_INVALID_DECRYPT_BUFFER;
    if (s.system.kind == .widevine) return widevine.decrypt(s, mode, pattern, kid_map.bytes(), iv_map.bytes(), data_map.bytes(), list);
    const k = s.find(kid_map.bytes()) orelse return c.ERROR_INVALID_ACCESSOR;
    if (k.status != c.Usable) return c.ERROR_INVALID_ACCESSOR;
    cenc.decrypt(mode, k.value, iv_map.bytes(), data_map.bytes(), list, pattern) catch return c.ERROR_INVALID_DECRYPT_BUFFER;
    return c.ERROR_NONE;
}

const Probe = struct {
    challenges: usize = 0,
    message: [256]u8 = undefined,
    len: usize = 0,
    updates: usize = 0,
    done: usize = 0,

    fn onChallenge(_: ?*c.OpenCDMSession, data: ?*anyopaque, _: [*c]const u8, challenge: [*c]const u8, length: u16) callconv(.c) void {
        const p: *Probe = @ptrCast(@alignCast(data));
        p.challenges += 1;
        p.len = @min(length, p.message.len);
        @memcpy(p.message[0..p.len], challenge[0..p.len]);
    }

    fn onKey(_: ?*c.OpenCDMSession, data: ?*anyopaque, _: [*c]const u8, _: u8) callconv(.c) void {
        const p: *Probe = @ptrCast(@alignCast(data));
        p.updates += 1;
    }

    fn onDone(_: ?*const c.OpenCDMSession, data: ?*anyopaque) callconv(.c) void {
        const p: *Probe = @ptrCast(@alignCast(data));
        p.done += 1;
    }
};

test "a clearkey session asks for its keys, takes a license and decrypts a sample" {
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), opencdm_is_type_supported("org.w3.clearkey", "video/mp4; codecs=\"avc1.64001f\""));
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_KEYSYSTEM_NOT_SUPPORTED), opencdm_is_type_supported("com.example.drm", ""));
    const sys = opencdm_create_system("org.w3.clearkey").?;
    defer _ = opencdm_destruct_system(sys);
    var probe: Probe = .{};
    var cbs: c.OpenCDMSessionCallbacks = .{ .process_challenge_callback = Probe.onChallenge, .key_update_callback = Probe.onKey, .keys_updated_callback = Probe.onDone };
    const init = "{\"kids\":[\"AAECAwQFBgcICQoLDA0ODw\"]}";
    var session: ?*c.OpenCDMSession = null;
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), opencdm_construct_session(sys, c.Temporary, "keyids", init, init.len, null, 0, &cbs, &probe, &session));
    try std.testing.expectEqual(@as(usize, 1), probe.challenges);
    try std.testing.expectStringStartsWith(probe.message[0..probe.len], "0:Type:{\"kids\":[\"AAECAwQFBgcICQoLDA0ODw\"]");
    const kid = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try std.testing.expectEqual(@as(c.KeyStatus, c.StatusPending), opencdm_session_status(session, &kid, 16));
    try std.testing.expectEqual(@as(?*c.OpenCDMSession, null), opencdm_get_system_session(sys, &kid, 16, 0));
    const lic = "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AAECAwQFBgcICQoLDA0ODw\",\"k\":\"EBESExQVFhcYGRobHB0eHw\"}]}";
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), opencdm_session_update(session, lic, lic.len));
    try std.testing.expectEqual(@as(usize, 1), probe.updates);
    try std.testing.expectEqual(@as(usize, 1), probe.done);
    try std.testing.expectEqual(@as(c.KeyStatus, c.Usable), opencdm_session_status(session, &kid, 16));
    const held = opencdm_get_system_session(sys, &kid, 16, 10).?;
    try std.testing.expectEqual(session, held);
    _ = opencdm_destruct_session(held);
    _ = opencdm_session_close(session);
    try std.testing.expectEqual(@as(?*c.OpenCDMSession, null), opencdm_get_system_session(sys, &kid, 16, 0));
    _ = opencdm_destruct_session(session);
}

test {
    _ = cenc;
    _ = clearkey;
    _ = widevine;
}
