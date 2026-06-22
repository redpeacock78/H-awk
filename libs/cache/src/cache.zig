// SPDX-License-Identifier: MIT
// libs/cache/src/cache.zig -- file-backed mmap shared cache (with heap fallback)

const std = @import("std");

pub const KEY_MAX: u32 = 128;
pub const VAL_MAX: u32 = 512;

pub const CACHE_MAGIC:   u32 = 0x4841574b; // "HAWK"
pub const CACHE_VERSION: u16 = 1;

pub const CacheHeader = extern struct {
    magic:       u32,
    version:     u16,
    header_size: u16,
    total_size:  u64,
    slot_count:  u32,
    key_max:     u32,
    val_max:     u32,
    flags:       u32,
    initialized: u32,
    _pad:        [4]u8,
};

const Entry = extern struct {
    hash:       u64,
    key_len:    u32,
    val_len:    u32,
    expires_at: i64,
    flags:      u32,
    _pad:       u32,
    key:        [KEY_MAX]u8,
    val:        [VAL_MAX]u8,
};

var g_inited:    bool = false;
var g_is_shared: bool = false;
var g_header:    ?*CacheHeader = null;
var g_slots:     ?[*]Entry     = null;
var g_mmap_mem:  ?[]align(std.heap.page_size_min) u8 = null;
var g_local_mem: ?[]u8 = null;
var g_lock_fd:   ?std.c.fd_t = null;

// gawk は worker ごとに single-threaded なので静的バッファは安全
var get_result_buf: [VAL_MAX]u8 = undefined;

const DEFAULT_CACHE_SIZE: usize = 512 * 1024;
const MIN_CACHE_SIZE:     usize = 64  * 1024;
const MAX_CACHE_SIZE:     usize = 64  * 1024 * 1024;

const FLAG_LIVE:      u32 = 1;
const FLAG_TOMBSTONE: u32 = 2;

pub fn init() void {
    if (g_inited) return;
    const size = parseCacheSize(std.c.getenv("HAWK_SHARED_CACHE_SIZE"));

    if (std.c.getenv("HAWK_RUN_DIR")) |run_dir_ptr| {
        const run_dir = std.mem.sliceTo(run_dir_ptr, 0);
        if (tryMmapInit(run_dir, size)) {
            g_inited = true;
            return;
        }
        const supervised = if (std.c.getenv("HAWK_SUPERVISED")) |p|
            std.mem.eql(u8, std.mem.sliceTo(p, 0), "1") else false;
        const workers: usize = if (std.c.getenv("HAWK_WORKERS")) |p|
            std.fmt.parseInt(usize, std.mem.sliceTo(p, 0), 10) catch 1 else 1;
        if (supervised or workers > 1) {
            std.debug.print("[hawk] cache: shared mmap init failed in multi-worker mode; aborting\n", .{});
            std.process.exit(1);
        }
    }
    localInit(size);
    g_inited = true;
}

pub fn deinit() void {
    if (!g_inited) return;
    if (g_mmap_mem)  |m|  { std.posix.munmap(m); g_mmap_mem  = null; }
    if (g_local_mem) |m|  { std.heap.page_allocator.free(m); g_local_mem = null; }
    if (g_lock_fd) |fd| { _ = std.c.close(fd); g_lock_fd = null; }
    g_header    = null;
    g_slots     = null;
    g_inited    = false;
    g_is_shared = false;
}

pub fn set(key: []const u8, val: []const u8, ttl_ms: i64) !void {
    if (key.len > KEY_MAX or val.len > VAL_MAX) return error.TooLarge;
    if (!lockAcquire()) return error.LockFailed;
    defer lockRelease();
    const slot_count = g_header.?.slot_count;
    const h = djb2(key);
    var i: usize = @intCast(h % @as(u64, slot_count));
    var probes: usize = 0;
    var tombstone_i: ?usize = null;
    while (probes < slot_count) : ({ i = (i + 1) % slot_count; probes += 1; }) {
        const e = &g_slots.?[i];
        if (isTombstone(e)) {
            if (tombstone_i == null) tombstone_i = i;
            continue;
        }
        if (isExpired(e)) {
            e.key_len = 0;
            e.flags   = FLAG_TOMBSTONE;
            if (tombstone_i == null) tombstone_i = i;
            continue;
        }
        if (isEmpty(e)) {
            writeEntry(&g_slots.?[tombstone_i orelse i], h, key, val, ttl_ms);
            return;
        }
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            writeEntry(e, h, key, val, ttl_ms);
            return;
        }
    }
    if (tombstone_i) |ti| { writeEntry(&g_slots.?[ti], h, key, val, ttl_ms); return; }
    return error.Full;
}

