const std = @import("std");
const c = @import("c.zig").c;

pub const idle_us: i64 = 5 * 60 * std.time.us_per_s;
pub const forced_us: i64 = 30 * 60 * std.time.us_per_s;
pub const pressure_limit: f64 = 10.0;
pub const freeze_us: i64 = 30 * std.time.us_per_s;

pub fn parsePressure(text: []const u8) ?f64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "some ")) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        while (fields.next()) |f| {
            if (std.mem.startsWith(u8, f, "avg10=")) return std.fmt.parseFloat(f64, f["avg10=".len..]) catch null;
        }
    }
    return null;
}

pub fn pressure() f64 {
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents("/proc/pressure/memory", &contents, &len, null) == 0) return 0;
    defer c.g_free(contents);
    return parsePressure(contents[0..len]) orelse 0;
}

pub const BUDGET_ENV = "FOTONE_WEB_VIEW_BUDGET";
const per_view_kib: u64 = 384 * 1024;

pub fn parseTotal(text: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
        var fields = std.mem.tokenizeScalar(u8, line["MemTotal:".len..], ' ');
        const v = fields.next() orelse return null;
        return std.fmt.parseInt(u64, v, 10) catch null;
    }
    return null;
}

pub fn budgetFor(total_kib: u64) usize {
    return @intCast(std.math.clamp(total_kib / per_view_kib / 2, 4, 48));
}

pub fn budget() usize {
    if (c.g_getenv(BUDGET_ENV)) |v| {
        const n = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
        if (n > 0) return n;
    }
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents("/proc/meminfo", &contents, &len, null) == 0) return 8;
    defer c.g_free(contents);
    return budgetFor(parseTotal(contents[0..len]) orelse return 8);
}

pub const MEMORY_ENV = "FOTONE_WEB_MEMORY_MIB";

pub fn memoryBudgetFor(total_kib: u64) u64 {
    return std.math.clamp(total_kib / 4, 512 * 1024, 8 * 1024 * 1024);
}

pub fn memoryBudget() u64 {
    if (c.g_getenv(MEMORY_ENV)) |v| {
        const n = std.fmt.parseInt(u64, std.mem.span(v), 10) catch 0;
        if (n > 0) return n * 1024;
    }
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents("/proc/meminfo", &contents, &len, null) == 0) return memoryBudgetFor(0);
    defer c.g_free(contents);
    return memoryBudgetFor(parseTotal(contents[0..len]) orelse 0);
}

pub fn parseChild(text: []const u8, parent: c_int) bool {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    if (close < open or !std.mem.eql(u8, text[open + 1 .. close], "WPEWebProcess")) return false;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = fields.next() orelse return false;
    const ppid = fields.next() orelse return false;
    return (std.fmt.parseInt(c_int, ppid, 10) catch return false) == parent;
}

pub fn parsePss(text: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Pss:")) continue;
        var fields = std.mem.tokenizeScalar(u8, line["Pss:".len..], ' ');
        return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
    }
    return null;
}

fn readProc(pid: [*c]const u8, file: [*:0]const u8, buf: [*c][*c]u8, len: *c.gsize) bool {
    const path = c.g_build_filename("/proc", pid, file, @as([*c]const u8, null));
    defer c.g_free(path);
    return c.g_file_get_contents(path, buf, len, null) != 0;
}

pub fn webMemory() u64 {
    const parent = std.c.getpid();
    const d = c.g_dir_open("/proc", 0, null) orelse return 0;
    defer c.g_dir_close(d);
    var total: u64 = 0;
    while (c.g_dir_read_name(d)) |name| {
        if (name[0] < '1' or name[0] > '9') continue;
        var stat: [*c]u8 = null;
        var len: c.gsize = 0;
        if (!readProc(name, "stat", &stat, &len)) continue;
        const child = parseChild(stat[0..len], parent);
        c.g_free(stat);
        if (!child) continue;
        var rollup: [*c]u8 = null;
        if (!readProc(name, "smaps_rollup", &rollup, &len)) continue;
        defer c.g_free(rollup);
        total += parsePss(rollup[0..len]) orelse 0;
    }
    return total;
}

pub fn shouldSleep(hidden_for: i64, current_pressure: f64) bool {
    if (hidden_for >= forced_us) return true;
    return hidden_for >= idle_us and current_pressure >= pressure_limit;
}

pub fn siteLimit(current_pressure: f64) usize {
    return if (current_pressure >= pressure_limit) 1 else 2;
}

pub fn shouldFreeze(hidden_for: i64, busy: bool) bool {
    return !busy and hidden_for >= freeze_us;
}

test "hidden views freeze after a short grace unless busy" {
    try std.testing.expect(!shouldFreeze(freeze_us - 1, false));
    try std.testing.expect(shouldFreeze(freeze_us, false));
    try std.testing.expect(!shouldFreeze(forced_us, true));
}

test "a site keeps fewer hidden views awake under pressure" {
    try std.testing.expectEqual(@as(usize, 2), siteLimit(0));
    try std.testing.expectEqual(@as(usize, 1), siteLimit(pressure_limit));
}

test "pressure reads the some avg10 field" {
    const sample = "some avg10=12.50 avg60=3.00 avg300=1.00 total=1234\nfull avg10=1.00 avg60=0.00 avg300=0.00 total=12\n";
    try std.testing.expectEqual(@as(f64, 12.5), parsePressure(sample).?);
    try std.testing.expect(parsePressure("garbage") == null);
}

test "the awake budget follows the installed memory" {
    try std.testing.expectEqual(@as(?u64, 16303436), parseTotal("MemTotal:       16303436 kB\nMemFree: 1 kB\n"));
    try std.testing.expectEqual(@as(usize, 4), budgetFor(2 * 1024 * 1024));
    try std.testing.expectEqual(@as(usize, 21), budgetFor(16 * 1024 * 1024));
    try std.testing.expectEqual(@as(usize, 48), budgetFor(128 * 1024 * 1024));
}

test "hidden views sleep under pressure or after a long time" {
    try std.testing.expect(!shouldSleep(idle_us - 1, 50));
    try std.testing.expect(shouldSleep(idle_us, pressure_limit));
    try std.testing.expect(!shouldSleep(idle_us, 0));
    try std.testing.expect(shouldSleep(forced_us, 0));
}

test "web processes share a quarter of the memory within bounds" {
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024), memoryBudgetFor(16 * 1024 * 1024));
    try std.testing.expectEqual(@as(u64, 512 * 1024), memoryBudgetFor(1024 * 1024));
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), memoryBudgetFor(128 * 1024 * 1024));
}

test "only web processes of this app count" {
    try std.testing.expect(parseChild("4242 (WPEWebProcess) S 100 4242 4242 0 -1", 100));
    try std.testing.expect(!parseChild("4242 (WPEWebProcess) S 101 4242 4242 0 -1", 100));
    try std.testing.expect(!parseChild("4242 (WPENetworkProce) S 100 4242 4242 0 -1", 100));
    try std.testing.expect(!parseChild("4242 (a) b) S 100", 100));
}

test "pss is read from smaps_rollup" {
    try std.testing.expectEqual(@as(?u64, 183412), parsePss("55d0-7ffd ---p 00000000 00:00 0 [rollup]\nRss: 201000 kB\nPss: 183412 kB\n"));
    try std.testing.expect(parsePss("Rss: 1 kB\n") == null);
}
