// SPDX-License-Identifier: MIT
// libs/multipart/src/multipart.zig
// Pure-Zig multipart/form-data parser. No gawk dependency.
const std = @import("std");

pub const Part = struct {
    name: []u8,
    filename: []u8,
    content_type: []u8,
    body: []u8,
};

pub fn freeParts(allocator: std.mem.Allocator, parts: []Part) void {
    for (parts) |p| {
        allocator.free(p.name);
        allocator.free(p.filename);
        allocator.free(p.content_type);
        allocator.free(p.body);
    }
    allocator.free(parts);
}

pub fn parse(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) ![]Part {
    // Delimiter: "--" + boundary + "\r\n" opens first part
    const open = try std.mem.concat(allocator, u8, &.{ "--", boundary, "\r\n" });
    defer allocator.free(open);
    // Between parts: "\r\n--" + boundary
    const mid = try std.mem.concat(allocator, u8, &.{ "\r\n--", boundary });
    defer allocator.free(mid);

    const first = std.mem.indexOf(u8, body, open) orelse return error.NoBoundary;
    var remaining = body[first + open.len ..];

    var list: std.ArrayList(Part) = .empty;
    errdefer {
        for (list.items) |p| {
            allocator.free(p.name);
            allocator.free(p.filename);
            allocator.free(p.content_type);
            allocator.free(p.body);
        }
        list.deinit(allocator);
    }

    while (remaining.len > 0) {
        const end = std.mem.indexOf(u8, remaining, mid) orelse {
            // Last part (no mid delimiter found)
            if (remaining.len > 0) {
                const p = try parsePart(allocator, remaining);
                try list.append(allocator, p);
            }
            break;
        };
        const p = try parsePart(allocator, remaining[0..end]);
        try list.append(allocator, p);
        remaining = remaining[end + mid.len ..];
        // After mid: either "--\r\n" (next part) or "--" (final boundary)
        if (std.mem.startsWith(u8, remaining, "--")) break;
        if (std.mem.startsWith(u8, remaining, "\r\n")) remaining = remaining[2..];
    }

    return list.toOwnedSlice(allocator);
}

fn parsePart(allocator: std.mem.Allocator, part: []const u8) !Part {
    const sep = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, part, sep) orelse return error.MalformedPart;
    const headers_raw = part[0..header_end];
    const body = part[header_end + sep.len ..];

    var name: []const u8 = "";
    var filename: []const u8 = "";
    var content_type: []const u8 = "application/octet-stream";

    var line_iter = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (line_iter.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        const hval = std.mem.trim(u8, line[colon + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(hname, "content-disposition")) {
            name = extractParam(hval, "name") orelse "";
            filename = extractParam(hval, "filename") orelse "";
        } else if (std.ascii.eqlIgnoreCase(hname, "content-type")) {
            content_type = hval;
        }
    }

    const duped_name = try allocator.dupe(u8, name);
    errdefer allocator.free(duped_name);
    const duped_filename = try allocator.dupe(u8, filename);
    errdefer allocator.free(duped_filename);
    const duped_ct = try allocator.dupe(u8, content_type);
    errdefer allocator.free(duped_ct);
    const duped_body = try allocator.dupe(u8, body);
    return Part{ .name = duped_name, .filename = duped_filename, .content_type = duped_ct, .body = duped_body };
}

/// Extract param value from Content-Disposition header value.
/// e.g. extractParam(`form-data; name="foo"`, "name") -> "foo"
fn extractParam(header: []const u8, param: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "{s}=\"", .{param}) catch return null;
    const pos = std.mem.indexOf(u8, header, needle) orelse return null;
    const value_start = pos + needle.len;
    const value_end = std.mem.indexOfScalarPos(u8, header, value_start, '"') orelse return null;
    return header[value_start..value_end];
}
