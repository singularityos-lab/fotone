const c = @import("c.zig").c;

pub const Once = struct {
    t: c.GType = 0,

    pub fn get(self: *Once, comptime make: fn () c.GType) c.GType {
        if (c.g_once_init_enter_pointer(@ptrCast(&self.t)) != 0) {
            c.g_once_init_leave_pointer(@ptrCast(&self.t), @ptrFromInt(make()));
        }
        return self.t;
    }
};

pub fn register(parent: c.GType, name: [*:0]const u8, comptime Class: type, comptime Instance: type, class_init: c.GClassInitFunc, instance_init: c.GInstanceInitFunc) c.GType {
    return c.g_type_register_static_simple(parent, c.g_intern_static_string(name), @sizeOf(Class), class_init, @sizeOf(Instance), instance_init, 0);
}

pub fn objectClass(klass: anytype) *c.GObjectClass {
    return @ptrCast(@alignCast(klass));
}

pub fn unrefPtr(p: anytype) void {
    if (p.*) |o| c.g_object_unref(o);
    p.* = null;
}
