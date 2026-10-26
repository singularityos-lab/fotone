const std = @import("std");
const c = @import("c.zig").c;
const engine = @import("engine");
const view = @import("view3.zig");
const extra = @import("extra.zig");
const legacy = @import("legacy.zig");

fn enumType(store: *c.GType, name: [*:0]const u8, values: [*c]const c.GEnumValue) c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(store)) != 0) {
        const t = c.g_enum_register_static(name, values);
        c.g_once_init_leave_pointer(@ptrCast(store), @ptrFromInt(t));
    }
    return store.*;
}

fn objectType(store: *c.GType, name: [*:0]const u8, init: c.GClassInitFunc) c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(store)) != 0) {
        const t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, c.g_intern_static_string(name), @sizeOf(c.GObjectClass), init, @sizeOf(c.GObject), null, 0);
        c.g_once_init_leave_pointer(@ptrCast(store), @ptrFromInt(t));
    }
    return store.*;
}

var step_type: c.GType = 0;
const step_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "WEBKIT_FORM_SUBMISSION_WILL_SEND_DOM_EVENT", .value_nick = "send-dom-event" },
    .{ .value = 1, .value_name = "WEBKIT_FORM_SUBMISSION_WILL_COMPLETE", .value_nick = "complete" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

export fn webkit_form_submission_step_get_type() c.GType {
    return enumType(&step_type, "WebKitFormSubmissionStep", &step_values);
}

var model_type: c.GType = 0;
const model_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "WEBKIT_PROCESS_MODEL_SHARED_SECONDARY_PROCESS", .value_nick = "shared-secondary-process" },
    .{ .value = 1, .value_name = "WEBKIT_PROCESS_MODEL_MULTIPLE_SECONDARY_PROCESSES", .value_nick = "multiple-secondary-processes" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

export fn webkit_process_model_get_type() c.GType {
    return enumType(&model_type, "WebKitProcessModel", &model_values);
}

var plugin_error_type: c.GType = 0;
const plugin_error_values = [_]c.GEnumValue{
    .{ .value = 299, .value_name = "WEBKIT_PLUGIN_ERROR_FAILED", .value_nick = "failed" },
    .{ .value = 200, .value_name = "WEBKIT_PLUGIN_ERROR_CANNOT_FIND_PLUGIN", .value_nick = "cannot-find-plugin" },
    .{ .value = 201, .value_name = "WEBKIT_PLUGIN_ERROR_CANNOT_LOAD_PLUGIN", .value_nick = "cannot-load-plugin" },
    .{ .value = 202, .value_name = "WEBKIT_PLUGIN_ERROR_JAVA_UNAVAILABLE", .value_nick = "java-unavailable" },
    .{ .value = 203, .value_name = "WEBKIT_PLUGIN_ERROR_CONNECTION_CANCELLED", .value_nick = "connection-cancelled" },
    .{ .value = 204, .value_name = "WEBKIT_PLUGIN_ERROR_WILL_HANDLE_LOAD", .value_nick = "will-handle-load" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

export fn webkit_plugin_error_get_type() c.GType {
    return enumType(&plugin_error_type, "WebKitPluginError", &plugin_error_values);
}

export fn webkit_plugin_error_quark() c.GQuark {
    return c.g_quark_from_static_string("WebKitPluginError");
}

var plugin_type: c.GType = 0;

export fn webkit_plugin_get_type() c.GType {
    return objectType(&plugin_type, "WebKitPlugin", null);
}

export fn webkit_plugin_get_name(_: ?*anyopaque) [*c]const u8 {
    return null;
}

export fn webkit_plugin_get_description(_: ?*anyopaque) [*c]const u8 {
    return null;
}

export fn webkit_plugin_get_path(_: ?*anyopaque) [*c]const u8 {
    return null;
}

export fn webkit_plugin_get_mime_info_list(_: ?*anyopaque) ?*c.GList {
    return null;
}

var mime_type: c.GType = 0;

fn mimeCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return p;
}

fn mimeFree(_: c.gpointer) callconv(.c) void {}

export fn webkit_mime_info_get_type() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&mime_type)) != 0) {
        const t = c.g_boxed_type_register_static("WebKitMimeInfo", mimeCopy, mimeFree);
        c.g_once_init_leave_pointer(@ptrCast(&mime_type), @ptrFromInt(t));
    }
    return mime_type;
}

