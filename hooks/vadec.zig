const std = @import("std");
const linux = std.os.linux;
const va = @import("vaenc.zig");

const Id = va.Id;
const invalid = va.invalid;
const Picture = va.Picture;
const check = va.check;

const profile_constrained_baseline: c_int = 13;
const profile_main: c_int = 6;
const profile_high: c_int = 7;
const entry_vld: c_int = 1;
const buf_picture: c_int = 0;
const buf_iq: c_int = 1;
const buf_slice_param: c_int = 4;
const buf_slice_data: c_int = 5;
const pic_long_term: u32 = 0x10;

const MAX_REFS = 16;
const SPARE_SURFACES = 3;

pub const PictureParams = extern struct {
    curr: Picture = .{},
    refs: [16]Picture = @splat(.{}),
    width_in_mbs_minus1: u16 = 0,
    height_in_mbs_minus1: u16 = 0,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    num_ref_frames: u8 = 0,
    seq_fields: u32 = 0,
    num_slice_groups_minus1: u8 = 0,
    slice_group_map_type: u8 = 0,
    slice_group_change_rate_minus1: u16 = 0,
    pic_init_qp_minus26: i8 = 0,
    pic_init_qs_minus26: i8 = 0,
    chroma_qp_index_offset: i8 = 0,
    second_chroma_qp_index_offset: i8 = 0,
    pic_fields: u32 = 0,
    frame_num: u16 = 0,
    reserved: [8]u32 = @splat(0),
};

pub const IqMatrix = extern struct {
    list4x4: [6][16]u8 = @splat(@splat(16)),
    list8x8: [2][64]u8 = @splat(@splat(16)),
    reserved: [4]u32 = @splat(0),
};

pub const SliceParams = extern struct {
    data_size: u32 = 0,
    data_offset: u32 = 0,
    data_flag: u32 = 0,
    data_bit_offset: u16 = 0,
    first_mb: u16 = 0,
    slice_type: u8 = 0,
    direct_spatial_mv_pred_flag: u8 = 0,
    num_ref_idx_l0_active_minus1: u8 = 0,
    num_ref_idx_l1_active_minus1: u8 = 0,
    cabac_init_idc: u8 = 0,
    slice_qp_delta: i8 = 0,
    disable_deblocking_filter_idc: u8 = 0,
    slice_alpha_c0_offset_div2: i8 = 0,
    slice_beta_offset_div2: i8 = 0,
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
    reserved: [4]u32 = @splat(0),
};

pub const Error = error{ Truncated, Unsupported, Missing, Va, OutOfMemory };

pub const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn bit(b: *Bits) Error!u1 {
        if (b.pos >= b.data.len * 8) return error.Truncated;
        const v: u1 = @intCast((b.data[b.pos / 8] >> @intCast(7 - b.pos % 8)) & 1);
        b.pos += 1;
        return v;
    }

    pub fn flag(b: *Bits) Error!bool {
        return try b.bit() == 1;
    }

    pub fn u(b: *Bits, n: u6) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | try b.bit();
        return v;
    }

    pub fn ue(b: *Bits) Error!u32 {
        var zeros: u6 = 0;
        while (try b.bit() == 0) {
            zeros += 1;
            if (zeros > 31) return error.Unsupported;
        }
        if (zeros == 0) return 0;
        return (@as(u32, 1) << @intCast(zeros)) - 1 + try b.u(zeros);
    }

    pub fn se(b: *Bits) Error!i32 {
        const k = try b.ue();
        const half: i32 = @intCast((k + 1) / 2);
        return if (k % 2 == 1) half else -half;
    }

    pub fn moreData(b: *const Bits) bool {
        var last = b.data.len;
        while (last > 0 and b.data[last - 1] == 0) last -= 1;
        if (last == 0) return false;
        const stop = (last - 1) * 8 + (7 - @ctz(b.data[last - 1]));
        return b.pos < stop;
    }
};

