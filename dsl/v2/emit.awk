# SPDX-License-Identifier: MIT
# dsl/v2/emit.awk -- AST -> awk コード生成
#
# 消費: 検査済み AST[]、PASS[]、TYPEOF[]、V2_LINEAST[]（parse.awk が記録）
# 生成: 標準出力への awk ソース
#
# 行順マージ: PASS 行はそのまま出力し、DSL 由来行は「その行を先頭とする
# 文ノード」を V2_LINEAST 経由で見つけて v2_e() に委譲する。
# FUNC 本体内の文は v2_e_func() が AST の子を直接たどって出力するため、
# V2_LINEAST には登録されない（登録されるのはトップレベル文のみ）。

function v2_emit(   l, id) {
  v2_collect_hoists()
  for (l = 1; l <= V2_NLINES; l++) {
    if (l in PASS) {
      print PASS[l]
    } else if (l in V2_LINEAST) {
      id = V2_LINEAST[l]
      v2_e(id, (AST[id,"kind"] == "FUNC") ? 0 : 1)
    }
  }
}

function v2_indent(depth,    s, i) {
  s = ""
  for (i = 0; i < depth; i++) s = s "  "
  return s
}

# ─── 関数ローカル変数のホイスト収集 ────────────────────────────────
# 各 FUNC の子孫にある LET/LETQ 変数名、WHEN 腕束縛名、PIPE/COALESCE/LETQ が
# 注入する一時変数名を HOIST[func_id] にカンマ区切りで集める。
# 一時変数の命名・採番は実際の emit 走査順と一致させる必要があるため
# （PIPE_TMPVAR[]/TC_TMPVAR[]/LETQ_TMPVAR[]/WHEN_TMPVAR[] にキャッシュし、
# emit 側は採番せず参照するだけにする）、ここでの走査順は v2_e() 系が
# 実際に式を評価する順序（子を先に、当該ノード自身の一時変数は後、ただし
# WHEN 自身の対象式一時変数は腕を見る前に確定する）に合わせている。
# PROGRAM ルート（AST id 1）から 1 回だけ走査する。FUNC の外側（BEGIN 等の
# トップレベル文、例: app.awk の `hawk.app.listen(env.get("PORT") ?? 8080)`）
# にも PIPE/COALESCE/LETQ/WHEN は現れ得るため、「FUNC ごとに歩く」実装では
# それらの一時変数採番が漏れる（func_id が無く HOIST できないだけで、採番
# 自体は必要）。そのため PROGRAM から 1 本の再帰で全体を歩き、現在どの
# FUNC の中にいるか（func_id、トップレベルなら 0）を引数で追跡する。
function v2_collect_hoists() {
  v2_collect_hoists_walk(1, 0)
}

function v2_hoist_add(func_id, name) {
  if (func_id == 0) return   # トップレベルはホイスト対象の関数が無い（素の awk グローバル変数）
  if ((func_id, name) in HOIST_SEEN) return
  HOIST_SEEN[func_id, name] = 1
  HOIST[func_id] = (func_id in HOIST) ? HOIST[func_id] ", " name : name
}

