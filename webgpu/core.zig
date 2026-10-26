const std = @import("std");
const dawn = @import("dawn.zig");
const wtf = @import("wtf.zig");
const blocks = @import("blocks.zig");
const sys = @import("sys.zig");

pub const c = dawn.c;
pub const wk = @import("wk.zig").c;
pub const gpa = std.heap.c_allocator;

pub fn d(comptime name: []const u8) dawn.Proc(name) {
    return dawn.proc(name);
}

pub fn str(s: [*c]const u8) c.WGPUStringView {
    return dawn.str(s);
}

pub fn label(arena: std.mem.Allocator, s: anytype) c.WGPUStringView {
    const z = wtf.utf8(arena, @as(wtf.String, @bitCast(s))) catch return dawn.str(null);
    return .{ .data = z.ptr, .length = z.len };
}

pub fn dupe(v: c.WGPUStringView) [:0]u8 {
    return gpa.dupeZ(u8, dawn.slice(v)) catch @constCast("");
}

pub fn free(m: [:0]u8) void {
    if (m.len > 0) gpa.free(m);
}

pub fn retain(refs: *std.atomic.Value(u32)) void {
    _ = refs.fetchAdd(1, .monotonic);
}

pub fn release(refs: *std.atomic.Value(u32)) bool {
    return refs.fetchSub(1, .acq_rel) == 1;
}

pub fn handle(comptime T: type, p: anytype) T {
    return @ptrCast(p);
}

pub fn wrapper(comptime T: type, h: anytype) ?*T {
    return @ptrCast(@alignCast(h));
}

pub const Instance = struct {
    refs: std.atomic.Value(u32) = .init(1),
    raw: c.WGPUInstance,
    schedule: ?*anyopaque,
    pending: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    signal: sys.Signal = .{},
    thread: ?sys.Thread = null,
    orphan: bool = false,

    pub fn create(raw: c.WGPUInstance, schedule: ?*const anyopaque) ?*Instance {
        const self = gpa.create(Instance) catch return null;
        self.* = .{ .raw = raw, .schedule = blocks._Block_copy(schedule) };
        self.thread = sys.Thread.spawn(Instance, tick, self);
        return self;
    }

    pub fn ref(self: *Instance) void {
        retain(&self.refs);
    }

    pub fn unref(self: *Instance) void {
        if (release(&self.refs)) self.destroy();
    }

    fn tick(self: *Instance) void {
        while (!self.stop.load(.acquire)) {
            if (self.pending.load(.acquire) == 0) {
                self.signal.wait(ready, self);
                continue;
            }
            d("wgpuInstanceProcessEvents")(self.raw);
            sys.sleepUs(1000);
        }
        if (self.orphan) self.finish();
    }

    fn ready(p: *anyopaque) bool {
        const self: *Instance = @ptrCast(@alignCast(p));
        return self.stop.load(.acquire) or self.pending.load(.acquire) > 0;
    }

    pub fn begin(self: *Instance) void {
        if (self.pending.fetchAdd(1, .acq_rel) == 0) self.signal.wake();
    }

    pub fn end(self: *Instance) void {
        _ = self.pending.fetchSub(1, .acq_rel);
    }

    fn destroy(self: *Instance) void {
        self.stop.store(true, .release);
        if (self.thread) |t| {
            if (t.current()) {
                self.orphan = true;
                return;
            }
            self.signal.wake();
            t.join();
        }
        self.finish();
    }

    fn finish(self: *Instance) void {
        d("wgpuInstanceRelease")(self.raw);
        if (self.schedule) |s| blocks._Block_release(s);
        gpa.destroy(self);
    }

    pub fn deliver(self: *Instance, comptime Ctx: type, ctx: Ctx) void {
        const B = blocks.Closure(Ctx, Ctx.run);
        const b = B.create(ctx) orelse return;
        if (self.schedule) |s| {
            blocks.invoke(fn (*anyopaque, *anyopaque) callconv(.c) void, s)(s, b);
        } else {
            blocks.invoke(fn (*anyopaque) callconv(.c) void, b)(b);
        }
        blocks._Block_release(b);
    }
};

