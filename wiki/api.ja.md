🌐 [English](api.md) | [← README に戻る](../README.ja.md)

# アプリケーション API (hawk::)

`hawk.app.*` は DSL スタイルの主要なルーティングインターフェースです。`hawk::dispatch("app.*", ...)` に脱糖されます。

## ルーティングメソッド

```awk
hawk.app.get(path, handler)
hawk.app.post(path, handler)
hawk.app.put(path, handler)
hawk.app.del(path, handler)
hawk.app.patch(path, handler)
hawk.app.head(path, handler)
hawk.app.on(methods, paths, handler)
hawk.app.listen(port)
```

## `hawk.app.on(methods, paths, handler)`

複数のメソッドおよび/またはパスに対してルートを登録します。文字列または gawk 配列を渡します。

```awk
# 単一メソッド + パス
hawk.app.on("GET", "/todos", "list_todos")

# 複数メソッド（配列）
delete ms; ms[1] = "GET"; ms[2] = "POST"
hawk.app.on(ms, "/todos", "list_todos")

# 複数パス（配列）
delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk.app.on("GET", ps, "list_todos")

# カスタムメソッド
hawk.app.on("PURGE", "/cache", "purge_cache")
```

## `hawk::all(paths, handler)`

標準メソッド（GET POST PUT DELETE PATCH HEAD OPTIONS）をすべて 1 つまたは複数のパスに登録します。

```awk
hawk::all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk::all(ps, "handler")
```

## Context API リファレンス

リクエストヘルパーは `Result<Untrusted<Str>, ParseError>` を返します。`when...of` または `?=` を使ってアンラップしてください。空の値は存在する値で `ok("")` を返します。欠落キーは `ng(ParseError, "missing ...")` を返します。

| DSL | 脱糖後 | 戻り値の型 |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `ctx::dispatch("req.json")` | `Result<Untrusted<Map>, ParseError>` |
| `ctx.res.json(data)` | `ctx::dispatch("res.json", data)` | `Response` |
| `ctx.res.json_raw(str)` | `ctx::dispatch("res.json_raw", str)` | `Response` |
| `ctx.res.text(data)` | `ctx::dispatch("res.text", data)` | `Response` |
| `ctx.res.html(data)` | `ctx::dispatch("res.html", data)` | `Response`（`HtmlEscapedStr\|HtmlFragment` が必須） |
| `ctx.res.render(path)` | `ctx::dispatch("res.render", path)` | `Response` |
| `ctx.res.status(code)` | `ctx::dispatch("res.status", code)` | `Response` |
| `ctx.res.header(name, val)` | `ctx::dispatch("res.header", name, val)` | `Response` |
| `ctx.res.redirect(url)` | `ctx::dispatch("res.redirect", url, 302)` | `Response` |
| `ctx.res.redirect(url, code)` | `ctx::dispatch("res.redirect", url, code)` | `Response` |

`ctx.res.json(data)` は AWK 配列またはスカラー値を JSON エンコードし、`Content-Type: application/json; charset=utf-8` でレスポンスボディを設定します。`str` が既にエンコード済み JSON で、そのまま送信する場合は `ctx.res.json_raw(str)` のみを使用してください。

> **破壊的変更:** `ctx.res.json(data)` は AWK 配列または値を JSON エンコードし、レスポンスに設定するようになりました。
> 以前の動作（事前エンコードされた JSON 文字列がそのまま渡されていた）については、`ctx.res.json_raw(str)` を使用してください。

`ctx.res.render(path)` は環境変数 `HAWK_TEMPLATE_ROOT` が設定されている場合、そのパスを通じてテンプレートを読み込みます。このモードでは、絶対パス、`..` トラバーサル、安全でないパス文字、テンプレートルートの外に解決されたパスは拒否されます。`HAWK_TEMPLATE_ROOT` が設定されていない場合、パスはそのまま使用されます。

## 環境変数 (env::)

`env::` は [Deno.env](https://deno.land/api?s=Deno.env) スタイルの実行時環境変数読み書き用の名前空間です。

```awk
env::get("KEY")          # ENVIRON["KEY"] を返す。未設定の場合は ""
env::set("KEY", "val")   # ENVIRON["KEY"] = "val"（現在のプロセスのみ）
env::del("KEY")          # ENVIRON["KEY"] を削除
env::has("KEY")          # 設定されている場合は 1、そうでない場合は 0
```

DSL スタイル（ドット記法）の呼び出しもサポートされています。

```awk
env.get("KEY")
env.set("KEY", "val")
env.del("KEY")
env.has("KEY")
```

`env::set` / `env::del` を使って設定または削除された変数は、同じ gawk プロセス内の後続の `env::get` 呼び出しから参照できますが、`system()` やパイプで起動された子プロセスには**伝播されません**。

```awk
# 環境変数からポートを読み込み、デフォルトは 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

*ルート分割で `@namespace` を使う場合については、[ルーティング](routing.ja.md#ルーターファイル)を参照してください。*
