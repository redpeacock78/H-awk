// SPDX-License-Identifier: MIT
const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stddef.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("gawkapi.h");
});

// Initialized in dl_load; gawk guarantees single-threaded, no calls before dl_load succeeds.
var _api: *const c.gawk_api_t = undefined;
var _ext_id: c.awk_ext_id_t = undefined;

pub const Args = struct {
    _argc: c_int,

    /// Get argument i as a string slice. Returns "" on index out of range or type mismatch.
    pub fn getString(self: Args, i: usize) []const u8 {
        if (i >= @as(usize, @intCast(self._argc))) return "";
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_STRING, &v) == c.awk_false) return "";
        return v.u.s.str[0..v.u.s.len];
    }

    /// Get argument i as i64. Returns 0 on index out of range or type mismatch.
    pub fn getInt(self: Args, i: usize) i64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_NUMBER, &v) == c.awk_false) return 0;
        return @intFromFloat(v.u.n.d);
    }

    /// Get argument i as f64. Returns 0.0 on index out of range or type mismatch.
    pub fn getDouble(self: Args, i: usize) f64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0.0;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_NUMBER, &v) == c.awk_false) return 0.0;
        return v.u.n.d;
    }

    /// Get argument i as a gawk array handle. Returns null on index out of range or type mismatch.
    pub fn getArray(self: Args, i: usize) c.awk_array_t {
        if (i >= @as(usize, @intCast(self._argc))) return null;
        var v: c.awk_value_t = undefined;
        if (_api.*.api_get_argument.?(_ext_id, @intCast(i), c.AWK_ARRAY, &v) == c.awk_false) return null;
        return v.u.a;
    }
};

/// Write a string key/value pair into a gawk array.
/// Both key and val must remain valid for the duration of the call;
/// gawk copies them (awk_false = gawk does NOT take ownership of our pointer).
pub fn arraySet(arr: c.awk_array_t, key: []const u8, val: []const u8) void {
    var k: c.awk_value_t = undefined;
    var v: c.awk_value_t = undefined;
    _ = c.r_make_string(_api, _ext_id, key.ptr, key.len, c.awk_false, &k);
    _ = c.r_make_string(_api, _ext_id, val.ptr, val.len, c.awk_false, &v);
    _ = _api.*.api_set_array_element.?(_ext_id, arr, &k, &v);
}

/// Return value from a gawk extension function.
pub const Result = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    none,
};

pub const FuncDef = struct {
    name: []const u8,
    impl: *const fn (Args) Result,
    args: usize,
};

pub const DlLoadConfig = struct {
    name: []const u8,
    functions: []const FuncDef,
};

/// Returns a gawk allocator backed by api_malloc/api_free.
/// Safe to use after dl_load initializes _api/_ext_id.
pub fn gawkAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &gawk_allocator_vtable,
    };
}

const gawk_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = gawkAlloc,
    .resize = gawkResize,
    .remap = gawkRemap,
    .free = gawkFree,
};

fn gawkAlloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const p = _api.*.api_malloc.?(n);
    return if (p != null) @ptrCast(p) else null;
}

fn gawkResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn gawkRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    // gawk has no realloc; signal caller to alloc+copy
    return null;
}

fn gawkFree(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    _api.*.api_free.?(buf.ptr);
}

/// Generate a gawk extension entry point.
/// IMPORTANT: Use in exactly one translation unit per shared library.
/// `dl_load` and `plugin_is_GPL_compatible` are global C symbols;
/// multiple instances in one .so will cause link-time name collision.
///
/// In Zig 0.16+, `usingnamespace` at file scope is not supported.
/// Use the comptime force-emit pattern instead:
///
///   const _ffi_entry = ffi.makeDlLoad(.{ .name = "myplugin", .functions = &.{ ... } });
///   comptime { _ = &_ffi_entry.dl_load; _ = &_ffi_entry.plugin_is_GPL_compatible; }
pub fn makeDlLoad(comptime cfg: DlLoadConfig) type {
    return struct {
        var _funcs: [cfg.functions.len]c.awk_ext_func_t = undefined;

        export var plugin_is_GPL_compatible: c_int = 1;

        export fn dl_load(api_p: [*c]const c.gawk_api_t, id: c.awk_ext_id_t) c_int {
            if (api_p == null) return 0;
            _api = api_p.?;
            _ext_id = id;

            if (_api.*.major_version != c.GAWK_API_MAJOR_VERSION or
                _api.*.minor_version < c.GAWK_API_MINOR_VERSION)
            {
                std.debug.print("{s}: gawk API version mismatch (want {d}.{d}, got {d}.{d})\n", .{
                    cfg.name,
                    c.GAWK_API_MAJOR_VERSION,
                    c.GAWK_API_MINOR_VERSION,
                    _api.*.major_version,
                    _api.*.minor_version,
                });
                return 0;
            }

            inline for (cfg.functions, 0..) |fdef, i| {
                _funcs[i] = .{
                    .name = @as([*c]const u8, @ptrCast(fdef.name.ptr)),
                    .function = makeAdapter(fdef.impl),
                    .max_expected_args = @intCast(fdef.args),
                    .min_required_args = @intCast(fdef.args),
                    .suppress_lint = c.awk_false,
                    .data = null,
                };
                if (_api.*.api_add_ext_func.?(_ext_id, "", &_funcs[i]) == c.awk_false) {
                    std.debug.print("{s}: failed to register {s}\n", .{ cfg.name, fdef.name });
                    return 0;
                }
            }
            return 1;
        }
    };
}

fn makeAdapter(comptime impl: *const fn (Args) Result) fn (c_int, [*c]c.awk_value_t, [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    return struct {
        fn adapter(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
            const r = impl(.{ ._argc = nargs });
            return switch (r) {
                .string => |s| c.r_make_string(_api, _ext_id, s.ptr, s.len, c.awk_false, result),
                .int => |n| c.make_number(@floatFromInt(n), result),
                .bool => |b| c.make_number(if (b) 1.0 else 0.0, result),
                .none => {
                    // Return empty string (not 0, which would stringify to "0")
                    return c.r_make_string(_api, _ext_id, "", 0, c.awk_true, result);
                },
            };
        }
    }.adapter;
}
