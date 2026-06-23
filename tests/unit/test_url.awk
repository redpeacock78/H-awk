# SPDX-License-Identifier: MIT
# tests/unit/test_url.awk -- URL encode/decode unit tests

function test_url_encode(   out) {
  out = url_encode("a b")
  assert_eq(out, "a%20b", "url_encode: space")
}

function test_url_encode_japanese(   out) {
  out = url_encode("あ")
  assert_eq(out, "%E3%81%82", "url_encode: japanese (fallback)")
  if (LIBS_LOADED["url"]) {
    out = hawk_url_encode("あ")
    assert_eq(out, "%E3%81%82", "url_encode: japanese (zig)")
  }
}

function test_url_decode_form(   out) {
  out = url_decode_form("a+b")
  assert_eq(out, "a b", "url_decode_form: plus sign")
}

function test_url_decode_percent(   out) {
  out = url_decode_form("%E3%81%82")
  assert_eq(out, "あ", "url_decode_form: japanese utf8 (fallback)")
  if (LIBS_LOADED["url"]) {
    out = hawk_url_decode_form("%E3%81%82")
    assert_eq(out, "あ", "url_decode_form: japanese utf8 (zig)")
  }
}

function test_url_decode_invalid(   out) {
  url_decode_form("%ZZ")
  assert_eq(HAWK_URL_ERROR, "InvalidPercentEncoding", "url_decode: invalid percent")
}

function test_url_decode_truncated(   out) {
  url_decode_form("%A")
  assert_eq(HAWK_URL_ERROR, "InvalidPercentEncoding", "url_decode: truncated percent")
}
