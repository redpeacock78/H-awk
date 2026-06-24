// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn valid(allocator: std.mem.Allocator, s: []const u8) !bool {
    return std.json.validate(allocator, s);
}

// 有効な JSON 文字列なら gawk allocator で複製して返す。無効なら null。
pub fn encode(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    const ok = std.json.validate(allocator, s) catch return error.OutOfMemory;
    if (!ok) return null;
    return try allocator.dupe(u8, s);
}

// JSON を parse し key\x1f value\x1e 形式のフラット表現を返す。
// dot-path キー（"user.name", "tags.0"）で全ネストを平坦化する。
// 制限: キーや文字列値に \x1e (RS=0x1e) が含まれる場合は未定義動作。
pub fn decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, s, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try flattenValue(allocator, parsed.value, "", &out);
    return out.toOwnedSlice(allocator);
}

fn flattenValue(allocator: std.mem.Allocator, val: std.json.Value, path: []const u8, out: *std.ArrayList(u8)) !void {
    switch (val) {
        .object => |obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const child = if (path.len == 0)
                    try std.fmt.allocPrint(allocator, "{s}", .{entry.key_ptr.*})
                else
                    try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                defer allocator.free(child);
                try flattenValue(allocator, entry.value_ptr.*, child, out);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, idx| {
                const child = if (path.len == 0)
                    try std.fmt.allocPrint(allocator, "{d}", .{idx})
                else
                    try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, idx });
                defer allocator.free(child);
                try flattenValue(allocator, item, child, out);
            }
        },
        .string => |str| {
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\x1f');
            try out.appendSlice(allocator, str);
            try out.append(allocator, '\x1e');
        },
        .integer => |n| {
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\x1f');
            const ns = try std.fmt.allocPrint(allocator, "{d}", .{n});
            defer allocator.free(ns);
            try out.appendSlice(allocator, ns);
            try out.append(allocator, '\x1e');
        },
        .float => |f| {
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\x1f');
            const fs = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(fs);
            try out.appendSlice(allocator, fs);
            try out.append(allocator, '\x1e');
        },
        .number_string => |n| {
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\x1f');
            try out.appendSlice(allocator, n);
            try out.append(allocator, '\x1e');
        },
        .bool => |b| {
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\x1f');
            try out.appendSlice(allocator, if (b) "true" else "false");
            try out.append(allocator, '\x1e');
        },
        .null => {
            try out.appendSlice(allocator, path);
            try out.append(allocator, '\x1f');
            try out.appendSlice(allocator, "null");
            try out.append(allocator, '\x1e');
        },
    }
}