function v2_collect_hoists_walk(id, func_id,    k, kind, next_func, rhs_id, child, resolved, tmpvar) {
  kind = AST[id,"kind"]
  next_func = (kind == "FUNC") ? id : func_id

  if (kind == "LET" || kind == "LETQ")
    v2_hoist_add(next_func, AST[id,"text"])

  # WHEN 自身の対象式一時変数（_ds_mc_N）は、腕の束縛名より先に確定する
  # （v1 desugar_match.awk と同じ順序: まず match 対象を temp に取り、
  # その後で腕ごとの束縛を処理する）。
  if (kind == "WHEN") {
    V2_MC_CNT++
    WHEN_TMPVAR[id] = "_ds_mc_" V2_MC_CNT
    v2_hoist_add(next_func, WHEN_TMPVAR[id])
  }

  # PAT の束縛変数（ok/some/ng/default の名前付き腕）。同名が複数腕で
  # 再利用されるケース（`ng e<A>:` / `ng e<B>:` が両方 "e" を束縛）は
  # v2_hoist_add の重複排除で 1 個に畳み込む。
  if (kind == "PAT") {
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "IDENT") v2_hoist_add(next_func, AST[child,"text"])
    }
  }

  for (k = 1; k <= AST[id,"nc"]; k++)
    v2_collect_hoists_walk(AST[id,"c" k], next_func)

  # PIPE / COALESCE / LETQ 自身の一時変数は子を評価した後に確定する
  # （実際の代入順序と一致させ、ネストした pipe/coalesce に先に若い番号を
  # 割り当てる）。採番（V2_*_CNT のインクリメントと *_TMPVAR[id] の記録）
  # は func_id の有無にかかわらず必ず行う（トップレベルはホイストだけ
  # スキップする）。
  if (kind == "PIPE") {
    V2_PIPE_CNT++
    PIPE_TMPVAR[id] = "_ds_p_" V2_PIPE_CNT
    v2_hoist_add(next_func, PIPE_TMPVAR[id])
  } else if (kind == "COALESCE") {
    V2_TC_CNT++
    TC_TMPVAR[id] = "_ds_tc_" V2_TC_CNT
    v2_hoist_add(next_func, TC_TMPVAR[id])
  } else if (kind == "LETQ") {
    V2_TC_CNT++
    tmpvar = "_ds_tc_" V2_TC_CNT
    LETQ_TMPVAR[id] = tmpvar
    v2_hoist_add(next_func, tmpvar)
    rhs_id = 0
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] != "TYPEANN") rhs_id = child
    }
    resolved = (rhs_id != 0) ? v2_resolve_sealed(TYPEOF[rhs_id]) : ""
    # Result 系のみ、エラー種別を受ける追加の一時変数が必要（Option 系は
    # option_some()/option_val() だけで済むため不要）。
    if (resolved !~ /^Option</) v2_hoist_add(next_func, "_ds_err_type_" tmpvar)
  }
}

# ─── 文ディスパッチ ────────────────────────────────────────────────

# v2_e_expr() から呼ばれる PIPE/COALESCE の emit は、自身の代入行を print
# する副作用を持つ（一時変数注入）。その print の直前に置くインデント幅を
# 式評価元の文と揃えるため、文ディスパッチの入口で都度更新するグローバル。
V2_CUR_DEPTH = 0

function v2_e(id, depth,    kind) {
  V2_CUR_DEPTH = depth
  kind = AST[id,"kind"]
  if      (kind == "FUNC")         v2_e_func(id, depth)
  else if (kind == "LET")          v2_e_let(id, depth)
  else if (kind == "LETQ")         v2_e_letq(id, depth)
  else if (kind == "RETURN")       v2_e_return(id, depth)
  else if (kind == "INDEX_ASSIGN") v2_e_index_assign(id, depth)
  else if (kind == "WHEN")         v2_e_when(id, depth)
  else if (kind == "EXPR")         print v2_indent(depth) v2_e_expr(AST[id,"c1"])
  else if (kind == "RAWLINE")      print AST[id,"text"]
  else if (kind == "TYPEDECL")     return   # コンパイル時の型情報のみ、実行コードは生成しない
  else v2_diag(AST[id,"line"], 1, "emit: unsupported node kind: " kind)
}

function v2_e_block(blk, depth,    k) {
  for (k = 1; k <= AST[blk,"nc"]; k++) v2_e(AST[blk,"c" k], depth)
}

function v2_e_func(id, depth,    k, c, kind, params, first, sig) {
  params = ""
  first = 1
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] == "PARAM") {
      params = params (first ? "" : ", ") AST[c,"text"]
      first = 0
    }
  }
  sig = params
  if (id in HOIST) sig = sig (params != "" ? ",    " : "    ") HOIST[id]

  print v2_indent(depth) "function " AST[id,"text"] "(" sig ") {"
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    kind = AST[c,"kind"]
    if (kind == "PARAM" || kind == "TYPEANN") continue
    v2_e(c, depth + 1)
  }
  print v2_indent(depth) "}"
}

function v2_e_let(id, depth,    varname, k, c, expr_id, ekind) {
  varname = AST[id,"text"]
  expr_id = 0
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] != "TYPEANN") expr_id = c
  }
  if (expr_id == 0) return   # 裸宣言: ホイストのみ、文は出力しない
  ekind = AST[expr_id,"kind"]
  if (ekind == "DICTLIT" || ekind == "LISTLIT")
    print v2_indent(depth) "delete " varname
  else
    print v2_indent(depth) varname " = " v2_e_expr(expr_id)
}

