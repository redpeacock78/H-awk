# H-awk

> **awkでシンプルにバックエンドルーターを書こう！**

`gawk` 単体で動作する、Express 型 API を備えた HTTP バックエンドルーター。

## 動作要件

- gawk 5.0 以上 (`gawk --version` で確認)
- POSIX sh 互換のシェル
- GNU make
- (E2E テスト時のみ) curl

検証済み環境: gawk 5.3.1 / macOS Darwin 21。Linux は API 互換のため動作見込み。Windows は WSL 経由のみ。

## Quickstart

```sh
# .env を雛形からコピー
cp .env.example .env

# サーバー起動 (デフォルト :8080)
./bin/hawk app.awk

# 別ターミナルから
curl http://127.0.0.1:8080/
curl -X POST -d 'title=buy+milk' http://127.0.0.1:8080/todos
curl http://127.0.0.1:8080/todos.json
```

`make help` で利用可能なターゲットを表示。

## ルート定義 (app.awk)

```awk
BEGIN {
  GET   ("/",            "index")
  GET   ("/users/:id",   "show_user")
  POST  ("/todos",       "add_todo")
}

function index(req, res) {
  render(res, "views/index.html")
}

function show_user(req, res) {
  text(res, "user=" req["params:id"])
}

function add_todo(req, res,    row) {
  delete row
  row["id"]    = systime()
  row["title"] = req["form:title"]
  append_tsv("data/todos.tsv", row)
  status(res, 201)
  text(res, "ok")
}
```

詳細仕様: [docs/superpowers/specs/2026-06-06-h-awk-design.md](docs/superpowers/specs/2026-06-06-h-awk-design.md)

## プラグインの作り方

`plugins/<name>/manifest.awk` と `plugins/<name>/<name>.awk` を作る。

```awk
# plugins/logger/manifest.awk
function plugin_logger_manifest(meta) {
  meta["name"]        = "logger"
  meta["version"]     = "0.1.0"
  meta["description"] = "Per-request stdout logger"
  meta["hooks"]       = "post_request"
  meta["api"]         = ""
  meta["config_keys"] = ""
}
```

```awk
# plugins/logger/logger.awk
function plugin_logger_post_request(req, res) {
  log_info(sprintf("→ %s %s %d", req["method"], req["path"], res["status"]))
  return 0
}
```

`plugins/logger/` に置けば起動時に自動ロードされる。無効化したい場合は `plugins/logger/.disabled` を作る。

## テスト

```sh
make test          # ユニット + E2E
make test-unit     # awk 内 assert のみ
make test-e2e      # サーバー起動 + curl
make lint          # gawk --lint の構文チェック
make ci            # lint + 全テスト
```

## バイナリ配信と native 拡張 (libs)

H-awk は標準で **PNG / JPG / アイコン等のバイナリファイル配信** に対応するが、これは内部的に `libs/binary/` (Zig 製 gawk extension) を使う。**ユーザーは Zig の存在を意識する必要はない**。`make build-libs` で一度ビルドすれば、以降は通常通り `./bin/hawk app.awk` で起動するだけでバイナリ配信が透過的に有効になる。

### libs のセットアップ (3 通り)

#### 方法 A: Zig からビルド (推奨)

```sh
make build-libs    # libs/*/zig-out/lib/libhawk_*.{so,dylib}
```

要件: Zig 0.15+ (`zig version` で確認)

#### 方法 B: precompiled をダウンロード (Zig 不要)

```sh
HAWK_REPO=<owner>/<repo> make fetch-libs
```

GitHub Release から OS / アーキ対応の .so / .dylib を取得して `libs/<name>/zig-out/lib/` に展開する。

#### 方法 C: libs を使わない

何もしない。サーバーは起動するが、PNG / JPG 等のバイナリ配信時に内容が壊れる (text mode 読込で `\n` が混入する)。CSS / JS / HTML / JSON / プレーンテキストは libs 不要で正常配信される。

### 状態確認

起動時のログに有効な libs が表示される:

```
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: binary]
```

### 提供 libs (v0.2 時点)

- **`libs/binary`** — バイナリ-safe file I/O。PNG/JPG/ICO/WebP/font 等の正確な読込・送信に必須

### 今後追加予定 (ロードマップ)

- v0.3: `libs/multipart` (ファイルアップロード) / `libs/crypto` (sha256/hmac)
- v0.4: `libs/gzip` / `libs/url` (高速 url_decode)

## プラグイン (plugins/) — git submodule で管理

H-awk のプラグインは **island plugin** 方式: 各プラグインは独立した git リポジトリで配布され、本リポジトリでは `git submodule` として取り込む。core は `plugins/<name>/manifest.awk` の存在のみで discover するため、submodule 未初期化 (= ディレクトリ空) の場合は自動的に無効化される。

### プラグインの追加

```sh
git submodule add https://github.com/<owner>/hawk-plugin-csrf plugins/csrf
git submodule update --init plugins/csrf
```

`plugins/csrf/manifest.awk` + `plugins/csrf/csrf.awk` が配置され、次の起動から自動有効化される。

### プラグインの一時無効化

```sh
touch plugins/csrf/.disabled
```

`.disabled` マーカーがあれば bin/hawk は当該 plugin を gawk -f 集約から外す。

### プラグインの完全削除

```sh
git submodule deinit plugins/csrf
git rm plugins/csrf
```

### 公式 plugin 命名規約

- リポジトリ名: `hawk-plugin-<name>`
- マウント先: `plugins/<name>/`
- 関数命名: `plugin_<name>_<hook>` (フック) / `<name>_<api>` (公開 API)

### 提供予定 (公式 plugin、ロードマップ)

- v0.3: `hawk-plugin-csrf` / `hawk-plugin-postgres` / `hawk-plugin-s3`
- v0.4: `hawk-plugin-session` / `hawk-plugin-cors` / `hawk-plugin-logger-json`

## ライセンス

(プロジェクトのライセンスに合わせて記載)
