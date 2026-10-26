const std = @import("std");
const c = @import("c.zig").c;
const options = @import("options");

const names = if (options.gtk3) @embedFile("webkit2gtk-4.1.syms") else @embedFile("webkitgtk-6.0.syms");

const GetType = *const fn () callconv(.c) c.GType;

var lib: ?*anyopaque = null;
var loop: ?*c.GMainLoop = null;
var view: ?*c.GtkWidget = null;

fn sym(comptime T: type, name: [*:0]const u8) ?T {
    const p = c.dlsym(lib, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn usage() noreturn {
    _ = c.printf("usage: fotone-compat <libwebkitgtk.so> [--run]\n");
    std.process.exit(2);
}

fn flagBits(flags: c.GParamFlags) c.GParamFlags {
    return flags & (c.G_PARAM_READABLE | c.G_PARAM_WRITABLE | c.G_PARAM_CONSTRUCT | c.G_PARAM_CONSTRUCT_ONLY);
}

fn byName(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c_int {
    const x: *const *c.GParamSpec = @ptrCast(@alignCast(a));
    const y: *const *c.GParamSpec = @ptrCast(@alignCast(b));
    return c.g_strcmp0(x.*.*.name, y.*.*.name);
}

fn bySignalName(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c_int {
    const x: *const c.guint = @ptrCast(@alignCast(a));
    const y: *const c.guint = @ptrCast(@alignCast(b));
    return c.g_strcmp0(c.g_signal_name(x.*), c.g_signal_name(y.*));
}

fn bare(t: c.GType) c.GType {
    return t & ~@as(c.GType, c.G_SIGNAL_TYPE_STATIC_SCOPE);
}

fn properties(t: c.GType) void {
    const klass = c.g_type_class_ref(t);
    defer c.g_type_class_unref(klass);
    var n: c.guint = 0;
    const specs = c.g_object_class_list_properties(@ptrCast(@alignCast(klass)), &n);
    defer c.g_free(@ptrCast(specs));
    c.g_qsort_with_data(@ptrCast(specs), @intCast(n), @sizeOf(*c.GParamSpec), byName, null);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const p = specs[i];
        if (p.*.owner_type != t) continue;
        _ = c.printf("  prop %s %s %u\n", p.*.name, c.g_type_name(p.*.value_type), flagBits(p.*.flags));
    }
}

fn signals(t: c.GType) void {
    var n: c.guint = 0;
    const ids = c.g_signal_list_ids(t, &n);
    defer c.g_free(ids);
    c.g_qsort_with_data(@ptrCast(ids), @intCast(n), @sizeOf(c.guint), bySignalName, null);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        var q: c.GSignalQuery = undefined;
        c.g_signal_query(ids[i], &q);
        _ = c.printf("  signal %s %s %u (", q.signal_name, c.g_type_name(bare(q.return_type)), q.signal_flags & (c.G_SIGNAL_RUN_FIRST | c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION));
        var k: c.guint = 0;
        while (k < q.n_params) : (k += 1) _ = c.printf("%s%s", if (k > 0) @as([*c]const u8, ", ") else @as([*c]const u8, ""), c.g_type_name(bare(q.param_types[k])));
        _ = c.printf(")\n");
    }
}

fn values(t: c.GType) void {
    const klass = c.g_type_class_ref(t);
    defer c.g_type_class_unref(klass);
    if (c.g_type_is_a(t, c.G_TYPE_ENUM) != 0) {
        const e: *c.GEnumClass = @ptrCast(@alignCast(klass));
        var i: c.guint = 0;
        while (i < e.n_values) : (i += 1) _ = c.printf("  value %s %d\n", e.values[i].value_name, e.values[i].value);
    } else {
        const f: *c.GFlagsClass = @ptrCast(@alignCast(klass));
        var i: c.guint = 0;
        while (i < f.n_values) : (i += 1) _ = c.printf("  value %s %u\n", f.values[i].value_name, f.values[i].value);
    }
}

fn describe(t: c.GType) void {
    var q = std.mem.zeroes(c.GTypeQuery);
    if (c.G_TYPE_IS_CLASSED(t) != 0) c.g_type_query(t, &q);
    const parent = c.g_type_parent(t);
    _ = c.printf("type %s parent %s class %u instance %u\n", c.g_type_name(t), if (parent != 0) c.g_type_name(parent) else @as([*c]const u8, "-"), q.class_size, q.instance_size);
    const fundamental = c.g_type_fundamental(t);
    if (fundamental == c.G_TYPE_ENUM or fundamental == c.G_TYPE_FLAGS) return values(t);
    if (fundamental == c.G_TYPE_OBJECT) properties(t);
    if (fundamental == c.G_TYPE_OBJECT or fundamental == c.G_TYPE_INTERFACE) signals(t);
}

fn report() void {
    var it = std.mem.tokenizeScalar(u8, names, '\n');
    var missing: usize = 0;
    var buf: [256]u8 = undefined;
    while (it.next()) |name| {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
        if (c.dlsym(lib, z.ptr) == null) {
            _ = c.printf("missing %s\n", z.ptr);
            missing += 1;
        }
    }
    _ = c.printf("symbols %zu missing %zu\n", std.mem.count(u8, names, "\n"), missing);
    it = std.mem.tokenizeScalar(u8, names, '\n');
    while (it.next()) |name| {
        if (!std.mem.endsWith(u8, name, "_get_type")) continue;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
        const f = sym(GetType, z.ptr) orelse continue;
        describe(f());
    }
}

fn evaluated(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    const finish = sym(*const fn ([*c]c.GObject, ?*c.GAsyncResult, [*c][*c]c.GError) callconv(.c) ?*anyopaque, "webkit_web_view_evaluate_javascript_finish").?;
    const to_int = sym(*const fn (?*anyopaque) callconv(.c) i32, "jsc_value_to_int32").?;
    var err: [*c]c.GError = null;
    const value = finish(src, res, &err);
    if (value) |v| {
        _ = c.printf("run eval %d\n", to_int(v));
        c.g_object_unref(v);
    } else {
        _ = c.printf("run eval error %s\n", if (err) |e| e.*.message else @as([*c]u8, @constCast("unknown")));
        c.g_clear_error(&err);
    }
    var title: [*c]u8 = null;
    var uri: [*c]u8 = null;
    c.g_object_get(view, "title", &title, "uri", &uri, @as([*c]const u8, null));
    defer c.g_free(title);
    defer c.g_free(uri);
    _ = c.printf("run title %s\n", title);
    _ = c.printf("run uri %s\n", uri);
    const set_zoom = sym(*const fn (?*c.GtkWidget, f64) callconv(.c) void, "webkit_web_view_set_zoom_level").?;
    const get_zoom = sym(*const fn (?*c.GtkWidget) callconv(.c) f64, "webkit_web_view_get_zoom_level").?;
    set_zoom(view, 1.5);
    _ = c.printf("run zoom %.2f\n", get_zoom(view));
    const back = sym(*const fn (?*c.GtkWidget) callconv(.c) c.gboolean, "webkit_web_view_can_go_back").?;
    _ = c.printf("run back %d\n", back(view));
    c.g_main_loop_quit(loop);
}

var finished = false;
var evaluating = false;

fn evaluate(v: ?*c.GtkWidget) void {
    if (evaluating or !finished) return;
    var title: [*c]u8 = null;
    c.g_object_get(v, "title", &title, @as([*c]const u8, null));
    defer c.g_free(title);
    if (title == null) return;
    evaluating = true;
    const eval = sym(*const fn (?*c.GtkWidget, [*c]const u8, isize, [*c]const u8, [*c]const u8, ?*c.GCancellable, c.GAsyncReadyCallback, c.gpointer) callconv(.c) void, "webkit_web_view_evaluate_javascript").?;
    eval(v, "6*7", -1, null, null, null, evaluated, null);
}

fn titleChanged(v: ?*c.GtkWidget, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    evaluate(v);
}

fn loadChanged(v: ?*c.GtkWidget, event: c_int, _: c.gpointer) callconv(.c) void {
    _ = c.printf("run load %d\n", event);
    if (event != 3) return;
    finished = true;
    evaluate(v);
}

fn timeout(_: c.gpointer) callconv(.c) c.gboolean {
    _ = c.printf("run timeout\n");
    c.g_main_loop_quit(loop);
    return 0;
}

fn run() void {
    if (options.gtk3) c.gtk_init(null, null) else c.gtk_init();
    const new = sym(*const fn () callconv(.c) ?*c.GtkWidget, "webkit_web_view_new").?;
    const load = sym(*const fn (?*c.GtkWidget, [*c]const u8, [*c]const u8) callconv(.c) void, "webkit_web_view_load_html").?;
    const win = if (options.gtk3) c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) else c.gtk_window_new();
    c.gtk_window_set_default_size(@ptrCast(win), 640, 480);
    view = new();
    _ = c.printf("run widget %s\n", c.g_type_name(c.G_TYPE_FROM_INSTANCE(view)));
    if (options.gtk3) {
        c.gtk_container_add(@ptrCast(win), view);
        c.gtk_widget_show_all(win);
    } else {
        c.gtk_window_set_child(@ptrCast(win), view);
        c.gtk_window_present(@ptrCast(win));
    }
    _ = c.g_signal_connect_data(view, "load-changed", @ptrCast(&loadChanged), null, null, 0);
    _ = c.g_signal_connect_data(view, "notify::title", @ptrCast(&titleChanged), null, null, 0);
    load(view, "<title>fotone</title><p>compat</p>", "https://compat.invalid/");
    loop = c.g_main_loop_new(null, 0);
    _ = c.g_timeout_add_seconds(30, timeout, null);
    c.g_main_loop_run(loop);
    if (options.gtk3) c.gtk_widget_destroy(win) else c.gtk_window_destroy(@ptrCast(win));
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) usage();
    const path = try init.arena.allocator().dupeZ(u8, args[1]);
    lib = c.dlopen(path.ptr, c.RTLD_NOW | c.RTLD_GLOBAL) orelse {
        _ = c.printf("cannot load %s: %s\n", path.ptr, c.dlerror());
        return 1;
    };
    if (args.len > 2 and std.mem.eql(u8, args[2], "--run")) run() else report();
    return 0;
}
