const std = @import("std");
const core = @import("core.zig");
const api = @import("api.zig");
const wtf = @import("wtf.zig");
const sys = @import("sys.zig");

const c = core.c;
const wk = core.wk;
const d = core.d;
const gpa = core.gpa;
const Device = core.Device;
const Queue = core.Queue;

const Bytes = wtf.Span(u8);

const State = enum { unmapped, pending, mapped };

pub const Buffer = struct {
    refs: std.atomic.Value(u32) = .init(1),
    raw: c.WGPUBuffer,
    dev: *Device,
    size: u64,
    usage: wk.WGPUBufferUsageFlags,
    lock: sys.Lock = .{},
    state: State = .unmapped,
    mode: wk.WGPUMapModeFlags = 0,
    offset: u64 = 0,
    length: u64 = 0,
    base: ?[*]u8 = null,
    whole: u64 = 0,
    destroyed: bool = false,

    pub fn ref(self: *Buffer) void {
        core.retain(&self.refs);
    }

    pub fn unref(self: *Buffer) void {
        if (!core.release(&self.refs)) return;
        d("wgpuBufferRelease")(self.raw);
        self.dev.unref();
        gpa.destroy(self);
    }

    fn attach(self: *Buffer) void {
        if (self.mode & wk.WGPUMapMode_Write != 0) {
            self.base = @ptrCast(d("wgpuBufferGetMappedRange")(self.raw, 0, self.whole));
        } else {
            self.base = @ptrCast(@constCast(d("wgpuBufferGetConstMappedRange")(self.raw, 0, self.whole)));
        }
        self.state = if (self.base != null) .mapped else .unmapped;
    }
};

pub fn buffer(h: wk.WGPUBuffer) *Buffer {
    return @ptrCast(@alignCast(h.?));
}

pub fn raw(h: wk.WGPUBuffer) c.WGPUBuffer {
    return if (h == null) null else buffer(h).raw;
}

fn floor4(v: u64) u64 {
    return v & ~@as(u64, 3);
}

export fn wgpuDeviceCreateBuffer(h: wk.WGPUDevice, desc: *const wk.WGPUBufferDescriptor) wk.WGPUBuffer {
    const dev = api.device(h);
    const out = c.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = core.str(desc.label),
        .usage = desc.usage,
        .size = desc.size,
        .mappedAtCreation = desc.mappedAtCreation,
    };
    const r = d("wgpuDeviceCreateBuffer")(dev.raw, &out) orelse return null;
    const self = gpa.create(Buffer) catch {
        d("wgpuBufferRelease")(r);
        return null;
    };
    self.* = .{ .raw = r, .dev = dev, .size = desc.size, .usage = desc.usage };
    dev.ref();
    if (desc.mappedAtCreation != 0) {
        self.mode = wk.WGPUMapMode_Write;
        self.length = desc.size;
        self.whole = floor4(desc.size);
        self.attach();
    }
    return @ptrCast(self);
}

export fn wgpuBufferReference(h: wk.WGPUBuffer) void {
    buffer(h).ref();
}

export fn wgpuBufferRelease(h: wk.WGPUBuffer) void {
    buffer(h).unref();
}

export fn wgpuBufferIsValid(h: wk.WGPUBuffer) wk.WGPUBool {
    return @intFromBool(h != null);
}

export fn wgpuBufferSetLabel(h: wk.WGPUBuffer, label: [*c]const u8) void {
    d("wgpuBufferSetLabel")(buffer(h).raw, core.str(label));
}

export fn wgpuBufferGetInitialSize(h: wk.WGPUBuffer) u64 {
    return buffer(h).size;
}

export fn wgpuBufferGetCurrentSize(h: wk.WGPUBuffer) u64 {
    const b = buffer(h);
    return if (b.destroyed) 0 else b.size;
}

export fn wgpuBufferGetUsage(h: wk.WGPUBuffer) wk.WGPUBufferUsageFlags {
    return buffer(h).usage;
}

export fn wgpuBufferGetMapState(h: wk.WGPUBuffer) wk.WGPUBufferMapState {
    const b = buffer(h);
    b.lock.lock();
    defer b.lock.unlock();
    return switch (b.state) {
        .unmapped => wk.WGPUBufferMapState_Unmapped,
        .pending => wk.WGPUBufferMapState_Pending,
        .mapped => wk.WGPUBufferMapState_Mapped,
    };
}

const MapReq = struct {
    buf: *Buffer,
    cb: wk.WGPUBufferMapCallback,
    ud: ?*anyopaque,
};

const MapDone = struct {
    cb: wk.WGPUBufferMapCallback,
    ud: ?*anyopaque,
    status: wk.WGPUBufferMapAsyncStatus,

    pub fn run(self: *MapDone) void {
        self.cb.?(self.status, self.ud);
    }
};

fn mapStatus(status: c.WGPUMapAsyncStatus) wk.WGPUBufferMapAsyncStatus {
    return switch (status) {
        c.WGPUMapAsyncStatus_Success => wk.WGPUBufferMapAsyncStatus_Success,
        c.WGPUMapAsyncStatus_Aborted => wk.WGPUBufferMapAsyncStatus_UnmappedBeforeCallback,
        c.WGPUMapAsyncStatus_Error => wk.WGPUBufferMapAsyncStatus_ValidationError,
        else => wk.WGPUBufferMapAsyncStatus_Unknown,
    };
}

