# H-awk

> Express-style HTTP server for GNU AWK. Write backends in plain AWK.

H-awk is a lightweight HTTP framework built on top of `gawk`. Define routes, handle requests, and build APIs with a familiar Express-like API — no Node, no Python, no compiled binaries required.

## Requirements

- gawk 5.0+ (`gawk --version`)
- bash 4.3+ (for multi-worker supervisor)
- GNU make
- Zig 0.14+ (only for `make build-libs`)
- curl (e2e tests only)

Tested on gawk 5.3.1 / macOS. Linux works. Windows via WSL only.

## Quickstart

```sh
cp .env.example .env

# Optional: build native extensions (binary I/O, TCP transport, etc.)
make build-libs

# Start the server (default :8080, 4 workers)
./bin/hawk app.awk

# Or with make
make run                  # 4 workers (default)
make run WORKERS=8        # 8 workers
make run WORKERS=1        # single worker (debug)
```

```sh
curl http://localhost:8080/
curl -X POST -d 'title=buy+milk' http://localhost:8080/todos
curl -X DELETE http://localhost:8080/todos/1234
curl http://localhost:8080/todos.json
```

`make help` lists all available targets.

## Routing

`bin/hawk` desugars your app file at startup — write routes and handlers using dot-notation DSL, and gawk locals using `let`.

```awk
BEGIN {
  hawk.app.get("/todos",        "list_todos")
  hawk.app.post("/todos",       "add_todo")
  hawk.app.del("/todos/:id",    "delete_todo")
  hawk.app.listen(env.get("PORT") ?? 8080)
}

function list_todos() {
  let rows = []
  let n = read_tsv("data/todos.tsv", rows)
  return ctx.res.json(sprintf("[%d items]", n))
}

function add_todo() {
  let title = ctx.req.form("title")
  if (title == "") {
    ctx.res.status(400)
    return ctx.res.text("title required")
  }
  ctx.res.status(201)
  return ctx.res.text("added: " title)
}

function delete_todo() {
  delete_tsv("data/todos.tsv", "id", ctx.req.param("id"))
  ctx.res.status(200)
  return ctx.res.html("")
}
```

## DSL Preprocessing

`bin/hawk` runs every app file through `dsl/desugar.awk` before passing it to gawk. Two transforms are applied:

**Dot-notation → dispatch**

```awk
# DSL
hawk.app.get("/todos", "list_todos")
ctx.req.form("title")

# Desugared
hawk::dispatch("app.get", "/todos", "list_todos")
ctx::dispatch("req.form", "title")
```

Rule: `ns.a.b.c(args)` → `ns::dispatch("a.b.c", args)`. First segment is the dispatcher namespace; the rest becomes the path string.

**`let` → gawk local variables**

```awk
# DSL
function handler() {
  let title = ctx.req.form("title")
  let items = []
  let tmp
  ...
}

# Desugared
function handler(    title, items, tmp) {
  title = ctx::dispatch("req.form", "title")
  delete items
  ...
}
```

`let` declarations are hoisted to the function signature as gawk locals (4-space convention). `let name = []` becomes `delete name`. Bare `let name` is hoisted only (line removed).

**Type annotations on `let`**

```awk
# Typed let with initializer — coerced + static check at desugar time
function handler() {
  let port: Int = 8080
  let title: Str = ctx.req.form("title")
}

# Desugared
function handler(    port, title) {
  port  = type::coerce(8080, "Int")
  title = type::coerce(ctx::dispatch("req.form", "title"), "Str")
}
```

```awk
# Bare typed declaration — hoist only, typed assignment auto-coerced
function handler() {
  let n: Int
  n = "42"   # auto-coerced + static check
}

# Desugared
function handler(    n) {
  n = type::coerce("42", "Int")
}
```

Static type checking at desugar time — mismatched types produce an error:

```sh
# Desugar-time error: string literal assigned to Int
let port: Int = "hello"
# dsl error: app.awk:5: type mismatch: cannot assign Str to Int
```

