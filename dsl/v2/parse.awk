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
function v2_operand_node(val, line) {
  if (val ~ /^[0-9]/) return v2_leaf("NUMLIT", val, line)
  return v2_leaf("IDENT", val, line)
}

# 二項演算子を還元してスタックに積む
function v2_reduce_op(op, line,    id, r, l) {
  r = V2_STK[V2_SP--]
  l = V2_STK[V2_SP--]
  if      (op == "|>") id = v2_node("PIPE", line)
  else if (op == "??") id = v2_node("COALESCE", line)
  else if (op == ".")  id = v2_node("DOT", line)
  else                 { id = v2_node("BINOP", line); AST[id,"text"] = op }
  v2_addchild(id, l)
  v2_addchild(id, r)
  V2_STK[++V2_SP] = id
  return id
}

# 関数呼び出しを還元してスタックに積む
function v2_reduce_call(name, arity, line,    id, k, args) {
  id = v2_node("CALL", line)
  AST[id,"text"] = name
  for (k = arity; k >= 1; k--) args[k] = V2_STK[V2_SP--]
  for (k = 1; k <= arity; k++) v2_addchild(id, args[k])
  V2_STK[++V2_SP] = id
  return id
}

# ─── 文ディスパッチ ────────────────────────────────────────────────

# MARKER に応じてサブパーサを選択し、末尾トークン位置を返す
function v2_stmt_dispatch(marker, i, parent) {
  if (marker == "FUNC_OPEN")          return v2_parse_func(i, parent)
  if (marker == "LET" || \
      marker == "LETQ")               return v2_parse_let(i, parent)
  # RETURN, WHEN 等は Task 6 で実装。ここではスキップ。
  return i
}

# FUNC_OPEN 文（i: FUNC_OPEN の RPN インデックス）
# 消費: OPERAND(fname) [OPERAND(rettype)] body FUNC_CLOSE
# 返す: FUNC_CLOSE の RPN インデックス
function v2_parse_func(i, parent,    fname, func_id, typeann_id, j) {
  fname   = RPN[i+1,"val"]
  func_id = v2_node("FUNC", RPN[i,"line"])
  AST[func_id,"text"] = fname

  # 戻り値型注釈: i+2 が大文字始まりの OPERAND → TYPEANN を追加
  j = i + 2
  if (RPN[j,"kind"] == "OPERAND" && RPN[j,"val"] ~ /^[A-Z]/) {
    typeann_id = v2_leaf("TYPEANN", RPN[j,"val"], RPN[j,"line"])
    v2_addchild(func_id, typeann_id)
    j = i + 3
  }

  # 本体処理（FUNC_CLOSE まで）
  while (j <= RPN["n"]) {
    if (RPN[j,"kind"] == "MARKER") {
      if (RPN[j,"val"] == "FUNC_CLOSE")              break
      if (RPN[j,"val"] == "LET" || \
          RPN[j,"val"] == "LETQ")                    { j = v2_parse_let(j, func_id); continue }
      if (RPN[j,"val"] == "RAWLINE")                 { j++; j++; continue }   # marker + operand
      if (RPN[j,"val"] == "RETURN")                  { j = v2_parse_return(j, func_id); continue }
      # WHEN, OF, ARM_OPEN, ARM_CLOSE, WHEN_END: Task 6
      j++; continue
    }
    if (RPN[j,"kind"] == "OPERAND") V2_STK[++V2_SP] = v2_operand_node(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "OP")   v2_reduce_op(RPN[j,"val"], RPN[j,"line"])
    else if (RPN[j,"kind"] == "CALL") v2_reduce_call(RPN[j,"val"], RPN[j,"arity"], RPN[j,"line"])
    j++
  }

  v2_addchild(parent, func_id)
  return j   # j == FUNC_CLOSE の位置
}

# LET 文（i: LET/LETQ の RPN インデックス）
# 消費: OPERAND(name) [OPERAND(type)] expr... STMT_END
# 返す: STMT_END の RPN インデックス
function v2_parse_let(i, parent,    varname, let_id, typeann_id, j, expr_id) {
  varname = RPN[i+1,"val"]
  let_id  = v2_node("LET", RPN[i,"line"])
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

# RETURN 文スケルトン（Task 5: 式を読み飛ばすのみ）
function v2_parse_return(i, parent,    j) {
  j = i + 1
  while (j <= RPN["n"]) {
    if (RPN[j,"kind"] == "MARKER" && RPN[j,"val"] == "STMT_END") break
    j++
  }
  return j
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
