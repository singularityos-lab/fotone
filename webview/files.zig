const std = @import("std");
const c = @import("c.zig").c;

const HANDLER = "fotoneFiles";
const MAX_READ = 256 << 20;

const SCRIPT =
    \\(function () {
    \\  if (window.showOpenFilePicker || !window.webkit || !window.webkit.messageHandlers.fotoneFiles) return;
    \\  const port = window.webkit.messageHandlers.fotoneFiles;
    \\  const call = async (req) => {
    \\    const r = JSON.parse(await port.postMessage(JSON.stringify(req)));
    \\    if (r.error) throw new DOMException(r.message || r.error, r.error);
    \\    return r;
    \\  };
    \\  const decode = (s) => { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; };
    \\  const encode = (u) => { let s = ""; for (let i = 0; i < u.length; i += 32768) s += String.fromCharCode.apply(null, u.subarray(i, i + 32768)); return btoa(s); };
    \\  const gesture = () => {
    \\    if (window.top !== window) throw new DOMException("Cross origin sub frames aren't allowed to show a file picker.", "SecurityError");
    \\    if (navigator.userActivation && !navigator.userActivation.isActive) throw new DOMException("Must be handling a user gesture to show a file picker.", "SecurityError");
    \\  };
    \\  const make = (e) => e.kind === "directory" ? new DirectoryHandle(e) : new FileHandle(e);
    \\  const bytesOf = async (d) => {
    \\    if (typeof d === "string") return new TextEncoder().encode(d);
    \\    if (d instanceof Blob) return new Uint8Array(await d.arrayBuffer());
    \\    if (d instanceof ArrayBuffer) return new Uint8Array(d);
    \\    if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
    \\    throw new TypeError("Invalid data for a file write.");
    \\  };
    \\  class Handle {
    \\    constructor(e) { Object.defineProperty(this, "kind", { value: e.kind, enumerable: true }); Object.defineProperty(this, "name", { value: e.name, enumerable: true }); Object.defineProperty(this, "id", { value: e.id }); }
    \\    async isSameEntry(o) { return o instanceof Handle && (await call({ op: "same", a: this.id, b: o.id })).same; }
    \\    async queryPermission(d) { return (await call({ op: "query", id: this.id, write: !!(d && d.mode === "readwrite") })).state; }
    \\    async requestPermission(d) { return (await call({ op: "permit", id: this.id, write: !!(d && d.mode === "readwrite") })).state; }
    \\  }
    \\  class Writable extends WritableStream {
    \\    constructor(id, data) {
    \\      const st = { data, size: data.length, pos: 0 };
    \\      const put = (u, at) => {
    \\        const end = at + u.length;
    \\        if (end > st.data.length) { const n = new Uint8Array(Math.max(end, st.data.length * 2)); n.set(st.data.subarray(0, st.size)); st.data = n; }
    \\        if (at > st.size) st.data.fill(0, st.size, at);
    \\        st.data.set(u, at); st.size = Math.max(st.size, end); st.pos = end;
    \\      };
    \\      super({
    \\        write: async (chunk) => {
    \\          if (chunk && typeof chunk === "object" && "type" in chunk && !(chunk instanceof Blob) && !ArrayBuffer.isView(chunk) && !(chunk instanceof ArrayBuffer)) {
    \\            if (chunk.type === "seek") { st.pos = chunk.position; return; }
    \\            if (chunk.type === "truncate") { if (chunk.size > st.size) put(new Uint8Array(0), chunk.size); st.size = chunk.size; st.pos = Math.min(st.pos, st.size); return; }
    \\            put(await bytesOf(chunk.data), chunk.position ?? st.pos); return;
    \\          }
    \\          put(await bytesOf(chunk), st.pos);
    \\        },
    \\        close: async () => { await call({ op: "write", id, data: encode(st.data.subarray(0, st.size)) }); },
    \\      });
    \\    }
    \\    async write(d) { const w = this.getWriter(); try { await w.write(d); } finally { w.releaseLock(); } }
    \\    async seek(position) { return this.write({ type: "seek", position }); }
    \\    async truncate(size) { return this.write({ type: "truncate", size }); }
    \\    async close() { const w = this.getWriter(); try { await w.close(); } finally { w.releaseLock(); } }
    \\  }
    \\  class FileHandle extends Handle {
    \\    async getFile() { const r = await call({ op: "read", id: this.id }); return new File([decode(r.data)], this.name, { type: r.type, lastModified: r.modified }); }
    \\    async createWritable(o) {
    \\      await call({ op: "permit", id: this.id, write: true, need: true });
    \\      const keep = o && o.keepExistingData;
    \\      return new Writable(this.id, keep ? decode((await call({ op: "read", id: this.id })).data) : new Uint8Array(0));
    \\    }
    \\  }
    \\  class DirectoryHandle extends Handle {
    \\    async *entries() { for (const e of (await call({ op: "list", id: this.id })).entries) yield [e.name, make(e)]; }
    \\    async *values() { for await (const [, h] of this.entries()) yield h; }
    \\    async *keys() { for await (const [n] of this.entries()) yield n; }
    \\    [Symbol.asyncIterator]() { return this.entries(); }
    \\    async getFileHandle(name, o) { return make(await call({ op: "child", id: this.id, name: String(name), kind: "file", create: !!(o && o.create) })); }
    \\    async getDirectoryHandle(name, o) { return make(await call({ op: "child", id: this.id, name: String(name), kind: "directory", create: !!(o && o.create) })); }
    \\    async removeEntry(name, o) { await call({ op: "remove", id: this.id, name: String(name), recursive: !!(o && o.recursive) }); }
    \\    async resolve(h) { return h instanceof Handle ? (await call({ op: "resolve", id: this.id, target: h.id })).path : null; }
    \\  }
    \\  const types = (o) => (o && o.types || []).map((t) => ({ description: t.description || "", accept: Object.entries(t.accept || {}).map(([m, e]) => [m, [].concat(e)]) }));
    \\  window.showOpenFilePicker = async (o) => { gesture(); return (await call({ op: "open", multiple: !!(o && o.multiple), all: !(o && o.excludeAcceptAllOption), types: types(o) })).handles.map(make); };
    \\  window.showSaveFilePicker = async (o) => { gesture(); return make(await call({ op: "save", name: String(o && o.suggestedName || ""), all: !(o && o.excludeAcceptAllOption), types: types(o) })); };
    \\  window.showDirectoryPicker = async (o) => { gesture(); return make(await call({ op: "dir", write: !!(o && o.mode === "readwrite") })); };
    \\})();
