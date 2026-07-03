# SPDX-License-Identifier: MIT
# dsl/v2/check.awk -- 静的検査 パス1: シグネチャ・型情報収集
#
# 消費: AST[]（dsl/v2/parse.awk）
# 生成:
#   SIG[name,"arity"]      関数の宣言引数数（可変長は -1）
#   SIG[name,"arity_max"]  省略可能引数を含む最大引数数（省略時は arity と同じ）
#   SIG[name,"ret"]        戻り値型
#   SIG[name,"arg" n]      n 番目（1-indexed）の引数型
#   ALIAS[name]            型エイリアスの展開先
#   VARIANTS[adt]          ADT のタグ集合（SUBSEP 区切り、"ok" SUBSEP "ng" など）
#   TYPEOF[id]             AST ノード id の型（式ノード全般。文ノードは持たない）
#
# v2_check() はこのファイルの唯一のエントリポイント。
# 5 周構成:
#   1. v2_collect(1)     -- FUNC ノードを収集して SIG[] を充填（前方参照に対応するため全体を先に走査）
#   2. v2_check_calls(1) -- CALL ノードの arity を検査し TYPEOF[] を設定
#   3. v2_infer(1)       -- 後順走査でボトムアップ型推論を行い、LET/RETURN の型注釈・LETQ の ?= 規則を検査
#   4. v2_check_when(1)  -- WHEN ノードの網羅性（ok/ng/some/none・型付き ng 腕の union 網羅）を検査
#   5. v2_check_brand(1) -- CALL 引数の型（XSS ブランド型含む）を SIG[] の宣言と照合

# ─── 組込みシグネチャ・型エイリアス登録（dsl/sig.awk より移植） ──────

function v2_init_builtins() {
  # 型エイリアス
  ALIAS["Port"]          = "Int|NumericStr|Str"
  ALIAS["HandlerName"]   = "Str"
  ALIAS["Safe<HtmlStr>"] = "HtmlEscapedStr"
  ALIAS["Safe<Str>"]     = "Str"
  ALIAS["HtmlPart"]      = "HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr"
  ALIAS["JsonScalar"]    = "Str|Int|Float|Bool|Null"
  ALIAS["JsonValue"]     = "JsonScalar|Array|JsonObject"
  ALIAS["JsonObject"]    = "Map"
  ALIAS["JsonError"]     = "JsonParseError|JsonTooDeepError"

  # env.*
  SIG["env.get","ret"] = "Str";  SIG["env.get","arity"] = 1; SIG["env.get","arg1"] = "Str"
  SIG["env.set","ret"] = "Void"; SIG["env.set","arity"] = 2; SIG["env.set","arg1"] = "Str"; SIG["env.set","arg2"] = "Str"
  SIG["env.del","ret"] = "Void"; SIG["env.del","arity"] = 1; SIG["env.del","arg1"] = "Str"
  SIG["env.has","ret"] = "Bool"; SIG["env.has","arity"] = 1; SIG["env.has","arg1"] = "Str"

  # ctx.req.*
  SIG["ctx.req.form","ret"]   = "Result<Untrusted<Str>, ParseError>"; SIG["ctx.req.form","arity"]   = 1; SIG["ctx.req.form","arg1"]   = "Str"
  SIG["ctx.req.query","ret"]  = "Result<Untrusted<Str>, ParseError>"; SIG["ctx.req.query","arity"]  = 1; SIG["ctx.req.query","arg1"]  = "Str"
  SIG["ctx.req.param","ret"]  = "Result<Untrusted<Str>, ParseError>"; SIG["ctx.req.param","arity"]  = 1; SIG["ctx.req.param","arg1"]  = "Str"
  SIG["ctx.req.header","ret"] = "Result<Untrusted<Str>, ParseError>"; SIG["ctx.req.header","arity"] = 1; SIG["ctx.req.header","arg1"] = "Str"
  SIG["ctx.req.body","ret"]   = "Result<Untrusted<Str>, ParseError>"; SIG["ctx.req.body","arity"]   = 0

  SIG["ctx.req.json","ret"]        = "Result<Untrusted<JsonValue>, JsonParseError|JsonTooDeepError>"; SIG["ctx.req.json","arity"]        = 0
  SIG["ctx.req.json_object","ret"] = "Result<Untrusted<JsonObject>, JsonParseError|JsonTooDeepError>"; SIG["ctx.req.json_object","arity"] = 0
  SIG["ctx.req.json_t","ret"]      = "Result<T, JsonParseError|JsonTypeError|JsonTooDeepError>"; SIG["ctx.req.json_t","arity"] = 1; SIG["ctx.req.json_t","arg1"] = "Str"

  # ctx.res.*
  SIG["ctx.res.json","ret"]     = "Response"; SIG["ctx.res.json","arity"]     = 1; SIG["ctx.res.json","arg1"]     = "Any"
  SIG["ctx.res.json_raw","ret"] = "Response"; SIG["ctx.res.json_raw","arity"] = 1; SIG["ctx.res.json_raw","arg1"] = "Str"
  SIG["ctx.res.text","ret"]     = "Response"; SIG["ctx.res.text","arity"]     = 1; SIG["ctx.res.text","arg1"]     = "Str|Untrusted<Str>"
  SIG["ctx.res.html","ret"]     = "Response"; SIG["ctx.res.html","arity"]     = 1; SIG["ctx.res.html","arg1"]     = "HtmlEscapedStr|HtmlFragment"

  # safe.*
  SIG["safe.html.escape","ret"] = "HtmlEscapedStr"; SIG["safe.html.escape","arity"] = 1; SIG["safe.html.escape","arg1"] = "Str|Untrusted<Str>"
  SIG["safe.attr.escape","ret"] = "HtmlAttrEscapedStr"; SIG["safe.attr.escape","arity"] = 1; SIG["safe.attr.escape","arg1"] = "Str|Untrusted<Str>"
  SIG["safe.str.trust","ret"]   = "Str"; SIG["safe.str.trust","arity"] = 1; SIG["safe.str.trust","arg1"] = "Untrusted<Str>"
  SIG["safe.html.raw","ret"]    = "HtmlFragment"; SIG["safe.html.raw","arity"] = 1; SIG["safe.html.raw","arg1"] = "Str"
  SIG["safe.html.fragment","ret"] = "HtmlFragment"; SIG["safe.html.fragment","arity"] = -1; SIG["safe.html.fragment","arg1"] = "HtmlPart"

  SIG["ctx.res.render","ret"]   = "Response"; SIG["ctx.res.render","arity"]   = 1; SIG["ctx.res.render","arg1"] = "Str"
  SIG["ctx.res.status","ret"]   = "Response"; SIG["ctx.res.status","arity"]   = 1; SIG["ctx.res.status","arg1"] = "Int"
  SIG["ctx.res.header","ret"]   = "Response"; SIG["ctx.res.header","arity"]   = 2; SIG["ctx.res.header","arg1"] = "Str"; SIG["ctx.res.header","arg2"] = "Str"
  SIG["ctx.res.redirect","ret"] = "Response"; SIG["ctx.res.redirect","arity"] = 1; SIG["ctx.res.redirect","arity_max"] = 2
  SIG["ctx.res.redirect","arg1"] = "Str"; SIG["ctx.res.redirect","arg2"] = "Int"

  # hawk.app.* (route registration)
  SIG["hawk.app.get","ret"]   = "Void"; SIG["hawk.app.get","arity"]   = 2; SIG["hawk.app.get","arg1"]   = "Str"; SIG["hawk.app.get","arg2"]   = "HandlerName"
  SIG["hawk.app.post","ret"]  = "Void"; SIG["hawk.app.post","arity"]  = 2; SIG["hawk.app.post","arg1"]  = "Str"; SIG["hawk.app.post","arg2"]  = "HandlerName"
  SIG["hawk.app.put","ret"]   = "Void"; SIG["hawk.app.put","arity"]   = 2; SIG["hawk.app.put","arg1"]   = "Str"; SIG["hawk.app.put","arg2"]   = "HandlerName"
  SIG["hawk.app.del","ret"]   = "Void"; SIG["hawk.app.del","arity"]   = 2; SIG["hawk.app.del","arg1"]   = "Str"; SIG["hawk.app.del","arg2"]   = "HandlerName"
  SIG["hawk.app.patch","ret"] = "Void"; SIG["hawk.app.patch","arity"] = 2; SIG["hawk.app.patch","arg1"] = "Str"; SIG["hawk.app.patch","arg2"] = "HandlerName"
  SIG["hawk.app.head","ret"]  = "Void"; SIG["hawk.app.head","arity"]  = 2; SIG["hawk.app.head","arg1"]  = "Str"; SIG["hawk.app.head","arg2"]  = "HandlerName"

  SIG["hawk.app.query","ret"] = "Void"; SIG["hawk.app.query","arity"] = 2; SIG["hawk.app.query","arity_max"] = 3
  SIG["hawk.app.query","arg1"] = "Str"; SIG["hawk.app.query","arg2"] = "HandlerName"; SIG["hawk.app.query","arg3"] = "List"

  SIG["hawk.app.on","ret"] = "Void"; SIG["hawk.app.on","arity"] = 3
  SIG["hawk.app.on","arg1"] = "Str"; SIG["hawk.app.on","arg2"] = "Str"; SIG["hawk.app.on","arg3"] = "HandlerName"

  SIG["hawk.app.all","ret"] = "Void"; SIG["hawk.app.all","arity"] = 2
  SIG["hawk.app.all","arg1"] = "Str"; SIG["hawk.app.all","arg2"] = "HandlerName"

  SIG["hawk.app.listen","ret"] = "Void"; SIG["hawk.app.listen","arity"] = 1; SIG["hawk.app.listen","arg1"] = "Port"

  # app runtime helpers (TSV storage + JSON)
  SIG["read_tsv","ret"] = "Int"; SIG["read_tsv","arity"] = 2; SIG["read_tsv","arg1"] = "Str"; SIG["read_tsv","arg2"] = "Array"

  SIG["delete_tsv","ret"] = "Int"; SIG["delete_tsv","arity"] = 3
  SIG["delete_tsv","arg1"] = "Str"; SIG["delete_tsv","arg2"] = "Str"; SIG["delete_tsv","arg3"] = "Str|Untrusted<Str>"

  SIG["append_tsv","ret"] = "Void"; SIG["append_tsv","arity"] = 2
  SIG["append_tsv","arg1"] = "Str"; SIG["append_tsv","arg2"] = "Array"

  SIG["json_encode","ret"] = "Str"; SIG["json_encode","arity"] = 1; SIG["json_encode","arg1"] = "Array"

  SIG["json.encode","ret"] = "Str"; SIG["json.encode","arity"] = 1; SIG["json.encode","arg1"] = "Any"

  SIG["json.decode","ret"] = "Result<JsonValue, JsonParseError|JsonTooDeepError>"
  SIG["json.decode","arity"] = 1; SIG["json.decode","arg1"] = "Str"

  SIG["json.decode_object","ret"] = "Result<JsonObject, JsonParseError|JsonTooDeepError>"
  SIG["json.decode_object","arity"] = 1; SIG["json.decode_object","arg1"] = "Str"

  # decode_t: arg1 は desugar が前置する型名文字列、arg2 がユーザーの渡す入力文字列
  SIG["json.decode_t","ret"] = "Result<T, JsonParseError|JsonTypeError|JsonTooDeepError>"
  SIG["json.decode_t","arity"] = 2; SIG["json.decode_t","arg1"] = "Str"; SIG["json.decode_t","arg2"] = "Str"

  # option constructors
  SIG["option.some","ret"] = "Option<Any>"; SIG["option.some","arity"] = 1; SIG["option.some","arg1"] = "Any"
  SIG["option.none","ret"] = "Option<Any>"; SIG["option.none","arity"] = 0

  # cache.*
  SIG["cache.get","ret"] = "Effect<Result<Option<Str>, CacheError>>"; SIG["cache.get","arity"] = 1; SIG["cache.get","arg1"] = "Str"

  SIG["cache.set","ret"] = "Effect<Result<Void, CacheError>>"; SIG["cache.set","arity"] = 3
  SIG["cache.set","arg1"] = "Str"; SIG["cache.set","arg2"] = "Any"; SIG["cache.set","arg3"] = "Int"

  SIG["cache.del","ret"] = "Effect<Result<Bool, CacheError>>"; SIG["cache.del","arity"] = 1; SIG["cache.del","arg1"] = "Str"
  SIG["cache.has","ret"] = "Effect<Result<Bool, CacheError>>"; SIG["cache.has","arity"] = 1; SIG["cache.has","arg1"] = "Str"
}