Supported types: `Int`, `Float`, `Str`, `Bool`. Type inference works for literals and known DSL functions (`env.get` → Str, `ctx.req.form` → Str, etc.).

**`??` null-coalescing operator**

```awk
# DSL
hawk.app.listen(env.get("PORT") ?? 8080)

# Desugared
_ds_tc_1 = env::dispatch("get", "PORT")
hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
```

Rule: `expr ?? default` — if `expr` evaluates to empty string, use `default`. Works inside function arguments.

Use `--debug` to inspect the generated file:

```sh
./bin/hawk --debug app.awk   # prints temp file path to stderr
```

## App API (hawk::)

`hawk.app.*` is the primary routing interface in DSL style. Desugars to `hawk::dispatch("app.*", ...)`.

### Routing methods

```awk
hawk.app.get(path, handler)
hawk.app.post(path, handler)
hawk.app.put(path, handler)
hawk.app.del(path, handler)
hawk.app.patch(path, handler)
hawk.app.head(path, handler)
hawk.app.listen(port)
```

### `hawk::on(methods, paths, handler)`

Register routes for multiple methods and/or paths. Pass strings or gawk arrays.

```awk
# single method + path
hawk::on("GET", "/todos", "list_todos")

# multiple methods (array)
delete ms; ms[1] = "GET"; ms[2] = "POST"
hawk::on(ms, "/todos", "list_todos")

# multiple paths (array)
delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk::on("GET", ps, "list_todos")

# custom method
hawk::on("PURGE", "/cache", "purge_cache")
```

### `hawk::all(paths, handler)`

Register all standard methods (GET POST PUT DELETE PATCH HEAD OPTIONS) for one or more paths.

```awk
hawk::all("/health", "ping")

delete ps; ps[1] = "/todos"; ps[2] = "/tasks"
hawk::all(ps, "handler")
```

### Context API reference

| DSL | Desugared | Description |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | URL query parameter |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | Path parameter (`:id`) |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | Request header (lowercase normalized) |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | Raw request body |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | Form field |
| `ctx.res.json(data)` | `ctx::dispatch("res.json", data)` | Respond with JSON |
| `ctx.res.text(data)` | `ctx::dispatch("res.text", data)` | Respond with plain text |
| `ctx.res.html(data)` | `ctx::dispatch("res.html", data)` | Respond with HTML |
| `ctx.res.render(path)` | `ctx::dispatch("res.render", path)` | Render a static HTML file |
| `ctx.res.status(code)` | `ctx::dispatch("res.status", code)` | Set HTTP status code |
| `ctx.res.header(name, val)` | `ctx::dispatch("res.header", name, val)` | Set response header |
| `ctx.res.redirect(url[, code])` | `ctx::dispatch("res.redirect", url[, code])` | HTTP redirect |

### Router files

Split routes into namespaced files using gawk `@namespace`:

```awk
# routers/todos.awk
@namespace "todos_router"

function routes() {
  awk::GET("/todos",     "todos_router::index")
  awk::GET("/todos/:id", "todos_router::show")
}

function index() { ctx::json("[]") }

function show(id) {
  id = ctx::param("id")
  return ctx::json("{\"id\":\"" id "\"}")
}
```

```awk
# app.awk
@include "routers/todos.awk"

BEGIN {
  todos_router::routes()
  listen(8080)
}
```

## Environment (env::)

