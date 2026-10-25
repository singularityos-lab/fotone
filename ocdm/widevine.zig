const std = @import("std");
const c = @import("c.zig").c;
const cenc = @import("cenc.zig");
const ocdm = @import("ocdm.zig");

pub const KEY_SYSTEM = "com.widevine.alpha";
const INTERFACE = 10;
const LIB = "libwidevinecdm.so";

const Fn = *const anyopaque;

const Cdm = extern struct { vtbl: [*]const Fn };

const SubsampleEntry = extern struct { clear: u32, cipher: u32 };

const InputBuffer = extern struct {
    data: [*]const u8,
    data_size: u32,
    scheme: u32,
    key_id: [*]const u8,
    key_id_size: u32,
    pad0: u32 = 0,
    iv: [*]const u8,
    iv_size: u32,
    pad1: u32 = 0,
    subsamples: ?[*]const SubsampleEntry,
    num_subsamples: u32,
    pad2: u32 = 0,
    crypt: u32,
    skip: u32,
    timestamp: i64 = 0,
};

const KeyInformation = extern struct {
    key_id: [*]const u8,
    key_id_size: u32,
    status: u32,
    system_code: u32,
};

const PlatformChallengeResponse = extern struct {
    signed_data: ?[*]const u8 = null,
    signed_data_length: u32 = 0,
    signed_data_signature: ?[*]const u8 = null,
    signed_data_signature_length: u32 = 0,
    platform_key_certificate: ?[*]const u8 = null,
    platform_key_certificate_length: u32 = 0,
};

const S_SUCCESS = 0;
const S_NO_KEY = 2;

pub fn dataDir(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/fotone/widevine", .{std.mem.span(c.g_get_user_data_dir())}) catch null;
}

fn libPath(buf: []u8) ?[:0]const u8 {
    if (c.g_getenv("FOTONE_WIDEVINE")) |p| if (p[0] != 0) return std.fmt.bufPrintZ(buf, "{s}", .{p}) catch null;
    var d: [4096]u8 = undefined;
    const dir = dataDir(&d) orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/" ++ LIB, .{dir}) catch null;
}

pub fn available() bool {
    if (fake != null) return true;
    var buf: [4096]u8 = undefined;
    const p = libPath(&buf) orelse return false;
    return c.g_file_test(p, c.G_FILE_TEST_IS_REGULAR) != 0;
}

const Job = struct {
    run: *const fn (*Job) void,
    done: bool = false,
    owned: bool = false,
    next: ?*Job = null,
};

const Timer = struct { at: i64, ctx: ?*anyopaque };

var qlock: c.GMutex = std.mem.zeroes(c.GMutex);
var qcond: c.GCond = std.mem.zeroes(c.GCond);
var dcond: c.GCond = std.mem.zeroes(c.GCond);
var head: ?*Job = null;
var tail: ?*Job = null;
var timers: [64]?Timer = .{null} ** 64;
var worker: ?*c.GThread = null;
threadlocal var on_worker = false;

fn post(j: *Job) void {
    c.g_mutex_lock(&qlock);
    defer c.g_mutex_unlock(&qlock);
    if (worker == null) worker = c.g_thread_new("fotone-cdm", loop, null);
    j.next = null;
    if (tail) |t| t.next = j else head = j;
    tail = j;
    c.g_cond_signal(&qcond);
}

fn nextDue() ?usize {
    var best: ?usize = null;
    for (timers, 0..) |t, i| if (t) |x| {
        if (best == null or x.at < timers[best.?].?.at) best = i;
    };
    return best;
}

fn loop(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    on_worker = true;
    c.g_mutex_lock(&qlock);
    while (true) {
        if (head) |j| {
            head = j.next;
            if (head == null) tail = null;
            const owned = j.owned;
            c.g_mutex_unlock(&qlock);
            j.run(j);
            c.g_mutex_lock(&qlock);
            if (!owned) {
                j.done = true;
                c.g_cond_broadcast(&dcond);
            }
            continue;
        }
        if (nextDue()) |i| {
            const now = c.g_get_monotonic_time();
            const t = timers[i].?;
            if (t.at <= now) {
                timers[i] = null;
                c.g_mutex_unlock(&qlock);
                if (instance) |cdm| vcall(cdm, 8, fn (*Cdm, ?*anyopaque) callconv(.c) void, .{t.ctx});
                c.g_mutex_lock(&qlock);
                continue;
            }
            _ = c.g_cond_wait_until(&qcond, &qlock, t.at);
        } else c.g_cond_wait(&qcond, &qlock);
    }
}

