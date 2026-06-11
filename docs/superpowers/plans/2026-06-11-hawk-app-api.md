# hawk:: App API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `hawk::` namespace を App API の一次インターフェースとして確立し、`GET/POST/...` を後方互換エイリアスに変える。

**Architecture:** 新規 `core/hawk.awk`（`@namespace "hawk"`）を `core/router.awk` より前にロードし、`hawk::get/post/put/delete/patch/head/on/all/listen` を定義する。`router.awk` の `GET/POST/...` は `hawk::get/post/...` を呼ぶ薄いラッパーに変更する。`hawk::on/all` は gawk の `isarray()` で scalar/array を両対応し、メソッド×パスの直積を `_route_add` に送る。

**Tech Stack:** gawk 5.0+（`@namespace`・`isarray()` 使用）、`core/util.awk` の `to_upper/trim` を `awk::to_upper/awk::trim` として参照。

---

## ファイル構成

| ファイル | 操作 | 内容 |
|---|---|---|
| `core/hawk.awk` | 新規 | `@namespace "hawk"` の App API 本体 |
| `hawk.awk` | 変更 | `@include "core/hawk.awk"` を router より前に追加 |
| `core/router.awk` | 変更 | `GET/POST/...` を `hawk::get/post/...` のラッパーに変更 |
| `tests/unit/test_hawk.awk` | 新規 | 9 つのユニットテスト |
| `tests/unit/run.awk` | 変更 | test_hawk.awk の include + 呼出し追加 |
| `app.awk` | 変更 | `hawk::` スタイルに更新 |
| `README.md` | 変更 | hawk:: API リファレンス追加 |

---

## Task 1: core/hawk.awk スケルトン + ロード順変更

**Files:**
- Create: `core/hawk.awk`
- Modify: `hawk.awk`

### コンテキスト

`hawk.awk` はエントリポイントで `core/*.awk` を順番に `@include` する。現在の順序:

```awk
@include "core/router.awk"
@include "core/ctx.awk"
```

`core/hawk.awk` は `core/router.awk` より前にロードする必要がある（router.awk の `GET()` が `hawk::get()` を呼ぶため）。

`hawk.awk` のロード順（現在 hawk.awk:26-27 付近）。gawk では `@namespace "hawk"` ブロック内で `awk::to_upper` のように別 namespace を参照できる。

- [ ] **Step 1: `core/hawk.awk` スケルトンを作成する**

```awk
# SPDX-License-Identifier: MIT
# core/hawk.awk -- hawk:: App API (Hono-style)
#
# hawk:: は H-awk の一次ルーティング API。
# GET/POST/... は後方互換エイリアスとして core/router.awk で定義する。

@namespace "hawk"

function get(path, handler)    { awk::_route_add("GET",    path, handler) }
function post(path, handler)   { awk::_route_add("POST",   path, handler) }
function put(path, handler)    { awk::_route_add("PUT",    path, handler) }
function delete(path, handler) { awk::_route_add("DELETE", path, handler) }
function patch(path, handler)  { awk::_route_add("PATCH",  path, handler) }
function head(path, handler)   { awk::_route_add("HEAD",   path, handler) }

function on(methods, paths, handler,    ms, ps, i, j) {
  if (isarray(methods)) { for (i in methods) ms[i] = awk::to_upper(awk::trim(methods[i])) }
  else                  { ms[1] = awk::to_upper(awk::trim(methods)) }
  if (isarray(paths))   { for (i in paths)   ps[i] = awk::trim(paths[i]) }
  else                  { ps[1] = awk::trim(paths) }
  for (i in ms) for (j in ps) awk::_route_add(ms[i], ps[j], handler)
}

function all(paths, handler,    std_ms, ps, i, j) {
  split("GET POST PUT DELETE PATCH HEAD OPTIONS", std_ms, " ")
  if (isarray(paths)) { for (i in paths) ps[i] = awk::trim(paths[i]) }
  else                { ps[1] = awk::trim(paths) }
  for (i in std_ms) for (j in ps) awk::_route_add(std_ms[i], ps[j], handler)
}

function listen(port) { awk::listen(port) }

@namespace "awk"
```

