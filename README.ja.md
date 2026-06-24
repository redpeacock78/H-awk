<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./docs/assets/h-awk-logo-faithful-dark-crop.png">
  <source media="(prefers-color-scheme: light)" srcset="./docs/assets/h-awk-logo-faithful-light-crop.png">
  <img alt="H-awk" src="./docs/assets/h-awk-logo-faithful-light-crop.png" width="420">
</picture>

[![CI](https://github.com/redpeacock78/H-awk/actions/workflows/ci.yml/badge.svg)](https://github.com/redpeacock78/H-awk/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/redpeacock78/H-awk)

AWK だけでバックエンドを書く。Node も Python もコンパイル済みバイナリも不要。

</div>

---

## 特徴

- **Express ライクなルーティング** — `hawk.app.get`、`.post`、`.del` など
- **型安全 DSL** — `let`、`when...of`、`??`、`|>`、コンパイル時型アノテーション
- **型付きコレクション** — `List<T>`、`Dict<K, V>`、`Record`（JSON 対応）
- **URL ヘルパー** — `libs/url` による Zig 製 URL エンコード/デコード（AWK fallback あり）
- **JSON ヘルパー** — `libs/json` による Zig 製 JSON エンコード/デコード、型付き `ctx.res.json(List<Todo>)`
- **gzip 圧縮** — `libs/gzip` による HTTP レスポンス圧縮、`HAWK_GZIP=1` で有効化
- **XSS 安全がデフォルト** — ブランド型により安全でない HTML はデシュガー時エラーになる
- **マルチワーカー** — `SO_REUSEPORT` + HTTP/1.1 keep-alive（オプションの Zig 拡張）

## クイックスタート

**動作要件:** gawk 5.0+、bash 4.3+、GNU make

```sh
cp .env.example .env
./bin/hawk app.awk        # :8080 で起動（マルチワーカーは libs/net が必要）
```

```sh
curl http://localhost:8080/
curl -X POST -d 'title=buy+milk' http://localhost:8080/todos
curl -X DELETE http://localhost:8080/todos/1234
```

```awk
BEGIN {
  hawk.app.get("/todos", "list_todos")
  hawk.app.post("/todos", "add_todo")
  hawk.app.listen(8080)
}

function list_todos() {
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let payload = []
  payload["count"] = n
  return ctx.res.json(payload)
}

function add_todo() {
  when ctx.req.form("title") of
    ok raw:
      ctx.res.status(201)
      return ctx.res.html(safe.html.fragment(
        "<li>", safe.html.escape(raw), "</li>"
      ))
    ng:
      ctx.res.status(400)
      return ctx.res.text("title required")
  end
}
```

## ドキュメント

| | |
|---|---|
| [セットアップ](docs/ja/setup.ja.md) | 動作要件、ビルド、バイナリ取得 |
| [CLI リファレンス](docs/ja/cli.ja.md) | サブコマンドとフラグ |
| [ルーティング](docs/ja/routing.ja.md) | ルート登録、ルーターファイル |
| [DSL リファレンス](docs/ja/dsl.ja.md) | `let`、`when...of`、`??`、`|>`、型、safe HTML |
| [API リファレンス](docs/ja/api.ja.md) | Context API、リクエスト/レスポンス、`env::` |
| [プラグイン](docs/ja/plugins.ja.md) | プラグインフック、サブモジュール配布 |
| [ネイティブ拡張](docs/ja/libs.ja.md) | Zig ライブラリ、キャッシュ API、マルチワーカー |
| [テスト](docs/ja/testing.ja.md) | テストターゲットと CI |

---

MIT © redpeacock78 · 🌐 [English](README.md)
