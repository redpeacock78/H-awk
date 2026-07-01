# SPDX-License-Identifier: MIT
# tests/unit/test_ctx.awk

function test_ctx_load_copies_req(    req, res) {
  delete req
  delete res
  req["method"] = "GET"
  req["path"] = "/test"
  req["query:limit"] = "10"
  req["params:id"] = "42"
  req["header:content-type"] = "application/json"
  res["status"] = 200

  _ctx_load(req, res)

  assert_eq(ctx::req["method"],              "GET",               "ctx_load: method copied")
  assert_eq(ctx::req["path"],                "/test",             "ctx_load: path copied")
  assert_eq(ctx::req["query:limit"],         "10",                "ctx_load: query copied")
  assert_eq(ctx::req["params:id"],           "42",                "ctx_load: param copied")
  assert_eq(ctx::req["header:content-type"], "application/json",  "ctx_load: header copied")
  assert_eq(ctx::res["status"],              200,                 "ctx_load: res status copied")
}

function test_ctx_save_copies_res_back(    req, res) {
  delete req
  delete res
  res["status"] = 200

  _ctx_load(req, res)

  ctx::res["status"] = 201
  ctx::res["body"] = "created"
  ctx::res["header:content-type"] = "application/json"

  _ctx_save(res)

  assert_eq(res["status"],              201,                "ctx_save: status written back")
  assert_eq(res["body"],                "created",          "ctx_save: body written back")
  assert_eq(res["header:content-type"], "application/json", "ctx_save: header written back")
}

function test_ctx_query_helper(    req, res, r) {
  delete req
  delete res
  req["query:page"] = "3"
  _ctx_load(req, res)
  assert_eq(result_val(ctx::query("page")), "3", "ctx::query reads query param")

  delete req
  delete res
  req["query:q"] = ""
  _ctx_load(req, res)
  r = ctx::query("q")
  assert_true(result_ok(r), "ctx::query treats empty existing query as ok")
  assert_eq(result_val(r), "", "ctx::query returns empty query value")
}

function test_ctx_param_helper(    req, res, r) {
  delete req
  delete res
  req["params:id"] = "99"
  _ctx_load(req, res)
  assert_eq(result_val(ctx::param("id")), "99", "ctx::param reads path param")

  delete req
  delete res
  req["params:id"] = ""
  _ctx_load(req, res)
  r = ctx::param("id")
  assert_true(result_ok(r), "ctx::param treats empty existing param as ok")
  assert_eq(result_val(r), "", "ctx::param returns empty param value")
}

function test_ctx_get_header_helper(    req, res, r) {
  delete req
  delete res
  req["header:accept"] = "text/html"
  _ctx_load(req, res)
  assert_eq(result_val(ctx::get_header("Accept")), "text/html", "ctx::get_header normalizes to lowercase")
  assert_eq(result_val(ctx::get_header("accept")), "text/html", "ctx::get_header lowercase input works")

  delete req
  delete res
  req["header:x-empty"] = ""
  _ctx_load(req, res)
  r = ctx::get_header("X-Empty")
  assert_true(result_ok(r), "ctx::get_header treats empty existing header as ok")
  assert_eq(result_val(r), "", "ctx::get_header returns empty header value")
}

function test_ctx_body_helper(    req, res, r) {
  delete req
  delete res
  req["body"] = "raw body content"
  _ctx_load(req, res)
  assert_eq(result_val(ctx::body()), "raw body content", "ctx::body returns raw body")

  delete req
  delete res
  req["body"] = ""
  _ctx_load(req, res)
  r = ctx::body()
  assert_true(result_ok(r), "ctx::body treats empty existing body as ok")
  assert_eq(result_val(r), "", "ctx::body returns empty body")

  delete req
  delete res
  req["form:title"] = ""
  _ctx_load(req, res)
  r = ctx::req_form("title")
  assert_true(result_ok(r), "ctx::req_form treats empty existing form value as ok")
  assert_eq(result_val(r), "", "ctx::req_form returns empty form value")

  delete req
  delete res
  req["body"] = ""
  _ctx_load(req, res)
  r = ctx::req_json()
  assert_true(!result_ok(r), "ctx::req_json empty body is ng under JsonValue contract")
  assert_eq(result_err_type(r), "JsonParseError", "ctx::req_json empty body error type")
}

function test_ctx_req_json_value(    req, res, r, out, out_type) {
  delete req
  delete res
  req["body"] = "{\"name\":\"alice\",\"age\":30}"
  _ctx_load(req, res)
  r = ctx::req_json()
  assert_true(result_ok(r), "ctx::req_json returns ok for valid JSON object")
  delete out
  delete out_type
  result_val_into_map(r, out, out_type)
  assert_eq(out["name"], "alice", "ctx::req_json map has name")
  assert_eq(out["age"],  "30",    "ctx::req_json map has age")

  delete req
  delete res
  req["body"] = "[1,2,3]"
  _ctx_load(req, res)
  r = ctx::req_json()
  assert_true(result_ok(r), "ctx::req_json returns ok for top-level array")

  delete req
  delete res
  req["body"] = "not json"
  _ctx_load(req, res)
  r = ctx::req_json()
  assert_true(!result_ok(r), "ctx::req_json invalid body is ng")
  assert_eq(result_err_type(r), "JsonParseError", "ctx::req_json invalid body error type")

  delete req
  delete res
  _ctx_load(req, res)
  r = ctx::req_json()
  assert_true(!result_ok(r), "ctx::req_json missing body is ng")
  assert_eq(result_err_type(r), "JsonParseError", "ctx::req_json missing body error type")
}

