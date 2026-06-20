# SPDX-License-Identifier: MIT
# tests/unit/run.awk -- H-awk ユニットテストランナー
# hawk.awk (core/*.awk を @include) と一緒に gawk に渡す。

BEGIN {
  ENVIRON["HAWK_NO_SERVE"] = 1
  TESTS_PASSED = 0
  TESTS_FAILED = 0
  TESTS_SKIPPED = 0

  # 各 test_* 関数の呼出はモジュールごとに追加していく
  test_util_url_decode()
  test_util_escape_html()
  test_util_to_lower()
  test_util_log_warn()

  test_json_encode_flat()
  test_json_encode_type_suffix()
  test_json_encode_escape()
  test_json_decode_flat()
  test_json_encode_any_scalar()
  test_json_encode_any_array()
  test_json_encode_any_object()

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
  test_request_parse_zig_get()
  test_request_parse_zig_post_form()
  test_request_parse_zig_query()
  test_request_parse_zig_bad()
  test_request_parse_multipart_no_lib()
  test_request_parse_multipart_text()
  test_request_parse_multipart_file()

  test_response_status()
  test_response_header()
  test_response_header_append()
  test_response_redirect()
  test_response_json()
  test_response_json_raw()
  test_response_text()
  test_response_html()
  test_response_wire()
  test_response_header_crlf_strip()
  test_response_redirect_crlf_strip()

  test_safe_fragment_v_empty()
  test_safe_fragment_v_concatenates()

  test_router_register_and_match()
  test_router_404()
  test_router_405()
  test_router_static_priority()

  test_ctx_load_copies_req()
  test_ctx_save_copies_res_back()
  test_ctx_query_helper()
  test_ctx_param_helper()
  test_ctx_get_header_helper()
  test_ctx_body_helper()
  test_ctx_json_helper()
  test_ctx_json_raw_helper()
  test_ctx_text_helper()
  test_ctx_status_helper()
  test_ctx_set_header_helper()
  test_ctx_load_clears_previous()

  test_hawk_shortcuts()
  test_hawk_compat_GET()
  test_hawk_on_single()
  test_hawk_on_multi_methods()
  test_hawk_on_multi_paths()
  test_hawk_on_multi_both()
  test_hawk_on_custom_method()
  test_hawk_all_single()
  test_hawk_all_multi_paths()

  test_env_get_existing()
  test_env_get_missing()
  test_env_set()
  test_env_del()
  test_env_has_existing()
  test_env_has_missing()
  test_env_set_overwrite()

  test_plugin_register_one()
  test_plugin_call_hooks_normal()
  test_plugin_call_hooks_abort()
  test_plugin_missing_config()

  test_libs_binary_length()
  test_libs_binary_read_text()
  test_libs_binary_read_missing()
  test_libs_net_listen_skip()
  test_libs_multipart_parse_skip()

  test_libs_crypto_sha256()
  test_libs_crypto_hmac_sha256()
  test_libs_crypto_argon2id()
  test_libs_crypto_argon2id_verify()
  test_libs_crypto_sha256_no_lib()

  test_cache_memory_get_set()
  test_cache_memory_miss()
  test_cache_memory_del()
  test_cache_memory_has()
  test_cache_memory_ttl_zero()
  test_cache_off()
  test_cache_backend_memory()
  test_cache_backend_off()
  test_cache_stats()
  test_cache_file_set_get()
  test_cache_file_tab_newline()
  test_cache_file_ttl_expired()
  test_cache_file_escape_unescape()
  test_cache_auto_no_zig_no_dir()
  test_cache_auto_with_dir()

  test_message_make_cast_decode()
  test_message_make_call_has_reply_to()
  test_message_ref_unique()
  test_message_decode_bad_line()
  test_message_make_error_decode()

  test_objectspace_register_resolve()
  test_objectspace_resolve_unknown()
  test_objectspace_unregister()

  test_adt_result_ok_roundtrip()
  test_adt_result_ok_xif_roundtrip()
  test_adt_result_ng_roundtrip()
  test_adt_result_ng_no_msg()
  test_adt_option_some_roundtrip()
  test_adt_option_none()

  printf "\n%d passed, %d failed, %d skipped\n", TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED
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
@include "tests/unit/test_safe.awk"
@include "tests/unit/test_router.awk"
@include "tests/unit/test_plugin.awk"
@include "tests/unit/test_libs.awk"
@include "tests/unit/test_ctx.awk"
@include "tests/unit/test_hawk.awk"
@include "tests/unit/test_env.awk"
@include "tests/unit/test_adt.awk"
@include "tests/unit/test_cache.awk"
@include "tests/unit/test_message.awk"
@include "tests/unit/test_objectspace.awk"
