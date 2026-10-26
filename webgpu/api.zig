const std = @import("std");
const core = @import("core.zig");
const conv = @import("conv.zig");
const dawn = @import("dawn.zig");
const wtf = @import("wtf.zig");
const blocks = @import("blocks.zig");
const features = @import("features.zig");

const c = core.c;
const wk = core.wk;
const d = core.d;
const gpa = core.gpa;
const Instance = core.Instance;
const Adapter = core.Adapter;
const Device = core.Device;
const Queue = core.Queue;

const MAX_PENDING = 16;

fn instance(h: wk.WGPUInstance) *Instance {
    return @ptrCast(@alignCast(h.?));
}

fn adapter(h: wk.WGPUAdapter) *Adapter {
    return @ptrCast(@alignCast(h.?));
}

pub fn device(h: wk.WGPUDevice) *Device {
    return @ptrCast(@alignCast(h.?));
}

fn queue(h: wk.WGPUQueue) *Queue {
    return @ptrCast(@alignCast(h.?));
}

pub fn errorType(t: c.WGPUErrorType) wk.WGPUErrorType {
    return switch (t) {
        c.WGPUErrorType_NoError => wk.WGPUErrorType_NoError,
        c.WGPUErrorType_Validation => wk.WGPUErrorType_Validation,
        c.WGPUErrorType_OutOfMemory => wk.WGPUErrorType_OutOfMemory,
        c.WGPUErrorType_Internal => wk.WGPUErrorType_Internal,
        else => wk.WGPUErrorType_Unknown,
    };
}

fn callbackMode() c.WGPUCallbackMode {
    return c.WGPUCallbackMode_AllowSpontaneous;
}

export fn wgpuCreateInstance(desc: ?*const wk.WGPUInstanceDescriptor) wk.WGPUInstance {
    if (!dawn.available()) return null;
    const raw = d("wgpuCreateInstance")(null) orelse return null;
    const schedule: ?*const anyopaque = if (desc) |x| @ptrCast(x.cocoaDescriptor.scheduleWorkBlock) else null;
    const self = Instance.create(raw, schedule) orelse {
        d("wgpuInstanceRelease")(raw);
        return null;
    };
    return @ptrCast(self);
}

export fn wgpuGetProcAddress(_: wk.WGPUDevice, _: [*c]const u8) wk.WGPUProc {
    return null;
}

export fn wgpuDefaultLimits() wk.WGPULimits {
    return features.defaults();
}

export fn wgpuInstanceReference(h: wk.WGPUInstance) void {
    instance(h).ref();
}

export fn wgpuInstanceRelease(h: wk.WGPUInstance) void {
    instance(h).unref();
}

export fn wgpuInstanceProcessEvents(h: wk.WGPUInstance) void {
    d("wgpuInstanceProcessEvents")(instance(h).raw);
}

const AdapterReq = struct {
    inst: *Instance,
    cb: wk.WGPURequestAdapterCallback,
    ud: ?*anyopaque,
};

const AdapterDone = struct {
    cb: wk.WGPURequestAdapterCallback,
    ud: ?*anyopaque,
    status: wk.WGPURequestAdapterStatus,
    adapter: ?*Adapter,
    message: [:0]u8,

    pub fn run(self: *AdapterDone) void {
        const a = self.adapter;
        self.adapter = null;
        self.cb.?(self.status, @ptrCast(a), self.message.ptr, self.ud);
    }

    pub fn deinit(self: *AdapterDone) void {
        if (self.adapter) |a| a.unref();
        core.free(self.message);
    }
};

fn adapterReady(status: c.WGPURequestAdapterStatus, raw: c.WGPUAdapter, message: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const req: *AdapterReq = @ptrCast(@alignCast(ud1.?));
    const inst = req.inst;
    defer {
        gpa.destroy(req);
        inst.end();
        inst.unref();
    }
    var done = AdapterDone{ .cb = req.cb, .ud = req.ud, .status = wk.WGPURequestAdapterStatus_Unknown, .adapter = null, .message = core.dupe(message) };
    switch (status) {
        c.WGPURequestAdapterStatus_Success => {
            done.adapter = if (raw) |r| Adapter.create(inst, r) else null;
            done.status = if (done.adapter != null) wk.WGPURequestAdapterStatus_Success else wk.WGPURequestAdapterStatus_Unavailable;
        },
        c.WGPURequestAdapterStatus_Unavailable => done.status = wk.WGPURequestAdapterStatus_Unavailable,
        c.WGPURequestAdapterStatus_Error => done.status = wk.WGPURequestAdapterStatus_Error,
        else => {},
    }
    inst.deliver(AdapterDone, done);
}

