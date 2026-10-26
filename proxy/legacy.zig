const std = @import("std");
const c = @import("c.zig").c;
const engine = @import("engine");
const view = @import("view3.zig");

const SESSION = "fotone-network-session";
const DIRS = "fotone-legacy-dirs";
const FLAGS = "fotone-legacy-flags";

var result_tag: u8 = 0;

pub const JavascriptResult = extern struct {
    tag: *u8,
    refs: c.gint,
    value: ?*c.JSCValue,
};

var result_type: c.GType = 0;

fn resultCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return webkit_javascript_result_ref(p);
}

fn resultFree(p: c.gpointer) callconv(.c) void {
    webkit_javascript_result_unref(p);
}

export fn webkit_javascript_result_get_type() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&result_type)) != 0) {
        const t = c.g_boxed_type_register_static("WebKitJavascriptResult", resultCopy, resultFree);
        c.g_once_init_leave_pointer(@ptrCast(&result_type), @ptrFromInt(t));
    }
    return result_type;
}

pub fn newResult(value: *c.JSCValue) *JavascriptResult {
    const r: *JavascriptResult = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(JavascriptResult))));
    r.* = .{ .tag = &result_tag, .refs = 1, .value = value };
    return r;
}

pub fn resultOf(p: ?*anyopaque) ?*JavascriptResult {
    const r: *JavascriptResult = @ptrCast(@alignCast(p orelse return null));
    return if (r.tag == &result_tag) r else null;
}

export fn webkit_javascript_result_ref(p: ?*anyopaque) ?*anyopaque {
    const r = resultOf(p) orelse return c.g_object_ref(p);
    _ = c.g_atomic_int_add(&r.refs, 1);
    return r;
}

export fn webkit_javascript_result_unref(p: ?*anyopaque) void {
    const r = resultOf(p) orelse return c.g_object_unref(p);
    if (c.g_atomic_int_dec_and_test(&r.refs) == 0) return;
    if (r.value) |v| c.g_object_unref(v);
    c.g_free(r);
}

export fn webkit_javascript_result_get_js_value(p: ?*anyopaque) ?*c.JSCValue {
    const r = resultOf(p) orelse return @ptrCast(@alignCast(p));
    return r.value;
}

export fn webkit_javascript_result_get_global_context(_: ?*anyopaque) ?*anyopaque {
    return null;
}

export fn webkit_javascript_result_get_value(_: ?*anyopaque) ?*anyopaque {
    return null;
}

const Finish = enum { evaluate, call };

const Run = struct { task: *c.GTask, finish: Finish };

fn ran(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const r: *Run = @ptrCast(@alignCast(data));
    defer c.g_free(r);
    defer c.g_object_unref(r.task);
    var err: [*c]c.GError = null;
    const value = switch (r.finish) {
        .evaluate => view.engineFn("webkit_web_view_evaluate_javascript_finish")(@ptrCast(src), res, &err),
        .call => view.engineFn("webkit_web_view_call_async_javascript_function_finish")(@ptrCast(src), res, &err),
    };
    const v = value orelse return c.g_task_return_error(r.task, err);
    c.g_task_return_pointer(r.task, newResult(v), resultFree);
}

fn start(v: *view.View, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer, finish: Finish) *Run {
    const r: *Run = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Run))));
    r.* = .{ .task = c.g_task_new(v, cancellable, cb, data).?, .finish = finish };
    return r;
}

fn evaluate(v: *view.View, script: [*c]const u8, len: isize, world: [*c]const u8, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    const r = start(v, cancellable, cb, data, .evaluate);
    view.engineFn("webkit_web_view_evaluate_javascript")(@ptrCast(v.priv.web), script, len, world, null, cancellable, ran, r);
}

export fn webkit_web_view_run_javascript(v: *view.View, script: [*c]const u8, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    evaluate(v, script, -1, null, cancellable, cb, data);
}

export fn webkit_web_view_run_javascript_in_world(v: *view.View, script: [*c]const u8, world: [*c]const u8, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    evaluate(v, script, -1, world, cancellable, cb, data);
}

export fn webkit_web_view_run_javascript_from_gresource(v: *view.View, resource: [*c]const u8, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    var err: [*c]c.GError = null;
    const bytes = c.g_resources_lookup_data(resource, c.G_RESOURCE_LOOKUP_FLAGS_NONE, &err) orelse {
        const task = c.g_task_new(v, cancellable, cb, data);
        defer c.g_object_unref(task);
        return c.g_task_return_error(task, err);
    };
    defer c.g_bytes_unref(bytes);
    var size: usize = 0;
    const script = c.g_bytes_get_data(bytes, &size);
    evaluate(v, @ptrCast(script), @intCast(size), null, cancellable, cb, data);
}

