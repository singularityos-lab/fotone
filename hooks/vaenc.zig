const std = @import("std");
const linux = std.os.linux;

pub const Status = c_int;
pub const Display = ?*anyopaque;
pub const Id = u32;
pub const invalid: Id = 0xffffffff;

const profile_constrained_baseline: c_int = 13;
const entry_enc_slice: c_int = 6;
const entry_enc_slice_lp: c_int = 8;
const attrib_rt_format: c_int = 0;
const attrib_rate_control: c_int = 5;
pub const rt_yuv420: u32 = 0x1;
const rc_cbr: u32 = 0x2;
const rc_vbr: u32 = 0x4;
pub const progressive: c_int = 0x1;
pub const fourcc_nv12: u32 = 0x3231564E;

const buf_coded: c_int = 21;
const buf_seq: c_int = 22;
const buf_pic: c_int = 23;
const buf_slice: c_int = 24;
const buf_misc: c_int = 27;
const misc_frame_rate: u32 = 0;
const misc_rate_control: u32 = 1;

pub const pic_invalid: u32 = 0x1;
pub const pic_short_term: u32 = 0x8;

pub const Picture = extern struct {
    picture_id: Id = invalid,
    frame_idx: u32 = 0,
    flags: u32 = pic_invalid,
    top_order: i32 = 0,
    bottom_order: i32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const Sequence = extern struct {
    seq_parameter_set_id: u8 = 0,
    level_idc: u8 = 0,
    intra_period: u32 = 0,
    intra_idr_period: u32 = 0,
    ip_period: u32 = 0,
    bits_per_second: u32 = 0,
    max_num_ref_frames: u32 = 0,
    picture_width_in_mbs: u16 = 0,
    picture_height_in_mbs: u16 = 0,
    seq_fields: u32 = 0,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    num_ref_frames_in_pic_order_cnt_cycle: u8 = 0,
    offset_for_non_ref_pic: i32 = 0,
    offset_for_top_to_bottom_field: i32 = 0,
    offset_for_ref_frame: [256]i32 = @splat(0),
    frame_cropping_flag: u8 = 0,
    frame_crop_left_offset: u32 = 0,
    frame_crop_right_offset: u32 = 0,
    frame_crop_top_offset: u32 = 0,
    frame_crop_bottom_offset: u32 = 0,
    vui_parameters_present_flag: u8 = 0,
    vui_fields: u32 = 0,
    aspect_ratio_idc: u8 = 0,
    sar_width: u32 = 0,
    sar_height: u32 = 0,
    num_units_in_tick: u32 = 0,
    time_scale: u32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const PictureParams = extern struct {
    curr: Picture = .{},
    refs: [16]Picture = @splat(.{}),
    coded_buf: Id = invalid,
    pic_parameter_set_id: u8 = 0,
    seq_parameter_set_id: u8 = 0,
    last_picture: u8 = 0,
    frame_num: u16 = 0,
    pic_init_qp: u8 = 0,
    num_ref_idx_l0_active_minus1: u8 = 0,
    num_ref_idx_l1_active_minus1: u8 = 0,
    chroma_qp_index_offset: i8 = 0,
    second_chroma_qp_index_offset: i8 = 0,
    pic_fields: u32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const Slice = extern struct {
    macroblock_address: u32 = 0,
    num_macroblocks: u32 = 0,
    macroblock_info: Id = invalid,
    slice_type: u8 = 0,
    pic_parameter_set_id: u8 = 0,
    idr_pic_id: u16 = 0,
    pic_order_cnt_lsb: u16 = 0,
    delta_pic_order_cnt_bottom: i32 = 0,
    delta_pic_order_cnt: [2]i32 = .{ 0, 0 },
    direct_spatial_mv_pred_flag: u8 = 0,
    num_ref_idx_active_override_flag: u8 = 0,
    num_ref_idx_l0_active_minus1: u8 = 0,
    num_ref_idx_l1_active_minus1: u8 = 0,
    ref_list0: [32]Picture = @splat(.{}),
    ref_list1: [32]Picture = @splat(.{}),
    luma_log2_weight_denom: u8 = 0,
    chroma_log2_weight_denom: u8 = 0,
    luma_weight_l0_flag: u8 = 0,
    luma_weight_l0: [32]i16 = @splat(0),
    luma_offset_l0: [32]i16 = @splat(0),
    chroma_weight_l0_flag: u8 = 0,
    chroma_weight_l0: [32][2]i16 = @splat(.{ 0, 0 }),
    chroma_offset_l0: [32][2]i16 = @splat(.{ 0, 0 }),
    luma_weight_l1_flag: u8 = 0,
    luma_weight_l1: [32]i16 = @splat(0),
    luma_offset_l1: [32]i16 = @splat(0),
    chroma_weight_l1_flag: u8 = 0,
    chroma_weight_l1: [32][2]i16 = @splat(.{ 0, 0 }),
    chroma_offset_l1: [32][2]i16 = @splat(.{ 0, 0 }),
    cabac_init_idc: u8 = 0,
    slice_qp_delta: i8 = 0,
    disable_deblocking_filter_idc: u8 = 0,
    slice_alpha_c0_offset_div2: i8 = 0,
    slice_beta_offset_div2: i8 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

const RateControl = extern struct {
    kind: u32 = misc_rate_control,
    bits_per_second: u32 = 0,
    target_percentage: u32 = 100,
    window_size: u32 = 1000,
    initial_qp: u32 = 26,
    min_qp: u32 = 18,
    basic_unit_size: u32 = 0,
    rc_flags: u32 = 0,
    icq_quality_factor: u32 = 0,
    max_qp: u32 = 0,
    quality_factor: u32 = 0,
    target_frame_size: u32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

const FrameRate = extern struct {
    kind: u32 = misc_frame_rate,
    framerate: u32 = 30,
    flags: u32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const ImageFormat = extern struct { fourcc: u32, byte_order: u32, bits_per_pixel: u32, depth: u32, masks: [4]u32, reserved: [4]u32 };

pub const Image = extern struct {
    image_id: Id,
    format: ImageFormat,
    buf: Id,
    width: u16,
    height: u16,
    data_size: u32,
    num_planes: u32,
    pitches: [3]u32,
    offsets: [3]u32,
    num_palette_entries: i32,
    entry_bytes: i32,
    component_order: [4]i8,
    reserved: [4]u32,
};

pub const Segment = extern struct {
    size: u32,
    bit_offset: u32,
    status: u32,
    reserved: u32,
    buf: ?[*]u8,
    next: ?*Segment,
    va_reserved: [4]u32,
};

pub const Attrib = extern struct { kind: c_int, value: u32 };

pub const Api = struct {
    getDisplayDRM: *const fn (c_int) callconv(.c) Display,
    initialize: *const fn (Display, *c_int, *c_int) callconv(.c) Status,
    terminate: *const fn (Display) callconv(.c) Status,
    queryConfigEntrypoints: *const fn (Display, c_int, [*]c_int, *c_int) callconv(.c) Status,
    maxNumEntrypoints: *const fn (Display) callconv(.c) c_int,
    getConfigAttributes: *const fn (Display, c_int, c_int, [*]Attrib, c_int) callconv(.c) Status,
    createConfig: *const fn (Display, c_int, c_int, [*]Attrib, c_int, *Id) callconv(.c) Status,
    destroyConfig: *const fn (Display, Id) callconv(.c) Status,
    createSurfaces: *const fn (Display, u32, u32, u32, [*]Id, u32, ?*anyopaque, u32) callconv(.c) Status,
    destroySurfaces: *const fn (Display, [*]Id, c_int) callconv(.c) Status,
    createContext: *const fn (Display, Id, c_int, c_int, c_int, [*]Id, c_int, *Id) callconv(.c) Status,
    destroyContext: *const fn (Display, Id) callconv(.c) Status,
    createBuffer: *const fn (Display, Id, c_int, u32, u32, ?*const anyopaque, *Id) callconv(.c) Status,
    destroyBuffer: *const fn (Display, Id) callconv(.c) Status,
    mapBuffer: *const fn (Display, Id, *?*anyopaque) callconv(.c) Status,
    unmapBuffer: *const fn (Display, Id) callconv(.c) Status,
    beginPicture: *const fn (Display, Id, Id) callconv(.c) Status,
    renderPicture: *const fn (Display, Id, [*]Id, c_int) callconv(.c) Status,
    endPicture: *const fn (Display, Id) callconv(.c) Status,
    syncSurface: *const fn (Display, Id) callconv(.c) Status,
    deriveImage: *const fn (Display, Id, *Image) callconv(.c) Status,
    destroyImage: *const fn (Display, Id) callconv(.c) Status,
};

var api: ?Api = null;
var loaded = false;

pub fn sym(comptime T: type, lib: *anyopaque, name: [:0]const u8) ?T {
    return @ptrCast(std.c.dlsym(lib, name) orelse return null);
}

pub fn load() ?Api {
    if (loaded) return api;
    loaded = true;
    const va = std.c.dlopen("libva.so.2", .{ .LAZY = true }) orelse return null;
    const drm = std.c.dlopen("libva-drm.so.2", .{ .LAZY = true }) orelse return null;
    api = .{
        .getDisplayDRM = sym(@FieldType(Api, "getDisplayDRM"), drm, "vaGetDisplayDRM") orelse return null,
        .initialize = sym(@FieldType(Api, "initialize"), va, "vaInitialize") orelse return null,
        .terminate = sym(@FieldType(Api, "terminate"), va, "vaTerminate") orelse return null,
        .queryConfigEntrypoints = sym(@FieldType(Api, "queryConfigEntrypoints"), va, "vaQueryConfigEntrypoints") orelse return null,
        .maxNumEntrypoints = sym(@FieldType(Api, "maxNumEntrypoints"), va, "vaMaxNumEntrypoints") orelse return null,
        .getConfigAttributes = sym(@FieldType(Api, "getConfigAttributes"), va, "vaGetConfigAttributes") orelse return null,
        .createConfig = sym(@FieldType(Api, "createConfig"), va, "vaCreateConfig") orelse return null,
        .destroyConfig = sym(@FieldType(Api, "destroyConfig"), va, "vaDestroyConfig") orelse return null,
        .createSurfaces = sym(@FieldType(Api, "createSurfaces"), va, "vaCreateSurfaces") orelse return null,
        .destroySurfaces = sym(@FieldType(Api, "destroySurfaces"), va, "vaDestroySurfaces") orelse return null,
        .createContext = sym(@FieldType(Api, "createContext"), va, "vaCreateContext") orelse return null,
        .destroyContext = sym(@FieldType(Api, "destroyContext"), va, "vaDestroyContext") orelse return null,
        .createBuffer = sym(@FieldType(Api, "createBuffer"), va, "vaCreateBuffer") orelse return null,
        .destroyBuffer = sym(@FieldType(Api, "destroyBuffer"), va, "vaDestroyBuffer") orelse return null,
        .mapBuffer = sym(@FieldType(Api, "mapBuffer"), va, "vaMapBuffer") orelse return null,
        .unmapBuffer = sym(@FieldType(Api, "unmapBuffer"), va, "vaUnmapBuffer") orelse return null,
        .beginPicture = sym(@FieldType(Api, "beginPicture"), va, "vaBeginPicture") orelse return null,
        .renderPicture = sym(@FieldType(Api, "renderPicture"), va, "vaRenderPicture") orelse return null,
        .endPicture = sym(@FieldType(Api, "endPicture"), va, "vaEndPicture") orelse return null,
        .syncSurface = sym(@FieldType(Api, "syncSurface"), va, "vaSyncSurface") orelse return null,
        .deriveImage = sym(@FieldType(Api, "deriveImage"), va, "vaDeriveImage") orelse return null,
        .destroyImage = sym(@FieldType(Api, "destroyImage"), va, "vaDestroyImage") orelse return null,
    };
    return api;
}

const REFS = 2;
const MAX_FRAME_NUM = 256;

pub const Encoder = struct {
    a: Api,
    fd: c_int,
    dpy: Display,
    config: Id,
    context: Id,
    input: Id,
    recon: [REFS]Id,
    coded: Id,
    width: u32,
    height: u32,
    mb_w: u16,
    mb_h: u16,
    fps: u32,
    bitrate: u32,
    rate_control: u32,
    frame_num: u32 = 0,
    idr_id: u16 = 0,
    current: usize = 0,
    has_ref: bool = false,
    rates_changed: bool = true,
    out: std.ArrayListUnmanaged(u8) = .empty,
};

pub fn macroblocks(pixels: u32) u16 {
    return @intCast((pixels + 15) / 16);
}

pub fn level(mb_w: u16, mb_h: u16) u8 {
    return if (@as(u32, mb_w) * mb_h <= 3600) 31 else 41;
}

pub fn sequence(e: *const Encoder) Sequence {
    var s = Sequence{
        .level_idc = level(e.mb_w, e.mb_h),
        .intra_period = MAX_FRAME_NUM,
        .intra_idr_period = MAX_FRAME_NUM,
        .ip_period = 1,
        .bits_per_second = e.bitrate,
        .max_num_ref_frames = 1,
        .picture_width_in_mbs = e.mb_w,
        .picture_height_in_mbs = e.mb_h,
        .seq_fields = 1 | (1 << 2) | (1 << 5) | (4 << 6) | (2 << 10),
        .vui_parameters_present_flag = 1,
        .vui_fields = (1 << 1) | (1 << 2) | (15 << 3) | (15 << 8) | (1 << 15),
        .num_units_in_tick = 1,
        .time_scale = e.fps * 2,
    };
    const crop_right = (@as(u32, e.mb_w) * 16 - e.width) / 2;
    const crop_bottom = (@as(u32, e.mb_h) * 16 - e.height) / 2;
    if (crop_right > 0 or crop_bottom > 0) {
        s.frame_cropping_flag = 1;
        s.frame_crop_right_offset = crop_right;
        s.frame_crop_bottom_offset = crop_bottom;
    }
    return s;
}

pub fn picture(e: *const Encoder, idr: bool) PictureParams {
    var p = PictureParams{
        .curr = .{ .picture_id = e.recon[e.current], .frame_idx = e.frame_num, .flags = 0, .top_order = @intCast(e.frame_num * 2), .bottom_order = @intCast(e.frame_num * 2) },
        .coded_buf = e.coded,
        .frame_num = @intCast(e.frame_num),
        .pic_init_qp = 26,
        .pic_fields = @as(u32, @intFromBool(idr)) | (1 << 1) | (1 << 9),
    };
    if (!idr and e.has_ref) {
        const prev = e.frame_num - 1;
        p.refs[0] = .{ .picture_id = e.recon[1 - e.current], .frame_idx = prev, .flags = pic_short_term, .top_order = @intCast(prev * 2), .bottom_order = @intCast(prev * 2) };
    }
    return p;
}

pub fn slice(e: *const Encoder, idr: bool, pic: *const PictureParams) Slice {
    var s = Slice{
        .num_macroblocks = @as(u32, e.mb_w) * e.mb_h,
        .slice_type = if (idr) 2 else 0,
        .idr_pic_id = e.idr_id,
    };
    if (!idr) {
        s.num_ref_idx_active_override_flag = 1;
        s.ref_list0[0] = pic.refs[0];
    }
    return s;
}

pub fn check(status: Status) !void {
    if (status != 0) return error.Va;
}

fn openDevice(a: Api, width: u32, height: u32) ?struct { fd: c_int, dpy: Display, entry: c_int, rc: u32 } {
    var path: [32]u8 = undefined;
    var minor: u32 = 128;
    while (minor < 136) : (minor += 1) {
        const p = std.fmt.bufPrintZ(&path, "/dev/dri/renderD{d}", .{minor}) catch continue;
        const rc = linux.open(p.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) continue;
        const fd: c_int = @intCast(rc);
        const dpy = a.getDisplayDRM(fd);
        var major: c_int = 0;
        var minor_version: c_int = 0;
        if (dpy != null and a.initialize(dpy, &major, &minor_version) == 0) {
            if (pickEntry(a, dpy)) |entry| {
                var attribs = [_]Attrib{ .{ .kind = attrib_rt_format, .value = 0 }, .{ .kind = attrib_rate_control, .value = 0 } };
                if (a.getConfigAttributes(dpy, profile_constrained_baseline, entry, &attribs, attribs.len) == 0 and attribs[0].value & rt_yuv420 != 0 and width <= 4096 and height <= 4096) {
                    const mode: u32 = if (attribs[1].value & rc_cbr != 0) rc_cbr else if (attribs[1].value & rc_vbr != 0) rc_vbr else 0;
                    if (mode != 0) return .{ .fd = fd, .dpy = dpy, .entry = entry, .rc = mode };
                }
            }
            _ = a.terminate(dpy);
        }
        _ = linux.close(fd);
    }
    return null;
}

fn pickEntry(a: Api, dpy: Display) ?c_int {
    var entries: [32]c_int = undefined;
    var count: c_int = 0;
    if (a.maxNumEntrypoints(dpy) > entries.len) return null;
    if (a.queryConfigEntrypoints(dpy, profile_constrained_baseline, &entries, &count) != 0) return null;
    var low_power = false;
    for (entries[0..@intCast(count)]) |entry| {
        if (entry == entry_enc_slice) return entry;
        if (entry == entry_enc_slice_lp) low_power = true;
    }
    return if (low_power) entry_enc_slice_lp else null;
}

pub export fn fotone_vaenc_open(width: u32, height: u32, fps: u32, bitrate: u32) ?*Encoder {
    if (width == 0 or height == 0 or width % 2 != 0 or height % 2 != 0) return null;
    const a = load() orelse return null;
    const dev = openDevice(a, width, height) orelse return null;
    const e = std.heap.c_allocator.create(Encoder) catch return null;
    e.* = .{
        .a = a,
        .fd = dev.fd,
        .dpy = dev.dpy,
        .config = invalid,
        .context = invalid,
        .input = invalid,
        .recon = .{ invalid, invalid },
        .coded = invalid,
        .width = width,
        .height = height,
        .mb_w = macroblocks(width),
        .mb_h = macroblocks(height),
        .fps = @max(fps, 1),
        .bitrate = @max(bitrate, 100_000),
        .rate_control = dev.rc,
    };
    setup(e, dev.entry) catch {
        fotone_vaenc_close(e);
        return null;
    };
    return e;
}

fn setup(e: *Encoder, entry: c_int) !void {
    const a = e.a;
    var attribs = [_]Attrib{ .{ .kind = attrib_rt_format, .value = rt_yuv420 }, .{ .kind = attrib_rate_control, .value = e.rate_control } };
    try check(a.createConfig(e.dpy, profile_constrained_baseline, entry, &attribs, attribs.len, &e.config));
    const w = @as(u32, e.mb_w) * 16;
    const h = @as(u32, e.mb_h) * 16;
    var surfaces: [3]Id = undefined;
    try check(a.createSurfaces(e.dpy, rt_yuv420, w, h, &surfaces, surfaces.len, null, 0));
    e.input = surfaces[0];
    e.recon = .{ surfaces[1], surfaces[2] };
    try check(a.createContext(e.dpy, e.config, @intCast(w), @intCast(h), progressive, &surfaces, surfaces.len, &e.context));
    try check(a.createBuffer(e.dpy, e.context, buf_coded, w * h * 3 / 2 + 4096, 1, null, &e.coded));
}

pub export fn fotone_vaenc_set_rates(e: *Encoder, bitrate: u32, fps: u32) void {
    e.bitrate = @max(bitrate, 100_000);
    e.fps = @max(fps, 1);
    e.rates_changed = true;
}

pub fn toNv12(dst: [*]u8, pitch_y: usize, pitch_uv: usize, uv_offset: usize, width: usize, height: usize, y: [*]const u8, stride_y: usize, u: [*]const u8, stride_u: usize, v: [*]const u8, stride_v: usize) void {
    for (0..height) |row| @memcpy(dst[row * pitch_y ..][0..width], y[row * stride_y ..][0..width]);
    for (0..height / 2) |row| {
        const line = dst[uv_offset + row * pitch_uv ..];
        for (0..width / 2) |col| {
            line[col * 2] = u[row * stride_u + col];
            line[col * 2 + 1] = v[row * stride_v + col];
        }
    }
}

fn upload(e: *Encoder, y: [*]const u8, stride_y: c_int, u: [*]const u8, stride_u: c_int, v: [*]const u8, stride_v: c_int) !void {
    const a = e.a;
    var image: Image = undefined;
    try check(a.deriveImage(e.dpy, e.input, &image));
    defer _ = a.destroyImage(e.dpy, image.image_id);
    if (image.format.fourcc != fourcc_nv12) return error.Format;
    var data: ?*anyopaque = null;
    try check(a.mapBuffer(e.dpy, image.buf, &data));
    defer _ = a.unmapBuffer(e.dpy, image.buf);
    const base: [*]u8 = @ptrCast(data orelse return error.Va);
    toNv12(base + image.offsets[0], image.pitches[0], image.pitches[1], image.offsets[1] - image.offsets[0], e.width, e.height, y, @intCast(stride_y), u, @intCast(stride_u), v, @intCast(stride_v));
}

fn param(e: *Encoder, kind: c_int, value: anytype) !Id {
    var id: Id = invalid;
    try check(e.a.createBuffer(e.dpy, e.context, kind, @sizeOf(@TypeOf(value.*)), 1, value, &id));
    return id;
}

pub export fn fotone_vaenc_encode(e: *Encoder, y: [*]const u8, stride_y: c_int, u: [*]const u8, stride_u: c_int, v: [*]const u8, stride_v: c_int, force_key: c_int, out: *[*]const u8, out_len: *usize, key: *c_int) c_int {
    encode(e, y, stride_y, u, stride_u, v, stride_v, force_key != 0) catch return -1;
    out.* = e.out.items.ptr;
    out_len.* = e.out.items.len;
    key.* = @intFromBool(e.frame_num == 1);
    return 0;
}

fn encode(e: *Encoder, y: [*]const u8, stride_y: c_int, u: [*]const u8, stride_u: c_int, v: [*]const u8, stride_v: c_int, force_key: bool) !void {
    const a = e.a;
    const idr = force_key or !e.has_ref or e.frame_num >= MAX_FRAME_NUM;
    if (idr) {
        if (e.has_ref) e.idr_id +%= 1;
        e.frame_num = 0;
        e.has_ref = false;
    }
    try upload(e, y, stride_y, u, stride_u, v, stride_v);

    var ids: [5]Id = undefined;
    var n: usize = 0;
    defer for (ids[0..n]) |id| {
        _ = a.destroyBuffer(e.dpy, id);
    };
    if (idr or e.rates_changed) {
        const seq = sequence(e);
        ids[n] = try param(e, buf_seq, &seq);
        n += 1;
        const rate = RateControl{ .bits_per_second = e.bitrate };
        ids[n] = try param(e, buf_misc, &rate);
        n += 1;
        const frame_rate = FrameRate{ .framerate = e.fps };
        ids[n] = try param(e, buf_misc, &frame_rate);
        n += 1;
        e.rates_changed = false;
    }
    const pic = picture(e, idr);
    ids[n] = try param(e, buf_pic, &pic);
    n += 1;
    const sl = slice(e, idr, &pic);
    ids[n] = try param(e, buf_slice, &sl);
    n += 1;

    try check(a.beginPicture(e.dpy, e.context, e.input));
    try check(a.renderPicture(e.dpy, e.context, &ids, @intCast(n)));
    try check(a.endPicture(e.dpy, e.context));
    try check(a.syncSurface(e.dpy, e.input));

    var mapped: ?*anyopaque = null;
    try check(a.mapBuffer(e.dpy, e.coded, &mapped));
    defer _ = a.unmapBuffer(e.dpy, e.coded);
    e.out.clearRetainingCapacity();
    var seg: ?*Segment = @ptrCast(@alignCast(mapped));
    while (seg) |s| : (seg = s.next) {
        const bytes = s.buf orelse continue;
        try e.out.appendSlice(std.heap.c_allocator, bytes[0..s.size]);
    }
    if (idr and !hasParameterSets(e.out.items)) return error.NoHeaders;

    e.has_ref = true;
    e.frame_num += 1;
    e.current = 1 - e.current;
}

pub fn hasParameterSets(stream: []const u8) bool {
    var sps = false;
    var pps = false;
    var i: usize = 0;
    while (i + 3 < stream.len) : (i += 1) {
        if (stream[i] != 0 or stream[i + 1] != 0) continue;
        const start: usize = if (stream[i + 2] == 1) i + 3 else if (stream[i + 2] == 0 and stream[i + 3] == 1) i + 4 else continue;
        if (start >= stream.len) break;
        switch (stream[start] & 0x1f) {
            7 => sps = true,
            8 => pps = true,
            else => {},
        }
        i = start;
    }
    return sps and pps;
}

pub export fn fotone_vaenc_close(e: *Encoder) void {
    const a = e.a;
    if (e.coded != invalid) _ = a.destroyBuffer(e.dpy, e.coded);
    if (e.context != invalid) _ = a.destroyContext(e.dpy, e.context);
    if (e.input != invalid) {
        var surfaces = [_]Id{ e.input, e.recon[0], e.recon[1] };
        _ = a.destroySurfaces(e.dpy, &surfaces, surfaces.len);
    }
    if (e.config != invalid) _ = a.destroyConfig(e.dpy, e.config);
    _ = a.terminate(e.dpy);
    _ = linux.close(e.fd);
    e.out.deinit(std.heap.c_allocator);
    std.heap.c_allocator.destroy(e);
}

test "the parameter structs match the libva 2.23 layout" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Picture));
    try std.testing.expectEqual(@as(usize, 1132), @sizeOf(Sequence));
    try std.testing.expectEqual(@as(usize, 648), @sizeOf(PictureParams));
    try std.testing.expectEqual(@as(usize, 3140), @sizeOf(Slice));
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(Image));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Segment));
}

