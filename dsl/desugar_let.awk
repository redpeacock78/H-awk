# SPDX-License-Identifier: MIT
# dsl/desugar_let.awk -- let declaration transform + function signature hoisting

# _ds_infer_type: 式の静的型を推論する。不明な場合は "" を返す
function _ds_infer_type(expr,    m) {
    # 文字列リテラル: "..." 形式
    if (expr ~ /^".*"$/) return "Str"
    # 整数リテラル: オプショナルな負号 + 数字のみ
    if (expr ~ /^-?[0-9]+$/) return "Int"
    # 浮動小数リテラル
    if (expr ~ /^-?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?$/) return "Float"
    # Bool リテラル
    if (expr == "true" || expr == "false") return "Bool"
    # 既知の DSL 関数呼び出し: ns.method(...) 形式 (desugar 前)
    if (match(expr, /^([a-z][a-zA-Z0-9_]*)\.([a-z][a-zA-Z0-9_]*)\(/, m)) {
        key = m[1] "." m[2]
        if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
    }
    # 既知の DSL 関数呼び出し: ns::dispatch("path", ...) 形式 (desugar 後)
    if (match(expr, /^([a-z][a-zA-Z0-9_]*)::dispatch\("([^"]+)"/, m)) {
        key = m[1] "." m[2]
        if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
    }
    return ""
}

# _ds_check_type: declared と inferred が不一致ならエラーを記録する
function _ds_check_type(declared, inferred, lineno) {
    if (inferred == "" || inferred == declared) return
    print "dsl error: " _DS_src_file ":" lineno \
        ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
    _DS_had_error = 1
}

function _ds_let_transform(line, lineno,    arr, rhs, declared) {
  # Array init: let name = []
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\[\][[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] "delete " arr[2]
  }
  # Type-annotated assignment: let name: Type = expr
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    _ds_check_type(arr[3], _ds_infer_type(arr[4]), lineno)
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
  }
  # Bare typed declaration: let name: Type  (初期値なし)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    return ""
  }
  # Assignment: let name = expr
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    if (!(arr[2] in _DS_let_type_map))
      _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] arr[2] " = " arr[3]
  }
  # Bare declaration: let name
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*$/, arr)) {
    if (!(arr[2] in _DS_let_type_map))
      _DS_let_locals[++_DS_let_count] = arr[2]
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
