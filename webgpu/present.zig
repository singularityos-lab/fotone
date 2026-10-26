const std = @import("std");
const core = @import("core.zig");
const api = @import("api.zig");
const conv = @import("conv.zig");
const blocks = @import("blocks.zig");
const sys = @import("sys.zig");

const c = core.c;
const wk = core.wk;
const d = core.d;
const gpa = core.gpa;
const Device = core.Device;

const MAX_BUFFERS = 3;
const SYNC_FD: c.WGPUSharedFenceType = c.WGPUSharedFenceType_SyncFD;

const Plane = struct {
    fd: c_int = -1,
    offset: u32 = 0,
    stride: u32 = 0,
};

const Buffer = struct {
    width: u32 = 0,
    height: u32 = 0,
    fourcc: u32 = 0,
    modifier: u64 = 0,
    count: u32 = 0,
    planes: [4]Plane = .{ .{}, .{}, .{}, .{} },

    fn close(b: *Buffer) void {
        for (b.planes[0..b.count]) |*p| {
            if (p.fd >= 0) _ = std.c.close(p.fd);
            p.fd = -1;
        }
        b.count = 0;
    }
};

pub const Surface = struct {
    refs: std.atomic.Value(u32) = .init(1),
    lock: sys.Lock = .{},
    buffers: [MAX_BUFFERS]Buffer = .{ .{}, .{}, .{} },
    count: usize = 0,
    generation: u32 = 0,
    fence: c_int = -1,

    pub fn ref(self: *Surface) void {
        core.retain(&self.refs);
    }

    pub fn unref(self: *Surface) void {
        if (!core.release(&self.refs)) return;
        for (self.buffers[0..self.count]) |*b| b.close();
        if (self.fence >= 0) _ = std.c.close(self.fence);
        gpa.destroy(self);
    }

    fn replace(self: *Surface, list: ?*const wk.WGPUDmaBufArray) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.buffers[0..self.count]) |*b| b.close();
        self.count = 0;
        self.generation +%= 1;
        const l = list orelse return;
        const n = @min(l.count, MAX_BUFFERS);
        for (0..n) |i| {
            const src = l.buffers[i];
            var b = Buffer{ .width = src.width, .height = src.height, .fourcc = src.fourcc, .modifier = src.modifier };
            const planes = @min(src.planeCount, 4);
            for (0..planes) |j| {
                const fd = std.c.dup(src.planes[j].fd);
                if (fd < 0) break;
                b.planes[j] = .{ .fd = fd, .offset = src.planes[j].offset, .stride = src.planes[j].stride };
                b.count += 1;
            }
            self.buffers[self.count] = b;
            self.count += 1;
        }
    }

    fn storeFence(self: *Surface, fd: c_int) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.fence >= 0) _ = std.c.close(self.fence);
        self.fence = fd;
    }
};

const Recreated = struct {
    surface: *Surface,

    fn run(self: *Recreated, list: ?*const wk.WGPUDmaBufArray) void {
        self.surface.replace(list);
    }

    pub fn deinit(self: *Recreated) void {
        self.surface.unref();
    }
};

const Scheduled = struct {
    fn run(_: *Scheduled, item: ?*anyopaque) void {
        const b = item orelse return;
        blocks.invoke(fn (*anyopaque) callconv(.c) void, b)(b);
    }
};

fn surface(h: wk.WGPUSurface) *Surface {
    return @ptrCast(@alignCast(h.?));
}

export fn wgpuInstanceCreateSurface(_: wk.WGPUInstance, desc: *const wk.WGPUSurfaceDescriptor) wk.WGPUSurface {
    const self = gpa.create(Surface) catch return null;
    self.* = .{};
    const register: ?*anyopaque = @ptrCast(@constCast(desc.cocoaDescriptor.compositorIntegrationRegister));
    const r = register orelse return @ptrCast(self);
    self.ref();
    const recreated = blocks.ClosureWith(Recreated, ?*const wk.WGPUDmaBufArray, Recreated.run).create(.{ .surface = self }) orelse {
        self.unref();
        return @ptrCast(self);
    };
    const scheduled = blocks.ClosureWith(Scheduled, ?*anyopaque, Scheduled.run).create(.{}) orelse {
        blocks._Block_release(recreated);
        return @ptrCast(self);
    };
    blocks.invoke(fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void, r)(r, recreated, scheduled);
    blocks._Block_release(recreated);
    blocks._Block_release(scheduled);
    return @ptrCast(self);
}

