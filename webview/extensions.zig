const std = @import("std");
const c = @import("c.zig").c;
const dnr = @import("dnr.zig");

const Json = std.json.Value;
const gpa = std.heap.c_allocator;

pub const SCHEME = "fotone-extension";
const BACKGROUND_PAGE = "/_generated_background_page.html";

const SHIM =
    \\const MSG = {};
    \\for (const k in MESSAGES) MSG[k.toLowerCase()] = MESSAGES[k];
    \\const port = window.webkit.messageHandlers["fotoneExt_" + ID];
    \\const call = async (req) => {
    \\  const r = JSON.parse(await port.postMessage(JSON.stringify(req)));
    \\  if (r && r.error) throw new Error(r.error);
    \\  return r;
    \\};
    \\const wrap = (p, cb) => {
    \\  if (typeof cb !== "function") return p;
    \\  p.then((v) => cb(v), (e) => { runtime.lastError = { message: String(e && e.message || e) }; try { cb(); } finally { runtime.lastError = undefined; } });
    \\};
    \\const event = (list) => ({
    \\  addListener: (f) => { if (!list.includes(f)) list.push(f); },
    \\  removeListener: (f) => { const i = list.indexOf(f); if (i >= 0) list.splice(i, 1); },
    \\  hasListener: (f) => list.includes(f),
    \\  hasListeners: () => list.length > 0,
    \\});
    \\const keysOf = (k) => k == null ? null : typeof k === "string" ? [k] : Array.isArray(k) ? k : Object.keys(k);
    \\const area = {
    \\  get: (k, cb) => wrap(call({ op: "get", keys: keysOf(k) }).then((r) => Object.assign(k && typeof k === "object" && !Array.isArray(k) ? Object.assign({}, k) : {}, r.items)), cb),
    \\  set: (items, cb) => wrap(call({ op: "set", items }).then(() => undefined), cb),
    \\  remove: (k, cb) => wrap(call({ op: "remove", keys: keysOf(k) }).then(() => undefined), cb),
    \\  clear: (cb) => wrap(call({ op: "clear" }).then(() => undefined), cb),
    \\  getKeys: (cb) => wrap(call({ op: "get", keys: null }).then((r) => Object.keys(r.items)), cb),
    \\};
    \\const i18n = {
    \\  getMessage(name, subs) {
    \\    const m = MSG[String(name).toLowerCase()];
    \\    if (!m) return "";
    \\    const list = subs == null ? [] : Array.isArray(subs) ? subs.map(String) : [String(subs)];
    \\    const ph = {};
    \\    for (const k in m.placeholders || {}) ph[k.toLowerCase()] = m.placeholders[k].content;
    \\    return m.message.replace(/\$([a-zA-Z0-9_@]+)\$/g, (_, n) => ph[n.toLowerCase()] ?? "")
    \\      .replace(/\$(\d)/g, (_, d) => list[d - 1] ?? "").replace(/\$\$/g, "$");
    \\  },
    \\  getUILanguage: () => navigator.language,
    \\};
    \\const messages = [], installed = [], startup = [];
    \\const runtime = {
    \\  id: ID,
    \\  lastError: undefined,
    \\  getManifest: () => JSON.parse(JSON.stringify(MANIFEST)),
    \\  getURL: (p) => "fotone-extension://" + ID + "/" + String(p).replace(/^\//, ""),
    \\  sendMessage: (...a) => {
    \\    const cb = typeof a[a.length - 1] === "function" ? a.pop() : null;
    \\    const message = a.length > 1 && (typeof a[0] === "string" || a[0] == null) ? a[1] : a[0];
    \\    return wrap(call({ op: "send", message, url: location.href }).then((r) => r.response ?? undefined), cb);
    \\  },
    \\  onMessage: event(messages),
    \\  onInstalled: event(installed),
    \\  onStartup: event(startup),
    \\};
    \\globalThis.chrome = Object.assign(globalThis.chrome || {}, { runtime, storage: { local: area }, i18n });
    \\if (ROLE === "background") {
    \\  globalThis.__fotoneDispatch = (message, sender) => new Promise((resolve) => {
    \\    let done = false, later = false;
    \\    const reply = (v) => { if (!done) { done = true; resolve(v === undefined ? null : v); } };
    \\    for (const f of messages.slice()) {
    \\      let r;
    \\      try { r = f(message, sender, reply); } catch (e) { console.error(e); continue; }
    \\      if (r === true) later = true;
    \\      else if (r && typeof r.then === "function") { later = true; r.then(reply, () => reply(null)); }
    \\    }
    \\    if (!later) reply(null);
    \\  });
    \\  globalThis.__fotoneStarted = (first) => {
    \\    for (const f of (first ? installed : startup).slice()) {
    \\      try { f(first ? { reason: "install" } : undefined); } catch (e) { console.error(e); }
    \\    }
    \\  };
    \\}
;

const Script = struct {
    script: *c.WebKitUserScript,
    sheet: ?*c.WebKitUserStyleSheet,
};

const Port = struct {
    ext: *Extension,
    background: bool,
};

const Extension = struct {
    arena: std.heap.ArenaAllocator,
    id: [:0]const u8,
    dir: [:0]const u8,
    world: [:0]const u8,
    handler: [:0]const u8,
    manifest: []const u8,
    messages: []const u8,
    worker: ?[]const u8,
    module: bool,
    scripts: std.ArrayList(Script) = .empty,
    rule_sets: std.ArrayList([:0]const u8) = .empty,
    store: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    background: ?*c.WebKitWebView = null,
    content_port: Port = undefined,
    background_port: Port = undefined,
};

var extensions: std.ArrayList(*Extension) = .empty;
var managers: ?*c.GPtrArray = null;
var scheme_ready = false;

pub fn idFor(path: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    var id: [32]u8 = undefined;
    for (digest[0..16], 0..) |b, i| {
        id[i * 2] = 'a' + (b >> 4);
        id[i * 2 + 1] = 'a' + (b & 0x0f);
    }
    return id;
}

pub fn pattern(a: std.mem.Allocator, match: []const u8, out: *std.ArrayList(?[*:0]const u8)) !void {
    if (std.mem.eql(u8, match, "<all_urls>")) {
        for ([_][]const u8{ "http://*/*", "https://*/*", "file:///*" }) |p| try out.append(a, (try a.dupeZ(u8, p)).ptr);
        return;
    }
    try out.append(a, (try a.dupeZ(u8, match)).ptr);
}

fn find(id: []const u8) ?*Extension {
    for (extensions.items) |e| if (std.mem.eql(u8, e.id, id)) return e;
    return null;
}

fn get(v: Json, k: []const u8) ?Json {
    if (v != .object) return null;
    return v.object.get(k);
}

fn readFile(a: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]u8 {
    if (!safe(rel)) return error.BadPath;
    const path = try std.fs.path.joinZ(a, &.{ dir, rel });
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(path, &contents, &len, null) == 0) return error.FileNotFound;
    defer c.g_free(contents);
    return a.dupe(u8, contents[0..len]);
}

