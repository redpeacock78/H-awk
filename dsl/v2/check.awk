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

# 型 t の union member を再帰的に走査し、pat（正規表現文字列）に prefix
# 一致する展開後の型を最初の 1 件返す（無ければ空文字）。member 自体が
# エイリアスの場合は v2_resolve_sealed で展開し、展開結果が元と異なるとき
# （＝エイリアスだった）は展開結果を union として再分割し再帰的に判定する。
# これはエイリアス展開結果自体が union になるケース（`type U =
# Str|Untrusted<Str>` 等）で prefix 照合が先頭 member しか見ず後続 member の
# Untrusted</Result</Option< を見逃す問題への対応（review DW）。展開結果が
# 元と同じ（＝エイリアスでない、または循環で解決不能）場合のみ従来どおり
# prefix 照合する。展開結果が intersection（`&`）を含む場合は
# v2_split_intersection で分割し各 member を再帰判定する（`type X = Tag &
# Untrusted<Str>` のように intersection 越しに隠れた sealed 型を見逃していた
# 問題への対応。review EG）。depth は循環防止のガード（最大 16）。
function v2_find_sealed_member(t, pat, depth,    parts, n, i, resolved, found, iparts, ni, j) {
  if (depth >= 16) return ""
  n = v2_split_union(t, parts)
  for (i = 1; i <= n; i++) {
    resolved = v2_resolve_sealed(parts[i])
    ni = v2_split_intersection(resolved, iparts)
    if (ni > 1) {
      for (j = 1; j <= ni; j++) {
        if ((found = v2_find_sealed_member(iparts[j], pat, depth + 1)) != "") return found
      }
    } else if (resolved == parts[i]) {
      if (resolved ~ pat) return resolved
    } else if ((found = v2_find_sealed_member(resolved, pat, depth + 1)) != "") {
      return found
    }
  }
  return ""
}

