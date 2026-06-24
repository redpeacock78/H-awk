# SPDX-License-Identifier: MIT
# tests/unit/test_gzip.awk

function _gzip_long_body(    s, i) {
  s = ""
  for (i = 0; i < 20; i++) {
    s = s "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  return s
}

function test_gzip_no_gzip_env(    res, req, saved) {
  saved = ENVIRON["HAWK_GZIP"]
  ENVIRON["HAWK_GZIP"] = ""
  delete res; delete req
  res["status"] = 200
  res["body"] = _gzip_long_body()
  res["header:content-type"] = "text/plain"
  req["method"] = "GET"
  req["header:accept-encoding"] = "gzip"
  assert_eq(gzip_maybe(res, req), 0, "no HAWK_GZIP env: gzip_maybe should return 0")
  ENVIRON["HAWK_GZIP"] = saved
}

function test_gzip_no_accept_encoding(    res, req, saved) {
  saved = ENVIRON["HAWK_GZIP"]
  ENVIRON["HAWK_GZIP"] = "1"
  delete res; delete req
  res["status"] = 200
  res["body"] = _gzip_long_body()
  res["header:content-type"] = "text/plain"
  req["method"] = "GET"
  assert_eq(gzip_maybe(res, req), 0, "no accept-encoding: gzip_maybe should return 0")
  ENVIRON["HAWK_GZIP"] = saved
}

function test_gzip_small_body(    res, req, saved) {
  saved = ENVIRON["HAWK_GZIP"]
  ENVIRON["HAWK_GZIP"] = "1"
  delete res; delete req
  res["status"] = 200
  res["body"] = "small"
  res["header:content-type"] = "text/plain"
  req["method"] = "GET"
  req["header:accept-encoding"] = "gzip"
  assert_eq(gzip_maybe(res, req), 0, "small body: gzip_maybe should return 0")
  ENVIRON["HAWK_GZIP"] = saved
}

function test_gzip_204(    res, req, saved) {
  saved = ENVIRON["HAWK_GZIP"]
  ENVIRON["HAWK_GZIP"] = "1"
  delete res; delete req
  res["status"] = 204
  res["body"] = _gzip_long_body()
  res["header:content-type"] = "text/plain"
  req["method"] = "GET"
  req["header:accept-encoding"] = "gzip"
  assert_eq(gzip_maybe(res, req), 0, "204: gzip_maybe should return 0")
  ENVIRON["HAWK_GZIP"] = saved
}

function test_gzip_image_ct(    res, req, saved) {
  saved = ENVIRON["HAWK_GZIP"]
  ENVIRON["HAWK_GZIP"] = "1"
  delete res; delete req
  res["status"] = 200
  res["body"] = _gzip_long_body()
  res["header:content-type"] = "image/png"
  req["method"] = "GET"
  req["header:accept-encoding"] = "gzip"
  assert_eq(gzip_maybe(res, req), 0, "image/png: gzip_maybe should return 0")
  ENVIRON["HAWK_GZIP"] = saved
}

function test_gzip_compress(    res, req, orig_body, result, saved) {
  if (!LIBS_LOADED["gzip"]) {
    TESTS_SKIPPED++
    return
  }
  saved = ENVIRON["HAWK_GZIP"]
  ENVIRON["HAWK_GZIP"] = "1"
  delete res; delete req
  orig_body = _gzip_long_body()
  res["status"] = 200
  res["body"] = orig_body
  res["header:content-type"] = "text/plain"
  req["method"] = "GET"
  req["header:accept-encoding"] = "gzip, br"

  result = gzip_maybe(res, req)
  assert_eq(result, 1, "gzip_maybe should return 1")
  assert_eq(res["header:content-encoding"], "gzip", "content-encoding should be gzip")
  assert_true("header:vary" in res, "vary header should be set")
  assert_true(length(res["body"]) > 0, "compressed body should not be empty")
  assert_true(length(res["body"]) < length(orig_body), "compressed should be smaller than original")
  ENVIRON["HAWK_GZIP"] = saved
}