pub fn safe(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn localeMessages(a: std.mem.Allocator, dir: []const u8, default: ?[]const u8) []const u8 {
    const names = c.g_get_language_names();
    var i: usize = 0;
    while (names[i] != null) : (i += 1) {
        const lang = std.mem.span(names[i]);
        if (std.mem.indexOfAny(u8, lang, ".@") != null or std.mem.eql(u8, lang, "C")) continue;
        const rel = std.fmt.allocPrint(a, "_locales/{s}/messages.json", .{lang}) catch continue;
        if (readFile(a, dir, rel)) |text| return text else |_| {}
    }
    if (default) |d| {
        const rel = std.fmt.allocPrint(a, "_locales/{s}/messages.json", .{d}) catch return "{}";
        if (readFile(a, dir, rel)) |text| return text else |_| {}
    }
    return "{}";
}

fn canonical(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Json, a, text, .{});
    return std.json.Stringify.valueAlloc(a, parsed.value, .{});
}

fn shim(e: *Extension, role: []const u8) ![:0]u8 {
    const a = e.arena.allocator();
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    try o.raw("(function () {\nif (globalThis.chrome && globalThis.chrome.runtime && globalThis.chrome.runtime.id) return;\nconst ID = ");
    try o.str(e.id);
    try o.raw(", ROLE = ");
    try o.str(role);
    try o.raw(", MANIFEST = ");
    try o.raw(e.manifest);
    try o.raw(", MESSAGES = ");
    try o.raw(e.messages);
    try o.raw(";\n");
    try o.raw(SHIM);
    try o.raw("})();\n");
    return a.dupeZ(u8, o.buf.items);
}