export fn webkit_mime_info_ref(info: ?*anyopaque) ?*anyopaque {
    return info;
}

export fn webkit_mime_info_unref(_: ?*anyopaque) void {}

export fn webkit_mime_info_get_mime_type(_: ?*anyopaque) [*c]const u8 {
    return null;
}

export fn webkit_mime_info_get_description(_: ?*anyopaque) [*c]const u8 {
    return null;
}

export fn webkit_mime_info_get_extensions(_: ?*anyopaque) [*c]const [*c]const u8 {
    return null;
}

export fn webkit_web_context_get_plugins(ctx: ?*c.WebKitWebContext, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    const task = c.g_task_new(ctx, cancellable, cb, data);
    defer c.g_object_unref(task);
    c.g_task_return_pointer(task, null, null);
}

export fn webkit_web_context_get_plugins_finish(_: ?*c.WebKitWebContext, res: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*c.GList {
    return @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(@alignCast(res)), err)));
}

export fn webkit_web_context_get_favicon_database(ctx: ?*c.WebKitWebContext) ?*c.WebKitFaviconDatabase {
    const m = legacy.webkit_web_context_get_website_data_manager(ctx);
    return c.webkit_website_data_manager_get_favicon_database(m);
}

var install_type: c.GType = 0;

fn permissionInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

export fn webkit_install_missing_media_plugins_permission_request_get_type() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&install_type)) != 0) {
        const t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, "WebKitInstallMissingMediaPluginsPermissionRequest", @sizeOf(c.GObjectClass), null, @sizeOf(c.GObject) + @sizeOf(usize), null, c.G_TYPE_FLAG_FINAL);
        const info = c.GInterfaceInfo{ .interface_init = permissionInit, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(t, c.webkit_permission_request_get_type(), &info);
        c.g_once_init_leave_pointer(@ptrCast(&install_type), @ptrFromInt(t));
    }
    return install_type;
}

export fn webkit_install_missing_media_plugins_permission_request_get_description(_: ?*anyopaque) [*c]const u8 {
    return null;
}

fn actionOf(d: ?*c.WebKitNavigationPolicyDecision) ?*c.WebKitNavigationAction {
    return c.webkit_navigation_policy_decision_get_navigation_action(d);
}

export fn webkit_navigation_policy_decision_get_frame_name(d: ?*c.WebKitNavigationPolicyDecision) [*c]const u8 {
    return c.webkit_navigation_action_get_frame_name(actionOf(d));
}

export fn webkit_navigation_policy_decision_get_modifiers(d: ?*c.WebKitNavigationPolicyDecision) c.guint {
    return view.gdkModifiers(c.webkit_navigation_action_get_modifiers(actionOf(d)));
}

export fn webkit_navigation_policy_decision_get_mouse_button(d: ?*c.WebKitNavigationPolicyDecision) c.guint {
    return c.webkit_navigation_action_get_mouse_button(actionOf(d));
}

export fn webkit_navigation_policy_decision_get_navigation_type(d: ?*c.WebKitNavigationPolicyDecision) c.WebKitNavigationType {
    return c.webkit_navigation_action_get_navigation_type(actionOf(d));
}

export fn webkit_navigation_policy_decision_get_request(d: ?*c.WebKitNavigationPolicyDecision) ?*c.WebKitURIRequest {
    return c.webkit_navigation_action_get_request(actionOf(d));
}

const FIELDS = "fotone-legacy-text-fields";

export fn webkit_form_submission_request_get_text_fields(r: ?*c.WebKitFormSubmissionRequest) ?*c.GHashTable {
    const o: *c.GObject = @ptrCast(@alignCast(r orelse return null));
    if (c.g_object_get_data(o, FIELDS)) |t| return @ptrCast(@alignCast(t));
    var names: ?*c.GPtrArray = null;
    var values: ?*c.GPtrArray = null;
    if (c.webkit_form_submission_request_list_text_fields(r, &names, &values) == 0) return null;
    const table = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, c.g_free);
    var i: c.guint = 0;
    while (i < names.?.len) : (i += 1) _ = c.g_hash_table_insert(table, c.g_strdup(@ptrCast(names.?.pdata[i])), c.g_strdup(@ptrCast(values.?.pdata[i])));
    c.g_object_set_data_full(o, FIELDS, table, @ptrCast(&c.g_hash_table_unref));
    return table;
}

