// libs/net/src/conn_pool.zig
// SPDX-License-Identifier: MIT
const std = @import("std");

fn monoNanos() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

pub const ConnState = enum { reading, ready, closed };

pub const SimpleMutex = struct {
    locked: bool = false,

    pub fn lock(self: *SimpleMutex) void {
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .seq_cst)) {}
    }

    pub fn unlock(self: *SimpleMutex) void {
        @atomicStore(bool, &self.locked, false, .seq_cst);
    }
};

pub const Conn = struct {
    fd: std.posix.socket_t,
    state: ConnState,
    read_buf: std.ArrayList(u8),
    keep_alive: bool,
    last_used: i64,
};

pub const ConnPool = struct {
    alloc: std.mem.Allocator,
    conns: std.AutoHashMap(u64, Conn),
    next_id: u64,
    mu: SimpleMutex,

    pub fn init(alloc: std.mem.Allocator) ConnPool {
        return .{
            .alloc = alloc,
            .conns = std.AutoHashMap(u64, Conn).init(alloc),
            .next_id = 1,
            .mu = .{},
        };
    }

    pub fn deinit(self: *ConnPool) void {
        // Caller must ensure no concurrent access during teardown.
        var it = self.conns.valueIterator();
        while (it.next()) |conn| {
            conn.read_buf.deinit(self.alloc);
            // Note: close(fd) is not called here; caller is responsible for fd lifecycle
        }
        self.conns.deinit();
    }

    /// Add a new connection. Returns conn_id. Caller owns fd lifecycle via pool.
    pub fn add(self: *ConnPool, fd: std.posix.socket_t) !u64 {
        self.mu.lock();
        defer self.mu.unlock();
        const id = self.next_id;
        try self.conns.put(id, .{
            .fd = fd,
            .state = .reading,
            .read_buf = try std.ArrayList(u8).initCapacity(self.alloc, 0),
            .keep_alive = false,
            .last_used = monoNanos(),
        });
        self.next_id += 1;
        return id;
    }

    /// Remove and deinit a connection. No-op if id not found.
    /// Caller is responsible for closing the fd.
    pub fn remove(self: *ConnPool, id: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.conns.fetchRemove(id)) |kv| {
            var conn = kv.value;
            conn.read_buf.deinit(self.alloc);
        }
    }

    pub fn count(self: *ConnPool) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.conns.count();
    }
};
