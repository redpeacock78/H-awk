# DSL Union型 + 関数返り値型アノテーション 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hawk DSL に Union 型と関数返り値型アノテーション (`-> Type`) を追加し、desugar 時の静的型チェックを強化する。

**Architecture:** Phase A-D の4段階で実装する。A: Union 型基盤 (type.awk拡張)、B: literal inference + ?? union 推論、C: 関数アノテーション + 2パス sig 収集、D: return/call チェック。型情報は gawk 出力に含まれず、desugar 時のみ保持する。

**Tech Stack:** gawk (GAWK 拡張: `@namespace`, `match(str, re, arr)`)、bash テスト (`tests/unit/dsl/run.sh`)

---

## ファイル構成

| ファイル | 変更種別 | 内容 |
|----------|----------|------|
| `dsl/type.awk` | Modify | Union parser + `type::accepts` を追加（`type` namespace） |
| `dsl/sig.awk` | Modify | `_DS_TYPE_ALIAS` テーブル追加、`hawk.app.listen` arg を `Port` に変更 |
| `dsl/typecheck.awk` | Modify | `_ds_typecheck_call` を `type::accepts` 対応に更新、`_ds_typecheck_plain_call` 追加、return check 追加 |
| `dsl/desugar_let.awk` | Modify | NumericStr 推論追加、`??` union 推論、Union 型アノテーション対応 |
| `dsl/desugar.awk` | Modify | `_ds_is_func_def` 拡張、2パス sig 収集、`_ds_parse_func_params` 追加 |
| `tests/unit/dsl/union_*/` | Create | Phase A-B テスト |
| `tests/unit/dsl/func_*/` | Create | Phase C-D テスト |
| `tests/unit/dsl/unwrap_union_*/` | Create | ?= + Union テスト |

---

## Phase A: Union 型基盤

### Task 1: Union パーサーを `dsl/type.awk` に追加

**Files:**
- Modify: `dsl/type.awk`
- Create: `tests/unit/dsl/union_normalize_basic/input.awk`
- Create: `tests/unit/dsl/union_normalize_basic/expected.awk`
- Create: `tests/unit/dsl/union_generic_top_level_split/input.awk`
- Create: `tests/unit/dsl/union_generic_top_level_split/expected.awk`

> **テスト形式の説明**:
> - `input.awk` は Hawk DSL ソース (通常の hawk 構文)
> - `expected.awk` は desugar 後の gawk 出力（`# line ...` コメントは除去される）
> - `expected_stderr` は stderr に含まれるべき文字列（エラーテスト用）
> - `tests/unit/dsl/run.sh` でテスト実行

- [ ] **Step 1: テストを書く (union_normalize_basic — desugar 後も型なしで出力される確認)**

```
# tests/unit/dsl/union_normalize_basic/input.awk
function setup() {
  let port: Int | Str = 8080
}
```

```
# tests/unit/dsl/union_normalize_basic/expected.awk
function setup(    port) {
  port = type::coerce(8080, "Int")
}
```

> 注: `let port: Int | Str = 8080` — 8080 は `Int`、`Int` は `Int|Str` のmemberなのでOK。coerce は declared の1番目のプリミティブで行う（MVPでは `Int` で coerce）。

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep union_normalize_basic
```

Expected: `FAIL: union_normalize_basic`

- [ ] **Step 3: `dsl/type.awk` に Union 関数を追加**

`dsl/type.awk` の末尾（`@namespace "type"` ブロック内）に以下を追加:

```awk
# type::split_union -- top-level の | で分割（<...> 内は分割しない）
# out[] に分割結果を格納し、count を返す
function split_union(t, out,    i, c, depth, cur, n) {
    n = 0; depth = 0; cur = ""
    for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if      (c == "<") depth++
        else if (c == ">") depth--
        else if (c == "|" && depth == 0) {
            out[++n] = _ds_trim_type(cur)
            cur = ""
            continue
        }
        cur = cur c
    }
    if (length(_ds_trim_type(cur)) > 0) out[++n] = _ds_trim_type(cur)
    return n
}

