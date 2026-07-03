# SPDX-License-Identifier: MIT
# dsl/v2/parse.awk -- RPN スタック還元による式 AST 構築
#
# 消費: RPN[]（dsl/v2/rpn.awk）
# 生成: AST[], V2_NAST
#
# AST[id,"kind"]  ノード種別
# AST[id,"line"]  ソース行番号
# AST[id,"nc"]    子ノード数
# AST[id,"c"k]    k 番目の子ノード ID (1-indexed)
# AST[id,"text"]  リーフテキスト（または FUNC/LET/CALL の名前）
#
# V2_NAST  最後に割り当てた AST ノード ID
# V2_STK[] 式還元スタック
# V2_SP    スタックポインタ

# ─── ノード生成ヘルパー ───────────────────────────────────────────

function v2_node(kind, line,    id) {
  id = ++V2_NAST
  AST[id,"kind"] = kind
  AST[id,"line"] = line
  AST[id,"nc"]   = 0
  return id
}

function v2_leaf(kind, text, line,    id) {
  id = v2_node(kind, line)
  AST[id,"text"] = text
  return id
}

function v2_addchild(parent, child) {
  AST[parent,"nc"]++
  AST[parent,"c" AST[parent,"nc"]] = child
}

# ─── 式還元 ──────────────────────────────────────────────────────