fn storagePath(e: *Extension) [*c]u8 {
    return c.g_build_filename(c.g_get_user_data_dir(), "fotone", "extensions", e.id.ptr, "storage.json", @as([*c]const u8, null));
}

fn loadStore(e: *Extension) void {
    const path = storagePath(e);
    defer c.g_free(path);
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(path, &contents, &len, null) == 0) return;
    defer c.g_free(contents);
    const parsed = std.json.parseFromSlice(Json, gpa, contents[0..len], .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| put(e, kv.key_ptr.*, kv.value_ptr.*) catch return;
}

fn put(e: *Extension, k: []const u8, v: Json) !void {
    const text = try std.json.Stringify.valueAlloc(gpa, v, .{});
    errdefer gpa.free(text);
    const slot = try e.store.getOrPut(gpa, k);
    if (slot.found_existing) gpa.free(slot.value_ptr.*) else {
        slot.key_ptr.* = gpa.dupe(u8, k) catch |err| {
            _ = e.store.swapRemove(k);
            return err;
        };
    }
    slot.value_ptr.* = text;
}

fn drop(e: *Extension, k: []const u8) void {
    if (e.store.fetchSwapRemove(k)) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
}

pub fn items(e: *Extension, keys: ?[]const Json, o: *dnr.Out) !void {
    try o.raw("{\"items\":{");
    if (keys) |list| {
        for (list) |k| {
            if (k != .string) continue;
            const v = e.store.get(k.string) orelse continue;
            try o.key(k.string);
            try o.raw(v);
        }
    } else {
        var it = e.store.iterator();
        while (it.next()) |kv| {
            try o.key(kv.key_ptr.*);
            try o.raw(kv.value_ptr.*);
        }
    }
    try o.raw("}}");
}

fn save(e: *Extension) void {
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    o.raw("{") catch return;
    var it = e.store.iterator();
    while (it.next()) |kv| {
        o.key(kv.key_ptr.*) catch return;
        o.raw(kv.value_ptr.*) catch return;
    }
    o.raw("}") catch return;
    const path = storagePath(e);
    defer c.g_free(path);
    const dir = c.g_path_get_dirname(path);
    defer c.g_free(dir);
    _ = c.g_mkdir_with_parents(dir, 0o700);
    var err: [*c]c.GError = null;
    if (c.g_file_set_contents_full(path, o.buf.items.ptr, @intCast(o.buf.items.len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o600, &err) == 0) {
        std.log.warn("fotone extension {s}: {s}", .{ e.id, if (err) |x| std.mem.span(x.*.message) else "storage not saved" });
        c.g_clear_error(&err);
    }
}

const Pending = struct {
    reply: *c.WebKitScriptMessageReply,
    ctx: *c.JSCContext,
};

fn answer(reply: *c.WebKitScriptMessageReply, ctx: *c.JSCContext, text: []const u8) void {
    const z = c.g_strndup(text.ptr, text.len);
    defer c.g_free(z);
    const value = c.jsc_value_new_string(ctx, z);
    defer c.g_object_unref(value);
    c.webkit_script_message_reply_return_value(reply, value);
}

fn fail(reply: *c.WebKitScriptMessageReply, ctx: *c.JSCContext, message: []const u8) void {
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    o.raw("{\"error\":") catch return;
    o.str(message) catch return;
    o.raw("}") catch return;
    answer(reply, ctx, o.buf.items);
}

fn dispatched(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(data));
    defer {
        c.webkit_script_message_reply_unref(p.reply);
        c.g_object_unref(p.ctx);
        c.g_free(p);
    }
    var err: [*c]c.GError = null;
    const value = c.webkit_web_view_call_async_javascript_function_finish(@ptrCast(@alignCast(src)), res, &err);
    if (value == null) {
        defer c.g_clear_error(&err);
        return fail(p.reply, p.ctx, if (err) |x| std.mem.span(x.*.message) else "The message port closed before a response was received.");
    }
    defer c.g_object_unref(value);
    const json = c.jsc_value_to_json(value, 0);
    defer c.g_free(json);
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    o.raw("{\"response\":") catch return;
    o.raw(if (json) |j| std.mem.span(j) else "null") catch return;
    o.raw("}") catch return;
    answer(p.reply, p.ctx, o.buf.items);
}

