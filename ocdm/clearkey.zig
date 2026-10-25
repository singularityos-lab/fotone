const std = @import("std");

pub const KEY_SYSTEM = "org.w3.clearkey";

pub const Kid = [16]u8;

pub fn decodeB64(out: []u8, text: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    const d = std.base64.url_safe_no_pad.Decoder;
    const n = try d.calcSizeForSlice(trimmed);
    if (n > out.len) return error.TooLong;
    try d.decode(out[0..n], trimmed);
    return out[0..n];
}

pub fn psshKids(data: []const u8, out: []Kid) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (at + 8 <= data.len) {
        const size = std.mem.readInt(u32, data[at..][0..4], .big);
        if (size < 8 or at + size > data.len) break;
        const box = data[at .. at + size];
        at += size;
        if (!std.mem.eql(u8, box[4..8], "pssh") or box.len < 32) continue;
        if (box[8] == 0) continue;
        const count = std.mem.readInt(u32, box[28..32], .big);
        var k: usize = 0;
        while (k < count and 32 + (k + 1) * 16 <= box.len and n < out.len) : (k += 1) {
            @memcpy(&out[n], box[32 + k * 16 ..][0..16]);
            n += 1;
        }
    }
    return n;
}

pub fn keyIdsKids(json: []const u8, out: []Kid) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json, .{});
    defer parsed.deinit();
    const kids = (if (parsed.value == .object) parsed.value.object.get("kids") else null) orelse return error.NoKids;
    if (kids != .array) return error.NoKids;
    var n: usize = 0;
    for (kids.array.items) |k| {
        if (k != .string or n == out.len) continue;
        var buf: [32]u8 = undefined;
        const raw = decodeB64(&buf, k.string) catch continue;
        if (raw.len != 16) continue;
        @memcpy(&out[n], raw);
        n += 1;
    }
    return n;
}

pub fn initKids(init_type: []const u8, data: []const u8, out: []Kid) !usize {
    if (std.mem.eql(u8, init_type, "cenc")) return psshKids(data, out);
    if (std.mem.eql(u8, init_type, "keyids")) return keyIdsKids(data, out);
    if (std.mem.eql(u8, init_type, "webm")) {
        if (data.len != 16 or out.len == 0) return error.BadInitData;
        @memcpy(&out[0], data);
        return 1;
    }
    return error.BadInitData;
}

pub fn request(out: []u8, kids: []const Kid, persistent: bool) ![]u8 {
    var w: std.ArrayList(u8) = .initBuffer(out);
    try w.appendSliceBounded("{\"kids\":[");
    for (kids, 0..) |k, i| {
        if (i > 0) try w.appendBounded(',');
        try w.appendBounded('"');
        var enc: [24]u8 = undefined;
        try w.appendSliceBounded(std.base64.url_safe_no_pad.Encoder.encode(&enc, &k));
        try w.appendBounded('"');
    }
    try w.appendSliceBounded(if (persistent) "],\"type\":\"persistent-license\"}" else "],\"type\":\"temporary\"}");
    return w.items;
}

pub const Key = struct {
    id: Kid,
    value: [16]u8,
};

pub fn license(json: []const u8, out: []Key) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json, .{});
    defer parsed.deinit();
    const keys = (if (parsed.value == .object) parsed.value.object.get("keys") else null) orelse return error.NoKeys;
    if (keys != .array) return error.NoKeys;
    var n: usize = 0;
    for (keys.array.items) |k| {
        if (k != .object or n == out.len) continue;
        const kty = k.object.get("kty") orelse continue;
        if (kty != .string or !std.mem.eql(u8, kty.string, "oct")) continue;
        const kid = k.object.get("kid") orelse continue;
        const value = k.object.get("k") orelse continue;
        if (kid != .string or value != .string) continue;
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        const id = decodeB64(&a, kid.string) catch continue;
        const v = decodeB64(&b, value.string) catch continue;
        if (id.len != 16 or v.len != 16) continue;
        @memcpy(&out[n].id, id);
        @memcpy(&out[n].value, v);
        n += 1;
    }
    if (n == 0) return error.NoKeys;
    return n;
}

test "init data gives the key ids to ask for" {
    var kids: [4]Kid = undefined;
    var pssh: [52]u8 = .{0} ** 52;
    std.mem.writeInt(u32, pssh[0..4], 52, .big);
    @memcpy(pssh[4..8], "pssh");
    pssh[8] = 1;
    std.mem.writeInt(u32, pssh[28..32], 1, .big);
    @memset(pssh[32..48], 0xab);
    try std.testing.expectEqual(@as(usize, 1), try initKids("cenc", &pssh, &kids));
    try std.testing.expectEqual(@as(u8, 0xab), kids[0][15]);
    try std.testing.expectEqual(@as(usize, 1), try initKids("keyids", "{\"kids\":[\"AAECAwQFBgcICQoLDA0ODw\"]}", &kids));
    try std.testing.expectEqual(@as(u8, 15), kids[0][15]);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{\"kids\":[\"AAECAwQFBgcICQoLDA0ODw\"],\"type\":\"temporary\"}", try request(&buf, kids[0..1], false));
}

test "licenses are JSON web key sets" {
    var keys: [2]Key = undefined;
    const n = try license("{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AAECAwQFBgcICQoLDA0ODw\",\"k\":\"EBESExQVFhcYGRobHB0eHw==\"}],\"type\":\"temporary\"}", &keys);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1f), keys[0].value[15]);
}
