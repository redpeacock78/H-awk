# SPDX-License-Identifier: MIT
# dsl/desugar.awk -- hawk DSL preprocessor entry point

@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_let.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/sig.awk"
@include "dsl/typecheck.awk"
@include "dsl/type.awk"

BEGIN { _ds_init() }

FNR == 1 {
  _DS_src_file = FILENAME
  print "# line 1 \"" FILENAME "\""
}

{ _ds_process_line($0, FNR) }

END {
  if (_DS_had_error) exit 1
  if (_DS_in_function) {
    print "dsl error: " _DS_src_file ": unclosed function '" _DS_func_name "'" \
      > "/dev/stderr"
    exit 1
  }
}

function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p) {
  _DS_current_lineno = lineno
  if (!_DS_in_function) {
    if (line ~ /^[[:space:]]*let[[:space:]]/) {
      print "dsl error: " _DS_src_file ":" lineno \
        ": 'let' outside function body" > "/dev/stderr"
      _DS_had_error = 1
      exit 1
    }
    if (_ds_is_func_def(line)) {
      _DS_in_function  = 1
      _DS_func_name    = _ds_extract_func_name(line)
      _DS_func_sig     = line
      _DS_brace_depth  = _ds_net_braces(line)
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_body_buf
      delete _DS_let_type_map
      return
    }
    nc_result = _ds_nc_transform(_ds_dot_transform(line), nc_pre)
    for (p = 1; p in nc_pre; p++) print nc_pre[p]
    print nc_result
    return
  }

  # Inside function body
  _DS_brace_depth += _ds_net_braces(line)

  if (_DS_brace_depth <= 0) {
    _DS_in_function = 0
    print _ds_rewrite_sig(_DS_func_sig)
    for (i = 1; i <= _DS_body_count; i++) print _DS_body_buf[i]
    print _ds_dot_transform(line)
    return
  }

  nc_result = _ds_nc_transform(_ds_dot_transform(line), nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  transformed = _ds_let_transform(nc_result, lineno)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
}

function _ds_is_func_def(line) {
  return (line ~ /^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\([^)]*\)[[:space:]]*\{/)
}

function _ds_net_braces(line,    n, i, c) {
  n = 0
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if      (c == "{") n++
    else if (c == "}") n--
  }
  return n
}