;

const Grant = struct {
    owner: usize,
    path: [*c]u8,
    dir: bool,
    write: bool,
};

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var grants: ?*c.GPtrArray = null;
var index: ?*c.GHashTable = null;

fn grantKey(owner: usize, path: [*c]const u8) [*c]u8 {
    return c.g_strdup_printf("%zx:%s", owner, path);
}

pub fn grant(owner: usize, path: [*c]const u8, dir: bool, write: bool) usize {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    if (grants == null) {
        grants = c.g_ptr_array_new();
        index = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
    }
    const key = grantKey(owner, path);
    if (c.g_hash_table_lookup(index, key)) |found| {
        c.g_free(key);
        const id = @intFromPtr(found);
        const g: *Grant = @ptrCast(@alignCast(grants.?.pdata[id - 1]));
        g.dir = dir;
        if (write) g.write = true;
        return id;
    }
    const g: *Grant = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Grant))));
    g.* = .{ .owner = owner, .path = c.g_strdup(path), .dir = dir, .write = write };
    c.g_ptr_array_add(grants, g);
    const id: usize = grants.?.len;
    _ = c.g_hash_table_insert(index, key, @ptrFromInt(id));
    return id;
}

fn lookup(owner: usize, id: usize) ?Grant {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    const all = grants orelse return null;
    if (id == 0 or id > all.len) return null;
    const g: *Grant = @ptrCast(@alignCast(all.pdata[id - 1]));
    if (g.owner != owner or g.path == null) return null;
    return .{ .owner = g.owner, .path = c.g_strdup(g.path), .dir = g.dir, .write = g.write };
}

fn allowWrite(owner: usize, id: usize) void {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    const all = grants orelse return;
    if (id == 0 or id > all.len) return;
    const g: *Grant = @ptrCast(@alignCast(all.pdata[id - 1]));
    if (g.owner == owner) g.write = true;
}

