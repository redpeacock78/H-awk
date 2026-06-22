🌐 [English](../routing.md) | [← README に戻る](../../README.ja.md)

# ルーティング

`bin/hawk` は `libexec/hawk` にディスパッチする薄いラッパーです。デシュガーリングはgawkが実行される前のサブコマンド（`serve`/`emit`/`check`）で発生します。ドット記法DSLを使ってルートとハンドラーを記述し、`let`を使ってgawkローカル変数を定義します。

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

> **注記:** TSVヘルパーは `mkdir` ベースのロックと `PROCINFO["pid"]`、`systime()`、`rand()` を含む一意の一時パスを使用しているため、`append_tsv`、`delete_tsv`、`update_tsv` はマルチワーカーモードで安全です。
> 高スループットの本番環境では、libSQL、SQLite、PostgreSQLなどの外部ストアを使用してください。

## ルーターファイル

gawk の `@namespace` を使ってルートを名前空間付きファイルに分割します。

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

*ルーティングメソッドの完全なリファレンスについては、[API リファレンス](api.ja.md)を参照してください。*
