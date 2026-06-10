// SPDX-License-Identifier: MIT
const std = @import("std");
const crypto = @import("crypto");

test "sha256 known vector" {
    const alloc = std.testing.allocator;
    _ = alloc;
    const hex = crypto.sha256("abc");
    // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "sha256 length is 64" {
    const hex = crypto.sha256("hello");
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}

test "hmac_sha256 length is 64" {
    const hex = crypto.hmacSha256("key", "data");
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}

test "hmac_sha256 known vector" {
    // HMAC-SHA256("key", "The quick brown fox jumps over the lazy dog")
    // = f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
    const hex = crypto.hmacSha256("key", "The quick brown fox jumps over the lazy dog");
    try std.testing.expectEqualStrings(
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
        &hex,
    );
}

test "argon2id hash and verify" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const hash = try crypto.argon2idHash(alloc, "testpassword", io);
    defer alloc.free(hash);
    try std.testing.expect(std.mem.startsWith(u8, hash, "$argon2id$"));
    const ok = crypto.argon2idVerify(alloc, hash, "testpassword", io);
    try std.testing.expect(ok);
    const bad = crypto.argon2idVerify(alloc, hash, "wrongpassword", io);
    try std.testing.expect(!bad);
}

test "ecdsa sign and verify" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const kp = crypto.ecdsaGenKey(io);
    const message = "test payload";
    const sig = try crypto.ecdsaSign(alloc, &kp.secret_key_bytes, message);
    defer alloc.free(sig);
    const ok = crypto.ecdsaVerify(alloc, &kp.public_key_bytes, message, sig);
    try std.testing.expect(ok);
}

test "ecdsa verify fails on tampered message" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const kp = crypto.ecdsaGenKey(io);
    const sig = try crypto.ecdsaSign(alloc, &kp.secret_key_bytes, "original");
    defer alloc.free(sig);
    const ok = crypto.ecdsaVerify(alloc, &kp.public_key_bytes, "tampered", sig);
    try std.testing.expect(!ok);
}
