// SPDX-License-Identifier: MIT
const std = @import("std");
const binary = @import("binary");

extern "c" fn fopen(filename: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fflush(stream: *anyopaque) c_int;
extern "c" fn fclose(stream: *anyopaque) c_int;

fn writeTemp(path: []const u8, data: []const u8) void {
    const f = fopen(@ptrCast(path.ptr), "wb") orelse return;
    _ = fwrite(data.ptr, 1, data.len, f);
    _ = fflush(f);
    _ = fclose(f);
}

test "readAll: text file" {
    const tmp = "/tmp/hawk_zig_test_text";
    writeTemp(tmp, "hello world");

    const allocator = std.testing.allocator;
    const content = try binary.readAll(allocator, tmp, 1048576);
    defer allocator.free(content);

    try std.testing.expectEqualSlices(u8, "hello world", content);
}

test "readAll: binary bytes (null bytes)" {
    const tmp = "/tmp/hawk_zig_test_bin";
    const data = &[_]u8{ 0x00, 0x01, 0xff, 0x7f, 0x80 };
    writeTemp(tmp, data);

    const allocator = std.testing.allocator;
    const content = try binary.readAll(allocator, tmp, 1048576);
    defer allocator.free(content);

    try std.testing.expectEqualSlices(u8, data, content);
}

test "readAll: missing file returns error" {
    const allocator = std.testing.allocator;
    const result = binary.readAll(allocator, "/tmp/hawk_zig_nonexistent_file", 1048576);
    try std.testing.expectError(error.FileNotFound, result);
}

test "readAll: file exceeds max_bytes returns FileTooLarge" {
    const tmp = "/tmp/hawk_zig_test_large";
    writeTemp(tmp, "abcde");

    const allocator = std.testing.allocator;
    const result = binary.readAll(allocator, tmp, 3); // max 3 bytes, file is 5
    try std.testing.expectError(error.FileTooLarge, result);
}

test "lengthBytes: ascii" {
    try std.testing.expectEqual(@as(usize, 5), binary.lengthBytes("hello"));
}

test "lengthBytes: binary bytes" {
    try std.testing.expectEqual(@as(usize, 3), binary.lengthBytes("\xff\xfe\xfd"));
}

test "lengthBytes: empty" {
    try std.testing.expectEqual(@as(usize, 0), binary.lengthBytes(""));
}
