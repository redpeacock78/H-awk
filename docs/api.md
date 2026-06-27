🌐 [日本語](ja/api.ja.md) | [← Back to README](../README.md)

# App API (hawk.app.*)

`hawk.app.*` is the primary routing interface. The DSL dot-notation form desugars to `hawk::dispatch("app.*", ...)`, which routes to the corresponding `hawk::` function. Both forms are equivalent at runtime.

| DSL | Namespace form |
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

`handler` is a function name as a string. Routes are matched in registration order.

## hawk.app.on(methods, paths, handler)

Register routes for multiple methods and/or paths at once. Pass strings or gawk arrays for either argument.

```awk
# single method + path
hawk.app.on("GET", "/todos", "list_todos")

# multiple methods (array)
delete ms; ms[1] = "GET"; ms[2] = "POST"
hawk.app.on(ms, "/todos", "list_todos")

# multiple paths (array)
delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk.app.on("GET", ps, "list_todos")

# custom method
hawk.app.on("PURGE", "/cache", "purge_cache")
```

## hawk.app.all(paths, handler)

Register all standard HTTP methods (GET POST PUT DELETE PATCH HEAD OPTIONS) for one or more paths.

```awk
hawk.app.all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk.app.all(ps, "handler")
```

## hawk.app.listen(port)

Start the HTTP server on the given port. Call once in `BEGIN`.

```awk
hawk.app.listen(8080)
hawk.app.listen(env.get("PORT") ?? 8080)
```

---

# Context API (ctx.*)

`ctx.*` dispatches through `ctx::dispatch(...)`, which routes to the corresponding internal handler. Both the DSL form and the `ctx::dispatch(...)` direct call are equivalent at runtime.

## Request (ctx.req.*)

Request helpers return `Result<Untrusted<Str>, ParseError>` — use `when...of` or `?=` to unwrap. Empty values return `ok("")`; missing keys return `ng(ParseError, "missing ...")`.

| DSL | Direct call | Return type |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `ctx::dispatch("req.json")` | `Result<Untrusted<Map>, ParseError>` |

Future typed JSON request parsing is available as an MVP:

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

## Response (ctx.res.*)

| DSL | Direct call | Return type |
|---|---|---|
| `ctx.res.json(data)` | `ctx::dispatch("res.json", data)` | `Response` |
| `ctx.res.json_raw(str)` | `ctx::dispatch("res.json_raw", str)` | `Response` |
| `ctx.res.text(data)` | `ctx::dispatch("res.text", data)` | `Response` |
| `ctx.res.html(data)` | `ctx::dispatch("res.html", data)` | `Response` (requires `HtmlEscapedStr\|HtmlFragment`) |
| `ctx.res.render(path)` | `ctx::dispatch("res.render", path)` | `Response` |
| `ctx.res.status(code)` | `ctx::dispatch("res.status", code)` | `Response` |
| `ctx.res.header(name, val)` | `ctx::dispatch("res.header", name, val)` | `Response` |
| `ctx.res.redirect(url)` | `ctx::dispatch("res.redirect", url, 302)` | `Response` |
| `ctx.res.redirect(url, code)` | `ctx::dispatch("res.redirect", url, code)` | `Response` |

`ctx.res.json(data)` JSON-encodes an AWK array or scalar value and sets the response body with `Content-Type: application/json; charset=utf-8`. Use `ctx.res.json_raw(str)` only when `str` is already encoded JSON and should be sent as-is.

If `data` is `List<T>`, `ctx.res.json(data)` returns a JSON array. If `data` is `Dict<Str, V>` or a Record, it returns a JSON object. Without type information, such as a legacy AWK array, it falls back to the previous behavior.

> **Breaking change:** `ctx.res.json(data)` now JSON-encodes an AWK array or value. For the previous behavior — passing a pre-encoded JSON string unchanged — use `ctx.res.json_raw(str)`.

`ctx.res.render(path)` reads templates through `HAWK_TEMPLATE_ROOT` when that environment variable is set. In that mode, empty paths, absolute paths, `..` traversal, unsafe path characters, and paths outside the template root are rejected. If `HAWK_TEMPLATE_ROOT` is unset, the path is used as provided.

Gzip compression is automatic and has no explicit API. Set `HAWK_GZIP=1` to enable it. Responses are compressed when `Accept-Encoding` contains `gzip` and the body is at least `HAWK_GZIP_MIN_SIZE` bytes (default: 1024). H-awk does not compress 204/304/HEAD responses, responses that already set `Content-Encoding`, image/zip/gzip/pdf content, or small bodies. Compressed responses add `Content-Encoding: gzip`, `Vary: Accept-Encoding`, and `Content-Length: <compressed>`.

