# H-awk 設計仕様書

- **プロジェクト名**: H-awk
- **ディレクトリ名**: `hawk/`
- **作成日**: 2026-06-06
- **対象バージョン**: v0.1 (MVP)
- **ステータス**: Draft (ブレスト承認済、実装計画作成前)

## 1. 概要

**スローガン:** awkでシンプルにバックエンドルーターを書こう！

H-awk は `gawk` 単体で動作する HTTP バックエンドルーターである。Express / Hono と同様の命令的なルート登録 API と、ハンドラ関数による req / res 処理を提供する。HTTP I/O には gawk 拡張の `/inet/tcp` を用い、外部ライブラリへの依存を最小化する。

将来的な拡張は「islands plugin」方式で吸収する。コアはルーティング・req / res・基本テンプレート・TSV ヘルパー・プラグインローダーのみに責務を絞り、PostgreSQL / S3 / CSRF / CORS / 構造化ログなどは個別プラグインとして提供する。

### 1.1 目的

- 実用ツールとして安定運用できること
- awk らしいシンプルな記述で Web アプリケーション・API サーバーを構築できること
- プラグイン拡張により段階的に機能を加えられること

### 1.2 非目標 (MVP)

- 高スループット (並行リクエスト処理は v0.3 以降)
- HTMX や部分テンプレート、テンプレート変数置換 (v0.2 以降)
- TLS 終端 (常に nginx 等の前段を想定)
- ファイルベースルーティング (v0.2 以降)

## 2. アーキテクチャ概観

```
┌─────────────────────────────────────┐
│  bin/hawk  (POSIX sh ラッパー)       │
│   - .env 読込 → export               │
│   - シグナル trap (SIGTERM → 正常終了)│
│   - supervisor: gawk が異常終了したら再起動 │
│   - exec gawk -f hawk.awk -f app.awk │
└──────────────┬──────────────────────┘
               │ exec gawk
               ▼
┌─────────────────────────────────────┐
│ gawk プロセス (single-thread loop)   │
│ ┌─────────────────────────────────┐ │
│ │ core/http.awk                   │ │
│ │   /inet/tcp/PORT/0/0 listen     │ │
│ │   raw HTTP req 読出 → dispatch  │ │
│ └────────────┬────────────────────┘ │
│              │                       │
│ ┌────────────▼────────────────────┐ │
│ │ core/request.awk                │ │
│ │   path/method/headers/body parse│ │
│ │   req[] 連想配列構築            │ │
│ └────────────┬────────────────────┘ │
│              │                       │
│ ┌────────────▼────────────────────┐ │
│ │ core/router.awk                 │ │
│ │   route table (ROUTES[]) lookup │ │
│ │   :param 抽出                   │ │
│ │   pre_request hook 起動         │ │
│ │   → handler 呼出                │ │
│ │   ← post_request hook 起動      │ │
│ └────────────┬────────────────────┘ │
│              │                       │
│ ┌────────────▼────────────────────┐ │
│ │ core/response.awk               │ │
│ │   res[] → HTTP wire format      │ │
│ │   socket 書出 → close           │ │
│ └─────────────────────────────────┘ │
│                                      │
│ サブシステム:                        │
│   core/static.awk  (public/ 配信)    │
│   core/tsv.awk     (TSV ヘルパー)    │
│   core/plugin.awk  (manifest scan)   │
│   core/template.awk(生HTML読込)      │
└─────────────────────────────────────┘
        ▲              ▲
        │              │
   plugins/      app.awk (ユーザー)
   (拡張)        GET/POST 登録 + handler
```

### 2.1 責務分離

