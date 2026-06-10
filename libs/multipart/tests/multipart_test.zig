// SPDX-License-Identifier: MIT
const std = @import("std");
const multipart = @import("multipart");

test "parse text-only form" {
    const alloc = std.testing.allocator;
    const boundary = "----WebKit123";
    const body =
        "------WebKit123\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "alice\r\n" ++
        "------WebKit123--\r\n";
    const parts = try multipart.parse(alloc, body, boundary);
    defer multipart.freeParts(alloc, parts);
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("username", parts[0].name);
    try std.testing.expectEqualStrings("alice", parts[0].body);
    try std.testing.expectEqualStrings("", parts[0].filename);
}

test "parse file + text mixed" {
    const alloc = std.testing.allocator;
    const boundary = "BOUND";
    const body =
        "--BOUND\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"photo.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n" ++
        "\r\n" ++
        "\xff\xd8\xff\xe0" ++
        "\r\n" ++
        "--BOUND\r\n" ++
        "Content-Disposition: form-data; name=\"caption\"\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--BOUND--\r\n";
    const parts = try multipart.parse(alloc, body, boundary);
    defer multipart.freeParts(alloc, parts);
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("avatar", parts[0].name);
    try std.testing.expectEqualStrings("photo.jpg", parts[0].filename);
    try std.testing.expectEqualStrings("image/jpeg", parts[0].content_type);
    try std.testing.expectEqualStrings("\xff\xd8\xff\xe0", parts[0].body);
    try std.testing.expectEqualStrings("caption", parts[1].name);
    try std.testing.expectEqualStrings("", parts[1].filename);
    try std.testing.expectEqualStrings("hello world", parts[1].body);
}

test "malformed body returns error" {
    const alloc = std.testing.allocator;
    const result = multipart.parse(alloc, "no boundary here", "BOUND");
    try std.testing.expectError(error.NoBoundary, result);
}
