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

function test_json_decode_flat(   out, out_type) {
  delete out
  json_decode("{\"foo\":\"bar\",\"n\":42,\"ok\":true,\"v\":null}", out, out_type)
  assert_eq(out["foo"], "bar", "json decode: string")
  assert_eq(out["n"],   "42",  "json decode: number as string")
  assert_eq(out["ok"],  "true", "json decode: bool")
  assert_eq(out_type["v"], "null", "json decode: null literal")
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
function test_json_decode_nested_object(    out, out_type) {
  json_decode("{\"user\":{\"name\":\"Alice\",\"age\":30}}", out, out_type)
  assert_eq(out["user.name"], "Alice", "decode nested: user.name")
  assert_eq(out["user.age"], "30", "decode nested: user.age")
}
function test_json_decode_array(    out, out_type) {
  json_decode("{\"tags\":[\"a\",\"b\",\"c\"]}", out, out_type)
  assert_eq(out["tags.0"], "a", "decode array: tags.0")
  assert_eq(out["tags.1"], "b", "decode array: tags.1")
  assert_eq(out["tags.2"], "c", "decode array: tags.2")
}
function test_json_decode_deep(    out, out_type) {
  json_decode("{\"a\":{\"b\":{\"c\":\"deep\"}}}", out, out_type)
  assert_eq(out["a.b.c"], "deep", "decode deep: a.b.c")
}
function test_json_decode_unicode_in_value(    out, out_type) {
  json_decode("{\"msg\":\"\\u3053\\u3093\\u306B\\u3061\\u306F\"}", out, out_type)
  assert_eq(out["msg"], "こんにちは", "decode unicode in value")
}
function test_json_decode_escape_in_value(    out, out_type) {
  json_decode("{\"q\":\"say \\\"hi\\\"\"}", out, out_type)
  assert_eq(out["q"], "say \"hi\"", "decode escape in value")
}
function test_json_decode_invalid_returns_zero(    out, out_type, ret) {
  ret = json_decode("not json", out, out_type)
  assert_eq(ret, 0, "decode invalid: returns 0")
}
function test_json_decode_via_zig_flat(    out, out_type, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"x\":1,\"y\":\"hello\"}", out, out_type)
  assert_eq(ret, 1, "zig decode: returns 1")
  assert_eq(out["x"], "1", "zig decode: integer as string")
  assert_eq(out["y"], "hello", "zig decode: string value")
}

function test_json_decode_via_zig_nested(    out, out_type, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"a\":{\"b\":\"c\"}}", out, out_type)
  assert_eq(ret, 1, "zig decode nested: returns 1")
  assert_eq(out["a.b"], "c", "zig decode nested: dot-path key")
}

function test_json_decode_via_zig_array(    out, out_type, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"tags\":[\"a\",\"b\"]}", out, out_type)
  assert_eq(ret, 1, "zig decode array: returns 1")
  assert_eq(out["tags.0"], "a", "zig decode array: index 0")
  assert_eq(out["tags.1"], "b", "zig decode array: index 1")
}

function test_json_decode_via_zig_bool(    out, out_type, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("{\"ok\":true,\"ng\":false,\"n\":null}", out, out_type)
  assert_eq(ret, 1, "zig decode bool: returns 1")
  assert_eq(out["ok"], "true",  "zig decode bool: true")
  assert_eq(out["ng"], "false", "zig decode bool: false")
  assert_eq(out_type["n"], "null",  "zig decode bool: null")
}

function test_json_decode_via_zig_invalid(    out, out_type, ret) {
  if (!LIBS_LOADED["json"]) {
    TESTS_SKIPPED++
    return
  }
  ret = json_decode("not json", out, out_type)
  assert_eq(ret, 0, "zig decode invalid: returns 0")
}

function test_json_decode_type_tags(    out, out_type, ret) {
  if (!LIBS_LOADED["json"]) { TESTS_SKIPPED++; return }
  ret = json_decode("{\"i\":1,\"f\":1.5,\"s\":\"x\",\"b\":true,\"n\":null}", out, out_type)
  assert_eq(ret, 1, "decode types: returns 1")
  assert_eq(out_type["i"], "int",    "type tag: int")
  assert_eq(out_type["f"], "float",  "type tag: float")
  assert_eq(out_type["s"], "string", "type tag: string")
  assert_eq(out_type["b"], "bool",   "type tag: bool")
  assert_eq(out_type["n"], "null",   "type tag: null")
}

function test_json_decode_distinguishes_string_from_int(    out, out_type) {
  if (!LIBS_LOADED["json"]) { TESTS_SKIPPED++; return }
  json_decode("{\"a\":1,\"b\":\"1\"}", out, out_type)
  assert_eq(out["a"], "1", "value: int 1 as string")
  assert_eq(out["b"], "1", "value: string 1")
  assert_eq(out_type["a"], "int",    "tag distinguishes int from string")
  assert_eq(out_type["b"], "string", "tag distinguishes string from int")
}

function test_json_decode_base64_roundtrip(    out, out_type) {
  if (!LIBS_LOADED["json"]) { TESTS_SKIPPED++; return }
  json_decode("{\"k\":\"a\\u001eb\\u001fc\\u001bd\"}", out, out_type)
  assert_eq(out["k"], "a\x1eb\x1fc\x1bd", "base64 roundtrip: RS/US/ESC in value")
}

function test_json_decode_fallback_type_tags(    out, out_type, _saved) {
  _saved = LIBS_LOADED["json"]
  LIBS_LOADED["json"] = 0
  json_decode("{\"i\":1,\"s\":\"x\",\"b\":true,\"n\":null}", out, out_type)
  LIBS_LOADED["json"] = _saved
  assert_eq(out_type["i"], "int",    "fallback type: int")
  assert_eq(out_type["s"], "string", "fallback type: string")
  assert_eq(out_type["b"], "bool",   "fallback type: bool")
  assert_eq(out_type["n"], "null",   "fallback type: null")
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