pub fn revoke(owner: usize) void {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    const all = grants orelse return;
    var i: c.guint = 0;
    while (i < all.len) : (i += 1) {
        const g: *Grant = @ptrCast(@alignCast(all.pdata[i]));
        if (g.owner != owner or g.path == null) continue;
        const key = grantKey(owner, g.path);
        defer c.g_free(key);
        _ = c.g_hash_table_remove(index, key);
        c.g_free(g.path);
        g.path = null;
        g.owner = 0;
    }
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

const Out = struct {
    s: *c.GString,

    fn init() Out {
        return .{ .s = c.g_string_new(null) };
    }

    fn raw(o: Out, t: []const u8) void {
        _ = c.g_string_append_len(o.s, t.ptr, @intCast(t.len));
    }

    fn str(o: Out, t: []const u8) void {
        const valid = c.g_utf8_make_valid(t.ptr, @intCast(t.len));
        defer c.g_free(valid);
        o.raw("\"");
        for (std.mem.span(valid)) |ch| switch (ch) {
            '"' => o.raw("\\\""),
            '\\' => o.raw("\\\\"),
            0...0x1f => _ = c.g_string_append_printf(o.s, "\\u%04x", @as(c_uint, ch)),
            else => _ = c.g_string_append_c(o.s, @intCast(ch)),
        };
        o.raw("\"");
    }

    fn entry(o: Out, id: usize, name: []const u8, dir: bool) void {
        _ = c.g_string_append_printf(o.s, "{\"id\":%zu,\"kind\":\"%s\",\"name\":", id, @as([*:0]const u8, if (dir) "directory" else "file"));
        o.str(name);
        o.raw("}");
    }

    fn done(o: Out) [*c]u8 {
        return c.g_string_free(o.s, 0);
    }
};

fn fail(name: []const u8, message: []const u8) [*c]u8 {
    const o = Out.init();
    o.raw("{\"error\":");
    o.str(name);
    o.raw(",\"message\":");
    o.str(message);
    o.raw("}");
    return o.done();
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn num(v: std.json.Value, name: []const u8) usize {
    const f = field(v, name) orelse return 0;
    return if (f == .integer and f.integer > 0) @intCast(f.integer) else 0;
}

fn flag(v: std.json.Value, name: []const u8) bool {
    const f = field(v, name) orelse return false;
    return f == .bool and f.bool;
}

fn text(v: std.json.Value, name: []const u8) []const u8 {
    const f = field(v, name) orelse return "";
    return if (f == .string) f.string else "";
}

fn baseName(path: [*c]const u8) [*c]u8 {
    return c.g_path_get_basename(path);
}

fn kindOf(path: [*c]const u8) c.GFileType {
    const f = c.g_file_new_for_path(path);
    defer c.g_object_unref(f);
    return c.g_file_query_file_type(f, c.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null);
}

fn notFound() [*c]u8 {
    return fail("NotFoundError", "A requested file or directory could not be found at the time an operation was processed.");
}

fn mismatch() [*c]u8 {
    return fail("TypeMismatchError", "The path supplied exists, but was not an entry of requested type.");
}

fn denied() [*c]u8 {
    return fail("NotAllowedError", "The request is not allowed by the user agent or the platform in the current context.");
}

fn read(g: Grant) [*c]u8 {
    if (g.dir) return mismatch();
    const f = c.g_file_new_for_path(g.path);
    defer c.g_object_unref(f);
    const info = c.g_file_query_info(f, "standard::size,time::modified,time::modified-usec", c.G_FILE_QUERY_INFO_NONE, null, null) orelse return notFound();
    defer c.g_object_unref(info);
    if (c.g_file_info_get_size(info) > MAX_READ) return fail("NotReadableError", "The file is too large to read.");
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(g.path, &data, &len, null) == 0) return fail("NotReadableError", "The requested file could not be read.");
    defer c.g_free(data);
    const modified = c.g_file_info_get_attribute_uint64(info, "time::modified") * 1000 + c.g_file_info_get_attribute_uint32(info, "time::modified-usec") / 1000;
    const name = baseName(g.path);
    defer c.g_free(name);
    const guess = c.g_content_type_guess(name, null, 0, null);
    defer c.g_free(guess);
    const mime = c.g_content_type_get_mime_type(guess);
    defer c.g_free(mime);
    const b64 = c.g_base64_encode(data, len);
    defer c.g_free(b64);
    const o = Out.init();
    _ = c.g_string_append_printf(o.s, "{\"modified\":%" ++ "llu" ++ ",\"type\":", @as(c_ulonglong, modified));
    o.str(if (mime != null and !std.mem.eql(u8, std.mem.span(mime), "application/octet-stream")) std.mem.span(mime) else "");
    o.raw(",\"data\":\"");
    o.raw(std.mem.span(b64));
    o.raw("\"}");
    return o.done();
}

fn save(g: Grant, data: []const u8) [*c]u8 {
    if (g.dir) return mismatch();
    if (!g.write) return denied();
    const z = c.g_strndup(data.ptr, data.len);
    defer c.g_free(z);
    var len: usize = 0;
    const bytes = c.g_base64_decode(z, &len);
    defer c.g_free(bytes);
    if (c.g_file_set_contents_full(g.path, @ptrCast(bytes), @intCast(len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o644, null) == 0)
        return fail("NoModificationAllowedError", "The file could not be written.");
    return c.g_strdup("{}");
}

fn list(owner: usize, g: Grant) [*c]u8 {
    if (!g.dir) return mismatch();
    const f = c.g_file_new_for_path(g.path);
    defer c.g_object_unref(f);
    const it = c.g_file_enumerate_children(f, "standard::name,standard::type", c.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null, null) orelse return notFound();
    defer c.g_object_unref(it);
    const o = Out.init();
    o.raw("{\"entries\":[");
    var first = true;
    while (c.g_file_enumerator_next_file(it, null, null)) |info| {
        defer c.g_object_unref(info);
        const t = c.g_file_info_get_file_type(info);
        if (t != c.G_FILE_TYPE_REGULAR and t != c.G_FILE_TYPE_DIRECTORY) continue;
        const name = c.g_file_info_get_name(info);
        const path = c.g_build_filename(g.path, name, @as(?*anyopaque, null));
        defer c.g_free(path);
        const dir = t == c.G_FILE_TYPE_DIRECTORY;
        if (!first) o.raw(",");
        first = false;
        o.entry(grant(owner, path, dir, g.write), std.mem.span(name), dir);
    }
    o.raw("]}");
    return o.done();
}

fn child(owner: usize, g: Grant, name: []const u8, dir: bool, create: bool) [*c]u8 {
    if (!g.dir) return mismatch();
    if (!validName(name)) return fail("TypeError", "Name is not allowed.");
    const z = c.g_strndup(name.ptr, name.len);
    defer c.g_free(z);
    const path = c.g_build_filename(g.path, z, @as(?*anyopaque, null));
    defer c.g_free(path);
    const t = kindOf(path);
    if (t == c.G_FILE_TYPE_UNKNOWN) {
        if (!create) return notFound();
        if (!g.write) return denied();
        const ok = if (dir) c.g_mkdir_with_parents(path, 0o755) == 0 else c.g_file_set_contents_full(path, "", 0, c.G_FILE_SET_CONTENTS_NONE, 0o644, null) != 0;
        if (!ok) return fail("NoModificationAllowedError", "The entry could not be created.");
    } else if ((t == c.G_FILE_TYPE_DIRECTORY) != dir or (t != c.G_FILE_TYPE_DIRECTORY and t != c.G_FILE_TYPE_REGULAR)) return mismatch();
    const o = Out.init();
    o.entry(grant(owner, path, dir, g.write), name, dir);
    return o.done();
}

fn wipe(f: ?*c.GFile) bool {
    if (c.g_file_query_file_type(f, c.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null) == c.G_FILE_TYPE_DIRECTORY) {
        const it = c.g_file_enumerate_children(f, "standard::name", c.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, null, null) orelse return false;
        defer c.g_object_unref(it);
        while (c.g_file_enumerator_next_file(it, null, null)) |info| {
            defer c.g_object_unref(info);
            const sub = c.g_file_get_child(f, c.g_file_info_get_name(info));
            defer c.g_object_unref(sub);
            if (!wipe(sub)) return false;
        }
    }
    return c.g_file_delete(f, null, null) != 0;
}

fn remove(g: Grant, name: []const u8, recursive: bool) [*c]u8 {
    if (!g.dir) return mismatch();
    if (!g.write) return denied();
    if (!validName(name)) return fail("TypeError", "Name is not allowed.");
    const z = c.g_strndup(name.ptr, name.len);
    defer c.g_free(z);
    const path = c.g_build_filename(g.path, z, @as(?*anyopaque, null));
    defer c.g_free(path);
    const t = kindOf(path);
    if (t == c.G_FILE_TYPE_UNKNOWN) return notFound();
    const f = c.g_file_new_for_path(path);
    defer c.g_object_unref(f);
    if (t == c.G_FILE_TYPE_DIRECTORY and !recursive) {
        if (c.g_file_delete(f, null, null) == 0) return fail("InvalidModificationError", "The directory is not empty.");
        return c.g_strdup("{}");
    }
    if (!wipe(f)) return fail("NoModificationAllowedError", "The entry could not be removed.");
    return c.g_strdup("{}");
}

fn resolve(base: Grant, target: Grant) [*c]u8 {
    const b = std.mem.span(base.path);
    const t = std.mem.span(target.path);
    if (std.mem.eql(u8, b, t)) return c.g_strdup("{\"path\":[]}");
    if (t.len <= b.len or !std.mem.startsWith(u8, t, b) or t[b.len] != '/') return c.g_strdup("{\"path\":null}");
    const o = Out.init();
    o.raw("{\"path\":[");
    var it = std.mem.splitScalar(u8, t[b.len + 1 ..], '/');
    var first = true;
    while (it.next()) |part| {
        if (!first) o.raw(",");
        first = false;
        o.str(part);
    }
    o.raw("]}");
    return o.done();
}

pub fn handle(owner: usize, req: []const u8) [*c]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, req, .{}) catch return fail("TypeError", "Bad request.");
    defer parsed.deinit();
    const v = parsed.value;
    const op = text(v, "op");
    if (std.mem.eql(u8, op, "same")) {
        const a = lookup(owner, num(v, "a")) orelse return notFound();
        defer c.g_free(a.path);
        const b = lookup(owner, num(v, "b")) orelse return notFound();
        defer c.g_free(b.path);
        return c.g_strdup(if (std.mem.eql(u8, std.mem.span(a.path), std.mem.span(b.path)) and a.dir == b.dir) "{\"same\":true}" else "{\"same\":false}");
    }
    const g = lookup(owner, num(v, "id")) orelse return notFound();
    defer c.g_free(g.path);
    if (std.mem.eql(u8, op, "query") or std.mem.eql(u8, op, "permit"))
        return c.g_strdup(if (!flag(v, "write") or g.write) "{\"state\":\"granted\"}" else if (flag(v, "need")) "{\"error\":\"NotAllowedError\",\"message\":\"Write permission was not granted.\"}" else "{\"state\":\"prompt\"}");
    if (std.mem.eql(u8, op, "read")) return read(g);
    if (std.mem.eql(u8, op, "write")) return save(g, text(v, "data"));
    if (std.mem.eql(u8, op, "list")) return list(owner, g);
    if (std.mem.eql(u8, op, "child")) return child(owner, g, text(v, "name"), std.mem.eql(u8, text(v, "kind"), "directory"), flag(v, "create"));
    if (std.mem.eql(u8, op, "remove")) return remove(g, text(v, "name"), flag(v, "recursive"));
    if (std.mem.eql(u8, op, "resolve")) {
        const t = lookup(owner, num(v, "target")) orelse return c.g_strdup("{\"path\":null}");
        defer c.g_free(t.path);
        return resolve(g, t);
    }
    return fail("TypeError", "Unknown operation.");
}

