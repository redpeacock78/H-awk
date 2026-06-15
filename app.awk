# SPDX-License-Identifier: MIT
# app.awk -- H-awk todo demo (DSL style)
#
# Routes:
#   GET    /              landing page (static shell)
#   GET    /todos         todo list HTML fragment (HTMX) — <tr> rows
#   POST   /todos         add todo, return new <tr> (HTMX)
#   DELETE /todos/:id     delete todo, return empty (HTMX outerHTML swap)
#   GET    /todos.json    JSON API

BEGIN {
  hawk.app.get("/",           "todo_index")
  hawk.app.get("/todos",      "todo_list_html")
  hawk.app.post("/todos",     "todo_add")
  hawk.app.del("/todos/:id",  "todo_delete")
  hawk.app.get("/todos.json", "todo_list_json")
  hawk.app.listen(env.get("PORT") ?? 8080)
}

function todo_index() -> Response {
  ctx.res.render("views/index.html")
}

function todo_list_html() -> Response {
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let out: Str = ""
  let i: Int
  for (i = 1; i <= n; i++) {
    out = out _todo_tr(rows[i, "id"], rows[i, "title"])
  }
  return ctx.res.html(safe.html.raw(out))
}

function todo_add() -> Response {
  let raw_title ?= ctx.req.form("title")
  let title: Str = result_val(raw_title)
  let row = []
  if (title == "") {
    let raw_q ?= ctx.req.query("title")
    title = result_val(raw_q)
  }
  if (title == "") {
    ctx.res.status(400)
    return ctx.res.text("title required")
  }
  row["id"]    = systime() "_" int(rand() * 100000)
  row["title"] = title
  append_tsv("data/todos.tsv", row)
  ctx.res.status(201)
  return ctx.res.html(_todo_tr(row["id"], row["title"]))
}

function todo_delete() -> Response {
  let raw_id ?= ctx.req.param("id")
  let deleted: Int = delete_tsv("data/todos.tsv", "id", result_val(raw_id))
  if (deleted == 0) {
    ctx.res.status(404)
    return ctx.res.text("not found")
  }
  ctx.res.status(200)
  return ctx.res.html(safe.html.raw(""))
}

function todo_list_json() -> Response {
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let item = []
  let items_json: Str = ""
  let i: Int
  for (i = 1; i <= n; i++) {
    item["id"]    = rows[i, "id"]
    item["title"] = rows[i, "title"]
    items_json = items_json (i > 1 ? "," : "") json_encode(item)
  }
  return ctx.res.json(sprintf("{\"count\":%d,\"items\":[%s]}", n, items_json))
}

function _todo_tr(id: Str, title: Str) -> HtmlFragment {
  return safe.html.raw(sprintf( \
    "<tr class=\"group border-b border-zinc-800/60 last:border-0\">" \
      "<td class=\"py-3 pr-4 text-sm text-zinc-200\">%s</td>" \
      "<td class=\"py-3 text-right\">" \
        "<button" \
          " hx-delete=\"/todos/%s\"" \
          " hx-target=\"closest tr\"" \
          " hx-swap=\"outerHTML\"" \
          " class=\"text-zinc-600 hover:text-red-400 text-base leading-none" \
            " opacity-0 group-hover:opacity-100 transition-all duration-150 cursor-pointer\"" \
        ">&#x2715;</button>" \
      "</td>" \
    "</tr>", \
    safe.html.escape(title), safe.attr.escape(id)))
}