fn Ret(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

fn call(comptime f: anytype, args: anytype) Ret(f) {
    if (on_worker) return @call(.auto, f, args);
    const Ctx = struct {
        job: Job,
        args: @TypeOf(args),
        result: Ret(f) = undefined,
        fn run(j: *Job) void {
            const s: *@This() = @fieldParentPtr("job", j);
            s.result = @call(.auto, f, s.args);
        }
    };
    var ctx: Ctx = .{ .job = .{ .run = Ctx.run }, .args = args };
    post(&ctx.job);
    c.g_mutex_lock(&qlock);
    while (!ctx.job.done) c.g_cond_wait(&dcond, &qlock);
    c.g_mutex_unlock(&qlock);
    return ctx.result;
}

fn later(comptime f: anytype, args: anytype) void {
    const Ctx = struct {
        job: Job,
        args: @TypeOf(args),
        fn run(j: *Job) void {
            const s: *@This() = @fieldParentPtr("job", j);
            @call(.auto, f, s.args);
            std.heap.c_allocator.destroy(s);
        }
    };
    const ctx = std.heap.c_allocator.create(Ctx) catch return;
    ctx.* = .{ .job = .{ .run = Ctx.run, .owned = true }, .args = args };
    post(&ctx.job);
}

fn vcall(cdm: *Cdm, comptime idx: usize, comptime F: type, args: anytype) Ret(@as(F, undefined)) {
    const f: *const F = @ptrCast(cdm.vtbl[idx]);
    return @call(.auto, f, .{cdm} ++ args);
}

pub const Session = struct {
    owner: *ocdm.Session,
    sid: [128]u8 = undefined,
    sid_len: usize = 0,
    update: u32 = 0,

    fn name(w: *Session) []const u8 {
        return w.sid[0..w.sid_len];
    }

    fn setName(w: *Session, sid: []const u8) void {
        w.sid_len = @min(sid.len, w.sid.len);
        @memcpy(w.sid[0..w.sid_len], sid[0..w.sid_len]);
        const id = &w.owner.id;
        const n = @min(sid.len, id.len);
        @memcpy(id[0..n], sid[0..n]);
        id[n] = 0;
    }
};

const PromiseKind = enum { create, update, cert, other };

const Promise = struct {
    id: u32,
    kind: PromiseKind,
    session: ?*Session,
    settled: bool = false,
    ok: bool = false,
};

var instance: ?*Cdm = null;
var fake: ?*Cdm = null;
var ready = false;
var failed_load = false;
var promises: [64]?Promise = .{null} ** 64;
var next_promise: u32 = 1;
var list: std.ArrayList(*Session) = .empty;
var creating: ?*Session = null;

fn promise(kind: PromiseKind, w: ?*Session) u32 {
    const id = next_promise;
    next_promise +%= 1;
    for (&promises) |*p| if (p.* == null) {
        p.* = .{ .id = id, .kind = kind, .session = w };
        return id;
    };
    promises[id % promises.len] = .{ .id = id, .kind = kind, .session = w };
    return id;
}

fn take(id: u32) ?Promise {
    for (&promises) |*p| if (p.*) |x| if (x.id == id) {
        p.* = null;
        return x;
    };
    return null;
}

fn bySid(sid: []const u8) ?*Session {
    for (list.items) |w| if (std.mem.eql(u8, w.name(), sid)) return w;
    return null;
}

fn live(w: *Session) bool {
    for (list.items) |x| if (x == w) return true;
    return false;
}

const Buf = extern struct {
    vtbl: *const [7]Fn,
    data: [*]u8,
    cap: u32,
    size: u32,

    fn destroy(b: *Buf) callconv(.c) void {
        std.heap.c_allocator.free(b.data[0..b.cap]);
        std.heap.c_allocator.destroy(b);
    }
    fn capacity(b: *const Buf) callconv(.c) u32 {
        return b.cap;
    }
    fn bytes(b: *Buf) callconv(.c) [*]u8 {
        return b.data;
    }
    fn setSize(b: *Buf, n: u32) callconv(.c) void {
        b.size = @min(n, b.cap);
    }
    fn getSize(b: *const Buf) callconv(.c) u32 {
        return b.size;
    }
    fn dtor(_: *Buf) callconv(.c) void {}

    const VT = [7]Fn{ &destroy, &capacity, &bytes, &setSize, &getSize, &dtor, &dtor };
};

fn allocate(_: *Host, capacity: u32) callconv(.c) ?*Buf {
    const b = std.heap.c_allocator.create(Buf) catch return null;
    const mem = std.heap.c_allocator.alloc(u8, @max(capacity, 1)) catch {
        std.heap.c_allocator.destroy(b);
        return null;
    };
    b.* = .{ .vtbl = &Buf.VT, .data = mem.ptr, .cap = @intCast(mem.len), .size = 0 };
    return b;
}

const Block = extern struct {
    vtbl: *const [6]Fn,
    buf: ?*Buf = null,
    ts: i64 = 0,

    fn setBuffer(b: *Block, buf: ?*Buf) callconv(.c) void {
        b.buf = buf;
    }
    fn getBuffer(b: *Block) callconv(.c) ?*Buf {
        return b.buf;
    }
    fn setTs(b: *Block, ts: i64) callconv(.c) void {
        b.ts = ts;
    }
    fn getTs(b: *const Block) callconv(.c) i64 {
        return b.ts;
    }
    fn dtor(_: *Block) callconv(.c) void {}

    const VT = [6]Fn{ &setBuffer, &getBuffer, &setTs, &getTs, &dtor, &dtor };
};

const Host = extern struct { vtbl: *const [20]Fn };

fn setTimer(_: *Host, delay: i64, ctx: ?*anyopaque) callconv(.c) void {
    c.g_mutex_lock(&qlock);
    defer c.g_mutex_unlock(&qlock);
    const at = c.g_get_monotonic_time() + @max(delay, 0) * 1000;
    for (&timers) |*t| if (t.* == null) {
        t.* = .{ .at = at, .ctx = ctx };
        c.g_cond_signal(&qcond);
        return;
    };
}

fn wallTime(_: *Host) callconv(.c) f64 {
    return @as(f64, @floatFromInt(c.g_get_real_time())) / 1000000.0;
}

fn onInitialized(_: *Host, ok: bool) callconv(.c) void {
    ready = ok;
    failed_load = !ok;
}

fn onKeyStatusPromise(_: *Host, id: u32, _: u32) callconv(.c) void {
    _ = take(id);
}

fn onNewSession(_: *Host, id: u32, sid: ?[*]const u8, len: u32) callconv(.c) void {
    const p = take(id) orelse return;
    const w = p.session orelse return;
    if (sid) |s| if (len > 0 and w.sid_len == 0) w.setName(s[0..len]);
}

fn settle(id: u32, ok: bool, message: []const u8) void {
    const p = take(id) orelse return;
    const w = p.session orelse return;
    if (!live(w)) return;
    switch (p.kind) {
        .update => {
            if (w.update == id) w.update = 0;
            if (ok) w.owner.updated() else fail(w, message);
        },
        .create => if (!ok) fail(w, message),
        else => {},
    }
}

fn fail(w: *Session, message: []const u8) void {
    var buf: [256:0]u8 = undefined;
    const n = @min(message.len, buf.len);
    @memcpy(buf[0..n], message[0..n]);
    buf[n] = 0;
    w.owner.failed(if (n == 0) "widevine rejected the request" else &buf);
}

fn onResolve(_: *Host, id: u32) callconv(.c) void {
    settle(id, true, "");
}

fn onReject(_: *Host, id: u32, _: u32, _: u32, msg: ?[*]const u8, len: u32) callconv(.c) void {
    settle(id, false, if (msg) |m| m[0..len] else "");
}

fn onMessage(_: *Host, sid: [*]const u8, sid_len: u32, kind: u32, msg: [*]const u8, len: u32) callconv(.c) void {
    const w = bySid(sid[0..sid_len]) orelse blk: {
        const x = creating orelse return;
        if (x.sid_len == 0) x.setName(sid[0..sid_len]);
        break :blk x;
    };
    w.owner.challenge(@intCast(@min(kind, 9)), msg[0..len]);
}

fn statusOf(s: u32) c.KeyStatus {
    return switch (s) {
        0 => c.Usable,
        2 => c.Expired,
        3 => c.OutputRestricted,
        4 => c.OutputDownscaled,
        5 => c.StatusPending,
        6 => c.Released,
        else => c.InternalError,
    };
}

fn onKeysChange(_: *Host, sid: [*]const u8, sid_len: u32, _: bool, keys: ?[*]const KeyInformation, count: u32) callconv(.c) void {
    const w = bySid(sid[0..sid_len]) orelse return;
    const all = if (keys) |k| k[0..count] else &[_]KeyInformation{};
    for (all) |k| {
        if (k.key_id_size != 16) continue;
        w.owner.setKey(k.key_id[0..16].*, null, statusOf(k.status));
    }
    for (all) |k| if (k.key_id_size == 16) w.owner.keyUpdated(k.key_id[0..16]);
    if (w.update == 0) w.owner.updated();
}

fn onExpiration(_: *Host, _: [*]const u8, _: u32, _: f64) callconv(.c) void {}

fn onClosed(_: *Host, sid: [*]const u8, sid_len: u32) callconv(.c) void {
    const w = bySid(sid[0..sid_len]) orelse return;
    const o = w.owner;
    for (o.keys[0..o.count]) |*k| o.setKey(k.id, null, c.Released);
    for (o.keys[0..o.count]) |*k| o.keyUpdated(&k.id);
    o.updated();
}

fn platformChallenge(_: *Host, _: [*]const u8, _: u32, _: [*]const u8, _: u32) callconv(.c) void {
    later(answerChallenge, .{});
}

fn answerChallenge() void {
    const cdm = instance orelse return;
    const r: PlatformChallengeResponse = .{};
    vcall(cdm, 16, fn (*Cdm, *const PlatformChallengeResponse) callconv(.c) void, .{&r});
}

fn enableProtection(_: *Host, _: u32) callconv(.c) void {}

fn queryProtection(_: *Host) callconv(.c) void {
    later(answerProtection, .{});
}

fn answerProtection() void {
    const cdm = instance orelse return;
    vcall(cdm, 17, fn (*Cdm, u32, u32, u32) callconv(.c) void, .{ 0, 0, 0 });
}

fn deferredDone(_: *Host, _: u32, _: u32) callconv(.c) void {}

const Client = extern struct { vtbl: [*]const Fn };

const File = extern struct {
    vtbl: *const [6]Fn,
    client: *Client,
    name: [64]u8 = undefined,
    len: usize = 0,
    open: bool = false,

    fn path(f: *const File, buf: []u8) ?[:0]const u8 {
        var d: [4096]u8 = undefined;
        const dir = dataDir(&d) orelse return null;
        return std.fmt.bufPrintZ(buf, "{s}/storage/{s}", .{ dir, f.name[0..f.len] }) catch null;
    }

    fn opened(f: *File, n: [*]const u8, len: u32) callconv(.c) void {
        if (f.open or !validName(n[0..len])) return later(openDone, .{ f, @as(u32, if (f.open) 1 else 2) });
        @memcpy(f.name[0..len], n[0..len]);
        f.len = len;
        var d: [4096]u8 = undefined;
        const dir = dataDir(&d) orelse return later(openDone, .{ f, @as(u32, 2) });
        var sb: [4096]u8 = undefined;
        const store = std.fmt.bufPrintZ(&sb, "{s}/storage", .{dir}) catch return later(openDone, .{ f, @as(u32, 2) });
        if (c.g_mkdir_with_parents(store, 0o700) != 0) return later(openDone, .{ f, @as(u32, 2) });
        f.open = true;
        later(openDone, .{ f, @as(u32, 0) });
    }

    fn read(f: *File) callconv(.c) void {
        later(readDone, .{f});
    }

    fn write(f: *File, data: [*]const u8, size: u32) callconv(.c) void {
        const copy = std.heap.c_allocator.dupe(u8, data[0..size]) catch return later(writeDone, .{ f, @as(u32, 2) });
        later(writeNow, .{ f, copy });
    }

    fn closed(f: *File) callconv(.c) void {
        later(free, .{f});
    }

    fn dtor(_: *File) callconv(.c) void {}

    const VT = [6]Fn{ &opened, &read, &write, &closed, &dtor, &dtor };
};

fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64 or n[0] == '_' or n[0] == '.') return false;
    for (n) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