# ─── パス 1: シグネチャ収集 ────────────────────────────────────────

# AST を再帰的に走査し、FUNC ノードから SIG[] を充填する。
# 前方参照（定義前の呼び出し）に対応するため、arity 検査より先に全体を走査する。
function v2_collect(id,    k, name, child, argn) {
  if (AST[id,"kind"] == "TYPEDECL") {
    # type NAME = TYPE_EXPR（AP）。組込み ALIAS と同じ展開経路（v2_expand_alias）
    # に乗せるだけで、既存の v2_type_compat / v2_unwrap_type 等はそのまま使える。
    # 循環検出（BR）は ALIAS[] がファイル全体分そろってから別パスで行うため、
    # ここでは宣言順・行番号だけ記録しておく。
    if (AST[id,"nc"] >= 1) {
      name = AST[id,"text"]
      ALIAS[name] = AST[AST[id,"c1"],"text"]
      ALIAS_DECL_LINE[name] = AST[id,"line"]
      ALIAS_DECL_ORDER[++ALIAS_DECL_N] = name
    }
  } else if (AST[id,"kind"] == "FUNC") {
    name = AST[id,"text"]
    SIG[name,"arity"] = 0
    SIG[name,"ret"]   = "Unknown"
    argn = 0
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "PARAM") {
        argn++
        if (AST[child,"nc"] >= 1) {
          SIG[name,"arg" argn] = AST[AST[child,"c1"],"text"]
        } else {
          SIG[name,"arg" argn] = "Any"
        }
      } else if (AST[child,"kind"] == "TYPEANN") {
        SIG[name,"ret"] = AST[child,"text"]
      } else if (AST[child,"kind"] == "RAWLINE" && \
                 AST[child,"text"] ~ /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/) {
        # `classify: transform|validator|sanitizer|sink` 注釈（CA。
        # dsl/desugar.awk の pass1 classify 収集と同じ 4 値）。DSL 文として
        # トークナイズされないため関数本体では RAWLINE として現れる。
        SIG[name,"classify"] = AST[child,"text"]
        sub(/^[[:space:]]*classify:[[:space:]]*/, "", SIG[name,"classify"])
        sub(/[[:space:]]*$/, "", SIG[name,"classify"])
      }
    }
    SIG[name,"arity"] = argn
  }

  for (k = 1; k <= AST[id,"nc"]; k++) v2_collect(AST[id,"c" k])
}

# ─── パス 2: CALL の arity 検査・TYPEOF 設定 ───────────────────────

# extra: PIPE の RHS にある CALL は、パイプで渡される左辺値の分だけ実引数が
# +1 されるとみなす（`x |> f()` は f を実質 1 引数で呼ぶのと同じ）。
function v2_check_calls(id, extra,    k, name, min_arity, max_arity, actual, child_extra) {
  if (AST[id,"kind"] == "CALL") {
    name = AST[id,"text"]
    if ((name,"arity") in SIG) {
      min_arity = SIG[name,"arity"]
      max_arity = ((name,"arity_max") in SIG) ? SIG[name,"arity_max"] : min_arity
      actual    = AST[id,"nc"] + extra
      if (min_arity != -1 && (actual < min_arity || actual > max_arity)) {
        v2_diag(AST[id,"line"], 1, name " expects " min_arity " argument(s), got " actual)
      }
      TYPEOF[id] = SIG[name,"ret"]
    } else if (name ~ /_t$/) {
      # rpn.awk の generic 呼び出し正規化（f<T>(...) -> f_t("T", ...)）が
      # 生成した名前のうち SIG 未登録のもの（v1 dsl/desugar_dot.awk の
      # unknown generic dispatch と同じ扱い。BJ。v1 実測でエラーになることを確認済み）。
      v2_diag(AST[id,"line"], 1, "unknown generic dispatch: " name)
    }
  }

  for (k = 1; k <= AST[id,"nc"]; k++) {
    child_extra = (AST[id,"kind"] == "PIPE" && k == 2) ? 1 : 0
    v2_check_calls(AST[id,"c" k], child_extra)
  }
}

