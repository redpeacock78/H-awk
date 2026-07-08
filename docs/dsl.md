🌐 [日本語](ja/dsl.ja.md) | [← Back to README](../README.md)

# DSL Preprocessing

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
# Bare typed declaration — hoist only, typed assignment auto-coerced.
# The RHS type must be statically unknown (e.g. an unannotated parameter)
# for coercion to apply; a literal like "42" is already known to be
# NumericStr and is rejected outright by the static check below.
function handler(v) {
  let n: Int
  n = v
}

# Desugared
function handler(v,    n) {
  n = type::coerce(v, "Int")
}
```

Static type checking at desugar time — mismatched types produce an error:

```sh
# Desugar-time error: string literal assigned to Int
let port: Int = "hello"
# app.awk:5:1: error: type mismatch: cannot assign Str to Int
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
# app.awk:3:1: error: type mismatch: cannot assign Bool to Int|Str
```

The `??` operator infers a union type from its two operands (`Str | Int` from `env.get("PORT") ?? 8080`). The built-in `Port` type alias expands to `Int|NumericStr|Str`, so `hawk.app.listen(env.get("PORT") ?? 8080)` passes type checking.

Supported types: `Int`, `Float`, `Str`, `Bool`, `NumericStr`, `Array`, `Map`, `Response`, `Option<T>`, `Result<T, E>`, `Untrusted<T>`, `HtmlEscapedStr`, `HtmlFragment`, `HtmlAttrEscapedStr`, `Void`, `Any`, and any union `A | B`. The `HtmlPart` alias expands to `HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr`. Type inference works for literals and known DSL functions.

**Collection and Record types**

`List<T>` is a typed JSON array:

```awk
let todos: List<Todo> = []
todos.push(todo)
return ctx.res.json(todos)  # -> JSON array
```

Only numeric indices are allowed. String keys are a type error. Passing `List<T>` to `ctx.res.json` produces a JSON array.

`Dict<K, V>` is a typed JSON object:

```awk
let users: Dict<Str, User> = {}
users["alice"] = user
return ctx.res.json(users)  # -> JSON object
```

Only `K = Str` is officially supported for now.

Record types define fixed object fields:

```awk
type Todo = {
  id: Str
  title: Str
  done: Bool
}

let todo: Todo = {
  id: "1"
  title: "buy milk"
  done: false
}
```

Assignment to undefined fields is a type error (both `todo.field = ...` and `todo["field"] = ...` forms). Passing a Record to `ctx.res.json` produces a JSON object.

Current support scope: a record type may be used as a `let` binding or a function **parameter** annotation. It **cannot** be used as a function **return type** annotation (record values are gawk arrays, and gawk does not allow arrays to be returned from functions — this is rejected at desugar time). Reading a record field back out with dot notation (`todo.id`) is not supported; read fields with bracket notation (`todo["id"]`) instead.

| DSL type | JSON |
|---|---|
| Str | string |
| Int | number |
| Float | number |
| Bool | boolean |
| Null | null |
| List<T> | array |
| Dict<Str, V> | object |
| Record | object |
| Option<T> | T or null |

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
# app.awk:8:1: error: normalize argument 1 expects Str, got Int

# Wrong arity
normalize("a", "b")
# app.awk:8:1: error: normalize expects 1 argument(s), got 2

# Wrong return type
function hello() -> Response {
  return "hello"
}
# app.awk:2:1: error: function hello expects return Response, got Str

# Void with value
function setup() -> Void {
  return ctx.res.text("ok")
}
# app.awk:2:1: error: function setup expects Void, got Response
```

**Safe HTML output (`safe.*`)**

`ctx.res.html()` requires `HtmlEscapedStr` or `HtmlFragment` — plain `Str` values are rejected at desugar time. This makes XSS a compile-time error rather than a runtime surprise.

Four sanitizers in the `safe.*` namespace produce these brand types:

| Function | Input | Output | Use |
|---|---|---|---|
| `safe.html.escape(s)` | `Str\|Untrusted<Str>` | `HtmlEscapedStr` | Escape user-supplied text for HTML body |
| `safe.attr.escape(s)` | `Str\|Untrusted<Str>` | `HtmlAttrEscapedStr` | Escape user-supplied text for HTML attributes |
| `safe.html.raw(s)` | `Str` | `HtmlFragment` | Trust assertion — use only for known-safe strings |
| `safe.html.fragment(parts...)` | `HtmlPart` args | `HtmlFragment` | Compose brand-typed HTML parts into a fragment; supports variadic calls, including 4+ parts |
| `safe.str.trust(s)` | `Untrusted<Str>` | `Str` | Explicit trust assertion — strips Untrusted wrapper without transformation |

`HtmlPart` is an alias for `HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr`. Literal string arguments to `safe.html.fragment` are also accepted as trusted static HTML. Calls with four or more parts are lowered through the variadic fragment helper.

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
# app.awk:3:1: error: ctx.res.html argument 1 expects HtmlEscapedStr|HtmlFragment, got Str

# Desugar-time error: brand type cannot be created by annotation alone
let frag: HtmlFragment = user_input
# app.awk:4:1: error: brand type HtmlFragment cannot be assigned Untrusted<Str>
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
    let greeting: Untrusted<Str> = "Hello, #{raw_name}!"
    # → greeting is Untrusted<Str> because raw_name is Untrusted<Str>.
    # A plain `Str` annotation here is rejected — the value is still
    # untrusted and must be passed through a `safe.*` sanitizer first.
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
# app.awk:9:1: error: when...of missing arm for NotFoundError (add 'ng e<NotFoundError>:' or 'default:')
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

Unwrap a `Result<T, E>` or `Option<T>` value in one step. On failure the handler returns early with an error status. `Option` `none` returns 404. `Result` `ng` maps error types to HTTP status codes: `ParseError` → 400, `AuthError` → 401, `NotFoundError` → 404, and all other errors → 500. Only valid when the RHS type is `Option` or `Result`.

```awk
# DSL — Result<T, E> (returns by error type on ng)
function create_todo() {
  let body ?= ctx.req.json()
  # body is now the unwrapped Untrusted<Str> value
}

# Desugared
function create_todo(    _ds_tc_1, body) {
  _ds_tc_1 = ctx::dispatch("req.json")
  if (!result_ok(_ds_tc_1)) {
    _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
    if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
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
# app.awk:5:1: error: ?= requires Option or Result, got Str
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
- `transform` — accepts `Untrusted<T>` input; propagates `Untrusted` to the output when the input is untrusted
- `validator` — accepts `Untrusted<T>` input; removes the `Untrusted` wrapper and returns plain `T` (checked, not sanitized)
- `sanitizer` — accepts `Untrusted<T>` input; produces a brand-safe output (e.g. `HtmlEscapedStr`)
- `sink` — terminal consumer (no output)

In other words, `classify: validator` turns a validated `Untrusted<T>` result into plain `T`; it does not produce an HTML-safe brand.

`classify:` lines are stripped from gawk output — annotation only.

**DSL function call checking**

Desugar validates arity and argument types for all built-in DSL functions and user-defined annotated functions:

```sh
# Wrong number of arguments
ctx.res.status()
# app.awk:5:1: error: ctx.res.status expects 1 argument(s), got 0

# Wrong argument type
ctx.res.status("ok")
# app.awk:5:1: error: ctx.res.status argument 1 expects Int, got Str
```

User-defined functions with type annotations are checked the same way. Forward references work — a function can be called before it is defined in the source file.

Use `--debug` to inspect the generated file:

```sh
./bin/hawk serve --debug app.awk   # prints temp file path to stderr
```