export fn wgpuInstanceRequestAdapter(h: wk.WGPUInstance, options: ?*const wk.WGPURequestAdapterOptions, cb: wk.WGPURequestAdapterCallback, ud: ?*anyopaque) void {
    const inst = instance(h);
    var opts = std.mem.zeroes(c.WGPURequestAdapterOptions);
    opts.featureLevel = c.WGPUFeatureLevel_Core;
    opts.backendType = c.WGPUBackendType_Vulkan;
    if (options) |o| {
        opts.powerPreference = conv.to("WGPUPowerPreference", o.powerPreference);
        opts.forceFallbackAdapter = o.forceFallbackAdapter;
    }
    const req = gpa.create(AdapterReq) catch {
        inst.deliver(AdapterDone, .{ .cb = cb, .ud = ud, .status = wk.WGPURequestAdapterStatus_Error, .adapter = null, .message = @constCast("") });
        return;
    };
    req.* = .{ .inst = inst, .cb = cb, .ud = ud };
    inst.ref();
    inst.begin();
    _ = d("wgpuInstanceRequestAdapter")(inst.raw, &opts, .{ .nextInChain = null, .mode = callbackMode(), .callback = adapterReady, .userdata1 = req, .userdata2 = null });
}

export fn wgpuAdapterReference(h: wk.WGPUAdapter) void {
    adapter(h).ref();
}

export fn wgpuAdapterRelease(h: wk.WGPUAdapter) void {
    adapter(h).unref();
}

export fn wgpuAdapterIsValid(h: wk.WGPUAdapter) wk.WGPUBool {
    return @intFromBool(h != null);
}

export fn wgpuAdapterXRCompatible(_: wk.WGPUAdapter) wk.WGPUBool {
    return 0;
}

export fn wgpuAdapterGetProperties(h: wk.WGPUAdapter, out: *wk.WGPUAdapterProperties) void {
    const a = adapter(h);
    out.* = .{
        .vendorID = a.info.vendorID,
        .vendorName = a.names[0].ptr,
        .architecture = a.names[1].ptr,
        .deviceID = a.info.deviceID,
        .name = a.names[2].ptr,
        .driverDescription = a.names[3].ptr,
        .adapterType = conv.from("WGPUAdapterType", a.info.adapterType),
        .backendType = conv.from("WGPUBackendType", a.info.backendType),
        .subgroupMinSize = a.info.subgroupMinSize,
        .subgroupMaxSize = a.info.subgroupMaxSize,
    };
}

export fn wgpuAdapterGetLimits(h: wk.WGPUAdapter, out: *wk.WGPUSupportedLimits) wk.WGPUBool {
    var l = std.mem.zeroes(c.WGPULimits);
    if (d("wgpuAdapterGetLimits")(adapter(h).raw, &l) != c.WGPUStatus_Success) return 0;
    out.limits = conv.limitsBack(&l);
    return 1;
}

fn listFeatures(supported: c.WGPUSupportedFeatures, out: ?[*]wk.WGPUFeatureName) usize {
    var n: usize = 0;
    const list = supported.features orelse return 0;
    for (list[0..supported.featureCount]) |f| {
        const mapped = conv.from("WGPUFeatureName", f);
        if (mapped == wk.WGPUFeatureName_Undefined) continue;
        if (out) |o| o[n] = mapped;
        n += 1;
    }
    return n;
}

export fn wgpuAdapterEnumerateFeatures(h: wk.WGPUAdapter, out: ?[*]wk.WGPUFeatureName) usize {
    var supported = std.mem.zeroes(c.WGPUSupportedFeatures);
    d("wgpuAdapterGetFeatures")(adapter(h).raw, &supported);
    defer d("wgpuSupportedFeaturesFreeMembers")(supported);
    return listFeatures(supported, out);
}