# ─── パス 3: ボトムアップ型推論・注釈検査（Task 8） ─────────────────
#
# v2_infer(id) は後順走査で TYPEOF[id] を充填する。戻り値は自ノードの型文字列
# （型を持たない文ノード = LET/FUNC/RETURN 等では ""）。
#
# 型規則（docs/dsl.md・dsl/typecheck.awk 互換）:
#   NUMLIT                              -> Int（小数点含みは Float）
#   STRLIT                              -> Str
#   BINOP + - * / % ^                   -> 両辺 Int なら Int、どちらか Float なら Float、他は error
#   BINOP CONCAT                        -> Str
#   BINOP == != < <= > >= ~ !~ && ||    -> Bool
#   UNOP NOT                            -> Bool
#   UNOP NEG                            -> オペランドと同じ数値型（Unknown なら Unknown）
#   CALL f(...)                         -> SIG[f,"ret"]（未知関数は Unknown）
#   DOT（レシーバ.メソッド(...) 呼び出し）-> SIG["レシーバ.メソッド","ret"]（未登録は Unknown）
#   COALESCE a ?? b                     -> unwrap(typeof a) と typeof b の合流
#   RAW                                 -> Unknown
#   Unknown が絡む演算                   -> Unknown（診断なし = 誤検出防止）

# 型文字列をトップレベル "|"（<...> の深さを尊重）で分割する
function v2_split_union(t, out,    i, c, depth, cur, n) {
  n = 0; depth = 0; cur = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if      (c == "<") depth++
    else if (c == ">") depth--
    else if (c == "|" && depth == 0) { out[++n] = cur; cur = ""; continue }
    cur = cur c
  }
  if (length(cur) > 0) out[++n] = cur
  return n
}

# 型引数リストをトップレベル ","（<...> の深さを尊重）で分割する
function v2_split_generic_args(t, out,    i, c, depth, cur, n) {
  n = 0; depth = 0; cur = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if      (c == "<") depth++
    else if (c == ">") depth--
    else if (c == "," && depth == 0) { out[++n] = cur; cur = ""; continue }
    cur = cur c
  }
  if (length(cur) > 0) out[++n] = cur
  for (i = 1; i <= n; i++) { sub(/^[ ]+/, "", out[i]); sub(/[ ]+$/, "", out[i]) }
  return n
}

# 型エイリアスを 1 段展開する（循環防止のため最大 8 段まで）
function v2_expand_alias(t,    guard) {
  guard = 0
  while ((t in ALIAS) && guard < 8) { t = ALIAS[t]; guard++ }
  return t
}

# 2 つの型を合流させた Union 文字列を返す（重複は除去）
function v2_union_of(a, b,    parts, seen, n, i, out, k, result) {
  if (a == "" || a == "Any") return b
  if (b == "" || b == "Any") return a
  if (a == b) return a
  n = v2_split_union(a "|" b, parts)
  k = 0
  for (i = 1; i <= n; i++) {
    if (!(parts[i] in seen)) { seen[parts[i]] = 1; out[++k] = parts[i] }
  }
  result = out[1]
  for (i = 2; i <= k; i++) result = result "|" out[i]
  return result
}

# expected が actual を受理するか（Union `A|B` 対応・ALIAS 展開）
function v2_type_compat(expected, actual,    ea, aa, en, an, i, j, eparts, aparts, \
                         eg, ag, egn, agn, egargs, agargs, matched) {
  if (expected == actual)             return 1
  if (expected == "Any" || expected == "Unknown") return 1
  if (actual   == "Any" || actual   == "Unknown") return 1
  if (actual == "")                   return 1
  # Array は typed collection（List</Dict<）の supertype（v1 dsl/type.awk:134-135
  # 移植。BK）。Map は v1 accepts() 側でも特別扱いされていないため対象外。
  if (expected == "Array" && (actual ~ /^List</ || actual ~ /^Dict</)) return 1

  ea = v2_expand_alias(expected)
  aa = v2_expand_alias(actual)
  if (ea != expected || aa != actual) return v2_type_compat(ea, aa)

  # 同名 generic 同士は型引数ごとに構造的に比較する（内側のエイリアスも展開される）
  if (match(expected, /^([A-Za-z_][A-Za-z0-9_]*)<(.+)>$/, eg) && \
      match(actual,   /^([A-Za-z_][A-Za-z0-9_]*)<(.+)>$/, ag) && eg[1] == ag[1]) {
    egn = v2_split_generic_args(eg[2], egargs)
    agn = v2_split_generic_args(ag[2], agargs)
    if (egn == agn) {
      for (i = 1; i <= egn; i++) if (!v2_type_compat(egargs[i], agargs[i])) return 0
      return 1
    }
    return 0
  }

  en = v2_split_union(expected, eparts)
  an = v2_split_union(actual,   aparts)

  if (en > 1 && an > 1) {
    # 両側 union: 実際の各メンバーが期待のいずれかのメンバーに受容されることを
    # 要求する（順序違いの等価 union を受理する。AX）。
    for (j = 1; j <= an; j++) {
      matched = 0
      for (i = 1; i <= en; i++) if (v2_type_compat(eparts[i], aparts[j])) { matched = 1; break }
      if (!matched) return 0
    }
    return 1
  }
  if (en > 1) {
    for (i = 1; i <= en; i++) if (v2_type_compat(eparts[i], actual)) return 1
    return 0
  }
  if (an > 1) {
    for (j = 1; j <= an; j++) if (!v2_type_compat(expected, aparts[j])) return 0
    return 1
  }
  return 0
}

# Effect<T> ラッパを 1 段剥がす（docs/dsl.md:636-654）。?= と when...of は
# Option/Result 判定の前に Effect を剥がしてから通常のルールを適用する。
# Effect でなければそのまま返す。
function v2_strip_effect(t,    m) {
  if (match(t, /^Effect<(.+)>$/, m)) return m[1]
  return t
}

# Effect 剥がしと type エイリアス展開を交互に適用し、`type R = Result<...>` の
# ような別名越しの sealed 型も実体まで解決する（BZ+CC。v1 実測: pipe/`?=`
# いずれもエイリアス展開後の実体型で sealed 判定する）。
function v2_resolve_sealed(t,    guard, prev) {
  guard = 0
  do {
    prev = t
    t = v2_strip_effect(t)
    t = v2_expand_alias(t)
    guard++
  } while (t != prev && guard < 8)
  return t
}

# Result<T, E> の内部をトップレベル "," で T/E に分割する（AN のヘルパを一般化。
# AW）。`[^,]+` による単純分割だと T 側にネストした generic
# （`Result<Dict<Str, Int>, ParseError>` 等）内部のカンマで誤分割するため、
# v2_split_generic_args の深さ追跡分割を再利用する。
# out[1]=T, out[2]=E。Result<...> でなければ 0 を返す。
function v2_result_parts(t, out,    m, inner) {
  if (!match(t, /^Result<(.+)>$/, m)) return 0
  inner = m[1]
  return v2_split_generic_args(inner, out)
}

# Option<T> / Result<T, E> の内側の型を取り出す（Union は各枝を合流）
function v2_unwrap_type(t,    parts, n, i, inner, m, result, rparts, rn) {
  n = v2_split_union(t, parts)
  result = ""
  for (i = 1; i <= n; i++) {
    inner = parts[i]
    if (match(inner, /^Option<(.+)>$/, m)) {
      inner = m[1]
    } else if (inner ~ /^Result</) {
      rn = v2_result_parts(inner, rparts)
      if (rn >= 1) inner = rparts[1]
    }
    result = v2_union_of(result, inner)
  }
  return result
}

# 二項演算子の結果型を決定する（Unknown が絡む場合は診断なしで Unknown）
function v2_binop_type(op, lt, rt, line,    is_num_op) {
  if (op == "==" || op == "!=" || op == "<" || op == "<=" || \
      op == ">"  || op == ">=" || op == "~" || op == "!~" || \
      op == "&&" || op == "||") {
    return "Bool"
  }
  # 文字列連結は brand 型（HtmlEscapedStr 等）を失い Str に落ちる（docs/dsl.md:264
  # の補間規則と同型: いずれかのオペランドが Untrusted<...> なら結果も
  # Untrusted<Str> を伝播する。CK）。
  if (op == "CONCAT") return (lt ~ /^Untrusted</ || rt ~ /^Untrusted</) ? "Untrusted<Str>" : "Str"

  is_num_op = (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "^")
  if (is_num_op) {
    if (lt == "Unknown" || rt == "Unknown") return "Unknown"
    if (lt == "Int" && rt == "Int") return "Int"
    if ((lt == "Int" || lt == "Float") && (rt == "Int" || rt == "Float")) return "Float"
    v2_diag(line, 1, "type mismatch: incompatible operand types " lt " and " rt " for operator '" op "'")
    return "Unknown"
  }

  return "Unknown"
}

