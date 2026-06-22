🌐 [日本語](api.ja.md) | [← Back to README](../README.md)

# App API (hawk.app.*)

`hawk.app.*` is the primary routing interface. All methods desugar to `hawk::dispatch("app.*", ...)`.

## Standard methods

```awk
hawk.app.get(path, handler)    # GET
hawk.app.post(path, handler)   # POST
hawk.app.put(path, handler)    # PUT
hawk.app.del(path, handler)    # DELETE
hawk.app.patch(path, handler)  # PATCH
hawk.app.head(path, handler)   # HEAD
```

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

## hawk.app.listen(port)

Start the HTTP server on the given port. Call once in `BEGIN`.

```awk
hawk.app.listen(8080)
hawk.app.listen(env.get("PORT") ?? 8080)
```

## hawk::all(paths, handler)

Register all standard HTTP methods (GET POST PUT DELETE PATCH HEAD OPTIONS) for one or more paths. Uses the direct `hawk::` namespace — there is no `hawk.app.all` DSL form.

```awk
hawk::all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk::all(ps, "handler")
```

---

# Context API (ctx.*)

## Request (ctx.req.*)

Request helpers return `Result<Untrusted<Str>, ParseError>` — use `when...of` or `?=` to unwrap. Empty values are present values and return `ok("")`; missing keys return `ng(ParseError, "missing ...")`.

| DSL | Desugared | Return type |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `ctx::dispatch("req.json")` | `Result<Untrusted<Str>, ParseError>` |

## Response (ctx.res.*)

| DSL | Desugared | Return type |
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

> **Breaking change:** `ctx.res.json(data)` now JSON-encodes an AWK array or value. For the previous behavior — passing a pre-encoded JSON string unchanged — use `ctx.res.json_raw(str)`.

`ctx.res.render(path)` reads templates through `HAWK_TEMPLATE_ROOT` when that environment variable is set. In that mode, absolute paths, `..` traversal, unsafe path characters, and paths outside the template root are rejected. If `HAWK_TEMPLATE_ROOT` is unset, the path is used as provided.

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

function todo_add() -> Response {
  # ... write data ...
  cache.del("todos:html")   # invalidate on write
  cache.del("todos:json")
}
```

## Methods

| DSL | Return type | Description |
|---|---|---|
| `cache.get(key)` | `Str` | Get cached value. Check `cache.found()` to distinguish a hit from an empty string. |
| `cache.set(key, value, ttl)` | `Void` | Store value with TTL in seconds. `ttl=0` means no expiry. |
| `cache.del(key)` | `Void` | Remove a key. No-op if key does not exist. |
| `cache.has(key)` | `Bool` | Return 1 if key exists and has not expired. |
| `cache.found()` | `Bool` | Return 1 if the most recent `cache.get` was a hit. |
| `cache.remember(key, ttl, fn)` | `Str` | Get or compute: call `fn()` on miss, cache the result, return it. |
| `cache.backend()` | `Str` | Return the active backend name (`zig`, `file`, `memory`, or `off`). |
| `cache.stats()` | `Str` | Return hit/miss/set counters as a string. |

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

---

# Environment (env.*)

`env.` / `env::` is a [Deno.env](https://deno.land/api?s=Deno.env)-style namespace for reading and writing environment variables at runtime.

```awk
env.get("KEY")           # returns ENVIRON["KEY"]; "" if unset
env.set("KEY", "val")    # ENVIRON["KEY"] = "val" (current process only)
env.del("KEY")           # delete ENVIRON["KEY"]
env.has("KEY")           # 1 if set, 0 if not
```

Both `env::` (direct namespace) and `env.` (dot-notation DSL) forms are supported.

Variables set or deleted via `env.set` / `env.del` are visible to subsequent `env.get` calls within the same gawk process, but are **not** propagated to child processes spawned via `system()` or pipes.

```awk
# Read port from environment, fall back to 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

*For route splitting with `@namespace`, see [Routing](routing.md#router-files).*
