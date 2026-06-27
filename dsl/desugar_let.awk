# SPDX-License-Identifier: MIT
# dsl/desugar_let.awk -- let declaration transform + function signature hoisting

function _ds_resolve_t_in_ret(transformed_expr,    _dm, _dispatch_ns, _dispatch_path, _dispatch_t, _sig_key, _ret) {
    if (!match(transformed_expr, /^([a-zA-Z_][a-zA-Z0-9_]*)::dispatch\("([a-zA-Z_][a-zA-Z0-9_]*)"[[:space:]]*,[[:space:]]*"([A-Z][a-zA-Z0-9_]*)"/, _dm))
        return ""
    _dispatch_ns   = _dm[1]
    _dispatch_path = _dm[2]
    _dispatch_t    = _dm[3]
    _sig_key       = _dispatch_ns "." _dispatch_path
    if (!(_sig_key in _DS_SIG_RET)) return ""
    _ret = _DS_SIG_RET[_sig_key]
    gsub(/\<T\>/, _dispatch_t, _ret)
    return _ret
}

# _ds_infer_type: 式の静的型を推論する。不明な場合は "" を返す
function _ds_infer_type(expr,    m, _m, arg_type, _resolved) {
    _resolved = _ds_resolve_t_in_ret(expr)
    if (_resolved != "") return _resolved
    # 数字のみの文字列リテラル: "8080" 形式 → NumericStr
    if (expr ~ /^"[0-9]+"$/) return "NumericStr"
    # 文字列リテラル: "..." 形式
    if (expr ~ /^".*"$/) return "Str"
    # 整数リテラル: オプショナルな負号 + 数字のみ
    if (expr ~ /^-?[0-9]+$/) return "Int"
    # 浮動小数リテラル
    if (expr ~ /^-?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?$/) return "Float"
    # Bool リテラル
    if (expr == "true" || expr == "false") return "Bool"
    # 既知の DSL 関数呼び出し: ns.method(...) または ctx.ns.method(...) 形式 (desugar 前)
    if (match(expr, /^((ctx\.)?[a-z][a-zA-Z0-9_]*(\.[a-z][a-zA-Z0-9_]*)*)\(/, m)) {
        # Try the full name first: ctx.req.form, then ctx.res.json, etc.
        if (m[1] in _DS_SIG_RET) return _DS_SIG_RET[m[1]]
        # Fall back to last two components (ns.method)
        if (match(m[1], /([a-z][a-zA-Z0-9_]*)\.([a-z][a-zA-Z0-9_]*)$/, m2)) {
            key = m2[1] "." m2[2]
            if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
        }
    }
    # 既知の DSL 関数呼び出し: ns::dispatch("path", ...) 形式 (desugar 後)
    if (match(expr, /^([a-z][a-zA-Z0-9_]*)::dispatch\("([^"]+)"/, m)) {
        key = m[1] "." m[2]
        if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
    }
    # option_some_make(arg) → Option<T> where T is inferred from arg
    if (match(expr, /^option_some_make\((.+)\)[[:space:]]*$/, _m)) {
        arg_type = _ds_infer_type(_ds_trim(_m[1]))
        return "Option<" (arg_type != "" ? arg_type : "Any") ">"
    }
    # option_none_make() → Option<Any>
    if (expr ~ /^option_none_make\(\)[[:space:]]*$/) {
        return "Option<Any>"
    }
    # ユーザー定義関数呼び出し: f(...) 形式 — plain function call (no space before `(`)
    if (match(expr, /^([a-zA-Z_][a-zA-Z0-9_]*)\(/, m)) {
        fname = m[1]
        if (fname in _DS_SIG_RET) {
            if ((fname in _DS_SIG_ARITY) && match(expr, /^[a-zA-Z_][a-zA-Z0-9_]*\((.*)\)[[:space:]]*$/, m))
                _ds_typecheck_call(fname, m[1])
            return _DS_SIG_RET[fname]
        }
        # awk builtins — Str return
        if (fname == "sprintf" || fname == "gensub" || fname == "substr" || \
            fname == "tolower" || fname == "toupper" || fname == "strftime") return "Str"
        # awk builtins — Int return
        if (fname == "int" || fname == "systime" || fname == "mktime" || \
            fname == "length" || fname == "split"  || fname == "sub"   || \
            fname == "gsub"   || fname == "index"  || fname == "match" || \
            fname == "patsplit") return "Int"
        # awk builtins — Float return
        if (fname == "rand" || fname == "sin" || fname == "cos" || \
            fname == "atan2" || fname == "exp" || fname == "log" || \
            fname == "sqrt") return "Float"
        # Unknown function: report error
        _ds_error(_DS_current_lineno, "unknown function " fname, \
            "define the function before use, or check the spelling")
        return ""
    }
    # 変数参照: _DS_VAR_TYPES から型を取得
    # During Pass 1b, _DS_in_function is 0 so this branch is never taken.
    if (_DS_in_function && (_DS_func_name SUBSEP expr) in _DS_VAR_TYPES)
        return _DS_VAR_TYPES[_DS_func_name, expr]
    return ""
}

# Side-effect-free variant: returns "" instead of calling _ds_error for unknown
# functions. Used during Pass 1b body scan where error output is not appropriate.
function _ds_infer_type_safe(expr,    m, _m, m2, key, fname, arg_type) {
    if (expr ~ /^"[0-9]+"$/) return "NumericStr"
    if (expr ~ /^".*"$/) return "Str"
    if (expr ~ /^-?[0-9]+$/) return "Int"
    if (expr ~ /^-?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?$/) return "Float"
    if (expr == "true" || expr == "false") return "Bool"
    if (match(expr, /^((ctx\.)?[a-z][a-zA-Z0-9_]*(\.[a-z][a-zA-Z0-9_]*)*)\(/, m)) {
        if (m[1] in _DS_SIG_RET) return _DS_SIG_RET[m[1]]
        if (match(m[1], /([a-z][a-zA-Z0-9_]*)\.([a-z][a-zA-Z0-9_]*)$/, m2)) {
            key = m2[1] "." m2[2]
            if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
        }
    }
    if (match(expr, /^([a-z][a-zA-Z0-9_]*)::dispatch\("([^"]+)"/, m)) {
        key = m[1] "." m[2]
        if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
    }
    if (match(expr, /^option_some_make\((.+)\)[[:space:]]*$/, _m)) {
        arg_type = _ds_infer_type_safe(_ds_trim(_m[1]))
        return "Option<" (arg_type != "" ? arg_type : "Any") ">"
    }
    if (expr ~ /^option_none_make\(\)[[:space:]]*$/) {
        return "Option<Any>"
    }
    if (match(expr, /^([a-zA-Z_][a-zA-Z0-9_]*)\(/, m)) {
        fname = m[1]
        if (fname in _DS_SIG_RET) return _DS_SIG_RET[fname]
        if (fname == "sprintf" || fname == "gensub" || fname == "substr" || \
            fname == "tolower" || fname == "toupper" || fname == "strftime") return "Str"
        if (fname == "int" || fname == "systime" || fname == "mktime" || \
            fname == "length" || fname == "split"  || fname == "sub"   || \
            fname == "gsub"   || fname == "index"  || fname == "match" || \
            fname == "patsplit") return "Int"
        if (fname == "rand" || fname == "sin" || fname == "cos" || \
            fname == "atan2" || fname == "exp" || fname == "log" || \
            fname == "sqrt") return "Float"
        return ""
    }
    if (_DS_in_function && (_DS_func_name SUBSEP expr) in _DS_VAR_TYPES)
        return _DS_VAR_TYPES[_DS_func_name, expr]
    return ""
}

# _ds_check_type: declared と inferred が不一致ならエラーを記録する
function _ds_check_type(declared, inferred, lineno) {
    if (inferred == "" || inferred == declared) return
    # Brand forgery prevention: brand types cannot be created by annotation
    if (_ds_is_brand(declared) && inferred != declared) {
        _ds_error(lineno, "safe/brand type cannot be created by annotation", \
            declared " must be constructed by a trusted sanitizer function")
        return
    }
    if (type::accepts(declared, inferred)) return
    _ds_error(lineno, "type mismatch: cannot assign " inferred " to " declared, \
        "use a value of type " declared ", or remove the type annotation")
}

# _ds_kind_of: 型文字列から変数の kind を取得する
function _ds_kind_of(t) {
    if (t == "Array")         return "array"
    if (t == "Map")           return "map"
    if (t ~ /^Option</)       return "option"
    if (t ~ /^Result</)       return "result"
    if (t == "Response")      return "response"
    return "scalar"
}

function _ds_is_primitive_type(t) {
    return (t == "Int" || t == "Float" || t == "Str" || t == "Bool")
}

function _ds_result_ng_return(varname,    t) {
    t = "_ds_err_type_" varname
    return \
        "    " t " = awk::result_err_type(" varname ")\n" \
        "    if (" t " == \"ParseError\") return ctx::dispatch(\"res.status\", 400)\n" \
        "    if (" t " == \"AuthError\") return ctx::dispatch(\"res.status\", 401)\n" \
        "    if (" t " == \"NotFoundError\") return ctx::dispatch(\"res.status\", 404)\n" \
        "    return ctx::dispatch(\"res.status\", 500)"
}

# _ds_extract_let_parts: parse "  let name: TYPE = RHS"
# Returns 1 on success, 0 on failure
# Fills: out_indent, out_varname, out_type, out_rhs
function _ds_extract_let_parts(line, out_indent, out_varname, out_type, out_rhs,    m, rest, eq_pos, type_part, rhs_part) {
    # Match "  let name:" prefix
    if (!match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.+)$/, m))
        return 0
    out_indent[1]   = m[1]
    out_varname[1]  = m[2]
    rest            = m[3]  # "TYPE = RHS"
    # Find first = (type cannot contain =, so first = splits correctly)
    eq_pos = index(rest, "=")
    if (eq_pos == 0) return 0
    type_part      = substr(rest, 1, eq_pos - 1)
    rhs_part       = substr(rest, eq_pos + 1)
    out_type[1]    = type::normalize(_ds_trim(type_part))
    out_rhs[1]     = _ds_trim(rhs_part)
    return 1
}

# Extract the RHS from the original let line (before transforms)
function _ds_extract_orig_rhs(orig_line,    m) {
    if (match(orig_line, /=[[:space:]]*(.+)$/, m)) return _ds_trim(m[1])
    return ""
}

# Infer type from transformed expr, falling back to orig_expr for ?? detection
function _ds_infer_type_with_orig(transformed_expr, orig_expr,    m, ltype, rtype, _resolved) {
    _resolved = _ds_resolve_t_in_ret(transformed_expr)
    if (_resolved != "") return _resolved
    if (orig_expr != "" && match(orig_expr, /^(.+)\?\?(.+)$/, m)) {
        ltype = _ds_infer_type(_ds_trim(m[1]))
        rtype = _ds_infer_type(_ds_trim(m[2]))
        return type::union_of(ltype, rtype)
    }
    return _ds_infer_type(transformed_expr)
}

function _ds_let_transform(line, lineno, orig_line,    arr, rhs, declared, rhs_type, var_type, _let_call) {
  if (_DS_strict && _DS_block_depth > 0 && line ~ /^[[:space:]]*let[[:space:]]+/)
    print "let inside control-flow block" > "/dev/stderr"

  # ?= unwrap: let name ?= expr / let name: Type ?= expr  (requires Option or Result return type)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)([[:space:]]*:[[:space:]]*([^?]+))?[[:space:]]*\?=[[:space:]]*(.+)$/, arr)) {
    rhs = _ds_trim(arr[5])
    rhs_type = _ds_strip_effect(_ds_infer_type(rhs))
    if (rhs_type != "" && !_ds_is_nullable(rhs_type) && !_ds_all_nullable(rhs_type)) {
      _ds_error(lineno, "?= requires Option or Result, got " rhs_type, \
          "use ?= only with Option<T> or Result<T,E> types")
      return ""
    }
    var_type = (arr[4] != "" ? type::normalize(_ds_trim(arr[4])) : _ds_inner_type(rhs_type))
    if (arr[4] != "")
      _ds_check_type(var_type, _ds_inner_type(rhs_type), lineno)
    _DS_tc_count++
    _DS_let_locals[++_DS_let_count] = "_ds_tc_" _DS_tc_count
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = var_type
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(var_type)
    _DS_body_buf[++_DS_body_count] = arr[1] "_ds_tc_" _DS_tc_count " = " rhs
    if (_ds_is_option(rhs_type)) {
      _DS_body_buf[++_DS_body_count] = arr[1] "if (!option_some(_ds_tc_" _DS_tc_count ")) {"
      _DS_body_buf[++_DS_body_count] = arr[1] "  return ctx::dispatch(\"res.status\", 404)"
      _DS_body_buf[++_DS_body_count] = arr[1] "}"
      _DS_body_buf[++_DS_body_count] = arr[1] arr[2] " = option_val(_ds_tc_" _DS_tc_count ")"
    } else {
      _DS_let_locals[++_DS_let_count] = "_ds_err_type__ds_tc_" _DS_tc_count
      _DS_body_buf[++_DS_body_count] = arr[1] "if (!result_ok(_ds_tc_" _DS_tc_count ")) {"
      _DS_body_buf[++_DS_body_count] = _ds_result_ng_return("_ds_tc_" _DS_tc_count)
      _DS_body_buf[++_DS_body_count] = arr[1] "}"
      _DS_body_buf[++_DS_body_count] = arr[1] arr[2] " = result_val(_ds_tc_" _DS_tc_count ")"
    }
    return ""
  }
  # Array init: let name = []
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\[\][[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = "Array"
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = "array"
    return arr[1] "delete " arr[2]
  }
  # Type-annotated assignment: let name: Type = expr (supports Union types)
  if (_ds_extract_let_parts(line, _parts_indent, _parts_varname, _parts_type, _parts_rhs)) {
    indent   = _parts_indent[1]
    varname  = _parts_varname[1]
    declared = _parts_type[1]
    rhs      = _parts_rhs[1]
    _DS_let_locals[++_DS_let_count] = varname
    _DS_let_type_map[varname]        = declared
    _DS_VAR_TYPES[_DS_func_name, varname] = declared
    _DS_VAR_KIND[_DS_func_name, varname]  = _ds_kind_of(declared)
    orig_rhs = _ds_extract_orig_rhs(orig_line)
    inferred = _ds_infer_type_with_orig(rhs, orig_rhs)
    _ds_check_type(declared, inferred, lineno)
    if (declared ~ /^(List|Dict)</ || (declared in _DS_RECORD_TYPE)) {
      transformed = _ds_desugar_let_init(varname, declared, rhs, indent)
      if (_in_let_rec) return ""
      gsub(/\n/, "\n" indent, transformed)
      return indent transformed
    }
    # RHS が関数呼び出しなら引数型チェック
    if (match(rhs, /^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\((.*)\)[[:space:]]*$/, _let_call)) {
      if (_let_call[1] in _DS_SIG_ARITY)
        _ds_typecheck_call(_let_call[1], _let_call[2])
    }
    # Union type: no coerce (ambiguous target), assign directly
    if (type::is_union(declared))
      return indent varname " = " rhs
    # Type statically known and accepted: no coerce needed
    if (inferred != "" && type::accepts(declared, inferred))
      return indent varname " = " rhs
    if (_ds_is_primitive_type(declared))
      return indent varname " = type::coerce(" rhs ", \"" declared "\")"
    return indent varname " = " rhs
  }
  # Bare typed declaration: let name: Type  (初期値なし, supports Union types)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.+)$/, arr)) {
    # Only match if no = sign (bare declaration)
    if (index(arr[3], "=") == 0) {
      declared = type::normalize(_ds_trim(arr[3]))
      _DS_let_locals[++_DS_let_count] = arr[2]
      _DS_let_type_map[arr[2]] = declared
      _DS_VAR_TYPES[_DS_func_name, arr[2]] = declared
      _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(declared)
      return ""
    }
  }
  # Assignment: let name = expr
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    if (!(arr[2] in _DS_let_type_map))
      _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = _ds_infer_type(arr[3])
    # Override: if interpolation produced sprintf(...) and any expr was Untrusted, mark as Untrusted<Str>
    if (_DS_last_interp_untrusted && (_DS_VAR_TYPES[_DS_func_name, arr[2]] == "Str" || _DS_VAR_TYPES[_DS_func_name, arr[2]] == "")) {
        _DS_VAR_TYPES[_DS_func_name, arr[2]] = "Untrusted<Str>"
        _DS_last_interp_untrusted = 0
    }
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(_DS_VAR_TYPES[_DS_func_name, arr[2]])
    return arr[1] arr[2] " = " arr[3]
  }
  # Bare declaration: let name
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*$/, arr)) {
    if (!(arr[2] in _DS_let_type_map))
      _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = ""
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = "scalar"
    return ""
  }
  # 型付き変数への代入を coerce でラップ
  # パターン: varname = rhs  (varname が _DS_let_type_map に登録されている場合)
  # =[^=<>!~] で ==, !=, <=, >=, =~, !~ を除外
  if (match(line, /^([[:space:]]*)([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=([^=<>!~].*)$/, arr)) {
    if (arr[2] in _DS_let_type_map) {
      rhs      = _ds_trim(arr[3])
      declared = _DS_let_type_map[arr[2]]
      _ds_check_type(declared, _ds_infer_type(rhs), lineno)
      if (_ds_is_primitive_type(declared))
        return arr[1] arr[2] " = type::coerce(" rhs ", \"" declared "\")"
      return arr[1] arr[2] " = " rhs
    }
  }
  # Array element assignment: arr["key"] = expr → track inferred type for later lookup
  if (_DS_in_function && \
      match(line, /^([[:space:]]*)([a-zA-Z_][a-zA-Z0-9_]*)\[([^\]]+)\][[:space:]]*=([^=<>!~].*)$/, arr)) {
    declared = _ds_infer_type(_ds_trim(arr[4]))
    if (declared != "")
      _DS_VAR_TYPES[_DS_func_name, arr[2] "[" arr[3] "]"] = declared
  }
  return line
}