pub fn unescape(out: []u8, nal: []const u8, removed: *std.ArrayListUnmanaged(usize), allocator: std.mem.Allocator) Error![]u8 {
    removed.clearRetainingCapacity();
    var n: usize = 0;
    var zeros: usize = 0;
    for (nal, 0..) |byte, i| {
        if (zeros >= 2 and byte == 3) {
            try removed.append(allocator, i);
            zeros = 0;
            continue;
        }
        out[n] = byte;
        n += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    return out[0..n];
}

pub const Sps = struct {
    profile_idc: u8 = 0,
    constraint_set1: bool = false,
    level_idc: u8 = 0,
    chroma_format_idc: u32 = 1,
    bit_depth_luma_minus8: u32 = 0,
    bit_depth_chroma_minus8: u32 = 0,
    log2_max_frame_num: u5 = 4,
    poc_type: u32 = 0,
    log2_max_poc_lsb: u5 = 4,
    delta_pic_order_always_zero: bool = false,
    offset_for_non_ref_pic: i32 = 0,
    offset_for_top_to_bottom_field: i32 = 0,
    offsets_for_ref_frame: [255]i32 = @splat(0),
    num_ref_frames_in_poc_cycle: u32 = 0,
    max_num_ref_frames: u32 = 0,
    gaps_allowed: bool = false,
    width_mbs: u32 = 0,
    height_mbs: u32 = 0,
    direct_8x8_inference: bool = false,
    crop_left: u32 = 0,
    crop_right: u32 = 0,
    crop_top: u32 = 0,
    crop_bottom: u32 = 0,
    valid: bool = false,

    pub fn width(s: *const Sps) u32 {
        return s.width_mbs * 16 - 2 * (s.crop_left + s.crop_right);
    }

    pub fn height(s: *const Sps) u32 {
        return s.height_mbs * 16 - 2 * (s.crop_top + s.crop_bottom);
    }
};

fn highProfile(p: u8) bool {
    return switch (p) {
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 => true,
        else => false,
    };
}

pub fn parseSps(rbsp: []const u8, out: []Sps) Error!u32 {
    var b = Bits{ .data = rbsp, .pos = 8 };
    var s = Sps{};
    s.profile_idc = @intCast(try b.u(8));
    const constraints = try b.u(8);
    s.constraint_set1 = constraints & 0x40 != 0;
    s.level_idc = @intCast(try b.u(8));
    const id = try b.ue();
    if (id >= out.len) return error.Unsupported;
    if (highProfile(s.profile_idc)) {
        s.chroma_format_idc = try b.ue();
        if (s.chroma_format_idc != 1) return error.Unsupported;
        s.bit_depth_luma_minus8 = try b.ue();
        s.bit_depth_chroma_minus8 = try b.ue();
        if (s.bit_depth_luma_minus8 != 0 or s.bit_depth_chroma_minus8 != 0) return error.Unsupported;
        _ = try b.flag();
        if (try b.flag()) return error.Unsupported;
    }
    const max_frame = try b.ue();
    if (max_frame > 12) return error.Unsupported;
    s.log2_max_frame_num = @intCast(max_frame + 4);
    s.poc_type = try b.ue();
    switch (s.poc_type) {
        0 => {
            const lsb = try b.ue();
            if (lsb > 12) return error.Unsupported;
            s.log2_max_poc_lsb = @intCast(lsb + 4);
        },
        1 => {
            s.delta_pic_order_always_zero = try b.flag();
            s.offset_for_non_ref_pic = try b.se();
            s.offset_for_top_to_bottom_field = try b.se();
            s.num_ref_frames_in_poc_cycle = try b.ue();
            if (s.num_ref_frames_in_poc_cycle > 255) return error.Unsupported;
            for (0..s.num_ref_frames_in_poc_cycle) |i| s.offsets_for_ref_frame[i] = try b.se();
        },
        2 => {},
        else => return error.Unsupported,
    }
    s.max_num_ref_frames = try b.ue();
    if (s.max_num_ref_frames > MAX_REFS) return error.Unsupported;
    s.gaps_allowed = try b.flag();
    s.width_mbs = try b.ue() + 1;
    s.height_mbs = try b.ue() + 1;
    if (!try b.flag()) return error.Unsupported;
    s.direct_8x8_inference = try b.flag();
    if (try b.flag()) {
        s.crop_left = try b.ue();
        s.crop_right = try b.ue();
        s.crop_top = try b.ue();
        s.crop_bottom = try b.ue();
    }
    if (s.width_mbs > 256 or s.height_mbs > 256 or s.width() == 0 or s.height() == 0) return error.Unsupported;
    s.valid = true;
    out[id] = s;
    return id;
}

pub const Pps = struct {
    sps_id: u32 = 0,
    entropy_coding_mode: bool = false,
    bottom_field_pic_order_present: bool = false,
    num_ref_idx_l0_default_minus1: u32 = 0,
    num_ref_idx_l1_default_minus1: u32 = 0,
    weighted_pred: bool = false,
    weighted_bipred_idc: u32 = 0,
    pic_init_qp_minus26: i32 = 0,
    pic_init_qs_minus26: i32 = 0,
    chroma_qp_index_offset: i32 = 0,
    second_chroma_qp_index_offset: i32 = 0,
    deblocking_filter_control_present: bool = false,
    constrained_intra_pred: bool = false,
    redundant_pic_cnt_present: bool = false,
    transform_8x8_mode: bool = false,
    valid: bool = false,
};

pub fn parsePps(rbsp: []const u8, out: []Pps) Error!u32 {
    var b = Bits{ .data = rbsp, .pos = 8 };
    var p = Pps{};
    const id = try b.ue();
    if (id >= out.len) return error.Unsupported;
    p.sps_id = try b.ue();
    p.entropy_coding_mode = try b.flag();
    p.bottom_field_pic_order_present = try b.flag();
    if (try b.ue() != 0) return error.Unsupported;
    p.num_ref_idx_l0_default_minus1 = try b.ue();
    p.num_ref_idx_l1_default_minus1 = try b.ue();
    if (p.num_ref_idx_l0_default_minus1 > 31 or p.num_ref_idx_l1_default_minus1 > 31) return error.Unsupported;
    p.weighted_pred = try b.flag();
    p.weighted_bipred_idc = try b.u(2);
    p.pic_init_qp_minus26 = try b.se();
    p.pic_init_qs_minus26 = try b.se();
    p.chroma_qp_index_offset = try b.se();
    p.deblocking_filter_control_present = try b.flag();
    p.constrained_intra_pred = try b.flag();
    p.redundant_pic_cnt_present = try b.flag();
    p.second_chroma_qp_index_offset = p.chroma_qp_index_offset;
    if (b.moreData()) {
        p.transform_8x8_mode = try b.flag();
        if (try b.flag()) return error.Unsupported;
        p.second_chroma_qp_index_offset = try b.se();
    }
    p.valid = true;
    out[id] = p;
    return id;
}

pub const ListOp = struct { idc: u32, value: u32 };
pub const Mmco = struct { op: u32, a: u32 = 0, b: u32 = 0 };

pub const SliceHeader = struct {
    nal_ref_idc: u2 = 0,
    idr: bool = false,
    first_mb: u32 = 0,
    slice_type: u32 = 0,
    pps_id: u32 = 0,
    frame_num: u32 = 0,
    idr_pic_id: u32 = 0,
    poc_lsb: u32 = 0,
    delta_poc_bottom: i32 = 0,
    delta_poc: [2]i32 = .{ 0, 0 },
    redundant_pic_cnt: u32 = 0,
    direct_spatial_mv_pred: bool = false,
    num_ref_idx_l0_active_minus1: u32 = 0,
    num_ref_idx_l1_active_minus1: u32 = 0,
    mods: [2][33]ListOp = undefined,
    mod_count: [2]usize = .{ 0, 0 },
    luma_log2_weight_denom: u32 = 0,
    chroma_log2_weight_denom: u32 = 0,
    weights: ?*SliceParams = null,
    no_output_of_prior_pics: bool = false,
    long_term_reference: bool = false,
    adaptive: bool = false,
    mmcos: [66]Mmco = undefined,
    mmco_count: usize = 0,
    cabac_init_idc: u32 = 0,
    slice_qp_delta: i32 = 0,
    disable_deblocking_filter_idc: u32 = 0,
    alpha: i32 = 0,
    beta: i32 = 0,
    header_bits: usize = 0,

    pub fn isB(h: *const SliceHeader) bool {
        return h.slice_type == 1;
    }

    pub fn isI(h: *const SliceHeader) bool {
        return h.slice_type == 2 or h.slice_type == 4;
    }
};

fn weightTable(b: *Bits, h: *SliceHeader, chroma: bool, out: *SliceParams) Error!void {
    h.luma_log2_weight_denom = try b.ue();
    if (h.luma_log2_weight_denom > 7) return error.Unsupported;
    if (chroma) {
        h.chroma_log2_weight_denom = try b.ue();
        if (h.chroma_log2_weight_denom > 7) return error.Unsupported;
    }
    out.luma_log2_weight_denom = @intCast(h.luma_log2_weight_denom);
    out.chroma_log2_weight_denom = @intCast(h.chroma_log2_weight_denom);
    const lists: usize = if (h.isB()) 2 else 1;
    for (0..lists) |l| {
        const count = (if (l == 0) h.num_ref_idx_l0_active_minus1 else h.num_ref_idx_l1_active_minus1) + 1;
        const lw = if (l == 0) &out.luma_weight_l0 else &out.luma_weight_l1;
        const lo = if (l == 0) &out.luma_offset_l0 else &out.luma_offset_l1;
        const cw = if (l == 0) &out.chroma_weight_l0 else &out.chroma_weight_l1;
        const co = if (l == 0) &out.chroma_offset_l0 else &out.chroma_offset_l1;
        var luma_any = false;
        var chroma_any = false;
        for (0..count) |i| {
            lw[i] = @intCast(@as(i32, 1) << @intCast(h.luma_log2_weight_denom));
            lo[i] = 0;
            if (try b.flag()) {
                luma_any = true;
                lw[i] = @intCast(try b.se());
                lo[i] = @intCast(try b.se());
            }
            cw[i] = .{ @intCast(@as(i32, 1) << @intCast(h.chroma_log2_weight_denom)), @intCast(@as(i32, 1) << @intCast(h.chroma_log2_weight_denom)) };
            co[i] = .{ 0, 0 };
            if (chroma and try b.flag()) {
                chroma_any = true;
                for (0..2) |j| {
                    cw[i][j] = @intCast(try b.se());
                    co[i][j] = @intCast(try b.se());
                }
            }
        }
        if (l == 0) {
            out.luma_weight_l0_flag = @intFromBool(luma_any);
            out.chroma_weight_l0_flag = @intFromBool(chroma_any);
        } else {
            out.luma_weight_l1_flag = @intFromBool(luma_any);
            out.chroma_weight_l1_flag = @intFromBool(chroma_any);
        }
    }
}

pub fn parseSlice(rbsp: []const u8, sps_set: []const Sps, pps_set: []const Pps, out_params: *SliceParams) Error!SliceHeader {
    var b = Bits{ .data = rbsp };
    _ = try b.u(1);
    var h = SliceHeader{};
    h.nal_ref_idc = @intCast(try b.u(2));
    h.idr = try b.u(5) == 5;
    h.first_mb = try b.ue();
    h.slice_type = (try b.ue()) % 5;
    if (h.slice_type == 3 or h.slice_type == 4) return error.Unsupported;
    h.pps_id = try b.ue();
    if (h.pps_id >= pps_set.len or !pps_set[h.pps_id].valid) return error.Missing;
    const pps = &pps_set[h.pps_id];
    if (pps.sps_id >= sps_set.len or !sps_set[pps.sps_id].valid) return error.Missing;
    const sps = &sps_set[pps.sps_id];
    h.frame_num = try b.u(sps.log2_max_frame_num);
    if (h.idr) h.idr_pic_id = try b.ue();
    if (sps.poc_type == 0) {
        h.poc_lsb = try b.u(sps.log2_max_poc_lsb);
        if (pps.bottom_field_pic_order_present) h.delta_poc_bottom = try b.se();
    }
    if (sps.poc_type == 1 and !sps.delta_pic_order_always_zero) {
        h.delta_poc[0] = try b.se();
        if (pps.bottom_field_pic_order_present) h.delta_poc[1] = try b.se();
    }
    if (pps.redundant_pic_cnt_present) h.redundant_pic_cnt = try b.ue();
    if (h.isB()) h.direct_spatial_mv_pred = try b.flag();
    h.num_ref_idx_l0_active_minus1 = pps.num_ref_idx_l0_default_minus1;
    h.num_ref_idx_l1_active_minus1 = pps.num_ref_idx_l1_default_minus1;
    if (!h.isI()) {
        if (try b.flag()) {
            h.num_ref_idx_l0_active_minus1 = try b.ue();
            if (h.isB()) h.num_ref_idx_l1_active_minus1 = try b.ue();
        }
        if (h.num_ref_idx_l0_active_minus1 > 31 or h.num_ref_idx_l1_active_minus1 > 31) return error.Unsupported;
        const lists: usize = if (h.isB()) 2 else 1;
        for (0..lists) |l| {
            if (!try b.flag()) continue;
            while (true) {
                const idc = try b.ue();
                if (idc == 3) break;
                if (idc > 2 or h.mod_count[l] >= h.mods[l].len) return error.Unsupported;
                h.mods[l][h.mod_count[l]] = .{ .idc = idc, .value = try b.ue() };
                h.mod_count[l] += 1;
            }
        }
    }
    if ((pps.weighted_pred and h.slice_type == 0) or (pps.weighted_bipred_idc == 1 and h.isB())) {
        try weightTable(&b, &h, sps.chroma_format_idc != 0, out_params);
    }
    if (h.nal_ref_idc != 0) {
        if (h.idr) {
            h.no_output_of_prior_pics = try b.flag();
            h.long_term_reference = try b.flag();
        } else {
            h.adaptive = try b.flag();
            if (h.adaptive) {
                while (true) {
                    const op = try b.ue();
                    if (op == 0) break;
                    if (op > 6 or h.mmco_count >= h.mmcos.len) return error.Unsupported;
                    var m = Mmco{ .op = op };
                    if (op == 1 or op == 3) m.a = try b.ue();
                    if (op == 2) m.a = try b.ue();
                    if (op == 3 or op == 6) m.b = try b.ue();
                    if (op == 4) m.a = try b.ue();
                    h.mmcos[h.mmco_count] = m;
                    h.mmco_count += 1;
                }
            }
        }
    }
    if (pps.entropy_coding_mode and !h.isI()) h.cabac_init_idc = try b.ue();
    h.slice_qp_delta = try b.se();
    if (pps.deblocking_filter_control_present) {
        h.disable_deblocking_filter_idc = try b.ue();
        if (h.disable_deblocking_filter_idc != 1) {
            h.alpha = try b.se();
            h.beta = try b.se();
        }
    }
    h.header_bits = b.pos;
    return h;
}

pub const Frame = struct {
    surface: Id = invalid,
    frame_num: u32 = 0,
    frame_num_wrap: i32 = 0,
    top: i32 = 0,
    bottom: i32 = 0,
    short_term: bool = false,
    long_term: bool = false,
    long_term_idx: u32 = 0,

    pub fn poc(f: *const Frame) i32 {
        return @min(f.top, f.bottom);
    }

    pub fn reference(f: *const Frame) bool {
        return f.short_term or f.long_term;
    }

    pub fn picture(f: *const Frame) Picture {
        return .{
            .picture_id = f.surface,
            .frame_idx = if (f.long_term) f.long_term_idx else f.frame_num,
            .flags = if (f.long_term) pic_long_term else va.pic_short_term,
            .top_order = f.top,
            .bottom_order = f.bottom,
        };
    }
};

pub const Dpb = struct {
    frames: [MAX_REFS]Frame = @splat(.{}),
    count: usize = 0,
    max_long_term_idx: ?u32 = null,

    pub fn refs(d: *Dpb) []Frame {
        return d.frames[0..d.count];
    }

    fn compact(d: *Dpb) void {
        var n: usize = 0;
        for (d.frames[0..d.count]) |f| {
            if (!f.reference()) continue;
            d.frames[n] = f;
            n += 1;
        }
        d.count = n;
    }

    pub fn clear(d: *Dpb) void {
        d.count = 0;
        d.max_long_term_idx = null;
    }

    pub fn holds(d: *const Dpb, surface: Id) bool {
        for (d.frames[0..d.count]) |f| if (f.surface == surface) return true;
        return false;
    }

    pub fn wrap(d: *Dpb, frame_num: u32, max_frame_num: u32) void {
        for (d.frames[0..d.count]) |*f| {
            if (!f.short_term) continue;
            f.frame_num_wrap = if (f.frame_num > frame_num) @as(i32, @intCast(f.frame_num)) - @as(i32, @intCast(max_frame_num)) else @intCast(f.frame_num);
        }
    }

    pub fn mark(d: *Dpb, h: *const SliceHeader, cur: *Frame, max_refs: u32) bool {
        var mmco5 = false;
        if (h.idr) {
            d.clear();
            if (h.long_term_reference) {
                cur.long_term = true;
                cur.long_term_idx = 0;
                d.max_long_term_idx = 0;
            } else cur.short_term = true;
        } else if (h.adaptive) {
            const cur_pic_num: i32 = @intCast(h.frame_num);
            for (h.mmcos[0..h.mmco_count]) |m| switch (m.op) {
                1 => d.unmarkShort(cur_pic_num - @as(i32, @intCast(m.a + 1))),
                2 => d.unmarkLong(m.a),
                3 => {
                    const pic_num = cur_pic_num - @as(i32, @intCast(m.a + 1));
                    d.unmarkLong(m.b);
                    for (d.frames[0..d.count]) |*f| {
                        if (f.short_term and f.frame_num_wrap == pic_num) {
                            f.short_term = false;
                            f.long_term = true;
                            f.long_term_idx = m.b;
                        }
                    }
                },
                4 => {
                    d.max_long_term_idx = if (m.a == 0) null else m.a - 1;
                    for (d.frames[0..d.count]) |*f| {
                        if (f.long_term and (d.max_long_term_idx == null or f.long_term_idx > d.max_long_term_idx.?)) f.long_term = false;
                    }
                },
                5 => {
                    for (d.frames[0..d.count]) |*f| {
                        f.short_term = false;
                        f.long_term = false;
                    }
                    d.max_long_term_idx = null;
                    mmco5 = true;
                },
                6 => {
                    d.unmarkLong(m.b);
                    cur.long_term = true;
                    cur.long_term_idx = m.b;
                },
                else => {},
            };
            if (!cur.long_term) cur.short_term = true;
        } else {
            var short: usize = 0;
            var long: usize = 0;
            for (d.frames[0..d.count]) |f| {
                if (f.short_term) short += 1;
                if (f.long_term) long += 1;
            }
            if (short + long >= @max(max_refs, 1) and short > 0) {
                var oldest: ?*Frame = null;
                for (d.frames[0..d.count]) |*f| {
                    if (f.short_term and (oldest == null or f.frame_num_wrap < oldest.?.frame_num_wrap)) oldest = f;
                }
                oldest.?.short_term = false;
            }
            cur.short_term = true;
        }
        d.compact();
        if (d.count >= MAX_REFS) {
            var oldest: usize = 0;
            for (d.frames[0..d.count], 0..) |f, i| if (f.frame_num_wrap < d.frames[oldest].frame_num_wrap) {
                oldest = i;
            };
            d.frames[oldest].short_term = false;
            d.frames[oldest].long_term = false;
            d.compact();
        }
        if (mmco5) {
            const temp = cur.poc();
            cur.top -= temp;
            cur.bottom -= temp;
            cur.frame_num = 0;
        }
        d.frames[d.count] = cur.*;
        d.count += 1;
        return mmco5;
    }

    fn unmarkShort(d: *Dpb, pic_num: i32) void {
        for (d.frames[0..d.count]) |*f| if (f.short_term and f.frame_num_wrap == pic_num) {
            f.short_term = false;
        };
    }

    fn unmarkLong(d: *Dpb, idx: u32) void {
        for (d.frames[0..d.count]) |*f| if (f.long_term and f.long_term_idx == idx) {
            f.long_term = false;
        };
    }
};

fn descPicNum(_: void, a: Frame, b: Frame) bool {
    return a.frame_num_wrap > b.frame_num_wrap;
}

fn ascLong(_: void, a: Frame, b: Frame) bool {
    return a.long_term_idx < b.long_term_idx;
}

fn descPoc(_: void, a: Frame, b: Frame) bool {
    return a.poc() > b.poc();
}

fn ascPoc(_: void, a: Frame, b: Frame) bool {
    return a.poc() < b.poc();
}

pub fn initLists(d: *Dpb, h: *const SliceHeader, cur_poc: i32, l0: []Frame, l1: []Frame) [2]usize {
    var short: [MAX_REFS]Frame = undefined;
    var long: [MAX_REFS]Frame = undefined;
    var ns: usize = 0;
    var nl: usize = 0;
    for (d.refs()) |f| {
        if (f.short_term) {
            short[ns] = f;
            ns += 1;
        } else if (f.long_term) {
            long[nl] = f;
            nl += 1;
        }
    }
    std.mem.sort(Frame, long[0..nl], {}, ascLong);
    if (!h.isB()) {
        std.mem.sort(Frame, short[0..ns], {}, descPicNum);
        @memcpy(l0[0..ns], short[0..ns]);
        @memcpy(l0[ns .. ns + nl], long[0..nl]);
        return .{ ns + nl, 0 };
    }
    var before: [MAX_REFS]Frame = undefined;
    var after: [MAX_REFS]Frame = undefined;
    var nb: usize = 0;
    var na: usize = 0;
    for (short[0..ns]) |f| {
        if (f.poc() < cur_poc) {
            before[nb] = f;
            nb += 1;
        } else {
            after[na] = f;
            na += 1;
        }
    }
    std.mem.sort(Frame, before[0..nb], {}, descPoc);
    std.mem.sort(Frame, after[0..na], {}, ascPoc);
    @memcpy(l0[0..nb], before[0..nb]);
    @memcpy(l0[nb .. nb + na], after[0..na]);
    @memcpy(l0[nb + na .. nb + na + nl], long[0..nl]);
    @memcpy(l1[0..na], after[0..na]);
    @memcpy(l1[na .. na + nb], before[0..nb]);
    @memcpy(l1[na + nb .. na + nb + nl], long[0..nl]);
    const n = ns + nl;
    if (n > 1) {
        var same = true;
        for (0..n) |i| if (l0[i].surface != l1[i].surface) {
            same = false;
        };
        if (same) std.mem.swap(Frame, &l1[0], &l1[1]);
    }
    return .{ n, n };
}

pub fn modifyList(d: *Dpb, list: []Frame, len: usize, active: usize, ops: []const ListOp, cur_frame_num: u32, max_frame_num: u32) Error!void {
    var tmp: [34]Frame = @splat(.{});
    @memcpy(tmp[0..@min(len, active)], list[0..@min(len, active)]);
    var pred: i64 = cur_frame_num;
    const max: i64 = max_frame_num;
    for (ops, 0..) |op, ref_idx| {
        if (ref_idx >= active) return error.Unsupported;
        var pick: ?Frame = null;
        if (op.idc < 2) {
            const diff: i64 = @as(i64, op.value) + 1;
            var no_wrap = if (op.idc == 0) pred - diff else pred + diff;
            if (no_wrap < 0) no_wrap += max;
            if (no_wrap >= max) no_wrap -= max;
            pred = no_wrap;
            const pic_num: i64 = if (no_wrap > cur_frame_num) no_wrap - max else no_wrap;
            for (d.refs()) |f| if (f.short_term and f.frame_num_wrap == pic_num) {
                pick = f;
            };
        } else {
            for (d.refs()) |f| if (f.long_term and f.long_term_idx == op.value) {
                pick = f;
            };
        }
        const chosen = pick orelse return error.Missing;
        var i = active;
        while (i > ref_idx) : (i -= 1) tmp[i] = tmp[i - 1];
        tmp[ref_idx] = chosen;
        var n = ref_idx + 1;
        for (ref_idx + 1..active + 1) |j| {
            if (tmp[j].surface != chosen.surface) {
                tmp[n] = tmp[j];
                n += 1;
            }
        }
    }
    @memcpy(list[0..active], tmp[0..active]);
}

pub const Poc = struct {
    prev_msb: i32 = 0,
    prev_lsb: i32 = 0,
    prev_frame_num_offset: i64 = 0,
    prev_frame_num: u32 = 0,

    pub fn compute(p: *Poc, sps: *const Sps, h: *const SliceHeader) [2]i32 {
        const max_frame_num: i64 = @as(i64, 1) << sps.log2_max_frame_num;
        switch (sps.poc_type) {
            0 => {
                if (h.idr) {
                    p.prev_msb = 0;
                    p.prev_lsb = 0;
                }
                const max_lsb: i32 = @as(i32, 1) << sps.log2_max_poc_lsb;
                const lsb: i32 = @intCast(h.poc_lsb);
                var msb = p.prev_msb;
                if (lsb < p.prev_lsb and p.prev_lsb - lsb >= @divTrunc(max_lsb, 2)) msb += max_lsb else if (lsb > p.prev_lsb and lsb - p.prev_lsb > @divTrunc(max_lsb, 2)) msb -= max_lsb;
                const top = msb + lsb;
                if (h.nal_ref_idc != 0) {
                    p.prev_msb = msb;
                    p.prev_lsb = lsb;
                }
                return .{ top, top + h.delta_poc_bottom };
            },
            else => {
                var offset: i64 = 0;
                if (!h.idr) offset = if (p.prev_frame_num > h.frame_num) p.prev_frame_num_offset + max_frame_num else p.prev_frame_num_offset;
                p.prev_frame_num_offset = offset;
                p.prev_frame_num = h.frame_num;
                if (sps.poc_type == 2) {
                    if (h.idr) return .{ 0, 0 };
                    const t: i64 = if (h.nal_ref_idc == 0) 2 * (offset + h.frame_num) - 1 else 2 * (offset + h.frame_num);
                    return .{ @intCast(t), @intCast(t) };
                }
                var abs: i64 = if (sps.num_ref_frames_in_poc_cycle != 0) offset + h.frame_num else 0;
                if (h.nal_ref_idc == 0 and abs > 0) abs -= 1;
                var expected: i64 = 0;
                if (abs > 0) {
                    var cycle_delta: i64 = 0;
                    for (sps.offsets_for_ref_frame[0..sps.num_ref_frames_in_poc_cycle]) |o| cycle_delta += o;
                    const n: i64 = sps.num_ref_frames_in_poc_cycle;
                    const cycle = @divTrunc(abs - 1, n);
                    const in_cycle: usize = @intCast(@mod(abs - 1, n));
                    expected = cycle * cycle_delta;
                    for (sps.offsets_for_ref_frame[0 .. in_cycle + 1]) |o| expected += o;
                }
                if (h.nal_ref_idc == 0) expected += sps.offset_for_non_ref_pic;
                const top = expected + h.delta_poc[0];
                const bottom = top + sps.offset_for_top_to_bottom_field + h.delta_poc[1];
                return .{ @intCast(top), @intCast(bottom) };
            },
        }
    }

    pub fn afterMmco5(p: *Poc, top: i32) void {
        p.prev_msb = 0;
        p.prev_lsb = top;
        p.prev_frame_num_offset = 0;
        p.prev_frame_num = 0;
    }
};

pub const Decoder = struct {
    a: va.Api,
    fd: c_int,
    dpy: va.Display,
    profiles: [3]bool,
    config: Id = invalid,
    context: Id = invalid,
    surfaces: [MAX_REFS + SPARE_SURFACES]Id = @splat(invalid),
    surface_count: usize = 0,
    width_mbs: u32 = 0,
    height_mbs: u32 = 0,
    profile: c_int = -1,
    sps: [32]Sps = @splat(.{}),
    pps: [256]Pps = @splat(.{}),
    dpb: Dpb = .{},
    poc: Poc = .{},
    last_output: Id = invalid,
    output_width: u32 = 0,
    output_height: u32 = 0,
    crop_x: u32 = 0,
    crop_y: u32 = 0,
    rbsp: std.ArrayListUnmanaged(u8) = .empty,
    removed: std.ArrayListUnmanaged(usize) = .empty,
};

const gpa = std.heap.c_allocator;

fn openDevice(a: va.Api, profiles: *[3]bool) ?struct { fd: c_int, dpy: va.Display } {
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
            for ([_]c_int{ profile_constrained_baseline, profile_main, profile_high }, 0..) |profile, i| profiles[i] = hasVld(a, dpy, profile);
            if (profiles[0]) return .{ .fd = fd, .dpy = dpy };
            _ = a.terminate(dpy);
        }
        _ = linux.close(fd);
    }
    return null;
}

