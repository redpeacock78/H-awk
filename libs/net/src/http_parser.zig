// SPDX-License-Identifier: MIT
const std = @import("std");

pub const Request = struct {
    conn_id: u64,
    method: []const u8,
    path: []const u8,
    headers_block: []const u8,
    body: []const u8,
    keep_alive: bool,
    content_length: usize,

    pub fn deinit(self: Request, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.path);
        alloc.free(self.headers_block);
        alloc.free(self.body);
    }
};

/// Parse raw HTTP/1.1 request bytes. Returns owned Request; caller calls deinit.
pub fn parse(buf: []const u8, conn_id: u64, alloc: std.mem.Allocator) !Request {
    const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.InvalidRequest;
    const headers_section = buf[0..sep];
    const body_raw = buf[sep + 4 ..];

    const first_crlf = std.mem.indexOf(u8, headers_section, "\r\n") orelse headers_section.len;
    const request_line = headers_section[0..first_crlf];

    var it = std.mem.splitScalar(u8, request_line, ' ');
    const method = it.next() orelse return error.InvalidRequest;
    const path = it.next() orelse return error.InvalidRequest;
    if (method.len == 0 or path.len == 0) return error.InvalidRequest;

    // headers_block includes the CRLF separators from the headers section (after request line) plus the final CRLF
    var headers_block_raw: []const u8 = "";
    if (first_crlf + 2 <= headers_section.len) {
        headers_block_raw = headers_section[first_crlf + 2 ..];
    }

    var content_length: usize = 0;
    var keep_alive = false;
    var hdr_it = std.mem.splitSequence(u8, headers_block_raw, "\r\n");
    while (hdr_it.next()) |hline| {
        if (hline.len == 0) continue;
        const colon = std.mem.indexOf(u8, hline, ":") orelse continue;
        const hname = std.mem.trim(u8, hline[0..colon], " ");
        const hval = std.mem.trim(u8, hline[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(hname, "content-length")) {
            content_length = std.fmt.parseInt(usize, hval, 10) catch 0;
        }
        if (std.ascii.eqlIgnoreCase(hname, "connection")) {
            keep_alive = std.ascii.eqlIgnoreCase(hval, "keep-alive");
        }
    }

    const body = body_raw[0..@min(content_length, body_raw.len)];

    // headers_block includes the headers with their trailing CRLF
    const headers_block = try alloc.dupe(u8, if (headers_block_raw.len > 0)
        buf[first_crlf + 2 .. sep + 2]
    else
        "");

    return .{
        .conn_id = conn_id,
        .method = try alloc.dupe(u8, method),
        .path = try alloc.dupe(u8, path),
        .headers_block = headers_block,
        .body = try alloc.dupe(u8, body),
        .keep_alive = keep_alive,
        .content_length = content_length,
    };
}

/// Format poll result string for AWK.
/// Format: conn_id RS method RS path RS headers_block RS body_len RS body
/// RS = \x1e (ASCII Record Separator). Caller owns returned slice.
pub fn formatPollResult(req: Request, alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{d}\x1e{s}\x1e{s}\x1e{s}\x1e{d}\x1e{s}", .{
        req.conn_id,
        req.method,
        req.path,
        req.headers_block,
        req.body.len,
        req.body,
    });
}
