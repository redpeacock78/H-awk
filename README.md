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

## CLI

```sh
./bin/hawk [serve] [--workers N] [--debug] <app.awk>
./bin/hawk emit    [--strict]             <app.awk>
./bin/hawk check   [--strict]             <app.awk>
./bin/hawk help
```

| Subcommand | Description |
|---|---|
| `serve` | Start HTTP server. Default when no subcommand is given — `hawk app.awk` and `hawk serve app.awk` are equivalent. |
| `emit` | Print the desugared AWK source to stdout and exit. Useful for inspecting what the DSL preprocessor produces. |
| `check` | Run the DSL preprocessor and exit without starting the server. Exits 0 on success, 1 on error. |
| `help` | Print usage summary. |

`--strict` runs the desugared output through `gawk --sandbox` for additional syntax validation. Available in `emit` and `check`.

## Routing

`bin/hawk` is a thin wrapper that dispatches to `libexec/hawk`. Desugaring happens in the subcommand (`serve`/`emit`/`check`) before gawk runs — write routes and handlers using dot-notation DSL, and gawk locals using `let`.

```awk
BEGIN {
  hawk.app.get("/todos",        "list_todos")
  hawk.app.post("/todos",       "add_todo")
  hawk.app.del("/todos/:id",    "delete_todo")
  hawk.app.listen(env.get("PORT") ?? 8080)
}

function list_todos() {
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  return ctx.res.json(sprintf("{\"count\":%d}", n))
}

function add_todo() {
  when ctx.req.form("title") of
    ok raw:
      if (raw == "") {
        ctx.res.status(400)
        return ctx.res.text("title required")
      }
      ctx.res.status(201)
      return ctx.res.html(safe.html.fragment(
        "<li>", safe.html.escape(raw), "</li>"
      ))
    ng:
      ctx.res.status(400)
      return ctx.res.text("title required")
  end
}

function delete_todo() -> Response {
  when ctx.req.param("id") of
    ok raw_id:
      delete_tsv("data/todos.tsv", "id", raw_id)
      ctx.res.status(200)
      return ctx.res.html(safe.html.raw(""))
    ng:
      ctx.res.status(400)
      return ctx.res.text("missing id")
  end
}
```

## DSL Preprocessing

`bin/hawk` runs every app file through `dsl/desugar.awk` before passing it to gawk. The following transforms are applied.

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
  let title = "hello"
  let items = []
  let tmp
  ...
}

# Desugared
function handler(    title, items, tmp) {
  title = "hello"
  delete items
  ...
}
```

`let` declarations are hoisted to the function signature as gawk locals (4-space convention). `let name = []` becomes `delete name`. Bare `let name` is hoisted only (line removed).

`let` is function-scoped, not block-scoped. A `let` inside `if`, `for`, or `while` is still hoisted to the function signature, so the variable remains visible after the block. In strict mode (`_DS_strict=1`), a warning is emitted when `let` appears inside a control-flow block.

**Type annotations on `let`**

```awk
# Typed let with initializer — static check at desugar time
function handler() {
  let n: Int = 42
}

