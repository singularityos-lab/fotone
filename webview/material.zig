const std = @import("std");
const c = @import("c.zig").c;

pub const Mode = enum(u32) { none = 0, glass = 1, blur = 2, liquid = 3 };

pub const query = "(document.querySelector('meta[name=\"sinty-material\"]') || {}).content || ''";
const STRENGTH = 60;
const LIBRARY = "libsingularity.so.0";

pub fn parse(s: []const u8) Mode {
    const t = std.mem.trim(u8, s, " \t");
    inline for (.{ Mode.glass, Mode.blur, Mode.liquid }) |m| {
        if (std.ascii.eqlIgnoreCase(t, @tagName(m))) return m;
    }
    return .none;
}

const Frame = *const fn (?*c.GtkWidget, ?*c.GtkWidget, u32, u32) callconv(.c) c.gboolean;

var frame_fn: ?Frame = null;
var looked = false;
var styled = false;

fn style(win: *c.GtkWidget) void {
    if (styled) return;
    styled = true;
    const p = c.gtk_css_provider_new();
    defer c.g_object_unref(p);
    c.gtk_css_provider_load_from_string(p, "window.fotone-material { background: none; }");
    c.gtk_style_context_add_provider_for_display(c.gtk_widget_get_display(win), @ptrCast(p), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

fn frame() ?Frame {
    if (looked) return frame_fn;
    looked = true;
    const h = std.c.dlopen(LIBRARY, .{ .LAZY = true }) orelse return null;
    frame_fn = @ptrCast(std.c.dlsym(h, "singularity_surface_effect_set_frame") orelse return null);
    return frame_fn;
}

pub fn apply(view: *c.GtkWidget, mode: Mode) bool {
    if (mode == .none) return false;
    const f = frame() orelse return false;
    const root = c.gtk_widget_get_root(view) orelse return false;
    const win: *c.GtkWidget = @ptrCast(@alignCast(root));
    if (f(win, view, @intFromEnum(mode), STRENGTH) == 0) return false;
    style(win);
    c.gtk_widget_add_css_class(win, "fotone-material");
    return true;
}

test "pages name a window material" {
    try std.testing.expectEqual(Mode.liquid, parse("liquid"));
    try std.testing.expectEqual(Mode.glass, parse(" Glass "));
    try std.testing.expectEqual(Mode.none, parse("metal"));
    try std.testing.expectEqual(Mode.none, parse(""));
}
