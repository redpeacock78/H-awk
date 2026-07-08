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

function v2_emit(   l, id, k) {
  v2_collect_hoists()
  for (l = 1; l <= V2_NLINES; l++) {
    if (l in V2_SUPPRESS_BLANK) {
      continue
    } else if (l in PASS) {
      print PASS[l]
    } else if (l in V2_LINEAST_N) {
      # 同一行に複数のトップレベル文が並ぶ場合（parse.awk 側で
      # V2_LINEAST[line, k] のリストとして蓄積済み。botfix wave 19）、
      # 記録順にすべて emit する。
      for (k = 1; k <= V2_LINEAST_N[l]; k++) {
        id = V2_LINEAST[l, k]
        # TYPEDECL（G2 の Error alias constructor 含む）は FUNC と同じく
        # トップレベル宣言であり BEGIN{} の中身ではないため depth 0。
        # それ以外の非 FUNC トップレベル文（EXPR 等）は従来どおり
        # BEGIN{} 内前提の depth 1 のまま。
        v2_e(id, (AST[id,"kind"] == "FUNC" || AST[id,"kind"] == "TYPEDECL") ? 0 : 1)
      }
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
  # 仮引数と同名の let/when 束縛・一時変数はホイストしない（Codex review
  # 指摘, botfix wave 19）。重複してホイストすると `function f(x,    x)`
  # のような仮引数重複になり gawk が構文エラーで拒否する。同名再利用は
  # 仮引数のスロットをそのまま使い回す。
  # 訂正（rev-pre12 review Minor）: 「v1 も同じ変数名を再代入するだけで
  # 別スロットを持たないため挙動一致」という以前のコメントは事実誤認
  # だった。v1（`gawk -f dsl/desugar.awk`）で同パターンを実測すると、
  # v1 も同じ形の重複仮引数（`function f(x,    x)`）を生成し gawk の
  # 構文エラーになる（v1・v2 共通の既存バグ）。この修正は「v1 と同じ
  # 挙動にする」ものではなく、生成コードが物理的に構文エラーになる
  # P1 の欠陥を独自に修正したもの。
  if ((func_id, name) in FUNC_PARAM_SEEN) return
  if ((func_id, name) in HOIST_SEEN) return
  HOIST_SEEN[func_id, name] = 1
  HOIST[func_id] = (func_id in HOIST) ? HOIST[func_id] ", " name : name
}

function v2_collect_hoists_walk(id, func_id,    k, kind, next_func, rhs_id, child, resolved, tmpvar, typeann_id, bound_type, types_var) {
  kind = AST[id,"kind"]
  next_func = (kind == "FUNC") ? id : func_id

  if (kind == "FUNC") {
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "PARAM") FUNC_PARAM_SEEN[id, AST[child,"text"]] = 1
    }
  }

  # LETQ の変数ホイストは束縛型により順序が変わる（record 束縛は v1
  # parity で tmpvar より後に、それ以外は従来どおり先に）ため、下の
  # kind == "LETQ" 専用ブロックへ移す（wave 27）。
  if (kind == "LET" || kind == "RECORDLIT")
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
    rhs_id = 0; typeann_id = 0
    for (k = 1; k <= AST[id,"nc"]; k++) {
      child = AST[id,"c" k]
      if (AST[child,"kind"] == "TYPEANN") typeann_id = child
      else                                rhs_id = child
    }
    resolved = (rhs_id != 0) ? v2_resolve_sealed(TYPEOF[rhs_id]) : ""
    # 束縛型（型注釈が無ければ Result<T,E>/Option<T> を unwrap した T で
    # 判定。check.awk の V2_ENV 決定と同じ規則）。unwrap 直後の T が
    # alias 名（`type L = List<Int>` の "L" 等）のままだと、下の
    # Dict/List 判定・record 判定のどちらにも一致せず materialization
    # されない（wave 27 追補 H1。probe /tmp/codex5/h1.awk）。
    # v2_resolve_sealed で 1 段以上 alias 展開してから判定する。
    bound_type = (typeann_id != 0) ? v2_resolve_sealed(AST[typeann_id,"text"]) : v2_resolve_sealed(v2_unwrap_type(resolved))
    LETQ_BOUND_TYPE[id] = bound_type
    if (bound_type in V2_RECORD_TYPE) {
      # record 型の typed decode（`ctx.req.json<Todo>()`）は v1
      # dsl/desugar_let.awk:_ds_let_transform の局所変数登録順（tmpvar ->
      # varname -> 型マップ変数 -> errtype）をそのまま踏襲する（wave 27。
      # golden fixture qeq_ctx_req_json_record_t が要求する順序で、
      # 下の Dict/List 分岐が採用する v2 独自の順序とは異なる）。
      v2_hoist_add(next_func, tmpvar)
      v2_hoist_add(next_func, AST[id,"text"])
      types_var = "_ds_tct_" V2_TC_CNT
      LETQ_TYPES_VAR[id] = types_var
      JSON_TYPEVAR[AST[id,"text"]] = types_var
      v2_hoist_add(next_func, types_var)
      if (resolved !~ /^Option</) v2_hoist_add(next_func, "_ds_err_type_" tmpvar)
    } else {
      v2_hoist_add(next_func, AST[id,"text"])
      v2_hoist_add(next_func, tmpvar)
      # Result 系のみ、エラー種別を受ける追加の一時変数が必要（Option 系は
      # option_some()/option_val() だけで済むため不要）。
      if (resolved !~ /^Option</) v2_hoist_add(next_func, "_ds_err_type_" tmpvar)
      # G6: `?=` の束縛先が Dict</List< のとき（json.decode<Dict<...>>(...) 等）、
      # result_val() の単純 scalar 代入では ADT payload 文字列がそのまま
      # 残ってしまい、束縛後に添字アクセスや ctx.res.json() へ渡すと壊れる。
      # v1 相当の result_val_into_map(res, out, out_types) で awk 連想配列へ
      # 復元する（v2_e_letq）。その out_types サイドカー用の一時変数をここで
      # 確定・ホイストしておく。record と共通の JSON_TYPEVAR[] に登録して
      # おくことで、後段の `ctx.res.json(var)` lowering（v2_e_dispatch）が
      # 型マップ変数を第 3 引数へ引き回せるようにする（wave 27 追補 H5。
      # probe /tmp/codex5/h5.awk。record 実装の要件 5 と共通機構）。
      if (bound_type ~ /^(Dict|List)</) {
        types_var = "_ds_letq_ty_" tmpvar
        JSON_TYPEVAR[AST[id,"text"]] = types_var
        v2_hoist_add(next_func, types_var)
      }
    }
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
  else if (kind == "EXPR")         v2_e_expr_stmt(id, depth)
  else if (kind == "RAWLINE")      v2_e_rawline(id)
  else if (kind == "TYPEDECL")     v2_e_typedecl(id, depth)
  else if (kind == "RECORDLIT")    v2_e_recordlit(id, depth)
  else v2_diag(AST[id,"line"], 1, "emit: unsupported node kind: " kind)
}

