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

# 添字 "[" の内側（深さ 1）にトップレベルのカンマがあるかを調べ、あれば
# 対応する閉じ "]" の位置を返す（`rows[i, "id"]` のような awk 組込みの
# 多次元連想配列アクセス。v2 は構造化 INDEX 二項演算子でこの形を表現
# できない = v2_index_assign_eq の既存判断 review EB と同じ）。カンマが
# 無い、またはネストした "[" を含む、または行内で閉じない場合は 0 を返す
# （呼び出し元は通常の単純添字として v2_pop_bracket 経路に委ねる）。
function v2_find_multidim_close(open_pos, line,    j, depth, has_comma) {
  depth = 1
  has_comma = 0
  for (j = open_pos + 1; j <= TOK["n"] && TOK[j,"line"] == line; j++) {
    if      (TOK[j,"kind"] == "LBRACK") depth++
    else if (TOK[j,"kind"] == "RBRACK") {
      depth--
      if (depth == 0) return has_comma ? j : 0
    } else if (TOK[j,"kind"] == "COMMA" && depth == 1) has_comma = 1
  }
  return 0
}

# 添字 "[" open_pos の直後から閉じ "]" close_pos の直前までのトークン列を、
# 元の awk 添字式に近い形（`i, "id"`）のテキストへ復元する。
function v2_read_subscript_text(open_pos, close_pos,    m, text) {
  text = ""
  for (m = open_pos + 1; m < close_pos; m++) {
    if      (TOK[m,"kind"] == "COMMA") text = text ", "
    else if (TOK[m,"kind"] == "STR")   text = text "\"" TOK[m,"text"] "\""
    else                                text = text TOK[m,"text"]
  }
  return text
}

# トークン区間 [start, end] を、可能なら元のソース行テキストから該当区間を
# 切り出して復元する（トークン化で失われた空白・引用符を保つ）。複数行に
# またがる場合はトークンを機械的に再結合したテキストへフォールバックする。
function v2_read_span_text(start, end,    ln, scol, ecol, etoklen) {
  ln = TOK[start,"line"]
  if (TOK[end,"line"] == ln && (ln in V2_LINE_TEXT)) {
    scol    = TOK[start,"col"]
    etoklen = length(TOK[end,"text"]) + (TOK[end,"kind"] == "STR" ? 2 : 0)
    ecol    = TOK[end,"col"] + etoklen - 1
    return substr(V2_LINE_TEXT[ln], scol, ecol - scol + 1)
  }
  return v2_read_subscript_text(start - 1, end + 1)
}