pub const Adapter = struct {
    refs: std.atomic.Value(u32) = .init(1),
    raw: c.WGPUAdapter,
    inst: *Instance,
    info: c.WGPUAdapterInfo = std.mem.zeroes(c.WGPUAdapterInfo),
    names: [4][:0]u8 = .{ @constCast(""), @constCast(""), @constCast(""), @constCast("") },

    pub fn create(inst: *Instance, raw: c.WGPUAdapter) ?*Adapter {
        const self = gpa.create(Adapter) catch return null;
        self.* = .{ .raw = raw, .inst = inst };
        inst.ref();
        if (d("wgpuAdapterGetInfo")(raw, &self.info) == c.WGPUStatus_Success) {
            self.names = .{ dupe(self.info.vendor), dupe(self.info.architecture), dupe(self.info.device), dupe(self.info.description) };
            d("wgpuAdapterInfoFreeMembers")(self.info);
        }
        return self;
    }

    pub fn ref(self: *Adapter) void {
        retain(&self.refs);
    }

    pub fn unref(self: *Adapter) void {
        if (release(&self.refs)) self.destroy();
    }

    fn destroy(self: *Adapter) void {
        d("wgpuAdapterRelease")(self.raw);
        for (self.names) |n| free(n);
        self.inst.unref();
        gpa.destroy(self);
    }
};

pub const Pending = struct {
    kind: wk.WGPUErrorType,
    message: [:0]u8,
};

pub const Device = struct {
    refs: std.atomic.Value(u32) = .init(1),
    life: std.atomic.Value(u32) = .init(2),
    raw: c.WGPUDevice = null,
    inst: *Instance,
    adapter: *Adapter,
    lock: sys.Lock = .{},
    lost_block: ?*anyopaque = null,
    lost_fn: wk.WGPUDeviceLostCallback = null,
    lost_data: ?*anyopaque = null,
    lost: bool = false,
    lost_reason: wk.WGPUDeviceLostReason = wk.WGPUDeviceLostReason_Undefined,
    lost_message: [:0]u8 = @constCast(""),
    error_fn: wk.WGPUErrorCallback = null,
    error_data: ?*anyopaque = null,
    errors: std.ArrayList(Pending) = .empty,
    paused: bool = false,
    dying: bool = false,

    pub fn ref(self: *Device) void {
        retain(&self.refs);
    }

    pub fn unref(self: *Device) void {
        if (!release(&self.refs)) return;
        self.lock.lock();
        self.dying = true;
        self.lock.unlock();
        if (self.raw) |r| d("wgpuDeviceRelease")(r);
        self.drop();
    }

    pub fn drop(self: *Device) void {
        if (release(&self.life)) self.destroy();
    }

    fn destroy(self: *Device) void {
        if (self.lost_block) |b| blocks._Block_release(b);
        for (self.errors.items) |e| free(e.message);
        self.errors.deinit(gpa);
        free(self.lost_message);
        self.adapter.unref();
        gpa.destroy(self);
    }

    pub fn inject(self: *Device, comptime msg: [:0]const u8) void {
        if (self.raw) |r| d("wgpuDeviceInjectError")(r, c.WGPUErrorType_Validation, dawn.str(msg));
    }
};

pub const Queue = struct {
    refs: std.atomic.Value(u32) = .init(1),
    raw: c.WGPUQueue,
    dev: *Device,

    pub fn ref(self: *Queue) void {
        retain(&self.refs);
    }

    pub fn unref(self: *Queue) void {
        if (release(&self.refs)) self.destroy();
    }

    fn destroy(self: *Queue) void {
        d("wgpuQueueRelease")(self.raw);
        self.dev.unref();
        gpa.destroy(self);
    }
};
