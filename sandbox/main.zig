const std = @import("std");
const linux = std.os.linux;

const ACCESS_EXECUTE: u64 = 1 << 0;
const ACCESS_WRITE_FILE: u64 = 1 << 1;
const ACCESS_READ_FILE: u64 = 1 << 2;
const ACCESS_READ_DIR: u64 = 1 << 3;
const ACCESS_REFER: u64 = 1 << 13;
const ACCESS_TRUNCATE: u64 = 1 << 14;
const ACCESS_IOCTL_DEV: u64 = 1 << 15;
const FILE_ACCESS = ACCESS_EXECUTE | ACCESS_WRITE_FILE | ACCESS_READ_FILE | ACCESS_TRUNCATE | ACCESS_IOCTL_DEV;
const READ_ACCESS = ACCESS_EXECUTE | ACCESS_READ_FILE | ACCESS_READ_DIR;
const NET_BIND_TCP: u64 = 1 << 0;
const NET_CONNECT_TCP: u64 = 1 << 1;
const CREATE_RULESET_VERSION: u32 = 1 << 0;
const RULE_PATH_BENEATH: u32 = 1;

const Ruleset = extern struct {
    fs: u64,
    net: u64,
    scoped: u64,
};

const PathBeneath = extern struct {
    allowed: u64 align(1),
    fd: i32 align(1),
};

pub const Kind = enum { web, gpu };

pub const Mode = enum { ro, rw };

pub const Path = struct {
    path: []const u8,
    mode: Mode,
};

const system_ro = [_][]const u8{ "/usr", "/etc", "/opt", "/lib", "/lib64", "/bin", "/sbin", "/sys", "/proc" };
const system_rw = [_][]const u8{ "/dev/dri", "/dev/null", "/dev/zero", "/dev/full", "/dev/random", "/dev/urandom", "/dev/shm", "/dev/udmabuf", "/dev/nvidiactl", "/dev/nvidia0", "/dev/nvidia-modeset", "/dev/nvidia-uvm", "/dev/sinty-compute" };
const home_ro = [_][]const u8{ ".local/share/fonts", ".fonts", ".config/fontconfig" };
const home_rw = [_][]const u8{ ".cache/fontconfig", ".cache/gstreamer-1.0", ".local/share/fotone/widevine" };
const caches = [_][]const u8{ "mesa_shader_cache", "mesa_shader_cache_db", "nvidia", "fotone" };

fn abi() u32 {
    const r = linux.syscall3(.landlock_create_ruleset, 0, 0, CREATE_RULESET_VERSION);
    const s: isize = @bitCast(r);
    return if (s < 0) 0 else @intCast(s);
}

pub fn handledFs(version: u32) u64 {
    var fs: u64 = (1 << 13) - 1;
    if (version >= 2) fs |= ACCESS_REFER;
    if (version >= 3) fs |= ACCESS_TRUNCATE;
    if (version >= 5) fs |= ACCESS_IOCTL_DEV;
    return fs;
}

fn addPath(ruleset: i32, path: []const u8, allowed: u64, handled: u64) void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd_r = linux.open(@ptrCast(&buf), .{ .PATH = true, .CLOEXEC = true }, 0);
    const fd: isize = @bitCast(fd_r);
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    var st: linux.Statx = undefined;
    _ = linux.statx(@intCast(fd), "", 0x1000, .{ .TYPE = true }, &st);
    const dir = (st.mode & linux.S.IFMT) == linux.S.IFDIR;
    var access = allowed & handled;
    if (!dir) access &= FILE_ACCESS;
    if (access == 0) return;
    const attr: PathBeneath = .{ .allowed = access, .fd = @intCast(fd) };
    _ = linux.syscall4(.landlock_add_rule, @as(usize, @bitCast(@as(isize, ruleset))), RULE_PATH_BENEATH, @intFromPtr(&attr), 0);
}

fn landlock(paths: []const Path) bool {
    const version = abi();
    if (version == 0) return false;
    const handled = handledFs(version);
    const attr: Ruleset = .{ .fs = handled, .net = if (version >= 4) NET_BIND_TCP | NET_CONNECT_TCP else 0, .scoped = 0 };
    const size: usize = if (version >= 6) @sizeOf(Ruleset) else if (version >= 4) 16 else 8;
    const r: isize = @bitCast(linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), size, 0));
    if (r < 0) return false;
    const ruleset: i32 = @intCast(r);
    defer _ = linux.close(ruleset);
    for (paths) |p| addPath(ruleset, p.path, if (p.mode == .ro) READ_ACCESS else handled, handled);
    const done: isize = @bitCast(linux.syscall2(.landlock_restrict_self, @as(usize, @bitCast(@as(isize, ruleset))), 0));
    return done == 0;
}

