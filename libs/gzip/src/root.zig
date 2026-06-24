// SPDX-License-Identifier: MIT
const ffi = @import("gawk_ffi");
const gzip = @import("gzip");

var _last_error: []const u8 = "";

fn gzipCompress(args: ffi.Args) ffi.Result {
    const s = args.getString(0);
    const out = gzip.compress(ffi.gawkAllocator(), s) catch |err| {
        _last_error = switch (err) {
            error.OutOfMemory => "OutOfMemory",
            else => "CompressFailed",
        };
        return .{ .string = "" };
    };
    _last_error = "";
    return .{ .gawk_string = out };
}

fn gzipError(_: ffi.Args) ffi.Result {
    return .{ .string = _last_error };
}

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_gzip",
    .functions = &.{
        .{ .name = "hawk_gzip_compress", .impl = &gzipCompress, .args = 1 },
        .{ .name = "hawk_gzip_error", .impl = &gzipError, .args = 0 },
    },
});
comptime {
    _ = _ffi_entry;
}