fn hasVld(a: va.Api, dpy: va.Display, profile: c_int) bool {
    var entries: [32]c_int = undefined;
    var count: c_int = 0;
    if (a.maxNumEntrypoints(dpy) > entries.len) return false;
    if (a.queryConfigEntrypoints(dpy, profile, &entries, &count) != 0) return false;
    for (entries[0..@intCast(count)]) |e| if (e == entry_vld) return true;
    return false;
}

pub export fn fotone_vadec_open() ?*Decoder {
    const a = va.load() orelse return null;
    var profiles: [3]bool = .{ false, false, false };
    const dev = openDevice(a, &profiles) orelse return null;
    const d = gpa.create(Decoder) catch return null;
    d.* = .{ .a = a, .fd = dev.fd, .dpy = dev.dpy, .profiles = profiles };
    return d;
}

fn vaProfile(d: *const Decoder, sps: *const Sps) ?c_int {
    if (sps.profile_idc == 66 and sps.constraint_set1 and d.profiles[0]) return profile_constrained_baseline;
    if ((sps.profile_idc == 77 or (sps.profile_idc == 66 and sps.constraint_set1)) and d.profiles[1]) return profile_main;
    if ((sps.profile_idc == 100 or sps.profile_idc == 77 or (sps.profile_idc == 66 and sps.constraint_set1)) and d.profiles[2]) return profile_high;
    return null;
}