# ─── `?=` 安全アンラップ文（LETQ） ─────────────────────────────────
#
# 対応表の移植元: dsl/desugar_let.awk:_ds_let_transform（?= 分岐）+
# _ds_result_ng_return。JSON デコード時の Dict/List 特殊分岐
# （result_val_into_map 等）は Task 11 のスコープ外（fixture・app.awk の
# いずれも踏まないため、報告書に Task 12 送りと明記して見送る）。
function v2_e_letq(id, depth,    varname, rhs_id, k, c, tmpvar, rhs_out, resolved, errvar) {
  varname = AST[id,"text"]
  rhs_id = 0
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] != "TYPEANN") rhs_id = c
  }
  tmpvar = LETQ_TMPVAR[id]
  rhs_out = v2_e_expr(rhs_id)
  print v2_indent(depth) tmpvar " = " rhs_out
  resolved = v2_resolve_sealed(TYPEOF[rhs_id])

  if (resolved ~ /^Option</) {
    print v2_indent(depth) "if (!option_some(" tmpvar ")) {"
    print v2_indent(depth + 1) "return ctx::dispatch(\"res.status\", 404)"
    print v2_indent(depth) "}"
    print v2_indent(depth) varname " = option_val(" tmpvar ")"
  } else {
    errvar = "_ds_err_type_" tmpvar
    print v2_indent(depth) "if (!result_ok(" tmpvar ")) {"
    print v2_indent(depth + 1) errvar " = awk::result_err_type(" tmpvar ")"
    print v2_indent(depth + 1) "if (" errvar " == \"ParseError\") return ctx::dispatch(\"res.status\", 400)"
    print v2_indent(depth + 1) "if (" errvar " == \"AuthError\") return ctx::dispatch(\"res.status\", 401)"
    print v2_indent(depth + 1) "if (" errvar " == \"NotFoundError\") return ctx::dispatch(\"res.status\", 404)"
    print v2_indent(depth + 1) "if (" errvar " == \"JsonParseError\") return ctx::dispatch(\"res.status\", 400)"
    print v2_indent(depth + 1) "if (" errvar " == \"JsonTypeError\") return ctx::dispatch(\"res.status\", 422)"
    print v2_indent(depth + 1) "if (" errvar " == \"JsonTooDeepError\") return ctx::dispatch(\"res.status\", 400)"
    print v2_indent(depth + 1) "return ctx::dispatch(\"res.status\", 500)"
    print v2_indent(depth) "}"
    print v2_indent(depth) varname " = result_val(" tmpvar ")"
  }
}

function v2_e_return(id, depth) {
  if (AST[id,"nc"] >= 1) print v2_indent(depth) "return " v2_e_expr(AST[id,"c1"])
  else                   print v2_indent(depth) "return"
}

function v2_e_index_assign(id, depth) {
  print v2_indent(depth) AST[id,"text"] "[" v2_e_expr(AST[id,"c1"]) "] = " v2_e_expr(AST[id,"c2"])
}

# ─── `when ... of ... end` 文 ──────────────────────────────────────
#
# 対応表の移植元: dsl/desugar_match.awk, docs/dsl.md 436-472 行。
# 対象式を _ds_mc_N に受けてから if/else if チェーンへ展開する。
# タグ判定:
#   ok/some    -> 成功条件（result_ok/option_some）、束縛は result_val/option_val
#   ng<Type>   -> result_err_type(tmp) == "Type" の else if、束縛は result_err
#   ng（無型）/none/default/_ -> 網羅性検査済みの catch-all（必ず最後）と
#                                 して else に展開。Result 系で束縛があれば
#                                 result_err、Option 系は束縛不可（parse 時点
#                                 で拒否済み）。
function v2_e_when(id, depth,    tmp, ttype, is_option, k, j, arm, pat, blk, \
                    tag, typeann_id, bind_id, pc, bind_name, opened, cond) {
  tmp = WHEN_TMPVAR[id]
  print v2_indent(depth) tmp " = " v2_e_expr(AST[id,"c1"])
  ttype = v2_resolve_sealed(TYPEOF[AST[id,"c1"]])
  is_option = (ttype ~ /^Option</)

  opened = 0
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
    bind_name = (bind_id != 0) ? AST[bind_id,"text"] : ""

    if (tag == "ok" || tag == "some") {
      cond = (tag == "ok") ? "result_ok(" tmp ")" : "option_some(" tmp ")"
      print v2_indent(depth) (opened ? "} else if (" : "if (") cond ") {"
      opened = 1
      if (bind_name != "")
        print v2_indent(depth + 1) bind_name " = " ((tag == "ok") ? "result_val(" tmp ")" : "option_val(" tmp ")")
      v2_e_block(blk, depth + 1)
    } else if (tag == "ng" && typeann_id != 0) {
      print v2_indent(depth) (opened ? "} else if (" : "if (") "result_err_type(" tmp ") == \"" AST[typeann_id,"text"] "\") {"
      opened = 1
      if (bind_name != "") print v2_indent(depth + 1) bind_name " = result_err(" tmp ")"
      v2_e_block(blk, depth + 1)
    } else {
      # catch-all（無型 ng / none / default / _）。check.awk の網羅性検査で
      # 必ず最後の腕であることが保証されている。
      print v2_indent(depth) (opened ? "} else {" : "if (1) {")
      opened = 1
      if (bind_name != "" && !is_option)
        print v2_indent(depth + 1) bind_name " = result_err(" tmp ")"
      v2_e_block(blk, depth + 1)
    }
  }
  print v2_indent(depth) "}"
}

