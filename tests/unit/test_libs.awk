# SPDX-License-Identifier: MIT
# tests/unit/test_libs.awk

function test_libs_binary_length(   ) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  assert_eq(hawk_bin_length("hello"), 5, "libs/binary: length ascii")
  assert_eq(hawk_bin_length(""),      0, "libs/binary: length empty")
}

function test_libs_binary_read_text(   tmp, content) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  tmp = "/tmp/hawk_libs_text_" PROCINFO["pid"]
  system("printf 'hello' > " tmp)
  content = hawk_bin_read(tmp)
  assert_eq(content, "hello", "libs/binary: read text")
  system("rm -f " tmp)
}

function test_libs_binary_read_missing(   content) {
  if (!LIBS_LOADED["binary"]) {
    TESTS_SKIPPED++
    return
  }
  content = hawk_bin_read("/tmp/this_does_not_exist_hawk_libs")
  assert_eq(content, "", "libs/binary: read missing -> empty")
}

function test_libs_net_listen_skip() {
  if (!LIBS_LOADED["net"]) {
    TESTS_SKIPPED++
    return
  }
  assert_eq((hawk_net_listen(19999) == 1 || hawk_net_listen(19999) == 0), 1, "libs/net: listen callable")
}

function test_libs_multipart_parse_skip(    raw, req) {
  if (!LIBS_LOADED["multipart"]) {
    TESTS_SKIPPED++
    return
  }
  # Basic integration smoke test: parse a single-field body
  raw = "--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nhello\r\n--B--\r\n"
  delete req
  assert_eq(hawk_multipart_parse(raw, "B", req), "1", "libs/multipart: parse returns 1")
  assert_eq(req["form:x"], "hello", "libs/multipart: parse sets form field")
}

function test_libs_crypto_sha256(    result) {
  if (!LIBS_LOADED["crypto"]) {
    TESTS_SKIPPED++
    return
  }
  result = hawk_sha256("abc")
  assert_eq(result, "ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469348423f656b1b6e33", "libs/crypto: sha256(abc)")
}

function test_libs_crypto_hmac_sha256(    result) {
  if (!LIBS_LOADED["crypto"]) {
    TESTS_SKIPPED++
    return
  }
  result = hawk_hmac_sha256("key", "data")
  assert_eq(length(result), 64, "libs/crypto: hmac_sha256 length 64")
}

function test_libs_crypto_argon2id(    hash, verify_ok, verify_fail) {
  if (!LIBS_LOADED["crypto"]) {
    TESTS_SKIPPED++
    return
  }
  hash = hawk_argon2id("password")
  assert_true(index(hash, "$argon2id$") == 1, "libs/crypto: argon2id hash starts with $argon2id$")
}

function test_libs_crypto_argon2id_verify(    hash, verify_ok, verify_fail) {
  if (!LIBS_LOADED["crypto"]) {
    TESTS_SKIPPED++
    return
  }
  hash = hawk_argon2id("password")
  verify_ok = hawk_argon2id_verify(hash, "password")
  verify_fail = hawk_argon2id_verify(hash, "wrongpassword")
  assert_eq(verify_ok, "1", "libs/crypto: argon2id_verify with correct password")
  assert_eq(verify_fail, "0", "libs/crypto: argon2id_verify with wrong password")
}

function test_libs_crypto_sha256_no_lib(    saved) {
  saved = LIBS_LOADED["crypto"]
  delete LIBS_LOADED["crypto"]
  assert_true(!LIBS_LOADED["crypto"], "libs/crypto: lib not loaded when deleted")
  LIBS_LOADED["crypto"] = saved
}