fn mapReady(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const req: *MapReq = @ptrCast(@alignCast(ud1.?));
    const b = req.buf;
    const inst = b.dev.inst;
    var s = mapStatus(status);
    b.lock.lock();
    if (b.state == .pending) {
        if (status == c.WGPUMapAsyncStatus_Success) {
            b.attach();
            if (b.state != .mapped) s = wk.WGPUBufferMapAsyncStatus_Unknown;
        } else {
            b.state = .unmapped;
        }
    } else if (s == wk.WGPUBufferMapAsyncStatus_Success) {
        s = wk.WGPUBufferMapAsyncStatus_UnmappedBeforeCallback;
    }
    b.lock.unlock();
    inst.deliver(MapDone, .{ .cb = req.cb, .ud = req.ud, .status = s });
    gpa.destroy(req);
    b.unref();
    inst.end();
}

fn validMap(b: *Buffer, mode: wk.WGPUMapModeFlags, offset: u64, size: u64) ?wk.WGPUBufferMapAsyncStatus {
    if (b.state != .unmapped) return wk.WGPUBufferMapAsyncStatus_MappingAlreadyPending;
    if (b.destroyed) return wk.WGPUBufferMapAsyncStatus_DestroyedBeforeCallback;
    if (offset % 8 != 0 or offset > b.size) return wk.WGPUBufferMapAsyncStatus_OffsetOutOfRange;
    if (size % 4 != 0 or size > b.size - offset) return wk.WGPUBufferMapAsyncStatus_SizeOutOfRange;
    const read = mode == wk.WGPUMapMode_Read and b.usage & wk.WGPUBufferUsage_MapRead != 0;
    const write = mode == wk.WGPUMapMode_Write and b.usage & wk.WGPUBufferUsage_MapWrite != 0;
    if (!read and !write) return wk.WGPUBufferMapAsyncStatus_ValidationError;
    return null;
}

export fn wgpuBufferMapAsync(h: wk.WGPUBuffer, mode: wk.WGPUMapModeFlags, offset: usize, size: usize, cb: wk.WGPUBufferMapCallback, ud: ?*anyopaque) void {
    const b = buffer(h);
    const inst = b.dev.inst;
    b.lock.lock();
    if (validMap(b, mode, offset, size)) |s| {
        b.lock.unlock();
        b.dev.inject("mapAsync was called with an invalid state, mode or range");
        return inst.deliver(MapDone, .{ .cb = cb, .ud = ud, .status = s });
    }
    const req = gpa.create(MapReq) catch {
        b.lock.unlock();
        return inst.deliver(MapDone, .{ .cb = cb, .ud = ud, .status = wk.WGPUBufferMapAsyncStatus_Unknown });
    };
    req.* = .{ .buf = b, .cb = cb, .ud = ud };
    b.state = .pending;
    b.mode = mode;
    b.offset = offset;
    b.length = size;
    b.whole = floor4(b.size);
    b.ref();
    b.lock.unlock();
    inst.begin();
    _ = d("wgpuBufferMapAsync")(b.raw, mode, 0, @intCast(b.whole), .{ .nextInChain = null, .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = mapReady, .userdata1 = req, .userdata2 = null });
}

export fn wgpuBufferGetMappedRange(h: wk.WGPUBuffer, offset: usize, size: usize) Bytes {
    const b = buffer(h);
    b.lock.lock();
    defer b.lock.unlock();
    const base = b.base orelse return .{ .ptr = null, .len = 0 };
    if (b.state != .mapped or offset % 8 != 0 or size % 4 != 0) return .{ .ptr = null, .len = 0 };
    if (offset < b.offset or offset - b.offset > b.length or size > b.length - (offset - b.offset)) return .{ .ptr = null, .len = 0 };
    if (offset + size > b.whole) return .{ .ptr = null, .len = 0 };
    return Bytes.of(base[offset .. offset + size]);
}

export fn wgpuBufferGetBufferContents(h: wk.WGPUBuffer) Bytes {
    const b = buffer(h);
    b.lock.lock();
    defer b.lock.unlock();
    const base = b.base orelse return .{ .ptr = null, .len = 0 };
    if (b.state != .mapped) return .{ .ptr = null, .len = 0 };
    return Bytes.of(base[0..@intCast(b.whole)]);
}

export fn wgpuBufferCopy(h: wk.WGPUBuffer, data: wtf.ConstSpan(u8), offset: usize) void {
    const contents = wgpuBufferGetBufferContents(h).slice();
    const src = data.slice();
    if (offset > contents.len or src.len > contents.len - offset) return;
    @memcpy(contents[offset .. offset + src.len], src);
}

export fn wgpuBufferUnmap(h: wk.WGPUBuffer) void {
    const b = buffer(h);
    b.lock.lock();
    b.state = .unmapped;
    b.base = null;
    b.lock.unlock();
    d("wgpuBufferUnmap")(b.raw);
}

export fn wgpuBufferDestroy(h: wk.WGPUBuffer) void {
    const b = buffer(h);
    b.lock.lock();
    b.destroyed = true;
    b.state = .unmapped;
    b.base = null;
    b.lock.unlock();
    d("wgpuBufferDestroy")(b.raw);
}

export fn wgpuBufferGenerateAValidationError(h: wk.WGPUBuffer) void {
    buffer(h).dev.inject("the buffer is invalid for this operation");
}

export fn wgpuQueueWriteBuffer(q: wk.WGPUQueue, h: wk.WGPUBuffer, offset: u64, data: Bytes) void {
    const queue: *Queue = @ptrCast(@alignCast(q.?));
    const s = data.slice();
    d("wgpuQueueWriteBuffer")(queue.raw, raw(h), offset, if (s.len == 0) null else s.ptr, s.len);
}
