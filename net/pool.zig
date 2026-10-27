const std = @import("std");
const h3 = @import("h3.zig");
const c = h3.c;

const IDLE_NS = 30 * std.time.ns_per_s;
const BROKEN_NS = 300 * std.time.ns_per_s;
const DISABLE_ENV = "FOTONE_HTTP3";

pub const Sink = extern struct {
    response: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    data: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    done: *const fn (?*anyopaque, c_int) callconv(.c) void,
};

const gpa = std.heap.c_allocator;

const Lock = struct {
    m: c.GMutex = std.mem.zeroes(c.GMutex),

    fn lock(self: *Lock) void {
        c.g_mutex_lock(&self.m);
    }

    fn unlock(self: *Lock) void {
        c.g_mutex_unlock(&self.m);
    }
};

const Route = struct { port: u16, expires: u64, broken_until: u64 = 0 };

var lock: Lock = .{};
var routes: std.StringHashMapUnmanaged(Route) = .empty;
var hosts: std.ArrayList(*Host) = .empty;

fn disabled() bool {
    const v = std.c.getenv(DISABLE_ENV) orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "0");
}

fn routeKey(buf: []u8, host: []const u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port }) catch "";
}

pub fn learn(host: []const u8, port: u16, value: []const u8) void {
    var buf: [300]u8 = undefined;
    const key = routeKey(&buf, host, port);
    if (key.len == 0) return;
    lock.lock();
    defer lock.unlock();
    if (std.mem.eql(u8, std.mem.trim(u8, value, " "), "clear")) {
        if (routes.fetchRemove(key)) |kv| gpa.free(kv.key);
        return;
    }
    const alt = h3.parseAltSvc(value) orelse return;
    const expires = h3.now() + @as(u64, alt.max_age) * std.time.ns_per_s;
    if (routes.getPtr(key)) |r| {
        r.port = alt.port;
        r.expires = expires;
        return;
    }
    const owned = gpa.dupe(u8, key) catch return;
    routes.put(gpa, owned, .{ .port = alt.port, .expires = expires }) catch gpa.free(owned);
}

pub fn route(host: []const u8, port: u16) ?u16 {
    if (disabled()) return null;
    var buf: [300]u8 = undefined;
    const key = routeKey(&buf, host, port);
    lock.lock();
    defer lock.unlock();
    const r = routes.get(key) orelse return null;
    const t = h3.now();
    if (t >= r.expires or t < r.broken_until) return null;
    return r.port;
}

fn markBroken(host: []const u8, port: u16) void {
    var buf: [300]u8 = undefined;
    const key = routeKey(&buf, host, port);
    lock.lock();
    defer lock.unlock();
    if (routes.getPtr(key)) |r| r.broken_until = h3.now() + BROKEN_NS;
}

const Event = struct {
    task: *Task,
    kind: enum { response, data, done },
    bytes: []u8,
    ok: bool = false,
};

const Task = struct {
    refs: std.atomic.Value(u32) = .init(2),
    cancelled: std.atomic.Value(bool) = .init(false),
    main: ?*c.GMainContext,
    sink: Sink,
    ctx: ?*anyopaque,
    req: h3.Request,
    owned: []u8,
    headers: std.ArrayList(u8) = .empty,
    responded: bool = false,

    fn unref(self: *Task) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.headers.deinit(gpa);
        gpa.free(self.owned);
        gpa.destroy(self);
    }

    fn post(self: *Task, kind: @TypeOf(@as(Event, undefined).kind), bytes: []const u8, ok: bool) void {
        const ev = gpa.create(Event) catch return;
        ev.* = .{ .task = self, .kind = kind, .bytes = gpa.dupe(u8, bytes) catch &.{}, .ok = ok };
        _ = self.refs.fetchAdd(1, .acq_rel);
        c.g_main_context_invoke_full(self.main, c.G_PRIORITY_DEFAULT, deliver, ev, release);
    }

    fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
        const ev: *Event = @ptrCast(@alignCast(data.?));
        const t = ev.task;
        if (t.cancelled.load(.acquire)) return c.G_SOURCE_REMOVE;
        switch (ev.kind) {
            .response => t.sink.response(t.ctx, ev.bytes.ptr, ev.bytes.len),
            .data => t.sink.data(t.ctx, ev.bytes.ptr, ev.bytes.len),
            .done => t.sink.done(t.ctx, @intFromBool(ev.ok)),
        }
        return c.G_SOURCE_REMOVE;
    }

    fn release(data: ?*anyopaque) callconv(.c) void {
        const ev: *Event = @ptrCast(@alignCast(data.?));
        if (ev.bytes.len > 0) gpa.free(ev.bytes);
        ev.task.unref();
        gpa.destroy(ev);
    }

    fn of(ctx: ?*anyopaque) *Task {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onHeader(ctx: ?*anyopaque, name: []const u8, value: []const u8) void {
        const self = of(ctx);
        self.headers.appendSlice(gpa, name) catch return;
        self.headers.append(gpa, 0) catch return;
        self.headers.appendSlice(gpa, value) catch return;
        self.headers.append(gpa, 0) catch return;
    }

    fn respond(self: *Task) void {
        if (self.responded) return;
        self.responded = true;
        if (self.headers.items.len > 0) self.post(.response, self.headers.items, false);
    }

    fn onData(ctx: ?*anyopaque, bytes: []const u8) void {
        const self = of(ctx);
        self.respond();
        self.post(.data, bytes, false);
    }

    fn onDone(ctx: ?*anyopaque, ok: bool) void {
        const self = of(ctx);
        if (ok) self.respond();
        self.post(.done, &.{}, ok and self.responded);
        self.unref();
    }
};

