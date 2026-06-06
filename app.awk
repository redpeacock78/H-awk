# SPDX-License-Identifier: MIT
# app.awk -- H-awk サンプル todo アプリ
#
# ルート:
#   GET    /              トップ画面
#   POST   /todos         todo 追加 (form: title)
#   GET    /todos.json    一覧 JSON
#   DELETE /todos/:id     削除

BEGIN {
  GET("/",           "todo_index")
  POST("/todos",     "todo_add")
  GET("/todos.json", "todo_list_json")
  DELETE("/todos/:id","todo_delete")
}

function todo_index(req, res) {
  render(res, "views/index.html")
}

function todo_add(req, res,    row, title) {
  title = req["form:title"]
  if (title == "") {
    status(res, 400)
    text(res, "title required")
    return
  }
  delete row
  row["id"]    = systime() "_" int(rand() * 100000)
  row["title"] = title
  append_tsv("data/todos.tsv", row)
  status(res, 201)
  render(res, "views/todo_added.html")
}

function todo_list_json(req, res,    rows, n, i, item, items_json, body) {
  delete rows
  n = read_tsv("data/todos.tsv", rows)
  items_json = ""
  for (i = 1; i <= n; i++) {
    delete item
    item["id"]    = rows[i, "id"]
    item["title"] = rows[i, "title"]
    items_json = items_json (i > 1 ? "," : "") json_encode(item)
  }
  body = sprintf("{\"count\":%d,\"items\":[%s]}", n, items_json)
  res["status"] = 200
  res["header:content-type"] = "application/json; charset=utf-8"
  res["body"] = body
}

function todo_delete(req, res,    deleted) {
  deleted = delete_tsv("data/todos.tsv", "id", req["params:id"])
  if (deleted == 0) {
    status(res, 404)
    text(res, "not found")
    return
  }
  status(res, 204)
  res["body"] = ""
}
