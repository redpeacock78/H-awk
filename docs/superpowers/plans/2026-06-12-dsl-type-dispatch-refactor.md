# DSL Type System Refactor + Dispatch Commonalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) 共通 dispatch ルーターを `core/dispatch.awk` に作り `env`/`hawk` の if-chain を routes テーブル方式に変換、(2) `core/type.awk` を `dsl/type.awk` に移動し型レジストリを追加、(3) `let i: Int` 裸宣言 + 型付き代入の静的チェックを DSL に追加する。

**Architecture:** `core/dispatch.awk` が `hawk_dispatch::call(ns, routes, path, ...)` を提供し gawk `@` 間接呼び出しでルーティング。各 namespace は routes 配列を登録するだけ。型システムは `dsl/type.awk` に集約し、デシュガー時に `_DS_let_type_map` で型付き変数を追跡して代入を自動 coerce・静的チェックする。

**Tech Stack:** gawk 5.0+（`@namespace`、`@` 間接関数呼び出し、3引数 `match()`）、bash（テストランナー）

---

## File Map

```
新設:  core/dispatch.awk           hawk_dispatch::call 共通ルーター
新設:  dsl/type.awk                type::coerce + _DS_TYPE_RETURNS レジストリ
削除:  core/type.awk
修正:  hawk.awk                    @include 順序変更
修正:  core/env.awk                routes テーブル + hawk_dispatch::call 委譲
修正:  core/hawk.awk               routes テーブル + hawk_dispatch::call 委譲
修正:  dsl/desugar_state.awk       _DS_let_type_map 追加
修正:  dsl/desugar.awk             @include + _DS_let_type_map リセット追加
修正:  dsl/desugar_let.awk         _ds_infer_type/_ds_check_type + 裸宣言 + 型付き代入
修正:  tests/unit/dsl/run.sh       エラー fixture サポート追加
新設:  tests/unit/dsl/type_bare_decl/{input,expected}.awk
新設:  tests/unit/dsl/type_bare_assign/{input,expected}.awk
新設:  tests/unit/dsl/type_static_error_literal/{input.awk,expected_stderr,expected_exit}
新設:  tests/unit/dsl/type_static_error_known_func/{input.awk,expected_stderr,expected_exit}
```

---

## Task 1: `core/dispatch.awk` — 共通ルーター新設

**Files:**
- Create: `core/dispatch.awk`
- Modify: `hawk.awk`
- Modify: `core/env.awk`
- Modify: `core/hawk.awk`

- [ ] **Step 1: `core/dispatch.awk` を作成**

```awk
# SPDX-License-Identifier: MIT
# core/dispatch.awk -- namespace dispatch 共通ルーター
#
# 使い方:
#   各 namespace の BEGIN ブロックで routes テーブルを設定し、
#   dispatch() 関数から hawk_dispatch::call() を呼ぶ。
#
# 例:
#   BEGIN { _ENV_ROUTES["get"] = "env::get" }
#   function dispatch(path, a1, a2, a3) {
#       return hawk_dispatch::call("env", _ENV_ROUTES, path, a1, a2, a3)
#   }

@namespace "hawk_dispatch"

function call(ns, routes, path, a1, a2, a3) {
    if (!(path in routes)) {
        print ns "::dispatch: unknown path: " path > "/dev/stderr"
        return ""
    }
    return @routes[path](a1, a2, a3)
}

@namespace "awk"
```

- [ ] **Step 2: `hawk.awk` の `@include` 順序を更新**

`@include "core/util.awk"` の直後（他の core より前）に `@include "core/dispatch.awk"` を追加。

変更前:
```awk
@include "core/util.awk"
@include "core/libs.awk"
```

変更後:
```awk
@include "core/util.awk"
@include "core/dispatch.awk"
@include "core/libs.awk"
```

- [ ] **Step 3: `core/env.awk` を routes テーブル方式に書き換え**

`dispatch` 関数と `@namespace "env"` ブロック全体を以下に置き換え（`get/set/del/has` 関数は変更しない）:

