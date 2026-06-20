// SPDX-License-Identifier: MIT
// libs/cache/src/cache.zig -- fixed-slot hash table cache

const std = @import("std");

pub const SLOT_COUNT = 4096;
pub const KEY_MAX    = 128;
pub const VAL_MAX    = 2048;

const Entry = extern struct {
    hash:       u64,
    key_len:    u32,
    val_len:    u32,
    expires_at: i64,
    flags:      u32,
    key:        [KEY_MAX]u8,
    val:        [VAL_MAX]u8,
};

var slots: [SLOT_COUNT]Entry = undefined;
var inited: bool = false;

pub fn init() void {
    @memset(std.mem.asBytes(&slots), 0);
    inited = true;
}

pub fn deinit() void {
    inited = false;
}

const FLAG_LIVE: u32 = 1;
const FLAG_TOMBSTONE: u32 = 2;

pub fn djb2(key: []const u8) u64 {
    var h: u64 = 5381;
    for (key) |c| h = h *% 33 +% c;
    return h;
}

fn nowMs() i64 {
    return @divFloor(std.time.nanoTimestamp(), 1_000_000);
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
    e.hash = h;
    e.key_len = @intCast(key.len);
    e.val_len = @intCast(val.len);
    e.expires_at = if (ttl_ms > 0) nowMs() + ttl_ms else 0;
    e.flags = FLAG_LIVE;
    @memcpy(e.key[0..key.len], key);
    @memcpy(e.val[0..val.len], val);
}

pub fn set(key: []const u8, val: []const u8, ttl_ms: i64) !void {
    if (key.len > KEY_MAX or val.len > VAL_MAX) return error.TooLarge;
    const h = djb2(key);
    var i = @as(usize, @intCast(h % SLOT_COUNT));
    var probes: usize = 0;
    var tombstone_i: ?usize = null;
    while (probes < SLOT_COUNT) : ({ i = (i + 1) % SLOT_COUNT; probes += 1; }) {
        const e = &slots[i];
        if (isTombstone(e)) {
            if (tombstone_i == null) tombstone_i = i;
            continue;
        }
        if (isEmpty(e)) {
            writeEntry(&slots[tombstone_i orelse i], h, key, val, ttl_ms);
            return;
        }
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            writeEntry(e, h, key, val, ttl_ms);
            return;
        }
    }
    if (tombstone_i) |ti| {
        writeEntry(&slots[ti], h, key, val, ttl_ms);
        return;
    }
    return error.Full;
}

pub fn get(key: []const u8) ?[]const u8 {
    const h = djb2(key);
    var i = @as(usize, @intCast(h % SLOT_COUNT));
    var probes: usize = 0;
    while (probes < SLOT_COUNT) : ({ i = (i + 1) % SLOT_COUNT; probes += 1; }) {
        const e = &slots[i];
        if (isTombstone(e)) continue;
        if (isEmpty(e)) return null;
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            if (isExpired(e)) {
                e.key_len = 0;
                e.flags = FLAG_TOMBSTONE;
                return null;
            }
            return e.val[0..e.val_len];
        }
    }
    return null;
}

pub fn del(key: []const u8) void {
    const h = djb2(key);
    var i = @as(usize, @intCast(h % SLOT_COUNT));
    var probes: usize = 0;
    while (probes < SLOT_COUNT) : ({ i = (i + 1) % SLOT_COUNT; probes += 1; }) {
        const e = &slots[i];
        if (isTombstone(e)) continue;
        if (isEmpty(e)) return;
        if (e.hash == h and e.key_len == key.len and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            e.key_len = 0;
            e.flags = FLAG_TOMBSTONE;
            return;
        }
    }
}

pub fn has(key: []const u8) bool {
    return get(key) != null;
}
