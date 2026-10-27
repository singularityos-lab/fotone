const std = @import("std");
const c = @import("c.zig").c;
const engine = @import("engine");
const options = @import("options");

pub const ACTIONS = [_][]const u8{
    "NO_ACTION",              "OPEN_LINK",                "OPEN_LINK_IN_NEW_WINDOW", "DOWNLOAD_LINK_TO_DISK",
    "COPY_LINK_TO_CLIPBOARD", "OPEN_IMAGE_IN_NEW_WINDOW", "DOWNLOAD_IMAGE_TO_DISK",  "COPY_IMAGE_TO_CLIPBOARD",
    "COPY_IMAGE_URL_TO_CLIPBOARD", "OPEN_FRAME_IN_NEW_WINDOW", "GO_BACK", "GO_FORWARD",
    "STOP",                   "RELOAD",                   "COPY",                    "CUT",
    "PASTE",                  "DELETE",                   "SELECT_ALL",              "INPUT_METHODS",
    "UNICODE",                "SPELLING_GUESS",           "NO_GUESSES_FOUND",        "IGNORE_SPELLING",
    "LEARN_SPELLING",         "IGNORE_GRAMMAR",           "FONT_MENU",               "BOLD",
    "ITALIC",                 "UNDERLINE",                "OUTLINE",                 "INSPECT_ELEMENT",
    "OPEN_VIDEO_IN_NEW_WINDOW", "OPEN_AUDIO_IN_NEW_WINDOW", "COPY_VIDEO_LINK_TO_CLIPBOARD", "COPY_AUDIO_LINK_TO_CLIPBOARD",
    "TOGGLE_MEDIA_CONTROLS",  "TOGGLE_MEDIA_LOOP",        "ENTER_VIDEO_FULLSCREEN",  "MEDIA_PLAY",
    "MEDIA_PAUSE",            "MEDIA_MUTE",               "DOWNLOAD_VIDEO_TO_DISK",  "DOWNLOAD_AUDIO_TO_DISK",
    "INSERT_EMOJI",           "PASTE_AS_PLAIN_TEXT",
};

pub const ACTION_CUSTOM = 10000;
const PREFIX = "WEBKIT_CONTEXT_MENU_ACTION_";

fn nick(comptime name: []const u8) [:0]const u8 {
    comptime {
        var out: [name.len:0]u8 = undefined;
        for (name, 0..) |ch, i| out[i] = if (ch == '_') '-' else std.ascii.toLower(ch);
        const final = out;
        return &final;
    }
}

const action_values = blk: {
    @setEvalBranchQuota(100000);
    var v: [ACTIONS.len + 2]c.GEnumValue = undefined;
    for (ACTIONS, 0..) |a, i| v[i] = .{ .value = i, .value_name = PREFIX ++ a, .value_nick = nick(a) };
    v[ACTIONS.len] = .{ .value = ACTION_CUSTOM, .value_name = PREFIX ++ "CUSTOM", .value_nick = "custom" };
    v[ACTIONS.len + 1] = .{ .value = 0, .value_name = null, .value_nick = null };
    break :blk v;
};

var action_type: c.GType = 0;

export fn webkit_context_menu_action_get_type() c.GType {
    return enumType(&action_type, "WebKitContextMenuAction", &action_values);
}

fn actionClass() ?*c.GEnumClass {
    const t = engine.lookup("webkit_context_menu_action_get_type", fn () callconv(.c) c.GType)();
    return @ptrCast(@alignCast(c.g_type_class_ref(t)));
}

pub fn gtkIndex(name: []const u8) ?c_int {
    if (!std.mem.startsWith(u8, name, PREFIX)) return null;
    const short = name[PREFIX.len..];
    if (std.mem.eql(u8, short, "CUSTOM")) return ACTION_CUSTOM;
    for (ACTIONS, 0..) |a, i| if (std.mem.eql(u8, a, short)) return @intCast(i);
    return null;
}

pub fn toEngine(gtk: c_int) c_int {
    const k = actionClass() orelse return gtk;
    defer c.g_type_class_unref(k);
    var buf: [96]u8 = undefined;
    const name = if (gtk == ACTION_CUSTOM) "CUSTOM" else if (gtk >= 0 and gtk < ACTIONS.len) ACTIONS[@intCast(gtk)] else return 0;
    const full = std.fmt.bufPrintZ(&buf, PREFIX ++ "{s}", .{name}) catch return 0;
    const v = c.g_enum_get_value_by_name(k, full.ptr) orelse return 0;
    return v.*.value;
}

