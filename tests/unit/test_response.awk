# SPDX-License-Identifier: MIT
function test_response_status() {
  delete res
  status(res, 404)
  assert_eq(res["status"], 404, "res: status")
}

function test_response_header() {
  delete res
  header(res, "X-Foo", "bar")
  assert_eq(res["header:x-foo"], "bar", "res: header lower-cased key")
}

function test_response_header_append() {
  delete res
  header_append(res, "Set-Cookie", "a=1")
  header_append(res, "Set-Cookie", "b=2")
  assert_eq(res["header:set-cookie"], "a=1\nb=2", "res: header_append uses LF separator")
}

function test_response_redirect() {
  delete res
  redirect(res, "/login")
  assert_eq(res["status"], 302,       "res: redirect default 302")
  assert_eq(res["header:location"], "/login", "res: redirect location")

  delete res
  redirect(res, "/x", 301)
  assert_eq(res["status"], 301, "res: redirect explicit code")
}

function test_response_json(   data, body) {
  delete res
  delete data
  data["foo"] = "bar"
  json(res, data)
  assert_eq(res["status"], 200, "res: json default 200")
  assert_eq(res["header:content-type"], "application/json; charset=utf-8", "res: json content-type")
  assert_eq(res["body"], "{\"foo\":\"bar\"}", "res: json body")
}

function test_response_text() {
  delete res
  text(res, "hello")
  assert_eq(res["header:content-type"], "text/plain; charset=utf-8", "res: text content-type")
  assert_eq(res["body"], "hello", "res: text body")
}

function test_response_html() {
  delete res
  html(res, "<p>hi</p>")
  assert_eq(res["header:content-type"], "text/html; charset=utf-8", "res: html content-type")
  assert_eq(res["body"], "<p>hi</p>", "res: html body")
}

function test_response_wire(   wire) {
  delete res
  status(res, 200)
  header(res, "X-Foo", "bar")
  res["body"] = "ok"
  wire = response_wire(res)

  assert_true(index(wire, "HTTP/1.1 200 OK\r\n") == 1, "res: status-line")
  assert_true(index(wire, "Content-Length: 2\r\n") > 0, "res: content-length")
  assert_true(index(wire, "X-Foo: bar\r\n") > 0,        "res: custom header")
  assert_true(index(wire, "Connection: close\r\n") > 0, "res: connection close")
  assert_true(index(wire, "\r\n\r\nok") > 0, "res: body separator")
}

function test_response_header_crlf_strip() {
  delete res
  header(res, "Location", "/safe\r\nX-Injected: yes")
  assert_eq(res["header:location"], "/safeX-Injected: yes", "res: header strips CRLF")
}

function test_response_redirect_crlf_strip() {
  delete res
  redirect(res, "/foo\r\nSet-Cookie: evil=1")
  assert_eq(res["header:location"], "/fooSet-Cookie: evil=1", "res: redirect strips CRLF")
}