fn free(f: *File) void {
    std.heap.c_allocator.destroy(f);
}

fn openDone(f: *File, status: u32) void {
    vcallClient(f.client, 0, fn (*Client, u32) callconv(.c) void, .{status});
}

fn readDone(f: *File) void {
    var pb: [4096]u8 = undefined;
    const p = (if (f.open) f.path(&pb) else null) orelse return vcallClient(f.client, 1, fn (*Client, u32, ?[*]const u8, u32) callconv(.c) void, .{ 2, null, 0 });
    if (c.g_file_test(p, c.G_FILE_TEST_EXISTS) == 0) return vcallClient(f.client, 1, fn (*Client, u32, ?[*]const u8, u32) callconv(.c) void, .{ 0, null, 0 });
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(p, &data, &len, null) == 0) return vcallClient(f.client, 1, fn (*Client, u32, ?[*]const u8, u32) callconv(.c) void, .{ 2, null, 0 });
    defer c.g_free(data);
    vcallClient(f.client, 1, fn (*Client, u32, ?[*]const u8, u32) callconv(.c) void, .{ 0, data, @as(u32, @intCast(len)) });
}

fn writeNow(f: *File, data: []u8) void {
    defer std.heap.c_allocator.free(data);
    var pb: [4096]u8 = undefined;
    const p = (if (f.open) f.path(&pb) else null) orelse return writeDone(f, 2);
    if (data.len == 0) {
        _ = std.c.unlink(p);
        return writeDone(f, 0);
    }
    writeDone(f, if (save(p, data)) 0 else 2);
}