pub fn toGtk(value: c_int) c_int {
    const k = actionClass() orelse return value;
    defer c.g_type_class_unref(k);
    const v = c.g_enum_get_value(k, value) orelse return 0;
    return gtkIndex(std.mem.span(v.*.value_name)) orelse 0;
}

export fn webkit_context_menu_item_new_from_stock_action(action: c_int) ?*anyopaque {
    return engine.lookup("webkit_context_menu_item_new_from_stock_action", fn (c_int) callconv(.c) ?*anyopaque)(toEngine(action));
}

export fn webkit_context_menu_item_new_from_stock_action_with_label(action: c_int, label: [*c]const u8) ?*anyopaque {
    return engine.lookup("webkit_context_menu_item_new_from_stock_action_with_label", fn (c_int, [*c]const u8) callconv(.c) ?*anyopaque)(toEngine(action), label);
}

export fn webkit_context_menu_item_get_stock_action(item: ?*anyopaque) c_int {
    return toGtk(engine.lookup("webkit_context_menu_item_get_stock_action", fn (?*anyopaque) callconv(.c) c_int)(item));
}

export fn webkit_context_menu_get_event(_: ?*anyopaque) ?*c.GdkEvent {
    return null;
}

export fn webkit_option_menu_get_event(_: ?*anyopaque) ?*c.GdkEvent {
    return null;
}

fn enumType(store: *c.GType, name: [*:0]const u8, values: [*c]const c.GEnumValue) c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(store)) != 0) {
        const t = c.g_enum_register_static(name, values);
        c.g_once_init_leave_pointer(@ptrCast(store), @ptrFromInt(t));
    }
    return store.*;
}

var policy_type: c.GType = 0;
const policy_values = if (options.gtk3) [_]c.GEnumValue{
    .{ .value = 0, .value_name = "WEBKIT_HARDWARE_ACCELERATION_POLICY_ON_DEMAND", .value_nick = "on-demand" },
    .{ .value = 1, .value_name = "WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS", .value_nick = "always" },
    .{ .value = 2, .value_name = "WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER", .value_nick = "never" },
    .{ .value = 0, .value_name = null, .value_nick = null },
} else [_]c.GEnumValue{
    .{ .value = 0, .value_name = "WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS", .value_nick = "always" },
    .{ .value = 1, .value_name = "WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER", .value_nick = "never" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

export fn webkit_hardware_acceleration_policy_get_type() c.GType {
    return enumType(&policy_type, "WebKitHardwareAccelerationPolicy", &policy_values);
}

var print_error_type: c.GType = 0;
const print_error_values = [_]c.GEnumValue{
    .{ .value = 599, .value_name = "WEBKIT_PRINT_ERROR_GENERAL", .value_nick = "general" },
    .{ .value = 500, .value_name = "WEBKIT_PRINT_ERROR_PRINTER_NOT_FOUND", .value_nick = "printer-not-found" },
    .{ .value = 501, .value_name = "WEBKIT_PRINT_ERROR_INVALID_PAGE_RANGE", .value_nick = "invalid-page-range" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

export fn webkit_print_error_get_type() c.GType {
    return enumType(&print_error_type, "WebKitPrintError", &print_error_values);
}

export fn webkit_print_error_quark() c.GQuark {
    return c.g_quark_from_static_string("WebKitPrintError");
}

var response_type: c.GType = 0;
const response_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "WEBKIT_PRINT_OPERATION_RESPONSE_PRINT", .value_nick = "print" },
    .{ .value = 1, .value_name = "WEBKIT_PRINT_OPERATION_RESPONSE_CANCEL", .value_nick = "cancel" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

export fn webkit_print_operation_response_get_type() c.GType {
    return enumType(&response_type, "WebKitPrintOperationResponse", &response_values);
}

var clipboard_type: c.GType = 0;

fn clipboardInterfaceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = iface;
}

export fn webkit_clipboard_permission_request_get_type() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&clipboard_type)) != 0) {
        const t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, "WebKitClipboardPermissionRequest", @sizeOf(c.GObjectClass), null, @sizeOf(c.GObject) + @sizeOf(usize), null, c.G_TYPE_FLAG_FINAL);
        const perm = engine.lookup("webkit_permission_request_get_type", fn () callconv(.c) c.GType)();
        const info = c.GInterfaceInfo{ .interface_init = clipboardInterfaceInit, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(t, perm, &info);
        c.g_once_init_leave_pointer(@ptrCast(&clipboard_type), @ptrFromInt(t));
    }
    return clipboard_type;
}