# トークン区間 [i, j] を操車場法で RPN に変換する
function v2_shunt_expr(i, j,    k, t, line, arity_idx, saved_sp, prevkind, unary_pos, text, \
                        chain_end, call_open, fname, has_generic, multidim_close) {
  # 三項式 `cond ? a : b` は v2 の演算子集合として構造化サポートしていない
  # （PREC["?"] 未登録。"?" は単項でも二項でもなく素通りし、":" は
  # dict リテラルの COLON と共有トークンのため continue で読み飛ばされる
  # だけで、結果として不正な演算子木が組み立てられていた。pre-Task12
  # botfix 2）。v1 実測（`gawk -f dsl/desugar.awk`）では三項式は型検査
  # されず let の type::coerce でラップされるだけで内部構造には一切
  # 踏み込まない（無検査 passthrough）。v2 も同じ寛容さに合わせるため、
  # 区間内に "?" 演算子トークンが 1 つでもあれば区間全体を 1 個の RAW
  # オペランドとして素通しする（型は Unknown、check.awk の型検査対象外）。
  for (k = i; k <= j; k++) {
    if (TOK[k,"kind"] == "OP" && TOK[k,"text"] == "?") {
      v2_emit_rpn("RAW", v2_read_span_text(i, j), TOK[i,"line"], "")
      return
    }
  }
  for (k = i; k <= j; k++) {
    t    = TOK[k,"kind"]
    line = TOK[k,"line"]

    # 隣接オペランドの暗黙 CONCAT（awk の juxtaposition 連結。CK）:
    # 直前トークンが値で終わっており（IDENT/NUM/TYPE/STR/REGEX/")"/"]"）、
    # 現在のトークンが新しい値の開始（IDENT/NUM/TYPE/REGEX/STR/補間開始/"("/
    # 空リテラル [] {}）なら、両者の間に演算子トークンが無い awk の暗黙連結と
    # みなし、CONCAT 演算子を挿入する（二項演算子と同じ pop_ge → push 手順）。
    # 添字アクセス rows[id] の "[" は別枝（260 行目以降）で処理するためここでは
    # 対象外。
    prevkind = (k > i) ? TOK[k-1,"kind"] : ""
    if ((prevkind == "IDENT" || prevkind == "NUM" || prevkind == "TYPE" || \
         prevkind == "STR" || prevkind == "REGEX" || prevkind == "RP" || prevkind == "RBRACK") && \
        (t == "IDENT" || t == "NUM" || t == "TYPE" || t == "REGEX" || \
         t == "STR" || t == "INTERP_OPEN" || t == "LP" || \
         (t == "LBRACK" && TOK[k+1,"kind"] == "RBRACK") || \
         (t == "LBRACE" && TOK[k+1,"kind"] == "RBRACE"))) {
      v2_pop_ge("CONCAT", line)
      v2_os_push("CONCAT")
    }

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
            # 二重ネスト補間 `#{f("#{g}")}`（補間の中の補間）は、check.awk/
            # emit.awk 側のテキストスキャン（v2_find_interp_close 等）が
            # "#{"/"}" の深さを追跡しない前提で書かれているため、ここで
            # 平坦化だけ直しても後続工程が壊れる（rpn.awk 単独修正では
            # 閉じない規模の変更になる）。専用診断を出して安全に停止する
            # （pre-Task12 botfix item4。coderabbit 指摘: 汎用 "unmatched
            # ')'" は偶然の一致でこのケースを保証できないため、専用文言に
            # する）。
            if (TOK[k,"kind"] == "INTERP_OPEN")
              v2_diag(line, TOK[k,"col"], "nested string interpolation is not supported")
            # 補間内のネストした文字列リテラル（review ES で lex.awk が STR
            # トークンとして認識するようになった）は、引用符を落とさず生の
            # " で再ラップして渡す（落とすと内部の } が補間終端と誤認される）。
            # check.awk 側の v2_find_interp_close は生の " をトグル、\X を
            # 無条件 2 文字エスケープとして扱う汎用規約（v2_find_toplevel_pipe /
            # v2_split_toplevel_commas と同じ）なので、STR トークン自身の
            # 内容に \" が含まれていても衝突しない。
            if (TOK[k,"kind"] == "STR") text = text "\"" TOK[k,"text"] "\""
            else                        text = text TOK[k,"text"]
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
      # 多次元添字（`rows[i, "id"]` のような awk 組込みの多次元連想配列
      # アクセス）は v2 の構造化 INDEX 二項演算子で表現できない
      # （v2_index_assign_eq の既存判断 review EB と同じ）。base が
      # ドット連鎖の一部でない単純 IDENT のときに限り、直前に emit 済みの
      # base OPERAND を書き換えて "base[i, \"id\"]" 全体を 1 個の RAW
      # オペランドへ差し替える（pre-Task12 botfix 1。v1 実測: この形の
      # 行は生ブロック内の生テキストとして無変更のまま出力されるため、
      # v2 でも検査を経ない生テキスト passthrough が v1 と同じ挙動になる）。
      if (prevkind == "IDENT" && TOK[k-2,"kind"] != "DOT") {
        multidim_close = v2_find_multidim_close(k, line)
        if (multidim_close > 0) {
          RPN[RPN["n"],"kind"] = "RAW"
          RPN[RPN["n"],"val"]  = TOK[k-1,"text"] "[" v2_read_subscript_text(k, multidim_close) "]"
          k = multidim_close
          continue
        }
      }
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

    # 深さ 0 の ';' は同一行内の文区切り（CR）。一行に複数文が並ぶ
    # `let x: Int = 1; return x` 形で、';' 以降を次の文として独立に
    # ディスパッチできるよう、式終端をここで確定する。
    if (depth == 0 && t == "OP" && txt == ";") return k - 1

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

# 生 awk ブレースブロック（`if (x) { ... }` / `for (...) { ... }`）の閉じ
# `}` 単独行を RAWLINE として emit し、未閉鎖ブレース深さを 1 減らす
# （review EJ の「単独 RBRACE を関数終端と誤認識しない」判定はそのままに、
# 消費するだけで捨てていた閉じ括弧を AST に載せる。pre-Task12 botfix 3。
# 開き `{` を含む行が RAWLINE として v2_rpn_stmt 経由で出力される一方、
# 閉じ `}` だけの行はここでしか出力されないため、この行を丸ごと落とすと
# emit 後の生成コードのブレースが不整合になっていた）。
function v2_rpn_emit_rawbrace_close(line) {
  v2_emit_rpn("MARKER",  "RAWLINE", line, "")
  v2_emit_rpn("OPERAND", "}",       line, "")
  V2_RPN_RAWBRACE_DEPTH--
}

# KW に応じてサブパーサを選択するディスパッチャ
function v2_rpn_dispatch(i,    kw) {
  # 深さ 0 のセミコロン文区切り（CR）: v2_find_expr_end が式終端として
  # ';' の手前で止めるため、前の文の直後に ';' 自体が残っている。次の文の
  # 開始トークンとして誤ってディスパッチしないよう読み飛ばす
  # （`let x: Int = 1; return x` の一行複数文に対応）。
  while (i <= TOK["n"] && TOK[i,"kind"] == "OP" && TOK[i,"text"] == ";") i++
  if (i > TOK["n"]) return i
  # when アーム本体（v2_rpn_when）やトップレベル走査（v2_rpn）は
  # v2_rpn_func 本体ループのような RBRACE 専用の事前チェックを持たず、
  # このディスパッチャを直接呼ぶ。生ブロックの閉じ `}` がここに来た
  # ときも同じ RAWLINE 化を行う（pre-Task12 botfix 3。v2_rpn_func 側は
  # 独自に FUNC_CLOSE 判定を兼ねるため、この分岐より前で RBRACE を
  # 消費しておりここには到達しない）。
  if (TOK[i,"kind"] == "RBRACE" && V2_RPN_RAWBRACE_DEPTH > 0) {
    v2_rpn_emit_rawbrace_close(TOK[i,"line"])
    return i + 1
  }
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
function v2_rpn_func(i,    fname, line, j, typestart, pname, paramtype) {
  line  = TOK[i,"line"]
  fname = TOK[i+1,"text"]

  v2_emit_rpn("MARKER", "FUNC_OPEN", line, "")
  v2_emit_rpn("OPERAND", fname, line, "")

  # 関数スコープ開始: 添字代入の構造化判定に使う DSL 変数の宣言型を初期化する
  # （CB）。前の関数の残留を持ち込まないよう毎回クリアする。
  delete V2_RPN_DSLVAR
  # 生 awk ブレースブロック（`if (x) { ... }` 等）の未閉鎖 `{` の深さ
  # （review EJ）。0 にリセットしてから本体走査を始める。
  V2_RPN_RAWBRACE_DEPTH = 0

  j = i + 2  # LP の位置

  # パラメータリスト ( IDENT [: TYPE] [, ...] )
  if (j <= TOK["n"] && TOK[j,"kind"] == "LP") {
    j++  # skip LP
    while (j <= TOK["n"] && TOK[j,"kind"] != "RP") {
      # 名前位置（LP 直後・カンマ直後）の TYPE トークンもパラメータ名として
      # 受理する（DT）。lex は大文字始まり識別子を TYPE にするため、
      # `function handler(Raw: Untrusted<Str>)` のような大文字パラメータ名
      # が IDENT のみを見るこのループでは無視され、パラメータとして
      # emit されずに arity スロットと注釈の両方を失っていた。
      if (TOK[j,"kind"] == "IDENT" || TOK[j,"kind"] == "TYPE") {
        pname = TOK[j,"text"]
        v2_emit_rpn("OPERAND", pname, TOK[j,"line"], "")
        j++
        # 型注釈 [: TYPE] → `:TYPE...` として出力（Union/Generic の
        # 複数トークン型に対応。let の型スキャンと同じ v2_skip_type を使う）
        if (TOK[j,"kind"] == "COLON" &&
            (TOK[j+1,"kind"] == "TYPE" || TOK[j+1,"kind"] == "IDENT")) {
          j++  # skip :
          typestart = j
          j = v2_skip_type(j)
          paramtype = v2_read_type_text(typestart, j)
          v2_emit_rpn("OPERAND", ":" paramtype, TOK[typestart,"line"], "")
          # let のコレクション型注釈（CB）と同じ理由で、関数引数の
          # List<T>/Dict<K,V> 注釈（エイリアス越しを含む。CY）も
          # V2_RPN_DSLVAR に記録し、添字代入の構造化対象にする。
          if (v2_rpn_expand_alias(paramtype) ~ /^List</ || v2_rpn_expand_alias(paramtype) ~ /^Dict</) \
            V2_RPN_DSLVAR[pname] = paramtype
        }
      } else {
        j++
      }
    }
    if (j <= TOK["n"]) j++  # skip RP
  }

  # -> RETTYPE（Effect<Option<Str>> / Int | Str のような複数トークン型に対応）。
  # 戻り値型 OPERAND には "->" を前置して、パラメータ名 OPERAND（大文字
  # 始まりの識別子が TYPE トークンになる関係で見た目が同じになりうる）と
  # 位置ではなくテキストで区別できるようにする（review C2。parse.awk が
  # 「大文字始まりなら戻り値型」という命名ヒューリスティックに頼っていたため、
  # 型注釈もアローも無い大文字始まりパラメータ（`function handler(Raw) {...}`）
  # が戻り値型と誤認識され PARAM ノードごと消失していた）。
  if (j <= TOK["n"] && TOK[j,"kind"] == "ARROW") {
    j++
    if (j <= TOK["n"] && (TOK[j,"kind"] == "TYPE" || TOK[j,"kind"] == "IDENT")) {
      typestart = j
      j = v2_skip_type(j)
      v2_emit_rpn("OPERAND", "->" v2_read_type_text(typestart, j), TOK[typestart,"line"], "")
    }
  }

  # { BODY }
  if (j <= TOK["n"] && TOK[j,"kind"] == "LBRACE") j++

  # 本体トークン列を文ディスパッチで処理
  while (j <= TOK["n"]) {
    if (TOK[j,"kind"] == "RBRACE") {
      # 生 awk ブレースブロックの開き `{` は RAWLINE の一部としてスキップ
      # されるが、閉じ `}` は単独行トークンとしてここに現れるため、素朴に
      # 「RBRACE を見たら関数終端」と判定すると生ブロックの閉じ括弧を関数
      # 終端と誤認識し、以降の文がトップレベル化していた（review EJ）。
      # RAWLINE 消化時に数えた未閉鎖 `{` の深さが残っている間は、この
      # RBRACE を関数終端にはしない。単に読み飛ばすだけだと閉じ括弧
      # 自体が AST から消えて emit 後のブレースが不整合になるため、
      # RAWLINE として emit してから深さを 1 減らす（pre-Task12 botfix 3）。
      if (V2_RPN_RAWBRACE_DEPTH > 0) {
        v2_rpn_emit_rawbrace_close(TOK[j,"line"])
        j++
        continue
      }
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
  # 後続の let 型注釈・関数引数注釈が同名エイリアスを参照したとき
  # List</Dict< 判定に展開して使えるよう記録する（CU/CY）。
  V2_RPN_ALIAS[name] = typetext
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
    # List</Dict< と宣言された変数は、後続の添字代入文（xs[k] = v）を RAWLINE
    # に吸収させず ASSIGN 系ノードとして構造化するための対象に記録する（CB）。
    # `type Ints = List<Int>` のようなエイリアス越しの宣言は typetext が
    # literal "List<"/"Dict<" prefix にならず記録漏れになっていたため、
    # 判定前にエイリアス展開する（CU）。
    if (v2_rpn_expand_alias(typetext) ~ /^List</ || v2_rpn_expand_alias(typetext) ~ /^Dict</) \
      V2_RPN_DSLVAR[name] = typetext
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
    # 腕タグは ok/ng/some/none/default のみを許容する（BP）。それ以外の
    # identifier + colon（例: `foo x:`）は v1 実測（dsl/desugar_match.awk）で
    # 「腕ヘッダとして認識されず本体行扱いになる」ため
    # "when...of body line before any arm" になる。v2 は既にこれを腕として
    # 構造化してしまう（rpn/parse の都合）ため、診断だけ同文面で出す。
    if (!((TOK[i,"kind"] == "KW" && TOK[i,"text"] == "default") || \
          (TOK[i,"kind"] == "IDENT" && (TOK[i,"text"] == "ok" || TOK[i,"text"] == "ng" || \
                                         TOK[i,"text"] == "some" || TOK[i,"text"] == "none")))) {
      v2_diag(arm_line, 1, "when...of body line before any arm")
    }
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

# 行内の "[" のうち、v2_shunt_expr の INDEX 二項演算子（BE/U）が扱えない
# 形（直前が値でない = 配列リテラル等、または対応する "]" までにネストした
# "[" を含む多次元添字、または行内で閉じない）が 1 つでもあれば真を返す
# （DR。単純な一階層添字 `name[idx]` は shunting yard 側で既に構造化
# できるため、これだけを理由に RAWLINE へ落とす必要はない）。
function v2_line_has_unsupported_index(i, line,    j, lbrack_pos, prevkind, depth, close_pos) {
  for (j = i; j <= TOK["n"] && TOK[j,"line"] == line; j++) {
    if (TOK[j,"kind"] != "LBRACK") continue
    lbrack_pos = j
    prevkind = (j > i) ? TOK[j-1,"kind"] : ""
    if (!(prevkind == "IDENT" || prevkind == "NUM" || prevkind == "TYPE" || \
          prevkind == "STR"   || prevkind == "RP"  || prevkind == "RBRACK")) return 1
    depth = 1
    close_pos = 0
    j++
    while (j <= TOK["n"] && TOK[j,"line"] == line && depth > 0) {
      if (TOK[j,"kind"] == "LBRACK") return 1   # ネストした添字は未対応
      if (TOK[j,"kind"] == "RBRACK") { depth--; if (depth == 0) close_pos = j }
      j++
    }
    if (depth != 0) return 1   # 行内で閉じない
    # 文頭の `name[...] =` 形は代入文（v2_index_assign_eq/CB）専用の判定
    # 対象で、ここに来た時点で false（base 変数が V2_RPN_DSLVAR 未登録）
    # ということは構造化不可が確定済みという意味。二重に構造化しようと
    # せず RAWLINE のまま（wave 6 CB の DSLVAR 限定ルールと衝突しない）。
    if (lbrack_pos == i + 1 && close_pos > 0 && \
        TOK[close_pos + 1,"kind"] == "OP" && TOK[close_pos + 1,"text"] == "=") return 1
    j--   # for の自動 j++ 分を差し引く
  }
  return 0
}

# 位置 i の行が式文として解釈不能かどうかを判定
# (v2_shunt_expr が扱えない LBRACE/COLON/ARROW を含む、または
# v2_shunt_expr の INDEX 演算子が扱えない形の "[" を含む)
#
# INTERP_OPEN/INTERP_CLOSE は判定条件から除外している（review EC）。
# let/return 経路は同じ v2_shunt_expr で STR/INTERP_* を既に構造化できて
# いるのに、式文だけこのゲートで一律 RAWLINE に落ちていた。旧実装だと
# `ctx.res.html(safe.html.raw("#{raw}"))` のような裸の式文が生テキストの
# まま保存され、brand/XSS 検査（v2_check_fragment_interp 等）を素通りして
# いた。
function v2_is_rawline(i,    line, j, k) {
  line = TOK[i,"line"]
  for (j = i; j <= TOK["n"] && TOK[j,"line"] == line; j++) {
    k = TOK[j,"kind"]
    if (k == "LBRACE" || k == "COLON" || k == "ARROW") return 1
  }
  if (v2_line_has_unsupported_index(i, line)) return 1
  return 0
}

# 行頭が素の awk 文形式（print / printf / if / while / for / do / delete 等、
# DSL 構文として構造化しない awk 制御構文・組込み文）かどうかを判定する（CS）。
# これらは v2_shunt_expr の式文法では扱えず、誤って CALL/CONCAT に還元される
# ため RAWLINE へ fallback させる。
function v2_is_awk_stmt_head(i) {
  return TOK[i,"kind"] == "IDENT" && \
    (TOK[i,"text"] == "print" || TOK[i,"text"] == "printf" || \
     TOK[i,"text"] == "if"    || TOK[i,"text"] == "while"  || \
     TOK[i,"text"] == "for"   || TOK[i,"text"] == "do"     || \
     TOK[i,"text"] == "delete")
}

# 素の awk 複合代入演算子（+= -= *= /= %= ^=）を検出する（CS）。lex.awk の
# 2 文字演算子表にこれらが含まれず単文字 OP 2 つに分割されるため、
# shunting yard がそれぞれを独立した演算子として扱い stack underflow に
# なる（`x += 1` → OP "+" OP "="）。深さに関わらず、同一行内にこの隣接
# ペアがあれば RAWLINE へ fallback させる対象と判定する。
function v2_is_compound_assign(i,    line, j, k, op1) {
  line = TOK[i,"line"]
  for (j = i; j <= TOK["n"] && TOK[j,"line"] == line; j++) {
    if (TOK[j,"kind"] != "OP") continue
    op1 = TOK[j,"text"]
    if (op1 != "+" && op1 != "-" && op1 != "*" && op1 != "/" && op1 != "%" && op1 != "^") continue
    k = j + 1
    if (k <= TOK["n"] && TOK[k,"line"] == line && TOK[k,"kind"] == "OP" && TOK[k,"text"] == "=" && \
        TOK[k,"col"] == TOK[j,"col"] + length(op1)) return 1
  }
  return 0
}

# その他の文（裸の式文・代入・未知トークン）
# 添字代入文 `name[idx] = rhs` を検出する（CB）。name が V2_RPN_DSLVAR に
# 記録された List</Dict< 変数であり、深さ 0 の RBRACK の直後に単純な `=`
# （`==`/`+=` 等ではない）が続く場合のみ ASSIGN 系ノードとして扱う。
# 一致すれば `=` の RPN インデックスを返し、しなければ 0 を返す。
# 素の awk 配列（DSL 変数でないもの）への添字代入は従来どおり RAWLINE に
# 委ねる（既存 fixture の a[i] = 1 は V2_RPN_DSLVAR に無いため対象外のまま）。
function v2_index_assign_eq(i,    line, j, depth, has_comma) {
  line = TOK[i,"line"]
  if (TOK[i,"kind"] != "IDENT" || !(TOK[i,"text"] in V2_RPN_DSLVAR)) return 0
  if (TOK[i+1,"kind"] != "LBRACK") return 0
  depth = 0
  has_comma = 0
  for (j = i + 1; j <= TOK["n"] && TOK[j,"line"] == line; j++) {
    if (TOK[j,"kind"] == "LBRACK") depth++
    else if (TOK[j,"kind"] == "RBRACK") {
      depth--
      if (depth == 0) break
    } else if (TOK[j,"kind"] == "COMMA" && depth == 1) {
      # 添字ブラケット直下（深さ 1）のトップレベルカンマは多次元 subscript
      # （`xs["bad", 0]`）とみなす。v2 は多次元 subscript 非対応なので診断で
      # 拒否する（review EB。旧実装は index 式全体を v2_shunt_expr に渡す
      # だけで、スタックトップ以外の成分が黙って落ちて代入が通っていた）。
      has_comma = 1
    }
  }
  if (depth != 0) return 0            # 未閉の [ 、または複数階層添字は対象外
  j++
  if (j <= TOK["n"] && TOK[j,"line"] == line && \
      TOK[j,"kind"] == "OP" && TOK[j,"text"] == "=") {
    if (has_comma) {
      v2_diag(line, 1, "multi-dimensional subscript is not supported")
      return 0
    }
    return j
  }
  return 0
}

# 添字代入文を INDEX_ASSIGN として構造化発行する（CB）。
# RPN: MARKER INDEX_ASSIGN / OPERAND name / <index 式> / MARKER INDEX_SEP /
#      <rhs 式> / MARKER STMT_END
function v2_rpn_index_assign(i, eq_pos,    line, name, lbrack, rbrack, j) {
  line  = TOK[i,"line"]
  name  = TOK[i,"text"]
  lbrack = i + 1
  rbrack = eq_pos - 1

  v2_emit_rpn("MARKER", "INDEX_ASSIGN", line, "")
  v2_emit_rpn("OPERAND", name, line, "")
  if (rbrack - 1 >= lbrack + 1) v2_shunt_expr(lbrack + 1, rbrack - 1)
  v2_emit_rpn("MARKER", "INDEX_SEP", line, "")

  j = v2_find_expr_end(eq_pos + 1)
  if (j >= eq_pos + 1) v2_shunt_expr(eq_pos + 1, j)
  else                 j = eq_pos     # RHS なし（構文エラーに近いが最低 1 トークン進める）

  v2_emit_rpn("MARKER", "STMT_END", TOK[j,"line"], "")
  return j + 1
}

function v2_rpn_stmt(i,    j, line, eq_pos) {
  line = TOK[i,"line"]

  eq_pos = v2_index_assign_eq(i)
  if (eq_pos > 0) return v2_rpn_index_assign(i, eq_pos)

  if (v2_is_rawline(i) || v2_is_awk_stmt_head(i) || v2_is_compound_assign(i)) {
    # 解釈不能トークン列を RAWLINE マーカーで素通し
    v2_emit_rpn("MARKER",  "RAWLINE",             line, "")
    v2_emit_rpn("OPERAND", V2_LINE_TEXT[line], line, "")
    j = i
    # この行に含まれる `{`/`}` の収支を数え、関数 body 走査側の未閉鎖
    # ブレース深さに反映する（review EJ）。`if (x) { ... }` のように開き
    # `{` のみで終わる行は深さ +1 になり、この行に閉じ `}` が見つかるまで
    # v2_rpn_func 側の単独 RBRACE を関数終端と誤認識しないようにする。
    while (j <= TOK["n"] && TOK[j,"line"] == line) {
      if      (TOK[j,"kind"] == "LBRACE") V2_RPN_RAWBRACE_DEPTH++
      else if (TOK[j,"kind"] == "RBRACE") V2_RPN_RAWBRACE_DEPTH--
      j++
    }
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
  # type NAME = TYPE_EXPR のエイリアス表（CU/CY）。v2_rpn_typedecl が
  # ファイル先頭から順に埋める。プログラム全体で 1 つの表（関数スコープでは
  # クリアしない）。
  delete V2_RPN_ALIAS

  i = 1
  while (i <= TOK["n"]) {
    i = v2_rpn_dispatch(i)
  }
}

# V2_RPN_DSLVAR 記録判定用に型テキスト t をエイリアス越しに展開する（CU/CY）。
# check.awk の v2_expand_alias（パス 1 完了後の ALIAS[] を使う）とは別に、
# rpn は自身のトップダウン走査中に集めた V2_RPN_ALIAS（type 宣言が使用箇所
# より前にある場合のみ解決可能）を参照する。展開先も別名の場合に備えて数段
# 展開するが、循環定義は guard で打ち切る（BR の循環検出は check 側の役割
# のためここでは検出しない、単に無限ループを防ぐだけ）。
function v2_rpn_expand_alias(t,    guard) {
  guard = 0
  while ((t in V2_RPN_ALIAS) && guard < 20) {
    t = V2_RPN_ALIAS[t]
    guard++
  }
  return t
}
