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
@include "dsl/desugar_pipe.awk"
@include "dsl/desugar_match.awk"
@include "dsl/type_dataflow.awk"

BEGIN {
  _ds_init()
  # Pass 1: collect user function signatures for forward-reference support
  if (ARGC > 1) {
    _pass1_fname = ""
    while ((getline _pass1_line < ARGV[1]) > 0) {
      if (_ds_is_func_def(_pass1_line)) {
        _pass1_fname = _ds_extract_func_name(_pass1_line)
        _pass1_ret   = _ds_extract_return_type(_pass1_line)
        _DS_SIG_RET[_pass1_fname] = (_pass1_ret != "" ? _pass1_ret : "Any")
        if (match(_pass1_line, /\(([^)]*)\)[[:space:]]*(->.*)?[[:space:]]*\{/, _pass1_m))
          _ds_parse_func_params(_pass1_fname, _pass1_m[1])
      } else if (_pass1_fname != "" && \
          match(_pass1_line, /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/, _pass1_m)) {
        _DS_FUNC_CLASS[_pass1_fname] = _pass1_m[1]
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

function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p, dot_transformed, pipe_pre, pipe_result, match_m) {
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
    pipe_result = _ds_pipe_transform(line, pipe_pre)
    for (p = 1; p in pipe_pre; p++) print pipe_pre[p]
    nc_result = _ds_nc_transform(_ds_dot_transform(pipe_result), nc_pre)
    for (p = 1; p in nc_pre; p++) print nc_pre[p]
    print nc_result
    return
  }

  # Inside function body
  _DS_brace_depth += _ds_net_braces(line)

  # Strip classify annotation lines — already stored in Pass 1
  if (line ~ /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/) {
    return
  }

  # Dispatch to match state machine if inside a match block or starting one
  if (_DS_in_match) {
    _ds_match_collect(line, lineno)
    return
  }
  if (_ds_match_starts(line, match_m)) {
    _DS_match_expr   = match_m[2]
    _DS_match_indent = match_m[1]
    _DS_in_match = 1
    return
  }

  # Multi-line adjacent string literal folding
  if (_DS_str_fold_active) {
    # Blank lines are transparent inside a fold — skip and continue accumulating.
    if (line ~ /^[[:space:]]*$/) return
    # Comment-only lines cleanly terminate the fold; the comment is then discarded.
    if (line ~ /^[[:space:]]*#/) {
      _ds_flush_string_fold(lineno)
      return
    }
    if (_ds_is_pure_string_line(line)) {
      _DS_str_fold_content = _DS_str_fold_content _ds_pure_string_line_content(line)
      return
    } else {
      _ds_flush_string_fold(lineno)
      # Fall through to process current line normally
    }
  }
  if (_ds_is_let_equals_no_rhs(line)) {
    _DS_str_fold_active  = 1
    _DS_str_fold_prefix  = line
    _DS_str_fold_content = ""
    _DS_str_fold_lineno  = lineno
    return
  }

  if (_DS_brace_depth <= 0) {
    if (_DS_str_fold_active) _ds_flush_string_fold(lineno)
    _DS_in_function = 0
    print _ds_rewrite_sig(_DS_func_sig)
    for (i = 1; i <= _DS_body_count; i++) print _DS_body_buf[i]
    print _ds_dot_transform(line)
    return
  }

  # Same-line adjacent string literal folding
  line = _ds_fold_adjacent_strings_inline(line)

  pipe_result = _ds_pipe_transform(line, pipe_pre)
  for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = pipe_pre[p]

  dot_transformed = _ds_dot_transform(pipe_result)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  _ds_typecheck_plain_call(nc_result)
  _ds_check_return(dot_transformed, lineno)
  transformed = _ds_let_transform(nc_result, lineno, line)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
}

# Flush accumulated multi-line string fold as a single synthetic let line.
# NOTE: deliberately avoids recursive _ds_process_line to prevent brace-depth
# race conditions when the triggering line is a closing brace.
function _ds_flush_string_fold(lineno,    prefix_line, synthetic_line, fold_lineno, pipe_pre, nc_pre, pipe_result, dot_transformed, nc_result, transformed, p) {
  prefix_line  = _DS_str_fold_prefix
  fold_lineno  = _DS_str_fold_lineno
  sub(/=[[:space:]]*$/, "", prefix_line)
  synthetic_line = prefix_line "= \"" _DS_str_fold_content "\""
  _DS_str_fold_active  = 0
  _DS_str_fold_prefix  = ""
  _DS_str_fold_content = ""
  _DS_str_fold_lineno  = 0
  # Process the synthetic line directly (no recursion) — same path as normal body lines.
  # This avoids the brace-depth race condition that occurs when the trigger line
  # is a closing brace: brace_depth is already decremented before we get here.
  synthetic_line = _ds_fold_adjacent_strings_inline(synthetic_line)
  pipe_result = _ds_pipe_transform(synthetic_line, pipe_pre)
  for (p = 1; p in pipe_pre; p++)
    _DS_body_buf[++_DS_body_count] = pipe_pre[p]
  dot_transformed = _ds_dot_transform(pipe_result)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  _ds_typecheck_plain_call(nc_result)
  _ds_check_return(dot_transformed, fold_lineno)
  transformed = _ds_let_transform(nc_result, fold_lineno, synthetic_line)
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

# Check return statement against declared return type
function _ds_check_return(line, lineno,    m, actual) {
  if (_DS_func_ret_type == "" || _DS_func_ret_type == "Any") return
  if (!match(line, /^[[:space:]]*return[[:space:]]+(.+)$/, m)) return
  actual = _ds_infer_type(_ds_trim(m[1]))
  if (actual == "") return
  if (_DS_func_ret_type == "Void") {
    print "dsl error: " _DS_src_file ":" lineno \
        ": function " _DS_func_name " expects Void, got " actual > "/dev/stderr"
    _DS_had_error = 1
    return
  }
  if (!type::accepts(_DS_func_ret_type, actual)) {
    print "dsl error: " _DS_src_file ":" lineno \
        ": function " _DS_func_name " expects return " _DS_func_ret_type ", got " actual > "/dev/stderr"
    _DS_had_error = 1
  }
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
