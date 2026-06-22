🌐 [日本語](api.ja.md) | [← Back to README](../README.md)

# App API (hawk::)

`hawk.app.*` is the primary routing interface in DSL style. Desugars to `hawk::dispatch("app.*", ...)`.

## Routing methods

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

Register routes for multiple methods and/or paths. Pass strings or gawk arrays.

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

## `hawk::all(paths, handler)`

Register all standard methods (GET POST PUT DELETE PATCH HEAD OPTIONS) for one or more paths.

```awk
hawk::all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk::all(ps, "handler")
```

## Context API reference

Request helpers return `Result<Untrusted<Str>, ParseError>` — use `when...of` or `?=` to unwrap. Empty values are present values and return `ok("")`; missing keys return `ng(ParseError, "missing ...")`.

| DSL | Desugared | Return type |
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
| `ctx.res.html(data)` | `ctx::dispatch("res.html", data)` | `Response` (`HtmlEscapedStr\|HtmlFragment` required) |
| `ctx.res.render(path)` | `ctx::dispatch("res.render", path)` | `Response` |
| `ctx.res.status(code)` | `ctx::dispatch("res.status", code)` | `Response` |
| `ctx.res.header(name, val)` | `ctx::dispatch("res.header", name, val)` | `Response` |
| `ctx.res.redirect(url)` | `ctx::dispatch("res.redirect", url, 302)` | `Response` |
| `ctx.res.redirect(url, code)` | `ctx::dispatch("res.redirect", url, code)` | `Response` |

`ctx.res.json(data)` JSON-encodes an AWK array or scalar value and sets the response body with `Content-Type: application/json; charset=utf-8`. Use `ctx.res.json_raw(str)` only when `str` is already encoded JSON and should be sent as-is.

> **Breaking change:** `ctx.res.json(data)` now JSON-encodes an AWK array or value and sets it on the response.
> For the previous behavior, where a pre-encoded JSON string was passed through unchanged, use `ctx.res.json_raw(str)`.

`ctx.res.render(path)` reads templates through `HAWK_TEMPLATE_ROOT` when that environment variable is set. In that mode, absolute paths, `..` traversal, unsafe path characters, and resolved paths outside the template root are rejected. If `HAWK_TEMPLATE_ROOT` is unset, the path is used as provided.

# Environment (env::)

`env::` is a [Deno.env](https://deno.land/api?s=Deno.env)-style namespace for reading and writing environment variables at runtime.

```awk
env::get("KEY")          # returns ENVIRON["KEY"]; "" if unset
env::set("KEY", "val")   # ENVIRON["KEY"] = "val" (current process only)
env::del("KEY")          # delete ENVIRON["KEY"]
env::has("KEY")          # 1 if set, 0 if not
```

DSL-style (dot-notation) invocations are also supported:

```awk
env.get("KEY")
env.set("KEY", "val")
env.del("KEY")
env.has("KEY")
```

Variables set or deleted via `env::set` / `env::del` are visible to subsequent `env::get` calls within the same gawk process, but are **not** propagated to child processes spawned via `system()` or pipes.

```awk
# Read port from environment, fall back to 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

*For route splitting with `@namespace`, see [Routing](routing.md#router-files).*
