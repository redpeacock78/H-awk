# SPDX-License-Identifier: MIT
# dsl/v2/lex.awk -- 行分類 + トークナイザ
#
# v2_lex(src)    : TOK[], PASS[], V2_NLINES を埋める
# v2_is_dsl(line): DSL 構文を含む行なら 1 を返す

# out の末尾（末尾空白を無視）を見て、直後の '/' が正規表現リテラルの開始と
# みなせるかを判定する（AS の「直前トークンが値なら除算」規則を、文字ベースの
# 簡易版として近似したもの。行頭 / `~` `!~` `(` `,` `=` の直後を正規表現開始と
# みなす。BG）。
function v2_regex_start_here(out,    trimmed, last) {
  trimmed = out
  sub(/[[:space:]]+$/, "", trimmed)
  if (length(trimmed) == 0) return 1
  last = substr(trimmed, length(trimmed), 1)
  return (last == "~" || last == "(" || last == "," || last == "=")
}

# line の位置 i（'/' の位置）から、対応する閉じ '/' の位置までを読み飛ばし、
# その位置を返す（見つからなければ行末）。エスケープ '\/' に対応する。
function v2_skip_regex_text(line, i,    j, ch) {
  j = i + 1
  while (j <= length(line)) {
    ch = substr(line, j, 1)
    if (ch == "\\") { j += 2; continue }
    if (ch == "/") return j
    j++
  }
  return length(line)
}

# 文字列リテラル・正規表現リテラル・行コメントを取り除いた行を返す（DSL
# キーワード判定の誤検出防止）。文字列内の補間開始 #{ はキーワード判定上も
# 意味を持つため残す。正規表現リテラルの中身は検出目的では丸ごと除去してよい
# （BG: `$0 ~ /let/` の `let` が DSL キーワードに誤検出されるのを防ぐ）。
function v2_strip_str_comment(line,    i, ch, out, instr) {
  out   = ""
  instr = 0
  for (i = 1; i <= length(line); i++) {
    ch = substr(line, i, 1)
    if (instr) {
      if (ch == "\\") { i++; continue }
      if (ch == "\"") { instr = 0; continue }
      if (ch == "#" && substr(line, i + 1, 1) == "{") { out = out "#{"; i++; continue }
      continue
    }
    if (ch == "\"") { instr = 1; continue }
    if (ch == "#") {
      if (substr(line, i + 1, 1) == "{") { out = out "#{"; i++; continue }
      break
    }
    if (ch == "/" && v2_regex_start_here(out)) { i = v2_skip_regex_text(line, i); continue }
    out = out ch
  }
  return out
}

