const std = @import("std");

const pin = @embedFile("upstream/wpewebkit");

const engine_flags = [_][]const u8{
    "-DPORT=WPE",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_C_COMPILER=clang",
    "-DCMAKE_CXX_COMPILER=clang++",
    "-DENABLE_WPE_PLATFORM=ON",
    "-DENABLE_WPE_LEGACY_API=OFF",
    "-DENABLE_WPE_QT_API=OFF",
    "-DENABLE_DOCUMENTATION=OFF",
    "-DENABLE_INTROSPECTION=OFF",
    "-DENABLE_BUBBLEWRAP_SANDBOX=OFF",
    "-DENABLE_SPEECH_SYNTHESIS=OFF",
    "-DENABLE_MINIBROWSER=OFF",
    "-DENABLE_API_TESTS=OFF",
    "-DENABLE_GAMEPAD=OFF",
    "-DENABLE_WEBDRIVER=OFF",
    "-DENABLE_JOURNALD_LOG=OFF",
    "-DUSE_LIBBACKTRACE=OFF",
    "-DUSE_SYSPROF_CAPTURE=OFF",
};

fn pinValue(comptime key: []const u8) []const u8 {
    @setEvalBranchQuota(100000);
    var it = std.mem.tokenizeScalar(u8, pin, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key ++ " ")) return line[key.len + 1 ..];
    }
    @compileError("upstream/wpewebkit has no " ++ key);
}

fn platformModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, src: []const u8, out: []const u8) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ src, "Source", "WebKit", "WPEPlatform" }) });
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ out, "DerivedSources", "WPEPlatform" }) });
    mod.addIncludePath(b.path("platform"));
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ out, "lib" }) });
    mod.addRPath(.{ .cwd_relative = b.pathJoin(&.{ out, "lib" }) });
    mod.linkSystemLibrary("WPEWebKit-2.0", .{ .use_pkg_config = .no });
    for ([_][]const u8{ "glib-2.0", "gobject-2.0", "gio-2.0", "epoxy", "gbm", "libdrm" }) |s| mod.linkSystemLibrary(s, .{});
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = comptime pinValue("version");
    const src = b.option([]const u8, "upstream-src", "unpacked WPE WebKit tree") orelse b.pathFromRoot(b.fmt("upstream/src/wpewebkit-{s}", .{version}));
    const out = b.option([]const u8, "upstream-build", "WPE WebKit build directory") orelse b.pathFromRoot("upstream/build");
    const jobs = b.option(u32, "jobs", "parallel engine compile jobs") orelse 2;

    const fetch = b.addSystemCommand(&.{ "sh", "-ec",
        \\[ -d "$1" ] && exit 0
        \\mkdir -p "$(dirname "$1")"
        \\t="$1.tar.xz"
        \\[ -f "$t" ] || curl -fsSL -o "$t" "$2"
        \\echo "$3  $t" | sha256sum -c -
        \\tar -C "$(dirname "$1")" -xf "$t"
        \\for p in $(cat "$4"); do patch -d "$1" -p1 -N < "$(dirname "$4")/$p"; done
    , "fetch", src, comptime pinValue("url"), comptime pinValue("sha256"), b.pathFromRoot("patches/series") });

    const configure = b.addSystemCommand(&.{ "cmake", "-G", "Ninja", "-S", src, "-B", out });
    configure.addArgs(&engine_flags);
    configure.step.dependOn(&fetch.step);

    const compile = b.addSystemCommand(&.{ "ninja", "-C", out, b.fmt("-j{d}", .{jobs}) });
    compile.step.dependOn(&configure.step);
    b.step("engine", "fetch, patch and build WPE WebKit").dependOn(&compile.step);

    const platform = b.addLibrary(.{
        .name = "fotone",
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .root_module = platformModule(b, "platform/fotone.zig", target, optimize, src, out),
        .use_llvm = true,
    });
    platform.installHeader(b.path("platform/fotone.h"), "fotone/fotone.h");
    b.installArtifact(platform);

    const t = b.addTest(.{ .root_module = platformModule(b, "platform/fotone.zig", target, optimize, src, out), .use_llvm = true });
    b.step("test", "run tests").dependOn(&b.addRunArtifact(t).step);
}
