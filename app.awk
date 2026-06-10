# SPDX-License-Identifier: MIT
# app.awk -- H-awk todo demo (ctx:: style)
#
# Routes:
#   GET    /              landing page (static shell)
#   GET    /todos         todo list HTML fragment (HTMX)
#   POST   /todos         add todo, return new <li> (HTMX)
#   DELETE /todos/:id     delete todo, return empty (HTMX outerHTML swap)
#   GET    /todos.json    JSON API

BEGIN {
  GET("/",             "todo_index")
  GET("/todos",        "todo_list_html")
  POST("/todos",       "todo_add")
  DELETE("/todos/:id", "todo_delete")
  GET("/todos.json",   "todo_list_json")
  listen(8080)
}

function todo_index() {
  ctx::render("views/index.html")
}

function todo_list_html(_r, _s,    rows, n, i, out) {
  delete rows
  n = read_tsv("data/todos.tsv", rows)
  out = ""
  for (i = 1; i <= n; i++) {
    out = out _todo_li(rows[i, "id"], rows[i, "title"])
  }
  ctx::html(out)
}

function todo_add(_r, _s,    title, row) {
  title = ctx::req["form:title"]
  if (title == "") title = ctx::query("title")
  if (title == "") {
    ctx::status(400)
    ctx::text("title required")
    return
  }
  delete row
  row["id"]    = systime() "_" int(rand() * 100000)
  row["title"] = title
  append_tsv("data/todos.tsv", row)
  ctx::status(201)
  ctx::html(_todo_li(row["id"], row["title"]))
}

function todo_delete(_r, _s,    deleted) {
  deleted = delete_tsv("data/todos.tsv", "id", ctx::param("id"))
  if (deleted == 0) {
    ctx::status(404)
    ctx::text("not found")
    return
  }
  ctx::status(200)
  ctx::html("")
}

function todo_list_json(_r, _s,    rows, n, i, item, items_json) {
  delete rows
  n = read_tsv("data/todos.tsv", rows)
  items_json = ""
  for (i = 1; i <= n; i++) {
    delete item
    item["id"]    = rows[i, "id"]
    item["title"] = rows[i, "title"]
    items_json = items_json (i > 1 ? "," : "") json_encode(item)
  }
  ctx::set_header("Content-Type", "application/json; charset=utf-8")
  ctx::res["body"] = sprintf("{\"count\":%d,\"items\":[%s]}", n, items_json)
}

function _todo_li(id, title) {
  return sprintf( \
    "<li class=\"flex items-center justify-between py-3 border-b border-zinc-800/60 last:border-0 group\">" \
      "<span class=\"text-sm text-zinc-200\">%s</span>" \
      "<button" \
        " hx-delete=\"/todos/%s\"" \
        " hx-target=\"closest li\"" \
        " hx-swap=\"outerHTML\"" \
        " class=\"text-zinc-600 hover:text-red-400 text-base leading-none" \
          " opacity-0 group-hover:opacity-100 transition-all duration-150 cursor-pointer\"" \
      ">&#x2715;</button>" \
    "</li>", \
    title, id)
}
