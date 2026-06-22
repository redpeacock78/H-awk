🌐 [English](../api.md) | [← README に戻る](../../README.ja.md)

# アプリケーション API (hawk.app.*)

`hawk.app.*` は主要なルーティングインターフェースです。DSL のドット記法は `hawk::dispatch("app.*", ...)` に脱糖され、対応する `hawk::` 関数にルーティングされます。両形式は実行時に等価です。

| DSL | 名前空間形式 |
|---|---|
| `hawk.app.get(path, handler)` | `hawk::get(path, handler)` |
| `hawk.app.post(path, handler)` | `hawk::post(path, handler)` |
| `hawk.app.put(path, handler)` | `hawk::put(path, handler)` |
| `hawk.app.del(path, handler)` | `hawk::del(path, handler)` |
| `hawk.app.patch(path, handler)` | `hawk::patch(path, handler)` |
| `hawk.app.head(path, handler)` | `hawk::head(path, handler)` |
| `hawk.app.on(methods, paths, handler)` | `hawk::on(methods, paths, handler)` |
| `hawk.app.all(paths, handler)` | `hawk::all(paths, handler)` |
| `hawk.app.listen(port)` | `hawk::listen(port)` |

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

## hawk.app.all(paths, handler)

標準 HTTP メソッド（GET POST PUT DELETE PATCH HEAD OPTIONS）すべてを 1 つまたは複数のパスに登録します。

```awk
hawk.app.all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk.app.all(ps, "handler")
```

## hawk.app.listen(port)

指定ポートで HTTP サーバーを起動します。`BEGIN` ブロック内で 1 回呼び出してください。

```awk
hawk.app.listen(8080)
hawk.app.listen(env.get("PORT") ?? 8080)
```

---

# Context API (ctx.*)

`ctx.*` は `ctx::dispatch(...)` 経由でディスパッチされ、対応する内部ハンドラにルーティングされます。DSL 形式と `ctx::dispatch(...)` 直接呼び出しは実行時に等価です。

## リクエスト (ctx.req.*)

リクエストヘルパーは `Result<Untrusted<Str>, ParseError>` を返します。`when...of` または `?=` でアンラップしてください。空の値は `ok("")` を返し、欠落キーは `ng(ParseError, "missing ...")` を返します。

| DSL | 直接呼び出し | 戻り値の型 |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `ctx::dispatch("req.json")` | `Result<Untrusted<Map>, ParseError>` |

## レスポンス (ctx.res.*)

| DSL | 直接呼び出し | 戻り値の型 |
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

`ctx.res.render(path)` は `HAWK_TEMPLATE_ROOT` が設定されている場合、そのパスを通じてテンプレートを読み込みます。このモードでは、空パス・絶対パス・`..` トラバーサル・安全でないパス文字・テンプレートルート外のパスは拒否されます。未設定の場合、パスはそのまま使用されます。

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

function todo_add() -> Void {
  # ... write data ...
  cache.del("todos:html")   # invalidate on write
  cache.del("todos:json")
}
```

## メソッド

| DSL | 名前空間形式 | 戻り値の型 |
|---|---|---|
| `cache.get(key)` | `cache::get(key)` | `Str` |
| `cache.set(key, value, ttl)` | `cache::set(key, value, ttl)` | `Void` |
| `cache.del(key)` | `cache::del(key)` | `Void` |
| `cache.has(key)` | `cache::has(key)` | `Bool` |
| `cache.found()` | `cache::found()` | `Bool` |
| `cache.remember(key, ttl, fn)` | `cache::remember(key, ttl, fn)` | `Str` |
| `cache.backend()` | `cache::backend()` | `Str` |
| `cache.stats()` | `cache::stats()` | `Str` |

`cache.get(key)` はキャッシュミスとキャッシュ済みの空文字列のどちらでも `""` を返します。`cache.get` の直後に `cache.found()` で区別してください。

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

## キャッシュサイズ（zig バックエンド専用）

`zig` バックエンドは固定サイズの共有メモリ領域（file-backed mmap）を確保します。`HAWK_SHARED_CACHE_SIZE` でサイズを指定できます。

```sh
HAWK_SHARED_CACHE_SIZE=512K ./bin/hawk app.awk   # 512 KiB（デフォルト）
HAWK_SHARED_CACHE_SIZE=1M   ./bin/hawk app.awk   # 1 MiB
HAWK_SHARED_CACHE_SIZE=2097152 ./bin/hawk app.awk # バイト数で直接指定
```

| 値 | 最小 | 最大 | デフォルト |
|---|---|---|---|
| バイト数 / K / M | 64K | 64M | 512K |

64K 未満は 64K に、64M 超過は 64M に丸めます。不正値は 512K にフォールバックします。

> **注意:** `zig` バックエンドは最大 512 バイトの値を保存できます。それより長い値は `error.TooLarge` で拒否されます。

---

# 環境変数 (env.*)

`env.*` / `env::` は [Deno.env](https://deno.land/api?s=Deno.env) スタイルの実行時環境変数読み書き用の名前空間です。

| DSL | 名前空間形式 | 戻り値の型 |
|---|---|---|
| `env.get("KEY")` | `env::get("KEY")` | `Str` |
| `env.set("KEY", val)` | `env::set("KEY", val)` | `Void` |
| `env.del("KEY")` | `env::del("KEY")` | `Void` |
| `env.has("KEY")` | `env::has("KEY")` | `Bool` |

`env.set` / `env.del` で設定・削除した変数は同じ gawk プロセス内の後続の `env.get` から参照できますが、`system()` やパイプで起動した子プロセスには**伝播されません**。

```awk
# 環境変数からポートを読み込み、デフォルトは 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

*`@namespace` を使ったルート分割については、[ルーティング](routing.ja.md#ルーターファイル)を参照してください。*
