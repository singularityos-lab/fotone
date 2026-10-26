const std = @import("std");

const PRELUDE =
    \\#include <stdint.h>
    \\#include <stddef.h>
    \\#include <stdbool.h>
    \\#define WGPU_SKIP_PROCS 1
    \\#define WGPU_SKIP_DECLARATIONS 1
    \\typedef struct WTFString { void *impl; } WTFString;
    \\typedef struct WTFVector { void *buffer; uint32_t capacity; uint32_t size; } WTFVector;
    \\typedef struct WTFOptional32 { uint32_t value; bool engaged; } WTFOptional32;
    \\
;

const REPLACE = [_][2][]const u8{
    .{ "WTF::String&&", "WTFString *" },
    .{ "WTF::String", "WTFString" },
    .{ "Vector<WGPUTextureFormat>", "WTFVector" },
    .{ "std::optional<WGPUBool>", "WTFOptional32" },
    .{ "std::optional<uint32_t>", "WTFOptional32" },
    .{ "SWIFT_ESCAPABLE", "" },
    .{ "__unsafe_unretained ", "" },
    .{ "(^", "(*" },
};

const DROP = [_][]const u8{ "std::", "RetainPtr", "MachSendRight", "String wgpu", "unsafeMakeSpan", "WTFLogAlways" };

fn replaceAll(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var cur = try gpa.dupe(u8, line);
    for (REPLACE) |r| {
        const n = try std.mem.replaceOwned(u8, gpa, cur, r[0], r[1]);
        gpa.free(cur);
        cur = n;
    }
    return cur;
}

fn array(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const start = std.mem.indexOf(u8, line, "std::array<") orelse return null;
    const comma = std.mem.indexOfScalarPos(u8, line, start, ',') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, '>') orelse return null;
    const semi = std.mem.lastIndexOfScalar(u8, line, ';') orelse return null;
    const elem = line[start + "std::array<".len .. comma];
    const count = std.mem.trim(u8, line[comma + 1 .. close], " ");
    const name = std.mem.trim(u8, line[close + 1 .. semi], " ");
    return try std.fmt.allocPrint(gpa, "{s}{s} {s}[{s}];", .{ line[0..start], elem, name, count });
}

pub fn lower(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var skip_body = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trim(u8, line, " \t");
        if (skip_body) {
            if (std.mem.eql(u8, t, "}")) skip_body = false;
            continue;
        }
        if (std.mem.startsWith(u8, t, "#include")) continue;
        if (std.mem.startsWith(u8, t, "inline ") or std.mem.startsWith(u8, t, "static inline ")) {
            skip_body = true;
            continue;
        }
        if (std.mem.eql(u8, t, "#ifdef __cplusplus")) {
            try out.appendSlice(gpa, "#if 1\n");
            continue;
        }
        if (std.mem.startsWith(u8, t, "#ifdef __swift__") or std.mem.startsWith(u8, t, "#ifndef __swift__")) {
            try out.appendSlice(gpa, if (t[3] == 'd') "#if 0\n" else "#if 1\n");
            continue;
        }
        if (try array(gpa, line)) |a| {
            defer gpa.free(a);
            try out.appendSlice(gpa, a);
            try out.append(gpa, '\n');
            continue;
        }
        const r = try replaceAll(gpa, line);
        defer gpa.free(r);
        var drop = false;
        for (DROP) |d| {
            if (std.mem.indexOf(u8, r, d) != null) drop = true;
        }
        if (drop) continue;
        try out.appendSlice(gpa, r);
        try out.append(gpa, '\n');
    }
}

fn slurp(gpa: std.mem.Allocator, path: [*:0]const u8, out: *std.ArrayList(u8)) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.Open;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.Read;
        if (n == 0) return;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.Usage;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, PRELUDE);
    for (args[2..]) |path| {
        var text: std.ArrayList(u8) = .empty;
        try slurp(gpa, path, &text);
        try lower(gpa, text.items, &out);
    }
    const fd = std.c.open(args[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.Open;
    defer _ = std.c.close(fd);
    var left = out.items;
    while (left.len > 0) {
        const n = std.c.write(fd, left.ptr, left.len);
        if (n <= 0) return error.Write;
        left = left[@intCast(n)..];
    }
}

test "block typedefs and wtf members lower to c" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try lower(gpa,
        \\typedef void (^WGPUWorkItem)(void);
        \\    WGPU_NULLABLE WTF::String label;
        \\    std::array<uint32_t, WGPUShaderStage_Compute / 2 + 1> metalBinding;
        \\    auto entriesSpan() const { return unsafeMakeSpan(entries, entryCount); }
        \\inline std::span<const int> f(const int& x)
        \\{
        \\    return x;
        \\}
        \\#include <wtf/Vector.h>
    , &out);
    try std.testing.expectEqualStrings(
        \\typedef void (*WGPUWorkItem)(void);
        \\    WGPU_NULLABLE WTFString label;
        \\    uint32_t metalBinding[WGPUShaderStage_Compute / 2 + 1];
        \\
    , out.items);
}