# ─── 式 emit ────────────────────────────────────────────────────

function v2_e_expr(id,    kind, s, k) {
  kind = AST[id,"kind"]
  if (kind == "NUMLIT" || kind == "IDENT" || kind == "REGEXLIT" || kind == "RAW")
    return AST[id,"text"]
  if (kind == "STRLIT") {
    if (index(AST[id,"text"], "#{") > 0) return v2_e_interp(id)
    return AST[id,"text"]
  }
  if (kind == "BINOP") {
    # CONCAT は暗黙連結（rpn.awk が隣接オペランドの間に挿入する疑似演算子）
    # であり、awk 上の実演算子ではない。"CONCAT" という語をそのまま出力すると
    # 生成コードが構文エラーになるため、演算子テキストを出さずに空白区切りで
    # 連結する（v1 の暗黙連結出力と同じ見た目。app.awk 実測で発覚）。
    if (AST[id,"text"] == "CONCAT")
      return v2_e_expr(AST[id,"c1"]) " " v2_e_expr(AST[id,"c2"])
    return v2_e_expr(AST[id,"c1"]) " " AST[id,"text"] " " v2_e_expr(AST[id,"c2"])
  }
  if (kind == "UNOP")
    return AST[id,"text"] v2_e_expr(AST[id,"c1"])
  if (kind == "INDEX")
    return v2_e_expr(AST[id,"c1"]) "[" v2_e_expr(AST[id,"c2"]) "]"
  if (kind == "PIPE")     return v2_e_pipe(id)
  if (kind == "COALESCE") return v2_e_coalesce(id)
  if (kind == "CALL") {
    if (index(AST[id,"text"], ".") > 0) return v2_e_dispatch(id)
    s = AST[id,"text"] "("
    for (k = 1; k <= AST[id,"nc"]; k++) s = s (k > 1 ? ", " : "") v2_e_expr(AST[id,"c" k])
    return s ")"
  }
  v2_diag(AST[id,"line"], 1, "emit: unsupported node kind: " kind)
  return ""
}

# ─── `|>` パイプ演算子（式） ────────────────────────────────────────
#
# 対応表の移植元: dsl/desugar_pipe.awk, docs/dsl.md 311-344 行。
# `lhs |> f(args)` を一時変数 _ds_p_N に代入する文として直前に出力し、
# 式としては生成した一時変数名を返す（呼び出し元の文がその文字列を使って
# 代入・return 等を組み立てる）。名前解決は v2_e_dispatch と同じ規則
# （ドット呼び出しは ns::dispatch、option.some/none は直呼び出し）だが、
# LHS を第 1 引数として注入する点だけが異なる。
function v2_e_pipe(id,    lhs_id, rhs_id, lhs_out, name, dot, ns, path, s, k, tmpvar, call_expr) {
  lhs_id = AST[id,"c1"]
  rhs_id = AST[id,"c2"]
  lhs_out = v2_e_expr(lhs_id)
  name = AST[rhs_id,"text"]

  if (name == "option.some") {
    s = "option_some_make(" lhs_out
    for (k = 1; k <= AST[rhs_id,"nc"]; k++) s = s ", " v2_e_expr(AST[rhs_id,"c" k])
    call_expr = s ")"
  } else {
    dot = index(name, ".")
    if (dot > 0) {
      ns   = substr(name, 1, dot - 1)
      path = substr(name, dot + 1)
      s = ns "::dispatch(\"" path "\", " lhs_out
      for (k = 1; k <= AST[rhs_id,"nc"]; k++) s = s ", " v2_e_expr(AST[rhs_id,"c" k])
      call_expr = s ")"
    } else {
      s = name "(" lhs_out
      for (k = 1; k <= AST[rhs_id,"nc"]; k++) s = s ", " v2_e_expr(AST[rhs_id,"c" k])
      call_expr = s ")"
    }
  }

  tmpvar = PIPE_TMPVAR[id]
  print v2_indent(V2_CUR_DEPTH) tmpvar " = " call_expr
  return tmpvar
}