pub fn get(key: []const u8) ?[]const u8 {
    if (!lockAcquire()) return null;
    defer lockRelease();
    const slot_count = g_header.?.slot_count;
    const h = djb2(key);
    var i: usize = @intCast(h % @as(u64, slot_count));
    var probes: usize = 0;
    while (probes < slot_count) : ({ i = (i + 1) % slot_count; probes += 1; }) {
        const e = &g_slots.?[i];
        if (isTombstone(e)) continue;
        if (isEmpty(e)) return null;
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            if (isExpired(e)) {
                e.key_len = 0;
                e.flags   = FLAG_TOMBSTONE;
                return null;
            }
            const len = e.val_len;
            @memcpy(get_result_buf[0..len], e.val[0..len]);
            return get_result_buf[0..len];
        }
    }
    return null;
}

pub fn del(key: []const u8) void {
    if (!lockAcquire()) return;
    defer lockRelease();
    const slot_count = g_header.?.slot_count;
    const h = djb2(key);
    var i: usize = @intCast(h % @as(u64, slot_count));
    var probes: usize = 0;
    while (probes < slot_count) : ({ i = (i + 1) % slot_count; probes += 1; }) {
        const e = &g_slots.?[i];
        if (isTombstone(e)) continue;
        if (isEmpty(e)) return;
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            e.key_len = 0;
            e.flags   = FLAG_TOMBSTONE;
            return;
        }
    }
}

pub fn has(key: []const u8) bool {
    return get(key) != null;
}

pub fn isShared() bool   { return g_is_shared; }
pub fn getCacheSize() u64 { return if (g_header) |h| h.total_size else 0; }
pub fn slotCount() u32    { return if (g_header) |h| h.slot_count else 0; }

pub fn djb2(key: []const u8) u64 {
    var h: u64 = 5381;
    for (key) |c| h = h *% 33 +% c;
    return h;
}

pub fn parseCacheSize(env_val: ?[*:0]const u8) usize {
    const raw: []const u8 = if (env_val) |p| std.mem.sliceTo(p, 0) else return alignToPage(DEFAULT_CACHE_SIZE);
    if (raw.len == 0) return alignToPage(DEFAULT_CACHE_SIZE);
    var multiplier: usize = 1;
    var num_part = raw;
    if (raw.len > 0) {
        const last = raw[raw.len - 1];
        if (last == 'K' or last == 'k') {
            multiplier = 1024;
            num_part = raw[0 .. raw.len - 1];
        } else if (last == 'M' or last == 'm') {
            multiplier = 1024 * 1024;
            num_part = raw[0 .. raw.len - 1];
        }
    }
    const n = std.fmt.parseInt(usize, num_part, 10) catch return alignToPage(DEFAULT_CACHE_SIZE);
    if (n == 0) return alignToPage(DEFAULT_CACHE_SIZE);
    const bytes = n *| multiplier;
    const clamped = @min(@max(bytes, MIN_CACHE_SIZE), MAX_CACHE_SIZE);
    return alignToPage(clamped);
}

fn alignToPage(size: usize) usize {
    const page = std.heap.pageSize();
    return (size + page - 1) & ~(page - 1);
}

fn lockAcquire() bool {
    if (g_lock_fd) |fd| {
        if (std.c.flock(fd, std.posix.LOCK.EX) != 0) return false;
    }
    return true;
}

fn lockRelease() void {
    if (g_lock_fd) |fd| _ = std.c.flock(fd, std.posix.LOCK.UN);
}

