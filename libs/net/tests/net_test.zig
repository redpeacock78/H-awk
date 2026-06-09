// SPDX-License-Identifier: MIT
const std = @import("std");
const http_parser = @import("http_parser");

test "parse simple GET" {
    const alloc = std.testing.allocator;
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    const req = try http_parser.parse(raw, 1, alloc);
    defer req.deinit(alloc);
    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqualStrings("Host: localhost\r\nConnection: keep-alive\r\n", req.headers_block);
    try std.testing.expect(req.keep_alive);
    try std.testing.expectEqual(@as(usize, 0), req.content_length);
}

test "parse POST with body" {
    const alloc = std.testing.allocator;
    const raw = "POST /data HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const req = try http_parser.parse(raw, 2, alloc);
    defer req.deinit(alloc);
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("hello", req.body);
    try std.testing.expectEqual(@as(usize, 5), req.content_length);
    try std.testing.expect(!req.keep_alive);
}

test "parse returns error on missing CRLFCRLF" {
    const alloc = std.testing.allocator;
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost";
    try std.testing.expectError(error.InvalidRequest, http_parser.parse(raw, 3, alloc));
}

test "parse returns error on malformed request line" {
    const alloc = std.testing.allocator;
    const raw = "GARBAGE\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, http_parser.parse(raw, 4, alloc));
}

test "formatPollResult" {
    const alloc = std.testing.allocator;
    const raw = "GET /foo HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const req = try http_parser.parse(raw, 42, alloc);
    defer req.deinit(alloc);
    const poll = try http_parser.formatPollResult(req, alloc);
    defer alloc.free(poll);
    // Format: conn_id RS method RS path RS headers RS body_len RS body
    const RS = "\x1e";
    try std.testing.expectEqualStrings(
        "42" ++ RS ++ "GET" ++ RS ++ "/foo" ++ RS ++ "Host: example.com\r\n" ++ RS ++ "0" ++ RS,
        poll,
    );
}
