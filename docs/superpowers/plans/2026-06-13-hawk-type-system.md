# Hawk DSL 型情報拡張 (Phase 1–5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hawk DSL の desugar フェーズに関数シグネチャ検証・変数シンボルテーブル・`?=` desugar を追加し、危険なコードをコンパイル時に検出できるようにする。

**Architecture:** `dsl/sig.awk` に全 DSL 関数のシグネチャ (戻り型・arity・引数型) を登録し、`dsl/typecheck.awk` が dot transform 時にチェックを実行。`desugar_let.awk` が関数スコープ付き変数シンボルテーブルを保持し、`?=` を runtime unwrap コードへ展開する。

**Tech Stack:** gawk (POSIX awk + `@namespace`), bash (テストランナー)

---

## File Map

| ファイル | 変更種別 | 責務 |
|---|---|---|
| `dsl/sig.awk` | **新規** | `_DS_SIG_RET/ARITY/ARG` 全 DSL 関数登録 |
| `dsl/typecheck.awk` | **新規** | arity/arg type check ロジック |
| `dsl/desugar.awk` | 変更 | `@include` 追加、`_DS_func_name` / `_DS_current_lineno` 設定 |
| `dsl/desugar_state.awk` | 変更 | `_DS_current_lineno`・`_DS_VAR_TYPES`・`_DS_VAR_KIND` 追加 |
| `dsl/desugar_dot.awk` | 変更 | `_ds_dispatch_from` に `_ds_typecheck_call` 呼び出し追加 |
| `dsl/desugar_let.awk` | 変更 | symbol table 記録・`_ds_kind_of`・`?=` パターン追加 |
| `dsl/type.awk` | 変更 | `_DS_TYPE_RETURNS` 削除、`_ds_infer_type` を `_DS_SIG_RET` 参照に変更 |

---

## Task 1: `dsl/sig.awk` 作成 + `_DS_TYPE_RETURNS` 移行

**Files:**
- Create: `dsl/sig.awk`
- Modify: `dsl/type.awk`
- Modify: `dsl/desugar.awk`

このタスクは純粋なリファクタ。既存の `_DS_TYPE_RETURNS` を `_DS_SIG_*` 3 配列に置き換える。外から見える動作は変わらないため、既存テストがそのまま通ることが「テスト」となる。

- [ ] **Step 1: 現在のテストが全て PASS することを確認**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `18 passed, 0 failed`

- [ ] **Step 2: `dsl/sig.awk` を作成**

