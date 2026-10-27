const std = @import("std");
const h3 = @import("h3.zig");
const c = h3.c;

const TTL_NS = 60 * std.time.ns_per_s;
const MAX_ENTRIES = 512;
const DISABLE_ENV = "FOTONE_DNS_CACHE";

const gpa = std.heap.c_allocator;

const Entry = struct { addresses: ?*c.GList, expires: u64 };

var mutex: c.GMutex = std.mem.zeroes(c.GMutex);
var cache: std.StringHashMapUnmanaged(Entry) = .empty;
var installed = false;

const Resolver = extern struct {
    parent: c.GResolver,
    inner: ?*c.GResolver,
};

const Pending = struct {
    task: ?*c.GTask,
    host: [*c]u8,
    flags: c.GResolverNameLookupFlags,
};

fn copyAddresses(list: ?*c.GList) ?*c.GList {
    return c.g_list_copy_deep(list, @ptrCast(&c.g_object_ref), null);
}

fn freeAddresses(list: ?*anyopaque) callconv(.c) void {
    c.g_resolver_free_addresses(@ptrCast(@alignCast(list)));
}

fn makeKey(host: [*c]const u8, flags: c.GResolverNameLookupFlags) ?[]u8 {
    return std.fmt.allocPrint(gpa, "{s}\x00{d}", .{ std.mem.span(host), flags }) catch null;
}

fn lookup(key: []const u8) ?*c.GList {
    c.g_mutex_lock(&mutex);
    defer c.g_mutex_unlock(&mutex);
    const e = cache.get(key) orelse return null;
    if (h3.now() >= e.expires) return null;
    return copyAddresses(e.addresses);
}

fn clearLocked() void {
    var it = cache.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        c.g_resolver_free_addresses(kv.value_ptr.addresses);
    }
    cache.clearRetainingCapacity();
}

pub fn clear() void {
    c.g_mutex_lock(&mutex);
    defer c.g_mutex_unlock(&mutex);
    clearLocked();
}

fn storeLocked(key: []const u8, list: ?*c.GList, expires: u64) void {
    if (list == null) return;
    const entry: Entry = .{ .addresses = copyAddresses(list), .expires = expires };
    if (cache.getPtr(key)) |old| {
        c.g_resolver_free_addresses(old.addresses);
        old.* = entry;
        return;
    }
    const owned = gpa.dupe(u8, key) catch {
        c.g_resolver_free_addresses(entry.addresses);
        return;
    };
    cache.put(gpa, owned, entry) catch {
        gpa.free(owned);
        c.g_resolver_free_addresses(entry.addresses);
    };
}

fn onlyFamily(list: ?*c.GList, family: c.GSocketFamily) ?*c.GList {
    var out: ?*c.GList = null;
    var it = list;
    while (it) |node| : (it = node.next) {
        const addr: *c.GInetAddress = @ptrCast(@alignCast(node.data));
        if (c.g_inet_address_get_family(addr) == family) out = c.g_list_prepend(out, addr);
    }
    return c.g_list_reverse(out);
}

fn remember(host: [*c]const u8, flags: c.GResolverNameLookupFlags, list: ?*c.GList) void {
    if (list == null) return;
    const key = makeKey(host, flags) orelse return;
    defer gpa.free(key);
    c.g_mutex_lock(&mutex);
    defer c.g_mutex_unlock(&mutex);
    if (cache.count() + 3 > MAX_ENTRIES) clearLocked();
    const expires = h3.now() + TTL_NS;
    storeLocked(key, list, expires);
    if (flags != c.G_RESOLVER_NAME_LOOKUP_FLAGS_DEFAULT) return;
    const split = [_]struct { c.GResolverNameLookupFlags, c.GSocketFamily }{
        .{ c.G_RESOLVER_NAME_LOOKUP_FLAGS_IPV4_ONLY, c.G_SOCKET_FAMILY_IPV4 },
        .{ c.G_RESOLVER_NAME_LOOKUP_FLAGS_IPV6_ONLY, c.G_SOCKET_FAMILY_IPV6 },
    };
    for (split) |s| {
        const part = onlyFamily(list, s[1]);
        defer c.g_list_free(part);
        const k = makeKey(host, s[0]) orelse continue;
        defer gpa.free(k);
        storeLocked(k, part, expires);
    }
}

fn innerOf(resolver: ?*c.GResolver) ?*c.GResolver {
    const self: *Resolver = @ptrCast(@alignCast(resolver));
    return self.inner;
}

fn byNameWithFlags(resolver: ?*c.GResolver, host: [*c]const u8, flags: c.GResolverNameLookupFlags, cancellable: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    const key = makeKey(host, flags) orelse return c.g_resolver_lookup_by_name_with_flags(innerOf(resolver), host, flags, cancellable, err);
    defer gpa.free(key);
    if (lookup(key)) |hit| return hit;
    const list = c.g_resolver_lookup_by_name_with_flags(innerOf(resolver), host, flags, cancellable, err);
    remember(host, flags, list);
    return list;
}

