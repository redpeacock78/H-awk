// SPDX-License-Identifier: MIT
const std = @import("std");
const ffi = @import("gawk_ffi");
const url = @import("url");

var _last_error: []const u8 = "";

fn urlEncode(args: ffi.Args) ffi.Result {
    const s = args.getString(0);
    const out = url.encode(ffi.gawkAllocator(), s) catch return .{ .string = "" };
    return .{ .gawk_string = out };
}

fn urlDecodeForm(args: ffi.Args) ffi.Result {
    const s = args.getString(0);
    const out = url.decode(ffi.gawkAllocator(), s, true) catch |err| {
        _last_error = switch (err) {
            url.DecodeError.InvalidPercentEncoding => "InvalidPercentEncoding",
            url.DecodeError.InvalidUtf8 => "InvalidUtf8",
            error.OutOfMemory => "OutOfMemory",
        };
        return .{ .string = "" };
    };
    _last_error = "";
    return .{ .gawk_string = out };
}

fn urlDecodeComponent(args: ffi.Args) ffi.Result {
    const s = args.getString(0);
    const out = url.decode(ffi.gawkAllocator(), s, false) catch |err| {
        _last_error = switch (err) {
            url.DecodeError.InvalidPercentEncoding => "InvalidPercentEncoding",
            url.DecodeError.InvalidUtf8 => "InvalidUtf8",
            error.OutOfMemory => "OutOfMemory",
        };
        return .{ .string = "" };
    };
    _last_error = "";
    return .{ .gawk_string = out };
}

fn urlError(_: ffi.Args) ffi.Result {
    return .{ .string = _last_error };
}

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_url",
    .functions = &.{
        .{ .name = "hawk_url_encode",           .impl = &urlEncode,          .args = 1 },
        .{ .name = "hawk_url_decode_form",      .impl = &urlDecodeForm,      .args = 1 },
        .{ .name = "hawk_url_decode_component", .impl = &urlDecodeComponent, .args = 1 },
        .{ .name = "hawk_url_error",            .impl = &urlError,           .args = 0 },
    },
});
comptime { _ = _ffi_entry; }