```awk
# SPDX-License-Identifier: MIT
# dsl/sig.awk -- DSL function signature registry
#
# _DS_SIG_RET[path]        : return type string
# _DS_SIG_ARITY[path]      : argument count (exact)
# _DS_SIG_ARG[path, index] : argument type, 1-indexed

BEGIN {
    # env.*
    _DS_SIG_RET["env.get"]        = "Str"
    _DS_SIG_ARITY["env.get"]      = 1
    _DS_SIG_ARG["env.get", 1]     = "Str"

    _DS_SIG_RET["env.set"]        = "Void"
    _DS_SIG_ARITY["env.set"]      = 2
    _DS_SIG_ARG["env.set", 1]     = "Str"
    _DS_SIG_ARG["env.set", 2]     = "Str"

    _DS_SIG_RET["env.del"]        = "Void"
    _DS_SIG_ARITY["env.del"]      = 1
    _DS_SIG_ARG["env.del", 1]     = "Str"

    _DS_SIG_RET["env.has"]        = "Bool"
    _DS_SIG_ARITY["env.has"]      = 1
    _DS_SIG_ARG["env.has", 1]     = "Str"

    # ctx.req.*
    _DS_SIG_RET["ctx.req.form"]      = "Str"
    _DS_SIG_ARITY["ctx.req.form"]    = 1
    _DS_SIG_ARG["ctx.req.form", 1]   = "Str"

    _DS_SIG_RET["ctx.req.query"]     = "Str"
    _DS_SIG_ARITY["ctx.req.query"]   = 1
    _DS_SIG_ARG["ctx.req.query", 1]  = "Str"

    _DS_SIG_RET["ctx.req.param"]     = "Str"
    _DS_SIG_ARITY["ctx.req.param"]   = 1
    _DS_SIG_ARG["ctx.req.param", 1]  = "Str"

    _DS_SIG_RET["ctx.req.header"]    = "Str"
    _DS_SIG_ARITY["ctx.req.header"]  = 1
    _DS_SIG_ARG["ctx.req.header", 1] = "Str"

    _DS_SIG_RET["ctx.req.body"]      = "Str"
    _DS_SIG_ARITY["ctx.req.body"]    = 0

    _DS_SIG_RET["ctx.req.json"]      = "Result<Map, Error>"
    _DS_SIG_ARITY["ctx.req.json"]    = 0

    # ctx.res.*
    _DS_SIG_RET["ctx.res.json"]      = "Response"
    _DS_SIG_ARITY["ctx.res.json"]    = 1
    _DS_SIG_ARG["ctx.res.json", 1]   = "Str"

    _DS_SIG_RET["ctx.res.text"]      = "Response"
    _DS_SIG_ARITY["ctx.res.text"]    = 1
    _DS_SIG_ARG["ctx.res.text", 1]   = "Str"

    _DS_SIG_RET["ctx.res.html"]      = "Response"
    _DS_SIG_ARITY["ctx.res.html"]    = 1
    _DS_SIG_ARG["ctx.res.html", 1]   = "Str"

    _DS_SIG_RET["ctx.res.render"]    = "Response"
    _DS_SIG_ARITY["ctx.res.render"]  = 1
    _DS_SIG_ARG["ctx.res.render", 1] = "Str"

    _DS_SIG_RET["ctx.res.status"]    = "Response"
    _DS_SIG_ARITY["ctx.res.status"]  = 1
    _DS_SIG_ARG["ctx.res.status", 1] = "Int"

    _DS_SIG_RET["ctx.res.header"]    = "Response"
    _DS_SIG_ARITY["ctx.res.header"]  = 2
    _DS_SIG_ARG["ctx.res.header", 1] = "Str"
    _DS_SIG_ARG["ctx.res.header", 2] = "Str"

    _DS_SIG_RET["ctx.res.redirect"]   = "Response"
    _DS_SIG_ARITY["ctx.res.redirect"] = 1
    _DS_SIG_ARG["ctx.res.redirect", 1] = "Str"

    # hawk.app.*  (route registration: always arity=2, Str path + HandlerName)
    _DS_SIG_RET["hawk.app.get"]       = "Void"
    _DS_SIG_ARITY["hawk.app.get"]     = 2
    _DS_SIG_ARG["hawk.app.get", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.get", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.post"]      = "Void"
    _DS_SIG_ARITY["hawk.app.post"]    = 2
    _DS_SIG_ARG["hawk.app.post", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.post", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.put"]       = "Void"
    _DS_SIG_ARITY["hawk.app.put"]     = 2
    _DS_SIG_ARG["hawk.app.put", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.put", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.del"]       = "Void"
    _DS_SIG_ARITY["hawk.app.del"]     = 2
    _DS_SIG_ARG["hawk.app.del", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.del", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.patch"]     = "Void"
    _DS_SIG_ARITY["hawk.app.patch"]   = 2
    _DS_SIG_ARG["hawk.app.patch", 1]  = "Str"
    _DS_SIG_ARG["hawk.app.patch", 2]  = "HandlerName"

    _DS_SIG_RET["hawk.app.head"]      = "Void"
    _DS_SIG_ARITY["hawk.app.head"]    = 2
    _DS_SIG_ARG["hawk.app.head", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.head", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.on"]        = "Void"
    _DS_SIG_ARITY["hawk.app.on"]      = 2
    _DS_SIG_ARG["hawk.app.on", 1]     = "Str"
    _DS_SIG_ARG["hawk.app.on", 2]     = "HandlerName"

    _DS_SIG_RET["hawk.app.all"]       = "Void"
    _DS_SIG_ARITY["hawk.app.all"]     = 2
    _DS_SIG_ARG["hawk.app.all", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.all", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.listen"]    = "Void"
    _DS_SIG_ARITY["hawk.app.listen"]  = 1
    _DS_SIG_ARG["hawk.app.listen", 1] = "Int"
}
```

- [ ] **Step 3: `dsl/type.awk` の `_DS_TYPE_RETURNS` ブロックを削除**

`dsl/type.awk` の末尾にある `BEGIN { _DS_TYPE_RETURNS[...] }` ブロック全体 (行 44–51) を削除する。削除後の `dsl/type.awk` は `type::coerce` 関数と namespace 宣言のみになる。

