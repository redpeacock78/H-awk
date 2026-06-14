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
  _DS_had_error   = 0
  _DS_src_file    = ""
  _DS_current_lineno = 0
  _DS_pipe_count  = 0
  _DS_mc_count       = 0
  _DS_in_match       = 0
  _DS_match_expr     = ""
  _DS_match_indent   = ""
  _DS_match_ok_var   = ""
  _DS_match_ng_var   = ""
  _DS_match_branch   = ""
  _DS_match_has_ng   = 0
  _DS_match_ok_count = 0
  _DS_match_ng_count = 0
  delete _DS_let_locals
  delete _DS_body_buf
  delete _DS_let_type_map
  delete _DS_VAR_TYPES
  delete _DS_VAR_KIND
  delete _DS_match_ok_body
  delete _DS_match_ng_body
  delete _DS_FUNC_CLASS
  # Re-register built-in function classes (cleared above)
  _DS_FUNC_CLASS["escape_html"] = "sanitizer"
  _DS_FUNC_CLASS["html_raw"]    = "sanitizer"
}