export fn wgpuAdapterHasFeature(h: wk.WGPUAdapter, f: wk.WGPUFeatureName) wk.WGPUBool {
    const mapped = conv.to("WGPUFeatureName", f);
    if (mapped == 0) return 0;
    return d("wgpuAdapterHasFeature")(adapter(h).raw, mapped);
}

export fn wgpuAdapterFeatureName(out: *wtf.String, f: wk.WGPUFeatureName) *wtf.String {
    out.* = wtf.fromUtf8(features.name(f));
    return out;
}

const LostDone = struct {
    block: ?*anyopaque,
    cb: wk.WGPUDeviceLostCallback,
    ud: ?*anyopaque,
    reason: wk.WGPUDeviceLostReason,
    message: [:0]u8,

    pub fn run(self: *LostDone) void {
        if (self.block) |b| blocks.invoke(fn (*anyopaque, wk.WGPUDeviceLostReason, [*c]const u8) callconv(.c) void, b)(b, self.reason, self.message.ptr);
        if (self.cb) |f| f(self.reason, self.message.ptr, self.ud);
    }

    pub fn deinit(self: *LostDone) void {
        if (self.block) |b| blocks._Block_release(b);
        core.free(self.message);
    }
};

fn fireLost(dev: *Device) void {
    const done = LostDone{
        .block = dev.lost_block,
        .cb = dev.lost_fn,
        .ud = dev.lost_data,
        .reason = dev.lost_reason,
        .message = gpa.dupeZ(u8, dev.lost_message) catch @constCast(""),
    };
    dev.lost_block = null;
    dev.lost_fn = null;
    dev.lost_data = null;
    if (done.block == null and done.cb == null) {
        core.free(done.message);
        return;
    }
    dev.inst.deliver(LostDone, done);
}

fn deviceLost(_: [*c]const c.WGPUDevice, reason: c.WGPUDeviceLostReason, message: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const dev: *Device = @ptrCast(@alignCast(ud1.?));
    dev.lock.lock();
    if (!dev.dying and !dev.lost) {
        dev.lost = true;
        dev.lost_reason = if (reason == c.WGPUDeviceLostReason_Destroyed) wk.WGPUDeviceLostReason_Destroyed else wk.WGPUDeviceLostReason_Undefined;
        dev.lost_message = core.dupe(message);
        fireLost(dev);
    }
    dev.lock.unlock();
    dev.drop();
}

const ErrorDone = struct {
    cb: wk.WGPUErrorCallback,
    ud: ?*anyopaque,
    kind: wk.WGPUErrorType,
    message: [:0]u8,

    pub fn run(self: *ErrorDone) void {
        self.cb.?(self.kind, self.message.ptr, self.ud);
    }

    pub fn deinit(self: *ErrorDone) void {
        core.free(self.message);
    }
};

fn uncaptured(_: [*c]const c.WGPUDevice, kind: c.WGPUErrorType, message: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const dev: *Device = @ptrCast(@alignCast(ud1.?));
    dev.lock.lock();
    defer dev.lock.unlock();
    if (dev.paused or dev.dying) return;
    const m = core.dupe(message);
    if (dev.error_fn) |f| {
        dev.error_fn = null;
        dev.inst.deliver(ErrorDone, .{ .cb = f, .ud = dev.error_data, .kind = errorType(kind), .message = m });
        return;
    }
    if (dev.errors.items.len >= MAX_PENDING) {
        core.free(m);
        return;
    }
    dev.errors.append(gpa, .{ .kind = errorType(kind), .message = m }) catch core.free(m);
}

const DeviceReq = struct {
    dev: *Device,
    cb: wk.WGPURequestDeviceCallback,
    ud: ?*anyopaque,
};

const DeviceDone = struct {
    cb: wk.WGPURequestDeviceCallback,
    ud: ?*anyopaque,
    status: wk.WGPURequestDeviceStatus,
    dev: ?*Device,
    message: [:0]u8,

    pub fn run(self: *DeviceDone) void {
        const dv = self.dev;
        self.dev = null;
        self.cb.?(self.status, @ptrCast(dv), self.message.ptr, self.ud);
    }

    pub fn deinit(self: *DeviceDone) void {
        if (self.dev) |dv| dv.unref();
        core.free(self.message);
    }
};