削除対象:
```awk
@namespace "awk"

# 既知の DSL 関数の戻り型 (デシュガー時の静的チェックに使用)
# キー: "namespace.method" の dot 記法文字列
BEGIN {
    _DS_TYPE_RETURNS["env.get"]       = "Str"
    _DS_TYPE_RETURNS["ctx.req.form"]  = "Str"
    _DS_TYPE_RETURNS["ctx.req.query"] = "Str"
    _DS_TYPE_RETURNS["ctx.req.param"] = "Str"
    _DS_TYPE_RETURNS["ctx.req.body"]  = "Str"
}
```

削除後のファイル末尾は `}` (coerce 関数の閉じ括弧) と `@namespace "awk"` だけになる。

- [ ] **Step 4: `dsl/desugar_let.awk` の `_ds_infer_type` を `_DS_SIG_RET` 参照に更新**

`desugar_let.awk:16–17` を変更。`_DS_TYPE_RETURNS` → `_DS_SIG_RET`

変更前:
```awk
    if (key in _DS_TYPE_RETURNS) return _DS_TYPE_RETURNS[key]
```
変更後:
```awk
    if (key in _DS_SIG_RET) return _DS_SIG_RET[key]
```

同ファイルの2箇所 (行 17 と 22) を両方変更する。

- [ ] **Step 5: `dsl/desugar.awk` に `@include "dsl/sig.awk"` を追加**

`dsl/desugar.awk` の `@include "dsl/type.awk"` の直前に追加する:

```awk
@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_let.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/sig.awk"
@include "dsl/type.awk"
```

- [ ] **Step 6: テスト実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `18 passed, 0 failed`

- [ ] **Step 7: コミット**

```bash
git add dsl/sig.awk dsl/type.awk dsl/desugar_let.awk dsl/desugar.awk
git commit -m "refactor(dsl): introduce _DS_SIG_* registry, replace _DS_TYPE_RETURNS"
```

---

## Task 2: `dsl/typecheck.awk` 作成 + arity check + `desugar_dot.awk` フック

**Files:**
- Create: `dsl/typecheck.awk`
- Modify: `dsl/desugar.awk`
- Modify: `dsl/desugar_state.awk`
- Modify: `dsl/desugar_dot.awk`
- Create: `tests/unit/dsl/sig_arity_ctx_status/` (failing test)
- Create: `tests/unit/dsl/sig_arity_ctx_status_ok/` (success test)

- [ ] **Step 1: 失敗テスト `sig_arity_ctx_status` を作成**

```bash
mkdir -p tests/unit/dsl/sig_arity_ctx_status
```

`tests/unit/dsl/sig_arity_ctx_status/input.awk`:
```awk
function handler() {
  ctx.res.status()
}
```

`tests/unit/dsl/sig_arity_ctx_status/expected_stderr`:
```
ctx.res.status expects 1 argument(s), got 0
```

`tests/unit/dsl/sig_arity_ctx_status/expected_exit`:
```
1
```

- [ ] **Step 2: 失敗テスト `sig_arity_hawk_route` を作成**

```bash
mkdir -p tests/unit/dsl/sig_arity_hawk_route
```

`tests/unit/dsl/sig_arity_hawk_route/input.awk`:
```awk
BEGIN {
  hawk.app.get("/")
}
```

`tests/unit/dsl/sig_arity_hawk_route/expected_stderr`:
```
hawk.app.get expects 2 argument(s), got 1
```

`tests/unit/dsl/sig_arity_hawk_route/expected_exit`:
```
1
```

- [ ] **Step 3: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `18 passed, 2 failed` (新テスト2件が失敗)

- [ ] **Step 4: `_DS_current_lineno` を `desugar_state.awk` に追加**

`dsl/desugar_state.awk` の `_ds_init` 関数に1行追加:

```awk
function _ds_init() {
  _DS_brace_depth    = 0
  _DS_in_function    = 0
  _DS_func_name      = ""
  _DS_func_sig       = ""
  _DS_let_count      = 0
  _DS_body_count     = 0
  _DS_tc_count       = 0
  _DS_had_error      = 0
  _DS_src_file       = ""
  _DS_current_lineno = 0
  delete _DS_let_locals
  delete _DS_body_buf
  delete _DS_let_type_map
}
```

