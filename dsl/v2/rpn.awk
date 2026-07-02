# SPDX-License-Identifier: MIT
# dsl/v2/rpn.awk -- 操車場法による RPN 中間表現の生成
#
# v2_rpn()  : TOK[] を走査し RPN[] を埋める（文駆動）
#
# RPN[i,"kind"]  : OPERAND | OP | CALL | MARKER
# RPN[i,"val"]   : マーカー名 or 演算子 or オペランドテキスト or 関数名
# RPN[i,"line"]  : ソース行番号
# RPN[i,"arity"] : CALL のみ。その他は空。
#
# MARKER val 語彙:
#   FUNC_OPEN  FUNC_CLOSE
#   LET  LETQ
#   WHEN  OF  ARM_OPEN  ARM_CLOSE  WHEN_END
#   RETURN  STMT_END  RAWLINE

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
      v2_emit_rpn("OPERAND", (t == "STR") ? ("\"" TOK[k,"text"] "\"") : TOK[k,"text"], line, "")
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
# 終端条件: 深さ 0 での RBRACE/RP/RBRACK、文開始 KW (let/function/when/end/return)、
# または深さ 0 でのソース行の変化（式は原則同一行内で終端する。丸括弧・角括弧・
# 波括弧による継続は depth > 0 のため対象外）。
function v2_find_expr_end(start,    k, depth, t, txt, startline) {
  depth     = 0
  startline = TOK[start,"line"]
  for (k = start; k <= TOK["n"]; k++) {
    t   = TOK[k,"kind"]
    txt = TOK[k,"text"]

    if (depth == 0 && k > start && TOK[k,"line"] != startline) return k - 1

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
        (txt == "let" || txt == "function" || txt == "when" ||
         txt == "end" || txt == "return")) {
      return k - 1
    }
  }
  return TOK["n"]
}

# ─── when 腕パターン判定 ─────────────────────────────────────────

# 位置 i から始まる when 腕パターン（IDENT... COLON）かどうかを返す。
# KW や演算子（< > 以外）が COLON より先に出れば 0。
function v2_is_arm_pat(i,    j) {
  if (i > TOK["n"]) return 0
  if (TOK[i,"kind"] != "IDENT") return 0
  for (j = i; j <= TOK["n"]; j++) {
    if (TOK[j,"kind"] == "COLON")                                    return 1
    if (TOK[j,"kind"] == "KW")                                       return 0
    if (TOK[j,"kind"] == "OP" &&
        TOK[j,"text"] != "<" && TOK[j,"text"] != ">")               return 0
    if (TOK[j,"kind"] == "LP"     || TOK[j,"kind"] == "LBRACE")     return 0
    if (TOK[j,"kind"] == "RBRACE" || TOK[j,"kind"] == "RP")         return 0
  }
  return 0
}

# ─── 文構造パーサ ────────────────────────────────────────────────

# KW に応じてサブパーサを選択するディスパッチャ
function v2_rpn_dispatch(i,    kw) {
  kw = (TOK[i,"kind"] == "KW") ? TOK[i,"text"] : ""
  if      (kw == "function") return v2_rpn_func(i)
  else if (kw == "let")      return v2_rpn_let(i)
  else if (kw == "when")     return v2_rpn_when(i)
  else if (kw == "return")   return v2_rpn_return(i)
  else                        return v2_rpn_stmt(i)
}