# ─── `??` null 合体演算子（式） ─────────────────────────────────────
#
# 対応表の移植元: dsl/desugar_nullcoalesce.awk, docs/dsl.md 480-497 行。
# `lhs ?? rhs` を一時変数 _ds_tc_N = lhs として直前に出力し、式としては
# `(tmp != "" ? tmp : rhs)` の三項式テキストを返す。
function v2_e_coalesce(id,    tmp, lhs_out, rhs_out) {
  tmp = TC_TMPVAR[id]
  lhs_out = v2_e_expr(AST[id,"c1"])
  print v2_indent(V2_CUR_DEPTH) tmp " = " lhs_out
  rhs_out = v2_e_expr(AST[id,"c2"])
  return "(" tmp " != \"\" ? " tmp " : " rhs_out ")"
}

# ドット記法呼び出し -> ns::dispatch("path", args...) への変換。
# 対応表の移植元: dsl/desugar_dot.awk, docs/dsl.md 296-344 行。
function v2_e_dispatch(id,    name, dot, ns, path, s, k, arg1type) {
  name = AST[id,"text"]

  if (name == "option.some") {
    s = "option_some_make("
    for (k = 1; k <= AST[id,"nc"]; k++) s = s (k > 1 ? ", " : "") v2_e_expr(AST[id,"c" k])
    return s ")"
  }
  if (name == "option.none") return "option_none_make()"

  dot  = index(name, ".")
  ns   = substr(name, 1, dot - 1)
  path = substr(name, dot + 1)

  if (name == "ctx.res.json" && AST[id,"nc"] == 1) {
    arg1type = TYPEOF[AST[id,"c1"]]
    if (arg1type ~ /^(Dict|List)</) return "json(res, " v2_e_expr(AST[id,"c1"]) ")"
  }

  # ctx.res.redirect(url) は status 302 をデフォルト付与する
  # （dsl/desugar_dot.awk と同じ規則。BODY 側で status を明示する 2 引数系は
  # そのまま素通し）。
  if (name == "ctx.res.redirect" && AST[id,"nc"] == 1)
    return "ctx::dispatch(\"res.redirect\", " v2_e_expr(AST[id,"c1"]) ", 302)"

  s = ns "::dispatch(\"" path "\""
  for (k = 1; k <= AST[id,"nc"]; k++) s = s ", " v2_e_expr(AST[id,"c" k])
  return s ")"
}

# ─── 文字列補間（#{...}） ───────────────────────────────────────────
#
# 対応表の移植元: dsl/desugar_strings.awk:_ds_expand_interp,
# docs/dsl.md 250-261 行。
#
# rpn.awk は補間を含む文字列を 1 個の STRLIT オペランドへ平坦化する際、
# ネストした文字列リテラル（review ES）をその生の引用符を保ったまま
# 埋め込む。そのため #{...} の中身のテキストには、さらに #{...} を含む
# ネスト文字列がそのまま現れることがある（review 追加要件 1: ネスト補間の
# 深度追跡）。check.awk がテキストスキャンで型検査するのと同じ前提に立ち、
# emit 側もテキストスキャンで sprintf(...) へ変換する（AST 化はしない）。
function v2_e_interp(id,    raw, content) {
  raw = AST[id,"text"]
  content = substr(raw, 2, length(raw) - 2)
  return v2_e_interp_build(content, AST[id,"line"])
}