- [ ] **Step 5: `dsl/desugar.awk` の `_ds_process_line` 先頭に `_DS_current_lineno` 設定を追加**

`dsl/desugar.awk` の `_ds_process_line` 関数の最初の行として追加:

変更前:
```awk
function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p) {
  if (!_DS_in_function) {
```

変更後:
```awk
function _ds_process_line(line, lineno,    transformed, nc_pre, nc_result, p) {
  _DS_current_lineno = lineno
  if (!_DS_in_function) {
```

- [ ] **Step 6: `dsl/typecheck.awk` を作成**

```awk
# SPDX-License-Identifier: MIT
# dsl/typecheck.awk -- DSL static type checker (arity + arg types)
#
# Called from desugar_dot.awk::_ds_dispatch_from after path and args are known.
# Uses _DS_current_lineno (set by desugar.awk) for error location.
# Uses _DS_SIG_* from sig.awk.

function _ds_is_option(t) { return t ~ /^Option</ }
function _ds_is_result(t) { return t ~ /^Result</ }
function _ds_is_nullable(t) { return _ds_is_option(t) || _ds_is_result(t) }

# _ds_inner_type: extract T from Option<T> or Result<T, E>. Returns "Any" if unknown.
function _ds_inner_type(t,    m) {
    if (match(t, /^Option<(.+)>$/, m))    return m[1]
    if (match(t, /^Result<([^,]+),/, m))  return m[1]
    return "Any"
}

# _ds_count_args: count top-level comma-separated args in args_str.
# Handles nested parens and quoted strings. Returns 0 for empty string.
function _ds_count_args(args_str,    n, i, c, depth, in_str) {
    if (_ds_trim(args_str) == "") return 0
    n = 1; depth = 0; in_str = 0
    for (i = 1; i <= length(args_str); i++) {
        c = substr(args_str, i, 1)
        if (in_str) {
            if (c == "\\" && i < length(args_str)) { i++; continue }
            if (c == "\"") in_str = 0
        } else {
            if      (c == "\"") in_str = 1
            else if (c == "(")  depth++
            else if (c == ")")  depth--
            else if (c == "," && depth == 0) n++
        }
    }
    return n
}

# _ds_split_args: split args_str by top-level commas into out[1..n]. Returns n.
function _ds_split_args(args_str, out,    i, c, depth, in_str, cur, n) {
    n = 0; depth = 0; in_str = 0; cur = ""
    for (i = 1; i <= length(args_str); i++) {
        c = substr(args_str, i, 1)
        if (in_str) {
            cur = cur c
            if (c == "\\" && i < length(args_str)) { cur = cur substr(args_str, ++i, 1) }
            else if (c == "\"") in_str = 0
        } else {
            if (c == "\"")      { in_str = 1; cur = cur c }
            else if (c == "(")  { depth++; cur = cur c }
            else if (c == ")")  { depth--; cur = cur c }
            else if (c == "," && depth == 0) {
                out[++n] = _ds_trim(cur)
                cur = ""
            } else {
                cur = cur c
            }
        }
    }
    if (_ds_trim(cur) != "") out[++n] = _ds_trim(cur)
    return n
}

# _ds_typecheck_call: check arity and arg types for a DSL function call.
# path: full dot-notation path e.g. "ctx.res.status"
# args_str: raw argument string (before recursive dot-transform)
function _ds_typecheck_call(path, args_str,    n, i, expected, actual, split_args, lineno) {
    lineno = _DS_current_lineno
    if (!(path in _DS_SIG_ARITY)) return   # unknown function: skip

    n = _ds_count_args(args_str)
    if (n != _DS_SIG_ARITY[path]) {
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " expects " _DS_SIG_ARITY[path] " argument(s), got " n > "/dev/stderr"
        _DS_had_error = 1
        return
    }

    if (n == 0) return   # arity OK, no args to type-check

    _ds_split_args(args_str, split_args)
    for (i = 1; i <= n; i++) {
        if (!((path, i) in _DS_SIG_ARG)) continue
        expected = _DS_SIG_ARG[path, i]
        actual   = _ds_infer_type(split_args[i])
        if (actual == "" || actual == "Any" || actual == expected) continue
        print "dsl error: " _DS_src_file ":" lineno \
            ": " path " argument " i " expects " expected ", got " actual > "/dev/stderr"
        _DS_had_error = 1
    }
}
```

