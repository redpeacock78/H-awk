# SPDX-License-Identifier: MIT

function test_hawk_shortcuts(    req, res) {
  _router_reset()
  hawk::get("/a",    "_t_hello")
  hawk::post("/b",   "_t_add")
  hawk::put("/c",    "_t_hello")
  hawk::del("/d",    "_t_hello")
  hawk::patch("/e",  "_t_hello")
  hawk::head("/f",   "_t_hello")

  delete req; req["method"] = "GET";    req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::get registers GET /a")

  delete req; req["method"] = "POST";   req["path"] = "/b"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::post registers POST /b")
  assert_eq(res["status"], 201,              "hawk::post: handler status")

  delete req; req["method"] = "PUT";    req["path"] = "/c"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::put registers PUT /c")

  delete req; req["method"] = "DELETE"; req["path"] = "/d"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::del registers DELETE /d")

  delete req; req["method"] = "PATCH";  req["path"] = "/e"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::patch registers PATCH /e")

  delete req; req["method"] = "HEAD";   req["path"] = "/f"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::head registers HEAD /f")
}

function test_hawk_compat_GET(    req, res) {
  _router_reset()
  GET("/compat", "_t_hello")
  delete req; req["method"] = "GET"; req["path"] = "/compat"; delete res
  assert_eq(router_dispatch(req, res), 1,       "compat GET: matched")
  assert_eq(res["body"], "hello",               "compat GET: body")
}
