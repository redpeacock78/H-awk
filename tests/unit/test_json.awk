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

function test_json_unescape_basic(    res) {
  _json_init()
  res = _json_unescape("hello")
  assert_eq(res, "hello", "unescape: plain string")
}
function test_json_unescape_control(    res) {
  _json_init()
  res = _json_unescape("a\\nb")
  assert_eq(res, "a\nb", "unescape: newline")
}
function test_json_unescape_quote(    res) {
  _json_init()
  res = _json_unescape("say \\\"hi\\\"")
  assert_eq(res, "say \"hi\"", "unescape: escaped quote")
}
function test_json_unescape_backslash(    res) {
  _json_init()
  res = _json_unescape("a\\\\b")
  assert_eq(res, "a\\b", "unescape: backslash")
}
function test_json_unescape_unicode_ascii(    res) {
  _json_init()
  res = _json_unescape("\\u0041")
  assert_eq(res, "A", "unescape: \\u0041 -> A")
}
function test_json_unescape_unicode_bmp(    res) {
  _json_init()
  res = _json_unescape("\\u3042")
  assert_eq(res, "あ", "unescape: \\u3042 -> あ")
}
function test_json_unescape_unicode_surrogate(    res) {
  _json_init()
  res = _json_unescape("\\uD83D\\uDE00")
  assert_eq(res, "😀", "unescape: surrogate pair -> U+1F600")
}
function test_json_decode_nested_object(    out) {
  json_decode("{\"user\":{\"name\":\"Alice\",\"age\":30}}", out)
  assert_eq(out["user.name"], "Alice", "decode nested: user.name")
  assert_eq(out["user.age"], "30", "decode nested: user.age")
}
function test_json_decode_array(    out) {
  json_decode("{\"tags\":[\"a\",\"b\",\"c\"]}", out)
  assert_eq(out["tags.0"], "a", "decode array: tags.0")
  assert_eq(out["tags.1"], "b", "decode array: tags.1")
  assert_eq(out["tags.2"], "c", "decode array: tags.2")
}
function test_json_decode_deep(    out) {
  json_decode("{\"a\":{\"b\":{\"c\":\"deep\"}}}", out)
  assert_eq(out["a.b.c"], "deep", "decode deep: a.b.c")
}
function test_json_decode_unicode_in_value(    out) {
  json_decode("{\"msg\":\"\\u3053\\u3093\\u306B\\u3061\\u306F\"}", out)
  assert_eq(out["msg"], "こんにちは", "decode unicode in value")
}
function test_json_decode_escape_in_value(    out) {
  json_decode("{\"q\":\"say \\\"hi\\\"\"}", out)
  assert_eq(out["q"], "say \"hi\"", "decode escape in value")
}
function test_json_decode_invalid_returns_zero(    out, ret) {
  ret = json_decode("not json", out)
  assert_eq(ret, 0, "decode invalid: returns 0")
}
function test_json_decode_via_zig_flat(    out, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"x\":1,\"y\":\"hello\"}", out)
  assert_eq(ret, 1, "zig decode: returns 1")
  assert_eq(out["x"], "1", "zig decode: integer as string")
  assert_eq(out["y"], "hello", "zig decode: string value")
}

function test_json_decode_via_zig_nested(    out, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"a\":{\"b\":\"c\"}}", out)
  assert_eq(ret, 1, "zig decode nested: returns 1")
  assert_eq(out["a.b"], "c", "zig decode nested: dot-path key")
}

function test_json_decode_via_zig_array(    out, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"tags\":[\"a\",\"b\"]}", out)
  assert_eq(ret, 1, "zig decode array: returns 1")
  assert_eq(out["tags.0"], "a", "zig decode array: index 0")
  assert_eq(out["tags.1"], "b", "zig decode array: index 1")
}

function test_json_decode_via_zig_bool(    out, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"ok\":true,\"ng\":false,\"n\":null}", out)
  assert_eq(ret, 1, "zig decode bool: returns 1")
  assert_eq(out["ok"], "true",  "zig decode bool: true")
  assert_eq(out["ng"], "false", "zig decode bool: false")
  assert_eq(out["n"],  "null",  "zig decode bool: null")
}

function test_json_decode_via_zig_invalid(    out, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("not json", out)
  assert_eq(ret, 0, "zig decode invalid: returns 0")
}

function test_json_dispatch_encode(   data, out) {
  delete data
  data["foo"] = "bar"
  out = json::dispatch("encode", data)
  assert_eq(out, "{\"foo\":\"bar\"}", "json::dispatch encode")
}

function test_json_dispatch_decode_ok(   res) {
  res = json::dispatch("decode", "{\"k\":\"v\"}")
  assert_true(awk::result_ok(res), "json::dispatch decode ok")
  assert_eq(awk::result_val(res), "{\"k\":\"v\"}", "json::dispatch decode payload is input s")
}

function test_json_dispatch_decode_ng(   res) {
  res = json::dispatch("decode", "not json")
  assert_true(!awk::result_ok(res), "json::dispatch decode ng")
  assert_eq(awk::result_err_type(res), "JsonError", "json::dispatch decode err type")
}

function test_json_dispatch_decode_t_ok(   res) {
  res = json::dispatch("decode_t", "Int", "{\"n\":1}")
  assert_true(awk::result_ok(res), "json::dispatch decode_t Int ok")
}

function test_json_dispatch_decode_t_mismatch(   res) {
  res = json::dispatch("decode_t", "Int", "{\"n\":\"abc\"}")
  assert_true(!awk::result_ok(res), "json::dispatch decode_t type mismatch ng")
  assert_eq(awk::result_err_type(res), "JsonError", "json::dispatch decode_t err type")
}

function test_json_dispatch_unknown_path(   res) {
  # hawk_dispatch::call は未登録 path に対し stderr へ警告を出して空文字列を返す契約。
  # stderr の文言検査はテストハーネスを複雑化するため行わず、戻り値が空であることのみ確認する。
  res = json::dispatch("no_such_path", "x")
  assert_eq(res, "", "json::dispatch unknown_path returns empty")
}