fn teardown(d: *Decoder) void {
    const a = d.a;
    if (d.context != invalid) _ = a.destroyContext(d.dpy, d.context);
    if (d.surface_count > 0) _ = a.destroySurfaces(d.dpy, &d.surfaces, @intCast(d.surface_count));
    if (d.config != invalid) _ = a.destroyConfig(d.dpy, d.config);
    d.context = invalid;
    d.config = invalid;
    d.surface_count = 0;
    d.surfaces = @splat(invalid);
    d.dpb.clear();
    d.last_output = invalid;
}

fn configure(d: *Decoder, sps: *const Sps) Error!void {
    const profile = vaProfile(d, sps) orelse return error.Unsupported;
    const needed = @max(sps.max_num_ref_frames, 1) + SPARE_SURFACES;
    if (d.context != invalid and profile == d.profile and sps.width_mbs == d.width_mbs and sps.height_mbs == d.height_mbs and needed <= d.surface_count) return;
    teardown(d);
    const a = d.a;
    var attribs = [_]va.Attrib{.{ .kind = 0, .value = va.rt_yuv420 }};
    check(a.createConfig(d.dpy, profile, entry_vld, &attribs, attribs.len, &d.config)) catch return error.Va;
    const count: u32 = @intCast(needed);
    check(a.createSurfaces(d.dpy, va.rt_yuv420, sps.width_mbs * 16, sps.height_mbs * 16, &d.surfaces, count, null, 0)) catch return error.Va;
    d.surface_count = count;
    check(a.createContext(d.dpy, d.config, @intCast(sps.width_mbs * 16), @intCast(sps.height_mbs * 16), va.progressive, &d.surfaces, @intCast(count), &d.context)) catch return error.Va;
    d.profile = profile;
    d.width_mbs = sps.width_mbs;
    d.height_mbs = sps.height_mbs;
}

