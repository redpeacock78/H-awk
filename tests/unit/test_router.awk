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

function _router_reset_query() {
  _router_reset()
  delete ROUTES_QUERY_TYPES
}

function _t_query_handler() { ctx::text("query-ok") }

function test_router_query_register_and_match(   req, res, ok) {
  _router_reset_query()
  QUERY("/search", "_t_query_handler")

  delete req; delete res
  req["method"] = "QUERY"
  req["path"]   = "/search"
  req["header:content-type"] = "application/json"
  ok = router_dispatch(req, res)
  assert_eq(ok, 1,                  "query: dispatch ok")
  assert_eq(res["body"], "query-ok","query: handler called")
  assert_eq(res["header:accept-query"], "*/*", "query: Accept-Query: */* when no types")
}

function test_router_query_missing_content_type(   req, res, ok) {
  _router_reset_query()
  QUERY("/search", "_t_query_handler")

  delete req; delete res
  req["method"] = "QUERY"
  req["path"]   = "/search"
  req["header:content-type"] = ""
  ok = router_dispatch(req, res)
  assert_eq(ok, -1,                "query: missing CT → dispatch returns -1")
  assert_eq(res["status"], 400,    "query: missing CT → 400")
}

function test_router_query_wrong_content_type(   req, res, ok, types) {
  _router_reset_query()
  delete types
  types[1] = "application/json"
  QUERY("/search", "_t_query_handler", types)

  delete req; delete res
  req["method"] = "QUERY"
  req["path"]   = "/search"
  req["header:content-type"] = "text/plain"
  ok = router_dispatch(req, res)
  assert_eq(ok, -1,                        "query: wrong CT → -1")
  assert_eq(res["status"], 415,            "query: wrong CT → 415")
  assert_eq(res["header:accept-query"], "application/json", "query: 415 has Accept-Query")
}

function test_router_query_accept_query_injected(   req, res, ok, types) {
  _router_reset_query()
  delete types
  types[1] = "application/json"
  types[2] = "application/sql"
  QUERY("/search", "_t_query_handler", types)

  delete req; delete res
  req["method"] = "QUERY"
  req["path"]   = "/search"
  req["header:content-type"] = "application/json"
  ok = router_dispatch(req, res)
  assert_eq(ok, 1, "query: accept-query dispatch ok")
  assert_true(index(res["header:accept-query"], "application/json") > 0, "query: AQ has json")
  assert_true(index(res["header:accept-query"], "application/sql")  > 0, "query: AQ has sql")
}

function test_router_query_405_includes_accept_query(   req, res, ok, types) {
  _router_reset_query()
  delete types
  types[1] = "application/json"
  GET("/search",   "_t_hello")
  QUERY("/search", "_t_query_handler", types)

  delete req; delete res
  req["method"] = "DELETE"
  req["path"]   = "/search"
  ok = router_dispatch(req, res)
  assert_eq(ok, -1,                        "query: 405 returns -1")
  assert_eq(res["status"], 405,            "query: 405 status")
  assert_true(index(res["header:allow"], "QUERY") > 0, "query: Allow contains QUERY")
  assert_eq(res["header:accept-query"], "application/json", "query: 405 has Accept-Query")
}

function test_router_query_options(   req, res, ok, types) {
  _router_reset_query()
  delete types
  types[1] = "application/json"
  GET("/search",   "_t_hello")
  QUERY("/search", "_t_query_handler", types)

  delete req; delete res
  req["method"] = "OPTIONS"
  req["path"]   = "/search"
  ok = router_dispatch(req, res)
  assert_eq(ok, 1,                         "query: OPTIONS returns 1")
  assert_eq(res["status"], 204,            "query: OPTIONS 204")
  assert_true(index(res["header:allow"], "GET")     > 0, "query: OPTIONS Allow GET")
  assert_true(index(res["header:allow"], "QUERY")   > 0, "query: OPTIONS Allow QUERY")
  assert_true(index(res["header:allow"], "OPTIONS") > 0, "query: OPTIONS Allow OPTIONS")
  assert_eq(res["header:accept-query"], "application/json", "query: OPTIONS Accept-Query")
}

function _t_catchall() { ctx::text("rest=" result_val(ctx::param("path"))) }

function test_router_catchall_match(   req, res, ok) {
  _router_reset()
  GET("/docs/*path", "_t_catchall")

  delete req; req["method"] = "GET"; req["path"] = "/docs/guide/routing"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1, "router: catchall matched")
  assert_eq(res["body"], "rest=guide/routing", "router: catchall multi-segment param")

  delete req; req["method"] = "GET"; req["path"] = "/docs/a"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1, "router: catchall single segment")
  assert_eq(res["body"], "rest=a", "router: catchall single segment param")

  # 残りパスが空 (1 文字未満) のときはマッチしない
  delete req; req["method"] = "GET"; req["path"] = "/docs/"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 0, "router: catchall requires at least 1 char")
}

function _t_catchall_mixed() { ctx::text("id=" result_val(ctx::param("id")) " rest=" result_val(ctx::param("rest"))) }

function test_router_catchall_with_named_param(   req, res, ok) {
  _router_reset()
  GET("/users/:id/files/*rest", "_t_catchall_mixed")

  delete req; req["method"] = "GET"; req["path"] = "/users/7/files/a/b.txt"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1, "router: catchall+named matched")
  assert_eq(res["body"], "id=7 rest=a/b.txt", "router: both params extracted")
}

function _t_catchall_lit() { ctx::text("literal") }

function test_router_catchall_nontail_is_literal(   req, res, ok) {
  _router_reset()
  GET("/a/*b/c", "_t_catchall_lit")

  delete req; req["method"] = "GET"; req["path"] = "/a/*b/c"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 1, "router: non-tail *seg matches literally")

  delete req; req["method"] = "GET"; req["path"] = "/a/x/c"
  delete res
  ok = router_dispatch(req, res)
  assert_eq(ok, 0, "router: non-tail *seg is not a wildcard")
}