export fn webkit_web_view_run_async_javascript_function_in_world(v: *view.View, body: [*c]const u8, args: ?*c.GVariant, world: [*c]const u8, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    const r = start(v, cancellable, cb, data, .call);
    view.engineFn("webkit_web_view_call_async_javascript_function")(@ptrCast(v.priv.web), body, -1, args, world, null, cancellable, ran, r);
}

fn propagate(result: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*JavascriptResult {
    return @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(result), err)));
}

export fn webkit_web_view_run_javascript_finish(_: *view.View, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*JavascriptResult {
    return propagate(result, err);
}

export fn webkit_web_view_run_javascript_in_world_finish(_: *view.View, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*JavascriptResult {
    return propagate(result, err);
}

export fn webkit_web_view_run_javascript_from_gresource_finish(_: *view.View, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*JavascriptResult {
    return propagate(result, err);
}

pub const Dirs = struct {
    data: [*c]u8 = null,
    cache: [*c]u8 = null,
    local_storage: [*c]u8 = null,
    disk_cache: [*c]u8 = null,
    indexeddb: [*c]u8 = null,
    websql: [*c]u8 = null,
    hsts: [*c]u8 = null,
    itp: [*c]u8 = null,
    service_workers: [*c]u8 = null,
    dom_cache: [*c]u8 = null,
    offline: [*c]u8 = null,
    ephemeral: bool = false,
};

fn freeDirs(p: c.gpointer) callconv(.c) void {
    const d: *Dirs = @ptrCast(@alignCast(p));
    inline for (@typeInfo(Dirs).@"struct".fields) |f| {
        if (f.type == [*c]u8) c.g_free(@field(d, f.name));
    }
    c.g_free(d);
}

const string_props = [_]struct { name: []const u8, field: []const u8 }{
    .{ .name = "base-data-directory", .field = "data" },
    .{ .name = "base-cache-directory", .field = "cache" },
    .{ .name = "local-storage-directory", .field = "local_storage" },
    .{ .name = "disk-cache-directory", .field = "disk_cache" },
    .{ .name = "indexeddb-directory", .field = "indexeddb" },
    .{ .name = "websql-directory", .field = "websql" },
    .{ .name = "hsts-cache-directory", .field = "hsts" },
    .{ .name = "itp-directory", .field = "itp" },
    .{ .name = "service-worker-registrations-directory", .field = "service_workers" },
    .{ .name = "dom-cache-directory", .field = "dom_cache" },
    .{ .name = "offline-application-cache-directory", .field = "offline" },
};

pub const Kind = enum { string, boolean, double, unknown };

pub fn kindOf(name: []const u8) Kind {
    for (string_props) |p| if (std.mem.eql(u8, p.name, name)) return .string;
    if (std.mem.eql(u8, name, "is-ephemeral")) return .boolean;
    if (std.mem.eql(u8, name, "origin-storage-ratio") or std.mem.eql(u8, name, "total-storage-ratio")) return .double;
    return .unknown;
}

pub fn setDir(d: *Dirs, name: []const u8, value: [*c]const u8) void {
    inline for (string_props) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            c.g_free(@field(d, p.field));
            @field(d, p.field) = c.g_strdup(value);
        }
    }
}

fn parentOf(path: [*c]u8) [*c]u8 {
    if (path == null) return null;
    return c.g_path_get_dirname(path);
}

fn managerFor(d: *Dirs) ?*c.WebKitWebsiteDataManager {
    const session = if (d.ephemeral) c.webkit_network_session_new_ephemeral() else blk: {
        const data = if (d.data != null) c.g_strdup(d.data) else parentOf(d.local_storage);
        defer c.g_free(data);
        const cache = if (d.cache != null) c.g_strdup(d.cache) else parentOf(d.disk_cache);
        defer c.g_free(cache);
        break :blk c.webkit_network_session_new(data, cache);
    };
    const s = session orelse return null;
    const m = c.webkit_network_session_get_website_data_manager(s) orelse return null;
    _ = c.g_object_ref(m);
    c.g_object_set_data_full(@ptrCast(@alignCast(m)), SESSION, s, c.g_object_unref);
    c.g_object_set_data_full(@ptrCast(@alignCast(m)), DIRS, d, freeDirs);
    return m;
}

pub fn sessionOfManager(m: ?*c.WebKitWebsiteDataManager) ?*c.WebKitNetworkSession {
    const p = m orelse return c.webkit_network_session_get_default();
    return @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(p)), SESSION) orelse return c.webkit_network_session_get_default()));
}