fn byName(resolver: ?*c.GResolver, host: [*c]const u8, cancellable: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    return byNameWithFlags(resolver, host, c.G_RESOLVER_NAME_LOOKUP_FLAGS_DEFAULT, cancellable, err);
}

fn resolved(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(data));
    defer {
        c.g_free(p.host);
        gpa.destroy(p);
    }
    var err: [*c]c.GError = null;
    const list = c.g_resolver_lookup_by_name_with_flags_finish(@ptrCast(source), result, &err);
    if (err != null) {
        c.g_task_return_error(p.task, err);
    } else {
        remember(p.host, p.flags, list);
        c.g_task_return_pointer(p.task, list, freeAddresses);
    }
    c.g_object_unref(p.task);
}

fn byNameWithFlagsAsync(resolver: ?*c.GResolver, host: [*c]const u8, flags: c.GResolverNameLookupFlags, cancellable: ?*c.GCancellable, callback: c.GAsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    const task = c.g_task_new(resolver, cancellable, callback, data);
    const key = makeKey(host, flags) orelse {
        c.g_task_return_new_error(task, c.g_io_error_quark(), c.G_IO_ERROR_FAILED, "out of memory");
        c.g_object_unref(task);
        return;
    };
    defer gpa.free(key);
    if (lookup(key)) |hit| {
        c.g_task_return_pointer(task, hit, freeAddresses);
        c.g_object_unref(task);
        return;
    }
    const p = gpa.create(Pending) catch {
        c.g_task_return_new_error(task, c.g_io_error_quark(), c.G_IO_ERROR_FAILED, "out of memory");
        c.g_object_unref(task);
        return;
    };
    p.* = .{ .task = task, .host = c.g_strdup(host), .flags = flags };
    c.g_resolver_lookup_by_name_with_flags_async(innerOf(resolver), host, flags, cancellable, resolved, p);
}

fn byNameAsync(resolver: ?*c.GResolver, host: [*c]const u8, cancellable: ?*c.GCancellable, callback: c.GAsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    byNameWithFlagsAsync(resolver, host, c.G_RESOLVER_NAME_LOOKUP_FLAGS_DEFAULT, cancellable, callback, data);
}

fn byNameFinish(_: ?*c.GResolver, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    return @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(result), err)));
}

fn byAddress(resolver: ?*c.GResolver, address: ?*c.GInetAddress, cancellable: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) [*c]c.gchar {
    return c.g_resolver_lookup_by_address(innerOf(resolver), address, cancellable, err);
}

fn byAddressAsync(resolver: ?*c.GResolver, address: ?*c.GInetAddress, cancellable: ?*c.GCancellable, callback: c.GAsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    c.g_resolver_lookup_by_address_async(innerOf(resolver), address, cancellable, callback, data);
}

fn byAddressFinish(resolver: ?*c.GResolver, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) callconv(.c) [*c]c.gchar {
    return c.g_resolver_lookup_by_address_finish(innerOf(resolver), result, err);
}

fn classOf(resolver: ?*c.GResolver) *c.GResolverClass {
    const instance: *c.GTypeInstance = @ptrCast(@alignCast(resolver));
    return @ptrCast(@alignCast(instance.g_class));
}

fn service(resolver: ?*c.GResolver, rrname: [*c]const u8, cancellable: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    const inner = innerOf(resolver);
    return classOf(inner).lookup_service.?(inner, rrname, cancellable, err);
}

fn serviceAsync(resolver: ?*c.GResolver, rrname: [*c]const u8, cancellable: ?*c.GCancellable, callback: c.GAsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    const inner = innerOf(resolver);
    classOf(inner).lookup_service_async.?(inner, rrname, cancellable, callback, data);
}

fn serviceFinish(resolver: ?*c.GResolver, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    return c.g_resolver_lookup_service_finish(innerOf(resolver), result, err);
}

fn records(resolver: ?*c.GResolver, rrname: [*c]const u8, kind: c.GResolverRecordType, cancellable: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    return c.g_resolver_lookup_records(innerOf(resolver), rrname, kind, cancellable, err);
}

fn recordsAsync(resolver: ?*c.GResolver, rrname: [*c]const u8, kind: c.GResolverRecordType, cancellable: ?*c.GCancellable, callback: c.GAsyncReadyCallback, data: ?*anyopaque) callconv(.c) void {
    c.g_resolver_lookup_records_async(innerOf(resolver), rrname, kind, cancellable, callback, data);
}

fn recordsFinish(resolver: ?*c.GResolver, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
    return c.g_resolver_lookup_records_finish(innerOf(resolver), result, err);
}

fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const k: *c.GResolverClass = @ptrCast(@alignCast(klass));
    k.lookup_by_name = byName;
    k.lookup_by_name_async = byNameAsync;
    k.lookup_by_name_finish = byNameFinish;
    k.lookup_by_name_with_flags = byNameWithFlags;
    k.lookup_by_name_with_flags_async = byNameWithFlagsAsync;
    k.lookup_by_name_with_flags_finish = byNameFinish;
    k.lookup_by_address = byAddress;
    k.lookup_by_address_async = byAddressAsync;
    k.lookup_by_address_finish = byAddressFinish;
    k.lookup_service = service;
    k.lookup_service_async = serviceAsync;
    k.lookup_service_finish = serviceFinish;
    k.lookup_records = records;
    k.lookup_records_async = recordsAsync;
    k.lookup_records_finish = recordsFinish;
}

