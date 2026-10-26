const std = @import("std");
const core = @import("core.zig");
const api = @import("api.zig");
const buf = @import("buffer.zig");
const conv = @import("conv.zig");
const wtf = @import("wtf.zig");

const c = core.c;
const wk = core.wk;
const d = core.d;
const gpa = core.gpa;
const Device = core.Device;
const Instance = core.Instance;
const Queue = core.Queue;

const KINDS = [_][]const u8{
    "BindGroup",         "BindGroupLayout",     "CommandBuffer",     "CommandEncoder",
    "ComputePassEncoder", "ComputePipeline",    "PipelineLayout",    "QuerySet",
    "RenderBundle",      "RenderBundleEncoder", "RenderPassEncoder", "RenderPipeline",
    "Sampler",           "Texture",             "TextureView",
};

fn passThrough(comptime kind: []const u8) void {
    const H = @field(wk, "WGPU" ++ kind);
    const S = struct {
        fn reference(h: H) callconv(.c) void {
            if (h != null) d("wgpu" ++ kind ++ "AddRef")(@ptrCast(h));
        }

        fn release(h: H) callconv(.c) void {
            if (h != null) d("wgpu" ++ kind ++ "Release")(@ptrCast(h));
        }

        fn valid(h: H) callconv(.c) wk.WGPUBool {
            return @intFromBool(h != null);
        }

        fn setLabel(h: H, text: [*c]const u8) callconv(.c) void {
            if (h != null) d("wgpu" ++ kind ++ "SetLabel")(@ptrCast(h), core.str(text));
        }
    };
    @export(&S.reference, .{ .name = "wgpu" ++ kind ++ "Reference" });
    @export(&S.release, .{ .name = "wgpu" ++ kind ++ "Release" });
    @export(&S.valid, .{ .name = "wgpu" ++ kind ++ "IsValid" });
    @export(&S.setLabel, .{ .name = "wgpu" ++ kind ++ "SetLabel" });
}

comptime {
    for (KINDS) |k| passThrough(k);
}

fn dev(h: wk.WGPUDevice) c.WGPUDevice {
    return api.device(h).raw;
}

fn cast(comptime T: type, h: anytype) T {
    return @ptrCast(h);
}

fn many(comptime T: type, p: anytype, n: usize) []const T {
    if (n == 0 or p == null) return &.{};
    const q: [*]const T = @ptrCast(p);
    return q[0..n];
}

fn view(h: wk.WGPUTextureView, t: wk.WGPUTexture, made: *std.ArrayList(c.WGPUTextureView), arena: std.mem.Allocator) c.WGPUTextureView {
    if (h != null) return cast(c.WGPUTextureView, h);
    if (t == null) return null;
    const v = d("wgpuTextureCreateView")(cast(c.WGPUTexture, t), null);
    if (v != null) made.append(arena, v) catch {};
    return v;
}

fn dropViews(made: *std.ArrayList(c.WGPUTextureView)) void {
    for (made.items) |v| d("wgpuTextureViewRelease")(v);
}

fn alloc(arena: std.mem.Allocator, comptime T: type, n: usize) []T {
    return arena.alloc(T, n) catch @as([*]T, undefined)[0..0];
}

fn formats(arena: std.mem.Allocator, p: [*c]const wk.WGPUTextureFormat, n: usize) [*c]const c.WGPUTextureFormat {
    const src = many(wk.WGPUTextureFormat, p, n);
    const out = arena.alloc(c.WGPUTextureFormat, src.len) catch return null;
    for (src, out) |f, *o| o.* = conv.to("WGPUTextureFormat", f);
    return out.ptr;
}

fn constants(arena: std.mem.Allocator, p: [*c]const wk.WGPUConstantEntry, n: usize) [*c]const c.WGPUConstantEntry {
    const src = many(wk.WGPUConstantEntry, p, n);
    const out = arena.alloc(c.WGPUConstantEntry, src.len) catch return null;
    for (src, out) |e, *o| o.* = .{ .nextInChain = null, .key = core.str(e.key), .value = e.value };
    return out.ptr;
}

pub const ShaderModule = struct {
    refs: std.atomic.Value(u32) = .init(1),
    raw: c.WGPUShaderModule,
    inst: *Instance,

    pub fn ref(self: *ShaderModule) void {
        core.retain(&self.refs);
    }

    pub fn unref(self: *ShaderModule) void {
        if (!core.release(&self.refs)) return;
        d("wgpuShaderModuleRelease")(self.raw);
        self.inst.unref();
        gpa.destroy(self);
    }
};

fn module(h: wk.WGPUShaderModule) c.WGPUShaderModule {
    if (h == null) return null;
    const m: *ShaderModule = @ptrCast(@alignCast(h.?));
    return m.raw;
}

export fn wgpuDeviceCreateShaderModule(h: wk.WGPUDevice, desc: *const wk.WGPUShaderModuleDescriptor) wk.WGPUShaderModule {
    const dv = api.device(h);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var source = c.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
        .code = core.label(arena.allocator(), desc.wgslDescriptor),
    };
    const out = c.WGPUShaderModuleDescriptor{ .nextInChain = &source.chain, .label = core.str(desc.label) };
    const r = d("wgpuDeviceCreateShaderModule")(dv.raw, &out) orelse return null;
    const self = gpa.create(ShaderModule) catch {
        d("wgpuShaderModuleRelease")(r);
        return null;
    };
    self.* = .{ .raw = r, .inst = dv.inst };
    dv.inst.ref();
    return @ptrCast(self);
}

fn shader(h: wk.WGPUShaderModule) *ShaderModule {
    return @ptrCast(@alignCast(h.?));
}

export fn wgpuShaderModuleReference(h: wk.WGPUShaderModule) void {
    shader(h).ref();
}

export fn wgpuShaderModuleRelease(h: wk.WGPUShaderModule) void {
    shader(h).unref();
}

export fn wgpuShaderModuleIsValid(h: wk.WGPUShaderModule) wk.WGPUBool {
    return @intFromBool(h != null);
}

export fn wgpuShaderModuleSetLabel(h: wk.WGPUShaderModule, text: [*c]const u8) void {
    d("wgpuShaderModuleSetLabel")(shader(h).raw, core.str(text));
}

const InfoReq = struct {
    inst: *Instance,
    cb: wk.WGPUCompilationInfoCallback,
    ud: ?*anyopaque,
};