# EXPR 文（式文）の emit。通常は式をそのまま 1 行として出力するが、
# record フィールードット代入 `recv.field = rhs` は v2_e_expr が持たない
# DOT ノードを LHS に含むため（wave 27。plain な `.field` アクセスは
# v2_e_expr の対応外 — namespace 呼び出しは v2_scan_dotted_chain が
# 別経路で CALL に還元するため、DOT ノードとして残るのは record
# フィールードアクセスのみ）、ここで bracket 形へ lowering してから出力する。
function v2_e_expr_stmt(id, depth,    binop, lhs, rhs_id, recv, fieldnode, vtype) {
  binop = AST[id,"c1"]
  if (AST[binop,"kind"] == "BINOP" && AST[binop,"text"] == "=") {
    lhs = AST[binop,"c1"]
    if (AST[lhs,"kind"] == "DOT") {
      recv = AST[lhs,"c1"]
      fieldnode = AST[lhs,"c2"]
      if (AST[recv,"kind"] == "IDENT" && (AST[recv,"text"] in V2_ENV)) {
        vtype = V2_ENV[AST[recv,"text"]]
        if ((vtype in V2_RECORD_TYPE) && AST[fieldnode,"kind"] == "IDENT") {
          rhs_id = AST[binop,"c2"]
          print v2_indent(depth) v2_e_record_field_assign(AST[recv,"text"], vtype, AST[fieldnode,"text"], rhs_id)
          return
        }
      }
    }
  }
  print v2_indent(depth) v2_e_expr(AST[id,"c1"])
}

# record フィールードへの代入を bracket 形へ lowering する
# （varname["field"] = val / Bool フィールードは varname["field:bool"] = 0|1。
# wave 27。v1 dsl/desugar.awk:284-288,_ds_desugar_record_literal と同じ規約）。
# record リテラル構築（v2_e_recordlit）とドット代入（v2_e_expr_stmt）の
# 両方から共有する。
function v2_e_record_field_assign(varname, vtype, fname, rhs_id,    vexpr, ftype) {
  vexpr = v2_e_expr(rhs_id)
  ftype = V2_RECORD_FIELDS[vtype, fname]
  if (ftype == "Bool") {
    # I1 対応: RHS が Bool リテラル `true`/`false` のときだけ 1/0 へ畳み込む。
    # 旧実装は emit 済みテキストと "true"/"1" を文字列比較しており、
    # リテラル以外（変数参照・関数呼び出し等の正当な Bool 式）は全て
    # 一致せず無条件に 0 へ落ちていた（Codex review 指摘、probe
    # /tmp/codex5/i1.awk）。DSL の Bool は実行時 1/0 で表現されるため、
    # リテラル以外はそのまま代入すれば良い。
    if (vexpr == "true")  return varname "[\"" fname ":bool\"] = 1"
    if (vexpr == "false") return varname "[\"" fname ":bool\"] = 0"
    return varname "[\"" fname ":bool\"] = " vexpr
  }
  return varname "[\"" fname "\"] = " vexpr
}

