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
var translate = false;
var extension: ?[*:0]const u8 = null;
var dump = false;
var perf = false;
var perf_polls: u32 = 0;
var suspend_test = false;
var rss_before: u64 = 0;

extern fn webkit_fotone_web_view_set_suspended(web: ?*c.WebKitWebView, suspended: c.gboolean) void;

const PERF_POLL_MS = 200;
const PERF_LIMIT = 100;

fn capture(_: c.gpointer) callconv(.c) c.gboolean {
    const win = window orelse return 0;
    const frame = if (view) |v| c.sit_web_view_get_frame(v) else null;
    if (frame == null or c.gdk_texture_save_to_png(frame, shot.?) == 0) std.log.warn("fotone-viewer: nothing to capture", .{});
    c.gtk_window_destroy(@ptrCast(win));
    return 0;
}

fn dumped(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    if (c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, &err)) |value| {
        defer c.g_object_unref(value);
        const text = c.jsc_value_to_string(value);
        defer c.g_free(text);
        std.debug.print("{s}\n", .{text});
    } else {
        std.log.warn("fotone-viewer: {s}", .{err.*.message});
        c.g_error_free(err);
    }
    if (window) |win| c.gtk_window_destroy(@ptrCast(win));
}

fn readText(_: c.gpointer) callconv(.c) c.gboolean {
    c.webkit_web_view_evaluate_javascript(c.sit_web_view_get_web_view(view), "document.body.innerText", -1, null, null, null, dumped, null);
    return 0;
}

fn perfRead(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    const value = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, &err) orelse {
        c.g_error_free(err);
        perf_polls += 1;
        if (perf_polls < PERF_LIMIT) _ = c.g_timeout_add(PERF_POLL_MS, perfPoll, null) else if (window) |win| c.gtk_window_destroy(@ptrCast(win));
        return;
    };
    defer c.g_object_unref(value);
    const text = c.jsc_value_to_string(value);
    defer c.g_free(text);
    if (std.mem.len(text) == 0) {
        perf_polls += 1;
        if (perf_polls < PERF_LIMIT) {
            _ = c.g_timeout_add(PERF_POLL_MS, perfPoll, null);
            return;
        }
        std.log.warn("fotone-viewer: the page reported no measurements", .{});
    } else c.g_print("%s\n", text);
    if (window) |win| c.gtk_window_destroy(@ptrCast(win));
}

fn perfPoll(_: c.gpointer) callconv(.c) c.gboolean {
    c.webkit_web_view_evaluate_javascript(c.sit_web_view_get_web_view(view), "document.body.dataset.perf || ''", -1, null, null, null, perfRead, null);
    return 0;
}

fn field(text: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, name) orelse return null;
    const rest = text[at + name.len ..];
    return std.mem.trim(u8, rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len], " \t");
}

fn parentOf(pid: []const u8) ?c_int {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{s}/status", .{pid}) catch return null;
    var text: [*c]u8 = null;
    if (c.g_file_get_contents(p.ptr, &text, null, null) == 0) return null;
    defer c.g_free(text);
    return std.fmt.parseInt(c_int, field(std.mem.span(text), "PPid:") orelse return null, 10) catch null;
}

fn webProcessRss() u64 {
    const self = c.getpid();
    const dir = c.g_dir_open("/proc", 0, null) orelse return 0;
    defer c.g_dir_close(dir);
    var total: u64 = 0;
    while (c.g_dir_read_name(dir)) |name| {
        const pid = std.mem.span(name);
        _ = std.fmt.parseInt(c_int, pid, 10) catch continue;
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path, "/proc/{s}/status", .{pid}) catch continue;
        var text: [*c]u8 = null;
        if (c.g_file_get_contents(p.ptr, &text, null, null) == 0) continue;
        defer c.g_free(text);
        const status = std.mem.span(text);
        const comm = field(status, "Name:") orelse continue;
        if (std.mem.indexOf(u8, comm, "WebProcess") == null) continue;
        var ancestor = std.fmt.parseInt(c_int, field(status, "PPid:") orelse continue, 10) catch continue;
        var depth: u32 = 0;
        while (ancestor != self and ancestor > 1 and depth < 4) : (depth += 1) {
            var buf: [16]u8 = undefined;
            ancestor = parentOf(std.fmt.bufPrint(&buf, "{d}", .{ancestor}) catch break) orelse break;
        }
        if (ancestor != self) continue;
        const rss = field(status, "RssAnon:") orelse continue;
        total += std.fmt.parseInt(u64, rss[0 .. std.mem.indexOfScalar(u8, rss, ' ') orelse rss.len], 10) catch 0;
    }
    return total;
}