# content（#{...} を含む文字列リテラルの中身）を sprintf(...) 呼び出し
# テキストへ変換する。#{ } を含まなければ（このヘルパはネスト展開からも
# 呼ばれるため、その場合は補間なしのケースがある）そのままクォートして返す。
function v2_e_interp_build(content, line,    parts, np, j, fmt, args, litpart, exprpart, exprout) {
  np = v2_e_split_interp(content, parts)
  if (np <= 1) return "\"" content "\""

  fmt = ""; args = ""
  for (j = 1; j <= np; j++) {
    if (j % 2 == 1) {
      litpart = parts[j]
      gsub(/%/, "%%", litpart)
      fmt = fmt litpart
    } else {
      exprpart = parts[j]
      sub(/^[[:space:]]+/, "", exprpart)
      sub(/[[:space:]]+$/, "", exprpart)
      exprout = v2_e_interp_expr(exprpart, line)
      fmt = fmt "%s"
      args = args ", " exprout
    }
  }
  return "sprintf(\"" fmt "\"" args ")"
}

# content を #{ } の深さを追跡して literal/expr の交互リストへ分割する
# （dsl/desugar_strings.awk:_ds_parse_interp と同じアルゴリズム）。
# parts[奇数] = リテラル、parts[偶数] = 式テキスト。返り値は常に奇数。
# n はローカル変数なので再帰（ネスト補間展開）から呼んでも他フレームの
# parts[] を汚さない。
function v2_e_split_interp(content, parts,    i, c, len, cur, depth, n) {
  len = length(content)
  cur = ""; depth = 0; n = 0
  for (i = 1; i <= len; i++) {
    c = substr(content, i, 1)
    if (depth == 0) {
      if (c == "#" && i < len && substr(content, i + 1, 1) == "{") {
        parts[++n] = cur; cur = ""
        depth = 1; i++
      } else if (c == "\\" && i < len) {
        cur = cur c substr(content, i + 1, 1); i++
      } else {
        cur = cur c
      }
    } else {
      if (c == "{") { depth++; cur = cur c }
      else if (c == "}") {
        depth--
        if (depth == 0) { parts[++n] = cur; cur = "" }
        else              cur = cur c
      } else cur = cur c
    }
  }
  parts[++n] = cur
  return n
}

# 補間 #{ expr } の中身（expr）を awk 式テキストへ変換する。
#  - ネストした "..." 文字列リテラルに #{ が含まれる場合は再帰的に
#    sprintf(...) へ展開する（ネスト補間）。
#  - トップレベルの `|>` は pipe 変換（一時変数は使わずインライン展開—
#    式コンテキストのため文として代入する対象が無い）。
#  - `name(...)` / `ns.path(...)` / `name<T>(...)` 形式の呼び出しは、
#    テキスト中のどこにあっても検出してディスパッチ変換する。
function v2_e_interp_expr(text, line,    text2, pos, lhs, rhs, lhs_out, name, \
                           genarg, open_pos, close_pos, argstr, cargs, ncargs, \
                           call_out, rest, k, matched) {
  sub(/^[[:space:]]+/, "", text)
  sub(/[[:space:]]+$/, "", text)
  text2 = v2_e_expand_nested_str(text, line)

  pos = v2_find_toplevel_pipe(text2)
  if (pos > 0) {
    lhs = substr(text2, 1, pos - 1)
    rhs = substr(text2, pos + 2)
    sub(/[[:space:]]+$/, "", lhs)
    sub(/^[[:space:]]+/, "", rhs)
    lhs_out = v2_e_interp_expr(lhs, line)

    matched = v2_interp_match_call_head(rhs)
    if (!matched) return lhs_out " |> " v2_e_interp_expr(rhs, line)

    name     = V2_INTERP_CALL_NAME
    genarg   = V2_INTERP_CALL_GENERIC
    open_pos = V2_INTERP_CALL_OPEN
    close_pos = v2_match_call_close(rhs, open_pos)
    argstr   = substr(rhs, open_pos + 1, close_pos - open_pos - 1)
    ncargs   = v2_split_toplevel_commas(argstr, cargs)
    for (k = 1; k <= ncargs; k++) cargs[k] = v2_e_interp_expr(cargs[k], line)
    call_out = v2_e_interp_build_call(name, genarg, lhs_out, cargs, ncargs)

    rest = substr(rhs, close_pos + 1)
    sub(/^[[:space:]]+/, "", rest)
    if (rest == "") return call_out
    return call_out " " v2_e_interp_expr(rest, line)
  }

  return v2_e_interp_scan_calls(text2, line)
}

