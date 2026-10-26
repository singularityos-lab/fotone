const std = @import("std");
const wk = @import("wk.zig").c;

const Entry = struct { feature: wk.WGPUFeatureName, name: []const u8 };

const NAMES = [_]Entry{
    .{ .feature = wk.WGPUFeatureName_DepthClipControl, .name = "depth-clip-control" },
    .{ .feature = wk.WGPUFeatureName_Depth32FloatStencil8, .name = "depth32float-stencil8" },
    .{ .feature = wk.WGPUFeatureName_TimestampQuery, .name = "timestamp-query" },
    .{ .feature = wk.WGPUFeatureName_TextureCompressionBC, .name = "texture-compression-bc" },
    .{ .feature = wk.WGPUFeatureName_TextureCompressionBCSliced3D, .name = "texture-compression-bc-sliced-3d" },
    .{ .feature = wk.WGPUFeatureName_TextureCompressionETC2, .name = "texture-compression-etc2" },
    .{ .feature = wk.WGPUFeatureName_TextureCompressionASTC, .name = "texture-compression-astc" },
    .{ .feature = wk.WGPUFeatureName_TextureCompressionASTCSliced3D, .name = "texture-compression-astc-sliced-3d" },
    .{ .feature = wk.WGPUFeatureName_IndirectFirstInstance, .name = "indirect-first-instance" },
    .{ .feature = wk.WGPUFeatureName_ShaderF16, .name = "shader-f16" },
    .{ .feature = wk.WGPUFeatureName_RG11B10UfloatRenderable, .name = "rg11b10ufloat-renderable" },
    .{ .feature = wk.WGPUFeatureName_BGRA8UnormStorage, .name = "bgra8unorm-storage" },
    .{ .feature = wk.WGPUFeatureName_Float32Filterable, .name = "float32-filterable" },
    .{ .feature = wk.WGPUFeatureName_Float32Blendable, .name = "float32-blendable" },
    .{ .feature = wk.WGPUFeatureName_ClipDistances, .name = "clip-distances" },
    .{ .feature = wk.WGPUFeatureName_DualSourceBlending, .name = "dual-source-blending" },
    .{ .feature = wk.WGPUFeatureName_PrimitiveIndex, .name = "primitive-index" },
    .{ .feature = wk.WGPUFeatureName_Float16Renderable, .name = "float16-renderable" },
    .{ .feature = wk.WGPUFeatureName_Float32Renderable, .name = "float32-renderable" },
    .{ .feature = wk.WGPUFeatureName_CoreFeaturesAndLimits, .name = "core-features-and-limits" },
    .{ .feature = wk.WGPUFeatureName_TextureFormatsTier1, .name = "texture-formats-tier1" },
    .{ .feature = wk.WGPUFeatureName_TextureFormatsTier2, .name = "texture-formats-tier2" },
    .{ .feature = wk.WGPUFeatureName_Subgroups, .name = "subgroups" },
};

pub fn name(f: wk.WGPUFeatureName) []const u8 {
    for (NAMES) |e| if (e.feature == f) return e.name;
    return "";
}

pub fn defaults() wk.WGPULimits {
    return .{
        .maxTextureDimension1D = 8192,
        .maxTextureDimension2D = 8192,
        .maxTextureDimension3D = 2048,
        .maxTextureArrayLayers = 256,
        .maxBindGroups = 4,
        .maxBindGroupsPlusVertexBuffers = 24,
        .maxBindingsPerBindGroup = 1000,
        .maxDynamicUniformBuffersPerPipelineLayout = 8,
        .maxDynamicStorageBuffersPerPipelineLayout = 4,
        .maxSampledTexturesPerShaderStage = 16,
        .maxSamplersPerShaderStage = 16,
        .maxStorageBuffersPerShaderStage = 8,
        .maxStorageTexturesPerShaderStage = 4,
        .maxUniformBuffersPerShaderStage = 12,
        .maxUniformBufferBindingSize = 65536,
        .maxStorageBufferBindingSize = 134217728,
        .minUniformBufferOffsetAlignment = 256,
        .minStorageBufferOffsetAlignment = 256,
        .maxVertexBuffers = 8,
        .maxBufferSize = 268435456,
        .maxVertexAttributes = 16,
        .maxVertexBufferArrayStride = 2048,
        .maxInterStageShaderVariables = 16,
        .maxColorAttachments = 8,
        .maxColorAttachmentBytesPerSample = 32,
        .maxComputeWorkgroupStorageSize = 16384,
        .maxComputeInvocationsPerWorkgroup = 256,
        .maxComputeWorkgroupSizeX = 256,
        .maxComputeWorkgroupSizeY = 256,
        .maxComputeWorkgroupSizeZ = 64,
        .maxComputeWorkgroupsPerDimension = 65535,
        .maxStorageBuffersInFragmentStage = 8,
        .maxStorageTexturesInFragmentStage = 4,
        .maxStorageBuffersInVertexStage = 8,
        .maxStorageTexturesInVertexStage = 4,
    };
}

test "feature names follow the specification spelling" {
    try std.testing.expectEqualStrings("texture-compression-bc-sliced-3d", name(wk.WGPUFeatureName_TextureCompressionBCSliced3D));
    try std.testing.expectEqualStrings("", name(wk.WGPUFeatureName_Undefined));
}