# DSL 構文を含む行か判定する述語
function v2_is_dsl(line,    s) {
  s = v2_strip_str_comment(line)
  # let / when / of / end をワード境界で検出
  if (s ~ /(^|[^[:alnum:]_])(let|when|of|end)([^[:alnum:]_]|$)/) return 1
  # type NAME = ...（型エイリアス宣言、docs/dsl.md:504-505。AP）
  if (s ~ /(^|[^[:alnum:]_])type[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) return 1
  # ??  |>  #{  ?=  演算子
  if (s ~ /\?\?|\|>|#\{|\?=/) return 1
  # function NAME(...) ->  シグネチャ
  if (s ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*->/) return 1
  # 名前空間付きアクセス (hawk. ctx. 等)
  if (s ~ /(^|[^[:alnum:]_])(hawk|ctx|env|cache|safe|msg|proc|json|option)\.[[:alnum:]_]/) return 1
  # 型注釈  : Int / : Str / : Response 等（docs/dsl.md:96 のサポート型一覧。BA）
  if (s ~ /:[[:space:]]*(Int|Float|Str|Bool|NumericStr|Array|Map|Response|Untrusted<|HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr|Void|Any|List<|Dict<|Record|Result<|Option<)/) return 1
  return 0
}

# 文字列リテラル・コメントを丸ごと取り除いた行を返す（ブレース深さ計測専用）。
# v2_strip_str_comment と異なり、文字列内の補間 #{ ... } も丸ごと取り除く。
# 補間の閉じ } まで対称に残さないと、文字列内の "#{" だけが LBRACE として
# カウントされて深さが過大になり、本体終端 } の探索がファイル末尾まで暴走する
# （実際に無注釈関数の本体に補間文字列があるケースで発生した回帰）。
function v2_strip_for_brace_count(line,    i, ch, out, instr) {
  out   = ""
  instr = 0
  for (i = 1; i <= length(line); i++) {
    ch = substr(line, i, 1)
    if (instr) {
      if (ch == "\\") { i++; continue }
      if (ch == "\"") { instr = 0; continue }
      continue
    }
    if (ch == "\"") { instr = 1; continue }
    if (ch == "#") break
    out = out ch
  }
  return out
}

# 注釈なし（-> RETTYPE を持たない）DSL 関数ヘッダを検出する。
# 本体（{ に対応する } まで）に DSL 構文が 1 行でもあれば、
# ヘッダ行から閉じ } の行までを V2_FORCE_DSL[] に印付けする。
function v2_mark_unannotated_func(nlines,    i, j, k, depth, stripped, tmp, n_open, n_close, has_dsl, header) {
  for (i = 1; i <= nlines; i++) {
    # ヘッダ判定はコメントを含む生行ではなく、コメント除去後の行に対して行う
    # （`function f() { # comment` のような行末コメントがあると「行末 {」判定が
    #   偽になり、ヘッダが未検出のまま本体が DSL 扱いされない不具合を防ぐ）。
    header = v2_strip_for_brace_count(V2_RAWLINE[i])
    if (header !~ /(^|[^[:alnum:]_])function([^[:alnum:]_]|$)/) continue
    if (header ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*->/) continue
    if (header !~ /\{[[:space:]]*$/) continue

    depth   = 1
    has_dsl = 0
    for (j = i + 1; j <= nlines && depth > 0; j++) {
      stripped = v2_strip_for_brace_count(V2_RAWLINE[j])
      tmp = stripped; n_open  = gsub(/{/, "", tmp)
      tmp = stripped; n_close = gsub(/}/, "", tmp)
      depth += n_open - n_close
      if (v2_is_dsl(V2_RAWLINE[j])) has_dsl = 1
    }
    # depth が 0 に戻らずファイル末尾まで走った（本体が閉じていない）場合は
    # 誤って残り全行を DSL 扱いにしないよう、印付けをスキップする。
    if (has_dsl && depth <= 0) {
      for (k = i; k < j; k++) V2_FORCE_DSL[k] = 1
    }
  }
}

# src ファイルを読み込み TOK[], PASS[], V2_NLINES を設定する
#
# in_when  : when...end ブロックの深さ（end で閉じる）
# in_block : DSL 関数本体 { } の深さ（} で閉じる）
# pending_brace : 注釈付き関数ヘッダを検出したが、ヘッダ行に { が無い
#   （次行以降にブレースが来る）状態。このフラグが立っている間は、
#   ヘッダ以降の行が個別に v2_is_dsl を満たさなくても DSL 扱いにして
#   トークン化する（BQ）。{ を含む行を処理したら解除する。
function v2_lex(src,    line, lineno, in_when, in_block, nlines, tok_start, k, \
                 pending_brace, header_stripped, force_line) {
  V2_NLINES = 0
  TOK["n"]  = 0
  in_when   = 0
  in_block  = 0
  pending_brace = 0

  nlines = 0
  while ((getline line < src) > 0) { nlines++; V2_RAWLINE[nlines] = line }
  close(src)

  v2_mark_unannotated_func(nlines)

  for (lineno = 1; lineno <= nlines; lineno++) {
    line = V2_RAWLINE[lineno]
    V2_NLINES = lineno
    force_line = (pending_brace && in_when == 0 && in_block == 0)
    if (in_when > 0 || in_block > 0 || v2_is_dsl(line) || (lineno in V2_FORCE_DSL) || force_line) {
      tok_start = TOK["n"]
      v2_tok_line(line, lineno)
      V2_LINE_TEXT[lineno] = line   # 生行テキスト（RAWLINE 用）
      # when...end / { } 深さは、この行が生成したトークンから数える
      # （文字列・コメント内の同名文字列に反応しないようにするため。トークン化後の
      #   LBRACE/RBRACE で数えることで rpn.awk 側の深さカウントとも方針を揃える）
      for (k = tok_start + 1; k <= TOK["n"]; k++) {
        if (TOK[k,"kind"] == "KW" && TOK[k,"text"] == "when") in_when++
        if (TOK[k,"kind"] == "KW" && TOK[k,"text"] == "end")  in_when--
        if (TOK[k,"kind"] == "LBRACE")                      { in_block++; pending_brace = 0 }
        if (TOK[k,"kind"] == "RBRACE")                        in_block--
      }
      if (in_when  < 0) in_when  = 0
      if (in_block < 0) in_block = 0
      # 注釈付き関数ヘッダ（function NAME(...) -> RETTYPE）で、この行が { を
      # 含まずに終わっていれば、次行以降のブレース待ち状態にする。
      if (in_block == 0 && !pending_brace) {
        header_stripped = v2_strip_for_brace_count(line)
        if (header_stripped ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*->/ && \
            index(header_stripped, "{") == 0) {
          pending_brace = 1
        }
      }
    } else {
      PASS[lineno] = line
    }
  }
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
  if (tok ~ /^(function|let|when|of|end|return|rec|default|type)$/) return "KW"
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
function v2_tok_str(rest, lineno, startcol,    i, ch, ch2, acc, acc_col, consumed, closed_interp) {
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
        closed_interp = 0
        while (i <= length(rest)) {
          ch = substr(rest, i, 1)
          # 補間終端
          if (ch == "}") {
            v2_push("INTERP_CLOSE", "}", lineno, startcol + i - 1)
            i++
            closed_interp = 1
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
        if (!closed_interp) {
          v2_diag(lineno, startcol, "unterminated interpolation")
          return length(rest)
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
  v2_diag(lineno, startcol, "unterminated string literal")
  return length(rest)
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

    # 正規表現リテラル（AS）: docs/dsl.md:291 は単一行 regex リテラルを明記。
    # 直前トークンが値（IDENT/NUM/TYPE/STR/")"/"]"）でなければ除算ではなく
    # regex リテラルの開始とみなし、対応する閉じ '/' まで単一トークン化する
    # （標準的な曖昧性解消規則: 直前が値なら除算、それ以外なら regex）。
    if (rest ~ /^\// && !v2_prevtok_is_value()) {
      pos += v2_tok_regex(rest, lineno, pos)
      continue
    }

    # 数値 / 識別子 / 1 文字記号
    pos += v2_tok_word(rest, lineno, pos)
  }
}

# 直前に push されたトークンが「値」（除算の左辺になり得る）かどうかを返す
function v2_prevtok_is_value(    k) {
  k = TOK["n"]
  if (k < 1) return 0
  return (TOK[k,"kind"] == "IDENT" || TOK[k,"kind"] == "NUM" || TOK[k,"kind"] == "TYPE" || \
          TOK[k,"kind"] == "STR"   || TOK[k,"kind"] == "RP"  || TOK[k,"kind"] == "RBRACK")
}

# 正規表現リテラル rest[1]=='/' をトークン化し、消費文字数を返す。
# エスケープ '\/' に対応し、閉じ '/' まで（開閉スラッシュを含めて）1 トークンにする。
function v2_tok_regex(rest, lineno, startcol,    i, ch, acc) {
  acc = "/"
  i = 2
  while (i <= length(rest)) {
    ch = substr(rest, i, 1)
    if (ch == "\\") { acc = acc ch substr(rest, i + 1, 1); i += 2; continue }
    if (ch == "/") {
      acc = acc ch
      v2_push("REGEX", acc, lineno, startcol)
      return i
    }
    acc = acc ch
    i++
  }
  v2_diag(lineno, startcol, "unterminated regex literal")
  v2_push("REGEX", acc, lineno, startcol)
  return length(rest)
}
