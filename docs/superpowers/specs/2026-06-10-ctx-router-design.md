# H-awk v0.4 ctx 名前空間 + ルーター分割設計仕様書

- **プロジェクト名**: H-awk
- **サブシステム**: `core/ctx.awk`, `core/router.awk` (軽微変更), `core/http.awk` (`listen()` 追加)
- **作成日**: 2026-06-10
- **対象バージョン**: H-awk v0.4
- **ステータス**: 承認済み

---

## 1. 概要

`app.awk` が肥大化したとき、ルートハンドラを `routers/*.awk` に名前空間単位で分割できるようにする。

あわせて `ctx::` 名前空間を導入し、ハンドラ関数の引数から `req`/`res` を省略できる Hono の Context に近い API を提供する。

**後方互換を完全に維持する。** 既存の `app.awk` スタイルは変更なしで動き続ける。

---

## 2. ゴール / 非ゴール

### ゴール
- `@namespace "todos_router"` で定義したハンドラを `GET("/todos", "todos_router::index")` で登録できる
- `ctx::req["query:limit"]` / `ctx::query("limit")` の両形式でリクエストデータにアクセスできる
- `ctx::json(data)` / `ctx::text(data)` 等でレスポンスを組み立てられる
- `listen(port)` を `BEGIN` で明示的に呼べる
- 旧スタイル (`function handler(req, res)` + END 自動起動) がそのまま動く

### 非ゴール
- ミドルウェアチェーン / ルーターグループ / パスプレフィックス (将来機能)
- ctx:: による並行リクエスト処理 (gawk はシングルスレッド、問題なし)
- `routers/` ディレクトリの自動スキャン / 自動ロード

---

## 3. アーキテクチャ

### 3.1 ファイル構成変更

```
hawk.awk                    ← @include "core/ctx.awk" を追加
core/ctx.awk                ← 新規
core/router.awk             ← router_dispatch に copy-in/copy-out を追加
core/http.awk               ← listen(port) 関数追加 + END にフラグ判定追加
```

ユーザー側は変更不要。分割したい場合のみ `routers/*.awk` を追加する。

### 3.2 include 順序 (hawk.awk)

```
core/util.awk
core/libs.awk
core/json.awk
core/tsv.awk
core/template.awk
core/static.awk
core/request.awk
core/response.awk
core/router.awk
core/ctx.awk      ← router の後に追加 (response.awk の関数に依存するため)
core/plugin.awk
core/http.awk
```

---

## 4. core/ctx.awk 仕様

### 4.1 グローバル配列

```awk
@namespace "ctx"
# req[], res[] はこの名前空間のグローバル配列
# router_dispatch によってリクエスト毎にコピーされる
```

`ctx::req[]` のキー体系は `core/request.awk` の `req[]` と同一:

- `ctx::req["method"]`, `ctx::req["path"]`
- `ctx::req["query:KEY"]` — クエリパラメータ
- `ctx::req["params:KEY"]` — パスパラメータ (`:id` 等)
- `ctx::req["header:KEY"]` — リクエストヘッダ (小文字正規化済み)
- `ctx::req["form:KEY"]` — フォームフィールド
- `ctx::req["json:KEY"]` — JSON ボディフィールド
- `ctx::req["body"]` — 生ボディ

### 4.2 リクエスト読取ヘルパー

```awk
function query(key)      { return ctx::req["query:" key] }
function param(key)      { return ctx::req["params:" key] }
function get_header(key) { return ctx::req["header:" awk::to_lower(key)] }
function body()          { return ctx::req["body"] }
```

### 4.3 レスポンス書込ヘルパー

すべて既存 `core/response.awk` の関数を `ctx::res` に対して呼ぶラッパー:

```awk
function json(data)       { awk::json(ctx::res, data) }
function text(data)       { awk::text(ctx::res, data) }
function html(data)       { awk::html(ctx::res, data) }
function render(tpl, d)   { awk::render(ctx::res, tpl, d) }
function redirect(url, c) { awk::redirect(ctx::res, url, c) }
function status(code)     { awk::status(ctx::res, code) }
function set_header(n, v) { awk::header(ctx::res, n, v) }
```

---

## 5. router_dispatch の変更

`core/router.awk` の `router_dispatch` 内でハンドラを呼ぶ箇所に copy-in/copy-out を追加する。

### 変更前
```awk
@handler(req, res)
return 1
```