fn freeSurface(d: *Decoder) Error!Id {
    for (d.surfaces[0..d.surface_count]) |s| {
        if (s != d.last_output and !d.dpb.holds(s)) return s;
    }
    return error.Unsupported;
}

pub fn nextNal(data: []const u8, from: *usize) ?[]const u8 {
    var i = from.*;
    while (i + 2 < data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) break;
    } else {
        from.* = data.len;
        return null;
    }
    const start = i + 3;
    var end = start;
    while (end + 2 < data.len) : (end += 1) {
        if (data[end] == 0 and data[end + 1] == 0 and (data[end + 2] == 1 or (end + 3 < data.len and data[end + 2] == 0 and data[end + 3] == 1))) break;
    } else end = data.len;
    from.* = end;
    var trimmed = end;
    while (trimmed > start and data[trimmed - 1] == 0) trimmed -= 1;
    return data[start..trimmed];
}

pub fn headerBitOffset(header_bits: usize, removed: []const usize) u16 {
    var bits = header_bits;
    for (removed) |raw| {
        if (raw * 8 >= bits) break;
        bits += 8;
    }
    return @intCast(bits);
}

pub export fn fotone_vadec_decode(d: *Decoder, data: [*]const u8, len: usize, width: *u32, height: *u32) c_int {
    return decode(d, data[0..len], width, height) catch -1;
}