const Call = struct {
    web: *c.WebKitWebView,
    reply: *c.WebKitScriptMessageReply,
    ctx: *c.JSCContext,
    req: [*c]u8,
    multiple: bool = false,
    wrap: bool = false,
    write: bool = false,
    id: usize = 0,
};

fn answer(call: *Call, json: [*c]u8) void {
    defer c.g_free(json);
    const value = c.jsc_value_new_string(call.ctx, json);
    defer c.g_object_unref(value);
    c.webkit_script_message_reply_return_value(call.reply, value);
    c.webkit_script_message_reply_unref(call.reply);
    c.g_object_unref(call.ctx);
    c.g_object_unref(call.web);
    c.g_free(call.req);
    c.g_free(call);
}

fn work(task: ?*c.GTask, _: c.gpointer, data: c.gpointer, _: ?*c.GCancellable) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    c.g_task_return_pointer(task, handle(@intFromPtr(call.web), std.mem.span(call.req)), c.g_free);
}

fn worked(_: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    answer(call, @ptrCast(c.g_task_propagate_pointer(@ptrCast(res), null)));
}

fn windowOf(web: *c.WebKitWebView) ?*c.GtkWindow {
    const w = c.g_object_get_data(@ptrCast(web), "fotone-widget") orelse return null;
    const root = c.gtk_widget_get_root(@ptrCast(@alignCast(w))) orelse return null;
    return @ptrCast(@alignCast(root));
}