const Legacy = enum { accelerated_2d_canvas, frame_flattening, java, plugins, private_browsing, xss_auditor };

fn legacyKey(comptime l: Legacy) [:0]const u8 {
    return "fotone-legacy-" ++ @tagName(l);
}

fn legacyGet(comptime l: Legacy) fn (?*c.GObject) callconv(.c) c.gboolean {
    return struct {
        fn f(s: ?*c.GObject) callconv(.c) c.gboolean {
            return @intFromBool(c.g_object_get_data(s, legacyKey(l)) != null);
        }
    }.f;
}

fn legacySet(comptime l: Legacy) fn (?*c.GObject, c.gboolean) callconv(.c) void {
    return struct {
        fn f(s: ?*c.GObject, on: c.gboolean) callconv(.c) void {
            c.g_object_set_data(s, legacyKey(l), if (on != 0) @ptrFromInt(1) else null);
        }
    }.f;
}

comptime {
    for (std.enums.values(Legacy)) |l| {
        @export(&legacyGet(l), .{ .name = "webkit_settings_get_enable_" ++ @tagName(l) });
        @export(&legacySet(l), .{ .name = "webkit_settings_set_enable_" ++ @tagName(l) });
    }
}

export fn webkit_security_origin_is_opaque(_: ?*anyopaque) c.gboolean {
    return 0;
}

export fn webkit_user_content_manager_register_script_message_handler(m: ?*c.WebKitUserContentManager, name: [*c]const u8) c.gboolean {
    return view.engineFn("webkit_user_content_manager_register_script_message_handler")(m, name, null);
}

export fn webkit_user_content_manager_unregister_script_message_handler(m: ?*c.WebKitUserContentManager, name: [*c]const u8) void {
    view.engineFn("webkit_user_content_manager_unregister_script_message_handler")(m, name, null);
}

export fn webkit_user_content_manager_register_script_message_handler_in_world(m: ?*c.WebKitUserContentManager, name: [*c]const u8, world: [*c]const u8) c.gboolean {
    return view.engineFn("webkit_user_content_manager_register_script_message_handler")(m, name, world);
}

export fn webkit_user_content_manager_unregister_script_message_handler_in_world(m: ?*c.WebKitUserContentManager, name: [*c]const u8, world: [*c]const u8) void {
    view.engineFn("webkit_user_content_manager_unregister_script_message_handler")(m, name, world);
}

export fn webkit_input_method_context_filter_key_event(_: ?*anyopaque, _: ?*c.GdkEventKey) c.gboolean {
    return 0;
}

fn activateGtk(_: ?*c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    c.gtk_action_activate(@ptrCast(@alignCast(data)));
}

const ACTION_KEY = "fotone-legacy-gtk-action";

export fn webkit_context_menu_item_new(action: ?*c.GtkAction) ?*c.WebKitContextMenuItem {
    const a = action orelse return null;
    const g = c.g_simple_action_new(c.gtk_action_get_name(a), null);
    defer c.g_object_unref(g);
    _ = c.g_signal_connect_data(g, "activate", @ptrCast(&activateGtk), c.g_object_ref(a), @ptrCast(&c.g_object_unref), 0);
    const item = c.webkit_context_menu_item_new_from_gaction(@ptrCast(g), c.gtk_action_get_label(a), null);
    c.g_object_set_data_full(@ptrCast(@alignCast(item)), ACTION_KEY, c.g_object_ref(a), c.g_object_unref);
    return item;
}

export fn webkit_context_menu_item_get_action(item: ?*c.WebKitContextMenuItem) ?*c.GtkAction {
    return @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(item orelse return null)), ACTION_KEY)));
}

var custom_type: c.GType = 0;
var custom_apply: c.guint = 0;
var custom_update: c.guint = 0;

const Custom = extern struct {
    parent: c.GObject,
    widget: ?*c.GtkWidget,
    title: [*c]u8,
};

fn customFinalize(o: [*c]c.GObject) callconv(.c) void {
    const w: *Custom = @ptrCast(@alignCast(o));
    if (w.widget) |x| c.g_object_unref(x);
    c.g_free(w.title);
    const parent: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(c.G_TYPE_OBJECT)));
    parent.finalize.?(o);
}

const CUSTOM_WIDGET = 1;
const CUSTOM_TITLE = 2;