# INDEX（添字式 target[idx]）の要素型を決定する（BE）。
# target が Dict<K, V> なら V、List<T> なら T、それ以外・Unknown は Unknown。
# 添字式の型も検査する（docs/dsl.md:108「Only numeric indices are allowed.
# String keys are a type error.」BN）: List は Int 添字のみ、Dict<Str, V> は
# Str 添字のみ。添字が Unknown なら誤検出防止のため素通しする。
function v2_index_type(id,    target_type, key_type, m, dn, dparts) {
  target_type = v2_resolve_sealed(TYPEOF[AST[id,"c1"]])
  key_type    = TYPEOF[AST[id,"c2"]]
  if (target_type == "" || target_type == "Unknown") return "Unknown"
  if (match(target_type, /^List<(.+)>$/, m)) {
    if (key_type != "" && key_type != "Unknown" && key_type != "Int") {
      v2_diag(AST[id,"line"], 1, \
        "List requires numeric index, got string key " AST[AST[id,"c2"],"text"])
    }
    return m[1]
  }
  if (match(target_type, /^Dict<(.+)>$/, m)) {
    dn = v2_split_generic_args(m[1], dparts)
    if (dn < 2) return "Unknown"
    if (key_type != "" && key_type != "Unknown" && key_type != "Str") {
      v2_diag(AST[id,"line"], 1, \
        "Dict<Str, V> requires string key, got integer " AST[AST[id,"c2"],"text"])
    }
    return dparts[2]
  }
  return "Unknown"
}

# INDEX_ASSIGN（`name[idx] = rhs`）を検査する（CB）。
# キー型検査は v1 実測文面に合わせる（dsl/typecheck.awk:_ds_check_collection_assign
# 互換: "name: List requires numeric index, got string key IDX" /
# "name: Dict<Str, V> requires string key, got integer IDX"）。
# 代入値と要素型の互換検査は v1 に対応する検査が無い（v1 は
# _ds_check_collection_assign でキー型しか見ない）v2 独自の追加厳格化であり、
# List<Int> の要素型検査を有効にするという CB の目的そのもの。
function v2_check_index_assign(id,    name, idx_id, rhs_id, target_type, key_type, rhs_type, m) {
  name        = AST[id,"text"]
  idx_id      = AST[id,"c1"]
  rhs_id      = AST[id,"c2"]
  target_type = (name in V2_ENV) ? V2_ENV[name] : "Unknown"
  # `type Ints = List<Int>` のようなエイリアス越しの宣言も List</Dict<
  # パターンに合わせて検査できるよう、判定前に 1 段以上展開する（CU/CY）。
  target_type = v2_expand_alias(target_type)
  if (target_type == "" || target_type == "Unknown") return
  key_type = (idx_id != 0 && (idx_id in TYPEOF)) ? TYPEOF[idx_id] : ""
  rhs_type = (rhs_id != 0 && (rhs_id in TYPEOF)) ? TYPEOF[rhs_id] : ""

  if (match(target_type, /^List<(.+)>$/, m)) {
    if (key_type != "" && key_type != "Unknown" && key_type != "Int") {
      v2_diag(AST[id,"line"], 1, \
        name ": List requires numeric index, got string key " AST[idx_id,"text"])
    }
    if (rhs_type != "" && rhs_type != "Unknown" && !v2_type_compat(m[1], rhs_type)) {
      v2_diag(AST[id,"line"], 1, "type mismatch: cannot assign " rhs_type " to " m[1])
    }
  } else if (match(target_type, /^Dict<[^,]+,[[:space:]]*(.+)>$/, m)) {
    if (key_type != "" && key_type != "Unknown" && key_type != "Str") {
      v2_diag(AST[id,"line"], 1, \
        name ": Dict<Str, V> requires string key, got integer " AST[idx_id,"text"])
    }
    if (rhs_type != "" && rhs_type != "Unknown" && !v2_type_compat(m[1], rhs_type)) {
      v2_diag(AST[id,"line"], 1, "type mismatch: cannot assign " rhs_type " to " m[1])
    }
  }
}

# DOT（レシーバ.メソッド(...) 呼び出し）の戻り型を決定する
# receiver が単純 IDENT でメソッドが CALL の場合のみ "receiver.method" で SIG[] を引く。
function v2_dot_type(id,    recv, callnode, name) {
  recv     = AST[id,"c1"]
  callnode = AST[id,"c2"]
  if (AST[recv,"kind"] != "IDENT" || AST[callnode,"kind"] != "CALL") return "Unknown"
  name = AST[recv,"text"] "." AST[callnode,"text"]
  if ((name,"ret") in SIG) return SIG[name,"ret"]
  return "Unknown"
}

# WHEN の腕パターンが導入する束縛変数の型を決定する（AV）。
# tag=ok/some: 対象型の成功部（v2_unwrap_type と同じ Option<T>/Result<T,E> の T）。
# tag=ng/default: 型付き（`ng e<X>:`）なら X、無型（`ng e:`/`default e:`）なら
# 対象の Result のエラー部全体（v1 desugar_match.awk の _ds_result_err_type 相当）。
# それ以外（none/_ 等、通常は無束縛）は Unknown。
function v2_when_bind_type(tag, ttype, typeann_id) {
  if (tag == "ok" || tag == "some") return v2_unwrap_type(ttype)
  if (tag == "ng" || tag == "default") {
    if (typeann_id != 0) return AST[typeann_id,"text"]
    return v2_result_err_part(ttype)
  }
  return "Unknown"
}

# WHEN ノードの型推論: 対象式を先に推論し、各腕のパターン束縛を（本体を検査する
# 前に）V2_ENV に登録してから腕本体を推論する（AV）。腕を抜けたら v1
# （dsl/desugar_match.awk の register/unregister）に合わせて束縛前の値へ戻す
# （シャドーがなければ削除）。
function v2_infer_when(id,    k, j, arm, pat, blk, pc, tag, typeann_id, bind_id, \
                        bind_name, bind_type, had_saved, saved_type, ttype) {
  v2_infer(AST[id,"c1"])
  ttype = v2_strip_effect(TYPEOF[AST[id,"c1"]])

  for (k = 2; k <= AST[id,"nc"]; k++) {
    arm = AST[id,"c" k]
    pat = AST[arm,"c1"]
    blk = AST[arm,"c2"]
    tag = AST[pat,"text"]

    bind_id = 0; typeann_id = 0
    for (j = 1; j <= AST[pat,"nc"]; j++) {
      pc = AST[pat,"c" j]
      if      (AST[pc,"kind"] == "IDENT")   bind_id = pc
      else if (AST[pc,"kind"] == "TYPEANN") typeann_id = pc
    }

    had_saved = 0
    if (bind_id != 0) {
      bind_name = AST[bind_id,"text"]
      bind_type = (ttype != "" && ttype != "Unknown") ? \
                  v2_when_bind_type(tag, ttype, typeann_id) : "Unknown"
      if (bind_name in V2_ENV) { had_saved = 1; saved_type = V2_ENV[bind_name] }
      V2_ENV[bind_name] = (bind_type != "") ? bind_type : "Unknown"
    }

    v2_infer(blk)

    if (bind_id != 0) {
      if (had_saved) V2_ENV[bind_name] = saved_type
      else           delete V2_ENV[bind_name]
    }
  }
}

# 現在走査中の関数の宣言戻り値型・名前（RETURN 文の検査に使う）
V2_CUR_FUNC_RET = ""
V2_CUR_FUNC_NAME = ""

