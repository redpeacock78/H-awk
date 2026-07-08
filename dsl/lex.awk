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
  # 直前が値を作らないトークン（演算子・キーワード・( , 行頭等）なら
  # regex（DC。旧許可リストは `~ ( , =` のみで `return /let/` や
  # `&& /when/` を除算誤判定して strip し損なっていた）。2 文字演算子
  # （== != <= >= && || !~）は末尾 1 文字が下記のいずれかに含まれるため
  # 単文字判定のままで拾える。
  if (trimmed ~ /(^|[^[:alnum:]_])return$/) return 1
  last = substr(trimmed, length(trimmed), 1)
  return (last == "~" || last == "(" || last == "," || last == "=" || \
          last == "!" || last == "<" || last == ">" || last == "&" || last == "|")
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
    # 文字列外の "#" は常に awk コメントの開始（CJ）。補間マーカー "#{" の保護は
    # 文字列内（instr の分岐）に限定する — 素の awk コメントが `#{note}` や
    # `# {foo} bar` のように "{" を含んでいても DSL 行と誤検出しない。
    if (ch == "#") break
    if (ch == "/" && v2_regex_start_here(out)) { i = v2_skip_regex_text(line, i); continue }
    out = out ch
  }
  return out
}

# DSL 構文を含む行か判定する述語
# type NAME = ... 宣言をファイル全体から事前収集し、型注釈検出（v2_is_dsl の
# `: TYPE` 判定）に使う代替パターンを組み立てる（CE）。組込み型集合に無い
# ユーザー定義エイリアスだけが注釈に使われている関数（`type Status = Int|Str`
# + `function f(x: Status) {...}`）は、この事前収集なしでは検出できず素の awk
# 扱いのまま素通りしていた。宣言位置が使用箇所より後（前方参照）でもファイル
# 全体を先に舐めるため拾える。
# 誤検出リスク: エイリアス名が偶然コメント・文字列中の識別子と一致するケースは
# 元々の固定型リストと同じ理由で許容する（v2_strip_str_comment 済みの行に対して
# のみ判定するため文字列内は対象外）。
function v2_collect_type_aliases(nlines,    i, s, m, names, n) {
  names = ""; n = 0
  for (i = 1; i <= nlines; i++) {
    s = v2_strip_str_comment(V2_RAWLINE[i])
    if (match(s, /(^|[^[:alnum:]_])type[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=/, m)) {
      if (!(m[2] in V2_DSL_ALIAS)) { V2_DSL_ALIAS[m[2]] = 1; names = names (n++ ? "|" : "") m[2] }
    }
  }
  V2_ALIAS_TYPEANN_RE = names
}

# 戻り値型注釈（`-> RETTYPE`）を持つユーザー定義関数名をファイル全体から
# 事前収集する（review EQ）。DSL マーカーを一切持たない関数本体
# （`function handler() { normalize(123) }`）でも、本体が既知の注釈付き
# 関数を呼び出しているだけなら v1 は引数型検査を行う。v2 は関数ヘッダに
# DSL 構文が無いと本体全体を素通し（RAWLINE）扱いにするため、この呼び出し
# だけが v2_check_calls の CALL 検査を経由せず引数型不一致を見逃していた。
function v2_collect_annotated_funcs(nlines,    i, s, m, names, n) {
  names = ""; n = 0
  for (i = 1; i <= nlines; i++) {
    s = v2_strip_str_comment(V2_RAWLINE[i])
    # 戻り値注釈 (-> RETTYPE) を持つ関数
    if (match(s, /function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\([^)]*\)[[:space:]]*->/, m)) {
      if (!(m[1] in V2_DSL_FUNCNAME)) { V2_DSL_FUNCNAME[m[1]] = 1; names = names (n++ ? "|" : "") m[1] }
      continue
    }
    # param-only シグネチャ（`->` 無し、`function f(x: Str) { ... }`）。
    # G4: 戻り値注釈が無いだけで prescan から漏れ、他に DSL 構文を持たない
    # caller から呼ばれても引数型検査に参加していなかった（review 指摘）。
    if (match(s, /function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(([^)]*)\)/, m) && m[2] ~ /:/) {
      if (!(m[1] in V2_DSL_FUNCNAME)) { V2_DSL_FUNCNAME[m[1]] = 1; names = names (n++ ? "|" : "") m[1] }
    }
  }
  V2_FUNCNAME_CALL_RE = names
}