- [ ] **Step 7: `dsl/desugar.awk` に `@include "dsl/typecheck.awk"` を追加**

`sig.awk` の後に追加:

```awk
@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_let.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/sig.awk"
@include "dsl/typecheck.awk"
@include "dsl/type.awk"
```

- [ ] **Step 8: `dsl/desugar_dot.awk` の `_ds_dispatch_from` に typecheck 呼び出しを追加**

`_ds_dispatch_from` 関数内、`path` が確定した直後に `_ds_typecheck_call` を呼ぶ。

変更前 (ファイルの `return ns "::dispatch...` の直前):
```awk
  np = split(m, parts, ".")
  ns = parts[1]
  path = ""
  for (j = 2; j <= np; j++)
    path = path (j > 2 ? "." : "") parts[j]

  # Now recursively transform after_close (it's the tail of the line)
  # We need to re-segment after_close and transform it
  # But after_close may start mid-way through a segment — just transform it as a new line
  return ns "::dispatch(\"" path "\"" (args != "" ? ", " _ds_dot_transform(args) : "") ")" \
         _ds_dot_transform(after_close)
```

変更後:
```awk
  np = split(m, parts, ".")
  ns = parts[1]
  path = ""
  for (j = 2; j <= np; j++)
    path = path (j > 2 ? "." : "") parts[j]

  _ds_typecheck_call(ns "." path, args)

  # Now recursively transform after_close (it's the tail of the line)
  # We need to re-segment after_close and transform it
  # But after_close may start mid-way through a segment — just transform it as a new line
  return ns "::dispatch(\"" path "\"" (args != "" ? ", " _ds_dot_transform(args) : "") ")" \
         _ds_dot_transform(after_close)
```

- [ ] **Step 9: 成功テスト `sig_arity_ctx_status_ok` を作成**

```bash
mkdir -p tests/unit/dsl/sig_arity_ctx_status_ok
```

`tests/unit/dsl/sig_arity_ctx_status_ok/input.awk`:
```awk
function handler() {
  ctx.res.status(200)
}
```

`tests/unit/dsl/sig_arity_ctx_status_ok/expected.awk`:
```awk
function handler() {
  ctx::dispatch("res.status", 200)
}
```

- [ ] **Step 10: テスト実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `21 passed, 0 failed`

- [ ] **Step 11: コミット**

```bash
git add dsl/typecheck.awk dsl/desugar.awk dsl/desugar_state.awk dsl/desugar_dot.awk \
        tests/unit/dsl/sig_arity_ctx_status/ \
        tests/unit/dsl/sig_arity_hawk_route/ \
        tests/unit/dsl/sig_arity_ctx_status_ok/
git commit -m "feat(dsl): add arity check via typecheck.awk, hook into dispatch transform"
```

---

## Task 3: 引数型チェック

**Files:**
- Create: `tests/unit/dsl/sig_type_ctx_status/`
- Create: `tests/unit/dsl/sig_type_hawk_route_path/`
- Create: `tests/unit/dsl/sig_type_hawk_route_handler/`

`typecheck.awk` の `_ds_typecheck_call` はすでに arg type チェックを実装済み (Task 2 Step 6)。このタスクではテストケースを追加して動作を検証する。

- [ ] **Step 1: 失敗テスト `sig_type_ctx_status` を作成**

```bash
mkdir -p tests/unit/dsl/sig_type_ctx_status
```

`tests/unit/dsl/sig_type_ctx_status/input.awk`:
```awk
function handler() {
  ctx.res.status("ok")
}
```

`tests/unit/dsl/sig_type_ctx_status/expected_stderr`:
```
ctx.res.status argument 1 expects Int, got Str
```

`tests/unit/dsl/sig_type_ctx_status/expected_exit`:
```
1
```

- [ ] **Step 2: 失敗テスト `sig_type_hawk_route_path` を作成**

```bash
mkdir -p tests/unit/dsl/sig_type_hawk_route_path
```

`tests/unit/dsl/sig_type_hawk_route_path/input.awk`:
```awk
BEGIN {
  hawk.app.get(200, "handler")
}
```

`tests/unit/dsl/sig_type_hawk_route_path/expected_stderr`:
```
hawk.app.get argument 1 expects Str, got Int
```

`tests/unit/dsl/sig_type_hawk_route_path/expected_exit`:
```
1
```

