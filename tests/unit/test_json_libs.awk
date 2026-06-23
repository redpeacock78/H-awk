# SPDX-License-Identifier: MIT
# tests/unit/test_json_libs.awk -- libs/json integration tests

function test_json_valid_object(   r) {
  if (!LIBS_LOADED["json"]) { TESTS_SKIPPED++; return }
  r = json_decode("{\"a\":1}", _out)
  assert_eq(r, 1, "json_decode: valid object")
}

function test_json_decode_invalid(   r) {
  if (!LIBS_LOADED["json"]) { TESTS_SKIPPED++; return }
  r = json_decode("{invalid}", _out)
  assert_eq(r, 0, "json_decode: invalid returns 0")
  assert_eq(length(HAWK_JSON_ERROR) > 0, 1, "json_decode: error set")
}