export fn webkit_website_data_manager_new(first: [*c]const u8, ...) callconv(.c) ?*c.WebKitWebsiteDataManager {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const d: *Dirs = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Dirs))));
    d.* = .{};
    var name = first;
    while (name != null) {
        const n = std.mem.span(name);
        switch (kindOf(n)) {
            .string => setDir(d, n, @cVaArg(&ap, [*c]const u8)),
            .boolean => d.ephemeral = @cVaArg(&ap, c.gboolean) != 0,
            .double => _ = @cVaArg(&ap, f64),
            .unknown => break,
        }
        name = @cVaArg(&ap, [*c]const u8);
    }
    return managerFor(d);
}

export fn webkit_website_data_manager_new_ephemeral() ?*c.WebKitWebsiteDataManager {
    const d: *Dirs = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Dirs))));
    d.* = .{ .ephemeral = true };
    return managerFor(d);
}

fn dirsOf(m: ?*c.WebKitWebsiteDataManager) ?*Dirs {
    return @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(m orelse return null)), DIRS) orelse return null));
}

fn dirGetter(comptime field: []const u8, comptime sub: [:0]const u8) fn (?*c.WebKitWebsiteDataManager) callconv(.c) [*c]const u8 {
    return struct {
        fn f(m: ?*c.WebKitWebsiteDataManager) callconv(.c) [*c]const u8 {
            const d = dirsOf(m) orelse return null;
            if (@field(d, field) != null) return @field(d, field);
            const base = if (std.mem.eql(u8, field, "disk_cache") or std.mem.eql(u8, field, "offline")) d.cache else d.data;
            if (base == null) return null;
            @field(d, field) = c.g_build_filename(base, sub.ptr, @as(?*anyopaque, null));
            return @field(d, field);
        }
    }.f;
}

pub const localStorageDirectory = dirGetter("local_storage", "localstorage");

comptime {
    const getters = .{
        .{ "disk_cache", "WebKitCache", "webkit_website_data_manager_get_disk_cache_directory" },
        .{ "dom_cache", "CacheStorage", "webkit_website_data_manager_get_dom_cache_directory" },
        .{ "hsts", "hsts-storage", "webkit_website_data_manager_get_hsts_cache_directory" },
        .{ "indexeddb", "databases/indexeddb", "webkit_website_data_manager_get_indexeddb_directory" },
        .{ "itp", "itp", "webkit_website_data_manager_get_itp_directory" },
        .{ "local_storage", "localstorage", "webkit_website_data_manager_get_local_storage_directory" },
        .{ "offline", "applications", "webkit_website_data_manager_get_offline_application_cache_directory" },
        .{ "service_workers", "serviceworkers", "webkit_website_data_manager_get_service_worker_registrations_directory" },
        .{ "websql", "databases", "webkit_website_data_manager_get_websql_directory" },
    };
    for (getters) |g| @export(&dirGetter(g[0], g[1]), .{ .name = g[2] });
}

export fn webkit_website_data_manager_get_cookie_manager(m: ?*c.WebKitWebsiteDataManager) ?*c.WebKitCookieManager {
    return c.webkit_network_session_get_cookie_manager(sessionOfManager(m));
}

export fn webkit_website_data_manager_get_itp_enabled(m: ?*c.WebKitWebsiteDataManager) c.gboolean {
    return c.webkit_network_session_get_itp_enabled(sessionOfManager(m));
}

export fn webkit_website_data_manager_set_itp_enabled(m: ?*c.WebKitWebsiteDataManager, on: c.gboolean) void {
    c.webkit_network_session_set_itp_enabled(sessionOfManager(m), on);
}

export fn webkit_website_data_manager_get_persistent_credential_storage_enabled(m: ?*c.WebKitWebsiteDataManager) c.gboolean {
    return c.webkit_network_session_get_persistent_credential_storage_enabled(sessionOfManager(m));
}