fn save(p: [*:0]const u8, data: []const u8) bool {
    return c.g_file_set_contents_full(p, data.ptr, @intCast(data.len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o600, null) != 0;
}

fn writeDone(f: *File, status: u32) void {
    vcallClient(f.client, 2, fn (*Client, u32) callconv(.c) void, .{status});
}

fn vcallClient(cl: *Client, comptime idx: usize, comptime F: type, args: anytype) void {
    const f: *const F = @ptrCast(cl.vtbl[idx]);
    @call(.auto, f, .{cl} ++ args);
}

fn createFile(_: *Host, client: *Client) callconv(.c) ?*File {
    const f = std.heap.c_allocator.create(File) catch return null;
    f.* = .{ .vtbl = &File.VT, .client = client };
    return f;
}

fn storageId(_: *Host, version: u32) callconv(.c) void {
    later(answerStorage, .{version});
}

fn answerStorage(version: u32) void {
    const cdm = instance orelse return;
    var id: [32]u8 = undefined;
    const ok = (version == 0 or version == 1) and loadStorageId(&id);
    if (ok) vcall(cdm, 18, fn (*Cdm, u32, ?[*]const u8, u32) callconv(.c) void, .{ 1, &id, 32 }) else vcall(cdm, 18, fn (*Cdm, u32, ?[*]const u8, u32) callconv(.c) void, .{ version, null, 0 });
}

fn loadStorageId(id: *[32]u8) bool {
    var d: [4096]u8 = undefined;
    const dir = dataDir(&d) orelse return false;
    var pb: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pb, "{s}/storage-id", .{dir}) catch return false;
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(p, &data, &len, null) != 0) {
        defer c.g_free(data);
        if (len == 32) {
            @memcpy(id, data[0..32]);
            return true;
        }
    }
    if (std.c.getrandom(id, 32, 0) != 32) return false;
    var db: [4096]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&db, "{s}", .{dir}) catch return false;
    if (c.g_mkdir_with_parents(dz, 0o700) != 0) return false;
    return save(p, id);
}