- [ ] **Step 3: テスト実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `21 passed, 2 failed` (新テスト2件が失敗)

Task 2 で実装した arg type check が新テストを通すはず。もし通らない場合は `typecheck.awk` の `_ds_infer_type` 参照を確認 (`_ds_infer_type` は `desugar_let.awk` に定義されている)。

- [ ] **Step 4: テスト再実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `23 passed, 0 failed`

- [ ] **Step 5: コミット**

```bash
git add tests/unit/dsl/sig_type_ctx_status/ tests/unit/dsl/sig_type_hawk_route_path/
git commit -m "test(dsl): add arg type check tests for ctx.res.status and hawk.app.get"
```

---

## Task 4: `_DS_func_name` 追跡 + 関数名抽出

**Files:**
- Modify: `dsl/desugar.awk`
- Modify: `dsl/typecheck.awk` (または `dsl/desugar_let.awk`)

`_DS_func_name` は `desugar_state.awk` で既に宣言されているが、常に `""` のまま。Task 5 の symbol table と Task 6 の `?=` に必要なため設定する。

- [ ] **Step 1: `_ds_extract_func_name` を `dsl/typecheck.awk` に追加**

`dsl/typecheck.awk` の末尾に追加:

```awk
# _ds_extract_func_name: extract function name from signature line.
# e.g. "function foo(a, b) {" → "foo"
function _ds_extract_func_name(sig,    m) {
    if (match(sig, /^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)/, m))
        return m[1]
    return ""
}
```

- [ ] **Step 2: `dsl/desugar.awk` の関数エントリブランチに `_DS_func_name` 設定を追加**

`_ds_process_line` 内の `if (_ds_is_func_def(line))` ブランチに1行追加:

変更前:
```awk
    if (_ds_is_func_def(line)) {
      _DS_in_function  = 1
      _DS_func_sig     = line
      _DS_brace_depth  = _ds_net_braces(line)
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_body_buf
      delete _DS_let_type_map
      return
    }
```

変更後:
```awk
    if (_ds_is_func_def(line)) {
      _DS_in_function  = 1
      _DS_func_sig     = line
      _DS_func_name    = _ds_extract_func_name(line)
      _DS_brace_depth  = _ds_net_braces(line)
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_body_buf
      delete _DS_let_type_map
      return
    }
```

- [ ] **Step 3: テスト実行 (回帰確認)**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `23 passed, 0 failed`

- [ ] **Step 4: コミット**

```bash
git add dsl/typecheck.awk dsl/desugar.awk
git commit -m "feat(dsl): track current function name in _DS_func_name"
```

---

## Task 5: 変数シンボルテーブル

**Files:**
- Modify: `dsl/desugar_state.awk`
- Modify: `dsl/desugar_let.awk`

`_DS_VAR_TYPES[func, var]` と `_DS_VAR_KIND[func, var]` を `let` 宣言時に記録する。外から見える出力は変わらないため、既存テストの通過が「テスト」となる。

- [ ] **Step 1: `dsl/desugar_state.awk` に VAR テーブルを追加**

`_ds_init` 関数に追加:

```awk
function _ds_init() {
  _DS_brace_depth    = 0
  _DS_in_function    = 0
  _DS_func_name      = ""
  _DS_func_sig       = ""
  _DS_let_count      = 0
  _DS_body_count     = 0
  _DS_tc_count       = 0
  _DS_had_error      = 0
  _DS_src_file       = ""
  _DS_current_lineno = 0
  delete _DS_let_locals
  delete _DS_body_buf
  delete _DS_let_type_map
  delete _DS_VAR_TYPES
  delete _DS_VAR_KIND
}
```

- [ ] **Step 2: `dsl/desugar_let.awk` に `_ds_kind_of` を追加**

ファイル末尾に追加:

```awk
# _ds_kind_of: map type string to kind label
function _ds_kind_of(t) {
    if (t == "Array" || t == "Map") return "array"
    if (t ~ /^Option</)             return "option"
    if (t ~ /^Result</)             return "result"
    if (t == "Response")            return "response"
    return "scalar"
}
```

- [ ] **Step 3: `_ds_let_transform` の各パターンに symbol table 記録を追加**

`dsl/desugar_let.awk` の `_ds_let_transform` 関数、4つのパターンを以下のように更新する。

