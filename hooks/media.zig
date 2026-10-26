const std = @import("std");
const linux = std.os.linux;

const Kind = enum(u32) { open = 1, release, close, ready, caps, frame, eos, failure, play, data, need, control, state };

const Head = extern struct { kind: u32, size: u32 };

const Frame = extern struct {
    id: u64,
    slot: i64,
    flags: u32,
    buffer_flags: u32,
    offset: u64,
    size: u64,
    maxsize: u64,
    pts: u64,
    dts: u64,
    duration: u64,
};

const Play = extern struct { flags: u32, pad: u32 = 0, size: u64 };
pub const Need = extern struct { offset: u64, length: u32, pad: u32 = 0 };
const Control = extern struct { op: u32, pad: u32 = 0, value: f64 };
const State = extern struct { position: i64, duration: i64, flags: u32, pad: u32 = 0 };

const MAX = 65536;
const CHUNK = MAX - @sizeOf(Head) - 8;
const FLAG_ISOLATED: u32 = 1;
const SLOTS = 8;
pub const LIMIT = 32 << 20;
pub const BACK = 1 << 20;
pub const AHEAD = 1 << 20;

pub const Events = extern struct {
    ctx: ?*anyopaque,
    restart: *const fn (?*anyopaque, u64) callconv(.c) void,
    frame: *const fn (?*anyopaque) callconv(.c) void,
    state: *const fn (?*anyopaque, i64, i64, u32) callconv(.c) void,
    size: *const fn (?*anyopaque, u32, u32) callconv(.c) void,
    ended: *const fn (?*anyopaque) callconv(.c) void,
    failed: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
};

pub const Copy = *const fn (?*anyopaque, [*]const u8, u32, u32, u32, u64) callconv(.c) void;

pub const Stream = struct {
    start: u64 = 0,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    end: ?u64 = null,
    stopped: bool = false,

    pub const Fed = enum { ok, stale, full };
    pub const Take = union(enum) { bytes: []const u8, wait, eof, miss };

    pub fn feed(self: *Stream, offset: u64, data: []const u8) Fed {
        if (offset != self.start + self.bytes.items.len) return .stale;
        if (self.bytes.items.len + data.len > LIMIT) {
            self.stopped = true;
            return .full;
        }
        self.bytes.appendSlice(std.heap.c_allocator, data) catch return .full;
        return .ok;
    }

    pub fn take(self: *Stream, want: Need) Take {
        const have = self.start + self.bytes.items.len;
        if (want.offset < self.start) return .miss;
        if (want.offset > have) return if (self.stopped or want.offset - have > AHEAD) .miss else .wait;
        if (want.offset == have) {
            if (self.end) |e| {
                if (e <= want.offset) return .eof;
            }
            return if (self.stopped) .miss else .wait;
        }
        const from: usize = @intCast(want.offset - self.start);
        const n = @min(@as(usize, want.length), self.bytes.items.len - from, CHUNK * 16);
        return .{ .bytes = self.bytes.items[from .. from + n] };
    }

    pub fn consume(self: *Stream, upto: u64) void {
        if (upto < self.start + BACK) return;
        const n: usize = @intCast(@min(upto - BACK - self.start, self.bytes.items.len));
        const rest = self.bytes.items.len - n;
        std.mem.copyForwards(u8, self.bytes.items[0..rest], self.bytes.items[n..]);
        self.bytes.shrinkRetainingCapacity(rest);
        self.start += n;
    }

    pub fn reset(self: *Stream, offset: u64) void {
        self.bytes.clearRetainingCapacity();
        self.start = offset;
        self.stopped = false;
    }

    pub fn deinit(self: *Stream) void {
        self.bytes.deinit(std.heap.c_allocator);
    }
};

pub fn field(caps: []const u8, name: []const u8) ?u32 {
    var it = std.mem.splitSequence(u8, caps, ", ");
    while (it.next()) |part| {
        if (!std.mem.startsWith(u8, part, name)) continue;
        const rest = part[name.len..];
        if (!std.mem.startsWith(u8, rest, "=(int)")) continue;
        const digits = rest["=(int)".len..];
        var n: usize = 0;
        while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
        return std.fmt.parseInt(u32, digits[0..n], 10) catch null;
    }
    return null;
}

const Map = struct { id: i64, ptr: [*]u8, len: usize };

const Shown = struct {
    id: u64,
    ptr: [*]const u8,
    len: usize,
    pts: u64,
    fd: i32,
    whole: usize,
};