fn resumedRead(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    if (c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, &err)) |value| {
        defer c.g_object_unref(value);
        const text = c.jsc_value_to_string(value);
        defer c.g_free(text);
        _ = c.g_print("{\"resumed_nodes\":%s}\n", text);
    } else {
        _ = c.g_print("{\"resumed_nodes\":null}\n");
        c.g_error_free(err);
    }
    if (window) |win| c.gtk_window_destroy(@ptrCast(win));
}

fn resumedRead0(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    if (c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, null)) |value| {
        defer c.g_object_unref(value);
        const text = c.jsc_value_to_string(value);
        defer c.g_free(text);
        _ = c.g_print("{\"nodes\":%s}\n", text);
    }
}

fn resumedCheck(_: c.gpointer) callconv(.c) c.gboolean {
    c.webkit_web_view_evaluate_javascript(c.sit_web_view_get_web_view(view), "document.getElementsByTagName('*').length", -1, null, null, null, resumedRead, null);
    return 0;
}

fn suspendReport(_: c.gpointer) callconv(.c) c.gboolean {
    _ = c.g_print("{\"rss_before_kb\":%lu,\"rss_suspended_kb\":%lu}\n", rss_before, webProcessRss());
    c.gtk_widget_set_visible(@ptrCast(@alignCast(view)), 1);
    webkit_fotone_web_view_set_suspended(c.sit_web_view_get_web_view(view), 0);
    _ = c.g_timeout_add(1000, resumedCheck, null);
    return 0;
}

fn suspendNow(_: c.gpointer) callconv(.c) c.gboolean {
    c.webkit_web_view_evaluate_javascript(c.sit_web_view_get_web_view(view), "document.getElementsByTagName('*').length", -1, null, null, null, resumedRead0, null);
    rss_before = webProcessRss();
    c.gtk_widget_set_visible(@ptrCast(@alignCast(view)), 0);
    webkit_fotone_web_view_set_suspended(c.sit_web_view_get_web_view(view), 1);
    _ = c.g_timeout_add(3000, suspendReport, null);
    return 0;
}

fn loaded(_: ?*c.WebKitWebView, event: c.WebKitLoadEvent, _: c.gpointer) callconv(.c) void {
    if (event != c.WEBKIT_LOAD_FINISHED) return;
    if (translate) c.sit_web_view_translate(view);
    if (dump) _ = c.g_timeout_add(3000, readText, null);
    if (perf) _ = c.g_timeout_add(PERF_POLL_MS, perfPoll, null);
    if (suspend_test) _ = c.g_timeout_add(3000, suspendNow, null);
    if (shot != null) _ = c.g_timeout_add(if (translate) 5000 else 1500, capture, null);
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
    if (extension) |path| {
        var err: [*c]c.GError = null;
        const id = c.sit_web_view_install_extension(path, &err);
        if (id == null) {
            std.log.warn("fotone-viewer: {s}", .{err.*.message});
            c.g_error_free(err);
        } else c.g_free(id);
    }
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
        } else if (std.mem.eql(u8, args[i], "--extension") and i + 1 < args.len) {
            extension = try arena.dupeZ(u8, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dump")) {
            dump = true;
        } else if (std.mem.eql(u8, args[i], "--perf")) {
            perf = true;
        } else if (std.mem.eql(u8, args[i], "--suspend-test")) {
            suspend_test = true;
        } else if (std.mem.eql(u8, args[i], "--translate")) {
            translate = true;
        } else uri = try arena.dupeZ(u8, args[i]);
    }
    const app = c.gtk_application_new(app_id orelse "dev.sinty.FotoneViewer", c.G_APPLICATION_NON_UNIQUE);
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&activate), null, null, 0);
    return @intCast(c.g_application_run(@ptrCast(app), 0, null));
}