fn send(e: *Extension, message: ?Json, url: []const u8, reply: *c.WebKitScriptMessageReply, ctx: *c.JSCContext) void {
    const bg = e.background orelse return fail(reply, ctx, "Could not establish connection. Receiving end does not exist.");
    const m = std.json.Stringify.valueAlloc(gpa, message orelse Json{ .null = {} }, .{}) catch return fail(reply, ctx, "Out of memory.");
    defer gpa.free(m);
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    o.raw("{") catch return;
    o.key("id") catch return;
    o.str(e.id) catch return;
    if (url.len > 0) {
        o.key("url") catch return;
        o.str(url) catch return;
    }
    o.raw("}") catch return;
    const mz = c.g_strndup(m.ptr, m.len);
    defer c.g_free(mz);
    const sz = c.g_strndup(o.buf.items.ptr, o.buf.items.len);
    defer c.g_free(sz);
    const dict = c.g_variant_dict_new(null);
    defer c.g_variant_dict_unref(dict);
    c.g_variant_dict_insert_value(dict, "m", c.g_variant_new_string(mz));
    c.g_variant_dict_insert_value(dict, "s", c.g_variant_new_string(sz));
    const p: *Pending = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Pending))));
    p.* = .{ .reply = c.webkit_script_message_reply_ref(reply).?, .ctx = @ptrCast(@alignCast(c.g_object_ref(ctx))) };
    c.webkit_web_view_call_async_javascript_function(bg, "return await __fotoneDispatch(JSON.parse(m), JSON.parse(s));", -1, c.g_variant_dict_end(dict), null, null, null, dispatched, p);
}

pub fn handle(e: *Extension, req: Json, o: *dnr.Out) !bool {
    const op = if (get(req, "op")) |v| (if (v == .string) v.string else "") else "";
    if (std.mem.eql(u8, op, "get")) {
        const keys = get(req, "keys");
        try items(e, if (keys) |k| (if (k == .array) k.array.items else null) else null, o);
        return true;
    }
    if (std.mem.eql(u8, op, "set")) {
        const set = get(req, "items") orelse return error.BadRequest;
        if (set != .object) return error.BadRequest;
        var it = set.object.iterator();
        while (it.next()) |kv| try put(e, kv.key_ptr.*, kv.value_ptr.*);
    } else if (std.mem.eql(u8, op, "remove")) {
        const keys = get(req, "keys") orelse return error.BadRequest;
        if (keys == .array) for (keys.array.items) |k| if (k == .string) drop(e, k.string);
    } else if (std.mem.eql(u8, op, "clear")) {
        while (e.store.count() > 0) drop(e, e.store.keys()[0]);
    } else return error.BadRequest;
    save(e);
    try o.raw("{}");
    return true;
}

fn received(_: ?*c.WebKitUserContentManager, value: ?*c.JSCValue, reply: ?*c.WebKitScriptMessageReply, data: c.gpointer) callconv(.c) c.gboolean {
    const port: *Port = @ptrCast(@alignCast(data));
    const v = value orelse return 0;
    const r = reply orelse return 0;
    const ctx = c.jsc_value_get_context(v) orelse return 0;
    const text = c.jsc_value_to_string(v);
    defer c.g_free(text);
    const parsed = std.json.parseFromSlice(Json, gpa, std.mem.span(text), .{}) catch {
        fail(r, ctx, "Bad request.");
        return 1;
    };
    defer parsed.deinit();
    const op = if (get(parsed.value, "op")) |x| (if (x == .string) x.string else "") else "";
    if (std.mem.eql(u8, op, "send")) {
        if (port.background) {
            fail(r, ctx, "Could not establish connection. Receiving end does not exist.");
            return 1;
        }
        const url = if (get(parsed.value, "url")) |x| (if (x == .string) x.string else "") else "";
        send(port.ext, get(parsed.value, "message"), url, r, ctx);
        return 1;
    }
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    _ = handle(port.ext, parsed.value, &o) catch {
        fail(r, ctx, "Bad request.");
        return 1;
    };
    answer(r, ctx, o.buf.items);
    return 1;
}