const InfoDone = struct {
    cb: wk.WGPUCompilationInfoCallback,
    ud: ?*anyopaque,
    status: wk.WGPUCompilationInfoRequestStatus,
    messages: []wk.WGPUCompilationMessage,

    pub fn run(self: *InfoDone) void {
        const info = wk.WGPUCompilationInfo{ .messageCount = self.messages.len, .messages = self.messages.ptr };
        self.cb.?(self.status, &info, self.ud);
    }

    pub fn deinit(self: *InfoDone) void {
        for (self.messages) |*m| wtf.deref(@ptrCast(&m.message));
        gpa.free(self.messages);
    }
};

fn messageType(t: c.WGPUCompilationMessageType) wk.WGPUCompilationMessageType {
    return switch (t) {
        c.WGPUCompilationMessageType_Warning => wk.WGPUCompilationMessageType_Warning,
        c.WGPUCompilationMessageType_Info => wk.WGPUCompilationMessageType_Info,
        else => wk.WGPUCompilationMessageType_Error,
    };
}

fn infoReady(status: c.WGPUCompilationInfoRequestStatus, info: [*c]const c.WGPUCompilationInfo, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const req: *InfoReq = @ptrCast(@alignCast(ud1.?));
    const inst = req.inst;
    defer {
        gpa.destroy(req);
        inst.end();
        inst.unref();
    }
    var done = InfoDone{ .cb = req.cb, .ud = req.ud, .status = wk.WGPUCompilationInfoRequestStatus_Unknown, .messages = &.{} };
    if (status == c.WGPUCompilationInfoRequestStatus_Success and info != null) {
        done.status = wk.WGPUCompilationInfoRequestStatus_Success;
        const src = many(c.WGPUCompilationMessage, info.*.messages, info.*.messageCount);
        if (gpa.alloc(wk.WGPUCompilationMessage, src.len)) |out| {
            for (src, out) |m, *o| {
                const s = wtf.fromUtf8(@import("dawn.zig").slice(m.message));
                o.* = std.mem.zeroes(wk.WGPUCompilationMessage);
                o.message = @bitCast(s);
                o.type = messageType(m.type);
                o.lineNum = m.lineNum;
                o.linePos = m.linePos;
                o.offset = m.offset;
                o.length = m.length;
                o.utf16LinePos = m.linePos;
                o.utf16Offset = m.offset;
                o.utf16Length = m.length;
            }
            done.messages = out;
        } else |_| {}
    }
    inst.deliver(InfoDone, done);
}

export fn wgpuShaderModuleGetCompilationInfo(h: wk.WGPUShaderModule, cb: wk.WGPUCompilationInfoCallback, ud: ?*anyopaque) void {
    const m = shader(h);
    const req = gpa.create(InfoReq) catch return m.inst.deliver(InfoDone, .{ .cb = cb, .ud = ud, .status = wk.WGPUCompilationInfoRequestStatus_Error, .messages = &.{} });
    req.* = .{ .inst = m.inst, .cb = cb, .ud = ud };
    m.inst.ref();
    m.inst.begin();
    _ = d("wgpuShaderModuleGetCompilationInfo")(m.raw, .{ .nextInChain = null, .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = infoReady, .userdata1 = req, .userdata2 = null });
}

export fn wgpuDeviceCreateTexture(h: wk.WGPUDevice, desc: *const wk.WGPUTextureDescriptor) wk.WGPUTexture {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = c.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = core.str(desc.label),
        .usage = desc.usage,
        .dimension = conv.to("WGPUTextureDimension", desc.dimension),
        .size = .{ .width = desc.size.width, .height = desc.size.height, .depthOrArrayLayers = desc.size.depthOrArrayLayers },
        .format = conv.to("WGPUTextureFormat", desc.format),
        .mipLevelCount = desc.mipLevelCount,
        .sampleCount = desc.sampleCount,
        .viewFormatCount = desc.viewFormatCount,
        .viewFormats = formats(arena.allocator(), desc.viewFormats, desc.viewFormatCount),
    };
    return @ptrCast(d("wgpuDeviceCreateTexture")(dev(h), &out));
}

export fn wgpuTextureCreateView(t: wk.WGPUTexture, desc: ?*const wk.WGPUTextureViewDescriptor) wk.WGPUTextureView {
    const x = desc orelse return @ptrCast(d("wgpuTextureCreateView")(cast(c.WGPUTexture, t), null));
    const out = c.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = core.str(x.label),
        .format = conv.to("WGPUTextureFormat", x.format),
        .dimension = conv.to("WGPUTextureViewDimension", x.dimension),
        .baseMipLevel = x.baseMipLevel,
        .mipLevelCount = x.mipLevelCount,
        .baseArrayLayer = x.baseArrayLayer,
        .arrayLayerCount = x.arrayLayerCount,
        .aspect = conv.to("WGPUTextureAspect", x.aspect),
        .usage = x.usage,
    };
    return @ptrCast(d("wgpuTextureCreateView")(cast(c.WGPUTexture, t), &out));
}

export fn wgpuTextureDestroy(t: wk.WGPUTexture) void {
    d("wgpuTextureDestroy")(cast(c.WGPUTexture, t));
}

export fn wgpuTextureUndestroy(_: wk.WGPUTexture) void {}

export fn wgpuTextureGetWidth(t: wk.WGPUTexture) u32 {
    return d("wgpuTextureGetWidth")(cast(c.WGPUTexture, t));
}

export fn wgpuTextureGetHeight(t: wk.WGPUTexture) u32 {
    return d("wgpuTextureGetHeight")(cast(c.WGPUTexture, t));
}

export fn wgpuTextureGetDepthOrArrayLayers(t: wk.WGPUTexture) u32 {
    return d("wgpuTextureGetDepthOrArrayLayers")(cast(c.WGPUTexture, t));
}

export fn wgpuTextureGetMipLevelCount(t: wk.WGPUTexture) u32 {
    return d("wgpuTextureGetMipLevelCount")(cast(c.WGPUTexture, t));
}

export fn wgpuTextureGetSampleCount(t: wk.WGPUTexture) u32 {
    return d("wgpuTextureGetSampleCount")(cast(c.WGPUTexture, t));
}

export fn wgpuTextureGetDimension(t: wk.WGPUTexture) wk.WGPUTextureDimension {
    return conv.from("WGPUTextureDimension", d("wgpuTextureGetDimension")(cast(c.WGPUTexture, t)));
}

export fn wgpuTextureGetFormat(t: wk.WGPUTexture) wk.WGPUTextureFormat {
    return conv.from("WGPUTextureFormat", d("wgpuTextureGetFormat")(cast(c.WGPUTexture, t)));
}