function v2_infer(id,    k, kind, t, lt, rt, ct, typeann_id, expr_id, child, \
                   saved_ret, saved_name, ret_type, name, ret_sig, typearg, lhs_decl_type, rhs_id) {
  kind = AST[id,"kind"]

  if (kind == "FUNC") {
    name = AST[id,"text"]
    ret_type = ((name,"ret") in SIG) ? SIG[name,"ret"] : "Unknown"
    saved_ret  = V2_CUR_FUNC_RET
    saved_name = V2_CUR_FUNC_NAME
    V2_CUR_FUNC_RET  = ret_type
    V2_CUR_FUNC_NAME = name
    delete V2_ENV
    for (k = 1; k <= AST[id,"nc"]; k++) v2_infer(AST[id,"c" k])
    V2_CUR_FUNC_RET  = saved_ret
    V2_CUR_FUNC_NAME = saved_name
    return ""
  }

  if (kind == "WHEN") {
    # 腕本体（ARM の BLOCK）を検査する前にパターン束縛を V2_ENV に登録する
    # 必要があるため、通常の子優先後順走査ではなく専用関数で処理する（AV）。
    v2_infer_when(id)
    return ""
  }

  for (k = 1; k <= AST[id,"nc"]; k++) v2_infer(AST[id,"c" k])

  t = ""
  if (kind == "NUMLIT") {
    t = (AST[id,"text"] ~ /\./) ? "Float" : "Int"
  } else if (kind == "STRLIT") {
    # 補間 #{ } 内のいずれかの式が Untrusted<...> なら結果は Untrusted<Str>
    # （docs/dsl.md:264-270。BL）。内側が Unknown の場合は誤検出防止で従来どおり Str。
    # 補間式の型は、ここ（v2_infer の正順走査で V2_ENV が正しく関数スコープに
    # なっている時点）でキャッシュしておく（BM）。v2_check_fragment_interp は
    # 型推論後に全体を再走査する別パス（v2_check_brand）から呼ばれるため、その
    # 時点の V2_ENV は最後に処理した関数のものに固定されてしまい、他の関数の
    # ローカル識別子を引けない。
    if (index(AST[id,"text"], "#{") > 0) {
      v2_cache_strlit_interp_types(id, AST[id,"text"])
      t = v2_strlit_has_untrusted_interp(id) ? "Untrusted<Str>" : "Str"
    } else if (AST[id,"text"] ~ /^"[0-9]+"$/) {
      # 数字のみの文字列リテラルは NumericStr に推論する（v1
      # dsl/desugar_let.awk:_ds_infer_type と同じリテラル形状規則。実測:
      # `function f() -> NumericStr { return "8080" }` は v1 で exit 0。CL）。
      t = "NumericStr"
    } else {
      t = "Str"
    }
  } else if (kind == "REGEXLIT") {
    # v1 に Regex 型はないため Any 相当（誤検出防止。AS）。
    t = "Any"
  } else if (kind == "LISTLIT") {
    # 空リスト [] は List<Any>（v1 は List<T> への List<Any> 共変受容を許容。AY）。
    t = "List<Any>"
  } else if (kind == "DICTLIT") {
    # 空 Dict {} は Dict<Str, Any>（docs/dsl.md:113 の Dict<Str, T> 系に合わせる。AY）。
    t = "Dict<Str, Any>"
  } else if (kind == "IDENT") {
    # true/false/null はリテラルとして具象型を持つ（docs/dsl.md:143-144）。
    # V2_ENV lookup より前に特別扱いする（Task 8 の環境実装より優先度が高い）。
    if      (AST[id,"text"] == "true" || AST[id,"text"] == "false") t = "Bool"
    else if (AST[id,"text"] == "null")                              t = "Null"
    else t = (AST[id,"text"] in V2_ENV) ? V2_ENV[AST[id,"text"]] : "Unknown"
  } else if (kind == "PARAM") {
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "TYPEANN") V2_ENV[AST[id,"text"]] = AST[child,"text"]
    }
    t = ""
  } else if (kind == "RAW" || kind == "RAWLINE") {
    t = "Unknown"
  } else if (kind == "UNOP") {
    ct = TYPEOF[AST[id,"c1"]]
    if (AST[id,"text"] == "NOT") t = "Bool"
    else if (ct == "Int" || ct == "Float") t = ct
    else t = "Unknown"
  } else if (kind == "BINOP") {
    lt = TYPEOF[AST[id,"c1"]]
    rt = TYPEOF[AST[id,"c2"]]
    if (AST[id,"text"] == "=") {
      # 代入: LHS が型環境に登録済みのローカルなら RHS 型と突合する（Task 8 の
      # V2_ENV は LET/PARAM で充填済み。未登録・Unknown 同士は誤検出防止で無視）。
      if (AST[AST[id,"c1"],"kind"] == "IDENT" && (AST[AST[id,"c1"],"text"] in V2_ENV)) {
        lhs_decl_type = V2_ENV[AST[AST[id,"c1"],"text"]]
        if (rt != "" && rt != "Unknown" && lhs_decl_type != "" && lhs_decl_type != "Unknown" && \
            !v2_type_compat(lhs_decl_type, rt)) {
          v2_diag(AST[id,"line"], 1, "type mismatch: cannot assign " rt " to " lhs_decl_type)
        }
      }
      t = rt
    } else {
      t = v2_binop_type(AST[id,"text"], lt, rt, AST[id,"line"])
    }
  } else if (kind == "COALESCE") {
    # v1（dsl/desugar_let.awk:_ds_infer_type_with_orig）は `??` の型を
    # union(左辺の生の型, 右辺の型) として求め、Option/Result を unwrap しない
    # （実測: `let x: Int = option.some(1) ?? 0` は v1 で
    # "type mismatch: cannot assign Int|Option<Any> to Int" になる。BS）。
    lt = TYPEOF[AST[id,"c1"]]
    rt = TYPEOF[AST[id,"c2"]]
    t = v2_union_of(lt, rt)
  } else if (kind == "INDEX") {
    t = v2_index_type(id)
  } else if (kind == "INDEX_ASSIGN") {
    v2_check_index_assign(id)
    t = ""
  } else if (kind == "PIPE") {
    rhs_id = AST[id,"c2"]
    t = TYPEOF[rhs_id]
    # pipe RHS の CALL に明示引数が無い場合、AB の generic 戻り型特殊化が
    # 引数から型を取れず（例: option.some の戻りが Option<Any> のまま）残る
    # （BO）。pipe 入力（c1）の型を暗黙の第 1 引数とみなして特殊化し直す。
    if (AST[rhs_id,"kind"] == "CALL" && AST[rhs_id,"nc"] == 0) {
      if (AST[rhs_id,"text"] == "option.some") {
        t = "Option<" TYPEOF[AST[id,"c1"]] ">"
        TYPEOF[rhs_id] = t
      }
    }
  } else if (kind == "DOT") {
    t = v2_dot_type(id)
    TYPEOF[id] = t
  } else if (kind == "CALL") {
    name = AST[id,"text"]
    t = ((id) in TYPEOF) ? TYPEOF[id] : "Unknown"
    if (name == "option.some" && AST[id,"nc"] >= 1) {
      t = "Option<" TYPEOF[AST[id,"c1"]] ">"
    } else if ((name,"ret") in SIG) {
      ret_sig = SIG[name,"ret"]
      if (ret_sig ~ /\<T\>/ && AST[id,"nc"] >= 1) {
        typearg = AST[AST[id,"c1"],"text"]
        gsub(/^"|"$/, "", typearg)
        t = ret_sig
        gsub(/\<T\>/, typearg, t)
      }
    }
  } else if (kind == "LET") {
    typeann_id = 0; expr_id = 0
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "TYPEANN") typeann_id = child
      else                                expr_id    = child
    }
    if (typeann_id != 0 && expr_id != 0) {
      ct = TYPEOF[expr_id]
      if (ct != "" && !v2_type_compat(AST[typeann_id,"text"], ct)) {
        v2_diag(AST[id,"line"], 1, "type mismatch: cannot assign " ct " to " AST[typeann_id,"text"])
      }
    }
    V2_ENV[AST[id,"text"]] = (typeann_id != 0) ? AST[typeann_id,"text"] : \
                              ((expr_id != 0 && TYPEOF[expr_id] != "") ? TYPEOF[expr_id] : "Unknown")
    t = ""
  } else if (kind == "LETQ") {
    typeann_id = 0; expr_id = 0
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "TYPEANN") typeann_id = child
      else                                expr_id    = child
    }
    v2_coalesce_type(id, typeann_id, expr_id)
    # 束縛型の導出前に Effect を剥がす（BH）。cache.get 等は
    # Effect<Result<Option<T>, E>> を返すため、strip 前の型を unwrap すると
    # Effect<...> のまま扱われ、後続の when...of が想定と異なる家系（Result
    # 扱い）になってしまう。
    V2_ENV[AST[id,"text"]] = (typeann_id != 0) ? AST[typeann_id,"text"] : \
                              v2_unwrap_type(v2_resolve_sealed(TYPEOF[expr_id]))
    t = ""
  } else if (kind == "RETURN") {
    if (AST[id,"nc"] >= 1) {
      ct = TYPEOF[AST[id,"c1"]]
      if (ct != "" && V2_CUR_FUNC_RET != "" && V2_CUR_FUNC_RET != "Unknown" && \
          !v2_type_compat(V2_CUR_FUNC_RET, ct)) {
        v2_diag(AST[id,"line"], 1, \
          "function " V2_CUR_FUNC_NAME " expects return " V2_CUR_FUNC_RET ", got " ct)
      }
    }
    t = ""
  }

  if (t != "") TYPEOF[id] = t
  return t
}