function v2_is_dsl(line,    s) {
  s = v2_strip_str_comment(line)
  # let / when をワード境界で検出
  if (s ~ /(^|[^[:alnum:]_])(let|when)([^[:alnum:]_]|$)/) return 1
  # end : when...end を閉じる DSL の "end" は単独行としてのみ現れる
  # （docs/dsl.md の when...of...end 例は常にこの形）。素の awk 変数 `end` を
  # 使う代入・参照が同じ語のせいで DSL 誤判定される事故を避ける（CQ）。
  # 注: "of" は文法上つねに同一行の "when ... of" としてしか現れないため、
  # 上の when 検出だけで拾える。単独の bare "of" 判定は削除した（CQ）。
  if (s ~ /^[[:space:]]*end[[:space:]]*$/) return 1
  # type NAME = ...（型エイリアス宣言、docs/dsl.md:504-505。AP）
  if (s ~ /(^|[^[:alnum:]_])type[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) return 1
  # ??  |>  #{  ?=  演算子
  if (s ~ /\?\?|\|>|#\{|\?=/) return 1
  # function NAME(...) ->  シグネチャ
  if (s ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*->/) return 1
  # 名前空間付きアクセス (hawk. ctx. 等)
  if (s ~ /(^|[^[:alnum:]_])(hawk|ctx|env|cache|safe|msg|proc|json|option)\.[[:alnum:]_]/) return 1
  # 型注釈  : Int / : Str / : Response 等（docs/dsl.md:96 のサポート型一覧。BA）
  # 組込みエイリアス（check.awk の v2_init_builtins の ALIAS[] と同じ一覧。
  # review EM。旧実装は Port/JsonValue/JsonObject/HtmlPart 等の組込み
  # エイリアスのみを型注釈に使う関数 `function f(x: JsonValue) { ... }` を
  # DSL として検出できず、注釈が生のまま awk に渡り構文エラーになっていた）。
  if (s ~ /:[[:space:]]*(Int|Float|Str|Bool|NumericStr|Array|Map|Response|Untrusted<|HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr|Void|Any|List<|Dict<|Record|Result<|Option<|Port|HandlerName|HtmlPart|JsonScalar|JsonValue|JsonObject|JsonError)/) return 1
  # ユーザー定義 type エイリアスのみによる型注釈（CE）。v2_collect_type_aliases
  # が事前収集した名前集合と ": NAME" 形で照合する。
  if (V2_ALIAS_TYPEANN_RE != "" && s ~ (":[[:space:]]*(" V2_ALIAS_TYPEANN_RE ")([^[:alnum:]_]|$)")) return 1
  # 既知の注釈付きユーザー関数の呼び出し（review EQ）。v2_collect_annotated_funcs
  # が事前収集した関数名集合と "NAME(" 形で照合する。DSL マーカーを一切
  # 持たない未注釈関数本体（`function handler() { normalize(123) }`）でも、
  # 呼び出し先が引数型検査対象の関数なら DSL 扱いにする。v1 は関数境界に
  # 関係なく行単位で引数型を検査するため、この呼び出しを見逃さない。
  if (V2_FUNCNAME_CALL_RE != "" && s ~ ("(^|[^[:alnum:]_])(" V2_FUNCNAME_CALL_RE ")[[:space:]]*\\(")) return 1
  return 0
}

# 文字列リテラル・コメントを丸ごと取り除いた行を返す（ブレース深さ計測専用）。
# v2_strip_str_comment と異なり、文字列内の補間 #{ ... } も丸ごと取り除く。
# 補間の閉じ } まで対称に残さないと、文字列内の "#{" だけが LBRACE として
# カウントされて深さが過大になり、本体終端 } の探索がファイル末尾まで暴走する
# （実際に無注釈関数の本体に補間文字列があるケースで発生した回帰）。
# regex リテラル（`/}/` 等）の中身も除去する（CX）。文字列・コメントしか
# 除去していなかったため、素の awk 行の regex リテラル内のブレースを数えて
# しまい、後続の DSL 本体検出が早期終了扱いになる誤検出があった
# （wave 6 BG が v2_strip_str_comment 向けに実装した v2_regex_start_here /
# v2_skip_regex_text の判定をここでも再利用する）。
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
    if (ch == "/" && v2_regex_start_here(out)) { i = v2_skip_regex_text(line, i); continue }
    out = out ch
  }
  return out
}