export fn wgpuTextureGetUsage(t: wk.WGPUTexture) wk.WGPUTextureUsageFlags {
    return @truncate(d("wgpuTextureGetUsage")(cast(c.WGPUTexture, t)));
}

export fn wgpuDeviceCreateSampler(h: wk.WGPUDevice, desc: ?*const wk.WGPUSamplerDescriptor) wk.WGPUSampler {
    const x = desc orelse return @ptrCast(d("wgpuDeviceCreateSampler")(dev(h), null));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = c.WGPUSamplerDescriptor{
        .nextInChain = null,
        .label = core.label(arena.allocator(), x.label),
        .addressModeU = conv.to("WGPUAddressMode", x.addressModeU),
        .addressModeV = conv.to("WGPUAddressMode", x.addressModeV),
        .addressModeW = conv.to("WGPUAddressMode", x.addressModeW),
        .magFilter = conv.to("WGPUFilterMode", x.magFilter),
        .minFilter = conv.to("WGPUFilterMode", x.minFilter),
        .mipmapFilter = conv.to("WGPUMipmapFilterMode", x.mipmapFilter),
        .lodMinClamp = x.lodMinClamp,
        .lodMaxClamp = x.lodMaxClamp,
        .compare = conv.to("WGPUCompareFunction", x.compare),
        .maxAnisotropy = x.maxAnisotropy,
    };
    return @ptrCast(d("wgpuDeviceCreateSampler")(dev(h), &out));
}

export fn wgpuDeviceCreateBindGroupLayout(h: wk.WGPUDevice, desc: *const wk.WGPUBindGroupLayoutDescriptor) wk.WGPUBindGroupLayout {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const src = many(wk.WGPUBindGroupLayoutEntry, desc.entries, desc.entryCount);
    const entries = arena.allocator().alloc(c.WGPUBindGroupLayoutEntry, src.len) catch return null;
    for (src, entries) |e, *o| {
        o.* = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        o.binding = e.binding;
        o.visibility = e.visibility;
        o.buffer = .{ .nextInChain = null, .type = conv.binding("WGPUBufferBindingType", e.buffer.type), .hasDynamicOffset = e.buffer.hasDynamicOffset, .minBindingSize = e.buffer.minBindingSize };
        o.sampler = .{ .nextInChain = null, .type = conv.binding("WGPUSamplerBindingType", e.sampler.type) };
        o.texture = .{ .nextInChain = null, .sampleType = conv.binding("WGPUTextureSampleType", e.texture.sampleType), .viewDimension = conv.to("WGPUTextureViewDimension", e.texture.viewDimension), .multisampled = e.texture.multisampled };
        o.storageTexture = .{ .nextInChain = null, .access = conv.binding("WGPUStorageTextureAccess", e.storageTexture.access), .format = conv.to("WGPUTextureFormat", e.storageTexture.format), .viewDimension = conv.to("WGPUTextureViewDimension", e.storageTexture.viewDimension) };
    }
    const out = c.WGPUBindGroupLayoutDescriptor{ .nextInChain = null, .label = core.str(desc.label), .entryCount = entries.len, .entries = entries.ptr };
    return @ptrCast(d("wgpuDeviceCreateBindGroupLayout")(dev(h), &out));
}

export fn wgpuDeviceCreatePipelineLayout(h: wk.WGPUDevice, desc: *const wk.WGPUPipelineLayoutDescriptor) wk.WGPUPipelineLayout {
    const out = c.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = core.str(desc.label),
        .bindGroupLayoutCount = desc.bindGroupLayoutCount,
        .bindGroupLayouts = @ptrCast(desc.bindGroupLayouts),
        .immediateSize = 0,
    };
    return @ptrCast(d("wgpuDeviceCreatePipelineLayout")(dev(h), &out));
}

export fn wgpuDeviceCreateBindGroup(h: wk.WGPUDevice, desc: *const wk.WGPUBindGroupDescriptor) wk.WGPUBindGroup {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var made: std.ArrayList(c.WGPUTextureView) = .empty;
    defer dropViews(&made);
    const src = many(wk.WGPUBindGroupEntry, desc.entries, desc.entryCount);
    const entries = arena.allocator().alloc(c.WGPUBindGroupEntry, src.len) catch return null;
    for (src, entries) |e, *o| o.* = .{
        .nextInChain = null,
        .binding = e.binding,
        .buffer = buf.raw(e.buffer),
        .offset = e.offset,
        .size = e.size,
        .sampler = cast(c.WGPUSampler, e.sampler),
        .textureView = view(e.textureView, e.texture, &made, arena.allocator()),
    };
    const out = c.WGPUBindGroupDescriptor{ .nextInChain = null, .label = core.str(desc.label), .layout = cast(c.WGPUBindGroupLayout, desc.layout), .entryCount = entries.len, .entries = entries.ptr };
    return @ptrCast(d("wgpuDeviceCreateBindGroup")(dev(h), &out));
}

export fn wgpuBindGroupUpdateExternalTextures(_: wk.WGPUBindGroup, _: wk.WGPUExternalTexture) bool {
    return false;
}

fn computeDesc(arena: std.mem.Allocator, x: *const wk.WGPUComputePipelineDescriptor) c.WGPUComputePipelineDescriptor {
    return .{
        .nextInChain = null,
        .label = core.str(x.label),
        .layout = cast(c.WGPUPipelineLayout, x.layout),
        .compute = .{
            .nextInChain = null,
            .module = module(x.compute.module),
            .entryPoint = core.str(x.compute.entryPoint),
            .constantCount = x.compute.constantCount,
            .constants = constants(arena, x.compute.constants, x.compute.constantCount),
        },
    };
}

fn stencil(s: wk.WGPUStencilFaceState) c.WGPUStencilFaceState {
    return .{
        .compare = conv.to("WGPUCompareFunction", s.compare),
        .failOp = conv.to("WGPUStencilOperation", s.failOp),
        .depthFailOp = conv.to("WGPUStencilOperation", s.depthFailOp),
        .passOp = conv.to("WGPUStencilOperation", s.passOp),
    };
}

fn blend(b: wk.WGPUBlendComponent) c.WGPUBlendComponent {
    return .{
        .operation = conv.to("WGPUBlendOperation", b.operation),
        .srcFactor = conv.to("WGPUBlendFactor", b.srcFactor),
        .dstFactor = conv.to("WGPUBlendFactor", b.dstFactor),
    };
}

const RenderParts = struct {
    desc: c.WGPURenderPipelineDescriptor,
    depth: c.WGPUDepthStencilState,
    fragment: c.WGPUFragmentState,
};