function test_ctx_req_json_object(    req, res, r, out, out_type) {
  delete req
  delete res
  req["body"] = "{\"name\":\"alice\"}"
  _ctx_load(req, res)
  r = ctx::req_json_object()
  assert_true(result_ok(r), "ctx::req_json_object returns ok for valid JSON object")
  delete out
  delete out_type
  result_val_into_map(r, out, out_type)
  assert_eq(out["name"], "alice", "ctx::req_json_object map has name")

  delete req
  delete res
  req["body"] = "[1,2,3]"
  _ctx_load(req, res)
  r = ctx::req_json_object()
  assert_true(!result_ok(r), "ctx::req_json_object rejects top-level array")
  assert_eq(result_err_type(r), "JsonParseError", "ctx::req_json_object array error type")
}

function test_ctx_req_json_t(    req, res, r, out, out_type) {
  delete req
  delete res
  req["body"] = "{\"n\":1}"
  _ctx_load(req, res)
  r = ctx::dispatch("req.json_t", "Int")
  assert_true(result_ok(r), "ctx::req_json_t Int ok")
  delete out
  delete out_type
  result_val_into_map(r, out, out_type)
  assert_eq(out["n"], "1", "ctx::req_json_t Int payload")

  delete req
  delete res
  req["body"] = "{\"n\":\"abc\"}"
  _ctx_load(req, res)
  r = ctx::dispatch("req.json_t", "Int")
  assert_true(!result_ok(r), "ctx::req_json_t Int type mismatch is ng")
  assert_eq(result_err_type(r), "JsonTypeError", "ctx::req_json_t type mismatch error type")
}

function test_ctx_req_json_too_deep(    req, res, r, s, i) {
  s = "1"
  for (i = 0; i < 40; i++) s = "[" s "]"
  delete req
  delete res
  req["body"] = s
  _ctx_load(req, res)
  r = ctx::req_json()
  assert_true(!result_ok(r), "ctx::req_json too-deep is ng")
  assert_eq(result_err_type(r), "JsonTooDeepError", "ctx::req_json too-deep error type")
}

function test_ctx_req_json_object_too_deep(    req, res, r, s, i, body) {
  body = "\"a\":1"
  for (i = 0; i < 40; i++) body = "\"a\":{" body "}"
  s = "{" body "}"
  delete req
  delete res
  req["body"] = s
  _ctx_load(req, res)
  r = ctx::req_json_object()
  assert_true(!result_ok(r), "ctx::req_json_object too-deep is ng")
  assert_eq(result_err_type(r), "JsonTooDeepError", "ctx::req_json_object too-deep error type")
}

function test_ctx_req_json_object_trailing_garbage(    req, res, r) {
  delete req
  delete res
  req["body"] = "{\"a\":1} junk"
  _ctx_load(req, res)
  r = ctx::req_json_object()
  assert_true(!result_ok(r), "ctx::req_json_object trailing garbage is ng")
  assert_eq(result_err_type(r), "JsonParseError", "ctx::req_json_object trailing garbage error type")
}

function test_ctx_json_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::json("hello")
  _ctx_save(res)
  assert_eq(res["body"],                     "\"hello\"",                  "ctx::json encodes body")
  assert_eq(res["header:content-type"], "application/json; charset=utf-8", "ctx::json sets content-type")
}

function test_ctx_json_raw_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::json_raw("{\"ok\":true}")
  _ctx_save(res)
  assert_eq(res["body"],                     "{\"ok\":true}",                  "ctx::json_raw sets body")
  assert_eq(res["header:content-type"], "application/json; charset=utf-8", "ctx::json_raw sets content-type")
}

function test_ctx_text_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::text("hello")
  _ctx_save(res)
  assert_eq(res["body"],                     "hello",                       "ctx::text sets body")
  assert_eq(res["header:content-type"], "text/plain; charset=utf-8", "ctx::text sets content-type")
}

function test_ctx_status_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::status(404)
  _ctx_save(res)
  assert_eq(res["status"], 404, "ctx::status sets status code")
}

function test_ctx_set_header_helper(    req, res) {
  delete req
  delete res
  res["status"] = 200
  _ctx_load(req, res)
  ctx::set_header("X-Custom", "myvalue")
  _ctx_save(res)
  assert_eq(res["header:x-custom"], "myvalue", "ctx::set_header sets response header")
}

function test_ctx_load_clears_previous(    req1, req2, res) {
  delete req1
  delete req2
  delete res
  req1["query:old"] = "stale"
  _ctx_load(req1, res)
  assert_eq(ctx::req["query:old"], "stale", "ctx_load: first load sets value")

  req2["query:new"] = "fresh"
  _ctx_load(req2, res)
  assert_eq(ctx::req["query:new"], "fresh", "ctx_load: second load sets new value")
  assert_eq(ctx::req["query:old"], "",      "ctx_load: previous keys cleared")
}
