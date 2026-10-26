const std = @import("std");

pub const Lock = struct {
    m: std.c.pthread_mutex_t = .{},

    pub fn lock(l: *Lock) void {
        _ = std.c.pthread_mutex_lock(&l.m);
    }

    pub fn unlock(l: *Lock) void {
        _ = std.c.pthread_mutex_unlock(&l.m);
    }
};

pub const Signal = struct {
    m: std.c.pthread_mutex_t = .{},
    cv: std.c.pthread_cond_t = .{},

    pub fn wait(s: *Signal, ready: *const fn (*anyopaque) bool, ctx: *anyopaque) void {
        _ = std.c.pthread_mutex_lock(&s.m);
        while (!ready(ctx)) _ = std.c.pthread_cond_wait(&s.cv, &s.m);
        _ = std.c.pthread_mutex_unlock(&s.m);
    }

    pub fn wake(s: *Signal) void {
        _ = std.c.pthread_mutex_lock(&s.m);
        _ = std.c.pthread_cond_broadcast(&s.cv);
        _ = std.c.pthread_mutex_unlock(&s.m);
    }
};

pub fn sleepUs(us: u32) void {
    const ts = std.c.timespec{ .sec = @intCast(us / 1_000_000), .nsec = @intCast((us % 1_000_000) * 1000) };
    _ = std.c.nanosleep(&ts, null);
}

pub const Thread = struct {
    id: std.c.pthread_t,

    pub fn spawn(comptime T: type, comptime run: fn (*T) void, ctx: *T) ?Thread {
        const S = struct {
            fn entry(p: ?*anyopaque) callconv(.c) ?*anyopaque {
                run(@ptrCast(@alignCast(p)));
                return null;
            }
        };
        var id: std.c.pthread_t = undefined;
        if (std.c.pthread_create(&id, null, S.entry, ctx) != .SUCCESS) return null;
        return .{ .id = id };
    }

    pub fn current(t: Thread) bool {
        return t.id == std.c.pthread_self();
    }

    pub fn join(t: Thread) void {
        _ = std.c.pthread_join(t.id, null);
    }
};
