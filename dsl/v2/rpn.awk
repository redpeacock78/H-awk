# SPDX-License-Identifier: MIT
# dsl/v2/rpn.awk -- 操車場法による RPN 中間表現の生成
#
# v2_rpn()  : TOK[] を走査し RPN[] を埋める
#
# RPN[i,"kind"]  : OPERAND | OP | CALL | MARKER
# RPN[i,"val"]   : 演算子文字列 or オペランドテキスト or 関数名
# RPN[i,"line"]  : ソース行番号
# RPN[i,"arity"] : CALL のみ。その他は空。

# ─── 演算子テーブル初期化 ─────────────────────────────────────────

function v2_ops_init() {
  v2_op("|>",     10, "L")
  v2_op("??",     20, "R")
  v2_op("||",     30, "L")
  v2_op("&&",     35, "L")
  v2_op("==",     40, "L"); v2_op("!=",  40, "L")
  v2_op("<",      40, "L"); v2_op("<=",  40, "L")
  v2_op(">",      40, "L"); v2_op(">=",  40, "L")
  v2_op("~",      40, "L"); v2_op("!~",  40, "L")
  v2_op("CONCAT", 50, "L")
  v2_op("+",      60, "L"); v2_op("-",   60, "L")
  v2_op("*",      70, "L"); v2_op("/",   70, "L"); v2_op("%", 70, "L")
  v2_op("^",      80, "R")
  v2_op("NOT",    90, "R"); v2_op("NEG", 90, "R")
  v2_op(".",     100, "L")
}

function v2_op(name, prec, assoc) {
  V2_OP_PREC[name]  = prec
  V2_OP_ASSOC[name] = assoc
}

# ─── RPN 出力 ────────────────────────────────────────────────────

function v2_emit_rpn(kind, val, line, arity,    n) {
  n = ++RPN["n"]
  RPN[n,"kind"]  = kind
  RPN[n,"val"]   = val
  RPN[n,"line"]  = line
  RPN[n,"arity"] = arity
}

# ─── 演算子スタック ───────────────────────────────────────────────

function v2_os_push(op)       { V2_OS[++v2_os_sp] = op }
function v2_os_pop()          { return V2_OS[v2_os_sp--] }
function v2_os_top()          { return V2_OS[v2_os_sp] }

# スタック上の最も近い FN: エントリのインデックスを返す（なければ 0）
function v2_os_fn_top(    i) {
  for (i = v2_os_sp; i >= 1; i--)
    if (V2_OS[i] ~ /^FN:/) return i
  return 0
}

# ─── 補助 ─────────────────────────────────────────────────────────

# "(" または FN: 境界まで OP を出力スタックへ送る（境界は残す）
function v2_pop_until_lp(line,    t) {
  while (v2_os_sp > 0) {
    t = v2_os_top()
    if (t == "(" || t ~ /^FN:/) break
    v2_emit_rpn("OP", v2_os_pop(), line, "")
  }
}

# "(" を捨てる、または FN: なら CALL を出力する
function v2_pop_lp_or_call(line,    t, fname, saved_sp) {
  if (v2_os_sp == 0) {
    v2_diag(line, 1, "unmatched ')'")
    return
  }
  t = v2_os_top()
  if (t == "(") {
    v2_os_pop()
  } else if (t ~ /^FN:/) {
    saved_sp = v2_os_sp
    fname    = substr(v2_os_pop(), 4)   # "FN:" の 3 文字を除く
    v2_emit_rpn("CALL", fname, line, V2_ARITY[saved_sp])
    delete V2_ARITY[saved_sp]
  }
}

# op より優先度が高い（左結合なら同等も）演算子をスタックから出力する
function v2_pop_ge(op, line,    t, tp, op_prec, op_assoc) {
  op_prec  = V2_OP_PREC[op]
  op_assoc = V2_OP_ASSOC[op]
  if (op_prec == "") return   # 未知の演算子
  while (v2_os_sp > 0) {
    t = v2_os_top()
    if (t == "(" || t ~ /^FN:/) break
    tp = V2_OP_PREC[t]
    if (tp == "") break
    if (tp > op_prec || (tp == op_prec && op_assoc == "L"))
      v2_emit_rpn("OP", v2_os_pop(), line, "")
    else
      break
  }
}

