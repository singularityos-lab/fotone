const std = @import("std");
const c = @import("c.zig").c;
const g = @import("gobject.zig");

pub const Toplevel = extern struct {
    parent: c.WPEToplevel,
};

const Class = extern struct {
    parent: c.WPEToplevelClass,
};

var once: g.Once = .{};

pub fn getType() c.GType {
    return once.get(make);
}

fn make() c.GType {
    return g.register(c.wpe_toplevel_get_type(), "FotoneToplevel", Class, Toplevel, classInit, null);
}

fn resize(_: [*c]c.WPEToplevel, _: c_int, _: c_int) callconv(.c) c.gboolean {
    return 0;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const tc: *c.WPEToplevelClass = @ptrCast(@alignCast(klass));
    tc.resize = resize;
}

const Size = struct { w: c_int, h: c_int };

fn resizeView(_: ?*c.WPEToplevel, v: ?*c.WPEView, data: c.gpointer) callconv(.c) c.gboolean {
    const s: *const Size = @ptrCast(@alignCast(data));
    c.wpe_view_resized(v, s.w, s.h);
    return 0;
}

pub export fn fotone_toplevel_get_type() c.GType {
    return getType();
}

pub export fn fotone_toplevel_configure(toplevel: [*c]c.WPEToplevel, width: c_int, height: c_int, scale: f64) void {
    c.wpe_toplevel_resized(toplevel, width, height);
    if (scale > 0 and scale != c.wpe_toplevel_get_scale(toplevel)) c.wpe_toplevel_scale_changed(toplevel, scale);
    var s: Size = .{ .w = width, .h = height };
    c.wpe_toplevel_foreach_view(toplevel, @ptrCast(&resizeView), &s);
}

test "configure records the size the widget allocates" {
    const d = @import("display.zig").fotone_display_new(null);
    defer c.g_object_unref(d);
    const t: [*c]c.WPEToplevel = @ptrCast(@alignCast(c.g_object_new(getType(), "display", d, @as(?*anyopaque, null))));
    defer c.g_object_unref(t);
    fotone_toplevel_configure(t, 800, 600, 1.25);
    var w: c_int = 0;
    var h: c_int = 0;
    c.wpe_toplevel_get_size(t, &w, &h);
    try std.testing.expectEqual(@as(c_int, 800), w);
    try std.testing.expectEqual(@as(c_int, 600), h);
    try std.testing.expectEqual(@as(f64, 1.25), c.wpe_toplevel_get_scale(t));
}
