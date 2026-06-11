# hawk env:: Namespace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `env::` namespace を新規追加し、gawk 組み込みの `ENVIRON` 配列に対する薄いラッパー（get/set/del/has）を提供する。

**Architecture:** `core/env.awk` を `@namespace "env"` で新規作成。4関数はすべて `ENVIRON` 直接操作の1行ラッパー。`hawk.awk` に `@include "core/env.awk"` を追加。テストは TDD で先行作成。

**Tech Stack:** gawk 5.0+（`@namespace` 必須）。

---

## ファイル構成

- 新規: `core/env.awk` — `@namespace "env"` 本体（get/set/del/has）
- 変更: `hawk.awk` — `@include "core/env.awk"` を追加
- 新規: `tests/unit/test_env.awk` — 7テスト関数
- 変更: `tests/unit/run.awk` — `@include` と呼び出し追加

---

## Task 1: テスト先行作成と run.awk への配線

**Files:**
- Create: `tests/unit/test_env.awk`
- Modify: `tests/unit/run.awk`

### gawk キーワード注意

`env::del` は `del` という関数名（`delete` キーワードではない）。テスト側は `env::del("KEY")` を呼ぶ。

### テスト隔離戦略

テスト用キーは `__TEST_ENV_*` プレフィックス。各テスト関数が使用後に `delete ENVIRON["__TEST_ENV_*"]` でクリーンアップ。

- [ ] **Step 1: `tests/unit/test_env.awk` を作成する**

```awk
# SPDX-License-Identifier: MIT

function test_env_get_existing() {
  ENVIRON["__TEST_ENV_KEY"] = "hello"
  assert_eq(env::get("__TEST_ENV_KEY"), "hello", "env::get existing")
  delete ENVIRON["__TEST_ENV_KEY"]
}

function test_env_get_missing() {
  delete ENVIRON["__TEST_ENV_MISSING"]
  assert_eq(env::get("__TEST_ENV_MISSING"), "", "env::get missing")
}

function test_env_set() {
  env::set("__TEST_ENV_SET", "world")
  assert_eq(env::get("__TEST_ENV_SET"), "world", "env::set then get")
  delete ENVIRON["__TEST_ENV_SET"]
}

function test_env_del() {
  ENVIRON["__TEST_ENV_DEL"] = "temp"
  env::del("__TEST_ENV_DEL")
  assert_eq(env::has("__TEST_ENV_DEL"), 0, "env::del then has")
}

function test_env_has_existing() {
  ENVIRON["__TEST_ENV_HAS"] = "1"
  assert_eq(env::has("__TEST_ENV_HAS"), 1, "env::has existing")
  delete ENVIRON["__TEST_ENV_HAS"]
}

function test_env_has_missing() {
  delete ENVIRON["__TEST_ENV_HAS_MISSING"]
  assert_eq(env::has("__TEST_ENV_HAS_MISSING"), 0, "env::has missing")
}

function test_env_set_overwrite() {
  env::set("__TEST_ENV_OW", "first")
  env::set("__TEST_ENV_OW", "second")
  assert_eq(env::get("__TEST_ENV_OW"), "second", "env::set overwrite")
  delete ENVIRON["__TEST_ENV_OW"]
}
```

- [ ] **Step 2: `tests/unit/run.awk` に @include と呼び出しを追加する**

`run.awk` の最終行（現在 `@include "tests/unit/test_hawk.awk"`）の後に追加:

```awk
@include "tests/unit/test_env.awk"
```

BEGIN ブロック内の `test_hawk_all_multi_paths()` 呼び出し（現在82行目）の直後に追加:

```awk
  test_env_get_existing()
  test_env_get_missing()
  test_env_set()
  test_env_del()
  test_env_has_existing()
  test_env_has_missing()
  test_env_set_overwrite()
```

- [ ] **Step 3: テストが失敗することを確認する**

```bash
make test-unit 2>&1 | tail -5
```

期待出力（`env::get` 未定義エラー）:

```
gawk: fatal: function `env::get' not defined
```

または `FAIL` が 7 件以上出力される。`env::` namespace が未実装なのでエラーが出るのが正常。

- [ ] **Step 4: コミットする**

```bash
git add tests/unit/test_env.awk tests/unit/run.awk
git commit -m "test(env): add env:: unit tests (failing)"
```

---

## Task 2: `core/env.awk` 実装と `hawk.awk` への配線

**Files:**
- Create: `core/env.awk`
- Modify: `hawk.awk`

- [ ] **Step 1: `core/env.awk` を作成する**

```awk
# SPDX-License-Identifier: MIT
# core/env.awk -- env:: namespace: ENVIRON ラッパー (Deno.env スタイル)
#
# 提供関数:
#   env::get(key)       -- ENVIRON[key] を返す。未定義時 "" を返す
#   env::set(key, val)  -- ENVIRON[key] = val
#   env::del(key)       -- delete ENVIRON[key]
#   env::has(key)       -- key in ENVIRON → 1 または 0
#
# 注意: env::set の変更は同プロセス内のみ有効。子プロセスへは伝播しない（gawk 仕様）

@namespace "env"

function get(key)      { return ENVIRON[key] }
function set(key, val) { ENVIRON[key] = val }
function del(key)      { delete ENVIRON[key] }
function has(key)      { return (key in ENVIRON) }

@namespace "awk"
```

- [ ] **Step 2: `hawk.awk` に `@include "core/env.awk"` を追加する**

`hawk.awk` の現在の内容（31行）:

```awk
@include "core/util.awk"
@include "core/libs.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/hawk.awk"
@include "core/router.awk"
@include "core/ctx.awk"
@include "core/plugin.awk"
@include "core/http.awk"
```

`@include "core/hawk.awk"` の直後に1行追加:

```awk
@include "core/env.awk"
```

変更後（該当箇所のみ）:

```awk
@include "core/hawk.awk"
@include "core/env.awk"
@include "core/router.awk"
```

- [ ] **Step 3: テストがすべてパスすることを確認する**

```bash
make test-unit 2>&1 | tail -3
```

期待出力（env:: 追加で 7 件増加、既存 182 件＋新規 7 件）:

```
189 passed, 0 failed, 12 skipped
```

`FAIL` が 0 であることを確認すること。

- [ ] **Step 4: コミットする**

```bash
git add core/env.awk hawk.awk
git commit -m "feat(core): add env:: namespace as ENVIRON wrapper (get/set/del/has)"
```
