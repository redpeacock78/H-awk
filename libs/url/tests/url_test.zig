const std = @import("std");
const url = @import("url");

test "encode space" {
    const out = try url.encode(std.testing.allocator, "a b");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a%20b", out);
}

test "decode form plus" {
    const out = try url.decode(std.testing.allocator, "a+b", true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a b", out);
}

test "decode invalid percent" {
    const result = url.decode(std.testing.allocator, "%ZZ", false);
    try std.testing.expectError(url.DecodeError.InvalidPercentEncoding, result);
}

test "decode truncated percent" {
    const result = url.decode(std.testing.allocator, "%A", false);
    try std.testing.expectError(url.DecodeError.InvalidPercentEncoding, result);
}

test "roundtrip japanese" {
    const encoded = try url.encode(std.testing.allocator, "あ");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("%E3%81%82", encoded);
    const decoded = try url.decode(std.testing.allocator, encoded, false);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("あ", decoded);
}
