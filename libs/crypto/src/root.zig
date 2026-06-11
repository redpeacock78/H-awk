// SPDX-License-Identifier: MIT
// libs/crypto/src/root.zig
const std = @import("std");
const ffi = @import("gawk_ffi");
const crypto = @import("crypto");

const _ffi_entry = ffi.makeDlLoad(.{
    .name = "hawk_crypto",
    .functions = &.{
        .{ .name = "hawk_sha256", .impl = &sha256Fn, .args = 1 },
        .{ .name = "hawk_hmac_sha256", .impl = &hmacSha256Fn, .args = 2 },
        .{ .name = "hawk_argon2id", .impl = &argon2idFn, .args = 1 },
        .{ .name = "hawk_argon2id_verify", .impl = &argon2idVerifyFn, .args = 2 },
        .{ .name = "hawk_ecdsa_sign", .impl = &ecdsaSignFn, .args = 2 },
        .{ .name = "hawk_ecdsa_verify", .impl = &ecdsaVerifyFn, .args = 3 },
    },
});
comptime {
    _ = _ffi_entry;
}

// hawk_sha256(data) → hex string (64 chars)
fn sha256Fn(args: ffi.Args) ffi.Result {
    const data = args.getString(0);
    const hex_bytes = crypto.sha256(data);
    // gawk copies the string immediately, so we can return a pointer to stack array
    return .{ .string = &hex_bytes };
}

// hawk_hmac_sha256(key, data) → hex string (64 chars)
fn hmacSha256Fn(args: ffi.Args) ffi.Result {
    const key = args.getString(0);
    const data = args.getString(1);
    const hex_bytes = crypto.hmacSha256(key, data);
    // gawk copies the string immediately, so we can return a pointer to stack array
    return .{ .string = &hex_bytes };
}

// hawk_argon2id(password) → "$argon2id$..." hash string or "" on error
fn argon2idFn(args: ffi.Args) ffi.Result {
    const password = args.getString(0);
    const alloc = std.heap.c_allocator;

    // Initialize Threaded IO instance for entropy
    var threaded_io = std.Io.Threaded.init(alloc, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const hash = crypto.argon2idHash(alloc, password, io) catch return .{ .string = "" };
    defer alloc.free(hash);
    const out = ffi.gawkAllocator().dupe(u8, hash) catch return .{ .string = "" };
    return .{ .gawk_string = out };
}

// hawk_argon2id_verify(hash, password) → "1" or "0"
fn argon2idVerifyFn(args: ffi.Args) ffi.Result {
    const hash = args.getString(0);
    const password = args.getString(1);
    const alloc = std.heap.c_allocator;

    // Initialize Threaded IO instance for entropy
    var threaded_io = std.Io.Threaded.init(alloc, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const ok = crypto.argon2idVerify(alloc, hash, password, io);
    return .{ .string = if (ok) "1" else "0" };
}

// hawk_ecdsa_sign(secret_key_b64url, data) → base64url signature or "" on error
fn ecdsaSignFn(args: ffi.Args) ffi.Result {
    const sk_b64 = args.getString(0);
    const data = args.getString(1);
    const alloc = std.heap.c_allocator;
    const b64 = std.base64.url_safe_no_pad;

    // Decode base64url secret key
    const sk_len = b64.Decoder.calcSizeForSlice(sk_b64) catch return .{ .string = "" };
    if (sk_len != 32) return .{ .string = "" };
    var sk_bytes: [32]u8 = undefined;
    b64.Decoder.decode(&sk_bytes, sk_b64) catch return .{ .string = "" };

    // Sign
    const sig = crypto.ecdsaSign(alloc, &sk_bytes, data) catch return .{ .string = "" };
    defer alloc.free(sig);
    const out = ffi.gawkAllocator().dupe(u8, sig) catch return .{ .string = "" };
    return .{ .gawk_string = out };
}

// hawk_ecdsa_verify(pub_key_b64url, data, sig_b64url) → "1" or "0"
fn ecdsaVerifyFn(args: ffi.Args) ffi.Result {
    const pk_b64 = args.getString(0);
    const data = args.getString(1);
    const sig_b64 = args.getString(2);
    const alloc = std.heap.c_allocator;
    const b64 = std.base64.url_safe_no_pad;

    // Decode base64url public key
    const pk_len = b64.Decoder.calcSizeForSlice(pk_b64) catch return .{ .string = "0" };
    if (pk_len != 65) return .{ .string = "0" };
    var pk_bytes: [65]u8 = undefined;
    b64.Decoder.decode(&pk_bytes, pk_b64) catch return .{ .string = "0" };

    // Verify
    const ok = crypto.ecdsaVerify(alloc, &pk_bytes, data, sig_b64);
    return .{ .string = if (ok) "1" else "0" };
}
