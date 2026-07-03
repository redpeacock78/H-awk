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

# "(" / "[" または FN: 境界まで OP を出力スタックへ送る（境界は残す）
function v2_pop_until_lp(line,    t) {
  while (v2_os_sp > 0) {
    t = v2_os_top()
    if (t == "(" || t == "[" || t ~ /^FN:/) break
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
  } else {
    v2_diag(line, 1, "unmatched ')'")
  }
}

# "[" を捨て、添字アクセスを二項演算子 INDEX として出力する
function v2_pop_bracket(line,    t) {
  if (v2_os_sp == 0) {
    v2_diag(line, 1, "unmatched ']'")
    return
  }
  t = v2_os_top()
  if (t == "[") {
    v2_os_pop()
    v2_emit_rpn("OP", "INDEX", line, "")
  } else {
    v2_diag(line, 1, "unmatched ']'")
  }
}

# op より優先度が高い（左結合なら同等も）演算子をスタックから出力する
function v2_pop_ge(op, line,    t, tp, op_prec, op_assoc) {
  op_prec  = V2_OP_PREC[op]
  op_assoc = V2_OP_ASSOC[op]
  if (op_prec == "") return   # 未知の演算子
  while (v2_os_sp > 0) {
    t = v2_os_top()
    if (t == "(" || t == "[" || t ~ /^FN:/) break
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
    else if (t == "[")
      v2_diag(line, 1, "unmatched '['")
    else
      v2_emit_rpn("OP", t, line, "")
  }
}

# ─── 操車場法コア ────────────────────────────────────────────────

# 位置 k の IDENT から始まる "a.b.c" 形のドット連結 callee 名を走査する。
# 戻り値: チェーンの直後（DOT でも IDENT でもない最初のトークン）の位置。
# 副作用: V2_CHAIN_NAME にチェーン全体を "." 結合した文字列を格納する。
function v2_scan_dotted_chain(k,    idx) {
  idx = k
  V2_CHAIN_NAME = TOK[idx,"text"]
  idx++
  while (TOK[idx,"kind"] == "DOT" && TOK[idx+1,"kind"] == "IDENT") {
    V2_CHAIN_NAME = V2_CHAIN_NAME "." TOK[idx+1,"text"]
    idx += 2
  }
  return idx
}

# 位置 k（generic の "<" の位置）から型引数 <TYPE> を走査する。
# List<Int> / Dict<Str,Int> のようなネストした generic も v2_skip_type で
# 深さを追跡して丸ごとスキャンする。
# 一致すれば ">" の次の位置を返し V2_GENERIC_ARG に型名を格納する。
# 一致しなければ k をそのまま返し V2_GENERIC_ARG を空にする（generic ではない）。
function v2_scan_generic_arg(k,    idx, end) {
  V2_GENERIC_ARG = ""
  idx = k + 1
  if (TOK[idx,"kind"] != "TYPE" && TOK[idx,"kind"] != "IDENT") return k
  end = v2_skip_type(idx)
  if (!(TOK[end,"kind"] == "OP" && TOK[end,"text"] == ">")) return k
  V2_GENERIC_ARG = v2_read_type_text(idx, end)
  return end + 1
}