export fn wgpuSurfaceReference(h: wk.WGPUSurface) void {
    if (h != null) surface(h).ref();
}

export fn wgpuSurfaceRelease(h: wk.WGPUSurface) void {
    if (h != null) surface(h).unref();
}

export fn wgpuSurfaceGetPreferredFormat(_: wk.WGPUSurface, _: wk.WGPUAdapter) wk.WGPUTextureFormat {
    return wk.WGPUTextureFormat_BGRA8Unorm;
}

export fn wgpuPresentationContextIsValid(h: wk.WGPUSurface) wk.WGPUBool {
    return @intFromBool(h != null);
}

export fn wgpuSurfaceTakeFence(h: wk.WGPUSurface) c_int {
    const self = surface(h orelse return -1);
    self.lock.lock();
    defer self.lock.unlock();
    const fd = self.fence;
    self.fence = -1;
    return fd;
}

const Slot = struct {
    memory: c.WGPUSharedTextureMemory = null,
    texture: c.WGPUTexture = null,

    fn release(s: *Slot) void {
        if (s.texture) |t| d("wgpuTextureRelease")(t);
        if (s.memory) |m| d("wgpuSharedTextureMemoryRelease")(m);
        s.* = .{};
    }
};

pub const SwapChain = struct {
    refs: std.atomic.Value(u32) = .init(1),
    dev: *Device,
    surface: *Surface,
    format: c.WGPUTextureFormat,
    usage: c.WGPUTextureUsage,
    width: u32,
    height: u32,
    views: []c.WGPUTextureFormat,
    slots: [MAX_BUFFERS]Slot = .{ .{}, .{}, .{} },
    count: usize = 0,
    generation: u32 = 0,
    imported: bool = false,
    current: ?usize = null,

    pub fn ref(self: *SwapChain) void {
        core.retain(&self.refs);
    }

    pub fn unref(self: *SwapChain) void {
        if (!core.release(&self.refs)) return;
        if (self.current) |i| self.finish(i, false);
        for (&self.slots) |*s| s.release();
        gpa.free(self.views);
        self.surface.unref();
        self.dev.unref();
        gpa.destroy(self);
    }

    fn load(self: *SwapChain) void {
        for (&self.slots) |*s| s.release();
        self.count = 0;
        const sf = self.surface;
        sf.lock.lock();
        defer sf.lock.unlock();
        self.generation = sf.generation;
        self.imported = true;
        const raw = self.dev.raw orelse return;
        for (sf.buffers[0..sf.count]) |*b| {
            var planes: [4]c.WGPUSharedTextureMemoryDmaBufPlane = undefined;
            for (b.planes[0..b.count], 0..) |p, i| planes[i] = .{ .fd = p.fd, .offset = p.offset, .stride = p.stride };
            var dma = std.mem.zeroes(c.WGPUSharedTextureMemoryDmaBufDescriptor);
            dma.chain.sType = c.WGPUSType_SharedTextureMemoryDmaBufDescriptor;
            dma.size = .{ .width = b.width, .height = b.height, .depthOrArrayLayers = 1 };
            dma.drmFormat = b.fourcc;
            dma.drmModifier = b.modifier;
            dma.planeCount = b.count;
            dma.planes = &planes;
            const desc = c.WGPUSharedTextureMemoryDescriptor{ .nextInChain = @ptrCast(&dma), .label = core.str(null) };
            var slot = Slot{};
            slot.memory = d("wgpuDeviceImportSharedTextureMemory")(raw, &desc);
            if (slot.memory) |m| {
                const tex = c.WGPUTextureDescriptor{
                    .nextInChain = null,
                    .label = core.str(null),
                    .usage = self.usage,
                    .dimension = c.WGPUTextureDimension_2D,
                    .size = dma.size,
                    .format = self.format,
                    .mipLevelCount = 1,
                    .sampleCount = 1,
                    .viewFormatCount = self.views.len,
                    .viewFormats = if (self.views.len == 0) null else self.views.ptr,
                };
                slot.texture = d("wgpuSharedTextureMemoryCreateTexture")(m, &tex);
            }
            self.slots[self.count] = slot;
            self.count += 1;
        }
    }

    fn stale(self: *SwapChain) bool {
        const sf = self.surface;
        sf.lock.lock();
        defer sf.lock.unlock();
        return !self.imported or sf.generation != self.generation;
    }

    fn begin(self: *SwapChain, i: usize) bool {
        const s = &self.slots[i];
        const m = s.memory orelse return false;
        const t = s.texture orelse return false;
        var layout = std.mem.zeroes(c.WGPUSharedTextureMemoryVkImageLayoutBeginState);
        layout.chain.sType = c.WGPUSType_SharedTextureMemoryVkImageLayoutBeginState;
        const desc = c.WGPUSharedTextureMemoryBeginAccessDescriptor{
            .nextInChain = @ptrCast(&layout),
            .concurrentRead = 0,
            .initialized = 0,
            .fenceCount = 0,
            .fences = null,
            .signaledValueCount = 0,
            .signaledValues = null,
        };
        return d("wgpuSharedTextureMemoryBeginAccess")(m, t, &desc) == c.WGPUStatus_Success;
    }

    fn finish(self: *SwapChain, i: usize, present: bool) void {
        self.current = null;
        const s = &self.slots[i];
        const m = s.memory orelse return;
        const t = s.texture orelse return;
        var layout = std.mem.zeroes(c.WGPUSharedTextureMemoryVkImageLayoutEndState);
        layout.chain.sType = c.WGPUSType_SharedTextureMemoryVkImageLayoutEndState;
        var state = std.mem.zeroes(c.WGPUSharedTextureMemoryEndAccessState);
        state.nextInChain = @ptrCast(&layout);
        if (d("wgpuSharedTextureMemoryEndAccess")(m, t, &state) != c.WGPUStatus_Success) return;
        defer d("wgpuSharedTextureMemoryEndAccessStateFreeMembers")(state);
        if (!present) return;
        var fd: c_int = -1;
        if (state.fenceCount > 0) fd = exportFence(state.fences[state.fenceCount - 1]);
        if (fd < 0) self.drain();
        self.surface.storeFence(fd);
    }

    fn drain(self: *SwapChain) void {
        const raw = self.dev.raw orelse return;
        const q = d("wgpuDeviceGetQueue")(raw) orelse return;
        defer d("wgpuQueueRelease")(q);
        var done = std.atomic.Value(bool).init(false);
        const info = c.WGPUQueueWorkDoneCallbackInfo{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = workDone,
            .userdata1 = &done,
            .userdata2 = null,
        };
        _ = d("wgpuQueueOnSubmittedWorkDone")(q, info);
        self.dev.inst.begin();
        defer self.dev.inst.end();
        var spins: u32 = 0;
        while (!done.load(.acquire) and spins < 2000) : (spins += 1) sys.sleepUs(500);
    }
};

