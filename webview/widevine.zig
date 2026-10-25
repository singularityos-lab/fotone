const std = @import("std");
const c = @import("c.zig").c;

const UPDATE_URL = "https://update.googleapis.com/service/update2/json";
const APP_ID = "oimompecagnajdejgnnjijobebaeigek";
const ENTRY = "_platform_specific/linux_x64/libwidevinecdm.so";
const HANDLER = "fotoneWidevine";
const MAX_CRX = 64 << 20;

const REQUEST =
    \\{"request":{"@os":"linux","@updater":"chrome","protocol":"3.1","acceptformat":"crx3","prodchannel":"stable","prodversion":"141.0.7390.0","updaterversion":"141.0.7390.0","os":{"platform":"Linux","arch":"x86_64","version":"6.0"},"arch":"x64","app":[{"appid":"
++ APP_ID ++
    \\","version":"0.0.0.0","updatecheck":{}}]}}
;

const SCRIPT =
    \\(function () {
    \\  const ask = navigator.requestMediaKeySystemAccess;
    \\  if (!ask) return;
    \\  navigator.requestMediaKeySystemAccess = function (system, configs) {
    \\    if (system === "com.widevine.alpha") window.webkit.messageHandlers.fotoneWidevine.postMessage(location.hostname);
    \\    return ask.call(navigator, system, configs);
    \\  };
    \\})();
;

var declined = false;
var busy = false;

fn dir() [*c]u8 {
    return c.g_build_filename(c.g_get_user_data_dir(), "fotone", "widevine", @as(?*anyopaque, null));
}

pub fn installed() bool {
    const d = dir();
    defer c.g_free(d);
    const p = c.g_build_filename(d, "libwidevinecdm.so", @as(?*anyopaque, null));
    defer c.g_free(p);
    return c.g_file_test(p, c.G_FILE_TEST_IS_REGULAR) != 0;
}

pub fn hook(web: *c.WebKitWebView) void {
    if (installed()) return;
    const ucm = c.webkit_web_view_get_user_content_manager(web) orelse return;
    if (c.webkit_user_content_manager_register_script_message_handler(ucm, HANDLER, null) == 0) return;
    const script = c.webkit_user_script_new(SCRIPT, c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, null, null);
    defer c.webkit_user_script_unref(script);
    c.webkit_user_content_manager_add_script(ucm, script);
    _ = c.g_signal_connect_data(ucm, "script-message-received::" ++ HANDLER, @ptrCast(&requested), web, null, 0);
}

const Job = struct {
    web: *c.WebKitWebView,
    session: *c.SoupSession,
    sha: [32]u8 = undefined,
    size: usize = 0,
    version: [32]u8 = undefined,
    version_len: usize = 0,
};

fn windowOf(web: *c.WebKitWebView) ?*c.GtkWindow {
    const w = c.g_object_get_data(@ptrCast(web), "fotone-widget") orelse return null;
    const root = c.gtk_widget_get_root(@ptrCast(@alignCast(w))) orelse return null;
    return @ptrCast(@alignCast(root));
}

fn requested(_: ?*c.WebKitUserContentManager, value: ?*c.JSCValue, data: c.gpointer) callconv(.c) void {
    if (declined or busy or installed()) return;
    const web: *c.WebKitWebView = @ptrCast(@alignCast(data));
    const host = c.jsc_value_to_string(value);
    defer c.g_free(host);
    const message = c.g_strdup_printf(c.g_dgettext("fotone", "%s wants to play protected content"), host);
    defer c.g_free(message);
    const d = c.gtk_alert_dialog_new("%s", message);
    defer c.g_object_unref(d);
    c.gtk_alert_dialog_set_detail(d, c.g_dgettext("fotone", "Fotone can download the Widevine module from Google to play it. The module is closed source and is covered by Google's terms."));
    const labels = [_:null]?[*:0]const u8{ c.g_dgettext("fotone", "_Not Now"), c.g_dgettext("fotone", "_Download") };
    c.gtk_alert_dialog_set_buttons(d, @ptrCast(&labels));
    c.gtk_alert_dialog_set_cancel_button(d, 0);
    c.gtk_alert_dialog_set_default_button(d, 1);
    busy = true;
    c.gtk_alert_dialog_choose(d, windowOf(web), null, chosen, c.g_object_ref(web));
}

fn chosen(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const web: *c.WebKitWebView = @ptrCast(@alignCast(data));
    if (c.gtk_alert_dialog_choose_finish(@ptrCast(@alignCast(src)), res, null) != 1) {
        declined = true;
        busy = false;
        return c.g_object_unref(web);
    }
    const job: *Job = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Job))));
    job.* = .{ .web = web, .session = c.soup_session_new().? };
    const msg = c.soup_message_new("POST", UPDATE_URL) orelse return finish(job, "bad update address");
    defer c.g_object_unref(msg);
    const body = c.g_bytes_new_static(REQUEST.ptr, REQUEST.len);
    defer c.g_bytes_unref(body);
    c.soup_message_set_request_body_from_bytes(msg, "application/json", body);
    c.soup_session_send_and_read_async(job.session, msg, c.G_PRIORITY_DEFAULT, null, checked, job);
}

