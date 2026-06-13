# SPDX-License-Identifier: MIT
# dsl/typecheck.awk -- DSL static type checker (arity + arg types)

function _ds_is_option(t) { return t ~ /^Option</ }
function _ds_is_result(t) { return t ~ /^Result</ }
function _ds_is_nullable(t) { return _ds_is_option(t) || _ds_is_result(t) }

function _ds_inner_type(t,    m) {
    if (match(t, /^Option<(.+)>$/, m))    return m[1]
    if (match(t, /^Result<([^,]+),/, m))  return m[1]
    return "Any"
}

function _ds_count_args(args_str,    n, i, c, depth, in_str) {
    if (_ds_trim(args_str) == "") return 0
    n = 1; depth = 0; in_str = 0
    for (i = 1; i <= length(args_str); i++) {
        c = substr(args_str, i, 1)
        if (in_str) {
            if (c == "\\" && i < length(args_str)) { i++; continue }
            if (c == "\"") in_str = 0
        } else {
            if      (c == "\"") in_str = 1
            else if (c == "(")  depth++
            else if (c == ")")  depth--
            else if (c == "," && depth == 0) n++
        }
    }
    return n
}

function _ds_split_args(args_str, out,    i, c, depth, in_str, cur, n) {
    n = 0; depth = 0; in_str = 0; cur = ""
    for (i = 1; i <= length(args_str); i++) {
        c = substr(args_str, i, 1)
        if (in_str) {
            cur = cur c
            if (c == "\\" && i < length(args_str)) { cur = cur substr(args_str, ++i, 1) }
            else if (c == "\"") in_str = 0
        } else {
            if (c == "\"")      { in_str = 1; cur = cur c }
            else if (c == "(")  { depth++; cur = cur c }
            else if (c == ")")  { depth--; cur = cur c }
            else if (c == "," && depth == 0) {
                out[++n] = _ds_trim(cur)
                cur = ""
            } else {
                cur = cur c
            }
        }
    }
    if (_ds_trim(cur) != "") out[++n] = _ds_trim(cur)
    return n
}

function _ds_typecheck_call(path, args_str,    n, i, expected, actual, split_args, lineno) {
    lineno = _DS_current_lineno
    if (!(path in _DS_SIG_ARITY)) return

    n = _ds_count_args(args_str)
    if (n != _DS_SIG_ARITY[path]) {
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " expects " _DS_SIG_ARITY[path] " argument(s), got " n > "/dev/stderr"
        _DS_had_error = 1
        return
    }

    if (n == 0) return

    _ds_split_args(args_str, split_args)
    for (i = 1; i <= n; i++) {
        if (!((path, i) in _DS_SIG_ARG)) continue
        expected = _DS_SIG_ARG[path, i]
        actual   = _ds_infer_type(split_args[i])
        if (actual == "" || actual == "Any" || actual == expected) continue
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " argument " i " expects " expected ", got " actual > "/dev/stderr"
        _DS_had_error = 1
    }
}

function _ds_extract_func_name(sig,    m) {
    if (match(sig, /function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, m))
        return m[1]
    return ""
}
