# SPDX-License-Identifier: MIT
# dsl/typecheck.awk -- DSL static type checker (arity + arg types)

function _ds_is_option(t) { return t ~ /^Option</ }
function _ds_is_result(t) { return t ~ /^Result</ }
function _ds_is_nullable(t) { return _ds_is_option(t) || _ds_is_result(t) }

# Returns 1 if all union members are nullable (Option or Result)
function _ds_all_nullable(t,    out, n, i) {
    n = type::split_union(t, out)
    for (i = 1; i <= n; i++)
        if (!_ds_is_nullable(out[i])) return 0
    return 1
}

# Unwrap each union member and union the resulting inner types
function _ds_unwrap_union_type(t,    out, n, i, result) {
    n = type::split_union(t, out)
    result = _ds_inner_type(out[1])
    for (i = 2; i <= n; i++)
        result = type::union_of(result, _ds_inner_type(out[i]))
    return result
}

function _ds_inner_type(t,    m) {
    if (match(t, /^Option<(.+)>$/, m))    return m[1]
    if (match(t, /^Result<([^,]+),/, m))  return m[1]
    return "Any"
}

function _ds_result_err_type(t,    m) {
    if (match(t, /^Result<[^,]+,[[:space:]]*(.+)>$/, m)) return m[1]
    return ""
}

# _ds_result_err_union(type_str, out_arr)
# "Result<T, AuthError | NotFoundError>" → out_arr[1]="AuthError", out_arr[2]="NotFoundError"
# Returns member count (0 if not a Result type).
function _ds_result_err_union(type_str, out_arr,    err_part) {
    err_part = _ds_result_err_type(type_str)
    if (err_part == "") return 0
    return type::split_union(err_part, out_arr)
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

function _ds_typecheck_call(path, args_str,    n, i, expected, actual, split_args, lineno, max_arity) {
    lineno = _DS_current_lineno
    if (!(path in _DS_SIG_ARITY)) return

    n = _ds_count_args(args_str)
    max_arity = ((path in _DS_SIG_ARITY_MAX) ? _DS_SIG_ARITY_MAX[path] : _DS_SIG_ARITY[path])
    if (_DS_SIG_ARITY[path] != -1 && (n < _DS_SIG_ARITY[path] || n > max_arity)) {
        if (path in _DS_SIG_ARITY_MAX) {
            _ds_error(lineno, path " expects " _DS_SIG_ARITY[path] ".." max_arity " argument(s), got " n, "")
        } else {
            _ds_error(lineno, path " expects " _DS_SIG_ARITY[path] " argument(s), got " n, "")
        }
        return
    }

    if (n == 0) return

    _ds_split_args(args_str, split_args)
    for (i = 1; i <= n; i++) {
        if ((path, i) in _DS_SIG_ARG) {
            expected = _DS_SIG_ARG[path, i]
        } else if ((path, 1) in _DS_SIG_ARG && _DS_SIG_ARITY[path] == -1) {
            expected = _DS_SIG_ARG[path, 1]
        } else {
            continue
        }
        actual   = _ds_infer_type(split_args[i])
        # safe.html.fragment: literal string args are trusted static HTML chunks
        if (path == "safe.html.fragment" && actual == "Str" && \
            split_args[i] ~ /^"[^"]*"$/) continue
        if (actual == "" || type::accepts(expected, actual)) continue
        _ds_error(lineno, path " argument " i " expects " expected ", got " actual, \
            "sanitize or unwrap the value to get " expected)
    }
}

function _ds_infer_literal_type(expr) {
    if (expr ~ /^"/)                        return "Str"
    if (expr ~ /^-?[0-9]+$/)                return "Int"
    if (expr ~ /^-?[0-9]+\.[0-9]+$/)        return "Float"
    if (expr == "true" || expr == "false")  return "Bool"
    if (expr == "null")                     return "Null"
    return ""
}

function _ds_check_collection_assign(varname, idx, val_type,    vtype, lineno) {
    lineno = _DS_current_lineno
    if (!((_DS_func_name, varname) in _DS_VAR_TYPES)) return
    vtype = _DS_VAR_TYPES[_DS_func_name, varname]
    if (vtype ~ /^List</) {
        if (idx ~ /^"/) {
            _ds_error(lineno, varname ": List requires numeric index, got string key " idx, \
                "use Dict<Str, T> for string keys")
        }
        return
    }
    if (vtype ~ /^Dict<Str,/) {
        if (idx ~ /^[0-9]+$/) {
            _ds_error(lineno, varname ": Dict<Str, V> requires string key, got integer " idx, \
                "use List<T> for numeric indices")
        }
        return
    }
}

function _ds_check_record_field_assign(varname, field, rhs_type,    vtype, expected, lineno) {
    lineno = _DS_current_lineno
    if (!((_DS_func_name, varname) in _DS_VAR_TYPES)) return
    vtype = _DS_VAR_TYPES[_DS_func_name, varname]
    if (!(vtype in _DS_RECORD_TYPE)) return
    if (!((vtype, field) in _DS_RECORD_FIELDS)) {
        _ds_error(lineno, vtype ": unknown field " field, \
            "valid fields: " _ds_record_field_list(vtype))
        return
    }
    expected = _DS_RECORD_FIELDS[vtype, field]
    if (rhs_type != "" && !type::accepts(expected, rhs_type)) {
        _ds_error(lineno, vtype "." field " expects " expected ", got " rhs_type, "")
    }
}

function _ds_record_field_list(typename,    k, out, sep) {
    out = ""; sep = ""
    for (k in _DS_RECORD_FIELDS) {
        if (index(k, typename SUBSEP) == 1) {
            out = out sep substr(k, length(typename) + 2)
            sep = ", "
        }
    }
    return out
}

function _ds_extract_func_name(sig,    m) {
    if (match(sig, /function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, m))
        return m[1]
    return ""
}

# _ds_strip_effect: strip Effect<T> wrapper, return T. Pass-through if not Effect.
function _ds_strip_effect(t,    m) {
    if (match(t, /^Effect<(.+)>$/, m)) return m[1]
    return t
}
