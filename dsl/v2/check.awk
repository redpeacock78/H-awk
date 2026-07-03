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
    if (AST[id,"nc"] >= 1) ALIAS[AST[id,"text"]] = AST[AST[id,"c1"],"text"]
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
                         eg, ag, egn, agn, egargs, agargs) {
  if (expected == actual)             return 1
  if (expected == "Any" || expected == "Unknown") return 1
  if (actual   == "Any" || actual   == "Unknown") return 1
  if (actual == "")                   return 1

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

# Option<T> / Result<T, E> の内側の型を取り出す（Union は各枝を合流）
function v2_unwrap_type(t,    parts, n, i, inner, m, result) {
  n = v2_split_union(t, parts)
  result = ""
  for (i = 1; i <= n; i++) {
    inner = parts[i]
    if (match(inner, /^Option<(.+)>$/, m))       inner = m[1]
    else if (match(inner, /^Result<([^,]+),/, m)) inner = m[1]
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
  if (op == "CONCAT") return "Str"

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

# 現在走査中の関数の宣言戻り値型・名前（RETURN 文の検査に使う）
V2_CUR_FUNC_RET = ""
V2_CUR_FUNC_NAME = ""

function v2_infer(id,    k, kind, t, lt, rt, ct, typeann_id, expr_id, child, \
                   saved_ret, saved_name, ret_type, name, ret_sig, typearg, lhs_decl_type) {
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

  for (k = 1; k <= AST[id,"nc"]; k++) v2_infer(AST[id,"c" k])

  t = ""
  if (kind == "NUMLIT") {
    t = (AST[id,"text"] ~ /\./) ? "Float" : "Int"
  } else if (kind == "STRLIT") {
    t = "Str"
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
    lt = TYPEOF[AST[id,"c1"]]
    rt = TYPEOF[AST[id,"c2"]]
    t = v2_union_of(v2_unwrap_type(lt), rt)
  } else if (kind == "PIPE") {
    t = TYPEOF[AST[id,"c2"]]
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
    V2_ENV[AST[id,"text"]] = (typeann_id != 0) ? AST[typeann_id,"text"] : v2_unwrap_type(TYPEOF[expr_id])
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
  ct = v2_strip_effect(ct)
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
function v2_result_err_part(t,    m, inner, depth, i, c, comma_pos, part) {
  if (!match(t, /^Result<(.+)>$/, m)) return ""
  inner = m[1]
  depth = 0; comma_pos = 0
  for (i = 1; i <= length(inner); i++) {
    c = substr(inner, i, 1)
    if      (c == "<") depth++
    else if (c == ">") depth--
    else if (c == "," && depth == 0) { comma_pos = i; break }
  }
  if (comma_pos == 0) return ""
  part = substr(inner, comma_pos + 1)
  sub(/^[[:space:]]+/, "", part)
  return part
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
    ttype = v2_strip_effect(TYPEOF[target_id])
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

# ─── パス 5: CALL 引数の型検査（XSS ブランド型を含む、Task 9） ────────

# #{ expr } 補間内の式テキストから、単純な CALL / DOT-CALL 形式（`recv.method(...)`
# または `fn(...)`）の戻り型を SIG[] から引く。判別できなければ Unknown を返す
# （v2_check_fragment_interp 側で Unknown は誤検出防止のため検査しない）。
# Task 11（補間の構造化 AST）のスコープ外のため、ここではテキストスキャンで
# v1（dsl/desugar_strings.awk の _ds_interp_expr_type 相当）と同等の検出を行う。
function v2_infer_interp_expr_type(exprtext,    m, name) {
  exprtext = exprtext
  sub(/^[[:space:]]+/, "", exprtext)
  sub(/[[:space:]]+$/, "", exprtext)
  if (match(exprtext, /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]*\(/, m)) {
    name = m[0]
    sub(/[[:space:]]*\($/, "", name)
    if ((name, "ret") in SIG) return SIG[name, "ret"]
  }
  return "Unknown"
}

# safe.html.fragment の文字列引数中の #{ expr } 補間を走査し、各式の型を
# HtmlPart（HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr）と照合する
# （AM: dsl/desugar_strings.awk の _ds_expand_fragment_interp 互換）。
function v2_check_fragment_interp(call_id, text,    rest, m, exprtext, t, adv) {
  rest = text
  while (match(rest, /#\{([^}]*)\}/, m)) {
    # RSTART/RLENGTH は組込みグローバル変数のため、次の match（
    # v2_infer_interp_expr_type 内部の match も含む）で上書きされる前に
    # 前進量を確定させておく（さもないと rest が縮まらず暴走する）。
    adv = RSTART + RLENGTH
    exprtext = m[1]
    t = v2_infer_interp_expr_type(exprtext)
    if (t != "" && t != "Unknown" && \
        !v2_type_compat("HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr", t)) {
      v2_diag(AST[call_id,"line"], 1, \
        "safe.html.fragment interpolation expects HtmlPart, got " t)
    }
    rest = substr(rest, adv)
  }
}

# CALL の 1 引数を SIG["name","argN"] と照合し、不一致なら診断する。
# safe.html.fragment への文字列リテラル引数は静的 HTML として常に許容するが、
# 補間 #{ } を含む場合は動的 HTML なので免除せず、埋め込み式を検査する（AM）。
function v2_check_brand_arg(call_id, name, argidx, expected, child,    actual, text) {
  if (name == "safe.html.fragment" && AST[child,"kind"] == "STRLIT") {
    text = AST[child,"text"]
    if (index(text, "#{") == 0) return
    v2_check_fragment_interp(call_id, text)
    return
  }
  actual = ((child) in TYPEOF) ? TYPEOF[child] : ""
  if (actual == "" || v2_type_compat(expected, actual)) return
  v2_diag(AST[call_id,"line"], 1, name " argument " argidx " expects " expected ", got " actual)
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
  v2_check_calls(1, 0)
  v2_infer(1)
  v2_check_when(1)
  v2_check_brand(1, 0)
}
