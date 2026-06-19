# SPDX-License-Identifier: MIT
function test_json_encode_flat(   data, out) {
  delete data
  data["foo"] = "bar"
  data["baz"] = "qux"
  out = json_encode(data)
  # awk の for-in は順序未保証 → 両パターン許容
  assert_true(out == "{\"foo\":\"bar\",\"baz\":\"qux\"}" \
           || out == "{\"baz\":\"qux\",\"foo\":\"bar\"}", \
           "json: flat object")
}

function test_json_encode_type_suffix(   data, out) {
  delete data
  data["age:int"]    = 30
  data["ok:bool"]    = 1
  data["miss:null"]  = ""
  out = json_encode(data)
  # 順序が変わっても OK にするため、含有チェックで代用
  assert_true(index(out, "\"age\":30") > 0,     "json: int suffix")
  assert_true(index(out, "\"ok\":true") > 0,    "json: bool true")
  assert_true(index(out, "\"miss\":null") > 0,  "json: null suffix")
}

function test_json_encode_escape(   data, out) {
  delete data
  data["msg"] = "hello\t\"world\""
  out = json_encode(data)
  assert_eq(out, "{\"msg\":\"hello\\t\\\"world\\\"\"}", "json: escape control chars")
}

function test_json_decode_flat(   out) {
  delete out
  json_decode("{\"foo\":\"bar\",\"n\":42,\"ok\":true,\"v\":null}", out)
  assert_eq(out["foo"], "bar", "json decode: string")
  assert_eq(out["n"],   "42",  "json decode: number as string")
  assert_eq(out["ok"],  "true", "json decode: bool")
  assert_eq(out["v"],   "null", "json decode: null literal")
}

function test_json_encode_any_scalar() {
  assert_eq(json_encode_any("hello"), "\"hello\"", "json any: string scalar")
  assert_eq(json_encode_any(42), "42", "json any: number scalar")
}

function test_json_encode_any_array(   arr) {
  delete arr
  arr["__json_type"] = "array"
  arr[1] = "a"
  arr[2] = "b"
  assert_eq(json_encode_any(arr), "[\"a\",\"b\"]", "json any: array")
}

function test_json_encode_any_object(   obj, out) {
  delete obj
  obj["x"] = 1
  obj["y"] = "hello"
  out = json_encode_any(obj)
  assert_true(index(out, "\"x\":1") > 0, "json any: object number field")
  assert_true(index(out, "\"y\":\"hello\"") > 0, "json any: object string field")
}
