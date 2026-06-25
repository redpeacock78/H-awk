# SPDX-License-Identifier: MIT
# dsl/desugar_state.awk -- shared desugar state

function _ds_init() {
  _DS_brace_depth = 0
  _DS_in_function = 0
  _DS_func_name     = ""
  _DS_func_sig      = ""
  _DS_func_ret_type = ""
  _DS_let_count   = 0
  _DS_body_count  = 0
  _DS_tc_count    = 0
  _DS_block_depth = 0
  _DS_had_error   = 0
  _DS_src_file    = ""
  _DS_current_lineno = 0
  _DS_pipe_count  = 0
  _DS_pipe_tmp_cnt = 0
  _DS_mc_count       = 0
  _DS_in_match       = 0
  _DS_match_depth    = 0
  delete _DS_let_locals
  delete _DS_body_buf
  delete _DS_let_type_map
  delete _DS_VAR_TYPES
  delete _DS_VAR_KIND
  delete _DS_match_expr
  delete _DS_match_indent
  delete _DS_match_ok_var
  delete _DS_match_branch
  delete _DS_match_ok_count
  delete _DS_match_ng_arms
  delete _DS_match_cur_ng_arm
  delete _DS_match_is_option
  delete _ds_saw_catchall
  delete _DS_match_ok_body
  delete _DS_match_ok_lineno
  delete _DS_match_ng_body
  delete _DS_match_ng_lineno
  delete _DS_match_ng_type
  delete _DS_match_ng_var_name
  delete _DS_match_ng_is_default
  delete _DS_match_ng_body_count
  delete _DS_ERROR_TYPES
  delete _DS_FUNC_CLASS
  # Re-register built-in function classes (cleared above)
  _DS_FUNC_CLASS["escape_html"]       = "sanitizer"
  _DS_FUNC_CLASS["safe.html.escape"]  = "sanitizer"
  _DS_FUNC_CLASS["safe.attr.escape"]  = "sanitizer"
  _DS_FUNC_CLASS["safe.html.raw"]     = "trusted"
  _DS_FUNC_CLASS["safe.html.fragment"] = "builder"
  # String folding state
  _DS_str_fold_active  = 0   # 1 when accumulating multi-line string fold
  _DS_str_fold_prefix  = ""  # the "let varname = ..." prefix line
  _DS_str_fold_content = ""  # accumulated string content (without outer quotes)
  _DS_str_fold_lineno  = 0   # source line number of the fold-start line
  # String interpolation state
  _DS_last_interp_untrusted = 0  # 1 if last _ds_expand_interp had Untrusted<T> expr
}