function _ds_rewrite_sig(sig,    i, locals_str, lp, rp) {
  if (_DS_let_count == 0) return sig

  # Build comma-joined locals list
  locals_str = ""
  for (i = 1; i <= _DS_let_count; i++)
    locals_str = locals_str (i > 1 ? ", " : "") _DS_let_locals[i]

  # Find opening and closing paren positions
  lp = index(sig, "(")
  rp = index(sig, ")")
  if (lp == 0 || rp == 0) return sig

  # Check if there are existing params (non-empty between parens)
  if (rp > lp + 1) {
    # Has existing params: append ",    locals" before ")"
    return substr(sig, 1, rp - 1) ",    " locals_str substr(sig, rp)
  } else {
    # Empty parens "()" — insert locals inside
    return substr(sig, 1, lp) "    " locals_str substr(sig, rp)
  }
}

function _ds_parse_record_fields(name, body,    inner, n, i, k, v, colon_pos, line, _prf_lines) {
    inner = body
    gsub(/^\{[[:space:]]*\n?/, "", inner)
    gsub(/\n?[[:space:]]*\}[[:space:]]*$/, "", inner)
    n = split(inner, _prf_lines, /\n/)
    for (i = 1; i <= n; i++) {
        line = _ds_trim(_prf_lines[i])
        if (line == "") continue
        colon_pos = index(line, ":")
        if (colon_pos < 2) continue
        k = _ds_trim(substr(line, 1, colon_pos - 1))
        v = _ds_trim(substr(line, colon_pos + 1))
        if (k != "" && v != "") _DS_RECORD_FIELDS[name, k] = v
    }
}