fn decode(d: *Decoder, au: []const u8, width: *u32, height: *u32) Error!c_int {
    const a = d.a;
    var from: usize = 0;
    var started = false;
    errdefer if (started) {
        _ = a.endPicture(d.dpy, d.context);
    };
    var header: SliceHeader = undefined;
    var cur = Frame{};
    var pic = PictureParams{};
    var buffers: std.ArrayListUnmanaged(Id) = .empty;
    defer {
        for (buffers.items) |id| _ = a.destroyBuffer(d.dpy, id);
        buffers.deinit(gpa);
    }
    var sps_ptr: *const Sps = undefined;
    while (nextNal(au, &from)) |nal| {
        if (nal.len < 2) continue;
        const kind = nal[0] & 0x1f;
        if (kind != 1 and kind != 5 and kind != 7 and kind != 8) continue;
        try d.rbsp.resize(gpa, nal.len);
        const rbsp = try unescape(d.rbsp.items, nal, &d.removed, gpa);
        switch (kind) {
            7 => _ = try parseSps(rbsp, &d.sps),
            8 => _ = try parsePps(rbsp, &d.pps),
            else => {
                var params = SliceParams{};
                const h = try parseSlice(rbsp, &d.sps, &d.pps, &params);
                if (h.redundant_pic_cnt > 0) continue;
                const pps = &d.pps[h.pps_id];
                const sps = &d.sps[pps.sps_id];
                if (!started) {
                    try configure(d, sps);
                    sps_ptr = sps;
                    header = h;
                    if (h.idr) d.dpb.clear();
                    const max_frame_num: u32 = @as(u32, 1) << sps.log2_max_frame_num;
                    d.dpb.wrap(h.frame_num, max_frame_num);
                    const order = d.poc.compute(sps, &h);
                    cur = .{ .surface = try freeSurface(d), .frame_num = h.frame_num, .frame_num_wrap = @intCast(h.frame_num), .top = order[0], .bottom = order[1] };
                    pic = pictureParams(d, sps, pps, &h, &cur);
                    var iq = IqMatrix{};
                    try buffers.append(gpa, try create(d, buf_picture, std.mem.asBytes(&pic)));
                    try buffers.append(gpa, try create(d, buf_iq, std.mem.asBytes(&iq)));
                    check(a.beginPicture(d.dpy, d.context, cur.surface)) catch return error.Va;
                    check(a.renderPicture(d.dpy, d.context, buffers.items.ptr, 2)) catch return error.Va;
                    started = true;
                }
                try fillSlice(d, sps, &h, &cur, &params, nal);
                var ids = [_]Id{ try create(d, buf_slice_param, std.mem.asBytes(&params)), try create(d, buf_slice_data, nal) };
                try buffers.appendSlice(gpa, &ids);
                check(a.renderPicture(d.dpy, d.context, &ids, ids.len)) catch return error.Va;
            },
        }
    }
    if (!started) return 0;
    check(a.endPicture(d.dpy, d.context)) catch return error.Va;
    check(a.syncSurface(d.dpy, cur.surface)) catch return error.Va;
    if (header.nal_ref_idc != 0) {
        if (d.dpb.mark(&header, &cur, sps_ptr.max_num_ref_frames)) d.poc.afterMmco5(cur.top);
    }
    d.last_output = cur.surface;
    d.output_width = sps_ptr.width();
    d.output_height = sps_ptr.height();
    d.crop_x = sps_ptr.crop_left * 2;
    d.crop_y = sps_ptr.crop_top * 2;
    width.* = d.output_width;
    height.* = d.output_height;
    return 1;
}

fn create(d: *Decoder, kind: c_int, bytes: []const u8) Error!Id {
    var id: Id = invalid;
    check(d.a.createBuffer(d.dpy, d.context, kind, @intCast(bytes.len), 1, bytes.ptr, &id)) catch return error.Va;
    return id;
}

fn pictureParams(d: *Decoder, sps: *const Sps, pps: *const Pps, h: *const SliceHeader, cur: *const Frame) PictureParams {
    var p = PictureParams{
        .curr = .{ .picture_id = cur.surface, .frame_idx = h.frame_num, .flags = 0, .top_order = cur.top, .bottom_order = cur.bottom },
        .width_in_mbs_minus1 = @intCast(sps.width_mbs - 1),
        .height_in_mbs_minus1 = @intCast(sps.height_mbs - 1),
        .num_ref_frames = @intCast(sps.max_num_ref_frames),
        .seq_fields = sps.chroma_format_idc | (@as(u32, @intFromBool(sps.gaps_allowed)) << 3) | (1 << 4) | (@as(u32, @intFromBool(sps.direct_8x8_inference)) << 6) |
            (@as(u32, @intFromBool(sps.level_idc >= 31)) << 7) | (@as(u32, sps.log2_max_frame_num - 4) << 8) | (sps.poc_type << 12) |
            (@as(u32, sps.log2_max_poc_lsb - 4) << 14) | (@as(u32, @intFromBool(sps.delta_pic_order_always_zero)) << 18),
        .pic_init_qp_minus26 = @intCast(pps.pic_init_qp_minus26),
        .pic_init_qs_minus26 = @intCast(pps.pic_init_qs_minus26),
        .chroma_qp_index_offset = @intCast(pps.chroma_qp_index_offset),
        .second_chroma_qp_index_offset = @intCast(pps.second_chroma_qp_index_offset),
        .pic_fields = @as(u32, @intFromBool(pps.entropy_coding_mode)) | (@as(u32, @intFromBool(pps.weighted_pred)) << 1) | (pps.weighted_bipred_idc << 2) |
            (@as(u32, @intFromBool(pps.transform_8x8_mode)) << 4) | (@as(u32, @intFromBool(pps.constrained_intra_pred)) << 6) |
            (@as(u32, @intFromBool(pps.bottom_field_pic_order_present)) << 7) | (@as(u32, @intFromBool(pps.deblocking_filter_control_present)) << 8) |
            (@as(u32, @intFromBool(pps.redundant_pic_cnt_present)) << 9) | (@as(u32, @intFromBool(h.nal_ref_idc != 0)) << 10),
        .frame_num = @intCast(h.frame_num),
    };
    for (d.dpb.refs(), 0..) |f, i| p.refs[i] = f.picture();
    return p;
}

