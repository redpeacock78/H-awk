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

## ライセンス

(プロジェクトのライセンスに合わせて記載)