fn deviceReady(status: c.WGPURequestDeviceStatus, raw: c.WGPUDevice, message: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const req: *DeviceReq = @ptrCast(@alignCast(ud1.?));
    const dev = req.dev;
    const inst = dev.inst;
    defer {
        gpa.destroy(req);
        inst.end();
    }
    var done = DeviceDone{ .cb = req.cb, .ud = req.ud, .status = wk.WGPURequestDeviceStatus_Error, .dev = null, .message = core.dupe(message) };
    if (status == c.WGPURequestDeviceStatus_Success and raw != null) {
        dev.raw = raw;
        done.status = wk.WGPURequestDeviceStatus_Success;
        done.dev = dev;
    } else {
        if (status != c.WGPURequestDeviceStatus_Error) done.status = wk.WGPURequestDeviceStatus_Unknown;
        dev.unref();
    }
    inst.deliver(DeviceDone, done);
}

const EXTRA_FEATURES = [_]c.WGPUFeatureName{
    c.WGPUFeatureName_ImplicitDeviceSynchronization,
    c.WGPUFeatureName_SharedTextureMemoryDmaBuf,
    c.WGPUFeatureName_SharedFenceSyncFD,
};

export fn wgpuAdapterRequestDevice(h: wk.WGPUAdapter, desc: ?*const wk.WGPUDeviceDescriptor, cb: wk.WGPURequestDeviceCallback, ud: ?*anyopaque) void {
    const a = adapter(h);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fail = DeviceDone{ .cb = cb, .ud = ud, .status = wk.WGPURequestDeviceStatus_Error, .dev = null, .message = @constCast("") };
    const dev = gpa.create(Device) catch return a.inst.deliver(DeviceDone, fail);
    dev.* = .{ .inst = a.inst, .adapter = a };
    a.ref();
    const req = gpa.create(DeviceReq) catch {
        dev.drop();
        dev.unref();
        return a.inst.deliver(DeviceDone, fail);
    };
    req.* = .{ .dev = dev, .cb = cb, .ud = ud };

    var wanted: std.ArrayList(c.WGPUFeatureName) = .empty;
    var limits: c.WGPULimits = undefined;
    var out = std.mem.zeroes(c.WGPUDeviceDescriptor);
    if (desc) |x| {
        out.label = core.str(x.label);
        out.defaultQueue.label = core.str(x.defaultQueue.label);
        if (x.requiredFeatures) |list| for (list[0..x.requiredFeatureCount]) |f| {
            const mapped = conv.to("WGPUFeatureName", f);
            if (mapped != 0) wanted.append(arena.allocator(), mapped) catch {};
        };
        if (x.requiredLimits) |l| {
            limits = conv.limits(&l.*.limits);
            out.requiredLimits = &limits;
        }
        dev.lost_fn = x.deviceLostCallback;
        dev.lost_data = x.deviceLostUserdata;
    }
    for (EXTRA_FEATURES) |f| {
        if (d("wgpuAdapterHasFeature")(a.raw, f) != 0) wanted.append(arena.allocator(), f) catch {};
    }
    out.requiredFeatureCount = wanted.items.len;
    out.requiredFeatures = wanted.items.ptr;
    out.deviceLostCallbackInfo = .{ .nextInChain = null, .mode = callbackMode(), .callback = deviceLost, .userdata1 = dev, .userdata2 = null };
    out.uncapturedErrorCallbackInfo = .{ .nextInChain = null, .callback = uncaptured, .userdata1 = dev, .userdata2 = null };
    a.inst.begin();
    _ = d("wgpuAdapterRequestDevice")(a.raw, &out, .{ .nextInChain = null, .mode = callbackMode(), .callback = deviceReady, .userdata1 = req, .userdata2 = null });
}

export fn wgpuDeviceReference(h: wk.WGPUDevice) void {
    device(h).ref();
}

export fn wgpuDeviceRelease(h: wk.WGPUDevice) void {
    device(h).unref();
}

export fn wgpuDeviceIsValid(h: wk.WGPUDevice) wk.WGPUBool {
    return @intFromBool(h != null and device(h).raw != null);
}

export fn wgpuDeviceDestroy(h: wk.WGPUDevice) void {
    if (device(h).raw) |r| d("wgpuDeviceDestroy")(r);
}

export fn wgpuDeviceSetLabel(h: wk.WGPUDevice, label: [*c]const u8) void {
    if (device(h).raw) |r| d("wgpuDeviceSetLabel")(r, core.str(label));
}

