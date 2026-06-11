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
  assert_eq(router_dispatch(req, res), 1, "hawk::get dispatch")
  assert_eq(res["body"], "hello",          "hawk::get body")

  delete req; req["method"] = "POST";   req["path"] = "/b"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::post dispatch")
  assert_eq(res["status"], 201,            "hawk::post status")
  assert_eq(res["body"], "added",          "hawk::post body")

  delete req; req["method"] = "PUT";    req["path"] = "/c"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::put dispatch")
  assert_eq(res["body"], "hello",          "hawk::put body")

  delete req; req["method"] = "DELETE"; req["path"] = "/d"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::del dispatch")
  assert_eq(res["body"], "hello",          "hawk::del body")

  delete req; req["method"] = "PATCH";  req["path"] = "/e"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::patch dispatch")
  assert_eq(res["body"], "hello",          "hawk::patch body")

  delete req; req["method"] = "HEAD";   req["path"] = "/f"; delete res
  assert_eq(router_dispatch(req, res), 1, "hawk::head dispatch")
  assert_eq(res["body"], "hello",          "hawk::head body")
}

function test_hawk_compat_GET(    req, res) {
  _router_reset()
  GET("/compat", "_t_hello")
  delete req; req["method"] = "GET"; req["path"] = "/compat"; delete res
  assert_eq(router_dispatch(req, res), 1,       "compat GET: matched")
  assert_eq(res["body"], "hello",               "compat GET: body")
}

function test_hawk_on_single(    req, res) {
  _router_reset()
  hawk::on("GET", "/a", "_t_hello")
  assert_eq(ROUTES_COUNT, 1, "on single: 1 route")
  delete req; req["method"] = "GET"; req["path"] = "/a"; delete res
  assert_eq(router_dispatch(req, res), 1,   "on single: dispatch")
  assert_eq(res["body"], "hello",            "on single: body")
}

function test_hawk_on_multi_methods(    req, res, ms) {
  _router_reset()
  delete ms; ms[1] = "GET"; ms[2] = "POST"
  hawk::on(ms, "/b", "_t_hello")
  assert_eq(ROUTES_COUNT, 2, "on multi_methods: 2 routes")
  delete req; req["method"] = "GET";  req["path"] = "/b"; delete res
  assert_eq(router_dispatch(req, res), 1, "on multi_methods: GET dispatch")
  delete req; req["method"] = "POST"; req["path"] = "/b"; delete res
  assert_eq(router_dispatch(req, res), 1, "on multi_methods: POST dispatch")
}

function test_hawk_on_multi_paths(    req, res, ps) {
  _router_reset()
  delete ps; ps[1] = "/c"; ps[2] = "/d"
  hawk::on("GET", ps, "_t_hello")
  assert_eq(ROUTES_COUNT, 2, "on multi_paths: 2 routes")
  delete req; req["method"] = "GET"; req["path"] = "/c"; delete res
  assert_eq(router_dispatch(req, res), 1, "on multi_paths: /c dispatch")
  delete req; req["method"] = "GET"; req["path"] = "/d"; delete res
  assert_eq(router_dispatch(req, res), 1, "on multi_paths: /d dispatch")
}

function test_hawk_on_multi_both(    req, res, ms, ps) {
  _router_reset()
  delete ms; ms[1] = "GET"; ms[2] = "POST"
  delete ps; ps[1] = "/e"; ps[2] = "/f"
  hawk::on(ms, ps, "_t_hello")
  assert_eq(ROUTES_COUNT, 4, "on multi_both: 4 routes")
  delete req; req["method"] = "GET";  req["path"] = "/e"; delete res
  assert_eq(router_dispatch(req, res), 1, "on multi_both: GET /e")
  delete req; req["method"] = "POST"; req["path"] = "/f"; delete res
  assert_eq(router_dispatch(req, res), 1, "on multi_both: POST /f")
}

function test_hawk_on_custom_method(    req, res) {
  _router_reset()
  hawk::on("PURGE", "/cache", "_t_hello")
  assert_eq(ROUTES_COUNT, 1, "on custom: 1 route")
  delete req; req["method"] = "PURGE"; req["path"] = "/cache"; delete res
  assert_eq(router_dispatch(req, res), 1,  "on custom: dispatch")
  assert_eq(res["body"], "hello",           "on custom: body")
}

function test_hawk_all_single(    req, res) {
  _router_reset()
  hawk::all("/x", "_t_hello")
  assert_eq(ROUTES_COUNT, 7, "all single: 7 routes")
  delete req; req["method"] = "GET";     req["path"] = "/x"; delete res
  assert_eq(router_dispatch(req, res), 1, "all single: GET")
  delete req; req["method"] = "POST";    req["path"] = "/x"; delete res
  assert_eq(router_dispatch(req, res), 1, "all single: POST")
  delete req; req["method"] = "OPTIONS"; req["path"] = "/x"; delete res
  assert_eq(router_dispatch(req, res), 1, "all single: OPTIONS")
}

function test_hawk_all_multi_paths(    req, res, ps) {
  _router_reset()
  delete ps; ps[1] = "/y"; ps[2] = "/z"
  hawk::all(ps, "_t_hello")
  assert_eq(ROUTES_COUNT, 14, "all multi: 14 routes")
  delete req; req["method"] = "GET"; req["path"] = "/y"; delete res
  assert_eq(router_dispatch(req, res), 1, "all multi: GET /y")
  delete req; req["method"] = "PUT"; req["path"] = "/z"; delete res
  assert_eq(router_dispatch(req, res), 1, "all multi: PUT /z")
}