fn serve(request: ?*c.WebKitURISchemeRequest, _: c.gpointer) callconv(.c) void {
    const req = request orelse return;
    const uri = c.g_uri_parse(c.webkit_uri_scheme_request_get_uri(req), c.G_URI_FLAGS_NONE, null);
    const e: ?*Extension = if (uri) |u| (if (c.g_uri_get_host(u)) |h| find(std.mem.span(h)) else null) else null;
    defer if (uri) |u| c.g_uri_unref(u);
    const ext = e orelse return notFound(req);
    const path = std.mem.span(c.g_uri_get_path(uri.?));
    if (std.mem.eql(u8, path, BACKGROUND_PAGE)) {
        const worker = ext.worker orelse return notFound(req);
        const page = std.fmt.allocPrintSentinel(gpa, "<!doctype html><meta charset=\"utf-8\"><script src=\"/{s}\"{s}></script>", .{ worker, if (ext.module) " type=\"module\"" else "" }, 0) catch return notFound(req);
        const bytes = c.g_bytes_new_take(page.ptr, page.len);
        const stream = c.g_memory_input_stream_new_from_bytes(bytes);
        c.g_bytes_unref(bytes);
        defer c.g_object_unref(stream);
        return c.webkit_uri_scheme_request_finish(req, stream, @intCast(page.len), "text/html");
    }
    const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (!safe(rel)) return notFound(req);
    const full = std.fs.path.joinZ(gpa, &.{ ext.dir, rel }) catch return notFound(req);
    defer gpa.free(full);
    const file = c.g_file_new_for_path(full);
    defer c.g_object_unref(file);
    const stream = c.g_file_read(file, null, null) orelse return notFound(req);
    defer c.g_object_unref(stream);
    var size: i64 = -1;
    if (c.g_file_query_info(file, c.G_FILE_ATTRIBUTE_STANDARD_SIZE, c.G_FILE_QUERY_INFO_NONE, null, null)) |info| {
        size = c.g_file_info_get_size(info);
        c.g_object_unref(info);
    }
    const kind = c.g_content_type_guess(full, null, 0, null);
    defer c.g_free(kind);
    const mime = c.g_content_type_get_mime_type(kind);
    defer c.g_free(mime);
    c.webkit_uri_scheme_request_finish(req, @ptrCast(stream), size, if (std.mem.endsWith(u8, rel, ".js") or std.mem.endsWith(u8, rel, ".mjs")) "text/javascript" else mime);
}

fn notFound(req: *c.WebKitURISchemeRequest) void {
    const err = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_NOT_FOUND, "Not found");
    defer c.g_error_free(err);
    c.webkit_uri_scheme_request_finish_error(req, err);
}

fn prepareScheme() void {
    if (scheme_ready) return;
    scheme_ready = true;
    const ctx = c.webkit_web_context_get_default();
    c.webkit_web_context_register_uri_scheme(ctx, SCHEME, serve, null, null);
    const security = c.webkit_web_context_get_security_manager(ctx);
    c.webkit_security_manager_register_uri_scheme_as_secure(security, SCHEME);
    c.webkit_security_manager_register_uri_scheme_as_cors_enabled(security, SCHEME);
}

fn attachTo(e: *Extension, ucm: *c.WebKitUserContentManager) void {
    if (c.webkit_user_content_manager_register_script_message_handler_with_reply(ucm, e.handler, e.world) == 0) return;
    const signal = std.fmt.allocPrintSentinel(gpa, "script-message-with-reply-received::{s}", .{e.handler}, 0) catch return;
    defer gpa.free(signal);
    _ = c.g_signal_connect_data(ucm, signal, @ptrCast(&received), &e.content_port, null, 0);
    for (e.scripts.items) |s| {
        c.webkit_user_content_manager_add_script(ucm, s.script);
        if (s.sheet) |sheet| c.webkit_user_content_manager_add_style_sheet(ucm, sheet);
    }
}