```awk
@namespace "env"

BEGIN {
    _ENV_ROUTES["get"] = "env::get"
    _ENV_ROUTES["set"] = "env::set"
    _ENV_ROUTES["del"] = "env::del"
    _ENV_ROUTES["has"] = "env::has"
}

function get(key)      { return ENVIRON[key] }
function set(key, val) { ENVIRON[key] = val }
function del(key)      { delete ENVIRON[key] }
function has(key)      { return (key in ENVIRON) }

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("env", _ENV_ROUTES, path, a1, a2, a3)
}

@namespace "awk"
```

- [ ] **Step 4: `core/hawk.awk` を routes テーブル方式に書き換え**

`dispatch` 関数を以下に置き換え（`get/post/put/del/patch/head/on/all/listen` 関数は変更しない）:

```awk
BEGIN {
    _HAWK_ROUTES["app.get"]    = "hawk::get"
    _HAWK_ROUTES["app.post"]   = "hawk::post"
    _HAWK_ROUTES["app.put"]    = "hawk::put"
    _HAWK_ROUTES["app.del"]    = "hawk::del"
    _HAWK_ROUTES["app.patch"]  = "hawk::patch"
    _HAWK_ROUTES["app.head"]   = "hawk::head"
    _HAWK_ROUTES["app.on"]     = "hawk::on"
    _HAWK_ROUTES["app.all"]    = "hawk::all"
    _HAWK_ROUTES["app.listen"] = "hawk::listen"
}

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("hawk", _HAWK_ROUTES, path, a1, a2, a3)
}
```

`BEGIN` ブロックは `@namespace "hawk"` の直後（既存関数の前）に置く。

- [ ] **Step 5: dispatch が動作することを確認**

```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN {
  ENVIRON["TEST_PORT"] = "9999"
  v = env::dispatch("get", "TEST_PORT")
  if (v != "9999") { print "FAIL env::get: got " v > "/dev/stderr"; exit 1 }
  env::dispatch("set", "TEST_KEY", "hello")
  v = env::dispatch("get", "TEST_KEY")
  if (v != "hello") { print "FAIL env::set: got " v > "/dev/stderr"; exit 1 }
  hawk::dispatch("app.get", "/test", "handler")
  print "OK"
  exit 0
}' 2>&1
```

Expected: `OK`

不明な path のエラー確認:
```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN { env::dispatch("unknown"); exit 0 }' 2>&1
```

Expected: `env::dispatch: unknown path: unknown`

- [ ] **Step 6: DSL テスト全パスを確認**

```bash
make test-dsl 2>&1
```

Expected: `14 passed, 0 failed`

- [ ] **Step 7: commit**

```bash
git add core/dispatch.awk hawk.awk core/env.awk core/hawk.awk
git commit -m "refactor(dispatch): add hawk_dispatch::call router, replace if-chains with route tables"
```

---

## Task 2: `dsl/type.awk` — 移動 + 型レジストリ

**Files:**
- Create: `dsl/type.awk`
- Delete: `core/type.awk`
- Modify: `hawk.awk`
- Modify: `dsl/desugar.awk`

- [ ] **Step 1: `dsl/type.awk` を作成**

`core/type.awk` の内容をベースに、型レジストリ（`_DS_TYPE_RETURNS`）を `@namespace "awk"` セクションに追加する。

