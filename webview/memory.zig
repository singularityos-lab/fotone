const std = @import("std");
const c = @import("c.zig").c;

pub const idle_us: i64 = 5 * 60 * std.time.us_per_s;
pub const forced_us: i64 = 30 * 60 * std.time.us_per_s;
pub const pressure_limit: f64 = 10.0;

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

pub fn shouldSleep(hidden_for: i64, current_pressure: f64) bool {
    if (hidden_for >= forced_us) return true;
    return hidden_for >= idle_us and current_pressure >= pressure_limit;
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