fn hostOf(web: *c.WebKitWebView) [*c]u8 {
    const uri = c.webkit_web_view_get_uri(web) orelse return c.g_strdup("This page");
    const u = c.g_uri_parse(uri, c.G_URI_FLAGS_NONE, null) orelse return c.g_strdup(uri);
    defer c.g_uri_unref(u);
    return c.g_strdup(c.g_uri_get_host(u) orelse uri);
}

pub fn filters(v: std.json.Value, all: bool) ?*c.GListStore {
    const types = field(v, "types") orelse return null;
    if (types != .array or types.array.items.len == 0) return null;
    const store = c.g_list_store_new(c.gtk_file_filter_get_type());
    for (types.array.items) |t| {
        const accept = field(t, "accept") orelse continue;
        if (accept != .array) continue;
        const f = c.gtk_file_filter_new();
        defer c.g_object_unref(f);
        const desc = text(t, "description");
        if (desc.len > 0) {
            const z = c.g_strndup(desc.ptr, desc.len);
            defer c.g_free(z);
            c.gtk_file_filter_set_name(f, z);
        }
        for (accept.array.items) |pair| {
            if (pair != .array or pair.array.items.len != 2) continue;
            const mime = pair.array.items[0];
            if (mime == .string and mime.string.len > 0) {
                const z = c.g_strndup(mime.string.ptr, mime.string.len);
                defer c.g_free(z);
                c.gtk_file_filter_add_mime_type(f, z);
            }
            const exts = pair.array.items[1];
            if (exts != .array) continue;
            for (exts.array.items) |e| {
                if (e != .string) continue;
                const ext = std.mem.trimStart(u8, e.string, ".");
                if (ext.len == 0) continue;
                const z = c.g_strndup(ext.ptr, ext.len);
                defer c.g_free(z);
                c.gtk_file_filter_add_suffix(f, z);
            }
        }
        c.g_list_store_append(store, f);
    }
    if (all) {
        const f = c.gtk_file_filter_new();
        defer c.g_object_unref(f);
        c.gtk_file_filter_set_name(f, c.g_dgettext("fotone", "All Files"));
        c.gtk_file_filter_add_pattern(f, "*");
        c.g_list_store_append(store, f);
    }
    return store;
}