```awk
# SPDX-License-Identifier: MIT
# dsl/type.awk -- DSL 型アノテーション用ランタイム変換 + 型レジストリ
#
# type::coerce(val, typename)  -- ランタイム型変換（デシュガー出力から呼ばれる）
# _DS_TYPE_RETURNS[]           -- 既知 DSL 関数の戻り型（デシュガー時静的チェック用）

@namespace "type"

function coerce(val, typename) {
    if (typename == "Int") {
        if (val !~ /^-?[0-9]+$/) {
            print "type error: cannot coerce \"" val "\" to Int" > "/dev/stderr"
            exit 1
        }
        return int(val)
    }
    if (typename == "Float") {
        if (val !~ /^-?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?$/) {
            print "type error: cannot coerce \"" val "\" to Float" > "/dev/stderr"
            exit 1
        }
        return val + 0
    }
    if (typename == "Str") {
        return val ""
    }
    if (typename == "Bool") {
        if (val == "true"  || val == "1") return 1
        if (val == "false" || val == "0" || val == "") return 0
        print "type error: cannot coerce \"" val "\" to Bool" > "/dev/stderr"
        exit 1
    }
    print "type::coerce: unknown type: " typename > "/dev/stderr"
    exit 1
}

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

**注意:** `_DS_TYPE_RETURNS` は `@namespace "awk"` に置く。`@namespace "type"` に置くと `type::_DS_TYPE_RETURNS` になり、`desugar_let.awk` から名前空間修飾なしでアクセスできなくなる。

- [ ] **Step 2: `hawk.awk` の `@include` を変更**

変更前:
```awk
@include "core/type.awk"
```

変更後:
```awk
@include "dsl/type.awk"
```

- [ ] **Step 3: `dsl/desugar.awk` に `@include "dsl/type.awk"` を追加**

既存の include の末尾に追加:

変更前:
```awk
@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/desugar_let.awk"
```

変更後:
```awk
@include "dsl/desugar_state.awk"
@include "dsl/desugar_strings.awk"
@include "dsl/desugar_dot.awk"
@include "dsl/desugar_nullcoalesce.awk"
@include "dsl/desugar_let.awk"
@include "dsl/type.awk"
```

- [ ] **Step 4: `core/type.awk` を削除**

```bash
git rm core/type.awk
```

- [ ] **Step 5: `type::coerce` がランタイムで動作することを確認**

```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN {
  v = type::coerce("42", "Int")
  if (v != 42) { print "FAIL: got " v > "/dev/stderr"; exit 1 }
  v = type::coerce("hello", "Str")
  if (v != "hello") { print "FAIL: got " v > "/dev/stderr"; exit 1 }
  print "OK"
  exit 0
}' 2>&1
```

Expected: `OK`

- [ ] **Step 6: 全テスト確認**

```bash
make test-dsl 2>&1
```

Expected: `14 passed, 0 failed`

- [ ] **Step 7: commit**

```bash
git add dsl/type.awk hawk.awk dsl/desugar.awk
git commit -m "refactor(type): move core/type.awk to dsl/type.awk, add _DS_TYPE_RETURNS registry"
```

---

## Task 3: エラー fixture サポートを `run.sh` に追加

**Files:**
- Modify: `tests/unit/dsl/run.sh`

エラー系 DSL fixture では `expected.awk` の代わりに `expected_stderr`（期待する stderr の部分文字列）と `expected_exit`（期待する終了コード）を使う。

- [ ] **Step 1: `tests/unit/dsl/run.sh` を更新**

現在の `for` ループを以下に置き換える:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -e
cd "$(dirname "$0")/../../.."

PASS=0; FAIL=0

for dir in tests/unit/dsl/*/; do
  name=$(basename "$dir")

  # エラー fixture: expected_stderr が存在する場合
  if [[ -f "${dir}expected_stderr" ]]; then
    [[ -f "${dir}input.awk" ]] || continue
    expected_exit=1
    [[ -f "${dir}expected_exit" ]] && expected_exit=$(cat "${dir}expected_exit")
    expected_msg=$(cat "${dir}expected_stderr")

    actual_stderr=$(gawk -f dsl/desugar.awk "${dir}input.awk" 2>&1 >/dev/null; true)
    actual_exit=$?
    # サブシェルで exit code を取得
    actual_stderr=$(gawk -f dsl/desugar.awk "${dir}input.awk" 2>&1 || true)
    set +e
    gawk -f dsl/desugar.awk "${dir}input.awk" >/dev/null 2>/dev/null
    actual_exit=$?
    set -e
    actual_stderr=$(gawk -f dsl/desugar.awk "${dir}input.awk" 2>&1 || true)

    if [[ "$actual_exit" -eq "$expected_exit" ]] && echo "$actual_stderr" | grep -qF "$expected_msg"; then
      printf "  PASS: %s\n" "$name"
      PASS=$((PASS + 1))
    else
      printf "  FAIL: %s\n" "$name"
      printf "    expected exit=%s, got exit=%s\n" "$expected_exit" "$actual_exit"
      printf "    expected stderr to contain: %s\n" "$expected_msg"
      printf "    actual stderr: %s\n" "$actual_stderr"
      FAIL=$((FAIL + 1))
    fi
    continue
  fi

  # 通常 fixture: expected.awk が存在する場合
  [[ -f "${dir}input.awk" ]] || continue
  [[ -f "${dir}expected.awk" ]] || continue

  actual=$(gawk -f dsl/desugar.awk "${dir}input.awk" 2>/dev/null | grep -v '^# line ')

  if diff -u "${dir}expected.awk" <(printf '%s\n' "$actual") >/dev/null 2>&1; then
    printf "  PASS: %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL: %s\n" "$name"
    diff -u "${dir}expected.awk" <(printf '%s\n' "$actual") || true
    FAIL=$((FAIL + 1))
  fi
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
```

