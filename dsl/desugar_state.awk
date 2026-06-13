# SPDX-License-Identifier: MIT
# dsl/desugar_state.awk -- shared desugar state

function _ds_init() {
  _DS_brace_depth = 0
  _DS_in_function = 0
  _DS_func_name   = ""
  _DS_func_sig    = ""
  _DS_let_count   = 0
  _DS_body_count  = 0
  _DS_tc_count    = 0
  _DS_had_error   = 0
  _DS_src_file    = ""
  _DS_current_lineno = 0
  delete _DS_let_locals
  delete _DS_body_buf
  delete _DS_let_type_map
  delete _DS_VAR_TYPES
  delete _DS_VAR_KIND
}
