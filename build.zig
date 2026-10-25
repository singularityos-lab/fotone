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
    "-DENABLE_WEB_RTC=ON",
    "-DUSE_GSTREAMER_WEBRTC=ON",
    "-DUSE_LIBRICE=OFF",
    "-DENABLE_ENCRYPTED_MEDIA=ON",
    "-DENABLE_THUNDER=ON",
    "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-Bsymbolic-functions",
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
    _ = src;
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ out, "stage", "usr", "local", "include", "wpe-webkit-2.0", "wpe-platform" }) });
    mod.addIncludePath(b.path("platform"));
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ out, "stage", "usr", "local", "lib" }) });
    mod.addRPath(.{ .cwd_relative = b.pathJoin(&.{ out, "stage", "usr", "local", "lib" }) });
    mod.linkSystemLibrary("WPEWebKit-2.0", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("ocdm", .{ .use_pkg_config = .no, .needed = true });
    for ([_][]const u8{ "glib-2.0", "gobject-2.0", "gio-2.0", "epoxy", "gbm", "libdrm" }) |s| mod.linkSystemLibrary(s, .{});
    return mod;
}

fn webviewModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, src: []const u8, out: []const u8) *std.Build.Module {
    const mod = platformModule(b, root, target, optimize, src, out);
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ out, "stage", "usr", "local", "include", "wpe-webkit-2.0" }) });
    mod.addIncludePath(b.path("webview"));
    mod.linkSystemLibrary("gtk4", .{});
    mod.linkSystemLibrary("libsoup-3.0", .{});
    mod.linkSystemLibrary("libsecret-1", .{});
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

    const hooks = b.addLibrary(.{
        .name = "fotone-hooks",
        .linkage = .static,
        .root_module = b.createModule(.{ .root_source_file = b.path("hooks/hooks.zig"), .target = target, .optimize = .ReleaseFast, .pic = true }),
    });

    const ocdm_mod = b.createModule(.{ .root_source_file = b.path("ocdm/ocdm.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = true });
    ocdm_mod.addIncludePath(b.path("ocdm"));
    ocdm_mod.linkSystemLibrary("gstreamer-1.0", .{});
    const ocdm = b.addLibrary(.{
        .name = "ocdm",
        .linkage = .dynamic,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .root_module = ocdm_mod,
        .use_llvm = true,
    });
    b.installArtifact(ocdm);

    const configure = b.addSystemCommand(&.{ "cmake", "-G", "Ninja", "-S", src, "-B", out });
    configure.addArgs(&engine_flags);
    configure.addArg(b.fmt("-DTHUNDER_INCLUDE_DIR={s}", .{b.pathFromRoot("ocdm")}));
    configure.addPrefixedFileArg("-DTHUNDER_LIBRARY=", ocdm.getEmittedBin());
    configure.addPrefixedFileArg("-DFOTONE_HOOKS=", hooks.getEmittedBin());
    configure.step.dependOn(&fetch.step);

    const compile = b.addSystemCommand(&.{ "ninja", "-C", out, b.fmt("-j{d}", .{jobs}) });
    compile.step.dependOn(&configure.step);
    const stage = b.addSystemCommand(&.{ "cmake", "--install", out });
    stage.setEnvironmentVariable("DESTDIR", b.pathJoin(&.{ out, "stage" }));
    stage.step.dependOn(&compile.step);
    const stage_ocdm = b.addSystemCommand(&.{ "cp", "-P" });
    stage_ocdm.addFileArg(ocdm.getEmittedBin());
    stage_ocdm.addArg(b.pathJoin(&.{ out, "stage", "usr", "local", "lib" }));
    stage_ocdm.step.dependOn(&stage.step);
    b.step("engine", "fetch, patch and build WPE WebKit").dependOn(&stage_ocdm.step);

    const platform = b.addLibrary(.{
        .name = "fotone",
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .root_module = platformModule(b, "platform/fotone.zig", target, optimize, src, out),
        .use_llvm = true,
    });
    platform.installHeader(b.path("platform/fotone.h"), "fotone/fotone.h");
    b.installArtifact(platform);

    const webview_mod = webviewModule(b, "webview/sitwebview.zig", target, optimize, src, out);
    webview_mod.linkLibrary(platform);
    const webview = b.addLibrary(.{
        .name = "sitwebview",
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .root_module = webview_mod,
        .use_llvm = true,
    });
    webview.installHeader(b.path("webview/sitwebview.h"), "sit/sitwebview.h");
    b.installArtifact(webview);
    b.installFile("webview/site-exceptions.json", "share/fotone/site-exceptions.json");

    const viewer_mod = webviewModule(b, "viewer/main.zig", target, optimize, src, out);
    viewer_mod.addIncludePath(b.path("viewer"));
    viewer_mod.linkLibrary(webview);
    viewer_mod.linkLibrary(platform);
    const viewer = b.addExecutable(.{ .name = "fotone-viewer", .root_module = viewer_mod, .use_llvm = true });
    b.installArtifact(viewer);
    const run = b.addRunArtifact(viewer);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "open a page in the viewer").dependOn(&run.step);

    const proxy_mod = webviewModule(b, "proxy/proxy.zig", target, optimize, src, out);
    proxy_mod.addIncludePath(b.path("proxy"));
    proxy_mod.linkLibrary(webview);
    const proxy = b.addLibrary(.{
        .name = "webkitgtk-6.0",
        .linkage = .dynamic,
        .version = .{ .major = 4, .minor = 0, .patch = 0 },
        .root_module = proxy_mod,
        .use_llvm = true,
    });
    proxy.setVersionScript(b.path("proxy/symbols.map"));
    proxy_mod.linkSystemLibrary("WPEWebKit-2.0", .{ .use_pkg_config = .no, .needed = true });
    b.installArtifact(proxy);

    const jsc_mod = b.createModule(.{ .root_source_file = b.path("proxy/jsc.zig"), .target = target, .optimize = optimize, .pic = true, .link_libc = true });
    jsc_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ out, "stage", "usr", "local", "lib" }) });
    jsc_mod.linkSystemLibrary("WPEWebKit-2.0", .{ .use_pkg_config = .no, .needed = true });
    const jsc = b.addLibrary(.{
        .name = "javascriptcoregtk-6.0",
        .linkage = .dynamic,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .root_module = jsc_mod,
        .use_llvm = true,
    });
    b.installArtifact(jsc);

    const compat_mod = b.createModule(.{ .root_source_file = b.path("compat/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    compat_mod.addIncludePath(b.path("compat"));
    compat_mod.linkSystemLibrary("gtk4", .{});
    b.installArtifact(b.addExecutable(.{ .name = "fotone-compat", .root_module = compat_mod, .use_llvm = true }));

    const sandbox_mod = b.createModule(.{ .root_source_file = b.path("sandbox/main.zig"), .target = target, .optimize = optimize });
    const sandbox = b.addExecutable(.{ .name = "fotone-sandbox", .root_module = sandbox_mod });
    b.getInstallStep().dependOn(&b.addInstallArtifact(sandbox, .{ .dest_dir = .{ .override = .{ .custom = "libexec/wpe-webkit-2.0" } } }).step);

    const bump_mod = b.createModule(.{ .root_source_file = b.path("bump/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bump_mod.addIncludePath(b.path("bump"));
    bump_mod.linkSystemLibrary("libsoup-3.0", .{});
    const bump = b.addRunArtifact(b.addExecutable(.{ .name = "fotone-bump", .root_module = bump_mod, .use_llvm = true }));
    bump.setCwd(b.path("."));
    b.step("bump", "move the upstream pin to the newest stable WPE WebKit release").dependOn(&bump.step);

    const t = b.addTest(.{ .root_module = platformModule(b, "platform/fotone.zig", target, optimize, src, out), .use_llvm = true });
    const wt_mod = webviewModule(b, "webview/sitwebview.zig", target, optimize, src, out);
    wt_mod.linkLibrary(platform);
    const wt = b.addTest(.{ .root_module = wt_mod, .use_llvm = true });
    const pt_mod = webviewModule(b, "proxy/proxy.zig", target, optimize, src, out);
    pt_mod.addIncludePath(b.path("proxy"));
    pt_mod.linkLibrary(webview);
    const pt = b.addTest(.{ .root_module = pt_mod, .use_llvm = true });
    const test_step = b.step("test", "run tests");
    test_step.dependOn(&b.addRunArtifact(pt).step);
    test_step.dependOn(&b.addRunArtifact(t).step);
    test_step.dependOn(&b.addRunArtifact(wt).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sandbox_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hooks.root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ocdm_mod, .use_llvm = true })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bump_mod, .use_llvm = true })).step);
}
