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

BEGIN {
  _ds_init()
  # Pass 1: collect user function signatures for forward-reference support
  if (ARGC > 1) {
    while ((getline _pass1_line < ARGV[1]) > 0) {
      if (_ds_is_func_def(_pass1_line)) {
        _pass1_fname = _ds_extract_func_name(_pass1_line)
        _pass1_ret   = _ds_extract_return_type(_pass1_line)
        _DS_SIG_RET[_pass1_fname] = (_pass1_ret != "" ? _pass1_ret : "Any")
        if (match(_pass1_line, /\(([^)]*)\)[[:space:]]*(->.*)?[[:space:]]*\{/, _pass1_m))
          _ds_parse_func_params(_pass1_fname, _pass1_m[1])
      }
    }
    close(ARGV[1])
  }
}

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

function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p, dot_transformed) {
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
      _DS_func_ret_type = _ds_extract_return_type(line)
      _DS_func_sig     = _ds_strip_func_annotations(line)
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

  dot_transformed = _ds_dot_transform(line)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  _ds_typecheck_plain_call(nc_result)
  transformed = _ds_let_transform(nc_result, lineno, line)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
}

function _ds_is_func_def(line) {
  return (line ~ /^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(.*\)[[:space:]]*(->.*)?[[:space:]]*\{[[:space:]]*$/)
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

# Extract return type from "function f(...) -> ReturnType {"
function _ds_extract_return_type(sig,    m) {
  if (match(sig, /->[[:space:]]*([^{]+)[[:space:]]*\{/, m))
    return type::normalize(_ds_trim(m[1]))
  return ""
}

# Parse type-annotated params, register in sig tables, return gawk param list
function _ds_parse_func_params(func_name, params_str,    i, c, depth, cur, n, parts, param, colon_pos, pname, ptype, result) {
  # Split on , respecting <...> depth
  n = 0; depth = 0; cur = ""
  for (i = 1; i <= length(params_str); i++) {
    c = substr(params_str, i, 1)
    if      (c == "<") depth++
    else if (c == ">") depth--
    else if (c == "," && depth == 0) {
      parts[++n] = _ds_trim(cur); cur = ""; continue
    }
    cur = cur c
  }
  if (_ds_trim(cur) != "") parts[++n] = _ds_trim(cur)

  _DS_SIG_ARITY[func_name] = n

  for (i = 1; i <= n; i++) {
    param = parts[i]
    colon_pos = index(param, ":")
    if (colon_pos > 0) {
      pname = _ds_trim(substr(param, 1, colon_pos - 1))
      ptype = type::normalize(_ds_trim(substr(param, colon_pos + 1)))
    } else {
      pname = _ds_trim(param)
      ptype = "Any"
    }
    _DS_SIG_ARG[func_name, i] = ptype
    parts[i] = pname
  }

  result = ""
  for (i = 1; i <= n; i++) result = result (i > 1 ? ", " : "") parts[i]
  return result
}

# Check plain function call "f(args)" for arity + type errors
function _ds_typecheck_plain_call(line,    m) {
  if (match(line, /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\((.*)\)[[:space:]]*$/, m)) {
    if (m[1] in _DS_SIG_ARITY)
      _ds_typecheck_call(m[1], m[2])
  }
}

# Strip type annotations from function def line for gawk output
# "function f(a: Str, b: Int) -> Response {" -> "function f(a, b) {"
function _ds_strip_func_annotations(sig,    m, func_name, params_str, clean_params) {
  if (!match(sig, /^([[:space:]]*)function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(([^)]*)\)/, m))
    return sig  # no match, return as-is
  func_name    = m[2]
  params_str   = m[3]
  clean_params = _ds_parse_func_params(func_name, params_str)
  return m[1] "function " func_name "(" clean_params ") {"
}
