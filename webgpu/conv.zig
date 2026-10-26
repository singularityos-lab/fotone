const std = @import("std");
const wk = @import("wk.zig").c;
const c = @import("dawn.zig").c;

fn Pair(comptime T: type) type {
    return struct { from: u32, to: T };
}

fn table(comptime src: type, comptime dst: type, comptime prefix: []const u8, comptime T: type) []const Pair(T) {
    @setEvalBranchQuota(2000000);
    comptime var out: []const Pair(T) = &.{};
    inline for (@typeInfo(src).@"struct".decls) |d| {
        if (comptime std.mem.startsWith(u8, d.name, prefix ++ "_") and !std.mem.endsWith(u8, d.name, "_Force32") and @hasDecl(dst, d.name)) {
            const a = @field(src, d.name);
            const b = @field(dst, d.name);
            if (@TypeOf(a) != type and @TypeOf(b) != type) out = out ++ .{Pair(T){ .from = @intCast(a), .to = @intCast(b) }};
        }
    }
    return out;
}

pub fn Dawn(comptime name: []const u8) type {
    return @field(c, name);
}

pub fn to(comptime name: []const u8, v: anytype) Dawn(name) {
    const t = comptime table(wk, c, name, Dawn(name));
    const x: u32 = @intCast(v);
    inline for (t) |p| {
        if (p.from == x) return p.to;
    }
    return 0;
}

pub fn from(comptime name: []const u8, v: anytype) @field(wk, name) {
    const t = comptime table(c, wk, name, @field(wk, name));
    const x: u32 = @intCast(v);
    inline for (t) |p| {
        if (p.from == x) return p.to;
    }
    return 0;
}

pub fn binding(comptime name: []const u8, v: anytype) Dawn(name) {
    if (v == 0) return @field(c, name ++ "_BindingNotUsed");
    return to(name, v);
}

pub fn optionalBool(o: anytype) c.WGPUOptionalBool {
    if (!o.engaged) return c.WGPUOptionalBool_Undefined;
    return if (o.value != 0) c.WGPUOptionalBool_True else c.WGPUOptionalBool_False;
}

pub fn limits(l: *const wk.WGPULimits) c.WGPULimits {
    var out = std.mem.zeroes(c.WGPULimits);
    inline for (@typeInfo(c.WGPULimits).@"struct".fields) |f| {
        if (comptime @typeInfo(f.type) != .int) continue;
        @field(out, f.name) = if (comptime @hasField(wk.WGPULimits, f.name)) @field(l, f.name) else std.math.maxInt(f.type);
    }
    return out;
}

pub fn limitsBack(l: *const c.WGPULimits) wk.WGPULimits {
    var out = std.mem.zeroes(wk.WGPULimits);
    inline for (@typeInfo(wk.WGPULimits).@"struct".fields) |f| {
        if (comptime @hasField(c.WGPULimits, f.name)) @field(out, f.name) = @field(l, f.name);
    }
    out.maxStorageBuffersInFragmentStage = l.maxStorageBuffersPerShaderStage;
    out.maxStorageTexturesInFragmentStage = l.maxStorageTexturesPerShaderStage;
    out.maxStorageBuffersInVertexStage = l.maxStorageBuffersPerShaderStage;
    out.maxStorageTexturesInVertexStage = l.maxStorageTexturesPerShaderStage;
    return out;
}

test "enums follow their names across numbering schemes" {
    try std.testing.expectEqual(@as(c.WGPUTextureFormat, c.WGPUTextureFormat_RGBA8Unorm), to("WGPUTextureFormat", wk.WGPUTextureFormat_RGBA8Unorm));
    try std.testing.expectEqual(@as(c.WGPULoadOp, c.WGPULoadOp_Clear), to("WGPULoadOp", wk.WGPULoadOp_Clear));
    try std.testing.expectEqual(@as(c.WGPUCompareFunction, c.WGPUCompareFunction_Greater), to("WGPUCompareFunction", wk.WGPUCompareFunction_Greater));
    try std.testing.expectEqual(@as(c.WGPUBufferBindingType, c.WGPUBufferBindingType_BindingNotUsed), binding("WGPUBufferBindingType", wk.WGPUBufferBindingType_Undefined));
    try std.testing.expectEqual(@as(c.WGPUBufferBindingType, c.WGPUBufferBindingType_Storage), binding("WGPUBufferBindingType", wk.WGPUBufferBindingType_Storage));
    try std.testing.expectEqual(@as(wk.WGPUFeatureName, wk.WGPUFeatureName_Depth32FloatStencil8), from("WGPUFeatureName", c.WGPUFeatureName_Depth32FloatStencil8));
}