# ─── パス 3 補助: LETQ（?=）の型規則（Task 9） ───────────────────────

# t の Union 各要素が Option<...> / Result<...> のいずれかであれば真
function v2_is_nullable(t,    parts, n, i) {
  n = v2_split_union(t, parts)
  if (n < 1) return 0
  for (i = 1; i <= n; i++) {
    if (parts[i] !~ /^Option</ && parts[i] !~ /^Result</) return 0
  }
  return 1
}

# `let name [: Type] ?= expr` の RHS 型を検査する。
# RHS が Unknown なら検査しない（誤検出防止）。RHS が Option/Result でなければ
# エラー（dsl/desugar_let.awk の "?= requires Option or Result" 互換）。
# 型注釈があれば unwrap 後の型と比較する。
function v2_coalesce_type(id, typeann_id, expr_id,    ct, inner) {
  if (expr_id == 0) return
  ct = TYPEOF[expr_id]
  if (ct == "" || ct == "Unknown") return
  # `type MaybeStr = Option<Str>` のようなエイリアス越しの nullable も判定でき
  # るよう、Effect 剥がしとエイリアス展開を往復してから判定する（CC。v1 実測:
  # `let x ?= get()`（get(): MaybeStr）は誤 reject せず通る）。
  ct = v2_resolve_sealed(ct)
  if (!v2_is_nullable(ct)) {
    v2_diag(AST[id,"line"], 1, "?= requires Option or Result, got " ct)
    return
  }
  if (typeann_id == 0) return
  inner = v2_unwrap_type(ct)
  if (inner != "" && !v2_type_compat(AST[typeann_id,"text"], inner)) {
    v2_diag(AST[id,"line"], 1, "type mismatch: cannot assign " inner " to " AST[typeann_id,"text"])
  }
}

# ─── パス 4: when 網羅性検査（Task 9） ───────────────────────────────

# Result<T, E> の E 部分を取り出す。
# トップレベル（<...> の深さ 0）のカンマで T/E を分ける。`[^,]+` による単純分割だと
# `Result<Dict<Str, Int>, AuthError|NotFoundError>` のような T 側のネストした generic
# 内部のカンマで誤分割してしまうため、深さを追跡してトップレベルのカンマのみを探す。
function v2_result_err_part(t,    parts, n) {
  n = v2_result_parts(t, parts)
  if (n < 2) return ""
  return parts[2]
}

# WHEN ノードを再帰的に走査し、腕の網羅性を検査する。
# - 対象式が Unknown/未知型なら検査しない。
# - `_`/`default` 腕があれば免除。
# - ok/some 以外の腕（ng/none）が 1 つもなければ
#   "when...of missing ng/none/default branch"。
# - 対象式が Result<T, E1|E2> のように型付きエラー Union を持ち、
#   型付き ng 腕（`ng e<Type>:` / `ng <Type>:`）のみでカバーしている場合、
#   未カバーの E メンバーごとに "when...of missing arm for E (add '...' or 'default:')"。
function v2_check_when(id,    k, j, arm, pat, tag, typeann_id, \
                        target_id, ttype, is_result, catchall, ng_count, \
                        covered, err_part, members, nmem, i) {
  if (AST[id,"kind"] == "WHEN") {
    target_id = AST[id,"c1"]
    ttype = v2_resolve_sealed(TYPEOF[target_id])
    if (ttype != "" && ttype != "Unknown" && (ttype ~ /^Option</ || ttype ~ /^Result</)) {
      is_result = (ttype ~ /^Result</)
      catchall = 0
      ng_count = 0
      delete covered
      for (k = 2; k <= AST[id,"nc"]; k++) {
        arm = AST[id,"c" k]
        pat = AST[arm,"c1"]
        tag = AST[pat,"text"]
        typeann_id = 0
        for (j = 1; j <= AST[pat,"nc"]; j++) {
          if (AST[AST[pat,"c" j],"kind"] == "TYPEANN") typeann_id = AST[pat,"c" j]
        }
        if (tag == "_" || tag == "default") {
          catchall = 1
        } else if (tag == "none") {
          # none は Option 対象専用。Result 対象では家系違いとして
          # 網羅性カウントに含めない（無視する。AO）。
          if (!is_result) { ng_count++; catchall = 1 }
        } else if (tag == "ng") {
          # ng は Result 対象専用。Option 対象では家系違いとして無視する（AO）。
          if (is_result) {
            ng_count++
            if (typeann_id != 0) covered[AST[typeann_id,"text"]] = 1
            else                 catchall = 1
          }
        }
      }
      if (ng_count == 0 && !catchall) {
        v2_diag(AST[id,"line"], 1, "when...of missing ng/none/default branch")
      } else if (!catchall && is_result) {
        err_part = v2_result_err_part(ttype)
        if (err_part != "") {
          nmem = v2_split_union(err_part, members)
          if (nmem > 1) {
            for (i = 1; i <= nmem; i++) {
              if (!(members[i] in covered)) {
                v2_diag(AST[id,"line"], 1, \
                  "when...of missing arm for " members[i] " (add 'ng e<" members[i] ">:' or 'default:')")
              }
            }
          }
        }
      }
    }
  }

  for (k = 1; k <= AST[id,"nc"]; k++) v2_check_when(AST[id,"c" k])
}

# WHEN の腕を辿り、catch-all 腕（none:/無型 ng:/default:/_:）より後に ng/none/
# default 系の腕が続く場合を診断する（BV。v1 実測: dsl/desugar_match.awk の
# _ds_match_catchall_order_error と同文面 "catch-all arm must be last"）。
# v1 はこの検査を対象式の型を問わず構文レベルで行うため（typecheck 前の行走査）、
# v2_check_when の ttype 判定（Option/Result 既知のみ）とは独立に、全 WHEN で
# 検査する。ok/some 腕は v1 でも対象外（catchall フラグの確認・更新をしない）。
function v2_check_arm_order(id,    k, j, arm, pat, tag, typeann_id, catchall_seen) {
  if (AST[id,"kind"] == "WHEN") {
    catchall_seen = 0
    for (k = 2; k <= AST[id,"nc"]; k++) {
      arm = AST[id,"c" k]
      pat = AST[arm,"c1"]
      tag = AST[pat,"text"]
      if (tag == "ng" || tag == "none" || tag == "default" || tag == "_") {
        if (catchall_seen) {
          v2_diag(AST[arm,"line"], 1, "catch-all arm must be last")
        }
        typeann_id = 0
        for (j = 1; j <= AST[pat,"nc"]; j++) {
          if (AST[AST[pat,"c" j],"kind"] == "TYPEANN") typeann_id = AST[pat,"c" j]
        }
        if (tag == "none" || tag == "default" || tag == "_") catchall_seen = 1
        else if (tag == "ng" && typeann_id == 0)             catchall_seen = 1
      }
    }
  }

  for (k = 1; k <= AST[id,"nc"]; k++) v2_check_arm_order(AST[id,"c" k])
}

# ─── パス 5: CALL 引数の型検査（XSS ブランド型を含む、Task 9） ────────

