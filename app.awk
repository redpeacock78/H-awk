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
  when cache.get("todos:html") of
    ok r:
      when r of
        some v:
          return ctx.res.html(safe.html.raw(v))
        none:
          # fall through to rebuild
      end
    ng _:
      # fall through to rebuild on cache error
  end
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let out: Str = ""
  let i: Int
  for (i = 1; i <= n; i++) {
    out = out _todo_tr(rows[i, "id"], rows[i, "title"])
  }
  when cache.set("todos:html", out, 30) of
    ok _:
      # noop
    ng _:
      # noop on cache error
  end
  return ctx.res.html(safe.html.raw(out))
}

function todo_add() -> Response {
  let raw_title = ctx.req.form("title")
  when raw_title of
    ok raw:
      if (raw == "") {
        let raw_q ?= ctx.req.query("title")
        raw = raw_q
      }
      if (raw == "") {
        ctx.res.status(400)
        return ctx.res.text("title required")
      }
      let row: Dict<Str, Str> = {}
      row["id"] = "#{systime()}_#{int(rand() * 100000)}"
      row["title"] = safe.str.trust(raw)
      append_tsv("data/todos.tsv", row)
      when cache.del("todos:html") of
        ok _:
          # noop
        ng _:
          return ctx.res.status(500)
      end
      when cache.del("todos:json") of
        ok _:
          # noop
        ng _:
          return ctx.res.status(500)
      end
      ctx.res.status(201)
      return ctx.res.html(_todo_tr(row["id"], row["title"]))
    ng err:
      ctx.res.status(400)
      return ctx.res.text("bad request")
  end
}

function todo_delete() -> Response {
  let raw_id ?= ctx.req.param("id")
  let deleted: Int = delete_tsv("data/todos.tsv", "id", raw_id)
  if (deleted == 0) {
    ctx.res.status(404)
    return ctx.res.text("not found")
  }
  when cache.del("todos:html") of
    ok _:
      # noop
    ng _:
      return ctx.res.status(500)
  end
  when cache.del("todos:json") of
    ok _:
      # noop
    ng _:
      return ctx.res.status(500)
  end
  ctx.res.status(200)
  return ctx.res.html(safe.html.raw(""))
}

function todo_list_json() -> Response {
  when cache.get("todos:json") of
    ok r:
      when r of
        some v:
          return ctx.res.json_raw(v)
        none:
          # fall through to rebuild
      end
    ng _:
      # fall through to rebuild on cache error
  end
  let rows = []
  let n: Int = read_tsv("data/todos.tsv", rows)
  let item: Dict<Str, Str> = {}
  let items_json: Str = ""
  let i: Int
  for (i = 1; i <= n; i++) {
    item["id"] = rows[i, "id"]
    item["title"] = rows[i, "title"]
    let sep: Str = (i > 1 ? "," : "")
    items_json = "#{items_json}#{sep}#{json_encode(item)}"
  }
  let result: Str = "{\"count\":#{n},\"items\":[#{items_json}]}"
  when cache.set("todos:json", result, 30) of
    ok _:
      # noop
    ng _:
      # noop on cache error
  end
  return ctx.res.json_raw(result)
}

function _todo_tr(id: Str, title: Str) -> HtmlFragment {
  let safe_title = safe.html.escape(title)
  let safe_id = safe.attr.escape(id)
  let html: Str =
    "<tr class=\"task-row\">"
      "<td class=\"task-bullet\">&#x25C6;</td>"
      "<td class=\"task-title\">#{safe_title}</td>"
      "<td class=\"task-del\">"
        "<button"
          " hx-delete=\"/todos/#{safe_id}\""
          " hx-target=\"closest tr\""
          " hx-swap=\"outerHTML\""
          " class=\"btn-del\""
        ">[ rm ]</button>"
      "</td>"
    "</tr>"
  return safe.html.raw(html)
}
