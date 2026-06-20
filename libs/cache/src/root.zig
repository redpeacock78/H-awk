// SPDX-License-Identifier: MIT
// libs/cache/src/root.zig -- gawk extension entry point

const std = @import("std");
const ffi = @import("gawk_ffi");
const cache = @import("cache");

var _inited = false;

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
    const ttl_ms = args.getInt(2);
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
    return .{ .string = if (cache.has(args.getString(0))) "1" else "0" };
}

fn cacheStats(_: ffi.Args) ffi.Result {
    return .{ .string = "slots=" ++ std.fmt.comptimePrint("{d}", .{cache.SLOT_COUNT}) };
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