export fn wgpuDeviceGetLimits(h: wk.WGPUDevice, out: *wk.WGPUSupportedLimits) wk.WGPUBool {
    var l = std.mem.zeroes(c.WGPULimits);
    if (d("wgpuDeviceGetLimits")(device(h).raw, &l) != c.WGPUStatus_Success) return 0;
    out.limits = conv.limitsBack(&l);
    return 1;
}

export fn wgpuDeviceEnumerateFeatures(h: wk.WGPUDevice, out: ?[*]wk.WGPUFeatureName) usize {
    var supported = std.mem.zeroes(c.WGPUSupportedFeatures);
    d("wgpuDeviceGetFeatures")(device(h).raw, &supported);
    defer d("wgpuSupportedFeaturesFreeMembers")(supported);
    return listFeatures(supported, out);
}

export fn wgpuDeviceHasFeature(h: wk.WGPUDevice, f: wk.WGPUFeatureName) wk.WGPUBool {
    const mapped = conv.to("WGPUFeatureName", f);
    if (mapped == 0) return 0;
    return d("wgpuDeviceHasFeature")(device(h).raw, mapped);
}

export fn wgpuDeviceGetQueue(h: wk.WGPUDevice) wk.WGPUQueue {
    const dev = device(h);
    const raw = d("wgpuDeviceGetQueue")(dev.raw) orelse return null;
    const q = gpa.create(Queue) catch {
        d("wgpuQueueRelease")(raw);
        return null;
    };
    q.* = .{ .raw = raw, .dev = dev };
    dev.ref();
    return @ptrCast(q);
}

export fn wgpuDevicePushErrorScope(h: wk.WGPUDevice, filter: wk.WGPUErrorFilter) void {
    d("wgpuDevicePushErrorScope")(device(h).raw, conv.to("WGPUErrorFilter", filter));
}

const ScopeReq = struct {
    inst: *Instance,
    cb: wk.WGPUErrorCallback,
    ud: ?*anyopaque,
};

fn scopePopped(status: c.WGPUPopErrorScopeStatus, kind: c.WGPUErrorType, message: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const req: *ScopeReq = @ptrCast(@alignCast(ud1.?));
    const inst = req.inst;
    defer {
        gpa.destroy(req);
        inst.end();
        inst.unref();
    }
    const t = if (status == c.WGPUPopErrorScopeStatus_Success) errorType(kind) else wk.WGPUErrorType_Unknown;
    inst.deliver(ErrorDone, .{ .cb = req.cb, .ud = req.ud, .kind = t, .message = core.dupe(message) });
}

export fn wgpuDevicePopErrorScope(h: wk.WGPUDevice, cb: wk.WGPUErrorCallback, ud: ?*anyopaque) void {
    const dev = device(h);
    const req = gpa.create(ScopeReq) catch return dev.inst.deliver(ErrorDone, .{ .cb = cb, .ud = ud, .kind = wk.WGPUErrorType_Unknown, .message = @constCast("") });
    req.* = .{ .inst = dev.inst, .cb = cb, .ud = ud };
    dev.inst.ref();
    dev.inst.begin();
    _ = d("wgpuDevicePopErrorScope")(dev.raw, .{ .nextInChain = null, .mode = callbackMode(), .callback = scopePopped, .userdata1 = req, .userdata2 = null });
}

export fn wgpuDeviceSetUncapturedErrorCallback(h: wk.WGPUDevice, cb: wk.WGPUErrorCallback, ud: ?*anyopaque) void {
    const dev = device(h);
    dev.lock.lock();
    defer dev.lock.unlock();
    if (dev.error_fn) |old| dev.inst.deliver(ErrorDone, .{ .cb = old, .ud = dev.error_data, .kind = wk.WGPUErrorType_NoError, .message = @constCast("") });
    dev.error_fn = null;
    if (cb == null) return;
    if (dev.errors.items.len > 0) {
        const e = dev.errors.orderedRemove(0);
        dev.inst.deliver(ErrorDone, .{ .cb = cb, .ud = ud, .kind = e.kind, .message = e.message });
        return;
    }
    dev.error_fn = cb;
    dev.error_data = ud;
}

