// SPDX-License-Identifier: MIT
// libs/gzip/src/gzip.zig -- gzip compression
const std = @import("std");

pub fn compress(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 64);
    errdefer out.deinit();

    const buf = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(buf);

    var gz = try std.compress.flate.Compress.init(&out.writer, buf, .gzip, .default);
    try gz.writer.writeAll(s);
    try gz.finish();

    return out.toOwnedSlice();
}