fn picked(call: *Call, files: ?*c.GListModel, dir: bool, write: bool) void {
    const model = files orelse return answer(call, fail("AbortError", "The user aborted a request."));
    defer c.g_object_unref(model);
    const owner = @intFromPtr(call.web);
    const o = Out.init();
    const n = c.g_list_model_get_n_items(model);
    if (call.wrap) o.raw("{\"handles\":[");
    var first = true;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const file: *c.GFile = @ptrCast(@alignCast(c.g_list_model_get_item(model, i)));
        defer c.g_object_unref(file);
        const path = c.g_file_get_path(file) orelse continue;
        defer c.g_free(path);
        const name = baseName(path);
        defer c.g_free(name);
        if (!first) o.raw(",");
        first = false;
        o.entry(grant(owner, path, dir, write), std.mem.span(name), dir);
        if (!call.wrap) break;
    }
    if (call.wrap) o.raw("]}");
    if (first and !call.wrap) {
        _ = c.g_string_free(o.s, 1);
        return answer(call, fail("AbortError", "The user aborted a request."));
    }
    answer(call, o.done());
}

fn single(file: ?*c.GFile) ?*c.GListModel {
    const f = file orelse return null;
    const store = c.g_list_store_new(c.g_file_get_type());
    c.g_list_store_append(store, f);
    c.g_object_unref(f);
    return @ptrCast(store);
}

fn opened(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    const fd: *c.GtkFileDialog = @ptrCast(@alignCast(src));
    picked(call, if (call.multiple) c.gtk_file_dialog_open_multiple_finish(fd, res, null) else single(c.gtk_file_dialog_open_finish(fd, res, null)), false, false);
}

fn saved(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    const file = c.gtk_file_dialog_save_finish(@ptrCast(@alignCast(src)), res, null);
    if (file) |f| if (c.g_file_query_exists(f, null) == 0) {
        const path = c.g_file_get_path(f);
        defer c.g_free(path);
        if (path != null) _ = c.g_file_set_contents_full(path, "", 0, c.G_FILE_SET_CONTENTS_NONE, 0o644, null);
    };
    picked(call, single(file), false, true);
}

fn folder(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    picked(call, single(c.gtk_file_dialog_select_folder_finish(@ptrCast(@alignCast(src)), res, null)), true, call.write);
}

fn permitted(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    if (c.gtk_alert_dialog_choose_finish(@ptrCast(@alignCast(src)), res, null) == 1) allowWrite(@intFromPtr(call.web), call.id);
    run(call);
}

fn run(call: *Call) void {
    const task = c.g_task_new(null, null, worked, call);
    defer c.g_object_unref(task);
    c.g_task_set_task_data(task, call, null);
    c.g_task_run_in_thread(task, work);
}

fn ask(call: *Call, g: Grant) void {
    const host = hostOf(call.web);
    defer c.g_free(host);
    const name = baseName(g.path);
    defer c.g_free(name);
    const message = c.g_strdup_printf(c.g_dgettext("fotone", "Let %s save changes to %s?"), host, name);
    defer c.g_free(message);
    const d = c.gtk_alert_dialog_new("%s", message);
    defer c.g_object_unref(d);
    c.gtk_alert_dialog_set_detail(d, c.g_dgettext("fotone", "The site will be able to change this file until you close the page."));
    const labels = [_:null]?[*:0]const u8{ c.g_dgettext("fotone", "_Don't Allow"), c.g_dgettext("fotone", "_Allow") };
    c.gtk_alert_dialog_set_buttons(d, @ptrCast(&labels));
    c.gtk_alert_dialog_set_cancel_button(d, 0);
    c.gtk_alert_dialog_set_default_button(d, 1);
    c.gtk_alert_dialog_choose(d, windowOf(call.web), null, permitted, call);
}