fn tryMmapInit(run_dir: []const u8, size: usize) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const cache_dir = std.fmt.bufPrintZ(&buf, "{s}/cache", .{run_dir}) catch return false;
    if (std.c.mkdir(cache_dir.ptr, 0o700) != 0 and std.c.errno(-1) != .EXIST) return false;

    const lock_path = std.fmt.bufPrintZ(&buf, "{s}/cache/shared-cache.lock", .{run_dir}) catch return false;
    const lock_fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (lock_fd < 0) return false;

    if (std.c.flock(lock_fd, std.posix.LOCK.EX) != 0) {
        _ = std.c.close(lock_fd);
        return false;
    }

    const cache_path = std.fmt.bufPrintZ(&buf, "{s}/cache/shared-cache.bin", .{run_dir}) catch {
        _ = std.c.flock(lock_fd, std.posix.LOCK.UN);
        _ = std.c.close(lock_fd);
        return false;
    };
    const cache_fd = std.c.open(cache_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (cache_fd < 0) {
        _ = std.c.flock(lock_fd, std.posix.LOCK.UN);
        _ = std.c.close(lock_fd);
        return false;
    }
    defer _ = std.c.close(cache_fd);

    if (std.c.ftruncate(cache_fd, @intCast(size)) != 0) {
        _ = std.c.flock(lock_fd, std.posix.LOCK.UN);
        _ = std.c.close(lock_fd);
        return false;
    }

    const mem = std.posix.mmap(
        null, size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        std.posix.MAP{ .TYPE = .SHARED },
        cache_fd, 0,
    ) catch {
        _ = std.c.flock(lock_fd, std.posix.LOCK.UN);
        _ = std.c.close(lock_fd);
        return false;
    };

    g_lock_fd = lock_fd;
    setupMemory(mem.ptr, size);
    lockRelease();

    g_mmap_mem  = mem;
    g_is_shared = true;
    return true;
}

fn localInit(size: usize) void {
    const mem = std.heap.page_allocator.alloc(u8, size) catch @panic("[hawk] cache: local init failed");
    @memset(mem, 0);
    setupMemory(mem.ptr, size);
    g_local_mem = mem;
    g_is_shared = false;
}

fn setupMemory(ptr: [*]u8, size: usize) void {
    const header: *CacheHeader = @ptrCast(@alignCast(ptr));
    const slot_count = @as(u32, @intCast((size - @sizeOf(CacheHeader)) / @sizeOf(Entry)));

    if (header.magic        != CACHE_MAGIC or
        header.version      != CACHE_VERSION or
        header.header_size  != @as(u16, @intCast(@sizeOf(CacheHeader))) or
        header.total_size   != size or
        header.slot_count   != slot_count or
        header.key_max      != KEY_MAX or
        header.val_max      != VAL_MAX or
        header.initialized  != 1)
    {
        @memset(ptr[0..size], 0);
        header.initialized = 0;
        header.magic       = CACHE_MAGIC;
        header.version     = CACHE_VERSION;
        header.header_size = @intCast(@sizeOf(CacheHeader));
        header.total_size  = size;
        header.slot_count  = slot_count;
        header.key_max     = KEY_MAX;
        header.val_max     = VAL_MAX;
        header.initialized = 1;
    }

    g_header = header;
    g_slots  = @ptrCast(@alignCast(ptr + @sizeOf(CacheHeader)));
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) @panic("clock_gettime failed");
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn isExpired(e: *const Entry) bool {
    if (e.expires_at == 0) return false;
    return nowMs() >= e.expires_at;
}

fn isEmpty(e: *const Entry) bool {
    return (e.flags & FLAG_TOMBSTONE) == 0 and e.key_len == 0;
}

fn isTombstone(e: *const Entry) bool {
    return (e.flags & FLAG_TOMBSTONE) != 0;
}

fn writeEntry(e: *Entry, h: u64, key: []const u8, val: []const u8, ttl_ms: i64) void {
    e.hash       = h;
    e.key_len    = @intCast(key.len);
    e.val_len    = @intCast(val.len);
    e.expires_at = if (ttl_ms > 0) nowMs() +| ttl_ms else 0;
    e.flags      = FLAG_LIVE;
    @memcpy(e.key[0..key.len], key);
    @memcpy(e.val[0..val.len], val);
}
