const std = @import("std");
const c = @import("c.zig").c;
const g = @import("gobject.zig");
const view = @import("view.zig");
const toplevel = @import("toplevel.zig");

pub const Display = extern struct {
    parent: c.WPEDisplay,
    node: [*c]u8,
    drm: ?*c.WPEDRMDevice,
    gbm: ?*c.struct_gbm_device,
    fd: c_int,
    formats: [*c]c.GArray,
};

const Class = extern struct {
    parent: c.WPEDisplayClass,
};

const Format = extern struct {
    fourcc: u32,
    modifier: u64,
};

var parent_class: ?*c.GObjectClass = null;
var once: g.Once = .{};

pub fn getType() c.GType {
    return once.get(make);
}

fn make() c.GType {
    return g.register(c.wpe_display_get_type(), "FotoneDisplay", Class, Display, classInit, instanceInit);
}

fn of(p: anytype) *Display {
    return @ptrCast(@alignCast(p));
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d = of(inst);
    d.fd = -1;
    d.formats = c.g_array_new(0, 0, @sizeOf(Format));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = of(o);
    if (d.gbm) |m| c.gbm_device_destroy(m);
    if (d.fd >= 0) _ = c.close(d.fd);
    if (d.drm) |m| c.wpe_drm_device_unref(m);
    c.g_free(d.node);
    _ = c.g_array_free(d.formats, 1);
    parent_class.?.finalize.?(o);
}

fn findDevice(d: *Display) void {
    var devs: [64]c.drmDevicePtr = undefined;
    const n = c.drmGetDevices2(0, &devs, devs.len);
    if (n <= 0) return;
    defer c.drmFreeDevices(&devs, n);
    for (devs[0..@intCast(n)]) |dev| {
        const nodes = dev.*.available_nodes;
        if (nodes & (1 << c.DRM_NODE_RENDER) == 0) continue;
        const render = dev.*.nodes[c.DRM_NODE_RENDER];
        if (d.node != null and c.g_strcmp0(d.node, render) != 0) continue;
        const primary: [*c]const u8 = if (nodes & (1 << c.DRM_NODE_PRIMARY) != 0) dev.*.nodes[c.DRM_NODE_PRIMARY] else null;
        d.drm = c.wpe_drm_device_new(primary, render);
        if (d.node == null) d.node = c.g_strdup(render);
        return;
    }
}

fn connect(display: [*c]c.WPEDisplay, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const d = of(display);
    if (d.drm == null) findDevice(d);
    return 1;
}

fn createView(display: [*c]c.WPEDisplay) callconv(.c) [*c]c.WPEView {
    return @ptrCast(@alignCast(c.g_object_new(view.getType(), "display", display, @as(?*anyopaque, null))));
}

fn createToplevel(display: [*c]c.WPEDisplay, _: c.guint) callconv(.c) [*c]c.WPEToplevel {
    return @ptrCast(@alignCast(c.g_object_new(toplevel.getType(), "display", display, @as(?*anyopaque, null))));
}

fn gbmDisplay(d: *Display) c.gpointer {
    if (d.node == null or !c.epoxy_has_egl_extension(null, "EGL_KHR_platform_gbm")) return null;
    if (d.gbm == null) {
        const fd = c.open(d.node, c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) return null;
        const m = c.gbm_create_device(fd) orelse {
            _ = c.close(fd);
            return null;
        };
        d.fd = fd;
        d.gbm = m;
    }
    return c.eglGetPlatformDisplayEXT(c.EGL_PLATFORM_GBM_KHR, d.gbm, null);
}

fn getEglDisplay(display: [*c]c.WPEDisplay, err: [*c][*c]c.GError) callconv(.c) c.gpointer {
    const d = of(display);
    if (gbmDisplay(d)) |e| return e;
    if (c.epoxy_has_egl_extension(null, "EGL_MESA_platform_surfaceless")) {
        if (c.eglGetPlatformDisplayEXT(c.EGL_PLATFORM_SURFACELESS_MESA, null, null)) |e| return e;
    }
    c.g_set_error_literal(err, c.wpe_egl_error_quark(), c.WPE_EGL_ERROR_NOT_AVAILABLE, "no EGL display for the Sinty platform");
    return null;
}

fn getDrmDevice(display: [*c]c.WPEDisplay) callconv(.c) ?*c.WPEDRMDevice {
    return of(display).drm;
}

fn getPreferredFormats(display: [*c]c.WPEDisplay) callconv(.c) ?*c.WPEBufferFormats {
    const d = of(display);
    if (d.formats.*.len == 0) return null;
    const b = c.wpe_buffer_formats_builder_new(d.drm);
    defer c.wpe_buffer_formats_builder_unref(b);
    c.wpe_buffer_formats_builder_append_group(b, d.drm, c.WPE_BUFFER_FORMAT_USAGE_RENDERING);
    const list: [*]Format = @ptrCast(@alignCast(d.formats.*.data));
    for (list[0..d.formats.*.len]) |f| c.wpe_buffer_formats_builder_append_format(b, f.fourcc, f.modifier);
    return c.wpe_buffer_formats_builder_end(b);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    g.objectClass(klass).finalize = finalize;
    const dc: *c.WPEDisplayClass = @ptrCast(@alignCast(klass));
    dc.connect = connect;
    dc.create_view = createView;
    dc.create_toplevel = createToplevel;
    dc.get_egl_display = getEglDisplay;
    dc.get_drm_device = getDrmDevice;
    dc.get_preferred_buffer_formats = getPreferredFormats;
}

pub export fn fotone_display_get_type() c.GType {
    return getType();
}

pub export fn fotone_display_new(render_node: [*c]const u8) [*c]c.WPEDisplay {
    const o: *Display = @ptrCast(@alignCast(c.g_object_new(getType(), null)));
    o.node = c.g_strdup(render_node);
    return &o.parent;
}

pub export fn fotone_display_add_format(display: [*c]c.WPEDisplay, fourcc: u32, modifier: u64) void {
    const f: Format = .{ .fourcc = fourcc, .modifier = modifier };
    _ = c.g_array_append_vals(of(display).formats, &f, 1);
}

pub export fn fotone_display_get_render_node(display: [*c]c.WPEDisplay) [*c]const u8 {
    return of(display).node;
}

test "display keeps the formats the host offers" {
    const d = fotone_display_new(null);
    defer c.g_object_unref(d);
    fotone_display_add_format(d, 0x34325258, 0);
    fotone_display_add_format(d, 0x34325241, 0x00ffffffffffffff);
    try std.testing.expectEqual(@as(c.guint, 2), of(d).formats.*.len);
}