- [ ] **Step 2: `hawk.awk` のロード順を変更する**

`hawk.awk` の現在の該当行（`@include "core/router.awk"` の直前）を確認し、`core/hawk.awk` を追加する。

変更前:
```awk
@include "core/router.awk"
@include "core/ctx.awk"
```

変更後:
```awk
@include "core/hawk.awk"
@include "core/router.awk"
@include "core/ctx.awk"
```

- [ ] **Step 3: 既存テストが壊れていないことを確認する**

```bash
HAWK_NO_SERVE=1 make test-unit
```

Expected: 全テスト PASS（hawk:: 関数はまだ router.awk から呼ばれていないが、スケルトンが存在することで gawk のパースエラーが出ないことを確認）。

- [ ] **Step 4: コミット**

```bash
git add core/hawk.awk hawk.awk
git commit -m "feat(core): add hawk:: App API skeleton with method shortcuts and on/all"
```

---

## Task 2: test_hawk.awk — method shortcuts + listen + compat テスト

**Files:**
- Create: `tests/unit/test_hawk.awk`
- Modify: `tests/unit/run.awk`

### コンテキスト

テストは `HAWK_NO_SERVE=1 gawk -f hawk.awk -f tests/unit/run.awk` で実行される。`run.awk` が全 test_*.awk を `@include` し、`BEGIN` 内で各テスト関数を呼び出す。

既存の `_router_reset()` は `test_router.awk` で定義されており、`run.awk` から `@include` されるため、`test_hawk.awk` からも使用可能。ハンドラ `_t_hello`（body: "hello"）と `_t_add`（status: 201, body: "added"）も `test_router.awk` で定義済み。

- [ ] **Step 1: `tests/unit/test_hawk.awk` を作成する**

```awk
# SPDX-License-Identifier: MIT

function test_hawk_shortcuts(    req, res) {
  _router_reset()
  hawk::get("/a",    "_t_hello")
  hawk::post("/b",   "_t_add")
  hawk::put("/c",    "_t_hello")
  hawk::delete("/d", "_t_hello")
  hawk::patch("/e",  "_t_hello")
  hawk::head("/f",   "_t_hello")

  delete req; req["method"] = "GET";    req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::get registers GET /a")

  delete req; req["method"] = "POST";   req["path"] = "/b"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::post registers POST /b")
  assert_eq(res["status"], 201,              "hawk::post: handler status")

  delete req; req["method"] = "PUT";    req["path"] = "/c"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::put registers PUT /c")

  delete req; req["method"] = "DELETE"; req["path"] = "/d"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::delete registers DELETE /d")

  delete req; req["method"] = "PATCH";  req["path"] = "/e"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::patch registers PATCH /e")

  delete req; req["method"] = "HEAD";   req["path"] = "/f"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::head registers HEAD /f")
}

function test_hawk_compat_GET(    req, res) {
  _router_reset()
  GET("/compat", "_t_hello")
  delete req; req["method"] = "GET"; req["path"] = "/compat"; delete res
  assert_eq(router_dispatch(req, res), 1,       "compat GET: matched")
  assert_eq(res["body"], "hello",               "compat GET: body")
}
```

- [ ] **Step 2: `run.awk` に test_hawk.awk の include と呼出しを追加する**

`@include "tests/unit/test_ctx.awk"` の直後に追加:
```awk
@include "tests/unit/test_hawk.awk"
```

`BEGIN` の末尾（`printf "%d passed..."` の直前）に追加:
```awk
  test_hawk_shortcuts()
  test_hawk_compat_GET()
```

- [ ] **Step 3: テスト実行 — PASS 確認（Task 1 でスケルトン実装済みのため）**

```bash
HAWK_NO_SERVE=1 make test-unit 2>&1 | tail -5
```

Expected: `test_hawk_shortcuts` と `test_hawk_compat_GET` が PASS。

- [ ] **Step 4: コミット**

