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
  return ctx.res.html(html_raw(""))
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
# Typed let with initializer — static check at desugar time
function handler() {
  let n: Int = 42
  let title: Str = ctx.req.form("title")
}

# Desugared (coerce only when type can't be statically confirmed)
function handler(    n, title) {
  n     = 42
  title = ctx::dispatch("req.form", "title")
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

**Union type annotations**

```awk
# Union type: accepts any member type
function handler() {
  let port: Int | Str = env.get("PORT") ?? 8080
}

# Desugared
function handler(    port) {
  _ds_tc_1 = env::dispatch("get", "PORT")
  port = (_ds_tc_1 != "" ? _ds_tc_1 : 8080)
}
```

```sh
# Desugar-time error: Bool is not a member of Int | Str
let port: Int | Str = true
# dsl error: app.awk:3: type mismatch: cannot assign Bool to Int|Str
```

The `??` operator infers a union type from its two operands (`Str | Int` from `env.get("PORT") ?? 8080`). The built-in `Port` type alias expands to `Int|NumericStr|Str`, so `hawk.app.listen(env.get("PORT") ?? 8080)` passes type checking.

Supported types: `Int`, `Float`, `Str`, `Bool`, `NumericStr`, `Array`, `Map`, `Response`, `Option<T>`, `Result<T, E>`, `Untrusted<T>`, `HtmlEscapedStr`, `Void`, `Any`, and any union `A | B`. Type inference works for literals and known DSL functions — `ctx.req.form` → `Result<Untrusted<Str>, ParseError>`, `ctx.req.json` → `Result<Untrusted<Map>, ParseError>`, `ctx.res.text` → `Response`, `escape_html` → `HtmlEscapedStr`, `html_raw` → `HtmlEscapedStr`, etc.

`ctx.res.html` requires `HtmlEscapedStr|HtmlFragment` — pass the result of `escape_html(s)` for user-supplied strings, or `html_raw(s)` for pre-built trusted HTML. This prevents XSS by making HTML output a tracked brand type that cannot be forged by plain string assignment.

**Function type annotations**

```awk
# Argument and return type annotations (both optional)
function normalize(text: Str) -> Str {
  return text
}

function handler() -> Response {
  let result: Str = normalize(ctx.req.form("title"))
  return ctx.res.text(result)
}

# Desugared
function normalize(text) {
  return text
}

function handler(    result) {
  result = normalize(ctx::dispatch("req.form", "title"))
  return ctx::dispatch("res.text", result)
}
```

Annotations are stripped from gawk output — they exist only at desugar time. Unannotated parameters and return types default to `Any` (no check). Union types work in annotations:

```awk
function process(id: Int | Str) -> Str {
  return id
}
```

Desugar-time checks on user-defined functions:

```sh
# Wrong argument type
normalize(123)
# dsl error: app.awk:8: normalize argument 1 expects Str, got Int

# Wrong arity
normalize("a", "b")
# dsl error: app.awk:8: normalize expects 1 argument(s), got 2

# Wrong return type
function hello() -> Response {
  return "hello"
}
# dsl error: app.awk:2: function hello expects return Response, got Str

# Void with value
function setup() -> Void {
  return ctx.res.text("ok")
}
# dsl error: app.awk:2: function setup expects Void, got Response
```

**`??` null-coalescing operator**

```awk
# DSL
hawk.app.listen(env.get("PORT") ?? 8080)

# Desugared
_ds_tc_1 = env::dispatch("get", "PORT")
hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
```

Rule: `expr ?? default` — if `expr` evaluates to empty string, use `default`. Works inside function arguments.

**`|>` pipe operator**

```awk
# DSL
function handler() {
  let raw  ?= ctx.req.form("title")
  let safe  = raw |> strip()
}

# Desugared — temp var injected, inserted as first arg
function handler(    _ds_tc_1, raw, _ds_p_1, safe) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  raw = result_val(_ds_tc_1)
  _ds_p_1 = strip(raw)
  safe = _ds_p_1
}
```

Rule: `expr |> f(args)` → temp var for `expr`, then `f(tempvar, args)`. Chains left-to-right. LHS must be a plain identifier (use `let tmp = expr` first for complex expressions).

Sealed-pipe rule: `Result<T, E>` and `Option<T>` values cannot be piped directly — use `?=` or `match...of` to unwrap first.

**`match...of...end` expression**

```awk
# DSL
function handler() {
  match ctx.req.json() of
    ok body:
      return ctx.res.text(body["title"])
    ng err:
      return ctx.res.status(500)
  end
}

# Desugared
function handler(    _ds_mc_1, body, err) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.text", body["title"])
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
```

Branch keywords: `ok VAR:` / `ng VAR:` for `Result<T,E>`, `some VAR:` / `none:` for `Option<T>`, `default:` as catch-all. Missing `ng`/`none`/`default` is a desugar-time error.

**`classify:` annotation**

```awk
function strip(s: Str) -> Str {
  classify: transform
  return s
}
```

Marks a function's role in the dataflow:
- `transform` — accepts `Untrusted<T>` input; strips Untrusted wrapper from output
- `validator` — accepts `Untrusted<T>` input; output is plain `T` (checked, not sanitized)
- `sanitizer` — accepts `Untrusted<T>` input; produces a brand-safe output (e.g. `HtmlEscapedStr`)
- `sink` — terminal consumer (no output)

`classify:` lines are stripped from gawk output — annotation only.

**`?=` safe unwrap operator**

Unwrap an `Option<T>` or `Result<T, E>` value. If the call fails, automatically returns a 500 response. Only valid for functions whose return type is `Option` or `Result`.

```awk
# DSL
function create_todo() {
  let body ?= ctx.req.json()
}

# Desugared
function create_todo(    _ds_tc_1, body) {
  _ds_tc_1 = ctx::dispatch("req.json")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  body = result_val(_ds_tc_1)
}
```

Desugar-time error if the RHS type is not Option or Result:

```sh
let port ?= env.get("PORT")
# dsl error: app.awk:5: ?= requires Option or Result, got Str
```

**DSL function call checking**

Desugar validates arity and argument types for all built-in DSL functions and user-defined annotated functions:

```sh
# Wrong number of arguments
ctx.res.status()
# dsl error: app.awk:5: ctx.res.status expects 1 argument(s), got 0

# Wrong argument type
ctx.res.status("ok")
# dsl error: app.awk:5: ctx.res.status argument 1 expects Int, got Str
```

User-defined functions with type annotations are checked the same way. Forward references work — a function can be called before it is defined in the source file.

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