fn detachFrom(e: *Extension, ucm: *c.WebKitUserContentManager) void {
    _ = c.g_signal_handlers_disconnect_matched(ucm, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, &e.content_port);
    c.webkit_user_content_manager_unregister_script_message_handler(ucm, e.handler, e.world);
    for (e.scripts.items) |s| {
        c.webkit_user_content_manager_remove_script(ucm, s.script);
        if (s.sheet) |sheet| c.webkit_user_content_manager_remove_style_sheet(ucm, sheet);
    }
}

fn managerGone(_: c.gpointer, gone: [*c]c.GObject) callconv(.c) void {
    if (managers) |m| _ = c.g_ptr_array_remove(m, gone);
}

pub fn track(ucm: *c.WebKitUserContentManager) void {
    if (managers == null) managers = c.g_ptr_array_new();
    if (c.g_ptr_array_find(managers, ucm, null) != 0) return;
    c.g_ptr_array_add(managers, ucm);
    c.g_object_weak_ref(@ptrCast(@alignCast(ucm)), managerGone, null);
    for (extensions.items) |e| attachTo(e, ucm);
}

fn eachManager(e: *Extension, f: *const fn (*Extension, *c.WebKitUserContentManager) void) void {
    const m = managers orelse return;
    var i: c.guint = 0;
    while (i < m.*.len) : (i += 1) f(e, @ptrCast(@alignCast(m.*.pdata[i])));
}

fn strings(a: std.mem.Allocator, v: ?Json, out: *std.ArrayList(?[*:0]const u8)) !void {
    const list = v orelse return;
    if (list != .array) return;
    for (list.array.items) |m| if (m == .string) try pattern(a, m.string, out);
}

fn contentScripts(e: *Extension, manifest: Json) !void {
    const a = e.arena.allocator();
    const list = get(manifest, "content_scripts") orelse return;
    if (list != .array) return;
    const prelude = try shim(e, "content");
    for (list.array.items) |cs| {
        var allow: std.ArrayList(?[*:0]const u8) = .empty;
        try strings(a, get(cs, "matches"), &allow);
        if (allow.items.len == 0) continue;
        try allow.append(a, null);
        var block: std.ArrayList(?[*:0]const u8) = .empty;
        try strings(a, get(cs, "exclude_matches"), &block);
        try block.append(a, null);
        const frames: c.WebKitUserContentInjectedFrames = if (get(cs, "all_frames")) |f| (if (f == .bool and f.bool) c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES else c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME) else c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME;
        const at: c.WebKitUserScriptInjectionTime = if (get(cs, "run_at")) |r| (if (r == .string and std.mem.eql(u8, r.string, "document_start")) c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START else c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END) else c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END;
        var source: std.ArrayList(u8) = .empty;
        try source.appendSlice(a, prelude);
        if (get(cs, "js")) |js| if (js == .array) for (js.array.items) |f| if (f == .string) {
            try source.appendSlice(a, try readFile(a, e.dir, f.string));
            try source.appendSlice(a, "\n;\n");
        };
        try source.append(a, 0);
        const script = c.webkit_user_script_new_for_world(@ptrCast(source.items.ptr), frames, at, e.world, @ptrCast(allow.items.ptr), @ptrCast(block.items.ptr)).?;
        var sheet: ?*c.WebKitUserStyleSheet = null;
        if (get(cs, "css")) |css| if (css == .array and css.array.items.len > 0) {
            var text: std.ArrayList(u8) = .empty;
            for (css.array.items) |f| if (f == .string) {
                try text.appendSlice(a, try readFile(a, e.dir, f.string));
                try text.append(a, '\n');
            };
            try text.append(a, 0);
            sheet = c.webkit_user_style_sheet_new_for_world(@ptrCast(text.items.ptr), frames, c.WEBKIT_USER_STYLE_LEVEL_USER, e.world, @ptrCast(allow.items.ptr), @ptrCast(block.items.ptr));
        };
        try e.scripts.append(a, .{ .script = script, .sheet = sheet });
    }
}