fn renderDesc(arena: std.mem.Allocator, x: *const wk.WGPURenderPipelineDescriptor, parts: *RenderParts) void {
    const bufs = many(wk.WGPUVertexBufferLayout, x.vertex.buffers, x.vertex.bufferCount);
    const layouts = alloc(arena, c.WGPUVertexBufferLayout, bufs.len);
    for (bufs[0..layouts.len], layouts) |b, *o| {
        const attrs = many(wk.WGPUVertexAttribute, b.attributes, b.attributeCount);
        const out = alloc(arena, c.WGPUVertexAttribute, attrs.len);
        for (attrs[0..out.len], out) |a, *p| p.* = .{ .nextInChain = null, .format = conv.to("WGPUVertexFormat", a.format), .offset = a.offset, .shaderLocation = a.shaderLocation };
        o.* = .{ .nextInChain = null, .stepMode = conv.to("WGPUVertexStepMode", b.stepMode), .arrayStride = b.arrayStride, .attributeCount = out.len, .attributes = out.ptr };
    }
    parts.desc = .{
        .nextInChain = null,
        .label = core.str(x.label),
        .layout = cast(c.WGPUPipelineLayout, x.layout),
        .vertex = .{
            .nextInChain = null,
            .module = module(x.vertex.module),
            .entryPoint = core.str(x.vertex.entryPoint),
            .constantCount = x.vertex.constantCount,
            .constants = constants(arena, x.vertex.constants, x.vertex.constantCount),
            .bufferCount = layouts.len,
            .buffers = layouts.ptr,
        },
        .primitive = .{
            .nextInChain = null,
            .topology = conv.to("WGPUPrimitiveTopology", x.primitive.topology),
            .stripIndexFormat = conv.to("WGPUIndexFormat", x.primitive.stripIndexFormat),
            .frontFace = conv.to("WGPUFrontFace", x.primitive.frontFace),
            .cullMode = conv.to("WGPUCullMode", x.primitive.cullMode),
            .unclippedDepth = x.primitive.unclippedDepth,
        },
        .depthStencil = null,
        .multisample = .{ .nextInChain = null, .count = x.multisample.count, .mask = x.multisample.mask, .alphaToCoverageEnabled = x.multisample.alphaToCoverageEnabled },
        .fragment = null,
    };
    if (x.depthStencil) |s| {
        parts.depth = .{
            .nextInChain = null,
            .format = conv.to("WGPUTextureFormat", s.*.format),
            .depthWriteEnabled = conv.optionalBool(s.*.depthWriteEnabled),
            .depthCompare = conv.to("WGPUCompareFunction", s.*.depthCompare),
            .stencilFront = stencil(s.*.stencilFront),
            .stencilBack = stencil(s.*.stencilBack),
            .stencilReadMask = s.*.stencilReadMask,
            .stencilWriteMask = s.*.stencilWriteMask,
            .depthBias = s.*.depthBias,
            .depthBiasSlopeScale = s.*.depthBiasSlopeScale,
            .depthBiasClamp = s.*.depthBiasClamp,
        };
        parts.desc.depthStencil = &parts.depth;
    }
    if (x.fragment) |f| {
        const src = many(wk.WGPUColorTargetState, f.*.targets, f.*.targetCount);
        const targets = alloc(arena, c.WGPUColorTargetState, src.len);
        for (src[0..targets.len], targets) |t, *o| {
            var b: ?*c.WGPUBlendState = null;
            if (t.blend) |tb| {
                b = arena.create(c.WGPUBlendState) catch null;
                if (b) |p| p.* = .{ .color = blend(tb.*.color), .alpha = blend(tb.*.alpha) };
            }
            o.* = .{ .nextInChain = null, .format = conv.to("WGPUTextureFormat", t.format), .blend = b, .writeMask = t.writeMask };
        }
        parts.fragment = .{
            .nextInChain = null,
            .module = module(f.*.module),
            .entryPoint = core.str(f.*.entryPoint),
            .constantCount = f.*.constantCount,
            .constants = constants(arena, f.*.constants, f.*.constantCount),
            .targetCount = targets.len,
            .targets = targets.ptr,
        };
        parts.desc.fragment = &parts.fragment;
    }
}

export fn wgpuDeviceCreateComputePipeline(h: wk.WGPUDevice, desc: *const wk.WGPUComputePipelineDescriptor) wk.WGPUComputePipeline {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = computeDesc(arena.allocator(), desc);
    return @ptrCast(d("wgpuDeviceCreateComputePipeline")(dev(h), &out));
}

export fn wgpuDeviceCreateRenderPipeline(h: wk.WGPUDevice, desc: *const wk.WGPURenderPipelineDescriptor) wk.WGPURenderPipeline {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parts: RenderParts = undefined;
    renderDesc(arena.allocator(), desc, &parts);
    return @ptrCast(d("wgpuDeviceCreateRenderPipeline")(dev(h), &parts.desc));
}

fn pipelineStatus(s: c.WGPUCreatePipelineAsyncStatus) wk.WGPUCreatePipelineAsyncStatus {
    return switch (s) {
        c.WGPUCreatePipelineAsyncStatus_Success => wk.WGPUCreatePipelineAsyncStatus_Success,
        c.WGPUCreatePipelineAsyncStatus_ValidationError => wk.WGPUCreatePipelineAsyncStatus_ValidationError,
        c.WGPUCreatePipelineAsyncStatus_InternalError => wk.WGPUCreatePipelineAsyncStatus_InternalError,
        else => wk.WGPUCreatePipelineAsyncStatus_Unknown,
    };
}

fn Pipeline(comptime P: type, comptime Callback: type, comptime release: []const u8) type {
    return struct {
        const Req = struct {
            inst: *Instance,
            cb: Callback,
            ud: ?*anyopaque,
        };

        const Done = struct {
            cb: Callback,
            ud: ?*anyopaque,
            status: wk.WGPUCreatePipelineAsyncStatus,
            pipeline: P,
            message: [:0]u8,

            pub fn run(self: *Done) void {
                var s = wtf.fromUtf8(self.message);
                const p = self.pipeline;
                self.pipeline = null;
                self.cb.?(self.status, @ptrCast(p), @ptrCast(&s), self.ud);
                wtf.deref(&s);
            }

            pub fn deinit(self: *Done) void {
                if (self.pipeline != null) d(release)(self.pipeline);
                core.free(self.message);
            }
        };

        fn ready(status: c.WGPUCreatePipelineAsyncStatus, p: P, message: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const req: *Req = @ptrCast(@alignCast(ud1.?));
            const inst = req.inst;
            defer {
                gpa.destroy(req);
                inst.end();
                inst.unref();
            }
            inst.deliver(Done, .{ .cb = req.cb, .ud = req.ud, .status = pipelineStatus(status), .pipeline = p, .message = core.dupe(message) });
        }

        fn start(dv: *Device, cb: Callback, ud: ?*anyopaque) ?*Req {
            const req = gpa.create(Req) catch {
                dv.inst.deliver(Done, .{ .cb = cb, .ud = ud, .status = wk.WGPUCreatePipelineAsyncStatus_InternalError, .pipeline = null, .message = @constCast("") });
                return null;
            };
            req.* = .{ .inst = dv.inst, .cb = cb, .ud = ud };
            dv.inst.ref();
            dv.inst.begin();
            return req;
        }
    };
}