# record リテラル `let NAME: TYPE = { ... }` の emit（wave 27。v1
# dsl/desugar_let.awk:_ds_desugar_record_literal と同じ lowering）。
function v2_e_recordlit(id, depth,    varname, typename, k, c) {
  varname = AST[id,"text"]
  typename = ""
  print v2_indent(depth) "delete " varname
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] == "TYPEANN") { typename = AST[c,"text"]; continue }
    print v2_indent(depth) v2_e_record_field_assign(varname, typename, AST[c,"text"], AST[c,"c1"])
  }
}

# classify: transform|validator|sanitizer|sink は Pass 1（check.awk の
# SIG[name,"classify"] 収集）で情報を吸収済みの関数注釈行であり、実行コード
# ではない。dsl/desugar.awk:202 と同じ正規表現でこの行だけ出力をスキップ
# する（v1 も同じ行を素通りさせず捨てている）。
#
# それ以外の RAWLINE はそのまま出力する（review C1: pipe 実装により
# classify: 行を含む関数を pipe 経由で呼ぶ入力が、以前の
# "unsupported node kind: PIPE" 診断という唯一のガードを失い、無診断で
# 構文的に無効な awk を出す regression になっていた）。
function v2_e_rawline(id,    text) {
  text = AST[id,"text"]
  if (text ~ /^[[:space:]]*classify:[[:space:]]*(transform|validator|sanitizer|sink)[[:space:]]*$/)
    return
  print text
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

function v2_e_let(id, depth,    varname, k, c, expr_id, ekind, typeann_id) {
  varname = AST[id,"text"]
  expr_id = 0; typeann_id = 0
  for (k = 1; k <= AST[id,"nc"]; k++) {
    c = AST[id,"c" k]
    if (AST[c,"kind"] == "TYPEANN") typeann_id = c
    else expr_id = c
  }
  if (expr_id == 0) return   # 裸宣言: ホイストのみ、文は出力しない
  ekind = AST[expr_id,"kind"]
  if (ekind == "DICTLIT" || ekind == "LISTLIT") {
    print v2_indent(depth) "delete " varname
    # 明示的に `let xs: List<T> = []` と注釈された空リストのみ、JSON
    # エンコーダ（json_encode_any）が配列と判定できるよう __json_type
    # マーカーを立てる（対応表移植元: dsl/desugar_let.awk:473
    # _ds_desugar_let_init。Dict は v1 でもマーカーを立てないため対称に
    # しない。型注釈なしの `let rows = []` は v1 実測でもマーカーを
    # 立てないため区別する。Codex review 4643328293 指摘）。
    # 判定は annotation の生テキスト前方一致ではなく、alias 展開後の
    # 解決型で行う（F3 対応。旧実装は `type L = List<Int>; let xs: L = []`
    # のような alias 越しの List で "List<" 前方一致が外れ、checker は
    # alias 済み List を受理しているのに marker だけ欠落していた）。
    if (ekind == "LISTLIT" && typeann_id != 0 && v2_resolve_sealed(AST[typeann_id,"text"]) ~ /^List</)
      print v2_indent(depth) varname "[\"__json_type\"] = \"array\""
  } else {
    print v2_indent(depth) varname " = " v2_e_expr(expr_id)
  }
}

# ─── `?=` 安全アンラップ文（LETQ） ─────────────────────────────────
#
# 対応表の移植元: dsl/desugar_let.awk:_ds_let_transform（?= 分岐）+
# _ds_result_ng_return。JSON デコード時の Dict/List 特殊分岐
# （result_val_into_map 等、G6）: 束縛先が Dict</List< のとき、v1 相当の
# result_val_into_map(res, out, out_types) で awk 連想配列へ復元する。
# List< はさらに json_encode_any が配列と判定できるよう __json_type
# マーカーを立てる（v2_e_let の空リストリテラル分岐と同じ規約。
# dsl/desugar_let.awk:314-315,465-473 が移植元）。
function v2_e_letq(id, depth,    varname, rhs_id, k, c, tmpvar, rhs_out, resolved, errvar, bound_type, types_var) {
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
    bound_type = LETQ_BOUND_TYPE[id]
    if (bound_type in V2_RECORD_TYPE) {
      # record 型 typed decode（`ctx.req.json<Todo>()`）。型マップ変数は
      # v1 parity で "_ds_tct_N"（v2_collect_hoists_walk が確定・ホイスト
      # 済み。wave 27）。
      print v2_indent(depth) "result_val_into_map(" tmpvar ", " varname ", " LETQ_TYPES_VAR[id] ")"
    } else if (bound_type ~ /^(Dict|List)</) {
      types_var = "_ds_letq_ty_" tmpvar
      print v2_indent(depth) "result_val_into_map(" tmpvar ", " varname ", " types_var ")"
      if (bound_type ~ /^List</)
        print v2_indent(depth) varname "[\"__json_type\"] = \"array\""
    } else {
      print v2_indent(depth) varname " = result_val(" tmpvar ")"
    }
  }
}