export fn webkit_website_data_manager_set_persistent_credential_storage_enabled(m: ?*c.WebKitWebsiteDataManager, on: c.gboolean) void {
    c.webkit_network_session_set_persistent_credential_storage_enabled(sessionOfManager(m), on);
}

export fn webkit_website_data_manager_get_tls_errors_policy(m: ?*c.WebKitWebsiteDataManager) c.WebKitTLSErrorsPolicy {
    return c.webkit_network_session_get_tls_errors_policy(sessionOfManager(m));
}

export fn webkit_website_data_manager_set_tls_errors_policy(m: ?*c.WebKitWebsiteDataManager, policy: c.WebKitTLSErrorsPolicy) void {
    c.webkit_network_session_set_tls_errors_policy(sessionOfManager(m), policy);
}

export fn webkit_website_data_manager_set_network_proxy_settings(m: ?*c.WebKitWebsiteDataManager, mode: c.WebKitNetworkProxyMode, settings: ?*c.WebKitNetworkProxySettings) void {
    c.webkit_network_session_set_proxy_settings(sessionOfManager(m), mode, settings);
}

export fn webkit_website_data_manager_set_memory_pressure_settings(settings: ?*c.WebKitMemoryPressureSettings) void {
    c.webkit_network_session_set_memory_pressure_settings(settings);
}

const ContextFlags = struct {
    sandbox: c.gboolean = 1,
    scrollbars: c.gboolean = 1,
    limit: c.guint = 0,
    model: c_int = 1,
    favicon_dir: [*c]u8 = null,
};

fn flagsOf(ctx: ?*c.WebKitWebContext) *ContextFlags {
    const o: *c.GObject = @ptrCast(@alignCast(ctx orelse c.webkit_web_context_get_default()));
    if (c.g_object_get_data(o, FLAGS)) |p| return @ptrCast(@alignCast(p));
    const f: *ContextFlags = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(ContextFlags))));
    f.* = .{};
    c.g_object_set_data_full(o, FLAGS, f, c.g_free);
    return f;
}

pub fn sessionOf(ctx: ?*c.WebKitWebContext) ?*c.WebKitNetworkSession {
    const o: *c.GObject = @ptrCast(@alignCast(ctx orelse return c.webkit_network_session_get_default()));
    return @ptrCast(@alignCast(c.g_object_get_data(o, SESSION) orelse return c.webkit_network_session_get_default()));
}

var bound: ?*c.GPtrArray = null;

fn contextGone(_: c.gpointer, ctx: ?*c.GObject) callconv(.c) void {
    if (bound) |b| _ = c.g_ptr_array_remove(b, ctx);
}

fn bindSession(ctx: *c.WebKitWebContext, session: *c.WebKitNetworkSession) void {
    if (c.g_object_get_data(@ptrCast(@alignCast(ctx)), SESSION) == null) {
        if (bound == null) bound = c.g_ptr_array_new();
        c.g_ptr_array_add(bound, ctx);
        c.g_object_weak_ref(@ptrCast(@alignCast(ctx)), contextGone, null);
    }
    c.g_object_set_data_full(@ptrCast(@alignCast(ctx)), SESSION, c.g_object_ref(session), c.g_object_unref);
}

pub fn bindManager(ctx: ?*c.WebKitWebContext, m: *c.WebKitWebsiteDataManager) void {
    const s = sessionOfManager(m) orelse return;
    bindSession(ctx orelse return, s);
}

pub fn contextOf(session: ?*c.WebKitNetworkSession) ?*c.WebKitWebContext {
    const s = session orelse return null;
    if (bound) |b| {
        var i: c.guint = 0;
        while (i < b.len) : (i += 1) {
            const ctx: *c.WebKitWebContext = @ptrCast(@alignCast(b.pdata[i]));
            if (sessionOf(ctx) == s) return ctx;
        }
    }
    if (s == c.webkit_network_session_get_default()) return c.webkit_web_context_get_default();
    return null;
}

export fn webkit_web_context_new_ephemeral() ?*c.WebKitWebContext {
    const ctx = c.webkit_web_context_new() orelse return null;
    const s = c.webkit_network_session_new_ephemeral() orelse return ctx;
    defer c.g_object_unref(s);
    bindSession(ctx, s);
    return ctx;
}

export fn webkit_web_context_new_with_website_data_manager(m: ?*c.WebKitWebsiteDataManager) ?*c.WebKitWebContext {
    const ctx = c.webkit_web_context_new() orelse return null;
    if (sessionOfManager(m)) |s| bindSession(ctx, s);
    return ctx;
}