fn hostDtor(_: *Host) callconv(.c) void {}

const HOST_VT = [20]Fn{
    &allocate,         &setTimer,       &wallTime,          &onInitialized, &onKeyStatusPromise,
    &onNewSession,     &onResolve,      &onReject,          &onMessage,     &onKeysChange,
    &onExpiration,     &onClosed,       &platformChallenge, &enableProtection, &queryProtection,
    &deferredDone,     &createFile,     &storageId,         &hostDtor,      &hostDtor,
};

var host: Host = .{ .vtbl = &HOST_VT };

fn getHost(version: c_int, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    return if (version == INTERFACE) @ptrCast(&host) else null;
}

fn ensure() bool {
    if (instance != null) return ready;
    if (failed_load) return false;
    failed_load = true;
    if (fake) |f| {
        instance = f;
    } else {
        var buf: [4096]u8 = undefined;
        const p = libPath(&buf) orelse return false;
        const lib = std.c.dlopen(p, .{ .NOW = true }) orelse return false;
        const init: *const fn () callconv(.c) void = @ptrCast(std.c.dlsym(lib, "InitializeCdmModule_4") orelse return false);
        const create: *const fn (c_int, [*]const u8, u32, *const anyopaque, ?*anyopaque) callconv(.c) ?*Cdm = @ptrCast(std.c.dlsym(lib, "CreateCdmInstance") orelse return false);
        init();
        instance = create(INTERFACE, KEY_SYSTEM, KEY_SYSTEM.len, @ptrCast(&getHost), null) orelse return false;
    }
    failed_load = false;
    vcall(instance.?, 0, fn (*Cdm, bool, bool, bool) callconv(.c) void, .{ false, true, false });
    return ready;
}