const Host = struct {
    name: [:0]u8,
    port: u16,
    alt_port: u16,
    mutex: Lock = .{},
    incoming: std.ArrayList(*Task) = .empty,
    cancels: std.ArrayList(*Task) = .empty,
    live: std.ArrayList(*Task) = .empty,
    wake: c_int,
    dead: bool = false,

    fn signal(self: *Host) void {
        const one: u64 = 1;
        _ = c.write(self.wake, &one, 8);
    }

    fn take(self: *Host, conn: ?*h3.Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.incoming.items) |t| {
            self.live.append(gpa, t) catch {
                t.req.finished = true;
                Task.onDone(t, false);
                continue;
            };
            if (conn) |q| q.submit(&t.req);
        }
        self.incoming.clearRetainingCapacity();
        for (self.cancels.items) |t| {
            const pending = !t.req.finished;
            if (conn) |q| q.cancel(&t.req) else t.req.finished = true;
            if (std.mem.indexOfScalar(*Task, self.live.items, t)) |i| _ = self.live.swapRemove(i);
            if (pending) t.unref();
            t.unref();
        }
        self.cancels.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.live.items.len) {
            if (self.live.items[i].req.finished) _ = self.live.swapRemove(i) else i += 1;
        }
    }

    fn failLive(self: *Host) void {
        self.mutex.lock();
        const live = self.live.toOwnedSlice(gpa) catch &.{};
        self.mutex.unlock();
        for (live) |t| if (!t.req.finished) {
            t.req.finished = true;
            Task.onDone(t, false);
        };
        gpa.free(live);
    }

    fn retire(self: *Host) bool {
        lock.lock();
        defer lock.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.incoming.items.len > 0) return false;
        self.dead = true;
        if (std.mem.indexOfScalar(*Host, hosts.items, self)) |i| _ = hosts.swapRemove(i);
        return true;
    }

    fn run(self: *Host) void {
        const conn = h3.Conn.open(gpa, self.name, self.alt_port) catch {
            markBroken(self.name, self.port);
            self.take(null);
            self.failLive();
            while (!self.retire()) {
                self.take(null);
                self.failLive();
            }
            self.destroy();
            return;
        };
        var idle_since = h3.now();
        while (true) {
            self.take(conn);
            var fds = [2]c.struct_pollfd{
                .{ .fd = conn.fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.wake, .events = c.POLLIN, .revents = 0 },
            };
            const ready = c.poll(&fds, 2, conn.timeoutMs(1000));
            if (ready > 0 and fds[1].revents != 0) {
                var v: u64 = 0;
                _ = c.read(self.wake, &v, 8);
                self.take(conn);
            }
            conn.tick(ready > 0 and fds[0].revents != 0) catch {
                if (!conn.ready()) markBroken(self.name, self.port);
                break;
            };
            if (conn.active > 0) {
                idle_since = h3.now();
            } else if (h3.now() - idle_since > IDLE_NS) {
                if (self.retire()) {
                    conn.close();
                    self.destroy();
                    return;
                }
            }
        }
        conn.failAll();
        self.failLive();
        while (!self.retire()) {
            self.take(null);
            self.failLive();
        }
        conn.close();
        self.destroy();
    }

    fn destroy(self: *Host) void {
        _ = c.close(self.wake);
        self.incoming.deinit(gpa);
        self.cancels.deinit(gpa);
        self.live.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }
};

