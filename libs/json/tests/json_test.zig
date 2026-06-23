const std = @import("std");
const json = @import("json");

test "valid json object" {
    try std.testing.expect(try json.valid(std.testing.allocator, "{\"a\":1}"));
}

test "valid json array" {
    try std.testing.expect(try json.valid(std.testing.allocator, "[1,true,null]"));
}

test "invalid json" {
    try std.testing.expect(!try json.valid(std.testing.allocator, "{invalid}"));
}