fn initType(t: []const u8) ?u32 {
    if (std.mem.eql(u8, t, "cenc")) return 0;
    if (std.mem.eql(u8, t, "keyids")) return 1;
    if (std.mem.eql(u8, t, "webm")) return 2;
    return null;
}

fn openNow(s: *ocdm.Session, cert: ?[]u8, init_type: []const u8, init: []const u8) c.OpenCDMError {
    if (!ensure()) return c.ERROR_KEYSYSTEM_NOT_SUPPORTED;
    const kind = initType(init_type) orelse return c.ERROR_INVALID_ARG;
    const cdm = instance.?;
    const w = std.heap.c_allocator.create(Session) catch return c.ERROR_OUT_OF_MEMORY;
    w.* = .{ .owner = s };
    list.append(std.heap.c_allocator, w) catch {
        std.heap.c_allocator.destroy(w);
        return c.ERROR_OUT_OF_MEMORY;
    };
    s.cdm = w;
    if (cert) |b| vcall(cdm, 2, fn (*Cdm, u32, [*]const u8, u32) callconv(.c) void, .{ promise(.cert, null), b.ptr, @as(u32, @intCast(b.len)) });
    creating = w;
    defer creating = null;
    const kind_session: u32 = if (s.persistent) 1 else 0;
    vcall(cdm, 3, fn (*Cdm, u32, u32, u32, [*]const u8, u32) callconv(.c) void, .{ promise(.create, w), kind_session, kind, init.ptr, @as(u32, @intCast(init.len)) });
    return c.ERROR_NONE;
}

pub fn open(s: *ocdm.Session, cert: ?[]u8, init_type: []const u8, init: []const u8) c.OpenCDMError {
    return call(openNow, .{ s, cert, init_type, init });
}

fn updateNow(s: *ocdm.Session, message: []const u8) c.OpenCDMError {
    const w = s.cdm orelse return c.ERROR_INVALID_SESSION;
    const cdm = instance orelse return c.ERROR_INVALID_SESSION;
    const id = promise(.update, w);
    w.update = id;
    const sid = w.name();
    vcall(cdm, 5, fn (*Cdm, u32, [*]const u8, u32, [*]const u8, u32) callconv(.c) void, .{ id, sid.ptr, @as(u32, @intCast(sid.len)), message.ptr, @as(u32, @intCast(message.len)) });
    return c.ERROR_NONE;
}

pub fn update(s: *ocdm.Session, message: []const u8) c.OpenCDMError {
    return call(updateNow, .{ s, message });
}

pub fn load(s: *ocdm.Session) c.OpenCDMError {
    _ = s;
    return c.ERROR_METHOD_NOT_IMPLEMENTED;
}

fn removeNow(s: *ocdm.Session) c.OpenCDMError {
    const w = s.cdm orelse return c.ERROR_INVALID_SESSION;
    const cdm = instance orelse return c.ERROR_INVALID_SESSION;
    const sid = w.name();
    vcall(cdm, 7, fn (*Cdm, u32, [*]const u8, u32) callconv(.c) void, .{ promise(.other, w), sid.ptr, @as(u32, @intCast(sid.len)) });
    return c.ERROR_NONE;
}

