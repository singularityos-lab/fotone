const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("import.h");
});

const RELEASES = "https://wpewebkit.org/releases/";
const PIN = "upstream/wpewebkit";

pub const Version = struct {
    major: u32,
    minor: u32,
    micro: u32,

    pub fn parse(s: []const u8) ?Version {
        var it = std.mem.splitScalar(u8, s, '.');
        const a = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const b = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const m = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        if (it.next() != null) return null;
        return .{ .major = a, .minor = b, .micro = m };
    }

    pub fn stable(v: Version) bool {
        return v.minor % 2 == 0;
    }

    pub fn newer(v: Version, o: Version) bool {
        if (v.major != o.major) return v.major > o.major;
        if (v.minor != o.minor) return v.minor > o.minor;
        return v.micro > o.micro;
    }
};

pub fn latest(index: []const u8) ?Version {
    var best: ?Version = null;
    var rest = index;
    while (std.mem.indexOf(u8, rest, "wpewebkit-")) |i| {
        rest = rest[i + "wpewebkit-".len ..];
        const end = std.mem.indexOf(u8, rest, ".tar.xz") orelse break;
        const v = Version.parse(rest[0..end]) orelse continue;
        if (!v.stable()) continue;
        if (best == null or v.newer(best.?)) best = v;
    }
    return best;
}

pub fn sha256Of(sums: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, sums, "sha256sum:") orelse return null;
    const tail = std.mem.trimStart(u8, sums[i + "sha256sum:".len ..], " \t");
    if (tail.len < 64) return null;
    for (tail[0..64]) |ch| if (!std.ascii.isHex(ch)) return null;
    return tail[0..64];
}

pub fn pinned(text: []const u8) ?Version {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| if (std.mem.startsWith(u8, line, "version ")) return Version.parse(line["version ".len..]);
    return null;
}

fn fetch(session: *c.SoupSession, url: [*:0]const u8) ?*c.GBytes {
    const msg = c.soup_message_new("GET", url) orelse return null;
    defer c.g_object_unref(msg);
    var err: ?*c.GError = null;
    const bytes = c.soup_session_send_and_read(session, msg, null, &err);
    if (err) |e| {
        std.debug.print("{s}: {s}\n", .{ url, e.message });
        c.g_error_free(e);
        return null;
    }
    if (c.soup_message_get_status(msg) != c.SOUP_STATUS_OK) {
        if (bytes) |by| c.g_bytes_unref(by);
        std.debug.print("{s}: HTTP {d}\n", .{ url, c.soup_message_get_status(msg) });
        return null;
    }
    return bytes;
}

fn span(bytes: *c.GBytes) []const u8 {
    var len: usize = 0;
    const p: [*]const u8 = @ptrCast(c.g_bytes_get_data(bytes, &len) orelse return "");
    return p[0..len];
}

pub fn main() u8 {
    const session = c.soup_session_new() orelse return 1;
    defer c.g_object_unref(session);
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(PIN, &data, &len, null) == 0) {
        std.debug.print("run from the Fotone checkout: {s} not found\n", .{PIN});
        return 1;
    }
    defer c.g_free(data);
    const have = pinned(data[0..len]) orelse return 1;
    var want: Version = undefined;
    const arg = c.g_getenv("FOTONE_BUMP_TO");
    if (arg != null) {
        want = Version.parse(std.mem.span(arg)) orelse {
            std.debug.print("bad version {s}\n", .{arg});
            return 1;
        };
    } else {
        const index = fetch(session, RELEASES) orelse return 1;
        defer c.g_bytes_unref(index);
        want = latest(span(index)) orelse return 1;
    }
    if (!want.newer(have) and arg == null) {
        std.debug.print("up to date at {d}.{d}.{d}\n", .{ have.major, have.minor, have.micro });
        return 0;
    }
    const url = c.g_strdup_printf("%swpewebkit-%u.%u.%u.tar.xz", RELEASES, want.major, want.minor, want.micro);
    defer c.g_free(url);
    const sums_url = c.g_strdup_printf("%s.sums", url);
    defer c.g_free(sums_url);
    const sums = fetch(session, sums_url) orelse return 1;
    defer c.g_bytes_unref(sums);
    const sha = sha256Of(span(sums)) orelse {
        std.debug.print("no sha256 in {s}\n", .{sums_url});
        return 1;
    };
    const out = c.g_strdup_printf("version %u.%u.%u\nurl %s\nsha256 %.*s\n", want.major, want.minor, want.micro, url, @as(c_int, 64), sha.ptr);
    defer c.g_free(out);
    if (c.g_file_set_contents(PIN, out, -1, null) == 0) return 1;
    std.debug.print("{d}.{d}.{d} -> {d}.{d}.{d}\nrun zig build engine to apply patches/series on the new release\n", .{ have.major, have.minor, have.micro, want.major, want.minor, want.micro });
    return 0;
}

test "the newest stable release wins over development snapshots" {
    const index = "<a href=\"wpewebkit-2.52.3.tar.xz\"></a><a href=\"wpewebkit-2.54.2.tar.xz\"></a><a href=\"wpewebkit-2.55.1.tar.xz\"></a><a href=\"wpewebkit-2.54.10.tar.xz.sums\"></a>";
    const v = latest(index).?;
    try std.testing.expectEqual(Version{ .major = 2, .minor = 54, .micro = 10 }, v);
}

test "sums and pins parse" {
    const sums = "wpewebkit-2.54.2.tar.xz (47.3 MiB)\n   md5sum: 27bafca6c1b6298fe2b9584fa29ba9d0\n   sha256sum: f3284e19e47fcb5ac8c63c2e1c113dbd65b2423eb8a545f5b345707829004f56\n";
    try std.testing.expectEqualStrings("f3284e19e47fcb5ac8c63c2e1c113dbd65b2423eb8a545f5b345707829004f56", sha256Of(sums).?);
    try std.testing.expectEqual(Version{ .major = 2, .minor = 54, .micro = 2 }, pinned("version 2.54.2\nurl x\n").?);
    try std.testing.expect(Version.parse("2.54") == null);
}