function v2_e_return(id, depth) {
  if (AST[id,"nc"] >= 1) print v2_indent(depth) "return " v2_e_expr(AST[id,"c1"])
  else                   print v2_indent(depth) "return"
}

function v2_e_index_assign(id, depth) {
  print v2_indent(depth) AST[id,"text"] "[" v2_e_expr(AST[id,"c1"]) "] = " v2_e_expr(AST[id,"c2"])
}

# `type NAME = Error` 宣言（G2）。トップレベル型情報のみで実行コードを
# 生成しない他の TYPEDECL（純粋な型エイリアス・レコード型）とは異なり、
# Error alias だけは v1（dsl/desugar.awk）と同じく Result の Err 側を
# 作るコンストラクタ関数 `function NAME(msg) { return result_ng("NAME",
# msg) }` を emit する必要がある。生成しないと `AuthError("msg")` 呼び出しが
# 未定義関数のランタイム fatal になるか、check.awk 側で Str 型と誤判定
# されコンパイルエラーになっていた（review 指摘）。
# ALIAS[name] は check.awk の v2_collect が既に埋めている（v2_check() は
# v2_emit() より前に実行される）。
function v2_e_typedecl(id, depth,    name, typeexpr) {
  name = AST[id,"text"]
  if (name == "" || !(name in ALIAS)) return
  typeexpr = ALIAS[name]
  if (typeexpr ~ /^Error([[:space:]]|$)/) {
    print v2_indent(depth) "function " name "(msg) { return result_ng(\"" name "\", msg) }"
    return
  }
  # 非 Error alias（`type Status = Int | Str` 等）の validator constructor
  # （wave 27 追補 H4。v1 dsl/desugar.awk の union/intersection alias 分岐の
  # 移植。docs/dsl.md:512 に文書化された形。この emit が無いと
  # `Status(42)` のような constructor 呼び出しがそのまま素通しされ、
  # 未定義関数のランタイム fatal になっていた）。
  print v2_indent(depth) "function " name "(val) { if (type::accepts(\"" typeexpr \
    "\", val)) return val; return result_ng(\"TypeError:" name "\", \"expected " typeexpr ", got \" val) }"
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
# when の 1 腕を emit する（v2_e_when から ok/some 腕・その他腕の両方の
# 走査で呼ばれる共通処理）。
function v2_e_when_arm(arm, tmp, is_option, depth, opened,    pat, blk, tag, \
                        typeann_id, bind_id, pc, j, bind_name, cond) {
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
    # 述語・アンラップ関数は腕自身のタグ文字列ではなく対象式の実家系
    # （is_option）で選ぶ（v1 実測: dsl/desugar_match.awk は ok/some を
    # 単一の "ok" スロットへ merge し、対象型から決めた option_val/
    # result_val を使う。旧実装は tag=="ok" かどうかだけで判定していたため、
    # `Result` を `some` 腕 + `ng` catch-all で受けると、実際は
    # result_ok/result_val であるべき箇所に option_some/option_val を
    # 誤って emit していた。Codex review 4643328293 指摘）。
    cond = is_option ? "option_some(" tmp ")" : "result_ok(" tmp ")"
    print v2_indent(depth) (opened ? "} else if (" : "if (") cond ") {"
    if (bind_name != "")
      print v2_indent(depth + 1) bind_name " = " (is_option ? "option_val(" tmp ")" : "result_val(" tmp ")")
    v2_e_block(blk, depth + 1)
  } else if (tag == "ng" && typeann_id != 0) {
    print v2_indent(depth) (opened ? "} else if (" : "if (") "awk::result_err_type(" tmp ") == \"" AST[typeann_id,"text"] "\") {"
    if (bind_name != "") print v2_indent(depth + 1) bind_name " = result_err(" tmp ")"
    v2_e_block(blk, depth + 1)
  } else {
    # catch-all（無型 ng / none / default / _）。check.awk の網羅性検査で
    # 他の ng 腕に対しては必ず最後であることが保証されている。
    print v2_indent(depth) (opened ? "} else {" : "if (1) {")
    if (bind_name != "" && !is_option)
      print v2_indent(depth + 1) bind_name " = result_err(" tmp ")"
    v2_e_block(blk, depth + 1)
  }
}

