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

pub fn shouldSleep(hidden_for: i64, current_pressure: f64) bool {
    if (hidden_for >= forced_us) return true;
    return hidden_for >= idle_us and current_pressure >= pressure_limit;
}

test "pressure reads the some avg10 field" {
    const sample = "some avg10=12.50 avg60=3.00 avg300=1.00 total=1234\nfull avg10=1.00 avg60=0.00 avg300=0.00 total=12\n";
    try std.testing.expectEqual(@as(f64, 12.5), parsePressure(sample).?);
    try std.testing.expect(parsePressure("garbage") == null);
}

test "hidden views sleep under pressure or after a long time" {
    try std.testing.expect(!shouldSleep(idle_us - 1, 50));
    try std.testing.expect(shouldSleep(idle_us, pressure_limit));
    try std.testing.expect(!shouldSleep(idle_us, 0));
    try std.testing.expect(shouldSleep(forced_us, 0));
}
