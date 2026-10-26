const std = @import("std");
const sys = @import("sys.zig");

pub const c = @cImport({
    @cDefine("WGPU_SKIP_DECLARATIONS", "1");
    @cInclude("dawn/webgpu.h");
});

pub const LIBRARY = "libwebgpu_dawn.so";
pub const STRLEN = std.math.maxInt(usize);

var handle: ?*anyopaque = null;
var state = std.atomic.Value(u8).init(0);
var lock: sys.Lock = .{};

pub fn available() bool {
    switch (state.load(.acquire)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    lock.lock();
    defer lock.unlock();
    if (state.load(.acquire) == 0) {
        handle = std.c.dlopen(LIBRARY, .{ .NOW = true, .DEEPBIND = true });
        state.store(if (handle != null) 1 else 2, .release);
    }
    return handle != null;
}

pub fn Proc(comptime name: []const u8) type {
    return @typeInfo(@field(c, "WGPUProc" ++ name[4..])).optional.child;
}

pub fn proc(comptime name: []const u8) Proc(name) {
    const S = struct {
        const symbol = name;
        var p = std.atomic.Value(?*const anyopaque).init(null);
    };
    if (S.p.load(.acquire)) |p| return @ptrCast(@alignCast(p));
    const p = std.c.dlsym(handle, @ptrCast((name ++ "\x00").ptr)) orelse std.debug.panic("dawn has no {s}", .{name});
    S.p.store(p, .release);
    return @ptrCast(@alignCast(p));
}

pub fn str(s: ?[*:0]const u8) c.WGPUStringView {
    return .{ .data = s, .length = STRLEN };
}

pub fn slice(v: c.WGPUStringView) []const u8 {
    const d = v.data orelse return "";
    if (v.length == STRLEN) return std.mem.span(@as([*:0]const u8, @ptrCast(d)));
    return d[0..v.length];
}