- **bin/hawk** … `.env` 読込・シグナル管理・supervisor などシェルで完結する処理
- **core/** … HTTP I/O・ルーティング・req / res・テンプレート・静的配信・TSV・プラグインローダー
- **plugins/** … ミドルウェアと重い拡張 (DB 接続・オブジェクトストレージ・CSRF など)
- **app.awk** … ユーザーがルート登録とハンドラを記述する

## 3. ディレクトリ構成

```
hawk/
├── bin/
│   └── hawk                  # POSIX sh エントリポイント
├── core/
│   ├── http.awk              # /inet/tcp listener + req/res ループ
│   ├── request.awk           # HTTPパース → req[] 構築
│   ├── router.awk            # ROUTES[] + パス一致 + :params 抽出
│   ├── response.awk          # res[] → HTTP wire format
│   ├── template.awk          # render() — 生HTML読込
│   ├── static.awk            # public/ 配信 + mime判定
│   ├── tsv.awk               # append_tsv/read_tsv/find_tsv
│   ├── plugin.awk            # plugins/ スキャン + manifest 登録
│   ├── json.awk              # JSON encode/decode (MVP最小)
│   └── util.awk              # url_decode/escape_html/log 等
├── hawk.awk                  # @include 集約エントリ
├── plugins/                  # ユーザー追加プラグイン格納
│   └── README.md             # plugin 作成方法 (manifest 仕様)
├── public/                   # 静的配信ルート (JS/CSS/画像/favicon)
├── views/                    # 生 HTML テンプレート
│   └── fragments/            # 部分テンプレート (v0.2 用)
├── data/                     # TSV 保管
├── tests/
│   ├── unit/                 # awk 内 assert (core/*.awk テスト)
│   │   ├── run.awk           # ユニットランナー
│   │   └── test_*.awk
│   └── e2e/
│       ├── run.sh            # サーバー起動 + curl + 終了
│       └── *.sh
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-06-06-h-awk-design.md
├── Makefile                  # タスクランナー
├── .env.example              # 設定サンプル
├── app.awk                   # ユーザーコード
└── README.md
```

### 3.1 エントリ起動

```sh
./bin/hawk app.awk
```

`bin/hawk` (`.env` 読込 + supervisor):

```sh
#!/bin/sh
set -e
[ -f .env ] && set -a && . ./.env && set +a
APP="${1:-app.awk}"
# plugins/<name>/manifest.awk と plugins/<name>/<name>.awk を集約
PLUGIN_FILES=""
for d in plugins/*/; do
  [ -d "$d" ] || continue
  [ -f "${d}.disabled" ] && continue
  name=$(basename "$d")
  PLUGIN_FILES="$PLUGIN_FILES -f ${d}manifest.awk -f ${d}${name}.awk"
done

while true; do
  gawk -f hawk.awk $PLUGIN_FILES -f "$APP"
  status=$?
  [ "$status" = 0 ] && break
  echo "[hawk] gawk exited $status, restart in 1s" >&2
  sleep 1
done
```

`hawk.awk` (`@include` 集約):

```awk
@include "core/util.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/router.awk"
@include "core/plugin.awk"
@include "core/http.awk"
```

### 3.2 Makefile (タスクランナー)

```makefile
.PHONY: run dev test test-unit test-e2e lint fmt clean help

APP ?= app.awk
PORT ?= 8080

help:
	@awk -F':.*##' '/^[a-z_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## サーバー起動
	./bin/hawk $(APP)

dev: ## DEV=1 でログ詳細
	DEV=1 ./bin/hawk $(APP)

test: test-unit test-e2e ## 全テスト

test-unit: ## awk内 assert
	gawk -f hawk.awk -f tests/unit/run.awk

test-e2e: ## サーバー起動 + curl
	./tests/e2e/run.sh