var resolver_type: c.GType = 0;

fn resolverType() c.GType {
    c.g_mutex_lock(&mutex);
    defer c.g_mutex_unlock(&mutex);
    if (resolver_type == 0)
        resolver_type = c.g_type_register_static_simple(c.g_resolver_get_type(), "FotoneResolver", @sizeOf(c.GResolverClass), classInit, @sizeOf(Resolver), null, 0);
    return resolver_type;
}

fn networkChanged(_: ?*c.GNetworkMonitor, _: c.gboolean, _: ?*anyopaque) callconv(.c) void {
    clear();
}

pub fn wrap(inner: *c.GResolver) *c.GResolver {
    const r: *Resolver = @ptrCast(@alignCast(c.g_object_new(resolverType(), null)));
    r.inner = @ptrCast(@alignCast(c.g_object_ref(inner)));
    return @ptrCast(r);
}

pub export fn fotone_dns_install() void {
    if (installed) return;
    installed = true;
    if (std.c.getenv(DISABLE_ENV)) |v| if (std.mem.eql(u8, std.mem.span(v), "0")) return;
    const inner = c.g_resolver_get_default();
    defer c.g_object_unref(inner);
    const r = wrap(inner);
    c.g_resolver_set_default(r);
    c.g_object_unref(r);
    _ = c.g_signal_connect_data(c.g_network_monitor_get_default(), "network-changed", @ptrCast(&networkChanged), null, null, 0);
}

const Counting = struct {
    var calls: usize = 0;

    fn byName(_: ?*c.GResolver, host: [*c]const u8, _: c.GResolverNameLookupFlags, _: ?*c.GCancellable, _: [*c][*c]c.GError) callconv(.c) ?*c.GList {
        calls += 1;
        const addr = c.g_inet_address_new_from_string(if (std.mem.eql(u8, std.mem.span(host), "two.test")) "192.0.2.2" else "192.0.2.1");
        return c.g_list_append(null, addr);
    }

    fn byNameDefault(r: ?*c.GResolver, host: [*c]const u8, cancellable: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) ?*c.GList {
        return Counting.byName(r, host, c.G_RESOLVER_NAME_LOOKUP_FLAGS_DEFAULT, cancellable, err);
    }

    fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const k: *c.GResolverClass = @ptrCast(@alignCast(klass));
        k.lookup_by_name = Counting.byNameDefault;
        k.lookup_by_name_with_flags = Counting.byName;
    }

    fn create() *c.GResolver {
        const t = c.g_type_register_static_simple(c.g_resolver_get_type(), "FotoneCountingResolver", @sizeOf(c.GResolverClass), Counting.classInit, @sizeOf(c.GResolver), null, 0);
        return @ptrCast(@alignCast(c.g_object_new(t, null)));
    }
};

fn expectFirst(expected: []const u8, list: ?*c.GList) !void {
    const addr: *c.GInetAddress = @ptrCast(@alignCast(list.?.*.data));
    const text = c.g_inet_address_to_string(addr);
    defer c.g_free(text);
    try std.testing.expectEqualStrings(expected, std.mem.span(text));
}

test "names resolve once per ttl and clear on network change" {
    const inner = Counting.create();
    defer c.g_object_unref(inner);
    const r = wrap(inner);
    defer c.g_object_unref(r);
    var err: [*c]c.GError = null;
    const a = c.g_resolver_lookup_by_name(r, "one.test", null, &err);
    defer c.g_resolver_free_addresses(a);
    const b = c.g_resolver_lookup_by_name(r, "one.test", null, &err);
    defer c.g_resolver_free_addresses(b);
    const d = c.g_resolver_lookup_by_name(r, "two.test", null, &err);
    defer c.g_resolver_free_addresses(d);
    try std.testing.expectEqual(@as(usize, 2), Counting.calls);
    try expectFirst("192.0.2.1", b);
    try expectFirst("192.0.2.2", d);
    clear();
    const e = c.g_resolver_lookup_by_name(r, "one.test", null, &err);
    defer c.g_resolver_free_addresses(e);
    try std.testing.expectEqual(@as(usize, 3), Counting.calls);
    const v4 = c.g_resolver_lookup_by_name_with_flags(r, "one.test", c.G_RESOLVER_NAME_LOOKUP_FLAGS_IPV4_ONLY, null, &err);
    defer c.g_resolver_free_addresses(v4);
    try expectFirst("192.0.2.1", v4);
    try std.testing.expectEqual(@as(usize, 3), Counting.calls);
    const v6 = c.g_resolver_lookup_by_name_with_flags(r, "one.test", c.G_RESOLVER_NAME_LOOKUP_FLAGS_IPV6_ONLY, null, &err);
    defer c.g_resolver_free_addresses(v6);
    try std.testing.expectEqual(@as(usize, 4), Counting.calls);
}