const Media = struct {
    fd: i32,
    events: Events,
    lock: std.c.pthread_mutex_t = .{},
    thread: std.c.pthread_t = undefined,
    stream: Stream = .{},
    want: ?Need = null,
    slots: [SLOTS]?Map = .{null} ** SLOTS,
    shown: ?Shown = null,
    width: u32 = 0,
    height: u32 = 0,
};

fn send(fd: i32, kind: Kind, parts: []const []const u8) bool {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    var head = Head{ .kind = @intFromEnum(kind), .size = @intCast(total) };
    var iov: [4]std.posix.iovec_const = undefined;
    iov[0] = .{ .base = @ptrCast(&head), .len = @sizeOf(Head) };
    for (parts, 1..) |p, i| iov[i] = .{ .base = p.ptr, .len = p.len };
    const msg = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = parts.len + 1, .control = null, .controllen = 0, .flags = 0 };
    while (true) {
        const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return true,
            .INTR => continue,
            else => return false,
        }
    }
}

const Msg = struct { kind: Kind, body: []u8, fd: i32 };

fn recv(fd: i32, buf: []u8) ?Msg {
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var ctl: [64]u8 align(8) = undefined;
    var msg = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = ctl.len, .flags = 0 };
    var n: usize = 0;
    while (true) {
        const rc = linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                n = rc;
                break;
            },
            .INTR => continue,
            else => return null,
        }
    }
    var got: i32 = -1;
    const hdr = 16;
    if (msg.controllen >= hdr) {
        const len = std.mem.readInt(usize, ctl[0..8], .little);
        const level = std.mem.readInt(i32, ctl[8..12], .little);
        const kind = std.mem.readInt(i32, ctl[12..16], .little);
        if (level == linux.SOL.SOCKET and kind == 1) {
            const count = (len - hdr) / 4;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const f = std.mem.readInt(i32, ctl[hdr + 4 * i ..][0..4], .little);
                if (i == 0) got = f else _ = linux.close(f);
            }
        }
    }
    if (n < @sizeOf(Head) or n == 0) {
        if (got >= 0) _ = linux.close(got);
        return null;
    }
    const head: *align(1) const Head = @ptrCast(buf.ptr);
    const kind = std.enums.fromInt(Kind, head.kind);
    if (kind == null or head.size + @sizeOf(Head) != n) {
        if (got >= 0) _ = linux.close(got);
        return if (kind == null) .{ .kind = .close, .body = buf[0..0], .fd = -1 } else null;
    }
    return .{ .kind = kind.?, .body = buf[@sizeOf(Head)..n], .fd = got };
}

fn asStruct(comptime T: type, body: []const u8) ?T {
    if (body.len < @sizeOf(T)) return null;
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), body[0..@sizeOf(T)]);
    return v;
}

fn serve(m: *Media) ?u64 {
    const want = m.want orelse return null;
    switch (m.stream.take(want)) {
        .bytes => |b| {
            var at = want.offset;
            var rest = b;
            while (rest.len > 0) {
                const n = @min(rest.len, CHUNK);
                var off = at;
                if (!send(m.fd, .data, &.{ std.mem.asBytes(&off), rest[0..n] })) break;
                at += n;
                rest = rest[n..];
            }
            m.stream.consume(at);
            m.want = null;
        },
        .eof => {
            var off = want.offset;
            _ = send(m.fd, .data, &.{std.mem.asBytes(&off)});
            m.want = null;
        },
        .miss => {
            m.stream.reset(want.offset);
            return want.offset;
        },
        .wait => {},
    }
    return null;
}

fn mapSlot(m: *Media, id: i64, fd: i32, size: usize) ?[*]u8 {
    for (m.slots) |o| {
        if (o) |s| {
            if (s.id == id) {
                if (fd >= 0) _ = linux.close(fd);
                return s.ptr;
            }
        }
    }
    if (fd < 0) return null;
    defer _ = linux.close(fd);
    const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const ptr: [*]u8 = @ptrFromInt(rc);
    var victim: usize = 0;
    for (m.slots, 0..) |o, i| {
        if (o == null) {
            victim = i;
            break;
        }
        if (o.?.id < m.slots[victim].?.id) victim = i;
    }
    if (m.slots[victim]) |old| _ = linux.munmap(old.ptr, old.len);
    m.slots[victim] = .{ .id = id, .ptr = ptr, .len = size };
    return ptr;
}

fn unshow(m: *Media) void {
    const s = m.shown orelse return;
    m.shown = null;
    if (s.fd >= 0) {
        _ = linux.munmap(@constCast(s.ptr), s.whole);
        _ = linux.close(s.fd);
    }
    var id = s.id;
    _ = send(m.fd, .release, &.{std.mem.asBytes(&id)});
}