# 補間の実引数テキスト 1 個の型を解決する（BW）。IDENT なら V2_ENV、call 形なら
# SIG の宣言戻り型（その call 自身の実引数は検査しない = 深さ 1 段で打ち切り。
# 過剰検出防止）、リテラルはリテラル型、それ以外は Unknown。
function v2_interp_atom_type(text,    m, name) {
  sub(/^[[:space:]]+/, "", text)
  sub(/[[:space:]]+$/, "", text)
  if (text ~ /^"([^"\\]|\\.)*"$/)          return "Str"
  if (text ~ /^-?[0-9]+\.[0-9]+$/)         return "Float"
  if (text ~ /^-?[0-9]+$/)                 return "Int"
  if (text == "true" || text == "false")   return "Bool"
  if (text == "null")                      return "Null"
  if (match(text, /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]*\(/, m)) {
    name = m[0]
    sub(/[[:space:]]*\($/, "", name)
    return ((name, "ret") in SIG) ? SIG[name, "ret"] : "Unknown"
  }
  if (text ~ /^[A-Za-z_][A-Za-z0-9_]*$/)   return (text in V2_ENV) ? V2_ENV[text] : "Unknown"
  return "Unknown"
}

# 文字列 s をトップレベル（丸括弧の深さ 0、ダブルクォート文字列の外）のカンマで
# 分割する（補間内 call 形の実引数リスト分割用。BW）。
function v2_split_toplevel_commas(s, out,    i, c, depth, in_str, cur, n) {
  n = 0; depth = 0; in_str = 0; cur = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (in_str) {
      cur = cur c
      if (c == "\\" && i < length(s)) { i++; cur = cur substr(s, i, 1) }
      else if (c == "\"") in_str = 0
      continue
    }
    if      (c == "\"") { in_str = 1; cur = cur c }
    else if (c == "(")  { depth++; cur = cur c }
    else if (c == ")")  { depth--; cur = cur c }
    else if (c == "," && depth == 0) { out[++n] = cur; cur = "" }
    else cur = cur c
  }
  sub(/^[[:space:]]+/, "", cur); sub(/[[:space:]]+$/, "", cur)
  if (cur != "") out[++n] = cur
  for (i = 1; i <= n; i++) { sub(/^[[:space:]]+/, "", out[i]); sub(/[[:space:]]+$/, "", out[i]) }
  return n
}