pub const Offer = struct {
    url: [1024]u8 = undefined,
    url_len: usize = 0,
    sha: [32]u8 = undefined,
    size: usize = 0,
    version: [32]u8 = undefined,
    version_len: usize = 0,
};

pub fn parseOffer(text: []const u8) !Offer {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return error.BadResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, text[start..], .{});
    defer parsed.deinit();
    const up = field(index(field(field(parsed.value, "response"), "app"), 0), "updatecheck") orelse return error.BadResponse;
    const status = field(up, "status") orelse return error.BadResponse;
    if (status != .string or !std.mem.eql(u8, status.string, "ok")) return error.NoUpdate;
    const pkg = index(field(field(field(up, "manifest"), "packages"), "package"), 0) orelse return error.BadResponse;
    const name = field(pkg, "name") orelse return error.BadResponse;
    const hash = field(pkg, "hash_sha256") orelse return error.BadResponse;
    const size = field(pkg, "size") orelse return error.BadResponse;
    if (name != .string or hash != .string or size != .integer) return error.BadResponse;
    var o: Offer = .{ .size = @intCast(size.integer) };
    _ = try std.fmt.hexToBytes(&o.sha, hash.string);
    const urls = field(field(up, "urls"), "url") orelse return error.BadResponse;
    if (urls != .array) return error.BadResponse;
    for (urls.array.items) |u| {
        const base = field(u, "codebase") orelse continue;
        if (base != .string or !std.mem.startsWith(u8, base.string, "https://")) continue;
        const full = try std.fmt.bufPrint(&o.url, "{s}{s}", .{ base.string, name.string });
        o.url_len = full.len;
        return o;
    }
    return error.NoSecureUrl;
}

fn field(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const x = v orelse return null;
    if (x != .object) return null;
    return x.object.get(key);
}

fn index(v: ?std.json.Value, i: usize) ?std.json.Value {
    const x = v orelse return null;
    if (x != .array or x.array.items.len <= i) return null;
    return x.array.items[i];
}

fn bytesOf(b: *c.GBytes) []const u8 {
    var n: usize = 0;
    const p: ?[*]const u8 = @ptrCast(c.g_bytes_get_data(b, &n));
    return if (p) |x| x[0..n] else &[_]u8{};
}

fn checked(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data));
    const bytes = c.soup_session_send_and_read_finish(@ptrCast(@alignCast(src)), res, null) orelse return finish(job, "the update service did not answer");
    defer c.g_bytes_unref(bytes);
    const offer = parseOffer(bytesOf(bytes)) catch return finish(job, "the update service offered no module");
    job.sha = offer.sha;
    job.size = offer.size;
    const v = versionOf(offer.url[0..offer.url_len]);
    job.version_len = @min(v.len, job.version.len);
    @memcpy(job.version[0..job.version_len], v[0..job.version_len]);
    var url: [1025]u8 = undefined;
    @memcpy(url[0..offer.url_len], offer.url[0..offer.url_len]);
    url[offer.url_len] = 0;
    const msg = c.soup_message_new("GET", @ptrCast(&url)) orelse return finish(job, "bad download address");
    defer c.g_object_unref(msg);
    c.soup_session_send_and_read_async(job.session, msg, c.G_PRIORITY_DEFAULT, null, downloaded, job);
}

pub fn crxZip(crx: []const u8) ![]const u8 {
    if (crx.len < 12 or !std.mem.eql(u8, crx[0..4], "Cr24")) return error.NotCrx;
    if (std.mem.readInt(u32, crx[4..8], .little) != 3) return error.NotCrx;
    const header = std.mem.readInt(u32, crx[8..12], .little);
    if (12 + @as(usize, header) > crx.len) return error.NotCrx;
    return crx[12 + header ..];
}

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