const DPI = 96.0;

export fn webkit_settings_font_size_to_pixels(points: u32) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(points)) * DPI / 72.0));
}

export fn webkit_settings_font_size_to_points(pixels: u32) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(pixels)) * 72.0 / DPI));
}

const GESTURES = "fotone-webkitgtk-gestures";
const POLICY = "fotone-webkitgtk-acceleration";

export fn webkit_settings_get_enable_back_forward_navigation_gestures(s: ?*c.GObject) c.gboolean {
    return @intFromBool(c.g_object_get_data(s, GESTURES) != null);
}

export fn webkit_settings_set_enable_back_forward_navigation_gestures(s: ?*c.GObject, enabled: c.gboolean) void {
    c.g_object_set_data(s, GESTURES, if (enabled != 0) @ptrFromInt(1) else null);
}

export fn webkit_settings_get_hardware_acceleration_policy(s: ?*c.GObject) c_int {
    return @intCast(@intFromPtr(c.g_object_get_data(s, POLICY)));
}

export fn webkit_settings_set_hardware_acceleration_policy(s: ?*c.GObject, policy: c_int) void {
    c.g_object_set_data(s, POLICY, @ptrFromInt(@as(usize, @intCast(@max(policy, 0)))));
}

const GEOMETRY = "fotone-webkitgtk-geometry";

export fn webkit_window_properties_get_geometry(p: ?*c.GObject, rect: ?*c.GdkRectangle) void {
    const r = rect orelse return;
    r.* = if (c.g_object_get_data(p, GEOMETRY)) |g| @as(*c.GdkRectangle, @ptrCast(@alignCast(g))).* else std.mem.zeroes(c.GdkRectangle);
}

const PROP_GESTURES = 0x4000;
const PROP_POLICY = 0x4001;
const PROP_GEOMETRY = 0x4002;
const PROP_FILTER = 0x4003;

const Accessors = struct {
    get: ?*const fn ([*c]c.GObject, c.guint, [*c]c.GValue, [*c]c.GParamSpec) callconv(.c) void = null,
    set: ?*const fn ([*c]c.GObject, c.guint, [*c]const c.GValue, [*c]c.GParamSpec) callconv(.c) void = null,
};

var settings_base: Accessors = .{};
var window_base: Accessors = .{};
var chooser_base: Accessors = .{};

fn baseOf(o: [*c]c.GObject) *Accessors {
    const t = o.*.g_type_instance.g_class.*.g_type;
    if (settings_once != 0 and c.g_type_is_a(t, webkit_settings_get_type()) != 0) return &settings_base;
    if (window_once != 0 and c.g_type_is_a(t, webkit_window_properties_get_type()) != 0) return &window_base;
    return &chooser_base;
}

fn extraGet(o: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_GESTURES => c.g_value_set_boolean(value, webkit_settings_get_enable_back_forward_navigation_gestures(o)),
        PROP_POLICY => c.g_value_set_enum(value, webkit_settings_get_hardware_acceleration_policy(o)),
        PROP_GEOMETRY => {
            var r: c.GdkRectangle = undefined;
            webkit_window_properties_get_geometry(o, &r);
            c.g_value_set_boxed(value, &r);
        },
        PROP_FILTER => c.g_value_take_object(value, webkit_file_chooser_request_get_mime_types_filter(o)),
        else => if (baseOf(o).get) |f| f(o, id, value, spec),
    }
}

fn extraSet(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_GESTURES => webkit_settings_set_enable_back_forward_navigation_gestures(o, c.g_value_get_boolean(value)),
        PROP_POLICY => webkit_settings_set_hardware_acceleration_policy(o, c.g_value_get_enum(value)),
        PROP_GEOMETRY => if (c.g_value_get_boxed(value)) |b| {
            const copy: *c.GdkRectangle = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GdkRectangle))));
            copy.* = @as(*const c.GdkRectangle, @ptrCast(@alignCast(b))).*;
            c.g_object_set_data_full(o, GEOMETRY, copy, c.g_free);
        },
        else => if (baseOf(o).set) |f| f(o, id, value, spec),
    }
}