`env::` is a [Deno.env](https://deno.land/api?s=Deno.env)-style namespace for reading and writing environment variables at runtime.

```awk
env::get("KEY")          # returns ENVIRON["KEY"]; "" if unset
env::set("KEY", "val")   # ENVIRON["KEY"] = "val" (current process only)
env::del("KEY")          # delete ENVIRON["KEY"]
env::has("KEY")          # 1 if set, 0 if not
```

DSL-style (dot-notation) invocations are also supported:

```awk
env.get("KEY")          # returns ENVIRON["KEY"]; "" if unset
env.set("KEY", "val")   # ENVIRON["KEY"] = "val"
env.del("KEY")          # delete ENVIRON["KEY"]
env.has("KEY")          # 1 if set, 0 if not
```

Variables set or deleted via `env::set` / `env::del` are visible to subsequent `env::get` calls within the same gawk process, but are **not** propagated to child processes spawned via `system()` or pipes.

```awk
# Read port from environment, fall back to 8080
hawk.app.listen(env.get("PORT") ?? 8080)
```

## Plugins

Drop a plugin directory into `plugins/<name>/`. H-awk auto-discovers and loads plugins at startup.

```awk
# plugins/logger/manifest.awk
function plugin_logger_manifest(meta) {
  meta["name"]        = "logger"
  meta["version"]     = "0.1.0"
  meta["description"] = "Per-request stdout logger"
  meta["hooks"]       = "post_request"
}
```

```awk
# plugins/logger/logger.awk
function plugin_logger_post_request(req, res) {
  log_info(sprintf("%s %s %d", req["method"], req["path"], res["status"]))
}
```

### Plugin hooks

| Hook | Signature | Notes |
|---|---|---|
| `init` | `(meta)` | Called once at startup |
| `pre_request` | `(req, res)` | Before dispatch; return `1` to short-circuit |
| `post_request` | `(req, res)` | After response is sent |
| `shutdown` | `(meta)` | Called once at teardown |

Disable a plugin without removing it:

```sh
touch plugins/logger/.disabled
```

Plugins are distributed as standalone git repositories and added via `git submodule`:

```sh
git submodule add https://github.com/<owner>/hawk-plugin-csrf plugins/csrf
git submodule update --init plugins/csrf
```

## Native Extensions (libs)

Optional Zig-compiled gawk extensions unlock capabilities beyond what AWK can do natively.

| Lib | Description |
|---|---|
| `libs/net` | Zig TCP event loop — keep-alive, SO_REUSEPORT multi-worker |
| `libs/binary` | Binary-safe file I/O (PNG, JPG, WebP, fonts, etc.) |
| `libs/multipart` | `multipart/form-data` parser for file uploads |
| `libs/crypto` | SHA-256 / HMAC-SHA256 |
| `libs/gzip` | Gzip / deflate compression |
| `libs/url` | High-performance URL encode/decode |

H-awk runs without any libs. Missing libs degrade gracefully — e.g., the server falls back to gawk's `/inet/tcp/` transport if `libs/net` is absent.

### Multi-worker & Keep-Alive (`libs/net`)

When `libs/net` is built, `bin/hawk` spawns N independent gawk workers sharing the same port via `SO_REUSEPORT`. The OS kernel distributes incoming connections across workers. Each worker is supervised and auto-restarted on crash.

```sh
# CLI
./bin/hawk --workers 8 app.awk

# Make
make run WORKERS=8

# Environment
HAWK_WORKERS=8 ./bin/hawk app.awk
```

HTTP/1.1 keep-alive is enabled by default. Workers maintain idle connections and close them after a configurable timeout:

```sh
HAWK_KEEPALIVE_TIMEOUT=30 ./bin/hawk app.awk   # 30s idle timeout (default: 75)
```

| Variable | Default | Description |
|---|---|---|
| `HAWK_WORKERS` | `4` | Number of worker processes (requires `libs/net`) |
| `HAWK_KEEPALIVE_TIMEOUT` | `75` | Idle keep-alive timeout in seconds |

### Setup

```sh
# Build all libs (requires Zig 0.14+)
make build-libs

# Or fetch precompiled binaries (no Zig required)
HAWK_REPO=<owner>/<repo> make fetch-libs
```

Enabled libs are shown at startup:

```
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, binary]
```

## Testing

```sh
make test           # unit + dsl + e2e
make test-unit      # AWK assertions only (fast, no server)
make test-dsl       # DSL desugar fixture tests
make test-e2e       # server + curl integration tests
make test-libs      # Zig lib unit tests
make lint           # gawk --lint syntax check
make ci             # lint + all tests
```

## License

MIT
