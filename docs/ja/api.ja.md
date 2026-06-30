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

将来の型付き JSON リクエスト解析 API は、現在 MVP として利用できます：

```awk
when ctx.req.json<Todo>() of
  ok todo:
    return ctx.res.status(201).json(todo)
  ng e: JsonParseError:
    return ctx.res.status(400).json({ error: "invalid json" })
  ng e: JsonTypeError:
    return ctx.res.status(422).json({ error: "invalid payload" })
end
```

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

`data` が `List<T>` の場合、`ctx.res.json(data)` は JSON 配列を返します。`data` が `Dict<Str, V>` または Record の場合は JSON オブジェクトを返します。型情報がない従来の AWK 配列では、以前の挙動にフォールバックします。

> **破壊的変更:** `ctx.res.json(data)` は AWK 配列または値を JSON エンコードするようになりました。以前の動作（事前エンコード済み JSON 文字列をそのまま通す）には `ctx.res.json_raw(str)` を使用してください。

`ctx.res.render(path)` は `HAWK_TEMPLATE_ROOT` が設定されている場合、そのパスを通じてテンプレートを読み込みます。このモードでは、空パス・絶対パス・`..` トラバーサル・安全でないパス文字・テンプレートルート外のパスは拒否されます。未設定の場合、パスはそのまま使用されます。

gzip 圧縮は自動で行われるため、明示的な API はありません。`HAWK_GZIP=1` で有効化します。`Accept-Encoding` に `gzip` が含まれ、本文が `HAWK_GZIP_MIN_SIZE` バイト以上（デフォルト: 1024）の場合に圧縮します。204/304/HEAD レスポンス、既に `Content-Encoding` が設定されたレスポンス、image/zip/gzip/pdf コンテンツ、小さい本文は圧縮しません。圧縮時は `Content-Encoding: gzip`、`Vary: Accept-Encoding`、`Content-Length: <compressed>` を追加します。

---

# JSON API (json.*)

`libs/json` が存在する場合に利用できます。

| DSL                 | dispatch                              | 戻り値の型                          |
| ------------------- | ------------------------------------- | ----------------------------------- |
| `json.encode(x)`    | `json::dispatch("encode", x)`         | `Str`                               |
| `json.decode(s)`    | `json::dispatch("decode", s)`         | `Result<Any, JsonError>`            |
| `json.decode<T>(s)` | `json::dispatch("decode_t", "T", s)`  | `Result<T, JsonError>`              |

`json.decode<T>` は DSL の山括弧内に書かれた型引数 `T` を desugar 時に第 1 引数の文字列リテラルとして dispatch に渡す。
`let` の宣言型 `Result<T, JsonError>` は、この型引数 `T` を sig 戻り型の `T` に流し込んで `Result<Int, JsonError>` などの具体型に解決する経路で照合される。
Result の ok payload は decode 済みフラット連想配列を「3-field レコード `base64(key)\x1Fbase64(value)\x1Ftype\x1E` の連結文字列」として保持する。
key と value は Base64 で encode するため、JSON 値内に区切り文字 `\x1E` / `\x1F` を含む場合でも安全に運べる。
値と型タグの取り出しは `awk::result_val_into_map(res, out, out_type)` を呼び、`out["key"]` で値、`out_type["key"]` で `int` / `float` / `string` / `bool` / `null` のいずれかを得る。

エラー型: `JsonParseError`、`JsonTypeError`、`JsonTooDeepError`。

---

# URL API (url.*)

`libs/url` が存在する場合はそれを使用し、ない場合は AWK fallback を使用します。

```awk
url.encode(str)             # -> Str
url.decode(str)             # -> Result<Str, UrlError>
url.decode_form(str)        # -> Result<Str, UrlError> (+ treated as space)
url.query_parse(str)        # -> Dict<Str, Str>
url.query_string(dict)      # -> Str
```

エラー型: `InvalidPercentEncoding`、`InvalidUtf8`。

---

# キャッシュ API (cache.*)

自動バックエンド選択付きの組み込みキャッシュファサードです。AWK ファイルでドット記法を使用してください。

```awk
function todo_list_html() -> Response {
  when cache.get("todos:html") of
    ok cached:
      when cached of
        some html:
          return ctx.res.html(safe.html.raw(html))
        none:
          # ... build response ...
      end
    ng e:
      # ... build response without cache ...
  end

  when cache.set("todos:html", out, 30) of
    ok _:
      return ctx.res.html(safe.html.raw(out))
    ng e:
      return ctx.res.html(safe.html.raw(out))
  end
}

function todo_add() -> Void {
  # ... write data ...
  when cache.has("todos:html") of
    ok present:
      if (present) {
        when cache.del("todos:html") of
          ok _:
            # invalidated
          ng e:
            # handle CacheError
        end
      }
    ng e:
      # handle CacheError
  end
}
```

## メソッド

| DSL | dispatch | 戻り値の型 |
|---|---|---|
| `cache.get(key)` | `cache::dispatch("get", key)` | `Effect<Result<Option<Str>, CacheError>>` |
| `cache.set(key, value, ttl)` | `cache::dispatch("set", key, value, ttl)` | `Effect<Result<Void, CacheError>>` |
| `cache.has(key)` | `cache::dispatch("has", key)` | `Effect<Result<Bool, CacheError>>` |
| `cache.del(key)` | `cache::dispatch("del", key)` | `Effect<Result<Bool, CacheError>>` |

`cache.get` はヒット時に `ok(some(value))`、ミス時に `ok(none())` を返します。`cache.found()` は不要です。

`cache.del` は削除直前にキーが存在すると観測された場合に `ok(true)`、それ以外の場合に `ok(false)` を返します。存在確認はベストエフォートです。`has` + `del` の二段実装で、間に並行書込が入ると返値とは異なる状態で削除される可能性あり。

`cache.has` と `cache.del` は AWK ランタイム層で Bool ペイロードを Str 値の `"1"` と `"0"` として返します。これは gawk の Bool 規約に一致します。DSL の `Bool` に対する `when` マッチは、これらのペイロードをそのまま受理します。

`HAWK_CACHE_BACKEND=off` は障害ではなく、通常のキャッシュ無効モードです。`get` は `ok(none())`、`set` は `ok("")`、`has` は `ok("0")`、`del` は `ok("0")` を返します。`CacheUnavailable` は、設定済みバックエンドが利用不能な場合にのみ発生します（Zig ライブラリがない、file バックエンドで `HAWK_RUN_DIR` が未設定など）。

エラータグ: `CacheUnknownMethod`, `CacheLockTimeout`, `CacheTooLarge`, `CacheUnavailable`, `CacheBackendError`。

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
