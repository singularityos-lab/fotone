const std = @import("std");
const c = @import("c.zig").c;

pub const Done = *const fn (c.gpointer, c.gboolean) callconv(.c) void;

const Job = struct {
    widget: *c.GtkWidget,
    parent: ?*c.GtkWindow,
    settings: ?*c.GtkPrintSettings,
    setup: ?*c.GtkPageSetup,
    dialog: bool,
    done: ?Done,
    data: c.gpointer,
    surface: ?*c.cairo_surface_t = null,
};

pub fn pages(width: c_int, height: c_int, page_w: f64, page_h: f64) c_int {
    if (width <= 0 or height <= 0 or page_w <= 0 or page_h <= 0) return 1;
    const scaled = @as(f64, @floatFromInt(height)) * page_w / @as(f64, @floatFromInt(width));
    return @max(1, @as(c_int, @intFromFloat(@ceil(scaled / page_h - 0.001))));
}

fn finish(j: *Job, ok: bool) void {
    if (j.done) |d| d(j.data, @intFromBool(ok));
    if (j.surface) |s| c.cairo_surface_destroy(s);
    if (j.settings) |s| c.g_object_unref(s);
    if (j.setup) |s| c.g_object_unref(s);
    c.g_object_unref(j.widget);
    c.g_free(j);
}

fn surfaceFrom(img: *c.WebKitImage) ?*c.cairo_surface_t {
    const w = c.webkit_image_get_width(img);
    const h = c.webkit_image_get_height(img);
    const bytes = c.webkit_image_as_bytes(img) orelse return null;
    defer c.g_bytes_unref(bytes);
    const s = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h) orelse return null;
    c.cairo_surface_flush(s);
    const src: [*]const u8 = @ptrCast(c.g_bytes_get_data(bytes, null));
    const dst: [*]u8 = c.cairo_image_surface_get_data(s);
    const in_stride: usize = c.webkit_image_get_stride(img);
    const out_stride: usize = @intCast(c.cairo_image_surface_get_stride(s));
    const row: usize = @as(usize, @intCast(w)) * 4;
    var y: usize = 0;
    while (y < h) : (y += 1) @memcpy(dst[y * out_stride ..][0..row], src[y * in_stride ..][0..row]);
    c.cairo_surface_mark_dirty(s);
    return s;
}

fn beginPrint(op: ?*c.GtkPrintOperation, ctx: ?*c.GtkPrintContext, data: c.gpointer) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data));
    const s = j.surface.?;
    c.gtk_print_operation_set_n_pages(op, pages(c.cairo_image_surface_get_width(s), c.cairo_image_surface_get_height(s), c.gtk_print_context_get_width(ctx), c.gtk_print_context_get_height(ctx)));
}

fn drawPage(_: ?*c.GtkPrintOperation, ctx: ?*c.GtkPrintContext, page: c_int, data: c.gpointer) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data));
    const s = j.surface.?;
    const cr = c.gtk_print_context_get_cairo_context(ctx);
    const scale = c.gtk_print_context_get_width(ctx) / @as(f64, @floatFromInt(c.cairo_image_surface_get_width(s)));
    const page_h = c.gtk_print_context_get_height(ctx) / scale;
    c.cairo_rectangle(cr, 0, 0, c.gtk_print_context_get_width(ctx), c.gtk_print_context_get_height(ctx));
    c.cairo_clip(cr);
    c.cairo_scale(cr, scale, scale);
    c.cairo_set_source_surface(cr, s, 0, -page_h * @as(f64, @floatFromInt(page)));
    c.cairo_paint(cr);
}

fn printed(op: ?*c.GtkPrintOperation, result: c.GtkPrintOperationResult, data: c.gpointer) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data));
    defer c.g_object_unref(op);
    finish(j, result == c.GTK_PRINT_OPERATION_RESULT_APPLY);
}

fn snapshotted(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data));
    const img = c.webkit_web_view_get_snapshot_finish(@ptrCast(@alignCast(src)), res, null) orelse return finish(j, false);
    defer c.g_object_unref(img);
    j.surface = surfaceFrom(img) orelse return finish(j, false);
    const op = c.gtk_print_operation_new();
    if (j.settings) |s| c.gtk_print_operation_set_print_settings(op, s);
    if (j.setup) |s| c.gtk_print_operation_set_default_page_setup(op, s);
    c.gtk_print_operation_set_allow_async(op, 1);
    c.gtk_print_operation_set_embed_page_setup(op, 1);
    _ = c.g_signal_connect_data(op, "begin-print", @ptrCast(&beginPrint), j, null, 0);
    _ = c.g_signal_connect_data(op, "draw-page", @ptrCast(&drawPage), j, null, 0);
    _ = c.g_signal_connect_data(op, "done", @ptrCast(&printed), j, null, 0);
    const action: c.GtkPrintOperationAction = if (j.dialog) c.GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG else c.GTK_PRINT_OPERATION_ACTION_PRINT;
    const r = c.gtk_print_operation_run(op, action, j.parent, null);
    if (r != c.GTK_PRINT_OPERATION_RESULT_IN_PROGRESS) printed(op, r, j);
}

pub fn run(widget: *c.GtkWidget, web: *c.WebKitWebView, parent: ?*c.GtkWindow, settings: ?*c.GtkPrintSettings, setup: ?*c.GtkPageSetup, dialog: bool, done: ?Done, data: c.gpointer) void {
    const j: *Job = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Job))));
    j.* = .{
        .widget = @ptrCast(@alignCast(c.g_object_ref(widget))),
        .parent = parent,
        .settings = if (settings) |s| @ptrCast(@alignCast(c.g_object_ref(s))) else null,
        .setup = if (setup) |s| @ptrCast(@alignCast(c.g_object_ref(s))) else null,
        .dialog = dialog,
        .done = done,
        .data = data,
    };
    c.webkit_web_view_get_snapshot(web, c.WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT, c.WEBKIT_SNAPSHOT_OPTIONS_NONE, null, snapshotted, j);
}