**注意:** `expected_stderr` の中身は期待する stderr の**部分文字列**。`grep -qF` で完全一致ではなく含まれているかを確認する。これにより `expected_stderr` にファイルパスを含めなくてよい。

- [ ] **Step 2: テストが引き続き通ることを確認**

```bash
make test-dsl 2>&1
```

Expected: `14 passed, 0 failed`

- [ ] **Step 3: commit**

```bash
git add tests/unit/dsl/run.sh
git commit -m "test(dsl): add error fixture support (expected_stderr + expected_exit) to run.sh"
```

---

## Task 4: DSL 型システム — 裸宣言・静的チェック・型付き代入

**Files:**
- Modify: `dsl/desugar_state.awk`
- Modify: `dsl/desugar.awk`
- Modify: `dsl/desugar_let.awk`
- Create: `tests/unit/dsl/type_bare_decl/{input,expected}.awk`
- Create: `tests/unit/dsl/type_bare_assign/{input,expected}.awk`
- Create: `tests/unit/dsl/type_static_error_literal/{input.awk,expected_stderr,expected_exit}`
- Create: `tests/unit/dsl/type_static_error_known_func/{input.awk,expected_stderr,expected_exit}`

### Step 1-2: `type_bare_decl` fixture（裸宣言のホイスト）

- [ ] **Step 1: fixture 作成**

`tests/unit/dsl/type_bare_decl/input.awk`:
```awk
function setup() {
  let i: Int
  let s: Str
  i = 42
  s = "hello"
}
```

`tests/unit/dsl/type_bare_decl/expected.awk`:
```awk
function setup(    i, s) {
  i = 42
  s = "hello"
}
```

**注意:** この段階では型付き代入変換はまだ実装しない。`i = 42` はそのまま出力される。

- [ ] **Step 2: テストが FAIL することを確認**

```bash
make test-dsl 2>&1 | grep type_bare_decl
```

Expected: `  FAIL: type_bare_decl`

### Step 3-6: `dsl/desugar_state.awk` + `dsl/desugar.awk` 修正

- [ ] **Step 3: `dsl/desugar_state.awk` に `_DS_let_type_map` 追加**

`_ds_init()` 関数の末尾（`delete _DS_body_buf` の後）に追加:

```awk
  delete _DS_let_type_map
```

変更後の関数全体:
```awk
function _ds_init() {
  _DS_brace_depth = 0
  _DS_in_function = 0
  _DS_func_name   = ""
  _DS_func_sig    = ""
  _DS_let_count   = 0
  _DS_body_count  = 0
  _DS_tc_count    = 0
  _DS_had_error   = 0
  _DS_src_file    = ""
  delete _DS_let_locals
  delete _DS_body_buf
  delete _DS_let_type_map
}
```