pub export fn webkit_web_context_get_website_data_manager(ctx: ?*c.WebKitWebContext) ?*c.WebKitWebsiteDataManager {
    return c.webkit_network_session_get_website_data_manager(sessionOf(ctx));
}

export fn webkit_web_view_get_website_data_manager(v: *view.View) ?*c.WebKitWebsiteDataManager {
    const s = view.engineFn("webkit_web_view_get_network_session")(@ptrCast(v.priv.web)) orelse return null;
    return c.webkit_network_session_get_website_data_manager(s);
}

export fn webkit_web_context_is_ephemeral(ctx: ?*c.WebKitWebContext) c.gboolean {
    return c.webkit_network_session_is_ephemeral(sessionOf(ctx));
}

export fn webkit_web_context_get_cookie_manager(ctx: ?*c.WebKitWebContext) ?*c.WebKitCookieManager {
    return c.webkit_network_session_get_cookie_manager(sessionOf(ctx));
}

export fn webkit_web_context_clear_cache(ctx: ?*c.WebKitWebContext) void {
    const m = c.webkit_network_session_get_website_data_manager(sessionOf(ctx));
    view.engineFn("webkit_website_data_manager_clear")(m, c.WEBKIT_WEBSITE_DATA_MEMORY_CACHE | c.WEBKIT_WEBSITE_DATA_DISK_CACHE, 0, null, null, null);
}

export fn webkit_web_context_download_uri(ctx: ?*c.WebKitWebContext, uri: [*c]const u8) ?*c.WebKitDownload {
    return c.webkit_network_session_download_uri(sessionOf(ctx), uri);
}

export fn webkit_web_context_set_network_proxy_settings(ctx: ?*c.WebKitWebContext, mode: c.WebKitNetworkProxyMode, settings: ?*c.WebKitNetworkProxySettings) void {
    c.webkit_network_session_set_proxy_settings(sessionOf(ctx), mode, settings);
}

export fn webkit_web_context_prefetch_dns(ctx: ?*c.WebKitWebContext, host: [*c]const u8) void {
    c.webkit_network_session_prefetch_dns(sessionOf(ctx), host);
}

export fn webkit_web_context_allow_tls_certificate_for_host(ctx: ?*c.WebKitWebContext, cert: ?*c.GTlsCertificate, host: [*c]const u8) void {
    c.webkit_network_session_allow_tls_certificate_for_host(sessionOf(ctx), cert, host);
}

export fn webkit_web_context_get_tls_errors_policy(ctx: ?*c.WebKitWebContext) c.WebKitTLSErrorsPolicy {
    return c.webkit_network_session_get_tls_errors_policy(sessionOf(ctx));
}

export fn webkit_web_context_set_tls_errors_policy(ctx: ?*c.WebKitWebContext, policy: c.WebKitTLSErrorsPolicy) void {
    c.webkit_network_session_set_tls_errors_policy(sessionOf(ctx), policy);
}

export fn webkit_web_context_set_disk_cache_directory(_: ?*c.WebKitWebContext, _: [*c]const u8) void {}

export fn webkit_web_context_set_additional_plugins_directory(_: ?*c.WebKitWebContext, _: [*c]const u8) void {}

export fn webkit_web_context_get_sandbox_enabled(ctx: ?*c.WebKitWebContext) c.gboolean {
    return flagsOf(ctx).sandbox;
}

export fn webkit_web_context_set_sandbox_enabled(ctx: ?*c.WebKitWebContext, on: c.gboolean) void {
    flagsOf(ctx).sandbox = on;
}

pub export fn webkit_web_context_get_use_system_appearance_for_scrollbars(ctx: ?*c.WebKitWebContext) c.gboolean {
    return flagsOf(ctx).scrollbars;
}

pub export fn webkit_web_context_set_use_system_appearance_for_scrollbars(ctx: ?*c.WebKitWebContext, on: c.gboolean) void {
    flagsOf(ctx).scrollbars = on;
}

export fn webkit_web_context_get_web_process_count_limit(ctx: ?*c.WebKitWebContext) c.guint {
    return flagsOf(ctx).limit;
}

export fn webkit_web_context_set_web_process_count_limit(ctx: ?*c.WebKitWebContext, limit: c.guint) void {
    flagsOf(ctx).limit = limit;
}

