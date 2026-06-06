# tests/unit/run.awk -- H-awk ユニットテストランナー
# hawk.awk (core/*.awk を @include) と一緒に gawk に渡す。

BEGIN {
  TESTS_PASSED = 0
  TESTS_FAILED = 0

  # 各 test_* 関数の呼出はモジュールごとに追加していく
  test_util_url_decode()
  test_util_escape_html()
  test_util_to_lower()

  test_json_encode_flat()
  test_json_encode_type_suffix()
  test_json_encode_escape()
  test_json_decode_flat()

  test_tsv_append_and_read()
  test_tsv_find()
  test_tsv_delete_update()

  test_template_read()
  test_template_read_missing()

  test_static_mime()
  test_static_safe_path()
  test_static_read()

  test_request_parse_get()
  test_request_parse_form()
  test_request_parse_json()
  test_request_bad_line()
  test_request_parse_array()
  test_request_parse_eq_in_value()

  test_response_status()
  test_response_header()
  test_response_header_append()
  test_response_redirect()
  test_response_json()
  test_response_text()
  test_response_html()
  test_response_wire()
  test_response_header_crlf_strip()
  test_response_redirect_crlf_strip()

  test_router_register_and_match()
  test_router_404()
  test_router_405()
  test_router_static_priority()

  printf "\n%d passed, %d failed\n", TESTS_PASSED, TESTS_FAILED
  exit (TESTS_FAILED > 0)
}

function assert_eq(actual, expected, msg) {
  if (actual == expected) {
    TESTS_PASSED++
    return
  }
  TESTS_FAILED++
  printf "FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n", msg, expected, actual > "/dev/stderr"
}

function assert_true(cond, msg) {
  assert_eq(cond ? 1 : 0, 1, msg)
}

@include "tests/unit/test_util.awk"
@include "tests/unit/test_json.awk"
@include "tests/unit/test_tsv.awk"
@include "tests/unit/test_template.awk"
@include "tests/unit/test_static.awk"
@include "tests/unit/test_request.awk"
@include "tests/unit/test_response.awk"
@include "tests/unit/test_router.awk"