const Insn = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const Fprog = extern struct {
    len: u16,
    filter: [*]const Insn,
};

fn stmt(code: u16, k: u32) Insn {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}

fn jump(code: u16, k: u32, jt: u8, jf: u8) Insn {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

const LD_W_ABS = 0x20;
const JEQ_K = 0x15;
const JGE_K = 0x35;
const AND_K = 0x54;
const RET_K = 0x06;
const RET_ALLOW: u32 = 0x7fff0000;
const RET_ERRNO: u32 = 0x00050000;
const RET_KILL: u32 = 0x80000000;
const AUDIT_ARCH_X86_64: u32 = 0xc000003e;
const OFF_NR = 0;
const OFF_ARCH = 4;
const OFF_ARG0 = 16;
const OFF_ARG1 = 24;

const Block = struct { nr: linux.SYS, errno: u32 };

const blocked = [_]Block{
    .{ .nr = .syslog, .errno = 1 },        .{ .nr = .uselib, .errno = 1 },         .{ .nr = .acct, .errno = 1 },
    .{ .nr = .modify_ldt, .errno = 1 },    .{ .nr = .quotactl, .errno = 1 },       .{ .nr = .add_key, .errno = 1 },
    .{ .nr = .keyctl, .errno = 1 },        .{ .nr = .request_key, .errno = 1 },    .{ .nr = .move_pages, .errno = 1 },
    .{ .nr = .mbind, .errno = 1 },         .{ .nr = .get_mempolicy, .errno = 1 },  .{ .nr = .set_mempolicy, .errno = 1 },
    .{ .nr = .migrate_pages, .errno = 1 }, .{ .nr = .unshare, .errno = 1 },        .{ .nr = .setns, .errno = 1 },
    .{ .nr = .mount, .errno = 1 },         .{ .nr = .umount2, .errno = 1 },        .{ .nr = .pivot_root, .errno = 1 },
    .{ .nr = .chroot, .errno = 1 },        .{ .nr = .clone3, .errno = 38 },        .{ .nr = .open_tree, .errno = 38 },
    .{ .nr = .move_mount, .errno = 38 },   .{ .nr = .fsopen, .errno = 38 },        .{ .nr = .fsconfig, .errno = 38 },
    .{ .nr = .fsmount, .errno = 38 },      .{ .nr = .fspick, .errno = 38 },        .{ .nr = .mount_setattr, .errno = 38 },
    .{ .nr = .perf_event_open, .errno = 1 }, .{ .nr = .personality, .errno = 1 },  .{ .nr = .ptrace, .errno = 1 },
    .{ .nr = .kexec_load, .errno = 1 },    .{ .nr = .kexec_file_load, .errno = 1 }, .{ .nr = .bpf, .errno = 1 },
    .{ .nr = .userfaultfd, .errno = 1 },
};

const CLONE_NEWUSER: u32 = 0x10000000;
const TIOCSTI: u32 = 0x5412;
const TIOCLINUX: u32 = 0x541c;

pub fn filter() [blocked.len * 2 + 22]Insn {
    var f: [blocked.len * 2 + 22]Insn = undefined;
    var i: usize = 0;
    f[i] = stmt(LD_W_ABS, OFF_ARCH);
    i += 1;
    f[i] = jump(JEQ_K, AUDIT_ARCH_X86_64, 1, 0);
    i += 1;
    f[i] = stmt(RET_K, RET_KILL);
    i += 1;
    f[i] = stmt(LD_W_ABS, OFF_NR);
    i += 1;
    f[i] = jump(JGE_K, 0x40000000, 0, 1);
    i += 1;
    f[i] = stmt(RET_K, RET_ERRNO | 38);
    i += 1;
    for (blocked) |b| {
        f[i] = jump(JEQ_K, @intCast(@intFromEnum(b.nr)), 0, 1);
        f[i + 1] = stmt(RET_K, RET_ERRNO | b.errno);
        i += 2;
    }
    f[i] = jump(JEQ_K, @intCast(@intFromEnum(linux.SYS.clone)), 0, 4);
    f[i + 1] = stmt(LD_W_ABS, OFF_ARG0);
    f[i + 2] = stmt(AND_K, CLONE_NEWUSER);
    f[i + 3] = jump(JEQ_K, CLONE_NEWUSER, 0, 1);
    f[i + 4] = stmt(RET_K, RET_ERRNO | 1);
    i += 5;
    f[i] = stmt(LD_W_ABS, OFF_NR);
    f[i + 1] = jump(JEQ_K, @intCast(@intFromEnum(linux.SYS.ioctl)), 0, 5);
    f[i + 2] = stmt(LD_W_ABS, OFF_ARG1);
    f[i + 3] = jump(JEQ_K, TIOCSTI, 2, 0);
    f[i + 4] = jump(JEQ_K, TIOCLINUX, 1, 0);
    f[i + 5] = stmt(RET_K, RET_ALLOW);
    f[i + 6] = stmt(RET_K, RET_ERRNO | 1);
    i += 7;
    f[i] = stmt(RET_K, RET_ALLOW);
    i += 1;
    while (i < f.len) : (i += 1) f[i] = stmt(RET_K, RET_ALLOW);
    return f;
}

fn seccomp() bool {
    const f = filter();
    const prog: Fprog = .{ .len = f.len, .filter = &f };
    const r: isize = @bitCast(linux.syscall3(.seccomp, 1, 0, @intFromPtr(&prog)));
    return r == 0;
}

fn usage() noreturn {
    std.debug.print("usage: fotone-sandbox web|gpu [--ro PATH] [--rw PATH] -- COMMAND [ARG]...\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 4) usage();
    _ = std.meta.stringToEnum(Kind, args[1]) orelse usage();
    var paths: std.ArrayList(Path) = .empty;
    for (system_ro) |p| try paths.append(gpa, .{ .path = p, .mode = .ro });
    for (system_rw) |p| try paths.append(gpa, .{ .path = p, .mode = .rw });
    if (init.environ_map.get("HOME")) |home| {
        for (home_ro) |p| try paths.append(gpa, .{ .path = try std.fs.path.join(gpa, &.{ home, p }), .mode = .ro });
        for (home_rw) |p| try paths.append(gpa, .{ .path = try std.fs.path.join(gpa, &.{ home, p }), .mode = .rw });
    }
    const cache_home = if (init.environ_map.get("XDG_CACHE_HOME")) |d| d else if (init.environ_map.get("HOME")) |home| try std.fs.path.join(gpa, &.{ home, ".cache" }) else null;
    if (cache_home) |base| for (caches) |name| {
        _ = linux.mkdir(try gpa.dupeZ(u8, base), 0o700);
        const dir = try std.fs.path.joinZ(gpa, &.{ base, name });
        _ = linux.mkdir(dir, 0o700);
        try paths.append(gpa, .{ .path = dir, .mode = .rw });
    };
    if (init.environ_map.get("XDG_DATA_HOME")) |d| try paths.append(gpa, .{ .path = try std.fs.path.join(gpa, &.{ d, "fotone", "widevine" }), .mode = .rw });
    if (init.environ_map.get("LD_LIBRARY_PATH")) |ld| {
        var it = std.mem.tokenizeScalar(u8, ld, ':');
        while (it.next()) |p| try paths.append(gpa, .{ .path = p, .mode = .ro });
    }
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (i + 1 >= args.len) usage();
        const mode: Mode = if (std.mem.eql(u8, a, "--ro")) .ro else if (std.mem.eql(u8, a, "--rw")) .rw else usage();
        try paths.append(gpa, .{ .path = args[i + 1], .mode = mode });
        i += 1;
    }
    if (i + 1 >= args.len) usage();
    const command = args[i + 1 ..];
    try paths.append(gpa, .{ .path = std.fs.path.dirname(command[0]) orelse "/", .mode = .ro });

    if (linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0) != 0) {
        std.debug.print("fotone-sandbox: no_new_privs failed\n", .{});
        return 1;
    }
    if (!landlock(paths.items)) std.debug.print("fotone-sandbox: landlock unavailable, filesystem not restricted\n", .{});
    if (!seccomp()) {
        std.debug.print("fotone-sandbox: seccomp failed\n", .{});
        return 1;
    }
    const argv = try gpa.allocSentinel(?[*:0]const u8, command.len, null);
    for (command, 0..) |a, n| argv[n] = (try gpa.dupeZ(u8, a)).ptr;
    const envp = try init.environ_map.createPosixBlock(gpa, .{});
    const err = linux.execve(argv[0].?, argv.ptr, envp.slice.ptr);
    std.debug.print("fotone-sandbox: exec {s} failed: {d}\n", .{ command[0], @as(isize, @bitCast(err)) });
    return 127;
}

test "the filter ends by allowing and covers every blocked call" {
    const f = filter();
    try std.testing.expectEqual(@as(u32, RET_ALLOW), f[f.len - 1].k);
    var found: usize = 0;
    for (f) |insn| {
        for (blocked) |b| {
            if (insn.code == JEQ_K and insn.k == @intFromEnum(b.nr)) found += 1;
        }
    }
    try std.testing.expect(found >= blocked.len);
}

test "handled access grows with the landlock abi" {
    try std.testing.expect(handledFs(1) & ACCESS_REFER == 0);
    try std.testing.expect(handledFs(5) & ACCESS_IOCTL_DEV != 0);
}