### 変更後
```awk
_ctx_load(req, res)
@handler(req, res)
_ctx_save(res)
return 1
```

### ヘルパー関数

```awk
function _ctx_load(req, res,    k) {
  delete ctx::req
  for (k in req) ctx::req[k] = req[k]
  delete ctx::res
  for (k in res) ctx::res[k] = res[k]
}

function _ctx_save(res,    k) {
  for (k in ctx::res) res[k] = ctx::res[k]
}
```

### 互換性

- **旧スタイルハンドラ** `function handler(req, res)`: `req`/`res` 引数をそのまま使う。`ctx::res` にも同期されるが干渉しない。
- **新スタイルハンドラ** `function handler(    local)`: `req`/`res` 引数を無視し `ctx::` を使う。gawk は余分な引数を無視するため呼出エラーにならない。
- **混在**: 旧スタイルハンドラが `res` を変更 → `_ctx_save` で `ctx::res` が上書きされるが、その後は読まれないため問題なし。

---

## 6. listen() 関数

`core/http.awk` に `listen(port)` 関数を追加する。

```awk
function listen(port) {
  if (port > 0) HAWK_PORT = port
  _hawk_serve()       # plugin_discover, call_hooks, http_serve のロジック
  _HAWK_LISTEN_CALLED = 1
}
```

`END` ブロックは `_HAWK_LISTEN_CALLED` フラグを見て重複起動を防ぐ:

```awk
END {
  if (!_HAWK_LISTEN_CALLED && !("HAWK_NO_SERVE" in ENVIRON)) {
    _hawk_serve()
  }
}
```

`_hawk_serve()` は現在の END ロジック (`plugin_discover` → `call_hooks("init")` → `http_serve` → `call_hooks("shutdown")`) をそのまま関数化したもの。

### ポート優先順位

`listen(port)` の引数 → `PORT` 環境変数 → デフォルト 8080 (既存と同じ)。`listen(0)` または引数省略時は環境変数/デフォルトにフォールバック。

---

## 7. ユーザー側の記述パターン

### 7.1 既存スタイル (変更なし、そのまま動く)

```awk
# app.awk
BEGIN {
  GET("/", "index")
  GET("/todos.json", "todo_list_json")
}

function index(req, res) { html(res, "<h1>Hello</h1>") }
function todo_list_json(req, res) { json(res, "[]") }
```

### 7.2 新スタイル: app.awk のみ (ctx:: 使用)

```awk
# app.awk
BEGIN {
  GET("/todos", "index")
  listen(8080)
}

function index(    limit) {
  limit = ctx::query("limit") + 0
  ctx::json("[]")
}
```

### 7.3 新スタイル: routers/ に分割

```awk
# routers/todos.awk
@namespace "todos_router"

function routes() {
  awk::GET("/todos",     "todos_router::index")
  awk::GET("/todos/:id", "todos_router::show")
}

function index(    limit) {
  limit = ctx::query("limit") + 0
  ctx::json(todos_all(limit))
}

function show(    id) {
  id = ctx::param("id")
  ctx::json(todos_find(id))
}
```

```awk
# app.awk
@include "routers/todos.awk"
@include "routers/users.awk"

function app_routes() {
  todos_router::routes()
  users_router::routes()
}

BEGIN {
  app_routes()
  listen(8080)
}
```

---

## 8. テスト方針

- `tests/unit/test_ctx.awk` を新設
  - `ctx::req` / `ctx::res` のコピー正確性を確認
  - `ctx::query` / `ctx::param` / `ctx::get_header` が正しいキーを読むことを確認
  - `ctx::json` / `ctx::text` / `ctx::status` が `ctx::res` を正しく設定することを確認
- `tests/unit/run.awk` にテスト関数呼出を追加
- `listen()` の直接テストは不要 (既存の http.awk テストがカバー)
- 既存テスト 122 件がすべて通ることを確認 (後方互換の担保)

---

## 9. 非機能要件

- リクエスト毎の `ctx::req`/`ctx::res` コピーは O(n)、n ≈ 30–50 キー。パフォーマンス影響は無視可。
- gawk 5.0 以上 (`@namespace` サポート) が必要。既存要件と同じ。
- `core/ctx.awk` は `core/response.awk` の `json`/`text`/`html`/`redirect`/`status`/`header`/`render` に依存する。include 順を守ること。
