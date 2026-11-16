const std = @import("std");
const c = @import("c.zig").c;
const g = @import("gobject.zig");

pub const Observer = extern struct {
    parent: c.WPEScreenSyncObserver,
    running: u32,
    generation: u32,
    fd: c_int,
    crtc: c_int,
    period_ns: i64,
};

const ObserverClass = extern struct {
    parent: c.WPEScreenSyncObserverClass,
};

pub const Screen = extern struct {
    parent: c.WPEScreen,
    observer: ?*Observer,
};

const ScreenClass = extern struct {
    parent: c.WPEScreenClass,
};

const Job = struct {
    o: *Observer,
    generation: u32,
};

var observer_once: g.Once = .{};
var screen_once: g.Once = .{};
var screen_parent: ?*c.GObjectClass = null;

pub fn observerType() c.GType {
    return observer_once.get(makeObserver);
}

pub fn getType() c.GType {
    return screen_once.get(makeScreen);
}

fn makeObserver() c.GType {
    return g.register(c.wpe_screen_sync_observer_get_type(), "FotoneScreenSyncObserver", ObserverClass, Observer, observerClassInit, observerInit);
}

fn makeScreen() c.GType {
    return g.register(c.wpe_screen_get_type(), "FotoneScreen", ScreenClass, Screen, screenClassInit, null);
}

fn observerOf(p: anytype) *Observer {
    return @ptrCast(@alignCast(p));
}

fn screenOf(p: anytype) *Screen {
    return @ptrCast(@alignCast(p));
}

fn observerInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const o = observerOf(inst);
    o.fd = -1;
    o.crtc = -1;
    o.period_ns = std.time.ns_per_s / 60;
}

fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec;
}

fn sleepUntil(t: i64) void {
    const ts: c.struct_timespec = .{ .tv_sec = @intCast(@divTrunc(t, std.time.ns_per_s)), .tv_nsec = @intCast(@mod(t, std.time.ns_per_s)) };
    while (c.clock_nanosleep(c.CLOCK_MONOTONIC, c.TIMER_ABSTIME, &ts, null) == c.EINTR) {}
}

fn crtcBits(index: c_int) c_int {
    if (index == 0) return 0;
    if (index == 1) return c.DRM_VBLANK_SECONDARY;
    return (index << c.DRM_VBLANK_HIGH_CRTC_SHIFT) & c.DRM_VBLANK_HIGH_CRTC_MASK;
}

fn waitVBlank(o: *Observer) bool {
    const fd = @atomicLoad(c_int, &o.fd, .acquire);
    const crtc = @atomicLoad(c_int, &o.crtc, .acquire);
    if (fd < 0 or crtc < 0) return false;
    var v: c.drmVBlank = std.mem.zeroes(c.drmVBlank);
    v.request.type = @bitCast(@as(c_int, c.DRM_VBLANK_RELATIVE) | crtcBits(crtc));
    v.request.sequence = 1;
    return c.drmWaitVBlank(fd, &v) == 0;
}

fn live(o: *Observer, generation: u32) bool {
    return @atomicLoad(u32, &o.running, .acquire) != 0 and @atomicLoad(u32, &o.generation, .acquire) == generation;
}

fn sync(o: *Observer) void {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(o));
    const oc: *c.WPEScreenSyncObserverClass = @ptrCast(@alignCast(inst.g_class));
    oc.sync.?(&o.parent);
}

fn run(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job: *Job = @ptrCast(@alignCast(arg));
    const o = job.o;
    const generation = job.generation;
    std.heap.c_allocator.destroy(job);
    defer c.g_object_unref(o);
    var next = now();
    while (live(o, generation)) {
        if (waitVBlank(o)) {
            next = now();
        } else {
            const period = @atomicLoad(i64, &o.period_ns, .acquire);
            next += period;
            const t = now();
            if (next < t) next = t + period - @mod(t - next, period);
            sleepUntil(next);
        }
        if (live(o, generation)) sync(o);
    }
    return null;
}