fn customSet(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const w: *Custom = @ptrCast(@alignCast(o));
    switch (id) {
        CUSTOM_WIDGET => if (c.g_value_get_object(value)) |x| {
            w.widget = @ptrCast(@alignCast(c.g_object_ref_sink(x)));
        },
        CUSTOM_TITLE => w.title = c.g_value_dup_string(value),
        else => {},
    }
}

fn customGet(o: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const w: *Custom = @ptrCast(@alignCast(o));
    switch (id) {
        CUSTOM_WIDGET => c.g_value_set_object(value, w.widget),
        CUSTOM_TITLE => c.g_value_set_string(value, w.title),
        else => {},
    }
}

fn customClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    oc.finalize = customFinalize;
    oc.set_property = customSet;
    oc.get_property = customGet;
    const flags = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, CUSTOM_WIDGET, c.g_param_spec_object("widget", null, null, c.gtk_widget_get_type(), flags));
    c.g_object_class_install_property(oc, CUSTOM_TITLE, c.g_param_spec_string("title", null, null, null, flags));
    const t = c.G_TYPE_FROM_CLASS(klass);
    custom_apply = c.g_signal_new("apply", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 0);
    custom_update = c.g_signal_new("update", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 2, c.gtk_page_setup_get_type(), c.gtk_print_settings_get_type());
}

pub export fn webkit_print_custom_widget_get_type() c.GType {
    if (c.g_once_init_enter_pointer(@ptrCast(&custom_type)) != 0) {
        const t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, "WebKitPrintCustomWidget", @sizeOf(c.GObjectClass), customClassInit, @sizeOf(Custom), null, 0);
        c.g_once_init_leave_pointer(@ptrCast(&custom_type), @ptrFromInt(t));
    }
    return custom_type;
}

export fn webkit_print_custom_widget_new(widget: ?*c.GtkWidget, title: [*c]const u8) ?*Custom {
    return @ptrCast(@alignCast(c.g_object_new(webkit_print_custom_widget_get_type(), "widget", widget, "title", title, @as([*c]const u8, null))));
}

export fn webkit_print_custom_widget_get_widget(w: *Custom) ?*c.GtkWidget {
    return w.widget;
}

export fn webkit_print_custom_widget_get_title(w: *Custom) [*c]const u8 {
    return w.title;
}

export fn webkit_web_view_get_inspector(v: ?*c.GObject) ?*c.GObject {
    return extra.inspectorFor(v);
}

export fn webkit_frame_get_javascript_global_context(_: ?*anyopaque) ?*anyopaque {
    return null;
}

export fn webkit_frame_get_javascript_context_for_script_world(_: ?*anyopaque, _: ?*anyopaque) ?*anyopaque {
    return null;
}

export fn webkit_frame_get_js_value_for_dom_object(_: ?*anyopaque, _: ?*anyopaque) ?*c.JSCValue {
    return null;
}

export fn webkit_frame_get_js_value_for_dom_object_in_script_world(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) ?*c.JSCValue {
    return null;
}

export fn webkit_web_hit_test_result_get_node(_: ?*anyopaque) ?*anyopaque {
    return null;
}

export fn webkit_web_page_get_dom_document(_: ?*anyopaque) ?*anyopaque {
    return null;
}

export fn webkit_web_extension_get_page(ext: ?*anyopaque, id: u64) ?*anyopaque {
    return engine.lookup("webkit_web_process_extension_get_page", fn (?*anyopaque, u64) callconv(.c) ?*anyopaque)(ext, id);
}

export fn webkit_web_extension_send_message_to_context(ext: ?*anyopaque, msg: ?*anyopaque, cancellable: ?*c.GCancellable, cb: c.GAsyncReadyCallback, data: c.gpointer) void {
    engine.lookup("webkit_web_process_extension_send_message_to_context", fn (?*anyopaque, ?*anyopaque, ?*c.GCancellable, c.GAsyncReadyCallback, c.gpointer) callconv(.c) void)(ext, msg, cancellable, cb, data);
}

export fn webkit_web_extension_send_message_to_context_finish(ext: ?*anyopaque, res: ?*c.GAsyncResult, err: [*c][*c]c.GError) ?*anyopaque {
    return engine.lookup("webkit_web_process_extension_send_message_to_context_finish", fn (?*anyopaque, ?*c.GAsyncResult, [*c][*c]c.GError) callconv(.c) ?*anyopaque)(ext, res, err);
}