const ComputeAsync = Pipeline(c.WGPUComputePipeline, wk.WGPUCreateComputePipelineAsyncCallback, "wgpuComputePipelineRelease");
const RenderAsync = Pipeline(c.WGPURenderPipeline, wk.WGPUCreateRenderPipelineAsyncCallback, "wgpuRenderPipelineRelease");

export fn wgpuDeviceCreateComputePipelineAsync(h: wk.WGPUDevice, desc: *const wk.WGPUComputePipelineDescriptor, cb: wk.WGPUCreateComputePipelineAsyncCallback, ud: ?*anyopaque) void {
    const dv = api.device(h);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = computeDesc(arena.allocator(), desc);
    const req = ComputeAsync.start(dv, cb, ud) orelse return;
    _ = d("wgpuDeviceCreateComputePipelineAsync")(dv.raw, &out, .{ .nextInChain = null, .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = ComputeAsync.ready, .userdata1 = req, .userdata2 = null });
}

export fn wgpuDeviceCreateRenderPipelineAsync(h: wk.WGPUDevice, desc: *const wk.WGPURenderPipelineDescriptor, cb: wk.WGPUCreateRenderPipelineAsyncCallback, ud: ?*anyopaque) void {
    const dv = api.device(h);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parts: RenderParts = undefined;
    renderDesc(arena.allocator(), desc, &parts);
    const req = RenderAsync.start(dv, cb, ud) orelse return;
    _ = d("wgpuDeviceCreateRenderPipelineAsync")(dv.raw, &parts.desc, .{ .nextInChain = null, .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = RenderAsync.ready, .userdata1 = req, .userdata2 = null });
}

export fn wgpuComputePipelineGetBindGroupLayout(p: wk.WGPUComputePipeline, index: u32) wk.WGPUBindGroupLayout {
    return @ptrCast(d("wgpuComputePipelineGetBindGroupLayout")(cast(c.WGPUComputePipeline, p), index));
}

export fn wgpuRenderPipelineGetBindGroupLayout(p: wk.WGPURenderPipeline, index: u32) wk.WGPUBindGroupLayout {
    return @ptrCast(d("wgpuRenderPipelineGetBindGroupLayout")(cast(c.WGPURenderPipeline, p), index));
}

export fn wgpuDeviceCreateQuerySet(h: wk.WGPUDevice, desc: *const wk.WGPUQuerySetDescriptor) wk.WGPUQuerySet {
    const out = c.WGPUQuerySetDescriptor{ .nextInChain = null, .label = core.str(desc.label), .type = conv.to("WGPUQueryType", desc.type), .count = desc.count };
    return @ptrCast(d("wgpuDeviceCreateQuerySet")(dev(h), &out));
}

export fn wgpuQuerySetDestroy(q: wk.WGPUQuerySet) void {
    d("wgpuQuerySetDestroy")(cast(c.WGPUQuerySet, q));
}

export fn wgpuQuerySetGetCount(q: wk.WGPUQuerySet) u32 {
    return d("wgpuQuerySetGetCount")(cast(c.WGPUQuerySet, q));
}

export fn wgpuQuerySetGetType(q: wk.WGPUQuerySet) wk.WGPUQueryType {
    return conv.from("WGPUQueryType", d("wgpuQuerySetGetType")(cast(c.WGPUQuerySet, q)));
}

export fn wgpuDeviceCreateCommandEncoder(h: wk.WGPUDevice, desc: ?*const wk.WGPUCommandEncoderDescriptor) wk.WGPUCommandEncoder {
    const out = c.WGPUCommandEncoderDescriptor{ .nextInChain = null, .label = core.str(if (desc) |x| x.label else null) };
    return @ptrCast(d("wgpuDeviceCreateCommandEncoder")(dev(h), &out));
}

fn encoder(e: wk.WGPUCommandEncoder) c.WGPUCommandEncoder {
    return cast(c.WGPUCommandEncoder, e);
}

fn timestamps(t: anytype) c.WGPUPassTimestampWrites {
    return .{ .nextInChain = null, .querySet = cast(c.WGPUQuerySet, t.*.querySet), .beginningOfPassWriteIndex = t.*.beginningOfPassWriteIndex, .endOfPassWriteIndex = t.*.endOfPassWriteIndex };
}

export fn wgpuCommandEncoderBeginComputePass(e: wk.WGPUCommandEncoder, desc: ?*const wk.WGPUComputePassDescriptor) wk.WGPUComputePassEncoder {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var writes: c.WGPUPassTimestampWrites = undefined;
    var out = std.mem.zeroes(c.WGPUComputePassDescriptor);
    out.label = core.str(null);
    if (desc) |x| {
        out.label = core.label(arena.allocator(), x.label);
        if (x.timestampWrites) |t| {
            writes = timestamps(t);
            out.timestampWrites = &writes;
        }
    }
    return @ptrCast(d("wgpuCommandEncoderBeginComputePass")(encoder(e), &out));
}