# function NAME( PARAMS ) -> RETTYPE { BODY }
function v2_rpn_func(i,    fname, line, j) {
  line  = TOK[i,"line"]
  fname = TOK[i+1,"text"]

  v2_emit_rpn("MARKER", "FUNC_OPEN", line, "")
  v2_emit_rpn("OPERAND", fname, line, "")

  j = i + 2  # LP の位置

  # パラメータリスト ( IDENT [: TYPE] [, ...] )
  if (j <= TOK["n"] && TOK[j,"kind"] == "LP") {
    j++  # skip LP
    while (j <= TOK["n"] && TOK[j,"kind"] != "RP") {
      if (TOK[j,"kind"] == "IDENT") {
        v2_emit_rpn("OPERAND", TOK[j,"text"], TOK[j,"line"], "")
        # 型注釈 [: TYPE] → `:TYPE` として出力（パラメータ型を parse で識別）
        if (TOK[j+1,"kind"] == "COLON" &&
            (TOK[j+2,"kind"] == "TYPE" || TOK[j+2,"kind"] == "IDENT")) {
          v2_emit_rpn("OPERAND", ":" TOK[j+2,"text"], TOK[j+2,"line"], "")
        }
      }
      j++
    }
    if (j <= TOK["n"]) j++  # skip RP
  }

  # -> RETTYPE
  if (j <= TOK["n"] && TOK[j,"kind"] == "ARROW") j++
  if (j <= TOK["n"] && (TOK[j,"kind"] == "TYPE" || TOK[j,"kind"] == "IDENT")) {
    v2_emit_rpn("OPERAND", TOK[j,"text"], TOK[j,"line"], "")
    j++
  }

  # { BODY }
  if (j <= TOK["n"] && TOK[j,"kind"] == "LBRACE") j++

  # 本体トークン列を文ディスパッチで処理
  while (j <= TOK["n"]) {
    if (TOK[j,"kind"] == "RBRACE") {
      v2_emit_rpn("MARKER", "FUNC_CLOSE", TOK[j,"line"], "")
      return j + 1
    }
    j = v2_rpn_dispatch(j)
  }
  # } が見つからない場合の安全終端
  v2_emit_rpn("MARKER", "FUNC_CLOSE", (TOK["n"] > 0 ? TOK[TOK["n"],"line"] : 1), "")
  return TOK["n"] + 1
}

# 型注釈の先頭トークン位置 j から、型を構成するトークン（TYPE/IDENT と
# 区切り記号 < > |）を読み飛ばし、型注釈の直後（= / ?= が来るはず）の位置を返す。
# 例: Dict<Str, Str> / Str|Int / Result<T, E> のような複数トークンの型に対応する。
function v2_skip_type(j) {
  j++   # 型名先頭トークンを読み飛ばす
  while (j <= TOK["n"] &&
         ((TOK[j,"kind"] == "OP" &&
           (TOK[j,"text"] == "<" || TOK[j,"text"] == ">" || TOK[j,"text"] == "|")) ||
          TOK[j,"kind"] == "TYPE" || TOK[j,"kind"] == "IDENT" || TOK[j,"kind"] == "COMMA"))
    j++
  return j
}

# let NAME [: TYPE] = EXPR  または  let NAME [: TYPE] ?= EXPR
function v2_rpn_let(i,    line, name, j, marker, expr_end, typestart, typetext, k) {
  line = TOK[i,"line"]
  name = TOK[i+1,"text"]

  # LET / LETQ 判別: 型注釈を読み飛ばして代入演算子を確認
  j = i + 2
  if (TOK[j,"kind"] == "COLON") j = v2_skip_type(j + 1)
  marker = (TOK[j,"kind"] == "OP" && TOK[j,"text"] == "?=") ? "LETQ" : "LET"

  v2_emit_rpn("MARKER", marker, line, "")
  v2_emit_rpn("OPERAND", name, line, "")

  # 型注釈 [: TYPE]（Dict<Str, Str> / Str|Int のような複数トークンの型に対応）
  j = i + 2
  if (TOK[j,"kind"] == "COLON") {
    j++  # skip :
    typestart = j
    j = v2_skip_type(j)
    typetext = ""
    for (k = typestart; k < j; k++)
      typetext = typetext ((TOK[k,"kind"] == "COMMA") ? ", " : TOK[k,"text"])
    v2_emit_rpn("OPERAND", typetext, TOK[typestart,"line"], "")
  }

  # = または ?= をスキップ
  if (j <= TOK["n"] && TOK[j,"kind"] == "OP") j++

  # 右辺式を操車場法で変換
  expr_end = v2_find_expr_end(j)
  if (expr_end >= j) {
    v2_shunt_expr(j, expr_end)
  } else {
    expr_end = j - 1
  }

  v2_emit_rpn("MARKER", "STMT_END", (expr_end >= j ? TOK[expr_end,"line"] : line), "")
  return expr_end + 1
}

