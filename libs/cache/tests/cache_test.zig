// SPDX-License-Identifier: MIT
const std = @import("std");
const cache = @import("cache");

test "set and get basic" {
    cache.init();
    defer cache.deinit();
    try cache.set("hello", "world", 60_000);
    const v = cache.get("hello");
    try std.testing.expectEqualStrings("world", v orelse return error.Miss);
}

test "get missing returns null" {
    cache.init();
    defer cache.deinit();
    const v = cache.get("no_such_key");
    try std.testing.expect(v == null);
}

test "del removes entry" {
    cache.init();
    defer cache.deinit();
    try cache.set("del_k", "v", 60_000);
    cache.del("del_k");
    try std.testing.expect(cache.get("del_k") == null);
}

test "TTL expiry" {
    cache.init();
    defer cache.deinit();
    try cache.set("exp_k", "v", 1); // 1ms TTL
    var ts = std.c.timespec{ .sec = 0, .nsec = 2_000_000 };
    _ = std.c.nanosleep(&ts, null);
    try std.testing.expect(cache.get("exp_k") == null);
}

test "has returns correct result" {
    cache.init();
    defer cache.deinit();
    try cache.set("has_k", "v", 60_000);
    try std.testing.expect(cache.has("has_k"));
    try std.testing.expect(!cache.has("no_has"));
}

test "tombstone: del does not break displaced key" {
    cache.init();
    defer cache.deinit();
    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    var ka: []const u8 = "";
    var kb: []const u8 = "";
    outer: for (0..2000) |i| {
        ka = std.fmt.bufPrint(&buf_a, "ck_{d}", .{i}) catch continue;
        const slot_a = cache.djb2(ka) % cache.SLOT_COUNT;
        for (i + 1..4000) |j| {
            kb = std.fmt.bufPrint(&buf_b, "ck_{d}", .{j}) catch continue;
            if (cache.djb2(kb) % cache.SLOT_COUNT == slot_a) break :outer;
        }
    }
    try std.testing.expect(ka.len > 0);

    try cache.set(ka, "val_a", 60_000);
    try cache.set(kb, "val_b", 60_000);

    cache.del(ka);

    const vb = cache.get(kb);
    try std.testing.expectEqualStrings("val_b", vb orelse return error.TombstoneBrokeProbChain);

    try std.testing.expect(cache.get(ka) == null);

    try cache.set(ka, "val_a2", 60_000);
    const va2 = cache.get(ka);
    try std.testing.expectEqualStrings("val_a2", va2 orelse return error.TombstoneReuseFailure);
}

test "parseCacheSize: default (null)" {
    try std.testing.expectEqual(@as(usize, 524288), cache.parseCacheSize(null));
}

test "parseCacheSize: 512K" {
    try std.testing.expectEqual(@as(usize, 524288), cache.parseCacheSize("512K"));
}

test "parseCacheSize: 512k lowercase" {
    try std.testing.expectEqual(@as(usize, 524288), cache.parseCacheSize("512k"));
}

test "parseCacheSize: 1M" {
    try std.testing.expectEqual(@as(usize, 1048576), cache.parseCacheSize("1M"));
}

test "parseCacheSize: 1m lowercase" {
    try std.testing.expectEqual(@as(usize, 1048576), cache.parseCacheSize("1m"));
}

test "parseCacheSize: raw bytes" {
    try std.testing.expectEqual(@as(usize, 1048576), cache.parseCacheSize("1048576"));
}

test "parseCacheSize: invalid default" {
    try std.testing.expectEqual(@as(usize, 524288), cache.parseCacheSize("nope"));
}

test "parseCacheSize: zero default" {
    try std.testing.expectEqual(@as(usize, 524288), cache.parseCacheSize("0"));
}

test "parseCacheSize: below min clamped to 64KB" {
    try std.testing.expectEqual(@as(usize, 65536), cache.parseCacheSize("1K"));
}

test "parseCacheSize: above max clamped to 64MB" {
    try std.testing.expectEqual(@as(usize, 67108864), cache.parseCacheSize("128M"));
}