fn fillSlice(d: *Decoder, sps: *const Sps, h: *const SliceHeader, cur: *const Frame, s: *SliceParams, nal: []const u8) Error!void {
    s.data_size = @intCast(nal.len);
    s.data_bit_offset = headerBitOffset(h.header_bits, d.removed.items);
    s.first_mb = @intCast(h.first_mb);
    s.slice_type = @intCast(h.slice_type);
    s.direct_spatial_mv_pred_flag = @intFromBool(h.direct_spatial_mv_pred);
    s.num_ref_idx_l0_active_minus1 = @intCast(h.num_ref_idx_l0_active_minus1);
    s.num_ref_idx_l1_active_minus1 = @intCast(h.num_ref_idx_l1_active_minus1);
    s.cabac_init_idc = @intCast(h.cabac_init_idc);
    s.slice_qp_delta = @intCast(h.slice_qp_delta);
    s.disable_deblocking_filter_idc = @intCast(h.disable_deblocking_filter_idc);
    s.slice_alpha_c0_offset_div2 = @intCast(h.alpha);
    s.slice_beta_offset_div2 = @intCast(h.beta);
    if (h.isI()) return;
    var l0: [34]Frame = @splat(.{});
    var l1: [34]Frame = @splat(.{});
    const lens = initLists(&d.dpb, h, cur.poc(), &l0, &l1);
    const max_frame_num: u32 = @as(u32, 1) << sps.log2_max_frame_num;
    try modifyList(&d.dpb, &l0, lens[0], h.num_ref_idx_l0_active_minus1 + 1, h.mods[0][0..h.mod_count[0]], h.frame_num, max_frame_num);
    for (0..h.num_ref_idx_l0_active_minus1 + 1) |i| s.ref_list0[i] = if (l0[i].surface != invalid) l0[i].picture() else .{};
    if (h.isB()) {
        try modifyList(&d.dpb, &l1, lens[1], h.num_ref_idx_l1_active_minus1 + 1, h.mods[1][0..h.mod_count[1]], h.frame_num, max_frame_num);
        for (0..h.num_ref_idx_l1_active_minus1 + 1) |i| s.ref_list1[i] = if (l1[i].surface != invalid) l1[i].picture() else .{};
    }
}

pub export fn fotone_vadec_frame(d: *Decoder, y: [*]u8, stride_y: c_int, u: [*]u8, stride_u: c_int, v: [*]u8, stride_v: c_int) c_int {
    frame(d, y, @intCast(stride_y), u, @intCast(stride_u), v, @intCast(stride_v)) catch return -1;
    return 0;
}

pub fn fromNv12(src: [*]const u8, pitch_y: usize, pitch_uv: usize, uv_offset: usize, x: usize, top: usize, width: usize, height: usize, y: [*]u8, stride_y: usize, u: [*]u8, stride_u: usize, v: [*]u8, stride_v: usize) void {
    for (0..height) |row| @memcpy(y[row * stride_y ..][0..width], src[(top + row) * pitch_y + x ..][0..width]);
    for (0..height / 2) |row| {
        const line = src[uv_offset + (top / 2 + row) * pitch_uv + x ..];
        for (0..width / 2) |col| {
            u[row * stride_u + col] = line[col * 2];
            v[row * stride_v + col] = line[col * 2 + 1];
        }
    }
}

fn frame(d: *Decoder, y: [*]u8, stride_y: usize, u: [*]u8, stride_u: usize, v: [*]u8, stride_v: usize) Error!void {
    if (d.last_output == invalid) return error.Missing;
    const a = d.a;
    var image: va.Image = undefined;
    check(a.deriveImage(d.dpy, d.last_output, &image)) catch return error.Va;
    defer _ = a.destroyImage(d.dpy, image.image_id);
    if (image.format.fourcc != va.fourcc_nv12) return error.Unsupported;
    var data: ?*anyopaque = null;
    check(a.mapBuffer(d.dpy, image.buf, &data)) catch return error.Va;
    defer _ = a.unmapBuffer(d.dpy, image.buf);
    const base: [*]const u8 = @ptrCast(data orelse return error.Va);
    fromNv12(base + image.offsets[0], image.pitches[0], image.pitches[1], image.offsets[1] - image.offsets[0], d.crop_x, d.crop_y, d.output_width, d.output_height, y, stride_y, u, stride_u, v, stride_v);
}

pub export fn fotone_vadec_profiles(d: *const Decoder) c_uint {
    var mask: c_uint = 0;
    for (d.profiles, 0..) |p, i| {
        if (p) mask |= @as(c_uint, 1) << @intCast(i);
    }
    return mask;
}

pub export fn fotone_vadec_close(d: *Decoder) void {
    teardown(d);
    _ = d.a.terminate(d.dpy);
    _ = linux.close(d.fd);
    d.rbsp.deinit(gpa);
    d.removed.deinit(gpa);
    gpa.destroy(d);
}

test "the decode structs match the libva 2.23 layout" {
    try std.testing.expectEqual(@as(usize, 672), @sizeOf(PictureParams));
    try std.testing.expectEqual(@as(usize, 240), @sizeOf(IqMatrix));
    try std.testing.expectEqual(@as(usize, 3128), @sizeOf(SliceParams));
    try std.testing.expectEqual(@as(usize, 620), @offsetOf(PictureParams, "seq_fields"));
    try std.testing.expectEqual(@as(usize, 632), @offsetOf(PictureParams, "pic_fields"));
    try std.testing.expectEqual(@as(usize, 636), @offsetOf(PictureParams, "frame_num"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(SliceParams, "ref_list0"));
    try std.testing.expectEqual(@as(usize, 2332), @offsetOf(SliceParams, "luma_log2_weight_denom"));
    try std.testing.expectEqual(@as(usize, 2722), @offsetOf(SliceParams, "luma_weight_l1_flag"));
}

test "exp-Golomb codes decode" {
    var b = Bits{ .data = &.{ 0b1010_0110, 0b0111_0000 } };
    try std.testing.expectEqual(@as(u32, 0), try b.ue());
    try std.testing.expectEqual(@as(u32, 1), try b.ue());
    try std.testing.expectEqual(@as(u32, 2), try b.ue());
    try std.testing.expectEqual(@as(i32, -3), try b.se());
}

test "emulation prevention bytes are removed and counted" {
    var out: [8]u8 = undefined;
    var removed: std.ArrayListUnmanaged(usize) = .empty;
    defer removed.deinit(std.testing.allocator);
    const r = try unescape(&out, &.{ 0x65, 0, 0, 3, 1, 0, 0, 3, 0 }, &removed, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 0, 0, 1, 0, 0, 0 }, r);
    try std.testing.expectEqualSlices(usize, &.{ 3, 7 }, removed.items);
    try std.testing.expectEqual(@as(u16, 24), headerBitOffset(24, removed.items));
    try std.testing.expectEqual(@as(u16, 33), headerBitOffset(25, removed.items));
    try std.testing.expectEqual(@as(u16, 66), headerBitOffset(50, removed.items));
}