export fn webkit_web_context_get_process_model(ctx: ?*c.WebKitWebContext) c_int {
    return flagsOf(ctx).model;
}

export fn webkit_web_context_set_process_model(ctx: ?*c.WebKitWebContext, model: c_int) void {
    flagsOf(ctx).model = model;
}

export fn webkit_web_context_set_favicon_database_directory(ctx: ?*c.WebKitWebContext, path: [*c]const u8) void {
    const f = flagsOf(ctx);
    c.g_free(f.favicon_dir);
    f.favicon_dir = c.g_strdup(path);
    const m = c.webkit_network_session_get_website_data_manager(sessionOf(ctx));
    c.webkit_website_data_manager_set_favicons_enabled(m, 1);
}

export fn webkit_web_context_get_favicon_database_directory(ctx: ?*c.WebKitWebContext) [*c]const u8 {
    return flagsOf(ctx).favicon_dir;
}

export fn webkit_web_context_set_web_extensions_directory(ctx: ?*c.WebKitWebContext, dir: [*c]const u8) void {
    c.webkit_web_context_set_web_process_extensions_directory(ctx, dir);
}

export fn webkit_web_context_set_web_extensions_initialization_user_data(ctx: ?*c.WebKitWebContext, data: ?*c.GVariant) void {
    c.webkit_web_context_set_web_process_extensions_initialization_user_data(ctx, data);
}

const DomainsCall = struct { task: *c.GTask };

fn fetched(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const task: *c.GTask = @ptrCast(@alignCast(data));
    defer c.g_object_unref(task);
    var err: [*c]c.GError = null;
    const list = c.webkit_website_data_manager_fetch_finish(@ptrCast(src), res, &err);
    if (err != null) return c.g_task_return_error(task, err);
    const names = c.g_ptr_array_new();
    var it = list;
    while (it != null) : (it = it.*.next) {
        const d: ?*c.WebKitWebsiteData = @ptrCast(it.*.data);
        c.g_ptr_array_add(names, c.g_strdup(c.webkit_website_data_get_name(d)));
        c.webkit_website_data_unref(d);
    }
    c.g_list_free(list);
    c.g_ptr_array_add(names, null);
    c.g_task_return_pointer(task, @ptrCast(c.g_ptr_array_free(names, 0)), @ptrCast(&c.g_strfreev));
}

fn managerOfCookies(cm: ?*c.WebKitCookieManager) ?*c.WebKitWebsiteDataManager {
    var session = c.webkit_network_session_get_default();
    if (cm) |m| {
        if (c.g_object_get_data(@ptrCast(@alignCast(m)), SESSION)) |s| session = @ptrCast(@alignCast(s));
    }
    return c.webkit_network_session_get_website_data_manager(session);
}

export fn webkit_cookie_manager_get_domains_with_cookies(cm: ?*c.WebKitCookieManager, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    const task = c.g_task_new(cm, cancellable, cb, data);
    view.engineFn("webkit_website_data_manager_fetch")(managerOfCookies(cm), c.WEBKIT_WEBSITE_DATA_COOKIES, cancellable, fetched, task);
}

export fn webkit_cookie_manager_get_domains_with_cookies_finish(_: ?*c.WebKitCookieManager, res: ?*c.GAsyncResult, err: [*c][*c]c.GError) [*c][*c]u8 {
    return @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(res), err)));
}

export fn webkit_cookie_manager_delete_all_cookies(cm: ?*c.WebKitCookieManager) void {
    view.engineFn("webkit_website_data_manager_clear")(managerOfCookies(cm), c.WEBKIT_WEBSITE_DATA_COOKIES, 0, null, null, null);
}

const DeleteCall = struct { domain: [*c]u8 };

fn removeDomain(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const domain: [*c]u8 = @ptrCast(data);
    defer c.g_free(domain);
    const m: ?*c.WebKitWebsiteDataManager = @ptrCast(src);
    const list = c.webkit_website_data_manager_fetch_finish(m, res, null);
    var keep: [*c]c.GList = null;
    var it = list;
    while (it != null) : (it = it.*.next) {
        const d: ?*c.WebKitWebsiteData = @ptrCast(it.*.data);
        if (c.g_strcmp0(c.webkit_website_data_get_name(d), domain) == 0) keep = c.g_list_prepend(keep, d) else c.webkit_website_data_unref(d);
    }
    c.g_list_free(list);
    if (keep != null) view.engineFn("webkit_website_data_manager_remove")(m, c.WEBKIT_WEBSITE_DATA_COOKIES, keep, null, null, null);
    c.g_list_free_full(keep, @ptrCast(&c.webkit_website_data_unref));
}