```bash
git add tests/unit/test_hawk.awk tests/unit/run.awk
git commit -m "test(hawk): add unit tests for method shortcuts and compat aliases"
```

---

## Task 3: `router.awk` — GET/POST/... をラッパーに変更

**Files:**
- Modify: `core/router.awk:9-14`

### コンテキスト

`core/router.awk` の先頭 6 行（`GET` ～ `HEAD`）が現在 `_route_add` を直接呼んでいる。これを `hawk::get/post/...` に変更する。`core/hawk.awk` が先にロードされているため、`hawk::` 関数は定義済みの状態。

- [ ] **Step 1: `core/router.awk` の alias 行を変更する**

変更前（9-14行）:
```awk
function GET(path, handler)    { _route_add("GET",    path, handler) }
function POST(path, handler)   { _route_add("POST",   path, handler) }
function PUT(path, handler)    { _route_add("PUT",    path, handler) }
function DELETE(path, handler) { _route_add("DELETE", path, handler) }
function PATCH(path, handler)  { _route_add("PATCH",  path, handler) }
function HEAD(path, handler)   { _route_add("HEAD",   path, handler) }
```

変更後:
```awk
function GET(path, handler)    { hawk::get(path, handler) }
function POST(path, handler)   { hawk::post(path, handler) }
function PUT(path, handler)    { hawk::put(path, handler) }
function DELETE(path, handler) { hawk::delete(path, handler) }
function PATCH(path, handler)  { hawk::patch(path, handler) }
function HEAD(path, handler)   { hawk::head(path, handler) }
```

- [ ] **Step 2: テスト実行 — `test_hawk_compat_GET` を含む全テスト PASS 確認**

```bash
HAWK_NO_SERVE=1 make test-unit 2>&1 | tail -5
```

Expected: 全テスト PASS（`test_hawk_compat_GET` が `GET()` → `hawk::get()` → `_route_add()` 経路を検証済み）。

- [ ] **Step 3: コミット**

```bash
git add core/router.awk
git commit -m "refactor(router): make GET/POST/... thin wrappers over hawk:: API"
```

---

## Task 4: `hawk::on` テスト

**Files:**
- Modify: `tests/unit/test_hawk.awk`
- Modify: `tests/unit/run.awk`

### コンテキスト

`hawk::on` は Task 1 のスケルトンで既に実装済み。テストを追加して動作を検証する。

- [ ] **Step 1: `test_hawk.awk` に `on` テストを追加する（ファイル末尾に追記）**

```awk
function test_hawk_on_single(    req, res) {
  _router_reset()
  hawk::on("GET", "/a", "_t_hello")
  delete req; req["method"] = "GET"; req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1,     "hawk::on single: matched")
  assert_eq(res["body"], "hello",             "hawk::on single: body")
}

function test_hawk_on_multi_methods(    ms, req, res) {
  _router_reset()
  delete ms; ms[1] = "GET"; ms[2] = "POST"
  hawk::on(ms, "/a", "_t_hello")
  delete req; req["method"] = "GET";  req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::on multi methods: GET")
  delete req; req["method"] = "POST"; req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::on multi methods: POST")
}

function test_hawk_on_multi_paths(    ps, req, res) {
  _router_reset()
  delete ps; ps[1] = "/a"; ps[2] = "/b"
  hawk::on("GET", ps, "_t_hello")
  delete req; req["method"] = "GET"; req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::on multi paths: /a")
  delete req; req["method"] = "GET"; req["path"] = "/b"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::on multi paths: /b")
}

function test_hawk_on_multi_both(    ms, ps) {
  _router_reset()
  delete ms; ms[1] = "GET"; ms[2] = "POST"
  delete ps; ps[1] = "/a";  ps[2] = "/b"
  hawk::on(ms, ps, "_t_hello")
  assert_eq(ROUTES_COUNT, 4, "hawk::on multi both: 4 entries registered")
}

function test_hawk_on_custom_method(    req, res) {
  _router_reset()
  hawk::on("PURGE", "/cache", "_t_hello")
  delete req; req["method"] = "PURGE"; req["path"] = "/cache"; delete res
  assert_eq(router_dispatch(req, res), 1,   "hawk::on custom method: matched")
  assert_eq(res["body"], "hello",           "hawk::on custom method: body")
}
```