fn start(observer: [*c]c.WPEScreenSyncObserver) callconv(.c) void {
    const o = observerOf(observer);
    const generation = @atomicRmw(u32, &o.generation, .Add, 1, .acq_rel) + 1;
    @atomicStore(u32, &o.running, 1, .release);
    const job = std.heap.c_allocator.create(Job) catch return;
    job.* = .{ .o = o, .generation = generation };
    _ = c.g_object_ref(o);
    var t: c.pthread_t = undefined;
    if (c.pthread_create(&t, null, run, job) != 0) {
        c.g_object_unref(o);
        std.heap.c_allocator.destroy(job);
        return;
    }
    _ = c.pthread_detach(t);
}

fn stop(observer: [*c]c.WPEScreenSyncObserver) callconv(.c) void {
    @atomicStore(u32, &observerOf(observer).running, 0, .release);
}

fn observerClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.WPEScreenSyncObserverClass = @ptrCast(@alignCast(klass));
    oc.start = start;
    oc.stop = stop;
}

fn syncObserver(screen: [*c]c.WPEScreen) callconv(.c) [*c]c.WPEScreenSyncObserver {
    const s = screenOf(screen);
    if (s.observer == null) s.observer = observerOf(c.g_object_new(observerType(), null));
    return @ptrCast(s.observer);
}

fn screenFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s = screenOf(o);
    if (s.observer) |ob| {
        @atomicStore(u32, &ob.running, 0, .release);
        c.g_object_unref(ob);
    }
    s.observer = null;
    screen_parent.?.finalize.?(o);
}

fn screenClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    screen_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    g.objectClass(klass).finalize = screenFinalize;
    const sc: *c.WPEScreenClass = @ptrCast(@alignCast(klass));
    sc.get_sync_observer = syncObserver;
}

pub fn new(id: u32) *Screen {
    const s = screenOf(c.g_object_new(getType(), "id", @as(c.guint, id), @as(?*anyopaque, null)));
    c.wpe_screen_set_refresh_rate(&s.parent, 60000);
    c.wpe_screen_set_scale(&s.parent, 1);
    return s;
}

pub fn setRate(s: *Screen, refresh: c_int) void {
    if (refresh <= 0) return;
    c.wpe_screen_set_refresh_rate(&s.parent, refresh);
    const o = observerOf(syncObserver(&s.parent));
    @atomicStore(i64, &o.period_ns, @divTrunc(@as(i64, std.time.ns_per_s) * 1000, refresh), .release);
}

pub fn setVBlank(s: *Screen, fd: c_int, crtc: c_int) void {
    const o = observerOf(syncObserver(&s.parent));
    @atomicStore(c_int, &o.crtc, crtc, .release);
    @atomicStore(c_int, &o.fd, fd, .release);
}

var test_ticks: u32 = 0;

fn countTick(_: [*c]c.WPEScreenSyncObserver, _: c.gpointer) callconv(.c) void {
    _ = @atomicRmw(u32, &test_ticks, .Add, 1, .acq_rel);
}

test "the screen ticks at its refresh rate only while someone listens" {
    const s = new(1);
    defer c.g_object_unref(s);
    setRate(s, 100000);
    const o = c.wpe_screen_get_sync_observer(&s.parent);
    try std.testing.expect(o != null);
    const id = c.wpe_screen_sync_observer_add_callback(o, countTick, null, null);
    sleepUntil(now() + 200 * std.time.ns_per_ms);
    c.wpe_screen_sync_observer_remove_callback(o, id);
    const ticks = @atomicLoad(u32, &test_ticks, .acquire);
    try std.testing.expect(ticks >= 17 and ticks <= 22);
    sleepUntil(now() + 50 * std.time.ns_per_ms);
    try std.testing.expect(@atomicLoad(u32, &test_ticks, .acquire) <= ticks + 1);
    try std.testing.expectEqual(@as(c_int, 100000), c.wpe_screen_get_refresh_rate(&s.parent));
}