- [ ] **Step 4: `dsl/desugar.awk` の関数スコープリセットに `_DS_let_type_map` を追加**

`_ds_process_line` 内の関数定義検出ブロック（`delete _DS_let_locals` の行の後）に追加:

変更前:
```awk
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_body_buf
```

変更後:
```awk
      _DS_let_count    = 0
      _DS_body_count   = 0
      delete _DS_let_locals
      delete _DS_let_type_map
      delete _DS_body_buf
```

- [ ] **Step 5: `dsl/desugar_let.awk` に裸宣言パターンを追加**

型付き代入パターン（`let name: Type = expr`）の直後に裸宣言パターンを追加:

```awk
  # Bare typed declaration: let name: Type  (初期値なし)
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    return ""
  }
```

このパターンは型付き代入パターン（`= expr` あり）の後、プレーン代入パターンの前に置く。

- [ ] **Step 6: `type_bare_decl` テストが PASS することを確認**

```bash
make test-dsl 2>&1 | grep -E "type_bare_decl|passed|failed"
```

Expected: `  PASS: type_bare_decl`

### Step 7-10: `type_bare_assign` fixture（型付き代入の自動 coerce）

- [ ] **Step 7: fixture 作成**

`tests/unit/dsl/type_bare_assign/input.awk`:
```awk
function process() {
  let n: Int
  let s: Str
  n = "99"
  s = 123
}
```

`tests/unit/dsl/type_bare_assign/expected.awk`:
```awk
function process(    n, s) {
  n = type::coerce("99", "Int")
  s = type::coerce(123, "Str")
}
```

- [ ] **Step 8: テストが FAIL することを確認**

```bash
make test-dsl 2>&1 | grep type_bare_assign
```

Expected: `  FAIL: type_bare_assign`

- [ ] **Step 9: `dsl/desugar_let.awk` に型付き代入変換を追加**

`_ds_let_transform` の末尾の `return line` の直前に追加:

```awk
  # 型付き変数への代入を coerce でラップ
  # パターン: varname = rhs  (varname が _DS_let_type_map に登録されている場合)
  # =[^=<>!~] で ==, !=, <=, >=, =~, !~ を除外
  if (match(line, /^([[:space:]]*)([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=([^=<>!~].*)$/, arr)) {
    if (arr[2] in _DS_let_type_map) {
      rhs      = _ds_trim(arr[3])
      declared = _DS_let_type_map[arr[2]]
      _ds_check_type(declared, _ds_infer_type(rhs), lineno)
      return arr[1] arr[2] " = type::coerce(" rhs ", \"" declared "\")"
    }
  }
  return line
```

`_ds_trim` は `dsl/desugar_nullcoalesce.awk` で定義済み。

- [ ] **Step 10: `type_bare_assign` テストが PASS することを確認**

```bash
make test-dsl 2>&1 | grep -E "type_bare_assign|passed|failed"
```

Expected: `  PASS: type_bare_assign`

### Step 11-16: 静的型チェック

- [ ] **Step 11: エラー fixture 作成（リテラル不一致）**

`tests/unit/dsl/type_static_error_literal/input.awk`:
```awk
function setup() {
  let port: Int = "hello"
}
```

`tests/unit/dsl/type_static_error_literal/expected_stderr`:
```
type mismatch: cannot assign Str to Int
```

`tests/unit/dsl/type_static_error_literal/expected_exit`:
```
1
```

- [ ] **Step 12: エラー fixture 作成（既知関数戻り型不一致）**

`tests/unit/dsl/type_static_error_known_func/input.awk`:
```awk
function setup() {
  let port: Int = env.get("PORT")
}
```

`tests/unit/dsl/type_static_error_known_func/expected_stderr`:
```
type mismatch: cannot assign Str to Int
```

`tests/unit/dsl/type_static_error_known_func/expected_exit`:
```
1
```

- [ ] **Step 13: エラーテストが FAIL（まだ実装前なので通過してしまう）することを確認**