# Desugared
function handler(    n) {
  n = 42
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
```

```sh
# Desugar-time error: Bool is not a member of Int | Str
let port: Int | Str = true
# dsl error: app.awk:3: type mismatch: cannot assign Bool to Int|Str
```

The `??` operator infers a union type from its two operands (`Str | Int` from `env.get("PORT") ?? 8080`). The built-in `Port` type alias expands to `Int|NumericStr|Str`, so `hawk.app.listen(env.get("PORT") ?? 8080)` passes type checking.

Supported types: `Int`, `Float`, `Str`, `Bool`, `NumericStr`, `Array`, `Map`, `Response`, `Option<T>`, `Result<T, E>`, `Untrusted<T>`, `HtmlEscapedStr`, `HtmlFragment`, `HtmlAttrEscapedStr`, `Void`, `Any`, and any union `A | B`. The `HtmlPart` alias expands to `HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr`. Type inference works for literals and known DSL functions.

**Function type annotations**

```awk
# Argument and return type annotations (both optional)
function normalize(text: Str) -> Str {
  return text
}

function handler() -> Response {
  let result: Str = normalize("hello")
  return ctx.res.text(result)
}

# Desugared
function normalize(text) {
  return text
}

function handler(    result) {
  result = normalize("hello")
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

**Safe HTML output (`safe.*`)**

`ctx.res.html()` requires `HtmlEscapedStr` or `HtmlFragment` — plain `Str` values are rejected at desugar time. This makes XSS a compile-time error rather than a runtime surprise.

Four sanitizers in the `safe.*` namespace produce these brand types:

| Function | Input | Output | Use |
|---|---|---|---|
| `safe.html.escape(s)` | `Str\|Untrusted<Str>` | `HtmlEscapedStr` | Escape user-supplied text for HTML body |
| `safe.attr.escape(s)` | `Str\|Untrusted<Str>` | `HtmlAttrEscapedStr` | Escape user-supplied text for HTML attributes |
| `safe.html.raw(s)` | `Str` | `HtmlFragment` | Trust assertion — use only for known-safe strings |
| `safe.html.fragment(parts...)` | `HtmlPart` args | `HtmlFragment` | Compose brand-typed HTML parts into a fragment |
| `safe.str.trust(s)` | `Untrusted<Str>` | `Str` | Explicit trust assertion — strips Untrusted wrapper without transformation |

`HtmlPart` is an alias for `HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr`. Literal string arguments to `safe.html.fragment` are also accepted as trusted static HTML.

```awk
function render_item(id: Str, title: Str) -> HtmlFragment {
  return safe.html.raw(sprintf(
    "<li id=\"item-%s\">%s</li>",
    safe.attr.escape(id),
    safe.html.escape(title)
  ))
}
```

Brand types cannot be forged by plain string assignment — only the `safe.*` sanitizers can produce them:

```sh
# Desugar-time error: plain Str cannot be passed to ctx.res.html
let html: Str = "<b>hello</b>"
return ctx.res.html(html)
# dsl error: app.awk:3: ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Str

# Desugar-time error: brand type cannot be created by annotation alone
let frag: HtmlFragment = user_input
# dsl error: app.awk:4: brand type HtmlFragment cannot be assigned Untrusted<Str>
```

**String interpolation (`#{...}`)**

Embed expressions inside strings with `#{expr}`. The desugar expands them to `sprintf` calls:

```awk
# DSL
let greeting: Str = "Hello, #{name}!"

# Desugared
greeting = sprintf("Hello, %s!", name)
```

Multiple expressions work in one string:

```awk
let msg: Str = "#{first} #{last} (#{age})"
# → sprintf("%s %s (%s)", first, last, age)
```

If any embedded expression is `Untrusted<T>`, the resulting variable is inferred as `Untrusted<Str>`:

```awk
when ctx.req.form("name") of
  ok raw_name:
    let greeting: Str = "Hello, #{raw_name}!"
    # → greeting is Untrusted<Str> because raw_name is Untrusted<Str>
  ng:
    return ctx.res.status(400)
end
```

Interpolation also works inside `safe.html.fragment(...)` calls. Literal text between `#{...}` markers is treated as trusted static HTML; embedded expressions are type-checked as `HtmlPart`:

```awk
when ctx.req.form("title") of
  ok raw_title:
    return ctx.res.html(safe.html.fragment(
      "<li class=\"item\">#{safe.html.escape(raw_title)}</li>"
    ))
  ng:
    return ctx.res.status(400)
end
```

**Regular expression literals**

Regular expression literals must stay on a single source line. The DSL parser does not support regex literals that span multiple lines.

**`??` null-coalescing operator**

```awk
# DSL
hawk.app.listen(env.get("PORT") ?? 8080)

# Desugared
_ds_tc_1 = env::dispatch("get", "PORT")
hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
```

Rule: `expr ?? default` — if `expr` evaluates to empty string, use `default`. Works inside function arguments.

Because AWK represents missing values as empty strings, `??` treats both null-like missing values and the empty string as falsy.

**`|>` pipe operator**

```awk
# DSL
function handler() {
  when ctx.req.form("title") of
    ok raw:
      let safe = raw |> strip()
      return ctx.res.text(safe)
    ng:
      return ctx.res.status(400)
  end
}

# Desugared — temp var injected, inserted as first arg
function handler(    _ds_mc_1, raw, _ds_p_1, safe) {
  _ds_mc_1 = ctx::dispatch("req.form", "title")
  if (result_ok(_ds_mc_1)) {
    raw = result_val(_ds_mc_1)
    _ds_p_1 = strip(raw)
    safe = _ds_p_1
    return ctx::dispatch("res.text", safe)
  } else {
    return ctx::dispatch("res.status", 400)
  }
}
```

Rule: `expr |> f(args)` → temp var for `expr`, then `f(tempvar, args)`. Chains left-to-right. LHS must be a plain identifier (use `let tmp = expr` first for complex expressions).

Sealed-pipe rule: `Result<T, E>` and `Option<T>` values cannot be piped directly — use `?=` or `when...of` to unwrap first.

Dot-notation functions work as pipe RHS:

```awk
let escaped = raw_title |> safe.html.escape()
# → _ds_p_1 = safe::dispatch("html.escape", raw_title)
```

**`when...of...end` expression**

Pattern-match on `Result<T, E>` and `Option<T>` values. Desugars to an if/else chain.

```awk
# DSL
function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng err:
      return ctx.res.status(500)
  end
}

# Desugared
function handler(    _ds_mc_1, body, err) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", body)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
```

**All arm forms:**

```
when EXPR of
  # Result<T, E> arms
  ok name:           # ok — bind value to name
  ok:                # ok — no bind
  ng e<TypeName>:    # ng — typed, bind error to e (dispatch by type)
  ng <TypeName>:     # ng — typed, no bind
  ng name:           # ng — untyped, bind error to name
  ng:                # ng — untyped, no bind
  default name:      # catch-all, bind to name
  default:           # catch-all, no bind

  # Option<T> arms
  some name:         # some — bind value to name
  some:              # some — no bind
  none:              # none — no bind (treated as catch-all for Option)
end
```

**Multiple typed `ng` arms** — dispatch by error type at runtime:

```awk
type AuthError    = Error
type NotFoundError = Error

function handler() {
  when fetch_user(id) of
    ok user:
      return ctx.res.json(user)
    ng e<AuthError>:
      return ctx.res.status(401)
    ng e<NotFoundError>:
      return ctx.res.status(404)
    default:
      return ctx.res.status(500)
  end
}

# Desugared
function handler(    _ds_mc_1, user, e) {
  _ds_mc_1 = fetch_user(id)
  if (result_ok(_ds_mc_1)) {
    user = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", user)
  } else if (result_err_type(_ds_mc_1) == "AuthError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 401)
  } else if (result_err_type(_ds_mc_1) == "NotFoundError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 404)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
```

**`some`/`none` arms for `Option<T>`:**

```awk
# DSL
function handler() {
  when find_title(id) of
    some title:
      return ctx.res.text(title)
    none:
      return ctx.res.status(404)
  end
}

# Desugared
function handler(    _ds_mc_1, title) {
  _ds_mc_1 = find_title(id)
  if (option_some(_ds_mc_1)) {
    title = option_val(_ds_mc_1)
    return ctx::dispatch("res.text", title)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
```

Missing `ng`/`none`/`default` is a desugar-time error.

**Exhaustiveness check for union error types:** When a function is annotated `-> Result<T, E1 | E2>`, typed `ng` arms must cover every union member, or a `default:`/`ng:` catch-all arm must be present:

```sh
# Desugar-time error: NotFoundError arm is missing
function handler() {
  when fetch_user(id) of
    ok user:
      return ctx.res.json(user)
    ng e<AuthError>:
      return ctx.res.status(401)
  end
}
# dsl error: app.awk:9: when...of missing arm for NotFoundError (add 'ng e<NotFoundError>:' or 'default:')
```

**`type` declarations**

Define custom error types and use them in `ng` arms:

```awk
# DSL
type AuthError    = Error
type NotFoundError = Error

# Desugared
function AuthError(msg)     { return result_ng("AuthError", msg) }
function NotFoundError(msg) { return result_ng("NotFoundError", msg) }
```

Use in functions:

```awk
function fetch_user(id) -> Result<Str, AuthError | NotFoundError> {
  if (!authenticated()) return AuthError("token expired")
  if (!found(id))       return NotFoundError("user " id)
  return result_ok_make(id)
}
```

**Union and Intersection type aliases**

Define type aliases with `|` (Union) or `&` (Intersection):

```awk
type Status   = Int | Str          # Status accepts Int or Str
type Config   = Str | Int | Bool   # multi-member union
type Precise  = Int & Str          # Precise requires both Int and Str
```

Each generates a validator function and registers a type alias:
```awk
# Desugared
function Status(val) { if (type::accepts("Int|Str", val)) return val; return result_ng("TypeError:Status", "expected Int|Str, got " val) }
```

Use in function signatures:
```awk
function parse(raw: Str) -> Int | Str {
  return 42
}
```

Use as let annotation:
```awk
function handler() {
  let port: Int | Str = env.get("PORT")
}
```

**ADT encoding**

`Result` and `Option` values are encoded as strings using ASCII Unit Separator (`\x1F`, U+001F):

| State | Encoding |
|---|---|
| `ok(val)` | `"ok\x1F" val` |
| `ng(TypeName)` | `"ng\x1F" TypeName` |
| `ng(TypeName, msg)` | `"ng\x1F" TypeName "\x1F" msg` |
| `some(val)` | `"some\x1F" val` |
| `none` | `"none\x1F"` |

The sentinel prefix means an `Option<Str>` holding an empty string is still distinguishable from `none`.

Runtime helpers (defined in `dsl/adt.awk`, always available):

```awk
result_ok(v)              # → 1 if v is ok
result_val(v)             # → inner value of ok
result_ok_make(val)       # → ok-encoded string
result_ng(type, msg)      # → ng-encoded string
result_err_type(v)        # → TypeName of ng value
result_err(v)             # → "TypeName" or "TypeName\x1Fmsg"

option_some(v)            # → 1 if some
option_none(v)            # → 1 if none
option_val(v)             # → inner value of some
option_some_make(val)     # → some-encoded string
option_none_make()        # → none-encoded string
```

**`option.some` / `option.none` construction**

Build `Option<T>` values in DSL code using the `option.*` namespace:

```awk
# DSL
function find_title(id: Str) -> Option<Str> {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}

# Desugared
function find_title(id) {
  if (!(id in rows)) {
    return option_none_make()
  }
  return option_some_make(rows[id])
}
```

`option.some(val)` infers its return type as `Option<T>` from the type of `val` — no explicit annotation needed. `option.none()` returns `Option<Any>`, which is compatible with any `Option<T>` annotation.

**`?=` safe unwrap operator**

Unwrap a `Result<T, E>` or `Option<T>` value in one step. On failure the handler returns early with an error status — 500 for `Result` (`ng`) and 404 for `Option` (`none`). Only valid when the RHS type is `Option` or `Result`.

```awk
# DSL — Result<T, E> (returns 500 on ng)
function create_todo() {
  let body ?= ctx.req.json()
  # body is now the unwrapped Untrusted<Map> value
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

```awk
# DSL — Option<T> (returns 404 on none)
function handler() {
  let title ?= find_title(id)
  return ctx.res.text(title)
}

# Desugared
function handler(    _ds_tc_1, title) {
  _ds_tc_1 = find_title(id)
  if (!option_some(_ds_tc_1)) {
    return ctx::dispatch("res.status", 404)
  }
  title = option_val(_ds_tc_1)
  return ctx::dispatch("res.text", title)
}
```

Desugar-time error if the RHS type is not `Option` or `Result`:

```sh
let port ?= env.get("PORT")
# dsl error: app.awk:5: ?= requires Option or Result, got Str
```

After `?=` unwrap, the variable holds `Untrusted<T>` — pass it to a `safe.*` sanitizer before using in HTML output.

**`Effect<T>` type annotation**

`Effect<T>` is a type-level wrapper for functions that will eventually be asynchronous (e.g., cache lookups, database queries). Annotating a function `-> Effect<Option<Str>>` or `-> Effect<Result<T, E>>` signals intent without requiring any change at the call site — `?=` and `when...of` strip the `Effect` wrapper automatically before performing their usual `Option`/`Result` handling.

```awk
# DSL
function get_cached(key: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  let val ?= get_cached("foo")   # Effect<Option<Str>> → Option<Str> → unwrap
  return ctx.res.text(val)
}
```

```awk
# DSL — when...of also strips Effect
function get_item(id: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  when get_item(id) of
    some val:
      return ctx.res.text(val)
    none:
      return ctx.res.status(404)
  end
}
```

At runtime, AWK is synchronous — `Effect` is a pass-through with no overhead. The annotation exists so that when async execution is added in the future, call sites need no changes.

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
./bin/hawk serve --debug app.awk   # prints temp file path to stderr
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

Request helpers return `Result<Untrusted<Str>, ParseError>` — use `when...of` or `?=` to unwrap.

| DSL | Desugared | Return type |
|---|---|---|
| `ctx.req.query(key)` | `ctx::dispatch("req.query", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.param(key)` | `ctx::dispatch("req.param", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.header(key)` | `ctx::dispatch("req.header", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.body()` | `ctx::dispatch("req.body")` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.form(key)` | `ctx::dispatch("req.form", key)` | `Result<Untrusted<Str>, ParseError>` |
| `ctx.req.json()` | `ctx::dispatch("req.json")` | `Result<Untrusted<Map>, ParseError>` |
| `ctx.res.json(data)` | `ctx::dispatch("res.json", data)` | `Response` |
| `ctx.res.text(data)` | `ctx::dispatch("res.text", data)` | `Response` |
| `ctx.res.html(data)` | `ctx::dispatch("res.html", data)` | `Response` (`HtmlEscapedStr\|HtmlFragment` required) |
| `ctx.res.render(path)` | `ctx::dispatch("res.render", path)` | `Response` |
| `ctx.res.status(code)` | `ctx::dispatch("res.status", code)` | `Response` |
| `ctx.res.header(name, val)` | `ctx::dispatch("res.header", name, val)` | `Response` |
| `ctx.res.redirect(url)` | `ctx::dispatch("res.redirect", url)` | `Response` |

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

function show() {
  when ctx::param("id") of
    ok id:
      return ctx::json("{\"id\":\"" result_val(id) "\"}")
    ng:
      return ctx::status(400)
  end
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
./bin/hawk serve --workers 8 app.awk

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
