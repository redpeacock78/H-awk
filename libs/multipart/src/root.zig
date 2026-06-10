// SPDX-License-Identifier: MIT
// libs/multipart/src/root.zig
const std = @import("std");
const ffi = @import("gawk_ffi");
const multipart = @import("multipart");

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_multipart",
    .functions = &.{
        .{ .name = "hawk_multipart_parse", .impl = &multipartParse, .args = 3 },
    },
});
comptime {
    _ = _ffi_entry;
}

// hawk_multipart_parse(body, boundary, req_array) → "1" (ok) / "0" (error)
fn multipartParse(args: ffi.Args) ffi.Result {
    const body = args.getString(0);
    const boundary = args.getString(1);
    const arr = args.getArray(2);
    if (arr == null) return .{ .string = "0" };

    const alloc = std.heap.c_allocator;
    const parts = multipart.parse(alloc, body, boundary) catch return .{ .string = "0" };
    defer multipart.freeParts(alloc, parts);

    for (parts) |part| {
        if (part.name.len == 0) continue;

        if (part.filename.len > 0) {
            // File field: write content, filename, content-type
            const file_key = std.fmt.allocPrint(alloc, "file:{s}", .{part.name}) catch continue;
            defer alloc.free(file_key);
            ffi.arraySet(arr, file_key, part.body);

            const fn_key = std.fmt.allocPrint(alloc, "file:{s}_filename", .{part.name}) catch continue;
            defer alloc.free(fn_key);
            ffi.arraySet(arr, fn_key, part.filename);

            const ct_key = std.fmt.allocPrint(alloc, "file:{s}_type", .{part.name}) catch continue;
            defer alloc.free(ct_key);
            ffi.arraySet(arr, ct_key, part.content_type);
        } else {
            // Text field
            const form_key = std.fmt.allocPrint(alloc, "form:{s}", .{part.name}) catch continue;
            defer alloc.free(form_key);
            ffi.arraySet(arr, form_key, part.body);
        }
    }

    return .{ .string = "1" };
}
