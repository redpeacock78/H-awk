# SPDX-License-Identifier: MIT
# E2E fixture app: 最小ルートで HTTP/router/static/parse を網羅
BEGIN {
  GET("/",            "e_index")
  GET("/users/:id",   "e_show")
  POST("/echo",       "e_echo")
  GET("/render-html", "e_render")
}

function e_index(req, res) {
  text(res, "hello")
}

function e_show(req, res) {
  text(res, "user=" req["params:id"])
}

function e_echo(req, res,    data) {
  delete data
  data["got"] = req["form:msg"]
  json(res, data, 201)
}

function e_render(req, res) {
  render(res, "tests/e2e/fixtures/views/test.html")
}
