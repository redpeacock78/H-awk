const std = @import("std");
const gzip = @import("gzip");

test "compress emits gzip stream" {
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ** 20;
    const out = try gzip.compress(std.testing.allocator, input);
    defer std.testing.allocator.free(out);

    try std.testing.expect(out.len > 10);
    try std.testing.expectEqual(@as(u8, 0x1f), out[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), out[1]);
    try std.testing.expect(out.len < input.len);
}
