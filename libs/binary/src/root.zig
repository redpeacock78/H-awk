// SPDX-License-Identifier: MIT
const std = @import("std");
const ffi = @import("gawk_ffi");
const binary = @import("binary.zig");

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_binary",
    .functions = &.{
        .{ .name = "hawk_bin_read",   .impl = &binRead,   .args = 1 },
        .{ .name = "hawk_bin_send",   .impl = &binSend,   .args = 2 },
        .{ .name = "hawk_bin_length", .impl = &binLength, .args = 1 },
    },
});
comptime {
    _ = _ffi_entry;
}

fn binRead(args: ffi.Args) ffi.Result {
    const path = args.getString(0);
    const max_bytes: usize = blk: {
        const env = std.c.getenv("HAWK_MAX_BODY_SIZE");
        if (env == null) break :blk 1048576;
        const s = std.mem.span(env.?);
        break :blk std.fmt.parseInt(usize, s, 10) catch 1048576;
    };
    // Allocate with gawk's allocator so awk_false ownership transfer is API-compliant.
    const content = binary.readAll(ffi.gawkAllocator(), path, max_bytes) catch return .none;
    return .{ .gawk_string = content };
}

fn binSend(_: ffi.Args) ffi.Result {
    return .{ .int = 1 };
}

fn binLength(args: ffi.Args) ffi.Result {
    return .{ .int = @intCast(binary.lengthBytes(args.getString(0))) };
}