export fn webkit_cookie_manager_delete_cookies_for_domain(cm: ?*c.WebKitCookieManager, domain: [*c]const u8) void {
    view.engineFn("webkit_website_data_manager_fetch")(managerOfCookies(cm), c.WEBKIT_WEBSITE_DATA_COOKIES, null, removeDomain, c.g_strdup(domain));
}

const data_bits = [_][2]c_uint{
    .{ 1, 1 },       .{ 2, 2 },        .{ 4, 4 },       .{ 8, 8 },
    .{ 16, 16 },     .{ 64, 32 },      .{ 256, 64 },    .{ 512, 128 },
    .{ 1024, 256 },  .{ 2048, 512 },   .{ 4096, 1024 }, .{ 8192, 2048 },
};

pub fn engineTypes(legacy: c_uint) c_uint {
    var t: c_uint = 0;
    for (data_bits) |b| {
        if (legacy & b[0] != 0) t |= b[1];
    }
    return t;
}

pub fn legacyTypes(types: c_uint) c_uint {
    var t: c_uint = 0;
    for (data_bits) |b| {
        if (types & b[1] != 0) t |= b[0];
    }
    return t;
}

export fn webkit_website_data_manager_fetch(m: ?*c.WebKitWebsiteDataManager, types: c_uint, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    view.engineFn("webkit_website_data_manager_fetch")(m, engineTypes(types), cancellable, cb, data);
}

export fn webkit_website_data_manager_remove(m: ?*c.WebKitWebsiteDataManager, types: c_uint, list: ?*c.GList, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    view.engineFn("webkit_website_data_manager_remove")(m, engineTypes(types), list, cancellable, cb, data);
}

export fn webkit_website_data_manager_clear(m: ?*c.WebKitWebsiteDataManager, types: c_uint, span: c.GTimeSpan, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    view.engineFn("webkit_website_data_manager_clear")(m, engineTypes(types), span, cancellable, cb, data);
}

export fn webkit_website_data_get_types(d: ?*c.WebKitWebsiteData) c_uint {
    return legacyTypes(view.engineFn("webkit_website_data_get_types")(d));
}

export fn webkit_website_data_get_size(d: ?*c.WebKitWebsiteData, types: c_uint) u64 {
    return view.engineFn("webkit_website_data_get_size")(d, engineTypes(types));
}

test "website data types translate between the two numberings" {
    try std.testing.expectEqual(@as(c_uint, 64), engineTypes(256));
    try std.testing.expectEqual(@as(c_uint, 4095), engineTypes(16383));
    try std.testing.expectEqual(@as(c_uint, 0), engineTypes(32 | 128));
    try std.testing.expectEqual(@as(c_uint, 256 | 1), legacyTypes(64 | 1));
    try std.testing.expectEqual(@as(c_uint, 16383 & ~@as(c_uint, 32 | 128)), legacyTypes(4095));
}

test "a JSC value passes where a JavaScript result is expected" {
    const ctx = c.jsc_context_new();
    defer c.g_object_unref(ctx);
    const v = c.jsc_value_new_number(ctx, 42);
    try std.testing.expect(resultOf(v) == null);
    try std.testing.expect(webkit_javascript_result_get_js_value(v) == v);
    const r = newResult(@ptrCast(c.g_object_ref(v)));
    try std.testing.expect(webkit_javascript_result_get_js_value(r) == v);
    webkit_javascript_result_unref(r);
    c.g_object_unref(v);
}

test "legacy data manager properties have known value types" {
    try std.testing.expectEqual(Kind.string, kindOf("base-data-directory"));
    try std.testing.expectEqual(Kind.string, kindOf("websql-directory"));
    try std.testing.expectEqual(Kind.boolean, kindOf("is-ephemeral"));
    try std.testing.expectEqual(Kind.double, kindOf("total-storage-ratio"));
    try std.testing.expectEqual(Kind.unknown, kindOf("bogus"));
}

test "a legacy directory lands in its field" {
    var d: Dirs = .{};
    setDir(&d, "local-storage-directory", "/tmp/x");
    try std.testing.expectEqualStrings("/tmp/x", std.mem.span(d.local_storage));
    c.g_free(d.local_storage);
}