# OPERAND の val から適切なリーフノードを返す
# val ~ /^"/ のとき STRLIT（引用符を含むまま text に保持）
function v2_operand_node(val, line) {
  if (val ~ /^[0-9]/) return v2_leaf("NUMLIT", val, line)
  if (val ~ /^"/)     return v2_leaf("STRLIT", val, line)
  return v2_leaf("IDENT", val, line)
}

# 二項演算子を還元してスタックに積む
function v2_reduce_op(op, line,    id, r, l) {
  # 単項演算子 NEG / NOT はオペランドを 1 つだけ消費する
  if (op == "NEG" || op == "NOT") {
    if (V2_SP < 1) { v2_diag(line, 0, "stack underflow on operator '" op "'"); return }
    r = V2_STK[V2_SP--]
    id = v2_node("UNOP", line)
    AST[id,"text"] = op
    v2_addchild(id, r)
    V2_STK[++V2_SP] = id
    return id
  }

  if (V2_SP < 2) { v2_diag(line, 0, "stack underflow on operator '" op "'"); return }
  r = V2_STK[V2_SP--]
  l = V2_STK[V2_SP--]
  if      (op == "|>")    id = v2_node("PIPE", line)
  else if (op == "??")    id = v2_node("COALESCE", line)
  else if (op == ".")     id = v2_node("DOT", line)
  else if (op == "INDEX") id = v2_node("INDEX", line)
  else                    { id = v2_node("BINOP", line); AST[id,"text"] = op }
  v2_addchild(id, l)
  v2_addchild(id, r)
  V2_STK[++V2_SP] = id
  return id
}

# 関数呼び出しを還元してスタックに積む
function v2_reduce_call(name, arity, line,    id, k, args) {
  if (arity > V2_SP) { v2_diag(line, 0, "stack underflow on call '" name "'"); return }
  id = v2_node("CALL", line)
  AST[id,"text"] = name
  for (k = arity; k >= 1; k--) args[k] = V2_STK[V2_SP--]
  for (k = 1; k <= arity; k++) v2_addchild(id, args[k])
  V2_STK[++V2_SP] = id
  return id
}

# 式トークン列を MARKER まで消費し、スタックトップを parent に addchild する
# i: 開始位置（MARKER 直後の最初の式トークン）
# 戻り値: MARKER の位置（まだ消費していない）
function v2_expr_until_marker(i, parent,    sp_saved, expr_id) {
  sp_saved = V2_SP
  while (i <= RPN["n"]) {
    if (RPN[i,"kind"] == "MARKER") break
    if (RPN[i,"kind"] == "OPERAND") V2_STK[++V2_SP] = v2_operand_node(RPN[i,"val"], RPN[i,"line"])
    else if (RPN[i,"kind"] == "OP")   v2_reduce_op(RPN[i,"val"], RPN[i,"line"])
    else if (RPN[i,"kind"] == "CALL") v2_reduce_call(RPN[i,"val"], RPN[i,"arity"], RPN[i,"line"])
    else if (RPN[i,"kind"] == "RAW")  V2_STK[++V2_SP] = v2_leaf("RAW", RPN[i,"val"], RPN[i,"line"])
    i++
  }
  if (V2_SP > sp_saved) {
    expr_id = V2_STK[V2_SP--]
    v2_addchild(parent, expr_id)
    V2_SP = sp_saved
  }
  return i
}

# ─── パターン解析 ─────────────────────────────────────────────────

# パターンテキストを PAT ノードに変換する
# "ok r"   → PAT(text=ok,  c1=IDENT r)
# "ng _"   → PAT(text=ng,  c1=IDENT _)
# "some v" → PAT(text=some, c1=IDENT v)
# "none"   → PAT(text=none)
# "_"      → PAT(text=_)
function v2_parse_pat(text, line,    pat_id, parts, n, k, m) {
  pat_id = v2_node("PAT", line)
  n = split(text, parts, " ")
  # 型付き no-bind パターン `ng<AuthError>`（バインド変数なし）は parts[1] 自体に
  # `<...>` が来る。この場合はタグ名と TYPEANN のみに分離する（IDENT は生成しない）。
  if (match(parts[1], /^([^<]+)<([^>]+)>$/, m)) {
    AST[pat_id,"text"] = m[1]
    v2_addchild(pat_id, v2_leaf("TYPEANN", m[2], line))
  } else {
    AST[pat_id,"text"] = parts[1]
  }
  for (k = 2; k <= n; k++) {
    # `e<NotFoundError>` → IDENT(e) + TYPEANN(NotFoundError)
    if (match(parts[k], /^([^<]+)<([^>]+)>$/, m)) {
      v2_addchild(pat_id, v2_leaf("IDENT",   m[1], line))
      v2_addchild(pat_id, v2_leaf("TYPEANN", m[2], line))
    } else {
      v2_addchild(pat_id, v2_leaf("IDENT", parts[k], line))
    }
  }
  return pat_id
}

# ─── ブロック・パニック ────────────────────────────────────────────

# close_marker まで文を積む
# 戻り値: close_marker の一つ後の位置
function v2_p_block(i, parent, close_marker) {
  while (i <= RPN["n"] && !(RPN[i,"kind"] == "MARKER" && RPN[i,"val"] == close_marker)) {
    if (RPN[i,"kind"] == "MARKER") {
      i = v2_stmt_dispatch(RPN[i,"val"], i, parent)
      i++  # 終端マーカーを読み飛ばす
    } else {
      i++
    }
  }
  return i + 1  # close_marker の次
}

# 次の FUNC_OPEN / WHEN_END / STMT_END まで読み飛ばす（エラー回復）
function v2_panic_skip(i) {
  while (i <= RPN["n"]) {
    if (RPN[i,"val"] == "FUNC_OPEN" || \
        RPN[i,"val"] == "WHEN_END"  || \
        RPN[i,"val"] == "STMT_END") return i
    i++
  }
  return i
}

# ─── 文ディスパッチ ────────────────────────────────────────────────

# MARKER に応じてサブパーサを選択し、末尾トークン位置を返す
function v2_stmt_dispatch(marker, i, parent) {
  if (marker == "FUNC_OPEN")          return v2_parse_func(i, parent)
  if (marker == "LET" || \
      marker == "LETQ")               return v2_parse_let(i, parent)
  if (marker == "RETURN")             return v2_parse_return(i, parent)
  if (marker == "WHEN")               return v2_p_when(i, parent)
  if (marker == "EXPR")               return v2_parse_expr_stmt(i, parent)
  if (marker == "RAWLINE")            return v2_parse_rawline(i, parent)
  return i
}

# ─── 素の awk 行（passthrough） ───────────────────────────────────

# RAWLINE 文（i: RAWLINE の RPN インデックス）
# 消費: marker + operand（元行テキスト）の 2 トークン
# emit（Task 10-11）が passthrough するために元行テキストを AST に保持する。
function v2_parse_rawline(i, parent,    id) {
  id = v2_leaf("RAWLINE", RPN[i+1,"val"], RPN[i,"line"])
  v2_addchild(parent, id)
  return i + 1
}

# ─── 裸の式文 ────────────────────────────────────────────────────

# EXPR 文（i: EXPR の RPN インデックス）
# 消費: expr... STMT_END
# 返す: STMT_END の RPN インデックス
function v2_parse_expr_stmt(i, parent,    id) {
  id = v2_node("EXPR", RPN[i,"line"])
  i  = v2_expr_until_marker(i + 1, id)   # STMT_END まで式を還元
  v2_addchild(parent, id)
  return i   # STMT_END の位置
}

# ─── when 文 ────────────────────────────────────────────────────

function v2_p_when(i, parent,    id, arm, blk) {
  id = v2_node("WHEN", RPN[i,"line"])
  i = v2_expr_until_marker(i + 1, id)   # 対象式（OF マーカーまで）
  i++                                    # OF を消費
  while (RPN[i,"val"] == "ARM_OPEN") {
    arm = v2_node("ARM", RPN[i,"line"])
    v2_addchild(arm, v2_parse_pat(RPN[i+1,"val"], RPN[i+1,"line"]))
    blk = v2_node("BLOCK", RPN[i,"line"])
    v2_addchild(arm, blk)
    i = v2_p_block(i + 2, blk, "ARM_CLOSE")  # ARM_CLOSE まで文を積む
    v2_addchild(id, arm)
  }
  if (RPN[i,"val"] != "WHEN_END") {
    v2_diag(AST[id,"line"], 1, "unclosed 'when' (missing 'end')")
    i = v2_panic_skip(i)
  }
  v2_addchild(parent, id)
  return i  # WHEN_END の位置
}

# ─── FUNC_OPEN 文 ────────────────────────────────────────────────

# FUNC_OPEN 文（i: FUNC_OPEN の RPN インデックス）
# 消費: OPERAND(fname) [PARAM...] [OPERAND(rettype)] body FUNC_CLOSE
# 返す: FUNC_CLOSE の RPN インデックス
function v2_parse_func(i, parent,    fname, func_id, typeann_id, param_id, j) {
  fname   = RPN[i+1,"val"]
  func_id = v2_node("FUNC", RPN[i,"line"])
  AST[func_id,"text"] = fname

  # パラメータ・戻り値型を処理
  j = i + 2
  while (RPN[j,"kind"] == "OPERAND") {
    if (RPN[j,"val"] ~ /^[A-Z]/) {
      # 戻り値型
      typeann_id = v2_leaf("TYPEANN", RPN[j,"val"], RPN[j,"line"])
      v2_addchild(func_id, typeann_id)
      j++
      break
    } else {
      # パラメータ名
      param_id = v2_node("PARAM", RPN[j,"line"])
      AST[param_id,"text"] = RPN[j,"val"]
      j++
      # 型注釈チェック: 次が `:TYPE`
      if (RPN[j,"kind"] == "OPERAND" && RPN[j,"val"] ~ /^:/) {
        typeann_id = v2_leaf("TYPEANN", substr(RPN[j,"val"], 2), RPN[j,"line"])
        v2_addchild(param_id, typeann_id)
        j++
      }
      v2_addchild(func_id, param_id)
    }
  }

  # 本体処理（FUNC_CLOSE まで）
  while (j <= RPN["n"]) {
    if (RPN[j,"kind"] == "MARKER") {
      if (RPN[j,"val"] == "FUNC_CLOSE")              break
      if (RPN[j,"val"] == "LET" || \
          RPN[j,"val"] == "LETQ")                    { j = v2_parse_let(j, func_id); continue }
      if (RPN[j,"val"] == "RAWLINE")                 { j = v2_parse_rawline(j, func_id) + 1; continue }
      if (RPN[j,"val"] == "RETURN")                  { j = v2_parse_return(j, func_id); continue }
      if (RPN[j,"val"] == "WHEN")                    { j = v2_p_when(j, func_id); continue }
      if (RPN[j,"val"] == "EXPR")                    { j = v2_parse_expr_stmt(j, func_id); continue }
      j++; continue
    }
    if (RPN[j,"kind"] == "OPERAND") V2_STK[++V2_SP] = v2_operand_node(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "OP")   v2_reduce_op(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "CALL") v2_reduce_call(RPN[j,"val"], RPN[j,"arity"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "RAW")  V2_STK[++V2_SP] = v2_leaf("RAW", RPN[j,"val"], RPN[j,"line"])
    j++
  }

  v2_addchild(parent, func_id)
  return j   # j == FUNC_CLOSE の位置
}

# ─── LET / LETQ 文 ───────────────────────────────────────────────

# LET 文（i: LET/LETQ の RPN インデックス）
# 消費: OPERAND(name) [OPERAND(type)] expr... STMT_END
# 返す: STMT_END の RPN インデックス
function v2_parse_let(i, parent,    varname, let_id, typeann_id, j, expr_id) {
  varname = RPN[i+1,"val"]
  let_id  = v2_node(RPN[i,"val"], RPN[i,"line"])   # LET または LETQ
  AST[let_id,"text"] = varname

  # 型注釈: i+2 が大文字始まりの OPERAND → TYPEANN を追加
  j = i + 2
  if (RPN[j,"kind"] == "OPERAND" && RPN[j,"val"] ~ /^[A-Z]/) {
    typeann_id = v2_leaf("TYPEANN", RPN[j,"val"], RPN[j,"line"])
    v2_addchild(let_id, typeann_id)
    j = i + 3
  }

  # 式処理（STMT_END まで）
  while (j <= RPN["n"]) {
    if (RPN[j,"kind"] == "MARKER") {
      if (RPN[j,"val"] == "STMT_END") break
    }
    if (RPN[j,"kind"] == "OPERAND") V2_STK[++V2_SP] = v2_operand_node(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "OP")   v2_reduce_op(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "CALL") v2_reduce_call(RPN[j,"val"], RPN[j,"arity"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "RAW")  V2_STK[++V2_SP] = v2_leaf("RAW", RPN[j,"val"], RPN[j,"line"])
    j++
  }

  # スタックトップ = 式の結果
  if (V2_SP >= 1) {
    expr_id = V2_STK[V2_SP--]
    v2_addchild(let_id, expr_id)
  }

  v2_addchild(parent, let_id)
  return j   # j == STMT_END の位置
}

# ─── RETURN 文 ──────────────────────────────────────────────────

# RETURN 文（i: RETURN の RPN インデックス）
# 消費: expr... STMT_END
# 返す: STMT_END の RPN インデックス
function v2_parse_return(i, parent,    j, return_id, sp_saved, expr_id) {
  return_id = v2_node("RETURN", RPN[i,"line"])
  sp_saved = V2_SP
  j = i + 1
  while (j <= RPN["n"]) {
    if (RPN[j,"kind"] == "MARKER" && RPN[j,"val"] == "STMT_END") break
    if (RPN[j,"kind"] == "OPERAND") V2_STK[++V2_SP] = v2_operand_node(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "OP")   v2_reduce_op(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "CALL") v2_reduce_call(RPN[j,"val"], RPN[j,"arity"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "RAW")  V2_STK[++V2_SP] = v2_leaf("RAW", RPN[j,"val"], RPN[j,"line"])
    j++
  }
  if (V2_SP > sp_saved) {
    expr_id = V2_STK[V2_SP--]
    v2_addchild(return_id, expr_id)
    V2_SP = sp_saved
  }
  v2_addchild(parent, return_id)
  return j   # j == STMT_END の位置
}

# ─── エントリポイント ─────────────────────────────────────────────

function v2_parse(    i, kind, root) {
  V2_NAST = 0
  V2_SP   = 0
  root = v2_node("PROGRAM", 1)
  i = 1
  while (i <= RPN["n"]) {
    kind = RPN[i,"kind"]
    if      (kind == "OPERAND") V2_STK[++V2_SP] = v2_operand_node(RPN[i,"val"], RPN[i,"line"])
    else if (kind == "OP")      v2_reduce_op(RPN[i,"val"], RPN[i,"line"])
    else if (kind == "CALL")    v2_reduce_call(RPN[i,"val"], RPN[i,"arity"], RPN[i,"line"])
    else if (kind == "MARKER")  i = v2_stmt_dispatch(RPN[i,"val"], i, root)
    i++
  }
}
