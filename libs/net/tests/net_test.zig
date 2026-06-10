// SPDX-License-Identifier: MIT
const std = @import("std");
const http_parser = @import("http_parser");
const conn_pool = @import("conn_pool");

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

test "add and get conn" {
    var pool = conn_pool.ConnPool.init(std.testing.allocator);
    defer pool.deinit();
    const id = try pool.add(99);  // fd=99 (dummy, won't be closed in test)
    try std.testing.expectEqual(@as(u64, 1), id);
    {
        pool.mu.lock();
        defer pool.mu.unlock();
        const conn = pool.conns.getPtr(id);
        try std.testing.expect(conn != null);
        try std.testing.expectEqual(conn_pool.ConnState.reading, conn.?.state);
    }
    // Remove without closing (fd=99 is not real in test)
    pool.mu.lock();
    if (pool.conns.fetchRemove(id)) |kv| {
        var c = kv.value;
        c.read_buf.deinit(std.testing.allocator);
        // don't close fd=99 in test
    }
    pool.mu.unlock();
}

test "next_id increments" {
    var pool = conn_pool.ConnPool.init(std.testing.allocator);
    defer pool.deinit();
    const id1 = try pool.add(0);
    const id2 = try pool.add(0);
    try std.testing.expect(id2 > id1);
    // Clean up without closing dummy fds
    pool.mu.lock();
    pool.conns.clearAndFree();
    pool.mu.unlock();
}

test "get returns null for unknown id" {
    var pool = conn_pool.ConnPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.mu.lock();
    const result = pool.conns.getPtr(9999);
    pool.mu.unlock();
    try std.testing.expect(result == null);
}

const event_loop = @import("event_loop");

test "event_loop: listen, send request, dequeue, respond" {
    const alloc = std.testing.allocator;

    const port: u16 = 18765;

    var loop = try event_loop.EventLoop.init(alloc, port);
    defer loop.deinit();

    const thread = try std.Thread.spawn(.{}, event_loop.EventLoop.run, .{&loop});

    {
        const ts = std.c.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    const client_fd = blk: {
        const fd_rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        if (std.posix.errno(fd_rc) != .SUCCESS) return error.Socket;
        break :blk @as(std.posix.socket_t, @intCast(fd_rc));
    };
    defer _ = std.posix.system.close(client_fd);

    const addr = std.posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    const conn_rc = std.posix.system.connect(client_fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
    if (std.posix.errno(conn_rc) != .SUCCESS) return error.Connect;

    const req_bytes = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = std.posix.system.write(client_fd, req_bytes.ptr, req_bytes.len);

    const poll_str = loop.dequeue(alloc);
    try std.testing.expect(poll_str != null);
    defer alloc.free(poll_str.?);

    try std.testing.expect(std.mem.indexOf(u8, poll_str.?, "\x1e") != null);
    try std.testing.expect(std.mem.indexOf(u8, poll_str.?, "GET") != null);

    const first_sep = std.mem.indexOf(u8, poll_str.?, "\x1e").?;
    const conn_id = try std.fmt.parseInt(u64, poll_str.?[0..first_sep], 10);

    const ok = loop.respond(conn_id, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nOK");
    try std.testing.expect(ok);

    {
        const ts = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    loop.stop();
    thread.join();
}