# when EXPR of ARM... end
function v2_rpn_when(i,    line, j, end_idx, depth, k, pat_text, arm_line) {
  line = TOK[i,"line"]
  v2_emit_rpn("MARKER", "WHEN", line, "")
  i++  # skip "when"

  # "of" を探す（対象式はその直前まで）
  j = i
  while (j <= TOK["n"] && !(TOK[j,"kind"] == "KW" && TOK[j,"text"] == "of")) j++
  # 対象式 [i, j-1] を操車場法で変換
  if (j > i) v2_shunt_expr(i, j - 1)
  v2_emit_rpn("MARKER", "OF", TOK[j,"line"], "")

  # 対応する "end" を探す（ネストした when...end に対応）
  depth   = 0
  end_idx = j + 1
  while (end_idx <= TOK["n"]) {
    if (TOK[end_idx,"kind"] == "KW" && TOK[end_idx,"text"] == "when") depth++
    if (TOK[end_idx,"kind"] == "KW" && TOK[end_idx,"text"] == "end") {
      if (depth == 0) break
      depth--
    }
    end_idx++
  }
  if (end_idx > TOK["n"]) v2_diag(line, 1, "unclosed 'when' (missing 'end')")

  i = j + 1  # 最初の腕パターン開始位置

  # 腕ループ: end_idx の "end" まで
  while (i < end_idx) {
    # 腕パターン: COLON まで収集してパターン文字列を生成
    arm_line = TOK[i,"line"]
    pat_text = ""
    k = i
    while (k < end_idx && TOK[k,"kind"] != "COLON") {
      # `<` / `>` / `<` 直後はスペースなしで連結（型注釈 e<NotFoundError> 対応）
      if (pat_text != "" && TOK[k,"text"] != ">" && TOK[k,"text"] != "<" && \
          (k == i || TOK[k-1,"text"] != "<"))
        pat_text = pat_text " "
      pat_text = pat_text TOK[k,"text"]
      k++
    }
    v2_emit_rpn("MARKER", "ARM_OPEN", arm_line, "")
    v2_emit_rpn("OPERAND", pat_text, arm_line, "")
    i = k + 1  # COLON をスキップして腕本体へ

    # 腕本体: 次の腕パターン開始または end まで文をディスパッチ
    while (i < end_idx && !v2_is_arm_pat(i)) {
      i = v2_rpn_dispatch(i)
    }

    # ARM_CLOSE の行は次の腕パターンまたは "end" の行
    v2_emit_rpn("MARKER", "ARM_CLOSE", TOK[i,"line"], "")
  }

  v2_emit_rpn("MARKER", "WHEN_END", TOK[end_idx,"line"], "")
  return end_idx + 1  # "end" をスキップ
}

# return EXPR（式は同一行に限定）
function v2_rpn_return(i,    line, j) {
  line = TOK[i,"line"]
  v2_emit_rpn("MARKER", "RETURN", line, "")
  i++  # skip "return"

  # 同一行上の式トークンを収集
  j = i
  while (j <= TOK["n"] && TOK[j,"line"] == line) j++
  j--  # j は同一行の最後のトークン（i-1 は式なしを意味する）

  if (j >= i) v2_shunt_expr(i, j)

  v2_emit_rpn("MARKER", "STMT_END", line, "")
  return j + 1
}

# 位置 i の行が式文として解釈不能かどうかを判定
# (v2_shunt_expr が扱えない LBRACE/LBRACK/RBRACK/COLON/ARROW/INTERP_* を含む)
function v2_is_rawline(i,    line, j, k) {
  line = TOK[i,"line"]
  for (j = i; j <= TOK["n"] && TOK[j,"line"] == line; j++) {
    k = TOK[j,"kind"]
    if (k == "LBRACE"     || k == "LBRACK"      || k == "RBRACK" ||
        k == "COLON"      || k == "ARROW"        ||
        k == "INTERP_OPEN" || k == "INTERP_CLOSE") return 1
  }
  return 0
}

# その他の文（裸の式文・代入・未知トークン）
function v2_rpn_stmt(i,    j, line) {
  line = TOK[i,"line"]

  if (v2_is_rawline(i)) {
    # 解釈不能トークン列を RAWLINE マーカーで素通し
    v2_emit_rpn("MARKER",  "RAWLINE",             line, "")
    v2_emit_rpn("OPERAND", V2_LINE_TEXT[line], line, "")
    j = i
    while (j <= TOK["n"] && TOK[j,"line"] == line) j++
    return j
  }

  j = v2_find_expr_end(i)
  if (j >= i) {
    v2_shunt_expr(i, j)
  } else {
    j = i  # 最低 1 トークン進める（無限ループ防止）
  }
  return j + 1
}

# ─── メインエントリ ───────────────────────────────────────────────

function v2_rpn(    i) {
  RPN["n"]  = 0
  v2_os_sp  = 0
  v2_ops_init()

  i = 1
  while (i <= TOK["n"]) {
    i = v2_rpn_dispatch(i)
  }
}
