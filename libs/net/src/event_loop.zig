// libs/net/src/event_loop.zig
// SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");
const http_parser = @import("http_parser");
const conn_pool = @import("conn_pool");

const BACKLOG: u31 = 128;
const MAX_EVENTS = 64;
const READ_BUF_SIZE = 65536;

fn monoNanos() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

pub const PendingResponse = struct {
    conn_id: u64,
    data: []u8,
};

pub const EventLoop = struct {
    alloc: std.mem.Allocator,
    listen_fd: std.posix.socket_t,
    pool: conn_pool.ConnPool,

    // Request queue: event loop thread enqueues; AWK thread dequeues
    req_queue: std.ArrayList([]const u8),
    req_mu: conn_pool.SimpleMutex,

    // Response queue: AWK thread enqueues; event loop thread drains
    resp_queue: std.ArrayList(PendingResponse),
    resp_mu: conn_pool.SimpleMutex,

    // Wakeup pipe: write 1 byte to interrupt kqueue/epoll wait
    wakeup_read_fd: std.posix.fd_t,
    wakeup_write_fd: std.posix.fd_t,

    // Atomic running flag
    running: std.atomic.Value(bool),

    // Keep-Alive idle timeout in nanoseconds (from HAWK_KEEPALIVE_TIMEOUT env, default 75s)
    keepalive_timeout_ns: i64,

    pub fn init(alloc: std.mem.Allocator, port: u16) !EventLoop {
        // Create listening socket
        const listen_fd = blk: {
            const fd_rc = std.posix.system.socket(
                std.posix.AF.INET,
                std.posix.SOCK.STREAM,
                std.posix.IPPROTO.TCP,
            );
            if (std.posix.errno(fd_rc) != .SUCCESS) return error.SocketCreate;
            break :blk @as(std.posix.socket_t, @intCast(fd_rc));
        };
        errdefer _ = std.posix.system.close(listen_fd);

        // Set SO_REUSEADDR + SO_REUSEPORT (enables multi-worker kernel-level load balancing)
        const reuse: c_int = 1;
        _ = std.posix.system.setsockopt(
            listen_fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            @ptrCast(&reuse),
            @sizeOf(c_int),
        );
        _ = std.posix.system.setsockopt(
            listen_fd,
            std.posix.SOL.SOCKET,
            std.c.SO.REUSEPORT,
            @ptrCast(&reuse),
            @sizeOf(c_int),
        );

        // Set non-blocking
        const flags_rc = std.posix.system.fcntl(listen_fd, std.posix.F.GETFL, @as(usize, 0));
        if (std.posix.errno(flags_rc) != .SUCCESS) return error.Fcntl;
        var fl_flags: usize = @intCast(flags_rc);
        fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        if (std.posix.errno(std.posix.system.fcntl(listen_fd, std.posix.F.SETFL, fl_flags)) != .SUCCESS) return error.Fcntl;

        // Bind
        const addr = std.posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0, // INADDR_ANY
        };
        const bind_rc = std.posix.system.bind(
            listen_fd,
            @ptrCast(&addr),
            @sizeOf(std.posix.sockaddr.in),
        );
        if (std.posix.errno(bind_rc) != .SUCCESS) return error.Bind;

        // Listen
        const listen_rc = std.posix.system.listen(listen_fd, BACKLOG);
        if (std.posix.errno(listen_rc) != .SUCCESS) return error.Listen;

        // Create wakeup pipe
        var pipe_fds: [2]std.posix.fd_t = undefined;
        const pipe_rc = std.c.pipe(&pipe_fds);
        if (pipe_rc != 0) return error.Pipe;
        errdefer {
            _ = std.posix.system.close(pipe_fds[0]);
            _ = std.posix.system.close(pipe_fds[1]);
        }

        // Set pipe read end non-blocking
        const pipe_flags_rc = std.posix.system.fcntl(pipe_fds[0], std.posix.F.GETFL, @as(usize, 0));
        if (std.posix.errno(pipe_flags_rc) != .SUCCESS) return error.Fcntl;
        var pipe_fl: usize = @intCast(pipe_flags_rc);
        pipe_fl |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        _ = std.posix.system.fcntl(pipe_fds[0], std.posix.F.SETFL, pipe_fl);

        const keepalive_s: i64 = if (std.c.getenv("HAWK_KEEPALIVE_TIMEOUT")) |val|
            std.fmt.parseInt(i64, std.mem.sliceTo(val, 0), 10) catch 75
        else
            75;

        return EventLoop{
            .alloc = alloc,
            .listen_fd = listen_fd,
            .pool = conn_pool.ConnPool.init(alloc),
            .req_queue = try std.ArrayList([]const u8).initCapacity(alloc, 0),
            .req_mu = .{},
            .resp_queue = try std.ArrayList(PendingResponse).initCapacity(alloc, 0),
            .resp_mu = .{},
            .wakeup_read_fd = pipe_fds[0],
            .wakeup_write_fd = pipe_fds[1],
            .running = std.atomic.Value(bool).init(true),
            .keepalive_timeout_ns = keepalive_s * std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        _ = std.posix.system.close(self.listen_fd);
        _ = std.posix.system.close(self.wakeup_read_fd);
        _ = std.posix.system.close(self.wakeup_write_fd);

        // Free any pending requests
        for (self.req_queue.items) |s| self.alloc.free(s);
        self.req_queue.deinit(self.alloc);

        // Free any pending responses
        for (self.resp_queue.items) |r| self.alloc.free(r.data);
        self.resp_queue.deinit(self.alloc);

        // Close all connection fds and deinit pool
        {
            var it = self.pool.conns.valueIterator();
            while (it.next()) |conn| {
                _ = std.posix.system.close(conn.fd);
            }
        }
        self.pool.deinit();
    }

    pub fn stop(self: *EventLoop) void {
        self.running.store(false, .seq_cst);
        // Wake up the event loop
        const buf: [1]u8 = .{0};
        _ = std.posix.system.write(self.wakeup_write_fd, &buf, 1);
    }

    /// Run the event loop. Call in a background thread.
    pub fn run(self: *EventLoop) void {
        self.running.store(true, .seq_cst);
        if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
            if (builtin.os.tag == .macos) {
                self.runKqueue() catch |err| {
                    std.log.err("event loop error: {}", .{err});
                };
            } else {
                self.runEpoll() catch |err| {
                    std.log.err("event loop error: {}", .{err});
                };
            }
        } else {
            // Fallback: simple blocking loop (should not be reached in practice)
            self.runBlocking();
        }
    }

    // Scan response bytes for "Connection: keep-alive" header.
    fn responseIsKeepAlive(data: []const u8) bool {
        const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
        const headers = data[0..headers_end];
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        _ = it.next(); // skip status line
        while (it.next()) |line| {
            const colon = std.mem.indexOf(u8, line, ":") orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Connection")) {
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                return std.ascii.eqlIgnoreCase(val, "keep-alive");
            }
        }
        return false;
    }

    fn responseHasConnectionClose(data: []const u8) bool {
        const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
        const headers = data[0..headers_end];
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        _ = it.next(); // skip status line
        while (it.next()) |line| {
            const colon = std.mem.indexOf(u8, line, ":") orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Connection")) {
                const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
                return std.ascii.eqlIgnoreCase(val, "close");
            }
        }
        return false;
    }

    fn fdIsHalfClosed(fd: std.posix.socket_t) bool {
        var byte: [1]u8 = undefined;
        const rc = std.c.recv(fd, &byte, byte.len, std.posix.MSG.PEEK);
        if (rc == 0) return true;
        if (rc > 0) return false;
        const e = std.posix.errno(rc);
        return e != .AGAIN;
    }

    fn sweepIdleConns(self: *EventLoop) void {
        const now_ms = @divTrunc(monoNanos(), 1_000_000);
        var ids: [256]u64 = undefined;
        var fds: [256]std.posix.socket_t = undefined;
        var send408: [256]bool = undefined;
        var count: usize = 0;

        self.pool.mu.lock();
        var it = self.pool.conns.iterator();
        while (it.next()) |entry| {
            if (count >= ids.len) break;
            const conn = entry.value_ptr;
            const idle = conn.keep_alive and (monoNanos() - conn.last_used > self.keepalive_timeout_ns);
            const body_late = conn.body_deadline != 0 and now_ms > conn.body_deadline;
            if (idle or body_late) {
                ids[count] = entry.key_ptr.*;
                fds[count] = conn.fd;
                send408[count] = body_late;
                count += 1;
            }
        }
        var removed_count: usize = 0;
        var bufs_to_deinit: [256]std.ArrayList(u8) = undefined;
        var close_fds: [256]std.posix.socket_t = undefined;
        var close_408: [256]bool = undefined;
        for (ids[0..count], 0..) |id, i| {
            if (self.pool.conns.fetchRemove(id)) |kv| {
                bufs_to_deinit[removed_count] = kv.value.read_buf;
                close_fds[removed_count] = fds[i];
                close_408[removed_count] = send408[i];
                removed_count += 1;
            }
        }
        self.pool.mu.unlock();

        for (bufs_to_deinit[0..removed_count]) |*buf| buf.deinit(self.alloc);

        for (close_fds[0..removed_count], close_408[0..removed_count]) |fd, do408| {
            if (do408) sendSimpleError(fd, 408, "Request Timeout");
            _ = std.posix.system.close(fd);
        }
    }

    fn sendSimpleError(fd: std.posix.socket_t, status_code: u16, reason: []const u8) void {
        var body_buf: [64]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{d} {s}", .{ status_code, reason }) catch return;
        var hdr_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ status_code, reason, body.len, body },
        ) catch return;
        _ = std.posix.system.write(fd, msg.ptr, msg.len);
    }

    // ---- kqueue implementation (macOS) ----
    fn runKqueue(self: *EventLoop) !void {
        // Create kqueue fd
        const kq_rc = std.posix.system.kqueue();
        if (std.posix.errno(kq_rc) != .SUCCESS) return error.KqueueCreate;
        const kq: std.posix.fd_t = @intCast(kq_rc);
        defer _ = std.posix.system.close(kq);

        // Register listen_fd for read events
        {
            const changes = [_]std.posix.Kevent{
                .{
                    .ident = @intCast(self.listen_fd),
                    .filter = std.c.EVFILT.READ,
                    .flags = std.c.EV.ADD | std.c.EV.ENABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0, // 0 = listen fd marker
                },
                .{
                    .ident = @intCast(self.wakeup_read_fd),
                    .filter = std.c.EVFILT.READ,
                    .flags = std.c.EV.ADD | std.c.EV.ENABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = std.math.maxInt(usize), // wakeup marker
                },
            };
            var events: [0]std.posix.Kevent = .{};
            _ = std.posix.system.kevent(kq, &changes, changes.len, &events, 0, null);
        }

        var event_buf: [MAX_EVENTS]std.posix.Kevent = undefined;
        const sweep_timeout = std.posix.timespec{ .sec = 5, .nsec = 0 };

        while (self.running.load(.seq_cst)) {
            // Drain response queue first
            self.drainResponses();

            const empty_changes: [0]std.posix.Kevent = .{};
            const n_rc = std.posix.system.kevent(kq, &empty_changes, 0, &event_buf, MAX_EVENTS, &sweep_timeout);
            if (std.posix.errno(n_rc) == .INTR) continue;
            if (std.posix.errno(n_rc) != .SUCCESS) break;
            const n: usize = @intCast(n_rc);

            self.sweepIdleConns();

            for (event_buf[0..n]) |ev| {
                if (ev.udata == std.math.maxInt(usize)) {
                    // Wakeup pipe: drain it
                    var tmp: [64]u8 = undefined;
                    while (true) {
                        const r = std.posix.system.read(self.wakeup_read_fd, &tmp, tmp.len);
                        if (std.posix.errno(r) == .AGAIN) break;
                        if (@as(isize, @intCast(r)) <= 0) break;
                    }
                    // Drain responses after wakeup
                    self.drainResponses();
                    continue;
                }

                const fd: std.posix.socket_t = @intCast(ev.ident);

                if (fd == self.listen_fd) {
                    // Accept new connections
                    self.acceptKqueue(kq);
                } else {
                    // Read from connection
                    self.readConn(fd, kq, .kqueue);
                }
            }
        }
    }

    fn acceptKqueue(self: *EventLoop, kq: std.posix.fd_t) void {
        while (true) {
            var client_addr: std.posix.sockaddr = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const accept_rc = std.posix.system.accept(self.listen_fd, &client_addr, &addr_len);
            const e = std.posix.errno(accept_rc);
            if (e == .AGAIN) break;
            if (e != .SUCCESS) break;
            const client_fd: std.posix.socket_t = @intCast(accept_rc);

            // Set non-blocking
            const fl_rc = std.posix.system.fcntl(client_fd, std.posix.F.GETFL, @as(usize, 0));
            if (std.posix.errno(fl_rc) == .SUCCESS) {
                var fl: usize = @intCast(fl_rc);
                fl |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
                _ = std.posix.system.fcntl(client_fd, std.posix.F.SETFL, fl);
            }

            const conn_id = self.pool.add(client_fd) catch {
                _ = std.posix.system.close(client_fd);
                continue;
            };

            // Register with kqueue
            const changes = [_]std.posix.Kevent{
                .{
                    .ident = @intCast(client_fd),
                    .filter = std.c.EVFILT.READ,
                    .flags = std.c.EV.ADD | std.c.EV.ENABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = conn_id, // use conn_id as udata
                },
            };
            var events: [0]std.posix.Kevent = .{};
            _ = std.posix.system.kevent(kq, &changes, changes.len, &events, 0, null);
        }
    }

    const IoBackend = enum { kqueue, epoll };

    fn readConn(self: *EventLoop, fd: std.posix.socket_t, kq_or_epoll: std.posix.fd_t, backend: IoBackend) void {
        _ = kq_or_epoll;
        _ = backend;

        // Find conn_id for this fd
        var conn_id: u64 = 0;
        {
            self.pool.mu.lock();
            defer self.pool.mu.unlock();
            var it = self.pool.conns.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.fd == fd) {
                    conn_id = entry.key_ptr.*;
                    break;
                }
            }
        }
        if (conn_id == 0) return;

        // Read data into connection buffer
        var buf: [READ_BUF_SIZE]u8 = undefined;
        const r = std.posix.system.read(fd, &buf, buf.len);
        const e = std.posix.errno(r);

        if (e == .AGAIN) return;

        if (@as(isize, @intCast(r)) <= 0 or e != .SUCCESS) {
            // Connection closed or error
            self.pool.mu.lock();
            if (self.pool.conns.getPtr(conn_id)) |conn| {
                if (conn.state == .ready) {
                    self.pool.mu.unlock();
                    return;
                }
            }
            if (self.pool.conns.fetchRemove(conn_id)) |kv| {
                var conn = kv.value;
                conn.read_buf.deinit(self.alloc);
            }
            self.pool.mu.unlock();
            _ = std.posix.system.close(fd);
            return;
        }

        const n: usize = @intCast(r);

        self.pool.mu.lock();
        var conn_ptr = self.pool.conns.getPtr(conn_id);
        if (conn_ptr == null) {
            self.pool.mu.unlock();
            return;
        }
        conn_ptr.?.read_buf.appendSlice(self.alloc, buf[0..n]) catch {
            self.pool.mu.unlock();
            return;
        };

        drain: while (true) {
            const frame = http_parser.parseFrame(conn_ptr.?.read_buf.items);
            switch (frame.action) {
                .enqueue => {
                    const slice = conn_ptr.?.read_buf.items[0..frame.consume_len];
                    const owned = self.alloc.dupe(u8, slice) catch break :drain;
                    defer self.alloc.free(owned);
                    const rest = conn_ptr.?.read_buf.items[frame.consume_len..];
                    const rest_copy = self.alloc.dupe(u8, rest) catch break :drain;
                    defer self.alloc.free(rest_copy);
                    conn_ptr.?.read_buf.clearRetainingCapacity();
                    conn_ptr.?.read_buf.appendSlice(self.alloc, rest_copy) catch {};
                    conn_ptr.?.body_deadline = 0;
                    self.pool.mu.unlock();
                    const req = http_parser.parse(owned, conn_id, self.alloc) catch {
                        self.pool.mu.lock();
                        conn_ptr = self.pool.conns.getPtr(conn_id);
                        if (conn_ptr == null) {
                            self.pool.mu.unlock();
                            return;
                        }
                        break :drain;
                    };
                    defer req.deinit(self.alloc);
                    const poll_str = http_parser.formatPollResult(req, self.alloc) catch {
                        self.pool.mu.lock();
                        conn_ptr = self.pool.conns.getPtr(conn_id);
                        if (conn_ptr == null) {
                            self.pool.mu.unlock();
                            return;
                        }
                        break :drain;
                    };
                    self.req_mu.lock();
                    self.req_queue.append(self.alloc, poll_str) catch {
                        self.req_mu.unlock();
                        self.alloc.free(poll_str);
                        self.pool.mu.lock();
                        conn_ptr = self.pool.conns.getPtr(conn_id);
                        if (conn_ptr == null) {
                            self.pool.mu.unlock();
                            return;
                        }
                        break :drain;
                    };
                    self.req_mu.unlock();
                    self.pool.mu.lock();
                    conn_ptr = self.pool.conns.getPtr(conn_id);
                    if (conn_ptr == null) {
                        self.pool.mu.unlock();
                        return;
                    }
                    conn_ptr.?.state = .ready;
                    if (conn_ptr.?.read_buf.items.len == 0) break :drain;
                },
                .wait_header => break :drain,
                .wait_body => {
                    conn_ptr.?.body_deadline = @divTrunc(monoNanos(), 1_000_000) + http_parser.BODY_READ_TIMEOUT_MS;
                    break :drain;
                },
                .error_response => {
                    const close_fd = conn_ptr.?.fd;
                    if (self.pool.conns.fetchRemove(conn_id)) |kv| {
                        var conn = kv.value;
                        conn.read_buf.deinit(self.alloc);
                    }
                    self.pool.mu.unlock();
                    sendSimpleError(close_fd, frame.status_code, frame.reason);
                    _ = std.posix.system.close(close_fd);
                    return;
                },
            }
        }
        self.pool.mu.unlock();
    }

    fn drainResponses(self: *EventLoop) void {
        self.resp_mu.lock();
        if (self.resp_queue.items.len == 0) {
            self.resp_mu.unlock();
            return;
        }
        // Take all pending responses
        const items = self.resp_queue.toOwnedSlice(self.alloc) catch {
            self.resp_mu.unlock();
            return;
        };
        self.resp_mu.unlock();
        defer self.alloc.free(items);

        for (items) |resp| {
            defer self.alloc.free(resp.data);

            // Find the connection fd
            var fd: std.posix.socket_t = 0;
            {
                self.pool.mu.lock();
                if (self.pool.conns.getPtr(resp.conn_id)) |conn| {
                    fd = conn.fd;
                }
                self.pool.mu.unlock();
            }
            if (fd == 0) continue;

            // Write response
            var written: usize = 0;
            while (written < resp.data.len) {
                const rc = std.posix.system.write(fd, resp.data[written..].ptr, resp.data.len - written);
                if (@as(isize, @intCast(rc)) <= 0) break;
                written += @intCast(rc);
            }

            const should_close = responseHasConnectionClose(resp.data) or fdIsHalfClosed(fd) or !responseIsKeepAlive(resp.data);
            if (!should_close) {
                // Keep connection open; update idle timestamp
                self.pool.mu.lock();
                if (self.pool.conns.getPtr(resp.conn_id)) |conn| {
                    conn.state = .reading;
                    conn.keep_alive = true;
                    conn.last_used = monoNanos();
                }
                self.pool.mu.unlock();
            } else {
                // Close connection
                self.pool.mu.lock();
                if (self.pool.conns.fetchRemove(resp.conn_id)) |kv| {
                    var conn = kv.value;
                    conn.read_buf.deinit(self.alloc);
                }
                self.pool.mu.unlock();
                _ = std.posix.system.close(fd);
            }
        }
    }

    // ---- epoll implementation (Linux) ----
    fn runEpoll(self: *EventLoop) !void {
        const linux = std.os.linux;
        const epoll_fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        defer std.posix.close(epoll_fd);

        // Register listen_fd
        {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = self.listen_fd },
            };
            try std.posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, self.listen_fd, &ev);
        }
        // Register wakeup pipe
        {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = self.wakeup_read_fd },
            };
            try std.posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, self.wakeup_read_fd, &ev);
        }

        var event_buf: [MAX_EVENTS]linux.epoll_event = undefined;

        while (self.running.load(.seq_cst)) {
            self.drainResponses();

            const n = std.posix.epoll_wait(epoll_fd, &event_buf, 5000);
            self.sweepIdleConns();

            for (event_buf[0..n]) |ev| {
                const fd: std.posix.fd_t = ev.data.fd;
                if (fd == self.wakeup_read_fd) {
                    var tmp: [64]u8 = undefined;
                    while (true) {
                        const r = std.posix.system.read(self.wakeup_read_fd, &tmp, tmp.len);
                        if (std.posix.errno(r) == .AGAIN) break;
                        if (@as(isize, @intCast(r)) <= 0) break;
                    }
                    self.drainResponses();
                } else if (fd == self.listen_fd) {
                    self.acceptEpoll(epoll_fd);
                } else {
                    self.readConn(@intCast(fd), epoll_fd, .epoll);
                }
            }
        }
    }

    fn acceptEpoll(self: *EventLoop, epoll_fd: std.posix.fd_t) void {
        const linux = std.os.linux;
        while (true) {
            var client_addr: std.posix.sockaddr = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const accept_rc = std.posix.system.accept(self.listen_fd, &client_addr, &addr_len);
            const e = std.posix.errno(accept_rc);
            if (e == .AGAIN) break;
            if (e != .SUCCESS) break;
            const client_fd: std.posix.socket_t = @intCast(accept_rc);

            // Set non-blocking
            const fl_rc = std.posix.system.fcntl(client_fd, std.posix.F.GETFL, @as(usize, 0));
            if (std.posix.errno(fl_rc) == .SUCCESS) {
                var fl: usize = @intCast(fl_rc);
                fl |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
                _ = std.posix.system.fcntl(client_fd, std.posix.F.SETFL, fl);
            }

            const conn_id = self.pool.add(client_fd) catch {
                _ = std.posix.system.close(client_fd);
                continue;
            };
            _ = conn_id;

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = client_fd },
            };
            std.posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &ev) catch {
                self.pool.remove(client_fd);
                _ = std.posix.system.close(client_fd);
            };
        }
    }

    // Simple blocking fallback (unused in practice)
    fn runBlocking(self: *EventLoop) void {
        while (self.running.load(.seq_cst)) {
            const ts = std.c.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }

    /// Block until a request is available. Returns caller-owned poll string, or null if stopped.
    pub fn dequeue(self: *EventLoop, gawk_alloc: std.mem.Allocator) ?[]u8 {
        while (self.running.load(.seq_cst)) {
            self.req_mu.lock();
            if (self.req_queue.items.len > 0) {
                const item = self.req_queue.orderedRemove(0);
                self.req_mu.unlock();
                // Re-allocate using gawk_alloc (caller may use a different allocator)
                const owned = gawk_alloc.dupe(u8, item) catch {
                    self.alloc.free(item);
                    return null;
                };
                self.alloc.free(item);
                return owned;
            }
            self.req_mu.unlock();
            const ts = std.c.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        return null;
    }

    /// Queue a response for a connection. Returns false if conn_id not found.
    pub fn respond(self: *EventLoop, conn_id: u64, data: []const u8) bool {
        // Verify connection exists
        self.pool.mu.lock();
        const exists = self.pool.conns.contains(conn_id);
        self.pool.mu.unlock();
        if (!exists) return false;

        const owned_data = self.alloc.dupe(u8, data) catch return false;

        self.resp_mu.lock();
        self.resp_queue.append(self.alloc, .{ .conn_id = conn_id, .data = owned_data }) catch {
            self.resp_mu.unlock();
            self.alloc.free(owned_data);
            return false;
        };
        self.resp_mu.unlock();

        // Wake up the event loop
        const buf: [1]u8 = .{1};
        _ = std.posix.system.write(self.wakeup_write_fd, &buf, 1);

        return true;
    }
};