fn onFrame(m: *Media, f: Frame, fd: i32) void {
    var shown = Shown{ .id = f.id, .ptr = undefined, .len = @intCast(f.size), .pts = f.pts, .fd = -1, .whole = 0 };
    if (f.slot >= 0) {
        const base = mapSlot(m, f.slot, fd, @intCast(f.maxsize)) orelse {
            var id = f.id;
            _ = send(m.fd, .release, &.{std.mem.asBytes(&id)});
            return;
        };
        shown.ptr = base;
    } else {
        const whole: usize = @intCast(f.offset + f.maxsize);
        const rc = linux.mmap(null, whole, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (fd < 0 or linux.errno(rc) != .SUCCESS) {
            if (fd >= 0) _ = linux.close(fd);
            var id = f.id;
            _ = send(m.fd, .release, &.{std.mem.asBytes(&id)});
            return;
        }
        shown.ptr = @as([*]const u8, @ptrFromInt(rc)) + @as(usize, @intCast(f.offset));
        shown.fd = fd;
        shown.whole = whole;
    }
    unshow(m);
    m.shown = shown;
}

fn reader(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const m: *Media = @ptrCast(@alignCast(arg));
    const ev = m.events;
    var buf: [MAX]u8 = undefined;
    while (true) {
        const msg = recv(m.fd, &buf) orelse break;
        switch (msg.kind) {
            .need => {
                const n = asStruct(Need, msg.body) orelse continue;
                _ = std.c.pthread_mutex_lock(&m.lock);
                m.want = n;
                const restart = serve(m);
                _ = std.c.pthread_mutex_unlock(&m.lock);
                if (restart) |at| ev.restart(ev.ctx, at);
            },
            .caps => {
                const text = std.mem.sliceTo(msg.body, 0);
                const w = field(text, "width") orelse continue;
                const h = field(text, "height") orelse continue;
                _ = std.c.pthread_mutex_lock(&m.lock);
                const changed = w != m.width or h != m.height;
                m.width = w;
                m.height = h;
                _ = std.c.pthread_mutex_unlock(&m.lock);
                if (changed) ev.size(ev.ctx, w, h);
            },
            .frame => {
                const f = asStruct(Frame, msg.body) orelse {
                    if (msg.fd >= 0) _ = linux.close(msg.fd);
                    continue;
                };
                _ = std.c.pthread_mutex_lock(&m.lock);
                onFrame(m, f, msg.fd);
                _ = std.c.pthread_mutex_unlock(&m.lock);
                ev.frame(ev.ctx);
            },
            .state => {
                const s = asStruct(State, msg.body) orelse continue;
                ev.state(ev.ctx, s.position, s.duration, s.flags);
            },
            .eos => ev.ended(ev.ctx),
            .failure => {
                const text = if (msg.body.len > 8) msg.body[8..] else msg.body[0..0];
                var it = std.mem.splitScalar(u8, text, 0);
                _ = it.next();
                const message = it.next() orelse "";
                var z: [512]u8 = undefined;
                const n = @min(message.len, z.len - 1);
                @memcpy(z[0..n], message[0..n]);
                z[n] = 0;
                ev.failed(ev.ctx, z[0..n :0]);
            },
            else => if (msg.fd >= 0) {
                _ = linux.close(msg.fd);
            },
        }
    }
    return null;
}

fn socketPath(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("SINTY_MEDIAD_SOCKET")) |p| return std.fmt.bufPrintZ(buf, "{s}", .{std.mem.span(p)}) catch null;
    const dir = std.c.getenv("XDG_RUNTIME_DIR") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/sinty-mediad.sock", .{std.mem.span(dir)}) catch null;
}