- [ ] **Step 2: `run.awk` の呼出し追加（`test_hawk_compat_GET()` 直後）**

```awk
  test_hawk_on_single()
  test_hawk_on_multi_methods()
  test_hawk_on_multi_paths()
  test_hawk_on_multi_both()
  test_hawk_on_custom_method()
```

- [ ] **Step 3: テスト実行 — PASS 確認**

```bash
HAWK_NO_SERVE=1 make test-unit 2>&1 | tail -5
```

Expected: 5 テスト PASS。

- [ ] **Step 4: コミット**

```bash
git add tests/unit/test_hawk.awk tests/unit/run.awk
git commit -m "test(hawk): add unit tests for hawk::on (single, multi methods/paths, custom)"
```

---

## Task 5: `hawk::all` テスト

**Files:**
- Modify: `tests/unit/test_hawk.awk`
- Modify: `tests/unit/run.awk`

- [ ] **Step 1: `test_hawk.awk` に `all` テストを追加する（ファイル末尾に追記）**

```awk
function test_hawk_all_single(    req, res) {
  _router_reset()
  hawk::all("/x", "_t_hello")
  assert_eq(ROUTES_COUNT, 7, "hawk::all single: 7 entries (GET POST PUT DELETE PATCH HEAD OPTIONS)")
  delete req; req["method"] = "GET";     req["path"] = "/x"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::all: GET /x matched")
  delete req; req["method"] = "OPTIONS"; req["path"] = "/x"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::all: OPTIONS /x matched")
}

function test_hawk_all_multi_paths(    ps) {
  _router_reset()
  delete ps; ps[1] = "/a"; ps[2] = "/b"
  hawk::all(ps, "_t_hello")
  assert_eq(ROUTES_COUNT, 14, "hawk::all multi paths: 7 methods x 2 paths = 14 entries")
}
```

- [ ] **Step 2: `run.awk` の呼出し追加（`test_hawk_on_custom_method()` 直後）**

```awk
  test_hawk_all_single()
  test_hawk_all_multi_paths()
```

- [ ] **Step 3: テスト実行 — PASS 確認**

```bash
HAWK_NO_SERVE=1 make test-unit 2>&1 | tail -5
```

Expected: 2 テスト PASS（`ROUTES_COUNT` 7 と 14）。

- [ ] **Step 4: コミット**

```bash
git add tests/unit/test_hawk.awk tests/unit/run.awk
git commit -m "test(hawk): add unit tests for hawk::all (single path and multi paths)"
```

---

## Task 6: `app.awk` を hawk:: スタイルに更新

**Files:**
- Modify: `app.awk:11-18`

### コンテキスト

`app.awk` は todo デモアプリ。`BEGIN` ブロックで `GET/POST/DELETE` と `listen(8080)` を使っている。`hawk::get/post/delete/listen` に変更する。ハンドラ関数（`todo_index` 等）は変更不要。

- [ ] **Step 1: `app.awk` の BEGIN ブロックを変更する**

変更前:
```awk
BEGIN {
  GET("/",             "todo_index")
  GET("/todos",        "todo_list_html")
  POST("/todos",       "todo_add")
  DELETE("/todos/:id", "todo_delete")
  GET("/todos.json",   "todo_list_json")
  listen(8080)
}
```

変更後:
```awk
BEGIN {
  hawk::get("/",             "todo_index")
  hawk::get("/todos",        "todo_list_html")
  hawk::post("/todos",       "todo_add")
  hawk::delete("/todos/:id", "todo_delete")
  hawk::get("/todos.json",   "todo_list_json")
  hawk::listen(8080)
}
```

- [ ] **Step 2: サーバー起動して動作確認**

```bash
./bin/hawk app.awk &
sleep 1
curl -s http://localhost:8080/todos.json
curl -s -X POST -d 'title=test' http://localhost:8080/todos
curl -s http://localhost:8080/todos.json
kill %1
```