**パターン 1: Array init** (`let name = []`)
変更前:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\[\][[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] "delete " arr[2]
  }
```
変更後:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\[\][[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = "Array"
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = "array"
    return arr[1] "delete " arr[2]
  }
```

**パターン 2: 型付き代入** (`let name: Type = expr`)
変更前:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    _ds_check_type(arr[3], _ds_infer_type(arr[4]), lineno)
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
  }
```
変更後:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = arr[3]
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(arr[3])
    _ds_check_type(arr[3], _ds_infer_type(arr[4]), lineno)
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
  }
```

**パターン 3: 型付き宣言のみ** (`let name: Type`)
変更前:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    return ""
  }
```
変更後:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = arr[3]
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(arr[3])
    return ""
  }
```

**パターン 4: 型なし代入** (`let name = expr`)
変更前:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    if (!(arr[2] in _DS_let_type_map))
      _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] arr[2] " = " arr[3]
  }
```
変更後:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    if (!(arr[2] in _DS_let_type_map)) {
      _DS_let_locals[++_DS_let_count] = arr[2]
      _DS_VAR_TYPES[_DS_func_name, arr[2]] = _ds_infer_type(arr[3])
      _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(_DS_VAR_TYPES[_DS_func_name, arr[2]])
    }
    return arr[1] arr[2] " = " arr[3]
  }
```

**パターン 5: 型なし宣言のみ** (`let name`)
変更前:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*$/, arr)) {
    if (!(arr[2] in _DS_let_type_map))
      _DS_let_locals[++_DS_let_count] = arr[2]
    return ""
  }
```
変更後:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*$/, arr)) {
    if (!(arr[2] in _DS_let_type_map)) {
      _DS_let_locals[++_DS_let_count] = arr[2]
      _DS_VAR_TYPES[_DS_func_name, arr[2]] = "Any"
      _DS_VAR_KIND[_DS_func_name, arr[2]]  = "scalar"
    }
    return ""
  }
```

- [ ] **Step 4: テスト実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `23 passed, 0 failed`

- [ ] **Step 5: コミット**

```bash
git add dsl/desugar_state.awk dsl/desugar_let.awk
git commit -m "feat(dsl): add variable symbol table (_DS_VAR_TYPES/_DS_VAR_KIND) in let transform"
```

---

## Task 6: `?=` 静的チェック + desugar

**Files:**
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/option_unwrap_error/`
- Create: `tests/unit/dsl/option_unwrap_ok/`

`?=` は `let name ?= expr` の構文で、`expr` が `Option<T>` or `Result<T, E>` を返すことを静的に検証し、unwrap+早期リターンコードに展開する。

`_ds_let_transform` は通常1行を返すが、`?=` は複数行を生成する。`_DS_body_buf` はグローバル変数のため `_ds_let_transform` 内から直接書き込み、`""` を返す。

- [ ] **Step 1: 失敗テスト `option_unwrap_error` を作成**

```bash
mkdir -p tests/unit/dsl/option_unwrap_error
```

`tests/unit/dsl/option_unwrap_error/input.awk`:
```awk
function handler() {
  let title ?= ctx.req.form("title")
}
```

`tests/unit/dsl/option_unwrap_error/expected_stderr`:
```
?= requires Option or Result, got Str
```

`tests/unit/dsl/option_unwrap_error/expected_exit`:
```
1
```

- [ ] **Step 2: 失敗テスト `option_unwrap_ok` を作成**

```bash
mkdir -p tests/unit/dsl/option_unwrap_ok
```

`tests/unit/dsl/option_unwrap_ok/input.awk`:
```awk
function create_todo() {
  let body ?= ctx.req.json()
}
```

`tests/unit/dsl/option_unwrap_ok/expected.awk`:
```awk
function create_todo(    _ds_tc_1, body) {
  _ds_tc_1 = ctx::dispatch("req.json")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  body = result_val(_ds_tc_1)
}
```

- [ ] **Step 3: テスト実行して FAIL を確認**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `23 passed, 2 failed`

- [ ] **Step 4: `_ds_let_transform` に `?=` パターンを追加**

`dsl/desugar_let.awk` の `_ds_let_transform` 関数の先頭 (Array init パターンの前) に追加する。

```awk
function _ds_let_transform(line, lineno,    arr, rhs, declared) {
  # ?= unwrap: let name ?= expr
  # Statically checks expr returns Option<T> or Result<T, E>.
  # Generates multi-line unwrap code directly into _DS_body_buf and returns "".
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\?=[[:space:]]*(.+)$/, arr)) {
    rhs = _ds_trim(arr[3])
    declared = _ds_infer_type(rhs)
    if (declared != "" && !_ds_is_nullable(declared)) {
      print "dsl error: " _DS_src_file ":" lineno \
          ": ?= requires Option or Result, got " declared > "/dev/stderr"
      _DS_had_error = 1
      return ""
    }
    # Generate unwrap code into body buffer directly
    _DS_tc_count++
    _DS_let_locals[++_DS_let_count] = "_ds_tc_" _DS_tc_count
    _DS_let_locals[++_DS_let_count] = arr[2]
    # Record in symbol table
    _DS_VAR_TYPES[_DS_func_name, arr[2]] = _ds_inner_type(declared)
    _DS_VAR_KIND[_DS_func_name, arr[2]]  = _ds_kind_of(_DS_VAR_TYPES[_DS_func_name, arr[2]])
    # Emit unwrap lines to body buffer
    _DS_body_buf[++_DS_body_count] = arr[1] "_ds_tc_" _DS_tc_count " = " rhs
    _DS_body_buf[++_DS_body_count] = arr[1] "if (!result_ok(_ds_tc_" _DS_tc_count ")) {"
    _DS_body_buf[++_DS_body_count] = arr[1] "  return ctx::dispatch(\"res.status\", 500)"
    _DS_body_buf[++_DS_body_count] = arr[1] "}"
    _DS_body_buf[++_DS_body_count] = arr[1] arr[2] " = result_val(_ds_tc_" _DS_tc_count ")"
    return ""
  }

  # Array init: let name = []
  ...