function _ds_desugar_let_init(varname, typename, init_expr, indent_str,    inner_type, rhs_clean) {
    rhs_clean = _ds_trim(init_expr)
    if (typename ~ /^List</) {
        inner_type = gensub(/^List<(.+)>$/, "\\1", 1, typename)
        if (rhs_clean != "[]" && rhs_clean != "") {
            _ds_error(_DS_current_lineno, varname ": List initializer must be [] (got: " rhs_clean ")", \
                "use [] to create an empty List, then assign elements individually")
            return ""
        }
        _DS_VAR_TYPES[_DS_func_name, varname] = typename
        return "delete " varname "\n" varname "[\"__json_type\"] = \"array\""
    }
    if (typename ~ /^Dict</) {
        if (rhs_clean != "{}" && rhs_clean != "") {
            _ds_error(_DS_current_lineno, varname ": Dict initializer must be {} (got: " rhs_clean ")", \
                "use {} to create an empty Dict, then assign elements individually")
            return ""
        }
        _DS_VAR_TYPES[_DS_func_name, varname] = typename
        return "delete " varname
    }
    if ((typename in _DS_RECORD_TYPE) && init_expr ~ /^\{.*\}[[:space:]]*$/) {
        _DS_VAR_TYPES[_DS_func_name, varname] = typename
        return _ds_desugar_record_literal(varname, typename, init_expr)
    }
    if ((typename in _DS_RECORD_TYPE) && init_expr ~ /^\{[[:space:]]*$/) {
        _DS_VAR_TYPES[_DS_func_name, varname] = typename
        _in_let_rec  = 1
        _let_rec_var  = varname
        _let_rec_type = typename
        _let_rec_buf  = init_expr
        _let_rec_indent = indent_str
        return ""
    }
    return ""
}

function _ds_desugar_record_literal(varname, typename, literal,    inner, parts, n, i, kv, k, v, out, sep, ftype) {
    inner = literal
    gsub(/^\{[[:space:]]*\n?/, "", inner)
    gsub(/\n?[[:space:]]*\}[[:space:]]*$/, "", inner)
    n = split(inner, parts, /[\n,]+/)
    out = "delete " varname
    sep = "\n"
    for (i = 1; i <= n; i++) {
        if (split(_ds_trim(parts[i]), kv, /[[:space:]]*:[[:space:]]/) == 2) {
            k = _ds_trim(kv[1])
            v = _ds_trim(kv[2])
            if (k == "" || v == "") continue
            if ((typename, k) in _DS_RECORD_FIELDS) {
                ftype = _DS_RECORD_FIELDS[typename, k]
                if (ftype == "Bool") {
                    out = out sep varname "[\"" k ":bool\"] = " ((v == "true" || v == "1") ? "1" : "0")
                } else if (ftype == "Int" || ftype == "Float") {
                    out = out sep varname "[\"" k "\"] = " v
                } else {
                    if (v ~ /^"/) {
                        out = out sep varname "[\"" k "\"] = " v
                    } else {
                        out = out sep varname "[\"" k "\"] = \"" v "\""
                    }
                }
                sep = "\n"
            } else {
                _ds_error(_DS_current_lineno, typename ": unknown field " k, "")
            }
        }
    }
    return out
}
