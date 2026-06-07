// SPDX-License-Identifier: MIT
// libs/binary/src/binary.zig -- binary-safe file I/O
//
// Pure Zig module, independent of gawk. Called from root.zig.

const std = @import("std");

/// Read a file in a binary-safe manner.
/// Return value is a slice owned by the allocator. Caller must free.
/// Returns error on failure (caller converts to empty string).
pub fn readAll(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    if (size > max_bytes) {
        std.log.warn("hawk_bin_read: file size {d} exceeds max {d}: {s}", .{ size, max_bytes, path });
        return error.FileTooLarge;
    }

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    const n = try file.readAll(buf);
    if (n != size) {
        allocator.free(buf);
        return error.ReadIncomplete;
    }

    return buf;
}

/// Return byte length (alternative to length(): gawk's length() counts characters)
pub fn lengthBytes(s: []const u8) usize {
    return s.len;
}