```bash
make test-dsl 2>&1 | grep -E "static_error|passed|failed"
```

Expected: `  FAIL: type_static_error_literal` と `  FAIL: type_static_error_known_func`（実装前なのでエラーにならない = テストが FAIL する）

- [ ] **Step 14: `dsl/desugar_let.awk` に `_ds_infer_type` + `_ds_check_type` を追加**

ファイルの先頭（`_ds_let_transform` 関数の前）に追加:

```awk
# _ds_infer_type: 式の静的型を推論する。不明な場合は "" を返す
function _ds_infer_type(expr,    m) {
    # 文字列リテラル: "..." 形式
    if (expr ~ /^".*"$/) return "Str"
    # 整数リテラル: オプショナルな負号 + 数字のみ
    if (expr ~ /^-?[0-9]+$/) return "Int"
    # 浮動小数リテラル: -?[0-9]*.[0-9]+ 形式
    if (expr ~ /^-?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?$/) return "Float"
    # Bool リテラル
    if (expr == "true" || expr == "false") return "Bool"
    # 既知の DSL 関数呼び出し: ns.method(...) 形式
    # _DS_TYPE_RETURNS は dsl/type.awk の BEGIN ブロックで定義
    if (match(expr, /^([a-z][a-zA-Z0-9_]*)\.([a-z][a-zA-Z0-9_]*)\(/, m)) {
        key = m[1] "." m[2]
        if (key in _DS_TYPE_RETURNS) return _DS_TYPE_RETURNS[key]
    }
    return ""
}

# _ds_check_type: declared と inferred が不一致ならエラーを記録する
# inferred が "" (不明) の場合はチェックしない
function _ds_check_type(declared, inferred, lineno) {
    if (inferred == "" || inferred == declared) return
    print "dsl error: " _DS_src_file ":" lineno \
        ": type mismatch: cannot assign " inferred " to " declared > "/dev/stderr"
    _DS_had_error = 1
}
```

- [ ] **Step 15: 型付き代入パターン（`let name: Type = expr`）に静的チェックを追加**

`dsl/desugar_let.awk` の型付き代入ブロックを更新:

変更前:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
  }
```

変更後:
```awk
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*([A-Z][a-zA-Z0-9]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    _DS_let_type_map[arr[2]] = arr[3]
    _ds_check_type(arr[3], _ds_infer_type(arr[4]), lineno)
    return arr[1] arr[2] " = type::coerce(" arr[4] ", \"" arr[3] "\")"
  }
```

エラーがあっても `_DS_had_error = 1` をセットして変換を続行する（複数エラーを一度に表示するため）。`desugar.awk` の `END` ブロックが `_DS_had_error` を見て `exit 1` する。

- [ ] **Step 16: 全テストが PASS することを確認**

```bash
make test-dsl 2>&1
```

Expected: `18 passed, 0 failed`（14 既存 + type_bare_decl + type_bare_assign + type_static_error_literal + type_static_error_known_func）

- [ ] **Step 17: commit**

```bash
git add dsl/desugar_state.awk dsl/desugar.awk dsl/desugar_let.awk \
  tests/unit/dsl/type_bare_decl/ tests/unit/dsl/type_bare_assign/ \
  tests/unit/dsl/type_static_error_literal/ tests/unit/dsl/type_static_error_known_func/
git commit -m "feat(dsl): add let bare type declaration, typed assignment coerce, static type checking"
```

---

## 完了確認

全タスク完了後:

```bash
make test-dsl 2>&1
```

Expected: `18 passed, 0 failed`

```bash
echo '' | gawk -v HAWK_NO_SERVE=1 -f hawk.awk -e '
BEGIN {
  env::dispatch("set", "PORT", "3000")
  v = env::dispatch("get", "PORT")
  print "env dispatch OK: " v
  v = type::coerce("42", "Int")
  print "type coerce OK: " v
  exit 0
}' 2>&1
```

Expected:
```
env dispatch OK: 3000
type coerce OK: 42
```
