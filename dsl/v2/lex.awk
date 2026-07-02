# SPDX-License-Identifier: MIT
# dsl/v2/lex.awk -- 行分類 + トークナイザ
#
# v2_lex(src)    : TOK[], PASS[], V2_NLINES を埋める
# v2_is_dsl(line): DSL 構文を含む行なら 1 を返す

# DSL 構文を含む行か判定する述語
function v2_is_dsl(line) {
  # let / when / of / end をワード境界で検出
  if (line ~ /(^|[^[:alnum:]_])(let|when|of|end)([^[:alnum:]_]|$)/) return 1
  # ??  |>  #{  ?=  演算子
  if (line ~ /\?\?|\|>|#\{|\?=/) return 1
  # function NAME(...) ->  シグネチャ
  if (line ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*->/) return 1
  # 名前空間付きアクセス (hawk. ctx. 等)
  if (line ~ /(^|[^[:alnum:]_])(hawk|ctx|env|cache|safe|msg|proc)\.[[:alnum:]_]/) return 1
  # 型注釈  : Int / : Str / : Response 等
  if (line ~ /:[[:space:]]*(Int|Str|Bool|Num|Void|Response|List<|Dict<|Record|Result<|Option<)/) return 1
  return 0
}

# src ファイルを読み込み TOK[], PASS[], V2_NLINES を設定する
#
# in_when  : when...end ブロックの深さ（end で閉じる）
# in_block : DSL 関数本体 { } の深さ（} で閉じる）
function v2_lex(src,    line, lineno, in_when, in_block, tmp, n_open, n_close) {
  V2_NLINES = 0
  TOK["n"]  = 0
  in_when   = 0
  in_block  = 0
  while ((getline line < src) > 0) {
    lineno = ++V2_NLINES
    if (in_when > 0 || in_block > 0 || v2_is_dsl(line)) {
      v2_tok_line(line, lineno)
      V2_LINE_TEXT[lineno] = line   # 生行テキスト（RAWLINE 用）
      # when...end ブロック追跡
      if (line ~ /(^|[^[:alnum:]_])when([^[:alnum:]_]|$)/) in_when++
      if (line ~ /(^|[^[:alnum:]_])end([^[:alnum:]_]|$)/)  in_when--
      if (in_when < 0) in_when = 0
      # DSL ブロック { } 深さ追跡（補間内 #{ } は対称なので相殺される）
      tmp = line; n_open  = gsub(/{/, "", tmp)
      tmp = line; n_close = gsub(/}/, "", tmp)
      in_block += n_open - n_close
      if (in_block < 0) in_block = 0
    } else {
      PASS[lineno] = line
    }
  }
  close(src)
}

# ─── 内部ヘルパー ─────────────────────────────────────────────

# トークンを TOK[] に追加する
function v2_push(kind, text, line, col) {
  TOK["n"]++
  TOK[TOK["n"], "kind"] = kind
  TOK[TOK["n"], "text"] = text
  TOK[TOK["n"], "line"] = line
  TOK[TOK["n"], "col"]  = col
}

# 識別子文字列から トークン種別を返す（KW / TYPE / IDENT）
function v2_ident_kind(tok) {
  if (tok ~ /^(function|let|when|of|end|return|rec|default)$/) return "KW"
  if (tok ~ /^[A-Z]/) return "TYPE"
  return "IDENT"
}

# rest の先頭から単一トークンを切り出し、消費文字数を返す
# rest は line の col 列目から始まる文字列
function v2_tok_word(rest, lineno, col,    c) {
  # 数値リテラル
  if (match(rest, /^[0-9]+(\.[0-9]+)?/)) {
    v2_push("NUM", substr(rest, 1, RLENGTH), lineno, col)
    return RLENGTH
  }
  # 識別子（キーワード・型名・ident）
  if (match(rest, /^[[:alpha:]_][[:alnum:]_]*/)) {
    v2_push(v2_ident_kind(substr(rest, 1, RLENGTH)), substr(rest, 1, RLENGTH), lineno, col)
    return RLENGTH
  }
  # 1 文字区切り記号
  c = substr(rest, 1, 1)
  if (c == "(") { v2_push("LP",     c, lineno, col); return 1 }
  if (c == ")") { v2_push("RP",     c, lineno, col); return 1 }
  if (c == "{") { v2_push("LBRACE", c, lineno, col); return 1 }
  if (c == "}") { v2_push("RBRACE", c, lineno, col); return 1 }
  if (c == "[") { v2_push("LBRACK", c, lineno, col); return 1 }
  if (c == "]") { v2_push("RBRACK", c, lineno, col); return 1 }
  if (c == ":") { v2_push("COLON",  c, lineno, col); return 1 }
  if (c == ",") { v2_push("COMMA",  c, lineno, col); return 1 }
  if (c == ".") { v2_push("DOT",    c, lineno, col); return 1 }
  # その他はすべて OP
  v2_push("OP", c, lineno, col)
  return 1
}

# 文字列リテラル（補間含む）をトークン化し、消費文字数を返す。
# rest[1] は '"' であること。startcol は '"' の列番号（1 始まり）。
function v2_tok_str(rest, lineno, startcol,    i, ch, ch2, acc, acc_col, consumed) {
  i       = 2          # '"' を読み飛ばす
  acc     = ""
  acc_col = startcol   # 現 STR セグメントの開始列（'"' 位置）

  while (i <= length(rest)) {
    ch = substr(rest, i, 1)

    # エスケープ
    if (ch == "\\") {
      acc = acc ch substr(rest, i + 1, 1)
      i += 2
      continue
    }

    # 文字列終端
    if (ch == "\"") {
      v2_push("STR", acc, lineno, acc_col)
      return i   # 消費した文字数（'"' 開始の i=1 含む）
    }

    # 補間開始  #{
    if (ch == "#") {
      ch2 = substr(rest, i + 1, 1)
      if (ch2 == "{") {
        # 蓄積分を STR として出力（空なら省略）
        if (length(acc) > 0) v2_push("STR", acc, lineno, acc_col)
        # INTERP_OPEN
        v2_push("INTERP_OPEN", "#{", lineno, startcol + i - 1)
        i += 2
        # #{ 内の式を }  まで逐次トークン化
        while (i <= length(rest)) {
          ch = substr(rest, i, 1)
          # 補間終端
          if (ch == "}") {
            v2_push("INTERP_CLOSE", "}", lineno, startcol + i - 1)
            i++
            break
          }
          # 空白読み飛ばし
          if (ch ~ /[[:space:]]/) { i++; continue }
          # 2 文字演算子
          ch2 = substr(rest, i, 2)
          if (ch2 ~ /^(\?\?|\|>|\?=|==|!=|<=|>=|&&|\|\||!~)/) {
            v2_push("OP", ch2, lineno, startcol + i - 1); i += 2; continue
          }
          if (ch2 ~ /^->/) {
            v2_push("ARROW", "->", lineno, startcol + i - 1); i += 2; continue
          }
          # 単語・記号
          consumed = v2_tok_word(substr(rest, i), lineno, startcol + i - 1)
          i += consumed
        }
        acc     = ""
        acc_col = startcol + i - 1   # 次 STR セグメントの開始列
        continue
      }
    }

    # 通常文字を蓄積
    acc = acc ch
    i++
  }
  return i - 1
}

# 1 行分のトークンを解析して TOK[] に追加する
function v2_tok_line(line, lineno,    pos, rest) {
  pos = 1
  while (pos <= length(line)) {
    rest = substr(line, pos)

    # 空白読み飛ばし
    if (rest ~ /^[[:space:]]/) { pos++; continue }

    # 文字列リテラル
    if (rest ~ /^"/) { pos += v2_tok_str(rest, lineno, pos); continue }

    # 補間開始（文字列外の #{）
    if (rest ~ /^#\{/) { v2_push("INTERP_OPEN", "#{", lineno, pos); pos += 2; continue }

    # 行コメント
    if (rest ~ /^#/) { break }

    # 2 文字演算子（-> を含む）
    if (rest ~ /^->/)                                       { v2_push("ARROW", "->", lineno, pos); pos += 2; continue }
    if (rest ~ /^(\?\?|\|>|\?=|==|!=|<=|>=|&&|\|\||!~)/)  { v2_push("OP", substr(rest, 1, 2), lineno, pos); pos += 2; continue }

    # 数値 / 識別子 / 1 文字記号
    pos += v2_tok_word(rest, lineno, pos)
  }
}
