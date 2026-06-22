🌐 [日本語](routing.ja.md) | [← Back to README](../README.md)

# Routing

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
  let payload = []
  payload["count"] = n
  return ctx.res.json(payload)
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

> **Note:** TSV helpers use `mkdir`-based locks and unique tmp paths containing `PROCINFO["pid"]`, `systime()`, and `rand()`, so `append_tsv`, `delete_tsv`, and `update_tsv` are safe under multi-worker mode.
> For high-throughput production use, prefer an external store such as libSQL, SQLite, or PostgreSQL.

## Router files

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

---

*For the full routing method reference, see [API Reference](api.md).*
