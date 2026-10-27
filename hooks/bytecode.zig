const std = @import("std");
const linux = std.os.linux;

pub const MIN_SOURCE = 4096;
const REPORT_EVERY = 16;
const DISABLE_ENV = "FOTONE_BYTECODE_CACHE";

const Report = extern struct { hits: u64 = 0, misses: u64 = 0, verified: u64 = 0, mismatches: u64 = 0, saved_ns: u64 = 0, spent_ns: u64 = 0 };

const Compute = struct {
    fd: c_int,
    report: *const fn (c_int, *const Report) callconv(.c) c_int,
};

var lock: std.c.pthread_mutex_t = .{};
var pending: Report = .{};
var counted: u32 = 0;
var compute: ?Compute = null;
var probed = false;

pub fn fileName(buf: []u8, base: []const u8, url: []const u8, hash: u32, length: u32) ?[]const u8 {
    if (length < MIN_SOURCE or base.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/fotone/bytecode/{x:0>16}-{x:0>8}-{x}", .{ base, std.hash.Wyhash.hash(0, url), hash, length }) catch null;
}

fn cacheBase(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |d| return std.mem.span(d);
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache", .{std.mem.span(home)}) catch null;
}

fn makeDirs(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        buf[i] = 0;
        _ = linux.mkdir(@ptrCast(&buf), 0o700);
        if (i < path.len) buf[i] = '/';
    }
}

pub export fn fotone_bytecode_cache_path(url: [*]const u8, url_len: usize, hash: c_uint, length: c_uint, out: [*]u8, out_size: usize) usize {
    if (std.c.getenv(DISABLE_ENV)) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "0")) return 0;
    }
    var base_buf: [4096]u8 = undefined;
    const base = cacheBase(&base_buf) orelse return 0;
    const name = fileName(out[0..out_size], base, url[0..url_len], hash, length) orelse return 0;
    makeDirs(std.fs.path.dirname(name) orelse return 0);
    return name.len;
}

fn open() ?Compute {
    const lib = std.c.dlopen("libsintycompute.so.0", .{ .LAZY = true }) orelse return null;
    const open_fn: *const fn () callconv(.c) c_int = @ptrCast(std.c.dlsym(lib, "sinty_compute_open") orelse return null);
    const report: *const fn (c_int, *const Report) callconv(.c) c_int = @ptrCast(std.c.dlsym(lib, "sinty_compute_report") orelse return null);
    const fd = open_fn();
    if (fd < 0) return null;
    return .{ .fd = fd, .report = report };
}

pub export fn fotone_bytecode_cache_count(hit: c_int) void {
    _ = std.c.pthread_mutex_lock(&lock);
    defer _ = std.c.pthread_mutex_unlock(&lock);
    if (hit != 0) pending.hits += 1 else pending.misses += 1;
    counted += 1;
    if (counted < REPORT_EVERY and pending.hits + pending.misses > 1) return;
    counted = 0;
    if (!probed) {
        probed = true;
        compute = open();
    }
    const c = compute orelse return;
    if (c.report(c.fd, &pending) == 0) pending = .{};
}

test "small scripts are not cached" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(fileName(&buf, "/c", "https://a/x.js", 1, MIN_SOURCE - 1) == null);
}

test "the file name depends on url, hash and length" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const x = fileName(&a, "/c", "https://a/x.js", 7, MIN_SOURCE).?;
    const y = fileName(&b, "/c", "https://a/y.js", 7, MIN_SOURCE).?;
    try std.testing.expect(std.mem.startsWith(u8, x, "/c/fotone/bytecode/"));
    try std.testing.expect(!std.mem.eql(u8, x, y));
}