---

## JSON

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

Error types: `JsonParseError`, `JsonTypeError`, `JsonTooDeepError`.

---

# URL API (url.*)

Uses `libs/url` when present, otherwise the AWK fallback.

```awk
url.encode(str)             # -> Str
url.decode(str)             # -> Result<Str, UrlError>
url.decode_form(str)        # -> Result<Str, UrlError> (+ treated as space)
url.query_parse(str)        # -> Dict<Str, Str>
url.query_string(dict)      # -> Str
```

Error types: `InvalidPercentEncoding`, `InvalidUtf8`.

---

# Cache API (cache.*)

Built-in cache facade with automatic backend selection. Use dot-notation in your AWK files.

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

## Methods

| DSL | Namespace form | Return type |
|---|---|---|
| `cache.get(key)` | `cache::get(key)` | `Str` |
| `cache.set(key, value, ttl)` | `cache::set(key, value, ttl)` | `Void` |
| `cache.del(key)` | `cache::del(key)` | `Void` |
| `cache.has(key)` | `cache::has(key)` | `Bool` |
| `cache.found()` | `cache::found()` | `Bool` |
| `cache.remember(key, ttl, fn)` | `cache::remember(key, ttl, fn)` | `Str` |
| `cache.backend()` | `cache::backend()` | `Str` |
| `cache.stats()` | `cache::stats()` | `Str` |

`cache.get(key)` returns `""` on both a cache miss and a cached empty string — use `cache.found()` after `cache.get` to distinguish the two cases.

## Backend selection

Set `HAWK_CACHE_BACKEND` to choose a backend explicitly, or leave unset for automatic selection:

| Value | Description |
|---|---|
| `auto` (default) | `zig` → `file` → `memory`, whichever is available first |
| `zig` | Shared-memory cache via `libs/cache` (requires `make build-libs`). Shared across all workers. |
| `file` | File-backed cache at `$HAWK_RUN_DIR/cache/cache.tsv`. Shared across workers. No Zig required. |
| `memory` | Process-local AWK array. Not shared between workers. |
| `off` | Cache disabled. `cache.get` always misses, `cache.set` is a no-op. |

When `libs/cache` is built, the `zig` backend is selected automatically and all workers share the same cache. Without it, `file` is used if `HAWK_RUN_DIR` is writable, otherwise `memory`.

```sh
HAWK_CACHE_BACKEND=file ./bin/hawk app.awk
HAWK_CACHE_BACKEND=off  ./bin/hawk app.awk
```

## Cache size (zig backend only)

The `zig` backend allocates a fixed-size shared memory region (file-backed mmap). Control its size with `HAWK_SHARED_CACHE_SIZE`:

```sh
HAWK_SHARED_CACHE_SIZE=512K ./bin/hawk app.awk   # 512 KiB (default)
HAWK_SHARED_CACHE_SIZE=1M   ./bin/hawk app.awk   # 1 MiB
HAWK_SHARED_CACHE_SIZE=2097152 ./bin/hawk app.awk # raw bytes
```

| Value | Min | Max | Default |
|---|---|---|---|
| bytes / K / M | 64K | 64M | 512K |

Values below 64K are clamped to 64K; values above 64M are clamped to 64M. Invalid strings fall back to 512K.

> **Note:** The `zig` backend stores values up to 512 bytes. Longer values are rejected with `error.TooLarge`.

---

# Environment (env.*)

`env.*` / `env::` is a [Deno.env](https://deno.land/api?s=Deno.env)-style namespace for reading and writing environment variables at runtime.

| DSL | Namespace form | Return type |
|---|---|---|
| `env.get("KEY")` | `env::get("KEY")` | `Str` |
| `env.set("KEY", val)` | `env::set("KEY", val)` | `Void` |
| `env.del("KEY")` | `env::del("KEY")` | `Void` |
| `env.has("KEY")` | `env::has("KEY")` | `Bool` |

Variables set or deleted via `env.set` / `env.del` are visible to subsequent `env.get` calls within the same gawk process, but are **not** propagated to child processes spawned via `system()` or pipes.

```awk
# Read port from environment, fall back to 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

*For route splitting with `@namespace`, see [Routing](routing.md#router-files).*