Expected: `/todos.json` が `{"count":...,"items":[...]}` を返す。POST 後にカウントが増える。

- [ ] **Step 3: コミット**

```bash
git add app.awk
git commit -m "feat(app): update demo to use hawk:: App API style"
```

---

## Task 7: README.md に hawk:: API リファレンスを追加

**Files:**
- Modify: `README.md`

### コンテキスト

現在の README の `## Routing` セクションに `GET/POST/...` の説明がある。`hawk::` API のリファレンスを追加し、`GET/POST` は後方互換エイリアスである旨を記載する。

- [ ] **Step 1: `## Routing` セクションの冒頭に hawk:: API リファレンスを追加する**

`## Routing` の `Use ctx:: helpers...` の段落の前に以下を挿入:

```markdown
H-awk の routing は `hawk::` namespace が一次 API。`GET/POST/...` は後方互換エイリアス。

```awk
BEGIN {
  hawk::get("/todos",        "list_todos")
  hawk::post("/todos",       "add_todo")
  hawk::delete("/todos/:id", "delete_todo")
  hawk::listen(8080)
}
```

### hawk:: App API

| 関数 | 説明 |
|---|---|
| `hawk::get(path, handler)` | GET ルート登録 |
| `hawk::post(path, handler)` | POST ルート登録 |
| `hawk::put(path, handler)` | PUT ルート登録 |
| `hawk::delete(path, handler)` | DELETE ルート登録 |
| `hawk::patch(path, handler)` | PATCH ルート登録 |
| `hawk::head(path, handler)` | HEAD ルート登録 |
| `hawk::on(methods, paths, handler)` | 任意メソッド・パスの直積で登録（string または配列） |
| `hawk::all(paths, handler)` | 全7メソッド一括登録（GET POST PUT DELETE PATCH HEAD OPTIONS） |
| `hawk::listen(port)` | サーバー起動 |

`hawk::on` と `hawk::all` はメソッド・パスに gawk 配列を渡して複数登録できる:

```awk
# 複数メソッド
delete ms; ms[1]="GET"; ms[2]="POST"
hawk::on(ms, "/todos", "handler")

# 複数パス
delete ps; ps[1]="/todos"; ps[2]="/tasks"
hawk::on("GET", ps, "handler")

# カスタムメソッド
hawk::on("PURGE", "/cache", "purge_cache")

# 全メソッド一括
hawk::all("/health", "ping")
```
```

- [ ] **Step 2: コミット**

```bash
git add README.md
git commit -m "docs: add hawk:: App API reference to README"
```

---

## 自己レビュー

### スペックカバレッジ確認

- `hawk::get/post/put/delete/patch/head` — Task 1 実装, Task 2 テスト ✓
- `hawk::on` (string×string, array×string, string×array, array×array, custom) — Task 1 実装, Task 4 テスト ✓
- `hawk::all` (single, multi paths) — Task 1 実装, Task 5 テスト ✓
- `hawk::listen` — Task 1 実装, Task 2 テスト（`test_hawk_shortcuts` の動作に含む） ✓
- `GET/POST/...` ラッパー化 — Task 3 ✓
- `router.awk` ラッパー後方互換 — Task 2 の `test_hawk_compat_GET` ✓
- `app.awk` 更新 — Task 6 ✓
- `README.md` 更新 — Task 7 ✓

### 注意点

- `hawk::delete` という名前は gawk の予約語と競合しない（gawk は C と違い `delete` を配列削除演算子として使うが、`@namespace "hawk"` 内では `hawk::delete` として解決されるため問題ない）
- `hawk::on` のローカル変数（`ms`, `ps`）は gawk の慣例に従い引数末尾に空白で区切って記述（コードの `    ms, ps, i, j` 部分）
- `hawk::all` のメソッドリストは `split()` 後に数値インデックスになるため `for (i in std_ms)` でも順序保証は不要（登録順序は `_route_add` の `ROUTES_ORDER` で追跡される）
