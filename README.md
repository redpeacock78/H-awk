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

### Classic style

Handlers receive `req` and `res` arrays directly.

```awk
BEGIN {
  GET("/users/:id", "show_user")
  POST("/todos",    "add_todo")
}

function show_user(req, res) {
  text(res, "user=" req["params:id"])
}

function add_todo(req, res,    row) {
  delete row
  row["id"]    = systime()
  row["title"] = req["form:title"]
  append_tsv("data/todos.tsv", row)
  status(res, 201)
  json(res, "{\"ok\":true}")
}
```

### Context style (v0.4+)

Use `ctx::` helpers instead of `req`/`res` arguments. Call `listen(port)` explicitly from `BEGIN`.

```awk
BEGIN {
  GET("/todos",        "list_todos")
  POST("/todos",       "add_todo")
  DELETE("/todos/:id", "delete_todo")
  listen(8080)
}

function list_todos(    n, rows) {
  delete rows
  n = read_tsv("data/todos.tsv", rows)
  ctx::json(sprintf("[%d items]", n))
}

function add_todo(    title) {
  title = ctx::req["form:title"]
  if (title == "") { ctx::status(400); ctx::text("title required"); return }
  ctx::status(201)
  ctx::text("added: " title)
}

function delete_todo() {
  delete_tsv("data/todos.tsv", "id", ctx::param("id"))
  ctx::status(200)
  ctx::html("")
}
```

#### Context API reference

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

function show(    id) {
  id = ctx::param("id")
  ctx::json("{\"id\":\"" id "\"}")
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

Both old-style and ctx-style handlers can coexist in the same application.

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
