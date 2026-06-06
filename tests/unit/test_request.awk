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
