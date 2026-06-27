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

// JSON を parse し base64(key)\x1fbase64(value)\x1ftype\x1e 形式のフラット表現を返す。
// dot-path キー（"user.name", "tags.0"）で全ネストを平坦化する。
// key および value は Base64 で encode するため任意のバイト列を安全に運べる。
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
        .string => |str| try emitLeaf(allocator, out, path, str, "string"),
        .integer => |n| {
            const ns = try std.fmt.allocPrint(allocator, "{d}", .{n});
            defer allocator.free(ns);
            try emitLeaf(allocator, out, path, ns, "int");
        },
        .float => |f| {
            const fs = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(fs);
            try emitLeaf(allocator, out, path, fs, "float");
        },
        .number_string => |n| try emitLeaf(allocator, out, path, n, if (isIntLiteral(n)) "int" else "float"),
        .bool => |b| try emitLeaf(allocator, out, path, if (b) "true" else "false", "bool"),
        .null => try emitLeaf(allocator, out, path, "", "null"),
    }
}

fn emitLeaf(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    typ: []const u8,
) !void {
    try writeBase64(allocator, out, key);
    try out.append(allocator, '\x1f');
    try writeBase64(allocator, out, value);
    try out.append(allocator, '\x1f');
    try out.appendSlice(allocator, typ);
    try out.append(allocator, '\x1e');
}

fn writeBase64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = std.base64.standard.Encoder.encode(buf, bytes);
    try out.appendSlice(allocator, buf);
}

fn isIntLiteral(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, ".eE") == null;
}