pub fn unzip(zip: []const u8, name: []const u8) ![]u8 {
    if (zip.len < 22) return error.BadZip;
    var end: usize = zip.len - 22;
    while (u32At(zip, end) != 0x06054b50) : (end -= 1) if (end == 0 or zip.len - end > 22 + 0xffff) return error.BadZip;
    const count = u16At(zip, end + 10);
    var at: usize = u32At(zip, end + 16);
    for (0..count) |_| {
        if (at + 46 > zip.len or u32At(zip, at) != 0x02014b50) return error.BadZip;
        const method = u16At(zip, at + 10);
        const crc = u32At(zip, at + 16);
        const packed_size = u32At(zip, at + 20);
        const size = u32At(zip, at + 24);
        const nlen = u16At(zip, at + 28);
        const extra = u16At(zip, at + 30);
        const note = u16At(zip, at + 32);
        const local = u32At(zip, at + 42);
        if (at + 46 + nlen > zip.len) return error.BadZip;
        const entry = zip[at + 46 ..][0..nlen];
        at += 46 + @as(usize, nlen) + extra + note;
        if (!std.mem.eql(u8, entry, name)) continue;
        if (local + 30 > zip.len or u32At(zip, local) != 0x04034b50) return error.BadZip;
        const start = local + 30 + @as(usize, u16At(zip, local + 26)) + u16At(zip, local + 28);
        if (start + packed_size > zip.len) return error.BadZip;
        const raw = zip[start..][0..packed_size];
        const out = std.heap.c_allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.free(out);
        switch (method) {
            0 => {
                if (raw.len != size) return error.BadZip;
                @memcpy(out, raw);
            },
            8 => try inflate(raw, out),
            else => return error.UnsupportedZip,
        }
        if (std.hash.Crc32.hash(out) != crc) return error.BadChecksum;
        return out;
    }
    return error.MissingEntry;
}

fn inflate(raw: []const u8, out: []u8) !void {
    const z = c.g_zlib_decompressor_new(c.G_ZLIB_COMPRESSOR_FORMAT_RAW);
    defer c.g_object_unref(z);
    var in_at: usize = 0;
    var out_at: usize = 0;
    while (true) {
        var read: usize = 0;
        var written: usize = 0;
        const r = c.g_converter_convert(@ptrCast(z), raw.ptr + in_at, raw.len - in_at, out.ptr + out_at, out.len - out_at, c.G_CONVERTER_INPUT_AT_END, &read, &written, null);
        in_at += read;
        out_at += written;
        if (r == c.G_CONVERTER_FINISHED) break;
        if (r == c.G_CONVERTER_ERROR or (read == 0 and written == 0)) return error.BadZip;
    }
    if (out_at != out.len) return error.BadZip;
}

fn store(module: []const u8, version: []const u8) bool {
    const d = dir();
    defer c.g_free(d);
    if (c.g_mkdir_with_parents(d, 0o700) != 0) return false;
    const p = c.g_build_filename(d, "libwidevinecdm.so", @as(?*anyopaque, null));
    defer c.g_free(p);
    if (c.g_file_set_contents_full(p, module.ptr, @intCast(module.len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o755, null) == 0) return false;
    const v = c.g_build_filename(d, "version", @as(?*anyopaque, null));
    defer c.g_free(v);
    _ = c.g_file_set_contents_full(v, version.ptr, @intCast(version.len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o644, null);
    return true;
}

fn versionOf(url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return "";
    const name = url[slash + 1 ..];
    var parts = std.mem.splitScalar(u8, name, '_');
    _ = parts.next();
    return parts.next() orelse "";
}

fn downloaded(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data));
    const bytes = c.soup_session_send_and_read_finish(@ptrCast(@alignCast(src)), res, null) orelse return finish(job, "the download failed");
    defer c.g_bytes_unref(bytes);
    const crx = bytesOf(bytes);
    if (crx.len != job.size or crx.len > MAX_CRX) return finish(job, "the download has the wrong size");
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(crx, &sum, .{});
    if (!std.mem.eql(u8, &sum, &job.sha)) return finish(job, "the download does not match its checksum");
    const zip = crxZip(crx) catch return finish(job, "the download is not a component package");
    const module = unzip(zip, ENTRY) catch return finish(job, "the package has no Linux module");
    defer std.heap.c_allocator.free(module);
    if (!store(module, job.version[0..job.version_len])) return finish(job, "the module could not be saved");
    finish(job, null);
}

fn finish(job: *Job, err: ?[*:0]const u8) void {
    busy = false;
    defer {
        c.g_object_unref(job.session);
        c.g_object_unref(job.web);
        c.g_free(job);
    }
    if (err) |e| {
        const d = c.gtk_alert_dialog_new("%s", c.g_dgettext("fotone", "Could not install Widevine"));
        defer c.g_object_unref(d);
        c.gtk_alert_dialog_set_detail(d, c.g_dgettext("fotone", e));
        c.gtk_alert_dialog_show(d, windowOf(job.web));
        return;
    }
    c.webkit_web_view_terminate_web_process(job.web);
    c.webkit_web_view_reload(job.web);
}

