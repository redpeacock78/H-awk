// SPDX-License-Identifier: MIT
// libs/_common/gawk_ffi.zig -- gawk extension C ABI wrapper
//
// Pure Zig types and utilities. Actual C ABI calls (dl_load, make_builtin)
// live in each lib's root.zig using @cImport of gawkapi.h.

const std = @import("std");

// ---------------------------------------------------------------------------
// gawk value type constants (match gawkapi.h)
// ---------------------------------------------------------------------------

pub const AWK_UNDEFINED: c_int = 0;
pub const AWK_NUMBER: c_int = 1;
pub const AWK_STRING: c_int = 2;
pub const AWK_REGEX: c_int = 3;
pub const AWK_STRNUM: c_int = 4;
pub const AWK_ARRAY: c_int = 5;
pub const AWK_SCALAR: c_int = 6;
pub const AWK_VALUE_COOKIE: c_int = 7;
pub const AWK_BOOL: c_int = 8;

pub const AwkFalse: c_int = 0;
pub const AwkTrue: c_int = 1;

// ---------------------------------------------------------------------------
// gawk C types
// ---------------------------------------------------------------------------

pub const awk_string_t = extern struct {
    str: [*c]u8,
    len: usize,
};

pub const awk_value_t = extern struct {
    val_type: c_int,
    u: extern union {
        d: f64,
        s: awk_string_t,
    },
};

// ---------------------------------------------------------------------------
// gawk memory functions (called from extensions)
// ---------------------------------------------------------------------------

extern fn gawk_malloc(size: usize) ?*anyopaque;
extern fn gawk_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn gawk_free(ptr: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Argument list passed to a gawk extension function.
pub const Args = struct {
    _argv: [*c]awk_value_t,
    _argc: c_int,

    /// Get i-th argument as string slice (empty on type mismatch).
    pub fn getString(self: Args, i: usize) []const u8 {
        if (i >= @as(usize, @intCast(self._argc))) return "";
        const v = self._argv[i];
        if (v.val_type != AWK_STRING and v.val_type != AWK_STRNUM) return "";
        return v.u.s.str[0..v.u.s.len];
    }

    /// Get i-th argument as i64 (0 on type mismatch).
    pub fn getInt(self: Args, i: usize) i64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0;
        const v = self._argv[i];
        if (v.val_type != AWK_NUMBER) return 0;
        return @intFromFloat(v.u.d);
    }

    /// Get i-th argument as f64 (0.0 on type mismatch).
    pub fn getDouble(self: Args, i: usize) f64 {
        if (i >= @as(usize, @intCast(self._argc))) return 0.0;
        const v = self._argv[i];
        if (v.val_type != AWK_NUMBER) return 0.0;
        return v.u.d;
    }
};

/// Return value of a gawk extension function.
pub const Result = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    none,
};

/// Definition of one gawk extension function.
pub const FuncDef = struct {
    name: []const u8,
    impl: *const fn (Args) Result,
    args: usize,
};

/// Configuration for makeDlLoad.
pub const DlLoadConfig = struct {
    name: []const u8,
    api_major: u32 = 4,
    api_minor: u32 = 0,
    functions: []const FuncDef,
};

// ---------------------------------------------------------------------------
// gawk_malloc-based allocator
// ---------------------------------------------------------------------------

pub fn gawkAllocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &gawk_allocator_vtable,
    };
}

const gawk_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = gawkAlloc,
    .resize = gawkResize,
    .free = gawkFreeSlice,
};

fn gawkAlloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const ptr = gawk_malloc(n) orelse return null;
    return @ptrCast(ptr);
}

fn gawkResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    _ = buf;
    _ = new_len;
    return false;
}

fn gawkFreeSlice(_: *anyopaque, slice: []u8, _: std.mem.Alignment, _: usize) void {
    gawk_free(slice.ptr);
}
