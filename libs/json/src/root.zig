// SPDX-License-Identifier: MIT
const std = @import("std");
const ffi = @import("gawk_ffi");
const json = @import("json");

var _last_error: []const u8 = "";

fn jsonValid(args: ffi.Args) ffi.Result {
    const s = args.getString(0);
    const ok = json.valid(ffi.gawkAllocator(), s) catch |err| {
        _last_error = switch (err) {
            error.OutOfMemory => "OutOfMemory",
        };
        return .{ .string = "0" };
    };
    _last_error = if (ok) "" else "InvalidJson";
    return .{ .string = if (ok) "1" else "0" };
}

fn jsonError(_: ffi.Args) ffi.Result {
    return .{ .string = _last_error };
}

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_json",
    .functions = &.{
        .{ .name = "hawk_json_valid", .impl = &jsonValid, .args = 1 },
        .{ .name = "hawk_json_error", .impl = &jsonError, .args = 0 },
    },
});
comptime {
    _ = _ffi_entry;
}