# 注釈なし（-> RETTYPE を持たない）DSL 関数ヘッダを検出する。
# 本体（{ に対応する } まで）に DSL 構文が 1 行でもあれば、
# ヘッダ行から閉じ } の行までを V2_FORCE_DSL[] に印付けする。
function v2_mark_unannotated_func(nlines,    i, j, k, depth, stripped, tmp, n_open, n_close, has_dsl, header, brace_line, look) {
  for (i = 1; i <= nlines; i++) {
    # ヘッダ判定はコメントを含む生行ではなく、コメント除去後の行に対して行う
    # （`function f() { # comment` のような行末コメントがあると「行末 {」判定が
    #   偽になり、ヘッダが未検出のまま本体が DSL 扱いされない不具合を防ぐ）。
    header = v2_strip_for_brace_count(V2_RAWLINE[i])
    if (header !~ /(^|[^[:alnum:]_])function([^[:alnum:]_]|$)/) continue
    if (header ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*->/) continue

    # ヘッダ行末に { があればその行、無ければ次行以降の最初の非空行が
    # `{` で始まるかを見て本体開始行を決める（CP: 未注釈関数の次行ブレース。
    # wave 7 BQ が注釈付き関数向けに実装した pending_brace と同じ検出帯）。
    brace_line = 0
    if (header ~ /\{[[:space:]]*$/) {
      brace_line = i
    } else if (header ~ /function[[:space:]]+[[:alnum:]_]+[[:space:]]*\([^)]*\)[[:space:]]*$/) {
      for (j = i + 1; j <= nlines; j++) {
        look = v2_strip_for_brace_count(V2_RAWLINE[j])
        if (look ~ /^[[:space:]]*$/) continue
        if (look ~ /^[[:space:]]*\{/) brace_line = j
        break
      }
    }
    if (!brace_line) continue

    stripped = v2_strip_for_brace_count(V2_RAWLINE[brace_line])
    tmp = stripped; n_open  = gsub(/{/, "", tmp)
    tmp = stripped; n_close = gsub(/}/, "", tmp)
    depth   = n_open - n_close
    has_dsl = 0
    # ブレース行自体に 1 行ボディがある形（`{ let x: Int = 1 }`）を見逃さない
    # よう、DSL 判定のスキャンをブレース行自体からも行う（review ED。
    # 旧実装は brace_line + 1 からしか走査せず、次行ブレース関数の
    # ブレース行同居ボディが未検査のまま RAWLINE になっていた）。
    if (v2_is_dsl(V2_RAWLINE[brace_line])) has_dsl = 1
    for (j = brace_line + 1; j <= nlines && depth > 0; j++) {
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

  delete V2_DSL_ALIAS
  V2_ALIAS_TYPEANN_RE = ""
  v2_collect_type_aliases(nlines)

  delete V2_DSL_FUNCNAME
  V2_FUNCNAME_CALL_RE = ""
  v2_collect_annotated_funcs(nlines)

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
  # 数値リテラル（指数表記 1e3 / 1.5e-2 / 1E+10 を含む。CM）
  if (match(rest, /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
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
          # ネストした文字列リテラル（内側の } を補間終端と誤認しないよう先に処理）
          if (ch == "\"") {
            consumed = v2_tok_str(substr(rest, i), lineno, startcol + i - 1)
            i += consumed
            continue
          }
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

    # 先頭ドット float リテラル（.5 / .5e2）: NUM の正規表現が小数点前の
    # 数字を必須としており、直前が値でない位置（`return .5` 等）の `.5` が
    # DOT + NUM に分解されて stack underflow していた（DG）。dot 演算子
    # （`a.b`）は直前が値のときのみ意味を持つため、直前が値でない場合に
    # 限って先頭ドット NUM として読む。
    if (rest ~ /^\.[0-9]/ && !v2_prevtok_is_value()) {
      match(rest, /^\.[0-9]+([eE][+-]?[0-9]+)?/)
      v2_push("NUM", substr(rest, 1, RLENGTH), lineno, pos)
      pos += RLENGTH
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
