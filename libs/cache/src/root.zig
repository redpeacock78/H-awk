// SPDX-License-Identifier: MIT
// libs/cache/src/root.zig -- gawk extension entry point

const std = @import("std");
const ffi = @import("gawk_ffi");
const cache = @import("cache");

var _inited = false;
var _stats_buf: [256]u8 = undefined;

fn ensureInit() void {
    if (!_inited) { cache.init(); _inited = true; }
}

fn cacheGet(args: ffi.Args) ffi.Result {
    ensureInit();
    const key = args.getString(0);
    const v = cache.get(key) orelse return .{ .string = "" };
    return .{ .string = v };
}

fn cacheSet(args: ffi.Args) ffi.Result {
    ensureInit();
    const key    = args.getString(0);
    const val    = args.getString(1);
    const ttl_arg = args.getDouble(2);
    if (!std.math.isFinite(ttl_arg)) return .{ .string = "0" };
    if (ttl_arg < @as(f64, @floatFromInt(std.math.minInt(i64))) or
        ttl_arg > @as(f64, @floatFromInt(std.math.maxInt(i64))))
    {
        return .{ .string = "0" };
    }
    const ttl_ms: i64 = @intFromFloat(ttl_arg);
    cache.set(key, val, ttl_ms) catch return .{ .string = "0" };
    return .{ .string = "1" };
}

fn cacheDel(args: ffi.Args) ffi.Result {
    ensureInit();
    cache.del(args.getString(0));
    return .{ .string = "1" };
}

fn cacheHas(args: ffi.Args) ffi.Result {
    ensureInit();
    return .{ .int = if (cache.has(args.getString(0))) 1 else 0 };
}

fn cacheStats(_: ffi.Args) ffi.Result {
    const s = std.fmt.bufPrint(&_stats_buf, "shared={d} size={d} slots={d} key_max={d} val_max={d}", .{
        @intFromBool(cache.isShared()),
        cache.getCacheSize(),
        cache.slotCount(),
        cache.KEY_MAX,
        cache.VAL_MAX,
    }) catch return .{ .string = "" };
    return .{ .string = s };
}

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_cache",
    .functions = &.{
        .{ .name = "hawk_cache_get",   .impl = &cacheGet,   .args = 1 },
        .{ .name = "hawk_cache_set",   .impl = &cacheSet,   .args = 3 },
        .{ .name = "hawk_cache_del",   .impl = &cacheDel,   .args = 1 },
        .{ .name = "hawk_cache_has",   .impl = &cacheHas,   .args = 1 },
        .{ .name = "hawk_cache_stats", .impl = &cacheStats, .args = 0 },
    },
});
comptime { _ = _ffi_entry; }
