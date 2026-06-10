# SPDX-License-Identifier: MIT
function test_request_parse_get(   raw, req) {
  raw = "GET /users/42?page=1 HTTP/1.1\r\nHost: x\r\nUser-Agent: curl/8.0\r\n\r\n"
  delete req
  request_parse(raw, req)
  assert_eq(req["method"],            "GET",            "req: method")
  assert_eq(req["path"],              "/users/42",      "req: path")
  assert_eq(req["query_string"],      "page=1",         "req: query_string")
  assert_eq(req["http_version"],      "HTTP/1.1",       "req: version")
  assert_eq(req["header:host"],       "x",              "req: host header")
  assert_eq(req["header:user-agent"], "curl/8.0",       "req: ua header")
  assert_eq(req["query:page"],        "1",              "req: query parsed")
}

function test_request_parse_form(   raw, req) {
  raw = "POST /todos HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 16\r\n\r\ntitle=buy+milk&n=1"
  delete req
  request_parse(raw, req)
  assert_eq(req["method"],         "POST",       "req: post method")
  assert_eq(req["form:title"],     "buy milk",   "req: form decoded")
  assert_eq(req["form:n"],         "1",          "req: form scalar")
}

function test_request_parse_json(   raw, req) {
  raw = "POST /api HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 19\r\n\r\n{\"foo\":\"bar\",\"n\":42}"
  delete req
  request_parse(raw, req)
  assert_eq(req["json:foo"], "bar", "req: json key")
  assert_eq(req["json:n"],   "42",  "req: json num")
}

function test_request_bad_line(   raw, req, ok) {
  raw = "GARBAGE\r\n\r\n"
  delete req
  ok = request_parse(raw, req)
  assert_eq(ok, 0, "req: bad request-line rejected")
}

function test_request_parse_array(   raw, req) {
  delete _ARR_COUNT
  raw = "POST /tags HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 27\r\n\r\ntags[]=shop&tags[]=urgent"
  delete req
  request_parse(raw, req)
  assert_eq(req["form:tags[]", 1], "shop",   "req: array index 1")
  assert_eq(req["form:tags[]", 2], "urgent", "req: array index 2")
}

function test_request_parse_eq_in_value(   raw, req) {
  raw = "POST /api HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 28\r\n\r\ntoken=YWJj%3D%3D&other=ok"
  delete req
  request_parse(raw, req)
  assert_eq(req["form:token"], "YWJj==", "req: encoded = in value (url-decoded)")
  assert_eq(req["form:other"], "ok",     "req: another pair after eq value")
}

function test_request_parse_zig_get(   poll, req) {
  poll = "42\x1eGET\x1e/users/1\x1eHost: localhost\r\nAccept: */*\r\n\x1e0\x1e"
  delete req
  delete _ARR_COUNT
  assert_eq(parse_request_zig(poll, req), 1, "zig req: parse returns 1")
  assert_eq(req["_conn_id"],      "42",        "zig req: conn_id")
  assert_eq(req["method"],        "GET",       "zig req: method")
  assert_eq(req["path"],          "/users/1",  "zig req: path")
  assert_eq(req["header:host"],   "localhost", "zig req: host header")
  assert_eq(req["header:accept"], "*/*",       "zig req: accept header")
  assert_eq(req["body"],          "",          "zig req: empty body")
}

function test_request_parse_zig_post_form(   poll, req) {
  poll = "7\x1ePOST\x1e/todos\x1eContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 9\r\n\x1e9\x1etitle=buy"
  delete req
  delete _ARR_COUNT
  assert_eq(parse_request_zig(poll, req), 1, "zig post: parse ok")
  assert_eq(req["method"],     "POST", "zig post: method")
  assert_eq(req["form:title"], "buy",  "zig post: form field")
}

function test_request_parse_zig_query(   poll, req) {
  poll = "3\x1eGET\x1e/search?q=hello&page=2\x1eHost: x\r\n\x1e0\x1e"
  delete req
  delete _ARR_COUNT
  parse_request_zig(poll, req)
  assert_eq(req["path"],         "/search",        "zig query: path without qs")
  assert_eq(req["query_string"], "q=hello&page=2", "zig query: query_string")
  assert_eq(req["query:q"],      "hello",          "zig query: q param")
  assert_eq(req["query:page"],   "2",              "zig query: page param")
}

function test_request_parse_zig_bad(   poll, req, ok) {
  poll = "only_one_field"
  delete req
  ok = parse_request_zig(poll, req)
  assert_eq(ok, 0, "zig req: too few fields rejected")
}

function test_request_parse_multipart_no_lib(    raw, req, ok) {
  delete LIBS_LOADED
  raw = "POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=BOUND\r\nContent-Length: 10\r\n\r\ndummybody"
  delete req
  ok = request_parse(raw, req)
  assert_eq(ok, 1, "request: multipart no-lib still parses ok")
  assert_eq(req["method"], "POST", "request: multipart no-lib method")
  assert_eq(req["header:content-type"], "multipart/form-data; boundary=BOUND", "request: multipart no-lib ct header")
}

function test_request_parse_multipart_text(    raw, req, ok, body, boundary) {
  if (!LIBS_LOADED["multipart"]) {
    TESTS_SKIPPED++
    return
  }
  boundary = "TESTBOUND"
  body = "--TESTBOUND\r\nContent-Disposition: form-data; name=\"username\"\r\n\r\nalice\r\n--TESTBOUND--\r\n"
  raw = sprintf("POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=TESTBOUND\r\nContent-Length: %d\r\n\r\n%s", length(body), body)
  delete req
  ok = request_parse(raw, req)
  assert_eq(ok, 1, "request: multipart text parse ok")
  assert_eq(req["form:username"], "alice", "request: multipart text field value")
}

function test_request_parse_multipart_file(    raw, req, ok, body) {
  if (!LIBS_LOADED["multipart"]) {
    TESTS_SKIPPED++
    return
  }
  body = "--BOUND\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nFAKEJPEG\r\n--BOUND--\r\n"
  raw = sprintf("POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=BOUND\r\nContent-Length: %d\r\n\r\n%s", length(body), body)
  delete req
  ok = request_parse(raw, req)
  assert_eq(ok, 1, "request: multipart file parse ok")
  assert_eq(req["file:avatar"], "FAKEJPEG", "request: multipart file body")
  assert_eq(req["file:avatar_filename"], "photo.jpg", "request: multipart file filename")
  assert_eq(req["file:avatar_type"], "image/jpeg", "request: multipart file content-type")
}
