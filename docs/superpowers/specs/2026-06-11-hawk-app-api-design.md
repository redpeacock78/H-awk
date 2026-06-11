# hawk:: App API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `hawk::` namespace を App API の一次インターフェースとして確立し、`GET/POST/...` を後方互換エイリアスに変える。

**Architecture:** `core/hawk.awk`（`@namespace "hawk"`）を新規追加し、`hawk.awk` のロード順で `router.awk` より前に挿入する。`router.awk` の `GET/POST/PUT/DELETE/PATCH/HEAD` は `hawk::get/post/...` を呼ぶ薄いラッパーに変更。`hawk::on/all` は `isarray()` で scalar/array を両対応し、メソッド×パスの直積を `_route_add` に送る。

**Tech Stack:** gawk 5.0+（`@namespace`、`isarray()` 必須）、既存 `core/router.awk` の `_route_add` を内部エンジンとして流用。

---

## ファイル構成

- 新規: `core/hawk.awk` — `@namespace "hawk"` の App API 本体
- 変更: `hawk.awk` — include 順に `core/hawk.awk` を `core/router.awk` の前に追加
- 変更: `core/router.awk` — `GET/POST/PUT/DELETE/PATCH/HEAD` をラッパー化
- 新規: `tests/unit/test_hawk.awk` — hawk:: のユニットテスト
- 変更: `tests/unit/run.awk` — test_hawk.awk を追加
- 変更: `app.awk` — `hawk::` スタイルに更新（デモ）
- 変更: `README.md` — hawk:: API リファレンス追加

---

## API リファレンス

### メソッドショートカット

```awk
hawk::get(path, handler)
hawk::post(path, handler)
hawk::put(path, handler)
hawk::delete(path, handler)
hawk::patch(path, handler)
hawk::head(path, handler)
```

### `hawk::on(methods, paths, handler)`

メソッドとパスの直積でルート登録。`methods`・`paths` は文字列または gawk 配列を受け付ける。

```awk
# single
hawk::on("GET", "/todos", "handler")

# multiple methods (array)
delete ms; ms[1]="GET"; ms[2]="POST"
hawk::on(ms, "/todos", "handler")

# multiple paths (array)
delete ps; ps[1]="/todos"; ps[2]="/tasks"
hawk::on("GET", ps, "handler")

# custom method
hawk::on("PURGE", "/cache", "purge_cache")
```

### `hawk::all(paths, handler)`

GET POST PUT DELETE PATCH HEAD OPTIONS の全7メソッドを一括登録。`paths` は文字列または配列。

```awk
hawk::all("/health", "ping")

delete ps; ps[1]="/todos"; ps[2]="/tasks"
hawk::all(ps, "handler")
```

### `hawk::listen(port)`

```awk
hawk::listen(8080)
```

### 後方互換エイリアス（router.awk）

```awk
function GET(p, h)    { hawk::get(p, h) }
function POST(p, h)   { hawk::post(p, h) }
function PUT(p, h)    { hawk::put(p, h) }
function DELETE(p, h) { hawk::delete(p, h) }
function PATCH(p, h)  { hawk::patch(p, h) }
function HEAD(p, h)   { hawk::head(p, h) }
```

---

## 内部実装

### `hawk::on` — isarray() 分岐

```awk
function on(methods, paths, handler,    ms, ps, i, j) {
  if (isarray(methods)) { for (i in methods) ms[i] = awk::to_upper(awk::trim(methods[i])) }
  else                  { ms[1] = awk::to_upper(awk::trim(methods)) }

  if (isarray(paths))   { for (i in paths) ps[i] = awk::trim(paths[i]) }
  else                  { ps[1] = awk::trim(paths) }

  for (i in ms) for (j in ps) awk::_route_add(ms[i], ps[j], handler)
}
```

### `hawk::all`

```awk
function all(paths, handler,    std_ms, ps, i, j) {
  split("GET POST PUT DELETE PATCH HEAD OPTIONS", std_ms, " ")
  if (isarray(paths)) { for (i in paths) ps[i] = awk::trim(paths[i]) }
  else                { ps[1] = awk::trim(paths) }
  for (i in std_ms) for (j in ps) awk::_route_add(std_ms[i], ps[j], handler)
}
```

---

## ロード順変更（hawk.awk）

```awk
# 変更前
@include "core/router.awk"

# 変更後
@include "core/hawk.awk"   # ← 追加（router より前）
@include "core/router.awk"
```

---

## テスト設計

`tests/unit/test_hawk.awk` でカバーする項目（関数名: `test_hawk_*`）:

- `test_hawk_shortcuts` — `hawk::get/post/put/delete/patch/head` 各1エントリ登録確認
- `test_hawk_on_single` — `hawk::on("GET", "/a", "h")` → 1エントリ（string×string）
- `test_hawk_on_multi_methods` — `ms[1]="GET"; ms[2]="POST"` + string path → 2エントリ
- `test_hawk_on_multi_paths` — string method + `ps[1]="/a"; ps[2]="/b"` → 2エントリ
- `test_hawk_on_multi_both` — 2メソッド配列×2パス配列 → 4エントリ
- `test_hawk_on_custom_method` — `hawk::on("PURGE", "/cache", "h")` → dispatch で PURGE /cache がマッチ
- `test_hawk_all_single` — `hawk::all("/x", "h")` → 7エントリ（GET POST PUT DELETE PATCH HEAD OPTIONS）
- `test_hawk_all_multi_paths` — `ps[1]="/a"; ps[2]="/b"` → 7×2 = 14エントリ
- `test_hawk_compat_GET` — `GET("/x", "h")` が `hawk::get` 経由で同一結果

注意: 文字列を `on` に渡す場合は single method/path として扱われる。複数指定には配列を使う。

---

## 後方互換性

- 既存の `GET/POST/...` 呼び出しはすべて動作継続
- `listen(port)` も `http.awk` に残し `hawk::listen` がそれを呼ぶ
- 既存の `app.awk` を `hawk::` スタイルに更新するが、旧スタイルも動作する