```

- [ ] **Step 5: `_ds_is_nullable` と `_ds_inner_type` が `desugar_let.awk` から参照可能であることを確認**

`_ds_is_nullable` と `_ds_inner_type` は `typecheck.awk` に定義されており、`desugar.awk` で `typecheck.awk` を `desugar_let.awk` より後に `@include` している。gawk では `BEGIN` ブロックは全ファイル読み込み後に実行され、関数定義はファイル全体で共有されるため、呼び出し順序は問題ない。確認のため `desugar.awk` の `@include` 順序を確認する:

```bash
grep '@include' dsl/desugar.awk
```

Expected:
```
@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_let.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/sig.awk"
@include "dsl/typecheck.awk"
@include "dsl/type.awk"
```

- [ ] **Step 6: テスト実行**

```bash
bash tests/unit/dsl/run.sh
```

Expected: `25 passed, 0 failed`

- [ ] **Step 7: コミット**

```bash
git add dsl/desugar_let.awk \
        tests/unit/dsl/option_unwrap_error/ \
        tests/unit/dsl/option_unwrap_ok/
git commit -m "feat(dsl): add ?= unwrap operator with static check and desugar expansion"
```

---

## Self-Review Checklist

- **spec.Phase 1 (sig registry)**: Task 1 で `sig.awk` 作成 + `_DS_TYPE_RETURNS` 移行 ✓
- **spec.Phase 2 (variable symbol table)**: Task 5 で symbol table 追加 ✓
- **spec.Phase 3 (array/scalar kind)**: Task 5 で `_ds_kind_of` + kind 記録 ✓
- **spec.Phase 4 (Option/Result 型文字列)**: Task 2 の `typecheck.awk` に `_ds_is_option/result/nullable` ✓
- **spec.Phase 5 (?= desugar)**: Task 6 で static check + desugar ✓
- **spec.error message format**: 全エラー `dsl error: <file>:<lineno>: <msg>` ✓
- **型一貫性**: `_DS_SIG_RET/ARITY/ARG` (Task 1) → `_ds_typecheck_call` (Task 2) → `_ds_infer_type` (既存, Task 1 で更新) → `?=` (Task 6) の全パスで参照名が一致 ✓
- **_DS_tc_count reset**: `desugar_state.awk` の `_ds_init` でリセット済み、`?=` と `??` でカウンターを共有 ✓
- **`_DS_func_name` 設定タイミング**: Task 4 で `_ds_is_func_def` ブランチに追加済み。Task 5 の symbol table 記録よりも前に実行される ✓
