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
  test_util_shellquote_plain()
  test_util_shellquote_single_quote()
  test_util_shellquote_shell_meta()
  test_util_shellquote_whitespace_and_backslash()
  test_util_shellquote_glob_and_expansion()

  test_json_encode_flat()
  test_json_encode_type_suffix()
  test_json_encode_escape()
  test_json_unescape_basic()
  test_json_unescape_control()
  test_json_unescape_quote()
  test_json_unescape_backslash()
  test_json_unescape_unicode_ascii()
  test_json_unescape_unicode_bmp()
  test_json_unescape_unicode_surrogate()
  test_json_decode_flat()
  test_json_encode_any_scalar()
  test_json_encode_any_array()
  test_json_encode_any_object()
  test_json_valid_object()
  test_json_decode_invalid()
  test_json_decode_nested_object()
  test_json_decode_array()
  test_json_decode_deep()
  test_json_decode_unicode_in_value()
  test_json_decode_escape_in_value()
  test_json_decode_invalid_returns_zero()
  test_json_decode_via_zig_flat()
  test_json_decode_via_zig_nested()
  test_json_decode_via_zig_array()
  test_json_decode_via_zig_bool()
  test_json_decode_via_zig_invalid()
  test_json_decode_type_tags()
  test_json_decode_distinguishes_string_from_int()
  test_json_decode_base64_roundtrip()
  test_json_decode_fallback_type_tags()
  test_json_dispatch_encode()
  test_json_dispatch_decode_ok()
  test_json_dispatch_decode_ng()
  test_json_dispatch_decode_t_ok()
  test_json_dispatch_decode_t_mismatch()
  test_json_dispatch_decode_t_distinguishes_string_from_int()
  test_json_dispatch_unknown_path()
  test_json_dispatch_decode_base64_roundtrip()
  test_json_decode_value_scalar()
  test_json_decode_value_array()
  test_json_decode_value_invalid_scalar()
  test_json_decode_value_nested_invalid_object_literal()
  test_json_decode_value_nested_invalid_array_literal()
  test_json_decode_value_truncated_object()
  test_json_decode_value_truncated_array()
  test_json_decode_object_dispatch_ok()
  test_json_decode_object_dispatch_ng()
  test_json_decode_object_invalid_nested_literal()
  test_json_decode_too_deep()
  test_json_decode_t_too_deep()
  test_json_decode_within_max_depth_ok()
  test_json_decode_object_too_deep()
  test_json_decode_value_scalar_trailing_garbage()
  test_json_decode_value_array_trailing_garbage()
  test_json_decode_value_object_trailing_garbage()
  test_json_decode_object_trailing_garbage()
  test_json_decode_value_unterminated_array_string()
  test_json_decode_value_unterminated_object_string()
  test_json_decode_t_unterminated_array_string()
  test_json_decode_t_unterminated_object_string()
  test_json_decode_t_int_rejects_empty_array()
  test_json_decode_t_int_rejects_empty_object()
  test_json_decode_t_jsonvalue_accepts_scalar()
  test_json_decode_t_array_accepts_array()
  test_json_decode_t_array_rejects_scalar_root()
  test_json_decode_t_jsonobject_rejects_array_root()
  test_json_decode_t_jsonscalar_rejects_array_root()
  test_json_decode_rejects_invalid_escape()
  test_json_decode_rejects_invalid_unicode_escape()
  test_json_decode_value_rejects_leading_zero()

  test_tsv_append_and_read()
  test_tsv_find()
  test_tsv_delete_update()

  test_template_read()
  test_template_read_missing()

  test_static_mime()
  test_static_safe_path()
  test_static_read()
  test_static_serve_shell_metachars()

  test_request_parse_get()
  test_request_parse_form()
  test_request_parse_json()
  test_request_parse_json_too_deep_does_not_populate()
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
  test_request_validate_content_type()

  test_response_status()
  test_response_header()
  test_response_header_append()
  test_response_redirect()
  test_response_json()
  test_response_json_raw()
  test_response_json_zig_passthrough()
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
  test_router_query_register_and_match()
  test_router_query_missing_content_type()
  test_router_query_wrong_content_type()
  test_router_query_accept_query_injected()
  test_router_query_405_includes_accept_query()
  test_router_query_options()

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
  test_cache_file_set_get()
  test_cache_file_tab_newline()
  test_cache_file_ttl_expired()
  test_cache_file_escape_unescape()
  test_cache_empty_string_hit_vs_miss()
  test_cache_zig_found_api()
  test_cache_dispatch_get_miss()
  test_cache_dispatch_get_hit()
  test_cache_dispatch_has()
  test_cache_dispatch_del_semantics()
  test_cache_dispatch_unknown_method()
  test_cache_dispatch_file_backend_unavailable()
  test_cache_dispatch_map_error_code()
  test_cache_facade_clears_stale_error_code()
  test_cache_dispatch_file_set_mv_failure()
  test_cache_dispatch_file_del_mv_failure()
  test_cache_zig_too_large_payload()
  test_cache_dispatch_file_round_trip()
  test_cache_dispatch_file_lock_timeout()
  test_cache_dispatch_zig_too_large()
  test_cache_dispatch_off_backend()

  test_url_encode()
  test_url_encode_japanese()
  test_url_decode_form()
  test_url_decode_percent()
  test_url_decode_invalid()
  test_url_decode_truncated()

  test_gzip_no_gzip_env()
  test_gzip_no_accept_encoding()
  test_gzip_small_body()
  test_gzip_204()
  test_gzip_image_ct()
  test_gzip_compress()

  test_message_make_cast_decode()
  test_message_make_call_has_reply_to()
  test_message_ref_unique()
  test_message_decode_bad_line()
  test_message_make_error_decode()

  test_objectspace_register_resolve()
  test_objectspace_resolve_unknown()
  test_objectspace_unregister()

  test_proc_self_has_value()
  test_proc_self_env()
  test_proc_register_whereis()
  test_proc_whereis_unknown()

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
@include "tests/unit/test_json_libs.awk"
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
@include "tests/unit/test_cache_dispatch.awk"
@include "tests/unit/test_cache_dispatch_file.awk"
@include "tests/unit/test_cache_dispatch_zig.awk"
@include "tests/unit/test_cache_dispatch_unavailable.awk"
@include "tests/unit/test_url.awk"
@include "tests/unit/test_gzip.awk"
@include "tests/unit/test_message.awk"
@include "tests/unit/test_objectspace.awk"
@include "tests/unit/test_proc.awk"