fn received(_: ?*c.WebKitUserContentManager, value: ?*c.JSCValue, reply: ?*c.WebKitScriptMessageReply, data: c.gpointer) callconv(.c) c.gboolean {
    const web: *c.WebKitWebView = @ptrCast(@alignCast(data));
    const v = value orelse return 0;
    const call: *Call = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Call))));
    call.* = .{
        .web = @ptrCast(@alignCast(c.g_object_ref(web))),
        .reply = c.webkit_script_message_reply_ref(reply).?,
        .ctx = @ptrCast(@alignCast(c.g_object_ref(c.jsc_value_get_context(v)))),
        .req = c.jsc_value_to_string(v),
    };
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, std.mem.span(call.req), .{}) catch {
        answer(call, fail("TypeError", "Bad request."));
        return 1;
    };
    defer parsed.deinit();
    const op = text(parsed.value, "op");
    const pick = std.mem.eql(u8, op, "open") or std.mem.eql(u8, op, "save") or std.mem.eql(u8, op, "dir");
    if (pick) {
        const fd = c.gtk_file_dialog_new();
        defer c.g_object_unref(fd);
        c.gtk_file_dialog_set_modal(fd, 1);
        if (filters(parsed.value, flag(parsed.value, "all"))) |store| {
            defer c.g_object_unref(store);
            c.gtk_file_dialog_set_filters(fd, @ptrCast(store));
        }
        const win = windowOf(web);
        if (std.mem.eql(u8, op, "open")) {
            call.multiple = flag(parsed.value, "multiple");
            call.wrap = true;
            if (call.multiple) c.gtk_file_dialog_open_multiple(fd, win, null, opened, call) else c.gtk_file_dialog_open(fd, win, null, opened, call);
        } else if (std.mem.eql(u8, op, "save")) {
            const name = text(parsed.value, "name");
            if (validName(name)) {
                const z = c.g_strndup(name.ptr, name.len);
                defer c.g_free(z);
                c.gtk_file_dialog_set_initial_name(fd, z);
            }
            c.gtk_file_dialog_save(fd, win, null, saved, call);
        } else {
            call.write = flag(parsed.value, "write");
            c.gtk_file_dialog_select_folder(fd, win, null, folder, call);
        }
        return 1;
    }
    if (std.mem.eql(u8, op, "permit") and flag(parsed.value, "write")) {
        call.id = num(parsed.value, "id");
        if (lookup(@intFromPtr(web), call.id)) |g| {
            defer c.g_free(g.path);
            if (!g.write) {
                ask(call, g);
                return 1;
            }
        }
    }
    run(call);
    return 1;
}

fn gone(data: c.gpointer, where: ?*c.GObject) callconv(.c) void {
    _ = data;
    revoke(@intFromPtr(where));
}

pub fn hook(web: *c.WebKitWebView) void {
    const ucm = c.webkit_web_view_get_user_content_manager(web) orelse return;
    if (c.webkit_user_content_manager_register_script_message_handler_with_reply(ucm, HANDLER, null) == 0) return;
    const script = c.webkit_user_script_new(SCRIPT, c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, null, null);
    defer c.webkit_user_script_unref(script);
    c.webkit_user_content_manager_add_script(ucm, script);
    _ = c.g_signal_connect_data(ucm, "script-message-with-reply-received::" ++ HANDLER, @ptrCast(&received), web, null, 0);
    c.g_object_weak_ref(@ptrCast(web), gone, null);
}

fn respond(owner: usize, req: []const u8) !std.json.Parsed(std.json.Value) {
    const out = handle(owner, req);
    defer c.g_free(out);
    return std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, std.mem.span(out), .{});
}

