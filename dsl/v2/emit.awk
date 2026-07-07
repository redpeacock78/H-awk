# SPDX-License-Identifier: MIT
# dsl/v2/emit.awk -- AST -> awk コード生成
#
# 消費: 検査済み AST[]、PASS[]、TYPEOF[]、V2_LINEAST[]（parse.awk が記録）
# 生成: 標準出力への awk ソース
#
# 行順マージ: PASS 行はそのまま出力し、DSL 由来行は「その行を先頭とする
# 文ノード」を V2_LINEAST 経由で見つけて v2_e() に委譲する。
# FUNC 本体内の文は v2_e_func() が AST の子を直接たどって出力するため、
# V2_LINEAST には登録されない（登録されるのはトップレベル文のみ）。

function v2_emit(   l, id) {
  v2_collect_hoists()
  for (l = 1; l <= V2_NLINES; l++) {
    if (l in PASS) {
      print PASS[l]
    } else if (l in V2_LINEAST) {
      id = V2_LINEAST[l]
      v2_e(id, (AST[id,"kind"] == "FUNC") ? 0 : 1)
    }
  }
}

function v2_indent(depth,    s, i) {
  s = ""
  for (i = 0; i < depth; i++) s = s "  "
  return s
}

# ─── 関数ローカル変数のホイスト収集 ────────────────────────────────
# 各 FUNC の子孫にある LET/LETQ 変数名を HOIST[func_id] にカンマ区切りで集める。
function v2_collect_hoists(   id) {
  for (id = 1; id <= V2_NAST; id++)
    if (AST[id,"kind"] == "FUNC") v2_collect_hoists_walk(id, id)
}

function v2_collect_hoists_walk(id, func_id,    k, kind) {
  kind = AST[id,"kind"]
  if (kind == "LET" || kind == "LETQ")
    HOIST[func_id] = (func_id in HOIST) ? HOIST[func_id] ", " AST[id,"text"] : AST[id,"text"]
  for (k = 1; k <= AST[id,"nc"]; k++)
    v2_collect_hoists_walk(AST[id,"c" k], func_id)
}

# ─── 文ディスパッチ ────────────────────────────────────────────────

function v2_e(id, depth,    kind) {
  kind = AST[id,"kind"]
  if      (kind == "FUNC")         v2_e_func(id, depth)
  else if (kind == "LET" || kind == "LETQ") v2_e_let(id, depth)
  else if (kind == "RETURN")       v2_e_return(id, depth)
  else if (kind == "INDEX_ASSIGN") v2_e_index_assign(id, depth)
  else if (kind == "EXPR")         print v2_indent(depth) v2_e_expr(AST[id,"c1"])
  else if (kind == "RAWLINE")      print AST[id,"text"]
  else if (kind == "TYPEDECL")     return   # コンパイル時の型情報のみ、実行コードは生成しない
  else v2_diag(AST[id,"line"], 1, "emit: unsupported node kind: " kind " (Task 11 で対応予定)")
}

function v2_e_func(id, depth,    k, c, kind, params, first, sig) {
  params = ""
  first = 1
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] == "PARAM") {
      params = params (first ? "" : ", ") AST[c,"text"]
      first = 0
    }
  }
  sig = params
  if (id in HOIST) sig = sig (params != "" ? ",    " : "    ") HOIST[id]

  print v2_indent(depth) "function " AST[id,"text"] "(" sig ") {"
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    kind = AST[c,"kind"]
    if (kind == "PARAM" || kind == "TYPEANN") continue
    v2_e(c, depth + 1)
  }
  print v2_indent(depth) "}"
}

function v2_e_let(id, depth,    varname, k, c, expr_id, ekind) {
  varname = AST[id,"text"]
  expr_id = 0
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] != "TYPEANN") expr_id = c
  }
  if (expr_id == 0) return   # 裸宣言: ホイストのみ、文は出力しない
  ekind = AST[expr_id,"kind"]
  if (ekind == "DICTLIT" || ekind == "LISTLIT")
    print v2_indent(depth) "delete " varname
  else
    print v2_indent(depth) varname " = " v2_e_expr(expr_id)
}

function v2_e_return(id, depth) {
  if (AST[id,"nc"] >= 1) print v2_indent(depth) "return " v2_e_expr(AST[id,"c1"])
  else                   print v2_indent(depth) "return"
}

function v2_e_index_assign(id, depth) {
  print v2_indent(depth) AST[id,"text"] "[" v2_e_expr(AST[id,"c1"]) "] = " v2_e_expr(AST[id,"c2"])
}

# ─── 式 emit ────────────────────────────────────────────────────

function v2_e_expr(id,    kind, s, k) {
  kind = AST[id,"kind"]
  if (kind == "NUMLIT" || kind == "IDENT" || kind == "REGEXLIT" || kind == "RAW")
    return AST[id,"text"]
  if (kind == "STRLIT") {
    # 補間あり（#{...}）は Task 11 送りのスタブ（v2_e_interp 未実装）。
    # 無診断で #{...} をそのまま awk 文字列リテラルへ出すと構文的に壊れるため、
    # 補間なしの場合のみそのまま通す。
    if (index(AST[id,"text"], "#{") > 0) {
      v2_diag(AST[id,"line"], 1, "emit: unsupported node kind: STRLIT with interpolation (Task 11 で対応予定)")
      return ""
    }
    return AST[id,"text"]
  }
  if (kind == "BINOP")
    return v2_e_expr(AST[id,"c1"]) " " AST[id,"text"] " " v2_e_expr(AST[id,"c2"])
  if (kind == "UNOP")
    return AST[id,"text"] v2_e_expr(AST[id,"c1"])
  if (kind == "INDEX")
    return v2_e_expr(AST[id,"c1"]) "[" v2_e_expr(AST[id,"c2"]) "]"
  if (kind == "CALL") {
    if (index(AST[id,"text"], ".") > 0) return v2_e_dispatch(id)
    s = AST[id,"text"] "("
    for (k = 1; k <= AST[id,"nc"]; k++) s = s (k > 1 ? ", " : "") v2_e_expr(AST[id,"c" k])
    return s ")"
  }
  v2_diag(AST[id,"line"], 1, "emit: unsupported node kind: " kind " (Task 11 で対応予定)")
  return ""
}

# ドット記法呼び出し -> ns::dispatch("path", args...) への変換。
# 対応表の移植元: dsl/desugar_dot.awk, docs/dsl.md 296-344 行。
function v2_e_dispatch(id,    name, dot, ns, path, s, k, arg1type) {
  name = AST[id,"text"]

  if (name == "option.some") {
    s = "option_some_make("
    for (k = 1; k <= AST[id,"nc"]; k++) s = s (k > 1 ? ", " : "") v2_e_expr(AST[id,"c" k])
    return s ")"
  }
  if (name == "option.none") return "option_none_make()"

  dot  = index(name, ".")
  ns   = substr(name, 1, dot - 1)
  path = substr(name, dot + 1)

  if (name == "ctx.res.json" && AST[id,"nc"] == 1) {
    arg1type = TYPEOF[AST[id,"c1"]]
    if (arg1type ~ /^(Dict|List)</) return "json(res, " v2_e_expr(AST[id,"c1"]) ")"
  }

  s = ns "::dispatch(\"" path "\""
  for (k = 1; k <= AST[id,"nc"]; k++) s = s ", " v2_e_expr(AST[id,"c" k])
  return s ")"
}
