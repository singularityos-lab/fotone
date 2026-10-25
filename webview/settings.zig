const std = @import("std");
const c = @import("c.zig").c;

const watched = [_][*:0]const u8{
    "notify::gtk-font-name",
    "notify::gtk-application-prefer-dark-theme",
    "notify::gtk-interface-color-scheme",
    "notify::gtk-enable-animations",
    "notify::gtk-xft-antialias",
    "notify::gtk-xft-hintstyle",
    "notify::gtk-xft-rgba",
    "notify::gtk-xft-dpi",
    "notify::gtk-cursor-blink",
    "notify::gtk-cursor-blink-time",
    "notify::gtk-double-click-time",
    "notify::gtk-double-click-distance",
    "notify::gtk-dnd-drag-threshold",
    "notify::gtk-overlay-scrolling",
};

fn getInt(gs: *c.GtkSettings, name: [*:0]const u8) c_int {
    var v: c_int = 0;
    c.g_object_get(gs, name, &v, @as([*c]const u8, null));
    return v;
}

fn getBool(gs: *c.GtkSettings, name: [*:0]const u8) bool {
    return getInt(gs, name) != 0;
}

fn getString(gs: *c.GtkSettings, name: [*:0]const u8) [*c]u8 {
    var v: [*c]u8 = null;
    c.g_object_get(gs, name, &v, @as([*c]const u8, null));
    return v;
}

fn has(gs: *c.GtkSettings, name: [*:0]const u8) bool {
    return c.g_object_class_find_property(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(gs))).g_class)), name) != null;
}

pub fn hinting(style: ?[*:0]const u8) u8 {
    const s = std.mem.span(style orelse return c.WPE_SETTINGS_HINTING_STYLE_SLIGHT);
    if (std.mem.eql(u8, s, "hintnone")) return c.WPE_SETTINGS_HINTING_STYLE_NONE;
    if (std.mem.eql(u8, s, "hintmedium")) return c.WPE_SETTINGS_HINTING_STYLE_MEDIUM;
    if (std.mem.eql(u8, s, "hintfull")) return c.WPE_SETTINGS_HINTING_STYLE_FULL;
    return c.WPE_SETTINGS_HINTING_STYLE_SLIGHT;
}

pub fn subpixel(rgba: ?[*:0]const u8) u8 {
    const s = std.mem.span(rgba orelse return c.WPE_SETTINGS_SUBPIXEL_LAYOUT_NONE);
    if (std.mem.eql(u8, s, "rgb")) return c.WPE_SETTINGS_SUBPIXEL_LAYOUT_RGB;
    if (std.mem.eql(u8, s, "bgr")) return c.WPE_SETTINGS_SUBPIXEL_LAYOUT_BGR;
    if (std.mem.eql(u8, s, "vrgb")) return c.WPE_SETTINGS_SUBPIXEL_LAYOUT_VRGB;
    if (std.mem.eql(u8, s, "vbgr")) return c.WPE_SETTINGS_SUBPIXEL_LAYOUT_VBGR;
    return c.WPE_SETTINGS_SUBPIXEL_LAYOUT_NONE;
}

fn sync(gs: *c.GtkSettings, display: *c.WPEDisplay) void {
    const s = c.wpe_display_get_settings(display) orelse return;
    const src = c.WPE_SETTINGS_SOURCE_PLATFORM;
    const font = getString(gs, "gtk-font-name");
    defer c.g_free(font);
    if (font != null) _ = c.wpe_settings_set_string(s, c.WPE_SETTING_FONT_NAME, font, src, null);
    var dark = getBool(gs, "gtk-application-prefer-dark-theme");
    if (has(gs, "gtk-interface-color-scheme")) dark = dark or getInt(gs, "gtk-interface-color-scheme") == c.GTK_INTERFACE_COLOR_SCHEME_DARK;
    _ = c.wpe_settings_set_boolean(s, c.WPE_SETTING_DARK_MODE, @intFromBool(dark), src, null);
    _ = c.wpe_settings_set_boolean(s, c.WPE_SETTING_REDUCED_MOTION, @intFromBool(!getBool(gs, "gtk-enable-animations")), src, null);
    _ = c.wpe_settings_set_boolean(s, c.WPE_SETTING_FONT_ANTIALIAS, @intFromBool(getInt(gs, "gtk-xft-antialias") != 0), src, null);
    const hint = getString(gs, "gtk-xft-hintstyle");
    defer c.g_free(hint);
    _ = c.wpe_settings_set_byte(s, c.WPE_SETTING_FONT_HINTING_STYLE, hinting(hint), src, null);
    const rgba = getString(gs, "gtk-xft-rgba");
    defer c.g_free(rgba);
    _ = c.wpe_settings_set_byte(s, c.WPE_SETTING_FONT_SUBPIXEL_LAYOUT, subpixel(rgba), src, null);
    const dpi = getInt(gs, "gtk-xft-dpi");
    if (dpi > 0) _ = c.wpe_settings_set_double(s, c.WPE_SETTING_FONT_DPI, @as(f64, @floatFromInt(dpi)) / 1024.0, src, null);
    const blink: u32 = if (getBool(gs, "gtk-cursor-blink")) @intCast(@max(getInt(gs, "gtk-cursor-blink-time"), 0)) else 0;
    _ = c.wpe_settings_set_uint32(s, c.WPE_SETTING_CURSOR_BLINK_TIME, blink, src, null);
    _ = c.wpe_settings_set_uint32(s, c.WPE_SETTING_DOUBLE_CLICK_TIME, @intCast(@max(getInt(gs, "gtk-double-click-time"), 0)), src, null);
    _ = c.wpe_settings_set_uint32(s, c.WPE_SETTING_DOUBLE_CLICK_DISTANCE, @intCast(@max(getInt(gs, "gtk-double-click-distance"), 0)), src, null);
    _ = c.wpe_settings_set_uint32(s, c.WPE_SETTING_DRAG_THRESHOLD, @intCast(@max(getInt(gs, "gtk-dnd-drag-threshold"), 0)), src, null);
    _ = c.wpe_settings_set_boolean(s, c.WPE_SETTING_OVERLAY_SCROLLBARS, @intFromBool(getBool(gs, "gtk-overlay-scrolling")), src, null);
}

fn changed(gs: ?*c.GtkSettings, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    sync(gs.?, @ptrCast(@alignCast(data)));
}

pub fn follow(display: *c.WPEDisplay) void {
    const gs = c.gtk_settings_get_default() orelse return;
    _ = c.wpe_settings_set_boolean(c.wpe_display_get_settings(display), c.WPE_SETTING_CREATE_VIEWS_WITH_A_TOPLEVEL, 0, c.WPE_SETTINGS_SOURCE_PLATFORM, null);
    sync(gs, display);
    for (watched) |sig| {
        if (has(gs, std.mem.span(sig)["notify::".len..].ptr)) _ = c.g_signal_connect_data(gs, sig, @ptrCast(&changed), display, null, 0);
    }
}

test "xft names map onto WPE settings" {
    try std.testing.expectEqual(@as(u8, c.WPE_SETTINGS_HINTING_STYLE_FULL), hinting("hintfull"));
    try std.testing.expectEqual(@as(u8, c.WPE_SETTINGS_HINTING_STYLE_SLIGHT), hinting(null));
    try std.testing.expectEqual(@as(u8, c.WPE_SETTINGS_SUBPIXEL_LAYOUT_BGR), subpixel("bgr"));
    try std.testing.expectEqual(@as(u8, c.WPE_SETTINGS_SUBPIXEL_LAYOUT_NONE), subpixel("none"));
}