export fn wgpuCommandEncoderBeginRenderPass(e: wk.WGPUCommandEncoder, desc: *const wk.WGPURenderPassDescriptor) wk.WGPURenderPassEncoder {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var made: std.ArrayList(c.WGPUTextureView) = .empty;
    defer dropViews(&made);
    const src = many(wk.WGPURenderPassColorAttachment, desc.colorAttachments, desc.colorAttachmentCount);
    const colors = a.alloc(c.WGPURenderPassColorAttachment, src.len) catch return null;
    for (src, colors) |x, *o| o.* = .{
        .nextInChain = null,
        .view = view(x.view, x.texture, &made, a),
        .depthSlice = if (x.depthSlice.engaged) x.depthSlice.value else c.WGPU_DEPTH_SLICE_UNDEFINED,
        .resolveTarget = view(x.resolveTarget, x.resolveTexture, &made, a),
        .loadOp = conv.to("WGPULoadOp", x.loadOp),
        .storeOp = conv.to("WGPUStoreOp", x.storeOp),
        .clearValue = .{ .r = x.clearValue.r, .g = x.clearValue.g, .b = x.clearValue.b, .a = x.clearValue.a },
    };
    var depth: c.WGPURenderPassDepthStencilAttachment = undefined;
    var writes: c.WGPUPassTimestampWrites = undefined;
    var draws = c.WGPURenderPassMaxDrawCount{ .chain = .{ .next = null, .sType = c.WGPUSType_RenderPassMaxDrawCount }, .maxDrawCount = desc.maxDrawCount };
    var out = c.WGPURenderPassDescriptor{
        .nextInChain = &draws.chain,
        .label = core.str(desc.label),
        .colorAttachmentCount = colors.len,
        .colorAttachments = colors.ptr,
        .depthStencilAttachment = null,
        .occlusionQuerySet = cast(c.WGPUQuerySet, desc.occlusionQuerySet),
        .timestampWrites = null,
    };
    if (desc.depthStencilAttachment) |x| {
        depth = .{
            .nextInChain = null,
            .view = view(x.*.view, x.*.texture, &made, a),
            .depthLoadOp = conv.to("WGPULoadOp", x.*.depthLoadOp),
            .depthStoreOp = conv.to("WGPUStoreOp", x.*.depthStoreOp),
            .depthClearValue = x.*.depthClearValue,
            .depthReadOnly = x.*.depthReadOnly,
            .stencilLoadOp = conv.to("WGPULoadOp", x.*.stencilLoadOp),
            .stencilStoreOp = conv.to("WGPUStoreOp", x.*.stencilStoreOp),
            .stencilClearValue = x.*.stencilClearValue,
            .stencilReadOnly = x.*.stencilReadOnly,
        };
        out.depthStencilAttachment = &depth;
    }
    if (desc.timestampWrites) |t| {
        writes = timestamps(t);
        out.timestampWrites = &writes;
    }
    return @ptrCast(d("wgpuCommandEncoderBeginRenderPass")(encoder(e), &out));
}

export fn wgpuCommandEncoderClearBuffer(e: wk.WGPUCommandEncoder, b: wk.WGPUBuffer, offset: u64, size: u64) void {
    d("wgpuCommandEncoderClearBuffer")(encoder(e), buf.raw(b), offset, size);
}

export fn wgpuCommandEncoderCopyBufferToBuffer(e: wk.WGPUCommandEncoder, src: wk.WGPUBuffer, src_offset: u64, dst: wk.WGPUBuffer, dst_offset: u64, size: u64) void {
    d("wgpuCommandEncoderCopyBufferToBuffer")(encoder(e), buf.raw(src), src_offset, buf.raw(dst), dst_offset, size);
}

fn bufferCopy(x: *const wk.WGPUImageCopyBuffer) c.WGPUTexelCopyBufferInfo {
    return .{ .layout = .{ .offset = x.layout.offset, .bytesPerRow = x.layout.bytesPerRow, .rowsPerImage = x.layout.rowsPerImage }, .buffer = buf.raw(x.buffer) };
}

fn textureCopy(x: *const wk.WGPUImageCopyTexture) c.WGPUTexelCopyTextureInfo {
    return .{ .texture = cast(c.WGPUTexture, x.texture), .mipLevel = x.mipLevel, .origin = .{ .x = x.origin.x, .y = x.origin.y, .z = x.origin.z }, .aspect = conv.to("WGPUTextureAspect", x.aspect) };
}

fn extent(x: *const wk.WGPUExtent3D) c.WGPUExtent3D {
    return .{ .width = x.width, .height = x.height, .depthOrArrayLayers = x.depthOrArrayLayers };
}

export fn wgpuCommandEncoderCopyBufferToTexture(e: wk.WGPUCommandEncoder, src: *const wk.WGPUImageCopyBuffer, dst: *const wk.WGPUImageCopyTexture, size: *const wk.WGPUExtent3D) void {
    const s = bufferCopy(src);
    const t = textureCopy(dst);
    const x = extent(size);
    d("wgpuCommandEncoderCopyBufferToTexture")(encoder(e), &s, &t, &x);
}

export fn wgpuCommandEncoderCopyTextureToBuffer(e: wk.WGPUCommandEncoder, src: *const wk.WGPUImageCopyTexture, dst: *const wk.WGPUImageCopyBuffer, size: *const wk.WGPUExtent3D) void {
    const s = textureCopy(src);
    const t = bufferCopy(dst);
    const x = extent(size);
    d("wgpuCommandEncoderCopyTextureToBuffer")(encoder(e), &s, &t, &x);
}

export fn wgpuCommandEncoderCopyTextureToTexture(e: wk.WGPUCommandEncoder, src: *const wk.WGPUImageCopyTexture, dst: *const wk.WGPUImageCopyTexture, size: *const wk.WGPUExtent3D) void {
    const s = textureCopy(src);
    const t = textureCopy(dst);
    const x = extent(size);
    d("wgpuCommandEncoderCopyTextureToTexture")(encoder(e), &s, &t, &x);
}

export fn wgpuCommandEncoderFinish(e: wk.WGPUCommandEncoder, desc: ?*const wk.WGPUCommandBufferDescriptor) wk.WGPUCommandBuffer {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = c.WGPUCommandBufferDescriptor{ .nextInChain = null, .label = if (desc) |x| core.label(arena.allocator(), x.label) else core.str(null) };
    return @ptrCast(d("wgpuCommandEncoderFinish")(encoder(e), &out));
}

export fn wgpuCommandEncoderResolveQuerySet(e: wk.WGPUCommandEncoder, q: wk.WGPUQuerySet, first: u32, count: u32, dst: wk.WGPUBuffer, offset: u64) void {
    d("wgpuCommandEncoderResolveQuerySet")(encoder(e), cast(c.WGPUQuerySet, q), first, count, buf.raw(dst), offset);
}

export fn wgpuCommandEncoderWriteTimestamp(e: wk.WGPUCommandEncoder, q: wk.WGPUQuerySet, index: u32) void {
    d("wgpuCommandEncoderWriteTimestamp")(encoder(e), cast(c.WGPUQuerySet, q), index);
}

