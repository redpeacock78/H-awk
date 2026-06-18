# SPDX-License-Identifier: MIT
function test_adt_result_ok_roundtrip(    r) {
  r = result_ok_make("hello world")
  assert_eq(result_val(r), "hello world", "adt: ok round-trip plain")
}

function test_adt_result_ok_xif_roundtrip(    r) {
  r = result_ok_make("before\x1Fafter")
  assert_eq(result_val(r), "before\x1Fafter", "adt: ok round-trip with \\x1F")
}

function test_adt_result_ng_roundtrip(    r) {
  r = result_ng("AuthError", "bad\x1Fcred")
  assert_eq(result_err_type(r), "AuthError",   "adt: ng type")
  assert_eq(result_err(r),      "bad\x1Fcred", "adt: ng msg round-trip with \\x1F")
}

function test_adt_result_ng_no_msg(    r) {
  r = result_ng("NotFoundError", "")
  assert_eq(result_err_type(r), "NotFoundError", "adt: ng no-msg type")
  assert_eq(result_err(r),      "",              "adt: ng no-msg empty string")
}

function test_adt_option_some_roundtrip(    r) {
  r = option_some_make("val\x1Fwith\x1Fsep")
  assert_true(option_some(r), "adt: some predicate")
  assert_eq(option_val(r), "val\x1Fwith\x1Fsep", "adt: some round-trip with \\x1F")
}

function test_adt_option_none(    r) {
  r = option_none_make()
  assert_true(option_none(r),    "adt: none predicate")
  assert_true(!option_some(r),   "adt: not some")
}