lint: ## awk構文チェック
	@for f in core/*.awk hawk.awk; do gawk --lint --source 'BEGIN{}' -f $$f >/dev/null || exit 1; done
	@echo "lint OK"

clean: ## 一時ファイル削除
	rm -f data/*.tmp tests/e2e/*.log
```

## 4. ルーティング

### 4.1 ルート登録 API

```awk
BEGIN {
  GET   ("/",            "index")
  GET   ("/users/:id",   "show_user")
  POST  ("/todos",       "add_todo")
  PUT   ("/todos/:id",   "update_todo")
  DELETE("/todos/:id",   "delete_todo")
  PATCH ("/users/:id",   "patch_user")
}
```

`GET / POST / PUT / DELETE / PATCH` はすべて `core/router.awk` 内の関数で、共通テーブル `ROUTES[]` に登録する。

### 4.2 ROUTES[] 構造 (gawk 多次元連想配列)

```
ROUTES["GET", "/users/:id", "handler"]    = "show_user"
ROUTES["GET", "/users/:id", "pattern"]    = "^/users/([^/]+)$"
ROUTES["GET", "/users/:id", "params"]     = "id"      # カンマ区切り
ROUTES["GET", "/users/:id", "count"]      = 1
```

登録時に `:param` を `([^/]+)` に変換し、param 名のリストを保存する。走査時の順序を保証するため、登録順を保持する 1 次元配列 `ROUTES_ORDER[]` を別途用意する。

```
ROUTES_ORDER[1] = "GET\t/"
ROUTES_ORDER[2] = "GET\t/users/:id"
ROUTES_ORDER[3] = "POST\t/todos"
ROUTES_COUNT    = 3
```

### 4.3 マッチングアルゴリズム

```awk
for (idx = 1; idx <= ROUTES_COUNT; idx++) {
  key = ROUTES_ORDER[idx]
  split(key, k, "\t")
  if (k[1] != req["method"]) continue
  pattern = ROUTES[k[1], k[2], "pattern"]
  if (match(req["path"], pattern, arr)) {
    params = ROUTES[k[1], k[2], "params"]
    split(params, names, ",")
    for (i in names) req["params:" names[i]] = arr[i]
    handler = ROUTES[k[1], k[2], "handler"]
    @handler(req, res)
    return
  }
}
```

`@handler(req, res)` は gawk の **indirect function call** であり、文字列ハンドラ名から関数を呼び出す。これが「ハンドラ名を文字列で登録する」設計の根拠となる。

### 4.4 優先順位

登録順 (Express 互換)。静的パス `/users/me` を先に登録すれば `:id` より優先される。

### 4.5 マッチング規則 (MVP)

- `:name` — 1 セグメント、`[^/]+` 相当、空文字不可
- ワイルドカード `*` / `**` — v0.2 以降
- regex 直書き — v0.2 以降

### 4.6 404 / 405 の判定

1. ROUTES_ORDER を全走査してパス・メソッド共に一致を探す
2. 一致した場合はハンドラ呼出
3. 一致しなかった場合は GET / HEAD のみ静的ファイル配信を試行
4. それでもなければ 404
5. パス一致だがメソッド違いがあった場合は 405 を返し、`Allow:` ヘッダに対応メソッドを列挙

## 5. req / res オブジェクト

### 5.1 req[] 構造

フラットな連想配列に対し、プレフィックスで名前空間を切る。

```awk
# メタ
req["method"]              # "GET", "POST" 等
req["path"]                # "/users/42"
req["full_path"]           # "/users/42?page=1"
req["query_string"]        # "page=1&sort=name"
req["http_version"]        # "HTTP/1.1"
req["raw"]                 # 生リクエスト全文 (デバッグ用)

# ヘッダ (キー小文字化)
req["header:content-type"] = "application/json"
req["header:user-agent"]   = "curl/8.0"
req["header:cookie"]       = "session=abc123"

# パスパラメータ
req["params:id"]           = "42"

# クエリ
req["query:page"]          = "1"
req["query:sort"]          = "name"

# form (application/x-www-form-urlencoded)
req["form:title"]          = "buy milk"
req["form:tags[]", 1]      = "shop"
req["form:tags[]", 2]      = "urgent"

# JSON (application/json)
req["body"]                = "<生JSON文字列>"
req["json:user.name"]      = "alice"
req["json:user.age"]       = "30"
req["json:items[]", 1]     = "..."

# プラグインによる注入 (例: 認証プラグイン)
req["user.id"]             = "42"
req["request_id"]          = "..."
```

### 5.2 res[] 構造

```awk
res["status"]              = 200
res["header:content-type"] = "text/html; charset=utf-8"
res["header:set-cookie"]   = "session=xyz; Path=/; HttpOnly"
res["body"]                = "<html>..."
res["sent"]                = 0    # 1 = 送信済み (二重送信防止)
```

### 5.3 res 操作 API

```awk
status(res, 404)
header(res, "X-Foo", "bar")
header_append(res, "Set-Cookie", "...")
redirect(res, "/login")            # 302 + Location
redirect(res, "/login", 301)       # 任意 status
json(res, data)                    # data[] → JSON、Content-Type 自動
text(res, "hello")                 # text/plain
html(res, "<p>hi</p>")             # text/html
render(res, "views/index.html")    # 生 HTML ファイル → body
send(res)                          # 即時送信 (通常はハンドラ戻りで自動)
```

### 5.4 ハンドラ shape

```awk
function show_user(req, res,    id, user) {
  id = req["params:id"]
  if (!find_tsv("data/users.tsv", "id", id, user)) {
    status(res, 404)
    text(res, "not found")
    return
  }
  json(res, user)
}
```

awk の慣習として、関数引数の4列目以降はローカル変数扱いとする。エディタで視認しやすいよう空白で区切る。

### 5.5 TSV ヘルパー API (MVP コア)

軽量データ永続化用の組込みヘルパー。1 行目をヘッダ (列名 TSV) とし、2 行目以降をレコードとして扱う。

```awk
# 追記。row[] は連想配列 (列名 → 値)。ヘッダがなければ row のキーから生成
# 戻り値: 1=成功、0=失敗
append_tsv(path, row)

# 全件読込。out[] に out[i, "<列名>"] = 値 の形で格納
# 戻り値: 件数
read_tsv(path, out)

# 単一検索。key=列名、val=完全一致値。最初に一致した行を row[] に格納
# 戻り値: 1=見つかった、0=見つからない
find_tsv(path, key, val, row)

# 削除。key=val の行を削除し、ファイルを書き直す
# 戻り値: 削除件数
delete_tsv(path, key, val)

# 更新。key=val の行に対し、update[] の列を上書き
# 戻り値: 更新件数
update_tsv(path, key, val, update)
```

エスケープ規約: 値内のタブは `\\t`、改行は `\\n`、バックスラッシュは `\\\\` にエスケープしてから書き込む。読込時に逆変換する。空のファイルは「ヘッダなし・0 件」として扱い、初回 `append_tsv` で row のキーをヘッダとして書く。

並行性なし (MVP は single-thread) のため、ファイルロックは行わない。v0.3 で並行化する際にロック方式を別途設計する。

### 5.6 JSON encode の制約 (MVP)

- `data["foo"] = "bar"` → `{"foo":"bar"}` (フラット object)
- 型ヒント: `data["foo:int"] = 30` → `{"foo":30}`。サフィックスは `:int` `:bool` `:null` を MVP でサポート
- 多次元キー (`data["users", 1, "name"]`) のネスト復元は **v0.2 以降**。MVP では SUBSEP 連結のフラットキーとして出力される
- 複雑構造 (リスト・ネスト) は手動で文字列を組み立てる運用 (`sprintf`, `json_encode` 連結) を許容する

## 6. プラグインシステム

### 6.1 ディレクトリ構造

```
plugins/
├── s3-storage/
│   ├── manifest.awk
│   └── s3.awk
├── postgres/
│   ├── manifest.awk
│   └── pg.awk
├── csrf/
│   ├── manifest.awk
│   └── csrf.awk
└── logger/
    ├── manifest.awk
    └── logger.awk
```

### 6.2 manifest.awk 仕様

```awk
function plugin_csrf_manifest(meta) {
  meta["name"]        = "csrf"
  meta["version"]     = "0.1.0"
  meta["description"] = "CSRF token validation"
  meta["hooks"]       = "pre_request,post_request"
  meta["api"]         = "csrf_token,csrf_validate"
  meta["config_keys"] = "CSRF_SECRET"       # 必要な .env キー
}
```

実装ファイルは `plugins/<name>/<name>.awk` 固定で 1 ファイルとする。manifest と実装ファイルの両方を `bin/hawk` が起動時に glob で `-f` 引数に展開する (`hawk.awk` の `@include` ではなく、コマンドライン側で集約)。複数ファイルに分割したい場合は v0.2 以降で manifest の `files` フィールドを再導入する。

### 6.3 コア側ローダー (`core/plugin.awk`)

```awk
function load_plugins(   pname, cmd, func_name, meta, n, m, j, keys, hooks, hook_name) {
  cmd = "ls plugins 2>/dev/null"
  while ((cmd | getline pname) > 0) {
    func_name = "plugin_" pname "_manifest"
    delete meta
    @func_name(meta)

    PLUGINS[pname, "version"]     = meta["version"]
    PLUGINS[pname, "hooks"]       = meta["hooks"]
    PLUGINS[pname, "api"]         = meta["api"]
    PLUGINS[pname, "config_keys"] = meta["config_keys"]

    # 必須 .env キーが揃っていることを検証
    n = split(meta["config_keys"], keys, ",")
    for (j = 1; j <= n; j++) {
      if (!(keys[j] in ENVIRON)) {
        printf "[hawk] plugin %s missing env: %s\n", pname, keys[j] > "/dev/stderr"
        exit 1
      }
    }

    # hook 登録
    m = split(meta["hooks"], hooks, ",")
    for (j = 1; j <= m; j++) {
      hook_name = hooks[j]
      HOOKS[hook_name, ++HOOKS_COUNT[hook_name]] = "plugin_" pname "_" hook_name
    }
  }
  close(cmd)
}
```

### 6.4 プラグイン実装規約

関数命名規約:

- フック関数: `plugin_<name>_<hook名>`
- 公開 API 関数: `<name>_<関数名>` (例: `csrf_token`)

```awk
function plugin_csrf_pre_request(req, res,    token, expected) {
  if (req["method"] == "GET") return 0
  token = req["form:_csrf"]
  expected = csrf_token(req["header:cookie"])
  if (token != expected) {
    status(res, 403)
    text(res, "CSRF token mismatch")
    return 1    # 1 = abort chain
  }
  return 0
}

function csrf_token(cookie,    sid) {
  sid = extract_cookie(cookie, "session")
  return sha256(sid ENVIRON["CSRF_SECRET"])
}
```

### 6.5 フック種別 (MVP)

| フック | タイミング | 用途例 |
|--------|------------|--------|
| `init` | サーバー起動時 1 回 | DB 接続プール初期化 |
| `pre_request` | ハンドラ呼出前 | 認証、CSRF、リクエストログ |
| `post_request` | ハンドラ呼出後 | CORS ヘッダ追加、レスポンスログ |
| `shutdown` | SIGTERM 受信時 | DB 接続クローズ等のクリーンアップ |

### 6.6 起動順

```
1. plugin pre_request hooks (登録順)
   - 戻り値 1 で abort し、即送信
2. ROUTES マッチ → handler 呼出
3. plugin post_request hooks (登録順)
   - レスポンス改変可
4. response 送信
```

### 6.7 有効化 / 無効化

- `plugins/<name>/` を置けば自動ロード
- 無効化はディレクトリ削除、または `.disabled` ファイルを直下に置く

### 6.8 `.env` 例

```
HAWK_PORT=8080
CSRF_SECRET=change-me-in-production
S3_ENDPOINT=https://s3.example.com
S3_BUCKET=hawk-assets
PG_DSN=host=db user=app dbname=hawk
```

## 7. データフロー (1リクエスト)

```
[クライアント] curl -X POST /todos -d "title=buy"
       │
       ▼
[bin/hawk] (shell)
   .env load → export → exec gawk
       │
       ▼
[core/http.awk]  (起動時 1回)
   load_plugins()                         # plugins/ scan
   call_hooks("init")                     # plugin init 実行
   /inet/tcp/8080/0/0 を双方向 stream open
       │
       ▼ ─────────────────── (ループ開始) ──────────────────
       │
       │ getline で生 request 読込
       │
       ▼
[core/request.awk]
   delete req
   parse_request_line(raw, req)
   parse_headers(raw, req)
   parse_query(req)
   parse_body(raw, req)
       │
       ▼
[core/response.awk]
   delete res
   res["status"] = 200
   res["sent"]   = 0
       │
       ▼
[core/router.awk] dispatch(req, res)
   ┌────────────────────────────────────┐
   │ 1. call_hooks("pre_request",req,res)│
   │    abort=1 → goto SEND              │
   ├────────────────────────────────────┤
   │ 2. ROUTES マッチ → handler 呼出     │
   ├────────────────────────────────────┤
   │ 3. マッチなし + GET/HEAD            │
   │    → serve_static(req, res)         │
   ├────────────────────────────────────┤
   │ 4. それもなし → 404                 │
   ├────────────────────────────────────┤
   │ 5. call_hooks("post_request",req,res)│
   └────────────────────────────────────┘
       │
       ▼ SEND:
[core/response.awk] send(res, socket)
   HTTP/1.1 wire format に整形 → socket 書出 → close
       │
       ▼ ─────────────────── (ループ末尾) ──────────────────
       │
       ▼
[SIGTERM 受信]
   call_hooks("shutdown")
   close listener
   exit 0
```

### 7.1 主要ポイント

- **Connection: close 固定** (MVP)。keep-alive はリクエスト境界判定が複雑なため v0.4 以降
- **Body 読込**: `Content-Length` ヘッダ値分を raw stream から読出。`Transfer-Encoding: chunked` は v0.4 以降
- **シグナル**: MVP では `bin/hawk` シェルが SIGTERM / SIGINT を trap し、gawk プロセスにそのまま中継する。gawk 側は read loop の先頭でフラグを確認して終了処理に入る。gawk extension の `signal` 機能 (gawkextlib) には MVP では依存しない
- **エラー伝播**: ハンドラ内で `status(res, 500)` 等をセットして return すれば、post_request → SEND まで通常フローで進む。awk には例外機構がないため、明示的な status set + early return がエラー伝播の唯一手段となる

## 8. エラーハンドリング

### 8.1 カテゴリ別

| 種別 | 検出位置 | 対応 |
|------|----------|------|
| パース失敗 (不正 HTTP) | `request.awk` | `status 400` + body "Bad Request" → 次のリクエストへ |
| ルートマッチなし | `router.awk` | 静的ファイル試行 → なければ `status 404` |
| Method 違い | `router.awk` | `status 405` + `Allow: GET, POST` |
| 不正 body (form / JSON parse 失敗) | `request.awk` | `status 400` + 詳細 (DEV=1 時) / 汎用 (本番) |
| Plugin pre_request abort | hook return 1 | hook が res 設定済 → 即送信 |
| Handler 内の明示エラー | user code | `status(res, 500)` → そのまま送信 |
| Handler 未捕捉エラー | gawk runtime error | gawk プロセス終了 → `bin/hawk` が supervisor として再起動 |
| Static file 読込失敗 | `static.awk` | 404 (ENOENT) / 403 (EACCES) / 500 (それ以外) |
| Plugin init 失敗 | manifest config_keys 不足 | 起動時 stderr 出力 + exit 1 (fail fast) |

### 8.2 エラーレスポンス形式

- 簡易 content negotiation: `Accept: application/json` を含む場合は JSON `{"error":"...","status":404}` を返す
- それ以外は text/plain (`"404 Not Found"`)
- `DEV=1` 時のみ gawk の行番号や関数名を含むスタックトレース風の出力を body に含める。本番では隠す

### 8.3 ログ

- 標準: stdout に 1 リクエスト 1 行の TSV (`timestamp\tlevel\tmethod\tpath\tstatus\tduration_ms`)
- `DEV=1` 時はより詳細 (header dump、body 先頭 N bytes)
- 構造化ログ (JSON line 等) は `logger-json` プラグインで提供

### 8.4 入力サイズ制限 (DoS 緩和)

`.env` で設定可能、デフォルト値は以下:

```
HAWK_MAX_HEADER_SIZE=8192       # ヘッダ合計 (バイト)
HAWK_MAX_BODY_SIZE=1048576      # body 1MB
HAWK_REQUEST_TIMEOUT=30         # 秒 (socket read timeout)
```

超過時のレスポンス:

- header 超過 → `431 Request Header Fields Too Large`
- body 超過 → `413 Payload Too Large`

## 9. テスト戦略

### 9.1 ユニットテスト (`tests/unit/`)

awk 内の assert ヘルパーとランナーで構成する。core/*.awk の純粋関数 (副作用なし) を対象とする。

```awk
# tests/unit/run.awk
BEGIN {
  TESTS_PASSED = 0; TESTS_FAILED = 0
  test_request_parse()
  test_router_match()
  test_json_encode()
  test_tsv_append()
  test_url_decode()
  printf "%d passed, %d failed\n", TESTS_PASSED, TESTS_FAILED
  exit (TESTS_FAILED > 0)
}

function assert_eq(actual, expected, msg) {
  if (actual == expected) { TESTS_PASSED++; return }
  TESTS_FAILED++
  printf "FAIL: %s\n  expected: %s\n  actual:   %s\n", msg, expected, actual > "/dev/stderr"
}
```

実行: `make test-unit`

カバレッジ目標 (MVP 完了時):

- request.awk: request-line / header / body / url-decode 各 1 ケース以上
- router.awk: 静的パス / `:param` / method 違い / 404
- response.awk: status / header / json / redirect
- tsv.awk: append / read / find (空ファイル、単行、複数行、タブを含む値)
- json.awk: フラット / 型サフィックス / ネスト

### 9.2 E2E テスト (`tests/e2e/`)

実サーバーを起動し、curl でリクエストを送り、結果をアサートしてプロセスを終了する。

```sh
# tests/e2e/run.sh
#!/bin/sh
set -e
PORT=18080
export HAWK_PORT=$PORT
./bin/hawk tests/e2e/fixtures/app.awk &
PID=$!
trap "kill $PID 2>/dev/null || true" EXIT

# 起動待ち
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.3
done

PASS=0; FAIL=0
check() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $desc (want $expected, got $actual)" >&2
  fi
}

status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
check "GET / returns 200" 200 "$status"

# ... 他のチェック ...

echo "$PASS passed, $FAIL failed"
exit $FAIL
```

fixtures 構成:

```
tests/e2e/fixtures/
├── app.awk              # 最小ルート定義
├── public/test.css      # 静的配信検証用
└── views/test.html      # render() 検証用
```

### 9.3 CI / 動作確認

- Makefile に `make ci = lint + test-unit + test-e2e` を用意
- GitHub Actions は v0.3 以降
- gawk バージョン: 5.0 以上 (`@include`、indirect call、`length()` 引数、`/inet/tcp` を網羅するため)
- 動作確認 OS: Linux、macOS (Darwin)。Windows は WSL 経由のみサポート

### 9.4 プラグインテスト

各 plugin ディレクトリ配下に任意で `tests/` を置ける:

```
plugins/csrf/
├── manifest.awk
├── csrf.awk
└── tests/
    └── test_csrf.awk
```

ルートの `tests/unit/run.awk` が `plugins/*/tests/*.awk` を glob で自動 include する。プラグインオーナーが個別にテストを書く。

## 10. MVP スコープと非スコープ

### 10.1 MVP (v0.1) に含むもの

- `bin/hawk` シェルラッパー + supervisor 再起動ループ
- `core/http.awk` /inet/tcp listen + 同期ループ
- `core/request.awk` HTTP/1.1 parse (request-line + headers + Content-Length body)
- form-urlencoded / JSON / query string パース (multipart は除外)
- `core/router.awk` GET / POST / PUT / DELETE / PATCH 登録、`:param` 動的ルート、linear scan、`@handler` indirect call
- `core/response.awk` `status / header / header_append / redirect / json / text / html / render / send`
- `core/template.awk` 生 HTML 読込のみ
- `core/static.awk` `public/` 配信 + 基本 mime (html / css / js / png / jpg / svg / ico / txt / json)
- `core/tsv.awk` `append_tsv / read_tsv / find_tsv`
- `core/json.awk` フラット object + 型サフィックス + 多次元ネスト復元
- `core/plugin.awk` `plugins/<name>/manifest.awk` scan + hook 登録
- フック: `init / pre_request / post_request / shutdown`
- `.env` 環境変数 (bin/hawk 内で source)
- 入力サイズ制限 (header / body / timeout)
- エラー: 400 / 404 / 405 / 413 / 431 / 500
- ログ: stdout に 1 リクエスト 1 行の TSV
- ユニットテスト + E2E テスト
- Makefile: `run / dev / test / test-unit / test-e2e / lint / clean / help`
- `gawk --lint` 構文チェック
- ドキュメント: README + プラグイン作成ガイド

### 10.2 MVP に含まないもの (v0.2 以降)

- ファイルベースルーティング (Next.js 型、`routes/` 自動マウント)
- HTMX サポート (部分テンプレート、fragment 連結)
- テンプレート変数置換、ループ、分岐、partial
- multipart/form-data (ファイルアップロード)
- 並行リクエスト (inetd 型、fork、nginx リバースプロキシ)
- keep-alive、chunked transfer
- TLS (常に nginx 前段を想定)
- 公式プラグイン: postgres / s3 / csrf / cors / logger-json / session / cache
- TSV のプラグイン分離
- ワイルドカードルート `*`、regex 直書きルート
- ホットリロード
- GitHub Actions CI
- Cookie ヘルパー API

## 11. ロードマップ

| バージョン | テーマ | 主な内容 |
|------------|--------|----------|
| **v0.1** | コア骨格 | 本仕様書の MVP スコープ |
| **v0.2** | 公式プラグイン + Next.js 型 routing | postgres / s3 / csrf / cors / logger プラグイン、`routes/` 自動マウント、HTMX 部分テンプレート、テンプレート変数置換、ワイルドカードルート |
| **v0.3** | 並行性 + 運用 | inetd 型 (fork-per-conn)、ホットリロード、GitHub Actions CI、メトリクスプラグイン、structured logging |
| **v0.4** | プロトコル拡張 | multipart、keep-alive、chunked、cookie ヘルパー、session プラグイン |
| **v1.0** | 安定 + ドキュメント | API freeze、ベンチマーク、サンプルアプリ集 (todo / ブログ / 管理画面)、本番運用ガイド |

## 12. 受入基準 (v0.1 完了条件)

- `make test` が全 pass する (unit + E2E)
- サンプル todo アプリ (GET 一覧 + POST 追加 + DELETE) が動作する
- `gawk --lint` 警告がゼロ
- README に Quickstart、プラグイン作成例、動作確認済み OS / gawk バージョンが記載されている
- 入力サイズ制限の境界値 (1B 超過) で 413 / 431 が返ることが E2E で確認できる

## 13. 用語集

- **gawk** … GNU awk 実装。`/inet/tcp`、`@include`、indirect call、多次元配列など POSIX awk 拡張機能を含む
- **`/inet/tcp/PORT/0/0`** … gawk の TCP listener 仕様。双方向 stream として open し `print x |& stream` で書出、`getline x < stream` で読込する
- **indirect function call** … gawk で `@func_name(args...)` と書くと文字列 `func_name` の関数を呼び出せる機能。本仕様ではルーティングとプラグインフックの中核として使用する
- **islands plugin** … コア機能を最小に絞り、機能拡張をすべて疎結合なプラグインとして提供するアーキテクチャ方針の呼称