fn connect() ?i32 {
    var pbuf: [512]u8 = undefined;
    const path = socketPath(&pbuf) orelse return null;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    var addr = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    if (path.len >= addr.path.len) {
        _ = linux.close(fd);
        return null;
    }
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

pub export fn fotone_media_available() c_int {
    const fd = connect() orelse return 0;
    _ = linux.close(fd);
    return 1;
}

pub export fn fotone_media_open(size: u64, events: *const Events) ?*Media {
    const fd = connect() orelse return null;
    const m = std.heap.c_allocator.create(Media) catch {
        _ = linux.close(fd);
        return null;
    };
    m.* = .{ .fd = fd, .events = events.* };
    var play = Play{ .flags = FLAG_ISOLATED, .size = size };
    if (!send(fd, .play, &.{ std.mem.asBytes(&play), "video/x-raw,format=BGRA", &[_]u8{0} }) or std.c.pthread_create(&m.thread, null, reader, m) != .SUCCESS) {
        _ = linux.close(fd);
        std.heap.c_allocator.destroy(m);
        return null;
    }
    return m;
}

pub export fn fotone_media_feed(m: *Media, offset: u64, data: [*]const u8, len: usize) c_int {
    _ = std.c.pthread_mutex_lock(&m.lock);
    const fed = m.stream.feed(offset, data[0..len]);
    const restart = if (fed == .ok) serve(m) else null;
    _ = std.c.pthread_mutex_unlock(&m.lock);
    if (restart) |at| m.events.restart(m.events.ctx, at);
    return if (fed == .full) 0 else 1;
}

pub export fn fotone_media_finish(m: *Media, offset: u64) void {
    _ = std.c.pthread_mutex_lock(&m.lock);
    if (offset == m.stream.start + m.stream.bytes.items.len) m.stream.end = offset;
    const restart = serve(m);
    _ = std.c.pthread_mutex_unlock(&m.lock);
    if (restart) |at| m.events.restart(m.events.ctx, at);
}

pub export fn fotone_media_control(m: *Media, op: u32, value: f64) void {
    var msg = Control{ .op = op, .value = value };
    _ = send(m.fd, .control, &.{std.mem.asBytes(&msg)});
}

pub export fn fotone_media_frame(m: *Media, copy: Copy, ctx: ?*anyopaque) c_int {
    _ = std.c.pthread_mutex_lock(&m.lock);
    defer _ = std.c.pthread_mutex_unlock(&m.lock);
    const s = m.shown orelse return 0;
    const stride = m.width * 4;
    if (m.width == 0 or @as(usize, stride) * m.height > s.len) return 0;
    copy(ctx, s.ptr, m.width, m.height, stride, s.pts);
    return 1;
}

pub export fn fotone_media_close(m: *Media) void {
    _ = linux.shutdown(m.fd, linux.SHUT.RDWR);
    _ = std.c.pthread_join(m.thread, null);
    unshow(m);
    for (m.slots) |o| {
        if (o) |s| _ = linux.munmap(s.ptr, s.len);
    }
    _ = linux.close(m.fd);
    m.stream.deinit();
    std.heap.c_allocator.destroy(m);
}

test "the stream hands out bytes in order and drops what was sent" {
    var s: Stream = .{};
    defer s.deinit();
    try std.testing.expectEqual(Stream.Fed.ok, s.feed(0, "abcdef"));
    try std.testing.expectEqual(Stream.Fed.stale, s.feed(2, "xx"));
    const t = s.take(.{ .offset = 0, .length = 4 });
    try std.testing.expectEqualStrings("abcd", t.bytes);
    s.consume(4);
    try std.testing.expectEqualStrings("cdef", s.take(.{ .offset = 2, .length = 100 }).bytes);
    try std.testing.expectEqualStrings("ef", s.take(.{ .offset = 4, .length = 100 }).bytes);
    s.consume(6);
    try std.testing.expect(s.take(.{ .offset = 6, .length = 1 }) == .wait);
    try std.testing.expect(s.take(.{ .offset = 6 + AHEAD, .length = 1 }) == .wait);
    try std.testing.expect(s.take(.{ .offset = 7 + AHEAD, .length = 1 }) == .miss);
    s.end = 6;
    try std.testing.expect(s.take(.{ .offset = 6, .length = 1 }) == .eof);
    s.reset(BACK * 4);
    try std.testing.expect(s.take(.{ .offset = 1, .length = 1 }) == .miss);
}

test "a full buffer asks for a fresh download once drained" {
    var s: Stream = .{};
    defer s.deinit();
    const big = try std.testing.allocator.alloc(u8, LIMIT);
    defer std.testing.allocator.free(big);
    try std.testing.expectEqual(Stream.Fed.ok, s.feed(0, big));
    try std.testing.expectEqual(Stream.Fed.full, s.feed(LIMIT, "z"));
    s.consume(LIMIT);
    try std.testing.expectEqual(@as(u64, LIMIT - BACK), s.start);
    try std.testing.expect(s.take(.{ .offset = LIMIT, .length = 1 }) == .miss);
    s.reset(LIMIT);
    try std.testing.expectEqual(Stream.Fed.ok, s.feed(LIMIT, "z"));
}

test "caps fields parse" {
    const caps = "video/x-raw, width=(int)320, height=(int)240, format=(string)BGRA";
    try std.testing.expectEqual(@as(?u32, 320), field(caps, "width"));
    try std.testing.expectEqual(@as(?u32, 240), field(caps, "height"));
    try std.testing.expectEqual(@as(?u32, null), field(caps, "depth"));
}
