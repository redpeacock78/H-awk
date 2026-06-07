// SPDX-License-Identifier: MIT
// libs/binary/src/root.zig -- gawk extension entry point for binary I/O

const std = @import("std");
const binary = @import("binary.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stddef.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("gawkapi.h");
});

// Globals set during dl_load
var api: *const c.gawk_api_t = undefined;
var ext_id: c.awk_ext_id_t = undefined;

// ---------------------------------------------------------------------------
// hawk_bin_read(path) → string (binary content, or "" on error)
// ---------------------------------------------------------------------------
fn binRead(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    _ = nargs;

    var path_val: c.awk_value_t = undefined;
    if (api.*.api_get_argument.?(ext_id, 0, c.AWK_STRING, &path_val) == c.awk_false) {
        return c.r_make_string(api, ext_id, "", 0, c.awk_true, result);
    }
    const path = path_val.u.s.str[0..path_val.u.s.len];

    const max_bytes: usize = blk: {
        const env = std.c.getenv("HAWK_MAX_BODY_SIZE");
        if (env == null) break :blk 1048576;
        const s = std.mem.span(env.?);
        break :blk std.fmt.parseInt(usize, s, 10) catch 1048576;
    };

    const allocator = std.heap.c_allocator;
    const content = binary.readAll(allocator, path, max_bytes) catch {
        return c.r_make_string(api, ext_id, "", 0, c.awk_true, result);
    };
    defer allocator.free(content);

    // Pass awk_true so gawk copies the string (we free our copy after return)
    const ret = c.r_make_string(api, ext_id, content.ptr, content.len, c.awk_true, result);
    allocator.free(content);
    return ret;
}

// ---------------------------------------------------------------------------
// hawk_bin_send(sock_name, content) → number (1=ok, 0=fail)
// v0.2 stub: gawk coprocess socket is not accessible from extension API.
// Actual binary send is done in http.awk via printf |& sock.
// ---------------------------------------------------------------------------
fn binSend(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    _ = nargs;
    return c.make_number(1, result);
}

// ---------------------------------------------------------------------------
// hawk_bin_length(str) → number (byte length)
// ---------------------------------------------------------------------------
fn binLength(nargs: c_int, result: [*c]c.awk_value_t, _: [*c]c.awk_ext_func_t) callconv(.c) [*c]c.awk_value_t {
    _ = nargs;

    var str_val: c.awk_value_t = undefined;
    if (api.*.api_get_argument.?(ext_id, 0, c.AWK_STRING, &str_val) == c.awk_false) {
        return c.make_number(0, result);
    }
    const s = str_val.u.s.str[0..str_val.u.s.len];
    return c.make_number(@floatFromInt(binary.lengthBytes(s)), result);
}

// ---------------------------------------------------------------------------
// Function table
// ---------------------------------------------------------------------------
var funcs = [_]c.awk_ext_func_t{
    .{
        .name = "hawk_bin_read",
        .function = binRead,
        .max_expected_args = 1,
        .min_required_args = 1,
        .suppress_lint = c.awk_false,
        .data = null,
    },
    .{
        .name = "hawk_bin_send",
        .function = binSend,
        .max_expected_args = 2,
        .min_required_args = 2,
        .suppress_lint = c.awk_false,
        .data = null,
    },
    .{
        .name = "hawk_bin_length",
        .function = binLength,
        .max_expected_args = 1,
        .min_required_args = 1,
        .suppress_lint = c.awk_false,
        .data = null,
    },
};

// ---------------------------------------------------------------------------
// dl_load -- gawk calls this when the shared library is loaded
// ---------------------------------------------------------------------------
export var plugin_is_GPL_compatible: c_int = 1;

export fn dl_load(api_p: [*c]const c.gawk_api_t, id: c.awk_ext_id_t) c_int {
    if (api_p == null) return 0;

    api = api_p.?;
    ext_id = id;

    // Version check
    if (api.*.major_version != c.GAWK_API_MAJOR_VERSION) {
        std.debug.print("hawk_binary: gawk API version mismatch\n", .{});
        return 0;
    }

    for (&funcs) |*f| {
        _ = api.*.api_add_ext_func.?(id, "", f);
    }

    return 1;
}