pub fn remove(s: *ocdm.Session) c.OpenCDMError {
    return call(removeNow, .{s});
}

fn closeNow(w: *Session) void {
    for (list.items, 0..) |x, i| if (x == w) {
        _ = list.swapRemove(i);
        break;
    };
    for (&promises) |*p| if (p.*) |x| if (x.session == w) {
        p.*.?.session = null;
    };
    if (instance) |cdm| if (w.sid_len > 0) {
        const sid = w.name();
        vcall(cdm, 6, fn (*Cdm, u32, [*]const u8, u32) callconv(.c) void, .{ promise(.other, null), sid.ptr, @as(u32, @intCast(sid.len)) });
    };
    std.heap.c_allocator.destroy(w);
}

pub fn close(w: *Session) void {
    call(closeNow, .{w});
}

fn decryptNow(s: *ocdm.Session, mode: cenc.Mode, pattern: cenc.Pattern, kid: []const u8, iv: []const u8, data: []u8, subs: []const cenc.Subsample) c.OpenCDMError {
    _ = s;
    const cdm = instance orelse return c.ERROR_INVALID_SESSION;
    if (kid.len != 16 or (iv.len != 8 and iv.len != 16)) return c.ERROR_INVALID_DECRYPT_BUFFER;
    var iv16: [16]u8 = .{0} ** 16;
    @memcpy(iv16[0..iv.len], iv);
    var entries: [512]SubsampleEntry = undefined;
    for (subs, 0..) |x, i| entries[i] = .{ .clear = x.clear, .cipher = x.encrypted };
    const input: InputBuffer = .{
        .data = data.ptr,
        .data_size = @intCast(data.len),
        .scheme = if (mode == .cbcs) 2 else 1,
        .key_id = kid.ptr,
        .key_id_size = 16,
        .iv = &iv16,
        .iv_size = 16,
        .subsamples = if (subs.len > 0) &entries else null,
        .num_subsamples = @intCast(subs.len),
        .crypt = pattern.crypt,
        .skip = pattern.skip,
    };
    var block: Block = .{ .vtbl = &Block.VT };
    const st = vcall(cdm, 9, fn (*Cdm, *const InputBuffer, *Block) callconv(.c) u32, .{ &input, &block });
    defer if (block.buf) |b| Buf.destroy(b);
    if (st == S_NO_KEY) return c.ERROR_INVALID_ACCESSOR;
    if (st != S_SUCCESS) return c.ERROR_INVALID_DECRYPT_BUFFER;
    const out = block.buf orelse return c.ERROR_INVALID_DECRYPT_BUFFER;
    if (out.size != data.len) return c.ERROR_INVALID_DECRYPT_BUFFER;
    @memcpy(data, out.data[0..out.size]);
    return c.ERROR_NONE;
}

pub fn decrypt(s: *ocdm.Session, mode: cenc.Mode, pattern: cenc.Pattern, kid: []const u8, iv: []const u8, data: []u8, subs: []const cenc.Subsample) c.OpenCDMError {
    return call(decryptNow, .{ s, mode, pattern, kid, iv, data, subs });
}

