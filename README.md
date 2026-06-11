# H-awk

> Express-style HTTP server for GNU AWK. Write backends in plain AWK.

H-awk is a lightweight HTTP framework built on top of `gawk`. Define routes, handle requests, and build APIs with a familiar Express-like API — no Node, no Python, no compiled binaries required.

## Requirements

- gawk 5.0+ (`gawk --version`)
- POSIX sh + GNU make
- Zig 0.14+ (only for `make build-libs`)
- curl (e2e tests only)

Tested on gawk 5.3.1 / macOS. Linux works. Windows via WSL only.

## Quickstart

```sh
cp .env.example .env

# Optional: build native extensions (binary I/O, TCP transport, etc.)
make build-libs

# Start the server (default :8080)
./bin/hawk app.awk
```

```sh
curl http://localhost:8080/
curl -X POST -d 'title=buy+milk' http://localhost:8080/todos
curl -X DELETE http://localhost:8080/todos/1234
curl http://localhost:8080/todos.json
```

`make help` lists all available targets.

## Routing

Use `ctx::` helpers to read requests and write responses. All declared function parameters are true local variables — no `req`/`res` noise. Call `listen(port)` from `BEGIN`.

```awk
BEGIN {
  GET("/todos",        "list_todos")
  POST("/todos",       "add_todo")
  DELETE("/todos/:id", "delete_todo")
  listen(8080)
}

function list_todos(n, rows) {
  delete rows
  n = read_tsv("data/todos.tsv", rows)
  return ctx::json(sprintf("[%d items]", n))
}

function add_todo(title) {
  title = ctx::req["form:title"]
  if (title == "") {
    ctx::status(400)
    return ctx::text("title required")
  }
  ctx::status(201)
  return ctx::text("added: " title)
}

function delete_todo() {
  delete_tsv("data/todos.tsv", "id", ctx::param("id"))
  ctx::status(200)
  return ctx::html("")
}
```

## App API (hawk::)

`hawk::` is the primary routing interface. `GET`/`POST`/... are backward-compatible aliases.

### Method shortcuts

```awk
hawk::get(path, handler)
hawk::post(path, handler)
hawk::put(path, handler)
hawk::del(path, handler)    # hawk::delete is a gawk reserved keyword
hawk::patch(path, handler)
hawk::head(path, handler)
hawk::listen(port)
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

### Backward-compatible aliases

```awk
GET(path, handler)     # → hawk::get
POST(path, handler)    # → hawk::post
PUT(path, handler)     # → hawk::put
DELETE(path, handler)  # → hawk::del
PATCH(path, handler)   # → hawk::patch
HEAD(path, handler)    # → hawk::head
listen(port)           # unchanged
```

### Context API reference

| Function | Description |
|---|---|
| `ctx::query(key)` | URL query parameter |
| `ctx::param(key)` | Path parameter (`:id`) |
| `ctx::get_header(key)` | Request header (lowercase normalized) |
| `ctx::body()` | Raw request body |
| `ctx::req["form:KEY"]` | Form field |
| `ctx::json(data)` | Respond with JSON |
| `ctx::text(data)` | Respond with plain text |
| `ctx::html(data)` | Respond with HTML |
| `ctx::render(path)` | Render a static HTML file |
| `ctx::status(code)` | Set HTTP status code |
| `ctx::set_header(name, val)` | Set response header |
| `ctx::redirect(url[, code])` | HTTP redirect |

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
| `libs/net` | Zig TCP event loop for higher-concurrency HTTP |
| `libs/binary` | Binary-safe file I/O (PNG, JPG, WebP, fonts, etc.) |
| `libs/multipart` | `multipart/form-data` parser for file uploads |
| `libs/crypto` | SHA-256 / HMAC-SHA256 |
| `libs/gzip` | Gzip / deflate compression |
| `libs/url` | High-performance URL encode/decode |

H-awk runs without any libs. Missing libs degrade gracefully — e.g., the server falls back to gawk's `/inet/tcp/` transport if `libs/net` is absent.

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
make test           # unit + e2e
make test-unit      # AWK assertions only (fast, no server)
make test-e2e       # server + curl integration tests
make test-libs      # Zig lib unit tests
make lint           # gawk --lint syntax check
make ci             # lint + all tests
```

## License

MIT
