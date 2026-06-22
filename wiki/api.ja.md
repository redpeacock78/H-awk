🌐 [English](api.md) | [← README に戻る](../README.ja.md)

# アプリケーション API (hawk.app.*)

`hawk.app.*` は主要なルーティングインターフェースです。すべてのメソッドは `hawk::dispatch("app.*", ...)` に脱糖されます。

## 標準メソッド

```awk
hawk.app.get(path, handler)    # GET
hawk.app.post(path, handler)   # POST
hawk.app.put(path, handler)    # PUT
hawk.app.del(path, handler)    # DELETE
hawk.app.patch(path, handler)  # PATCH
hawk.app.head(path, handler)   # HEAD
```

`handler` は関数名を表す文字列です。ルートは登録順にマッチします。

## hawk.app.on(methods, paths, handler)

複数のメソッドおよび/またはパスにまとめてルートを登録します。引数には文字列または gawk 配列を渡せます。

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

## hawk.app.listen(port)

指定ポートで HTTP サーバーを起動します。`BEGIN` ブロック内で 1 回呼び出してください。

```awk
hawk.app.listen(8080)
hawk.app.listen(env.get("PORT") ?? 8080)
```

## hawk::all(paths, handler)

標準 HTTP メソッド（GET POST PUT DELETE PATCH HEAD OPTIONS）すべてを 1 つまたは複数のパスに登録します。`hawk::` 名前空間を直接使用するため、`hawk.app.all` という DSL 形式は存在しません。

```awk
hawk::all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk::all(ps, "handler")
```

---

# Context API (ctx.*)

## リクエスト (ctx.req.*)

リクエストヘルパーは `Result<Untrusted<Str>, ParseError>` を返します。`when...of` または `?=` でアンラップしてください。空の値は存在する値として `ok("")` を返し、欠落キーは `ng(ParseError, "missing ...")` を返します。

| DSL | 脱糖後 | 戻り値の型 |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `ctx::dispatch("req.json")` | `Result<Untrusted<Str>, ParseError>` |

## レスポンス (ctx.res.*)

| DSL | 脱糖後 | 戻り値の型 |
|---|---|---|
| `ctx.res.json(data)` | `ctx::dispatch("res.json", data)` | `Response` |
| `ctx.res.json_raw(str)` | `ctx::dispatch("res.json_raw", str)` | `Response` |
| `ctx.res.text(data)` | `ctx::dispatch("res.text", data)` | `Response` |
| `ctx.res.html(data)` | `ctx::dispatch("res.html", data)` | `Response`（`HtmlEscapedStr\|HtmlFragment` が必須） |
| `ctx.res.render(path)` | `ctx::dispatch("res.render", path)` | `Response` |
| `ctx.res.status(code)` | `ctx::dispatch("res.status", code)` | `Response` |
| `ctx.res.header(name, val)` | `ctx::dispatch("res.header", name, val)` | `Response` |
| `ctx.res.redirect(url)` | `ctx::dispatch("res.redirect", url, 302)` | `Response` |
| `ctx.res.redirect(url, code)` | `ctx::dispatch("res.redirect", url, code)` | `Response` |

`ctx.res.json(data)` は AWK 配列またはスカラー値を JSON エンコードし、`Content-Type: application/json; charset=utf-8` でレスポンスボディを設定します。`str` が既にエンコード済み JSON でそのまま送信する場合は `ctx.res.json_raw(str)` を使用してください。

> **破壊的変更:** `ctx.res.json(data)` は AWK 配列または値を JSON エンコードするようになりました。以前の動作（事前エンコード済み JSON 文字列をそのまま通す）には `ctx.res.json_raw(str)` を使用してください。

`ctx.res.render(path)` は `HAWK_TEMPLATE_ROOT` が設定されている場合、そのパスを通じてテンプレートを読み込みます。このモードでは、絶対パス・`..` トラバーサル・安全でないパス文字・テンプレートルート外のパスは拒否されます。未設定の場合、パスはそのまま使用されます。

