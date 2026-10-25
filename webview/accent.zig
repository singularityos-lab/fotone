const std = @import("std");
const c = @import("c.zig").c;

const portal = "org.freedesktop.portal.Desktop";
const path = "/org/freedesktop/portal/desktop";
const iface = "org.freedesktop.portal.Settings";
const namespace = "org.freedesktop.appearance";
const key = "accent-color";

fn variantType(comptime t: [:0]const u8) *const c.GVariantType {
    return @ptrCast(t.ptr);
}

pub fn hex(r: f64, g: f64, b: f64, out: *[8]u8) ?[:0]const u8 {
    if (r < 0 or r > 1 or g < 0 or g > 1 or b < 0 or b > 1) return null;
    const ch = [3]u8{ @intFromFloat(@round(r * 255)), @intFromFloat(@round(g * 255)), @intFromFloat(@round(b * 255)) };
    return std.fmt.bufPrintZ(out, "#{x:0>2}{x:0>2}{x:0>2}", .{ ch[0], ch[1], ch[2] }) catch null;
}

fn apply(display: *c.WPEDisplay, value: ?*c.GVariant) void {
    var v = c.g_variant_ref(value orelse return);
    defer c.g_variant_unref(v);
    while (c.g_variant_is_of_type(v, variantType("v")) != 0) {
        const inner = c.g_variant_get_variant(v);
        c.g_variant_unref(v);
        v = inner;
    }
    if (c.g_variant_is_of_type(v, variantType("(ddd)")) == 0) return;
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    c.g_variant_get(v, "(ddd)", &r, &g, &b);
    var buf: [8]u8 = undefined;
    const s = hex(r, g, b, &buf) orelse "";
    _ = c.wpe_settings_set_string(c.wpe_display_get_settings(display), c.WPE_SETTING_ACCENT_COLOR, s.ptr, c.WPE_SETTINGS_SOURCE_PLATFORM, null);
}

fn changed(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    var ns: [*c]const u8 = null;
    var k: [*c]const u8 = null;
    var v: ?*c.GVariant = null;
    c.g_variant_get(params, "(&s&sv)", &ns, &k, &v);
    defer if (v) |x| c.g_variant_unref(x);
    if (c.g_strcmp0(ns, namespace) != 0 or c.g_strcmp0(k, key) != 0) return;
    apply(@ptrCast(@alignCast(data)), v);
}

pub fn follow(display: *c.WPEDisplay) void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    const reply = c.g_dbus_connection_call_sync(bus, portal, path, iface, "ReadOne", c.g_variant_new("(ss)", namespace, key), null, c.G_DBUS_CALL_FLAGS_NONE, 2000, null, null);
    if (reply) |r| {
        var v: ?*c.GVariant = null;
        c.g_variant_get(r, "(v)", &v);
        apply(display, v);
        if (v) |x| c.g_variant_unref(x);
        c.g_variant_unref(r);
    }
    _ = c.g_dbus_connection_signal_subscribe(bus, portal, iface, "SettingChanged", path, null, c.G_DBUS_SIGNAL_FLAGS_NONE, changed, display, null);
}

test "portal rgb becomes a hex accent" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("#3584e4", hex(0.2078, 0.5176, 0.8941, &buf).?);
    try std.testing.expect(hex(-1, 0, 0, &buf) == null);
}
