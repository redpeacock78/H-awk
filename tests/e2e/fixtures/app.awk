# SPDX-License-Identifier: MIT
# E2E fixture app: 最小ルートで HTTP/router/static/parse を網羅
BEGIN {
  GET("/",            "e_index")
  GET("/users/:id",   "e_show")
  POST("/echo",       "e_echo")
  GET("/render-html", "e_render")
}

function e_index() {
  ctx::text("hello")
}

function e_show() {
  ctx::text("user=" ctx::param("id"))
}

function e_echo(    data) {
  delete data
  data["got"] = ctx::req["form:msg"]
  ctx::status(201)
  return ctx::json(json_encode(data))
}

function e_render() {
  ctx::render("tests/e2e/fixtures/views/test.html")
}