fn ruleSets(e: *Extension, manifest: Json) !void {
    const a = e.arena.allocator();
    const dnr_key = get(manifest, "declarative_net_request") orelse return;
    const list = get(dnr_key, "rule_resources") orelse return;
    if (list != .array) return;
    for (list.array.items) |r| {
        if (get(r, "enabled")) |en| if (en == .bool and !en.bool) continue;
        const path = get(r, "path") orelse continue;
        const rid = get(r, "id") orelse continue;
        if (path != .string or rid != .string) continue;
        const rules = readFile(a, e.dir, path.string) catch continue;
        const id = try std.fmt.allocPrintSentinel(a, "ext-{s}-{s}", .{ e.id, rid.string }, 0);
        const res = dnr.install(id, rules, null, null) catch |err| {
            std.log.warn("fotone extension {s}: rule set {s}: {s}", .{ e.id, rid.string, @errorName(err) });
            continue;
        };
        res.deinit();
        try e.rule_sets.append(a, id);
    }
}

fn started(src: [*c]c.GObject, res: ?*c.GAsyncResult, _: c.gpointer) callconv(.c) void {
    const v = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(@alignCast(src)), res, null);
    if (v) |x| c.g_object_unref(x);
}

fn backgroundLoaded(web: ?*c.WebKitWebView, event: c.WebKitLoadEvent, data: c.gpointer) callconv(.c) void {
    if (event != c.WEBKIT_LOAD_FINISHED) return;
    const e: *Extension = @ptrCast(@alignCast(data));
    _ = c.g_signal_handlers_disconnect_matched(web, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @ptrCast(@constCast(&backgroundLoaded)), data);
    const path = storagePath(e);
    defer c.g_free(path);
    const first = c.g_file_test(path, c.G_FILE_TEST_EXISTS) == 0;
    if (first) save(e);
    const script: [*:0]const u8 = if (first) "__fotoneStarted(true)" else "__fotoneStarted(false)";
    c.webkit_web_view_evaluate_javascript(web, script, -1, null, null, null, started, null);
}

fn startBackground(e: *Extension, display: ?*c.WPEDisplay) !void {
    if (e.worker == null) return;
    const ucm = c.webkit_user_content_manager_new().?;
    defer c.g_object_unref(ucm);
    const prelude = try shim(e, "background");
    const allow = [_:null]?[*:0]const u8{try std.fmt.allocPrintSentinel(e.arena.allocator(), SCHEME ++ "://{s}/*", .{e.id}, 0)};
    const script = c.webkit_user_script_new(prelude, c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, @ptrCast(&allow), null);
    defer c.webkit_user_script_unref(script);
    c.webkit_user_content_manager_add_script(ucm, script);
    if (c.webkit_user_content_manager_register_script_message_handler_with_reply(ucm, e.handler, null) == 0) return error.Handler;
    const signal = try std.fmt.allocPrintSentinel(gpa, "script-message-with-reply-received::{s}", .{e.handler}, 0);
    defer gpa.free(signal);
    _ = c.g_signal_connect_data(ucm, signal, @ptrCast(&received), &e.background_port, null, 0);
    const web: *c.WebKitWebView = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "display", display, "user-content-manager", ucm, @as([*c]const u8, null))));
    e.background = @ptrCast(@alignCast(c.g_object_ref_sink(web)));
    _ = c.g_signal_connect_data(web, "load-changed", @ptrCast(&backgroundLoaded), e, null, 0);
    const uri = try std.fmt.allocPrintSentinel(gpa, SCHEME ++ "://{s}" ++ BACKGROUND_PAGE, .{e.id}, 0);
    defer gpa.free(uri);
    c.webkit_web_view_load_uri(web, uri);
}