---

# キャッシュ API (cache.*)

自動バックエンド選択付きの組み込みキャッシュファサードです。AWK ファイルでドット記法を使用してください。

```awk
function todo_list_html() -> Response {
  let cached: Str = cache.get("todos:html")
  if (cache.found()) {
    return ctx.res.html(safe.html.raw(cached))
  }
  # ... build response ...
  cache.set("todos:html", out, 30)   # TTL: 30 seconds
  return ctx.res.html(safe.html.raw(out))
}

function todo_add() -> Response {
  # ... write data ...
  cache.del("todos:html")   # invalidate on write
  cache.del("todos:json")
}
```

## メソッド

| DSL | 戻り値の型 | 説明 |
|---|---|---|
| `cache.get(key)` | `Str` | キャッシュされた値を取得します。ヒットと空文字列を区別するには `cache.found()` を確認してください。 |
| `cache.set(key, value, ttl)` | `Void` | TTL（秒）付きで値を保存します。`ttl=0` は無期限です。 |
| `cache.del(key)` | `Void` | キーを削除します。存在しない場合は何もしません。 |
| `cache.has(key)` | `Bool` | キーが存在し有効期限が切れていない場合は 1 を返します。 |
| `cache.found()` | `Bool` | 最後の `cache.get` がヒットした場合は 1 を返します。 |
| `cache.remember(key, ttl, fn)` | `Str` | キャッシュから取得、またはミス時に `fn()` を呼び出して結果をキャッシュして返します。 |
| `cache.backend()` | `Str` | アクティブなバックエンド名（`zig`、`file`、`memory`、または `off`）を返します。 |
| `cache.stats()` | `Str` | ヒット/ミス/セットカウンタを文字列で返します。 |

## バックエンド選択

`HAWK_CACHE_BACKEND` を明示的に設定するか、未設定のままにして自動選択させます：

| 値 | 説明 |
|---|---|
| `auto`（デフォルト） | `zig` → `file` → `memory`、最初に利用可能なものを使用 |
| `zig` | `libs/cache` 経由の共有メモリキャッシュ（`make build-libs` が必要）。全ワーカーで共有されます。 |
| `file` | `$HAWK_RUN_DIR/cache/cache.tsv` のファイルバックアップキャッシュ。ワーカー間で共有されます。Zig 不要。 |
| `memory` | プロセスローカルな AWK 配列。ワーカー間では共有されません。 |
| `off` | キャッシュ無効。`cache.get` は常にミスし、`cache.set` は何もしません。 |

`libs/cache` がビルドされている場合、`zig` バックエンドが自動選択され全ワーカーがキャッシュを共有します。それ以外は `HAWK_RUN_DIR` が書き込み可能なら `file`、そうでなければ `memory` が使われます。

```sh
HAWK_CACHE_BACKEND=file ./bin/hawk app.awk
HAWK_CACHE_BACKEND=off  ./bin/hawk app.awk
```

---

# 環境変数 (env.*)

`env.` / `env::` は [Deno.env](https://deno.land/api?s=Deno.env) スタイルの実行時環境変数読み書き用の名前空間です。

```awk
env.get("KEY")           # ENVIRON["KEY"] を返す。未設定なら ""
env.set("KEY", "val")    # ENVIRON["KEY"] = "val"（現在のプロセスのみ）
env.del("KEY")           # ENVIRON["KEY"] を削除
env.has("KEY")           # 設定されていれば 1、そうでなければ 0
```

`env::` （直接名前空間）と `env.`（ドット記法 DSL）の両形式が使用できます。

`env.set` / `env.del` で設定・削除した変数は同じ gawk プロセス内の後続の `env.get` から参照できますが、`system()` やパイプで起動した子プロセスには**伝播されません**。

```awk
# 環境変数からポートを読み込み、デフォルトは 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

*`@namespace` を使ったルート分割については、[ルーティング](routing.ja.md#ルーターファイル)を参照してください。*
