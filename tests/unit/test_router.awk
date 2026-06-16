# SPDX-License-Identifier: MIT
# テスト用ハンドラ (ctx:: スタイル — @handler() でゼロ引数呼び出し)
function _t_hello() { ctx::text("hello") }
function _t_show()  { ctx::text("id=" result_val(ctx::param("id"))) }
function _t_add()   { ctx::status(201); ctx::text("added") }

function _router_reset() {
  delete ROUTES
  delete ROUTES_ORDER
  ROUTES_COUNT = 0
}

function test_router_register_and_match(   req, res, ok) {
  _router_reset()
  GET("/",            "_t_hello")
  GET("/users/:id",   "_t_show")
  POST("/todos",      "_t_add")

  delete req; req["method"] = "GET"; req["path"] = "/"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1,           "router: matched root")
  assert_eq(res["body"], "hello", "router: root body")

  delete req; req["method"] = "GET"; req["path"] = "/users/42"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1,                  "router: matched param")
  assert_eq(res["body"], "id=42",   "router: param extracted")

  delete req; req["method"] = "POST"; req["path"] = "/todos"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1,                "router: matched POST")
  assert_eq(res["status"], 201,    "router: handler set status")
  assert_eq(res["body"], "added",  "router: handler set body")
}

function test_router_404(   req, res, ok) {
  _router_reset()
  GET("/", "_t_hello")
  delete req; req["method"] = "GET"; req["path"] = "/missing"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 0, "router: 404 returns 0")
}

function test_router_405(   req, res, ok) {
  _router_reset()
  GET("/x",   "_t_hello")
  POST("/x",  "_t_add")
  delete req; req["method"] = "DELETE"; req["path"] = "/x"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, -1,                       "router: 405 returns -1")
  assert_eq(res["status"], 405,           "router: 405 status set")
  assert_true(index(res["header:allow"], "GET") > 0,  "router: Allow contains GET")
  assert_true(index(res["header:allow"], "POST") > 0, "router: Allow contains POST")
}

function test_router_static_priority(   req, res, ok) {
  _router_reset()
  GET("/users/me",   "_t_hello")
  GET("/users/:id",  "_t_show")
  delete req; req["method"] = "GET"; req["path"] = "/users/me"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(res["body"], "hello", "router: static path priority")
}