test "the update answer names a secure package with its checksum" {
    const answer =
        \\)]}'
        \\{"response":{"app":[{"appid":"x","status":"ok","updatecheck":{"status":"ok","urls":{"url":[{"codebase":"http://a.example/p/"},{"codebase":"https://b.example/p/"}]},"manifest":{"version":"4.10.3112.0","packages":{"package":[{"hash_sha256":"1bf1f200dcccd461b2d029d000d0fcf800f0571c932db31467b9d5d301e0a98f","size":21970001,"name":"m_4.10.3112.0_linux64.crx3"}]}}}}]}}
    ;
    const o = try parseOffer(answer);
    try std.testing.expectEqualStrings("https://b.example/p/m_4.10.3112.0_linux64.crx3", o.url[0..o.url_len]);
    try std.testing.expectEqual(@as(usize, 21970001), o.size);
    try std.testing.expectEqual(@as(u8, 0x1b), o.sha[0]);
    try std.testing.expectEqualStrings("4.10.3112.0", versionOf(o.url[0..o.url_len]));
    try std.testing.expectError(error.NoUpdate, parseOffer("{\"response\":{\"app\":[{\"updatecheck\":{\"status\":\"noupdate\"}}]}}"));
}

fn zipOne(buf: []u8, name: []const u8, data: []const u8, method: u16, stored: []const u8) []u8 {
    var w: std.ArrayList(u8) = .initBuffer(buf);
    const crc = std.hash.Crc32.hash(data);
    const le = struct {
        fn put(l: *std.ArrayList(u8), comptime T: type, v: T) void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            l.appendSliceBounded(&b) catch unreachable;
        }
    };
    le.put(&w, u32, 0x04034b50);
    le.put(&w, u16, 20);
    le.put(&w, u16, 0);
    le.put(&w, u16, method);
    le.put(&w, u32, 0);
    le.put(&w, u32, crc);
    le.put(&w, u32, @intCast(stored.len));
    le.put(&w, u32, @intCast(data.len));
    le.put(&w, u16, @intCast(name.len));
    le.put(&w, u16, 0);
    w.appendSliceBounded(name) catch unreachable;
    w.appendSliceBounded(stored) catch unreachable;
    const cd = w.items.len;
    le.put(&w, u32, 0x02014b50);
    le.put(&w, u16, 20);
    le.put(&w, u16, 20);
    le.put(&w, u16, 0);
    le.put(&w, u16, method);
    le.put(&w, u32, 0);
    le.put(&w, u32, crc);
    le.put(&w, u32, @intCast(stored.len));
    le.put(&w, u32, @intCast(data.len));
    le.put(&w, u16, @intCast(name.len));
    le.put(&w, u16, 0);
    le.put(&w, u16, 0);
    le.put(&w, u16, 0);
    le.put(&w, u16, 0);
    le.put(&w, u32, 0);
    le.put(&w, u32, 0);
    w.appendSliceBounded(name) catch unreachable;
    const cd_len = w.items.len - cd;
    le.put(&w, u32, 0x06054b50);
    le.put(&w, u16, 0);
    le.put(&w, u16, 0);
    le.put(&w, u16, 1);
    le.put(&w, u16, 1);
    le.put(&w, u32, @intCast(cd_len));
    le.put(&w, u32, @intCast(cd));
    le.put(&w, u16, 0);
    return w.items;
}

test "component packages unpack stored and deflated modules" {
    const module = "\x7fELF fake module " ** 40;
    var buf: [4096]u8 = undefined;
    var crx: [4200]u8 = undefined;
    @memcpy(crx[0..4], "Cr24");
    std.mem.writeInt(u32, crx[4..8], 3, .little);
    std.mem.writeInt(u32, crx[8..12], 4, .little);
    const stored = zipOne(&buf, ENTRY, module, 0, module);
    @memcpy(crx[16..][0..stored.len], stored);
    const got = try unzip(try crxZip(crx[0 .. 16 + stored.len]), ENTRY);
    defer std.heap.c_allocator.free(got);
    try std.testing.expectEqualStrings(module, got);

    const z = c.g_zlib_compressor_new(c.G_ZLIB_COMPRESSOR_FORMAT_RAW, -1);
    defer c.g_object_unref(z);
    var packed_buf: [1024]u8 = undefined;
    var read: usize = 0;
    var written: usize = 0;
    _ = c.g_converter_convert(@ptrCast(z), module.ptr, module.len, &packed_buf, packed_buf.len, c.G_CONVERTER_INPUT_AT_END, &read, &written, null);
    var buf2: [4096]u8 = undefined;
    const deflated = zipOne(&buf2, ENTRY, module, 8, packed_buf[0..written]);
    const got2 = try unzip(deflated, ENTRY);
    defer std.heap.c_allocator.free(got2);
    try std.testing.expectEqualStrings(module, got2);
    try std.testing.expectError(error.MissingEntry, unzip(deflated, "other"));
}
