const std = @import("std");
const c = @import("c.zig").c;

const LIB = "libWPEWebKit-2.0.so.1";
const VERSION = "FOTONE_2.0";

var handle: ?*anyopaque = null;

fn lib() ?*anyopaque {
    if (handle == null) handle = c.dlopen(LIB, c.RTLD_NOW | c.RTLD_NOLOAD);
    return handle;
}

pub fn lookup(comptime name: [:0]const u8, comptime F: type) *const F {
    const S = struct {
        const symbol = name;
        var ptr: ?*const F = null;
    };
    if (S.ptr) |p| return p;
    const sym = c.dlvsym(lib(), S.symbol, VERSION) orelse std.debug.panic("fotone engine has no {s}", .{name});
    S.ptr = @ptrCast(@alignCast(sym));
    return S.ptr.?;
}

pub fn viewType() c.GType {
    return lookup("webkit_web_view_get_type", fn () callconv(.c) c.GType)();
}

test "lookups with the same signature keep their own symbol" {
    const F = fn () callconv(.c) c.GType;
    const view = lookup("webkit_web_view_get_type", F);
    const settings = lookup("webkit_settings_get_type", F);
    try std.testing.expect(view != settings);
    try std.testing.expectEqualStrings("FotoneWebKitWebView", std.mem.span(c.g_type_name(view())));
    try std.testing.expectEqualStrings("WebKitSettings", std.mem.span(c.g_type_name(settings())));
}
