// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn valid(allocator: std.mem.Allocator, s: []const u8) !bool {
    return std.json.validate(allocator, s);
}