function _ds_trim_type(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

# type::is_union -- Union 型か判定
function is_union(t,    out, n) {
    n = split_union(t, out)
    return (n > 1)
}

# type::normalize -- 正規化: ソート・重複削除・スペースなし join
function normalize(t,    out, n, i, j, sorted, seen, result) {
    n = split_union(t, out)
    if (n == 1) return out[1]
    # 重複削除 + sort (bubble sort, small n)
    for (i = 1; i <= n; i++) seen[out[i]] = 1
    n = 0
    for (i in seen) sorted[++n] = i
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (sorted[i] > sorted[j]) { result = sorted[i]; sorted[i] = sorted[j]; sorted[j] = result }
    result = sorted[1]
    for (i = 2; i <= n; i++) result = result "|" sorted[i]
    return result
}

# type::union_of -- 2型を union 化して正規化
function union_of(a, b) {
    if (a == "" || a == "Any") return b
    if (b == "" || b == "Any") return a
    if (a == b) return a
    return normalize(a "|" b)
}
```

- [ ] **Step 4: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "union_normalize|FAIL|PASS" | head -20
```

Expected: `PASS: union_normalize_basic` (他のテストに影響なし)

- [ ] **Step 5: generic top-level split テストを追加**

```
# tests/unit/dsl/union_generic_top_level_split/input.awk
function handler() {
  let body ?= ctx.req.json()
}
```

```
# tests/unit/dsl/union_generic_top_level_split/expected.awk
function handler(    _ds_tc_1, body) {
  _ds_tc_1 = ctx::dispatch("req.json")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  body = result_val(_ds_tc_1)
}
```

> これは `Result<Map, Error>` が1つの型として扱われることの確認（split しない）。

- [ ] **Step 6: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "union_generic|FAIL" | head -10
```

Expected: `PASS: union_generic_top_level_split`

- [ ] **Step 7: コミット**

```bash
git add dsl/type.awk tests/unit/dsl/union_normalize_basic/ tests/unit/dsl/union_generic_top_level_split/
git commit -m "feat(dsl): add Union type parser to type.awk (split_union, normalize, union_of)"
```

---

### Task 2: Alias テーブルと `type::accepts` を追加

**Files:**
- Modify: `dsl/sig.awk`
- Modify: `dsl/type.awk`
- Create: `tests/unit/dsl/union_alias_port_ok/input.awk`
- Create: `tests/unit/dsl/union_alias_port_ok/expected.awk`
- Create: `tests/unit/dsl/union_actual_all_members_reject/input.awk`
- Create: `tests/unit/dsl/union_actual_all_members_reject/expected_stderr`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/union_alias_port_ok/input.awk
BEGIN {
  hawk.app.listen(8080)
}
```

```
# tests/unit/dsl/union_alias_port_ok/expected.awk
BEGIN {
  hawk::dispatch("app.listen", 8080)
}
```

```
# tests/unit/dsl/union_actual_all_members_reject/input.awk
function handler() {
  let x: Int = ctx.req.form("title")
}
```

```
# tests/unit/dsl/union_actual_all_members_reject/expected_stderr
type mismatch: cannot assign Int to
```

> 注: `ctx.req.form` は `Str` を返す。`expected_stderr` は部分一致で判定される。

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "union_alias|union_actual"
```

Expected: 両方 FAIL

- [ ] **Step 3: `dsl/sig.awk` に `_DS_TYPE_ALIAS` テーブルを追加し、`hawk.app.listen` の arg を `Port` に変更**

`dsl/sig.awk` の `BEGIN {` ブロック先頭に追加:

```awk
    # Type aliases
    _DS_TYPE_ALIAS["Port"]        = "Int|NumericStr|Str"
    _DS_TYPE_ALIAS["HandlerName"] = "Str"
```

`hawk.app.listen` の arg 型を変更:

```awk
    # before:
    _DS_SIG_ARG["hawk.app.listen", 1] = "Int"
    # after:
    _DS_SIG_ARG["hawk.app.listen", 1] = "Port"
```

- [ ] **Step 4: `dsl/type.awk` に `type::expand_alias` と `type::accepts` を追加**

`dsl/type.awk` に追加（`type` namespace 内）:

```awk
# type::expand_alias -- alias を展開（展開できなければそのまま返す）
function expand_alias(t) {
    if (t in awk::_DS_TYPE_ALIAS) return awk::_DS_TYPE_ALIAS[t]
    return t
}

# type::accepts -- expected が actual を受け入れるか判定
# 返り値: 1=OK, 0=NG
function accepts(expected, actual,    eparts, apart, en, an, i, j) {
    if (expected == actual)  return 1
    if (expected == "Any")   return 1
    if (actual   == "Any")   return 1
    if (actual   == "")      return 1

    # alias 展開
    if (expected in awk::_DS_TYPE_ALIAS) return accepts(awk::_DS_TYPE_ALIAS[expected], actual)
    if (actual   in awk::_DS_TYPE_ALIAS) return accepts(expected, awk::_DS_TYPE_ALIAS[actual])

    en = split_union(expected, eparts)
    an = split_union(actual,   apart)

    if (en > 1 && an == 1) {
        # expected が union: memberのどれかが actual を受理
        for (i = 1; i <= en; i++)
            if (accepts(eparts[i], actual)) return 1
        return 0
    }

    if (an > 1) {
        # actual が union: 全memberが expected に受理される必要あり
        for (j = 1; j <= an; j++)
            if (!accepts(expected, apart[j])) return 0
        return 1
    }

    # HandlerName は Str を受け入れる（既存の特殊ケース）
    if (expected == "HandlerName" && actual == "Str") return 1

    return 0
}
```

- [ ] **Step 5: `dsl/typecheck.awk` の `_ds_typecheck_call` を `type::accepts` を使うよう更新**

`_ds_typecheck_call` の型チェック部分を変更:

```awk
# before:
        if (actual == "" || actual == "Any" || actual == expected) continue
        if (expected == "HandlerName" && actual == "Str") continue
        print "dsl error: ..." > "/dev/stderr"
        _DS_had_error = 1

# after:
        if (actual == "" || type::accepts(expected, actual)) continue
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " argument " i " expects " expected ", got " actual > "/dev/stderr"
        _DS_had_error = 1
```

- [ ] **Step 6: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "union_alias|union_actual|FAIL"
```

Expected: `PASS: union_alias_port_ok`, `PASS: union_actual_all_members_reject`

既存テストも壊れていないことを確認:

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -5
```

Expected: `X passed, 0 failed`

- [ ] **Step 7: コミット**

```bash
git add dsl/sig.awk dsl/type.awk dsl/typecheck.awk \
    tests/unit/dsl/union_alias_port_ok/ tests/unit/dsl/union_actual_all_members_reject/
git commit -m "feat(dsl): add type alias table and type::accepts with Union support"
```

---

## Phase B: literal inference + ?? union 推論

### Task 3: NumericStr 推論を `_ds_infer_type` に追加

**Files:**
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/union_numericstr_ok/input.awk`
- Create: `tests/unit/dsl/union_numericstr_ok/expected.awk`
- Create: `tests/unit/dsl/union_alias_port_bad_literal/input.awk`
- Create: `tests/unit/dsl/union_alias_port_bad_literal/expected_stderr`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/union_numericstr_ok/input.awk
BEGIN {
  hawk.app.listen("8080")
}
```

```
# tests/unit/dsl/union_numericstr_ok/expected.awk
BEGIN {
  hawk::dispatch("app.listen", "8080")
}
```

```
# tests/unit/dsl/union_alias_port_bad_literal/input.awk
BEGIN {
  hawk.app.listen("hello")
}
```

```
# tests/unit/dsl/union_alias_port_bad_literal/expected_stderr
hawk.app.listen argument 1 expects Port, got Str
```

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "numericstr|bad_literal"
```

Expected: 両方 FAIL（`"8080"` が現在 `Str` として推論されるため）

- [ ] **Step 3: `dsl/desugar_let.awk` の `_ds_infer_type` を更新**

```awk
# before:
    if (expr ~ /^".*"$/) return "Str"

# after (NumericStr を先にチェック):
    if (expr ~ /^"[0-9]+"$/) return "NumericStr"
    if (expr ~ /^".*"$/)     return "Str"
```

- [ ] **Step 4: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "numericstr|bad_literal|FAIL"
```

Expected: `PASS: union_numericstr_ok`, `PASS: union_alias_port_bad_literal`

- [ ] **Step 5: コミット**

```bash
git add dsl/desugar_let.awk tests/unit/dsl/union_numericstr_ok/ tests/unit/dsl/union_alias_port_bad_literal/
git commit -m "feat(dsl): add NumericStr literal inference for Port type checking"
```

---

### Task 4: `let` の Union 型アノテーション対応

**Files:**
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/union_let_basic_ok/input.awk`
- Create: `tests/unit/dsl/union_let_basic_ok/expected.awk`
- Create: `tests/unit/dsl/union_let_basic_error/input.awk`
- Create: `tests/unit/dsl/union_let_basic_error/expected_stderr`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/union_let_basic_ok/input.awk
function handler() {
  let port: Int | Str = 8080
}
```

```
# tests/unit/dsl/union_let_basic_ok/expected.awk
function handler(    port) {
  port = 8080
}
```

> 注: Union 型の `let` では `type::coerce` を呼ばない（coerce 先が一意でないため）。型チェックのみ行い、代入はそのまま。

```
# tests/unit/dsl/union_let_basic_error/input.awk
function handler() {
  let port: Int | Str = true
}
```

```
# tests/unit/dsl/union_let_basic_error/expected_stderr
type mismatch: cannot assign Bool to Int|Str
```

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "union_let"
```

Expected: 両方 FAIL（現在の regex が `Int | Str` をキャプチャできない）

- [ ] **Step 3: `dsl/desugar_let.awk` の `_ds_let_transform` を Union 型対応に更新**

型付き `let` のパターンを拡張する。現在の正規表現:

```awk
/^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/
```

Union 型（スペース、`|`、`<>` を含む）に対応する新しい型キャプチャロジックを `_ds_extract_type_and_rhs` 関数として分離:

```awk
# _ds_extract_type_and_rhs: "let name: TYPE = RHS" から TYPE と RHS を取り出す
# 返り値: 1=成功, 0=失敗。out_type, out_rhs に格納
function _ds_extract_type_and_rhs(decl, out_type, out_rhs,    eq_pos, type_part, rhs_part, m) {
    # "name: TYPE = RHS" 形式を想定 (let と name は除去済)
    # "=" で分割するが、型内の "=>" などを除くため単純 index は使えない
    # ": " の後から "=" の前を型とする
    if (!match(decl, /^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.+)[[:space:]]*=[[:space:]]*(.+)$/, m))
        return 0
    out_type[1] = type::normalize(m[2])
    out_rhs[1]  = _ds_trim(m[3])
    return 1
}
```

> **注意**: 上記の正規表現は `=` が型内に含まれない前提（Union 型には `=` が入らない）。`Result<T, E>` や `Option<T>` でも `=` は含まれないためOK。

型付き `let` のブランチを置き換える:

```awk
  # Type-annotated assignment: let name: Type = expr  (Type は Union も可)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*/, arr)) {
    indent = arr[1]; varname = arr[2]
    rest = substr(line, RLENGTH + length(arr[1]) + length("let ") + length(arr[2]))
    # rest = ": TYPE = RHS" の形式
    if (match(rest, /^:[[:space:]]*(.+)[[:space:]]*=[[:space:]]*(.+)$/, type_rhs)) {
        declared = type::normalize(type_rhs[1])
        rhs      = _ds_trim(type_rhs[2])
        _DS_let_locals[++_DS_let_count] = varname
        _DS_let_type_map[varname]        = declared
        _DS_VAR_TYPES[_DS_func_name, varname] = declared
        _DS_VAR_KIND[_DS_func_name, varname]  = _ds_kind_of(declared)
        inferred = _ds_infer_type(rhs)
        if (inferred != "" && !type::accepts(declared, inferred)) {
            print "dsl error: " _DS_src_file ":" lineno \
                ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
            _DS_had_error = 1
        }
        # Union 型には coerce しない（一意でないため）
        if (type::is_union(declared))
            return indent varname " = " rhs
        return indent varname " = type::coerce(" rhs ", \"" declared "\")"
    }
  }
```

> **実装メモ**: 既存の `let name: Type = expr` ブランチの「前」にこのブランチを置き、Union 型と単純型の両方を処理できるようにする。既存ブランチは Union を含まない型にのみマッチするよう正規表現を残すか、このブランチですべて処理するかのどちらか。全置き換えが明快。

- [ ] **Step 4: `_ds_check_type` を `type::accepts` 対応に更新**

```awk
function _ds_check_type(declared, inferred, lineno) {
    if (inferred == "" || inferred == declared) return
    # before: exact match のみ
    # after: type::accepts を使用
    if (type::accepts(declared, inferred)) return
    print "dsl error: " _DS_src_file ":" lineno \
        ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
    _DS_had_error = 1
}
```

- [ ] **Step 5: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "union_let|FAIL" | head -20
```

Expected: `PASS: union_let_basic_ok`, `PASS: union_let_basic_error`

全テスト確認:

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```

Expected: `X passed, 0 failed`

- [ ] **Step 6: コミット**

```bash
git add dsl/desugar_let.awk tests/unit/dsl/union_let_basic_ok/ tests/unit/dsl/union_let_basic_error/
git commit -m "feat(dsl): support Union type annotation in let declarations"
```

---

### Task 5: `??` の型推論を union 化

**Files:**
- Modify: `dsl/desugar.awk`
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/union_nullcoalesce_str_int/input.awk`
- Create: `tests/unit/dsl/union_nullcoalesce_str_int/expected.awk`
- Create: `tests/unit/dsl/union_listen_nullcoalesce_ok/input.awk`
- Create: `tests/unit/dsl/union_listen_nullcoalesce_ok/expected.awk`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/union_nullcoalesce_str_int/input.awk
function handler() {
  let port: Int | Str = env.get("PORT") ?? 8080
}
```

```
# tests/unit/dsl/union_nullcoalesce_str_int/expected.awk
function handler(    _ds_tc_1, port) {
  _ds_tc_1 = env::dispatch("get", "PORT")
  port = (_ds_tc_1 != "" ? _ds_tc_1 : 8080)
}
```

```
# tests/unit/dsl/union_listen_nullcoalesce_ok/input.awk
BEGIN {
  hawk.app.listen(env.get("PORT") ?? 8080)
}
```

```
# tests/unit/dsl/union_listen_nullcoalesce_ok/expected.awk
BEGIN {
  _ds_tc_1 = env::dispatch("get", "PORT")
  hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
}
```

> 注: `sig_listen_nullcoalesce_ok` と同じ期待値。こちらは型チェックが通ることも確認する（エラーなし）。

- [ ] **Step 2: テスト実行して現在の状態を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "nullcoalesce_str_int|listen_nullcoalesce"
```

`union_nullcoalesce_str_int` は現在 FAIL（`??` の型推論がないため `Int|Str` 宣言に `Bool` 等を渡すとエラーにならない）。  
`union_listen_nullcoalesce_ok` は現在 PASS（型チェックが skip される）。

- [ ] **Step 3: `_ds_process_line` に元の行を保持して `_ds_let_transform` に渡す**

`dsl/desugar.awk` の `_ds_process_line` 内、関数 body の処理部分を変更:

```awk
  # Inside function body — before:
  nc_result = _ds_nc_transform(_ds_dot_transform(line), nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  transformed = _ds_let_transform(nc_result, lineno)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed

  # after: 元の行（dot_transform前）を保持して _ds_let_transform に渡す
  dot_transformed = _ds_dot_transform(line)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  transformed = _ds_let_transform(nc_result, lineno, line)  # 第3引数: 元の行
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
```

- [ ] **Step 4: `_ds_let_transform` のシグネチャを更新し、`??` 推論を追加**

`dsl/desugar_let.awk` の `_ds_let_transform` に `orig_line` 引数を追加:

```awk
function _ds_let_transform(line, lineno, orig_line,    arr, rhs, declared) {
```

`_ds_infer_type` の `??` 処理を更新:

```awk
# before:
    if (expr ~ /\?\?/) return ""

# after: 元の行から ?? 前後の型を推論するヘルパーを使う
# (この行は削除し、_ds_infer_type_with_orig を使う)
```

`??` 型推論用のヘルパーを追加:

```awk
# _ds_infer_type_with_orig: orig_expr (変換前) と transformed_expr を見て型推論
# orig_expr に ?? が含まれる場合、左辺・右辺を個別推論して union 化
function _ds_infer_type_with_orig(transformed_expr, orig_expr,    m, ltype, rtype) {
    if (orig_expr != "" && match(orig_expr, /^(.+)\?\?(.+)$/, m)) {
        ltype = _ds_infer_type(_ds_trim(m[1]))
        rtype = _ds_infer_type(_ds_trim(m[2]))
        return type::union_of(ltype, rtype)
    }
    return _ds_infer_type(transformed_expr)
}
```

型付き `let` のブランチで、inferred 取得を `_ds_infer_type_with_orig` に変更:

```awk
        # before:
        inferred = _ds_infer_type(rhs)

        # after: orig_line から対応する RHS を取り出して渡す
        orig_rhs = _ds_extract_orig_rhs(orig_line)
        inferred = _ds_infer_type_with_orig(rhs, orig_rhs)
```

```awk
# _ds_extract_orig_rhs: 元の let 行から = 以降の RHS を取り出す
function _ds_extract_orig_rhs(orig_line,    m) {
    if (match(orig_line, /=[[:space:]]*(.+)$/, m)) return _ds_trim(m[1])
    return ""
}
```

- [ ] **Step 5: `_ds_infer_type` の `??` スキップを削除**

```awk
# 削除する行:
    if (expr ~ /\?\?/) return ""
```

(代わりに `_ds_infer_type_with_orig` で処理する)

- [ ] **Step 6: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "nullcoalesce|FAIL" | head -20
```

Expected: 
- `PASS: union_nullcoalesce_str_int`
- `PASS: union_listen_nullcoalesce_ok`
- `PASS: nullcoalesce_basic` (既存テストが壊れていないこと)
- `PASS: nullcoalesce_in_call` (既存テストが壊れていないこと)

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```

Expected: `X passed, 0 failed`

- [ ] **Step 7: コミット**

```bash
git add dsl/desugar.awk dsl/desugar_let.awk \
    tests/unit/dsl/union_nullcoalesce_str_int/ tests/unit/dsl/union_listen_nullcoalesce_ok/
git commit -m "feat(dsl): infer Union type from ?? expressions (pre-transform origin tracking)"
```

---

## Phase C: 関数アノテーション

### Task 6: `_ds_is_func_def` 拡張 + `_ds_parse_func_params` + 2パス sig 収集

**Files:**
- Modify: `dsl/desugar.awk`
- Create: `tests/unit/dsl/func_signature_desugar/input.awk`
- Create: `tests/unit/dsl/func_signature_desugar/expected.awk`
- Create: `tests/unit/dsl/func_arg_optional_any/input.awk`
- Create: `tests/unit/dsl/func_arg_optional_any/expected.awk`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/func_signature_desugar/input.awk
function hello(name: Str) -> Response {
  return ctx.res.text("hello")
}
```

```
# tests/unit/dsl/func_signature_desugar/expected.awk
function hello(name) {
  return ctx::dispatch("res.text", "hello")
}
```

```
# tests/unit/dsl/func_arg_optional_any/input.awk
function echo(x) -> Response {
  return ctx.res.text(x)
}
```

```
# tests/unit/dsl/func_arg_optional_any/expected.awk
function echo(x) {
  return ctx::dispatch("res.text", x)
}
```

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "func_signature|func_arg_optional"
```

Expected: 両方 FAIL（`-> Response` が現在 `_ds_is_func_def` でマッチしないため）

- [ ] **Step 3: `_ds_is_func_def` の正規表現を拡張**

`dsl/desugar.awk` を変更:

```awk
# before:
function _ds_is_func_def(line) {
  return (line ~ /^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\([^)]*\)[[:space:]]*\{/)
}

# after: -> ReturnType を許容、引数に型アノテーションを含む場合も対応
function _ds_is_func_def(line) {
  return (line ~ /^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(.*\)[[:space:]]*(->.*)?[[:space:]]*\{[[:space:]]*$/)
}
```

- [ ] **Step 4: `_ds_extract_func_name` を `typecheck.awk` から `desugar.awk` に移動（または両方で使えるよう共有）**

> `_ds_extract_func_name` は `typecheck.awk` に定義済。`desugar.awk` でも使うため、`desugar_state.awk` に移動するか、`typecheck.awk` の関数をそのまま呼ぶ（同じ namespace なので呼べる）。

`typecheck.awk` の `_ds_extract_func_name` はそのままで OK。`desugar.awk` から呼び出せる。

- [ ] **Step 5: `_ds_parse_func_params` を `desugar.awk` に追加**

```awk
# _ds_parse_func_params: 型付き引数リストを gawk 用引数名リストに変換し sig を登録
# 例: "name: Str, age: Int | Str" -> "name, age"
# 副作用: _DS_SIG_ARG[func_name, i], _DS_SIG_ARITY[func_name] を設定
function _ds_parse_func_params(func_name, params_str,    i, c, depth, cur, n, parts, param, colon_pos, pname, ptype) {
    # パラメータを , で分割（<...> depth 考慮）
    n = 0; depth = 0; cur = ""
    for (i = 1; i <= length(params_str); i++) {
        c = substr(params_str, i, 1)
        if      (c == "<") depth++
        else if (c == ">") depth--
        else if (c == "," && depth == 0) {
            parts[++n] = _ds_trim(cur); cur = ""; continue
        }
        cur = cur c
    }
    if (_ds_trim(cur) != "") parts[++n] = _ds_trim(cur)

    _DS_SIG_ARITY[func_name] = n

    for (i = 1; i <= n; i++) {
        param = parts[i]
        colon_pos = index(param, ":")
        if (colon_pos > 0) {
            pname = _ds_trim(substr(param, 1, colon_pos - 1))
            ptype = type::normalize(_ds_trim(substr(param, colon_pos + 1)))
        } else {
            pname = _ds_trim(param)
            ptype = "Any"
        }
        _DS_SIG_ARG[func_name, i] = ptype
        parts[i] = pname  # gawk 用に型を除去した名前
    }

    # gawk 用引数リストを再構築
    cur = ""
    for (i = 1; i <= n; i++) cur = cur (i > 1 ? ", " : "") parts[i]
    return cur
}

# _ds_extract_return_type: "function f(...) -> ReturnType {" から ReturnType を取り出す
function _ds_extract_return_type(sig,    m) {
    if (match(sig, /->[[:space:]]*([^{]+)[[:space:]]*\{/, m))
        return type::normalize(_ds_trim(m[1]))
    return "Any"
}

# _ds_strip_func_annotations: 型アノテーションを除去して gawk 用の function 宣言を返す
# "function f(a: Str, b: Int) -> Response {" -> "function f(a, b) {"
function _ds_strip_func_annotations(sig,    m, func_name, params_str, clean_params) {
    if (!match(sig, /^([[:space:]]*)function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(([^)]*)\)/, m))
        return sig
    func_name    = m[2]
    params_str   = m[3]
    clean_params = _ds_parse_func_params(func_name, params_str)
    return m[1] "function " func_name "(" clean_params ") {"
}
```

- [ ] **Step 6: `_ds_process_line` の関数定義処理を更新**

`_ds_process_line` 内の関数定義検出時:

```awk
    if (_ds_is_func_def(line)) {
      _DS_in_function  = 1
      _DS_func_name    = _ds_extract_func_name(line)
      _DS_func_sig     = _ds_strip_func_annotations(line)  # アノテーション除去済
      _DS_func_ret_type = _ds_extract_return_type(line)    # 返り値型を保持
      _DS_brace_depth  = _ds_net_braces(line)
      ...
    }
```

`_DS_func_ret_type` を `desugar_state.awk` に追加:

```awk
# dsl/desugar_state.awk に追加:
_DS_func_ret_type = ""   # 現在処理中の関数の返り値型
```

- [ ] **Step 7: 2パス sig 収集を `dsl/desugar.awk` の `BEGIN` に追加**

```awk
BEGIN {
    _ds_init()
    # Pass 1: ユーザー定義関数の sig を収集
    # ARGV[1] から入力ファイルを読む（desugar.awk は常に1ファイル入力）
    if (ARGC > 1) {
        while ((getline _pass1_line < ARGV[1]) > 0) {
            if (_ds_is_func_def(_pass1_line)) {
                _pass1_fname = _ds_extract_func_name(_pass1_line)
                _pass1_ret   = _ds_extract_return_type(_pass1_line)
                _DS_SIG_RET[_pass1_fname] = (_pass1_ret != "" ? _pass1_ret : "Any")
                if (match(_pass1_line, /\(([^)]*)\)/, _pass1_m))
                    _ds_parse_func_params(_pass1_fname, _pass1_m[1])
            }
        }
        close(ARGV[1])
    }
}
```

- [ ] **Step 8: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "func_signature|func_arg_optional|FAIL" | head -20
```

Expected: `PASS: func_signature_desugar`, `PASS: func_arg_optional_any`

既存テストを確認:

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```

Expected: `X passed, 0 failed`

- [ ] **Step 9: コミット**

```bash
git add dsl/desugar.awk dsl/desugar_state.awk \
    tests/unit/dsl/func_signature_desugar/ tests/unit/dsl/func_arg_optional_any/
git commit -m "feat(dsl): 2-pass sig collection and function annotation parsing"
```

---

### Task 7: 関数引数型チェック（ユーザー定義関数 + built-in 統合）

**Files:**
- Modify: `dsl/desugar.awk`
- Create: `tests/unit/dsl/func_arg_type_ok/input.awk`
- Create: `tests/unit/dsl/func_arg_type_ok/expected.awk`
- Create: `tests/unit/dsl/func_arg_type_error/input.awk`
- Create: `tests/unit/dsl/func_arg_type_error/expected_stderr`
- Create: `tests/unit/dsl/func_arg_union_ok/input.awk`
- Create: `tests/unit/dsl/func_arg_union_ok/expected.awk`
- Create: `tests/unit/dsl/func_user_call_arity_error/input.awk`
- Create: `tests/unit/dsl/func_user_call_arity_error/expected_stderr`
- Create: `tests/unit/dsl/func_user_call_type_error/input.awk`
- Create: `tests/unit/dsl/func_user_call_type_error/expected_stderr`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/func_arg_type_ok/input.awk
function normalize(text: Str) -> Str {
  return text
}

function handler() {
  let result: Str = normalize(ctx.req.form("title"))
}
```

```
# tests/unit/dsl/func_arg_type_ok/expected.awk
function normalize(text) {
  return text
}

function handler(    result) {
  result = normalize(ctx::dispatch("req.form", "title"))
}
```

```
# tests/unit/dsl/func_arg_type_error/input.awk
function normalize(text: Str) -> Str {
  return text
}

function handler() {
  let result: Str = normalize(123)
}
```

```
# tests/unit/dsl/func_arg_type_error/expected_stderr
normalize argument 1 expects Str, got Int
```

```
# tests/unit/dsl/func_arg_union_ok/input.awk
function process(id: Int | Str) -> Str {
  return id
}

function handler() {
  let result: Str = process(42)
}
```

```
# tests/unit/dsl/func_arg_union_ok/expected.awk
function process(id) {
  return id
}

function handler(    result) {
  result = process(42)
}
```

```
# tests/unit/dsl/func_user_call_arity_error/input.awk
function greet(name: Str) -> Str {
  return name
}

function handler() {
  let x: Str = greet("Alice", "Bob")
}
```

```
# tests/unit/dsl/func_user_call_arity_error/expected_stderr
greet expects 1 argument(s), got 2
```

```
# tests/unit/dsl/func_user_call_type_error/input.awk
function double(n: Int) -> Int {
  return n
}

function handler() {
  let x: Int = double("hello")
}
```

```
# tests/unit/dsl/func_user_call_type_error/expected_stderr
double argument 1 expects Int, got Str
```

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "func_arg_type|func_arg_union|func_user_call"
```

Expected: 全て FAIL

- [ ] **Step 3: `_ds_typecheck_plain_call` を `dsl/desugar.awk` に追加**

```awk
# _ds_typecheck_plain_call: 単純関数呼び出し "f(args)" の型チェック
# dot-transform 後・let-transform 前に呼ぶ
function _ds_typecheck_plain_call(line,    m) {
    if (match(line, /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\((.*)\)[[:space:]]*$/, m)) {
        if (m[1] in _DS_SIG_ARITY)
            _ds_typecheck_call(m[1], m[2])
    }
}
```

- [ ] **Step 4: `_ds_process_line` の関数 body 処理に `_ds_typecheck_plain_call` を追加**

```awk
  # Inside function body
  dot_transformed = _ds_dot_transform(line)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  _ds_typecheck_plain_call(nc_result)  # 追加: ユーザー定義関数 call check
  transformed = _ds_let_transform(nc_result, lineno, line)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
```

- [ ] **Step 5: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "func_arg_type|func_arg_union|func_user_call|FAIL" | head -20
```

Expected: 全て PASS

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```

Expected: `X passed, 0 failed`

- [ ] **Step 6: コミット**

```bash
git add dsl/desugar.awk \
    tests/unit/dsl/func_arg_type_ok/ tests/unit/dsl/func_arg_type_error/ \
    tests/unit/dsl/func_arg_union_ok/ \
    tests/unit/dsl/func_user_call_arity_error/ tests/unit/dsl/func_user_call_type_error/
git commit -m "feat(dsl): user-defined function call type check via _ds_typecheck_plain_call"
```

---

## Phase D: return / call check

### Task 8: 関数返り値型チェック

**Files:**
- Modify: `dsl/desugar.awk`
- Create: `tests/unit/dsl/func_return_type_ok/input.awk`
- Create: `tests/unit/dsl/func_return_type_ok/expected.awk`
- Create: `tests/unit/dsl/func_return_type_error/input.awk`
- Create: `tests/unit/dsl/func_return_type_error/expected_stderr`
- Create: `tests/unit/dsl/func_return_union_ok/input.awk`
- Create: `tests/unit/dsl/func_return_union_ok/expected.awk`
- Create: `tests/unit/dsl/func_return_void_error/input.awk`
- Create: `tests/unit/dsl/func_return_void_error/expected_stderr`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/func_return_type_ok/input.awk
function hello() -> Response {
  return ctx.res.text("hello")
}
```

```
# tests/unit/dsl/func_return_type_ok/expected.awk
function hello() {
  return ctx::dispatch("res.text", "hello")
}
```

```
# tests/unit/dsl/func_return_type_error/input.awk
function hello() -> Response {
  return "hello"
}
```

```
# tests/unit/dsl/func_return_type_error/expected_stderr
function hello expects return Response, got Str
```

```
# tests/unit/dsl/func_return_union_ok/input.awk
function parse(raw: Str) -> Int | Str {
  return 42
}
```

```
# tests/unit/dsl/func_return_union_ok/expected.awk
function parse(raw) {
  return 42
}
```

```
# tests/unit/dsl/func_return_void_error/input.awk
function setup() -> Void {
  return ctx.res.text("hello")
}
```

```
# tests/unit/dsl/func_return_void_error/expected_stderr
function setup expects Void, got Response
```

- [ ] **Step 2: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "func_return"
```

Expected: 全て FAIL

- [ ] **Step 3: `_ds_check_return` を `dsl/desugar.awk` に追加**

```awk
# _ds_check_return: return 文の型チェック
function _ds_check_return(line, lineno,    m, actual) {
    if (_DS_func_ret_type == "" || _DS_func_ret_type == "Any") return
    # "return expr" の形式を検出
    if (match(line, /^[[:space:]]*return[[:space:]]+(.+)$/, m)) {
        actual = _ds_infer_type(_ds_trim(m[1]))
        if (actual == "") return  # 推論不可は skip
        if (_DS_func_ret_type == "Void") {
            print "dsl error: " _DS_src_file ":" lineno \
                ": function " _DS_func_name " expects Void, got " actual > "/dev/stderr"
            _DS_had_error = 1
            return
        }
        if (!type::accepts(_DS_func_ret_type, actual)) {
            print "dsl error: " _DS_src_file ":" lineno \
                ": function " _DS_func_name " expects return " _DS_func_ret_type ", got " actual > "/dev/stderr"
            _DS_had_error = 1
        }
    }
}
```

- [ ] **Step 4: `_ds_process_line` の関数 body 処理に return チェックを追加**

```awk
  # Inside function body
  dot_transformed = _ds_dot_transform(line)
  nc_result = _ds_nc_transform(dot_transformed, nc_pre)
  for (p = 1; p in nc_pre; p++)
    _DS_body_buf[++_DS_body_count] = nc_pre[p]
  _ds_typecheck_plain_call(nc_result)
  _ds_check_return(dot_transformed, lineno)  # 追加: return type check (dot後・nc前を使う)
  transformed = _ds_let_transform(nc_result, lineno, line)
  if (transformed != "") _DS_body_buf[++_DS_body_count] = transformed
```

> `_ds_check_return` は `dot_transformed` に対して呼ぶ（`nc_transform` 後は return 文が変形される場合があるため、dot 変換後の形式が最も素直）。`return ctx.res.text("hello")` が `return ctx::dispatch("res.text", "hello")` になった状態で `_ds_infer_type` が DSL dispatch 形式をパースできる。

- [ ] **Step 5: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "func_return|FAIL" | head -20
```

Expected: 全て PASS

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```

Expected: `X passed, 0 failed`

- [ ] **Step 6: コミット**

```bash
git add dsl/desugar.awk \
    tests/unit/dsl/func_return_type_ok/ tests/unit/dsl/func_return_type_error/ \
    tests/unit/dsl/func_return_union_ok/ tests/unit/dsl/func_return_void_error/
git commit -m "feat(dsl): add function return type checking"
```

---

### Task 9: `?=` + Union 型対応

**Files:**
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/unwrap_union_option_result_ok/input.awk`
- Create: `tests/unit/dsl/unwrap_union_option_result_ok/expected.awk`
- Create: `tests/unit/dsl/unwrap_union_non_unwrap_error/input.awk`
- Create: `tests/unit/dsl/unwrap_union_non_unwrap_error/expected_stderr`

- [ ] **Step 1: テストを書く**

```
# tests/unit/dsl/unwrap_union_option_result_ok/input.awk
function handler() {
  let body ?= ctx.req.json()
}
```

```
# tests/unit/dsl/unwrap_union_option_result_ok/expected.awk
function handler(    _ds_tc_1, body) {
  _ds_tc_1 = ctx::dispatch("req.json")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  body = result_val(_ds_tc_1)
}
```

```
# tests/unit/dsl/unwrap_union_non_unwrap_error/input.awk
function handler() {
  let title ?= ctx.req.form("title")
}
```

```
# tests/unit/dsl/unwrap_union_non_unwrap_error/expected_stderr
?= requires Option or Result, got Str
```

> 注: `unwrap_union_non_unwrap_error` は `option_unwrap_error` と同等のテスト。`option_unwrap_error` が既に存在するため、`unwrap_union_non_unwrap_error` の内容が重複する場合はスキップしてよい。

- [ ] **Step 2: テスト実行して現在の状態を確認**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "unwrap_union"
```

`unwrap_union_option_result_ok` は `option_unwrap_ok` と同等のため PASS になる可能性が高い。  
`unwrap_union_non_unwrap_error` は PASS になる可能性が高い（既存の `?=` チェックが機能している）。

- [ ] **Step 3: Union 型 RHS の `?=` 対応（現在の `_ds_is_nullable` 拡張）**

複数の Option/Result を union 化した RHS を `?=` で受け取れるよう `desugar_let.awk` を更新:

現在の `?=` ブランチ:
```awk
    if (declared != "" && !_ds_is_nullable(declared)) {
      print "dsl error: ..."
    }
```

Union 型の全 member が nullable かチェックするよう更新:

```awk
function _ds_all_nullable(t,    out, n, i) {
    n = type::split_union(t, out)
    for (i = 1; i <= n; i++)
        if (!_ds_is_nullable(out[i])) return 0
    return 1
}
```

```awk
    # ?= ブランチ内:
    declared = _ds_infer_type(rhs)
    if (declared != "" && !_ds_is_nullable(declared) && !_ds_all_nullable(declared)) {
      print "dsl error: ..."
    }
    # unwrap 後の型を union 化
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = _ds_unwrap_union_type(declared)
```

```awk
# Union 型の各 member を unwrap した型を union 化
function _ds_unwrap_union_type(t,    out, n, i, result) {
    n = type::split_union(t, out)
    result = _ds_inner_type(out[1])
    for (i = 2; i <= n; i++)
        result = type::union_of(result, _ds_inner_type(out[i]))
    return result
}
```

- [ ] **Step 4: テスト実行**

```bash
bash tests/unit/dsl/run.sh 2>&1 | grep -E "unwrap_union|FAIL" | head -20
```

Expected: 全て PASS

```bash
bash tests/unit/dsl/run.sh 2>&1 | tail -3
```

Expected: `X passed, 0 failed`

- [ ] **Step 5: コミット**

```bash
git add dsl/desugar_let.awk \
    tests/unit/dsl/unwrap_union_option_result_ok/ tests/unit/dsl/unwrap_union_non_unwrap_error/
git commit -m "feat(dsl): ?= supports Union of Option/Result types"
```

---

## 最終確認

- [ ] **全テスト実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: 全テスト PASS、`0 failed`

- [ ] **既存の hawk サンプルで動作確認（あれば）**

```bash
find . -name "*.hawk" | head -5 | xargs -I{} gawk -f dsl/desugar.awk {}
```

- [ ] **最終コミット（必要に応じて）**

```bash
git log --oneline -10
```

---

## 実装メモ

### gawk namespace 注意点

- `type.awk` は `@namespace "type"` を宣言済。新規追加関数も同じ namespace 内。
- `type` namespace から default namespace（`awk` namespace）の変数にアクセスする場合は `awk::_DS_TYPE_ALIAS` のように `awk::` プレフィックスを使う。
- `typecheck.awk` は default namespace から `type::accepts(...)` のように呼び出す。

### `_ds_parse_func_params` の副作用

- Pass 1（BEGIN）でも Pass 2（通常処理）でも呼ばれる。
- Pass 1 では sig 収集のみが目的。Pass 2 の `_ds_is_func_def` 検出時にも `_ds_parse_func_params` を呼ぶが、同じ関数に対して2回呼ばれることになる。これは問題ない（上書きするだけで値は同じ）。

### `let: Union` の coerce

- `let port: Int | Str = 8080` では `type::coerce` を呼ばない。
- Union 型への coerce は実行時に意味をなさない（どちらの型に coerce すべきか不明）ため、型チェックのみ行い代入はそのまま。
- 単一型 `let port: Int = 8080` の場合は従来通り `type::coerce(8080, "Int")` を呼ぶ。