fn markers(comptime kind: []const u8) void {
    const H = @field(wk, "WGPU" ++ kind);
    const S = struct {
        fn insert(h: H, text: [*c]const u8) callconv(.c) void {
            d("wgpu" ++ kind ++ "InsertDebugMarker")(@ptrCast(h), core.str(text));
        }

        fn push(h: H, text: [*c]const u8) callconv(.c) void {
            d("wgpu" ++ kind ++ "PushDebugGroup")(@ptrCast(h), core.str(text));
        }

        fn pop(h: H) callconv(.c) void {
            d("wgpu" ++ kind ++ "PopDebugGroup")(@ptrCast(h));
        }
    };
    @export(&S.insert, .{ .name = "wgpu" ++ kind ++ "InsertDebugMarker" });
    @export(&S.push, .{ .name = "wgpu" ++ kind ++ "PushDebugGroup" });
    @export(&S.pop, .{ .name = "wgpu" ++ kind ++ "PopDebugGroup" });
}

comptime {
    for ([_][]const u8{ "CommandEncoder", "ComputePassEncoder", "RenderPassEncoder", "RenderBundleEncoder" }) |k| markers(k);
}

const Offsets = wtf.Optional(wtf.Vector(u32));

fn offsets(o: ?*Offsets) []const u32 {
    const x = o orelse return &.{};
    if (!x.engaged) return &.{};
    return x.value.items();
}

export fn wgpuComputePassEncoderSetPipeline(p: wk.WGPUComputePassEncoder, pipeline: wk.WGPUComputePipeline) void {
    d("wgpuComputePassEncoderSetPipeline")(cast(c.WGPUComputePassEncoder, p), cast(c.WGPUComputePipeline, pipeline));
}

export fn wgpuComputePassEncoderSetBindGroup(p: wk.WGPUComputePassEncoder, index: u32, group: wk.WGPUBindGroup, dynamic: ?*Offsets) void {
    const list = offsets(dynamic);
    d("wgpuComputePassEncoderSetBindGroup")(cast(c.WGPUComputePassEncoder, p), index, cast(c.WGPUBindGroup, group), list.len, if (list.len == 0) null else list.ptr);
}

export fn wgpuComputePassEncoderDispatchWorkgroups(p: wk.WGPUComputePassEncoder, x: u32, y: u32, z: u32) void {
    d("wgpuComputePassEncoderDispatchWorkgroups")(cast(c.WGPUComputePassEncoder, p), x, y, z);
}

export fn wgpuComputePassEncoderDispatchWorkgroupsIndirect(p: wk.WGPUComputePassEncoder, b: wk.WGPUBuffer, offset: u64) void {
    d("wgpuComputePassEncoderDispatchWorkgroupsIndirect")(cast(c.WGPUComputePassEncoder, p), buf.raw(b), offset);
}

export fn wgpuComputePassEncoderEnd(p: wk.WGPUComputePassEncoder) void {
    d("wgpuComputePassEncoderEnd")(cast(c.WGPUComputePassEncoder, p));
}

fn pass(p: wk.WGPURenderPassEncoder) c.WGPURenderPassEncoder {
    return cast(c.WGPURenderPassEncoder, p);
}

export fn wgpuRenderPassEncoderSetPipeline(p: wk.WGPURenderPassEncoder, pipeline: wk.WGPURenderPipeline) void {
    d("wgpuRenderPassEncoderSetPipeline")(pass(p), cast(c.WGPURenderPipeline, pipeline));
}

export fn wgpuRenderPassEncoderSetBindGroup(p: wk.WGPURenderPassEncoder, index: u32, group: wk.WGPUBindGroup, dynamic: ?*Offsets) void {
    const list = offsets(dynamic);
    d("wgpuRenderPassEncoderSetBindGroup")(pass(p), index, cast(c.WGPUBindGroup, group), list.len, if (list.len == 0) null else list.ptr);
}

export fn wgpuRenderPassEncoderSetVertexBuffer(p: wk.WGPURenderPassEncoder, slot: u32, b: wk.WGPUBuffer, offset: u64, size: u64) void {
    d("wgpuRenderPassEncoderSetVertexBuffer")(pass(p), slot, buf.raw(b), offset, size);
}

export fn wgpuRenderPassEncoderSetIndexBuffer(p: wk.WGPURenderPassEncoder, b: wk.WGPUBuffer, format: wk.WGPUIndexFormat, offset: u64, size: u64) void {
    d("wgpuRenderPassEncoderSetIndexBuffer")(pass(p), buf.raw(b), conv.to("WGPUIndexFormat", format), offset, size);
}

export fn wgpuRenderPassEncoderDraw(p: wk.WGPURenderPassEncoder, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
    d("wgpuRenderPassEncoderDraw")(pass(p), vertices, instances, first_vertex, first_instance);
}

export fn wgpuRenderPassEncoderDrawIndexed(p: wk.WGPURenderPassEncoder, indices: u32, instances: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    d("wgpuRenderPassEncoderDrawIndexed")(pass(p), indices, instances, first_index, base_vertex, first_instance);
}

export fn wgpuRenderPassEncoderDrawIndirect(p: wk.WGPURenderPassEncoder, b: wk.WGPUBuffer, offset: u64) void {
    d("wgpuRenderPassEncoderDrawIndirect")(pass(p), buf.raw(b), offset);
}

export fn wgpuRenderPassEncoderDrawIndexedIndirect(p: wk.WGPURenderPassEncoder, b: wk.WGPUBuffer, offset: u64) void {
    d("wgpuRenderPassEncoderDrawIndexedIndirect")(pass(p), buf.raw(b), offset);
}

export fn wgpuRenderPassEncoderSetViewport(p: wk.WGPURenderPassEncoder, x: f32, y: f32, w: f32, h: f32, min: f32, max: f32) void {
    d("wgpuRenderPassEncoderSetViewport")(pass(p), x, y, w, h, min, max);
}

export fn wgpuRenderPassEncoderSetScissorRect(p: wk.WGPURenderPassEncoder, x: u32, y: u32, w: u32, h: u32) void {
    d("wgpuRenderPassEncoderSetScissorRect")(pass(p), x, y, w, h);
}