test "names that escape a directory are refused" {
    try std.testing.expect(validName("notes.txt"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName(".."));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a\\b"));
}

test "a granted directory can be listed, written, read, resolved and cleaned" {
    const root = c.g_dir_make_tmp("fotone-files-XXXXXX", null);
    defer c.g_free(root);
    const owner: usize = 0x1000;
    var buf: [256]u8 = undefined;
    const ro = grant(owner, root, true, false);
    {
        const r = try respond(owner, try std.fmt.bufPrint(&buf, "{{\"op\":\"child\",\"id\":{d},\"name\":\"a.txt\",\"kind\":\"file\",\"create\":true}}", .{ro}));
        defer r.deinit();
        try std.testing.expectEqualStrings("NotAllowedError", field(r.value, "error").?.string);
    }
    const id = grant(owner, root, true, true);
    try std.testing.expectEqual(ro, id);
    const sub = try std.fmt.bufPrint(&buf, "{{\"op\":\"child\",\"id\":{d},\"name\":\"docs\",\"kind\":\"directory\",\"create\":true}}", .{id});
    const d = try respond(owner, sub);
    defer d.deinit();
    const dir_id: usize = @intCast(field(d.value, "id").?.integer);
    const mk = try std.fmt.bufPrint(&buf, "{{\"op\":\"child\",\"id\":{d},\"name\":\"a.txt\",\"kind\":\"file\",\"create\":true}}", .{dir_id});
    const f = try respond(owner, mk);
    defer f.deinit();
    const file_id: usize = @intCast(field(f.value, "id").?.integer);
    const wr = try std.fmt.bufPrint(&buf, "{{\"op\":\"write\",\"id\":{d},\"data\":\"aGVsbG8=\"}}", .{file_id});
    const w = try respond(owner, wr);
    defer w.deinit();
    try std.testing.expect(field(w.value, "error") == null);
    const rd = try std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"id\":{d}}}", .{file_id});
    const r = try respond(owner, rd);
    defer r.deinit();
    try std.testing.expectEqualStrings("aGVsbG8=", field(r.value, "data").?.string);
    try std.testing.expectEqualStrings("text/plain", field(r.value, "type").?.string);
    const ls = try std.fmt.bufPrint(&buf, "{{\"op\":\"list\",\"id\":{d}}}", .{id});
    const l = try respond(owner, ls);
    defer l.deinit();
    const entries = field(l.value, "entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("directory", field(entries[0], "kind").?.string);
    try std.testing.expectEqual(dir_id, @as(usize, @intCast(field(entries[0], "id").?.integer)));
    const rs = try std.fmt.bufPrint(&buf, "{{\"op\":\"resolve\",\"id\":{d},\"target\":{d}}}", .{ id, file_id });
    const p = try respond(owner, rs);
    defer p.deinit();
    const parts = field(p.value, "path").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("a.txt", parts[1].string);
    const bad = try std.fmt.bufPrint(&buf, "{{\"op\":\"child\",\"id\":{d},\"name\":\"..\",\"kind\":\"file\"}}", .{id});
    const b = try respond(owner, bad);
    defer b.deinit();
    try std.testing.expectEqualStrings("TypeError", field(b.value, "error").?.string);
    const other = try std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"id\":{d}}}", .{file_id});
    const x = try respond(owner + 1, other);
    defer x.deinit();
    try std.testing.expectEqualStrings("NotFoundError", field(x.value, "error").?.string);
    const keep = try std.fmt.bufPrint(&buf, "{{\"op\":\"remove\",\"id\":{d},\"name\":\"docs\"}}", .{id});
    const k = try respond(owner, keep);
    defer k.deinit();
    try std.testing.expectEqualStrings("InvalidModificationError", field(k.value, "error").?.string);
    const rm = try std.fmt.bufPrint(&buf, "{{\"op\":\"remove\",\"id\":{d},\"name\":\"docs\",\"recursive\":true}}", .{id});
    const e = try respond(owner, rm);
    defer e.deinit();
    try std.testing.expect(field(e.value, "error") == null);
    revoke(owner);
    const after = try respond(owner, try std.fmt.bufPrint(&buf, "{{\"op\":\"list\",\"id\":{d}}}", .{id}));
    defer after.deinit();
    try std.testing.expectEqualStrings("NotFoundError", field(after.value, "error").?.string);
    _ = std.c.rmdir(root);
}

test "picker types become file filters" {
    const json =
        \\{"types":[{"description":"Images","accept":[["image/png",[".png"]],["image/jpeg",[".jpg",".jpeg"]]]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json, .{});
    defer parsed.deinit();
    const store = filters(parsed.value, true).?;
    defer c.g_object_unref(store);
    try std.testing.expectEqual(@as(c.guint, 2), c.g_list_model_get_n_items(@ptrCast(store)));
    const f: *c.GtkFileFilter = @ptrCast(@alignCast(c.g_list_model_get_item(@ptrCast(store), 0)));
    defer c.g_object_unref(f);
    try std.testing.expectEqualStrings("Images", std.mem.span(c.gtk_file_filter_get_name(f)));
}