# #{ expr } 補間内の式テキストから、単純な CALL / DOT-CALL 形式（`recv.method(...)`
# または `fn(...)`）の戻り型を SIG[] から引く。判別できなければ Unknown を返す
# （v2_check_fragment_interp 側で Unknown は誤検出防止のため検査しない）。
# call 形の場合は実引数テキストも SIG の宣言引数型と照合する（BW）。補間テキスト
# は AST 子ノードにならず通常の CALL 引数検査（v2_check_brand）が届かないため
# （`safe.html.fragment("<p>#{safe.html.raw(raw)}</p>")` で内側の
# `safe.html.raw(raw)` の実引数が素通りしていた）、ここで同じ文面
# （"name argument N expects EXPECTED, got ACTUAL"）を診断する。
# Task 11（補間の構造化 AST）のスコープ外のため、ここではテキストスキャンで
# v1（dsl/desugar_strings.awk の _ds_interp_expr_type 相当）と同等の検出を行う。
function v2_infer_interp_expr_type(strlit_id, exprtext,    m, name, argstr, args, n, i, \
                                    atype, expected, arity, max_arity, open_pos, close_pos, \
                                    depth, c, trailing, call_ret, trail_type) {
  exprtext = exprtext
  sub(/^[[:space:]]+/, "", exprtext)
  sub(/[[:space:]]+$/, "", exprtext)
  if (match(exprtext, /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]*\(/, m)) {
    name = m[0]
    sub(/[[:space:]]*\($/, "", name)
    open_pos = length(m[0])
    # 深さ追跡で対応する閉じ ")" を探す（CO）。旧実装は末尾の ")" を機械的に
    # 1 個切り落とすだけだったため、call の直後に暗黙連結の式が続く場合
    # （`safe.html.escape(raw) raw` 等）に境界を誤認識し、末尾の式（brand
    # 検査が必要な Untrusted<Str> の可能性がある）を丸ごと argstr に取り込んで
    # 黙って捨てていた。
    depth = 1
    close_pos = 0
    for (i = open_pos + 1; i <= length(exprtext); i++) {
      c = substr(exprtext, i, 1)
      if (c == "(") depth++
      else if (c == ")") { depth--; if (depth == 0) { close_pos = i; break } }
    }
    if (close_pos == 0) close_pos = length(exprtext) + 1
    argstr = substr(exprtext, open_pos + 1, close_pos - open_pos - 1)
    trailing = substr(exprtext, close_pos + 1)
    sub(/^[[:space:]]+/, "", trailing)
    if ((name, "arity") in SIG) {
      arity = SIG[name, "arity"]
      n = v2_split_toplevel_commas(argstr, args)
      # 補間内 call は v2_check_calls の CALL ノード検査を迂回するため、
      # ここで同じ arity 検査を行う（引数の型検査ループとは独立に、まず
      # 個数が範囲外なら診断する。文面は v2_check_calls と同一形式。CN）。
      max_arity = ((name, "arity_max") in SIG) ? SIG[name, "arity_max"] : arity
      if (arity != -1 && (n < arity || n > max_arity)) {
        v2_diag(AST[strlit_id,"line"], 1, name " expects " arity " argument(s), got " n)
      }
      for (i = 1; i <= n; i++) {
        if ((name, "arg" i) in SIG)                    expected = SIG[name, "arg" i]
        else if (arity == -1 && (name, "arg1") in SIG)  expected = SIG[name, "arg1"]
        else                                            continue
        atype = v2_interp_atom_type(args[i])
        if (atype == "" || atype == "Unknown" || v2_type_compat(expected, atype)) continue
        v2_diag(AST[strlit_id,"line"], 1, name " argument " i " expects " expected ", got " atype)
      }
    }
    call_ret = ((name, "ret") in SIG) ? SIG[name, "ret"] : "Unknown"
    if (trailing == "") return call_ret
    # call の後ろに式が続く場合は awk の暗黙連結（CK）とみなし、同じ CONCAT
    # 型付け規則（brand 喪失 / Untrusted 伝播）を適用する。
    trail_type = v2_infer_interp_expr_type(strlit_id, trailing)
    return v2_binop_type("CONCAT", call_ret, trail_type, AST[strlit_id,"line"])
  }
  # 単純 IDENT（レシーバ・呼び出しなし）は V2_ENV から引く（BL: Untrusted 伝播判定に使う）。
  if (exprtext ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
    return (exprtext in V2_ENV) ? V2_ENV[exprtext] : "Unknown"
  }
  return "Unknown"
}

# STRLIT の #{ } 補間式それぞれの型を id 単位でキャッシュする（BM）。
# v2_infer の正順走査中（V2_ENV が現在の関数スコープに正しく充填された状態）
# に一度だけ呼び出す。STRLIT_INTERP_TYPE[id, n] / STRLIT_INTERP_COUNT[id] に
# 格納し、後段の v2_check_fragment_interp（型推論が終わった後の別パスから
# 呼ばれ、その時点では V2_ENV が最後に処理した関数のものに固定されている）が
# 再スキャンせずに済むようにする。
# 各補間式の型（Effect 剥がし後）が Option</Result< なら sealed 値の補間として
# 拒否する（BY。v1 実測: "cannot interpolate sealed <type>" と同文面。
# dsl/desugar_strings.awk 相当。unwrap しないまま埋め込むと `?=`/`when...of` の
# 強制 unwrap を迂回できてしまうため）。
function v2_cache_strlit_interp_types(id, text,    rest, m, exprtext, t, adv, n, ct) {
  rest = text
  n = 0
  while (match(rest, /#\{([^}]*)\}/, m)) {
    adv = RSTART + RLENGTH
    exprtext = m[1]
    t = v2_infer_interp_expr_type(id, exprtext)
    if (t != "" && t != "Unknown") {
      ct = v2_resolve_sealed(t)
      if (v2_is_nullable(ct)) v2_diag(AST[id,"line"], 1, "cannot interpolate sealed " ct)
    }
    n++
    STRLIT_INTERP_TYPE[id, n] = t
    rest = substr(rest, adv)
  }
  STRLIT_INTERP_COUNT[id] = n
}

# id（STRLIT ノード）の #{ } 補間のいずれかの型が Untrusted<...> なら真を返す
# （BL）。v2_cache_strlit_interp_types 呼び出し後のキャッシュを読むだけ（BM）。
function v2_strlit_has_untrusted_interp(id,    i, n) {
  n = (id in STRLIT_INTERP_COUNT) ? STRLIT_INTERP_COUNT[id] : 0
  for (i = 1; i <= n; i++) {
    if (STRLIT_INTERP_TYPE[id, i] ~ /^Untrusted</) return 1
  }
  return 0
}

# safe.html.fragment の文字列引数中の #{ expr } 補間を走査し、各式の型を
# HtmlPart（HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr）と照合する
# （AM: dsl/desugar_strings.awk の _ds_expand_fragment_interp 互換）。
# strlit_id の型は v2_cache_strlit_interp_types が v2_infer 内で（正しい
# V2_ENV スコープのもとで）キャッシュ済みのものを使う（BM）。
function v2_check_fragment_interp(call_id, strlit_id,    i, n, t) {
  n = (strlit_id in STRLIT_INTERP_COUNT) ? STRLIT_INTERP_COUNT[strlit_id] : 0
  for (i = 1; i <= n; i++) {
    t = STRLIT_INTERP_TYPE[strlit_id, i]
    if (t != "" && t != "Unknown" && \
        !v2_type_compat("HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr", t)) {
      v2_diag(AST[call_id,"line"], 1, \
        "safe.html.fragment interpolation expects HtmlPart, got " t)
    }
  }
}

# CALL の 1 引数を SIG["name","argN"] と照合し、不一致なら診断する。
# safe.html.fragment への文字列リテラル引数は静的 HTML として常に許容するが、
# 補間 #{ } を含む場合は動的 HTML なので免除せず、埋め込み式を検査する（AM）。
function v2_check_brand_arg(call_id, name, argidx, expected, child,    actual, text, cls, inner) {
  if (name == "safe.html.fragment" && AST[child,"kind"] == "STRLIT") {
    text = AST[child,"text"]
    if (index(text, "#{") == 0) return
    v2_check_fragment_interp(call_id, child)
    return
  }
  actual = ((child) in TYPEOF) ? TYPEOF[child] : ""
  if (actual == "" || v2_type_compat(expected, actual)) return
  # classify: transform/validator/sanitizer は docs/dsl.md の規定どおり
  # Untrusted<T> 入力を受容する（CA）。宣言引数型そのものは素の T のままでよく、
  # 呼び出し側の Untrusted<T> 実引数だけを classify で免除する。
  if (actual ~ /^Untrusted</ && (name, "classify") in SIG) {
    cls = SIG[name, "classify"]
    if (cls == "transform" || cls == "validator" || cls == "sanitizer") {
      inner = actual
      sub(/^Untrusted</, "", inner); sub(/>$/, "", inner)
      if (v2_type_compat(expected, inner)) return
    }
  }
  v2_diag(AST[call_id,"line"], 1, name " argument " argidx " expects " expected ", got " actual)
}

# PIPE ノードの規則を検査する（dsl.md:336/:338、BB+BC）。
# - RHS（c2）は CALL でなければならない（`expr |> f(args)`）。BC。
# - LHS（c1）の型（Effect 剥がし・エイリアス展開後）が Result</Option< なら
#   sealed 値の直接 pipe は禁止（`?=` か when...of で unwrap してから）。
#   v1 実測文面に合わせる（dsl/desugar_pipe.awk: "pipe input is <type>"）。BB。
#   `type R = Result<...>` のようなエイリアス越しの sealed 値も同様に拒否する
#   （BZ。エイリアス展開前の literal prefix しか見ていないと素通りしていた）。
function v2_check_pipe_rules(id,    lhs_id, rhs_id, lt) {
  lhs_id = AST[id,"c1"]
  rhs_id = AST[id,"c2"]
  if (AST[rhs_id,"kind"] != "CALL") {
    v2_diag(AST[id,"line"], 1, "pipe right-hand side must be a call (`expr |> f(args)`)")
    return
  }
  lt = ((lhs_id) in TYPEOF) ? TYPEOF[lhs_id] : ""
  if (lt == "" || lt == "Unknown") return
  lt = v2_resolve_sealed(lt)
  if (lt ~ /^Result</ || lt ~ /^Option</) {
    v2_diag(AST[id,"line"], 1, "pipe input is " lt)
  }
}

# CALL ノードを再帰的に走査し、実引数の型を SIG["name","argN"] と照合する。
# PIPE の RHS にある CALL は v2_check_calls と同様に extra で引数位置をずらす
# （明示引数側）。PIPE 左辺の暗黙 arg1（c1）自体も CALL の子ではないため、
# PIPE ノード側で別途 argidx=1 として検査する。
function v2_check_brand(id, extra,    k, name, arity, argidx, expected, child, child_extra, callee) {
  if (AST[id,"kind"] == "CALL") {
    name = AST[id,"text"]
    if ((name,"arity") in SIG) {
      arity = SIG[name,"arity"]
      for (k = 1; k <= AST[id,"nc"]; k++) {
        child  = AST[id,"c" k]
        argidx = k + extra
        if ((name, "arg" argidx) in SIG) {
          expected = SIG[name, "arg" argidx]
        } else if (arity == -1 && (name, "arg1") in SIG) {
          expected = SIG[name, "arg1"]
        } else {
          continue
        }
        v2_check_brand_arg(id, name, argidx, expected, child)
      }
    }
  } else if (AST[id,"kind"] == "PIPE") {
    v2_check_pipe_rules(id)
    callee = AST[id,"c2"]
    if (AST[callee,"kind"] == "CALL") {
      name = AST[callee,"text"]
      if ((name, "arg1") in SIG) {
        v2_check_brand_arg(callee, name, 1, SIG[name, "arg1"], AST[id,"c1"])
      }
    }
  }

  for (k = 1; k <= AST[id,"nc"]; k++) {
    child_extra = (AST[id,"kind"] == "PIPE" && k == 2) ? 1 : 0
    v2_check_brand(AST[id,"c" k], child_extra)
  }
}

# ─── エントリポイント ─────────────────────────────────────────────

function v2_check() {
  v2_init_builtins()
  VARIANTS["Result"] = "ok" SUBSEP "ng"
  VARIANTS["Option"]  = "some" SUBSEP "none"

  v2_collect(1)
  v2_check_alias_cycles()
  v2_check_toplevel_let()
  v2_check_calls(1, 0)
  v2_infer(1)
  v2_check_when(1)
  v2_check_arm_order(1)
  v2_check_brand(1, 0)
}

# 関数外（PROGRAM 直下）の LET/LETQ を拒否する（CF。v1 実測:
# dsl/typecheck.awk・libexec/hawk-check で top-level `let x: Int = 1` /
# `let x ?= ...` いずれも "'let' outside function body" で reject）。
# PROGRAM の直接の子だけを見ればよい（FUNC 内の LET は FUNC の子として現れ、
# PROGRAM の子には出てこない）。
function v2_check_toplevel_let(    k, child) {
  for (k = 1; k <= AST[1,"nc"]; k++) {
    child = AST[1,"c" k]
    if (AST[child,"kind"] == "LET" || AST[child,"kind"] == "LETQ") {
      v2_diag(AST[child,"line"], 1, "'let' outside function body")
    }
  }
}

# ─── パス 1.5: type エイリアス循環検出（BR） ─────────────────────────
# v1（dsl/type.awk:_type_check_alias_cycle）の visited-set DFS 実測互換。
# v1 は pass1a（forward reference 収集）で全エイリアスを集めてから、宣言順に
# 1 件ずつ visiting セットをリセットして辿る。v2_collect も ALIAS[] をファイル
# 全体分そろえてから（本関数は v2_collect の直後に呼ぶ）、宣言順に同じ DFS を
# 行う。

# name から辿って visiting に既出なら "type alias cycle detected involving
# 'name'" を診断する（v1 実測文面と一致）。
function v2_check_alias_cycle(name, lineno, visiting,    target, parts, n, i) {
  if (!(name in ALIAS)) return
  if (name in visiting) {
    v2_diag(lineno, 1, "type alias cycle detected involving '" name "'")
    return
  }
  visiting[name] = 1
  target = ALIAS[name]
  n = v2_split_union(target, parts)
  for (i = 1; i <= n; i++) {
    if (parts[i] in ALIAS) v2_check_alias_cycle(parts[i], lineno, visiting)
  }
  delete visiting[name]
}

function v2_check_alias_cycles(    i, name, visiting) {
  for (i = 1; i <= ALIAS_DECL_N; i++) {
    name = ALIAS_DECL_ORDER[i]
    delete visiting
    v2_check_alias_cycle(name, ALIAS_DECL_LINE[name], visiting)
  }
}
