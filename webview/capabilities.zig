const std = @import("std");
const c = @import("c.zig").c;

pub const TRANSLATE = "dev.sinty.Translate1";

pub const Provider = struct {
    bus: [*c]u8,
    path: [*c]u8,

    pub fn free(p: Provider) void {
        c.g_free(p.bus);
        c.g_free(p.path);
    }
};

fn fromFile(path: [*c]const u8, iface: [*:0]const u8) ?Provider {
    const kf = c.g_key_file_new();
    defer c.g_key_file_unref(kf);
    if (c.g_key_file_load_from_file(kf, path, c.G_KEY_FILE_NONE, null) == 0) return null;
    const i = c.g_key_file_get_string(kf, "Capability", "Interface", null);
    defer c.g_free(i);
    if (c.g_strcmp0(i, iface) != 0) return null;
    const bus = c.g_key_file_get_string(kf, "Capability", "BusName", null);
    const obj = c.g_key_file_get_string(kf, "Capability", "ObjectPath", null);
    if (bus == null or obj == null or c.g_dbus_is_name(bus) == 0 or c.g_variant_is_object_path(obj) == 0) {
        c.g_free(bus);
        c.g_free(obj);
        return null;
    }
    return .{ .bus = bus, .path = obj };
}

fn inDir(base: [*c]const u8, iface: [*:0]const u8) ?Provider {
    const dir = c.g_build_filename(base, "singularity", "capabilities", @as([*c]const u8, null));
    defer c.g_free(dir);
    const d = c.g_dir_open(dir, 0, null) orelse return null;
    defer c.g_dir_close(d);
    while (c.g_dir_read_name(d)) |name| {
        if (c.g_str_has_suffix(name, ".ini") == 0) continue;
        const path = c.g_build_filename(dir, name, @as([*c]const u8, null));
        defer c.g_free(path);
        if (fromFile(path, iface)) |p| return p;
    }
    return null;
}

pub fn find(iface: [*:0]const u8) ?Provider {
    if (inDir(c.g_get_user_data_dir(), iface)) |p| return p;
    const dirs = c.g_get_system_data_dirs();
    var i: usize = 0;
    while (dirs[i] != null) : (i += 1) if (inDir(dirs[i], iface)) |p| return p;
    return null;
}

fn called(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    if (c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, null)) |v| c.g_variant_unref(v);
}

pub fn call(iface: [*:0]const u8, method: [*:0]const u8, params: ?*c.GVariant) void {
    const p = find(iface) orelse {
        if (params) |v| c.g_variant_unref(c.g_variant_ref_sink(v));
        return;
    };
    defer p.free();
    const conn = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    defer c.g_object_unref(conn);
    c.g_dbus_connection_call(conn, p.bus, p.path, iface, method, params, null, c.G_DBUS_CALL_FLAGS_NONE, 30000, null, called, null);
}
