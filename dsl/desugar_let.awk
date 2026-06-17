# SPDX-License-Identifier: MIT
# dsl/desugar_let.awk -- let declaration transform + function signature hoisting

# _ds_infer_type: 式の静的型を推論する。不明な場合は "" を返す
function _ds_infer_type(expr,    m, _m, arg_type) {
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
function _ds_infer_type_with_orig(transformed_expr, orig_expr,    m, ltype, rtype) {
    if (orig_expr != "" && match(orig_expr, /^(.+)\?\?(.+)$/, m)) {
        ltype = _ds_infer_type(_ds_trim(m[1]))
        rtype = _ds_infer_type(_ds_trim(m[2]))
        return type::union_of(ltype, rtype)
    }
    return _ds_infer_type(transformed_expr)
}

function _ds_let_transform(line, lineno, orig_line,    arr, rhs, declared, _let_call) {
  # ?= unwrap: let name ?= expr  (requires Option or Result return type)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\?=[[:space:]]*(.+)$/, arr)) {
    rhs = _ds_trim(arr[3])
    declared = _ds_strip_effect(_ds_infer_type(rhs))
    if (declared != "" && !_ds_is_nullable(declared) && !_ds_all_nullable(declared)) {
      _ds_error(lineno, "?= requires Option or Result, got " declared, \
          "use ?= only with Option<T> or Result<T,E> types")
      return ""
    }
    _DS_tc_count++
    _DS_let_locals[++_DS_let_count] = "_ds_tc_" _DS_tc_count
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = _ds_inner_type(declared)
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(_DS_VAR_TYPES[_DS_func_name, arr[2]])
    _DS_body_buf[++_DS_body_count] = arr[1] "_ds_tc_" _DS_tc_count " = " rhs
    if (_ds_is_option(declared)) {
      _DS_body_buf[++_DS_body_count] = arr[1] "if (!option_some(_ds_tc_" _DS_tc_count ")) {"
      _DS_body_buf[++_DS_body_count] = arr[1] "  return ctx::dispatch(\"res.status\", 404)"
      _DS_body_buf[++_DS_body_count] = arr[1] "}"
      _DS_body_buf[++_DS_body_count] = arr[1] arr[2] " = option_val(_ds_tc_" _DS_tc_count ")"
    } else {
      _DS_body_buf[++_DS_body_count] = arr[1] "if (!result_ok(_ds_tc_" _DS_tc_count ")) {"
      _DS_body_buf[++_DS_body_count] = arr[1] "  return ctx::dispatch(\"res.status\", 500)"
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
    return indent varname " = type::coerce(" rhs ", \"" declared "\")"
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
      return arr[1] arr[2] " = type::coerce(" rhs ", \"" declared "\")"
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
