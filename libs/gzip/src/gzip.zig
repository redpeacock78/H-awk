// SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

/// Compress `s` with gzip. Caller owns the returned slice.
pub fn compress(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // Allocating writer grows dynamically as compressed bytes arrive.
    // Initial capacity must be > 8 (asserted by Compress.init).
    var out_w = try Io.Writer.Allocating.initCapacity(alloc, @max(s.len, 64));
    errdefer out_w.deinit();

    // History/input buffer for the deflate engine; must be >= max_window_len.
    var deflate_buf: [flate.max_window_len * 2]u8 = undefined;

    var deflater = try flate.Compress.init(
        &out_w.writer,
        &deflate_buf,
        .gzip,
        flate.Compress.Options.default,
    );

    // Feed uncompressed bytes; compressor drains to out_w on demand.
    try deflater.writer.writeAll(s);

    // Flush remaining data and write gzip checksum + size footer.
    try deflater.finish();

    const end = out_w.writer.end;
    const result = try alloc.dupe(u8, out_w.writer.buffer[0..end]);
    out_w.deinit();
    return result;
}