function v2_e_when(id, depth,    tmp, ttype, is_option, k, arm, pat, tag, ok_k) {
  tmp = WHEN_TMPVAR[id]
  print v2_indent(depth) tmp " = " v2_e_expr(AST[id,"c1"])
  ttype = v2_resolve_sealed(TYPEOF[AST[id,"c1"]])
  is_option = (ttype ~ /^Option</)

  # 対象式の型が未解決（未注釈関数呼び出しなど）だと ttype は Unknown/Any の
  # ままで is_option が常に 0（Result 扱い）に落ちる。腕タグに some/none が
  # あれば Option 対象と確定できるので、型が解決できない場合のみ腕タグに
  # フォールバックする（when_triple_nested で発覚した誤 result_ok emit の修正）。
  if (ttype !~ /^(Option|Result)</) {
    for (k = 2; k <= AST[id,"nc"]; k++) {
      arm = AST[id,"c" k]
      pat = AST[arm,"c1"]
      tag = AST[pat,"text"]
      if (tag == "some" || tag == "none") { is_option = 1; break }
    }
  }

  # ok/some 腕は常に最初の条件として emit する（Codex review 4642730010
  # 指摘 + v1 実測: dsl/desugar_match.awk は ok/some を専用スロット
  # （_DS_match_ok_var/_DS_match_branch）に保持し、ng 腕の登録配列とは
  # 独立に扱うため、ソース上で catch-all（default:/ng e:）が ok より前に
  # 書かれていても常に ok の成功条件を先頭で判定する。v2 が単純にソース
  # 順で if/else if チェーンを組み立てると、catch-all の `if (1)` が
  # 先に確定し後続の ok 腕が到達不能になっていた）。
  ok_k = 0
  for (k = 2; k <= AST[id,"nc"]; k++) {
    arm = AST[id,"c" k]
    pat = AST[arm,"c1"]
    tag = AST[pat,"text"]
    if (tag == "ok" || tag == "some") { ok_k = k; break }
  }

  if (ok_k != 0) {
    v2_e_when_arm(AST[id,"c" ok_k], tmp, is_option, depth, 0)
    for (k = 2; k <= AST[id,"nc"]; k++) {
      if (k == ok_k) continue
      v2_e_when_arm(AST[id,"c" k], tmp, is_option, depth, 1)
    }
  } else {
    # ok/some 腕が無い場合も、成功時は何もしない暗黙の腕を合成してから
    # catch-all 腕チェーンへつなぐ（v1 実測: dsl/desugar_match.awk は
    # ng のみの match でも常に `if (result_ok(tmp)) {\n} else {...}` の形に
    # ラップし、成功値では catch-all 本体を実行しない。旧実装は catch-all
    # を `if (1) {` として無条件展開しており、成功値でも result_err/
    # ng ハンドラが走っていた。Codex review 4643328293 指摘）。
    print v2_indent(depth) "if (" (is_option ? "option_some(" tmp ")" : "result_ok(" tmp ")") ") {"
    for (k = 2; k <= AST[id,"nc"]; k++)
      v2_e_when_arm(AST[id,"c" k], tmp, is_option, depth, 1)
  }
  print v2_indent(depth) "}"
}

# ─── 式 emit ────────────────────────────────────────────────────