export fn wgpuRenderPassEncoderSetBlendConstant(p: wk.WGPURenderPassEncoder, color: *const wk.WGPUColor) void {
    const x = c.WGPUColor{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    d("wgpuRenderPassEncoderSetBlendConstant")(pass(p), &x);
}

export fn wgpuRenderPassEncoderSetStencilReference(p: wk.WGPURenderPassEncoder, reference: u32) void {
    d("wgpuRenderPassEncoderSetStencilReference")(pass(p), reference);
}

export fn wgpuRenderPassEncoderBeginOcclusionQuery(p: wk.WGPURenderPassEncoder, index: u32) void {
    d("wgpuRenderPassEncoderBeginOcclusionQuery")(pass(p), index);
}

export fn wgpuRenderPassEncoderEndOcclusionQuery(p: wk.WGPURenderPassEncoder) void {
    d("wgpuRenderPassEncoderEndOcclusionQuery")(pass(p));
}

export fn wgpuRenderPassEncoderExecuteBundles(p: wk.WGPURenderPassEncoder, count: usize, bundles: [*c]const wk.WGPURenderBundle) void {
    d("wgpuRenderPassEncoderExecuteBundles")(pass(p), count, @ptrCast(bundles));
}

export fn wgpuRenderPassEncoderEnd(p: wk.WGPURenderPassEncoder) void {
    d("wgpuRenderPassEncoderEnd")(pass(p));
}

export fn wgpuDeviceCreateRenderBundleEncoder(h: wk.WGPUDevice, desc: *const wk.WGPURenderBundleEncoderDescriptor) wk.WGPURenderBundleEncoder {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = c.WGPURenderBundleEncoderDescriptor{
        .nextInChain = null,
        .label = core.str(desc.label),
        .colorFormatCount = desc.colorFormatCount,
        .colorFormats = formats(arena.allocator(), desc.colorFormats, desc.colorFormatCount),
        .depthStencilFormat = conv.to("WGPUTextureFormat", desc.depthStencilFormat),
        .sampleCount = desc.sampleCount,
        .depthReadOnly = desc.depthReadOnly,
        .stencilReadOnly = desc.stencilReadOnly,
    };
    return @ptrCast(d("wgpuDeviceCreateRenderBundleEncoder")(dev(h), &out));
}

fn bundle(p: wk.WGPURenderBundleEncoder) c.WGPURenderBundleEncoder {
    return cast(c.WGPURenderBundleEncoder, p);
}

export fn wgpuRenderBundleEncoderSetPipeline(p: wk.WGPURenderBundleEncoder, pipeline: wk.WGPURenderPipeline) void {
    d("wgpuRenderBundleEncoderSetPipeline")(bundle(p), cast(c.WGPURenderPipeline, pipeline));
}

export fn wgpuRenderBundleEncoderSetBindGroup(p: wk.WGPURenderBundleEncoder, index: u32, group: wk.WGPUBindGroup, count: usize, list: [*c]const u32) void {
    d("wgpuRenderBundleEncoderSetBindGroup")(bundle(p), index, cast(c.WGPUBindGroup, group), count, list);
}

export fn wgpuRenderBundleEncoderSetBindGroupWithDynamicOffsets(p: wk.WGPURenderBundleEncoder, index: u32, group: wk.WGPUBindGroup, dynamic: ?*Offsets) void {
    const list = offsets(dynamic);
    d("wgpuRenderBundleEncoderSetBindGroup")(bundle(p), index, cast(c.WGPUBindGroup, group), list.len, if (list.len == 0) null else list.ptr);
}

export fn wgpuRenderBundleEncoderSetVertexBuffer(p: wk.WGPURenderBundleEncoder, slot: u32, b: wk.WGPUBuffer, offset: u64, size: u64) void {
    d("wgpuRenderBundleEncoderSetVertexBuffer")(bundle(p), slot, buf.raw(b), offset, size);
}

export fn wgpuRenderBundleEncoderSetIndexBuffer(p: wk.WGPURenderBundleEncoder, b: wk.WGPUBuffer, format: wk.WGPUIndexFormat, offset: u64, size: u64) void {
    d("wgpuRenderBundleEncoderSetIndexBuffer")(bundle(p), buf.raw(b), conv.to("WGPUIndexFormat", format), offset, size);
}

export fn wgpuRenderBundleEncoderDraw(p: wk.WGPURenderBundleEncoder, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
    d("wgpuRenderBundleEncoderDraw")(bundle(p), vertices, instances, first_vertex, first_instance);
}

export fn wgpuRenderBundleEncoderDrawIndexed(p: wk.WGPURenderBundleEncoder, indices: u32, instances: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    d("wgpuRenderBundleEncoderDrawIndexed")(bundle(p), indices, instances, first_index, base_vertex, first_instance);
}

export fn wgpuRenderBundleEncoderDrawIndirect(p: wk.WGPURenderBundleEncoder, b: wk.WGPUBuffer, offset: u64) void {
    d("wgpuRenderBundleEncoderDrawIndirect")(bundle(p), buf.raw(b), offset);
}

export fn wgpuRenderBundleEncoderDrawIndexedIndirect(p: wk.WGPURenderBundleEncoder, b: wk.WGPUBuffer, offset: u64) void {
    d("wgpuRenderBundleEncoderDrawIndexedIndirect")(bundle(p), buf.raw(b), offset);
}

export fn wgpuRenderBundleEncoderFinish(p: wk.WGPURenderBundleEncoder, desc: ?*const wk.WGPURenderBundleDescriptor) wk.WGPURenderBundle {
    const out = c.WGPURenderBundleDescriptor{ .nextInChain = null, .label = core.str(if (desc) |x| x.label else null) };
    return @ptrCast(d("wgpuRenderBundleEncoderFinish")(bundle(p), &out));
}

export fn wgpuQueueWriteTexture(q: wk.WGPUQueue, dst: *const wk.WGPUImageCopyTexture, data: wtf.Span(u8), layout: *const wk.WGPUTextureDataLayout, size: *const wk.WGPUExtent3D) void {
    const queue: *Queue = @ptrCast(@alignCast(q.?));
    const t = textureCopy(dst);
    const l = c.WGPUTexelCopyBufferLayout{ .offset = layout.offset, .bytesPerRow = layout.bytesPerRow, .rowsPerImage = layout.rowsPerImage };
    const x = extent(size);
    const s = data.slice();
    d("wgpuQueueWriteTexture")(queue.raw, &t, if (s.len == 0) null else s.ptr, s.len, &l, &x);
}

export fn wgpuDeviceImportExternalTexture(_: wk.WGPUDevice, _: ?*const anyopaque) wk.WGPUExternalTexture {
    return null;
}

export fn wgpuExternalTextureReference(_: wk.WGPUExternalTexture) void {}
export fn wgpuExternalTextureRelease(_: wk.WGPUExternalTexture) void {}
export fn wgpuExternalTextureIsValid(_: wk.WGPUExternalTexture) wk.WGPUBool {
    return 0;
}
export fn wgpuExternalTextureDestroy(_: wk.WGPUExternalTexture) void {}
export fn wgpuExternalTextureUndestroy(_: wk.WGPUExternalTexture) void {}
export fn wgpuExternalTextureUpdate(_: wk.WGPUExternalTexture, _: ?*anyopaque) void {}