fn extend(t: c.GType, base: *Accessors, specs: []const struct { c.guint, *c.GParamSpec }) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    base.get = @ptrCast(oc.get_property);
    base.set = @ptrCast(oc.set_property);
    oc.get_property = @ptrCast(&extraGet);
    oc.set_property = @ptrCast(&extraSet);
    for (specs) |s| c.g_object_class_install_property(oc, s[0], s[1]);
}

var settings_once: usize = 0;
var window_once: usize = 0;
var chooser_once: usize = 0;

const RWC = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS;

pub export fn webkit_settings_get_type() c.GType {
    const t = engine.lookup("webkit_settings_get_type", fn () callconv(.c) c.GType)();
    if (c.g_once_init_enter(&settings_once) != 0) {
        extend(t, &settings_base, &.{
            .{ PROP_GESTURES, c.g_param_spec_boolean("enable-back-forward-navigation-gestures", null, null, 0, RWC) },
            .{ PROP_POLICY, c.g_param_spec_enum("hardware-acceleration-policy", null, null, webkit_hardware_acceleration_policy_get_type(), 0, RWC) },
        });
        c.g_once_init_leave(&settings_once, 1);
    }
    return t;
}

pub export fn webkit_window_properties_get_type() c.GType {
    const t = engine.lookup("webkit_window_properties_get_type", fn () callconv(.c) c.GType)();
    if (c.g_once_init_enter(&window_once) != 0) {
        extend(t, &window_base, &.{
            .{ PROP_GEOMETRY, c.g_param_spec_boxed("geometry", null, null, c.gdk_rectangle_get_type(), c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS) },
        });
        c.g_once_init_leave(&window_once, 1);
    }
    return t;
}

pub export fn webkit_file_chooser_request_get_type() c.GType {
    const t = engine.lookup("webkit_file_chooser_request_get_type", fn () callconv(.c) c.GType)();
    if (c.g_once_init_enter(&chooser_once) != 0) {
        extend(t, &chooser_base, &.{
            .{ PROP_FILTER, c.g_param_spec_object("filter", null, null, c.gtk_file_filter_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS) },
        });
        c.g_once_init_leave(&chooser_once, 1);
    }
    return t;
}

export fn webkit_file_chooser_request_get_mime_types_filter(r: ?*anyopaque) ?*c.GtkFileFilter {
    const types = engine.lookup("webkit_file_chooser_request_get_mime_types", fn (?*anyopaque) callconv(.c) [*c]const [*c]const u8)(r);
    if (types == null or types[0] == null) return null;
    const f = c.gtk_file_filter_new();
    var i: usize = 0;
    while (types[i] != null) : (i += 1) c.gtk_file_filter_add_mime_type(f, types[i]);
    return f;
}

pub export fn webkit_favicon_database_get_type() c.GType {
    const t = engine.lookup("webkit_favicon_database_get_type", fn () callconv(.c) c.GType)();
    if (c.g_signal_lookup("favicon-changed", t) == 0) _ = c.g_signal_new("favicon-changed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 2, c.G_TYPE_STRING, c.G_TYPE_STRING);
    return t;
}

export fn webkit_favicon_database_get_favicon_uri(_: ?*anyopaque, _: [*c]const u8) [*c]u8 {
    return null;
}

export fn webkit_favicon_database_get_favicon(db: ?*c.GObject, _: [*c]const u8, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    const task = c.g_task_new(db, cancellable, cb, data);
    defer c.g_object_unref(task);
    c.g_task_return_new_error(task, c.g_io_error_quark(), c.G_IO_ERROR_NOT_SUPPORTED, "favicons are available from webkit_web_view_get_favicon");
}

export fn webkit_favicon_database_get_favicon_finish(_: ?*c.GObject, res: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*anyopaque {
    return @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(@alignCast(res)), err)));
}

test "context menu actions keep their GTK numbers" {
    try std.testing.expectEqual(@as(?c_int, 8), gtkIndex("WEBKIT_CONTEXT_MENU_ACTION_COPY_IMAGE_URL_TO_CLIPBOARD"));
    try std.testing.expectEqual(@as(?c_int, 45), gtkIndex("WEBKIT_CONTEXT_MENU_ACTION_PASTE_AS_PLAIN_TEXT"));
    try std.testing.expectEqual(@as(?c_int, ACTION_CUSTOM), gtkIndex("WEBKIT_CONTEXT_MENU_ACTION_CUSTOM"));
    try std.testing.expectEqual(@as(?c_int, null), gtkIndex("WEBKIT_CONTEXT_MENU_ACTION_NOPE"));
}