# BINOP の子ノード child_id を emit し、必要なら丸括弧で包む。
# parent_op: 親 BINOP の演算子テキスト（"CONCAT" 含む）。is_right: child が
# 右オペランドなら 1。子が BINOP でも UNOP（NEG/NOT）でもない、または
# 優先順位表（rpn.awk の V2_OP_PREC/V2_OP_ASSOC、グローバル共有）に無い
# 演算子（生成できないはず）なら素通しする。子の優先順位が親より低い場合、
# または同順位で親が左結合かつ子が右オペランドの場合（`a - (b - c)` を
# `a - b - c` に潰さないため）に括弧を付ける（Codex review 指摘,
# botfix wave 19）。
# 子が UNOP（NEG/NOT）の場合も同じ優先順位比較を適用する（F1 (b) 対応:
# NEG/NOT を awk 準拠の優先順位（`*`/`/`より高く`^`より低い）に変更した
# ため、`(-a) ^ 2` のように明示括弧で NEG を先に確定させた AST
# （BINOP ^ の子が UNOP NEG）を無条件に "-a^2" と素通しすると、awk 側は
# `^` が NEG より高優先度と解釈して `-(a^2)` に化けてしまう。旧実装は
# BINOP 子しか判定しておらず UNOP 子は無条件素通しだった）。
function v2_e_binop_child(child_id, parent_op, is_right,    s, ctext, cprec, pprec, assoc, ckind) {
  s = v2_e_expr(child_id)
  # 親が単項 NEG/NOT で、生成された子テキストが同じ演算子文字で始まる場合
  # （`-(-a)` の子が UNOP NEG で `-a` を返す、またはリテラル畳み込みで
  # 既に "-5" のような負数テキストが返る場合）、括弧で区切らずに連結すると
  # `--a` になり gawk が前置デクリメント演算子として解釈してしまう
  # （Codex review 指摘: 変数を書き換えた上で `a - 1` を返す誤動作になる）。
  # NOT/NOT の "!!a" は awk 上は無害だが、同じ規則で括弧を付けても
  # 意味は変わらないため対称に扱う。
  if ((parent_op == "NEG" && substr(s, 1, 1) == "-") || \
      (parent_op == "NOT" && substr(s, 1, 1) == "!")) {
    return "(" s ")"
  }
  ckind = AST[child_id,"kind"]
  if (ckind != "BINOP" && ckind != "UNOP") return s
  ctext = AST[child_id,"text"]
  cprec = V2_OP_PREC[ctext]
  pprec = V2_OP_PREC[parent_op]
  if (cprec == "" || pprec == "") return s
  if (cprec + 0 < pprec + 0) return "(" s ")"
  if (cprec + 0 == pprec + 0) {
    assoc = V2_OP_ASSOC[parent_op]
    # 左結合演算子は右オペランドが同順位のとき（`a - (b - c)` を
    # `a - b - c` に潰さないため）、右結合演算子は左オペランドが
    # 同順位のとき（`(a ^ b) ^ c` を `a ^ b ^ c` に潰さないため。
    # rev-pre12 review Critical 2）に括弧が要る。
    if (is_right && assoc == "L") return "(" s ")"
    if (!is_right && assoc == "R") return "(" s ")"
  }
  return s
}

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
    #
    # 子が BINOP のときは演算子の優先順位を比較し、ソース側の丸括弧で
    # 意図されたグルーピングを保つ（Codex review 指摘, botfix wave 19。
    # 従来は子の優先順位を無視して常にフラットに出力しており、
    # `(a + b) * c` が `a + b * c` に化けて意味が変わっていた）。
    if (AST[id,"text"] == "CONCAT")
      return v2_e_binop_child(AST[id,"c1"], "CONCAT", 0) " " v2_e_binop_child(AST[id,"c2"], "CONCAT", 1)
    return v2_e_binop_child(AST[id,"c1"], AST[id,"text"], 0) " " AST[id,"text"] " " v2_e_binop_child(AST[id,"c2"], AST[id,"text"], 1)
  }
  if (kind == "UNOP") {
    # rpn.awk は単項 -/! を内部マーカー "NEG"/"NOT" として演算子スタックに
    # 積む（v2_shunt_expr）。AST の text にはこのマーカー文字列がそのまま
    # 残るため、実際の awk 演算子へ写像してから出力する（さもないと
    # `return -a` が `return NEGa` という無関係の識別子参照になる。
    # Codex review 指摘, botfix wave 19）。
    #
    # オペランドが BINOP のときは v2_e_binop_child で括弧要否を判定する
    # （rev-pre12 review Critical 1）。NEG/NOT は演算子表で優先順位 75
    # （`^`=80 より低く `*`/`/`=70 より高い、awk 準拠。F1 (b) 対応）に
    # 登録されているため、`*`/`/`/`+`/`-`/`||`/`&&` 等の低優先度 BINOP
    # オペランドには常に括弧が付き、`^` オペランドには付かない（awk
    # 自身が `-a^2` を `-(a^2)` と解釈するのと一致させるため）。旧実装は
    # ここを無条件 v2_e_expr にしていたため `!(a && b)` が `!a && b` に、
    # `-(a + b)` が `-a + b` になり、無診断で意味が変わっていた。
    return (AST[id,"text"] == "NEG" ? "-" : "!") v2_e_binop_child(AST[id,"c1"], AST[id,"text"], 0)
  }
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
# pipe RHS の実引数リストを組み立てる。generic dispatch（rpn.awk が
# `f<T>(...)` を `f_t("T", ...)` へ正規化した名前。SIG の規約上 arg1 が
# 型引数文字列で arg2 以降が実引数）は、その型引数（rhs_id の c1）を
# 常に先頭に残し、pipe の LHS はその直後（実引数の先頭）に挿入する
# （Codex review 指摘, botfix wave 19。旧実装は generic 判定をせず LHS を
# 無条件に全引数の前へ差し込んでいたため、`raw |> json.decode<T>()` が
# `json::dispatch("decode_t", raw, "T")` という型引数と入力が入れ替わった
# 呼び出しになっていた）。
function v2_e_pipe_args(rhs_id, lhs_out, is_generic,    k, n, s) {
  n = AST[rhs_id,"nc"]
  if (is_generic && n >= 1) {
    s = v2_e_expr(AST[rhs_id,"c1"]) ", " lhs_out
    for (k = 2; k <= n; k++) s = s ", " v2_e_expr(AST[rhs_id,"c" k])
  } else {
    s = lhs_out
    for (k = 1; k <= n; k++) s = s ", " v2_e_expr(AST[rhs_id,"c" k])
  }
  return s
}