fn hostFor(name: []const u8, port: u16, alt_port: u16) ?*Host {
    for (hosts.items) |h| if (h.port == port and std.mem.eql(u8, h.name, name) and !h.dead) return h;
    const h = gpa.create(Host) catch return null;
    const wake = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (wake < 0) {
        gpa.destroy(h);
        return null;
    }
    h.* = .{ .name = gpa.dupeZ(u8, name) catch {
        _ = c.close(wake);
        gpa.destroy(h);
        return null;
    }, .port = port, .alt_port = alt_port, .wake = wake };
    hosts.append(gpa, h) catch {
        h.destroy();
        return null;
    };
    const thread = std.Thread.spawn(.{}, Host.run, .{h}) catch {
        _ = hosts.pop();
        h.destroy();
        return null;
    };
    thread.detach();
    return h;
}

pub export fn fotone_h3_learn(host: [*:0]const u8, port: c_uint, value: [*:0]const u8) void {
    learn(std.mem.span(host), @intCast(port), std.mem.span(value));
}

pub export fn fotone_h3_route(host: [*:0]const u8, port: c_uint) c_uint {
    return route(std.mem.span(host), @intCast(port)) orelse 0;
}

pub export fn fotone_h3_start(host: [*:0]const u8, port: c_uint, method: [*:0]const u8, path: [*:0]const u8, headers: [*]const u8, headers_len: usize, sink: *const Sink, ctx: ?*anyopaque, main: ?*c.GMainContext) ?*anyopaque {
    const name = std.mem.span(host);
    const alt = route(name, @intCast(port)) orelse return null;
    const m = std.mem.span(method);
    const p = std.mem.span(path);
    const owned = gpa.alloc(u8, m.len + p.len + headers_len) catch return null;
    @memcpy(owned[0..m.len], m);
    @memcpy(owned[m.len .. m.len + p.len], p);
    @memcpy(owned[m.len + p.len ..], headers[0..headers_len]);
    const task = gpa.create(Task) catch {
        gpa.free(owned);
        return null;
    };
    task.* = .{
        .main = main,
        .sink = sink.*,
        .ctx = ctx,
        .owned = owned,
        .req = .{
            .method = owned[0..m.len],
            .path = owned[m.len .. m.len + p.len],
            .headers = owned[m.len + p.len ..],
            .sink = .{ .ctx = task, .header = Task.onHeader, .data = Task.onData, .done = Task.onDone },
        },
    };
    lock.lock();
    const h = hostFor(name, @intCast(port), alt) orelse {
        lock.unlock();
        gpa.free(owned);
        gpa.destroy(task);
        return null;
    };
    h.mutex.lock();
    h.incoming.append(gpa, task) catch {
        h.mutex.unlock();
        lock.unlock();
        gpa.free(owned);
        gpa.destroy(task);
        return null;
    };
    h.mutex.unlock();
    lock.unlock();
    h.signal();
    return task;
}

pub export fn fotone_h3_cancel(handle: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(handle orelse return));
    if (task.cancelled.swap(true, .acq_rel)) return;
    lock.lock();
    for (hosts.items) |h| {
        h.mutex.lock();
        const owns = std.mem.indexOfScalar(*Task, h.live.items, task) != null or std.mem.indexOfScalar(*Task, h.incoming.items, task) != null;
        if (owns) {
            _ = task.refs.fetchAdd(1, .acq_rel);
            h.cancels.append(gpa, task) catch task.unref();
        }
        h.mutex.unlock();
        if (owns) {
            h.signal();
            break;
        }
    }
    lock.unlock();
}

pub export fn fotone_h3_release(handle: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(handle orelse return));
    task.cancelled.store(true, .release);
    task.unref();
}

test "alt-svc routes expire, clear and survive lookups" {
    learn("example.com", 443, "h3=\":443\"; ma=60");
    try std.testing.expectEqual(@as(?u16, 443), route("example.com", 443));
    try std.testing.expectEqual(@as(?u16, null), route("example.com", 8443));
    learn("example.com", 443, "clear");
    try std.testing.expectEqual(@as(?u16, null), route("example.com", 443));
    learn("example.org", 443, "h3=\":443\"; ma=0");
    try std.testing.expectEqual(@as(?u16, null), route("example.org", 443));
}