fn workDone(_: c.WGPUQueueWorkDoneStatus, _: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const done: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud1.?));
    done.store(true, .release);
}

fn exportFence(f: c.WGPUSharedFence) c_int {
    var sync = std.mem.zeroes(c.WGPUSharedFenceSyncFDExportInfo);
    sync.chain.sType = c.WGPUSType_SharedFenceSyncFDExportInfo;
    sync.handle = -1;
    var info = c.WGPUSharedFenceExportInfo{ .nextInChain = @ptrCast(&sync), .type = 0 };
    d("wgpuSharedFenceExportInfo")(f, &info);
    if (info.type != SYNC_FD or sync.handle < 0) return -1;
    return std.c.dup(sync.handle);
}

fn chain(h: wk.WGPUSwapChain) *SwapChain {
    return @ptrCast(@alignCast(h.?));
}

export fn wgpuDeviceCreateSwapChain(h: wk.WGPUDevice, s: wk.WGPUSurface, desc: *const wk.WGPUSwapChainDescriptor) wk.WGPUSwapChain {
    if (h == null or s == null) return null;
    const dev = api.device(h);
    const self = gpa.create(SwapChain) catch return null;
    const list: *const @import("wtf.zig").Vector(wk.WGPUTextureFormat) = @ptrCast(&desc.viewFormats);
    const src = list.items();
    const views = gpa.alloc(c.WGPUTextureFormat, src.len) catch {
        gpa.destroy(self);
        return null;
    };
    for (src, views) |f, *v| v.* = conv.to("WGPUTextureFormat", f);
    dev.ref();
    surface(s).ref();
    self.* = .{
        .dev = dev,
        .surface = surface(s),
        .format = conv.to("WGPUTextureFormat", desc.format),
        .usage = desc.usage,
        .width = desc.width,
        .height = desc.height,
        .views = views,
    };
    return @ptrCast(self);
}