export fn wgpuDeviceClearUncapturedErrorCallback(h: wk.WGPUDevice) void {
    wgpuDeviceSetUncapturedErrorCallback(h, null, null);
}

export fn wgpuDevicePauseErrorReporting(h: wk.WGPUDevice, pause: wk.WGPUBool) void {
    const dev = device(h);
    dev.lock.lock();
    dev.paused = pause != 0;
    dev.lock.unlock();
}

export fn wgpuDeviceSetDeviceLostCallback(h: wk.WGPUDevice, cb: wk.WGPUDeviceLostCallback, ud: ?*anyopaque) void {
    const dev = device(h);
    dev.lock.lock();
    defer dev.lock.unlock();
    dev.lost_fn = cb;
    dev.lost_data = ud;
    if (dev.lost) fireLost(dev);
}

export fn wgpuDeviceSetDeviceLostCallbackWithBlock(h: wk.WGPUDevice, block: wk.WGPUDeviceLostBlockCallback) void {
    const dev = device(h);
    dev.lock.lock();
    defer dev.lock.unlock();
    if (dev.lost_block) |b| blocks._Block_release(b);
    dev.lost_block = blocks._Block_copy(@ptrCast(block));
    if (dev.lost) fireLost(dev);
}

export fn wgpuDeviceClearDeviceLostCallback(h: wk.WGPUDevice) void {
    const dev = device(h);
    dev.lock.lock();
    defer dev.lock.unlock();
    if (dev.lost_block) |b| blocks._Block_release(b);
    dev.lost_block = null;
    dev.lost_fn = null;
    dev.lost_data = null;
}

export fn wgpuQueueReference(h: wk.WGPUQueue) void {
    queue(h).ref();
}

export fn wgpuQueueRelease(h: wk.WGPUQueue) void {
    queue(h).unref();
}

export fn wgpuQueueIsValid(h: wk.WGPUQueue) wk.WGPUBool {
    return @intFromBool(h != null);
}

export fn wgpuQueueSetLabel(h: wk.WGPUQueue, label: [*c]const u8) void {
    d("wgpuQueueSetLabel")(queue(h).raw, core.str(label));
}

export fn wgpuQueueSubmit(h: wk.WGPUQueue, count: usize, list: [*c]const wk.WGPUCommandBuffer) void {
    d("wgpuQueueSubmit")(queue(h).raw, count, @ptrCast(list));
}

const WorkReq = struct {
    inst: *Instance,
    cb: wk.WGPUQueueWorkDoneCallback,
    ud: ?*anyopaque,
};

const WorkDone = struct {
    cb: wk.WGPUQueueWorkDoneCallback,
    ud: ?*anyopaque,
    status: wk.WGPUQueueWorkDoneStatus,

    pub fn run(self: *WorkDone) void {
        self.cb.?(self.status, self.ud);
    }
};

fn workDone(status: c.WGPUQueueWorkDoneStatus, _: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const req: *WorkReq = @ptrCast(@alignCast(ud1.?));
    const inst = req.inst;
    defer {
        gpa.destroy(req);
        inst.end();
        inst.unref();
    }
    const s: wk.WGPUQueueWorkDoneStatus = switch (status) {
        c.WGPUQueueWorkDoneStatus_Success => wk.WGPUQueueWorkDoneStatus_Success,
        c.WGPUQueueWorkDoneStatus_Error => wk.WGPUQueueWorkDoneStatus_Error,
        else => wk.WGPUQueueWorkDoneStatus_Unknown,
    };
    inst.deliver(WorkDone, .{ .cb = req.cb, .ud = req.ud, .status = s });
}

export fn wgpuQueueOnSubmittedWorkDone(h: wk.WGPUQueue, cb: wk.WGPUQueueWorkDoneCallback, ud: ?*anyopaque) void {
    const q = queue(h);
    const inst = q.dev.inst;
    const req = gpa.create(WorkReq) catch return inst.deliver(WorkDone, .{ .cb = cb, .ud = ud, .status = wk.WGPUQueueWorkDoneStatus_Error });
    req.* = .{ .inst = inst, .cb = cb, .ud = ud };
    inst.ref();
    inst.begin();
    _ = d("wgpuQueueOnSubmittedWorkDone")(q.raw, .{ .nextInChain = null, .mode = callbackMode(), .callback = workDone, .userdata1 = req, .userdata2 = null });
}