const Accessors = struct {
    get: ?*const fn ([*c]c.GObject, c.guint, [*c]c.GValue, [*c]c.GParamSpec) callconv(.c) void = null,
    set: ?*const fn ([*c]c.GObject, c.guint, [*c]const c.GValue, [*c]c.GParamSpec) callconv(.c) void = null,
};

const FIRST_SETTING = 0x4100;
const FIRST_DECISION = 0x4200;
const FIRST_CONTEXT = 0x4300;

const decision_props = [_][:0]const u8{ "frame-name", "modifiers", "mouse-button", "navigation-type", "request" };
const context_props = [_][:0]const u8{ "website-data-manager", "local-storage-directory", "process-swap-on-cross-site-navigation-enabled", "use-system-appearance-for-scrollbars" };

var settings_base: Accessors = .{};
var decision_base: Accessors = .{};
var context_base: Accessors = .{};

fn baseOf(id: c.guint) *Accessors {
    if (id >= FIRST_CONTEXT) return &context_base;
    if (id >= FIRST_DECISION) return &decision_base;
    return &settings_base;
}

fn settingIndex(id: c.guint) ?Legacy {
    if (id < FIRST_SETTING or id >= FIRST_SETTING + std.enums.values(Legacy).len) return null;
    return std.enums.values(Legacy)[id - FIRST_SETTING];
}

fn settingGet(l: Legacy, o: ?*c.GObject) c.gboolean {
    return switch (l) {
        inline else => |t| legacyGet(t)(o),
    };
}

fn settingSet(l: Legacy, o: ?*c.GObject, on: c.gboolean) void {
    switch (l) {
        inline else => |t| legacySet(t)(o, on),
    }
}

fn decisionGet(id: c.guint, o: [*c]c.GObject, value: [*c]c.GValue) void {
    const d: ?*c.WebKitNavigationPolicyDecision = @ptrCast(@alignCast(o));
    switch (id - FIRST_DECISION) {
        0 => c.g_value_set_string(value, webkit_navigation_policy_decision_get_frame_name(d)),
        1 => c.g_value_set_uint(value, webkit_navigation_policy_decision_get_modifiers(d)),
        2 => c.g_value_set_uint(value, webkit_navigation_policy_decision_get_mouse_button(d)),
        3 => c.g_value_set_enum(value, @intCast(webkit_navigation_policy_decision_get_navigation_type(d))),
        else => c.g_value_set_object(value, webkit_navigation_policy_decision_get_request(d)),
    }
}

fn contextGet(id: c.guint, o: [*c]c.GObject, value: [*c]c.GValue) void {
    const ctx: ?*c.WebKitWebContext = @ptrCast(@alignCast(o));
    switch (id - FIRST_CONTEXT) {
        0 => c.g_value_set_object(value, legacy.webkit_web_context_get_website_data_manager(ctx)),
        1 => c.g_value_set_string(value, legacy.localStorageDirectory(legacy.webkit_web_context_get_website_data_manager(ctx))),
        2 => c.g_value_set_boolean(value, 1),
        else => c.g_value_set_boolean(value, legacy.webkit_web_context_get_use_system_appearance_for_scrollbars(ctx)),
    }
}

fn contextSet(id: c.guint, o: [*c]c.GObject, value: [*c]const c.GValue) void {
    const ctx: ?*c.WebKitWebContext = @ptrCast(@alignCast(o));
    switch (id - FIRST_CONTEXT) {
        0 => if (c.g_value_get_object(value)) |m| legacy.bindManager(ctx, @ptrCast(@alignCast(m))),
        3 => legacy.webkit_web_context_set_use_system_appearance_for_scrollbars(ctx, c.g_value_get_boolean(value)),
        else => {},
    }
}

fn extraGet(o: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (settingIndex(id)) |l| return c.g_value_set_boolean(value, settingGet(l, o));
    if (id >= FIRST_CONTEXT and id < FIRST_CONTEXT + context_props.len) return contextGet(id, o, value);
    if (id >= FIRST_DECISION and id < FIRST_DECISION + decision_props.len) return decisionGet(id, o, value);
    if (baseOf(id).get) |f| f(o, id, value, spec);
}

