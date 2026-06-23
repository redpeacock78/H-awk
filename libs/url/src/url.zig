// SPDX-License-Identifier: MIT
// libs/url/src/url.zig -- URL encode/decode
const std = @import("std");

/// RFC 3986 percent-encode
pub fn encode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const DecodeError = error{ InvalidPercentEncoding, InvalidUtf8 };

/// Percent decode. Converts '+' to ' ' when form_mode is true.
pub fn decode(alloc: std.mem.Allocator, s: []const u8, form_mode: bool) (DecodeError || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (form_mode and c == '+') {
            try out.append(alloc, ' ');
            i += 1;
        } else if (c == '%') {
            if (i + 2 >= s.len) return DecodeError.InvalidPercentEncoding;
            const hi = hexDigit(s[i + 1]) orelse return DecodeError.InvalidPercentEncoding;
            const lo = hexDigit(s[i + 2]) orelse return DecodeError.InvalidPercentEncoding;
            try out.append(alloc, hi * 16 + lo);
            i += 3;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