function v2_e_pipe(id,    lhs_id, rhs_id, lhs_out, name, dot, ns, path, is_generic, tmpvar, call_expr) {
  lhs_id = AST[id,"c1"]
  rhs_id = AST[id,"c2"]
  lhs_out = v2_e_expr(lhs_id)
  name = AST[rhs_id,"text"]
  # check.awk の未登録 generic dispatch 判定（BJ）と同じ規約: 名前が "_t"
  # で終わるものだけを generic 呼び出しとみなす。
  is_generic = (name ~ /_t$/)

  if (name == "option.some") {
    call_expr = "option_some_make(" v2_e_pipe_args(rhs_id, lhs_out, 0) ")"
  } else if (name == "ctx.res.json" && AST[rhs_id,"nc"] == 0 && v2_resolve_sealed(TYPEOF[lhs_id]) ~ /^(Dict|List)</) {
    # ctx.res.json(dictOrList) の Dict/List 短絡を pipe 経路にも適用する
    # （coderabbit review 4642730010 指摘。旧実装は v2_e_dispatch の直呼び
    # 経路にしかこの分岐が無く、`x |> ctx.res.json()` だけ json(res, x) では
    # なく ctx::dispatch("res.json", x) に落ちて出力形式がずれていた）。
    # TYPEOF は alias 展開前の生テキスト（`type L = List<Int>` の "L" 等）を
    # 保持し得るため v2_resolve_sealed で展開してから判定する（F3 対応）。
    call_expr = "json(res, " lhs_out ")"
  } else if (name == "ctx.res.redirect" && AST[rhs_id,"nc"] == 0) {
    # ctx.res.redirect(url) の直呼び特例（status 302 既定付与）を pipe
    # 経路にも適用する（Codex review 指摘, botfix wave 19。旧実装は
    # v2_e_dispatch の直呼び経路にしかこの分岐が無く、`url |> ctx.res.redirect()`
    # は status 引数無しで dispatch され、ctx が arity 2 で登録している
    # res.redirect の実引数が 1 個足りなくなっていた）。
    call_expr = "ctx::dispatch(\"res.redirect\", " lhs_out ", 302)"
  } else {
    dot = index(name, ".")
    if (dot > 0) {
      ns   = substr(name, 1, dot - 1)
      path = substr(name, dot + 1)
      call_expr = ns "::dispatch(\"" path "\", " v2_e_pipe_args(rhs_id, lhs_out, is_generic) ")"
    } else {
      call_expr = name "(" v2_e_pipe_args(rhs_id, lhs_out, is_generic) ")"
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
# AST 部分木 id が PIPE/COALESCE を含むか（評価時に一時変数への代入行を
# 無条件 print する副作用を持つか）を再帰的に調べる。
function v2_expr_has_side_effect(id,    k) {
  if (AST[id,"kind"] == "PIPE" || AST[id,"kind"] == "COALESCE") return 1
  for (k = 1; k <= AST[id,"nc"]; k++)
    if (v2_expr_has_side_effect(AST[id,"c" k])) return 1
  return 0
}

function v2_e_coalesce(id,    tmp, lhs_out, rhs_out) {
  tmp = TC_TMPVAR[id]
  lhs_out = v2_e_expr(AST[id,"c1"])
  print v2_indent(V2_CUR_DEPTH) tmp " = " lhs_out
  # RHS が PIPE/COALESCE を含む場合、それらの evaluate（v2_e_expr）は自身の
  # 一時変数代入行を print という副作用で先出しする。単純な三項式のテキスト
  # に埋め込むと、その print は LHS が非空でも無条件に実行されてしまい
  # `??` の短絡評価（LHS 非空なら RHS を評価しない）に反する（Codex review
  # 指摘, botfix wave 19）。RHS にこの副作用がある場合だけ、tmp が空のとき
  # のみ実行する if ブロックへ評価を遅延させる。副作用の無い通常の RHS
  # （リテラル・単純な CALL 等）は従来どおり三項式のまま出力する
  # （awk の `? :` 自体は短絡評価のため、単純な CALL は元々問題ない）。
  if (v2_expr_has_side_effect(AST[id,"c2"])) {
    print v2_indent(V2_CUR_DEPTH) "if (" tmp " == \"\") {"
    V2_CUR_DEPTH++
    rhs_out = v2_e_expr(AST[id,"c2"])
    print v2_indent(V2_CUR_DEPTH) tmp " = " rhs_out
    V2_CUR_DEPTH--
    print v2_indent(V2_CUR_DEPTH) "}"
    return tmp
  }
  rhs_out = v2_e_expr(AST[id,"c2"])
  return "(" tmp " != \"\" ? " tmp " : " rhs_out ")"
}

# ドット記法呼び出し -> ns::dispatch("path", args...) への変換。
# 対応表の移植元: dsl/desugar_dot.awk, docs/dsl.md 296-344 行。
function v2_e_dispatch(id,    name, dot, ns, path, s, k, arg1type, arg1name) {
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
    # alias 展開後の解決型で判定する（F3 対応。`type L = List<Int>; let
    # xs: L = []` の xs は TYPEOF が未展開の "L" のままのため、生テキスト
    # 前方一致では通らず、直接 `List<Int>` と書いた場合とだけ lowering
    # 分岐が変わっていた）。
    arg1type = v2_resolve_sealed(TYPEOF[AST[id,"c1"]])
    if (arg1type ~ /^(Dict|List)</ || arg1type in V2_RECORD_TYPE) {
      # typed decode（`?=` + result_val_into_map、G6）由来の変数は型マップ
      # 変数を第 3 引数に引き回す（JSON_TYPEVAR。wave 27 追補 H5:
      # Dict/List の `?=` materialization でもこの型マップを渡さないと
      # 復元後の値が文字列扱いのまま json_encode_any へ渡り型が壊れる。
      # probe /tmp/codex5/h5.awk。record 実装の要件 5 と共通機構）。
      # record リテラル由来（typed decode を経ない）や空リテラル
      # （`let xs: List<T> = []`）は型マップが無いため 2 引数のまま
      # （record_basic / emit_dict_basic 等の golden）。
      arg1name = AST[AST[id,"c1"],"text"]
      if (AST[AST[id,"c1"],"kind"] == "IDENT" && (arg1name in JSON_TYPEVAR))
        return "json(res, " v2_e_expr(AST[id,"c1"]) ", " JSON_TYPEVAR[arg1name] ")"
      return "json(res, " v2_e_expr(AST[id,"c1"]) ")"
    }
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
function v2_e_split_interp(content, parts,    i, c, len, cur, depth, n, in_str, in_regex, prevc) {
  len = length(content)
  cur = ""; depth = 0; n = 0; in_str = 0; in_regex = 0
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
      # 補間式内の文字列リテラル（`#{ f("}") }` 等）は深度計算から除外する
      # （coderabbit review 4642730010 指摘。文字列内の `{`/`}` が補間の
      # 終端記号として誤カウントされると、式が途中で切れてしまう。
      # v2_e_expand_nested_str 側の生の `"` トグル・`\X` 2 文字エスケープ
      # 規約に合わせ、ここでも同じ規約でスキップする）。
      # 正規表現リテラル（`#{x ~ /[}]/}` 等）も同じ理由で深度計算から除外
      # する（F2 対応。旧実装は文字列リテラルしか除外しておらず、正規表現
      # 内の `}` が補間の終端記号として誤カウントされ、式が途中で切れて
      # 壊れた awk を無診断で出力していた）。判定は v2_e_interp_scan_calls
      # と同じ「直前の非空白文字が値で終わっていなければ `/` は正規表現の
      # 開始」ヒューリスティック（v2_e_interp_prev_nonspace）を使う。
      if (in_str) {
        cur = cur c
        if (c == "\\" && i < len) { cur = cur substr(content, i + 1, 1); i++ }
        else if (c == "\"") in_str = 0
      } else if (in_regex) {
        cur = cur c
        if (c == "\\" && i < len) { cur = cur substr(content, i + 1, 1); i++ }
        else if (c == "/") in_regex = 0
      } else if (c == "\"") {
        in_str = 1
        cur = cur c
      } else if (c == "/") {
        prevc = v2_e_interp_prev_nonspace(content, i)
        if (prevc !~ /[A-Za-z0-9_)\]"]/) in_regex = 1
        cur = cur c
      } else if (c == "{") { depth++; cur = cur c }
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
    if (!matched) {
      # 補間内 pipe の RHS が呼び出し形式でない場合（`"#{x |> y}"`）、
      # AST 経路の v2_check_pipe_rules と同じ規則で診断する（Codex review
      # 4642730010 指摘。旧実装はここで DSL の `|>` をそのまま出力に
      # 素通ししており、コンパイルは成功するのに gawk が構文解析できない
      # awk が生成されていた）。
      v2_diag(line, 1, "pipe right-hand side must be a call (`expr |> f(args)`)")
      return lhs_out
    }

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

# text 中の位置 pos より前で最初に見つかる非空白文字を返す（無ければ ""）。
# v2_e_interp_scan_calls の正規表現リテラル判定ヒューリスティックが使う。
function v2_e_interp_prev_nonspace(text, pos,    j, c) {
  for (j = pos - 1; j >= 1; j--) {
    c = substr(text, j, 1)
    if (c !~ /[ \t]/) return c
  }
  return ""
}

# text（#{ } の直接ネストを既に展開済み）を左から走査し、識別子で始まる
# call 形（ドット連結・generic を含む）を見つけたら都度ディスパッチ変換に
# 置き換える。文字列リテラル内部はスキップする（誤検出防止）。正規表現
# リテラル内部もスキップする（Codex review 4642730010 指摘: `x ~
# /safe.html.raw()/` のようなパターン中の呼び出し風テキストを書き換えると
# 正規表現の中身が変わってしまう）。awk の `/` は直前トークンが値
# （識別子・数字・`)`・`]`・文字列末尾の `"`）で終わる場合は除算、それ以外
# （演算子・開き括弧・行頭など）の直後は正規表現の開始という構文的な曖昧さが
# あるため、直前の非空白文字で判定する保守的なヒューリスティックを使う
# （完全な bracket 式 `[...]` 内の `/` 対応までは行わない）。
function v2_e_interp_scan_calls(text, line,    out, i, n, c, in_str, in_regex, prevc, chunk_start, \
                                 sub_i, name, genarg, open_rel, close_rel, abs_close, \
                                 argstr, cargs, ncargs, k, call_out) {
  out = ""; n = length(text); i = 1; in_str = 0; in_regex = 0; chunk_start = 1
  while (i <= n) {
    c = substr(text, i, 1)
    if (in_str) {
      if (c == "\\" && i < n) { i += 2; continue }
      if (c == "\"") in_str = 0
      i++
      continue
    }
    if (in_regex) {
      if (c == "\\" && i < n) { i += 2; continue }
      if (c == "/") in_regex = 0
      i++
      continue
    }
    if (c == "\"") { in_str = 1; i++; continue }
    if (c == "/") {
      prevc = v2_e_interp_prev_nonspace(text, i)
      if (prevc !~ /[A-Za-z0-9_)\]"]/) { in_regex = 1; i++; continue }
    }
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
