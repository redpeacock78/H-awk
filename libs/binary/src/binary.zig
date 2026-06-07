// SPDX-License-Identifier: MIT
// libs/binary/src/binary.zig -- binary-safe file I/O
//
// Pure Zig module, independent of gawk. Called from root.zig.

const std = @import("std");

extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *anyopaque) c_long;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

/// Read a file in a binary-safe manner.
/// Return value is a slice owned by the allocator. Caller must free.
/// Returns error on failure (caller converts to empty string).
pub fn readAll(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);

    const file = std.c.fopen(c_path.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return error.SeekFailed;
    const size = ftell(file);
    if (size < 0) return error.TellFailed;
    if (fseek(file, 0, SEEK_SET) != 0) return error.SeekFailed;

    const usize_size = @as(usize, @intCast(size));
    if (usize_size > max_bytes) {
        std.debug.print("hawk_bin_read: file size {d} exceeds max {d}: {s}\n", .{ usize_size, max_bytes, path });
        return error.FileTooLarge;
    }

    const buf = try allocator.alloc(u8, usize_size);
    errdefer allocator.free(buf);

    const n = std.c.fread(buf.ptr, 1, usize_size, file);
    if (n != usize_size) {
        allocator.free(buf);
        return error.ReadIncomplete;
    }

    return buf;
}

/// Return byte length (alternative to length(): gawk's length() counts characters)
pub fn lengthBytes(s: []const u8) usize {
    return s.len;
}