const Fake = struct {
    cdm: Cdm = .{ .vtbl = &VT },
    key: [16]u8 = .{0x5a} ** 16,
    usable: bool = false,

    fn h() *Host {
        return &host;
    }
    fn hostCall(comptime idx: usize, comptime F: type, args: anytype) void {
        const f: *const F = @ptrCast(HOST_VT[idx]);
        @call(.auto, f, .{h()} ++ args);
    }
    fn initialize(_: *Cdm, _: bool, _: bool, _: bool) callconv(.c) void {
        hostCall(3, fn (*Host, bool) callconv(.c) void, .{true});
    }
    fn create(_: *Cdm, id: u32, _: u32, _: u32, _: [*]const u8, _: u32) callconv(.c) void {
        hostCall(5, fn (*Host, u32, ?[*]const u8, u32) callconv(.c) void, .{ id, "abc123", 6 });
        hostCall(8, fn (*Host, [*]const u8, u32, u32, [*]const u8, u32) callconv(.c) void, .{ "abc123", 6, 0, "challenge", 9 });
    }
    fn updateSession(cdm: *Cdm, id: u32, sid: [*]const u8, sid_len: u32, _: [*]const u8, _: u32) callconv(.c) void {
        const self: *Fake = @fieldParentPtr("cdm", cdm);
        self.usable = true;
        const kid = [_]u8{7} ** 16;
        const info = [_]KeyInformation{.{ .key_id = &kid, .key_id_size = 16, .status = 0, .system_code = 0 }};
        hostCall(9, fn (*Host, [*]const u8, u32, bool, ?[*]const KeyInformation, u32) callconv(.c) void, .{ sid, sid_len, true, &info, 1 });
        hostCall(6, fn (*Host, u32) callconv(.c) void, .{id});
    }
    fn nop(_: *Cdm) callconv(.c) void {}
    fn decryptBlock(cdm: *Cdm, in: *const InputBuffer, out: *Block) callconv(.c) u32 {
        const self: *Fake = @fieldParentPtr("cdm", cdm);
        if (!self.usable) return S_NO_KEY;
        const b = allocate(h(), in.data_size).?;
        for (b.data[0..in.data_size], in.data[0..in.data_size]) |*o, i| o.* = i ^ 0xff;
        b.size = in.data_size;
        out.buf = b;
        return S_SUCCESS;
    }

    const VT = blk: {
        var t = [_]Fn{@as(Fn, &nop)} ** 22;
        t[0] = &initialize;
        t[3] = &create;
        t[5] = &updateSession;
        t[9] = &decryptBlock;
        break :blk t;
    };
};

test "the widevine bridge drives a module through its vtables on one thread" {
    var f: Fake = .{};
    fake = &f.cdm;
    defer fake = null;
    try std.testing.expect(available());
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), @import("ocdm.zig").opencdm_is_type_supported(KEY_SYSTEM, "video/mp4"));
    const sys: *ocdm.System = @ptrCast(@alignCast(@import("ocdm.zig").opencdm_create_system(KEY_SYSTEM).?));
    const Probe = struct {
        var msg: [32]u8 = undefined;
        var len: usize = 0;
        var done: usize = 0;
        fn onChallenge(_: ?*c.OpenCDMSession, _: ?*anyopaque, _: [*c]const u8, ch: [*c]const u8, n: u16) callconv(.c) void {
            len = n;
            @memcpy(msg[0..n], ch[0..n]);
        }
        fn onDone(_: ?*const c.OpenCDMSession, _: ?*anyopaque) callconv(.c) void {
            done += 1;
        }
    };
    var cbs: c.OpenCDMSessionCallbacks = .{ .process_challenge_callback = Probe.onChallenge, .keys_updated_callback = Probe.onDone };
    var raw: ?*c.OpenCDMSession = null;
    const init = [_]u8{0} ** 32;
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), @import("ocdm.zig").opencdm_construct_session(@ptrCast(sys), c.Temporary, "cenc", &init, init.len, null, 0, &cbs, null, &raw));
    try std.testing.expectEqualStrings("0:Type:challenge", Probe.msg[0..Probe.len]);
    try std.testing.expectEqualStrings("abc123", std.mem.span(@import("ocdm.zig").opencdm_session_id(raw)));
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), @import("ocdm.zig").opencdm_session_update(raw, "license", 7));
    try std.testing.expectEqual(@as(usize, 1), Probe.done);
    const kid = [_]u8{7} ** 16;
    try std.testing.expectEqual(@as(c.KeyStatus, c.Usable), @import("ocdm.zig").opencdm_session_status(raw, &kid, 16));
    const s: *ocdm.Session = @ptrCast(@alignCast(raw.?));
    var data = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(@as(c.OpenCDMError, c.ERROR_NONE), decrypt(s, .ctr, .{}, &kid, &[_]u8{0} ** 8, &data, &.{}));
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xfd, 0xfc }, &data);
    _ = @import("ocdm.zig").opencdm_session_close(raw);
    _ = @import("ocdm.zig").opencdm_destruct_session(raw);
    _ = @import("ocdm.zig").opencdm_destruct_system(@ptrCast(sys));
}

test "storage names cannot leave the store" {
    try std.testing.expect(validName("license.bin"));
    try std.testing.expect(!validName("../x"));
    try std.testing.expect(!validName("_hidden"));
    try std.testing.expect(!validName(""));
}