# 型 t のいずれかの union member が Untrusted<...>（エイリアス越しを含む）
# なら真を返す（v2_find_sealed_member 参照。DK/DL/DV から呼ばれる）。
function v2_type_has_untrusted_member(t) {
  return (v2_find_sealed_member(t, "^Untrusted<", 0) != "") ? 1 : 0
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
                         eg, ag, egn, agn, egargs, agargs, matched, ein, eiparts) {
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

  # 期待型が intersection（`&`）なら、全 member を actual が満たすことを
  # 要求する（review ER。旧実装は `Str & Any` のような intersection を
  # 不透明な 1 個の文字列として比較し、Str の代入すら誤 reject していた）。
  ein = v2_split_intersection(expected, eiparts)
  if (ein > 1) {
    for (i = 1; i <= ein; i++) if (!v2_type_compat(eiparts[i], actual)) return 0
    return 1
  }

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
  # Untrusted<Str> を伝播する。union の場合は member 単位で判定する。DK/DL）。
  if (op == "CONCAT") return (v2_type_has_untrusted_member(lt) || v2_type_has_untrusted_member(rt)) ? "Untrusted<Str>" : "Str"

  is_num_op = (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "^")
  if (is_num_op) {
    # オペランドがエイリアス越し（`type Count = Int`）だと literal Int/Float
    # と直接比較しても一致せず誤 reject するため、展開してから比較する（DI）。
    # オペランドがエイリアス越し（`type Count = Int`）だと literal Int/Float
    # と直接比較しても一致せず誤 reject するため、展開してから比較する（DI）。
    lt = v2_expand_alias(lt)
    rt = v2_expand_alias(rt)
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
  # キー型もエイリアス越し（`type Key = Int`）だと literal Int/Str と直接
  # 比較しても一致せず誤 reject するため、展開してから比較する（DH）。
  key_type    = v2_resolve_sealed(TYPEOF[AST[id,"c2"]])
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
  # Effect 剥がしのみだとエイリアス越しの sealed 型（`type MaybeStr =
  # Option<Str>`）の束縛導出で MaybeStr のまま残り、`-> Str` 関数の
  # `return v` が誤って型不一致になる（DD）。v2_check_when の網羅性判定
  # （line 801）と同じ v2_resolve_sealed で揃える。
  ttype = v2_resolve_sealed(TYPEOF[AST[id,"c1"]])

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
    # 小数点があれば Float。指数部（1e-2 等）のみで小数点が無い場合も、
    # 指数が負なら真値が非整数になるため Float とする（DO）。指数が非負
    # （1e3 等）なら真値は整数なので Int のまま（CM の既存 fixture
    # check_exponent_type と同じ判断）。
    # v1 実測: dsl/desugar_let.awk:_ds_infer_type の Int/Float 判定正規表現は
    # どちらも指数部付きリテラルにマッチせず、指数の符号に関係なく推論結果
    # "" のまま型検査自体をスキップする（`let x: Int = 1e3` も
    # `let x: Float = 1e3` も同様に無検査で通る）。v1 に Int/Float の
    # 区別が無いため、v2 では真値が非整数になる場合に限り Float とする。
    if (AST[id,"text"] ~ /\./)        t = "Float"
    else if (AST[id,"text"] ~ /[eE]-/) t = "Float"
    else                               t = "Int"
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
    # classify: transform の関数へ pipe すると、入力が Untrusted<T> のとき
    # 結果も Untrusted<戻り型> になる（v1 の dsl/type_dataflow.awk:
    # _ds_dataflow_ret と同じ規則。CW）。v1 実測: `let raw: Untrusted<Str> = x`
    # のように明示的に型付けた変数を classify: transform の関数へ pipe すると
    # 結果は Untrusted<Str> のまま伝播し、素の Str を要求する呼び出しへ渡すと
    # 拒否される。実測では validator は宣言戻り型が Untrusted<...> のときそれを
    # 常に剥がして返す（入力の trust 状態に関係なく）、sanitizer は宣言戻り型を
    # そのまま返す（そもそも Untrusted を含まない宣言のため実質的に除去）。
    # 実測範囲外の直接呼び出し（pipe を使わない `strip(raw)` 形）は v1 が
    # このルールを適用しないことを確認済みのため、ここでも PIPE の場合のみ
    # 適用する（報告書に記載）。
    if (AST[rhs_id,"kind"] == "CALL" && (AST[rhs_id,"text"],"classify") in SIG) {
      t = v2_dataflow_ret(AST[rhs_id,"text"], TYPEOF[AST[id,"c1"]], t)
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

# t の Union 各要素が Option<...> / Result<...> のいずれかであれば真。
# member 自体がエイリアス（`type O = Option<Str>` 等）の場合は
# v2_resolve_sealed で展開してから判定する（review EO。旧実装は未展開の
# エイリアス名をそのまま prefix 照合していたため、`type O = Option<Str>` +
# `type R = Result<Str, E>` の union `O|R` を `?= requires Option or
# Result` で誤 reject していた）。
function v2_is_nullable(t,    parts, n, i, resolved) {
  n = v2_split_union(t, parts)
  if (n < 1) return 0
  for (i = 1; i <= n; i++) {
    resolved = v2_resolve_sealed(parts[i])
    if (resolved !~ /^Option</ && resolved !~ /^Result</) return 0
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
        # エラー型パラメータがユーザー定義エイリアス（`type Errors =
        # AuthError|NotFoundError`）のとき、展開前の "Errors" のまま
        # v2_split_union に渡すと nmem が 1 のままになり、union に隠れた
        # 各エラー型への missing-arm 検査が働かない（DQ。wave 11 CZ の
        # 「真に単一のエラー型なら nmem==1 skip は v1 互換」とは別の
        # ケース: こちらはエイリアス未展開による誤った nmem==1）。
        err_part = v2_expand_alias(v2_result_err_part(ttype))
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

# v1 dsl/type_dataflow.awk:_ds_dataflow_ret と同じ規則で pipe の戻り型を
# 求める（CW）。classify に応じて:
#   - validator: 宣言戻り型が Untrusted<...> なら常に剥がして返す
#     （入力の trust 状態に関係なく、検証済みとして扱う）
#   - transform: 入力（input_type）が Untrusted<...> なら宣言戻り型を
#     Untrusted<...> で包んで返す（Untrusted を伝播）
#   - それ以外（sanitizer 等）: 宣言戻り型をそのまま返す
function v2_dataflow_ret(name, input_type, decl_ret,    cls, ret) {
  cls = ((name, "classify") in SIG) ? SIG[name, "classify"] : ""
  ret = decl_ret
  if (cls == "validator" && ret ~ /^Untrusted</) {
    sub(/^Untrusted</, "", ret); sub(/>$/, "", ret)
  }
  # input_type がエイリアス（`type U = Untrusted<Str>` 等、union 展開結果を
  # 含む）だと未展開テキストへの prefix 照合が一致せず、transform を経由
  # した Untrusted 伝播が握り潰される（review C1 / XSS バイパス）。DW の
  # member 再分割ヘルパで展開後の Untrusted<...> を探してから判定する。
  if (cls == "transform" && v2_find_sealed_member(input_type, "^Untrusted<", 0) != "") return "Untrusted<" ret ">"
  return ret
}

# text 中の '(' 位置 open_pos（開き括弧そのものの直後、すなわち引数列の
# 先頭位置）に対応する閉じ ')' の位置を、深さ追跡で求める（CO/DB 共用）。
# 対応する閉じ括弧が見つからなければ text の末尾+1（=全体を argstr とみなす）
# を返す。呼び出し元は open_pos に「call 名 + '(' までの長さ」（m[0] の長さ）
# を渡す想定。
function v2_match_call_close(text, open_pos,    i, c, depth, close_pos) {
  depth = 1
  close_pos = 0
  for (i = open_pos + 1; i <= length(text); i++) {
    c = substr(text, i, 1)
    if (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) { close_pos = i; break } }
  }
  if (close_pos == 0) close_pos = length(text) + 1
  return close_pos
}

# text[pos] を '<' として、深さを追跡して対応する '>' まで走査する（DU）。
# V2_INTERP_GENERIC_ARG に中身を格納し、'>' の次の位置を返す。閉じなければ
# 0 を返し、呼び出し側で generic ではない（比較演算子の '<'）とみなす。
function v2_interp_scan_generic(text, pos,    i, c, depth, start) {
  start = pos + 1
  depth = 1
  for (i = start; i <= length(text); i++) {
    c = substr(text, i, 1)
    if (c == "<") depth++
    else if (c == ">") {
      depth--
      if (depth == 0) { V2_INTERP_GENERIC_ARG = substr(text, start, i - start); return i + 1 }
    }
  }
  V2_INTERP_GENERIC_ARG = ""
  return 0
}

# text の先頭が `name(...)` / `name<T>(...)`（dotted 名も可）のいずれかの
# call 形かどうかを判定する（DU: 補間内 call 認識に generic 形を追加。
# 非 generic 判定（CN/DB）と同じ「先頭一致 + 深さ追跡」の型に揃える）。
# 一致すれば 1 を返し、以下のグローバルに結果を格納する:
#   V2_INTERP_CALL_NAME    SIG 照合名（generic なら "_t" 接尾。rpn.awk の
#                          f<T>(...) -> f_t("T", ...) 正規化と同じ規約）
#   V2_INTERP_CALL_GENERIC generic 型引数のテキスト（generic でなければ ""）
#   V2_INTERP_CALL_OPEN    "(" の位置（v2_match_call_close にそのまま渡せる）
function v2_interp_match_call_head(text,    name, pos) {
  if (!match(text, /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/)) return 0
  name = substr(text, RSTART, RLENGTH)
  pos = RSTART + RLENGTH
  V2_INTERP_CALL_GENERIC = ""
  if (substr(text, pos, 1) == "<") {
    pos = v2_interp_scan_generic(text, pos)
    if (pos == 0) return 0
    name = name "_t"
    V2_INTERP_CALL_GENERIC = V2_INTERP_GENERIC_ARG
  }
  while (substr(text, pos, 1) ~ /[[:space:]]/) pos++
  if (substr(text, pos, 1) != "(") return 0
  V2_INTERP_CALL_NAME = name
  V2_INTERP_CALL_OPEN = pos
  return 1
}

# text 中の先頭の、丸括弧の深さ 0・文字列リテラル外にある "|>" の位置
# （'|' の位置）を返す（CT。補間式内の pipe 検出用）。見つからなければ 0。
function v2_find_toplevel_pipe(text,    i, c, depth, in_str) {
  depth = 0; in_str = 0
  for (i = 1; i <= length(text); i++) {
    c = substr(text, i, 1)
    if (in_str) {
      if (c == "\\") { i++; continue }
      if (c == "\"") in_str = 0
      continue
    }
    if (c == "\"") { in_str = 1; continue }
    else if (c == "(") depth++
    else if (c == ")") depth--
    else if (c == "|" && depth == 0 && substr(text, i + 1, 1) == ">") return i
  }
  return 0
}

# 補間の実引数テキスト 1 個の型を解決する（BW）。IDENT なら V2_ENV、call 形なら
# SIG の宣言戻り型（その call 自身の実引数は検査しない = 深さ 1 段で打ち切り。
# 過剰検出防止）、リテラルはリテラル型、それ以外は Unknown。
# call がテキスト全体を消費しない場合（call の直後に式が続く暗黙連結。CK）は
# CO と同じ規則で末尾式を CONCAT 型付けする（DB。旧実装は call 名 prefix
# だけを見て残りを丸ごと無視していたため、実引数内部の
# `safe.str.trust(raw) raw` のような形で末尾の未エスケープ式が握り潰されていた）。
function v2_interp_atom_type(text, line,    m, name, argstr, args, n, i, atype, \
                              expected, arity, max_arity, open_pos, close_pos, \
                              trailing, call_ret, trail_type, uref, genarg) {
  sub(/^[[:space:]]+/, "", text)
  sub(/[[:space:]]+$/, "", text)
  if (text ~ /^"([^"\\]|\\.)*"$/)          return "Str"
  if (text ~ /^-?[0-9]+\.[0-9]+$/)         return "Float"
  if (text ~ /^-?[0-9]+$/)                 return "Int"
  if (text == "true" || text == "false")   return "Bool"
  if (text == "null")                      return "Null"
  # トップレベル補間スキャナ（v2_interp_match_call_head）と同じ「name(...)
  # / name<T>(...)」判定を使う（review EK。旧実装は独自の非 generic 専用
  # 正規表現を持っていたため、`json.decode<Int>(body)` のようなネスト引数中
  # の generic call を認識できず、sealed 戻り型（Result 等）が Unknown に
  # 落ちて後続の sealed 検査を素通りしていた）。
  if (v2_interp_match_call_head(text)) {
    name    = V2_INTERP_CALL_NAME
    genarg  = V2_INTERP_CALL_GENERIC
    open_pos = V2_INTERP_CALL_OPEN
    close_pos = v2_match_call_close(text, open_pos)
    # 補間実引数がネストした CALL のとき、そのネスト call 自体の arity・
    # 引数型検査は v2_check_calls の CALL ノード走査を経由しないため、
    # ここで v2_infer_interp_expr_type の CALL 分岐と同じ検査を行う
    # （DN。旧実装は宣言戻り型を返すだけでネスト呼び出しの検査を素通り
    # させていた）。
    argstr = substr(text, open_pos + 1, close_pos - open_pos - 1)
    if ((name, "arity") in SIG) {
      arity = SIG[name, "arity"]
      n = v2_split_toplevel_commas(argstr, args)
      # generic call（DU と同じ規則）は型引数を第 1 引数の文字列として
      # 先頭に注入してから既存の arity・引数型検査に乗せる。
      if (genarg != "") {
        for (i = n; i >= 1; i--) args[i + 1] = args[i]
        args[1] = "\"" genarg "\""
        n++
      }
      max_arity = ((name, "arity_max") in SIG) ? SIG[name, "arity_max"] : arity
      if (arity != -1 && (n < arity || n > max_arity)) {
        v2_diag(line, 1, name " expects " arity " argument(s), got " n)
      }
      for (i = 1; i <= n; i++) {
        if ((name, "arg" i) in SIG)                    expected = SIG[name, "arg" i]
        else if (arity == -1 && (name, "arg1") in SIG)  expected = SIG[name, "arg1"]
        else                                            continue
        atype = v2_interp_atom_type(args[i], line)
        if (atype == "" || atype == "Unknown" || v2_type_compat(expected, atype)) continue
        v2_diag(line, 1, name " argument " i " expects " expected ", got " atype)
      }
    } else if (name ~ /_t$/) {
      # SIG 未登録の generic dispatch（トップレベル分岐と同じ扱い。BJ 相当）。
      v2_diag(line, 1, "unknown generic dispatch: " name)
      return "Unknown"
    }
    call_ret = ((name, "ret") in SIG) ? SIG[name, "ret"] : "Unknown"
    if (genarg != "" && call_ret ~ /\<T\>/) gsub(/\<T\>/, genarg, call_ret)
    trailing = substr(text, close_pos + 1)
    sub(/^[[:space:]]+/, "", trailing); sub(/[[:space:]]+$/, "", trailing)
    if (trailing == "") return call_ret
    trail_type = v2_interp_atom_type(trailing, line)
    return v2_binop_type("CONCAT", call_ret, trail_type, 0)
  }
  if (text ~ /^[A-Za-z_][A-Za-z0-9_]*$/)   return (text in V2_ENV) ? V2_ENV[text] : "Unknown"
  # リテラル・識別子・認識可能な call のいずれでもない形（`raw ""` の
  # concat 等）は Unknown に落ちる前に、v2_infer_interp_expr_type の DV
  # フォールバックと同じ規則を適用する（review DY。旧実装は補間実引数の
  # 型付けヘルパにこのフォールバックが効いておらず、実引数の Untrusted
  # 参照を見逃していた）。
  uref = v2_interp_text_has_untrusted_ref(text)
  if (uref != "") return uref
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
                                    depth, c, trailing, call_ret, trail_type, \
                                    pipe_pos, lhs_text, rhs_text, lhs_type, rname, r_argstr, \
                                    expected1, ok, cls, inner, genarg, uref, mt) {
  exprtext = exprtext
  sub(/^[[:space:]]+/, "", exprtext)
  sub(/[[:space:]]+$/, "", exprtext)
  # 数値・文字列リテラル単体の補間式（`#{123}` 等）はここで型を確定させる
  # （review DZ。旧実装は裸 IDENT・call・pipe のいずれにもマッチせず Unknown
  # に落ち、v2_check_fragment_interp の HtmlPart 検査をスキップしていた）。
  # 指数表記の Int/Float 判定は NUMLIT の推論規則（DO）と同一にする。
  if (exprtext ~ /^"([^"\\]|\\.)*"$/) return "Str"
  if (exprtext ~ /^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) {
    if (exprtext ~ /\./) return "Float"
    if (exprtext ~ /[eE]-/) return "Float"
    return "Int"
  }
  # `expr |> callee(args)` 形式（CT）。#{ } 補間内でも pipe 経由の sanitizer
  # 迂回を検出できるよう、既存の AST 側 PIPE 検査（AK/BB/BC）と同じ規則
  # （LHS 型を callee の arg1 として照合し、結果は callee 戻り型）を
  # テキストスキャンで適用する。安全側で単一段の pipe のみ対応する
  # （複数段連鎖 `a |> f() |> g()` は最初の |> で分割されるため、rhs_text
  # 側に残った次段の |> は callee 呼び出しの CALL 判定にマッチせず
  # Unknown 扱いになる。Task 11 の補間構造化 AST 移行までのスコープ外）。
  pipe_pos = v2_find_toplevel_pipe(exprtext)
  if (pipe_pos > 0) {
    lhs_text = substr(exprtext, 1, pipe_pos - 1)
    rhs_text = substr(exprtext, pipe_pos + 2)
    sub(/[[:space:]]+$/, "", lhs_text)
    sub(/^[[:space:]]+/, "", rhs_text)
    lhs_type = v2_infer_interp_expr_type(strlit_id, lhs_text)
    # 通常 pipe と同じ sealed 入力検査（v2_check_pipe_rules 相当）を補間内
    # pipe にも適用する（review EF。旧実装は LHS を callee の arg1 として
    # しか検査しておらず、RHS が Any を受ける場合に Result/Option がそのまま
    # 通ってしまっていた）。診断文言は v2_check_pipe_rules と同一。
    mt = v2_find_sealed_member(lhs_type, "^(Result|Option)<", 0)
    if (mt != "") v2_diag(AST[strlit_id,"line"], 1, "pipe input is " mt)
    if (v2_interp_match_call_head(rhs_text)) {
      rname     = V2_INTERP_CALL_NAME
      close_pos = v2_match_call_close(rhs_text, V2_INTERP_CALL_OPEN)
      r_argstr  = substr(rhs_text, V2_INTERP_CALL_OPEN + 1, close_pos - V2_INTERP_CALL_OPEN - 1)
      if ((rname, "arg1") in SIG && lhs_type != "" && lhs_type != "Unknown") {
        expected1 = SIG[rname, "arg1"]
        ok = v2_type_compat(expected1, lhs_type)
        # classify: transform/validator/sanitizer は Untrusted<T> 入力を
        # 受容する（CA と同じ規則。v2_check_brand_arg 相当）。lhs_type が
        # エイリアス（union 展開結果を含む）の場合は未展開テキストへの
        # prefix 照合が一致せず免除されない非対称があったため、EE と同じ
        # v2_find_sealed_member で展開後の Untrusted<...> を探してから
        # 判定する（review I1。v2_check_brand_arg 側は EE で対応済みだが、
        # 補間 pipe のこの call site は独立実装のため同じ穴が残っていた）。
        if (!ok && (rname, "classify") in SIG) {
          mt = v2_find_sealed_member(lhs_type, "^Untrusted<", 0)
          if (mt != "") {
            cls = SIG[rname, "classify"]
            if (cls == "transform" || cls == "validator" || cls == "sanitizer") {
              inner = mt
              sub(/^Untrusted</, "", inner); sub(/>$/, "", inner)
              if (v2_type_compat(expected1, inner)) ok = 1
            }
          }
        }
        if (!ok) v2_diag(AST[strlit_id,"line"], 1, rname " argument 1 expects " expected1 ", got " lhs_type)
      }
      # RHS の明示引数（LHS を arg1 として数えた実効 arity）も検査する
      # （既存 AST 側 PIPE 検査 = V と同じ規則・同じ文面。DP。旧実装は
      # LHS の arg1 照合だけで、RHS 側の明示引数の個数・型を一切見て
      # いなかった）。
      if ((rname, "arity") in SIG) {
        arity = SIG[rname, "arity"]
        max_arity = ((rname, "arity_max") in SIG) ? SIG[rname, "arity_max"] : arity
        n = v2_split_toplevel_commas(r_argstr, args) + 1   # LHS 分を +1
        if (arity != -1 && (n < arity || n > max_arity)) {
          v2_diag(AST[strlit_id,"line"], 1, rname " expects " arity " argument(s), got " n)
        }
        for (i = 1; i <= n - 1; i++) {
          if (!((rname, "arg" (i + 1)) in SIG)) continue
          expected = SIG[rname, "arg" (i + 1)]
          atype = v2_interp_atom_type(args[i], AST[strlit_id,"line"])
          if (atype == "" || atype == "Unknown" || v2_type_compat(expected, atype)) continue
          v2_diag(AST[strlit_id,"line"], 1, rname " argument " (i + 1) " expects " expected ", got " atype)
        }
      }
      call_ret = ((rname, "ret") in SIG) ? SIG[rname, "ret"] : "Unknown"
      # classify: transform/validator は通常 PIPE と同じ dataflow 規則
      # （v2_dataflow_ret、CW）を適用する（review DX。旧実装は callee の
      # 宣言戻り型をそのまま返しており、transform に Untrusted 入力を
      # 通しても戻り値の Untrusted<...> が保存されなかった）。
      if ((rname, "classify") in SIG) call_ret = v2_dataflow_ret(rname, lhs_type, call_ret)
      # RHS call の閉じ括弧より後に残るテキストを非 pipe call 経路（下の
      # v2_interp_match_call_head 分岐）と同じ CONCAT 規則で検査する
      # （review EN。旧実装は call を型付けして即 return するだけで、
      # `"#{raw |> safe.html.escape() raw}"` のように後続の暗黙連結が
      # 未エスケープの Untrusted 値を持ち込むケースを見逃していた）。
      trailing = substr(rhs_text, close_pos + 1)
      sub(/^[[:space:]]+/, "", trailing)
      if (trailing == "") return call_ret
      trail_type = v2_infer_interp_expr_type(strlit_id, trailing)
      return v2_binop_type("CONCAT", call_ret, trail_type, AST[strlit_id,"line"])
    }
    return "Unknown"
  }
  if (v2_interp_match_call_head(exprtext)) {
    name    = V2_INTERP_CALL_NAME
    genarg  = V2_INTERP_CALL_GENERIC
    # 深さ追跡で対応する閉じ ")" を探す（CO。v2_match_call_close に関数化して
    # v2_interp_atom_type と共用する。DB）。旧実装は末尾の ")" を機械的に
    # 1 個切り落とすだけだったため、call の直後に暗黙連結の式が続く場合
    # （`safe.html.escape(raw) raw` 等）に境界を誤認識し、末尾の式（brand
    # 検査が必要な Untrusted<Str> の可能性がある）を丸ごと argstr に取り込んで
    # 黙って捨てていた。
    close_pos = v2_match_call_close(exprtext, V2_INTERP_CALL_OPEN)
    argstr = substr(exprtext, V2_INTERP_CALL_OPEN + 1, close_pos - V2_INTERP_CALL_OPEN - 1)
    trailing = substr(exprtext, close_pos + 1)
    sub(/^[[:space:]]+/, "", trailing)
    if ((name, "arity") in SIG) {
      arity = SIG[name, "arity"]
      n = v2_split_toplevel_commas(argstr, args)
      # generic call（DU）は rpn.awk の f<T>(...) -> f_t("T", ...) 正規化と
      # 同じく、型引数を第 1 引数の文字列として先頭に注入してから既存の
      # arity・引数型検査に乗せる。
      if (genarg != "") {
        for (i = n; i >= 1; i--) args[i + 1] = args[i]
        args[1] = "\"" genarg "\""
        n++
      }
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
        atype = v2_interp_atom_type(args[i], AST[strlit_id,"line"])
        if (atype == "" || atype == "Unknown" || v2_type_compat(expected, atype)) continue
        v2_diag(AST[strlit_id,"line"], 1, name " argument " i " expects " expected ", got " atype)
      }
    } else if (name ~ /_t$/) {
      # SIG 未登録の generic dispatch（v1 dsl/desugar_dot.awk の unknown
      # generic dispatch と同じ扱い。BJ 相当）。
      v2_diag(AST[strlit_id,"line"], 1, "unknown generic dispatch: " name)
      return "Unknown"
    }
    call_ret = ((name, "ret") in SIG) ? SIG[name, "ret"] : "Unknown"
    # generic 戻り型の T プレースホルダを実際の型引数で置換する（AE と同じ
    # 規則をテキストスキャンにも適用する。DU）。
    if (genarg != "" && call_ret ~ /\<T\>/) gsub(/\<T\>/, genarg, call_ret)
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
  # 裸 IDENT・call・pipe のいずれの既知形にもマッチしない補間式（丸括弧
  # 包み `(raw)` や `raw ""` のような暗黙連結の一部でない裸の並びなど）は
  # 従来 Unknown を返すだけで、文字列リテラルキャッシュ側が Unknown を
  # 安全な Str と同一視していた。式テキスト中に Untrusted な変数への
  # 参照が含まれる場合はそれを見逃さず Untrusted<Str> を返す（DV。
  # 誤検出側に倒す必要はないが、untrusted 参照の見逃し側には倒さない）。
  uref = v2_interp_text_has_untrusted_ref(exprtext)
  if (uref != "") return uref
  return "Unknown"
}

# exprtext 中に現れる識別子のうち、V2_ENV で Untrusted<...>（union member
# 含む = DK の v2_type_has_untrusted_member を再利用）と分かっているものが
# 1 つでもあれば、その型を返す。無ければ "" を返す（DV）。既知形にマッチ
# しない補間式の安全側フォールバックとして使う。
function v2_interp_text_has_untrusted_ref(exprtext,    rest, m, ident, t) {
  rest = exprtext
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
    ident = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    if (!(ident in V2_ENV)) continue
    t = V2_ENV[ident]
    if (v2_type_has_untrusted_member(t)) return t
  }
  return ""
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
# 補間式テキストの終端 "}" を、引用文字列（"..."、\" エスケープ対応）内の
# "}" を除外して探す。CO/DB の括弧深さ追跡と同じ帯: `#{...}` の中身に
# `safe.html.raw("}")` のような文字列リテラルがあると、素朴な [^}]* 走査は
# その中の } で早期終端してしまう（DM）。start は "#{" の直後の位置。
# 見つからなければ 0 を返す。
# 生の " を文字列開始/終了のトグルに使い、文字列内の \X は任意の 1 文字を
# 無条件でエスケープとして読み飛ばす（v2_find_toplevel_pipe /
# v2_split_toplevel_commas と同じ汎用エスケープ規約。review ES 対応で
# lex.awk が補間内ネスト文字列を実際に STR トークンとして字句化するように
# なったため、rpn.awk の再構築テキストにも生の " がそのまま現れる。旧
# `\"` ペア規約は、STR トークン自身の内容に \" が含まれるケース
# （f("a\"b") 等）で境界判定のパリティが崩れ、sealed/Untrusted 補間検査を
# バイパスする不具合があった）。
function v2_find_interp_close(text, start,    i, c, in_str) {
  in_str = 0
  for (i = start; i <= length(text); i++) {
    c = substr(text, i, 1)
    if (in_str) {
      if (c == "\\") { i++; continue }
      if (c == "\"") in_str = 0
      continue
    }
    if (c == "\"") { in_str = 1; continue }
    if (c == "}") return i
  }
  return 0
}

function v2_cache_strlit_interp_types(id, text,    rest, exprtext, t, n, ct, start, close_pos) {
  rest = text
  n = 0
  while ((start = index(rest, "#{")) > 0) {
    close_pos = v2_find_interp_close(rest, start + 2)
    if (close_pos == 0) break
    exprtext = substr(rest, start + 2, close_pos - start - 2)
    t = v2_infer_interp_expr_type(id, exprtext)
    if (t != "" && t != "Unknown") {
      ct = v2_resolve_sealed(t)
      if (v2_is_nullable(ct)) v2_diag(AST[id,"line"], 1, "cannot interpolate sealed " ct)
    }
    n++
    STRLIT_INTERP_TYPE[id, n] = t
    rest = substr(rest, close_pos + 1)
  }
  STRLIT_INTERP_COUNT[id] = n
}

# id（STRLIT ノード）の #{ } 補間のいずれかの型が Untrusted<...> なら真を返す
# （BL）。v2_cache_strlit_interp_types 呼び出し後のキャッシュを読むだけ（BM）。
function v2_strlit_has_untrusted_interp(id,    i, n) {
  n = (id in STRLIT_INTERP_COUNT) ? STRLIT_INTERP_COUNT[id] : 0
  for (i = 1; i <= n; i++) {
    if (v2_type_has_untrusted_member(STRLIT_INTERP_TYPE[id, i])) return 1
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
function v2_check_brand_arg(call_id, name, argidx, expected, child,    actual, text, cls, inner, mt) {
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
  # actual がエイリアス（`type U = Untrusted<Str>` 等、union 展開結果を
  # 含む）の場合は未展開テキストに prefix が一致せず免除されない非対称が
  # あったため、DW の member 再分割ヘルパで展開後の Untrusted<...> を
  # 探してから判定する（review EE）。
  mt = v2_find_sealed_member(actual, "^Untrusted<", 0)
  if (mt != "" && (name, "classify") in SIG) {
    cls = SIG[name, "classify"]
    if (cls == "transform" || cls == "validator" || cls == "sanitizer") {
      inner = mt
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
#   さらにエイリアス展開結果自体が union になる場合（`type S =
#   Str|Result<Str,E>`）も v2_find_sealed_member が再帰的に member を
#   走査して見逃さない（review DW）。
function v2_check_pipe_rules(id,    lhs_id, rhs_id, lt, mt) {
  lhs_id = AST[id,"c1"]
  rhs_id = AST[id,"c2"]
  if (AST[rhs_id,"kind"] != "CALL") {
    v2_diag(AST[id,"line"], 1, "pipe right-hand side must be a call (`expr |> f(args)`)")
    return
  }
  lt = ((lhs_id) in TYPEOF) ? TYPEOF[lhs_id] : ""
  if (lt == "" || lt == "Unknown") return
  mt = v2_find_sealed_member(lt, "^(Result|Option)<", 0)
  if (mt != "") v2_diag(AST[id,"line"], 1, "pipe input is " mt)
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

# 型文字列をトップレベル "&"（<...> の深さを尊重）で分割する（DF。交差型
# `A & Int` の各 member を辿るため v2_split_union と対で使う）。
function v2_split_intersection(t, out,    i, c, depth, cur, n) {
  n = 0; depth = 0; cur = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if      (c == "<") depth++
    else if (c == ">") depth--
    else if (c == "&" && depth == 0) { out[++n] = cur; cur = ""; continue }
    cur = cur c
  }
  if (length(cur) > 0) out[++n] = cur
  return n
}

# name から辿って visiting に既出なら "type alias cycle detected involving
# 'name'" を診断する（v1 実測文面と一致）。union 分岐だけでなく交差型 "&"
# でも分割し、各 member がエイリアス名なら再帰する（DF。`type A = B & Int`
# + `type B = A` のように交差型に隠れたサイクルは union 分岐だけでは
# 素通りしていた）。
function v2_check_alias_cycle(name, lineno, visiting,    target, uparts, un, i, iparts, ni, j) {
  if (!(name in ALIAS)) return
  if (name in visiting) {
    v2_diag(lineno, 1, "type alias cycle detected involving '" name "'")
    return
  }
  visiting[name] = 1
  target = ALIAS[name]
  un = v2_split_union(target, uparts)
  for (i = 1; i <= un; i++) {
    ni = v2_split_intersection(uparts[i], iparts)
    for (j = 1; j <= ni; j++) v2_check_alias_cycle_member(iparts[j], lineno, visiting)
  }
  delete visiting[name]
}

# member（union/intersection 分割後の 1 要素）を辿る。member 自体がエイリアス
# 名ならそのエイリアスを再帰的に辿り、`Name<...>` の generic 型なら型引数を
# 抽出して各引数にも同じ処理を適用する（review EA。`type A = List<B>` +
# `type B = A` のように generic 型引数の内側に隠れた循環は、member の完全
# 一致判定だけでは検出できず素通りしていた）。
function v2_check_alias_cycle_member(member, lineno, visiting,    m, inner, gparts, gn, k) {
  if (member in ALIAS) v2_check_alias_cycle(member, lineno, visiting)
  if (match(member, /^[A-Za-z_][A-Za-z0-9_]*<(.*)>$/, m)) {
    inner = m[1]
    gn = v2_split_generic_args(inner, gparts)
    for (k = 1; k <= gn; k++) v2_check_alias_cycle_member(gparts[k], lineno, visiting)
  }
}

function v2_check_alias_cycles(    i, name, visiting) {
  for (i = 1; i <= ALIAS_DECL_N; i++) {
    name = ALIAS_DECL_ORDER[i]
    delete visiting
    v2_check_alias_cycle(name, ALIAS_DECL_LINE[name], visiting)
  }
}
