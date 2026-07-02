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
# 3 周構成:
#   1. v2_collect(1)     -- FUNC ノードを収集して SIG[] を充填（前方参照に対応するため全体を先に走査）
#   2. v2_check_calls(1) -- CALL ノードの arity を検査し TYPEOF[] を設定
#   3. v2_infer(1)       -- 後順走査でボトムアップ型推論を行い、LET/RETURN の型注釈を検査

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
  if (AST[id,"kind"] == "FUNC") {
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
#   NUMLIT                              -> Int（小数点含みは Num）
#   STRLIT                              -> Str
#   BINOP + - * / % ^                   -> 両辺 Int なら Int、どちらか Num なら Num、他は error
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
function v2_type_compat(expected, actual,    ea, aa, en, an, i, j, eparts, aparts) {
  if (expected == actual)             return 1
  if (expected == "Any" || expected == "Unknown") return 1
  if (actual   == "Any" || actual   == "Unknown") return 1
  if (actual == "")                   return 1

  ea = v2_expand_alias(expected)
  aa = v2_expand_alias(actual)
  if (ea != expected || aa != actual) return v2_type_compat(ea, aa)

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

# Option<T> / Result<T, E> の内側の型を取り出す（Union は各枝を合流）
function v2_unwrap_type(t,    parts, n, i, inner, m, result) {
  n = v2_split_union(t, parts)
  result = ""
  for (i = 1; i <= n; i++) {
    inner = parts[i]
    if (match(inner, /^Option<(.+)>$/, m))       inner = m[1]
    else if (match(inner, /^Result<([^,]+),/, m)) inner = m[1]
    else                                          inner = "Any"
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
    if ((lt == "Int" || lt == "Num") && (rt == "Int" || rt == "Num")) return "Num"
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
                   saved_ret, saved_name, ret_type, name) {
  kind = AST[id,"kind"]

  if (kind == "FUNC") {
    name = AST[id,"text"]
    ret_type = ((name,"ret") in SIG) ? SIG[name,"ret"] : "Unknown"
    saved_ret  = V2_CUR_FUNC_RET
    saved_name = V2_CUR_FUNC_NAME
    V2_CUR_FUNC_RET  = ret_type
    V2_CUR_FUNC_NAME = name
    for (k = 1; k <= AST[id,"nc"]; k++) v2_infer(AST[id,"c" k])
    V2_CUR_FUNC_RET  = saved_ret
    V2_CUR_FUNC_NAME = saved_name
    return ""
  }

  for (k = 1; k <= AST[id,"nc"]; k++) v2_infer(AST[id,"c" k])

  t = ""
  if (kind == "NUMLIT") {
    t = (AST[id,"text"] ~ /\./) ? "Num" : "Int"
  } else if (kind == "STRLIT") {
    t = "Str"
  } else if (kind == "IDENT") {
    t = "Unknown"
  } else if (kind == "RAW" || kind == "RAWLINE") {
    t = "Unknown"
  } else if (kind == "UNOP") {
    ct = TYPEOF[AST[id,"c1"]]
    if (AST[id,"text"] == "NOT") t = "Bool"
    else if (ct == "Int" || ct == "Num") t = ct
    else t = "Unknown"
  } else if (kind == "BINOP") {
    lt = TYPEOF[AST[id,"c1"]]
    rt = TYPEOF[AST[id,"c2"]]
    t = v2_binop_type(AST[id,"text"], lt, rt, AST[id,"line"])
  } else if (kind == "COALESCE") {
    lt = TYPEOF[AST[id,"c1"]]
    rt = TYPEOF[AST[id,"c2"]]
    t = v2_union_of(v2_unwrap_type(lt), rt)
  } else if (kind == "DOT") {
    t = v2_dot_type(id)
    TYPEOF[id] = t
  } else if (kind == "CALL") {
    t = ((id) in TYPEOF) ? TYPEOF[id] : "Unknown"
  } else if (kind == "LET" || kind == "LETQ") {
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

# ─── エントリポイント ─────────────────────────────────────────────

function v2_check() {
  v2_init_builtins()
  VARIANTS["Result"] = "ok" SUBSEP "ng"
  VARIANTS["Option"]  = "some" SUBSEP "none"

  v2_collect(1)
  v2_check_calls(1, 0)
  v2_infer(1)
}
