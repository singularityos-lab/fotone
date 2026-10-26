const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("engine.h");
});

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

pub const GType = c.GType;

pub fn viewType() c.GType {
    return lookup("webkit_web_view_get_type", fn () callconv(.c) c.GType)();
}

pub fn Async(comptime C: type) type {
    return struct {
        cb: C.GAsyncReadyCallback,
        data: C.gpointer,
        view: ?*anyopaque,

        const Self = @This();

        pub fn wrap(cb: C.GAsyncReadyCallback, data: C.gpointer, view: ?*anyopaque) *Self {
            const a: *Self = @ptrCast(@alignCast(C.g_malloc0(@sizeOf(Self))));
            a.* = .{ .cb = cb, .data = data, .view = if (view) |p| C.g_object_ref(p) else null };
            return a;
        }

        pub fn done(_: [*c]C.GObject, res: ?*C.GAsyncResult, d: C.gpointer) callconv(.c) void {
            const a: *Self = @ptrCast(@alignCast(d));
            defer C.g_free(a);
            defer if (a.view) |p| C.g_object_unref(p);
            if (a.cb) |cb| cb(@ptrCast(@alignCast(a.view)), res, a.data);
        }
    };
}

pub fn Wrap(comptime C: type, comptime H: type, comptime name: [:0]const u8) type {
    const F = @TypeOf(@field(C, name));
    const isViewPtr = struct {
        fn f(comptime T: type) bool {
            return T == [*c]C.WebKitWebView or T == ?*C.WebKitWebView or T == *C.WebKitWebView;
        }
    }.f;
    const info = @typeInfo(F).@"fn";
    const P = info.params;
    const R = info.return_type.?;
    return struct {
        fn T(comptime i: usize) type {
            return P[i].type.?;
        }

        fn call(args: std.meta.ArgsTuple(F)) R {
            var a = args;
            inline for (P, 0..) |p, i| {
                if (comptime p.type.? == C.GAsyncReadyCallback and i + 1 < P.len) {
                    if (a[i] != null) {
                        a[i + 1] = Async(C).wrap(a[i], a[i + 1], if (P.len > 0 and comptime isViewPtr(P[0].type.?)) @ptrCast(a[0]) else null);
                        a[i] = Async(C).done;
                    }
                } else if (comptime isViewPtr(p.type.?)) {
                    a[i] = @ptrCast(@alignCast(H.toEngine(@ptrCast(a[i]))));
                }
            }
            const r = @call(.auto, lookup(name, F), a);
            if (comptime isViewPtr(R)) return @ptrCast(@alignCast(H.toProxy(@ptrCast(r))));
            return r;
        }

        fn f0() callconv(.c) R {
            return call(.{});
        }
        fn f1(a0: T(0)) callconv(.c) R {
            return call(.{a0});
        }
        fn f2(a0: T(0), a1: T(1)) callconv(.c) R {
            return call(.{ a0, a1 });
        }
        fn f3(a0: T(0), a1: T(1), a2: T(2)) callconv(.c) R {
            return call(.{ a0, a1, a2 });
        }
        fn f4(a0: T(0), a1: T(1), a2: T(2), a3: T(3)) callconv(.c) R {
            return call(.{ a0, a1, a2, a3 });
        }
        fn f5(a0: T(0), a1: T(1), a2: T(2), a3: T(3), a4: T(4)) callconv(.c) R {
            return call(.{ a0, a1, a2, a3, a4 });
        }
        fn f6(a0: T(0), a1: T(1), a2: T(2), a3: T(3), a4: T(4), a5: T(5)) callconv(.c) R {
            return call(.{ a0, a1, a2, a3, a4, a5 });
        }
        fn f7(a0: T(0), a1: T(1), a2: T(2), a3: T(3), a4: T(4), a5: T(5), a6: T(6)) callconv(.c) R {
            return call(.{ a0, a1, a2, a3, a4, a5, a6 });
        }
        fn f8(a0: T(0), a1: T(1), a2: T(2), a3: T(3), a4: T(4), a5: T(5), a6: T(6), a7: T(7)) callconv(.c) R {
            return call(.{ a0, a1, a2, a3, a4, a5, a6, a7 });
        }
        fn f9(a0: T(0), a1: T(1), a2: T(2), a3: T(3), a4: T(4), a5: T(5), a6: T(6), a7: T(7), a8: T(8)) callconv(.c) R {
            return call(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8 });
        }

        pub fn exportIt() void {
            const opts: std.builtin.ExportOptions = .{ .name = name };
            switch (P.len) {
                0 => @export(&f0, opts),
                1 => @export(&f1, opts),
                2 => @export(&f2, opts),
                3 => @export(&f3, opts),
                4 => @export(&f4, opts),
                5 => @export(&f5, opts),
                6 => @export(&f6, opts),
                7 => @export(&f7, opts),
                8 => @export(&f8, opts),
                9 => @export(&f9, opts),
                else => @compileError(name ++ " has too many parameters"),
            }
        }
    };
}


test "lookups with the same signature keep their own symbol" {
    const F = fn () callconv(.c) c.GType;
    const view = lookup("webkit_web_view_get_type", F);
    const settings = lookup("webkit_settings_get_type", F);
    try std.testing.expect(view != settings);
    try std.testing.expectEqualStrings("FotoneWebKitWebView", std.mem.span(c.g_type_name(view())));
    try std.testing.expectEqualStrings("WebKitSettings", std.mem.span(c.g_type_name(settings())));
}