# スタックに残った演算子をすべて出力する
function v2_os_flush(line,    t) {
  while (v2_os_sp > 0) {
    t = v2_os_pop()
    if (t == "(" || t ~ /^FN:/)
      v2_diag(line, 1, "unmatched '('")
    else
      v2_emit_rpn("OP", t, line, "")
  }
}

# ─── 操車場法コア ────────────────────────────────────────────────

# トークン区間 [i, j] を操車場法で RPN に変換する
function v2_shunt_expr(i, j,    k, t, line, arity_idx, saved_sp) {
  for (k = i; k <= j; k++) {
    t    = TOK[k,"kind"]
    line = TOK[k,"line"]

    # 関数呼び出し: IDENT の直後が LP
    if (t == "IDENT" && TOK[k+1,"kind"] == "LP") {
      v2_os_push("FN:" TOK[k,"text"])
      # 空引数 g() か判定: LP の次が RP なら arity=0、そうでなければ 1
      V2_ARITY[v2_os_sp] = (TOK[k+2,"kind"] == "RP") ? 0 : 1
      k++   # LP をスキップ
      continue
    }

    if (t == "IDENT" || t == "NUM" || t == "STR" || t == "TYPE") {
      v2_emit_rpn("OPERAND", TOK[k,"text"], line, "")
      continue
    }

    if (t == "LP") {
      v2_os_push("(")
      continue
    }

    if (t == "COMMA") {
      v2_pop_until_lp(line)
      arity_idx = v2_os_fn_top()
      if (arity_idx > 0) V2_ARITY[arity_idx]++
      continue
    }

    if (t == "RP") {
      v2_pop_until_lp(line)
      v2_pop_lp_or_call(line)
      continue
    }

    if (t == "DOT") {
      v2_pop_ge(".", line)
      v2_os_push(".")
      continue
    }

    if (t == "OP") {
      v2_pop_ge(TOK[k,"text"], line)
      v2_os_push(TOK[k,"text"])
      continue
    }

    # それ以外は式文脈で予期しないトークン
    v2_diag(line, TOK[k,"col"], "unexpected token in expression: " TOK[k,"text"])
  }

  if (j >= i) v2_os_flush(TOK[j,"line"])
}

# ─── 式区間末尾の探索 ────────────────────────────────────────────

# トークン start から走査し、式が終わる最後のトークン番号を返す。
# 終端条件: 深さ 0 での RBRACE、または文開始 KW (let/function/when/end)。
function v2_find_expr_end(start,    k, depth, t, txt) {
  depth = 0
  for (k = start; k <= TOK["n"]; k++) {
    t   = TOK[k,"kind"]
    txt = TOK[k,"text"]

    if (t == "LP" || t == "LBRACK") { depth++; continue }

    if (t == "RP" || t == "RBRACK") {
      if (depth == 0) return k - 1
      depth--
      continue
    }

    if (t == "LBRACE") { depth++; continue }

    if (t == "RBRACE") {
      if (depth == 0) return k - 1
      depth--
      continue
    }

    if (depth == 0 && t == "KW" &&
        (txt == "let" || txt == "function" || txt == "when" || txt == "end")) {
      return k - 1
    }
  }
  return TOK["n"]
}

# ─── メインエントリ ───────────────────────────────────────────────

function v2_rpn(    i, j, t) {
  RPN["n"]  = 0
  v2_os_sp  = 0
  v2_ops_init()

  i = 1
  while (i <= TOK["n"]) {
    t = TOK[i,"kind"]

    # 代入右辺: = の後続を式区間とみなす
    if (t == "OP" && TOK[i,"text"] == "=") {
      v2_emit_rpn("OPERAND", "=", TOK[i,"line"], "")
      j = v2_find_expr_end(i + 1)
      if (j >= i + 1) v2_shunt_expr(i + 1, j)
      i = j + 1
      continue
    }

    # return 後続を式区間とみなす
    if (t == "KW" && TOK[i,"text"] == "return") {
      v2_emit_rpn("OPERAND", "return", TOK[i,"line"], "")
      j = v2_find_expr_end(i + 1)
      if (j >= i + 1) v2_shunt_expr(i + 1, j)
      i = j + 1
      continue
    }

    # それ以外は素通しで OPERAND
    v2_emit_rpn("OPERAND", TOK[i,"text"], TOK[i,"line"], "")
    i++
  }
}