export fn wgpuSwapChainReference(h: wk.WGPUSwapChain) void {
    if (h != null) chain(h).ref();
}

export fn wgpuSwapChainRelease(h: wk.WGPUSwapChain) void {
    if (h != null) chain(h).unref();
}

export fn wgpuSwapChainGetCurrentTexture(h: wk.WGPUSwapChain, frame: u32) wk.WGPUTexture {
    const self = chain(h orelse return null);
    if (self.stale()) {
        if (self.current) |i| self.finish(i, false);
        self.load();
    }
    if (self.count == 0) return null;
    const i = frame % self.count;
    if (self.current) |cur| {
        if (cur == i) return @ptrCast(self.slots[i].texture);
        self.finish(cur, false);
    }
    if (!self.begin(i)) return null;
    self.current = i;
    return @ptrCast(self.slots[i].texture);
}

export fn wgpuSwapChainGetCurrentTextureView(_: wk.WGPUSwapChain) wk.WGPUTextureView {
    return null;
}

export fn wgpuSwapChainPresent(h: wk.WGPUSwapChain, _: u32) void {
    const self = chain(h orelse return);
    const i = self.current orelse return;
    self.finish(i, true);
}

export fn wgpuDeviceCreateXRBinding(_: wk.WGPUDevice) wk.WGPUXRBinding {
    return null;
}

export fn wgpuBindingCreateXRProjectionLayer(_: wk.WGPUXRBinding, _: wk.WGPUTextureFormat, _: ?*wk.WGPUTextureFormat, _: wk.WGPUTextureUsageFlags, _: f64) wk.WGPUXRProjectionLayer {
    return null;
}

export fn wgpuBindingGetViewSubImage(_: wk.WGPUXRBinding, _: wk.WGPUXRProjectionLayer) wk.WGPUXRSubImage {
    return null;
}

export fn wgpuXRSubImageGetColorTexture(_: wk.WGPUXRSubImage) wk.WGPUTexture {
    return null;
}

export fn wgpuXRSubImageGetDepthStencilTexture(_: wk.WGPUXRSubImage) wk.WGPUTexture {
    return null;
}

fn xr(comptime kind: []const u8) void {
    const H = @field(wk, "WGPUXR" ++ kind);
    const S = struct {
        fn noop(_: H) callconv(.c) void {}

        fn valid(_: H) callconv(.c) wk.WGPUBool {
            return 0;
        }
    };
    @export(&S.noop, .{ .name = "wgpuXR" ++ kind ++ "Reference" });
    @export(&S.noop, .{ .name = "wgpuXR" ++ kind ++ "Release" });
    @export(&S.valid, .{ .name = "wgpuXR" ++ kind ++ "IsValid" });
}

comptime {
    for ([_][]const u8{ "Binding", "SubImage", "ProjectionLayer", "View" }) |k| xr(k);
}

test "recreated buffers are duplicated and replaced" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var bufs: [2]wk.WGPUDmaBuf = .{ std.mem.zeroes(wk.WGPUDmaBuf), std.mem.zeroes(wk.WGPUDmaBuf) };
    for (&bufs, 0..) |*b, i| {
        b.width = 64;
        b.height = 32;
        b.fourcc = 0x34325241;
        b.planeCount = 1;
        b.planes[0] = .{ .fd = fds[i], .offset = 0, .stride = 256 };
    }
    const list = wk.WGPUDmaBufArray{ .count = 2, .buffers = &bufs };
    const s = try gpa.create(Surface);
    s.* = .{};
    s.replace(&list);
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expect(s.buffers[0].planes[0].fd != fds[0]);
    try std.testing.expectEqual(@as(u32, 256), s.buffers[1].planes[0].stride);
    const first = s.generation;
    s.replace(null);
    try std.testing.expectEqual(@as(usize, 0), s.count);
    try std.testing.expect(s.generation != first);
    s.storeFence(std.c.dup(fds[0]));
    try std.testing.expect(wgpuSurfaceTakeFence(@ptrCast(s)) >= 0);
    try std.testing.expectEqual(@as(c_int, -1), wgpuSurfaceTakeFence(@ptrCast(s)));
    s.unref();
}