# トークン区間 [i, j] を操車場法で RPN に変換する
function v2_shunt_expr(i, j,    k, t, line, arity_idx, saved_sp, prevkind, unary_pos, text, \
                        chain_end, call_open, fname, has_generic) {
  for (k = i; k <= j; k++) {
    t    = TOK[k,"kind"]
    line = TOK[k,"line"]

    # 呼び出し可能な callee の走査: 単純 IDENT、dotted (a.b.c)、
    # generic (f<T>) のいずれも FN: を push する前に callee 全体を収集する。
    # dotted の組込みシグネチャは "ctx.res.text" のようにフルネームで
    # 登録されているため、末尾の識別子だけを CALL 名にすると検査が壊れる。
    if (t == "IDENT") {
      chain_end = v2_scan_dotted_chain(k)
      fname     = V2_CHAIN_NAME
      has_generic = 0
      call_open = chain_end
      if (TOK[chain_end,"kind"] == "OP" && TOK[chain_end,"text"] == "<") {
        call_open = v2_scan_generic_arg(chain_end)
        if (call_open != chain_end) has_generic = 1
        else call_open = chain_end   # generic でなかった（"<" は比較演算子）
      }
      if (TOK[call_open,"kind"] == "LP") {
        # generic 呼び出しは型パラメータを組込み表のキー形式（"_t" 接尾）に
        # 正規化し、型名を第 1 引数の文字列リテラルとして注入する
        # （dsl/desugar_dot.awk の ns.path_t 変換と同じ規約）。
        if (has_generic) fname = fname "_t"
        v2_os_push("FN:" fname)
        # 空引数か判定: LP の次が RP なら arity=0、そうでなければ 1
        # （generic 注入引数がある場合は基底 arity に +1 する）
        V2_ARITY[v2_os_sp] = (TOK[call_open+1,"kind"] == "RP") ? 0 : 1
        if (has_generic) {
          V2_ARITY[v2_os_sp]++
          v2_emit_rpn("OPERAND", "\"" V2_GENERIC_ARG "\"", line, "")
        }
        k = call_open   # LP をスキップ（for の自動 k++ 込みで LP の次へ）
        continue
      }
    }

    if (t == "IDENT" || t == "NUM" || t == "TYPE" || t == "REGEX") {
      v2_emit_rpn("OPERAND", TOK[k,"text"], line, "")
      continue
    }

    # 文字列リテラル（補間 #{ expr } を含む場合は連続する
    # STR / INTERP_OPEN ... INTERP_CLOSE 列をまとめて 1 個の STRLIT オペランドに戻す）
    if (t == "STR" || t == "INTERP_OPEN") {
      if (t == "STR" && TOK[k+1,"kind"] != "INTERP_OPEN") {
        v2_emit_rpn("OPERAND", "\"" TOK[k,"text"] "\"", line, "")
        continue
      }
      text = "\""
      while (k <= j && (TOK[k,"kind"] == "STR" || TOK[k,"kind"] == "INTERP_OPEN")) {
        if (TOK[k,"kind"] == "STR") {
          text = text TOK[k,"text"]
          k++
        } else {
          text = text "#{"
          k++
          while (k <= j && TOK[k,"kind"] != "INTERP_CLOSE") {
            text = text TOK[k,"text"]
            k++
          }
          text = text "}"
          k++   # INTERP_CLOSE をスキップ
        }
      }
      text = text "\""
      k--     # for の自動 k++ 分を差し引く
      v2_emit_rpn("OPERAND", text, line, "")
      continue
    }

    # 空リテラル [] / {}
    if (t == "LBRACK" && TOK[k+1,"kind"] == "RBRACK") {
      v2_emit_rpn("OPERAND", "[]", line, "")
      k++
      continue
    }
    if (t == "LBRACE" && TOK[k+1,"kind"] == "RBRACE") {
      v2_emit_rpn("OPERAND", "{}", line, "")
      k++
      continue
    }

    # 非空 dict リテラル { key: value, ... } の構造トークンは、dict の
    # emit（Task 10）が実装されるまでの間、診断なしで読み飛ばす。
    # 中身の IDENT/STRLIT はそのまま operand として RPN に流れる。
    if (t == "LBRACE" || t == "RBRACE" || t == "COLON") continue

    # 添字式 rows[id] / user["name"]: 直前に値（IDENT/NUM/TYPE/STR/")"/"]"）が
    # あれば非空 "[" を添字アクセスの開始として扱う（二項演算子 INDEX に還元）。
    if (t == "LBRACK") {
      prevkind = (k > i) ? TOK[k-1,"kind"] : ""
      if (prevkind == "IDENT" || prevkind == "NUM" || prevkind == "TYPE" || \
          prevkind == "STR" || prevkind == "RP" || prevkind == "RBRACK") {
        v2_os_push("[")
        continue
      }
    }

    if (t == "RBRACK") {
      v2_pop_until_lp(line)
      v2_pop_bracket(line)
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

    # awk フィールド参照 $0 / $NF は DSL の演算子集合に属さない素の awk 式。
    # 診断せず 1 個の RAW オペランドとして素通しする（$IDENT / $NUM の単純形のみ）。
    if (t == "OP" && TOK[k,"text"] == "$" && \
        (TOK[k+1,"kind"] == "NUM" || TOK[k+1,"kind"] == "IDENT")) {
      v2_emit_rpn("RAW", "$" TOK[k+1,"text"], line, "")
      k++   # フィールド番号/識別子トークンをスキップ
      continue
    }

    if (t == "OP") {
      # 単項 - / ! : 式先頭・演算子直後・"(" 直後・"," 直後に現れる場合は
      # arity 1 の NEG / NOT として扱う（二項演算子として push しない）。
      prevkind  = (k > i) ? TOK[k-1,"kind"] : ""
      unary_pos = (k == i || prevkind == "OP" || prevkind == "LP" || prevkind == "COMMA")
      if (unary_pos && TOK[k,"text"] == "-") {
        v2_os_push("NEG")
      } else if (unary_pos && TOK[k,"text"] == "!") {
        v2_os_push("NOT")
      } else {
        v2_pop_ge(TOK[k,"text"], line)
        v2_os_push(TOK[k,"text"])
      }
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
         txt == "end" || txt == "return" || txt == "type")) {
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
  # "default" は正規の arm 開始キーワード（docs/dsl.md: default / default name:）
  if (!(TOK[i,"kind"] == "IDENT" ||
        (TOK[i,"kind"] == "KW" && TOK[i,"text"] == "default"))) return 0
  for (j = i; j <= TOK["n"]; j++) {
    if (TOK[j,"kind"] == "COLON")                                    return 1
    if (TOK[j,"kind"] == "KW" && TOK[j,"text"] != "default")        return 0
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
  else if (kw == "type")     return v2_rpn_typedecl(i)
  else                        return v2_rpn_stmt(i)
}

# 型注釈開始位置 typestart から v2_skip_type で終端位置まで読み飛ばし、
# 結合したテキスト（Dict<Str, Str> / Str|Int のような複数トークン型）を返す。
function v2_read_type_text(typestart, end,    k, typetext) {
  typetext = ""
  for (k = typestart; k < end; k++)
    typetext = typetext ((TOK[k,"kind"] == "COMMA") ? ", " : TOK[k,"text"])
  return typetext
}

# function NAME( PARAMS ) -> RETTYPE { BODY }
function v2_rpn_func(i,    fname, line, j, typestart) {
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
        j++
        # 型注釈 [: TYPE] → `:TYPE...` として出力（Union/Generic の
        # 複数トークン型に対応。let の型スキャンと同じ v2_skip_type を使う）
        if (TOK[j,"kind"] == "COLON" &&
            (TOK[j+1,"kind"] == "TYPE" || TOK[j+1,"kind"] == "IDENT")) {
          j++  # skip :
          typestart = j
          j = v2_skip_type(j)
          v2_emit_rpn("OPERAND", ":" v2_read_type_text(typestart, j), TOK[typestart,"line"], "")
        }
      } else {
        j++
      }
    }
    if (j <= TOK["n"]) j++  # skip RP
  }

  # -> RETTYPE（Effect<Option<Str>> / Int | Str のような複数トークン型に対応）
  if (j <= TOK["n"] && TOK[j,"kind"] == "ARROW") j++
  if (j <= TOK["n"] && (TOK[j,"kind"] == "TYPE" || TOK[j,"kind"] == "IDENT")) {
    typestart = j
    j = v2_skip_type(j)
    v2_emit_rpn("OPERAND", v2_read_type_text(typestart, j), TOK[typestart,"line"], "")
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
# 区切り記号 < > |）を読み飛ばし、型注釈の直後の位置を返す。
# 例: Dict<Str, Str> / Str|Int / Result<T, E> のような複数トークンの型に対応する。
# `<...>` の深さを追跡し、深さ 0 の COMMA では停止する（呼び出し元がパラメータ
# リストの区切り ',' なのか、Dict<Str, Str> の内側の ',' なのかを区別するため）。
function v2_skip_type(j,    startline, depth) {
  startline = TOK[j,"line"]
  j++   # 型名先頭トークンを読み飛ばす
  depth = 0
  while (j <= TOK["n"] && TOK[j,"line"] == startline) {
    if (TOK[j,"kind"] == "OP" && TOK[j,"text"] == "<") { depth++; j++; continue }
    if (TOK[j,"kind"] == "OP" && TOK[j,"text"] == ">") {
      if (depth == 0) break
      depth--; j++; continue
    }
    if (TOK[j,"kind"] == "OP" && TOK[j,"text"] == "|") { j++; continue }
    # Intersection 型エイリアス（docs/dsl.md:506: `Int & Str`）にも対応（AP）
    if (TOK[j,"kind"] == "OP" && TOK[j,"text"] == "&") { j++; continue }
    if (TOK[j,"kind"] == "COMMA") {
      if (depth == 0) break
      j++; continue
    }
    if (TOK[j,"kind"] == "TYPE" || TOK[j,"kind"] == "IDENT") { j++; continue }
    break
  }
  return j
}

# type NAME = TYPE_EXPR（型エイリアス宣言、docs/dsl.md:504-506。AP）
# Union（|）/ Intersection（&）の単一行形のみ対応する。record 形
# （`type Todo = { ... }` docs/dsl.md:123）は Task 10/11（emit）と合わせて
# 別途対応が必要なスコープのため、ここでは扱わない（報告書に明記）。
function v2_rpn_typedecl(i,    line, name, j, typestart, typetext) {
  line = TOK[i,"line"]
  name = TOK[i+1,"text"]

  v2_emit_rpn("MARKER", "TYPEDECL", line, "")
  v2_emit_rpn("OPERAND", name, line, "")

  j = i + 2
  typetext = ""
  if (j <= TOK["n"] && TOK[j,"kind"] == "OP" && TOK[j,"text"] == "=") {
    j++
    typestart = j
    j = v2_skip_type(j)
    typetext = v2_read_type_text(typestart, j)
  }
  v2_emit_rpn("OPERAND", typetext, line, "")
  v2_emit_rpn("MARKER", "STMT_END", line, "")
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

  # 裸の let 宣言（hoist 形 `let tmp` / `let n: Int`、= も ?= もない）は
  # 初期化式を持たない。次文の先頭トークンを無条件に initializer として
  # shunt しないよう、= / ?= がある場合のみ RHS をパースする。
  if (j <= TOK["n"] && TOK[j,"kind"] == "OP" && (TOK[j,"text"] == "=" || TOK[j,"text"] == "?=")) {
    j++  # = または ?= をスキップ
    expr_end = v2_find_expr_end(j)
    if (expr_end >= j) {
      v2_shunt_expr(j, expr_end)
    } else {
      expr_end = j - 1
    }
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

  # 同一行上の式トークンを、深さ 0 の RBRACE/RP/RBRACK で終端する
  # v2_find_expr_end で収集する（`function f() -> Str { return x }` の
  # ような 1 行関数で、閉じ } を式に含めてしまわないため）。
  if (i <= TOK["n"] && TOK[i,"line"] == line) {
    j = v2_find_expr_end(i)
    if (j >= i) v2_shunt_expr(i, j)
  } else {
    j = i - 1   # 式なし
  }

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

# 行頭が素の awk 文形式（print / printf 等）かどうかを判定する
function v2_is_awk_stmt_head(i) {
  return TOK[i,"kind"] == "IDENT" && (TOK[i,"text"] == "print" || TOK[i,"text"] == "printf")
}

# その他の文（裸の式文・代入・未知トークン）
function v2_rpn_stmt(i,    j, line) {
  line = TOK[i,"line"]

  if (v2_is_rawline(i) || v2_is_awk_stmt_head(i)) {
    # 解釈不能トークン列を RAWLINE マーカーで素通し
    v2_emit_rpn("MARKER",  "RAWLINE",             line, "")
    v2_emit_rpn("OPERAND", V2_LINE_TEXT[line], line, "")
    j = i
    while (j <= TOK["n"] && TOK[j,"line"] == line) j++
    return j
  }

  j = v2_find_expr_end(i)
  if (j >= i) {
    # 裸の式文（例: hawk.app.get("/x", "h")）も EXPR/STMT_END で囲んで
    # parse 側に還元させる（囲まないと式の結果が AST に接続されず消える）。
    v2_emit_rpn("MARKER", "EXPR", line, "")
    v2_shunt_expr(i, j)
    v2_emit_rpn("MARKER", "STMT_END", TOK[j,"line"], "")
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