test "real camera and encoder parameter sets parse" {
    var sps: [32]Sps = @splat(.{});
    var pps: [256]Pps = @splat(.{});
    var buf: [64]u8 = undefined;
    var removed: std.ArrayListUnmanaged(usize) = .empty;
    defer removed.deinit(std.testing.allocator);
    const base = [_]u8{ 0x67, 0x42, 0xc0, 0x15, 0xda, 0x05, 0x07, 0xec, 0x05, 0xa8, 0x30, 0x30, 0x35, 0x28, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x01, 0xe4, 0x78, 0xb1, 0x75 };
    _ = try parseSps(try unescape(&buf, &base, &removed, std.testing.allocator), &sps);
    try std.testing.expectEqual(@as(u8, 66), sps[0].profile_idc);
    try std.testing.expect(sps[0].constraint_set1);
    try std.testing.expectEqual(@as(u32, 320), sps[0].width());
    try std.testing.expectEqual(@as(u32, 240), sps[0].height());
    try std.testing.expectEqual(@as(u32, 2), sps[0].poc_type);
    _ = try parsePps(&.{ 0x68, 0xce, 0x3c, 0x80 }, &pps);
    try std.testing.expect(pps[0].valid and !pps[0].entropy_coding_mode);
    const high = [_]u8{ 0x67, 0x64, 0x00, 0x1e, 0xac, 0xd9, 0x42, 0x8d, 0xf9, 0x30, 0x16, 0xa0, 0xc0, 0xc0, 0xd4, 0xa0, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x03, 0x02, 0x91, 0xe2, 0xc5, 0xb2, 0xc0 };
    _ = try parseSps(try unescape(&buf, &high, &removed, std.testing.allocator), &sps);
    try std.testing.expectEqual(@as(u8, 100), sps[0].profile_idc);
    try std.testing.expectEqual(@as(u32, 160), sps[0].width());
    try std.testing.expectEqual(@as(u32, 90), sps[0].height());
    try std.testing.expectEqual(@as(u32, 4), sps[0].max_num_ref_frames);
    _ = try parsePps(&.{ 0x68, 0xeb, 0xec, 0x4c, 0x84, 0xc0 }, &pps);
    try std.testing.expect(pps[0].entropy_coding_mode and pps[0].transform_8x8_mode);
}

test "start codes split an access unit into NAL units" {
    const au = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5 };
    var from: usize = 0;
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 1, 2 }, nextNal(&au, &from).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x68, 3 }, nextNal(&au, &from).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 4, 5 }, nextNal(&au, &from).?);
    try std.testing.expect(nextNal(&au, &from) == null);
}

test "the sliding window drops the oldest short-term frame" {
    var dpb = Dpb{};
    var h = SliceHeader{ .nal_ref_idc = 1, .idr = true };
    var f0 = Frame{ .surface = 1, .frame_num = 0 };
    _ = dpb.mark(&h, &f0, 2);
    h.idr = false;
    for (1..4) |i| {
        h.frame_num = @intCast(i);
        dpb.wrap(h.frame_num, 16);
        var f = Frame{ .surface = @intCast(i + 1), .frame_num = @intCast(i), .frame_num_wrap = @intCast(i) };
        _ = dpb.mark(&h, &f, 2);
    }
    try std.testing.expectEqual(@as(usize, 2), dpb.count);
    try std.testing.expect(!dpb.holds(1));
    try std.testing.expect(!dpb.holds(2));
    try std.testing.expect(dpb.holds(3) and dpb.holds(4));
}

test "P lists start from the most recent frame and honour modifications" {
    var dpb = Dpb{};
    dpb.frames[0] = .{ .surface = 10, .frame_num = 1, .frame_num_wrap = 1, .short_term = true };
    dpb.frames[1] = .{ .surface = 11, .frame_num = 2, .frame_num_wrap = 2, .short_term = true };
    dpb.frames[2] = .{ .surface = 12, .frame_num = 3, .frame_num_wrap = 3, .short_term = true };
    dpb.count = 3;
    const h = SliceHeader{ .slice_type = 0, .frame_num = 4 };
    var l0: [34]Frame = @splat(.{});
    var l1: [34]Frame = @splat(.{});
    const lens = initLists(&dpb, &h, 8, &l0, &l1);
    try std.testing.expectEqual(@as(usize, 3), lens[0]);
    try std.testing.expectEqual(@as(Id, 12), l0[0].surface);
    try std.testing.expectEqual(@as(Id, 10), l0[2].surface);
    try modifyList(&dpb, &l0, lens[0], 2, &.{.{ .idc = 0, .value = 2 }}, 4, 16);
    try std.testing.expectEqual(@as(Id, 10), l0[0].surface);
    try std.testing.expectEqual(@as(Id, 12), l0[1].surface);
}

test "picture order count type 0 wraps the LSB" {
    var sps = Sps{ .poc_type = 0, .log2_max_poc_lsb = 4 };
    var poc = Poc{};
    var h = SliceHeader{ .idr = true, .nal_ref_idc = 1, .poc_lsb = 0 };
    try std.testing.expectEqual(@as(i32, 0), poc.compute(&sps, &h)[0]);
    h.idr = false;
    h.poc_lsb = 14;
    try std.testing.expectEqual(@as(i32, -2), poc.compute(&sps, &h)[0]);
    h.poc_lsb = 2;
    try std.testing.expectEqual(@as(i32, 2), poc.compute(&sps, &h)[0]);
    sps.poc_type = 2;
    poc = .{};
    h = .{ .idr = false, .nal_ref_idc = 1, .frame_num = 3 };
    try std.testing.expectEqual(@as(i32, 6), poc.compute(&sps, &h)[0]);
}

test "NV12 surfaces copy out as cropped I420" {
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 20, 30, 21, 31 };
    var y: [4]u8 = undefined;
    var u: [1]u8 = undefined;
    var v: [1]u8 = undefined;
    fromNv12(&src, 4, 4, 8, 2, 0, 2, 2, &y, 2, &u, 1, &v, 1);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 7, 8 }, &y);
    try std.testing.expectEqual(@as(u8, 21), u[0]);
    try std.testing.expectEqual(@as(u8, 31), v[0]);
}