pub fn install(path: []const u8, display: ?*c.WPEDisplay) ![:0]const u8 {
    prepareScheme();
    const e = try gpa.create(Extension);
    e.* = .{ .arena = .init(gpa), .id = undefined, .dir = undefined, .world = undefined, .handler = undefined, .manifest = undefined, .messages = undefined, .worker = null, .module = false };
    errdefer {
        e.arena.deinit();
        gpa.destroy(e);
    }
    const a = e.arena.allocator();
    const abs = c.g_canonicalize_filename(try a.dupeZ(u8, path), null);
    defer c.g_free(abs);
    e.dir = try a.dupeZ(u8, std.mem.span(abs));
    e.id = try a.dupeZ(u8, &idFor(e.dir));
    if (find(e.id)) |old| remove(old.id);
    e.world = try std.fmt.allocPrintSentinel(a, "fotone-ext-{s}", .{e.id}, 0);
    e.handler = try std.fmt.allocPrintSentinel(a, "fotoneExt_{s}", .{e.id}, 0);
    e.content_port = .{ .ext = e, .background = false };
    e.background_port = .{ .ext = e, .background = true };
    const raw = try readFile(a, e.dir, "manifest.json");
    const manifest = try std.json.parseFromSliceLeaky(Json, a, raw, .{});
    const version = get(manifest, "manifest_version") orelse return error.NotManifestV3;
    if (version != .integer or version.integer != 3) return error.NotManifestV3;
    e.manifest = try std.json.Stringify.valueAlloc(a, manifest, .{});
    const default = if (get(manifest, "default_locale")) |d| (if (d == .string) d.string else null) else null;
    e.messages = canonical(a, localeMessages(a, e.dir, default)) catch "{}";
    if (get(manifest, "background")) |bg| {
        if (get(bg, "service_worker")) |w| if (w == .string and safe(w.string)) {
            e.worker = w.string;
        };
        if (get(bg, "type")) |t| e.module = t == .string and std.mem.eql(u8, t.string, "module");
    }
    try contentScripts(e, manifest);
    loadStore(e);
    try extensions.append(gpa, e);
    eachManager(e, attachTo);
    try ruleSets(e, manifest);
    try startBackground(e, display);
    return e.id;
}

pub fn remove(id: []const u8) void {
    const e = find(id) orelse return;
    eachManager(e, detachFrom);
    for (e.rule_sets.items) |r| dnr.remove(r);
    if (e.background) |bg| {
        c.webkit_web_view_terminate_web_process(bg);
        c.g_object_unref(bg);
    }
    for (e.scripts.items) |s| {
        c.webkit_user_script_unref(s.script);
        if (s.sheet) |sheet| c.webkit_user_style_sheet_unref(sheet);
    }
    var it = e.store.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        gpa.free(kv.value_ptr.*);
    }
    e.store.deinit(gpa);
    for (extensions.items, 0..) |x, i| if (x == e) {
        _ = extensions.swapRemove(i);
        break;
    };
    e.arena.deinit();
    gpa.destroy(e);
}

test "extension ids are stable and use the a to p alphabet" {
    const a = idFor("/usr/share/fotone/extensions/hello");
    const b = idFor("/usr/share/fotone/extensions/hello");
    try std.testing.expectEqualSlices(u8, &a, &b);
    for (a) |ch| try std.testing.expect(ch >= 'a' and ch <= 'p');
    try std.testing.expect(!std.mem.eql(u8, &a, &idFor("/other")));
}

test "paths inside the extension stay inside it" {
    try std.testing.expect(safe("content/main.js"));
    try std.testing.expect(!safe("../secret"));
    try std.testing.expect(!safe("a/../../b"));
    try std.testing.expect(!safe("/etc/passwd"));
    try std.testing.expect(!safe(""));
}

test "all_urls covers web and file pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(?[*:0]const u8) = .empty;
    try pattern(arena.allocator(), "<all_urls>", &out);
    try pattern(arena.allocator(), "https://*.example.org/*", &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("https://*.example.org/*", std.mem.span(out.items[3].?));
}

test "storage keeps json values by key" {
    var e: Extension = .{ .arena = .init(gpa), .id = "t", .dir = "/nonexistent", .world = "w", .handler = "h", .manifest = "{}", .messages = "{}", .worker = null, .module = false };
    defer {
        var it = e.store.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        e.store.deinit(gpa);
        e.arena.deinit();
    }
    const parsed = try std.json.parseFromSlice(Json, gpa, "{\"n\":41,\"s\":\"x\",\"o\":{\"a\":[1,2]}}", .{});
    defer parsed.deinit();
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| try put(&e, kv.key_ptr.*, kv.value_ptr.*);
    try put(&e, "n", .{ .integer = 42 });
    var o: dnr.Out = .{};
    defer o.buf.deinit(gpa);
    const keys = [_]Json{ .{ .string = "n" }, .{ .string = "o" }, .{ .string = "missing" } };
    try items(&e, &keys, &o);
    try std.testing.expectEqualStrings("{\"items\":{\"n\":42,\"o\":{\"a\":[1,2]}}}", o.buf.items);
    drop(&e, "s");
    try std.testing.expectEqual(@as(usize, 2), e.store.count());
}