test "odd sizes are cropped to whole macroblocks" {
    var e: Encoder = undefined;
    e.bitrate = 1_000_000;
    e.width = 1280;
    e.height = 722;
    e.mb_w = macroblocks(e.width);
    e.mb_h = macroblocks(e.height);
    e.fps = 30;
    const s = sequence(&e);
    try std.testing.expectEqual(@as(u16, 80), s.picture_width_in_mbs);
    try std.testing.expectEqual(@as(u16, 46), s.picture_height_in_mbs);
    try std.testing.expectEqual(@as(u8, 1), s.frame_cropping_flag);
    try std.testing.expectEqual(@as(u32, 7), s.frame_crop_bottom_offset);
    try std.testing.expectEqual(@as(u8, 41), s.level_idc);
    try std.testing.expectEqual(@as(u8, 31), level(80, 45));
    try std.testing.expectEqual(@as(u8, 41), level(120, 68));
}

test "P frames reference the previous reconstruction" {
    var e: Encoder = undefined;
    e.coded = 5;
    e.idr_id = 0;
    e.recon = .{ 10, 11 };
    e.current = 1;
    e.frame_num = 3;
    e.has_ref = true;
    e.mb_w = 2;
    e.mb_h = 2;
    const p = picture(&e, false);
    try std.testing.expectEqual(@as(Id, 11), p.curr.picture_id);
    try std.testing.expectEqual(@as(Id, 10), p.refs[0].picture_id);
    try std.testing.expectEqual(pic_short_term, p.refs[0].flags);
    const s = slice(&e, false, &p);
    try std.testing.expectEqual(@as(u8, 0), s.slice_type);
    try std.testing.expectEqual(@as(Id, 10), s.ref_list0[0].picture_id);
    try std.testing.expectEqual(@as(u32, 4), s.num_macroblocks);
}

test "I420 planes interleave into NV12" {
    const y = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const u = [_]u8{ 20, 21 };
    const v = [_]u8{ 30, 31 };
    var dst: [16]u8 = @splat(0);
    toNv12(&dst, 4, 4, 8, 4, 2, &y, 4, &u, 2, &v, 2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 20, 30, 21, 31 }, dst[0..12]);
}

test "streams without parameter sets are refused" {
    try std.testing.expect(hasParameterSets(&.{ 0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 1, 0x65 }));
    try std.testing.expect(!hasParameterSets(&.{ 0, 0, 0, 1, 0x65, 1, 2 }));
}

test "the encoder declines when no device can encode" {
    if (std.c.dlopen("libva.so.2", .{ .LAZY = true }) != null) return error.SkipZigTest;
    try std.testing.expect(fotone_vaenc_open(640, 480, 30, 1_000_000) == null);
}
