const std = @import("std");
const linux = std.os.linux;

pub const FIDO_PAGE = 0xF1D0;
pub const FIDO_USAGE = 0x01;
pub const REPORT = 64;
pub const MAX_NODES = 64;

pub fn isFido(desc: []const u8) bool {
    var page: u32 = 0;
    var i: usize = 0;
    while (i < desc.len) {
        const prefix = desc[i];
        if (prefix == 0xFE) {
            if (i + 1 >= desc.len) return false;
            i += 3 + @as(usize, desc[i + 1]);
            continue;
        }
        const size: usize = switch (prefix & 3) {
            3 => 4,
            else => |s| s,
        };
        if (i + 1 + size > desc.len) return false;
        var value: u32 = 0;
        for (desc[i + 1 .. i + 1 + size], 0..) |b, k| value |= @as(u32, b) << @intCast(8 * k);
        switch (prefix & 0xFC) {
            0x04 => page = value,
            0x08 => {
                const full = if (size == 4) value else (page << 16) | value;
                if (full == (FIDO_PAGE << 16) | FIDO_USAGE) return true;
            },
            else => {},
        }
        i += 1 + size;
    }
    return false;
}

fn openAt(path: [*:0]const u8, flags: linux.O) ?i32 {
    const rc = linux.open(path, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn descriptorIsFido(n: usize) bool {
    var buf: [80]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "/sys/class/hidraw/hidraw{d}/device/report_descriptor", .{n}) catch return false;
    const fd = openAt(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) orelse return false;
    defer _ = linux.close(fd);
    var desc: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < desc.len) {
        const r = linux.read(fd, desc[len..].ptr, desc.len - len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        len += r;
    }
    return isFido(desc[0..len]);
}

pub const Found = *const fn (ctx: ?*anyopaque, path: [*:0]const u8) callconv(.c) void;

pub export fn fotone_hid_scan(found: Found, ctx: ?*anyopaque) c_int {
    var count: c_int = 0;
    for (0..MAX_NODES) |n| {
        if (!descriptorIsFido(n)) continue;
        var buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "/dev/hidraw{d}", .{n}) catch continue;
        found(ctx, path);
        count += 1;
    }
    return count;
}

pub export fn fotone_hid_open(path: [*:0]const u8) c_int {
    return openAt(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }) orelse -1;
}

pub export fn fotone_hid_close(fd: c_int) void {
    if (fd >= 0) _ = linux.close(fd);
}

pub export fn fotone_hid_write(fd: c_int, data: [*]const u8, len: usize) c_int {
    var report = [_]u8{0} ** (REPORT + 1);
    @memcpy(report[1 .. 1 + @min(len, REPORT)], data[0..@min(len, REPORT)]);
    const r = linux.write(fd, &report, report.len);
    return @intFromBool(linux.errno(r) == .SUCCESS and r == report.len);
}

pub export fn fotone_hid_read(fd: c_int, data: [*]u8, len: usize) isize {
    const r = linux.read(fd, data, len);
    if (linux.errno(r) != .SUCCESS) return -1;
    return @intCast(r);
}

test "a security key descriptor is recognised" {
    const yubikey = [_]u8{ 0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01, 0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02, 0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02, 0xC0 };
    try std.testing.expect(isFido(&yubikey));
    const keyboard = [_]u8{ 0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0xC0 };
    try std.testing.expect(!isFido(&keyboard));
    const extended = [_]u8{ 0x0B, 0x01, 0x00, 0xD0, 0xF1 };
    try std.testing.expect(isFido(&extended));
    try std.testing.expect(!isFido(&[_]u8{ 0x06, 0xD0 }));
}

test "scanning the live nodes does not fail" {
    const S = struct {
        fn found(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
    };
    _ = fotone_hid_scan(&S.found, null);
    try std.testing.expectEqual(@as(c_int, -1), fotone_hid_open("/nonexistent/hidraw"));
}