fn extraSet(o: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (settingIndex(id)) |l| return settingSet(l, o, c.g_value_get_boolean(value));
    if (id >= FIRST_CONTEXT and id < FIRST_CONTEXT + context_props.len) return contextSet(id, o, value);
    if (baseOf(id).set) |f| f(o, id, value, spec);
}

fn extend(t: c.GType, base: *Accessors) *c.GObjectClass {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    base.get = @ptrCast(oc.get_property);
    base.set = @ptrCast(oc.set_property);
    oc.get_property = @ptrCast(&extraGet);
    oc.set_property = @ptrCast(&extraSet);
    return oc;
}

const RO = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
const RWC = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS;
const RWO = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS;

var context_download: c.guint = 0;
var context_extensions: c.guint = 0;

fn downloadStarted(hint: ?*c.GSignalInvocationHint, n: c.guint, params: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    _ = hint;
    if (n < 2) return 1;
    const session: ?*c.WebKitNetworkSession = @ptrCast(@alignCast(c.g_value_get_object(&params[0])));
    const download = c.g_value_get_object(&params[1]);
    if (legacy.contextOf(session)) |ctx| c.g_signal_emit(ctx, context_download, 0, download);
    return 1;
}

fn extensionsInitializing(_: ?*c.GSignalInvocationHint, n: c.guint, params: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    if (n < 1) return 1;
    c.g_signal_emit(c.g_value_get_object(&params[0]), context_extensions, 0);
    return 1;
}

pub fn load() void {
    const so = extend(c.webkit_settings_get_type(), &settings_base);
    for (std.enums.values(Legacy), 0..) |l, i| {
        const name = c.g_strdelimit(c.g_strdup_printf("enable-%s", @tagName(l).ptr), "_", '-');
        c.g_object_class_install_property(so, @intCast(FIRST_SETTING + i), c.g_param_spec_boolean(c.g_intern_string(name), null, null, 0, RWC));
        c.g_free(name);
    }
    const dt = c.webkit_navigation_policy_decision_get_type();
    const doc = extend(dt, &decision_base);
    const decision_specs = [_]*c.GParamSpec{
        c.g_param_spec_string(decision_props[0], null, null, null, RO),
        c.g_param_spec_uint(decision_props[1], null, null, 0, std.math.maxInt(c.guint), 0, RO),
        c.g_param_spec_uint(decision_props[2], null, null, 0, std.math.maxInt(c.guint), 0, RO),
        c.g_param_spec_enum(decision_props[3], null, null, c.webkit_navigation_type_get_type(), c.WEBKIT_NAVIGATION_TYPE_OTHER, RO),
        c.g_param_spec_object(decision_props[4], null, null, c.webkit_uri_request_get_type(), RO),
    };
    for (decision_specs, 0..) |spec, i| c.g_object_class_install_property(doc, @intCast(FIRST_DECISION + i), spec);
    const ct = c.webkit_web_context_get_type();
    const coc = extend(ct, &context_base);
    const context_specs = [_]*c.GParamSpec{
        c.g_param_spec_object(context_props[0], null, null, c.webkit_website_data_manager_get_type(), RWO),
        c.g_param_spec_string(context_props[1], null, null, null, RWO),
        c.g_param_spec_boolean(context_props[2], null, null, 0, RWO),
        c.g_param_spec_boolean(context_props[3], null, null, 1, RWC),
    };
    for (context_specs, 0..) |spec, i| c.g_object_class_install_property(coc, @intCast(FIRST_CONTEXT + i), spec);
    context_download = c.g_signal_new("download-started", ct, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 1, c.webkit_download_get_type());
    context_extensions = c.g_signal_new("initialize-web-extensions", ct, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 0);
    c.g_type_class_unref(c.g_type_class_ref(c.webkit_network_session_get_type()));
    _ = c.g_signal_add_emission_hook(c.g_signal_lookup("download-started", c.webkit_network_session_get_type()), 0, downloadStarted, null, null);
    _ = c.g_signal_add_emission_hook(c.g_signal_lookup("initialize-web-process-extensions", ct), 0, extensionsInitializing, null, null);
}

test "legacy enums register with their GTK values" {
    const k: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(webkit_process_model_get_type())));
    defer c.g_type_class_unref(k);
    try std.testing.expectEqual(@as(c_int, 1), c.g_enum_get_value_by_nick(k, "multiple-secondary-processes").*.value);
    try std.testing.expect(webkit_plugin_error_quark() != 0);
}
