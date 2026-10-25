const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("viewer.h");
});

var uri: [*:0]const u8 = "https://sinty.dev";
var shot: ?[*:0]const u8 = null;
var window: ?*c.GtkWidget = null;
var app_id: ?[*:0]const u8 = null;
var rules: ?[*:0]const u8 = null;
var view: ?*c.SitWebView = null;

fn capture(_: c.gpointer) callconv(.c) c.gboolean {
    const win = window orelse return 0;
    const frame = if (view) |v| c.sit_web_view_get_frame(v) else null;
    if (frame == null or c.gdk_texture_save_to_png(frame, shot.?) == 0) std.log.warn("fotone-viewer: nothing to capture", .{});
    c.gtk_window_destroy(@ptrCast(win));
    return 0;
}

fn loaded(_: ?*c.WebKitWebView, event: c.WebKitLoadEvent, _: c.gpointer) callconv(.c) void {
    if (event == c.WEBKIT_LOAD_FINISHED and shot != null) _ = c.g_timeout_add(1500, capture, null);
}

fn compiled(ok: c.gboolean, err: [*c]const c.GError, _: c.gpointer) callconv(.c) void {
    if (ok == 0 and err != null) std.log.warn("fotone-viewer: rules not compiled: {s}", .{err.*.message});
    c.sit_web_view_load_uri(view, uri);
}

fn applyRules(path: [*:0]const u8) bool {
    var text: [*c]u8 = null;
    var err: [*c]c.GError = null;
    if (c.g_file_get_contents(path, &text, null, &err) == 0) {
        std.log.warn("fotone-viewer: {s}", .{err.*.message});
        c.g_error_free(err);
        return false;
    }
    defer c.g_free(text);
    if (c.sit_web_view_install_rule_set("fotone-viewer", text, compiled, null, &err) == 0) {
        std.log.warn("fotone-viewer: {s}", .{err.*.message});
        c.g_error_free(err);
        return false;
    }
    return true;
}

fn activate(app: ?*c.GtkApplication, _: c.gpointer) callconv(.c) void {
    const win = c.gtk_application_window_new(app);
    window = win;
    c.gtk_window_set_default_size(@ptrCast(win), 1024, 720);
    const child = if (app_id) |id| c.sit_web_view_new_for_web_app(id) else c.sit_web_view_new();
    view = @ptrCast(@alignCast(child));
    _ = c.g_object_bind_property(c.sit_web_view_get_web_view(view), "title", win, "title", c.G_BINDING_SYNC_CREATE);
    c.gtk_window_set_child(@ptrCast(win), child);
    _ = c.g_signal_connect_data(c.sit_web_view_get_web_view(view), "load-changed", @ptrCast(&loaded), null, null, 0);
    if (rules == null or !applyRules(rules.?)) c.sit_web_view_load_uri(view, uri);
    c.gtk_window_present(@ptrCast(win));
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--screenshot") and i + 1 < args.len) {
            shot = try arena.dupeZ(u8, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--app") and i + 1 < args.len) {
            app_id = try arena.dupeZ(u8, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--rules") and i + 1 < args.len) {
            rules = try arena.dupeZ(u8, args[i + 1]);
            i += 1;
        } else uri = try arena.dupeZ(u8, args[i]);
    }
    const app = c.gtk_application_new(app_id orelse "dev.sinty.FotoneViewer", c.G_APPLICATION_NON_UNIQUE);
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&activate), null, null, 0);
    return @intCast(c.g_application_run(@ptrCast(app), 0, null));
}