# text（#{ } の直接ネストを既に展開済み）を左から走査し、識別子で始まる
# call 形（ドット連結・generic を含む）を見つけたら都度ディスパッチ変換に
# 置き換える。文字列リテラル内部はスキップする（誤検出防止）。
function v2_e_interp_scan_calls(text, line,    out, i, n, c, in_str, chunk_start, \
                                 sub_i, name, genarg, open_rel, close_rel, abs_close, \
                                 argstr, cargs, ncargs, k, call_out) {
  out = ""; n = length(text); i = 1; in_str = 0; chunk_start = 1
  while (i <= n) {
    c = substr(text, i, 1)
    if (in_str) {
      if (c == "\\" && i < n) { i += 2; continue }
      if (c == "\"") in_str = 0
      i++
      continue
    }
    if (c == "\"") { in_str = 1; i++; continue }
    if (c ~ /[A-Za-z_]/) {
      sub_i = substr(text, i)
      if (v2_interp_match_call_head(sub_i)) {
        name      = V2_INTERP_CALL_NAME
        genarg    = V2_INTERP_CALL_GENERIC
        open_rel  = V2_INTERP_CALL_OPEN
        close_rel = v2_match_call_close(sub_i, open_rel)
        abs_close = i - 1 + close_rel

        out = out substr(text, chunk_start, i - chunk_start)
        argstr = substr(text, i + open_rel, close_rel - open_rel - 1)
        ncargs = v2_split_toplevel_commas(argstr, cargs)
        for (k = 1; k <= ncargs; k++) cargs[k] = v2_e_interp_expr(cargs[k], line)
        call_out = v2_e_interp_build_call(name, genarg, "", cargs, ncargs)

        out = out call_out
        i = abs_close + 1
        chunk_start = i
        continue
      }
    }
    i++
  }
  out = out substr(text, chunk_start)
  return out
}

# 補間内 call を実際の呼び出しテキストへ組み立てる。
#   name        : v2_interp_match_call_head が正規化した呼び出し名
#                 （dotted はフルパス、generic は "_t" 接尾）
#   genarg      : generic 型引数のテキスト（無ければ ""）。第 1 引数として注入
#   extra_first : pipe LHS（無ければ ""）。genarg の次に注入
#   args/nargs  : 明示引数（変換済みテキスト）
# option.some/none 特殊化と ns::dispatch への変換は v2_e_dispatch と同じ規則。
# ctx.res.json の Dict/List 短絡・ctx.res.redirect の 302 既定は、補間内では
# 型情報を持たないため対象外（既存 CALL AST 経路のみ適用。Task 12 送り）。
function v2_e_interp_build_call(name, genarg, extra_first, args, nargs,    allargs, nall, k, dot, ns, path, s) {
  nall = 0
  if (genarg != "")      { nall++; allargs[nall] = "\"" genarg "\"" }
  if (extra_first != "") { nall++; allargs[nall] = extra_first }
  for (k = 1; k <= nargs; k++) { nall++; allargs[nall] = args[k] }

  if (name == "option.some") {
    s = "option_some_make("
    for (k = 1; k <= nall; k++) s = s (k > 1 ? ", " : "") allargs[k]
    return s ")"
  }
  if (name == "option.none") return "option_none_make()"

  dot = index(name, ".")
  if (dot == 0) {
    s = name "("
    for (k = 1; k <= nall; k++) s = s (k > 1 ? ", " : "") allargs[k]
    return s ")"
  }
  ns   = substr(name, 1, dot - 1)
  path = substr(name, dot + 1)
  s = ns "::dispatch(\"" path "\""
  for (k = 1; k <= nall; k++) s = s ", " allargs[k]
  return s ")"
}

# text 内のネスト文字列リテラル（#{ を含むもの）を再帰的に sprintf(...) へ
# 展開し、含まないものはそのままクォート付きで残す。
function v2_e_expand_nested_str(text, line,    out, i, n, c, cj, j, buf) {
  out = ""; n = length(text); i = 1
  while (i <= n) {
    c = substr(text, i, 1)
    if (c == "\"") {
      j = i + 1
      buf = "\""
      while (j <= n) {
        cj = substr(text, j, 1)
        if (cj == "\\" && j < n) { buf = buf cj substr(text, j + 1, 1); j += 2; continue }
        buf = buf cj
        if (cj == "\"") { j++; break }
        j++
      }
      if (index(buf, "#{") > 0) {
        out = out v2_e_interp_build(substr(buf, 2, length(buf) - 2), line)
      } else {
        out = out buf
      }
      i = j
      continue
    }
    out = out c
    i++
  }
  return out
}
